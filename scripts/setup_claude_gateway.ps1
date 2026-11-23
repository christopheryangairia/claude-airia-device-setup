# =============================================================================
# Airia - Claude Desktop Gateway Setup (Windows PowerShell Version)
#
# Purpose:
#   This script sets up Claude Desktop to run through the Airia inference
#   gateway for a specific user. It will:
#     1. Ask for / infer the Airia region (from a BASE_URL like the one in
#        run.sh, e.g. https://sg01.api.airia.ai -> region "sg01")
#     2. Ask for the AI Gateway URL (suggesting the standard pattern for the
#        detected region: https://<region>.gateway.airia.ai/)
#     3. Ask for the user's email address
#     4. Have the admin paste the user's personal Gateway API key, created
#        in the Airia console (API keys can no longer mint gateway keys)
#     5. Derive the OTLP endpoint from the same BASE_URL, and ask for the
#        OTLP API key (X-API-Key header used for telemetry ingestion)
#     6. Optionally ask for an MCP server name + URL to manage
#     7. Ask whether users may import/export their Claude data
#     8. Fill in the Windows (.reg) and/or macOS (.mobileconfig) config
#        template with all of the above
#     9. Save the finished, ready-to-install file(s) to ./generated/
# =============================================================================

$ErrorActionPreference = "Stop"

$SCRIPT_DIR = $PSScriptRoot
$ROOT_DIR = Split-Path $SCRIPT_DIR -Parent
$OUT_DIR = Join-Path $ROOT_DIR "generated"

