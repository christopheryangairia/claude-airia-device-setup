# =============================================================================
# Airia - Claude Desktop Gateway Setup (User Impersonation, Windows PowerShell)
#
# Purpose:
#   Sets up Claude Desktop to run through the Airia inference gateway in
#   "User Impersonation" mode for a specific user - the user's own Anthropic
#   plan subscription (Pro/Max/Team/Enterprise) is billed, and Airia stays in
#   the request path only for routing, logging, and model allow-listing. See
#   "Claude Desktop via Airia Gateway - Formatted PDF.pdf" for background.
#
#   DIFFERENT from setup_claude.ps1 (the default gateway-key flow):
#     - The Airia-issued gateway key (minted the same way as the default
#       flow, via /v1/GatewayApiKey) goes into the x-airia-key CUSTOM HEADER,
#       not into inferenceGatewayApiKey.
#     - inferenceGatewayApiKey instead holds the USER'S OWN long-lived
#       Anthropic OAuth token (sk-ant-oat01-...), which the user must mint
#       themselves by running `claude setup-token` locally (an interactive
#       browser OAuth flow this script cannot automate) and paste in here.
#     - Models are NOT auto-discovered - the user must manually enter the
#       model names to allow (matching the Allowed Models list configured
#       on the Airia gateway side), plus whether each supports 1M context.
#
#   Steps:
#     1. Ask for / infer the Airia region (from a BASE_URL like the one in
#        run.sh, e.g. https://sg01.api.airia.ai -> region "sg01")
#     2. Ask for the AI Gateway URL
#     3. Ask for the user's email address
#     4. Request a personal Gateway API key from Airia (User key type) using
#        that email - becomes the x-airia-key custom header value
#     5. Ask for the user's Claude long-lived token (sk-ant-oat01-...) -
#        becomes inferenceGatewayApiKey
#     6. Derive the OTLP endpoint from the same BASE_URL, and ask for the
#        OTLP API key (X-API-Key header used for telemetry ingestion)
#     7. Optionally ask for an MCP server name + URL to manage
#     8. Ask the user to manually enter the list of allowed models (name +
#        whether it supports 1M context), one at a time, then confirm
#     9. Ask whether users may import/export their Claude data
#     10. Fill in the Windows (.reg) and/or macOS (.mobileconfig) config
#        template with all of the above
#     11. Save the finished, ready-to-install file(s) to ./generated/
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

$REG_TEMPLATE = Join-Path $ROOT_DIR "templates/Claude_user_impersonation.reg"
$MOBILECONFIG_TEMPLATE = Join-Path $ROOT_DIR "templates/Claude_user_impersonation.mobileconfig"

# -----------------------------------------------------------------------------
# Fixed admin credentials used only to mint the Airia gateway key that goes
# into the x-airia-key custom header. Same mechanism as setup_claude.ps1 - the
# gateway configuration behind BASE_URL/GATEWAY_CONFIGURATION_ID must have AI
# Service Authentication set to "User Impersonation" on the Airia side (that
# is configured in Airia, not here).
# -----------------------------------------------------------------------------
$MINT_API_KEY = if ($env:MINT_API_KEY) { $env:MINT_API_KEY } else { "" }
$GATEWAY_CONFIGURATION_ID = if ($env:GATEWAY_CONFIGURATION_ID) { $env:GATEWAY_CONFIGURATION_ID } else { "" }
$KEY_TYPE = "User"
$ENABLED = $true

Write-Host "============================================================"
Write-Host " Claude Desktop - Airia Gateway Setup (User Impersonation)"
Write-Host "============================================================"
Write-Host "This will request a personal Airia gateway key (for the x-airia-key"
Write-Host "header) and generate a ready-to-install Claude Desktop config file"
Write-Host "(Windows .reg and/or macOS .mobileconfig) wired for User Impersonation"
Write-Host "mode - the user's own Anthropic plan subscription is billed."
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
Write-Host "URL. If you don't have access, ask your Admin. This gateway config must"
Write-Host "have AI Service Authentication set to 'User Impersonation'."
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
$AIRIA_GATEWAY_KEY = $null
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
                    $AIRIA_GATEWAY_KEY = $MANUAL_KEY
                    Write-Host "Using manually entered key."
                } else {
                    Write-Host "No key entered - a new key will be created instead."
                }
            } elseif ($fetchedKey) {
                $AIRIA_GATEWAY_KEY = $fetchedKey
                Write-Host "Reusing existing gateway API key."
            } else {
                Write-Host "Warning: could not retrieve the existing key's value via the API - a new key will be created instead." -ForegroundColor Yellow
            }
        }
    }
}
Write-Host ""

