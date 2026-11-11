@echo off
title Local LLM - stop everything
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\serve-model.ps1" -Stop
echo.
echo  Model servers stopped, GPU freed.
echo  (The Anthropic shim on :8097 is left alone - it is idle and costs nothing.)
pause
