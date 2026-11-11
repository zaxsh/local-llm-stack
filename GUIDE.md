# GUIDE — start here if you are an agent picking this up cold

This file exists because the rest of the repository is a **record of measurements**, and a record is
useless to someone who does not know how it was produced, what is still provisional, and which
mistakes have already been paid for. Everything below is either a fact measured on this machine or a
trap that has already cost someone a night. Nothing here is aspirational.

If you are a human and just want to run a model, ignore this file and read `README.md` → *Run it*.
If you are an agent about to change something, read this twice.

---

## 1. The one idea

Tokens per second is bounded by **memory bandwidth divided by bytes read per token**. On a laptop:

| memory | bandwidth | what it means |
|---|---|---|
| 32 GB DDR5-5600, dual channel | ~47 GB/s real | a 20 GB dense model reads 20 GB per token → ~2 t/s |
| RTX 5060 Laptop, 8 GB GDDR7 | ~448 GB/s | same 20 GB does not fit; what fits runs ~10× faster |

That 9.5× gap is the whole project. It leads to three conclusions, each of which is measured here
rather than asserted:

1. **Mixture-of-Experts is the only way to run a 20–40 B model in 8 GB of VRAM**: only ~3 B of the
   weights are active per token, so the bytes actually read per token stay small.
2. **`--n-cpu-moe` is the tuning knob**: it decides how many layers keep their experts in DDR5
   instead of VRAM. Too low → out of memory; too high → every token waits on the slow pool.
   The right value is the **lowest one that still fits**, and it is found by loading, not by thinking.
3. **The KV cache should be `f16`, not `q8_0`**: measured 25–35 % faster on this hardware, because
   the quantised cache costs more dequantisation than the bandwidth it saves.

## 2. The machine

| | |
|---|---|
| laptop | MSI MS-17T4, host `MSI-Crosshair\fih` |
| CPU | Core Ultra 7 255HX, 20 cores / 20 threads, AVX2 + AVX-VNNI, **no AVX-512, no AMX** |
| RAM | 32 GB DDR5-5600, dual channel |
| GPU | RTX 5060 Laptop, **8151 MiB** GDDR7, `sm_120`, driver 621.01 |
| iGPU | Intel Xe (unused for this) |
| OS | Windows 11 build 28000, Turkish locale, **no administrator rights** |

Consequences that shape every script: nothing may require admin, paths must be derived from
`$PSScriptRoot` rather than hardcoded, and only **one model fits in VRAM at a time**, so every preset
and every client kills the previous server before starting its own.

Engine: **llama.cpp b12255**, CUDA 12.4 build plus the CUDA 13.5 runtime pack, from
`ggml-org/llama.cpp` releases, installed at `%USERPROFILE%\Desktop\llama.cpp`. It already contains
`qwen35moe` (checked by grepping `llama.dll`), so it runs every model in this repository.

## 3. The invariant: one registry, everything else derived

`bin/llm-up.ps1` holds a table named `$Models`. It is the **single source of truth**:

```
key = @{ File = '<name in models\>'; Port = 8083; Alias = '<openai model id>'; Ctx = 131072;
         CpuMoe = 0; Threads = 20; Note = '<what it is and how fast, one line>' }
```

Every other artefact is generated *from* it, and the scripts that need it **regex it out of the file
text** rather than importing it (a deliberate choice: `llm-up.ps1` also has side effects, so dotting
it in would start a server).

```
bin/llm-up.ps1  ──registry──┬─→ presets\<key>.cmd        (bin/llm-desktop.ps1)
                            ├─→ Desktop\llama.cpp\*      (bin/llm-desktop.ps1)
                            ├─→ llama-direct.exe         (bin/llm-direct.ps1, compiles the list in)
                            ├─→ README tables            (by hand, from measured numbers)
                            └─→ bin/llm-selftest.ps1     (asserts all of the above agree)
models.manifest.json ───────┴─→ bin/llm-fetch.ps1 downloads (key/file/repo/repoFile/sizeBytes)

so the rule is: change the registry, then regenerate, then `llm-selftest.ps1`, then commit.
If you edit a preset by hand it will be silently overwritten and the self-test will fail.
```

