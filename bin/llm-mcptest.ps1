<#
.SYNOPSIS
    Start one model with the MCP tools and prove that a chat using every advertised tool fits.

.DESCRIPTION
    The failure this exists for: a chat that selects tools sends their schemas with the request, and
    v1.2.0 advertised all 255 REA tools. That is 85 098 prompt tokens of JSON before the user types
    anything, so every tool-using request on coder36 (32 768) died with

        request (85210 tokens) exceeds the available context size (32768 tokens), try increasing it

    This starts the real preset, asks the server which tools it advertises, then sends one chat that
    carries *all* of them - the worst case a user can create from the Web UI's tool picker - and
    reports the prompt size the server actually counted, against the window it started with.

    It leaves nothing running: the model is stopped at the end unless -Keep is given.

.PARAMETER Model
    Registry key: gemma4, flint, qwen3, qwen36, coder36. The two models without native tool calls
    (coder, gptoss) are refused, because they cannot answer with tool_calls.

.EXAMPLE
    pwsh -File bin\llm-mcptest.ps1                 # gemma4, the default model
    pwsh -File bin\llm-mcptest.ps1 -Model qwen3    # the tightest window: 16 384
#>
[CmdletBinding()]
param(
    [string]$Model = 'gemma4',
    # Rewrite mcp\rea-mcp.json for this scope before starting: 'enhanced', 'direct', a list such as
    # 'direct,enhanced', or 'all' for the full 255-tool catalog. Without it the file is left alone.
    [string]$Scope,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot
$root = Split-Path $bin -Parent

# ---------------------------------------------------------------- registry
$registry = [ordered]@{}
$up = Get-Content (Join-Path $bin 'llm-up.ps1') -Raw
foreach ($m in [regex]::Matches($up, "(?m)^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)';\s*Port\s*=\s*(\d+);\s*Alias\s*=\s*'([^']+)';\s*Ctx\s*=\s*(\d+);\s*CpuMoe\s*=\s*(\d+);\s*Threads\s*=\s*(\d+)(?:;\s*Note\s*=\s*'[^']*')?(?:;\s*Mcp\s*=\s*'([^']*)')?")) {
    $registry[$m.Groups[1].Value] = @{
        File = $m.Groups[2].Value; Port = [int]$m.Groups[3].Value; Alias = $m.Groups[4].Value
        Ctx  = [int]$m.Groups[5].Value
        Mcp  = $(if ($m.Groups[8].Success) { $m.Groups[8].Value } else { '' })
    }
}
if (-not $registry.Contains($Model)) { throw "no registry entry '$Model'. Have: $($registry.Keys -join ', ')" }
$e = $registry[$Model]
if (-not $e.Mcp) { throw "'$Model' has no native tool calls (registry Mcp is empty) - it cannot answer with tool_calls" }

$base = "http://127.0.0.1:$($e.Port)"
Write-Host ''
Write-Host ("  {0}  {1}  ctx {2:N0}  {3}" -f $Model, $e.Alias, $e.Ctx, $base) -ForegroundColor Gray

# A requested scope is written first: llama-server reads the config once, at startup.
if ($Scope) {
    if ($Scope -eq 'all') { & pwsh -NoProfile -File (Join-Path $bin 'llm-mcp.ps1') -Full *> $null }
    else { & pwsh -NoProfile -File (Join-Path $bin 'llm-mcp.ps1') -Families $Scope *> $null }
    Write-Host ("  scope        {0}" -f $Scope) -ForegroundColor Gray
}

# ---------------------------------------------------------------- which tools does it advertise
function Get-AdvertisedTools {
    $r = Invoke-RestMethod -Uri "$base/tools" -TimeoutSec 20
    if ($r -is [array]) { return $r }
    foreach ($p in @('tools', 'data', 'result')) { if ($r.$p) { return @($r.$p) } }
    return @()
}

function ConvertTo-OpenAiTool($t) {
    # GET /tools returns llama-server's own descriptors: { display_name, tool, type, permissions,
    # definition: { type: "function", function: { name, description, parameters } } }. The chat
    # endpoint wants exactly that inner object, so pass it through rather than rebuilding it - a
    # rebuilt copy loses the name and the server rejects the request with "type must be string".
    if ($t.definition) { return $t.definition }
    $params = $t.inputSchema
    if (-not $params -and $t.input_schema) { $params = $t.input_schema }
    if (-not $params) { $params = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} } }
    return [pscustomobject]@{
        type     = 'function'
        function = [pscustomobject]@{
            name        = "$($t.name)"
            description = "$($t.description)"
            parameters  = $params
        }
    }
}

Write-Host '  starting...' -NoNewline
& pwsh -NoProfile -File (Join-Path $bin 'llm-up.ps1') $Model *> $null
$deadline = (Get-Date).AddSeconds(180)
$healthy = $false
while ((Get-Date) -lt $deadline) {
    try {
        $h = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 3
        if ($h.status -eq 'ok' -or $h -eq 'ok') { $healthy = $true; break }
    } catch { }
    Write-Host '.' -NoNewline
    Start-Sleep -Seconds 2
}
Write-Host ''
if (-not $healthy) { throw "the server did not report healthy within 180 s on $base" }