# Load environment variables from .env (if present). Keys should be named
# `MINT_API_KEY` and `GATEWAY_CONFIGURATION_ID`. Values are set in-process.
$ENV_FILE = Join-Path $ROOT_DIR ".env"
function Load-EnvFile {
    param($path)
    if (-not (Test-Path $path)) { return }
    Get-Content $path | ForEach-Object {
        # Strip inline comments (everything from an unquoted # onward), then trim.
        $line = ($_ -split '#', 2)[0].Trim()
        if ($line -eq "") { return }
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
            $name = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            # Remove surrounding quotes if present
            if ($value.StartsWith('"') -and $value.EndsWith('"')) { $value = $value.Trim('"') }
            if ($value.StartsWith("'") -and $value.EndsWith("'")) { $value = $value.Trim("'") }
            [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

Load-EnvFile $ENV_FILE

$REG_TEMPLATE = Join-Path $ROOT_DIR "templates/Claude.reg"
$MOBILECONFIG_TEMPLATE = Join-Path $ROOT_DIR "templates/Claude.mobileconfig"

# -----------------------------------------------------------------------------
# Admin config for this Airia gateway configuration. GATEWAY_CONFIGURATION_ID
# is required. MINT_API_KEY (an admin or developer API key) is optional: it's
# used only for read-only lookups (user directory, existing keys, access list)
# and as the default OTLP key. It no longer mints user keys - Airia rejects
# POST /v1/GatewayApiKey from any API key, so an admin creates the user's key
# in the console and pastes it in when prompted.
# The script will read `MINT_API_KEY` and `GATEWAY_CONFIGURATION_ID` from a
# local `.env` file (or the process environment) if set.
# -----------------------------------------------------------------------------
$MINT_API_KEY = if ($env:MINT_API_KEY) { $env:MINT_API_KEY } else { "" }
$GATEWAY_CONFIGURATION_ID = if ($env:GATEWAY_CONFIGURATION_ID) { $env:GATEWAY_CONFIGURATION_ID } else { "" }

if (-not $GATEWAY_CONFIGURATION_ID) {
    Write-Host "Warning: GATEWAY_CONFIGURATION_ID is not set. Add it to .env in the project root." -ForegroundColor Yellow
}
if (-not $MINT_API_KEY) {
    Write-Host "Note: MINT_API_KEY is not set - the user lookup and gateway-access check will be" -ForegroundColor Yellow
    Write-Host "skipped, and you'll be asked for an OTLP key directly." -ForegroundColor Yellow
}

Write-Host "============================================================"
Write-Host " Claude Desktop - Airia Gateway Setup"
Write-Host "============================================================"
Write-Host "This will take a personal Airia gateway API key for a user (created by an admin in the console)"
Write-Host "and generate a ready-to-install Claude Desktop config file"
Write-Host "(Windows .reg and/or macOS .mobileconfig) with that key baked in."
Write-Host ""

# -----------------------------------------------------------------------------
# 1. Ask for / infer the region from a BASE_URL (same value used in run.sh)
# -----------------------------------------------------------------------------
$BASE_URL_INPUT = (Read-Host "Enter your Airia BASE_URL (same as BASE_URL in run.sh, e.g. https://sg01.api.airia.ai)").TrimEnd('/')
if ([string]::IsNullOrWhiteSpace($BASE_URL_INPUT)) {
    Write-Host "Error: BASE_URL is required." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    Exit
}

$REGION = ""
if ($BASE_URL_INPUT -match '^https?://([A-Za-z0-9-]+)\.api\.airia\.ai$') {
    $REGION = $Matches[1].ToLower()
    Write-Host ""
    Write-Host "Detected region: $REGION"
} else {
    Write-Host ""
    Write-Host "Could not auto-detect a standard region (expected <region>.api.airia.ai)."
    Write-Host "Treating this as a custom endpoint."
}

$regionPrompt = if ($REGION) { "Region (detected: $REGION) - press Enter to accept, or type a custom region code" } else { "Region - press Enter to skip, or type a custom region code" }
$REGION_OVERRIDE = Read-Host $regionPrompt
if (-not [string]::IsNullOrWhiteSpace($REGION_OVERRIDE)) {
    $REGION = $REGION_OVERRIDE.ToLower()
}

$BASE_URL = $BASE_URL_INPUT
Write-Host "Using BASE_URL: $BASE_URL"
Write-Host ""

# App/UI host (used later to build a deep link into Secure > Gateway).
if ($REGION) {
    $APP_BASE_URL = "https://$REGION.airia.ai"
} else {
    $APP_BASE_URL = $BASE_URL -replace '\.api\.', '.'
}

# -----------------------------------------------------------------------------
# 2. Ask for the AI Gateway URL
# -----------------------------------------------------------------------------
Write-Host "Go to the Airia Platform > Gateway settings to retrieve your AI Gateway"
Write-Host "URL. If you don't have access, ask your Admin."
if ($REGION) {
    $SUGGESTED_GATEWAY = "https://$REGION.gateway.airia.ai"
    Write-Host "Based on region '$REGION', it is likely: $SUGGESTED_GATEWAY/"
    $GATEWAY_INPUT = Read-Host "Enter the AI Gateway URL [$SUGGESTED_GATEWAY]"
    $AIRIA_AI_GATEWAY = if ([string]::IsNullOrWhiteSpace($GATEWAY_INPUT)) { $SUGGESTED_GATEWAY } else { $GATEWAY_INPUT }
} else {
    $AIRIA_AI_GATEWAY = Read-Host "Enter the AI Gateway URL"
}
$AIRIA_AI_GATEWAY = $AIRIA_AI_GATEWAY.TrimEnd('/')
if ([string]::IsNullOrWhiteSpace($AIRIA_AI_GATEWAY)) {
    Write-Host "Error: AI Gateway URL is required." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    Exit
}
Write-Host "Using AI Gateway URL: $AIRIA_AI_GATEWAY"
Write-Host ""

# -----------------------------------------------------------------------------
# 3. Ask for email
# -----------------------------------------------------------------------------
$USER_EMAIL = Read-Host "Enter the user's email address"
if ([string]::IsNullOrWhiteSpace($USER_EMAIL)) {
    Write-Host "Error: email address is required." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    Exit
}

# Derive initials from the email's local part (used for output filenames)
$LOCAL_PART = $USER_EMAIL.Split('@')[0]
$INITIALS = ""

if ($LOCAL_PART -match '[._-]') {
    $parts = $LOCAL_PART -split '[._-]'
    foreach ($part in $parts) {
        if ($part.Length -gt 0) {
            $INITIALS += $part.Substring(0, 1)
            if ($INITIALS.Length -ge 2) { break }
        }
    }
}

if ($INITIALS.Length -lt 2) {
    if ($LOCAL_PART.Length -ge 2) {
        $INITIALS = $LOCAL_PART.Substring(0, 2)
    } else {
        $INITIALS = $LOCAL_PART
    }
}
$INITIALS = $INITIALS.ToUpper()

$INITIALS_OVERRIDE = Read-Host "Derived initials for filenames: $INITIALS  (press Enter to accept, or type your own)"
if (-not [string]::IsNullOrWhiteSpace($INITIALS_OVERRIDE)) {
    $INITIALS = $INITIALS_OVERRIDE.ToUpper()
}

Write-Host ""
Write-Host "Using email:    $USER_EMAIL"
Write-Host "Using initials: $INITIALS"
Write-Host ""

# -----------------------------------------------------------------------------
# 3b. Resolve the user's platform id (used for duplicate-key + access checks)
# -----------------------------------------------------------------------------
$USERS_ENDPOINT = "$BASE_URL/v1/Users"

function Resolve-GatewayUserId {
    $headers = @{ "X-API-Key" = $MINT_API_KEY }
    $page = 1
    $pageSize = 100
    $maxPages = 20
    while ($page -le $maxPages) {
        try {
            $resp = Invoke-RestMethod -Uri "$USERS_ENDPOINT`?pageSize=$pageSize&pageNumber=$page" -Method Get -Headers $headers
        } catch {
            return $null
        }
        $match = $resp.items | Where-Object { $_.email -and ($_.email.ToLower() -eq $USER_EMAIL.ToLower()) } | Select-Object -First 1
        if ($match) {
            return $match.id
        }
        if (-not $resp.items -or $resp.items.Count -lt $pageSize) {
            break
        }
        $page++
    }
    return $null
}

Write-Host "Looking up $USER_EMAIL in the tenant user directory..."
$GATEWAY_USER_ID = Resolve-GatewayUserId
Write-Host ""

# -----------------------------------------------------------------------------
# 3c. Verify the user has gateway access (checks users-access list)
#     users-access only returns gatewayUserId (no email); GATEWAY_USER_ID was
#     already resolved above, so we just check whether that id appears as a
#     gatewayUserId in the gateway's users-access list.
# -----------------------------------------------------------------------------
$GATEWAY_EDIT_URL = "$APP_BASE_URL/gateway/ai/$GATEWAY_CONFIGURATION_ID/edit?pageNumber=1&pageSize=50"
$ACCESS_ENDPOINT = "$BASE_URL/v1/GatewayConfiguration/$GATEWAY_CONFIGURATION_ID/users-access"

function Test-GatewayAccessForId($userId) {
    if (-not $userId) { return $false }
    $headers = @{ "X-API-Key" = $MINT_API_KEY }
    try {
        $resp = Invoke-RestMethod -Uri "$ACCESS_ENDPOINT`?pageNumber=1&pageSize=1000" -Method Get -Headers $headers
        return [bool]($resp.items | Where-Object { $_.gatewayUserId -eq $userId })
    } catch {
        return $false
    }
}

if (-not $GATEWAY_USER_ID) {
    Write-Host "Could not find '$USER_EMAIL' in the tenant user directory (Users list) - cannot verify gateway access automatically."
    Write-Host "Please go to: Secure > Gateway > set the user access to this email."
    Write-Host "  $GATEWAY_EDIT_URL"
    $ACCESS_CONFIRM = Read-Host "Have you done it? [y/N]"
    if ($ACCESS_CONFIRM -notmatch '^[Yy]') {
        Write-Host "Warning: continuing without confirmed gateway access." -ForegroundColor Yellow
    }
} elseif (Test-GatewayAccessForId $GATEWAY_USER_ID) {
    Write-Host "User verified to have access. Proceeding..."
} else {
    Write-Host "User '$USER_EMAIL' was not found in the gateway access list."
    Write-Host "Please go to: Secure > Gateway > set the user access to this email."
    Write-Host "  $GATEWAY_EDIT_URL"
    while ($true) {
        $ACCESS_CONFIRM = Read-Host "Have you done it? [y/N]"
        if ($ACCESS_CONFIRM -match '^[Yy]') {
            if (Test-GatewayAccessForId $GATEWAY_USER_ID) {
                Write-Host "User verified to have access. Proceeding..."
                break
            } else {
                Write-Host "Still not finding '$USER_EMAIL' in the access list. Please double-check and try again."
            }
        } else {
            Write-Host "Warning: continuing without confirmed gateway access." -ForegroundColor Yellow
            break
        }
    }
}
Write-Host ""

# -----------------------------------------------------------------------------
# 4. Get the user's personal gateway API key.
#    Airia no longer lets an API key (admin or developer) mint gateway keys:
#    POST /v1/GatewayApiKey returns 403 "api_key_caller_not_allowed", and
#    GET /v1/GatewayApiKey/{keyId} (which revealed an existing key's value)
#    is blocked as well. An admin signed in to the Airia console creates the
#    key there and pastes it in here. GET /v1/GatewayConfiguration/{id} still
#    works with an API key, so it's used only to warn when the user already
#    has enabled keys on this configuration.
# -----------------------------------------------------------------------------
if ($GATEWAY_USER_ID) {
    try {
        $configResponse = Invoke-RestMethod -Uri "$BASE_URL/v1/GatewayConfiguration/$GATEWAY_CONFIGURATION_ID" -Method Get -Headers @{ "X-API-Key" = $MINT_API_KEY }
    } catch {
        $configResponse = $null
    }
    $existingKeys = @()
    if ($configResponse -and $configResponse.apiKeys) {
        $existingKeys = @($configResponse.apiKeys | Where-Object { $_.resourceId -eq $GATEWAY_USER_ID -and $_.enabled })
    }
    if ($existingKeys.Count -gt 0) {
        Write-Host "Note: '$USER_EMAIL' already has $($existingKeys.Count) enabled gateway API key(s) on this configuration."
        Write-Host "If you still have one of those key values, you can paste it below instead of creating another."
        Write-Host ""
    }
}

Write-Host "An admin must create the user's gateway API key in the Airia console"
Write-Host "(API keys can no longer mint gateway keys):"
Write-Host "  1. Sign in to Airia as an admin and open: Secure > Gateway > this configuration"
Write-Host "     $GATEWAY_EDIT_URL"
Write-Host "  2. Create a new User API key for $USER_EMAIL."
Write-Host "  3. Copy the full key value when it's shown (it's typically only shown once)."
Write-Host ""
$USER_API_KEY = ""
while (-not $USER_API_KEY) {
    $secureKey = Read-Host "Paste the user's gateway API key (input hidden)" -AsSecureString
    $USER_API_KEY = ([System.Net.NetworkCredential]::new("", $secureKey).Password) -replace '\s', ''
    if (-not $USER_API_KEY) {
        Write-Host "A gateway API key is required. Create one at the link above, then paste it here." -ForegroundColor Yellow
    } elseif ($USER_API_KEY.Contains([char]0x2022)) {
        Write-Host "That looks like a masked value (contains a bullet). Copy the full key value, not the masked preview." -ForegroundColor Yellow
        $USER_API_KEY = ""
    }
}
$keyPreview = if ($USER_API_KEY.Length -gt 10) { $USER_API_KEY.Substring(0, 6) + "..." + $USER_API_KEY.Substring($USER_API_KEY.Length - 4) } else { "(short value)" }
Write-Host "Gateway API key received: $keyPreview"
Write-Host ""

# -----------------------------------------------------------------------------
# 5. OTLP endpoint (derived from BASE_URL) + OTLP API key
#    Defaults to MINT_API_KEY (the admin/developer key in .env)
#    unless the user wants to provide a separate one for telemetry ingestion.
# -----------------------------------------------------------------------------
$OTLP_ENDPOINT_BASE = $BASE_URL
Write-Host "OTLP endpoint will be: $OTLP_ENDPOINT_BASE/v1/ClaudeCodeOtelIngest/ingest"

if (-not $MINT_API_KEY) {
    Write-Host "MINT_API_KEY isn't set, so an OTLP API key must be entered directly."
    $OTLP_KEY_CHOICE = "y"
} else {
    $OTLP_KEY_CHOICE = Read-Host "Provide a separate OTLP API key (X-API-Key header for telemetry ingestion)? [y/N]"
}
if ($OTLP_KEY_CHOICE -match '^[Yy]') {
    $OTLP_API_KEY = Read-Host "Enter the OTLP API key"
    if ([string]::IsNullOrWhiteSpace($OTLP_API_KEY)) {
        Write-Host "Error: OTLP API key is required if you opt to provide one." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        Exit
    }
} else {
    $OTLP_API_KEY = $MINT_API_KEY
    Write-Host "Using the same key as MINT_API_KEY for OTLP ingestion."
}
Write-Host ""

# -----------------------------------------------------------------------------
# 6. Optional MCP server
# -----------------------------------------------------------------------------
$MCP_ENABLED = $false
$MCP_NAME = ""
$MCP_URL = ""
$MCP_CHOICE = Read-Host "Set up a managed MCP server? [y/N]"
if ($MCP_CHOICE -match '^[Yy]') {
    $MCP_ENABLED = $true
    $MCP_NAME = Read-Host "MCP server name"
    $MCP_URL = Read-Host "MCP server URL"
    if ([string]::IsNullOrWhiteSpace($MCP_NAME) -or [string]::IsNullOrWhiteSpace($MCP_URL)) {
        Write-Host "Error: MCP server name and URL are both required if you opt in." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        Exit
    }
}
Write-Host ""

# -----------------------------------------------------------------------------
# 7. Claude data import / export
#    Controls whether users may import their existing Claude.ai history (and
#    third-party history, e.g. ChatGPT) into this managed install, and whether
#    they may export their data back out. Written as a single JSON policy blob
#    (claudeAiImport). Declining writes an explicit "everything false" policy
#    rather than omitting the key, so the deny is deliberate instead of relying
#    on whatever the app defaults to.
# -----------------------------------------------------------------------------
$IMPORT_EXPORT_CHOICE = Read-Host "Allow users to import their data into Claude (and export it out)? [y/N]"
if ($IMPORT_EXPORT_CHOICE -match '^[Yy]') {
    $CLAUDE_AI_IMPORT = '{"enabled":true,"automatic3pImport":true,"exportEnabled":true,"bannerBehavior":"show"}'
    Write-Host "Data import/export: enabled."
} else {
    $CLAUDE_AI_IMPORT = '{"enabled":false,"automatic3pImport":false,"exportEnabled":false,"bannerBehavior":"hide"}'
    Write-Host "Data import/export: disabled."
}
Write-Host ""

# -----------------------------------------------------------------------------
# 8. Ask which platform config(s) to generate
# -----------------------------------------------------------------------------
Write-Host "Which config file should be generated?"
Write-Host "  1) Windows (.reg)"
Write-Host "  2) macOS (.mobileconfig)"
Write-Host "  3) Both"
$PLATFORM_CHOICE = Read-Host "Choose [1/2/3]"

if (-not (Test-Path $OUT_DIR)) {
    New-Item -ItemType Directory -Path $OUT_DIR | Out-Null
}

# -----------------------------------------------------------------------------
# 9. Fill templates
# -----------------------------------------------------------------------------
if ($MCP_ENABLED) {
    $MCP_ARRAY_PLAIN = '[{"name":"' + $MCP_NAME + '","transport":"http","url":"' + $MCP_URL + '","oauth":{"mode":"dcr"}}]'
} else {
    $MCP_ARRAY_PLAIN = '[]'
}

function Generate-MobileConfig {
    $out_file = Join-Path $OUT_DIR "${INITIALS}_claude.mobileconfig"
    if (-not (Test-Path $MOBILECONFIG_TEMPLATE)) {
        Write-Warning "Error: template not found at $MOBILECONFIG_TEMPLATE"
        return
    }

    $content = Get-Content $MOBILECONFIG_TEMPLATE -Raw
    $content = $content.Replace('<AIRIA-AI-GATEWAY>', $AIRIA_AI_GATEWAY)
    $content = $content.Replace('<USER-API-KEY>', $USER_API_KEY)
    $content = $content.Replace('<OTLP-ENDPOINT>', $OTLP_ENDPOINT_BASE)
    $content = $content.Replace('<OTLP-API-KEY>', $OTLP_API_KEY)
    $content = $content.Replace('<USER-EMAIL>', $USER_EMAIL)
    $content = $content.Replace('<CLAUDE-AI-IMPORT>', $CLAUDE_AI_IMPORT)
    $content = $content.Replace('[{"name":"<MCP-SERVER-NAME>","transport":"http","url":"<MCP-URL>","oauth":{"mode":"dcr"}}]', $MCP_ARRAY_PLAIN)

    Set-Content $out_file $content
    Write-Host "Created: $out_file"
}

function Generate-Reg {
    $out_file = Join-Path $OUT_DIR "${INITIALS}_claude.reg"
    if (-not (Test-Path $REG_TEMPLATE)) {
        Write-Warning "Error: template not found at $REG_TEMPLATE"
        return
    }

    if ($MCP_ENABLED) {
        $mcpArrayEscaped = '[{\"name\":\"' + $MCP_NAME + '\",\"transport\":\"http\",\"url\":\"' + $MCP_URL + '\",\"oauth\":{\"mode\":\"dcr\"}}]'
    } else {
        $mcpArrayEscaped = '[]'
    }

    # The .reg format wraps values in double quotes, so any quote inside a JSON
    # blob has to be backslash-escaped.
    $claudeAiImportEscaped = $CLAUDE_AI_IMPORT.Replace('"', '\"')

    $content = Get-Content $REG_TEMPLATE -Raw
    $content = $content.Replace('<AIRIA-AI-GATEWAY>', $AIRIA_AI_GATEWAY)
    $content = $content.Replace('<USER-API-KEY>', $USER_API_KEY)
    $content = $content.Replace('<OTLP-ENDPOINT>', $OTLP_ENDPOINT_BASE)
    $content = $content.Replace('<OTLP-API-KEY>', $OTLP_API_KEY)
    $content = $content.Replace('<USER-EMAIL>', $USER_EMAIL)
    $content = $content.Replace('<CLAUDE-AI-IMPORT>', $claudeAiImportEscaped)
    $content = $content.Replace('[{\"name\":\"<MCP-SERVER-NAME>\",\"transport\":\"http\",\"url\":\"<MCP-URL>\",\"oauth\":{\"mode\":\"dcr\"}}]', $mcpArrayEscaped)

    # Ensure standard Windows Registry UTF-16LE (with BOM) formatting
    [System.IO.File]::WriteAllText($out_file, $content, [System.Text.Encoding]::Unicode)
    Write-Host "Created: $out_file"
}

switch ($PLATFORM_CHOICE) {
    "1" { Generate-Reg }
    "2" { Generate-MobileConfig }
    "3" { Generate-Reg; Generate-MobileConfig }
    Default {
        Write-Host "Error: invalid choice '$PLATFORM_CHOICE'." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        Exit
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host " Done."
Write-Host " These file(s) contain live API keys - treat them like"
Write-Host " passwords. Do not commit them to source control or share"
Write-Host " them outside of delivering them to the intended user."
Write-Host "============================================================"
Read-Host "Press Enter to exit"
