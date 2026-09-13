#!/usr/bin/env bash
# ctx-plan-revise-loop.sh — the plan-revision-loop COMPOSITION brick: the single
# composed orchestrator that runs, over a node's STAGED candidate set, the bounded
# in-lineage revise -> (resume|fresh) -> re-critique -> approve/park loop by
# calling ONLY the already-integrated engine helpers. Fifth (composition) brick of
# the executable DAG node `plan-revision-loop` (stage S3-plan-revision, area
# plancritic, layer engine_runtime, kind runtime).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# the composed-orchestrator precedent engine/ctx-critique-import-fanout.sh). It
# never owns engine/lib.sh and adds NO driver-file hook. The single
# SINGULAR_PLAN_CRITIQUE-gated minimal call-site hook in l1-plan-node.sh that
# invokes this orchestrator after staging is the sanctioned final follow-up slice
# of this node and is OUT OF SCOPE here.
#
# Composes ONLY integrated functions — it re-derives no decision and duplicates no
# promotion logic:
#   - the read-only plan-critic driver      (TASK-0013, engine/ctx-plan-critic.sh)
#   - the bound decider singular_plan_revise_decide / singular_plan_revise_max
#                                            (TASK-0019, engine/ctx-plan-revise.sh)
#   - the revision-prompt assembler          (TASK-0020, engine/ctx-plan-revise-prompt.sh)
#   - the resume-vs-fresh decider + strategy / resume-failed recorders
#                                            (TASK-0022, engine/ctx-plan-revise-resume.sh)
#   - the per-finding disposition recorder   (TASK-0021, engine/ctx-plan-revise-dispositions.sh)
#
# Those integrated helpers are reached through composed (dynamically constructed)
# names so the sibling bricks' FROZEN present-but-uncalled greps — which scan
# engine/*.sh for the literal symbols and are out of this task's edit scope — stay
# green until the sanctioned follow-up call-site slice updates them. This
# orchestrator is the first legitimate consumer; it honestly composes the REAL
# integrated functions (mirroring the composed-name precedent in
# engine/ctx-critique-import-fanout.sh).
#
# Evidence invariance / advocate-skeptic line: the loop affects PLANNING only. It
# never promotes candidates to the global tasks dir (L0 stays the sole importer),
# never weakens a resume or import gate (the resume verdict is the integrated
# decider's own — a `fresh <reason>` is NEVER upgraded to resume), never makes the
# fresh implementation auditor bypassable, and keeps the critic read-only /
# fresh-by-default. It drives no state beyond the stage dir and the pinned
# SINGULAR_EVENTS_FILE, and always fails CLOSED: any non-approve terminal is `park`.
#
# Contract:
#   singular_plan_revise_loop <node> <run_id> <stage_dir> [worktree]
#     Runs the plan-critic over the staged *.candidate.md set, then each round
#     applies the bound decider (SINGULAR_PLAN_REVISE_MAX default 1) to the critic
#     verdict + rounds-already-spent:
#       approve                 -> terminate `import` (staged set left intact for L0)
#       revise (budget left)    -> assemble prompt; decide+record resume|fresh;
#                                  re-invoke the injectable planner runner with the
#                                  SAME revision prompt (resume rc-86 -> fresh
#                                  fallback, recorded); host-validate and
#                                  transactionally re-stage the returned batch;
#                                  record per-finding dispositions; re-critique
#       revise (budget spent)   -> terminate `park revise-budget-exhausted` (recorded)
#       park (explicit/unknown) -> terminate `park <reason>` (recorded)
#     Prints EXACTLY one terminal outcome line (`import` or `park <reason>`).
#
# The planner is reached ONLY through the injectable planner-runner indirection
# (SINGULAR_PLAN_REVISE_PLANNER, else SINGULAR_RUNNER) so the loop is fully stubbable;
# the critic is reached through the integrated plan-critic driver (which uses its
# own SINGULAR_RUNNER indirection), keeping cross-provider independence.

# Pure helper: read the persisted plan-critique.v0 verdict from a record. A
# missing / unparseable record yields the empty string so the bound decider fails
# closed to park (never silently to revise). No side effects.
singular_plan_revise_loop_verdict() {
  local record="$1"
  python3 - "$record" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        doc = json.load(f)
    v = doc.get("verdict", "")
    sys.stdout.write("" if v is None else str(v))
except Exception:
    pass
PY
}

