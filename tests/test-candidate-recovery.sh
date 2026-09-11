#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

state="$tmp/state"
tasks="$tmp/tasks"
mkdir -p "$state/leases" "$state/runs" "$tasks" "$tmp/orchestration"
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
make_synthetic_verification() {
  local fixture_run="$1" fixture_head="$2" fixture_tree="$3"
  local run_path="$state/runs/$fixture_run"
  local request_path="$run_path/verification-request-1.json"
  local task_snapshot="$run_path/verification-task-contract-1.md"
  local policy_path="$run_path/verification-policy-1.json"
  local report_path="$run_path/audit-verification.json"
  mkdir -p "$run_path"
  cp "$task" "$task_snapshot"
  printf '%s\n' '{"campaign":"legacy","policy":"legacy"}' >"$policy_path"
  printf 'synthetic host gate passed\n' >"$run_path/gate.log"
  python3 "$ROOT/engine/gate-report.py" create-verification-request \
    --output "$request_path" --task-id TASK-1107 --run-id "$fixture_run" \
    --attempt 1 --head-sha "$fixture_head" --tree-sha "$fixture_tree" \
    --campaign legacy --task-contract "$task_snapshot" \
    --policy-contract "$policy_path" --suite-id task-contract-gate >/dev/null
  python3 "$ROOT/engine/gate-report.py" create --output "$report_path" \
    --task-id TASK-1107 --run-id "$fixture_run" --head-sha "$fixture_head" \
    --command 'bash tests/run.sh test-candidate-recovery.sh' --exit-code 0 \
    --log "$run_path/gate.log" --phase audit-verification \
    --workspace-kind disposable --integrity-status verified >/dev/null
  python3 "$ROOT/engine/gate-report.py" bind-verification-result \
    --request "$request_path" --report "$report_path" \
    --task-contract "$task_snapshot" --policy-contract "$policy_path"
}
cat >"$packet" <<JSON
{"taskId":"TASK-1107","runId":"RUN-OLD","branch":"agent/old","headSha":"$old_head","status":"accepted"}
JSON
cat >"$audit" <<JSON
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-1107","runId":"RUN-OLD","branch":"agent/old","verdict":"accepted","evidenceReviewed":["reviewed-head-sha:$old_head"]}
JSON
make_synthetic_verification RUN-OLD "$old_head" "$old_tree"
cp "$audit" "$tmp/RUN-OLD.audit.pristine.json"
python3 - "$audit" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d.pop("evidenceReviewed"); json.dump(d, open(p,"w"))
PY
if SINGULAR_RUNS_DIR="$state/runs" python3 "$ROOT/engine/task_lifecycle.py" retain-candidate \
    --lease "$lease" --packet "$packet" --audit "$audit" --task-file "$task" \
    --task TASK-1107 --run RUN-OLD --branch agent/old --head "$old_head" \
    --tree "$old_tree" --campaign legacy --acceptance-mode accepted >/dev/null 2>&1; then
  fail "v1 retention accepted an audit without a reviewed-head marker"
fi
cp "$tmp/RUN-OLD.audit.pristine.json" "$audit"
python3 - "$audit" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["evidenceReviewed"] *= 2; json.dump(d, open(p,"w"))
PY
if SINGULAR_RUNS_DIR="$state/runs" python3 "$ROOT/engine/task_lifecycle.py" retain-candidate \
    --lease "$lease" --packet "$packet" --audit "$audit" --task-file "$task" \
    --task TASK-1107 --run RUN-OLD --branch agent/old --head "$old_head" \
    --tree "$old_tree" --campaign legacy --acceptance-mode accepted >/dev/null 2>&1; then
  fail "v1 retention accepted duplicate reviewed-head markers"
fi
cp "$tmp/RUN-OLD.audit.pristine.json" "$audit"
cp "$packet" "$tmp/RUN-OLD.packet.pristine.json"
python3 - "$packet" "$new_head" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["headSha"]=sys.argv[2]; json.dump(d, open(p,"w"))
PY
make_synthetic_verification RUN-OLD "$new_head" "$old_tree"
if SINGULAR_RUNS_DIR="$state/runs" python3 "$ROOT/engine/task_lifecycle.py" retain-candidate \
    --lease "$lease" --packet "$packet" --audit "$audit" --task-file "$task" \
    --task TASK-1107 --run RUN-OLD --branch agent/old --head "$new_head" \
    --tree "$old_tree" --campaign legacy --acceptance-mode accepted >/dev/null 2>&1; then
  fail "unchanged-tree changed commit reused the old v1 audit"
fi
mv "$tmp/RUN-OLD.packet.pristine.json" "$packet"
make_synthetic_verification RUN-OLD "$old_head" "$old_tree"
if SINGULAR_RUNS_DIR="$state/runs" python3 "$ROOT/engine/task_lifecycle.py" retain-candidate \
    --lease "$lease" --packet "$packet" --audit "$audit" --task-file "$task" \
    --task TASK-1107 --run RUN-OLD --branch agent/old --head "$old_head" \
    --tree "$old_tree" --campaign campaign:relabeled \
    --acceptance-mode accepted >/dev/null 2>&1; then
  fail "direct retention relabeled a legacy verification tuple into another campaign"
fi
SINGULAR_RUNS_DIR="$state/runs" python3 "$ROOT/engine/task_lifecycle.py" retain-candidate --lease "$lease" \
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
if python3 "$ROOT/engine/task_lifecycle.py" candidate-failed --lease "$lease" \
    --head "$old_head" --tree "$old_tree" --campaign legacy \
    --failure-class gate-red --target-head target-a --invalidation-key inputs-a \
    --failure-id failure-product-1 --domain infrastructure \
    --next-action "misbound replay" >/dev/null 2>&1; then
  fail "failure identity replay changed its budget domain"
