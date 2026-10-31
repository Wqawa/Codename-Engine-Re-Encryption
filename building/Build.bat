@echo off
rem ---------------------------------------------------------------------------
rem  Double click this file to build Codename Engine for Windows.
rem
rem  It forwards everything to lazy-build.ps1 next to it, so this one file does
rem  everything the removed setup-windows.bat and cne-windows.bat used to do:
rem
rem    1. find (or download) Haxe + Neko,
rem    2. check that every library listed in building\libs.xml is really
rem       installed, run the engine's own setup command for whatever is missing,
rem       then continue,
rem    3. check the lime native library and MSVC,
rem    4. ask whether to compile when libraries had to be installed, then build
rem       (a checkout that was already complete builds straight away),
rem    5. report the result and translate the usual errors.
rem
rem  Examples:  Build.bat           build, installing anything missing on the way
rem             Build.bat -Setup    only install/repair the libraries, no build
rem             Build.bat -Clean    full rebuild, ignore hxcpp objects
rem             Build.bat -Debug    debug configuration
rem             Build.bat -DryRun   print the plan, change nothing
rem             Build.bat test      engine command line (was cne-windows.bat test)
rem             Build.bat help      list the engine command line commands
rem             Build.bat optimize  optimize a JSON file
rem  Full help: lazy-build.md
rem ---------------------------------------------------------------------------
setlocal
chcp 65001 >nul
cd /d "%~dp0.."

set "SCRIPT=%~dp0lazy-build.ps1"

if not exist "project.xml" (
    echo.
    echo  [X] project.xml not found - this folder must stay inside the repository.
    echo.
    pause
    exit /b 1
)

if not exist "%SCRIPT%" (
    echo.
    echo  [X] missing %SCRIPT%
    echo      the build script was moved or deleted.
    echo.
    pause
    exit /b 1
)

rem An engine command line job ("Build.bat test", "Build.bat help", ...) used to be
rem cne-windows.bat. The raw command line is handed over in LAZYBUILD_CNE, because
rem PowerShell would otherwise bind the first word to a script parameter (it would
rem end up in -CacheDir).
set "ARGS=%*"
set "FIRST="
for /f "tokens=1" %%A in ("%ARGS%") do set "FIRST=%%A"
if defined FIRST (
    echo %FIRST%| findstr /i /x /c:"setup" /c:"help" /c:"test" /c:"build" /c:"run" /c:"release" /c:"test-release" /c:"optimize" >nul 2>nul
    if not errorlevel 1 (
        set "LAZYBUILD_CNE=%ARGS%"
        set "ARGS=-Cne"
    )
)

where pwsh >nul 2>nul
if not errorlevel 1 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %ARGS%
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %ARGS%
)

set EXITCODE=%errorlevel%
echo.
echo  exit code: %EXITCODE%
if not defined LAZYBUILD_NOPAUSE pause
exit /b %EXITCODE%
