# progress.md — everything this project has done, first prompt to last

This is the complete record. It is written to be read cold, by a person or an agent who was not here.

- **Machine:** MSI MS-17T4, Intel Core Ultra 7 255HX (20C/20T), 32 GB DDR5-5600, NVIDIA RTX 5060
  Laptop GPU (8151 MiB, sm_120, driver 621.01), Windows 11 build 28000, Turkish locale, **no
  administrator rights**.
- **Repository:** `C:\Users\fih\llm` → https://github.com/zaxsh/local-llm-stack (public, MIT).
- **Bundle:** `C:\Users\fih\Desktop\Local-LLM-Project\llama.cpp` — the double-clickable copy.
- **Timeline covered:** 2026-11-11 21:27 → the present, 14 commits, 5 releases, 7 models.
- **Starting point:** one sentence — *"make the repo better!"* — and an existing repository of
  PowerShell scripts around llama.cpp that had been written quickly and never verified.

---

## Phase 0 — what existed before the first prompt

A repository of ~25 PowerShell scripts that install llama.cpp, download GGUF models, tune
`--n-cpu-moe` and `-c`, and serve them on fixed ports. The measurements in it were a mixture of real
numbers and plausible guesses, several scripts hardcoded `C:\Users\fih`, there was no licence, no CI,
no self-test, and the "Desktop bundle" feature could leave a half-built folder behind and then throw.

The one idea everything rests on was already there and correct:

> **tokens/s ≈ memory bandwidth ÷ bytes read per token.** VRAM on this laptop gives 448 GB/s, DDR5
> gives ~60 GB/s. A dense 8B model in Q4 reads 4.9 GB per token → ~90 t/s ceiling. A 30B MoE with 3B
> active reads ~1.9 GB per token even though it is 18 GB on disk → it fits the same 8 GB card *and*
> beats a dense 14B by 3–5×. That is what `--n-cpu-moe` buys: the expert tensors live in DDR5 and are
> read one hot subset at a time.

---

## Phase 1 — the first pass: make it honest (21:27 → 22:17)

**What was wrong, and what was done about it.**

| finding | fix |
|---|---|
| 13 scripts hardcoded `C:\Users\fih` | every path derived from `$PSScriptRoot` / `$env:USERPROFILE`; a `--list` that works from any clone |
| No licence file GitHub could read (`NOASSERTION`) | plain MIT, no additions |
| The bundle build created the folder, failed midway, and threw | it now checks the machine first and says *why* it cannot continue |
| Nothing could be re-checked by a stranger | `bin/llm-selftest.ps1`, 7 checks: scripts parse, registry ↔ catalogue, presets ↔ registry, launcher builds, `--list` answers |
| No CI | GitHub Actions: self-test + launcher build on every push |
| Nobody knew where to start | `get-started.ps1` — machine check → engine → models → bundle → launch |
| The launcher passed `-m ""models\x.gguf""` | quoting was doubled twice; fixed, and the build now refuses to emit a doubled path |

**Releases:** v1.0.0 (21:50, "the measured stack"), v1.0.1 (22:11, front door + licence + self-test +
CI), v1.0.2 (22:17, no hardcoded user paths).

---

## Phase 2 — "are you sure it is safe and sound?" (two independent passes)

The user asked twice, so the checks were run twice, not asserted:

- `llm-selftest.ps1` → **PASS 7 checks**, including inside the *downloaded release zip* (extracted to
  a temp folder, ran there, exit 0).
- `llm-verify-bundle.ps1` → all six presets: load, answer 300 tokens, call a tool where the model
  supports it, stop, GPU released (192 MB left after each).
- The published artifacts were hashed and the hashes published next to them.
- A trap found in this pass: **PowerShell cannot pipe-capture a Windows-subsystem exe** — the
  launcher's `--list` had to be redirected to a file and read back, which is how the CI check works.

Also fixed here: `$LASTEXITCODE` staying 0 when a child's output is piped into `Select-Object` (a
broken pipe looked like success).

---

## Phase 3 — the seventh model: coder36 (23:09 → 02:33)

**The request:** *add https://huggingface.co/ManniX-ITA/Qwen3.6-27B-A3B-Coder-MTP-GGUF to the system,
with the full process — presets, context, the works.* Then: *the best config; you may try other
download methods — WARP is on, and IDM/Hydra are available.*

**The model.** Qwen3.6-27B-A3B-Coder, Q4_K_M, **16,057,050,592 bytes**. It is an expert prune of
Qwen3.6-35B-A3B: 256 → **184 experts**, top-**10** routing baked in, 26.66 B total, ~3 B active,
architecture string `qwen35moe` (checked against `llama.dll` **before** downloading 15 GB — b12255
already supports it).

