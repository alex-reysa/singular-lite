#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"
if [[ "${INCREMENTAL_RECONCILE_PRIVATE_CHILD:-}" != 1 ]]; then
  exec "$PYTHON" - "$0" <<'PY'
import os
import subprocess
import sys

env = {key: value for key, value in os.environ.items() if not key.startswith("SINGULAR_")}
env.update(INCREMENTAL_RECONCILE_PRIVATE_CHILD="1", PYTHONDONTWRITEBYTECODE="1")
raise SystemExit(subprocess.run(["/opt/homebrew/bin/bash", sys.argv[1]], env=env).returncode)
PY
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ "${INCREMENTAL_RETROSPECTIVE_BASELINE:-0}" != 1 ]]; then
repo="$tmp/repo"
tasks="$repo/tasks"
packets="$repo/packets"
leases="$repo/state/leases"
index="$repo/state/reconcile-index.json"
mkdir -p "$tasks" "$packets/TASK-1108" "$leases"

git -C "$repo" init -q
git -C "$repo" checkout -q -b target
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.local
printf 'base\n' >"$repo/app.txt"
git -C "$repo" add app.txt
git -C "$repo" commit -qm base
git -C "$repo" checkout -q -b worker
printf 'candidate\n' >"$repo/app.txt"
git -C "$repo" commit -qam candidate
candidate_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q target
git -C "$repo" branch -D worker >/dev/null

printf 'Task: TASK-1108\nStatus: ready\nDepends on: []\n' >"$tasks/TASK-1108.md"
printf '{"taskId":"TASK-1108","status":"accepted","headSha":"%s","branch":"worker"}\n' \
  "$candidate_head" >"$packets/TASK-1108/RUN-1.json"
printf '{"taskId":"TASK-1108","verdict":"accepted"}\n' \
  >"$packets/TASK-1108/RUN-1.audit.json"
printf '{"taskId":"TASK-1108","status":"accepted","campaignBinding":"campaign-a"}\n' \
  >"$leases/TASK-1108.json"

plan() {
  "$PYTHON" "$ROOT/engine/reconcile_index.py" plan \
    --index "$index" --tasks "$tasks" --packets "$packets" --leases "$leases" \
    --repo "$repo" \
    --target-head "$1" --policy "$2" --campaign "$3" --full-scan-every "$4"
}
commit_index() {
  "$PYTHON" "$ROOT/engine/reconcile_index.py" commit \
    --index "$index" --tasks "$tasks" --packets "$packets" --leases "$leases" \
    --repo "$repo" \
    --target-head "$1" --policy "$2" --campaign "$3" --full-scan-every "$4" >/dev/null
}
assert_plan() {
  "$PYTHON" - "$1" "$2" "$3" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["runCanonical"] is (sys.argv[2] == "yes"), doc
assert doc["metrics"]["canonicalRequested"] == int(sys.argv[3]), doc
assert "expensiveHistoricalValidations" not in doc["metrics"], doc
assert doc["authority"] == "discovery-only", doc
assert doc["schema"] == "singular.orchestration.reconcile-index-plan.v1", doc
PY
}

# Initial reconstruction schedules the canonical validator and measures work by
# count, never elapsed time. Committing records only discovery identities.
first="$(plan head-a gate-a campaign-a 50)"
assert_plan "$first" yes 1
commit_index head-a gate-a campaign-a 50

# Candidate ref identity is part of canonical eligibility. Restoring a missing
# ref through packed-refs must invalidate the discovery baseline immediately.
git -C "$repo" branch worker "$candidate_head"
git -C "$repo" pack-refs --all --prune
restored_ref="$(plan head-a gate-a campaign-a 50)"
assert_plan "$restored_ref" yes 1
commit_index head-a gate-a campaign-a 50

