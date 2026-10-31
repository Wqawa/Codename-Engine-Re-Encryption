@echo off
rem ---------------------------------------------------------------------------
rem  Double click this file to build Codename Engine for Windows.
rem
rem  It forwards everything to lazy-build.ps1 next to it, so this one file does
rem  what setup-windows.bat and a build had to be run for separately:
rem
rem    1. find (or download) Haxe + Neko,
rem    2. check that every library listed in building\libs.xml is really
rem       installed and run the upstream setup-windows.bat for whatever is
rem       missing, then continue,
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

where pwsh >nul 2>nul
if not errorlevel 1 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)

set EXITCODE=%errorlevel%
echo.
echo  exit code: %EXITCODE%
if not defined LAZYBUILD_NOPAUSE pause
exit /b %EXITCODE%
