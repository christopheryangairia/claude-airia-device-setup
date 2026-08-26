# Airia — Claude Desktop Gateway Setup

This folder contains scripts that generate a ready-to-install Claude Desktop
config file (Windows `.reg` or macOS `.mobileconfig`) that points Claude
Desktop at your organization's Airia inference gateway, wires up OTLP
telemetry, and optionally registers a managed MCP server — all for one
specific end user.

## Quick start — pick a mode, one entry point

Run whichever matches the machine you're on, from the project root:

- `./setup_claude.sh` — bash (macOS / Linux / WSL / Git Bash)
- `.\setup_claude.ps1` — PowerShell (Windows). `run.bat` is a
  double-clickable launcher for this script.

Either one asks a single question — **Gateway** (Airia-minted universal key;
Claude Desktop auto-discovers models) or **OAuth Passthrough / User
Impersonation** (bills the *user's own* Anthropic plan subscription instead
of an Airia-side key) — then hands off to the matching script under
`scripts/`. Everything from that point on (region, email, existing-key
checks, OTLP, MCP, output format) is identical to running that script
directly; see [Section 7](#7-user-impersonation-variant) for what's
different about Impersonation mode specifically.

## Folder layout

```
.
├── setup_claude.sh / setup_claude.ps1   ← start here: mode picker
├── run.bat                              ← double-click launcher for setup_claude.ps1
├── .env / .env_sample                   ← admin config, shared by every script below
├── scripts/                             ← the actual per-mode setup scripts
│   ├── setup_claude_gateway.sh / .ps1
│   ├── setup_claude_user_impersonation.sh / .ps1
│   └── run_gateway.bat / run_user_impersonation.bat  ← direct-mode launchers
├── templates/                           ← .reg / .mobileconfig templates with placeholders
│   ├── Claude.reg / Claude.mobileconfig
│   └── Claude_user_impersonation.reg / Claude_user_impersonation.mobileconfig
├── generated/                           ← output lands here regardless of entry point
└── docs/                                ← background PDF, etc.
```

You can still run `scripts/setup_claude_gateway.sh` (or the impersonation
variant) directly if you already know which mode you want — the mode picker
is purely a convenience wrapper and doesn't change any of the underlying
behavior documented below.

> Note: `symmlink-plugins.sh` is a separate, unrelated utility for symlinking
> a plugins folder from OneDrive and is not covered by this README.

---

## 1. Before you run anything — set the admin config values

Both scripts need two admin-level values filled in **once per Airia
environment/organization** before handing the script to anyone. These are not
per-user values — the script will still ask each individual user for their
own email, region, etc. separately.

**Recommended: use a `.env` file.** Copy `.env_sample` to `.env` in the
**project root** (next to `setup_claude.sh`/`.ps1`, not inside `scripts/`)
and fill in your values:

```bash
cp .env_sample .env
```

```dotenv
# .env
MINT_API_KEY="ak-..."
GATEWAY_CONFIGURATION_ID="2d25bdf7-..."

# Optional overrides — see the table below. Uncomment only if you need
# something other than the defaults.
# KEY_TYPE="User"
# ENABLED="true"
```

All four scripts under `scripts/` (`setup_claude_gateway.sh`/`.ps1` and
`setup_claude_user_impersonation.sh`/`.ps1`) automatically load `.env` from
the project root if it exists (you'll see a `Loading environment from ...`
line when they do), and export the values into the process environment
before anything else runs — this works the same whether you launched them
directly or via the `setup_claude.sh`/`.ps1` mode picker at the root. Values
may optionally be wrapped in single or double quotes — all scripts strip
them correctly. Trailing `# comments` on a line are also stripped. `.env` is
already listed in `.gitignore`, so it won't get committed by accident.

If you'd rather not use a `.env` file, you can instead hardcode the values
directly in the small constants block near the top of each script under
`scripts/`:

```bash
# scripts/setup_claude_gateway.sh
MINT_API_KEY=""
GATEWAY_CONFIGURATION_ID=""
KEY_TYPE="User"
ENABLED="true"
```

```powershell
# scripts/setup_claude_gateway.ps1
$MINT_API_KEY = if ($env:MINT_API_KEY) { $env:MINT_API_KEY } else { "" }
$GATEWAY_CONFIGURATION_ID = if ($env:GATEWAY_CONFIGURATION_ID) { $env:GATEWAY_CONFIGURATION_ID } else { "" }
$KEY_TYPE = "User"
$ENABLED = $true
```

A value set directly in the script's constants block only takes effect if
`.env` doesn't already provide it — `.env` (or the external process
environment, e.g. `export MINT_API_KEY=...` before running the script) wins
if both are present.

