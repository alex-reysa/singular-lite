#!/usr/bin/env bash
set -euo pipefail

# Operator verbs (0.5.0). The field run's every recovery was raw file surgery
# — hand-editing task files, leases, decisions.md, dispatch records, deleting
# planner-backoff.json, killing sleep children — repeated ~15 times. These
# verbs make each of those a single audited command.
#
#   ops.sh supersede TASK-XXXX [--by TASK-YYYY] [--reason TEXT] [--force]
#   ops.sh unpark TASK-XXXX [--reason TEXT]
#   ops.sh clear-backoff
#   ops.sh breaker [show|reset]
#   ops.sh stop [--wait[=SECS]]
#   ops.sh resume
#   ops.sh wake
#   ops.sh gates [--json]
#   ops.sh health [--json]
#   ops.sh gc [--dry-run]
#   ops.sh plan archive [--name NAME] [--force] [--no-commit]
#   ops.sh plan list [--json]
#   ops.sh ask "<question>" [--wait]
#   ops.sh report

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "ops.sh requires bash >= 4" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

verb="${1:-}"
shift || true

# --- unpark -------------------------------------------------------------------
# Return a parked task to the dispatch frontier: task Status, lease status and
# retryCount, the refusals counter, a decision record and an event.
#
# Until this existed a transient environment fault killed a task permanently.
# `escalate-parked` writes Status: blocked and a blocked lease; dispatch selects
# only Status: ready; recover.sh filters to running|planned|needs-review before
# it could ever help. The single supported operator action was `supersede`,
# which MOVES the file to tasks/superseded/ — burial, not repair. The engine
# could park a task for a missing dependency and offered no way to say the
# dependency is there now.
#
# Resetting the durable product-pass marker and retryCount is the part that is
# easy to miss. Without both, the driver treats the task as a continuation and
# can park before the operator-authorized fresh pass. The refusals counter is
# likewise only cleared on a successful dispatch.
ops_unpark() {
  local task_id="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      TASK-*) task_id="$1"; shift ;;
      *) echo "usage: singular unpark TASK-XXXX [--reason TEXT]" >&2; return 2 ;;
    esac
  done
  [[ -n "$task_id" ]] || { echo "usage: singular unpark TASK-XXXX [--reason TEXT]" >&2; return 2; }

  local task_file="$SINGULAR_TASKS_DIR/$task_id.md"
  if [[ ! -f "$task_file" ]]; then
    if [[ -f "$SINGULAR_TASKS_DIR/superseded/$task_id.md" ]]; then
      echo "unpark: $task_id is superseded, not parked; move it back by hand if that was wrong" >&2
      return 2
    fi
    echo "unpark: no task file $task_file" >&2
    return 2
  fi
  local current lease_file lease_status lease_retry lease_started
  current="$(singular_task_status "$task_file" 2>/dev/null || true)"
  lease_file="$(singular_lease_path "$task_id")"
  lease_status=""
  if [[ -f "$lease_file" ]]; then
    lease_status="$(singular_lease_status "$task_id" 2>/dev/null || true)"
  fi
  if [[ "$current" == "ready" ]]; then
    # A previous partial unpark could leave the task ready while its failed or
    # exhausted lease still carries a started pass.  Reconcile that durable
    # budget instead of reporting a false idempotent success.  Never rewrite a
    # live/accepted lease merely because the task surface is inconsistent.
    case "$lease_status" in
      planned|running|needs-review)
        echo "unpark: $task_id is already ready with active lease '$lease_status' (idempotent no-op)"
        return 0 ;;
      accepted|integrated|cancelled|superseded)
        echo "unpark: $task_id is ready but lease is '$lease_status'; refusing to reset terminal work" >&2
        return 2 ;;
    esac
    if [[ -f "$lease_file" ]]; then
      lease_retry="$(singular_lease_field "$task_id" retryCount 2>/dev/null || true)"
      lease_started="$(singular_lease_field "$task_id" productPassStarted 2>/dev/null || true)"
      if [[ "$lease_status" != "ready" || "$lease_retry" != "0" \
          || "$lease_started" == "True" || "$lease_started" == "true" ]]; then
        if ! singular_lease_unpark "$task_id" 2>/dev/null; then
          echo "unpark: lease budget reconciliation FAILED; refusing false success" >&2
          return 2
        fi
        rm -f "$SINGULAR_DISPATCH_DIR/$task_id.refusals" 2>/dev/null || true
        singular_append_event "task.unpark_reconciled" \
          "ready task had stale lease budget reconciled" \
          "{\"taskId\":\"$task_id\",\"previousLeaseStatus\":\"$lease_status\"}"
        echo "unpark: $task_id is already ready; stale lease budget reconciled"
        return 0
      fi
    fi
    echo "unpark: $task_id is already ready (idempotent no-op)"
    return 0
  fi
  case "$current" in
    blocked|failed|"") ;;
    *)
      echo "unpark: $task_id is '$current', not parked; refusing to override a live status" >&2
      return 2 ;;
  esac

  local run_id
  run_id="$(singular_run_id)"
  singular_acquire_lock "$run_id" || { echo "unpark: origin lock busy" >&2; return 2; }
  # shellcheck disable=SC2064
  trap "singular_release_lock '$run_id' 2>/dev/null || true" EXIT

  local rationale="${reason:-unparked via singular unpark}"
  # Surface 1 — decisions (durable intent first, as in supersede).
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision unpark \
    --rationale "$rationale" --run "$run_id" --authority operator 2>/dev/null \
    && echo "unpark: decision recorded" || echo "unpark: decision record FAILED (continuing)" >&2
  # Surface 2 — lease: reset the durable budget before exposing the task as
  # ready.  An existing lease that cannot be rewritten is an error, not "no
  # lease (ok)"; otherwise unpark can appear successful while re-entry remains
  # exhausted.
  if [[ -f "$lease_file" ]]; then
    case "$lease_status" in
      planned|running|needs-review|accepted|integrated)
        echo "unpark: refusing to override lease status '$lease_status'" >&2
        return 2 ;;
    esac
    if singular_lease_unpark "$task_id" 2>/dev/null; then
      echo "unpark: lease -> ready, product-pass budget reset"
    else
      echo "unpark: lease budget reset FAILED; task remains $current" >&2
      return 2
    fi
  else
    echo "unpark: no lease (ok)"
  fi
  # Surface 3 — task file.  Lease-first ordering is fail-safe: if this write
  # fails, the task remains non-ready and a repeated unpark can finish safely.
  singular_task_set_status "$task_file" "ready" \
    && echo "unpark: task -> ready" \
    || { echo "unpark: task status update FAILED" >&2; return 2; }
  # Surface 4 — refusals counter.
  if [[ -f "$SINGULAR_DISPATCH_DIR/$task_id.refusals" ]]; then
    rm -f "$SINGULAR_DISPATCH_DIR/$task_id.refusals"
    echo "unpark: refusals counter cleared"
  fi
  singular_append_event "task.unparked" "task returned to the frontier via operator verb" \
    "{\"taskId\":\"$task_id\",\"previousStatus\":\"$current\"}"
  echo "unparked $task_id"
}

# --- recover-candidate ---------------------------------------------------------
# Mint recovery authority only from the locked host operations surface. The
# lifecycle helper validates every predecessor binding again before changing
# dispatch/integration eligibility; the decision log is an audit trail, never
# authority by itself.
ops_recover_candidate() {
  local task_id="" action="" successor_run="" successor_branch=""
  local successor_worktree="" failure_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      TASK-*) task_id="$1"; shift ;;
      --action) action="${2:-}"; shift 2 ;;
      --successor-run) successor_run="${2:-}"; shift 2 ;;
      --successor-branch) successor_branch="${2:-}"; shift 2 ;;
      --successor-worktree) successor_worktree="${2:-}"; shift 2 ;;
      --failure-id) failure_id="${2:-}"; shift 2 ;;
      *) echo "usage: singular recover-candidate TASK-XXXX --action repair|regate --successor-run RUN --successor-branch BRANCH --successor-worktree PATH [--failure-id ID]" >&2; return 2 ;;
    esac
  done
  [[ -n "$task_id" && ( "$action" == repair || "$action" == regate ) \
      && -n "$successor_run" && -n "$successor_branch" && -n "$successor_worktree" ]] || {
    echo "recover-candidate: complete task/action/successor identity is required" >&2
    return 2
  }
  local lease task_file campaign run_id authority_dir authority_file authorization_id
  lease="$(singular_lease_path "$task_id")"
  task_file="$SINGULAR_TASKS_DIR/$task_id.md"
  [[ -f "$lease" && -f "$task_file" ]] || {
    echo "recover-candidate: retained lease and trusted task contract are required" >&2
    return 2
  }
  singular_campaign_verify_or_refuse ops recover-candidate || return 2
  campaign="$(singular_campaign_binding)" || return 2
  run_id="$(singular_run_id)"
  singular_acquire_lock "$run_id" || { echo "recover-candidate: origin lock busy" >&2; return 2; }
  trap "singular_release_lock '$run_id' 2>/dev/null || true" EXIT
  authority_dir="$SINGULAR_STATE_DIR/recovery-authority/$task_id"
  mkdir -p "$authority_dir"
  authority_file="$authority_dir/$successor_run.json"
  if [[ -e "$authority_file" ]]; then
    echo "recover-candidate: successor authority already exists" >&2
    return 2
  fi
  if ! python3 - "$lease" "$authority_file" "$task_id" "$action" "$successor_run" \
      "$successor_branch" "$successor_worktree" "$failure_id" "$campaign" <<'PY'
