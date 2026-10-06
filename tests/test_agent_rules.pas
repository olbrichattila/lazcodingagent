program test_agent_rules;
{$mode objfpc}{$H+}
uses Classes, SysUtils, uAgentRules;
var Root, Dir, Path: string; Files: TStringList; Combined: string;
begin
  if ParamCount <> 1 then raise Exception.Create('Expected project root argument.');
  Root := ExpandFileName(ParamStr(1));
  if TAgentRules.ReadAll(Root + '-empty') <> '' then
    raise Exception.Create('A project without rules should contribute no prompt text.');
  Dir := TAgentRules.DirectoryForProject(Root);
  if not ForceDirectories(Dir) then raise Exception.Create('Could not create fixture .rules folder.');
  TAgentRules.WriteFile(IncludeTrailingPathDelimiter(Dir) + 'a.md', 'First rule.');
  TAgentRules.WriteFile(IncludeTrailingPathDelimiter(Dir) + 'z.md', 'Last rule.');
  Files := TStringList.Create;
  try
    TAgentRules.ListFiles(Root, Files);
    if Files.Count <> 2 then raise Exception.Create('Rule file listing failed.');
    if ExtractFileName(Files[0]) <> 'a.md' then raise Exception.Create('Rules are not sorted by filename.');
    Combined := TAgentRules.ReadAll(Root);
    if (Pos('First rule.', Combined) = 0) or (Pos('Last rule.', Combined) <= Pos('First rule.', Combined)) then
      raise Exception.Create('Rules were not combined in filename order.');
    Path := TAgentRules.CreateRule(Root, 'Generated rule.');
    if not FileExists(Path) or (TAgentRules.ReadFile(Path) <> 'Generated rule.') then
      raise Exception.Create('Generated rule file persistence failed.');
    TAgentRules.WriteFile(Path, 'Updated rule.');
    if TAgentRules.ReadFile(Path) <> 'Updated rule.' then raise Exception.Create('Rule update failed.');
    if not DeleteFile(Path) then raise Exception.Create('Rule deletion failed.');
  finally
    Files.Free;
  end;
  WriteLn('Agent rule tests passed.');
end.
