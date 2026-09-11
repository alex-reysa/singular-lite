#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

workspace_fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
digest.update(subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"]))
digest.update(subprocess.check_output([
    "git", "-C", str(root), "status", "--porcelain=v1", "-z", "--untracked-files=all"
]))
for raw in subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).split(b"\0"):
    if not raw:
        continue
    path = root / os.fsdecode(raw)
    digest.update(raw)
    digest.update(b"\0")
    digest.update(path.read_bytes())
print(digest.hexdigest())
PY
}

worktree_count() {
  git -C "$SINGULAR_ROOT" worktree list --porcelain | grep -c '^worktree '
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
path, dotted = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    value = json.load(f)
for part in dotted.split("."):
    value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/tasks" \
    "$root/docs/orchestration/packets/imported" \
    "$root/docs/orchestration/decisions" \
    "$root/schemas/orchestration" \
    "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/schemas/state-packet.v0.schema.json" "$root/schemas/orchestration/state-packet.v0.schema.json"
  cp "$ENGINE_HOME/schemas/audit-verdict.v0.schema.json" "$root/schemas/orchestration/audit-verdict.v0.schema.json"
  mkdir -p "$root/internal/artifact"
  echo "package artifact" >"$root/internal/artifact/doc.go"
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  FIXTURE_TMP="$tmp"
  make_repo "$tmp/repo"
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_AUDIT_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/audit-verdict.v0.schema.json"
  export SINGULAR_TARGET_BRANCH="target"
  export SINGULAR_MODULES="storage-proof"
  export SINGULAR_PROOF_LAYERS="storage_proof"
}

write_task() {
  cat >"$SINGULAR_TASKS_DIR/TASK-9001.md" <<'EOF'
# TASK-9001: Existing packet acceptance fixture

Status: blocked
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-9001-test`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Accept an already-built packet.

## Scope

Owned files:

- `internal/artifact/a.go`
- `internal/artifact/a_test.go`

Forbidden files:

- `internal/artifact/doc.go`

## Acceptance Criteria

- Pass.
EOF
}

write_storage_proof_task() {
  cat >"$SINGULAR_TASKS_DIR/TASK-9001.md" <<'EOF'
# TASK-9001: Durable storage proof existing packet fixture

Status: blocked
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-9001-test`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement a bounded `D1.storage_proof` / `storage_proof` repository conformance round-trip proof.

## Scope

Owned files:

- `internal/artifact/a.go`
- `internal/artifact/a_test.go`

Forbidden files:

- `internal/artifact/doc.go`

## Acceptance Criteria

- Include marked nonzero red evidence for the storage-stripped real-store proof path.

## Required Evidence

- Failing targeted test output, including a marked nonzero `*-skip-guard-red` storage-proof command log.
EOF
}

write_worker_branch_and_packet() {
  local run_id="RUN-TEST-9001"
  local branch="agent/artifact/TASK-9001-test"
  local base head worktree run_dir
  base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  worktree="$(dirname "$SINGULAR_ROOT")/wt-TASK-9001"
  git -C "$SINGULAR_ROOT" branch "$branch" target
  git -C "$SINGULAR_ROOT" worktree add -q "$worktree" "$branch"
  echo "package artifact" >"$worktree/internal/artifact/a.go"
  cat >"$worktree/internal/artifact/a_test.go" <<'EOF'
package artifact

import "testing"

func TestFixture(t *testing.T) {}
EOF
  mkdir -p "$worktree/.singular-evidence"
  echo "red failed as expected" >"$worktree/.singular-evidence/red.log"
  echo "green passed" >"$worktree/.singular-evidence/green.log"
  echo "regression passed" >"$worktree/.singular-evidence/regression.log"
  git -C "$worktree" add internal/artifact/a.go internal/artifact/a_test.go
  git -C "$worktree" -c user.name=test -c user.email=test@example.local commit -q -m "TASK-9001 worker"
  head="$(git -C "$worktree" rev-parse HEAD)"
  run_dir="$SINGULAR_RUNS_DIR/$run_id"
  mkdir -p "$run_dir"
  cat >"$run_dir/packet.json" <<EOF
{
  "schema": "singular.orchestration.state-packet.v0",
  "packetId": "TASK-9001-$run_id",
  "runId": "$run_id",
  "taskId": "TASK-9001",
  "area": "artifact",
  "role": "l2-developer",
  "status": "needs-review",
  "baseRef": "$base",
  "branch": "$branch",
  "headSha": "$head",
  "workspace": "$worktree",
  "ownedFiles": [
    "internal/artifact/a.go",
    "internal/artifact/a_test.go"
  ],
  "changedFiles": [
    "internal/artifact/a.go",
    "internal/artifact/a_test.go"
  ],
  "commands": [
    {"cmd": "false", "exitCode": 1, "logRef": ".singular-evidence/red.log"},
    {"cmd": "test -f internal/artifact/a.go", "exitCode": 0, "logRef": ".singular-evidence/green.log"},
    {"cmd": "test -f internal/artifact/a_test.go", "exitCode": 0, "logRef": ".singular-evidence/regression.log"}
  ],
  "tests": [
    {"name": "fixture red", "phase": "red", "status": "failed-as-expected", "logRef": ".singular-evidence/red.log"},
    {"name": "fixture green", "phase": "green", "status": "passed", "logRef": ".singular-evidence/green.log"},
    {"name": "fixture regression", "phase": "regression", "status": "passed", "logRef": ".singular-evidence/regression.log"}
  ],
  "evidence": [
    {"kind": "red-log", "ref": ".singular-evidence/red.log"},
    {"kind": "green-log", "ref": ".singular-evidence/green.log"},
    {"kind": "regression-log", "ref": ".singular-evidence/regression.log"}
  ],
  "blockers": [],
  "nextAction": "await review",
  "createdAt": "2026-06-03T00:00:00Z"
}
EOF
  mkdir -p "$SINGULAR_LEASES_DIR"
  cat >"$SINGULAR_LEASES_DIR/TASK-9001.json" <<EOF
{
  "taskId": "TASK-9001",
  "branch": "$branch",
  "area": "artifact",
  "owner": "l2-developer",
  "fileScope": "internal/artifact/a.go internal/artifact/a_test.go",
  "ownedFiles": ["internal/artifact/a.go", "internal/artifact/a_test.go"],
  "forbiddenFiles": ["internal/artifact/doc.go"],
  "baseSha": "$base",
  "runId": "$run_id",
  "worktree": "$worktree",
  "status": "blocked",
  "createdAt": "2026-06-03T00:00:00Z",
  "updatedAt": "2026-06-03T00:00:00Z"
}
EOF
}

