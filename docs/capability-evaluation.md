# Measuring what the models can do, not just how fast they do it

Every other number in this repository is a speed. This document is the other half: a battery of 36
tasks that scores what each model actually produces, with every answer graded by a program.

The suite lives in [`bench/capability-suite-v1.json`](../bench/capability-suite-v1.json), the grader in
[`bin/llm-eval.py`](../bin/llm-eval.py), and the runner in [`bin/llm-eval.ps1`](../bin/llm-eval.ps1).

```powershell
.\bin\llm-eval.ps1                       # all seven models, ~50 min
.\bin\llm-eval.ps1 -Models gemma4,qwen3  # two of them
.\bin\llm-eval.ps1 -Models coder36 -Only code,math,logic
.\bin\llm-eval.ps1 -Report               # re-aggregate bench\eval-*.json, run nothing
```

---

## 1. Why a second benchmark was needed

The rest of the project answers *"how fast"*. It cannot answer *"is this one better"*, and the two
questions have opposite answers surprisingly often: on this machine the 27B coder is faster than the
8B generalist (44.4 vs 34.0 t/s at context) because it reads fewer bytes per token, not because it is
smarter. Speed and capability are decided by different physics — bandwidth versus weights — so they
need different measurements.

**Six rules were fixed before the first item was written**, because each one is a way that a
homemade benchmark lies:

1. **No judge model.** A judge is another model with its own preferences, and at 36 items its noise
   would swamp the signal. Everything is graded by exact match, a regular expression, a JSON schema,
   or by *executing* the model's code against unit tests it has never seen.
2. **Identical token budget per item, for every model.** A model that thinks before answering spends
   its budget reasoning; if the budget is small, it never writes an answer and scores zero for a
   reason that has nothing to do with capability. This was not hypothetical — see §6.
3. **The answer format is part of the contract.** Prompts end with *"finish with a final line of
   exactly this form: `ANSWER: <your answer>`"*. A model that reasons correctly and then writes three
   paragraphs still scores; the grader reads what follows the marker.
4. **The grader has to pass its own gold answers first.** `--self-test` feeds every item the answer
   key and requires the grader to accept it. CI runs the same test on every push, because a benchmark
   with a broken extractor scores every model zero and the zero looks like a finding.
5. **Per-category scores, never one headline number.** A single aggregate lets a model that is good at
   knowledge hide that it cannot follow a format instruction, and the weighting that produces the
   aggregate is arbitrary.
6. **Intervals, not decimals.** Six items per category means the 95 % interval is wide — roughly ±30
   points at the extremes. The report says so instead of printing "83 %" and implying precision the
   sample cannot support.

## 2. What is in the suite

| category | n | what it asks | how it is graded | chance |
|---|--:|---|---|--:|
| `math` | 6 | multi-step word problems (rates, time, fractions, geometry) | the number after `ANSWER:` | 0 |
| `logic` | 5 | syllogism, ordering, calendar arithmetic, knights and knaves, inclusion–exclusion | the option letter | 25 % |
| `code` | 4 | four functions: word reversal, palindrome test, Fibonacci, interval merging | **unit tests executed** in a subprocess, 20 s limit | 0 |
| `instr` | 6 | verifiable constraints: exact line count, exact word count, all caps, exact JSON, regex shape | predicate list — every constraint must hold | 0 |
| `json` | 3 | field extraction from messy text with typed values | parsed, then compared field by field | 0 |
| `needle` | 3 | a passphrase hidden at 15 %, 55 % and 90 % depth of half the model's own context | exact substring | 0 |
| `tools` | 3 | two tools offered, three requests that need them | native `tool_calls`: function name and arguments | 0 |
| `knowledge` | 6 | stable facts, four-way multiple choice | the letter | 25 % |

Two details that matter more than they look:

- **The code items are executed, not compared.** A model that writes a correct function with a
  different name for its helper still passes; a model that writes something that looks right and
  crashes on the empty list does not. This is the least ambiguous category in the suite, which is why
  it is worth the 20 seconds per item.
- **The needle scales with each model's own context**, not with a fixed size. Testing a 16k model at
  24k tokens measures the error message, not the model. The filler is generated at run time from a
  seeded word list, so the answer cannot have been memorised, and the passphrase is different at each
  depth.

## 3. Keeping it fair on this machine

- **Each model runs with its own registered flags** — the exact `-c`, `--n-cpu-moe`, `-t` and KV type
  that `llm-up.ps1` uses in daily work. The benchmark measures the models *as they are used here*,
  not a stripped-down configuration that would score the same for everything.
- **Temperature 0, top_p 1, one request at a time.** llama.cpp is bit-reproducible at this setting on
  a fixed build, so a re-run is a check of the harness rather than a source of new noise.
