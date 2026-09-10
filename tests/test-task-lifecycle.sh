#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

export SINGULAR_ROOT="$tmp/repo"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
export SINGULAR_DISPATCH_DIR="$SINGULAR_STATE_DIR/dispatch"
export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
mkdir -p "$SINGULAR_LEASES_DIR" "$SINGULAR_DISPATCH_DIR" "$SINGULAR_RUNS_DIR" \
  "$SINGULAR_WORKTREES_DIR" "$SINGULAR_TASKS_DIR" \
  "$SINGULAR_ORCH_DIR/packets/imported/TASK-0001"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lifecycle.sh"

task=TASK-0001
owner1=reconcile:RUN-1:TASK-0001
gen1="$(singular_lifecycle_reserve "$task" "$owner1" RUN-1 agent/test/TASK-0001 \
  test '["engine/example.sh"]' base-1 batch-1 "$SINGULAR_WORKTREES_DIR/$task")"
[[ "$gen1" == 1 ]] || fail "first reservation generation was $gen1"
singular_lifecycle_dispatch_record_write "$task" RUN-1 999999 gone fixture.log \
  base-1 batch-1 "$owner1" "$gen1"

if singular_lifecycle_finish "$task" stale-owner "$gen1" batch-1 stale stale 2>/dev/null; then
  fail "stale owner changed a reservation"
fi
[[ "$(singular_lease_status "$task")" == planned ]] || fail "stale owner changed lease status"

singular_lifecycle_finish "$task" "$owner1" "$gen1" batch-1 dispatch-tree-vanished retry
[[ "$(singular_lease_status "$task")" == failed ]] || fail "current owner did not close vanished dispatch"
singular_lifecycle_dispatch_finalize "$task" -1 crashed "$owner1" "$gen1"

owner2=reconcile:RUN-2:TASK-0001
gen2="$(singular_lifecycle_reserve "$task" "$owner2" RUN-2 agent/test/TASK-0001 \
  test '["engine/example.sh"]' base-2 batch-2 "$SINGULAR_WORKTREES_DIR/$task")"
[[ "$gen2" == 2 ]] || fail "successor reservation generation was $gen2"
if singular_lifecycle_finish "$task" "$owner1" "$gen1" batch-1 stale stale 2>/dev/null; then
  fail "predecessor closed successor in reserve-before-bind window"
fi
[[ "$(singular_lease_status "$task")" == planned ]] || fail "reserve-before-bind successor was not preserved"
singular_lifecycle_dispatch_record_write "$task" RUN-2 999998 gone fixture-2.log \
  base-2 batch-2 "$owner2" "$gen2"
if singular_lifecycle_finish "$task" "$owner1" "$gen1" batch-1 stale stale 2>/dev/null; then
  fail "predecessor generation changed successor reservation"
fi
[[ "$(singular_lease_status "$task")" == planned ]] || fail "successor reservation was not preserved"

# Complete the synthetic reservation and publish a real accepted authority.
singular_lifecycle_finish "$task" "$owner2" "$gen2" batch-2 dispatch-tree-vanished retry
singular_lifecycle_dispatch_finalize "$task" -1 crashed "$owner2" "$gen2"

# Native l1-drive still rewrites compatibility lease fields. The dispatch token
# authorizes its wrapper close, and lastReservationGeneration keeps the next
# reservation monotonic instead of restarting at one.
raw_task=TASK-0003
raw_owner=reconcile:RAW-1:TASK-0003
raw_gen="$(singular_lifecycle_reserve "$raw_task" "$raw_owner" RAW-1 agent/test/TASK-0003 \
  test '["engine/raw.sh"]' raw-base raw-batch "$SINGULAR_WORKTREES_DIR/$raw_task")"
singular_lifecycle_dispatch_record_write "$raw_task" RAW-1 999997 gone raw.log \
  raw-base raw-batch "$raw_owner" "$raw_gen"
python3 - "$(singular_lease_path "$raw_task")" <<'PY'
import json, sys
path = sys.argv[1]
lease = json.load(open(path, encoding="utf-8"))
lease = {
    "taskId": lease["taskId"], "branch": lease["branch"], "batchId": lease["batchId"],
    "baseSha": lease["baseSha"], "status": "running", "productPassStarted": True,
}
json.dump(lease, open(path, "w", encoding="utf-8"))
PY
singular_lifecycle_finish "$raw_task" "$raw_owner" "$raw_gen" raw-batch driver-exit-9 classify
singular_lifecycle_dispatch_finalize "$raw_task" 9 failed "$raw_owner" "$raw_gen"
raw_gen2="$(singular_lifecycle_reserve "$raw_task" reconcile:RAW-2:TASK-0003 RAW-2 \
  agent/test/TASK-0003 test '["engine/raw.sh"]' raw-base-2 raw-batch-2 \
  "$SINGULAR_WORKTREES_DIR/$raw_task")"
