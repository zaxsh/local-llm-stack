@echo off
title Local LLM - Gemma 4 (fastest)
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\serve-model.ps1" gemma4
echo.
echo  Gemma 4 is on http://127.0.0.1:8083/v1   (model id: gemma-4-e4b)
echo  74 t/s at its full 131k context, 130 ms to first token, tool calls work.
echo.
pause
