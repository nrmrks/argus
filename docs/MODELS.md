# Models

## Results

Measured with the 8 synthetic cases in `tests/sample-alerts/bench`, identical
frozen facts for every model, sent together (4 parallel slots, context 32768).
Hardware: RTX 4070 Ti 12 GB (504 GB/s), 128 GB RAM, LM Studio (llama.cpp CUDA).
Quality is a manual score against `tests/sample-alerts/bench/EXPECTED.md`.

| Model | Mode | Fits 12 GB | tok/s per stream | 8 alerts | Alerts/hour | Wh / alert | Quality | Verdict |
|---|---|---|---|---|---|---|---|---|
| deepseek-r1-distill-qwen-14b | always reasons | yes | 31–35 | 67–81 s | ~400 | — | 5/8, obeyed injection | avoid |
| **qwen3.5-9b** | reasoning off | **yes (8 GB)** | **47–51** | **31 s** | **~940** | **0.27** | **7/8** | **default** |
| qwen3.5-9b | reasoning on | yes | ~48 | 188 s | ~150 | 1.46 | 7/8, more careful | for critical alerts |
| gemma-4-12b-qat | reasoning off | yes (9.8 GB) | 28–36 | 45 s | ~640 | 0.28 | 7/8 | fallback |
| granite-4.1-8b | reasoning off | yes | 48–55 | 27 s | ~1 060 | 0.25 | 5/8 | no: suggested whitelisting a reverse-shell port |
| gpt-oss-20b | low | partly | ~20 | 71 s | ~400 | 0.23 | 5/8 | no |
| gemma-4-26b-a4b-qat (MoE) | reasoning off | no (VRAM + RAM) | ~12 | 96 s | ~300 | 0.24 | 7/8 | RAM-bound |
| **qwen3.6-35b-a3b (MoE)** | reasoning off | no (10 GB VRAM + 10 GB RAM) | ~11 | 159 s | ~180 | 0.34 | **8/8, best** | needs ≥ 24 GB VRAM |
| qwen3.8-27b (dense) | reasoning off | no | 2.8 | 587 s | ~49 | 1.31 | ~7.5/8 | unusable without VRAM |

## What we learned

1. **Reasoning is the main speed knob.** It adds 2 400–5 800 tokens per alert:
   5–10× slower for a small quality gain. For Qwen 3.x and Gemma 4 in LM Studio
   use `reasoning_effort: "none"` (`/no_think` does not work); gpt-oss accepts
   `"low"` at minimum.
2. **Whatever does not fit in VRAM is bound by RAM/PCIe, not the GPU.** The
   best-quality model ran at 10–12 tok/s with the GPU 12–20 % busy.
3. **Context is split across parallel slots.** 16k over 4 slots is 4k per
   request; reasoning models overflowed. KV-cache memory = context × slots.
4. **Parallelism is nearly free while the model fits in VRAM.** qwen3.5-9b kept
   ~49 tok/s per stream with 4 concurrent requests (~175 tok/s total).
5. **Never rely on the model for injection defence.** One model followed an
   instruction hidden in a username; the pipeline guard covers every model.
6. **Tool calling:** Qwen 3.x makes no tool calls with reasoning off. The
   investigator and chat run with reasoning `low`.

## Hardware guidance (extrapolated from the measurements)

| GPU class | Fits fully | Expected |
|---|---|---|
| 12 GB, ~500 GB/s (4070 Ti) | 9–12B | ~940 alerts/h with a 9B model, reasoning off |
| 24 GB, ~1 TB/s (4090 class) | 35B MoE (qwen3.6-35b-a3b) | best-quality model, roughly 5–8× faster than when spilled to RAM |
| 32 GB, ~1.8 TB/s (5090) | 27B dense, 35B MoE with large context | reasoning on every alert becomes practical (~300–600 alerts/h) |
| 96 GB or 2 × 24–32 GB | 70B class, many slots | multi-alert correlation, several models side by side |

Use your own alert volume (docs/OPERATIONS.md) to pick the class.

## Benchmark your own models

1. Create the n8n data table `argus_bench_cases` with string columns
   `bench_set`, `case_id`, `alert_json`, `facts`; generate the rows and import
   them via *Import CSV*:
   ```bash
   python3 scripts/bench-cases-csv.py v1     # -> build/argus_bench_cases.csv
   ```
   Put the table ID into `BENCH_CASES_TABLE_ID` (and create the metrics table,
   INSTALL.md step 8), then `scripts/install.sh`.
2. Load the candidate in LM Studio with context 32768 and 4 slots.
3. Open `ARGUS · pipeline` in the editor, click *Execute workflow* (it waits
   for a test webhook call) and send the benchmark request to the **test** URL:
   ```bash
   curl -X POST "$N8N_PUBLIC_URL/webhook-test/$WEBHOOK_PATH" \
     -H "X-Wazuh-Secret: $WEBHOOK_SECRET" -H 'Content-Type: application/json' \
     -d '{"bench_set":"v1","model":"<model id>","tag":"<run tag>","extra_body":{"reasoning_effort":"none"}}'
   ```
   Optional: `"cases":["07"]` for a subset, `"prompt_suffix":"..."` for prompt
   experiments. Benchmark overrides are honoured only in editor (test) runs, so
   the production webhook can never choose the model.
4. Run `ARGUS · LLM metrics report` and compare against `EXPECTED.md`.
   Check the `model` column: an unknown model ID silently falls back to the
   loaded model.
