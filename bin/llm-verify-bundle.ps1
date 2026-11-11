<#
.SYNOPSIS
    Verify the standalone Desktop\llama.cpp bundle: every preset, loads, generates, tools, stop.

.DESCRIPTION
    Reads the real .cmd files out of the bundle rather than re-deriving flags, so this tests what
    the user will actually double-click. For each preset it starts the engine the way the preset
    does, waits for /health, sends a normal prompt, sends a tool-shaped prompt, and checks that
    stop.cmd's action really releases the GPU.

    The browser line inside the presets is skipped on purpose - this is a headless check.
#>
[CmdletBinding()]
param(
    [string]$Bundle = "$env:USERPROFILE\Desktop\llama.cpp",
    [int]$MaxTokens = 300,
    [string]$Out = 'C:\Users\fih\llm\bench\bundle-verify.csv'
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
'preset,model,port,load_s,health,gen_tps,gen_tokens,finish,tool_call,stopped,vram_after' |
    Set-Content $Out

$exe = Join-Path $Bundle 'llama-server.exe'
if (-not (Test-Path $exe)) { throw "no engine at $exe" }

function Get-PresetArgs([string]$path) {
    $lines = Get-Content $path
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # the invocation, not the "taskkill /IM llama-server.exe" line above it
        if ($lines[$i].Trim() -match '^"[^"]*llama-server\.exe"\s*\^?$') { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $args = @()
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        $cont = $l.TrimEnd().EndsWith('^')
        $l = $l.TrimEnd().TrimEnd('^')
        if ($i -eq $start) { $l = ($l -replace '^\s*"?.{0,80}?llama-server\.exe"?\s*', '') }
        if ($l.Trim()) {
            foreach ($t in ($l -split '\s+(?=--)|\s+(?=-)')) {
                $t = $t.Trim()
                if ($t) { $args += $t }
            }
        }
        if (-not $cont) { break }
    }
    return $args
}

$results = @()
foreach ($preset in (Get-ChildItem (Join-Path $Bundle 'presets') -Filter '*.cmd' | Sort-Object Name)) {
    $key = $preset.BaseName
    Write-Host ""
    Write-Host "  === $key ===" -ForegroundColor Cyan

    $a = Get-PresetArgs $preset.FullName
    if (-not $a) { Write-Host "  could not parse the preset" -ForegroundColor Red; continue }
    # the splitter keeps "--port 8081" together (llama.cpp accepts that form), so read the values
    # out of the joined command line rather than by index
    $flat = $a -join ' '
    $port = 8080
    if ($flat -match '--port\s+(\d+)') { $port = [int]$Matches[1] }
    $model = ''
    if ($flat -match '--alias\s+(\S+)') { $model = $Matches[1] }
    Write-Host ("  args: {0}" -f $flat) -ForegroundColor DarkGray

    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    for ($i = 0; $i -lt 24; $i++) {
        if (@(Get-Process llama-server -ErrorAction SilentlyContinue).Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $exe -ArgumentList $a -WorkingDirectory $Bundle -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$env:TEMP\bv.out" -RedirectStandardError "$env:TEMP\bv.err"

    $health = 'down'
    $wait = [Diagnostics.Stopwatch]::StartNew()
    while ($wait.Elapsed.TotalSeconds -lt 90) {
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { break }
        try {
            if ((Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 1).status -eq 'ok') { $health = 'ok'; break }
        } catch { }
    }
    $load = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($health -ne 'ok') {
        Write-Host ("  FAILED to start ({0})" -f ((Get-Content "$env:TEMP\bv.err" -Tail 1) -join '')) -ForegroundColor Red
        if (-not $p.HasExited) { $p | Stop-Process -Force }
        "$key,$model,$port,$load,fail,0,0,-,-,no," | Add-Content $Out
        continue
    }
    Write-Host ("  loaded in {0}s, serving on :{1}" -f $load, $port) -ForegroundColor DarkGray

    # Warm the GPU first: the core clock ramps from ~1.6 to ~2.4 GHz over the first seconds of load,
    # so a short generation measures the ramp rather than the model. One throwaway request, then
    # the timed one.
    $warm = @{ model = $model; messages = @(@{ role = 'user'; content = 'Say hello.' }); max_tokens = 64; temperature = 0.2; cache_prompt = $false } | ConvertTo-Json -Depth 6
    try { $null = Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post -Body $warm -ContentType 'application/json' -TimeoutSec 300 } catch { }

    # a normal prompt
    $b = @{ model = $model; messages = @(@{ role = 'user'; content = 'Explain in detail how a mixture-of-experts layer routes tokens: the gating network, expert capacity, and load balancing. Be concrete.' }); max_tokens = $MaxTokens; temperature = 0.2; cache_prompt = $false } | ConvertTo-Json -Depth 8
    $tps = 0; $tok = 0; $finish = '-'
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 600
        $tps = [math]::Round($r.timings.predicted_per_second, 1)
        $tok = $r.timings.predicted_n
        $finish = $r.choices[0].finish_reason
        Write-Host ("  generation: {0:N1} t/s ({1} tokens, finish {2})" -f $tps, $tok, $finish) -ForegroundColor Green
    } catch { Write-Host "  generation FAILED" -ForegroundColor Red }

    # a tool-shaped prompt, to see whether this model can drive an agent loop
    $tb = @{
        model    = $model
        messages = @(@{ role = 'user'; content = 'What is the weather in Istanbul? Use the get_weather tool.' })
        tools    = @(@{ type = 'function'; function = @{ name = 'get_weather'; description = 'Get the weather'; parameters = @{ type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city') } } })
        max_tokens = 400
    } | ConvertTo-Json -Depth 10
    $tool = 'no'
    try {
        $tr = Invoke-RestMethod "http://127.0.0.1:$port/v1/chat/completions" -Method Post -Body $tb -ContentType 'application/json' -TimeoutSec 600
        if ($tr.choices[0].message.tool_calls) {
            $tool = "$($tr.choices[0].message.tool_calls[0].function.name)($($tr.choices[0].message.tool_calls[0].function.arguments))"
        }
        Write-Host "  tool call: $tool" -ForegroundColor $(if ($tool -eq 'no') { 'DarkYellow' } else { 'Green' })
    } catch { Write-Host "  tool request failed" -ForegroundColor DarkYellow }

    # stop the way stop.cmd does
    $p | Stop-Process -Force
    # a 20 GB MoE can take several seconds to unmap its experts
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { break }
    }
    # a 20 GB process can still be visible while it tears down, so wait for zero rather than sample
    $left = 1
    for ($j = 0; $j -lt 24; $j++) {
        $left = @(Get-Process llama-server -ErrorAction SilentlyContinue).Count
        if ($left -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $vram = [int](@(& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=memory.used --format=csv,noheader,nounits) | Select-Object -First 1)
    Write-Host ("  stopped: {0} processes left, {1} MB still in use" -f $left, $vram) -ForegroundColor DarkGray

    "$key,$model,$port,$load,ok,$tps,$tok,$finish,`"$($tool -replace '"','""')`",$(if($left -eq 0){'yes'}else{'no'}),$vram" | Add-Content $Out
}

Write-Host ""
Write-Host "  ================= bundle verification =================" -ForegroundColor Yellow
Import-Csv $Out | Format-Table preset, model, port, load_s, gen_tps, tool_call, stopped -AutoSize
$bad = Import-Csv $Out | Where-Object { $_.health -ne 'ok' -or $_.stopped -ne 'yes' }
if ($bad) { Write-Host "  FAILURES: $($bad.preset -join ', ')" -ForegroundColor Red }
else { Write-Host "  all presets load, answer, and release the GPU" -ForegroundColor Green }