`models.manifest.json` is the *catalogue*: where each file comes from, its exact published size, the
sha256 of the file that was benchmarked, and whether the local copy is byte-identical to the source.
`File` in the registry must equal `file` in the catalogue — the self-test enforces it.

## 4. Map of the repository

| path | what it is |
|---|---|
| `bin/llm-up.ps1` | start/list a server for a registered model. **The registry lives here.** |
| `bin/llm-server.ps1` | the actual launcher: picks flags from the model's geometry |
| `bin/llm-fetch.ps1` | downloads from Hugging Face with xet, `-Missing` only, verifies sizes |
| `bin/llm-ncmoe-sweep.ps1` | sweeps `--n-cpu-moe`, records OOM as OOM, writes a CSV |
| `bin/llm-maxctx.ps1` | finds the real context ceiling (bytes/token measured at 8192 and 16384, then tried), `-Apply` writes it into the registry |
| `bin/llm-ctxgrow.ps1` | older, narrower version of the same idea (per-model growth) |
| `bin/llm-tune.ps1` | fastest offload configuration for one GGUF, by measurement |
| `bin/llm-plan.ps1` | reads a GGUF's geometry and says whether it fits, and with what flags |
| `bin/llm-desktop.ps1` | builds the standalone bundle: binaries, models, presets, fetch script |
| `bin/llm-direct.ps1` | builds `llama-direct.exe`, a small GUI that lists models and starts one |
| `bin/llm-selftest.ps1` | **7 checks**: scripts parse, registry↔catalogue agree, presets agree, launcher builds, `--list` answers |
| `bin/llm-verify-bundle.ps1` | end-to-end: every preset loads, generates, calls a tool, stops |
| `bin/llm-bench.ps1` | benchmark across backends, writes CSV |
| `bin/llm-speccmp.ps1` | measures whether speculative decoding helps, per model |
| `bin/llm-gpu.ps1` | finds the NVIDIA GPU and brings it back when Windows hides it |
| `bin/llm-check.ps1` | one status table for every local runtime on the machine |
| `bin/connect-*.ps1`, `bin/llm-claude.ps1` | point Claude Code / dsh-tui / any OpenAI client at a running model |
| `get-started.ps1` | the front door: machine check → engine → models → bundle → launch |
| `bin/llm-scenarios.ps1` | runs realistic prompts and writes a Markdown report |
| `presets/*.cmd` | **generated**. Double-click to serve one model on its port |
| `bench/*.csv` | every measurement, kept. This is the evidence behind the numbers |
| `docs/PROJECT-CONTEXT.md` | the human-facing story of how the machine behaved |
| `docs/local-llm-report.md` | the long report: what was measured and what the machine did |
| `docs/how-the-numbers-were-made.md` | the method behind every number, for people who want to redo it |
| `docs/connecting-local-models.md` | per-client setup (Claude Code, dsh-tui, generic OpenAI) |
| `.github/workflows/ci.yml` | runs `llm-selftest.ps1` + builds the launcher on every push |
| `LICENSE` | plain MIT, no additions — see trap 10 |

## 5. How every number here was produced

No number in this repository came from a spec sheet or an estimate. The protocol:

1. **Fit** — `llm-ncmoe-sweep.ps1` starts the server at each `--n-cpu-moe` in turn, waits for the
   model to load, generates 250 tokens, records tokens/s. A configuration that fails to load is
   recorded as **OOM**, never skipped, because the OOM boundary is the useful information.
2. **Context ceiling** — `llm-maxctx.ps1` loads at 8192 and 16384, reads free VRAM at both to get
   bytes of KV per token, then *tries* the resulting ceiling: the model must load **and complete a
   300-token request**. A model that loads but cannot finish a generation is reported as not
   working — that is exactly how qwen36 lost 24576 and had to be set to 20480.
3. **Speed** — tokens/s from the server's own `--metrics` on that same 250–300 token generation,
   with `-fa on -ctk f16 -ctv f16`, `-ngl 99`, `-t/-tb` at 16 or 20.
4. Everything lands in `bench/*.csv`. If a number is in the README, there is a CSV behind it.

**Never** quote `/health` as proof that a model works, and never extrapolate a context ceiling from
free VRAM. Both have already produced wrong answers here.

## 6. What is measured today

