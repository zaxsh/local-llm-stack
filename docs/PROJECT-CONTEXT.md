# Local LLM project — reconstructed context

Rebuilt on 2026‑11‑11 from five archived sessions in `%USERPROFILE%\.dsh\sessions`:

| # | session id | started | what it was |
|---|---|---|---|
| 1 | `92a4ce88` | 11‑08 02:07 | install Hermes agent |
| 2 | `b581f8fb` | 11‑08 02:36 | fix Hermes desktop, connect every local engine |
| 3 | `dc34217f` | 11‑09 02:08 | Pinokio local coding agent (later deleted) |
| 4 | `ec293695` | 11‑10 22:19 | scan hardware, install every runtime |
| 5 | `966860e7` | 11‑10 23:42 | **the real project** — tune for Mac‑level speed, package it |

Digests kept at `.dsh\core\` (fuller) and `.dsh\digests\` (verbatim tool calls).

---

## 1. The machine

| | |
|---|---|
| Laptop | MSI **MS‑17T4**, host `MSI-Crosshair\fih` |
| CPU | Intel Core Ultra 7 **255HX** (Arrow Lake‑HX), 20C/20T, AVX2 + AVX‑VNNI, **no AVX‑512 / no AMX** |
| RAM | **32 GB DDR5‑5600**, measured ≈47 GB/s copy, 45–60 GB/s read |
| dGPU | **RTX 5060 Laptop, 8151 MiB GDDR7**, sm_120, driver 621.01, ≈448 GB/s |
| iGPU | Intel Xe, 4 cores, shared RAM, Vulkan 1.4.x |
| OS | Win11 build 28000, Turkish locale, **no admin rights** |

The whole project follows from one ratio: **448 GB/s ÷ 60 GB/s ≈ 7.5×**. Anything that has to
cross the PCIe/DDR5 boundary is 7.5× slower per byte than anything resident in VRAM.

## 2. The goal

> "scan my current hardware and optimize it to mac‑level llm running"

i.e. make a 32 GB Windows laptop feel like an Apple‑silicon box with unified memory. It cannot be
done with a big dense model (8 GB VRAM, 60 GB/s RAM). It *was* done by picking models whose
**bytes‑read‑per‑token** is small — MoE with a hand‑tuned `--n-cpu-moe` split — and by keeping the
KV cache in f16 on the GPU.

## 3. The two failed premises (worth remembering)

1. **"Use the iGPU as unified memory."** Measured on a 7B Q4: CPU 13.0 t/s, Vulkan iGPU 7.9, OpenVINO
   8.4. On x86 the iGPU shares the *same* DDR5 stick but has 4 Xe cores — strictly worse than the CPU
   for generation. Ollama says so itself: `dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1`.
2. **"A 20B dense model won't fit, so split it."** gpt‑oss‑20b is **MoE**, and qwen3.6‑35b‑a3b fires
   only **8 of 256 experts** per token. Parameter count is irrelevant; sparsity is everything.

## 4. What exists on disk now (verified 11‑11 20:30)

```
C:\Users\fih\llm\
  llama.cpp\b12255\  cpu  vulkan  openvino  cuda
  models\            gemma-4-E4B-it-q4kxl.gguf            3.93 GB   4B dense
                     Qwen3-8B-Q4_K_M.gguf                4.87 GB   8B dense
                     qwen2.5-coder-7b-q4km.gguf          4.36 GB   7B dense
                     gpt-oss-20b-MXFP4.gguf             12.85 GB   20B MoE
                     flint-nvfp4-40b.gguf               21.29 GB   40B MoE (2.5B active)
                     qwen3.6-35b-a3b-mtp-q4km.gguf      20.23 GB   35B MoE (3B active, MTP)
                     qwen3.6-mmproj.gguf                 0.84 GB   vision projector (unused)
  bin\               llm-up.ps1        model registry (file, port, alias, Ctx, CpuMoe, Threads)
                     llm-plan.ps1      GGUF geometry -> bytes/token, suggested ncmoe, predicted t/s
                     llm-server.ps1    low-level launcher
                     serve-model.ps1   universal launcher (registry key | filename | path | ollama tag)
                     llm-check.ps1     health/environment check
                     llm-bench.ps1     benchmark
                     llm-scenarios.ps1 6 user-scenario prompts per model -> report + CSV
                     llm-tune.ps1      flag sweep
                     llm-ncmoe-sweep.ps1  ncmoe vs t/s, marks OOM runs
                     llm-speccmp.ps1   A/B spec decoding (none | draft-mtp | ngram-cache)
                     llm-desktop.ps1   builds the Desktop bundle + presets from the registry
                     llm-direct.ps1    builds Desktop\llama-direct.exe (GUI) from the registry
                     llm-verify-bundle.ps1  reads the real .cmd presets and tests each one
                     llm-maxctx.ps1    two-point VRAM probe (unreliable here — see §7)
                     llm-ctxgrow.ps1   ** trial-load prober: the highest ctx that really loads **
                     llm-gpu.ps1       dGPU diagnostics/recovery
                     connect-dsh.ps1   writes dsh-tui routes
                     connect-claude.ps1 starts anthropic-shim.py and launches Claude Code
                     connect-any.ps1   prints configs for Continue/Cline/Roo/OpenWebUI/LangChain
                     anthropic-shim.py Anthropic /v1/messages -> OpenAI /v1/chat/completions shim
  bench\             bundle-verify.csv, maxctx.csv(empty), ncmoe-*.csv, confirm-qwen36.csv
  README.md          the engine manual, §12 = connecting any model to any client
  venv\              torch 2.15+cpu, transformers 5.5.4, openvino 2026.4.1, llama-cpp-python 0.3.36