# A wrong candidate ref and restoration to the audited head are distinct Git
# dependency identities even when packet and task bytes do not change.
git -C "$repo" branch -f worker target
wrong_head="$(plan head-a gate-a campaign-a 50)"
assert_plan "$wrong_head" yes 1
commit_index head-a gate-a campaign-a 50
git -C "$repo" branch -f worker "$candidate_head"
git -C "$repo" pack-refs --all --prune
restored_head="$(plan head-a gate-a campaign-a 50)"
assert_plan "$restored_head" yes 1
commit_index head-a gate-a campaign-a 50

# Commit and tree availability are canonical dependencies too. Removing and
# restoring each loose object changes no indexed artifact or target ref.
candidate_tree="$(git -C "$repo" rev-parse "$candidate_head^{tree}")"
for object_id in "$candidate_head" "$candidate_tree"; do
  object_path="$repo/.git/objects/${object_id:0:2}/${object_id:2}"
  saved_object="$tmp/object-$object_id"
  cp "$object_path" "$saved_object"
  rm "$object_path"
  unavailable="$(plan head-a gate-a campaign-a 50)"
  assert_plan "$unavailable" yes 1
  commit_index head-a gate-a campaign-a 50
  mkdir -p "$(dirname "$object_path")"
  cp "$saved_object" "$object_path"
  available="$(plan head-a gate-a campaign-a 50)"
  assert_plan "$available" yes 1
  commit_index head-a gate-a campaign-a 50
done

# The second unchanged cycle performs no historical content validation.
second="$(plan head-a gate-a campaign-a 50)"
assert_plan "$second" no 0

# Every dependency identity that can change canonical eligibility invalidates
# discovery. The canonical integrator remains the only acceptance authority.
for field in task packet audit lease; do
  case "$field" in
    task) printf '\nObjective: changed\n' >>"$tasks/TASK-1108.md" ;;
    packet) printf ' ' >>"$packets/TASK-1108/RUN-1.json" ;;
    audit) printf ' ' >>"$packets/TASK-1108/RUN-1.audit.json" ;;
    lease) printf ' ' >>"$leases/TASK-1108.json" ;;
  esac
  changed="$(plan head-a gate-a campaign-a 50)"
  assert_plan "$changed" yes 1
  commit_index head-a gate-a campaign-a 50
done
for args in 'head-b gate-a campaign-a' 'head-b gate-b campaign-a' 'head-b gate-b campaign-b'; do
  changed="$(plan $args 50)"
  assert_plan "$changed" yes 1
  commit_index $args 50
done

# A same-size change with restored timestamps evades the cheap identity scan,
# then is found by the bounded periodic full-content scan. The fixture advances
# deterministic scan cycles; it makes no timing-based causal claim.
"$PYTHON" - "$tasks/TASK-1108.md" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
before = p.stat()
raw = p.read_bytes()
replacement = raw.replace(b"changed", b"CHANGED")
assert len(replacement) == len(raw)
p.write_bytes(replacement)
os.utime(p, ns=(before.st_atime_ns, before.st_mtime_ns))
PY
quiet="$(plan head-b gate-b campaign-b 2)"
assert_plan "$quiet" no 0
periodic="$(plan head-b gate-b campaign-b 2)"
assert_plan "$periodic" yes 1
"$PYTHON" - "$periodic" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["scan"] == "full", doc
assert "content-changed" in doc["reasons"], doc
PY
commit_index head-b gate-b campaign-b 2

# Missing/corrupt state reconstructs safely. A process restart over a committed
# index remains unchanged, so discovery cannot itself duplicate publication.
printf '{broken\n' >"$index"
corrupt="$(plan head-b gate-b campaign-b 50)"
assert_plan "$corrupt" yes 1
commit_index head-b gate-b campaign-b 50
restart="$(plan head-b gate-b campaign-b 50)"
assert_plan "$restart" no 0

