unit uToolBase;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fgl, fpjson, jsonparser, uAgentTypes;

type
  TToolModes = set of TAgentMode;
  TToolCancelled = function: Boolean of object;
  TToolFileChanged = procedure(const APath: string) of object;
  TToolSession = class
  public
    Tasks: TJSONArray;
    Diagnostics: TJSONObject;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
  end;
  TToolContext = record
    ProjectRoot: string;
    Mode: TAgentMode;
    IsCancelled: TToolCancelled;
    Session: TToolSession;
    OnFileChanged: TToolFileChanged;
  end;

  { Base class for agent executable tools }
  TAgentTool = class
  private
    FName: string;
    FDescription: string;
    FParametersSchema: TJSONObject;
  public
    constructor Create(const AName, ADescription: string; AParametersSchema: TJSONObject); virtual;
    destructor Destroy; override;

    function Execute(const AArgsJSON: string): string; virtual; abstract;
    function ExecuteWithContext(const AArgsJSON: string; const AContext: TToolContext): string; virtual;
    function GetDeclarationJSON: TJSONObject; virtual;

  public
    Aliases: string; { Semicolon separated; never advertised }
    AllowedModes: TToolModes;
    MutatesFiles: Boolean;
    Advertised: Boolean;
    property Name: string read FName;
    property Description: string read FDescription;
    property ParametersSchema: TJSONObject read FParametersSchema;
  end;

  TToolList = specialize TFPGObjectList<TAgentTool>;

  { Tool Registry managing available built-in and custom tools }
  TToolRegistry = class
  private
    FTools: TToolList;
  public
    constructor Create;
    destructor Destroy; override;

    procedure RegisterTool(ATool: TAgentTool);
    function FindTool(const AName: string): TAgentTool;
    function GetToolsDeclarationJSONArray(AMode: TAgentMode): TJSONArray;
    function ExecuteTool(const AName, AArgsJSON: string): string; overload;
    function ExecuteTool(const AName, AArgsJSON: string; const AContext: TToolContext): string; overload;
    function CanonicalName(const AName: string): string;
    function ToolGuidance(AMode: TAgentMode): string;
    function Count: Integer;

    property Tools: TToolList read FTools;
  end;

function SafeToolText(const S: RawByteString; MaxBytes: Integer = MaxInt): string;
function ToolError(const AMessage: string): string;
function ParseToolArgs(const S: string): TJSONObject;
function CurrentToolContext: TToolContext;
function ToolCancelled: Boolean;
function NotifyToolFileChanged(const APath: string): string;
function GetToolRegistry: TToolRegistry;
function ToolAllowedForMode(AMode: TAgentMode; const AToolName: string): Boolean;
function FallbackExtractToolCall(const AText: string; out AToolName, AToolArgs: string): Boolean;
function GetEffectiveProjectDir: string;
procedure SetEffectiveProjectDir(const ADir: string);

type
  TProjectDirProvider = function: string;
  TAgentIDERefreshProc = function(AChangedFiles: TStrings;
    const AProjectRoot: string): string of object;
  TAgentIDECommandRefreshProc = function(const AProjectRoot: string;
    ABeforeCommand: Boolean): string of object;

var
  GProjectDirProvider: TProjectDirProvider = nil;
  GAgentIDERefreshProc: TAgentIDERefreshProc = nil;
  GAgentIDECommandRefreshProc: TAgentIDECommandRefreshProc = nil;

procedure SetAgentIDERefreshProc(AProc: TAgentIDERefreshProc);

implementation

var
  GToolRegistry: TToolRegistry = nil;
  GCurrentProjectDir: string = '';

threadvar
  GActiveContext: TToolContext;

procedure SetAgentIDERefreshProc(AProc: TAgentIDERefreshProc);
begin
  GAgentIDERefreshProc := AProc;
end;

