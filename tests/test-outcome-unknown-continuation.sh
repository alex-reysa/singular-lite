#!/usr/bin/env bash
set -euo pipefail

# Recovery of a STARTED attempt whose driver exited without a terminal
# disposition. `finish` records terminalDisposition.kind="outcome-unknown" and
# drops the live reservation owner, so the orphan-reservation reconciler can
# never match and `authorize_continuation` used to refuse forever — the retained
# worker output became unrecoverable through every public verb.
#
# This drives the PUBLIC path end to end: reserve -> started attempt -> finish
# -> host authorization -> native reserve/claim, and pins the identity refusals.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-outcome-unknown-continuation.sh requires bash >= 4" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/engine"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

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
cat >"$repo/docs/orchestration/tasks/TASK-1120.md" <<'MD'
# TASK-1120: interrupted started attempt fixture
Status: ready
Area: brain
Target branch: `target`
Worker branch: `agent/brain/TASK-1120`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []
## Objective
Continue a started attempt whose driver exited without a terminal disposition.
## Scope
Owned files:
- `app.txt`
## Acceptance Criteria
- The retained worker output survives one native continuation.
MD
printf 'base\n' >"$repo/app.txt"
printf '%s\n' '.singular-state/' '.worktrees/' >"$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit -qm base
reservation_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" branch agent/brain/TASK-1120
mkdir -p "$repo/.worktrees"
git -C "$repo" worktree add -q "$repo/.worktrees/TASK-1120" agent/brain/TASK-1120
worktree="$repo/.worktrees/TASK-1120"

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

lease_path="$(singular_lease_path TASK-1120)"
# The lease carries the executed WORKER run; the dispatch record carries the
# RESERVATION run. They are distinct, and the recovery must not conflate them.
owner='reconcile:RUN-RESERVATION:TASK-1120'
worker_run='RUN-WORKER-ATTEMPT'
generation="$(singular_lifecycle_reserve TASK-1120 "$owner" RUN-RESERVATION \
  agent/brain/TASK-1120 brain '["app.txt"]' "$reservation_base" BATCH-A "$worktree")"
[[ "$generation" == 1 ]] || fail "unexpected generation: $generation"
# The scheduler binds a dispatch record before the driver runs; record-attempt and
# finish both read the reservation run and campaign binding from it.
singular_lifecycle_dispatch_record_write TASK-1120 RUN-RESERVATION "$$" 0 \
  "$tmp/dispatch.log" "$reservation_base" BATCH-A "$owner" "$generation" >/dev/null
predecessor_campaign="$(singular_json_field "$(singular_dispatch_record_path TASK-1120)" campaignBinding)"
[[ -n "$predecessor_campaign" ]] || fail "fixture produced no campaign binding"

# A dispatched driver runs under its own worker run id while the reservation run
# stays on the dispatch record. This fixture sets that split exactly as a live
# dispatch leaves it (the same technique the orphan-continuation fixture uses).
python3 - "$lease_path" "$worker_run" <<'PYSETUP' || fail "fixture could not set the executed worker run"
import json, os, sys
path, worker_run = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding="utf-8"))
d["runId"] = worker_run
d["productPassStarted"] = True
d["productPassStartedRunId"] = worker_run
tmp = path + ".tmp"
json.dump(d, open(tmp, "w", encoding="utf-8"), indent=2)
os.replace(tmp, path)
PYSETUP
singular_lifecycle_record_attempt TASK-1120 "$owner" "$generation" "$worker_run" started >/dev/null

# Real worker output, committed on the candidate branch, exactly as l1-drive does.
printf 'worker output\n' >"$worktree/app.txt"
printf 'untracked partial\n' >"$worktree/untracked.txt"
git -C "$worktree" add app.txt
git -C "$worktree" -c user.name=w -c user.email=w@w commit -qm 'TASK-1120: worker output'
worker_commit="$(git -C "$worktree" rev-parse HEAD)"
tracked_before="$(shasum -a 256 "$worktree/app.txt" | awk '{print $1}')"
untracked_before="$(shasum -a 256 "$worktree/untracked.txt" | awk '{print $1}')"