try {
    $tools = @(Get-AdvertisedTools)
    if (-not $tools.Count) { throw 'the server advertises no tools - is mcp\rea-mcp.json written? (bin\llm-mcp.ps1)' }
    Write-Host ("  advertised   {0} tools" -f $tools.Count) -ForegroundColor Gray

    # The worst case the Web UI allows: every advertised tool selected at once.
    $oai = @($tools | ForEach-Object { ConvertTo-OpenAiTool $_ })
    $plain = [pscustomobject]@{
        model      = $e.Alias
        messages   = @([pscustomobject]@{ role = 'user'; content = 'In one sentence, what does this project measure?' })
        max_tokens = 1
        stream     = $false
    } | ConvertTo-Json -Depth 30 -Compress
    $body = [pscustomobject]@{
        model       = $e.Alias
        messages    = @([pscustomobject]@{ role = 'user'; content = 'In one sentence, what does this project measure?' })
        tools       = $oai
        tool_choice = 'auto'
        max_tokens  = 64
        stream      = $false
    } | ConvertTo-Json -Depth 30 -Compress

    # What the tools themselves cost: the same request with and without them. This is the number
    # that has to fit, and it is smaller than raw tools/list bytes - the chat template renders the
    # schemas more compactly than the JSON the MCP server sends.
    $baseline = 0
    try {
        $r0 = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Method Post -Body $plain `
              -ContentType 'application/json' -TimeoutSec 600
        $baseline = [int]$r0.usage.prompt_tokens
    } catch { }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $res = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Method Post -Body $body `
               -ContentType 'application/json' -TimeoutSec 600
    } catch {
        $detail = ''
        try { $detail = $_.ErrorDetails.Message } catch { }
        if (-not $detail) { $detail = $_.Exception.Message }
        Write-Host ("  FAIL  {0}" -f (($detail -replace '\s+', ' ').Trim())) -ForegroundColor Red
        exit 1
    }
    $sw.Stop()

    $p = [int]$res.usage.prompt_tokens
    $c = [int]$res.usage.completion_tokens
    $free = $e.Ctx - $p
    $colour = if ($free -lt 2048) { 'Red' } elseif ($free -lt ($e.Ctx / 2)) { 'DarkYellow' } else { 'Green' }
    Write-Host ''
    Write-Host ('  tools sent   {0}' -f $oai.Count) -ForegroundColor Gray
    if ($baseline) { Write-Host ('  the tools    {0:N0} tokens ({1:N0} without them)' -f ($p - $baseline), $baseline) -ForegroundColor Gray }
    Write-Host ('  prompt       {0:N0} tokens of {1:N0}  ({2:N0} left for the chat)' -f $p, $e.Ctx, $free) -ForegroundColor $colour
    Write-Host ('  reply        {0} tokens, {1:N1} s, finish_reason={2}' -f $c, $sw.Elapsed.TotalSeconds, $res.choices[0].finish_reason) -ForegroundColor Gray
    if ($free -lt 0) { Write-Host '  FAIL  the request would not have fit' -ForegroundColor Red; exit 1 }
    Write-Host ("  PASS  all {0} advertised tools fit in {1}'s window" -f $oai.Count, $Model) -ForegroundColor Green

    # Fitting is necessary, not sufficient: the scope must still contain a tool worth calling, and
    # the server must still be able to run it. Force one call, then execute it through POST /tools.
    $pick = @($oai | Where-Object { $_.function.name -eq 'rea_binary_session' })
    if (-not $pick.Count) { Write-Host '  --    no rea_binary_session in this scope, call not proven' -ForegroundColor DarkYellow; return }
    $callBody = [pscustomobject]@{
        model       = $e.Alias
        messages    = @([pscustomobject]@{ role = 'user'; content = 'Report the analysis session status.' })
        tools       = @($pick)
        tool_choice = [pscustomobject]@{ type = 'function'; function = [pscustomobject]@{ name = 'rea_binary_session' } }
        # Generous on purpose: qwen36 and coder36 reason before they answer, and a 64-token cap
        # stopped them mid-thought with finish_reason=length and no call at all.
        max_tokens  = 512
        stream      = $false
    } | ConvertTo-Json -Depth 30 -Compress
    $c1 = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Method Post -Body $callBody `
          -ContentType 'application/json' -TimeoutSec 600
    $call = @($c1.choices[0].message.tool_calls | Where-Object { $_.function })
    if (-not $call.Count) {
        Write-Host ("  FAIL  the model did not emit a tool call (finish_reason={0})" -f $c1.choices[0].finish_reason) -ForegroundColor Red
        exit 1
    }
    Write-Host ("  native call  {0}({1})" -f $call[0].function.name, $call[0].function.arguments) -ForegroundColor Gray

    $execBody = [pscustomobject]@{ tool = $call[0].function.name; arguments = ($call[0].function.arguments | ConvertFrom-Json) } |
                ConvertTo-Json -Depth 20 -Compress
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    $ran = Invoke-RestMethod -Uri "$base/tools" -Method Post -Body $execBody -ContentType 'application/json' -TimeoutSec 600
    $sw2.Stop()
    $text = ($ran | ConvertTo-Json -Depth 6 -Compress)
    if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '...' }
    Write-Host ("  executed     {0:N1} s  {1}" -f $sw2.Elapsed.TotalSeconds, $text) -ForegroundColor Gray
    Write-Host '  PASS  the tool ran server-side' -ForegroundColor Green
}
finally {
    if (-not $Keep) {
        & pwsh -NoProfile -File (Join-Path $bin 'llm-up.ps1') -Stop *> $null
        Write-Host '  stopped, GPU released' -ForegroundColor DarkGray
    }
}
