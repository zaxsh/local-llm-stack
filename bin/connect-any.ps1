<#
.SYNOPSIS
    Print ready-to-paste connection configs for any client, against a running local model.

.DESCRIPTION
    Every local model here speaks the OpenAI Chat Completions API at /v1 on loopback. That is
    the whole contract - anything that can talk to OpenAI can talk to this. This script prints
    the exact strings for the common clients so there is nothing to guess.

.PARAMETER Port
    Port the model is serving on.

.PARAMETER Model
    The server's --alias. Defaults to whatever /v1/models reports.

.EXAMPLE
    .\connect-any.ps1 -Port 8083 -Model gemma-4-e4b
    .\connect-any.ps1 -Port 8084                       # id taken from the server
#>
[CmdletBinding()]
param(
    [int]$Port = 8083,
    [string]$Model = ''
)

$ErrorActionPreference = 'Stop'

try {
    $ids = @((Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 5).data.id)
} catch {
    Write-Host "  nothing is answering on 127.0.0.1:$Port" -ForegroundColor Red
    Write-Host "  start a model first:  .\serve-model.ps1 <name> -Port $Port" -ForegroundColor Yellow
    return
}
if (-not $Model) { $Model = $ids[0] }

$base = "http://127.0.0.1:$Port/v1"

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkGray
Write-Host "  base URL : $base"
Write-Host "  API key  : local        (anything non-empty; the server does not check)"
Write-Host "  model    : $Model"
if ($ids.Count -gt 1) { Write-Host "  also here: $((($ids | Where-Object { $_ -ne $Model }) -join ', '))" -ForegroundColor DarkGray }
Write-Host "  ============================================================" -ForegroundColor DarkGray
Write-Host ""

Write-Host "--- curl ------------------------------------------------------" -ForegroundColor Cyan
Write-Host @"
curl.exe -s $base/chat/completions ``
  -H "content-type: application/json" ``
  -d "{\"model\":\"$Model\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"
"@

Write-Host ""
Write-Host "--- Python (openai>=1.0) --------------------------------------" -ForegroundColor Cyan
Write-Host @"
from openai import OpenAI
client = OpenAI(base_url="$base", api_key="local")
r = client.chat.completions.create(
    model="$Model",
    messages=[{"role": "user", "content": "hello"}],
)
print(r.choices[0].message.content)
"@

Write-Host ""
Write-Host "--- Node / TypeScript (openai) --------------------------------" -ForegroundColor Cyan
Write-Host @"
import OpenAI from "openai";
const client = new OpenAI({ baseURL: "$base", apiKey: "local" });
const r = await client.chat.completions.create({
  model: "$Model",
  messages: [{ role: "user", content: "hello" }],
});
console.log(r.choices[0].message.content);
"@

Write-Host ""
Write-Host "--- Environment variables (most tools honour these) -----------" -ForegroundColor Cyan
Write-Host @"
`$env:OPENAI_BASE_URL  = "$base"
`$env:OPENAI_API_BASE  = "$base"
`$env:OPENAI_API_KEY   = "local"
`$env:OPENAI_MODEL     = "$Model"
"@

Write-Host ""
Write-Host "--- Continue.dev  (~/.continue/config.json) -------------------" -ForegroundColor Cyan
Write-Host @"
{
  "models": [{
    "title": "$Model (local)",
    "provider": "openai",
    "model": "$Model",
    "apiBase": "$base",
    "apiKey": "local"
  }]
}
"@

Write-Host ""
Write-Host "--- Cline / Roo Code  (settings -> API) -----------------------" -ForegroundColor Cyan
Write-Host "    Provider      : OpenAI Compatible"
Write-Host "    Base URL      : $base"
Write-Host "    API Key       : local"
Write-Host "    Model ID      : $Model"

Write-Host ""
Write-Host "--- Open WebUI -------------------------------------------------" -ForegroundColor Cyan
Write-Host "    OPENAI_API_BASE_URL=$base"
Write-Host "    OPENAI_API_KEY=local"

Write-Host ""
Write-Host "--- LangChain (python) ----------------------------------------" -ForegroundColor Cyan
Write-Host @"
from langchain_openai import ChatOpenAI
llm = ChatOpenAI(base_url="$base", api_key="local", model="$Model")
"@

Write-Host ""
Write-Host "  Two rules that matter more than the config:" -ForegroundColor Yellow
Write-Host "    1. the model string must equal the server's --alias, or you get a 404" -ForegroundColor DarkGray
Write-Host "    2. set the context window in the client to <= the server's -Ctx" -ForegroundColor DarkGray
Write-Host ""
