<#
.SYNOPSIS
    Find the fastest offload configuration for one GGUF on this machine, by measuring.

.DESCRIPTION
    Two things decide generation speed here: how much of the model sits in the 5060's
    8 GB (448 GB/s) and how much streams from DDR5 (~60 GB/s).

      * DENSE model  -> all of it in VRAM or don't bother, so sweep -ngl.
      * MoE model    -> only a few billion params fire per token, so expert tensors can
                        live in RAM at little cost. --n-cpu-moe N keeps N layers' experts
                        on the CPU; the right N depends on free VRAM, so measure it.

    Uses llama-bench with CSV output (no server, no HTTP) and prints a ready-to-paste
    llm-server.ps1 command.

.EXAMPLE
    .\llm-tune.ps1 -Model .\models\gpt-oss-20b.gguf -Mode moe
    .\llm-tune.ps1 -Model .\models\Qwen3-8B-Q4_K_M.gguf -Mode dense
    .\llm-tune.ps1 -Model .\models\gpt-oss-20b.gguf -Mode moe -Values 0,8,16,24,32 -Ctx 16384
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Model,
    [ValidateSet('dense', 'moe')][string]$Mode = 'moe',
    # -Ctx is the context the KV cache has to cover; it becomes llama-bench's test depth,
    # so VRAM pressure is realistic. 0 = shallow test, fastest, best for pure speed ranking.
    [int]$Ctx = 8192,
    [int]$PP = 256,
    [int]$TG = 64,
    # Comma-separated list, as a string: -File invocation mangles -Values 0,99 into a single
    # element, so parse it by hand instead of relying on [int[]] binding.
    [string]$Values,
    [string]$Backend = 'cuda'
)

$ErrorActionPreference = 'Stop'
$llmRoot = 'C:\Users\fih\llm'
$buildsRoot = Join-Path $llmRoot 'llama.cpp'
$tag = Get-ChildItem $buildsRoot -Directory | Sort-Object { [int]($_.Name -replace '\D', '') } -Descending |
    Select-Object -First 1 -ExpandProperty Name

$nvHere = [bool](Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VEN_10DE' })

if (-not $nvHere) {
    Write-Host ""
    Write-Host "  ! The RTX 5060 is still not on the PCI bus (Code 45)." -ForegroundColor Yellow
    Write-Host "    Sweeping now measures only the CPU, which is a different question." -ForegroundColor Yellow
    Write-Host "    Fix the MSI Center GPU Switch -> reboot -> run .\llm-gpu.ps1 to confirm." -ForegroundColor Yellow
    Write-Host "    Continuing with the CPU backend." -ForegroundColor DarkYellow
    $Backend = 'cpu'
}

if (-not (Test-Path $Model)) {
    $c = Join-Path (Join-Path $llmRoot 'models') $Model
    if (Test-Path $c) { $Model = $c } else { throw "Model not found: $Model" }
}
$Model = (Resolve-Path $Model).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Model)
$sizeGB = (Get-Item $Model).Length / 1GB

$binDir = Join-Path $buildsRoot "$tag\$Backend"
$bench = Join-Path $binDir 'llama-bench.exe'
if (-not (Test-Path $bench)) { throw "llama-bench for backend '$Backend' not found: $bench" }

