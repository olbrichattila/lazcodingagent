unit uFrmModelPicker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  uAgentConfig, uLLMClient;

type
  { TFrmModelPicker }

  TFrmModelPicker = class(TForm)
    BtnCancel: TButton;
    BtnRefresh: TButton;
    BtnSelect: TButton;
    EdtSearch: TEdit;
    LblModelCount: TLabel;
    LblSearch: TLabel;
    LstModels: TListBox;
    PnlBottom: TPanel;
    PnlTop: TPanel;
    procedure BtnCancelClick(Sender: TObject);
    procedure BtnRefreshClick(Sender: TObject);
    procedure BtnSelectClick(Sender: TObject);
    procedure EdtSearchChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure LstModelsDblClick(Sender: TObject);
    procedure LstModelsSelectionChange(Sender: TObject; User: boolean);
  private
    FAllModels: TStringList;
    FSelectedModel: string;
    procedure FilterModels;
    procedure FetchModels;
  public
    property SelectedModel: string read FSelectedModel write FSelectedModel;
  end;

function ShowModelPicker(const ACurrentModel: string; out AChosenModel: string): Boolean;

implementation

{$R *.lfm}

function ShowModelPicker(const ACurrentModel: string; out AChosenModel: string): Boolean;
var
  Frm: TFrmModelPicker;
begin
  Result := False;
  AChosenModel := ACurrentModel;
  Frm := TFrmModelPicker.Create(Application);
  try
    Frm.SelectedModel := ACurrentModel;
    if Frm.ShowModal = mrOk then
    begin
      AChosenModel := Frm.SelectedModel;
      Result := True;
    end;
  finally
    Frm.Free;
  end;
end;

{ TFrmModelPicker }

procedure TFrmModelPicker.FormCreate(Sender: TObject);
begin
  FAllModels := TStringList.Create;
end;

procedure TFrmModelPicker.FormDestroy(Sender: TObject);
begin
  FAllModels.Free;
end;

procedure TFrmModelPicker.FormShow(Sender: TObject);
begin
  FetchModels;
end;

procedure TFrmModelPicker.FetchModels;
var
  Client: TLLMClient;
  Cfg: TAgentConfig;
  ErrMsg: string;
begin
  Cfg := GetAgentConfig;
  Client := TLLMClient.Create(Cfg);
  try
    LstModels.Clear;
    LblModelCount.Caption := 'Fetching models from server...';
    Application.ProcessMessages;

    if Client.FetchAvailableModels(FAllModels, ErrMsg) then
    begin
      FilterModels;
    end
    else
    begin
      LblModelCount.Caption := 'Error: ' + ErrMsg;
      ShowMessage('Failed to fetch models:' + LineEnding + ErrMsg);
    end;
  finally
    Client.Free;
  end;
end;

procedure TFrmModelPicker.FilterModels;
var
  SearchTerm: string;
  I: Integer;
  ModelName: string;
  SelectIdx: Integer;
begin
  SearchTerm := LowerCase(Trim(EdtSearch.Text));
  LstModels.Items.BeginUpdate;
  try
    LstModels.Clear;
    SelectIdx := -1;

    for I := 0 to FAllModels.Count - 1 do
    begin
      ModelName := FAllModels[I];
      if (SearchTerm = '') or (Pos(SearchTerm, LowerCase(ModelName)) > 0) then
      begin
        LstModels.Items.Add(ModelName);
        if SameText(ModelName, FSelectedModel) then
          SelectIdx := LstModels.Items.Count - 1;
      end;
    end;

    if SelectIdx >= 0 then
      LstModels.ItemIndex := SelectIdx
    else if LstModels.Items.Count > 0 then
      LstModels.ItemIndex := 0;

  finally
    LstModels.Items.EndUpdate;
  end;

  LblModelCount.Caption := Format('Showing %d of %d models', [LstModels.Items.Count, FAllModels.Count]);
  BtnSelect.Enabled := LstModels.ItemIndex >= 0;
end;

procedure TFrmModelPicker.EdtSearchChange(Sender: TObject);
begin
  FilterModels;
end;

procedure TFrmModelPicker.BtnRefreshClick(Sender: TObject);
begin
  FetchModels;
end;

procedure TFrmModelPicker.LstModelsSelectionChange(Sender: TObject; User: boolean);
begin
  if LstModels.ItemIndex >= 0 then
  begin
    FSelectedModel := LstModels.Items[LstModels.ItemIndex];
    BtnSelect.Enabled := True;
  end
  else
    BtnSelect.Enabled := False;
end;

procedure TFrmModelPicker.LstModelsDblClick(Sender: TObject);
begin
  if LstModels.ItemIndex >= 0 then
  begin
    FSelectedModel := LstModels.Items[LstModels.ItemIndex];
    ModalResult := mrOk;
  end;
end;

procedure TFrmModelPicker.BtnSelectClick(Sender: TObject);
begin
  if LstModels.ItemIndex >= 0 then
  begin
    FSelectedModel := LstModels.Items[LstModels.ItemIndex];
    ModalResult := mrOk;
  end;
end;

procedure TFrmModelPicker.BtnCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

end.