**Getting the bytes was the hard part.** The link ran at 0.03–2.1 MB/s. What was measured, not assumed:

| attempt | result |
|---|---|
| `hf download` | stalls at 0 bytes on this link, while `curl` to the same URL proceeds |
| 1 connection | 2.0 MB/s |
| 8 connections × 20 MB ranges | 3.9 MB/s |
| 16 connections | 4.05 MB/s — the link saturates here |
| 8 connections × **1.87 GB** ranges | 0.33 MB/s, and eight of them sat at 0 bytes for three minutes |

Conclusion: **range size, not parallelism, was the problem.** The file came down as **174 chunks of
64 MB, 8 workers**, stitched with a streamed .NET copy, then hashed. The publisher ships a `.sha256`
beside every quant, so the result is *proved* byte-identical — the first model here where provenance
is a proof rather than a size comparison.

**The tuning, in the order it was measured:**

| question | answer |
|---|---|
| `--n-cpu-moe` floor at 16384 | 28 → 33.9 t/s, **26 → 45.0 t/s**, 24 → real CUDA OOM (`failed to allocate CUDA0 buffer of size 360583296`) |
| context ceiling | `llm-maxctx` *extrapolated* 28672 from free VRAM; `llm-ctxgrow` trial-loaded **32768**; 34816 fails its first completion |
| re-check at 32768 | 26 → **44.4 t/s**, 28 → 43.6, 30 → 35.2 — the floor does not move when the context grows |
| VRAM at 32k | 7.38 GB of 7.96 GiB, load 12.2 s, 49 °C |
| tool calls | native `tool_calls`, verified against llama.cpp directly |

**It thinks before it answers**, and that is invisible in a t/s number. Same coding prompt, 28k
context:

| configuration | speed | wall time | reasoning |
|---|---|---|---|
| default (top-10 routing) | 37.2 t/s | 35.7 s | 4403 characters before the first line of code |
| `--reasoning-budget 512` | 41.1 t/s | **20.3 s** | 2157 characters |
| `--override-kv qwen35moe.expert_used_count=int:8` | **43.6 t/s** | 28.3 s | 3817 characters |

The preset ships the author's own top-10 routing and no thinking cap. The other two are documented in
the registry note and in `docs/`, because the speed gain of 8 experts is real but its quality cost was
never measured, and this repository does not ship numbers it cannot defend.

**Two tools were broken by this model, which is the only way that kind of bug surfaces:**

1. `bin/llm-ncmoe-sweep.ps1` declared `[string]$Values` and then reassigned it to the split array — but
   a parameter keeps its type constraint for the whole scope, so the array was coerced straight back
   into the string `"26 28 30"` and the loop ran **once**, sweeping one bogus configuration. Every
   multi-value sweep in the project's history had been wrong. The split now goes into `$targets`.
2. `bin/llm-scenarios.ps1` kept its own filename/port/alias maps instead of reading the registry, so it
   reported a registered, working model as "not downloaded". It parses `llm-up.ps1` now.

**Release:** v1.1.0 (02:33) — "the seventh model, and two tools that were lying". 82 tracked files,
CI green, three assets (launcher exe, source zip, SHA256SUMS).

---

## Phase 4 — the launcher shows the actual file name (03:00)

The launcher listed a model's pretty title and a one-line description, and **never the file name** —
so a download folder full of `.gguf` files could not be matched to the list by eye. Worse, the list of
titles was a second hardcoded copy of the registry: a newly registered model appeared as the bare key
`coder36` with no description.

Fixed:

- every row now shows **title, then the full `.gguf` file name in monospace, then the description**;
- a model missing from the title map falls back to its registry alias and its registry note, never to
  the bare key;
- the window grew from 500×500 to 500×548 to fit the third line;
- and the build became honest: it compiles to a staging path, verifies the timestamp, and says so if
  the launcher window is open and the file is locked. Before this, `csc` failed, the old `Test-Path`
  guard passed, and the script printed "built" over the **previous** binary — a fix that looks applied
  and is not.

---

## Phase 5 — one folder on the Desktop (03:05)

Everything the project had left on the Desktop was scattered: four documents, a results CSV, eight
numbered `.cmd` shortcuts, the launcher exe, and a 76-file `llama.cpp` bundle.

