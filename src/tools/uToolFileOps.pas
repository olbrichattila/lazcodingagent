unit uToolFileOps;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uAgentTypes, Masks, uToolPaths, fpjson, jsonparser, uToolBase;

type
  { Tool: list_files }
  TToolListFiles = class(TAgentTool)
  private
    procedure ScanDirectory(const ARoot, ASubDir, APattern: string; ARecursive: Boolean; ADepth: Integer; AResultArray: TJSONArray);
  public
    constructor Create;
    function Execute(const AArgsJSON: string): string; override;
  end;

  { Tool: read_file }
  TToolReadFile = class(TAgentTool)
  public
    constructor Create;
    function Execute(const AArgsJSON: string): string; override;
  end;

  { Tool: write_file }
  TToolWriteFile = class(TAgentTool)
  public
    constructor Create;
    function Execute(const AArgsJSON: string): string; override;
  end;

  { Tool: create_plan_file }
  TToolCreatePlanFile = class(TAgentTool)
  public
    constructor Create;
    function Execute(const AArgsJSON: string): string; override;
  end;

procedure RegisterFileTools;

implementation

function ResolveFullPath(const APath: string): string;
begin Result := ResolveProjectPath(APath); end;

function ShouldSkipDir(const ADirName: string): Boolean;
var
  LName: string;
begin
  if (ADirName = '.') or (ADirName = '..') then Exit(True);
  if (Length(ADirName) > 0) and (ADirName[1] = '.') then Exit(True);
  LName := LowerCase(ADirName);
  Result := (LName = 'node_modules') or (LName = 'backup') or
            (LName = 'lib') or (LName = 'units') or (LName = 'bin') or
            (LName = 'obj') or (LName = 'target') or (LName = 'dist') or
            (LName = '__pycache__') or (LName = 'venv') or (LName = '.env');
end;

function CreateSchema(AProperties: TJSONObject; const ARequired: array of string): TJSONObject;
var
  ReqArray: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'object');
  Result.Add('properties', AProperties);
  if Length(ARequired) > 0 then
  begin
    ReqArray := TJSONArray.Create;
    for I := Low(ARequired) to High(ARequired) do
      ReqArray.Add(ARequired[I]);
    Result.Add('required', ReqArray);
  end;
end;

{ TToolListFiles }

constructor TToolListFiles.Create;
var
  Props: TJSONObject;
  PathProp: TJSONObject;
  ExtProp: TJSONObject;
  RecurseProp: TJSONObject;
begin
  Props := TJSONObject.Create;

  PathProp := TJSONObject.Create;
  PathProp.Add('type', 'string');
  PathProp.Add('description', 'Directory path to list (default: active Lazarus project directory)');
  Props.Add('path', PathProp);

  ExtProp := TJSONObject.Create;
  ExtProp.Add('type', 'string');
  ExtProp.Add('description', 'File extension pattern filter, e.g. *.pas, *.lpr, *.lfm, *.inc, or * (default: *)');
  Props.Add('extension', ExtProp);

  RecurseProp := TJSONObject.Create;
  RecurseProp.Add('type', 'boolean');
  RecurseProp.Add('description', 'Whether to scan directories recursively (default: true)');
  Props.Add('recursive', RecurseProp);

  inherited Create(
    'list_files',
    'List files in the active project directory with optional extension pattern filter and recursive scanning.',
    CreateSchema(Props, [])
  );
  AllowedModes := [amAsk, amPlan, amAgent]; MutatesFiles := False; Advertised := False;
end;

procedure TToolListFiles.ScanDirectory(const ARoot, ASubDir, APattern: string; ARecursive: Boolean; ADepth: Integer; AResultArray: TJSONArray);
var
  Info: TSearchRec;
  CurrentPath: string;
  RelativePath: string;
  FileObj: TJSONObject;
  Patterns: TStringList;
  I: Integer;
  Matches: Boolean;
