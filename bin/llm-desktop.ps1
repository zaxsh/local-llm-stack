<#
.SYNOPSIS
    Build a self-contained llama.cpp folder on the Desktop: binaries, our models, our presets.

.DESCRIPTION
    Copies the working CUDA build to Desktop\llama.cpp, hard-links every model in llm\models into
    its models\ subfolder (no extra disk - the bytes are shared), and writes one double-clickable
    preset per model with the flags measured on this machine.

    Re-running it is safe: binaries are only copied when missing or changed, and the presets are
    regenerated from the llm-up.ps1 registry, so they never drift from the tuned values.

.PARAMETER Destination
    Where to build it. Defaults to Desktop\llama.cpp.

.PARAMETER SkipBinaries
    Only refresh the presets and links, leave the copied engine alone.

.EXAMPLE
    .\llm-desktop.ps1
    .\llm-desktop.ps1 -Destination D:\llama.cpp
#>
[CmdletBinding()]
param(
    [string]$Destination = "$env:USERPROFILE\Desktop\llama.cpp",
    [switch]$SkipBinaries,
    # left empty so the defaults follow the repository instead of one machine's layout
    [string]$Build,
    [string]$SourceModels
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot
$repo = Split-Path $bin -Parent

# Defaults are relative to this repository, so a clone in any folder works. Override -Build to use
# a different llama.cpp build (cpu / vulkan / openvino) or -SourceModels to read GGUFs from elsewhere.
if (-not $Build) {
    foreach ($cand in @((Join-Path $repo 'llama.cpp\b12255\cuda'),
                        (Join-Path $repo 'llama.cpp\b12255\vulkan'),
                        (Join-Path $repo 'llama.cpp\b12255\cpu'))) {
        if (Test-Path (Join-Path $cand 'llama-server.exe')) { $Build = $cand; break }
    }
    if (-not $Build) { $Build = Join-Path $repo 'llama.cpp\b12255\cuda' }
}
if (-not $SourceModels) { $SourceModels = Join-Path $repo 'models' }

Write-Host ""
Write-Host "  building $Destination" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'models') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'presets') | Out-Null

