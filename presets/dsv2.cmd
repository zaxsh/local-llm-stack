@echo off
title llama.cpp - dsv2
cd /d "%~dp0.."

REM only one model fits in 8 GB of VRAM - clear the previous one first
taskkill /IM llama-server.exe /F >nul 2>&1

echo.
echo   dsv2  ->  http://127.0.0.1:8086/
echo   model id: deepseek-coder-v2-lite    context: 18432    n-cpu-moe: 0
echo   tools: none
echo.
echo   The chat page opens in your browser in a few seconds. Ctrl+C here to stop.
echo.

REM open the built-in web UI once the server has had time to load
start "" cmd /c "timeout /t 8 >nul & start http://127.0.0.1:8086"

"%~dp0..\llama-server.exe" ^
  -m models\deepseek-coder-v2-lite-maple-sub5gb.gguf ^
  --alias deepseek-coder-v2-lite ^
  --host 127.0.0.1 --port 8086 ^
  -c 18432 ^
  --jinja --metrics --no-warmup ^
  -t 16 -tb 16 ^
  -ngl 99 -fa on -ctk q8_0 -ctv q8_0
