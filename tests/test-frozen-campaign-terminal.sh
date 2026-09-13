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
  SINGULAR_JSON_CONFIG_SOURCE SINGULAR_CONTEXT_CONFIG_FILE \
  SINGULAR_CONTEXT_BUDGET_BYTES 2>/dev/null || true

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
tree_bytes_modes_binding() {
  "$PYTHON_BIN" - "$1" <<'PY'
import hashlib, json, os, stat, sys

records = []

def record(path, relative):
    mode = os.lstat(path).st_mode
    if stat.S_ISDIR(mode):
        kind, payload = "directory", None
    elif stat.S_ISREG(mode):
        kind = "file"
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        payload = digest.hexdigest()
    elif stat.S_ISLNK(mode):
        kind, payload = "symlink", os.readlink(path)
    else:
        kind, payload = "other", None
    records.append([relative, kind, stat.S_IMODE(mode), payload])
    if kind == "directory":
        for entry in sorted(os.scandir(path), key=lambda item: item.name):
            child = entry.name if not relative else relative + "/" + entry.name
            record(entry.path, child)

record(os.path.abspath(sys.argv[1]), "")
encoded = json.dumps(records, ensure_ascii=True, separators=(",", ":")).encode()
print(hashlib.sha256(encoded).hexdigest())
PY
}

FROZEN_BOUND_SOURCE_ENGINE=
FROZEN_BOUND_SOURCE_BINDING=
FROZEN_BOUND_TEST_ENGINE=
FROZEN_BOUND_TEST_BINDING=
FROZEN_OWNED_TEST_ENGINE=

