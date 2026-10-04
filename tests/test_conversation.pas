program test_conversation;
{$mode objfpc}{$H+}
uses Classes, SysUtils, fpjson, uAgentTypes, uAgentHistory, uAgentConfig,
  uLLMAdapter, uLLMClient, uAgentContext;
procedure Check(B: Boolean; const S: string);
begin if not B then raise Exception.Create(S); end;
var H, CopyHistory: TAgentHistory; M, R: TChatMessage; A: TChatCompletionsAdapter;
  Request: TJSONObject;
  JSON: TJSONArray; SSE: TSSEStream; S: string; Est: TApproximateContextEstimator;
  Cfg: TAgentConfig; Failed: Boolean;
procedure Emit(const Line: string);
var Bytes: string;
begin Bytes := 'data: ' + Line + #10#10; SSE.Write(Bytes[1], Length(Bytes)); end;
begin
  H := TAgentHistory.Create; A := TChatCompletionsAdapter.Create;
  Est := TApproximateContextEstimator.Create;
  try
    H.AddMessage(mrSystem, 'Persistent system');
    H.AddMessage(mrUser, 'first');
    M := TChatMessage.Create(mrAssistant, 'Inspecting');
    try
      M.AddToolCall('one', 'read_file', '{"path":"one.pas"}');
      M.AddToolCall('', 'todo', '{"action":"read"}');
      R := H.AppendAssistant(M);
    finally M.Free; end;
    Check(R.ToolCalls.Count = 2, 'All assistant calls retained');
    S := R.ToolCalls[1].Id;
    Check(S <> '', 'Missing ID generated');
    H.AddToolResult('one', 'read_file', 'file content');
    H.AddToolResult(S, 'todo', '[]');
    H.AddToolResult(S, 'todo', '[]');
    Check(H.Count = 5, 'Repeated tool result is idempotent');
    H.AddMessage(mrAssistant, 'first answer');
    H.AddMessage(mrUser, 'second'); H.AddMessage(mrAssistant, 'second answer');
    H.AddMessage(mrUser, 'third');
    Check(H.CompactablePrefix(2) = 0, 'Two previous turns and current protected');
    Check(H.CompactablePrefix(1) = 6, 'Whole first turn eligible');
    CopyHistory := H.Clone;
    try
      CopyHistory.GetMessage(2).ToolCalls[0].Name := 'changed';
      Check(H.GetMessage(2).ToolCalls[0].Name = 'read_file', 'Deep clone ownership');
    finally CopyHistory.Free; end;
    JSON := A.Messages(H, 'Mode system');
    try
      Check(JSON.Objects[2].Get('content', '') = 'first', 'Chronology');
      Check(JSON.Objects[3].Get('content', '') = 'Inspecting', 'Assistant text alongside calls');
      Check(JSON.Objects[3].Arrays['tool_calls'].Count = 2, 'Serialization all calls');
      Check(JSON.Objects[5].Get('tool_call_id', '') = S, 'Result linkage');
      Check(Est.Estimate(JSON, 'tools') > 0, 'Approximate size');
    finally JSON.Free; end;
    Failed := False;
    try H.ReplacePrefix(3, 'Unsafe split'); except Failed := True; end;
    Check(Failed and (H.Count = 9) and (H.Summary = ''), 'Split turn compaction rejected');
    H.ReplacePrefix(6, 'Engineering summary');
    Check(H.GetMessage(0).Role = mrSystem, 'System instructions protected');
    Check(H.GetMessage(1).Content = 'second', 'Recent messages verbatim');
    JSON := A.Messages(H, 'Mode system');
    try
      Check(JSON.Objects[1].Get('role', '') = 'system', 'System before summary');
      Check(Pos('Engineering summary', JSON.Objects[2].Get('content', '')) > 0, 'Summary before recent turns');
    finally JSON.Free; end;
    H.Block(32768, 2);
    Check(not H.PromptAdmissionAllowed(32768, 2), 'Size failure blocks growth');
    Check(H.PromptAdmissionAllowed(65536, 2), 'Changed budget can be checked');
    H.Clear; Check((H.Count = 0) and (H.Summary = ''), 'Clear resets state');
    Check(H.PromptAdmissionAllowed(32768, 2), 'Clear unblocks');
    M := H.AddMessage(mrAssistant, ''); M.AddToolCall('empty', 'todo', '{"action":"read"}');
    H.AddToolResult('empty', 'todo', '[]');
    JSON := A.Messages(H, '');
    try Check(JSON.Objects[0].Types['content'] = jtNull, 'Empty content tool call'); finally JSON.Free; end;
    Request := A.BuildRequest(TJSONArray.Create, nil, 'o3-mini', lpOpenAI, False, 2048);
    try
      Check(Request.Get('max_completion_tokens', 0) = 2048, 'OpenAI completion-token limit');
      Check(Request.Find('max_tokens') = nil, 'No incompatible legacy token limit for OpenAI');
    finally Request.Free; end;
  SSE := TSSEStream.Create(nil);
    try
      Emit('{"choices":[{"delta":{"reasoning_content":"SECRET_REASONING","tool_calls":[{"index":1,"id":"two","function":{"name":"todo","arguments":"{"}}]}}]}');
      Emit('{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"one","function":{"name":"read_","arguments":"{\"path\":"}}]}}]}');
      Emit('{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"two","function":{"name":"todo","arguments":"\"action\":\"read\"}"}},{"index":0,"function":{"name":"file","arguments":"\"one.pas\"}"}}]}}]}');
      Failed := False;
      try R := SSE.Response; R.Free; except Failed := True; end;
      Check(Failed, 'Incomplete stream rejected');
      Emit('[DONE]'); R := SSE.Response;
      try
        A.ValidateResponse(R);
        Check(R.ToolCalls[0].Name = 'read_file', 'Interleaved stream index ordering');
        Check(R.ToolCalls[1].Id = 'two', 'Repeated stream ID not duplicated');
        Check(R.Content = '', 'Reasoning excluded');
      finally R.Free; end;
    finally SSE.Free; end;
    SSE := TSSEStream.Create(nil);
    try
      Emit('{"choices":[{"delta":{"content":"partial"},"finish_reason":"stop"}]}');
      R := SSE.Response;
      try Check(R.Content = 'partial', 'Terminal stop completes stream without DONE');
      finally R.Free; end;
    finally SSE.Free; end;
    SSE := TSSEStream.Create(nil);
    try
      Emit('{"choices":[{"delta":{"content":"partial"}}]}');
      Failed := False;
      try R := SSE.Response; R.Free; except on E: Exception do
        begin Failed := Pos('missing data: [DONE]', E.Message) > 0; end; end;
      Check(Failed, 'Missing terminator without terminal finish reason rejected');
    finally SSE.Free; end;
    SSE := TSSEStream.Create(nil);
    try
      Emit('{"choices":[{"delta":{},"finish_reason":"length"}]}'); Emit('[DONE]');
      Failed := False;
      try R := SSE.Response; R.Free; except on E: Exception do
        begin Failed := Pos('finish_reason="length"', E.Message) > 0; end; end;
      Check(Failed, 'Unsupported stream finish reason reported');
    finally SSE.Free; end;
    SSE := TSSEStream.Create(nil);
    try
      Emit('{broken');
      Failed := False;
      try R := SSE.Response; R.Free; except on E: Exception do
        begin Failed := (Pos('Invalid streaming response:', E.Message) = 1) and
          (Pos('Incomplete or invalid', E.Message) = 0); end; end;
      Check(Failed, 'Malformed stream event reports parser error');
    finally SSE.Free; end;
    SSE := TSSEStream.Create(nil);
    try
      Emit('{"error":{"message":"quota exceeded"}}');
      Failed := False;
      try R := SSE.Response; R.Free; except on E: Exception do
        begin Failed := Pos('Provider stream error: quota exceeded', E.Message) > 0; end; end;
      Check(Failed, 'Provider stream error is preserved');
    finally SSE.Free; end;
    H.Clear; H.AddMessage(mrTool, 'orphan').ToolCallId := 'missing';
    Failed := False;
    try JSON := A.Messages(H, ''); JSON.Free; except Failed := True; end;
    Check(Failed, 'Orphan tool results rejected before serialization');
    Cfg := TAgentConfig.Create;
    try
      Cfg.ContextBudget := 45678; Cfg.RecentTurns := 3; Cfg.Save;
      Cfg.ContextBudget := 32768; Cfg.RecentTurns := 2; Cfg.Load;
      Check((Cfg.ContextBudget = 45678) and (Cfg.RecentTurns = 3), 'Context settings roundtrip');
      Cfg.ContextBudget := -1; Cfg.RecentTurns := 999; Cfg.Save; Cfg.Load;
      Check((Cfg.ContextBudget = 32768) and (Cfg.RecentTurns = 2), 'Invalid INI defaults');
    finally Cfg.Free; end;
  finally Est.Free; A.Free; H.Free; end;
  WriteLn('Conversation model, SSE and settings tests passed.');
end.