# A periodic content scan that finds no indexed byte change still schedules a
# canonical rediscovery. Its successful acknowledgement advances the watermark.
unchanged_full="$(plan head-b gate-b campaign-b 2)"
assert_plan "$unchanged_full" yes 1
"$PYTHON" - "$unchanged_full" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["scan"] == "full", doc
assert doc["metrics"]["contentHashes"] > 0, doc
assert "periodic-canonical-rediscovery" in doc["reasons"], doc
PY
commit_index head-b gate-b campaign-b 2
after_unchanged_full="$(plan head-b gate-b campaign-b 2)"
assert_plan "$after_unchanged_full" no 0
"$PYTHON" - "$after_unchanged_full" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["scan"] == "quick", doc
assert doc["metrics"]["contentHashes"] == 0, doc
PY
fi

# Exercise the real reconcile --actuate -> canonical integrate.sh path. A thin
# engine facade wraps only the integrator so the test can count actual calls;
# the wrapper always execs the production integrator. Runner and gate fixtures
# are local and never invoke a provider.
actual_repo="$tmp/actual-repo"
actual_orch="$actual_repo/docs/orchestration"
actual_state="$actual_repo/.singular-state"
fixture_engine="$tmp/fixture-engine"
engine_source="${INCREMENTAL_ENGINE_HOME:-$ROOT}"
canonical_count="$tmp/canonical-count"
validation_count="$tmp/validation-count"
dispatch_count="$tmp/dispatch-count"
publication_count="$tmp/publication-count"
mkdir -p "$actual_orch/tasks" "$actual_orch/packets/imported/TASK-2201" \
  "$actual_orch/gates" "$actual_state/runs/RUN-INCREMENTAL" "$fixture_engine"
cp -R "$engine_source/schemas" "$actual_repo/"
cp -R "$engine_source/engine/." "$fixture_engine/"
cat >"$fixture_engine/integrate.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf 'canonical\n' >>"$CANONICAL_COUNT_FILE"
wrapper_output="$(mktemp)"
trap 'rm -f "$wrapper_output"' EXIT
wrapper_rc=0
"$REAL_ENGINE_HOME/engine/integrate.sh" "$@" >"$wrapper_output" 2>&1 || wrapper_rc=$?
cat "$wrapper_output"
grep '^INTEGRATED ' "$wrapper_output" >>"$PUBLICATION_COUNT_FILE" 2>/dev/null || true
exit "$wrapper_rc"
SH
chmod +x "$fixture_engine/integrate.sh"

git -C "$actual_repo" init -q
git -C "$actual_repo" checkout -q -b target
git -C "$actual_repo" config user.name test
git -C "$actual_repo" config user.email test@example.local
cat >"$actual_repo/singular.config.json" <<'JSON'
{
  "schemaVersion": "v2",
  "targetBranch": "target",
  "gateCommand": "bash fixture-gate.sh",
  "bootstrap": {"required": false, "commands": []}
}
JSON
: >"$actual_repo/singular.config.sh"
: >"$actual_state/config.local.sh"
cat >"$actual_repo/fixture-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'validated\n' >>"$VALIDATION_COUNT_FILE"
[[ "$(cat app.txt)" == "candidate" ]]
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
cat >"$tmp/fixture-driver.sh" <<'SH'
#!/usr/bin/env bash
printf 'dispatched\n' >>"$DISPATCH_COUNT_FILE"
exit 0
SH
chmod +x "$actual_repo/fixture-gate.sh" "$tmp/fixture-driver.sh"
printf 'base\n' >"$actual_repo/app.txt"
printf '%s\n' '.singular-state/' '.worktrees/' '.singular-cache/' '.singular-evidence/' \
  >"$actual_repo/.gitignore"
cat >"$actual_orch/tasks/TASK-2201.md" <<'EOF'
# TASK-2201: Incremental canonical fixture

Status: accepted
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-2201-incremental`
Test policy: `strict_test_first`
Gate command: `bash fixture-gate.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise actual indexed canonical integration.

## Scope

Owned files:

- `app.txt`

## Acceptance Criteria