# -----------------------------------------------------------------------------
# 4. Create the Airia gateway key (goes into the x-airia-key custom header),
#    skipped if an existing key was reused above.
# -----------------------------------------------------------------------------
if (-not $AIRIA_GATEWAY_KEY) {
    Write-Host "Requesting Airia gateway key (for x-airia-key header) from Airia..."

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
        $AIRIA_GATEWAY_KEY = $response.apiKey
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

    if ([string]::IsNullOrWhiteSpace($AIRIA_GATEWAY_KEY)) {
        Write-Host "Error: could not extract apiKey from response." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        Exit
    }

    Write-Host "Airia gateway key created successfully (will be placed in x-airia-key)."
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
# 5. Ask for the user's Claude long-lived token (goes into
#    inferenceGatewayApiKey, sent as Authorization: Bearer)
# -----------------------------------------------------------------------------
Write-Host "------------------------------------------------------------"
Write-Host " Claude long-lived token (Anthropic OAuth token)"
Write-Host "------------------------------------------------------------"
Write-Host "This script cannot mint this token for you - it requires an interactive"
Write-Host "local browser OAuth flow. On the END USER's own machine, have them run:"
Write-Host ""
Write-Host "    claude setup-token"
Write-Host ""
Write-Host "This opens claude.ai/oauth/authorize (scope: user:inference, PKCE flow)."
Write-Host "They must approve while signed in to the correct plan account"
Write-Host "(Pro/Max/Team/Enterprise). The CLI then prints a long-lived (~1 year)"
Write-Host "token that looks like: sk-ant-oat01-..."
Write-Host ""
Write-Host "Security note: treat this token like a password. Anyone holding it can"
Write-Host "consume the user's plan quota. Do not commit it to source control."
Write-Host ""
$CLAUDE_LONGLIVED_TOKEN = Read-Host "Paste the user's sk-ant-oat01-... token"
if ([string]::IsNullOrWhiteSpace($CLAUDE_LONGLIVED_TOKEN)) {
    Write-Host "Error: the Claude long-lived token is required." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    Exit
}
if (-not $CLAUDE_LONGLIVED_TOKEN.StartsWith("sk-ant-oat01-")) {
    Write-Host "Warning: this doesn't look like a sk-ant-oat01-... token. Continuing" -ForegroundColor Yellow
    Write-Host "anyway, but double check you didn't paste the ?code=... value or the" -ForegroundColor Yellow
    Write-Host "Airia gateway key by mistake." -ForegroundColor Yellow
}
Write-Host ""

# -----------------------------------------------------------------------------
# 6. OTLP endpoint (derived from BASE_URL) + OTLP API key
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
# 7. Optional MCP server
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
# 8. Manually entered model list (inferenceModels)
#    User Impersonation does not auto-discover models - the models entered
#    here must match the Allowed Models list configured on the Airia gateway
#    side (an empty allow-list there means "allow all").
# -----------------------------------------------------------------------------
Write-Host "------------------------------------------------------------"
Write-Host " Model list (inferenceModels)"
Write-Host "------------------------------------------------------------"
Write-Host "Enter the models Claude Desktop should offer. These must match the"
Write-Host "Allowed Models list configured on the Airia gateway side. Remember to"
Write-Host "include claude-haiku-4-5 (used for background tasks)."
Write-Host ""

$Models = @()

function Show-Models {
    Write-Host "Current model list:"
    if ($Models.Count -eq 0) {
        Write-Host "  (none yet)"
    } else {
        foreach ($m in $Models) {
            Write-Host "  - $($m.name) (supports1m: $($m.supports1m.ToString().ToLower()))"
        }
    }
    Write-Host ""
}

while ($true) {
    $ModelName = Read-Host "Model name (e.g. claude-sonnet-4-6), or press Enter to stop adding models"
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        if ($Models.Count -eq 0) {
            Write-Host "You must enter at least one model." -ForegroundColor Red
            continue
        }
        break
    }

    $Supports1mChoice = Read-Host "  Does '$ModelName' support 1M context (supports1m)? [y/N]"
    $Supports1m = $Supports1mChoice -match '^[Yy]'

    $Models += [PSCustomObject]@{ name = $ModelName; supports1m = $Supports1m }
    Write-Host ""
}

Show-Models

while ($true) {
    $ConfirmModels = Read-Host "Confirm this is the final model list? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($ConfirmModels) -or $ConfirmModels -match '^[Yy]') {
        if ($Models.Count -eq 0) {
            Write-Host "You must have at least one model before confirming." -ForegroundColor Red
            Write-Host ""
        } else {
            break
        }
    }

    $ExtraModel = Read-Host "Add another model? (leave blank to just remove the last one and re-confirm) Model name"
    if (-not [string]::IsNullOrWhiteSpace($ExtraModel)) {
        $ExtraSupports1mChoice = Read-Host "  Does '$ExtraModel' support 1M context (supports1m)? [y/N]"
        $ExtraSupports1m = $ExtraSupports1mChoice -match '^[Yy]'
        $Models += [PSCustomObject]@{ name = $ExtraModel; supports1m = $ExtraSupports1m }
    } elseif ($Models.Count -gt 1) {
        $Models = $Models[0..($Models.Count - 2)]
    } elseif ($Models.Count -eq 1) {
        $Models = @()
    }

    Show-Models
}