begin
  if ADepth > 8 then Exit;
  if AResultArray.Count >= 500 then Exit;

  CurrentPath := IncludeTrailingPathDelimiter(ARoot);
  if ASubDir <> '' then
    CurrentPath := IncludeTrailingPathDelimiter(CurrentPath + ASubDir);

  Patterns := TStringList.Create;
  try
    Patterns.Delimiter := ';';
    Patterns.StrictDelimiter := True;
    if (APattern = '') or (APattern = '*') then
      Patterns.Add('*')
    else
      Patterns.DelimitedText := APattern;

    if FindFirst(CurrentPath + '*', faAnyFile, Info) = 0 then
    begin
      try
        repeat
          if (Info.Attr and faDirectory) <> 0 then
          begin
            if IsPathLink(CurrentPath + Info.Name) then Continue;
            if ShouldSkipDir(Info.Name) then Continue;
            ResolveProjectPath(CurrentPath + Info.Name);

            if ARecursive and (AResultArray.Count < 500) then
            begin
              if ASubDir <> '' then
                ScanDirectory(ARoot, IncludeTrailingPathDelimiter(ASubDir) + Info.Name, APattern, ARecursive, ADepth + 1, AResultArray)
              else
                ScanDirectory(ARoot, Info.Name, APattern, ARecursive, ADepth + 1, AResultArray);
            end;
          end
          else
          begin
            if IsPathLink(CurrentPath + Info.Name) then Continue;
            ResolveProjectPath(CurrentPath + Info.Name);
            if (Length(Info.Name) > 0) and (Info.Name[1] = '.') then
              Continue;

            Matches := False;
            for I := 0 to Patterns.Count - 1 do
            begin
              if (Patterns[I] = '*') or MatchesMask(Info.Name, Patterns[I]) then
              begin
                Matches := True;
                Break;
              end;
            end;

            if Matches then
            begin
              if ASubDir <> '' then
                RelativePath := IncludeTrailingPathDelimiter(ASubDir) + Info.Name
              else
                RelativePath := Info.Name;

              FileObj := TJSONObject.Create;
              FileObj.Add('path', RelativePath);
              FileObj.Add('size', Info.Size);
              AResultArray.Add(FileObj);

              if AResultArray.Count >= 500 then
                Break;
            end;
          end;
        until FindNext(Info) <> 0;
      finally
        FindClose(Info);
      end;
    end;
  finally
    Patterns.Free;
  end;
end;

function TToolListFiles.Execute(const AArgsJSON: string): string;
var
  Parser: TJSONParser;
  JSONData: TJSONData;
  Args: TJSONObject;
  BasePath: string;
  ResolvedPath: string;
  Pattern: string;
  Recursive: Boolean;
  OutJSON: TJSONObject;
  FilesArray: TJSONArray;
begin
  BasePath := '.';
  Pattern := '*';
  Recursive := True;

  if Trim(AArgsJSON) <> '' then
  begin
    try
      Parser := TJSONParser.Create(AArgsJSON, True);
      try
        JSONData := Parser.Parse;
        try
          if JSONData is TJSONObject then
          begin
            Args := TJSONObject(JSONData);
            if Args.Find('path') <> nil then
              BasePath := Args.Get('path', BasePath);
            if Args.Find('extension') <> nil then
              Pattern := Args.Get('extension', Pattern);
            if Args.Find('recursive') <> nil then
              Recursive := Args.Get('recursive', Recursive);
          end;
        finally
          JSONData.Free;
        end;
      finally
        Parser.Free;
      end;
    except
      on E: Exception do Exit(ToolError('Invalid arguments: ' + E.Message));
    end;
  end;

  ResolvedPath := ResolveFullPath(BasePath);

  if not DirectoryExists(ResolvedPath) then
    Exit(ToolError('Directory does not exist: ' + ResolvedPath));

  OutJSON := TJSONObject.Create;
  try
    FilesArray := TJSONArray.Create;
    ScanDirectory(ResolvedPath, '', Pattern, Recursive, 0, FilesArray);
    OutJSON.Add('directory', ResolvedPath);
    OutJSON.Add('filter', Pattern);
    OutJSON.Add('total_files', FilesArray.Count);
    if FilesArray.Count >= 500 then
      OutJSON.Add('truncated', True);
    OutJSON.Add('files', FilesArray);
    Result := OutJSON.AsJSON;
  finally
    OutJSON.Free;
  end;
end;

{ TToolReadFile }

constructor TToolReadFile.Create;
var
  Props: TJSONObject;
  PathProp: TJSONObject;
  OffsetProp: TJSONObject;
  LimitProp: TJSONObject;
begin
  Props := TJSONObject.Create;

  PathProp := TJSONObject.Create;
  PathProp.Add('type', 'string');
  PathProp.Add('description', 'Relative or absolute file path to read');
  Props.Add('path', PathProp);

  OffsetProp := TJSONObject.Create;
  OffsetProp.Add('type', 'integer'); OffsetProp.Add('minimum', 1);
  OffsetProp.Add('description', 'Line number to start reading from (1-indexed, default: 1)');
  Props.Add('offset', OffsetProp);

  LimitProp := TJSONObject.Create;
  LimitProp.Add('type', 'integer'); LimitProp.Add('minimum', 1); LimitProp.Add('maximum', 2000);
  LimitProp.Add('description', 'Maximum number of lines to read (default: 2000)');
  Props.Add('limit', LimitProp);

  inherited Create(
    'read_file',
    'Read the text contents of a file with optional line offset and limit.',
    CreateSchema(Props, ['path'])
  );
  AllowedModes := [amAsk, amPlan, amAgent]; MutatesFiles := False;
