#!/usr/bin/env bash
set -euo pipefail

# Frozen-campaign regression for a pre-existing committed candidate whose first
# worker makes no edit and whose first fresh audit returns actionable findings.
# The provider is a deterministic fixture, not native unattended-provider
# evidence. Evidence delivery itself uses the real Unix-socket broker by
# default. FIRST_AUDIT_SOCKETLESS=1 is only a supplemental managed-sandbox seam.

find_bash4() {
  local candidate resolved major
  # The host pins PATH for qualification; an explicit override remains useful
  # for other portable runners without baking a workstation path into the test.
  for candidate in "${SINGULAR_TEST_BASH:-}" bash; do
    [[ -n "$candidate" ]] || continue
    resolved="$(command -v "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" && -x "$resolved" ]] || continue
    major="$("$resolved" -c 'printf "%s" "${BASH_VERSINFO[0]:-0}"' 2>/dev/null || true)"
    if [[ "$major" =~ ^[0-9]+$ && "$major" -ge 4 ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 1
}

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  replacement_bash="$(find_bash4 || true)"
  [[ -n "$replacement_bash" ]] || {
    echo "test-first-audit-correction.sh requires a discoverable Bash >= 4" >&2
    exit 1
  }
  exec "$replacement_bash" "$0" "$@"
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="$(find_bash4 || true)"
PYTHON_BIN="${SINGULAR_TEST_PYTHON:-$(command -v python3 2>/dev/null || true)}"
[[ -n "$BASH_BIN" ]] || { echo "missing discoverable Bash >= 4" >&2; exit 1; }
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] \
  || { echo "missing discoverable Python 3" >&2; exit 1; }
"$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)' \
  || { echo "selected Python is not Python 3: $PYTHON_BIN" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly contained '$2'"; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/singular-first-audit-frozen.XXXXXX")"
cleanup() {
  if [[ "${FIRST_AUDIT_KEEP_TMP:-0}" == "1" ]]; then
    echo "first-audit frozen fixture retained: $scratch" >&2
  else
    rm -rf "$scratch"
  fi
}
trap cleanup EXIT

socketless_fixture="$scratch/socketless-fixture"
BROKER_ENV=()
if [[ "${FIRST_AUDIT_SOCKETLESS:-0}" == "1" ]]; then
  echo "SUPPLEMENTAL ONLY: socketless managed-sandbox adapter enabled; this is not real-broker operational evidence" >&2
  mkdir -p "$socketless_fixture"
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
  BROKER_ENV+=("PYTHONPATH=$socketless_fixture${PYTHONPATH:+:$PYTHONPATH}")
fi

FIXTURE_ROOT=""
FIXTURE_COUNTERS=""
FIXTURE_RUNNER=""
FIXTURE_MODE=""
CASE_MAX_RETRIES="1"
REVIEW_MAX_ROUNDS="3"
SEED_HEAD=""
CAMPAIGN_BINDING=""
ENGINE_FINGERPRINT=""
CONFIG_SHA=""
RUNNER_SHA=""
worker_branch="agent/widget/TASK-0001-frozen"

sha256_file() {
  "$PYTHON_BIN" - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)
print(digest.hexdigest())
PY
}

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
run_id=""; level=""; worktree=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) role="$2"; shift 2 ;;
    --capability-profile) capability="$2"; shift 2 ;;
    --result-file) result_file="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --level) level="$2"; shift 2 ;;
    -C|--worktree) worktree="$2"; shift 2 ;;
    --output-last-message) output="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    --session-meta|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$run_id" && -n "$output" ]] || exit 92

bump() {
  local name="$1" path="${FIRST_AUDIT_COUNTERS:?}/$1-calls" count=0
  mkdir -p "${FIRST_AUDIT_COUNTERS:?}"
  [[ -f "$path" ]] && count="$(<"$path")"
  printf '%s\n' "$((count + 1))" >"$path"
  printf '%s\n' "$((count + 1))"
}

write_result() {
  [[ -n "$result_file" ]] || return 0
  "$FIRST_AUDIT_PYTHON" - "$result_file" "$run_id" "$role" "$capability" "$output" <<'PY'
import datetime
import json
import sys

path, run_id, role, capability, output = sys.argv[1:]
record = {
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
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
    handle.write("\n")
PY
}

case "$role" in
  supervisor)
    printf '%s\n' '{"ok":true}' >"$output"
    write_result
    ;;
  implementer)
    [[ "$level" == "l2" && -d "$worktree" ]] || exit 93
    [[ "${SINGULAR_TEST_TASK_ID:-}" == "TASK-0001" ]] || exit 94
    [[ "${SINGULAR_TEST_TASK_CONTRACT:-}" == \
      "${SINGULAR_TEST_TASKS_DIR:-}/TASK-0001.md" ]] || exit 95
    call="$(bump worker)"
    cp "$prompt" "$FIRST_AUDIT_COUNTERS/worker-prompt-$call.md"
    git -C "$worktree" rev-parse HEAD >"$FIRST_AUDIT_COUNTERS/worker-head-$call"
    "$FIRST_AUDIT_PYTHON" - \
      "${FIRST_AUDIT_LEASE:?}" \
      "$FIRST_AUDIT_COUNTERS/worker-retry-$call" <<'PY'
