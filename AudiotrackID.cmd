@echo off
rem AudiotrackID launcher - drag a folder or video files onto this file, or run:
rem   AudiotrackID.cmd "D:\Movies" [-DryRun] [-Model small] [-Samples 6] ...
setlocal
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
rem lets the script detect an Explorer launch (double-click / drag & drop) and keep the window open
set "ATID_LAUNCHER=1"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0AudiotrackID.ps1" %*
exit /b %ERRORLEVEL%
