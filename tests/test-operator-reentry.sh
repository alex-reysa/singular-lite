#!/usr/bin/env bash
set -euo pipefail
# `singular unpark` is the public operator re-entry. Field run 2026-09-14: it
# left the failed attempt's attemptLifecycle/terminalDisposition on the lease,
# reserve() refused every redispatch ("terminal or started work requires
# explicit successor authority"), and after a hand archive the next driver
# refusal DELETED the lease (planned + productPassStarted=false) with its
# history. This pins: unpark archives history, reserve admits, and a refused
# driver releases (never deletes) a lease that carries history.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-operator-reentry.sh requires bash >= 4" >&2; exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/engine"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo"; git -C "$repo" init -q; git -C "$repo" commit -q --allow-empty -m base
export SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state"
source "$ROOT/engine/lib.sh" >/dev/null
source "$ROOT/engine/lifecycle.sh" >/dev/null
singular_ensure_state_dirs
lease="$(singular_lease_path TASK-1117)"
mkdir -p "$(dirname "$lease")"
cat >"$lease" <<'JSON'
{"taskId":"TASK-1117","status":"blocked","branch":"b","runId":"RUN-OLD","retryCount":0,
 "productPassStarted":true,"productPassStartedRunId":"RUN-OLD","maxRetries":1,
 "attemptLifecycle":{"state":"terminal","runId":"RUN-OLD","reservationOwner":"o1","reservationGeneration":1,"reservationRunId":"ORIGIN-OLD","disposition":"blocked","failureClass":"worker-no-packet"},
 "terminalDisposition":{"kind":"blocked","runId":"RUN-OLD","reservationOwner":"o1","reservationGeneration":1,"reservationRunId":"ORIGIN-OLD","failureClass":"worker-no-packet"},
 "lastReservationOwner":"o1","lastReservationGeneration":1}
JSON

singular_lease_unpark TASK-1117 || fail "unpark failed"
python3 - "$lease" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert "attemptLifecycle" not in d and "terminalDisposition" not in d, "terminal records still live on the lease"
assert d["attemptHistory"][0]["runId"] == "RUN-OLD" and d["terminalDispositionHistory"][0]["runId"] == "RUN-OLD"
assert d["operatorReentries"][0]["archivedRunId"] == "RUN-OLD" and d["operatorReentries"][0]["previousStatus"] == "blocked"
assert d["status"] == "ready" and d["retryCount"] == 0 and d["productPassStarted"] is False
PY
pass "unpark archives the terminal attempt into history and resets the pass budget"

gen="$(singular_lifecycle_reserve TASK-1117 o2 ORIGIN-NEW b brain '["app.txt"]' \
  "$(git -C "$repo" rev-parse HEAD)" BATCH "$repo/.worktrees/TASK-1117")" \
  || fail "reserve refused an unparked lease"
[[ "$gen" == 2 ]] || fail "reserve did not continue the generation sequence: $gen"
pass "reserve admits the unparked lease (generation $gen)"
singular_lifecycle_dispatch_record_write TASK-1117 ORIGIN-NEW "$$" 0 "$tmp/d.log" \
  "$(git -C "$repo" rev-parse HEAD)" BATCH o2 "$gen" >/dev/null

# The driver refuses before acquiring execution ownership (a driver- reason on a
# planned lease). Before the fix this deleted the lease record outright.
singular_lifecycle_finish TASK-1117 o2 "$gen" BATCH "driver-refused" "inspect" \
  || fail "finish refused the driver-refusal release"
[[ -f "$lease" ]] || fail "lease record was deleted together with its attempt history"
python3 - "$lease" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["attemptHistory"][0]["runId"] == "RUN-OLD", "history lost"
assert d["operatorReentries"], "re-entry record lost"
assert not d.get("reservationOwner"), d.get("reservationOwner")
PY
pass "a refused driver releases the reservation and keeps the lease history"

# A truly disposable reservation (no history at all) is still deleted.
lease2="$(singular_lease_path TASK-1118)"
gen2="$(singular_lifecycle_reserve TASK-1118 o3 ORIGIN-X b brain '["app.txt"]' \
  "$(git -C "$repo" rev-parse HEAD)" BATCH "$repo/.worktrees/TASK-1118")" || fail "fresh reserve failed"
singular_lifecycle_dispatch_record_write TASK-1118 ORIGIN-X "$$" 0 "$tmp/d2.log" \
  "$(git -C "$repo" rev-parse HEAD)" BATCH o3 "$gen2" >/dev/null
singular_lifecycle_finish TASK-1118 o3 "$gen2" BATCH "driver-refused" "inspect" || fail "finish failed"
[[ ! -f "$lease2" ]] || fail "history-free planned reservation should still be disposable"
pass "a history-free planned reservation is still disposed of"
echo "test-operator-reentry: ok"
