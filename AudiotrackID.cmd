@echo off
rem AudiotrackID launcher - drag a folder or video files onto this file, or run:
rem   AudiotrackID.cmd "D:\Movies" [-DryRun] [-Model small] [-Samples 6] ...
setlocal
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0AudiotrackID.ps1" %*
set "RC=%ERRORLEVEL%"
rem keep the window open when started from Explorer (double-click / drag & drop)
echo %CMDCMDLINE% | find /i "/c" >nul && pause
exit /b %RC%