import json
import sys

lease = json.load(open(sys.argv[1], encoding="utf-8"))
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(str(lease.get("retryCount")) + "\n")
PY
    if [[ "$call" == "1" ]]; then
      [[ "$(<"$FIRST_AUDIT_COUNTERS/worker-retry-1")" == "0" ]] || exit 96
      grep -q 'seeded committed candidate' "$worktree/internal/widget/parser.go" || exit 97
    elif [[ "${FIRST_AUDIT_MODE:?}" == "no-output" ]]; then
      # The one bounded re-emit after a packet-format failure carries no audit
      # findings; the fixture simply fails to emit a packet again.
      [[ "$call" == "2" ]] || exit 98
    else
      [[ "$call" == "2" ]] || exit 98
      [[ "$(<"$FIRST_AUDIT_COUNTERS/worker-retry-2")" == "1" ]] || exit 99
      grep -q 'FINDING_ALPHA: replace the seeded implementation' "$prompt" || exit 100
      if [[ "${FIRST_AUDIT_MODE:?}" == "accept" \
          || "${FIRST_AUDIT_MODE:?}" == "required-fixes" \
          || "${FIRST_AUDIT_MODE:?}" == "moved-repeat" \
          || "${FIRST_AUDIT_MODE:?}" == "p1-then-accept" ]]; then
        printf 'package widget\n// corrected after actionable audit feedback\n' \
          >"$worktree/internal/widget/parser.go"
      fi
    fi
    if [[ "${FIRST_AUDIT_MODE:?}" == "no-output" ]]; then
      rm -f "$output"
      write_result
      exit 0
    fi
    FIRST_AUDIT_OUTPUT="$output" FIRST_AUDIT_WORKTREE="$worktree" \
      "$FIRST_AUDIT_PYTHON" - <<'PY'
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
    "branch": "agent/widget/TASK-0001-frozen",
    "headSha": "uncommitted",
    "workspace": os.environ["FIRST_AUDIT_WORKTREE"],
    "ownedFiles": ["internal/widget/parser.go"],
    "changedFiles": [],
    "commands": [],
    "tests": [],
    "evidence": [],
    "blockers": [],
    "nextAction": "await auditor verdict",
    "createdAt": "2026-09-12T00:00:00Z",
}
with open(os.environ["FIRST_AUDIT_OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(record, handle)
    handle.write("\n")
PY
    write_result
    ;;
  auditor)
    call="$(bump auditor)"
    host_report="$(dirname "$output")/audit-verification.json"
    [[ -f "$host_report" ]] || exit 101
    status="$($FIRST_AUDIT_PYTHON - "$host_report" <<'PY'
import json
import sys

status = json.load(open(sys.argv[1], encoding="utf-8"))["outcome"]
print("passed" if status == "passed-with-acknowledged-baseline" else status)
PY
)"
    [[ "$status" == "passed" || "$status" == "not-rerun-evidence-verified" ]] || exit 102
    FIRST_AUDIT_OUTPUT="$output" FIRST_AUDIT_STATUS="$status" \
      FIRST_AUDIT_AUDITOR_CALL="$call" \
      "$FIRST_AUDIT_PYTHON" - <<'PY'
import json
import os

mode = os.environ["FIRST_AUDIT_MODE"]
call = int(os.environ["FIRST_AUDIT_AUDITOR_CALL"])
canonical = "FINDING_ALPHA: replace the seeded implementation"
verdict = "needs-fix"
findings = [canonical]
required_fixes = [canonical]
if mode in {"accept", "required-fixes"} and call > 1:
    verdict = "accepted"
    findings = []
    required_fixes = []
elif mode == "repeat" and call > 1:
    findings = ["  FINDING_ALPHA:   replace the seeded implementation  "]
    required_fixes = list(findings)
elif mode == "blank-only":
    findings = ["", "   ", "``"]
    required_fixes = [" ` \t ` "]
elif mode == "required-fixes":
    findings = []
    required_fixes = [canonical]
elif mode == "moved-repeat":
    if call == 1:
        findings = []
        required_fixes = [canonical]
    else:
        findings = ["  `finding_alpha`:   REPLACE the seeded implementation  "]
        required_fixes = [
            "`FINDING_ALPHA: replace the seeded implementation`",
            " finding_alpha: replace the seeded implementation ",
        ]
