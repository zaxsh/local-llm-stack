@echo off
title Local LLM - connection configs
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\serve-model.ps1" -List
echo.
set /p PORT=Which port is your model on (enter for 8083):
if "%PORT%"=="" set PORT=8083
echo.
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\connect-any.ps1" -Port %PORT%
echo.
pause
