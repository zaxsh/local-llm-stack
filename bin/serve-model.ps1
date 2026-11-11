<#
.SYNOPSIS
    Serve ANY model on this machine with flags chosen from its own geometry.

.DESCRIPTION
    One entry point that works for a registry name, a filename in llm\models, a full path, or
    an Ollama tag. It reads the GGUF header, decides whether the model is dense or MoE, how much
    of it fits in VRAM, and derives -ngl / -n-cpu-moe / threads from that - then starts
    llama-server and prints exactly how to connect to it.

    Only one model fits on the 8 GB card at a time, so any running llama-server is stopped first.

.PARAMETER Model
    One of:
      gemma4                        registry key from llm-up.ps1 (if the name matches one)
      Qwen3-8B-Q4_K_M.gguf          a file in .\models
      C:\path\to\model.gguf         a full path
      qwen3.6:35b-a3b-mtp-q4_K_M    an Ollama tag (must already be pulled)

.PARAMETER SpecType
    Speculative decoding mode. 'draft-mtp' uses the model's own MTP head (free speedup on
    models that ship one, like qwen3.6:35b-a3b-mtp). 'ngram-cache' needs no draft model at all
    and helps when output repeats the prompt. 'none' disables it.

.PARAMETER DraftModel
    Separate small draft model for classic speculative decoding (used with SpecType draft-simple).

.EXAMPLE
    .\serve-model.ps1 -List
    .\serve-model.ps1 gemma4
    .\serve-model.ps1 qwen3.6:35b-a3b-mtp-q4_K_M -SpecType draft-mtp -Ctx 16384 -Port 8084
    .\serve-model.ps1 flint -CpuMoe 40 -Foreground
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Model,

    [int]$Port = 0,                 # 0 = pick from the registry, else 8080
    [string]$Alias = '',
    [int]$Ctx = 16384,
    [int]$GpuLayers = 99,
    [int]$CpuMoe = -1,              # -1 = derive from geometry
    [int]$Threads = 0,              # 0 = derive from geometry
    [string]$CacheK = 'f16',
    [string]$CacheV = 'f16',

    [ValidateSet('', 'none', 'draft-simple', 'draft-eagle3', 'draft-mtp', 'draft-dflash', 'draft-dspark', 'ngram-cache', 'ngram-mod', 'ngram-simple')]
    [string]$SpecType = '',

    [string]$DraftModel = '',
    [string[]]$Extra = @(),

    [ValidateSet('auto', 'cuda', 'vulkan', 'openvino', 'cpu')]
    [string]$Backend = 'auto',

    [switch]$Foreground,
    [switch]$Stop,
    [switch]$List,
    [switch]$NoAutoStop
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot
$modelsDir = Join-Path (Split-Path $bin -Parent) 'models'
$llamaRoot = Join-Path (Split-Path $bin -Parent) 'llama.cpp'

# ---------------------------------------------------------------- stop / list
if ($Stop) {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "  all llama-server processes stopped" -ForegroundColor Green
    return
}

function Resolve-ModelFile([string]$name) {
    if (Test-Path $name) { return (Resolve-Path $name).Path }
    $c = Join-Path $modelsDir $name
    if (Test-Path $c) { return (Resolve-Path $c).Path }
    $c = Join-Path $modelsDir "$name.gguf"
    if (Test-Path $c) { return (Resolve-Path $c).Path }

    # Ollama tag -> blob, via its manifest. Same blob the model was pulled into.
    $mroot = if ($env:OLLAMA_MODELS) { Join-Path $env:OLLAMA_MODELS 'manifests' } else { Join-Path $env:USERPROFILE '.ollama\models\manifests' }
    $parts = $name -split ':', 2
    $repo = $parts[0]; $tag = if ($parts.Count -gt 1) { $parts[1] } else { 'latest' }
    $candidates = @()
    if ($repo -like 'hf.co/*') {
        $candidates += Join-Path $mroot (Join-Path 'hf.co' (Join-Path ($repo -replace '^hf\.co/', '') $tag))
    } else {
        $candidates += Join-Path $mroot (Join-Path 'registry.ollama.ai' (Join-Path 'library' (Join-Path $repo $tag)))
    }
    foreach ($m in $candidates) {
        if (Test-Path $m) {
            $j = Get-Content $m -Raw | ConvertFrom-Json
            $layer = $j.layers | Where-Object { $_.mediaType -like '*image.model*' } | Select-Object -First 1
            if ($layer) {
                $blob = Join-Path (Join-Path $env:OLLAMA_MODELS 'blobs') ($layer.digest -replace ':', '-')
                if (Test-Path $blob) { return $blob }
            }
        }
    }
    return $null
}