fi
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
  SINGULAR_LOCAL_CONFIG_FILE=/dev/null SINGULAR_JSON_CONFIG_FILE=/dev/null)
cp "$packet" "$tmp/RUN-OLD.pristine.json"
printf 'tampered\n' >>"$packet"
if "${ops_env[@]}" "$ROOT/engine/recover.sh" candidate TASK-1107 \
    --action repair --successor-run RUN-REPAIR --successor-branch agent/repair \
    --successor-worktree "$tmp/repair-worktree" --failure-id failure-product-1 \
    >/dev/null 2>&1; then
  fail "recovery authorization trusted a stale cached packet hash"
fi
[[ ! -e "$state/recovery-authority/TASK-1107/RUN-REPAIR.json" ]] \
  || fail "rejected recovery left replayable authority evidence"
mv "$tmp/RUN-OLD.pristine.json" "$packet"
python3 - "$lease" "$task" <<'PY'
import hashlib, json, sys
d=json.load(open(sys.argv[1])); expected=d["acceptedCandidate"]["taskContractSha256"]
actual=hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest()
assert actual == expected, (actual, expected, open(sys.argv[2]).read())
PY
out="$("${ops_env[@]}" "$ROOT/engine/recover.sh" candidate TASK-1107 \
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

# Reservation accepts only the authorized successor identity, even while the
# predecessor's accepted packet remains imported and immutable. The trusted
# scheduler may arrive with its ordinary task-contract placeholders; the
# lifecycle record itself must atomically capture the authorized successor so
# the real driver cannot launch the predecessor identity.
cp "$packet" "$tmp/imported/RUN-OLD.json"
if python3 "$ROOT/engine/task_lifecycle.py" reserve --lease "$lease" --task TASK-1107 \
    --owner worker --run RUN-WRONG --branch agent/repair --area brain \
    --scope-json '[]' --base base --batch batch --worktree "$tmp/repair-worktree" \
    --imported-dir "$tmp/imported" >/dev/null 2>&1; then
  fail "mismatched repair successor reservation was accepted"
fi
python3 "$ROOT/engine/task_lifecycle.py" reserve --lease "$lease" --task TASK-1107 \
  --owner reconcile:RUN-SCHEDULER:TASK-1107 --run RUN-SCHEDULER \
  --branch agent/original-contract --area brain --scope-json '[]' --base base \
  --batch batch --worktree "$tmp/original-contract-worktree" \
  --imported-dir "$tmp/imported" >/dev/null
python3 - "$lease" "$tmp/repair-worktree" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert d["runId"] == "RUN-REPAIR", d
assert d["branch"] == "agent/repair", d
assert d["worktree"] == sys.argv[2], d
assert d["reservationRunId"] == "RUN-REPAIR", d
PY

# The changed candidate cannot be retained without a fresh accepted audit and
# exact successor binding.
cat >"$tmp/RUN-REPAIR.json" <<JSON
{"taskId":"TASK-1107","runId":"RUN-REPAIR","branch":"agent/repair","headSha":"$new_head","status":"accepted"}
JSON
cat >"$tmp/RUN-REPAIR.audit.json" <<'JSON'
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-1107","runId":"RUN-REPAIR","branch":"agent/repair","verdict":"needs-fix"}
JSON
if python3 "$ROOT/engine/task_lifecycle.py" retain-candidate --lease "$lease" \
    --packet "$tmp/RUN-REPAIR.json" --audit "$tmp/RUN-REPAIR.audit.json" \
    --task-file "$task" --task TASK-1107 --run RUN-REPAIR --branch agent/repair \
    --head "$new_head" --tree "$new_tree" --campaign legacy \
    --acceptance-mode accepted >/dev/null 2>&1; then
  fail "repair candidate without fresh accepted audit was retained"
fi
python3 - "$tmp/RUN-REPAIR.audit.json" "$new_head" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["verdict"]="accepted"
d["evidenceReviewed"]=["reviewed-head-sha:" + sys.argv[2]]
json.dump(d,open(p,"w"))
PY
make_synthetic_verification RUN-REPAIR "$new_head" "$new_tree"
SINGULAR_RUNS_DIR="$state/runs" python3 "$ROOT/engine/task_lifecycle.py" retain-candidate --lease "$lease" \
  --packet "$tmp/RUN-REPAIR.json" --audit "$tmp/RUN-REPAIR.audit.json" \
  --task-file "$task" --task TASK-1107 --run RUN-REPAIR --branch agent/repair \
  --head "$new_head" --tree "$new_tree" --campaign legacy \
  --acceptance-mode accepted >/dev/null
