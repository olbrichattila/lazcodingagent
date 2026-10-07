unit uFrmChat;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, ComCtrls, fpjson,
  jsonparser, uFrmChatSession;

type
  TFrmChat = class(TForm)
  private
    FTabBar: TScrollBox;
    FPages: TPageControl;
    FAddButton: TButton;
    FCloseFinalizeTimer: TTimer;
    FCloseFinalizePending: Boolean;
    FLoading, FShuttingDown: Boolean;
    procedure AddTabClick(Sender: TObject);
    procedure SelectTabClick(Sender: TObject);
    procedure CloseTabClick(Sender: TObject);
    procedure FinalizeTabClose(Sender: TObject);
    procedure SessionChanged(Sender: TObject);
    procedure AddTab(AData: TJSONObject = nil; ARebuildTabBar: Boolean = True);
    procedure RebuildTabBar;
    procedure SaveSessions;
    procedure LoadSessions;
    function SessionAt(AIndex: Integer): TFrmChatSession;
    function StoragePath: string;
  public
    procedure RefreshProjectDirectoryInfo;
  published
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormActivate(Sender: TObject);
  end;

var
  FrmChat: TFrmChat;

implementation

{$R *.lfm}

procedure TFrmChat.FormCreate(Sender: TObject);
begin
  FLoading := True;
  FShuttingDown := False;
  FTabBar := TScrollBox.Create(Self);
  FTabBar.Parent := Self;
  FTabBar.Align := alTop;
  FTabBar.Height := 52;
  FTabBar.HorzScrollBar.Visible := True;
  FTabBar.VertScrollBar.Visible := False;
  FTabBar.AutoScroll := True;
  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.ShowTabs := False;
  FPages.TabHeight := 0;
  FCloseFinalizePending := False;
  FCloseFinalizeTimer := TTimer.Create(Self);
  FCloseFinalizeTimer.Enabled := False;
  FCloseFinalizeTimer.Interval := 1;
  FCloseFinalizeTimer.OnTimer := @FinalizeTabClose;
  LoadSessions;
  if FPages.PageCount = 0 then AddTab;
  if (FPages.PageCount > 0) then
  begin
    FPages.ActivePageIndex := 0;
    RebuildTabBar;
  end;
  FLoading := False;
  SaveSessions;
end;

procedure TFrmChat.FormDestroy(Sender: TObject);
var I: Integer; Session: TFrmChatSession; WasRunning: Boolean;
begin
  FShuttingDown := True;
  FCloseFinalizeTimer.Enabled := False;
  FCloseFinalizePending := False;
  for I := 0 to FPages.PageCount - 1 do
  begin
    Session := SessionAt(I);
    if Session <> nil then
    begin
      WasRunning := Session.IsRunning;
      Session.StopRun;
      if WasRunning then Session.MarkInterrupted;
    end;
  end;
  SaveSessions;
end;

procedure TFrmChat.FormActivate(Sender: TObject);
begin
  RefreshProjectDirectoryInfo;
end;

procedure TFrmChat.RefreshProjectDirectoryInfo;
var I: Integer; Session: TFrmChatSession;
begin
  if not Assigned(FPages) then Exit;
  for I := 0 to FPages.PageCount - 1 do
  begin
    Session := SessionAt(I);
    if Session <> nil then Session.RefreshProjectDirectoryInfo;
  end;
end;

function TFrmChat.StoragePath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'chat_tabs.json';
end;

function TFrmChat.SessionAt(AIndex: Integer): TFrmChatSession;
var I: Integer; Sheet: TTabSheet;
begin
  Result := nil;
  if (AIndex < 0) or (AIndex >= FPages.PageCount) then Exit;
  Sheet := FPages.Pages[AIndex];
  for I := 0 to Sheet.ControlCount - 1 do
    if Sheet.Controls[I] is TFrmChatSession then
      Exit(TFrmChatSession(Sheet.Controls[I]));
end;

procedure TFrmChat.AddTab(AData: TJSONObject; ARebuildTabBar: Boolean);
var Sheet: TTabSheet; Session: TFrmChatSession;
begin
  Sheet := TTabSheet.Create(FPages);
  Sheet.PageControl := FPages;
  Sheet.Caption := 'New Chat';
  Session := TFrmChatSession.Create(Sheet);
  Session.Parent := Sheet;
  Session.Align := alClient;
  Session.OnStateChange := @SessionChanged;
  if AData <> nil then Session.LoadState(AData);
  FPages.ActivePage := Sheet;
  if ARebuildTabBar then
  begin
    RebuildTabBar;
    if not FLoading then SaveSessions;
  end;