write_bound_verification() {
  local run_id="RUN-TEST-9001"
  local run_dir="$SINGULAR_RUNS_DIR/$run_id"
  local packet="$run_dir/packet.json"
  local task_snapshot="$run_dir/verification-task-contract-1.md"
  local policy="$run_dir/verification-policy-1.json"
  local request="$run_dir/verification-request-1.json"
  local report="$run_dir/audit-verification.json"
  local log="$run_dir/audit-verification.log"
  local head tree
  head="$(json_field "$packet" headSha)"
  tree="$(git -C "$SINGULAR_ROOT" rev-parse "$head^{tree}")"

  cp "$SINGULAR_TASKS_DIR/TASK-9001.md" "$task_snapshot"
  printf '{"campaign":"legacy"}\n' >"$policy"
  printf 'verification passed\n' >"$log"
  python3 "$SCRIPT_DIR/gate-report.py" create-verification-request \
    --output "$request" \
    --task-id TASK-9001 \
    --run-id "$run_id" \
    --attempt 1 \
    --head-sha "$head" \
    --tree-sha "$tree" \
    --campaign legacy \
    --task-contract "$task_snapshot" \
    --policy-contract "$policy" \
    --suite-id task-contract-gate >/dev/null
  python3 "$SCRIPT_DIR/gate-report.py" create \
    --output "$report" \
    --task-id TASK-9001 \
    --run-id "$run_id" \
    --head-sha "$head" \
    --command true \
    --exit-code 0 \
    --log "$log" \
    --phase audit-verification \
    --workspace-kind disposable \
    --integrity-status verified
  python3 "$SCRIPT_DIR/gate-report.py" bind-verification-result \
    --request "$request" \
    --report "$report" \
    --task-contract "$task_snapshot" \
    --policy-contract "$policy"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["evidence"] = [
    item for item in packet.get("evidence", [])
    if item.get("kind") != "audit-verification"
]
packet["evidence"].append({
    "kind": "audit-verification",
    "ref": "runs/RUN-TEST-9001/audit-verification.json",
})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY
}

