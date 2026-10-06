program gui_driver;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Interfaces, Forms, ExtCtrls, Classes, SysUtils, fpjson,
  uAgentTypes, uAgentConfig, uToolBase, uFrmChat, uFrmPlanResult, uMarkdownView;
type
  TChatAccess = class(TFrmChat)
  public
    procedure CheckActivity(const AName, Args: string);
    function Transcript: string;
  end;
  TMarkdownAccess = class(TMarkdownView)
  public
    class function HTML(const Markdown: string): string; static;
  end;
  TObserver = class
    Paths: TStringList;
    Previewed, MainThreadRefresh, ClosePreview, CancelPlanning: Boolean;
    PreviewCount, CommandStarts, CommandFinishes, FileRefreshCount: Integer;
    function Refresh(Files: TStrings; const ProjectRoot: string): string;
    function CommandRefresh(const ProjectRoot: string; BeforeCommand: Boolean): string;
    procedure Tick(Sender: TObject);
    procedure RunScenarios(Sender: TObject; var Done: Boolean);
  end;
procedure TChatAccess.CheckActivity(const AName, Args: string);
begin HandleToolExecuting(AName, Args); end;
function TChatAccess.Transcript: string;
begin Result := HistoryMarkdown; end;
class function TMarkdownAccess.HTML(const Markdown: string): string;
begin Result := RenderHTML(Markdown); end;

procedure Check(Condition: Boolean; const Message: string);
begin if not Condition then raise Exception.Create(Message); end;

const LiteralCommand = #10 + '  cat <<''COMMAND''' + #10 +
  '<script>"quoted" & text</script>' + #10 + '```' + #10 + '````' + #10 +
  '`literal`' + #10#10 + 'COMMAND' + #10;
function TObserver.Refresh(Files: TStrings; const ProjectRoot: string): string;
begin
  MainThreadRefresh := MainThreadRefresh and (GetCurrentThreadID = MainThreadID);
  Inc(FileRefreshCount);
  Paths.AddStrings(Files); Result := '';
end;
function TObserver.CommandRefresh(const ProjectRoot: string; BeforeCommand: Boolean): string;
begin
  MainThreadRefresh := MainThreadRefresh and (GetCurrentThreadID = MainThreadID);
  if BeforeCommand then Inc(CommandStarts)
  else begin Inc(CommandFinishes); Paths.Add(ProjectRoot); end;
  Result := '';
end;
procedure TObserver.Tick(Sender: TObject);
var I: Integer; PlanForm: TFrmPlanResult;
begin
  if CancelPlanning and (Pos('Plan Saved', TChatAccess(FrmChat).Transcript) > 0) then
    FrmChat.BtnStopClick(nil);
  for I := 0 to Screen.CustomFormCount-1 do
    if Screen.CustomForms[I] is TFrmPlanResult then
    begin
      PlanForm := TFrmPlanResult(Screen.CustomForms[I]);
      if PlanForm.Visible then
      begin
        Previewed := Pos('.plan', PlanForm.LblPlanPath.Caption) > 0;
        Inc(PreviewCount);
        if ClosePreview then PlanForm.BtnClose.Click else PlanForm.BtnBuild.Click;
      end;
    end;
end;
var ProviderRoot: string;
function TestProjectDirectory: string;
begin Result := ProviderRoot; end;

procedure Send(const Prompt: string; Mode: Integer; ExpectSuccess: Boolean = True);
var Start: QWord;
begin
  WriteLn(StdErr, 'GUI scenario: ', Prompt); Flush(StdErr);
  FrmChat.CmbMode.ItemIndex := Mode; FrmChat.CmbModeChange(nil);
  FrmChat.MemInput.Text := Prompt; FrmChat.BtnSendClick(nil); Start := GetTickCount64;
  while FrmChat.BtnStop.Visible do
  begin
    Application.ProcessMessages; Sleep(5);
    if GetTickCount64-Start > 10000 then raise Exception.Create('GUI run timed out');
  end;
  if ExpectSuccess and (FrmChat.LblStatus.Caption <> 'Status: Ready') then raise Exception.Create('GUI run failed: ' + FrmChat.LblStatus.Caption);
