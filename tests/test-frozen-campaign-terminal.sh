#!/usr/bin/env bash
set -euo pipefail

# A frozen campaign must carry one real scheduler reservation through
# reconcile -> dispatch-wrap -> l1-drive and publish a durable terminal
# disposition. Terminal failure/refusal is not fresh-dispatch authority.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-frozen-campaign-terminal.sh requires bash >= 4" >&2
  exit 1
fi

ENGINE_HOME="${SINGULAR_FROZEN_TEST_ENGINE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASH_BIN=/opt/homebrew/bin/bash
PYTHON_BIN=/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12
[[ -x "$BASH_BIN" ]] || { echo "missing pinned Bash: $BASH_BIN" >&2; exit 1; }
[[ -x "$PYTHON_BIN" ]] || { echo "missing pinned Python: $PYTHON_BIN" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing $1"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/singular-frozen-terminal.XXXXXX")"
cleanup() {
  if [[ "${FROZEN_KEEP_TMP:-0}" == "1" ]]; then
    echo "frozen terminal fixture retained: $scratch" >&2
  else
    rm -rf "$scratch"
  fi
}
trap cleanup EXIT

write_runner() {
  local runner="$1"
  cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--describe-contract" ]]; then
  printf '%s\n' '{"schema":"singular.runner-contract.v1","version":1,"provider":"codex","arguments":["--worktree","--prompt-file","--level","--run-id","--output-last-message","--role","--capability-profile","--result-file","--describe-contract"],"structuredResult":"singular.orchestration.runner-result.v0","structuredProviderError":"singular.orchestration.provider-error.v0"}'
  exit 0
fi

role="${SINGULAR_RUNNER_ROLE:-}"
capability="${SINGULAR_RUNNER_CAPABILITY_PROFILE:-fixture}"
result_file="${SINGULAR_RUNNER_RESULT_FILE:-}"
run_id=""; worktree=""; output=""; level=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) role="$2"; shift 2 ;;
    --capability-profile) capability="$2"; shift 2 ;;
    --result-file) result_file="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    -C|--worktree) worktree="$2"; shift 2 ;;
    --output-last-message) output="$2"; shift 2 ;;
    --level) level="$2"; shift 2 ;;
    --prompt-file|--session-meta|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$run_id" && -n "$output" ]] || exit 92

bump() {
  local name="$1" path="${FROZEN_FIXTURE_COUNTER_DIR:?}/$1-calls" value=0
  mkdir -p "${FROZEN_FIXTURE_COUNTER_DIR:?}"
  [[ -f "$path" ]] && value="$(cat "$path")"
  printf '%s\n' "$((value + 1))" >"$path"
}
write_result() {
  [[ -n "$result_file" ]] || return 0
  "$FROZEN_PYTHON" - "$result_file" "$run_id" "$role" "$capability" "$output" <<'PY'
import datetime, json, sys
path, run_id, role, capability, output = sys.argv[1:]
json.dump({
    "schema": "singular.orchestration.runner-result.v0",
    "contractVersion": 1,
    "provider": "codex",
    "runId": run_id,
    "role": role,
    "capabilityProfile": capability,
    "exitCode": 0,
    "outcome": "succeeded",
    "failureClass": "none",
    "providerErrorRef": None,
    "outputRef": output,
    "recordedAt": datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z"),
}, open(path, "w", encoding="utf-8"))
PY
}

case "$role" in
  supervisor)
    bump supervisor
    printf '%s\n' '{"ok":true}' >"$output"
    write_result
    ;;
  implementer)
    bump worker
    [[ "$level" == "l2" && -d "$worktree" ]] || exit 93
    [[ "${SINGULAR_TEST_TASK_ID:-}" == "TASK-0001" ]] || exit 94
    [[ "${SINGULAR_TEST_TASK_CONTRACT:-}" == \
      "${SINGULAR_TEST_TASKS_DIR:-}/TASK-0001.md" ]] || exit 95
    if [[ "${FROZEN_FIXTURE_MODE:-success}" == "infra" ]]; then
      : >"$output"
      exit 124
    fi
    mkdir -p "$worktree/internal/widget" "$worktree/.singular-evidence"
    printf 'package widget\n// frozen campaign candidate\n' >"$worktree/internal/widget/parser.go"
    printf 'intentional red fixture\n' >"$worktree/.singular-evidence/red.log"
    printf 'green fixture\n' >"$worktree/.singular-evidence/green.log"
    printf 'regression fixture\n' >"$worktree/.singular-evidence/regression.log"
    "$FROZEN_PYTHON" - "$output" "$run_id" "$worktree" <<'PY'