classified = []
if mode == "p2-only":
    verdict = "needs-fix"
    findings = ["P2 leftover comment", "P2 unused helper"]
    required_fixes = list(findings)
    classified = [
        {"id": "p2-comment", "severity": "P2", "summary": "P2 leftover comment"},
        {"id": "p2-helper", "severity": "P2", "summary": "P2 unused helper"},
    ]
elif mode == "p1-then-accept":
    if call > 1:
        verdict = "accepted"
        findings = []
        required_fixes = []
        classified = []
    else:
        classified = [{
            "id": "p1-seeded",
            "severity": "P1",
            "summary": canonical,
            "trigger": "seeded implementation remains",
            "impact": "acceptance criteria unmet",
            "requirement": "replace the seeded implementation",
        }]
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": "fixture-run",
    "branch": "agent/widget/TASK-0001-frozen",
    "verdict": verdict,
    "evidenceReviewed": ["evidence-manifest.json", "audit-verification.json"],
    "verificationResults": [{
        "status": os.environ["FIRST_AUDIT_STATUS"],
        "command": "bash strict-gate.sh",
        "exitCode": 0,
        "evidenceRefs": ["audit-verification.json"],
        "rationale": "matches the exact host-derived classification",
    }],
    "commandsRun": [],
    "findings": findings,
    "requiredFixes": required_fixes,
    "rationale": "fresh accepted audit" if verdict == "accepted" else "fresh audit feedback",
}
if classified:
    record["classifiedFindings"] = classified
with open(os.environ["FIRST_AUDIT_OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(record, handle)
    handle.write("\n")
PY
    write_result
    ;;
  *) exit 103 ;;
esac
RUNNER
  chmod +x "$runner"
}

run_engine() {
  (
    cd "$FIXTURE_ROOT"
    env "${BROKER_ENV[@]}" \
      PATH="$(dirname "$BASH_BIN"):$(dirname "$PYTHON_BIN"):/usr/bin:/bin:${PATH:-}" \
      PYTHONDONTWRITEBYTECODE=1 \
      FIRST_AUDIT_PYTHON="$PYTHON_BIN" \
      FIRST_AUDIT_MODE="$FIXTURE_MODE" \
      FIRST_AUDIT_COUNTERS="$FIXTURE_COUNTERS" \
      FIRST_AUDIT_LEASE="$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
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
      SINGULAR_WORKER_INFRA_MAX=0 \
      SINGULAR_AUDIT_INFRA_MAX=0 \
      SINGULAR_MAX_RETRIES="$CASE_MAX_RETRIES" \
      SINGULAR_DECIDER_FAST=1 \
      SINGULAR_REVIEW_MAX_ROUNDS="${REVIEW_MAX_ROUNDS:-3}" \
      "$@"
  )
}

