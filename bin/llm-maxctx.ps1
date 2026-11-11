<#
.SYNOPSIS
    Find, and optionally apply, the largest context window each model can load on this GPU.

.DESCRIPTION
    Two facts are needed per model: how many bytes of KV cache one token costs, and how much VRAM
    is left over while serving. Both are measured, not guessed:

      * load at 8192 and at 16384, read free VRAM at each  -> bytes per token
      * the spare VRAM at 16384 then buys more context   -> target

    The headroom is capped by the context the model was trained for, which is read straight out of
    the GGUF header (0.4 s, no weights loaded). The target is then loaded for real and measured, so
    a preset is only written if it actually works and is not much slower than before.

.PARAMETER Apply
    Rewrite the Ctx field in llm-up.ps1. Presets and llama-direct.exe then pick it up.
#>
[CmdletBinding()]
param(
    [string[]]$Models = @('gemma4', 'flint', 'qwen3', 'coder', 'gptoss', 'qwen36'),
    [int]$SafetyMB = 400,
    [int]$MaxTokens = 300,
    [switch]$Apply,
    [string]$Out = 'C:\Users\fih\llm\bench\maxctx.csv'
)

$ErrorActionPreference = 'Continue'
$bin = $PSScriptRoot
$modelsDir = 'C:\Users\fih\llm\models'
$exe = 'C:\Users\fih\llm\llama.cpp\b12255\cuda\llama-server.exe'
$smi = "$env:SystemRoot\System32\nvidia-smi.exe"
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

Add-Type @"
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
public class MaxCtxGguf
{
    static long Size(uint t) {
        switch (t) { case 0: case 1: case 7: return 1; case 2: case 3: return 2;
                     case 4: case 5: case 6: return 4; case 10: case 11: case 12: return 8; default: return -1; }
    }
    static void Skip(BinaryReader br, uint t) {
        long s = Size(t);
        if (s >= 0) { br.BaseStream.Seek(s, SeekOrigin.Current); return; }
        if (t == 8) { long l = (long)br.ReadUInt64(); br.BaseStream.Seek(l, SeekOrigin.Current); return; }
        if (t == 9) {
            uint et = br.ReadUInt32(); long n = (long)br.ReadUInt64(); long es = Size(et);
            if (es >= 0) { br.BaseStream.Seek(es * n, SeekOrigin.Current); return; }
            for (long i = 0; i < n; i++) { long l = (long)br.ReadUInt64(); br.BaseStream.Seek(l, SeekOrigin.Current); }
            return;
        }
        throw new Exception("bad type");
    }
    static object Read(BinaryReader br, uint t) {
        switch (t) {
            case 0: return (long)br.ReadByte(); case 1: return (long)br.ReadSByte();
            case 2: return (long)br.ReadUInt16(); case 3: return (long)br.ReadInt16();
            case 4: return (long)br.ReadUInt32(); case 5: return (long)br.ReadInt32();
            case 6: return (double)br.ReadSingle(); case 7: return (long)(br.ReadBoolean() ? 1 : 0);
            case 8: { long l = (long)br.ReadUInt64(); return Encoding.UTF8.GetString(br.ReadBytes((int)l)); }
            case 10: return (long)br.ReadUInt64(); case 11: return br.ReadInt64(); case 12: return br.ReadDouble();
        }
        throw new Exception("bad type");
    }
    public static Dictionary<string, object> Read(string path) {
        var res = new Dictionary<string, object>();
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (var br = new BinaryReader(fs)) {
            if (Encoding.ASCII.GetString(br.ReadBytes(4)) != "GGUF") return res;
            br.ReadUInt32(); br.ReadUInt64(); long n = (long)br.ReadUInt64();
            for (long i = 0; i < n; i++) {
                long kl = (long)br.ReadUInt64();
                string key = Encoding.UTF8.GetString(br.ReadBytes((int)kl));
                uint t = br.ReadUInt32();
                if (key == "general.architecture" || key.EndsWith(".context_length")) res[key] = Read(br, t);
                else Skip(br, t);
            }
        }
        return res;
    }
}
"@

$upPath = Join-Path $bin 'llm-up.ps1'
$up = Get-Content $upPath -Raw
$reg = [ordered]@{}
foreach ($m in [regex]::Matches($up, "(?m)^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)';\s*Port\s*=\s*(\d+);\s*Alias\s*=\s*'([^']+)';\s*Ctx\s*=\s*(\d+);\s*CpuMoe\s*=\s*(\d+);\s*Threads\s*=\s*(\d+)")) {
    $reg[$m.Groups[1].Value] = @{ File = $m.Groups[2].Value; Port = [int]$m.Groups[3].Value
        Alias = $m.Groups[4].Value; Ctx = [int]$m.Groups[5].Value; CpuMoe = [int]$m.Groups[6].Value
        Threads = [int]$m.Groups[7].Value }
}

