unit uFrmChatSession;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  fpjson, jsonparser,
  uAgentTypes, uAgentCore, uAgentThread, uToolBase, uAgentHistory, uFrmSettings, uFrmPlanResult,
  uMarkdownView;

type
  { TFrmChatSession }

  TFrmChatSession = class(TFrame)
    BtnSend: TButton;
    BtnStop: TButton;
    BtnClear: TButton;
    BtnSettings: TButton;
    BtnHelp: TButton;
    CmbMode: TComboBox;
    CmbModel: TComboBox;
    LblMode: TLabel;
    LblModel: TLabel;
    LblStatus: TLabel;
    LblProjectDir: TLabel;
    PnlChatHistory: TPanel;
    MemInput: TMemo;
    PnlTop: TPanel;
    PnlBottom: TPanel;
    procedure BtnClearClick(Sender: TObject);
    procedure BtnHelpClick(Sender: TObject);
    procedure BtnSendClick(Sender: TObject);
    procedure BtnSettingsClick(Sender: TObject);
    procedure BtnStopClick(Sender: TObject);
    procedure CmbModeChange(Sender: TObject);
    procedure CmbModelChange(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure MemInputKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure MemInputChange(Sender: TObject);
    procedure MemInputEnter(Sender: TObject);
  private
    FAgent: TAgentCore;
    FWorkerThread: TAgentWorkerThread;
    FReasoningBuffer: string;
    FContentBuffer: string;
    FPlanFilePath: string;
    FPlanFileContent: string;
    FAgentChangedFiles: TStringList;
    FRefreshTargets: TStringList;
    FCommandRefreshPending: Boolean;
    FTrackingWarning: string;
    FRunMode: TAgentMode;
    FRunProjectRoot: string;
    FHistoryMarkdown: string;
    FChatView: TMarkdownView;
    FOnStateChange: TNotifyEvent;
    FRestoredInterrupted: Boolean;
    FTitle: string;
    FContextSnapshot: TJSONObject;
    FRefreshingModelList: Boolean;
    FBlockedByOtherSession: Boolean;
    FPlanDialogOpen: Boolean;
    procedure Changed;
    procedure UpdateSendAvailability;
    procedure RefreshContextSnapshot;
    procedure HandleWorkerProgress(const AText: string);
    function GetTabCaption: string;
    function GetIsRunning: Boolean;

    procedure AppendToHistory(const ARole, AText: string);
    procedure ScrollChatToBottom(Data: PtrInt);
    procedure AppendAssistantMessage(const AAnswer, AThinking: string);
    procedure ParseAssistantPayload(const ARaw: string; out AAnswer, AThinking: string);
    procedure UpdateStatus(const AStatus: string);
    procedure UpdateProjectDirectoryInfo;
    procedure RefreshModelList;
    procedure HandleThreadChunk(const AChunk: string; AIsReasoning: Boolean);
    procedure HandleToolCompleted(const AToolName, AToolResult: string);
    procedure HandleFileChanged(const APath: string);
    procedure RefreshIDEPaths(APaths: TStrings);
    procedure FinishCommandRefresh;
    function DescribeToolActivity(const AToolName, AToolArgs: string): string;
    function DescribeToolFailure(const AToolResult: string): string;
    procedure HandleThreadCompleted(ASuccess: Boolean; const AFinalText: string);
  protected
    procedure HandleToolExecuting(const AToolName, AToolArgs: string);
    property HistoryMarkdown: string read FHistoryMarkdown;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadState(AData: TJSONObject);
    procedure MarkInterrupted;
    procedure StopRun;
    procedure SetSharedSettingsEnabled(AEnabled: Boolean);
    procedure SetSharedRunBlocked(ABlocked: Boolean);
    procedure SynchronizeSharedModel;
    procedure RefreshProjectDirectoryInfo;
    property IsRunning: Boolean read GetIsRunning;
    function SaveState: TJSONObject;
    property OnStateChange: TNotifyEvent read FOnStateChange write FOnStateChange;
    property TabCaption: string read GetTabCaption;
  end;

implementation

function FirstTwoWords(const S: string): string;
var I, StartAt, Words: Integer;
begin
  Result := ''; I := 1; Words := 0;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and (S[I] <= ' ') do Inc(I);
    if I > Length(S) then Break;
    StartAt := I;
    while (I <= Length(S)) and (S[I] > ' ') do Inc(I);
    if Result <> '' then Result := Result + ' ';
    Result := Result + Copy(S, StartAt, I - StartAt);
    Inc(Words);
    if Words = 2 then Break;
  end;
  if Result = '' then Result := 'New Chat';
end;

{$R *.lfm}

{ TFrmChat }

constructor TFrmChatSession.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAgent := TAgentCore.Create;
  FOnStateChange := nil;
  FRestoredInterrupted := False;
  FTitle := 'New Chat';
  FContextSnapshot := nil;
  FWorkerThread := nil;

  CmbMode.ItemIndex := 0; { amAsk }
  FAgent.Mode := amAsk;
  UpdateStatus('Ready');
  FReasoningBuffer := '';
  FContentBuffer := '';
  FPlanFilePath := '';
  FPlanFileContent := '';
  FAgentChangedFiles := TStringList.Create;
  FAgentChangedFiles.CaseSensitive := {$IFDEF WINDOWS}False{$ELSE}True{$ENDIF};
  FAgentChangedFiles.Duplicates := dupIgnore;
  FAgentChangedFiles.Sorted := True;
  FRefreshTargets := TStringList.Create;
  FRefreshTargets.CaseSensitive := FAgentChangedFiles.CaseSensitive;
  FRefreshTargets.Duplicates := dupIgnore;
  FRefreshTargets.Sorted := True;
  FBlockedByOtherSession := False;
  FPlanDialogOpen := False;
  FRunMode := amAsk;
  FHistoryMarkdown := '';
  FChatView := TMarkdownView.Create(Self);
  FChatView.Parent := PnlChatHistory;
  FChatView.Align := alClient;
  FChatView.SetMarkdown('');
  RefreshModelList;
  RefreshContextSnapshot;
  UpdateProjectDirectoryInfo;
end;

procedure TFrmChatSession.FormShow(Sender: TObject);
begin
  UpdateProjectDirectoryInfo;
end;

procedure TFrmChatSession.MemInputEnter(Sender: TObject);
begin
  UpdateProjectDirectoryInfo;
end;

procedure TFrmChatSession.RefreshProjectDirectoryInfo;
begin
  UpdateProjectDirectoryInfo;
end;

procedure TFrmChatSession.UpdateProjectDirectoryInfo;
var
  ProjDir: string;
begin
  { Refresh IDE context on the UI thread before a run; freeze it while a worker
    owns its project snapshot. Standalone callers keep their selected directory. }
  if (FWorkerThread = nil) and Assigned(GProjectDirProvider) then
  begin
    try ProjDir := GProjectDirProvider(); except ProjDir := ''; end;
    if not DirectoryExists(ProjDir) then ProjDir := GetCurrentDir;
    SetEffectiveProjectDir(ProjDir);
  end;
  ProjDir := GetEffectiveProjectDir;
  if Length(ProjDir) > 45 then
    LblProjectDir.Caption := '📁 ...' + Copy(ProjDir, Length(ProjDir) - 40, 41)
  else
    LblProjectDir.Caption := '📁 ' + ProjDir;
  LblProjectDir.Hint := 'Active Project: ' + ProjDir;
end;

destructor TFrmChatSession.Destroy;
begin
  StopRun;
  FreeAndNil(FAgentChangedFiles);
  FreeAndNil(FRefreshTargets);
  FreeAndNil(FContextSnapshot);
  FAgent.Free;
  inherited Destroy;
end;

procedure TFrmChatSession.RefreshModelList;
var
  Idx: Integer;
begin
  FRefreshingModelList := True;
  CmbModel.Items.BeginUpdate;
  try
    CmbModel.Items.Assign(FAgent.Config.ModelList);
    if CmbModel.Items.Count = 0 then
      GetDefaultModelList(FAgent.Config.Provider, CmbModel.Items);

    if (FAgent.Config.ModelName <> '') and (CmbModel.Items.IndexOf(FAgent.Config.ModelName) < 0) then
      CmbModel.Items.Insert(0, FAgent.Config.ModelName);

    Idx := CmbModel.Items.IndexOf(FAgent.Config.ModelName);
    if Idx >= 0 then
      CmbModel.ItemIndex := Idx
    else if CmbModel.Items.Count > 0 then
    begin
      CmbModel.ItemIndex := 0;
      FAgent.Config.ModelName := CmbModel.Items[0];
    end;
  finally
    CmbModel.Items.EndUpdate;
    FRefreshingModelList := False;
  end;
end;

procedure TFrmChatSession.CmbModelChange(Sender: TObject);
begin
  if FRefreshingModelList then Exit;
  if CmbModel.ItemIndex >= 0 then
  begin
    FAgent.Config.ModelName := CmbModel.Items[CmbModel.ItemIndex];
    FAgent.Config.Save;
    Changed;
  end;
end;

procedure TFrmChatSession.BtnHelpClick(Sender: TObject);
begin
  ShowMessage(
    'Lazarus Coding Agent' + LineEnding + LineEnding +
    'Modes:' + LineEnding +
    '  - Ask   : Quick questions, Pascal explanations, syntax guidance' + LineEnding +
    '  - Plan  : Multi-step task decomposition and roadmaps' + LineEnding +
    '  - Agent : Autonomous coding, refactoring, and file tool execution' + LineEnding + LineEnding +
    'Shortcuts:' + LineEnding +
    '  - Ctrl+Alt+A : Toggle this chat window on/off in Lazarus IDE' + LineEnding +
    '  - Ctrl+Enter : Send message from the input box' + LineEnding + LineEnding +
    'Configure API keys, providers, and models in Settings (⚙).'
  );
end;

procedure TFrmChatSession.CmbModeChange(Sender: TObject);
begin
  case CmbMode.ItemIndex of
    0: FAgent.Mode := amAsk;
    1: FAgent.Mode := amPlan;
    2: FAgent.Mode := amAgent;
  end;
  Changed;
end;

procedure TFrmChatSession.BtnSettingsClick(Sender: TObject);
var
  SettingsForm: TFrmSettings;
begin
  SettingsForm := TFrmSettings.Create(Self);
  try
    SettingsForm.ProjectRoot := GetEffectiveProjectDir;
    if SettingsForm.ShowModal = mrOk then
    begin
      FAgent.Config.Load;
      RefreshModelList;
      Changed;
    end;
  finally
    SettingsForm.Free;
  end;
end;

procedure TFrmChatSession.BtnClearClick(Sender: TObject);
begin
  if FPlanDialogOpen then Exit;
  StopRun;

  FHistoryMarkdown := '';
  FChatView.SetMarkdown('');
  FReasoningBuffer := '';
  FContentBuffer := '';
  FPlanFilePath := '';
  FPlanFileContent := '';
  FAgentChangedFiles.Clear; FRefreshTargets.Clear; FTrackingWarning := '';
  FAgent.ClearHistory;
  RefreshContextSnapshot;
  UpdateStatus('Ready');
  Changed;
end;

procedure TFrmChatSession.BtnStopClick(Sender: TObject);
begin
  if Assigned(FWorkerThread) then
  begin
    FWorkerThread.Terminate;
    UpdateStatus('Stopping...');
  end;
end;

procedure TFrmChatSession.UpdateSendAvailability;
begin
  if BtnSend.Visible then
    BtnSend.Enabled := (not Assigned(FWorkerThread)) and (not FBlockedByOtherSession) and
      (not FPlanDialogOpen);
end;

procedure TFrmChatSession.SetSharedRunBlocked(ABlocked: Boolean);
begin
  if FBlockedByOtherSession = ABlocked then Exit;
  FBlockedByOtherSession := ABlocked;
  UpdateSendAvailability;
  if ABlocked and not Assigned(FWorkerThread) then
    UpdateStatus('Another chat is running.')
  else if not Assigned(FWorkerThread) and not FPlanDialogOpen then
    UpdateStatus('Ready');
end;

procedure TFrmChatSession.BtnSendClick(Sender: TObject);
var
  Prompt: string;
begin
  if Assigned(FWorkerThread) or FBlockedByOtherSession or FPlanDialogOpen then
    Exit;

  Prompt := Trim(MemInput.Text);
  if Prompt = '' then
    Exit;

  // Refresh active project directory on the UI thread
  UpdateProjectDirectoryInfo;

  MemInput.Clear;
  if FTitle = 'New Chat' then FTitle := FirstTwoWords(Prompt);
  AppendToHistory('User', Prompt);
  UpdateStatus('Thinking...');

  BtnSend.Visible := False;
  BtnStop.Visible := True;
  BtnStop.Enabled := True;

  FReasoningBuffer := '';
  FContentBuffer := '';
  FPlanFilePath := '';
  FPlanFileContent := '';
  FAgentChangedFiles.Clear;
  FRefreshTargets.Clear;
  FTrackingWarning := '';
  FRunMode := FAgent.Mode;
  FRunProjectRoot := GetEffectiveProjectDir;
  CmbMode.Enabled := False;
  CmbModel.Enabled := False;
  BtnSettings.Enabled := False;

  FWorkerThread := TAgentWorkerThread.Create(
    FAgent,
    Prompt,
    @HandleThreadChunk,
    @HandleToolExecuting,
    @HandleToolCompleted,
    @HandleThreadCompleted,
    @HandleFileChanged,
    @HandleWorkerProgress, FRunProjectRoot
  );
  Changed;
  FWorkerThread.Start;
end;

procedure TFrmChatSession.HandleThreadChunk(const AChunk: string; AIsReasoning: Boolean);
begin
  RefreshContextSnapshot;
  if AIsReasoning then
    FReasoningBuffer := FReasoningBuffer + AChunk
  else
    FContentBuffer := FContentBuffer + AChunk;
end;

procedure TFrmChatSession.HandleToolExecuting(const AToolName, AToolArgs: string);
var
  Activity, Command, Fence: string;
  Data, CommandData: TJSONData;
  I, Backticks, MaxBackticks: SizeInt;
begin
  RefreshContextSnapshot;
  FRefreshTargets.Clear; { paths notified during this tool, not the whole run }
  FinishCommandRefresh;
  if Assigned(GAgentIDECommandRefreshProc) and
    Assigned(GetToolRegistry.FindTool(AToolName)) and
    GetToolRegistry.FindTool(AToolName).MutatesFiles then
  begin
    FCommandRefreshPending := True;
    try
      Command := GAgentIDECommandRefreshProc(FRunProjectRoot, True);
      if Command <> '' then AppendToHistory('IDE Refresh', Command);
    except on E: Exception do AppendToHistory('IDE Refresh', E.Message); end;
  end;
  { This response requested a tool; it is intermediate, not user-facing final text. }
  FReasoningBuffer := '';
  FContentBuffer := '';
  Activity := DescribeToolActivity(AToolName, AToolArgs);
  UpdateStatus(Activity);
  if SameText(GetToolRegistry.CanonicalName(AToolName), 'shell') then
  begin
    Command := '';
    try
      Data := GetJSON(AToolArgs);
      try
        if Data is TJSONObject then
        begin
          CommandData := TJSONObject(Data).Find('command');
          if Assigned(CommandData) and (CommandData.JSONType = jtString) then
            Command := CommandData.AsString;
        end;
      finally
        Data.Free;
      end;
    except
      { Invalid tool arguments must not interrupt UI updates. }
    end;
    if Trim(Command) <> '' then
    begin
      { A longer fence keeps every backtick sequence in the command literal. }
      Backticks := 0;
      MaxBackticks := 2;
      for I := 1 to Length(Command) do
        if Command[I] = '`' then
        begin
          Inc(Backticks);
          if Backticks > MaxBackticks then MaxBackticks := Backticks;
        end
        else Backticks := 0;
      Fence := StringOfChar('`', MaxBackticks + 1);
      Activity := 'Running shell command:' + LineEnding + LineEnding +
        Fence + LineEnding + Command + LineEnding + Fence;
    end;
  end;
end;

function TFrmChatSession.DescribeToolActivity(const AToolName, AToolArgs: string): string;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Path, PathLabel: string;
begin
  Path := '';
  try
    Data := GetJSON(AToolArgs);
    try
      if Data.JSONType = jtObject then
      begin
        Obj := TJSONObject(Data);
        Path := Obj.Get('path', '');
      end;
    finally
      Data.Free;
    end;
  except
    { Activity summaries do not depend on valid JSON arguments. }
  end;

  PathLabel := ExtractFileName(ExcludeTrailingPathDelimiter(Path));
  if PathLabel = '' then PathLabel := 'project files';

  if SameText(AToolName, 'list_files') then
    Result := 'Reading files in ' + PathLabel + '...'
  else if SameText(AToolName, 'read_file') then
    Result := 'Reading ' + PathLabel + '...'
  else if SameText(AToolName, 'write_file') then
    Result := 'Updating ' + PathLabel + '...'
  else if SameText(AToolName, 'create_plan_file') then
    Result := 'Saving Markdown plan to the project...'
  else
    Result := 'Running ' + AToolName + '...';
end;

procedure TFrmChatSession.RefreshIDEPaths(APaths: TStrings);
var Error: string;
begin
  if (APaths.Count = 0) or not Assigned(GAgentIDERefreshProc) then Exit;
  try
    Error := GAgentIDERefreshProc(APaths, FRunProjectRoot);
    if Error <> '' then AppendToHistory('IDE Refresh', Error);
  except on E: Exception do
    AppendToHistory('IDE Refresh', 'Could not refresh changed files: ' + E.Message);
  end;
end;

procedure TFrmChatSession.HandleFileChanged(const APath: string);
var Paths: TStringList;
begin
  if APath = '' then Exit;
  FAgentChangedFiles.Add(APath);
  FRefreshTargets.Add(APath);
  Paths := TStringList.Create;
  try
    Paths.Add(APath);
    RefreshIDEPaths(Paths);
  finally Paths.Free; end;
end;

procedure TFrmChatSession.FinishCommandRefresh;
var Error: string;
begin
  if not FCommandRefreshPending then Exit;
  FCommandRefreshPending := False;
  if not Assigned(GAgentIDECommandRefreshProc) then Exit;
  try
    Error := GAgentIDECommandRefreshProc(FRunProjectRoot, False);
    if Error <> '' then AppendToHistory('IDE Refresh', Error);
  except on E: Exception do AppendToHistory('IDE Refresh', E.Message); end;
end;

function TFrmChatSession.DescribeToolFailure(const AToolResult: string): string;
var
  Data: TJSONData;
  Obj: TJSONObject;
begin
  Result := 'The tool reported an error.';
  try
    Data := GetJSON(AToolResult);
    try
      if Data.JSONType = jtObject then
      begin
        Obj := TJSONObject(Data);
        Result := Obj.Get('error', Result);
        if Result = '' then
          Result := Obj.Get('message', 'The tool reported an error.');
      end;
    finally
      Data.Free;
    end;
  except
    if Trim(AToolResult) <> '' then
      Result := Trim(AToolResult);
  end;
end;

procedure TFrmChatSession.HandleToolCompleted(const AToolName, AToolResult: string);
var
  Data: TJSONData;
  Obj: TJSONObject;
  ChangedPath, Canonical: string;
  ChangedPaths: TJSONArray;
  Tasks: TJSONArray;
  I: Integer;
  Summary: string;
begin
  RefreshContextSnapshot;
  Canonical := GetToolRegistry.CanonicalName(AToolName);
  UpdateStatus('Tool ' + Canonical + ' completed');
  if SameText(Canonical, 'create_plan_file') then
  begin
    FPlanFilePath := ''; FPlanFileContent := '';
    try
      Data := GetJSON(AToolResult);
      try
        if Data.JSONType = jtObject then
        begin
          Obj := TJSONObject(Data);
          if SameText(Obj.Get('status', ''), 'success') then
          begin
            FPlanFilePath := Obj.Get('path', '');
            FPlanFileContent := Obj.Get('content', '');
          end;
        end;
      finally
        Data.Free;
      end;
    except
      FPlanFilePath := '';
      FPlanFileContent := '';
    end;
    if FPlanFilePath <> '' then
      AppendToHistory('Plan Saved', FPlanFilePath)
    else
      AppendToHistory('Plan Save Error', DescribeToolFailure(AToolResult));
    if FAgent.Config.DebuggingMode then
      AppendToHistory('Tool Result: ' + AToolName, AToolResult);
    FinishCommandRefresh;
    Exit;
  end;
  try
    Data := GetJSON(AToolResult);
    try
      if Data is TJSONObject then
      begin
        Obj := TJSONObject(Data);
        ChangedPaths := Obj.Find('changed_paths') as TJSONArray;
        if Assigned(ChangedPaths) then for I := 0 to ChangedPaths.Count-1 do
        begin
          ChangedPath := ChangedPaths.Strings[I];
          if (ChangedPath <> '') and (FAgentChangedFiles.IndexOf(ChangedPath) < 0) then
            FAgentChangedFiles.Add(ChangedPath);
          { Compatibility for custom tools that only return changed_paths. }
          if (ChangedPath <> '') and (FRefreshTargets.IndexOf(ChangedPath) < 0) then
            HandleFileChanged(ChangedPath);
        end;
        if Obj.Get('tracking_warning', '') <> '' then
          FTrackingWarning := Obj.Get('tracking_warning', '');
        if Canonical = 'todo' then
        begin
          Tasks := Obj.Find('items') as TJSONArray; Summary := '';
          if Assigned(Tasks) then for I := 0 to Tasks.Count-1 do
            Summary := Summary + '- ' + TJSONObject(Tasks[I]).Get('status', '') + ': ' +
              TJSONObject(Tasks[I]).Get('text', '') + LineEnding;
          if Assigned(Tasks) then AppendToHistory('Tasks', Summary);
        end;
      end;
    finally Data.Free; end;
  except
    { Malformed tool results must not cause UI failures. }
  end;
  { Explicit paths consume their snapshots before the fallback disk comparison. }
  FinishCommandRefresh;
  if (not FAgent.Config.DebuggingMode) and (Pos('"error"', LowerCase(AToolResult)) > 0) then
    AppendToHistory('Tool Error: ' + AToolName, DescribeToolFailure(AToolResult));
  if FAgent.Config.DebuggingMode then
    AppendToHistory('Tool Result: ' + AToolName, AToolResult);
end;

procedure TFrmChatSession.HandleThreadCompleted(ASuccess: Boolean; const AFinalText: string);
var
  RawText, AnswerText, ThinkingText, Completion, PlanContent: string;
  PlanForm: TFrmPlanResult;
  BuildPrompt, SavedPlanPath, SavedPlanContent: string;
  Context: TToolContext;
  Args: TJSONObject;
  I, PlanStart, PlanEnd: Integer;
begin
  FWorkerThread := nil;
  RefreshContextSnapshot;
  FinishCommandRefresh;
  FRefreshTargets.Clear;
  BtnStop.Visible := False;
  BtnSend.Visible := True;
  CmbMode.Enabled := True;
  CmbModel.Enabled := True;
  BtnSettings.Enabled := True;
  UpdateSendAvailability;

  RawText := AFinalText;
  if ASuccess and (RawText = '') then RawText := FContentBuffer;
  ParseAssistantPayload(RawText, AnswerText, ThinkingText);
  if FReasoningBuffer <> '' then
  begin
    if ThinkingText <> '' then ThinkingText := ThinkingText + LineEnding + LineEnding;
    ThinkingText := ThinkingText + FReasoningBuffer;
  end;
  { Clear the old run before the modal preview can start a new worker. }
  FReasoningBuffer := '';
  FContentBuffer := '';

  if ASuccess then
  begin
    UpdateStatus('Ready');
    if AnswerText <> '' then AppendAssistantMessage(AnswerText, ThinkingText);
    if (FRunMode = amPlan) and (FPlanFilePath = '') then
    begin
      PlanStart := Pos('<proposed_plan>', AnswerText);
      PlanEnd := Pos('</proposed_plan>', AnswerText);
      if (PlanStart > 0) and (PlanEnd > PlanStart) then
      begin
        PlanContent := Trim(Copy(AnswerText, PlanStart + Length('<proposed_plan>'),
          PlanEnd - PlanStart - Length('<proposed_plan>')));
        if PlanContent <> '' then
        begin
          Context := Default(TToolContext);
          Context.Mode := amPlan; Context.ProjectRoot := FRunProjectRoot;
          Context.Session := FAgent.ToolSession;
          Args := TJSONObject.Create(['content', PlanContent]);
          try
            HandleToolCompleted('create_plan_file',
              GetToolRegistry.ExecuteTool('create_plan_file', Args.AsJSON, Context));
          finally Args.Free; end;
          UpdateStatus('Ready');
        end;
      end;
    end;
  end
  else
  begin
    UpdateStatus('Error');
    if AFinalText <> '' then AppendToHistory('Error', AFinalText);
  end;

  if FRunMode = amAgent then
  begin
    if ASuccess then Completion := 'Request done.'
    else if Pos('cancelled', LowerCase(AFinalText)) > 0 then Completion := 'Request cancelled.'
    else Completion := 'Request incomplete.';
    Completion := Completion + LineEnding + LineEnding;
    if FAgentChangedFiles.Count = 0 then
    begin
      if FTrackingWarning = '' then Completion := Completion + 'No project files changed.'
      else Completion := Completion + 'No changed project files could be identified.';
    end
    else
    begin
      Completion := Completion + 'Files changed:' + LineEnding;
      for I := 0 to FAgentChangedFiles.Count - 1 do
        Completion := Completion + '- ' +
          ExtractRelativePath(IncludeTrailingPathDelimiter(FRunProjectRoot), FAgentChangedFiles[I]) + LineEnding;
    end;
    if FTrackingWarning <> '' then Completion := Completion + LineEnding + LineEnding + FTrackingWarning;
    AppendToHistory('Completion', Completion);
  end;
  FAgentChangedFiles.Clear;
  FTrackingWarning := '';

  if ASuccess and (FRunMode = amPlan) and (FPlanFilePath <> '') then
  begin
    SavedPlanPath := FPlanFilePath;
    SavedPlanContent := FPlanFileContent;
    FPlanDialogOpen := True;
    UpdateSendAvailability;
    BtnClear.Enabled := False;
    PlanForm := TFrmPlanResult.Create(Self);
    try
      PlanForm.LoadPlan(SavedPlanPath, SavedPlanContent);
      if PlanForm.ShowModal = mrOk then
      begin
        FAgent.Mode := amAgent;
        CmbMode.ItemIndex := 2;
        BuildPrompt := 'Implement the plan saved at ' + SavedPlanPath +
          '. First inspect the project files, then carry out the plan completely.' +
          LineEnding + LineEnding + SavedPlanContent;
        MemInput.Text := BuildPrompt;
        FPlanDialogOpen := False;
        BtnClear.Enabled := True;
        UpdateSendAvailability;
        BtnSendClick(BtnSend);
      end;
    finally
      PlanForm.Free;
      FPlanDialogOpen := False;
      BtnClear.Enabled := True;
      UpdateSendAvailability;
    end;
  end;
  Changed;
end;

procedure TFrmChatSession.MemInputChange(Sender: TObject);
begin
  Changed;
end;

procedure TFrmChatSession.MemInputKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  { Send on Ctrl+Enter }
  if (Key = 13) and (ssCtrl in Shift) then
  begin
    Key := 0;
    BtnSendClick(Sender);
  end;
end;

procedure TFrmChatSession.AppendToHistory(const ARole, AText: string);
begin
  if FHistoryMarkdown <> '' then
    FHistoryMarkdown := FHistoryMarkdown + LineEnding + LineEnding;
  FHistoryMarkdown := FHistoryMarkdown + '**' + ARole + '**' +
    LineEnding + LineEnding + AText;
  FChatView.SetMarkdown(FHistoryMarkdown);
  Changed;
  Application.QueueAsyncCall(@ScrollChatToBottom, 0);
end;

procedure TFrmChatSession.ScrollChatToBottom(Data: PtrInt);
begin
  if Assigned(FChatView) then
    FChatView.ScrollToBottom;
end;

procedure TFrmChatSession.AppendAssistantMessage(const AAnswer, AThinking: string);
begin
  if AThinking <> '' then
    AppendToHistory('Thinking', AThinking);
  AppendToHistory('Agent (' + ModeToString(FRunMode) + ')', AAnswer);
end;

procedure TFrmChatSession.ParseAssistantPayload(const ARaw: string; out AAnswer, AThinking: string);
var
  Data: TJSONData;
  ParseText: string;
  FoundAnswer: Boolean;
  OtherText: string;

  procedure AddText(var ATarget: string; const AText: string);
  begin
    if Trim(AText) = '' then Exit;
    if ATarget <> '' then ATarget := ATarget + LineEnding + LineEnding;
    ATarget := ATarget + AText;
  end;

  function JSONValueText(AValue: TJSONData): string;
  var
    J: Integer;
    S, Part: string;
    Nested: TJSONData;
  begin
    case AValue.JSONType of
      jtString:
        begin
          S := AValue.AsString;
          if (Trim(S) <> '') and (Trim(S)[1] in ['{', '[']) then
          begin
            try
              Nested := GetJSON(S);
              try
                Result := JSONValueText(Nested);
              finally
                Nested.Free;
              end;
              Exit;
            except
              { Keep ordinary text unchanged. }
            end;
          end;
          Result := S;
        end;
      jtObject:
        begin
          Result := '';
          for J := 0 to TJSONObject(AValue).Count - 1 do
          begin
            Part := TJSONObject(AValue).Names[J] + ': ' +
              JSONValueText(TJSONObject(AValue).Items[J]);
            AddText(Result, Part);
          end;
        end;
      jtArray:
        begin
          Result := '';
          for J := 0 to TJSONArray(AValue).Count - 1 do
            AddText(Result, JSONValueText(TJSONArray(AValue).Items[J]));
        end;
    else
      Result := AValue.AsJSON;
    end;
  end;

  function IsThinkingKey(const AKey: string): Boolean;
  var
    K: string;
  begin
    K := LowerCase(AKey);
    Result := (K = 'thinking') or (K = 'thought') or (K = 'thoughts') or
      (K = 'reasoning') or (K = 'reasoning_content') or (K = 'analysis') or
      (K = 'chain_of_thought') or (K = 'internal_reasoning');
  end;

  function IsAnswerKey(const AKey: string): Boolean;
  var
    K: string;
  begin
    K := LowerCase(AKey);
    Result := (K = 'answer') or (K = 'final') or (K = 'final_answer') or
      (K = 'final_response') or (K = 'response') or (K = 'output') or
      (K = 'message') or (K = 'text') or (K = 'result') or (K = 'content');
  end;

  procedure VisitJSON(AValue: TJSONData; const APath: string);
  var
    J: Integer;
    ChildKey, ChildPath, ScalarText: string;
    NestedData: TJSONData;
  begin
    if AValue.JSONType = jtObject then
    begin
      for J := 0 to TJSONObject(AValue).Count - 1 do
      begin
        ChildKey := TJSONObject(AValue).Names[J];
        ChildPath := ChildKey;
        if APath <> '' then ChildPath := APath + '.' + ChildKey;
        if IsThinkingKey(ChildKey) then
          AddText(AThinking, JSONValueText(TJSONObject(AValue).Items[J]))
        else if IsAnswerKey(ChildKey) then
        begin
          FoundAnswer := True;
          AddText(AAnswer, JSONValueText(TJSONObject(AValue).Items[J]));
        end
        else
          VisitJSON(TJSONObject(AValue).Items[J], ChildPath);
      end;
    end
    else if AValue.JSONType = jtArray then
    begin
      for J := 0 to TJSONArray(AValue).Count - 1 do
        VisitJSON(TJSONArray(AValue).Items[J], APath + '[' + IntToStr(J) + ']');
    end
    else if AValue.JSONType = jtString then
    begin
      ScalarText := AValue.AsString;
      { Providers sometimes JSON-encode the assistant object inside content. }
      if (Trim(ScalarText) <> '') and (Trim(ScalarText)[1] in ['{', '[']) then
      begin
        try
          NestedData := GetJSON(ScalarText);
          try
            VisitJSON(NestedData, APath);
          finally
            NestedData.Free;
          end;
          Exit;
        except
          { Treat a non-JSON string as normal text. }
        end;
      end;
      if APath <> '' then ScalarText := APath + ': ' + ScalarText;
      AddText(OtherText, ScalarText);
    end
    else
    begin
      ScalarText := JSONValueText(AValue);
      if APath <> '' then ScalarText := APath + ': ' + ScalarText;
      AddText(OtherText, ScalarText);
    end;
  end;
begin
  AAnswer := ARaw;
  AThinking := '';
  if Trim(ARaw) = '' then Exit;
  ParseText := Trim(ARaw);
  { Accept the common fenced JSON form emitted by chat models. }
  if (Copy(ParseText, 1, 3) = '```') then
  begin
    Delete(ParseText, 1, 3);
    if (Length(ParseText) >= 4) and (LowerCase(Copy(ParseText, 1, 4)) = 'json') then
      Delete(ParseText, 1, 4);
    if (Length(ParseText) >= 3) and (Copy(ParseText, Length(ParseText) - 2, 3) = '```') then
      Delete(ParseText, Length(ParseText) - 2, 3);
    ParseText := Trim(ParseText);
  end;
  try
    Data := GetJSON(ParseText);
    try
      FoundAnswer := False;
      OtherText := '';
      if Data.JSONType = jtString then
      begin
        ParseText := Data.AsString;
        if (Trim(ParseText) <> '') and (Trim(ParseText)[1] in ['{', '[']) then
        begin
          Data.Free;
          Data := GetJSON(ParseText);
        end
        else
        begin
          AAnswer := ParseText;
          Exit;
        end;
      end;
      AAnswer := '';
      VisitJSON(Data, '');
      if not FoundAnswer then
      begin
        if OtherText <> '' then AAnswer := OtherText
        else if AThinking <> '' then AAnswer := '(No final answer was provided.)'
        else AAnswer := Data.FormatJSON([foUseTabchar]);
      end;
    finally
      Data.Free;
    end;
  except
    { For non-JSON model text, preserve the original readable response. }
    AAnswer := ARaw;
    AThinking := '';
  end;
end;

procedure TFrmChatSession.UpdateStatus(const AStatus: string);
begin
  LblStatus.Caption := 'Status: ' + AStatus;
  Changed;
end;


function TFrmChatSession.GetTabCaption: string;
begin
  Result := FTitle;
end;

function TFrmChatSession.SaveState: TJSONObject;
var H: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('mode', Ord(FAgent.Mode));
  Result.Add('title', FTitle);
  Result.Add('transcript', FHistoryMarkdown);
  Result.Add('input', MemInput.Text);
  Result.Add('status', LblStatus.Caption);
  Result.Add('running', Assigned(FWorkerThread));
  H := TJSONObject(FContextSnapshot.Find('history').Clone);
  Result.Add('history', H);
  Result.Add('tasks', FContextSnapshot.Find('tasks').Clone);
  Result.Add('diagnostics', FContextSnapshot.Find('diagnostics').Clone);
end;

procedure TFrmChatSession.LoadState(AData: TJSONObject);
var V, I: Integer; H: TJSONObject; D: TJSONData;
begin
  if AData = nil then Exit;
  V := AData.Get('mode', Ord(amAsk));
  if (V < Ord(Low(TAgentMode))) or (V > Ord(High(TAgentMode))) then V := Ord(amAsk);
  FAgent.Mode := TAgentMode(V); CmbMode.ItemIndex := V;
  FTitle := AData.Get('title', 'New Chat');
  FHistoryMarkdown := AData.Get('transcript', '');
  MemInput.Text := AData.Get('input', '');
  FChatView.SetMarkdown(FHistoryMarkdown);
  Application.QueueAsyncCall(@ScrollChatToBottom, 0);
  H := TJSONObject(AData.Find('history'));
  FAgent.History.LoadJSON(H);
  FAgent.ToolSession.Clear;
  D := AData.Find('tasks');
  if (D <> nil) and (D.JSONType = jtArray) then
    for I := 0 to TJSONArray(D).Count - 1 do
      FAgent.ToolSession.Tasks.Add(TJSONArray(D)[I].Clone as TJSONObject);
  D := AData.Find('diagnostics');
  if (D <> nil) and (D.JSONType = jtObject) then
    for I := 0 to TJSONObject(D).Count - 1 do
      FAgent.ToolSession.Diagnostics.Add(TJSONObject(D).Names[I],
        TJSONObject(D).Items[I].Clone);
  FRestoredInterrupted := AData.Get('running', False);
  RefreshContextSnapshot;
  if FRestoredInterrupted then MarkInterrupted
  else UpdateStatus('Ready');
end;

procedure TFrmChatSession.MarkInterrupted;
begin
  FRestoredInterrupted := False;
  AppendToHistory('Interrupted', 'This chat was running when the application last closed. The request was not resumed.');
  UpdateStatus('Interrupted');
end;

function TFrmChatSession.GetIsRunning: Boolean;
begin
  Result := Assigned(FWorkerThread);
end;

procedure TFrmChatSession.StopRun;
var Worker: TAgentWorkerThread;
begin
  Worker := FWorkerThread;
  if Worker = nil then Exit;
  Worker.FreeOnTerminate := False;
  Worker.Terminate;
  while not Worker.Finished do CheckSynchronize(10);
  Worker.WaitFor;
  if FWorkerThread = Worker then FWorkerThread := nil;
  Worker.Free;
  BtnStop.Visible := False; BtnSend.Visible := True;
  UpdateSendAvailability;
  CmbMode.Enabled := True;
  UpdateStatus('Stopped');
end;

procedure TFrmChatSession.SetSharedSettingsEnabled(AEnabled: Boolean);
begin
  CmbModel.Enabled := AEnabled and not Assigned(FWorkerThread);
  BtnSettings.Enabled := AEnabled and not Assigned(FWorkerThread);
end;

procedure TFrmChatSession.SynchronizeSharedModel;
begin
  if not SameText(CmbModel.Text, FAgent.Config.ModelName) then RefreshModelList;
end;

procedure TFrmChatSession.Changed;
begin
  if not Assigned(FWorkerThread) then RefreshContextSnapshot;
  if Assigned(FOnStateChange) then FOnStateChange(Self);
end;

procedure TFrmChatSession.RefreshContextSnapshot;
var Snapshot: TJSONObject;
begin
  Snapshot := TJSONObject.Create;
  try
    Snapshot.Add('history', FAgent.History.ToJSON);
    Snapshot.Add('tasks', FAgent.ToolSession.Tasks.Clone);
    Snapshot.Add('diagnostics', FAgent.ToolSession.Diagnostics.Clone);
    FreeAndNil(FContextSnapshot);
    FContextSnapshot := Snapshot;
  except
    Snapshot.Free;
    raise;
  end;
end;

procedure TFrmChatSession.HandleWorkerProgress(const AText: string);
const SummaryMarker = 'Context summary ready:';
begin
  RefreshContextSnapshot;
  if Copy(AText, 1, Length(SummaryMarker)) = SummaryMarker then
  begin
    AppendToHistory('Context Summary', Trim(Copy(AText, Length(SummaryMarker) + 1, MaxInt)));
    UpdateStatus('Context summarized');
  end
  else UpdateStatus(AText);
end;

end.
