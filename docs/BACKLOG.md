# Backlog — phase-2+ work

This template intentionally ships a minimal, customer-agnostic starter. The
items below are deliberately deferred so the bootstrap stays small and easy
to fork. None of them are in scope for what `azd up` provisions today.

Grouping mirrors the workstreams in typical SOC-agent project plans.

## Agent harness (WS2)

- [ ] Add a configurable system prompt (env var or `agent.manifest.yaml` field)
      instead of the hard-coded `_SYSTEM_PROMPT` in `src/copilot-agent/main.py`.
- [ ] Add structured tool-registration code so the agent advertises its
      configured MCP tools to the model.
- [ ] Optional GitHub Copilot model auth path (re-enable `GITHUB_TOKEN`) for
      a public-network sibling template.
- [ ] Local Foundry Playground harness for offline testing.

## Tools / MCP integrations (WS3)

- [ ] **Microsoft Sentinel MCP (Data Exploration)** — adopt the official
      Microsoft-hosted MCP; document egress requirements; wire to agent.
- [ ] **ServiceNow MCP (Path A)** — Foundry built-in tool → Logic Apps MCP.
- [ ] **ServiceNow MCP (Path B)** — custom **Azure Function MCP** exposing
      `search_incidents(query, ip?, time_range, state?, limit)`.
- [ ] **A2A server** sample (Container App on MCP subnet) — agent-to-agent
      delegation.
- [ ] **MCP hosting bake-off** — Functions vs Logic Apps vs APIM, with
      latency / cost / DX scorecards.

## Federated search (WS4)

- [ ] **Federated-search tool contract & source registry** — a single
      agent-facing tool with pluggable source adapters. Each source declares
      the filter shape it supports (IP, free text, time range minimum) and
      returns a common `{raw_hits[], summary}` envelope.
- [ ] **Sentinel Data Lake** adapter via the Sentinel MCP.
- [ ] **AWS S3 raw logs** adapter via Microsoft Fabric shortcuts (primary)
      and Athena (fallback).
- [ ] **ServiceNow Incidents** adapter via the Azure Function MCP.
- [ ] Multi-account / multi-bucket S3 fan-out.

## KQL generation & cookbooks (WS5)

- [ ] **Cookbook catalog** — Git-backed markdown + metadata; ~10 seed Sentinel
      Data Lake patterns.
- [ ] **Cookbook retrieval tool** + KQL gen tool that returns grounded
      suggestion + cited cookbook(s).
- [ ] Parse-check / syntax validator before the Sentinel MCP executes.
- [ ] Bidirectional cookbook contribution loop (agent learns new patterns).

## Governance, eval, demo (WS6)

- [ ] Eval set of ~20 analyst questions; CVE-driven golden scenario.
- [ ] Performance + stress test plan; KPI baselines (latency, success rate,
      cost per query).
- [ ] Trace PII redaction pipeline (currently flagged as security debt).
- [ ] Decision log + risk register templates.

## Platform & ops (WS1)

- [ ] Multi-environment promotion (dev → test → prod) with `azd` environment
      manifests and a CI/CD skeleton.
- [ ] Secrets rotation runbook; migrate any remaining key auth to managed
      identity (e.g. AWS access key → OIDC federation).
- [ ] Hub-and-spoke landing-zone integration examples (use the existing
      `existingDnsZones` / `existingMonitorDnsZones` params).
- [ ] Self-hosted CI agent inside the VNet for ACR pushes that don't rely
      on a developer-IP allowlist.
- [ ] Workbook / dashboard for agent telemetry.

## Repo housekeeping

- [ ] CI workflow (Bicep lint + Python lint/type-check).
- [ ] PR template + CODEOWNERS.
- [ ] Sample integration tests against a deployed environment.

---

Items here are not commitments — they are suggested directions for projects
that adopt this template. Trim or extend to match the team's roadmap.