| key | model | file on disk | ctx (measured) | t/s | port | `--n-cpu-moe` | tool calls |
|---|---|---|---|---|---|---|---|
| `gemma4` | Gemma 4 E4B, UD-Q4_K_XL (QAT) | 3.93 GB | 131072 | 74.1 | 8083 | 0 | yes |
| `flint` | FLINT 40B MoE, nvfp4 | 21.29 GB | 49152 | 29.8 | 8080 | 40 | yes |
| `qwen3` | Qwen3-8B Q4_K_M | 4.68 GB | 16384 (20480 OOM) | 59.0 | 8081 | 0 | yes |
| `coder` | Qwen2.5-Coder-7B Q4_K_M | 4.36 GB | 32768 | 50.3 | 8081 | 0 | **no** |
| `gptoss` | gpt-oss-20b MXFP4 | 11.28 GB | 24576 (32768 OOM) | 30.8 | 8082 | 14 | **no** |
| `qwen36` | Qwen3.6-35B-A3B-MTP UD-Q4_K_S | 19.92 GB | 20480 (24576 loads, cannot finish) | 34.0 | 8084 | 30 | yes |
| `coder36` | Qwen3.6-27B-A3B-Coder Q4_K_M | 14.95 GB | **provisional 16384** | **unmeasured** | 8085 | **provisional 24** | unknown |

`coder36` is the seventh model and it is **not finished**. Its flags are placeholders, explicitly
marked `PROVISIONAL` in the registry, and it appears in no performance table. See §7.

## 7. Where we are right now (2026-11-12, 01:20)

The model to add: `ManniX-ITA/Qwen3.6-27B-A3B-Coder-MTP-GGUF`, quant `Q4_K_M`,
**16,057,050,592 bytes exactly**, publisher's sha256
`baf6dfd9eb22799143ae96c89ddb2971733e2f3029783685e18c873c576457de`.

What it is: an **expert-pruned** Qwen3.6-35B-A3B — 256 → **184 experts**, top-**10** routing baked
in (not 8), 26.66 B total, ~3 B active, architecture string `qwen35moe`, Apache-2.0. It **thinks
before answering**, and llama.cpp can bound that with `--reasoning-budget N` (present in b12255).
None of the six existing presets sets a thinking budget, so for comparability this one does not
either — but it is worth offering in the registry note, because a coder model that thinks can eat a
16k context before writing a single line.

**State of the download, and why it is a story:**

- The link (WARP enabled) ran at 0.03–2.1 MB/s. `hf download` **stalls at 0 bytes** on this link
  while plain `curl` to the same URL proceeds — that is a fact about this network, not about `hf`.
- One connection: 2.0 MB/s. Eight connections with 20 MB ranges: 3.9 MB/s. Sixteen: 4.05 MB/s → the
  link saturates near 4 MB/s. **But** a single 1.87 GB range ran at 0.33 MB/s and eight of them sat
  at 0 bytes for three minutes: **large ranges are the problem, not parallelism**.
- So the transfer is **174 chunks of 64 MB, 8 workers** (`%TEMP%\chunks-coder36\cNNNN.bin`), stitched
  with a streamed `.NET` copy, then hashed before being renamed into place. At 01:20 it was
  **113/174 chunks**.
- Script: `C:\Users\fih\.dsh\segmented-coder36.ps1`; log `C:\Users\fih\.dsh\coder36-finish.log`.
  The `.part` file (`models\qwen3.6-27b-a3b-coder-q4km.gguf.part`) holds the first 4,383,946,060
  bytes from the earlier single-stream attempt and is reused, not re-downloaded.
- A measurement chain is already queued (`C:\Users\fih\.dsh\measure-coder36.ps1`): the moment the
  verified file exists it runs `llm-ncmoe-sweep.ps1 -Values 16,18,20,22,24,26,28 -Ctx 16384
  -Threads 16` into `bench\ncmoe-coder36.csv`, logging to `bench\measure-coder36.log`.

**Do not trust the process ids in this document; check them.** Find the real ones with
`Get-Process curl` and `Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'"`.

## 8. How to continue from here