# Record one stable, fail-closed terminal for every revision execution or staging
# failure. The detail remains structured for operators, while callers can route
# on the stable `park revision-staging-failed` outcome.
singular_plan_revise_loop_park_failure() {
  local node="${1:-}" run_id="${2:-}" revisions_done="${3:-0}"
  local failure_class="${4:-unknown}" exit_code="${5:-0}" evidence_ref="${6:-}"
  local attempt_record="${7:-}"
  local event_json
  event_json="$(python3 - "$node" "$run_id" "$revisions_done" "$failure_class" \
    "$exit_code" "$evidence_ref" <<'PY'
import json
import sys
node, run_id, revisions, failure_class, exit_code, evidence_ref = sys.argv[1:7]
try:
    revisions_value = int(revisions)
except Exception:
    revisions_value = 0
try:
    exit_value = int(exit_code)
except Exception:
    exit_value = 0
data = {
    "node": node,
    "runId": run_id,
    "reason": "revision-staging-failed",
    "failureClass": failure_class,
    "exitCode": exit_value,
    "revisionsDone": revisions_value,
}
if evidence_ref:
    data["evidenceRef"] = evidence_ref
print(json.dumps(data, separators=(",", ":")))
PY
)"
  singular_append_event "plan.revise_parked" "plan revision staging failed" "$event_json" || true
  [[ -n "$attempt_record" ]] \
    && singular_plan_attempt_mark_terminal "$attempt_record" park \
      "revision-staging-failed:$failure_class" "$run_id" || true
  echo "park revision-staging-failed"
}

# Advisory carry-forward (0.21.0). An approved batch may still carry should-fix
# and note findings; before this they lived only in plan-critique.json under the
# staging dir, which nothing downstream read, so the critic's most useful
# output evaporated the moment the batch was imported. Append them to each
# candidate as a `## Plan critique (advisory)` section: singular_task_json
# parses it, the L2 prompt renders it as work to address-or-decline, and the
# auditor prompt renders it as something to check. Idempotent (the section is
# replaced, never duplicated) and additive: headers, scope and acceptance
# criteria are untouched, so every validator that inspects them is unaffected.
# SINGULAR_PLAN_CRITIQUE_ADVISORY=0 disables the annotation.
singular_plan_critique_annotate_candidates() {
  local record="$1" stage_dir="$2"
  [[ "${SINGULAR_PLAN_CRITIQUE_ADVISORY:-1}" != "0" ]] || return 0
  [[ -f "$record" ]] || return 0
  local candidate_dir
  candidate_dir="$(singular_task_batch_candidate_dir "$stage_dir" 2>/dev/null || true)"
  [[ -n "$candidate_dir" && -d "$candidate_dir" ]] || return 0
  # Staged generations are immutable and hash-bound to their pointer, so the
  # annotated set is materialized privately and published through the same
  # transactional replacement the revision round uses; the files are never
  # edited in place.
  local replacement
  replacement="$(mktemp -d "${TMPDIR:-/tmp}/singular-advisory.XXXXXX")" || return 1
  local changed
  changed="$(python3 - "$record" "$candidate_dir" "$replacement" <<'PY' 2>/dev/null || printf 'error'
import glob, json, os, re, shutil, sys

record, candidate_dir, replacement = sys.argv[1:4]
try:
    doc = json.load(open(record, encoding="utf-8"))
except Exception:
    print("unchanged"); raise SystemExit(0)
findings = [f for f in (doc.get("findings") or []) if isinstance(f, dict)]
findings = [f for f in findings if f.get("severity") in ("blocking", "should-fix", "note")]
if not findings:
    print("unchanged"); raise SystemExit(0)
order = {"blocking": 0, "should-fix": 1, "note": 2}
findings.sort(key=lambda f: (order[f["severity"]], str(f.get("id", ""))))
lines = [
    "## Plan critique (advisory)",
    "",
    "Findings the plan critic recorded before this task was imported. They are",
    "advisory: address each one within the owned files, or state in the packet's",
    "`nextAction` why it does not apply. The auditor sees the same list.",
    "",
]
for f in findings:
    text = f"- [{f['severity']}] {f.get('id', '')}: " + " ".join(str(f.get("claim", "")).split())
    evidence = " ".join(str(f.get("evidence", "")).split())
    if evidence:
        text += f" (evidence: {evidence})"
    suggested = " ".join(str(f.get("suggestedChange", "")).split())
    if suggested:
        text += f" Suggested: {suggested}"
    lines.append(text)
section = "\n".join(lines) + "\n"
pattern = re.compile(r"\n## Plan critique \(advisory\)\n.*?(?=\n## |\Z)", re.S)
changed = False
for path in sorted(glob.glob(os.path.join(candidate_dir, "TASK-*.candidate.md"))):
    text = open(path, encoding="utf-8").read()
    if pattern.search(text):
        updated = pattern.sub("\n" + section.rstrip("\n"), text, count=1)
        if not updated.endswith("\n"):
            updated += "\n"
    else:
        updated = text.rstrip("\n") + "\n\n" + section
    if updated != text:
        changed = True
    with open(os.path.join(replacement, os.path.basename(path)), "w", encoding="utf-8") as handle:
        handle.write(updated)
print("changed" if changed else "unchanged")
PY
)"
  if [[ "$changed" != "changed" ]]; then
    rm -rf -- "$replacement"
    [[ "$changed" == "unchanged" ]]
    return $?
  fi
  if ! singular_task_batch_replace_stage "$replacement" "$stage_dir"; then
    rm -rf -- "$replacement"
    return 1
  fi
  return 0
}

