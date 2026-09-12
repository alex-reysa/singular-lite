#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local want="$1" got="$2" msg="$3"
  [[ "$got" == "$want" ]] || fail "$msg: want '$want', got '$got'"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg: missing '$needle' in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg: unexpectedly found '$needle' in: $haystack"
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
value = data
for part in sys.argv[2].split("."):
    value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/packets/imported" \
    "$root/docs/orchestration/areas/artifact" \
    "$root/docs/orchestration/gates" \
    "$root/docs/orchestration/prompts" "$root/schemas/orchestration" "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/l1-planner.md"
  cp "$ENGINE_HOME/schemas/state-packet.v0.schema.json" "$root/schemas/orchestration/state-packet.v0.schema.json"
  cp "$ENGINE_HOME/schemas/audit-verdict.v0.schema.json" "$root/schemas/orchestration/audit-verdict.v0.schema.json"
  cp "$ENGINE_HOME/schemas/decider-verdict.v0.schema.json" "$root/schemas/orchestration/decider-verdict.v0.schema.json"
  cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/task-batch.v0.schema.json"
  cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/dag.v0.schema.json"
  cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/gate-result.v0.schema.json"
  cat >"$root/docs/orchestration/project-state.md" <<'EOF'
# Project State
EOF
  cat >"$root/docs/orchestration/areas/artifact/state.md" <<'EOF'
# Area State: Artifact

Current status: active
EOF
  cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    {
      "id": "D0.contract",
      "stage": "D0",
      "area": "kernel",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": [],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "D1.contract",
      "stage": "D1",
      "area": "artifact",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "S0.storage_substrate_base",
      "stage": "S0",
      "area": "storage",
      "layer": "storage_substrate_base",
      "kind": "substrate",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "storage_substrate_ready"
    },
    {
      "id": "D1.storage_proof",
      "stage": "D1",
      "area": "artifact",
      "layer": "storage_proof",
      "kind": "storage",
      "dependsOn": ["D1.contract", "S0.storage_substrate_base"],
      "requiredCompletion": "storage_proof_complete"
    }
  ]
}
EOF
  cat >"$root/docs/orchestration/gates/D0.contract.gate-result.json" <<'EOF'
{
  "schema": "singular.orchestration.gate-result.v0",
  "node": "D0.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [
    {
      "kind": "source-path",
      "ref": "internal/kernel",
      "description": "Existing D0 kernel contract package."
    }
  ],
  "decidedBy": "bootstrap",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

