<#
.SYNOPSIS
    Find the discrete NVIDIA GPU on this laptop, explain why it is missing, and bring it back.

.DESCRIPTION
    This machine (MS-17T4, BIOS E17T4IMS.10C) has TWO GPUs:
      * Intel Graphics          - 4 Xe cores, shares DDR5, always on
      * NVIDIA GeForce RTX 5060 - 8 GB GDDR7, ~448 GB/s, the one that matters for LLM speed

    The dGPU is routinely invisible for one of three reasons, in order of likelihood:

      1. MSI Center "GPU Switch" is set to Integrated / UMA mode.
         In that mode the EC cuts power to the dGPU and the PCI device is not even
         enumerated, so Windows keeps the old node as a phantom (Code 45,
         "this hardware device is not connected"). Fix in the MSI Center GUI, then reboot.
      2. BIOS "Graphics Configuration" set to iGPU only.  Fix in BIOS setup.
      3. The GPU fell off the PCIe bus (driver/TDR/resume bug). Fix: rescan, or reboot.

    Without -Fix this script only reports. With -Fix (needs an elevated shell) it runs the
    software-side repairs that can be done from Windows: device rescan, re-enable, power
    plan, Defender exclusions. It cannot flip a BIOS/EC switch - that is step 1 above.

.EXAMPLE
    .\llm-gpu.ps1
    .\llm-gpu.ps1 -Fix          # elevated PowerShell
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [string]$ModelsPath = 'C:\Users\fih\llm\models',
    [string]$OllamaModelsPath = 'C:\Users\fih\.cache\huggingface\hub'
)

$ErrorActionPreference = 'Continue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Line([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }

Line ""
Line "  DISCRETE GPU STATUS" 'Cyan'
Line "  -------------------" 'Cyan'

# ---------------------------------------------------------------- present adapters
$present = @(Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue)
$nvPresent = $present | Where-Object { $_.InstanceId -match 'VEN_10DE' }
$intelPresent = $present | Where-Object { $_.InstanceId -match 'VEN_8086' }

foreach ($a in $present) {
    $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -eq $a.InstanceId } | Select-Object -First 1
    $drv = if ($vc) { $vc.DriverVersion } else { '?' }
    Line ("  [ok]      {0}  (driver {1})" -f $a.FriendlyName, $drv) 'Green'
}

# ---------------------------------------------------------------- phantom (gone) adapters
$phantom = @(Get-PnpDevice -Class Display, MEDIA, System -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VEN_10DE' -and $_.Status -ne 'OK' })

$nvInstance = ($phantom | Where-Object { $_.Class -eq 'Display' } | Select-Object -First 1).InstanceId
if (-not $nvInstance) {
    $nvInstance = (Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_10DE' } | Select-Object -First 1).InstanceId
}

if (-not $nvPresent) {
    Line ""
    Line "  [OFF]     NVIDIA GeForce RTX 5060 Laptop GPU - not on the PCI bus" 'Red'
    if ($nvInstance) {
        $p = Get-PnpDevice -InstanceId $nvInstance -ErrorAction SilentlyContinue
        $arrival = Get-PnpDeviceProperty -InstanceId $nvInstance -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction SilentlyContinue
        Line ("            last seen : {0}   problem: {1}" -f $arrival.Data, $p.Problem)
        Line ("            pnp id    : {0}" -f $nvInstance)
    }
    Line ""
    Line "  This is the single biggest lever you have: 8 GB GDDR7 at ~448 GB/s vs" 'Yellow'
    Line "  ~60 GB/s of DDR5. On a 7B Q4_K_M that is roughly 13 t/s -> 45-60 t/s." 'Yellow'
    Line ""
    Line "  Fix ladder (do these in order):" 'Cyan'
    Line "    1. MSI Center -> Features -> General Settings -> GPU Switch -> 'Hybrid Graphics'"
    Line "       (or 'Discrete Graphics'), then REBOOT. Integrated/UMA mode powers the"
    Line "       dGPU down completely - this is the usual cause of Code 45 on MSI laptops."
    Line "    2. MSI Center -> User Scenario -> 'Extreme Performance' (raises the shared"
    Line "       CPU+GPU power budget; a 255HX + 5060 will happily eat 150 W of it)."
    Line "    3. BIOS (Del at boot): Advanced -> Graphics Configuration -> enable the"
    Line "       discrete GPU / MUX, save & exit."
    Line "    4. Elevated shell: .\llm-gpu.ps1 -Fix   (rescan + re-enable + housekeeping)"
    Line "    5. Still missing after a cold boot? The GPU may have dropped off the bus:"
    Line "       power off (not restart), unplug, hold the power button 15 s, boot."
    Line ""
} else {
    Line ""
    Line "  [ok]      discrete NVIDIA GPU is enumerated" 'Green'
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path $smi) {
        $q = & $smi --query-gpu=name,memory.total,memory.used,driver_version,compute_cap,temperature.gpu,power.limit --format=csv,noheader 2>&1
        if ($LASTEXITCODE -eq 0) {
            Line ("            {0}" -f $q) 'Green'
        } else {
            Line ("            nvidia-smi failed: {0}" -f ($q -join ' ')) 'Yellow'
            Line "            (if this says 'insufficient permissions', run this script elevated)" 'DarkYellow'
        }
    }
}

# ---------------------------------------------------------------- VRAM budget advice
Line ""
Line "  MEMORY BUDGET (how big a model actually fits)" 'Cyan'
Line "  -------------------------------------------" 'Cyan'
$vram = 8.0
if ($nvPresent) {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path $smi) {
        $m = & $smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        if ($m -and $m -match '^\d+') { $vram = [double]$m / 1024 }
    }
}
Line ("  VRAM available for the model : {0:N1} GB (leave ~0.6 GB for the desktop/compositor)" -f $vram)
$usable = [math]::Max(0, $vram - 0.6)
Line ("  usable for weights + KV cache: {0:N1} GB" -f $usable)
Line ""
Line "  Fits fully in VRAM (fastest):" 'Green'
$fits = @(
    @{ n = 'Qwen3-4B / Llama-3.2-3B  Q4_K_M'; g = 2.6; t = '55-75 t/s' },
    @{ n = 'Qwen3-8B / Qwen2.5-Coder-7B  Q4_K_M'; g = 4.9; t = '40-55 t/s' },
    @{ n = 'Qwen3-14B  IQ3_XXS / Q3_K_S'; g = 6.5; t = '28-38 t/s' },
    @{ n = 'gpt-oss-20b  MXFP4 (MoE, 3.6B active)'; g = 12.0; t = 'too big alone' }
)
foreach ($f in $fits) {
    $mark = if ($f.g -le $usable) { 'yes' } elseif ($f.g -le $usable + 3) { 'partial' } else { 'no ' }
    Line ("    [{0}] {1,-48} {2,5:N1} GB   ~{3}" -f $mark, $f.n, $f.g, $f.t) $(if ($mark -eq 'yes') { 'Green' } elseif ($mark -eq 'partial') { 'Yellow' } else { 'DarkGray' })
}
Line ""
Line "  Bigger than VRAM -> hybrid: put the dense/unshared part on the 5060 and the" 'DarkGray'
Line "  expert tensors in DDR5. For MoE models that is genuinely fast (30B-A3B at" 'DarkGray'
Line "  ~15-20 t/s), for dense models it is not (14B dense spills to ~8 t/s)." 'DarkGray'