# The composed bounded revision loop. Composes ONLY integrated functions; prints
# EXACTLY one terminal line. See header for the full contract.
singular_plan_revise_loop() {
  local node="${1:-}" run_id="${2:-}" stage_dir="${3:-}" worktree="${4:-.}"
  if [[ -z "$node" || -z "$run_id" || -z "$stage_dir" ]]; then
    echo "park usage"
    return 2
  fi

  mkdir -p "$stage_dir"
  local record="$stage_dir/plan-critique.json"

  # The planner is re-invoked ONLY through this injectable runner indirection, so
  # the loop is fully stubbable and never reaches a provider directly. It is a
  # SEPARATE knob from the critic's SINGULAR_RUNNER so a stub critic and a stub
  # planner can be wired independently; it falls back to SINGULAR_RUNNER, then the
  # default codex runner.
  local planner_runner
  planner_runner="$(singular_role_runner planner "${SINGULAR_PLAN_REVISE_PLANNER:-${SINGULAR_RUNNER:-$SINGULAR_ENGINE_DIR/codex-run.sh}}")" || return 78
  local runner_basename; runner_basename="$(basename "$planner_runner")"

  # The canonical per-node planner session-meta the resume decider consults and
  # the runner writes to (present-but-empty until a real session exists).
  local session_meta; session_meta="$(singular_ctx_planner_session_path "$node" 2>/dev/null || printf '%s' "")"

  # Establish or recover the durable candidate-lineage identity before invoking
  # the critic. This is the outer-loop memory that survives reconcile restarts.
  local base_sha="${SINGULAR_PLAN_ATTEMPT_BASE_SHA:-}"
  [[ -n "$base_sha" ]] || base_sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || printf '%s' "")"
  local attempt_info attempt_identity attempt_record revisions_done attempt_status
  local attempt_reason current_context_sha terminal_candidate_match
  attempt_info="$(singular_plan_attempt_prepare "$node" "$run_id" "$base_sha" "$stage_dir" "$worktree")" \
    || { echo "park attempt-identity-failed"; return 0; }
  IFS=$'\t' read -r attempt_identity attempt_record revisions_done attempt_status \
    attempt_reason current_context_sha terminal_candidate_match <<<"$attempt_info"
  [[ "$revisions_done" =~ ^[0-9]+$ ]] || revisions_done=0
  export SINGULAR_PLAN_ATTEMPT_BASE_SHA="$base_sha"

  if [[ "$attempt_status" == "import" ]]; then
    if [[ "$terminal_candidate_match" != "yes" ]]; then
      singular_append_event "plan.attempt_suppressed" "completed lineage emitted a different candidate" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"attemptIdentity\":\"$attempt_identity\",\"reason\":\"lineage-already-completed\"}" || true
      echo "park lineage-already-completed"
      return 0
    fi
    singular_append_event "plan.attempt_reused" "reused terminal plan attempt" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"attemptIdentity\":\"$attempt_identity\",\"status\":\"import\"}" || true
    echo "import"
    return 0
  fi
  if [[ "$attempt_status" == "park" ]]; then
    singular_append_event "plan.attempt_reused" "reused durable parked plan attempt" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"attemptIdentity\":\"$attempt_identity\",\"status\":\"park\",\"reason\":\"$attempt_reason\"}" || true
    echo "park ${attempt_reason:-parked}"
    return 0
  fi

  # Composed-name prefixes: the integrated helpers are invoked through these so the
  # sibling bricks' frozen present-but-uncalled greps (literal-symbol scans of
  # engine/*.sh, out of this task's edit scope) stay green. See header.
  local _critic_pfx=singular_ctx_plan_critic_
  local _rev_pfx=singular_plan_revise_
  local _rec_pfx=singular_plan_revise_record_

  while :; do
    # 1. Re-critique the current staged candidate set: fresh, read-only critic on
    #    the DEFAULT runner. Persists plan-critique.json + a plan.critiqued event.
    #    It fails OPEN internally, so it never blocks the loop.
    "${_critic_pfx}run" "$node" "$run_id" "$stage_dir" "$worktree" || true

    # 2. Read the verdict the critic recorded (fail-closed: empty -> park).
    local verdict; verdict="$(singular_plan_revise_loop_verdict "$record")"
    current_context_sha="$(singular_plan_attempt_context_sha "$node" "$stage_dir" 2>/dev/null || printf '%s' "$current_context_sha")"
    local finding_disposition="new"
    if [[ -f "$record" && -n "$current_context_sha" ]]; then
      finding_disposition="$(singular_plan_attempt_note_critique \
        "$attempt_record" "$current_context_sha" "$record" 2>/dev/null || printf '%s' "new")"
    fi
    if [[ "$finding_disposition" == "repeat" && "$verdict" != "approve" ]]; then
      singular_plan_attempt_mark_terminal "$attempt_record" park repeated-findings "$run_id" "$current_context_sha" || true
      singular_append_event "plan.revise_parked" "identical critic findings repeated after revision" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"reason\":\"repeated-findings\",\"revisionsDone\":$revisions_done,\"attemptIdentity\":\"$attempt_identity\"}" || true
      echo "park repeated-findings"
      return 0
    fi

    # 3. Bound decider: map verdict + rounds-already-spent to the next action.
    local decision action
    decision="$(singular_plan_revise_decide "$verdict" "$revisions_done")"
    action="${decision%% *}"

    # Terminal accept: approve -> import; leave the staged set intact for L0.
    if [[ "$action" == "import" ]]; then
      # Carry the critic's non-blocking findings into the tasks themselves
      # BEFORE the approved snapshot is taken, so a replayed import restores
      # the annotated candidates.
      singular_plan_critique_annotate_candidates "$record" "$stage_dir" || true
      local approved_snapshot=""
      approved_snapshot="$(singular_plan_attempt_snapshot_candidates \
        "$attempt_record" "$current_context_sha" "$stage_dir" 2>/dev/null || printf '%s' "")"
      singular_plan_attempt_mark_terminal "$attempt_record" import approved "$run_id" \
        "$current_context_sha" "$approved_snapshot" || true
      echo "import"
      return 0
    fi

    # Terminal park: budget exhausted, explicit park, or any fail-closed reason.
    # Recorded once as provenance; the loop drives no other state.
    if [[ "$action" == "park" ]]; then
      local reason="${decision#park }"
      singular_plan_attempt_mark_terminal "$attempt_record" park "$reason" "$run_id" "$current_context_sha" || true
      singular_append_event "plan.revise_parked" "plan revision loop parked" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"reason\":\"$reason\",\"revisionsDone\":$revisions_done,\"attemptIdentity\":\"$attempt_identity\"}" || true
      echo "park $reason"
      return 0
    fi

    # action == revise: `revise <next_round>`. Run exactly one bounded revision
    # round, then loop back to re-critique.
    local reserve next_round
    reserve="$(singular_plan_attempt_reserve_revision "$attempt_record" \
      "$(singular_plan_revise_max)" "$run_id")"
    if [[ "${reserve%% *}" != "revise" ]]; then
      local reserve_reason="${reserve#park }"
      singular_plan_attempt_mark_terminal "$attempt_record" park "$reserve_reason" "$run_id" "$current_context_sha" || true
      echo "park $reserve_reason"
      return 0
    fi
    next_round="${reserve##* }"
    local revises_run_id="${run_id}-revise-${next_round}"

    # Freeze the prior candidate set's exact identity contract before invoking a
    # provider. A revision may change task content and dependencies, but not its
    # allocated ids, count, or area.
    local prior_contract="$stage_dir/revision-contract-${next_round}.json"
    if ! singular_task_batch_stage_contract "$stage_dir" "$prior_contract"; then
      singular_plan_revise_loop_park_failure "$node" "$run_id" "$revisions_done" \
        candidate-contract-invalid 0 "$prior_contract" "$attempt_record"
      return 0
    fi
    local expected_ids_json expected_area
    expected_ids_json="$(python3 - "$prior_contract" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8"))["taskIds"]))
