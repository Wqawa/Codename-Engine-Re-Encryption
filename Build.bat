@echo off
rem ---------------------------------------------------------------------------
rem  Double click this file to build Codename Engine for Windows.
rem
rem  It forwards everything to tools\lazy-build\lazy-build.ps1, which finds or
rem  downloads Haxe + Neko, checks the vendored .haxelib libraries and the lime
rem  native library, checks MSVC, builds, and reports the result.
rem
rem  Examples:  Build.bat -Clean     Build.bat -Debug     Build.bat -DryRun
rem  Full help: tools\lazy-build\README.md
rem ---------------------------------------------------------------------------
setlocal
chcp 65001 >nul
cd /d "%~dp0"

set "SCRIPT=%~dp0tools\lazy-build\lazy-build.ps1"

if not exist "project.xml" (
    echo.
    echo  [X] project.xml not found - Build.bat must stay in the repository root.
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
