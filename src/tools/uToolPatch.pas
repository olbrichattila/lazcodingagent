unit uToolPatch;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, fpjson, uToolBase;
type
  TToolApplyPatch = class(TAgentTool)
    constructor Create;
    function Execute(const AArgsJSON: string): string; override;
  end;
  TToolEditFile = class(TAgentTool)
    constructor Create;
    function Execute(const AArgsJSON: string): string; override;
  end;
implementation
uses uToolPaths, RegExpr, {$IFDEF UNIX}BaseUnix{$ELSE}Windows{$ENDIF};
type
  EPatchError = class(Exception)
  public
    ErrorKind, ErrorPath: string;
    ErrorLine: Integer;
    constructor Create(const AKind, AMessage, APath: string; ALine: Integer = 0);
  end;
  TStagedEdit = class
    Path, TempPath: string;
    Original, Content: RawByteString;
    Remove, CreateFile: Boolean;
    destructor Destroy; override;
  end;
destructor TStagedEdit.Destroy;
begin if TempPath <> '' then SysUtils.DeleteFile(TempPath); inherited Destroy; end;

procedure PatchRaise(const AKind, AMessage, APath: string; ALine: Integer = 0); forward;

procedure SplitLines(const S: RawByteString; Lines, Endings: TStrings);
var I, Start: Integer; E: string;
begin
  I := 1; Start := 1;
  while I <= Length(S) do
  begin
    if S[I] in [#10, #13] then
    begin
      Lines.Add(Copy(S, Start, I-Start)); E := S[I];
      if (S[I] = #13) and (I < Length(S)) and (S[I+1] = #10) then begin E := #13#10; Inc(I); end;
      Endings.Add(E); Start := I+1;
    end;
    Inc(I);
  end;
  if Start <= Length(S) then begin Lines.Add(Copy(S, Start, MaxInt)); Endings.Add(''); end;
end;

function PatchPath(const Header: string): string;
var P: Integer;
begin
  Result := Copy(Header, 5, MaxInt); P := Pos(#9, Result);
  if P > 0 then Result := Copy(Result, 1, P-1);
  if Result = '/dev/null' then Exit;
  if (Copy(Result, 1, 2) = 'a/') or (Copy(Result, 1, 2) = 'b/') then Delete(Result, 1, 2);
  if (Result = '') or (Result[1] = '"') then
    PatchRaise('format', 'Patch requires unquoted file paths', '', 0);
  Result := ResolveProjectPath(Result);
end;

function NextLineStart(const S: string; StartAt: Integer): Integer;
begin
  Result := StartAt;
  while (Result <= Length(S)) and (S[Result] <> #10) do Inc(Result);
  if Result <= Length(S) then Inc(Result);
end;

function FindUnifiedHeader(const S: string): Integer;
var I, Next: Integer;
begin
  Result := 0; I := 1;
  while I <= Length(S) do
  begin
    Next := NextLineStart(S, I);
    if (Copy(S, I, 4) = '--- ') and (Copy(S, Next, 4) = '+++ ') then Exit(I);
    I := Next;
  end;
end;

function FindClosingFence(const S: string; StartAt: Integer): Integer;
var I: Integer;
begin
  Result := 0; I := StartAt;
  while I <= Length(S) do
  begin
    if Copy(S, I, 3) = StringOfChar('`', 3) then Exit(I);
    I := NextLineStart(S, I);
  end;
end;

function NormalizePatch(const Value: string): string;
var S: string; HeaderStart, FenceStart: Integer;
begin
  S := Value;
  if Copy(S, 1, 3) = #239#187#191 then Delete(S, 1, 3);
  S := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  S := StringReplace(S, #13, #10, [rfReplaceAll]);
  { Ignore a short response wrapper around one complete unified diff. }
  HeaderStart := FindUnifiedHeader(S);
  if HeaderStart > 0 then
  begin
    FenceStart := FindClosingFence(S, NextLineStart(S, HeaderStart));
    if FenceStart > 0 then
      S := Copy(S, HeaderStart, FenceStart - HeaderStart)
    else
      S := Copy(S, HeaderStart, MaxInt);
  end;

  Result := S;
end;

constructor EPatchError.Create(const AKind, AMessage, APath: string; ALine: Integer);
begin
  inherited Create(AMessage);
  ErrorKind := AKind;
  ErrorPath := APath;
  ErrorLine := ALine;
end;

function PatchErrorJSON(const E: EPatchError): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('error', E.Message);
    O.Add('error_kind', E.ErrorKind);
    if E.ErrorPath <> '' then O.Add('path', E.ErrorPath);
    if E.ErrorLine > 0 then O.Add('line', E.ErrorLine);
    Result := O.AsJSON;
  finally O.Free; end;
end;

procedure PatchRaise(const AKind, AMessage, APath: string; ALine: Integer = 0);
begin
  raise EPatchError.Create(AKind, AMessage, APath, ALine);
end;

function PatchErrorKindForMessage(const AMessage: string): string;
begin
  if Pos('Hunk count mismatch', AMessage) > 0 then Exit('hunk_count_mismatch');
  if Pos('Incomplete hunk', AMessage) > 0 then Exit('incomplete_hunk');
  if (Pos('Invalid hunk', AMessage) > 0) or (Pos('hunk header', LowerCase(AMessage)) > 0) or
     (Pos('Hunk position', AMessage) > 0) or (Pos('Hunk lines require', AMessage) > 0) or
     (Pos('Overlapping or invalid hunk', AMessage) > 0) or (Pos('Invalid new hunk position', AMessage) > 0) or
     (Pos('Old newline marker mismatch', AMessage) > 0) or (Pos('No-newline marker', AMessage) > 0) then
    Exit('invalid_hunk');
  if (Pos('Patch is empty', AMessage) > 0) or (Pos('Patch file has no hunks', AMessage) > 0) then Exit('empty_patch');
  if (Pos('Patch requires unquoted', AMessage) > 0) or (Pos('Invalid patch paths', AMessage) > 0) or
     (Pos('Renaming is unsupported', AMessage) > 0) then Exit('format');
  Result := 'patch_apply';
end;

procedure Stage(Edit: TStagedEdit);
{$IFDEF UNIX}var Info: Stat;{$ENDIF}
begin
  if Edit.Remove then Exit;
  ResolveProjectPath(Edit.Path);
  if not ForceDirectories(ExtractFileDir(Edit.Path)) then raise Exception.Create('Cannot create patch parent directory');
  ResolveProjectPath(Edit.Path);
  Edit.TempPath := SysUtils.GetTempFileName(ExtractFileDir(Edit.Path), '.agent-patch-');
  WriteBytes(Edit.TempPath, Edit.Content);
  {$IFDEF UNIX}
  if not Edit.CreateFile and (fpStat(Edit.Path, Info) = 0) then
    if fpChmod(Edit.TempPath, Info.st_mode and &777) <> 0 then raise Exception.Create('Cannot preserve file permissions');
  {$ENDIF}
end;

function Commit(Edits: TList): string;
var I: Integer; E: TStagedEdit; O: TJSONObject; Changed: TJSONArray;
  Warning, W: string;
begin
  Warning := '';
  O := TJSONObject.Create; Changed := TJSONArray.Create; O.Add('changed_paths', Changed);
  try
    try
      for I := 0 to Edits.Count - 1 do
      begin
        E := TStagedEdit(Edits[I]);
        ResolveProjectPath(E.Path);
        if E.CreateFile then
        begin if FileExists(E.Path) or DirectoryExists(E.Path) then raise Exception.Create('Creation target already exists'); end
        else if ReadTextBytes(E.Path) <> E.Original then raise Exception.Create('File changed since patch validation: ' + E.Path);
      end;
      if ToolCancelled then raise Exception.Create('Tool cancelled');
      for I := 0 to Edits.Count - 1 do
      begin
        if ToolCancelled then raise Exception.Create('Tool cancelled');
        Stage(TStagedEdit(Edits[I]));
      end;
      if ToolCancelled then raise Exception.Create('Tool cancelled');
      for I := 0 to Edits.Count - 1 do
      begin
        if ToolCancelled then raise Exception.Create('Tool cancelled');
        E := TStagedEdit(Edits[I]); ResolveProjectPath(E.Path);
        if E.Remove then
        begin if not SysUtils.DeleteFile(E.Path) then raise Exception.Create('Cannot delete ' + E.Path); end
        else
        begin
          {$IFDEF WINDOWS}
          if not MoveFileEx(PChar(E.TempPath), PChar(E.Path), MOVEFILE_REPLACE_EXISTING) then
          {$ELSE}
          if not RenameFile(E.TempPath, E.Path) then
          {$ENDIF}
            raise Exception.Create('Cannot replace ' + E.Path);
          E.TempPath := '';
        end;
        Changed.Add(E.Path);
        W := NotifyToolFileChanged(E.Path);
        if W <> '' then Warning := Warning + W + LineEnding;
      end;
      O.Add('status', 'success');
    except on Ex: Exception do
      begin
        O.Add('error', Ex.Message);
        O.Add('error_kind', PatchErrorKindForMessage(Ex.Message));
        O.Add('partial', Changed.Count > 0);
      end;
    end;
    if Warning <> '' then O.Add('tracking_warning', Trim(Warning));
    Result := O.AsJSON;
  finally O.Free; end;
end;

constructor TToolApplyPatch.Create;
begin
  inherited Create('apply_patch', 'Apply a unified diff after validating all hunks. Supports file creation, modification and deletion.',
    ParseToolArgs('{"type":"object","properties":{"patch":{"type":"string"}},"required":["patch"]}'));
end;

function TToolApplyPatch.Execute(const AArgsJSON: string): string;
var
  A: TJSONObject; Patch: TStringList; Edits: TList;
  Lines, Endings, Output, OutEndings: TStringList;
  R: TRegExpr; E: TStagedEdit;
  I, J, Cursor, OldStart, OldCount, NewStart, NewCount, SeenOld, SeenNew, MarkerIndex, HunkCount: Integer;
  OldPath, NewPath, Text, EOL, BOM: string; MarkerOld: Boolean;
  PatchEx: EPatchError;
  procedure AppendOriginal(UntilIndex: Integer);
  begin
    while Cursor < UntilIndex do
    begin
      if Cursor >= Lines.Count then
        PatchRaise('invalid_hunk', 'Hunk position outside file', E.Path, Cursor + 1);
      Output.Add(Lines[Cursor]); OutEndings.Add(Endings[Cursor]); Inc(Cursor);
    end;
  end;
  procedure CheckOld(const Value: string);
  begin
    if (Cursor >= Lines.Count) or (Lines[Cursor] <> Value) then
      raise EPatchError.Create('context_mismatch', 'Patch context mismatch in ' +
        E.Path + ' near line ' + IntToStr(Cursor + 1) +
        '; reread the current file and retry with exact context', E.Path, Cursor + 1);
  end;
begin
  A := ParseToolArgs(AArgsJSON); Patch := TStringList.Create; Edits := TList.Create;
  Lines := TStringList.Create; Endings := TStringList.Create;
  Output := TStringList.Create; OutEndings := TStringList.Create; R := TRegExpr.Create;
  try
    try
      Patch.Text := NormalizePatch(A.Get('patch', ''));
    R.Expression := '^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@';
    I := 0;
    while I < Patch.Count do
    begin
      if (Copy(Patch[I], 1, 11) = 'diff --git ') or (Copy(Patch[I], 1, 6) = 'index ') or (Patch[I] = '') then begin Inc(I); Continue; end;
      if Copy(Patch[I], 1, 4) <> '--- ' then
      begin
        { A complete diff may be followed by a short explanatory response. }
        if Edits.Count > 0 then Break;
        if (Pos('*** Begin Patch', Patch.Text) > 0) or
           (Pos('*** Update File:', Patch.Text) > 0) then
          raise EPatchError.Create('format', 'Unsupported patch format; send a unified diff with --- and +++ file headers', '', 0)
        else if Copy(Patch[I], 1, 3) = '```' then
          raise EPatchError.Create('format', 'Remove surrounding Markdown fences and send a unified diff with --- and +++ file headers', '', 0)
        else
          raise EPatchError.Create('format', 'Expected unified diff file header (--- path / +++ path); check the patch format and remove any surrounding text', '', 0);
      end;
      OldPath := PatchPath(Patch[I]); Inc(I);
      if (I >= Patch.Count) or (Copy(Patch[I], 1, 4) <> '+++ ') then
        raise EPatchError.Create('format', 'Missing +++ header after unified diff file header', '', 0);
      NewPath := PatchPath(Patch[I]); Inc(I);
      if (OldPath = '/dev/null') and (NewPath = '/dev/null') then
        PatchRaise('format', 'Invalid patch paths', '', 0);
      if (OldPath <> '/dev/null') and (NewPath <> '/dev/null') and (OldPath <> NewPath) then
        PatchRaise('format', 'Renaming is unsupported; use delete and create', '', 0);
      E := TStagedEdit.Create; Edits.Add(E);
      E.CreateFile := OldPath = '/dev/null'; E.Remove := NewPath = '/dev/null';
      if E.Remove then E.Path := OldPath else E.Path := NewPath;
      for J := 0 to Edits.Count-2 do
        if TStagedEdit(Edits[J]).Path = E.Path then
          PatchRaise('patch_apply', 'Duplicate patch target', E.Path, 0);
      if E.CreateFile then
      begin
        if FileExists(E.Path) or DirectoryExists(E.Path) then
          PatchRaise('patch_apply', 'Creation target already exists', E.Path, 0);
      end
      else E.Original := ReadTextBytes(E.Path);
      Lines.Clear; Endings.Clear; Output.Clear; OutEndings.Clear;
      Text := E.Original; BOM := '';
      if Copy(Text, 1, 3) = #239#187#191 then begin BOM := Copy(Text, 1, 3); Delete(Text, 1, 3); end;
      SplitLines(Text, Lines, Endings); Cursor := 0; HunkCount := 0;
      { Unified diffs use LF for new files; existing files below retain their
        first observed line ending. }
      EOL := #10;
      for J := 0 to Endings.Count-1 do if Endings[J] <> '' then begin EOL := Endings[J]; Break; end;
      while (I < Patch.Count) and (Copy(Patch[I], 1, 2) = '@@') do
      begin
        if ToolCancelled then raise Exception.Create('Tool cancelled');
        if not R.Exec(Patch[I]) then PatchRaise('invalid_hunk', 'Invalid hunk header', E.Path, 0);
        OldStart := StrToInt(R.Match[1]); NewStart := StrToInt(R.Match[4]);
        OldCount := 1; NewCount := 1;
        if R.Match[3] <> '' then OldCount := StrToInt(R.Match[3]);
        if R.Match[6] <> '' then NewCount := StrToInt(R.Match[6]);
        if OldCount > 0 then Dec(OldStart);
        if NewCount > 0 then Dec(NewStart);
        if (OldStart < Cursor) or (OldStart > Lines.Count) then
          PatchRaise('invalid_hunk', 'Overlapping or invalid hunk', E.Path, OldStart + 1);
        AppendOriginal(OldStart);
        if NewStart <> Output.Count then
          PatchRaise('invalid_hunk', 'Invalid new hunk position', E.Path, NewStart + 1);
        Inc(I); Inc(HunkCount); SeenOld := 0; SeenNew := 0; MarkerIndex := -1; MarkerOld := False;
        while I < Patch.Count do
        begin
          Text := Patch[I];
          if Text = '\ No newline at end of file' then
          begin
            if MarkerOld and ((Cursor = 0) or (Endings[Cursor-1] <> '')) then
              PatchRaise('invalid_hunk', 'Old newline marker mismatch', E.Path, Cursor);
            if MarkerIndex >= 0 then OutEndings[MarkerIndex] := '';
            MarkerIndex := -1; MarkerOld := False; Inc(I); Continue;
          end;
          if (SeenOld = OldCount) and (SeenNew = NewCount) then Break;
          if Text = '' then PatchRaise('invalid_hunk', 'Hunk lines require a prefix', E.Path, 0);
          case Text[1] of
            ' ': begin CheckOld(Copy(Text, 2, MaxInt)); Output.Add(Lines[Cursor]); OutEndings.Add(Endings[Cursor]); Inc(Cursor); Inc(SeenOld); Inc(SeenNew); MarkerIndex := Output.Count-1; MarkerOld := True; end;
            '-': begin CheckOld(Copy(Text, 2, MaxInt)); Inc(Cursor); Inc(SeenOld); MarkerIndex := -1; MarkerOld := True; end;
            '+': begin Output.Add(Copy(Text, 2, MaxInt)); OutEndings.Add(EOL); Inc(SeenNew); MarkerIndex := Output.Count-1; MarkerOld := False; end;
            else PatchRaise('invalid_hunk', 'Invalid hunk line', E.Path, 0);
          end;
          if (SeenOld > OldCount) or (SeenNew > NewCount) then
            PatchRaise('hunk_count_mismatch',
              'Hunk count mismatch; @@ old/new counts must match space, -, and + lines', E.Path, 0);
          Inc(I);
        end;
        if (SeenOld <> OldCount) or (SeenNew <> NewCount) then
          PatchRaise('incomplete_hunk',
            'Incomplete hunk; @@ old/new counts must match space, -, and + lines', E.Path, 0);
      end;
      if HunkCount = 0 then PatchRaise('empty_patch', 'Patch file has no hunks', E.Path, 0);
      AppendOriginal(Lines.Count); E.Content := BOM;
      for J := 0 to Output.Count-1 do
      begin
        if (J < Output.Count-1) and (OutEndings[J] = '') then
          PatchRaise('invalid_hunk', 'No-newline marker before final line', E.Path, 0);
        E.Content := E.Content + Output[J] + OutEndings[J];
      end;
      if E.Remove and (Output.Count <> 0) then
        PatchRaise('patch_apply', 'Deletion patch must remove all lines', E.Path, 0);
    end;
    if Edits.Count = 0 then PatchRaise('empty_patch', 'Patch is empty', '', 0);
      Result := Commit(Edits);
    except
      on Ex: EPatchError do Result := PatchErrorJSON(Ex);
      on Ex: Exception do
      begin
        PatchEx := EPatchError.Create(PatchErrorKindForMessage(Ex.Message), Ex.Message, '', 0);
        try Result := PatchErrorJSON(PatchEx); finally PatchEx.Free; end;
      end;
    end;
  finally
    for J := 0 to Edits.Count-1 do TObject(Edits[J]).Free;
    A.Free; Patch.Free; Edits.Free; Lines.Free; Endings.Free; Output.Free; OutEndings.Free; R.Free;
  end;
end;

constructor TToolEditFile.Create;
begin
  inherited Create('edit_file', 'Replace exactly one occurrence of old_text in a text file.',
    ParseToolArgs('{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["path","old_text","new_text"]}'));
  Advertised := False;
end;
function TToolEditFile.Execute(const AArgsJSON: string): string;
var A: TJSONObject; E: TStagedEdit; Edits: TList; Old, NewText: string; P: Integer;
begin
  A := ParseToolArgs(AArgsJSON); E := TStagedEdit.Create; Edits := TList.Create; Edits.Add(E);
  try
    E.Path := ResolveProjectPath(A.Get('path', '')); E.Original := ReadTextBytes(E.Path);
    Old := A.Get('old_text', ''); NewText := A.Get('new_text', '');
    if Old = '' then raise Exception.Create('old_text must not be empty');
    P := Pos(Old, E.Original);
    if (P = 0) or (Pos(Old, Copy(E.Original, P+1, MaxInt)) > 0) then raise Exception.Create('old_text must match exactly once');
    E.Content := Copy(E.Original, 1, P-1) + NewText + Copy(E.Original, P+Length(Old), MaxInt);
    Result := Commit(Edits);
  finally A.Free; E.Free; Edits.Free; end;
end;
initialization
  GetToolRegistry.RegisterTool(TToolApplyPatch.Create);
  GetToolRegistry.RegisterTool(TToolEditFile.Create);
end.
