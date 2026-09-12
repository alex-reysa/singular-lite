#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo with spaces"
mkdir -p "$repo/config dir" "$repo/tasks custom" "$repo/state custom" \
  "$repo/docs/orchestration"
git -C "$repo" init -q
git -C "$repo" -c user.name=test -c user.email=test@example.com \
  commit -q --allow-empty -m init

cat >"$repo/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"wrong","env":{"SINGULAR_CODEX_MODEL":"wrong-model"}}
JSON
cat >"$repo/docs/orchestration/dag.v0.json" <<'JSON'
{"schema":"singular.orchestration.dag.v0","nodes":[{"id":"config-parity","stage":"S0","area":"brain","layer":"test","kind":"contract","dependsOn":[],"requiredCompletion":"done"}]}
JSON
cat >"$repo/config dir/custom.json" <<'JSON'
{
  "schemaVersion":"v2",
  "targetBranch":"main",
  "runner":"codex-run.sh",
  "env": {
    "SINGULAR_CODEX_IMPLEMENTER_MODEL":"gpt-5.6-sol",
    "SINGULAR_CODEX_AUDITOR_MODEL":"gpt-6-astra",
    "SINGULAR_CODEX_L2_REASONING_EFFORT":"high",
    "SINGULAR_CODEX_AUDITOR_REASONING_EFFORT":"medium",
    "SINGULAR_CODEX_SERVICE_TIER":"",
    "SINGULAR_TASKS_DIR":"tasks custom",
    "SINGULAR_STATE_DIR":"state custom"
  }
}
JSON

selector="config dir/custom.json"
doctor_json="$(cd / && env SINGULAR_JSON_CONFIG_FILE="$selector" \
  SINGULAR_CODEX_BIN=/bin/true HOME="$tmp/home" \
  python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$repo" \
    --bash "${BASH:-/bin/bash}" --bash-version "${BASH_VERSION:-5.0}" --json 2>/dev/null || true)"
console_json="$(cd / && env SINGULAR_JSON_CONFIG_FILE="$selector" \
  SINGULAR_ENGINE_HOME="$ROOT" python3 "$ROOT/plugin/scripts/singular_graph_server.py" \
    --repo "$repo" --config)"
effective_json="$(cd / && env SINGULAR_JSON_CONFIG_FILE="$selector" \
  python3 "$ROOT/engine/provider_resolver.py" effective-config --repo "$repo")"
cli_json="$(cd "$repo" && env SINGULAR_JSON_CONFIG_FILE="$selector" \
  SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN=/bin/true \
  bash "$ROOT/cli/singular" health --json)"

python3 - "$doctor_json" "$console_json" "$effective_json" "$cli_json" \
  "$repo/config dir/custom.json" <<'PY' \
  || fail "CLI, doctor and console did not resolve the same custom config"
import json, os, sys
doctor, console, effective, cli = map(json.loads, sys.argv[1:5])
path = os.path.realpath(sys.argv[5])
check = next(item for item in doctor["checks"] if item["id"] == "repo.config")
assert check["status"] == "pass", check
assert check["details"]["path"] == path, check
assert check["details"]["source"] == "selector", check
assert console["configuration"] == {"path": path, "source": "selector", "status": "ok"}, console
assert console["roles"]["implementer"]["model"] == "gpt-5.6-sol", console
assert console["roles"]["implementer"]["effort"] == "high", console
assert console["roles"]["auditor"]["model"] == "gpt-6-astra", console
assert console["roles"]["auditor"]["effort"] == "medium", console
assert console["roles"]["implementer"]["requestedServiceTier"] == "default", console
assert console["paths"]["tasks"] == os.path.join(os.path.dirname(os.path.dirname(path)), "tasks custom"), console
assert console["paths"]["state"] == os.path.join(os.path.dirname(os.path.dirname(path)), "state custom"), console
assert doctor["effectiveConfiguration"] == effective, doctor
assert cli["effectiveConfiguration"] == effective, cli
assert effective["configuration"] == console["configuration"], (effective, console)
assert effective["paths"] == console["paths"], (effective, console)
for role in ("implementer", "auditor"):
    assert effective["roles"][role]["model"] == console["roles"][role]["model"]
    assert effective["roles"][role]["reasoningEffort"] == console["roles"][role]["effort"]
PY

for bad in missing.json malformed.json; do
  [[ "$bad" != malformed.json ]] || printf '{bad\n' >"$repo/$bad"
  report="$(env SINGULAR_JSON_CONFIG_FILE="$bad" SINGULAR_CODEX_BIN=/bin/true \
    python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$repo" \
      --bash "${BASH:-/bin/bash}" --bash-version "${BASH_VERSION:-5.0}" --json 2>/dev/null || true)"
  python3 - "$report" "$repo/$bad" <<'PY' || fail "$bad did not fail actionably"
import json, os, sys
report = json.loads(sys.argv[1])
item = next(row for row in report["checks"] if row["id"] == "repo.config")
assert item["status"] == "fail", item
assert os.path.realpath(sys.argv[2]) in item["message"], item
PY
done

echo "PASS: test-effective-config-parity"
