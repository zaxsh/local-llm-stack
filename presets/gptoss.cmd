@echo off
title llama.cpp - gptoss
cd /d "%~dp0.."

REM only one model fits in 8 GB of VRAM - clear the previous one first
taskkill /IM llama-server.exe /F >nul 2>&1

echo.
echo   gptoss  ->  http://127.0.0.1:8082/
echo   model id: gpt-oss-20b    context: 24576    n-cpu-moe: 14
echo.
echo   The chat page opens in your browser in a few seconds. Ctrl+C here to stop.
echo.

REM open the built-in web UI once the server has had time to load
start "" cmd /c "timeout /t 8 >nul & start http://127.0.0.1:8082"

"%~dp0..\llama-server.exe" ^
  -m models\gpt-oss-20b-MXFP4.gguf ^
  --alias gpt-oss-20b ^
  --host 127.0.0.1 --port 8082 ^
  -c 24576 ^
  --jinja --metrics --no-warmup ^
  -t 20 -tb 20 ^
  -ngl 99 -fa on -ctk f16 -ctv f16 ^
  --n-cpu-moe 14