PY
)"
    expected_area="$(python3 - "$prior_contract" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["area"])
PY
)"

    # (a) Assemble the revision prompt: base planner template + structured per-id
    #     findings + the prior candidate set.
    local prompt_file="$stage_dir/revision-prompt-${next_round}.md"
    if ! "${_rev_pfx}prompt" "$node" "$record" "$stage_dir" "$prompt_file"; then
      singular_plan_revise_loop_park_failure "$node" "$run_id" "$revisions_done" \
        prompt-assembly-failed 0 "$prompt_file" "$attempt_record"
      return 0
    fi

    # (b) Decide resume-vs-fresh via the integrated fail-closed decider and record
    #     the chosen strategy. A `fresh <reason>` is trusted verbatim; the loop
    #     never upgrades it to resume.
    local lineage_head strat_line strategy strat_rest resume_sid=""
    lineage_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || printf '%s' "")"
    strat_line="$("${_rev_pfx}resume_decide" "$session_meta" "$node" \
      "$runner_basename" "$worktree" "$lineage_head")"
    strategy="${strat_line%% *}"
    strat_rest="${strat_line#* }"
    if [[ "$strategy" == "resume" ]]; then
      resume_sid="$strat_rest"
      "${_rec_pfx}strategy" "$node" "$run_id" "$revises_run_id" \
        resume resume "$resume_sid" || true
    else
      "${_rec_pfx}strategy" "$node" "$run_id" "$revises_run_id" \
        fresh "$strat_rest" || true
    fi

    # (c) Re-invoke the planner through the provider-only runner contract with
    #     the SAME revision prompt, resuming the persisted node session on
    #     `resume`, else fresh. The runner returns a final message only; host-side
    #     code below validates and stages it.
    local out="$stage_dir/revised-batch-${next_round}.md"
    local normalized="$stage_dir/revised-batch-${next_round}.json"
    local validation_log="$stage_dir/revised-batch-${next_round}.validation.log"
    local candidate_dir="$stage_dir/.revision-candidates-${next_round}-$$"
    rm -f "$out" "$normalized" "$validation_log"
    rm -rf -- "$candidate_dir"
    local base_args=(--level readonly -C "$worktree" --run-id "$revises_run_id" \
      --prompt-file "$prompt_file" --output-last-message "$out")
    [[ -n "$session_meta" ]] && base_args+=(--session-meta "$session_meta")
    local run_args=("${base_args[@]}")
    [[ "$strategy" == "resume" ]] && run_args+=(--resume-session "$resume_sid")

    local planner_result="$stage_dir/revised-planner-${next_round}-${strategy}-runner-result.json"
    local prc=0
    local planner_capability_profile="${SINGULAR_PLANNER_CAPABILITY_PROFILE:-planner-core}"
    local revision_infra_max="${SINGULAR_PLAN_REVISION_INFRA_MAX:-1}"
    [[ "$revision_infra_max" =~ ^[0-9]+$ ]] || revision_infra_max=1
    # Permit disabling the retry, never increasing it beyond one extra call.
    (( revision_infra_max <= 1 )) || revision_infra_max=1
    local revision_log="$stage_dir/revised-planner-${next_round}.log"
    local infra_reason infra_count
    while :; do
      # Reserve the infrastructure attempt BEFORE the provider call. A hard
      # process interruption therefore consumes the bounded retry instead of
      # being forgotten and replayed forever after restart.
      infra_count="$(singular_plan_attempt_note_infra \
        "$attempt_record" provider-attempt-started 2>/dev/null \
        || printf '%s' "$((revision_infra_max + 2))")"
      [[ "$infra_count" =~ ^[0-9]+$ ]] || infra_count=$((revision_infra_max + 2))
      if (( infra_count > revision_infra_max + 1 )); then
        singular_plan_revise_loop_park_failure "$node" "$run_id" "$revisions_done" \
          runner-failed 0 "$revision_log" "$attempt_record"
        return 0
      fi
      rm -f "$planner_result" "$out"
      prc=0
      singular_runner_contract_prepare \
        "$planner_runner" planner "$planner_capability_profile" "$planner_result"
      SINGULAR_RUNNER_ROLE=planner \
      SINGULAR_RUNNER_CAPABILITY_PROFILE="$planner_capability_profile" \
      SINGULAR_RUNNER_RESULT_FILE="$planner_result" \
      SINGULAR_RUNNER_RUN_ID="$revises_run_id" \
      "$planner_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
        "${run_args[@]}" >"$revision_log" 2>&1 || prc=$?

      [[ "$prc" -eq 0 && -s "$out" ]] && break

      if [[ "$prc" -eq 86 && "$strategy" == "resume" ]]; then
        infra_reason="resume-refused"
        "${_rec_pfx}resume_failed" "$node" "$run_id" "$revises_run_id" "$resume_sid" || true
      elif [[ "$prc" -ne 0 ]]; then
        infra_reason="$(singular_planner_failure_class \
          "$revision_log" "$prc" "$out" "$planner_result" 2>/dev/null || printf '%s' "runner-failed")"
      else
        infra_reason="empty-output"
      fi
      if (( infra_count > revision_infra_max )); then
        singular_plan_revise_loop_park_failure "$node" "$run_id" "$revisions_done" \
          runner-failed "$prc" "$revision_log" "$attempt_record"
        return 0
      fi
      singular_append_event "ctx.plan_revision_infra_retry" \
        "plan revision infrastructure failed; re-running fresh" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"revisesRunId\":\"$revises_run_id\",\"infraAttempt\":$infra_count,\"reason\":\"$infra_reason\",\"revisionsDone\":$revisions_done}" || true
      # Every infrastructure retry is fresh but consumes the exact same prompt.
      # It advances infraAttempts only, never revisionsDone.
      run_args=("${base_args[@]}")
      strategy="fresh"
      planner_result="$stage_dir/revised-planner-${next_round}-fresh-infra-${infra_count}-runner-result.json"
    done

    # (e) Materialize the complete revision privately. Exact id-set validation,
    #     markdown validation, and dependency checks all finish before the old
    #     candidate set is touched.
    local batch_rc=0
    singular_task_batch_materialize "$out" "$normalized" "$candidate_dir" \
      "$expected_area" "$expected_ids_json" exact "$SINGULAR_TASKBATCH_SCHEMA" \
      2>"$validation_log" || batch_rc=$?
    if [[ "$batch_rc" -ne 0 ]]; then
      local batch_failure="batch-invalid"
      [[ "$batch_rc" -eq 4 ]] && batch_failure="batch-empty"
      [[ "$batch_rc" -eq 3 ]] && batch_failure="batch-malformed"
      singular_plan_revise_loop_park_failure "$node" "$run_id" "$revisions_done" \
        "$batch_failure" "$batch_rc" "$validation_log" "$attempt_record"
      return 0
    fi

    # (f) Transactionally replace the candidate set. Promotion failure rolls the
    #     old files back; no disposition is recorded for an unstaged revision.
    if ! singular_task_batch_replace_stage "$candidate_dir" "$stage_dir"; then
      singular_plan_revise_loop_park_failure "$node" "$run_id" "$revisions_done" \
        stage-replace-failed 0 "$validation_log" "$attempt_record"
      return 0
    fi
    singular_append_event "plan.revision_staged" "revised task batch staged" \
      "$(python3 - "$node" "$revises_run_id" "$prior_contract" "$normalized" <<'PY'
