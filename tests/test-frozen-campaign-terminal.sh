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
unset SINGULAR_CONFIG_FILE SINGULAR_LOCAL_CONFIG_FILE SINGULAR_JSON_CONFIG_FILE \
  SINGULAR_JSON_CONFIG_SOURCE 2>/dev/null || true

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing $1"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
file_mode() {
  "$PYTHON_BIN" - "$1" <<'PY'
import os, stat, sys
print(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode))
PY
}

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
    if [[ "${FROZEN_CONTINUATION_EXPECTED:-0}" == "1" ]]; then
      [[ "$(cat "$worktree/internal/widget/parser.go")" == \
        'preserved tracked candidate bytes' ]] || exit 98
      [[ "$(cat "$worktree/internal/widget/note.txt")" == \
        'preserved untracked candidate bytes' ]] || exit 99
    fi
    if [[ "${FROZEN_FIXTURE_MODE:-success}" == "infra" ]]; then
      : >"$output"
      exit 124
    fi
    if [[ "${FROZEN_FIXTURE_MODE:-success}" == "crash-started" ]]; then
      ancestor="$PPID"
      while [[ "$ancestor" =~ ^[1-9][0-9]*$ && "$ancestor" -gt 1 ]]; do
        command="$(ps -o command= -p "$ancestor" 2>/dev/null || true)"
        if [[ "$command" == *"l1-drive.sh"* ]]; then
          kill -KILL "$ancestor"
          break
        fi
        ancestor="$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')"
      done
      sleep 1
      exit 137
    fi
    # Policy drift must be established and evidenced before any candidate bytes
    # or packet exist. A failed injection therefore cannot be salvaged through
    # l1-drive's intentional nonzero-with-output path.
    if [[ "${FROZEN_FIXTURE_MODE:-success}" == "drift" ]]; then
      drift_target="${FROZEN_FIXTURE_DRIFT_TARGET:-${FROZEN_FIXTURE_SOURCE_ROOT:?}/docs/orchestration/prompts/auditor.md}"
      "$FROZEN_PYTHON" - "$drift_target" \
        "${FROZEN_FIXTURE_COUNTER_DIR:?}/drift-injection-proof.json" <<'PY'
import hashlib, json, os, stat, sys
target, proof = sys.argv[1:]
before = open(target, "rb").read()
before_mode = stat.S_IMODE(os.stat(target).st_mode)
with open(target, "ab") as handle:
    handle.write(b"\nmid-run policy drift\n")
after = open(target, "rb").read()
after_mode = stat.S_IMODE(os.stat(target).st_mode)
if after == before or after_mode != before_mode:
    raise SystemExit("drift injection did not change only bytes")
record = {
    "schema": "singular.test.drift-injection-proof.v0",
    "target": target,
    "beforeSha256": hashlib.sha256(before).hexdigest(),
    "afterSha256": hashlib.sha256(after).hexdigest(),
    "beforeMode": before_mode,
    "afterMode": after_mode,
}
temporary = proof + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, proof)
PY
    fi
    mkdir -p "$worktree/internal/widget" "$worktree/.singular-evidence"
    branch="$(git -C "$worktree" branch --show-current)"
    if [[ "$branch" == "agent/widget/TASK-0001-repair" ]]; then
      printf 'package widget\n// authorized repair marker\n' >"$worktree/internal/widget/parser.go"
    else
      printf 'package widget\n// frozen campaign candidate\n' >"$worktree/internal/widget/parser.go"
    fi
    [[ -f "$worktree/internal/widget/note.txt" ]] \
      || printf 'worker note\n' >"$worktree/internal/widget/note.txt"
    printf 'intentional red fixture\n' >"$worktree/.singular-evidence/red.log"
    printf 'green fixture\n' >"$worktree/.singular-evidence/green.log"
    printf 'regression fixture\n' >"$worktree/.singular-evidence/regression.log"
    "$FROZEN_PYTHON" - "$output" "$run_id" "$worktree" "$branch" <<'PY'
