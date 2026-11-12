<#
.SYNOPSIS
    Start a llama.cpp server (OpenAI-compatible API) tuned for this laptop:
    Intel Core Ultra 7 255HX + RTX 5060 Laptop (8 GB) + Intel Xe iGPU.

.DESCRIPTION
    Four backends are installed side by side under llm\llama.cpp\<tag>\:

      cuda      - NVIDIA RTX 5060. ~448 GB/s of GDDR7. THE fast path, once the GPU is
                  switched back on (see llm-gpu.ps1). ~45-60 t/s on a 7B Q4_K_M.
      vulkan    - works on BOTH the RTX and the Intel iGPU. On the RTX it is ~10-15 %
                  slower than cuda; on the iGPU it is slower than the CPU for generation.
      openvino  - Intel iGPU only, fastest prompt processing (~171 t/s on 7B).
      cpu       - AVX-VNNI CPU build, ~13 t/s generation on a 7B Q4_K_M.

    Backend 'auto' (the default) picks cuda if the RTX is enumerated and a cuda build
    exists, else vulkan if the RTX is enumerated, else cpu. That means this script
    keeps doing the right thing before and after the dGPU comes back.

    Rule of thumb:
      * chat / coding / long generation      -> auto (=> cuda once the GPU is on)
      * huge prompt, RAG ingest, big PDF     -> openvino (iGPU) or cuda (RTX)
      * model bigger than ~7 GB              -> auto + -CpuMoe <n>  (MoE hybrid split)

.EXAMPLE
    .\llm-server.ps1 -Model .\models\Qwen3-8B-Q4_K_M.gguf
    .\llm-server.ps1 -Model .\models\Qwen3-30B-A3B-Q4_K_M.gguf -CpuMoe 40 -Ctx 32768
    .\llm-server.ps1 -Model .\models\Qwen3-8B-Q4_K_M.gguf -Backend cuda -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Model,

    [ValidateSet('auto', 'cuda', 'vulkan', 'openvino', 'cpu')]
    [string]$Backend = 'auto',

    [int]$Ctx = 16384,
    [int]$Port = 8080,

    # CPU threads used for prompt processing on a CPU/hybrid backend. Measured on this
    # chip: 20 threads (all) = 71 t/s prompt + 11.3 t/s generation. With a GPU backend
    # this only affects the layers that stayed on the CPU, so it stays at 20.
    [int]$Threads = 20,

    # Layers to offload. 99 = "all of them". Lower it only to leave room for a big
    # KV cache or a model that does not quite fit.
    [int]$GpuLayers = 99,

    # MoE models only (gpt-oss-20b, Qwen3-30B-A3B, ...): keep N expert layers in RAM and
    # the rest on the GPU. This is the one hybrid split that is actually worth it,
    # because only a few experts fire per token.
    [int]$CpuMoe = 0,

    # MEASURED: f16 KV is 25-35 % faster than q8_0 on a GPU-resident model (62.3 vs 44.7 t/s
    # on a 7B), because quantised KV needs a dequant pass over every head on every layer, every
    # token. Only drop to q8_0/q4_0 when f16 does not fit - the fit warning below tells you.
    [string]$CacheK = 'f16',
    [string]$CacheV = 'f16',

    # auto | none | mmap | mlock | mmap+mlock  (older builds called this --mmap/--no-mmap)
    [string]$LoadMode = 'auto',

    # Vulkan only: which adapter to use (0 is usually the discrete GPU when it is on).
    [int]$VkDevice = -1,

    # Model id advertised to clients (--alias). Pin this so dsh / Claude Code routes stay
    # valid when the underlying file is renamed or re-downloaded.
    [string]$Alias,

    [switch]$NoFlashAttn,
    [switch]$DryRun,

    # MCP tool servers to expose. 'rea' means mcp\rea-mcp.json (written by bin\llm-mcp.ps1), or
    # pass any other JSON file. -NoMcp wins when both are given.
    [string]$Mcp = '',
    [switch]$NoMcp,

    # Speculative decoding: none | draft-mtp | draft-simple | draft-eagle3 | ngram-cache | ...
    # draft-mtp uses the model's own MTP head, so it costs no extra VRAM. ngram-* need no draft.
    [string]$SpecType = '',
    [string]$SpecDraftModel = '',

    [string[]]$Extra = @()
)

$ErrorActionPreference = 'Stop'
$llmRoot = Split-Path $PSScriptRoot -Parent

