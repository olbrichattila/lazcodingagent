# Lazarus Coding Agent

An autonomous coding agent extension for Free Lazarus IDE.

## Overview

The Lazarus Coding Agent provides intelligent code assistance and autonomous development workflows integrated directly into Free Lazarus:

- **Integrated Chat Window**: Dockable and toggleable GUI window within the Lazarus IDE layout.
- **Initial Modes**:
  - **Ask Mode**: Conversational Q&A, code explanations, and targeted syntax guidance without modifying files.
  - **Plan Mode**: High-level task decomposition, architecture planning, and step-by-step roadmaps without immediate execution.
  - **Agent Mode**: Autonomous execution of multi-step coding, refactoring, and debugging tasks with tool use and file system interactions.
- **Future Roadmap**:
  - **Multi-Agent Architecture**: Coordinated sub-agents specialized in planning, coding, reviewing, and testing.
  - **Knowledge Base (RAG & Docs)**: Local codebase indexing, Free Pascal / Lazarus component documentation retrieval, and semantic search.

---

## Adding the Agent to Lazarus IDE

### Option 1: Using the Automated Build Script (Recommended)
Run the automated installation script from the project root:

```bash
./build.sh install
```

On native Windows, use the batch equivalent from a Lazarus/Free Pascal command
prompt:

```bat
build.bat install
```

`build.bat` uses the Lazarus installation already available through `PATH`, or
the directory supplied in `LAZARUS_DIR`. Set `LCL_WS` only when a non-default
LCL widgetset is required; native Windows builds default to `win32` for the
test runners.

On macOS, install native Free Pascal and Lazarus builds for your Mac
architecture, along with Xcode Command Line Tools. Install the Lazarus
`TurboPowerIPro` and `Printer4Lazarus` packages. The build scripts select the
Cocoa widgetset by default; set `LCL_WS` if your Lazarus installation uses a
different widgetset. If automatic Lazarus discovery does not find the source
directory, set `LAZARUS_DIR` to the directory containing `components/lazutils`.
Then build both targets with:

```bash
./build.sh all
```

Build separately on Apple Silicon and Intel to produce binaries for each
architecture. This project does not create a signed or notarized app bundle.

This registers `package/lazaruscodingagent.lpk` and invokes `lazbuild` to recompile and restart the Lazarus IDE.

---

### Option 2: Installing via Lazarus GUI Package Manager
1. Launch **Free Lazarus IDE**.
2. From the main menu, navigate to **Package** -> **Open Package File (.lpk)...**
3. Browse to and select `package/lazaruscodingagent.lpk`.
4. In the Package Editor window that appears:
   - Click **Compile** to verify package compilation.
   - Click **Use** -> **Install**.
5. Lazarus will prompt: *"Do you want to rebuild Lazarus now?"* Click **Yes**.
6. Lazarus will automatically recompile itself with the Coding Agent package installed and restart.

---

### Option 3: Manual Command Line Installation (`lazbuild`)
```bash
# Register package with the IDE configuration
lazbuild --add-package package/lazaruscodingagent.lpk

# Rebuild Lazarus IDE binary
lazbuild --build-ide=
```

---

## IDE Integration & Controls

Once installed in Lazarus, the Coding Agent provides multiple access points:

### 1. Toggle On / Off Shortcut
- Press **`Ctrl+Alt+A`** anywhere in the IDE to instantly toggle the Coding Agent chat window between visible and hidden.

### 2. Main Menu Option
- Navigate to **View** -> **Coding Agent Chat** to toggle the chat window.

### 3. Toolbar Button
- The Coding Agent registers a dedicated button on the main Lazarus IDE toolbar.
- Clicking the toolbar button toggles the agent chat window on and off.
- You can position or customize the button via **Tools** -> **Options** -> **Environment** -> **Toolbar**.

### 4. Docking into IDE Workspace
- The chat window integrates with Lazarus docking (`IDEWindowIntf` / `AnchorDocking`).
- You can dock the chat panel beside the Source Editor, under the Messages/Compiler window, or keep it floating as a utility tool window.

---

## Standalone Development & Testing

For fast development and UI tweaking without rebuilding the entire Lazarus IDE:

```bash
# Build the standalone chat executable
./build.sh app

# Run the standalone application
./app/bin/standalone_chat
```

The chat and plan preview render Markdown through Lazarus' `TurboPowerIPro`
HTML panel package. Ensure `TurboPowerIPro` (and its `Printer4Lazarus`
dependency) is installed in the Lazarus environment used to build the IDE
package or standalone application.

---

## Configuration & Usage

