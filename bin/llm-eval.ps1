<#
.SYNOPSIS
    Run the capability suite against local models and write a scored report.

.DESCRIPTION
    For each model: start it through llm-up.ps1 (so the registry's flags are what gets measured), run
    bin\llm-eval.py against it, stop it, and save bench\eval-<key>.json. Then aggregate every result
    into bench\eval-summary.csv and bench\eval-report.md.

    The suite itself is bench\eval-suite-v1.json: 36 items over eight categories, every one graded by a
    program - exact answers for maths and logic, unit tests that are actually executed for code, regex
    predicates for instruction following, schema checks for JSON, and a hidden passphrase at three
    depths for long context. No judge model, no human reading answers.

.EXAMPLE
    llm-eval.ps1                                  # all downloaded models, ~70-90 min
    llm-eval.ps1 -Models gemma4,qwen3
    llm-eval.ps1 -Models coder36 -Only code,math
    llm-eval.ps1 -Report                          # re-aggregate what is already in bench\, run nothing
#>
[CmdletBinding()]
param(
    # [string[]] on purpose: pwsh -File x.ps1 -Models a,b hands over one string, while &x.ps1 -Models a,b hands over an array. Both must work, so the list is normalised below.
    [string]$Suite = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bench\capability-suite-v1.json'),
    [string[]]$Models = @('gemma4', 'qwen3', 'coder', 'flint', 'gptoss', 'coder36', 'qwen36', 'dsv2'),
    [string[]]$Only = @(),
    [switch]$SkipNeedle,
    [switch]$KeepRunning,
    [double]$BudgetScale = 1.0,
    [switch]$Merge,
    [switch]$Report
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$bin = Join-Path $root 'bin'
$bench = Join-Path $root 'bench'
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
if (-not $py) { throw 'no python on PATH - the grader needs it for the code items' }
$env:PYTHONIOENCODING = 'utf-8'

function Read-Registry {
    $reg = @{}
    foreach ($line in (Get-Content (Join-Path $bin 'llm-up.ps1'))) {
        if ($line -match "^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)'\s*;\s*Port\s*=\s*(\d+)\s*;\s*Alias\s*=\s*'([^']+)';\s*Ctx\s*=\s*(\d+)") {
            $reg[$Matches[1]] = @{ File = $Matches[2]; Port = [int]$Matches[3]; Alias = $Matches[4]; Ctx = [int]$Matches[5] }
        }
    }
    return $reg
}

function Stop-Models {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

$registry = Read-Registry

if (-not $Report) {
    $keys = ($Models -join ',') -split '[,\s]+' | Where-Object { $_ }
    foreach ($k in $keys) {
        if (-not $registry.ContainsKey($k)) { Write-Host "  skip $k (not in the registry)" -ForegroundColor DarkYellow; continue }
        $e = $registry[$k]
        if (-not (Test-Path (Join-Path $root "models\$($e.File)"))) {
            Write-Host "  skip $k (not downloaded)" -ForegroundColor DarkYellow; continue
        }

        Write-Host "`n  ===== $k  ($($e.Alias), ctx $($e.Ctx)) =====" -ForegroundColor Cyan
        Stop-Models
        & (Join-Path $bin 'llm-up.ps1') $k 2>&1 | Out-Null

        $up = $false
        foreach ($i in 1..60) {
            try {
                if ((Invoke-RestMethod "http://127.0.0.1:$($e.Port)/health" -TimeoutSec 2).status -eq 'ok') { $up = $true; break }
            } catch { }
            Start-Sleep -Milliseconds 500
        }
        if (-not $up) {
            Write-Host "  $k did not start - recorded as missing" -ForegroundColor Red
            continue
        }

        $out = Join-Path $bench "eval-$k.json"
        $pyArgs = @((Join-Path $bin 'llm-eval.py'), '--url', "http://127.0.0.1:$($e.Port)/v1",
                    '--alias', $e.Alias, '--ctx', $e.Ctx, '--suite', $Suite, '--out', $out)
        $onlyList = ($Only -join ',') -split '[,\s]+' | Where-Object { $_ }
        if ($onlyList) { $pyArgs += @('--only', ($onlyList -join ',')) }
        if ($SkipNeedle) { $pyArgs += '--skip-needle' }
        if ($Merge) { $pyArgs += '--merge' }
        if ($BudgetScale -ne 1.0) { $pyArgs += @('--budget-scale', $BudgetScale) }
        & $py @pyArgs
        if (-not $KeepRunning) { Stop-Models }
    }
}

# ---------------------------------------------------------------- aggregate
$files = Get-ChildItem $bench -Filter 'eval-*.json' -File | Sort-Object Name
if (-not $files) { throw "no eval-*.json in $bench - run without -Report first" }

$rows = @()
$catOrder = @('math', 'logic', 'code', 'instr', 'json', 'needle', 'tools', 'knowledge')
foreach ($f in $files) {
    $r = Get-Content $f.FullName -Raw | ConvertFrom-Json
    foreach ($c in $catOrder) {
        $v = $r.categories.$c
        if ($null -eq $v) { continue }
        $rows += [pscustomobject]@{
            model = $r.model; category = $c; n = [int]$v.n; pass = [int]$v.pass
            pct = [double]$v.pct; ci_lo = [double]$v.lo; ci_hi = [double]$v.hi
        }
    }
}
$rows | Export-Csv (Join-Path $bench 'eval-summary.csv') -NoTypeInformation -Encoding utf8

$models = $rows.model | Select-Object -Unique
Write-Host "`n=================== capability, programmatically graded ===================" -ForegroundColor Cyan
$hdr = '  {0,-9}' -f 'model'
foreach ($c in $catOrder) { $hdr += '{0,10}' -f $c }
$hdr += '{0,9}' -f 'macro'
Write-Host $hdr -ForegroundColor Gray
foreach ($m in $models) {
    $line = '  {0,-9}' -f $m
    foreach ($c in $catOrder) {
        $cell = $rows | Where-Object { $_.model -eq $m -and $_.category -eq $c } | Select-Object -First 1
        $line += if ($cell) { '{0,10}' -f "$($cell.pass)/$($cell.n)" } else { '{0,10}' -f '-' }
    }
    $r = Get-Content (Join-Path $bench "eval-$m.json") -Raw | ConvertFrom-Json
    $line += '{0,9}' -f ('{0:N1}' -f $r.macro)
    Write-Host $line
}
Write-Host "`n  summary : bench\eval-summary.csv" -ForegroundColor Green
