unit uAgentHistory;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, fpjson, uAgentTypes;

type
  TChatMessageList = specialize TFPGObjectList<TChatMessage>;

  TAgentHistory = class
  private
    FMessages: TChatMessageList;
    FSummary: string;
    FEstimatedInputTokens: Int64;
    FNextCallId: QWord;
    FCallNamespace: string;
    FBlockedBudget, FBlockedRecentTurns: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    function AddMessage(ARole: TMessageRole; const AContent: string): TChatMessage;
    procedure Clear;
    function Clone: TAgentHistory;
    function AppendAssistant(AResponse: TChatMessage): TChatMessage;
    procedure AddToolResult(const ACallId, AName, AContent: string);
    function NewToolCallId: string;
    function CompactablePrefix(ARecentTurns: Integer): Integer;
    procedure ReplacePrefix(ACount: Integer; const ASummary: string);
    function PromptAdmissionAllowed(ABudget, ARecentTurns: Integer): Boolean;
    procedure Block(ABudget, ARecentTurns: Integer);
    procedure Unblock;
    property EstimatedInputTokens: Int64 read FEstimatedInputTokens write FEstimatedInputTokens;
    property Summary: string read FSummary write FSummary;
    function Count: Integer;
    function GetMessage(AIndex: Integer): TChatMessage;
    function ToJSON: TJSONObject;
    procedure LoadJSON(AData: TJSONObject);

    property Messages: TChatMessageList read FMessages;
  end;

implementation

{ TAgentHistory }

constructor TAgentHistory.Create;
var G: TGUID;
begin
  inherited Create;
  FMessages := TChatMessageList.Create(True);
  CreateGUID(G); FCallNamespace := GUIDToString(G);
end;

destructor TAgentHistory.Destroy;
begin
  FMessages.Free;
  inherited Destroy;
end;

function TAgentHistory.AddMessage(ARole: TMessageRole; const AContent: string): TChatMessage;
begin
  Result := TChatMessage.Create(ARole, AContent);
  FMessages.Add(Result);
end;

procedure TAgentHistory.Clear;
begin
  FMessages.Clear;
  FSummary := ''; FEstimatedInputTokens := 0; FNextCallId := 0; FBlockedBudget := 0; FBlockedRecentTurns := 0;
end;

function TAgentHistory.Count: Integer;
begin
  Result := FMessages.Count;
end;

function TAgentHistory.GetMessage(AIndex: Integer): TChatMessage;
begin
  if (AIndex >= 0) and (AIndex < FMessages.Count) then
    Result := FMessages[AIndex]
  else
    Result := nil;
end;

function TAgentHistory.Clone: TAgentHistory;
var I: Integer;
begin
  Result := TAgentHistory.Create;
  try
    Result.FSummary := FSummary;
    Result.FEstimatedInputTokens := FEstimatedInputTokens;
    Result.FNextCallId := FNextCallId;
    Result.FCallNamespace := FCallNamespace;
    for I := 0 to Count - 1 do Result.FMessages.Add(GetMessage(I).Clone);
  except Result.Free; raise; end;
end;

function TAgentHistory.NewToolCallId: string;
begin
  Inc(FNextCallId);
  Result := 'call_local_' + Copy(FCallNamespace, 2, 36) + '_' + IntToStr(FNextCallId);
end;

function TAgentHistory.AppendAssistant(AResponse: TChatMessage): TChatMessage;
var I, J: Integer; Collision: Boolean;
begin
  Result := AResponse.Clone;
  try
    for I := 0 to Result.ToolCalls.Count - 1 do
      if Result.ToolCalls[I].Id = '' then
        repeat
          Result.ToolCalls[I].Id := NewToolCallId;
          Collision := False;
          for J := 0 to Result.ToolCalls.Count - 1 do
            if (J <> I) and (Result.ToolCalls[I].Id = Result.ToolCalls[J].Id) then Collision := True;
        until not Collision;
    FMessages.Add(Result);
  except Result.Free; raise; end;
end;

procedure TAgentHistory.AddToolResult(const ACallId, AName, AContent: string);
var M: TChatMessage; I, J: Integer; Found: Boolean;
begin
  Found := False;
  for I := Count - 1 downto 0 do
  begin
    M := GetMessage(I);
    if M.Role = mrTool then
    begin
      if M.ToolCallId = ACallId then
      begin
        if M.Content <> AContent then raise Exception.Create('Conflicting duplicate tool result');
        Exit; { idempotent within this assistant invocation }
      end;
    end
    else if M.Role = mrAssistant then
    begin
      for J := 0 to M.ToolCalls.Count - 1 do
        if M.ToolCalls[J].Id = ACallId then Found := True;
      if (M.ToolCalls.Count = 0) and (M.ToolCallId <> '') and (M.ToolCallId = ACallId) then Found := True;
      Break;
    end
    else Break;
  end;
  if not Found or (ACallId = '') then raise Exception.Create('Tool result has no matching assistant call');
  M := AddMessage(mrTool, AContent);
  M.ToolCallId := ACallId; M.ToolCallName := AName;
end;