import datetime, json, sys
out, run_id, worktree = sys.argv[1:]
json.dump({
    "schema": "singular.orchestration.state-packet.v0",
    "packetId": run_id + "-packet",
    "runId": run_id,
    "taskId": "TASK-0001",
    "area": "widget",
    "role": "l2-developer",
    "status": "needs-review",
    "baseRef": "target",
    "branch": "agent/widget/TASK-0001-frozen",
    "headSha": "uncommitted",
    "workspace": worktree,
    "ownedFiles": ["internal/widget/parser.go"],
    "changedFiles": ["internal/widget/parser.go"],
    "commands": [{"cmd": "bash strict-gate.sh", "exitCode": 0,
                  "logRef": ".singular-evidence/regression.log"}],
    "tests": [
        {"name": "fixture red", "phase": "red", "status": "failed",
         "logRef": ".singular-evidence/red.log"},
        {"name": "fixture green", "phase": "green", "status": "passed",
         "logRef": ".singular-evidence/green.log"},
    ],
    "evidence": [
        {"kind": "red", "ref": ".singular-evidence/red.log"},
        {"kind": "green", "ref": ".singular-evidence/green.log"},
    ],
    "blockers": [],
    "nextAction": "await auditor verdict",
    "createdAt": datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z"),
}, open(out, "w", encoding="utf-8"))
PY
    if [[ "${FROZEN_FIXTURE_MODE:-success}" == "drift" ]]; then
      printf '\nmid-run policy drift\n' >>"${FROZEN_FIXTURE_SOURCE_ROOT:?}/docs/orchestration/prompts/auditor.md"
    fi
    write_result
    ;;
  auditor)
    bump auditor
    # evidence_delivery.py intentionally strips ambient engine paths before it
    # invokes the auditor. The host report is a required artifact beside the
    # requested output, so derive it from that explicit output capability.
    host_report="$(dirname "$output")/audit-verification.json"
    [[ -f "$host_report" ]] || exit 96
    "$FROZEN_PYTHON" - "$output" "$run_id" "$host_report" <<'PY'
import json, sys
out, run_id, report = sys.argv[1:]
status = json.load(open(report, encoding="utf-8"))["outcome"]
if status == "passed-with-acknowledged-baseline":
    status = "passed"
assert status in {"passed", "not-rerun-evidence-verified"}, status
json.dump({
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": run_id,
    "branch": "agent/widget/TASK-0001-frozen",
    "verdict": "accepted",
    "evidenceReviewed": ["evidence-manifest.json", "audit-verification.json"],
    "verificationResults": [{
        "status": status,
        "command": "bash strict-gate.sh",
        "exitCode": 0,
        "evidenceRefs": ["runs/%s/audit-verification.json" % run_id],
        "rationale": "matches the exact host verification classification",
    }],
    "commandsRun": ["bash strict-gate.sh"],
    "findings": [],
    "requiredFixes": [],
    "rationale": "accepted by deterministic exact-host-bound audit",
}, open(out, "w", encoding="utf-8"))
PY
    write_result
    ;;
  *) exit 97 ;;
esac
RUNNER
  chmod +x "$runner"
}

