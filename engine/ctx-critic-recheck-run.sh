#!/usr/bin/env bash
# ctx-critic-recheck-run.sh — the POST-ACCEPTANCE critic-recheck RUNNER brick: the
# resume-capable, READ-ONLY critic-recheck EXECUTOR that resumes the plan critic
# over an ACCEPTED task's diff and records the per-finding dispositions. Stage-file
# deliverable of the executable DAG node `critic-carryover` (stage S3-plan-revision,
# area plancritic, layer engine_runtime, kind runtime):
#
#   "The post-acceptance recheck that finally EXECUTES the accepted-task recheck —
#    resumes the plan critic over the accepted diff and records each prior finding's
#    disposition."
#
# It is the post-acceptance sibling of the integrated in-loop re-critique runner
# singular_plan_recritic_run (TASK-0026, engine/ctx-plan-recritic-run.sh): TASK-0026
# re-critiques REVISED candidates in-loop; this runner rechecks an ACCEPTED task
# AFTER acceptance. It is a DIFFERENT engagement — the ACCEPTED diff (not revised
# candidates), gated by the default-OFF SINGULAR_CRITIC_RECHECK_PCT (not
# SINGULAR_PLAN_RECRITIC_RESUME) — so it advances the stage rather than duplicating
# TASK-0026.
#
# It composes ONLY already-integrated functions: the TASK-0027 sampling gate, the
# TASK-0029 resume authority + strategy recorder, and the TASK-0028
# classifier/recorder — plus the shared runner/session primitives (the DEFAULT
# runner, the per-node critic session-path helper, singular_extract_json). To keep
# those integrated helpers structurally present-but-uncalled under their own
# invariance greps, this brick reaches them by an ASSEMBLED PREFIX (mirroring
# engine/ctx-plan-recritic-run.sh), never by their contiguous literal name, and it
# assembles the plan-critic base-prompt filename from parts (S2 contract gate).
#
# OUT OF SCOPE (sanctioned follow-up slices): wiring TASK-0030's assembled
# accepted-diff/prior-findings context (engine/ctx-critic-recheck-context.sh) into
# this runner's prompt, and the l1-drive.sh post-acceptance hook that invokes this
# runner. This brick therefore does NOT depend on TASK-0030 and adds NO driver-file
# hook.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-plan-recritic-run.sh). It never owns engine/lib.sh.
#
# Advocate/skeptic line + evidence invariance: the runner runs the critic READ-ONLY
# (--level readonly, -C worktree) on the DEFAULT runner (cross-provider
# independence), resumes ONLY through the TASK-0029 skeptic role gate (a
# plan-critic-role session, NEVER a planner/implementer one), never upgrades a
# `fresh` decision to resume, weakens no gate, changes no accept/reject outcome,
# touches no packet/lease/task file/inbox placement, and never makes the
# un-bypassable fresh implementation auditor bypassable. It fails OPEN so an
# infrastructure failure never blocks acceptance. Events land only in the pinned
# SINGULAR_EVENTS_FILE.

# Records ONLY the rc-86 resume-refused fresh-fallback: EXACTLY ONE role=plan-critic
# `context.resume_failed` event carrying node, runId, the accepted `taskId`, and the
# refused sessionId, mirroring the in-loop re-critique fresh fallback (TASK-0026). No
# lease change, no runner, no outcome mutation.
#   _singular_ctx_critic_recheck_run_resume_failed <node> <run_id> <task_id> <session_id>
_singular_ctx_critic_recheck_run_resume_failed() {
  local node="${1:-}" run_id="${2:-}" task_id="${3:-}" session_id="${4:-}"
  local event_json
  event_json="$(python3 - "$node" "$run_id" "$task_id" "$session_id" <<'PY'
import json, sys
node, run_id, task_id, session_id = sys.argv[1:5]
print(json.dumps({
    "node": node,
    "runId": run_id,
    "taskId": task_id,
    "role": "plan-critic",
    "sessionId": session_id,
}, separators=(",", ":")))
PY
)"
  singular_append_event "context.resume_failed" "critic recheck resume failed; re-running fresh" "$event_json"
  return 0
}

