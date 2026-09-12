#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "autonomate.sh requires bash >= 4" >&2; exit 1
fi

# The self-driving loop. Each iteration runs one full actuate cycle (import ->
# recover -> generate a ready frontier if idle -> dispatch worker batch -> audit
# -> auto-fix -> integrate -> push), then writes STATUS and sleeps. It stops on: the STOP
# sentinel, the wall-clock budget (SINGULAR_MAX_HOURS), the circuit breaker
# (SINGULAR_MAX_CONSEC_FAILS consecutive no-progress failures), or DAG exhaustion.
#
# Single-instance via a pidfile so the launchd watchdog only relaunches it if it
# died. `--once` runs a single iteration (for tests).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
reconcile_script="${SINGULAR_RECONCILE_SCRIPT:-$SCRIPT_DIR/reconcile.sh}"

export SINGULAR_TARGET_BRANCH="${SINGULAR_TARGET_BRANCH:-}"
export SINGULAR_AUTO_INTEGRATE="${SINGULAR_AUTO_INTEGRATE:-1}"
export SINGULAR_PUSH="${SINGULAR_PUSH:-1}"
export SINGULAR_GENERATE="${SINGULAR_GENERATE:-1}"
# A configured reconcile script is a child process, so it must receive the
# canonical paths resolved by lib.sh. Relying on whether the caller happened
# to export these variables made custom reconcilers observe an empty state
# directory (or a differently-spelled /var versus /private/var path).
export SINGULAR_ROOT SINGULAR_STATE_DIR SINGULAR_JSON_CONFIG_FILE \
  SINGULAR_JSON_CONFIG_SOURCE SINGULAR_JSON_CONFIG_DEFAULT_ROOT \
  SINGULAR_JSON_CONFIG_DEFAULT_FILE
sleep_secs="${SINGULAR_SLEEP:-20}"
quota_sleep_cap="${SINGULAR_QUOTA_SLEEP_CAP:-300}"       # max seconds per quota-window poll nap
quota_wait_budget="${SINGULAR_QUOTA_WAIT_BUDGET:-10800}" # total quota-wait before escalating to STOP (3h)
quota_waited_total=0
# Provider overload gets its own budget. Sharing one would let a burst of 529s
# spend the usage-limit budget and escalate to STOP for a reason that was never
# a usage limit.
overload_wait_budget="${SINGULAR_OVERLOAD_WAIT_BUDGET:-3600}"
overload_waited_total=0
once="no"
detach="no"
for arg in "$@"; do
  case "$arg" in
    --once) once="yes" ;;
    --detach) detach="yes" ;;
    *) echo "autonomate: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

singular_ensure_state_dirs
singular_require_target_branch

# A manifest exists only after `singular campaign start`; legacy callers remain
# compatible, while an explicit campaign cannot silently continue after its
# engine, configuration, shell, runner, gate, evidence or prompt-policy surface
# changes. Verification is repeated at EVERY actuation boundary below: a
# process that stays alive across a hot patch must not keep dispatching simply
# because its startup preflight was once green.
autonomate_campaign_verify() {
  local phase="$1" cycle="${2:-0}"
  "$SCRIPT_DIR/campaign.sh" verify --quiet && return 0
  singular_append_event "campaign.drift_detected" "autonomate refused runtime drift" \
    "{\"manifest\":\"${SINGULAR_CAMPAIGN_MANIFEST:-$SINGULAR_STATE_DIR/campaign/manifest.json}\",\"phase\":\"$phase\",\"iteration\":$cycle}" || true
  singular_write_status "$cycle" "stopped (campaign runtime drift at $phase)" || true
  echo "[autonomate] campaign runtime drift at $phase; refusing further actuation. Review 'singular campaign verify', end the campaign, and start a replacement." >&2
  return 1
}
if ! autonomate_campaign_verify startup 0; then
  exit 2
fi

