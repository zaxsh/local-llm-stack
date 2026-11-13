<#
.SYNOPSIS
    Does a wider context window cost generation speed? Measure A and B alternately, not once each.

.DESCRIPTION
    `llm-ncmoe-sweep.ps1` answers "which --n-cpu-moe loads", but its numbers cannot be compared
    across runs: it starts a cold card, generates twice, keeps the best, and moves on. On this
    laptop the SM clock sits at ~1600 MHz when idle and only reaches ~2600 MHz after a few seconds
    of real work, so the first generation of any run is slow for reasons that have nothing to do
    with the flag under test. Measured that way, a 40 960 window looked both 20 % faster and 30 %
    slower than a 20 480 one on consecutive attempts.

    This harness measures one question and nothing else: given two (Ctx, CpuMoe) configurations,
    which is faster, and by how much? It alternates A, B, A, B so thermal drift lands on both
    arms instead of on whichever ran last, warms the card with a discard generation, and reports
    the median of several 384-token decodes per arm. Absolute t/s still depends on the room; the
    ratio does not.

.PARAMETER Model
    Path to the GGUF.

.PARAMETER Alias
    Model id the server answers to inside the benchmark.

.PARAMETER ACtx / ACpuMoe
    Arm A: the configuration in use today.

.PARAMETER BCtx / BCpuMoe
    Arm B: the candidate.

.PARAMETER Rounds
    How many A→B alternations. Two rounds is four server loads; three is six.

.PARAMETER Reps
    Generations per arm per round, after the warm-up. Median is taken.

.PARAMETER Out
    CSV to write.

.EXAMPLE
    pwsh -File bin\llm-window-ab.ps1 -Model .\models\qwen3.6-35b-a3b-mtp-q4km.gguf `
        -ACtx 20480 -ACpuMoe 30 -BCtx 40960 -BCpuMoe 31 -Alias qwen3.6-35b-a3b
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][int]$ACtx,
    [Parameter(Mandatory = $true)][int]$ACpuMoe,
    [Parameter(Mandatory = $true)][int]$BCtx,
    [Parameter(Mandatory = $true)][int]$BCpuMoe,
    [string]$Alias = 'ab',
    [int]$Rounds = 2,
    [int]$Reps = 2,
    [int]$GenTokens = 384,
    [int]$Port = 8091,
    [int]$Threads = 16,
    # KV cache type per arm, so a window can be traded against precision: f16 is the fast default,
    # q8_0 halves the cache and buys a window the card cannot otherwise hold.
    [string]$AKv = 'f16',
    [string]$BKv = 'f16',
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bench\window-ab.csv')
)

$ErrorActionPreference = 'Continue'
$exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'llama.cpp\b12255\cuda\llama-server.exe'
if (-not (Test-Path $exe)) { throw "no llama-server at $exe" }
if (-not (Test-Path $Model)) { throw "no model at $Model" }
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

$prompt = 'Write a Python function that reads a CSV into a list of dicts, handling quoted fields and escaped quotes, then explain it briefly.'
$base = "http://127.0.0.1:$Port"

function Get-Median($values) {
    $s = @($values | Sort-Object)
    if (-not $s.Count) { return 0 }
    if ($s.Count % 2) { return [double]$s[[int](($s.Count - 1) / 2)] }
    return ([double]$s[$s.Count / 2 - 1] + [double]$s[$s.Count / 2]) / 2
}

function Stop-Server {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    # VRAM is returned by the driver a moment after the process dies; a load started too early
    # fails with a CUDA OOM that looks like "this configuration does not fit".
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $used = (nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -replace '[^\d]', ''
        if ([int]$used -lt 1500) { break }
    }
}

function Start-Arm([hashtable]$arm) {
    Stop-Server
    $log = "$env:TEMP\ab-$($arm.Tag).log"
    Remove-Item $log -ErrorAction SilentlyContinue
    $a = @('-m', $Model, '-c', "$($arm.Ctx)", '--host', '127.0.0.1', '--port', "$Port",
        '--jinja', '--metrics', '--no-warmup', '-t', "$Threads", '-tb', "$Threads",
        '-ngl', '99', '-fa', 'on', '-ctk', $arm.Kv, '-ctv', $arm.Kv,
        '--n-cpu-moe', "$($arm.CpuMoe)", '--alias', $Alias)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $exe -ArgumentList $a -PassThru -WindowStyle Hidden `
         -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    for ($i = 0; $i -lt 360; $i++) {
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { break }
        try { if ((Invoke-RestMethod "$base/health" -TimeoutSec 2).status -eq 'ok') { break } } catch { }
    }
    $arm.LoadS = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($p.HasExited -or $arm.LoadS -gt 179) { $arm.Loaded = $false; return $arm }
    $arm.Loaded = $true
    # What the server really allocated - the flag asked for $arm.Ctx, this proves it.
    try { $arm.NCtx = [int](Invoke-RestMethod "$base/props" -TimeoutSec 5).default_generation_settings.n_ctx } catch { $arm.NCtx = 0 }
    return $arm
}

