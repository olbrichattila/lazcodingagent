program test_file_notifications;
{$mode objfpc}{$H+}
uses Classes, SysUtils, fpjson, uAgentTypes, uToolBase, uToolPaths,
  uToolFileOps, uToolLocal;
type
  TObserver = class
    Paths: TStringList;
    Root, NextPath, NextContent: string;
    CancelAfterChange, Cancelled, FailNotification: Boolean;
    procedure Changed(const Path: string);
    function IsCancelled: Boolean;
  end;
procedure Check(Value: Boolean; const Msg: string);
begin if not Value then raise Exception.Create(Msg); end;
procedure TObserver.Changed(const Path: string);
begin
  Paths.Add(Path);
  Check(GetCurrentThreadID = MainThreadID, 'Unexpected callback thread');
  if (NextPath <> '') and (Paths.Count = 1) then
    Check(ReadTextBytes(NextPath) = NextContent, 'Next patch file committed before notification');
  if CancelAfterChange then Cancelled := True;
  if FailNotification then raise Exception.Create('fixture notification error');
end;
function TObserver.IsCancelled: Boolean;
begin Result := Cancelled; end;
var C: TToolContext; Observer: TObserver; O: TJSONObject;
  A, B, Patch, Root: string; Files: TStringList;
  procedure Execute(const Name, JSON: string; ExpectError: Boolean = False);
  begin
    O := ParseToolArgs(GetToolRegistry.ExecuteTool(Name, JSON, C));
    Check((O.Find('error') <> nil) = ExpectError, Name + ': ' + O.AsJSON);
  end;
  function WriteArgs(const Path, Content: string): string;
  var D: TJSONObject;
  begin
    D := TJSONObject.Create(['path', Path, 'content', Content]);
    try Result := D.AsJSON; finally D.Free; end;
  end;
  function PatchArgs(const Text: string): string;
  var D: TJSONObject;
  begin
    D := TJSONObject.Create(['patch', Text]);
    try Result := D.AsJSON; finally D.Free; end;
  end;
begin
  Root := IncludeTrailingPathDelimiter(ParamStr(1));
  SetEffectiveProjectDir(Root);
  C := Default(TToolContext); C.Mode := amAgent; C.ProjectRoot := Root;
  Check(ResolveProjectPath('') = ExcludeTrailingPathDelimiter(ExpandFileName(Root)),
    'Project root did not canonicalize');
  Check(ResolveProjectPath('relative.txt') = ExpandFileName(Root + 'relative.txt'),
    'Relative project path did not resolve');
  try
    ResolveProjectPath('..' + DirectorySeparator + 'outside.txt');
    raise Exception.Create('Parent traversal escaped project confinement');
  except on E: Exception do
    if Pos('Path escapes', E.Message) = 0 then raise;
  end;
  {$IFDEF WINDOWS}
  try
    ResolveProjectPath('\\server\share\outside.txt');
    raise Exception.Create('UNC path escaped project confinement');
  except on E: Exception do
    if Pos('Path escapes', E.Message) = 0 then raise;
  end;
  {$ENDIF}
  Observer := TObserver.Create; Observer.Paths := TStringList.Create;
  C.OnFileChanged := @Observer.Changed; C.IsCancelled := @Observer.IsCancelled;
  A := Root + 'a.pas'; B := Root + 'b.pas';
  try
    Execute('write_file', WriteArgs(A, 'old' + #10)); O.Free;
    Files := TStringList.Create;
    try
      CollectFiles(Root, '', True, Files);
      Check(Files.IndexOf('a.pas') >= 0, 'Recursive file enumeration missed a project file');
    finally Files.Free; end;
    Check(Observer.Paths.Count = 1, 'Write callback missing');
    Execute('write_file', WriteArgs(A, 'old' + #10)); O.Free;
    Check(Observer.Paths.Count = 2, 'Repeated write notification missing');
    Execute('write_file', WriteArgs(B, 'old' + #10)); O.Free;
    Observer.Paths.Clear; Observer.NextPath := B; Observer.NextContent := 'old' + #10;
    Patch := '--- a/a.pas' + #10 + '+++ b/a.pas' + #10 + '@@ -1 +1 @@' + #10 +
      '-old' + #10 + '+new' + #10 + '--- a/b.pas' + #10 + '+++ b/b.pas' + #10 +
      '@@ -1 +1 @@' + #10 + '-old' + #10 + '+new' + #10;
    Execute('apply_patch', PatchArgs(Patch)); O.Free;
    Check((Observer.Paths.Count = 2) and (Observer.Paths[0] = A) and
      (Observer.Paths[1] = B), 'Patch callback order incorrect');
    Observer.NextPath := ''; Observer.Paths.Clear;
    Execute('apply_patch', PatchArgs(Patch), True); O.Free;
    Check(Observer.Paths.Count = 0, 'Invalid patch sent notifications');
    Execute('write_file', WriteArgs(A, 'old' + #10)); O.Free;
    Execute('write_file', WriteArgs(B, 'old' + #10)); O.Free;
    Observer.Paths.Clear; Observer.CancelAfterChange := True;
    Execute('apply_patch', PatchArgs(Patch), True);
    Check(O.Get('partial', False), 'Partial cancellation missing'); O.Free;
    Check((Observer.Paths.Count = 1) and (ReadTextBytes(A) = 'new' + #10) and
      (ReadTextBytes(B) = 'old' + #10), 'Cancellation lost per-file boundary');
    Observer.CancelAfterChange := False; Observer.Cancelled := False;
    Observer.Paths.Clear;
    Execute('edit_file', '{"path":"a.pas","old_text":"new","new_text":"edited"}'); O.Free;
    Check((Observer.Paths.Count = 1) and (ReadTextBytes(A) = 'edited' + #10), 'Exact edit callback missing');
    Observer.Paths.Clear;
    Execute('apply_patch', PatchArgs('--- a/a.pas' + #10 + '+++ /dev/null' + #10 +
      '@@ -1 +0,0 @@' + #10 + '-edited' + #10)); O.Free;
    Check((Observer.Paths.Count = 1) and not FileExists(A), 'Delete callback missing');
    Observer.FailNotification := True;
    Execute('write_file', WriteArgs(A, 'saved' + #10));
    Check(Pos('fixture notification error', O.Get('tracking_warning', '')) > 0,
      'Callback failure lost warning'); O.Free;
    Check(ReadTextBytes(A) = 'saved' + #10, 'Callback failure changed write result');
    C.Mode := amPlan; Observer.Paths.Clear;
    Execute('write_file', WriteArgs(A, 'denied'), True); O.Free;
    Check(Observer.Paths.Count = 0, 'Denied write sent notification');
    Check(not Assigned(CurrentToolContext.OnFileChanged), 'Callback leaked beyond tool context');
    WriteLn('Per-file commit notification tests passed.');
  finally
    Observer.Paths.Free; Observer.Free;
    DeleteFile(A); DeleteFile(B);
  end;
end.
