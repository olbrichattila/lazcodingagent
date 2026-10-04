# Boilerplate Implementation Plan

## 1. Project Structure & Architecture

To support both **direct IDE integration** (as a Lazarus Package `.lpk`) and **rapid development/debugging** (as a standalone application `.lpi`), the boilerplate will be structured as follows:

```
CodingAgent/
├── README.md
├── plan.md
├── boilerplate_plan.md
├── Makefile                  # Build helper using lazbuild / fpc
├── src/
│   ├── core/                 # Core engine & agent loop
│   │   ├── uAgentCore.pas    # Agent orchestrator and state engine
│   │   ├── uAgentTypes.pas   # Shared data structures, enums (Modes, Roles, Status)
│   │   ├── uAgentConfig.pas  # Settings / API keys persistence
│   │   └── uAgentHistory.pas # Conversation and context manager
│   ├── llm/                  # LLM communication layer
│   │   ├── uLLMClient.pas    # Base HTTP/REST client for LLM API
│   │   ├── uLLMOpenAI.pas    # OpenAI / Ollama / Compatible endpoints
│   │   └── uLLMParser.pas    # JSON parsing and streaming response handlers
│   ├── tools/                # Tooling & execution
│   │   ├── uToolBase.pas     # Base tool definition interface
│   │   ├── uToolFileOps.pas  # Read, write, patch file tools
│   │   └── uToolCompiler.pas # lazbuild / fpc runner & error diagnostic parser
│   ├── ui/                   # GUI Components (LCL)
│   │   ├── uFrmChat.pas      # Main Chat Window form (dockable or standalone)
│   │   ├── uFrmChat.lfm      # Form layout definition
│   │   ├── uFrmSettings.pas  # Configuration dialog form
│   │   ├── uFrmSettings.lfm  # Settings layout
│   │   └── uChatControls.pas # Custom chat message rendering / formatting
│   └── ide/                  # Lazarus IDE Registration
│       ├── uAgentPlugin.pas  # IDE integration & menu/docking registration
│       └── lazaruscodingagent.pas # Package main unit
├── package/
│   └── lazaruscodingagent.lpk # Lazarus IDE Package definition
└── app/
    ├── standalone_chat.lpr   # Standalone runner program for UI testing
    └── standalone_chat.lpi   # Standalone Lazarus project file
```

---

## 2. Core Dependencies & Packages

- **FCL (Free Component Library)**:
  - `fphttpclient` / `opensslsockets` (or `synapse` / `libcurl`) for HTTPS requests to LLM APIs.
  - `fpjson`, `jsonparser` for request/response serialization and tool call parsing.
  - `classes`, `sysutils`, `process` for subprocess execution (`lazbuild`, `fpc`).
- **LCL (Lazarus Component Library)**:
  - `Forms`, `Controls`, `StdCtrls`, `ExtCtrls`, `ComCtrls`, `Graphics`.
  - `SynEdit` (built-in Lazarus editor component) for syntax-highlighted code blocks.
- **IDEIntf (when building IDE package)**:
  - `LazIDEIntf`, `MenuIntf`, `IDEDialogs`, `SrcEditorIntf` for deep IDE hooks.

---

## 3. Implementation Steps for the Boilerplate

### Step 1: Base Types & Interfaces (`src/core/uAgentTypes.pas`)
- Define `TAgentMode = (amAsk, amPlan, amAgent)`.
- Define `TMessageRole = (mrSystem, mrUser, mrAssistant, mrTool)`.
- Define `TChatMessage` record/class with timestamp, role, content, tool calls, and status.

### Step 2: Standalone Shell & Project Files
- Create `lazaruscodingagent.lpk` (IDE package).
- Create `standalone_chat.lpr` and `standalone_chat.lpi` (test runner).
- Verify compilation with `lazbuild` / `fpc`.

### Step 3: Main Chat Window GUI (`src/ui/uFrmChat.pas` + `.lfm`)
- Header: Mode selector (RadioGroup/ComboBox: **Ask**, **Plan**, **Agent**), Model selector, Settings button.
- Body: Scrollable message history with role distinctions and formatted blocks.
- Footer: Multiline input memo, Send button, Stop/Cancel button, Token/Status indicator.

### Step 4: Configuration Subsystem (`src/core/uAgentConfig.pas`)
- Storage for API keys, default endpoint URLs, default model names, and system prompts.
- INI/JSON-based config file in `~/.config/lazarus-coding-agent/` or standard config path.

### Step 5: LLM Client Mock/Stub (`src/llm/uLLMClient.pas`)
- Abstract client class for asynchronous or threaded API execution.
- Base response handler verifying HTTP 200, parsing JSON payload, and returning chat chunks to the UI.