C:\Users\fih\Desktop\
  0 - Stop all models.cmd        1 - List models.cmd
  2 - Start Gemma 4 (fast).cmd   3 - Start flint 40B (deep).cmd
  4 - Claude Code (local model).cmd   5 - dsh-tui (local model).cmd
  6 - Connect anything (configs).cmd  7 - Start Qwen3.6 35B (smart).cmd
  llama-direct.exe               the 16.5 KB one-click GUI (start model -> chat page opens)
  llama.cpp\                     self-contained copy: binaries, models, presets\, START HERE.cmd
  local-llm-report.md            34 KB measurement report
  local-llm-results.csv          the scenario suite
  how-the-numbers-were-made.md   methodology (ncmoe sweep, MTP A/B, GPU clock ramp)
  connecting-local-models.md     the client contract
```

Also on the machine, from the earlier sessions: **Hermes** (Electron app at
`C:\Users\fih\hermes-src\apps\desktop\release\win-unpacked\Hermes.exe`, agent CLI
`C:\Users\fih\.local\bin\hermes.exe`, backend :57857) with providers for LM Studio :1234,
Ollama :11434, Magnitude :10100, llama.cpp and Ollama Cloud; **Ollama, LM Studio, Magnitude**
all installed. **Pinokio's Local Coder app was deleted on purpose** ("delete everything in
pinokio, carry our progress to the llama.cpp that is installed directly") — do not rebuild it.

## 5. The serving contract (do not change ports/aliases — clients are wired to them)

| key | alias | port | Ctx | n‑cpu‑moe | threads |
|---|---|---|---|---|---|
| `gemma4` | `gemma-4-e4b` | 8083 | **131072** | 0 | 20 |
| `qwen3` | `qwen3-8b` | 8081 | 16384 | 0 | 20 |
| `coder` | `qwen2.5-coder-7b` | 8081 | **32768** | 0 | 20 |
| `gptoss` | `gpt-oss-20b` | 8082 | **24576** | 14 | 20 |
| `flint` | `flint-nvfp4-40b` | 8080 | **49152** | 40 | 16 |
| `qwen36` | `qwen3.6-35b-a3b` | 8084 | **20480** | 30 | 16 |

Every preset runs: `--jinja --metrics --no-warmup -ngl 99 -fa on -ctk f16 -ctv f16`.

## 6. Measured performance (all numbers from this machine)

Bundle verification, 300‑token runs after warm‑up:

| preset | load | generation | native tool calls | frees GPU |
|---|---|---|---|---|
| gemma4 | 5.1 s | **77.5 t/s** | ✅ | ✅ |
| coder | 7.9 s | 52.5 t/s | ❌ by design | ✅ |
| qwen3 | 8.7 s | 46.7 t/s | ✅ | ✅ |
| qwen36 | 21.5 s | 39.2 t/s | ✅ | ✅ |
| gptoss | 15.9 s | 34.4 t/s | ❌ by design | ✅ |
| flint | 21.5 s | 29.5 t/s | ✅ | ✅ |

Six‑scenario suite (summarise / codegen / debug / reasoning / extract / tools):
qwen36 43.3 / 36.4 / 46.9 / 39.2 / 43.4 / 47.0 t/s · flint 29.9 / 37.1 / 25.2 / 34.1 / 36.6 / 35.9 ·
gpt‑oss 25–35 · gemma4 69.9–88.9 · qwen3 16.5–57.4 · coder ~57.5 flat.

Tuning conclusions that must not be re‑litigated:

* **f16 KV is 25–35 % faster than q8_0** on GPU‑resident models (62.3 vs 44.7 t/s). Only drop to q8_0
  if f16 does not fit.
* **Lower `--n-cpu-moe` is faster** until it OOMs; the optimum is the lowest value that loads.
  qwen36: 20/24/26/28/29 all OOM at 16k ctx, **30 = 45.7 / 41.3 t/s**, 31 = 33.7, 32 = 38.7, 34 = 40.7.
* **MTP is a net loss here**: +18 % at equal ncmoe, but the extra rs‑cache buffer forces ncmoe 30→38
  which costs ~29 %. `ngram-cache` is far worse (16–21 % acceptance). Do not use.
* **`draft-mtp` needs ncmoe ≥ 34 at 8192 ctx** on qwen36 (blk.40.nextn.\* tensors are loaded even
  though the log says "unused … ignoring").
* Short runs measure the **GPU clock ramp** (1.6 → 2.4 GHz). Always warm up and generate ≥300 tokens;
  expect ±15 % run‑to‑run.
* `llama-bench` has no `-c`; it uses `-p/-n/-d`. Flag renames in b12255: `--load-mode` replaced
  `--no-mmap`; `--spec-type`/`--spec-draft-model` for speculative decoding.
* Only **one model fits in 8 GB at a time** — every preset and every client must stop the previous
  server first. Clients holding VRAM (LM Studio, Magnitude, Steam/steamwebhelper) must be closed;
  closing them freed 1.45 GB used / 6.45 GB free.
* llama.cpp b12255 has **no Anthropic `/v1/messages` endpoint** — Claude Code needs `anthropic-shim.py`.

## 7. U16 — maximum context per model  ✅ done 2026‑11‑11 20:52

Last instruction of session 5 (U16, 20:08):

> "fix the presets so every model will load with maximum amount of context window (a model is
> running rn if you wonder what is keeping the cache full)."

The session died at 20:13 mid‑flight: `llm-maxctx.ps1` had produced one real result
(gemma4 `32768 -> 131072`, KV 17,408 B/token, 74.1 → 67.5 t/s) and `bench\maxctx.csv` was still
0 bytes because the script only writes at the very end.

### What was done on resume

1. Ran `llm-maxctx.ps1 -Apply`. It works when the card has headroom, but **its extrapolation is
   wrong on this machine**: free VRAM at 16384 is 200–300 MB with LM Studio/Magnitude resident, so
   `(free − 400 MB)` goes negative and it proposed *smaller* contexts than the ones already
   serving (qwen3 16384 → 14336, gptoss 16384 → 11264). Those two rows were reverted.
2. Wrote **`bin\llm-ctxgrow.ps1`**, which treats loading as ground truth: start at each candidate
   context, wait for `/health`, send a real completion, keep the last one that passes, stop at the
   first failure. This is what settled the ceilings.
3. Applied the verified values, regenerated the presets and `llama-direct.exe`, then re-ran
   `llm-verify-bundle.ps1` — all six load, answer, tool‑call and release the GPU.

### Result

| preset | ctx before → after | verified generation | cost |
|---|---|---|---|
| gemma4 | 32768 → **131072** | 74.1 t/s | −4 % |
| flint | 16384 → **49152** | 29.8 t/s | none |
| coder | 16384 → **32768** | 50.3 t/s | −4 % |
| gptoss | 16384 → **24576** | 30.8 t/s | −10 % |
| qwen36 | 16384 → **20480** | 34.0 t/s | −13 % |
| qwen3 | 16384 → 16384 | 59.0 t/s | ceiling confirmed (20480 exits) |

Context turned out to be cheap: the KV cache is 17–58 KiB/token against 4–21 GB of weights, so a
full 131k window on gemma4 costs ~2.3 GB and 4 % of its speed. The probe's scarier numbers
(−24 %, −32 %) were cold‑clock artefacts; the warm‑up verification is authoritative.

Written up in `local-llm-report.md` ("Maximum context, per model"), `how-the-numbers-were-made.md`
(Part 9), `llm\README.md` (§14) and the `Note` fields in `llm-up.ps1`.

### Trap for next time

A negative‑headroom model must never be "downsized" by an estimator. If `free_VRAM < safety_margin`
the correct answer is *keep the context that already works and probe upward by trial load*, not
"compute a smaller number". Also: `/health` returning ok is **not** proof a context works — qwen36
at 24576 loads, answers `/health`, and then fails its first real completion.

## 8. House rules learned the hard way

* `pwsh -File script.ps1 -Param a,b,c` collapses the list into one string — pass one value per call
  or split on `[,\s]+`.
* Tool calls in one assistant message can run in parallel: an edit + a run in the same message races.
* A detached `llama-server` can make a tool call look like it never returns — verify via `/health`.
* `web_fetch` refuses `127.0.0.1` ("non-public IP").
* Secrets live in `%LOCALAPPDATA%\hermes\.env` and Ollama's config; don't copy them into new files.

---

## 9. Where this lives now — GitHub, and getting the models back (2026‑11‑11 21:35)

**Repo:** `https://github.com/zaxsh/local-llm-stack` — **public**, branch `main`, tags `v1.0.0` and `v1.0.1`,
first release published with two assets.