import hashlib, json, os, sys
(lease_path, output, task_id, action, successor_run, successor_branch,
 successor_worktree, failure_id, campaign) = sys.argv[1:10]
lease = json.load(open(lease_path, encoding="utf-8"))
candidate = lease.get("acceptedCandidate")
if not isinstance(candidate, dict):
    raise SystemExit("recover-candidate: no retained candidate")
failures = [item for item in candidate.get("failures", []) if isinstance(item, dict)]
def durable_id(item):
    explicit = str(item.get("failureId", "") or "")
    if explicit:
        return explicit
    key = str(item.get("key", "") or "")
    return hashlib.sha256(("legacy:" + key).encode()).hexdigest() if key else ""
if not failure_id and failures:
    failure_id = durable_id(failures[-1])
if not failure_id or not any(durable_id(item) == failure_id for item in failures):
    raise SystemExit("recover-candidate: failure identity is not eligible")
record = {
    "schema": "singular.orchestration.recovery-authority.v0",
    "taskId": task_id,
    "predecessorRunId": candidate.get("runId", ""),
    "predecessorHeadSha": candidate.get("headSha", ""),
    "predecessorTreeSha": candidate.get("treeSha", ""),
    "campaignBinding": campaign,
    "policyIdentity": campaign,
    "failureId": failure_id,
    "action": action,
    "successorRunId": successor_run,
    "successorBranch": successor_branch,
    "successorWorktree": successor_worktree,
    "authorizedBy": "origin-ops",
}
temporary = output + ".tmp"
with open(temporary, "x", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, output)
PY
  then
    rm -f "$authority_file" 2>/dev/null || true
    return 2
  fi
  if ! authorization_id="$(python3 "$SCRIPT_DIR/task_lifecycle.py" authorize-recovery \
    --lease "$lease" --authority "$authority_file" --task-contract "$task_file" \
    --expected-task "$task_id" --expected-campaign "$campaign" \
    --expected-policy "$campaign")"; then
    rm -f "$authority_file" 2>/dev/null || true
    return 2
  fi
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "authorize-$action" \
    --rationale "recovery authorization $authorization_id for $failure_id -> $successor_run" \
    --run "$run_id" --branch "$successor_branch" --authority origin >/dev/null || true
  singular_append_event "candidate.recovery_authorized" \
    "host authorized bounded candidate recovery" \
    "{\"taskId\":\"$task_id\",\"action\":\"$action\",\"authorizationId\":\"$authorization_id\",\"successorRunId\":\"$successor_run\",\"campaignBinding\":\"$campaign\"}" || true
  echo "authorizationId=$authorization_id"
  if [[ "$action" == regate ]]; then
    echo "nextAction=SINGULAR_RECOVERY_AUTHORIZATION_ID=$authorization_id singular integrate --task $task_id --run-id $successor_run"
  else
    echo "nextAction=dispatch the distinct repair attempt $successor_run in $successor_worktree"
  fi
}

# --- supersede ----------------------------------------------------------------
# The "four resurrection surfaces" atomically: decisions.md entry, task file
# (Superseded by: header + Status + move to tasks/superseded/), lease status,
# dispatch record finalize + inbox quarantine. Idempotent; refuses a live
# dispatch without --force.
ops_supersede() {
  local task_id="" by="" reason="" force="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by) by="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      --force) force="yes"; shift ;;
      TASK-*) task_id="$1"; shift ;;
      *) echo "usage: singular supersede TASK-XXXX [--by TASK-YYYY] [--reason TEXT] [--force]" >&2; return 2 ;;
    esac
  done
  [[ -n "$task_id" ]] || { echo "usage: singular supersede TASK-XXXX [--by TASK-YYYY] [--reason TEXT] [--force]" >&2; return 2; }

  local superseded_dir="$SINGULAR_TASKS_DIR/superseded"
  if [[ -f "$superseded_dir/$task_id.md" ]]; then
    echo "supersede: $task_id already superseded (idempotent no-op)"
    return 0
  fi
  local task_file="$SINGULAR_TASKS_DIR/$task_id.md"
  [[ -f "$task_file" ]] || { echo "supersede: no task file $task_file" >&2; return 2; }
  if [[ -n "$by" ]]; then
    [[ -f "$SINGULAR_TASKS_DIR/$by.md" || -f "$superseded_dir/$by.md" ]] \
      || { echo "supersede: successor $by not found" >&2; return 2; }
    [[ "$by" != "$task_id" ]] || { echo "supersede: task cannot supersede itself" >&2; return 2; }
  fi

  # Live-dispatch guard.
  local drec dpid dstart dpgid drun
  drec="$(singular_dispatch_record_path "$task_id")"
  if [[ -f "$drec" && "$(singular_json_field "$drec" state 2>/dev/null || true)" == "launched" ]]; then
    dpid="$(singular_json_field "$drec" pid 2>/dev/null || true)"
    dstart="$(singular_json_field "$drec" pidStart 2>/dev/null || true)"
    dpgid="$(singular_json_field "$drec" pgid 2>/dev/null || true)"
    drun="$(singular_json_field "$drec" runId 2>/dev/null || true)"
    if singular_dispatch_tree_alive "$task_id" "$dpid" "$dstart" "$drun" "${dpgid:-0}"; then
      if [[ "$force" != "yes" ]]; then
        echo "supersede: $task_id has a LIVE dispatch (pid $dpid); rerun with --force to terminate it" >&2
        return 2
      fi
      echo "supersede: --force terminating live dispatch tree (pid $dpid)"
      singular_kill_dispatch_pgroup "$task_id" || singular_kill_tree "$dpid" || true
      sleep 1
    fi
  fi

  local run_id
  run_id="$(singular_run_id)"
  singular_acquire_lock "$run_id" || { echo "supersede: origin lock busy" >&2; return 2; }
  # shellcheck disable=SC2064
  trap "singular_release_lock '$run_id' 2>/dev/null || true" EXIT

  local rationale="${reason:-superseded${by:+ by $by} via singular supersede}"
  # Surface 1 — decisions (durable intent first).
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision supersede \
    --rationale "$rationale" --run "$run_id" --authority operator 2>/dev/null \
    && echo "supersede: decision recorded" || echo "supersede: decision record FAILED (continuing)" >&2
  # Surface 2 — task file.
  if [[ -n "$by" ]] && ! grep -q '^Superseded by:' "$task_file"; then
    python3 - "$task_file" "$by" <<'PY'
import sys
path, by = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)
out, done = [], False
for line in lines:
    out.append(line)
    if not done and line.startswith("Status:"):
        out.append(f"Superseded by: {by}\n")
        done = True