All of it now lives in **`C:\Users\fih\Desktop\Local-LLM-Project\`**, which is the only thing left on
the Desktop:

```
Local-LLM-Project\
├─ llama-direct.exe     the launcher (shows every model with its full file name)
├─ llama.cpp\           the bundle: engine, 7 models (hard links), presets, START HERE.cmd, stop.cmd
├─ launchers\           the numbered shortcuts
├─ docs\                how-the-numbers-were-made, local-llm-report, eval-intelligence, connecting-*
├─ results\             every raw CSV and JSON behind the numbers
├─ GUIDE.md             the engineer's handover (17 → 20 traps)
├─ PROJECT-CONTEXT.md   the project record
├─ progress.md          this file
└─ README-START-HERE.md the one-minute version
```

The scripts were repointed so nothing regenerates into the old places: `llm-desktop.ps1`,
`llm-direct.ps1`, `llm-verify-bundle.ps1`, `get-started.ps1` all default to the new bundle path, and
`llm-scenarios.ps1` writes its report and CSV into the new docs/results folders. The launcher resolves
`llama.cpp` next to itself, so it kept working without a single change to its search logic.

---

## Phase 6 — measuring intelligence, not just speed

Speed was measured in every phase above. Capability was not. This phase builds and runs a battery
that scores what each model can actually *do*, with every answer graded by a program.

**The design decisions, and why:**

1. **No judge model.** A judge model is another model with its own biases, and at 36 items its noise
   would swamp the signal. Every item is graded by exact match, regex, JSON schema, or by *executing*
   the model's code against unit tests.
2. **A fixed token budget per item, identical for all seven models.** Otherwise the models that think
   before answering get a different budget from the ones that do not, and the comparison is
   meaningless. Token use is recorded per item.
3. **Answer extraction is part of the contract.** Prompts end with *"finish with a final line of
   exactly this form: ANSWER: <your answer>"*, and code items ask for one fenced block. A model that
   reasons correctly but rambles still scores.
4. **The grader is tested before any model runs.** `--self-test` feeds each item its own gold answer
   and requires the grader to accept it. This found a real bug on the first run (a constraint rule
   written as `lines==3` instead of `lines`), which would otherwise have silently zeroed one category
   for every model.
5. **Per-category scores, not one number.** A model can win on knowledge and lose on instruction
   following; one aggregate would hide exactly the information the run was paid for.
6. **Wilson confidence intervals.** 5/6 is not "83 %". At n=6 per category the interval is wide, and
   the report says so rather than implying a precision the sample cannot support.

**The eight categories (36 items, `bench/capability-suite-v1.json`):**

| category | n | what it tests | how it is graded |
|---|---|---|---|
| `math` | 6 | multi-step word problems | exact number after `ANSWER:` |
| `logic` | 5 | syllogism, ordering, calendar, knights/knaves, inclusion–exclusion | exact option letter |
| `code` | 4 | four functions (words, palindrome, fibonacci, interval merge) | **unit tests executed** in a subprocess |
| `instr` | 6 | IFEval-style constraints: exact line count, exact word count, all caps, JSON only, regex shape | predicate list, all must pass |
| `json` | 3 | field extraction from messy text | schema + value equality |
| `needle` | 3 | a passphrase hidden at 15 %, 55 % and 90 % depth of half the model's own context | exact substring |
| `tools` | 3 | two tools, three requests | native `tool_calls` name + arguments |
| `knowledge` | 6 | stable facts, four-way multiple choice | exact letter |

**What the literature says about doing this honestly** (and what was applied):

- IFEval (arXiv 2311.07911) — verifiable instruction constraints beat human judgement at this scale;
  used as the model for the `instr` category.
- RULER (2404.06654) — multi-needle retrieval over a scaled haystack; this is why the needle depth
  scales with each model's own context rather than a fixed size.
- "Adding Error Bars to Evals" (2411.00640) — reports must carry Wilson intervals; applied.
- HELM (2211.09110) and The Leaderboard Illusion (2504.20879) — a single aggregate hides trade-offs
  and invites weighting games; rejected in favour of a per-category profile.
- Contamination (GSM1k, 2405.00332; MMLU slot-guessing, 2311.09783) — published benchmarks are in
  every pretraining set, so these items were **written for this repository** rather than sampled from
  a public suite. The answer key is in the repository and auditable.
- Nondeterminism (2506.09501) — batch size and KV settings can move reasoning scores by several
  points, so every model runs with its own registered flags, unchanged, and the exact server command
  line is recorded beside the results.

**What actually happened, in order** (times are real, from this machine):

| when | what |
|---|---|
| 03:05 | first full run started |
| 03:10 | stopped it: gemma4's raw replies showed the code items were truncated mid-docstring at 900 tokens, and the JSON parser failed on a trailing fragment. The grader was fixed (brace-walking `raw_decode`, code budget 1600). |
| 03:16 | second run started — and died immediately: `Remove-Item bench\eval-*.json` matched `eval-suite-v1.json` and **deleted the 36-item suite**. Rebuilt it as `bench/capability-suite-v1.json`, which no result glob matches. |
| 03:23 | third run started, clean: 36 items × 7 models, base budgets |
| 04:32 | finished. Every model had a score, and three of them had hit the token ceiling repeatedly |
| 04:36 | "headroom pass": `code`, `json`, `needle`, `tools` re-run for **all seven** at 3× budget (uniform, so still comparable) |
| 05:28 | headroom pass finished: qwen3 80.2 → 93.8, flint 76.3 → 80.4, coder36 70.8 → 78.1, qwen36 62.5 → 74.0 |
| 05:29 | flint answered "ANSWER: 1945" instead of "(C)". The choice grader demanded a letter; fixed to accept an option's text when exactly one option matches |
| 05:30 | **own mistake**: re-graded stored replies offline. Replies had been truncated at 1,200 characters for storage, so the `ANSWER:` line was missing from the long ones and six items flipped to wrong. Re-ran `logic` and `knowledge` live for all seven instead. Replies are now stored whole. |
| 06:00 | coder36's `code-4` reported `SyntaxError` — the reply contained the function twice (once in a fence, once after `ANSWER:`), and an unclosed fence concatenated both. Extractor now cuts at the marker. Re-ran `code` for the two thinking models. |
| 06:10 | five models wrote `"#A-1187"` for the order id and the key demanded `"A-1187"`. Five of seven agreeing means the key is wrong: added identifier normalisation, re-graded the short JSON replies (all under the truncation point) and re-ran gpt-oss's. |

**The results** (36 items each, uniform budgets per category, 2026-11-12):

| model | macro | math | logic | code | instr | json | needle | tools | knowledge | budget hits |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| flint | 100.0 | 6/6 | 5/5 | 4/4 | 6/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| gemma4 | 97.9 | 6/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| qwen3 | 97.9 | 6/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| coder | 95.8 | 5/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| coder36 | 85.4 | 5/6 | 5/5 | 2/4 | 5/6 | 3/3 | 2/3 | 3/3 | 6/6 | 5 |
| qwen36 | 78.1 | 6/6 | 5/5 | 1/4 | 2/6 | 3/3 | 2/3 | 3/3 | 6/6 | 8 |
| gpt-oss | 67.7 | 6/6 | 5/5 | 1/4 | 1/6 | 3/3 | 3/3 | 0/3 | 6/6 | 5 |

**Three findings worth more than the ranking:**

1. **Speed and capability are not related here** — rank correlation 0.2 across the seven. The slowest
   model (flint, 29.8 t/s) is the best; the fastest (gemma4, 74.5 t/s) is second; the second slowest
   (gpt-oss) is last. Speed is bytes-per-token; capability is weights and serving.
2. **The bottom three are the three that reason before answering.** They hit their output ceiling on 5,
   8 and 5 items. On `code-2` (`is_palindrome`) coder36 and qwen36 each burned their entire 4,800-token
   budget and returned an **empty reply** — not a wrong function, no function. For short,
   format-sensitive work the direct-answering models are simply the better tool on this hardware.
3. **gpt-oss is mis-served, not proven weak.** Its analysis channel leaks into the content field
   (`"Paris\nWe have a conversation: user says..."`), so `instr` 1/6 and `tools` 0/3 measure this
   build's template. Its row should be re-measured after that is fixed.

**And the honest caveats**, which are in `docs/capability-evaluation.md` as well:

- coder36 (5), qwen36 (8) and gpt-oss (5) still hit the ceiling on some items — their rows are **floors**,
  not measurements.
- Six items per category means the 95 % interval is roughly ±30 points at the extremes. flint and gemma4
  being 2 points apart is a tie, and the battery is too easy at the top: every model scores 5/5 logic and
  6/6 knowledge.
- One run per model, so there is no empirical variance estimate.

**Files this phase added:** `bin/llm-eval.ps1`, `bin/llm-eval.py`, `bin/llm-eval-report.py`,
`bin/llm-toolmode.ps1`, `bench/capability-suite-v1.json`, `bench/eval-<model>.json` (raw replies and
verdicts), `bench/eval-summary.csv`, `docs/capability-evaluation.md`. CI now runs
`llm-eval.py --self-test` on every push, and `llm-selftest.ps1` checks the suite file itself.

---

## The bug ledger

Every one of these was found by *using* the thing, not by reading it.

1. Registry drift in `llm-scenarios.ps1` — its own filename/port/alias maps; a registered model was
   reported "not downloaded".
2. `[string]` parameter coercion in `llm-ncmoe-sweep.ps1` — every multi-value sweep swept one bogus
   value. Found by a sweep row that read `crashed` with zero tokens.
3. Launcher quoting doubled twice — `-m ""models\x.gguf""`.
4. `Test-Path` as a build guard — a locked exe made a failed compile look successful.
5. `param()` defaults cannot call commands (`Join-Path`) — a parse error that only appears when you
   run the file, not when you edit it.
6. `-Only a,b` binds as an array; `[string]` refuses it. Fixed with `[string[]]` + normalisation.
7. `Tee-Object` does not capture `Write-Host`, so a sweep log held the table and not the errors.
8. `[System.IO.File]::ReadAllText` resolves relative paths against the *process* directory
   (`C:\WINDOWS\system32`), not the current location. Absolute paths everywhere for .NET APIs.
9. `Select-String -SimpleMatch 'C:\\Users\\fih'` returns false negatives — the pattern is literal.
10. A `Get-CimInstance | Where CommandLine -like '*script*'` filter killed the shell running it;
    always exclude `$PID`.

---

## Where the numbers stand

Seven models, every one measured on this machine, in the registry that generates the presets:

| key | model | file | ctx | t/s | port | n-cpu-moe | tools |
|---|---|---|---:|---:|---:|---:|---|
| `gemma4` | Gemma 4 E4B QAT Q4_K_XL | 3.93 GB | 131072 | 74.5 | 8083 | 0 | yes |
| `coder36` | Qwen3.6 27B-A3B Coder Q4_K_M | 14.95 GB | 32768 | 44.4 | 8085 | 26 | yes |
| `qwen36` | Qwen3.6 35B-A3B UD-Q4_K_S | 19.92 GB | 20480 | 34.0 | 8084 | 30 | yes |
| `flint` | flint 40B NVFP4 | 21.29 GB | 49152 | 29.8 | 8080 | 40 | yes |
| `qwen3` | Qwen3 8B Q4_K_M | 4.68 GB | 16384 | 59.0 | 8081 | 0 | yes |
| `coder` | Qwen2.5 Coder 7B Q4_K_M | 4.36 GB | 32768 | 50.3 | 8081 | 0 | no |
| `gptoss` | gpt-oss 20B MXFP4 | 11.28 GB | 24576 | 30.8 | 8082 | 14 | no |

The end-to-end proof (`llm-verify-bundle.ps1`, 300 tokens each, tool call, GPU released): gemma4 74.5,
coder 52.0, qwen3 58.9, coder36 40.5, qwen36 38.6, gptoss 30.7, flint 29.3 t/s.

---

## What is left

1. **The MTP heads are unused.** Both `-MTP` models log their `nextn` tensors as ignored. Whether
   speculative decoding would help on this card is measurable with `bin/llm-speccmp.ps1` and has not
   been measured.
2. **flint vs qwen36** — the two "big" options — are now compared on the same 36 items (100.0 vs 78.1),
   but qwen36's row is a floor: it hit its budget on 8 items. A run with 3× headroom on `instr` and
   `needle` would settle it.
3. **`--reasoning-budget` as a default.** It halved wall time on a coding prompt and also removes
   thinking the model may have needed. That is a judgement call, not a measurement.
4. **The 36-item battery is a profile, not a ranking.** With six items per category the intervals are
   ±30 points; it separates "broken" from "works", not "good" from "very good". More items per
   category is the cheapest improvement, and the harness takes them without code changes.
5. **`coder` and `gptoss` report no tool calls.** llama.cpp's documentation lists both *Qwen 2.5
   Coder* and *GPT-OSS/Harmony* as native tool-call formats, so this may be a template or `--jinja`
   issue rather than a model limit — worth re-testing before repeating the claim.

---

## How to verify any of this

```powershell
cd C:\Users\fih\llm
.\bin\llm-selftest.ps1                 # 6 checks, including the capability suite
.\bin\llm-verify-bundle.ps1            # every preset: load, answer, tool call, stop
.\bin\llm-eval.ps1 -Report             # re-aggregate the capability results, run nothing
.\bin\llm-eval.ps1 -Models gemma4      # re-measure one model from scratch (~6 min)
.\bin\llm-ncmoe-sweep.ps1 -Model .\models\<file>.gguf -Values '26 28 30' -Ctx 32768
```

Every raw number is in `results\` here and in `bench\` in the repository. Nothing in the documents is
a number that cannot be traced to one of those files.
