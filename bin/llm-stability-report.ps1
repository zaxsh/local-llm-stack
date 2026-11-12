<#
.SYNOPSIS
    Rebuild the stability table from bench\stability-at-depth.csv - no GPU, no model load.

.DESCRIPTION
    llm-stability.ps1 writes one row per measurement. This reads those rows back and prints the
    table that goes into README.md section 14, so the documents never carry a hand-typed number.

    Speed at depth is compared against the *midpoint* of the two empty-window bookends
    (before and after the deep work), not against a single one. This laptop throttles: the same
    512-token request measured 41.7 t/s before and 34.9 t/s after qwen36's deep runs, and 81.5 ->
    88.0 t/s for gemma4. Comparing a deep run to whichever bookend happens to be colder invents a
    speed loss (or a speed gain) that has nothing to do with context length.

    Verdict against that midpoint: kept >= 90 %, softened 75-90 %, collapsed < 75 %.

.EXAMPLE
    .\llm-stability-report.ps1
    .\llm-stability-report.ps1 -Out ..\bench\stability-at-depth.csv -Markdown
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bench\stability-at-depth.csv'),
    [string]$JsonOut = '',
    [switch]$Markdown
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Out)) { throw "no measurements at $Out - run .\llm-stability.ps1 first" }

function Get-Median($values) {
    $v = @($values | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($v.Count -eq 0) { return 0 }
    if ($v.Count % 2) { return [math]::Round($v[[int](($v.Count - 1) / 2)], 1) }
    return [math]::Round((($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2), 1)
}

$rows = Import-Csv $Out
if (-not $rows) { throw "$Out has no rows" }

$report = @()
foreach ($group in ($rows | Group-Object key)) {
    $pre = Get-Median @($group.Group | Where-Object { $_.label -match '^shallow-r\d+$' } | ForEach-Object { [double]$_.pred_tps })
    $post = Get-Median @($group.Group | Where-Object { $_.label -match '^shallow-post\d+$' } | ForEach-Object { [double]$_.pred_tps })
    $mid = if ($pre -gt 0 -and $post -gt 0) { [math]::Round(($pre + $post) / 2, 1) } elseif ($pre -gt 0) { $pre } else { $post }
    $drift = if ($pre -gt 0 -and $post -gt 0) { [math]::Round(($post - $pre) / $pre * 100, 1) } else { 0 }

    $depths = @()
    foreach ($d in ($group.Group | Where-Object { $_.label -like 'depth-*' } | Sort-Object { [int]$_.depth_tokens })) {
        $pct = if ($mid -gt 0) { [math]::Round([double]$d.pred_tps / $mid * 100, 1) } else { 0 }
        $depths += [pscustomobject]@{
            label   = $d.label
            tokens  = [int]$d.depth_tokens
            tps     = [double]$d.pred_tps
            prefill = [double]$d.prompt_tps
            pct     = $pct
            verdict = if ($pct -ge 90) { 'kept' } elseif ($pct -ge 75) { 'softened' } else { 'collapsed' }
        }
    }

    $report += [pscustomobject]@{
        key     = $group.Name
        model   = $group.Group[0].model
        window  = [int]$group.Group[0].window
        shallow = $mid
        pre     = $pre
        post    = $post
        drift   = $drift
        depths  = $depths
        verdict = ($depths | ForEach-Object { $_.verdict }) -join '/'
    }
}

if ($Markdown) {
    "| model | window | empty (512) | 25 % of window | 60 % of window | clock drift | verdict |"
    "|---|---|---|---|---|---|---|"
    # Fastest first: the table is a ranking of what survives depth, and it should read that way.
    foreach ($r in ($report | Sort-Object -Property @{ Expression = 'shallow'; Descending = $true })) {
        $cells = @()
        foreach ($d in $r.depths) {
            $cells += ("{0} tok -> **{1:N1}** t/s ({2:N0} %)" -f $d.tokens, $d.tps, $d.pct)
        }
        while ($cells.Count -lt 2) { $cells += '-' }
        ("| {0} | {1} | {2:N1} t/s | {3} | {4} | {5:+0;-0} % | {6} |" -f
            $r.key, $r.window, $r.shallow, $cells[0], $cells[1], $r.drift, $r.verdict).Replace(',', '.')
    }
} else {
    foreach ($r in $report) {
        ""
        "{0}  window {1}  empty {2:N1} t/s (drift {3:+0;-0}%)  -> {4}" -f $r.key, $r.window, $r.shallow, $r.drift, $r.verdict
        foreach ($d in $r.depths) {
            "    {0,-11} {1,6} tok  {2,6:N1} t/s  {3,5:N1}%  prefill {4:N0} t/s  {5}" -f
                $d.label, $d.tokens, $d.tps, $d.pct, $d.prefill, $d.verdict
        }
    }
}

if ($JsonOut) {
    $report | ConvertTo-Json -Depth 5 | Set-Content $JsonOut
    "wrote $JsonOut"
}
