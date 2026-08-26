# =============================================================================
# Airia - Claude Desktop Setup (mode picker, Windows PowerShell)
#
# Asks which mode to set up Claude Desktop in, then hands off to the
# corresponding script under scripts\ - the rest of the interactive flow
# (region, email, existing-key checks, OTLP, MCP, output format, etc.) is
# unchanged, just invoked from here:
#   1) Gateway            -> scripts\setup_claude_gateway.ps1
#   2) User Impersonation -> scripts\setup_claude_user_impersonation.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$SCRIPT_DIR = $PSScriptRoot

Write-Host "============================================================"
Write-Host " Claude Desktop - Airia Setup"
Write-Host "============================================================"
Write-Host "How would you like to set up Claude Desktop?"
Write-Host "  1) Gateway - Airia-minted universal key (default; Claude Desktop"
Write-Host "     auto-discovers models)"
Write-Host "  2) OAuth Passthrough / User Impersonation - bills the user's own"
Write-Host "     Anthropic plan subscription (Pro/Max/Team/Enterprise); Airia"
Write-Host "     stays in the request path for routing, logging, and model"
Write-Host "     allow-listing"
Write-Host ""
$MODE_CHOICE = Read-Host "Choose [1/2]"

switch ($MODE_CHOICE) {
    "1" { & (Join-Path $SCRIPT_DIR "scripts\setup_claude_gateway.ps1") }
    "2" { & (Join-Path $SCRIPT_DIR "scripts\setup_claude_user_impersonation.ps1") }
    Default {
        Write-Host "Error: invalid choice '$MODE_CHOICE'." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        Exit
    }
}
