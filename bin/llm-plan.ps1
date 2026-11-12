<#
.SYNOPSIS
    Read a GGUF's real geometry and work out whether it fits the 5060, what the best
    offload split is, and what generation speed to expect - without loading the model.

.DESCRIPTION
    For a DENSE model the answer is binary: it fits in VRAM or it is slow.

    For an MoE model the answer is a number. Only top-k of N experts fire per token, so the
    bytes that actually cross the bus per token are:

        non_expert_bytes  +  expert_bytes * (k / N)

    ...which is often far smaller than the file. A 22 GB, 40B model with 256 experts and
    top-6 reads ~2.1 GB per token, less than a dense 8B. That is why an MoE can be both
    huge and fast, and why the right --n-cpu-moe is worth measuring.

    This script parses the GGUF header only (a few MB of reads, no weights), then solves
    for the split that maximises speed inside the VRAM budget.

.EXAMPLE
    .\llm-plan.ps1 -Model .\models\Qwen3-8B-Q4_K_M.gguf
    .\llm-plan.ps1 -Model $env:USERPROFILE\.cache\huggingface\hub\blobs\sha256-97cc8009...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Model,
    [switch]$Json,
    [int]$Ctx = 16384,
    [double]$VramGB = 0,      # 0 = detect
    [double]$DdrGBs = 60,
    [double]$Efficiency = 0.55,   # fraction of theoretical bandwidth llama.cpp achieves
    [string]$CacheK = 'q8_0'
)

$ErrorActionPreference = 'Stop'
$llmRoot = Split-Path $PSScriptRoot -Parent

if (-not (Test-Path $Model)) {
    $c = Join-Path (Join-Path $llmRoot 'models') $Model
    if (Test-Path $c) { $Model = $c } else { throw "Model not found: $Model" }
}
$Model = (Resolve-Path $Model).Path

