<#
.SYNOPSIS
    Start (or list) a local llama.cpp server for one of the models in llm\models.

.DESCRIPTION
    One model at a time can hold the 8 GB card, so this stops whatever llama-server is running
    before starting the new one. Each model keeps a FIXED port and a FIXED alias, because dsh
    and Claude Code routes are configured against those two values - changing them silently
    breaks every client.

.EXAMPLE
    llm-up.ps1                  # what is available, what is running
    llm-up.ps1 qwen3            # start Qwen3-8B on :8081
    llm-up.ps1 flint -Foreground
    llm-up.ps1 -Stop
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Model,
    [switch]$Stop,
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'
$modelsDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'models')

# The GGUFs may live only in the Desktop bundle (it hard-links them, or holds the one copy after a
# Download). Look there before calling a model missing, so the registry runs from either place.
$bundleModels = Join-Path $env:USERPROFILE 'Desktop\Local-LLM-Project\llama.cpp\models'
function Resolve-ModelFile([string]$name) {
    $local = Join-Path $modelsDir $name
    if (Test-Path $local) { return $local }
    $bundled = Join-Path $bundleModels $name
    if (Test-Path $bundled) { return $bundled }
    return $null
}

# name -> file, port, alias, and the flags that were actually measured to be best.
# Update this table (not the routes) when a model is replaced.
$registry = [ordered]@{
    gemma4  = @{ File = 'gemma-4-E4B-it-q4kxl.gguf';  Port = 8083; Alias = 'gemma-4-e4b';       Ctx = 131072; CpuMoe = 0;  Threads = 20; Note = '4B dense Gemma 4, 74.1 t/s at full 131k ctx, native tool calls - best agent default; keeps 62 % of its speed at 78k tok'; Mcp = 'rea' }
    flint   = @{ File = 'flint-nvfp4-40b.gguf';       Port = 8080; Alias = 'flint-nvfp4-40b';   Ctx = 49152; CpuMoe = 40; Threads = 16; Note = '40B MoE, 29.8 t/s, max ctx 49152; keeps 84 % at 29k tok'; Mcp = 'rea' }
    qwen3   = @{ File = 'Qwen3-8B-Q4_K_M.gguf';       Port = 8081; Alias = 'qwen3-8b';          Ctx = 16384; CpuMoe = 0;  Threads = 20; Note = '8B dense, 59.0 t/s, max ctx 16384 (20480 OOM); keeps 82 % at 9800 tok; no MCP tools - the 39-tool default costs 12402 of these 16384 tokens, leaving no room for a tool result' }
    coder   = @{ File = 'qwen2.5-coder-7b-q4km.gguf'; Port = 8081; Alias = 'qwen2.5-coder-7b';  Ctx = 32768; CpuMoe = 0;  Threads = 20; Note = '7B dense coder, 50.3 t/s at full 32768 ctx, no native tools; keeps 80 % at 19k tok' }
    gptoss  = @{ File = 'gpt-oss-20b-MXFP4.gguf';     Port = 8082; Alias = 'gpt-oss-20b';       Ctx = 32768; CpuMoe = 15; Threads = 20; Note = '20B MoE, 30.3 t/s at max ctx 32768 (A/B 2026-11-14, 3 rounds / 6 loads: 30.3 t/s at both 24576/ncmoe 14 and 32768/ncmoe 15 - the extra 8192 tokens are free; 14 is a CUDA OOM at the wider window); no native tools; keeps 93 % at 15k tok' }
    coder36 = @{ File = 'qwen3.6-27b-a3b-coder-q4km.gguf'; Port = 8085; Alias = 'qwen3.6-27b-a3b-coder'; Ctx = 57344; CpuMoe = 30; Threads = 16; Note = '27B MoE coder (3B active), 37.7 t/s at ctx 57344 (A/B 2026-11-14: 49152/ncmoe 29 was 38.2 t/s, so 8192 more tokens cost 1.3 %, inside the noise; earlier A/B on 2026-11-13: +11.6 % against 32768/ncmoe 26); n-cpu-moe 30 at this window, 27 is a CUDA OOM at 49152; native tool calls; thinks first (docs for the flags); keeps 93 % at 20k tok'; Mcp = 'rea' }
  qwen36  = @{ File = 'qwen3.6-35b-a3b-mtp-q4km.gguf'; Port = 8084; Alias = 'qwen3.6-35b-a3b'; Ctx = 40960; CpuMoe = 31; Threads = 16; Note = '35B MoE 8/256 experts, 35.3 t/s at ctx 40960 (A/B 2026-11-13: +21.3 % against 20480/ncmoe 30; 4/4 loads at ncmoe 31, 32 crashed once); native tools; keeps 85 % at 12k tok; the 39-tool REA catalog is 30 % of this window, not 61 %'; Mcp = 'rea' }
    dsv2    = @{ File = 'deepseek-coder-v2-lite-maple-sub5gb.gguf'; Port = 8086; Alias = 'deepseek-coder-v2-lite'; Ctx = 18432; CpuMoe = 0; Threads = 16; Note = '13.5B MoE coder (2.4B active, 6/54 experts), 4.5 GB at 2.87 bpw; q8_0 KV is what buys this window - f16 stops at 8192; no native tool calls'; Kv = 'q8_0' }
}