# The integration target advances (gate/control-state commits), and the retained
# candidate is base-refreshed onto it by merge, which is the real TASK-1116 shape.
git -C "$repo" checkout -q target
printf 'advanced\n' >"$repo/target-advanced.txt"
git -C "$repo" add target-advanced.txt
git -C "$repo" commit -qm 'target advanced'
integration_target="$(git -C "$repo" rev-parse target)"
git -C "$worktree" -c user.name=w -c user.email=w@w merge -q --no-ff "$integration_target" -m 'merge: refresh candidate onto admitted base'
candidate_source="$(git -C "$worktree" rev-parse HEAD)"
[[ "$candidate_source" != "$worker_commit" ]] || fail "fixture did not produce a base-refresh merge"

# The driver exits without publishing a terminal disposition.
singular_lifecycle_finish TASK-1120 "$owner" "$generation" BATCH-A \
  driver-exited-before-terminal 'inspect preserved attempt artifacts' >/dev/null
# The reaper closes the dead dispatch generation, exactly as recover.sh does.
singular_lifecycle_dispatch_finalize TASK-1120 -1 crashed "$owner" "$generation"

python3 - "$lease_path" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
t = d.get("terminalDisposition") or {}
assert t.get("kind") == "outcome-unknown", f"expected outcome-unknown, got {t.get('kind')!r}"
assert d.get("productPassStarted") is True, "fixture did not record a started product pass"
assert not d.get("reservationOwner"), "fixture still holds a live reservation owner"
assert (d.get("attemptLifecycle") or {}).get("state") == "started", "attempt is not started"
PY
pass "fixture reproduces the public outcome-unknown state"

recover_env=(env PYTHONDONTWRITEBYTECODE=1 SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" SINGULAR_ORCH_DIR="$SINGULAR_ORCH_DIR" \
  SINGULAR_TASKS_DIR="$SINGULAR_TASKS_DIR" SINGULAR_LEASES_DIR="$SINGULAR_LEASES_DIR" \
  SINGULAR_DISPATCH_DIR="$SINGULAR_DISPATCH_DIR" SINGULAR_RUNS_DIR="$SINGULAR_RUNS_DIR" \
  SINGULAR_WORKTREES_DIR="$SINGULAR_WORKTREES_DIR" SINGULAR_INBOX_DIR="$SINGULAR_INBOX_DIR" \
  SINGULAR_EVENTS_FILE="$SINGULAR_EVENTS_FILE" SINGULAR_TARGET_BRANCH=target)

continuation_args=(continuation TASK-1120 --predecessor-owner "$owner"
  --predecessor-generation "$generation" --predecessor-run RUN-RESERVATION
  --predecessor-campaign "$predecessor_campaign"
  --predecessor-reservation-base "$reservation_base"
  --candidate-source "$candidate_source" --integration-target "$integration_target"
  --worktree "$worktree")

# Identity refusals, asserted BEFORE any authority exists so each one is proven
# by the new identity validation itself and not by the one-shot guards that a
# successful authorization would otherwise leave behind.
for mismatch in owner generation run campaign base worktree candidate; do
  args=("${continuation_args[@]}")
  case "$mismatch" in
    owner)      args[3]='reconcile:RUN-WRONG:TASK-1120' ;;
    generation) args[5]=9 ;;
    run)        args[7]='RUN-WRONG' ;;
    campaign)   args[9]='campaign:wrong' ;;
    base)       args[11]="$integration_target" ;;
    candidate)  args[13]="$worker_commit" ;;
    worktree)   args[17]="$tmp/wrong-worktree" ;;
  esac
  if "${recover_env[@]}" "$ROOT/engine/recover.sh" "${args[@]}" >/dev/null 2>&1; then
    fail "continuation accepted a $mismatch mismatch"
  fi
done
pass "stale or mismatched predecessor identity is refused"
[[ ! -f "$lease_path" ]] || python3 - "$lease_path" <<'PYNOAUTH' || fail "a refused attempt left continuation authority behind"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert not isinstance(d.get("continuationAuthorization"), dict), "refused attempt issued authority"
PYNOAUTH

out="$("${recover_env[@]}" "$ROOT/engine/recover.sh" "${continuation_args[@]}")" \
  || fail "outcome-unknown continuation was refused"