- The exact candidate integrates once.
EOF
git -C "$actual_repo" add .
git -C "$actual_repo" commit -qm baseline
git -C "$actual_repo" checkout -q -b agent/core/TASK-2201-incremental
printf 'candidate\n' >"$actual_repo/app.txt"
git -C "$actual_repo" commit -qam candidate
actual_head="$(git -C "$actual_repo" rev-parse HEAD)"
actual_tree="$(git -C "$actual_repo" rev-parse 'HEAD^{tree}')"

verification_run="$actual_state/runs/RUN-INCREMENTAL"
cp "$actual_orch/tasks/TASK-2201.md" "$verification_run/verification-task-contract-1.md"
printf '%s\n' '{"campaign":"legacy","policy":"legacy"}' \
  >"$verification_run/verification-policy-1.json"
"$PYTHON" "$engine_source/engine/gate-report.py" create-verification-request \
  --output "$verification_run/verification-request-1.json" \
  --task-id TASK-2201 --run-id RUN-INCREMENTAL --attempt 1 \
  --head-sha "$actual_head" --tree-sha "$actual_tree" --campaign legacy \
  --task-contract "$verification_run/verification-task-contract-1.md" \
  --policy-contract "$verification_run/verification-policy-1.json" \
  --suite-id task-contract-gate >/dev/null
(cd "$actual_repo" && env \
  PATH="/opt/homebrew/bin:$PATH" \
  VALIDATION_COUNT_FILE="$validation_count" \
  SINGULAR_ROOT="$actual_repo" SINGULAR_ORCH_DIR="$actual_orch" \
  SINGULAR_TASKS_DIR="$actual_orch/tasks" SINGULAR_STATE_DIR="$actual_state" \
  SINGULAR_RUNS_DIR="$actual_state/runs" SINGULAR_TARGET_BRANCH=target \
  SINGULAR_ENGINE_HOME="$engine_source" SINGULAR_DEFAULT_GATE_CMD='bash fixture-gate.sh' \
  SINGULAR_JSON_CONFIG_FILE="$actual_repo/singular.config.json" \
  SINGULAR_CONFIG_FILE="$actual_repo/singular.config.sh" \
  SINGULAR_LOCAL_CONFIG_FILE="$actual_state/config.local.sh" \
  /opt/homebrew/bin/bash "$engine_source/engine/gate-check.sh" RUN-INCREMENTAL \
    --task-id TASK-2201 \
    --verification-request "$verification_run/verification-request-1.json" \
    --task-contract "$verification_run/verification-task-contract-1.md" \
    --policy-contract "$verification_run/verification-policy-1.json" \
    --attempt 1) >/dev/null
mv "$verification_run/gate-report.json" "$verification_run/audit-verification.json"
: >"$validation_count"

git -C "$actual_repo" checkout -q target
cat >"$actual_orch/packets/imported/TASK-2201/RUN-INCREMENTAL.json" <<JSON
{
  "schema":"singular.orchestration.state-packet.v0",
  "packetId":"RUN-INCREMENTAL",
  "runId":"RUN-INCREMENTAL",
  "taskId":"TASK-2201",
  "area":"core",
  "role":"l2-developer",
  "status":"accepted",
  "baseRef":"target",
  "branch":"agent/core/TASK-2201-incremental",
  "headSha":"$actual_head",
  "workspace":"$actual_repo",
  "ownedFiles":["app.txt"],
  "changedFiles":["app.txt"],
  "commands":[{"cmd":"bash fixture-gate.sh","exitCode":0}],
  "tests":[{"name":"incremental","phase":"regression","status":"passed"}],
  "evidence":[{"kind":"audit-verification","ref":"runs/RUN-INCREMENTAL/audit-verification.json"}],
  "blockers":[],
  "nextAction":"integrate",
  "createdAt":"2026-09-12T00:00:00Z"
}
JSON
cat >"$actual_orch/packets/imported/TASK-2201/RUN-INCREMENTAL.audit.json" <<JSON
{
  "schema":"singular.orchestration.audit-verdict.v1",
  "taskId":"TASK-2201",
  "runId":"RUN-INCREMENTAL",
  "branch":"agent/core/TASK-2201-incremental",
  "verdict":"accepted",
  "evidenceReviewed":["audit-verification.json","reviewed-head-sha:$actual_head"],
  "verificationResults":[{"status":"passed","command":"bash fixture-gate.sh","exitCode":0,"evidenceRefs":["audit-verification.json"],"rationale":"local host-bound fixture"}],
  "commandsRun":[],
  "findings":[],
  "requiredFixes":[],
  "rationale":"fixture accepted"
}
JSON
git -C "$actual_repo" add docs/orchestration/packets
git -C "$actual_repo" commit -qm packet
git -C "$actual_repo" branch -D agent/core/TASK-2201-incremental >/dev/null

