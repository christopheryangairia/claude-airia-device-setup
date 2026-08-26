@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "setup_claude_user_impersonation.ps1"
pause
