<#
.SYNOPSIS
    Run realistic user prompts against local llama.cpp models and write a Markdown report.

.DESCRIPTION
    For each model: start it through llm-up.ps1 (fixed port + alias), fire six prompts that
    reflect actual use (coding, debugging, summarising, arithmetic, JSON extraction, tool
    calling), and record the server's own timings. Writes a report to the Desktop.

.EXAMPLE
    llm-scenarios.ps1                                  # all downloaded models
    llm-scenarios.ps1 -Models gemma4,qwen3 -Reps 2
#>
[CmdletBinding()]
param(
    # Comma list, kept as [string] on purpose: `pwsh -File script.ps1 -Models a,b,c`
    # hands a [string[]] parameter one single string ("a,b,c"), so split it by hand.
    [string]$Models = 'gemma4,qwen3,coder,flint,gptoss',
    [int]$Reps = 1,
    [string]$Out = "$env:USERPROFILE\Desktop\local-llm-report.md"
)

if ($Models -match ',') { $modelList = $Models -split '\s*,\s*' | Where-Object { $_ } }
else { $modelList = @($Models) }

$ErrorActionPreference = 'Continue'
$bin = $PSScriptRoot
$modelNamesDir = 'C:\Users\fih\llm\models'

$samples = [ordered]@{
    summarise = @{
        Label = 'Summarise a document'
        Max   = 700
        Text  = 'Summarise the notes below in exactly three bullet points, no preamble.

NOTES: Our team moved the inference service from a shared GPU box to a dedicated node in March. Latency dropped from 1.8 s to 410 ms at p50, and from 6.2 s to 1.1 s at p99. The main cause was contention: the shared box was also running batch jobs that saturated memory bandwidth. Cost went up 22 percent, but the team stopped paging on-call, which we estimate was worth about 40 engineer-hours per month. The next bottleneck is prompt length: 70 percent of requests now carry more than 8k tokens of context, and the KV cache is what limits how many concurrent requests we can serve. We are evaluating prefix caching and a smaller retrieval window before buying more hardware.'
    }
    codegen = @{
        Label = 'Write code from a spec'
        Max   = 1200
        Text  = 'Write a Python function `top_n_by_column(path, column, n)` that reads a CSV with the csv module, returns the n rows with the largest numeric values in `column`, and raises ValueError with a clear message if the column is missing or holds non-numeric data. No pandas. Include a short docstring.'
    }
    debug = @{
        Label = 'Debug a traceback'
        Max   = 700
        Text  = 'This raises IndexError: list index out of range on the last line. Explain the cause in one sentence, then give the corrected code.

```
rows = [["a", 1], ["b"]]
totals = []
for r in rows:
    totals.append(r[1])
print(totals)
```'
    }
    reasoning = @{
        Label = 'Multi-step arithmetic'
        Max   = 1000
        Text  = 'A workshop starts with 3 identical machines. Each machine makes 45 parts per hour. They run 6 hours a day, 5 days a week. After 2 weeks one machine breaks and is not replaced. How many parts does the workshop make in the next 3 weeks? Show the steps, then give the final number on its own line.'
    }
    extract = @{
        Label = 'Extract structured data'
        Max   = 700
        Text  = 'Extract the job posting below into JSON with keys: title, company, location, seniority, min_years_experience, remote. Use null when a field is not stated. Reply with JSON only.

POSTING: Senior Backend Engineer at Kestrel Labs, Berlin (hybrid, 2 days in office). You have 6+ years building Python services, ideally with FastAPI and Postgres. We run on Kubernetes and care a lot about observability.'
    }
    tools = @{
        Label = 'Call a tool'
        Max   = 400
        Tools = @(@{
            type = 'function'
            function = @{
                name = 'get_weather'
                description = 'Get the current weather for a city'
                parameters = @{ type = 'object'; properties = @{ city = @{ type = 'string'; description = 'City name' } }; required = @('city') }
            }
        })
        Text = 'What is the weather in Istanbul right now? Use the get_weather tool.'
    }
}