make_fixture() {
  local name="$1" mode="$2" max_retries="$3" risk_tier="$4"
  REVIEW_MAX_ROUNDS="${5:-3}"
  FIXTURE_ROOT="$scratch/$name/repo"
  FIXTURE_COUNTERS="$scratch/$name/counters"
  FIXTURE_RUNNER="$scratch/$name/runner.sh"
  FIXTURE_MODE="$mode"
  CASE_MAX_RETRIES="$max_retries"
  mkdir -p "$FIXTURE_ROOT/docs/orchestration/tasks" \
    "$FIXTURE_ROOT/docs/orchestration/prompts" "$FIXTURE_COUNTERS"
  git -C "$FIXTURE_ROOT" init -q
  git -C "$FIXTURE_ROOT" checkout -q -b target
  git -C "$FIXTURE_ROOT" config user.name first-audit-test
  git -C "$FIXTURE_ROOT" config user.email first-audit@example.invalid
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" \
    "$FIXTURE_ROOT/docs/orchestration/prompts/"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" \
    "$FIXTURE_ROOT/docs/orchestration/prompts/"
  printf '# Fixture planner policy\n' >"$FIXTURE_ROOT/docs/orchestration/prompts/l1-planner.md"
  printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' \
    >"$FIXTURE_ROOT/docs/orchestration/prompts/decider.md"
  cat >"$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" <<TASK
# TASK-0001: Correct a committed candidate after fresh audit feedback

Status: ready
Area: widget
Risk tier: $risk_tier
Target branch: \`target\`
Worker branch: \`agent/widget/TASK-0001-frozen\`
Test policy: \`strict_test_first\`
Gate command: \`bash strict-gate.sh\`
Dispatch mode: canonical
Depends on: []

## Objective

Correct the pre-existing widget candidate from fresh audit findings.

## Scope

Owned files:

- \`internal/widget/parser.go\`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The fresh audit finding is fixed in one bounded correcting pass.
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
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": "v2",
        "targetBranch": "target",
        "gateCommand": "bash strict-gate.sh",
        "runner": sys.argv[2],
        "bootstrap": {"required": False, "commands": []},
    }, handle)
    handle.write("\n")
PY
  run_engine "$BASH_BIN" -c \
    '. "$1"; singular_ensure_state_dirs; singular_ensure_repo_scaffold' \
    fixture "$ENGINE_HOME/engine/lib.sh"
  git -C "$FIXTURE_ROOT" add .
  git -C "$FIXTURE_ROOT" commit -qm 'first-audit frozen fixture baseline'

  local seed="$scratch/$name/seed"
  git -C "$FIXTURE_ROOT" worktree add -q -b "$worker_branch" "$seed" target
  mkdir -p "$seed/internal/widget"
  printf 'package widget\n// seeded committed candidate\n' >"$seed/internal/widget/parser.go"
  git -C "$seed" add internal/widget/parser.go
  git -C "$seed" commit -qm 'seed committed candidate'
  SEED_HEAD="$(git -C "$seed" rev-parse HEAD)"
  git -C "$FIXTURE_ROOT" worktree remove "$seed"

  run_engine "$BASH_BIN" "$ENGINE_HOME/engine/campaign.sh" start \
    --id "first-audit-$name" >"$scratch/$name/campaign-start.raw.log" 2>&1 \
    || { cat "$scratch/$name/campaign-start.raw.log" >&2; fail "$name campaign did not start"; }
  run_engine "$BASH_BIN" "$ENGINE_HOME/engine/campaign.sh" verify --quiet \
    || fail "$name frozen campaign did not verify"
  CAMPAIGN_BINDING="$(run_engine "$BASH_BIN" -c \
    '. "$1"; singular_campaign_binding' fixture "$ENGINE_HOME/engine/lib.sh")"
  ENGINE_FINGERPRINT="$(run_engine "$BASH_BIN" -c \
    '. "$1"; singular_campaign_engine_source_fingerprint' fixture "$ENGINE_HOME/engine/lib.sh")"
  CONFIG_SHA="$(sha256_file "$FIXTURE_ROOT/singular.config.json")"
  RUNNER_SHA="$(sha256_file "$FIXTURE_RUNNER")"
  [[ "$CAMPAIGN_BINDING" == campaign:first-audit-"$name":sha256:* ]] \
    || fail "$name did not establish a content-addressed campaign binding"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/campaign/manifest.json" \
    "$FIXTURE_ROOT/singular.config.json" "$FIXTURE_RUNNER" "$CONFIG_SHA" \
    "$RUNNER_SHA" "$ENGINE_FINGERPRINT" "first-audit-$name" <<'PY'
import json
import os
import sys

(manifest_path, config_path, runner_path, config_sha, runner_sha,
 engine_fingerprint, campaign_id) = sys.argv[1:]
manifest = json.load(open(manifest_path, encoding="utf-8"))
assert manifest["campaignId"] == campaign_id, manifest
assert os.path.realpath(manifest["configuration"]["json"]["path"]) == os.path.realpath(config_path), manifest
assert manifest["configuration"]["json"]["sha256"] == config_sha, manifest
assert os.path.realpath(manifest["runner"]["path"]) == os.path.realpath(runner_path), manifest
assert manifest["runner"]["sha256"] == runner_sha, manifest
assert manifest["engine"]["sourceFingerprint"] == engine_fingerprint, manifest
assert os.path.isfile(manifest_path), manifest_path
PY
}

reconcile() {
  local name="$1" label="$2" rc=0
  run_engine "$BASH_BIN" "$ENGINE_HOME/engine/reconcile.sh" --actuate \
    >"$scratch/$name/$label.raw.log" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    cat "$scratch/$name/$label.raw.log" >&2
    fail "$name/$label reconcile returned $rc"
  fi
}

calls() {
  local role="$1" path="$FIXTURE_COUNTERS/$1-calls"
  [[ -f "$path" ]] && cat "$path" || printf '0\n'
}

event_count() {
  local event_type="$1"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/events.ndjson" "$event_type" <<'PY'
import json
import sys

count = 0
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("type") == sys.argv[2]:
            count += 1
print(count)
PY
}

identity_signature() {
  local payload="$1" record
  record="$(mktemp "$scratch/identity.XXXXXX")"
  printf '%s\n' "$payload" >"$record"
  "$BASH_BIN" -c '
    source <(sed -n "/^l1_normalized_findings_signature()/,/^# ---- Decider-driven retry loop ----$/p" "$1" | sed "\$d")
    l1_normalized_findings_signature "$2"
  ' fixture "$ENGINE_HOME/engine/l1-drive.sh" "$record"
}

set_task_ready() {
  "$PYTHON_BIN" - "$FIXTURE_ROOT/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^Status:\s*`?[^`\n]+`?\s*$", "Status: ready", text,
              count=1, flags=re.MULTILINE | re.IGNORECASE)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
}