| Env var | What it is | Where to get it |
|---|---|---|
| `MINT_API_KEY` | **Required.** An **admin-level** Airia API key with permission to create new Gateway API keys via the `/v1/GatewayApiKey` endpoint. This is the credential the script authenticates itself with — it is not the key that ends up in the generated config file. By default it is also reused as the OTLP telemetry key (see `<OTLP-API-KEY>` below), unless the person running the script chooses to supply a different one. | Airia Platform → Gateway settings → API Keys (admin/org-owner access), or ask your Airia Admin. |
| `GATEWAY_CONFIGURATION_ID` | **Required.** The ID of the specific Gateway Configuration in Airia that the newly minted user key should belong to. Every key minted by this script is scoped to this configuration. | Airia Platform → Gateway → the specific Gateway Configuration's details page. Ask your Admin if you don't see it. |
| `KEY_TYPE` | Optional (defaults to `"User"`). The type of key to request from Airia when minting. `"User"` mints a personal, per-person key (this is what the script is designed around — each run mints one key for one email). Other values may be supported by your Airia environment (e.g. a service/team-level key type) but changing this changes what kind of key gets generated. | Leave unset/`"User"` unless your Admin tells you otherwise. |
| `ENABLED` | Optional (defaults to `"true"`). Whether the newly minted key should be **active immediately** on the gateway (`true`) or created in a disabled state (`false`) so an admin has to flip it on later. This does not affect anything already in the generated config file — it only affects whether the key actually works on Airia's side the moment it's created. | Leave unset/`"true"` for normal onboarding. Set to `false` if your process requires an admin to explicitly approve/enable new keys before they're usable. |

If your organization only has one Airia gateway configuration, you'll set
these once and never touch them again. If you support multiple environments
(e.g. separate configs for different regions or business units), keep a
separate `.env` (or a separate copy of the script with values hardcoded) per
environment.

---

## 2. What the script asks you, step by step

Running the script walks you through the following, in order. Some steps are
fully automatic, some only prompt you conditionally:

1. **BASE_URL / region** — Enter the same `BASE_URL` value used for this
   environment, e.g. `https://sg01.api.airia.ai`. The script tries to detect
   the region (`sg01`, `eu1`, etc.) from the hostname pattern
   `<region>.api.airia.ai`. If your URL doesn't match that pattern, it's
   treated as a custom endpoint and you can type a region label of your own
   (or leave it blank). This value drives the OTLP endpoint, the suggested
   Gateway URL in the next step, and the `Secure > Gateway` deep link used
   later.
2. **AI Gateway URL** — The script suggests `https://<region>.gateway.airia.ai/`
   based on the detected region, but you should confirm this against the
   actual value in **Airia Platform → Gateway**. If you don't have access,
   ask your Admin. This becomes `<AIRIA-AI-GATEWAY>` in the generated config.
3. **User's email address** — The person this config file is being generated
   for. Used to mint/reuse their personal gateway key, verify their gateway
   access, and tag their OTLP telemetry.