# --- locate the newest llama.cpp build -------------------------------------
$buildsRoot = Join-Path $llmRoot 'llama.cpp'
if (-not (Test-Path $buildsRoot)) { throw "llama.cpp root not found: $buildsRoot" }

$tag = $env:LLM_LLAMA_TAG
if (-not $tag) {
    $tag = Get-ChildItem $buildsRoot -Directory |
        Sort-Object { [int]($_.Name -replace '\D', '') } -Descending |
        Select-Object -First 1 -ExpandProperty Name
}

# --- is the discrete GPU actually there? ----------------------------------
$nvHere = [bool](Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VEN_10DE' })

if ($Backend -eq 'auto') {
    $Backend = if ($nvHere -and (Test-Path (Join-Path $buildsRoot "$tag\cuda\llama-server.exe"))) { 'cuda' }
    elseif ($nvHere -and (Test-Path (Join-Path $buildsRoot "$tag\vulkan\llama-server.exe"))) { 'vulkan' }
    else { 'cpu' }
    Write-Host "  backend 'auto' -> $Backend  (discrete GPU present: $nvHere)" -ForegroundColor DarkGray
}

$binDir = Join-Path $buildsRoot "$tag\$Backend"
$server = Join-Path $binDir 'llama-server.exe'
if (-not (Test-Path $server)) {
    throw "Backend '$Backend' not found at $binDir. Installed: $((Get-ChildItem "$buildsRoot\$tag" -Directory).Name -join ', '). See llm-gpu.ps1 for the cuda build."
}

# --- resolve model path ----------------------------------------------------
# Accepts: a full path, a name inside llm\models, or an Ollama model name/prefix
# ("flint", "qwen2.5-coder:7b", "hf.co/RecursiveSI/flint-nvfp4-gguf:NVFP4").
# For Ollama names it reads the manifest and points at the sha256 blob, so the same
# 21 GB file is shared - no second copy on disk, and no duplicate page cache.
function Resolve-LlmModel([string]$Name) {
    if (Test-Path $Name) { return (Resolve-Path $Name).Path }
    $cand = Join-Path (Join-Path $llmRoot 'models') $Name
    if (Test-Path $cand) { return (Resolve-Path $cand).Path }

    $roots = @()
    if ($env:OLLAMA_MODELS) { $roots += $env:OLLAMA_MODELS }
    $roots += (Join-Path $env:USERPROFILE '.ollama\models')
    $roots += "$env:USERPROFILE\.cache\huggingface\hub"

    $n = $Name; $tag = 'latest'
    if ($n -match '^(.*):([^:]+)$') { $n = $Matches[1]; $tag = $Matches[2] }

    foreach ($r in $roots) {
        $man = Join-Path $r 'manifests'
        if (-not (Test-Path $man)) { continue }
        $mf = Join-Path $man ($n -replace '/', '\')
        $mf = Join-Path $mf $tag
        if (-not (Test-Path $mf)) {
            # prefix/substring match, so "-Model flint" works
            $mf = Get-ChildItem $man -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match [regex]::Escape($n) } |
                Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $mf) { continue }
        try {
            $j = Get-Content $mf -Raw | ConvertFrom-Json
            $layer = $j.layers | Where-Object { $_.mediaType -eq 'application/vnd.ollama.image.model' } | Select-Object -First 1
            if ($layer) {
                $hex = ($layer.digest -split ':')[1]
                $blob = Join-Path $r "blobs\sha256-$hex"
                if (Test-Path $blob) { return $blob }
            }
        } catch { }
    }
    throw "Model not found as a file, and not resolvable as an Ollama model: $Name"
}
$Model = Resolve-LlmModel $Model

# --- backend specific environment -----------------------------------------
if ($Backend -eq 'openvino') {
    $env:GGML_OPENVINO_DEVICE = 'GPU'
    Remove-Item Env:GGML_CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue
} elseif ($Backend -eq 'cuda') {
    $env:CUDA_VISIBLE_DEVICES = '0'
    Remove-Item Env:GGML_OPENVINO_DEVICE -ErrorAction SilentlyContinue
} elseif ($Backend -eq 'vulkan') {
    if ($VkDevice -ge 0) { $env:GGML_VK_VISIBLE_DEVICES = "$VkDevice" }
    Remove-Item Env:GGML_OPENVINO_DEVICE -ErrorAction SilentlyContinue
} else {
    Remove-Item Env:GGML_OPENVINO_DEVICE -ErrorAction SilentlyContinue
}

# --- build the command line -------------------------------------------------
$llamaArgs = @(
    '-m', $Model,
    '-c', "$Ctx",
    '--host', '127.0.0.1',
    '--port', "$Port",
    '--jinja',
    '--metrics',
    '--no-warmup',
    '-t', "$Threads",
    '-tb', "$Threads"
)

if ($Backend -in 'cuda', 'vulkan') {
    $llamaArgs += @('-ngl', "$GpuLayers")
}

if (-not $NoFlashAttn) { $llamaArgs += @('-fa', 'on') }

# --- MCP tool servers -------------------------------------------------------
# llama-server spawns each declared server as a child process over stdio and exposes its tools as
# <server>_<tool> on GET /tools and in the Web UI. REA is the one we ship, so the analysis tools
# are there without any extra daemon. The flag is probed first: a build without it ignores unknown
# options, and then the catalog silently looks like "the tools disappeared".
if ($Mcp -and -not $NoMcp) {
    $mcpPath = $Mcp
    if (-not (Test-Path $mcpPath)) {
        $cand = Join-Path (Join-Path $llmRoot 'mcp') "$Mcp-mcp.json"
        if (Test-Path $cand) { $mcpPath = $cand }
    }
    if (-not (Test-Path $mcpPath)) {
        throw "MCP config not found: $Mcp - run bin\llm-mcp.ps1 to write mcp\rea-mcp.json"
    }
    $knowsMcp = (& $server --help 2>&1 | Select-String -SimpleMatch 'mcp-servers-config') -ne $null
    if ($knowsMcp) { $llamaArgs += @('--mcp-servers-config', (Resolve-Path $mcpPath).Path) }
    else { Write-Host "  ! this llama.cpp build has no --mcp-servers-config - no MCP tools" -ForegroundColor Yellow }
}

# The OpenVINO backend compiles a graph PER SLOT at load time (~20 s each), and it rejects
# non-default loading modes with "[GPU] shared USM buffer has smaller size (0)".
if ($Backend -eq 'openvino') {
    $llamaArgs += @('-np', '1')
} elseif ($LoadMode -and $LoadMode -ne 'auto') {
    $llamaArgs += @('-lm', $LoadMode)
}

# The OpenVINO backend rejects quantized KV caches at the moment
# ("cannot run the operation (PERMUTE)"), so only apply cache types to the others.
if ($Backend -ne 'openvino') {
    if ($CacheK) { $llamaArgs += @('-ctk', $CacheK) }
    if ($CacheV) { $llamaArgs += @('-ctv', $CacheV) }
}

# MoE hybrid split - only if this build knows the flag.
if ($CpuMoe -gt 0) {
    $knows = (& $server --help 2>&1 | Select-String -SimpleMatch 'n-cpu-moe') -ne $null
    if ($knows) { $llamaArgs += @('--n-cpu-moe', "$CpuMoe") }
    else {
        Write-Host "  ! this build has no --n-cpu-moe; use an -ot/--override-tensor recipe instead" -ForegroundColor Yellow
    }
}

if ($Extra.Count -gt 0) {
    # `pwsh -File script.ps1 -Extra a,b` binds one string to a [string[]] parameter; split it back.
    if ($Extra.Count -eq 1 -and $Extra[0] -match ',') { $Extra = $Extra[0] -split '\s*,\s*' }
    $llamaArgs += $Extra
}

# Speculative decoding. draft-mtp uses the model's own multi-token-prediction head, so it costs
# no extra VRAM; ngram-* need no draft model at all.
if ($SpecType) { $llamaArgs += @('--spec-type', $SpecType) }
if ($SpecDraftModel) { $llamaArgs += @('--spec-draft-model', $SpecDraftModel) }

# Stable model id for OpenAI clients (/v1/models, dsh, Claude Code shims). Without it the id
# is the file basename, which for an HF blob is a 64-char sha256 and changes on every re-pull.
if ($Alias) { $llamaArgs += @('--alias', $Alias) }

# --- warn when the model will not fit --------------------------------------
if ($Backend -in 'cuda', 'vulkan') {
    $modelGB = (Get-Item $Model).Length / 1GB
    $vramGB = 8.0
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if ($nvHere -and (Test-Path $smi)) {
        $m = & $smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        if ($m -and $m -match '^\d+') { $vramGB = [double]$m / 1024 }
    }
    # KV bytes per token, read from the model's own attention geometry. The previous constant was
    # calibrated on a 36-layer / 8-KV-head 7B and overstated small-KV architectures by ~8x: it
    # printed "3.9 GB + KV 19.7 GB" for gemma-4 at ctx 131072, which really costs 2.3 GB and loads.
    $kvPerTok = 0.0
    $planner = Join-Path $PSScriptRoot 'llm-plan.ps1'
    if (Test-Path $planner) {
        $pj = pwsh -NoProfile -File $planner -Model $Model -Ctx $Ctx -CacheK $CacheK -Json 2>$null |
            Where-Object { $_ -like '{*' } | ConvertFrom-Json
        if ($pj -and $pj.KvBytesPerToken -gt 0) { $kvPerTok = [double]$pj.KvBytesPerToken }
    }
    if ($kvPerTok -le 0) {
        $kb = switch ($CacheK) { 'f16' { 150.0 } 'q8_0' { 80.0 } 'q4_0' { 42.0 } default { 80.0 } }
        $kvPerTok = $kb * 1024
    }
    $kvGB = $kvPerTok * $Ctx / 1GB
    $need = $modelGB + $kvGB

    # Evidence beats arithmetic. If the registry already serves this exact file at this context,
    # the window is measured, not estimated - so an estimate that says "will not fit" is wrong by
    # definition. This is what kept warning about gemma-4 at 131072, where the geometric figure is
    # ~5x too high because 5 of every 6 layers are sliding-window and never keep the full cache.
    $proven = $false
    $registry = Join-Path $PSScriptRoot 'llm-up.ps1'
    if (Test-Path $registry) {
        $rt = Get-Content $registry -Raw
        $base = [regex]::Escape([IO.Path]::GetFileName($Model))
        foreach ($mm in [regex]::Matches($rt, "(?m)^\s*(?<k>\w+)\s*=\s*@\{(?<b>[^}]*)\}")) {
            $body = $mm.Groups['b'].Value
            if ($body -notmatch ("File\s*=\s*'" + $base + "'")) { continue }
            $cm = [regex]::Match($body, 'Ctx\s*=\s*(\d+)')
            if ($cm.Success -and [int]$cm.Groups[1].Value -ge $Ctx) { $proven = $mm.Groups['k'].Value }
        }
    }

    if ($need -gt ($vramGB - 0.5)) {
        if ($proven) {
            Write-Host ("  note: model {0:N1} GB + est. KV {1:N1} GB > {2:N1} GB, but '{3}' already serves this window - measured, so loading." -f $modelGB, $kvGB, $vramGB, $proven) -ForegroundColor DarkGray
        } else {
            Write-Host ("  ! model {0:N1} GB + KV ~{1:N1} GB (ctx {2}) > {3:N1} GB VRAM - layers will spill to DDR5." -f $modelGB, $kvGB, $Ctx, $vramGB) -ForegroundColor Yellow
            Write-Host "    (KV is estimated from attention geometry; sliding-window models cost less.)" -ForegroundColor DarkYellow
            if ($CpuMoe -gt 0) {
                Write-Host "    MoE split requested, so only the expert tensors go to RAM - fine." -ForegroundColor DarkYellow
            } else {
                Write-Host "    MoE model? add -CpuMoe 20-40. Dense? shrink -Ctx, use -CacheK q4_0, or a smaller quant." -ForegroundColor Yellow
            }
        }
    }
}

# --- launch ----------------------------------------------------------------
if ($DryRun) {
    Write-Host ""
    Write-Host "  $server " -ForegroundColor Cyan -NoNewline
    Write-Host ($llamaArgs -join ' ') -ForegroundColor DarkGray
    Write-Host ""
    return
}

Write-Host ""
Write-Host "  llama.cpp $tag  |  backend: $Backend  |  ctx: $Ctx  |  threads: $Threads" -ForegroundColor Cyan
Write-Host "  model: $Model" -ForegroundColor DarkGray
Write-Host "  API:   http://127.0.0.1:$Port/v1  (OpenAI)   http://127.0.0.1:$Port/docs" -ForegroundColor Cyan
if ($Backend -eq 'openvino') {
    Write-Host "  note:  OpenVINO compiles its graph on load - expect ~20-40 s before /health returns ok" -ForegroundColor DarkYellow
}
Write-Host ""

Push-Location $binDir
try {
    & $server @llamaArgs
} finally {
    Pop-Location
}