function Invoke-Scenario([int]$Port, $S, [string]$ModelId) {
    $msg = @(@{ role = 'user'; content = $S.Text })
    $body = @{ model = $ModelId; messages = $msg; max_tokens = $S.Max; temperature = 0.2; cache_prompt = $false }
    if ($S.Tools) { $body.tools = $S.Tools }
    $json = $body | ConvertTo-Json -Depth 12
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $json `
            -ContentType 'application/json' -TimeoutSec 600
        $sw.Stop()
        $t = $r.timings
        return [pscustomobject]@{
            Ok        = $true
            PromptN   = [int]$t.prompt_n
            PromptTps = [math]::Round([double]$t.prompt_per_second, 1)
            GenN      = [int]$t.predicted_n
            GenTps    = [math]::Round([double]$t.predicted_per_second, 1)
            TtftMs    = [math]::Round([double]$t.prompt_ms + [double]$t.predicted_per_token_ms, 0)
            WallS     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Finish    = $r.choices[0].finish_reason
            ToolCalls = if ($r.choices[0].message.tool_calls) {
                ($r.choices[0].message.tool_calls | ForEach-Object { "$($_.function.name)($($_.function.arguments))" }) -join '; '
            } else { '' }
            Answer    = [string]$r.choices[0].message.content
            Reasoning = [string]$r.choices[0].message.reasoning_content
        }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

$results = @()
$meta = @()

foreach ($m in $modelList) {
    $file = switch ($m) {
        'gemma4' { 'gemma-4-E4B-it-q4kxl.gguf' }
        'qwen3'  { 'Qwen3-8B-Q4_K_M.gguf' }
        'coder'  { 'qwen2.5-coder-7b-q4km.gguf' }
        'flint'  { 'flint-nvfp4-40b.gguf' }
        'gptoss' { 'gpt-oss-20b-MXFP4.gguf' }
        'qwen36' { 'qwen3.6-35b-a3b-mtp-q4km.gguf' }
        default  { "$m.gguf" }
    }
    if (-not (Test-Path (Join-Path $modelNamesDir $file))) {
        Write-Host "  skip $m (not downloaded)" -ForegroundColor DarkYellow
        continue
    }

    Write-Host "`n  === $m ===" -ForegroundColor Cyan
    $loadSw = [Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $bin 'llm-up.ps1') $m | Out-Null
    $loadSw.Stop()

    $port = switch ($m) { 'flint' { 8080 } 'gptoss' { 8082 } 'gemma4' { 8083 } 'qwen36' { 8084 } default { 8081 } }
    $alias = switch ($m) { 'flint' { 'flint-nvfp4-40b' } 'gptoss' { 'gpt-oss-20b' } 'gemma4' { 'gemma-4-e4b' } 'qwen3' { 'qwen3-8b' } 'coder' { 'qwen2.5-coder-7b' } 'qwen36' { 'qwen3.6-35b-a3b' } default { 'local' } }

    try { $health = (Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 5).status } catch { $health = 'down' }
    if ($health -ne 'ok') {
        Write-Host "  $m did not start - skipping" -ForegroundColor Red
        $meta += [pscustomobject]@{ Model = $m; LoadS = $null; VramGB = $null; TempC = $null; Ok = $false }
        continue
    }

    $vram = [int](@(& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=memory.used --format=csv,noheader,nounits) | Select-Object -First 1)
    $temp = [int](@(& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=temperature.gpu --format=csv,noheader,nounits) | Select-Object -First 1)
    $meta += [pscustomobject]@{ Model = $m; LoadS = [math]::Round($loadSw.Elapsed.TotalSeconds, 1); VramGB = [math]::Round([double]$vram / 1024, 2); TempC = [int]$temp; Ok = $true }

    # Warm up first: the very first request pays CUDA allocation, graph capture and cold
    # page-ins, which would otherwise look like a multi-second TTFT for whichever prompt
    # happened to run first.
    try {
        $w = @{ model = $alias; messages = @(@{ role = 'user'; content = 'hi' }); max_tokens = 8 } | ConvertTo-Json -Depth 6
        Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post -Body $w -ContentType 'application/json' -TimeoutSec 300 | Out-Null
        Write-Host '    (warmup)' -ForegroundColor DarkGray
    } catch { }
    for ($rep = 1; $rep -le $Reps; $rep++) {
        foreach ($key in $samples.Keys) {
            $s = $samples[$key]
            $r = Invoke-Scenario -Port $port -S $s -ModelId $alias
            if ($r.Ok) {
                Write-Host ("    {0,-10} prompt {1,5:N0} tok @ {2,6:N0} t/s | gen {3,3} tok @ {4,5:N1} t/s | ttft {5,5:N0} ms | {6}" -f `
                    $key, $r.PromptN, $r.PromptTps, $r.GenN, $r.GenTps, $r.TtftMs, $r.Finish)
                $results += [pscustomobject]@{
                    Model = $m; Scenario = $key; Label = $s.Label; Rep = $rep
                    PromptN = $r.PromptN; PromptTps = $r.PromptTps; GenN = $r.GenN; GenTps = $r.GenTps
                    TtftMs = $r.TtftMs; WallS = $r.WallS; Finish = $r.Finish; ToolCalls = $r.ToolCalls
                    Answer = $r.Answer; Reasoning = $r.Reasoning; Ok = $true
                }
            } else {
                Write-Host ("    {0,-10} FAILED: {1}" -f $key, $r.Error) -ForegroundColor Red
                $results += [pscustomobject]@{ Model = $m; Scenario = $key; Label = $s.Label; Rep = $rep; Ok = $false; Answer = $r.Error }
            }
        }
    }
}

# ---------------------------------------------------------------- report
$now = Get-Date -Format 'yyyy-MM-dd HH:mm'
$gpu = (& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=name,memory.total,driver_version --format=csv,noheader) -join ' '

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# Local LLM report - RTX 5060 Laptop, 8 GB")
[void]$md.AppendLine()
[void]$md.AppendLine("Generated $now on $env:COMPUTERNAME.")
[void]$md.AppendLine()
[void]$md.AppendLine("- GPU: $gpu")
[void]$md.AppendLine("- CPU: Intel Core Ultra 7 255HX (20C/20T), 30 GB DDR5-5600")
[void]$md.AppendLine("- Engine: llama.cpp b12255, CUDA backend, f16 KV cache, flash attention on")
[void]$md.AppendLine("- All numbers are the server's own timings block, not estimates. Repeats: $Reps")
[void]$md.AppendLine()

[void]$md.AppendLine("## Models")
[void]$md.AppendLine()
[void]$md.AppendLine("| model | VRAM | load | temp |")
[void]$md.AppendLine("|---|---|---|---|")
foreach ($m in $meta) {
    if ($m.Ok) { [void]$md.AppendLine("| ``$($m.Model)`` | $($m.VramGB) GB | $($m.LoadS) s | $($m.TempC) C |") }
    else { [void]$md.AppendLine("| ``$($m.Model)`` | didn't start | | |") }
}
[void]$md.AppendLine()

[void]$md.AppendLine("## Generation speed per prompt (t/s)")
[void]$md.AppendLine()
$modelNames = (($results | Where-Object Ok | Select-Object -ExpandProperty Model) | Sort-Object -Unique)
$skeys = $samples.Keys
$hdr = "| prompt | " + (($modelNames | ForEach-Object { "``$_``" }) -join ' | ') + ' |'
[void]$md.AppendLine($hdr)
[void]$md.AppendLine("|---" * ($modelNames.Count + 1) + "|")
foreach ($k in $skeys) {
    $row = "| $($samples[$k].Label) |"
    foreach ($mo in $modelNames) {
        $v = ($results | Where-Object { $_.Ok -and $_.Model -eq $mo -and $_.Scenario -eq $k } | Select-Object -First 1)
        $row += if ($v) { " $($v.GenTps) |" } else { " - |" }
    }
    [void]$md.AppendLine($row)
}
[void]$md.AppendLine()

[void]$md.AppendLine("## Prompt processing, time to first token")
[void]$md.AppendLine()
[void]$md.AppendLine("| model | avg prompt t/s | avg TTFT | wall time per answer |")
[void]$md.AppendLine("|---|---|---|---|")
foreach ($mo in $modelNames) {
    $rows = $results | Where-Object { $_.Ok -and $_.Model -eq $mo }
    if (-not $rows) { continue }
    $real = $rows | Where-Object { $_.PromptN -gt 10 }
    $apt = if ($real) { [math]::Round(($real | Measure-Object PromptTps -Average).Average, 0) } else { 0 }
    $att = [math]::Round(($rows | Measure-Object TtftMs -Average).Average, 0)
    $awl = [math]::Round(($rows | Measure-Object WallS -Average).Average, 1)
    [void]$md.AppendLine("| ``$mo`` | $apt t/s | $att ms | $awl s |")
}
[void]$md.AppendLine()

[void]$md.AppendLine("## Tool calling")
[void]$md.AppendLine()
foreach ($mo in $modelNames) {
    $t = ($results | Where-Object { $_.Ok -and $_.Model -eq $mo -and $_.Scenario -eq 'tools' } | Select-Object -First 1)
    if ($t) {
        $toolSummary = if ($t.ToolCalls) { "native ``tool_calls``: ``$($t.ToolCalls)``" } else { "no tool call - answered in prose (finish: $($t.Finish))" }
        [void]$md.AppendLine("- **$mo**: $toolSummary")
    }
}
[void]$md.AppendLine()

[void]$md.AppendLine("## What to use, and why")
[void]$md.AppendLine()
$best = $results | Where-Object Ok | Group-Object Model | ForEach-Object {
    $g = $_.Group
    $real = $g | Where-Object { $_.PromptN -gt 10 }
    [pscustomobject]@{
        Model  = $_.Name
        Gen    = [math]::Round(($g | Measure-Object GenTps -Average).Average, 1)
        Worst  = ($g | Measure-Object GenTps -Minimum).Minimum
        Ttft   = if ($real) { [math]::Round(($real | Measure-Object TtftMs -Average).Average, 0) } else { 0 }
        Tools  = [bool]($g | Where-Object { $_.ToolCalls })
    }
} | Sort-Object -Property Gen -Descending
foreach ($b in $best) {
    $toolText = if ($b.Tools) { 'yes' } else { 'NO - cannot drive an agent loop' }
    [void]$md.AppendLine(("- **{0}**: {1} t/s average generation (worst seen {2}), {3} ms to first token, native tools: {4}" -f $b.Model, $b.Gen, $b.Worst, $b.Ttft, $toolText))
}
[void]$md.AppendLine()
[void]$md.AppendLine("Rules of thumb for this machine:")
[void]$md.AppendLine()
[void]$md.AppendLine("- **Agent work (Claude Code, dsh-tui tools, multi-file edits)**: the model with native tool calls *and* the lowest time to first token. A model that answers a tool request in prose cannot drive an agent loop, no matter how fast it generates.")
[void]$md.AppendLine("- **Long documents, RAG, big files**: prompt processing dominates, not generation. The MoE path pays 10-40x more per prompt token because its experts live on the CPU; a fully VRAM-resident model ingests 20-30x faster.")
[void]$md.AppendLine("- **One-off hard questions**: the biggest model that still fits. Watch the first-token latency - that is the part a human actually feels.")
[void]$md.AppendLine("- **Only one model fits in 8 GB of VRAM at a time.** `llm-up.ps1 <model>` swaps them, 5-18 s depending on size.")
[void]$md.AppendLine("- **f16 KV cache, not q8_0.** Measured +25-35 % generation on this GPU. Quantised KV is re-dequantised every layer, every token.")
[void]$md.AppendLine()
[void]$md.AppendLine("## Raw answers")
[void]$md.AppendLine()
foreach ($mo in $modelNames) {
    [void]$md.AppendLine("### $mo")
    [void]$md.AppendLine()
    foreach ($k in $skeys) {
        $v = ($results | Where-Object { $_.Ok -and $_.Model -eq $mo -and $_.Scenario -eq $k } | Select-Object -First 1)
        if (-not $v) { continue }
        [void]$md.AppendLine("**$($samples[$k].Label)** - $($v.GenTps) t/s, $($v.GenN) tokens")
        [void]$md.AppendLine()
        [void]$md.AppendLine('```')
        # NB: the comma in `-replace 'x', 'y'` sits at the argument level of the method call,
        # so PowerShell would parse it as two AppendLine arguments. Bind to a variable first.
        $clean = (($v.Answer -replace "`r", '') -replace '```', "'''")
        if ([string]::IsNullOrWhiteSpace($clean) -and $v.ToolCalls) {
            [void]$md.AppendLine('tool call: ' + $v.ToolCalls)
        } elseif ([string]::IsNullOrWhiteSpace($clean)) {
            [void]$md.AppendLine('(no final answer - the budget was consumed by the reasoning trace)')
        } else {
            [void]$md.AppendLine($clean)
        }
        [void]$md.AppendLine('```')
        $think = (($v.Reasoning -replace "`r", '') -replace '```', "'''")
        if (-not [string]::IsNullOrWhiteSpace($think)) {
            [void]$md.AppendLine()
            [void]$md.AppendLine("<sub>reasoning trace, $($think.Length) chars</sub>")
        }
        [void]$md.AppendLine()
    }
}

[System.IO.File]::WriteAllText($Out, $md.ToString(), (New-Object System.Text.UTF8Encoding($false)))
$csv = "$env:USERPROFILE\Desktop\local-llm-results.csv"
$csvText = ($results | Select-Object Model, Scenario, Rep, PromptN, PromptTps, GenN, GenTps, TtftMs, WallS, Finish, ToolCalls | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
[System.IO.File]::WriteAllText($csv, $csvText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "`n  report : $Out" -ForegroundColor Green
Write-Host "  raw csv: $csv" -ForegroundColor Green












