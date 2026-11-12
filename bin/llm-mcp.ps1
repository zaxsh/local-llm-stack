<#
.SYNOPSIS
    Write mcp\rea-mcp.json - the MCP server definition that llama-server spawns.

.DESCRIPTION
    llama-server takes a Cursor-compatible JSON file with --mcp-servers-config and spawns each
    listed server as a child process over stdio. REA is one of those: it publishes its tools as
    rea_* in the Web UI and on GET /tools, and llama-server respawns it on demand when a tool is
    called.

    Every path in that file is absolute, and an absolute path that has moved is the one failure
    mode that looks like "the tools are gone". So this script resolves the four moving parts on
    the current machine and rewrites the file:

        node.exe     - the Node.js that runs REA
        rea.mjs      - the installed rea-agents entrypoint (not a cache path: npx would re-download)
        JAVA_HOME    - a 64-bit JDK >= 21, used only by REA's Ghidra provider
        GHIDRA_INSTALL_DIR - the unpacked Ghidra 12.x, so REA can decompile native targets

    Anything it cannot resolve is reported and left out, instead of writing a config that fails at
    startup. Missing JDK/Ghidra is not fatal: REA still serves its tools, only the Ghidra provider
    stays unavailable (REA doctor says so).

.PARAMETER OutFile
    Where to write the config. Defaults to mcp\rea-mcp.json in this repository.

.PARAMETER Print
    Print the resolved status and the JSON, write nothing.

.PARAMETER Families
    Restrict the advertised catalog to these REA tool families. Out-of-scope tools then fail loudly
    instead of disappearing, so widen it again when a task needs another one.

.PARAMETER Full
    Advertise every REA tool (255). This is what shipped before v1.3.0 and it does not fit: the
    catalog alone is 155 093 tokens on Gemma's tokenizer, more than the 131 072 the largest preset
    can hold, and 143 270 on Qwen's. Use it only for a client that filters tools itself.

.NOTES
    Why a scope is the default: llama-server embeds the tools a chat selects into the request, so
    the catalog is a context cost every time a tool is used. Measured on this machine (2026-11-13,
    prompt tokens the server itself counted, all tools selected, bin\llm-mcptest.ps1 reproduces it):

        scope               tools   qwen3 16k   gemma4 131k
        session,enhanced       39       12 402         8 604   <- default
        direct,enhanced        56       10 607         8 191
        session,direct,enh.    80           -        14 090
        all                   255       85 098        63 800

    'session,enhanced' is the default because it is the smallest scope that can actually do the
    job in a chat: `session` carries open_binary/binary_session (without which nothing can be
    opened at all) and `enhanced` carries analyze_function, decompile_all, batch_decompile,
    binary_overview, get_call_graph, find_xrefs and the trace_* family. All 255 do not fit the
    32 768 window of coder36: that request is 85 098 tokens and dies with
    "exceeds the available context size" - the bug v1.3.0 fixes.

.EXAMPLE
    .\bin\llm-mcp.ps1                 # refresh mcp\rea-mcp.json, show what it resolved
    .\bin\llm-mcp.ps1 -Print          # just look
    .\bin\llm-mcp.ps1 -Families session,enhanced,direct   # wider, for the big models
    .\bin\llm-mcp.ps1 -OutFile D:\llama.cpp\mcp\rea-mcp.json
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$Print,

    # Restrict the advertised catalog to these REA tool families (comma list). Out-of-scope tools
    # then fail loudly instead of disappearing, so widen it again when a task needs another one.
    [string[]]$Families,

    # Advertise the complete 255-tool catalog. Measured not to fit any preset - see .NOTES.
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot
$repo = Split-Path $bin -Parent
if (-not $OutFile) { $OutFile = Join-Path (Join-Path $repo 'mcp') 'rea-mcp.json' }

function Resolve-Node {
    foreach ($cand in @($env:LLM_NODE, (Get-Command node.exe -ErrorAction SilentlyContinue).Source,
                        (Join-Path $env:USERPROFILE 'scoop\apps\nodejs\current\node.exe'),
                        "$env:ProgramFiles\nodejs\node.exe")) {
        if ($cand -and (Test-Path $cand)) { return (Resolve-Path $cand).Path }
    }
    return $null
}