```
llama-direct.exe                 26 KB   the launcher, same file as on the Desktop
local-llm-stack-v1.0.0.zip      152 KB   the whole source tree (bin, presets, launchers, docs, bench)
```

| | |
|---|---|
| GitHub account | `zaxsh` (gh 2.101.0, keyring, repo + workflow + delete_repo scopes) |
| Hugging Face | hf 1.32.0, hf_xet 1.6.0, token at `%USERPROFILE%\.cache\huggingface\token` (no account name here: this repository is public) |
| What is in git | 65 files: `bin\` (24 scripts), `presets\` (6), `launchers\` (8), `docs\` (4), `bench\` (19), README, manifest, requirements |
| What is deliberately not | `models\` (74 GB), `llama.cpp\` (1.2 GB), `tools\` (cmake/ninja), `venv\`, `logs\`, any `*.exe` |

### The downloader (new)

- `models.manifest.json` — repo + repoFile + exact bytes + sha256 + quant + note, per model.
- `bin\llm-fetch.ps1` — `-List`, `-Missing`, `-Key`, `-All`, `-DryRun`, `-Token`, `-HighPerformance`,
  `-Json`. Downloads into `%TEMP%\hf-stage-<key>`, then moves to `models\<registry filename>`.
  Staging is what makes resume safe and keeps half files out of `models\`.
- `llama-direct.exe` — the Download button and the masked **HF token...** box; token is written to
  the standard HF token path, never to a command line or a log. Headless: `--list`,
  `--download <key>`, `--start <key>`, `--stop`. It is `/target:winexe`, so it calls `AttachConsole`
  to print when given a command line and stays silent when double-clicked.

### Provenance — how each GGUF was traced

Hashed all six local files, then compared against the LFS `sha256` the Hub API reports for each
sibling of every candidate repo, and cross‑checked with `fsutil hardlink list` (which names the blob
each file was hardlinked from).

| local file | source | verdict |
|---|---|---|
| `gemma-4-E4B-it-q4kxl.gguf` | `unsloth/gemma-4-E4B-it-qat-GGUF` :: `gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf` | **sha256 identical** |
| `flint-nvfp4-40b.gguf` | `RecursiveSI/flint-nvfp4-gguf` :: `flint-nvfp4.gguf` | **sha256 identical** |
| `qwen3.6-35b-a3b-mtp-q4km.gguf` | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` :: `…UD-Q4_K_S.gguf` | nearest size (21.39 vs 21.72 GB) |
| `gpt-oss-20b-MXFP4.gguf` | `ggml-org/gpt-oss-20b-GGUF` :: `gpt-oss-20b-MXFP4.gguf` | canonical (12.11 vs 13.79 GB) |
| `Qwen3-8B-Q4_K_M.gguf` | `Qwen/Qwen3-8B-GGUF` :: `Qwen3-8B-Q4_K_M.gguf` | official, same name (5.03 vs 5.23 GB) |
| `qwen2.5-coder-7b-q4km.gguf` | `Qwen/Qwen2.5-Coder-7B-Instruct-GGUF` :: `qwen2.5-coder-7b-instruct-q4_k_m.gguf` | official, sha differs by 512 bytes |