import datetime, json, sys
out, run_id, worktree, branch = sys.argv[1:]
json.dump({
    "schema": "singular.orchestration.state-packet.v0",
    "packetId": run_id + "-packet",
    "runId": run_id,
    "taskId": "TASK-0001",
    "area": "widget",
    "role": "l2-developer",
    "status": "needs-review",
    "baseRef": "target",
    "branch": branch,
    "headSha": "uncommitted",
    "workspace": worktree,
    "ownedFiles": ["internal/widget/parser.go", "internal/widget/note.txt"],
    "changedFiles": ["internal/widget/parser.go", "internal/widget/note.txt"],
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
    write_result
    ;;
  auditor)
    bump auditor
    # evidence_delivery.py intentionally strips ambient engine paths before it
    # invokes the auditor. The host report is a required artifact beside the
    # requested output, so derive it from that explicit output capability.
    host_report="$(dirname "$output")/audit-verification.json"
    [[ -f "$host_report" ]] || exit 96
    branch="$(git -C "$worktree" branch --show-current)"
    "$FROZEN_PYTHON" - "$output" "$run_id" "$host_report" "$branch" <<'PY'
import json, sys
out, run_id, report, branch = sys.argv[1:]
status = json.load(open(report, encoding="utf-8"))["outcome"]
if status == "passed-with-acknowledged-baseline":
    status = "passed"
assert status in {"passed", "not-rerun-evidence-verified"}, status
json.dump({
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": run_id,
    "branch": branch,
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
  chmod u+w \
    "$FIXTURE_ROOT/docs/orchestration/prompts/l2-test-first-developer.md" \
    "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md"
  assert_eq "$(file_mode "$FIXTURE_ROOT/docs/orchestration/prompts/l2-test-first-developer.md")" \
    "420" "$name developer prompt planned mode 0644"
  assert_eq "$(file_mode "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md")" \
    "420" "$name auditor prompt planned mode 0644"
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
- `internal/widget/note.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The deterministic widget regression is green.
TASK
cat >"$FIXTURE_ROOT/strict-gate.sh" <<'GATE'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SINGULAR_TEST_TASK_CONTRACT:-}" ]]; then
  [[ "${SINGULAR_TEST_TASK_ID:-}" == "TASK-0001" ]]
  [[ "${SINGULAR_TEST_TASK_CONTRACT:-}" == \
    "${SINGULAR_TEST_TASKS_DIR:-}/TASK-0001.md" ]]
fi
if [[ -z "${SINGULAR_TEST_TASK_CONTRACT:-}" \
    && -f .frozen-repair-case \
    && "$(cat internal/widget/parser.go 2>/dev/null || true)" != *"authorized repair marker"* ]]; then
  printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[{"signature":"repair:required","title":"authorized repair marker is missing"}]}' \
    >"${SINGULAR_GATE_REPORT_FILE:?}"
  exit 1
fi
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
      FROZEN_FIXTURE_DRIFT_TARGET="${FROZEN_FIXTURE_DRIFT_TARGET:-}" \
      FROZEN_CONTINUATION_EXPECTED="${FROZEN_CONTINUATION_EXPECTED:-0}" \
      CONTINUATION_BOOTSTRAP_MARKER="${CONTINUATION_BOOTSTRAP_MARKER:-}" \
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

prepare_public_continuation() {
  local name="$1" predecessor_retry="$2" require_bootstrap="$3"
  make_fixture "$name"
  CONTINUATION_BOOTSTRAP_MARKER="$scratch/$name/bootstrap-ready"
  CONTINUATION_BOOTSTRAP_SCRIPT="$scratch/$name/bootstrap-check.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf '[[ -f %q ]]\n' "$CONTINUATION_BOOTSTRAP_MARKER"
  } >"$CONTINUATION_BOOTSTRAP_SCRIPT"
  chmod +x "$CONTINUATION_BOOTSTRAP_SCRIPT"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/singular.config.json" "$require_bootstrap" \
    "$CONTINUATION_BOOTSTRAP_SCRIPT" <<'PY'
import json, sys
path, required, script = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["bootstrap"] = {
    "required": required == "yes",
    "commands": [{"command": script, "required": True, "lockfiles": []}]
    if required == "yes" else [],
}
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  mkdir -p "$FIXTURE_ROOT/internal/widget"
  printf 'candidate baseline\n' >"$FIXTURE_ROOT/internal/widget/parser.go"
  git -C "$FIXTURE_ROOT" add singular.config.json internal/widget/parser.go
  git -C "$FIXTURE_ROOT" commit -qm 'older continuation candidate source'
  CONTINUATION_CANDIDATE="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
  git -C "$FIXTURE_ROOT" branch agent/widget/TASK-0001-frozen
  mkdir -p "$FIXTURE_ROOT/.worktrees"
  git -C "$FIXTURE_ROOT" worktree add -q "$FIXTURE_ROOT/.worktrees/TASK-0001" \
    agent/widget/TASK-0001-frozen
  CONTINUATION_WORKTREE="$FIXTURE_ROOT/.worktrees/TASK-0001"
  printf 'preserved tracked candidate bytes\n' >"$CONTINUATION_WORKTREE/internal/widget/parser.go"
  printf 'preserved untracked candidate bytes\n' >"$CONTINUATION_WORKTREE/internal/widget/note.txt"
  CONTINUATION_TRACKED_SHA="$(shasum -a 256 "$CONTINUATION_WORKTREE/internal/widget/parser.go" | awk '{print $1}')"
  CONTINUATION_UNTRACKED_SHA="$(shasum -a 256 "$CONTINUATION_WORKTREE/internal/widget/note.txt" | awk '{print $1}')"

  printf 'new reservation base\n' >"$FIXTURE_ROOT/reservation-base.txt"
  git -C "$FIXTURE_ROOT" add reservation-base.txt
  git -C "$FIXTURE_ROOT" commit -qm 'new engine reservation base'
  CONTINUATION_RESERVATION_BASE="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
  if [[ "$require_bootstrap" == "yes" ]]; then
    : >"$CONTINUATION_BOOTSTRAP_MARKER"
  fi
  start_campaign success
  if [[ "$require_bootstrap" == "yes" ]]; then
    rm -f "$CONTINUATION_BOOTSTRAP_MARKER"
  fi
  CONTINUATION_CAMPAIGN="$(run_engine success "$BASH_BIN" -c \
    '. "$1"; singular_campaign_binding' fixture "$ENGINE_HOME/engine/lib.sh")"
  CONTINUATION_RUNTIME_FINGERPRINT="$(run_engine success "$BASH_BIN" -c \
    '. "$1"; singular_campaign_engine_source_fingerprint' fixture "$ENGINE_HOME/engine/lib.sh")"
  CONTINUATION_OWNER='reconcile:ORIGIN-OLD:TASK-0001'
  CONTINUATION_GENERATION="$(run_engine success "$BASH_BIN" -c \
    '. "$1"; SCRIPT_DIR="$2"; . "$2/lifecycle.sh"; singular_lifecycle_reserve TASK-0001 "$3" ORIGIN-OLD agent/widget/TASK-0001-frozen widget '\''["internal/widget/parser.go","internal/widget/note.txt"]'\'' "$4" BATCH-OLD "$5"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$ENGINE_HOME/engine" \
    "$CONTINUATION_OWNER" "$CONTINUATION_RESERVATION_BASE" "$CONTINUATION_WORKTREE")"
  assert_eq "$CONTINUATION_GENERATION" "1" "$name predecessor reservation generation"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$predecessor_retry" <<'PY'
import json, os, sys
path, retry = sys.argv[1], int(sys.argv[2])
data = json.load(open(path, encoding="utf-8"))
data["productPassStarted"] = True
data["productPassStartedRunId"] = "WORKER-OLD"
data["retryCount"] = retry
data["maxRetries"] = 1
tmp = path + ".tmp"
json.dump(data, open(tmp, "w", encoding="utf-8"), indent=2)
os.replace(tmp, path)
PY

  run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/recover.sh" orphan-reservation \
    TASK-0001 --owner "$CONTINUATION_OWNER" --generation "$CONTINUATION_GENERATION" \
    --run ORIGIN-OLD --campaign "$CONTINUATION_CAMPAIGN" \
    --reservation-base "$CONTINUATION_RESERVATION_BASE" \
    --candidate-source "$CONTINUATION_CANDIDATE" --worktree "$CONTINUATION_WORKTREE" \
    >"$scratch/$name-orphan-recovery.log"
  run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/recover.sh" continuation \
    TASK-0001 --predecessor-owner "$CONTINUATION_OWNER" \
    --predecessor-generation "$CONTINUATION_GENERATION" --predecessor-run ORIGIN-OLD \
    --predecessor-campaign "$CONTINUATION_CAMPAIGN" \
    --predecessor-reservation-base "$CONTINUATION_RESERVATION_BASE" \
    --candidate-source "$CONTINUATION_CANDIDATE" \
    --integration-target "$CONTINUATION_RESERVATION_BASE" \
    --worktree "$CONTINUATION_WORKTREE" >"$scratch/$name-continuation-recovery.log"

  printf 'new current target\n' >"$FIXTURE_ROOT/current-target.txt"
  git -C "$FIXTURE_ROOT" add current-target.txt
  git -C "$FIXTURE_ROOT" commit -qm 'advance current integration target'
  CONTINUATION_CURRENT_TARGET="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
  [[ "$CONTINUATION_CANDIDATE" != "$CONTINUATION_RESERVATION_BASE" \
      && "$CONTINUATION_RESERVATION_BASE" != "$CONTINUATION_CURRENT_TARGET" ]] \
    || fail "$name did not keep candidate, reservation base, and current target distinct"
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor "$CONTINUATION_RESERVATION_BASE" \
    "$CONTINUATION_CURRENT_TARGET" || fail "$name current target broke authorized ancestry"
}

assert_public_continuation_identity() {
  local name="$1" predecessor_retry="$2" expected_generation="$3"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$FIXTURE_ROOT/.singular-state/dispatch/TASK-0001.json" \
    "$CONTINUATION_CANDIDATE" "$CONTINUATION_RESERVATION_BASE" \
    "$CONTINUATION_CURRENT_TARGET" "$CONTINUATION_RUNTIME_FINGERPRINT" \
    "$predecessor_retry" "$expected_generation" <<'PY'
import json, subprocess, sys
(lease_path, dispatch_path, candidate, reservation_base, current_target,
 runtime_fingerprint, retry, generation) = sys.argv[1:]
lease = json.load(open(lease_path, encoding="utf-8"))
dispatch = json.load(open(dispatch_path, encoding="utf-8"))
authority = lease["continuationAuthorization"]
assert authority["candidateSourceSha"] == candidate, lease
assert authority["integrationTargetSha"] == reservation_base, lease
assert lease["reservationBaseSha"] == current_target, lease
assert authority["engineSourceFingerprint"] == runtime_fingerprint, lease
assert authority["predecessorAccounting"]["retryCount"] == int(retry), lease
assert lease["retryCount"] == int(retry), lease
assert lease["maxRetries"] == 1, lease
assert authority["additionalWorkerAttemptsAuthorized"] == 1, lease
assert authority["additionalWorkerAttemptsClaimed"] == 1, lease
assert authority["additionalWorkerAttemptsRemaining"] == 0, lease
assert authority["state"] == "claimed", lease
assert lease["terminalDisposition"]["kind"] == "completed", lease
assert lease["terminalDispositionHistory"][0]["kind"] == "orphan-reservation", lease
assert dispatch["reservationGeneration"] == int(generation), dispatch
assert dispatch["attemptLifecycle"]["state"] == "terminal", dispatch
assert dispatch["attemptLifecycle"]["continuationAuthorizationId"] == authority["authorizationId"], dispatch
PY
  assert_eq "$(calls worker)" "1" "$name exactly one continuation worker"
  assert_eq "$(calls auditor)" "1" "$name exactly one continuation auditor"
  assert_eq "$(find "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" \
    -maxdepth 1 -name '*.json' -not -name '*.audit.json' -type f 2>/dev/null | wc -l | tr -d '[:space:]')" \
    "1" "$name exactly one accepted publication"
}

test_public_continuation_budget() {
  local name="$1" predecessor_retry="$2"
  prepare_public_continuation "$name" "$predecessor_retry" no
  FROZEN_CONTINUATION_EXPECTED=1 reconcile success "$name-dispatch"
  FROZEN_CONTINUATION_EXPECTED=1 reconcile success "$name-import"
  FROZEN_CONTINUATION_EXPECTED=1 reconcile success "$name-no-duplicate"
  assert_public_continuation_identity "$name" "$predecessor_retry" 2
  echo "ok: $name public frozen continuation preserves ordinary retry accounting"
}

test_public_continuation_bootstrap_reissue() {
  local name=continuation-bootstrap
  prepare_public_continuation "$name" 1 yes
  CONTINUATION_BOOTSTRAP_MARKER="$CONTINUATION_BOOTSTRAP_MARKER" \
    FROZEN_CONTINUATION_EXPECTED=1 reconcile success "$name-preparation-failure"
  assert_eq "$(calls worker)" "0" "$name preparation failure worker calls"
  [[ "$(shasum -a 256 "$CONTINUATION_WORKTREE/internal/widget/parser.go" | awk '{print $1}')" \
      == "$CONTINUATION_TRACKED_SHA" ]] || fail "$name changed tracked partial bytes"
  [[ "$(shasum -a 256 "$CONTINUATION_WORKTREE/internal/widget/note.txt" | awk '{print $1}')" \
      == "$CONTINUATION_UNTRACKED_SHA" ]] || fail "$name changed untracked partial bytes"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); a=d["continuationAuthorization"]
assert d["status"] == "ready" and a["state"] == "issued", d
assert a["preparationFailureCount"] == 1, d
assert a["automaticPreparationRetriesRemaining"] == 0, d
assert a["additionalWorkerAttemptsClaimed"] == 0, d
assert d["retryCount"] == 1 and d["maxRetries"] == 1, d
assert "attemptLifecycle" not in d, d
PY
  CONTINUATION_BOOTSTRAP_MARKER="$CONTINUATION_BOOTSTRAP_MARKER" \
    FROZEN_CONTINUATION_EXPECTED=1 reconcile success "$name-repeated-preparation-failure"
  assert_eq "$(calls worker)" "0" "$name repeated preparation failure worker calls"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); a=d["continuationAuthorization"]
task = open(sys.argv[2], encoding="utf-8").read()
assert d["status"] == "blocked" and a["state"] == "preparation-blocked", d
assert a["preparationFailureCount"] == 2, d
assert a["additionalWorkerAttemptsClaimed"] == 0, d
assert re.search(r"^Status:\s*blocked\s*$", task, re.MULTILINE | re.IGNORECASE), task
PY
  : >"$CONTINUATION_BOOTSTRAP_MARKER"
  authorization_id="$("$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["continuationAuthorization"]["authorizationId"])
PY
)"
  if run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/recover.sh" \
      continuation-preparation TASK-0001 --authorization-id "$authorization_id" \
      --evidence "$scratch/$name/missing-repair-evidence" >/dev/null 2>&1; then
    fail "$name accepted missing host repair evidence"
  fi
  run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/recover.sh" \
    continuation-preparation TASK-0001 --authorization-id "$authorization_id" \
    --evidence "$CONTINUATION_BOOTSTRAP_MARKER" \
    >"$scratch/$name-preparation-rearmed.log"
  # The two preparation-only reconcile cycles may publish ordinary control
  # state. Bind the assertion to the actual target used by the final scheduler
  # reservation; the authority's earlier integration target must remain its
  # ancestor, not be relabeled as this newer head.
  CONTINUATION_CURRENT_TARGET="$(git -C "$FIXTURE_ROOT" rev-parse target)"
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor "$CONTINUATION_RESERVATION_BASE" \
    "$CONTINUATION_CURRENT_TARGET" || fail "$name repaired target lost authorized ancestry"
  CONTINUATION_BOOTSTRAP_MARKER="$CONTINUATION_BOOTSTRAP_MARKER" \
    FROZEN_CONTINUATION_EXPECTED=1 reconcile success "$name-dispatch"
  CONTINUATION_BOOTSTRAP_MARKER="$CONTINUATION_BOOTSTRAP_MARKER" \
    FROZEN_CONTINUATION_EXPECTED=1 reconcile success "$name-import"
  CONTINUATION_BOOTSTRAP_MARKER="$CONTINUATION_BOOTSTRAP_MARKER" \
    FROZEN_CONTINUATION_EXPECTED=1 reconcile success "$name-no-duplicate"
  assert_public_continuation_identity "$name" 1 4
  echo "ok: required bootstrap reissues once, blocks repetition, and completes after evidenced repair"
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

prepare_native_repair() {
  local name="$1"
  make_fixture "$name"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import sys
p=sys.argv[1]; text=open(p, encoding="utf-8").read()
text=text.replace("Area: widget\n", "Area: widget\nRisk tier: high\n", 1)
open(p, "w", encoding="utf-8").write(text)
PY
  : >"$FIXTURE_ROOT/.frozen-repair-case"
  git -C "$FIXTURE_ROOT" add .frozen-repair-case docs/orchestration/tasks/TASK-0001.md
  git -C "$FIXTURE_ROOT" commit -qm 'declare frozen repair fixture control'
  start_campaign success

  reconcile success "$name-predecessor-dispatch"
  reconcile success "$name-predecessor-import"
  assert_terminal_contract completed "" accepted
  assert_eq "$(calls worker)" "1" "$name predecessor worker calls"
  assert_eq "$(calls auditor)" "1" "$name predecessor auditor calls"

  PREDECESSOR_RUN="$($PYTHON_BIN - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "accepted", d
assert d["attemptLifecycle"]["state"] == "terminal", d
print(d["attemptLifecycle"]["runId"])
PY
)"
  PREDECESSOR_ATTEMPT_SHA="$(shasum -a 256 "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" | awk '{print $1}')"

  local rc=0
  run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0001 --run-id "$name-integration-red" \
    >"$scratch/$name-integration-red.log" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "$name predecessor unexpectedly integrated"
  REPAIR_FAILURE_ID="$($PYTHON_BIN - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
      "$PREDECESSOR_RUN" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); c=d["acceptedCandidate"]
assert c["runId"] == sys.argv[2] and c["state"] == "integration-failed", d
assert c["failures"][-1]["domain"] == "product", c
print(c["failures"][-1]["failureId"])
PY
)"
  REPAIR_RUN="RUN-$name-SUCCESSOR"
  REPAIR_BRANCH="agent/widget/TASK-0001-repair"
  REPAIR_WORKTREE="$FIXTURE_ROOT/.worktrees/TASK-0001-repair"
  run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/recover.sh" candidate TASK-0001 \
    --action repair --successor-run "$REPAIR_RUN" --successor-branch "$REPAIR_BRANCH" \
    --successor-worktree "$REPAIR_WORKTREE" --failure-id "$REPAIR_FAILURE_ID" \
    >"$scratch/$name-authorize.log"
  run_engine success "$PYTHON_BIN" "$ENGINE_HOME/engine/task_lifecycle.py" \
    repair-dispatch-eligible \
    --lease "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    --task-contract "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" >/dev/null \
    || fail "$name public repair was absent from the scheduler frontier"
}

assert_repair_scheduler_identity() {
  local name="$1" expected_kind="$2"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$FIXTURE_ROOT/.singular-state/dispatch/TASK-0001.json" \
    "$PREDECESSOR_RUN" "$REPAIR_RUN" "$expected_kind" <<'PY'
import json, sys
lease=json.load(open(sys.argv[1], encoding="utf-8"))
dispatch=json.load(open(sys.argv[2], encoding="utf-8"))
predecessor, successor, kind=sys.argv[3:]
authority=lease["recoveryAuthorization"]
attempt=lease["attemptLifecycle"]
assert authority["state"] == "claimed", lease
assert lease["runId"] == successor == attempt["runId"], lease
assert authority["reservationRunId"] == dispatch["runId"] == attempt["reservationRunId"], (lease, dispatch)
assert authority["reservationOwner"] == lease.get("reservationOwner", lease.get("lastReservationOwner")), lease
if kind == "outcome-unknown":
    assert attempt["state"] == "started", attempt
    assert lease["terminalDisposition"]["kind"] == kind, lease
else:
    assert attempt["state"] == "terminal" and attempt["disposition"] == kind, attempt
assert any(x.get("runId") == predecessor for x in lease["attemptHistory"]), lease
assert any(x.get("runId") == predecessor for x in lease["terminalDispositionHistory"]), lease
PY
}

test_native_repair_scheduler() {
  local name=repair-native
  prepare_native_repair "$name"
  reconcile success "$name-successor-dispatch"
  reconcile success "$name-successor-import"
  assert_repair_scheduler_identity "$name" completed
  assert_eq "$(calls worker)" "2" "$name exactly one repair worker"
  assert_eq "$(calls auditor)" "2" "$name exactly one repair auditor"

  local merge_before
  run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0001 --run-id "$name-integration-green" \
    >"$scratch/$name-integration-green.log" 2>&1 \
    || fail "$name repair successor did not integrate: $(tail -30 "$scratch/$name-integration-green.log")"
  merge_before="$($PYTHON_BIN - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["acceptedCandidate"]["mergeCommit"])
PY
)"
  reconcile success "$name-restart-one"
  reconcile success "$name-restart-two"
  assert_eq "$(calls worker)" "2" "$name restart did not duplicate repair worker"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" "$merge_before" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "integrated", d
assert d["recoveryAuthorization"]["state"] == "published", d
assert d["acceptedCandidate"]["state"] == "integrated", d
assert d["acceptedCandidate"]["mergeCommit"] == sys.argv[2], d
PY
  echo "ok: frozen native accepted predecessor repairs through scheduler and exact integration"
}

test_native_repair_started_crash() {
  local name=repair-crash
  prepare_native_repair "$name"
  reconcile crash-started "$name-successor-crash"
  sleep 2
  reconcile success "$name-reap"
  assert_repair_scheduler_identity "$name" outcome-unknown
  assert_eq "$(calls worker)" "2" "$name crashed repair invoked once"
  local generation
  generation="$($PYTHON_BIN - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["reservationGeneration"])
PY
)"
  reconcile success "$name-restart"
  assert_eq "$(calls worker)" "2" "$name restart refused a second repair worker"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" "$generation" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["recoveryAuthorization"]
assert d["status"] == "blocked", d
assert d["reservationGeneration"] == int(sys.argv[2]), d
assert a["state"] == "claimed", a
assert d["attemptLifecycle"]["runId"] == a["successorRunId"], d
PY
  if run_engine success "$PYTHON_BIN" "$ENGINE_HOME/engine/task_lifecycle.py" reserve \
      --lease "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" --task TASK-0001 \
      --owner reconcile:ORIGIN-SECOND:TASK-0001 --run ORIGIN-SECOND \
      --branch "$REPAIR_BRANCH" --area widget \
      --scope-json '["internal/widget/parser.go","internal/widget/note.txt"]' \
      --base "$(git -C "$FIXTURE_ROOT" rev-parse target)" --batch BATCH-SECOND \
      --worktree "$REPAIR_WORKTREE" --imported-dir "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" \
      --campaign "$(run_engine success "$BASH_BIN" -c '. "$1"; singular_campaign_binding' fixture "$ENGINE_HOME/engine/lib.sh")" \
      --repo-root "$FIXTURE_ROOT" --engine-source-fingerprint legacy >/dev/null 2>&1; then
    fail "$name claimed successor was admitted into a new generation"
  fi
  echo "ok: started repair crash stays outcome-unknown and cannot regenerate"
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

test_policy_drift_injection_failure_is_fail_closed() {
  local name=drift-injection-failure output result
  make_fixture "$name"
  output="$scratch/$name/candidate-packet.json"
  result="$scratch/$name/runner-result.json"
  if FROZEN_FIXTURE_DRIFT_TARGET="$scratch/$name/missing/auditor.md" \
      run_engine drift env \
        SINGULAR_RUNNER_ROLE=implementer \
        SINGULAR_RUNNER_CAPABILITY_PROFILE=fixture \
        SINGULAR_RUNNER_RESULT_FILE="$result" \
        SINGULAR_TEST_TASK_ID=TASK-0001 \
        SINGULAR_TEST_TASK_CONTRACT="$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" \
        SINGULAR_TEST_TASKS_DIR="$FIXTURE_ROOT/docs/orchestration/tasks" \
        "$FIXTURE_RUNNER" --worktree "$FIXTURE_ROOT" --level l2 \
          --run-id RUN-DRIFT-INJECTION-FAILURE --output-last-message "$output" \
          >"$scratch/$name/injection-failure.log" 2>&1; then
    fail "$name unexpectedly succeeded"
  fi
  [[ ! -e "$output" ]] || fail "$name left usable candidate output"
  [[ ! -e "$result" ]] || fail "$name left a successful runner result"
  [[ ! -e "$FIXTURE_COUNTERS/drift-injection-proof.json" ]] \
    || fail "$name claimed a failed injection was proved"
  [[ ! -e "$FIXTURE_ROOT/internal/widget/parser.go" ]] \
    || fail "$name created candidate bytes before drift injection"
  assert_eq "$(calls worker)" "1" "$name attempted exactly one worker injection"
  echo "ok: failed drift injection cannot create usable worker output"
}

test_policy_drift() {
  local packet original_sha original_mode
  make_fixture drift
  cp "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md" "$scratch/drift-auditor.original"
  original_sha="$(shasum -a 256 "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md" | awk '{print $1}')"
  original_mode="$(file_mode "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md")"
  start_campaign drift
  # L1 publishes the campaign-mismatch disposition, and the same reconcile
  # process then refuses its later control-state commit under the changed
  # policy. Exit 2 is the expected outer entrypoint refusal.
  reconcile drift drift-first 2
  assert_file "$FIXTURE_COUNTERS/drift-injection-proof.json" \
    "drift injection proof"
  "$PYTHON_BIN" - "$FIXTURE_COUNTERS/drift-injection-proof.json" \
    "$FIXTURE_ROOT/.singular-state/campaign/manifest.json" \
    "$FIXTURE_ROOT/docs/orchestration/prompts" \
    "$ENGINE_HOME/engine/campaign_manifest.py" "$original_sha" "$original_mode" <<'PY'
import hashlib, importlib.util, json, pathlib, stat, sys
proof_path, manifest_path, prompts, module_path, original_sha, original_mode = sys.argv[1:]
proof = json.load(open(proof_path, encoding="utf-8"))
manifest = json.load(open(manifest_path, encoding="utf-8"))
spec = importlib.util.spec_from_file_location("campaign_manifest", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
actual = module.tree_fingerprint(prompts)
expected = manifest["activePolicy"]["consumer-prompts"]
target = pathlib.Path(proof["target"])
assert proof["beforeSha256"] == original_sha, proof
assert proof["beforeMode"] == proof["afterMode"] == int(original_mode), proof
assert proof["beforeSha256"] != proof["afterSha256"], proof
assert hashlib.sha256(target.read_bytes()).hexdigest() == proof["afterSha256"], proof
assert stat.S_IMODE(target.stat().st_mode) == int(original_mode), proof
assert expected["sha256"] != actual["sha256"], (expected, actual)
PY
  assert_eq "$(calls worker)" "1" "drift worker calls"
  assert_eq "$(calls auditor)" "1" "drift semantic audit completed before refusal"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/events.ndjson" \
    "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$FIXTURE_ROOT/.singular-state/campaign/manifest.json" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
drift_events = [event for event in events if event.get("type") == "campaign.drift_detected"]
assert len(drift_events) == 2, drift_events
assert [(event["data"]["entrypoint"], event["data"]["phase"])
        for event in drift_events] == [
    ("l1-drive", "post-accepted-audit-checkpoint"),
    ("reconcile", "pre-control-state-commit"),
], drift_events
for event in drift_events:
    data = event["data"]
    assert data["manifest"] == sys.argv[3], data
    assert type(data["verifyExitCode"]) is int, data
    assert data["verifyExitCode"] == 3, data
    assert "raw" not in data, data
assert sum(event.get("type") == "l1.campaign_mismatch" for event in events) == 1, events
assert not any(event.get("type") == "l1.task_accepted" for event in events), events
assert not any(event.get("type") == "origin.control_state_committed" for event in events), events
lease = json.load(open(sys.argv[2], encoding="utf-8"))
terminal = lease["terminalDisposition"]
assert terminal["kind"] == "campaign-mismatch", terminal
assert terminal["failureClass"] == "campaign-mismatch", terminal
assert terminal["action"] == "re-audit-current-campaign", terminal
PY
  [[ ! -d "$FIXTURE_ROOT/.singular-state/inbox" ]] \
    || [[ -z "$(find "$FIXTURE_ROOT/.singular-state/inbox" -name '*.json' -type f -print -quit)" ]] \
    || fail "drift published an inbox packet"
  [[ ! -d "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" ]] \
    || [[ -z "$(find "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" \
      -name '*.json' -type f -print -quit)" ]] \
    || fail "drift published an imported packet"
  packet="$(find "$FIXTURE_ROOT/.singular-state/runs" -name packet.json -type f -print -quit)"
  assert_file "$packet" "drift worker packet preserved"
  assert_file "$FIXTURE_ROOT/.worktrees/TASK-0001/internal/widget/parser.go" \
    "drift partial candidate preserved"
  cp "$scratch/drift-auditor.original" "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md"
  chmod "$(printf '%04o' "$original_mode")" \
    "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md"
  assert_eq "$(shasum -a 256 "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md" | awk '{print $1}')" \
    "$original_sha" "drift restores exact auditor bytes"
  assert_eq "$(file_mode "$FIXTURE_ROOT/docs/orchestration/prompts/auditor.md")" \
    "$original_mode" "drift restores exact auditor mode"
  run_engine drift "$BASH_BIN" "$ENGINE_HOME/engine/campaign.sh" verify --quiet \
    || fail "drift exact restoration did not recover the frozen campaign fingerprint"
  set_task_ready
  reconcile drift drift-reconcile-2
  reconcile drift drift-reconcile-3
  assert_eq "$(calls worker)" "1" "drift restart did not duplicate worker"
  assert_eq "$(calls auditor)" "1" "drift restart did not manufacture audit"
  assert_terminal_contract campaign-mismatch campaign-mismatch re-audit-current-campaign
  assert_contains "$(cat "$scratch/drift-reconcile-2.log" "$scratch/drift-reconcile-3.log")" \
    'reservation refused for TASK-0001' "drift restart durable reservation refusal"
  [[ ! -d "$FIXTURE_ROOT/.singular-state/inbox" ]] \
    || [[ -z "$(find "$FIXTURE_ROOT/.singular-state/inbox" -name '*.json' -type f -print -quit)" ]] \
    || fail "drift restart published an inbox packet"
  [[ ! -d "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" ]] \
    || [[ -z "$(find "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" \
      -name '*.json' -type f -print -quit)" ]] \
    || fail "drift restart published an imported packet"
  echo "ok: mid-run policy drift preserves artifacts and refuses duplicate publication"
}

case "${FROZEN_TERMINAL_CASE:-all}" in
  success) test_success ;;
  infra) test_infra_exhaustion ;;
  drift) test_policy_drift ;;
  drift-injection-failure) test_policy_drift_injection_failure_is_fail_closed ;;
  continuation-budget)
    test_public_continuation_budget continuation-budget-available 0
    test_public_continuation_budget continuation-budget-exhausted 1
    ;;
  continuation-bootstrap) test_public_continuation_bootstrap_reissue ;;
  repair) test_native_repair_scheduler ;;
  repair-crash) test_native_repair_started_crash ;;
  continuation)
    test_public_continuation_budget continuation-budget-available 0
    test_public_continuation_budget continuation-budget-exhausted 1
    test_public_continuation_bootstrap_reissue
    test_native_repair_scheduler
    test_native_repair_started_crash
    ;;
  all)
    test_success
    test_infra_exhaustion
    test_policy_drift_injection_failure_is_fail_closed
    test_policy_drift
    test_public_continuation_budget continuation-budget-available 0
    test_public_continuation_budget continuation-budget-exhausted 1
    test_public_continuation_bootstrap_reissue
    test_native_repair_scheduler
    test_native_repair_started_crash
    ;;
  *) fail "unknown FROZEN_TERMINAL_CASE=${FROZEN_TERMINAL_CASE}" ;;
esac

echo "PASS: frozen campaign terminal lifecycle"
