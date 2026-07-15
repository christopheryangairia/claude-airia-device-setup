# Airia — Claude Desktop Gateway Setup

This folder contains scripts that generate a ready-to-install Claude Desktop
config file (Windows `.reg` or macOS `.mobileconfig`) that points Claude
Desktop at your organization's Airia inference gateway, wires up OTLP
telemetry, and optionally registers a managed MCP server — all for one
specific end user.

There are two equivalent scripts, so use whichever matches the machine you're
running this from:

- `setup_claude.sh` — bash (macOS / Linux / WSL / Git Bash)
- `setup_claude.ps1` — PowerShell (Windows). `run.bat` is a double-clickable
  launcher for this script.

> Note: `symmlink-plugins.sh` is a separate, unrelated utility for symlinking
> a plugins folder from OneDrive and is not covered by this README.

---

## 1. Before you run anything — set the admin config values

Both scripts need two admin-level values filled in **once per Airia
environment/organization** before handing the script to anyone. These are not
per-user values — the script will still ask each individual user for their
own email, region, etc. separately.

**Recommended: use a `.env` file.** Copy `.env_sample` to `.env` in this same
folder and fill in your values:

```bash
cp .env_sample .env
```

```dotenv
# .env
MINT_API_KEY="ak-..."
GATEWAY_CONFIGURATION_ID="2d25bdf7-..."
```

Both `setup_claude.sh` and `setup_claude.ps1` automatically load `.env` from
the script's own directory if it exists (you'll see a `Loading environment
from ...` line when they do), and export the values into the process
environment before anything else runs. Values may optionally be wrapped in
single or double quotes — both scripts strip them correctly. Trailing `#
comments` on a line are also stripped. `.env` is already listed in
`.gitignore`, so it won't get committed by accident.

If you'd rather not use a `.env` file, you can instead hardcode the values
directly in the small constants block near the top of each script:

```bash
# setup_claude.sh
MINT_API_KEY=""
GATEWAY_CONFIGURATION_ID=""
KEY_TYPE="User"
ENABLED="true"
```

```powershell
# setup_claude.ps1
$MINT_API_KEY = if ($env:MINT_API_KEY) { $env:MINT_API_KEY } else { "" }
$GATEWAY_CONFIGURATION_ID = if ($env:GATEWAY_CONFIGURATION_ID) { $env:GATEWAY_CONFIGURATION_ID } else { "" }
$KEY_TYPE = "User"
$ENABLED = $true
```

A value set directly in the script's constants block only takes effect if
`.env` doesn't already provide it — `.env` (or the external process
environment, e.g. `export MINT_API_KEY=...` before running the script) wins
if both are present.

| Constant | What it is | Where to get it |
|---|---|---|
| `MINT_API_KEY` | An **admin-level** Airia API key with permission to create new Gateway API keys via the `/v1/GatewayApiKey` endpoint. This is the credential the script authenticates itself with — it is not the key that ends up in the generated config file. By default it is also reused as the OTLP telemetry key (see `<OTLP-API-KEY>` below), unless the person running the script chooses to supply a different one. | Airia Platform → Gateway settings → API Keys (admin/org-owner access), or ask your Airia Admin. |
| `GATEWAY_CONFIGURATION_ID` | The ID of the specific Gateway Configuration in Airia that the newly minted user key should belong to. Every key minted by this script is scoped to this configuration. | Airia Platform → Gateway → the specific Gateway Configuration's details page. Ask your Admin if you don't see it. |
| `KEY_TYPE` | The type of key to request from Airia when minting. `"User"` mints a personal, per-person key (this is what the script is designed around — each run mints one key for one email). Other values may be supported by your Airia environment (e.g. a service/team-level key type) but changing this changes what kind of key gets generated. | Leave as `"User"` unless your Admin tells you otherwise. |
| `ENABLED` | Whether the newly minted key should be **active immediately** on the gateway (`true`) or created in a disabled state (`false`) so an admin has to flip it on later. This does not affect anything already in the generated config file — it only affects whether the key actually works on Airia's side the moment it's created. | Leave as `true` for normal onboarding. Set to `false` if your process requires an admin to explicitly approve/enable new keys before they're usable. |

If your organization only has one Airia gateway configuration, you'll set
these once and never touch them again. If you support multiple environments
(e.g. separate configs for different regions or business units), keep a
separate `.env` (or a separate copy of the script with values hardcoded) per
environment.

---

## 2. What the script asks you, step by step

Running the script walks you through six prompts:

1. **BASE_URL / region** — Enter the same `BASE_URL` value used in `run.sh`
   for this environment, e.g. `https://sg01.api.airia.ai`. The script tries
   to detect the region (`sg01`, `eu1`, etc.) from the hostname pattern
   `<region>.api.airia.ai`. If your URL doesn't match that pattern, it's
   treated as a custom endpoint and you can type a region label of your own
   (or leave it blank). This value drives both the OTLP endpoint and the
   suggested Gateway URL in the next step.
