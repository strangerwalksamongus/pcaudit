@echo off
setlocal enabledelayedexpansion

rem ============================================================
rem  run_audit.bat
rem
rem  Launcher for run_audit.ps1. Two jobs only:
rem    1. make sure we're running as administrator
rem    2. start PowerShell with the execution policy bypassed
rem
rem  Paths come from %~dp0 (this file's folder), never the current
rem  directory. That's what makes the USB drive letter irrelevant,
rem  and what keeps it working after UAC - an elevated process
rem  starts in C:\Windows\System32, so anything relative would
rem  resolve to the wrong disk.
rem ============================================================

title Computer Audit

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%run_audit.ps1"

if not exist "%PS_SCRIPT%" (
    echo.
    echo   ERROR: run_audit.ps1 was not found next to this file.
    echo          Expected it at:
    echo          %PS_SCRIPT%
    echo.
    pause
    exit /b 2
)

rem ------------------------------------------------------------------
rem  Split our own re-entry marker from arguments meant for the PS1.
rem
rem  --elevated is internal to this file. run_audit.ps1 has no parameter
rem  by that name, so forwarding it would make PowerShell reject the
rem  call before the script even ran. Elevation itself is unaffected.
rem
rem  Everything else passes straight through, so run_audit.bat -Console
rem  elevates as usual then asks the questions in the console.
rem ------------------------------------------------------------------
set "PS_ARGS="
set "WAS_ELEVATED="
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--elevated" (set "WAS_ELEVATED=1") else (set "PS_ARGS=!PS_ARGS! %1")
shift
goto parse_args
:args_done

rem --- Elevated? "net session" only succeeds as administrator. ---
net session >nul 2>&1
if %ERRORLEVEL% equ 0 goto :run_audit

rem --- Tried elevating once and still not admin, so give up. Tested via
rem     the variable, not %1 - shift has eaten the arguments by now. ---
if defined WAS_ELEVATED (
    echo.
    echo   ERROR: Administrator rights are required, but this process is
    echo          still not elevated.
    echo.
    echo          Right-click run_audit.bat and pick "Run as administrator",
    echo          or sign in with an account that has admin rights.
    echo.
    pause
    exit /b 3
)

echo.
echo   Requesting administrator rights...
echo   (WinAudit and CrystalDiskInfo need them for complete data.)
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '--elevated%PS_ARGS%' -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"

if %ERRORLEVEL% neq 0 (
    echo.
    echo   ERROR: Elevation was cancelled or refused. The audit did NOT run
    echo          and no files were written.
    echo.
    pause
    exit /b 3
)

rem The elevated copy is doing the work now, so this one is done.
exit /b 0

:run_audit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"%PS_ARGS%
set "RC=%ERRORLEVEL%"
exit /b %RC%
