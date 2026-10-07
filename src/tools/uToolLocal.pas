unit uToolLocal;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, uAgentTypes, fpjson, uToolBase;
procedure RegisterLocalTools;
implementation
uses uToolPaths, uToolProcess, uToolPatch, RegExpr, DateUtils, StrUtils;
type
  TLocalTool = class(TAgentTool)
    function Execute(const AArgsJSON: string): string; override;
  end;

function DirectoryTool(A: TJSONObject; Recursive: Boolean): string;
var Root, Pattern, Full, Rel: string; Hidden, Truncated: Boolean;
  Files: TStringList; Entries: TJSONArray; O, Entry: TJSONObject; R: TSearchRec; I: Integer;
begin
  Root := ResolveProjectPath(A.Get('path', '.'));
  if not DirectoryExists(Root) then raise Exception.Create('Directory does not exist: ' + Root);
  Hidden := A.Get('include_hidden', False); Pattern := A.Get('pattern', '**/*');
  if Recursive and (Pattern = '') then raise Exception.Create('pattern must not be empty');
  Files := TStringList.Create; Files.CaseSensitive := True; Entries := TJSONArray.Create; O := TJSONObject.Create;
  O.Add('entries', Entries); Truncated := False;
  try
    if Recursive then CollectFiles(Root, '', Hidden, Files)
    else if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faAnyFile, R) = 0 then
    try
      repeat
        if (R.Name = '.') or (R.Name = '..') then Continue;
        if not Hidden and (R.Name[1] = '.') then Continue;
        Files.Add(R.Name);
      until FindNext(R) <> 0;
    finally FindClose(R); end;
    Files.Sort;
    for I := 0 to Files.Count-1 do
    begin
      if ToolCancelled then raise Exception.Create('Tool cancelled');
      Rel := Files[I]; Full := IncludeTrailingPathDelimiter(Root) + Rel;
      if Recursive then Rel := StringReplace(ExtractRelativePath(IncludeTrailingPathDelimiter(CurrentToolContext.ProjectRoot), Full), DirectorySeparator, '/', [rfReplaceAll]);
      if Recursive and not GlobMatches(Pattern, Rel) then Continue;
      if Entries.Count = 500 then begin Truncated := True; Break; end;
      Entry := TJSONObject.Create(['path', Rel]);
      if IsPathLink(Full) then begin Entry.Add('type', 'symlink'); Entry.Add('size', 0); end
      else if DirectoryExists(ResolveProjectPath(Full)) then begin Entry.Add('type', 'directory'); Entry.Add('size', 0); end
      else
      begin
        Entry.Add('type', 'file');
        if FindFirst(Full, faAnyFile, R) = 0 then
        try Entry.Add('size', R.Size); finally FindClose(R); end;
      end;
      Entries.Add(Entry);
    end;
    O.Add('directory', Root); O.Add('total_entries', Entries.Count); O.Add('truncated', Truncated);
    Result := O.AsJSON;
  finally Files.Free; O.Free; end;
end;

function ShellTool(A: TJSONObject): string;
var Args: TStringList; O: TJSONObject; Command, Cwd: string;
begin
  Command := A.Get('command', ''); if Trim(Command) = '' then raise Exception.Create('command must not be empty');
  Cwd := ResolveProjectPath(A.Get('cwd', '.')); Args := TStringList.Create;
  try
    {$IFDEF UNIX}Args.Add('-c');{$ELSE}Args.Add('/S'); Args.Add('/C');{$ENDIF}
    Args.Add(Command);
    {$IFDEF UNIX}O := RunToolProcess('/bin/sh', Args, Cwd, A.Get('timeout_ms', 120000), True);
    {$ELSE}O := RunToolProcess('cmd.exe', Args, Cwd, A.Get('timeout_ms', 120000), True);{$ENDIF}
    try O.Add('refresh_project', True); Result := O.AsJSON; finally O.Free; end;
  finally Args.Free; end;
end;

