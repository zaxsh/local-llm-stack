<#
.SYNOPSIS
    Measure whether speculative decoding actually helps on this machine, per model.

.DESCRIPTION
    Runs the same prompts three times - with speculation off, with the model's own MTP head
    (draft-mtp), and with n-gram speculation (ngram-cache) - and reports generation speed for
    each. Speculation is only a win when the model guesses its own next tokens correctly; on a
    creative prompt it can be slower than plain decoding, so this measures instead of assuming.

    Uses the server's own `timings` block, which excludes model loading and HTTP overhead.

.PARAMETER Model
    Anything serve-model.ps1 accepts.

.EXAMPLE
    .\llm-speccmp.ps1 -Model qwen3.6:35b-a3b-mtp-q4_K_M
    .\llm-speccmp.ps1 -Model gemma4 -Modes none,draft-mtp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Model,
    [int]$Port = 8099,
    [int]$Ctx = 16384,
    [int]$CpuMoe = -1,
    [string[]]$Modes = @('none', 'draft-mtp', 'ngram-cache'),
    [int]$MaxTokens = 500,
    [int]$Runs = 2
)

$ErrorActionPreference = 'Stop'
# `pwsh -File x.ps1 -Modes a,b` collapses the list into one space-joined string, so split on
# whatever separator survived.
$Modes = @($Modes -split '[,\s]+' | Where-Object { $_ })
$bin = $PSScriptRoot
$serve = Join-Path $bin 'serve-model.ps1'

# Two prompts with very different predictability. n-gram speculation feeds on the first kind and
# starves on the second, which is exactly the trade-off worth seeing.
$prompts = @(
    @{
        name  = 'code (repetitive)'
        text  = 'Write a Python function that prints the numbers 1 to 200, one per line, using a for loop with a comment on each line explaining what happens.'
    },
    @{
        name  = 'prose (creative)'
        text  = 'Describe in two paragraphs, in your own words, why a laptop has two kinds of memory and what that means for running a language model locally.'
    }
)

function Invoke-Chat([string]$text) {
    $body = @{
        messages    = @(@{ role = 'user'; content = $text })
        max_tokens  = $MaxTokens
        temperature = 0.2
        cache_prompt = $false
    } | ConvertTo-Json -Depth 8
    $r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 900
    return $r
}

$results = @()
foreach ($mode in $Modes) {
    Write-Host ""
    Write-Host "  === $mode ===" -ForegroundColor Cyan
    $specArg = if ($mode -eq 'none') { @() } else { @('-SpecType', $mode) }
    $args = @('-NoProfile', '-File', $serve, '-Model', $Model, '-Port', "$Port", '-Ctx', "$Ctx", '-CpuMoe', "$CpuMoe") + $specArg
    $p = Start-Process pwsh -ArgumentList $args -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$env:TEMP\speccmp.out" -RedirectStandardError "$env:TEMP\speccmp.err"
    $up = $false
    for ($i = 0; $i -lt 200; $i++) {
        Start-Sleep -Milliseconds 700
        try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2).status -eq 'ok') { $up = $true; break } } catch { }
    }
    if (-not $up) {
        Write-Host "  could not start the model with $mode - skipping" -ForegroundColor Red
        Get-Content "$env:TEMP\speccmp.err" -Tail 6 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        & $serve -Stop | Out-Null
        continue
    }

    foreach ($pr in $prompts) {
        $null = Invoke-Chat 'hi'      # warm the graph; the first call is always slow
        for ($run = 1; $run -le $Runs; $run++) {
            $r = Invoke-Chat $pr.text
            $t = $r.timings
            $results += [pscustomobject]@{
                Mode      = $mode
                Prompt    = $pr.name
                GenTps    = [math]::Round($t.predicted_per_second, 1)
                Tokens    = $t.predicted_n
                PrefillTps = [math]::Round($t.prompt_per_second, 1)
                DraftN    = if ($t.PSObject.Properties.Name -contains 'draft_n') { $t.draft_n } else { 0 }
                Accepted  = if ($t.PSObject.Properties.Name -contains 'draft_n_accepted') { $t.draft_n_accepted } else { 0 }
            }
            Write-Host ("    {0,-20} run {1}: {2,5:N1} t/s  ({3} tok)" -f $pr.name, $run, $t.predicted_per_second, $t.predicted_n) -ForegroundColor DarkGray
        }
    }
    & $serve -Stop | Out-Null
}

Write-Host ""
Write-Host "  ================ generation speed by mode ================" -ForegroundColor Yellow
$results | Group-Object Mode, Prompt | ForEach-Object {
    $g = $_.Group
    $draftN = ($g | Measure-Object DraftN -Average).Average
    $accN = ($g | Measure-Object Accepted -Average).Average
    [pscustomobject]@{
        Mode       = $g[0].Mode
        Prompt     = $g[0].Prompt
        AvgTps     = [math]::Round(($g | Measure-Object GenTps -Average).Average, 1)
        MinTps     = ($g | Measure-Object GenTps -Minimum).Minimum
        MaxTps     = ($g | Measure-Object GenTps -Maximum).Maximum
        AcceptRate = if ($draftN -gt 0) { "$([math]::Round($accN / $draftN * 100))%" } else { '-' }
    }
} | Sort-Object Prompt, Mode | Format-Table -AutoSize

$baseline = $results | Where-Object Mode -eq 'none' | Group-Object Prompt
foreach ($b in $baseline) {
    $base = ($b.Group | Measure-Object GenTps -Average).Average
    foreach ($m in ($Modes | Where-Object { $_ -ne 'none' })) {
        $other = $results | Where-Object { $_.Mode -eq $m -and $_.Prompt -eq $b.Name }
        if ($other) {
            $v = ($other | Measure-Object GenTps -Average).Average
            $delta = ($v - $base) / $base * 100
            $color = if ($delta -gt 5) { 'Green' } elseif ($delta -lt -5) { 'Red' } else { 'DarkGray' }
            Write-Host ("  {0,-20} {1,-14} {2,7:N1} %" -f $b.Name, $m, $delta) -ForegroundColor $color
        }
    }
}
Write-Host ""
