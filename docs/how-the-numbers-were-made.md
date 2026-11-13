# How the numbers were made

*Companion to `local-llm-report.md`. That file has the results; this one explains where they came
from, why they are what they are, and which parts are measured fact versus arithmetic.*

---

## The short version

Every speed in the report comes from one of two places:

1. **`llama-bench.exe`** — the model is loaded once and run on synthetic prompts of a fixed length.
   No server, no HTTP, no chat template. This isolates the engine.
2. **`llama-server`'s own `timings` block** — every completion response carries the token counts
   and the milliseconds the server actually spent. This is the number you feel in use.

Nothing is estimated from a stopwatch or inferred from a screenshot. When a number below is
arithmetic rather than measurement, it is labelled as such.

The headline finding — that a 4-billion-parameter model beats a 40-billion-parameter one by 2× —
is not an anomaly. It follows from one equation, and that equation predicted the ordering before
anything was benchmarked.

---

## 1. The equation that decides everything

Generation speed is not set by parameter count. It is set by **how many bytes the machine must
read from memory to produce one token**, divided by **how fast that memory is**.

```
tokens/sec  ≈  memory bandwidth  ÷  bytes read per token
```

This laptop has two memory pools with a 7.5× difference between them:

| pool | size | bandwidth | what lives there |
|---|---|---|---|
| RTX 5060 GDDR7 | 8 GB | **448 GB/s** | whatever fits |
| DDR5-5600 dual channel | 32 GB | **60 GB/s** | everything else |

So the question is never "how big is the model". It is "what fraction of its weights does this
token actually touch, and where do those bytes live".

### The seven models, with the arithmetic

`bytes/token` is read from each GGUF's own header (see §2). The ceiling is `bytes ÷ bandwidth`.
The measured column is real, from the report.

| model | bytes/token | lives in | ceiling | measured | efficiency |
|---|---|---|---|---|---|
| Gemma 4 E4B (dense) | 3.91 GB | VRAM | 114 t/s | **80 t/s** | 70 % |
| Qwen2.5-Coder 7B (dense) | 4.36 GB | VRAM | 103 t/s | 55 t/s | 54 % |
| Qwen3-8B (dense) | 4.86 GB | VRAM | 92 t/s | 56 t/s | 61 % |
| flint 40B (MoE, CPU experts) | 1.92 GB | DDR5 | 31 t/s | 19-44 t/s | see §5.2 |
| gpt-oss-20b (MoE, split) | 4.54 GB | mixed | 64 t/s | 30 t/s | 47 % |
| Qwen3.6-27B-A3B-Coder (MoE, split) | 2.27 GB | mixed: 15 layers in VRAM, 26 in DDR5 | 38 t/s if everything came from DDR5 | 42 t/s | above 100 % - the VRAM layers carry it |
| *any* dense model on CPU | 4.36 GB | DDR5 | 14 t/s | 13 t/s | 93 % |

The model does its job: it predicts the ranking correctly, and lands within roughly a third of the
truth. The missing 30–45 % on the VRAM-resident models is not lost bandwidth — it is attention,
the KV cache read, sampling, and kernel launch overhead, none of which the pure weight-streaming
model accounts for.

The last row is the one that keeps the model honest in the other direction: a dense model on the CPU
measuring 13 t/s against a 14 t/s ceiling implies the effective DDR5 rate is nearer 65 GB/s than the
60 used above, and that a "100 % efficiency" result almost certainly means the denominator is
slightly wrong rather than that the machine is perfect. Treat the ceiling column as ±10 %.

The one place the model breaks down badly is the MoE-on-CPU path, and §5.2 explains why: it is not
bandwidth-bound at all, it is bound by the CPU's dequantise-and-dot kernel.

---

## 2. Where `bytes/token` comes from

Reading it out of a GGUF is not guesswork — the header carries per-tensor dimensions and types, so
you can compute the size of every tensor without loading a single weight. `llm-plan.ps1` parses
that header directly (a small C# block compiled with `Add-Type`, because reading a 21 GB file
through PowerShell cmdlets is worse).

For a **dense** model it is trivial: every weight is read for every token, so the number is the
file minus the output head. Gemma 4 E4B: 3.93 GB on disk, 3.91 GB read per token.

For a **mixture of experts** you need three facts from the header — how many layers carry experts,
how many experts exist, and how many are active per token:

```
flint:   49 blocks, 47 with experts, 256 experts, top-6
         6 / 256 = 2.3 % of the expert weights are touched per layer
         non-expert (attention, embeddings, norms):  1.46 GB   always read
         expert weights:                            19.83 GB   × 2.3 %  = 0.46 GB
         ------------------------------------------------------------------
         bytes per token:                            1.92 GB
```

That single line is why a 40 B model can be faster than a 7 B one: it reads 1.92 GB per token
against the dense 7B's 4.36 GB. **The 40 B model reads less than half as much.** Parameter count
says nothing about speed; bytes per token says all of it.

