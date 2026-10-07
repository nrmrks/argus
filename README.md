# ARGUS — AI SOC analyst for Wazuh

ARGUS triages Wazuh alerts with a **local** LLM. Every alert at or above a level
threshold gets a plain-text analyst report: verdict, severity, affected host,
related activity and concrete next steps. Critical alerts additionally get a
deep investigation by a tool-using agent. Nothing leaves your network: Wazuh,
n8n, Postgres and the model all run on your own machines.

```
Wazuh manager ──(integration custom-argus, X-Wazuh-Secret)──► n8n webhook
                                                                │
                              Normalize ─► level ≥ 7 ─► suppress repeats (10 min)
                                                                │
 Wazuh indexer :9200 ◄── related alerts (24 h aggregations) ────┤  facts come from
 Wazuh API     :55000 ◄── host details (OS, status, groups) ────┤  the pipeline,
                                                                │  never from the model
                                            ARGUS triage (LLM, no reasoning, ~10 s)
                                                                │
                                   level ≥ 12 ─► ARGUS Investigator (agent + tools)
                                                 ─► evidence-only writer
                                                                │
                        Postgres: incident journal, alert-flow counters, errors
                        Delivery: Gmail / Jira (shipped disabled)
```

## Features

- **Fact-grounded reports.** Counts, hosts and history come from deterministic
  Wazuh queries; the model may only quote them. Tested against hallucinated
  counts and invented hosts.
- **Prompt-injection guard.** Instruction-like text inside alerts is flagged by
  the pipeline, not left to the model, and alert text is treated as untrusted.
- **Hybrid depth.** Fast single-call triage for everything, an agent with
  tools (alert search, host details, past incidents) for critical alerts.
- **ARGUS chat.** Ask in plain language: "what were the noisiest hosts in the
  last 24 hours?", "anything on 203.0.113.5 this week?".
- **Capacity data built in.** Every alert is counted per stage (received,
  suppressed, sent to the LLM, analyzed) with LLM latency, so you can size GPU
  hardware from your real alert volume.
- **One-command install** into Docker, with fixed workflow IDs and
  credentials generated from a single `.env`.

## Requirements

| Component | Tested with | Notes |
|---|---|---|
| Wazuh | 4.14 | manager + indexer + server API |
| Docker host | Ubuntu 24.04, Docker Compose v2 | runs n8n 2.42.3 and Postgres 16 |
| LLM server | LM Studio (OpenAI-compatible API) | GPU with ≥ 8 GB VRAM for a 9B model |
| Model | `qwen/qwen3.5-9b` Q4_K_M | see [docs/MODELS.md](docs/MODELS.md) for alternatives |
| Python 3 | on the Docker host | standard library only |

## Quick start

```bash
git clone <this repo> argus && cd argus
cp .env.example .env && chmod 600 .env   # fill in hosts, users, passwords
docker compose up -d                     # n8n + Postgres
scripts/install.sh                       # credentials, workflows, tables, publish
tests/send-alert.sh                      # synthetic alert -> check n8n Executions
```

Then connect Wazuh: copy `wazuh/` to the manager and run
`sudo bash install-integration.sh <webhook URL printed by install.sh>`.

Full guide: **[docs/INSTALL.md](docs/INSTALL.md)**.

## Documentation

| Document | What |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | step-by-step setup: Wazuh users, LLM server, n8n, integration |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the pipeline works and why |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | tuning, flow counters and GPU sizing, troubleshooting |
| [docs/MODELS.md](docs/MODELS.md) | model benchmark results and how to benchmark your own |
| [SECURITY.md](SECURITY.md) | security model and hardening checklist |

## Repository layout

| Path | What |
|---|---|
| `n8n/workflows/` | workflow templates with `__PLACEHOLDER__` tokens |
| `scripts/render.py` | fills templates and credentials from `.env` into `build/` |
| `scripts/install.sh` | imports everything into the n8n container and publishes it |
| `sql/schema.sql` | Postgres schema (same as the `ARGUS · setup db` workflow) |
| `prompts/` | the ARGUS system prompt (also stored in the pipeline's `ARGUS Config` node) |
| `wazuh/` | integration script and installer for the Wazuh manager |
| `tests/` | synthetic sample alerts, benchmark cases, `send-alert.sh` |

## Status

Proof of concept running against a production Wazuh. Reports are advisory:
ARGUS recommends actions but cannot block, isolate or change anything.
