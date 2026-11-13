# Start here (one minute)

Eight models, tuned for this laptop (RTX 5060 Laptop 8 GB + 32 GB DDR5), with the numbers that chose
their settings. Nothing here downloads on first use: the weights are already in `llama.cpp\models\`.

## Three ways to start

1. **`llama-direct.exe`** — double-click. Pick a model, press **Start model**; the chat page opens by
   itself. **Stop** frees the GPU. This is the normal path.
2. **`llama.cpp\START HERE.cmd`** — the same presets as a text menu, if you prefer a console.
3. **`llama.cpp\presets\<model>.cmd`** — one file per model, double-click. `stop.cmd` frees the GPU.

Only one model fits in VRAM, so stop before starting another.

## What is in the box

| preset | model | port | context | n-cpu-moe | threads | tools |
|---|---|---|---|---|---|---|
| `gemma4.cmd` | `gemma-4-e4b` | 8083 | 131072 | - | 20 | REA |
| `flint.cmd` | `flint-nvfp4-40b` | 8080 | 49152 | 40 | 16 | REA |
| `qwen3.cmd` | `qwen3-8b` | 8081 | 16384 | - | 20 | - |
| `coder.cmd` | `qwen2.5-coder-7b` | 8081 | 32768 | - | 20 | - |
| `gptoss.cmd` | `gpt-oss-20b` | 8082 | 32768 | 15 | 20 | - |
| `coder36.cmd` | `qwen3.6-27b-a3b-coder` | 8085 | 57344 | 30 | 16 | REA |
| `qwen36.cmd` | `qwen3.6-35b-a3b` | 8084 | 40960 | 31 | 16 | REA |
| `dsv2.cmd` | `deepseek-coder-v2-lite` | 8086 | 18432 | - | 16 | - |

`n-cpu-moe` is the number of layers' experts kept in RAM instead of VRAM — that is how a 20-40B model
runs on an 8 GB card. **REA** means the preset also exposes the REA reverse-engineering tools in the
Web UI, which costs prompt tokens: pick only the tools a chat needs.

## Which one to use

- **Anything general: `gemma4`.** 74 t/s, 131k window, native tool calls, 4.2 GB. It is the default.
- **Hard questions: `qwen36`.** Slower, best answers, 40k window, tools.
- **Code with an agent: `coder36`.** 57344 window, native tool calls, 37.7 t/s on its best day.
- **Code, speed over quality: `coder`.** 7B dense, ~56 t/s cold, no tool calls.
- **A 13.5B model in 4.5 GB: `dsv2`.** 65 t/s and the largest model here that needs no CPU offload —
  but its quantisation is damaged (17.7 % on the capability suite: it will tell you Saturn is the
  largest planet). Experiments only; the README's §14 has the evidence.

## Where the evidence is

- `README.md` — the full report: hardware, the measurements, and why each flag is what it is.
- `docs\how-the-numbers-were-made.md` — the method, including what had to be thrown away.
- `docs\capability-evaluation.md` — the 36-item battery every model was scored on.
- `results\` — the raw CSVs and JSON behind every number in the documents.
- `GUIDE.md` — the engineer's handover, 25 traps already paid for.
- `progress.md` — what was tried, what worked, what did not.

## If something is wrong

```powershell
cd <the repository>
.\bin\llm-selftest.ps1       # registry, catalogue, presets, launcher, graders
.\bin\llm-verify-bundle.ps1   # every preset: load, answer, release the GPU
```

Regenerate the Desktop folder at any time with `bin\llm-desktop.ps1 -SkipBinaries` — it rewrites the
presets, the menu and `llama.cpp\README.md` from the single registry in `bin\llm-up.ps1`.