$ModelsJsonItems = $Models | ForEach-Object { '{"name":"' + $_.name + '","supports1m":' + $_.supports1m.ToString().ToLower() + '}' }
$MODELS_JSON = '[' + ($ModelsJsonItems -join ',') + ']'
Write-Host "Final inferenceModels: $MODELS_JSON"
Write-Host ""

# -----------------------------------------------------------------------------
# 9. Claude data import / export
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
# 10. Ask which platform config(s) to generate
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
# 11. Fill templates
# -----------------------------------------------------------------------------
if ($MCP_ENABLED) {
    $MCP_ARRAY_PLAIN = '[{"name":"' + $MCP_NAME + '","transport":"http","url":"' + $MCP_URL + '","oauth":{"mode":"dcr"}}]'
} else {
    $MCP_ARRAY_PLAIN = '[]'
}

function Generate-MobileConfig {
    $out_file = Join-Path $OUT_DIR "${INITIALS}_claude_impersonation.mobileconfig"
    if (-not (Test-Path $MOBILECONFIG_TEMPLATE)) {
        Write-Warning "Error: template not found at $MOBILECONFIG_TEMPLATE"
        return
    }

    $content = Get-Content $MOBILECONFIG_TEMPLATE -Raw
    $content = $content.Replace('<AIRIA-AI-GATEWAY>', $AIRIA_AI_GATEWAY)
    $content = $content.Replace('<AIRIA-GATEWAY-KEY>', $AIRIA_GATEWAY_KEY)
    $content = $content.Replace('<CLAUDE-LONGLIVED-TOKEN>', $CLAUDE_LONGLIVED_TOKEN)
    $content = $content.Replace('<OTLP-ENDPOINT>', $OTLP_ENDPOINT_BASE)
    $content = $content.Replace('<OTLP-API-KEY>', $OTLP_API_KEY)
    $content = $content.Replace('<USER-EMAIL>', $USER_EMAIL)
    $content = $content.Replace('<MODELS-JSON>', $MODELS_JSON)
    $content = $content.Replace('<CLAUDE-AI-IMPORT>', $CLAUDE_AI_IMPORT)
    $content = $content.Replace('[{"name":"<MCP-SERVER-NAME>","transport":"http","url":"<MCP-URL>","oauth":{"mode":"dcr"}}]', $MCP_ARRAY_PLAIN)

    Set-Content $out_file $content
    Write-Host "Created: $out_file"
}

function Generate-Reg {
    $out_file = Join-Path $OUT_DIR "${INITIALS}_claude_impersonation.reg"
    if (-not (Test-Path $REG_TEMPLATE)) {
        Write-Warning "Error: template not found at $REG_TEMPLATE"
        return
    }

    if ($MCP_ENABLED) {
        $mcpArrayEscaped = '[{\"name\":\"' + $MCP_NAME + '\",\"transport\":\"http\",\"url\":\"' + $MCP_URL + '\",\"oauth\":{\"mode\":\"dcr\"}}]'
    } else {
        $mcpArrayEscaped = '[]'
    }

    $modelsJsonEscaped = $MODELS_JSON.Replace('"', '\"')

    # The .reg format wraps values in double quotes, so any quote inside a JSON
    # blob has to be backslash-escaped.
    $claudeAiImportEscaped = $CLAUDE_AI_IMPORT.Replace('"', '\"')

    $content = Get-Content $REG_TEMPLATE -Raw
    $content = $content.Replace('<AIRIA-AI-GATEWAY>', $AIRIA_AI_GATEWAY)
    $content = $content.Replace('<AIRIA-GATEWAY-KEY>', $AIRIA_GATEWAY_KEY)
    $content = $content.Replace('<CLAUDE-LONGLIVED-TOKEN>', $CLAUDE_LONGLIVED_TOKEN)
    $content = $content.Replace('<OTLP-ENDPOINT>', $OTLP_ENDPOINT_BASE)
    $content = $content.Replace('<OTLP-API-KEY>', $OTLP_API_KEY)
    $content = $content.Replace('<USER-EMAIL>', $USER_EMAIL)
    $content = $content.Replace('<MODELS-JSON>', $modelsJsonEscaped)
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
Write-Host " These file(s) contain live credentials (Airia gateway key and"
Write-Host " the user's Anthropic long-lived token) - treat them like"
Write-Host " passwords. Do not commit them to source control or share"
Write-Host " them outside of delivering them to the intended user."
Write-Host "============================================================"
Read-Host "Press Enter to exit"