open(path, "w").writelines(out)
PY
  fi
  singular_task_set_status "$task_file" "superseded" || true
  mkdir -p "$superseded_dir"
  mv "$task_file" "$superseded_dir/$task_id.md" \
    && echo "supersede: task file -> tasks/superseded/$task_id.md" \
    || echo "supersede: task file move FAILED" >&2
  # Surface 3 — lease.
  if singular_lease_set_status "$task_id" "superseded" 2>/dev/null; then
    echo "supersede: lease -> superseded"
  else
    echo "supersede: no lease (ok)"
  fi
  # Surface 4 — dispatch record + queued inbox packet.
  if [[ -f "$drec" && "$(singular_json_field "$drec" state 2>/dev/null || true)" == "launched" ]]; then
    singular_dispatch_record_finalize "$task_id" 0 "superseded" || true
    echo "supersede: dispatch record finalized"
  fi
  local pkt pkt_task
  mkdir -p "$SINGULAR_INBOX_DIR/superseded" 2>/dev/null || true
  for pkt in "$SINGULAR_INBOX_DIR"/*.json; do
    [[ -f "$pkt" ]] || continue
    pkt_task="$(singular_json_field "$pkt" taskId 2>/dev/null || true)"
    if [[ "$pkt_task" == "$task_id" ]]; then
      mv "$pkt" "$SINGULAR_INBOX_DIR/superseded/$(basename "$pkt")"
      echo "supersede: quarantined inbox packet $(basename "$pkt")"
    fi
  done
  singular_append_event "task.superseded" "task superseded via operator verb" \
    "{\"taskId\":\"$task_id\",\"by\":\"$by\",\"forced\":\"$force\"}"
  echo "superseded $task_id${by:+ -> $by}"
}

# --- breaker / stop / resume / wake -------------------------------------------
ops_breaker() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      local n
      n="$(singular_breaker_count)"
      echo "breaker: $n/${SINGULAR_MAX_CONSEC_FAILS} ($([[ "$n" -ge "$SINGULAR_MAX_CONSEC_FAILS" ]] && echo OPEN || echo closed))"
      [[ -f "$SINGULAR_BREAKER_FILE" ]] && cat "$SINGULAR_BREAKER_FILE"
      ;;
    reset)
      local prev
      prev="$(singular_breaker_count)"
      singular_breaker_reset
      singular_append_event "breaker.reset" "circuit breaker reset by operator" "{\"previous\":$prev}"
      echo "breaker reset (was $prev/$SINGULAR_MAX_CONSEC_FAILS)"
      ;;
    *) echo "usage: singular breaker [show|reset]" >&2; return 2 ;;
  esac
}

ops_stop() {
  local wait_secs=""
  case "${1:-}" in
    --wait) wait_secs=300 ;;
    --wait=*) wait_secs="${1#--wait=}" ;;
    "") : ;;
    *) echo "usage: singular stop [--wait[=SECS]]" >&2; return 2 ;;
  esac
  singular_ensure_state_dirs
  : >"$SINGULAR_STOP_FILE"
  singular_append_event "operator.stop_requested" "STOP sentinel written by operator" "{}"
  echo "STOP written ($SINGULAR_STOP_FILE)"
  [[ -n "$wait_secs" ]] || return 0
  [[ "$wait_secs" =~ ^[0-9]+$ ]] || wait_secs=300
  local pidfile="$SINGULAR_STATE_DIR/autonomate.pid" pid waited=0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo "autonomate not running"
    return 0
  fi
  echo "waiting up to ${wait_secs}s for autonomate (pid $pid) to exit..."
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if (( waited >= wait_secs )); then
      echo "autonomate (pid $pid) still running after ${wait_secs}s; kill $pid to force" >&2
      return 1
    fi
  done
  echo "autonomate exited"
}

ops_resume() {
  if [[ -f "$SINGULAR_STOP_FILE" ]]; then
    rm -f "$SINGULAR_STOP_FILE"
    singular_append_event "operator.resume_requested" "STOP sentinel removed by operator" "{}"
    echo "STOP removed"
  else
    echo "no STOP sentinel present"
  fi
  local pid
  pid="$(cat "$SINGULAR_STATE_DIR/autonomate.pid" 2>/dev/null || true)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo "hint: autonomate is not running — start it with: singular auto --detach"
  fi
}

ops_wake() {
  # One-shot "make the loop runnable": clear backoff, reset breaker, drop STOP,
  # then signal any live nap to end. Each step reports individually.
  local keep_stop="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-stop) keep_stop="yes"; shift ;;
      *) echo "usage: singular wake [--keep-stop]" >&2; return 2 ;;
    esac
  done
  singular_planner_backoff_clear
  ops_breaker reset
  if [[ -f "$SINGULAR_STOP_FILE" ]]; then
    if [[ "$keep_stop" == "yes" ]]; then
      echo "STOP kept (--keep-stop); the loop stays halted"
    else
      # Dropping STOP is the part of `wake` that surprises people. The habitual
      # `breaker reset; wake; auto` sequence used to be one second away from two
      # concurrent loops: wake removes the sentinel a still-exiting loop has not
      # noticed yet, and `auto` then started a second one. `auto`'s pidfile is
      # atomic now, so the second one refuses — but say plainly what happened,
      # because a silent un-stop is how the sequence got habitual.
      rm -f "$SINGULAR_STOP_FILE"
      echo "STOP removed — the loop is no longer halted (use --keep-stop to only end the nap)"
      if [[ -f "$SINGULAR_STATE_DIR/autonomate.pid" ]]; then
        local live_pid
        live_pid="$(head -1 "$SINGULAR_STATE_DIR/autonomate.pid" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$live_pid" ]] && singular_pid_alive "$live_pid"; then
          echo "note: autonomate (pid $live_pid) is still running and will resume; do NOT start another"
        fi
      fi
    fi
  else
    echo "no STOP sentinel present"
  fi
  singular_request_wake
  singular_append_event "operator.wake" "wake verb completed" \
    "{\"keptStop\":\"$keep_stop\"}"
}

# --- gates ----------------------------------------------------------------------
ops_gates() {
  local json="no"
  [[ "${1:-}" == "--json" ]] && json="yes"
  python3 - "${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}" "$SINGULAR_ORCH_DIR/gates" "$json" <<'PY'
import json
import os
import sys

dag_file, gates_dir, as_json = sys.argv[1:4]
nodes = []
try:
    dag = json.load(open(dag_file))
    nodes = [(n.get("id", ""), n.get("kind", "")) for n in dag.get("nodes", [])]
except Exception:
    pass

rows, passed = [], 0
for node_id, kind in nodes:
    path = os.path.join(gates_dir, f"{node_id}.gate-result.json")
    if not os.path.isfile(path):
        rows.append({"node": node_id, "kind": kind, "status": "(no gate)", "authoritative": "",
                     "evidenceClass": "", "decidedBy": "", "recordedAt": "", "file": ""})
        continue
    try:
        g = json.load(open(path))
        status = str(g.get("status", "?"))
        if status in ("passed", "passed-with-acknowledged-baseline"):
            passed += 1
        rows.append({"node": node_id, "kind": kind, "status": status,
                     "authoritative": g.get("authoritative", ""),
                     "evidenceClass": g.get("evidenceClass", ""),
                     "decidedBy": g.get("decidedBy", ""),
                     "recordedAt": g.get("recordedAt", ""), "file": path})
    except Exception as exc:
        # A malformed gate is DISPLAYED, never fatal — operators need to see it.
        rows.append({"node": node_id, "kind": kind, "status": f"invalid ({exc})",
                     "authoritative": "", "evidenceClass": "", "decidedBy": "",
                     "recordedAt": "", "file": path})

if as_json == "yes":
    print(json.dumps({"gates": rows, "passed": passed, "total": len(nodes)}, indent=2))
else:
    widths = [max(len(str(r["node"])) for r in rows or [{"node": "NODE"}]) + 2, 12, 12]
    print(f"{'NODE':<{widths[0]}}{'KIND':<{widths[1]}}{'STATUS':<14}{'AUTH':<6}{'EVIDENCECLASS':<22}RECORDEDAT")
    for r in rows:
        print(f"{r['node']:<{widths[0]}}{r['kind']:<{widths[1]}}{str(r['status']):<14}"
              f"{str(r['authoritative']):<6}{str(r['evidenceClass']):<22}{r['recordedAt']}")
    print(f"passed {passed}/{len(nodes)}")
PY
}

# A failed `kill -0` is not synonymous with a dead process: POSIX permits an
# EPERM result when the process exists but the caller may not signal it. Keep
# that distinction at the operator surface so an inconclusive probe cannot
# encourage a second autonomate loop.
ops_pid_probe_state() {
  local pid="${1:-}"
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "dead"
    return 0
  fi

  # Permission failures are difficult to reproduce portably in a test process
  # owned by the current user. This validated, test-namespaced seam exercises
  # the same downstream contract without changing the production probe. Both
  # variables are required so a stray inherited state value cannot alter an
  # ordinary operator health check.
  if [[ "${SINGULAR_TEST_PID_PROBE:-0}" == "1" ]]; then
    case "${SINGULAR_TEST_PID_PROBE_STATE:-}" in
      alive|dead|unknown)
        printf '%s\n' "$SINGULAR_TEST_PID_PROBE_STATE"
        return 0
        ;;
    esac
  fi

  python3 - "$pid" <<'PY'
import errno
import os
import sys

pid = int(sys.argv[1])
try:
    os.kill(pid, 0)
except ProcessLookupError:
    print("dead")
except PermissionError:
    print("unknown")
except (OverflowError, ValueError):
    # A syntactically numeric pid that cannot fit the platform pid_t is a
    # stale/invalid pidfile value, not an inconclusive live-process probe.
    print("dead")
except OSError as exc:
    if exc.errno == errno.ESRCH:
        print("dead")
    elif exc.errno in (errno.EPERM, errno.EACCES):
        print("unknown")
    else:
        print("unknown")
else:
    print("alive")
PY
}

# --- health ----------------------------------------------------------------------
ops_health() {
  local json="no"
  [[ "${1:-}" == "--json" ]] && json="yes"
  local gates_json frontier_json ready_count active_count l1_active l1_stale
  gates_json="$(ops_gates --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps({"passed":d["passed"],"total":d["total"]}))' 2>/dev/null || echo '{"passed":null,"total":null}')"
  # "null" here used to mean two different things -- no ready work, and a DAG
  # that could not be evaluated at all -- and health printed the same line for
  # both. singular_dag_next_areas_json separates them: a non-zero exit is an
  # evaluation failure, which health must name.
  local frontier_raw frontier_rc=0
  frontier_raw="$(singular_dag_next_areas_json)" || frontier_rc=$?
  if [[ "$frontier_rc" -ne 0 ]]; then
    frontier_json="unavailable"
  else
    frontier_json="$(printf '%s' "$frontier_raw" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d.get("frontier",[])))
except Exception:
    print("null")' || echo null)"
  fi
  ready_count="$(singular_list_ready_tasks 2>/dev/null | grep -c . || true)"
  active_count="$(singular_active_lease_count 2>/dev/null || echo 0)"
  l1_active="$(singular_l1_list_active 2>/dev/null | grep -c . || true)"
  l1_stale="$(singular_l1_list_stale 2>/dev/null | grep -c . || true)"
  local backoff_json breaker_n stop_present lock_present auto_pid auto_state
  backoff_json="$(singular_planner_backoff_active_json 2>/dev/null || echo null)"
  breaker_n="$(singular_breaker_count)"
  stop_present="$([[ -f "$SINGULAR_STOP_FILE" ]] && echo true || echo false)"
  lock_present="$([[ -f "$SINGULAR_LOCK_FILE" ]] && echo true || echo false)"
  auto_pid="$(cat "$SINGULAR_STATE_DIR/autonomate.pid" 2>/dev/null || true)"
  auto_state="$(ops_pid_probe_state "$auto_pid" 2>/dev/null || echo unknown)"
  case "$auto_state" in
    alive|dead|unknown) ;;
    *) auto_state="unknown" ;;
  esac
  local disk_free wt_count console_url lifecycle_json resource_json health_details_json
  local effective_configuration_json
  disk_free="$(singular_free_disk_gb 2>/dev/null || echo null)"
  wt_count="$(find "$SINGULAR_WORKTREES_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -c . || true)"
  console_url="$(head -1 "$SINGULAR_STATE_DIR/console.url" 2>/dev/null || true)"
  lifecycle_json="$(python3 - "$SINGULAR_RUNS_DIR" "$SINGULAR_LEASES_DIR" "$SINGULAR_TASKS_DIR" <<'PY'
import collections
import json
import pathlib
import re
import sys

runs = pathlib.Path(sys.argv[1])
leases = pathlib.Path(sys.argv[2])
tasks = pathlib.Path(sys.argv[3])
records = []
if runs.is_dir():
    for path in runs.glob("*/run-status.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if data.get("schema") != "singular.orchestration.run-status.v0":
            continue
        records.append(data)
