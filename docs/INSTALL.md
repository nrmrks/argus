# Installing ARGUS

About an hour if Wazuh and a GPU machine already exist. Steps:

1. [Wazuh: read-only users for ARGUS](#1-wazuh-read-only-users)
2. [LLM server](#2-llm-server)
3. [Configure `.env`](#3-configure-env)
4. [Start n8n and Postgres](#4-start-n8n-and-postgres)
5. [Install ARGUS into n8n](#5-install-argus-into-n8n)
6. [Test with a synthetic alert](#6-test-with-a-synthetic-alert)
7. [Connect Wazuh](#7-connect-wazuh)
8. [Optional: metrics table, benchmark, delivery](#8-optional-parts)

Network paths you need:

| From | To | Port |
|---|---|---|
| Wazuh manager | n8n | 5678 (webhook) |
| n8n | Wazuh indexer | 9200 |
| n8n | Wazuh server API | 55000 |
| n8n | LLM server | 1234 (LM Studio default) |
| n8n | Postgres | 5432 (internal when you use the bundled one) |

---

## 1. Wazuh: read-only users

ARGUS only reads from Wazuh. Give it two dedicated accounts, never `admin`.

**Indexer user** (alert search and aggregations). In the Wazuh dashboard:
*Indexer management > Security*:

1. *Roles > Create role* `argus_reader`: index pattern `wazuh-alerts-*`,
   index permissions `read`. No cluster permissions are needed.
2. *Internal users > Create* `argus_reader` with a strong password.
3. Map the user to the role (*Roles > argus_reader > Mapped users*).

Check from the n8n host:

```bash
curl -k -u argus_reader:PASSWORD "https://WAZUH:9200/wazuh-alerts-*/_count"
```

**Server API user** (host details: OS, status, groups). Needs only
`agents:read`. With an admin token from the manager:

```bash
API=https://localhost:55000
TOKEN=$(curl -sk -u wazuh:ADMIN_PASSWORD -X POST "$API/security/user/authenticate?raw=true")
H=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

curl -sk "${H[@]}" -X POST "$API/security/users" -d '{"username":"argus_api","password":"STRONG-Passw0rd!"}'
curl -sk "${H[@]}" -X POST "$API/security/policies" \
  -d '{"name":"argus_agents_read","policy":{"actions":["agents:read"],"resources":["agent:id:*","agent:group:*"],"effect":"allow"}}'
curl -sk "${H[@]}" -X POST "$API/security/roles" -d '{"name":"argus_api"}'
# then link: POST /security/roles/{role_id}/policies?policy_ids={policy_id}
#            POST /security/users/{user_id}/roles?role_ids={role_id}
# (ids are in the responses above)
```

Check: `curl -sk -u argus_api:PASSWORD -X POST "https://WAZUH:55000/security/user/authenticate?raw=true"`
must print a token.

## 2. LLM server

Tested with **LM Studio** on Linux with an NVIDIA GPU. Any OpenAI-compatible
server works for triage, but LM Studio's native `/api/v0` endpoint also
returns time-to-first-token and tokens/s, which ARGUS logs for sizing.

1. Download the model, e.g. `qwen/qwen3.5-9b` (Q4_K_M, ~8 GB VRAM).
2. Load it with **context 32768 and 4 parallel slots**. LM Studio splits the
   context across slots, so each request gets 8k tokens:
   ```bash
   lms load qwen/qwen3.5-9b --context-length 32768 --parallel 4
   ```
3. Start the server on all interfaces (the default binds to localhost only
   and n8n gets `ECONNREFUSED`):
   ```bash
   lms server start --bind 0.0.0.0 --port 1234
   ```
4. Enable an API token (Developer > API tokens) and put it in `LLM_API_KEY`.
5. In *Developer settings* turn **off** "separate `reasoning_content` and
   `content` in API responses" (`separateReasoningContentInAPI: false`).
   With it on, Qwen 3.x agents write their final answer into the reasoning
   field and the chat/investigator return empty text. ARGUS strips the
   `<think>` block itself.

Triage runs with reasoning off (`reasoning_effort: "none"`): 5 to 10 times
faster at nearly the same quality. The investigator and chat agents run with
reasoning `low`, because Qwen 3.x makes no tool calls with reasoning off.

## 3. Configure `.env`

```bash
cp .env.example .env && chmod 600 .env
```

Fill in every value; the comments in `.env.example` explain each one. Notes:

- `N8N_PUBLIC_URL` is the URL **the Wazuh manager** uses to reach n8n.
- With the bundled Postgres keep `POSTGRES_HOST=postgres`; just set a strong
  `POSTGRES_PASSWORD`.
- `LLM_BASE_URL` has no `/v1`, and must be reachable **from inside the n8n
  container** (use the LAN address, not `localhost`).
- Leave `WEBHOOK_PATH` and `WEBHOOK_SECRET` empty: they are generated on the
  first render and saved back into `.env`.

## 4. Start n8n and Postgres

```bash
docker compose up -d
docker compose ps        # both healthy / running
```

Open `N8N_PUBLIC_URL` in a browser and create the n8n owner account.

Already running n8n? Skip compose, point `POSTGRES_*` at a database n8n can
reach, and pass your container name: `N8N_CONTAINER=n8n scripts/install.sh`.

## 5. Install ARGUS into n8n

```bash
scripts/install.sh
```

It renders the templates from `.env`, imports 5 credentials and 7 workflows
with fixed IDs, creates the Postgres tables, publishes the workflows and
restarts n8n. Re-running it is safe; it overwrites the ARGUS workflows with
freshly rendered copies (so make lasting changes in the templates, not only
in the n8n editor).

| Workflow | ID | Published |
|---|---|---|
| ARGUS · pipeline | `argusPipeline001` | yes (webhook) |
| ARGUS · tool · get_wazuh_agent_details | `argusAgentTool01` | yes (called by the pipeline and chat) |
| ARGUS · chat | `argusChat0000001` | yes (chat UI) |
| ARGUS · error handler | `argusErrors00001` | yes (logs failed executions) |
| ARGUS · setup db | `argusSetupDb0001` | manual |
| ARGUS · alert flow report | `argusFlowReport1` | manual |
| ARGUS · LLM metrics report | `argusMetrics0001` | manual (needs the metrics table) |

## 6. Test with a synthetic alert

```bash
tests/send-alert.sh                                   # SSH brute force, level 10
tests/send-alert.sh tests/sample-alerts/bench/06-netstat-port-change-l7.json
```

Expect `HTTP 200`, then in n8n *Executions* a successful `ARGUS · pipeline`
run of about 10 to 15 seconds whose `Parse LLM Response` node holds the
report. Rows appear in Postgres (`argus_alert_flow`, `argus_incidents`).

| Response | Meaning |
|---|---|
| 403 | wrong `X-Wazuh-Secret` |
| 401 | header missing |
| 404 | pipeline not published |

## 7. Connect Wazuh

Copy the `wazuh/` folder to the manager and run, with the webhook URL that
`render.py` printed (`N8N_PUBLIC_URL/webhook/WEBHOOK_PATH`):

```bash
scp -r wazuh/ admin@wazuh-manager:/tmp/argus-wazuh
ssh -t admin@wazuh-manager 'sudo bash /tmp/argus-wazuh/install-integration.sh http://n8n.example.internal:5678/webhook/<WEBHOOK_PATH> 7'
```

The script asks for `WEBHOOK_SECRET`, installs `custom-argus` into
`/var/ossec/integrations`, sends a test alert, backs up `ossec.conf`, adds one
`<integration>` block (existing integrations are untouched) and asks before
restarting `wazuh-manager`. It prints the rollback command at the end.

After the restart, real alerts of level ≥ 7 start flowing. Expect a burst
right after the restart. Watch `/var/ossec/logs/integrations.log` on the
manager and *Executions* in n8n.

## 8. Optional parts

**LLM metrics table** (per-call tokens, TTFT, tokens/s; used by the benchmark
and the metrics report). In n8n *Data tables*, create `argus_llm_metrics` with
these columns, put its ID (from the URL) into `METRICS_TABLE_ID`, run
`scripts/install.sh` again:

```
ts:date source execution_id hardware model model_arch quant context_length:number
rule_id rule_level:number severity agent_name prompt_tokens:number
completion_tokens:number reasoning_tokens:number total_tokens:number ttft_s:number
tokens_per_s:number generation_s:number llm_latency_s:number enrich_latency_s:number
pipeline_latency_s:number stop_reason report_chars:number sections_ok:boolean
success:boolean error verdict injection_suspected:boolean report bench_case quality_flags
```
(columns without a type are strings)

**Benchmark cases**: see [MODELS.md](MODELS.md#benchmark-your-own-models).

**Delivery.** The `Send a message` (Gmail), `Send Raw Alert (AI failed)` and
`Create an issue` (Jira) nodes ship disabled. Create the Gmail OAuth2 / Jira
credentials in n8n, set `ALERT_EMAIL`, `JIRA_PROJECT_ID`,
`JIRA_ISSUE_TYPE_ID`, re-run `scripts/install.sh`, then enable the nodes.

**HTTPS.** Put n8n behind a reverse proxy with TLS and remove
`N8N_SECURE_COOKIE=false` from `docker-compose.yml`; see [SECURITY.md](../SECURITY.md).

## Uninstall

On the Wazuh manager, restore the `ossec.conf` backup printed by the
installer, remove `/var/ossec/integrations/custom-argus*` and restart the
manager. On the Docker host: `docker compose down -v` (deletes n8n and
Postgres data).
