unit uAgentConfig;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, uAgentTypes;

type
  TAgentConfig = class
  private
    FContextBudget, FRecentTurns: Integer;
    FProvider: TLLMProvider;
    FAPIKey: string;
    FEndpointURL: string;
    FModelName: string;
    FDebuggingMode: Boolean;
    FModelList: TStringList;
    FConfigFile: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Load;
    procedure Save;
    procedure SetModels(ANewList: TStrings);

    property ContextBudget: Integer read FContextBudget write FContextBudget;
    property RecentTurns: Integer read FRecentTurns write FRecentTurns;
    property Provider: TLLMProvider read FProvider write FProvider;
    property APIKey: string read FAPIKey write FAPIKey;
    property EndpointURL: string read FEndpointURL write FEndpointURL;
    property ModelName: string read FModelName write FModelName;
    property DebuggingMode: Boolean read FDebuggingMode write FDebuggingMode;
    property ModelList: TStringList read FModelList;
  end;

function GetAgentConfig: TAgentConfig;

implementation

var
  GAgentConfig: TAgentConfig = nil;

function GetConfigFilePath: string;
var
  ConfigDir: string;
begin
  ConfigDir := GetAppConfigDir(False);
  if not DirectoryExists(ConfigDir) then
    ForceDirectories(ConfigDir);
  Result := IncludeTrailingPathDelimiter(ConfigDir) + 'codingagent.ini';
end;

function GetAgentConfig: TAgentConfig;
begin
  if not Assigned(GAgentConfig) then
  begin
    GAgentConfig := TAgentConfig.Create;
    GAgentConfig.Load;
  end;
  Result := GAgentConfig;
end;

{ TAgentConfig }

constructor TAgentConfig.Create;
begin
  inherited Create;
  FConfigFile := GetConfigFilePath;
  FModelList := TStringList.Create;
  FProvider := lpOpenAI;
  FAPIKey := '';
  FEndpointURL := GetDefaultEndpoint(lpOpenAI);
  FModelName := GetDefaultModel(lpOpenAI);
  FDebuggingMode := False;
  FContextBudget := 32768; FRecentTurns := 2;
  GetDefaultModelList(lpOpenAI, FModelList);
end;

destructor TAgentConfig.Destroy;
begin
  FModelList.Free;
  inherited Destroy;
end;

procedure TAgentConfig.SetModels(ANewList: TStrings);
begin
  FModelList.Assign(ANewList);
end;

procedure TAgentConfig.Load;
var
  Ini: TIniFile;
  ProvStr: string;
  Count, I: Integer;
  MName: string;
begin
  if not FileExists(FConfigFile) then
  begin
    GetDefaultModelList(FProvider, FModelList);
    Exit;
  end;

  Ini := TIniFile.Create(FConfigFile);
  try
    ProvStr := Ini.ReadString('LLM', 'Provider', 'OpenAI');
    FProvider := StringToProvider(ProvStr);
    FAPIKey := Ini.ReadString('LLM', 'APIKey', FAPIKey);
    FEndpointURL := Ini.ReadString('LLM', 'EndpointURL', GetDefaultEndpoint(FProvider));
    FModelName := Ini.ReadString('LLM', 'ModelName', GetDefaultModel(FProvider));
    FDebuggingMode := Ini.ReadBool('General', 'DebuggingMode', False);
    FContextBudget := Ini.ReadInteger('Context', 'InputBudget', 32768);
    FRecentTurns := Ini.ReadInteger('Context', 'RecentTurns', 2);
    if (FContextBudget < 4096) or (FContextBudget > 2000000) then FContextBudget := 32768;
    if (FRecentTurns < 0) or (FRecentTurns > 100) then FRecentTurns := 2;

    Count := Ini.ReadInteger('Models', 'Count', 0);
    FModelList.Clear;
    if Count > 0 then
    begin
      for I := 0 to Count - 1 do
      begin
        MName := Ini.ReadString('Models', 'Model_' + IntToStr(I), '');
        if MName <> '' then
          FModelList.Add(MName);
      end;
    end;

    if FModelList.Count = 0 then
      GetDefaultModelList(FProvider, FModelList);

    if (FModelName <> '') and (FModelList.IndexOf(FModelName) < 0) then
      FModelList.Insert(0, FModelName);

    if (FModelName = '') and (FModelList.Count > 0) then
      FModelName := FModelList[0];
  finally
    Ini.Free;
  end;
end;

procedure TAgentConfig.Save;
var
  Ini: TIniFile;
  I: Integer;
begin
  Ini := TIniFile.Create(FConfigFile);
  try
    Ini.WriteString('LLM', 'Provider', ProviderToString(FProvider));
    Ini.WriteString('LLM', 'APIKey', FAPIKey);
    Ini.WriteString('LLM', 'EndpointURL', FEndpointURL);
    Ini.WriteString('LLM', 'ModelName', FModelName);
    Ini.WriteBool('General', 'DebuggingMode', FDebuggingMode);
    Ini.WriteInteger('Context', 'InputBudget', FContextBudget);
    Ini.WriteInteger('Context', 'RecentTurns', FRecentTurns);

    // Save models list
    Ini.EraseSection('Models');
    Ini.WriteInteger('Models', 'Count', FModelList.Count);
    for I := 0 to FModelList.Count - 1 do
      Ini.WriteString('Models', 'Model_' + IntToStr(I), FModelList[I]);
  finally
    Ini.Free;
  end;
end;

initialization

finalization
  if Assigned(GAgentConfig) then
    FreeAndNil(GAgentConfig);

end.