records.sort(key=lambda item: str(item.get("updatedAt") or ""), reverse=True)
active = [item for item in records if item.get("state") in ("active", "waiting")]
counts = collections.Counter(str(item.get("phase") or "unknown") for item in active)
candidates = []
if leases.is_dir():
    for path in sorted(leases.glob("*.json")):
        try:
            lease = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        candidate = lease.get("acceptedCandidate")
        history = lease.get("candidateHistory") or []
        recovery = lease.get("recoveryAuthorization")
        retained = candidate if isinstance(candidate, dict) else (history[-1] if history else None)
        if not isinstance(retained, dict):
            continue
        failures = [item for item in retained.get("failures", []) if isinstance(item, dict)]
        latest = failures[-1] if failures else {}
        task_id = str(lease.get("taskId") or path.stem)
        dependencies = []
        task_path = tasks / (task_id + ".md")
        try:
            match = re.search(r"^Depends on:\s*\[(.*?)\]", task_path.read_text(encoding="utf-8"), re.M)
            if match:
                declared = re.findall(r"TASK-[0-9]+", match.group(1))
                for dependency in declared:
                    dependency_status = ""
                    dependency_task = tasks / (dependency + ".md")
                    try:
                        status_match = re.search(
                            r"^Status:\s*([A-Za-z0-9_-]+)",
                            dependency_task.read_text(encoding="utf-8"), re.M,
                        )
                        dependency_status = status_match.group(1).lower() if status_match else ""
                    except OSError:
                        pass
                    dependency_lease = leases / (dependency + ".json")
                    try:
                        lease_status = json.loads(
                            dependency_lease.read_text(encoding="utf-8")
                        ).get("status")
                        if lease_status:
                            dependency_status = str(lease_status).lower()
                    except (OSError, json.JSONDecodeError):
                        pass
                    if dependency_status != "integrated":
                        dependencies.append(dependency)
        except OSError:
            pass
        candidates.append({
            "taskId": task_id,
            "candidateRunId": retained.get("runId"),
            "candidateHeadSha": retained.get("headSha"),
            "candidateTreeSha": retained.get("treeSha"),
            "state": retained.get("state"),
            "blockedDependencies": dependencies,
            "blockedReason": latest.get("failureClass") or (retained.get("recoveryBlock") or {}).get("reason"),
            "failureDomain": latest.get("domain"),
            "failureId": latest.get("failureId"),
            "owner": (recovery or {}).get("authorizedBy") or lease.get("owner") or "origin",
            "permittedNextAction": lease.get("nextAction") or retained.get("nextAction"),
            "recoveryAction": (recovery or {}).get("action"),
            "recoveryState": (recovery or {}).get("state"),
            "failureBudgets": lease.get("failureBudgets", {"product": 0, "infrastructure": 0, "regate": 0}),
        })
print(json.dumps({
    "active": active[:50],
    "activeCount": len(active),
    "phaseCounts": dict(sorted(counts.items())),
    "implementersActive": counts.get("implementing", 0),
    "candidates": candidates,
}, separators=(",", ":")))
PY
)"
  resource_json="$("$SCRIPT_DIR/resource-plan.sh" --json 2>/dev/null || echo null)"
  health_details_json="$(python3 "$SCRIPT_DIR/health_details.py" \
    --repo "$SINGULAR_ROOT" \
    --dag "${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}" \
    --events "$SINGULAR_EVENTS_FILE" 2>/dev/null \
    || echo '{"diagnostics":{"total":0,"groups":0,"counts":{},"items":[]},"humanGates":{"total":0,"approved":0,"blocking":0,"states":{},"blockedNodes":[],"items":[],"errors":["health detail collection failed"]}}')"
  effective_configuration_json="$(python3 "$SCRIPT_DIR/provider_resolver.py" \
    effective-config --repo "$SINGULAR_ROOT" 2>/dev/null || echo '{}')"
  local head_sha
  head_sha="$(git -C "$SINGULAR_ROOT" rev-parse --short HEAD 2>/dev/null || echo null)"

  python3 - "$gates_json" "$frontier_json" "$ready_count" "$active_count" "$l1_active" "$l1_stale" \
    "$backoff_json" "$breaker_n" "${SINGULAR_MAX_CONSEC_FAILS:-5}" "$stop_present" "$lock_present" \
    "$auto_pid" "$auto_state" "$disk_free" "${SINGULAR_MIN_DISK_GB:-2}" "$wt_count" "$console_url" \
    "${SINGULAR_TARGET_BRANCH:-}" "$head_sha" "$lifecycle_json" "$resource_json" \
    "$health_details_json" "$effective_configuration_json" "$json" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone

(gates_raw, frontier, ready, active, l1a, l1s, backoff_raw, breaker, breaker_max,
 stop, lock, auto_pid, auto_state, disk, min_disk, wt, console_url,
 target, head, lifecycle_raw, resource_raw, health_details_raw,
 effective_configuration_raw, as_json) = sys.argv[1:25]


def num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None


gates = json.loads(gates_raw)
try:
    backoff = json.loads(backoff_raw) if backoff_raw != "null" else None
except Exception:
    backoff = None
try:
    lifecycle = json.loads(lifecycle_raw)
except Exception:
    lifecycle = {"active": [], "activeCount": 0, "phaseCounts": {}, "implementersActive": 0}
try:
    resources = json.loads(resource_raw) if resource_raw != "null" else None
except Exception:
    resources = None
try:
    health_details = json.loads(health_details_raw)
except Exception:
    health_details = {
        "diagnostics": {"total": 0, "groups": 0, "counts": {}, "items": []},
        "humanGates": {
            "total": 0, "approved": 0, "blocking": 0, "states": {},
            "blockedNodes": [], "items": [], "errors": ["health detail JSON invalid"],
        },
    }
try:
    effective_configuration = json.loads(effective_configuration_raw)
except Exception:
    effective_configuration = {}

attention = []
if frontier == "unavailable":
    attention.append(
        "DAG frontier could not be evaluated (run `singular next-areas` for the "
        "diagnostic); an empty frontier here does NOT mean there is no work"
    )
if stop == "true":
    attention.append("STOP sentinel present")
if backoff:
    attention.append(f"planner backoff active ({backoff.get('failureClass')}, until {backoff.get('until')})")
if num(breaker) and num(breaker) >= num(breaker_max):
    attention.append(f"circuit breaker OPEN ({breaker}/{breaker_max})")
if num(l1s):
    attention.append(f"{l1s} stale L1 lease(s) (singular recover --scan)")
if num(disk) is not None and num(min_disk) is not None and num(disk) < num(min_disk):
    attention.append(f"disk below floor ({disk}GiB < {min_disk}GiB)")
if auto_state == "dead":
    attention.append("autonomate not running")