end;

procedure TFrmChat.AddTabClick(Sender: TObject);
begin
  if FShuttingDown or FCloseFinalizePending then Exit;
  { The plus button is also part of the tab strip. Defer its destruction for
    the same reason as a close button. }
  FCloseFinalizePending := True;
  try
    AddTab(nil, False);
  except
    FCloseFinalizePending := False;
    raise;
  end;
  FCloseFinalizeTimer.Enabled := True;
end;

procedure TFrmChat.SelectTabClick(Sender: TObject);
var I: Integer; P: TControl;
begin
  if (Sender is TControl) then
  begin
    I := TControl(Sender).Tag;
    if (I >= 0) and (I < FPages.PageCount) then FPages.ActivePageIndex := I;
  end;
  for I := 0 to FPages.PageCount - 1 do
  begin
    P := FTabBar.FindChildControl('ChatHeader' + IntToStr(I));
    if P is TPanel then
      if I = FPages.ActivePageIndex then TPanel(P).Color := clHighlight
      else TPanel(P).Color := clBtnFace;
  end;
  SessionChanged(nil);
end;

procedure TFrmChat.CloseTabClick(Sender: TObject);
var I, CloseIndex: Integer; Session: TFrmChatSession;
begin
  if FShuttingDown or FCloseFinalizePending then Exit;
  if not (Sender is TControl) then Exit;
  CloseIndex := TControl(Sender).Tag;
  if (CloseIndex < 0) or (CloseIndex >= FPages.PageCount) then Exit;
  FCloseFinalizePending := True;
  Session := SessionAt(CloseIndex);
  try
    if Session <> nil then Session.StopRun;
    FPages.Pages[CloseIndex].Free;
  except
    FCloseFinalizePending := False;
    raise;
  end;
  { Do not rebuild here: the sender is the close button in the tab strip, and
    destroying it before its OnClick dispatch returns can cause an AV. }
  FCloseFinalizeTimer.Enabled := True;
end;

procedure TFrmChat.FinalizeTabClose(Sender: TObject);
begin
  FCloseFinalizeTimer.Enabled := False;
  if FShuttingDown then
  begin
    FCloseFinalizePending := False;
    Exit;
  end;
  FCloseFinalizePending := False;
  if FPages.PageCount = 0 then AddTab
  else
  begin
    if FPages.ActivePageIndex < 0 then FPages.ActivePageIndex := FPages.PageCount - 1;
    RebuildTabBar;
    SaveSessions;
  end;
end;

procedure TFrmChat.RebuildTabBar;
var I, X: Integer; Panel: TPanel; LabelTab: TLabel; CloseBtn: TButton;
  Session: TFrmChatSession;
begin
  for I := FTabBar.ControlCount - 1 downto 0 do
    if FTabBar.Controls[I] <> FAddButton then FTabBar.Controls[I].Free;
  if Assigned(FAddButton) then FreeAndNil(FAddButton);
  X := 2;
  for I := 0 to FPages.PageCount - 1 do
  begin
    Session := SessionAt(I);
    Panel := TPanel.Create(FTabBar);
    Panel.Name := 'ChatHeader' + IntToStr(I);
    Panel.Caption := '';
    Panel.Parent := FTabBar;
    Panel.SetBounds(X, 2, 170, 30);
    Panel.BevelOuter := bvLowered;
    Panel.Tag := I;
    Panel.OnClick := @SelectTabClick;
    if I = FPages.ActivePageIndex then Panel.Color := clHighlight;
    LabelTab := TLabel.Create(Panel);
    LabelTab.Parent := Panel;
    LabelTab.Align := alClient;
    LabelTab.Caption := '  ' + Session.TabCaption;
    LabelTab.Layout := tlCenter;
    LabelTab.Tag := I;
    LabelTab.OnClick := @SelectTabClick;
    CloseBtn := TButton.Create(Panel);
    CloseBtn.Parent := Panel;
    CloseBtn.Align := alRight;
    CloseBtn.Width := 28;
    CloseBtn.Caption := '×';
    CloseBtn.Tag := I;
    CloseBtn.OnClick := @CloseTabClick;
    Inc(X, 172);
  end;
  FAddButton := TButton.Create(FTabBar);
  FAddButton.Parent := FTabBar;
  FAddButton.SetBounds(X, 2, 30, 30);
  FAddButton.Caption := '+';
  FAddButton.Hint := 'New chat';
  FAddButton.ShowHint := True;
  FAddButton.OnClick := @AddTabClick;
  FTabBar.HorzScrollBar.Range := X + 34;