cat >"$tmp/repair-gate.json" <<JSON
{"outcome":"passed","headSha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}
JSON
repair_proof="$(python3 "$ROOT/engine/task_lifecycle.py" candidate-tested \
  --lease "$lease" --head "$new_head" --tree "$new_tree" --campaign legacy \
  --tested-tree "$new_tree" --target-parent target-repair \
  --candidate-parent "$new_head" \
  --synthetic-commit eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  --gate-run RUN-REPAIR-GATE --gate-report "$tmp/repair-gate.json" \
  --gate-command 'bash fixture-gate')"
python3 "$ROOT/engine/task_lifecycle.py" candidate-integrated --lease "$lease" \
  --head "$new_head" --tree "$new_tree" --campaign legacy \
  --proof-id "$repair_proof" --merge ffffffffffffffffffffffffffffffffffffffff

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
# Capacity is checked again at execution because limits can change after an
# authority is issued.
python3 - "$lease" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["failureLimits"]["regate"]=1
json.dump(d, open(p,"w"))
PY
if python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
    --authorization-id "$auth_id" --action regate --head "$new_head" \
    --tree "$new_tree" --campaign legacy --run RUN-REGATE >/dev/null 2>&1; then
  fail "regate launched after its execution ceiling was reached"
fi
python3 - "$lease" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["failureLimits"]["regate"]=3
json.dump(d, open(p,"w"))
PY
cp "$tmp/regate.json" "$tmp/regate.pristine.json"
printf ' ' >>"$tmp/regate.json"
if python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
    --authorization-id "$auth_id" --action regate --head "$new_head" \
    --tree "$new_tree" --campaign legacy --run RUN-REGATE >/dev/null 2>&1; then
  fail "claim accepted changed recovery authority evidence"
fi
mv "$tmp/regate.pristine.json" "$tmp/regate.json"
cp "$task" "$tmp/task.pristine.md"
printf '\nchanged after authorization\n' >>"$task"
if python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
    --authorization-id "$auth_id" --action regate --head "$new_head" \
    --tree "$new_tree" --campaign legacy --run RUN-REGATE >/dev/null 2>&1; then
  fail "claim accepted changed task policy evidence"
fi
mv "$tmp/task.pristine.md" "$task"
python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
  --authorization-id "$auth_id" --action regate --head "$new_head" \
  --tree "$new_tree" --campaign legacy --run RUN-REGATE >/dev/null
python3 - "$lease" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["failureLimits"]["regate"]=1
json.dump(d, open(p,"w"))
PY
if python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
    --authorization-id "$auth_id" --action regate --head "$new_head" \
    --tree "$new_tree" --campaign legacy --run RUN-REGATE >/dev/null 2>&1; then
  fail "claimed crash-resume replay bypassed its execution ceiling"
fi
python3 - "$lease" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["failureLimits"]["regate"]=3
json.dump(d, open(p,"w"))
PY
# The exact same claim is resumable after a crash before gate publication;
# changed identities still cannot steal it.
python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
  --authorization-id "$auth_id" --action regate --head "$new_head" \
  --tree "$new_tree" --campaign legacy --run RUN-REGATE >/dev/null
if python3 "$ROOT/engine/task_lifecycle.py" claim-recovery --lease "$lease" \
    --authorization-id "$auth_id" --action regate --head "$new_head" \
    --tree "$new_tree" --campaign legacy --run RUN-OTHER >/dev/null 2>&1; then
  fail "regate claim was replayed with a different successor"
fi
cat >"$tmp/regate-overlap.json" <<JSON
{"schema":"singular.orchestration.recovery-authority.v0","taskId":"TASK-1107","predecessorRunId":"RUN-REPAIR","predecessorHeadSha":"$new_head","predecessorTreeSha":"$new_tree","campaignBinding":"legacy","policyIdentity":"legacy","failureId":"failure-regate-1","action":"regate","successorRunId":"RUN-REGATE-OVERLAP","successorBranch":"agent/repair","successorWorktree":"$tmp/repair-worktree","authorizedBy":"host"}
JSON
if python3 "$ROOT/engine/task_lifecycle.py" authorize-recovery --lease "$lease" \
    --authority "$tmp/regate-overlap.json" --task-contract "$task" \
    --expected-task TASK-1107 --expected-campaign legacy --expected-policy legacy \
    >/dev/null 2>&1; then
  fail "a second authorization replaced a claimed crash-resumable regate"
fi
python3 - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); c=d["acceptedCandidate"]
assert c["headSha"] == "cccccccccccccccccccccccccccccccccccccccc"
assert d["failureBudgets"] == {"infrastructure": 1, "product": 1, "regate": 1}
assert d["recoveryAuthorization"]["state"] == "claimed"
assert d["candidateHistory"][0]["headSha"] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PY

# Durable domain counters are enforcement inputs, not merely observability.
python3 - "$lease" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["failureLimits"]["regate"]=1
json.dump(d, open(p,"w"))
PY
python3 "$ROOT/engine/task_lifecycle.py" candidate-failed --lease "$lease" \
  --head "$new_head" --tree "$new_tree" --campaign legacy \
  --failure-class gate-red --target-head target-c --invalidation-key inputs-c \
  --failure-id failure-regate-2 --domain regate \
  --next-action "regate budget exhausted" >/dev/null
cat >"$tmp/regate-exhausted.json" <<JSON
{"schema":"singular.orchestration.recovery-authority.v0","taskId":"TASK-1107","predecessorRunId":"RUN-REPAIR","predecessorHeadSha":"$new_head","predecessorTreeSha":"$new_tree","campaignBinding":"legacy","policyIdentity":"legacy","failureId":"failure-regate-2","action":"regate","successorRunId":"RUN-REGATE-2","successorBranch":"agent/repair","successorWorktree":"$tmp/repair-worktree","authorizedBy":"host"}
JSON
if python3 "$ROOT/engine/task_lifecycle.py" authorize-recovery --lease "$lease" \
    --authority "$tmp/regate-exhausted.json" --task-contract "$task" \
    --expected-task TASK-1107 --expected-campaign legacy --expected-policy legacy \
    >/dev/null 2>&1; then
  fail "exhausted regate budget still granted execution authority"
fi

