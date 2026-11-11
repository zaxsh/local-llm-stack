@echo off
title Local LLM - flint 40B
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\serve-model.ps1" flint
echo.
echo  flint is on http://127.0.0.1:8080/v1   (model id: flint-nvfp4-40b)
echo  30 t/s at 49k context, 3.9 s to first token. Slowest to start, strongest reasoning.
echo.
pause