elif auto_state == "unknown":
    attention.append(
        "autonomate liveness unknown (permission denied or inconclusive); "
        "verify process ownership before starting another loop"
    )
if resources and resources.get("effectiveSlots") == 0:
    attention.append("adaptive scheduler has zero affordable worktree slots")
pressure = resources.get("providerPressure") if isinstance(resources, dict) else None
if isinstance(pressure, dict) and pressure.get("applied"):
    attention.append(
        "provider pressure is limiting concurrency "
        f"({pressure.get('provider')} cap={pressure.get('cap')}); "
        "capacity restores after quiet successful iterations"
    )

doc = {
    "ok": not attention,
    "gates": gates,
    # `ready: null` means "counted, and the count was unreadable"; evaluable
    # false means the DAG could not be evaluated at all. Collapsing those two
    # into one line is what let an invalid DAG read as "no work to do".
    "frontier": ({"ready": None, "evaluable": False}
                 if frontier == "unavailable" else
                 {"ready": num(frontier), "evaluable": True}),
    "tasks": {"ready": num(ready)},
    "leases": {"l2Active": num(active), "l1Active": num(l1a), "l1Stale": num(l1s),
               "implementersActive": lifecycle.get("implementersActive", 0)},
    "lifecycle": lifecycle,
    "candidates": lifecycle.get("candidates", []),
    "effectiveConfiguration": effective_configuration,
    "resources": resources,
    "diagnostics": health_details.get("diagnostics", {}),
    "humanGates": health_details.get("humanGates", {}),
    "backoff": backoff,
    "breaker": {"consecFails": num(breaker), "threshold": num(breaker_max),
                "open": bool(num(breaker) and num(breaker) >= num(breaker_max))},
    "stop": stop == "true",
    "lock": lock == "true",
    "autonomate": {
        "pid": num(auto_pid),
        "state": auto_state,
        # Preserve the existing boolean for compatible consumers, but never
        # represent an inconclusive probe as false.
        "alive": (
            True if auto_state == "alive" else
            False if auto_state == "dead" else
            None
        ),
    },
    "diskFreeGb": num(disk),
    "worktrees": num(wt),
    "consoleUrl": console_url or None,
    "targetBranch": target or None,
    "head": head if head != "null" else None,
    "attention": attention,
}
# Digest over everything except generatedAt: the skill heartbeat compares
# ONLY this field to decide whether anything changed.
digest_doc = json.loads(json.dumps(doc))
# Exact free bytes fluctuate because unrelated processes write caches between
# polls. Capacity transitions matter; byte-level noise does not.
if isinstance(digest_doc.get("resources"), dict):
    digest_doc["resources"].pop("freeBytes", None)
    digest_doc["resources"].pop("affordableSlots", None)