# ---------------------------------------------------------------- GGUF reader
if (-not ('GgufReader' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Globalization;

public class GgufInfo {
  public string Arch = "?";
  public int Blocks, ExpertCount, ExpertUsed, Emb, ExpertFfn, Align = 32;
  // KV geometry: bytes of cache one token costs is Blocks * HeadCountKv * (KeyLength + ValueLength)
  // * bytes-per-element. Without these the launcher had to guess from a 7B-shaped constant.
  public int HeadCountKv, KeyLength, ValueLength;
  public long FileBytes, TotalParams, ExpertBytes, NonExpertBytes;
  public int ExpertLayers;
  public double BPW;
  public string Error = "";
}

public static class GgufReader {
  static BinaryReader br;
  static string RStr() {
    ulong n = br.ReadUInt64();
    if (n > 1_000_000_000UL) throw new Exception("bad string length");
    return Encoding.UTF8.GetString(br.ReadBytes((int)n));
  }
  static void SkipVal(int t) {
    switch (t) {
      case 0: case 1: case 7: br.ReadByte(); break;
      case 2: case 3: br.ReadUInt16(); break;
      case 4: case 5: case 6: br.ReadUInt32(); break;
      case 10: case 11: case 12: br.ReadUInt64(); break;
      case 8: { ulong n = br.ReadUInt64(); br.BaseStream.Seek((long)n, SeekOrigin.Current); break; }
      case 9: { int et = br.ReadInt32(); ulong c = br.ReadUInt64(); for (ulong i = 0; i < c; i++) SkipVal(et); break; }
      default: throw new Exception("unknown value type " + t);
    }
  }

  public static GgufInfo Read(string path) {
    var info = new GgufInfo();
    try {
      var fi = new FileInfo(path);
      info.FileBytes = fi.Length;
      using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
      using (var bs = new BufferedStream(fs, 1 << 20)) {
        br = new BinaryReader(bs, Encoding.UTF8, true);
        if (Encoding.ASCII.GetString(br.ReadBytes(4)) != "GGUF") { info.Error = "not a GGUF file"; return info; }
        uint ver = br.ReadUInt32();
        ulong nT = br.ReadUInt64();
        ulong nKv = br.ReadUInt64();

        for (ulong i = 0; i < nKv; i++) {
          string k = RStr();
          int t = br.ReadInt32();
          bool scalar = t != 9 && t != 8;
          if (k == "general.architecture" && t == 8) { info.Arch = RStr(); continue; }
          if (k == "general.alignment" && scalar) { info.Align = (int)br.ReadUInt32(); continue; }
          if (scalar && (k.EndsWith(".block_count") || k.EndsWith(".expert_count") || k.EndsWith(".expert_used_count")
                      || k.EndsWith(".embedding_length") || k.EndsWith(".expert_feed_forward_length")
                      || k.EndsWith(".attention.head_count_kv") || k.EndsWith(".attention.key_length")
                      || k.EndsWith(".attention.value_length"))) {
            long v = 0;
            switch (t) {
              case 4: v = br.ReadUInt32(); break;
              case 5: v = br.ReadInt32(); break;
              case 10: v = (long)br.ReadUInt64(); break;
              case 11: v = br.ReadInt64(); break;
              default: SkipVal(t); continue;
            }
            if (k.EndsWith(".block_count")) info.Blocks = (int)v;
            else if (k.EndsWith(".expert_count")) info.ExpertCount = (int)v;
            else if (k.EndsWith(".expert_used_count")) info.ExpertUsed = (int)v;
            else if (k.EndsWith(".embedding_length")) info.Emb = (int)v;
            else if (k.EndsWith(".expert_feed_forward_length")) info.ExpertFfn = (int)v;
            else if (k.EndsWith(".attention.head_count_kv")) info.HeadCountKv = (int)v;
            else if (k.EndsWith(".attention.key_length")) info.KeyLength = (int)v;
            else if (k.EndsWith(".attention.value_length")) info.ValueLength = (int)v;
            continue;
          }
          SkipVal(t);
        }

        // tensor infos: name, n_dims, dims..., type, offset
        var names = new List<string>((int)nT);
        var offs = new List<long>((int)nT);
        var elems = new List<long>((int)nT);
        var layerOf = new List<int>((int)nT);
        for (ulong i = 0; i < nT; i++) {
          string nm = RStr();
          uint nd = br.ReadUInt32();
          long e = 1;
          for (uint d = 0; d < nd; d++) e *= (long)br.ReadUInt64();
          br.ReadInt32();                       // type id - layout already summed in offsets
          long off = (long)br.ReadUInt64();
          int bi = -1;
          if (nm.StartsWith("blk.")) { int dot = nm.IndexOf('.', 4); int.TryParse(nm.Substring(4, dot - 4), out bi); }
          names.Add(nm); offs.Add(off); elems.Add(e); layerOf.Add(bi);
        }

        long pos = br.BaseStream.Position;
        long dataStart = (pos + info.Align - 1) / info.Align * info.Align;

        // exact tensor sizes from sorted offsets
        var idx = new List<int>(names.Count);
        for (int i = 0; i < names.Count; i++) idx.Add(i);
        idx.Sort((a, b) => offs[a].CompareTo(offs[b]));

        var layerExpertBytes = new Dictionary<int, long>();
        long exp = 0, non = 0, totalP = 0;
        for (int n = 0; n < idx.Count; n++) {
          int i = idx[n];
          long size = (n + 1 < idx.Count) ? (offs[idx[n + 1]] - offs[i]) : (info.FileBytes - dataStart - offs[i]);
          if (size < 0) size = 0;
          totalP += elems[i];
          bool isExp = names[i].Contains("_exps") || names[i].Contains("expert");
          if (isExp) {
            exp += size;
            int bi = layerOf[i];
            if (!layerExpertBytes.ContainsKey(bi)) layerExpertBytes[bi] = 0;
            layerExpertBytes[bi] += size;
          } else non += size;
        }
        info.ExpertBytes = exp;
        info.NonExpertBytes = non;
        info.TotalParams = totalP;
        info.ExpertLayers = layerExpertBytes.Count;
        info.BPW = totalP > 0 ? (info.FileBytes * 8.0 / totalP) : 0;
      }
    } catch (Exception ex) { info.Error = ex.Message; }
    return info;
  }
}
'@
}

Write-Host ""
Write-Host "  reading GGUF header (no weights loaded)..." -ForegroundColor DarkGray
$i = [GgufReader]::Read($Model)
if ($i.Error) { throw "GGUF parse failed: $($i.Error)" }

$isMoe = $i.ExpertCount -gt 1
$fileGB = $i.FileBytes / 1GB
$nonGB = $i.NonExpertBytes / 1GB
$expGB = $i.ExpertBytes / 1GB
$activeExpFrac = if ($isMoe) { $i.ExpertUsed / [double]$i.ExpertCount } else { 1.0 }
$activeGB = $nonGB + $expGB * $activeExpFrac

# ---------------------------------------------------------------- VRAM
if ($VramGB -le 0) {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    $m = $null
    if ((Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -match 'VEN_10DE' })) {
        # FREE, not total: on a hybrid laptop the desktop compositor already holds ~1 GB.
        $m = & $smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
    }
    $VramGB = if ($m -and $m -match '^\d+') { [double]$m / 1024 } else { 8.0 }
    if (-not $m) { Write-Host "  (dGPU not detected - assuming 8.0 GB)" -ForegroundColor DarkYellow }
}

