#!/usr/bin/env bash
set -euo pipefail

# E7 (0.5.0): a retry whose content was already committed by a PRIOR attempt
# (empty staged diff, owned files differ from base, gate green) proceeds as a
# valid empty-diff attempt instead of failing `no-changes`. 0.4.0 parked fully
# green work here (field audit: TASK-0052/0053).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-no-changes-prior-commit.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

workroot="$(mktemp -d)"
trap 'rm -rf "$workroot"' EXIT
root="$workroot/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/prompts" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' >"$root/docs/orchestration/prompts/decider.md"
cat >"$root/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"target","gateCommand":"bash strict-gate.sh"}
JSON
cat >"$root/strict-gate.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$root/strict-gate.sh"

cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Empty-diff retry fixture

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
Gate command: `bash strict-gate.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the widget parser.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Parser handles empty input.
EOF
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -qm init

# Mock runner: L2 writes FIXED content every attempt (attempt 2 therefore has
# an empty staged diff on top of attempt 1's commit). Auditor returns needs-fix
# on the first call, accepted afterwards. WRITE_MODE=never makes L2 write
# nothing at all (regression case).
mock="$workroot/mock-runner.sh"
cat >"$mock" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
level=""; worktree=""; out=""; prompt=""
args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --level) level="${args[$((i+1))]}"; i=$((i+2)) ;;
    -C|--worktree) worktree="${args[$((i+1))]}"; i=$((i+2)) ;;
    --prompt-file) prompt="${args[$((i+1))]}"; i=$((i+2)) ;;
    --output-last-message) out="${args[$((i+1))]}"; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  if [[ "${WRITE_MODE:-fixed}" == "fixed" ]]; then
    mkdir -p "$worktree/internal/widget"
    printf 'package widget\n// stable content\n' >"$worktree/internal/widget/parser.go"
  fi
  [[ -n "$out" ]] && cat >"$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  exit 0
fi
ac=0; [[ -f "${AUDIT_COUNT_FILE:-/dev/null}" ]] && ac="$(cat "$AUDIT_COUNT_FILE" 2>/dev/null || echo 0)"
ac=$((ac+1)); [[ -n "${AUDIT_COUNT_FILE:-}" ]] && echo "$ac" >"$AUDIT_COUNT_FILE"
if [[ "$ac" -eq 1 && -n "${AUDIT_HOLD_FILE:-}" ]]; then
  printf '%s\n' "$$" >"$AUDIT_HOLD_FILE"
  while [[ ! -f "${AUDIT_RELEASE_FILE:-}" ]]; do sleep 0.05; done
fi
if [[ "$ac" -eq 1 ]]; then
  audit_verdict="needs-fix"
  audit_findings="tighten tests"
else
  audit_verdict="accepted"
  audit_findings=""
fi
audit_status="${AUDIT_STATUS_OVERRIDE:-}"
if [[ -z "$audit_status" && -f "$prompt" ]]; then
  audit_status="$(sed -n 's/.*classification is `\([^`]*\)`.*/\1/p' "$prompt" | tail -1)"
fi
[[ -n "$audit_status" ]] || audit_status="passed"
if [[ -n "$out" ]]; then
  AUDIT_OUT="$out" AUDIT_STATUS="$audit_status" AUDIT_VERDICT="$audit_verdict" \
    AUDIT_FINDINGS="$audit_findings" python3 - <<'PY'
import json
import os

finding = os.environ["AUDIT_FINDINGS"]
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": "r",
    "branch": "agent/widget/TASK-0001-generic",
    "verdict": os.environ["AUDIT_VERDICT"],
    "evidenceReviewed": ["evidence-manifest.json", "audit-verification.json"],
    "verificationResults": [{
        "status": os.environ["AUDIT_STATUS"],
        "command": "bash strict-gate.sh",
        "exitCode": 0,
        "evidenceRefs": ["audit-verification.json"],
        "rationale": "matches the host-derived classification",
    }],
    "commandsRun": [],
    "findings": [finding] if finding else [],
    "requiredFixes": [finding] if finding else [],
    "rationale": "tests need tightening" if finding else "accepted",
}
with open(os.environ["AUDIT_OUT"], "w", encoding="utf-8") as handle:
    json.dump(record, handle)
    handle.write("\n")
PY
fi
exit 0
MOCK
chmod +x "$mock"

run_drive() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_INBOX_DIR="$root/.singular-state/inbox" \
    SINGULAR_RUNS_DIR="$root/.singular-state/runs" SINGULAR_WORKTREES_DIR="$root/.worktrees" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_DECIDER_FAST=1 AUDIT_COUNT_FILE="$workroot/audit-count" "$@" \
    bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1
}

# 1. needs-fix then retry-with-identical-content: reconciled, accepted.
drive_output="$workroot/drive-output.log"
run_drive env WRITE_MODE=fixed \
  AUDIT_HOLD_FILE="$workroot/auditor.pid" \
  AUDIT_RELEASE_FILE="$workroot/auditor.release" >"$drive_output" 2>&1 &
