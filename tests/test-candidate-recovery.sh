#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

state="$tmp/state"
tasks="$tmp/tasks"
mkdir -p "$state/leases" "$tasks" "$tmp/orchestration"
lease="$state/leases/TASK-1107.json"
task="$tasks/TASK-1107.md"
packet="$tmp/RUN-OLD.json"
audit="$tmp/RUN-OLD.audit.json"
old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
old_tree=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
new_head=cccccccccccccccccccccccccccccccccccccccc
new_tree=dddddddddddddddddddddddddddddddddddddddd
cat >"$task" <<'MD'
# TASK-1107 fixture
Gate command: `bash tests/run.sh test-candidate-recovery.sh`
MD
cat >"$packet" <<JSON
{"taskId":"TASK-1107","runId":"RUN-OLD","branch":"agent/old","headSha":"$old_head","status":"accepted"}
JSON
cat >"$audit" <<'JSON'
{"taskId":"TASK-1107","runId":"RUN-OLD","branch":"agent/old","verdict":"accepted"}
JSON
python3 "$ROOT/engine/task_lifecycle.py" retain-candidate --lease "$lease" \
  --packet "$packet" --audit "$audit" --task-file "$task" --task TASK-1107 \
  --run RUN-OLD --branch agent/old --head "$old_head" --tree "$old_tree" \
  --campaign legacy --acceptance-mode accepted >/dev/null
mkdir -p "$tmp/old-worktree/.singular-evidence"
printf 'tracked predecessor bytes\n' >"$tmp/old-worktree/tracked.txt"
printf 'untracked predecessor bytes\n' >"$tmp/old-worktree/untracked.txt"
printf 'historical evidence\n' >"$tmp/old-worktree/.singular-evidence/gate.log"
python3 - "$lease" "$tmp/old-worktree" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["worktree"]=sys.argv[2]; json.dump(d,open(p,"w"))
PY

# One durable failure identity is counted once across repeated publication and
# replay. Domains remain independent.
for ignored in 1 2; do
  python3 "$ROOT/engine/task_lifecycle.py" candidate-failed --lease "$lease" \
    --head "$old_head" --tree "$old_tree" --campaign legacy \
    --failure-class gate-red --target-head target-a --invalidation-key inputs-a \
    --failure-id failure-product-1 --domain product \
    --next-action "authorize repair or unchanged regate" >/dev/null
done
python3 "$ROOT/engine/task_lifecycle.py" candidate-failed --lease "$lease" \
  --head "$old_head" --tree "$old_tree" --campaign legacy \
  --failure-class git-lock-timeout --target-head target-a --invalidation-key lock-a \
  --failure-id failure-infra-1 --domain infrastructure \
  --next-action "retry host infrastructure" >/dev/null
python3 - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); c=d["acceptedCandidate"]
assert len(c["failures"]) == 2
assert d["failureBudgets"] == {"infrastructure": 1, "product": 1, "regate": 0}
PY

mkdir -p "$tmp/imported"
if python3 "$ROOT/engine/task_lifecycle.py" reserve --lease "$lease" --task TASK-1107 \
    --owner worker --run RUN-DENIED --branch agent/replay --area brain \
    --scope-json '[]' --base base --batch batch --worktree "$tmp/replay" \
    --imported-dir "$tmp/imported" >/dev/null 2>&1; then
  fail "retained failed candidate launched without host recovery authority"
fi

# A repair must have exact host evidence and distinct successor identities.
ops_env=(env SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$state"
  SINGULAR_LEASES_DIR="$state/leases" SINGULAR_TASKS_DIR="$tasks"
  SINGULAR_ORCH_DIR="$tmp/orchestration" SINGULAR_ENGINE_HOME="$ROOT/engine"
  SINGULAR_LOCAL_CONFIG_FILE=/dev/null)
out="$("${ops_env[@]}" "$ROOT/engine/ops.sh" recover-candidate TASK-1107 \
  --action repair --successor-run RUN-REPAIR --successor-branch agent/repair \
  --successor-worktree "$tmp/repair-worktree" --failure-id failure-product-1)" \
  || fail "host recovery entrypoint refused valid repair authority"
[[ "$out" == *"authorizationId="* && "$out" == *"distinct repair attempt"* ]] \
  || fail "host recovery entrypoint did not publish bounded next action"
