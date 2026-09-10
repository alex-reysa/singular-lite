#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "dispatch-wrap.sh requires bash >= 4" >&2; exit 1
fi

# Spawn wrapper for L1 dispatch (used in both batch and detached modes): runs
# the driver, then persists its exit code as a dispatch exit file so the reaper
# can attribute the outcome out-of-process. If the driver died before reaching
# its own lease lifecycle (e.g. a preflight failure while a reconcile pre-lease
# is still 'planned'), the lease is backstopped to 'failed' so it stops
# consuming a concurrency slot. usage:
# dispatch-wrap.sh <task_id> <driver> <reservation_owner> <generation> <batch>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lifecycle.sh"

task_id="$1"
driver="$2"
reservation_owner="${3:-}"
reservation_generation="${4:-}"
reservation_batch="${5:-}"

if [[ -z "$reservation_owner" || ! "$reservation_generation" =~ ^[1-9][0-9]*$ ]]; then
  echo "dispatch-wrap: owner and generation are required; refusing unattributed launch" >&2
  exit 2
fi

rc=0
SINGULAR_RESERVATION_OWNER="$reservation_owner" \
SINGULAR_RESERVATION_GENERATION="$reservation_generation" \
  "$driver" "$task_id" || rc=$?

if [[ "$rc" -eq 0 ]]; then
  finish_reason="driver-returned-with-active-lease"
  finish_next="inspect publication state, then retry only if no accepted candidate exists"
else
  finish_reason="driver-exit-$rc"
  finish_next="classify the bounded failure before retrying"
fi
singular_lifecycle_finish "$task_id" "$reservation_owner" "$reservation_generation" \
  "$reservation_batch" "$finish_reason" "$finish_next" 2>/dev/null || true
singular_lifecycle_exit_write "$task_id" "$rc" "$reservation_owner" \
  "$reservation_generation" 2>/dev/null || true

# Detached workers finish outside reconcile's process tree. Without a wakeup,
# the newly free slot is invisible until autonomate's next polling interval,
# adding a full sleep between implementation, import, and refill. Touching the
# cooperative WAKE sentinel is idempotent across concurrent completions and does
# not kill or signal the scheduler. Batch mode is already waiting in-process and
# deliberately avoids leaving a redundant wake behind.
if [[ "${SINGULAR_DETACHED_DISPATCH:-0}" == "1" ]]; then
  wake_file="$(singular_wake_file)"
  mkdir -p "$(dirname "$wake_file")"
  : >"$wake_file"
  singular_append_event "origin.capacity_released" \
    "detached worker completed; scheduler wake requested" \
    "{\"taskId\":\"$task_id\",\"exitCode\":$rc}" 2>/dev/null || true
fi
exit "$rc"
