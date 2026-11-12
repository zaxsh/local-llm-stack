@echo off
title llama.cpp - coder
cd /d "%~dp0.."

REM only one model fits in 8 GB of VRAM - clear the previous one first
taskkill /IM llama-server.exe /F >nul 2>&1

echo.
echo   coder  ->  http://127.0.0.1:8081/
echo   model id: qwen2.5-coder-7b    context: 32768    n-cpu-moe: 0
echo   tools: none
echo.
echo   The chat page opens in your browser in a few seconds. Ctrl+C here to stop.
echo.

REM open the built-in web UI once the server has had time to load
start "" cmd /c "timeout /t 8 >nul & start http://127.0.0.1:8081"

"%~dp0..\llama-server.exe" ^
  -m models\qwen2.5-coder-7b-q4km.gguf ^
  --alias qwen2.5-coder-7b ^
  --host 127.0.0.1 --port 8081 ^
  -c 32768 ^
  --jinja --metrics --no-warmup ^
  -t 20 -tb 20 ^
  -ngl 99 -fa on -ctk f16 -ctv f16