The four unverified ones came from uploaders that no longer serve the same bytes. Every substitute
is *smaller* than the local file, so the tuned `-n-cpu-moe` still fits. `llm-fetch.ps1` treats a file
as present when it is at least 60 % of the catalogued size — an exact match is too strict and would
tell you a working 20 GB model is missing.

### xet, measured

Same 94 MB file, back to back, both runs surviving a dropped connection:

| transport | time | rate |
|---|---|---|
| plain HTTP (`HF_HUB_DISABLE_XET=1`) | 310 s | 0.30 MB/s |
| xet (default) | 131 s | 0.72 MB/s |

2.4×. The absolute numbers are the line's, not xet's. `-HighPerformance` sets
`HF_XET_HIGH_PERFORMANCE=1` for more parallel ranges.

### coder36 — the seventh model (finished, 2026-11-12 02:20)

`ManniX-ITA/Qwen3.6-27B-A3B-Coder-MTP-GGUF`, Q4_K_M, **16,057,050,592 bytes exactly**, port 8085,
alias `qwen3.6-27b-a3b-coder`, file `qwen3.6-27b-a3b-coder-q4km.gguf`. It is an **expert prune** of
Qwen3.6-35B-A3B: 256 -> **184 experts**, top-**10** routing baked in, 26.66 B total, ~3 B active,
architecture string `qwen35moe`, Apache-2.0.

