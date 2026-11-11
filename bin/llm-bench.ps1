<#
.SYNOPSIS
    Benchmark a GGUF across the installed llama.cpp backends and save a CSV.

.DESCRIPTION
    Runs pp (prompt processing) and tg (token generation) on:
      cpu      - AVX2 / AVX-VNNI build
      cuda     - NVIDIA RTX 5060 (only when it is enumerated and the cuda build exists)
      vulkan   - Vulkan build: RTX 5060 when present, Intel iGPU otherwise
      openvino - Intel iGPU through the OpenVINO GPU plugin

    Also sweeps thread counts for the CPU backend, because this chip is hybrid
    (8 P-cores + 12 E-cores).

.EXAMPLE
    .\llm-bench.ps1 -Model C:\Users\fih\llm\models\Qwen3-8B-Q4_K_M.gguf
    .\llm-bench.ps1 -Model .\models\model.gguf -NoThreadSweep
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Model,
    [int]$PP = 256,
    [int]$TG = 128,
    [int]$Reps = 3,
    [switch]$NoThreadSweep,
    [int[]]$Threads = @(12, 14, 16, 18, 20)
)

$ErrorActionPreference = 'Stop'
$llmRoot = 'C:\Users\fih\llm'
$buildsRoot = Join-Path $llmRoot 'llama.cpp'
$tag = Get-ChildItem $buildsRoot -Directory | Sort-Object { [int]($_.Name -replace '\D', '') } -Descending |
    Select-Object -First 1 -ExpandProperty Name

if (-not (Test-Path $Model)) {
    $c = Join-Path (Join-Path $llmRoot 'models') $Model
    if (Test-Path $c) { $Model = $c } else { throw "Model not found: $Model" }
}
$Model = (Resolve-Path $Model).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Model)

$benchDir = Join-Path $llmRoot 'bench'
New-Item -ItemType Directory -Force -Path $benchDir | Out-Null
$csv = Join-Path $benchDir ("bench-{0}-{1:yyyyMMdd-HHmm}.csv" -f $name, (Get-Date))
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-Bench([string]$backend, [int]$t, [string]$extraArgs = '') {
    $dir = Join-Path $buildsRoot "$tag\$backend"
    if (-not (Test-Path $dir)) { Write-Host "  skip $backend (not installed)" -ForegroundColor DarkGray; return }
    $exe = Join-Path $dir 'llama-bench.exe'

    if ($backend -eq 'openvino') {
        $env:GGML_OPENVINO_DEVICE = 'GPU'
        Remove-Item Env:CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue
    } elseif ($backend -eq 'cuda') {
        $env:CUDA_VISIBLE_DEVICES = '0'
        Remove-Item Env:GGML_OPENVINO_DEVICE -ErrorAction SilentlyContinue
    } else {
        Remove-Item Env:GGML_OPENVINO_DEVICE -ErrorAction SilentlyContinue
        Remove-Item Env:CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue
    }
    $env:GGML_VK_VISIBLE_DEVICES = '0'

    $a = @('-m', $Model, '-p', "$PP", '-n', "$TG", '-r', "$Reps", '-t', "$t")
    if ($backend -ne 'cpu') { $a += @('-ngl', '99') }
    if ($extraArgs) { $a += $extraArgs.Split(' ') }

    Push-Location $dir
    try { $raw = & $exe @a 2>&1 | Out-String } finally { Pop-Location }

    foreach ($test in 'pp', 'tg') {
        $line = ($raw -split "`n" | Where-Object { $_ -like "*$test$PP*" -or $_ -like "*$test$TG*" } | Select-Object -First 1)
        if ($line -and $line -match '([\d.]+)\s*±\s*([\d.]+)') {
            $results.Add([pscustomobject]@{
                    Model   = $name
                    Backend = $backend
                    Threads = $t
                    Test    = if ($test -eq 'pp') { "pp$PP" } else { "tg$TG" }
                    Tps     = [double]$Matches[1]
                    Stdev   = [double]$Matches[2]
                })
        }
    }
}

Write-Host "`nModel: $name`n" -ForegroundColor Cyan

$nvHere = [bool](Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VEN_10DE' })
if (-not $nvHere) {
    Write-Host "  note: the RTX 5060 is not enumerated - cuda will be skipped and 'vulkan'" -ForegroundColor DarkYellow
    Write-Host "        below means the Intel iGPU. Run .\llm-gpu.ps1 to fix that." -ForegroundColor DarkYellow
    Write-Host ""
}

Write-Host "== cpu (16 threads) ==" -ForegroundColor Yellow
Invoke-Bench 'cpu' 16

Write-Host "== cuda / RTX ==" -ForegroundColor Yellow
Invoke-Bench 'cuda' 16

Write-Host "== vulkan ==" -ForegroundColor Yellow
Invoke-Bench 'vulkan' 16

Write-Host "== openvino / iGPU ==" -ForegroundColor Yellow
Invoke-Bench 'openvino' 16

if (-not $NoThreadSweep) {
    Write-Host "== cpu thread sweep ==" -ForegroundColor Yellow
    foreach ($t in $Threads) { Invoke-Bench 'cpu' $t }
}

$results | Group-Object Backend, Test | ForEach-Object {
    $best = $_.Group | Sort-Object Tps -Descending | Select-Object -First 1
    [pscustomobject]@{
        Backend = $best.Backend
        Test    = $best.Test
        'Best t/s' = [math]::Round($best.Tps, 2)
        Threads = $best.Threads
    }
} | Sort-Object Test, Backend | Format-Table -AutoSize

$results | Export-Csv -Path $csv -NoTypeInformation -Encoding utf8
Write-Host "raw results -> $csv" -ForegroundColor DarkGray