write_accept_waiver_records() {
  local run_id="RUN-TEST-9001"
  write_bound_verification
  python3 - "$SINGULAR_RUNS_DIR/$run_id/packet.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    packet = json.load(f)
packet["status"] = "accepted"
packet["nextAction"] = "import into control state and reconcile"
packet.setdefault("evidence", []).append({"kind": "waiver", "ref": "decider:accept-waiver"})
with open(path, "w", encoding="utf-8") as f:
    json.dump(packet, f, indent=2)
    f.write("\n")
PY
  python3 - "$SINGULAR_LEASES_DIR/TASK-9001.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lease = json.load(handle)
lease["status"] = "accepted"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(lease, handle, indent=2)
    handle.write("\n")
PY
  python3 - "$SINGULAR_RUNS_DIR/$run_id/packet.json" \
    "$SINGULAR_RUNS_DIR/$run_id/audit.json" <<'PY'
import json
import sys

packet_path, audit_path = sys.argv[1:3]
with open(packet_path, encoding="utf-8") as handle:
    packet = json.load(handle)
audit = {
    "schema": "singular.orchestration.audit-verdict.v0",
    "taskId": "TASK-9001",
    "runId": "RUN-TEST-9001",
    "branch": "agent/artifact/TASK-9001-test",
    "verdict": "needs-fix",
    "evidenceReviewed": ["reviewed-head-sha:" + packet["headSha"]],
    "commandsRun": [],
    "findings": ["red evidence passed because behavior already existed"],
    "requiredFixes": ["record an explicit waiver"],
    "rationale": "needs waiver",
}
with open(audit_path, "w", encoding="utf-8") as handle:
    json.dump(audit, handle, indent=2)
    handle.write("\n")
PY
  cat >"$SINGULAR_RUNS_DIR/$run_id/decision-audit-needs-fix.json" <<'EOF'
{
  "schema": "singular.orchestration.decider-verdict.v0",
  "failureClass": "audit-needs-fix",
  "taskId": "TASK-9001",
  "runId": "RUN-TEST-9001",
  "campaignBinding": "legacy",
  "action": "accept-waiver",
  "rationale": "Accept already-built coverage with explicit waiver.",
  "params": {
    "waiverType": "non_failing_red_evidence"
  },
  "nextOwner": "l1",
  "confidence": 0.8
}
EOF
  cat >"$SINGULAR_ORCH_DIR/decisions.md" <<'EOF'
# Decisions

### 2026-06-04T00:00:00Z — TASK-9001 — accept

- Run: `RUN-TEST-9001`
- Branch: `agent/artifact/TASK-9001-test`
- Authority: origin
- Rationale: accepted via decider waiver (auditor: needs-fix); gate green

### 2026-06-04T00:00:00Z — TASK-9001 — decide:accept-waiver

- Run: `RUN-TEST-9001`
- Branch: `agent/artifact/TASK-9001-test`
- Authority: decider
- Rationale: audit-needs-fix -> accept-waiver
EOF
}

mark_packet_and_lease_accepted() {
  python3 - "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" \
    "$SINGULAR_LEASES_DIR/TASK-9001.json" <<'PY'
import json
import sys

for path in sys.argv[1:3]:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
    value["status"] = "accepted"
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
PY
}