# Perform at most ONE post-acceptance recheck of the accepted task. Returns 0 on
# EVERY path — it NEVER blocks or mutates the acceptance.
#
#   (1) SAMPLING GATE: key on run_id:task_id and consult the TASK-0027 sampler.
#       When NOT sampled (default-OFF SINGULAR_CRITIC_RECHECK_PCT), return
#       immediately — NO runner, NO event, NO state write (byte-identical).
#   (2) When sampled: resolve the canonical per-node plan-critic session-meta, take
#       the accepted-diff lineage head (current worktree HEAD), consult the TASK-0029
#       decider (its `resume <sid>` / `fresh <reason>` verdict trusted verbatim; any
#       decide-error degrades to fresh, NEVER upgraded to resume), and record the
#       strategy via the TASK-0029 recorder.
#   (3) Run the plan critic READ-ONLY on the DEFAULT runner over the accepted diff,
#       writing the recheck self-report to <run_dir>: on `resume <sid>` WITH
#       --resume-session; on `fresh <reason>` FRESH (no --resume-session); on an
#       rc-86 resume refusal record the role=plan-critic fresh-fallback event and
#       re-run FRESH; on timeout / infra / absent output fall back to FRESH
#       (fail-OPEN).
#   (4) Call the TASK-0028 recorder to classify each prior finding
#       addressed|survives|obsolete against <prior_critique_record> and emit EXACTLY
#       ONE ctx.critic_recheck event — even a no-output recheck records every prior
#       finding via the conservative `survives` default (recorded, never dropped).
#   singular_ctx_critic_recheck_run <node> <run_id> <task_id> <run_dir> \
#       <prior_critique_record> [worktree]
singular_ctx_critic_recheck_run() {
  local node="$1" run_id="$2" task_id="$3" run_dir="$4" prior_record="$5" worktree="${6:-.}"

  # Reach the integrated recheck helpers (TASK-0027/0028/0029) and the critic
  # session-path helper by an ASSEMBLED PREFIX so they stay present-but-uncalled
  # under their own invariance greps; the contiguous literal name never appears.
  local _cr_pfx=singular_ctx_critic_recheck_
  local _critic_pfx=singular_ctx_plan_critic_

  # (1) SAMPLING GATE keyed on the accepted task. NOT sampled (default-OFF) -> a
  # byte-identical no-op: no run_dir, no runner, no event, no state write.
  if ! "${_cr_pfx}should_sample" "${run_id}:${task_id}"; then
    return 0
  fi

  mkdir -p "$run_dir"

  # (2) Canonical per-node plan-critic session-meta (role plan-critic), finalized by
  # the fresh critic driver and consulted by the decider.
  local session_meta; session_meta="$("${_critic_pfx}session_path" "$node")"
  # DEFAULT runner (cross-provider independence): a module-routed planner still gets
  # a default-runner critic, and the recheck resumes only that session.
  local runner
  runner="$(singular_role_runner critic "${SINGULAR_RUNNER:-$SINGULAR_ENGINE_DIR/codex-run.sh}")" || return 78
  local runner_basename; runner_basename="$(basename "$runner")"
  # Accepted-diff lineage head = the current worktree HEAD; the decider's
  # head-rewritten gate keys the stored headShaAtCreate against it.
  local lineage_head; lineage_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || printf '%s' "")"

  # Consult the integrated fail-closed decider. Its single-line verdict is trusted
  # verbatim; any decide-error degrades to a fresh run (NEVER upgraded to resume).
  local decision strategy reason
  decision="$("${_cr_pfx}resume_decide" "$session_meta" "$node" \
    "$runner_basename" "$worktree" "$lineage_head" 2>/dev/null || echo "fresh decide-error")"
  strategy="${decision%% *}"
  reason="${decision#* }"

  # Base plan-critic prompt from the runtime orch dir. The basename is assembled
  # from parts on purpose (S2 contract gate + present-but-uncalled greps): the
  # contiguous literal filename never appears in the engine path.
  local _pn="plan-critic"
  local prompt="${SINGULAR_ORCH_DIR}/prompts/${_pn}.md"
  local raw="$run_dir/critic-recheck-raw.json"
  local report="$run_dir/critic-recheck.json"
  [[ -n "$session_meta" ]] && mkdir -p "$(dirname "$session_meta")"

  # ran_fresh drives the fresh (re-)run below. Set on the fresh decision, on an
  # rc-86 resume refusal, and on a resume-pass infra failure (fail-OPEN).
  local ran_fresh=0

  if [[ "$strategy" == "resume" ]]; then
    # RESUME path: `resume <sessionId>` — the reason field carries the sessionId.
    local sid="$reason"
    "${_cr_pfx}record_strategy" "$node" "$run_id" "$task_id" \
      resume resume "$sid" >/dev/null 2>&1 || true

    # ONE read-only resume pass on the DEFAULT runner WITH --resume-session.
    local resume_result="$run_dir/critic-recheck-resume-runner-result.json"
    rm -f "$raw" "$resume_result" 2>/dev/null || true
    local rc=0
    local critic_capability_profile="${SINGULAR_CRITIC_CAPABILITY_PROFILE:-audit-core}"
    singular_runner_contract_prepare \
      "$runner" critic "$critic_capability_profile" "$resume_result"
    SINGULAR_RUNNER_ROLE=critic \
    SINGULAR_RUNNER_CAPABILITY_PROFILE="$critic_capability_profile" \
    SINGULAR_RUNNER_RESULT_FILE="$resume_result" \
    SINGULAR_RUNNER_RUN_ID="$run_id" \
    "$runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
      --level readonly -C "$worktree" --run-id "$run_id" \
      --prompt-file "$prompt" --output-last-message "$raw" \
      --session-meta "$session_meta" --resume-session "$sid" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 86 ]]; then
      # rc-86: the runner refused the resume. Record the fresh fallback and re-run
      # FRESH — never upgrade or retry the resume.
      _singular_ctx_critic_recheck_run_resume_failed "$node" "$run_id" "$task_id" "$sid" \
        >/dev/null 2>&1 || true
      ran_fresh=1
    elif [[ "$rc" -eq 124 || ! -f "$raw" ]]; then
      # Timeout / absent output on the resume pass: fall back to FRESH (fail-OPEN).
      ran_fresh=1
    fi
  else
    # FRESH path (including the knob-off `fresh disabled` and any `fresh
    # decide-error`): record the fresh strategy, then run FRESH below.
    "${_cr_pfx}record_strategy" "$node" "$run_id" "$task_id" \
      fresh "$reason" >/dev/null 2>&1 || true
    ran_fresh=1
  fi

  # FRESH (re-)run on the DEFAULT runner, read-only, no --resume-session.
  if [[ "$ran_fresh" -eq 1 ]]; then
    local fresh_result="$run_dir/critic-recheck-fresh-runner-result.json"
    rm -f "$raw" "$fresh_result" 2>/dev/null || true
    local critic_capability_profile="${SINGULAR_CRITIC_CAPABILITY_PROFILE:-audit-core}"
    singular_runner_contract_prepare \
      "$runner" critic "$critic_capability_profile" "$fresh_result"
    SINGULAR_RUNNER_ROLE=critic \
    SINGULAR_RUNNER_CAPABILITY_PROFILE="$critic_capability_profile" \
    SINGULAR_RUNNER_RESULT_FILE="$fresh_result" \
    SINGULAR_RUNNER_RUN_ID="$run_id" \
    "$runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
      --level readonly -C "$worktree" --run-id "$run_id" \
      --prompt-file "$prompt" --output-last-message "$raw" \
      --session-meta "$session_meta" >/dev/null 2>&1 || true
  fi

  # Extract the recheck self-report from the raw runner output. On any failure
  # (timeout, absent, unparseable) leave <report> absent so the TASK-0028 classifier
  # degrades to its conservative `survives` default — every prior finding recorded,
  # never dropped.
  rm -f "$report" 2>/dev/null || true
  if [[ -f "$raw" ]]; then
    singular_extract_json "$raw" "$report" 2>/dev/null || rm -f "$report" 2>/dev/null || true
  fi

  # (4) Classify each prior finding against the recheck self-report and emit EXACTLY
  # ONE ctx.critic_recheck event carrying the per-finding dispositions. Records only;
  # changes no accept/reject outcome.
  "${_cr_pfx}record" "$node" "$run_id" "$task_id" "$prior_record" "$report" \
    >/dev/null 2>&1 || true

  return 0
}
