# presets

The seven `.cmd` files here are the exact flags each model runs with, generated from the registry in
`bin/llm-up.ps1` by `bin/llm-desktop.ps1`. They are committed so you can read the tuning without
building anything - a preset is the whole argument list in one place.

They are **not** meant to be double-clicked from inside this folder: each one does `cd /d "%~dp0.."`
and expects `llama-server.exe` and `models\` next to its parent, which is true inside the built
bundle (`Desktop\llama.cpp\presets\`) and not true in a fresh clone.

To start a model from a clone, use either:

```powershell
.\llama-direct.exe                    # after get-started.ps1, pick from the list
.\bin\llm-up.ps1 gemma4              # start one by key, prints its URL
```

## The `--mcp-servers-config` line

Presets for models that can call tools end with:

```
--mcp-servers-config mcp\rea-mcp.json
```

That hands `llama-server` the REA tool server: it spawns REA at startup to list its tools (39 by
default), stops it, and respawns it per call. The tools appear as `rea_*` in the Web UI and on
`GET /tools`, and they are only sent to the model when you select them for a chat.

Which presets have it is decided by the registry, not by hand: `Mcp = 'rea'` on the entry. Today that
is `gemma4`, `flint`, `coder36` and `qwen36`. `coder` and `gptoss` do not get it because they
cannot emit a native tool call (measured: one writes a `<json>` block as text, the other leaks
Harmony markup), so a catalog would only clutter the picker. `qwen3` does not either: its window is
16 384 tokens and the default catalog is 12 402 of them, leaving nothing for the tool result.

The scope is a context cost, so the default catalog is the smallest one that can still open and
analyze a target (`session,enhanced`, 39 tools). Widen it deliberately, and check the arithmetic
before a chat fails on the first message:

```powershell
.\bin\llm-mcp.ps1 -Families session,direct,enhanced   # 80 tools
.\bin\llm-ctxfit.ps1                                  # FIT / TIGHT / OVER per preset
```

`mcp\rea-mcp.json` is **generated** - the absolute Node/REA/JDK/Ghidra paths in it belong to this
machine. Regenerate it after moving any of them:

```powershell
.\bin\llm-mcp.ps1            # rewrites mcp\rea-mcp.json
.\bin\llm-mcp.ps1 -Print     # show what it resolves, write nothing
```

`bin\llm-selftest.ps1` checks that every preset still matches the registry: same model file, same
port, same context, and the flag present exactly when the registry asks for it. If you edit the
registry by hand, run it.