# headroom: CUDA context + compute/graph buffers. The desktop's own VRAM use is already
# excluded, because the budget is based on FREE memory.
$overheadGB = if ($VramGB -lt 7.5) { 0.45 } else { 0.9 }
# KV bytes per token: exact when the header carries the attention geometry, otherwise the old
# dense-7B calibration. The calibration is 3-8x too high for small-KV architectures (gemma-4 is
# 17 KB/token, the constant claimed 150 KB), which is how the launcher came to warn about a
# "19.7 GB KV cache" on a model that occupies 2.3 GB and loads in 13 s.
$kvElemBytes = switch ($CacheK) { 'f16' { 2.0 } 'q8_0' { 1.0 } 'q4_0' { 0.5 } default { 1.0 } }
$kvBytesPerToken = 0.0
if ($i.Blocks -gt 0 -and $i.HeadCountKv -gt 0 -and ($i.KeyLength + $i.ValueLength) -gt 0) {
    $kvBytesPerToken = $i.Blocks * $i.HeadCountKv * ($i.KeyLength + $i.ValueLength) * $kvElemBytes
}
$kvSource = 'measured geometry'
if ($kvBytesPerToken -le 0) {
    $kvBytesPerToken = if ($CacheK -eq 'q8_0') { 26000.0 } elseif ($CacheK -eq 'q4_0') { 14000.0 } else { 49000.0 }
    $kvSource = 'fallback constant'
}
$kvPerTok = $kvBytesPerToken
$kvGB = $kvPerTok * $Ctx / 1GB
$budget = $VramGB - $overheadGB - $kvGB

# ---------------------------------------------------------------- machine-readable output
# serve-model.ps1 uses this to pick flags automatically instead of guessing.
if ($Json) {
    $jExpBudget = [math]::Max(0, $budget - $nonGB)
    $jShare = if ($expGB -gt 0) { [math]::Min(1.0, $jExpBudget / $expGB) } else { 1.0 }
    $jFits = -not ($nonGB + $kvGB -gt $VramGB - $overheadGB)
    $jNcmoe = if ($isMoe -and $expGB -gt 0) { [int][math]::Round($i.ExpertLayers * (1 - $jShare)) } else { 0 }
    $jGpu = $nonGB + $expGB * $activeExpFrac * $jShare
    $jRam = $expGB * $activeExpFrac * (1 - $jShare)
    $jMs = ($jGpu / 448.0 * 1000) + ($jRam / $DdrGBs * 1000)
    [pscustomobject]@{
        File            = (Resolve-Path $Model).Path
        Name            = [IO.Path]::GetFileName($Model)
        Arch            = $i.Arch
        Blocks          = $i.Blocks
        IsMoE           = $isMoe
        ExpertLayers    = $i.ExpertLayers
        ExpertCount     = $i.ExpertCount
        ExpertUsed      = $i.ExpertUsed
        FileGB          = [math]::Round($fileGB, 2)
        NonExpertGB     = [math]::Round($nonGB, 2)
        ExpertGB        = [math]::Round($expGB, 2)
        BytesPerTokenGB = [math]::Round($activeGB, 2)
        Bpw             = [math]::Round($i.BPW, 2)
        VramGB          = [math]::Round($VramGB, 2)
        KvGB            = [math]::Round($kvGB, 2)
        KvBytesPerToken = [int]$kvBytesPerToken
        KvSource        = $kvSource
        HeadCountKv     = $i.HeadCountKv
        KeyLength       = $i.KeyLength
        ValueLength     = $i.ValueLength
        BudgetGB        = [math]::Round($budget, 2)
        Fits            = $jFits
        FullVram        = ($jShare -ge 0.999)
        ExpertShareGpu  = [math]::Round($jShare, 3)
        SuggestedNcmoe  = $jNcmoe
        PredTps         = if ($jMs -gt 0) { [int][math]::Round(1000.0 / $jMs * $Efficiency) } else { 0 }
    } | ConvertTo-Json -Compress
    return
}

