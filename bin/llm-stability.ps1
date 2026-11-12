<#
.SYNOPSIS
    Prove that a model still holds its tokens/s once its context window is actually filled.

.DESCRIPTION
    The presets were widened to the measured ceiling (gemma4 32768 -> 131072, flint 16384 ->
    49152, coder 32768, gptoss 24576, qwen36 20480, coder36 32768). A ceiling is only worth
    having if decode speed survives being used, and every t/s number in the repository so far
    was taken on a *short* prompt. Attention cost grows with the tokens already in the window,
    so "40 t/s at 32k" is a claim about an empty 32k window, not a full one.

    This harness fills the window on purpose:

      * shallow  -  512 tokens of context: the number the old runs reported
      * mid      -  25 % of the model's own window
      * deep     -  60 % of the model's own window

    Decode speed is read from the server's own `timings.predicted_per_second`, with
    `cache_prompt: false` so nothing is reused between runs, and the shallow case is repeated
    to show run-to-run spread (the GPU clock ramps 1.6 -> 2.4 GHz and the room warms up).

    The verdict per model is "kept" when deep decode is within 10 % of shallow, "softened" when
    it degrades 10-25 %, "collapsed" beyond that. Prompt-processing speed is recorded too, but
    it is a different quantity and is not part of the verdict.

.PARAMETER Only
    Registry keys to test. Default: every key in llm-up.ps1.

.PARAMETER Depth
    Fractions of each model's window to fill, as strings. Default: 0.25 and 0.6.

.PARAMETER Reps
    Repeat count for the shallow (512-token) case. Default 3.

.EXAMPLE
    .\llm-stability.ps1
    .\llm-stability.ps1 -Only gemma4,flint -Depth 0.25,0.5 -Reps 2
#>
[CmdletBinding()]
param(
    [string[]]$Only = @(),
    [string[]]$Depth = @('0.25', '0.6'),
    [int]$Reps = 3,
    [int]$Shallow = 512,
    [int]$GenTokens = 200,
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bench\stability-at-depth.csv')
)

$ErrorActionPreference = 'Continue'
$bin = $PSScriptRoot
$repo = Split-Path $bin -Parent
$regFile = Join-Path $bin 'llm-up.ps1'
$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$log = Join-Path $env:TEMP 'llm-stability.log'
$serveLog = Join-Path $env:TEMP 'llama-serve.log'

New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
'key,model,port,window,label,depth_tokens,prompt_n,prompt_tps,pred_n,pred_tps,finish,vram_mb,sm_mhz,temp_c,seconds' |
    Set-Content $Out

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $log -Value $line
}
Set-Content -Path $log -Value "=== stability at depth, started $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="

# ---------------------------------------------------------------- the registry
# llm-up.ps1 has side effects, so it is parsed, never dotted in (GUIDE §3).
if (-not (Test-Path $regFile)) { throw "no registry at $regFile" }
$regText = Get-Content $regFile -Raw
$registry = [ordered]@{}
$pat = [regex]::new(
    "(?m)^\s*(?<key>\w+)\s*=\s*@\{(?<body>[^}]*)\}", 'IgnoreCase'
)
foreach ($m in $pat.Matches($regText)) {
    $body = $m.Groups['body'].Value
    # quoted field, and unquoted numeric field - the registry writes Port/Ctx bare
    $str = {
        param($name)
        $mm = [regex]::Match($body, "$name\s*=\s*'([^']*)'")
        if ($mm.Success) { return $mm.Groups[1].Value } else { return '' }
    }
    $num = {
        param($name)
        $mm = [regex]::Match($body, "$name\s*=\s*(\d+)")
        if ($mm.Success) { return [int]$mm.Groups[1].Value } else { return 0 }
    }
    $key = $m.Groups['key'].Value
    $registry[$key] = [pscustomobject]@{
        Key   = $key
        File  = (& $str 'File')
        Port  = (& $num 'Port')
        Alias = (& $str 'Alias')
        Ctx   = (& $num 'Ctx')
        Note  = (& $str 'Note')
    }
}
if ($registry.Count -eq 0) { throw "registry parsed to zero models" }
Write-Log ("registry: {0} models ({1})" -f $registry.Count, ($registry.Keys -join ', '))