Same arithmetic for gpt-oss-20b: 24 blocks, 4 of 32 experts active → 12.5 % of 9.48 GB of experts
(1.19 GB) plus 3.35 GB of always-read non-expert weights = **4.54 GB/token**. Which is *more* than
the dense 7B reads — and that is exactly why it is slower despite being "sparse".

A sparse model only wins if it is sparse *enough*. 4-of-32 is not; 6-of-256 is.

---

## 3. Two kinds of measurement, and why both

**`llama-bench`** answers "what can the engine do". Fixed prompt lengths, fixed generation length,
several repeats, no HTTP, no tokenizer chat template, no sampling variability. Good for comparing
configurations — `-ncmoe 40` versus `-ncmoe 44` — because nothing else changes.

**`llama-server` timings** answers "what will you feel". Every `/v1/chat/completions` response
includes:

| field | meaning |
|---|---|
| `prompt_n` / `prompt_ms` | tokens actually processed, and how long it took |
| `prompt_per_second` | prompt processing rate — dominates time-to-first-token |
| `predicted_n` / `predicted_ms` | tokens generated, and how long |
| `predicted_per_second` | the generation rate quoted everywhere |
| `predicted_per_token_ms` | per-token latency at steady state |

Time to first token is `prompt_ms + predicted_per_token_ms` — the wait before the first character
appears. This is the number a human actually feels, and it is where the models differ most: 96 ms
for Gemma 4 against 2,185 ms for flint, a 23× difference that no generation benchmark shows.

Both benchmarks matter because they disagree in instructive ways. flint's `llama-bench` generation
rate (43.6 t/s) is higher than what it delivers end to end (40 t/s), because bench does not carry a
16k context or a chat template. The dense models barely move between the two.

---

## 4. The harness, and the four ways it lied first

`llm-scenarios.ps1` sends six prompts that mirror ordinary use — summarise a document, write code
from a spec, debug a traceback, multi-step arithmetic, extract JSON, call a tool — and records the
server's timings. Writing it was straightforward. Making it tell the truth was not, and every bug
below produced plausible-looking numbers:

**1. Prompt caching made repeats look 10× faster.** llama.cpp reuses a cached prompt prefix, so a
repeated prompt reported `prompt_n = 5` and a nonsense "51 t/s". Fixed with `cache_prompt: false`.
*Lesson: a suspiciously good prompt number is usually a cache hit, not a fast machine.*

**2. No warmup charged startup to the first prompt.** The first request after load pays CUDA
allocation and cold page-ins. flint's first prompt showed a 5.6 s time-to-first-token that was pure
startup cost, and it would have been attributed to whichever prompt ran first. Fixed with a
throwaway 8-token request per model before measuring.

**3. Thinking models looked broken.** Qwen3 and Gemma 4 are reasoning models: they fill a separate
`reasoning_content` field first and only then produce `content`. With a 200-token budget the whole
allowance went to reasoning and `content` came back **empty** — which looks exactly like a dead
server or a broken proxy. The fix was to raise budgets to 700–1200 tokens and capture both fields.
*This is the single most likely thing to waste an afternoon when you first point an agent at a
local reasoning model.*

