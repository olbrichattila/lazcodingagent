@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "ROOT=%~dp0"
set "APP_DIR=%ROOT%app"
set "PKG_DIR=%ROOT%package"
set "BIN_DIR=%APP_DIR%\bin"
set "ACTION=%~1"
if "%ACTION%"=="" set "ACTION=app"

if /i "%ACTION%"=="help" goto :usage
if /i "%ACTION%"=="--help" goto :usage
if /i "%ACTION%"=="-h" goto :usage

where lazbuild >nul 2>&1 || goto :missing_lazbuild
where fpc >nul 2>&1 || goto :missing_fpc

set "LAZBUILD_FLAGS="
if defined LAZARUS_DIR set LAZBUILD_FLAGS=--lazarusdir="%LAZARUS_DIR%"
if defined LCL_WS set "LAZBUILD_FLAGS=%LAZBUILD_FLAGS% --ws=%LCL_WS%"

if /i "%ACTION%"=="app" goto :build_app
if /i "%ACTION%"=="package" goto :build_package
if /i "%ACTION%"=="install" goto :install_package
if /i "%ACTION%"=="all" goto :build_all
if /i "%ACTION%"=="clean" goto :clean
echo Error: Unknown command "%ACTION%"
goto :usage_error

:build_app
echo ==^> Building Standalone Chat Application...
if not exist "%APP_DIR%\standalone_chat.lpi" (
  echo Error: %APP_DIR%\standalone_chat.lpi not found.
  exit /b 1
)
if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"
lazbuild %LAZBUILD_FLAGS% --build-mode=Default "%APP_DIR%\standalone_chat.lpi"
if errorlevel 1 exit /b 1
echo ==^> Standalone app built successfully under: %BIN_DIR%
exit /b 0

:build_package
echo ==^> Compiling Lazarus IDE Package...
if not exist "%PKG_DIR%\lazaruscodingagent.lpk" (
  echo Error: %PKG_DIR%\lazaruscodingagent.lpk not found.
  exit /b 1
)
lazbuild %LAZBUILD_FLAGS% "%PKG_DIR%\lazaruscodingagent.lpk"
if errorlevel 1 exit /b 1
echo ==^> Package compiled successfully.
exit /b 0

:install_package
echo ==^> Registering package and rebuilding Lazarus IDE...
if not exist "%PKG_DIR%\lazaruscodingagent.lpk" (
  echo Error: %PKG_DIR%\lazaruscodingagent.lpk not found.
  exit /b 1
)
lazbuild %LAZBUILD_FLAGS% --add-package "%PKG_DIR%\lazaruscodingagent.lpk"
if errorlevel 1 exit /b 1
lazbuild %LAZBUILD_FLAGS% --build-ide=
if errorlevel 1 exit /b 1
echo ==^> Package registered and Lazarus IDE rebuilt successfully.
exit /b 0

:build_all
call "%~f0" package
if errorlevel 1 exit /b 1
call "%~f0" app
exit /b %errorlevel%

:clean
echo ==^> Cleaning build artifacts...
for /r "%ROOT%" %%F in (*.o *.ppu *.a *.compiled *.or *.res *.rsj) do if exist "%%F" del /q "%%F"
if exist "%BIN_DIR%" rmdir /s /q "%BIN_DIR%"
if exist "%APP_DIR%\lib" rmdir /s /q "%APP_DIR%\lib"
if exist "%PKG_DIR%\lib" rmdir /s /q "%PKG_DIR%\lib"
echo ==^> Clean complete.
exit /b 0

:missing_lazbuild
echo Error: lazbuild was not found in PATH. Install Lazarus or add lazbuild.exe to PATH.
exit /b 1

:missing_fpc
echo Error: fpc was not found in PATH. Install Free Pascal or add fpc.exe to PATH.
exit /b 1

:usage_error
echo Usage: build.bat [command]
echo.
echo Commands:
echo   app         Build the standalone chat application (default)
echo   package     Compile the Lazarus IDE package (.lpk)
echo   install     Register package and rebuild Lazarus IDE
echo   all         Build both the standalone app and compile the package
echo   clean       Remove compilation artifacts and binaries
echo   help        Display this help message
exit /b 1

:usage
echo Usage: build.bat [command]
echo.
echo Commands:
echo   app         Build the standalone chat application (default)
echo   package     Compile the Lazarus IDE package (.lpk)
echo   install     Register package and rebuild Lazarus IDE
echo   all         Build both the standalone app and compile the package
echo   clean       Remove compilation artifacts and binaries
echo   help        Display this help message
exit /b 0
