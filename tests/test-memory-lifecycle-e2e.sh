#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 "$ROOT/tests/test_memory_lifecycle.py"
SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/cli/singular" memory --help \
  | grep -q 'capture an untrusted cited proposal'

cmp -s "$ROOT/schemas/memory-record.v1.schema.json" \
  "$ROOT/schemas/orchestration/memory-record.v1.schema.json" || {
  echo "memory schema copies differ" >&2
  exit 1
}

python3 - "$ROOT/schemas/memory-record.v1.schema.json" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
assert schema["$id"] == "singular.orchestration.memory-record.v1"
assert schema["properties"]["schema"]["const"] == "singular.orchestration.memory-record.v1"
PY

echo "test-memory-lifecycle-e2e: all assertions passed"
