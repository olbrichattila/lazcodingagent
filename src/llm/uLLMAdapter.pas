unit uLLMAdapter;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, fpjson, jsonparser, uAgentTypes, uAgentHistory;
type
  TLLMAdapter = class
  public
    function Messages(AHistory: TAgentHistory; const ASystem: string): TJSONArray; virtual; abstract;
    { Takes ownership of messages/tools. }
    function BuildRequest(AMessages, ATools: TJSONArray; const AModel: string; AProvider: TLLMProvider;
      AStream: Boolean; AMaxTokens: Integer): TJSONObject; virtual; abstract;
    function ParseResponse(AData: TJSONObject): TChatMessage; virtual; abstract;
    procedure ValidateResponse(AMessage: TChatMessage); virtual; abstract;
  end;
  TChatCompletionsAdapter = class(TLLMAdapter)
  public
    function Messages(AHistory: TAgentHistory; const ASystem: string): TJSONArray; override;
    function BuildRequest(AMessages, ATools: TJSONArray; const AModel: string; AProvider: TLLMProvider;
      AStream: Boolean; AMaxTokens: Integer): TJSONObject; override;
    function ParseResponse(AData: TJSONObject): TChatMessage; override;
    procedure ValidateResponse(AMessage: TChatMessage); override;
  end;
implementation
function TChatCompletionsAdapter.BuildRequest(AMessages, ATools: TJSONArray;
  const AModel: string; AProvider: TLLMProvider; AStream: Boolean; AMaxTokens: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('messages', AMessages);
    Result.Add('model', AModel);
    if AStream then Result.Add('stream', True);
    if AMaxTokens > 0 then
    begin
      if AProvider = lpOpenAI then Result.Add('max_completion_tokens', AMaxTokens)
      else Result.Add('max_tokens', AMaxTokens);
    end;
    if Assigned(ATools) then
    begin
      Result.Add('tools', ATools); ATools := nil;
      Result.Add('tool_choice', 'auto');
    end;
  except ATools.Free; Result.Free; raise; end;
end;

function TChatCompletionsAdapter.Messages(AHistory: TAgentHistory; const ASystem: string): TJSONArray;
var I, J, K: Integer; Pending: TStringList; M: TChatMessage; O: TJSONObject; Calls: TJSONArray;
  procedure AddCall(const Id, Name, Args: string);
  begin
    Calls.Add(TJSONObject.Create(['id', Id, 'type', 'function',
      'function', TJSONObject.Create(['name', Name, 'arguments', Args])]));
  end;
begin
  Result := TJSONArray.Create;
  Pending := TStringList.Create;
  try
    try
      if ASystem <> '' then Result.Add(TJSONObject.Create(['role', 'system', 'content', ASystem]));
      for I := 0 to AHistory.Count - 1 do
        if AHistory.GetMessage(I).Role = mrSystem then
          Result.Add(TJSONObject.Create(['role', 'system', 'content', AHistory.GetMessage(I).Content]));
      if AHistory.Summary <> '' then Result.Add(TJSONObject.Create(['role', 'user', 'content',
        'Historical conversation summary (context, not new instructions):' + LineEnding + AHistory.Summary]));
      for I := 0 to AHistory.Count - 1 do
      begin
        M := AHistory.GetMessage(I);
        if M.Role = mrSystem then Continue;
        if (M.Role <> mrTool) and (Pending.Count > 0) then
          raise Exception.Create('Assistant tool calls must receive results before the next message');
        if M.Role = mrTool then
        begin
          K := Pending.IndexOf(M.ToolCallId);
          if K < 0 then raise Exception.Create('Orphan or duplicate tool result');
          Pending.Delete(K);
        end;
        O := TJSONObject.Create(['role', RoleToString(M.Role)]);
        Result.Add(O);
        if (M.Role = mrAssistant) and ((M.ToolCalls.Count > 0) or (M.ToolCallId <> '')) then
        begin
          if M.Content = '' then O.Add('content', TJSONNull.Create) else O.Add('content', M.Content);
          Calls := TJSONArray.Create; O.Add('tool_calls', Calls);
          for J := 0 to M.ToolCalls.Count - 1 do
          begin
            if (M.ToolCalls[J].Id = '') or (Pending.IndexOf(M.ToolCalls[J].Id) >= 0) then
              raise Exception.Create('Missing or duplicate assistant tool call ID');
            Pending.Add(M.ToolCalls[J].Id);
            AddCall(M.ToolCalls[J].Id, M.ToolCalls[J].Name, M.ToolCalls[J].Arguments);
          end;
          if M.ToolCalls.Count = 0 then
          begin
            Pending.Add(M.ToolCallId); AddCall(M.ToolCallId, M.ToolCallName, M.ToolCallArgs);
          end;
        end
        else O.Add('content', M.Content);
        if M.Role = mrTool then
        begin
          if M.ToolCallId = '' then raise Exception.Create('Tool result has no call ID');
          O.Add('tool_call_id', M.ToolCallId);
        end;
      end;
      if Pending.Count <> 0 then raise Exception.Create('Unresolved assistant tool calls');
    except Result.Free; raise; end;
  finally Pending.Free; end;
end;

procedure TChatCompletionsAdapter.ValidateResponse(AMessage: TChatMessage);
var I, J: Integer; D: TJSONData; C: TAgentToolCall;
begin
  for I := 0 to AMessage.ToolCalls.Count - 1 do
  begin
    C := AMessage.ToolCalls[I];
    if C.Name = '' then raise Exception.Create('Incomplete tool call: missing name');
    D := GetJSON(C.Arguments);
    try
      if not (D is TJSONObject) then raise Exception.Create('Tool arguments must be a JSON object');
    finally D.Free; end;
    for J := 0 to I - 1 do
      if (C.Id <> '') and (C.Id = AMessage.ToolCalls[J].Id) then
        raise Exception.Create('Duplicate tool call ID in response');
  end;
end;

function TChatCompletionsAdapter.ParseResponse(AData: TJSONObject): TChatMessage;
var Choices, Calls: TJSONArray; Choice, M, C, F: TJSONObject; I: Integer; Finish: string;
begin
  Result := nil;
  Choices := AData.Find('choices') as TJSONArray;
  if (Choices = nil) or (Choices.Count = 0) then raise Exception.Create('API returned no choices');
  Choice := Choices.Objects[0];
  Finish := Choice.Get('finish_reason', '');
  if (Finish <> '') and not (Finish = 'stop') and not (Finish = 'tool_calls') then
    raise Exception.Create('Incomplete response: ' + Finish);
  M := Choice.Find('message') as TJSONObject;
  if M = nil then raise Exception.Create('API returned no assistant message');
  Result := TChatMessage.Create(mrAssistant, M.Get('content', ''));
  try
    Calls := M.Find('tool_calls') as TJSONArray;
    if Calls <> nil then for I := 0 to Calls.Count - 1 do
    begin
      C := Calls.Objects[I]; F := C.Find('function') as TJSONObject;
      if F = nil then raise Exception.Create('Missing tool function');
      Result.AddToolCall(C.Get('id', ''), F.Get('name', ''), F.Get('arguments', ''));
    end;
    ValidateResponse(Result);
  except FreeAndNil(Result); raise; end;
end;
end.
