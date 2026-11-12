<#
.SYNOPSIS
    Does the MCP tool catalog fit the context window of every preset that advertises it?

.DESCRIPTION
    llama-server embeds the tools a chat selects into the request, so a catalog larger than a
    preset's -c is a request that fails before the model sees it:

        request (85210 tokens) exceeds the available context size (32768 tokens)

    That is what shipped before v1.3.0, and it is reproducible: every one of REA's 255 tools sent
    at once is 85 098 prompt tokens, so any chat on coder36 (32 768) died on the first message.

    The numbers below are measured, not estimated - each is the prompt-token count llama-server
    itself reported for one request carrying every tool of that scope, worst case across the
    tokenizers this project ships. bin\llm-mcptest.ps1 -Scope <name> reproduces a row.

    Modes:

        (default)   print the fit table for the scope mcp\rea-mcp.json declares
        -Table      same thing, explicitly
        -Check      the guard: exit 1 if any tool-carrying preset cannot hold its catalog with
                    half its window left. bin\llm-selftest.ps1 runs this, so CI catches the
                    regression that produced the error above.

.EXAMPLE
    pwsh -File bin\llm-ctxfit.ps1                 # the table
    pwsh -File bin\llm-ctxfit.ps1 -Check          # pass/fail, used by the self-test
    pwsh -File bin\llm-ctxfit.ps1 -Scope all      # what the old full catalog would cost
#>
[CmdletBinding()]
param(
    # Scope to evaluate. Defaults to whatever mcp\rea-mcp.json declares.
    [string]$Scope,
    # Print the table (the default; kept so the two modes read alike).
    [switch]$Table,
    # Exit 1 when a preset cannot hold its catalog with half the window left.
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot
$root = Split-Path $bin -Parent

# Measured 2026-11-13: one request, every tool of the scope selected, prompt tokens as reported by
# the server. The worst case over the tokenizers is recorded, because the check must be safe for
# the model that pays the most.
$RECORDED = [ordered]@{
    'enhanced'                = @{ Tools = 15;  Tokens = 3528 }
    'direct'                  = @{ Tools = 41;  Tokens = 7161 }
    'session'                 = @{ Tools = 24;  Tokens = 8956 }
    'direct,enhanced'         = @{ Tools = 56;  Tokens = 10607 }
    'session,enhanced'        = @{ Tools = 39;  Tokens = 12402 }
    'session,direct,enhanced' = @{ Tools = 80;  Tokens = 16035 }
    'all'                     = @{ Tools = 255; Tokens = 85098 }
}

# ---------------------------------------------------------------- the registry
$registry = [ordered]@{}
$up = Get-Content (Join-Path $bin 'llm-up.ps1') -Raw
foreach ($m in [regex]::Matches($up, "(?m)^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)';\s*Port\s*=\s*(\d+);\s*Alias\s*=\s*'([^']+)';\s*Ctx\s*=\s*(\d+);\s*CpuMoe\s*=\s*(\d+);\s*Threads\s*=\s*(\d+)(?:;\s*Note\s*=\s*'[^']*')?(?:;\s*Mcp\s*=\s*'([^']*)')?")) {
    $registry[$m.Groups[1].Value] = @{
        File = $m.Groups[2].Value; Ctx = [int]$m.Groups[5].Value
        Mcp  = $(if ($m.Groups[8].Success) { $m.Groups[8].Value } else { '' })
    }
}
if ($registry.Count -eq 0) { throw 'llm-up.ps1 has no model entries - did the registry format change?' }

# ---------------------------------------------------------------- the declared scope
if (-not $Scope) {
    $cfgPath = Join-Path $root 'mcp\rea-mcp.json'
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $Scope = $cfg.mcpServers.rea.env.REA_MCP_TOOL_FAMILIES
        } catch { $Scope = $null }
        if (-not $Scope) { $Scope = 'all' }   # absent field = every tool advertised
    } else {
        # No config on this machine (a fresh clone, or CI): judge the scope bin\llm-mcp.ps1 would
        # write by default, because that is what a user gets after the bundle is built.
        $Scope = 'session,enhanced'
    }
}
$key = ($Scope -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ','
if (-not $key) { $key = 'all' }

# ---------------------------------------------------------------- report
function Get-Verdict([int]$cost, [int]$ctx) {
    if ($cost -ge $ctx) { return @{ Name = 'OVER'; Why = "the request fails before the model reads it" } }
    if ($cost * 2 -gt $ctx) { return @{ Name = 'TIGHT'; Why = "leaves $($ctx - $cost) tokens for the conversation" } }
    return @{ Name = 'FIT'; Why = "$([math]::Round(100.0 * $cost / $ctx))% of the window" }
}

function Show-Table($rows, [string]$scopeKey) {
    Write-Host ''
    Write-Host ("  scope: {0}   measured 2026-11-13, every tool selected" -f $scopeKey) -ForegroundColor Gray
    Write-Host ''
    Write-Host ('  {0,-8} {1,-38} {2,7} {3,7} {4,8}  {5}' -f 'preset', 'model', 'ctx', 'tools', 'tokens', 'verdict')
    Write-Host ('  {0,-8} {1,-38} {2,7} {3,7} {4,8}  {5}' -f ('-' * 8), ('-' * 38), ('-' * 7), ('-' * 7), ('-' * 8), ('-' * 44))
    foreach ($r in $rows) {
        $colour = switch ($r.Verdict.Name) { 'OVER' { 'Red' } 'TIGHT' { 'DarkYellow' } default { 'Green' } }
        Write-Host ('  {0,-8} {1,-38} {2,7} {3,7} {4,8}  ' -f $r.Preset, $r.Model, $r.Ctx, $r.Tools, $r.Tokens) -NoNewline
        Write-Host ('{0,-6} {1}' -f $r.Verdict.Name, $r.Verdict.Why) -ForegroundColor $colour
    }
    Write-Host ''
}

$toolPresets = @($registry.Keys | Where-Object { $registry[$_].Mcp })
if (-not $toolPresets.Count) {
    Write-Host '  no preset advertises tools - nothing to check' -ForegroundColor DarkGray
    return
}

if (-not $RECORDED.Contains($key)) {
    $msg = "scope '{0}' has no measured cost. Measure it: pwsh -File bin\llm-mcptest.ps1 -Model gemma4 -Scope {0}" -f $key
    if ($Check) { Write-Host "  FAIL  $msg" -ForegroundColor Red; exit 1 }
    Write-Host "  $msg" -ForegroundColor DarkYellow
    return
}
$rec = $RECORDED[$key]

$rows = foreach ($p in $toolPresets) {
    @{ Preset = $p; Model = $registry[$p].File; Ctx = $registry[$p].Ctx; Tools = $rec.Tools; Tokens = $rec.Tokens
       Verdict = (Get-Verdict $rec.Tokens $registry[$p].Ctx) }
}

# ---------------------------------------------------------------- -Check
if ($Check) {
    $bad = @($rows | Where-Object { $_.Verdict.Name -eq 'OVER' })
    if ($bad.Count) {
        foreach ($b in $bad) {
            Write-Host ("  FAIL  {0}: {1} tools cost {2:N0} tokens, its window is {3:N0}" -f $b.Preset, $rec.Tools, $rec.Tokens, $b.Ctx) -ForegroundColor Red
        }
        exit 1
    }
    Write-Host ("  ok    scope '{0}' ({1} tools, {2:N0} tokens) fits all {3} tool presets" -f $key, $rec.Tools, $rec.Tokens, $toolPresets.Count) -ForegroundColor Green
    return
}

Show-Table $rows $key