write_accepted_audit() {
  local audit_run_id="${1:-RUN-TEST-9001}"
  python3 - "$SINGULAR_RUNS_DIR/RUN-TEST-9001/audit.json" "$audit_run_id" \
    "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" <<'PY'
import json
import sys

path, run_id, packet_path = sys.argv[1:4]
with open(packet_path, encoding="utf-8") as handle:
    packet = json.load(handle)
audit = {
    "schema": "singular.orchestration.audit-verdict.v0",
    "taskId": "TASK-9001",
    "runId": run_id,
    "branch": "agent/artifact/TASK-9001-test",
    "verdict": "accepted",
    "evidenceReviewed": ["reviewed-head-sha:" + packet["headSha"]],
    "commandsRun": [],
    "findings": [],
    "requiredFixes": [],
    "rationale": "accepted import fixture",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(audit, handle, indent=2)
    handle.write("\n")
PY
}

test_accepts_existing_packet_and_imports_afterward() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  cat >"$SINGULAR_ROOT/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"target","gateCommand":"true"}
JSON

  local workspace before_fingerprint before_worktrees
  workspace="$(json_field "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" workspace)"
  before_fingerprint="$(workspace_fingerprint "$workspace")"
  before_worktrees="$(worktree_count)"
  python3 - "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" "$workspace" <<'PY'
import json
import shlex
import sys

path, original_workspace = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["commands"].append({
    "cmd": (
        f'test "$PWD" != {shlex.quote(original_workspace)}'
        ' && case "$TURBO_CACHE_DIR:$VITE_CACHE_DIR:$BUN_INSTALL_CACHE_DIR:$TMPDIR"'
        ' in *"$PWD"*) exit 91 ;; esac'
        ' && printf turbo-cache > "$TURBO_CACHE_DIR/acceptance-probe"'
        ' && printf vite-cache > "$VITE_CACHE_DIR/acceptance-probe"'
        ' && printf bun-cache > "$BUN_INSTALL_CACHE_DIR/acceptance-probe"'
    ),
    "exitCode": 0,
    "logRef": ".singular-evidence/regression.log",
})
packet["commands"].append({
    "cmd": (
        "test -f internal/artifact/a.go"
        " && (test -f internal/artifact/a_test.go)"
        " # (attempt-2 green: shell comments remain executable syntax)"
    ),
    "exitCode": 0,
    "logRef": ".singular-evidence/regression.log",
})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY

  "$SCRIPT_DIR/accept-existing-packet.sh" "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" >/tmp/accept-existing-packet.out
  assert_eq "accepted" "$(json_field "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" status)" "packet is accepted"
  assert_eq "accepted" "$(json_field "$SINGULAR_RUNS_DIR/RUN-TEST-9001/audit.json" verdict)" "audit verdict"
  assert_eq "singular.orchestration.audit-verdict.v1" \
    "$(json_field "$SINGULAR_RUNS_DIR/RUN-TEST-9001/audit.json" schema)" \
    "v2 acceptance writes audit-verdict.v1"
  assert_eq "$before_fingerprint" "$(workspace_fingerprint "$workspace")" \
    "original worker workspace remains byte-identical"
  assert_eq "$before_worktrees" "$(worktree_count)" \
    "disposable verification worktree is removed"
  assert_contains "$(sed -n '1,8p' "$SINGULAR_TASKS_DIR/TASK-9001.md")" "Status: accepted" "task status updated"
  assert_eq "accepted" "$(json_field "$SINGULAR_LEASES_DIR/TASK-9001.json" status)" "lease status updated"
  python3 - "$SINGULAR_RUNS_DIR/RUN-TEST-9001" <<'PY'
import hashlib
import json
import pathlib
import sys

run_dir = pathlib.Path(sys.argv[1])
manifest = json.loads((run_dir / "evidence-manifest.json").read_text(encoding="utf-8"))
packet_input = json.loads(
    (run_dir / "accept-existing-packet-input.json").read_text(encoding="utf-8")
)
assert manifest["schema"] == "singular.orchestration.evidence-manifest.v0"
assert manifest["headSha"] == packet_input["headSha"]
assert packet_input["status"] == "needs-review"
assert manifest["checks"]["scope"]["status"] == "passed"
assert manifest["checks"]["secret"]["status"] == "passed"
assert manifest["checks"]["gate"]["status"] == "passed"
assert any(item["name"].startswith("acceptance-rerun-") for item in manifest["commands"])
assert "packet.json" not in {item["ref"] for item in manifest["artifacts"]}
assert "audit.json" not in {item["ref"] for item in manifest["artifacts"]}
for item in manifest["artifacts"]:
    artifact = run_dir / item["ref"]
    assert artifact.is_file(), item["ref"]
    assert hashlib.sha256(artifact.read_bytes()).hexdigest() == item["sha256"]
for check in manifest["checks"].values():
    artifact = run_dir / check["ref"]
    assert hashlib.sha256(artifact.read_bytes()).hexdigest() == check["sha256"]
audit = json.loads((run_dir / "audit.json").read_text(encoding="utf-8"))
assert str(run_dir / "evidence-manifest.json") in audit["evidenceReviewed"]
assert str(run_dir / "evidence-manifest.json") in audit["verificationResults"][0]["evidenceRefs"]
PY

  "$SCRIPT_DIR/import-packet.sh" "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" >/tmp/import-existing-packet.out
  [[ -f "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] || fail "packet imported"
  [[ -f "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.audit.json" ]] || fail "audit sidecar imported"
}

test_rejects_source_mutation_and_preserves_original_workspace() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet workspace before_fingerprint before_worktrees out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  workspace="$(json_field "$packet" workspace)"
  before_fingerprint="$(workspace_fingerprint "$workspace")"
  before_worktrees="$(worktree_count)"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["commands"] = [{
    "cmd": "printf '\\nmutation\\n' >> internal/artifact/a.go",
    "exitCode": 0,
    "logRef": ".singular-evidence/green.log",
}]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "source mutation must be rejected"
  assert_contains "$out" "attempted source mutation" "source-integrity rejection reason"
  assert_eq "needs-review" "$(json_field "$packet" status)" "mutating packet remains unaccepted"
  assert_eq "$before_fingerprint" "$(workspace_fingerprint "$workspace")" \
    "source-mutation attempt never touches original workspace"
  assert_eq "$before_worktrees" "$(worktree_count)" \
    "mutating disposable worktree is discarded"
  [[ ! -f "$SINGULAR_RUNS_DIR/RUN-TEST-9001/audit.json" ]] \
    || fail "source-mutation rejection must not emit an accepted audit"
}

test_rejects_failed_rerun_in_disposable_worktree() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet workspace before_fingerprint before_worktrees out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  workspace="$(json_field "$packet" workspace)"
  before_fingerprint="$(workspace_fingerprint "$workspace")"
  before_worktrees="$(worktree_count)"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["commands"] = [{
    "cmd": "test -f internal/artifact/does-not-exist.go",
    "exitCode": 0,
    "logRef": ".singular-evidence/green.log",
}]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "failed successful-command rerun must be rejected"
  assert_contains "$out" "packet command failed during deterministic acceptance" \
    "failed rerun rejection reason"
  assert_eq "needs-review" "$(json_field "$packet" status)" "failed rerun remains unaccepted"
  assert_eq "$before_fingerprint" "$(workspace_fingerprint "$workspace")" \
    "failed rerun leaves original workspace immutable"
  assert_eq "$before_worktrees" "$(worktree_count)" \
    "failed-rerun disposable worktree is discarded"
  [[ ! -f "$SINGULAR_RUNS_DIR/RUN-TEST-9001/audit.json" ]] \
    || fail "failed rerun must not emit an accepted audit"
}

