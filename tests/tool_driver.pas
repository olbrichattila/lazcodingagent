program tool_driver;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Classes, SysUtils, fpjson,
  uAgentTypes, uToolBase, uToolFileOps, uToolLocal;
type TCancel = class
  Deadline: QWord;
  function Cancelled: Boolean;
end;
function TCancel.Cancelled: Boolean;
begin Result := (Deadline > 0) and (GetTickCount64 >= Deadline); end;
var Line, Name, Args: string; A: TJSONObject; C: TToolContext; Cancel: TCancel; D: TJSONArray;
begin
  C := Default(TToolContext); C.ProjectRoot := ParamStr(1); C.Session := TToolSession.Create;
  Cancel := TCancel.Create; C.IsCancelled := @Cancel.Cancelled;
  try
    while not EOF(Input) do
    begin
      ReadLn(Line);
      try
        A := ParseToolArgs(Line);
        try
          C.Mode := StringToMode(A.Get('mode', 'Agent')); Name := A.Get('tool', '');
          Cancel.Deadline := 0;
          if A.Get('cancel_after_ms', 0) > 0 then Cancel.Deadline := GetTickCount64 + QWord(A.Get('cancel_after_ms', 0));
          if Name = '_clear' then begin C.Session.Clear; WriteLn('{}'); end
          else if Name = '_declarations' then
          begin D := GetToolRegistry.GetToolsDeclarationJSONArray(C.Mode); try WriteLn(D.AsJSON); finally D.Free; end; end
          else if Name = '_fallback' then
          begin
            if FallbackExtractToolCall(A.Get('text', ''), Name, Args) then WriteLn(GetToolRegistry.ExecuteTool(Name, Args, C))
            else WriteLn(ToolError('No fallback call'));
          end
          else
          begin
            if A.Find('args') = nil then Args := '{}'
            else if A.Types['args'] = jtString then Args := A.Get('args', '{}') else Args := A.Find('args').AsJSON;
            WriteLn(GetToolRegistry.ExecuteTool(Name, Args, C));
          end;
        finally A.Free; end;
      except on E: Exception do WriteLn(ToolError(E.Message)); end;
      Flush(Output);
    end;
  finally C.Session.Free; Cancel.Free; end;
end.