if ($List -or -not $Model) {
    # The table is sized against the GPU's design budget, not whatever is free this second -
    # a game or LM Studio holding 5 GB changes the answer for every row at once.
    $freeGB = 0
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path $smi) {
        $m = & $smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
        if ($m -and "$m" -match '^\d+') { $freeGB = [double]$m / 1024 }
    }
    if ($freeGB -gt 0 -and $freeGB -lt 5.5) {
        Write-Host ""
        Write-Host ("  ! only {0:N1} GB of VRAM is free right now (design budget is ~7.0 GB)." -f $freeGB) -ForegroundColor Yellow
        if (Get-Process llama-server -ErrorAction SilentlyContinue) {
            Write-Host "    A model is already loaded - free it with: .\serve-model.ps1 -Stop" -ForegroundColor Yellow
        } else {
            Write-Host "    Close games / LM Studio / browser GPU tabs, or nothing big will fit." -ForegroundColor Yellow
        }
    }
    $rows = foreach ($f in Get-ChildItem $modelsDir -Filter '*.gguf' -File -ErrorAction SilentlyContinue) {
        $g = pwsh -NoProfile -File (Join-Path $bin 'llm-plan.ps1') -Model $f.FullName -Json -VramGB 7.0 2>$null | Where-Object { $_ -like '{*' } | ConvertFrom-Json
        # A vision projector is a companion file, not a model you can chat with on its own.
        if (-not $g -or $g.Arch -in 'clip', 'mmproj') { continue }
        [pscustomobject]@{
            Model  = $f.BaseName
            GB     = [math]::Round($f.Length / 1GB, 2)
            Arch   = $g.Arch
            MoE    = if ($g.IsMoE) { "$($g.ExpertUsed)/$($g.ExpertCount)" } else { 'dense' }
            PerTok = "$($g.BytesPerTokenGB) GB"
            Fit    = if ($g.FullVram) { 'full VRAM' } elseif ($g.Fits) { "split ncmoE=$($g.SuggestedNcmoe)" } else { 'will not fit' }
        }
    }
    $rows | Sort-Object GB | Format-Table -AutoSize
    Write-Host "  serve one with: .\serve-model.ps1 <Model>" -ForegroundColor DarkGray
    return
}

$regAlias = ''
$regPort = 0
$file = Resolve-ModelFile $Model
if (-not $file) {
    # Not a path or an Ollama tag - maybe it is a registry key from llm-up.ps1 (gemma4, flint, ...).
    $up = Join-Path $bin 'llm-up.ps1'
    if (Test-Path $up) {
        $txt = Get-Content $up -Raw
        $key = [regex]::Escape($Model)
        $pat = "(?m)^\s*" + $key + "\s*=\s*@\{[^}]*File\s*=\s*'([^']+)'"
        if ($txt -match $pat) {
            $file = Resolve-ModelFile $Matches[1]
            if ($txt -match ("(?m)^\s*" + $key + "\s*=\s*@\{[^}]*Alias\s*=\s*'([^']+)'")) { $regAlias = $Matches[1] }
            if ($txt -match ("(?m)^\s*" + $key + "\s*=\s*@\{[^}]*Port\s*=\s*(\d+)")) { $regPort = [int]$Matches[1] }
        }
    }
}
if (-not $file) {
    Write-Host "  '$Model' not found as a path, a file in $modelsDir, or an Ollama tag." -ForegroundColor Red
    Write-Host "  If it is an Ollama model, pull it first:  ollama pull $Model" -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------- geometry
$geo = pwsh -NoProfile -File (Join-Path $bin 'llm-plan.ps1') -Model $file -Json 2>$null |
    Where-Object { $_ -like '{*' } | ConvertFrom-Json
if (-not $geo) { throw "could not read GGUF header of $file" }

# A previous model's VRAM is still held while we measure, so stop first unless told not to.
if (-not $NoAutoStop) {
    $running = Get-Process llama-server -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "  stopping the model already on the GPU (only one fits)..." -ForegroundColor DarkGray
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 900
        $geo = pwsh -NoProfile -File (Join-Path $bin 'llm-plan.ps1') -Model $file -Json 2>$null |
            Where-Object { $_ -like '{*' } | ConvertFrom-Json
    }
}

if ($Threads -le 0) { $Threads = if ($geo.IsMoE -and $CpuMoe -ne 0) { 16 } else { 20 } }
if ($CpuMoe -lt 0) { $CpuMoe = if ($geo.IsMoE) { $geo.SuggestedNcmoe } else { 0 } }
if ($Threads -le 0) { $Threads = if ($CpuMoe -gt 0) { 16 } else { 20 } }
if (-not $Alias) { $Alias = if ($regAlias) { $regAlias } else { $geo.Name -replace '\.gguf$', '' } }
if ($Port -le 0) { $Port = if ($regPort) { $regPort } else { 8080 } }

