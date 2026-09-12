#!/usr/bin/env bash
set -euo pipefail

# Frozen actual-L1 regression for a committed candidate whose first worker is a
# no-op but whose first fresh, host-bound audit returns actionable findings.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-first-audit-correction.sh requires bash >= 4" >&2
  exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN=/opt/homebrew/bin/bash
PYTHON_BIN=/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12
[[ -x "$BASH_BIN" ]] || { echo "missing pinned Bash: $BASH_BIN" >&2; exit 1; }
[[ -x "$PYTHON_BIN" ]] || { echo "missing pinned Python: $PYTHON_BIN" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/singular-first-audit-correction.XXXXXX")"
cleanup() {
  if [[ "${FIRST_AUDIT_KEEP_TMP:-0}" == "1" ]]; then
    echo "fixture retained: $scratch" >&2
  else
    rm -rf "$scratch"
  fi
}
trap cleanup EXIT
repo="$scratch/repo"
state="$repo/.singular-state"
tasks="$repo/docs/orchestration/tasks"
prompts="$repo/docs/orchestration/prompts"
counters="$scratch/counters"
socketless_fixture="$scratch/socketless-fixture"
worker_branch=agent/widget/TASK-0001-generic
mkdir -p "$tasks" "$prompts" "$state" "$counters" "$socketless_fixture"

# Explicit fixture adapter only: this managed test sandbox denies AF_UNIX
# listener creation. The provider fixture consumes the complete required
# evidence already embedded by evidence_delivery.py and never uses paged reads,
# so replace only the unused socket server lifecycle. This is not native
# evidence-delivery proof; host verification must rerun without this adapter.
cat >"$socketless_fixture/sitecustomize.py" <<'PY'
import socketserver
import threading


class SocketlessFixtureServer:
    def __init__(self, _address, _handler):
        self._closed = threading.Event()

    def __enter__(self):
        return self

    def __exit__(self, _kind, _value, _traceback):
        self.shutdown()

    def serve_forever(self):
        self._closed.wait()

    def shutdown(self):
        self._closed.set()


socketserver.ThreadingUnixStreamServer = SocketlessFixtureServer
PY

git -C "$repo" init -q
git -C "$repo" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$prompts/"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$prompts/"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' >"$prompts/decider.md"
printf '%s\n' '{"schemaVersion":"v2","targetBranch":"target","gateCommand":"bash strict-gate.sh"}' \
  >"$repo/singular.config.json"
cat >"$repo/strict-gate.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$repo/strict-gate.sh"
cat >"$tasks/TASK-0001.md" <<'TASK'
# TASK-0001: Correct a committed candidate after fresh audit feedback

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
Dispatch mode: canonical
Depends on: []

## Objective

Correct the pre-existing widget candidate from fresh audit findings.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The fresh audit finding is fixed in one bounded correcting pass.
TASK
git -C "$repo" add .
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm base

runner="$scratch/fixture-runner.sh"
cat >"$runner" <<'RUNNER'
#!/opt/homebrew/bin/bash
set -euo pipefail

level=""; role=""; worktree=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    -C|--worktree) worktree="$2"; shift 2 ;;
    --output-last-message) output="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    --result-file|--run-id|--capability-profile|--session-meta|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done

bump() {
  local path="${FIXTURE_COUNTERS:?}/$1" count=0
  [[ -f "$path" ]] && count="$(<"$path")"
  printf '%s\n' "$((count + 1))" >"$path"
  printf '%s\n' "$((count + 1))"
}

if [[ "$level" == "l2" ]]; then
  call="$(bump worker-calls)"
  git -C "$worktree" rev-parse HEAD >"$FIXTURE_COUNTERS/worker-head-$call"
  cp "$prompt" "$FIXTURE_COUNTERS/worker-prompt-$call.md"
  [[ "${SINGULAR_TEST_TASK_ID:-}" == "TASK-0001" ]] || exit 94
  [[ "${SINGULAR_TEST_TASK_CONTRACT:-}" == \
    "${SINGULAR_TEST_TASKS_DIR:-}/TASK-0001.md" ]] || exit 95
  if [[ "$call" -gt 1 ]]; then
    grep -q 'FINDING_ALPHA: replace the seeded implementation' "$prompt" || exit 96
    if [[ "${FIXTURE_MODE:?}" == "accept" ]]; then
      printf 'package widget\n// corrected after actionable audit feedback\n' \
        >"$worktree/internal/widget/parser.go"
    fi
  fi
  FIXTURE_OUTPUT="$output" FIXTURE_WORKTREE="$worktree" "$FIXTURE_PYTHON" - <<'PY'
import json
import os