# A [string] param would coerce this array straight back into one string, so keep it local.
if ($Values) {
    $vals = @($Values -split '[,;\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
} else {
    $vals = if ($Mode -eq 'dense') { @(0, 8, 16, 24, 32, 99) } else { @(0, 8, 12, 16, 20, 24, 32) }
}

if ($Backend -eq 'cuda') { $env:CUDA_VISIBLE_DEVICES = '0' }
$env:GGML_VK_VISIBLE_DEVICES = '0'

Write-Host ""
Write-Host "  model   : $name  ($([math]::Round($sizeGB, 2)) GB)" -ForegroundColor Cyan
Write-Host "  mode    : $Mode   backend: $Backend   ctx/depth: $Ctx" -ForegroundColor Cyan
Write-Host ""

$rows = [System.Collections.Generic.List[object]]::new()

function Measure-One([int]$v) {
    $label = if ($Mode -eq 'moe') { "ncmoe=$v" } else { "ngl=$v" }
    $a = @('-m', $Model, '-p', "$PP", '-n', "$TG", '-r', '1', '-t', '20', '-fa', 'on', '-o', 'csv')
    if ($Ctx -gt 0) { $a += @('-d', "$Ctx") }
    if ($Mode -eq 'moe') {
        if ($v -gt 0) { $a += @('--n-cpu-moe', "$v") }
        $a += @('-ngl', '99')
    } else {
        $a += @('-ngl', "$v")
    }

    Push-Location $binDir
    try { $raw = & $bench @a 2>&1 | Out-String } finally { Pop-Location }

    # llama-bench writes backend chatter plus a CSV block; keep the header + quoted rows.
    $lines = $raw -split "`r?`n"
    $hdr = $lines | Where-Object { $_ -like 'build_commit,*' } | Select-Object -First 1
    $csv = @()
    if ($hdr) {
        $csv = @($hdr) + @($lines | Where-Object { $_ -match '^"' })
    }

    $pp = $null; $tg = $null; $ngl = $null; $moe = $null
    if ($csv.Count -gt 1) {
        try {
            $recs = $csv | ConvertFrom-Csv
            $rPP = $recs | Where-Object { [int]$_.n_gen -eq 0 -and [int]$_.n_prompt -gt 0 } | Select-Object -First 1
            $rTG = $recs | Where-Object { [int]$_.n_gen -gt 0 } | Select-Object -First 1
            if ($rPP) { $pp = [double]$rPP.avg_ts }
            if ($rTG) { $tg = [double]$rTG.avg_ts }
            $first = $recs | Select-Object -First 1
            $ngl = $first.n_gpu_layers
            $moe = $first.n_cpu_moe
        } catch { }
    }

    $rows.Add([pscustomobject]@{
            Setting  = $label
            Ngl      = $ngl
            Ncmoe    = $moe
            Prompt   = if ($pp) { [math]::Round($pp, 1) } else { $null }
            Generate = if ($tg) { [math]::Round($tg, 1) } else { $null }
        })
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $ppS = if ($pp) { [math]::Round($pp, 1).ToString($inv) } else { '-' }
    $tgS = if ($tg) { [math]::Round($tg, 1).ToString($inv) } else { '-' }
    Write-Host ("    {0,-12} pp {1,8} t/s    tg {2,6} t/s" -f $label, $ppS, $tgS) -ForegroundColor Gray
}

foreach ($v in $vals) { Measure-One $v }

Write-Host ""
$rows | Select-Object Setting, Prompt, Generate | Format-Table -AutoSize | Out-String | Write-Host

$best = $rows | Where-Object { $_.Generate } | Sort-Object Generate -Descending | Select-Object -First 1
if (-not $best) {
    Write-Host "  no results parsed - run llama-bench by hand to see what happened" -ForegroundColor Red
    return
}

Write-Host ("  fastest: {0}  ->  {1} t/s generation" -f $best.Setting, $best.Generate) -ForegroundColor Green
Write-Host ""

$flag = if ($Mode -eq 'moe' -and $best.Setting -match '=(\d+)' -and $Matches[1] -ne '0') { "-CpuMoe $($Matches[1])" }
elseif ($Mode -eq 'dense') { "-GpuLayers $($best.Setting -replace 'ngl=', '')" }
else { "" }

Write-Host ("  llm-server.ps1 -Model `"$Model`" -Backend $Backend -Ctx $Ctx $flag").Trim() -ForegroundColor Cyan
Write-Host ""
Write-Host "  reading the result:" -ForegroundColor DarkGray
Write-Host "   - all rows within ~10 % of each other  -> nothing is spilling; use full offload" -ForegroundColor DarkGray
Write-Host "   - winner is the LARGEST ncmoe         -> VRAM-starved; drop -Ctx or use a smaller quant" -ForegroundColor DarkGray
Write-Host "   - tg collapses at ncmoe=0             -> model does not fit 8 GB; the split is mandatory" -ForegroundColor DarkGray
