@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "setup_claude.ps1"
pause