assert_attempt_count() {
  local expected="$1" actual
  actual="$("$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/runs" <<'PY'
import json
import pathlib
import sys

count = 0
for path in pathlib.Path(sys.argv[1]).glob("*/attempts/index.json"):
    data = json.load(open(path, encoding="utf-8"))
    if data.get("taskId") == "TASK-0001":
        count += len(data.get("attempts", []))
print(count)
PY
)"
  assert_eq "$actual" "$expected" "durable attempt archive count"
}

assert_terminal_contract() {
  local kind="$1" failure_class="$2" action="$3" expected_retry="$4"
  "$PYTHON_BIN" - "$FIXTURE_ROOT/.singular-state/leases/TASK-0001.json" \
    "$FIXTURE_ROOT/.singular-state/dispatch/TASK-0001.json" \
    "$FIXTURE_ROOT/.singular-state/campaign/manifest.json" \
    "$kind" "$failure_class" "$action" "$expected_retry" \
    "$CAMPAIGN_BINDING" "$ENGINE_FINGERPRINT" "$CONFIG_SHA" <<'PY'
import json
import sys

(lease_path, dispatch_path, manifest_path, kind, failure_class, action,
 expected_retry, campaign_binding, engine_fingerprint, config_sha) = sys.argv[1:]
lease = json.load(open(lease_path, encoding="utf-8"))
dispatch = json.load(open(dispatch_path, encoding="utf-8"))
manifest = json.load(open(manifest_path, encoding="utf-8"))
terminal = lease["terminalDisposition"]
attempt = lease["attemptLifecycle"]
dispatch_attempt = dispatch["attemptLifecycle"]
assert lease["retryCount"] == int(expected_retry), lease
assert terminal["schema"] == "singular.orchestration.terminal-disposition.v0", terminal
assert terminal["kind"] == kind, terminal
assert terminal.get("failureClass", "") == failure_class, terminal
assert terminal["action"] == action, terminal
assert terminal["campaignBinding"] == campaign_binding, terminal
assert dispatch["campaignBinding"] == campaign_binding, dispatch
assert lease["campaignBinding"] == campaign_binding, lease
assert manifest["engine"]["sourceFingerprint"] == engine_fingerprint, manifest
assert manifest["configuration"]["json"]["sha256"] == config_sha, manifest
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
    assert record["campaignBinding"] == campaign_binding, record
assert attempt == dispatch_attempt, (attempt, dispatch_attempt)
assert terminal["reservationGeneration"] == 1, terminal
assert dispatch["reservationGeneration"] == 1, dispatch
assert dispatch["state"] == "reaped", dispatch
PY
}

finish_and_prove_no_redispatch() {
  local name="$1" workers="$2" auditors="$3"
  reconcile "$name" terminal-reap
  set_task_ready
  reconcile "$name" terminal-reentry-one
  reconcile "$name" terminal-reentry-two
  assert_eq "$(calls worker)" "$workers" "$name terminal worker count"
  assert_eq "$(calls auditor)" "$auditors" "$name terminal auditor count"
  assert_eq "$(find "$FIXTURE_ROOT/.singular-state/dispatch" -name 'TASK-0001.json' \
    -type f | wc -l | tr -d '[:space:]')" "1" "$name single dispatch record"
  run_engine "$BASH_BIN" "$ENGINE_HOME/engine/campaign.sh" verify --quiet \
    || fail "$name campaign identity drifted"
  assert_contains "$(cat "$scratch/$name/terminal-reentry-one.raw.log" \
    "$scratch/$name/terminal-reentry-two.raw.log")" \
    'reservation refused for TASK-0001' "$name durable terminal reservation refusal"
}

test_corrected_after_fresh_audit() {
  local name=corrected
  make_fixture "$name" accept 1 normal
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "2" "$name worker calls"
  assert_eq "$(calls auditor)" "2" "$name fresh auditor calls"
  assert_eq "$(<"$FIXTURE_COUNTERS/worker-head-1")" "$SEED_HEAD" \
    "$name first worker saw preseeded commit"
  assert_eq "$(<"$FIXTURE_COUNTERS/worker-retry-1")" "0" \
    "$name initial pass accounting"
  assert_eq "$(<"$FIXTURE_COUNTERS/worker-retry-2")" "1" \
    "$name correction charged before worker"
  local events
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"l1.no_changes_reconciled"' \
    "$name preseeded no-edit reconciliation"
  assert_contains "$events" '"type":"l1.actionable_audit_correction_eligible"' \
    "$name fresh findings correction eligibility"
  assert_contains "$events" '"type":"l1.product_repair_budget_consumed"' \
    "$name durable retry 0 to 1"
  assert_contains "$events" '"type":"l1.task_accepted"' "$name accepted correction"
  assert_not_contains "$events" '"type":"l1.identical_findings_parked"' \
    "$name accepted path did not repeat findings"
  grep -q 'corrected after actionable audit feedback' \
    "$FIXTURE_ROOT/.worktrees/TASK-0001/internal/widget/parser.go" \
    || fail "$name corrected candidate bytes missing"
  assert_attempt_count 2
  finish_and_prove_no_redispatch "$name" 2 2
  assert_terminal_contract completed "" accepted 1
  echo "ok: frozen preseed -> no-edit -> fresh needs-fix -> charged correction -> fresh accept"
}