# ---------------------------------------------------------------- elevated repairs
Line ""
if ($Fix) {
    if (-not $isAdmin) {
        Line "  -Fix needs an elevated shell. Right-click PowerShell -> 'Run as administrator'," 'Red'
        Line "  then: .\llm-gpu.ps1 -Fix" 'Red'
        return
    }
    Line "  APPLYING REPAIRS (elevated)" 'Cyan'
    Line "  ---------------------------" 'Cyan'

    Line "  [1] rescanning the PCI bus ..."
    & pnputil /scan-devices 2>&1 | ForEach-Object { Line "      $_" 'DarkGray' }

    if (-not $nvPresent -and $nvInstance) {
        Line "  [2] re-enabling the NVIDIA device node ..."
        & pnputil /enable-device "$nvInstance" 2>&1 | ForEach-Object { Line "      $_" 'DarkGray' }
    }

    Line "  [3] power plan -> High performance ..."
    & powercfg /setactive SCHEME_MIN 2>&1 | ForEach-Object { Line "      $_" 'DarkGray' }
    & powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 50 2>&1 | Out-Null
    & powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100 2>&1 | Out-Null
    & powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 2 2>&1 | Out-Null
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
    Line ("      active: " + ((powercfg /getactivescheme) -join ''))

    Line "  [4] Defender exclusions for multi-GB model files ..."
    foreach ($p in $ModelsPath, $OllamaModelsPath, 'C:\Users\fih\.lmstudio\models') {
        if (Test-Path $p) {
            try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; Line "      + $p" 'DarkGray' }
            catch { Line "      ! $p : $($_.Exception.Message)" 'Yellow' }
        }
    }

    Line "  [5] pagefile - Windows manages it, but confirm it is not tiny ..."
    Get-CimInstance Win32_PageFileUsage | ForEach-Object {
        Line ("      {0}: {1:N1} GB allocated, {2:N1} GB in use" -f $_.Name, ($_.AllocatedBaseSize / 1024), ($_.CurrentUsage / 1024))
    }

    Line ""
    Line "  VERIFY" 'Cyan'
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path $smi) {
        & $smi --query-gpu=name,memory.total,driver_version --format=csv 2>&1 | ForEach-Object { Line "      $_" }
    }
    Line "  If the GPU is still absent: it is switched off below the OS. Do the MSI Center"
    Line "  GPU Switch / BIOS step and reboot - no Windows-side command can undo that."
} else {
    Line "  Report only. Run '.\llm-gpu.ps1 -Fix' from an elevated shell to apply the" 'DarkGray'
    Line "  Windows-side repairs (rescan, re-enable, power plan, Defender exclusions)." 'DarkGray'
    if (-not $isAdmin) { Line "  (this shell is not elevated)" 'DarkGray' }
}
Line ""
