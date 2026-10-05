@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0.."
set "TEST_OUTPUT=%TEMP%\coding-agent-ide-%RANDOM%"
mkdir "%TEST_OUTPUT%" || exit /b 1
set "LAZARUS_DIR=%LAZARUS_DIR%"
if not defined LAZARUS_DIR if defined ProgramFiles if exist "%ProgramFiles%\Lazarus" set "LAZARUS_DIR=%ProgramFiles%\Lazarus"
if not defined LAZARUS_DIR if defined ProgramFiles(x86) if exist "%ProgramFiles(x86)%\Lazarus" set "LAZARUS_DIR=%ProgramFiles(x86)%\Lazarus"
if not defined LAZARUS_DIR (
  echo Error: Set LAZARUS_DIR to the Lazarus installation directory.
  goto :fail
)
set "LCL_WS=%LCL_WS%"
if not defined LCL_WS set "LCL_WS=win32"
(
  echo ^<CONFIG^>
  echo   ^<ProjectOptions^>
  echo     ^<Version Value="12"/^>
  echo     ^<General^>^<MainUnit Value="0"/^>^</General^>
  echo     ^<RequiredPackages Count="4"^>
  echo       ^<Item1^>^<PackageName Value="IDEIntf"/^>^</Item1^>
  echo       ^<Item2^>^<PackageName Value="CodeTools"/^>^</Item2^>
  echo       ^<Item3^>^<PackageName Value="TurboPowerIPro"/^>^</Item3^>
  echo       ^<Item4^>^<PackageName Value="LCL"/^>^</Item4^>
  echo     ^</RequiredPackages^>
  echo     ^<Units Count="1"^>^<Unit0^>^<Filename Value="%CD%\tests\test_ide_reload.pas"/^>^<IsPartOfProject Value="True"/^>^</Unit0^>^</Units^>
  echo   ^</ProjectOptions^>
  echo   ^<CompilerOptions^>
  echo     ^<Version Value="11"/^>
  echo     ^<Target^>^<Filename Value="%TEST_OUTPUT%\ide_reload"/^>^</Target^>
  echo     ^<SearchPaths^>^<OtherUnitFiles Value="%CD%\src\core;%CD%\src\tools;%CD%\src\llm;%CD%\src\ui;%CD%\src\ide"/^>^<UnitOutputDirectory Value="%TEST_OUTPUT%\units"/^>^</SearchPaths^>
  echo   ^</CompilerOptions^>
  echo ^</CONFIG^>
) >"%TEST_OUTPUT%\ide_reload.lpi"
lazbuild --ws=%LCL_WS% "%TEST_OUTPUT%\ide_reload.lpi" >"%TEST_OUTPUT%\build.log" 2>&1
if errorlevel 1 (
  type "%TEST_OUTPUT%\build.log"
  goto :fail
)
mkdir "%TEST_OUTPUT%\project"
"%TEST_OUTPUT%\ide_reload.exe" "%TEST_OUTPUT%\project"
if errorlevel 1 goto :fail
echo IDE adapter tests passed.
rmdir /s /q "%TEST_OUTPUT%"
exit /b 0
:fail
echo IDE tests failed. Logs are in %TEST_OUTPUT%
exit /b 1