The chat uses Windows WinHTTP (with the Windows Schannel TLS implementation) on
Windows. Linux and macOS use Free Pascal's `fphttpclient` and `opensslsockets`.
For HTTPS providers on macOS, install an OpenSSL runtime compatible with your
Free Pascal build and make its libraries discoverable to the app. With
Homebrew OpenSSL 3, for example:

```bash
brew install openssl@3
OPENSSL_PREFIX="$(brew --prefix openssl@3)"
export PATH="$OPENSSL_PREFIX/bin:$PATH"
export DYLD_LIBRARY_PATH="$OPENSSL_PREFIX/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
```

HTTP-only endpoints, including the local test fixtures, do not exercise TLS.

1. **Configure LLM & Models in Settings (⚙)**:
   - Click the gear icon (**⚙**) in the chat toolbar to open the tabbed Settings dialog:
     - **Providers & Models Tab**:
       - Select an **LLM Provider** (OpenAI, Nous Portal, OpenRouter, Ollama, Custom).
       - Enter your **API Key** and customize the **Endpoint URL**.
       - **Manage Models**: Add new models (`+ Add`), update (`✎ Update`), or delete (`- Remove`) from your custom model list.
       - **Browse Server**: Click `🌐 Browse Server...` to fetch and search the live model list directly from your provider.
       - Choose which model is active by default.
     - **Agents Tab**: Structure for future multi-agent orchestrations.
     - **Bots & Knowledge (RAG) Tab**: Structure for future vector indexing and RAG documentation search.

2. **Select Mode, Model & Interact in Chat**:
   - **Mode Selector**: Choose between **Ask**, **Plan**, and **Agent** modes.
   - **Model Selector Dropdown**: Instantly switch the active model directly from the chat toolbar (`Model: [Dropdown]`).
   - **Help Dialog (?)**: Click the **?** icon for an instant guide to modes and shortcuts.
   - **Clear Chat (🗑)**: Clears conversation history.
   - Press **`Ctrl+Enter`** in the input prompt to quickly send messages.

Completed plans open the **Implementation Plan** window automatically. Plan mode
can ask clarifying questions in chat first. A completed plan returned inside
`<proposed_plan>` markers is saved automatically if the model has not already
called `create_plan_file`. **Build** switches to Agent mode and starts implementing
the saved plan; **Close** leaves it unimplemented.

Every Agent run ends with a completion entry and the changed project files,
alongside the model's final summary. Failed or cancelled runs report their actual
outcome and any changes already made. Shell commands and compiler builds compare
project file contents before and after execution, including hidden configuration
files and deletions, without requiring Git. Symlinks, `.git`, `.plan`, and generated
directories are excluded from this comparison. Tracking failures preserve command
output and show that the changed-file list may be incomplete. A successful Agent
loop does not itself mean compiler checks passed; the final summary reports checks
actually performed.

## Conversation history and context

Each chat owns a provider-independent `TAgentHistory`. Both synchronous sends and
GUI worker sends use `TAgentCore.RunPrompt`: append the user message once, request
an assistant response, store its text and all tool calls together, execute calls
sequentially, store each result with its call ID, and request the next response.
Later prompts replay this history chronologically. Results are associated with the
particular assistant invocation, so a provider reusing an ID in another response
cannot overwrite an earlier result. Missing/fallback IDs are generated locally.
An identical result committed twice within one invocation is ignored.

Streaming responses complete on `data: [DONE]` or on a clean HTTP end after a
terminal `finish_reason` of `stop` or `tool_calls`; this supports compatible
providers that omit the sentinel. Streams without either completion signal,
provider/parser errors, invalid call arguments, and truncated responses fail before
assistant history is committed or tools execute. Rejected/cancelled batches retain
results for remaining calls so later requests have a complete call/result sequence.
Transport errors retain successful earlier tool exchanges. Reasoning API fields
are never stored in the conversation or included in summaries or subsequent requests;
existing transient UI display remains available.

**Settings → General** exposes the input-context budget (default **32768**) and
recent completed turns retained (default **2**). These values persist in the existing
INI configuration. The input budget is an estimate, not the model's context window:
the fallback estimator uses serialized UTF-8 bytes divided by three, rounded up,
plus message overhead, including system instructions and tool declarations. Set a
budget below the model's actual context limit to leave space for its response.
`History.EstimatedInputTokens` reports the most recent preflight estimate; it is
separate from actual provider token usage, which is not currently tracked.