end;

procedure TFrmChat.SessionChanged(Sender: TObject);
var I: Integer; Session: TFrmChatSession; Panel: TControl; J: Integer;
  AnyRunning: Boolean; Child: TControl;
begin
  if FLoading or FShuttingDown then Exit;
  AnyRunning := False;
  for I := 0 to FPages.PageCount - 1 do
    if (SessionAt(I) <> nil) and SessionAt(I).IsRunning then AnyRunning := True;
  for I := 0 to FPages.PageCount - 1 do
  begin
    Session := SessionAt(I);
    Panel := FTabBar.FindChildControl('ChatHeader' + IntToStr(I));
    if (Session <> nil) and (Panel is TPanel) then
    begin
      if I = FPages.ActivePageIndex then TPanel(Panel).Color := clHighlight
      else TPanel(Panel).Color := clBtnFace;
      FPages.Pages[I].Caption := Session.TabCaption;
      for J := 0 to TPanel(Panel).ControlCount - 1 do
      begin
        Child := TPanel(Panel).Controls[J];
        if Child is TLabel then TLabel(Child).Caption := '  ' + Session.TabCaption;
      end;
      begin
        Session.SetSharedSettingsEnabled(not AnyRunning);
        Session.SetSharedRunBlocked(AnyRunning and not Session.IsRunning);
        Session.SynchronizeSharedModel;
      end;
    end;
  end;
  SaveSessions;
end;

procedure TFrmChat.SaveSessions;
var Root: TJSONObject; Arr: TJSONArray; I: Integer; TempPath, Path, JSONText: string;
  Stream: TFileStream; Session: TFrmChatSession;
begin
  if not Assigned(FPages) or FLoading then Exit;
  Root := TJSONObject.Create;
  try
    Root.Add('selected', FPages.ActivePageIndex);
    Arr := TJSONArray.Create;
    for I := 0 to FPages.PageCount - 1 do
    begin
      Session := SessionAt(I);
      if Session <> nil then Arr.Add(Session.SaveState);
    end;
    Root.Add('tabs', Arr);
    Path := StoragePath;
    ForceDirectories(ExtractFileDir(Path));
    TempPath := Path + '.tmp';
    JSONText := Root.AsJSON;
    Stream := TFileStream.Create(TempPath, fmCreate);
    try if JSONText <> '' then Stream.WriteBuffer(JSONText[1], Length(JSONText));
    finally Stream.Free; end;
    if FileExists(Path) then DeleteFile(Path);
    RenameFile(TempPath, Path);
  finally
    Root.Free;
  end;
end;

procedure TFrmChat.LoadSessions;
var Data: TJSONData; Root: TJSONObject; Arr: TJSONArray; I, Selected: Integer;
  S: TFileStream; JSONText: string;
begin
  if not FileExists(StoragePath) then Exit;
  try
    S := TFileStream.Create(StoragePath, fmOpenRead or fmShareDenyNone);
    try SetLength(JSONText, S.Size); if Length(JSONText) > 0 then S.ReadBuffer(JSONText[1], Length(JSONText));
    finally S.Free; end;
    Data := GetJSON(JSONText);
    try
      Root := TJSONObject(Data);
      Arr := TJSONArray(Root.Find('tabs'));
      if Arr = nil then Exit;
      for I := 0 to Arr.Count - 1 do
        if Arr[I].JSONType = jtObject then AddTab(TJSONObject(Arr[I]));
      Selected := Root.Get('selected', 0);
      if (Selected >= 0) and (Selected < FPages.PageCount) then FPages.ActivePageIndex := Selected;
    finally Data.Free; end;
  except
    { A corrupt or older session file must not prevent the chat from opening. }
  end;
end;

end.