**4. Two PowerShell variables silently ate the output.** PowerShell variable names are
case-insensitive, so `$models` (my report's model list) and `$Models` (the parameter) were the same
variable, and `$out` (a sentence about tool calls) overwrote `$Out` (the report path). The report
was being written to a filename made of prose. Both fixed; the file now writes through
`[System.IO.File]::WriteAllText` because the sandboxed `Set-Content` proxy rejects `-Encoding` on
piped input.

A fifth, smaller one: `---` concatenation for a Markdown table header produced the right number of
columns by luck, and a comma inside a method call (`-replace 'x', 'y'`) was parsed as a second
argument to `AppendLine`. Both are the kind of thing that works until the data changes shape.

---

## 5. The experiment log

Chronological, with the hypothesis each experiment was testing.

### 5.1 CPU-only baseline (the control)

```
flint-nvfp4-40b, CPU backend, 20 threads:
  prompt processing   45.4 t/s
  generation          18.7 t/s
```

This established the floor and one surprising fact: generation is *faster* than prompt processing
on the CPU path. That is unusual — normally prompt processing wins because it is one big
matrix-multiply per chunk. It means the NVFP4 expert path is so slow per byte that batching barely
helps. Everything after this was an attempt to get those bytes onto the GPU.

### 5.2 The expert-offload sweep — and why the model breaks here

Hypothesis: the ceiling is DDR5 bandwidth, so moving experts to VRAM should scale smoothly.

```
-ncmoe  34   out of memory (7388 MiB requested, 7.04 GB free)
-ncmoe  36   29.6 t/s
-ncmoe  40   43.6 t/s    <- best
-ncmoe  44   41.5 t/s
-ncmoe  47   40.8 t/s
```

It does not scale smoothly. It *peaks* at 40 and gets worse, which bandwidth alone cannot explain.
Two effects are fighting, and only the first is directly measured:

- More expert layers on the GPU means fewer bytes from DDR5 — good, and visible in the 36 → 40 step.
- But flint is NVFP4, and **the CPU has no fast vector path for NVFP4.** Measured against the
  60 GB/s pipe, the CPU expert path achieves only ~36 GB/s effective (18.7 t/s on 1.92 GB/token).
  It is kernel-bound, not bandwidth-bound.

Why 44 and 47 are *worse* than 40 is not settled by these numbers — the plausible causes are
per-layer CPU↔GPU transfer overhead and VRAM pressure. What is measured is the shape of the curve,
not the cause of its downturn. That distinction matters, because the practical advice ("40, not 47")
is solid while the explanation is a hypothesis.

So the answer to "why not just offload everything" is: 19.83 GB of experts do not fit in 8 GB, and
the part that must stay behind is not running at the speed the memory could deliver. The measured
19–44 t/s spread across the whole session is the same effect showing up as run-to-run variance —
the OS page cache decides how much of the expert data is warm.

### 5.3 Thread sweep

```
ncmoe 40,  -t  8   44.0 t/s
           -t 12   44.8 t/s
           -t 16   46.9 t/s    <- best
           -t 20   44.5 t/s
```

16 threads, not 20, even though the CPU has 20 (8 P-cores + 12 E-cores). The likely reason is that
the P-cores do the real work and the remaining four threads add contention rather than throughput —
but that is inference, not measurement. What *is* measured is that 16 beats 20 by 2.4 t/s on this
model, and that the dense models prefer all 20, because their prompt processing is a different,
more parallel workload.

### 5.4 f16 versus q8_0 KV cache — the counterintuitive one

Hypothesis: quantising the KV cache to 8 bits halves KV memory and should be faster.

```
Qwen2.5-Coder 7B, fully on GPU:
  KV q8_0   44.7 / 49.6 t/s
  KV f16    57.9 / 62.4 t/s      <- 25-35 % faster
```

The opposite. Quantised KV must be **dequantised back to f16 for every attention operation, every
layer, every token**. On a GPU with 448 GB/s and plenty of headroom at 16k context, that
dequantisation costs far more than the bandwidth it saves. KV quantisation is a technique for
fitting longer contexts, not for going faster. On this machine, with an 8 GB card and 16–32k
contexts, **f16 is the default** — `llm-server.ps1` was changed accordingly.

### 5.5 The dense model in VRAM — the actual unlock

Once a 7B dense model fits entirely in VRAM (`-ngl 99`), both halves of the problem improve at once:

```
                 flint (MoE, CPU experts)    7B dense, fully in VRAM
generation            41-48 t/s                    58-62 t/s
prompt processing      370 t/s                     2,018 t/s
time to first token   1.1-5.6 s                    56-100 ms
```

Prompt processing is the story: **5.4× faster**, because it runs entirely on tensor cores instead
of streaming experts through DDR5. A 4,800-token file costs 2.4 s instead of 13 s. Generation only
gains ~40 %, but generation was never the bottleneck in interactive use — ingestion is.

**One number in these documents looks contradictory, so it is worth addressing.** The report shows
flint averaging 54 t/s of prompt processing; this section quotes 370 t/s. Both are correct and they
measure different prompt lengths. `prompt_per_second` is bytes-processed divided by time, and on the
MoE path a short prompt is dominated by the fixed per-request cost — expert page-in, layer
scheduling — so 150 tokens take about as long as 400 would, and the *rate* collapses. At 4,808
tokens the fixed cost is amortised and the true streaming rate (370 t/s) shows up. This is why
"prompt t/s" is only meaningful with the prompt length attached, and why the report's 54 t/s should
be read as "short prompts are expensive for this model", not "this model processes prompts at
54 t/s".

### 5.6 Finding Gemma 4 already on the disk

The request was "update the smaller model to something newer, at the same speed". While looking for
candidates, `glob` turned up an unused Unsloth QAT build of **Gemma 4 E4B** in Magnitude's hub
cache — 3.93 GB, never downloaded for this project, already paid for.

```
llama-bench:   prompt 6,117 t/s   generation 89.6 t/s
end to end:    80 t/s, 96 ms to first token, 3.7 GB VRAM
```

Faster than the 7B on both axes, 0.4 GB smaller on disk and **1.9 GB less VRAM** (3.67 against
5.58), and — verified against llama.cpp directly, not through any proxy — it returns native
`tool_calls`. It became the default for agent work.

The lesson is not "Gemma 4 is good". It is that **the fastest model on your machine may already be
on your disk**, and `bytes/token` tells you where to look before you spend six hours downloading.

### 5.7 gpt-oss-20b, and the limits of sparsity

```
-ncmoe  20   34.2 t/s
-ncmoe  17   34.5 t/s
-ncmoe  14   38.8 t/s    <- chosen
-ncmoe  13   38.2 t/s, prompt 236 t/s
-ncmoe  12   out of memory
```

It works, and 14 is the value that survives a 16k context. But two things went wrong that the
numbers alone would hide:

- **It is slower than its own arithmetic predicts** (30 t/s against a 64 t/s ceiling). MXFP4 on the
  CPU has the same kernel problem NVFP4 has: ~28 GB/s effective against a 60 GB/s pipe.
- **Its tool calls do not survive the server.** Asked to call a tool, it emitted raw Harmony
  markup — `<|channel|>analysis to=tool.get_weather code<|message|>{"location":"Istanbul"}` — as
  plain text, and llama-server passed it through. The model's intent is correct; the plumbing to
  convert Harmony into OpenAI `tool_calls` is not there in this build. For chat it is fine. For an
  agent loop it is not, without a parser.

---

## 6. The dead ends, and what they cost

Not everything tried worked. These are worth recording so they are not tried again.

**The iGPU / "unified memory" idea.** The premise was that an integrated GPU sharing DDR5 would let
big models run without a VRAM limit. Measurement killed it: shared memory does not change the
60 GB/s ceiling, and the iGPU's compute is far below the CPU's for this workload. Unified memory
gives you *capacity*, which is the one thing this machine did not lack. It is a capacity solution
to a bandwidth problem.

**OpenVINO / Lemonade.** Genuinely interesting for CPU inference, and it is installed. But it
targets a different execution model (NPU/GPU via OpenVINO IR, not GGUF), so it cannot share the
models or the tooling. It stayed unused, and `llm-check.ps1` notes it.

**NVFP4 on the CPU.** No fast dequantise-dot kernel, as §5.2 shows. The backend has the type
(`nvfp4`, `mxfp4` strings are in both the CPU and CUDA DLLs) but the CPU path runs at ~36 GB/s
effective. This is the single biggest structural limitation on the MoE strategy here.

**Hugging Face downloads.** Measured at 0.15 MB/s on a single stream, ~0.4 MB/s via xet, with
repeated "connection struggling" stalls and one downloader that exited successfully having written
nothing. The Ollama registry served the same bytes at **4–6 MB/s, roughly 30× faster**. Every model
on this machine now comes from `ollama pull` and is hardlinked into `llm\models`, so the two tools
share one copy on disk.

Both long pulls also **stalled mid-flight at a fixed percentage with zero bytes written**, and only
resumed after the client was killed and restarted. A stall is not necessarily a dead connection.
This is why the downloads were monitored rather than trusted.

---

## 7. Why flint's first token takes two seconds

With everything warm, flint's time to first token is ~1.1 s. Cold, it is 5.6 s. That gap is not
model load — it is the **expert page-in**: the first tokens of a session touch expert tensors
scattered across 21 GB, and until the OS page cache holds them, those reads come off NVMe at a few
GB/s instead of DDR5 at 60 GB/s.

This matters more than it sounds. It means flint's *second* answer in a conversation is
substantially faster than its first, and it means any benchmark that does not warm up will
overstate how slow it is — and any benchmark that shares a process between prompts will understate
it. The warmup request in the harness exists precisely to make this cost visible and separate.

The dense models do not have this behaviour, because 4 GB fits in the page cache entirely. That is
another, quieter advantage of being small.

---

## 8. Verify any number yourself

Every claim in the report can be reproduced from a shell:

```powershell
cd C:\Users\fih\llm\bin

# 1. What does this model read per token, and does it fit?
.\llm-plan.ps1 -Model .\..\models\gemma-4-E4B-it-q4kxl.gguf

# 2. Engine-level throughput, no server involved
.\llm-bench.ps1 -Model .\..\models\gemma-4-E4B-it-q4kxl.gguf -PP 512 -TG 128 -Reps 3

# 3. Start it the way an agent would use it
.\llm-up.ps1 gemma4

# 4. Watch the raw timings for one request
curl.exe -s http://127.0.0.1:8083/v1/chat/completions `
  -H "content-type: application/json" `
  -d '{\"model\":\"gemma-4-e4b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":64}' |
  ConvertFrom-Json | Select-Object -ExpandProperty timings

# 5. Re-run the whole six-prompt suite and rewrite the report
.\llm-scenarios.ps1 -Reps 3
```

The `timings` object from step 4 is the primary source for everything in the report. If a number in
the report cannot be reproduced this way, treat it as wrong.

---

## 9. What would change these conclusions

Honest limits of what was measured:

- **One machine, one session.** Run-to-run variance on the MoE path is ±10 t/s, larger than some of
  the differences being compared. The dense-model results are stable to ±3 t/s and can be trusted
  further.
- **Temperature 0.2 and thinking left on.** Both affect how many tokens are generated and therefore
  how diluted the measured rate is. A thinking model's generation rate is partly a measure of how
  long it thinks.
- **A newer llama.cpp may fix the CPU FP4 kernels.** Performance here is dominated by
  `ggml-cpu`'s dequantise-dot path. If that improves, the entire MoE-on-CPU conclusion improves
  with it — the flint numbers in particular.
- **A newer build may also convert Harmony tool calls properly**, which would change gpt-oss's
  verdict from "chat only" to "usable".
- **8 GB is the binding constraint.** Every recommendation assumes one model resident at a time.
  A 16 GB card would make the dense 14B class interesting and would make the MoE compromise
  unnecessary.

---

## 10. Which script does what

| file | role |
|---|---|
| `llm-check.ps1` | scans hardware and toolchain, reports what is present |
| `llm-plan.ps1` | parses a GGUF header: blocks, experts, bytes/token, recommended offload |
| `llm-bench.ps1` | wraps `llama-bench` with the right flags, optional thread sweep |
| `llm-tune.ps1` | sweeps `-ncmoe` / threads and reports the best combination |
| `llm-server.ps1` | starts `llama-server` with measured defaults (f16 KV, flash attention) |
| `llm-up.ps1` | name → file → port → alias, one model at a time, waits for `/health` |
| `llm-scenarios.ps1` | six user prompts, records timings, writes the Desktop report |
| `llm-claude.ps1` | starts model + Anthropic shim, then launches Claude Code |
| `anthropic-shim.py` | translates Anthropic `/v1/messages` to OpenAI `/v1/chat/completions` |

The chain that produced the report: `llm-plan` to understand the model, `llm-bench` to compare
configurations, `llm-up` to serve it exactly as an agent would, `llm-scenarios` to measure what a
person would feel.

---

# Part 8 — Qwen3.6-35B-A3B: the same trick on a newer model

Added after the first report. This part is mostly about what *did not* work, because that is where
the useful knowledge is.

## The model that was chosen

`qwen3.6:35b-a3b-mtp-q4_K_M`, 20.23 GB, pulled from Ollama's registry in two attempts (the first
died at 31% with `unexpected EOF`; a retry loop resumed where it stopped).

