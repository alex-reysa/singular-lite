#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "decide.sh requires bash >= 4" >&2; exit 1
fi

# Autonomous Decider invocation. Given a decision point that would otherwise need
# a human, run a read-only Codex decider that returns one action from the
# recovery vocabulary. This script DECIDES + RECORDS; the CALLER executes the
# returned action. It prints `action=<x>` and `verdict=<path>` on stdout.
#
# If the decider cannot be run or returns nothing parseable, it falls back to
# `escalate-parked` (park, never spin).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Decider runner. Defaults to the codex runner; set SINGULAR_RUNNER to a drop-in
# (e.g. claude-run.sh) to dispatch a different CLI under the same contract.
# SINGULAR_ROLE_RUNNER_DECIDER (from config roleRunners.decider) wins when set.
SINGULAR_RUNNER_BIN="$(singular_role_runner decider "${SINGULAR_RUNNER:-$SCRIPT_DIR/codex-run.sh}")" || exit 78

task_id=""
failure_class=""
branch=""
run_id=""
context_file=""
worktree="$SINGULAR_ROOT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task_id="$2"; shift 2 ;;
    --failure-class) failure_class="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --run) run_id="$2"; shift 2 ;;
    --context-file) context_file="$2"; shift 2 ;;
    --worktree) worktree="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$failure_class" ]] || { echo "decide.sh: --failure-class required" >&2; exit 2; }
[[ -n "$run_id" ]] || run_id="$(singular_worker_run_id)"
[[ -d "$worktree" ]] || worktree="$SINGULAR_ROOT"
singular_campaign_verify_or_refuse decide entry || exit 2
decider_campaign_binding="$(singular_campaign_binding)" || exit 2
if [[ -n "${SINGULAR_EXPECTED_CAMPAIGN_BINDING:-}" \
    && "$decider_campaign_binding" != "$SINGULAR_EXPECTED_CAMPAIGN_BINDING" ]]; then
  echo "decide: caller campaign identity is no longer current" >&2
  exit 2
fi
singular_ensure_state_dirs
run_dir="$(singular_run_dir "$run_id")"
mkdir -p "$run_dir"

decider_status_activity="Decision failed for $failure_class"
decider_status_next_action="Inspect the decider evidence"
decider_status_outcome="decision-failed"
decider_campaign_lock_held="no"

singular_decider_status_write() {
  local activity="$1" next_action="$2" process_type="${3:-decider}" process_pid="${4:-$$}"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$run_id" --task-id "${task_id:-}" --phase deciding --state active \
    --activity "$activity" --safe-cancel true --next-action "$next_action" \
    --process-type "$process_type" --pid "$process_pid" >/dev/null 2>&1 || true
}

singular_decider_status_on_exit() {
  local rc=$?
  local state="failed"
  trap - EXIT
  if [[ "$decider_campaign_lock_held" == "yes" ]]; then
    singular_campaign_lock_release 2>/dev/null || true
    decider_campaign_lock_held="no"
  fi
  rm -f "${verdict_candidate:-}" "${verdict_publication_tmp:-}" 2>/dev/null || true
  [[ "$rc" -eq 0 ]] && state="completed"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$run_id" --task-id "${task_id:-}" --phase terminal --state "$state" \
    --activity "$decider_status_activity" --safe-cancel false \
    --next-action "$decider_status_next_action" --process-type decider --pid "$$" \
    --outcome "$decider_status_outcome" >/dev/null 2>&1 || true
  exit "$rc"
}

singular_decider_status_write \
  "Preparing decision for ${task_id:-unscoped} ($failure_class)" \
  "Run the configured decider"
trap singular_decider_status_on_exit EXIT

retry_count="$(singular_lease_field "$task_id" retryCount 2>/dev/null || echo 0)"
max_retries="$(singular_lease_field "$task_id" maxRetries 2>/dev/null || echo "$SINGULAR_MAX_RETRIES")"
[[ -n "$retry_count" ]] || retry_count=0
[[ -n "$max_retries" ]] || max_retries="$SINGULAR_MAX_RETRIES"
[[ "$retry_count" =~ ^[0-9]+$ ]] || retry_count=0
[[ "$max_retries" =~ ^[0-9]+$ ]] || max_retries="$SINGULAR_MAX_RETRIES"
[[ "$max_retries" =~ ^[0-9]+$ ]] || max_retries=0

context_body="(none provided)"
if [[ -n "$context_file" && -f "$context_file" ]]; then
  context_body="$(tail -c 8000 "$context_file")"
fi

# Assemble the decider prompt.
prompt_file="$run_dir/decider-prompt-$failure_class.md"
python3 - "$SINGULAR_ORCH_DIR/prompts/decider.md" "$prompt_file" \
  "$task_id" "$failure_class" "$branch" "$run_id" "$retry_count" "$max_retries" "$context_body" <<'PY'
import sys
tmpl_path, out_path, task_id, fc, branch, run_id, rc, mr, ctx = sys.argv[1:10]
with open(tmpl_path, "r", encoding="utf-8") as f:
    tmpl = f.read().replace("[TASK-ID]", task_id or "(n/a)").replace("[FAILURE CLASS]", fc)