make_fixture() {
  local name="$1"
  FIXTURE_ROOT="$scratch/$name/repo"
  FIXTURE_COUNTERS="$scratch/$name/counters"
  FIXTURE_RUNNER="$scratch/$name/runner.sh"
  mkdir -p "$FIXTURE_ROOT/docs/orchestration/tasks" \
    "$FIXTURE_ROOT/docs/orchestration/prompts" "$FIXTURE_COUNTERS"
  git -C "$FIXTURE_ROOT" init -q
  git -C "$FIXTURE_ROOT" checkout -q -b target
  git -C "$FIXTURE_ROOT" config user.name frozen-terminal-test
  git -C "$FIXTURE_ROOT" config user.email frozen-terminal@example.invalid
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" \
    "$FIXTURE_ROOT/docs/orchestration/prompts/"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" \
    "$FIXTURE_ROOT/docs/orchestration/prompts/"
  printf '# Fixture planner policy\n' >"$FIXTURE_ROOT/docs/orchestration/prompts/l1-planner.md"
  cat >"$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" <<'TASK'
# TASK-0001: Frozen campaign terminal fixture

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-frozen`
Test policy: `strict_test_first`
Gate command: `bash strict-gate.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the frozen campaign widget.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The deterministic widget regression is green.
TASK
  cat >"$FIXTURE_ROOT/strict-gate.sh" <<'GATE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${SINGULAR_TEST_TASK_ID:-}" == "TASK-0001" ]]
[[ "${SINGULAR_TEST_TASK_CONTRACT:-}" == \
  "${SINGULAR_TEST_TASKS_DIR:-}/TASK-0001.md" ]]
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"${SINGULAR_GATE_REPORT_FILE:?}"
GATE
  chmod +x "$FIXTURE_ROOT/strict-gate.sh"
  write_runner "$FIXTURE_RUNNER"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n' >"$FIXTURE_ROOT/.gitignore"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/singular.config.json" "$FIXTURE_RUNNER" <<'PY'
import json, sys
json.dump({
    "schemaVersion": "v2",
    "targetBranch": "target",
    "gateCommand": "bash strict-gate.sh",
    "runner": sys.argv[2],
    "bootstrap": {"required": False, "commands": []},
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
  run_engine success "$BASH_BIN" -c \
    '. "$1"; singular_ensure_state_dirs; singular_ensure_repo_scaffold' \
    frozen-fixture "$ENGINE_HOME/engine/lib.sh"
  git -C "$FIXTURE_ROOT" add .
  git -C "$FIXTURE_ROOT" commit -qm 'frozen terminal fixture baseline'
}

run_engine() {
  local mode="$1"; shift
  (
    cd "$FIXTURE_ROOT"
    env \
      PATH="$(dirname "$PYTHON_BIN"):/opt/homebrew/bin:/usr/bin:/bin" \
      PYTHONDONTWRITEBYTECODE=1 \
      FROZEN_PYTHON="$PYTHON_BIN" \
      FROZEN_FIXTURE_MODE="$mode" \
      FROZEN_FIXTURE_COUNTER_DIR="$FIXTURE_COUNTERS" \
      FROZEN_FIXTURE_SOURCE_ROOT="$FIXTURE_ROOT" \
      SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      SINGULAR_BASH_BIN="$BASH_BIN" \
      SINGULAR_RUNNER="$FIXTURE_RUNNER" \
      SINGULAR_CONFIG_FILE=/dev/null \
      SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
      SINGULAR_GENERATE=0 \
      SINGULAR_AUTO_INTEGRATE=0 \
      SINGULAR_AUTO_PROMOTE_GATES=0 \
      SINGULAR_PUSH=0 \
      SINGULAR_MAX_CONCURRENT=1 \
      SINGULAR_MAX_DISPATCH=1 \
      SINGULAR_DISK_RESERVE_BYTES=0 \
      SINGULAR_ESTIMATED_WORKTREE_BYTES=1048576 \
      SINGULAR_MIN_DISK_GB=0 \
      SINGULAR_DETACHED_DISPATCH=0 \
      SINGULAR_REQUIRE_AUDIT=1 \
      SINGULAR_AUDIT_VERIFY=0 \
      SINGULAR_WORKER_INFRA_MAX=1 \
      SINGULAR_DECIDER_FAST=1 \
      "$@"
  )
}

start_campaign() {
  local mode="$1"
  run_engine "$mode" "$BASH_BIN" "$ENGINE_HOME/engine/campaign.sh" start \
    --id "frozen-$mode" >"$scratch/$mode-campaign.log" 2>&1 || {
      cat "$scratch/$mode-campaign.log" >&2
      fail "$mode campaign did not start"
    }
}

reconcile() {
  local mode="$1" label="$2" expected_rc="${3:-0}" rc=0
  run_engine "$mode" "$BASH_BIN" "$ENGINE_HOME/engine/reconcile.sh" --actuate \
    >"$scratch/$label.log" 2>&1 || rc=$?
  if [[ "$rc" -ne "$expected_rc" ]]; then
    cat "$scratch/$label.log" >&2
    fail "$label reconcile entrypoint returned $rc, expected $expected_rc"
  fi
}

calls() {
  local role="$1" path
  path="$FIXTURE_COUNTERS/$role-calls"
  [[ -f "$path" ]] && cat "$path" || printf '0\n'
}

set_task_ready() {
  "$PYTHON_BIN" - "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^Status:\s*`?[^`\n]+`?\s*$", "Status: ready", text,
              count=1, flags=re.MULTILINE | re.IGNORECASE)
open(path, "w", encoding="utf-8").write(text)
PY
}

assert_terminal_contract() {
  local kind="$1" failure_class="$2" action="$3"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$FIXTURE_ROOT/.singular-state/dispatch/TASK-0001.json" \
    "$kind" "$failure_class" "$action" <<'PY'
import json, sys
lease_path, dispatch_path, kind, failure_class, action = sys.argv[1:]
lease = json.load(open(lease_path, encoding="utf-8"))
dispatch = json.load(open(dispatch_path, encoding="utf-8"))
terminal = lease["terminalDisposition"]
attempt = lease["attemptLifecycle"]
dispatch_attempt = dispatch["attemptLifecycle"]
assert terminal["schema"] == "singular.orchestration.terminal-disposition.v0", terminal
assert terminal["kind"] == kind, terminal
assert terminal.get("failureClass", "") == failure_class, terminal
assert terminal["action"] == action, terminal
for record in (attempt, dispatch_attempt):
    assert record["schema"] == "singular.orchestration.attempt-lifecycle.v0", record
    assert record["taskId"] == "TASK-0001", record
    assert record["state"] == "terminal", record
    assert record["disposition"] == kind, record
    assert record.get("failureClass", "") == failure_class, record
    assert record["action"] == action, record
    assert record["runId"] == terminal["runId"], (record, terminal)
    assert record["reservationOwner"] == terminal["reservationOwner"], (record, terminal)
    assert record["reservationGeneration"] == terminal["reservationGeneration"], (record, terminal)
    assert record["campaignBinding"] == terminal["campaignBinding"], (record, terminal)
assert attempt == dispatch_attempt, (attempt, dispatch_attempt)
assert dispatch["state"] == "reaped", dispatch
PY
}

test_success() {
  make_fixture success
  start_campaign success
  reconcile success success-first
  assert_eq "$(calls worker)" "1" "success worker calls"
  assert_eq "$(calls auditor)" "1" "success auditor calls"
  local accepted_packet=""
  accepted_packet="$(find "$FIXTURE_ROOT/.singular-state/inbox" -maxdepth 1 \
    -name '*.json' -type f -print -quit 2>/dev/null || true)"
  if [[ -z "$accepted_packet" ]]; then
    cat "$scratch/success-first.log" >&2
    find "$FIXTURE_ROOT/.singular-state/runs" -name 'dispatch-TASK-0001.log' \
      -type f -exec cat {} \; >&2
    fail "success accepted packet was not published"
  fi
  assert_contains "$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")" \
    '"type":"l1.task_accepted"' "success acceptance event"
  reconcile success success-reap
  assert_terminal_contract completed "" accepted
  assert_eq "$(calls worker)" "1" "success did not redispatch"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$FIXTURE_ROOT/.singular-state/runs" <<'PY'
import json, pathlib, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
assert lease["status"] in {"accepted", "integrated"}, lease
statuses = []
for path in pathlib.Path(sys.argv[2]).glob("*/run-status.json"):
    data = json.load(open(path, encoding="utf-8"))
    if data.get("taskId") == "TASK-0001":
        statuses.append(data)
assert any(item.get("phase") == "terminal" and item.get("outcome") == "accepted"
           for item in statuses), statuses
PY
  echo "ok: frozen campaign publishes one accepted terminal attempt through real reconcile"
}

