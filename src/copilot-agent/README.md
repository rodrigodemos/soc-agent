# SOC Copilot Agent

A Microsoft Foundry **hosted agent** that runs the **GitHub Copilot SDK**
(`CopilotClient`) over the `azure-ai-agentserver-invocations` protocol and
streams session events as Server-Sent Events. Built for **private-network**
SOC scenarios with **BYOK** (Bring Your Own Foundry Model) authentication.

## Auth

This agent is **BYOK only**:

- Reads `FOUNDRY_PROJECT_ENDPOINT` and `AZURE_AI_MODEL_DEPLOYMENT_NAME`.
- Calls `DefaultAzureCredential` → `https://ai.azure.com/.default` → bearer token.
- Passes the token to the Copilot SDK as a `ProviderConfig` of type `azure`.

There is no `GITHUB_TOKEN` code path because this template targets a private
VNet where outbound traffic to `github.com` is normally blocked.

When deployed as a Foundry hosted agent, `FOUNDRY_PROJECT_ENDPOINT` is
**auto-injected** by the platform and the managed identity used by the agent
already has the required role assignments (provisioned by the parent template).

## Run locally

```powershell
cd src\copilot-agent
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy .env.example .env
# edit .env with your FOUNDRY_PROJECT_ENDPOINT and AZURE_AI_MODEL_DEPLOYMENT_NAME
python main.py
```

Then POST to the invocations endpoint with a prompt:

```powershell
curl.exe -N -H "Content-Type: application/json" `
  -d "{\"input\": \"investigate IP 1.2.3.4\"}" `
  http://localhost:8088/invocations
```

## Deploy

This service is deployed by the parent template via `azd up` / `azd deploy`.
See the [top-level README](../../README.md).

## System prompt

The default system prompt frames the agent as a SOC triage assistant; you can
override it by editing `_SYSTEM_PROMPT` in `main.py` or wiring an environment
variable.
