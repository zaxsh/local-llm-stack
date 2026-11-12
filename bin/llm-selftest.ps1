<#
.SYNOPSIS
    Check that this repository is internally consistent and that the launcher still builds.

.DESCRIPTION
    Nothing here needs a GPU or a model file. It is what CI runs, and what you should run after
    editing the registry, the manifest, the presets or any script:

      1. every .ps1 in bin\ parses (catches a stray quote before it reaches a user)
      2. the registry in llm-up.ps1 and models.manifest.json describe the same set of models,
         with the same filenames, and every manifest entry names a repo and a file
      3. every preset in presets\ mentions a model that exists, on the registered port, with the
         registered context, and the MCP tool catalog it advertises still fits that context
      4. llama-direct.ps1 still compiles llama-direct.exe, and the exe answers --list

    Exit code 0 means all of that held. Exit code 1 means something is broken and says what.

.EXAMPLE
    .\bin\llm-selftest.ps1
    .\bin\llm-selftest.ps1 -SkipBuild      # everything except compiling the launcher
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot
$root = Split-Path $bin -Parent
$fail = 0
$checks = 0

function Pass([string]$what) { $script:checks++; Write-Host ("  ok    {0}" -f $what) -ForegroundColor Green }
function Fail([string]$what, [string]$why) { $script:checks++; $script:fail++; Write-Host ("  FAIL  {0}" -f $what) -ForegroundColor Red; if ($why) { Write-Host ("        {0}" -f $why) -ForegroundColor Red } }
function Head([string]$what) { Write-Host ""; Write-Host ("  {0}" -f $what) -ForegroundColor Cyan }

# ------------------------------------------------------------------ 1. syntax
Head "scripts parse"
$parsed = 0
$scripts = @(Get-ChildItem $bin -Filter '*.ps1') + @(Get-ChildItem $root -Filter '*.ps1' -File)
foreach ($f in $scripts) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Fail $f.Name ("line {0}: {1}" -f $errors[0].Extent.StartLineNumber, $errors[0].Message)
    }
    else { $parsed++ }
}
if ($parsed -gt 0) { Pass "$parsed scripts (bin\ and the repository root)" }

# ------------------------------------------------------------------ 2. registry vs manifest
Head "registry and catalogue agree"
$registry = @{}
$up = Get-Content (Join-Path $bin 'llm-up.ps1') -Raw
foreach ($m in [regex]::Matches($up, "(?m)^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)';\s*Port\s*=\s*(\d+);\s*Alias\s*=\s*'([^']+)';\s*Ctx\s*=\s*(\d+);\s*CpuMoe\s*=\s*(\d+);\s*Threads\s*=\s*(\d+)(?:;\s*Note\s*=\s*'[^']*')?(?:;\s*Mcp\s*=\s*'([^']*)')?")) {
    $registry[$m.Groups[1].Value] = @{
        File = $m.Groups[2].Value; Port = [int]$m.Groups[3].Value; Alias = $m.Groups[4].Value
        Ctx = [int]$m.Groups[5].Value; CpuMoe = [int]$m.Groups[6].Value; Threads = [int]$m.Groups[7].Value
        Mcp = $(if ($m.Groups[8].Success) { $m.Groups[8].Value } else { '' })
    }
}
if ($registry.Count -eq 0) { Fail "registry" "llm-up.ps1 has no model entries - did the format change?" }
else { Pass "$($registry.Count) models in the registry" }

$manifestPath = Join-Path $root 'models.manifest.json'
$catalog = @{}
if (-not (Test-Path $manifestPath)) { Fail "models.manifest.json" "missing" }
else {
    foreach ($e in (Get-Content $manifestPath -Raw | ConvertFrom-Json).models) { $catalog[$e.key] = $e }
    Pass "$($catalog.Count) entries in models.manifest.json"
}

foreach ($k in $registry.Keys) {
    if (-not $catalog.ContainsKey($k)) { Fail "manifest entry for '$k'" "the registry has it, the catalogue does not"; continue }
    if ($catalog[$k].file -ne $registry[$k].File) {
        Fail "filename for '$k'" ("registry says '{0}', catalogue says '{1}' - llm-fetch would save a file the registry cannot find" -f $registry[$k].File, $catalog[$k].file)
    }
}
foreach ($k in $catalog.Keys) {
    if (-not $registry.ContainsKey($k)) { Fail "registry entry for '$k'" "the catalogue has it, the registry does not" }
    $e = $catalog[$k]
    if (-not $e.repo -or -not $e.repoFile) { Fail "download source for '$k'" "repo/repoFile empty - the Download button would refuse" }
    if (-not $e.sizeBytes -or [int64]$e.sizeBytes -le 0) { Fail "size for '$k'" "sizeBytes is zero" }
}
if ($catalog.Count -gt 0 -and $registry.Count -gt 0) {
    $sameNames = @($catalog.Values | Where-Object { $registry.ContainsKey($_.key) -and $registry[$_.key].File -eq $_.file }).Count
    if ($sameNames -eq $registry.Count) { Pass "every registry file is catalogued with the same name" }
}

