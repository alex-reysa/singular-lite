#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-orphan-continuation.sh requires bash >= 4" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/engine"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/tasks" "$repo/docs/orchestration/prompts"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.local
git -C "$repo" checkout -qb target
cp "$ROOT/templates/prompts/l2-test-first-developer.md" "$repo/docs/orchestration/prompts/"
cp "$ROOT/templates/prompts/auditor.md" "$repo/docs/orchestration/prompts/"
cat >"$repo/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"target","gateCommand":"true","bootstrap":{"required":false,"commands":[]}}
JSON
cat >"$repo/docs/orchestration/tasks/TASK-1108.md" <<'MD'
# TASK-1108: preserved orphan continuation fixture
Status: ready
Area: brain
Target branch: `target`
Worker branch: `agent/brain/TASK-1108`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []
## Objective
Continue retained partial work through the native worker path.
## Scope
Owned files:
- `app.txt`
## Acceptance Criteria
- The retained partial bytes survive one native continuation.
MD
printf 'base\n' >"$repo/app.txt"
printf '%s\n' '.singular-state/' '.worktrees/' >"$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit -qm base
predecessor_source="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" branch agent/brain/TASK-1108
mkdir -p "$repo/.worktrees"
git -C "$repo" worktree add -q "$repo/.worktrees/TASK-1108" agent/brain/TASK-1108
printf 'successor engine bytes\n' >"$repo/engine-current.txt"
git -C "$repo" add engine-current.txt
git -C "$repo" commit -qm 'current engine source'
successor_source="$(git -C "$repo" rev-parse HEAD)"

worktree="$repo/.worktrees/TASK-1108"
printf 'retained tracked partial\n' >"$worktree/app.txt"
printf 'retained untracked partial\n' >"$worktree/untracked.txt"
tracked_before="$(shasum -a 256 "$worktree/app.txt" | awk '{print $1}')"
untracked_before="$(shasum -a 256 "$worktree/untracked.txt" | awk '{print $1}')"

export SINGULAR_ROOT="$repo"
export SINGULAR_STATE_DIR="$repo/.singular-state"
export SINGULAR_ORCH_DIR="$repo/docs/orchestration"
export SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks"
export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
export SINGULAR_DISPATCH_DIR="$SINGULAR_STATE_DIR/dispatch"
export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
export SINGULAR_WORKTREES_DIR="$repo/.worktrees"
export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
export SINGULAR_TARGET_BRANCH=target
mkdir -p "$SINGULAR_LEASES_DIR" "$SINGULAR_DISPATCH_DIR" "$SINGULAR_RUNS_DIR" "$SINGULAR_INBOX_DIR"

# shellcheck source=/dev/null
source "$ROOT/engine/lib.sh"
# shellcheck source=/dev/null
source "$ROOT/engine/lifecycle.sh"

owner='reconcile:RUN-OLD:TASK-1108'
generation="$(singular_lifecycle_reserve TASK-1108 "$owner" RUN-OLD \
  agent/brain/TASK-1108 brain '["app.txt"]' "$successor_source" BATCH-OLD "$worktree")"
[[ "$generation" == 1 ]] || fail "unexpected predecessor generation: $generation"
python3 - "$(singular_lease_path TASK-1108)" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["status"] = "planned"
d["productPassStarted"] = True
d["productPassStartedRunId"] = "RUN-ORIGINAL-ATTEMPT"
d["retryCount"] = 0
d["maxRetries"] = 1
t = p + ".tmp"
json.dump(d, open(t, "w", encoding="utf-8"), indent=2)
os.replace(t, p)
PY

recover_env=(env PYTHONDONTWRITEBYTECODE=1 SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" SINGULAR_ORCH_DIR="$SINGULAR_ORCH_DIR" \
  SINGULAR_TASKS_DIR="$SINGULAR_TASKS_DIR" SINGULAR_LEASES_DIR="$SINGULAR_LEASES_DIR" \
  SINGULAR_DISPATCH_DIR="$SINGULAR_DISPATCH_DIR" SINGULAR_RUNS_DIR="$SINGULAR_RUNS_DIR" \
  SINGULAR_WORKTREES_DIR="$SINGULAR_WORKTREES_DIR" SINGULAR_INBOX_DIR="$SINGULAR_INBOX_DIR" \
  SINGULAR_EVENTS_FILE="$SINGULAR_EVENTS_FILE" SINGULAR_TARGET_BRANCH=target)

reconcile_args=(orphan-reservation TASK-1108 --owner "$owner" --generation "$generation" \
  --run RUN-OLD --campaign legacy --reservation-base "$successor_source" \
  --candidate-source "$predecessor_source" --worktree "$worktree")
"${recover_env[@]}" "$ROOT/engine/recover.sh" "${reconcile_args[@]}" >/dev/null
"${recover_env[@]}" "$ROOT/engine/recover.sh" "${reconcile_args[@]}" >/dev/null \
  || fail "exact orphan reconciliation was not restart-idempotent"

for mismatch in owner generation run campaign reservation-base candidate-source worktree; do
  args=("${reconcile_args[@]}")
  case "$mismatch" in
    owner) args[3]='wrong-owner' ;;
    generation) args[5]=9 ;;
    run) args[7]='RUN-WRONG' ;;
    campaign) args[9]='campaign:wrong' ;;
    reservation-base) args[11]="$predecessor_source" ;;
    candidate-source) args[13]="$successor_source" ;;
    worktree) args[15]="$tmp/wrong-worktree" ;;
  esac
  if "${recover_env[@]}" "$ROOT/engine/recover.sh" "${args[@]}" >/dev/null 2>&1; then
    fail "reconciled orphan accepted $mismatch mismatch"
  fi