end;

function TToolReadFile.Execute(const AArgsJSON: string): string;
var
  Parser: TJSONParser;
  JSONData: TJSONData;
  Args: TJSONObject;
  FilePath: string;
  ResolvedPath: string;
  Offset, Limit: Integer;
  Lines: TStringList;
  OutJSON: TJSONObject;
  FormattedText: string;
  StartIdx, EndIdx, I: Integer;
begin
  FilePath := '';
  Offset := 1;
  Limit := 2000;

  if Trim(AArgsJSON) <> '' then
  begin
    try
      Parser := TJSONParser.Create(AArgsJSON, True);
      try
        JSONData := Parser.Parse;
        try
          if JSONData is TJSONObject then
          begin
            Args := TJSONObject(JSONData);
            FilePath := Args.Get('path', '');
            Offset := Args.Get('offset', 1);
            Limit := Args.Get('limit', 2000);
          end;
        finally
          JSONData.Free;
        end;
      finally
        Parser.Free;
      end;
    except
      on E: Exception do
        Exit(ToolError('Invalid arguments: ' + E.Message));
    end;
  end;

  if FilePath = '' then
    Exit(ToolError('Missing required parameter: path'));

  ResolvedPath := ResolveFullPath(FilePath);

  if not FileExists(ResolvedPath) then
    Exit(ToolError('File not found: ' + ResolvedPath));

  Lines := TStringList.Create;
  try
    try
      Lines.Text := ReadTextBytes(ResolvedPath);
    except
      on E: Exception do
        Exit(ToolError('Failed to read file: ' + E.Message));
    end;

    if (Offset < 1) or (Limit < 1) or (Limit > 2000) then
      raise Exception.Create('offset must be positive and limit must be 1..2000');
    StartIdx := Offset - 1;
    if (StartIdx >= Lines.Count) and ((Lines.Count > 0) or (Offset <> 1)) then
      raise Exception.CreateFmt('Offset line out of range; total_lines: %d', [Lines.Count]);

    EndIdx := StartIdx + Limit;
    if EndIdx > Lines.Count then
      EndIdx := Lines.Count;

    FormattedText := '';
    for I := StartIdx to EndIdx - 1 do
      FormattedText := FormattedText + IntToStr(I + 1) + '|' + Lines[I] + LineEnding;

    OutJSON := TJSONObject.Create;
    try
      OutJSON.Add('path', ResolvedPath);
      OutJSON.Add('offset', Offset);
      OutJSON.Add('lines_returned', EndIdx - StartIdx);
      OutJSON.Add('total_lines', Lines.Count);
      OutJSON.Add('content', FormattedText);
      Result := OutJSON.AsJSON;
    finally
      OutJSON.Free;
    end;
  finally
    Lines.Free;
  end;
end;

{ TToolWriteFile }

constructor TToolWriteFile.Create;
var
  Props: TJSONObject;
  PathProp: TJSONObject;
  ContentProp: TJSONObject;
begin
  Props := TJSONObject.Create;

  PathProp := TJSONObject.Create;
  PathProp.Add('type', 'string');
  PathProp.Add('description', 'Relative or absolute file path to write');
  Props.Add('path', PathProp);

  ContentProp := TJSONObject.Create;
  ContentProp.Add('type', 'string');
  ContentProp.Add('description', 'Complete content to write to the file');
  Props.Add('content', ContentProp);

  inherited Create(
    'write_file',
    'Write or overwrite content to a file. Creates parent directories automatically.',
    CreateSchema(Props, ['path', 'content'])
  );
end;

function TToolWriteFile.Execute(const AArgsJSON: string): string;
var
  Parser: TJSONParser;
  JSONData: TJSONData;
  Args: TJSONObject;
  FilePath: string;
  ResolvedPath: string;
  Content: string;
  Dir: string;
  OutJSON: TJSONObject;