pidfile="$SINGULAR_STATE_DIR/autonomate.pid"
# The process identity lives BESIDE the pidfile, not inside it. ops.sh, doctor
# and the console all read the pidfile with `cat` and expect a bare number;
# adding a second line to it broke `singular auto --detach` outright and would
# have broken five more readers quietly.
pididfile="$pidfile.identity"
pid_start_of() { ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//'; }

# True when the pidfile names a process that is genuinely still this loop.
#
# `kill -0` alone cannot: a pid is a small recycled integer, and an unrelated
# long-running process that inherits the number reads as "autonomate is already
# running" forever, with no way to start the loop again short of deleting the
# file by hand. Recording `ps lstart` at claim time and comparing it here is what
# tells the two apart.
autonomate_holder_alive() {
  local holder_pid holder_start
  holder_pid="$(sed -n '1p' "$pidfile" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$holder_pid" ]] || return 1
  kill -0 "$holder_pid" 2>/dev/null || return 1
  holder_start="$(sed -n '1p' "$pididfile" 2>/dev/null)"
  # No recorded identity: a pidfile written by an older engine. Trust the pid,
  # since refusing to start is the safer of the two wrong answers there.
  [[ -n "$holder_start" ]] || return 0
  [[ "$holder_start" == "$(pid_start_of "$holder_pid")" ]]
}

# --detach (0.5.0): supported daemonized launch. The field run hand-rolled
# python setsid double-forks 6+ times because plain `nohup ... &` dies on
# shell handoff and launchd is TCC-blocked on user dirs. The child re-execs
# this script with SINGULAR_AUTONOMATE_DETACHED=1; the parent waits for the
# pidfile to prove liveness, prints it, and exits.
if [[ "$detach" == "yes" && "${SINGULAR_AUTONOMATE_DETACHED:-}" != "1" ]]; then
  # Identity-aware, like the claim below. This check used to be `kill -0` alone,
  # so a recycled pid made `singular auto --detach` a permanent no-op.
  if autonomate_holder_alive; then
    echo "autonomate already running (pid $(sed -n '1p' "$pidfile" 2>/dev/null))"
    exit 0
  fi
  detach_log="$SINGULAR_STATE_DIR/autonomate.log"
  detach_args=()
  [[ "$once" == "yes" ]] && detach_args+=("--once")
  SINGULAR_AUTONOMATE_DETACHED=1 python3 - "$BASH_SOURCE" "$detach_log" \
    "$(singular_bash_bin)" ${detach_args[@]+"${detach_args[@]}"} <<'PY'
import os, sys
script, log, bash_bin = sys.argv[1:4]
extra = sys.argv[4:]
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        devnull = os.open(os.devnull, os.O_RDONLY)
        os.dup2(devnull, 0)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.execv(bash_bin, [bash_bin, script] + extra)
    os._exit(0)
os.wait()
PY
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    newpid="$(sed -n '1p' "$pidfile" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$newpid" && "$newpid" != "$$" ]] && kill -0 "$newpid" 2>/dev/null; then
      echo "autonomate: detached pid=$newpid log=$detach_log"
      exit 0
    fi
  done
  echo "autonomate: detached launch FAILED; last log lines:" >&2
  tail -5 "$detach_log" 2>/dev/null >&2 || true
  exit 1
fi
# Single-instance guard.
#
# This used to read the pidfile, decide, and then write it — two processes
# racing that window both saw a dead predecessor and both started. The habitual
# `breaker reset; wake; auto` recovery sequence sits right on top of it: `wake`
# drops STOP while the previous loop is still exiting, and `auto` follows within
# a second.
#
# mkdir is the atomic primitive (the same one singular_git_lock_acquire uses):
# exactly one process can create the directory, so exactly one can claim the
# pidfile. Liveness is decided by autonomate_holder_alive above, which is
# pid-reuse-safe.
pidlock="$pidfile.lock"

autonomate_write_pidfile() {
  printf '%s\n' "$$" >"$pidfile"
  printf '%s\n' "$(pid_start_of $$)" >"$pididfile"
}

autonomate_claim_pidfile() {
  if mkdir "$pidlock" 2>/dev/null; then
    if autonomate_holder_alive; then
      rmdir "$pidlock" 2>/dev/null || true
      return 1
    fi
    autonomate_write_pidfile
    rmdir "$pidlock" 2>/dev/null || true
    return 0
  fi
  # Another process holds the lock right now; give it a moment to finish
  # writing, then defer to it.
  local waited=0
  while [[ -d "$pidlock" && "$waited" -lt 50 ]]; do sleep 0.1; waited=$((waited + 1)); done
  autonomate_holder_alive && return 1
  if mkdir "$pidlock" 2>/dev/null; then
    autonomate_write_pidfile
    rmdir "$pidlock" 2>/dev/null || true
    return 0
  fi
  return 1
}

