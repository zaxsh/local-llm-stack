<#
.SYNOPSIS
    Download the models this stack uses, straight from Hugging Face, with xet acceleration.

.DESCRIPTION
    Reads models.manifest.json and pulls each GGUF into models\ under the exact filename the
    registry, the presets and llama-direct.exe expect. Downloads land in a staging folder first and
    are moved into place, so an interrupted transfer never leaves a half file where a model should
    be - re-running resumes from the partial download instead of starting over.

    Speed comes from HF's xet backend (hf_xet). Without it the same files download fine, just
    slower; the script says which one you have.

    Auth: public repos need no token, but HF rate-limits anonymous traffic and gated repos refuse it.
    Pass -Token once, or run `hf auth login`. Tokens are handed to hf through the HF_TOKEN
    environment variable, never on a command line, and are never written to a log.

.EXAMPLE
    .\llm-fetch.ps1 -Missing            # fetch whatever is not on disk yet
    .\llm-fetch.ps1 -Key gemma4         # one model
    .\llm-fetch.ps1 -All -DryRun        # show the hf commands, download nothing
    .\llm-fetch.ps1 -List               # what is present / missing, and where it comes from
#>
[CmdletBinding()]
param(
    # registry keys: gemma4, flint, qwen36, gptoss, qwen3, coder
    [string]$Key,
    [switch]$All,
    [switch]$Missing,
    [switch]$List,
    [string]$Token,
    [string]$ManifestPath,
    [string]$ModelsDir,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Json,
    # ask xet for more parallel ranges; helps on a slow line, costs some CPU
    [switch]$HighPerformance
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ where things are
function Find-Manifest {
    $cands = @(
        $ManifestPath,
        (Join-Path $PSScriptRoot 'models.manifest.json'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'models.manifest.json'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'models.manifest.json')
    ) | Where-Object { $_ }
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path } }
    throw "models.manifest.json not found (looked next to this script and in llm\)"
}

function Find-ModelsDir {
    if ($ModelsDir) { return $ModelsDir }
    # a bundle folder that has the engine next to it wins, so the launcher and the files agree
    $near = Join-Path (Split-Path $PSScriptRoot -Parent) 'models'
    if (Test-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'llama-server.exe')) { return $near }
    if (Test-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'models')) { return (Join-Path (Split-Path $PSScriptRoot -Parent) 'models') }
    return $near
}

# NB: '$manifest' is the parameter name in older revisions and PowerShell variables are case-insensitive:
# assigning an object to a [string]-typed variable silently re-joins it into a string. The parsed JSON lives in $catalog.
$manifestPath = Find-Manifest
$catalog = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$modelsDir = Find-ModelsDir
New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

