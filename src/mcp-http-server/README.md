# Minimal MCP HTTP Server (sample tool for SOC Copilot agent)

A trivial, **customer-agnostic** Model Context Protocol (MCP) server that runs
over **streamable HTTP** and exposes a single example tool (`echo`). It is
intended as a placeholder you replace with real SOC tools (Sentinel KQL,
ServiceNow lookup, S3 search, etc.).

Built on the official Anthropic [`mcp`](https://pypi.org/project/mcp/) Python
SDK using `FastMCP`'s streamable-HTTP transport, served by Uvicorn.

## Endpoints

- `GET  /healthz` — liveness probe (returns `{"status": "ok"}`)
- `POST /mcp`     — MCP streamable-HTTP transport
- `GET  /mcp`     — MCP streamable-HTTP transport (server-to-client stream)

## Add a tool

Drop a new Python file under `app/tools/` and register it in `app/main.py`:

```python
from .tools.your_tool import register as register_your_tool

register_your_tool(mcp)
```

Each tool file follows this shape:

```python
def register(mcp):
    @mcp.tool()
    def your_tool(arg: str) -> str:
        """Description shown to the agent."""
        return f"result: {arg}"
```

## Run locally

```powershell
cd src\mcp-http-server
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m app.main
```

The server listens on `0.0.0.0:8080` by default. Override with `PORT=...`.

## Deploy

This service is deployed by the parent template via `azd deploy` to a Container
App on the **MCP subnet** of the private VNet. The agent's Foundry project
connects to it as an MCP tool over the private network.
