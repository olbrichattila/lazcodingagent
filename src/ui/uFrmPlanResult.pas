unit uFrmPlanResult;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  uMarkdownView;

type
  TFrmPlanResult = class(TForm)
    BtnBuild: TButton;
    BtnClose: TButton;
    LblPlanPath: TLabel;
    PnlPlan: TPanel;
    PnlBottom: TPanel;
    procedure BtnBuildClick(Sender: TObject);
  private
    FMarkdownView: TMarkdownView;
  public
    procedure LoadPlan(const APath, AContent: string);
  end;

implementation

{$R *.lfm}

procedure TFrmPlanResult.LoadPlan(const APath, AContent: string);
begin
  LblPlanPath.Caption := 'Plan file: ' + APath;
  LblPlanPath.Hint := APath;
  if not Assigned(FMarkdownView) then
  begin
    FMarkdownView := TMarkdownView.Create(Self);
    FMarkdownView.Parent := PnlPlan;
    FMarkdownView.Align := alClient;
  end;
  FMarkdownView.SetMarkdown(AContent);
end;

procedure TFrmPlanResult.BtnBuildClick(Sender: TObject);
begin
  ModalResult := mrOk;
end;

end.
