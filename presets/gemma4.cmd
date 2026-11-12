@echo off
title llama.cpp - gemma4
cd /d "%~dp0.."

REM only one model fits in 8 GB of VRAM - clear the previous one first
taskkill /IM llama-server.exe /F >nul 2>&1

echo.
echo   gemma4  ->  http://127.0.0.1:8083/
echo   model id: gemma-4-e4b    context: 131072    n-cpu-moe: 0
echo   tools: rea  (REA - pick them per chat in the Web UI)
echo.
echo   The chat page opens in your browser in a few seconds. Ctrl+C here to stop.
echo.

REM open the built-in web UI once the server has had time to load
start "" cmd /c "timeout /t 8 >nul & start http://127.0.0.1:8083"

"%~dp0..\llama-server.exe" ^
  -m models\gemma-4-E4B-it-q4kxl.gguf ^
  --alias gemma-4-e4b ^
  --host 127.0.0.1 --port 8083 ^
  -c 131072 ^
  --jinja --metrics --no-warmup ^
  -t 20 -tb 20 ^
  -ngl 99 -fa on -ctk f16 -ctv f16 ^
  --mcp-servers-config mcp\rea-mcp.json