doc["digest"] = hashlib.sha256(
    json.dumps(digest_doc, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()[:16]
doc["generatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

if as_json == "yes":
    print(json.dumps(doc, indent=2))
else:
    g = doc["gates"]
    print(f"ok:         {doc['ok']}")
    print(f"gates:      {g.get('passed')}/{g.get('total')}")
    if doc["frontier"].get("evaluable") is False:
        print("frontier:   UNEVALUABLE (see dag.evaluation_failed; this is not 'no work')")
    else:
        print(f"frontier:   {doc['frontier']['ready']} ready node(s)")
    print(f"tasks:      {doc['tasks']['ready']} ready; leases l2={doc['leases']['l2Active']} l1={doc['leases']['l1Active']} (stale {doc['leases']['l1Stale']})")
    print(f"breaker:    {doc['breaker']['consecFails']}/{doc['breaker']['threshold']}"
          + (" OPEN" if doc["breaker"]["open"] else ""))
    print(f"backoff:    {'ACTIVE ' + str((doc['backoff'] or {}).get('failureClass')) if doc['backoff'] else 'none'}")
    print(f"stop:       {doc['stop']}   lock: {doc['lock']}")
    auto = doc["autonomate"]
    alive_display = (
        str(auto["alive"]) if auto["alive"] is not None else "unknown"
    )
    print(f"autonomate: pid={auto['pid']} state={auto['state']} alive={alive_display}")
    print(f"disk:       {doc['diskFreeGb']}GiB free; worktrees: {doc['worktrees']}")
    if doc["resources"]:
        print(f"capacity:   {doc['resources']['effectiveSlots']}/{doc['resources']['configuredSlots']} slots ({doc['resources']['reason']})")
        pressure = doc["resources"].get("providerPressure")
        if isinstance(pressure, dict):
            cap_display = pressure.get("cap") if pressure.get("cap") is not None else "none"
            print(
                f"pressure:   {pressure.get('provider') or 'provider-unknown'} "
                f"cap={cap_display} applied={bool(pressure.get('applied'))} "
                f"events={pressure.get('events')} "
                f"recovery={pressure.get('quietSuccesses')}/{pressure.get('recoverQuiet')}"
            )
    if doc["lifecycle"]["phaseCounts"]:
        print(f"phases:     {doc['lifecycle']['phaseCounts']}")
    for candidate in doc["candidates"]:
        print(
            "candidate:  " + str(candidate.get("taskId"))
            + " head=" + str(candidate.get("candidateHeadSha"))
            + " blocked=" + str(candidate.get("blockedDependencies") or candidate.get("blockedReason"))
            + " domain=" + str(candidate.get("failureDomain"))
            + " owner=" + str(candidate.get("owner"))
            + " action=" + str(candidate.get("permittedNextAction"))
        )
    diagnostics = doc["diagnostics"]
    if diagnostics.get("total"):
        print(f"diagnostics:{diagnostics.get('counts', {})}")
    human = doc["humanGates"]
    if human.get("total"):
        print(f"human gates:{human.get('approved')}/{human.get('total')} approved; {human.get('blocking')} blocking")
    if doc["consoleUrl"]:
        print(f"console:    {doc['consoleUrl']}")
    for a in doc["attention"]:
        print(f"ATTENTION:  {a}")
    print(f"digest:     {doc['digest']}")
PY
}

# --- gc --------------------------------------------------------------------------
ops_gc() {
  local dry="no" inherited_run_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry="yes"; shift ;;
      --from-reconcile)
        [[ -n "${2:-}" ]] || { echo "usage: singular gc [--dry-run] [--from-reconcile RUN_ID]" >&2; return 2; }
        inherited_run_id="$2"
        shift 2
        ;;
      *) echo "usage: singular gc [--dry-run] [--from-reconcile RUN_ID]" >&2; return 2 ;;
    esac
  done
  [[ -z "$inherited_run_id" || "$dry" == "no" ]] || {
    echo "gc: --from-reconcile cannot be combined with --dry-run" >&2
    return 2
  }

  local run_id
  run_id="${inherited_run_id:-$(singular_run_id)}"
  if [[ -n "$inherited_run_id" ]]; then
    # Reconcile already owns the sole origin lock. A public flag and run id are
    # not sufficient authority; require the per-acquisition child capability.
    if ! singular_require_inherited_origin_lock "$inherited_run_id"; then
      echo "gc: reconcile lock capability did not verify" >&2
      return 2
    fi
  elif [[ "$dry" == "no" ]]; then
    singular_acquire_lock "$run_id" || { echo "gc: origin lock busy" >&2; return 2; }
    # shellcheck disable=SC2064
    trap "singular_release_lock '$run_id' 2>/dev/null || true" EXIT
  fi
  local prefix_word=""
  [[ "$dry" == "yes" ]] && prefix_word="would-"

  # 1. Runs-history cap: keep newest SINGULAR_RUNS_KEEP per prefix bucket;
  #    never delete runs referenced by live leases/dispatches/inbox packets or
  #    newer than SINGULAR_RUNS_MIN_AGE_HOURS.
  python3 - "$SINGULAR_RUNS_DIR" "$SINGULAR_LEASES_DIR" "$SINGULAR_DISPATCH_DIR" "$SINGULAR_INBOX_DIR" \
    "${SINGULAR_RUNS_KEEP:-200}" "${SINGULAR_RUNS_MIN_AGE_HOURS:-24}" "$dry" <<'PY'
import json
import os
import shutil
import sys
import time

runs_dir, leases_dir, dispatch_dir, inbox_dir, keep_raw, min_age_raw, dry = sys.argv[1:8]
keep = int(keep_raw)
min_age_s = int(min_age_raw) * 3600
now = time.time()

protected = set()
for base in (leases_dir, dispatch_dir, inbox_dir):
    if not os.path.isdir(base):
        continue
    for name in os.listdir(base):
        if not name.endswith(".json"):
            continue
        try:
            data = json.load(open(os.path.join(base, name)))
        except Exception:
            continue
        rid = data.get("runId")
        status = str(data.get("status", data.get("state", "")))
        if rid and status not in ("superseded", "cancelled"):
            protected.add(rid)

buckets = {}
if os.path.isdir(runs_dir):
    for name in os.listdir(runs_dir):
        path = os.path.join(runs_dir, name)
        if not os.path.isdir(path):
            continue
        bucket = name.split("-", 1)[0]
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        buckets.setdefault(bucket, []).append((mtime, name, path))

removed = kept = 0
for bucket, entries in buckets.items():
    entries.sort(reverse=True)
    for i, (mtime, name, path) in enumerate(entries):
        if i < keep or name in protected or (now - mtime) < min_age_s:
            kept += 1
            continue
        if dry == "no":
            shutil.rmtree(path, ignore_errors=True)
        removed += 1
prefix = "would-" if dry == "yes" else ""
print(f"gc: runs: {prefix}removed {removed} / kept {kept} (keep={keep}/bucket)")
PY

  # 2. Worktrees: prune integrated+merged+clean (same predicate as recover
  #    auto-prune), gated SINGULAR_GC_WORKTREES=1.
  local pruned=0 kept_wt=0 wt tid lease_status wt_head
  if [[ "${SINGULAR_GC_WORKTREES:-1}" == "1" && -d "$SINGULAR_WORKTREES_DIR" ]]; then
    for wt in "$SINGULAR_WORKTREES_DIR"/*; do
      [[ -d "$wt" ]] || continue
      tid="$(basename "$wt")"
      lease_status="$(singular_lease_status "$tid" 2>/dev/null || true)"
      if [[ "$lease_status" != "integrated" ]]; then
        kept_wt=$((kept_wt + 1)); continue
      fi
      wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
      if [[ -z "$wt_head" ]] \
        || ! git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$wt_head" "$SINGULAR_TARGET_BRANCH" 2>/dev/null \
        || [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        kept_wt=$((kept_wt + 1)); continue
      fi
      if [[ "$dry" == "no" ]]; then
        git -C "$SINGULAR_ROOT" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
        singular_record_recovery "gc pruned integrated worktree" "$tid" "" "prune" "operator" "" "operator" 2>/dev/null || true
      fi
      pruned=$((pruned + 1))
    done
    [[ "$dry" == "no" ]] && git -C "$SINGULAR_ROOT" worktree prune 2>/dev/null || true
  fi
  echo "gc: worktrees: ${prefix_word}pruned $pruned / kept $kept_wt"

  # 3. Events rotation.
  local max_mb="${SINGULAR_EVENTS_MAX_MB:-64}" rotate_keep="${SINGULAR_EVENTS_ROTATE_KEEP:-3}"
  if [[ -f "$SINGULAR_EVENTS_FILE" && "$max_mb" =~ ^[0-9]+$ && "$max_mb" -gt 0 ]]; then
    local size_mb
    size_mb="$(( $(wc -c <"$SINGULAR_EVENTS_FILE") / 1024 / 1024 ))"
    if (( size_mb >= max_mb )); then
      if [[ "$dry" == "no" ]]; then
        local i
        for ((i = rotate_keep - 1; i >= 1; i--)); do
          [[ -f "$SINGULAR_EVENTS_FILE.$i" ]] && mv "$SINGULAR_EVENTS_FILE.$i" "$SINGULAR_EVENTS_FILE.$((i + 1))"
        done
        mv "$SINGULAR_EVENTS_FILE" "$SINGULAR_EVENTS_FILE.1"
        : >"$SINGULAR_EVENTS_FILE"
        singular_append_event "gc.events_rotated" "events journal rotated" "{\"sizeMb\":$size_mb}"
      fi
      echo "gc: events: ${prefix_word}rotated (${size_mb}MB >= ${max_mb}MB)"
    else
      echo "gc: events: kept (${size_mb}MB < ${max_mb}MB)"
    fi
  fi

  # 4. Quarantine sweeps (>30 days).
  python3 - "$SINGULAR_LEASES_DIR/superseded" "$SINGULAR_INBOX_DIR/superseded" "$dry" <<'PY'
import os
import sys
import time

dirs = sys.argv[1:3]
dry = sys.argv[3]
now = time.time()
removed = 0
for base in dirs:
    if not os.path.isdir(base):
        continue
    for name in os.listdir(base):
        path = os.path.join(base, name)
        try:
            if now - os.path.getmtime(path) > 30 * 86400:
                if dry == "no":
                    os.remove(path)
                removed += 1
        except OSError:
            continue
prefix = "would-" if dry == "yes" else ""
print(f"gc: quarantine: {prefix}removed {removed} file(s) older than 30d")
PY

  # 5. Read-only guard journals (>30 days).
  # A journal directory holds what the guard moved aside when it put a worktree
  # back, so it is operator-recoverable data, not scratch — same retention as
  # the quarantines above. A journal whose owner process is still alive belongs
  # to a run in flight and is never touched, no matter how old the timestamp
  # looks; `reconcile` is what restores the ones whose owner is gone.
  python3 - "$SINGULAR_STATE_DIR/readonly-guard" \
    "${SINGULAR_READONLY_GUARD_KEEP_DAYS:-30}" "$dry" <<'PY'
import json
import os
import shutil
import sys
import time

base, keep_days_raw, dry = sys.argv[1:4]
try:
    keep_s = int(keep_days_raw) * 86400
except ValueError:
    keep_s = 30 * 86400
now = time.time()
removed = 0
live = 0
if os.path.isdir(base):
    for name in sorted(os.listdir(base)):
        path = os.path.join(base, name)
        if not os.path.isdir(path):
            continue
        owner = 0
        try:
            with open(os.path.join(path, "journal.json"), encoding="utf-8") as stream:
                owner = int(json.load(stream).get("ownerPid") or 0)
        except (OSError, ValueError):
            owner = 0
        if owner > 0:
            try:
                os.kill(owner, 0)
            except ProcessLookupError:
                pass
            except OSError:
                live += 1
                continue
            else:
                live += 1
                continue
        try:
            if now - os.path.getmtime(path) > keep_s:
                if dry == "no":
                    shutil.rmtree(path, ignore_errors=True)
                removed += 1
        except OSError:
            continue
prefix = "would-" if dry == "yes" else ""
days = keep_s // 86400
print(f"gc: readonly-guard: {prefix}removed {removed} journal(s) older than {days}d"
      + (f"; {live} in flight" if live else ""))
PY
  [[ "$dry" == "no" ]] && singular_append_event "gc.completed" "gc run completed" "{}"
  return 0
}

# --- plan (archive / list) -------------------------------------------------------
# "Plan threads" (0.8.0): a completed DAG is archived as a browsable mini-repo
# under .singular-state/plans/<id>/ (both docs/orchestration/ and .singular-state/
# subtrees — the console points a per-plan collector root here), then the live
# tree is reset to a starter DAG so a fresh plan can begin. Archived plans are
# read-only history; the archive root is gitignored (runs/events were never
# committed), the docs-side history stays in git and the manifest records the sha.
ops_plan() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    archive) ops_plan_archive "$@" ;;
    list)    ops_plan_list "$@" ;;
    *) echo "usage: singular plan archive|list ..." >&2; return 2 ;;
  esac
}

ops_plan_archive() {
  local name="" force="no" no_commit="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)      name="${2:-}"; shift 2 ;;
      --force)     force="yes"; shift ;;
      --no-commit) no_commit="yes"; shift ;;
      *) echo "usage: singular plan archive [--name <display name>] [--force] [--no-commit]" >&2; return 2 ;;
    esac
  done

  local gates_dir="${SINGULAR_GATES_DIR:-$SINGULAR_ORCH_DIR/gates}"
  local dag_file="${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}"

  # --- Preconditions (each refusable only via --force) ---
  # 1. Live autonomate.
  local auto_pid
  auto_pid="$(cat "$SINGULAR_STATE_DIR/autonomate.pid" 2>/dev/null || true)"
  if [[ -n "$auto_pid" ]] && kill -0 "$auto_pid" 2>/dev/null && [[ "$force" != "yes" ]]; then
    echo "plan archive: autonomate is LIVE (pid $auto_pid); stop it (singular stop --wait) or rerun with --force" >&2
    return 1
  fi
  # 2. Origin lock present.
  if [[ -f "$SINGULAR_LOCK_FILE" && "$force" != "yes" ]]; then
    echo "plan archive: origin lock present ($SINGULAR_LOCK_FILE); the loop may be active — rerun with --force" >&2
    return 1
  fi
  # 3. Live dispatch tree (a launched record whose process tree is still alive).
  if [[ "$force" != "yes" && -d "$SINGULAR_DISPATCH_DIR" ]]; then
    local drec dstate dtid dpid dstart dpgid drun
    for drec in "$SINGULAR_DISPATCH_DIR"/*.json; do
      [[ -f "$drec" ]] || continue
      dstate="$(singular_json_field "$drec" state 2>/dev/null || true)"
      [[ "$dstate" == "launched" ]] || continue
      dtid="$(singular_json_field "$drec" taskId 2>/dev/null || true)"
      dpid="$(singular_json_field "$drec" pid 2>/dev/null || true)"
      dstart="$(singular_json_field "$drec" pidStart 2>/dev/null || true)"
      dpgid="$(singular_json_field "$drec" pgid 2>/dev/null || true)"
      drun="$(singular_json_field "$drec" runId 2>/dev/null || true)"
      if singular_dispatch_tree_alive "$dtid" "$dpid" "$dstart" "$drun" "${dpgid:-0}"; then
        echo "plan archive: LIVE dispatch for $dtid (pid $dpid); rerun with --force to archive anyway" >&2
        return 1
      fi
    done
  fi
  # 4. Plan incomplete (dag frontier not fully gate-passed).
  local frontier_out all_complete
  # Fails safe either way (an unreadable frontier is not allComplete, so archive
  # refuses), but the operator should still be told WHY rather than being sent to
  # finish a DAG that cannot be parsed.
  frontier_out="$(singular_dag_next_areas_json || true)"
  all_complete="$(printf '%s' "$frontier_out" | python3 -c 'import json,sys
try:
    print("true" if json.load(sys.stdin).get("allComplete") else "false")
except Exception:
    print("false")' 2>/dev/null || echo false)"
  if [[ "$all_complete" != "true" && "$force" != "yes" ]]; then
    echo "plan archive: plan is INCOMPLETE (dag.sh next-areas allComplete != true); finish the DAG or rerun with --force" >&2
    return 1
  fi
  # 5. Worktrees present — never moved/archived, even with --force; refuse without.
  if [[ -d "$SINGULAR_WORKTREES_DIR" ]]; then
    local wt_entries
    wt_entries="$(find "$SINGULAR_WORKTREES_DIR" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
    if [[ -n "$wt_entries" && "$force" != "yes" ]]; then
      echo "plan archive: .worktrees/ is not empty (worktrees are never archived); run 'singular gc' first:" >&2
      printf '%s\n' "$wt_entries" | sed 's/^/  /' >&2
      return 1
    fi
  fi

  # --- Acquire the origin lock (trap release) ---
  local run_id
  run_id="$(singular_run_id)"
  singular_acquire_lock "$run_id" || { echo "plan archive: origin lock busy" >&2; return 1; }
  # shellcheck disable=SC2064
  trap "singular_release_lock '$run_id' 2>/dev/null || true" EXIT
  # Re-check autonomate liveness after acquiring the lock (it may have started).
  auto_pid="$(cat "$SINGULAR_STATE_DIR/autonomate.pid" 2>/dev/null || true)"
  if [[ -n "$auto_pid" ]] && kill -0 "$auto_pid" 2>/dev/null && [[ "$force" != "yes" ]]; then
    echo "plan archive: autonomate became LIVE (pid $auto_pid) after acquiring lock; aborting" >&2
    return 1
  fi

  # --- Compute plan id + display name ---
  local stamp id slug display_name
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -n "$name" ]]; then
    slug="$(printf '%s' "$name" | python3 -c 'import sys,re
s=sys.stdin.read().strip().lower()
s=re.sub(r"[^a-z0-9]+","-",s).strip("-")[:32].strip("-")
print(s)')"
    if [[ -n "$slug" ]]; then id="plan-$stamp-$slug"; else id="plan-$stamp"; fi
    display_name="$name"
  else
    id="plan-$stamp"
    display_name="$id"
  fi

  # --- Build manifest (one python heredoc over gates + tasks + events) ---
  local plans_dir="$SINGULAR_STATE_DIR/plans"
  local archive_dir="$plans_dir/$id"
  local archived_at engine_version schema_version branch head_sha
  archived_at="$(singular_timestamp)"
  engine_version="$(tr -d '[:space:]' <"$SINGULAR_ENGINE_HOME/VERSION" 2>/dev/null || true)"
  schema_version="$(tr -d '[:space:]' <"$SINGULAR_ENGINE_HOME/SCHEMA_VERSION" 2>/dev/null || true)"
  if [[ -z "$schema_version" && -f "$SINGULAR_ROOT/singular.config.json" ]]; then
    schema_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("schemaVersion","") or "")' "$SINGULAR_ROOT/singular.config.json" 2>/dev/null || true)"
  fi
  branch="$(git -C "$SINGULAR_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  head_sha="$(git -C "$SINGULAR_ROOT" rev-parse HEAD 2>/dev/null || true)"

  local manifest_tmp
  manifest_tmp="$(mktemp)"
  python3 - "$dag_file" "$gates_dir" "$SINGULAR_TASKS_DIR" "$SINGULAR_EVENTS_FILE" \
    "$id" "$display_name" "$archived_at" "$engine_version" "$schema_version" \
    "$branch" "$head_sha" "$force" >"$manifest_tmp" <<'PY'
import json, os, sys
(dag_file, gates_dir, tasks_dir, events_file, plan_id, name, archived_at,
 engine_version, schema_version, branch, head_sha, force) = sys.argv[1:13]

# gates: successful among dag nodes (plain pass or acknowledged baseline);
# total = node count.
nodes = []
try:
    dag = json.load(open(dag_file))
    nodes = [str(n.get("id", "")) for n in dag.get("nodes", []) if isinstance(n, dict)]
except Exception:
    nodes = []
passed = 0
for nid in nodes:
    try:
        if json.load(open(os.path.join(gates_dir, f"{nid}.gate-result.json"))).get("status") in (
            "passed", "passed-with-acknowledged-baseline"
        ):
            passed += 1
    except Exception:
        pass

# taskCount: TASK-*.md directly under tasks_dir (excludes TEMPLATE.md & superseded/).
task_count = 0
if os.path.isdir(tasks_dir):
    for fn in os.listdir(tasks_dir):
        if fn.startswith("TASK-") and fn.endswith(".md") and os.path.isfile(os.path.join(tasks_dir, fn)):
            task_count += 1

# events: firstEventAt/lastEventAt/eventCount from the ts fields.
first_at = last_at = None
event_count = 0
if os.path.isfile(events_file):
    with open(events_file, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            event_count += 1
            ts = ev.get("ts")
            if ts:
                if first_at is None:
                    first_at = ts
                last_at = ts

manifest = {
    "schema": "singular.plan.manifest.v0",
    "id": plan_id,
    "name": name,
    "archivedAt": archived_at,
    "engineVersion": engine_version or None,
    "schemaVersion": schema_version or None,
    "branch": branch or None,
    "headSha": head_sha or None,
    "gates": {"passed": passed, "total": len(nodes)},
    "taskCount": task_count,
    "firstEventAt": first_at,
    "lastEventAt": last_at,
    "eventCount": event_count,
    "forced": force == "yes",
}
print(json.dumps(manifest, indent=2))
PY
  local gates_passed gates_total
  gates_passed="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["gates"]["passed"])' "$manifest_tmp")"
  gates_total="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["gates"]["total"])' "$manifest_tmp")"

  # --- Archive moves/copies into the mini-repo layout ---
  mkdir -p "$archive_dir/docs/orchestration" "$archive_dir/.singular-state"
  local adocs="$archive_dir/docs/orchestration" astate="$archive_dir/.singular-state" d s
  # MOVE docs-side (per-plan history).
  [[ -e "$dag_file" ]] && mv "$dag_file" "$adocs/dag.v0.json"
  for d in tasks gates areas packets; do
    [[ -e "$SINGULAR_ORCH_DIR/$d" ]] && mv "$SINGULAR_ORCH_DIR/$d" "$adocs/$d"
  done
  # COPY docs-side (durable repo-level; originals stay live).
  [[ -e "$SINGULAR_ORCH_DIR/prompts" ]] && cp -R "$SINGULAR_ORCH_DIR/prompts" "$adocs/prompts"
  [[ -f "$SINGULAR_ORCH_DIR/planner-contract.md" ]] && cp "$SINGULAR_ORCH_DIR/planner-contract.md" "$adocs/planner-contract.md"
  [[ -f "$SINGULAR_ORCH_DIR/decisions.md" ]] && cp "$SINGULAR_ORCH_DIR/decisions.md" "$adocs/decisions.md"
  # MOVE state-side (per-plan runtime record).
  [[ -e "$SINGULAR_EVENTS_FILE" ]] && mv "$SINGULAR_EVENTS_FILE" "$astate/events.ndjson"
  for s in runs sessions leases l1-leases dispatch inbox; do
    [[ -e "$SINGULAR_STATE_DIR/$s" ]] && mv "$SINGULAR_STATE_DIR/$s" "$astate/$s"
  done
  [[ -f "$SINGULAR_ORIGIN_STATE_FILE" ]] && mv "$SINGULAR_ORIGIN_STATE_FILE" "$astate/origin-state.json"
  [[ -f "$SINGULAR_STATUS_FILE" ]] && mv "$SINGULAR_STATUS_FILE" "$astate/STATUS.md"
  [[ -f "$SINGULAR_BREAKER_FILE" ]] && mv "$SINGULAR_BREAKER_FILE" "$astate/circuit.json"
  [[ -f "$SINGULAR_PLANNER_BACKOFF_FILE" ]] && mv "$SINGULAR_PLANNER_BACKOFF_FILE" "$astate/planner-backoff.json"
  local counter; counter="$(singular_task_id_counter_file)"
  [[ -d "$counter.lock" ]] && { rmdir "$counter.lock" 2>/dev/null || true; }
  [[ -f "$counter" ]] && mv "$counter" "$astate/task-id-counter"

  # --- Write manifest.json + upsert index.json (atomic, newest-first) ---
  python3 - "$manifest_tmp" "$archive_dir/manifest.json" "$plans_dir/index.json" <<'PY'
import json, os, sys, tempfile
manifest_tmp, manifest_dest, index_path = sys.argv[1:4]
manifest = json.load(open(manifest_tmp))

def atomic_write(path, obj):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

atomic_write(manifest_dest, manifest)

summary = {k: manifest.get(k) for k in
           ("id", "name", "archivedAt", "gates", "taskCount", "eventCount", "headSha", "branch")}
index = {"schema": "singular.plans.index.v0", "updatedAt": manifest["archivedAt"], "plans": []}
if os.path.exists(index_path):
    try:
        prev = json.load(open(index_path))
        if isinstance(prev.get("plans"), list):
            index["plans"] = [p for p in prev["plans"] if isinstance(p, dict)]
    except Exception:
        pass
index["plans"] = [p for p in index["plans"] if p.get("id") != summary["id"]]
# Insert the just-archived plan at the front so a stable DESC sort keeps it
# first even when a prior archive shares the same second-resolution archivedAt.
index["plans"].insert(0, summary)
index["plans"].sort(key=lambda p: p.get("archivedAt") or "", reverse=True)
index["updatedAt"] = manifest["archivedAt"]
atomic_write(index_path, index)
PY
  rm -f "$manifest_tmp"

  # --- Reset the live tree to a fresh starter plan ---
  singular_ensure_repo_scaffold
  cat >"$dag_file" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "layers": ["scaffold", "domain", "api"],
  "kinds": ["build", "test"],
  "nodes": [
    {"id": "M0.scaffold", "stage": "M0", "area": "core", "layer": "scaffold", "kind": "build", "dependsOn": [], "requiredCompletion": "scaffold_complete"}
  ]
}
EOF
  : >"$SINGULAR_EVENTS_FILE"
  local event_data
  event_data="$(python3 -c 'import json,sys
print(json.dumps({"planId":sys.argv[1],"name":sys.argv[2],"gates":{"passed":int(sys.argv[3]),"total":int(sys.argv[4])}},separators=(",",":")))' \
    "$id" "$display_name" "$gates_passed" "$gates_total")"
  singular_append_event "plan.archived" "archived plan $id ($display_name)" "$event_data"

  # --- Commit the reset docs (default; --no-commit opts out) ---
  local committed="false"
  if [[ "$no_commit" != "yes" ]]; then
    git -C "$SINGULAR_ROOT" add -A docs/orchestration 2>/dev/null || true
    if ! git -C "$SINGULAR_ROOT" diff --cached --quiet 2>/dev/null; then
      if git -C "$SINGULAR_ROOT" -c user.name="$SINGULAR_GIT_L0_NAME" -c user.email="$SINGULAR_GIT_L0_EMAIL" \
        commit -q -m "plan: archive $id ($display_name)" 2>/dev/null; then
        committed="true"
      fi
    fi
  fi

  # --- Release lock + summary ---
  singular_release_lock "$run_id" 2>/dev/null || true
  trap - EXIT
  python3 -c 'import json,sys
print(json.dumps({"ok":True,"id":sys.argv[1],"dir":sys.argv[2],
  "gates":{"passed":int(sys.argv[3]),"total":int(sys.argv[4])},
  "reset":True,"committed":sys.argv[5]=="true"},separators=(",",":")))' \
    "$id" "$archive_dir" "$gates_passed" "$gates_total" "$committed"
}

ops_plan_list() {
  local json="no"
  case "${1:-}" in
    --json) json="yes" ;;
    "")     : ;;
    *) echo "usage: singular plan list [--json]" >&2; return 2 ;;
  esac
  python3 - "$SINGULAR_STATE_DIR/plans" "$json" <<'PY'
import json, os, sys
plans_dir, as_json = sys.argv[1], sys.argv[2]
index_path = os.path.join(plans_dir, "index.json")
plans, seen = [], set()
# Primary source: the registry index.
if os.path.isfile(index_path):
    try:
        for p in json.load(open(index_path)).get("plans", []):
            if isinstance(p, dict) and p.get("id"):
                plans.append(p); seen.add(p["id"])
    except Exception:
        pass
# Self-heal: fold in any manifest not represented in the index.
if os.path.isdir(plans_dir):
    for name in sorted(os.listdir(plans_dir)):
        mpath = os.path.join(plans_dir, name, "manifest.json")
        if not os.path.isfile(mpath):
            continue
        try:
            m = json.load(open(mpath))
        except Exception:
            continue
        pid = m.get("id") or name
        if pid in seen:
            continue
        plans.append({k: m.get(k) for k in
            ("id", "name", "archivedAt", "gates", "taskCount", "eventCount", "headSha", "branch")})
        seen.add(pid)
plans.sort(key=lambda p: p.get("archivedAt") or "", reverse=True)

if as_json == "yes":
    print(json.dumps({"schema": "singular.plans.index.v0", "plans": plans}, indent=2))
    sys.exit(0)

if not plans:
    sys.stderr.write("no archived plans (run 'singular plan archive' when a DAG completes)\n")
    sys.exit(0)

def gates_str(p):
    ga = p.get("gates") or {}
    return f"{ga.get('passed', '?')}/{ga.get('total', '?')}"

idw = max([len(str(p.get("id", ""))) for p in plans] + [len("PLAN ID")]) + 2
namew = max([len(str(p.get("name", ""))) for p in plans] + [len("NAME")]) + 2
print(f"{'PLAN ID':<{idw}}{'NAME':<{namew}}{'ARCHIVED':<22}{'GATES':<8}TASKS")
for p in plans:
    print(f"{str(p.get('id', '')):<{idw}}{str(p.get('name', '')):<{namew}}"
          f"{str(p.get('archivedAt', '')):<22}{gates_str(p):<8}{p.get('taskCount', '')}")
PY
}

# --- ask / report (0.10.0 supervisor) ----------------------------------------
# ops_ask mints an ASK run, stages question.md (never argv-to-runner), and runs
# ask.sh. Default: dispatch in the background and print the runId. --wait: run in
# the foreground and print the answer when it lands.
ops_ask() {
  local question="" want_wait="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait) want_wait="yes"; shift ;;
      -*) echo "usage: singular ask \"<question>\" [--wait]" >&2; return 2 ;;
      *) if [[ -z "$question" ]]; then question="$1"; else question="$question $1"; fi; shift ;;
    esac
  done
  [[ -n "$question" ]] || { echo "usage: singular ask \"<question>\" [--wait]" >&2; return 2; }
  singular_ensure_state_dirs
  local run_id run_dir
  run_id="ASK-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  run_dir="$(singular_run_dir "$run_id")"
  mkdir -p "$run_dir"
  python3 - "$run_dir/question.md" "$question" <<'PY'
import os, sys
path, q = sys.argv[1], sys.argv[2]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(q)
os.replace(tmp, path)
PY
  echo "runId=$run_id"
  if [[ "$want_wait" == "yes" ]]; then
    "$(singular_bash_bin)" "$SCRIPT_DIR/ask.sh" --run-id "$run_id"
    # A timeout / no-answer ends with no answer.md; that is a normal terminal
    # outcome (state is in ask.json), so never fail the verb on its absence.
    if [[ -f "$run_dir/answer.md" ]]; then echo "---"; cat "$run_dir/answer.md"; fi
  else
    ( "$(singular_bash_bin)" "$SCRIPT_DIR/ask.sh" --run-id "$run_id" >>"$run_dir/ask-spawn.log" 2>&1 & ) || true
    echo "dispatched (poll the console, or re-run with --wait)"
  fi
}

# ops_report runs a single supervisor briefing in the foreground; latest.json is
# updated in place only if the model returns a schema-valid report.
ops_report() {
  echo "requesting supervisor briefing (readonly, one-shot)..." >&2
  "$(singular_bash_bin)" "$SCRIPT_DIR/supervise.sh" --once
}

case "$verb" in
  supersede)     ops_supersede "$@" ;;
  unpark)        ops_unpark "$@" ;;
  recover-candidate) ops_recover_candidate "$@" ;;
  clear-backoff) singular_planner_backoff_clear ;;
  breaker)       ops_breaker "$@" ;;
  stop)          ops_stop "$@" ;;
  resume)        ops_resume "$@" ;;
  wake)          ops_wake "$@" ;;
  gates)         ops_gates "$@" ;;
  health)        ops_health "$@" ;;
  gc)            ops_gc "$@" ;;
  plan)          ops_plan "$@" ;;
  ask)           ops_ask "$@" ;;
  report)        ops_report "$@" ;;
  *)
    echo "usage: ops.sh supersede|unpark|recover-candidate|clear-backoff|breaker|stop|resume|wake|gates|health|gc|plan|ask|report ..." >&2
    exit 2 ;;
esac