# Health excludes completed dependencies and retains actionable ownership for
# only the dependencies that are actually blocking now.
cat >"$tasks/TASK-1000.md" <<'MD'
# TASK-1000
Status: integrated
MD
cat >"$tasks/TASK-1001.md" <<'MD'
# TASK-1001
Status: ready
MD
cat >>"$task" <<'MD'
Status: ready
Depends on: [TASK-1000, TASK-1001]
MD
health="$("${ops_env[@]}" "$ROOT/engine/ops.sh" health --json)" \
  || fail "ops health failed for retained candidate"
python3 - "$health" <<'PY'
import json, sys
d=json.loads(sys.argv[1]); c=next(x for x in d["lifecycle"]["candidates"] if x["taskId"]=="TASK-1107")
assert c["blockedDependencies"] == ["TASK-1001"], c
assert c["candidateRunId"] == "RUN-REPAIR"
assert c["blockedReason"] == "gate-red"
assert c["owner"] and c["permittedNextAction"]
PY

# Real maintenance entrypoints: accepted -> failed exact-tree gate -> authorized
# unchanged regate -> integration, followed by a second candidate that requires
# an authorized branch/worktree repair and a fresh audit before integration.
repo="$tmp/real-repo"
orch="$repo/docs/orchestration"
real_state="$repo/.singular-state"
mkdir -p "$orch/tasks" "$orch/packets/imported/TASK-1201" \
  "$orch/packets/imported/TASK-1202" "$real_state"
cp -R "$ROOT/templates/prompts" "$orch/prompts"
git -C "$repo" init -q
git -C "$repo" checkout -qb target
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.local
cat >"$repo/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"target","gateCommand":"bash recovery-gate.sh","bootstrap":{"required":false,"commands":[]}}
JSON
cat >"$repo/recovery-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${GATE_RUN_COUNTER:-}" ]] || printf 'gate\n' >>"$GATE_RUN_COUNTER"
failure=""
[[ "${FORCE_GATE_RED:-0}" != 1 ]] || failure="forced regate failure"
if [[ "${FORCE_GATE_INFRA:-0}" == 1 ]]; then
  echo "No space left on device" >&2
  exit 1
fi
if [[ -n "$failure" ]]; then
  printf '{"schema":"singular.orchestration.gate-observation.v0","failures":[{"signature":"recovery:behavior","title":"%s"}]}\n' "$failure" >"$SINGULAR_GATE_REPORT_FILE"
  echo "AssertionError: $failure" >&2
  exit 1
fi
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$repo/recovery-gate.sh"
cat >"$orch/tasks/TASK-1201.md" <<'MD'
# TASK-1201: unchanged regate fixture
Status: accepted
Area: brain
Target branch: `target`
Worker branch: `agent/regate`
Test policy: `strict_test_first`
Gate command: `bash recovery-gate.sh`
Dispatch mode: canonical
Depends on: []
## Objective
Exercise unchanged recovery.
## Scope
Owned files:
- `app1.txt`
MD
cat >"$orch/tasks/TASK-1202.md" <<'MD'
# TASK-1202: repair fixture
Status: accepted
Area: brain
Target branch: `target`
Worker branch: `agent/repair-old`
Test policy: `strict_test_first`
Gate command: `bash recovery-gate.sh`
Dispatch mode: canonical
Depends on: []
## Objective
Exercise separate repair recovery.
## Scope
Owned files:
- `app2.txt`
MD
printf '%s\n' '.singular-state/' '.worktrees/' >"$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit -qm base

real_env=(env -i PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
  SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$orch" SINGULAR_TASKS_DIR="$orch/tasks" \
  SINGULAR_STATE_DIR="$real_state" SINGULAR_LEASES_DIR="$real_state/leases" \
  SINGULAR_RUNS_DIR="$real_state/runs" SINGULAR_WORKTREES_DIR="$repo/.worktrees" \
  SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$repo/singular.config.json" \
  SINGULAR_CONFIG_FILE=/dev/null SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
  SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_PUSH=0)

make_bound_verification() {
  local fixture_run="$1" fixture_task="$2" fixture_head="$3" fixture_worktree="$4"
  local fixture_tree run_path request_path task_snapshot policy_path
  fixture_tree="$(git -C "$fixture_worktree" rev-parse "$fixture_head^{tree}")"
  run_path="$real_state/runs/$fixture_run"
  request_path="$run_path/verification-request-1.json"
  task_snapshot="$run_path/verification-task-contract-1.md"
  policy_path="$run_path/verification-policy-1.json"
  mkdir -p "$run_path"
  cp "$orch/tasks/$fixture_task.md" "$task_snapshot"
  printf '%s\n' '{"campaign":"legacy","policy":"legacy"}' >"$policy_path"
  python3 "$ROOT/engine/gate-report.py" create-verification-request \
    --output "$request_path" --task-id "$fixture_task" --run-id "$fixture_run" \
    --attempt 1 --head-sha "$fixture_head" --tree-sha "$fixture_tree" \
    --campaign legacy --task-contract "$task_snapshot" \
    --policy-contract "$policy_path" --suite-id task-contract-gate >/dev/null
  (cd "$fixture_worktree" && "${real_env[@]}" SINGULAR_ROOT="$fixture_worktree" \
    "$ROOT/engine/gate-check.sh" "$fixture_run" \
    --task-id "$fixture_task" --verification-request "$request_path" \
    --task-contract "$task_snapshot" \
    --policy-contract "$policy_path" --attempt 1) >/dev/null
  mv "$run_path/gate-report.json" "$run_path/audit-verification.json"
}