function SearchTool(A: TJSONObject): string;
var Files: TStringList; O, Match: TJSONObject; Matches: TJSONArray;
  I, LineNo, StartAt, MatchPos, K, LineLength, LineCapacity: Integer;
  Root, SearchRoot, Query, Path, FullPath, LowerQuery, LineText, LowerLine: string;
  Stream: TFileStream; RawLine: RawByteString; Buffer: array[0..65535] of Byte;
  N, B: Integer;
  Regex: TRegExpr; Truncated, IsDirectory, BinaryFile: Boolean;
  procedure AddMatch(const APath, AText: string; ALine, AColumn: Integer);
  begin
    if Matches.Count >= 500 then begin Truncated := True; Exit; end;
    Match := TJSONObject.Create(['path', APath, 'line', ALine,
      'column', AColumn, 'text', TrimRight(AText)]);
    Matches.Add(Match);
  end;
  procedure ScanLine(const ALine: RawByteString);
  begin
    Inc(LineNo);
    LineText := SafeToolText(ALine);
    if not A.Get('regex', False) and not A.Get('case_sensitive', True) then
      LowerLine := AnsiLowerCase(LineText);
    if A.Get('regex', False) then
    begin
      if Regex.Exec(LineText) then
      begin
        repeat
          if ToolCancelled then raise Exception.Create('Tool cancelled');
          MatchPos := Regex.MatchPos[0];
          AddMatch(Path, LineText, LineNo, MatchPos);
          if Truncated then Exit;
        until not Regex.ExecNext;
      end;
    end
    else
    begin
      StartAt := 1;
      while StartAt <= Length(LineText) do
      begin
        if ToolCancelled then raise Exception.Create('Tool cancelled');
        if A.Get('case_sensitive', True) then
          K := PosEx(Query, LineText, StartAt)
        else
          K := PosEx(LowerQuery, LowerLine, StartAt);
        if K = 0 then Break;
        MatchPos := K;
        AddMatch(Path, LineText, LineNo, MatchPos);
        if Truncated then Exit;
        StartAt := MatchPos + Length(Query);
      end;
    end;
  end;