- **The server command line and the token counts are stored with every item**, so any number can be
  traced back to the request that produced it.
- **Raw replies are kept** (`bench/eval-<key>.json`), which is what let the two grader bugs in §6 be
  found and fixed without re-running every model.

## 4. What this battery cannot tell you

- **It ranks "broken" versus "works", not "good" versus "very good".** With six items per category the
  interval around 5/6 is roughly 44–97 %. A 6/6 against a 5/6 is *not* a meaningful difference.
- **A 36-item run cannot see a quantisation difference.** Q4_K_M versus Q8 moves benchmark scores by
  less than the noise here; measuring it needs a continuous signal such as log-probabilities, not
  accuracy counts.
- **It is one run per model.** No repetition, so no variance estimate; the intervals quoted are
  statistical, not empirical.
- **It is not MMLU, GSM8K or HumanEval**, so the numbers are not comparable with any published table.
  That is deliberate: those sets are in every pretraining corpus, and three of these seven models
  could plausibly have seen them. The answer key here is in the repository, which is a smaller
  problem than contamination and a bigger one than nothing.
- **Tool calls are scored only in native mode.** If a model can be coaxed into tool calling through a
  different template, this battery will not find out.

## 5. Why these categories and not others

- **Code, because it is objectively gradable.** Unit tests are the only part of this suite where the
  grader cannot be argued with.
- **Instruction following, because it is what breaks in daily use.** A model that ignores "reply with
  only the JSON" is unusable in a script regardless of how well it reasons.
- **Long context, because it is the only category that separates a 16k model from a 131k one**, and
  because this project's whole point is fitting large models into 8 GB — the context ceiling is
  usually the price paid for that.
- **Tool calls, because an agent cannot be driven without them.** Two of the seven models do not
  produce them natively, and that is a fact about them, not a defect of the harness.
- **Maths and logic, because they have right answers.** No subjective judgement, no rubric.
- **Knowledge, as a calibration anchor** — it is the closest thing here to a published benchmark, and
  it is the category most likely to be contaminated, so it is read last and with suspicion.

## 6. The results

### The table

Sorted by the unweighted mean of the eight category pass-rates. That mean is a
convenience for ordering the rows, **not** a capability score — read the profile, and read
the interval below before believing a gap.

| model | macro | math | logic | code | instr | json | needle | tools | knowledge | budget hit |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| **flint** | **100.0** | 6/6 | 5/5 | 4/4 | 6/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| **gemma4** | **97.9** | 6/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| **qwen3** | **97.9** | 6/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| **coder** | **95.8** | 5/6 | 5/5 | 4/4 | 5/6 | 3/3 | 3/3 | 3/3 | 6/6 | 0 |
| **coder36** | **85.4** | 5/6 | 5/5 | 2/4 | 5/6 | 3/3 | 2/3 | 3/3 | 6/6 | 5 |
| **qwen36** | **78.1** | 6/6 | 5/5 | 1/4 | 2/6 | 3/3 | 2/3 | 3/3 | 6/6 | 8 |
| **gptoss** | **67.7** | 6/6 | 5/5 | 1/4 | 1/6 | 3/3 | 3/3 | 0/3 | 6/6 | 5 |

### The profile, in words

- **flint** — clean sweep in `code`, `instr`, `json`, `knowledge`, `logic`, `math`, `needle`, `tools`.
- **gemma4** — clean sweep in `code`, `json`, `knowledge`, `logic`, `math`, `needle`, `tools`; loses points in `instr`.
- **qwen3** — clean sweep in `code`, `json`, `knowledge`, `logic`, `math`, `needle`, `tools`; loses points in `instr`.
- **coder** — clean sweep in `code`, `json`, `knowledge`, `logic`, `needle`, `tools`; loses points in `instr`, `math`.
- **coder36** — clean sweep in `json`, `knowledge`, `logic`, `tools`; loses points in `code`, `needle`; ran out of its token budget on 5 item(s), so its row is a lower bound; 2 answer(s) could not be parsed out of the reply.
- **qwen36** — clean sweep in `json`, `knowledge`, `logic`, `math`, `tools`; loses points in `code`, `instr`; ran out of its token budget on 8 item(s), so its row is a lower bound; 1 answer(s) could not be parsed out of the reply.
- **gptoss** — clean sweep in `json`, `knowledge`, `logic`, `math`, `needle`; loses points in `tools`, `instr`; ran out of its token budget on 5 item(s), so its row is a lower bound.

### Who wins each category

