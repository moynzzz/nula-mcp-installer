#!/usr/bin/env bash
# nula-mcp-installer/install.sh
# One-line installer for the Nula MCP server.
# Mac + Linux. Wires up Claude Desktop, Cursor, opencode, and GitHub Copilot CLI.
# Plain bash + python3 (no jq). Backups every file it touches with .bak before writing.

set -euo pipefail

###############################################################################
# Configuration — override via env var, e.g.
#   MCP_URL=https://mcp.example.com/mcp bash <(curl -fsSL https://raw.githubusercontent.com/moynzzz/nula-mcp-installer/main/install.sh)
###############################################################################

# Production URL gets baked in once W4-2 (Vapor deploy) lands. Until then,
# users override via env. The placeholder is intentionally invalid so a
# default install fails loudly rather than configuring a dead URL.
MCP_URL="${MCP_URL:-https://YOUR_NULA_INSTANCE/mcp}"

# Optional. If your grant covers a single team, leave blank — the server
# auto-picks it. If your grant covers multiple teams, set this to the
# team id you want every JSON-RPC call to act on.
MCP_TEAM_ID="${MCP_TEAM_ID:-}"

# Where install.sh's transient JSON-merge helper lives. /tmp is fine on
# Mac + Linux; the file is rewritten on every invocation.
PYHELPER="${TMPDIR:-/tmp}/nula-mcp-installer-merge.$$.py"

###############################################################################
# Pretty output
###############################################################################

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; RESET=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$BLUE"   "$*" "$RESET"; }
warn() { printf '%s%s%s\n' "$YELLOW" "$*" "$RESET" >&2; }
err()  { printf '%s%s%s\n' "$RED"    "$*" "$RESET" >&2; }
ok()   { printf '%s%s%s\n' "$GREEN"  "$*" "$RESET"; }

###############################################################################
# Preflight
###############################################################################

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Missing required tool: $1"
        err "Install it (Mac: 'brew install $1', Debian/Ubuntu: 'sudo apt install $1') and re-run."
        exit 1
    fi
}

require python3

case "$(uname -s)" in
    Darwin) OS=mac ;;
    Linux)  OS=linux ;;
    *)
        err "Unsupported OS: $(uname -s). This installer covers Mac + Linux."
        err "Windows users: use install.ps1 instead (see README)."
        exit 1
        ;;
esac

if [ "$MCP_URL" = "https://YOUR_NULA_INSTANCE/mcp" ]; then
    warn "MCP_URL is the placeholder default."
    warn "Set it explicitly, e.g.:"
    warn "  MCP_URL=https://nula.bg/mcp bash <(curl -fsSL .../install.sh)"
    warn ""
    printf 'Continue with the placeholder anyway? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) err "Aborted."; exit 1 ;;
    esac
fi

###############################################################################
# Per-client config paths
###############################################################################

claude_config_path() {
    case "$OS" in
        mac)   echo "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
        linux) echo "$HOME/.config/Claude/claude_desktop_config.json" ;;
    esac
}

cursor_config_path() {
    echo "$HOME/.cursor/mcp.json"
}

opencode_config_path() {
    # opencode prefers ~/.config/opencode/opencode.json on Mac + Linux.
    echo "$HOME/.config/opencode/opencode.json"
}

copilot_config_path() {
    # ~/.copilot/mcp-config.json is the user-global location per Copilot CLI docs.
    echo "$HOME/.copilot/mcp-config.json"
}

###############################################################################
# Detection
###############################################################################
# A client counts as "installed" only when we have a strong signal: either its
# binary is reachable, or its client-specific config file already exists.
# Dir-alone signals are deliberately rejected — unrelated tools can leave stub
# config dirs (~/.cursor was a reported false-positive vector on Windows; same
# risk applies on Mac/Linux).

claude_installed() {
    [ -f "$(claude_config_path)" ] || command -v claude >/dev/null 2>&1
}

cursor_installed() {
    [ -f "$(cursor_config_path)" ] || command -v cursor >/dev/null 2>&1
}

opencode_installed() {
    [ -f "$(opencode_config_path)" ] || command -v opencode >/dev/null 2>&1
}

copilot_installed() {
    command -v copilot >/dev/null 2>&1
}

###############################################################################
# JSON merge helper (python3) — written once per run, then invoked per client.
# Reads:  argv[1] target file (may not exist), argv[2] top-level key,
#         argv[3] server name, argv[4] server-block JSON (stdin merged with this)
# Writes: target file, after deep-merging.
###############################################################################

