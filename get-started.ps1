<#
.SYNOPSIS
    From a fresh clone to a running model, in one command.

.DESCRIPTION
    Checks the machine, gets the llama.cpp engine, gets the models, builds the Desktop bundle and
    opens the launcher. Every step notices when it is already done, so running this twice is
    harmless and re-running it later is the normal way to pick up a changed preset.

    It downloads, in this order, only what is missing:
      engine  ~715 MB   the pinned llama.cpp build + its CUDA runtime, from ggml-org's releases
      models  ~75 GB    the six GGUFs, from Hugging Face, resumable

    Needs Windows 10/11, an NVIDIA GPU (8 GB+ for the big ones), PowerShell 7 for the nicest
    output, and the `hf` CLI for the models:  pip install -U "huggingface_hub[cli,hf_xet]"

.EXAMPLE
    .\get-started.ps1
    .\get-started.ps1 -SkipModels                 # engine + bundle only
    .\get-started.ps1 -Yes -NoLaunch              # unattended, do not open the window
#>
[CmdletBinding()]
param(
    [switch]$SkipEngine,
    [switch]$SkipModels,
    [switch]$NoLaunch,
    [switch]$Yes,
    [string]$EngineTag = 'b12255',
    [string]$Bundle = "$env:USERPROFILE\Desktop\llama.cpp"
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$bin = Join-Path $root 'bin'
$models = Join-Path $root 'models'
$cudaDir = Join-Path $root "llama.cpp\$EngineTag\cuda"

function Head([string]$n, [string]$of, [string]$what) {
    Write-Host ""
    Write-Host ("  [{0}/{1}] {2}" -f $n, $of, $what) -ForegroundColor Cyan
}
function Ok([string]$m) { Write-Host ("        {0}" -f $m) -ForegroundColor Green }
function Note([string]$m) { Write-Host ("        {0}" -f $m) -ForegroundColor DarkGray }
function Warn([string]$m) { Write-Host ("        {0}" -f $m) -ForegroundColor Yellow }
function Bad([string]$m) { Write-Host ("        {0}" -f $m) -ForegroundColor Red }
function Ask([string]$q) {
    if ($Yes) { return $true }
    $a = Read-Host "        $q [Y/n]"
    return ($a -eq '' -or $a -match '^[Yy]')
}
function Size([double]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    return ('{0:N0} MB' -f ($b / 1MB))
}

Write-Host ""
Write-Host "  local-llm-stack" -ForegroundColor White
Write-Host "  one model at a time, on a GPU with 8 GB" -ForegroundColor DarkGray

# ------------------------------------------------------------------ 1. the machine
Head 1 4 "this machine"
if ($PSVersionTable.PSVersion.Major -ge 7) { Ok ("PowerShell {0}" -f $PSVersionTable.PSVersion) }
else { Warn ("PowerShell {0} - the scripts work, but PowerShell 7 is what this was tested on" -f $PSVersionTable.PSVersion) }

$gpu = $null
try { $gpu = (& nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>$null) } catch { }
if ($gpu) { Ok ("GPU: " + $gpu.Trim()) }
else { Bad "no NVIDIA GPU answered nvidia-smi - the presets here are tuned for one" }

$missingBytes = 0
if (Test-Path (Join-Path $root 'models.manifest.json')) {
    foreach ($e in (Get-Content (Join-Path $root 'models.manifest.json') -Raw | ConvertFrom-Json).models) {
        $have = Join-Path $models $e.file
        if (-not (Test-Path $have)) { $missingBytes += [int64]$e.sizeBytes }
    }
}
$needEngine = -not (Test-Path (Join-Path $cudaDir 'llama-server.exe'))
$budget = $missingBytes + $(if ($needEngine) { 800MB } else { 0 })
try {
    $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($root))
    $free = $drive.AvailableFreeSpace
    if ($budget -gt 0) {
        if ($free -lt $budget) { Bad ("need {0}, this drive has {1} free" -f (Size $budget), (Size $free)) }
        else { Ok ("disk: {0} free, {1} to download" -f (Size $free), (Size $budget)) }
    }
    else { Ok ("disk: {0} free, nothing to download" -f (Size $free)) }
} catch { Warn "could not read free space on this drive" }