test_feedback_identity_contract() {
  local canonical equivalent distinct blank invalid expected
  canonical="$(identity_signature \
    '{"findings":["  `FINDING_ALPHA`:   replace the seeded implementation  "],"requiredFixes":[]}')"
  equivalent="$(identity_signature \
    '{"findings":[" finding_alpha: REPLACE the seeded implementation "],"requiredFixes":["`FINDING_ALPHA: replace the seeded implementation`"," finding_alpha: replace the seeded implementation "]}')"
  distinct="$(identity_signature \
    '{"findings":[],"requiredFixes":["FINDING_BETA: replace the seeded implementation"]}')"
  blank="$(identity_signature \
    '{"findings":["","   ","``"],"requiredFixes":[" ` \t ` "]}')"
  invalid="$(identity_signature \
    '{"findings":[{"text":"FINDING_ALPHA: replace the seeded implementation"},1,true,["FINDING_ALPHA: replace the seeded implementation"]],"requiredFixes":[null]}')"
  expected="470a78ca19f33d31aaf8f34e6d968396cd281c7684da373758bd3ca909b6f988"
  assert_eq "$canonical" "$expected" "canonical feedback identity"
  assert_eq "$equivalent" "$canonical" \
    "array placement, duplicates, whitespace, case and backticks are identity-neutral"
  [[ -n "$distinct" && "$distinct" != "$canonical" ]] \
    || fail "distinct substantive feedback must have a distinct nonempty identity"
  assert_eq "$blank" "" "blank-only feedback has no identity"
  assert_eq "$invalid" "" "invalid item types cannot acquire feedback identity"
  echo "ok: feedback identity matches the worker-ledger string contract"
}

test_blank_only_feedback_parks_without_repair() {
  local name=blank-only
  make_fixture "$name" blank-only 2 high
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "1" "$name worker calls"
  assert_eq "$(calls auditor)" "1" "$name auditor calls"
  local events
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"l1.unchanged_candidate_parked"' \
    "$name unchanged candidate terminal"
  assert_not_contains "$events" '"type":"l1.actionable_audit_correction_eligible"' \
    "$name blank feedback is not actionable"
  assert_eq "$(event_count l1.product_repair_budget_consumed)" "0" \
    "$name repair charge count"
  assert_attempt_count 1
  finish_and_prove_no_redispatch "$name" 1 1
  assert_terminal_contract blocked audit-needs-fix escalate-parked 0
  echo "ok: blank and backtick-only feedback parks without a correction charge"
}

test_required_fixes_only_correction() {
  local name=required-fixes
  make_fixture "$name" required-fixes 1 normal
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "2" "$name worker calls"
  assert_eq "$(calls auditor)" "2" "$name auditor calls"
  assert_eq "$(<"$FIXTURE_COUNTERS/worker-retry-2")" "1" \
    "$name correction charged before worker"
  grep -q 'FINDING_ALPHA: replace the seeded implementation' \
    "$FIXTURE_COUNTERS/worker-prompt-2.md" \
    || fail "$name requiredFixes text did not reach correcting worker"
  local events
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"l1.actionable_audit_correction_eligible"' \
    "$name requiredFixes-only eligibility"
  assert_contains "$events" '"type":"l1.task_accepted"' "$name accepted correction"
  assert_eq "$(event_count l1.product_repair_budget_consumed)" "1" \
    "$name repair charge count"
  grep -q 'corrected after actionable audit feedback' \
    "$FIXTURE_ROOT/.worktrees/TASK-0001/internal/widget/parser.go" \
    || fail "$name corrected candidate bytes missing"
  assert_attempt_count 2
  finish_and_prove_no_redispatch "$name" 2 2
  assert_terminal_contract completed "" accepted 1
  echo "ok: requiredFixes-only feedback authorizes one charged correction and fresh acceptance"
}

