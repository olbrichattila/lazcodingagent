program agent_driver;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Classes, SysUtils, fpjson,
  uAgentTypes, uAgentCore, uAgentThread, uToolBase;
type
  TObserver = class
    Done, Success: Boolean;
    Response: string;
    Results, Changes: TJSONArray;
    procedure FileChanged(const Path: string);
    procedure Completed(ASuccess: Boolean; const AText: string);
    procedure ToolCompleted(const AName, AResult: string);
  end;
procedure TObserver.Completed(ASuccess: Boolean; const AText: string);
begin Done := True; Success := ASuccess; Response := AText; end;
procedure TObserver.ToolCompleted(const AName, AResult: string);
begin Results.Add(TJSONObject.Create(['name', AName, 'result', ParseToolArgs(AResult)])); end;
procedure TObserver.FileChanged(const Path: string);
begin
  if GetCurrentThreadID <> MainThreadID then raise Exception.Create('Notification not synchronized');
  Changes.Add(TJSONObject.Create(['path', Path, 'completed_tools', Results.Count]));
end;
var Agent: TAgentCore; Observer: TObserver; Worker: TAgentWorkerThread; O: TJSONObject;
begin
  SetEffectiveProjectDir(ParamStr(1)); Agent := TAgentCore.Create; Observer := TObserver.Create;
  Observer.Results := TJSONArray.Create;
  Observer.Changes := TJSONArray.Create;
  try
    Agent.Config.Provider := lpCustom;
    Agent.Config.EndpointURL := ParamStr(2); Agent.Config.APIKey := ''; Agent.Config.ModelName := 'fixture';
    Agent.Mode := StringToMode(ParamStr(3));
    if ParamStr(4) = 'thread' then
    begin
      Worker := TAgentWorkerThread.Create(Agent, ParamStr(5), nil, nil, @Observer.ToolCompleted,
        @Observer.Completed, @Observer.FileChanged);
      Worker.FreeOnTerminate := False;
      try
        Worker.Start;
        while not Observer.Done do CheckSynchronize(10);
        Worker.WaitFor;
      finally Worker.Free; end;
    end
    else
    begin
      Agent.OnToolCompleted := @Observer.ToolCompleted;
      Agent.OnFileChanged := @Observer.FileChanged;
      Observer.Success := Agent.SendUserPrompt(ParamStr(5), Observer.Response);
    end;
    O := TJSONObject.Create(['success', Observer.Success, 'response', Observer.Response]);
    O.Add('results', Observer.Results.Clone); O.Add('tasks', Agent.ToolSession.Tasks.Clone);
    O.Add('changes', Observer.Changes.Clone);
    Agent.ClearHistory; O.Add('tasks_after_clear', Agent.ToolSession.Tasks.Clone);
    try WriteLn(O.AsJSON); finally O.Free; end;
  finally Observer.Changes.Free; Observer.Results.Free; Observer.Free; Agent.Free; end;
end.
