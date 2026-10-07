# Operations

## Day to day

- **n8n Executions** shows every alert run. Failed runs are also in Postgres:
  `SELECT * FROM argus_pipeline_errors ORDER BY ts DESC LIMIT 20;`
- **Journal**: `SELECT created_at, path, rule_id, agent_name, verdict FROM argus_incidents ORDER BY created_at DESC LIMIT 20;`
- **Chat**: open `ARGUS · chat` in n8n and use the chat panel, or publish its
  chat URL for the SOC team.

## Tuning

| What | Where | Default |
|---|---|---|
| Minimum level sent by Wazuh | `<level>` in the `custom-argus` block of `ossec.conf` | 7 |
| Minimum level analysed | `Level >= 7?` node | 7 |
| Repeat suppression window | `WINDOW_MIN` in `Normalize Alert` | 10 minutes |
| Deep investigation threshold | `Critical?` node | level ≥ 12 |
| Model, endpoint, temperature, max tokens, prompt | `ARGUS Config` node (from `.env` on render) | see `.env.example` |
| Reasoning for triage | `REASONING_EFFORT` in `Prepare LLM Request` | `none` |

Edit the templates in `n8n/workflows/` (or `.env`) and re-run
`scripts/install.sh`; edits made only in the n8n editor are overwritten by
the next install.

Keep `prompts/argus-system-prompt.md` identical to `ARGUS Config.system_prompt`
(stored there with a leading `=`; it must not contain `{{`).

## Alert volume and GPU sizing

Every alert is logged per stage in `argus_alert_flow`. Run
**`ARGUS · alert flow report`** (window in hours in the `Report Window` node)
or ask the chat "what was the ARGUS load in the last 24 hours?". You get:

- received, suppressed repeats, forwarded to the LLM, LLM ok / failed
- LLM latency average and p95
- peak received per hour, peak LLM calls per hour and per 5 minutes
- hourly series, top agents, top rules

Collect at least a week of production traffic (weekday peaks and weekend
lows), then size:

```
required output tokens/s ≈ peak LLM calls per hour × 800 / 3600
                            (× 5 or more if you turn reasoning on)
```

~800 output tokens per triage report is typical for a 9B model (prompt
≈ 1 750 tokens). Compare with the aggregate tokens/s your GPU delivers with
4 parallel slots (`ARGUS · LLM metrics report`). Plan for the **peak 5-minute
rate**, not the daily average: bursts after a Wazuh restart or during an
incident are several times the mean. More monitored hosts scale volume
roughly linearly; use alerts per host per day from the report to extrapolate.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Wazuh `integrations.log`: 403 | `X-Wazuh-Secret` does not match `WEBHOOK_SECRET`. |
| 404 from the webhook | `ARGUS · pipeline` not published. |
| `ECONNREFUSED` to the LLM | LM Studio bound to localhost: `lms server start --bind 0.0.0.0 --port 1234`. |
| Chat or investigator return empty text | LM Studio "separate reasoning_content" is on; turn it off (INSTALL.md step 2). |
| Investigator made no tool calls | Model runs with reasoning off; Qwen 3.x needs reasoning `low` for tool calls. |
| `model` column shows a different model | LM Studio silently uses the loaded model when the requested ID is unknown. Check `LLM_MODEL` against `GET /v1/models`. |
| "Context size has been exceeded" | Context is split across parallel slots; load 32768 / 4 or raise the context. |
| Postgres tool: `there is no parameter $3` | n8n drops empty values from `queryReplacement`. The shipped tools use `-` for "any"; keep that pattern in your own queries. |
| `n8n execute` / `publish:workflow` in the container: "Task Broker's port 5679 is already in use" | Run the CLI with `-e N8N_RUNNERS_BROKER_PORT=5690`, as `install.sh` does. |
| Host details: "Authorization failed" | Wazuh API user lacks `agents:read`, or the indexer user was used for the API. |