function Resolve-ReaScript {
    foreach ($cand in @($env:REA_MCP_SCRIPT, $env:LLM_REA_SCRIPT)) {
        if ($cand -and (Test-Path $cand)) { return (Resolve-Path $cand).Path }
    }
    # npm root -g is authoritative when npm is on PATH, but it costs a process start.
    $roots = @()
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($npm) {
        try {
            $roots += (& $npm.Source root -g 2>$null | Where-Object { $_ -and (Test-Path $_) })
        } catch { }
    }
    $roots += @((Join-Path $env:USERPROFILE '.npm-global\node_modules'),
                (Join-Path $env:APPDATA 'npm\node_modules'))
    foreach ($r in $roots) {
        $p = Join-Path $r 'rea-agents\scripts\rea.mjs'
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    return $null
}

function Test-Jdk([string]$home_) {
    if (-not $home_) { return $null }
    $java = Join-Path $home_ 'bin\java.exe'
    $javac = Join-Path $home_ 'bin\javac.exe'
    if (-not (Test-Path $java) -or -not (Test-Path $javac)) { return $null }
    # Read the JDK's own release file first: `java -version` writes to stderr, and with
    # $ErrorActionPreference='Stop' a redirected native stderr can abort the call. The release
    # file is the same fact without a process start.
    $version = $null
    $rel = Join-Path $home_ 'release'
    if (Test-Path $rel) {
        $line = Select-String -Path $rel -Pattern '^JAVA_VERSION="([^"]+)"' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($line) { $version = $line.Matches[0].Groups[1].Value }
    }
    if (-not $version) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $v = (& $java -version 2>&1 | Where-Object { $_ -match 'version' } | Select-Object -First 1)
            if ($v) { $version = ($v.ToString() -replace '.*version\s+"?([^"\s]+)"?.*', '$1') }
        } catch { }
        finally { $ErrorActionPreference = $prev }
    }
    if (-not $version) { return $null }
    $majorText = ($version -split '\.')[0]
    if ($majorText -notmatch '^\d+$') { return $null }
    $major = [int]$majorText
    # Ghidra 12.1 accepts JDK 21 or newer; older than 21 cannot open its databases.
    if ($major -lt 21) { return $null }
    return @{ Path = (Resolve-Path $home_).Path; Version = $version; Major = $major }
}

function Resolve-Jdk {
    # JAVA_HOME is the machine's default JDK and often a newer one than Ghidra was built for, so a
    # JDK kept next to Ghidra in .toolchains wins; JAVA_HOME is only the fallback.
    $cands = @($env:LLM_JDK_HOME)
    $toolchains = Join-Path $env:USERPROFILE '.toolchains'
    if (Test-Path $toolchains) {
        $cands += (Get-ChildItem $toolchains -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(jdk-2[1-9]|jdk-[3-9]\d)' } |
            Sort-Object Name -Descending | ForEach-Object { $_.FullName })
    }
    $cands += @($env:JAVA_HOME)
    foreach ($c in $cands) {
        $ok = Test-Jdk $c
        if ($ok) { return $ok }
    }
    return $null
}

function Resolve-Ghidra {
    $cands = @($env:GHIDRA_INSTALL_DIR, $env:LLM_GHIDRA_DIR)
    $toolchains = Join-Path $env:USERPROFILE '.toolchains'
    if (Test-Path $toolchains) {
        $cands += (Get-ChildItem $toolchains -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'ghidra_*' } |
            Sort-Object Name -Descending | ForEach-Object { $_.FullName })
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c 'support\analyzeHeadless.bat'))) { return (Resolve-Path $c).Path }
    }
    return $null
}

$node = Resolve-Node
$rea = Resolve-ReaScript
$jdk = Resolve-Jdk
$ghidra = Resolve-Ghidra

Write-Host ''
if (-not $node) { throw 'node.exe not found - install Node.js or set LLM_NODE/REA_MCP_SCRIPT' }
if (-not $rea) { throw 'rea-agents is not installed - npm install -g rea-agents, or set REA_MCP_SCRIPT' }

