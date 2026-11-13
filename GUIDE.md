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
`ggml-org/llama.cpp` releases, installed at `%USERPROFILE%\Desktop\Local-LLM-Project\llama.cpp`. It already contains
`qwen35moe` (checked by grepping `llama.dll`), so it runs every model in this repository.

## 3. The invariant: one registry, everything else derived

`bin/llm-up.ps1` holds a table named `$Models`. It is the **single source of truth**:

```
key = @{ File = '<name in models\>'; Port = 8083; Alias = '<openai model id>'; Ctx = 131072;
         CpuMoe = 0; Threads = 20; Note = '<what it is and how fast, one line>'; Kv = 'q8_0' }
```

`Kv` is optional and defaults to `f16`. It exists for one model: `dsv2` stores 276 KB of KV per
token, so at f16 its window dies at 10240 while `-ctk q8_0 -ctv q8_0` holds 18432 — and runs *faster*
there (65.1 vs 58.0 t/s), because attention then reads half the cache. Do not set it by default: at
an equal window q8_0 measured 5.4 % slower on `qwen3`.

Every other artefact is generated *from* it, and the scripts that need it **regex it out of the file
text** rather than importing it (a deliberate choice: `llm-up.ps1` also has side effects, so dotting
it in would start a server).

```
bin/llm-up.ps1  ──registry──┬─→ presets\<key>.cmd        (bin/llm-desktop.ps1)
                            ├─→ Desktop\Local-LLM-Project\llama.cpp\*   (bin/llm-desktop.ps1)
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
| `bin/llm-eval.ps1` + `bin/llm-eval.py` | **the capability battery**: 36 graded tasks, eight categories, Wilson intervals. `-Report` re-aggregates without running anything |
| `bench/eval-suite-v1.json` | the items themselves, with gold answers so the grader can prove itself |
| `bench/eval-<key>.json` | every item: verdict, raw reply, finish reason, tokens, seconds |
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
   working — that is exactly how qwen36 lost 24576 and had to be set to 20480 (it now serves 40960 at
   `--n-cpu-moe 31`, widened once the tool catalog proved to be the real user of its window).
3. **Speed** — tokens/s from the server's own `--metrics` on that same 250–300 token generation,
   with `-fa on -ctk f16 -ctv f16`, `-ngl 99`, `-t/-tb` at 16 or 20.
4. **Capability** - `llm-eval.ps1` runs 36 items over eight categories and grades every one by program
   (exact value, regex, JSON schema, or *executing* unit tests). No judge model. The grader is tested
   against its own gold answers before any model runs, and CI re-tests it on every push.
5. **Depth** — `llm-stability.ps1` fills the window to 25 % and 60 % of that model's `Ctx` and
   reads decode t/s from the server's own `timings.predicted_per_second` with `cache_prompt: false`.
   The 512-token baseline is measured **before and after** the deep runs and every ratio is taken
   against the midpoint, because the clock on this laptop moves 8-16 % in five minutes and a deep
   run compared to whichever bookend was colder invents a depth penalty (or a depth bonus) that is
   not there. `llm-stability-report.ps1 -Markdown` rebuilds the README table from the CSV without
   a GPU and without a hand-typed digit.
6. Everything lands in `bench/*.csv` and `bench/eval-*.json`. If a number is in the README, there is a file
   behind it.

**Never** quote `/health` as proof that a model works, and never extrapolate a context ceiling from
free VRAM. Both have already produced wrong answers here.

Two more rules that the capability run made obvious, and they apply to every measurement here:

- **Give a thinking model room, or you are timing its budget, not its ability.** At 1800 output tokens
  the models that reason first scored 13 points below what they scored when the same items were re-run
  with three times the headroom - qwen3 went from 80.2 to 93.8 on identical questions. Record
  `finish_reason`, count the truncations, and re-run the affected categories for *every* model rather
  than explaining the difference away afterwards.
- **A benchmark tool is code, and its bugs look like findings.** A rule written as `lines==3` instead of
  `lines`, a JSON parser that sliced from the first brace to the last and so failed on any trailing
  prose, and a cleanup glob (`eval-*.json`) that deleted the task suite itself - all three happened in
  one evening, and all three were caught by testing the tool against its own gold answers.

## 6. What is measured today

| key | model | file on disk | ctx (measured) | t/s | port | `--n-cpu-moe` | tool calls |
|---|---|---|---|---|---|---|---|
| `gemma4` | Gemma 4 E4B, UD-Q4_K_XL (QAT) | 3.93 GB | 131072 | 74.1 | 8083 | 0 | yes |
| `flint` | FLINT 40B MoE, nvfp4 | 21.29 GB | 49152 | 29.8 | 8080 | 40 | yes |
| `qwen3` | Qwen3-8B Q4_K_M | 4.68 GB | 16384 (20480 OOM) | 59.0 | 8081 | 0 | yes |
| `coder` | Qwen2.5-Coder-7B Q4_K_M | 4.36 GB | 32768 | 50.3 | 8081 | 0 | **no** |
| `dsv2` | DeepSeek-Coder-V2-Lite MAPLE Sub5GB | 4.50 GB | 18432 (q8_0 KV) | 65.1 | 8086 | 0 | **no** |
| `gptoss` | gpt-oss-20b MXFP4 | 11.28 GB | 32768 (24576 before) | 30.8 | 8082 | 15 | **no** |
| `qwen36` | Qwen3.6-35B-A3B-MTP UD-Q4_K_S | 19.92 GB | 40960 | 35.3 | 8084 | 31 | yes |
| `coder36` | Qwen3.6-27B-A3B-Coder Q4_K_M | 14.95 GB | 57344 | 32.6 | 8085 | 30 | yes |

Both Qwen3.6 windows were widened on 2026-11-13 (20480 → 40960, 32768 → 49152) once the tool catalog
turned out to eat 61 % and 38 % of them; the speed column is the A/B median from
`bin\llm-window-ab.ps1`, not a single-shot sweep. At 49152 the `coder36` floor moved: 27 is a CUDA
OOM, 28 loads, 29 was shipped that night.

Then on 2026-11-14 every model was re-swept and re-A/B'd, which moved three things: `coder36` to
57344 (`--n-cpu-moe 30`, 8192 more tokens for 1.3 % — inside the noise), `gptoss` to 32768
(`--n-cpu-moe 15`, 0.0 % over six loads), and `dsv2` arrived. `qwen36` and `flint` were offered larger
windows and refused them: 49152/32 cost `qwen36` 14.8 % and 57344 cost `flint` 13.8 %.

`coder36` was finished on 2026-11-12; §7 is the record of how, including the two tools it exposed.
It is the fastest model here that still handles 32k of context, and the only one whose file is
**proved** byte-identical to its source rather than matched by size.

## 7. How the seventh model was finished (2026-11-12, 02:20)

This is the worked example of the recipe in §9, including the parts that went wrong, because that is
what a cold agent actually needs.

**The model.** `ManniX-ITA/Qwen3.6-27B-A3B-Coder-MTP-GGUF`, `Q4_K_M`, **16,057,050,592 bytes
exactly**, publisher's sha256 `baf6dfd9eb22799143ae96c89ddb2971733e2f3029783685e18c873c576457de`.
An expert prune of Qwen3.6-35B-A3B: 256 → **184 experts**, top-**10** routing baked in, 26.66 B total,
~3 B active, architecture string `qwen35moe` (which b12255 already supports — check that *before*
downloading 15 GB).

**Getting the bytes was the hard part.** The link (WARP on) ran at 0.03–2.1 MB/s. Facts established by
measurement, not assumption:

| what | measured |
|---|---|
| `hf download` | stalls at 0 bytes on this link while `curl` to the same URL proceeds |
| one connection | 2.0 MB/s |
| 8 connections, 20 MB ranges | 3.9 MB/s |
| 16 connections | 4.05 MB/s — the link saturates here |
| 8 connections, **1.87 GB** ranges | 0.33 MB/s, and eight of them sat at 0 bytes for 3 minutes |

So the problem was **range size, not parallelism**. Final transfer: **174 chunks of 64 MB, 8 workers**,
stitched with a streamed `.NET` copy, hashed, renamed. The first 4.38 GB from an earlier single-stream
attempt was reused (`-C -`), not re-downloaded.

**The measurements, in the order they were taken:**

| question | answer |
|---|---|
| `--n-cpu-moe` floor at 16k | 28 → 33.9 t/s, **26 → 45.0 t/s**, 24 → real CUDA OOM (`failed to allocate CUDA0 buffer of size 360583296`) |
| context ceiling | `llm-maxctx` *extrapolated* 28672; `llm-ctxgrow` trial-loaded **32768** (34816 fails its first completion) |
| re-checked at 32768 | 26 → **44.4 t/s**, 28 → 43.6, 30 → 35.2 — the floor does not move when the context grows |
| re-checked at 49152 (2026-11-13) | 27 → CUDA OOM, 28 → 33.2, 29 → 39.7 t/s single-shot; the A/B median is **32.6**. Here the floor *did* move: the window doubled, so two more layers had to leave the card |
| tool calls | native `tool_calls`, verified with a real `get_weather` request |
| VRAM at 32k | 7.38 GB of 7.96 GiB, load 12.2 s, 49 °C |

**It thinks before it answers, and that changes what a user feels.** Same coding prompt, 28k context:

| configuration | speed | wall time | reasoning |
|---|---|---|---|
| default (top-10 routing) | 37.2 t/s | 35.7 s | 4403 chars before the first line of code |
| `--reasoning-budget 512` | 41.1 t/s | **20.3 s** | 2157 chars |
| `--override-kv qwen35moe.expert_used_count=int:8` | **43.6 t/s** | 28.3 s | 3817 chars |

The preset ships the model author's own top-10 routing and no thinking cap; both knobs are documented
because the speed gain of 8 experts is real but its quality cost was never measured, and this
repository does not ship numbers it cannot defend.

**Two tools were broken by this model, and both are fixed:**

1. `bin/llm-ncmoe-sweep.ps1` declared `[string]$Values` and then reassigned it to the split array — but
   a parameter's type constraint survives the whole scope, so the array was coerced straight back into
   `"26 28 30"` and the loop ran once, sweeping one bogus configuration. Every multi-value sweep ever
   run with that tool was wrong. The split now goes into `$targets`.
2. `bin/llm-scenarios.ps1` kept its own maps of filename, port and alias instead of reading the
   registry, so it reported coder36 as "not downloaded" while the file sat in `models\`. It now parses
   the registry like everything else.

Both are instances of the same lesson: **one source of truth, or the copies drift.**

## 8. The state of the repository right now, and how to re-verify it

Eight models, all measured, all in the registry, the catalogue, `presets\`, the launcher and the
README. `main` is released as **v1.5.1**; the 2026-11-14 window pass and `dsv2` are in it.

```powershell
cd C:\Users\fih\llm

# is everything consistent?
pwsh -NoProfile -File .\bin\llm-selftest.ps1        # 7 checks: scripts, registry<->catalogue, presets, launcher

# does the model actually work, end to end, including a tool call?
pwsh -NoProfile -File .\bin\llm-verify-bundle.ps1

# does it still hold its speed with the window full? (~16 min, loads all seven)
pwsh -NoProfile -File .\bin\llm-stability.ps1
pwsh -NoProfile -File .\bin\llm-stability-report.ps1 -Markdown   # table from the CSV, no GPU

# what does the launcher see?
& "$env:USERPROFILE\Desktop\Local-LLM-Project\llama-direct.exe" --list

# re-measure one model's split or ceiling
pwsh -NoProfile -File .\bin\llm-ncmoe-sweep.ps1 -Model .\models\<file>.gguf -Values '26 28 30' -Ctx 32768
pwsh -NoProfile -File .\bin\llm-ctxgrow.ps1 -Model <key> -Candidates '28672,32768,34816'
```

`bench\` holds the CSVs behind every one of those numbers: `ncmoe-coder36.csv`,
`ncmoe-coder36-at-28k.csv`, `ncmoe-coder36-at-32k.csv`, `ctxgrow-coder36.csv`, `maxctx-coder36.csv`,
`stability-at-depth.csv`.

**Open, in priority order:**

1. Does the **MTP head** help? Both `-MTP` models ignore it today (the engine logs the `nextn`
   tensors as unused). `bin\llm-speccmp.ps1` is the tool; nobody has run it on them.
2. **flint vs qwen36 head-to-head** on the same prompts — the repository has both at 30 and 34 t/s but
   no answer to "which one should I actually use".
3. Whether `--reasoning-budget` should become a preset default. It halved wall time on a coding
   prompt; it also removes thinking the model might have needed. That is a judgement call, not a
   measurement.
4. **`Ctx` is a ceiling, not a recommendation.** The depth sweep shows gemma4 at 62 % of its empty
   speed at 78k tokens while `gptoss` and `coder36` do not move. That argues for a second field —
   `CtxComfort` — per model, chosen as the point where decode is still ≥ 80 %. Nobody has decided
   where that cut belongs, and the launcher would have to honour it.

## 8b. Tools the models can call (REA), and what is verified

`llama-server` here has `--mcp-servers-config`. That is now used: `mcp\rea-mcp.json` declares REA as
an MCP server, and every preset whose registry entry carries `Mcp = 'rea'` passes it. `llama-server`
spawns REA over stdio at startup to list its tools, stops it, and respawns it per call — so the
tools are `rea_*` on `GET /tools` and in the Web UI, and an idle chat pays nothing for them.

Three files hold this, in the order they matter:

| file | role |
|---|---|
| `bin\llm-mcp.ps1` | resolves Node, `rea-agents`, a JDK ≥ 21 and Ghidra, writes `mcp\rea-mcp.json`. **Generated, never hand-edited** — a moved path is the only failure mode that looks like "the tools are gone" |
| `mcp\rea-mcp.json` | the definition itself; `timeout_ms` 450000 because a cold Ghidra start may take 330 s |
| registry `Mcp = 'rea'` | decides which presets get the flag; `llm-desktop.ps1` and `llm-direct.ps1` both read it, the selftest checks preset parity |

**Measured, per model, with the real preset plus the real config** (2026-11-13): all seven start and
list REA's tools. Four complete a tool loop — `gemma4`, `qwen36`, `flint`, `coder36`. `coder` writes
`<json>{"name":...}</json>` as text and `gptoss` leaks Harmony markup, so those two deliberately
carry no `Mcp` field; both still load fine, they just have nothing to call. `qwen3` does call tools
but cannot carry the catalog: 39 tools are 12 402 of its 16 384 tokens. Load times land within a
second of the numbers without MCP (9.2 s gemma4 … 32.8 s flint), so the feature costs nothing at
startup on this machine.

Re-verify without loading all seven:

```powershell
pwsh -NoProfile -File .\bin\llm-mcptest.ps1 -Model gemma4   # fit + a real call + POST /tools
curl.exe -s http://127.0.0.1:8083/tools | Select-Object -First 1        # 39 rea_* entries
```

Traps worth knowing, all three found the hard way:

- **The catalog is not free once a chat selects tools.** Every selected tool's schema goes into the
  request, and all 255 are 85 098 prompt tokens — the exact reason v1.2.0's Web UI answered with
  `request (85210 tokens) exceeds the available context size (32768 tokens)`. The default scope is
  now `session,enhanced` (39 tools, 12 402 tokens); `bin\llm-ctxfit.ps1` is the arithmetic, and the
  self-test fails if a preset cannot hold its catalog with half its window left.
- **A scope change needs a server restart.** `llama-server` reads `mcp\rea-mcp.json` once, at startup.
- **`Mcp` sits *after* `Note` in the registry line, on purpose.** Every generator matches the entry
  with one regex ending `(?:;\s*Note\s*=\s*'[^']*')?(?:;\s*Mcp\s*=\s*'([^']*)')?`; inserting a field
  between `Threads` and `Note` breaks the capture silently and the presets lose the flag.
- **Budget the catalog by the tool, not by the family.** Measured 2026-11-13: 318 prompt tokens per
  Qwen tool, 221 per Gemma tool, so the 39-tool default is 12 402 / 8 604 and a hand-picked core of
  eight is ~2 500. The Web UI's picker is per chat and sends only what is ticked — that is the free
  lever, and it is the one to reach for before changing a window.
- **`REA_MCP_TOOL_CATALOG_PROFILE=hot-cold` does not work with this client.** It advertises five
  tools (binary_session, open_binary, close_binary, get_evidence_bundle, discover_tools) for 1 678
  tokens — an 81 % cut — but `llama-server` ignores `notifications/tools/list_changed` and respawns
  REA per call, so a discovered tool never becomes callable. Verified on `gemma4` 2026-11-13: the
  model called `discover_tools` correctly and `GET /tools` still returned five. Do not ship it as a
  context saving; it only fits chats that need nothing beyond open/session/evidence.
- **A wider window is not automatically slower.** `bin\llm-window-ab.ps1` alternates the two
  configurations (`-ACtx/-ACpuMoe` vs `-BCtx/-BCpuMoe`) so thermal drift lands on both arms, warms
  the card with a discarded generation, and reports medians. Single-shot sweeps on this laptop
  disagree with themselves by 30 %: the same 20 480 configuration measured 34.6 and 23.5 t/s in
  consecutive rounds.

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
16. **A parameter keeps its type constraint for the whole scope.** `param([string]$Values)` followed
    by `$Values = @($Values -split ...)` does not produce an array — it produces the array coerced
    right back into `"26 28 30"`, so `foreach` runs **once** over that string. This silently broke
    every multi-value `llm-ncmoe-sweep.ps1` run until 2026-11-12; the split now lands in `$targets`.
    If you need a value to change type, rename the variable.
17. **Keep no second copy of the registry.** `llm-scenarios.ps1` had its own switch blocks for
    filename/port/alias, so a newly registered model was reported "not downloaded" while it sat in
    `models\` and served fine. If a script needs the file name, port or alias, it parses
    `llm-up.ps1` — that is the rule, and the self-test only checks some of the files that follow it.
18. **A `param()` default cannot call a command.** `[string]$X = Join-Path $a b` is a parse error
    ("missing expression after '='") because defaults are expressions, not statements. Use
    `"$env:USERPROFILE\..."`, or compute it in the body.
19. **A rebuild that cannot write its output used to look successful.** With the launcher window open,
    Windows locks the exe, `csc` fails with "cannot write output file", and the old `Test-Path` guard
    passed anyway - so the script printed "built" over the *previous* binary and the fix appeared
    applied. `llm-direct.ps1` now compiles to a staging path, checks the timestamp, and refuses to
    claim success while the window is open.
20. **`-Only a,b,c` binds as an array, and `[string]` refuses it.** Call a script with unquoted commas
    and a `[string]` parameter throws "cannot convert System.Object[]"; call it through `pwsh -File`
    and the same parameter arrives as one string. Declare `[string[]]` and normalise with
    `($P -join ',') -split '[,\s]+'` so both call styles work.
21. **A launcher that re-derives tuned flags serves something the registry never measured.**
    `serve-model.ps1` took a registry key, then derived `--n-cpu-moe` from the GGUF geometry instead
    of from the registry: flint was served at **38** where the repository says **40**, which loads at
    16384 and cannot serve its own 49152 window. Nothing failed at launch — the stability run simply
    sat on a dead port until a timeout. Registry keys now inherit `Ctx`, `CpuMoe`, `Threads`, `Port`
    and `Alias`; derivation is only for models the registry has never seen. The stability harness
    now parses the served `ncmoe=`/`ctx=` back out of the launch log and complains if it disagrees.
22. **A hardcoded KV estimate is a guess with a decimal point.** `llm-server.ps1` carried
    `1.5e-4 GB/token`, calibrated on a 36-layer, 8-KV-head 7B, and warned that gemma-4 needed
    "3.9 GB + KV 19.7 GB" at 131072 — where it really costs **2.3 GB** and loads in 13 s, because
    five of every six of its layers are sliding-window and never keep the full cache. Two fixes:
    read the geometry from the header (`llm-plan.ps1` now reports `KvBytesPerToken` and where it came
    from), and let measurement outrank arithmetic — if the registry already serves that file at that
    context, the estimate is not allowed to say it will not fit.
23. **A model can load, answer, and still be wrong.** `dsv2` serves 65.1 t/s at 18432 and scores
    **17.7 %** on the capability suite; every load probe passes, every `/health` says ok, and the only
    thing that catches it is `bin\llm-eval.ps1`. Speed measurements do not test a quantised model's
    quality, and a Hugging Face card claiming "~93 % retained" is a claim about *their* benchmark.
    Run the suite before a new model goes in the README table, and put the score in the table row.
24. **`-ctk q8_0` is not always the slow choice.** The rule "f16 is 25-35 % faster" holds at an equal
    window on models whose cache fits (`qwen3`: 55.5 vs 52.5). When the cache is what stops the window
    (`dsv2`: 276 KB/token), halving it serves a 2.25x larger window *and* runs 12.2 % faster, because
    attention reads half the bytes. Measure both arms; the direction is not a constant.
25. **A registry field the generators do not know about is silently dropped.** Adding `Kv` took four
    edits: `llm-up.ps1` (serve), `llm-desktop.ps1` (preset writer *and* the parsing regex),
    `llm-direct.ps1` (the compiled launcher list) and the regex group order. The preset is the proof:
    if `presets\dsv2.cmd` does not contain `-ctk q8_0`, the field never arrived.

## 11. House rules (how this repository is written)

- **Numbers over adjectives.** Not "fast" — 35.3 t/s at 40960 context on this laptop.
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
