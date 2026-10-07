-- ARGUS Postgres schema (same as the 'ARGUS · setup db' workflow). Idempotent.
-- Generated from the live setup-db workflow; do not edit by hand.

CREATE TABLE IF NOT EXISTS argus_incidents (
  id BIGSERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source TEXT,
  path TEXT,
  execution_id TEXT,
  rule_id TEXT,
  rule_level INT,
  severity TEXT,
  rule_description TEXT,
  agent_id TEXT,
  agent_name TEXT,
  src_ip TEXT,
  verdict TEXT,
  model TEXT,
  injection_suspected BOOLEAN,
  tool_calls INT,
  report TEXT
);
CREATE INDEX IF NOT EXISTS argus_incidents_agent_idx ON argus_incidents (agent_name, created_at DESC);
CREATE INDEX IF NOT EXISTS argus_incidents_srcip_idx ON argus_incidents (src_ip, created_at DESC);

-- Inbound alert flow for volume sizing: one row per alert per stage
-- (received -> suppressed | forwarded -> analyzed by the LLM).
CREATE TABLE IF NOT EXISTS argus_alert_flow (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT now(),
  execution_id TEXT,
  source TEXT,
  stage TEXT NOT NULL,
  rule_id TEXT,
  level INT,
  severity TEXT,
  agent_id TEXT,
  agent_name TEXT,
  src_ip TEXT,
  rule_groups TEXT,
  llm_ok BOOLEAN,
  verdict TEXT,
  llm_latency_s REAL
);
ALTER TABLE argus_alert_flow ADD COLUMN IF NOT EXISTS rule_description TEXT;
CREATE INDEX IF NOT EXISTS argus_alert_flow_ts_idx ON argus_alert_flow (ts DESC, stage);
CREATE INDEX IF NOT EXISTS argus_alert_flow_agent_idx ON argus_alert_flow (agent_name, ts DESC);
CREATE INDEX IF NOT EXISTS argus_alert_flow_rule_idx ON argus_alert_flow (rule_id, ts DESC);

DROP VIEW IF EXISTS argus_flow_hourly;
CREATE VIEW argus_flow_hourly AS
SELECT date_trunc('hour', ts) AS hour,
  source,
  count(*) FILTER (WHERE stage = 'received') AS received,
  count(*) FILTER (WHERE stage = 'received' AND level >= 7) AS level_ge_7,
  count(*) FILTER (WHERE stage = 'received' AND level >= 12) AS level_ge_12,
  count(*) FILTER (WHERE stage = 'suppressed') AS suppressed,
  count(*) FILTER (WHERE stage = 'forwarded') AS forwarded_to_llm,
  count(*) FILTER (WHERE stage = 'analyzed' AND llm_ok) AS llm_ok,
  count(*) FILTER (WHERE stage = 'analyzed' AND NOT llm_ok) AS llm_failed,
  round(avg(llm_latency_s) FILTER (WHERE stage = 'analyzed')::numeric, 1) AS avg_llm_s,
  count(DISTINCT agent_name) FILTER (WHERE stage = 'received') AS agents
FROM argus_alert_flow
GROUP BY 1, 2;

-- Failed pipeline executions (written by the error-handler workflow).
CREATE TABLE IF NOT EXISTS argus_pipeline_errors (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT now(),
  workflow_id TEXT,
  workflow_name TEXT,
  execution_id TEXT,
  mode TEXT,
  last_node TEXT,
  message TEXT
);

SELECT (SELECT count(*) FROM argus_incidents) AS incidents, (SELECT count(*) FROM argus_alert_flow) AS flow_rows, (SELECT count(*) FROM argus_pipeline_errors) AS errors;
