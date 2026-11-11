<#
.SYNOPSIS
    Run Claude Code against a local llama.cpp model.

.DESCRIPTION
    Claude Code speaks the Anthropic Messages API; llama-server only speaks OpenAI. This
    starts the target model (if it is not already up), starts the translation shim, points
    Claude Code at the shim and launches it. Nothing leaves the machine.

    Context matters here: Claude Code's own system prompt plus its tool schemas run to
    roughly 12-15k tokens, so the server needs -Ctx 32768 to leave room for your work.
    The wrapper raises the context for that reason.

.EXAMPLE
    llm-claude.ps1                 # newest dense model, interactive
    llm-claude.ps1 -Model flint    # the 40B MoE instead
    llm-claude.ps1 -Model coder -Args '-p','explain this repo'
#>
[CmdletBinding()]
param(
    [string]$Model = 'gemma4',
    [string[]]$Args = @(),
    [int]$ShimPort = 8097
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot

# Claude Code's prompt+tools are big; give the server room so it does not truncate mid-task.
if (-not $env:LLM_CLAUDE_CTX) { $env:LLM_CLAUDE_CTX = '32768' }

function Test-Url([string]$u) {
    try { (Invoke-WebRequest $u -TimeoutSec 2 -UseBasicParsing).StatusCode -eq 200 } catch { $false }
}

# --- which model, which port -------------------------------------------------
& (Join-Path $bin 'llm-up.ps1') $Model -ErrorAction SilentlyContinue | Out-Null
$running = Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue
$port = if ($running -and $running.CommandLine -match '--port\s+(\d+)') { $Matches[1] } else { '8080' }
$modelId = if ($running -and $running.CommandLine -match '--alias\s+(\S+)') { $Matches[1] } else { 'local' }
$upstream = "http://127.0.0.1:$port/v1"

# --- shim --------------------------------------------------------------------
$shimUp = Test-Url "http://127.0.0.1:$ShimPort/v1/models"
if (-not $shimUp) {
    Write-Host "  starting anthropic shim on :$ShimPort -> $upstream" -ForegroundColor Cyan
    Start-Process python -ArgumentList (Join-Path $bin 'anthropic-shim.py'), '--upstream', $upstream, '--port', "$ShimPort" -WindowStyle Hidden
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Url "http://127.0.0.1:$ShimPort/v1/models") { $shimUp = $true; break }
        Start-Sleep -Milliseconds 400
    }
}
if (-not $shimUp) { throw "shim did not start on :$ShimPort" }

# --- claude ------------------------------------------------------------------
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$ShimPort"
$env:ANTHROPIC_AUTH_TOKEN = 'local'
$env:ANTHROPIC_MODEL = $modelId
$env:ANTHROPIC_SMALL_FAST_MODEL = $modelId
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
$env:API_TIMEOUT_MS = '600000'

Write-Host "  claude -> $upstream  (model id: $modelId)" -ForegroundColor Green
$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) { throw 'claude not found on PATH' }
& $claude.Source @Args
