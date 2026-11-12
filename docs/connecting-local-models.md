# Connecting any local model to anything

*The models on this machine speak exactly one protocol. Learn it once and every client is five
minutes of configuration.*

---

## The whole contract

Every model here is served by `llama-server`, which exposes an **OpenAI-compatible HTTP API** on
loopback:

```
base URL : http://127.0.0.1:<port>/v1
API key  : anything non-empty   (the server does not check it)
model id : the server's --alias  (NOT the filename, NOT the path)
```

That's it. If a tool can talk to OpenAI, it can talk to this. There is no account, no key, no
rate limit, and nothing leaves the machine.

Two rules cause almost every problem:

1. **The model string must equal the `--alias`.** Send `"model": "gemma-4-e4b"` when the server
   advertises `gemma-4-e4b`. Send the filename and you get a 404 or a 400.
2. **The client's context setting must be ≤ the server's `-Ctx`.** Claude Code needs ~15k before
   you type a word; a server started at `-Ctx 4096` will fail mid-task with a confusing error.

---

## Starting a model

```powershell
cd C:\Users\fih\llm\bin

.\serve-model.ps1 -List                    # what is on disk, with geometry
.\serve-model.ps1 gemma4                   # registry key, port and alias from llm-up.ps1
.\serve-model.ps1 flint -Ctx 16384
.\serve-model.ps1 .\..\models\Qwen3-8B-Q4_K_M.gguf -Port 9000
.\serve-model.ps1 qwen3.6:35b-a3b-mtp-q4_K_M -SpecType draft-mtp
.\serve-model.ps1 -Stop                    # free the GPU
```

`serve-model.ps1` reads the GGUF header and picks the flags itself: whether it is dense or MoE,
how much fits in VRAM, `-n-cpu-moe`, thread count, and a sensible alias. It prints the exact base
URL and model id when the server is healthy.

**Only one model fits on the 8 GB card.** Starting a second one stops the first — that is
deliberate, not a bug.

### Flags worth knowing

| flag | when to use it |
|---|---|
| `-Ctx 16384` | context length. 16k is the default; 32k for agent work on small models |
| `-CpuMoe N` | MoE only: layers whose experts stay on the CPU. Auto-derived; override to match `llm-tune.ps1` |
| `-SpecType draft-mtp` | model ships an MTP head (look for `-mtp` in the name) — free speedup |
| `-SpecType ngram-cache` | no draft model needed; helps when output echoes the prompt |
| `-CacheK q8_0` | only when f16 KV does not fit — f16 is measured 25-35 % **faster** |
| `-Port 9000` | run somewhere else, e.g. to keep two endpoints for a quick comparison |

---

## dsh-tui

dsh-tui speaks OpenAI natively, so there is no proxy — just a route in its config.

```powershell
.\serve-model.ps1 gemma4                    # in one terminal
.\connect-dsh.ps1 -Port 8083                # writes the route
dsh-tui                                     # /model -> the new route
```

`connect-dsh.ps1` edits `~\.dsh\profiles\dsh-tui\cordis.patch.yml`, backs it up first, and
validates the YAML afterwards (restoring the backup if the parse fails). dsh-tui watches that file
and hot-reloads it.

The shape it writes:

```yaml
      llama-gemma-4-e4b:
        baseURL: http://127.0.0.1:8083/v1
        api: openai-completions
        models:
          - id: gemma-4-e4b
            contextWindow: 32768
            maxTokens: 8192
```

Useful options: `-Name` to choose the route name, `-Context` to advertise the window you actually
started the server with.

---

## Claude Code

Claude Code speaks the **Anthropic Messages API**. `llama-server` has no `/v1/messages` route —
verified by scanning the binary — so a translation shim sits in between.

```
Claude Code  ->  anthropic-shim.py :8097  ->  llama-server :8083/v1
   (Anthropic)        (translates)              (OpenAI)
```

```powershell
.\connect-claude.ps1 -Port 8083             # starts the shim if needed, then launches claude
.\connect-claude.ps1 -Port 8083 -NoLaunch   # just set the environment, for scripting
```

It exports:

