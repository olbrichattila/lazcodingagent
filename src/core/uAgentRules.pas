unit uAgentRules;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils;

type
  TAgentRules = class
  public
    class function DirectoryForProject(const AProjectRoot: string): string;
    class procedure ListFiles(const AProjectRoot: string; AFiles: TStrings);
    class function ReadAll(const AProjectRoot: string): string;
    class function ReadFile(const AFileName: string): string;
    class procedure WriteFile(const AFileName, AContent: string);
    class function CreateRule(const AProjectRoot, AContent: string): string;
  end;

implementation

class function TAgentRules.DirectoryForProject(const AProjectRoot: string): string;
begin
  if Trim(AProjectRoot) = '' then Exit('');
  Result := IncludeTrailingPathDelimiter(ExpandFileName(AProjectRoot)) + '.rules';
end;

class procedure TAgentRules.ListFiles(const AProjectRoot: string; AFiles: TStrings);
var Search: TSearchRec; Dir: string; SortedFiles: TStringList;
begin
  AFiles.Clear;
  Dir := DirectoryForProject(AProjectRoot);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;
  SortedFiles := TStringList.Create;
  try
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.md', faAnyFile, Search) = 0 then
  try
    repeat
      if ((Search.Attr and faDirectory) = 0) and (Search.Name <> '.') and (Search.Name <> '..') then
        SortedFiles.Add(IncludeTrailingPathDelimiter(Dir) + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
    SortedFiles.Sort;
    AFiles.Assign(SortedFiles);
  finally
    SortedFiles.Free;
  end;
end;

class function TAgentRules.ReadFile(const AFileName: string): string;
var Stream: TFileStream;
begin
  Result := '';
  if not FileExists(AFileName) then Exit;
  Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

class procedure TAgentRules.WriteFile(const AFileName, AContent: string);
var Stream: TFileStream; Bytes: UTF8String;
begin
  Bytes := UTF8String(AContent);
  Stream := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(Bytes) > 0 then Stream.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

class function TAgentRules.ReadAll(const AProjectRoot: string): string;
var Files: TStringList; I: Integer; Content: string;
begin
  Result := '';
  Files := TStringList.Create;
  try
    ListFiles(AProjectRoot, Files);
    for I := 0 to Files.Count - 1 do
    begin
      Content := Trim(ReadFile(Files[I]));
      if Content = '' then Continue;
      if Result <> '' then Result := Result + LineEnding + LineEnding;
      Result := Result + Content;
    end;
  finally
    Files.Free;
  end;
end;

class function TAgentRules.CreateRule(const AProjectRoot, AContent: string): string;
var Dir, Name: string; Guid: TGuid;
begin
  Dir := DirectoryForProject(AProjectRoot);
  if Dir = '' then raise Exception.Create('Cannot save a rule without an active project folder.');
  if not ForceDirectories(Dir) then raise Exception.Create('Could not create project .rules folder.');
  if CreateGUID(Guid) <> 0 then raise Exception.Create('Could not generate a unique rule filename.');
  Name := GUIDToString(Guid);
  Name := StringReplace(Name, '{', '', []);
  Name := StringReplace(Name, '}', '', []);
  Name := StringReplace(Name, '-', '', [rfReplaceAll]);
  Result := IncludeTrailingPathDelimiter(Dir) + 'rule-' + LowerCase(Name) + '.md';
  WriteFile(Result, AContent);
end;

end.
