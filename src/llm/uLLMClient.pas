unit uLLMClient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpclient, opensslsockets, fpjson, jsonparser,
  uAgentTypes, uAgentHistory, uAgentConfig, uToolBase, uLLMAdapter;

type
  TSSEChunkEvent = procedure(const AChunk: string; AIsReasoning: Boolean) of object;

  { Custom Stream capturing real-time SSE chunks from HTTP stream }
  TSSEStream = class(TStream)
  private
    FCalls: TAgentToolCalls;
    FDone, FInvalid: Boolean;
    FFinishReason: string;
    FBuffer: string;
    FError: string;
    FReceivedData: string;
    FOnChunk: TSSEChunkEvent;
    FAccumulatedContent: string;
    FAccumulatedReasoning: string;
    FAccumulatedToolId: string;
    FAccumulatedToolName: string;
    FAccumulatedToolArgs: string;
    FHasToolCall: Boolean;
    procedure ProcessLine(const ALine: string);
  public
    constructor Create(AOnChunk: TSSEChunkEvent);
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
    procedure Flush;
    destructor Destroy; override;
    function Response: TChatMessage;
    property Complete: Boolean read FDone;
    property Error: string read FError;
    property ReceivedData: string read FReceivedData;

    property AccumulatedContent: string read FAccumulatedContent;
    property AccumulatedReasoning: string read FAccumulatedReasoning;
    property AccumulatedToolId: string read FAccumulatedToolId;
    property AccumulatedToolName: string read FAccumulatedToolName;
    property AccumulatedToolArgs: string read FAccumulatedToolArgs;
    property HasToolCall: Boolean read FHasToolCall;
  end;

  TLLMClient = class
  private
    FAdapter: TLLMAdapter;
    FConfig: TAgentConfig;
    function ExtractErrorMessage(AResponseData: string; AStatusCode: Integer): string;

  public
    constructor Create(AConfig: TAgentConfig; AAdapter: TLLMAdapter = nil);
    destructor Destroy; override;
    function BuildSystemPrompt(AMode: TAgentMode): string;
    function SendResponse(AHistory: TAgentHistory; AMode: TAgentMode;
      AStream, AEnableTools: Boolean; AOnChunk: TSSEChunkEvent;
      out AMessage: TChatMessage; out AError: string): Boolean;
    { Takes ownership of AMessages. No conversation mutations. }
    function RequestResponse(AMessages: TJSONArray; AStream, AEnableTools: Boolean;
      AMode: TAgentMode; AOnChunk: TSSEChunkEvent; AMaxTokens: Integer;
      out AMessage: TChatMessage; out AError: string): Boolean;
    property Adapter: TLLMAdapter read FAdapter;
    function SendChat(AHistory: TAgentHistory; AMode: TAgentMode; out AResponseText: string): Boolean; overload;
    function SendChat(AHistory: TAgentHistory; AMode: TAgentMode; AEnableTools: Boolean;
      out AResponseText: string; out AHasToolCall: Boolean;
      out AToolCallId, AToolName, AToolArgs: string): Boolean; overload;
    function SendChatStream(AHistory: TAgentHistory; AMode: TAgentMode; AEnableTools: Boolean;
      AOnChunk: TSSEChunkEvent; out AResponseText: string; out AHasToolCall: Boolean;
      out AToolCallId, AToolName, AToolArgs: string): Boolean;
    function FetchAvailableModels(AModelList: TStrings; out AErrorMsg: string): Boolean;
  end;

implementation

const
  LLMUserAgent = 'Mozilla/5.0';
  MaxStreamDiagnosticChars = 12000;

{ TSSEStream }

constructor TSSEStream.Create(AOnChunk: TSSEChunkEvent);
begin
  inherited Create;
  FOnChunk := AOnChunk;
  FCalls := TAgentToolCalls.Create(True);
  FBuffer := '';
  FAccumulatedContent := '';
  FAccumulatedReasoning := '';
  FAccumulatedToolId := '';
  FAccumulatedToolName := '';
  FAccumulatedToolArgs := '';
  FHasToolCall := False;
end;