test_rejects_annotated_command_before_execution() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet workspace before_fingerprint before_worktrees out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  workspace="$(json_field "$packet" workspace)"
  before_fingerprint="$(workspace_fingerprint "$workspace")"
  before_worktrees="$(worktree_count)"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["commands"] = [{
    "cmd": (
        "test -f internal/artifact/a.go"
        " (attempt-2 green: 40 pass, 0 fail)"
    ),
    "exitCode": 0,
    "logRef": ".singular-evidence/green.log",
}]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "annotated packet command must be rejected"
  assert_contains "$out" "commands[0].cmd contains a trailing human annotation" \
    "annotated command contract rejection"
  assert_contains "$out" "rationale or evidence" \
    "annotated command remediation"
  [[ ! -e "$SINGULAR_RUNS_DIR/RUN-TEST-9001/accept-existing-packet-command-0.log" ]] \
    || fail "annotated command reached deterministic bash execution"
  assert_eq "needs-review" "$(json_field "$packet" status)" \
    "annotated command packet remains unaccepted"
  assert_eq "$before_fingerprint" "$(workspace_fingerprint "$workspace")" \
    "annotated command rejection leaves original workspace immutable"
  assert_eq "$before_worktrees" "$(worktree_count)" \
    "annotated command rejection occurs before disposable worktree setup"
}

test_hash_inside_shell_word_does_not_bypass_annotation_rejection() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet workspace before_fingerprint before_worktrees out prefix
  local -a prefixes=("printf x#" "printf '#'" 'printf \#')
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  workspace="$(json_field "$packet" workspace)"
  before_fingerprint="$(workspace_fingerprint "$workspace")"
  before_worktrees="$(worktree_count)"
  for prefix in "${prefixes[@]}"; do
    python3 - "$packet" "$prefix" <<'PY'
import json
import sys

path, prefix = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["commands"] = [{
    "cmd": prefix + " (attempt-2 green: 40 pass, 0 fail)",
    "exitCode": 0,
    "logRef": ".singular-evidence/green.log",
}]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY
    local rc=0
    out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$packet" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] \
      || fail "non-comment hash form must not bypass annotation rejection: $prefix"
    assert_contains "$out" "commands[0].cmd contains a trailing human annotation" \
      "non-comment hash annotation rejection: $prefix"
    [[ ! -e "$SINGULAR_RUNS_DIR/RUN-TEST-9001/accept-existing-packet-command-0.log" ]] \
      || fail "non-comment hash command reached deterministic bash execution: $prefix"
  done
  assert_eq "needs-review" "$(json_field "$packet" status)" \
    "non-comment hash packet remains unaccepted"
  assert_eq "$before_fingerprint" "$(workspace_fingerprint "$workspace")" \
    "non-comment hash rejection leaves original workspace immutable"
  assert_eq "$before_worktrees" "$(worktree_count)" \
    "non-comment hash rejection occurs before disposable worktree setup"
}

test_rejects_whitespace_only_packet_command() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["commands"][1]["cmd"] = " \t "
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "whitespace-only packet command must be rejected"
  assert_contains "$out" "commands[1].cmd must be non-empty executable shell text" \
    "empty command contract rejection"
  [[ ! -e "$SINGULAR_RUNS_DIR/RUN-TEST-9001/accept-existing-packet-command-1.log" ]] \
    || fail "empty command reached deterministic bash execution"
}

test_required_bootstrap_failure_blocks_acceptance() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet workspace before_fingerprint before_worktrees out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  workspace="$(json_field "$packet" workspace)"
  before_fingerprint="$(workspace_fingerprint "$workspace")"
  before_worktrees="$(worktree_count)"
  out="$(SINGULAR_BOOTSTRAP_JSON='{"command":"exit 17","required":true}' \
    "$SCRIPT_DIR/accept-existing-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "required bootstrap failure must block acceptance"
  assert_contains "$out" "required deterministic acceptance bootstrap failed" \
    "bootstrap infrastructure rejection reason"
  assert_eq "needs-review" "$(json_field "$packet" status)" "bootstrap failure remains unaccepted"
  assert_eq "$before_fingerprint" "$(workspace_fingerprint "$workspace")" \
    "bootstrap failure leaves original workspace immutable"
  assert_eq "$before_worktrees" "$(worktree_count)" \
    "bootstrap-failure disposable worktree is discarded"
  [[ ! -f "$SINGULAR_RUNS_DIR/RUN-TEST-9001/audit.json" ]] \
    || fail "bootstrap failure must not emit an accepted audit"
}