# ------------------------------------------------------------------ 2. the engine
Head 2 4 "the llama.cpp engine"
if (-not $needEngine) {
    Ok ("already here: " + $cudaDir)
}
elseif ($SkipEngine) {
    Warn "skipped (-SkipEngine)"
}
else {
    Note ("not present -> llama.cpp {0}, CUDA build, ~715 MB" -f $EngineTag)
    Note "the engine is not in this repository; it is downloaded from ggml-org's releases"
    if (Ask "download it now?") {
        $parts = @(
            "llama-$EngineTag-bin-win-cuda-12.4-x64.zip",
            "cudart-llama-bin-win-cuda-13.5-x64.zip"
        )
        $tmp = Join-Path $env:TEMP ("llama-engine-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            foreach ($name in $parts) {
                $url = "https://github.com/ggml-org/llama.cpp/releases/download/$EngineTag/$name"
                $zip = Join-Path $tmp $name
                Note $name
                $haveCurl = $null -ne (Get-Command curl.exe -ErrorAction SilentlyContinue)
                if ($haveCurl) { & curl.exe -L --fail --progress-bar -o $zip $url }
                else { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing }
                if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 1MB) { throw "download failed: $name" }
                Expand-Archive -Path $zip -DestinationPath $tmp -Force
                Remove-Item $zip -Force
            }
            New-Item -ItemType Directory -Force -Path $cudaDir | Out-Null
            # the zips carry a folder of their own; the bundle wants one flat directory
            Get-ChildItem $tmp -Recurse -File | ForEach-Object {
                Copy-Item $_.FullName (Join-Path $cudaDir $_.Name) -Force
            }
            if (Test-Path (Join-Path $cudaDir 'llama-server.exe')) {
                Ok ("installed {0} files into {1}" -f (Get-ChildItem $cudaDir -File).Count, $cudaDir)
            }
            else { Bad "extracted, but llama-server.exe is not there - check the tag $EngineTag" }
        }
        catch { Bad ("engine download failed: {0}" -f $_.Exception.Message) }
        finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    else { Warn "skipped - the bundle will have no engine to run" }
}

# ------------------------------------------------------------------ 3. the models
Head 3 4 "the models"
if ($SkipModels) { Warn "skipped (-SkipModels)" }
elseif ($missingBytes -eq 0) { Ok "all six are already in models\" }
else {
    $hf = Get-Command hf -ErrorAction SilentlyContinue
    if (-not $hf) {
        Bad "the hf CLI is not installed - nothing can be downloaded"
        Note 'pip install -U "huggingface_hub[cli,hf_xet]"'
        Note "then: .\bin\llm-fetch.ps1 -Missing"
    }
    else {
        Note ("{0} missing, {1} to fetch from Hugging Face (resumable)" -f
              (@((Get-Content (Join-Path $root 'models.manifest.json') -Raw | ConvertFrom-Json).models |
                 Where-Object { -not (Test-Path (Join-Path $models $_.file)) }).Count), (Size $missingBytes))
        $fetchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $bin 'llm-fetch.ps1'), '-Missing')
        if ($Yes) { $fetchArgs += '-HighPerformance' }
        $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
        & $psExe @fetchArgs
        if ($LASTEXITCODE -ne 0) { Warn "the fetcher reported a problem; re-run this script to resume" }
    }
}

# ------------------------------------------------------------------ 4. the bundle and the launcher
Head 4 4 "the bundle and the launcher"
$engine = $null
foreach ($cand in @($cudaDir,
                    (Join-Path $root "llama.cpp\$EngineTag\vulkan"),
                    (Join-Path $root "llama.cpp\$EngineTag\cpu"))) {
    if (Test-Path (Join-Path $cand 'llama-server.exe')) { $engine = $cand; break }
}
if (-not $engine) {
    Bad "no llama-server.exe found under llama.cpp\ - the bundle needs the engine"
    $engine = $cudaDir
}
else { Ok ("engine: " + $engine) }

try {
    & pwsh -NoProfile -File (Join-Path $bin 'llm-desktop.ps1') -Destination $Bundle `
        -Build $engine -SourceModels $models -SkipBinaries:$false | Out-Null
    if (Test-Path (Join-Path $Bundle 'llama-server.exe')) { Ok ("bundle: " + $Bundle) }
    else { Bad "the bundle was built but has no llama-server.exe" }
}
catch { Bad ("could not build the bundle: " + $_.Exception.Message) }

try {
    & pwsh -NoProfile -File (Join-Path $bin 'llm-direct.ps1') -Bundle $Bundle | Out-Null
    if (Test-Path (Join-Path $Bundle 'llama-direct.exe')) { Ok "launcher: llama-direct.exe (also copied to the Desktop)" }
    else { Bad "the launcher did not build" }
}
catch { Bad ("could not build the launcher: " + $_.Exception.Message) }

# ------------------------------------------------------------------ done
Write-Host ""
if ($NoLaunch) {
    Note ("start it yourself: " + (Join-Path $Bundle 'llama-direct.exe'))
    exit 0
}
$exe = Join-Path $Bundle 'llama-direct.exe'
if (Test-Path $exe) {
    Write-Host "  opening the launcher - pick a model, the chat page opens by itself." -ForegroundColor Green
    Start-Process -FilePath $exe
}
else {
    Write-Host "  nothing to launch yet; fix the errors above and run this again." -ForegroundColor Yellow
}
Write-Host ""