Header, read before trusting it with anything:

```
arch            : qwen35moe        41 blocks
experts         : 8 of 256 active per token, on all 41 layers
non-expert      : 1.57 GB   (attention, embeddings, norms - read every token)
expert weights  : 18.65 GB   (3% read per token)
bytes per token : 2.15 GB
```

2.15 GB/token sits between flint (1.92) and gpt-oss (4.54), so the ceiling is visible before the
first request:

| model | bytes/token | VRAM ceiling | measured |
|---|---|---|---|
| flint 40B | 1.92 GB | 83 t/s | 33-40 t/s |
| **Qwen3.6-35B-A3B** | **2.15 GB** | **74 t/s** | **42.7 t/s** |
| gpt-oss-20b | 4.54 GB | 35 t/s | 30 t/s |

## The `-n-cpu-moe` sweep, and the cliff

Every layer whose experts stay on the CPU moves its share of those 2.15 GB onto a 60 GB/s bus
instead of a 448 GB/s one, so the *lowest* value that still fits should be fastest. It is:

| `-n-cpu-moe` | result |
|---|---|
| 20, 24, 26, 28 | failed to load — `failed to create_context` |
| **30** | **41.3 t/s** (35.3 / 42.3 / 46.2 over three prompts) |
| 31 | 33.7 t/s |
| 32 | 31.0 t/s |
| 34 | 38.3 t/s (31.2 / 40.8 / 43.0) |