git -C "$repo" checkout -qb agent/regate
printf 'fixed-one\n' >"$repo/app1.txt"
git -C "$repo" add app1.txt
git -C "$repo" commit -qm regate-candidate
regate_head="$(git -C "$repo" rev-parse HEAD)"
make_bound_verification RUN-REGATE-OLD TASK-1201 "$regate_head" "$repo"
git -C "$repo" checkout -q target
cat >"$orch/packets/imported/TASK-1201/RUN-REGATE-OLD.json" <<JSON
{"schema":"singular.orchestration.state-packet.v0","packetId":"RUN-REGATE-OLD","runId":"RUN-REGATE-OLD","taskId":"TASK-1201","area":"brain","role":"l2-developer","status":"accepted","baseRef":"target","branch":"agent/regate","headSha":"$regate_head","workspace":"$repo","ownedFiles":["app1.txt"],"changedFiles":["app1.txt"],"commands":[{"cmd":"bash recovery-gate.sh","exitCode":0}],"tests":[{"name":"fixture","phase":"regression","status":"passed"}],"evidence":[{"kind":"test","ref":"fixture"},{"kind":"audit-verification","ref":"runs/RUN-REGATE-OLD/audit-verification.json"}],"blockers":[],"nextAction":"integrate","createdAt":"2026-09-11T00:00:00Z"}
JSON
cat >"$orch/packets/imported/TASK-1201/RUN-REGATE-OLD.audit.json" <<JSON
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-1201","runId":"RUN-REGATE-OLD","branch":"agent/regate","verdict":"accepted","evidenceReviewed":["fixture","audit-verification.json","reviewed-head-sha:$regate_head"],"verificationResults":[{"status":"passed","command":"bash recovery-gate.sh","exitCode":0,"evidenceRefs":["audit-verification.json"],"rationale":"host-bound fixture gate"}],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"fresh fixture audit"}
JSON
git -C "$repo" add "$orch/packets/imported/TASK-1201"
git -C "$repo" commit -qm regate-packet
if "${real_env[@]}" GATE_RUN_COUNTER="$tmp/gate-runs" FORCE_GATE_INFRA=1 \
    bash "$ROOT/engine/integrate.sh" \
    --task TASK-1201 --run-id RUN-INFRA-RED >"$tmp/regate-red.out" 2>&1; then
  fail "forced real infrastructure gate unexpectedly passed"
fi
gate_runs_after_initial_infra="$(wc -l <"$tmp/gate-runs" | tr -d ' ')"
"${real_env[@]}" GATE_RUN_COUNTER="$tmp/gate-runs" FORCE_GATE_INFRA=1 \
  bash "$ROOT/engine/integrate.sh" --task TASK-1201 --run-id RUN-INFRA-RETRY \
  >"$tmp/infra-no-authority-retry.out" 2>&1 || true
[[ "$(wc -l <"$tmp/gate-runs" | tr -d ' ')" == "$gate_runs_after_initial_infra" ]] \
  || fail "unchanged no-authority infrastructure retry reran the gate"
regate_failure="$(python3 - "$real_state/leases/TASK-1201.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); assert d["acceptedCandidate"]["state"]=="integration-failed"
print(d["acceptedCandidate"]["failures"][-1]["failureId"])
PY
)"
regate_auth_out="$("${real_env[@]}" "$ROOT/engine/recover.sh" candidate TASK-1201 \
  --action regate --successor-run RUN-REGATE-FAIL --successor-branch agent/regate \
  --successor-worktree "$repo/.worktrees/regate" --failure-id "$regate_failure")"
regate_auth="$(printf '%s\n' "$regate_auth_out" | sed -n 's/^authorizationId=//p')"
[[ -n "$regate_auth" ]] || fail "real regate authorization was not issued"
if "${real_env[@]}" GATE_RUN_COUNTER="$tmp/gate-runs" FORCE_GATE_INFRA=1 \
    SINGULAR_RECOVERY_AUTHORIZATION_ID="$regate_auth" \
    bash "$ROOT/engine/integrate.sh" --task TASK-1201 --run-id RUN-REGATE-FAIL \
    >"$tmp/regate-authorized-red.out" 2>&1; then
  fail "authorized infrastructure-failing regate unexpectedly integrated"
fi
gate_runs_before_replay="$(wc -l <"$tmp/gate-runs" | tr -d ' ')"
"${real_env[@]}" GATE_RUN_COUNTER="$tmp/gate-runs" \
  SINGULAR_RECOVERY_AUTHORIZATION_ID="$regate_auth" \
  bash "$ROOT/engine/integrate.sh" --task TASK-1201 --run-id RUN-REGATE-FAIL \
  >"$tmp/regate-failed-replay.out" 2>&1 || true
[[ "$(wc -l <"$tmp/gate-runs" | tr -d ' ')" == "$gate_runs_before_replay" ]] \
  || fail "completed failed regate replay reran the gate"
python3 - "$real_state/leases/TASK-1201.json" "$regate_failure" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); a=d["recoveryAuthorization"]
assert a["state"] == "failed", a
assert a["executionFailureId"] != sys.argv[2], (a, sys.argv[2])
assert len(d["acceptedCandidate"]["failures"]) == 2, d
failure=d["acceptedCandidate"]["failures"][-1]
assert failure["domain"] == "infrastructure", failure
assert failure["recoveryAction"] == "regate", failure
PY
"${real_env[@]}" GATE_RUN_COUNTER="$tmp/gate-runs" FORCE_GATE_INFRA=1 \
  bash "$ROOT/engine/integrate.sh" --task TASK-1201 --run-id RUN-REGATE-NO-AUTH \
  >"$tmp/regate-failed-no-authority.out" 2>&1 || true