[[ "$raw_gen2" == 2 ]] || fail "generation restarted after native compatibility rewrite: $raw_gen2"

cat >"$SINGULAR_TASKS_DIR/$task.md" <<'EOF'
# TASK-0001: lifecycle fixture

Status: accepted
EOF
packet="$SINGULAR_ORCH_DIR/packets/imported/$task/RUN-ACCEPT.json"
audit="$SINGULAR_ORCH_DIR/packets/imported/$task/RUN-ACCEPT.audit.json"
cat >"$packet" <<'EOF'
{"taskId":"TASK-0001","runId":"RUN-ACCEPT","branch":"agent/test/TASK-0001","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"accepted"}
EOF
cat >"$audit" <<'EOF'
{"taskId":"TASK-0001","runId":"RUN-ACCEPT","branch":"agent/test/TASK-0001","verdict":"accepted"}
EOF
singular_lifecycle_retain_candidate "$task" "$packet" "$audit" "$SINGULAR_TASKS_DIR/$task.md" \
  RUN-ACCEPT agent/test/TASK-0001 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb campaign:test accepted >/dev/null
singular_lifecycle_candidate_failed "$task" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb campaign:test gate-red target-1 inputs-1 \
  "correct candidate before retry"

rc=0
out="$(singular_lifecycle_candidate_check "$task" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb campaign:test target-1 inputs-1 2>&1)" || rc=$?
[[ "$rc" == 3 && "$out" == *"correct candidate before retry"* ]] \
  || fail "unchanged failed gate was not suppressed"
singular_lifecycle_candidate_check "$task" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb campaign:test target-1 inputs-2 \
  || fail "changed gate/campaign/target invalidation input did not permit retry"

# Reconciliation of the same packet is idempotent and retains failure history.
state="$(singular_lifecycle_retain_candidate "$task" "$packet" "$audit" \
  "$SINGULAR_TASKS_DIR/$task.md" RUN-ACCEPT agent/test/TASK-0001 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  campaign:test accepted)"
[[ "$state" == integration-failed ]] || fail "unchanged reconciliation reset candidate state"
if singular_lifecycle_reserve "$task" retry-owner RUN-RETRY agent/test/TASK-0001 \
    test '["engine/example.sh"]' base-3 batch-3 "$SINGULAR_WORKTREES_DIR/$task" 2>/dev/null; then
  fail "accepted candidate was redispatched"
fi

python3 - "$(singular_lease_path "$task")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
c = d["acceptedCandidate"]
assert d["status"] == "accepted"
assert c["state"] == "integration-failed"
assert c["packetSha256"] and c["auditSha256"] and c["taskContractSha256"]
assert len(c["failures"]) == 1
PY

# A wrapper without reservation authority must not run its driver.
marker="$tmp/unattributed-driver-ran"
stub="$tmp/stub.sh"
cat >"$stub" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
chmod +x "$stub"
rc=0
"$SCRIPT_DIR/dispatch-wrap.sh" TASK-0999 "$stub" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 && ! -e "$marker" ]] || fail "unattributed wrapper launched its driver"

# Recovery cannot use stale Markdown to close a generated reservation when its
# owner-bound dispatch record is missing.
cat >"$SINGULAR_LEASES_DIR/TASK-0002.json" <<'EOF'
{"taskId":"TASK-0002","status":"running","reservationOwner":"owner","reservationGeneration":7,"runId":"RUN-X","updatedAt":"2000-01-01T00:00:00Z"}
EOF
cat >"$SINGULAR_TASKS_DIR/TASK-0002.md" <<'EOF'
# TASK-0002: stale projection

Status: accepted
EOF
out="$(SINGULAR_STALE_MINUTES=0 "$SCRIPT_DIR/recover.sh" --scan)"
[[ "$out" == *"lacks owner-bound dispatch authority"* ]] || fail "recovery did not expose actionable missing authority"
[[ "$(singular_lease_status TASK-0002)" == running ]] || fail "stale Markdown changed generated reservation"

echo "PASS: test-task-lifecycle"