done

continuation_out="$("${recover_env[@]}" "$ROOT/engine/recover.sh" continuation TASK-1108 \
  --predecessor-owner "$owner" --predecessor-generation "$generation" \
  --predecessor-run RUN-OLD --predecessor-campaign legacy \
  --predecessor-reservation-base "$successor_source" \
  --candidate-source "$predecessor_source" --integration-target "$successor_source" \
  --worktree "$worktree")"
authorization_id="$(printf '%s\n' "$continuation_out" | sed -n 's/^authorizationId=//p')"
[[ -n "$authorization_id" ]] || fail "continuation authority was not issued"
[[ "$(git -C "$worktree" rev-parse HEAD)" == "$predecessor_source" ]] \
  || fail "continuation changed the preserved candidate base"
[[ "$(shasum -a 256 "$worktree/app.txt" | awk '{print $1}')" == "$tracked_before" ]] \
  || fail "tracked partial bytes changed during source fast-forward"
[[ "$(shasum -a 256 "$worktree/untracked.txt" | awk '{print $1}')" == "$untracked_before" ]] \
  || fail "untracked partial bytes changed during source fast-forward"
if "${recover_env[@]}" "$ROOT/engine/recover.sh" continuation TASK-1108 \
    --predecessor-owner "$owner" --predecessor-generation "$generation" \
    --predecessor-run RUN-OLD --predecessor-campaign legacy \
    --predecessor-reservation-base "$successor_source" \
    --candidate-source "$predecessor_source" --integration-target "$successor_source" \
    --worktree "$worktree" >/dev/null 2>&1; then
  fail "a second continuation authority replaced the one-shot authority"
fi

# The target may advance after authorization (for example, through a
# control-state-only commit). It remains safe because the authorized target is
# an ancestor while the frozen engine fingerprint and candidate bytes stay
# unchanged.
mkdir -p "$repo/docs/orchestration"
printf '# control state\n' >"$repo/docs/orchestration/project-state.md"
git -C "$repo" add docs/orchestration/project-state.md
git -C "$repo" commit -qm 'advance target control state'
advanced_target="$(git -C "$repo" rev-parse HEAD)"

if singular_lifecycle_reserve TASK-1108 reconcile:RUN-WRONG:TASK-1108 RUN-WRONG \
    agent/brain/TASK-1108 brain '["app.txt"]' "$predecessor_source" BATCH-WRONG "$worktree" \
    >/dev/null 2>&1; then
  fail "continuation reservation accepted the wrong successor source"
fi

# A preparation failure happens before the one-shot claim. Finish returns the
# same exact authority to issued state, so a fresh public reservation can retry
# without losing partial bytes or spending the worker invocation.
: >"$tmp/preparation-calls"
never_runner="$tmp/never-runner.sh"
cat >"$never_runner" <<'SH'
#!/usr/bin/env bash
printf 'unexpected\n' >>"${PREPARATION_CALLS:?}"
exit 99
SH
chmod +x "$never_runner"
prepare_owner='reconcile:RUN-PREPARE:TASK-1108'
prepare_generation="$(singular_lifecycle_reserve TASK-1108 "$prepare_owner" RUN-PREPARE \
  agent/brain/TASK-1108 brain '["app.txt"]' "$advanced_target" BATCH-PREPARE "$worktree")"
singular_lifecycle_dispatch_record_write TASK-1108 RUN-PREPARE $$ gone "$tmp/prepare-dispatch.log" \
  "$advanced_target" BATCH-PREPARE "$prepare_owner" "$prepare_generation"
prepare_rc=0
PREPARATION_CALLS="$tmp/preparation-calls" SINGULAR_RUNNER="$never_runner" \
  SINGULAR_WORKTREE_COPY_PATHS_JSON='not-json' \
  "$ROOT/engine/dispatch-wrap.sh" TASK-1108 "$ROOT/engine/l1-drive.sh" \
    "$prepare_owner" "$prepare_generation" BATCH-PREPARE \
    >"$tmp/preparation-failure.log" 2>&1 || prepare_rc=$?
