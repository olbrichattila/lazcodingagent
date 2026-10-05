@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0.."
set "TEST_OUTPUT=%TEMP%\coding-agent-tests-%RANDOM%"
mkdir "%TEST_OUTPUT%" || exit /b 1
set "LAZARUS_DIR=%LAZARUS_DIR%"
if not defined LAZARUS_DIR if defined ProgramFiles if exist "%ProgramFiles%\Lazarus" set "LAZARUS_DIR=%ProgramFiles%\Lazarus"
if not defined LAZARUS_DIR if defined ProgramFiles(x86) if exist "%ProgramFiles(x86)%\Lazarus" set "LAZARUS_DIR=%ProgramFiles(x86)%\Lazarus"
if not defined LAZARUS_DIR (
  echo Error: Set LAZARUS_DIR to the Lazarus installation directory.
  goto :fail
)
set FLAGS=-Fu.\src\core -Fu.\src\tools -Fu.\src\llm -Fu"%LAZARUS_DIR%\components\lazutils" -FU"%TEST_OUTPUT%" -FE"%TEST_OUTPUT%"

fpc %FLAGS% tests\test_sse_tool_names.pas >"%TEST_OUTPUT%\sse-build.log" 2>&1 || goto :show_sse
fpc %FLAGS% tests\tool_driver.pas >"%TEST_OUTPUT%\tool-build.log" 2>&1 || goto :show_tool
fpc %FLAGS% tests\agent_driver.pas >"%TEST_OUTPUT%\agent-build.log" 2>&1 || goto :show_agent
fpc %FLAGS% tests\test_registry.pas >"%TEST_OUTPUT%\registry-build.log" 2>&1 || goto :show_registry
fpc %FLAGS% tests\test_file_notifications.pas >"%TEST_OUTPUT%\notifications-build.log" 2>&1 || goto :show_notifications
fpc %FLAGS% -gh tests\test_conversation.pas >"%TEST_OUTPUT%\conversation-build.log" 2>&1 || goto :show_conversation
fpc %FLAGS% -gh tests\conversation_driver.pas >"%TEST_OUTPUT%\history-build.log" 2>&1 || goto :show_history

set "APPDATA=%TEST_OUTPUT%\appdata"
"%TEST_OUTPUT%\test_conversation.exe" 2>"%TEST_OUTPUT%\heap.log" || goto :fail
findstr /r /c:"[1-9][0-9]* unfreed memory blocks" "%TEST_OUTPUT%\heap.log" >nul && type "%TEST_OUTPUT%\heap.log" && goto :fail
python tests\test_conversation_context.py "%TEST_OUTPUT%\conversation_driver.exe" || goto :fail
"%TEST_OUTPUT%\test_file_notifications.exe" "%TEST_OUTPUT%" || goto :fail
"%TEST_OUTPUT%\test_registry.exe" || goto :fail
"%TEST_OUTPUT%\test_sse_tool_names.exe" || goto :fail
python tests\test_local_tools.py "%TEST_OUTPUT%\tool_driver.exe" || goto :fail
python tests\test_agent_loops.py "%TEST_OUTPUT%\agent_driver.exe" || goto :fail
echo All tests passed.
goto :cleanup

:show_sse
type "%TEST_OUTPUT%\sse-build.log"
goto :fail
:show_tool
type "%TEST_OUTPUT%\tool-build.log"
goto :fail
:show_agent
type "%TEST_OUTPUT%\agent-build.log"
goto :fail
:show_registry
type "%TEST_OUTPUT%\registry-build.log"
goto :fail
:show_notifications
type "%TEST_OUTPUT%\notifications-build.log"
goto :fail
:show_conversation
type "%TEST_OUTPUT%\conversation-build.log"
goto :fail
:show_history
type "%TEST_OUTPUT%\history-build.log"

:fail
echo Tests failed. Logs are in %TEST_OUTPUT%
exit /b 1

:cleanup
rmdir /s /q "%TEST_OUTPUT%"
exit /b 0
