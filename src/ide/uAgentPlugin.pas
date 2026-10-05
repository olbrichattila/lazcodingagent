unit uAgentPlugin;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs, Menus, LCLType,
  LazIDEIntf, ProjectIntf, MenuIntf, IDEWindowIntf, IDECommands, ToolBarIntf,
  SrcEditorIntf, CodeToolManager, LazFileCache, LazFileUtils, LazMsgWorker, MD5,
  uToolBase, uToolPaths, uFrmChat;

type
  { TAgentPluginManager }
  TAgentPluginManager = class
  private
    FChatForm: TFrmChat;
    FToggleCommand: TIDECommand;
    FCommandFiles: TStringList;
    FPendingDesigners: TStringList;
    FDesignerProjectRoot: string;
    FCommandRoot: string;
    FReloadMessages: string;
    FDiskCheckSuspended, FPreviousDiskCheck: Boolean;
    procedure CreateAgentForm(Sender: TObject; aFormName: string;
      var AForm: TCustomForm; DoDisableAutoSizing: boolean);
    function SilentMessage(const ACaption, AMsg: string; DlgType: TMsgDlgType;
      Buttons: TMsgDlgButtons; const HelpKeyword: string = ''): Integer;
    function SilentQuestion(const ACaption, AMsg: string; DlgType: TMsgDlgType;
      Buttons: array of const; const HelpKeyword: string = ''): Integer;
  public
    function RefreshIDEFiles(AChangedFiles: TStrings; const AProjectRoot: string): string;
    function RefreshCommandFiles(const AProjectRoot: string; ABeforeCommand: Boolean): string;
    constructor Create;
    destructor Destroy; override;
    procedure RegisterIntegrations;
    procedure ToggleChatWindow(Sender: TObject);
  end;

procedure Register;

implementation

const
  CAgentWindowName = 'CodingAgentChatForm';

var
  GPluginManager: TAgentPluginManager = nil;