test_imports_accept_waiver_packet_and_integrates_eligibly() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  write_accept_waiver_records

  "$SCRIPT_DIR/import-packet.sh" "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" >/tmp/import-waiver-packet.out
  [[ -f "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] || fail "waiver packet imported"
  [[ -f "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.audit.json" ]] || fail "waiver audit sidecar imported"
  assert_eq "needs-fix" "$(json_field "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.audit.json" verdict)" "waiver preserves original audit verdict"
  assert_contains "$(cat /tmp/import-waiver-packet.out)" "acceptance: accepted-waiver" "waiver import mode recorded"

  local out
  out="$(SINGULAR_DEFAULT_GATE_CMD=true "$SCRIPT_DIR/integrate.sh" --dry-run --task TASK-9001)"
  assert_contains "$out" "eligible: TASK-9001" "waiver packet is integration-eligible"
}

test_rejects_already_imported_task() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mkdir -p "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001"
  cp "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json"
  local out rc=0
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "duplicate import must be rejected"
  assert_contains "$out" "already imported" "duplicate rejection reason"
}

test_rejects_head_mismatch() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  python3 - "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["headSha"] = "deadbeef"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out rc=0
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "head mismatch must be rejected"
  assert_contains "$out" "does not match branch head" "head mismatch reason"
}

test_rejects_scope_violation() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  worktree="$(json_field "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" workspace)"
  printf 'package artifact\n\nconst forbiddenFixture = true\n' >"$worktree/internal/artifact/doc.go"
  git -C "$worktree" add internal/artifact/doc.go
  git -C "$worktree" -c user.name=test -c user.email=test@example.local commit -q -m "scope violation"
  head="$(git -C "$worktree" rev-parse HEAD)"
  python3 - "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" "$head" <<'PY'
import json
import sys
path, head = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["headSha"] = head
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out rc=0
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "scope violation must be rejected"
  assert_contains "$out" "scope check failed" "scope failure reason"
}

test_accept_existing_rejects_storage_proof_without_marked_red_guard() {
  with_fixture
  write_storage_proof_task
  write_worker_branch_and_packet
  local out rc=0
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "storage proof existing packet without marked red guard must be rejected"
  assert_contains "$out" "logRef ending in -skip-guard-red" "storage proof guard rejection reason"
}

test_import_rejects_storage_proof_without_marked_red_guard() {
  with_fixture
  write_storage_proof_task
  write_worker_branch_and_packet
  write_accept_waiver_records
  local out rc=0
  out="$("$SCRIPT_DIR/import-packet.sh" "$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "storage proof import without marked red guard must be rejected"
  assert_contains "$out" "logRef ending in -skip-guard-red" "storage proof import guard rejection reason"
}

test_import_rejects_obsolete_campaign_binding() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet lease epoch out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  lease="$SINGULAR_LEASES_DIR/TASK-9001.json"
  epoch="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  mkdir -p "$SINGULAR_STATE_DIR/campaign"
  printf '%s\n' "$epoch" >"$SINGULAR_STATE_DIR/campaign/EPOCH"
  python3 - "$packet" "$lease" <<'PY'
import json
import sys