begin
  FilePath := '';
  Content := '';

  if Trim(AArgsJSON) <> '' then
  begin
    try
      Parser := TJSONParser.Create(AArgsJSON, True);
      try
        JSONData := Parser.Parse;
        try
          if JSONData is TJSONObject then
          begin
            Args := TJSONObject(JSONData);
            FilePath := Args.Get('path', '');
            if Args.Find('content') = nil then raise Exception.Create('Missing required parameter: content');
            Content := Args.Get('content', '');
          end;
        finally
          JSONData.Free;
        end;
      finally
        Parser.Free;
      end;
    except
      on E: Exception do
        Exit(ToolError('Invalid arguments: ' + E.Message));
    end;
  end;

  if FilePath = '' then
    Exit(ToolError('Missing required parameter: path'));

  ResolvedPath := ResolveFullPath(FilePath);

  Dir := ExtractFileDir(ResolvedPath);
  if (Dir <> '') and not DirectoryExists(Dir) then
  begin
    if not ForceDirectories(Dir) then
      Exit(ToolError('Failed to create directory: ' + Dir));
  end;

  try
    WriteBytes(ResolvedPath, Content);

    OutJSON := TJSONObject.Create;
    try
      OutJSON.Add('status', 'success');
      OutJSON.Add('path', ResolvedPath);
      OutJSON.Add('bytes_written', Length(Content));
      OutJSON.Add('changed_paths', TJSONArray.Create([ResolvedPath]));
      OutJSON.Add('tracking_warning', NotifyToolFileChanged(ResolvedPath));
      Result := OutJSON.AsJSON;
    finally
      OutJSON.Free;
    end;
  except
    on E: Exception do
      Result := ToolError('Failed to write file: ' + E.Message);
  end;
end;

constructor TToolCreatePlanFile.Create;
var
  Props, ContentProp: TJSONObject;
begin
  Props := TJSONObject.Create;
  ContentProp := TJSONObject.Create;
  ContentProp.Add('type', 'string');
  ContentProp.Add('description', 'Complete implementation plan in Markdown');
  Props.Add('content', ContentProp);
  inherited Create('create_plan_file',
    'Save a completed implementation plan as a timestamped Markdown file under the project .plan directory.',
    CreateSchema(Props, ['content']));
  AllowedModes := [amPlan, amAgent];
end;

function TToolCreatePlanFile.Execute(const AArgsJSON: string): string;
var
  Parser: TJSONParser;
  JSONData: TJSONData;
  Args, OutJSON: TJSONObject;
  Content, PlanDir, PlanPath, BaseName: string;
  Suffix: Integer;
  Stream: TFileStream;
begin
  Content := '';
  try
    Parser := TJSONParser.Create(AArgsJSON, True);
    try
      JSONData := Parser.Parse;
      try
        if JSONData.JSONType <> jtObject then
          Exit(ToolError('Arguments must be a JSON object'));
        Args := TJSONObject(JSONData);
        Content := Args.Get('content', '');
      finally
        JSONData.Free;
      end;
    finally
      Parser.Free;
    end;
  except
    on E: Exception do
      Exit(ToolError('Invalid plan arguments: ' + E.Message));
  end;

  if Trim(Content) = '' then
    Exit(ToolError('Plan content is required'));

  try
    { Check the literal directory before path resolution can follow a link. }
    PlanDir := IncludeTrailingPathDelimiter(ResolveProjectPath('')) + '.plan';
    if IsPathLink(PlanDir) then
      Exit(ToolError('Project .plan directory must not be a symbolic link or reparse point'));
    PlanDir := ResolveProjectPath(PlanDir);
    if not ForceDirectories(PlanDir) then
      Exit(ToolError('Could not create project .plan directory'));

    BaseName := 'plan-' + FormatDateTime('yyyymmdd-hhnnss', Now);
    PlanPath := IncludeTrailingPathDelimiter(PlanDir) + BaseName + '.md';
    Suffix := 1;
    while FileExists(PlanPath) do
    begin
      PlanPath := IncludeTrailingPathDelimiter(PlanDir) + BaseName + '-' + IntToStr(Suffix) + '.md';
      Inc(Suffix);
    end;

    if IsPathLink(PlanDir) then
      Exit(ToolError('Project .plan directory must not be a symbolic link or reparse point'));
    ResolveProjectPath(PlanPath);
    Stream := TFileStream.Create(PlanPath, fmCreate);
    try
      Stream.WriteBuffer(Content[1], Length(Content));
    finally
      Stream.Free;
    end;
    OutJSON := TJSONObject.Create;
    try
      OutJSON.Add('status', 'success');
      OutJSON.Add('path', PlanPath);
      OutJSON.Add('content', Content);
      Result := OutJSON.AsJSON;
    finally
      OutJSON.Free;
    end;
  except
    on E: Exception do
      Result := ToolError('Could not save plan: ' + E.Message);
  end;
end;

procedure RegisterFileTools;
begin
  GetToolRegistry.RegisterTool(TToolListFiles.Create);
  GetToolRegistry.RegisterTool(TToolReadFile.Create);
  GetToolRegistry.RegisterTool(TToolWriteFile.Create);
  GetToolRegistry.RegisterTool(TToolCreatePlanFile.Create);
end;

initialization
  RegisterFileTools;

end.
