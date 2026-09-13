#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "supervise.sh requires bash >= 4" >&2; exit 1
fi

# Supervisor briefing (0.10.0). One-shot: assemble the read-only situational
# digest, render the supervisor prompt, run ONE read-only runner pass, and — only
# on a schema-valid report — publish it as the latest briefing the console Home
# card reads. Modeled on decide.sh (one-shot readonly spawn + kill-tree watchdog
# + extract/validate). NEVER edits code, git, tasks, leases, or settings.
#
# On success:  .singular-state/supervisor/latest.json (+ history/<utc>.json, 20 kept)
#              and a supervisor.report event.
# On failure:  a supervisor.failed event; latest.json is left untouched.
#
# The run dir is shaped like a normal session dir so the console discovers it:
#   runs/SUP-<utc>-<pid>/{supervisor-prompt.md, supervisor-codex.log,
#                         session-supervisor.json, report-raw.json}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

# Briefing runner. Defaults to the codex runner; SINGULAR_RUNNER selects a drop-in.
# SINGULAR_ROLE_RUNNER_SUPERVISOR (from config roleRunners.supervisor) wins when set.
SINGULAR_RUNNER_BIN="$(singular_role_runner supervisor "${SINGULAR_RUNNER:-$SCRIPT_DIR/codex-run.sh}")" || exit 78

# --once is the only supported mode; accepted (and default) for symmetry with the
# rest of the engine and forward-compatibility.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) shift ;;
    *) echo "usage: supervise.sh [--once]" >&2; exit 2 ;;
  esac
done

