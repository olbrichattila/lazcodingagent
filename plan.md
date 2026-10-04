# Development Plan: Lazarus Coding Agent

Project roadmap and milestones for building the autonomous Coding Agent for Free Lazarus.

---

## Phase 1: Core Agent & UI Framework

### 1.1 Chat Interface (IDE Integration)
- [ ] Design and implement dockable/standalone chat window in Lazarus (LCL).
- [ ] Support message history, markdown rendering, code block highlighting, and status indicators.
- [ ] Add mode selector (Plan / Agent / Ask).

### 1.2 Mode Implementations
- [ ] **Ask Mode**:
  - Read-only context collection (active unit, selected code, project structure).
  - Direct LLM querying for explanations and advice.
- [ ] **Plan Mode**:
  - Codebase inspection and requirement analysis.
  - Generation of structured, actionable markdown execution plans without modifying source code.
- [ ] **Agent Mode**:
  - Autonomous tool execution loop (read, write, patch files, compile with FPC, parse compiler output/errors).
  - Human-in-the-loop approval gates for critical actions.

### 1.3 LLM & Tool Provider Integration
- [ ] Abstract provider interface (OpenAI, Anthropic, local/Ollama, custom endpoints).
- [ ] Tool calling / function execution engine in Pascal/native backend.
- [ ] Free Pascal / Lazarus compiler (`fpc` / `lazbuild`) integration for build & diagnostic feedback.

---

## Phase 2: Knowledge Base & RAG

### 2.1 Codebase Indexing & Retrieval
- [ ] Project symbol extraction (units, classes, methods, types) using Free Pascal parser.
- [ ] Local embeddings generation and vector storage.
- [ ] Semantic code search and context hydration.

### 2.2 Lazarus Documentation & Component Knowledge
- [ ] Integration of FPC/LCL documentation and reference materials into the RAG pipeline.
- [ ] Contextual component/property lookup.

---

## Phase 3: Multi-Agent Orchestration

### 3.1 Multi-Agent System
- [ ] Specialized agent roles (Planner, Implementer, Reviewer, Tester/Compiler Fixer).
- [ ] Inter-agent communication protocols and artifact passing.
- [ ] Conflict reconciliation and automated regression testing.
