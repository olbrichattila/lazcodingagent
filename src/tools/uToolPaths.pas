unit uToolPaths;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, fpjson, uToolBase;
function ResolveProjectPath(const Path: string): string;
function CanonicalFilePath(const Path: string): string;
function ReadTextBytes(const Path: string): RawByteString;
procedure WriteBytes(const Path: string; const Content: RawByteString);
function IsPathLink(const Path: string): Boolean;
function SkipGenerated(const Name: string): Boolean;
function GlobMatches(const Pattern, Path: string): Boolean;
procedure CollectFiles(const Root, Sub: string; Hidden: Boolean; Files: TStrings; Depth: Integer = 0);
function SuccessFile(const Path: string; Bytes: Int64): string;
implementation
uses {$IFDEF UNIX}BaseUnix{$ELSE}Windows{$ENDIF};

function CanonicalPath(const Path: string; Depth: Integer): string;
var Parts: TStringList; I: Integer; Cur, Link, Tail: string;
begin
  if Depth > 32 then raise Exception.Create('Too many symbolic links');
  Result := ExpandFileName(Path);
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True; Parts.Delimiter := DirectorySeparator;
    Parts.DelimitedText := Result;
    {$IFDEF UNIX}Cur := '/';{$ELSE}Cur := Parts[0] + DirectorySeparator;{$ENDIF}
    for I := 1 to Parts.Count - 1 do
    begin
      Cur := IncludeTrailingPathDelimiter(Cur) + Parts[I];
      {$IFDEF UNIX}
      Link := fpReadLink(Cur);
      if Link <> '' then
      begin
        if Link[1] <> '/' then Link := IncludeTrailingPathDelimiter(ExtractFileDir(Cur)) + Link;
        Tail := ''; if I < Parts.Count - 1 then Tail := Copy(Result, Length(Cur) + 1, MaxInt);
        Exit(CanonicalPath(Link + Tail, Depth + 1));
      end;
      {$ELSE}
      if (GetFileAttributes(PChar(Cur)) <> INVALID_FILE_ATTRIBUTES) and
        ((GetFileAttributes(PChar(Cur)) and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
        raise Exception.Create('Reparse-point paths are unsupported');
      {$ENDIF}
    end;
  finally Parts.Free; end;
end;

function CanonicalFilePath(const Path: string): string;
begin
  Result := CanonicalPath(Path, 0);
end;

function ResolveProjectPath(const Path: string): string;
var Root, Candidate, Prefix: string; C: TToolContext;
begin
  if Pos(#0, Path) > 0 then raise Exception.Create('Invalid path');
  C := CurrentToolContext;
  Root := ExcludeTrailingPathDelimiter(CanonicalPath(C.ProjectRoot, 0));
  if Path = '' then Candidate := Root
  {$IFDEF UNIX}
  else if Path[1] = '/' then Candidate := Path
  {$ELSE}
  else if ((Length(Path) > 1) and (Path[2] = ':')) or (Copy(Path, 1, 2) = '\\') then Candidate := Path
  {$ENDIF}
  else Candidate := IncludeTrailingPathDelimiter(Root) + Path;
  Result := CanonicalPath(Candidate, 0);
  if SafeToolText(Result) <> Result then raise Exception.Create('Unsupported path encoding');
  Prefix := IncludeTrailingPathDelimiter(Root);
  {$IFDEF WINDOWS}
  if not SameText(Result, Root) and not SameText(Copy(Result, 1, Length(Prefix)), Prefix) then
  {$ELSE}
  if (Result <> Root) and (Copy(Result, 1, Length(Prefix)) <> Prefix) then
  {$ENDIF}
    raise Exception.Create('Path escapes the active project: ' + Path);
end;

function ReadTextBytes(const Path: string): RawByteString;
var S: TFileStream; I: Integer;
  {$IFDEF UNIX}Info: Stat;{$ENDIF}
begin
  {$IFDEF UNIX}
  if (fpStat(Path, Info) <> 0) or not FPS_ISREG(Info.st_mode) then raise Exception.Create('Not a regular text file: ' + Path);
  {$ENDIF}
  S := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    if S.Size > 16*1024*1024 then raise Exception.Create('Text file exceeds 16 MiB limit');
    SetLength(Result, S.Size);
    if Length(Result) > 0 then S.ReadBuffer(Result[1], Length(Result));
  finally S.Free; end;
  if SafeToolText(Result) <> Result then raise Exception.Create('Unsupported text encoding; use UTF-8: ' + Path);
  for I := 1 to Length(Result) do
    if (Result[I] = #0) or ((Ord(Result[I]) < 9) or (Ord(Result[I]) in [14..31])) then
      raise Exception.Create('Unsupported binary or text encoding: ' + Path);
end;

procedure WriteBytes(const Path: string; const Content: RawByteString);
var S: TFileStream;
  {$IFDEF UNIX}Info: Stat;{$ENDIF}
begin
  ResolveProjectPath(Path);
  {$IFDEF UNIX}
  if (fpStat(Path, Info) = 0) and not FPS_ISREG(Info.st_mode) then raise Exception.Create('Not a regular file: ' + Path);
  {$ENDIF}
  if not ForceDirectories(ExtractFileDir(Path)) then raise Exception.Create('Cannot create parent directories');
  ResolveProjectPath(Path);
  S := TFileStream.Create(Path, fmCreate);
  try if Length(Content) > 0 then S.WriteBuffer(Content[1], Length(Content)); finally S.Free; end;
end;

function IsPathLink(const Path: string): Boolean;
{$IFDEF UNIX}var Info: Stat;{$ELSE}var Attr: DWORD;{$ENDIF}
begin
  {$IFDEF UNIX}
  Result := (fpLStat(Path, Info) = 0) and FPS_ISLNK(Info.st_mode);
  {$ELSE}
  Attr := GetFileAttributes(PChar(Path));
  Result := (Attr <> INVALID_FILE_ATTRIBUTES) and ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0);
  {$ENDIF}
end;

function SkipGenerated(const Name: string): Boolean;
begin
  Result := Pos(';' + LowerCase(Name) + ';', ';node_modules;backup;lib;units;bin;obj;target;dist;__pycache__;venv;.git;') > 0;
end;

function GlobMatches(const Pattern, Path: string): Boolean;
  function Match(P, S: Integer): Boolean;
  var K: Integer; Recursive: Boolean;
  begin
    if P > Length(Pattern) then Exit(S > Length(Path));
    if Pattern[P] = '*' then
    begin
      Recursive := (P < Length(Pattern)) and (Pattern[P+1] = '*');
      if Recursive then
      begin
        Inc(P);
        if (P < Length(Pattern)) and (Pattern[P+1] = '/') and Match(P+2, S) then Exit(True);
      end;
      K := S;
      repeat
        if Match(P+1, K) then Exit(True);
        if K > Length(Path) then Break;
        if not Recursive and (Path[K] = '/') then Break;
        Inc(K);
      until False;
      Exit(False);
    end;
    if S > Length(Path) then Exit(False);
    Result := ((Pattern[P] = Path[S]) or ((Pattern[P] = '?') and (Path[S] <> '/'))) and Match(P+1, S+1);
  end;
begin Result := Match(1, 1); end;

procedure CollectFiles(const Root, Sub: string; Hidden: Boolean; Files: TStrings; Depth: Integer);
var R: TSearchRec; Dir, Rel, Full: string;
begin
  if ToolCancelled then raise Exception.Create('Tool cancelled');
  if Depth > 64 then raise Exception.Create('Directory nesting exceeds 64 levels');
  Dir := IncludeTrailingPathDelimiter(Root) + Sub;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) <> 0 then Exit;
  try
    repeat
      if ToolCancelled then raise Exception.Create('Tool cancelled');
      if (R.Name = '.') or (R.Name = '..') then Continue;
      if not Hidden and (R.Name[1] = '.') then Continue;
      Rel := Sub + R.Name; Full := IncludeTrailingPathDelimiter(Root) + Rel;
      { Do not recurse through links: avoids cycles and traversal outside the project. }
      if IsPathLink(Full) then Continue;
      ResolveProjectPath(Full);
      if (R.Attr and faDirectory) <> 0 then
      begin
        if not SkipGenerated(R.Name) then CollectFiles(Root, Rel + DirectorySeparator, Hidden, Files, Depth+1);
      end
      else Files.Add(StringReplace(Rel, DirectorySeparator, '/', [rfReplaceAll]));
    until FindNext(R) <> 0;
  finally FindClose(R); end;
end;

function SuccessFile(const Path: string; Bytes: Int64): string;
var O: TJSONObject; A: TJSONArray;
begin
  O := TJSONObject.Create(['status', 'success', 'path', Path, 'bytes_written', Bytes]);
  A := TJSONArray.Create; A.Add(Path); O.Add('changed_paths', A);
  try Result := O.AsJSON; finally O.Free; end;
end;
end.