[[ "$(wc -l <"$tmp/gate-runs" | tr -d ' ')" == "$gate_runs_before_replay" ]] \
  || fail "completed infrastructure-failed regate reran without authority"
# Even a relevant target-head invalidation cannot bypass an exhausted domain.
git -C "$repo" commit --allow-empty -qm advance-target-for-invalidation
python3 - "$real_state/leases/TASK-1201.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["failureLimits"]["infrastructure"]=2
json.dump(d, open(p,"w"))
PY
"${real_env[@]}" GATE_RUN_COUNTER="$tmp/gate-runs" FORCE_GATE_INFRA=1 \
  bash "$ROOT/engine/integrate.sh" --task TASK-1201 --run-id RUN-INFRA-EXHAUSTED \
  >"$tmp/infra-exhausted.out" 2>&1 || true
[[ "$(wc -l <"$tmp/gate-runs" | tr -d ' ')" == "$gate_runs_before_replay" ]] \
  || fail "exhausted infrastructure domain reran after invalidation"
grep -q 'infrastructure recovery budget is exhausted' "$tmp/infra-exhausted.out" \
  || fail "exhausted infrastructure retry lacked its durable reason"
python3 - "$real_state/leases/TASK-1201.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["failureLimits"]["infrastructure"]=3
json.dump(d, open(p,"w"))
PY
regate_retry_failure="$(python3 - "$real_state/leases/TASK-1201.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["acceptedCandidate"]["failures"][-1]["failureId"])
PY
)"
regate_retry_out="$("${real_env[@]}" "$ROOT/engine/recover.sh" candidate TASK-1201 \
  --action regate --successor-run RUN-REGATE-GREEN --successor-branch agent/regate \
  --successor-worktree "$repo/.worktrees/regate" --failure-id "$regate_retry_failure")"
regate_retry_auth="$(printf '%s\n' "$regate_retry_out" | sed -n 's/^authorizationId=//p')"
[[ -n "$regate_retry_auth" ]] || fail "fresh regate authority was not issued"
# Kill the actual integration entrypoint immediately after its durable claim,
# then restart in a fresh process from that checkpoint.
if "${real_env[@]}" GATE_RUN_COUNTER="$tmp/gate-runs" \
    SINGULAR_RECOVERY_AUTHORIZATION_ID="$regate_retry_auth" \
    SINGULAR_TEST_INTERRUPT_AFTER_RECOVERY_CLAIM=1 \
    bash "$ROOT/engine/integrate.sh" --task TASK-1201 --run-id RUN-REGATE-GREEN \
    >"$tmp/regate-crash.out" 2>&1; then
  fail "deterministic recovery-entrypoint interrupt did not stop integration"
fi
[[ "$(wc -l <"$tmp/gate-runs" | tr -d ' ')" == "$gate_runs_before_replay" ]] \
  || fail "interrupted recovery ran the gate before its durable checkpoint"
"${real_env[@]}" GATE_RUN_COUNTER="$tmp/gate-runs" \
  SINGULAR_RECOVERY_AUTHORIZATION_ID="$regate_retry_auth" \
  bash "$ROOT/engine/integrate.sh" --task TASK-1201 --run-id RUN-REGATE-GREEN \
  >"$tmp/regate-green.out" 2>&1 \
  || fail "crash-resumed unchanged regate did not integrate: $(cat "$tmp/regate-green.out")"
regate_merge="$(git -C "$repo" rev-parse HEAD)"
"${real_env[@]}" bash "$ROOT/engine/integrate.sh" --task TASK-1201 \
  --run-id RUN-REGATE-REPLAY >"$tmp/regate-replay.out" 2>&1 \
  || fail "integrated regate replay was not recoverable"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$regate_merge" ]] \
  || fail "unchanged regate replay published a duplicate merge"
python3 - "$real_state/leases/TASK-1201.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); assert d["status"]=="integrated", d
assert d["recoveryAuthorization"]["state"]=="published", d
PY

git -C "$repo" checkout -qb agent/repair-old
printf 'broken-two\n' >"$repo/app2.txt"
git -C "$repo" add app2.txt
git -C "$repo" commit -qm repair-candidate-old
repair_old_head="$(git -C "$repo" rev-parse HEAD)"
make_bound_verification RUN-REPAIR-OLD TASK-1202 "$repair_old_head" "$repo"
git -C "$repo" checkout -q target
cat >"$orch/packets/imported/TASK-1202/RUN-REPAIR-OLD.json" <<JSON
{"schema":"singular.orchestration.state-packet.v0","packetId":"RUN-REPAIR-OLD","runId":"RUN-REPAIR-OLD","taskId":"TASK-1202","area":"brain","role":"l2-developer","status":"accepted","baseRef":"target","branch":"agent/repair-old","headSha":"$repair_old_head","workspace":"$repo","ownedFiles":["app2.txt"],"changedFiles":["app2.txt"],"commands":[{"cmd":"bash recovery-gate.sh","exitCode":0}],"tests":[{"name":"fixture","phase":"regression","status":"passed"}],"evidence":[{"kind":"test","ref":"fixture"},{"kind":"audit-verification","ref":"runs/RUN-REPAIR-OLD/audit-verification.json"}],"blockers":[],"nextAction":"integrate","createdAt":"2026-09-11T00:00:00Z"}
JSON
cat >"$orch/packets/imported/TASK-1202/RUN-REPAIR-OLD.audit.json" <<JSON
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-1202","runId":"RUN-REPAIR-OLD","branch":"agent/repair-old","verdict":"accepted","evidenceReviewed":["fixture","audit-verification.json","reviewed-head-sha:$repair_old_head"],"verificationResults":[{"status":"passed","command":"bash recovery-gate.sh","exitCode":0,"evidenceRefs":["audit-verification.json"],"rationale":"host-bound fixture gate"}],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"fresh fixture audit"}
JSON
git -C "$repo" add "$orch/packets/imported/TASK-1202"
git -C "$repo" commit -qm repair-packet-old
if "${real_env[@]}" FORCE_GATE_RED=1 bash "$ROOT/engine/integrate.sh" --task TASK-1202 \
    --run-id RUN-REPAIR-RED >"$tmp/repair-red.out" 2>&1; then
  fail "broken repair predecessor unexpectedly integrated"