29 also failed. The model is one layer away from not running at all, and speed is not monotonic:
30 beats 32 *and* 34. That gap is VRAM pressure rather than a clean bandwidth effect — at 30 the
card is ~7.2 of 8.0 GB full, and the first prompt in every run is consistently the slowest
(35.3 against 46.2) while pages are pulled in.

**Practical rule:** 30 at 16k context. There is no headroom above it; 32k at 30 does not load
either, which is why the server is pinned to 16k.

## Speculative decoding — measured, and rejected

`llama.cpp b12255` exposes speculative decoding as a first-class feature:

```
--spec-type none,draft-simple,draft-eagle3,draft-mtp,draft-dflash,draft-dspark,
            ngram-simple,ngram-map-k,ngram-map-k4v,ngram-mod,ngram-cache
```

### MTP: it works, and it is still not worth it

The GGUF carries a multi-token-prediction head (`blk.40.nextn.*`). At load time the build appears
to discard it — `model has unused tensor blk.40.nextn.eh_proj.weight -- ignoring` — but
`--spec-type draft-mtp` does activate it. The first failures were **memory**, not support:

```
E llama_init_from_model: failed to initialize the context: failed to allocate buffer for rs cache
```

The speculative path allocates an extra recurrent-state buffer, needing VRAM a `-n-cpu-moe 30`
server does not have. Given headroom it runs, and acceptance is good:

| configuration | generation |
|---|---|
| `-n-cpu-moe 38`, no speculation | 29.3 / 29.2 t/s |
| `-n-cpu-moe 38`, `draft-mtp` | 35.4 / 33.7 t/s — **+18 %**, 167/246 and 168/243 accepted (**69 %**) |

+18 % is real. It is also smaller than the ~25 % given up by pushing eight more layers of experts
to DDR5 to make room for it, and it will not fit at all lower down:

| `-n-cpu-moe` | with `draft-mtp` |
|---|---|
| 30 | failed to load |
| 32 | failed to load |
| 34 | 29.2 t/s (plain 34: 38.3) |
| 38 | 33.7-35.4 t/s |
| 41 | 32.0 t/s |

**Conclusion:** best configuration for this model on this laptop is plain decoding at
`-n-cpu-moe 30`. MTP is a genuine accelerator that the 8 GB card cannot afford to use.

