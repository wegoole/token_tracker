@echo off
rem run_ttk.cmd -- launch the ttk popup (WinForms) from this script's folder.
rem Portable: %~dp0 relative, no hardcoded absolute paths. Copy the whole
rem project folder anywhere and this still works.
rem Usage: double-click, or:  run_ttk.cmd            (7-day popup)
rem        run_ttk.cmd 14                        (pass Days to _ttk.ps1)
rem CLI instead:  py -3.11 ttk.py --days 14
rem NOTE: keep this file ASCII-only - cmd.exe reads .cmd as GBK on this
rem system, non-ASCII comments get mangled and spew errors.
setlocal
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
if not exist "%HERE%\_ttk.ps1" (
    echo [ttk] _ttk.ps1 not found next to this script: %HERE%
    echo [ttk] keep run_ttk.cmd and _ttk.ps1 in the same folder.
    pause
    exit /b 1
)
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%HERE%\_ttk.ps1" %*
