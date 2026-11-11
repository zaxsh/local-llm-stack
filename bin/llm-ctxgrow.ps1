<#
.SYNOPSIS
    Find the largest context a model ACTUALLY loads by trying, not by extrapolating free VRAM.

.DESCRIPTION
    llm-maxctx.ps1 extrapolates "extra tokens = spare VRAM / bytes-per-token". That works when the
    card has headroom, but this machine usually has almost none left at 16k (LM Studio, Magnitude
    and Steam stay resident), so the extrapolation goes NEGATIVE and proposes a smaller context
    than the one already proven to work.

    Loading is the ground truth. This walks the candidate list in ascending order, keeps the last
    context that served a completion, and stops at the first one that fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Model,
    # [string], not [int[]]: `pwsh -File script.ps1 -Candidates 1,2,3` hands over ONE string "1,2,3".
    [string]$Candidates,
    [int]$MaxTokens = 200,
    [string]$Out
)
# NB: assign to a NEW variable. $Candidates is declared [string], so assigning an array to it
# would immediately coerce back to a space-joined string (PowerShell keeps parameter types).
$ctxList = @($Candidates -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$ErrorActionPreference = 'Continue'
$bin = $PSScriptRoot
$modelsDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'models')
$exe = (Join-Path (Split-Path $PSScriptRoot -Parent) 'llama.cpp\b12255\cuda\llama-server.exe')
$upPath = Join-Path $bin 'llm-up.ps1'
$up = Get-Content $upPath -Raw

$e = $null
foreach ($m in [regex]::Matches($up, "(?m)^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)';\s*Port\s*=\s*(\d+);\s*Alias\s*=\s*'([^']+)';\s*Ctx\s*=\s*(\d+);\s*CpuMoe\s*=\s*(\d+);\s*Threads\s*=\s*(\d+)")) {
    if ($m.Groups[1].Value -eq $Model) {
        $e = @{ File = $m.Groups[2].Value; Port = [int]$m.Groups[3].Value; Alias = $m.Groups[4].Value
                Ctx = [int]$m.Groups[5].Value; CpuMoe = [int]$m.Groups[6].Value; Threads = [int]$m.Groups[7].Value }
    }
}
if (-not $e) { throw "unknown model '$Model' in llm-up.ps1" }
if (-not $ctxList -or $ctxList.Count -eq 0) { $ctxList = @($e.Ctx) }

function Stop-All {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    for ($i = 0; $i -lt 24; $i++) {
        if (@(Get-Process llama-server -ErrorAction SilentlyContinue).Count -eq 0) { break }
        Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Milliseconds 600
}

function Try-Ctx([int]$ctx) {
    Stop-All
    $a = @('-m', (Join-Path $modelsDir $e.File), '--alias', $e.Alias, '--host', '127.0.0.1',
        '--port', "$($e.Port)", '-c', "$ctx", '--jinja', '--metrics', '--no-warmup',
        '-t', "$($e.Threads)", '-tb', "$($e.Threads)", '-ngl', '99', '-fa', 'on',
        '-ctk', 'f16', '-ctv', 'f16')
    if ($e.CpuMoe -gt 0) { $a += @('--n-cpu-moe', "$($e.CpuMoe)") }
    $p = Start-Process $exe -ArgumentList $a -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$env:TEMP\grow.out" -RedirectStandardError "$env:TEMP\grow.err"
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { return @{ OK = $false; Tps = 0; Why = 'exited' } }
        try { if ((Invoke-RestMethod "http://127.0.0.1:$($e.Port)/health" -TimeoutSec 1).status -eq 'ok') { break } } catch { }
    }
    $ok = $false
    try { $ok = (Invoke-RestMethod "http://127.0.0.1:$($e.Port)/health" -TimeoutSec 2).status -eq 'ok' } catch { }
    if (-not $ok) { if (-not $p.HasExited) { $p | Stop-Process -Force }; return @{ OK = $false; Tps = 0; Why = 'no health' } }

    $tps = 0
    try {
        $body = @{ model = $e.Alias; max_tokens = $MaxTokens; temperature = 0.2
                   messages = @(@{ role = 'user'; content = 'List three ways a KV cache grows with context length.' }) } | ConvertTo-Json -Depth 6
        $r = Invoke-RestMethod "http://127.0.0.1:$($e.Port)/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900
        $tps = [math]::Round($r.timings.predicted_per_second, 1)
    } catch { if (-not $p.HasExited) { $p | Stop-Process -Force }; return @{ OK = $false; Tps = 0; Why = 'completion failed' } }

    if (-not $p.HasExited) { $p | Stop-Process -Force }
    return @{ OK = $true; Tps = $tps; Why = 'ok' }
}

$rows = @()
$best = 0; $bestTps = 0
foreach ($c in $ctxList) {
    Write-Host ("  {0,-8} trying ctx {1}" -f $Model, $c) -ForegroundColor Cyan
    $r = Try-Ctx $c
    Write-Host ("           {0} t/s  ({1})" -f $r.Tps, $r.Why) -ForegroundColor $(if ($r.OK) { 'Green' } else { 'Red' })
    $rows += [pscustomobject]@{ Model = $Model; Ctx = $c; OK = $r.OK; Tps = $r.Tps; Why = $r.Why }
    if (-not $r.OK) { break }
    $best = $c; $bestTps = $r.Tps
}
Stop-All
Write-Host ""
Write-Host ("  $Model : largest context that loads = {0}  ({1} t/s)" -f $best, $bestTps) -ForegroundColor Yellow
if ($Out) { $rows | Export-Csv $Out -NoTypeInformation -Encoding UTF8 }
$rows | Format-Table -AutoSize
