#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
CLI="$ENGINE_HOME/cli/singular"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing file $1"; }
assert_dir() { [[ -d "$1" ]] || fail "$2: missing dir $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

json_file_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
path, field = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    value = json.load(f)
for part in field.split("."):
    value = value[part]
print(value)
PY
}

new_git_repo() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" checkout -q -b main
  printf 'seed\n' >"$root/README.md"
  git -C "$root" add README.md
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

test_init_scaffolds_fresh_repo_and_reconcile_apply_is_noop_safe() {
  local tmp repo out rc
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"

  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" init 2>&1)"
  assert_contains "$out" "singular init ->" "init reports target repo"

  assert_dir "$repo/docs/orchestration/packets/imported" "init packet import scaffold"
  assert_dir "$repo/docs/orchestration/areas/core" "init starter area scaffold"
  assert_file "$repo/docs/orchestration/decisions.md" "init decisions log"
  assert_file "$repo/docs/orchestration/project-state.md" "init project snapshot"
  assert_file "$repo/docs/orchestration/tasks/TEMPLATE.md" "init task template"
  assert_file "$repo/docs/orchestration/planner-contract.md" "init planner contract"
  for schema in audit-verdict decider-verdict gate-result state-packet task-batch dag l1-lease; do
    assert_file "$repo/schemas/orchestration/$schema.v0.schema.json" "init schema mirror $schema"
  done
  for entry in ".singular-state/" ".worktrees/" ".singular-evidence/" ".singular-cache/"; do
    grep -qxF "$entry" "$repo/.gitignore" || fail "init gitignore missing $entry"
  done

  git -C "$repo" checkout -q -b agent/integration
  set +e
  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" reconcile --apply 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "fresh reconcile --apply"
  assert_contains "$out" "singular origin reconcile (apply)" "fresh reconcile prints summary"
  assert_contains "$(cat "$repo/docs/orchestration/project-state.md")" "Latest Reconcile Snapshot" "fresh reconcile writes project snapshot"
}

# PMGO-006: an operator who already ran `init` must be able to reach a verified
# stopped state without undoing anything. Every ladder step that init already
# satisfied has to report itself as satisfied — not redo the work — and the
# config init wrote must come out byte-for-byte identical.
test_setup_after_init_is_a_clean_noop_ladder() {
  local tmp repo out rc before_config before_dag
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"

  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" init 2>&1)"
  assert_contains "$out" "singular init ->" "init runs before setup"
  before_config="$(shasum -a 256 "$repo/singular.config.json" | awk '{print $1}')"
  before_dag="$(shasum -a 256 "$repo/docs/orchestration/dag.v0.json" | awk '{print $1}')"

  # doctor probes the SELECTED provider's real executable, so pin a stub one
  # through the operator override lib.sh sources last; otherwise this test would
  # assert facts about whichever CLI happens to be authenticated on the host.
  mkdir -p "$repo/.singular-state" "$tmp/bin"
  cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.0.0-stub" ;;
  *) echo "stub" ;;
esac
exit 0
SH
  chmod +x "$tmp/bin/codex"
  cat >"$repo/.singular-state/config.local.sh" <<SH
export SINGULAR_RUNNER="$SCRIPT_DIR/codex-run.sh"
export SINGULAR_CODEX_BIN="$tmp/bin/codex"
SH

  set +e
  out="$(cd "$repo" && HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" setup --no-test 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "setup after init succeeds ($out)"
  assert_contains "$out" "singular.config.json exists — init not re-run" "setup does not re-scaffold"
  assert_contains "$out" ".singular-version present" "setup keeps the pin init wrote"
  assert_contains "$out" "matches engine schema — nothing to migrate" "setup migrates nothing"
  assert_not_contains "$out" "singular init ->" "setup did not re-run init"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^Next: ')" "1" "setup prints exactly one next action"
  assert_file "$repo/.singular-state/STOP" "setup leaves the repository stopped"
  assert_eq "$(json_file_field "$repo/.singular-state/setup/state.json" state)" "validated" \
    "setup reaches validated without a regression run"
  assert_eq "$(shasum -a 256 "$repo/singular.config.json" | awk '{print $1}')" "$before_config" \
    "setup left singular.config.json byte-identical"
  assert_eq "$(shasum -a 256 "$repo/docs/orchestration/dag.v0.json" | awk '{print $1}')" "$before_dag" \
    "setup left the DAG byte-identical"
}