write_task() {
  local id="$1" status="$2" owned="$3" depends="${4:-[]}" forbidden="${5:-}"
  local title="${6:-Task $id}"
  [[ -n "$forbidden" ]] || forbidden="Any file outside the owned scope unless an L1 scope amendment is recorded."
  cat >"$SINGULAR_TASKS_DIR/$id.md" <<EOF
# $id: $title

Status: $status
Area: artifact
Target branch: \`target\`
Worker branch: \`agent/artifact/$id-test\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: $depends

## Objective

Exercise $id.

## Scope

Owned files:

- \`$owned\`

Forbidden files:

- \`$forbidden\`

## Prerequisites

- Human-readable prerequisite text.

## Acceptance Criteria

- Pass.
EOF
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  make_repo "$tmp/repo"
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
  export SINGULAR_ORIGIN_STATE_FILE="$SINGULAR_STATE_DIR/origin-state.json"
  export SINGULAR_GIT_LOCK_DIR="$SINGULAR_STATE_DIR/locks/git-op.lock"
  export SINGULAR_PACKET_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/state-packet.v0.schema.json"
  export SINGULAR_AUDIT_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/audit-verdict.v0.schema.json"
  export SINGULAR_DECIDER_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/decider-verdict.v0.schema.json"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_STATUS_FILE="$SINGULAR_STATE_DIR/STATUS.md"
  export SINGULAR_BREAKER_FILE="$SINGULAR_STATE_DIR/circuit.json"
  export SINGULAR_TARGET_BRANCH="target"
  export SINGULAR_MODULES="storage-proof"
  export SINGULAR_PROOF_LAYERS="storage_proof"
  source "$SCRIPT_DIR/lib.sh"
}

test_task_parser_metadata() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "TASK-0007, TASK-0008"
  local json
  json="$(singular_task_json "$SINGULAR_TASKS_DIR/TASK-0001.md")"
  assert_eq "canonical" "$(json_field "$json" dispatchMode)" "dispatch mode parsed"
  assert_eq '["TASK-0007","TASK-0008"]' "$(json_field "$json" dependsOn)" "dependsOn parsed"
}

test_frontier_selection() {
  with_fixture
  write_task TASK-0001 integrated internal/artifact/kind.go "[]"
  write_task TASK-0002 ready internal/artifact/schema.go "[]"
  write_task TASK-0003 ready internal/artifact/version.go "TASK-0001"
  write_task TASK-0004 ready internal/artifact/schema.go "[]"
  write_task TASK-0005 ready internal/artifact/dependent.go "TASK-9999"
  singular_lease_write TASK-0006 agent/artifact/TASK-0006 artifact l2 "internal/artifact/active.go" running RUN-LEASE "$SINGULAR_WORKTREES_DIR/TASK-0006" target-sha "" '["internal/artifact/active.go"]' "[]"
  write_task TASK-0006 ready internal/artifact/active.go "[]"

  local selected ids
  selected="$(singular_select_dispatch_frontier 3)"
  ids="$(printf '%s\n' "$selected" | xargs -n1 basename | sed 's/\.md$//' | paste -sd ' ' -)"
  assert_eq "TASK-0002 TASK-0003" "$ids" "frontier selects only dependency-ready, file-disjoint, lease-free tasks"
}

test_frontier_selection_allows_shared_forbidden_files() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/schema.go "[]" internal/artifact/doc.go
  write_task TASK-0002 ready internal/artifact/version.go "[]" internal/artifact/doc.go

  local selected ids
  selected="$(singular_select_dispatch_frontier 2)"
  ids="$(printf '%s\n' "$selected" | xargs -n1 basename | sed 's/\.md$//' | paste -sd ' ' -)"
  assert_eq "TASK-0001 TASK-0002" "$ids" "frontier allows disjoint owned files with shared forbidden files"
}

test_frontier_selection_allows_shared_forbidden_file_with_active_lease() {
  with_fixture
  singular_lease_write TASK-0001 agent/artifact/TASK-0001 artifact l2 "internal/artifact/active.go" running RUN-LEASE "$SINGULAR_WORKTREES_DIR/TASK-0001" target-sha "" '["internal/artifact/active.go"]' '["internal/artifact/doc.go"]'
  write_task TASK-0002 ready internal/artifact/version.go "[]" internal/artifact/doc.go

  local selected ids
  selected="$(singular_select_dispatch_frontier 2)"
  ids="$(printf '%s\n' "$selected" | xargs -n1 basename | sed 's/\.md$//' | paste -sd ' ' -)"
  assert_eq "TASK-0002" "$ids" "frontier ignores active lease forbidden files when owned files are disjoint"
}

test_frontier_selection_allows_requeued_task_with_failed_lease() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/requeued.go "[]"
  singular_lease_write TASK-0001 agent/artifact/TASK-0001 artifact l2 "internal/artifact/requeued.go" failed RUN-LEASE "$SINGULAR_WORKTREES_DIR/TASK-0001" target-sha "" '["internal/artifact/requeued.go"]' "[]"

  local selected ids
  selected="$(singular_select_dispatch_frontier 1)"
  ids="$(printf '%s\n' "$selected" | xargs -n1 basename | sed 's/\.md$//' | paste -sd ' ' -)"
  assert_eq "TASK-0001" "$ids" "frontier allows an explicitly requeued ready task with a terminal failed lease"
}

make_parallel_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tid="$1"
mkdir -p "$SINGULAR_STATE_DIR"
echo "$tid base=${SINGULAR_DISPATCH_BASE_SHA:-} batch=${SINGULAR_DISPATCH_BATCH_ID:-}" >>"$SINGULAR_STATE_DIR/dispatch.log"
touch "$SINGULAR_STATE_DIR/$tid.start"
case "$tid" in
  TASK-0001) other=TASK-0002 ;;
  TASK-0002) other=TASK-0001 ;;
  *) other="" ;;
esac
if [[ -n "$other" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$SINGULAR_STATE_DIR/$other.start" ]] && exit 0
    sleep 0.2
  done
  echo "$tid did not overlap with $other" >&2
  exit 7
fi
exit 0
EOF
  chmod +x "$stub"
}

test_reconcile_parallel_batch_with_stub() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$SINGULAR_ROOT/stub-l1.sh"
  make_parallel_stub "$stub"

  local out
  out="$(SINGULAR_L1_DRIVER="$stub" SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 SINGULAR_MAX_CONCURRENT=2 SINGULAR_MAX_DISPATCH=2 SINGULAR_DETACHED_DISPATCH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"
  assert_contains "$out" "dispatched_this_run=2" "parallel reconcile dispatched both tasks"
  assert_contains "$out" "failed_dispatches=0" "parallel reconcile had no dispatch failures"
  assert_contains "$(cat "$SINGULAR_STATE_DIR/dispatch.log")" "TASK-0001 base=" "TASK-0001 received dispatch metadata"
  assert_contains "$(cat "$SINGULAR_STATE_DIR/dispatch.log")" "TASK-0002 base=" "TASK-0002 received dispatch metadata"
}

test_reconcile_parallel_batch_with_shared_forbidden_file() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]" internal/artifact/doc.go
  write_task TASK-0002 ready internal/artifact/b.go "[]" internal/artifact/doc.go
  local stub="$SINGULAR_ROOT/stub-l1.sh"
  make_parallel_stub "$stub"

  local out
  out="$(SINGULAR_L1_DRIVER="$stub" SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 SINGULAR_MAX_CONCURRENT=2 SINGULAR_MAX_DISPATCH=2 SINGULAR_DETACHED_DISPATCH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"
  assert_contains "$out" "dispatched_this_run=2" "parallel reconcile dispatched both tasks sharing a forbidden file"
  assert_contains "$out" "failed_dispatches=0" "parallel reconcile shared-forbidden batch had no dispatch failures"
}

test_reconcile_counts_failed_child() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$SINGULAR_ROOT/stub-l1-fail.sh"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$1" >>"$SINGULAR_STATE_DIR/dispatch.log"
[[ "$1" == "TASK-0002" ]] && exit 9
exit 0
EOF
  chmod +x "$stub"

  local out
  out="$(SINGULAR_L1_DRIVER="$stub" SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 SINGULAR_MAX_CONCURRENT=2 SINGULAR_MAX_DISPATCH=2 SINGULAR_DETACHED_DISPATCH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
  assert_contains "$out" "dispatched_this_run=2" "failed-child reconcile still counted both dispatch attempts"
  assert_contains "$out" "failed_dispatches=1" "failed-child reconcile counted one failure"
}

test_reconcile_scrubs_origin_capability_from_dispatch_child() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  local stub="$SINGULAR_ROOT/stub-l1-capability-probe.sh"
  local leaked="$SINGULAR_STATE_DIR/dispatch-origin-capability.leaked"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}" ]]; then
  printf 'origin capability reached dispatch child\n' \
    >"$SINGULAR_STATE_DIR/dispatch-origin-capability.leaked"
fi
exit 0
EOF
  chmod +x "$stub"

  local out rc=0
  out="$(SINGULAR_L1_DRIVER="$stub" SINGULAR_GENERATE=0 \
    SINGULAR_AUTO_INTEGRATE=0 SINGULAR_MAX_CONCURRENT=1 \
    SINGULAR_MAX_DISPATCH=1 SINGULAR_DETACHED_DISPATCH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)" || rc=$?
  assert_eq "0" "$rc" "capability-confinement reconcile completes ($out)"
  [[ ! -e "$leaked" ]] \
    || fail "origin lock capability reached an untrusted dispatch child"
}

test_reconcile_refills_when_only_ready_task_is_leased() {
  with_fixture
  write_task TASK-0099 ready internal/artifact/leased.go "[]"
  singular_lease_write TASK-0099 agent/artifact/TASK-0099 artifact l2 \
    "internal/artifact/leased.go" planned RUN-LEASE \
    "$SINGULAR_WORKTREES_DIR/TASK-0099" target-sha "" \
    '["internal/artifact/leased.go"]' "[]"

  local planner_stub="$SINGULAR_ROOT/planner-refill-stub.sh"
  cat >"$planner_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "$SINGULAR_STATE_DIR/planner-refill-called"
exit 91
EOF
  chmod +x "$planner_stub"

  local out
  out="$(SINGULAR_CODEX_RUNNER="$planner_stub" \
    SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_AUTO_INTEGRATE=0 \
    SINGULAR_MAX_CONCURRENT=2 SINGULAR_MAX_DISPATCH=2 \
    SINGULAR_DETACHED_DISPATCH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"

  [[ -f "$SINGULAR_STATE_DIR/planner-refill-called" ]] \
    || fail "a leased lifecycle-ready task suppressed planning despite a free slot"
  assert_contains "$out" "dispatchable queue empty; invoking task generator" \
    "reconcile refills from the dispatchable, not raw-ready, queue"
  assert_contains "$out" "ready=1 dispatchable=0 frontier=0 active_leases=1" \
    "reconcile reports raw-ready and dispatchable counts independently"
  grep -q '^Status: ready$' "$SINGULAR_TASKS_DIR/TASK-0099.md" \
    || fail "lease metadata must not rewrite the task lifecycle status"
  assert_eq "planned" "$(singular_lease_status TASK-0099)" \
    "refill leaves the in-flight lease independently owned"
}

test_reconcile_partial_frontier_requests_and_fills_remaining_capacity() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/ready.go "[]"
  write_task TASK-0099 ready internal/artifact/already-active.go "[]"
  singular_lease_write TASK-0099 agent/artifact/TASK-0099 artifact l2 \
    "internal/artifact/already-active.go" planned RUN-ACTIVE \
    "$SINGULAR_WORKTREES_DIR/TASK-0099" target-sha "" \
    '["internal/artifact/already-active.go"]' "[]"

  local worker_stub="$SINGULAR_ROOT/worker-hold-stub.sh"
  cat >"$worker_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$1" >>"$SINGULAR_STATE_DIR/refill-dispatch.log"
while [[ ! -f "$SINGULAR_STATE_DIR/release-workers" ]]; do
  sleep 0.05
done
EOF
  chmod +x "$worker_stub"

  local planner_stub="$SINGULAR_ROOT/planner-one-refill-stub.sh"
  cat >"$planner_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message|-o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
touch "$SINGULAR_STATE_DIR/partial-refill-planner-called"
python3 - "$out" <<'PY'
import json
import sys

out = sys.argv[1]
task_id = "TASK-0100"
markdown = f"""# {task_id}: Refill remaining capacity

Status: ready
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/{task_id}-refill`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Fill the remaining scheduler slot.

## Scope

Owned files:

- `internal/artifact/refill.go`

Forbidden files:

- Any file outside the owned scope unless an L1 scope amendment is recorded.

## Prerequisites

- D0.

## Acceptance Criteria

- Pass.
"""
with open(out, "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "singular.orchestration.task-batch.v0",
        "tasks": [{"taskId": task_id, "markdown": markdown}],
    }, handle, indent=2)
    handle.write("\n")
PY
EOF
  chmod +x "$planner_stub"

  local first_out second_out
  first_out="$(SINGULAR_L1_DRIVER="$worker_stub" SINGULAR_CODEX_RUNNER="$planner_stub" \
    SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_AUTO_INTEGRATE=0 \
    SINGULAR_MAX_CONCURRENT=3 SINGULAR_MAX_DISPATCH=3 \
    SINGULAR_DETACHED_DISPATCH=1 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"

  assert_contains "$first_out" "dispatched_this_run=1" \
    "partial frontier dispatches already-ready work without waiting for planning"
  assert_contains "$first_out" "refill_requested_this_run=1" \
    "partial frontier requests an immediate event-driven refill"
  [[ -f "$(singular_wake_file)" ]] || fail "partial frontier did not write WAKE"
  [[ ! -f "$SINGULAR_STATE_DIR/partial-refill-planner-called" ]] \
    || fail "planner delayed an already-ready task in the first cycle"

  # Model autonomate consuming WAKE, then running the requested cycle. Both the
  # pre-existing and newly launched tasks are active, so exactly one of three
  # slots remains and the planner must receive/fill only that capacity.
  rm -f "$(singular_wake_file)"
  second_out="$(SINGULAR_L1_DRIVER="$worker_stub" SINGULAR_CODEX_RUNNER="$planner_stub" \
    SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_AUTO_INTEGRATE=0 \
    SINGULAR_MAX_CONCURRENT=3 SINGULAR_MAX_DISPATCH=3 \
    SINGULAR_DETACHED_DISPATCH=1 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"

  [[ -f "$SINGULAR_STATE_DIR/partial-refill-planner-called" ]] \
    || fail "event-driven refill cycle did not invoke the planner"
  assert_contains "$second_out" "invoking task generator for up to 1 task(s)" \
    "refill planning is bounded by exact remaining capacity"
  assert_contains "$second_out" "dispatched_this_run=1" \
    "refill cycle dispatched exactly the remaining slot"
  assert_eq "3" "$(singular_active_lease_count)" \
    "partial refill reaches but never exceeds configured concurrency"
  assert_eq "2" "$(wc -l <"$SINGULAR_STATE_DIR/refill-dispatch.log" | tr -d ' ')" \
    "only the existing ready task and one generated task were launched"

  touch "$SINGULAR_STATE_DIR/release-workers"
  SINGULAR_DRAIN_POLL_SECS=0.05 SINGULAR_DRAIN_TIMEOUT_SECS=10 \
    "$SCRIPT_DIR/reconcile.sh" --drain >/dev/null 2>&1
}

make_codex_arg_stub() {
  local dir="$SINGULAR_STATE_DIR/fake-bin"
  mkdir -p "$dir"
  cat >"$dir/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$SINGULAR_STATE_DIR/codex-args.log"
exit 0
EOF
  chmod +x "$dir/codex"
  export PATH="$dir:$PATH"
}

test_codex_run_l2_defaults_to_workspace_write_sandbox() {
  with_fixture
  make_codex_arg_stub

  "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$SINGULAR_ROOT" >/dev/null 2>&1

  assert_contains "$(cat "$SINGULAR_STATE_DIR/codex-args.log")" "--sandbox workspace-write" "l2 codex-run defaults to workspace-write"
}

test_codex_run_l2_uses_medium_reasoning_without_service_tier() {
  with_fixture
  make_codex_arg_stub

  "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$SINGULAR_ROOT" >/dev/null 2>&1

  local args
  args="$(cat "$SINGULAR_STATE_DIR/codex-args.log")"
  assert_contains "$args" "-m gpt-5.5" "l2 codex-run pins the worker model"
  assert_contains "$args" "model_reasoning_effort=\"medium\"" "l2 codex-run uses medium reasoning"
  assert_not_contains "$args" "service_tier=" "l2 codex-run leaves service tier at the API default"
  assert_not_contains "$args" "service_tier=\"fast\"" "l2 codex-run does not request fast service tier"
}

test_codex_run_readonly_planner_uses_high_reasoning() {
  with_fixture
  make_codex_arg_stub
  local prompt="$SINGULAR_STATE_DIR/planner-prompt.md"
  printf 'plan\n' >"$prompt"

  "$SCRIPT_DIR/codex-run.sh" --level readonly --prompt-file "$prompt" -C "$SINGULAR_ROOT" >/dev/null 2>&1

  local args
  args="$(cat "$SINGULAR_STATE_DIR/codex-args.log")"
  assert_contains "$args" "--sandbox read-only" "planner codex-run uses readonly sandbox"
  assert_contains "$args" "-m gpt-5.5" "planner codex-run pins the model"
  assert_contains "$args" "model_reasoning_effort=\"high\"" "planner codex-run uses high reasoning"
  assert_not_contains "$args" "service_tier=" "planner codex-run leaves service tier at the API default"
}

test_codex_run_readonly_aux_roles_use_high_reasoning() {
  with_fixture
  make_codex_arg_stub

  local name prompt args
  for name in auditor.md reviewer.md decider-prompt-worker-no-packet.md plan-critic.md generic-readonly.md; do
    prompt="$SINGULAR_STATE_DIR/$name"
    printf 'role prompt\n' >"$prompt"
    "$SCRIPT_DIR/codex-run.sh" --level readonly --prompt-file "$prompt" -C "$SINGULAR_ROOT" >/dev/null 2>&1
    args="$(cat "$SINGULAR_STATE_DIR/codex-args.log")"
    assert_contains "$args" "model_reasoning_effort=\"high\"" "$name codex-run uses high reasoning"
  done
}

test_codex_run_readonly_auditor_uses_high_reasoning() {
  with_fixture
  make_codex_arg_stub
  local prompt="$SINGULAR_STATE_DIR/auditor-prompt.md"
  printf 'audit\n' >"$prompt"

  "$SCRIPT_DIR/codex-run.sh" --level readonly --prompt-file "$prompt" -C "$SINGULAR_ROOT" >/dev/null 2>&1

  local args
  args="$(cat "$SINGULAR_STATE_DIR/codex-args.log")"
  assert_contains "$args" "--sandbox read-only" "auditor codex-run uses readonly sandbox"
  assert_contains "$args" "-m gpt-5.5" "auditor codex-run pins the model"
  assert_contains "$args" "model_reasoning_effort=\"high\"" "auditor codex-run uses high reasoning"
  assert_not_contains "$args" "service_tier=" "auditor codex-run leaves service tier at the API default"
}

test_codex_run_l2_allows_explicit_sandbox_override() {
  with_fixture
  make_codex_arg_stub

  SINGULAR_L2_SANDBOX=danger-full-access "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$SINGULAR_ROOT" >/dev/null 2>&1

  assert_contains "$(cat "$SINGULAR_STATE_DIR/codex-args.log")" "--sandbox danger-full-access" "l2 codex-run honors explicit sandbox override"
}

test_codex_run_l2_rejects_invalid_sandbox_override() {
  with_fixture
  make_codex_arg_stub

  local out
  out="$(SINGULAR_L2_SANDBOX=bogus "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$SINGULAR_ROOT" 2>&1 || true)"

  assert_contains "$out" "invalid SINGULAR_L2_SANDBOX" "invalid l2 sandbox override is rejected"
}

test_codex_run_explicit_bin_wins_without_path_reordering() {
  with_fixture
  local broken_dir="$SINGULAR_ROOT/broken-bin"
  local working_dir="$SINGULAR_ROOT/working codex"
  local working_codex="$working_dir/codex"
  mkdir -p "$broken_dir" "$working_dir"
  cat >"$broken_dir/codex" <<'EOF'
#!/usr/bin/env bash
touch "$SINGULAR_STATE_DIR/broken-codex-called"
exit 91
EOF
  cat >"$working_codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$SINGULAR_STATE_DIR/pinned-codex-args.log"
exit 0
EOF
  chmod +x "$broken_dir/codex" "$working_codex"

  PATH="$broken_dir:$PATH" SINGULAR_CODEX_BIN="$working_codex" \
    "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$SINGULAR_ROOT" \
    >/dev/null 2>&1

  [[ -f "$SINGULAR_STATE_DIR/pinned-codex-args.log" ]] || fail "explicit Codex path was not invoked"
  [[ ! -f "$SINGULAR_STATE_DIR/broken-codex-called" ]] || fail "runner fell back to broken PATH Codex"
  assert_contains "$(cat "$SINGULAR_STATE_DIR/pinned-codex-args.log")" "--sandbox workspace-write" \
    "pinned Codex receives normal runner arguments"
}

test_codex_run_rejects_nonabsolute_explicit_bin() {
  with_fixture
  make_codex_arg_stub
  local out rc=0
  out="$(SINGULAR_CODEX_BIN=codex "$SCRIPT_DIR/codex-run.sh" \
    --level l2 --no-output-capture -C "$SINGULAR_ROOT" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "relative SINGULAR_CODEX_BIN must be rejected"
  assert_contains "$out" "SINGULAR_CODEX_BIN must be an absolute path" \
    "relative explicit Codex path has a clear error"
  [[ ! -f "$SINGULAR_STATE_DIR/codex-args.log" ]] || fail "invalid explicit Codex must not fall back to PATH"
}

test_gate_red_external_proof_env_blocker_detected() {
  with_fixture
  local log="$SINGULAR_STATE_DIR/gate-red.log"
  cat >"$log" <<'EOF'
--- FAIL: TestArtifactStorageRepositoryDurableRoundTripProvesPostgresAndBlobImmutability (0.00s)
    storage_repository_test.go:30: SINGULAR_STORAGE_PROOF_DATABASE_URL or SINGULAR_DATABASE_URL must point at a real PostgreSQL database; the storage proof must not silently skip or use an in-memory/SQLite substitute
FAIL
EOF
  unset SINGULAR_STORAGE_PROOF_DATABASE_URL SINGULAR_DATABASE_URL
  singular_gate_red_external_proof_env_blocker "$log" \
    || fail "missing real PostgreSQL env gate-red must be treated as an external proof-env blocker"
}

test_gate_red_external_proof_env_blocker_ignored_when_env_present() {
  with_fixture
  local log="$SINGULAR_STATE_DIR/gate-red.log"
  cat >"$log" <<'EOF'
storage_repository_test.go:30: SINGULAR_STORAGE_PROOF_DATABASE_URL or SINGULAR_DATABASE_URL must point at a real PostgreSQL database; the storage proof must not silently skip or use an in-memory/SQLite substitute
EOF
  if SINGULAR_STORAGE_PROOF_DATABASE_URL="postgres://singular:singular@127.0.0.1:5432/singular" \
    singular_gate_red_external_proof_env_blocker "$log"; then
    fail "present real PostgreSQL env should leave gate-red eligible for rerun-tests"
  fi
}

test_strict_proof_skip_detected() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/storage_repository_test.go "[]"
  cat >>"$SINGULAR_TASKS_DIR/TASK-0001.md" <<'EOF'

The strict first test uses a real PostgreSQL-backed metadata store and no silent skip of the real-store proof.
EOF
  mkdir -p "$SINGULAR_ROOT/internal/artifact"
  cat >"$SINGULAR_ROOT/internal/artifact/storage_repository_test.go" <<'EOF'
package artifact

import "testing"

func TestProof(t *testing.T) {
	t.Skipf("missing PostgreSQL")
}
EOF
  singular_strict_proof_skip_detected "$SINGULAR_TASKS_DIR/TASK-0001.md" "$SINGULAR_ROOT" "internal/artifact/storage_repository_test.go" \
    || fail "strict proof task must reject t.Skipf in owned proof tests"
}

test_strict_proof_skip_ignored_for_nonproof_task() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/storage_repository_test.go "[]"
  mkdir -p "$SINGULAR_ROOT/internal/artifact"
  cat >"$SINGULAR_ROOT/internal/artifact/storage_repository_test.go" <<'EOF'
package artifact

import "testing"

func TestFixture(t *testing.T) {
	t.Skip("fixture")
}
EOF
  if singular_strict_proof_skip_detected "$SINGULAR_TASKS_DIR/TASK-0001.md" "$SINGULAR_ROOT" "internal/artifact/storage_repository_test.go"; then
    fail "ordinary tasks are not strict proof tasks just because a test contains t.Skip"
  fi
}

make_planner_stub() {
  local stub="$1" mode="$2"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
mode="__MODE__"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message|-o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
python3 - "$out" "$mode" <<'PY'
import json
import sys

out, mode = sys.argv[1:3]

def markdown(task_id, title, owned, depends):
    return f"""# {task_id}: {title}

Status: ready
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/{task_id}-{title.lower()}`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: {depends}

## Objective

{title}.

## Scope

Owned files:

- `{owned}`

Forbidden files:

- Any file outside the owned scope unless an L1 scope amendment is recorded.

## Prerequisites

- D0.

## Acceptance Criteria

- Pass.
"""

first_dep = "TASK-0002" if mode == "internal_dep" else "[]"
data = {
    "schema": "singular.orchestration.task-batch.v0",
    "tasks": [
        {"taskId": "TASK-0001", "markdown": markdown("TASK-0001", "First", "internal/artifact/first.go", first_dep)},
        {"taskId": "TASK-0002", "markdown": markdown("TASK-0002", "Second", "internal/artifact/second.go", "[]")},
    ],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
EOF
  python3 - "$stub" "$mode" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
path.write_text(path.read_text().replace("__MODE__", mode))
PY
  chmod +x "$stub"
}

test_generate_tasks_accepts_valid_batch() {
  with_fixture
  local stub="$SINGULAR_ROOT/planner-valid.sh"
  make_planner_stub "$stub" valid
  local out
  out="$(SINGULAR_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --count 2 2>&1)"
  assert_contains "$out" "generated:TASK-0001" "planner generated first task"
  assert_contains "$out" "generated:TASK-0002" "planner generated second task"
  [[ -f "$SINGULAR_TASKS_DIR/TASK-0001.md" && -f "$SINGULAR_TASKS_DIR/TASK-0002.md" ]] || fail "planner did not write batch task files"
}

test_generate_tasks_rejects_internal_dependency() {
  with_fixture
  local stub="$SINGULAR_ROOT/planner-internal-dep.sh"
  make_planner_stub "$stub" internal_dep
  local out
  out="$(SINGULAR_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --count 2 2>&1 || true)"
  assert_contains "$out" "planner-failed" "planner rejected internal dependency batch"
  [[ ! -f "$SINGULAR_TASKS_DIR/TASK-0001.md" ]] || fail "planner wrote invalid internal dependency batch"
}

test_scope_amendment_rejects_generated_cache_paths() {
  with_fixture
  local accepted=()
  local p
  while IFS= read -r p; do
    if singular_scope_amendment_path_allowed "$p"; then
      accepted+=("$p")
    fi
  done <<'EOF'
internal/artifact/real.go
.singular-cache/go-build/aa/cache-a
.singular-cache/go-build/testexpire.txt
.singular-state/runs/RUN/file.log
.singular-evidence/red.log
EOF
  assert_eq "internal/artifact/real.go" "${accepted[*]}" "scope amendment filters generated local cache/state/evidence paths"
}

write_minimal_worker_packet() {
  local path="$1" schema="$2"
  cat >"$path" <<EOF
{
  "schema": "$schema",
  "packetId": "RUN-PACKET",
  "runId": "RUN-PACKET",
  "taskId": "TASK-0001",
  "area": "artifact",
  "role": "l2-developer",
  "status": "needs-review",
  "baseRef": "target",
  "branch": "agent/artifact/TASK-0001-test",
  "headSha": "uncommitted",
  "workspace": "$SINGULAR_ROOT/.worktrees/TASK-0001",
  "ownedFiles": ["internal/artifact/a.go"],
  "changedFiles": ["internal/artifact/a.go"],
  "commands": [{"cmd": "true", "exitCode": 0, "logRef": "log"}],
  "tests": [{"name": "fixture", "phase": "green", "status": "passed", "logRef": "log"}],
  "evidence": [{"kind": "test", "ref": "log"}],
  "blockers": [],
  "nextAction": "await auditor verdict",
  "createdAt": "2026-06-02T00:00:00Z"
}
EOF
}

write_storage_proof_guard_task() {
  mkdir -p "$SINGULAR_TASKS_DIR"
  cat >"$SINGULAR_TASKS_DIR/TASK-0001.md" <<'EOF'
# TASK-0001: Durable storage proof fixture

Status: ready
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-0001-test`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement a bounded `D1.storage_proof` / `storage_proof` repository conformance round-trip proof.

## Scope

Owned files:

- `internal/artifact/a.go`

Forbidden files:

- `internal/artifact/doc.go`

## Acceptance Criteria

- Include marked nonzero red evidence for the storage-stripped real-store proof path.

## Required Evidence

- Failing targeted test output, including a marked nonzero `*-skip-guard-red` storage-proof command log.
EOF
}