if ! autonomate_claim_pidfile; then
  echo "autonomate already running (pid $(sed -n '1p' "$pidfile" 2>/dev/null)); exiting"
  exit 0
fi
cleanup() {
  if [[ "$(sed -n '1p' "$pidfile" 2>/dev/null | tr -d '[:space:]')" == "$$" ]]; then
    rm -f "$pidfile" "$pididfile"
  fi
  rmdir "$pidlock" 2>/dev/null || true
}
trap cleanup EXIT

# Unattended actuation gate (PMGO-004).
#
# This loop dispatches agents nobody is watching and kills them when they time
# out. If the host cannot terminate a process group, that kill does not contain
# the tree: the provider and shell descendants survive, keep writing to a
# worktree, and the cleanup still LOOKS successful. A restricted sandbox reached
# exactly that state in the field. Refusing to start is the only honest answer —
# the alternative is hours of unsupervised runs whose failure mode is silent
# corruption. Ordering matters: the claim already succeeded, so the EXIT trap
# above releases the pidfile on the way out and a later `singular auto` is not
# locked out by this refusal.
#
# Attended paths (ask/supervise/one-shot runners) are deliberately NOT gated: an
# operator watching a single run can see and clean up a survivor.
#
# SINGULAR_ALLOW_DEGRADED_KILL=1 is the documented override for operators who
# accept the risk; it downgrades the refusal to a logged warning.
preflight_state="$(singular_process_control_preflight)"
if [[ "$preflight_state" == degraded:* ]]; then
  preflight_reason="${preflight_state#degraded:}"
  if [[ "${SINGULAR_ALLOW_DEGRADED_KILL:-0}" == "1" ]]; then
    echo "[autonomate] WARNING: process-group cleanup is unverified ($preflight_reason); continuing because SINGULAR_ALLOW_DEGRADED_KILL=1. Timed-out agents may leave surviving descendants." >&2
    singular_append_event "autonomate.preflight_degraded_override" \
      "process-group cleanup unverified; continuing under SINGULAR_ALLOW_DEGRADED_KILL" \
      "{\"reason\":\"$preflight_reason\"}"
  else
    singular_append_event "autonomate.preflight_unsafe" \
      "process-group cleanup unverified; refusing unattended actuation" \
      "{\"reason\":\"$preflight_reason\"}"
    {
      echo "[autonomate] REFUSING to start: this environment cannot prove it can terminate a process group ($preflight_reason)."
      echo "[autonomate] A timed-out agent's descendants could survive the kill and keep writing to a worktree."
      echo "[autonomate] Run 'singular doctor' and read the runtime.process-group-kill check, or set SINGULAR_ALLOW_DEGRADED_KILL=1 to accept the risk."
    } >&2
    exit 2
  fi
fi

start_ts="$(date +%s)"
max_hours_int="${SINGULAR_MAX_HOURS%%.*}"; [[ "$max_hours_int" =~ ^[0-9]+$ ]] || max_hours_int=20
deadline=$(( start_ts + max_hours_int * 3600 ))
iteration=0
campaign_drifted="no"

singular_append_event "autonomate.started" "autonomous loop started" \
  "{\"pid\":$$,\"maxHours\":\"$SINGULAR_MAX_HOURS\",\"autoIntegrate\":\"$SINGULAR_AUTO_INTEGRATE\",\"push\":\"$SINGULAR_PUSH\"}"