| category | best | score | field median |
|---|---|---|--:|
| `math` | qwen36 | 100 % | 100 % |
| `logic` | qwen36 | 100 % | 100 % |
| `code` | qwen3 | 100 % | 100 % |
| `instr` | flint | 100 % | 83 % |
| `json` | qwen36 | 100 % | 100 % |
| `needle` | qwen3 | 100 % | 100 % |
| `tools` | qwen36 | 100 % | 100 % |
| `knowledge` | qwen36 | 100 % | 100 % |

Two numbers in that table need defending before anything is read into them.

**The budgets.** Every category was run once at its base budget, which the suite file records
(`max_tokens` per item). That first pass showed a systematic problem: the models that reason before
they answer were being cut off mid-thought, and a cut-off reply scores as a wrong answer. So every
category that showed truncation — `code`, `json`, `needle`, `tools` — was re-run for **all seven
models** at three times the budget, and `logic`/`knowledge` were re-run after the choice grader learned
to accept an option's text as well as its letter. The final column counts the items that still hit the
ceiling; a model with a non-zero count is a lower bound, not a measurement.

**The macro column** is the unweighted mean of the eight category rates. It exists to order the rows.
It is not a score, and a 2-point gap in it is noise (§4).

## 7. What the table actually says

### 7.1 There is no speed-versus-smartness trade-off here — there is barely any relationship at all

Rank correlation between tokens/s and the macro column across these seven models is **0.2**, which at
n = 7 is indistinguishable from zero. The slowest model in the project (flint, 29.8 t/s) scored 100; the
fastest (gemma4, 74.5 t/s) scored 97.9; the second slowest (gpt-oss, 30.8 t/s) scored 67.7.

That is not an accident of this table. Speed on this machine is decided by **bytes read per token** —
weights that fit in VRAM are fast, weights streamed from DDR5 are not — while capability is decided by
**what the weights are and how the model is served**. Two different physical quantities. The practical
consequence: "it is slow, so it must be good" is not a rule you can use here, and neither is the
reverse.

### 7.2 The bottom three are the three models that think before they answer

`coder36`, `qwen36` and `gpt-oss` are exactly the three models in the table with long hidden reasoning
traces, and exactly the bottom three. The three models that answer directly — flint, gemma4, qwen3 —
are the top three.

That is the strongest pattern in the data, and it is a **serving** pattern, not a statement about
intelligence:

- On `code-2` (`is_palindrome`, arguably a five-line function) **coder36 and qwen36 each spent their
  entire 4,800-token budget reasoning and returned an empty reply.** Not a wrong function — no function.
  `finish_reason` was `length` in both cases.
- On the six instruction items **qwen36 hit the ceiling on four of them.** Its instruction score of 2/6
  is therefore a floor caused by thinking through "write exactly twelve words" for 1,500 tokens and
  then never writing the sentence.
- `gpt-oss` is worse and different: its replies leak the analysis channel into the content field
  (`"Paris\nWe have a conversation: user says: ..."`), so its `instr` 1/6 and `tools` 0/3 are partly a
  **template defect on this llama.cpp build**, not the model's ceiling. It should be re-measured after
  the chat template is fixed before anyone concludes anything about the model.

The honest reading: **at these budgets, deliberation is a tax this hardware cannot always pay.** A
thinking model at 4,800 tokens costs ~110 s per item at 44 t/s, and if it thinks past the ceiling the
work is thrown away. The models that answer in 200 tokens finish, and score.

### 7.3 Size buys knowledge and logic — which are saturated

Every model, including the 4B and including gpt-oss with its broken template, scored **5/5 on logic and
6/6 on knowledge**. Those two categories no longer discriminate: they are too easy for this field. What
they do show is that the small models here are not weak in the way a parameter count suggests — gemma4
at 4B gets the same factual and logical score as a 40B.

The battery needs a harder tier before it can separate flint (100) from gemma4 (97.9). Right now the
top of the table is a tie between models that differ by a factor of ten in size, which is a statement
about the test, not about the models.

### 7.4 Instruction following is the real fault line, and it is where the money is wasted

`instr` is the only category with a spread that is not explained by budget: 6/6 flint, 5/6 for four
models, 2/6 qwen36, 1/6 gpt-oss. The single item the four good models miss is `instr-3` — one sentence
about rain, exactly twelve words — where they write eleven. That is a real, if petty, capability signal:
counting words while writing is the thing autoregressive models are worst at.

This is also the category that matters most in practice. A model that writes a beautiful answer and
ignores "reply with only the JSON" cannot be put in a pipeline. On this battery, the models you would
actually script against are flint, gemma4, qwen3 and coder — not the two biggest ones.

### 7.5 Code was clean for five of seven, and the grader had to be fixed first

