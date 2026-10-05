@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0.."
set "TEST_OUTPUT=%TEMP%\coding-agent-gui-%RANDOM%"
mkdir "%TEST_OUTPUT%" || exit /b 1
set "LAZARUS_DIR=%LAZARUS_DIR%"
if not defined LAZARUS_DIR if defined ProgramFiles if exist "%ProgramFiles%\Lazarus" set "LAZARUS_DIR=%ProgramFiles%\Lazarus"
if not defined LAZARUS_DIR if defined ProgramFiles(x86) if exist "%ProgramFiles(x86)%\Lazarus" set "LAZARUS_DIR=%ProgramFiles(x86)%\Lazarus"
if not defined LAZARUS_DIR (
  echo Error: Set LAZARUS_DIR to the Lazarus installation directory.
  goto :fail
)
for /f "delims=" %%A in ('fpc -iTP') do set "UNIT_CPU=%%A"
for /f "delims=" %%A in ('fpc -iTO') do set "UNIT_OS=%%A"
set "UNIT_PLATFORM=%UNIT_CPU%-%UNIT_OS%"
set "LCL_WS=%LCL_WS%"
if not defined LCL_WS set "LCL_WS=win32"
fpc -Fu.\src\core -Fu.\src\tools -Fu.\src\llm -Fu.\src\ui ^
  "-Fu%LAZARUS_DIR%\lcl\units\%UNIT_PLATFORM%" ^
  "-Fu%LAZARUS_DIR%\lcl\units\%UNIT_PLATFORM%\%LCL_WS%" ^
  "-Fu%LAZARUS_DIR%\components\lazutils\lib\%UNIT_PLATFORM%" ^
  "-Fu%LAZARUS_DIR%\components\turbopower_ipro\units\%UNIT_PLATFORM%\%LCL_WS%" ^
  "-Fu%LAZARUS_DIR%\components\printers\lib\%UNIT_PLATFORM%\%LCL_WS%" ^
  "-FU%TEST_OUTPUT%" "-FE%TEST_OUTPUT%" tests\gui_driver.pas >"%TEST_OUTPUT%\build.log" 2>&1
if errorlevel 1 (
  type "%TEST_OUTPUT%\build.log"
  goto :fail
)
python tests\test_gui_flow.py "%TEST_OUTPUT%\gui_driver.exe"
if errorlevel 1 goto :fail
echo GUI tests passed.
rmdir /s /q "%TEST_OUTPUT%"
exit /b 0
:fail
echo GUI tests failed. Logs are in %TEST_OUTPUT%
exit /b 1