begin
  Root := CurrentToolContext.ProjectRoot;
  SearchRoot := ResolveProjectPath(A.Get('path', '.')); Query := A.Get('query', '');
  if Query = '' then raise Exception.Create('query must not be empty');
  Files := TStringList.Create; Files.CaseSensitive := True;
  Matches := TJSONArray.Create; O := TJSONObject.Create; O.Add('matches', Matches);
  Regex := nil; Truncated := False;
  try
    if A.Get('regex', False) then
    begin
      Regex := TRegExpr.Create;
      Regex.Expression := Query;
      Regex.ModifierI := not A.Get('case_sensitive', True);
    end
    else if not A.Get('case_sensitive', True) then LowerQuery := AnsiLowerCase(Query);

    IsDirectory := DirectoryExists(SearchRoot);
    if IsDirectory then CollectFiles(SearchRoot, '', A.Get('include_hidden', False), Files)
    else if FileExists(SearchRoot) then Files.Add(ExtractFileName(SearchRoot))
    else raise Exception.Create('Search path does not exist: ' + SearchRoot);
    Files.Sort;
    for I := 0 to Files.Count-1 do
    begin
      if ToolCancelled then raise Exception.Create('Tool cancelled');
      if IsDirectory then FullPath := IncludeTrailingPathDelimiter(SearchRoot) + Files[I]
      else FullPath := SearchRoot;
      Path := StringReplace(ExtractRelativePath(IncludeTrailingPathDelimiter(Root), FullPath),
        DirectorySeparator, '/', [rfReplaceAll]);
      if (A.Get('glob', '') <> '') and not GlobMatches(A.Get('glob', ''), Path) then Continue;
      Stream := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyWrite);
      try
        { Ignore binary files, matching ripgrep's default treatment of NUL bytes. }
        BinaryFile := False;
        while Stream.Position < Stream.Size do
        begin
          if ToolCancelled then raise Exception.Create('Tool cancelled');
          N := Stream.Read(Buffer, SizeOf(Buffer));
          for B := 0 to N-1 do if Buffer[B] = 0 then begin BinaryFile := True; Break; end;
          if BinaryFile then Break;
        end;
        if BinaryFile then Continue;
        Stream.Position := 0; LineNo := 0; RawLine := '';
        LineLength := 0; LineCapacity := 0;
        while Stream.Position < Stream.Size do
        begin
          if ToolCancelled then raise Exception.Create('Tool cancelled');
          N := Stream.Read(Buffer, SizeOf(Buffer));
          for B := 0 to N-1 do
          begin
            if Buffer[B] = 10 then
            begin
              if (LineLength > 0) and (RawLine[LineLength] = #13) then Dec(LineLength);
              SetLength(RawLine, LineLength); ScanLine(RawLine);
              SetLength(RawLine, LineCapacity); LineLength := 0;
              if Truncated then Break;
            end
            else
            begin
              if LineLength >= LineCapacity then
              begin
                if LineCapacity = 0 then LineCapacity := 256 else LineCapacity := LineCapacity * 2;
                SetLength(RawLine, LineCapacity);
              end;
              Inc(LineLength); RawLine[LineLength] := AnsiChar(Buffer[B]);
            end;
          end;
          if Truncated then Break;
        end;
        if not Truncated and (LineLength > 0) then
        begin SetLength(RawLine, LineLength); ScanLine(RawLine); end;
      finally Stream.Free; end;
      if Truncated then Break;
    end;
    O.Add('total_matches', Matches.Count); O.Add('truncated', Truncated);
    Result := O.AsJSON;
  finally Files.Free; Regex.Free; O.Free; end;
end;

function GitTool(A: TJSONObject): string;
var Args: TStringList; O: TJSONObject; Paths: TJSONArray; I, Limit: Integer; Op, Rev: string;
begin
  Op := A.Get('operation', ''); Rev := A.Get('revision', '');
  if not ((Op = 'status') or (Op = 'diff') or (Op = 'log') or (Op = 'show')) then raise Exception.Create('Unsupported Git operation');
  if (Rev <> '') and ((Rev[1] = '-') or (Pos(#0, Rev) > 0)) then raise Exception.Create('Invalid Git revision');
  Limit := A.Get('limit', 20); if (Limit < 1) or (Limit > 100) then raise Exception.Create('limit must be 1..100');
  Args := TStringList.Create;
  try
    Args.Add('--no-pager'); Args.Add('--no-optional-locks');
    Args.Add('-c'); Args.Add('core.fsmonitor=false'); Args.Add(Op);
    if Op = 'status' then Args.Add('--porcelain=v1');
    if (Op = 'diff') or (Op = 'show') then begin Args.Add('--no-ext-diff'); Args.Add('--no-textconv'); end;
    if (Op = 'diff') and A.Get('staged', False) then Args.Add('--cached');
    if Op = 'log' then begin Args.Add('-n'); Args.Add(IntToStr(Limit)); end;
    if (Op = 'status') and (Rev <> '') then raise Exception.Create('status does not accept a revision');
    if Rev <> '' then Args.Add(Rev);
    Args.Add('--'); Paths := A.Find('paths') as TJSONArray;
    if Assigned(Paths) then for I := 0 to Paths.Count-1 do
    begin
      if Paths[I].JSONType <> jtString then raise Exception.Create('paths must contain strings');
      Args.Add(ResolveProjectPath(Paths.Strings[I]));
    end;
    try O := RunToolProcess('git', Args, CurrentToolContext.ProjectRoot);
    except on E: Exception do raise Exception.Create('Cannot run Git; ensure git is installed. ' + E.Message); end;
    try
      if O.Get('exit_code', 0) <> 0 then O.Add('error', 'Git inspection failed: ' + O.Get('stderr', ''));
      Result := O.AsJSON;
    finally O.Free; end;
  finally Args.Free; end;
end;

function DiagnosticTool(A: TJSONObject): string;
var C: TToolContext; Action, Target, Ext, Exe, Text, Line, Severity: string;
  Args, Lines: TStringList; O, D: TJSONObject; Messages: TJSONArray; R, General: TRegExpr; I: Integer;
begin
  C := CurrentToolContext; if C.Session = nil then raise Exception.Create('Diagnostics require a chat session');
  Action := A.Get('action', 'read');
  if Action = 'read' then
  begin
    if (C.Session.Diagnostics.Count = 0) or (C.Session.Diagnostics.Get('project_root', '') <> C.ProjectRoot) then
      Exit('{"status":"unavailable","message":"No compiler diagnostics for the active project yet."}');
    Exit(C.Session.Diagnostics.AsJSON);
  end;
  if Action <> 'build' then raise Exception.Create('action must be read or build');
  if C.Mode <> amAgent then raise Exception.Create('Diagnostic builds require Agent mode');
  Target := A.Get('target', ''); if Target = '' then raise Exception.Create('Build requires an explicit target');
  Target := ResolveProjectPath(Target); if not FileExists(Target) then raise Exception.Create('Build target does not exist');
  Ext := LowerCase(ExtractFileExt(Target));
  if (Ext = '.lpi') or (Ext = '.lpk') then Exe := 'lazbuild'
  else if (Ext = '.pas') or (Ext = '.lpr') then Exe := 'fpc'
  else raise Exception.Create('Unsupported build target; use .lpi, .lpk, .pas, or .lpr');
  Args := TStringList.Create; Lines := TStringList.Create; R := TRegExpr.Create; General := TRegExpr.Create;
  try
    Args.Add(Target);
    try
      O := RunToolProcess(Exe, Args, C.ProjectRoot, A.Get('timeout_ms', 120000), True);
    except
      on E: Exception do
        raise Exception.Create('Cannot start ' + Exe + ' for ' + Target +
          '; check that the matching Free Pascal/Lazarus tools are installed and ' +
          Exe + ' is available on PATH. Process error: ' + E.Message);
    end;
    try
      O.Add('project_root', C.ProjectRoot); O.Add('target', Target);
      O.Add('compiler', Exe);
      O.Add('timestamp', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', LocalTimeToUniversal(Now))); O.Add('refresh_project', True);
      Messages := TJSONArray.Create; O.Add('messages', Messages);
      Text := O.Get('stdout', '') + LineEnding + O.Get('stderr', ''); Lines.Text := Text;
      R.Expression := '^(.+)\(([0-9]+),([0-9]+)\)\s*(Fatal|Error|Warning|Note|Hint):\s*(.*)$';
      General.Expression := '^(Fatal|Error|Warning|Note|Hint):\s*(.*)$';
      for I := 0 to Lines.Count-1 do
      begin
        Line := Trim(Lines[I]);
        if R.Exec(Line) then
        begin
          Severity := LowerCase(R.Match[4]);
          D := TJSONObject.Create(['path', R.Match[1], 'line', StrToInt(R.Match[2]),
            'column', StrToInt(R.Match[3]), 'severity', Severity, 'message', R.Match[5]]);
          Messages.Add(D);
        end
        else if General.Exec(Line) then
          Messages.Add(TJSONObject.Create(['severity', LowerCase(General.Match[1]), 'message', General.Match[2]]));
      end;
      if O.Get('timed_out', False) or O.Get('cancelled', False) then O.Add('status', 'incomplete')
      else if O.Get('exit_code', 0) = 0 then O.Add('status', 'success') else O.Add('status', 'failed');
      D := O.Clone as TJSONObject; C.Session.Diagnostics.Free; C.Session.Diagnostics := D;
      Result := O.AsJSON;
    finally O.Free; end;
  finally Args.Free; Lines.Free; R.Free; General.Free; end;
end;

function TodoTool(A: TJSONObject): string;
var C: TToolContext; Items, CopyItems: TJSONArray; Item: TJSONObject; IDs: TStringList;
  I: Integer; Action, ID, Status: string; O: TJSONObject;
begin
  C := CurrentToolContext; if C.Session = nil then raise Exception.Create('Task tracking requires a chat session');
  Action := A.Get('action', 'read');
  if Action = 'replace' then
  begin
    Items := A.Find('items') as TJSONArray;
    if Items = nil then raise Exception.Create('replace requires items');
    if Items.Count > 100 then raise Exception.Create('At most 100 tasks are supported');
    IDs := TStringList.Create;
    try
      for I := 0 to Items.Count-1 do
      begin
        if not (Items[I] is TJSONObject) then raise Exception.Create('Task must be an object');
        Item := TJSONObject(Items[I]);
        if (Item.Find('id') = nil) or (Item.Find('text') = nil) or (Item.Find('status') = nil) then raise Exception.Create('Task requires id, text, and status');
        if (Item.Types['id'] <> jtString) or (Item.Types['text'] <> jtString) or (Item.Types['status'] <> jtString) then raise Exception.Create('Task fields must be strings');
        ID := Item.Get('id', ''); Status := Item.Get('status', '');
        if (Trim(ID) = '') or (Trim(Item.Get('text', '')) = '') or (IDs.IndexOf(ID) >= 0) then raise Exception.Create('Task IDs must be nonempty and unique; text is required');
        if not ((Status = 'pending') or (Status = 'in_progress') or (Status = 'completed')) then raise Exception.Create('Invalid task status');
        IDs.Add(ID);
      end;
      CopyItems := Items.Clone as TJSONArray; C.Session.Tasks.Free; C.Session.Tasks := CopyItems;
    finally IDs.Free; end;
  end
  else if Action <> 'read' then raise Exception.Create('action must be read or replace');
  O := TJSONObject.Create; O.Add('items', C.Session.Tasks.Clone);
  try Result := O.AsJSON; finally O.Free; end;
end;

function TLocalTool.Execute(const AArgsJSON: string): string;
var A: TJSONObject;
begin
  A := ParseToolArgs(AArgsJSON);
  try
    case Name of
      'list_directory': Result := DirectoryTool(A, False);
      'glob': Result := DirectoryTool(A, True);
      'search_code': Result := SearchTool(A);
      'shell': Result := ShellTool(A);
      'git': Result := GitTool(A);
      'diagnostics': Result := DiagnosticTool(A);
      'todo': Result := TodoTool(A);
      else raise Exception.Create('Unknown local tool');
    end;
  finally A.Free; end;
end;

procedure AddTool(const Name, Description, Properties, Required, Aliases: string; ReadOnly: Boolean);
var T: TLocalTool;
begin
  T := TLocalTool.Create(Name, Description,
    ParseToolArgs('{"type":"object","properties":' + Properties + ',"required":' + Required + '}'));
  T.Aliases := Aliases; T.MutatesFiles := not ReadOnly;
  if ReadOnly then T.AllowedModes := [amAsk, amPlan, amAgent];
  GetToolRegistry.RegisterTool(T);
end;
procedure RegisterLocalTools;
begin
  AddTool('list_directory', 'List immediate file and directory entries, sorted and capped at 500.',
    '{"path":{"type":"string"},"include_hidden":{"type":"boolean"}}', '[]', '', True);
  AddTool('glob', 'Find files by project-relative wildcard pattern (*, ?, **), sorted and capped at 500.',
    '{"pattern":{"type":"string"},"path":{"type":"string"},"include_hidden":{"type":"boolean"}}', '["pattern"]', '', True);
  AddTool('search_code', 'Search project text natively; supports literal or common regular-expression searches and returns file, line, byte column and matching text, capped at 500.',
    '{"query":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"regex":{"type":"boolean"},"case_sensitive":{"type":"boolean"},"include_hidden":{"type":"boolean"}}', '["query"]', 'grep', True);
  {$IFDEF UNIX}
  AddTool('shell', 'Run a command via /bin/sh -c in the project. Default timeout 120000ms, maximum 600000ms; normal OS permissions apply.',
  {$ELSE}
  AddTool('shell', 'Run a command via cmd.exe /C in the project. Default timeout 120000ms, maximum 600000ms; normal OS permissions apply.',
  {$ENDIF}
    '{"command":{"type":"string"},"cwd":{"type":"string"},"timeout_ms":{"type":"integer"}}', '["command"]', 'terminal', False);
  AddTool('git', 'Inspect Git status, diff, log or show. No mutating operations. limit is 1..100.',
    '{"operation":{"type":"string","enum":["status","diff","log","show"]},"revision":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"limit":{"type":"integer"},"staged":{"type":"boolean"}}', '["operation"]', '', True);
  AddTool('diagnostics', 'Read cached compiler diagnostics; Agent mode can build an explicit .lpi/.lpk/.pas/.lpr target.',
    '{"action":{"type":"string","enum":["read","build"]},"target":{"type":"string"},"timeout_ms":{"type":"integer"}}', '["action"]', '', True);
  AddTool('todo', 'Read or replace chat-local tasks; use stable IDs and pending, in_progress or completed status.',
    '{"action":{"type":"string","enum":["read","replace"]},"items":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"text":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["id","text","status"]}}}', '["action"]', 'plan', True);
end;
initialization
  RegisterLocalTools;
end.
