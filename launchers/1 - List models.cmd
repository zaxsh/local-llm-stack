@echo off
title Local LLM - what is on disk
pwsh -NoProfile -File "%USERPROFILE%\llm\bin\serve-model.ps1" -List
echo.
echo  Start one with the numbered shortcuts. Only one model fits in 8 GB at a time.
pause