end;
procedure TObserver.RunScenarios(Sender: TObject; var Done: Boolean);
var O: TJSONObject; RefreshPaths: TJSONArray; I: Integer; Start: QWord;
  Chat: TChatAccess;
  HTML, Before: string;
  PreviewBefore, PathCount: Integer;
  TempFile: TStringList;
begin
  Application.OnIdle := nil;
  try
    Chat := TChatAccess(FrmChat);
    { Malformed, absent, and non-string commands use the ordinary activity. }
    for I := 0 to 4 do
    begin
      case I of
        0: Before := '{';
        1: Before := '{}';
        2: Before := '{"command":42}';
        3: Before := '[]';
        4: Before := '{"command":"   "}';
      end;
      FrmChat.BtnClearClick(nil);
      Chat.CheckActivity('shell', Before);
      Check(Pos('Running shell...', Chat.Transcript) > 0, 'Invalid argument activity failed');
      Check(Pos('Running shell command:', Chat.Transcript) = 0, 'Invalid command displayed');
    end;
    FrmChat.BtnClearClick(nil);
    Chat.CheckActivity('read_file', '{"path":"unit.pas"}');
    Check(Pos('Reading unit.pas...', Chat.Transcript) > 0, 'Non-shell activity changed');
    FrmChat.BtnClearClick(nil);
    Send('gui_commands', 2);
    Check(Pos(LiteralCommand, Chat.Transcript) > 0, 'Alias/multiline command missing');
    Check(Pos('printf "second command"; exit 7', Chat.Transcript) >
      Pos(LiteralCommand, Chat.Transcript), 'Sequential/failed command not retained');
    HTML := TMarkdownAccess.HTML(Chat.Transcript);
    Check(Pos('<pre><code>' + #10 + '  cat', HTML) > 0, 'Leading whitespace lost');
    Check(Pos('&lt;script&gt;&quot;quoted&quot; &amp; text&lt;/script&gt;' + #10 +
      '```' + #10 + '````' + #10 + '`literal`' + #10#10 + 'COMMAND' + #10 + '</code></pre>', HTML) > 0,
      'Command markup was not rendered literally');
    Check(Pos('<script>', HTML) = 0, 'Command HTML was not escaped');
    Check(Pos('<pre><code>plain</code></pre>',
      TMarkdownAccess.HTML('```pascal' + #10 + 'plain' + #10 + '```')) > 0,
      'Existing fenced block failed');
    Check(Pos('```text' + #10 + '````' + #10 + 'tail</code></pre>',
      TMarkdownAccess.HTML('```' + #10 + '```text' + #10 + '````' + #10 + 'tail' + #10 + '```')) > 0,
      'Nonmatching fence closed code block');
    FrmChat.BtnClearClick(nil);
    Send('gui_empty', 2);
    Check(Pos('Request done.', Chat.Transcript) > 0, 'Empty response lacked completion');
    Check(Pos('No project files changed.', Chat.Transcript) > 0, 'No-change message missing');
    FrmChat.BtnClearClick(nil);
    PathCount := FileRefreshCount;
    Send('gui_patch', 2);
    Check(FileRefreshCount = PathCount + 1, 'Patch was not refreshed exactly once');
    if Paths.IndexOf(IncludeTrailingPathDelimiter(ParamStr(1))+'unit.pas') < 0 then raise Exception.Create('Missing patch refresh');
    Check(Pos('Request done.', Chat.Transcript) > 0, 'Direct Agent completion missing');
    Check(Pos('- unit.pas', Chat.Transcript) > 0, 'Patch file list missing');
    FrmChat.BtnClearClick(nil);
    Send('gui_shell', 2);
    Check(Pos('printf ''shell\n'' > shell-created', Chat.Transcript) > 0, 'Completed shell command missing');
    if Paths.IndexOf(ParamStr(1)) < 0 then raise Exception.Create('Missing shell refresh');
    Check(Pos('- shell-created', Chat.Transcript) > 0, 'Shell file list missing');
    Check(Pos('- unit.pas', Chat.Transcript) = 0, 'Prior run changes leaked');
    FrmChat.BtnClearClick(nil);
    PreviewBefore := PreviewCount;
    Send('gui_plan', 1);
    Check(PreviewCount = PreviewBefore + 1, 'Saved plan preview duplicated');
    if not Previewed or (FrmChat.CmbMode.ItemIndex <> 2) then raise Exception.CreateFmt('Plan preview/Build transition failed: previewed=%s mode=%d', [BoolToStr(Previewed, True), FrmChat.CmbMode.ItemIndex]);
    Check(Pos('Request done.', Chat.Transcript) > 0, 'Build completion missing');
    Check(Pos('- unit.pas', Chat.Transcript) > 0, 'Build changes missing');
    { Text plans are auto-saved, while questions stay in chat. }
    ClosePreview := True; PreviewBefore := PreviewCount;
    Send('gui_plan_text', 1);
    Check(PreviewCount = PreviewBefore + 1, 'Text plan preview missing or duplicated');
    Check(FrmChat.CmbMode.ItemIndex = 1, 'Close started implementation');
    PreviewBefore := PreviewCount;
    Send('gui_plan_question', 1);
    Check(PreviewCount = PreviewBefore, 'Question opened preview');
    Send('gui_plan_failed', 1, False);
    Check(PreviewCount = PreviewBefore, 'Failed plan opened preview');
    FrmChat.BtnClearClick(nil);
    CancelPlanning := True;
    try Send('gui_plan_cancel', 1, False); finally CancelPlanning := False; end;
    Check(PreviewCount = PreviewBefore, 'Cancelled plan opened preview');
    { Saving a completed text plan can fail without starting Build. }
    Check(RenameFile(IncludeTrailingPathDelimiter(ParamStr(1))+'.plan',
      IncludeTrailingPathDelimiter(ParamStr(1))+'.plan-kept'), 'Cannot prepare save failure');
    TempFile := TStringList.Create;
    try
      TempFile.Text := 'blocks directory creation';
      TempFile.SaveToFile(IncludeTrailingPathDelimiter(ParamStr(1))+'.plan');
      Send('gui_plan_text', 1);
      Check(PreviewCount = PreviewBefore, 'Save failure opened preview');
      Check(Pos('Plan Save Error', Chat.Transcript) > 0, 'Save failure not shown');
    finally
      TempFile.Free;
      DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1))+'.plan');
      RenameFile(IncludeTrailingPathDelimiter(ParamStr(1))+'.plan-kept',
        IncludeTrailingPathDelimiter(ParamStr(1))+'.plan');
    end;
    FrmChat.BtnClearClick(nil);
    Send('gui_fail_after_edit', 2, False);
    Check(Pos('Request incomplete.', Chat.Transcript) > 0, 'Failure completion missing');
    Check(Pos('- partial.pas', Chat.Transcript) > 0, 'Partial changes missing');
    Check(Pos('Request done.', Chat.Transcript) = 0, 'Failure claimed success');
    FrmChat.BtnClearClick(nil);
    Send('exhaust', 2, False);
    Check(Pos('Request incomplete.', Chat.Transcript) > 0, 'Iteration limit completion missing');
    Check(Pos('Request done.', Chat.Transcript) = 0, 'Iteration limit claimed success');
    FrmChat.BtnClearClick(nil);
    Send('gui_tracking_warning', 2);
    Check(Pos('Changed-file list may be incomplete', Chat.Transcript) > 0, 'Tracking warning missing');
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1))+'untrackable');
    FrmChat.BtnClearClick(nil);
    { Observe the command while running, then retain it through cancellation. }
    FrmChat.MemInput.Text := 'gui_slow'; FrmChat.BtnSendClick(nil); Start := GetTickCount64;
    while not FileExists(IncludeTrailingPathDelimiter(ParamStr(1))+'running') do
    begin Application.ProcessMessages; Sleep(5); if GetTickCount64-Start > 3000 then raise Exception.Create('Slow tool did not start'); end;
    Check(Pos('touch running; sleep 10', Chat.Transcript) > 0, 'Running command missing');
    Check(FrmChat.LblStatus.Caption = 'Status: Running shell...', 'Shell status was not compact');
    Before := Chat.Transcript;
    FrmChat.BtnStopClick(nil);
    while FrmChat.BtnStop.Visible do
    begin Application.ProcessMessages; Sleep(5); if GetTickCount64-Start > 3000 then raise Exception.Create('Stop did not cancel process promptly'); end;
    Check(Copy(Chat.Transcript, 1, Length(Before)) = Before, 'Cancellation removed command history');
    Check(Pos('Request cancelled.', Chat.Transcript) > 0, 'Cancellation outcome missing');
    Check(Pos('- running', Chat.Transcript) > 0, 'Cancelled command changes missing');
    Check(Pos('Request done.', Chat.Transcript) = 0, 'Cancellation claimed success');
    { Clear a chat during a running process: wait for worker before resetting state. }
    DeleteFile(IncludeTrailingPathDelimiter(ParamStr(1))+'running');
    FrmChat.MemInput.Text := 'gui_slow'; FrmChat.BtnSendClick(nil); Start := GetTickCount64;
    while not FileExists(IncludeTrailingPathDelimiter(ParamStr(1))+'running') do
    begin Application.ProcessMessages; Sleep(5); if GetTickCount64-Start > 3000 then raise Exception.Create('Slow tool did not restart'); end;
    Start := GetTickCount64; FrmChat.BtnClearClick(nil);
    if GetTickCount64-Start > 3000 then raise Exception.Create('Clear did not cancel process promptly');
    if FrmChat.BtnStop.Visible or not MainThreadRefresh then raise Exception.Create('UI/thread state failed');
    Check(CommandStarts = CommandFinishes, 'Command refresh missing after cancellation');
    Check(Chat.Transcript = '', 'Clear retained run output');
    Check(FrmChat.CmbMode.Enabled and FrmChat.CmbModel.Enabled and FrmChat.BtnSettings.Enabled, 'Clear left controls disabled');
    ProviderRoot := IncludeTrailingPathDelimiter(ParamStr(1))+'second-project';
    ForceDirectories(ProviderRoot);
    GProjectDirProvider := @TestProjectDirectory;
    Send('gui_shell', 2);
    if not FileExists(IncludeTrailingPathDelimiter(ProviderRoot)+'shell-created') then raise Exception.Create('Active project switch was not refreshed');
    GProjectDirProvider := nil;
    O := TJSONObject.Create(['previewed', Previewed, 'main_thread_refresh', MainThreadRefresh,
      'clear_cancelled', True, 'project_switched', True, 'commands_displayed', True]); RefreshPaths := TJSONArray.Create;
    for I := 0 to Paths.Count-1 do RefreshPaths.Add(Paths[I]);
    O.Add('refresh_paths', RefreshPaths);
    try WriteLn(O.AsJSON); finally O.Free; end;
  except on E: Exception do begin WriteLn(StdErr, E.Message); ExitCode := 1; end; end;
  Application.Terminate;
end;

var Observer: TObserver; Timer: TTimer;
begin
  RequireDerivedFormResource := True; Application.Initialize;
  SetEffectiveProjectDir(ParamStr(1));
  GetAgentConfig.Provider := lpCustom; GetAgentConfig.EndpointURL := ParamStr(2);
  GetAgentConfig.APIKey := ''; GetAgentConfig.ModelName := 'fixture';
  Observer := TObserver.Create; Observer.Paths := TStringList.Create; Observer.MainThreadRefresh := True;
  SetAgentIDERefreshProc(@Observer.Refresh);
  GAgentIDECommandRefreshProc := @Observer.CommandRefresh;
  Timer := TTimer.Create(nil); Timer.Interval := 10; Timer.OnTimer := @Observer.Tick;
  Application.CreateForm(TFrmChat, FrmChat);
  Application.OnIdle := @Observer.RunScenarios;
  try Application.Run;
  finally
    Timer.Free; FrmChat.Free; SetAgentIDERefreshProc(nil);
    GAgentIDECommandRefreshProc := nil; Observer.Paths.Free; Observer.Free;
  end;
end.