count_lines() {
  if [[ -f "$1" ]]; then wc -l <"$1" | tr -d ' '; else printf '0'; fi
}
run_actual() {
  env \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/homebrew/bin:$PATH" \
    REAL_ENGINE_HOME="$engine_source" CANONICAL_COUNT_FILE="$canonical_count" \
    VALIDATION_COUNT_FILE="$validation_count" DISPATCH_COUNT_FILE="$dispatch_count" \
    PUBLICATION_COUNT_FILE="$publication_count" \
    SINGULAR_ROOT="$actual_repo" SINGULAR_ORCH_DIR="$actual_orch" \
    SINGULAR_TASKS_DIR="$actual_orch/tasks" SINGULAR_STATE_DIR="$actual_state" \
    SINGULAR_RUNS_DIR="$actual_state/runs" SINGULAR_LEASES_DIR="$actual_state/leases" \
    SINGULAR_WORKTREES_DIR="$actual_repo/.worktrees" \
    SINGULAR_ENGINE_HOME="$engine_source" SINGULAR_TARGET_BRANCH=target \
    SINGULAR_DEFAULT_GATE_CMD='bash fixture-gate.sh' \
    SINGULAR_JSON_CONFIG_FILE="$actual_repo/singular.config.json" \
    SINGULAR_CONFIG_FILE="$actual_repo/singular.config.sh" \
    SINGULAR_LOCAL_CONFIG_FILE="$actual_state/config.local.sh" \
    SINGULAR_RECONCILE_INDEX_FILE="$actual_state/reconcile-index.json" \
    SINGULAR_RECONCILE_FULL_SCAN_EVERY=50 \
    SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_GENERATE=0 SINGULAR_PUSH=0 \
    SINGULAR_MAX_DISPATCH=0 SINGULAR_DETACHED_DISPATCH=0 \
    SINGULAR_L1_DRIVER="$tmp/fixture-driver.sh" \
    SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC=999999 \
    "$@" /opt/homebrew/bin/bash "$fixture_engine/reconcile.sh" --actuate
}

actual_first="$(run_actual 2>&1)"
if [[ "${INCREMENTAL_RETROSPECTIVE_BASELINE:-0}" == 1 ]]; then
  [[ "$(count_lines "$canonical_count")" == 1 ]] \
    || { echo "$actual_first" >&2; exit 1; }
  # The uncorrected source acknowledges before its control-state commit. Run a
  # second still-missing cycle to stabilize that target identity, then restore
  # only the packed ref. The following public --actuate call must rediscover it.
  baseline_stabilize="$(run_actual 2>&1)"
  [[ "$(count_lines "$canonical_count")" == 2 ]] \
    || { echo "$baseline_stabilize" >&2; exit 1; }
  git -C "$actual_repo" branch agent/core/TASK-2201-incremental "$actual_head"
  git -C "$actual_repo" pack-refs --all --prune
  baseline_restored="$(run_actual 2>&1)"
  if [[ "$(count_lines "$canonical_count")" == 2 \
      && "$(count_lines "$validation_count")" == 0 \
      && "$baseline_restored" == *"integrated_this_run=0"* ]]; then
    echo "FAIL: restored packed candidate ref was not rediscovered by actual reconcile --actuate" >&2
    exit 1
  fi
  echo "PASS: retrospective baseline unexpectedly rediscovered restored ref"
  exit 0
