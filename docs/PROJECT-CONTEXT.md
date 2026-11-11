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
