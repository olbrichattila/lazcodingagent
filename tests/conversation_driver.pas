program conversation_driver;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Classes, SysUtils, fpjson, jsonparser,
  uAgentTypes, uAgentCore, uAgentThread, uLLMAdapter, uToolBase;
type
  TObserver = class
    Done, Success, CancelTools, CancelSummary, Cancelled: Boolean;
    Worker: TAgentWorkerThread;
    Text: string;
    procedure Completed(ASuccess: Boolean; const AText: string);
    procedure ToolCompleted(const AName, AResult: string);
    procedure Progress(const AText: string);
    function IsCancelled: Boolean;
  end;
procedure TObserver.Completed(ASuccess: Boolean; const AText: string);
begin Done := True; Success := ASuccess; Text := AText; end;
procedure TObserver.ToolCompleted(const AName, AResult: string);
begin
  if CancelTools then begin Cancelled := True; if Worker <> nil then Worker.Terminate; end;
end;
procedure TObserver.Progress(const AText: string);
begin
  if CancelSummary and (Pos('Summarizing', AText) > 0) then
  begin Cancelled := True; if Worker <> nil then Worker.Terminate; end;
end;
function TObserver.IsCancelled: Boolean;
begin Result := Cancelled; end;
var Agent: TAgentCore; Observer: TObserver; Worker: TAgentWorkerThread;
  Steps: TJSONData; Step, Output: TJSONObject; Results: TJSONArray;
  Context: TToolContext;
  Adapter: TChatCompletionsAdapter; I: Integer; Prompt, Response, StepsText: string;
  StepsFile: TFileStream; Success: Boolean;
begin
  SetEffectiveProjectDir(ParamStr(1)); Agent := TAgentCore.Create;
  Observer := TObserver.Create; Adapter := TChatCompletionsAdapter.Create;
  StepsFile := TFileStream.Create(ParamStr(4), fmOpenRead or fmShareDenyWrite);
  try
    SetLength(StepsText, StepsFile.Size);
    if Length(StepsText) > 0 then StepsFile.ReadBuffer(StepsText[1], Length(StepsText));
  finally StepsFile.Free; end;
  Steps := GetJSON(StepsText); Results := TJSONArray.Create;
  try
    Agent.Config.Provider := lpCustom; Agent.Config.EndpointURL := ParamStr(2);
    Agent.Config.APIKey := ''; Agent.Config.ModelName := 'fixture'; Agent.Mode := amAsk;
    for I := 0 to Steps.Count - 1 do
    begin
      Step := TJSONArray(Steps).Objects[I];
      if Step.Get('clear', False) then Agent.ClearHistory;
      if Step.Find('summary') <> nil then Agent.History.Summary := Step.Get('summary', '');
      Agent.Config.ContextBudget := Step.Get('budget', Agent.Config.ContextBudget);
      Agent.Config.RecentTurns := Step.Get('recent', Agent.Config.RecentTurns);
      Prompt := Step.Get('prompt', '');
      Observer.Cancelled := False; Observer.Worker := nil;
      Observer.CancelTools := Step.Get('cancel_tools', False);
      Observer.CancelSummary := Step.Get('cancel_summary', False);
      if ParamStr(3) = 'thread' then
      begin
        Observer.Done := False;
        Worker := TAgentWorkerThread.Create(Agent, Prompt, nil, nil, @Observer.ToolCompleted, @Observer.Completed, nil, @Observer.Progress);
        Observer.Worker := Worker;
        Worker.FreeOnTerminate := False;
        try
          Worker.Start;
          while not Observer.Done do CheckSynchronize(10);
          Worker.WaitFor; Success := Observer.Success; Response := Observer.Text;
        finally Worker.Free; end;
      end
      else if Observer.CancelTools or Observer.CancelSummary then
      begin
        Context := Default(TToolContext); Context.Mode := Agent.Mode;
        Context.ProjectRoot := GetEffectiveProjectDir; Context.Session := Agent.ToolSession;
        Context.IsCancelled := @Observer.IsCancelled;
        Success := Agent.RunPrompt(Prompt, Context, False, nil, nil, @Observer.ToolCompleted, @Observer.Progress, Response);
      end
      else Success := Agent.SendUserPrompt(Prompt, Response);
      Output := TJSONObject.Create(['success', Success, 'response', Response,
        'summary', Agent.History.Summary, 'count', Agent.History.Count,
        'idle', Agent.Status = asIdle]);
      Output.Add('messages', Adapter.Messages(Agent.History, ''));
      Results.Add(Output);
    end;
    WriteLn(Results.AsJSON);
  finally Results.Free; Steps.Free; Adapter.Free; Observer.Free; Agent.Free; end;
end.