test_infra_exhaustion() {
  make_fixture infra
  start_campaign infra
  reconcile infra infra-first
  assert_eq "$(calls worker)" "2" "infra bounded worker calls"
  assert_eq "$(calls auditor)" "0" "infra auditor calls"
  assert_contains "$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")" \
    '"type":"worker.infra_exhausted"' "infra exhaustion event"
  set_task_ready
  reconcile infra infra-reconcile-2
  reconcile infra infra-reconcile-3
  assert_eq "$(calls worker)" "2" "infra restart did not redispatch"
  assert_eq "$(calls auditor)" "0" "infra restart did not audit"
  assert_terminal_contract blocked worker-infra escalate-infra
  assert_eq "$(find "$FIXTURE_ROOT/.singular-state/dispatch" -name 'TASK-0001.json' -type f | wc -l | tr -d '[:space:]')" \
    "1" "infra retained one dispatch generation"
  assert_contains "$(cat "$scratch/infra-reconcile-2.log" "$scratch/infra-reconcile-3.log")" \
    'reservation refused for TASK-0001' "infra restart durable reservation refusal"
  echo "ok: exhausted worker infrastructure is durable and cannot auto-redispatch"
}

test_policy_drift() {
  make_fixture drift
  cp "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md" "$scratch/drift-auditor.original"
  start_campaign drift
  # L1 publishes the campaign-mismatch disposition, and the same reconcile
  # process then refuses its later control-state commit under the changed
  # policy. Exit 2 is the expected outer entrypoint refusal.
  reconcile drift drift-first 2
  assert_eq "$(calls worker)" "1" "drift worker calls"
  assert_eq "$(calls auditor)" "1" "drift semantic audit completed before refusal"
  assert_contains "$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")" \
    'campaign' "drift refusal event"
  [[ ! -d "$FIXTURE_ROOT/.singular-state/inbox" ]] \
    || [[ -z "$(find "$FIXTURE_ROOT/.singular-state/inbox" -name '*.json' -type f -print -quit)" ]] \
    || fail "drift published an inbox packet"
  packet="$(find "$FIXTURE_ROOT/.singular-state/runs" -name packet.json -type f -print -quit)"
  assert_file "$packet" "drift worker packet preserved"
  assert_file "$FIXTURE_ROOT/.worktrees/TASK-0001/internal/widget/parser.go" \
    "drift partial candidate preserved"
  cp "$scratch/drift-auditor.original" "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md"
  set_task_ready
  reconcile drift drift-reconcile-2
  reconcile drift drift-reconcile-3
  assert_eq "$(calls worker)" "1" "drift restart did not duplicate worker"
  assert_eq "$(calls auditor)" "1" "drift restart did not manufacture audit"
  assert_terminal_contract campaign-mismatch campaign-mismatch re-audit-current-campaign
  assert_contains "$(cat "$scratch/drift-reconcile-2.log" "$scratch/drift-reconcile-3.log")" \
    'reservation refused for TASK-0001' "drift restart durable reservation refusal"
  echo "ok: mid-run policy drift preserves artifacts and refuses duplicate publication"
}

case "${FROZEN_TERMINAL_CASE:-all}" in
  success) test_success ;;
  infra) test_infra_exhaustion ;;
  drift) test_policy_drift ;;
  all) test_success; test_infra_exhaustion; test_policy_drift ;;
  *) fail "unknown FROZEN_TERMINAL_CASE=${FROZEN_TERMINAL_CASE}" ;;
esac

echo "PASS: frozen campaign terminal lifecycle"