write_pyhelper() {
    cat >"$PYHELPER" <<'PY'
"""
Deep-merge a single MCP server block into a client config file.

Usage: merge.py <target_path> <top_level_key> <server_name>
       (server-block JSON read from stdin)

Behavior:
- Target file is created if absent (parent dirs are mkdir -p'd).
- Existing JSON is preserved (other servers, unrelated keys, _comment_* fields).
- The server block under <top_level_key>.<server_name> is REPLACED in full
  (we don't try to merge nested 'headers' from a previous install — full
  replace is the right call so users running install.sh again pick up new
  defaults cleanly).
- Atomic write via tempfile + os.replace.
"""

import json
import os
import sys
import tempfile

target, top_key, server_name = sys.argv[1], sys.argv[2], sys.argv[3]
block = json.loads(sys.stdin.read())

if os.path.exists(target):
    with open(target, "r", encoding="utf-8") as fh:
        try:
            data = json.load(fh)
        except json.JSONDecodeError as exc:
            sys.stderr.write(
                f"refusing to overwrite invalid JSON in {target}: {exc}\n"
            )
            sys.exit(2)
    if not isinstance(data, dict):
        sys.stderr.write(
            f"refusing to overwrite non-object JSON root in {target}\n"
        )
        sys.exit(2)
else:
    data = {}

if top_key not in data or not isinstance(data[top_key], dict):
    data[top_key] = {}

data[top_key][server_name] = block

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)

fd, tmp = tempfile.mkstemp(prefix=".nula-mcp-", dir=os.path.dirname(target) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, target)
PY
}

merge_json() {
    local target="$1" top_key="$2" server_name="$3" block="$4"
    python3 "$PYHELPER" "$target" "$top_key" "$server_name" <<<"$block"
}

backup_if_present() {
    local path="$1"
    if [ -f "$path" ]; then
        cp -f "$path" "$path.bak"
        info "  backup: $path.bak"
    fi
}

###############################################################################
# Per-client blocks
###############################################################################

headers_block() {
    # Emits a headers map for inclusion in a client config.
    # - Mcp-Team-Id only set if the user provided MCP_TEAM_ID.
    # - For Copilot CLI we ALSO need an Authorization: Bearer header.
    local include_auth="${1:-false}"
    python3 - "$MCP_TEAM_ID" "$include_auth" <<'PY'
import json, sys
team_id, include_auth = sys.argv[1], sys.argv[2] == "true"
headers = {}
if team_id:
    headers["Mcp-Team-Id"] = team_id
if include_auth:
    headers["Authorization"] = "Bearer ${NULA_MCP_TOKEN}"
sys.stdout.write(json.dumps(headers))
PY
}

build_block_claude_or_cursor() {
    # Claude Desktop + Cursor share the same block shape.
    python3 - "$MCP_URL" "$(headers_block false)" <<'PY'
import json, sys
url, headers = sys.argv[1], json.loads(sys.argv[2])
block = {"url": url, "transport": "http"}
if headers:
    block["headers"] = headers
sys.stdout.write(json.dumps(block))
PY
}

build_block_cursor() {
    # Cursor's example omits 'transport' — keep that shape for parity.
    python3 - "$MCP_URL" "$(headers_block false)" <<'PY'
import json, sys
url, headers = sys.argv[1], json.loads(sys.argv[2])
block = {"url": url}
if headers:
    block["headers"] = headers
sys.stdout.write(json.dumps(block))
PY
}

build_block_opencode() {
    python3 - "$MCP_URL" "$(headers_block false)" <<'PY'
import json, sys
url, headers = sys.argv[1], json.loads(sys.argv[2])
block = {"type": "remote", "url": url, "enabled": True}
if headers:
    block["headers"] = headers
sys.stdout.write(json.dumps(block))
PY
}

build_block_copilot() {
    python3 - "$MCP_URL" "$(headers_block true)" <<'PY'
import json, sys
url, headers = sys.argv[1], json.loads(sys.argv[2])
block = {"type": "http", "url": url, "tools": ["*"]}
if headers:
    block["headers"] = headers
sys.stdout.write(json.dumps(block))
PY
}

###############################################################################
# Installers
###############################################################################

install_claude() {
    local path; path="$(claude_config_path)"
    info "Claude Desktop → $path"
    backup_if_present "$path"
    merge_json "$path" "mcpServers" "nula" "$(build_block_claude_or_cursor)"
    ok "  installed"
    NEXT_STEPS+=("Claude Desktop: quit + relaunch the app. First connect opens a browser for OAuth consent (pick teams + Read/Read+Write, approve).")
}

