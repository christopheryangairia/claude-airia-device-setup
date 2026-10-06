#!/usr/bin/env bash
# =============================================================================
# Airia — Claude Desktop Gateway Setup
#
# Purpose:
#   This script sets up Claude Desktop to run through the Airia inference
#   gateway for a specific user. It will:
#     1. Ask for / infer the Airia region (from a BASE_URL like the one in
#        run.sh, e.g. https://sg01.api.airia.ai -> region "sg01")
#     2. Ask for the AI Gateway URL (suggesting the standard pattern for the
#        detected region: https://<region>.gateway.airia.ai/)
#     3. Ask for the user's email address
#     4. Request a personal Gateway API key from Airia (User key type) using
#        that email
#     5. Derive the OTLP endpoint from the same BASE_URL, and ask for the
#        OTLP API key (X-API-Key header used for telemetry ingestion)
#     6. Optionally ask for an MCP server name + URL to manage
#     7. Ask whether users may import/export their Claude data
#     8. Fill in the Windows (.reg) and/or macOS (.mobileconfig) config
#        template with all of the above
#     9. Save the finished, ready-to-install file(s) to ./generated/
#
# Requires: bash, curl, perl. jq is optional but recommended (falls back to
#           grep). iconv is required to safely edit the UTF-16 .reg file.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${ROOT_DIR}/generated"

REG_TEMPLATE="${ROOT_DIR}/templates/Claude.reg"
MOBILECONFIG_TEMPLATE="${ROOT_DIR}/templates/Claude.mobileconfig"

# -----------------------------------------------------------------------------
# Fixed admin credentials used only to mint a personal user API key.
# These are tied to a specific Airia gateway configuration — update them if
# your organization uses a different admin key / configuration id.
# -----------------------------------------------------------------------------
MINT_API_KEY=""
GATEWAY_CONFIGURATION_ID=""
KEY_TYPE="User"
ENABLED="true"

