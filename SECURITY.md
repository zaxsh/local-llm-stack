# Security notes

This project runs models on your own machine and talks to exactly one external service: the
Hugging Face Hub, and only when you ask it to download something.

## What leaves the machine

| when | what | where |
|---|---|---|
| you press Download, or run `llm-fetch.ps1` | the repo id and file name you asked for | `huggingface.co` |
| you press HF token..., or run `hf auth login` | the token itself, as a request header | `huggingface.co` |
| everything else, always | nothing | - |

The model serves on `127.0.0.1` only (`--host 127.0.0.1` is in every preset), so no other machine on
the network can reach it, and there is no telemetry, update check, or call home anywhere in `bin\`.

## The Hugging Face token

- Stored at `%USERPROFILE%\.cache\huggingface\token`, which is where every Hugging Face tool looks.
  That is deliberate: the token is not this app's private file, it is the machine's.
- Never passed on a command line (it travels as the `HF_TOKEN` environment variable) and never
  written to a log.
- Public models need no token at all. A token buys you gated repos and higher rate limits.
- Revoke it at `huggingface.co/settings/tokens` if it ever lands somewhere you did not intend.

## What is not in this repository

No model weights, no engine binaries (the downloader fetches them), no credentials, no `.env`, and
`.gitignore` refuses `*.env`, `token`, `stored_tokens`, `*credential*`, `*.pem`, `*.key`.

## Reporting

Open a normal issue for anything that is not a vulnerability. If it is one - the launcher starting a
process it was not asked to, the downloader writing outside `models\`, a token reaching a log - say
so in an issue titled `security:` without reproducing the secret.
