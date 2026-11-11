<#
.SYNOPSIS
    Verify every local-LLM runtime on this machine and print one status table.

.EXAMPLE
    .\llm-check.ps1
    .\llm-check.ps1 -SkipPython     # faster: skip the import test
#>
[CmdletBinding()]
param([switch]$SkipPython)

$ErrorActionPreference = 'Continue'
$llmRoot = Split-Path $PSScriptRoot -Parent
$rows = [System.Collections.Generic.List[object]]::new()

function Add-Row([string]$component, [string]$status, [string]$detail) {
    $rows.Add([pscustomobject]@{ Component = $component; Status = $status; Detail = $detail })
}

function Try-Cmd([string]$exe, [string[]]$cmdArgs, [string]$label) {
    $p = Get-Command $exe -ErrorAction SilentlyContinue
    if (-not $p) { Add-Row $label 'not found' 'not on PATH'; return $null }
    try {
        $out = & $p.Source @cmdArgs 2>&1 | Out-String
        return $out.Trim()
    } catch { return $null }
}

# ---------------------------------------------------------------- hardware
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
$gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'Intel' } | Select-Object -First 1
$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0)
Add-Row 'CPU' 'ok' "$($cpu.Name.Trim()) | $($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T"
Add-Row 'RAM' 'ok' "$ramGB GB DDR5-5600 dual channel (~60 GB/s read)"
Add-Row 'iGPU' 'ok' "$($gpu.Name) | driver $($gpu.DriverVersion)"

# ---------------------------------------------------------------- dGPU
$nvPresent = Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VEN_10DE' } | Select-Object -First 1
if ($nvPresent) {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    $info = if (Test-Path $smi) {
        (& $smi --query-gpu=memory.total,driver_version --format=csv,noheader 2>$null) -join ' | '
    } else { 'nvidia-smi missing' }
    Add-Row 'dGPU (RTX 5060)' 'ok' "$($nvPresent.FriendlyName) | $info"
} else {
    $phantom = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_10DE' } | Select-Object -First 1
    if ($phantom) {
        Add-Row 'dGPU (RTX 5060)' 'OFF' "absent from PCI bus ($($phantom.Problem)) - run .\llm-gpu.ps1"
    } else {
        Add-Row 'dGPU (RTX 5060)' 'not found' 'no NVIDIA display device known to Windows'
    }
}

try {
    $avx2 = [System.Runtime.Intrinsics.X86.Avx2]::IsSupported
    $vnni = [System.Runtime.Intrinsics.X86.AvxVnni]::IsSupported
    Add-Row 'CPU ISA' 'ok' "AVX2=$avx2 AVX-VNNI=$vnni AVX512=$([System.Runtime.Intrinsics.X86.Avx512F]::IsSupported)"
} catch {
    # Windows PowerShell 5.1 (.NET Framework) does not expose System.Runtime.Intrinsics.
    Add-Row 'CPU ISA' 'n/a' 'run this script under pwsh 7 for the AVX probe'
}

# ---------------------------------------------------------------- vulkan
$vulkanDll = 'C:\Windows\System32\vulkan-1.dll'
if (Test-Path $vulkanDll) {
    $vkDev = & "$env:WINDIR\System32\vulkaninfo.exe" --summary 2>&1 |
        Select-String -Pattern 'deviceName' | Select-Object -First 1
    $vkName = if ($vkDev) { ($vkDev.Line -split '=')[-1].Trim() } else { '?' }
    Add-Row 'Vulkan runtime' 'ok' "vulkan-1.dll $((Get-Item $vulkanDll).VersionInfo.FileVersion) | device: $vkName"
} else { Add-Row 'Vulkan runtime' 'MISSING' 'install the Intel graphics driver' }

# ---------------------------------------------------------------- llama.cpp
$buildsRoot = Join-Path $llmRoot 'llama.cpp'
if (Test-Path $buildsRoot) {
    $tag = Get-ChildItem $buildsRoot -Directory | Sort-Object { [int]($_.Name -replace '\D', '') } -Descending | Select-Object -First 1 -ExpandProperty Name
    foreach ($b in 'cuda', 'cpu', 'vulkan', 'openvino') {
        $exe = Join-Path $buildsRoot "$tag\$b\llama-server.exe"
        if (Test-Path $exe) {
            $dll = switch ($b) {
                'cuda' { 'ggml-cuda.dll' }
                'cpu' { 'ggml-cpu-alderlake.dll' }
                'vulkan' { 'ggml-vulkan.dll' }
                'openvino' { 'ggml-openvino.dll' }
            }
            $has = Test-Path (Join-Path $buildsRoot "$tag\$b\$dll")
            $st = if ($b -eq 'cuda' -and -not $has) { 'MISSING' } else { 'ok' }
            Add-Row "llama.cpp $b" $st "$tag | backend dll $(if ($has) { 'present' } else { 'MISSING' })"
        } else { Add-Row "llama.cpp $b" 'MISSING' $exe }
    }
    $onPath = Get-Command llama-server -ErrorAction SilentlyContinue
    Add-Row 'llama-server on PATH' $(if ($onPath) { 'ok' } else { 'no' }) $(if ($onPath) { $onPath.Source } else { 'add llm\llama.cpp\<tag>\cpu to PATH' })
} else { Add-Row 'llama.cpp' 'MISSING' $buildsRoot }