function TAgentHistory.CompactablePrefix(ARecentTurns: Integer): Integer;
var I, J, Turns: Integer;
begin
  Result := 0; Turns := 0;
  { The last user starts the protected current turn, including interrupted runs. }
  for I := Count - 1 downto 0 do
    if GetMessage(I).Role = mrUser then
    begin
      if Turns = ARecentTurns then
      begin
        for J := 0 to I - 1 do
          if GetMessage(J).Role <> mrSystem then begin Result := I; Exit; end;
        Exit;
      end;
      Inc(Turns);
    end;
end;

procedure TAgentHistory.ReplacePrefix(ACount: Integer; const ASummary: string);
var I: Integer;
begin
  if (ACount < 0) or (ACount > Count) or (Trim(ASummary) = '') then
    raise Exception.Create('Invalid history compaction');
  if (ACount < Count) and (ACount > 0) and not (FMessages[ACount].Role in [mrUser, mrSystem]) then
    raise Exception.Create('Compaction must replace whole turns');
  FSummary := ASummary;
  for I := ACount - 1 downto 0 do
    if FMessages[I].Role <> mrSystem then FMessages.Delete(I);
  FBlockedBudget := 0;
end;

function TAgentHistory.PromptAdmissionAllowed(ABudget, ARecentTurns: Integer): Boolean;
begin
  Result := (FBlockedBudget = 0) or (FBlockedBudget <> ABudget) or
    (FBlockedRecentTurns <> ARecentTurns);
end;

procedure TAgentHistory.Block(ABudget, ARecentTurns: Integer);
begin
  FBlockedBudget := ABudget; FBlockedRecentTurns := ARecentTurns;
end;

procedure TAgentHistory.Unblock;
begin FBlockedBudget := 0; FBlockedRecentTurns := 0; end;


function TAgentHistory.ToJSON: TJSONObject;
var I, J: Integer; M: TChatMessage; Calls: TJSONArray; Call: TAgentToolCall; MsgObj: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('summary', FSummary);
  Result.Add('estimated_tokens', FEstimatedInputTokens);
  Result.Add('next_call_id', UIntToStr(FNextCallId));
  Result.Add('call_namespace', FCallNamespace);
  Result.Add('blocked_budget', FBlockedBudget);
  Result.Add('blocked_recent_turns', FBlockedRecentTurns);
  Calls := TJSONArray.Create;
  for I := 0 to Count - 1 do
  begin
    M := GetMessage(I);
    MsgObj := TJSONObject.Create;
    MsgObj.Add('role', Ord(M.Role)); MsgObj.Add('content', M.Content);
    MsgObj.Add('timestamp', DateTimeToStr(M.Timestamp));
    MsgObj.Add('tool_call_id', M.ToolCallId); MsgObj.Add('tool_call_name', M.ToolCallName);
    MsgObj.Add('tool_call_args', M.ToolCallArgs);
    MsgObj.Add('calls', TJSONArray.Create);
    Calls.Add(MsgObj);
    for J := 0 to M.ToolCalls.Count - 1 do
    begin
      Call := M.ToolCalls[J];
      TJSONArray(MsgObj.Find('calls')).Add(
        TJSONObject.Create(['id', Call.Id, 'name', Call.Name,
          'arguments', Call.Arguments, 'stream_index', Call.StreamIndex]));
    end;
  end;
  Result.Add('messages', Calls);
end;

procedure TAgentHistory.LoadJSON(AData: TJSONObject);
var I, J, RoleValue: Integer; Arr, CallArr: TJSONArray; Obj, CObj: TJSONObject;
  M: TChatMessage; CallId, CallName, CallArgs: string;
begin
  Clear;
  if AData = nil then Exit;
  FSummary := AData.Get('summary', '');
  FEstimatedInputTokens := AData.Get('estimated_tokens', Int64(0));
  try FNextCallId := StrToQWord(AData.Get('next_call_id', '0')); except FNextCallId := 0; end;
  FCallNamespace := AData.Get('call_namespace', FCallNamespace);
  FBlockedBudget := AData.Get('blocked_budget', 0);
  FBlockedRecentTurns := AData.Get('blocked_recent_turns', 0);
  Arr := TJSONArray(AData.Find('messages'));
  if Arr = nil then Exit;
  for I := 0 to Arr.Count - 1 do
  begin
    Obj := TJSONObject(Arr[I]);
    RoleValue := Obj.Get('role', Ord(mrUser));
    if (RoleValue < Ord(Low(TMessageRole))) or (RoleValue > Ord(High(TMessageRole))) then RoleValue := Ord(mrUser);
    M := AddMessage(TMessageRole(RoleValue), Obj.Get('content', ''));
    try
      try M.Timestamp := StrToDateTime(Obj.Get('timestamp', DateTimeToStr(Now))); except end;
      M.ToolCallId := Obj.Get('tool_call_id', '');
      M.ToolCallName := Obj.Get('tool_call_name', '');
      M.ToolCallArgs := Obj.Get('tool_call_args', '');
      CallArr := TJSONArray(Obj.Find('calls'));
      if CallArr <> nil then
        for J := 0 to CallArr.Count - 1 do
        begin
          CObj := TJSONObject(CallArr[J]);
          CallId := CObj.Get('id', ''); CallName := CObj.Get('name', '');
          CallArgs := CObj.Get('arguments', '');
          M.AddToolCall(CallId, CallName, CallArgs).StreamIndex := CObj.Get('stream_index', -1);
        end;
    except
      FMessages.Delete(FMessages.Count - 1);
      raise;
    end;
  end;
end;

end.
