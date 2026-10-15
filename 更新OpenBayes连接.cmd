@echo off
chcp 65001 >nul
title Update OpenBayes Connection
> "%~dp0last-run.log" echo [LAUNCHER] Starting Windows PowerShell...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-OpenBayesCodex.ps1"
set "OPENBAYES_EXIT=%ERRORLEVEL%"
>> "%~dp0last-run.log" echo [LAUNCHER] PowerShell exit code: %OPENBAYES_EXIT%
echo.
if not "%OPENBAYES_EXIT%"=="0" echo Update failed. Log: %~dp0last-run.log
pause
exit /b %OPENBAYES_EXIT%