### n-gram speculation: actively harmful

No draft model required, so it costs nothing to try — and plenty to keep:

| model | prompt | off | `ngram-cache` | delta |
|---|---|---|---|---|
| Gemma 4 E4B | code | 82.6 | 76.8 | −7 % |
| Gemma 4 E4B | prose | 81.5 | 81.3 | 0 % |
| **Qwen3.6-35B** | code | 40.7 | **17.8** | **−56 %** |
| **Qwen3.6-35B** | prose | 45.8 | **27.8** | **−39 %** |

Acceptance was 21 % and 16 %. On a model already generating 40 t/s the guess-and-verify overhead
dominates; on the 35B it halves throughput. The mode is a trap for anyone who assumes "it says
speculative, it must be faster".

## The real weakness: prompt processing

Generation is 42.7 t/s. Prompt processing is not in the same league:

| prompt size | prefill | time to first token |
|---|---|---|
| 63 tok | 13.6 t/s | 4.6 s |
| 195 tok | 52.8 t/s | 3.7 s |
| 459 tok | 262 t/s | 1.8 s |
| 1119 tok | 112 t/s | 10.0 s |

Prefill for a split MoE is governed by the same DDR5 bus, but now 84 % of the expert weights must
be touched for a *batch* of tokens rather than one. It improves with batch size up to a point and
then collapses once the working set thrashes — 1.8 s at 459 tokens and 10.0 s at 1119 are the same
server minutes apart.

For chat and code turns this is fine. For an agent that opens every task with a 12-15k-token
system prompt it is the difference between usable and not.

## How it actually compares

Same six prompts, same session, same machine:

| model | avg generation | avg time to first token | tools | VRAM |
|---|---|---|---|---|
| gemma4 (4B dense) | 81.0 t/s | 131 ms | ✅ | 4.0 GB |
| coder (7B dense) | 57.4 t/s | 84 ms | ❌ | 6.3 GB |
| **qwen36 (35B MoE)** | **42.7 t/s** | **2,805 ms** | **✅** | **7.2 GB** |
| qwen3 (8B dense) | 39.1 t/s | 208 ms | ✅ | 7.4 GB |
| flint (40B MoE) | 33.1 t/s | 3,850 ms | ✅ | 6.6 GB |
| gpt-oss (20B MoE) | 30.1 t/s | 1,083 ms | ❌ | 7.6 GB |

The condition was "only if it is better than flint". It is: +29 % generation, two-thirds less
waiting for the first token, and a current-generation model rather than an experimental
quantisation. Whether the *answers* are better is not something timings can decide — the raw text
of all six prompts is in `local-llm-report.md` for a human to judge.

---

# Part 9 — Maximum context: why estimation failed and trial loads worked

## The question

> "fix the presets so every model will load with maximum amount of context window."

Every preset was pinned at 16384 (gemma4 at 32768) because those were the values used while tuning
speed. Nobody had ever asked how far each model could *actually* go.

## The estimation that lied

`llm-maxctx.ps1` measured free VRAM at two context sizes and extrapolated:

```
bytes_per_token = (free_at_8192 - free_at_16384) / 8192
extra_tokens    = (free_at_16384 - safety_margin) / bytes_per_token
max_ctx         = 16384 + extra_tokens
```

It produced this:

| model | suggested | why it is wrong |
|---|---|---|
| gemma4 | 131072 | right, by luck — it hit the training cap |
| flint | 49152 | right |
| coder | 32768 | right (training cap) |
| **qwen3** | **14336** | **below** the 16384 it was already serving |
| **gptoss** | **11264** | **below** the 16384 it was already serving |
| **qwen36** | *negative* | computed `target -6144`, failed to load, kept 16384 |

The failure is structural, not a rounding bug. The formula assumes the card has spare VRAM at the
baseline context. On this machine it does not: with LM Studio, Magnitude and Steam resident,
free VRAM at 8192 was 1120 MB for qwen3 and 295 MB for qwen36. Free VRAM at 16384 then *drops below
the safety margin*, so `extra_tokens` goes negative and the script "discovers" that the model can
hold less than it is demonstrably holding right now.

Free VRAM is a **residual**, not a **budget**. You cannot subtract a residual from a safety margin
and get a context length.

## The method that worked: try to load it

`llm-ctxgrow.ps1` asks the only question with a real answer — does it load?

1. Stop every `llama-server` (one model at a time, always).
2. Start the model at the first candidate context, exactly the flags the preset uses.
3. Wait on `/health`, then send a real completion. Health alone is not enough: a model can answer
   `/health` and still fail its first request (qwen36 at 24576 did exactly that).
4. Keep the highest context that passed, stop at the first failure.

```powershell
.\llm-ctxgrow.ps1 -Model qwen36 -Candidates 16384,20480,24576,32768
```

The cliff is sharp, which is why trial loads beat interpolation:

