# nula-mcp-installer

One-line installer for the [Nula](https://nula.bg) MCP server. Wires up the four major MCP clients in one shot:

- **Claude Desktop**
- **Cursor**
- **opencode**
- **GitHub Copilot CLI**

The installer detects which clients are installed on your machine, asks you to pick the ones to configure, backs up any existing config, and writes a clean JSON merge — your other MCP servers stay intact.

---

## Quick install

### macOS / Linux

```sh
MCP_URL=https://YOUR_NULA_INSTANCE/mcp bash <(curl -fsSL https://raw.githubusercontent.com/moynzzz/nula-mcp-installer/main/install.sh)
```

### Windows (PowerShell 5.1+ or PowerShell 7)

```powershell
iex "& { $(irm https://raw.githubusercontent.com/moynzzz/nula-mcp-installer/main/install.ps1) } -McpUrl https://YOUR_NULA_INSTANCE/mcp"
```

Replace `YOUR_NULA_INSTANCE` with your actual Nula host (e.g. `nula.bg`). The placeholder URL is intentionally invalid — the installer will prompt before letting you continue with it.

---

## Options

Both scripts honour the same two settings:

| Setting | macOS / Linux | Windows | What it does |
|---|---|---|---|
| MCP URL | `MCP_URL` env var | `-McpUrl` arg or `$env:MCP_URL` | The remote MCP endpoint (e.g. `https://nula.bg/mcp`). |
| Team header | `MCP_TEAM_ID` env var | `-McpTeamId` arg or `$env:MCP_TEAM_ID` | Optional. Sets `Mcp-Team-Id` on every JSON-RPC call. Leave blank if your grant covers a single team — the server auto-picks it. Required if your grant covers multiple teams. |

### Single-team example

```sh
MCP_URL=https://nula.bg/mcp bash <(curl -fsSL .../install.sh)
```

### Multi-team example

```sh
MCP_URL=https://nula.bg/mcp MCP_TEAM_ID=410 bash <(curl -fsSL .../install.sh)
```

---

## What the installer does

1. **Detects** which of the four clients are installed (either the binary is on `PATH` or the client's config directory exists).
2. **Shows a numbered menu** so you can pick one, several (`1,3`), all detected (`a`), or quit (`q`).
3. **Backs up** any existing config file as `<file>.bak` before touching it.
4. **Merges** the `cloudbooks` MCP server block into the right top-level key of the right JSON file — preserving every other MCP server, every unrelated key, and every `_comment_*` field you may have added. Atomic write via temp file + rename.
5. **Prints next-steps tailored per client** (OAuth flow for Claude / Cursor / opencode; manual token-mint for Copilot CLI).

---

## Config paths the installer writes to

| Client | macOS | Linux | Windows |
|---|---|---|---|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | `~/.config/Claude/claude_desktop_config.json` | `%APPDATA%\Claude\claude_desktop_config.json` |
| Cursor | `~/.cursor/mcp.json` | `~/.cursor/mcp.json` | `%USERPROFILE%\.cursor\mcp.json` |
| opencode | `~/.config/opencode/opencode.json` | `~/.config/opencode/opencode.json` | `%APPDATA%\opencode\opencode.json` |
| GitHub Copilot CLI | `~/.copilot/mcp-config.json` | `~/.copilot/mcp-config.json` | `%USERPROFILE%\.copilot\mcp-config.json` |

---

## Manual install (if you'd rather not curl-pipe)

Paste these snippets into the relevant file, replacing `https://YOUR_NULA_INSTANCE/mcp` with your host. If the file already has `mcpServers` / `mcp`, add the `cloudbooks` server *inside* that block — don't overwrite.

### Claude Desktop

```json
{
  "mcpServers": {
    "cloudbooks": {
      "url": "https://YOUR_NULA_INSTANCE/mcp",
      "transport": "http"
    }
  }
}
```

### Cursor

```json
{
  "mcpServers": {
    "cloudbooks": {
      "url": "https://YOUR_NULA_INSTANCE/mcp"
    }
  }
}
```

### opencode

```json
{
  "mcp": {
    "cloudbooks": {
      "type": "remote",
      "url": "https://YOUR_NULA_INSTANCE/mcp",
      "enabled": true
    }
  }
}
```

### GitHub Copilot CLI

```json
{
  "mcpServers": {
    "cloudbooks": {
      "type": "http",
      "url": "https://YOUR_NULA_INSTANCE/mcp",
      "tools": ["*"],
      "headers": {
        "Authorization": "Bearer ${CLOUDBOOKS_MCP_TOKEN}"
      }
    }
  }
}
```

> Copilot CLI does NOT do OAuth automatically. Mint a bearer token externally (the Nula repo ships `scripts/qa-mcp-flow.sh`) and export it as `CLOUDBOOKS_MCP_TOKEN` before starting `copilot`. Tokens expire after 90 days.

### Multi-team grants

If your OAuth grant covers more than one team, every snippet above also needs an `Mcp-Team-Id` header so the server knows which team to act on:

```json
"headers": {
  "Mcp-Team-Id": "410"
}
```

(Copilot CLI: add it alongside the `Authorization` header.)

---

## After the install — the OAuth flow

For **Claude Desktop / Cursor / opencode**, the first time the client connects it will:

1. Fetch `<MCP_URL>/.well-known/oauth-protected-resource` to discover the auth server.
2. POST to the auth server's `/oauth/register` (RFC 7591 dynamic client registration).
3. Open your default browser on the Nula consent page.

In the browser you'll see:

- Nula login (if you're not already signed in).
- A consent screen: a list of your teams (checkboxes) + a **Read / Read+Write** radio. Pick at least one team + Read+Write if you want write tools.
- Click **Approve** — the browser redirects back to the client's loopback callback and you're connected.

For **opencode** the flow is the same but triggered manually:

```sh
opencode mcp auth cloudbooks
opencode mcp debug cloudbooks    # verify
```

For **Copilot CLI** there is no OAuth flow — see the bearer-token note above.

---

## Troubleshooting

### "MCP_URL is the placeholder default"

You ran the installer without setting `MCP_URL`. Re-run with the env var set:

```sh
MCP_URL=https://nula.bg/mcp bash <(curl -fsSL .../install.sh)
```

### "refusing to overwrite invalid JSON in <path>"

The target config file isn't valid JSON. Open it in an editor, fix the syntax, then re-run. The installer will never overwrite a file it cannot parse — your bad config is safe.

### Client connects but reports "0 tools"

- Confirm you actually approved the OAuth consent (Approve button, not Cancel).
- Confirm your grant covers a team with at least one tool-relevant permission (see the Nula docs on roles + permissions).
- Multi-team grants: confirm `Mcp-Team-Id` is set to a team that's in the grant.

### "401 Unauthorized" from Copilot CLI

Your `CLOUDBOOKS_MCP_TOKEN` is missing, expired, or for the wrong instance. Mint a fresh one (`scripts/qa-mcp-flow.sh` from the Nula repo) and `export CLOUDBOOKS_MCP_TOKEN=...` before starting `copilot`.

### "Something else broke"

Every config file the installer touches gets a `.bak` companion before any write. Restore with:

```sh
mv ~/path/to/config.json.bak ~/path/to/config.json
```

Then open an issue at https://github.com/moynzzz/nula-mcp-installer/issues with the script output.

---

## Testing

### macOS / Linux

A clean Linux container is the simplest reproducible smoke test:

```sh
docker run --rm -it -v "$PWD:/work" -w /work ubuntu:24.04 bash -c '
    apt-get update -qq && apt-get install -y -qq python3 curl >/dev/null
    mkdir -p ~/.cursor ~/.config/opencode ~/.copilot
    MCP_URL=https://example.test/mcp MCP_TEAM_ID=42 ./install.sh
'
```

Type `a` at the menu and the installer should detect Cursor, opencode, and Copilot CLI (no Claude on Linux unless you also `mkdir ~/.config/Claude`).

### Windows

PowerShell parse + behaviour check on Windows 10/11:

```powershell
# In a Windows PowerShell session
. .\install.ps1 -McpUrl https://example.test/mcp -McpTeamId 42
```

If you're testing on a fresh user profile, `mkdir $env:APPDATA\Claude`, `$env:APPDATA\opencode`, etc., first so detection has something to find.

---

## Security notes

- This installer is **plain bash / PowerShell** — no compiled binaries, no telemetry, no analytics, no auto-update hooks. The entire source is the two scripts in this repo.
- Read both scripts before piping into `bash` / `iex`. If you don't trust them, copy the snippets from the **Manual install** section above into your client config by hand.
- The installer **never** mints credentials, **never** stores tokens, and **never** phones home. The only network call is the OAuth flow triggered by the MCP client itself, against the Nula host *you* specified.
- Token-bearing config (Copilot CLI) uses an env-var reference (`${CLOUDBOOKS_MCP_TOKEN}`), not the token itself. Your config files never contain the literal bearer.

---

## License

[MIT](LICENSE). © Nula (Nula EOOD).
