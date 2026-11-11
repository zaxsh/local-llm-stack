# presets

The six `.cmd` files here are the exact flags each model runs with, generated from the registry in
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

`bin\llm-selftest.ps1` checks that every preset still matches the registry: same model file, same
port, same context. If you edit the registry by hand, run it.