Above 80% of this budget, older whole turns are summarized automatically through
the configured model with tools disabled and a 2048-token output limit. This adds
API requests. The summary preserves engineering objectives, decisions, constraints,
modified files and symbols, attempted/failed approaches, unresolved work, and user
preferences. Large eligible prefixes are processed in bounded chronological batches.
System instructions, the two recent turns, and the current turn remain verbatim;
tool-call/result groups are never split. Context is sent as system instructions,
a labeled historical summary, and retained messages. Summary progress appears in
the status bar, and the completed summary is added to the visible chat transcript.

Replacement is transactional: every summary batch must succeed and the resulting
context must fit before old messages are freed. Empty, invalid, cancelled, or failed
summaries preserve the original history and can be retried. If recent/current history
or an indivisible older turn cannot fit, the run stops with full tool output retained.
Further prompts cannot grow a chat blocked by size; change the budget or retention
settings, or clear the chat. Changed settings undergo preflight before a prompt is
admitted. Tool results are never silently truncated by history management.

**Clear Chat** stops the worker before resetting history, summary, estimates, local
ID counters, blocked state, and tool-session state. Conversation history remains
in memory and does not survive application restart; no database is introduced.

Extension points:

- `TLLMAdapter` converts common messages to provider requests and parses responses.
  The current `TChatCompletionsAdapter` serves all existing compatible endpoints;
  `TSSEStream` handles their streaming protocol. `TLLMClient.SendResponse` returns
  an owned `TChatMessage` with every call. Legacy single-call overloads remain
  available, but new integrations should use `SendResponse`.
- `TContextEstimator` can be replaced with a model-specific tokenizer;
  `TConversationCompactor` can be replaced with a different summary policy.
  Assign replacements through the idle agent's `ContextEstimator` and `Compactor`
  properties; the agent takes ownership. `TAgentHistory.ReplacePrefix` is the
  whole-turn replacement boundary for future persistence or repository-context work.
- History owns messages, messages own calls, and request snapshots deep-clone both.
  JSON request trees belong to the provider layer, not the conversation model.

---

## Local Tools

The standalone app and IDE plugin expose the same JSON tool interfaces:

| Tool | Arguments | Behavior |
| --- | --- | --- |
| `read_file` | `path`, optional `offset`, `limit` | Numbered text lines; offset starts at 1; limit is 1–2000. |
| `write_file` | `path`, `content` | Create/replace a file, including explicitly empty content. |
| `list_directory` | optional `path`, `include_hidden` | Immediate entries with file/directory/symlink type and size. |
| `glob` | `pattern`, optional `path`, `include_hidden` | Project-relative file patterns supporting `*`, `?`, and `**`; path narrows traversal. |
| `search_code` | `query`, optional `path`, `glob`, `regex`, `case_sensitive`, `include_hidden` | Native Pascal text search with file, line, byte column, and matching text; supports literals and common regular expressions. |
| `apply_patch` | `patch` | Unified diff creation, modification, and deletion; validates every hunk before writing. |
| `shell` | `command`, optional `cwd`, `timeout_ms` | Execute through `/bin/sh` on Unix or `cmd.exe` on Windows. |
| `diagnostics` | `action: read/build`, optional `target`, `timeout_ms` | Read the latest compiler result or build an explicit `.lpi`, `.lpk`, `.pas`, or `.lpr`. |
| `git` | `operation: status/diff/log/show`, optional `revision`, `paths`, `limit`, `staged` | Inspect changes/history; log limit defaults to 20, maximum 100. |
| `todo` | `action: read/replace`, optional `items` | Chat-local tasks with unique string IDs, text, and `pending/in_progress/completed` status. |
| `create_plan_file` | `content` | Save a Markdown plan under `.plan/`; preserve the plan preview and **Build** transition to Agent mode. |

Canonical names are advertised to models. Compatibility calls remain accepted:

- `terminal` → `shell`, `grep` → `search_code`, `plan` → `todo`.
- `edit_file(path, old_text, new_text)` replaces exactly one occurrence and preserves surrounding bytes.
- `list_files(path, extension, recursive)` retains its existing files-only output, extension filtering, 500-file cap, and recursion depth limit.
- `plan` tracks tasks; use `create_plan_file` to save the implementation document.

### Access and limits

**Ask** and **Plan** can inspect files, search, inspect Git, read cached diagnostics, and update chat-local tasks. **Plan** can also save its plan. **Agent** additionally enables writes, patches, commands, and compiler builds. The registry enforces these permissions for native and fallback tool calls in both execution paths.

The generated prompt identifies the active mode and lists its available tools and argument schemas. Plan mode permits only `.md` creation inside the project's `.plan/` directory through `create_plan_file`; its prompt includes the absolute permitted folder. The plan writer rejects a `.plan` directory that is a symbolic link or reparse point.