drive_pid=$!
for _ in $(seq 1 400); do
  [[ -s "$workroot/auditor.pid" ]] && break
  sleep 0.05
done
[[ -s "$workroot/auditor.pid" ]] || {
  touch "$workroot/auditor.release"
  wait "$drive_pid" || true
  fail "auditor did not enter the observable active phase: $(cat "$drive_output")"
}
active_status=""
auditor_pid="$(cat "$workroot/auditor.pid")"
# Evidence delivery is a host-owned process boundary. The active record names
# that broker, which directly owns this fixture auditor, rather than its child.
auditor_owner_pid="$(ps -o ppid= -p "$auditor_pid" | tr -d '[:space:]')"
[[ "$auditor_owner_pid" =~ ^[1-9][0-9]*$ ]] || fail "auditor has no live owner"
for _ in $(seq 1 400); do
  active_status="$(find "$root/.singular-state/runs" -name run-status.json -type f | head -1)"
  if [[ -n "$active_status" ]] && python3 - "$active_status" "$auditor_owner_pid" <<'PY' >/dev/null 2>&1
import json
import sys
status = json.load(open(sys.argv[1]))
process = status.get("process", {})
raise SystemExit(
    0
    if status.get("phase") == "auditing"
    and process.get("type") == "auditor"
    and process.get("pid") == int(sys.argv[2])
    else 1
)
PY
  then
    break
  fi
  sleep 0.05
done
if [[ -z "$active_status" ]] || ! python3 - "$active_status" "$auditor_owner_pid" <<'PY' >/dev/null 2>&1
import json
import sys
status = json.load(open(sys.argv[1]))
process = status.get("process", {})
raise SystemExit(0 if process.get("type") == "auditor" and process.get("pid") == int(sys.argv[2]) else 1)
PY
then
  touch "$workroot/auditor.release"
  wait "$drive_pid" || true
  fail "active lifecycle record did not switch to the auditor owner PID"
fi
python3 - "$active_status" "$workroot/auditor.pid" "$auditor_owner_pid" <<'PY'
import json
import os
import subprocess
import sys

status = json.load(open(sys.argv[1]))
auditor_pid = int(open(sys.argv[2]).read().strip())
owner_pid = int(sys.argv[3])
assert status["phase"] == "auditing"
assert status["state"] == "active"
assert status["process"]["type"] == "auditor"
assert status["process"]["pid"] == owner_pid
assert int(subprocess.check_output(["ps", "-o", "ppid=", "-p", str(auditor_pid)], text=True)) == owner_pid
os.kill(owner_pid, 0)
os.kill(auditor_pid, 0)
PY
touch "$workroot/auditor.release"
if wait "$drive_pid"; then
  out="$(cat "$drive_output")"
else
  out="$(cat "$drive_output")"
  fail "drive should accept (out: $out)"
fi
events="$(cat "$root/.singular-state/events.ndjson")"
assert_contains "$events" '"type":"l1.no_changes_reconciled"' "empty-diff retry reconciled"
assert_contains "$events" '"type":"l1.task_accepted"' "task accepted after reconciled retry"
audit_path="$(ls "$root"/.singular-state/runs/*/audit.json | head -1)"
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schema"])' "$audit_path")" \
  == "singular.orchestration.audit-verdict.v1" ]] || fail "v2 repo did not write audit-verdict.v1"
run_status="${audit_path%/audit.json}/run-status.json"
python3 - "$run_status" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["schema"] == "singular.orchestration.run-status.v0"
assert data["phase"] == "terminal"
assert data["state"] == "completed"
assert data["outcome"] == "accepted"
assert data["safeCancel"] is True
assert data["process"]["type"] == "l1-driver"
assert data["process"]["pid"] > 0
assert data["process"]["pgid"] > 0
PY
# 0.6.0: the auditor's runner output must be durable in the run dir.
ls "$root"/.singular-state/runs/*/auditor-codex.log >/dev/null 2>&1 \
  || fail "auditor-codex.log not written by audit phase"

reset_fixture() {
  rm -rf "$root/.singular-state/runs" "$root/.singular-state/leases" \
    "$root/.singular-state/inbox" "$root/.worktrees"
  : >"$root/.singular-state/events.ndjson"
  rm -f "$workroot/audit-count"
  git -C "$root" worktree prune 2>/dev/null || true
  git -C "$root" branch -D agent/widget/TASK-0001-generic 2>/dev/null || true
  python3 - "$root/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write(re.sub(r"Status: \w+", "Status: ready", t, count=1))
PY
}

# 2. When disposable verification is disabled, the host verifies the original
# hash-bound gate evidence. The model fixture reads the host-derived prompt
# classification and must preserve not-rerun-evidence-verified through the v1
# verdict; the task may still be accepted on that explicitly weaker basis.
reset_fixture
if ! out="$(
  run_drive env WRITE_MODE=fixed SINGULAR_AUDIT_VERIFY=0
)"; then
  fail "evidence-only verification with a matching v1 classification should accept: $out"
fi
events="$(cat "$root/.singular-state/events.ndjson")"
assert_contains "$events" '"type":"audit.evidence_only_verified"' \
  "evidence-only host verification recorded"
assert_contains "$events" '"verification":"not-rerun-evidence-verified"' \
  "audit completion preserves evidence-only classification"
assert_contains "$events" '"type":"l1.task_accepted"' \
  "matching evidence-only audit accepted"
audit_path="$(ls "$root"/.singular-state/runs/*/audit.json | head -1)"
python3 - "$audit_path" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
statuses = [item["status"] for item in data["verificationResults"]]
assert statuses == ["not-rerun-evidence-verified"], statuses
PY
grep -q 'host verification classification is `not-rerun-evidence-verified`' \
  "${audit_path%/audit.json}"/auditor-bound-prompt-attempt-*.md \
  || fail "auditor prompt omitted the host-derived evidence-only classification"