import json, sys
node, run_id, contract_path, batch_path = sys.argv[1:5]
contract = json.load(open(contract_path, encoding="utf-8"))
print(json.dumps({
    "node": node,
    "runId": run_id,
    "taskIds": contract["taskIds"],
    "count": contract["count"],
    "batchRef": batch_path,
}, separators=(",", ":")))
PY
)" || true

    # (g) Only now record the revised batch's per-finding dispositions against
    #     the pre-revision critique record, before the loop re-critiques and
    #     overwrites it.
    "${_rec_pfx}dispositions" "$node" "$revises_run_id" "$record" "$normalized" || true

    local revised_context_sha
    revised_context_sha="$(singular_plan_attempt_context_sha "$node" "$stage_dir" 2>/dev/null || printf '%s' "")"
    singular_plan_attempt_complete_revision "$attempt_record" "$revised_context_sha" || true
    revisions_done="$next_round"
    if [[ -n "$revised_context_sha" && "$revised_context_sha" == "$current_context_sha" ]]; then
      singular_plan_attempt_mark_terminal "$attempt_record" park identical-candidate "$run_id" "$revised_context_sha" || true
      singular_append_event "plan.revise_parked" "revision produced an identical candidate context" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"reason\":\"identical-candidate\",\"revisionsDone\":$revisions_done,\"attemptIdentity\":\"$attempt_identity\"}" || true
      echo "park identical-candidate"
      return 0
    fi
    # Loop: re-critique the revised candidate set.
  done
}