$extraArgs = @()
if ($SpecType) {
    $extraArgs += @('--spec-type', $SpecType)
    if ($DraftModel) {
        $d = Resolve-ModelFile $DraftModel
        if ($d) { $extraArgs += @('--spec-draft-model', $d) }
        else { Write-Host "  ! draft model '$DraftModel' not found - ignoring" -ForegroundColor Yellow }
    }
}
if ($Extra.Count -gt 0) { $extraArgs += $Extra }

Write-Host ""
Write-Host "  $($geo.Name)" -ForegroundColor Cyan
Write-Host ("    {0} | {1} | {2} GB file | {3} GB/token" -f $geo.Arch,
    $(if ($geo.IsMoE) { "MoE $($geo.ExpertUsed)/$($geo.ExpertCount) experts, $($geo.ExpertLayers) layers" } else { 'dense' }),
    $geo.FileGB, $geo.BytesPerTokenGB) -ForegroundColor DarkGray
Write-Host ("    ngl={0} ncmoe={1} threads={2} ctx={3} kv={4}" -f $GpuLayers, $CpuMoe, $Threads, $Ctx, $CacheK) -ForegroundColor DarkGray
if (-not $geo.Fits) { Write-Host "    ! header says this will not fit - lower -Ctx or use a smaller quant" -ForegroundColor Yellow }
Write-Host ""

# ---------------------------------------------------------------- start
$specDraft = ''
if ($DraftModel) {
    $d = Resolve-ModelFile $DraftModel
    if ($d) { $specDraft = $d } else { Write-Host "  ! draft model '$DraftModel' not found - ignoring" -ForegroundColor Yellow }
}

$serverArgs = @{
    Model          = $file
    Backend        = $Backend
    Ctx            = $Ctx
    Port           = $Port
    Threads        = $Threads
    GpuLayers      = $GpuLayers
    CpuMoe         = $CpuMoe
    CacheK         = $CacheK
    CacheV         = $CacheV
    Alias          = $Alias
    SpecType       = $SpecType
    SpecDraftModel = $specDraft
}

# llm-server.ps1 runs in the foreground on purpose, so that `\\llm-server.ps1 -DryRun` shows the
# command line and a plain run streams the load log. Serving in the background means launching it
# as its own process.
$sw = [Diagnostics.Stopwatch]::StartNew()
if ($Foreground) {
    & (Join-Path $bin 'llm-server.ps1') @serverArgs
    return
}

$log = Join-Path $env:TEMP 'llama-serve.log'
Remove-Item $log, "$log.err" -ErrorAction SilentlyContinue
$argList = @(
    '-NoProfile', '-File', (Join-Path $bin 'llm-server.ps1'),
    '-Model', $file, '-Backend', $Backend, '-Ctx', "$Ctx", '-Port', "$Port",
    '-Threads', "$Threads", '-GpuLayers', "$GpuLayers", '-CpuMoe', "$CpuMoe",
    '-CacheK', $CacheK, '-CacheV', $CacheV, '-Alias', $Alias
)
if ($SpecType) { $argList += @('-SpecType', $SpecType) }
if ($specDraft) { $argList += @('-SpecDraftModel', $specDraft) }
if ($Extra.Count -gt 0) { $argList += @('-Extra', ($Extra -join ',') ) }

Start-Process pwsh -ArgumentList $argList -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" | Out-Null

$ok = $false
for ($i = 0; $i -lt 200; $i++) {
    Start-Sleep -Milliseconds 700
    try {
        if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2).status -eq 'ok') { $ok = $true; break }
    } catch { }
}
$sw.Stop()

if (-not $ok) {
    Write-Host "  ! server did not become healthy in 140 s" -ForegroundColor Red
    if (Test-Path $log) { Get-Content $log -Tail 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    if (Test-Path "$log.err") { Get-Content "$log.err" -Tail 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed } }
    return
}

# ---------------------------------------------------------------- how to connect
$up = "http://127.0.0.1:$Port/v1"
Write-Host ""
Write-Host "  ready in $([math]::Round($sw.Elapsed.TotalSeconds))s" -ForegroundColor Green
Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  OpenAI-compatible base URL : $up"
Write-Host "  model id (use this string) : $Alias"
Write-Host ""
Write-Host "  curl:" -ForegroundColor DarkGray
Write-Host "    curl.exe -s $up/chat/completions -H `"content-type: application/json`" -d `"{\`"model\`":\`"$Alias\`",\`"messages\`":[{\`"role\`":\`"user\`",\`"content\`":\`"hi\`"}]}`""
Write-Host ""
Write-Host "  Claude Code : .\connect-claude.ps1 -Port $Port -Model $Alias" -ForegroundColor Cyan
Write-Host "  dsh-tui     : .\connect-dsh.ps1 -Port $Port -Model $Alias   (then restart dsh-tui)" -ForegroundColor Cyan
Write-Host "  anything    : .\connect-any.ps1 -Port $Port -Model $Alias  (prints configs for common clients)" -ForegroundColor Cyan
Write-Host ""



