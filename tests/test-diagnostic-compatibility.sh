#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/config" "$repo/custom-state" "$repo/custom-tasks"
config="$repo/config/runtime.json"
events="$repo/custom-state/events.ndjson"
dag="$repo/dag.json"

cat >"$config" <<'JSON'
{
  "schemaVersion":"v2",
  "runner":"codex-run.sh",
  "env":{
    "SINGULAR_TASKS_DIR":"custom-tasks",
    "SINGULAR_STATE_DIR":"custom-state",
    "SINGULAR_CODEX_IMPLEMENTER_MODEL":"gpt-5.6-sol",
    "SINGULAR_CODEX_AUDITOR_MODEL":"gpt-6-astra",
    "SINGULAR_CODEX_L2_REASONING_EFFORT":"high",
    "SINGULAR_CODEX_AUDITOR_REASONING_EFFORT":"medium"
  }
}
JSON
printf '{"nodes":[]}\n' >"$dag"
cat >"$events" <<'JSONL'
{"ts":"2026-09-11T10:00:00Z","type":"provider.model_rejected","message":"provider rejected requested model","data":{"diagnostic":{"category":"provider-failure","severity":"error","expected":false,"impact":"blocking","source":"provider","dedupeKey":"model-rejected","evidenceStatus":"provider-rejection","inventoryProvenance":"provider-response","providerRejected":true}}}
JSONL

effective="$(env SINGULAR_JSON_CONFIG_FILE='config/runtime.json' \
  python3 "$ROOT/engine/provider_resolver.py" effective-config --repo "$repo")"
health="$(python3 "$ROOT/engine/health_details.py" --repo "$repo" --dag "$dag" --events "$events")"

python3 - "$effective" "$health" "$repo" "$config" <<'PY'
import json, os, sys
effective, health = map(json.loads, sys.argv[1:3])
repo, config = map(os.path.realpath, sys.argv[3:5])
assert effective["configuration"] == {
    "path": config, "source": "selector", "status": "ok"
}, effective
assert effective["paths"] == {
    "root": repo,
    "tasks": os.path.join(repo, "custom-tasks"),
    "state": os.path.join(repo, "custom-state"),
}, effective
assert effective["roles"]["implementer"]["model"] == "gpt-5.6-sol", effective
assert effective["roles"]["implementer"]["reasoningEffort"] == "high", effective
assert effective["roles"]["auditor"]["model"] == "gpt-6-astra", effective
assert effective["roles"]["auditor"]["reasoningEffort"] == "medium", effective

diagnostics = health["diagnostics"]
assert diagnostics["schema"] == "singular.diagnostics.v2.1", diagnostics
item = diagnostics["items"][0]
# Existing consumer fields remain while 2.1 evidence qualifiers survive.
assert {"category", "severity", "expected", "impact", "source", "dedupeKey"} <= set(item), item
assert item["evidenceStatus"] == "provider-rejection", item
assert item["inventoryProvenance"] == "provider-response", item
assert item["providerRejected"] is True, item
PY

echo "PASS: test-diagnostic-compatibility"
