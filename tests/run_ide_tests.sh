#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_OUTPUT="$(mktemp -d /tmp/coding-agent-ide-XXXXXX)"
trap 'rm -rf "$TEST_OUTPUT"' EXIT
cat > "$TEST_OUTPUT/ide_reload.lpi" <<XML
<CONFIG>
  <ProjectOptions>
    <Version Value="12"/>
    <General><MainUnit Value="0"/></General>
    <RequiredPackages Count="4">
      <Item1><PackageName Value="IDEIntf"/></Item1>
      <Item2><PackageName Value="CodeTools"/></Item2>
      <Item3><PackageName Value="TurboPowerIPro"/></Item3>
      <Item4><PackageName Value="LCL"/></Item4>
    </RequiredPackages>
    <Units Count="1"><Unit0><Filename Value="$PWD/tests/test_ide_reload.pas"/><IsPartOfProject Value="True"/></Unit0></Units>
  </ProjectOptions>
  <CompilerOptions>
    <Version Value="11"/>
    <Target><Filename Value="$TEST_OUTPUT/ide_reload"/></Target>
    <SearchPaths><OtherUnitFiles Value="$PWD/src/core;$PWD/src/tools;$PWD/src/llm;$PWD/src/ui;$PWD/src/ide"/><UnitOutputDirectory Value="$TEST_OUTPUT/units"/></SearchPaths>
  </CompilerOptions>
</CONFIG>
XML
lazbuild --ws=qt5 "$TEST_OUTPUT/ide_reload.lpi" >"$TEST_OUTPUT/build.log" 2>&1 || { rg "Error:|Fatal:" "$TEST_OUTPUT/build.log"; exit 1; }
mkdir "$TEST_OUTPUT/project"
QT_QPA_PLATFORM=xcb xvfb-run -a "$TEST_OUTPUT/ide_reload" "$TEST_OUTPUT/project"