ctx_block = f"""

---

## Context for this decision (authoritative)

- taskId: {task_id or '(n/a)'}
- branch: {branch or '(n/a)'}
- runId: {run_id}
- retries used: {rc} of {mr}

### Failure / findings / logs

```
{ctx}
```

Decide now. Emit ONLY the decider-verdict JSON object.
"""
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl + ctx_block)
PY

verdict="$run_dir/decision-$failure_class.json"
verdict_candidate="$run_dir/.decision-$failure_class.candidate.$$.json"
verdict_publication_tmp="$run_dir/.decision-$failure_class.publication.$$.json"
invalid_verdict="$run_dir/decision-$failure_class.invalid.json"
action="escalate-parked"
rationale="decider unavailable; parked by fallback"
timed_out="no"
decider_timeout_sec="${SINGULAR_DECIDER_TIMEOUT_SEC:-1200}"
if ! [[ "$decider_timeout_sec" =~ ^[0-9]+$ && "$decider_timeout_sec" -gt 0 ]]; then
  decider_timeout_sec=1200
fi

# Was a local recursive-pgrep walk that sent SIGTERM and nothing else, so a
# process that ignored or was slow to handle TERM survived the decider timeout
# indefinitely — and recursive pgrep loses children that reparent mid-walk.
# singular_kill_tree snapshots the tree first and escalates to SIGKILL after the
# grace period, which is also what gives the runner's EXIT trap (and with it the
# read-only restore guard) a chance to run against $SINGULAR_ROOT.
singular_decider_kill_tree() {
  singular_kill_tree "$1" "$(singular_kill_grace_sec)"
}

singular_decider_timeout_action() {
  if [[ "$failure_class" == "audit-needs-fix" && "$retry_count" -lt "$max_retries" ]]; then
    action="retry"
    rationale="readonly decider timed out after ${decider_timeout_sec}s; audit-needs-fix is buildable and retry budget remains (${retry_count}/${max_retries})"
  else
    action="escalate-parked"
    rationale="readonly decider timed out after ${decider_timeout_sec}s; parked by fallback"
  fi
}

decider_event_data() {
  python3 - "$task_id" "$run_id" "$failure_class" "$action" "${1:-}" <<'PY'
import json
import sys
task_id, run_id, failure_class, action, reason = sys.argv[1:6]
data = {"taskId": task_id, "runId": run_id, "failureClass": failure_class, "action": action}
if reason:
    data["reason"] = reason[:500]
print(json.dumps(data, separators=(",", ":")))
PY
}

run_ec=0
# Decider runner output + session-meta are durable (0.6.0): the console
# streams the log as a labeled pane; previously both went to /dev/null.
decider_log="$run_dir/decider-codex.log"
decider_meta="$run_dir/session-decider.json"
decider_result="$run_dir/decider-runner-result.json"
rm -f "$decider_result"
decider_capability_profile="${SINGULAR_DECIDER_CAPABILITY_PROFILE:-decider-core}"
singular_runner_contract_prepare \
  "$SINGULAR_RUNNER_BIN" decider "$decider_capability_profile" "$decider_result"
# `exec` so $! IS the runner script, not a subshell wrapping it. The runner is a
# cooperative citizen — it traps TERM and group-kills its own provider session —
# but only if the TERM actually reaches it; with an intermediate subshell the
# signal landed on a bash that was merely waiting, and the runner's EXIT trap
# (which holds the read-only restore guard) never ran. Deliberately NOT a new
# session: the runner stays in this shell's group so Ctrl-C still reaches it.
(
  export SINGULAR_RUNNER_ROLE=decider
  export SINGULAR_RUNNER_CAPABILITY_PROFILE="$decider_capability_profile"
  export SINGULAR_RUNNER_RESULT_FILE="$decider_result"
  export SINGULAR_RUNNER_RUN_ID="$run_id"
  exec "$SINGULAR_RUNNER_BIN" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
    --level readonly -C "$worktree" \
    --run-id "$run_id" \
    --prompt-file "$prompt_file" \
    --output-last-message "$verdict_candidate" \
    --session-meta "$decider_meta"
) >>"$decider_log" 2>&1 &
decider_pid=$!
singular_decider_status_write \
  "Running the decider for ${task_id:-unscoped} ($failure_class)" \
  "Validate and record the decider verdict" provider-runner "$decider_pid"
deadline=$((SECONDS + decider_timeout_sec))
while kill -0 "$decider_pid" 2>/dev/null; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    timed_out="yes"
    singular_decider_kill_tree "$decider_pid"
    wait "$decider_pid" 2>/dev/null || true
    run_ec=124
    break
  fi
  sleep 1
done
if [[ "$timed_out" != "yes" ]]; then
  wait "$decider_pid" || run_ec=$?
fi
singular_decider_status_write \
  "Validating the decider verdict for ${task_id:-unscoped}" \
  "Persist the selected recovery action"
singular_session_meta_finalize "$decider_meta" "decider" "$task_id" "$run_id" \
  "$(basename "$SINGULAR_RUNNER_BIN")" "$(singular_prompt_sha "$prompt_file")" "" 1 || true