function Invoke-Gen {
    $body = @{ model = $Alias; messages = @(@{ role = 'user'; content = $prompt })
               max_tokens = $GenTokens; temperature = 0.2; cache_prompt = $false } |
            ConvertTo-Json -Depth 8
    $r = Invoke-RestMethod "$base/v1/chat/completions" -Method Post -Body $body `
          -ContentType 'application/json' -TimeoutSec 900
    return [double]$r.timings.predicted_per_second
}

'round,arm,ctx,ncmoe,kv,tps,load_s,n_ctx' | Set-Content $Out
$arms = @(
    @{ Tag = 'A'; Ctx = $ACtx; CpuMoe = $ACpuMoe; Kv = $AKv; Tps = @() },
    @{ Tag = 'B'; Ctx = $BCtx; CpuMoe = $BCpuMoe; Kv = $BKv; Tps = @() }
)

for ($round = 1; $round -le $Rounds; $round++) {
    foreach ($arm in $arms) {
        Write-Host ("  round {0}  arm {1}  ctx {2}  ncmoe {3}  kv {4}  " -f $round, $arm.Tag, $arm.Ctx, $arm.CpuMoe, $arm.Kv) -NoNewline
        $arm = Start-Arm $arm
        if (-not $arm.Loaded) {
            Write-Host ("FAILED to load in {0}s" -f $arm.LoadS) -ForegroundColor Red
            "$round,$($arm.Tag),$($arm.Ctx),$($arm.CpuMoe),$($arm.Kv),0,$($arm.LoadS),0" | Add-Content $Out
            continue
        }
        $null = Invoke-Gen            # discard: brings the SM clock up, and its number belongs to the ramp
        $vals = @()
        for ($r = 1; $r -le $Reps; $r++) { $vals += Invoke-Gen }
        $med = [math]::Round((Get-Median $vals), 1)
        $arm.Tps += $med
        Write-Host ("{0,5:N1} t/s   (load {1}s, n_ctx {2})" -f $med, $arm.LoadS, $arm.NCtx) -ForegroundColor Green
        "$round,$($arm.Tag),$($arm.Ctx),$($arm.CpuMoe),$($arm.Kv),$med,$($arm.LoadS),$($arm.NCtx)" | Add-Content $Out
    }
}

Stop-Server
$a = [math]::Round((Get-Median $arms[0].Tps), 1)
$b = [math]::Round((Get-Median $arms[1].Tps), 1)
Write-Host ''
if (-not $a -or -not $b) {
    Write-Host "  one arm never loaded - no comparison to make" -ForegroundColor Red
    exit 1
}
$delta = [math]::Round(100.0 * ($b - $a) / $a, 1)
$colour = if ($delta -le -5) { 'DarkYellow' } else { 'Green' }
Write-Host ("  A ctx {0} ncmoe {1} kv {2}: {3:N1} t/s" -f $ACtx, $ACpuMoe, $AKv, $a)
Write-Host ("  B ctx {0} ncmoe {1} kv {2}: {3:N1} t/s  ({4:+0.0;-0.0} %)" -f $BCtx, $BCpuMoe, $BKv, $b, $delta) -ForegroundColor $colour
Write-Host ("  rows written to {0}" -f $Out) -ForegroundColor DarkGray
