unit uFrmSettings;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, ComCtrls,
  uAgentTypes, uAgentConfig, uFrmModelPicker;

type
  { TFrmSettings }

  TFrmSettings = class(TForm)
    BtnSave: TButton;
    BtnCancel: TButton;
    BtnAddModel: TButton;
    BtnUpdateModel: TButton;
    BtnDeleteModel: TButton;
    BtnFetchServer: TButton;
    BtnSetActive: TButton;
    EdtContextBudget, EdtRecentTurns: TEdit;
    LblContextBudget, LblRecentTurns, LblContextHint: TLabel;
    ChkDebuggingMode: TCheckBox;
    CmbProvider: TComboBox;
    EdtApiKey: TEdit;
    EdtEndpoint: TEdit;
    EdtModelName: TEdit;
    LblActiveModel: TLabel;
    LblAgentsInfo: TLabel;
    LblApiKey: TLabel;
    LblEndpoint: TLabel;
    LblKnowledgeInfo: TLabel;
    LblModelEdit: TLabel;
    LblModels: TLabel;
    LblProvider: TLabel;
    LblProviderHint: TLabel;
    LstModels: TListBox;
    PageControlSettings: TPageControl;
    PnlButtons: TPanel;
    PnlModelActions: TPanel;
    TabAgents: TTabSheet;
    TabGeneral: TTabSheet;
    TabKnowledge: TTabSheet;
    TabLLM: TTabSheet;
    procedure BtnAddModelClick(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);
    procedure BtnDeleteModelClick(Sender: TObject);
    procedure BtnFetchServerClick(Sender: TObject);
    procedure BtnSaveClick(Sender: TObject);
    procedure BtnSetActiveClick(Sender: TObject);
    procedure BtnUpdateModelClick(Sender: TObject);
    procedure CmbProviderChange(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure LstModelsDblClick(Sender: TObject);
    procedure LstModelsSelectionChange(Sender: TObject; User: boolean);
  private
    FActiveModel: string;
    procedure UpdateProviderUI(AProvider: TLLMProvider; AResetDefaults: Boolean);
    procedure UpdateActiveModelLabel;
  public
  end;

var
  FrmSettings: TFrmSettings;

implementation

{$R *.lfm}

{ TFrmSettings }

procedure TFrmSettings.FormShow(Sender: TObject);
var
  Cfg: TAgentConfig;
  I: Integer;
  ProvName: string;
begin
  Cfg := GetAgentConfig;

  CmbProvider.Items.Clear;
  CmbProvider.Items.Add('OpenAI');
  CmbProvider.Items.Add('Nous Portal');
  CmbProvider.Items.Add('OpenRouter');
  CmbProvider.Items.Add('Ollama (Local)');
  CmbProvider.Items.Add('Custom');

  ProvName := ProviderToString(Cfg.Provider);
  CmbProvider.ItemIndex := 0;
  for I := 0 to CmbProvider.Items.Count - 1 do
  begin
    if SameText(CmbProvider.Items[I], ProvName) then
    begin
      CmbProvider.ItemIndex := I;
      Break;
    end;
  end;

  EdtApiKey.Text := Cfg.APIKey;
  EdtEndpoint.Text := Cfg.EndpointURL;
  FActiveModel := Cfg.ModelName;

  LstModels.Items.Assign(Cfg.ModelList);
  if LstModels.Items.Count = 0 then
    GetDefaultModelList(Cfg.Provider, LstModels.Items);

  if (FActiveModel <> '') and (LstModels.Items.IndexOf(FActiveModel) < 0) then
    LstModels.Items.Insert(0, FActiveModel);

  if LstModels.Items.Count > 0 then
  begin
    I := LstModels.Items.IndexOf(FActiveModel);
    if I >= 0 then
      LstModels.ItemIndex := I
    else
    begin
      LstModels.ItemIndex := 0;
      FActiveModel := LstModels.Items[0];
    end;
    EdtModelName.Text := LstModels.Items[LstModels.ItemIndex];
  end
  else
    EdtModelName.Text := '';

  UpdateProviderUI(Cfg.Provider, False);
  ChkDebuggingMode.Checked := Cfg.DebuggingMode;
  EdtContextBudget.Text := IntToStr(Cfg.ContextBudget);
  EdtRecentTurns.Text := IntToStr(Cfg.RecentTurns);
  UpdateActiveModelLabel;
end;

procedure TFrmSettings.UpdateProviderUI(AProvider: TLLMProvider; AResetDefaults: Boolean);
var
  HintText: string;
begin
  if AResetDefaults then
  begin
    EdtEndpoint.Text := GetDefaultEndpoint(AProvider);
    GetDefaultModelList(AProvider, LstModels.Items);
    FActiveModel := GetDefaultModel(AProvider);
    if (FActiveModel <> '') and (LstModels.Items.IndexOf(FActiveModel) < 0) then
      LstModels.Items.Insert(0, FActiveModel);

    if LstModels.Items.Count > 0 then
    begin
      LstModels.ItemIndex := LstModels.Items.IndexOf(FActiveModel);
      if (LstModels.ItemIndex >= 0) and (LstModels.ItemIndex < LstModels.Items.Count) then
        EdtModelName.Text := LstModels.Items[LstModels.ItemIndex]
      else
        EdtModelName.Text := LstModels.Items[0];
    end;
    UpdateActiveModelLabel;
  end;

  case AProvider of
    lpOpenAI:
      HintText := 'OpenAI endpoints and GPT models.';
    lpNousPortal:
      HintText := 'Nous Portal (Hermes, Gemini, DeepSeek).';
    lpOpenRouter:
      HintText := 'OpenRouter unified API gateway.';
    lpOllama:
      HintText := 'Local Ollama server (API Key optional).';
    lpCustom:
      HintText := 'Custom OpenAI-compatible API endpoint.';
  end;

  if Assigned(LblProviderHint) then
    LblProviderHint.Caption := HintText;
end;

procedure TFrmSettings.UpdateActiveModelLabel;
begin
  if FActiveModel <> '' then
    LblActiveModel.Caption := 'Active Selected Model: ' + FActiveModel
  else
    LblActiveModel.Caption := 'Active Selected Model: (None)';
end;

procedure TFrmSettings.CmbProviderChange(Sender: TObject);
var
  SelectedProvider: TLLMProvider;
begin
  SelectedProvider := StringToProvider(CmbProvider.Text);
  UpdateProviderUI(SelectedProvider, True);
end;

procedure TFrmSettings.LstModelsSelectionChange(Sender: TObject; User: boolean);
begin
  if LstModels.ItemIndex >= 0 then
    EdtModelName.Text := LstModels.Items[LstModels.ItemIndex];
end;

procedure TFrmSettings.LstModelsDblClick(Sender: TObject);
begin
  if LstModels.ItemIndex >= 0 then
  begin
    FActiveModel := LstModels.Items[LstModels.ItemIndex];
    UpdateActiveModelLabel;
  end;
end;

procedure TFrmSettings.BtnSetActiveClick(Sender: TObject);
begin
  if LstModels.ItemIndex >= 0 then
  begin
    FActiveModel := LstModels.Items[LstModels.ItemIndex];
    UpdateActiveModelLabel;
  end
  else if Trim(EdtModelName.Text) <> '' then
  begin
    FActiveModel := Trim(EdtModelName.Text);
    UpdateActiveModelLabel;
  end;
end;

procedure TFrmSettings.BtnAddModelClick(Sender: TObject);
var
  NewName: string;
begin
  NewName := Trim(EdtModelName.Text);
  if NewName = '' then Exit;

  if LstModels.Items.IndexOf(NewName) < 0 then
  begin
    LstModels.Items.Add(NewName);
    LstModels.ItemIndex := LstModels.Items.Count - 1;
    FActiveModel := NewName;
    UpdateActiveModelLabel;
  end;
end;

procedure TFrmSettings.BtnUpdateModelClick(Sender: TObject);
var
  NewName: string;
begin
  NewName := Trim(EdtModelName.Text);
  if (NewName = '') or (LstModels.ItemIndex < 0) then Exit;

  LstModels.Items[LstModels.ItemIndex] := NewName;
  FActiveModel := NewName;
  UpdateActiveModelLabel;
end;

procedure TFrmSettings.BtnDeleteModelClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := LstModels.ItemIndex;
  if Idx >= 0 then
  begin
    LstModels.Items.Delete(Idx);
    if LstModels.Items.Count > 0 then
    begin
      if Idx >= LstModels.Items.Count then
        Idx := LstModels.Items.Count - 1;
      LstModels.ItemIndex := Idx;
      EdtModelName.Text := LstModels.Items[Idx];
      if not (LstModels.Items.IndexOf(FActiveModel) >= 0) then
        FActiveModel := LstModels.Items[Idx];
    end
    else
    begin
      EdtModelName.Text := '';
      FActiveModel := '';
    end;
    UpdateActiveModelLabel;
  end;
end;

procedure TFrmSettings.BtnFetchServerClick(Sender: TObject);
var
  Cfg: TAgentConfig;
  ChosenModel: string;
begin
  Cfg := GetAgentConfig;
  Cfg.Provider := StringToProvider(CmbProvider.Text);
  Cfg.APIKey := Trim(EdtApiKey.Text);
  Cfg.EndpointURL := Trim(EdtEndpoint.Text);
  Cfg.ModelName := FActiveModel;

  if ShowModelPicker(FActiveModel, ChosenModel) then
  begin
    if LstModels.Items.IndexOf(ChosenModel) < 0 then
      LstModels.Items.Insert(0, ChosenModel);

    LstModels.ItemIndex := LstModels.Items.IndexOf(ChosenModel);
    EdtModelName.Text := ChosenModel;
    FActiveModel := ChosenModel;
    UpdateActiveModelLabel;
  end;
end;

procedure TFrmSettings.BtnSaveClick(Sender: TObject);
var
  Cfg: TAgentConfig;
  Budget, Recent: Integer;
begin
  if not TryStrToInt(Trim(EdtContextBudget.Text), Budget) or (Budget < 4096) or (Budget > 2000000) then
  begin ShowMessage('Input budget must be between 4096 and 2000000 estimated tokens.'); Exit; end;
  if not TryStrToInt(Trim(EdtRecentTurns.Text), Recent) or (Recent < 0) or (Recent > 100) then
  begin ShowMessage('Recent completed turns must be between 0 and 100.'); Exit; end;
  Cfg := GetAgentConfig;
  Cfg.ContextBudget := Budget; Cfg.RecentTurns := Recent;
  Cfg.Provider := StringToProvider(CmbProvider.Text);
  Cfg.APIKey := Trim(EdtApiKey.Text);
  Cfg.EndpointURL := Trim(EdtEndpoint.Text);

  if FActiveModel = '' then
  begin
    if LstModels.Items.Count > 0 then
      FActiveModel := LstModels.Items[0]
    else
      FActiveModel := Trim(EdtModelName.Text);
  end;

  Cfg.ModelName := FActiveModel;
  Cfg.SetModels(LstModels.Items);
  Cfg.DebuggingMode := ChkDebuggingMode.Checked;
  Cfg.Save;
  ModalResult := mrOk;
end;

procedure TFrmSettings.BtnCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

end.