# ------------------------------------------------------------------ 3. presets
Head "presets match the registry"
$presetDir = Join-Path $root 'presets'
if (-not (Test-Path $presetDir)) { Write-Host "  --    presets\ not present, skipped" -ForegroundColor DarkGray }
else {
    $checked = 0
    foreach ($k in $registry.Keys) {
        $p = Join-Path $presetDir "$k.cmd"
        if (-not (Test-Path $p)) { Fail "presets\$k.cmd" "missing - run bin\llm-desktop.ps1 to regenerate"; continue }
        $text = Get-Content $p -Raw
        $e = $registry[$k]
        if ($text -notmatch [regex]::Escape("models\$($e.File)")) { Fail "presets\$k.cmd model" "does not name models\$($e.File)" }
        elseif ($text -notmatch ("--port " + $e.Port)) { Fail "presets\$k.cmd port" "does not use port $($e.Port)" }
        elseif ($text -notmatch ("-c " + $e.Ctx)) { Fail "presets\$k.cmd context" "does not use context $($e.Ctx)" }
        elseif ($e.Mcp -and $text -notmatch '--mcp-servers-config') { Fail "presets\$k.cmd tools" "registry asks for '$($e.Mcp)' tools, the preset has no --mcp-servers-config" }
        elseif (-not $e.Mcp -and $text -match '--mcp-servers-config') { Fail "presets\$k.cmd tools" "the preset passes --mcp-servers-config but the registry asks for no tools" }
        else { $checked++ }
    }
    if ($checked -gt 0) { Pass "$checked presets agree with the registry" }
}

