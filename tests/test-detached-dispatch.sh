#!/usr/bin/env bash
# singular-test: serial — fixture workers are explicitly started, held, released,
# and observed complete; watchdogs bound hangs without making timing the verdict.
set -euo pipefail

# Detached dispatch (SINGULAR_DETACHED_DISPATCH=1): reconcile spawns workers and
# returns without waiting; outcomes are attributed by the reaper on later
# cycles via dispatch records + exit files. These tests cover: fast cycle
# return with lock release, pre-lease double-dispatch/scope protection, reap
# correctness for ok/failed/crashed workers, --drain, batch-mode shadow
# accounting parity, breaker semantics under autonomate, and atomic state
# writes leaving no tmp residue.

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

FIXTURE_ROOTS=()
FIXTURE_TMP_PARENT="${TMPDIR:-/tmp}"
FIXTURE_TMP_PARENT="${FIXTURE_TMP_PARENT%/}"

cleanup_fixtures() {
  local rc=$? fixture_root state record task_id record_state pid pid_start current_start
  trap - EXIT INT TERM

  # First release every controlled worker. This is the normal assertion-failure
  # path and lets dispatch-wrap persist its exit file cleanly.
  for fixture_root in "${FIXTURE_ROOTS[@]}"; do
    state="$fixture_root/repo/.singular-state"
    [[ -d "$state" ]] || continue
    : >"$state/fixture-release"
  done
  sleep 0.5

  # A watchdog or hard assertion may leave a wrapper that did not cooperate.
  # Kill only process groups named by fixture-owned dispatch records; the
  # engine helper verifies that each group is a setsid leader before signaling.
  for fixture_root in "${FIXTURE_ROOTS[@]}"; do
    state="$fixture_root/repo/.singular-state"
    [[ -d "$state/dispatch" ]] || continue
    SINGULAR_ROOT="$fixture_root/repo"
    SINGULAR_STATE_DIR="$state"
    SINGULAR_DISPATCH_DIR="$state/dispatch"
    SINGULAR_RUNS_DIR="$state/runs"
    for record in "$state"/dispatch/*.json; do
      [[ -f "$record" ]] || continue
      record_state="$(singular_json_field "$record" state 2>/dev/null || true)"
      [[ "$record_state" == "launched" ]] || continue
      pid="$(singular_json_field "$record" pid 2>/dev/null || true)"
      pid_start="$(singular_json_field "$record" pidStart 2>/dev/null || true)"
      current_start="$(singular_dispatch_pid_start "$pid" 2>/dev/null || true)"
      [[ -n "$pid_start" && "$current_start" == "$pid_start" ]] || continue
      task_id="$(basename "$record" .json)"
      singular_kill_dispatch_pgroup "$task_id" >/dev/null 2>&1 || true
    done
  done

  for fixture_root in "${FIXTURE_ROOTS[@]}"; do
    [[ -n "$fixture_root" && "$fixture_root" == "$FIXTURE_TMP_PARENT"/tmp.* ]] || continue
    rm -rf -- "$fixture_root"
  done
  exit "$rc"
}
trap cleanup_fixtures EXIT INT TERM

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
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

write_task() {
  local id="$1" status="$2" owned="$3" depends="${4:-[]}"
  cat >"$SINGULAR_TASKS_DIR/$id.md" <<EOF
# $id: Task $id

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

- \`Any file outside the owned scope unless an L1 scope amendment is recorded.\`

## Prerequisites

- Human-readable prerequisite text.

## Acceptance Criteria

- Pass.
EOF
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  FIXTURE_ROOTS+=("$tmp")
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
  export SINGULAR_DISPATCH_DIR="$SINGULAR_STATE_DIR/dispatch"
  export SINGULAR_PACKET_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/state-packet.v0.schema.json"
  export SINGULAR_AUDIT_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/audit-verdict.v0.schema.json"
  export SINGULAR_DECIDER_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/decider-verdict.v0.schema.json"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_STATUS_FILE="$SINGULAR_STATE_DIR/STATUS.md"
  export SINGULAR_BREAKER_FILE="$SINGULAR_STATE_DIR/circuit.json"
  export SINGULAR_PLANNER_BACKOFF_FILE="$SINGULAR_STATE_DIR/planner-backoff.json"
  export SINGULAR_TARGET_BRANCH="target"
  source "$SCRIPT_DIR/lib.sh"
}

# Stub driver that announces startup, waits for an explicit fixture release,
# announces completion, then exits with a per-task code (default 0).
make_controlled_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tid="$1"
worker_dir="$SINGULAR_STATE_DIR/fixture-workers/$tid"
mkdir -p "$worker_dir"
echo "$tid" >>"$SINGULAR_STATE_DIR/dispatch.log"
: >"$worker_dir/started"
while [[ ! -f "$SINGULAR_STATE_DIR/fixture-release" ]]; do
  sleep 0.1
done
: >"$worker_dir/released"
ec_file="$SINGULAR_STATE_DIR/$tid.ec"
ec=0
[[ -f "$ec_file" ]] && ec="$(cat "$ec_file")"
: >"$worker_dir/completed"
exit "$ec"
EOF
  chmod +x "$stub"
}

# Immediate-completion stub retained for reap and batch-accounting cases.
make_sleep_stub() {
  local stub="$1" secs="$2"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
set -euo pipefail
tid="\$1"
echo "\$tid" >>"\$SINGULAR_STATE_DIR/dispatch.log"
sleep $secs
ec_file="\$SINGULAR_STATE_DIR/\$tid.ec"
[[ -f "\$ec_file" ]] && exit "\$(cat "\$ec_file")"
exit 0
EOF
  chmod +x "$stub"
}

actuate() {
  SINGULAR_L1_DRIVER="$1" SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 \
    SINGULAR_MAX_CONCURRENT="$2" SINGULAR_MAX_DISPATCH="$2" SINGULAR_DETACHED_DISPATCH="$3" \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true
}

actuate_to_file() { # driver max detached output
  local driver="$1" max="$2" detached="$3" output="$4"
  SINGULAR_L1_DRIVER="$driver" SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 \
    SINGULAR_MAX_CONCURRENT="$max" SINGULAR_MAX_DISPATCH="$max" \
    SINGULAR_DETACHED_DISPATCH="$detached" \
    "$SCRIPT_DIR/reconcile.sh" --actuate >"$output" 2>&1 || true
}

field_of() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

wait_for_exit_files() {
  local count="$1" tries=0
  while [[ "$(find "$SINGULAR_DISPATCH_DIR" -name '*.exit' 2>/dev/null | wc -l | tr -d ' ')" -lt "$count" ]]; do
    tries=$((tries + 1))
    [[ "$tries" -ge 50 ]] && fail "timed out waiting for $count exit file(s)"
    sleep 0.2
  done
}

fixture_worker_count() { # marker
  find "$SINGULAR_STATE_DIR/fixture-workers" -name "$1" 2>/dev/null \
    | wc -l | tr -d ' '
}

wait_for_worker_marker() { # marker count description
  local marker="$1" count="$2" description="$3" tries=0
  while [[ "$(fixture_worker_count "$marker")" -lt "$count" ]]; do
    tries=$((tries + 1))
    if [[ "$tries" -ge 100 ]]; then
      find "$SINGULAR_STATE_DIR/fixture-workers" "$SINGULAR_DISPATCH_DIR" \
        -maxdepth 3 -type f -print 2>/dev/null >&2 || true
      fail "watchdog timed out waiting for $description ($count $marker marker(s))"
    fi
    sleep 0.1
  done
}

assert_workers_held() { # count description
  local count="$1" description="$2"
  wait_for_worker_marker started "$count" "$description to start"
  assert_eq "0" "$(fixture_worker_count completed)" \
    "$description completed before fixture release"
  assert_eq "0" "$(find "$SINGULAR_DISPATCH_DIR" -name '*.exit' 2>/dev/null | wc -l | tr -d ' ')" \
    "$description produced exit files before fixture release"
}

release_workers() {
  : >"$SINGULAR_STATE_DIR/fixture-release"
}

wait_for_process_group_gone() { # pgid description
  local pgid="$1" description="$2" tries=0
  while singular_pgroup_alive "$pgid"; do
    tries=$((tries + 1))
    [[ "$tries" -lt 50 ]] \
      || fail "watchdog timed out waiting for $description process group $pgid to exit"
    sleep 0.1
  done
}

test_detached_cycle_returns_fast_and_releases_lock() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_controlled_stub "$stub"

  # This scheduling delay deliberately exceeds the old four-second heuristic.
  # Correctness is instead the observable ordering below: reconcile returns,
  # its origin lock is gone, and both workers are still held by the fixture.
  sleep 4
  local cycle_out="$SINGULAR_STATE_DIR/fixture-cycle.out" out
  actuate_to_file "$stub" 2 1 "$cycle_out"
  out="$(cat "$cycle_out")"

  assert_eq "2" "$(field_of "$out" dispatched_this_run)" "detached cycle dispatched both tasks"
  assert_eq "1" "$(field_of "$out" detached_dispatch)" "detached flag reported"
  assert_workers_held 2 "detached workers"
  [[ ! -f "$SINGULAR_STATE_DIR/locks/origin.lock.json" ]] || fail "origin lock still held after detached cycle"

  # Negative control: the same ordering assertion must reject a worker already
  # completed when its cycle claims to have returned detached.
  local negative_state="$SINGULAR_ROOT/negative-control-state"
  mkdir -p "$negative_state/fixture-workers/TASK-NEG" "$negative_state/dispatch"
  : >"$negative_state/fixture-workers/TASK-NEG/started"
  : >"$negative_state/fixture-workers/TASK-NEG/completed"
  if (SINGULAR_STATE_DIR="$negative_state" SINGULAR_DISPATCH_DIR="$negative_state/dispatch" \
      assert_workers_held 1 "synchronous negative-control worker") >/dev/null 2>&1; then
    fail "ordering assertion accepted a synchronous/waiting negative control"
  fi

  # While the stubs are explicitly held: pre-leases hold the slots and the next
  # cycle defers without duplicate dispatch.
  local out2
  actuate_to_file "$stub" 2 1 "$cycle_out"
  out2="$(cat "$cycle_out")"
  assert_eq "0" "$(field_of "$out2" dispatched_this_run)" "no double dispatch while workers run"
  assert_eq "2" "$(field_of "$out2" workers_running)" "both workers observed running at cycle start"
  assert_contains "$out2" "max-concurrent cap reached" "ready tasks deferred while slots are held"
  assert_workers_held 2 "detached workers after second cycle"

  # Explicit release lets drain observe completion and reap both.
  local drain_out
  release_workers
  drain_out="$(SINGULAR_DRAIN_TIMEOUT_SECS=30 "$SCRIPT_DIR/reconcile.sh" --drain 2>&1)" || fail "drain did not exit cleanly"
  assert_contains "$drain_out" "no launched dispatch records remain" "drain completed"
  assert_eq "2" "$(fixture_worker_count released)" "both detached workers observed fixture release"
  assert_eq "2" "$(fixture_worker_count completed)" "both detached workers completed after release"
  assert_contains "$(cat "$SINGULAR_DISPATCH_DIR/TASK-0001.json")" '"state": "reaped"' "TASK-0001 record finalized"
  assert_contains "$(cat "$SINGULAR_DISPATCH_DIR/TASK-0002.json")" '"state": "reaped"' "TASK-0002 record finalized"
  [[ -z "$(find "$SINGULAR_DISPATCH_DIR" -name '*.exit' 2>/dev/null)" ]] || fail "exit files not cleaned up after reap"
}

test_detached_pre_lease_blocks_scope_overlap() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/shared.go "[]"
  write_task TASK-0002 ready internal/artifact/shared.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_controlled_stub "$stub"

  local cycle_out="$SINGULAR_STATE_DIR/fixture-cycle.out" out
  actuate_to_file "$stub" 2 1 "$cycle_out"
  out="$(cat "$cycle_out")"
  assert_eq "1" "$(field_of "$out" dispatched_this_run)" "only one task dispatched for a shared owned file"
  assert_workers_held 1 "overlap owner"

  # While TASK-0001 runs under its pre-lease, the overlapping TASK-0002 must
  # stay blocked even though a slot is free.
  local out2
  actuate_to_file "$stub" 2 1 "$cycle_out"
  out2="$(cat "$cycle_out")"
  assert_eq "0" "$(field_of "$out2" dispatched_this_run)" "scope overlap with a pre-leased running task blocks dispatch"
  assert_eq "1" "$(wc -l <"$SINGULAR_STATE_DIR/dispatch.log" | tr -d ' ')" "driver invoked exactly once"
  assert_workers_held 1 "overlap owner after second cycle"

  release_workers
  SINGULAR_DRAIN_TIMEOUT_SECS=30 "$SCRIPT_DIR/reconcile.sh" --drain >/dev/null 2>&1 \
    || fail "overlap fixture drain did not exit cleanly"
  assert_eq "1" "$(fixture_worker_count completed)" "overlap owner completed after release"
}

test_detached_reap_attributes_ok_and_failed() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_sleep_stub "$stub" 0
  echo 9 >"$SINGULAR_STATE_DIR/TASK-0002.ec"

  local out
  out="$(actuate "$stub" 2 1)"
  assert_eq "2" "$(field_of "$out" dispatched_this_run)" "both fast stubs dispatched"
  wait_for_exit_files 2
  [[ -f "$(singular_wake_file)" ]] \
    || fail "detached worker completion did not request an immediate scheduler wake"
  assert_contains "$(cat "$SINGULAR_STATE_DIR/events.ndjson")" \
    '"type":"origin.capacity_released"' "capacity release wake was not recorded"

  # Next cycle (no new dispatch): the reaper attributes one ok + one failure.
  local out2
  out2="$(actuate "$stub" 0 1)"
  assert_eq "1" "$(field_of "$out2" reaped_ok)" "one ok reap"
  assert_eq "1" "$(field_of "$out2" reaped_failures)" "one failed reap"
  assert_eq "0" "$(field_of "$out2" workers_running)" "no workers left running"

  local events
  events="$(cat "$SINGULAR_STATE_DIR/events.ndjson")"
  assert_contains "$events" '"type":"origin.dispatch_reaped"' "dispatch_reaped events emitted"
  assert_contains "$events" '"taskId":"TASK-0002","exitCode":9' "failure attributed with its exit code"

  # The stubs never took lease ownership, so the wrapper cleared the
  # pre-leases: the tasks are re-dispatchable, not stuck holding slots.
  [[ ! -f "$SINGULAR_LEASES_DIR/TASK-0001.json" ]] || fail "pre-lease for TASK-0001 not cleared"
  [[ ! -f "$SINGULAR_LEASES_DIR/TASK-0002.json" ]] || fail "pre-lease for TASK-0002 not cleared"
}

test_detached_crash_detected_by_pid() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_controlled_stub "$stub"

  local cycle_out="$SINGULAR_STATE_DIR/fixture-cycle.out" out
  actuate_to_file "$stub" 1 1 "$cycle_out"
  out="$(cat "$cycle_out")"
  assert_eq "1" "$(field_of "$out" dispatched_this_run)" "worker dispatched"
  assert_workers_held 1 "crash-control worker"

  local pid
  pid="$(singular_json_field "$SINGULAR_DISPATCH_DIR/TASK-0001.json" pid)"
  [[ -n "$pid" ]] || fail "dispatch record has no pid"
  # Kill the detached session (wrapper + stub) without letting it write an
  # exit file -- simulates a hard crash / SIGKILL.
  kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
  wait_for_process_group_gone "$pid" "crashed worker"

  local out2
  # 0.5.0 tree-liveness treats recent run-dir writes as maybe-alive (bounded
  # conservatism); disable the mtime window so the simulated hard crash reaps
  # immediately in this fixture.
  out2="$(SINGULAR_TREE_ACTIVITY_WINDOW_SEC=0 actuate "$stub" 0 1)"
  assert_eq "1" "$(field_of "$out2" reaped_failures)" "crash counted as a reap failure"
  assert_contains "$(cat "$SINGULAR_STATE_DIR/events.ndjson")" '"outcome":"crashed"' "crash outcome recorded"
  assert_eq "failed" "$(singular_json_field "$SINGULAR_LEASES_DIR/TASK-0001.json" status)" "crashed worker's lease marked failed"
}

test_batch_mode_shadow_accounting_parity() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_sleep_stub "$stub" 0
  echo 9 >"$SINGULAR_STATE_DIR/TASK-0002.ec"

  # Batch mode (flag off): the wait loop stays authoritative and emits
  # worker_reaped; records + exit files are left for the shadow reaper.
  local out
  out="$(actuate "$stub" 2 0)"
  assert_eq "2" "$(field_of "$out" dispatched_this_run)" "batch dispatched both"
  assert_eq "1" "$(field_of "$out" failed_dispatches)" "batch wait loop counted the failure"
  assert_eq "0" "$(field_of "$out" detached_dispatch)" "batch mode reported"

  local out2
  out2="$(actuate "$stub" 0 0)"
  assert_eq "1" "$(field_of "$out2" reaped_ok)" "shadow reaper saw the ok exit"
  assert_eq "1" "$(field_of "$out2" reaped_failures)" "shadow reaper saw the failed exit"

  # Parity: in-cycle wait accounting and out-of-process reap accounting agree.
  local waited reaped
  waited="$(grep -c '"type":"origin.worker_reaped"' "$SINGULAR_STATE_DIR/events.ndjson" || true)"
  reaped="$(grep -c '"type":"origin.dispatch_reaped"' "$SINGULAR_STATE_DIR/events.ndjson" || true)"
  assert_eq "$waited" "$reaped" "shadow reap count matches wait-loop reap count"
  assert_eq "2" "$waited" "both workers accounted"
}

test_autonomate_breaker_semantics_detached() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_controlled_stub "$stub"

  # Dispatch-only cycle: NOT progress (no reset) and NOT failure (no trip).
  local breaker_out="$SINGULAR_STATE_DIR/fixture-breaker.out" out
  (cd "$SINGULAR_ROOT" && SINGULAR_L1_DRIVER="$stub" SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 SINGULAR_PUSH=0 \
    SINGULAR_MAX_CONCURRENT=1 SINGULAR_MAX_DISPATCH=1 SINGULAR_DETACHED_DISPATCH=1 \
    "$SCRIPT_DIR/autonomate.sh" --once >"$breaker_out" 2>&1) || true
  out="$(cat "$breaker_out")"
  assert_contains "$out" "dispatched_this_run=1" "autonomate cycle dispatched"
  assert_workers_held 1 "breaker dispatch-only worker"
  assert_not_contains "$out" "breaker ->" "dispatch-only detached cycle must not trip the breaker"
  assert_eq "0" "$(singular_breaker_count)" "breaker untouched by dispatch-only cycle"
  release_workers
  SINGULAR_DRAIN_TIMEOUT_SECS=30 "$SCRIPT_DIR/reconcile.sh" --drain >/dev/null 2>&1 \
    || fail "breaker fixture drain did not exit cleanly"
  assert_eq "1" "$(fixture_worker_count completed)" "breaker worker completed after release"

  # Reap-failure cycle (a previously detached worker failed): trips the breaker.
  with_fixture
  singular_dispatch_record_write "TASK-9001" "RUN-FAKE" "99999999" "" "/dev/null" "sha" "batch"
  singular_dispatch_exit_write "TASK-9001" 9
  local out2
  out2="$(cd "$SINGULAR_ROOT" && SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 SINGULAR_PUSH=0 \
    SINGULAR_MAX_CONCURRENT=0 SINGULAR_MAX_DISPATCH=0 SINGULAR_DETACHED_DISPATCH=1 \
    "$SCRIPT_DIR/autonomate.sh" --once 2>&1)" || true
  assert_contains "$out2" "reaped_failures=1" "reap failure surfaced to autonomate"
  assert_contains "$out2" "breaker -> 1" "reap failure trips the breaker"
  assert_eq "1" "$(singular_breaker_count)" "breaker incremented by reap failure"
}

test_atomic_state_writes_leave_no_tmp() {
  with_fixture
  singular_lease_write TASK-0001 agent/artifact/TASK-0001 artifact l2 "internal/a.go" running RUN-X "" sha batch '["internal/a.go"]' "[]"
  singular_lease_set_status TASK-0001 needs-review
  singular_lease_update_owned TASK-0001 '["internal/a.go","internal/b.go"]'
  singular_lease_bump_retry TASK-0001 >/dev/null
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  singular_task_set_status "$SINGULAR_TASKS_DIR/TASK-0002.md" blocked

  [[ -z "$(find "$SINGULAR_LEASES_DIR" "$SINGULAR_TASKS_DIR" -name '*.tmp' 2>/dev/null)" ]] \
    || fail "atomic writes left .tmp residue"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SINGULAR_LEASES_DIR/TASK-0001.json" \
    || fail "lease not valid JSON after atomic writes"
  assert_eq "needs-review" "$(singular_json_field "$SINGULAR_LEASES_DIR/TASK-0001.json" status)" "status survived atomic rewrite chain"
  assert_contains "$(cat "$SINGULAR_TASKS_DIR/TASK-0002.md")" "Status: blocked" "task status rewritten atomically"
}

test_detached_cycle_returns_fast_and_releases_lock
test_detached_pre_lease_blocks_scope_overlap
test_detached_reap_attributes_ok_and_failed
test_detached_crash_detected_by_pid
test_batch_mode_shadow_accounting_parity
test_autonomate_breaker_semantics_detached
test_atomic_state_writes_leave_no_tmp

echo "detached dispatch tests passed"
