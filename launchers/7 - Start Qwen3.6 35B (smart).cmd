@echo off
title Local LLM - Qwen3.6 35B-A3B
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\serve-model.ps1" qwen36
echo.
echo  Qwen3.6-35B-A3B is on http://127.0.0.1:8084/v1   (model id: qwen3.6-35b-a3b)
echo  34 t/s, 2.8 s to first token, native tool calls, 20k context.
echo  MoE: 8 of 256 experts fire per token, ~84%% of the experts stream from DDR5.
echo.
pause
