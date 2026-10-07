#!/bin/bash
# Install the ARGUS integration on a Wazuh manager (4.x).
# Copy the wazuh/ folder to the manager, then run:
#   sudo bash install-integration.sh <webhook_url> [min_level]
# Example:
#   sudo bash install-integration.sh http://n8n.example.internal:5678/webhook/<WEBHOOK_PATH> 7
# It asks for the webhook secret (WEBHOOK_SECRET from .env), sends a test alert,
# backs up ossec.conf, adds one <integration> block and asks before restarting.
# Existing integrations are not touched.
set -euo pipefail

URL="${1:?usage: install-integration.sh <webhook_url> [min_level]}"
LEVEL="${2:-7}"
HERE="$(cd "$(dirname "$0")" && pwd)"
INT=/var/ossec/integrations
CONF=/var/ossec/etc/ossec.conf
NAME=custom-argus

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
[ -f "$CONF" ] || { echo "$CONF not found - is this a Wazuh manager?"; exit 1; }
if grep -q "<name>$NAME</name>" "$CONF"; then
  echo "$NAME is already configured in $CONF - nothing to do."; exit 0
fi

echo "1/4 Check that n8n is reachable..."
BASE="${URL%%/webhook/*}"
code=$(curl -s -m 8 -o /dev/null -w "%{http_code}" "$BASE/healthz" || true)
[ "$code" = "200" ] || { echo "n8n not reachable at $BASE (HTTP $code)"; exit 1; }

read -r -s -p "Webhook secret (WEBHOOK_SECRET from .env, input hidden): " SECRET; echo
SECRET="${SECRET//[$'\t\r\n ']/}"
[ -n "$SECRET" ] || { echo "Empty secret"; exit 1; }

echo "2/4 Install integration files and send a test alert..."
install -o root -g wazuh -m 750 "$HERE/custom-argus" "$INT/$NAME"
install -o root -g wazuh -m 750 "$HERE/custom-argus.py" "$INT/$NAME.py"
TEST=$(mktemp); chmod 644 "$TEST"
echo '{"timestamp":"2026-01-01T00:00:00.000+0000","rule":{"level":7,"description":"ARGUS integration test","id":"999200","groups":["test"]},"agent":{"id":"000","name":"wazuh-manager"},"full_log":"ARGUS integration test from the Wazuh manager"}' > "$TEST"
if ! sudo -u wazuh "$INT/$NAME" "$TEST" "$SECRET" "$URL"; then
  rm -f "$TEST"
  echo "Test alert FAILED (see /var/ossec/logs/integrations.log)."
  echo "403 = wrong secret, 401 = no header, 404 = 'ARGUS · pipeline' not published. ossec.conf NOT changed."
  exit 1
fi
rm -f "$TEST"
echo "   test alert accepted by n8n"

echo "3/4 Back up ossec.conf and add the integration block..."
BAK="$CONF.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$CONF" "$BAK"
NEW=$(mktemp)
S="$SECRET" U="$URL" L="$LEVEL" N="$NAME" awk '
  !done && /<\/ossec_config>/ {
    print "  <integration>"
    print "    <name>" ENVIRON["N"] "</name>"
    print "    <hook_url>" ENVIRON["U"] "</hook_url>"
    print "    <api_key>" ENVIRON["S"] "</api_key>"
    print "    <level>" ENVIRON["L"] "</level>"
    print "    <alert_format>json</alert_format>"
    print "  </integration>"
    done = 1 }
  { print }' "$CONF" > "$NEW"
cat "$NEW" > "$CONF"; rm -f "$NEW"; unset SECRET
echo "   changes (secret masked):"
diff "$BAK" "$CONF" | sed 's#<api_key>.*</api_key>#<api_key>***</api_key>#' || true
echo "   backup: $BAK"

read -r -p "4/4 Restart wazuh-manager now? Alert processing pauses for a few seconds [y/N] " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
  systemctl restart wazuh-manager
  echo "   wazuh-manager: $(systemctl is-active wazuh-manager)"
else
  echo "   Not restarted. Later: sudo systemctl restart wazuh-manager"
fi
echo "Rollback: sudo cp -p $BAK $CONF && sudo rm -f $INT/$NAME $INT/$NAME.py && sudo systemctl restart wazuh-manager"
