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
failure=""
[[ "${FORCE_GATE_RED:-0}" != 1 ]] || failure="forced regate failure"
[[ ! -e app1.txt || "$(cat app1.txt)" == "fixed-one" ]] || failure="app1 behavior failure"
[[ ! -e app2.txt || "$(cat app2.txt)" == "fixed-two" ]] || failure="app2 behavior failure"
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

git -C "$repo" checkout -qb agent/regate
printf 'fixed-one\n' >"$repo/app1.txt"
git -C "$repo" add app1.txt
git -C "$repo" commit -qm regate-candidate
regate_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q target
cat >"$orch/packets/imported/TASK-1201/RUN-REGATE-OLD.json" <<JSON
{"schema":"singular.orchestration.state-packet.v0","packetId":"RUN-REGATE-OLD","runId":"RUN-REGATE-OLD","taskId":"TASK-1201","area":"brain","role":"l2-developer","status":"accepted","baseRef":"target","branch":"agent/regate","headSha":"$regate_head","workspace":"$repo","ownedFiles":["app1.txt"],"changedFiles":["app1.txt"],"commands":[{"cmd":"bash recovery-gate.sh","exitCode":0}],"tests":[{"name":"fixture","phase":"regression","status":"passed"}],"evidence":[{"kind":"test","ref":"fixture"}],"blockers":[],"nextAction":"integrate","createdAt":"2026-09-11T00:00:00Z"}
JSON
cat >"$orch/packets/imported/TASK-1201/RUN-REGATE-OLD.audit.json" <<'JSON'
{"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-1201","runId":"RUN-REGATE-OLD","branch":"agent/regate","verdict":"accepted","evidenceReviewed":["fixture"],"commandsRun":["bash recovery-gate.sh"],"findings":[],"requiredFixes":[],"rationale":"fresh fixture audit"}
JSON
git -C "$repo" add "$orch/packets/imported/TASK-1201"
git -C "$repo" commit -qm regate-packet
if "${real_env[@]}" FORCE_GATE_RED=1 bash "$ROOT/engine/integrate.sh" \
    --task TASK-1201 --run-id RUN-REGATE-RED >"$tmp/regate-red.out" 2>&1; then
  fail "forced real integration gate unexpectedly passed"
fi
regate_failure="$(python3 - "$real_state/leases/TASK-1201.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); assert d["acceptedCandidate"]["state"]=="integration-failed"
print(d["acceptedCandidate"]["failures"][-1]["failureId"])
PY
)"
regate_auth_out="$("${real_env[@]}" "$ROOT/engine/recover.sh" candidate TASK-1201 \
  --action regate --successor-run RUN-REGATE-GREEN --successor-branch agent/regate \
  --successor-worktree "$repo/.worktrees/regate" --failure-id "$regate_failure")"
regate_auth="$(printf '%s\n' "$regate_auth_out" | sed -n 's/^authorizationId=//p')"
[[ -n "$regate_auth" ]] || fail "real regate authorization was not issued"
"${real_env[@]}" SINGULAR_RECOVERY_AUTHORIZATION_ID="$regate_auth" \
  bash "$ROOT/engine/integrate.sh" --task TASK-1201 --run-id RUN-REGATE-GREEN \
  >"$tmp/regate-green.out" 2>&1 \
  || fail "authorized unchanged regate did not integrate: $(cat "$tmp/regate-green.out")"
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
git -C "$repo" checkout -q target
cat >"$orch/packets/imported/TASK-1202/RUN-REPAIR-OLD.json" <<JSON
{"schema":"singular.orchestration.state-packet.v0","packetId":"RUN-REPAIR-OLD","runId":"RUN-REPAIR-OLD","taskId":"TASK-1202","area":"brain","role":"l2-developer","status":"accepted","baseRef":"target","branch":"agent/repair-old","headSha":"$repair_old_head","workspace":"$repo","ownedFiles":["app2.txt"],"changedFiles":["app2.txt"],"commands":[{"cmd":"bash recovery-gate.sh","exitCode":0}],"tests":[{"name":"fixture","phase":"regression","status":"passed"}],"evidence":[{"kind":"test","ref":"fixture"}],"blockers":[],"nextAction":"integrate","createdAt":"2026-09-11T00:00:00Z"}
JSON
cat >"$orch/packets/imported/TASK-1202/RUN-REPAIR-OLD.audit.json" <<'JSON'
{"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-1202","runId":"RUN-REPAIR-OLD","branch":"agent/repair-old","verdict":"accepted","evidenceReviewed":["fixture"],"commandsRun":["bash recovery-gate.sh"],"findings":[],"requiredFixes":[],"rationale":"fresh fixture audit"}
JSON
git -C "$repo" add "$orch/packets/imported/TASK-1202"
git -C "$repo" commit -qm repair-packet-old
if "${real_env[@]}" bash "$ROOT/engine/integrate.sh" --task TASK-1202 \
    --run-id RUN-REPAIR-RED >"$tmp/repair-red.out" 2>&1; then
  fail "broken repair predecessor unexpectedly integrated"
fi
repair_failure="$(python3 - "$real_state/leases/TASK-1202.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); assert d["acceptedCandidate"]["state"]=="integration-failed"
print(d["acceptedCandidate"]["failures"][-1]["failureId"])
PY
)"
python3 - "$real_state/leases/TASK-1202.json" "$tmp/repair-predecessor" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["worktree"]=sys.argv[2]; json.dump(d,open(p,"w"))
PY
mkdir -p "$tmp/repair-predecessor/.singular-evidence"
printf 'predecessor work\n' >"$tmp/repair-predecessor/untracked.txt"
printf 'predecessor evidence\n' >"$tmp/repair-predecessor/.singular-evidence/red.log"
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
"${real_env[@]}" bash "$ROOT/engine/integrate.sh" --task TASK-1202 \
  --run-id RUN-REPAIR-INTEGRATE >"$tmp/repair-green.out" 2>&1 \
  || fail "authorized repair did not integrate: $(cat "$tmp/repair-green.out")"
grep -q '^INTEGRATED TASK-1202:' "$tmp/repair-green.out" \
  || fail "authorized repair was skipped: $(cat "$tmp/repair-green.out")"
[[ "$(cat "$tmp/repair-predecessor/untracked.txt")" == "predecessor work" \
    && "$(cat "$tmp/repair-predecessor/.singular-evidence/red.log")" == "predecessor evidence" ]] \
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
