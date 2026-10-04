program test_registry;
{$mode objfpc}{$H+}
uses SysUtils, fpjson, uAgentTypes, uToolBase;
type
  TLegacyTool = class(TAgentTool)
    function Execute(const AArgsJSON: string): string; override;
  end;
function TLegacyTool.Execute(const AArgsJSON: string): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create(['root', CurrentToolContext.ProjectRoot]);
  try Result := O.AsJSON; finally O.Free; end;
end;
var T: TLegacyTool; Registry: TToolRegistry; C: TToolContext; O: TJSONObject; D: TJSONArray;
begin
  Registry := GetToolRegistry;
  T := TLegacyTool.Create('legacy_custom', 'Legacy extension without schema', nil);
  T.Aliases := 'old_custom'; Registry.RegisterTool(T);
  C := Default(TToolContext); C.ProjectRoot := '/tmp/context-project'; C.Mode := amAsk;
  O := ParseToolArgs(Registry.ExecuteTool('old_custom', '{}', C));
  try if O.Find('error') = nil then raise Exception.Create('Custom tools must default to Agent-only'); finally O.Free; end;
  C.Mode := amAgent;
  O := ParseToolArgs(Registry.ExecuteTool('old_custom', '{}', C));
  try if O.Get('root', '') <> C.ProjectRoot then raise Exception.Create('Legacy context wrapper failed'); finally O.Free; end;
  if CurrentToolContext.ProjectRoot = C.ProjectRoot then raise Exception.Create('Call context leaked');
  if Pos('legacy_custom', Registry.ToolGuidance(amAgent)) = 0 then raise Exception.Create('Nil-schema guidance failed');
  D := Registry.GetToolsDeclarationJSONArray(amAgent);
  try if D.Count <> 1 then raise Exception.Create('Aliases were advertised'); finally D.Free; end;
  O := ParseToolArgs(Registry.ExecuteTool('missing', '{}', C));
  try if O.Find('error') = nil then raise Exception.Create('Unknown tool must be an error'); finally O.Free; end;
  WriteLn('Custom-tool registry compatibility tests passed.');
end.