fi
repair_failure="$(python3 - "$real_state/leases/TASK-1202.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); assert d["acceptedCandidate"]["state"]=="integration-failed"
print(d["acceptedCandidate"]["failures"][-1]["failureId"])
PY
)"
repair_predecessor="$repo/.worktrees/repair-predecessor"
git -C "$repo" worktree add -q "$repair_predecessor" agent/repair-old
printf 'dirty tracked predecessor bytes\n' >"$repair_predecessor/app2.txt"
printf 'untracked predecessor bytes\n' >"$repair_predecessor/untracked.txt"
mkdir -p "$repair_predecessor/.singular-evidence"
printf 'predecessor evidence\n' >"$repair_predecessor/.singular-evidence/red.log"
predecessor_status="$(git -C "$repair_predecessor" status --porcelain=v1 --untracked-files=all)"
predecessor_branch="$(git -C "$repair_predecessor" branch --show-current)"
python3 - "$real_state/leases/TASK-1202.json" "$repair_predecessor" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["worktree"]=sys.argv[2]; json.dump(d,open(p,"w"))
PY
repair_auth_out="$("${real_env[@]}" "$ROOT/engine/recover.sh" candidate TASK-1202 \
  --action repair --successor-run RUN-REPAIR-ZNEW --successor-branch agent/repair-new \
  --successor-worktree "$repo/.worktrees/repair-new" --failure-id "$repair_failure")"
[[ "$repair_auth_out" == *"distinct repair attempt"* ]] \
  || fail "real repair authorization was not issued"
# Run the authorized successor through the real driver. The stub performs only
# the bounded fixture edit and emits the normal worker/auditor contracts; the
# driver itself must claim the authority, create the distinct branch/worktree,
# execute the focused gate, and publish a fresh accepted audit.
repair_runner="$tmp/repair-runner.sh"
cat >"$repair_runner" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
level=""; worktree=""; run_id=""; out=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C|--worktree) worktree="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$level" == l2 ]]; then
  printf 'fixed-two\n' >"$worktree/app2.txt"
  printf '%s\n' "$run_id|$worktree|$(git -C "$worktree" branch --show-current)" \
    >"$REPAIR_LAUNCH_RECORD"
  cat >"$out" <<'JSON'
{"schema":"singular.orchestration.state-packet.v0","packetId":"fixture","runId":"fixture","taskId":"TASK-1202","area":"brain","role":"l2-developer","status":"needs-review","baseRef":"fixture","branch":"fixture","headSha":"0","workspace":"fixture","ownedFiles":["app2.txt"],"changedFiles":["app2.txt"],"commands":[],"tests":[{"name":"recovery-gate","phase":"green","status":"passed"}],"evidence":[],"blockers":[],"nextAction":"audit","createdAt":"2026-09-11T00:00:00Z"}
JSON
  exit 0
fi
status="$(sed -n 's/.*classification is `\([^`]*\)`.*/\1/p' "$prompt" | tail -1)"
[[ -n "$status" ]] || status=passed
AUDIT_OUT="$out" AUDIT_RUN="$run_id" AUDIT_STATUS="$status" AUDIT_WORKTREE="$worktree" \
python3 - <<'PY'
import json, os, subprocess
branch=subprocess.check_output(
    ["git", "-C", os.environ["AUDIT_WORKTREE"], "branch", "--show-current"], text=True
).strip()
record={
    "schema":"singular.orchestration.audit-verdict.v1",
    "taskId":"TASK-1202", "runId":os.environ["AUDIT_RUN"], "branch":branch,
    "verdict":"accepted",
    "evidenceReviewed":["evidence-manifest.json","audit-verification.json"],
    "verificationResults":[{
        "status":os.environ["AUDIT_STATUS"], "command":"bash recovery-gate.sh",
        "exitCode":0, "evidenceRefs":["audit-verification.json"],
        "rationale":"fresh exact successor verification",
    }],
    "commandsRun":[], "findings":[], "requiredFixes":[],
    "rationale":"fresh audit of the authorized repair successor",
}
with open(os.environ["AUDIT_OUT"], "w", encoding="utf-8") as handle:
    json.dump(record, handle); handle.write("\n")
PY
SH
chmod +x "$repair_runner"
# AF_UNIX broker creation can itself be denied in the outer worker sandbox.
# Keep this fixture about recovery dispatch by replacing only the copied
# delivery transport with a bounded pass-through; production l1-drive and all
# lifecycle/gate/audit code still execute from the copied engine entrypoint.
driver_engine="$tmp/driver-engine"
cp -R "$ROOT/engine" "$driver_engine"
cat >"$driver_engine/evidence_delivery.py" <<'PY'
#!/usr/bin/env python3
import subprocess, sys
try:
    marker = sys.argv.index("--")
