#!/usr/bin/env python3
"""Build a CSV for the optional n8n data table `argus_bench_cases`.

  python3 scripts/bench-cases-csv.py [bench_set]   (default bench_set: v1)

Writes build/argus_bench_cases.csv with columns bench_set, case_id,
alert_json, facts. Import it in n8n (Data tables > argus_bench_cases >
Import CSV). `facts` freezes the Wazuh enrichment so every model sees the
same input; see docs/MODELS.md.
"""
import csv
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bench_set = sys.argv[1] if len(sys.argv) > 1 else "v1"
src = os.path.join(ROOT, "tests", "sample-alerts", "bench")
facts = json.load(open(os.path.join(src, "facts.json")))

os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
out = os.path.join(ROOT, "build", "argus_bench_cases.csv")
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["bench_set", "case_id", "alert_json", "facts"])
    for path in sorted(glob.glob(os.path.join(src, "0*.json"))):
        case = os.path.basename(path)[:2]
        alert = json.load(open(path))
        w.writerow([bench_set, case, json.dumps(alert, separators=(",", ":")), facts.get(case, "")])
print("wrote", os.path.relpath(out, ROOT))