`code` is 4/4 for flint, gemma4, qwen3 and coder; coder36 manages 2/4 and qwen36 1/4,
both for the budget reason in 7.2. Getting there required two fixes to the harness, both found by
reading raw replies:

- The reply contract asks for a final `ANSWER:` line, so a code answer gets written **twice** — once in
  a fence, once after the marker. If the closing fence was missing (budget), the extractor concatenated
  both copies and `ANSWER: def ...` raised a `SyntaxError` **caused by the harness**. Cutting the
  extracted block at the marker turned one of coder36's "failures" into a pass.
- A `SyntaxError` from a truncated fence looks exactly like a model that cannot write Python. It was
  neither. Any benchmark that grades code has to distinguish "the code is wrong" from "we failed to
  extract the code", and this one now does.

### 7.6 Why the small models win here, in one sentence

Because on an 8 GB laptop the models that fit in VRAM answer in a couple of hundred tokens at
50–75 t/s, while the models that do not fit spend their context budget thinking at 30–45 t/s and
sometimes never arrive — so for short, format-sensitive work the 4B is the better tool, and the 40B is
the better tool for anything that needs a long context or a hard single answer.

### 7.7 Five of the seven call tools natively; one only writes JSON; one cannot

The battery scores `tools` as pass/fail on the call itself, which hides *how* the call arrived.
`bin/llm-toolmode.ps1` asks one question that needs a tool and records `finish_reason` plus whether the
reply carried a real `tool_calls` block:

| model | finish | native `tool_calls` | what it produced |
|---|---|---|---|
| gemma4 | `tool_calls` | **yes** | `get_weather({"city":"Ankara","when":"right now"})` |
| qwen3 | `tool_calls` | **yes** | `get_weather({"city": "Ankara", "when": "now"})` |
| flint | `tool_calls` | **yes** | `get_weather({"city":"Ankara"})` |
| coder36 | `tool_calls` | **yes** | `get_weather({"city":"Ankara","when":"right now"})` |
| qwen36 | `tool_calls` | **yes** | `get_weather({"city":"Ankara"})` |
| coder | `stop` | no | `{"name": "get_weather", "arguments": {...}}` in the text |
| gpt-oss | `length` | no | 1,500 tokens of narration, never a call |

The distinction matters for anything that drives a model in a loop: a **native** call is structured
output the client can dispatch without parsing prose, and `coder`'s text JSON has to be fished out and
hoped over. It is still a correct answer — which is why the battery counts it 3/3 — but it is not the
same thing.

The first version of this probe used 300 output tokens and reported **coder36 and qwen36 as having no
tool support at all**. They were thinking through the request and had not started the call yet. At
1,500 tokens both produce a clean native call. The probe was wrong, not the models — the same trap as
§7.2, in a different disguise.

## 8. Using this to choose

| if the job is | use | because |
|---|---|---|
| anything scripted (JSON out, exact format, tool calls) | **flint**, then **gemma4** / **qwen3** | 6/6 instr and 3/3 json at 4B–40B; the two biggest lose points here |
| code you will actually run | **coder**, **qwen3**, **gemma4**, **flint** | all 4/4 with executed tests; coder36 needs a much larger budget for short functions |
| a long document (50k+ tokens) | **flint** (49k) or **gemma4** (131k) | the only two that hold a big context and still score 3/3 on retrieval |
| an agent loop with tools | **flint**, **gemma4**, **qwen3**, then **coder36** / **qwen36** | all five return native `tool_calls`; `coder` only writes the call as text, gpt-oss cannot on this build |
| the fastest acceptable answer | **gemma4** (74.5 t/s, 97.9) | highest speed that is still near the top of the table |
| a hard one-shot question where latency does not matter | **flint** | 100 on this battery and the only model that did not miss a single item |

## 9. What would make this table better

1. **A harder tier.** The top four are separated by 4 points out of 36 items. Adding items that actually
   fail — multi-file code, 4-hop retrieval, nested JSON schemas — is the only way to rank them.
2. **A bigger per-category n.** Six items gives ±30 points at the extremes; twenty would give ±15.
3. **A fixed reasoning budget per model, recorded.** `--reasoning-budget` exists in this build; running
   each thinking model at a declared budget would turn §7.2 from an observation into a measurement.
4. **Repetition.** Three runs per item would separate "sometimes" from "never", which is the difference
   between a model that cannot and a model that got unlucky.
5. **The gpt-oss template.** Until that is fixed, its row should be read as "this configuration", not
   "this model".

---

*Raw data: `bench/eval-<model>.json` (every item, its reply, its verdict, its token count and finish
reason), aggregated into `bench/eval-summary.csv`. Regenerate the tables above with
`python bin/llm-eval-report.py`.*