[[ "$prepare_rc" == 3 ]] || fail "preparation failure was not terminal (rc=$prepare_rc)"
[[ ! -s "$tmp/preparation-calls" ]] || fail "preparation failure invoked the worker"
python3 - "$(singular_lease_path TASK-1108)" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "ready", d
assert d["continuationAuthorization"]["state"] == "issued", d
assert "reservationOwner" not in d, d
PY
[[ "$(singular_task_field "$SINGULAR_TASKS_DIR/TASK-1108.md" status)" == ready ]] \
  || fail "preparation failure changed the ready task contract"
[[ "$(shasum -a 256 "$worktree/app.txt" | awk '{print $1}')" == "$tracked_before" ]] \
  || fail "preparation failure changed retained tracked bytes"
singular_lifecycle_dispatch_finalize TASK-1108 "$prepare_rc" terminal \
  "$prepare_owner" "$prepare_generation"

next_owner='reconcile:RUN-NEXT:TASK-1108'
next_generation="$(singular_lifecycle_reserve TASK-1108 "$next_owner" RUN-NEXT \
  agent/brain/TASK-1108 brain '["app.txt"]' "$advanced_target" BATCH-NEXT "$worktree")"
[[ "$next_generation" == 3 ]] || fail "continuation did not retain generation history"
python3 - "$(singular_lease_path TASK-1108)" "$next_owner" "$next_generation" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
a = d["continuationAuthorization"]
assert a["state"] == "reserved", d
assert a["reservationOwner"] == sys.argv[2], d
assert a["reservationGeneration"] == int(sys.argv[3]), d
assert a["integrationTargetSha"], d
assert a["engineSourceFingerprint"] == "legacy", d
PY

mock="$tmp/continuation-runner.sh"
cat >"$mock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
worktree=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--worktree) worktree="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$(cat "$worktree/app.txt")" == 'retained tracked partial' ]]
[[ "$(cat "$worktree/untracked.txt")" == 'retained untracked partial' ]]
[[ "${SINGULAR_TEST_TASK_ID:-}" == TASK-1108 ]]
[[ "${SINGULAR_TEST_TASK_CONTRACT:-}" == "${SINGULAR_TEST_TASKS_DIR:-}/TASK-1108.md" ]]
printf 'invoked\n' >>"${CONTINUATION_CALLS:?}"
exit 124
SH
chmod +x "$mock"
: >"$tmp/calls"
singular_lifecycle_dispatch_record_write TASK-1108 RUN-NEXT $$ gone "$tmp/dispatch.log" \
  "$advanced_target" BATCH-NEXT "$next_owner" "$next_generation"
rc=0
CONTINUATION_CALLS="$tmp/calls" SINGULAR_RUNNER="$mock" SINGULAR_WORKER_INFRA_MAX=0 \
  "$ROOT/engine/dispatch-wrap.sh" TASK-1108 "$ROOT/engine/l1-drive.sh" \
    "$next_owner" "$next_generation" BATCH-NEXT >"$tmp/native-continuation.log" 2>&1 || rc=$?
[[ "$rc" == 3 ]] || fail "native continuation did not publish terminal infra state (rc=$rc): $(cat "$tmp/native-continuation.log")"
[[ "$(wc -l <"$tmp/calls" | tr -d '[:space:]')" == 1 ]] \
  || fail "native continuation did not invoke exactly one worker"
[[ -d "$worktree" ]] || fail "native continuation deleted the preserved worktree"
[[ "$(shasum -a 256 "$worktree/app.txt" | awk '{print $1}')" == "$tracked_before" ]] \
  || fail "native continuation changed retained tracked bytes"
[[ "$(shasum -a 256 "$worktree/untracked.txt" | awk '{print $1}')" == "$untracked_before" ]] \
  || fail "native continuation changed retained untracked bytes"
python3 - "$(singular_lease_path TASK-1108)" "$authorization_id" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["retryCount"] == 0, d
assert d["maxRetries"] == 1, d
assert d["productPassStarted"] is True, d
assert d["continuationAuthorization"]["authorizationId"] == sys.argv[2], d
assert d["continuationAuthorization"]["state"] == "claimed", d
assert d["continuationAuthorization"]["additionalWorkerAttemptsClaimed"] == 1, d
assert d["continuationAuthorization"]["additionalWorkerAttemptsRemaining"] == 0, d
assert d["terminalDisposition"]["kind"] == "blocked", d
assert d["terminalDispositionHistory"][0]["kind"] == "orphan-reservation", d
PY
if singular_lifecycle_reserve TASK-1108 reconcile:RUN-REPLAY:TASK-1108 RUN-REPLAY \
    agent/brain/TASK-1108 brain '["app.txt"]' "$advanced_target" BATCH-REPLAY "$worktree" \
    >/dev/null 2>&1; then
  fail "claimed continuation authority was replayed"
fi

echo "PASS: test-orphan-continuation"