function Stop-All {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    for ($i = 0; $i -lt 24; $i++) {
        if (@(Get-Process llama-server -ErrorAction SilentlyContinue).Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
}

function Free-MB { [int]((& $smi --query-gpu=memory.free --format=csv,noheader,nounits) | Select-Object -First 1) }

function Start-Model($key, [int]$ctx) {
    $e = $reg[$key]
    $a = @('-m', (Join-Path $modelsDir $e.File), '--alias', $e.Alias, '--host', '127.0.0.1',
        '--port', "$($e.Port)", '-c', "$ctx", '--jinja', '--metrics', '--no-warmup',
        '-t', "$($e.Threads)", '-tb', "$($e.Threads)", '-ngl', '99', '-fa', 'on',
        '-ctk', 'f16', '-ctv', 'f16')
    if ($e.CpuMoe -gt 0) { $a += @('--n-cpu-moe', "$($e.CpuMoe)") }
    $p = Start-Process $exe -ArgumentList $a -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$env:TEMP\mx.out" -RedirectStandardError "$env:TEMP\mx.err"
    for ($i = 0; $i -lt 200; $i++) {
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { return $null }
        try { if ((Invoke-RestMethod "http://127.0.0.1:$($e.Port)/health" -TimeoutSec 1).status -eq 'ok') { return $p } } catch { }
    }
    if (-not $p.HasExited) { $p | Stop-Process -Force }
    return $null
}

function Get-CtxMeasure($key) {
    $e = $reg[$key]
    $res = @{ Model = $key; CtxTrain = 0; CtxNow = $e.Ctx; FreeLo = 0; FreeHi = 0
              BytesPerTok = 0; CtxMax = 0; TpsNow = 0; TpsMax = 0; Status = '' }
    $meta = [MaxCtxGguf]::Read((Join-Path $modelsDir $e.File))
    $arch = $meta['general.architecture']
    if ($arch) { $res.CtxTrain = [int]$meta["$arch.context_length"] }

    # --- two points on the VRAM line
    Stop-All
    $p = Start-Model $key 8192
    if (-not $p) { $res.Status = '8192 failed'; return $res }
    $res.FreeLo = Free-MB
    $p | Stop-Process -Force; Stop-All

    $p = Start-Model $key 16384
    if (-not $p) { $res.Status = '16384 failed'; return $res }
    $res.FreeHi = Free-MB
    $res.BytesPerTok = [math]::Round((($res.FreeLo - $res.FreeHi) * 1MB) / 8192, 0)
    if ($res.BytesPerTok -le 0) { $res.Status = 'no KV growth'; $p | Stop-Process -Force; Stop-All; return $res }

    # --- speed at the old context, for comparison
    $body = @{ model = $e.Alias; messages = @(@{ role = 'user'; content = 'Explain how a KV cache grows with context length and why attention is quadratic.' }); max_tokens = $MaxTokens; temperature = 0.2 } | ConvertTo-Json -Depth 6
    try { $r = Invoke-RestMethod "http://127.0.0.1:$($e.Port)/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600
          $res.TpsNow = [math]::Round($r.timings.predicted_per_second, 1) } catch { }
    $p | Stop-Process -Force; Stop-All

    # --- the target
    $extra = [int][math]::Floor((($res.FreeHi - $SafetyMB) * 1MB) / $res.BytesPerTok)
    $max = 16384 + $extra
    if ($res.CtxTrain -gt 0 -and $max -gt $res.CtxTrain) { $max = $res.CtxTrain }
    if ($max -ge 65536) { $max = [int]([math]::Floor($max / 8192) * 8192) }
    elseif ($max -ge 16384) { $max = [int]([math]::Floor($max / 4096) * 4096) }
    else { $max = [int]([math]::Floor($max / 1024) * 1024) }
    $res.CtxMax = $max

    $p = Start-Model $key $max
    if (-not $p) { $res.Status = "target $max failed"; $res.CtxMax = 16384; return $res }
    try { $r = Invoke-RestMethod "http://127.0.0.1:$($e.Port)/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600
          $res.TpsMax = [math]::Round($r.timings.predicted_per_second, 1) } catch { }
    $res.Status = 'ok'
    $p | Stop-Process -Force; Stop-All
    return $res
}

$rows = @()
foreach ($key in $Models) {
    if (-not $reg[$key]) { Write-Host "  unknown model $key" -ForegroundColor Red; continue }
    Write-Host ""
    Write-Host "  === $key ===" -ForegroundColor Cyan
    $r = Get-CtxMeasure $key
    Write-Host ("  ctx {0} -> {1}   KV {2:N0} bytes/token   trained for {3}" -f $r.CtxNow, $r.CtxMax, $r.BytesPerTok, $r.CtxTrain) -ForegroundColor Green
    Write-Host ("  speed {0} -> {1} t/s   ({2})" -f $r.TpsNow, $r.TpsMax, $r.Status) -ForegroundColor DarkGray
    $rows += [pscustomobject]$r
}

$rows | Export-Csv $Out -NoTypeInformation -Encoding UTF8
Write-Host ""
$rows | Format-Table Model, CtxNow, CtxMax, CtxTrain, BytesPerTok, FreeHi, TpsNow, TpsMax, Status -AutoSize

if ($Apply) {
    $changed = @()
    foreach ($r in $rows) {
        if ($r.Status -ne 'ok' -or $r.CtxMax -le 0 -or $r.CtxMax -eq $r.CtxNow) { continue }
        $pattern = "(?m)^(\s*$($r.Model)\s*=\s*@\{\s*File\s*=\s*'$([regex]::Escape($reg[$r.Model].File))';\s*Port\s*=\s*\d+;\s*Alias\s*=\s*'[^']*';\s*Ctx\s*=\s*)\d+"
        $up = [regex]::Replace($up, $pattern, "`${1}$($r.CtxMax)")
        $changed += "$($r.Model): $($r.CtxNow) -> $($r.CtxMax)"
    }
    [System.IO.File]::WriteAllText($upPath, $up)
    $changed | ForEach-Object { "  applied $_" }
    Write-Host "  now run: .\llm-desktop.ps1 -SkipBinaries ; .\llm-direct.ps1" -ForegroundColor Cyan
}
