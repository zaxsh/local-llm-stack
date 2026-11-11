@echo off
title Claude Code - local model
echo  Starting the model...
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\serve-model.ps1" gemma4
if errorlevel 1 goto fail
echo.
echo  Launching Claude Code against the local model.
echo.
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\connect-claude.ps1" -Port 8083
goto end
:fail
echo.
echo  The model did not start. Run "1 - List models.cmd" and check the name.
:end
echo.
pause
