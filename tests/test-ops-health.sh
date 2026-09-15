#!/usr/bin/env bash
set -euo pipefail

# P6 (0.5.0): `singular health --json` (compact digest, stable across idle
# calls), `singular gates` (malformed gates displayed not fatal), and
# `dag.sh next-areas --explain` exclusion reasons.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ops-health.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    { "id": "a", "stage": "S0", "area": "core", "layer": "x", "kind": "contract", "dependsOn": [], "requiredCompletion": "done" },
    { "id": "b", "stage": "S1", "area": "core", "layer": "x", "kind": "contract", "dependsOn": ["a"], "requiredCompletion": "done" },
    { "id": "c", "stage": "S1", "area": "aux", "layer": "x", "kind": "contract", "dependsOn": [], "requiredCompletion": "done" }
  ]
}
EOF
printf 'bound gate evidence\n' >"$root/x"
x_sha="$(shasum -a 256 "$root/x" | awk '{print $1}')"
cat >"$root/docs/orchestration/gates/a.gate-result.json" <<EOF
{"schema":"singular.orchestration.gate-result.v1","node":"a","status":"passed-with-acknowledged-baseline","authoritative":true,"evidenceClass":"grandfathered","verificationClassification":"not-rerun-evidence-verified","evidence":[{"kind":"source-path","ref":"x","sha256":"$x_sha","description":"t"}],"decidedBy":"test","recordedAt":"2026-06-01T00:00:00Z"}
EOF
printf '{broken json' >"$root/docs/orchestration/gates/c.gate-result.json"
git -C "$root" add . && git -C "$root" -c user.email=t@t -c user.name=t commit -q -m init

run_env() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_WORKTREES_DIR="$root/.worktrees" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" SINGULAR_TARGET_BRANCH=target "$@"
}

# 1. gates: passed + missing + malformed all displayed.
out="$(run_env bash "$SCRIPT_DIR/ops.sh" gates)"
assert_contains "$out" "passed 1/3" "gate count"
assert_contains "$out" "(no gate)" "missing gate shown"
assert_contains "$out" "invalid" "malformed gate shown, not fatal"

# Health exposes the seven normalized diagnostic categories with duplicate
# grouping, plus fail-closed human-gate state and derived descendant blockers.
mkdir -p "$root/docs/orchestration/human-gates"
printf 'approval bytes\n' >"$root/approval-artifact.txt"
python3 - "$root/docs/orchestration/dag.v0.json" \
  "$root/docs/orchestration/human-gates/a.human-gate.json" \
  "$root/approval-artifact.txt" "$root/.singular-state/events.ndjson" <<'PY'
import hashlib
import json
import sys

dag_path, request_path, artifact_path, events_path = sys.argv[1:]
dag = json.load(open(dag_path, encoding="utf-8"))
dag["nodes"][0]["humanGate"] = {
    "requestRef": "docs/orchestration/human-gates/a.human-gate.json",
    "approvalRef": "docs/orchestration/human-gates/a.human-approval.json",
}
with open(dag_path, "w", encoding="utf-8") as handle:
    json.dump(dag, handle)
artifact = open(artifact_path, "rb").read()
request = {
    "schema": "singular.orchestration.human-gate.v0",
    "gateId": "a-approval",
    "node": "a",
    "approvalType": "exact-artifact",
    "requiredOwner": "owner@example.com",
    "questions": [{"id": "risk", "prompt": "Accept risk?", "required": True}],
    "artifacts": [{
        "ref": "approval-artifact.txt",
        "sha256": hashlib.sha256(artifact).hexdigest(),
    }],
    "blockedNodes": ["b"],
    "createdAt": "2026-07-24T00:00:00Z",
    "expiresAt": "2099-07-25T00:00:00Z",
}
with open(request_path, "w", encoding="utf-8") as handle:
    json.dump(request, handle)
categories = [
    "product-failure",
    "orchestration-failure",
    "provider-failure",
    "optional-dependency-warning",
    "acknowledged-baseline",
    "infrastructure-inconclusive",
    "info",
]
with open(events_path, "w", encoding="utf-8") as handle:
    for index, category in enumerate(categories):
        event = {
            "ts": f"2026-07-24T00:00:0{index}Z",
            "type": f"test.{index}",
            "message": category,
            "data": {
                "diagnostic": {
                    "category": category,
                    "severity": (
                        "error" if category.endswith("-failure") else
                        "warning" if category != "info" else "info"
                    ),
                    "dedupeKey": f"test:{category}",
                }
            },
        }
        handle.write(json.dumps(event, separators=(",", ":")) + "\n")
    duplicate = {
        "ts": "2026-07-24T00:00:08Z",
        "type": "test.provider-repeat",
        "message": "provider repeated",
        "data": {
            "diagnostic": {
                "category": "provider-failure",
                "severity": "error",
                "dedupeKey": "test:provider-failure",
            }
        },
    }
    handle.write(json.dumps(duplicate, separators=(",", ":")) + "\n")
PY