authorization_id="$(printf '%s\n' "$out" | sed -n 's/^authorizationId=//p')"
[[ -n "$authorization_id" ]] || fail "no continuation authority was issued"
pass "outcome-unknown continuation issues one-shot authority"

[[ "$(git -C "$worktree" rev-parse HEAD)" == "$candidate_source" ]] \
  || fail "authorization moved the candidate head"
[[ "$(shasum -a 256 "$worktree/app.txt" | awk '{print $1}')" == "$tracked_before" ]] \
  || fail "authorization changed retained tracked bytes"
[[ "$(shasum -a 256 "$worktree/untracked.txt" | awk '{print $1}')" == "$untracked_before" ]] \
  || fail "authorization changed retained untracked bytes"
git -C "$worktree" merge-base --is-ancestor "$worker_commit" HEAD \
  || fail "the preserved worker commit is no longer reachable"
pass "preserved worker output and partial bytes are untouched"

if "${recover_env[@]}" "$ROOT/engine/recover.sh" "${continuation_args[@]}" >/dev/null 2>&1; then
  fail "a replayed authorization replaced the one-shot authority"
fi
pass "replay is refused (one-shot authority)"

python3 - "$lease_path" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
a = d.get("continuationAuthorization")
assert isinstance(a, dict), "no durable continuation authority on the lease"
assert a.get("state") == "issued", f"authority state {a.get('state')!r}"
assert a.get("additionalWorkerAttemptsAuthorized") == 1, "authority is not one-shot"
assert a.get("additionalWorkerAttemptsClaimed") == 0, "authority was pre-claimed"
hist = d.get("terminalDispositionHistory")
assert d.get("retryCount") == 0, "recovery altered product accounting"
PY
pass "authority is durable, one-shot and leaves accounting intact"


# A native reservation claims the one-shot authority exactly once. The claim
# runs on the reservation's own bound dispatch record, and — exactly as in the
# predecessor — the executed worker run is distinct from the reservation run.
next_owner='reconcile:RUN-CONTINUE:TASK-1120'
next_worker_run='RUN-CONTINUE-WORKER'
candidate_base="$(git -C "$repo" merge-base "$candidate_source" "$integration_target")"
next_generation="$(singular_lifecycle_reserve TASK-1120 "$next_owner" RUN-CONTINUE \
  agent/brain/TASK-1120 brain '["app.txt"]' "$candidate_source" BATCH-B "$worktree")"
[[ "$next_generation" == 2 ]] || fail "continuation reservation did not advance generation: $next_generation"
singular_lifecycle_dispatch_record_write TASK-1120 RUN-CONTINUE "$$" 0 \
  "$tmp/continue-dispatch.log" "$candidate_source" BATCH-B "$next_owner" \
  "$next_generation" >/dev/null
singular_lifecycle_claim_continuation TASK-1120 "$authorization_id" "$next_owner" \
  "$next_generation" "$next_worker_run" "$candidate_source" "$integration_target" \
  "$worktree" "$SINGULAR_TASKS_DIR/TASK-1120.md" "$candidate_base" \
  >/dev/null || fail "native reservation could not claim the continuation"
python3 - "$lease_path" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
a = d.get("continuationAuthorization") or {}
assert a.get("additionalWorkerAttemptsClaimed") == 1, f"claim count {a.get('additionalWorkerAttemptsClaimed')!r}"
PY
if singular_lifecycle_claim_continuation TASK-1120 "$authorization_id" "$next_owner" \
    "$next_generation" "$next_worker_run" "$candidate_source" "$integration_target" \
    "$worktree" "$SINGULAR_TASKS_DIR/TASK-1120.md" "$candidate_base" \
    >/dev/null 2>&1; then
  fail "the one-shot continuation was claimed twice"
fi
pass "native reserve/claim consumes the authority exactly once"

# Live ownership must block a fresh authorization.
if "${recover_env[@]}" "$ROOT/engine/recover.sh" "${continuation_args[@]}" >/dev/null 2>&1; then
  fail "continuation was authorized while the reservation is actively owned"
fi
pass "active ownership is refused"

echo "PASS: test-outcome-unknown-continuation"