function Get-Running {
    Get-Process llama-server -ErrorAction SilentlyContinue
}

function Show-Table {
    $running = Get-Running
    $port = $null
    if ($running) {
        $cmd = (Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue).CommandLine
        if ($cmd -match '--port\s+(\d+)') { $port = $Matches[1] }
    }
    Write-Host ''
    Write-Host '  model    port   tools  id                      status' -ForegroundColor DarkGray
    Write-Host '  -------------------------------------------------------------------------' -ForegroundColor DarkGray
    foreach ($k in $registry.Keys) {
        $m = $registry[$k]
        $exists = [bool](Resolve-ModelFile $m.File)
        $state = if (-not $exists) { 'not downloaded' }
                 elseif ($running -and $port -eq "$($m.Port)") { "RUNNING on :$($m.Port)" }
                 else { 'ready' }
        $colour = if (-not $exists) { 'DarkGray' } elseif ($state -like 'RUNNING*') { 'Green' } else { 'Gray' }
        $tools = if ($m.Mcp) { $m.Mcp } else { '-' }
        Write-Host ('  {0,-8} {1,-6} {2,-6} {3,-23} {4}' -f $k, $m.Port, $tools, $m.Alias, $state) -ForegroundColor $colour
    }
    Write-Host ''
    foreach ($k in $registry.Keys) {
        $m = $registry[$k]
        if (Resolve-ModelFile $m.File) {
            Write-Host ("  {0,-8} {1}" -f $k, $m.Note) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host '  start one with:  llm-up.ps1 <model>' -ForegroundColor DarkGray
    Write-Host ''
}

if ($Stop) {
    $p = Get-Running
    if ($p) { $p | Stop-Process -Force; Write-Host '  stopped llama-server' -ForegroundColor Yellow }
    else { Write-Host '  nothing running' -ForegroundColor DarkGray }
    return
}

if (-not $Model) { Show-Table; return }

$key = $registry.Keys | Where-Object { $_ -like "$Model*" } | Select-Object -First 1
if (-not $key) { throw "Unknown model '$Model'. Known: $($registry.Keys -join ', ')" }
$cfg = $registry[$key]
$file = Resolve-ModelFile $cfg.File
if (-not $file) { throw "Not downloaded: $($cfg.File) - press Download in llama-direct.exe" }

# only one model fits in 8 GB of VRAM
Get-Running | ForEach-Object { $_.Kill(); $_ }
Start-Sleep -Milliseconds 700

$serverArgs = @(
    '-Model', $file, '-Backend', 'cuda', '-Port', $cfg.Port, '-Alias', $cfg.Alias
    '-Ctx', $cfg.Ctx, '-Threads', $cfg.Threads
)
if ($cfg.CpuMoe -gt 0) { $serverArgs += @('-CpuMoe', $cfg.CpuMoe) }
if ($cfg.Kv) { $serverArgs += @('-CacheK', $cfg.Kv, '-CacheV', $cfg.Kv) }
if ($cfg.Mcp) { $serverArgs += @('-Mcp', $cfg.Mcp) }

Write-Host ("  starting {0}  ->  http://127.0.0.1:{1}/v1   (id: {2})" -f $key, $cfg.Port, $cfg.Alias) -ForegroundColor Cyan

if ($Foreground) {
    & (Join-Path $PSScriptRoot 'llm-server.ps1') @serverArgs
    return
}

Start-Process pwsh -ArgumentList (@('-NoProfile', '-File', (Join-Path $PSScriptRoot 'llm-server.ps1')) + $serverArgs) -WindowStyle Hidden

# wait until it answers, so the caller never races the load
for ($i = 0; $i -lt 90; $i++) {
    try {
        $h = Invoke-RestMethod "http://127.0.0.1:$($cfg.Port)/health" -TimeoutSec 2
        if ($h.status -eq 'ok') {
            Write-Host ("  ready after ~{0:N0}s - openai endpoint http://127.0.0.1:{1}/v1" -f ($i * 1.5), $cfg.Port) -ForegroundColor Green
            & "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=memory.used,temperature.gpu --format=csv,noheader 2>$null
            return
        }
    } catch { }
    Start-Sleep -Milliseconds 1500
}
Write-Host '  server did not become healthy within 135 s' -ForegroundColor Red