# 2. health --json: parses, has digest, digest stable across two idle calls.
j1="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
d1="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["digest"])' "$j1")"
sleep 1
j2="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
d2="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["digest"])' "$j2")"
[[ "$d1" == "$d2" ]] || fail "digest must be stable across idle calls ($d1 vs $d2)"
python3 -c 'import json,sys
d=json.loads(sys.argv[1])
assert d["gates"]["passed"]==1 and d["gates"]["total"]==3, d["gates"]
assert isinstance(d["attention"], list)
assert d["breaker"]["threshold"]==5
categories = {
    "product-failure", "orchestration-failure", "provider-failure",
    "optional-dependency-warning", "acknowledged-baseline",
    "infrastructure-inconclusive", "info",
}
assert categories == set(d["diagnostics"]["counts"])
assert d["diagnostics"]["counts"]["provider-failure"] == 2
provider = next(
    item for item in d["diagnostics"]["items"]
    if item["dedupeKey"] == "test:provider-failure"
)
assert provider["count"] == 2
human = d["humanGates"]
assert human["total"] == 1 and human["approved"] == 0 and human["blocking"] == 1
assert human["states"] == {"pending": 1}
assert human["items"][0]["owner"] == "owner@example.com"
assert human["items"][0]["blockedNodes"] == ["b"]' "$j1" || fail "health fields"

# State change -> digest changes.
touch "$root/.singular-state/STOP"
j3="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
d3="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["digest"])' "$j3")"
[[ "$d3" != "$d1" ]] || fail "digest must change when state changes"
assert_contains "$j3" "STOP sentinel present" "attention lists STOP"
rm -f "$root/.singular-state/STOP"

# Restore the original DAG semantics before the dedicated frontier assertions.
python3 - "$root/docs/orchestration/dag.v0.json" <<'PY'
import json, sys
path = sys.argv[1]
dag = json.load(open(path, encoding="utf-8"))
dag["nodes"][0].pop("humanGate", None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(dag, handle)
PY

# 3. next-areas --explain: exclusion reasons for all three classes.
out="$(run_env bash "$SCRIPT_DIR/dag.sh" next-areas --explain)"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
frontier = {e["node"] for e in d["frontier"]}
excluded = {e["node"]: e for e in d.get("excluded", [])}
assert "b" in frontier or "b" in excluded, d
assert excluded["a"]["reason"] == "gate-passed", excluded
# c has a malformed gate (not passed) and no deps -> frontier
assert "c" in frontier, d
# b depends on a (passed) -> frontier
assert "b" in frontier, d
PY

# deps-not-gated reason: drop a's gate.
rm -f "$root/docs/orchestration/gates/a.gate-result.json"
out="$(run_env bash "$SCRIPT_DIR/dag.sh" next-areas --explain)"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
excluded = {e["node"]: e for e in d.get("excluded", [])}
assert excluded["b"]["reason"] == "deps-not-gated", excluded
assert excluded["b"]["unmetDeps"] == ["a"], excluded
PY

# 4. Existing ops health exposes reconciliation discovery state: index health,
# event backlog, sweep progress and remaining work, with actual counters. Cache
# state is reported, never treated as authority.
index_file="$root/.singular-state/reconcile-index.json"
absent="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
python3 - "$absent" <<'PYEOF'
import json, sys
doc = json.loads(sys.argv[1])
index = doc["reconcileIndex"]
assert index["present"] is False, index
assert index["healthy"] is False, index
assert index["authority"] == "discovery-only", index
assert index["reason"] == "missing-index", index
PYEOF
assert_contains "$absent" '"reconcileIndex"' "health exposes reconcile index state"

python3 - "$index_file" <<'PYEOF'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schema": "singular.orchestration.reconcile-index.v2",
    "authority": "discovery-only",
    "cycle": 7,
    "lastFullCycle": 7,
    "baselinePass": 2,
    "shared": {},
    "sharedDigest": "0" * 64,
    "events": {"offset": 10, "size": 42, "inode": 1, "headDigest": "1" * 64},
    "sweep": {"pass": 3, "started": True, "frontier": ["tasks|"],
              "entryCursor": "TASK-0002.md", "passEntries": 4},
    "entries": {
        "tasks/TASK-0001.md": {"identity": [1, 2, 3, 4], "content": "2" * 64,
                               "pass": 3, "taskId": "TASK-0001"},
        "tasks/TASK-0002.md": {"identity": [1, 3, 3, 4], "content": "3" * 64,
                               "pass": 2, "taskId": "TASK-0002"},
    },
    "diagnostics": {},
}), encoding="utf-8")
PYEOF
present="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
python3 - "$present" <<'PYEOF'
import json, sys
doc = json.loads(sys.argv[1])
index = doc["reconcileIndex"]
assert index["present"] is True, index
assert index["healthy"] is True, index
assert index["authority"] == "discovery-only", index
assert index["cycle"] == 7, index
assert index["entries"] == 2, index
assert index["eventBacklogBytes"] == 32, index
assert index["sweep"]["pass"] == 3, index
assert index["sweep"]["remainingEntries"] == 1, index
assert index["sweep"]["passComplete"] is False, index
PYEOF
text_health="$(run_env bash "$SCRIPT_DIR/ops.sh" health)"
assert_contains "$text_health" "reconcile:" "text health reports discovery index"
assert_contains "$text_health" "backlog=32" "text health reports actual event backlog"

printf '{broken\n' >"$index_file"
broken="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
python3 - "$broken" <<'PYEOF'
import json, sys
doc = json.loads(sys.argv[1])
index = doc["reconcileIndex"]
assert index["healthy"] is False, index
assert index["reason"] == "corrupt-index", index
assert doc["ok"] is False, doc["attention"]
assert any("reconciliation discovery index" in item for item in doc["attention"]), doc["attention"]
PYEOF
rm -f "$index_file"

echo "PASS: test-ops-health"