record = {
    "schema": "singular.orchestration.state-packet.v0",
    "packetId": "fixture-packet",
    "runId": "fixture-run",
    "taskId": "TASK-0001",
    "area": "widget",
    "role": "l2-developer",
    "status": "needs-review",
    "baseRef": "target",
    "branch": "agent/widget/TASK-0001-generic",
    "headSha": "uncommitted",
    "workspace": os.environ["FIXTURE_WORKTREE"],
    "ownedFiles": ["internal/widget/parser.go"],
    "changedFiles": [],
    "commands": [],
    "tests": [],
    "evidence": [],
    "blockers": [],
    "nextAction": "await auditor verdict",
    "createdAt": "2026-09-12T00:00:00Z",
}
with open(os.environ["FIXTURE_OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(record, handle)
    handle.write("\n")
PY
  exit 0
fi

audit_count_path="${AUDIT_COUNT_FILE:?}"
audit_count=0
[[ -f "$audit_count_path" ]] && audit_count="$(<"$audit_count_path")"
call=$((audit_count + 1))
printf '%s\n' "$call" >"$audit_count_path"
status=""
if [[ -f "$prompt" ]]; then
  status="$(sed -n 's/.*classification is `\([^`]*\)`.*/\1/p' "$prompt" | tail -1)"
fi
[[ -n "$status" ]] || status=passed
verdict=needs-fix
finding='FINDING_ALPHA: replace the seeded implementation'
mode="$(<"${audit_count_path%/*}/mode")"
if [[ "$mode" == "accept" && "$call" -gt 1 ]]; then
  verdict=accepted
  finding=""
fi
FIXTURE_OUTPUT="$output" FIXTURE_STATUS="$status" FIXTURE_VERDICT="$verdict" \
  FIXTURE_FINDING="$finding" /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 - <<'PY'
import json
import os

finding = os.environ["FIXTURE_FINDING"]
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": "fixture-run",
    "branch": "agent/widget/TASK-0001-generic",
    "verdict": os.environ["FIXTURE_VERDICT"],
    "evidenceReviewed": ["evidence-manifest.json", "audit-verification.json"],
    "verificationResults": [{
        "status": os.environ["FIXTURE_STATUS"],
        "command": "bash strict-gate.sh",
        "exitCode": 0,
        "evidenceRefs": ["audit-verification.json"],
        "rationale": "matches the host-derived classification",
    }],
    "commandsRun": [],
    "findings": [finding] if finding else [],
    "requiredFixes": [finding] if finding else [],
    "rationale": "fresh actionable audit" if finding else "fresh accepted audit",
}
with open(os.environ["FIXTURE_OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(record, handle)
    handle.write("\n")
PY
exit 0
RUNNER
chmod +x "$runner"

prepare_case() {
  local kind="${1:-seeded}"
  rm -rf "$state/runs" "$state/leases" "$state/inbox" "$repo/.worktrees" "$counters"
  mkdir -p "$state" "$counters"
  : >"$state/events.ndjson"
  git -C "$repo" worktree prune
  git -C "$repo" branch -D "$worker_branch" >/dev/null 2>&1 || true
  "$PYTHON_BIN" - "$tasks/TASK-0001.md" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^Status: \S+", "Status: ready", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
  seed="$scratch/seed"
  rm -rf "$seed"
  if [[ "$kind" == "empty" ]]; then
    git -C "$repo" branch "$worker_branch" target
    seed_head="$(git -C "$repo" rev-parse "$worker_branch")"
    return 0
  fi
  git -C "$repo" worktree add -q -b "$worker_branch" "$seed" target
  mkdir -p "$seed/internal/widget"
  printf 'package widget\n// seeded committed candidate\n' >"$seed/internal/widget/parser.go"
  git -C "$seed" add internal/widget/parser.go
  git -C "$seed" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm 'seed committed candidate'
  seed_head="$(git -C "$seed" rev-parse HEAD)"
  git -C "$repo" worktree remove "$seed"
}

run_drive() {
  env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$socketless_fixture" FIXTURE_PYTHON="$PYTHON_BIN" \
    FIXTURE_COUNTERS="$counters" SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$state" \
    AUDIT_COUNT_FILE="$counters/auditor-calls" \
    SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_TASKS_DIR="$tasks" \
    SINGULAR_LEASES_DIR="$state/leases" SINGULAR_INBOX_DIR="$state/inbox" \
    SINGULAR_RUNS_DIR="$state/runs" SINGULAR_WORKTREES_DIR="$repo/.worktrees" \
    SINGULAR_EVENTS_FILE="$state/events.ndjson" SINGULAR_TARGET_BRANCH=target \
    SINGULAR_RUNNER="$runner" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_DECIDER_FAST=1 "$@" "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001
}

single_run_assertions() {
  local expected_retry="$1" expected_workers="$2" expected_auditors="$3"
  assert_eq "$(<"$counters/worker-calls")" "$expected_workers" "worker invocation count"
  assert_eq "$(<"$counters/auditor-calls")" "$expected_auditors" "auditor invocation count"
  lease="$state/leases/TASK-0001.json"
  "$PYTHON_BIN" - "$lease" "$expected_retry" <<'PY'
import json
import sys

lease = json.load(open(sys.argv[1], encoding="utf-8"))
assert lease["retryCount"] == int(sys.argv[2]), lease
assert lease["maxRetries"] in {0, 1}, lease
PY
  events="$(<"$state/events.ndjson")"
  dispatches="$(grep -c '"type":"l1.dispatch_started"' "$state/events.ndjson" || true)"
  assert_eq "$dispatches" 1 "single L1 dispatch"
}

# A committed candidate gets a fresh actionable audit after the first no-op
# worker. One durable repair is charged before a correcting worker sees the
# finding, changes the candidate, and receives a fresh accepted audit.
prepare_case
printf '%s\n' accept >"$counters/mode"
if ! output="$(run_drive env FIXTURE_MODE=accept SINGULAR_MAX_RETRIES=1 2>&1)"; then
  fail "actionable first audit did not reach one correcting pass: $output"
fi
single_run_assertions 1 2 2
events="$(<"$state/events.ndjson")"
assert_contains "$events" '"type":"l1.no_changes_reconciled"' "preseeded no-op reconciled"
assert_contains "$events" '"type":"l1.actionable_audit_correction_eligible"' \
  "fresh normalized audit feedback crossed the unchanged guard"
assert_contains "$events" '"type":"l1.product_repair_budget_consumed"' "repair charged"
assert_contains "$events" '"type":"l1.task_accepted"' "corrected candidate accepted"
assert_eq "$(<"$counters/worker-head-1")" "$seed_head" "first worker saw preseeded commit"
final_head="$(git -C "$repo/.worktrees/TASK-0001" rev-parse HEAD)"
[[ "$final_head" != "$seed_head" ]] || fail "correcting worker did not create a fresh candidate"
grep -q 'corrected after actionable audit feedback' \
  "$repo/.worktrees/TASK-0001/internal/widget/parser.go" \
  || fail "corrected candidate bytes missing"

# If the correcting worker is also a no-op and the fresh audit repeats the
# normalized finding on the exact candidate, park after the paid correction;
# do not dispatch a third worker or reset the durable retry.
prepare_case
printf '%s\n' repeat >"$counters/mode"
rc=0
output="$(run_drive env FIXTURE_MODE=repeat SINGULAR_MAX_RETRIES=1 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "repeated unchanged findings unexpectedly accepted"
single_run_assertions 1 2 2
events="$(<"$state/events.ndjson")"
assert_contains "$events" '"type":"l1.identical_findings_parked"' \
  "exact candidate and repeated normalized findings parked"
assert_eq "$(git -C "$repo/.worktrees/TASK-0001" rev-parse HEAD)" "$seed_head" \
  "no-op correction kept exact candidate"

# A zero-repair policy still permits the initial fresh audit but cannot invoke
# a corrective worker or mint/reset durable budget.
prepare_case
printf '%s\n' accept >"$counters/mode"
rc=0
output="$(run_drive env FIXTURE_MODE=accept SINGULAR_MAX_RETRIES=0 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "max-zero actionable audit unexpectedly accepted"
single_run_assertions 0 1 1
events="$(<"$state/events.ndjson")"
assert_contains "$events" '"type":"l1.product_repair_budget_exhausted"' \
  "max-zero audit correction terminated durably"
[[ "$events" != *'"type":"l1.product_repair_budget_consumed"'* ]] \
  || fail "max-zero case consumed a nonexistent repair"

# A genuinely empty initial worker on the target candidate still stops at the
# original no-changes/unchanged-candidate guard, before audit or repair spend.
prepare_case empty
printf '%s\n' repeat >"$counters/mode"
rc=0
output="$(run_drive env FIXTURE_MODE=repeat SINGULAR_MAX_RETRIES=1 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "empty fresh worker unexpectedly accepted"
assert_eq "$(<"$counters/worker-calls")" 1 "empty fresh worker invocation count"
[[ ! -e "$counters/auditor-calls" ]] || fail "empty fresh worker reached the auditor"
lease="$state/leases/TASK-0001.json"
"$PYTHON_BIN" - "$lease" <<'PY'
import json
import sys

lease = json.load(open(sys.argv[1], encoding="utf-8"))
assert lease["retryCount"] == 0, lease
assert lease["maxRetries"] == 1, lease
PY
events="$(<"$state/events.ndjson")"
assert_contains "$events" '"type":"l1.unchanged_candidate_parked"' \
  "real no-changes guard remained active"
assert_contains "$events" '"failureClass":"no-changes"' \
  "real no-changes failure remained classified"
assert_eq "$(grep -c '"type":"l1.dispatch_started"' "$state/events.ndjson" || true)" 1 \
  "empty fresh case single dispatch"

echo "PASS: test-first-audit-correction"