**Final flags: `-c 32768 --n-cpu-moe 26 -t 16` -> 44.4 t/s.** Every part of that came from a
measurement:

| step | what happened |
|---|---|
| floor | `--n-cpu-moe` 28 -> 33.9 t/s, **26 -> 45.0 t/s**, 24 -> real CUDA OOM (`failed to allocate CUDA0 buffer of size 360583296`). 26 is both the floor and the fastest. |
| ceiling | `llm-maxctx.ps1` extrapolated 28672 from free VRAM. `llm-ctxgrow.ps1` then served **32768** at the same setting, and 34816 failed its first completion. |
| re-check | at 32768: 26 -> **44.4 t/s**, 28 -> 43.6, 30 -> 35.2. The floor did not move when the context grew. |
| tools | native `tool_calls`, verified with a real `get_weather` request against llama.cpp directly (43 t/s). |

**It thinks before it answers**, and that changes the numbers a user sees. Same coding prompt, three
configurations, 28k context: default routing 37.2 t/s over 1197 tokens and **35.7 s** wall time
(4403 characters of reasoning before the first line of code); `--reasoning-budget 512` cut that to
**20.3 s**; `--override-kv qwen35moe.expert_used_count=int:8` reached **43.6 t/s** in 28.3 s but
trades routing quality for speed, which was not measured, so the preset ships the model's own
top-10 default and both flags are documented instead of applied.

**The download is the story of the night.** The link ran at 0.03-2.1 MB/s, `hf download` stalled at
0 bytes where plain `curl` proceeded, one connection gave 2.0 MB/s, eight gave 3.9, sixteen 4.05 —
and a single 1.87 GB range collapsed to 0.33 MB/s while eight of them sat at zero bytes for three
minutes. So large ranges were the problem, not parallelism: the file came down as **174 chunks of
64 MB, 8 at a time**, stitched and hashed. The publisher ships a `.sha256` beside every quant, so the
result is `verified: true` in the strict sense — proved byte-identical, not assumed.

**A tool was broken by this model and is now fixed.** `llm-ncmoe-sweep.ps1` declared
`[string]$Values` and then reassigned it to the split array — but a parameter's type constraint
survives for the whole scope, so the array was coerced straight back into `"26 28 30"` and the loop
ran once with that string as a single value. Every multi-value sweep had therefore been silently
sweeping one bogus configuration. The split now goes into `$targets`. Found by using the tool, which
is the only way this kind of bug surfaces.
### The front door (added for v1.0.1)

`get-started.ps1` is now the entry point: machine check, engine download (pinned `b12255`, from
ggml-org releases — engine + cudart, ~715 MB), missing models, bundle, launcher, open. It is
idempotent, so it is also the rebuild path.