# 3. A model that upgrades the same evidence-only host result to passed does
# not get to: the host rewrites verificationResults to its own classification
# (0.21.0), keeps the model's product verdict, preserves the original beside
# the record, and does not spend a second auditor pass on the echo.
reset_fixture
rc=0
out="$(
  run_drive env WRITE_MODE=fixed SINGULAR_AUDIT_VERIFY=0 \
    SINGULAR_AUDIT_INFRA_MAX=0 AUDIT_STATUS_OVERRIDE=passed
)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "host-normalized evidence-only verdict should accept: $out"
events="$(cat "$root/.singular-state/events.ndjson")"
assert_contains "$events" '"type":"l1.audit_verification_normalized"' \
  "host/model classification normalization recorded"
[[ "$events" != *'"type":"l1.audit_verification_mismatch"'* ]] \
  || fail "normalization must not also spend an auditor repair retry"
[[ "$events" != *'"type":"audit.infra_retry"'* ]] \
  || fail "normalization must not re-run the auditor"
assert_contains "$events" '"type":"l1.task_accepted"' \
  "normalized evidence-only audit accepted"
audit_path="$(ls "$root"/.singular-state/runs/*/audit.json | head -1)"
python3 - "$audit_path" <<'PY'
import json
import os
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
statuses = [item["status"] for item in data["verificationResults"]]
assert statuses == ["not-rerun-evidence-verified"], statuses
assert "host-authoritative" in data["verificationResults"][0]["rationale"]
original = json.load(open(path + ".pre-normalize.json", encoding="utf-8"))
assert [item["status"] for item in original["verificationResults"]] == ["passed"], original
PY

# 3b. With normalization disabled the 0.20 fail-closed behavior is intact:
# the mismatch is recorded, the auditor is not accepted, the task is not.
reset_fixture
rc=0
out="$(
  run_drive env WRITE_MODE=fixed SINGULAR_AUDIT_VERIFY=0 \
    SINGULAR_AUDIT_INFRA_MAX=0 AUDIT_STATUS_OVERRIDE=passed \
    SINGULAR_AUDIT_VERIFY_NORMALIZE=0
)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "mismatched evidence-only v1 classification must fail closed when normalization is off"
events="$(cat "$root/.singular-state/events.ndjson")"
assert_contains "$events" '"type":"l1.audit_verification_mismatch"' \
  "host/model classification mismatch recorded"
[[ "$events" != *'"type":"l1.task_accepted"'* ]] \
  || fail "mismatched evidence-only audit must not accept the task"

# 4. Regression: a worker that writes nothing on a FRESH task still fails
#    no-changes (truly no content vs base).
reset_fixture
rc=0
out="$(run_drive env WRITE_MODE=never SINGULAR_MAX_RETRIES=5)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "empty fresh attempt must not accept"
events="$(cat "$root/.singular-state/events.ndjson")"
assert_contains "$events" 'no-changes' "no-changes failure recorded"

# 5. ...and it now stops after the FIRST unchanged candidate, before spending
# either a second worker/gate pass or a decider round-trip. SINGULAR_MAX_RETRIES
# may lower a risk ceiling but cannot raise the ordinary one-repair ceiling.
assert_contains "$events" '"type":"l1.unchanged_candidate_parked"' \
  "unchanged-candidate guard fired"
assert_contains "$events" '"productRepairMax":1' \
  "ordinary task kept its hard one-repair ceiling"
# Counted from the archived attempt directories, which is what the loop
# actually produced.
attempts="$(find "$root/.singular-state/runs" -type f -path '*/attempts/*/failure.txt' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$attempts" -eq 1 ]] \
  || fail "unchanged-candidate guard did not stop immediately: $attempts attempts archived"
assert_contains "$out" "NOT ACCEPTED (escalate-parked)" \
  "unchanged-candidate parking is reported as a bounded terminal outcome"

echo "PASS: test-no-changes-prior-commit"