while true; do
  iteration=$((iteration + 1))
  now="$(date +%s)"

  if singular_stop_requested; then
    echo "[autonomate] STOP sentinel; halting after $((iteration-1)) iteration(s)"
    singular_write_status "$iteration" "stopped (STOP sentinel)"
    singular_append_event "autonomate.stopped" "stopped by STOP sentinel" "{\"iteration\":$iteration}"
    break
  fi
  if [[ "$now" -ge "$deadline" ]]; then
    echo "[autonomate] wall-clock budget reached (${SINGULAR_MAX_HOURS}h); halting"
    singular_write_status "$iteration" "stopped (time-box ${SINGULAR_MAX_HOURS}h)"
    singular_append_event "autonomate.stopped" "stopped by time-box" "{\"iteration\":$iteration}"
    break
  fi
  breaker="$(singular_breaker_count)"
  if [[ "$breaker" -ge "$SINGULAR_MAX_CONSEC_FAILS" ]]; then
    echo "[autonomate] circuit breaker open ($breaker/$SINGULAR_MAX_CONSEC_FAILS); halting"
    singular_write_status "$iteration" "stopped (circuit breaker $breaker/$SINGULAR_MAX_CONSEC_FAILS)"
    singular_append_event "autonomate.stopped" "stopped by circuit breaker" "{\"iteration\":$iteration,\"consecFails\":$breaker}"
    break
  fi

  # This is the transaction boundary for autonomous work. reconcile --actuate
  # owns planning, dispatch, packet import, integration and promotion, so no
  # such operation can begin in this cycle until the immutable campaign still
  # matches. A drift discovered after the preceding cycle therefore stops here
  # before any additional mutation.
  if ! autonomate_campaign_verify cycle-boundary "$iteration"; then
    campaign_drifted="yes"
    break
  fi

  # Provider window: a planner backoff whose failureClass names one means the
  # provider — not the code — is refusing. Two classes qualify:
  #
  #   quota                the session *usage limit* (or an entitlement denial)
  #   provider-overloaded  a 503/529: the provider shedding load
  #
  # Refusing to plan is correct in both cases, but neither is a code failure and
  # neither may trip the circuit breaker; the loop sleeps through the window so
  # it auto-recovers. They differ only in how long: a usage limit is tens of
  # minutes, an overload is seconds, and each carries its own wait budget.
  # EVERY other failure class falls through to the normal cycle below and still
  # counts toward the breaker. STOP is honored before and after the nap, and the
  # wait budget escalates an unbounded window to STOP rather than idling forever.
  # With no active backoff this block is a no-op.
  planner_backoff_at_cycle_start=0
  bo_json="$(singular_planner_backoff_active_json 2>/dev/null || true)"
  if [[ -n "$bo_json" ]]; then
    planner_backoff_at_cycle_start=1
    bo_class=""; bo_remaining=0
    read -r bo_class bo_remaining < <(python3 - "$bo_json" <<'PY'
import json, sys
from datetime import datetime, timezone
try:
    d = json.loads(sys.argv[1])
    rem = int((datetime.fromisoformat(str(d.get("until", "")).replace("Z", "+00:00")) - datetime.now(timezone.utc)).total_seconds())
    if rem < 0:
        rem = 0
    print(d.get("failureClass", "unknown"), rem)
except Exception:
    print("unknown", 0)
PY
)
    [[ "$bo_remaining" =~ ^[0-9]+$ ]] || bo_remaining=0
    if [[ ( "$bo_class" == "quota" || "$bo_class" == "provider-overloaded" ) && "$bo_remaining" -gt 0 ]]; then
      if [[ "$bo_class" == "provider-overloaded" ]]; then
        window_label="provider overload"; window_waited="$overload_waited_total"; window_budget="$overload_wait_budget"
      else
        window_label="quota"; window_waited="$quota_waited_total"; window_budget="$quota_wait_budget"
      fi
      if [[ "$window_waited" -ge "$window_budget" ]]; then
        echo "[autonomate] $window_label wait budget exhausted (${window_waited}s >= ${window_budget}s); setting STOP"
        : >"$SINGULAR_STOP_FILE"
        singular_write_status "$iteration" "stopped ($window_label wait budget ${window_budget}s exhausted)"
        singular_append_event "autonomate.stopped" "stopped: $window_label wait budget exhausted" "{\"iteration\":$iteration,\"failureClass\":\"$bo_class\",\"waitedTotal\":$window_waited}"
        break
      fi
      nap="$bo_remaining"; [[ "$nap" -gt "$quota_sleep_cap" ]] && nap="$quota_sleep_cap"
      echo "[autonomate] planner $window_label window open (${bo_remaining}s left); sleeping up to ${nap}s WITHOUT breaker increment (waited ${window_waited}s)"
      singular_append_event "autonomate.quota_wait" "sleeping through planner $window_label window" "{\"iteration\":$iteration,\"failureClass\":\"$bo_class\",\"remainingSec\":$bo_remaining,\"napSec\":$nap,\"waitedTotal\":$window_waited}"
      singular_write_status "$iteration" "sleeping through $window_label window (${bo_remaining}s left, waited ${window_waited}s)"
      [[ "$once" == "yes" ]] && { echo "[autonomate] --once: $window_label wait detected, single iteration done"; break; }
      # Interruptible (0.5.0): STOP mid-nap ends the loop within
      # SINGULAR_SLEEP_POLL_SEC; `singular wake` / clear-backoff end the nap
      # early. Only actually-slept seconds count toward the window's budget.
      nap_started=$SECONDS
      nap_rc=0
      singular_interruptible_sleep "$nap" 1 || nap_rc=$?
      if [[ "$bo_class" == "provider-overloaded" ]]; then
        overload_waited_total=$((overload_waited_total + SECONDS - nap_started))
      else
        quota_waited_total=$((quota_waited_total + SECONDS - nap_started))
      fi
      [[ "$nap_rc" -eq 2 ]] && { echo "[autonomate] STOP during $window_label wait; halting"; break; }
      singular_stop_requested && { echo "[autonomate] STOP during $window_label wait; halting"; break; }
      # WAKE means useful completion/control state may be waiting even though
      # the planner provider is still unavailable. Run exactly one control-
      # plane reconcile: import/reap/integrate/promote stay live, while both
      # planner generation and worker dispatch are hard-disabled. Then return
      # to the same backoff window; this path never increments the breaker.
      if [[ "$nap_rc" -eq 1 ]] \
          && bo_after_wake="$(singular_planner_backoff_active_json 2>/dev/null)"; then
        echo "[autonomate] WAKE during active $window_label window; running one control-plane-only reconcile"
        singular_append_event "autonomate.backoff_control_reconcile" \
          "wake during active provider window; running control-plane-only reconcile" \
          "{\"iteration\":$iteration,\"failureClass\":\"$bo_class\",\"backoff\":$bo_after_wake}"
        control_out="$(SINGULAR_GENERATE=0 SINGULAR_MAX_DISPATCH=0 \
          "$reconcile_script" --actuate 2>&1)" || true
        printf '%s\n' "$control_out" | sed 's/^/  control: /'
        singular_stop_requested \
          && { echo "[autonomate] STOP after control-plane reconcile; halting"; break; }
      fi
      iteration=$((iteration - 1))
      continue
    fi
  fi

  echo "[autonomate] iteration $iteration (elapsed $(( (now-start_ts)/60 ))m, breaker $breaker/$SINGULAR_MAX_CONSEC_FAILS)"
  cycle_out="$("$reconcile_script" --actuate 2>&1)" || true
  printf '%s\n' "$cycle_out" | sed 's/^/  /'

  field() { printf '%s\n' "$cycle_out" | sed -n "s/^$1=//p" | tail -1; }
  dispatched="$(field dispatched_this_run)"; integrated="$(field integrated_this_run)"
  accepted="$(field imported_this_run)"
  faild="$(field failed_dispatches)"; faili="$(field failed_integrations)"
  planner_failures="$(field planner_failures_this_run)"
  planner_backoff_deferred="$(field planner_backoff_active_this_run)"
  l1_import_rejections="$(field l1_import_rejections_this_run)"
  reaped_ok="$(field reaped_ok)"; reaped_failures="$(field reaped_failures)"
  workers_running="$(field workers_running)"
  promoted="$(field gates_promoted_this_run)"
  for v in dispatched integrated accepted faild faili planner_failures planner_backoff_deferred l1_import_rejections reaped_ok reaped_failures workers_running promoted; do [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
  if [[ "$planner_backoff_at_cycle_start" -eq 1 && "$planner_failures" -gt 0 ]]; then
    echo "  [autonomate] active planner backoff made planner refusal neutral; ignoring $planner_failures planner failure(s) for breaker accounting"
    singular_append_event "autonomate.planner_backoff_neutral" \
      "active planner backoff suppressed repeated planner failure accounting" \
      "{\"iteration\":$iteration,\"suppressedPlannerFailures\":$planner_failures}"
    planner_failures=0
    planner_backoff_deferred=1
  fi
  gen_complete="no"; printf '%s\n' "$cycle_out" | grep -q 'all-areas-complete' && gen_complete="yes"
  gen_made="no"; printf '%s\n' "$cycle_out" | grep -q 'gen:.*generated:' && gen_made="yes"
  # Reconcile's frontier selector already performs the authoritative duplicate,
  # dependency, lease, and scope checks. This post-cycle value is telemetry only;
  # avoid the legacy per-task duplicate scan on large campaigns.
  ready_now="$(singular_list_status_ready_tasks | wc -l | tr -d ' ')"
  active_now="$(singular_active_lease_count)"

  # Only durable campaign advancement resets the breaker. Generating a new
  # candidate, launching a worker, or reaping an exit-zero process is activity,
  # not proof that the orchestration made useful progress: all three happened
  # repeatedly in the field while the same node/finding tuple spun forever.
  #
  # imported_this_run is an accepted packet (import-packet.sh refuses anything
  # without an accepted exact-head audit or an explicit waiver); integration and
  # gate promotion are the other two monotone DAG transitions. A process restart
  # deliberately preserves the counter — operators can still use the explicit
  # `singular breaker reset` command after changing the blocking condition.
  progress="no"
  if [[ "$accepted" -gt 0 || "$integrated" -gt 0 || "$promoted" -gt 0 ]]; then
    progress="yes"
  fi

  if [[ "$progress" == "yes" ]]; then
    singular_breaker_reset
    # Additive-increase half of the provider-pressure controller (opt-in). A
    # cycle that made progress counts as one quiet interval; after
    # SINGULAR_PROVIDER_PRESSURE_RECOVER_QUIET of them the ceiling rises by
    # exactly one slot. "Quiet" is approximate on purpose: recording a FRESH
    # observation resets the counter to zero, but generate-tasks.sh observes
    # mid-cycle while this ticks at end-of-cycle, so a cycle that both hit a 429
    # and still integrated work banks one tick anyway. That errs toward
    # recovering capacity, which the cluster threshold then re-takes if the
    # congestion is real. No-op unless the selected provider is actually
    # throttled, so a healthy loop writes no state.
    singular_provider_pressure_success >/dev/null 2>&1 || true
  elif [[ "$faild" -gt 0 || "$faili" -gt 0 || "$planner_failures" -gt 0 || "$l1_import_rejections" -gt 0 || ( "${SINGULAR_DETACHED_DISPATCH:-0}" == "1" && "$reaped_failures" -gt 0 ) ]]; then
    # C2 (0.5.0): a usage-limit / 403 / overload window can poison the decider,
    # auditor, L1 fanout, or dispatch paths, producing cycle failures with NO
    # active quota backoff. When a validated runner-result/provider-error pair
    # exists in this cycle (singular_cycle_limit_window_evidence_json), ARM a
    # quota backoff so the next iteration sleeps
    # through, and do NOT increment the breaker. Import rejections are
    # deterministic validation outcomes (duplicate candidates, bad batches) and
    # can never be quota evidence — they are excluded from limit ELIGIBILITY
    # (0.4.0 counted them, arming false 30-minute backoffs from healthy cycles)
    # though they still count toward the breaker branch. FAIL-CLOSED: no
    # evidence -> the breaker trips, so genuine code failures are unaffected.
    # SINGULAR_LIMIT_SLEEPTHROUGH=0 (or legacy SINGULAR_DISABLE_LIMIT_SLEEPTHROUGH=1,
    # deprecated) forces the always-trip behavior.
    limit_eligible=$((faild + faili + planner_failures))
    [[ "${SINGULAR_DETACHED_DISPATCH:-0}" == "1" ]] && limit_eligible=$((limit_eligible + reaped_failures))
    sleepthrough="${SINGULAR_LIMIT_SLEEPTHROUGH:-1}"
    [[ "${SINGULAR_DISABLE_LIMIT_SLEEPTHROUGH:-0}" == "1" ]] && sleepthrough=0
    limit_evidence=""
    if [[ "$sleepthrough" == "1" && "$limit_eligible" -gt 0 ]]; then
      limit_evidence="$(singular_cycle_limit_window_evidence_json 2>/dev/null || true)"
    fi
    ev_resultref=""
    ev_class=""
    if [[ -n "$limit_evidence" ]]; then
      # The class must come from the evidence, not be assumed. This site used to
      # hardcode "quota", so an overload window re-armed a 30-minute backoff here
      # even once the classifier had told the truth about it.
      # Class first: `read` folds every remaining field into the last variable,
      # so a resultRef containing spaces survives intact.
      read -r ev_class ev_resultref < <(printf '%s' "$limit_evidence" | python3 -c '
import json, sys
d = json.load(sys.stdin)
kinds = {"usage-limit": "quota", "entitlement": "quota", "overloaded": "provider-overloaded"}
print(kinds.get(d.get("kind"), ""), d.get("resultRef", ""))
' 2>/dev/null || true)
    fi
    # Suppressing the breaker is only safe if the backoff we just armed will
    # actually be honoured on the next iteration. Backoffs became
    # provider-scoped, but this cycle scanner is not: it will happily arm a
    # window from provider X's evidence while the loop is running provider Y,
    # and the honour path then discards it. That combination has no terminating
    # condition — the loop never sleeps, so the wait budget never accumulates
    # and never escalates to STOP, while the breaker sits pinned at zero. The
    # record is still written (evidence preserved, and it reactivates if the
    # runner reverts); what we decline to do is buy breaker immunity with a
    # window that cannot stop us.
    if [[ -n "$ev_resultref" && -n "$ev_class" ]] \
      && singular_planner_backoff_set "$ev_class" "RUN-limit-chokepoint" "breaker-chokepoint" "$ev_resultref" \
      && singular_planner_backoff_active_json >/dev/null 2>&1; then
      echo "  [autonomate] no progress + structured provider limit evidence ($ev_resultref); armed $ev_class backoff, NO breaker increment (breaker stays $breaker/$SINGULAR_MAX_CONSEC_FAILS)"
      singular_append_event "autonomate.limit_window_detected" "provider window at breaker chokepoint; armed $ev_class backoff instead of tripping" "{\"iteration\":$iteration,\"failureClass\":\"$ev_class\",\"breaker\":$breaker,\"failD\":$faild,\"failI\":$faili,\"plannerFail\":$planner_failures,\"importReject\":$l1_import_rejections,\"evidence\":$limit_evidence}"
    else
      nb="$(singular_breaker_trip)"; echo "  [autonomate] no progress + failure; breaker -> $nb"
    fi
  fi

  singular_write_status "$iteration" "running (disp=$dispatched accepted=$accepted int=$integrated failD=$faild failI=$faili planFail=$planner_failures planBackoff=$planner_backoff_deferred importReject=$l1_import_rejections reapOK=$reaped_ok reapFail=$reaped_failures workers=$workers_running)"

  # Periodic supervisor briefing (0.10.0). BYTE-INERT when the interval knob is
  # unset/0: a single string test skips the whole block, so no supervisor/ dir,
  # stamp, or SUP run is ever created. When enabled, brief at most once per
  # interval, never during a quota/planner backoff, and stamp BEFORE spawning so
  # an immediate next cycle cannot double-spawn. The briefing is a detached,
  # log-redirected background readonly session — it never blocks the loop.
  sup_int="${SINGULAR_SUPERVISOR_INTERVAL_MIN:-0}"
  if [[ "$sup_int" =~ ^[0-9]+$ && "$sup_int" -gt 0 && -z "$bo_json" ]]; then
    sup_dir="$SINGULAR_STATE_DIR/supervisor"
    sup_last=0
    [[ -f "$sup_dir/last-run" ]] && sup_last="$(cat "$sup_dir/last-run" 2>/dev/null || echo 0)"
    [[ "$sup_last" =~ ^[0-9]+$ ]] || sup_last=0
    if (( now - sup_last >= sup_int * 60 )); then
      mkdir -p "$sup_dir"
      printf '%s\n' "$now" >"$sup_dir/last-run"
      ( "$(singular_bash_bin)" "$SCRIPT_DIR/supervise.sh" --once >>"$sup_dir/spawn.log" 2>&1 & ) || true
    fi
  fi

  # DAG exhausted: planner says all areas complete and nothing is left to do.
  if [[ "$gen_complete" == "yes" && "$ready_now" -eq 0 && "$active_now" -eq 0 ]]; then
    echo "[autonomate] DAG exhausted (all areas complete); halting"
    singular_write_status "$iteration" "stopped (DAG complete)"
    singular_append_event "autonomate.stopped" "stopped: DAG complete" "{\"iteration\":$iteration}"
    break
  fi

  [[ "$once" == "yes" ]] && { echo "[autonomate] --once: single iteration done"; break; }
  # Interruptible (0.5.0): STOP is honored mid-nap (0.4.0 checked only at loop
  # top, so a STOP written during the sleep waited out the full nap); WAKE
  # ends it early without killing sleep children (which killed the whole loop
  # in the field).
  singular_interruptible_sleep "$sleep_secs" || true
done

singular_append_event "autonomate.exited" "autonomous loop exited" "{\"iterations\":$iteration}"
echo "[autonomate] done after $iteration iteration(s). STATUS: $SINGULAR_STATUS_FILE"
if [[ "$campaign_drifted" == "yes" ]]; then
  exit 2
fi
exit 0