mark_minimal_packet_with_storage_proof_guard() {
  local packet="$1"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
ref = ".singular-evidence/TASK-0001-skip-guard-red"
data["commands"][0] = {
    "cmd": "env -u SINGULAR_STORAGE_PROOF_DATABASE_URL -u SINGULAR_DATABASE_URL go test ./internal/artifact -run TestStorageProof -count=1",
    "exitCode": 1,
    "logRef": ref,
}
data["tests"][0] = {
    "name": "storage proof env stripped",
    "phase": "red",
    "status": "failed-as-expected",
    "logRef": ref,
}
data["evidence"][0] = {"kind": "red-log", "ref": ref}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

test_l1_worker_packet_preflight_normalizes_legacy_schema_path() {
  with_fixture
  local msg="$SINGULAR_STATE_DIR/legacy-last-message.json"
  local packet="$SINGULAR_STATE_DIR/prepared-packet.json"
  local validation_log="$SINGULAR_STATE_DIR/preflight-validation.log"
  write_minimal_worker_packet "$msg" "schemas/orchestration/state-packet.v0.schema.json"

  singular_l1_prepare_worker_packet "$msg" "$packet" "$validation_log" \
    || fail "legacy schema-path packet should pass L1 worker preflight"

  assert_eq "singular.orchestration.state-packet.v0" \
    "$(json_field "$(cat "$packet")" schema)" \
    "L1 worker preflight normalizes legacy schema path"
  assert_contains "$(singular_validate_packet_basic "$packet")" "ok" \
    "normalized packet validates with strict import validator"
}

test_l1_worker_packet_preflight_reports_validation_errors() {
  with_fixture
  local msg="$SINGULAR_STATE_DIR/bad-schema-last-message.json"
  local packet="$SINGULAR_STATE_DIR/bad-schema-packet.json"
  local validation_log="$SINGULAR_STATE_DIR/bad-schema-validation.log"
  local rc=0
  write_minimal_worker_packet "$msg" "wrong-schema"

  singular_l1_prepare_worker_packet "$msg" "$packet" "$validation_log" || rc=$?

  assert_eq "12" "$rc" "invalid worker packet is classified as packet-invalid preflight"
  assert_contains "$(cat "$validation_log")" "unsupported schema: wrong-schema" \
    "invalid worker packet preserves validator error"
}

test_l1_worker_packet_preflight_reports_unknown_fields() {
  with_fixture
  local msg="$SINGULAR_STATE_DIR/unknown-field-last-message.json"
  local packet="$SINGULAR_STATE_DIR/unknown-field-packet.json"
  local validation_log="$SINGULAR_STATE_DIR/unknown-field-validation.log"
  local rc=0
  write_minimal_worker_packet "$msg" "singular.orchestration.state-packet.v0"
  python3 - "$msg" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["risks"] = ["non-schema worker note"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

  singular_l1_prepare_worker_packet "$msg" "$packet" "$validation_log" || rc=$?

  assert_eq "12" "$rc" "unknown top-level worker packet field is packet-invalid"
  assert_contains "$(cat "$validation_log")" "unknown fields: risks" \
    "unknown field worker packet preserves validator error"
}

test_storage_proof_packet_guard_rejects_unmarked_red_log() {
  with_fixture
  write_storage_proof_guard_task
  local packet="$SINGULAR_STATE_DIR/storage-proof-unmarked-packet.json"
  local worktree="$SINGULAR_ROOT/.worktrees/TASK-0001"
  local out rc=0
  write_minimal_worker_packet "$packet" "singular.orchestration.state-packet.v0"
  mkdir -p "$worktree/.singular-evidence"
  printf 'red failed\n' >"$worktree/.singular-evidence/red.log"

  out="$(singular_packet_module_guard "$packet" "$SINGULAR_TASKS_DIR/TASK-0001.md" "$worktree" "$SINGULAR_STATE_DIR/runs/RUN-PACKET" 2>&1)" || rc=$?

  [[ "$rc" -ne 0 ]] || fail "storage proof packet without marked red guard must be rejected"
  assert_contains "$out" "logRef ending in -skip-guard-red" \
    "storage proof guard explains missing marked red command"
}

test_storage_proof_packet_guard_accepts_marked_env_unset_red_log() {
  with_fixture
  write_storage_proof_guard_task
  local packet="$SINGULAR_STATE_DIR/storage-proof-marked-packet.json"
  local worktree="$SINGULAR_ROOT/.worktrees/TASK-0001"
  local ref=".singular-evidence/TASK-0001-skip-guard-red"
  write_minimal_worker_packet "$packet" "singular.orchestration.state-packet.v0"
  mark_minimal_packet_with_storage_proof_guard "$packet"
  mkdir -p "$worktree/.singular-evidence"
  printf 'real storage stripped failed\n' >"$worktree/$ref"

  singular_packet_module_guard "$packet" "$SINGULAR_TASKS_DIR/TASK-0001.md" "$worktree" "$SINGULAR_STATE_DIR/runs/RUN-PACKET" >/dev/null \
    || fail "storage proof packet with marked env-unset red guard should pass"
}

test_l2_worker_prompt_matches_state_packet_schema_fields() {
  local prompt
  prompt="$(cat "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md")"

  assert_not_contains "$prompt" "test evidence, risks," \
    "L2 worker prompt must not request non-schema top-level risks field"
  assert_contains "$prompt" "test evidence, blockers," \
    "L2 worker prompt names schema-supported packet fields"
  assert_contains "$prompt" "and next action. Do not add top-level fields outside the packet schema." \
    "L2 worker prompt forbids schema-extra top-level fields"
}

test_integrate_push_logs_sanitize_branch_names() {
  with_fixture
  git -C "$SINGULAR_ROOT" branch -m codex/singular-bootstrap-target
  export SINGULAR_TARGET_BRANCH="codex/singular-bootstrap-target"

  write_task TASK-0100 accepted internal/artifact/push_log_fixture.go "[]"
  python3 - "$SINGULAR_TASKS_DIR/TASK-0100.md" "$SINGULAR_TARGET_BRANCH" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("Target branch: `target`", f"Target branch: `{sys.argv[2]}`")
text = text.replace(
    "Worker branch: `agent/artifact/TASK-0100-test`",
    "Worker branch: `agent/artifact/TASK-0100-push-log`",
)
path.write_text(text, encoding="utf-8")
PY
  git -C "$SINGULAR_ROOT" add "$SINGULAR_TASKS_DIR/TASK-0100.md"
  git -C "$SINGULAR_ROOT" -c user.name=test -c user.email=test@example.local \
    commit -q -m "TASK-0100: push log task"

  local origin="$SINGULAR_ROOT/../origin.git"
  git init --bare -q "$origin"
  git -C "$SINGULAR_ROOT" remote add origin "$origin"
  git -C "$SINGULAR_ROOT" push -q -u origin "$SINGULAR_TARGET_BRANCH"

  local branch="agent/artifact/TASK-0100-push-log"
  git -C "$SINGULAR_ROOT" checkout -q -b "$branch"
  mkdir -p "$SINGULAR_ROOT/internal/artifact"
  cat >"$SINGULAR_ROOT/internal/artifact/push_log_fixture.go" <<'EOF'
package artifact

const PushLogFixture = "ok"
EOF
  git -C "$SINGULAR_ROOT" add internal/artifact/push_log_fixture.go
  git -C "$SINGULAR_ROOT" -c user.name=test -c user.email=test@example.local commit -q -m "TASK-0100: push log fixture"
  local head tree run_dir request task_snapshot policy
  head="$(git -C "$SINGULAR_ROOT" rev-parse HEAD)"
  tree="$(git -C "$SINGULAR_ROOT" rev-parse 'HEAD^{tree}')"

  run_dir="$SINGULAR_RUNS_DIR/RUN-PUSHLOG"
  request="$run_dir/verification-request-1.json"
  task_snapshot="$run_dir/verification-task-contract-1.md"
  policy="$run_dir/verification-policy-1.json"
  mkdir -p "$run_dir"
  cp "$SINGULAR_TASKS_DIR/TASK-0100.md" "$task_snapshot"
  printf '%s\n' '{"campaign":"legacy","policy":"push-log-fixture"}' >"$policy"
  python3 "$SCRIPT_DIR/gate-report.py" create-verification-request \
    --output "$request" --task-id TASK-0100 --run-id RUN-PUSHLOG \
    --attempt 1 --head-sha "$head" --tree-sha "$tree" --campaign legacy \
    --task-contract "$task_snapshot" --policy-contract "$policy" \
    --suite-id task-contract-gate >/dev/null
  (cd "$SINGULAR_ROOT" && "$SCRIPT_DIR/gate-check.sh" RUN-PUSHLOG \
    --task-id TASK-0100 --verification-request "$request" \
    --task-contract "$task_snapshot" --policy-contract "$policy" --attempt 1) >/dev/null
  mv "$run_dir/gate-report.json" "$run_dir/audit-verification.json"
  git -C "$SINGULAR_ROOT" checkout -q "$SINGULAR_TARGET_BRANCH"

  local packet_dir="$SINGULAR_ORCH_DIR/packets/imported/TASK-0100"
  mkdir -p "$packet_dir"
  cat >"$packet_dir/RUN-PUSHLOG.json" <<EOF
{
  "schema": "singular.orchestration.state-packet.v0",
  "packetId": "RUN-PUSHLOG",
  "runId": "RUN-PUSHLOG",
  "taskId": "TASK-0100",
  "area": "artifact",
  "role": "l2",
  "status": "accepted",
  "baseRef": "$SINGULAR_TARGET_BRANCH",
  "branch": "$branch",
  "headSha": "$head",
  "workspace": "$SINGULAR_ROOT",
  "ownedFiles": ["internal/artifact/push_log_fixture.go"],
  "changedFiles": ["internal/artifact/push_log_fixture.go"],
  "commands": [{"cmd": "true", "exitCode": 0}],
  "tests": [{"name": "fixture", "phase": "regression", "status": "passed"}],
  "evidence": [{"kind": "test", "ref": "fixture"}, {"kind": "audit-verification", "ref": "runs/RUN-PUSHLOG/audit-verification.json"}],
  "blockers": [],
  "nextAction": "integrate",
  "createdAt": "2026-05-29T00:00:00Z"
}
EOF
  cat >"$packet_dir/RUN-PUSHLOG.audit.json" <<EOF
{
  "schema": "singular.orchestration.audit-verdict.v0",
  "taskId": "TASK-0100",
  "runId": "RUN-PUSHLOG",
  "branch": "$branch",
  "verdict": "accepted",
  "evidenceReviewed": ["fixture", "audit-verification.json", "reviewed-head-sha:$head"],
  "commandsRun": ["true"],
  "findings": [],
  "requiredFixes": [],
  "rationale": "fixture accepted"
}
EOF

  local out
  out="$(SINGULAR_DEFAULT_GATE_CMD=true SINGULAR_PUSH=1 "$SCRIPT_DIR/integrate.sh" --task TASK-0100 --run-id RUN-PUSHLOG 2>&1)"
  assert_contains "$out" "pushed codex/singular-bootstrap-target -> origin" "target branch pushed with slash name"
  assert_contains "$out" "pushed agent/artifact/TASK-0100-push-log -> origin" "worker branch pushed with slash name"

  [[ -f "$run_dir/secret-scan-push-codex__singular-bootstrap-target.log" ]] || fail "missing sanitized target push scan log"
  [[ -f "$run_dir/secret-scan-push-agent__artifact__TASK-0100-push-log.log" ]] || fail "missing sanitized worker push scan log"
  [[ ! -d "$run_dir/secret-scan-push-codex" ]] || fail "target push scan log used branch slash as directory"
  [[ ! -d "$run_dir/secret-scan-push-agent" ]] || fail "worker push scan log used branch slash as directory"
}

( test_task_parser_metadata )
( test_frontier_selection )
( test_frontier_selection_allows_shared_forbidden_files )
( test_frontier_selection_allows_shared_forbidden_file_with_active_lease )
( test_frontier_selection_allows_requeued_task_with_failed_lease )
( test_reconcile_parallel_batch_with_stub )
( test_reconcile_parallel_batch_with_shared_forbidden_file )
( test_reconcile_counts_failed_child )
( test_reconcile_scrubs_origin_capability_from_dispatch_child )
( test_reconcile_refills_when_only_ready_task_is_leased )
( test_reconcile_partial_frontier_requests_and_fills_remaining_capacity )
( test_codex_run_l2_defaults_to_workspace_write_sandbox )
( test_codex_run_l2_uses_medium_reasoning_without_service_tier )
( test_codex_run_readonly_planner_uses_high_reasoning )
( test_codex_run_readonly_auditor_uses_high_reasoning )
( test_codex_run_readonly_aux_roles_use_high_reasoning )
( test_codex_run_l2_allows_explicit_sandbox_override )
( test_codex_run_l2_rejects_invalid_sandbox_override )
( test_codex_run_explicit_bin_wins_without_path_reordering )
( test_codex_run_rejects_nonabsolute_explicit_bin )
( test_gate_red_external_proof_env_blocker_detected )
( test_gate_red_external_proof_env_blocker_ignored_when_env_present )
( test_strict_proof_skip_detected )
( test_strict_proof_skip_ignored_for_nonproof_task )
( test_generate_tasks_accepts_valid_batch )
( test_generate_tasks_rejects_internal_dependency )
( test_scope_amendment_rejects_generated_cache_paths )
( test_l1_worker_packet_preflight_normalizes_legacy_schema_path )
( test_l1_worker_packet_preflight_reports_validation_errors )
( test_l1_worker_packet_preflight_reports_unknown_fields )
( test_storage_proof_packet_guard_rejects_unmarked_red_log )
( test_storage_proof_packet_guard_accepts_marked_env_unset_red_log )
( test_l2_worker_prompt_matches_state_packet_schema_fields )
( test_integrate_push_logs_sanitize_branch_names )

echo "dynamic dispatch tests passed"