except ValueError:
    raise SystemExit(3)
raise SystemExit(subprocess.call(sys.argv[marker + 1:]))
PY
chmod +x "$driver_engine/evidence_delivery.py"
"${real_env[@]}" SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE=0 \
  SINGULAR_RUNNER="$repair_runner" SINGULAR_AUDIT_VERIFY=0 \
  SINGULAR_WORKER_INFRA_MAX=0 SINGULAR_AUDIT_INFRA_MAX=0 \
  SINGULAR_AUDIT_VERIFY_INFRA_MAX=0 SINGULAR_EVIDENCE_INFRA_MAX=0 \
  REPAIR_LAUNCH_RECORD="$tmp/repair-launch.record" \
  bash "$driver_engine/l1-drive.sh" TASK-1202 >"$tmp/repair-drive.out" 2>&1 \
  || fail "authorized repair driver failed: $(tail -20 "$tmp/repair-drive.out"); auditor: $(tail -30 "$real_state/runs/RUN-REPAIR-ZNEW/auditor-codex.log" 2>/dev/null); validation: $(cat "$real_state/runs/RUN-REPAIR-ZNEW/audit-validate.err" 2>/dev/null)"
IFS='|' read -r launched_run launched_worktree launched_branch <"$tmp/repair-launch.record"
[[ "$launched_run" == RUN-REPAIR-ZNEW \
    && "$launched_worktree" == "$repo/.worktrees/repair-new" \
    && "$launched_branch" == agent/repair-new ]] \
  || fail "driver launched a mismatched recovery successor"
repair_new_head="$(git -C "$repo/.worktrees/repair-new" rev-parse HEAD)"
cp "$real_state/inbox/RUN-REPAIR-ZNEW.json" \
  "$orch/packets/imported/TASK-1202/RUN-REPAIR-ZNEW.json"
cp "$real_state/runs/RUN-REPAIR-ZNEW/audit.json" \
  "$orch/packets/imported/TASK-1202/RUN-REPAIR-ZNEW.audit.json"
repair_verification="$real_state/runs/RUN-REPAIR-ZNEW/audit-verification.json"
cp "$repair_verification" "$tmp/repair-verification.pristine.json"
python3 - "$repair_verification" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["rawExitCode"]=1
json.dump(d, open(p,"w"))
PY
repair_new_tree="$(git -C "$repo" rev-parse "$repair_new_head^{tree}")"
if SINGULAR_RUNS_DIR="$real_state/runs" python3 "$ROOT/engine/task_lifecycle.py" \
    retain-candidate --lease "$real_state/leases/TASK-1202.json" \
    --packet "$orch/packets/imported/TASK-1202/RUN-REPAIR-ZNEW.json" \
    --audit "$orch/packets/imported/TASK-1202/RUN-REPAIR-ZNEW.audit.json" \
    --task-file "$orch/tasks/TASK-1202.md" --task TASK-1202 \
    --run RUN-REPAIR-ZNEW --branch agent/repair-new \
    --head "$repair_new_head" --tree "$repair_new_tree" --campaign legacy \
    --acceptance-mode accepted >/dev/null 2>&1; then
  fail "retain-candidate accepted a rejected production verification binding"
fi
repair_target_before_rejection="$(git -C "$repo" rev-parse target)"
"${real_env[@]}" bash "$ROOT/engine/integrate.sh" --task TASK-1202 \
  --run-id RUN-REPAIR-BINDING-REJECT >"$tmp/repair-binding-reject.out" 2>&1 || true
grep -Eq 'no accepted auditor verdict|accepted candidate lifecycle binding failed closed' \
  "$tmp/repair-binding-reject.out" \
  || fail "tampered v1 verification binding reached integration eligibility"
[[ "$(git -C "$repo" rev-parse target)" == "$repair_target_before_rejection" ]] \
  || fail "rejected verification binding changed the target"
mv "$tmp/repair-verification.pristine.json" "$repair_verification"
"${real_env[@]}" bash "$ROOT/engine/integrate.sh" --task TASK-1202 \
  --run-id RUN-REPAIR-INTEGRATE >"$tmp/repair-green.out" 2>&1 \
  || fail "authorized repair did not integrate: $(cat "$tmp/repair-green.out")"
grep -q '^INTEGRATED TASK-1202:' "$tmp/repair-green.out" \
  || fail "authorized repair was skipped: $(cat "$tmp/repair-green.out")"
[[ "$(git -C "$repair_predecessor" branch --show-current)" == "$predecessor_branch" \
    && "$(git -C "$repair_predecessor" status --porcelain=v1 --untracked-files=all)" == "$predecessor_status" \
    && "$(cat "$repair_predecessor/app2.txt")" == "dirty tracked predecessor bytes" \
    && "$(cat "$repair_predecessor/untracked.txt")" == "untracked predecessor bytes" \
    && "$(cat "$repair_predecessor/.singular-evidence/red.log")" == "predecessor evidence" ]] \
  || fail "real repair flow changed predecessor work or evidence"
python3 - "$real_state/leases/TASK-1202.json" "$repair_old_head" "$repair_new_head" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); c=d["acceptedCandidate"]
assert d["status"]=="integrated" and c["headSha"]==sys.argv[3]
assert d["candidateHistory"][0]["headSha"]==sys.argv[2]
assert d["recoveryAuthorization"]["freshAuditRequired"] is True
assert d["recoveryAuthorization"]["successorAuditSha256"]
assert d["recoveryAuthorization"]["state"]=="published", d
PY

echo "PASS: test-candidate-recovery"
