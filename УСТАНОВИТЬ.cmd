@echo off
rem Second Brain installer: runs setup.ps1 next to this file.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
