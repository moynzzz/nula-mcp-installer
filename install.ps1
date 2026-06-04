<#
.SYNOPSIS
    One-line installer for the Cloudbooks MCP server.
    Windows. Wires up Claude Desktop, Cursor, opencode, and GitHub Copilot CLI.

.DESCRIPTION
    Mirrors install.sh for Windows. Pure PowerShell — no jq, no Python.
    Backs up every file with .bak before writing. JSON merge preserves
    existing servers + unrelated keys in target configs.

.PARAMETER McpUrl
    The remote MCP server URL. Override the placeholder default by passing
    -McpUrl or setting $env:MCP_URL before invoking.

.PARAMETER McpTeamId
    Optional. Sets the Mcp-Team-Id header on every JSON-RPC call. Leave
    blank if your grant covers a single team — the server auto-picks it.

.EXAMPLE
    iex "& { $(irm https://raw.githubusercontent.com/moynzzz/nula-mcp-installer/main/install.ps1) } -McpUrl https://nula.bg/mcp"

.NOTES
    Requires PowerShell 5.1+ (Windows 10/11 default) or PowerShell 7+.
#>

[CmdletBinding()]
param(
    [string]$McpUrl = $env:MCP_URL,
    [string]$McpTeamId = $env:MCP_TEAM_ID
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

if ([string]::IsNullOrWhiteSpace($McpUrl)) {
    $McpUrl = 'https://YOUR_CLOUDBOOKS_INSTANCE/mcp'
}

function Write-Info  { param([string]$Msg) Write-Host $Msg -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host $Msg -ForegroundColor Red }

if ($McpUrl -eq 'https://YOUR_CLOUDBOOKS_INSTANCE/mcp') {
    Write-Warn2 'MCP_URL is the placeholder default.'
    Write-Warn2 'Set it explicitly, e.g.:'
    Write-Warn2 '  iex "& { $(irm .../install.ps1) } -McpUrl https://nula.bg/mcp"'
    $answer = Read-Host 'Continue with the placeholder anyway? [y/N]'
    if ($answer -notmatch '^(?i:y|yes)$') {
        Write-Err 'Aborted.'
        exit 1
    }
}

###############################################################################
# Per-client config paths (Windows)
###############################################################################

function Get-ClaudeConfigPath   { Join-Path $env:APPDATA 'Claude\claude_desktop_config.json' }
function Get-CursorConfigPath   { Join-Path $env:USERPROFILE '.cursor\mcp.json' }
function Get-OpencodeConfigPath { Join-Path $env:APPDATA 'opencode\opencode.json' }
function Get-CopilotConfigPath  { Join-Path $env:USERPROFILE '.copilot\mcp-config.json' }

###############################################################################
# Detection
###############################################################################
# A client counts as "installed" if EITHER its binary is on PATH OR its
# config directory exists. Either signal is enough — users who've
# customized config paths still benefit from a detection menu hit.

function Test-ClaudeInstalled {
    (Test-Path (Join-Path $env:APPDATA 'Claude')) -or `
    [bool](Get-Command claude -ErrorAction SilentlyContinue)
}
function Test-CursorInstalled {
    (Test-Path (Join-Path $env:USERPROFILE '.cursor')) -or `
    [bool](Get-Command cursor -ErrorAction SilentlyContinue)
}
function Test-OpencodeInstalled {
    (Test-Path (Join-Path $env:APPDATA 'opencode')) -or `
    [bool](Get-Command opencode -ErrorAction SilentlyContinue)
}
function Test-CopilotInstalled {
    [bool](Get-Command copilot -ErrorAction SilentlyContinue) -or `
    (Test-Path (Join-Path $env:USERPROFILE '.copilot'))
}

###############################################################################
# JSON merge — preserve existing config, full-replace the cloudbooks server
# block. Refuses to overwrite invalid JSON. Atomic write via .tmp + Move-Item.
###############################################################################

function Merge-McpConfig {
    param(
        [Parameter(Mandatory=$true)][string]$Target,
        [Parameter(Mandatory=$true)][string]$TopKey,
        [Parameter(Mandatory=$true)][string]$ServerName,
        [Parameter(Mandatory=$true)][hashtable]$Block
    )

    $parent = Split-Path -Parent $Target
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path $Target) {
        $raw = Get-Content $Target -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $data = [ordered]@{}
        } else {
            try {
                $data = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            } catch {
                Write-Err "refusing to overwrite invalid JSON in $Target : $_"
                exit 2
            }
            if ($data -isnot [System.Collections.IDictionary]) {
                Write-Err "refusing to overwrite non-object JSON root in $Target"
                exit 2
            }
        }
    } else {
        $data = [ordered]@{}
    }

    if (-not $data.Contains($TopKey) -or $data[$TopKey] -isnot [System.Collections.IDictionary]) {
        $data[$TopKey] = [ordered]@{}
    }
    $data[$TopKey][$ServerName] = $Block

    $tmp = "$Target.tmp"
    $data | ConvertTo-Json -Depth 32 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $Target -Force
}

