@echo off
rem Connects a cloud model (DeepSeek or Kimi): runs cloud.ps1 next to this file.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cloud.ps1" %*
echo.
pause