`bin\llm-selftest.ps1` is the regression net, and it needs no GPU and no model: it parses all 25
scripts, proves the registry and the catalogue name the same six files, proves every preset uses the
registered model/port/context, compiles the launcher and checks `--list`. CI runs exactly this on
`windows-latest` (`.github/workflows/ci.yml`), then uploads the exe as an artifact. First run:
all 7 steps green. **Run it before any commit that touches the registry, the manifest or the presets.**

Portability that used to be machine-specific: `llm-desktop.ps1` now finds `-Build` and
`-SourceModels` relative to the repo (cuda → vulkan → cpu), and `launchers\*.cmd` use `%USERPROFILE%`.

Git gotcha worth keeping: `git archive` applies `.gitattributes`, which is why the `.cmd` files in
the released zip are CRLF (cmd.exe breaks its `goto` labels on LF). If a batch file misbehaves after
a checkout, check its line endings first.
### Re-cutting a release

```powershell
cd C:\Users\fih\llm
git add -A; git commit -m "..."
gh auth status                          # must say zaxsh
git push                                # git's helper is 'manager'; if it 401s, gh auth setup-git fixes it
git tag -a v1.0.1 -m "v1.0.1"; git push origin v1.0.1
.\bin\llm-direct.ps1                    # rebuild the launcher into the bundle
git archive --format=zip -o dist\local-llm-stack-v1.0.1.zip --prefix=local-llm-stack-1.0.1/ HEAD
gh release create v1.0.1 --title "..." --notes-file NOTES.md dist\llama-direct.exe dist\local-llm-stack-v1.0.1.zip
```

### Two traps that bit twice

1. **`git push` after `gh repo create --push` can 401.** The remote is fine; git's own credential
   helper had nothing. `gh auth setup-git` then `git push origin <tag>`.
2. **PowerShell `[string]`-typed variables silently re-join objects.** `param([string]$ManifestPath)`
   plus `$manifest = ... | ConvertFrom-Json` assigns to *the same variable* (names are
   case‑insensitive) and turns the object into a string, so `$manifest.models` is empty and every
   lookup returns nothing. The fetcher keeps the parsed JSON in `$catalog` for this reason. The same
   trap hit `-Candidates` in `llm-ctxgrow.ps1` (see §7).
3. **Quotes get doubled twice.** `llama-direct.ps1` generates C# source. The model arguments live in a
   verbatim `@"..."` literal, where `"` must be written `""` — but the code also kept an older
   `.Replace('"','""')` from when the literal was a normal `"..."`, so the engine was handed
   `-m ""models\gemma-4-E4B-it-q4kxl.gguf""`. `/health` still answered, which is why it hid. There is
   now a `CsLiteral()` used for every emitted string and a build-time throw if the output ever
   contains four consecutive quotes. Check the running process with
   `(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'").CommandLine` when a model
   behaves oddly: the real command line is the ground truth, not the intent.

## 10. Capability measured, not just speed (2026‑11‑12 06:10)

The repository could say how fast each model is and nothing about whether it is any good. That is now
measured: `bin/llm-eval.ps1` runs 36 items over eight categories, `bin/llm-eval.py` grades every reply by
program, `bench/capability-suite-v1.json` holds the items and the answer key, and
`docs/capability-evaluation.md` holds the results and what they cannot support.

| model | macro | math | logic | code | instr | json | needle | tools | knowledge | budget hits |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| flint | 100.0 | 6/6 | 5/5 | 4/4 | 6/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| gemma4 | 97.9 | 6/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| qwen3 | 97.9 | 6/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| coder | 95.8 | 5/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| coder36 | 85.4 | 5/6 | 5/5 | 2/4 | 5/6 | 3/3 | 2/3 | 3/3 | 6/6 | 5 |
| qwen36 | 78.1 | 6/6 | 5/5 | 1/4 | 2/6 | 3/3 | 2/3 | 3/3 | 6/6 | 8 |
| gpt-oss | 67.7 | 6/6 | 5/5 | 1/4 | 1/6 | 3/3 | 3/3 | 0/3 | 6/6 | 5 |

Three findings that should change how the stack is used:

1. **Speed and capability are effectively uncorrelated here** (rank correlation 0.2 over seven models).
   Speed is bytes-per-token, capability is weights and serving.
2. **The bottom three are the three that think before answering.** They hit their output budget on
   5, 8 and 5 items respectively; on `code-2` coder36 and qwen36 each spent 4,800 tokens and returned an
   **empty reply**. For short, format-sensitive work the direct-answering models are the better tool.