packet_path, lease_path = sys.argv[1:3]
with open(packet_path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet.setdefault("evidence", []).append({
    "kind": "campaign-binding",
    "ref": "campaign:obsolete:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:epoch:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
})
packet["status"] = "accepted"
with open(packet_path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")

with open(lease_path, encoding="utf-8") as handle:
    lease = json.load(handle)
lease["campaignBinding"] = packet["evidence"][-1]["ref"]
lease["status"] = "accepted"
with open(lease_path, "w", encoding="utf-8") as handle:
    json.dump(lease, handle, indent=2)
    handle.write("\n")
PY

  out="$("$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "obsolete campaign packet must not import"
  assert_contains "$out" "campaign binding does not match" \
    "obsolete campaign import rejection reason"
  [[ ! -e "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] \
    || fail "obsolete campaign packet became authoritative"
  [[ ! -e "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.audit.json" ]] \
    || fail "obsolete campaign audit sidecar was published"
  [[ ! -f "$SINGULAR_EVENTS_FILE" ]] \
    || [[ "$(cat "$SINGULAR_EVENTS_FILE")" != *'"packet.imported"'* ]] \
    || fail "obsolete campaign import emitted a success event"
}

test_import_rejects_nonaccepted_packet() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  out="$(SINGULAR_REQUIRE_AUDIT=0 "$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "needs-review packet must not import"
  assert_contains "$out" "packet status must be accepted" \
    "nonaccepted packet import rejection reason"
  [[ ! -e "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] \
    || fail "nonaccepted packet became authoritative"
}

test_import_rejects_unsafe_run_id() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  local packet lease out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  lease="$SINGULAR_LEASES_DIR/TASK-9001.json"
  mark_packet_and_lease_accepted
  python3 - "$packet" "$lease" <<'PY'
import json
import sys

for path in sys.argv[1:3]:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
    value["runId"] = "../ESCAPE"
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
PY
  out="$(SINGULAR_REQUIRE_AUDIT=0 "$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "path-traversing runId must not import"
  assert_contains "$out" "one safe path component" "unsafe runId rejection reason"
  [[ ! -e "$SINGULAR_ORCH_DIR/packets/imported/ESCAPE.json" ]] \
    || fail "unsafe runId escaped the task import directory"
}

test_import_rejects_cross_run_lease() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  local packet lease out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  lease="$SINGULAR_LEASES_DIR/TASK-9001.json"
  python3 - "$lease" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lease = json.load(handle)
lease["runId"] = "RUN-OTHER"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(lease, handle, indent=2)
    handle.write("\n")
PY
  out="$(SINGULAR_REQUIRE_AUDIT=0 "$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "cross-run lease must not authorize packet import"
  assert_contains "$out" "lease runId does not match packet" \
    "cross-run lease rejection reason"
}

test_import_rejects_cross_run_audit() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  write_accepted_audit RUN-OTHER
  local packet out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  out="$("$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "cross-run audit must not authorize packet import"
  assert_contains "$out" "audit runId does not match packet" \
    "cross-run audit rejection reason"
  [[ ! -e "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] \
    || fail "cross-run audit authorized a packet"
}

test_import_rejects_invalid_audit_policy_value() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  local packet out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  out="$(SINGULAR_REQUIRE_AUDIT=true "$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "invalid audit policy value must fail closed"
  assert_contains "$out" "must be exactly 0 or 1" \
    "invalid audit policy rejection reason"
}

test_import_idempotence_requires_complete_sidecar() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  write_accepted_audit
  local packet dest out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  dest="$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json"
  mkdir -p "$(dirname "$dest")"
  cp "$packet" "$dest"
  out="$("$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "packet-only import must not be idempotent success"
  assert_contains "$out" "incomplete or has different packet/audit content" \
    "incomplete idempotent publication rejection reason"
}

test_import_rejects_audit_for_stale_head() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  write_accepted_audit
  local packet workspace new_head out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  workspace="$(json_field "$packet" workspace)"
  printf 'package artifact\n\nconst secondRevision = true\n' >"$workspace/internal/artifact/a.go"
  git -C "$workspace" add internal/artifact/a.go
  git -C "$workspace" -c user.name=test -c user.email=test@example.local \
    commit -q -m "TASK-9001 second revision"
  new_head="$(git -C "$workspace" rev-parse HEAD)"
  python3 - "$packet" "$new_head" <<'PY'
import json
import sys

path, head = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["headSha"] = head
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY
  out="$("$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "audit for an earlier branch head must not authorize import"
  assert_contains "$out" "exactly one reviewed-head-sha marker matching" \
    "stale reviewed head rejection reason"
  [[ ! -e "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] \
    || fail "stale audit authorized a newer packet head"
}

test_import_rejects_revision_expression_head() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  local packet out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    packet = json.load(handle)
packet["headSha"] += "^{commit}"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle, indent=2)
    handle.write("\n")
PY
  out="$(SINGULAR_REQUIRE_AUDIT=0 "$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "Git revision expressions must not be accepted as packet head identity"
  assert_contains "$out" "does not match branch head" "revision-expression head rejection"
}

test_import_rejects_symlinked_run_directory() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  local packet real_run out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  real_run="$FIXTURE_TMP/escaped-run"
  mv "$SINGULAR_RUNS_DIR/RUN-TEST-9001" "$real_run"
  ln -s "$real_run" "$SINGULAR_RUNS_DIR/RUN-TEST-9001"
  out="$(SINGULAR_REQUIRE_AUDIT=0 "$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "symlinked run directory must not be imported"
  assert_contains "$out" "run directory must be a real directory" \
    "symlinked run directory rejection reason"
}

test_import_rejects_symlinked_destination_paths() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  write_accepted_audit
  local packet task_dest dest audit_dest outside out rc=0
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  task_dest="$SINGULAR_ORCH_DIR/packets/imported/TASK-9001"
  dest="$task_dest/RUN-TEST-9001.json"
  audit_dest="$task_dest/RUN-TEST-9001.audit.json"
  outside="$FIXTURE_TMP/outside-import"
  mkdir -p "$outside"
  ln -s "$outside" "$task_dest"
  out="$("$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "symlinked task destination must not be imported"
  assert_contains "$out" "unsafe import destination" "symlinked destination directory rejection"
  [[ ! -e "$outside/RUN-TEST-9001.json" ]] || fail "packet escaped through destination symlink"

  rm "$task_dest"
  mkdir -p "$task_dest"
  ln -s "$packet" "$dest"
  ln -s "$SINGULAR_RUNS_DIR/RUN-TEST-9001/audit.json" "$audit_dest"
  rc=0
  out="$("$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "symlinked packet destination must not be idempotent success"
  assert_contains "$out" "packet destination must be a regular non-symlink file" \
    "symlinked packet destination rejection"
  rm "$dest"
  rc=0
  out="$("$SCRIPT_DIR/import-packet.sh" "$packet" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "symlinked audit destination must not be accepted"
  assert_contains "$out" "audit destination must be a regular non-symlink file" \
    "symlinked audit destination rejection"
}