function Get-Hf {
    $c = Get-Command hf -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Test-Xet {
    # hf_xet is what makes downloads multi-connection; it ships alongside huggingface_hub
    try {
        & python -c "import hf_xet" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N0} MB' -f ($bytes / 1MB)) }
    return ('{0:N0} KB' -f ($bytes / 1KB))
}

# ------------------------------------------------------------------ selection
$selected = @()
foreach ($m in $catalog.models) {
    $have = Join-Path $modelsDir $m.file
    $bytes = 0
    if (Test-Path -LiteralPath $have) { $bytes = (Get-Item -LiteralPath $have).Length }
    $m | Add-Member -NotePropertyName PresentBytes -NotePropertyValue $bytes -Force
    $m | Add-Member -NotePropertyName Present -NotePropertyValue ([bool]($bytes -gt 0)) -Force
    $m | Add-Member -NotePropertyName Path -NotePropertyValue $have -Force
}

if ($Key) {
    $selected = @($catalog.models | Where-Object { $_.key -eq $Key })
    if (-not $selected) { throw "no model with key '$Key' in the manifest" }
}
elseif ($All) { $selected = @($catalog.models) }
elseif ($Missing) { $selected = @($catalog.models | Where-Object { -not $_.Present }) }
else { $selected = @($catalog.models) }

if ($Json) {
    $catalog.models | ForEach-Object {
        [pscustomobject]@{ key = $_.key; file = $_.file; present = $_.Present
            bytes = $_.PresentBytes; repo = $_.repo; repoFile = $_.repoFile
            verified = $_.verified; note = $_.note }
    } | ConvertTo-Json -Depth 5
    return
}

# ------------------------------------------------------------------ report
if ($List -or $Missing -or $All -or $Key) {
    Write-Host ""
    Write-Host ("  models: {0}" -f $modelsDir) -ForegroundColor DarkGray
    Write-Host ("  manifest: {0}" -f $manifestPath) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host ("  {0,-8} {1,-34} {2,10}  {3}" -f 'key', 'file', 'size', 'state') -ForegroundColor DarkGray
    Write-Host ("  " + ('-' * 96)) -ForegroundColor DarkGray
    foreach ($m in $catalog.models) {
        $state = if (-not $m.Present) { 'missing' }
                 elseif ($m.PresentBytes -eq $m.sizeBytes) { 'ok' }
                 elseif ([math]::Abs($m.PresentBytes - $m.sizeBytes) -lt 1MB) { 'ok' }
                 else { "present ($(Format-Size $m.PresentBytes))" }
        $colour = if ($state -eq 'missing') { 'Yellow' } elseif ($state -eq 'ok') { 'Green' } else { 'Gray' }
        Write-Host ("  {0,-8} {1,-34} {2,10}  {3}" -f $m.key, $m.file, (Format-Size $m.sizeBytes), $state) -ForegroundColor $colour
    }
    Write-Host ""
    if ($List -and -not ($All -or $Missing -or $Key)) { return }
}

$hf = Get-Hf
if (-not $hf) {
    Write-Host "  hf CLI not found." -ForegroundColor Red
    Write-Host "  install: curl -LsSf https://hf.co/cli/install.sh | bash -s   (or: uv tool install huggingface_hub)" -ForegroundColor Yellow
    exit 3
}

if ($Token) { $env:HF_TOKEN = $Token }
if ($HighPerformance) { $env:HF_XET_HIGH_PERFORMANCE = '1' }

# ------------------------------------------------------------------ download
$todo = @($selected | Where-Object { $Force -or -not $_.Present })
if ($todo.Count -eq 0) {
    Write-Host "  nothing to download - every selected model is already on disk." -ForegroundColor Green
    return
}

if (-not (Test-Xet)) {
    Write-Host "  note: hf_xet is not installed, downloads will use a single connection." -ForegroundColor Yellow
    Write-Host "        fix: python -m pip install -U hf_xet" -ForegroundColor DarkGray
}

$results = @()
foreach ($m in $todo) {
    $stage = Join-Path $env:TEMP ("hf-stage-" + $m.key)
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $stageFile = Join-Path $stage ($m.repoFile -replace '/', '\')

    $hfArgs = @('download', $m.repo, $m.repoFile, '--type', 'model', '--local-dir', $stage)
    if ($DryRun) { $hfArgs += '--dry-run' }

    Write-Host ""
    Write-Host ("  == {0}  ({1})" -f $m.key, $m.quant) -ForegroundColor Cyan
    Write-Host ("     {0} :: {1}" -f $m.repo, $m.repoFile) -ForegroundColor DarkGray
    Write-Host ("     -> {0}" -f $m.Path) -ForegroundColor DarkGray

    if ($DryRun) { Write-Host ("     hf " + ($hfArgs -join ' ')) -ForegroundColor DarkGray }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $hf @hfArgs
    $code = $LASTEXITCODE
    $sw.Stop()

    if ($DryRun) {
        # hf --dry-run resolves the repo and the file without transferring anything
        $st = if ($code -eq 0) { 'dry-run ok' } else { "dry-run failed ($code)" }
        $results += [pscustomobject]@{ key = $m.key; status = $st; bytes = 0; seconds = 0 }
        continue
    }

    if ($code -ne 0) {
        Write-Host ("     failed (hf exit {0}); the partial download stays staged and resumes next run" -f $code) -ForegroundColor Red
        $results += [pscustomobject]@{ key = $m.key; status = "failed ($code)"; bytes = 0; seconds = [int]$sw.Elapsed.TotalSeconds }
        continue
    }

    if (-not (Test-Path -LiteralPath $stageFile)) {
        $found = Get-ChildItem -LiteralPath $stage -Recurse -Filter (Split-Path $m.repoFile -Leaf) -File -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { $stageFile = $found.FullName }
    }
    if (-not (Test-Path -LiteralPath $stageFile)) {
        Write-Host "     hf reported success but the file is not in the staging folder" -ForegroundColor Red
        $results += [pscustomobject]@{ key = $m.key; status = 'missing after download'; bytes = 0; seconds = [int]$sw.Elapsed.TotalSeconds }
        continue
    }

    $size = (Get-Item -LiteralPath $stageFile).Length
    # move into place under the filename the registry expects
    if (Test-Path -LiteralPath $m.Path) { Remove-Item -LiteralPath $m.Path -Force }
    Move-Item -LiteralPath $stageFile -Destination $m.Path -Force
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

    $secs = [int]$sw.Elapsed.TotalSeconds
    $rate = if ($secs -gt 0) { [math]::Round(($size / 1MB) / $secs, 1) } else { 0 }
    Write-Host ("     done: {0} in {1}s  ({2} MB/s)  ->  {3}" -f (Format-Size $size), $secs, $rate, (Split-Path $m.Path -Leaf)) -ForegroundColor Green
    $results += [pscustomobject]@{ key = $m.key; status = 'downloaded'; bytes = $size; seconds = $secs }
}

if (-not $DryRun) {
    Write-Host ""
    Write-Host ("  {0,-8} {1,-12} {2,10} {3,8}" -f 'key', 'status', 'size', 'seconds') -ForegroundColor DarkGray
    foreach ($r in $results) {
        $c = if ($r.status -eq 'downloaded') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-8} {1,-12} {2,10} {3,8}" -f $r.key, $r.status, (Format-Size $r.bytes), $r.seconds) -ForegroundColor $c
    }
    Write-Host ""
    Write-Host "  next: .\llm-up.ps1 -List   (or refresh the Desktop bundle with .\llm-desktop.ps1 -SkipBinaries)" -ForegroundColor DarkGray
}
