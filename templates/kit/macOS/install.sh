#!/bin/bash
# Installs the Airia credential helper and opens the Claude Desktop profile.
# Run from Terminal:  bash <drag this file here>
# (Running it through bash avoids the Gatekeeper prompt a double-clicked,
#  downloaded script gets.)

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SRC="${KIT_DIR}/airia-claude-cred-helper"
HELPER_DST="/usr/local/bin/airia-claude-cred-helper"
PROFILE="$(ls "${KIT_DIR}"/*.mobileconfig 2>/dev/null | head -n 1)"

[[ -f "${HELPER_SRC}" ]] || { echo "Missing ${HELPER_SRC}. Unzip the whole kit and try again." >&2; exit 1; }
[[ -n "${PROFILE}" ]] || { echo "No .mobileconfig found next to this script." >&2; exit 1; }

echo "Step 1/2: installing the credential helper to ${HELPER_DST}"
echo "(macOS will ask for your Mac password.)"
sudo mkdir -p /usr/local/bin
sudo install -m 755 "${HELPER_SRC}" "${HELPER_DST}"
sudo xattr -d com.apple.quarantine "${HELPER_DST}" 2>/dev/null || true
echo "Installed."
echo ""

echo "Step 2/2: opening the Claude configuration profile"
open "${PROFILE}"
# Opening a profile only stages it; the user approves it in System Settings.
sleep 2
open "x-apple.systempreferences:com.apple.Profiles-Settings.extension" 2>/dev/null || true

cat <<'EOF'

To finish:
  1. In System Settings > General > Device Management (or "Profiles"),
     double-click "Claude Desktop Third-Party Inference (User Impersonation)",
     click Install, and enter your Mac password.
  2. Quit Claude Desktop completely (Cmd+Q) if it is open, then open it again.
  3. A browser tab opens for a one-time Claude sign-in. Sign in with your own
     Claude account and click Authorize. It may open behind Claude Desktop.
     Claude shows "Running credential helper..." until you finish.
EOF