fi
[[ "$actual_first" == *"canonical_integration_scans_this_run=1"* ]] \
  || { echo "$actual_first" >&2; exit 1; }
[[ "$actual_first" == *"integrated_this_run=0"* ]] \
  || { echo "$actual_first" >&2; exit 1; }
[[ "$(count_lines "$canonical_count")" == 1 ]] || exit 1
[[ "$(count_lines "$validation_count")" == 0 ]] || exit 1

# The immediately following unchanged cycle runs neither the canonical wrapper
# nor the expensive exact-tree gate.
actual_second="$(run_actual 2>&1)"
[[ "$actual_second" == *"canonical_integration_scans_this_run=0"* ]] \
  || { echo "$actual_second" >&2; exit 1; }
[[ "$(count_lines "$canonical_count")" == 1 ]] || exit 1
[[ "$(count_lines "$validation_count")" == 0 ]] || exit 1

# Disabling the index invokes the same production canonical integrator. While
# the branch is missing both modes agree there is no eligible integration.
actual_no_index="$(run_actual SINGULAR_RECONCILE_INDEX=0 2>&1)"
[[ "$actual_no_index" == *"canonical_integration_scans_this_run=1"* ]] || exit 1
[[ "$actual_no_index" == *"integrated_this_run=0"* ]] || exit 1

# Restore through packed-refs. The indexed path notices immediately, executes
# the real gate and integrator, then stops before index acknowledgement.
git -C "$actual_repo" branch agent/core/TASK-2201-incremental "$actual_head"
git -C "$actual_repo" pack-refs --all --prune
interrupted_rc=0
run_actual SINGULAR_TEST_INTERRUPT_BEFORE_RECONCILE_INDEX_ACK=1 \
  >"$tmp/interrupted-reconcile.out" 2>&1 || interrupted_rc=$?
[[ "$interrupted_rc" == 97 ]] \
  || { cat "$tmp/interrupted-reconcile.out" >&2; exit 1; }
grep -q 'INTEGRATED TASK-2201' "$tmp/interrupted-reconcile.out" || exit 1
[[ "$(count_lines "$validation_count")" == 1 ]] || exit 1
[[ "$(count_lines "$publication_count")" == 1 ]] || exit 1
[[ "$(grep -c '"type":"integration.integrated"' "$actual_state/events.ndjson")" == 1 ]] || exit 1

# A fresh process replays canonical work from the unacknowledged baseline, but
# terminal lifecycle and ancestry guards prevent another gate or publication.
actual_resume="$(run_actual 2>&1)"
[[ "$actual_resume" == *"canonical_integration_scans_this_run=1"* ]] \
  || { echo "$actual_resume" >&2; exit 1; }
[[ "$(count_lines "$validation_count")" == 1 ]] || exit 1
[[ "$(count_lines "$publication_count")" == 1 ]] || exit 1
[[ "$(grep -c '"type":"integration.integrated"' "$actual_state/events.ndjson")" == 1 ]] || exit 1

# Deleted and corrupt state both fail open to canonical discovery without
# duplicating the already accepted publication or dispatching a provider.
rm "$actual_state/reconcile-index.json"
actual_missing_index="$(run_actual 2>&1)"
[[ "$actual_missing_index" == *"canonical_integration_scans_this_run=1"* ]] || exit 1
printf '{broken\n' >"$actual_state/reconcile-index.json"
actual_corrupt_index="$(run_actual 2>&1)"
[[ "$actual_corrupt_index" == *"canonical_integration_scans_this_run=1"* ]] || exit 1
[[ "$(count_lines "$validation_count")" == 1 ]] || exit 1
[[ "$(count_lines "$dispatch_count")" == 0 ]] || exit 1
[[ "$(count_lines "$publication_count")" == 1 ]] || exit 1
[[ "$(grep -c '"type":"integration.integrated"' "$actual_state/events.ndjson")" == 1 ]] || exit 1

echo "PASS: test-incremental-reconcile"