# Load .env file if present using a safe parser. Accepts lines like:
#   MINT_API_KEY=ak-...
#   GATEWAY_CONFIGURATION_ID=...
# Blank lines and lines starting with # are ignored. Surrounding quotes
# around values (single or double) are removed. Parsed values are exported
# into this process environment so the rest of the script can read them via
# $MINT_API_KEY etc.
ENV_FILE="${ROOT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  echo "Loading environment from ${ENV_FILE}"
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # strip comments and trim whitespace
    line="${_line%%#*}"
    line="$(echo -e "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "${line}" ]] && continue
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # remove surrounding quotes if present (use literal prefix/suffix
      # stripping — quoting parts of a bash [[ =~ ]] regex makes them
      # literal, not capture groups, so a regex-based strip here would
      # never match and the quotes would stay embedded in the value).
      if [[ "${val}" == \"*\" && "${val}" == *\" ]]; then
        val="${val#\"}"
        val="${val%\"}"
      elif [[ "${val}" == \'*\' && "${val}" == *\' ]]; then
        val="${val#\'}"
        val="${val%\'}"
      fi
      export "${name}=${val}"
    fi
  done < "${ENV_FILE}"
fi

# Read values from environment (either from .env or external env)
MINT_API_KEY="${MINT_API_KEY:-}"
GATEWAY_CONFIGURATION_ID="${GATEWAY_CONFIGURATION_ID:-}"

if [[ -z "${MINT_API_KEY}" || -z "${GATEWAY_CONFIGURATION_ID}" ]]; then
  echo "Warning: MINT_API_KEY and/or GATEWAY_CONFIGURATION_ID are not set." >&2
  echo "Create a .env file in the project root with:" >&2
  echo "  MINT_API_KEY=ak-..." >&2
  echo "  GATEWAY_CONFIGURATION_ID=..." >&2
fi

echo "============================================================"
echo " Claude Desktop — Airia Gateway Setup"
echo "============================================================"
echo "This will request a personal Airia gateway API key for a user"
echo "and generate a ready-to-install Claude Desktop config file"
echo "(Windows .reg and/or macOS .mobileconfig) with that key baked in."
echo ""

# -----------------------------------------------------------------------------
# 1. Ask for / infer the region from a BASE_URL (same value used in run.sh)
# -----------------------------------------------------------------------------
read -rp "Enter your Airia BASE_URL (same as BASE_URL in run.sh, e.g. https://sg01.api.airia.ai): " BASE_URL_INPUT
BASE_URL_INPUT="${BASE_URL_INPUT%/}"
if [[ -z "${BASE_URL_INPUT}" ]]; then
  echo "Error: BASE_URL is required." >&2
  exit 1
fi

REGION=""
if [[ "${BASE_URL_INPUT}" =~ ^https?://([A-Za-z0-9-]+)\.api\.airia\.ai$ ]]; then
  REGION="$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  echo ""
  echo "Detected region: ${REGION}"
else
  echo ""
  echo "Could not auto-detect a standard region (expected <region>.api.airia.ai)."
  echo "Treating this as a custom endpoint."
fi

read -rp "Region${REGION:+ (detected: ${REGION})} — press Enter to accept, or type a custom region code: " REGION_OVERRIDE
if [[ -n "${REGION_OVERRIDE}" ]]; then
  REGION="$(echo "${REGION_OVERRIDE}" | tr '[:upper:]' '[:lower:]')"
fi

BASE_URL="${BASE_URL_INPUT}"
echo "Using BASE_URL: ${BASE_URL}"
echo ""

# App/UI host (used later to build a deep link into Secure > Gateway).
if [[ -n "${REGION}" ]]; then
  APP_BASE_URL="https://${REGION}.airia.ai"
else
  APP_BASE_URL="${BASE_URL/.api./.}"
fi

# -----------------------------------------------------------------------------
# 2. Ask for the AI Gateway URL
# -----------------------------------------------------------------------------
echo "Go to the Airia Platform > Gateway settings to retrieve your AI Gateway"
echo "URL. If you don't have access, ask your Admin."
if [[ -n "${REGION}" ]]; then
  SUGGESTED_GATEWAY="https://${REGION}.gateway.airia.ai"
  echo "Based on region '${REGION}', it is likely: ${SUGGESTED_GATEWAY}/"
  read -rp "Enter the AI Gateway URL [${SUGGESTED_GATEWAY}]: " GATEWAY_INPUT
  AIRIA_AI_GATEWAY="${GATEWAY_INPUT:-${SUGGESTED_GATEWAY}}"
else
  read -rp "Enter the AI Gateway URL: " AIRIA_AI_GATEWAY
fi
AIRIA_AI_GATEWAY="${AIRIA_AI_GATEWAY%/}"
if [[ -z "${AIRIA_AI_GATEWAY}" ]]; then
  echo "Error: AI Gateway URL is required." >&2
  exit 1
fi
echo "Using AI Gateway URL: ${AIRIA_AI_GATEWAY}"
echo ""

# -----------------------------------------------------------------------------
# 3. Ask for email
# -----------------------------------------------------------------------------
read -rp "Enter the user's email address: " USER_EMAIL
if [[ -z "${USER_EMAIL}" ]]; then
  echo "Error: email address is required." >&2
  exit 1
fi

# Derive initials from the email's local part (used for output filenames)
derive_initials() {
  local local_part="$1"
  local initials=""

  if [[ "${local_part}" == *[._-]* ]]; then
    IFS='._-' read -ra parts <<< "${local_part}"
    for part in "${parts[@]}"; do
      [[ -n "${part}" ]] || continue
      initials="${initials}${part:0:1}"
      if [[ ${#initials} -ge 2 ]]; then
        break
      fi
    done
  fi

  if [[ ${#initials} -lt 2 ]]; then
    initials="${local_part:0:2}"
  fi

  echo "${initials}" | tr '[:lower:]' '[:upper:]'
}

LOCAL_PART="${USER_EMAIL%@*}"
INITIALS="$(derive_initials "${LOCAL_PART}")"

read -rp "Derived initials for filenames: ${INITIALS}  (press Enter to accept, or type your own): " INITIALS_OVERRIDE
if [[ -n "${INITIALS_OVERRIDE}" ]]; then
  INITIALS="$(echo "${INITIALS_OVERRIDE}" | tr '[:lower:]' '[:upper:]')"
fi

echo ""
echo "Using email:    ${USER_EMAIL}"
echo "Using initials: ${INITIALS}"
echo ""

# -----------------------------------------------------------------------------
# 3b. Resolve the user's platform id (used for duplicate-key + access checks)
# -----------------------------------------------------------------------------
USERS_ENDPOINT="${BASE_URL}/v1/Users"

resolve_user_id() {
  local page=1 page_size=100 max_pages=20
  while (( page <= max_pages )); do
    local resp id item_count
    resp=$(curl --silent --show-error \
      --request GET \
      --url "${USERS_ENDPOINT}?pageSize=${page_size}&pageNumber=${page}" \
      --header "X-API-Key: ${MINT_API_KEY}" 2>/dev/null)

    if command -v jq &>/dev/null; then
      id=$(echo "${resp}" | jq -r --arg email "${USER_EMAIL}" \
        '.items[]? | select((.email // "" | ascii_downcase) == ($email | ascii_downcase)) | .id' 2>/dev/null | head -n1) || true
      item_count=$(echo "${resp}" | jq -r '.items | length' 2>/dev/null) || true
    elif command -v python3 &>/dev/null; then
      id=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
email = sys.argv[2].lower()
items = data.get('items', [])
for u in items:
    if (u.get('email') or '').lower() == email:
        print(u.get('id', ''))
        break
" "${resp}" "${USER_EMAIL}")
      item_count="${page_size}"
    else
      id=""
      item_count="0"
    fi

    if [[ -n "${id}" ]]; then
      echo "${id}"
      return 0
    fi
    [[ -z "${item_count}" || "${item_count}" -lt "${page_size}" ]] && break
    page=$((page + 1))
  done
  echo ""
}

echo "Looking up '${USER_EMAIL}' in the tenant user directory..."
GATEWAY_USER_ID="$(resolve_user_id)"
echo ""

# -----------------------------------------------------------------------------
# 3c. Check for an existing gateway API key for this user before minting a
#     new one. GET /v1/GatewayConfiguration/{id} lists apiKeys[] (masked
#     values only) with a resourceId matching the platform user id above.
#     GET /v1/GatewayApiKey/{keyId} can return the full value, but has proven
#     unreliable (404s on some otherwise-valid, enabled keys) — if it fails
#     we fall back to minting a new key rather than blocking.
# -----------------------------------------------------------------------------
USER_API_KEY=""
if [[ -n "${GATEWAY_USER_ID}" ]]; then
  echo "Checking for existing gateway API keys for ${USER_EMAIL}..."
  CONFIG_RESPONSE=$(curl --silent --show-error \
    --request GET \
    --url "${BASE_URL}/v1/GatewayConfiguration/${GATEWAY_CONFIGURATION_ID}" \
    --header "X-API-Key: ${MINT_API_KEY}" 2>/dev/null)

  if command -v jq &>/dev/null; then
    EXISTING_KEY_IDS=$(echo "${CONFIG_RESPONSE}" | jq -r --arg uid "${GATEWAY_USER_ID}" \
      '.apiKeys[]? | select(.resourceId == $uid and .enabled == true) | .id' 2>/dev/null) || true
  elif command -v python3 &>/dev/null; then
    EXISTING_KEY_IDS=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
uid = sys.argv[2]
for k in data.get('apiKeys', []):
    if k.get('resourceId') == uid and k.get('enabled'):
        print(k.get('id', ''))
" "${CONFIG_RESPONSE}" "${GATEWAY_USER_ID}")
  else
    EXISTING_KEY_IDS=""
  fi

  if [[ -n "${EXISTING_KEY_IDS}" ]]; then
    EXISTING_KEY_COUNT=$(echo "${EXISTING_KEY_IDS}" | wc -l | tr -d ' ')
    echo "User API key detected: found ${EXISTING_KEY_COUNT} existing enabled gateway API key(s) for '${USER_EMAIL}'."
    read -rp "Use an existing key instead of creating another? [y/N]: " REUSE_CHOICE
    if [[ "${REUSE_CHOICE}" =~ ^[Yy] ]]; then
      REUSE_KEY_ID=$(echo "${EXISTING_KEY_IDS}" | head -n1)
      FETCHED=$(curl --silent --show-error \
        --request GET \
        --url "${BASE_URL}/v1/GatewayApiKey/${REUSE_KEY_ID}" \
        --header "X-API-Key: ${MINT_API_KEY}" 2>/dev/null)
      if command -v jq &>/dev/null; then
        FETCHED_KEY=$(echo "${FETCHED}" | jq -r '.apiKey // empty' 2>/dev/null) || true
      else
        FETCHED_KEY=$(echo "${FETCHED}" | grep -o '"apiKey":"[^"]*"' | cut -d'"' -f4)
      fi

      if [[ -n "${FETCHED_KEY}" && "${FETCHED_KEY}" == *"•"* ]]; then
        echo "The retrieved key value is masked/obfuscated: ${FETCHED_KEY}"
        read -rp "Paste the real key manually (or leave blank to create a new one instead): " MANUAL_KEY
        if [[ -n "${MANUAL_KEY}" ]]; then
          USER_API_KEY="${MANUAL_KEY}"
          echo "Using manually entered key."
        else
          echo "No key entered — a new key will be created instead."
        fi
      elif [[ -n "${FETCHED_KEY}" ]]; then
        USER_API_KEY="${FETCHED_KEY}"
        echo "Reusing existing gateway API key."
      else
        echo "Warning: could not retrieve the existing key's value via the API — a new key will be created instead." >&2
      fi
    fi
  fi
fi
echo ""

# -----------------------------------------------------------------------------
# 4. Create the gateway API key (skipped if an existing key was reused above)
# -----------------------------------------------------------------------------
if [[ -z "${USER_API_KEY}" ]]; then
  echo "Requesting gateway API key from Airia..."

  ENDPOINT="${BASE_URL}/v1/GatewayApiKey"

  BODY=$(cat <<EOF
{
  "gatewayConfigurationId": "${GATEWAY_CONFIGURATION_ID}",
  "type": "${KEY_TYPE}",
  "enabled": ${ENABLED},
  "email": "${USER_EMAIL}"
}
EOF
  )

  HTTP_RESPONSE=$(curl --silent --show-error \
    --request POST \
    --url "${ENDPOINT}" \
    --header "Content-Type: application/json" \
    --header "X-API-Key: ${MINT_API_KEY}" \
    --data "${BODY}" \
    --write-out "\n%{http_code}" 2>/dev/null)

  HTTP_STATUS=$(echo "${HTTP_RESPONSE}" | tail -n1)
  RESPONSE=$(echo "${HTTP_RESPONSE}" | sed '$d')

  if [[ "${HTTP_STATUS}" -lt 200 || "${HTTP_STATUS}" -ge 300 ]]; then
    echo "Error: gateway API key request failed (HTTP ${HTTP_STATUS})." >&2
    echo "Response: ${RESPONSE}" >&2
    exit 1
  fi

  if command -v jq &>/dev/null; then
    USER_API_KEY=$(echo "${RESPONSE}" | jq -r '.apiKey // empty')
  else
    USER_API_KEY=$(echo "${RESPONSE}" | grep -o '"apiKey":"[^"]*"' | cut -d'"' -f4)
  fi

  if [[ -z "${USER_API_KEY}" ]]; then
    echo "Error: could not extract apiKey from response." >&2
    echo "Response: ${RESPONSE}" >&2
    exit 1
  fi

  echo "API key created successfully."
fi
echo ""

# -----------------------------------------------------------------------------
# 4b. Verify the user has gateway access (checks users-access list)
#     users-access only returns gatewayUserId (no email); GATEWAY_USER_ID was
#     already resolved above, so we just check whether that id appears as a
#     gatewayUserId in the gateway's users-access list.
# -----------------------------------------------------------------------------
ACCESS_ENDPOINT="${BASE_URL}/v1/GatewayConfiguration/${GATEWAY_CONFIGURATION_ID}/users-access"
GATEWAY_EDIT_URL="${APP_BASE_URL}/gateway/ai/${GATEWAY_CONFIGURATION_ID}/edit?pageNumber=1&pageSize=50"

check_gateway_access_for_id() {
  local user_id="$1"
  [[ -z "${user_id}" ]] && return 1
  local resp
  resp=$(curl --silent --show-error \
    --request GET \
    --url "${ACCESS_ENDPOINT}?pageNumber=1&pageSize=1000" \
    --header "X-API-Key: ${MINT_API_KEY}" 2>/dev/null)
  [[ "${resp}" == *"\"gatewayUserId\":\"${user_id}\""* ]]
}

if [[ -z "${GATEWAY_USER_ID}" ]]; then
  echo "Could not find '${USER_EMAIL}' in the tenant user directory (Users list) — cannot verify gateway access automatically."
  echo "Please go to: Secure > Gateway > set the user access to this email."
  echo "  ${GATEWAY_EDIT_URL}"
  read -rp "Have you done it? [y/N]: " ACCESS_CONFIRM
  if [[ ! "${ACCESS_CONFIRM}" =~ ^[Yy] ]]; then
    echo "Warning: continuing without confirmed gateway access." >&2
  fi
elif check_gateway_access_for_id "${GATEWAY_USER_ID}"; then
  echo "User verified to have access. Proceeding..."
else
  echo "User '${USER_EMAIL}' was not found in the gateway access list."
  echo "Please go to: Secure > Gateway > set the user access to this email."
  echo "  ${GATEWAY_EDIT_URL}"
  while true; do
    read -rp "Have you done it? [y/N]: " ACCESS_CONFIRM
    if [[ "${ACCESS_CONFIRM}" =~ ^[Yy] ]]; then
      if check_gateway_access_for_id "${GATEWAY_USER_ID}"; then
        echo "User verified to have access. Proceeding..."
        break
      else
        echo "Still not finding '${USER_EMAIL}' in the access list. Please double-check and try again."
      fi
    else
      echo "Warning: continuing without confirmed gateway access." >&2
      break
    fi
  done
fi
echo ""

# -----------------------------------------------------------------------------
# 5. OTLP endpoint (derived from BASE_URL) + OTLP API key
#    Defaults to the same admin key used to mint the gateway key (MINT_API_KEY)
#    unless the user wants to provide a separate one for telemetry ingestion.
# -----------------------------------------------------------------------------
OTLP_ENDPOINT_BASE="${BASE_URL}"
echo "OTLP endpoint will be: ${OTLP_ENDPOINT_BASE}/v1/ClaudeCodeOtelIngest/ingest"

read -rp "Provide a separate OTLP API key (X-API-Key header for telemetry ingestion)? [y/N]: " OTLP_KEY_CHOICE
if [[ "${OTLP_KEY_CHOICE}" =~ ^[Yy] ]]; then
  read -rp "Enter the OTLP API key: " OTLP_API_KEY
  if [[ -z "${OTLP_API_KEY}" ]]; then
    echo "Error: OTLP API key is required if you opt to provide one." >&2
    exit 1
  fi
else
  OTLP_API_KEY="${MINT_API_KEY}"
  echo "Using the same key as MINT_API_KEY for OTLP ingestion."
fi
echo ""

# -----------------------------------------------------------------------------
# 6. Optional MCP server
# -----------------------------------------------------------------------------
MCP_ENABLED="false"
MCP_NAME=""
MCP_URL=""
read -rp "Set up a managed MCP server? [y/N]: " MCP_CHOICE
if [[ "${MCP_CHOICE}" =~ ^[Yy] ]]; then
  MCP_ENABLED="true"
  read -rp "MCP server name: " MCP_NAME
  read -rp "MCP server URL: " MCP_URL
  if [[ -z "${MCP_NAME}" || -z "${MCP_URL}" ]]; then
    echo "Error: MCP server name and URL are both required if you opt in." >&2
    exit 1
  fi
fi
echo ""

# -----------------------------------------------------------------------------
# 7. Claude data import / export
#    Controls whether users may import their existing Claude.ai history (and
#    third-party history, e.g. ChatGPT) into this managed install, and whether
#    they may export their data back out. Written as a single JSON policy blob
#    (claudeAiImport). Declining writes an explicit "everything false" policy
#    rather than omitting the key, so the deny is deliberate instead of relying
#    on whatever the app defaults to.
# -----------------------------------------------------------------------------
read -rp "Allow users to import their data into Claude (and export it out)? [y/N]: " IMPORT_EXPORT_CHOICE
if [[ "${IMPORT_EXPORT_CHOICE}" =~ ^[Yy] ]]; then
  CLAUDE_AI_IMPORT='{"enabled":true,"automatic3pImport":true,"exportEnabled":true,"bannerBehavior":"show"}'
  echo "Data import/export: enabled."
else
  CLAUDE_AI_IMPORT='{"enabled":false,"automatic3pImport":false,"exportEnabled":false,"bannerBehavior":"hide"}'
  echo "Data import/export: disabled."
fi
echo ""

# -----------------------------------------------------------------------------
# 8. Ask which platform config(s) to generate
# -----------------------------------------------------------------------------
echo "Which config file should be generated?"
echo "  1) Windows (.reg)"
echo "  2) macOS (.mobileconfig)"
echo "  3) Both"
read -rp "Choose [1/2/3]: " PLATFORM_CHOICE

mkdir -p "${OUT_DIR}"

# -----------------------------------------------------------------------------
# 9. Fill templates
# -----------------------------------------------------------------------------

# Safely replace a literal (non-regex) token in a file, using perl so that
# values containing sed/regex metacharacters (URLs, JSON, etc.) are handled
# correctly.
replace_token() {
  local file="$1" token="$2" value="$3"
  perl -e '
    my ($file, $token, $value) = @ARGV;
    open(my $fh, "<", $file) or die $!;
    local $/;
    my $content = <$fh>;
    close $fh;
    $content =~ s/\Q$token\E/$value/g;
    open(my $out, ">", $file) or die $!;
    print $out $content;
    close $out;
  ' "${file}" "${token}" "${value}"
}

if [[ "${MCP_ENABLED}" == "true" ]]; then
  MCP_ARRAY_PLAIN="[{\"name\":\"${MCP_NAME}\",\"transport\":\"http\",\"url\":\"${MCP_URL}\",\"oauth\":{\"mode\":\"dcr\"}}]"
else
  MCP_ARRAY_PLAIN="[]"
fi

generate_mobileconfig() {
  local out_file="${OUT_DIR}/${INITIALS}_claude.mobileconfig"

  if [[ ! -f "${MOBILECONFIG_TEMPLATE}" ]]; then
    echo "Error: template not found at ${MOBILECONFIG_TEMPLATE}" >&2
    return 1
  fi

  cp "${MOBILECONFIG_TEMPLATE}" "${out_file}"

  replace_token "${out_file}" '<AIRIA-AI-GATEWAY>' "${AIRIA_AI_GATEWAY}"
  replace_token "${out_file}" '<USER-API-KEY>' "${USER_API_KEY}"
  replace_token "${out_file}" '<OTLP-ENDPOINT>' "${OTLP_ENDPOINT_BASE}"
  replace_token "${out_file}" '<OTLP-API-KEY>' "${OTLP_API_KEY}"
  replace_token "${out_file}" '<USER-EMAIL>' "${USER_EMAIL}"
  replace_token "${out_file}" '<CLAUDE-AI-IMPORT>' "${CLAUDE_AI_IMPORT}"
  replace_token "${out_file}" '[{"name":"<MCP-SERVER-NAME>","transport":"http","url":"<MCP-URL>","oauth":{"mode":"dcr"}}]' "${MCP_ARRAY_PLAIN}"

  echo "Created: ${out_file}"
}

generate_reg() {
  local out_file="${OUT_DIR}/${INITIALS}_claude.reg"

  if [[ ! -f "${REG_TEMPLATE}" ]]; then
    echo "Error: template not found at ${REG_TEMPLATE}" >&2
    return 1
  fi

  if ! command -v iconv &>/dev/null; then
    echo "Error: iconv is required to edit the UTF-16 .reg file but was not found." >&2
    return 1
  fi

  # .reg file is UTF-16LE with BOM. Convert to UTF-8, do the substitutions,
  # then convert back to UTF-16LE with BOM so it stays a valid, double-
  # clickable Windows registry file.
  local tmp_utf8
  tmp_utf8="$(mktemp)"

  iconv -f UTF-16LE -t UTF-8 "${REG_TEMPLATE}" > "${tmp_utf8}"

  local mcp_array_escaped
  if [[ "${MCP_ENABLED}" == "true" ]]; then
    mcp_array_escaped="[{\\\"name\\\":\\\"${MCP_NAME}\\\",\\\"transport\\\":\\\"http\\\",\\\"url\\\":\\\"${MCP_URL}\\\",\\\"oauth\\\":{\\\"mode\\\":\\\"dcr\\\"}}]"
  else
    mcp_array_escaped="[]"
  fi

  # The .reg format wraps values in double quotes, so any quote inside a JSON
  # blob has to be backslash-escaped.
  local claude_ai_import_escaped="${CLAUDE_AI_IMPORT//\"/\\\"}"

  replace_token "${tmp_utf8}" '<AIRIA-AI-GATEWAY>' "${AIRIA_AI_GATEWAY}"
  replace_token "${tmp_utf8}" '<USER-API-KEY>' "${USER_API_KEY}"
  replace_token "${tmp_utf8}" '<OTLP-ENDPOINT>' "${OTLP_ENDPOINT_BASE}"
  replace_token "${tmp_utf8}" '<OTLP-API-KEY>' "${OTLP_API_KEY}"
  replace_token "${tmp_utf8}" '<USER-EMAIL>' "${USER_EMAIL}"
  replace_token "${tmp_utf8}" '<CLAUDE-AI-IMPORT>' "${claude_ai_import_escaped}"
  replace_token "${tmp_utf8}" '[{\"name\":\"<MCP-SERVER-NAME>\",\"transport\":\"http\",\"url\":\"<MCP-URL>\",\"oauth\":{\"mode\":\"dcr\"}}]' "${mcp_array_escaped}"

  iconv -f UTF-8 -t UTF-16LE "${tmp_utf8}" > "${out_file}"

  rm -f "${tmp_utf8}"

  echo "Created: ${out_file}"
}

case "${PLATFORM_CHOICE}" in
  1)
    generate_reg
    ;;
  2)
    generate_mobileconfig
    ;;
  3)
    generate_reg
    generate_mobileconfig
    ;;
  *)
    echo "Error: invalid choice '${PLATFORM_CHOICE}'." >&2
    exit 1
    ;;
esac

echo ""
echo "============================================================"
echo " Done."
echo " These file(s) contain live API keys — treat them like"
echo " passwords. Do not commit them to source control or share"
echo " them outside of delivering them to the intended user."
echo "============================================================"