Write-Host ("  node    {0}" -f $node) -ForegroundColor Gray
Write-Host ("  rea     {0}" -f $rea) -ForegroundColor Gray
if ($jdk) { Write-Host ("  java    {0}  ({1})" -f $jdk.Path, $jdk.Version) -ForegroundColor Gray }
else { Write-Host '  java    not found - REA runs, but its Ghidra provider will report unavailable' -ForegroundColor DarkYellow }
if ($ghidra) { Write-Host ("  ghidra  {0}" -f $ghidra) -ForegroundColor Gray }
else { Write-Host '  ghidra  not found - native decompilation stays unavailable' -ForegroundColor DarkYellow }

# Forward slashes: llama-server reads this as JSON, and a single backslash is an escape sequence.
function JsonPath([string]$p) { return ($p -replace '\\', '/') }

# The advertised catalog. 'session,enhanced' by default: the smallest scope that can open a target
# and analyze it, and the largest that still leaves qwen36 a conversation. -Full restores the old
# 255-tool behaviour and -Families takes an explicit list.
$scope = @()
if ($Full -and $Families) { throw 'pick one: -Full advertises everything, -Families narrows it' }
elseif ($Full) { $scope = @() }
elseif ($Families) { $scope = @($Families | Where-Object { $_ }) }
else { $scope = @('session', 'enhanced') }

$envBlock = [ordered]@{
    # compact keeps the advertised schemas small; the canonical result contracts are unchanged.
    REA_MCP_INPUT_SCHEMA_PROFILE = 'compact'
    REA_MCP_OUTPUT_SCHEMA_PROFILE = 'compact'
}
if ($jdk) { $envBlock['JAVA_HOME'] = JsonPath $jdk.Path }
if ($ghidra) { $envBlock['GHIDRA_INSTALL_DIR'] = JsonPath $ghidra }

# Measured on 2026-11-13 by sending every advertised tool in one request and reading the prompt
# count the server reported (bin\llm-mcptest.ps1 -Scope <name>). Worst case over the tokenizers.
$scopeCost = @{
    'session,enhanced'        = @{ Tools = 39; Tokens = 12402 }
    'direct,enhanced'         = @{ Tools = 56; Tokens = 10607 }
    'session,direct,enhanced' = @{ Tools = 80; Tokens = 16035 }
    ''                        = @{ Tools = 255; Tokens = 85098 }
}
$key = ($scope -join ',')
$cost = $scopeCost[$key]

if ($scope.Count) {
    $envBlock['REA_MCP_TOOL_FAMILIES'] = $key
    if ($cost) {
        Write-Host ("  scope   {0}  ({1} tools, {2:N0} tokens worst case)" -f $key, $cost.Tools, $cost.Tokens) -ForegroundColor Gray
    } else {
        Write-Host ("  scope   {0}  (not one of the measured scopes - run bin\llm-ctxfit.ps1)" -f $key) -ForegroundColor DarkYellow
    }
} else {
    Write-Host '  scope   all 255 tools - this does not fit any preset (see bin\llm-ctxfit.ps1)' -ForegroundColor DarkYellow
}

$config = [ordered]@{
    mcpServers = [ordered]@{
        rea = [ordered]@{
            command = JsonPath $node
            args = @((JsonPath $rea), 'mcp')
            env = $envBlock
            # per-tool-call timeout, including a cold engine start: REA allows 330 s for Ghidra
            # startup plus the operation itself. Anything shorter kills the first analysis.
            timeout_ms = 450000
        }
    }
}

$json = $config | ConvertTo-Json -Depth 8

if ($Print) {
    Write-Host ''
    Write-Host $json
    return
}

$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-Content -Path $OutFile -Value $json -Encoding utf8

# Read it back: a config that does not parse is worse than no config, because llama-server starts
# and silently exposes no tools.
$null = Get-Content $OutFile -Raw | ConvertFrom-Json
Write-Host ''
Write-Host ("  wrote {0} ({1} bytes)" -f $OutFile, (Get-Item $OutFile).Length) -ForegroundColor Green
Write-Host '  llama-server reads it with --mcp-servers-config; tools appear as rea_* on GET /tools' -ForegroundColor DarkGray
Write-Host '  check the catalog against this machine''s windows: pwsh -File bin\llm-ctxfit.ps1' -ForegroundColor DarkGray
Write-Host ''