test_moved_duplicate_feedback_stops_changed_candidate() {
  local name=moved-repeat
  make_fixture "$name" moved-repeat 2 high
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "2" "$name worker calls"
  assert_eq "$(calls auditor)" "2" "$name auditor calls"
  assert_eq "$(<"$FIXTURE_COUNTERS/worker-retry-2")" "1" \
    "$name correction charged before second worker"
  local events
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"l1.identical_findings_parked"' \
    "$name equivalent feedback repeat guard"
  assert_contains "$events" '"candidateUnchanged":false' \
    "$name changed corrective candidate classification"
  assert_contains "$events" '"productRepairMax":2' \
    "$name retained high-risk repair headroom"
  assert_eq "$(event_count l1.product_repair_budget_consumed)" "1" \
    "$name repair charge count"
  grep -q 'corrected after actionable audit feedback' \
    "$FIXTURE_ROOT/.worktrees/TASK-0001/internal/widget/parser.go" \
    || fail "$name second worker did not change candidate bytes"
  assert_attempt_count 2
  finish_and_prove_no_redispatch "$name" 2 2
  assert_terminal_contract blocked audit-needs-fix escalate-parked 1
  echo "ok: moved and duplicated equivalent feedback parks a changed candidate before pass three"
}

test_max_zero_is_terminal() {
  local name=max-zero
  make_fixture "$name" repeat 0 normal
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "1" "$name initial worker calls"
  assert_eq "$(calls auditor)" "1" "$name initial auditor calls"
  local events
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"l1.actionable_audit_correction_eligible"' \
    "$name fresh audit still ran"
  assert_contains "$events" '"type":"l1.product_repair_budget_exhausted"' \
    "$name zero repair terminal"
  assert_not_contains "$events" '"type":"l1.product_repair_budget_consumed"' \
    "$name cannot consume nonexistent repair"
  assert_attempt_count 1
  finish_and_prove_no_redispatch "$name" 1 1
  assert_terminal_contract blocked audit-needs-fix escalate-parked 0
  echo "ok: max-zero fresh audit terminates durably and reconciliation cannot mint a pass"
}

test_repeated_findings_stop_with_budget_left() {
  local name=repeated
  make_fixture "$name" repeat 2 high
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "2" "$name worker calls"
  assert_eq "$(calls auditor)" "2" "$name auditor calls"
  assert_eq "$(<"$FIXTURE_COUNTERS/worker-retry-2")" "1" \
    "$name correction charged before second worker"
  local events
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"l1.identical_findings_parked"' \
    "$name normalized repeated findings guard"
  assert_contains "$events" '"productRepairMax":2' \
    "$name retained nominal high-risk repair headroom"
  assert_eq "$(git -C "$FIXTURE_ROOT/.worktrees/TASK-0001" rev-parse HEAD)" \
    "$SEED_HEAD" "$name no-op correction kept exact candidate"
  assert_attempt_count 2
  finish_and_prove_no_redispatch "$name" 2 2
  assert_terminal_contract blocked audit-needs-fix escalate-parked 1
  echo "ok: normalized repeated findings park before a third pass despite budget headroom"
}

test_no_output_stays_fail_closed() {
  local name=no-output
  make_fixture "$name" no-output 1 normal
  reconcile "$name" dispatch
  # A first packet-format failure on an unchanged candidate gets exactly one
  # re-emit (charged to the product budget); the repeat parks fail-closed with
  # no audit spend.
  assert_eq "$(calls worker)" "2" "$name worker calls"
  assert_eq "$(calls auditor)" "0" "$name auditor calls"
  local events
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"l1.packet_format_retry_eligible"' \
    "$name first format failure re-emits once"
  assert_contains "$events" '"type":"l1.unchanged_candidate_parked"' \
    "$name unchanged no-output guard"
  assert_contains "$events" '"failureClass":"worker-no-packet"' \
    "$name output failure classification"
  assert_not_contains "$events" '"type":"worker.infra_retry"' \
    "$name no-output is not infrastructure"
  assert_attempt_count 2
  finish_and_prove_no_redispatch "$name" 2 0
  assert_terminal_contract blocked worker-no-packet escalate-parked 1
  echo "ok: frozen rc-zero no-output remains fail-closed without audit or repair spend"
}

test_p2_only_accepted_without_repair() {
  local name=p2-only events
  make_fixture "$name" p2-only 1 normal 2
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "1" "$name worker calls"
  assert_eq "$(calls auditor)" "1" "$name auditor calls"
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"l1.task_accepted"' "$name accepted after policy"
  assert_contains "$events" '"type":"review.policy_applied"' "$name policy applied"
  assert_contains "$events" '"effectiveVerdict":"accepted"' "$name effective accepted"
  assert_eq "$(grep -c . "$FIXTURE_ROOT/.singular-state/review-policy/backlog.ndjson")" "2" \
    "$name backlog lines"
  assert_not_contains "$events" '"type":"l1.product_repair_budget_consumed"' \
    "$name did not spend product repair"
  assert_attempt_count 1
  finish_and_prove_no_redispatch "$name" 1 1
  assert_terminal_contract completed "" accepted 0
  echo "ok: P2-only needs-fix is accepted as backlog without a correction charge"
}