test_import_rejects_waiver_decision_change_during_validation() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  write_accept_waiver_records
  local packet holder_ready holder_release holder_pid import_pid out_file git_lock rc=0 i
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  holder_ready="$FIXTURE_TMP/waiver-holder-ready"
  holder_release="$FIXTURE_TMP/waiver-holder-release"
  out_file="$FIXTURE_TMP/import-waiver-race.out"
  git_lock="$SINGULAR_STATE_DIR/locks/git-op.lock"
  (
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib.sh"
    singular_campaign_lock_acquire
    : >"$holder_ready"
    while [[ ! -e "$holder_release" ]]; do sleep 0.01; done
    singular_campaign_lock_release
  ) &
  holder_pid=$!
  i=0
  while [[ "$i" -lt 500 && ! -e "$holder_ready" ]]; do
    sleep 0.01
    i=$((i + 1))
  done
  [[ -e "$holder_ready" ]] || fail "waiver campaign lock holder did not start"
  "$SCRIPT_DIR/import-packet.sh" "$packet" >"$out_file" 2>&1 &
  import_pid=$!
  i=0
  while [[ "$i" -lt 500 && ! -d "$git_lock" ]]; do
    sleep 0.01
    i=$((i + 1))
  done
  [[ -d "$git_lock" ]] || fail "waiver import did not reach final publication lock"
  rm "$SINGULAR_RUNS_DIR/RUN-TEST-9001/decision-audit-needs-fix.json"
  : >"$holder_release"
  wait "$holder_pid"
  wait "$import_pid" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "deleted accept-waiver decision must fail publication CAS"
  assert_contains "$(cat "$out_file")" \
    "accept-waiver decision changed while packet import was being validated" \
    "waiver-decision CAS rejection reason"
  [[ ! -e "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] \
    || fail "packet imported after its waiver authority disappeared"
}

test_import_rejects_audit_appearing_during_validation() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mark_packet_and_lease_accepted
  local packet holder_ready holder_release holder_pid import_pid out_file git_lock rc=0 i
  packet="$SINGULAR_RUNS_DIR/RUN-TEST-9001/packet.json"
  holder_ready="$FIXTURE_TMP/campaign-holder-ready"
  holder_release="$FIXTURE_TMP/campaign-holder-release"
  out_file="$FIXTURE_TMP/import-race.out"
  git_lock="$SINGULAR_STATE_DIR/locks/git-op.lock"
  (
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib.sh"
    singular_campaign_lock_acquire
    : >"$holder_ready"
    while [[ ! -e "$holder_release" ]]; do sleep 0.01; done
    singular_campaign_lock_release
  ) &
  holder_pid=$!
  i=0
  while [[ "$i" -lt 500 && ! -e "$holder_ready" ]]; do
    sleep 0.01
    i=$((i + 1))
  done
  [[ -e "$holder_ready" ]] || fail "campaign lock holder did not start"
  SINGULAR_REQUIRE_AUDIT=0 "$SCRIPT_DIR/import-packet.sh" "$packet" >"$out_file" 2>&1 &
  import_pid=$!
  i=0
  while [[ "$i" -lt 500 && ! -d "$git_lock" ]]; do
    sleep 0.01
    i=$((i + 1))
  done
  [[ -d "$git_lock" ]] || fail "import did not reach final publication lock"
  printf '{}\n' >"$SINGULAR_RUNS_DIR/RUN-TEST-9001/audit.json"
  : >"$holder_release"
  wait "$holder_pid"
  wait "$import_pid" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "audit appearing after validation must fail publication"
  assert_contains "$(cat "$out_file")" "audit appeared while packet import was being validated" \
    "late audit appearance rejection reason"
  [[ ! -e "$SINGULAR_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] \
    || fail "late unvalidated audit accompanied an authoritative packet"
}

test_accepts_existing_packet_and_imports_afterward
test_rejects_source_mutation_and_preserves_original_workspace
test_rejects_failed_rerun_in_disposable_worktree
test_rejects_annotated_command_before_execution
test_hash_inside_shell_word_does_not_bypass_annotation_rejection
test_rejects_whitespace_only_packet_command
test_required_bootstrap_failure_blocks_acceptance
test_imports_accept_waiver_packet_and_integrates_eligibly
test_rejects_already_imported_task
test_rejects_head_mismatch
test_rejects_scope_violation
test_accept_existing_rejects_storage_proof_without_marked_red_guard
test_import_rejects_storage_proof_without_marked_red_guard
test_import_rejects_obsolete_campaign_binding
test_import_rejects_nonaccepted_packet
test_import_rejects_unsafe_run_id
test_import_rejects_cross_run_lease
test_import_rejects_cross_run_audit
test_import_rejects_invalid_audit_policy_value
test_import_idempotence_requires_complete_sidecar
test_import_rejects_audit_for_stale_head
test_import_rejects_revision_expression_head
test_import_rejects_symlinked_run_directory
test_import_rejects_symlinked_destination_paths
test_import_rejects_waiver_decision_change_during_validation
test_import_rejects_audit_appearing_during_validation

echo "accept-existing-packet tests passed"