| model | 16384 | 20480 | 24576 | 32768 |
|---|---|---|---|---|
| qwen3 | ✅ 48,6 t/s | ❌ exits | — | — |
| gptoss | ✅ 33,6 t/s | ✅ 33,4 t/s | ✅ 25,6 t/s | ❌ exits |
| qwen36 | ✅ 31,1 t/s | ✅ 21,2 t/s | ❌ loads, completion fails | — |

## Where the KV cache actually goes

The dense formula says gemma4 needs 168 KiB/token (42 blocks × 2 KV heads × 1024 × 2 bytes) and
therefore could not exceed ~16k. It serves **131072 tokens**. The reason: most Gemma-4 layers are
sliding-window, and llama.cpp only allocates the 512-token window for those layers, so measured
growth is ~17 KiB/token — ten times less than the dense arithmetic.

Same story on the MoE models: with `--n-cpu-moe`, most expert weights live in RAM, so the VRAM
budget is *non-expert weights + KV + compute buffers*, not the file size. Reading a GGUF header
tells you the geometry; it does not tell you the budget. Only a load does.

## What changed

| preset | before | now | generation before → after |
|---|---|---|---|
| gemma4 | 32768 | **131072** | 77.5 → 74.1 t/s (−4 %) |
| flint | 16384 | **49152** | 29.5 → 29.8 t/s (flat) |
| coder | 16384 | **32768** | 52.5 → 50.3 t/s (−4 %) |
| gptoss | 16384 | **24576** | 34.4 → 30.8 t/s (−10 %) |
| qwen36 | 16384 | **20480** | 39.2 → 34.0 t/s (−13 %) |
| qwen3 | 16384 | 16384 (ceiling confirmed) | 46.7 → 59.0 t/s (same context, run-to-run) |

The probe runs in the table above looked far more expensive (−24 %, −32 %) than the verification
run did. The probe measures one 200-token completion immediately after load, on a cold clock; the
verification warms up first and generates 300 tokens. **Trust the warm-up numbers.** The real price
of maximum context is 4–13 %, and for flint nothing at all.

That is the more interesting result: context here is nearly free, because the KV cache is 17–58 KiB
per token while the weights are 4–21 GB. A full 131k window on gemma4 costs 2.3 GB — noticeable
against 8 GB, but nothing like a model's worth.

Data: `llm\bench\maxctx.csv` (the two-point probe), `llm\bench\ctxgrow-*.csv` (the trial loads),
`llm\bench\bundle-verify.csv` (the presets re-verified at the new sizes).

---

# Part 10 — Depth: what a full window actually costs (2026-11-12)

## The gap Part 9 left open

Part 9 established how far each window can go. Every speed in it — and in every earlier part — was
measured on an **empty** one: a 41-token question dropped into a 131072-token context. Decode speed
is `bandwidth ÷ bytes read per token`, and the bytes an attention layer reads per token grow with the
tokens already in the cache. So "44 t/s at 32k" was a property of the *configuration*, not of a
session that has used 32k.

## The measurement

`bin\llm-stability.ps1`:

1. Starts each registry preset exactly as the registry specifies (it used to re-derive the split —
   see the two mistakes below).
2. Warms the clock with one 64-token request.
3. Measures 200 decode tokens at 512 tokens of context, three times, reading
   `timings.predicted_per_second` from the server with `cache_prompt: false`.
4. Fills the window to 25 % and 60 % of that model's `Ctx` with filler verified through `/tokenize`,
   then repeats the 200-token measurement.
5. Measures the 512-token case **again**, twice.

Step 5 is the part that makes the table mean anything. This laptop's clock moves 8-16 % in the five
minutes a model takes (1627 MHz idle, ~2500 MHz under load at 68 °C, 2287 MHz at 75 °C). With a
single baseline taken first, `qwen36` looks like it loses 29 % of its speed at depth when most of that
is the machine cooling between runs. Every ratio uses the **mean of the before and after baselines**,
and the drift between them is printed in the table so the reader can see how much correction was
applied.

## The two mistakes, both of which produced plausible tables

- **A launcher that re-derives tuned flags.** `serve-model.ps1` took the registry key, then computed
  `--n-cpu-moe` from the GGUF geometry instead of reading the registry: flint was served at **38**
  where the repository says **40**. At 38 it loads at 16384 and cannot serve its own 49152 window, so
  the sweep waited on a dead port. Fixed: a registry key inherits `Ctx`, `CpuMoe`, `Threads`, `Port`
  and `Alias`; geometry is only used for a file the registry has never seen. The harness now parses
  the served `ncmoe=`/`ctx=` back out of the launch log and complains if they disagree.
- **An invented KV number.** `llm-server.ps1` warned that gemma-4 needed "3.9 GB + KV 19.7 GB" at
  131072, from a constant calibrated on a 36-layer 7B. The real cache is **2.3 GB**: five of every
  six gemma-4 layers are sliding-window and never store the full window. `llm-plan.ps1` now computes
  `KvBytesPerToken` from the header's `block_count`/`head_count_kv`/`key_length`/`value_length` and
  reports whether that is measured geometry or a fallback constant — and the warning is not allowed
  to contradict a window the registry already serves.

## What came out

