#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_OUTPUT="$(mktemp -d /tmp/coding-agent-gui-XXXXXX)"
trap 'rm -rf "$TEST_OUTPUT"' EXIT
LAZARUS_DIR="${LAZARUS_DIR:-/usr/lib/lazarus/default}"
UNIT_PLATFORM="$(fpc -iTP)-$(fpc -iTO)"
fpc -Fu./src/core -Fu./src/tools -Fu./src/llm -Fu./src/ui \
  "-Fu${LAZARUS_DIR}/lcl/units/${UNIT_PLATFORM}" \
  "-Fu${LAZARUS_DIR}/lcl/units/${UNIT_PLATFORM}/qt5" \
  "-Fu${LAZARUS_DIR}/components/lazutils/lib/${UNIT_PLATFORM}" \
  "-Fu${LAZARUS_DIR}/components/turbopower_ipro/units/${UNIT_PLATFORM}/qt5" \
  "-Fu${LAZARUS_DIR}/components/printers/lib/${UNIT_PLATFORM}/qt5" \
  "-FU${TEST_OUTPUT}" "-FE${TEST_OUTPUT}" tests/gui_driver.pas >"$TEST_OUTPUT/build.log" 2>&1 || { cat "$TEST_OUTPUT/build.log"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 QT_QPA_PLATFORM=xcb xvfb-run -a python3 tests/test_gui_flow.py "$TEST_OUTPUT/gui_driver"