function StripTrailingSlash(const S: string): string;
begin
  Result := S;
  while (Length(Result) > 1) and ((Result[Length(Result)] = '/') or (Result[Length(Result)] = '\')) do
    Delete(Result, Length(Result), 1);
end;

procedure SetEffectiveProjectDir(const ADir: string);
begin
  if (ADir <> '') and DirectoryExists(ADir) then
    GCurrentProjectDir := StripTrailingSlash(ExpandFileName(ADir))
  else
    GCurrentProjectDir := '';
end;

function GetEffectiveProjectDir: string;
begin
  if (GCurrentProjectDir <> '') and DirectoryExists(GCurrentProjectDir) then
    Result := GCurrentProjectDir
  else
  begin
    Result := '';
    if Assigned(GProjectDirProvider) then
    begin
      try
        Result := GProjectDirProvider();
      except
        Result := '';
      end;
    end;

    if (Result = '') or not DirectoryExists(Result) then
      Result := GetCurrentDir;
  end;
  Result := StripTrailingSlash(ExpandFileName(Result));
end;

function FallbackExtractToolCall(const AText: string; out AToolName, AToolArgs: string): Boolean;
var
  S, Sub: string;
  P1, P2: Integer;
  Parser: TJSONParser;
  JSONData: TJSONData;
  Obj: TJSONObject;
begin
  Result := False;
  AToolName := '';
  AToolArgs := '{}';
  S := Trim(AText);
  Sub := '';

  P1 := Pos('```json', S);
  if P1 > 0 then
  begin
    P2 := Pos('```', Copy(S, P1 + 7, Length(S)));
    if P2 > 0 then
      Sub := Trim(Copy(S, P1 + 7, P2 - 1));
  end
  else
  begin
    P1 := Pos('<tool_call>', S);
    if P1 > 0 then
    begin
      P2 := Pos('</tool_call>', S);
      if P2 > 0 then
        Sub := Trim(Copy(S, P1 + 11, P2 - P1 - 11));
    end;
  end;

  if Sub = '' then
  begin
    if (Length(S) > 0) and (S[1] = '{') and (S[Length(S)] = '}') then
      Sub := S;
  end;

  if Sub <> '' then
  begin
    try
      Parser := TJSONParser.Create(Sub, True);
      try
        JSONData := Parser.Parse;
        try
          if JSONData is TJSONObject then
          begin
            Obj := TJSONObject(JSONData);
            if Obj.Find('name') <> nil then
            begin
              AToolName := Obj.Get('name', '');
              if Obj.Find('arguments') <> nil then
              begin
                if Obj.Types['arguments'] = jtObject then
                  AToolArgs := Obj.Objects['arguments'].AsJSON
                else
                  AToolArgs := Obj.Get('arguments', '{}');
              end
              else if Obj.Find('parameters') <> nil then
              begin
                if Obj.Types['parameters'] = jtObject then
                  AToolArgs := Obj.Objects['parameters'].AsJSON
                else
                  AToolArgs := Obj.Get('parameters', '{}');
              end;

              Result := (AToolName <> '') and (GetToolRegistry.FindTool(AToolName) <> nil);
            end;
          end;
        finally
          JSONData.Free;
        end;
      finally
        Parser.Free;
      end;
    except
      // Ignore parse failure
    end;
  end;
end;

function GetToolRegistry: TToolRegistry;
begin
  if not Assigned(GToolRegistry) then
    GToolRegistry := TToolRegistry.Create;
  Result := GToolRegistry;
end;

{ TAgentTool }

constructor TAgentTool.Create(const AName, ADescription: string; AParametersSchema: TJSONObject);
begin
  inherited Create;
  AllowedModes := [amAgent];
  MutatesFiles := True;
  Advertised := True;
  Aliases := '';
  FName := AName;
  FDescription := ADescription;
  FParametersSchema := AParametersSchema;
end;

destructor TAgentTool.Destroy;
begin
  if Assigned(FParametersSchema) then
    FParametersSchema.Free;
  inherited Destroy;
end;

function TAgentTool.GetDeclarationJSON: TJSONObject;
var
  FnObj: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('type', 'function');

  FnObj := TJSONObject.Create;
  FnObj.Add('name', FName);
  FnObj.Add('description', FDescription);

  if Assigned(FParametersSchema) then
    FnObj.Add('parameters', FParametersSchema.Clone as TJSONObject)
  else
  begin
    FnObj.Add('parameters', TJSONObject.Create(['type', 'object', 'properties', TJSONObject.Create]));
  end;

  Result.Add('function', FnObj);
end;

{ TToolRegistry }

constructor TToolRegistry.Create;
begin
  inherited Create;
  FTools := TToolList.Create(True);
end;

destructor TToolRegistry.Destroy;
begin
  FTools.Free;
  inherited Destroy;
end;

procedure TToolRegistry.RegisterTool(ATool: TAgentTool);
var
  Existing: TAgentTool;
begin
  if not Assigned(ATool) then Exit;
  Existing := FindTool(ATool.Name);
  if Assigned(Existing) then
    FTools.Remove(Existing);
  FTools.Add(ATool);
end;

function TToolRegistry.FindTool(const AName: string): TAgentTool;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FTools.Count - 1 do
  begin
    if SameText(FTools[I].Name, AName) or
      (Pos(';' + LowerCase(AName) + ';', ';' + LowerCase(FTools[I].Aliases) + ';') > 0) then
    begin
      Result := FTools[I];
      Exit;
    end;
  end;
end;

function TToolRegistry.GetToolsDeclarationJSONArray(AMode: TAgentMode): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to FTools.Count - 1 do
    if FTools[I].Advertised and ToolAllowedForMode(AMode, FTools[I].Name) then
      Result.Add(FTools[I].GetDeclarationJSON);
end;

{ Preserve valid UTF-8 and replace invalid/truncated byte sequences in command output.
  JSON transported to an LLM must remain UTF-8 even when a command prints binary bytes. }
function SafeToolText(const S: RawByteString; MaxBytes: Integer): string;
var I, J, N, W, B, SecondMin, SecondMax: Integer;
begin
  SetLength(Result, Min(Int64(Length(S))*3, Int64(MaxBytes)));
  I := 1; W := 0;
  while I <= Length(S) do
  begin
    B := Ord(S[I]); N := 0; SecondMin := $80; SecondMax := $BF;
    if B < $80 then N := 1
    else if (B >= $C2) and (B <= $DF) then N := 2
    else if (B >= $E0) and (B <= $EF) then
    begin
      N := 3;
      if B = $E0 then SecondMin := $A0;
      if B = $ED then SecondMax := $9F;
    end
    else if (B >= $F0) and (B <= $F4) then
    begin
      N := 4;
      if B = $F0 then SecondMin := $90;
      if B = $F4 then SecondMax := $8F;
    end;
    if I+N-1 > Length(S) then N := 0;
    if N > 1 then
    begin
      if (Ord(S[I+1]) < SecondMin) or (Ord(S[I+1]) > SecondMax) then N := 0;
      for J := 2 to N-1 do if (Ord(S[I+J]) < $80) or (Ord(S[I+J]) > $BF) then begin N := 0; Break; end;
    end;
    if N = 0 then
    begin
      if W+3 > MaxBytes then Break;
      Result[W+1] := #239; Result[W+2] := #191; Result[W+3] := #189;
      Inc(W, 3); Inc(I);
    end
    else
    begin
      if W+N > MaxBytes then Break;
      Move(S[I], Result[W+1], N); Inc(W, N); Inc(I, N);
    end;
  end;
  SetLength(Result, W);
end;

function ToolError(const AMessage: string): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create(['error', SafeToolText(AMessage)]);
  try Result := O.AsJSON; finally O.Free; end;
end;

function ParseToolArgs(const S: string): TJSONObject;
var D: TJSONData;
begin
  D := GetJSON(S);
  if not (D is TJSONObject) then
  begin D.Free; raise Exception.Create('Arguments must be a JSON object'); end;
  Result := TJSONObject(D);
end;

function CurrentToolContext: TToolContext;
begin
  Result := GActiveContext;
  if Result.ProjectRoot = '' then Result.ProjectRoot := GetEffectiveProjectDir;
end;

function ToolCancelled: Boolean;
begin
  Result := Assigned(GActiveContext.IsCancelled) and GActiveContext.IsCancelled();
end;

function NotifyToolFileChanged(const APath: string): string;
begin
  Result := '';
  if not Assigned(GActiveContext.OnFileChanged) then Exit;
  try
    GActiveContext.OnFileChanged(APath);
  except on E: Exception do
    Result := 'File changed but its IDE notification failed: ' + E.Message;
  end;
end;

constructor TToolSession.Create;
begin inherited Create; Tasks := TJSONArray.Create; Diagnostics := TJSONObject.Create; end;
destructor TToolSession.Destroy;
begin Tasks.Free; Diagnostics.Free; inherited Destroy; end;
procedure TToolSession.Clear;
begin Tasks.Clear; Diagnostics.Clear; end;

function TAgentTool.ExecuteWithContext(const AArgsJSON: string; const AContext: TToolContext): string;
begin Result := Execute(AArgsJSON); end;

function ToolAllowedForMode(AMode: TAgentMode; const AToolName: string): Boolean;
var T: TAgentTool;
begin
  T := GetToolRegistry.FindTool(AToolName);
  Result := Assigned(T) and (AMode in T.AllowedModes);
end;

function TToolRegistry.CanonicalName(const AName: string): string;
var T: TAgentTool;
begin T := FindTool(AName); if Assigned(T) then Result := T.Name else Result := AName; end;

function TToolRegistry.ToolGuidance(AMode: TAgentMode): string;
var I: Integer; Schema: string;
begin
  Result := 'Available tools (JSON arguments):' + LineEnding;
  for I := 0 to FTools.Count - 1 do
    if FTools[I].Advertised and (AMode in FTools[I].AllowedModes) then
    begin
      Schema := '{}'; if Assigned(FTools[I].ParametersSchema) then Schema := FTools[I].ParametersSchema.AsJSON;
      Result := Result + '- ' + FTools[I].Name + ': ' + FTools[I].Description +
        ' Parameters: ' + Schema + LineEnding;
    end;
end;

function TToolRegistry.ExecuteTool(const AName, AArgsJSON: string): string;
var C: TToolContext;
begin
  C := Default(TToolContext); C.ProjectRoot := GetEffectiveProjectDir; C.Mode := amAgent;
  Result := ExecuteTool(AName, AArgsJSON, C);
end;

function TToolRegistry.ExecuteTool(const AName, AArgsJSON: string; const AContext: TToolContext): string;
var
  Tool: TAgentTool;
  Args: TJSONObject;
  Props: TJSONObject;
  Req: TJSONArray;
  D: TJSONData;
  I: Integer;
  N, Kind: string;
  Previous: TToolContext;
begin
  Tool := FindTool(AName);
  if not Assigned(Tool) then Exit(ToolError('Tool not found: ' + AName));
  if not (AContext.Mode in Tool.AllowedModes) then
    Exit(ToolError('Tool unavailable in ' + ModeToString(AContext.Mode) + ' mode: ' + Tool.Name));
  Previous := GActiveContext;
  GActiveContext := AContext;
  try
    try
      if ToolCancelled then Exit(ToolError('Tool cancelled'));
      Args := ParseToolArgs(AArgsJSON);
      try
        if Assigned(Tool.ParametersSchema) then
        begin
          Req := Tool.ParametersSchema.Find('required') as TJSONArray;
          if Assigned(Req) then
            for I := 0 to Req.Count - 1 do
              if Args.Find(Req.Strings[I]) = nil then
                raise Exception.Create('Missing required parameter: ' + Req.Strings[I]);
          Props := Tool.ParametersSchema.Find('properties') as TJSONObject;
          if Assigned(Props) then
            for I := 0 to Args.Count - 1 do
            begin
              N := Args.Names[I]; D := Props.Find(N);
              if D = nil then Continue;
              Kind := TJSONObject(D).Get('type', ''); D := Args.Items[I];
              if ((Kind = 'string') and (D.JSONType <> jtString)) or
                 ((Kind = 'boolean') and (D.JSONType <> jtBoolean)) or
                 ((Kind = 'array') and (D.JSONType <> jtArray)) or
                 ((Kind = 'integer') and ((D.JSONType <> jtNumber) or (D.AsFloat <> D.AsInt64) or (D.AsFloat > High(Integer)) or (D.AsFloat < Low(Integer)))) then
                raise Exception.Create('Invalid parameter type: ' + N);
            end;
        end;
        if (Tool.Name = 'diagnostics') and (Args.Get('action', 'read') = 'build') and
          (AContext.Mode <> amAgent) then Exit(ToolError('Diagnostic builds require Agent mode'));
      finally Args.Free; end;
      Result := Tool.ExecuteWithContext(AArgsJSON, AContext);
    except on E: Exception do Result := ToolError(E.Message); end;
  finally GActiveContext := Previous; end;
end;

function TToolRegistry.Count: Integer;
begin
  Result := FTools.Count;
end;

initialization

finalization
  if Assigned(GToolRegistry) then
    FreeAndNil(GToolRegistry);

end.
