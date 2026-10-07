#!/usr/bin/env python3
"""Wazuh integration: forward one alert to the ARGUS n8n webhook.

Called by wazuh-integratord as:
  custom-argus <alert_file> <api_key> <hook_url>
api_key is the shared secret, sent as the X-Wazuh-Secret header.
Uses the Python bundled with Wazuh (framework/python), which has requests.
"""
import json
import logging
import sys

import requests

LOG_FILE = "/var/ossec/logs/integrations.log"
logging.basicConfig(filename=LOG_FILE, level=logging.INFO,
                    format="%(asctime)s custom-argus: %(levelname)s %(message)s")


def main(argv):
    if len(argv) < 4:
        logging.error("usage: custom-argus <alert_file> <api_key> <hook_url>")
        return 2
    alert_file, secret, hook_url = argv[1], argv[2], argv[3]
    with open(alert_file) as f:
        alert = json.load(f)
    try:
        r = requests.post(hook_url, json=alert, timeout=10,
                          headers={"Content-Type": "application/json", "X-Wazuh-Secret": secret})
        r.raise_for_status()
    except requests.exceptions.RequestException as e:
        # 403 = wrong secret, 401 = header missing, 404 = workflow not published
        logging.error("failed to send alert %s: %s", alert.get("id"), e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