$keys = if ($Only.Count -gt 0) { $Only } else { @($registry.Keys) }
$fractions = @()
foreach ($d in ($Depth -join ',') -split '[,\s]+') { if ($d) { $fractions += [double]::Parse($d, [Globalization.CultureInfo]::InvariantCulture) } }

# ---------------------------------------------------------------- helpers
function Stop-All {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    for ($i = 0; $i -lt 40; $i++) {
        if (@(Get-Process llama-server -ErrorAction SilentlyContinue).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (@(Get-Process llama-server -ErrorAction SilentlyContinue).Count -eq 0)
}

function Get-Vram {
    if (-not (Test-Path $smi)) { return 0 }
    $v = & $smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
    if ($v -and "$v" -match '^\d+') { return [int]$v } else { return 0 }
}

function Get-FreeVram {
    if (-not (Test-Path $smi)) { return 0 }
    $v = & $smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
    if ($v -and "$v" -match '^\d+') { return [int]$v } else { return 0 }
}

# Core clock and temperature travel with every row, because on a 8 mm-thick laptop the decode
# rate decays with heat and that decay is not a property of the context window.
function Get-Gpu {
    if (-not (Test-Path $smi)) { return [pscustomobject]@{ Sm = 0; Temp = 0 } }
    $v = & $smi --query-gpu=clocks.sm,temperature.gpu --format=csv,noheader,nounits 2>$null
    if ($v -match '^\s*(\d+)\s*,\s*(\d+)') {
        return [pscustomobject]@{ Sm = [int]$Matches[1]; Temp = [int]$Matches[2] }
    }
    return [pscustomobject]@{ Sm = 0; Temp = 0 }
}

function Get-Median($values) {
    $v = @($values | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($v.Count -eq 0) { return 0 }
    if ($v.Count % 2) { return [math]::Round($v[[int](($v.Count - 1) / 2)], 1) }
    return [math]::Round((($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2), 1)
}

function Write-Row($key, $m, $label, $r) {
    $g = Get-Gpu
    "$key,$($m.Alias),$($m.Port),$($m.Ctx),$label,$($r.PromptN),$($r.PromptN),$([math]::Round($r.PromptTps,1)),$($r.PredN),$([math]::Round($r.PredTps,1)),$($r.Finish),$(Get-Vram),$($g.Sm),$($g.Temp),$($r.Seconds)" |
        Add-Content $Out
}

function Wait-Healthy([int]$Port, [int]$Seconds = 180) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 700
        try {
            if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2).status -eq 'ok') {
                return [math]::Round($sw.Elapsed.TotalSeconds, 1)
            }
        } catch { }
    }
    return -1
}

# Filler that tokenises densely and boringly: no code fences, no markup, no repeated token.
$unit = @'
The archive held a record of every shipment that had passed through the northern depot since the
previous spring, and each entry was written in a clerk's careful hand. Weather delayed the third
convoy for four days, and the resulting backlog was sorted by destination rather than by date.
A note in the margin observed that the river crossing closed early that year, which forced the
southern route and added nearly a week to the round trip. Later entries grow shorter, as though
the writer had begun to trust that nobody would read them carefully.
'@

$unitTokens = 0
function Get-TokenCount([int]$Port, [string]$Text) {
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$Port/tokenize" -Method Post `
            -Body (@{ content = $Text } | ConvertTo-Json -Depth 4) -ContentType 'application/json' -TimeoutSec 120
        return [int]$r.tokens.Count
    } catch { return 0 }
}