python3 - "$lease" "$tmp" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); a=d["recoveryAuthorization"]
assert d["status"] == "ready"
assert "acceptedCandidate" not in d
assert d["candidateHistory"][0]["runId"] == "RUN-OLD"
assert a["action"] == "repair" and a["state"] == "issued"
assert a["freshAuditRequired"] is True
assert a["predecessorWorktree"] == sys.argv[2] + "/old-worktree"
PY
[[ "$(cat "$tmp/old-worktree/tracked.txt")" == "tracked predecessor bytes" \
    && "$(cat "$tmp/old-worktree/untracked.txt")" == "untracked predecessor bytes" \
    && "$(cat "$tmp/old-worktree/.singular-evidence/gate.log")" == "historical evidence" ]] \
  || fail "repair authorization changed predecessor work or evidence"
if "${ops_env[@]}" "$ROOT/engine/ops.sh" recover-candidate TASK-1107 \
    --action repair --successor-run RUN-REPAIR --successor-branch agent/repair \
    --successor-worktree "$tmp/repair-worktree" --failure-id failure-product-1 \
    >/dev/null 2>&1; then
  fail "repair authorization replay was accepted"
fi

# The changed candidate cannot be retained without a fresh accepted audit and
# exact successor binding.
cat >"$tmp/RUN-REPAIR.json" <<JSON
{"taskId":"TASK-1107","runId":"RUN-REPAIR","branch":"agent/repair","headSha":"$new_head","status":"accepted"}
JSON
cat >"$tmp/RUN-REPAIR.audit.json" <<'JSON'
{"taskId":"TASK-1107","runId":"RUN-REPAIR","branch":"agent/repair","verdict":"needs-fix"}
JSON
if python3 "$ROOT/engine/task_lifecycle.py" retain-candidate --lease "$lease" \
    --packet "$tmp/RUN-REPAIR.json" --audit "$tmp/RUN-REPAIR.audit.json" \
    --task-file "$task" --task TASK-1107 --run RUN-REPAIR --branch agent/repair \
    --head "$new_head" --tree "$new_tree" --campaign legacy \
    --acceptance-mode accepted >/dev/null 2>&1; then
  fail "repair candidate without fresh accepted audit was retained"
fi
python3 - "$tmp/RUN-REPAIR.audit.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["verdict"]="accepted"; json.dump(d,open(p,"w"))
PY
python3 "$ROOT/engine/task_lifecycle.py" retain-candidate --lease "$lease" \
  --packet "$tmp/RUN-REPAIR.json" --audit "$tmp/RUN-REPAIR.audit.json" \
  --task-file "$task" --task TASK-1107 --run RUN-REPAIR --branch agent/repair \
  --head "$new_head" --tree "$new_tree" --campaign legacy \
  --acceptance-mode accepted >/dev/null

# An unchanged regate is separately authorized, consumes no product failure,
# can be claimed exactly once, and preserves candidate/history publication.
python3 "$ROOT/engine/task_lifecycle.py" candidate-failed --lease "$lease" \
  --head "$new_head" --tree "$new_tree" --campaign legacy \
  --failure-class gate-red --target-head target-b --invalidation-key inputs-b \
  --failure-id failure-regate-1 --domain regate \
  --next-action "authorize unchanged regate" >/dev/null
cat >"$tmp/regate.json" <<JSON
{"schema":"singular.orchestration.recovery-authority.v0","taskId":"TASK-1107","predecessorRunId":"RUN-REPAIR","predecessorHeadSha":"$new_head","predecessorTreeSha":"$new_tree","campaignBinding":"legacy","policyIdentity":"legacy","failureId":"failure-regate-1","action":"regate","successorRunId":"RUN-REGATE","successorBranch":"agent/repair","successorWorktree":"$tmp/repair-worktree","authorizedBy":"host"}
JSON
auth_id="$(python3 "$ROOT/engine/task_lifecycle.py" authorize-recovery --lease "$lease" \
  --authority "$tmp/regate.json" --task-contract "$task" --expected-task TASK-1107 \
  --expected-campaign legacy --expected-policy legacy)"
python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
  --authorization-id "$auth_id" --action regate --head "$new_head" \
  --tree "$new_tree" --campaign legacy --run RUN-REGATE >/dev/null
if python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
    --authorization-id "$auth_id" --action regate --head "$new_head" \
    --tree "$new_tree" --campaign legacy --run RUN-REGATE >/dev/null 2>&1; then
  fail "regate authorization replay was accepted"
fi
python3 - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); c=d["acceptedCandidate"]
assert c["headSha"] == "cccccccccccccccccccccccccccccccccccccccc"
assert d["failureBudgets"] == {"infrastructure": 1, "product": 1, "regate": 1}
assert d["recoveryAuthorization"]["state"] == "consumed"
assert d["candidateHistory"][0]["headSha"] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PY

echo "PASS: test-candidate-recovery"
