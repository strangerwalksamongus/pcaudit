@echo off
setlocal enabledelayedexpansion

rem ============================================================
rem  run_audit.bat
rem
rem  Launcher for run_audit.ps1. Its only jobs are:
rem    1. make sure we are running as administrator
rem    2. start PowerShell with the execution policy bypassed
rem
rem  Every path is derived from %~dp0 (the folder this file lives
rem  in), never from the current directory. That is what makes the
rem  USB drive letter irrelevant, and it is what keeps things
rem  working after UAC elevation - an elevated process starts with
rem  its working directory set to C:\Windows\System32, so anything
rem  relative would resolve to the wrong disk entirely.
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

rem --- Are we elevated? "net session" only succeeds as administrator. ---
net session >nul 2>&1
if %ERRORLEVEL% equ 0 goto :run_audit

rem --- Already tried to elevate once and still not admin: give up. ---
if "%~1"=="--elevated" (
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

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '--elevated' -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"

if %ERRORLEVEL% neq 0 (
    echo.
    echo   ERROR: Elevation was cancelled or refused. The audit did NOT run
    echo          and no files were written.
    echo.
    pause
    exit /b 3
)

rem The elevated copy is doing the work now; this one is done.
exit /b 0

:run_audit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
set "RC=%ERRORLEVEL%"
exit /b %RC%
