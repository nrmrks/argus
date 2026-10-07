#!/usr/bin/env bash
# Send a sample alert to the ARGUS webhook exactly as Wazuh would.
#   tests/send-alert.sh [alert.json]
# Reads N8N_PUBLIC_URL, WEBHOOK_PATH and WEBHOOK_SECRET from .env.
# Needs the "ARGUS · pipeline" workflow published.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALERT="${1:-$ROOT/tests/sample-alerts/sshd-bruteforce-l10.json}"
get() { grep -E "^$1=" "$ROOT/.env" | tail -1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
URL="$(get N8N_PUBLIC_URL)"; P="$(get WEBHOOK_PATH)"; S="$(get WEBHOOK_SECRET)"
[ -n "$P" ] && [ -n "$S" ] || { echo "Run scripts/render.py first (WEBHOOK_PATH/SECRET empty)"; exit 1; }

curl -sS -X POST "${URL%/}/webhook/$P" \
  -H 'Content-Type: application/json' \
  -H "X-Wazuh-Secret: $S" \
  --data-binary @"$ALERT" -w '\nHTTP %{http_code}\n'
