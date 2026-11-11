<#
.SYNOPSIS
    Point Claude Code at a local llama.cpp model.

.DESCRIPTION
    Claude Code speaks the Anthropic Messages API. llama-server only speaks OpenAI, so a
    translation shim (anthropic-shim.py) sits in between on its own port.

    This script starts the shim if it is not already running against the right upstream, exports
    the environment Claude Code reads, and launches it. Nothing leaves the machine.

.PARAMETER Port
    The port the model is already serving on (see serve-model.ps1).

.PARAMETER Model
    The model id - the server's --alias. Must match, or the server answers 404.

.EXAMPLE
    .\connect-claude.ps1 -Port 8083 -Model gemma-4-e4b
    .\connect-claude.ps1 -Port 8084 -Model qwen3.6-35b-a3b -ClaudeArgs '--help'
#>
[CmdletBinding()]
param(
    [int]$Port = 8083,
    [string]$Model = '',
    [int]$ShimPort = 8097,
    [string]$Python = 'python',
    [string[]]$ClaudeArgs = @(),
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot
$shim = Join-Path $bin 'anthropic-shim.py'

# --- the model must already be up ------------------------------------------
try {
    $models = Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 5
    $ids = @($models.data.id)
} catch {
    Write-Host "  nothing is answering on 127.0.0.1:$Port" -ForegroundColor Red
    Write-Host "  start a model first:  .\serve-model.ps1 <name> -Port $Port" -ForegroundColor Yellow
    return
}
if (-not $Model) { $Model = $ids[0] }
if ($ids -notcontains $Model) {
    Write-Host "  ! '$Model' is not served here. Available: $($ids -join ', ')" -ForegroundColor Yellow
    $Model = $ids[0]
}

# --- shim: (re)start only if it is not already pointing at this upstream ----
$upstream = "http://127.0.0.1:$Port/v1"
$health = "http://127.0.0.1:$ShimPort/v1/models"
# The shim answers /v1/models with a placeholder id, so "is it up" and "is it pointed at the
# right port" are two different questions. Remember the upstream in a sidecar file.
$marker = Join-Path $env:TEMP 'anthropic-shim.upstream'
$shimOk = $false
try {
    $null = Invoke-RestMethod $health -TimeoutSec 3
    $cur = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { '' }
    $shimOk = ($cur -eq $upstream)
} catch { }

if (-not $shimOk) {
    Get-Process python -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*anthropic-shim*' } | Stop-Process -Force
    Start-Sleep -Milliseconds 400
    Write-Host "  starting the Anthropic shim on :$ShimPort -> $upstream" -ForegroundColor DarkGray
    Start-Process $Python -ArgumentList @($shim, '--upstream', $upstream, '--port', "$ShimPort") -WindowStyle Hidden
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        try { if ((Invoke-WebRequest "http://127.0.0.1:$ShimPort/v1/models" -TimeoutSec 2 -UseBasicParsing).StatusCode -eq 200) { $shimOk = $true; break } } catch { }
    }
    if ($shimOk) { Set-Content -Path $marker -Value $upstream }
}
if (-not $shimOk) { Write-Host "  ! shim did not come up - check python and anthropic-shim.py" -ForegroundColor Red; return }

# --- Claude Code environment ----------------------------------------------
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$ShimPort"
$env:ANTHROPIC_AUTH_TOKEN = 'local'
$env:ANTHROPIC_API_KEY = 'local'
$env:ANTHROPIC_MODEL = $Model
$env:ANTHROPIC_SMALL_FAST_MODEL = $Model
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
$env:API_TIMEOUT_MS = '600000'

Write-Host ""
Write-Host "  Claude Code -> 127.0.0.1:$ShimPort -> $upstream" -ForegroundColor Green
Write-Host "    ANTHROPIC_MODEL = $Model" -ForegroundColor DarkGray
Write-Host ""

if ($NoLaunch) {
    Write-Host "  environment is set in this shell only; run 'claude' here, or:" -ForegroundColor Yellow
    Write-Host "    `$env:ANTHROPIC_BASE_URL='http://127.0.0.1:$ShimPort'" -ForegroundColor DarkGray
    return
}

$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) { Write-Host "  'claude' is not on PATH - install Claude Code, or use -NoLaunch" -ForegroundColor Red; return }

& $claude.Source @ClaudeArgs
