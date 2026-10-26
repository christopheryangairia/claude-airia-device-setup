@echo off
rem Installs the Airia credential helper and imports the Claude Desktop policy.
rem Double-click to run; it asks for administrator approval.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "KIT_DIR=%~dp0"
set "HELPER_DIR=%ProgramFiles%\Airia"

if not exist "%KIT_DIR%airia-claude-cred-helper.ps1" (
    echo Missing airia-claude-cred-helper.ps1. Extract the whole zip first, then run this again.
    pause
    exit /b 1
)

echo Step 1/2: installing the credential helper to %HELPER_DIR%
if not exist "%HELPER_DIR%" mkdir "%HELPER_DIR%"
copy /Y "%KIT_DIR%airia-claude-cred-helper.ps1" "%HELPER_DIR%\" >nul || goto :fail
powershell -NoProfile -Command "Unblock-File -Path '%HELPER_DIR%\airia-claude-cred-helper.ps1'"
echo Installed.
echo.

echo Step 2/2: importing the Claude Desktop policy
set "REG_FILE="
for %%f in ("%KIT_DIR%*.reg") do set "REG_FILE=%%f"
if not defined REG_FILE (
    echo No .reg file found next to this script.
    goto :fail
)
reg import "%REG_FILE%" || goto :fail
echo Imported.
echo.

echo To finish:
echo   1. Quit Claude Desktop completely (right-click its tray icon, Quit) if it is open, then open it again.
echo   2. A browser tab opens for a one-time Claude sign-in. Sign in with your own
echo      Claude account and click Authorize. It may open behind Claude Desktop.
echo      Claude shows "Running credential helper..." until you finish.
echo.
pause
exit /b 0

:fail
echo.
echo Install failed. Send a screenshot of this window to your IT admin.
pause
exit /b 1