test_v0_to_v2_migration_backfills_scaffold_rebrands_and_syncs_contracts() {
  local tmp repo out
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  cat >"$repo/singular.config.json" <<'JSON'
{
  "schemaVersion": "v0",
  "engineVersion": "0.3.0",
  "targetBranch": "agent/integration",
  "gateCommand": "true",
  "areas": {},
  "env": {
    "PMGO_COMPAT_MARKER": "pmgo.orchestration.decider-verdict.v0"
  }
}
JSON
  mkdir -p "$repo/docs/orchestration/prompts"
  printf 'legacy schema pmgo.orchestration.state-packet.v0\n' >"$repo/docs/orchestration/prompts/legacy.md"
  git -C "$repo" add singular.config.json docs/orchestration/prompts/legacy.md
  git -C "$repo" -c user.name=test -c user.email=test@example.local commit -q -m orchestration-v0

  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate 2>&1)"
  assert_contains "$out" "run   v0-to-v1.sh (v0 -> v1)" "migration announces v1 step"
  assert_contains "$out" "run   v1-to-v2.sh (v1 -> v2)" "migration announces v2 step"
  assert_eq "$(json_file_field "$repo/singular.config.json" schemaVersion)" "v2" "migration advances schemaVersion"
  grep -q 'singular.orchestration.decider-verdict.v0' "$repo/singular.config.json" || fail "migration did not rebrand config namespace"
  grep -q 'singular.orchestration.state-packet.v0' "$repo/docs/orchestration/prompts/legacy.md" || fail "migration did not rebrand orchestration namespace"
  assert_file "$repo/docs/orchestration/project-state.md" "migration project-state scaffold"
  assert_dir "$repo/docs/orchestration/packets/imported" "migration packet import scaffold"
  assert_file "$repo/schemas/orchestration/audit-verdict.v1.schema.json" "migration v1 audit contract"
  assert_file "$repo/schemas/orchestration/gate-result.v1.schema.json" "migration v1 gate contract"

  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate 2>&1)"
  assert_contains "$out" "up to date, nothing to do" "migration is idempotent after v2"
}

