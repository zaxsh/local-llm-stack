<#
.SYNOPSIS
    Ask each model one question that needs a tool, and record how it answers.

.DESCRIPTION
    The capability battery scores tool use as pass/fail, but it cannot tell *how* the model called the
    tool: llama.cpp returns native `tool_calls` for some chat templates and, for others, the model
    writes a JSON object into the text. Both can be a correct answer; only the first is what an agent
    loop can consume without help.

    This sends one request per model through the registered flags and records:
      finish_reason, whether the message had tool_calls, and the call itself.

    Output: bench\tool-mode.csv

.EXAMPLE
    .\bin\llm-toolmode.ps1
    .\bin\llm-toolmode.ps1 -Models coder,gptoss
#>
[CmdletBinding()]
param([string[]]$Models = @('gemma4', 'qwen3', 'coder', 'flint', 'gptoss', 'coder36', 'qwen36'))
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$bin = Join-Path $root 'bin'

$reg = @{}
foreach ($line in (Get-Content (Join-Path $bin 'llm-up.ps1'))) {
    if ($line -match "^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)'\s*;\s*Port\s*=\s*(\d+)\s*;\s*Alias\s*=\s*'([^']+)'") {
        $reg[$Matches[1]] = @{ File = $Matches[2]; Port = [int]$Matches[3]; Alias = $Matches[4] }
    }
}

$tools = @(
    @{ type = 'function'; function = @{
        name = 'get_weather'; description = 'Current or forecast weather for a city.'
        parameters = @{ type = 'object'; properties = @{
            city = @{ type = 'string' }; when = @{ type = 'string' } }; required = @('city') } } }
)

$rows = foreach ($k in (($Models -join ',') -split '[,\s]+' | Where-Object { $_ })) {
    if (-not $reg.ContainsKey($k)) { continue }
    $e = $reg[$k]
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 700
    & (Join-Path $bin 'llm-up.ps1') $k 2>&1 | Out-Null
    $up = $false
    foreach ($i in 1..80) {
        try { if ((Invoke-RestMethod "http://127.0.0.1:$($e.Port)/health" -TimeoutSec 2).status -eq 'ok') { $up = $true; break } } catch { }
        Start-Sleep -Milliseconds 500
    }
    if (-not $up) {
        [pscustomobject]@{ model = $k; finish = 'did-not-start'; native = 'no'; call = '' }
        continue
    }
    $body = @{
        model = $e.Alias; max_tokens = 1500; temperature = 0
        tools = $tools; tool_choice = 'auto'
        messages = @(@{ role = 'user'; content = 'What is the weather in Ankara right now?' })
    } | ConvertTo-Json -Depth 10
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$($e.Port)/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 180
        $msg = $r.choices[0].message
        $finish = $r.choices[0].finish_reason
        $native = if ($msg.tool_calls) { 'yes' } else { 'no' }
        $call = if ($msg.tool_calls) {
            "$($msg.tool_calls[0].function.name)($($msg.tool_calls[0].function.arguments))"
        } elseif ([string]$msg.content -match '\{.*\}') {
            $Matches[0]
        } else {
            (([string]$msg.content) -replace '\s+', ' ').Trim()
        }
        [pscustomobject]@{ model = $k; finish = $finish; native = $native; call = ([string]$call).Substring(0, [Math]::Min(90, ([string]$call).Length)) }
    } catch {
        [pscustomobject]@{ model = $k; finish = "error: $($_.Exception.Message.Substring(0, [Math]::Min(50, $_.Exception.Message.Length)))"; native = 'no'; call = '' }
    }
}
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
$rows | Export-Csv (Join-Path $root 'bench\tool-mode.csv') -Encoding utf8
$rows | Format-Table -AutoSize
