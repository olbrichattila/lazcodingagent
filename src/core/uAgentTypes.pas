unit uAgentTypes;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl;

type
  { Agent Execution Modes }
  TAgentMode = (
    amAsk,    { Direct Q&A and code advice without file changes }
    amPlan,   { Step-by-step roadmap and architecture decomposition }
    amAgent   { Autonomous multi-step execution with tool calling }
  );

  { LLM Provider Presets }
  TLLMProvider = (
    lpOpenAI,      { Official OpenAI API }
    lpNousPortal,  { Nous Research Portal }
    lpOpenRouter,  { OpenRouter API Aggregator }
    lpOllama,      { Local Ollama server }
    lpCustom       { User-defined endpoint }
  );

  { Message Roles }
  TMessageRole = (
    mrSystem,
    mrUser,
    mrAssistant,
    mrTool
  );

  { Status of Agent Run }
  TAgentStatus = (
    asIdle,
    asThinking,
    asCallingTool,
    asWaitingApproval,
    asError
  );

  TAgentToolCall = class
  public
    Id, Name, Arguments: string;
    StreamIndex: Integer;
    function Clone: TAgentToolCall;
  end;
  TAgentToolCalls = specialize TFPGObjectList<TAgentToolCall>;

  { Single Chat Message }
  TChatMessage = class
  private
    FToolCalls: TAgentToolCalls;
    FRole: TMessageRole;
    FContent: string;
    FTimestamp: TDateTime;
    FToolCallId: string;
    FToolCallName: string;
    FToolCallArgs: string;
  public
    constructor Create(ARole: TMessageRole; const AContent: string);
    destructor Destroy; override;
    function Clone: TChatMessage;
    function AddToolCall(const AId, AName, AArguments: string): TAgentToolCall;
    property ToolCalls: TAgentToolCalls read FToolCalls;
    property Role: TMessageRole read FRole write FRole;
    property Content: string read FContent write FContent;
    property Timestamp: TDateTime read FTimestamp write FTimestamp;
    property ToolCallId: string read FToolCallId write FToolCallId;
    property ToolCallName: string read FToolCallName write FToolCallName;
    property ToolCallArgs: string read FToolCallArgs write FToolCallArgs;
  end;

function ModeToString(AMode: TAgentMode): string;
function StringToMode(const AStr: string): TAgentMode;
function RoleToString(ARole: TMessageRole): string;

function ProviderToString(AProvider: TLLMProvider): string;
function StringToProvider(const AStr: string): TLLMProvider;
function GetDefaultEndpoint(AProvider: TLLMProvider): string;
function GetDefaultModel(AProvider: TLLMProvider): string;
procedure GetDefaultModelList(AProvider: TLLMProvider; AList: TStrings);

implementation

function ModeToString(AMode: TAgentMode): string;
begin
  case AMode of
    amAsk:   Result := 'Ask';
    amPlan:  Result := 'Plan';
    amAgent: Result := 'Agent';
  end;
end;

function StringToMode(const AStr: string): TAgentMode;
begin
  if SameText(AStr, 'Plan') then
    Result := amPlan
  else if SameText(AStr, 'Agent') then
    Result := amAgent
  else
    Result := amAsk;
end;

function RoleToString(ARole: TMessageRole): string;
begin
  case ARole of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool';
  end;
end;

function ProviderToString(AProvider: TLLMProvider): string;
begin
  case AProvider of
    lpOpenAI:     Result := 'OpenAI';
    lpNousPortal: Result := 'Nous Portal';
    lpOpenRouter: Result := 'OpenRouter';
    lpOllama:     Result := 'Ollama (Local)';
    lpCustom:     Result := 'Custom';
  end;
end;

function StringToProvider(const AStr: string): TLLMProvider;
begin
  if SameText(AStr, 'Nous Portal') or SameText(AStr, 'Nous') or SameText(AStr, 'NousPortal') then
    Result := lpNousPortal
  else if SameText(AStr, 'OpenRouter') then
    Result := lpOpenRouter
  else if SameText(AStr, 'Ollama (Local)') or SameText(AStr, 'Ollama') then
    Result := lpOllama
  else if SameText(AStr, 'Custom') then
    Result := lpCustom
  else
    Result := lpOpenAI;
