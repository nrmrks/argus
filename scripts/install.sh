#!/usr/bin/env bash
# Import ARGUS into a running n8n container: credentials, workflows, Postgres
# tables, then publish the workflows. Run on the Docker host from the repo root:
#   scripts/install.sh            # container "argus-n8n" (docker-compose.yml)
#   N8N_CONTAINER=n8n scripts/install.sh
# Re-running is safe: credentials and workflows keep their fixed IDs and are
# overwritten with the freshly rendered versions.
set -euo pipefail
cd "$(dirname "$0")/.."
C="${N8N_CONTAINER:-argus-n8n}"

docker inspect "$C" >/dev/null 2>&1 || { echo "container $C not running (docker compose up -d)"; exit 1; }

python3 scripts/render.py

echo "== importing credentials"
# Stream through stdin so the file inside the container belongs to the n8n user.
docker exec -i "$C" sh -c 'umask 077; cat > /tmp/argus-credentials.json' < build/credentials.json
docker exec "$C" n8n import:credentials --input=/tmp/argus-credentials.json
docker exec "$C" rm -f /tmp/argus-credentials.json
rm -f build/credentials.json

echo "== importing workflows"
tar -C build/workflows -cf - . | docker exec -i "$C" sh -c 'rm -rf /tmp/argus-wf && mkdir -p /tmp/argus-wf && tar -C /tmp/argus-wf -xf -'
docker exec "$C" n8n import:workflow --separate --input=/tmp/argus-wf/
docker exec "$C" rm -rf /tmp/argus-wf

# n8n CLI commands inside a running container need a free task-broker port.
CLI=(docker exec -e N8N_RUNNERS_BROKER_PORT=5690 "$C" n8n)

echo "== creating Postgres tables (ARGUS · setup db)"
if "${CLI[@]}" execute --id=argusSetupDb0001 2>/dev/null | grep -q '"status": "success"'; then
  echo "   tables ready"
else
  echo "   setup db FAILED: check the 'ARGUS Postgres' credential, then run 'ARGUS · setup db' in the n8n UI"
fi

echo "== publishing workflows"
for id in argusErrors00001 argusAgentTool01 argusPipeline001 argusChat0000001; do
  if "${CLI[@]}" publish:workflow --id="$id" >/dev/null 2>&1; then
    echo "   published $id"
  else
    echo "   could not publish $id (publish it in the n8n UI)"
  fi
done

echo "== restarting n8n to load the published workflows"
docker restart "$C" >/dev/null
for _ in $(seq 1 30); do
  docker exec "$C" wget -qO- http://127.0.0.1:5678/healthz >/dev/null 2>&1 && break
  sleep 2
done

echo
echo "Done. Next (docs/INSTALL.md):"
echo "  1. Send a test alert:        tests/send-alert.sh"
echo "  2. Connect Wazuh:            wazuh/install-integration.sh on the Wazuh manager"
echo "  3. Check the flow counters:  run 'ARGUS · alert flow report' in n8n"