Dedicated file tools resolve paths within the active project and reject traversal or symbolic-link escapes. Directory listings show links without following them; recursive exploration skips links to avoid cycles. Globs/searches exclude generated directories by default and omit hidden entries unless requested. Results are sorted and capped at 500 with truncation metadata.

Text reads support UTF-8/ASCII and reject binary/unsupported encodings and files larger than 16 MiB. Patch and exact-replacement edits preserve existing bytes, UTF-8 BOMs, line endings, and Unix permissions. Patch mismatches leave every target unchanged; filesystem failures during replacement report any paths already changed. Renames and quoted unified-diff paths are unsupported; use deletion and creation for renames.

Commands default to the project directory, a 120-second timeout, and a 600-second maximum. Each output stream is capped at 1 MiB while pipes continue draining; invalid UTF-8 bytes are replaced so results remain valid JSON. Stop cancels running commands and their child processes. Shell commands run with ordinary OS permissions and can access files beyond the project; the dedicated file-tool policy is not a shell sandbox. Compiler builds produce build artifacts but never run the resulting application.

Tasks and the latest diagnostic result live in memory for the chat and reset on **Clear Chat**. Cached diagnostics carry the project, target, and UTC timestamp; they are a snapshot rather than live LSP errors. Git errors are returned normally when the project is not a repository; no repository is initialized automatically.

Runtime dependencies: `git` for Git inspection, `fpc` for Pascal targets, and `lazbuild` for Lazarus projects/packages. Code search is implemented natively in Pascal and needs no external search executable; regex syntax follows Free Pascal's `RegExpr` unit, so ripgrep-specific syntax is not guaranteed. Web search, page fetching, browser automation, and LSP connections are deferred.

### Tool error kinds and recovery

Failed tools return JSON with an `error` string. `apply_patch` also sets `error_kind` (and often `path` / `line`) so the model can recover without guessing.

| `error_kind` | Typical cause | Recovery |
| --- | --- | --- |
| `context_mismatch` | Context or removal line does not match the file | `read_file` the path, copy exact lines, rebuild the hunk |
| `format` | Not a raw unified diff (Markdown fences, `*** Begin Patch`, missing `---`/`+++`) | Send only `--- a/...`, `+++ b/...`, `@@`, and prefixed hunk lines |
| `hunk_count_mismatch` | Too many/few ` ` / `-` / `+` lines vs the `@@` old/new counts | Re-count lines; each hunk line must start with space, `-`, or `+` |
| `incomplete_hunk` | Hunk ended before old/new counts were satisfied | Same as hunk counts; ensure the full hunk body is present |
| `invalid_hunk` | Bad `@@` header, overlap, or malformed hunk line | Fix hunk headers and positions using current file line numbers |
| `empty_patch` | No file sections or no hunks | Include at least one `---`/`+++` pair and one `@@` hunk |
| `patch_apply` | Validation/commit failure (duplicate target, rename, I/O, cancel) | Read the `error` text; on `partial: true`, inspect `changed_paths` |

Other common errors (plain `error`, no `error_kind`): `Path escapes the active project` (use project-relative paths); `old_text must match exactly once` for `edit_file`; `Cannot run Git` / missing `fpc` or `lazbuild` (install and ensure `PATH`); `Tool unavailable in Ask/Plan mode`. For `shell`, use **cmd.exe** syntax on Windows (`&`, `>`, `exit /b`) and **/bin/sh** syntax on Unix/macOS.

### Adding custom tools

Subclass `TAgentTool` and implement `Execute(const AArgsJSON: string): string`, then register the instance with `GetToolRegistry.RegisterTool`. Existing custom tools remain compatible and default to Agent-only access. Set `AllowedModes`, `MutatesFiles`, `Aliases` (semicolon-separated), and `Advertised` explicitly when needed.

Context-aware tools can override `ExecuteWithContext` to access the project root, mode, cancellation callback, and chat-owned task/diagnostic state. Call the context-aware `ExecuteTool` overload to enforce permissions; the two-argument overload retains legacy Agent-mode behavior for existing callers. Errors use a JSON string `error` field. File edits and commands/builds retain `changed_paths`; commands/builds retain `refresh_project` for compatibility.

### Immediate reload inside Lazarus

The IDE plugin automatically reloads affected open project files after each agent file write, exact replacement, or individual patch commit. It discards unsaved changes in those editors and associated open form, frame, and data-module designers without asking or saving first. Repeated edits to the same file each reload immediately. Unopened files and files outside the run's project are skipped; deleted files have their affected views closed without saving. Editor cursor positions and the active source tab are preserved where possible.

