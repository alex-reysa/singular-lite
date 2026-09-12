#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-autonomate-progress-accounting.sh requires bash >= 4" >&2; exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/.singular-state" "$repo/docs/orchestration/tasks"
repo_resolved="$(cd "$repo" && pwd -P)"
git -C "$tmp" init -q repo
git -C "$repo" checkout -q -b target
git -C "$repo" -c user.email=test@example.com -c user.name=test \
  commit -q --allow-empty -m init

fail() { echo "FAIL: $*" >&2; exit 1; }

env_common() {
  env SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_EVENTS_FILE="$repo/.singular-state/events.ndjson" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_PUSH=0 SINGULAR_SLEEP=0 \
    SINGULAR_TEST_PROCESS_CONTROL=1 SINGULAR_TEST_PROCESS_CONTROL_STATE=ok \
    "$@"
}

breaker_count() {
  env_common bash -c "source '$ROOT/engine/lib.sh'; singular_breaker_count"
}

trip_breaker_twice() {
  env_common bash -c \
    "source '$ROOT/engine/lib.sh'; singular_breaker_reset; singular_breaker_trip >/dev/null; singular_breaker_trip >/dev/null"
}

write_stub() {
  local imported="$1" integrated="$2" promoted="$3" generated="$4"
  cat >"$repo/reconcile-stub.sh" <<SH
#!/usr/bin/env bash
[[ "\${SINGULAR_JSON_CONFIG_SOURCE:-}" == "default" ]] || exit 91
[[ "\${SINGULAR_JSON_CONFIG_FILE:-}" == "$repo_resolved/singular.config.json" ]] || exit 92
[[ "\${SINGULAR_JSON_CONFIG_DEFAULT_ROOT:-}" == "$repo_resolved" ]] || exit 93
[[ "\${SINGULAR_JSON_CONFIG_DEFAULT_FILE:-}" == "$repo_resolved/singular.config.json" ]] || exit 94
echo "imported_this_run=$imported"
echo "dispatched_this_run=1"
echo "integrated_this_run=$integrated"
echo "failed_dispatches=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "planner_backoff_active_this_run=0"
echo "l1_import_rejections_this_run=0"
echo "reaped_ok=1"
echo "reaped_failures=0"
echo "workers_running=0"
echo "gates_promoted_this_run=$promoted"
SH
  if [[ "$generated" == "yes" ]]; then
    printf '%s\n' 'echo "gen: generated:TASK-0001"' >>"$repo/reconcile-stub.sh"
  fi
  chmod +x "$repo/reconcile-stub.sh"
}

run_once() {
  env_common SINGULAR_RECONCILE_SCRIPT="$repo/reconcile-stub.sh" \
    bash "$ROOT/engine/autonomate.sh" --once >"$tmp/autonomate.log" 2>&1 || {
      cat "$tmp/autonomate.log" >&2
      return 1
    }
}

# Exercise the same absent-default boundary through the two real child
# entrypoints used by autonomate. Provider executables remain unavailable.
env_common bash "$ROOT/engine/campaign.sh" verify --quiet
resource_plan="$(env_common bash "$ROOT/engine/resource-plan.sh" \
  --configured-slots 3 --reserve-bytes 0 --estimated-worktree-bytes 1 \
  --free-bytes 2 --json)"
python3 - "$resource_plan" <<'PY'
import json, sys
plan = json.loads(sys.argv[1])
assert plan["configuredSlots"] == 3, plan
assert plan["effectiveSlots"] == 2, plan
assert plan["reason"] == "disk-limited-concurrency", plan
PY

# A wake that is already pending must be consumed before the first sleep
# chunk.  This keeps detached completion/refill notifications truly immediate.
wake="$repo/.singular-state/WAKE"
: >"$wake"
wake_started=$SECONDS
wake_rc=0
env_common SINGULAR_SLEEP_POLL_SEC=10 bash -c \
  "source '$ROOT/engine/lib.sh'; singular_interruptible_sleep 10" || wake_rc=$?
[[ "$wake_rc" == "1" ]] || fail "pending wake did not interrupt sleep (rc=$wake_rc)"
[[ $((SECONDS - wake_started)) -lt 3 ]] || fail "pending wake waited for the first poll interval"
[[ ! -e "$wake" ]] || fail "pending wake was not consumed"

# Restart, generation, dispatch and an exit-zero reap are not durable progress.
trip_breaker_twice
write_stub 0 0 0 yes
run_once
[[ "$(breaker_count)" == "2" ]] \
  || fail "non-durable activity reset the breaker (got $(breaker_count), want 2)"

# An imported packet has already passed the exact-head acceptance boundary.
write_stub 1 0 0 no
run_once
[[ "$(breaker_count)" == "0" ]] \
  || fail "accepted packet import did not reset the breaker"

# Gate promotion is a monotone DAG transition and also resets it.
trip_breaker_twice
write_stub 0 0 1 no
run_once
[[ "$(breaker_count)" == "0" ]] \
  || fail "DAG gate promotion did not reset the breaker"

echo "PASS: test-autonomate-progress-accounting"