function Backup-IfPresent {
    param([string]$Path)
    if (Test-Path $Path) {
        Copy-Item -Path $Path -Destination "$Path.bak" -Force
        Write-Info "  backup: $Path.bak"
    }
}

###############################################################################
# Per-client blocks
###############################################################################

function Get-HeadersBlock {
    param([bool]$IncludeAuth = $false)
    $h = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($McpTeamId)) {
        $h['Mcp-Team-Id'] = $McpTeamId
    }
    if ($IncludeAuth) {
        $h['Authorization'] = 'Bearer ${CLOUDBOOKS_MCP_TOKEN}'
    }
    return $h
}

function Build-Block-Claude {
    $block = [ordered]@{ url = $McpUrl; transport = 'http' }
    $h = Get-HeadersBlock $false
    if ($h.Count -gt 0) { $block['headers'] = $h }
    return $block
}

function Build-Block-Cursor {
    $block = [ordered]@{ url = $McpUrl }
    $h = Get-HeadersBlock $false
    if ($h.Count -gt 0) { $block['headers'] = $h }
    return $block
}

function Build-Block-Opencode {
    $block = [ordered]@{ type = 'remote'; url = $McpUrl; enabled = $true }
    $h = Get-HeadersBlock $false
    if ($h.Count -gt 0) { $block['headers'] = $h }
    return $block
}

function Build-Block-Copilot {
    $block = [ordered]@{ type = 'http'; url = $McpUrl; tools = @('*') }
    $h = Get-HeadersBlock $true
    if ($h.Count -gt 0) { $block['headers'] = $h }
    return $block
}

###############################################################################
# Installers
###############################################################################

$script:NextSteps = @()

function Install-Claude {
    $path = Get-ClaudeConfigPath
    Write-Info "Claude Desktop -> $path"
    Backup-IfPresent $path
    Merge-McpConfig -Target $path -TopKey 'mcpServers' -ServerName 'cloudbooks' -Block (Build-Block-Claude)
    Write-Ok '  installed'
    $script:NextSteps += 'Claude Desktop: quit + relaunch the app. First connect opens a browser for OAuth consent.'
}

function Install-Cursor {
    $path = Get-CursorConfigPath
    Write-Info "Cursor -> $path"
    Backup-IfPresent $path
    Merge-McpConfig -Target $path -TopKey 'mcpServers' -ServerName 'cloudbooks' -Block (Build-Block-Cursor)
    Write-Ok '  installed'
    $script:NextSteps += 'Cursor: Settings -> MCP -> Reconnect (or restart Cursor). First connect opens a browser for OAuth consent.'
}

function Install-Opencode {
    $path = Get-OpencodeConfigPath
    Write-Info "opencode -> $path"
    Backup-IfPresent $path
    Merge-McpConfig -Target $path -TopKey 'mcp' -ServerName 'cloudbooks' -Block (Build-Block-Opencode)
    Write-Ok '  installed'
    $script:NextSteps += "opencode: run 'opencode mcp auth cloudbooks' to trigger the browser OAuth flow."
}