timeout_sec="${SINGULAR_SUPERVISOR_TIMEOUT_SEC:-900}"
[[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || timeout_sec=900

singular_ensure_state_dirs
run_id="SUP-$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$(singular_run_dir "$run_id")"
mkdir -p "$run_dir"

sup_dir="$SINGULAR_STATE_DIR/supervisor"
mkdir -p "$sup_dir/history"

# Emit a supervisor.failed event with a machine-readable reason, then exit 0.
# A failed briefing is observability, never a loop-breaking error.
supervisor_fail() {
  local reason="$1" message="$2"
  singular_append_event "supervisor.failed" "$message" \
    "$(python3 - "$run_id" "$reason" <<'PY'
import json, sys
run_id, reason = sys.argv[1:3]
print(json.dumps({"runId": run_id, "reason": reason}, separators=(",", ":")))
PY
)"
}

# 1. Digest -> rendered prompt (fall back to engine templates for pre-0.10 repos).
digest_file="$run_dir/digest.txt"
singular_supervisor_digest "$digest_file"

tmpl="$SINGULAR_ORCH_DIR/prompts/supervisor.md"
[[ -f "$tmpl" ]] || tmpl="$SINGULAR_ENGINE_HOME/templates/prompts/supervisor.md"
if [[ ! -f "$tmpl" ]]; then
  supervisor_fail "no-template" "supervisor prompt template not found"
  echo "runId=$run_id" ; echo "status=failed" ; exit 0
fi

prompt_file="$run_dir/supervisor-prompt.md"
singular_render_supervisor_prompt "$tmpl" "$digest_file" "$prompt_file"

# 2. One read-only runner pass + kill-tree watchdog (decide.sh model).
raw="$run_dir/report-raw.json"
log="$run_dir/supervisor-codex.log"
meta="$run_dir/session-supervisor.json"
runner_result="$run_dir/supervisor-runner-result.json"

timed_out="no"
rm -f "$runner_result"
supervisor_capability_profile="${SINGULAR_SUPERVISOR_CAPABILITY_PROFILE:-supervisor-core}"
singular_runner_contract_prepare \
  "$SINGULAR_RUNNER_BIN" supervisor "$supervisor_capability_profile" "$runner_result"
# `exec` so $! IS the runner script, not a subshell wrapping it. The runner is a
# cooperative citizen — it traps TERM and group-kills its own provider session —
# but only if the TERM actually reaches it; with an intermediate subshell the
# signal landed on a bash that was merely waiting. Deliberately NOT a new
# session: the supervisor keeps sharing this shell's terminal group.
(
  export SINGULAR_RUNNER_ROLE=supervisor
  export SINGULAR_RUNNER_CAPABILITY_PROFILE="$supervisor_capability_profile"
  export SINGULAR_RUNNER_RESULT_FILE="$runner_result"
  export SINGULAR_RUNNER_RUN_ID="$run_id"
  exec "$SINGULAR_RUNNER_BIN" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
    --level readonly -C "$SINGULAR_ROOT" \
    --run-id "$run_id" \
    --prompt-file "$prompt_file" \
    --output-last-message "$raw" \
    --session-meta "$meta"
) >>"$log" 2>&1 &
runner_pid=$!
deadline=$((SECONDS + timeout_sec))
while kill -0 "$runner_pid" 2>/dev/null; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    timed_out="yes"
    # With a grace period, so the runner's EXIT trap — which holds the read-only
    # restore guard — gets to run. autonomate.sh backgrounds this supervisor
    # every cycle against $SINGULAR_ROOT for up to 900s; a bare SIGKILL here left
    # every mutation it made in the operator's repo.
    singular_kill_tree "$runner_pid" "$(singular_kill_grace_sec)"
    wait "$runner_pid" 2>/dev/null || true
    break
  fi
  sleep 1
done
if [[ "$timed_out" != "yes" ]]; then
  wait "$runner_pid" || true
fi

singular_session_meta_finalize "$meta" "supervisor" "" "$run_id" \
  "$(basename "$SINGULAR_RUNNER_BIN")" "$(singular_prompt_sha "$prompt_file")" "" 1 || true

# 3. Extract + validate + publish (or record the failure).
status="failed"
report_json="$run_dir/report.json"
validation_log="$run_dir/report.validation.log"
if [[ "$timed_out" == "yes" ]]; then
  supervisor_fail "timeout" "supervisor briefing timed out after ${timeout_sec}s"
elif [[ -f "$raw" ]] && singular_extract_json "$raw" "$report_json" 2>>"$log"; then
  if singular_validate_supervisor_report "$report_json" >"$validation_log" 2>&1; then
    # Publish: enrich with generatedAt + runId, then atomically replace latest.json
    # and drop a history snapshot pruned to the newest 20.
    if python3 - "$report_json" "$sup_dir" "$run_id" <<'PY'
import json, os, sys
from datetime import datetime, timezone

report_path, sup_dir, run_id = sys.argv[1:4]
with open(report_path, "r", encoding="utf-8") as f:
    report = json.load(f)
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
report["generatedAt"] = now
report["runId"] = run_id
text = json.dumps(report, indent=2) + "\n"

latest = os.path.join(sup_dir, "latest.json")
tmp = latest + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(text)
os.replace(tmp, latest)

history_dir = os.path.join(sup_dir, "history")
os.makedirs(history_dir, exist_ok=True)
stamp = now.replace(":", "").replace("-", "")
hist = os.path.join(history_dir, stamp + ".json")
with open(hist, "w", encoding="utf-8") as f:
    f.write(text)

snaps = sorted(n for n in os.listdir(history_dir) if n.endswith(".json"))
for name in snaps[:-20]:
    try:
        os.remove(os.path.join(history_dir, name))
    except OSError:
        pass
PY
    then
      status="ok"
      stage="$(singular_json_field "$report_json" stage 2>/dev/null || echo "")"
      singular_append_event "supervisor.report" "supervisor briefing published" \
        "$(python3 - "$run_id" "$stage" <<'PY'
import json, sys
run_id, stage = sys.argv[1:3]
print(json.dumps({"runId": run_id, "stage": stage[:200]}, separators=(",", ":")))
PY
)"
    else
      supervisor_fail "publish-error" "supervisor report could not be published"
    fi
  else
    supervisor_fail "invalid" "supervisor report failed schema validation"
  fi
else
  supervisor_fail "unparseable" "supervisor produced no parseable report"
fi

echo "runId=$run_id"
echo "status=$status"
