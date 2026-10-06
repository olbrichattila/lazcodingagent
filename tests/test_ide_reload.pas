program test_ide_reload;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF} {$IFDEF WINDOWS}Windows,{$ENDIF}
  Interfaces, Forms, Controls, Classes, SysUtils, Types, Dialogs, LCLType,
  SrcEditorIntf, LazIDEIntf, ProjectIntf, LazMsgWorker, CodeToolManager, LazFileUtils,
  uAgentPlugin;
{$IFDEF WINDOWS}
function WinCreateSymbolicLink(LinkName, TargetName: PChar; Flags: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'CreateSymbolicLinkA';
{$ENDIF}
type
  TTestEditor = class(TSourceEditorInterface)
  public
    Path, Text, ResourceText: string;
    Dirty: Boolean;
    Designer: TIDesigner;
    Cursor: TPoint;
    Top: Integer;
    function GetFileName: string; override;
    function GetDesigner(LoadForm: Boolean): TIDesigner; override;
    function GetCursorTextXY: TPoint; override;
    procedure SetCursorTextXY(const Value: TPoint); override;
    function GetTopLine: Integer; override;
    procedure SetTopLine(const Value: Integer); override;
  end;
  TTestProject = class(TLazProject)
  public
    Root: string;
    InfoFile, ProjectDir: string;
    function GetMainFile: TLazProjectFile; override;
    function GetProjectInfoFile: string; override;
    function GetDirectory: string; override;
  end;
  TTestWindow = class(TSourceEditorWindowInterface)
  public
    Editors: TList;
    function GetWindowID: Integer; override;
    function IndexOfEditorInShareWith(Editor: TSourceEditorInterface): Integer; override;
  end;
  TTestEditors = class(TSourceEditorManagerInterface)
  public
    Items: TList;
    Active: TSourceEditorInterface;
    Window: TTestWindow;
    function GetActiveEditor: TSourceEditorInterface; override;
    procedure SetActiveEditor(const Value: TSourceEditorInterface); override;
    function GetSourceEditors(Index: Integer): TSourceEditorInterface; override;
    function GetUniqueSourceEditors(Index: Integer): TSourceEditorInterface; override;
    function SourceEditorCount: Integer; override;
    function UniqueSourceEditorCount: Integer; override;
    function SourceEditorIntfWithFilename(const Path: string): TSourceEditorInterface; override;
    function SourceWindowWithEditor(const Editor: TSourceEditorInterface): TSourceEditorWindowInterface; override;
    function IndexOfSourceWindowWithID(const ID: Integer): Integer; override;
  end;
  TTestIDE = class(TLazIDEInterface)
  public
    Project: TTestProject;
    Editors: TTestEditors;
    Reloads, FormReloads, Closes: Integer;
    function GetActiveProject: TLazProject; override;
    function DoOpenEditorFile(Path: string; PageIndex, WindowIndex: Integer;
      Flags: TOpenFlags): TModalResult; override;
    function DoCloseEditorFile(const Path: string; Flags: TCloseFlags): TModalResult; override;
    function DoOpenComponent(const Path: string; OpenFlags: TOpenFlags;
      CloseFlags: TCloseFlags; out Component: TComponent): TModalResult; override;
    function UnexpectedMessage(const Caption, Msg: string; DlgType: TMsgDlgType;
      Buttons: TMsgDlgButtons; const HelpKeyword: string = ''): Integer;
    function UnexpectedQuestion(const Caption, Msg: string; DlgType: TMsgDlgType;
      Buttons: array of const; const HelpKeyword: string = ''): Integer;
  end;
procedure Check(Value: Boolean; const Msg: string);
begin if not Value then raise Exception.Create(Msg); end;
procedure Save(const Path, Text: string);
var S: TFileStream;
begin
  S := TFileStream.Create(Path, fmCreate);
  try if Text <> '' then S.WriteBuffer(Text[1], Length(Text)); finally S.Free; end;
end;
function Read(const Path: string): string;
var S: TFileStream;
begin
  S := TFileStream.Create(Path, fmOpenRead);
  try SetLength(Result, S.Size); if Result <> '' then S.ReadBuffer(Result[1], Length(Result)); finally S.Free; end;
end;
function TTestEditor.GetFileName: string; begin Result := Path; end;
function TTestEditor.GetDesigner(LoadForm: Boolean): TIDesigner;
begin Check(not LoadForm, 'Reload opened an unopened designer'); Result := Designer; end;
function TTestEditor.GetCursorTextXY: TPoint; begin Result := Cursor; end;
procedure TTestEditor.SetCursorTextXY(const Value: TPoint); begin Cursor := Value; end;
function TTestEditor.GetTopLine: Integer; begin Result := Top; end;
procedure TTestEditor.SetTopLine(const Value: Integer); begin Top := Value; end;
function TTestProject.GetProjectInfoFile: string;
begin Result := InfoFile; end;
function TTestProject.GetMainFile: TLazProjectFile;
begin Result := nil; end;
function TTestProject.GetDirectory: string;
begin if ProjectDir <> '' then Result := ProjectDir else Result := Root; end;
function TTestWindow.GetWindowID: Integer; begin Result := 42; end;
function TTestWindow.IndexOfEditorInShareWith(Editor: TSourceEditorInterface): Integer;
begin Result := Editors.IndexOf(Editor); end;
function TTestEditors.GetActiveEditor: TSourceEditorInterface; begin Result := Active; end;
procedure TTestEditors.SetActiveEditor(const Value: TSourceEditorInterface); begin Active := Value; end;
function TTestEditors.GetSourceEditors(Index: Integer): TSourceEditorInterface;
begin Result := TSourceEditorInterface(Items[Index]); end;
function TTestEditors.GetUniqueSourceEditors(Index: Integer): TSourceEditorInterface;
begin Result := GetSourceEditors(Index); end;
function TTestEditors.SourceEditorCount: Integer; begin Result := Items.Count; end;
function TTestEditors.UniqueSourceEditorCount: Integer; begin Result := Items.Count; end;
function TTestEditors.SourceEditorIntfWithFilename(const Path: string): TSourceEditorInterface;
var I: Integer;
begin
  Result := nil;
  for I := 0 to Items.Count - 1 do
    if TTestEditor(Items[I]).Path = Path then Exit(TTestEditor(Items[I]));
end;
function TTestEditors.SourceWindowWithEditor(const Editor: TSourceEditorInterface): TSourceEditorWindowInterface;
begin Result := Window; end;
function TTestEditors.IndexOfSourceWindowWithID(const ID: Integer): Integer;
begin if ID = 42 then Result := 0 else Result := -1; end;
function TTestIDE.GetActiveProject: TLazProject; begin Result := Project; end;
function TTestIDE.DoOpenEditorFile(Path: string; PageIndex, WindowIndex: Integer;
  Flags: TOpenFlags): TModalResult;
var I: Integer; E: TTestEditor;
begin
  Check((PageIndex >= 0) and (WindowIndex = 0), 'Revert lost its editor page/window');
  Check((ofRevert in Flags) and (ofQuiet in Flags) and (ofDoNotLoadResource in Flags), 'Unsafe source reload flags');
  Inc(Reloads);
  for I := 0 to Editors.Items.Count - 1 do
  begin
    E := TTestEditor(Editors.Items[I]);
    if E.Path = Path then begin E.Text := Read(Path); E.Dirty := False; E.Cursor := Point(1, 1); E.Top := 1; end;
  end;
  Result := mrOk;
end;
function TTestIDE.DoCloseEditorFile(const Path: string; Flags: TCloseFlags): TModalResult;
var I: Integer;
begin
  Check((cfQuiet in Flags) and not (cfSaveFirst in Flags) and not (cfSaveDependencies in Flags), 'Deletion saves unsaved changes');
  Inc(Closes);
  for I := Editors.Items.Count - 1 downto 0 do
    if TTestEditor(Editors.Items[I]).Path = Path then Editors.Items.Delete(I);
  Result := mrOk;
end;
function TTestIDE.DoOpenComponent(const Path: string; OpenFlags: TOpenFlags;
  CloseFlags: TCloseFlags; out Component: TComponent): TModalResult;
var E: TTestEditor; Resource: string;
begin
  Check((ofRevert in OpenFlags) and (ofQuiet in OpenFlags), 'Unsafe designer reload flags');
  Check(CloseFlags = [cfQuiet], 'Designer saves/closes dependencies');
  E := TTestEditor(Editors.SourceEditorIntfWithFilename(Path));
  Resource := ChangeFileExt(Path, '.lfm');
  if not FileExists(Resource) then Resource := ChangeFileExt(Path, '.dfm');
  Check(CodeToolBoss.FindFile(Resource).Source = Read(Resource), 'Resource reloaded stale cached bytes');
  if Read(Resource) = 'malformed' then
  begin
    E.Designer.Free; E.Designer := nil;
    Check(LazQuestionWorker('Invalid resource', 'fixture failure', mtError,
      [mrCancel, 'Cancel', mrYes, 'Repair']) = mrCancel, 'Reload accepted a repair dialog');
    Exit(mrCancel);
  end;
  if E.Designer = nil then E.Designer := TIDesigner.Create;
  E.ResourceText := Read(Resource); Inc(FormReloads);
  Component := nil; Result := mrOk;
end;
function TTestIDE.UnexpectedMessage(const Caption, Msg: string; DlgType: TMsgDlgType;
  Buttons: TMsgDlgButtons; const HelpKeyword: string): Integer;
begin raise Exception.Create('Unexpected modal message'); end;
function TTestIDE.UnexpectedQuestion(const Caption, Msg: string; DlgType: TMsgDlgType;
  Buttons: array of const; const HelpKeyword: string): Integer;
begin raise Exception.Create('Unexpected modal question'); end;
var IDE: TTestIDE; Editors: TTestEditors; Manager: TAgentPluginManager;
  Project: TTestProject; Window: TTestWindow; AllEditors: TList;
  Paths: TStringList; UnitEditor, Dual, Unrelated, Outside, FormUnit, Linked,
    ProjectEditor: TTestEditor;
  Root, Error, Resource, OriginalDir, InstallDir: string; I, Before, Date: Integer;
  function AddEditor(const Path: string): TTestEditor;
  begin
    Result := TTestEditor.Create; Result.Path := Path; Result.Dirty := True;
    Result.Text := 'unsaved'; Result.Cursor := Point(4, 3); Result.Top := 2;
    Save(Path, 'disk'); Editors.Items.Add(Result); AllEditors.Add(Result);
  end;
  function Refresh(const Path: string): string;
  begin Paths.Clear; Paths.Add(Path); Result := Manager.RefreshIDEFiles(Paths, Root); end;
begin
  Application.Initialize;
  Root := ParamStr(1); ForceDirectories(Root);
  Editors := TTestEditors.Create(nil); Editors.Items := TList.Create;
  AllEditors := TList.Create; Window := TTestWindow.CreateNew(nil);
  Window.Editors := Editors.Items; Editors.Window := Window;
  SourceEditorManagerIntf := Editors;
  Project := TTestProject.Create(nil); Project.Root := Root;
  Project.InfoFile := IncludeTrailingPathDelimiter(Root) + 'fixture.lpi';
  IDE := TTestIDE.Create(nil); IDE.Project := Project; IDE.Editors := Editors;
  Manager := TAgentPluginManager.Create; Paths := TStringList.Create;
  LazMessageWorker := @IDE.UnexpectedMessage; LazQuestionWorker := @IDE.UnexpectedQuestion;
  try
    { Project discovery must not inherit the Lazarus process directory. }
    InstallDir := IncludeTrailingPathDelimiter(Root) + 'lazarus';
    ForceDirectories(InstallDir);
    OriginalDir := GetCurrentDir;
    Check(SetCurrentDir(InstallDir), 'Could not set IDE process directory fixture');
    try
      Project.InfoFile := IncludeTrailingPathDelimiter(Root) + 'fixture.lpi';
      Project.ProjectDir := '';
      Check(CompareFilenames(GetActiveLazarusProjectDirectory, Root) = 0,
        'Absolute project filename did not set the active project directory');
      Project.InfoFile := 'fixture.lpi';
      Project.ProjectDir := Root;
      Check(CompareFilenames(GetActiveLazarusProjectDirectory, Root) = 0,
        'Relative project filename was not resolved against the project directory');
      Project.InfoFile := '';
      Check(CompareFilenames(GetActiveLazarusProjectDirectory, Root) = 0,
        'Project directory fallback failed');
      Project.InfoFile := IncludeTrailingPathDelimiter(InstallDir) + 'lazarus.lpi';
      Project.ProjectDir := InstallDir;
      ProjectEditor := AddEditor(IncludeTrailingPathDelimiter(Root) + 'working.pas');
      Editors.Active := ProjectEditor;
      Check(CompareFilenames(GetActiveLazarusProjectDirectory, Root) = 0,
        'Active editor did not override the IDE working directory');
    finally
      Check(SetCurrentDir(OriginalDir), 'Could not restore IDE process directory');
    end;
    Project.InfoFile := IncludeTrailingPathDelimiter(Root) + 'fixture.lpi';
    Project.ProjectDir := Root;
    UnitEditor := AddEditor(Root + '/unit.pas');
    Dual := AddEditor(UnitEditor.Path);
    Unrelated := AddEditor(Root + '/unrelated.pas');
    Outside := AddEditor(Root + '/../outside.pas'); Editors.Active := Unrelated;
    Save(UnitEditor.Path, 'changed');
    Check(Refresh(UnitEditor.Path) = '', 'Unit reload failed');
    Check((UnitEditor.Text = 'changed') and not UnitEditor.Dirty and
      (Dual.Text = 'changed') and not Dual.Dirty, 'Dirty/dual buffers not discarded');
    Check(Unrelated.Dirty and (Editors.Active = Unrelated), 'Unrelated buffer/focus changed');
    Check((UnitEditor.Cursor.X = 4) and (UnitEditor.Top = 2) and
      (Dual.Cursor.X = 4) and (Dual.Top = 2), 'Dual-view positions lost');
    Before := IDE.Reloads; Save(Root + '/unopened.pas', 'new'); Refresh(Root + '/unopened.pas');
    Refresh(Outside.Path); Check((IDE.Reloads = Before) and Outside.Dirty, 'Unopened/external files reloaded');
    ForceDirectories(Root + '/../external');
    {$IFDEF UNIX}
    Check(fpSymlink(PChar(Root + '/../external'), PChar(Root + '/linked')) = 0, 'Cannot prepare symlink fixture');
    {$ELSE}
    Check(WinCreateSymbolicLink(PChar(IncludeTrailingPathDelimiter(Root) + 'linked'),
      PChar(ExpandFileName(IncludeTrailingPathDelimiter(Root) + '..' + DirectorySeparator + 'external')), 1),
      'Cannot prepare reparse-point fixture; enable Windows Developer Mode or run as administrator');
    {$ENDIF}
    Linked := AddEditor(Root + '/linked/escaped.pas');
    Refresh(Linked.Path); Check((IDE.Reloads = Before) and Linked.Dirty, 'Parent symlink escaped project confinement');
    Save(UnitEditor.Path, 'again'); Refresh(UnitEditor.Path);
    Check(IDE.Reloads = Before + 1, 'Repeated file edit not reloaded');
    for I := 0 to 2 do
    begin
      FormUnit := AddEditor(Root + '/designer' + IntToStr(I) + '.pp');
      FormUnit.Designer := TIDesigner.Create; Resource := ChangeFileExt(FormUnit.Path, '.lfm');
      Save(Resource, 'resource-' + IntToStr(I));
      Check(Refresh(Resource) = '', 'Designer-only resource reload failed');
      Check(FormUnit.Dirty and (FormUnit.ResourceText = Read(Resource)), 'Resource refresh overwrote unit buffer');
      Check(Refresh(FormUnit.Path) = '', 'Unit/designer refresh failed');
    end;
    Check(IDE.FormReloads = 6, 'Designer path coverage failed');
    Save(Resource, 'malformed'); Error := Refresh(Resource);
    Check(Pos('fixture failure', Error) > 0, 'Malformed resource failure not reported');
    Check(TMethod(LazQuestionWorker).Code = TMethod(@IDE.UnexpectedQuestion).Code, 'Dialog hook leaked');
    Save(Resource, 'fixed'); Check(Refresh(Resource) = '', 'Reload did not recover');
    Check(FormUnit.Designer <> nil, 'Destroyed designer not recreated after paired commit');
    FormUnit := AddEditor(Root + '/dfm.pas'); FormUnit.Designer := TIDesigner.Create;
    Resource := ChangeFileExt(FormUnit.Path, '.dfm'); Save(Resource, 'dfm resource');
    Check((Refresh(Resource) = '') and (FormUnit.ResourceText = 'dfm resource'), 'DFM resource did not map to its unit');
    IDE.CheckFilesOnDiskEnabled := True;
    Manager.RefreshCommandFiles(Root, True);
    Check(not IDE.CheckFilesOnDiskEnabled, 'Disk dialog check not suspended during tool');
    Date := FileAge(UnitEditor.Path); Save(UnitEditor.Path, 'shell'); FileSetDate(UnitEditor.Path, Date);
    Before := IDE.Reloads; Manager.RefreshCommandFiles(Root, False);
    Check((IDE.Reloads = Before + 1) and (UnitEditor.Text = 'shell'), 'Command disk contents not compared');
    Check(IDE.CheckFilesOnDiskEnabled, 'Disk check setting not restored');
    Manager.RefreshCommandFiles(Root, True); Save(UnitEditor.Path, 'tool'); Refresh(UnitEditor.Path);
    Before := IDE.Reloads; Manager.RefreshCommandFiles(Root, False);
    Check(IDE.Reloads = Before, 'Per-file notification reloaded twice at tool completion');
    IDE.CheckFilesOnDiskEnabled := False; Manager.RefreshCommandFiles(Root, True);
    Manager.RefreshCommandFiles(Root, False);
    Check(not IDE.CheckFilesOnDiskEnabled, 'Previously disabled disk check was enabled');
    Before := IDE.Reloads; Project.Root := Root + '/other'; ForceDirectories(Project.Root);
    Refresh(UnitEditor.Path); Check(IDE.Reloads = Before, 'Reload crossed project switch'); Project.Root := Root;
    DeleteFile(UnitEditor.Path); Check(Refresh(UnitEditor.Path) = '', 'Deleted source not handled');
    Check(Editors.SourceEditorIntfWithFilename(UnitEditor.Path) = nil, 'Deleted source view left open');
    DeleteFile(Resource); Check(Refresh(Resource) = '', 'Deleted designer not handled');
    Check(Editors.SourceEditorIntfWithFilename(FormUnit.Path) = nil, 'Deleted form view left open');
    WriteLn('Lazarus reload adapter tests passed (source, dual views, designer resources, deletion, snapshots, silent errors).');
  finally
    Paths.Free; Manager.Free; IDE.Free; Project.Free;
    SourceEditorManagerIntf := nil; Window.Free;
    for I := 0 to AllEditors.Count - 1 do
    begin
      TTestEditor(AllEditors[I]).Designer.Free;
      TTestEditor(AllEditors[I]).Free;
    end;
    AllEditors.Free; Editors.Items.Free; Editors.Free;
  end;
end.