2. **AI Gateway URL** — The script suggests `https://<region>.gateway.airia.ai/`
   based on the detected region, but you should confirm this against the
   actual value in **Airia Platform → Gateway**. If you don't have access,
   ask your Admin. This becomes `<AIRIA-AI-GATEWAY>` in the generated config.
3. **User's email address** — The person this config file is being generated
   for. Used both to mint their personal gateway key and to tag their OTLP
   telemetry.
4. *(automatic)* — The script calls Airia's `/v1/GatewayApiKey` endpoint
   using `MINT_API_KEY`, `GATEWAY_CONFIGURATION_ID`, `KEY_TYPE`, `ENABLED`,
   and the email from step 3, and receives back a personal API key for that
   user.
5. **OTLP API key** — The OTLP endpoint itself is derived automatically from
   the `BASE_URL` you entered in step 1 (`<BASE_URL>/v1/ClaudeCodeOtelIngest/ingest`).
   You're then asked whether you want to provide a **separate** API key for
   OTLP telemetry ingestion. If you say no (the default), the script reuses
   `MINT_API_KEY` for this purpose. If you say yes, you'll be prompted to
   paste a distinct key.
6. **Optional MCP server** — If you want Claude Desktop to auto-connect to a
   managed MCP server for this user, say yes and provide a name and URL. If
   you decline, the config is generated with no MCP servers registered.

At the end, you choose whether to generate the Windows `.reg`, the macOS
`.mobileconfig`, or both. Output files are written to `./generated/` as
`<INITIALS>_claude.reg` / `<INITIALS>_claude.mobileconfig`, where initials
are derived from the user's email (and can be overridden).

---

## 3. Placeholder reference

Both `Claude.reg` and `Claude.mobileconfig` are templates containing the same
set of placeholders. The scripts fill in every one of these before writing
the final file to `./generated/`.

| Placeholder | Filled with | Purpose |
|---|---|---|
| `<AIRIA-AI-GATEWAY>` | The AI Gateway URL entered in step 2 | Base URL Claude Desktop sends inference (chat/completion) requests to, via Airia's gateway instead of directly to Anthropic. The template appends `/anthropic` to this value (`inferenceGatewayBaseUrl`). |
| `<USER-API-KEY>` | The personal key minted in step 4 | The credential Claude Desktop uses to authenticate this specific user's requests against the gateway (`inferenceGatewayApiKey`). This is the sensitive, per-user secret — treat generated files like passwords. |
| `<OTLP-ENDPOINT>` | The `BASE_URL` entered in step 1 | Base URL for OpenTelemetry (OTLP) ingestion. The template appends the fixed path `/v1/ClaudeCodeOtelIngest/ingest` to form the full `otlpEndpoint`. This is how usage/telemetry data flows back into Airia. |
| `<OTLP-API-KEY>` | Either `MINT_API_KEY` (default) or a separate key you provide in step 5 | Value sent as the `X-API-KEY` header (`otlpHeaders`) when Claude Desktop pushes telemetry to the OTLP endpoint above. |
| `<USER-EMAIL>` | The email entered in step 3 | Used to tag telemetry with the user's identity (`otlpResourceAttributes` → `airia.user-email`), and is the identity the personal API key was minted for. |
| `<MCP-SERVER-NAME>` / `<MCP-URL>` | The values entered in step 6, if you opted in | Name and URL of a managed MCP server for Claude Desktop to auto-register (`managedMcpServers`). If you decline MCP setup, this whole field is written as an empty array (`[]`) instead of leaving these placeholders unfilled. |

A few settings in the templates are **not** placeholders — they're fixed
values baked into the templates themselves and aren't touched by the script:

- `otlpProtocol` (`http/json`), `otlpContentCapture` (which content types get
  captured), `chatTabEnabled`, `coworkEgressAllowedHosts`, `inferenceProvider`
  (`gateway`), and `inferenceCredentialKind` (`static`). Edit `Claude.reg` /
  `Claude.mobileconfig` directly if you need to change any of these defaults
  for your organization.

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

**`setup_claude.sh`**: `bash`, `curl`, `perl` (used for safe literal string
substitution), and `iconv` (used to safely edit the UTF‑16 `.reg` file
without corrupting its encoding). `jq` is optional — the script falls back
to `grep`/`cut` for parsing the API response if `jq` isn't installed.

**`setup_claude.ps1`**: Windows PowerShell with internet access to reach the
`BASE_URL` you provide (uses `Invoke-RestMethod`).

---

## 6. Troubleshooting

- **"gateway API key request failed (HTTP ...)"** — Check that
  `MINT_API_KEY` and `GATEWAY_CONFIGURATION_ID` are correct for the
  environment behind the `BASE_URL` you entered, and that `MINT_API_KEY`
  hasn't expired or been revoked. If you're setting these via `.env`, double
  check there's no stray whitespace or mismatched quote at the end of a line.
- **"Warning: MINT_API_KEY and/or GATEWAY_CONFIGURATION_ID are not set"**,
  or the script otherwise seems to ignore your `.env` — confirm the file is
  literally named `.env` and sits next to `setup_claude.sh` / `setup_claude.ps1`
  (not in a parent folder), and that you don't still have `.env_sample`'s
  placeholder values in place.
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
