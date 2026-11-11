<#
.SYNOPSIS
    Register a running local model as a dsh-tui provider route.

.DESCRIPTION
    dsh-tui reads ~\.dsh\profiles\dsh-tui\cordis.patch.yml and hot-reloads it, so a model becomes
    selectable in /model without restarting anything.

    This edits that file in place: it removes any route with the same name and appends a fresh
    one, leaving every other route and the retry policy untouched. The original is backed up.

.PARAMETER Port
    Port the model is serving on.

.PARAMETER Model
    The server's --alias (must match, or the route 404s).

.PARAMETER Name
    Route name shown in dsh-tui. Defaults to "llama-<slug of model>".

.EXAMPLE
    .\connect-dsh.ps1 -Port 8084 -Model qwen3.6-35b-a3b
    .\connect-dsh.ps1 -Port 8083 -Model gemma-4-e4b -Name local-fast -Context 32768
#>
[CmdletBinding()]
param(
    [int]$Port = 8083,
    [string]$Model = '',
    [string]$Name = '',
    [int]$Context = 16384,
    [int]$MaxTokens = 8192,
    [string]$ConfigPath = "$env:USERPROFILE\.dsh\profiles\dsh-tui\cordis.patch.yml"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) {
    Write-Host "  dsh-tui config not found at $ConfigPath" -ForegroundColor Red
    Write-Host "  start dsh-tui once so it creates the profile, then re-run." -ForegroundColor Yellow
    return
}

# --- confirm the model is really there -------------------------------------
try {
    $ids = @((Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 5).data.id)
} catch {
    Write-Host "  nothing is answering on 127.0.0.1:$Port - start the model first" -ForegroundColor Red
    Write-Host "    .\serve-model.ps1 <name> -Port $Port" -ForegroundColor Yellow
    return
}
if (-not $Model) { $Model = $ids[0] }
if ($ids -notcontains $Model) {
    Write-Host "  ! '$Model' is not served on :$Port (available: $($ids -join ', '))" -ForegroundColor Yellow
    return
}

if (-not $Name) {
    $slug = ($Model -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLower()
    $Name = "llama-$slug"
}

$lines = Get-Content $ConfigPath
$backup = "$ConfigPath.bak"
Copy-Item $ConfigPath $backup -Force

# Remove an existing block for this route: its header, then everything more indented.
$out = New-Object System.Collections.Generic.List[string]
$skipping = $false
foreach ($ln in $lines) {
    if ($ln -match "^\s{6}$([regex]::Escape($Name)):\s*$") { $skipping = $true; continue }
    if ($skipping) {
        if ($ln -match '^\s{0,6}\S' -and $ln.Trim() -ne '') { $skipping = $false }
        else { continue }
    }
    $out.Add($ln)
}

$block = @(
    ""
    "      # added by connect-dsh.ps1"
    "      ${Name}:"
    "        baseURL: http://127.0.0.1:$Port/v1"
    "        api: openai-completions"
    "        models:"
    "          - id: $Model"
    "            contextWindow: $Context"
    "            maxTokens: $MaxTokens"
)
foreach ($b in $block) { $out.Add($b) }

Set-Content -Path $ConfigPath -Value $out -NoNewline:$false

# --- validate before declaring victory -------------------------------------
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $check = & python -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1],encoding='utf-8'));p=d[0]['config']['providers'];print('routes:',','.join(p.keys()))" $ConfigPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Copy-Item $backup $ConfigPath -Force
        Write-Host "  ! YAML validation failed, restored the backup:" -ForegroundColor Red
        Write-Host "    $check" -ForegroundColor DarkGray
        return
    }
    Write-Host "  $check" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  dsh-tui route '$Name' -> http://127.0.0.1:$Port/v1  ($Model)" -ForegroundColor Green
Write-Host "  dsh-tui hot-reloads this file. If the model list looks stale, restart dsh-tui." -ForegroundColor DarkGray
Write-Host "    /model -> $Name -> $Model" -ForegroundColor Cyan
Write-Host "  backup: $backup" -ForegroundColor DarkGray