4. *(automatic)* — Looks up that email in the tenant's Users directory
   (`GET /v1/Users`) to resolve the person's platform user id. This id is
   what the next two checks are keyed on. If the email isn't found here
   (e.g. the person hasn't been provisioned in Airia yet), both of the
   following checks are skipped and you're asked to confirm access manually
   instead.
5. *(automatic, conditional prompt)* — **Checks for an existing gateway API
   key.** Calls `GET /v1/GatewayConfiguration/{id}` and looks for an
   already-enabled key belonging to that user id. If one (or more) exists,
   you're asked:

   > `User API key detected: found N existing enabled gateway API key(s)...`
   > `Use an existing key instead of creating another? [y/N]`

   - Answering **y** tries to fetch the real value via
     `GET /v1/GatewayApiKey/{keyId}`. This endpoint has proven unreliable in
     practice (it can 404 on a key that's otherwise valid and enabled) — if
     it fails, or returns a masked-looking value (containing `•`), you're
     asked to paste the real key manually instead; leaving that blank falls
     through to minting a brand-new key.
   - Answering **N** (or no existing key was found) proceeds to step 6 and
     mints a new key as before.
6. *(automatic, skipped if step 5 reused a key)* — Calls Airia's
   `/v1/GatewayApiKey` endpoint using `MINT_API_KEY`, `GATEWAY_CONFIGURATION_ID`,
   `KEY_TYPE`, `ENABLED`, and the email from step 3, and receives back a
   fresh personal API key for that user.
7. *(automatic, conditional prompt)* — **Verifies gateway access.** Calls
   `GET /v1/GatewayConfiguration/{id}/users-access` and checks whether the
   user id from step 4 is already on that list. If they're missing, you're
   shown a direct link into **Secure > Gateway > [config] > edit** and
   asked `Have you done it? [y/N]` — answering **y** re-checks the list
   (looping back if it's still missing); answering **N** just prints a
   warning and continues rather than blocking you.
8. **OTLP API key** — The OTLP endpoint itself is derived automatically from
   the `BASE_URL` you entered in step 1 (`<BASE_URL>/v1/ClaudeCodeOtelIngest/ingest`).
   You're then asked whether you want to provide a **separate** API key for
   OTLP telemetry ingestion. If you say no (the default), the script reuses
   `MINT_API_KEY` for this purpose. If you say yes, you'll be prompted to
   paste a distinct key.
9. **Optional MCP server** — If you want Claude Desktop to auto-connect to a
   managed MCP server for this user, say yes and provide a name and URL. If
   you decline, the config is generated with no MCP servers registered.

At the end, you choose whether to generate the Windows `.reg`, the macOS
`.mobileconfig`, or both. Output files are written to `./generated/` as
`<INITIALS>_claude.reg` / `<INITIALS>_claude.mobileconfig`, where initials
are derived from the user's email (and can be overridden).

> Steps 4, 5, and 7 all rely on the same tenant lookups and degrade
> gracefully — if `jq` and `python3` are both unavailable, or the lookups
> fail outright, the script simply skips straight to minting a new key and
> asking you to confirm access manually, rather than blocking.

---

## 3. Placeholder reference

Both `templates/Claude.reg` and `templates/Claude.mobileconfig` are templates
containing the same set of placeholders. The scripts fill in every one of
these before writing the final file to `./generated/`.

| Placeholder | Filled with | Purpose |
|---|---|---|
| `<AIRIA-AI-GATEWAY>` | The AI Gateway URL entered in step 2 | Base URL Claude Desktop sends inference (chat/completion) requests to, via Airia's gateway instead of directly to Anthropic. The template appends `/anthropic` to this value (`inferenceGatewayBaseUrl`). |
| `<USER-API-KEY>` | The personal key from step 5/6 above — either reused from an existing key (step 5) or freshly minted (step 6) | The credential Claude Desktop uses to authenticate this specific user's requests against the gateway (`inferenceGatewayApiKey`). This is the sensitive, per-user secret — treat generated files like passwords. |
| `<OTLP-ENDPOINT>` | The `BASE_URL` entered in step 1 | Base URL for OpenTelemetry (OTLP) ingestion. The template appends the fixed path `/v1/ClaudeCodeOtelIngest/ingest` to form the full `otlpEndpoint`. This is how usage/telemetry data flows back into Airia. |
| `<OTLP-API-KEY>` | Either `MINT_API_KEY` (default) or a separate key you provide in step 8 | Value sent as the `X-API-KEY` header (`otlpHeaders`) when Claude Desktop pushes telemetry to the OTLP endpoint above. |
| `<USER-EMAIL>` | The email entered in step 3 | Used to tag telemetry with the user's identity (`otlpResourceAttributes` → `airia.user-email`), and is the identity the personal API key was minted for. |
| `<MCP-SERVER-NAME>` / `<MCP-URL>` | The values entered in step 9, if you opted in | Name and URL of a managed MCP server for Claude Desktop to auto-register (`managedMcpServers`). If you decline MCP setup, this whole field is written as an empty array (`[]`) instead of leaving these placeholders unfilled. |

A few settings in the templates are **not** placeholders — they're fixed
values baked into the templates themselves and aren't touched by the script:

- `otlpProtocol` (`http/json`), `otlpContentCapture` (which content types get
  captured), `chatTabEnabled`, `coworkEgressAllowedHosts`, `inferenceProvider`
  (`gateway`), and `inferenceCredentialKind` (`static`). Edit
  `templates/Claude.reg` / `templates/Claude.mobileconfig` directly if you
  need to change any of these defaults for your organization.

---

## 4. Output & security

Generated files land in `./generated/`:

- `<INITIALS>_claude.reg` — double-click to import into
  `HKEY_CURRENT_USER\SOFTWARE\Policies\Claude` on the target Windows machine.
- `<INITIALS>_claude.mobileconfig` — install as a configuration profile on
  macOS (e.g. via System Settings, or MDM deployment).

**These files contain live, working API keys.** Treat them exactly like
passwords:

- Don't commit them to source control.
- Don't share them over channels outside of delivering the file to the
  specific intended user.
- The `./generated/` folder is a good candidate for a `.gitignore` entry if
  this repo is ever tracked in git.

---

## 5. Requirements

**`scripts/setup_claude_gateway.sh`**: `bash`, `curl`, `perl` (used for safe
literal string substitution), and `iconv` (used to safely edit the UTF‑16
`.reg` file without corrupting its encoding). `jq` is strongly recommended —
it's used to parse the `/v1/Users` and `/v1/GatewayConfiguration` responses
for the duplicate-key and access checks (steps 4/5/7 above). If `jq` isn't
installed, the script falls back to `python3` for those same lookups; if
neither is available, it falls back further to `grep`/`cut` for the basic
API key extraction and simply skips the automatic user/key matching (you'll
always be prompted to confirm access and mint a fresh key manually).

**`scripts/setup_claude_gateway.ps1`**: Windows PowerShell with internet
access to reach the `BASE_URL` you provide (uses `Invoke-RestMethod`, which
is built in — no extra dependency needed for the equivalent checks).

---

## 6. Troubleshooting

- **"gateway API key request failed (HTTP ...)"** — Check that
  `MINT_API_KEY` and `GATEWAY_CONFIGURATION_ID` are correct for the
  environment behind the `BASE_URL` you entered, and that `MINT_API_KEY`
  hasn't expired or been revoked. If you're setting these via `.env`, double
  check there's no stray whitespace or mismatched quote at the end of a line.
- **"Warning: MINT_API_KEY and/or GATEWAY_CONFIGURATION_ID are not set"**,
  or the script otherwise seems to ignore your `.env` — confirm the file is
  literally named `.env` and sits in the **project root** (next to
  `setup_claude.sh`/`.ps1`, *not* inside `scripts/`), and that you don't
  still have `.env_sample`'s placeholder values in place.
- **"iconv is required..."** — Install `iconv` (usually part of `glibc` /
  available via your package manager) before generating a `.reg` file on
  bash.
- **Generated `.reg` file won't import on Windows** — Double check it's
  still UTF‑16LE with a BOM (`file <name>.reg` should report "little-endian
  text"); this should be preserved automatically by the script, but a manual
  edit with the wrong text editor can strip it.
- **Region wasn't detected correctly** — This only matters for the
  *suggested* Gateway URL; you can always type the real one at that prompt
  regardless of what region was detected.
- **"The retrieved key value is masked/obfuscated"** — you chose to reuse an
  existing key, but Airia returned a partial/obfuscated value instead of the
  real one. Paste the real key manually if you have it (e.g. from wherever
  it was originally delivered), or leave it blank to mint a new key instead.
- **Reusing an existing key silently falls back to minting a new one** — this
  is expected if `GET /v1/GatewayApiKey/{keyId}` 404s for that key. This
  endpoint has proven unreliable even for keys that show as valid/enabled in
  `GET /v1/GatewayConfiguration/{id}`; the script treats that as "couldn't
  retrieve it" rather than an error, and mints a fresh key instead.
- **"Could not find '\<email\>' in the tenant user directory"** — the email
  doesn't have a match in `GET /v1/Users` for this tenant, so the script
  can't resolve a platform user id and skips the duplicate-key and
  access-list checks. This usually means the person hasn't been invited to
  the tenant yet — invite them first if you expect these checks to run.
- **"Still not finding '\<email\>' in the access list" / stuck in the
  access-confirmation loop** — the script re-checks
  `GET /v1/GatewayConfiguration/{id}/users-access` after you answer `y`; if
  the user still isn't listed, double-check you granted access to the
  *email you typed*, not a different account, via the `Secure > Gateway`
  link the script prints.

---

## 7. User Impersonation variant

Everything above describes the **default** setup, where an Airia-minted
gateway key (`inferenceGatewayApiKey`) authenticates every request and Claude
Desktop auto-discovers available models.

**User Impersonation** is a different mode: the *end user's own* Anthropic
plan subscription (Pro/Max/Team/Enterprise) gets billed for inference
instead of an Airia-side key, while Airia stays in the request path for
routing, logging, and model allow-listing. Full background and the
manual/UI steps (mint the token, enable Developer Mode, etc.) live in
`docs/Claude Desktop via Airia Gateway – Formatted PDF.pdf`.

Two credentials are always in play in this mode, and — unlike the default
setup — they go in **different** places:

| Credential | Format | Goes in | Sent as |
|---|---|---|---|
| The user's own Anthropic OAuth token | `sk-ant-oat01-...` | `inferenceGatewayApiKey` | `Authorization: Bearer` |
| Airia-issued gateway key (same kind minted by the default flow) | Airia-issued (`agk-...`) | `inferenceCustomHeaders` → `x-airia-key` | custom header |

Mixing these up is the #1 failure mode (401 "Invalid API key") — see the
Troubleshooting table in the PDF.

### Files

- `templates/Claude_user_impersonation.mobileconfig` /
  `templates/Claude_user_impersonation.reg` — placeholder templates for this
  mode (parallel to `templates/Claude.mobileconfig` / `templates/Claude.reg`).
- `scripts/setup_claude_user_impersonation.sh` — bash (macOS / Linux / WSL /
  Git Bash)
- `scripts/setup_claude_user_impersonation.ps1` — PowerShell (Windows).
  `scripts/run_user_impersonation.bat` is a double-clickable launcher for
  this script. Or just run `setup_claude.sh`/`.ps1` from the project root
  and pick option 2.

### What's different from the default script

1. **Airia gateway key still gets minted the same way** (`POST
   /v1/GatewayApiKey` using `MINT_API_KEY` + `GATEWAY_CONFIGURATION_ID` from
   `.env` — same admin values as the default script), but the result is
   written into the `x-airia-key` custom header instead of
   `inferenceGatewayApiKey`.
2. **New prompt: the user's Claude long-lived token.** The script cannot
   mint this — it requires an interactive local browser OAuth flow. The end
   user must run `claude setup-token` themselves on their own machine (not
   over plain SSH — the OAuth callback targets `localhost`), approve in the
   browser while signed into the correct plan account, and paste the
   resulting `sk-ant-oat01-...` token into the script's prompt. This becomes
   `inferenceGatewayApiKey`.
3. **`inferenceGatewayAuthScheme` is fixed to `"bearer"`** in the template
   (not a placeholder) — required so the token above travels as
   `Authorization: Bearer` rather than `x-api-key`.
4. **New step: manual model list.** Since model discovery doesn't work the
   same way in this mode, the script loops asking for model names one at a
   time (e.g. `claude-sonnet-4-6`, an Opus model, and `claude-haiku-4-5`,
   which is required for background tasks) plus whether each supports 1M
   context (`supports1m`, written as an explicit `true`/`false`). These
   must match the Allowed Models list configured on the Airia gateway side
   (an empty allow-list there means "allow all"). The script shows the
   accumulated list and asks for a final confirmation (with the option to
   add more or remove the last entry) before writing it into
   `inferenceModels`.
5. Everything else — BASE_URL/region detection, AI Gateway URL, user email,
   OTLP endpoint/key, optional MCP server, output platform choice — works
   identically to `scripts/setup_claude_gateway.sh`/`.ps1`. That includes the same
   pre-mint checks described in [Section 2](#2-what-the-script-asks-you-step-by-step):
   resolving the email to a platform user id, checking for and optionally
   reusing an existing enabled gateway key (the one that ends up in
   `x-airia-key`, not the Anthropic token), and verifying/confirming gateway
   access afterward.

### Placeholder reference (impersonation templates)

| Placeholder | Filled with | Purpose |
|---|---|---|
| `<AIRIA-AI-GATEWAY>` | The AI Gateway URL | Same as the default template — `inferenceGatewayBaseUrl` with `/anthropic` appended. |
| `<AIRIA-GATEWAY-KEY>` | The gateway key from the key acquisition step — reused from an existing key or freshly minted via `/v1/GatewayApiKey` (same logic as the default flow's step 5/6) | Written into `inferenceCustomHeaders` as `{"x-airia-key":"..."}`. Authenticates to Airia / identifies the tenant config. |
| `<CLAUDE-LONGLIVED-TOKEN>` | The user's own `sk-ant-oat01-...` token, pasted at the "Claude long-lived token" prompt ("What's different" item 2 above) | Written into `inferenceGatewayApiKey`. Authenticates to Anthropic and bills the user's own plan seat. Sent as `Authorization: Bearer` (see `inferenceGatewayAuthScheme`, fixed to `"bearer"` in the template). |
| `<OTLP-ENDPOINT>` / `<OTLP-API-KEY>` / `<USER-EMAIL>` | Same as the default flow | Telemetry wiring — unchanged from `scripts/setup_claude_gateway.sh`/`.ps1`. |
| `<MODELS-JSON>` | The confirmed model list from the manual model list step ("What's different" item 4 above), e.g. `[{"name":"claude-sonnet-4-6","supports1m":false},{"name":"claude-haiku-4-5","supports1m":false}]` | Written into `inferenceModels`. Must match the Allowed Models list on the Airia gateway side. |
| `<MCP-SERVER-NAME>` / `<MCP-URL>` | Same as the default flow | `managedMcpServers`, or `[]` if declined. |

Output files land in `./generated/` as `<INITIALS>_claude_impersonation.reg`
/ `<INITIALS>_claude_impersonation.mobileconfig` — same live-credential
handling rules apply (never commit, treat like passwords, deliver only to
the intended user).
