program standalone_chat;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms,
  uFrmChat,
  uFrmChatSession,
  uFrmSettings,
  uFrmModelPicker,
  uFrmPlanResult,
  uAgentTypes,
  uAgentConfig,
  uAgentHistory,
  uAgentCore,
  uAgentThread,
  uLLMClient,
  uToolBase,
  uToolFileOps,
  uToolLocal;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TFrmChat, FrmChat);
  Application.Run;
end.
