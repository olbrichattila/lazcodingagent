unit uAgentThread;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uAgentTypes, uAgentHistory, uAgentConfig, uAgentCore, uLLMClient, uToolBase, uToolFileOps, uAgentContext;

type
  TThreadChunkEvent = procedure(const AChunk: string; AIsReasoning: Boolean) of object;
  TThreadToolEvent = procedure(const AToolName, AToolData: string) of object;
  TThreadCompleteEvent = procedure(ASuccess: Boolean; const AFinalText: string) of object;

  TAgentWorkerThread = class(TThread)
  private
    FPrompt: string;
    FRunMode: TAgentMode;
    FProjectRoot: string;
    FAgent: TAgentCore;
    FOnProgress: TContextProgress;
    FSyncProgress: string;
    FOnChunk: TThreadChunkEvent;
    FOnToolExecuting: TThreadToolEvent;
    FOnToolCompleted: TThreadToolEvent;
    FOnCompleted: TThreadCompleteEvent;
    FOnFileChanged: TToolFileChanged;
    FSyncFilePath: string;

    FSyncChunk: string;
    FSyncIsReasoning: Boolean;
    FSyncToolName: string;
    FSyncToolData: string;
    FSyncSuccess: Boolean;
    FSyncFinalText: string;

    function ToolIsCancelled: Boolean;
    procedure SyncProgress;
    procedure HandleProgress(const AText: string);
    procedure HandleToolExecuting(const AName, AData: string);
    procedure HandleToolCompleted(const AName, AData: string);
    procedure SyncChunk;
    procedure SyncToolExecuting;
    procedure SyncToolCompleted;
    procedure SyncCompleted;
    procedure SyncFileChanged;
    procedure HandleFileChanged(const APath: string);

    procedure HandleSSEChunk(const AChunk: string; AIsReasoning: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(AAgent: TAgentCore; const APrompt: string;
      AOnChunk: TThreadChunkEvent;
      AOnToolExecuting, AOnToolCompleted: TThreadToolEvent;
      AOnCompleted: TThreadCompleteEvent;
      AOnFileChanged: TToolFileChanged = nil; AOnProgress: TContextProgress = nil;
      const AProjectRoot: string = '');
  end;

implementation

constructor TAgentWorkerThread.Create(AAgent: TAgentCore; const APrompt: string;
  AOnChunk: TThreadChunkEvent;
  AOnToolExecuting, AOnToolCompleted: TThreadToolEvent;
  AOnCompleted: TThreadCompleteEvent; AOnFileChanged: TToolFileChanged;
  AOnProgress: TContextProgress; const AProjectRoot: string);
begin
  inherited Create(True); { Start suspended }
  FreeOnTerminate := True;
  FAgent := AAgent;
  FPrompt := APrompt;
  FRunMode := AAgent.Mode;
  FProjectRoot := AProjectRoot;
  if FProjectRoot = '' then FProjectRoot := GetEffectiveProjectDir;
  FOnChunk := AOnChunk;
  FOnToolExecuting := AOnToolExecuting;
  FOnToolCompleted := AOnToolCompleted;
  FOnCompleted := AOnCompleted;
  FOnFileChanged := AOnFileChanged;
  FOnProgress := AOnProgress;
end;

procedure TAgentWorkerThread.HandleFileChanged(const APath: string);
begin
  FSyncFilePath := APath;
  Synchronize(@SyncFileChanged);
end;

procedure TAgentWorkerThread.SyncFileChanged;
begin
  if Assigned(FOnFileChanged) then FOnFileChanged(FSyncFilePath);
end;

procedure TAgentWorkerThread.HandleSSEChunk(const AChunk: string; AIsReasoning: Boolean);
begin
  if Terminated then Exit;
  FSyncChunk := AChunk;
  FSyncIsReasoning := AIsReasoning;
  Synchronize(@SyncChunk);
end;

function TAgentWorkerThread.ToolIsCancelled: Boolean;
begin Result := Terminated; end;

procedure TAgentWorkerThread.SyncChunk;
begin
  if Assigned(FOnChunk) then
    FOnChunk(FSyncChunk, FSyncIsReasoning);
end;

procedure TAgentWorkerThread.SyncToolExecuting;
begin
  if Assigned(FOnToolExecuting) then
    FOnToolExecuting(FSyncToolName, FSyncToolData);
end;

procedure TAgentWorkerThread.SyncToolCompleted;
begin
  if Assigned(FOnToolCompleted) then
    FOnToolCompleted(FSyncToolName, FSyncToolData);
end;

procedure TAgentWorkerThread.SyncCompleted;
begin
  if Assigned(FOnCompleted) then
    FOnCompleted(FSyncSuccess, FSyncFinalText);
end;

procedure TAgentWorkerThread.SyncProgress;
begin if Assigned(FOnProgress) then FOnProgress(FSyncProgress); end;
procedure TAgentWorkerThread.HandleProgress(const AText: string);
begin
  if Terminated then Exit;
  FSyncProgress := AText; Synchronize(@SyncProgress);
end;
procedure TAgentWorkerThread.HandleToolExecuting(const AName, AData: string);
begin
  if Terminated then Exit;
  FSyncToolName := AName; FSyncToolData := AData; Synchronize(@SyncToolExecuting);
end;
procedure TAgentWorkerThread.HandleToolCompleted(const AName, AData: string);
begin
  if Terminated then Exit;
  FSyncToolName := AName; FSyncToolData := AData; Synchronize(@SyncToolCompleted);
end;

procedure TAgentWorkerThread.Execute;
var Context: TToolContext;
begin
  Context := Default(TToolContext);
  Context.Mode := FRunMode; Context.ProjectRoot := FProjectRoot;
  Context.Session := FAgent.ToolSession; Context.IsCancelled := @ToolIsCancelled;
  Context.OnFileChanged := @HandleFileChanged;
  try
    FSyncSuccess := FAgent.RunPrompt(FPrompt, Context, True, @HandleSSEChunk,
      @HandleToolExecuting, @HandleToolCompleted, @HandleProgress, FSyncFinalText);
  except on E: Exception do
    begin FSyncSuccess := False; FSyncFinalText := 'Agent error: ' + E.Message; end;
  end;
  Synchronize(@SyncCompleted);
end;

end.