function TSSEStream.Write(const Buffer; Count: Longint): Longint;
var
  P: PChar;
  I: Integer;
  Ch: Char;
  Line, Chunk: string;
begin
  Result := Count;
  if Count <= 0 then Exit;

  P := @Buffer;
  SetString(Chunk, P, Count);
  FReceivedData := FReceivedData + Chunk;
  if Length(FReceivedData) > MaxStreamDiagnosticChars then
    Delete(FReceivedData, 1, Length(FReceivedData) - MaxStreamDiagnosticChars);
  for I := 0 to Count - 1 do
  begin
    Ch := P[I];
    if Ch = #10 then
    begin
      Line := FBuffer;
      FBuffer := '';
      ProcessLine(Line);
    end
    else if Ch <> #13 then
      FBuffer := FBuffer + Ch;
  end;
end;

function TSSEStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TSSEStream.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

procedure TSSEStream.Flush;
var
  Line: string;
begin
  if FBuffer <> '' then
  begin
    Line := FBuffer;
    FBuffer := '';
    ProcessLine(Line);
  end;
end;

destructor TSSEStream.Destroy;
begin
  FCalls.Free;
  inherited Destroy;
end;

function TSSEStream.Response: TChatMessage;
var I: Integer;
begin
  if FInvalid then
    raise Exception.Create('Invalid streaming response: ' + FError);
  if (FFinishReason <> '') and (FFinishReason <> 'stop') and
    (FFinishReason <> 'tool_calls') then
    raise Exception.Create('Incomplete streaming response: finish_reason="' +
      FFinishReason + '"');
  if not FDone and (FFinishReason = '') then
    raise Exception.Create('Incomplete streaming response: missing data: [DONE] terminator and terminal finish_reason');
  Result := TChatMessage.Create(mrAssistant, FAccumulatedContent);
  try
    for I := 0 to FCalls.Count - 1 do Result.ToolCalls.Add(FCalls[I].Clone);
  except Result.Free; raise; end;
end;

procedure TSSEStream.ProcessLine(const ALine: string);
var S, Chunk, NameChunk, IdChunk: string; Data: TJSONData;
  Obj, Choice, Delta, CallObj, Fn: TJSONObject; Choices, Calls: TJSONArray;
  I, J, Index: Integer; Call: TAgentToolCall;
begin
  S := Trim(ALine);
  if Copy(S, 1, 5) <> 'data:' then Exit;
  S := Trim(Copy(S, 6, Length(S)));
  if S = '[DONE]' then begin FDone := True; Exit; end;
  if S = '' then Exit;
  try
    Data := GetJSON(S);
    try
      Obj := Data as TJSONObject;
      if Obj.Find('error') <> nil then
      begin
        if Obj.Types['error'] = jtObject then
          raise Exception.Create('Provider stream error: ' + Obj.Objects['error'].Get('message', 'unspecified error'))
        else
          raise Exception.Create('Provider stream error: ' + Obj.Get('error', 'unspecified error'));
      end;
      Choices := Obj.Find('choices') as TJSONArray;
      if (Choices = nil) or (Choices.Count = 0) then Exit;
      Choice := Choices.Objects[0];
      if (Choice.Find('finish_reason') <> nil) and (Choice.Types['finish_reason'] <> jtNull) then
        FFinishReason := Choice.Get('finish_reason', '');
      Delta := Choice.Find('delta') as TJSONObject;
      if Delta = nil then Exit;
      Chunk := Delta.Get('reasoning_content', Delta.Get('reasoning', ''));
      if (Chunk <> '') and Assigned(FOnChunk) then FOnChunk(Chunk, True);
      Chunk := Delta.Get('content', '');
      FAccumulatedContent := FAccumulatedContent + Chunk;
      if (Chunk <> '') and Assigned(FOnChunk) then FOnChunk(Chunk, False);
      Calls := Delta.Find('tool_calls') as TJSONArray;
      if Calls <> nil then for I := 0 to Calls.Count - 1 do
      begin
        CallObj := Calls.Objects[I]; Index := CallObj.Get('index', 0);
        if Index < 0 then raise Exception.Create('Invalid stream tool index');
        Call := nil;
        for J := 0 to FCalls.Count - 1 do
          if FCalls[J].StreamIndex = Index then Call := FCalls[J];
        if Call = nil then
        begin
          Call := TAgentToolCall.Create; Call.StreamIndex := Index;
          J := 0;
          while (J < FCalls.Count) and (FCalls[J].StreamIndex < Index) do Inc(J);
          FCalls.Insert(J, Call);
        end;
        IdChunk := CallObj.Get('id', '');
        if (IdChunk <> '') and (IdChunk <> Call.Id) then
        begin
          if (Call.Id <> '') and (Copy(IdChunk, 1, Length(Call.Id)) = Call.Id) then
            Call.Id := IdChunk
          else Call.Id := Call.Id + IdChunk;
        end;
        Fn := CallObj.Find('function') as TJSONObject;
        if Fn <> nil then
        begin
          NameChunk := Fn.Get('name', '');
          if (NameChunk <> '') and (NameChunk <> Call.Name) then
          begin
            if (Call.Name <> '') and (Copy(NameChunk, 1, Length(Call.Name)) = Call.Name) then
              Call.Name := NameChunk
            else Call.Name := Call.Name + NameChunk;
          end;
          Call.Arguments := Call.Arguments + Fn.Get('arguments', '');
        end;
      end;
      FHasToolCall := FCalls.Count > 0;
      if FHasToolCall then
      begin
        FAccumulatedToolId := FCalls[0].Id;
        FAccumulatedToolName := FCalls[0].Name;
        FAccumulatedToolArgs := FCalls[0].Arguments;
      end;
    finally Data.Free; end;
  except
    on E: Exception do
    begin
      FInvalid := True;
      if FError = '' then FError := E.Message;
    end;
  end;
