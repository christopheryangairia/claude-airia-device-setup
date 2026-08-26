#!/usr/bin/env bash
# =============================================================================
# Airia — Claude Desktop Setup (mode picker)
#
# Asks which mode to set up Claude Desktop in, then hands off to the
# corresponding script under scripts/ — the rest of the interactive flow
# (region, email, existing-key checks, OTLP, MCP, output format, etc.) is
# unchanged, just invoked from here:
#   1) Gateway            -> scripts/setup_claude_gateway.sh
#   2) User Impersonation -> scripts/setup_claude_user_impersonation.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " Claude Desktop — Airia Setup"
echo "============================================================"
echo "How would you like to set up Claude Desktop?"
echo "  1) Gateway — Airia-minted universal key (default; Claude Desktop"
echo "     auto-discovers models)"
echo "  2) OAuth Passthrough / User Impersonation — bills the user's own"
echo "     Anthropic plan subscription (Pro/Max/Team/Enterprise); Airia"
echo "     stays in the request path for routing, logging, and model"
echo "     allow-listing"
echo ""
read -rp "Choose [1/2]: " MODE_CHOICE

case "${MODE_CHOICE}" in
  1)
    exec "${SCRIPT_DIR}/scripts/setup_claude_gateway.sh"
    ;;
  2)
    exec "${SCRIPT_DIR}/scripts/setup_claude_user_impersonation.sh"
    ;;
  *)
    echo "Error: invalid choice '${MODE_CHOICE}'." >&2
    exit 1
    ;;
esac