install_cursor() {
    local path; path="$(cursor_config_path)"
    info "Cursor → $path"
    backup_if_present "$path"
    merge_json "$path" "mcpServers" "nula" "$(build_block_cursor)"
    ok "  installed"
    NEXT_STEPS+=("Cursor: Settings → MCP → Reconnect (or restart Cursor). First connect opens a browser for OAuth consent.")
}

install_opencode() {
    local path; path="$(opencode_config_path)"
    info "opencode → $path"
    backup_if_present "$path"
    merge_json "$path" "mcp" "nula" "$(build_block_opencode)"
    ok "  installed"
    NEXT_STEPS+=("opencode: run 'opencode mcp auth nula' to trigger the browser OAuth flow. Then 'opencode mcp debug nula' to verify.")
}

install_copilot() {
    local path; path="$(copilot_config_path)"
    info "GitHub Copilot CLI → $path"
    backup_if_present "$path"
    merge_json "$path" "mcpServers" "nula" "$(build_block_copilot)"
    ok "  installed"
    NEXT_STEPS+=("Copilot CLI: mint a bearer token (run scripts/qa-mcp-flow.sh from the Nula server repo) and 'export NULA_MCP_TOKEN=<token>' before starting 'copilot'. Tokens expire after 90 days. Copilot CLI does NOT do OAuth.")
}

###############################################################################
# Menu
###############################################################################

declare -a CHOSEN=()
declare -a NEXT_STEPS=()

main_menu() {
    say ""
    say "${BOLD}Nula MCP installer${RESET}"
    say "${DIM}MCP URL: $MCP_URL${RESET}"
    if [ -n "$MCP_TEAM_ID" ]; then
        say "${DIM}Mcp-Team-Id header: $MCP_TEAM_ID${RESET}"
    else
        say "${DIM}Mcp-Team-Id header: (omitted — server will auto-pick if grant covers one team)${RESET}"
    fi
    say ""

    local i=0
    local labels=() availability=()
    register() {
        local key="$1" pretty="$2" detected="$3"
        i=$((i+1))
        labels[i]="$key"
        availability[i]="$detected"
        local tag
        if [ "$detected" = "yes" ]; then
            tag="${GREEN}installed${RESET}"
        else
            tag="${DIM}not detected${RESET}"
        fi
        printf '  %d) %-20s [%s]\n' "$i" "$pretty" "$tag"
    }

    register claude   "Claude Desktop"     "$(claude_installed   && echo yes || echo no)"
    register cursor   "Cursor"             "$(cursor_installed   && echo yes || echo no)"
    register opencode "opencode"           "$(opencode_installed && echo yes || echo no)"
    register copilot  "GitHub Copilot CLI" "$(copilot_installed  && echo yes || echo no)"
    say ""
    say "  a) all (auto-select every detected client)"
    say "  q) quit"
    say ""
    printf 'Pick by number, comma-separated (e.g. 1,3) or letter: '
    read -r choice

    case "$choice" in
        q|Q) say "Aborted."; exit 0 ;;
        a|A|all)
            local n
            for n in 1 2 3 4; do
                if [ "${availability[n]}" = "yes" ]; then
                    CHOSEN+=("${labels[n]}")
                fi
            done
            if [ ${#CHOSEN[@]} -eq 0 ]; then
                err "No clients detected. Install one and re-run, or pick a number explicitly to force-write a config."
                exit 1
            fi
            ;;
        *)
            local IFS=','
            for n in $choice; do
                n="${n//[[:space:]]/}"
                case "$n" in
                    1) CHOSEN+=("claude")   ;;
                    2) CHOSEN+=("cursor")   ;;
                    3) CHOSEN+=("opencode") ;;
                    4) CHOSEN+=("copilot")  ;;
                    *) err "Unknown choice: $n"; exit 1 ;;
                esac
            done
            ;;
    esac
}

###############################################################################
# Main
###############################################################################

write_pyhelper
trap 'rm -f "$PYHELPER"' EXIT

main_menu

say ""
info "Installing into ${#CHOSEN[@]} client(s)..."
say ""

for client in "${CHOSEN[@]}"; do
    case "$client" in
        claude)   install_claude   ;;
        cursor)   install_cursor   ;;
        opencode) install_opencode ;;
        copilot)  install_copilot  ;;
    esac
done

say ""
ok "All done."
say ""
say "${BOLD}Next steps:${RESET}"
for step in "${NEXT_STEPS[@]}"; do
    say "  • $step"
done
say ""
say "${DIM}If something goes wrong, restore from <config>.bak and open an issue at${RESET}"
say "${DIM}https://github.com/moynzzz/nula-mcp-installer/issues${RESET}"
