#!/usr/bin/env python3
"""Render ARGUS workflows and n8n credentials from .env.

  python3 scripts/render.py [--env .env]

Reads n8n/workflows/*.json (templates with __PLACEHOLDER__ tokens), fills them
from .env and writes:
  build/workflows/*.json   ready for `n8n import:workflow --separate`
  build/credentials.json   ready for `n8n import:credentials` (contains secrets,
                           mode 600; scripts/install.sh deletes it after import)

Missing WEBHOOK_PATH / WEBHOOK_SECRET are generated and written back to .env.
Only the Python standard library is used.
"""
import argparse
import json
import os
import re
import secrets
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REQUIRED = [
    "N8N_PUBLIC_URL", "POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_DB", "POSTGRES_USER",
    "POSTGRES_PASSWORD", "LLM_BASE_URL", "LLM_MODEL", "WAZUH_INDEXER_URL",
    "WAZUH_INDEXER_USER", "WAZUH_INDEXER_PASSWORD", "WAZUH_API_URL", "WAZUH_API_USER",
    "WAZUH_API_PASSWORD",
]
PLACEHOLDERS = {
    "__WAZUH_INDEXER_URL__": "WAZUH_INDEXER_URL",
    "__WAZUH_API_URL__": "WAZUH_API_URL",
    "__LLM_BASE_URL__": "LLM_BASE_URL",
    "__LLM_MODEL__": "LLM_MODEL",
    "__HARDWARE_LABEL__": "HARDWARE_LABEL",
    "__WEBHOOK_PATH__": "WEBHOOK_PATH",
    "__METRICS_TABLE_ID__": "METRICS_TABLE_ID",
    "__BENCH_CASES_TABLE_ID__": "BENCH_CASES_TABLE_ID",
    "__ALERT_EMAIL__": "ALERT_EMAIL",
    "__JIRA_PROJECT_ID__": "JIRA_PROJECT_ID",
    "__JIRA_ISSUE_TYPE_ID__": "JIRA_ISSUE_TYPE_ID",
}
# Nodes that depend on an optional setting; disabled when it is empty.
OPTIONAL_NODES = {
    "METRICS_TABLE_ID": ["Log Metrics", "All metrics"],
    "BENCH_CASES_TABLE_ID": ["Load Bench Cases"],
}


def read_env(path):
    env, lines = {}, open(path).read().splitlines()
    for line in lines:
        m = re.match(r"^\s*([A-Z0-9_]+)\s*=(.*)$", line)
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            env[m.group(1)] = v
    return env, lines


def write_back(path, lines, updates):
    out, done = [], set()
    for line in lines:
        m = re.match(r"^\s*([A-Z0-9_]+)\s*=", line)
        if m and m.group(1) in updates:
            out.append(f"{m.group(1)}={updates[m.group(1)]}")
            done.add(m.group(1))
        else:
            out.append(line)
    out += [f"{k}={v}" for k, v in updates.items() if k not in done]
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def json_escape(value):
    return json.dumps(value)[1:-1]  # safe inside an existing JSON string


def credentials(env):
    llm_url = env["LLM_BASE_URL"].rstrip("/") + "/v1"
    return [
        {"id": "argusCredPgsql01", "name": "ARGUS Postgres", "type": "postgres", "data": {
            "host": env["POSTGRES_HOST"], "port": int(env["POSTGRES_PORT"]), "database": env["POSTGRES_DB"],
            "user": env["POSTGRES_USER"], "password": env["POSTGRES_PASSWORD"]}},
        {"id": "argusCredIndex01", "name": "Wazuh Indexer", "type": "httpBasicAuth", "data": {
            "user": env["WAZUH_INDEXER_USER"], "password": env["WAZUH_INDEXER_PASSWORD"]}},
        {"id": "argusCredWzApi01", "name": "Wazuh API", "type": "httpBasicAuth", "data": {
            "user": env["WAZUH_API_USER"], "password": env["WAZUH_API_PASSWORD"]}},
        {"id": "argusCredLlmApi1", "name": "LM Studio", "type": "openAiApi", "data": {
            "apiKey": env.get("LLM_API_KEY") or "none", "url": llm_url}},
        {"id": "argusCredHook001", "name": "Wazuh Webhook Secret", "type": "httpHeaderAuth", "data": {
            "name": "X-Wazuh-Secret", "value": env["WEBHOOK_SECRET"]}},
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=os.path.join(ROOT, ".env"))
    args = ap.parse_args()
    if not os.path.exists(args.env):
        sys.exit(f"{args.env} not found: cp .env.example .env and fill it in")
    env, lines = read_env(args.env)

    updates = {}
    if not env.get("WEBHOOK_PATH"):
        updates["WEBHOOK_PATH"] = str(uuid.uuid4())
    if not env.get("WEBHOOK_SECRET"):
        updates["WEBHOOK_SECRET"] = secrets.token_hex(32)
    if updates:
        write_back(args.env, lines, updates)
        env.update(updates)
        print("generated and saved to .env:", ", ".join(updates))

    missing = [k for k in REQUIRED if not env.get(k)]
    if missing:
        sys.exit("missing in .env: " + ", ".join(missing))
    for k in ("POSTGRES_PASSWORD", "WAZUH_INDEXER_PASSWORD", "WAZUH_API_PASSWORD"):
        if env.get(k) == "change-me":
            print(f"warning: {k} is still 'change-me'")

    src = os.path.join(ROOT, "n8n", "workflows")
    dst = os.path.join(ROOT, "build", "workflows")
    os.makedirs(dst, exist_ok=True)
    for name in sorted(os.listdir(src)):
        if not name.endswith(".json") or name.startswith("."):
            continue
        text = open(os.path.join(src, name)).read()
        for token, key in PLACEHOLDERS.items():
            text = text.replace(token, json_escape(env.get(key, "")))
        wf = json.loads(text)
        for key, nodes in OPTIONAL_NODES.items():
            if not env.get(key):
                for n in wf["nodes"]:
                    if n["name"] in nodes:
                        n["disabled"] = True
        left = re.findall(r"__[A-Z_]+__", json.dumps(wf))
        if left:
            sys.exit(f"{name}: unfilled placeholders {sorted(set(left))}")
        with open(os.path.join(dst, name), "w") as f:
            json.dump(wf, f, indent=2, ensure_ascii=False)
        print("rendered", os.path.join("build", "workflows", name))

    cred_path = os.path.join(ROOT, "build", "credentials.json")
    fd = os.open(cred_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(credentials(env), f, indent=2)
    print("rendered build/credentials.json (secrets, mode 600)")

    print("\nWazuh webhook URL:", env["N8N_PUBLIC_URL"].rstrip("/") + "/webhook/" + env["WEBHOOK_PATH"])
    print("Next: scripts/install.sh  (see docs/INSTALL.md)")


if __name__ == "__main__":
    main()