end;

function GetDefaultEndpoint(AProvider: TLLMProvider): string;
begin
  case AProvider of
    lpOpenAI:     Result := 'https://api.openai.com/v1/chat/completions';
    lpNousPortal: Result := 'https://inference-api.nousresearch.com/v1/chat/completions';
    lpOpenRouter: Result := 'https://openrouter.ai/api/v1/chat/completions';
    lpOllama:     Result := 'http://localhost:11434/v1/chat/completions';
    lpCustom:     Result := 'http://localhost:8000/v1/chat/completions';
  end;
end;

function GetDefaultModel(AProvider: TLLMProvider): string;
begin
  case AProvider of
    lpOpenAI:     Result := 'gpt-4o';
    lpNousPortal: Result := 'google/gemini-3.7-flash';
    lpOpenRouter: Result := 'google/gemini-3.7-flash';
    lpOllama:     Result := 'qwen2.5-coder:latest';
    lpCustom:     Result := 'default-model';
  end;
end;

procedure GetDefaultModelList(AProvider: TLLMProvider; AList: TStrings);
begin
  if not Assigned(AList) then Exit;
  AList.Clear;

  case AProvider of
    lpOpenAI:
    begin
      AList.Add('gpt-4o');
      AList.Add('gpt-4o-mini');
      AList.Add('o3-mini');
      AList.Add('o1');
      AList.Add('gpt-4-turbo');
    end;
    lpNousPortal:
    begin
      AList.Add('google/gemini-3.7-flash');
      AList.Add('deepseek/deepseek-r1');
      AList.Add('deepseek/deepseek-v4-flash');
      AList.Add('openai/gpt-4o');
      AList.Add('openai/gpt-4o-mini');
      AList.Add('openai/o3-mini');
      AList.Add('anthropic/claude-sonnet-4.5');
      AList.Add('qwen/qwen-2.5-72b-instruct');
      AList.Add('meta-llama/llama-3.3-70b-instruct');
    end;
    lpOpenRouter:
    begin
      AList.Add('google/gemini-3.7-flash');
      AList.Add('deepseek/deepseek-r1');
      AList.Add('anthropic/claude-3.7-sonnet');
      AList.Add('openai/gpt-4o');
      AList.Add('meta-llama/llama-3.3-70b-instruct');
    end;
    lpOllama:
    begin
      AList.Add('qwen2.5-coder:latest');
      AList.Add('qwen2.5-coder:7b');
      AList.Add('deepseek-coder-v2:latest');
      AList.Add('codellama:latest');
      AList.Add('llama3.1:latest');
    end;
    lpCustom:
    begin
      AList.Add('default-model');
    end;
  end;
end;

{ TChatMessage }

constructor TChatMessage.Create(ARole: TMessageRole; const AContent: string);
begin
  inherited Create;
  FToolCalls := TAgentToolCalls.Create(True);
  FRole := ARole;
  FContent := AContent;
  FTimestamp := Now;
  FToolCallName := '';
  FToolCallArgs := '';
end;

function TAgentToolCall.Clone: TAgentToolCall;
begin
  Result := TAgentToolCall.Create;
  Result.Id := Id; Result.Name := Name; Result.Arguments := Arguments;
  Result.StreamIndex := StreamIndex;
end;

destructor TChatMessage.Destroy;
begin
  FToolCalls.Free;
  inherited Destroy;
end;

function TChatMessage.AddToolCall(const AId, AName, AArguments: string): TAgentToolCall;
begin
  Result := TAgentToolCall.Create;
  Result.Id := AId; Result.Name := AName; Result.Arguments := AArguments;
  FToolCalls.Add(Result);
end;

function TChatMessage.Clone: TChatMessage;
var I: Integer;
begin
  Result := TChatMessage.Create(Role, Content);
  try
    Result.Timestamp := Timestamp;
    Result.ToolCallId := ToolCallId;
    Result.ToolCallName := ToolCallName;
    Result.ToolCallArgs := ToolCallArgs;
    for I := 0 to ToolCalls.Count - 1 do Result.ToolCalls.Add(ToolCalls[I].Clone);
  except Result.Free; raise; end;
end;

end.
