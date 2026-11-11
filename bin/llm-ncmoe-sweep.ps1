<#
.SYNOPSIS
    Sweep --n-cpu-moe for one MoE model and report generation speed per setting.

.DESCRIPTION
    Drives llama-server directly instead of going through serve-model, so each configuration is
    a clean start: process dies, VRAM returns, next setting begins. Higher -n-cpu-moe pushes more
    expert tensors to DDR5 (~60 GB/s) instead of VRAM (~448 GB/s), so speed should fall as the
    number rises - the point is to find the lowest value that still fits, not the highest that
    loads.

    A configuration that fails to load is recorded as OOM rather than silently skipped.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Model,
    # Comma- or space-separated. Two separate traps live here, both worth knowing:
    #   1. `pwsh -File script.ps1 -Values 20,24` can collapse into one string before it can bind to
    #      [int[]], so accept the string and split it here.
    #   2. A [string] parameter keeps its type constraint for the whole scope, so reassigning it to
    #      the split array silently coerces the array BACK to one space-joined string - and then
    #      `foreach` over that string runs exactly once with "20 24" as the value. Hence $targets.
    [string]$Values = '20,24,26,28,30,32,34',
    [int]$Port = 8090,
    [int]$Ctx = 16384,
    [int]$Threads = 16,
    [int]$MaxTokens = 250,
    [string]$Alias = 'sweep',
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bench\ncmoe-sweep.csv')
)

$ErrorActionPreference = 'Continue'
$targets = @($Values -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
if ($targets.Count -eq 0) {
    Write-Host "  no numbers in -Values '$Values' - nothing to sweep" -ForegroundColor Red
    exit 1
}
$exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'llama.cpp\b12255\cuda\llama-server.exe')
$log = "$env:TEMP\sweep.log"
$err = "$env:TEMP\sweep.err"
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
'value,tps,tokens,load_s,status' | Set-Content $Out

$prompt = 'Write a Python function that parses a CSV file into a list of dicts, handling quoted fields, then explain in two sentences how it handles escaped quotes.'

foreach ($n in $targets) {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Remove-Item $log, $err -ErrorAction SilentlyContinue

    $a = @('-m', $Model, '-c', "$Ctx", '--host', '127.0.0.1', '--port', "$Port",
        '--jinja', '--metrics', '--no-warmup', '-t', "$Threads", '-tb', "$Threads",
        '-ngl', '99', '-fa', 'on', '-ctk', 'f16', '-ctv', 'f16',
        '--n-cpu-moe', "$n", '--alias', $Alias)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $exe -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err

    $up = $false
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { break }
        try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2).status -eq 'ok') { $up = $true; break } } catch { }
    }
    $load = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    if (-not $up) {
        $why = if ($p.HasExited) { 'crashed' } else { 'timeout' }
        $tail = (Get-Content $err -Tail 3 -ErrorAction SilentlyContinue) -join ' | '
        Write-Host ("  ncmoe {0,3}: {1}  ({2})" -f $n, $why, $tail) -ForegroundColor Red
        "$n,0,0,$load,$why" | Add-Content $Out
        if (-not $p.HasExited) { $p | Stop-Process -Force }
        continue
    }

    $body = @{ model = $Alias; messages = @(@{ role = 'user'; content = $prompt }); max_tokens = $MaxTokens; temperature = 0.2; cache_prompt = $false } | ConvertTo-Json -Depth 8
    $best = 0; $toks = 0
    foreach ($run in 1..2) {
        try {
            $r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600
            $tps = [math]::Round($r.timings.predicted_per_second, 1)
            $toks = $r.timings.predicted_n
            if ($tps -gt $best) { $best = $tps }
        } catch { }
    }
    Write-Host ("  ncmoe {0,3}: {1,5:N1} t/s  loaded in {2}s" -f $n, $best, $load) -ForegroundColor $(if ($best -gt 0) { 'Green' } else { 'Red' })
    "$n,$best,$toks,$load,ok" | Add-Content $Out
    $p | Stop-Process -Force
    Start-Sleep -Seconds 2
}

Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host ""
$rows = Import-Csv $Out
$rows | Format-Table -AutoSize
$best = $rows | Where-Object { $_.status -eq 'ok' } | Sort-Object { [double]$_.tps } -Descending | Select-Object -First 1
if ($best) { Write-Host ("  BEST: --n-cpu-moe {0} -> {1} t/s" -f $best.value, $best.tps) -ForegroundColor Yellow }