# ------------------------------------------------------------------ 3a. mcp config
Head "the MCP config is usable"
$mcpFile = Join-Path $root 'mcp\rea-mcp.json'
$wantMcp = @($registry.Keys | Where-Object { $registry[$_].Mcp })
if (-not (Test-Path $mcpFile)) {
    # Generated, and machine-specific: a clone has none until bin\llm-mcp.ps1 runs (the bundle
    # builder calls it automatically). Not a failure, but say what is missing.
    if ($wantMcp.Count) { Write-Host "  --    mcp\rea-mcp.json not generated yet - run bin\llm-mcp.ps1 (needed by: $($wantMcp -join ', '))" -ForegroundColor DarkGray }
    else { Write-Host "  --    mcp\rea-mcp.json not present, no model asks for tools" -ForegroundColor DarkGray }
}
else {
    try {
        $cfg = Get-Content $mcpFile -Raw | ConvertFrom-Json
        $server = $cfg.mcpServers.rea
        $cmd = $server.command -replace '/', '\'
        $script = @($server.args)[0] -replace '/', '\'
        if (-not $cmd) { Fail 'mcp\rea-mcp.json command' 'no mcpServers.rea.command' }
        elseif (-not (Test-Path $cmd)) { Fail 'mcp\rea-mcp.json command' "not on this machine: $cmd" }
        elseif (-not $script -or -not (Test-Path $script)) { Fail 'mcp\rea-mcp.json script' "rea entrypoint not found: $script" }
        elseif (-not $server.timeout_ms) { Fail 'mcp\rea-mcp.json timeout_ms' 'unset - the first cold-Ghidra call would be killed' }
        elseif ($server.args[1] -ne 'mcp') { Fail 'mcp\rea-mcp.json args' "expected the 'mcp' transport argument, got '$($server.args[1])'" }
        else { Pass "mcp\rea-mcp.json spawns REA (timeout $([int]($server.timeout_ms/1000)) s)" }
    } catch {
        Fail 'mcp\rea-mcp.json' "does not parse: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ 3b. the catalog fits
Head "the tool catalog fits the windows that advertise it"
# All 255 REA tools are 85 098 prompt tokens; the largest window here is 131 072, and coder36 owns
# 32 768. v1.2.0 advertised them all and every tool-using chat died with "request (85210 tokens) exceeds the available context size
# (32768 tokens)". This check is the thing that stops that from shipping again.
try {
    $fitOut = & pwsh -NoProfile -File (Join-Path $bin 'llm-ctxfit.ps1') -Check 2>&1
    $fitText = @($fitOut | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        $why = @($fitText | Where-Object { $_ -match 'FAIL' }) | Select-Object -First 1
        Fail 'catalog fits the context windows' ($why -replace '^\s*FAIL\s+', '')
    } else {
        $ok = @($fitText | Where-Object { $_ -match '^\s+ok' }) | Select-Object -First 1
        Pass (("$ok" -replace '^\s*ok\s+', '').Trim())
    }
} catch { Fail 'llm-ctxfit.ps1' $_.Exception.Message }

# ------------------------------------------------------------------ 3c. the capability suite
Head "the capability suite is well formed"
$suitePath = Join-Path $root 'bench\capability-suite-v1.json'
if (-not (Test-Path $suitePath)) { Fail 'bench\capability-suite-v1.json' 'missing - the battery cannot run' }
else {
    try {
        $suite = Get-Content $suitePath -Raw | ConvertFrom-Json
        $items = @($suite.items)
        $ids = @($items | ForEach-Object { $_.id })
        $dup = @($ids | Group-Object | Where-Object { $_.Count -gt 1 })
        $noKey = @($items | Where-Object {
            $_.kind -in @('numeric', 'choice') -and $null -eq $_.answer -and -not $_.gold
        })
        $noTests = @($items | Where-Object { $_.kind -eq 'code' -and -not $_.tests })
        $cats = @($items | ForEach-Object { $_.category } | Select-Object -Unique)
        if ($dup.Count) { Fail 'suite ids' "duplicated: $(($dup | ForEach-Object { $_.Name }) -join ', ')" }
        elseif ($noKey.Count) { Fail 'suite answers' "items with no answer: $(($noKey | ForEach-Object { $_.id }) -join ', ')" }
        elseif ($noTests.Count) { Fail 'suite tests' "code items with no tests: $(($noTests | ForEach-Object { $_.id }) -join ', ')" }
        elseif ($cats.Count -lt 8) { Fail 'suite categories' "expected 8, found $($cats.Count)" }
        else { Pass "$($items.Count) items, $($cats.Count) categories, no duplicate ids, every code item has tests" }
    } catch {
        Fail 'bench\capability-suite-v1.json' "does not parse: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ 4. the launcher builds

Head "the launcher builds"
if ($SkipBuild) { Write-Host "  --    skipped (-SkipBuild)" -ForegroundColor DarkGray }
else {
    $out = if ($OutDir) { $OutDir } else { Join-Path $env:TEMP ('selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    try {
        & pwsh -NoProfile -File (Join-Path $bin 'llm-direct.ps1') -Bundle $out -DesktopCopy (Join-Path $out 'desktop-copy.exe') *> $null
        $exe = Join-Path $out 'llama-direct.exe'
        if (-not (Test-Path $exe)) { Fail "llama-direct.exe" "llm-direct.ps1 ran but produced no exe" }
        else {
            $kb = [math]::Round((Get-Item $exe).Length / 1KB)
            if ($kb -lt 10) { Fail "llama-direct.exe" "only $kb KB - the compile probably failed softly" }
            else { Pass "built llama-direct.exe ($kb KB)" }
            # PowerShell does not capture the stdout of a Windows-subsystem exe through a pipeline,
            # so ask Start-Process to redirect it to a file and read that.
            $listOut = Join-Path $out 'list.txt'
            $p = Start-Process -FilePath $exe -ArgumentList '--list' -Wait -PassThru -NoNewWindow `
                 -RedirectStandardOutput $listOut -RedirectStandardError (Join-Path $out 'list.err')
            $listing = @(Get-Content $listOut -ErrorAction SilentlyContinue | Where-Object { $_ })
            if ($p.ExitCode -ne 0) { Fail "llama-direct.exe --list" "exit code $($p.ExitCode)" }
            elseif ($listing.Count -eq 0) { Fail "llama-direct.exe --list" "printed nothing" }
            elseif ($listing.Count -ne $registry.Count) { Fail "llama-direct.exe --list" "listed $($listing.Count) models, registry has $($registry.Count)" }
            else { Pass "--list answers for $($listing.Count) models" }
        }
    }
    catch { Fail "llm-direct.ps1" $_.Exception.Message }
    finally { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ verdict
Write-Host ""
if ($fail -eq 0) {
    Write-Host ("  PASS  {0} checks" -f $checks) -ForegroundColor Green
    exit 0
}
Write-Host ("  FAIL  {0} of {1} checks" -f $fail, $checks) -ForegroundColor Red
exit 1