verify_frozen_engine_bindings() {
  local actual failed=0
  if [[ -n "$FROZEN_BOUND_SOURCE_ENGINE" ]]; then
    if ! actual="$(tree_bytes_modes_binding "$FROZEN_BOUND_SOURCE_ENGINE")"; then
      echo "FAIL: accepted-recovery source engine binding could not be read" >&2
      failed=1
    elif [[ "$actual" != "$FROZEN_BOUND_SOURCE_BINDING" ]]; then
      echo "FAIL: accepted-recovery source engine bytes or modes changed" >&2
      failed=1
    fi
  fi
  if [[ -n "$FROZEN_BOUND_TEST_ENGINE" ]]; then
    if ! actual="$(tree_bytes_modes_binding "$FROZEN_BOUND_TEST_ENGINE")"; then
      echo "FAIL: accepted-recovery prepared test engine binding could not be read" >&2
      failed=1
    elif [[ "$actual" != "$FROZEN_BOUND_TEST_BINDING" ]]; then
      echo "FAIL: accepted-recovery prepared test engine bytes or modes changed" >&2
      failed=1
    fi
  fi
  return "$failed"
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/singular-frozen-terminal.XXXXXX")"
cleanup() {
  local exit_status=$? cleanup_failed=0
  trap - EXIT
  verify_frozen_engine_bindings || cleanup_failed=1
  if [[ "${FROZEN_KEEP_TMP:-0}" == "1" ]]; then
    echo "frozen terminal fixture retained: $scratch" >&2
  else
    if [[ -n "$FROZEN_OWNED_TEST_ENGINE" \
        && "$FROZEN_OWNED_TEST_ENGINE" == "$scratch/"* ]]; then
      chmod -R u+w "$FROZEN_OWNED_TEST_ENGINE" 2>/dev/null || cleanup_failed=1
    fi
    rm -rf "$scratch" || cleanup_failed=1
  fi
  if [[ "$exit_status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    exit_status=1
  fi
  exit "$exit_status"
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
    task_id="${SINGULAR_TEST_TASK_ID:-}"
    [[ "$task_id" == "TASK-0001" || "$task_id" == "TASK-0002" ]] || exit 94
    [[ "${SINGULAR_TEST_TASK_CONTRACT:-}" == \
      "${SINGULAR_TEST_TASKS_DIR:-}/$task_id.md" ]] || exit 95
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
    mkdir -p "$worktree/.singular-evidence"
    branch="$(git -C "$worktree" branch --show-current)"
    if [[ "$task_id" == "TASK-0002" ]]; then
      mkdir -p "$worktree/internal/followup"
      printf 'package followup\n// dependent fixture\n' >"$worktree/internal/followup/next.go"
    elif [[ "$branch" == "agent/widget/TASK-0001-repair" ]]; then
      mkdir -p "$worktree/internal/widget"
      printf 'package widget\n// authorized repair marker\n' >"$worktree/internal/widget/parser.go"
    else
      mkdir -p "$worktree/internal/widget"
      printf 'package widget\n// frozen campaign candidate\n' >"$worktree/internal/widget/parser.go"
    fi
    if [[ "$task_id" == "TASK-0001" ]]; then
      [[ -f "$worktree/internal/widget/note.txt" ]] \
        || printf 'worker note\n' >"$worktree/internal/widget/note.txt"
    fi
    printf 'intentional red fixture\n' >"$worktree/.singular-evidence/red.log"
    printf 'green fixture\n' >"$worktree/.singular-evidence/green.log"
    printf 'regression fixture\n' >"$worktree/.singular-evidence/regression.log"
    "$FROZEN_PYTHON" - "$output" "$run_id" "$worktree" "$branch" "$task_id" <<'PY'
import datetime, json, sys
out, run_id, worktree, branch, task_id = sys.argv[1:]
changed = (["internal/followup/next.go"] if task_id == "TASK-0002" else
           ["internal/widget/note.txt", "internal/widget/parser.go"])
owned = ["internal/followup/"] if task_id == "TASK-0002" else ["internal/widget/"]
json.dump({
    "schema": "singular.orchestration.state-packet.v0",
    "packetId": run_id + "-packet",
    "runId": run_id,
    "taskId": task_id,
    "area": "widget",
    "role": "l2-developer",
    "status": "needs-review",
    "baseRef": "target",
    "branch": branch,
    "headSha": "uncommitted",
    "workspace": worktree,
    "ownedFiles": owned,
    "changedFiles": changed,
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
host = json.load(open(report, encoding="utf-8"))
status = host["outcome"]
task_id = host["taskId"]
if status == "passed-with-acknowledged-baseline":
    status = "passed"
assert status in {"passed", "not-rerun-evidence-verified"}, status
json.dump({
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": task_id,
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
  decider)
    bump decider
    exit 97
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

- `internal/widget/`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The deterministic widget regression is green.
TASK
cat >"$FIXTURE_ROOT/strict-gate.sh" <<'GATE'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FROZEN_FIXTURE_COUNTER_DIR:-}" ]]; then
  counter="$FROZEN_FIXTURE_COUNTER_DIR/gate-calls"
  count=0
  [[ -f "$counter" ]] && count="$(cat "$counter")"
  printf '%s\n' "$((count + 1))" >"$counter"
fi
if [[ -n "${SINGULAR_TEST_TASK_CONTRACT:-}" ]]; then
  task_id="${SINGULAR_TEST_TASK_ID:-}"
  [[ "$task_id" == "TASK-0001" || "$task_id" == "TASK-0002" ]]
  [[ "${SINGULAR_TEST_TASK_CONTRACT:-}" == \
    "${SINGULAR_TEST_TASKS_DIR:-}/$task_id.md" ]]
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

enable_context_service() {
  mkdir -p "$FIXTURE_ROOT/policy/nested"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/singular.config.json" \
    "$FIXTURE_ROOT/policy/nested/context.json" <<'PY'
import json, sys
path, alternate = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["contextService"] = {"enabled": False, "budgetBytes": 1, "rolePolicy": {}}
data.setdefault("env", {})["SINGULAR_CONTEXT_CONFIG_FILE"] = "policy/nested/context.json"
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
policy = {
    "enabled": True,
    "projectId": "frozen-terminal-fixture",
    "budgetBytes": 65536,
    "codePaths": ["docs/orchestration/tasks/TASK-0001.md"],
    "rolePolicy": {
        "planner": ["code"],
        "implementer": ["code"],
        "review-target": ["code"],
    },
}
json.dump({"contextService": policy}, open(alternate, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
  git -C "$FIXTURE_ROOT" add singular.config.json policy/nested/context.json
  git -C "$FIXTURE_ROOT" commit -qm 'enable frozen context service'
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
      FROZEN_EVIDENCE_TARGET_RUNS_DIR="${FROZEN_EVIDENCE_TARGET_RUNS_DIR:-}" \
      FROZEN_EVIDENCE_TARGET_RUN_ID="${FROZEN_EVIDENCE_TARGET_RUN_ID:-}" \
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
  local workspace_shape="${4:-default}"
  local predecessor_max="${5:-1}" repair_shape="${6:-no}"
  make_fixture "$name"
  if [[ "$repair_shape" == "yes" ]]; then
    "$PYTHON_BIN" - "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import sys
p=sys.argv[1]; text=open(p, encoding="utf-8").read()
text=text.replace("Area: widget\n", "Area: widget\nRisk tier: high\n", 1)
open(p, "w", encoding="utf-8").write(text)
PY
    : >"$FIXTURE_ROOT/.frozen-repair-case"
    cat >"$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0002.md" <<'TASK'
# TASK-0002: Frozen dependent fixture

Status: ready
Area: followup
Target branch: `target`
Worker branch: `agent/followup/TASK-0002-frozen`
Test policy: `strict_test_first`
Gate command: `bash strict-gate.sh`
Dispatch mode: canonical
Depends on: [TASK-0001]

## Objective

Exercise the first native reservation after exact predecessor integration.

## Scope

Owned files:

- `internal/followup/`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The dependent fixture receives the integrated target as its reservation base.
TASK
  fi
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
  if [[ "$repair_shape" == "yes" ]]; then
    git -C "$FIXTURE_ROOT" add .frozen-repair-case \
      docs/orchestration/tasks/TASK-0001.md \
      docs/orchestration/tasks/TASK-0002.md
  fi
  git -C "$FIXTURE_ROOT" commit -qm 'older continuation candidate source'
  CONTINUATION_CANDIDATE="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
  git -C "$FIXTURE_ROOT" branch agent/widget/TASK-0001-frozen
  if [[ "$workspace_shape" == "custom" ]]; then
    CONTINUATION_WORKTREE="$scratch/$name/retained continuation workspace"
    mkdir -p "$(dirname "$CONTINUATION_WORKTREE")"
  else
    mkdir -p "$FIXTURE_ROOT/.worktrees"
    CONTINUATION_WORKTREE="$FIXTURE_ROOT/.worktrees/TASK-0001"
  fi
  git -C "$FIXTURE_ROOT" worktree add -q "$CONTINUATION_WORKTREE" \
    agent/widget/TASK-0001-frozen
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
    '. "$1"; SCRIPT_DIR="$2"; . "$2/lifecycle.sh"; singular_lifecycle_reserve TASK-0001 "$3" ORIGIN-OLD agent/widget/TASK-0001-frozen widget '\''["internal/widget/"]'\'' "$4" BATCH-OLD "$5"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$ENGINE_HOME/engine" \
    "$CONTINUATION_OWNER" "$CONTINUATION_RESERVATION_BASE" "$CONTINUATION_WORKTREE")"
  assert_eq "$CONTINUATION_GENERATION" "1" "$name predecessor reservation generation"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$predecessor_retry" "$predecessor_max" <<'PY'
import json, os, sys
path, retry, maximum = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = json.load(open(path, encoding="utf-8"))
data["productPassStarted"] = True
data["productPassStartedRunId"] = "WORKER-OLD"
data["retryCount"] = retry
data["maxRetries"] = maximum
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
    --candidate-base "$CONTINUATION_CANDIDATE" \
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
assert authority["candidateBaseSha"] == candidate, lease
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
  "$PYTHON_BIN" - "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" \
    "$CONTINUATION_CANDIDATE" <<'PY'
import json, pathlib, sys
packets = [path for path in pathlib.Path(sys.argv[1]).glob("*.json")
           if not path.name.endswith(".audit.json")]
assert len(packets) == 1, packets
packet = json.load(open(packets[0], encoding="utf-8"))
assert packet["baseRef"] == sys.argv[2], packet
assert packet["changedFiles"] == ["internal/widget/note.txt", "internal/widget/parser.go"], packet
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

test_custom_continuation_accepted_publication() {
  local name=continuation-custom-accepted source_engine test_engine default_worktree
  local lease authorization_id owner generation dispatch_run dispatch_log wrapper_pid
  local wrapper_rc=0 run_id run_dir packet audit base head target_after out rc=0
  local worker_before auditor_before gate_before decider_before evidence_before
  local authority_before accounting_before lease_snapshot mutation
  local decoy_branch decoy_head decoy_status
  source_engine="$ENGINE_HOME"
  FROZEN_BOUND_SOURCE_ENGINE="$source_engine"
  FROZEN_BOUND_SOURCE_BINDING="$(tree_bytes_modes_binding "$source_engine")"
  test_engine="$scratch/$name/test-engine"
  mkdir -p "$test_engine"
  test_engine="$(cd "$test_engine" && pwd -P)"
  FROZEN_OWNED_TEST_ENGINE="$test_engine"
  cp -R "$source_engine/." "$test_engine/"
  chmod u+w "$test_engine/engine"
  mv "$test_engine/engine/evidence-manifest.sh" \
    "$test_engine/engine/evidence-manifest.real.sh"
  cat >"$test_engine/engine/evidence-manifest.sh" <<'EVIDENCE'
#!/usr/bin/env bash
set -euo pipefail
counter="${FROZEN_EVIDENCE_COUNTER:?}"
target_runs="${FROZEN_EVIDENCE_TARGET_RUNS_DIR:?}"
task_id=""; run_dir=""; args=("$@")
for ((index=0; index<${#args[@]}; index++)); do
  case "${args[$index]}" in
    --task-id) [[ $((index + 1)) -lt ${#args[@]} ]] && task_id="${args[$((index + 1))]}" ;;
    --run-dir) [[ $((index + 1)) -lt ${#args[@]} ]] && run_dir="${args[$((index + 1))]}" ;;
  esac
done
real_driver="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence-manifest.real.sh"
if [[ "$task_id" != "TASK-0001" || ! -d "$run_dir" || ! -d "$target_runs" ]]; then
  exec "$real_driver" "$@"
fi
run_dir="$(cd "$run_dir" && pwd -P)"
target_runs="$(cd "$target_runs" && pwd -P)"
[[ "$(dirname "$run_dir")" == "$target_runs" ]] || exec "$real_driver" "$@"
run_binding="${counter}.run-dir"
if [[ -f "$run_binding" ]]; then
  [[ "$(cat "$run_binding")" == "$run_dir" ]] || exec "$real_driver" "$@"
else
  printf '%s\n' "$run_dir" >"$run_binding"
fi
count=0
[[ -f "$counter" ]] && count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
if [[ "$count" -eq 3 || "$count" -eq 4 ]]; then
  echo "injected bounded custom-continuation evidence transport failure" >&2
  exit 77
fi
exec "$real_driver" "$@"
EVIDENCE
  chmod +x "$test_engine/engine/evidence-manifest.sh"
  chmod -R a-w "$test_engine"
  FROZEN_BOUND_TEST_ENGINE="$test_engine"
  FROZEN_BOUND_TEST_BINDING="$(tree_bytes_modes_binding "$test_engine")"
  ENGINE_HOME="$test_engine"
  export FROZEN_EVIDENCE_COUNTER="$scratch/$name/counters/evidence-calls"
  export FROZEN_EVIDENCE_TARGET_RUNS_DIR="$scratch/$name/repo/.singular-state/runs"

  prepare_public_continuation "$name" 1 no custom
  default_worktree="$FIXTURE_ROOT/.worktrees/TASK-0001"
  [[ ! -e "$default_worktree" ]] || fail "$name unexpectedly created the default worktree"
  lease="$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json"
  authorization_id="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["continuationAuthorization"]["authorizationId"])
PY
)"
  owner="reconcile:ORIGIN-CUSTOM:TASK-0001"
  dispatch_run="ORIGIN-CUSTOM"
  generation="$(run_engine success "$BASH_BIN" -c \
    '. "$1"; SCRIPT_DIR="$2"; . "$2/lifecycle.sh"; singular_lifecycle_reserve TASK-0001 "$3" "$4" agent/widget/TASK-0001-frozen widget '\''["internal/widget/"]'\'' "$5" BATCH-CUSTOM "$6"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$ENGINE_HOME/engine" "$owner" \
    "$dispatch_run" "$CONTINUATION_CURRENT_TARGET" "$CONTINUATION_WORKTREE")"
  assert_eq "$generation" "2" "$name exact continuation reservation generation"
  dispatch_log="$scratch/$name/custom-dispatch.log"
  FROZEN_CONTINUATION_EXPECTED=1 run_engine success "$BASH_BIN" \
    "$ENGINE_HOME/engine/dispatch-wrap.sh" TASK-0001 \
    "$ENGINE_HOME/engine/l1-drive.sh" "$owner" "$generation" BATCH-CUSTOM \
    >"$dispatch_log" 2>&1 &
  wrapper_pid=$!
  run_engine success "$BASH_BIN" -c \
    '. "$1"; SCRIPT_DIR="$2"; . "$2/lifecycle.sh"; singular_lifecycle_dispatch_record_write TASK-0001 "$3" "$4" "$(singular_dispatch_pid_start "$4")" "$5" "$6" BATCH-CUSTOM "$7" "$8"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$ENGINE_HOME/engine" "$dispatch_run" \
    "$wrapper_pid" "$dispatch_log" "$CONTINUATION_CURRENT_TARGET" "$owner" "$generation"
  if wait "$wrapper_pid"; then wrapper_rc=0; else wrapper_rc=$?; fi
  assert_eq "$wrapper_rc" "3" "$name initial accepted publication interruption ($(tail -30 "$dispatch_log"))"

  run_id="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["continuationAuthorization"]["executionRunId"])
PY
)"
  run_dir="$FIXTURE_ROOT/.singular-state/runs/$run_id"
  packet="$run_dir/packet.json"
  audit="$run_dir/audit.json"
  assert_file "$packet" "$name accepted continuation packet"
  assert_file "$audit" "$name accepted continuation audit"
  base="$($PYTHON_BIN - "$packet" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["baseRef"])
PY
)"
  head="$($PYTHON_BIN - "$packet" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["headSha"])
PY
)"
  "$PYTHON_BIN" - "$lease" "$packet" "$audit" "$CONTINUATION_WORKTREE" \
      "$authorization_id" "$run_id" "$base" "$head" <<'PY'
import json, os, sys
lease, packet, audit = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:4]]
worktree, authorization, run, base, head = sys.argv[4:]
authority = lease["continuationAuthorization"]
attempt = lease["attemptLifecycle"]
assert packet["status"] == "blocked" and audit["verdict"] == "accepted", (packet, audit)
assert authority["state"] == "claimed", authority
assert authority["authorizationId"] == attempt["continuationAuthorizationId"] == authorization
assert authority["executionRunId"] == packet["runId"] == run
assert authority["candidateBaseSha"] == packet["baseRef"] == base
assert packet["headSha"] == head and head != base
assert os.path.realpath(packet["workspace"]) == os.path.realpath(lease["worktree"]) == os.path.realpath(authority["worktree"]) == os.path.realpath(worktree)
assert authority["additionalWorkerAttemptsClaimed"] == 1
assert authority["additionalWorkerAttemptsRemaining"] == 0
assert authority["predecessorAccounting"]["retryCount"] == lease["retryCount"] == 1
PY
  assert_eq "$(calls worker)" "1" "$name one continuation worker before recovery"
  assert_eq "$(calls auditor)" "1" "$name one continuation audit before recovery"
  assert_eq "$(calls evidence)" "4" "$name bounded interrupted evidence calls"
  [[ ! -e "$default_worktree" ]] || fail "$name interruption created the default worktree"

  printf 'independent custom continuation target\n' >"$FIXTURE_ROOT/custom-target-after.txt"
  git -C "$FIXTURE_ROOT" add custom-target-after.txt
  git -C "$FIXTURE_ROOT" commit -qm 'advance target after accepted custom continuation'
  target_after="$(git -C "$FIXTURE_ROOT" rev-parse target)"
  [[ "$base" != "$head" && "$base" != "$target_after" && "$head" != "$target_after" ]] \
    || fail "$name did not preserve distinct B/H/T"

  continuation_state_digest() {
    {
      shasum -a 256 "$lease" "$packet" "$audit" \
        "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md"
      git -C "$CONTINUATION_WORKTREE" rev-parse HEAD
      git -C "$CONTINUATION_WORKTREE" status --porcelain=v1 -z | shasum -a 256
      { find "$FIXTURE_ROOT/.singular-state/inbox" \
          "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" \
          -type f -print0 2>/dev/null || true; } \
        | sort -z | while IFS= read -r -d '' path; do
          shasum -a 256 "$path"
        done
    } | shasum -a 256 | awk '{print $1}'
  }
  assert_continuation_authority_refusals() {
    local phase="$1" pristine
    local state_before worker_at_start auditor_at_start gate_at_start
    local decider_at_start evidence_at_start rc out mutation
    pristine="$scratch/$name/$phase-lease.json"
    cp "$lease" "$pristine"
    worker_at_start="$(calls worker)"; auditor_at_start="$(calls auditor)"
    gate_at_start="$(calls gate)"; decider_at_start="$(calls decider)"
    evidence_at_start="$(calls evidence)"
    for mutation in missing null list empty; do
      cp "$pristine" "$lease"
      "$PYTHON_BIN" - "$lease" "$mutation" <<'PY'
import json, os, sys
path, mutation = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
if mutation == "missing":
    data.pop("continuationAuthorization", None)
elif mutation == "null":
    data["continuationAuthorization"] = None
elif mutation == "list":
    data["continuationAuthorization"] = []
elif mutation == "empty":
    data["continuationAuthorization"] = {}
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
      state_before="$(continuation_state_digest)"
      rc=0
      out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
      assert_eq "$rc" "3" "$name $phase $mutation authority refusal ($out)"
      assert_eq "$(continuation_state_digest)" "$state_before" \
        "$name $phase $mutation complete retained state"
      assert_eq "$(calls worker)" "$worker_at_start" "$name $phase $mutation worker calls"
      assert_eq "$(calls auditor)" "$auditor_at_start" "$name $phase $mutation auditor calls"
      assert_eq "$(calls gate)" "$gate_at_start" "$name $phase $mutation gate calls"
      assert_eq "$(calls decider)" "$decider_at_start" "$name $phase $mutation decider calls"
      assert_eq "$(calls evidence)" "$evidence_at_start" "$name $phase $mutation evidence calls"
    done
    cp "$pristine" "$lease"
  }

  # The first refusal set proves malformed authority cannot reach evidence
  # recovery while the ordinary/default task worktree is genuinely absent.
  assert_continuation_authority_refusals awaiting-evidence
  [[ ! -e "$default_worktree" ]] || fail "$name refusal created the absent default worktree"

  # Keep a distinct, real default-shaped worktree present for all later
  # publication and duplicate checks. It is a decoy, never the accepted run's
  # retained custom workspace.
  decoy_branch="agent/widget/TASK-0001-default-decoy"
  mkdir -p "$(dirname "$default_worktree")"
  git -C "$FIXTURE_ROOT" worktree add -q -b "$decoy_branch" \
    "$default_worktree" "$target_after"
  decoy_head="$(git -C "$default_worktree" rev-parse HEAD)"
  decoy_status="$(git -C "$default_worktree" status --porcelain=v1 -z | shasum -a 256)"
  assert_default_decoy_unchanged() {
    assert_eq "$(git -C "$default_worktree" branch --show-current)" "$decoy_branch" \
      "$name decoy branch"
    assert_eq "$(git -C "$default_worktree" rev-parse HEAD)" "$decoy_head" \
      "$name decoy head"
    assert_eq "$(git -C "$default_worktree" status --porcelain=v1 -z | shasum -a 256)" \
      "$decoy_status" "$name decoy bytes"
  }

  authority_before="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["continuationAuthorization"]
keys=("authorizationId", "authoritySha256", "state", "executionRunId", "branch", "worktree", "campaignBinding", "candidateBaseSha", "reservationOwner", "reservationGeneration", "reservationRunId", "additionalWorkerAttemptsAuthorized", "additionalWorkerAttemptsClaimed", "additionalWorkerAttemptsRemaining")
lease_keys=("taskId", "runId", "branch", "worktree", "baseSha", "reservationBaseSha", "campaignBinding", "reservationOwner", "reservationGeneration", "reservationRunId")
attempt_keys=("taskId", "runId", "reservationRunId", "reservationOwner", "reservationGeneration", "campaignBinding", "state", "continuationAuthorizationId")
print(json.dumps({"authority":{k:a.get(k) for k in keys}, "lease":{k:d.get(k) for k in lease_keys}, "attempt":{k:d["attemptLifecycle"].get(k) for k in attempt_keys}}, sort_keys=True, separators=(",", ":")))
PY
)"
  accounting_before="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["continuationAuthorization"]
print(json.dumps({"retryCount":d.get("retryCount"), "maxRetries":d.get("maxRetries"), "productPassStarted":d.get("productPassStarted"), "productPassStartedRunId":d.get("productPassStartedRunId"), "predecessorAccounting":a.get("predecessorAccounting")}, sort_keys=True, separators=(",", ":")))
PY
)"
  worker_before="$(calls worker)"; auditor_before="$(calls auditor)"
  gate_before="$(calls gate)"; decider_before="$(calls decider)"; evidence_before="$(calls evidence)"
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "$name retained custom-worktree recovery ($out)"
  assert_contains "$out" "RESUMED ACCEPTED EVIDENCE" "$name explicit accepted recovery"
  assert_eq "$(calls worker)" "$worker_before" "$name recovery worker calls"
  assert_eq "$(calls auditor)" "$auditor_before" "$name recovery auditor calls"
  assert_eq "$(calls gate)" "$gate_before" "$name recovery gate calls"
  assert_eq "$(calls decider)" "$decider_before" "$name recovery decider calls"
  assert_eq "$(calls evidence)" "$((evidence_before + 1))" "$name recovery evidence calls"
  assert_file "$FIXTURE_ROOT/.singular-state/inbox/$run_id.json" "$name accepted publication"
  assert_default_decoy_unchanged

  # Queued duplicate classification must reject the same malformed shapes
  # before its no-op result, without touching the distinct default worktree.
  assert_continuation_authority_refusals queued-duplicate
  assert_default_decoy_unchanged

  evidence_before="$(calls evidence)"; rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "$name duplicate reentry ($out)"
  assert_contains "$out" "already queued/imported; dispatch is a no-op" "$name duplicate no-op"
  assert_eq "$(calls evidence)" "$evidence_before" "$name duplicate evidence calls"
  assert_eq "$(calls worker)" "$worker_before" "$name duplicate worker calls"
  assert_eq "$(calls auditor)" "$auditor_before" "$name duplicate auditor calls"
  assert_eq "$(calls gate)" "$gate_before" "$name duplicate gate calls"
  assert_eq "$(calls decider)" "$decider_before" "$name duplicate decider calls"
  assert_default_decoy_unchanged
  "$PYTHON_BIN" - "$packet" "$base" "$head" "$CONTINUATION_WORKTREE" <<'PY'
import json, os, sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
assert packet["status"] == "accepted", packet
assert packet["baseRef"] == sys.argv[2], packet
assert packet["headSha"] == sys.argv[3], packet
assert os.path.realpath(packet["workspace"]) == os.path.realpath(sys.argv[4]), packet
PY
  assert_eq "$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["continuationAuthorization"]
keys=("authorizationId", "authoritySha256", "state", "executionRunId", "branch", "worktree", "campaignBinding", "candidateBaseSha", "reservationOwner", "reservationGeneration", "reservationRunId", "additionalWorkerAttemptsAuthorized", "additionalWorkerAttemptsClaimed", "additionalWorkerAttemptsRemaining")
lease_keys=("taskId", "runId", "branch", "worktree", "baseSha", "reservationBaseSha", "campaignBinding", "reservationOwner", "reservationGeneration", "reservationRunId")
attempt_keys=("taskId", "runId", "reservationRunId", "reservationOwner", "reservationGeneration", "campaignBinding", "state", "continuationAuthorizationId")
print(json.dumps({"authority":{k:a.get(k) for k in keys}, "lease":{k:d.get(k) for k in lease_keys}, "attempt":{k:d["attemptLifecycle"].get(k) for k in attempt_keys}}, sort_keys=True, separators=(",", ":")))
PY
)" "$authority_before" "$name continuation lease/claim identity preserved"
  assert_eq "$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["continuationAuthorization"]
print(json.dumps({"retryCount":d.get("retryCount"), "maxRetries":d.get("maxRetries"), "productPassStarted":d.get("productPassStarted"), "productPassStartedRunId":d.get("productPassStartedRunId"), "predecessorAccounting":a.get("predecessorAccounting")}, sort_keys=True, separators=(",", ":")))
PY
)" "$accounting_before" "$name continuation accounting preserved"

  reconcile success "$name-import"
  assert_file "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001/$run_id.json" \
    "$name imported continuation packet"
  assert_continuation_authority_refusals imported-duplicate
  assert_default_decoy_unchanged
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "$name imported duplicate ($out)"
  assert_contains "$out" "already queued/imported; dispatch is a no-op" \
    "$name imported duplicate no-op"
  assert_eq "$(calls evidence)" "$evidence_before" "$name imported duplicate evidence calls"
  assert_default_decoy_unchanged

  lease_snapshot="$scratch/$name/accepted-lease.json"
  cp "$lease" "$lease_snapshot"
  for mutation in recorded execution owner attempt attempt-missing allowance; do
    cp "$lease_snapshot" "$lease"
    "$PYTHON_BIN" - "$lease" "$mutation" <<'PY'
import json, os, sys
path, mutation = sys.argv[1:]
d = json.load(open(path, encoding="utf-8")); a = d["continuationAuthorization"]
if mutation == "recorded": a["authorizationId"] = "0" * 64
elif mutation == "execution": a["executionRunId"] = "RUN-MISMATCH"
elif mutation == "owner": a["reservationOwner"] = "reconcile:OTHER:TASK-0001"
elif mutation == "attempt": d["attemptLifecycle"]["continuationAuthorizationId"] = "0" * 64
elif mutation == "attempt-missing": d["attemptLifecycle"].pop("continuationAuthorizationId", None)
elif mutation == "allowance": a["additionalWorkerAttemptsRemaining"] = 1
temporary = path + ".test.tmp"
json.dump(d, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
    rc=0
    out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
    assert_eq "$rc" "3" "$name $mutation provenance refusal ($out)"
    assert_eq "$(calls worker)" "$worker_before" "$name $mutation worker calls"
    assert_eq "$(calls auditor)" "$auditor_before" "$name $mutation auditor calls"
    assert_eq "$(calls gate)" "$gate_before" "$name $mutation gate calls"
    assert_eq "$(calls decider)" "$decider_before" "$name $mutation decider calls"
    assert_eq "$(calls evidence)" "$evidence_before" "$name $mutation evidence calls"
    assert_default_decoy_unchanged
  done
  cp "$lease_snapshot" "$lease"
  unset -f continuation_state_digest assert_continuation_authority_refusals \
    assert_default_decoy_unchanged
  verify_frozen_engine_bindings || fail "$name engine binding failed at test exit"
  unset FROZEN_EVIDENCE_COUNTER FROZEN_EVIDENCE_TARGET_RUNS_DIR
  ENGINE_HOME="$source_engine"
  echo "ok: consumed continuation publishes only from its retained custom workspace"
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

test_context_success() {
  local name=context-success
  make_fixture "$name"
  enable_context_service
  start_campaign success
  reconcile success "$name-first"
  assert_eq "$(calls worker)" "1" "$name worker calls"
  assert_eq "$(calls auditor)" "1" "$name auditor calls"
  reconcile success "$name-reap"
  reconcile success "$name-no-duplicate"
  assert_terminal_contract completed "" accepted
  assert_eq "$(calls worker)" "1" "$name did not redispatch worker"
  assert_eq "$(calls auditor)" "1" "$name did not redispatch auditor"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/runs" \
    "$FIXTURE_ROOT/policy/nested/context.json" "$FIXTURE_ROOT/.worktrees/TASK-0001" \
    "$FIXTURE_ROOT/.singular-state/campaign/manifest.json" <<'PY'
import hashlib, json, pathlib, sys
runs, config, workspace, manifest_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve(), pathlib.Path(sys.argv[3]).resolve(), pathlib.Path(sys.argv[4])
bundles = [json.load(open(path, encoding="utf-8")) for path in runs.glob("*/context-*.bundle.json")]
roles = {bundle["identity"]["role"] for bundle in bundles}
assert {"implementer", "review-target"} <= roles, roles
for bundle in bundles:
    assert pathlib.Path(bundle["policy"]["configPath"]).resolve() == config, bundle
    assert pathlib.Path(bundle["invocation"]["workspace"]).resolve() == workspace, bundle
    assert bundle["invocation"]["campaignBinding"].startswith("campaign:"), bundle
    assert not any("host_invocation_identity" in item.get("reasons", [])
                   for item in bundle["provenance"]), bundle
receipts = [json.load(open(path, encoding="utf-8"))
            for path in runs.glob("*/context-invocation-*.json")]
assert receipts and all(item["status"] == "admitted" for item in receipts), receipts
manifest = json.load(open(manifest_path, encoding="utf-8"))
expected = "sha256:" + hashlib.sha256(json.dumps(
    manifest["configuration"]["resolvedSettings"], sort_keys=True,
    separators=(",", ":"),
).encode()).hexdigest()
assert all(item["policy"]["resolvedPolicySha256"] == expected for item in receipts), receipts
events = [json.loads(line) for line in (runs.parent / "events.ndjson").read_text().splitlines()]
context_events = [item for item in events if item.get("type") == "context.bundle_selected"]
assert context_events, events
assert all(item["data"]["policy"]["resolvedPolicySha256"] == expected
           for item in context_events), context_events
PY
  echo "ok: enabled frozen context uses selected nested policy, explicit worker workspace, and frozen receipt identity"
}

test_missing_context_policy_refuses_campaign_start() {
  local name=context-missing-policy
  make_fixture "$name"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data.setdefault("env", {})["SINGULAR_CONTEXT_CONFIG_FILE"] = "policy/missing.json"
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
  git -C "$FIXTURE_ROOT" add singular.config.json
  git -C "$FIXTURE_ROOT" commit -qm 'select missing context policy'
  if run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/campaign.sh" start \
      --id frozen-context-missing >"$scratch/$name.log" 2>&1; then
    fail "$name campaign silently treated missing selected policy as disabled"
  fi
  [[ ! -e "$FIXTURE_ROOT/.singular-state/campaign/manifest.json" ]] \
    || fail "$name published a campaign manifest"
  echo "ok: already-missing selected context policy refuses campaign creation"
}

test_context_infra_exhaustion() {
  local name=context-infra
  make_fixture "$name"
  enable_context_service
  start_campaign infra
  reconcile infra "$name-first"
  assert_eq "$(calls worker)" "2" "$name bounded worker calls"
  assert_eq "$(calls auditor)" "0" "$name auditor calls"
  set_task_ready
  reconcile infra "$name-reap"
  reconcile infra "$name-no-duplicate"
  assert_eq "$(calls worker)" "2" "$name restart did not redispatch"
  assert_eq "$(calls auditor)" "0" "$name restart did not audit"
  assert_terminal_contract blocked worker-infra escalate-infra
  echo "ok: enabled frozen context preserves bounded infra terminal handling"
}

test_accepted_recovery_after_independent_target_advance() {
  local name=accepted-recovery source_engine test_engine entry
  local run_id run_dir packet audit lease worktree base head target_after
  local packet_before audit_before lease_before task_before
  local worker_before auditor_before gate_before decider_before evidence_before retry_before
  local out rc=0 inbox_count
  source_engine="$ENGINE_HOME"
  FROZEN_BOUND_SOURCE_ENGINE="$source_engine"
  FROZEN_BOUND_SOURCE_BINDING="$(tree_bytes_modes_binding "$source_engine")"
  make_fixture "$name"

  # This test engine is complete, immutable, and selected before campaign
  # creation. Only its evidence driver is a deterministic transport-failure
  # wrapper; every production consumer and the Unix evidence broker remain real.
  test_engine="$scratch/$name/test-engine"
  mkdir -p "$test_engine"
  test_engine="$(cd "$test_engine" && pwd -P)"
  "$PYTHON_BIN" - "$source_engine" "$test_engine" "$scratch/$name" "$scratch" <<'PY'
import pathlib, sys
source, copied, owner, scratch = [pathlib.Path(item).resolve(strict=True)
                                  for item in sys.argv[1:]]
assert source != copied, (source, copied)
assert not copied.is_relative_to(source), (source, copied)
assert not source.is_relative_to(copied), (source, copied)
assert copied.parent == owner, (copied, owner)
assert copied.is_relative_to(scratch), (copied, scratch)
PY
  FROZEN_OWNED_TEST_ENGINE="$test_engine"
  cp -R "$source_engine/." "$test_engine/"
  chmod u+w "$test_engine/engine"
  mv "$test_engine/engine/evidence-manifest.sh" \
    "$test_engine/engine/evidence-manifest.real.sh"
  cat >"$test_engine/engine/evidence-manifest.sh" <<'EVIDENCE'
#!/usr/bin/env bash
set -euo pipefail
counter="${FROZEN_EVIDENCE_COUNTER:?}"
target_runs="${FROZEN_EVIDENCE_TARGET_RUNS_DIR:?}"
task_id=""
run_dir=""
args=("$@")
for ((index=0; index<${#args[@]}; index++)); do
  case "${args[$index]}" in
    --task-id)
      [[ $((index + 1)) -lt ${#args[@]} ]] && task_id="${args[$((index + 1))]}"
      ;;
    --run-dir)
      [[ $((index + 1)) -lt ${#args[@]} ]] && run_dir="${args[$((index + 1))]}"
      ;;
  esac
done
real_driver="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence-manifest.real.sh"
if [[ "$task_id" != "TASK-0001" || ! -d "$run_dir" || ! -d "$target_runs" ]]; then
  exec "$real_driver" "$@"
fi
run_dir="$(cd "$run_dir" && pwd -P)"
target_runs="$(cd "$target_runs" && pwd -P)"
if [[ "$(dirname "$run_dir")" != "$target_runs" ]]; then
  exec "$real_driver" "$@"
fi
run_binding="${counter}.run-dir"
if [[ -f "$run_binding" ]]; then
  [[ "$(cat "$run_binding")" == "$run_dir" ]] || exec "$real_driver" "$@"
else
  printf '%s\n' "$run_dir" >"$run_binding"
fi
count=0
[[ -f "$counter" ]] && count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
if [[ "$count" -eq 3 || "$count" -eq 4 ]]; then
  echo "injected bounded post-accept evidence transport failure" >&2
  exit 77
fi
exec "$real_driver" "$@"
EVIDENCE
  chmod +x "$test_engine/engine/evidence-manifest.sh"
  chmod -R a-w "$test_engine"
  "$PYTHON_BIN" - "$test_engine" <<'PY'
import os, stat, sys
for current, directories, files in os.walk(sys.argv[1], followlinks=False):
    for path in [current, *(os.path.join(current, item)
                            for item in directories + files)]:
        assert not stat.S_IMODE(os.lstat(path).st_mode) & 0o222, path
PY
  FROZEN_BOUND_TEST_ENGINE="$test_engine"
  FROZEN_BOUND_TEST_BINDING="$(tree_bytes_modes_binding "$test_engine")"
  verify_frozen_engine_bindings || fail "$name engine binding failed before campaign start"
  ENGINE_HOME="$test_engine"
  export FROZEN_EVIDENCE_COUNTER="$FIXTURE_COUNTERS/evidence-calls"
  export FROZEN_EVIDENCE_TARGET_RUNS_DIR="$FIXTURE_ROOT/.singular-state/runs"

  start_campaign success
  assert_eq "$(calls evidence)" "0" "$name canary did not consume target evidence failures"
  reconcile success "$name-awaiting-evidence"
  lease="$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json"
  run_id="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["runId"])
PY
)"
  run_dir="$FIXTURE_ROOT/.singular-state/runs/$run_id"
  packet="$run_dir/packet.json"
  audit="$run_dir/audit.json"
  worktree="$FIXTURE_ROOT/.worktrees/TASK-0001"
  assert_file "$packet" "$name accepted checkpoint packet"
  assert_file "$audit" "$name accepted audit"
  base="$($PYTHON_BIN - "$packet" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["baseRef"])
PY
)"
  head="$($PYTHON_BIN - "$packet" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["headSha"])
PY
)"
  "$PYTHON_BIN" - "$packet" "$audit" "$lease" "$base" "$head" <<'PY'
import json, sys
packet, audit, lease = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:4]]
base, head = sys.argv[4:]
assert packet["status"] == "blocked", packet
assert audit["verdict"] == "accepted", audit
assert lease["status"] == "blocked", lease
assert packet["baseRef"] == lease["baseSha"] == base, (packet, lease)
assert packet["headSha"] == head, packet
assert any(item.get("reason") == "awaiting-evidence" and
           item.get("productAuditVerdict") == "accepted"
           for item in packet["blockers"]), packet
PY
  assert_eq "$(calls worker)" "1" "$name initial worker calls"
  assert_eq "$(calls auditor)" "1" "$name initial auditor calls"
  assert_eq "$(calls decider)" "0" "$name initial decider calls"
  assert_eq "$(calls evidence)" "4" "$name bounded evidence failure calls"

  # Advance only the consumer's target from B to independent T. The accepted
  # branch/worktree stay at H and the task's dirty blocked status is not added.
  printf 'independent target T\n' >"$FIXTURE_ROOT/independent-target.txt"
  git -C "$FIXTURE_ROOT" add independent-target.txt
  git -C "$FIXTURE_ROOT" commit -qm 'advance target independently after accepted H'
  target_after="$(git -C "$FIXTURE_ROOT" rev-parse target)"
  [[ "$base" != "$head" && "$base" != "$target_after" && "$head" != "$target_after" ]] \
    || fail "$name did not keep B, H, and T distinct"
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor "$base" "$head" \
    || fail "$name accepted candidate lost B->H ancestry"
  if git -C "$FIXTURE_ROOT" merge-base --is-ancestor "$target_after" "$head"; then
    fail "$name independent target T unexpectedly precedes H"
  fi

  # Freeze the producer's exact accepted packet and exercise interruptions
  # after packet publication and after lease publication. The third boundary,
  # after inbox publication, is the duplicate call below.
  local boundary boundary_packet boundary_lease boundary_task boundary_packet_sha
  local boundary_evidence_before
  boundary_packet="$scratch/$name/boundary-packet.json"
  boundary_lease="$scratch/$name/boundary-lease.json"
  boundary_task="$scratch/$name/boundary-task.md"
  cp "$packet" "$boundary_packet"
  cp "$lease" "$boundary_lease"
  cp "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" "$boundary_task"
  blocked_state_digest() {
    shasum -a 256 "$packet" "$audit" "$lease" \
      "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" \
      | shasum -a 256 | awk '{print $1}'
  }
  local malformed_digest
  printf '{not-json\n' >"$packet"
  malformed_digest="$(blocked_state_digest)"
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "$name invalid retained JSON refusal ($out)"
  assert_eq "$(blocked_state_digest)" "$malformed_digest" \
    "$name invalid retained JSON preserved"
  assert_eq "$(calls worker)" "1" "$name invalid retained JSON worker calls"
  assert_eq "$(calls auditor)" "1" "$name invalid retained JSON auditor calls"
  assert_eq "$(calls evidence)" "4" "$name invalid retained JSON evidence calls"
  cp "$boundary_packet" "$packet"
  "$PYTHON_BIN" - "$packet" <<'PY'
import json, os, sys
path=sys.argv[1]; data=json.load(open(path, encoding="utf-8"))
data["blockers"]=None
temporary=path+".test.tmp"
json.dump(data, open(temporary,"w",encoding="utf-8"), indent=2)
open(temporary,"a",encoding="utf-8").write("\n")
os.replace(temporary,path)
PY
  malformed_digest="$(blocked_state_digest)"
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "$name null-blockers retained refusal ($out)"
  assert_eq "$(blocked_state_digest)" "$malformed_digest" \
    "$name null-blockers retained state preserved"
  assert_eq "$(calls worker)" "1" "$name null-blockers worker calls"
  assert_eq "$(calls auditor)" "1" "$name null-blockers auditor calls"
  assert_eq "$(calls evidence)" "4" "$name null-blockers evidence calls"
  cp "$boundary_packet" "$packet"
  "$test_engine/engine/evidence-manifest.real.sh" --run-dir "$run_dir" \
    --task-id TASK-0001 --worktree "$worktree" --base-ref "$base" \
    --head-sha "$head" >/dev/null
  "$PYTHON_BIN" - "$packet" "$head" <<'PY'
import json, os, sys
path, head = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["blockers"] = [item for item in data["blockers"]
                    if not (isinstance(item, dict)
                            and item.get("reason") == "awaiting-evidence"
                            and item.get("headSha") == head)]
data["status"] = "accepted"
data["nextAction"] = "import into control state and reconcile"
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  boundary_packet_sha="$(shasum -a 256 "$packet" | awk '{print $1}')"
  boundary_evidence_before="$(calls evidence)"
  for boundary in packet lease; do
    cp "$boundary_lease" "$lease"
    cp "$boundary_task" "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md"
    if [[ "$boundary" == "lease" ]]; then
      "$PYTHON_BIN" - "$lease" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["status"] = "accepted"
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
    fi
    rc=0
    out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
    assert_eq "$rc" "0" "$name $boundary publication-boundary recovery ($out)"
    assert_eq "$(shasum -a 256 "$packet" | awk '{print $1}')" "$boundary_packet_sha" \
      "$name $boundary boundary preserves accepted packet bytes"
    assert_eq "$(calls worker)" "1" "$name $boundary boundary worker calls"
    assert_eq "$(calls auditor)" "1" "$name $boundary boundary auditor calls"
    assert_eq "$(calls evidence)" "$boundary_evidence_before" \
      "$name $boundary boundary evidence calls"
    assert_file "$FIXTURE_ROOT/.singular-state/inbox/$run_id.json" \
      "$name $boundary boundary publication"
    unlink "$FIXTURE_ROOT/.singular-state/inbox/$run_id.json"
  done
  cp "$boundary_packet" "$packet"
  cp "$boundary_lease" "$lease"
  cp "$boundary_task" "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md"

  # Put the accepted lease at its repair ceiling. Evidence-only recovery is a
  # terminal continuation and must precede this fresh-work budget guard.
  "$PYTHON_BIN" - "$lease" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["retryCount"] = data["maxRetries"]
data["productPassStarted"] = True
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  packet_before="$(shasum -a 256 "$packet" | awk '{print $1}')"
  audit_before="$(shasum -a 256 "$audit" | awk '{print $1}')"
  lease_before="$(shasum -a 256 "$lease" | awk '{print $1}')"
  task_before="$(shasum -a 256 "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" | awk '{print $1}')"
  worker_before="$(calls worker)"
  auditor_before="$(calls auditor)"
  gate_before="$(calls gate)"
  decider_before="$(calls decider)"
  evidence_before="$(calls evidence)"
  retry_before="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["retryCount"])
PY
)"

  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "$name public L1 recovery after target advance ($out)"
  assert_contains "$out" "RESUMED ACCEPTED EVIDENCE" "$name explicit recovery outcome"
  assert_eq "$(calls worker)" "$worker_before" "$name recovery worker debit"
  assert_eq "$(calls auditor)" "$auditor_before" "$name recovery auditor debit"
  assert_eq "$(calls gate)" "$gate_before" "$name recovery gate call"
  assert_eq "$(calls decider)" "$decider_before" "$name recovery decider call"
  assert_eq "$(calls evidence)" "$((evidence_before + 1))" "$name evidence-only recovery call"
  assert_eq "$(shasum -a 256 "$audit" | awk '{print $1}')" "$audit_before" \
    "$name accepted audit remains byte-identical"
  assert_eq "$(git -C "$worktree" rev-parse HEAD)" "$head" "$name worktree H preserved"
  assert_eq "$(git -C "$FIXTURE_ROOT" rev-parse agent/widget/TASK-0001-frozen)" "$head" \
    "$name branch H preserved"
  "$PYTHON_BIN" - "$packet" "$lease" "$base" "$head" "$retry_before" <<'PY'
import json, sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
lease = json.load(open(sys.argv[2], encoding="utf-8"))
base, head, retry = sys.argv[3:]
assert packet["status"] == "accepted", packet
assert packet["baseRef"] == lease["baseSha"] == base, (packet, lease)
assert packet["headSha"] == head, packet
assert lease["retryCount"] == int(retry), lease
PY
  assert_file "$FIXTURE_ROOT/.singular-state/inbox/$run_id.json" "$name one accepted publication"

  # With the repair ceiling still exhausted, a duplicate public call must reach
  # the established queued/imported no-op before any gate, decider, or provider.
  local packet_after_resume
  packet_after_resume="$(shasum -a 256 "$packet" | awk '{print $1}')"
  evidence_before="$(calls evidence)"
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "$name duplicate public L1 call ($out)"
  assert_contains "$out" "already queued/imported; dispatch is a no-op" \
    "$name duplicate reaches existing no-op"
  assert_eq "$(calls worker)" "$worker_before" "$name duplicate worker calls"
  assert_eq "$(calls auditor)" "$auditor_before" "$name duplicate auditor calls"
  assert_eq "$(calls gate)" "$gate_before" "$name duplicate gate calls"
  assert_eq "$(calls decider)" "$decider_before" "$name duplicate decider calls"
  assert_eq "$(calls evidence)" "$evidence_before" "$name duplicate evidence calls"
  assert_eq "$(shasum -a 256 "$packet" | awk '{print $1}')" "$packet_after_resume" \
    "$name duplicate packet bytes"
  assert_eq "$(shasum -a 256 "$audit" | awk '{print $1}')" "$audit_before" \
    "$name duplicate audit bytes"
  assert_eq "$(git -C "$worktree" rev-parse HEAD)" "$head" "$name duplicate worktree H"
  inbox_count="$(find "$FIXTURE_ROOT/.singular-state/inbox" -maxdepth 1 \
    -name '*.json' -type f | wc -l | tr -d '[:space:]')"
  assert_eq "$inbox_count" "1" "$name exactly one queued publication"
  "$PYTHON_BIN" - "$lease" "$base" "$retry_before" <<'PY'
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
assert lease["baseSha"] == sys.argv[2], lease
assert lease["retryCount"] == int(sys.argv[3]), lease
PY

  # Duplicate evidence is authoritative only after the canonical packet,
  # audit, campaign, and exact queued/imported artifact all validate.
  local publishable_packet publishable_audit retained_digest_before imported_dir
  publishable_packet="$scratch/$name/publishable-packet.json"
  publishable_audit="$scratch/$name/publishable-audit.json"
  imported_dir="$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001"
  cp "$packet" "$publishable_packet"
  cp "$audit" "$publishable_audit"
  accepted_state_digest() {
    shasum -a 256 "$packet" "$audit" "$lease" \
      "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" \
      | shasum -a 256 | awk '{print $1}'
  }
  assert_retained_refusal_quiet() {
    local label="$1"
    assert_eq "$(calls worker)" "$worker_before" "$label worker calls"
    assert_eq "$(calls auditor)" "$auditor_before" "$label auditor calls"
    assert_eq "$(calls gate)" "$gate_before" "$label gate calls"
    assert_eq "$(calls decider)" "$decider_before" "$label decider calls"
    assert_eq "$(calls evidence)" "$evidence_before" "$label evidence calls"
  }

  # Directory ownership is segment-aware, not a string prefix. A neighboring
  # name and a traversal-shaped packet path must both fail before duplicate
  # publication can borrow the retained accepted audit.
  local escaped_path
  for escaped_path in internal/widget-neighbor/escape.go internal/widget/../escape.go; do
    "$PYTHON_BIN" - "$packet" "$escaped_path" <<'PY'
import json, os, sys
path, changed = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["changedFiles"] = [changed]
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
    retained_digest_before="$(accepted_state_digest)"
    rc=0
    out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
    assert_eq "$rc" "3" "$name changed-path scope refusal for $escaped_path ($out)"
    assert_eq "$(accepted_state_digest)" "$retained_digest_before" \
      "$name changed-path scope state for $escaped_path"
    assert_retained_refusal_quiet "$name changed-path scope $escaped_path"
    cp "$publishable_packet" "$packet"
  done

  # Task preflight intentionally disallows overlapping declarations, so prove
  # forbidden precedence directly at the shared admission/publication leaf.
  # This is the otherwise unreachable malicious-packet shape: the path matches
  # both declarations and must be classified forbidden, never merely allowed.
  "$PYTHON_BIN" - "$ENGINE_HOME/engine" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from git_changes import scope_membership
forbidden, disallowed = scope_membership(
    ["internal/widget/private/secret.txt"],
    ["internal/widget/"],
    ["internal/widget/private/"],
)
assert forbidden == ["internal/widget/private/secret.txt"], forbidden
assert disallowed == [], disallowed
PY

  "$PYTHON_BIN" - "$packet" "$FIXTURE_ROOT/.singular-state/inbox/$run_id.json" <<'PY'
import json, os, sys
for path in sys.argv[1:]:
    data=json.load(open(path, encoding="utf-8"))
    data["schema"]="singular.orchestration.state-packet.invalid"
    temporary=path+".test.tmp"
    json.dump(data, open(temporary,"w",encoding="utf-8"), indent=2)
    open(temporary,"a",encoding="utf-8").write("\n")
    os.replace(temporary,path)
PY
  retained_digest_before="$(accepted_state_digest)"
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "$name schema-broken duplicate refusal ($out)"
  assert_eq "$(accepted_state_digest)" "$retained_digest_before" \
    "$name schema-broken retained state"
  assert_retained_refusal_quiet "$name schema-broken"
  cp "$publishable_packet" "$packet"
  cp "$publishable_packet" "$FIXTURE_ROOT/.singular-state/inbox/$run_id.json"

  "$PYTHON_BIN" - "$packet" "$FIXTURE_ROOT/.singular-state/inbox/$run_id.json" <<'PY'
import json, os, sys
for path in sys.argv[1:]:
    data=json.load(open(path, encoding="utf-8"))
    for item in data["evidence"]:
        if item.get("kind") == "campaign-binding":
            item["ref"]="campaign:stale-fixture"
    temporary=path+".test.tmp"
    json.dump(data, open(temporary,"w",encoding="utf-8"), indent=2)
    open(temporary,"a",encoding="utf-8").write("\n")
    os.replace(temporary,path)
PY
  retained_digest_before="$(accepted_state_digest)"
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "$name old-campaign duplicate refusal ($out)"
  assert_eq "$(accepted_state_digest)" "$retained_digest_before" \
    "$name old-campaign retained state"
  assert_retained_refusal_quiet "$name old-campaign"
  cp "$publishable_packet" "$packet"
  cp "$publishable_packet" "$FIXTURE_ROOT/.singular-state/inbox/$run_id.json"

  "$PYTHON_BIN" - "$audit" <<'PY'
import json, os, sys
path=sys.argv[1]; data=json.load(open(path, encoding="utf-8"))
data["runId"]="RUN-MISMATCHED-AUDIT"
temporary=path+".test.tmp"
json.dump(data, open(temporary,"w",encoding="utf-8"), indent=2)
open(temporary,"a",encoding="utf-8").write("\n")
os.replace(temporary,path)
PY
  retained_digest_before="$(accepted_state_digest)"
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "$name mismatched-audit duplicate refusal ($out)"
  assert_eq "$(accepted_state_digest)" "$retained_digest_before" \
    "$name mismatched-audit retained state"
  assert_retained_refusal_quiet "$name mismatched-audit"
  cp "$publishable_audit" "$audit"

  mkdir -p "$imported_dir"
  printf '{"unrelated":true}\n' >"$imported_dir/RUN-UNRELATED.json"
  retained_digest_before="$(accepted_state_digest)"
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "$name unrelated-import duplicate refusal ($out)"
  assert_eq "$(accepted_state_digest)" "$retained_digest_before" \
    "$name unrelated-import retained state"
  assert_retained_refusal_quiet "$name unrelated-import"
  unlink "$imported_dir/RUN-UNRELATED.json"

  # The initial checkpoint hashes prove this fixture recovered the same durable
  # authority rather than manufacturing a new verdict or candidate. Only the
  # packet's blocked->accepted transition and lease/task statuses may change.
  [[ "$packet_before" != "$packet_after_resume" ]] \
    || fail "$name packet did not perform blocked-to-accepted transition"
  [[ "$lease_before" != "$(shasum -a 256 "$lease" | awk '{print $1}')" ]] \
    || fail "$name lease did not perform blocked-to-accepted transition"
  [[ "$task_before" != "$(shasum -a 256 "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" | awk '{print $1}')" ]] \
    || fail "$name task did not perform blocked-to-accepted transition"

  verify_frozen_engine_bindings || fail "$name engine binding failed at test exit"
  unset FROZEN_EVIDENCE_COUNTER FROZEN_EVIDENCE_TARGET_RUNS_DIR
  ENGINE_HOME="$source_engine"
  echo "ok: frozen accepted B->H recovers once after independent T and remains idempotent"
}

prepare_native_repair() {
  local name="$1" with_dependent="${2:-no}"
  make_fixture "$name"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import sys
p=sys.argv[1]; text=open(p, encoding="utf-8").read()
text=text.replace("Area: widget\n", "Area: widget\nRisk tier: high\n", 1)
open(p, "w", encoding="utf-8").write(text)
PY
  : >"$FIXTURE_ROOT/.frozen-repair-case"
  if [[ "$with_dependent" == "yes" ]]; then
    cat >"$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0002.md" <<'TASK'
# TASK-0002: Frozen dependent fixture

Status: ready
Area: followup
Target branch: `target`
Worker branch: `agent/followup/TASK-0002-frozen`
Test policy: `strict_test_first`
Gate command: `bash strict-gate.sh`
Dispatch mode: canonical
Depends on: [TASK-0001]

## Objective

Exercise the first native reservation after exact predecessor integration.

## Scope

Owned files:

- `internal/followup/`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The dependent fixture receives the integrated target as its reservation base.
TASK
  fi
  git -C "$FIXTURE_ROOT" add .frozen-repair-case docs/orchestration/tasks/TASK-0001.md
  if [[ "$with_dependent" == "yes" ]]; then
    git -C "$FIXTURE_ROOT" add docs/orchestration/tasks/TASK-0002.md
  fi
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

prepare_continued_native_repair() {
  local name="$1" lease owner generation dispatch_run dispatch_log wrapper_pid wrapper_rc=0
  prepare_public_continuation "$name" 1 no custom 2 yes
  lease="$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json"
  owner="reconcile:ORIGIN-CONTINUED-REPAIR:TASK-0001"
  dispatch_run="ORIGIN-CONTINUED-REPAIR"
  generation="$(run_engine success "$BASH_BIN" -c \
    '. "$1"; SCRIPT_DIR="$2"; . "$2/lifecycle.sh"; singular_lifecycle_reserve TASK-0001 "$3" "$4" agent/widget/TASK-0001-frozen widget '\''["internal/widget/"]'\'' "$5" BATCH-CONTINUED-REPAIR "$6"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$ENGINE_HOME/engine" "$owner" \
    "$dispatch_run" "$CONTINUATION_CURRENT_TARGET" "$CONTINUATION_WORKTREE")"
  assert_eq "$generation" "2" "$name continued predecessor reservation generation"
  dispatch_log="$scratch/$name/continued-predecessor-dispatch.log"
  FROZEN_CONTINUATION_EXPECTED=1 run_engine success "$BASH_BIN" \
    "$ENGINE_HOME/engine/dispatch-wrap.sh" TASK-0001 \
    "$ENGINE_HOME/engine/l1-drive.sh" "$owner" "$generation" \
    BATCH-CONTINUED-REPAIR >"$dispatch_log" 2>&1 &
  wrapper_pid=$!
  run_engine success "$BASH_BIN" -c \
    '. "$1"; SCRIPT_DIR="$2"; . "$2/lifecycle.sh"; singular_lifecycle_dispatch_record_write TASK-0001 "$3" "$4" "$(singular_dispatch_pid_start "$4")" "$5" "$6" BATCH-CONTINUED-REPAIR "$7" "$8"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$ENGINE_HOME/engine" "$dispatch_run" \
    "$wrapper_pid" "$dispatch_log" "$CONTINUATION_CURRENT_TARGET" "$owner" "$generation"
  if wait "$wrapper_pid"; then wrapper_rc=0; else wrapper_rc=$?; fi
  assert_eq "$wrapper_rc" "0" \
    "$name continued predecessor accepted publication ($(tail -30 "$dispatch_log"))"

  PREDECESSOR_RUN="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["continuationAuthorization"]
assert d["retryCount"] == 1 and d["maxRetries"] == 2, d
assert a["predecessorAccounting"]["retryCount"] == 1, a
assert a["predecessorAccounting"]["maxRetries"] == 2, a
assert a["state"] == "claimed" and a["additionalWorkerAttemptsRemaining"] == 0, a
assert d["attemptLifecycle"]["continuationAuthorizationId"] == a["authorizationId"], d
print(a["executionRunId"])
PY
)"
  assert_file "$FIXTURE_ROOT/.singular-state/inbox/$PREDECESSOR_RUN.json" \
    "$name continued predecessor publication"
  reconcile success "$name-predecessor-import"
  PREDECESSOR_ATTEMPT_SHA="$(shasum -a 256 "$lease" | awk '{print $1}')"

  local rc=0
  run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0001 --run-id "$name-integration-red" \
    >"$scratch/$name-integration-red.log" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "$name continued predecessor unexpectedly integrated"
  REPAIR_FAILURE_ID="$($PYTHON_BIN - "$lease" "$PREDECESSOR_RUN" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); c=d["acceptedCandidate"]
assert c["runId"] == sys.argv[2] and c["state"] == "integration-failed", d
assert c["failures"][-1]["domain"] == "product", c
assert d["retryCount"] == 1 and d["maxRetries"] == 2, d
assert d["continuationAuthorization"]["executionRunId"] == sys.argv[2], d
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
    repair-dispatch-eligible --lease "$lease" \
    --task-contract "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" >/dev/null \
    || fail "$name public continued-predecessor repair was absent from the scheduler frontier"
  "$PYTHON_BIN" - "$lease" "$PREDECESSOR_RUN" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); c=d["continuationAuthorization"]
r=d["recoveryAuthorization"]
assert c["executionRunId"] == r["predecessorRunId"] == sys.argv[2], d
assert r["successorRunId"] != c["executionRunId"], d
assert d["retryCount"] == 1 and d["maxRetries"] == 2, d
assert c["predecessorAccounting"]["retryCount"] == 1, c
PY
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

test_native_repair_accepted_publication() {
  local name=repair-accepted-publication source_engine test_engine lease run_dir packet audit
  local base head target_after integration_target_before out rc=0 worker_before auditor_before gate_before
  local decider_before evidence_before packet_after claim_before claim_after accounting_before
  source_engine="$ENGINE_HOME"
  FROZEN_BOUND_SOURCE_ENGINE="$source_engine"
  FROZEN_BOUND_SOURCE_BINDING="$(tree_bytes_modes_binding "$source_engine")"
  test_engine="$scratch/$name/test-engine"
  mkdir -p "$test_engine"
  test_engine="$(cd "$test_engine" && pwd -P)"
  FROZEN_OWNED_TEST_ENGINE="$test_engine"
  cp -R "$source_engine/." "$test_engine/"
  chmod u+w "$test_engine/engine"
  mv "$test_engine/engine/evidence-manifest.sh" \
    "$test_engine/engine/evidence-manifest.real.sh"
  cat >"$test_engine/engine/evidence-manifest.sh" <<'EVIDENCE'
#!/usr/bin/env bash
set -euo pipefail
counter="${FROZEN_EVIDENCE_COUNTER:?}"
target_runs="${FROZEN_EVIDENCE_TARGET_RUNS_DIR:?}"
target_run_id="${FROZEN_EVIDENCE_TARGET_RUN_ID:?}"
task_id=""
run_dir=""
args=("$@")
for ((index=0; index<${#args[@]}; index++)); do
  case "${args[$index]}" in
    --task-id)
      [[ $((index + 1)) -lt ${#args[@]} ]] && task_id="${args[$((index + 1))]}"
      ;;
    --run-dir)
      [[ $((index + 1)) -lt ${#args[@]} ]] && run_dir="${args[$((index + 1))]}"
      ;;
  esac
done
real_driver="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence-manifest.real.sh"
if [[ "$task_id" != "TASK-0001" || ! -d "$run_dir" || ! -d "$target_runs" ]]; then
  exec "$real_driver" "$@"
fi
run_dir="$(cd "$run_dir" && pwd -P)"
target_runs="$(cd "$target_runs" && pwd -P)"
if [[ "$(dirname "$run_dir")" != "$target_runs" || "$(basename "$run_dir")" != "$target_run_id" ]]; then
  exec "$real_driver" "$@"
fi
count=0
[[ -f "$counter" ]] && count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
if [[ "$count" -eq 3 || "$count" -eq 4 ]]; then
  echo "injected bounded repair-successor evidence transport failure" >&2
  exit 77
fi
exec "$real_driver" "$@"
EVIDENCE
  chmod +x "$test_engine/engine/evidence-manifest.sh"
  chmod -R a-w "$test_engine"
  FROZEN_BOUND_TEST_ENGINE="$test_engine"
  FROZEN_BOUND_TEST_BINDING="$(tree_bytes_modes_binding "$test_engine")"
  verify_frozen_engine_bindings || fail "$name engine binding failed before campaign start"
  ENGINE_HOME="$test_engine"
  export FROZEN_EVIDENCE_COUNTER="$scratch/$name/counters/evidence-calls"
  export FROZEN_EVIDENCE_TARGET_RUNS_DIR="$scratch/$name/repo/.singular-state/runs"
  export FROZEN_EVIDENCE_TARGET_RUN_ID="RUN-$name-SUCCESSOR"

  prepare_continued_native_repair "$name"
  assert_eq "$(calls evidence)" "0" \
    "$name canary and predecessor did not consume successor evidence failures"
  reconcile success "$name-successor-awaiting-publication"
  lease="$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json"
  run_dir="$FIXTURE_ROOT/.singular-state/runs/$REPAIR_RUN"
  packet="$run_dir/packet.json"
  audit="$run_dir/audit.json"
  assert_file "$packet" "$name repair successor packet"
  assert_file "$audit" "$name repair successor audit"
  base="$($PYTHON_BIN - "$packet" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["baseRef"])
PY
)"
  head="$($PYTHON_BIN - "$packet" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["headSha"])
PY
)"
  "$PYTHON_BIN" - "$packet" "$audit" "$lease" "$REPAIR_RUN" \
      "$REPAIR_BRANCH" "$REPAIR_WORKTREE" "$base" "$head" <<'PY'
import json, os, sys
packet, audit, lease = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:4]]
run, branch, worktree, base, head = sys.argv[4:]
authority = lease["recoveryAuthorization"]
continuation = lease["continuationAuthorization"]
assert packet["status"] == "blocked" and audit["verdict"] == "accepted", (packet, audit)
assert lease["status"] == "blocked" and authority["state"] == "claimed", lease
assert packet["runId"] == lease["runId"] == authority["successorRunId"] == run, lease
assert packet["branch"] == lease["branch"] == authority["successorBranch"] == branch, lease
assert os.path.realpath(packet["workspace"]) == os.path.realpath(lease["worktree"]) == os.path.realpath(authority["successorWorktree"]) == os.path.realpath(worktree), lease
assert packet["baseRef"] == lease["baseSha"] == authority["predecessorHeadSha"] == base, lease
assert packet["headSha"] == head and head != base, packet
assert lease["retryCount"] == lease["maxRetries"] == 2, lease
assert continuation["predecessorAccounting"]["retryCount"] == 1, continuation
assert continuation["predecessorAccounting"]["maxRetries"] == 2, continuation
assert continuation["executionRunId"] == authority["predecessorRunId"], lease
assert all("continuationAuthorizationId" not in x for x in [lease["attemptLifecycle"]]), lease
historical = [x for x in lease["attemptHistory"] if x.get("runId") == authority["predecessorRunId"]]
assert len(historical) == 1, lease
assert historical[0]["continuationAuthorizationId"] == continuation["authorizationId"], lease
PY

  printf 'independent target after accepted repair\n' >"$FIXTURE_ROOT/repair-target-after.txt"
  git -C "$FIXTURE_ROOT" add repair-target-after.txt
  git -C "$FIXTURE_ROOT" commit -qm 'advance target after accepted repair successor'
  target_after="$(git -C "$FIXTURE_ROOT" rev-parse target)"
  [[ "$target_after" != "$base" && "$target_after" != "$head" ]] \
    || fail "$name did not preserve distinct repair B/H/T"
  if git -C "$FIXTURE_ROOT" merge-base --is-ancestor "$target_after" "$head"; then
    fail "$name independent repair target unexpectedly precedes successor"
  fi

  claim_before="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["recoveryAuthorization"]
print("|".join(str(a.get(k, "")) for k in ("authorizationId", "claimId", "reservationOwner", "reservationGeneration", "reservationRunId", "successorRunId", "successorBranch", "successorWorktree", "predecessorHeadSha")))
PY
)"
  accounting_before="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps({"retryCount":d.get("retryCount"), "failureBudgets":d.get("failureBudgets"), "failureLimits":d.get("failureLimits")}, sort_keys=True, separators=(",", ":")))
PY
)"
  worker_before="$(calls worker)"; auditor_before="$(calls auditor)"
  gate_before="$(calls gate)"; decider_before="$(calls decider)"
  evidence_before="$(calls evidence)"

  repair_publication_state_digest() {
    {
      shasum -a 256 "$lease" "$packet" "$audit" \
        "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md"
      git -C "$REPAIR_WORKTREE" rev-parse HEAD
      git -C "$REPAIR_WORKTREE" status --porcelain=v1 -z | shasum -a 256
      git -C "$CONTINUATION_WORKTREE" rev-parse HEAD
      git -C "$CONTINUATION_WORKTREE" status --porcelain=v1 -z | shasum -a 256
      { find "$FIXTURE_ROOT/.singular-state/inbox" \
          "$FIXTURE_ROOT/docs/orchestration/packets/imported/TASK-0001" \
          -type f -print0 2>/dev/null || true; } \
        | sort -z | while IFS= read -r -d '' path; do
          shasum -a 256 "$path"
        done
    } | shasum -a 256 | awk '{print $1}'
  }
  assert_repair_provenance_refusals() {
    local phase="$1" pristine
    local state_before worker_at_start auditor_at_start gate_at_start
    local decider_at_start evidence_at_start rc out mutation
    pristine="$scratch/$name/$phase-repair-lease.json"
    cp "$lease" "$pristine"
    worker_at_start="$(calls worker)"; auditor_at_start="$(calls auditor)"
    gate_at_start="$(calls gate)"; decider_at_start="$(calls decider)"
    evidence_at_start="$(calls evidence)"
    for mutation in missing null list empty historical-run historical-authorization \
        current-marker history-authorizes-current recovery-missing recovery-null \
        recovery-list recovery-empty recovery-recorded; do
      cp "$pristine" "$lease"
      "$PYTHON_BIN" - "$lease" "$mutation" <<'PY'
import json, os, sys
path, mutation = sys.argv[1:]
d = json.load(open(path, encoding="utf-8"))
c = d.get("continuationAuthorization")
r = d["recoveryAuthorization"]
historical = [x for x in d["attemptHistory"]
              if x.get("runId") == r["predecessorRunId"]]
assert len(historical) == 1, d
if mutation == "missing":
    d.pop("continuationAuthorization", None)
elif mutation == "null":
    d["continuationAuthorization"] = None
elif mutation == "list":
    d["continuationAuthorization"] = []
elif mutation == "empty":
    d["continuationAuthorization"] = {}
elif mutation == "historical-run":
    historical[0]["runId"] = "RUN-UNRELATED-HISTORY"
elif mutation == "historical-authorization":
    historical[0]["continuationAuthorizationId"] = "0" * 64
elif mutation == "current-marker":
    d["attemptLifecycle"]["continuationAuthorizationId"] = c["authorizationId"]
elif mutation == "history-authorizes-current":
    c["executionRunId"] = d["runId"]
elif mutation == "recovery-missing":
    d.pop("recoveryAuthorization", None)
elif mutation == "recovery-null":
    d["recoveryAuthorization"] = None
elif mutation == "recovery-list":
    d["recoveryAuthorization"] = []
elif mutation == "recovery-empty":
    d["recoveryAuthorization"] = {}
elif mutation == "recovery-recorded":
    d.pop("continuationAuthorization", None)
    historical[0].pop("continuationAuthorizationId", None)
    r["authorizedBy"] = "tampered-cached-issuer"
temporary = path + ".test.tmp"
json.dump(d, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
      state_before="$(repair_publication_state_digest)"
      rc=0
      out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
      assert_eq "$rc" "3" "$name $phase $mutation provenance refusal ($out)"
      assert_eq "$(repair_publication_state_digest)" "$state_before" \
        "$name $phase $mutation complete retained state"
      assert_eq "$(calls worker)" "$worker_at_start" "$name $phase $mutation worker calls"
      assert_eq "$(calls auditor)" "$auditor_at_start" "$name $phase $mutation auditor calls"
      assert_eq "$(calls gate)" "$gate_at_start" "$name $phase $mutation gate calls"
      assert_eq "$(calls decider)" "$decider_at_start" "$name $phase $mutation decider calls"
      assert_eq "$(calls evidence)" "$evidence_at_start" "$name $phase $mutation evidence calls"
    done
    cp "$pristine" "$lease"
  }

  if [[ "${FROZEN_SKIP_PROVENANCE_NEGATIVES:-0}" != "1" ]]; then
    assert_repair_provenance_refusals awaiting-evidence
  fi

  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "$name claimed repair publication recovery ($out)"
  assert_contains "$out" "RESUMED ACCEPTED EVIDENCE" "$name explicit repair recovery"
  assert_eq "$(calls worker)" "$worker_before" "$name recovery worker calls"
  assert_eq "$(calls auditor)" "$auditor_before" "$name recovery auditor calls"
  assert_eq "$(calls gate)" "$gate_before" "$name recovery gate calls"
  assert_eq "$(calls decider)" "$decider_before" "$name recovery decider calls"
  assert_eq "$(calls evidence)" "$((evidence_before + 1))" "$name evidence-only recovery"
  packet_after="$(shasum -a 256 "$packet" | awk '{print $1}')"
  claim_after="$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["recoveryAuthorization"]
assert a["state"] == "claimed", a
print("|".join(str(a.get(k, "")) for k in ("authorizationId", "claimId", "reservationOwner", "reservationGeneration", "reservationRunId", "successorRunId", "successorBranch", "successorWorktree", "predecessorHeadSha")))
PY
)"
  assert_eq "$claim_after" "$claim_before" "$name claim/provenance preserved"
  assert_eq "$($PYTHON_BIN - "$lease" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps({"retryCount":d.get("retryCount"), "failureBudgets":d.get("failureBudgets"), "failureLimits":d.get("failureLimits")}, sort_keys=True, separators=(",", ":")))
PY
)" "$accounting_before" "$name accounting preserved"
  assert_file "$FIXTURE_ROOT/.singular-state/inbox/$REPAIR_RUN.json" "$name repair publication"

  evidence_before="$(calls evidence)"
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "$name claimed repair duplicate ($out)"
  assert_contains "$out" "already queued/imported; dispatch is a no-op" "$name exact duplicate"
  assert_eq "$(calls worker)" "$worker_before" "$name duplicate worker calls"
  assert_eq "$(calls auditor)" "$auditor_before" "$name duplicate auditor calls"
  assert_eq "$(calls gate)" "$gate_before" "$name duplicate gate calls"
  assert_eq "$(calls decider)" "$decider_before" "$name duplicate decider calls"
  assert_eq "$(calls evidence)" "$evidence_before" "$name duplicate evidence calls"
  assert_eq "$(shasum -a 256 "$packet" | awk '{print $1}')" "$packet_after" \
    "$name duplicate packet bytes"
  if [[ "${FROZEN_SKIP_PROVENANCE_NEGATIVES:-0}" != "1" ]]; then
    assert_repair_provenance_refusals queued-duplicate
  fi

  reconcile success "$name-successor-import"
  "$PYTHON_BIN" - "$lease" "$claim_before" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); a=d["recoveryAuthorization"]
assert "acceptedCandidate" not in d, d
assert a["state"] == "claimed", a
claim="|".join(str(a.get(k, "")) for k in ("authorizationId", "claimId", "reservationOwner", "reservationGeneration", "reservationRunId", "successorRunId", "successorBranch", "successorWorktree", "predecessorHeadSha"))
assert claim == sys.argv[2], (claim, sys.argv[2])
PY
  if [[ "${FROZEN_SKIP_PROVENANCE_NEGATIVES:-0}" != "1" ]]; then
    assert_repair_provenance_refusals imported-duplicate
  fi
  rc=0
  out="$(run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "$name imported repair duplicate ($out)"
  assert_contains "$out" "already queued/imported; dispatch is a no-op" \
    "$name exact imported duplicate"
  assert_eq "$(calls worker)" "$worker_before" "$name imported duplicate worker calls"
  assert_eq "$(calls auditor)" "$auditor_before" "$name imported duplicate auditor calls"
  assert_eq "$(calls gate)" "$gate_before" "$name imported duplicate gate calls"
  assert_eq "$(calls decider)" "$decider_before" "$name imported duplicate decider calls"
  assert_eq "$(calls evidence)" "$evidence_before" "$name imported duplicate evidence calls"
  integration_target_before="$(git -C "$FIXTURE_ROOT" rev-parse target)"
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor \
    "$target_after" "$integration_target_before" \
    || fail "$name integration target lost the independent target advance"
  [[ "$integration_target_before" != "$base" && "$integration_target_before" != "$head" ]] \
    || fail "$name repair product and integration identities collapsed"
  run_engine success "$BASH_BIN" "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0001 --run-id "$name-integration" \
    >"$scratch/$name-integration.log" 2>&1 \
    || fail "$name exact repair integration failed: $(tail -30 "$scratch/$name-integration.log")"
  "$PYTHON_BIN" - "$lease" "$head" "$integration_target_before" "$REPAIR_WORKTREE" <<'PY'
import json, os, sys
d=json.load(open(sys.argv[1], encoding="utf-8")); c=d["acceptedCandidate"]; a=d["recoveryAuthorization"]
assert d["status"] == "integrated" and c["state"] == "integrated", d
assert c["headSha"] == sys.argv[2] and a["state"] == "published", d
assert os.path.realpath(d["worktree"]) == os.path.realpath(sys.argv[4]), d
assert c["integrationProof"]["targetParent"] == sys.argv[3], c
PY
  local integrated_target task2_lease predecessor_worker predecessor_auditor
  integrated_target="$(git -C "$FIXTURE_ROOT" rev-parse target)"
  predecessor_worker="$(calls worker)"
  predecessor_auditor="$(calls auditor)"
  reconcile success "$name-dependent-reservation"
  task2_lease="$FIXTURE_ROOT/.singular-state/leases/TASK-0002.json"
  assert_file "$task2_lease" "$name next dependent lease"
  "$PYTHON_BIN" - "$task2_lease" "$lease" "$integrated_target" "$REPAIR_RUN" \
      "$claim_before" <<'PY'
import json, sys
next_lease = json.load(open(sys.argv[1], encoding="utf-8"))
predecessor = json.load(open(sys.argv[2], encoding="utf-8"))
target, predecessor_run, predecessor_claim = sys.argv[3:]
attempt = next_lease["attemptLifecycle"]
assert next_lease["taskId"] == "TASK-0002", next_lease
assert next_lease["baseSha"] == next_lease["reservationBaseSha"] == target, next_lease
assert next_lease["runId"] != predecessor_run, next_lease
assert attempt["runId"] == next_lease["runId"], next_lease
assert attempt["reservationOwner"] != predecessor["recoveryAuthorization"]["reservationOwner"], (next_lease, predecessor)
assert attempt["reservationRunId"] != predecessor["recoveryAuthorization"]["reservationRunId"], (next_lease, predecessor)
claim = "|".join(str(predecessor["recoveryAuthorization"].get(k, "")) for k in (
    "authorizationId", "claimId", "reservationOwner", "reservationGeneration",
    "reservationRunId", "successorRunId", "successorBranch", "successorWorktree",
    "predecessorHeadSha"))
assert claim == predecessor_claim, (claim, predecessor_claim)
assert predecessor["status"] == "integrated", predecessor
PY
  assert_eq "$(calls worker)" "$((predecessor_worker + 1))" \
    "$name next dependent received one independent worker run"
  assert_eq "$(calls auditor)" "$((predecessor_auditor + 1))" \
    "$name next dependent received one independent audit"
  verify_frozen_engine_bindings || fail "$name engine binding failed at test exit"
  unset -f repair_publication_state_digest assert_repair_provenance_refusals
  unset FROZEN_EVIDENCE_COUNTER FROZEN_EVIDENCE_TARGET_RUNS_DIR \
    FROZEN_EVIDENCE_TARGET_RUN_ID
  ENGINE_HOME="$source_engine"
  echo "ok: claimed native repair publishes, integrates, then reserves its real dependent"
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
  local packet original_sha original_mode manifest_reader_controls
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
  assert_eq "$(calls auditor)" "0" "drift early policy guard prevented semantic audit"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/runs" \
    "$FIXTURE_ROOT/.singular-state/evidence-deliveries.sqlite3" <<'PY'
import json, pathlib, sqlite3, sys
runs, ledger = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
receipts = [json.load(open(path, encoding="utf-8"))
            for path in runs.glob("*/context-invocation-review-target-*.json")]
assert len(receipts) == 1, receipts
assert receipts[0]["status"] == "denied", receipts
assert receipts[0]["denial"]["reason"] == "campaign-mismatch", receipts
assert receipts[0]["retrievalDebitBytes"] == 0, receipts
assert not list(runs.glob("*/delivery-prompt-*.md")), list(runs.glob("*/delivery-prompt-*.md"))
if ledger.exists():
    with sqlite3.connect(ledger) as db:
        assert db.execute("select count(*) from deliveries").fetchone()[0] == 0
PY
  manifest_reader_controls="$scratch/drift-manifest-reader-controls"
  mkdir -p "$manifest_reader_controls"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/events.ndjson" \
    "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$FIXTURE_ROOT/.singular-state/campaign/manifest.json" \
    "$manifest_reader_controls" <<'PY'
import json, os, sys

def assert_manifest_reference(data, expected_manifest):
    assert isinstance(data["manifest"], str) and os.path.isabs(data["manifest"]), data
    assert os.path.isfile(data["manifest"]), data
    assert os.path.samefile(data["manifest"], expected_manifest), data

def assert_manifest_rejected(manifest, expected_manifest, label):
    try:
        assert_manifest_reference({"manifest": manifest}, expected_manifest)
    except (AssertionError, OSError):
        return
    raise AssertionError(f"manifest reader accepted {label}: {manifest!r}")

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
drift_events = [event for event in events if event.get("type") == "campaign.drift_detected"]
assert len(drift_events) == 2, drift_events
assert [(event["data"]["entrypoint"], event["data"]["phase"])
        for event in drift_events] == [
    ("evidence-delivery", "provider-boundary"),
    ("reconcile", "pre-control-state-commit"),
], drift_events
for event in drift_events:
    data = event["data"]
    assert_manifest_reference(data, sys.argv[3])
    assert type(data["verifyExitCode"]) is int, data
    assert data["verifyExitCode"] == 3, data
    assert "raw" not in data, data

controls = sys.argv[4]
alias = os.path.join(controls, "manifest-alias.json")
wrong = os.path.join(controls, "byte-identical-wrong-manifest.json")
missing_actual = os.path.join(controls, "missing-actual.json")
missing_expected = os.path.join(controls, "missing-expected.json")
dangling = os.path.join(controls, "dangling-manifest.json")
directory = os.path.join(controls, "manifest-directory")
relative = os.path.relpath(sys.argv[3])
os.symlink(sys.argv[3], alias)
with open(sys.argv[3], "rb") as source, open(wrong, "wb") as target:
    target.write(source.read())
os.symlink(missing_actual, dangling)
os.mkdir(directory)
assert_manifest_reference({"manifest": alias}, sys.argv[3])
assert_manifest_rejected(wrong, sys.argv[3], "byte-identical wrong file")
assert_manifest_rejected(missing_actual, sys.argv[3], "missing actual path")
assert_manifest_rejected(sys.argv[3], missing_expected, "missing expected path")
assert_manifest_rejected(dangling, sys.argv[3], "dangling link")
assert_manifest_rejected(directory, sys.argv[3], "directory")
assert_manifest_rejected(relative, sys.argv[3], "relative path")
assert_manifest_rejected(None, sys.argv[3], "non-string field")
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
  assert_eq "$(calls auditor)" "0" "drift restart did not manufacture audit"
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
  context-success) test_context_success ;;
  context-missing) test_missing_context_policy_refuses_campaign_start ;;
  infra) test_infra_exhaustion ;;
  context-infra) test_context_infra_exhaustion ;;
  accepted-recovery) test_accepted_recovery_after_independent_target_advance ;;
  drift) test_policy_drift ;;
  drift-injection-failure) test_policy_drift_injection_failure_is_fail_closed ;;
  continuation-budget)
    test_public_continuation_budget continuation-budget-available 0
    test_public_continuation_budget continuation-budget-exhausted 1
    ;;
  continuation-custom-accepted) test_custom_continuation_accepted_publication ;;
  continuation-bootstrap) test_public_continuation_bootstrap_reissue ;;
  repair) test_native_repair_scheduler ;;
  repair-accepted-publication) test_native_repair_accepted_publication ;;
  repair-continued-supported)
    FROZEN_SKIP_PROVENANCE_NEGATIVES=1 test_native_repair_accepted_publication
    ;;
  repair-crash) test_native_repair_started_crash ;;
  continuation)
    test_public_continuation_budget continuation-budget-available 0
    test_public_continuation_budget continuation-budget-exhausted 1
    test_custom_continuation_accepted_publication
    test_public_continuation_bootstrap_reissue
    test_native_repair_scheduler
    test_native_repair_accepted_publication
    test_native_repair_started_crash
    ;;
  all)
    test_success
    test_context_success
    test_missing_context_policy_refuses_campaign_start
    test_infra_exhaustion
    test_context_infra_exhaustion
    test_accepted_recovery_after_independent_target_advance
    test_policy_drift_injection_failure_is_fail_closed
    test_policy_drift
    test_public_continuation_budget continuation-budget-available 0
    test_public_continuation_budget continuation-budget-exhausted 1
    test_custom_continuation_accepted_publication
    test_public_continuation_bootstrap_reissue
    test_native_repair_scheduler
    test_native_repair_accepted_publication
    test_native_repair_started_crash
    ;;
  *) fail "unknown FROZEN_TERMINAL_CASE=${FROZEN_TERMINAL_CASE}" ;;
esac

echo "PASS: frozen campaign terminal lifecycle"