test_p1_then_accept() {
  local name=p1-then-accept events ledger
  make_fixture "$name" p1-then-accept 1 normal 2
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "2" "$name worker calls"
  assert_eq "$(calls auditor)" "2" "$name auditor calls"
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_eq "$(event_count review.policy_applied)" "2" "$name policy applied twice"
  assert_contains "$events" '"type":"l1.task_accepted"' "$name accepted after P1 fix"
  ledger="$(cat "$FIXTURE_ROOT/.singular-state/review-policy/ledger.json")"
  assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); e=d["logicalChanges"]["TASK-0001"]; print(len(e["rounds"]), e["status"])' <<<"$ledger")" \
    "2 accepted" "$name ledger two rounds accepted"
  assert_attempt_count 2
  finish_and_prove_no_redispatch "$name" 2 2
  assert_terminal_contract completed "" accepted 1
  echo "ok: supported P1 charges one correction and accepts on the follow-up round"
}

test_rounds_exhausted_without_auditor() {
  local name=rounds-exhausted events
  make_fixture "$name" accept 1 normal 2
  cat >"$scratch/$name/backfill.json" <<'JSON'
{
  "logicalChange": "TASK-0001",
  "rounds": [
    {
      "round": 1,
      "kind": "initial",
      "taskId": "TASK-0001",
      "runId": "historical-1",
      "attempt": 1,
      "head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "originalVerdict": "needs-fix",
      "effectiveVerdict": "needs-fix",
      "blocking": ["f-hist-1"],
      "backlog": [],
      "downgraded": [],
      "unclassifiedCount": 0
    },
    {
      "round": 2,
      "kind": "followup",
      "taskId": "TASK-0001",
      "runId": "historical-2",
      "attempt": 2,
      "head": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "originalVerdict": "needs-fix",
      "effectiveVerdict": "needs-fix",
      "blocking": ["f-hist-1"],
      "backlog": [],
      "downgraded": [],
      "unclassifiedCount": 0
    }
  ]
}
JSON
  SINGULAR_REVIEW_MAX_ROUNDS=2 \
    "$PYTHON_BIN" "$ENGINE_HOME/engine/review_policy.py" \
    --config "$FIXTURE_ROOT/singular.config.json" \
    --state-dir "$FIXTURE_ROOT/.singular-state" \
    backfill --file "$scratch/$name/backfill.json" >/dev/null \
    || fail "$name backfill failed"
  reconcile "$name" dispatch
  assert_eq "$(calls worker)" "1" "$name worker calls"
  assert_eq "$(calls auditor)" "0" "$name auditor not called"
  events="$(cat "$FIXTURE_ROOT/.singular-state/events.ndjson")"
  assert_contains "$events" '"type":"review.rounds_exhausted"' "$name exhausted event"
  assert_not_contains "$events" '"type":"l1.product_repair_budget_consumed"' \
    "$name did not spend product repair"
  assert_attempt_count 1
  finish_and_prove_no_redispatch "$name" 1 0
  assert_terminal_contract blocked review-rounds-exhausted escalate-parked 0
  echo "ok: pre-filled review rounds exhaust before auditor launch"
}

echo "NOTE: deterministic fixture provider; this test is not live unattended-provider evidence"
case "${FIRST_AUDIT_CASE:-all}" in
  identity) test_feedback_identity_contract ;;
  corrected) test_corrected_after_fresh_audit ;;
  blank-only) test_blank_only_feedback_parks_without_repair ;;
  required-fixes) test_required_fixes_only_correction ;;
  moved-repeat) test_moved_duplicate_feedback_stops_changed_candidate ;;
  max-zero) test_max_zero_is_terminal ;;
  repeated) test_repeated_findings_stop_with_budget_left ;;
  no-output) test_no_output_stays_fail_closed ;;
  p2-only) test_p2_only_accepted_without_repair ;;
  p1-then-accept) test_p1_then_accept ;;
  rounds-exhausted) test_rounds_exhausted_without_auditor ;;
  all)
    test_feedback_identity_contract
    test_corrected_after_fresh_audit
    test_blank_only_feedback_parks_without_repair
    test_required_fixes_only_correction
    test_moved_duplicate_feedback_stops_changed_candidate
    test_max_zero_is_terminal
    test_repeated_findings_stop_with_budget_left
    test_no_output_stays_fail_closed
    test_p2_only_accepted_without_repair
    test_p1_then_accept
    test_rounds_exhausted_without_auditor
    ;;
  *) fail "unknown FIRST_AUDIT_CASE=${FIRST_AUDIT_CASE}" ;;
esac
echo "PASS: test-first-audit-correction (frozen campaign lifecycle)"
