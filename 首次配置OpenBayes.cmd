@echo off
chcp 65001 >nul
title Setup OpenBayes Connection
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-OpenBayesCodex.ps1"
set "OPENBAYES_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %OPENBAYES_EXIT%
