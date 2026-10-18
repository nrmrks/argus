# Security

ARGUS processes security alerts, which contain host names, user names, IPs and
log lines. The design keeps that data inside your network and limits what the
AI can do.

## Design

- **Local model.** Alerts go only to your own LLM server. No cloud API is used.
- **Read-only access.** The Wazuh indexer user needs `read` on
  `wazuh-alerts-*`; the API user needs `agents:read`. ARGUS has no tool that
  changes Wazuh, hosts or the network.
- **Authenticated webhook.** Wazuh sends a 64-hex-character shared secret in
  `X-Wazuh-Secret`; wrong secret = 403.
- **Untrusted alert text.** Prompt-injection patterns are flagged
  deterministically; the prompts tell the model that alert content is data,
  not instructions.
- **Secrets.** Credentials are stored encrypted in n8n. `.env` holds them in
  plain text on the Docker host (git-ignored, mode 600). `build/credentials.json`
  is deleted by `install.sh` right after import.
- **Test isolation.** Benchmark overrides (model choice, frozen facts) work only
  in editor runs, never through the production webhook. Manual runs are
  excluded from the incident history the agent reads.

## Hardening checklist

- [ ] Put n8n behind HTTPS (reverse proxy) and remove `N8N_SECURE_COOKIE=false`.
- [ ] Firewall: only the Wazuh manager may reach the webhook port; only n8n may
      reach the LLM server and Postgres.
- [ ] Trust the Wazuh CA in n8n and turn off "Ignore SSL issues"
      (`allowUnauthorizedCerts`) on the Wazuh HTTP nodes; it is on by default
      because Wazuh ships self-signed certificates.
- [ ] Use dedicated read-only Wazuh users, never `admin`.
- [ ] Set an LM Studio API token.
- [ ] Rotate `WEBHOOK_SECRET`: clear it in `.env`, run `scripts/install.sh`,
      then update the `<api_key>` in the manager's `ossec.conf`.
- [ ] Limit execution data retention (`EXECUTIONS_DATA_MAX_AGE`, default 14
      days in `docker-compose.yml`); executions contain alert content.
- [ ] Back up the n8n volume together with its encryption key, and Postgres.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability
reporting (Security tab > Report a vulnerability) and include steps to
reproduce.