# ---------------------------------------------------------------- engine
if (-not $SkipBinaries) {
    $files = Get-ChildItem $Build -File
    $copied = 0; $skipped = 0
    foreach ($f in $files) {
        $dest = Join-Path $Destination $f.Name
        if ((Test-Path $dest) -and (Get-Item $dest).Length -eq $f.Length) { $skipped++; continue }
        Copy-Item $f.FullName $dest -Force
        $copied++
    }
    Write-Host ("  engine: {0} files copied, {1} already current ({2:N0} MB)" -f $copied, $skipped,
        ((Get-ChildItem $Destination -File | Measure-Object Length -Sum).Sum / 1MB)) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- models
# Hard links, not copies: same bytes, no second 20 GB on disk, and the data survives even if the
# original in llm\models is deleted (both names point at one file).
$linked = 0
foreach ($f in Get-ChildItem $SourceModels -Filter '*.gguf' -File) {
    # vision projectors are companions, not chattable models - skip them
    if ($f.Name -match 'mmproj') { continue }
    $dest = Join-Path (Join-Path $Destination 'models') $f.Name
    if (-not (Test-Path $dest)) {
        New-Item -ItemType HardLink -Path $dest -Target $f.FullName -Force | Out-Null
        $linked++
    }
}
Write-Host "  models: $linked linked, $((Get-ChildItem (Join-Path $Destination 'models') -Filter '*.gguf').Count) present" -ForegroundColor DarkGray

# ---------------------------------------------------------------- fetch
# The launcher's Download button calls this. It needs the script and the catalogue together, inside
# the bundle, so the folder keeps working after it is copied somewhere else.
$fetchDir = Join-Path $Destination 'fetch'
New-Item -ItemType Directory -Force -Path $fetchDir | Out-Null
Copy-Item (Join-Path $bin 'llm-fetch.ps1') $fetchDir -Force
$manifestSrc = Join-Path $bin '..\models.manifest.json'
if (Test-Path $manifestSrc) { Copy-Item $manifestSrc (Join-Path $fetchDir 'models.manifest.json') -Force }
Write-Host "  fetch: llm-fetch.ps1 + models.manifest.json" -ForegroundColor DarkGray

# ---------------------------------------------------------------- presets
# The registry in llm-up.ps1 is the single source of truth for ports, aliases, context and the
# measured -n-cpu-moe / thread values.
$up = Get-Content (Join-Path $bin 'llm-up.ps1') -Raw
$entries = [ordered]@{}
foreach ($m in [regex]::Matches($up, "(?m)^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)';\s*Port\s*=\s*(\d+);\s*Alias\s*=\s*'([^']+)';\s*Ctx\s*=\s*(\d+);\s*CpuMoe\s*=\s*(\d+);\s*Threads\s*=\s*(\d+)")) {
    $entries[$m.Groups[1].Value] = @{
        File = $m.Groups[2].Value; Port = $m.Groups[3].Value; Alias = $m.Groups[4].Value
        Ctx = $m.Groups[5].Value; CpuMoe = $m.Groups[6].Value; Threads = $m.Groups[7].Value
    }
}
if ($entries.Count -eq 0) { throw "could not read the model registry from llm-up.ps1" }

$friendly = @{
    gemma4 = @{ Title = 'Gemma 4 E4B      - fastest, best default';     Note = '74 t/s at 131k context, 130 ms to first token, native tool calls' }
    qwen36 = @{ Title = 'Qwen3.6 35B-A3B - strongest';                 Note = '34 t/s at 20k context, 2.8 s to first token, 8 of 256 experts fire' }
    flint = @{ Title = 'flint 40B       - deep reasoning';              Note = '30 t/s at 49k context, 3.9 s to first token, MoE split from DDR5' }
    qwen3 = @{ Title = 'Qwen3 8B        - balanced';                    Note = '59 t/s at 16k context, reasons before it answers' }
    coder = @{ Title = 'Qwen2.5 Coder 7B - code only';                  Note = '50 t/s at 32k context, but NO native tool calls' }
    gptoss = @{ Title = 'gpt-oss 20B     - OpenAI''s open model';       Note = '31 t/s at 24k context, no working tool calls' }
}

$menu = New-Object System.Collections.Generic.List[string]
$menu.Add('@echo off')
$menu.Add('setlocal EnableDelayedExpansion')
$menu.Add('title llama.cpp - choose a model')
$menu.Add('cd /d "%~dp0"')
$menu.Add('echo.')
$menu.Add('echo   llama.cpp on this machine - one model fits in 8 GB of VRAM at a time.')
$menu.Add('echo.')
$menu.Add('echo   0  stop everything')
$i = 1
$order = @()
foreach ($k in $entries.Keys) {
    $e = $entries[$k]
    $t = if ($friendly[$k]) { $friendly[$k].Title } else { $k }
    $n = if ($friendly[$k]) { $friendly[$k].Note } else { '' }
    $menu.Add(("echo   {0}  {1}" -f $i, $t))
    $menu.Add(("echo         {0}" -f $n))
    $order += $k
    $i++
}
$menu.Add('echo.')
$menu.Add('set /p pick=  pick a number: ')
$i = 1
foreach ($k in $order) { $menu.Add(("if ""!pick!""==""{0}"" goto m{0}" -f $i)); $i++ }
$menu.Add('if "!pick!"=="0" goto stop')
$menu.Add('goto bad')
$menu.Add('')
$menu.Add(':stop')
$menu.Add('taskkill /IM llama-server.exe /F >nul 2>&1')
$menu.Add('echo   stopped.')
$menu.Add('timeout /t 2 >nul & exit /b')
$i = 1
foreach ($k in $order) {
    $menu.Add((":m{0}" -f $i))
    $menu.Add(("call presets\{0}.cmd" -f $k))
    $menu.Add('exit /b')
    $i++
}
$menu.Add(':bad')
$menu.Add('echo   not a choice.')

Set-Content -Path (Join-Path $Destination 'START HERE.cmd') -Value $menu -Encoding ASCII

$root = $Destination
foreach ($k in $entries.Keys) {
    $e = $entries[$k]
    $lines = @(
        '@echo off',
        "title llama.cpp - $k",
        'cd /d "%~dp0.."',
        '',
        'REM only one model fits in 8 GB of VRAM - clear the previous one first',
        'taskkill /IM llama-server.exe /F >nul 2>&1',
        '',
        'echo.',
        "echo   $k  ->  http://127.0.0.1:$($e.Port)/",
        "echo   model id: $($e.Alias)    context: $($e.Ctx)    n-cpu-moe: $($e.CpuMoe)",
        'echo.',
        'echo   The chat page opens in your browser in a few seconds. Ctrl+C here to stop.',
        'echo.',
        '',
        "REM open the built-in web UI once the server has had time to load",
        "start `"`" cmd /c `"timeout /t 8 >nul & start http://127.0.0.1:$($e.Port)`"",
        '',
        '"%~dp0..\llama-server.exe" ^'
    )
    $args = @(
        "  -m models\$($e.File)",
        "  --alias $($e.Alias)",
        "  --host 127.0.0.1 --port $($e.Port)",
        "  -c $($e.Ctx)",
        "  --jinja --metrics --no-warmup",
        "  -t $($e.Threads) -tb $($e.Threads)",
        "  -ngl 99 -fa on -ctk f16 -ctv f16"
    )
    if ([int]$e.CpuMoe -gt 0) { $args += "  --n-cpu-moe $($e.CpuMoe)" }
    for ($j = 0; $j -lt $args.Count; $j++) {
        $suffix = if ($j -lt $args.Count - 1) { ' ^' } else { '' }
        $lines += ($args[$j] + $suffix)
    }
    Set-Content -Path (Join-Path (Join-Path $Destination 'presets') "$k.cmd") -Value $lines -Encoding ASCII
}

# stop shortcut
Set-Content -Path (Join-Path $Destination 'stop.cmd') -Value @(
    '@echo off',
    'taskkill /IM llama-server.exe /F >nul 2>&1',
    'echo   model stopped, VRAM freed.',
    'timeout /t 2 >nul'
) -Encoding ASCII

# ---------------------------------------------------------------- readme
$tbl = New-Object System.Collections.Generic.List[string]
$tbl.Add('| preset | model | port | context | n-cpu-moe | threads |')
$tbl.Add('|---|---|---|---|---|---|')
foreach ($k in $entries.Keys) {
    $e = $entries[$k]
    $tbl.Add(("| ``{0}.cmd`` | ``{1}`` | {2} | {3} | {4} | {5} |" -f $k, $e.Alias, $e.Port, $e.Ctx,
            $(if ([int]$e.CpuMoe -gt 0) { $e.CpuMoe } else { '-' }), $e.Threads))
}

$readmeTemplate = @'
# llama.cpp on this machine

A working llama.cpp with this laptop's models and this laptop's tuning, in one folder. The GGUFs are
already here. If they are ever missing - a new machine, a wiped disk - the launcher can pull them
straight from Hugging Face.

## Use it

Double-click **START HERE.cmd** and pick a number. The model loads, and the built-in chat page
opens at `http://127.0.0.1:<port>` in your browser.

Or double-click a preset directly. **stop.cmd** frees the GPU.

### The one-click way: llama-direct.exe

`llama-direct.exe` (in this folder, and copied to the Desktop) is a small window that does the same
thing without a console and without remembering ports:

- pick a model from the list, press **Start model** - the chat page opens in your browser
- **Open web UI** reopens the page later (greyed out until something is running)
- **Stop** kills the engine and frees the GPU
- **Folder** opens this directory
- if a model is already serving - from a preset, or a previous run - the window finds it and says
  so instead of starting a second one

It also works from a script, which is how it was tested:

```
llama-direct.exe --start qwen36     REM load, return immediately
llama-direct.exe --stop             REM free the GPU
llama-direct.exe --list             REM what is on disk, what is missing, where it comes from
llama-direct.exe --download gemma4  REM fetch one model from Hugging Face (blocks until done)
```

The window closing does **not** stop the model, so a chat page you already have open keeps working.
Use **Stop** or `stop.cmd` when you are done.

**Only one model fits in 8 GB of VRAM at a time.** Starting a second one kills the first - that is
deliberate, not a bug.

## Getting the models

Pick a model in the launcher and press **Download**. The list already knows which files are missing,
how big they are and where each one comes from; the download runs in the background and prints its
progress in the box at the bottom of the window.

Under the hood that button runs:

```
pwsh -File fetch\llm-fetch.ps1 -Key gemma4
```

which drives the Hugging Face command line:

```
hf download unsloth/gemma-4-E4B-it-qat-GGUF gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf --local-dir <stage>
```

- **xet** - if `hf_xet` is installed, HF transfers the file over its xet backend, which is many
  connections instead of one and is the difference between minutes and half a day on this line.
  The script says which one you are getting. Install it with `python -m pip install -U hf_xet`.
- **it resumes** - each download lands in a staging folder and is moved into `models\` under the
  exact filename the presets expect only once it is complete. An interrupted transfer is picked up
  where it stopped the next time you press Download.
- **a token** - public files need none, but HF throttles anonymous traffic and refuses gated repos.
  Press **HF token...** in the launcher, paste one from `huggingface.co/settings/tokens`, and it is
  written where the `hf` CLI reads it (`%USERPROFILE%\.cache\huggingface\token`). The same token is
  used by every later download, including anything you run by hand.
- **what is where** - `fetch\models.manifest.json` is the catalogue: repo, file, exact byte size,
  quant, and the sha256 of the copy that was benchmarked here. To point a model at a different
  repo, edit that file; nothing else needs to change.

Not every model is byte-identical to the copy measured on this machine - uploaders re-quantise and
re-upload under the same names. The manifest says which is which, and the sizes are within a few
hundred bytes where it matters.

## The presets

{{TABLE}}

Every preset uses:

```
-ngl 99          all layers on the GPU
-fa on           flash attention
-ctk/-ctv f16    f16 KV cache - measured 25-35% faster than q8_0 on this GPU
-t / -tb         thread counts measured on this chip
--jinja          the model's real chat template
--n-cpu-moe N    MoE only: how many layers' experts stay in RAM
```

`n-cpu-moe` is the one number worth understanding. MoE models read only a few experts per token,
so the experts that do not fit can live in DDR5 and still be fast. The value here is the lowest
one that loads; one lower and the model fails with `failed to create_context`.

## Files

| path | what |
|---|---|
| `llama-direct.exe` | the one-click launcher (also on the Desktop) |
| `START HERE.cmd` | text menu, same presets without a window |
| `presets\` | one `.cmd` per model, the tuned flags are inside |
| `models\` | the GGUFs - **hard links**, so they use no extra disk |
| `fetch\` | `llm-fetch.ps1` and `models.manifest.json` - the downloader behind the Download button |
| `stop.cmd` | kill the server, free VRAM |
| `llama-server.exe`, `*.dll` | the engine (CUDA build, b12255) |

The files in `models\` are the same bytes as the repository's `models\` - two names, one copy. If
you delete one side the data survives; delete both and it is gone.

## Command line, if you want it

```
llama-server.exe -m models\gemma-4-E4B-it-q4kxl.gguf --alias gemma-4-e4b ^
  --port 8083 -c 32768 --jinja -t 20 -tb 20 -ngl 99 -fa on -ctk f16 -ctv f16
```

Then any OpenAI-compatible client can use `http://127.0.0.1:8083/v1` with model id `gemma-4-e4b`.
`connecting-local-models.md`, copied to the Desktop, explains how to point Claude Code, dsh-tui,
Cline, Continue and the rest at it.

## Which one to use

- **Fastest, best default**: `gemma4` - 74 t/s at its full 131072 context, 130 ms to first token,
  native tool calls. It is the only model here that is both fast and an agent.
- **Smartest that still runs**: `qwen36` - 34 t/s, but 2.8 s before the first token. Best answers.
- **Deep reasoning with room to think**: `flint` - 30 t/s, 49152 context.
- **Code writing**: `coder` is fast (50 t/s), but it cannot call tools, so no agent use.
- **Agent loops**: anything with native tool calls - `gemma4`, `qwen36`, `flint`, `qwen3`.
  `coder` and `gptoss` are chat-only by design.

Every context number above is the largest one that actually completed a real completion on this
machine - not an estimate. See `Desktop\local-llm-report.md` for the table and
`Desktop\how-the-numbers-were-made.md` for how each was measured.

---

*Built from llama.cpp b12255 (CUDA 13.5) on MSI-Crosshair, Windows 11 build 28000, RTX 5060 Laptop
8 GB. Regenerate this folder with `bin\llm-desktop.ps1`.*
'@
$readme = $readmeTemplate.Replace('{{TABLE}}', ($tbl -join "`n"))
Set-Content -Path (Join-Path $Destination 'README.md') -Value $readme

Write-Host "  presets: $((Get-ChildItem (Join-Path $Destination 'presets') -Filter '*.cmd').Count)" -ForegroundColor DarkGray
Write-Host "  done -> $Destination" -ForegroundColor Green
Write-Host ""