# ---------------------------------------------------------------- report
Write-Host ""
Write-Host "  $([IO.Path]::GetFileName($Model))" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("  arch            : {0}   blocks: {1}   {2}" -f $i.Arch, $i.Blocks,
    $(if ($isMoe) { "MoE: {0}/{1} experts active per token, on {2} layers" -f $i.ExpertUsed, $i.ExpertCount, $i.ExpertLayers }
      else { "dense" }))
Write-Host ("  on disk         : {0:N2} GB   ({1:N2} bpw)" -f $fileGB, $i.BPW)
Write-Host ("  non-expert      : {0:N2} GB  (attention, embeddings, norms - read for every token)" -f $nonGB)
Write-Host ("  expert weights  : {0:N2} GB  (only {1:N0}% of it is read per token)" -f $expGB, ($activeExpFrac * 100))
Write-Host ("  bytes per token : {0:N2} GB   <- the number that decides speed" -f $activeGB) -ForegroundColor Yellow
Write-Host ""

# what a dense model of the same size would read per token
Write-Host ("  for comparison: a dense model would read {0:N2} GB per token, {1:N1}x more." -f $fileGB, ($fileGB / $activeGB)) -ForegroundColor DarkGray
Write-Host ""

Write-Host ("  VRAM {0:N1} GB - {1:N1} overhead - {2:N1} KV (ctx {3}) = {4:N2} GB usable" -f $VramGB, $overheadGB, $kvGB, $Ctx, $budget) -ForegroundColor DarkGray

if ($nonGB + $kvGB -gt $VramGB - $overheadGB) {
    Write-Host "  even the non-expert part does not fit - lower -Ctx or use a smaller quant." -ForegroundColor Red
    return
}

$expBudget = [math]::Max(0, $budget - $nonGB)
$shareGpu = if ($expGB -gt 0) { [math]::Min(1.0, $expBudget / $expGB) } else { 1.0 }
$ncmoe = if ($isMoe -and $expGB -gt 0) {
    [math]::Round($i.ExpertLayers * (1 - $shareGpu))
} else { 0 }

# bandwidth model
$gpuActive = $nonGB + $expGB * $activeExpFrac * $shareGpu
$ramActive = $expGB * $activeExpFrac * (1 - $shareGpu)
$ms = ($gpuActive / 448.0 * 1000) + ($ramActive / $DdrGBs * 1000)
$tps = if ($ms -gt 0) { 1000.0 / $ms * $Efficiency } else { 0 }
$tpsGpuOnly = 1000.0 / ($gpuActive / 448.0 * 1000) * $Efficiency

Write-Host ""
if ($shareGpu -ge 0.999) {
    Write-Host ("  FIT      : 100% in VRAM - full 448 GB/s, no DDR5 in the path") -ForegroundColor Green
    Write-Host ("  expected : ~{0:N0} t/s generation" -f $tpsGpuOnly) -ForegroundColor Green
} else {
    $pct = [math]::Round($shareGpu * 100)
    Write-Host ("  SPLIT    : {0}% of the expert weights on the GPU, {1}% streamed from DDR5" -f $pct, (100 - $pct)) -ForegroundColor Yellow
    Write-Host ("  expected : ~{0:N0} t/s generation  ({1:N1} ms/token: {2:N1} ms VRAM + {3:N1} ms DDR5)" -f $tps, $ms, ($gpuActive / 448.0 * 1000), ($ramActive / $DdrGBs * 1000)) -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  suggested sweep (measure, do not trust the model):" -ForegroundColor Cyan
    $lo = [math]::Max(0, $ncmoe - 8); $hi = [math]::Min($i.ExpertLayers, $ncmoe + 8)
    Write-Host ("    .\llm-tune.ps1 -Model `"$Model`" -Mode moe -Ctx $Ctx -Values {0},{1},{2},{3},{4}" -f `
            $lo, [math]::Round($lo + ($hi - $lo) / 4), [math]::Round($lo + ($hi - $lo) / 2), [math]::Round($lo + 3 * ($hi - $lo) / 4), $hi) -ForegroundColor Cyan
    Write-Host ("    llm-server.ps1 -Model `"$Model`" -Backend cuda -Ctx $Ctx -CpuMoe {0}" -f $ncmoe) -ForegroundColor Cyan
}
Write-Host ""