write_missing_branch_fixture() {
  local repo="$1" packet_dir="$1/docs/orchestration/packets/imported/TASK-0001"
  local run_dir="$1/.singular-state/runs/RUN-MISSING"
  local head tree
  mkdir -p "$repo/docs/orchestration/tasks" "$packet_dir" \
    "$repo/.singular-state/leases" "$run_dir"
  cat >"$repo/docs/orchestration/decisions.md" <<'EOF'
# Decisions

## Decision Log
EOF
  cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Missing branch fixture

Status: accepted
Area: core
Target branch: `target`
Worker branch: `agent/missing/TASK-0001`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise missing branch integration handling.

## Scope

Owned files:

- `README.md`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
EOF
  git -C "$repo" add docs/orchestration/decisions.md docs/orchestration/tasks/TASK-0001.md
  git -C "$repo" -c user.name=test -c user.email=test@example.local \
    commit -q -m fixture-contract
  # Keep the accepted commit object available while deleting its branch. Using
  # target HEAD here makes the candidate an ancestor and exercises restart
  # proof handling instead of the missing-ref recovery path.
  git -C "$repo" checkout -q -b agent/missing/TASK-0001
  printf 'accepted candidate\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.local \
    commit -q -m accepted-candidate
  head="$(git -C "$repo" rev-parse HEAD)"
  tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
  cp "$repo/docs/orchestration/tasks/TASK-0001.md" \
    "$run_dir/verification-task-contract-1.md"
  printf '%s\n' '{"campaign":"legacy","policy":"legacy"}' \
    >"$run_dir/verification-policy-1.json"
  python3 "$SCRIPT_DIR/gate-report.py" create-verification-request \
    --output "$run_dir/verification-request-1.json" --task-id TASK-0001 \
    --run-id RUN-MISSING --attempt 1 --head-sha "$head" --tree-sha "$tree" \
    --campaign legacy --task-contract "$run_dir/verification-task-contract-1.md" \
    --policy-contract "$run_dir/verification-policy-1.json" \
    --suite-id task-contract-gate >/dev/null
  (cd "$repo" && env \
    SINGULAR_ROOT="$repo" \
    SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
    SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_JSON_CONFIG_FILE=/dev/null \
    SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
    bash "$SCRIPT_DIR/gate-check.sh" RUN-MISSING --task-id TASK-0001 \
      --verification-request "$run_dir/verification-request-1.json" \
      --task-contract "$run_dir/verification-task-contract-1.md" \
      --policy-contract "$run_dir/verification-policy-1.json" --attempt 1) >/dev/null
  mv "$run_dir/gate-report.json" "$run_dir/audit-verification.json"
  git -C "$repo" checkout -q target
  git -C "$repo" branch -D agent/missing/TASK-0001 >/dev/null

  python3 - "$packet_dir/RUN-MISSING.json" "$head" <<'PY'
import json
import sys
path, head = sys.argv[1:3]
packet = {
    "schema": "singular.orchestration.state-packet.v0",
    "packetId": "RUN-MISSING",
    "runId": "RUN-MISSING",
    "taskId": "TASK-0001",
    "area": "core",
    "role": "l2-developer",
    "status": "accepted",
    "baseRef": "target",
    "branch": "agent/missing/TASK-0001",
    "headSha": head,
    "workspace": "/tmp/missing",
    "ownedFiles": ["README.md"],
    "changedFiles": ["README.md"],
    "commands": [],
    "tests": [],
    "evidence": [{"kind": "audit-verification", "ref": "runs/RUN-MISSING/audit-verification.json"}],
    "blockers": [],
    "nextAction": "integrate",
    "createdAt": "2026-01-01T00:00:00Z",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(packet, f, indent=2)
    f.write("\n")
PY
  python3 - "$packet_dir/RUN-MISSING.audit.json" "$head" <<'PY'
import json
import sys
head = sys.argv[2]
audit = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": "RUN-MISSING",
    "branch": "agent/missing/TASK-0001",
    "verdict": "accepted",
    "evidenceReviewed": [
        "audit-verification.json",
        "reviewed-head-sha:" + head,
    ],
    "verificationResults": [{
        "status": "passed",
        "command": "true",
        "exitCode": 0,
        "evidenceRefs": ["audit-verification.json"],
        "rationale": "host-bound missing-branch fixture gate",
    }],
    "commandsRun": [],
    "findings": [],
    "requiredFixes": [],
    "rationale": "fixture accepted",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(audit, f, indent=2)
    f.write("\n")
PY
  SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_LEASES_DIR="$repo/.singular-state/leases" SINGULAR_TARGET_BRANCH=target \
    bash -c 'source "$0/lib.sh"; singular_lease_write TASK-0001 agent/missing/TASK-0001 core l2 "README.md" accepted RUN-MISSING "" target "" "[\"README.md\"]" "[]"' "$SCRIPT_DIR"
}

test_integrate_retains_and_suppresses_missing_branch_until_restored() {
  local tmp repo out out2 out3 out4 lease decisions events failures head recovery
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  git -C "$repo" checkout -q -b target
  write_missing_branch_fixture "$repo"

  out="$(SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --run-id RUN-MISSING-INTEG 2>&1)"
  assert_contains "$out" "skip TASK-0001: branch missing" "first integrate reports missing branch"
  assert_eq "$(json_file_field "$repo/.singular-state/leases/TASK-0001.json" status)" "accepted" \
    "missing branch preserves accepted lease authority"
  assert_eq "$(json_file_field "$repo/.singular-state/leases/TASK-0001.json" acceptedCandidate.state)" \
    "integration-failed" "missing branch retains actionable candidate state"
  grep -q '^Status: accepted$' "$repo/docs/orchestration/tasks/TASK-0001.md" \
    || fail "missing branch changed accepted task authority"
  assert_contains "$(cat "$repo/docs/orchestration/decisions.md")" "decide:escalate-parked" "missing branch records parked decision"
  failures="$(python3 - "$repo/.singular-state/leases/TASK-0001.json" <<'PY'
import json, sys
candidate = json.load(open(sys.argv[1], encoding="utf-8"))["acceptedCandidate"]
assert candidate["failures"][0]["failureClass"] == "branch-missing", candidate
assert "restore" in candidate["nextAction"], candidate
print(len(candidate["failures"]))
PY
)"
  assert_eq "$failures" "1" "first missing branch publishes one durable failure"
  decisions="$(grep -c 'decide:escalate-parked' "$repo/docs/orchestration/decisions.md")"
  events="$(grep -c '"type":"integration.parked"' "$repo/.singular-state/events.ndjson")"
  recovery="$(grep -c '"type":"recovery.action"' "$repo/.singular-state/events.ndjson")"

  # Unrelated target progress does not change the missing ref dependency and
  # therefore must not republish the same recovery decision on the next cycle.
  printf 'unrelated target progress\n' >"$repo/unrelated.txt"
  git -C "$repo" add unrelated.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.local \
    commit -q -m unrelated-target-progress

  out2="$(SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --run-id RUN-MISSING-INTEG2 2>&1)"
  assert_contains "$out2" "unchanged failed integration" "unchanged missing branch is suppressed"
  assert_not_contains "$out2" "branch missing (" "unchanged cycle does not republish missing-branch handling"
  assert_eq "$(grep -c 'decide:escalate-parked' "$repo/docs/orchestration/decisions.md")" "$decisions" \
    "unchanged cycle publishes no duplicate decision"
  assert_eq "$(grep -c '"type":"integration.parked"' "$repo/.singular-state/events.ndjson")" "$events" \
    "unchanged cycle publishes no duplicate parked event"
  assert_eq "$(grep -c '"type":"recovery.action"' "$repo/.singular-state/events.ndjson")" "$recovery" \
    "unchanged cycle publishes no duplicate recovery row"

  lease="$(shasum -a 256 "$repo/.singular-state/leases/TASK-0001.json" | awk '{print $1}')"
  decisions="$(shasum -a 256 "$repo/docs/orchestration/decisions.md" | awk '{print $1}')"
  events="$(shasum -a 256 "$repo/.singular-state/events.ndjson" | awk '{print $1}')"

  out3="$(SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --task TASK-0001 --dry-run 2>&1)"
  assert_contains "$out3" "skip TASK-0001: branch missing" "dry-run reports current missing dependency"
  assert_eq "$(shasum -a 256 "$repo/.singular-state/leases/TASK-0001.json" | awk '{print $1}')" "$lease" \
    "dry-run does not mutate retained candidate"
  assert_eq "$(shasum -a 256 "$repo/docs/orchestration/decisions.md" | awk '{print $1}')" "$decisions" \
    "dry-run does not publish a decision"
  assert_eq "$(shasum -a 256 "$repo/.singular-state/events.ndjson" | awk '{print $1}')" "$events" \
    "dry-run does not publish an integration event"

  head="$(json_file_field "$repo/.singular-state/leases/TASK-0001.json" acceptedCandidate.headSha)"
  git -C "$repo" branch agent/missing/TASK-0001 "$head"
  out4="$(SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_DEFAULT_GATE_CMD=true SINGULAR_AUTO_PROMOTE_GATES=0 \
    bash "$SCRIPT_DIR/integrate.sh" --task TASK-0001 --run-id RUN-MISSING-RESTORED 2>&1)"
  assert_contains "$out4" "INTEGRATED TASK-0001" "restoring exact branch permits integration"
  assert_eq "$(json_file_field "$repo/.singular-state/leases/TASK-0001.json" status)" "integrated" \
    "restored branch completes retained candidate"
}