Shell commands and builds refresh at tool completion, including failure or cancellation. The plugin compares the disk contents of eligible open files and their designer resources, so unchanged files retain unsaved edits. Lazarus's ordinary disk-change check is temporarily suspended during mutating tools and restored afterward. Reload errors are reported in chat; IDE reload questions are cancelled and reported instead of opening modal dialogs.

Custom file tools can call `NotifyToolFileChanged(Path)` after each successful commit, using the current `TToolContext.OnFileChanged` callback. It returns a warning string if notification fails; include it in `tracking_warning` without treating an already committed write as a failed write. Worker callbacks run synchronously on the IDE thread before tool execution continues. `TAgentCore.OnFileChanged` supports the synchronous execution path. Tools that only return `changed_paths` still refresh at tool completion. The IDE refresh callback now receives both the changed paths and the frozen run project root.

### Tests

```bash
./tests/run_tests.sh
./tests/run_gui_tests.sh   # Native widgetset; Linux uses Qt5/Xvfb
./tests/run_ide_tests.sh   # Native widgetset; Linux uses Qt5/Xvfb
./build.sh all
```

The native Windows build and test workflows have also been exercised. Run the
corresponding batch scripts from a Windows command prompt:

```bat
tests\run_tests.bat
tests\run_gui_tests.bat
tests\run_ide_tests.bat
build.bat all
```

Windows test runners require native Lazarus/Free Pascal, Python, `git`,
and the TurboPowerIPro and Printer4Lazarus packages. Keep `fpc.exe`
and `lazbuild.exe` on `PATH`; set `LAZARUS_DIR` if the scripts cannot find the
Lazarus installation in the usual locations. GUI and IDE tests default to the
`win32` widgetset (override with `LCL_WS`) and do not require Xvfb. The Bash
runners support Linux and macOS; use the batch runners on Windows.

GitHub Actions: macOS jobs run in [`.github/workflows/macos.yml`](.github/workflows/macos.yml). The Windows workflow ([`.github/workflows/windows.yml`](.github/workflows/windows.yml)) is manual (`workflow_dispatch`); enable **Use self-hosted runner** on a Windows machine with the toolchain above. Set repository variables `LAZARUS_DIR` (Lazarus root) and optionally `WINDOWS_SELF_HOSTED_LABEL` (runner label, default `self-hosted`).

### macOS

The Bash build and test runners select Cocoa on macOS by default. Set
`LAZARUS_DIR` when Lazarus is installed outside the common paths, or set
`LCL_WS` when using a different installed widgetset. Run the full native suite
from a graphical macOS session:

```bash
./build.sh all
./tests/run_tests.sh
./tests/run_gui_tests.sh
./tests/run_ide_tests.sh
```

The macOS runners require Free Pascal, Lazarus with Cocoa LCL units, Python 3,
`git`, the OpenSSL 3 libraries and command-line tool, `TurboPowerIPro`,
and `Printer4Lazarus`. The GUI tests run directly on macOS and do not use Xvfb
or Qt's XCB backend. The core test runner also makes a local trusted HTTPS/SSE
request on macOS to verify that the OpenSSL runtime is loadable.

GitHub Actions builds and tests native arm64 and x86_64 targets. Install the
architecture-appropriate toolchain from the
[official Lazarus downloads](https://www.lazarus-ide.org/index.php?page=downloads).

The checked-in `packagefiles.xml` is Lazarus IDE machine metadata and may
contain absolute paths from the environment that created it. Portable builds
use the relative `.lpk` and `.lpi` files instead of that metadata; regenerate
`packagefiles.xml` locally when opening the package through a different
Lazarus installation.

Fixtures cover file confinement, aliases/modes, glob/search, exact replacements and unified diffs, per-file notification ordering and partial cancellation, process output limits and child cleanup, compiler/Git results, task state, SSE tool names, and both agent loops. Conversation fixtures also cover multiple user turns, multiple/interleaved tool calls,
result linkage and idempotence, summary batching/rollback/retry, cancellation,
context limits and settings defaults. Focused history and conversation integration
binaries run with Free Pascal heap tracing. Mock LLM tests bind only to loopback and keep their files/configuration in temporary directories. GUI fixtures exercise patch/command refresh notifications, plan preview/**Build**, cancelling a process through **Clear Chat**, and switching the active project. The IDE adapter fixture uses test implementations of Lazarus's editor/designer interfaces to verify targeting, reload flags, cached resource refresh, deletion, snapshots, and silent error handling; it does not replace a smoke test in a rebuilt Lazarus IDE.