function StripTrailingSlash(const S: string): string;
begin
  Result := S;
  while (Length(Result) > 1) and ((Result[Length(Result)] = '/') or (Result[Length(Result)] = '\')) do
    Delete(Result, Length(Result), 1);
end;

function GetLazarusProjectDirectory: string; forward;

function InProject(const APath, ARoot: string): Boolean;
var P, R: string;
begin
  Result := False;
  if (APath = '') or (ARoot = '') then Exit;
  P := ExpandFileName(APath);
  R := IncludeTrailingPathDelimiter(ExpandFileName(ARoot));
  if not FileIsInPath(P, R) then Exit;
  { Reject links escaping the project, including links in parent directories. }
  P := CanonicalFilePath(P);
  R := CanonicalFilePath(ExcludeTrailingPathDelimiter(R));
  R := IncludeTrailingPathDelimiter(R);
  Result := FileIsInPath(P, R);
end;

function ResourceForUnit(const AUnit: string): string;
begin
  Result := ChangeFileExt(AUnit, '.lfm');
  if not FileExists(Result) and FileExists(ChangeFileExt(AUnit, '.dfm')) then
    Result := ChangeFileExt(AUnit, '.dfm');
end;

function DiskFingerprint(const APath: string): string;
var Stream: TFileStream; Context: TMD5Context; Digest: TMD5Digest;
  Buffer: array[0..65535] of Byte; Count: LongInt;
begin
  if not FileExists(APath) then Exit('missing');
  { MD5File silently treats an unreadable file as empty and changes global
    FileMode. Use a stream so errors are reported and worker I/O is unaffected. }
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    MD5Init(Context);
    repeat
      Count := Stream.Read(Buffer, SizeOf(Buffer));
      if Count > 0 then MD5Update(Context, Buffer, Count);
    until Count = 0;
    MD5Final(Context, Digest);
    Result := 'md5:' + MD5Print(Digest);
  finally Stream.Free; end;
end;

function TAgentPluginManager.SilentMessage(const ACaption, AMsg: string;
  DlgType: TMsgDlgType; Buttons: TMsgDlgButtons; const HelpKeyword: string): Integer;
begin
  FReloadMessages := FReloadMessages + ACaption + ': ' + AMsg + LineEnding;
  if mbCancel in Buttons then Result := mrCancel
  else if mbAbort in Buttons then Result := mrAbort
  else if mbNo in Buttons then Result := mrNo
  else Result := mrOk;
end;

function TAgentPluginManager.SilentQuestion(const ACaption, AMsg: string;
  DlgType: TMsgDlgType; Buttons: array of const; const HelpKeyword: string): Integer;
var I: Integer;
begin
  FReloadMessages := FReloadMessages + ACaption + ': ' + AMsg + LineEnding;
  { Fail the reload instead of accepting a repair or modifying dependencies. }
  for I := Low(Buttons) to High(Buttons) do
    if (Buttons[I].VType = vtInteger) and (Buttons[I].VInteger = mrCancel) then Exit(mrCancel);
  for I := Low(Buttons) to High(Buttons) do
    if (Buttons[I].VType = vtInteger) and (Buttons[I].VInteger = mrAbort) then Exit(mrAbort);
  for I := Low(Buttons) to High(Buttons) do
    if (Buttons[I].VType = vtInteger) and (Buttons[I].VInteger = mrNo) then Exit(mrNo);
  Result := mrCancel;
end;

function TAgentPluginManager.RefreshIDEFiles(AChangedFiles: TStrings;
  const AProjectRoot: string): string;
var
  I, J, K, PageIndex, WindowIndex: Integer;
  Path, UnitPath, ResourcePath, ActivePath: string;
  Editor, OwnerEditor, E: TSourceEditorInterface;
  EditorWindow: TSourceEditorWindowInterface;
  HadDesigner: Boolean;
  Component: TComponent;
  Status: TModalResult;
  PreviousMessage: TLazMessageWorker;
  PreviousQuestion: TLazQuestionWorker;
  Positions: array of record
    Editor: TSourceEditorInterface;
    Cursor: TPoint;
    Top: Integer;
  end;
begin
  Result := '';
  if (AChangedFiles = nil) or (AChangedFiles.Count = 0) then Exit;
  if not Assigned(LazarusIDE) or not Assigned(SourceEditorManagerIntf) then
  begin
    Result := 'The Lazarus IDE is unavailable; changed open files could not be refreshed.';
    Exit;
  end;
  if CompareFilenames(GetLazarusProjectDirectory, AProjectRoot) <> 0 then Exit;
  if CompareFilenames(FDesignerProjectRoot, AProjectRoot) <> 0 then
  begin
    FPendingDesigners.Clear;
    FDesignerProjectRoot := AProjectRoot;
  end;

  { All calls are synchronized onto the IDE thread. These hooks are scoped to
    the reload only, so a broken resource cannot block the agent with a dialog. }
  PreviousMessage := LazMessageWorker;
  PreviousQuestion := LazQuestionWorker;
  FReloadMessages := '';
  LazMessageWorker := @SilentMessage;
  LazQuestionWorker := @SilentQuestion;
  ActivePath := '';
  if SourceEditorManagerIntf.ActiveEditor <> nil then
    ActivePath := SourceEditorManagerIntf.ActiveEditor.FileName;
  try
    InvalidateFileStateCache;
    for I := 0 to AChangedFiles.Count - 1 do
    try
      Path := ExpandFileName(AChangedFiles[I]);
      if not InProject(Path, AProjectRoot) then Continue;
      Editor := SourceEditorManagerIntf.SourceEditorIntfWithFilename(Path);
      OwnerEditor := Editor;
      UnitPath := Path;
      if SameText(ExtractFileExt(Path), '.lfm') or SameText(ExtractFileExt(Path), '.dfm') then
      begin
        OwnerEditor := nil;
        for J := 0 to SourceEditorManagerIntf.UniqueSourceEditorCount - 1 do
        begin
          E := SourceEditorManagerIntf.UniqueSourceEditors[J];
          if (SameText(ExtractFileExt(E.FileName), '.pas') or
              SameText(ExtractFileExt(E.FileName), '.pp') or
              SameText(ExtractFileExt(E.FileName), '.p')) and
             (CompareFilenames(ChangeFileExt(E.FileName, ExtractFileExt(Path)), Path) = 0) then
          begin OwnerEditor := E; UnitPath := E.FileName; Break; end;
        end;
      end;
      HadDesigner := (OwnerEditor <> nil) and
        ((OwnerEditor.GetDesigner(False) <> nil) or (FPendingDesigners.IndexOf(UnitPath) >= 0));
      if (Editor = nil) and not HadDesigner then Continue;
      if not InProject(UnitPath, AProjectRoot) then Continue;
      ResourcePath := ResourceForUnit(UnitPath);
      if HadDesigner and not InProject(ResourcePath, AProjectRoot) then
      begin
        Result := Result + 'Skipped designer resource outside the project: ' + ResourcePath + LineEnding;
        HadDesigner := False;
      end;
      { A failed reload can destroy the designer. Remember its open state so
        the next paired unit/resource commit can recreate it. }
      if HadDesigner then FPendingDesigners.Add(UnitPath);
      if not FileExists(Path) then
      begin
        if HadDesigner then Status := LazarusIDE.DoCloseEditorFile(UnitPath, [cfQuiet])
        else Status := mrOk;
        if (Editor <> nil) and (CompareFilenames(Path, UnitPath) <> 0) then
          Status := LazarusIDE.DoCloseEditorFile(Path, [cfQuiet])
        else if not HadDesigner then Status := LazarusIDE.DoCloseEditorFile(Path, [cfQuiet]);
      end
      else
      begin
        SetLength(Positions, SourceEditorManagerIntf.SourceEditorCount);
        for J := 0 to High(Positions) do
        begin
          E := SourceEditorManagerIntf.SourceEditors[J];
          Positions[J].Editor := E;
          Positions[J].Cursor := E.CursorTextXY;
          Positions[J].Top := E.TopLine;
        end;
        Status := mrOk;
        if Editor <> nil then
        begin
          EditorWindow := SourceEditorManagerIntf.SourceWindowWithEditor(Editor);
          if EditorWindow = nil then Status := mrCancel
          else
          begin
            PageIndex := EditorWindow.IndexOfEditorInShareWith(Editor);
            WindowIndex := SourceEditorManagerIntf.IndexOfSourceWindowWithID(EditorWindow.WindowID);
            if (PageIndex < 0) or (WindowIndex < 0) then Status := mrCancel
            else Status := LazarusIDE.DoOpenEditorFile(Path, PageIndex, WindowIndex,
              [ofRevert, ofQuiet, ofOnlyIfExists, ofRegularFile,
               ofDoNotLoadResource, ofDoNotActivateSourceEditor]);
          end;
        end;
        if (Status = mrOk) and HadDesigner then
        begin
          { DoOpenComponent uses cached resource text: explicitly revert that
            buffer first. Never save designer edits or its dependencies. }
          if not FileExists(ResourcePath) then
            Status := LazarusIDE.DoCloseEditorFile(UnitPath, [cfQuiet])
          else if CodeToolBoss.LoadFile(ResourcePath, True, True) = nil then Status := mrCancel
          else Status := LazarusIDE.DoOpenComponent(UnitPath,
            [ofRevert, ofQuiet, ofOnlyIfExists, ofDoNotActivateSourceEditor], [cfQuiet], Component);
        end;
        for J := 0 to High(Positions) do
          for K := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
          begin
            { A failed resource reload can close an editor. Find each live
              view by identity before accessing it, including dual views. }
            E := SourceEditorManagerIntf.SourceEditors[K];
            if E = Positions[J].Editor then
            begin
              E.CursorTextXY := Positions[J].Cursor;
              E.TopLine := Positions[J].Top;
              Break;
            end;
          end;
      end;
      if Status <> mrOk then Result := Result + 'Could not reload ' + Path + LineEnding;
      if (Status = mrOk) and (FPendingDesigners.IndexOf(UnitPath) >= 0) then
        FPendingDesigners.Delete(FPendingDesigners.IndexOf(UnitPath));
      { The per-file callback already consumed this change. Do not reload it
        a second time when the enclosing tool completes. }
      if FCommandFiles.IndexOfName(Path) >= 0 then
        FCommandFiles.Values[Path] := DiskFingerprint(Path);
    except on Ex: Exception do
      Result := Result + 'Could not reload ' + Path + ': ' + Ex.Message + LineEnding;
    end;
  finally
    LazMessageWorker := PreviousMessage;
    LazQuestionWorker := PreviousQuestion;
    if ActivePath <> '' then
    begin
      E := SourceEditorManagerIntf.SourceEditorIntfWithFilename(ActivePath);
      if E <> nil then SourceEditorManagerIntf.ActiveEditor := E;
    end;
  end;
  Result := Trim(Result + FReloadMessages);
end;

function TAgentPluginManager.RefreshCommandFiles(const AProjectRoot: string;
  ABeforeCommand: Boolean): string;
var I: Integer; E: TSourceEditorInterface; Path: string; Changed: TStringList;
  procedure Remember(const APath: string);
  begin
    if InProject(APath, AProjectRoot) and (FCommandFiles.IndexOfName(APath) < 0) then
      FCommandFiles.Add(APath + #9 + DiskFingerprint(APath));
  end;
begin
  Result := '';
  if ABeforeCommand then
  begin
    if FDiskCheckSuspended and Assigned(LazarusIDE) then
      LazarusIDE.CheckFilesOnDiskEnabled := FPreviousDiskCheck;
    FDiskCheckSuspended := False;
    FCommandFiles.Clear;
    FCommandRoot := AProjectRoot;
    if (not Assigned(SourceEditorManagerIntf)) or
      (CompareFilenames(GetLazarusProjectDirectory, AProjectRoot) <> 0) then Exit;
    FPreviousDiskCheck := LazarusIDE.CheckFilesOnDiskEnabled;
    LazarusIDE.CheckFilesOnDiskEnabled := False;
    FDiskCheckSuspended := True;
    for I := 0 to SourceEditorManagerIntf.UniqueSourceEditorCount - 1 do
    begin
      E := SourceEditorManagerIntf.UniqueSourceEditors[I];
      Remember(E.FileName);
      if (E.GetDesigner(False) <> nil) or (FPendingDesigners.IndexOf(E.FileName) >= 0) then
        Remember(ResourceForUnit(E.FileName));
    end;
  end
  else
  begin
    Changed := TStringList.Create;
    try
      if CompareFilenames(FCommandRoot, AProjectRoot) <> 0 then Exit;
      for I := 0 to FCommandFiles.Count - 1 do
      begin
        Path := FCommandFiles.Names[I];
        try
          if DiskFingerprint(Path) <> FCommandFiles.ValueFromIndex[I] then Changed.Add(Path);
        except on Ex: Exception do Result := Result + Path + ': ' + Ex.Message + LineEnding; end;
      end;
      Result := Trim(Result + RefreshIDEFiles(Changed, AProjectRoot));
    finally
      Changed.Free;
      FCommandFiles.Clear;
      FCommandRoot := '';
      if FDiskCheckSuspended and Assigned(LazarusIDE) then
        LazarusIDE.CheckFilesOnDiskEnabled := FPreviousDiskCheck;
      FDiskCheckSuspended := False;
    end;
  end;
end;

function FindProjectRoot(const AStartDir: string): string;
var
  CurDir, ParentDir, Name: string;
begin
  Result := AStartDir;
  CurDir := StripTrailingSlash(ExpandFileName(AStartDir));
  if (CurDir = '') or (CurDir = '/') then Exit;

  ParentDir := StripTrailingSlash(ExtractFileDir(CurDir));
  if (ParentDir <> '') and (ParentDir <> CurDir) and (ParentDir <> '/') then
  begin
    Name := LowerCase(ExtractFileName(CurDir));
    if (Name = 'app') or (Name = 'package') or (Name = 'packages') or
       (Name = 'src') or (Name = 'units') or (Name = 'bin') then
    begin
      if DirectoryExists(ParentDir + DirectorySeparator + 'src') or
         DirectoryExists(ParentDir + DirectorySeparator + '.git') or
         FileExists(ParentDir + DirectorySeparator + 'README.md') or
         FileExists(ParentDir + DirectorySeparator + 'build.sh') or
         FileExists(ParentDir + DirectorySeparator + 'build.bat') or
         FileExists(ParentDir + DirectorySeparator + 'Makefile') then
      begin
        Result := ParentDir;
        Exit;
      end;
    end;
  end;
  Result := CurDir;
end;

function GetLazarusProjectDirectory: string;
var
  Proj: TLazProject;
  Candidate: string;
begin
  Result := '';
  if Assigned(LazarusIDE) then
  begin
    try
      Proj := LazarusIDE.ActiveProject;
      if Assigned(Proj) then
      begin
        Candidate := '';
        if Proj.ProjectInfoFile <> '' then
          Candidate := ExtractFilePath(Proj.ProjectInfoFile)
        else if Proj.Directory <> '' then
          Candidate := Proj.Directory
        else if Assigned(Proj.MainFile) and (Proj.MainFile.Filename <> '') then
          Candidate := ExtractFilePath(Proj.MainFile.Filename);

        if (Candidate <> '') and DirectoryExists(Candidate) then
          Result := FindProjectRoot(Candidate);
      end;
    except
      Result := '';
    end;
  end;
end;

procedure Register;
begin
  GProjectDirProvider := @GetLazarusProjectDirectory;
  if not Assigned(GPluginManager) then
  begin
    GPluginManager := TAgentPluginManager.Create;
    GPluginManager.RegisterIntegrations;
  end;
  SetAgentIDERefreshProc(@GPluginManager.RefreshIDEFiles);
  GAgentIDECommandRefreshProc := @GPluginManager.RefreshCommandFiles;
end;

{ TAgentPluginManager }

constructor TAgentPluginManager.Create;
begin
  inherited Create;
  FChatForm := nil;
  FToggleCommand := nil;
  FCommandFiles := TStringList.Create;
  FCommandFiles.NameValueSeparator := #9;
  FCommandFiles.CaseSensitive := {$IFDEF WINDOWS}False{$ELSE}True{$ENDIF};
  FPendingDesigners := TStringList.Create;
  FPendingDesigners.CaseSensitive := FCommandFiles.CaseSensitive;
  FPendingDesigners.Sorted := True;
  FPendingDesigners.Duplicates := dupIgnore;
end;

destructor TAgentPluginManager.Destroy;
begin
  SetAgentIDERefreshProc(nil);
  GAgentIDECommandRefreshProc := nil;
  if Assigned(FChatForm) then
    FreeAndNil(FChatForm);
  if FDiskCheckSuspended and Assigned(LazarusIDE) then
    LazarusIDE.CheckFilesOnDiskEnabled := FPreviousDiskCheck;
  FCommandFiles.Free;
  FPendingDesigners.Free;
  inherited Destroy;
end;

procedure TAgentPluginManager.CreateAgentForm(Sender: TObject; aFormName: string;
  var AForm: TCustomForm; DoDisableAutoSizing: boolean);
begin
  if not Assigned(FChatForm) then
  begin
    FChatForm := TFrmChat.Create(Application);
    FChatForm.Name := aFormName;
  end;
  AForm := FChatForm;
end;

procedure TAgentPluginManager.ToggleChatWindow(Sender: TObject);
var
  AgentForm: TCustomForm;
begin
  AgentForm := IDEWindowCreators.GetForm(CAgentWindowName, False, False);

  if Assigned(AgentForm) and AgentForm.Visible and AgentForm.IsVisible then
  begin
    // Window is currently open and visible -> Toggle OFF (Hide)
    AgentForm.Hide;
  end
  else
  begin
    // Window is closed or hidden -> Toggle ON (Show and Bring to front)
    AgentForm := IDEWindowCreators.ShowForm(CAgentWindowName, True);
    if Assigned(AgentForm) then
      AgentForm.BringToFront;
  end;
end;

procedure TAgentPluginManager.RegisterIntegrations;
var
  ParentMenu: TIDEMenuSection;
  CommandCat: TIDECommandCategory;
begin
  // 1. Register IDE Dockable Window Creator
  IDEWindowCreators.Add(
    CAgentWindowName,
    nil,
    @CreateAgentForm,
    '150', '150', '650', '750',
    '', alNone, False, nil
  );

  // 2. Register IDE Command with Shortcut (Ctrl+Alt+A)
  CommandCat := IDECommandList.CreateCategory(nil, 'CodingAgentCategory', 'Coding Agent');
  FToggleCommand := RegisterIDECommand(
    CommandCat,
    'ToggleCodingAgentChat',
    'Coding Agent Chat (Toggle)',
    VK_A, [ssCtrl, ssAlt],
    @ToggleChatWindow
  );

  // 3. Register Menu Item under View -> Windows
  ParentMenu := TIDEMenuSection(RegisterIDEMenuSection(itmViewMainWindows, 'CodingAgentMenuSection'));
  RegisterIDEMenuCommand(ParentMenu, 'CodingAgentChatMenuCmd', 'Coding Agent Chat', @ToggleChatWindow, nil, FToggleCommand);

  // 4. Register Toolbar Button
  if Assigned(FToggleCommand) then
    RegisterIDEButtonCommand(FToggleCommand);
end;

initialization

finalization
  if Assigned(GPluginManager) then
    FreeAndNil(GPluginManager);

end.
