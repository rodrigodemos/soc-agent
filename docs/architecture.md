# Architecture

```
                                           Foundry Playground / VPN / Bastion
                                                          │
                                                          ▼
        ┌────────────────────────────────────────────────────────────────────┐
        │                       Private VNet (BYO or new)                    │
        │                                                                    │
        │   ┌──────────────────┐   ┌─────────────────┐   ┌────────────────┐  │
        │   │  Agent subnet    │   │   PE subnet     │   │   MCP subnet   │  │
        │   │ delegated to     │   │ private         │   │ user-deployed  │  │
        │   │ Microsoft.App/   │   │ endpoints       │   │ Container Apps │  │
        │   │ environments     │   │                 │   │                │  │
        │   │                  │   │  ▸ Foundry      │   │  ▸ MCP HTTP    │  │
        │   │  ▸ Hosted agent  │   │  ▸ Cosmos DB    │   │    server      │  │
        │   │    (Foundry)     │   │  ▸ AI Search    │   │  ▸ (future:    │  │
        │   │                  │   │  ▸ Storage      │   │    A2A,        │  │
        │   │                  │   │  ▸ ACR          │   │    Functions,  │  │
        │   │                  │   │  ▸ AppInsights  │   │    …)          │  │
        │   │                  │   │    (AMPLS)      │   │                │  │
        │   └────────┬─────────┘   └────────┬────────┘   └────────┬───────┘  │
        │            │                      │                     │          │
        │            └──────────────────────┴─────────────────────┘          │
        │                              private DNS                           │
        └────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Where it lives | Why it's there |
|-----------|----------------|----------------|
| Foundry account | RG, `publicNetworkAccess: Disabled` | Public access disabled; backend tools reachable only via PEs |
| Foundry project | sub-resource of account | Hosts the capability host and connections |
| Capability host (kind=Agents) | sub-resource of project | Threading + storage + vector connections for agents; created by Bicep (no bash script) |
| Agent (hosted) | Agent subnet (delegated to ACA env) | Runs the Copilot SDK app; injected by Foundry into the VNet |
| Cosmos DB / AI Search / Storage | PE subnet via private endpoints | BYO backends; AAD-only auth |
| ACR (Premium) | PE subnet via private endpoint | Holds agent + MCP-server images. Optional dev-IP allowlist for `azd deploy` |
| Application Insights + Log Analytics | RG; ingestion via AMPLS in PE subnet | Workspace-based; public ingestion disabled |
| MCP HTTP server | MCP subnet (Container App) | Sample tool the agent calls; the template ships one (`echo`), backlog has more |

## Request path (agent invocation)

1. Caller (Foundry Playground inside VPN, or another in-VNet client) POSTs to
   the agent's invocations endpoint.
2. The Foundry-hosted Container App (`src/copilot-agent`) lazily acquires a
   bearer token via `DefaultAzureCredential` for the project endpoint and
   instantiates the Copilot SDK `CopilotClient` with that token.
3. The Copilot SDK calls the Foundry model (private; routed via the project
   endpoint over the VNet's data proxy).
4. When the SDK invokes a tool, it talks to the MCP HTTP server over the
   private network (MCP subnet → ACA ingress on port 8080).
5. Session events stream back to the caller as SSE.

## Trace path

The agent has an `AppInsights` connection on the Foundry project (created by
`infra/modules/monitoring/application-insights.bicep`). OTel exports flow
**from the Agent subnet → PE subnet (AMPLS)** to the workspace-based
Application Insights — never over the public internet, since
`publicNetworkAccessForIngestion: Disabled`.
