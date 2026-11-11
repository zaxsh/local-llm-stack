# Second half of the llama-direct.exe test: adopting an already-running server,
# the "Open web UI" button, and the "Folder" button.
# Run with Windows PowerShell 5.1 (powershell.exe).
param(
    [string]$Exe = "$env:USERPROFILE\Desktop\llama-direct.exe",
    [int]$Port = 8083
)

Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class W32B
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindowW(IntPtr cls, string title);
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
    public static IntPtr FindWin(string title) { return FindWindowW(IntPtr.Zero, title); }

    public static List<IntPtr> Children(IntPtr parent)
    {
        List<IntPtr> found = new List<IntPtr>();
        EnumChildWindows(parent, delegate (IntPtr h, IntPtr l) { found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindButton(IntPtr parent, string text)
    {
        foreach (IntPtr h in Children(parent))
            if (Cls(h).IndexOf("BUTTON") >= 0 && Text(h) == text) return h;
        return IntPtr.Zero;
    }
}
"@

function Get-Status($h) {
    $texts = @()
    foreach ($c in [W32B]::Children($h)) {
        if ([W32B]::Cls($c) -match 'STATIC') { $t = [W32B]::Text($c); if ($t) { $texts += $t } }
    }
    return $texts
}

Write-Host "  --- part 1: Open web UI with nothing running (guard) ---"
Get-Process llama-direct -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$p = Start-Process $Exe -PassThru
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 250; $h = [W32B]::FindWin('llama.cpp - local models'); if ($h -ne [IntPtr]::Zero) { break } }
if ($h -eq [IntPtr]::Zero) { Write-Host "  FAILED: no window" -ForegroundColor Red; $p | Stop-Process -Force; exit 1 }

$open = [W32B]::FindButton($h, 'Open web UI')
$null = [W32B]::SendMessage($open, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 2
$msg = Get-Status $h | Where-Object { $_ -match 'Start a model first' }
if ($msg) { Write-Host "  guard works: '$msg'" -ForegroundColor Green }
else { Write-Host "  guard did not fire" -ForegroundColor Yellow }

Write-Host ""
Write-Host "  --- part 2: adopt a server started outside the window ---"
$null = [W32B]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 2
if (-not $p.HasExited) { $p | Stop-Process -Force }

& $Exe --start gemma4 | Out-Null
$healthy = $false
for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Seconds 1; try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 1).status -eq 'ok') { $healthy = $true; break } } catch { } }
Write-Host ("  server started by --start: {0}" -f $healthy) -ForegroundColor $(if ($healthy) { 'Green' } else { 'Red' })

$p2 = Start-Process $Exe -PassThru
$h2 = [IntPtr]::Zero
for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 250; $h2 = [W32B]::FindWin('llama.cpp - local models'); if ($h2 -ne [IntPtr]::Zero) { break } }
Start-Sleep -Seconds 3   # the probe runs on a background thread
$adopted = Get-Status $h2 | Where-Object { $_ -match 'Already running' }
if ($adopted) { Write-Host "  adopted: '$adopted'" -ForegroundColor Green }
else { Write-Host "  did NOT adopt the running server" -ForegroundColor Red }

Write-Host ""
Write-Host "  --- part 3: Open web UI with a model running ---"
$before = @(Get-Process msedge, chrome, firefox, brave, opera, vivaldi -ErrorAction SilentlyContinue).Count
$null = [W32B]::SendMessage([W32B]::FindButton($h2, 'Open web UI'), 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 6
$after = @(Get-Process msedge, chrome, firefox, brave, opera, vivaldi -ErrorAction SilentlyContinue).Count
Write-Host ("  browser processes before/after: {0} / {1}" -f $before, $after)
if ($after -gt $before) { Write-Host "  the browser was launched" -ForegroundColor Green }
else { Write-Host "  no new browser process - check the default browser association" -ForegroundColor Yellow }

Write-Host ""
Write-Host "  --- part 4: Folder button ---"
$explorers = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
$null = [W32B]::SendMessage([W32B]::FindButton($h2, 'Folder'), 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 3
Write-Host ("  explorer processes before/after: {0} / {1}" -f $explorers, @(Get-Process explorer -ErrorAction SilentlyContinue).Count)

Write-Host ""
Write-Host "  --- part 5: clean up ---"
$null = [W32B]::SendMessage([W32B]::FindButton($h2, 'Stop'), 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 4
Write-Host ("  llama-server left: {0}" -f @(Get-Process llama-server -ErrorAction SilentlyContinue).Count)
$null = [W32B]::PostMessage($h2, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 2
if (-not $p2.HasExited) { $p2 | Stop-Process -Force }
& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=memory.used --format=csv,noheader
Write-Host "  done"