3. **gpt-oss is mis-served on this build**, not (necessarily) weak: its analysis channel leaks into the
   content field. Re-measure it after the template is fixed.

### Traps this run produced, all caught by the harness testing itself

- **A thinking model needs budget or you are measuring the ceiling.** qwen3 scored 80.2 on the first
  pass and 93.8 on the same items with three times the headroom. Every category that truncated was re-run
  for **all** models, and `finish_reason == length` is recorded per item as `budget_exhausted`.
- **Never re-grade from a stored reply that was truncated.** Truncating replies at 1,200 characters for
  storage, then re-grading them offline, silently flipped six items and invented a 4-point regression.
  Replies are now stored whole.
- **The `ANSWER:` contract makes a code answer appear twice.** The first extractor concatenated both
  copies and reported `SyntaxError` — a harness bug that looks exactly like a model that cannot code.
  The extractor now cuts at the marker.
- **A cleanup glob ate the task suite.** `Remove-Item bench\eval-*.json` matched `eval-suite-v1.json`
  and deleted the 36 items. The suite is now `bench/capability-suite-v1.json`, which no result glob
  matches, and `llm-selftest.ps1` checks it parses, has unique ids and gives every code item tests.

## 11. Depth: does the window stay fast when it is full? (2026‑11‑12 21:56)

The context ceilings from §7 were measured on an empty window, and so was every t/s figure in this
project. That is a statement about a configuration, not about a session: attention reads more bytes
per token the more tokens are already in the cache.

`bin/llm-stability.ps1` (new) fills each preset to 25 % and 60 % of its own `Ctx` and reads decode
speed from `timings.predicted_per_second` with `cache_prompt: false`; 7 models, 44 rows in
`llm/bench/stability-at-depth.csv`. The 512-token baseline is taken **before and after** the deep
runs and every ratio uses the mean of the two, because this laptop's clock drifts 8–16 % in five
minutes (1627 MHz idle, ~2500 MHz under load at 68 °C, 2287 MHz at 75 °C). `bin/llm-stability-report.ps1`
rebuilds the table from the CSV with no GPU, so no digit in the documents is hand-typed.

| model | window | empty | 60 % of window | verdict |
|---|---|---|---|---|
| `gptoss` | 24576 | 27.4 t/s | 14718 tok → **25.5** t/s (93 %) | holds |
| `coder36` | 32768 | 40.0 t/s | 19594 tok → **37.1** t/s (93 %) | holds |
| `qwen36` | 20480 | 38.4 t/s | 12259 tok → **29.7** t/s (77 %, 85 % vs the post-run clock) | softens |
| `flint` | 49152 | 34.3 t/s | 29370 tok → **28.9** t/s (84 %) | softens |
| `qwen3` | 16384 | 53.2 t/s | 9813 tok → **43.6** t/s (82 %) | softens |
| `coder` | 32768 | 61.2 t/s | 19614 tok → **48.9** t/s (80 %) | softens |
| `gemma4` | 131072 | 84.8 t/s | 78291 tok → **52.7** t/s (62 %) | breaks near the top |

**Nothing in the registry changed**: every `Ctx` still loads, answers and holds a usable speed. What
changed is the guidance — `gemma4` at 32k for interactive work, 131k for one-shot long-document
passes; the MoE models are flat enough to use their whole window.

Two tool defects surfaced and are fixed (details in `GUIDE.md` §10, traps 21–22 and `progress.md`
bug 11–12):

1. `serve-model.ps1` re-derived `--n-cpu-moe` from the GGUF geometry for a registry key — flint was
   served at 38 instead of 40, which loads at 16384 and cannot serve its 49152 window. Registry keys
   now inherit `Ctx`, `CpuMoe`, `Threads`, `Port`, `Alias`; geometry is only for unknown files.
2. `llm-server.ps1` warned about a "19.7 GB KV cache" for gemma-4 at 131072 from a 7B-calibrated
   constant; the real cost is 2.3 GB, because five of six layers are sliding-window. `llm-plan.ps1`
   now reports `KvBytesPerToken` from the header (with its source), and the warning may not contradict
   a window the registry already serves.

**Open:** `Ctx` is a ceiling, not a recommendation. The evidence argues for a second field
(`CtxComfort`, the point where decode is still ≥ 80 %), but nobody has decided the cut, and the
launcher would have to honour it.