function New-Filler([int]$Port, [int]$TargetTokens) {
    # grow geometrically against the server's real tokeniser, then trim by binary search
    $text = $unit
    $n = Get-TokenCount $Port $text
    if ($n -le 0) {
        # /tokenize unavailable: fall back to ~4 chars per token
        return ($unit * [math]::Ceiling($TargetTokens / 70.0))
    }
    $copies = [math]::Max(1, [int][math]::Ceiling($TargetTokens / [double]$n))
    $text = ($unit + "`n") * $copies
    $got = Get-TokenCount $Port $text
    # trim in 5 % steps to land close to the target without a thousand round trips
    $guard = 0
    while ($got -gt $TargetTokens -and $guard -lt 40) {
        $keep = [math]::Max(1, [int]($TargetTokens / [double]$got * $text.Length * 0.995))
        $text = $text.Substring(0, $keep)
        $got = Get-TokenCount $Port $text
        $guard++
    }
    return $text
}

function Invoke-Gen([int]$Port, [string]$Alias, [string]$Prompt, [int]$MaxTokens) {
    $body = @{
        model        = $Alias
        messages     = @(@{ role = 'user'; content = $Prompt })
        max_tokens   = $MaxTokens
        temperature  = 0.2
        cache_prompt = $false
    } | ConvertTo-Json -Depth 8
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
            -Body $body -ContentType 'application/json' -TimeoutSec 1800
        $sw.Stop()
        return [pscustomobject]@{
            Ok       = $true
            PredN    = [int]$r.timings.predicted_n
            PredTps  = [double]$r.timings.predicted_per_second
            PromptN  = [int]$r.timings.prompt_n
            PromptTps = [double]$r.timings.prompt_per_second
            Finish   = $r.choices[0].finish_reason
            Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{
            Ok = $false; PredN = 0; PredTps = 0; PromptN = 0; PromptTps = 0
            Finish = "error: $($_.Exception.Message)"; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    }
}

$question = "`n`nAnswer in one short paragraph: what does a depot clerk's margin note tell a historian that the main ledger does not?"

# ---------------------------------------------------------------- the run
$summary = @()
foreach ($key in $keys) {
    $m = $registry[$key]
    if (-not $m) { Write-Log "  ? '$key' is not in the registry - skipped"; continue }
    if ($m.Ctx -le 0 -or $m.Port -le 0) {
        Write-Log ("  ! {0}: registry gave port {1} / window {2} - refusing to measure a guess" -f $key, $m.Port, $m.Ctx)
        continue
    }

    Write-Log ""
    Write-Log ("=== {0}  ({1}, port {2}, window {3}) ===" -f $key, $m.Alias, $m.Port, $m.Ctx)
    if (-not (Stop-All)) { Write-Log "  ! a llama-server would not exit" }

    $free = Get-FreeVram
    Write-Log ("  free VRAM before load: {0} MiB" -f $free)

    $loadSw = [Diagnostics.Stopwatch]::StartNew()
    # Never pipe into the launcher: it starts a detached llama-server that inherits the handle,
    # so a pipeline never sees EOF even though the launcher itself has exited (GUIDE trap 8).
    # Redirect to files and wait on the process instead.
    $serveOut = Join-Path $env:TEMP 'stability-serve.out'
    $serveErr = Join-Path $env:TEMP 'stability-serve.err'
    $sp = Start-Process pwsh -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-File', (Join-Path $bin 'serve-model.ps1'), '-Model', $key, '-Ctx', "$($m.Ctx)") `
        -RedirectStandardOutput $serveOut -RedirectStandardError $serveErr
    if (-not $sp.WaitForExit(180000)) { Write-Log "  ! launcher did not return in 180 s" }
    $healthy = Wait-Healthy -Port $m.Port -Seconds 60
    $loadSw.Stop()
    if ($healthy -lt 0) {
        Write-Log ("  FAILED: nothing healthy on :{0} after the launcher returned" -f $m.Port)
        if (Test-Path $serveLog) { Get-Content $serveLog -Tail 8 | ForEach-Object { Write-Log "    $_" } }
        "$key,$($m.Alias),$($m.Port),$($m.Ctx),load,failed,0,0,0,0,-,0,$([math]::Round($loadSw.Elapsed.TotalSeconds,1))" |
            Add-Content $Out
        $summary += [pscustomobject]@{ key = $key; window = $m.Ctx; shallow = 0; deep = 0; verdict = 'load failed' }
        continue
    }
    Write-Log ("  loaded in {0:N1}s; VRAM {1} MiB" -f $loadSw.Elapsed.TotalSeconds, (Get-Vram))

    # Guard: the launcher must have served the registry's flags, not re-derived ones. It used to
    # derive n-cpu-moe from geometry and quietly served flint at 38 instead of 40, which loads at
    # 16k and dies at 49k - the exact class of drift this harness would otherwise measure blindly.
    $served = Get-Content $serveOut -Raw -ErrorAction SilentlyContinue
    if ($served -and $served -match 'ncmoe=(\d+)') {
        $servedNcmoe = [int]$Matches[1]
        $regNcmoe = 0
        $mm = [regex]::Match((Get-Content $regFile -Raw), "(?m)^\s*" + [regex]::Escape($key) + "\s*=\s*@\{[^}]*CpuMoe\s*=\s*(\d+)")
        if ($mm.Success) { $regNcmoe = [int]$mm.Groups[1].Value }
        if ($servedNcmoe -ne $regNcmoe) {
            Write-Log ("  ! ncmoe mismatch: served {0}, registry {1} - the launcher changed the flags" -f $servedNcmoe, $regNcmoe)
        }
        if ($served -match 'ctx=(\d+)') {
            $servedCtx = [int]$Matches[1]
            if ($servedCtx -ne $m.Ctx) {
                Write-Log ("  ! ctx mismatch: served {0}, registry {1}" -f $servedCtx, $m.Ctx)
            }
        }
    }

    # warm the clocks: one throwaway request before anything is timed
    $null = Invoke-Gen -Port $m.Port -Alias $m.Alias -Prompt 'Say hello.' -MaxTokens 64
    Start-Sleep -Milliseconds 800

    $preTps = @()
    for ($rep = 1; $rep -le $Reps; $rep++) {
        $r = Invoke-Gen -Port $m.Port -Alias $m.Alias -Prompt $question -MaxTokens $GenTokens
        $label = "shallow-r$rep"
        Write-Log ("  {0,-13} prompt {1,6} tok | decode {2,6} tok @ {3,6:N1} t/s | sm {4} MHz {5}C | {6}s" -f
            $label, $r.PromptN, $r.PredN, $r.PredTps, (Get-Gpu).Sm, (Get-Gpu).Temp, $r.Seconds)
        Write-Row $key $m $label $r
        if ($r.Ok) { $preTps += $r.PredTps }
    }

    foreach ($f in $fractions) {
        $target = [int][math]::Floor($m.Ctx * $f)
        if ($target -le $Shallow) { continue }
        $label = "depth-$([int]($f * 100))pct"
        Write-Log ("  {0}: filling to ~{1} tokens..." -f $label, $target)
        $filler = New-Filler -Port $m.Port -TargetTokens $target
        $prompt = $filler + $question
        $r = Invoke-Gen -Port $m.Port -Alias $m.Alias -Prompt $prompt -MaxTokens $GenTokens
        Write-Log ("  {0,-13} prompt {1,6} tok @ {2,6:N0} t/s prefill | decode {3,6} tok @ {4,6:N1} t/s | sm {5} MHz {6}C | {7}s" -f
            $label, $r.PromptN, $r.PromptTps, $r.PredN, $r.PredTps, (Get-Gpu).Sm, (Get-Gpu).Temp, $r.Seconds)
        Write-Row $key $m $label $r
        $summary += [pscustomobject]@{
            key   = $key
            window = $m.Ctx
            label = $label
            deepN = $r.PromptN
            tps   = [math]::Round($r.PredTps, 1)
        }
    }

    # Bookend the run: the same shallow measurement again, after the deep work. Without this a
    # drop over the window is indistinguishable from the laptop simply heating up over five
    # minutes - and this machine does throttle (1627 MHz idle, ~1400 MHz sustained under load).
    $postTps = @()
    for ($rep = 1; $rep -le [math]::Max(2, $Reps - 1); $rep++) {
        $r = Invoke-Gen -Port $m.Port -Alias $m.Alias -Prompt $question -MaxTokens $GenTokens
        $label = "shallow-post$rep"
        Write-Log ("  {0,-13} prompt {1,6} tok | decode {2,6} tok @ {3,6:N1} t/s | sm {4} MHz {5}C | {6}s" -f
            $label, $r.PromptN, $r.PredN, $r.PredTps, (Get-Gpu).Sm, (Get-Gpu).Temp, $r.Seconds)
        Write-Row $key $m $label $r
        if ($r.Ok) { $postTps += $r.PredTps }
    }

    $preMed = Get-Median $preTps
    $postMed = Get-Median $postTps
    $drift = if ($preMed -gt 0) { [math]::Round(($postMed - $preMed) / $preMed * 100, 1) } else { 0 }
    Write-Log ("  shallow median {0:N1} t/s; after the deep runs {1:N1} t/s ({2:+0.0;-0.0}% - clock drift, not depth)" -f $preMed, $postMed, $drift)

    $summary += [pscustomobject]@{ key = $key; window = $m.Ctx; label = 'shallow'; deepN = $Shallow; tps = $preMed; drift = $drift; post = $postMed }

    $null = Stop-All
    Start-Sleep -Milliseconds 500
}

# ---------------------------------------------------------------- verdict
Write-Log ""
Write-Log "================ comparison ================"
$byModel = $summary | Where-Object { $_.label -ne 'load failed' } | Group-Object key
$verdicts = @()
foreach ($g in $byModel) {
    $sh = $g.Group | Where-Object { $_.label -eq 'shallow' } | Select-Object -First 1
    $deepRows = $g.Group | Where-Object { $_.label -like 'depth-*' }
    foreach ($d in $deepRows) {
        $ratio = if ($sh.tps -gt 0) { [math]::Round(($d.tps / $sh.tps) * 100, 1) } else { 0 }
        # Two independent corrections, so the verdict is about depth and nothing else:
        #   vs pre  - the headline ratio the table reports
        #   vs post - the same ratio against the *post* bookend, which already contains the
        #             heat the deep run put into the machine
        $vsPost = if ($sh.post -gt 0) { [math]::Round(($d.tps / $sh.post) * 100, 1) } else { 0 }
        $verdict = if ($ratio -ge 90) { 'kept' } elseif ($ratio -ge 75) { 'softened' } else { 'collapsed' }
        $line = "  {0,-9} {1,-8} {2,7} tok | {3,6:N1} -> {4,6:N1} t/s | {5,5}% of pre, {6,5}% of post | {7}" -f
            $g.Name, $d.label, $d.deepN, $sh.tps, $d.tps, $ratio, $vsPost, $verdict
        Write-Log $line
        $verdicts += [pscustomobject]@{
            key = $g.Name; label = $d.label; window = $sh.window; depth = $d.deepN
            shallow = $sh.tps; deep = $d.tps; kept = $ratio; vs_post = $vsPost
            drift = $sh.drift; verdict = $verdict
        }
    }
    Write-Log ("  {0,-9} clock drift over the run: {1:+0.0;-0.0}% ({2:N1} -> {3:N1} t/s at 512 tok)" -f $g.Name, $sh.drift, $sh.tps, $sh.post)
}

$verdicts | ConvertTo-Json -Depth 4 | Set-Content (Join-Path (Split-Path $Out) 'stability-verdicts.json')
Write-Log ("done; csv {0}" -f $Out)