end;

procedure RedactStreamReasoning(AData: TJSONData);
var I: Integer; Obj: TJSONObject; Arr: TJSONArray; Key: string;
begin
  if AData = nil then Exit;
  if AData.JSONType = jtObject then
  begin
    Obj := TJSONObject(AData);
    for I := Obj.Count - 1 downto 0 do
    begin
      Key := LowerCase(Obj.Names[I]);
      if (Key = 'thinking') or (Key = 'thought') or (Key = 'thoughts') or
        (Key = 'reasoning') or (Key = 'reasoning_content') or
        (Key = 'reasoning_details') or (Key = 'analysis') or
        (Key = 'chain_of_thought') or (Key = 'internal_reasoning') then
      begin
        Key := Obj.Names[I];
        Obj.Delete(Key);
        Obj.Add(Key, '[reasoning redacted]');
      end
      else RedactStreamReasoning(Obj.Items[I]);
    end;
  end
  else if AData.JSONType = jtArray then
  begin
    Arr := TJSONArray(AData);
    for I := 0 to Arr.Count - 1 do RedactStreamReasoning(Arr.Items[I]);
  end;
end;

function SanitizedStreamTail(const ARaw: string): string;
var I, StartAt: Integer; Line, Payload: string; Data: TJSONData;
begin
  Result := '';
  StartAt := 1;
  for I := 1 to Length(ARaw) + 1 do
    if (I > Length(ARaw)) or (ARaw[I] = #10) then
    begin
      Line := Copy(ARaw, StartAt, I - StartAt);
      if (Line <> '') and (Line[Length(Line)] = #13) then Delete(Line, Length(Line), 1);
      if Copy(Line, 1, 5) = 'data:' then
      begin
        Payload := Trim(Copy(Line, 6, Length(Line)));
        if (Payload <> '') and (Payload <> '[DONE]') then
        begin
          try
            Data := GetJSON(Payload);
            try
              RedactStreamReasoning(Data);
              Line := 'data: ' + Data.AsJSON;
            finally Data.Free; end;
          except
            { Retain malformed SSE lines unchanged so the parser failure is diagnosable. }
          end;
        end;
      end;
      if Result <> '' then Result := Result + LineEnding;
      Result := Result + Line;
      StartAt := I + 1;
    end;
end;

{ TLLMClient }

constructor TLLMClient.Create(AConfig: TAgentConfig; AAdapter: TLLMAdapter);
begin
  inherited Create;
  FConfig := AConfig;
  FAdapter := AAdapter;
  if FAdapter = nil then FAdapter := TChatCompletionsAdapter.Create;
end;

function TLLMClient.BuildSystemPrompt(AMode: TAgentMode): string;
var
  ToolsInfo: string;
  WorkingDir: string;
begin
  WorkingDir := GetEffectiveProjectDir;

  ToolsInfo := GetToolRegistry.ToolGuidance(AMode);

  case AMode of
    amPlan:
      Result :=
        'You are an expert software architect planning development in the current project.' + LineEnding +
        'Active Mode: Plan' + LineEnding +
        'Current Project Directory: ' + WorkingDir + LineEnding + LineEnding +
        ToolsInfo +
        'Instructions:' + LineEnding +
        '- This agent is working on a project. For project tasks, always inspect the actual files and use list_directory/glob/search_code/read_file before making claims.' + LineEnding +
        '- Use inspection tools, cached diagnostics, and task tracking.' + LineEnding +
        '- Only create .md files inside ' + IncludeTrailingPathDelimiter(WorkingDir) + '.plan' + DirectorySeparator + ', using create_plan_file. Do not modify other project files. Shell commands and compiler builds are unavailable.' + LineEnding +
        '- Produce a structured, actionable Markdown plan and save it with create_plan_file. The tool chooses a timestamped filename under .plan/.' + LineEnding +
        '- If clarification is needed, ask questions in chat without saving a plan. Otherwise, mark any completed plan returned in chat with <proposed_plan> and </proposed_plan> on separate lines, so the app can save and preview it if necessary.' + LineEnding +
        '- Do not implement the plan.';

    amAgent:
      Result :=
        'You are an autonomous coding agent working on the current project, integrated into Free Lazarus IDE / Free Pascal.' + LineEnding +
        'Active Mode: Agent' + LineEnding +
        'Current Project Directory: ' + WorkingDir + LineEnding + LineEnding +
        ToolsInfo + LineEnding +
        'Instructions:' + LineEnding +
        '- For project tasks, always inspect the actual files with list_directory/glob/search_code/read_file before making claims or changes; do not guess at file contents.' + LineEnding +
        '- Implement the user request fully using the available project tools.' + LineEnding +
        '- Output clean, robust Free Pascal code compatible with the Lazarus Component Library (LCL).' + LineEnding +
        '- Work systematically step by step until the user task is fully resolved.' + LineEnding +
        '- Finish with a short summary of what was accomplished and any checks actually performed. State unfinished work or failures clearly.';

    else
      Result :=
        'You are an expert software assistant working in the current project.' + LineEnding +
        'Active Mode: Ask' + LineEnding +
        'Current Project Directory: ' + WorkingDir + LineEnding + LineEnding +
        ToolsInfo + LineEnding +
        'Instructions:' + LineEnding +
        '- For project questions, always inspect the actual files with list_directory/glob/search_code/read_file before answering.' + LineEnding +
        '- This is Ask mode: use inspection tools, cached diagnostics, and task tracking. Do not write or create files, call write tools, or propose file-write actions.' + LineEnding +
        '- Answer questions directly and accurately using what you learned from the project.';
  end;
end;

function TLLMClient.ExtractErrorMessage(AResponseData: string; AStatusCode: Integer): string;
var
  Parser: TJSONParser;
  JSONData: TJSONData;
  Obj: TJSONObject;
  ErrMsg: string;
begin
  AResponseData := Trim(AResponseData);
  ErrMsg := '';

  if (Length(AResponseData) > 0) and (AResponseData[1] = '{') then
  begin
    try
      Parser := TJSONParser.Create(AResponseData, True);
      try
        JSONData := Parser.Parse;
        try
          if JSONData is TJSONObject then
          begin
            Obj := TJSONObject(JSONData);
            if Obj.Find('error') <> nil then
            begin
              if Obj.Types['error'] = jtObject then
                ErrMsg := Obj.Objects['error'].Get('message', '')
              else
                ErrMsg := Obj.Get('error', '');
            end
            else if Obj.Find('message') <> nil then
              ErrMsg := Obj.Get('message', '')
            else if Obj.Find('detail') <> nil then
              ErrMsg := Obj.Get('detail', '');
          end;
        finally
          JSONData.Free;
        end;
      finally
        Parser.Free;
      end;
    except
      // Ignore JSON parse errors
    end;
  end;

  if ErrMsg <> '' then
  begin
    if AStatusCode > 0 then
      Result := Format('API Error (HTTP %d): %s', [AStatusCode, ErrMsg])
    else
      Result := 'API Error: ' + ErrMsg;
  end
  else if AResponseData <> '' then
  begin
    if Length(AResponseData) > 300 then
      AResponseData := Copy(AResponseData, 1, 300) + '...';
    if AStatusCode > 0 then
      Result := Format('HTTP %d Error: %s', [AStatusCode, AResponseData])
    else
      Result := 'HTTP/Network Error: ' + AResponseData;
  end
  else
  begin
    Result := Format('HTTP request failed with status code %d', [AStatusCode]);
  end;
end;

destructor TLLMClient.Destroy;
begin
  FAdapter.Free;
  inherited Destroy;
end;

function TLLMClient.SendResponse(AHistory: TAgentHistory; AMode: TAgentMode;
  AStream, AEnableTools: Boolean; AOnChunk: TSSEChunkEvent;
  out AMessage: TChatMessage; out AError: string): Boolean;
var Snapshot: TAgentHistory;
begin
  Result := False; AMessage := nil; AError := ''; Snapshot := nil;
  try
    try
      Snapshot := AHistory.Clone;
      Result := RequestResponse(FAdapter.Messages(Snapshot, BuildSystemPrompt(AMode)),
        AStream, AEnableTools, AMode, AOnChunk, 0, AMessage, AError);
    except on E: Exception do AError := 'LLM context error: ' + E.Message; end;
  finally Snapshot.Free; end;
end;

function TLLMClient.RequestResponse(AMessages: TJSONArray; AStream, AEnableTools: Boolean;
  AMode: TAgentMode; AOnChunk: TSSEChunkEvent; AMaxTokens: Integer;
  out AMessage: TChatMessage; out AError: string): Boolean;
var Req: TJSONObject; Tools: TJSONArray; Client: TFPHTTPClient; Input: TRawByteStringStream;
  Output: TStringStream; SSE: TSSEStream; Data: TJSONData;
  Body, Diagnostic, Fence: string; Status, I, RunLength, MaxRun: Integer;
begin
  Result := False; AMessage := nil; AError := '';
  if (FConfig.APIKey = '') and (FConfig.Provider in [lpOpenAI, lpNousPortal, lpOpenRouter]) then
  begin
    AMessages.Free;
    AError := 'API key is not configured for ' + ProviderToString(FConfig.Provider); Exit;
  end;
  Tools := nil;
  try
    if AEnableTools and (GetToolRegistry.Count > 0) then
      Tools := GetToolRegistry.GetToolsDeclarationJSONArray(AMode);
  except AMessages.Free; raise; end;
  Req := FAdapter.BuildRequest(AMessages, Tools, FConfig.ModelName, FConfig.Provider, AStream, AMaxTokens);
  try Body := Req.AsJSON; finally Req.Free; end;
  Client := TFPHTTPClient.Create(nil);
  Input := nil; Output := nil; SSE := nil;
  try
    Input := TRawByteStringStream.Create(Body);
    Output := TStringStream.Create('');
    SSE := TSSEStream.Create(AOnChunk);
    Client.AllowRedirect := True;
    Client.ConnectTimeout := 30000; Client.IOTimeout := 120000;
    Client.AddHeader('Content-Type', 'application/json');
    Client.AddHeader('User-Agent', LLMUserAgent);
    if AStream then Client.AddHeader('Accept', 'text/event-stream');
    if FConfig.APIKey <> '' then Client.AddHeader('Authorization', 'Bearer ' + FConfig.APIKey);
    Client.RequestBody := Input;
    try
      if AStream then Client.Post(FConfig.EndpointURL, SSE) else Client.Post(FConfig.EndpointURL, Output);
      Status := Client.ResponseStatusCode;
      if Status >= 400 then
      begin
        if AStream then
          raise Exception.Create(ExtractErrorMessage(SSE.ReceivedData, Status))
        else
          raise Exception.Create(ExtractErrorMessage(Output.DataString, Status));
      end;
      if AStream then
      begin
        SSE.Flush;
        AMessage := SSE.Response;
        FAdapter.ValidateResponse(AMessage);
      end
      else
      begin
        Data := GetJSON(Output.DataString);
        try AMessage := FAdapter.ParseResponse(Data as TJSONObject); finally Data.Free; end;
      end;
      Result := True;
    except on E: Exception do
      begin
        FreeAndNil(AMessage);
        AError := 'LLM request failed: ' + E.Message;
        if AStream and (SSE <> nil) and (SSE.ReceivedData <> '') then
        begin
          Diagnostic := SanitizedStreamTail(SSE.ReceivedData);
          MaxRun := 0; RunLength := 0;
          for I := 1 to Length(Diagnostic) do
          begin
            if Diagnostic[I] = '`' then
            begin
              Inc(RunLength);
              if RunLength > MaxRun then MaxRun := RunLength;
            end
            else RunLength := 0;
          end;
          Fence := StringOfChar('`', MaxRun + 1);
          if Length(Fence) < 3 then Fence := '```';
          AError := AError + LineEnding + LineEnding +
            'Raw model stream tail (up to 12000 characters; may include generated text and tool arguments):' +
            LineEnding + Fence + 'text' + LineEnding + Diagnostic + LineEnding + Fence;
        end;
      end;
    end;
  finally
    Client.RequestBody := nil;
    Input.Free; Output.Free; SSE.Free; Client.Free;
  end;
end;

function TLLMClient.SendChat(AHistory: TAgentHistory; AMode: TAgentMode; out AResponseText: string): Boolean;
var HasCall: Boolean; Id, Name, Args: string;
begin
  Result := SendChat(AHistory, AMode, False, AResponseText, HasCall, Id, Name, Args);
end;

procedure LegacyResponse(M: TChatMessage; out Text: string; out HasCall: Boolean;
  out Id, Name, Args: string);
begin
  Text := M.Content; HasCall := M.ToolCalls.Count > 0;
  if HasCall then
  begin Id := M.ToolCalls[0].Id; Name := M.ToolCalls[0].Name; Args := M.ToolCalls[0].Arguments; end;
end;

function TLLMClient.SendChat(AHistory: TAgentHistory; AMode: TAgentMode; AEnableTools: Boolean;
  out AResponseText: string; out AHasToolCall: Boolean;
  out AToolCallId, AToolName, AToolArgs: string): Boolean;
var M: TChatMessage;
begin
  AHasToolCall := False; AToolCallId := ''; AToolName := ''; AToolArgs := '';
  Result := SendResponse(AHistory, AMode, False, AEnableTools, nil, M, AResponseText);
  if Result then
    try LegacyResponse(M, AResponseText, AHasToolCall, AToolCallId, AToolName, AToolArgs); finally M.Free; end;
end;

function TLLMClient.SendChatStream(AHistory: TAgentHistory; AMode: TAgentMode; AEnableTools: Boolean;
  AOnChunk: TSSEChunkEvent; out AResponseText: string; out AHasToolCall: Boolean;
  out AToolCallId, AToolName, AToolArgs: string): Boolean;
var M: TChatMessage;
begin
  AHasToolCall := False; AToolCallId := ''; AToolName := ''; AToolArgs := '';
  Result := SendResponse(AHistory, AMode, True, AEnableTools, AOnChunk, M, AResponseText);
  if Result then
    try LegacyResponse(M, AResponseText, AHasToolCall, AToolCallId, AToolName, AToolArgs); finally M.Free; end;
end;

function TLLMClient.FetchAvailableModels(AModelList: TStrings; out AErrorMsg: string): Boolean;
var
  Client: TFPHTTPClient;
  ModelsURL: string;
  ResponseBody: string;
  ResponseStream: TStringStream;
  Parser: TJSONParser;
  JSONData: TJSONData;
  ResponseJSON: TJSONObject;
  DataArray: TJSONArray;
  ItemObj: TJSONObject;
  I: Integer;
  ModelID: string;
  StatusCode: Integer;
begin
  Result := False;
  AErrorMsg := '';
  if not Assigned(AModelList) then Exit;
  AModelList.Clear;

  if (FConfig.APIKey = '') and (FConfig.Provider in [lpOpenAI, lpNousPortal, lpOpenRouter]) then
  begin
    AErrorMsg := 'API Key is required to fetch models for ' + ProviderToString(FConfig.Provider) + '.';
    Exit;
  end;

  if Pos('/chat/completions', FConfig.EndpointURL) > 0 then
    ModelsURL := StringReplace(FConfig.EndpointURL, '/chat/completions', '/models', [rfIgnoreCase, rfReplaceAll])
  else if Pos('/v1', FConfig.EndpointURL) > 0 then
    ModelsURL := Copy(FConfig.EndpointURL, 1, Pos('/v1', FConfig.EndpointURL) + 2) + '/models'
  else
    ModelsURL := FConfig.EndpointURL;

  Client := TFPHTTPClient.Create(nil);
  ResponseStream := TStringStream.Create('');
  try
    Client.AllowRedirect := True;
    Client.AddHeader('User-Agent', LLMUserAgent);
    if FConfig.APIKey <> '' then
      Client.AddHeader('Authorization', 'Bearer ' + FConfig.APIKey);

    StatusCode := 0;
    try
      Client.Get(ModelsURL, ResponseStream);
      StatusCode := Client.ResponseStatusCode;
      ResponseBody := ResponseStream.DataString;
    except
      on E: EHTTPClient do
      begin
        StatusCode := Client.ResponseStatusCode;
        ResponseBody := ResponseStream.DataString;
        AErrorMsg := ExtractErrorMessage(ResponseBody, StatusCode);
        Exit;
      end;
      on E: Exception do
      begin
        AErrorMsg := 'Network Error: ' + E.Message;
        Exit;
      end;
    end;

    ResponseBody := Trim(ResponseBody);
    if (StatusCode >= 400) or (Length(ResponseBody) = 0) or (ResponseBody[1] <> '{') then
    begin
      AErrorMsg := ExtractErrorMessage(ResponseBody, StatusCode);
      Exit;
    end;

    try
      Parser := TJSONParser.Create(ResponseBody, True);
      try
        JSONData := Parser.Parse;
        try
          if JSONData is TJSONObject then
          begin
            ResponseJSON := TJSONObject(JSONData);

            if ResponseJSON.Find('data') <> nil then
            begin
              DataArray := ResponseJSON.Arrays['data'];
              for I := 0 to DataArray.Count - 1 do
              begin
                if DataArray.Types[I] = jtObject then
                begin
                  ItemObj := DataArray.Objects[I];
                  ModelID := ItemObj.Get('id', '');
                  if ModelID <> '' then
                    AModelList.Add(ModelID);
                end
                else if DataArray.Types[I] = jtString then
                begin
                  ModelID := DataArray.Strings[I];
                  if ModelID <> '' then
                    AModelList.Add(ModelID);
                end;
              end;
            end
            else if ResponseJSON.Find('models') <> nil then
            begin
              DataArray := ResponseJSON.Arrays['models'];
              for I := 0 to DataArray.Count - 1 do
              begin
                if DataArray.Types[I] = jtObject then
                begin
                  ItemObj := DataArray.Objects[I];
                  ModelID := ItemObj.Get('name', '');
                  if ModelID <> '' then
                    AModelList.Add(ModelID);
                end;
              end;
            end;

            if AModelList.Count > 0 then
            begin
              TStringList(AModelList).Sort;
              Result := True;
            end
            else
            begin
              AErrorMsg := 'No models found in the server response.';
            end;
          end
          else
            AErrorMsg := 'Unexpected JSON response from server.';
        finally
          JSONData.Free;
        end;
      finally
        Parser.Free;
      end;
    except
      on E: Exception do
        AErrorMsg := 'JSON Parsing Error: ' + E.Message;
    end;

  finally
    ResponseStream.Free;
    Client.Free;
  end;
end;

end.