| variable | value |
|---|---|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:8097` |
| `ANTHROPIC_AUTH_TOKEN` | `local` |
| `ANTHROPIC_MODEL` | the served alias |
| `ANTHROPIC_SMALL_FAST_MODEL` | same |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` |
| `API_TIMEOUT_MS` | `600000` (local generation is slow; the default times out) |

The shim is reused when it already points at the same port, and restarted when you switch models.

---

## Anything else

```powershell
.\connect-any.ps1 -Port 8083
```

Prints copy-paste configs for curl, the Python and Node OpenAI SDKs, environment variables,
Continue.dev, Cline/Roo Code, Open WebUI and LangChain — all derived from what is actually running.

The generic form, for any client not listed:

```
Provider      : OpenAI compatible
Base URL      : http://127.0.0.1:<port>/v1
API Key       : local
Model         : <alias>
Context       : <= the server's -Ctx
```

---

## Client compatibility, by what they need

| client | needs | works here? |
|---|---|---|
| dsh-tui | OpenAI chat + tools | ✅ native, no proxy |
| Claude Code | Anthropic Messages | ✅ via `anthropic-shim.py` |
| Cline / Roo Code | OpenAI chat + tools | ✅ tools must be supported by the model |
| Continue.dev | OpenAI chat | ✅ |
| Open WebUI | OpenAI chat | ✅ set `OPENAI_API_BASE_URL` |
| LangChain / OpenAI SDK | OpenAI chat | ✅ |
| Aider | OpenAI chat | ✅ |
| Ollama clients | Ollama API (`/api/chat`) | ❌ use Ollama itself, or the OpenAI endpoint |

### Which models can actually use tools

An agent loop is only as good as the model's tool calling. Measured on this machine:

| model | structured `tool_calls` | note |
|---|---|---|
| `gemma-4-e4b` | ✅ | best default: 80 t/s, 96 ms to first token |
| `qwen3-8b` | ✅ | correct, but reasons first — allow 600+ output tokens |
| `qwen3.6-35b-a3b` | ✅ | newest and strongest here: 42.7 t/s, 2.8 s TTFT, 16k ctx |
| `flint-nvfp4-40b` | ✅ | 33 t/s in the same session, 3.9 s to first token |
| `qwen3.6-27b-a3b-coder` | ✅ | 44 t/s, 32k ctx — the coder that does call tools |
| `qwen2.5-coder-7b` | ❌ | writes the call as a JSON code block |
| `gpt-oss-20b` | ❌ | emits raw Harmony markup as text |

If tool calls fail, test the model directly before blaming the client:

```powershell
curl.exe -s http://127.0.0.1:8083/v1/chat/completions -H "content-type: application/json" `
  -d "{\"model\":\"gemma-4-e4b\",\"messages\":[{\"role\":\"user\",\"content\":\"weather in Paris? use get_weather\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}}}]}"
```

Look for `"finish_reason":"tool_calls"`. If it says `"stop"` and the answer is prose, the model
cannot do it — no client setting will fix that.

### Tools that live on the server: MCP

Those examples all hand the model a tool schema the *client* owns. `llama-server` can also host
tools itself: `--mcp-servers-config mcp\rea-mcp.json` spawns an MCP server over stdio at startup,
lists its tools once, stops it, and respawns it per call. The tools appear as `<server>_<tool>` on
`GET /tools` and in the Web UI's picker, and the server runs them — the client never sees the
transport.

```powershell
# which tools exist right now (39 for REA with the default scope, on a server started with the flag)
curl.exe -s http://127.0.0.1:8083/tools

# run one exactly the way the Web UI does, without a model in the loop
curl.exe -s -X POST http://127.0.0.1:8083/tools -H "content-type: application/json" `
  -d '{\"tool\":\"rea_binary_session\",\"arguments\":{\"detail\":\"summary\"}}'
