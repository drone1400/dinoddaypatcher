@echo off
REM ---------------------------------------------------------------------------
REM  DinoDDayPatcher launcher -- double-click this instead of the .ps1.
REM
REM  -ExecutionPolicy Bypass here applies to this one PowerShell process and
REM  nothing else. Do NOT "fix" script-blocked errors with Set-ExecutionPolicy:
REM  that is a permanent, machine-wide change and is not needed to run this.
REM
REM  Arguments are passed straight through, e.g.  DinoDDayPatcher.bat -s
REM ---------------------------------------------------------------------------

setlocal
set "PS1=%~dp0DinoDDayPatcher.ps1"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS1%" (
    echo.
    echo   DinoDDayPatcher.ps1 was not found next to this file.
    echo   Keep both files together in the same folder.
    echo.
    pause
    exit /b 1
)

REM Full path so a stray powershell.exe in the working directory cannot be
REM picked up instead. Fall back to the PATH if the install is non-standard.
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

REM Double-clicking passes no arguments, and the window would otherwise close
REM before anything could be read. A scripted call with arguments is left alone.
if "%~1"=="" pause
exit /b %RC%
