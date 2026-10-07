unit uAgentCore;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uAgentTypes, uAgentHistory, uAgentConfig, uLLMClient, uToolBase, uToolFileOps, uToolLocal, uAgentContext;

type
  TToolExecutionEvent = procedure(const AToolName, AToolArgs: string) of object;
  TToolCompletedEvent = procedure(const AToolName, AToolResult: string) of object;

  TAgentCore = class
  private
    FEstimator: TContextEstimator;
    FCompactor: TConversationCompactor;
    FConfig: TAgentConfig;
    FHistory: TAgentHistory;
    FLLMClient: TLLMClient;
    FToolSession: TToolSession;
    FMode: TAgentMode;
    FStatus: TAgentStatus;
    FOnToolExecuting: TToolExecutionEvent;
    FOnToolCompleted: TToolCompletedEvent;
    FOnFileChanged: TToolFileChanged;
    procedure SetContextEstimator(AValue: TContextEstimator);
    procedure SetCompactor(AValue: TConversationCompactor);
  public
    constructor Create;
    destructor Destroy; override;

    function SendUserPrompt(const APrompt: string; out AResponse: string): Boolean;
    function RunPrompt(const APrompt: string; const AContext: TToolContext;
      AStreaming: Boolean; AOnChunk: TSSEChunkEvent;
      AExecuting: TToolExecutionEvent; ACompleted: TToolCompletedEvent;
      AProgress: TContextProgress; out AResponse: string): Boolean;
    procedure ClearHistory;

    { Agent owns replacements. Set only while idle. }
    property ContextEstimator: TContextEstimator read FEstimator write SetContextEstimator;
    property Compactor: TConversationCompactor read FCompactor write SetCompactor;
    property ToolSession: TToolSession read FToolSession;
    property Config: TAgentConfig read FConfig;
    property History: TAgentHistory read FHistory;
    property Mode: TAgentMode read FMode write FMode;
    property Status: TAgentStatus read FStatus write FStatus;
    property OnToolExecuting: TToolExecutionEvent read FOnToolExecuting write FOnToolExecuting;
    property OnToolCompleted: TToolCompletedEvent read FOnToolCompleted write FOnToolCompleted;
    property OnFileChanged: TToolFileChanged read FOnFileChanged write FOnFileChanged;
  end;

implementation

procedure TAgentCore.SetContextEstimator(AValue: TContextEstimator);
begin
  if (FStatus <> asIdle) or (AValue = nil) then raise Exception.Create('Estimator requires an idle agent and a non-nil value');
  if FEstimator = AValue then Exit;
  FEstimator.Free; FEstimator := AValue;
end;

procedure TAgentCore.SetCompactor(AValue: TConversationCompactor);
begin
  if (FStatus <> asIdle) or (AValue = nil) then raise Exception.Create('Compactor requires an idle agent and a non-nil value');
  if FCompactor = AValue then Exit;
  FCompactor.Free; FCompactor := AValue;
end;

constructor TAgentCore.Create;
begin
  inherited Create;
  FEstimator := TApproximateContextEstimator.Create;
  FCompactor := TEngineeringCompactor.Create;
  FConfig := GetAgentConfig;
  FHistory := TAgentHistory.Create;
  FToolSession := TToolSession.Create;
  FLLMClient := TLLMClient.Create(FConfig);
  FMode := amAsk;
  FStatus := asIdle;
  FOnToolExecuting := nil;
  FOnToolCompleted := nil;
end;

destructor TAgentCore.Destroy;
begin
  FCompactor.Free; FEstimator.Free;
  FLLMClient.Free;
  FHistory.Free;
  FToolSession.Free;
  inherited Destroy;
end;

function TAgentCore.SendUserPrompt(const APrompt: string; out AResponse: string): Boolean;
var Context: TToolContext;
begin
  Context := Default(TToolContext); Context.Mode := FMode;
  Context.ProjectRoot := GetEffectiveProjectDir; Context.Session := FToolSession;
  Context.OnFileChanged := FOnFileChanged;
  Result := RunPrompt(APrompt, Context, False, nil, FOnToolExecuting, FOnToolCompleted, nil, AResponse);
end;

function TAgentCore.RunPrompt(const APrompt: string; const AContext: TToolContext;
  AStreaming: Boolean; AOnChunk: TSSEChunkEvent;
  AExecuting: TToolExecutionEvent; ACompleted: TToolCompletedEvent;
  AProgress: TContextProgress; out AResponse: string): Boolean;