```

Practical consequences:

- **The catalog is free until a chat selects tools, and expensive once it does.** A chat with no
  tools selected is ~22 prompt tokens however many are registered; select them and every schema
  goes into the request. REA's full 255 are 85 098 prompt tokens, which is more than `coder36`'s
  32 768-token window — that request fails before the model reads it (`request (85210 tokens)
  exceeds the available context size (32768 tokens)` is the Web UI's wording).
- **So the scope is a budget.** Here it is `session,enhanced` (39 tools, 12 402 tokens), and
  `llm-ctxfit.ps1` prints the arithmetic per preset. Widen with `llm-mcp.ps1 -Families ...` only
  after checking that table, and still select a handful of tools per chat rather than all of them.
- **A server without the flag has no MCP tools at all**, and `GET /tools` returns `[]` — that is the
  first thing to check when a client "sees no tools".
- **Timeouts.** Every MCP call is bounded by `timeout_ms` in the JSON (450 s here, because a cold
  Ghidra start is 330 s). A client-side timeout shorter than that will give up while the call is
  still working.

Which of these models can drive those tools is the table above; `coder` and `gptoss` cannot, so
their presets deliberately do not pass the flag.

---

## Reasoning models: the trap that looks like a broken server

Qwen3, Gemma 4 and most 2026 models think before answering. The chain of thought goes into a
separate `reasoning_content` field, and `content` only fills in afterwards.

With a small `max_tokens`, the whole budget is spent thinking and **`content` comes back empty** —
which looks exactly like a dead server. Give them 800+ tokens per turn. Claude Code's defaults are
fine; a bare `curl` test with `max_tokens: 100` is not.

---

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `Connection refused` | nothing is serving that port | `serve-model.ps1 -List`, then start one |
| `404 model not found` | model string ≠ `--alias` | `curl http://127.0.0.1:<port>/v1/models` and copy the id |
| `400` with a huge prompt | context overflow | raise `-Ctx`, or shorten the input |
| empty reply, no error | thinking model with a small budget | raise the client's max tokens |
| first token takes seconds | MoE paging experts from disk | normal for flint/gpt-oss; the second answer is faster |
| second model start kills the first | only one fits in 8 GB | expected |
| agent tool calls never fire | model has no native tool support | see the table above |
| slow but GPU idle | model is CPU-bound by design | check `bytes/token` with `llm-plan.ps1` |

---

## The files

| file | what it does |
|---|---|
| `serve-model.ps1` | start any model, auto-tuned, prints how to connect |
| `connect-dsh.ps1` | add/replace a dsh-tui route |
| `connect-claude.ps1` | start the Anthropic shim and launch Claude Code |
| `connect-any.ps1` | print configs for every other client |
| `anthropic-shim.py` | the Anthropic ⇄ OpenAI translation itself |
| `llm-up.ps1` | the fixed-port registry (gemma4, flint, qwen3, coder, gptoss, qwen36) |
| `llm-server.ps1` | the low-level server launcher the others call |
| `llm-scenarios.ps1` | benchmark six real prompts and write a report |
| `llm-desktop.ps1` | rebuild the standalone `Desktop\llama.cpp` bundle |
| `llm-ncmoe-sweep.ps1` | find the lowest `-n-cpu-moe` that still loads |
| `llm-speccmp.ps1` | A/B speculative decoding on your own prompts |

---

## The standalone bundle

`Desktop\llama.cpp` is the same engine, models and tuning with no dependency on anything in
`C:\Users\fih\llm\bin`:

```
Desktop\llama.cpp\
  llama-server.exe, *.dll      the CUDA build, copied
  models\                       the GGUFs - hard links, 0 extra bytes
  presets\gemma4.cmd ...        one double-clickable preset per model
  START HERE.cmd                menu
  stop.cmd                      free the GPU
  README.md
```

Double-click a preset: it kills any running server, starts the model with its measured flags, and
opens the built-in chat UI at `http://127.0.0.1:<port>`. Or double-click **`llama-direct.exe`** on
the Desktop for the same thing in a window: pick a model, Start, and the browser opens by itself.

The endpoint it exposes is identical to the ones above, so every client in this document works
against it unchanged. Rebuild it any time with `C:\Users\fih\llm\bin\llm-desktop.ps1`.

---

*Verified on MSI-Crosshair, Windows 11 build 28000, llama.cpp b12255 (CUDA 13.5), RTX 5060 Laptop
8 GB. Every command in this document was run, not copied.*

