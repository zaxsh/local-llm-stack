@echo off
title llama.cpp - qwen3
cd /d "%~dp0.."

REM only one model fits in 8 GB of VRAM - clear the previous one first
taskkill /IM llama-server.exe /F >nul 2>&1

echo.
echo   qwen3  ->  http://127.0.0.1:8081/
echo   model id: qwen3-8b    context: 16384    n-cpu-moe: 0
echo.
echo   The chat page opens in your browser in a few seconds. Ctrl+C here to stop.
echo.

REM open the built-in web UI once the server has had time to load
start "" cmd /c "timeout /t 8 >nul & start http://127.0.0.1:8081"

"%~dp0..\llama-server.exe" ^
  -m models\Qwen3-8B-Q4_K_M.gguf ^
  --alias qwen3-8b ^
  --host 127.0.0.1 --port 8081 ^
  -c 16384 ^
  --jinja --metrics --no-warmup ^
  -t 20 -tb 20 ^
  -ngl 99 -fa on -ctk f16 -ctv f16
