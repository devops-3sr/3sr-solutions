@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cloudiway-collector-launcher.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
echo Code de sortie : %RC%
pause
exit /b %RC%
