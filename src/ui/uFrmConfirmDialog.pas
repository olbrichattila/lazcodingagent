unit uFrmConfirmDialog;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls;

type
  { TFrmConfirmDialog }

  TFrmConfirmDialog = class(TForm)
    BtnOk: TButton;
    BtnCancel: TButton;
    ImageWarning: TImage;
    LblQuestion: TLabel;
    LblDetails: TLabel;
    PnlBottom: TPanel;
    PnlContent: TPanel;
    procedure FormCreate(Sender: TObject);
  private
  public
    class function Execute(AOwner: TComponent; const AQuestion: string = 'Are you sure?'; const ADetails: string = 'Please confirm if you want to proceed.'): Boolean;
  end;

var
  FrmConfirmDialog: TFrmConfirmDialog;

implementation

{$R *.lfm}

{ TFrmConfirmDialog }

procedure TFrmConfirmDialog.FormCreate(Sender: TObject);
begin
  Caption := 'Confirmation';
  Position := poScreenCenter;
  BorderStyle := bsDialog;
end;

class function TFrmConfirmDialog.Execute(AOwner: TComponent; const AQuestion: string; const ADetails: string): Boolean;
var
  Dlg: TFrmConfirmDialog;
begin
  Dlg := TFrmConfirmDialog.Create(AOwner);
  try
    if AQuestion <> '' then
      Dlg.LblQuestion.Caption := AQuestion;
    if ADetails <> '' then
      Dlg.LblDetails.Caption := ADetails;
    Result := (Dlg.ShowModal = mrOk);
  finally
    Dlg.Free;
  end;
end;

end.
