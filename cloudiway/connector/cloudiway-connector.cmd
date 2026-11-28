@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cloudiway-connector-launcher.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
echo Code de sortie : %RC%  (0 = conforme, 1 = arret avant toute ecriture, 2 = applique avec des elements en echec ou a verifier)
pause
exit /b %RC%