test_l1_drive_provisions_gitignored_files_and_allowlisted_env() {
  local tmp repo runner out rc
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  git -C "$repo" checkout -q -b target
  mkdir -p "$repo/docs/orchestration/prompts" "$repo/docs/orchestration/tasks" "$repo/src"
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$repo/docs/orchestration/prompts/l2-test-first-developer.md"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$repo/docs/orchestration/prompts/auditor.md"
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$repo/docs/orchestration/prompts/decider.md"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n.env.local\n' >"$repo/.gitignore"
  cat >"$repo/.env.local" <<'EOF'
LOCAL_ONLY=present
EOF
  cat >"$repo/strict-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
test -f .env.local
test -f "$SINGULAR_WORKTREE_ENV_FILE"
. "$SINGULAR_WORKTREE_ENV_FILE"
test "${PUBLIC_ALLOWED:-}" = ok
test -z "${SECRET_DENIED:-}"
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
  chmod +x "$repo/strict-gate.sh"
  cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Provisioning fixture

Status: ready
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-0001-provisioning`
Test policy: `strict_test_first`
Gate command: `bash strict-gate.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Write the generated fixture file.

## Scope

Owned files:

- `src/generated.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Gate can read provisioned file and allowlisted env.
EOF
  git -C "$repo" add .gitignore docs/orchestration src strict-gate.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.local commit -q -m target-setup
  cat >"$repo/singular.config.json" <<JSON
{
  "schemaVersion": "v2",
  "targetBranch": "target",
  "gateCommand": "true",
  "provisionFiles": [
    {"source": ".env.local", "target": ".env.local", "required": true}
  ],
  "envAllowlist": ["PUBLIC_*"]
}
JSON
  runner="$tmp/runner.sh"
  cat >"$runner" <<'SH'
#!/usr/bin/env bash
level=""; out=""; chdir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C|--worktree) chdir="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file|--run-id|--session-meta|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  mkdir -p "$chdir/src" "$chdir/.singular-evidence"
  printf 'generated\n' >"$chdir/src/generated.txt"
  printf 'red\n' >"$chdir/.singular-evidence/red.log"
  printf 'green\n' >"$chdir/.singular-evidence/green.log"
  printf 'regression\n' >"$chdir/.singular-evidence/regression.log"
  python3 - "$out" <<'PY'
import json
import sys
packet = {
    "schema": "singular.orchestration.state-packet.v0",
    "packetId": "p",
    "runId": "r",
    "taskId": "TASK-0001",
    "area": "core",
    "role": "l2-developer",
    "status": "needs-review",
    "baseRef": "target",
    "branch": "agent/core/TASK-0001-provisioning",
    "headSha": "uncommitted",
    "workspace": "/tmp",
    "ownedFiles": ["src/generated.txt"],
    "changedFiles": ["src/generated.txt"],
    "commands": [{"cmd": "true", "exitCode": 0}],
    "tests": [{"name": "fixture", "phase": "red", "status": "fail", "logRef": ".singular-evidence/red.log"},
              {"name": "fixture", "phase": "green", "status": "pass", "logRef": ".singular-evidence/green.log"}],
    "evidence": [{"kind": "red", "ref": ".singular-evidence/red.log"}],
    "blockers": [],
    "nextAction": "audit",
    "createdAt": "2026-01-01T00:00:00Z",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(packet, f)
PY
  exit 0
fi
python3 - "$out" <<'PY'
import json
import sys
audit = {
    "schema": "singular.orchestration.audit-verdict.v0",
    "taskId": "TASK-0001",
    "runId": "r",
    "branch": "agent/core/TASK-0001-provisioning",
    "verdict": "accepted",
    "evidenceReviewed": [],
    "commandsRun": [],
    "findings": [],
    "requiredFixes": [],
    "rationale": "accepted",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(audit, f)
PY
SH
  chmod +x "$runner"

  set +e
  out="$(PUBLIC_ALLOWED=ok SECRET_DENIED=bad SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
    SINGULAR_STATE_DIR="$repo/.singular-state" SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" SINGULAR_WORKTREES_DIR="$repo/.worktrees" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$runner" SINGULAR_MAX_RETRIES=0 \
    bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "provisioned l1-drive accepts ($out)"
  assert_contains "$out" "ACCEPTED: TASK-0001" "provisioned task accepted"
}

test_init_scaffolds_fresh_repo_and_reconcile_apply_is_noop_safe
test_setup_after_init_is_a_clean_noop_ladder
test_v0_to_v2_migration_backfills_scaffold_rebrands_and_syncs_contracts
test_integrate_retains_and_suppresses_missing_branch_until_restored
test_l1_drive_provisions_gitignored_files_and_allowlisted_env

echo "fresh consumer tests passed"
