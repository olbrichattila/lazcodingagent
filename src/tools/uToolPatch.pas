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
  TStagedEdit = class
    Path, TempPath: string;
    Original, Content: RawByteString;
    Remove, CreateFile: Boolean;
    destructor Destroy; override;
  end;
destructor TStagedEdit.Destroy;
begin if TempPath <> '' then SysUtils.DeleteFile(TempPath); inherited Destroy; end;

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
  if (Result = '') or (Result[1] = '"') then raise Exception.Create('Patch requires unquoted file paths');
  Result := ResolveProjectPath(Result);
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
      begin O.Add('error', Ex.Message); O.Add('partial', Changed.Count > 0); end;
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
  procedure AppendOriginal(UntilIndex: Integer);
  begin
    while Cursor < UntilIndex do
    begin
      if Cursor >= Lines.Count then raise Exception.Create('Hunk position outside file');
      Output.Add(Lines[Cursor]); OutEndings.Add(Endings[Cursor]); Inc(Cursor);
    end;
  end;
  procedure CheckOld(const Value: string);
  begin
    if (Cursor >= Lines.Count) or (Lines[Cursor] <> Value) then raise Exception.Create('Patch context mismatch: ' + E.Path);
  end;
begin
  A := ParseToolArgs(AArgsJSON); Patch := TStringList.Create; Edits := TList.Create;
  Lines := TStringList.Create; Endings := TStringList.Create;
  Output := TStringList.Create; OutEndings := TStringList.Create; R := TRegExpr.Create;
  try
    Patch.Text := A.Get('patch', '');
    R.Expression := '^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@';
    I := 0;
    while I < Patch.Count do
    begin
      if (Copy(Patch[I], 1, 11) = 'diff --git ') or (Copy(Patch[I], 1, 6) = 'index ') or (Patch[I] = '') then begin Inc(I); Continue; end;
      if Copy(Patch[I], 1, 4) <> '--- ' then raise Exception.Create('Expected unified diff file header');
      OldPath := PatchPath(Patch[I]); Inc(I);
      if (I >= Patch.Count) or (Copy(Patch[I], 1, 4) <> '+++ ') then raise Exception.Create('Missing +++ header');
      NewPath := PatchPath(Patch[I]); Inc(I);
      if (OldPath = '/dev/null') and (NewPath = '/dev/null') then raise Exception.Create('Invalid patch paths');
      if (OldPath <> '/dev/null') and (NewPath <> '/dev/null') and (OldPath <> NewPath) then raise Exception.Create('Renaming is unsupported; use delete and create');
      E := TStagedEdit.Create; Edits.Add(E);
      E.CreateFile := OldPath = '/dev/null'; E.Remove := NewPath = '/dev/null';
      if E.Remove then E.Path := OldPath else E.Path := NewPath;
      for J := 0 to Edits.Count-2 do if TStagedEdit(Edits[J]).Path = E.Path then raise Exception.Create('Duplicate patch target');
      if E.CreateFile then
      begin if FileExists(E.Path) or DirectoryExists(E.Path) then raise Exception.Create('Creation target already exists'); end
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
        if not R.Exec(Patch[I]) then raise Exception.Create('Invalid hunk header');
        OldStart := StrToInt(R.Match[1]); NewStart := StrToInt(R.Match[4]);
        OldCount := 1; NewCount := 1;
        if R.Match[3] <> '' then OldCount := StrToInt(R.Match[3]);
        if R.Match[6] <> '' then NewCount := StrToInt(R.Match[6]);
        if OldCount > 0 then Dec(OldStart);
        if NewCount > 0 then Dec(NewStart);
        if (OldStart < Cursor) or (OldStart > Lines.Count) then raise Exception.Create('Overlapping or invalid hunk');
        AppendOriginal(OldStart);
        if NewStart <> Output.Count then raise Exception.Create('Invalid new hunk position');
        Inc(I); Inc(HunkCount); SeenOld := 0; SeenNew := 0; MarkerIndex := -1; MarkerOld := False;
        while I < Patch.Count do
        begin
          Text := Patch[I];
          if Text = '\ No newline at end of file' then
          begin
            if MarkerOld and ((Cursor = 0) or (Endings[Cursor-1] <> '')) then raise Exception.Create('Old newline marker mismatch');
            if MarkerIndex >= 0 then OutEndings[MarkerIndex] := '';
            MarkerIndex := -1; MarkerOld := False; Inc(I); Continue;
          end;
          if (SeenOld = OldCount) and (SeenNew = NewCount) then Break;
          if Text = '' then raise Exception.Create('Hunk lines require a prefix');
          case Text[1] of
            ' ': begin CheckOld(Copy(Text, 2, MaxInt)); Output.Add(Lines[Cursor]); OutEndings.Add(Endings[Cursor]); Inc(Cursor); Inc(SeenOld); Inc(SeenNew); MarkerIndex := Output.Count-1; MarkerOld := True; end;
            '-': begin CheckOld(Copy(Text, 2, MaxInt)); Inc(Cursor); Inc(SeenOld); MarkerIndex := -1; MarkerOld := True; end;
            '+': begin Output.Add(Copy(Text, 2, MaxInt)); OutEndings.Add(EOL); Inc(SeenNew); MarkerIndex := Output.Count-1; MarkerOld := False; end;
            else raise Exception.Create('Invalid hunk line');
          end;
          if (SeenOld > OldCount) or (SeenNew > NewCount) then raise Exception.Create('Hunk count mismatch');
          Inc(I);
        end;
        if (SeenOld <> OldCount) or (SeenNew <> NewCount) then raise Exception.Create('Incomplete hunk');
      end;
      if HunkCount = 0 then raise Exception.Create('Patch file has no hunks');
      AppendOriginal(Lines.Count); E.Content := BOM;
      for J := 0 to Output.Count-1 do
      begin
        if (J < Output.Count-1) and (OutEndings[J] = '') then raise Exception.Create('No-newline marker before final line');
        E.Content := E.Content + Output[J] + OutEndings[J];
      end;
      if E.Remove and (Output.Count <> 0) then raise Exception.Create('Deletion patch must remove all lines');
    end;
    if Edits.Count = 0 then raise Exception.Create('Patch is empty');
    Result := Commit(Edits);
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
