@echo off
title dsh-tui - local model
echo  Starting the model...
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\serve-model.ps1" gemma4
echo.
echo  Registering the route with dsh-tui...
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\connect-dsh.ps1" -Port 8083
echo.
echo  Opening dsh-tui. Use /model to pick the local route.
echo.
pwsh -NoProfile -File "C:\Users\fih\AppData\Roaming\npm\dsh-tui.ps1"
echo.
pause