```powershell
cd C:\Users\fih\llm

# 1. is the file there yet?
Get-Content C:\Users\fih\.dsh\coder36-finish.log -Tail 5

# 2. if the chunks stopped, just re-run this - it skips every chunk already correct
pwsh -NoProfile -File C:\Users\fih\.dsh\segmented-coder36.ps1

# 3. when the sweep CSV exists, read it
Get-Content bench\ncmoe-coder36.csv

# 4. pick the lowest --n-cpu-moe that is not OOM and is fastest; put it in the registry
#    (bin/llm-up.ps1, the coder36 line), then regenerate everything:
pwsh -NoProfile -File .\bin\llm-desktop.ps1 -SkipBinaries
pwsh -NoProfile -File .\bin\llm-direct.ps1
#    and sync the generated preset back into the repository copy:
Copy-Item "$env:USERPROFILE\Desktop\llama.cpp\presets\coder36.cmd" .\presets\ -Force

# 5. the context ceiling, measured and applied
pwsh -NoProfile -File .\bin\llm-maxctx.ps1 -Models coder36 -Apply
#    then regenerate presets again (maxctx rewrites Ctx in the registry)

# 6. prove it works end to end, including a real tool call
pwsh -NoProfile -File .\bin\llm-selftest.ps1
pwsh -NoProfile -File .\bin\llm-verify-bundle.ps1
```

Then, and only then, the paperwork that makes it a fact:

1. `models.manifest.json` — set `verified: true`, `localSha256` to the hash you computed, and rewrite
   the `note` from *TO BE MEASURED* to the measured one-liner.
2. `README.md` — §3 (memory budget), §4 (measured performance), §14 (context ceilings), §15 (where
   the models came from). One row, real numbers.
3. `docs/PROJECT-CONTEXT.md` — replace the *in progress* section with what actually happened.
4. `bench\` — keep the sweep and maxctx CSVs; they are the evidence.
5. `git add -A`, commit in the house voice (see §11), push, confirm CI green.
6. Cut **v1.1.0** (new model = minor bump): tag HEAD, `git archive` the zip, `gh release create`
   with `llama-direct.exe`, the zip and `SHA256SUMS.txt`.

## 9. Adding the eighth model (the recipe, generalised)

1. **Is the repo public?** `curl -s https://huggingface.co/api/models/<repo>?blobs=true` → `gated`,
   `private`, and the exact `size` of each file. Use the exact byte count, not the rounded GB.
2. **Is there a published checksum?** Many uploaders ship `<file>.gguf.sha256`. If yes, the model can
   be **`verified: true`** in the strict sense — download, hash, compare — instead of "same size,
   probably the same bytes".
3. **Pick the quant by arithmetic, not taste**: total bytes must leave room for `f16` KV at the
   context you want. Q4_K_M is the quality sweet spot; drop to Q4_K_S/IQ4_XS when the budget is tight.
4. **Check the engine supports the architecture** before downloading 15 GB:
   `findstr /c:"qwen35moe" "%USERPROFILE%\Desktop\llama.cpp\llama.dll"`. The architecture string is
   in the GGUF header (`general.architecture`).
5. **Add to `models.manifest.json`** (key, file, repo, repoFile, sizeBytes, quant, params, verified,
   localSha256, note) and to the registry in `bin/llm-up.ps1` (pick a free port — 8080–8085 are taken).
6. **Download** with `bin\llm-fetch.ps1 -Key <key>` if the link is healthy; on this link, see §7.
7. **Measure**: `llm-ncmoe-sweep.ps1` → `llm-maxctx.ps1 -Apply` → verify with a real generation and a
   tool call. Record t/s from `--metrics`.
