# End-to-end test of llama-direct.exe by driving its real window:
# find the actual Win32 button controls, send BM_CLICK, and read the status label back.
# Run with Windows PowerShell 5.1 (powershell.exe).
param(
    [string]$Exe = "$env:USERPROFILE\Desktop\llama-direct.exe",
    [int]$Port = 8083,
    [int]$WaitSeconds = 90
)

Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class W32
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindowW(IntPtr cls, string title);
    // passing $null through PowerShell marshals to "" not NULL, so wrap the IntPtr overload
    public static IntPtr FindWin(string title) { return FindWindowW(IntPtr.Zero, title); }
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    public static string Text(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
    public static string Cls(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }

    public static List<IntPtr> Children(IntPtr parent)
    {
        List<IntPtr> found = new List<IntPtr>();
        EnumChildWindows(parent, delegate (IntPtr h, IntPtr l) { found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindButton(IntPtr parent, string text)
    {
        foreach (IntPtr h in Children(parent))
        {
            if (Cls(h).IndexOf("BUTTON") >= 0 && Text(h) == text) return h;
        }
        return IntPtr.Zero;
    }
}
"@

function Get-Status($h) {
    $texts = @()
    foreach ($c in [W32]::Children($h)) {
        if ([W32]::Cls($c) -match 'STATIC') { $t = [W32]::Text($c); if ($t) { $texts += $t } }
    }
    return $texts
}

Write-Host "  cleaning up previous runs"
Get-Process llama-direct -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

Write-Host "  launching $Exe"
$p = Start-Process $Exe -PassThru

$h = [IntPtr]::Zero
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $h = [W32]::FindWin('llama.cpp - local models')
    if ($h -ne [IntPtr]::Zero) { break }
    if ($p.HasExited) { Write-Host "  FAILED: process exited before showing a window" -ForegroundColor Red; exit 1 }
}
if ($h -eq [IntPtr]::Zero) { Write-Host "  FAILED: no window after 15 s" -ForegroundColor Red; $p | Stop-Process -Force; exit 1 }
Write-Host ("  window found: {0}  ({1:0.0} s)" -f [W32]::Text($h), $i * 0.25) -ForegroundColor Green

Write-Host "  controls in the window:"
foreach ($c in [W32]::Children($h)) {
    $cls = [W32]::Cls($c) -replace 'WindowsForms10\.', '' -replace '\.app\.0\..*', ''
    $t = [W32]::Text($c)
    if ($t) { "    {0,-10} [{1}]" -f $cls, $t }
}

$start = [W32]::FindButton($h, 'Start model')
if ($start -eq [IntPtr]::Zero) { Write-Host "  FAILED: no Start model button" -ForegroundColor Red; exit 1 }
Write-Host "  clicking 'Start model' (BM_CLICK)"
$null = [W32]::SendMessage($start, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)

$ok = $false
for ($i = 0; $i -lt $WaitSeconds; $i++) {
    Start-Sleep -Seconds 1
    try {
        $health = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 1
        if ($health.status -eq 'ok') { $ok = $true; break }
    } catch { }
    if ($p.HasExited) { Write-Host "  FAILED: window died while starting" -ForegroundColor Red; exit 1 }
    if (($i % 10) -eq 0 -and $i -gt 0) { Write-Host ("    still loading... {0} s" -f $i) }
}
Write-Host ("  server on :{0} healthy: {1}" -f $Port, $ok) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
if (-not $ok) { Write-Host "  FAILED: the button did not start a working server" -ForegroundColor Red; exit 1 }

$running = (Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 5).data.id
Write-Host "  alias served: $running"

Start-Sleep -Seconds 1
$labels = Get-Status $h
Write-Host "  status labels now:"
$labels | ForEach-Object { "    [$_]" }
$line = $labels | Where-Object { $_ -match 'Running:' }
if ($line) { Write-Host "  status line updated: $line" -ForegroundColor Green }
else { Write-Host "  status line did not update" -ForegroundColor Yellow }

# a real generation through the endpoint the UI advertises
$b = @{ model = $running; messages = @(@{ role = 'user'; content = 'Reply with the single word: ready' }); max_tokens = 40 } | ConvertTo-Json -Depth 5
$r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $b -TimeoutSec 180
Write-Host ("  generation works: {0:N1} t/s" -f $r.timings.predicted_per_second) -ForegroundColor Green

$stop = [W32]::FindButton($h, 'Stop')
if ($stop -eq [IntPtr]::Zero) { Write-Host "  FAILED: no Stop button" -ForegroundColor Red; exit 1 }
Write-Host "  clicking 'Stop'"
$null = [W32]::SendMessage($stop, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 5
$left = @(Get-Process llama-server -ErrorAction SilentlyContinue).Count
Write-Host ("  llama-server processes left: {0}" -f $left) -ForegroundColor $(if ($left -eq 0) { 'Green' } else { 'Red' })
$stopped = Get-Status $h | Where-Object { $_ -match 'Stopped' }
if ($stopped) { Write-Host "  status: $stopped" -ForegroundColor Green }
$vram = [int](@(& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=memory.used --format=csv,noheader,nounits) | Select-Object -First 1)
Write-Host "  VRAM in use after stop: $vram MB"

Write-Host "  closing the window"
$null = [W32]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
Start-Sleep -Seconds 2
$p.Refresh()
Write-Host ("  window closed cleanly: {0}" -f $p.HasExited) -ForegroundColor $(if ($p.HasExited) { 'Green' } else { 'Yellow' })
if (-not $p.HasExited) { $p | Stop-Process -Force }
Write-Host "  done"
