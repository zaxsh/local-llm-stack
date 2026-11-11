@echo off
title llama.cpp - coder36
cd /d "%~dp0.."

REM only one model fits in 8 GB of VRAM - clear the previous one first
taskkill /IM llama-server.exe /F >nul 2>&1

echo.
echo   coder36  ->  http://127.0.0.1:8085/
echo   model id: qwen3.6-27b-a3b-coder    context: 16384    n-cpu-moe: 24
echo.
echo   The chat page opens in your browser in a few seconds. Ctrl+C here to stop.
echo.

REM open the built-in web UI once the server has had time to load
start "" cmd /c "timeout /t 8 >nul & start http://127.0.0.1:8085"

"%~dp0..\llama-server.exe" ^
  -m models\qwen3.6-27b-a3b-coder-q4km.gguf ^
  --alias qwen3.6-27b-a3b-coder ^
  --host 127.0.0.1 --port 8085 ^
  -c 16384 ^
  --jinja --metrics --no-warmup ^
  -t 16 -tb 16 ^
  -ngl 99 -fa on -ctk f16 -ctv f16 ^
  --n-cpu-moe 24
