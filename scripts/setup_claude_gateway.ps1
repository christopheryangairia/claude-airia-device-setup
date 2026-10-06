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
#     4. Request a personal Gateway API key from Airia (User key type) using
#        that email
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
# Fixed admin credentials used only to mint a personal user API key.
# These are tied to a specific Airia gateway configuration - update them if
# your organization uses a different admin key / configuration id.
# The script will read `MINT_API_KEY` and `GATEWAY_CONFIGURATION_ID` from a
# local `.env` file (or the process environment) if set.
# -----------------------------------------------------------------------------
$MINT_API_KEY = if ($env:MINT_API_KEY) { $env:MINT_API_KEY } else { "" }
$GATEWAY_CONFIGURATION_ID = if ($env:GATEWAY_CONFIGURATION_ID) { $env:GATEWAY_CONFIGURATION_ID } else { "" }
$KEY_TYPE = "User"
$ENABLED = $true

Write-Host "============================================================"
Write-Host " Claude Desktop - Airia Gateway Setup"
Write-Host "============================================================"
Write-Host "This will request a personal Airia gateway API key for a user"
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
# 3c. Check for an existing gateway API key for this user before minting a
#     new one. GET /v1/GatewayConfiguration/{id} lists apiKeys[] (masked
#     values only) with a resourceId matching the platform user id above.
#     GET /v1/GatewayApiKey/{keyId} can return the full value, but has proven
#     unreliable (404s on some otherwise-valid, enabled keys) - if it fails we
#     fall back to minting a new key rather than blocking.
# -----------------------------------------------------------------------------
$USER_API_KEY = $null
if ($GATEWAY_USER_ID) {
    Write-Host "Checking for existing gateway API keys for $USER_EMAIL..."
    $mintHeaders = @{ "X-API-Key" = $MINT_API_KEY }
    try {
        $configResponse = Invoke-RestMethod -Uri "$BASE_URL/v1/GatewayConfiguration/$GATEWAY_CONFIGURATION_ID" -Method Get -Headers $mintHeaders
    } catch {
        $configResponse = $null
    }

    $existingKeys = @()
    if ($configResponse -and $configResponse.apiKeys) {
        $existingKeys = @($configResponse.apiKeys | Where-Object { $_.resourceId -eq $GATEWAY_USER_ID -and $_.enabled })
    }

    if ($existingKeys.Count -gt 0) {
        Write-Host "User API key detected: found $($existingKeys.Count) existing enabled gateway API key(s) for '$USER_EMAIL'."
        $REUSE_CHOICE = Read-Host "Use an existing key instead of creating another? [y/N]"
        if ($REUSE_CHOICE -match '^[Yy]') {
            $reuseKeyId = $existingKeys[0].id
            $fetchedKey = $null
            try {
                $fetched = Invoke-RestMethod -Uri "$BASE_URL/v1/GatewayApiKey/$reuseKeyId" -Method Get -Headers $mintHeaders
                $fetchedKey = $fetched.apiKey
            } catch {
                $fetchedKey = $null
            }

            if ($fetchedKey -and $fetchedKey.Contains([char]0x2022)) {
                Write-Host "The retrieved key value is masked/obfuscated: $fetchedKey"
                $MANUAL_KEY = Read-Host "Paste the real key manually (or leave blank to create a new one instead)"
                if (-not [string]::IsNullOrWhiteSpace($MANUAL_KEY)) {
                    $USER_API_KEY = $MANUAL_KEY
                    Write-Host "Using manually entered key."
                } else {
                    Write-Host "No key entered - a new key will be created instead."
                }
            } elseif ($fetchedKey) {
                $USER_API_KEY = $fetchedKey
                Write-Host "Reusing existing gateway API key."
            } else {
                Write-Host "Warning: could not retrieve the existing key's value via the API - a new key will be created instead." -ForegroundColor Yellow
            }
        }
    }
}
Write-Host ""

# -----------------------------------------------------------------------------
# 4. Create the gateway API key (skipped if an existing key was reused above)
# -----------------------------------------------------------------------------
if (-not $USER_API_KEY) {
    Write-Host "Requesting gateway API key from Airia..."

    $ENDPOINT = "$BASE_URL/v1/GatewayApiKey"
    $BODY = @{
        gatewayConfigurationId = $GATEWAY_CONFIGURATION_ID
        type                   = $KEY_TYPE
        enabled                = $ENABLED
        email                  = $USER_EMAIL
    } | ConvertTo-Json

    $headers = @{
        "Content-Type" = "application/json"
        "X-API-Key"    = $MINT_API_KEY
    }

    try {
        $response = Invoke-RestMethod -Uri $ENDPOINT -Method Post -Headers $headers -Body $BODY
        $USER_API_KEY = $response.apiKey
    } catch {
        Write-Host "Error: gateway API key request failed." -ForegroundColor Red
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            Write-Host "Response: $($reader.ReadToEnd())" -ForegroundColor Red
        } else {
            Write-Host "Exception: $($_.Exception.Message)" -ForegroundColor Red
        }
        Read-Host "Press Enter to exit"
        Exit
    }

    if ([string]::IsNullOrWhiteSpace($USER_API_KEY)) {
        Write-Host "Error: could not extract apiKey from response." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        Exit
    }

    Write-Host "API key created successfully."
}
Write-Host ""

# -----------------------------------------------------------------------------
# 4b. Verify the user has gateway access (checks users-access list)
#     users-access only returns gatewayUserId (no email); GATEWAY_USER_ID was
#     already resolved above, so we just check whether that id appears as a
#     gatewayUserId in the gateway's users-access list.
# -----------------------------------------------------------------------------
$ACCESS_ENDPOINT = "$BASE_URL/v1/GatewayConfiguration/$GATEWAY_CONFIGURATION_ID/users-access"
$GATEWAY_EDIT_URL = "$APP_BASE_URL/gateway/ai/$GATEWAY_CONFIGURATION_ID/edit?pageNumber=1&pageSize=50"

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
# 5. OTLP endpoint (derived from BASE_URL) + OTLP API key
#    Defaults to the same admin key used to mint the gateway key (MINT_API_KEY)
#    unless the user wants to provide a separate one for telemetry ingestion.
# -----------------------------------------------------------------------------
$OTLP_ENDPOINT_BASE = $BASE_URL
Write-Host "OTLP endpoint will be: $OTLP_ENDPOINT_BASE/v1/ClaudeCodeOtelIngest/ingest"

$OTLP_KEY_CHOICE = Read-Host "Provide a separate OTLP API key (X-API-Key header for telemetry ingestion)? [y/N]"
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
