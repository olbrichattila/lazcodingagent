program test_sse_tool_names;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, fpjson, uAgentTypes, uToolBase, uToolFileOps, uToolLocal, uLLMClient;

procedure AssertEqual(const ALabel, AExpected, AActual: string);
begin
  if AExpected <> AActual then
    raise Exception.CreateFmt('%s: expected "%s", got "%s"',
      [ALabel, AExpected, AActual]);
end;

procedure AssertTrue(const ALabel: string; AValue: Boolean);
begin
  if not AValue then
    raise Exception.Create(ALabel + ': expected true');
end;

procedure EmitToolDelta(AStream: TSSEStream; const AName, AArguments: string);
var
  Event, Choice, Delta, ToolCall, Func: TJSONObject;
  Choices, ToolCalls: TJSONArray;
  Data: string;
begin
  Event := TJSONObject.Create;
  try
    Choices := TJSONArray.Create;
    Choice := TJSONObject.Create;
    Delta := TJSONObject.Create;
    ToolCalls := TJSONArray.Create;
    ToolCall := TJSONObject.Create;
    Func := TJSONObject.Create;

    Func.Add('name', AName);
    Func.Add('arguments', AArguments);
    ToolCall.Add('index', 0);
    ToolCall.Add('id', 'call_1');
    ToolCall.Add('function', Func);
    ToolCalls.Add(ToolCall);
    Delta.Add('tool_calls', ToolCalls);
    Choice.Add('delta', Delta);
    Choices.Add(Choice);
    Event.Add('choices', Choices);

    Data := 'data: ' + Event.AsJSON + LineEnding;
    AStream.Write(Data[1], Length(Data));
  finally
    Event.Free;
  end;
end;

procedure TestRepeatedCompleteName;
var
  Stream: TSSEStream;
begin
  Stream := TSSEStream.Create(nil);
  try
    EmitToolDelta(Stream, 'read_file', '{');
    EmitToolDelta(Stream, 'read_file', '"path":');
    EmitToolDelta(Stream, 'read_file', '"unit1.pas"}');
    AssertEqual('Repeated tool name', 'read_file', Stream.AccumulatedToolName);
    AssertEqual('Split arguments', '{"path":"unit1.pas"}', Stream.AccumulatedToolArgs);
    AssertTrue('Tool call detected', Stream.HasToolCall);
  finally
    Stream.Free;
  end;
end;

procedure TestSplitNameAndArguments;
var
  Stream: TSSEStream;
begin
  Stream := TSSEStream.Create(nil);
  try
    EmitToolDelta(Stream, 'read_', '{"path":');
    EmitToolDelta(Stream, 'file', '"unit1.pas"}');
    AssertEqual('Split tool name', 'read_file', Stream.AccumulatedToolName);
    AssertEqual('Split arguments', '{"path":"unit1.pas"}', Stream.AccumulatedToolArgs);
  finally
    Stream.Free;
  end;
end;

procedure TestCumulativeNameSnapshot;
var
  Stream: TSSEStream;
begin
  Stream := TSSEStream.Create(nil);
  try
    EmitToolDelta(Stream, 'read_', '{');
    EmitToolDelta(Stream, 'read_file', '"path":');
    EmitToolDelta(Stream, 'read_file', '"unit1.pas"}');
    AssertEqual('Cumulative tool name', 'read_file', Stream.AccumulatedToolName);
    AssertEqual('Cumulative arguments', '{"path":"unit1.pas"}', Stream.AccumulatedToolArgs);
  finally
    Stream.Free;
  end;
end;

procedure TestPlanModeToolPermissions;
begin
  AssertTrue('Plan can read files', ToolAllowedForMode(amPlan, 'read_file'));
  AssertTrue('Plan can save its plan', ToolAllowedForMode(amPlan, 'create_plan_file'));
  if ToolAllowedForMode(amPlan, 'write_file') then
    raise Exception.Create('Plan mode must reject write_file');
end;

begin
  TestRepeatedCompleteName;
  TestSplitNameAndArguments;
  TestCumulativeNameSnapshot;
  TestPlanModeToolPermissions;
  WriteLn('SSE tool-name tests passed.');
end.