var Iter, I, J: Integer; Response, Stored: TChatMessage;
  ToolName, ToolArgs, ToolResult, Failure: string; Call: TAgentToolCall;
  function Cancelled: Boolean;
  begin Result := Assigned(AContext.IsCancelled) and AContext.IsCancelled(); end;
begin
  Result := False; AResponse := ''; FStatus := asThinking;
  try
    try
      if not FHistory.PromptAdmissionAllowed(FConfig.ContextBudget, FConfig.RecentTurns) then
      begin AResponse := 'Context remains blocked. Increase the input budget or clear chat.'; Exit; end;
      { Changing settings must actually make the existing context usable before admitting another prompt. }
      if not FCompactor.Prepare(FHistory, FLLMClient, FConfig, AContext.Mode,
        FEstimator, AContext.IsCancelled, AProgress, AResponse, AContext.ProjectRoot) then Exit;
      if Cancelled then begin AResponse := 'Request cancelled by user.'; Exit; end;
      FHistory.AddMessage(mrUser, APrompt);
      for Iter := 1 to 50 do
      begin
        if Cancelled then begin AResponse := 'Request cancelled by user.'; Exit; end;
        if not FCompactor.Prepare(FHistory, FLLMClient, FConfig, AContext.Mode,
          FEstimator, AContext.IsCancelled, AProgress, AResponse, AContext.ProjectRoot) then Exit;
        if Assigned(AProgress) then AProgress('Thinking...');
        if not FLLMClient.SendResponse(FHistory, AContext.Mode, AStreaming, True,
          AOnChunk, Response, AResponse, AContext.ProjectRoot, AContext.IsCancelled) then Exit;
        try
          if Cancelled then begin AResponse := 'Request cancelled by user.'; Exit; end;
          AResponse := Response.Content;
          if (Response.ToolCalls.Count = 0) and
            FallbackExtractToolCall(Response.Content, ToolName, ToolArgs) then
          begin
            Response.AddToolCall('', ToolName, ToolArgs);
            FLLMClient.Adapter.ValidateResponse(Response);
          end;
          Stored := FHistory.AppendAssistant(Response);
        finally Response.Free; end;
        if Stored.ToolCalls.Count = 0 then Exit(True);
        Failure := '';
        for I := 0 to Stored.ToolCalls.Count - 1 do
        begin
          Call := Stored.ToolCalls[I];
          if Cancelled then Failure := 'Request cancelled by user.';
          if (Failure = '') and not ToolAllowedForMode(AContext.Mode, Call.Name) then
            Failure := 'Tool call rejected: ' + Call.Name + ' is unavailable in ' + ModeToString(AContext.Mode) + ' mode.';
          if Failure <> '' then
          begin
            for J := I to Stored.ToolCalls.Count - 1 do
              FHistory.AddToolResult(Stored.ToolCalls[J].Id, Stored.ToolCalls[J].Name, ToolError(Failure));
            AResponse := Failure; Exit;
          end;
          FStatus := asCallingTool;
          try
            if Assigned(AExecuting) then AExecuting(Call.Name, Call.Arguments);
            ToolResult := GetToolRegistry.ExecuteTool(Call.Name, Call.Arguments, AContext);
          except on E: Exception do ToolResult := ToolError(E.Message); end;
          { Commit before callbacks; callback failure must never lose an executed result. }
          FHistory.AddToolResult(Call.Id, Call.Name, ToolResult);
          if Assigned(ACompleted) then
            try ACompleted(Call.Name, ToolResult); except on E: Exception do Failure := E.Message; end;
          if Failure <> '' then
          begin
            for J := I + 1 to Stored.ToolCalls.Count - 1 do
              FHistory.AddToolResult(Stored.ToolCalls[J].Id, Stored.ToolCalls[J].Name, ToolError(Failure));
            AResponse := Failure; Exit;
          end;
        end;
        FStatus := asThinking;
      end;
      AResponse := 'Run incomplete: tool iteration limit reached.';
    except on E: Exception do AResponse := 'Agent error: ' + E.Message;
    end;
  finally FStatus := asIdle; end;
end;

procedure TAgentCore.ClearHistory;
begin
  FHistory.Clear;
  FToolSession.Clear;
end;

end.