# ---------------------------------------------------------------- toolchain
foreach ($t in @(
        @{ n = 'CMake'; p = "$llmRoot\tools\cmake-4.4.5-windows-x86_64\bin\cmake.exe" },
        @{ n = 'Ninja'; p = "$llmRoot\tools\ninja\ninja.exe" },
        @{ n = 'MSVC (cl.exe)'; p = $null }
    )) {
    if ($t.n -eq 'MSVC (cl.exe)') {
        $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path $vswhere) {
            $vspath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
            Add-Row 'MSVC (cl.exe)' $(if ($vspath) { 'ok' } else { 'partial' }) $(if ($vspath) { $vspath } else { 'VS installer present, C++ workload not found' })
        } else { Add-Row 'MSVC (cl.exe)' 'not found' 'optional: winget install Microsoft.VisualStudio.2022.BuildTools' }
        continue
    }
    if (Test-Path $t.p) { Add-Row $t.n 'ok' ((& $t.p --version 2>&1 | Select-Object -First 1)) }
    else { Add-Row $t.n 'MISSING' $t.p }
}

# ---------------------------------------------------------------- engine CLIs
$ollamaVer = Try-Cmd 'ollama' @('--version') 'Ollama'
if ($ollamaVer) {
    $models = (& ollama list 2>&1 | Measure-Object -Line).Lines - 1
    Add-Row 'Ollama' 'ok' "$($ollamaVer -replace 'ollama version is ', '') | $models model(s)"
} else { Add-Row 'Ollama' 'not found' '' }

$lmsVer = Get-Command lms -ErrorAction SilentlyContinue
if ($lmsVer) {
    # The selected engine lives in backend-preferences-v2.json; the CLI table uses a
    # unicode tick that mangles under a Turkish OEM code page, so read the JSON instead.
    $prefFile = Join-Path $env:USERPROFILE '.lmstudio\.internal\backend-preferences-v2.json'
    $gguf = $null; $ggufVer = $null
    if (Test-Path $prefFile) {
        try {
            $pref = Get-Content $prefFile -Raw | ConvertFrom-Json
            $gguf = $pref.formatDefaults.gguf
            $ggufVer = $pref.versions.$gguf
        } catch { }
    }
    if ($gguf) {
        $isGpuRt = $gguf -match 'cuda|vulkan'
        Add-Row 'LM Studio' $(if ($isGpuRt) { 'ok' } else { 'check' }) "gguf engine: $gguf @ $ggufVer$(if ($gguf -match 'vulkan' -and $nvPresent) { ' (switch to cuda12 now that the dGPU is on)' })"
    } else {
        Add-Row 'LM Studio' 'ok' "lms present; engine preference unreadable"
    }
} else { Add-Row 'LM Studio' 'not found' '' }

$lemonade = Get-Command lemonade.exe -ErrorAction SilentlyContinue
if ($lemonade) {
    $v = (& lemonade.exe --version 2>&1 | Out-String).Trim()
    Add-Row 'Lemonade (OpenVINO)' 'ok' $v
}

# ---------------------------------------------------------------- python
if (-not $SkipPython) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    # prefer the dedicated LLM venv over whatever 'python' resolves to
    $venvPy = Join-Path $llmRoot 'venv\Scripts\python.exe'
    if (Test-Path $venvPy) { $py = [pscustomobject]@{ Source = $venvPy } }
    if ($py) {
        $ver = (& $py.Source --version 2>&1).Trim()
        $label = if ($py.Source -like '*\llm\venv\*') { 'Python (llm venv)' } else { 'Python' }
        Add-Row $label 'ok' "$ver ($($py.Source))"
        $probe = @'
import importlib, json
out = {}
for m in ("torch","transformers","llama_cpp","openvino","optimum.intel","openvino_genai", "sentence_transformers"):
    try:
        mod = importlib.import_module(m)
        out[m] = getattr(mod, "__version__", "ok")
    except Exception as e:
        out[m] = "MISSING"
try:
    import openvino as ov
    out["openvino_devices"] = ",".join(ov.Core().available_devices)
except Exception:
    out["openvino_devices"] = "?"
print(json.dumps(out))
'@
        $json = ($probe | & $py.Source -) 2>&1 | Out-String
        $d = $null
        try { $d = $json.Trim() | ConvertFrom-Json } catch { }
        if ($d) {
            foreach ($k in 'torch', 'transformers', 'llama_cpp', 'openvino', 'optimum.intel', 'openvino_genai', 'sentence_transformers') {
                $v = $d.PSObject.Properties[$k].Value
                Add-Row "py:$k" $(if ($v -eq 'MISSING' -or $null -eq $v) { 'MISSING' } else { 'ok' }) "$v"
            }
            Add-Row 'OpenVINO devices' 'ok' "$($d.openvino_devices)"
        }
    } else { Add-Row 'Python' 'not found' '' }
}

# ---------------------------------------------------------------- disk
$c = Get-PSDrive C
Add-Row 'Disk C: free' 'ok' "$([math]::Round($c.Free / 1GB, 1)) GB"

# ---------------------------------------------------------------- output
$rows | Format-Table -AutoSize -Wrap
$bad = $rows | Where-Object { $_.Status -in 'MISSING', 'not found', 'partial' }
if ($bad) {
    Write-Host "$($bad.Count) component(s) need attention:" -ForegroundColor Yellow
    $bad | ForEach-Object { Write-Host "  - $($_.Component): $($_.Detail)" -ForegroundColor Yellow }
} else {
    Write-Host "All components present." -ForegroundColor Green
}