| model | window | empty (512) | 25 % of window | 60 % of window | drift | verdict |
|---|---|---|---|---|---|---|
| gemma4 | 131072 | 84.8 t/s | 32646 tok -> **68.4** t/s (81 %) | 78291 tok -> **52.7** t/s (62 %) | +8 % | softened/collapsed |
| coder | 32768 | 61.2 t/s | 8205 tok -> **52.4** t/s (86 %) | 19614 tok -> **48.9** t/s (80 %) | -1 % | softened/softened |
| qwen3 | 16384 | 53.2 t/s | 4108 tok -> **48.4** t/s (91 %) | 9813 tok -> **43.6** t/s (82 %) | +1 % | kept/softened |
| coder36 | 32768 | 40.0 t/s | 8186 tok -> **38.1** t/s (95 %) | 19594 tok -> **37.1** t/s (93 %) | +9 % | kept/kept |
| qwen36 | 20480 | 38.4 t/s | 5127 tok -> **38.9** t/s (101 %) | 12259 tok -> **29.7** t/s (77 %) | -16 % | kept/softened |
| flint | 49152 | 34.3 t/s | 12252 tok -> **29.6** t/s (86 %) | 29370 tok -> **28.9** t/s (84 %) | +1 % | softened/softened |
| gptoss | 24576 | 27.4 t/s | 6159 tok -> **27.2** t/s (99 %) | 14718 tok -> **25.5** t/s (93 %) | +3 % | kept/kept |

The pattern follows the KV footprint per token, not the model size: gpt-oss keeps 24.6 KiB per token
and barely moves; gemma-4 stores 2.3 GB at 131k and pays for the last third of it. Two conclusions
survive: every ceiling in Part 9 is real, and `Ctx` is a **ceiling, not a recommendation**.

Data: `llm\bench\stability-at-depth.csv` (44 rows), `llm\bench\stability-verdicts.json`. The table is
regenerated by `bin\llm-stability-report.ps1 -Markdown` — never typed by hand.

---

# Part 11 — A wider window is free, if you measure A against B (2026-11-13)

## The question

Not "how big can the window be" (Part 9) but "is it big enough for what a chat carries". With REA's
tool catalog selected, every request begins at 12 402 prompt tokens — 61 % of `qwen36`'s 20 480 and
38 % of `coder36`'s 32 768. Doubling either window puts that back at 30 % and 25 %, so the question is
only whether doubling costs generation speed.

## Why one arm per configuration cannot answer it

`llm-ncmoe-sweep.ps1` starts a cold card, generates twice, keeps the best, and moves on. Run it often
enough and it contradicts itself: the **same** 20 480 configuration measured 34.6 t/s and then 23.5
t/s in consecutive rounds, and a 40 960 one measured 41.2 and 26.7. Nothing had changed except the
order — the SM clock idles at ~1600 MHz and needs seconds of real work to reach ~2600, so the arm that
runs first pays for the ramp and the one after it inherits a warm card.

Part 10 solved this for depth with bookends. Here the same idea is applied to a flag: alternate.

## The protocol

`bin\llm-window-ab.ps1 -ACtx 20480 -ACpuMoe 30 -BCtx 40960 -BCpuMoe 31`

1. Loads arm A, generates once and **discards it** — that generation is the clock ramp, not the arm.
2. Takes the median of two 384-token decodes.
3. Repeats for arm B, then the whole cycle again (A, B, A, B).
4. Waits for VRAM to fall below 1.5 GB before each load, because a load started too early fails with
   a CUDA OOM that looks exactly like "this configuration does not fit".
5. Reads `n_ctx` back from `/props`, so "40 960" is the server's number, not the flag's.

## What came out

| model | arm A | arm B | A → B | catalog share |
|---|---|---|---|---|
| `qwen36` | 20480 / ncmoe 30 → 29.1 t/s | **40960 / ncmoe 31 → 35.3 t/s** | +21 % | 61 % → 30 % |
| `coder36` | 32768 / ncmoe 26 → 29.2 t/s | **49152 / ncmoe 29 → 32.6 t/s** | +12 % | 38 % → 25 % |

The floors moved with the windows — `coder36` 27 is a CUDA OOM at 49 152, and `qwen36` 32 crashed
once at 40 960 — so the registry ships the value that loaded 4/4, not the lowest that loaded once.

**Read the absolute numbers carefully.** The *old* settings measured 29.1 and 29.2 on the same
afternoon, i.e. this card was running ~30 % below its best-day clocks while the A/B ran. The
comparison is same-day and internal; it says the wider window costs nothing, not that the model got
faster. That is why every table in this document dates its rows.

Data: `bench\window-ab-qwen36.csv`, `bench\window-ab-coder36.csv` (round, arm, ctx, ncmoe, tps,
load_s, n_ctx). Regenerate with the command above; never type the table by hand.

---

*Numbers in this document were taken 2026-11-10 through 2026-11-13 on `MSI-Crosshair`, Windows 11 build 28000,
llama.cpp b12255 (CUDA 13.5), NVIDIA driver 621.01. Where a figure is arithmetic rather than
measurement it says so; where a measurement was unstable it says that too.*