8. **Regenerate** presets/bundle/launcher, sync the preset into `presets\`, run `llm-selftest.ps1`.
9. **Document** in the same four places as §8, then commit and release.

## 10. Traps that have already been paid for

Each of these cost real time. Do not rediscover them.

1. **`hf download` can sit at 0 bytes forever on a bad link while `curl` works.** Watch the target
   directory's size, not the process's existence. And on this link, prefer many small ranges.
2. **Hardcoded paths shipped once.** 13 scripts contained `C:\Users\fih\llm`; a copy of the repo in
   `%TEMP%` proved it by resolving the *original* folder. Always `Split-Path $PSScriptRoot -Parent`.
   The proof is cheap: copy the tree somewhere else and run it there.
3. **`llm-desktop.ps1` used to create a half-built folder and then throw** on a machine with no
   engine. It now checks for `llama-server.exe` first and exits 1 without writing. Keep that order:
   **check, then create.**
4. **PowerShell cannot capture a Windows-subsystem `.exe` through a pipe** — the child dies and
   `$LASTEXITCODE` reads 0. Use `Start-Process -RedirectStandardOutput` (this is how `llm-selftest`
   reads `llama-direct.exe --list`).
5. **`[System.IO.File]::ReadAllText('relative\path')` resolves against `C:\WINDOWS\system32`**, not
   the script's directory. Always pass an absolute path.
6. **`Select-String -SimpleMatch 'C:\\Users\\fih'` matches nothing** — in simple mode the backslashes
   are literal, so the doubled form is wrong. An audit based on it falsely reported "0 hardcoded".
7. **Do not kill processes by command-line match without excluding yourself**: `Get-CimInstance
   Win32_Process | Where CommandLine -like '*finish-coder36*'` also matches the shell running that
   very command. One session was killed that way. Add `-and $_.ProcessId -ne $PID`.
8. **A detached `llama-server` makes the next command look hung.** The server daemonises; the calling
   shell waits forever. Poll `http://127.0.0.1:<port>/health` instead of waiting on the process.
9. **`gh run view --json` rejects fields it does not know** (e.g. `isLatest`) with a bare error. Ask
   for the fields you need one at a time.
10. **GitHub reported `NOASSERTION` for the licence** because the MIT text had a paragraph appended
    after it. `LICENSE` must be the unmodified MIT text; the "weights are not MIT" note lives in the
    README.
11. **`.gitattributes` keeps `.ps1`/`.cmd` as CRLF and everything else as LF.** Without it, Windows
    clones get a mixed tree and `.cmd` files can break.
12. **`$LASTEXITCODE` becomes 0 if you pipe a failing child's output into `Select-Object -First N`** —
    the broken pipe kills the child before it can set the exit code. Never truncate the output of a
    command whose exit code you are about to trust.
13. **`throw @"... "@` collapses into one line** in some hosts, and a `throw` inside a pipeline is
    swallowed. Use `Write-Host` + `exit 1` when the message is the point.
14. **`web_fetch` refuses `127.0.0.1`.** Use `curl`/`Invoke-RestMethod` for local endpoints.
15. **Commands may start in `C:\WINDOWS\system32`.** Pass an explicit working directory, or `cd`
    first, or use absolute paths. A relative path "not found" is usually this.

## 11. House rules (how this repository is written)

- **Numbers over adjectives.** Not "fast" — 34.0 t/s at 20480 context on this laptop.
- **No claim without the command that produced it.** If you cannot paste the command and its output,
  it does not go in a table.
- **Provisional must say provisional.** A placeholder is allowed only with `PROVISIONAL` in the
  registry and a matching note in the manifest, and it may not appear as a performance number.
- **Say what failed.** The OOM rows, the "loads but cannot finish", the model that has no native
  tool calls — these are the most valuable lines in the file.
- **Commit messages explain why, then what.** `fix: stop llm-desktop building a folder it cannot fill`
  beats `update script`.
- **A release may only contain verified state.** If main is ahead of the last tag with provisional
  work, tag the last verified commit rather than shipping placeholders (v1.0.3 was cut that way).
- **Style of the response to the user**: one line beginning with `⏵` describing the current action,
  then the content. Terse, evidence-first.

## 12. Open questions, in priority order

1. Finish `coder36`: sweep → context ceiling → registry → docs → **v1.1.0**.
2. Does `--override-kv qwen35moe.expert_used_count=int:8` (8 experts instead of the baked-in 10)
   buy enough speed to be worth the quality trade? Measure both, then decide — the model card
   suggests it as the cheaper option, but nothing has been measured on this GPU.
3. Does the MTP head actually help here? `bin/llm-speccmp.ps1` answers it for a model; nobody has
   run it on the two `-MTP` models yet.
4. `flint` at 29.8 t/s and `qwen36` at 34.0 t/s are the two "big" options; a head-to-head on the same
   prompts (via `bin/llm-scenarios.ps1`) would say which one to actually use, and that answer is not
   in the repository yet.
5. The twelve remaining `C:\Users\fih` mentions in the docs are deliberate (they are the machine
   record), but they do leak a username in a public repo. Scrub them if that ever matters.