function Install-Copilot {
    $path = Get-CopilotConfigPath
    Write-Info "GitHub Copilot CLI -> $path"
    Backup-IfPresent $path
    Merge-McpConfig -Target $path -TopKey 'mcpServers' -ServerName 'cloudbooks' -Block (Build-Block-Copilot)
    Write-Ok '  installed'
    $script:NextSteps += "Copilot CLI: mint a bearer token (run scripts/qa-mcp-flow.sh from the Cloudbooks repo) and set `$env:CLOUDBOOKS_MCP_TOKEN before starting 'copilot'. Tokens expire after 90 days. Copilot CLI does NOT do OAuth."
}

###############################################################################
# Menu
###############################################################################

Write-Host ''
Write-Host 'Cloudbooks MCP installer' -ForegroundColor White
Write-Host "MCP URL: $McpUrl" -ForegroundColor DarkGray
if ([string]::IsNullOrWhiteSpace($McpTeamId)) {
    Write-Host 'Mcp-Team-Id header: (omitted - server auto-picks if grant covers one team)' -ForegroundColor DarkGray
} else {
    Write-Host "Mcp-Team-Id header: $McpTeamId" -ForegroundColor DarkGray
}
Write-Host ''

$entries = @(
    @{ Key='claude';   Pretty='Claude Desktop';     Detected=(Test-ClaudeInstalled) },
    @{ Key='cursor';   Pretty='Cursor';             Detected=(Test-CursorInstalled) },
    @{ Key='opencode'; Pretty='opencode';           Detected=(Test-OpencodeInstalled) },
    @{ Key='copilot';  Pretty='GitHub Copilot CLI'; Detected=(Test-CopilotInstalled) }
)

for ($i = 0; $i -lt $entries.Count; $i++) {
    $tag = if ($entries[$i].Detected) { '[installed]' } else { '[not detected]' }
    $line = '  {0}) {1,-20} {2}' -f ($i + 1), $entries[$i].Pretty, $tag
    if ($entries[$i].Detected) {
        Write-Host $line -ForegroundColor Green
    } else {
        Write-Host $line -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host '  a) all (auto-select every detected client)'
Write-Host '  q) quit'
Write-Host ''
$choice = Read-Host 'Pick by number, comma-separated (e.g. 1,3) or letter'

$chosen = @()

switch -Regex ($choice) {
    '^(q|Q)$'   { Write-Host 'Aborted.'; exit 0 }
    '^(a|A)' {
        foreach ($e in $entries) { if ($e.Detected) { $chosen += $e.Key } }
        if ($chosen.Count -eq 0) {
            Write-Err 'No clients detected. Install one and re-run, or pick a number explicitly.'
            exit 1
        }
    }
    default {
        foreach ($n in ($choice -split '[,\s]+')) {
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            switch ($n) {
                '1' { $chosen += 'claude' }
                '2' { $chosen += 'cursor' }
                '3' { $chosen += 'opencode' }
                '4' { $chosen += 'copilot' }
                default { Write-Err "Unknown choice: $n"; exit 1 }
            }
        }
    }
}

Write-Host ''
Write-Info "Installing into $($chosen.Count) client(s)..."
Write-Host ''

foreach ($c in $chosen) {
    switch ($c) {
        'claude'   { Install-Claude }
        'cursor'   { Install-Cursor }
        'opencode' { Install-Opencode }
        'copilot'  { Install-Copilot }
    }
}

Write-Host ''
Write-Ok 'All done.'
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
foreach ($s in $script:NextSteps) { Write-Host "  - $s" }
Write-Host ''
Write-Host 'If something goes wrong, restore from <config>.bak and open an issue at' -ForegroundColor DarkGray
Write-Host 'https://github.com/moynzzz/nula-mcp-installer/issues' -ForegroundColor DarkGray