if [[ "$timed_out" == "yes" ]]; then
  singular_decider_timeout_action
  owner="human"; [[ "$action" == "retry" ]] && owner="l1"
  singular_write_decider_verdict "$verdict_candidate" "$task_id" "$failure_class" "$action" "$rationale" "$owner"
  singular_append_event "decider.timeout" "readonly decider timed out" \
    "$(python3 - "$task_id" "$run_id" "$failure_class" "$action" "$decider_timeout_sec" <<'PY'
import json, sys
task_id, run_id, failure_class, action, timeout_sec = sys.argv[1:6]
print(json.dumps({"taskId": task_id, "runId": run_id, "failureClass": failure_class, "timeoutSec": int(timeout_sec), "action": action}, separators=(",", ":")))
PY
)"
elif [[ -f "$verdict_candidate" ]] \
    && singular_extract_json "$verdict_candidate" "$verdict_candidate" 2>/dev/null; then
  validation_log="$run_dir/decision-$failure_class.validation.log"
  if singular_validate_decider_verdict "$verdict_candidate" "$failure_class" "$task_id" >"$validation_log" 2>&1; then
    a="$(singular_json_field "$verdict_candidate" action 2>/dev/null || echo "")"
    r="$(singular_json_field "$verdict_candidate" rationale 2>/dev/null || echo "")"
    if [[ -n "$a" ]]; then action="$a"; fi
    if [[ -n "$r" ]]; then rationale="$r"; fi
  else
    cp "$verdict_candidate" "$invalid_verdict" 2>/dev/null || true
    invalid_reason="$(cat "$validation_log" 2>/dev/null || echo "schema validation failed")"
    action="escalate-parked"
    rationale="invalid decider verdict; parked by fallback: $invalid_reason"
    singular_write_decider_verdict "$verdict_candidate" "$task_id" "$failure_class" "$action" "$rationale" "human"
    singular_append_event "decider.invalid_verdict" "decider verdict failed validation; using fallback" \
      "$(decider_event_data "$invalid_reason")"
  fi
else
  # Decider produced no parseable JSON action (prose-only, refusal, or truncated).
  # Falls back to the escalate-parked default, but record WHY so a prose stall is
  # visible rather than indistinguishable from a deliberate human-park decision.
  [[ -f "$verdict_candidate" ]] && cp "$verdict_candidate" "$invalid_verdict" 2>/dev/null || true
  singular_write_decider_verdict "$verdict_candidate" "$task_id" "$failure_class" "$action" "$rationale" "human"
  singular_append_event "decider.unparseable" "decider produced no parseable JSON action; using fallback" \
    "$(decider_event_data "unparseable")"
fi

# Record the decision durably.
singular_campaign_binding_matches \
  "$decider_campaign_binding" decide pre-decision-publication-checkpoint || exit 2
singular_campaign_lock_acquire || {
  echo "decide: campaign publication lock unavailable" >&2
  exit 75
}
decider_campaign_lock_held="yes"
singular_campaign_publication_cas \
  "$decider_campaign_binding" decide pre-decision-publication || exit 2
python3 - "$verdict_candidate" "$verdict_publication_tmp" \
  "$run_id" "$decider_campaign_binding" <<'PY'
import json
import sys

source, destination, run_id, campaign_binding = sys.argv[1:5]
with open(source, encoding="utf-8") as stream:
    data = json.load(stream)
data["runId"] = run_id
data["campaignBinding"] = campaign_binding
with open(destination, "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
PY
singular_validate_decider_verdict \
  "$verdict_publication_tmp" "$failure_class" "$task_id" >/dev/null
mv "$verdict_publication_tmp" "$verdict"
rm -f "$verdict_candidate"
"$SCRIPT_DIR/record-decision.sh" --task "${task_id:-UNKNOWN}" --decision "decide:$action" \
  --rationale "$failure_class -> $action: $rationale" --run "$run_id" --branch "$branch" \
  --authority decider >/dev/null 2>&1 || true

if [[ "$action" == "escalate-infra" ]]; then
  # Distinct from escalate-parked on purpose: this says the work is fine and the
  # environment is not, which is a different queue for whoever reads it — one
  # needs a human to judge, the other needs a human to fix. Both come back
  # through `singular unpark`.
  singular_append_event "decider.parked_infrastructure" \
    "decision parked on an environment failure, not a product defect" \
    "$(decider_event_data "$rationale")" || true
elif [[ "$action" == "escalate-parked" ]]; then
  singular_append_event "decider.parked" "decision parked for human review" \
    "$(decider_event_data "$rationale")" || true
else
  singular_append_event "decider.verdict" "decider chose an action" \
    "$(decider_event_data)" || true
fi
singular_campaign_lock_release
decider_campaign_lock_held="no"

decider_status_activity="Decision recorded for ${task_id:-unscoped}: $action"
decider_status_next_action="Apply the recorded recovery action"
decider_status_outcome="decision-$action"
echo "verdict=$verdict"
echo "action=$action"
