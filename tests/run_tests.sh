#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_OUTPUT="$(mktemp -d /tmp/coding-agent-tests-XXXXXX)"
trap 'rm -rf "$TEST_OUTPUT"' EXIT
LAZARUS_DIR="${LAZARUS_DIR:-/usr/lib/lazarus/default}"
FLAGS=(-Fu./src/core -Fu./src/tools -Fu./src/llm "-Fu${LAZARUS_DIR}/components/lazutils" "-FU${TEST_OUTPUT}" "-FE${TEST_OUTPUT}")
fpc "${FLAGS[@]}" tests/test_sse_tool_names.pas >"$TEST_OUTPUT/sse-build.log" 2>&1 || { cat "$TEST_OUTPUT/sse-build.log"; exit 1; }
fpc "${FLAGS[@]}" tests/tool_driver.pas >"$TEST_OUTPUT/tool-build.log" 2>&1 || { cat "$TEST_OUTPUT/tool-build.log"; exit 1; }
fpc "${FLAGS[@]}" tests/agent_driver.pas >"$TEST_OUTPUT/agent-build.log" 2>&1 || { cat "$TEST_OUTPUT/agent-build.log"; exit 1; }
fpc "${FLAGS[@]}" tests/test_registry.pas >"$TEST_OUTPUT/registry-build.log" 2>&1 || { cat "$TEST_OUTPUT/registry-build.log"; exit 1; }
fpc "${FLAGS[@]}" tests/test_file_notifications.pas >"$TEST_OUTPUT/notifications-build.log" 2>&1 || { cat "$TEST_OUTPUT/notifications-build.log"; exit 1; }
fpc "${FLAGS[@]}" -gh tests/test_conversation.pas >"$TEST_OUTPUT/conversation-build.log" 2>&1 || { cat "$TEST_OUTPUT/conversation-build.log"; exit 1; }
fpc "${FLAGS[@]}" -gh tests/conversation_driver.pas >"$TEST_OUTPUT/history-build.log" 2>&1 || { cat "$TEST_OUTPUT/history-build.log"; exit 1; }
XDG_CONFIG_HOME="$TEST_OUTPUT/config" "$TEST_OUTPUT/test_conversation" 2>"$TEST_OUTPUT/heap.log"
if rg -q '[1-9][0-9]* unfreed memory blocks' "$TEST_OUTPUT/heap.log"; then cat "$TEST_OUTPUT/heap.log"; exit 1; fi
python3 tests/test_conversation_context.py "$TEST_OUTPUT/conversation_driver"
"$TEST_OUTPUT/test_file_notifications" "$TEST_OUTPUT"
"$TEST_OUTPUT/test_registry"
"$TEST_OUTPUT/test_sse_tool_names"
python3 tests/test_local_tools.py "$TEST_OUTPUT/tool_driver"
python3 tests/test_agent_loops.py "$TEST_OUTPUT/agent_driver"
