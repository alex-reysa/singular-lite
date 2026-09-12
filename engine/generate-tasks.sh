#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "generate-tasks.sh requires bash >= 4" >&2; exit 1
fi

# Autonomous task generator (L1 planner). When the ready queue is empty, the
# executable DAG manifest selects the next eligible planning node. The AI planner
# emits the next bounded frontier of strict-test-first task files for that node.
# Completion is published only by authoritative gate-result records, never by
# planner prose or Markdown area state.
#
# Prints one or more generated:TASK-XXXX lines, all-areas-complete, or
# planner-failed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

dry_run="no"
count=1
node_override=""   # plan a SPECIFIC frontier node (parallel-area fanout)
stage_dir=""       # when set, write candidates here (node-local temp ids) — never the global tasks dir
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run="yes"; shift ;;
    --count) count="$2"; shift 2 ;;
    --node) node_override="$2"; shift 2 ;;
    --stage-dir) stage_dir="$2"; shift 2 ;;
    *) echo "usage: $0 [--dry-run] [--count N] [--node NODE] [--stage-dir DIR]" >&2; exit 2 ;;
  esac
done
[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || { echo "--count must be >= 1" >&2; exit 2; }

# Task fatness knob: how many mutually-independent strict-test-first slices the
# planner may fold into one L2 task. Default 1 (byte-identical to prior behavior).
# Clamped to SINGULAR_L2_SLICE_BUDGET_MAX; the per-node layer guardrail below forces 1
# on the configured single-slice layers regardless of this value.
slice_budget="${SINGULAR_L2_SLICE_BUDGET:-1}"
slice_budget_max="${SINGULAR_L2_SLICE_BUDGET_MAX:-3}"
[[ "$slice_budget" =~ ^[0-9]+$ && "$slice_budget" -ge 1 ]] || { echo "SINGULAR_L2_SLICE_BUDGET must be an integer >= 1" >&2; exit 2; }
[[ "$slice_budget_max" =~ ^[0-9]+$ && "$slice_budget_max" -ge 1 ]] || { echo "SINGULAR_L2_SLICE_BUDGET_MAX must be an integer >= 1" >&2; exit 2; }
[[ "$slice_budget" -gt "$slice_budget_max" ]] && slice_budget="$slice_budget_max"

singular_ensure_state_dirs

# Honor the kill switch at the generation entry point, not only in the loop
# wrappers, so a manual invocation cannot generate work while frozen.
if singular_stop_requested; then
  singular_append_event "planner.frozen" "STOP sentinel present; refusing to generate" "{}"
  echo "frozen (STOP sentinel present; $SINGULAR_STOP_FILE)"
  exit 0
fi

singular_require_target_branch

# Planner session-meta lineage anchor: resolve the target-branch head at planning
# time (the head a resumable planner session would be anchored to). Used only by
# the SINGULAR_PLANNER_SESSION finalize hook below (default 1); unused otherwise.
planner_head_sha="$(git -C "$SINGULAR_ROOT" rev-parse "$SINGULAR_TARGET_BRANCH" 2>/dev/null || true)"

# Pick the first eligible ungated DAG node from the manifest and authoritative
# gate-result records.
if [[ -n "$node_override" ]]; then
  # Staged/fanout mode: target a specific, still-eligible frontier node.
  dag_next="$("$SCRIPT_DIR/dag.sh" node-fields "$node_override" 2>&1)" || {
    singular_append_event "planner.failed" "dag node-fields failed" \
      "{\"node\":\"$node_override\",\"runId\":\"\"}"
    echo "planner-failed ($dag_next)"
    exit 1
  }
else
  dag_next="$("$SCRIPT_DIR/dag.sh" next-area 2>&1)" || {
    singular_append_event "planner.failed" "dag frontier selection failed" "$(python3 - "$dag_next" <<'PY'
import json, sys
print(json.dumps({"reason": "dag-frontier", "message": sys.argv[1]}))
PY
)"
    echo "planner-failed ($dag_next)"
    exit 1
  }
  if [[ "$dag_next" == "all-nodes-complete" ]]; then
    echo "all-areas-complete"
    exit 0
  fi
fi
active_node="$(printf '%s\n' "$dag_next" | sed -n 's/^node=//p' | tail -1)"
active_stage="$(printf '%s\n' "$dag_next" | sed -n 's/^stage=//p' | tail -1)"
active_area="$(printf '%s\n' "$dag_next" | sed -n 's/^area=//p' | tail -1)"
active_layer="$(printf '%s\n' "$dag_next" | sed -n 's/^layer=//p' | tail -1)"
active_kind="$(printf '%s\n' "$dag_next" | sed -n 's/^kind=//p' | tail -1)"
active_required="$(printf '%s\n' "$dag_next" | sed -n 's/^requiredCompletion=//p' | tail -1)"
if [[ -z "$active_node" || -z "$active_area" || -z "$active_layer" ]]; then
  singular_append_event "planner.failed" "dag frontier output incomplete" "{\"output\":\"$dag_next\"}"
  echo "planner-failed (dag frontier output incomplete)"
  exit 1
fi

# Layer guardrail: keep configured layers single-slice (SINGULAR_SINGLE_SLICE_LAYERS,
# default "contract"). Promotion is fail-closed, so folding extra slices into such
# a node can only leave its gate un-promotable, never corrupt it; we force a
# single slice to keep those nodes clean. Other layers fatten freely.
effective_slice_budget="$slice_budget"
single_slice_layers="${SINGULAR_SINGLE_SLICE_LAYERS:-contract}"
for _ssl in ${single_slice_layers//,/ }; do
  if [[ "$active_layer" == "$_ssl" ]]; then effective_slice_budget=1; break; fi
done

run_id="${SINGULAR_PLANNING_RUN_ID:-$(singular_worker_run_id)}"
planner_status_activity="Planning failed for $active_node"
planner_status_next_action="Inspect the planner evidence"
planner_status_outcome="planning-failed"

# Status-record identity only; $run_id keeps its meaning everywhere else (events,
# backoff, staging, session correlation). Under L1 fanout every concurrent
# planner inherits the SAME origin id via SINGULAR_PLANNING_RUN_ID, and
# run-status.sh keys its path on the id alone -- so without this the planners
# race on one record and `health` cannot report more than one of them. Matches
# l1-plan-node.sh's derivation, so both layers of a single planner write to one
# record rather than two.
status_run_id="$run_id-l1-$(printf '%s' "$active_node" | tr -c 'A-Za-z0-9._-' '-')"

singular_planner_status_write() {
  local phase="$1" state="$2" activity="$3" safe_cancel="$4" next_action="$5"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$status_run_id" --node "$active_node" --phase "$phase" --state "$state" \
    --activity "$activity" --safe-cancel "$safe_cancel" --next-action "$next_action" \
    --process-type planner --pid "$$" >/dev/null 2>&1 || true
}

singular_planner_status_on_exit() {
  local rc=$?
  local state="failed"
  trap - EXIT
  [[ "$rc" -eq 0 ]] && state="completed"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$status_run_id" --node "$active_node" --phase terminal --state "$state" \
    --activity "$planner_status_activity" --safe-cancel false \
    --next-action "$planner_status_next_action" --process-type planner --pid "$$" \
    --outcome "$planner_status_outcome" >/dev/null 2>&1 || true
  exit "$rc"
}

singular_planner_status_write planning active \
  "Planning tasks for $active_node" true "Validate and stage planner output"
trap singular_planner_status_on_exit EXIT

# Planner suppression (0.5.0, SINGULAR_SUPPRESS_UNPROMOTED_REPLAN=1): a node
# whose tasks are all integrated/satisfied but whose gate is unpublished must
# NOT be re-planned — 0.4.0 kept minting duplicate tasks for such nodes
# (import-rejected each cycle, feeding the false-quota chokepoint) until an
# operator manually promoted. Not a failure: exit 0, distinct event.
if [[ "${SINGULAR_SUPPRESS_UNPROMOTED_REPLAN:-1}" == "1" && -n "$active_node" ]]   && singular_node_pending_promotion "$active_node" 2>/dev/null; then
  singular_append_event "planner.suppressed_pending_promotion"     "node tasks complete; awaiting gate promotion — not re-planning"     "{\"node\":\"$active_node\",\"area\":\"$active_area\",\"runId\":\"$run_id\"}"
  planner_status_activity="Planning suppressed for $active_node; promotion is pending"
  planner_status_next_action="Promote the node gate"
  planner_status_outcome="suppressed-pending-promotion"
  echo "planner-suppressed (pending-promotion node=$active_node)"
  exit 0
fi

backoff_json="$(singular_planner_backoff_active_json 2>/dev/null || true)"
if [[ -n "$backoff_json" ]]; then
  event_json="$(python3 - "$active_node" "$active_area" "$run_id" "$backoff_json" <<'PY'
import json
import sys

node, area, run_id, raw = sys.argv[1:5]
data = json.loads(raw)
data.update({"node": node, "area": area, "runId": run_id})
print(json.dumps(data, separators=(",", ":")))
PY
)"
  singular_append_event "planner.backoff_active" "planner backoff active; refusing to call codex" "$event_json"
  failure_class="$(python3 - "$backoff_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1]).get("failureClass", "unknown"))
PY
)"
  echo "planner-backoff ($failure_class)"
  exit 1
fi

blocked_gate_json=""
if blocked_gate_json="$(singular_blocked_gate_planner_guard_json "$active_node" 2>/dev/null)"; then
  event_json="$(python3 - "$active_node" "$active_area" "$run_id" "$blocked_gate_json" <<'PY'
import json
import sys

node, area, run_id, raw = sys.argv[1:5]
data = json.loads(raw)
data.update({"node": node, "area": area, "runId": run_id})
print(json.dumps(data, separators=(",", ":")))
PY
)"
  singular_append_event "planner.blocked" "blocked gate has unmet task-set evidence; refusing to call codex" "$event_json"
  echo "planner-blocked (closeout-gate)"
  exit 1
fi

# Task ids. In staged mode the ids are node-local temps (TASK-0001..N); the
# real, globally-unique ids are assigned by L0's serial importer, so we
# deliberately do NOT consult the allocator here (that would also race against
# concurrent planners). Non-staged mode reserves real ids from the durable
# monotonic allocator (singular_task_id_next) BEFORE the planner runs — a failed
# planner burns its reserved ids, which is intentional: monotonicity (never
# reusing an archived task's id) is the invariant, not density.
declare -a next_ids=()
if [[ -z "$stage_dir" ]]; then
  while IFS= read -r _id; do
    [[ -n "$_id" ]] && next_ids+=("$_id")
  done < <(singular_task_id_next "$count")
  [[ ${#next_ids[@]} -eq "$count" ]] || { echo "task-id allocation failed" >&2; exit 1; }
else
  for ((i=1; i<=count; i++)); do
    next_ids+=("$(printf 'TASK-%04d' "$i")")
  done
fi
next_id="${next_ids[0]}"
next_ids_csv="$(IFS=,; echo "${next_ids[*]}")"

# Inline task summary for the planner (while-read: paths contain a space).
task_summary="$(
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    tid="$(singular_task_field "$f" taskId 2>/dev/null || echo '?')"
    st="$(singular_task_field "$f" status 2>/dev/null || echo '?')"
    ti="$(singular_task_field "$f" title 2>/dev/null || echo '')"
    echo "- $tid [$st] $ti"
  done < <(find "$SINGULAR_TASKS_DIR" -maxdepth 1 -name 'TASK-*.md' -type f 2>/dev/null | sort)
)"
[[ -n "$task_summary" ]] || task_summary="(none yet)"

# Parallel L1 planners share the parent orchestration run id for lineage, but
# their prompts, provider output, logs, and result sidecars must never share a
# filesystem namespace. l1-plan-node.sh binds this internal directory to the
# node-private staging directory. Direct/serial callers retain the canonical
# per-run directory.
run_dir="${SINGULAR_PLANNING_ARTIFACT_DIR:-$(singular_run_dir "$run_id")}"
mkdir -p "$run_dir"
prompt_file="$run_dir/planner-prompt.md"

# Stack-neutral placeholders (0.21.0). The shipped planner template used to
# hard-code one consumer's toolchain (a Go gate command, `internal/<area>/`
# paths, `_test.go` suffixes), so a fresh `singular init` planned Go tasks for
# every repository until someone rewrote the prompt by hand. The gate command
# and the area's owned paths are facts the config already holds; render them.
area_paths="$(python3 - "${SINGULAR_JSON_CONFIG_FILE:-$SINGULAR_ROOT/singular.config.json}" "$active_area" <<'PY' 2>/dev/null || true
import json, sys
try:
    config = json.load(open(sys.argv[1], encoding="utf-8"))
    paths = (config.get("areas") or {}).get(sys.argv[2], [])
    if isinstance(paths, str):
        paths = [paths] if paths else []
    print(", ".join("`%s`" % p for p in paths if isinstance(p, str) and p))
except Exception:
    print("")
PY
)"
[[ -n "$area_paths" ]] || area_paths="the area's owned paths declared in \`singular.config.json\`"
python3 - "$SINGULAR_ORCH_DIR/prompts/l1-planner.md" "$prompt_file" \
  "$active_area" "$SINGULAR_TARGET_BRANCH" "$next_id" "$next_ids_csv" "$count" "$task_summary" \
  "$active_node" "$active_stage" "$active_layer" "$active_kind" "$active_required" \
  "$effective_slice_budget" "${SINGULAR_DEFAULT_GATE_CMD:-}" "$area_paths" <<'PY'
import sys
(
    tmpl_path,
    out_path,
    area,
    target,
    next_id,
    next_ids,
    count,
    summary,
    node,
    stage,
    layer,
    kind,
    required,
    slice_budget,
    gate_command,
    area_paths,
) = sys.argv[1:17]
with open(tmpl_path) as f:
    t = (
        f.read()
        .replace("[GATE-COMMAND]", gate_command or "(the repository gate command)")
        .replace("[AREA-PATHS]", area_paths)
        .replace("[AREA]", area)
        .replace("[TARGET]", target)
        .replace("[NEXT-ID]", next_id)
        .replace("[NEXT-IDS]", next_ids)
        .replace("[COUNT]", count)
        .replace("[NODE]", node)
        .replace("[STAGE]", stage)
        .replace("[LAYER]", layer)
        .replace("[KIND]", kind)
        .replace("[REQUIRED-COMPLETION]", required)
        .replace("[SLICE-BUDGET]", slice_budget)
    )
t += f"\n\n---\n\n## Executable DAG frontier\n\n- node: `{node}`\n- stage: `{stage}`\n- area: `{area}`\n- layer: `{layer}`\n- kind: `{kind}`\n- required completion: `{required}`\n\n## Existing tasks\n\n{summary}\n"
with open(out_path, "w") as f:
    f.write(t)
PY

echo "planner: node=$active_node stage=$active_stage area=$active_area layer=$active_layer next_ids=$next_ids_csv count=$count slice_budget=$effective_slice_budget"
if [[ "$dry_run" == "yes" ]]; then
  planner_status_activity="Planning dry run completed for $active_node"
  planner_status_next_action="Review the generated planner prompt"
  planner_status_outcome="dry-run"
  echo "DRY RUN — prompt at $prompt_file (no codex, no task writes)"
  exit 0
fi

out="$run_dir/planner-out.md"
codex_log="$run_dir/planner-codex.log"
runner_result="$run_dir/planner-runner-result.json"
codex_runner="${SINGULAR_RUNNER:-${SINGULAR_CODEX_RUNNER:-$SCRIPT_DIR/codex-run.sh}}"
codex_exit=0
# Planner session-meta hook (default ON): when SINGULAR_PLANNER_SESSION=1, offer
# the runner the canonical per-node planner session-meta path — mirroring the
# worker/reviewer --session-meta wiring in l1-drive.sh. With the knob unset/0 no
# --session-meta arg is added, so the invocation is byte-identical to prior.
planner_runner_args=(--level readonly -C "$SINGULAR_ROOT" --run-id "$run_id" \
  --prompt-file "$prompt_file" --output-last-message "$out")
planner_session_meta=""
if [[ "${SINGULAR_PLANNER_SESSION:-0}" == "1" ]]; then
  planner_session_meta="$(singular_ctx_planner_session_path "$active_node")"
  [[ -n "$planner_session_meta" ]] && planner_runner_args+=(--session-meta "$planner_session_meta")
fi

# Planner session-resume consult hook (default ON): when SINGULAR_PLANNER_SESSION=1,
# consult the already-integrated ordered fail-closed decider before invoking the
# runner — mirroring the implementer/reviewer resume path in l1-drive.sh. The
# lineage head is the current target-branch head (planner_head_sha), the same
# anchor the finalize hook records. On `resume <sessionId>` add --resume-session
# and acquire the canonical per-node planner session-lease before the run; on
# `fresh <reason>` invoke without it. Either way emit EXACTLY ONE
# context.strategy_selected event (role "planner") carrying the exact gate reason
# returned by the decider (plus sessionId on resume), so ctx-metrics.sh sees
# planner routing and every gate reason is event-visible. The decider's
# fail-closed verdict is trusted verbatim — a `fresh <reason>` (or any decide
# error) is NEVER upgraded to a resume, so a non-planner session is never resumed
# as the planner. With the knob unset/0 nothing is consulted, no --resume-session
# is added, no strategy event is emitted, and no lease is acquired.
planner_resume_id=""
planner_lease_path=""
planner_transcript=""
planner_strategy="fresh"
planner_strategy_reason="context-routing-disabled"
planner_base_args=("${planner_runner_args[@]}")
if [[ "${SINGULAR_PLANNER_SESSION:-0}" == "1" ]]; then
  # Gate 12 (window-pressure) measures the CANONICAL per-node planner transcript,
  # not this run's $codex_log: a planner session persists across runs, so the
  # current run's log does not exist yet at decide time and would fail the gate
  # closed on every fresh run. The canonical file accumulates across runs and is
  # truncated whenever the decision is fresh (see below).
  planner_transcript="$(singular_ctx_planner_session_transcript_path "$active_node")"
  planner_decision="$(singular_planner_resume_decide "$planner_session_meta" "$active_node" \
    "$(basename "$codex_runner")" "$SINGULAR_ROOT" "$planner_head_sha" "$planner_transcript" 2>/dev/null || echo "fresh decide-error")"
  planner_strategy="${planner_decision%% *}"
  planner_strategy_reason="${planner_decision#* }"
  if [[ "$planner_strategy" == "resume" ]]; then
    planner_resume_id="$planner_strategy_reason"
    planner_runner_args+=(--resume-session "$planner_resume_id")
    # Acquire the canonical planner session-lease before the resume run so a
    # parallel L1 fanout's decider sees `leased` and does not resume concurrently.
    planner_lease_path="$(singular_planner_resume_lease_path "$active_node")"
    if [[ -n "$planner_lease_path" ]]; then
      mkdir -p "$(dirname "$planner_lease_path")"
      printf '{"pid": %s}\n' "$$" >"$planner_lease_path"
    fi
    singular_append_event "context.strategy_selected" "planner session resume strategy selected" \
      "{\"node\":\"$active_node\",\"runId\":\"$run_id\",\"role\":\"planner\",\"strategy\":\"resume\",\"reason\":\"resume\",\"sessionId\":\"$planner_resume_id\"}" || true
  else
    # A fresh planner run starts a NEW session carrying no prior context, so the
    # accumulated transcript resets with it. Without this the file would grow
    # forever and, once past the threshold, permanently pin the planner to fresh.
    if [[ -n "$planner_transcript" ]]; then
      mkdir -p "$(dirname "$planner_transcript")" 2>/dev/null || true
      : >"$planner_transcript" 2>/dev/null || true
    fi
    singular_append_event "context.strategy_selected" "planner fresh-run strategy selected" \
      "{\"node\":\"$active_node\",\"runId\":\"$run_id\",\"role\":\"planner\",\"strategy\":\"fresh\",\"reason\":\"$planner_strategy_reason\"}" || true
  fi
fi

# Shared context is an invocation concern, not a rehydration strategy. Build the
# exact planner prompt from the integrated service for fresh and resumed runs.
# A resumed planner compares against the last node-bound bundle and receives
# changed bytes plus immutable references for unchanged sources.
planner_context_bundle="$run_dir/context-planner.bundle.json"
planner_context_prior=""
if [[ "$planner_strategy" == "resume" ]]; then
  planner_context_prior="$(singular_ctx_planner_context_path "$active_node")"
elif [[ -f "$planner_context_bundle" ]]; then
  planner_context_prior="$planner_context_bundle"
fi
if ! singular_context_invocation_prepare planner plan \
    "$SINGULAR_ORCH_DIR/dag.v0.json" "$prompt_file" \
    "$planner_context_bundle" "$planner_context_prior"; then
  echo "planner-failed (context service invocation assembly failed)"
  exit 1
fi

rm -f "$runner_result"
singular_runner_contract_prepare \
  "$codex_runner" planner planner-core "$runner_result"
SINGULAR_RUNNER_ROLE=planner \
SINGULAR_RUNNER_CAPABILITY_PROFILE=planner-core \
SINGULAR_RUNNER_RESULT_FILE="$runner_result" \
SINGULAR_RUNNER_RUN_ID="$run_id" \
  "$codex_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
    "${planner_runner_args[@]}" >"$codex_log" 2>&1 || codex_exit=$?

# rc-86 in-run fresh fallback: the runner refused the resume. Drop
# --resume-session and re-run the planner FRESH within the SAME run (a pure
# optimization miss; the planning outcome is unchanged), mirroring the worker
# rc-86 fallback in l1-drive.sh.
if [[ "$codex_exit" -eq 86 && -n "$planner_resume_id" ]]; then
  singular_append_event "context.resume_failed" "planner resume failed; re-running fresh" \
    "{\"node\":\"$active_node\",\"runId\":\"$run_id\",\"role\":\"planner\",\"sessionId\":\"$planner_resume_id\"}" || true
  planner_runner_args=("${planner_base_args[@]}")
  codex_exit=0
  rm -f "$runner_result"
  singular_runner_contract_prepare \
    "$codex_runner" planner planner-core "$runner_result"
  SINGULAR_RUNNER_ROLE=planner \
  SINGULAR_RUNNER_CAPABILITY_PROFILE=planner-core \
  SINGULAR_RUNNER_RESULT_FILE="$runner_result" \
  SINGULAR_RUNNER_RUN_ID="$run_id" \
    "$codex_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
      "${planner_runner_args[@]}" >"$codex_log" 2>&1 || codex_exit=$?
fi

# Release the planner session-lease after the run returns — including after an
# rc-86 fresh fallback and on runner error (subsequent failure paths exit below).
if [[ -n "$planner_lease_path" ]]; then
  rm -f "$planner_lease_path"
fi

# Extend the canonical per-node planner transcript with this run's log, so gate 12
# measures what the SESSION has accumulated rather than what one run produced.
# Only on success: a failed run is not a lineage the decider will extend either
# (singular_ctx_planner_session_finalize skips a non-zero rc for the same reason).
# Never fatal — the transcript is a size proxy, not evidence.
if [[ "$codex_exit" -eq 0 && -n "$planner_transcript" && -f "$codex_log" ]]; then
  mkdir -p "$(dirname "$planner_transcript")" 2>/dev/null || true
  cat "$codex_log" >>"$planner_transcript" 2>/dev/null || true
fi
if [[ "$codex_exit" -eq 0 && -f "$planner_context_bundle" ]]; then
  planner_context_session="$(singular_ctx_planner_context_path "$active_node")"
  if [[ -n "$planner_context_session" ]]; then
    mkdir -p "$(dirname "$planner_context_session")" 2>/dev/null || true
    cp "$planner_context_bundle" "$planner_context_session" 2>/dev/null || true
  fi
fi

if [[ "$codex_exit" -ne 0 ]]; then
  failure_class="$(singular_planner_failure_class "$codex_log" "$codex_exit" "$out" "$runner_result")"
  case "$failure_class" in
    quota|provider-overloaded) singular_planner_backoff_set "$failure_class" "$run_id" "$active_node" "$runner_result" ;;
    timeout|codex-exit) singular_planner_backoff_set "$failure_class" "$run_id" "$active_node" "$codex_log" ;;
  esac
  event_json="$(python3 - "$active_node" "$active_area" "$run_id" "$failure_class" "$codex_exit" "$codex_log" "$out" "$runner_result" <<'PY'
import json
import sys

node, area, run_id, failure_class, exit_code, log_ref, output_ref, result_ref = sys.argv[1:9]
print(json.dumps({
    "node": node,
    "area": area,
    "runId": run_id,
    "failureClass": failure_class,
    "exitCode": int(exit_code),
    "logRef": log_ref,
    "outputRef": output_ref,
    "runnerResultRef": result_ref,
}, separators=(",", ":")))
PY
)"
  singular_append_event "planner.failed" "planner codex invocation failed" "$event_json"
  echo "planner-failed ($failure_class)"
  exit 1
fi

if [[ ! -s "$out" ]]; then
  failure_class="$(singular_planner_failure_class "$codex_log" "$codex_exit" "$out" "$runner_result")"
  case "$failure_class" in
    quota|provider-overloaded) singular_planner_backoff_set "$failure_class" "$run_id" "$active_node" "$runner_result" ;;
    timeout|codex-exit) singular_planner_backoff_set "$failure_class" "$run_id" "$active_node" "$codex_log" ;;
  esac
  event_json="$(python3 - "$active_node" "$active_area" "$run_id" "$failure_class" "$codex_exit" "$codex_log" "$out" "$runner_result" <<'PY'
import json
import sys

node, area, run_id, failure_class, exit_code, log_ref, output_ref, result_ref = sys.argv[1:9]
print(json.dumps({
    "node": node,
    "area": area,
    "runId": run_id,
    "failureClass": failure_class,
    "exitCode": int(exit_code),
    "logRef": log_ref,
    "outputRef": output_ref,
    "runnerResultRef": result_ref,
}, separators=(",", ":")))
PY
)"
  singular_append_event "planner.failed" "planner produced no output" "$event_json"
  echo "planner-failed ($failure_class)"; exit 1
fi

# Strip code fences if any.
body="$(python3 - "$out" <<'PY'
import sys
t = open(sys.argv[1]).read().strip()
if t.startswith("```"):
    t = t.split("\n", 1)[1] if "\n" in t else t
    if t.rstrip().endswith("```"):
        t = t.rstrip()[:-3]
print(t.strip())
PY
)"

# AREA-COMPLETE sentinel?
first_line="$(printf '%s\n' "$body" | head -1 | tr -d '[:space:]')"
if [[ "$first_line" == "AREA-COMPLETE" || "$body" == "AREA-COMPLETE" ]]; then
  singular_append_event "planner.failed" "planner attempted non-authoritative area completion" \
    "{\"node\":\"$active_node\",\"area\":\"$active_area\",\"runId\":\"$run_id\"}"
  echo "planner-failed (AREA-COMPLETE is not authoritative; publish gate-result.v0 instead)"
  exit 1
fi

batch_file="$run_dir/planner-batch.json"
body_file="$run_dir/planner-body.txt"
printf '%s\n' "$body" >"$body_file"
# Provider runners return only a final message. The host owns extraction,
# validation, id assignment, and candidate materialization through the same
# helper the revision loop uses; no provider receives a staging path.
batch_expected_json="$(printf '%s\n' "${next_ids[@]}" | python3 -c \
  'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))')"
materialized_dir="$run_dir/planner-candidates"
batch_rc=0
singular_task_batch_materialize "$body_file" "$batch_file" "$materialized_dir" \
  "$active_area" "$batch_expected_json" assign "$SINGULAR_TASKBATCH_SCHEMA" || batch_rc=$?

# Empty batch (rc 4): a valid no-op, NOT a planner failure. 0.4.0 classified
# {"tasks": []} as invalid-output; the failure then fed the autonomate
# chokepoint, which armed a false 30-minute quota backoff (field audit, S3
# accessibility window). No failure event, no backoff, exit 0.
if [[ "$batch_rc" -eq 4 ]]; then
  singular_append_event "planner.no_tasks" "planner returned a valid empty batch" \
    "{\"node\":\"$active_node\",\"area\":\"$active_area\",\"runId\":\"$run_id\",\"class\":\"no-tasks\"}"
  if [[ -n "$stage_dir" ]]; then
    mkdir -p "$stage_dir"
    : >"$stage_dir/NO-TASKS"
  fi
  echo "planner-no-tasks (node=$active_node)"
  singular_ctx_planner_session_finalize "$active_node" 0 "" "$run_id" \
    "$(basename "$codex_runner")" "$(singular_prompt_sha "$prompt_file" 2>/dev/null || true)" \
    "$planner_head_sha" 1 >/dev/null 2>&1 || true
  planner_status_activity="Planning completed with no tasks for $active_node"
  planner_status_next_action="Advance or re-evaluate the DAG frontier"
  planner_status_outcome="no-tasks"
  exit 0
fi

if [[ "$batch_rc" -eq 0 ]]; then
  mapfile -t batch_ids < <(python3 - "$batch_file" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for item in data["tasks"]:
    print(item["taskId"])
PY
)
  for tid in "${batch_ids[@]}"; do
    tmp="$materialized_dir/$tid.candidate.md"
    if [[ -z "$stage_dir" ]]; then
      duplicate_json="$(singular_find_duplicate_task_signature "$tmp" "$active_node" 2>/dev/null || true)"
      if [[ -n "$duplicate_json" ]]; then
        event_json="$(singular_duplicate_candidate_event_json "$run_id" "$active_node" "$duplicate_json")"
        singular_append_event "origin.l1_import_rejected" "duplicate-candidate" "$event_json"
        echo "planner-failed (duplicate-candidate)"
        exit 1
      fi
    fi
  done
  for tid in "${batch_ids[@]}"; do
    if [[ -n "$stage_dir" ]]; then
      mkdir -p "$stage_dir"
      mv "$materialized_dir/$tid.candidate.md" "$stage_dir/$tid.candidate.md"
      singular_append_event "planner.staged" "task staged" \
        "{\"area\":\"$active_area\",\"taskId\":\"$tid\",\"runId\":\"$run_id\",\"node\":\"$active_node\"}"
      echo "staged:$tid"
    else
      mv "$materialized_dir/$tid.candidate.md" "$SINGULAR_TASKS_DIR/$tid.md"
      singular_append_event "planner.generated" "task generated" \
        "{\"area\":\"$active_area\",\"taskId\":\"$tid\",\"runId\":\"$run_id\"}"
      echo "generated:$tid"
    fi
  done
  # Accepted batch: persist the finalized planner session-meta (a no-op unless
  # SINGULAR_PLANNER_SESSION=1, which is the default). Never fatal.
  singular_ctx_planner_session_finalize "$active_node" 0 "$next_id" "$run_id" \
    "$(basename "$codex_runner")" "$(singular_prompt_sha "$prompt_file" 2>/dev/null || true)" \
    "$planner_head_sha" 1 >/dev/null 2>&1 || true
  if [[ -n "$stage_dir" ]]; then
    planner_status_activity="Planning staged ${#batch_ids[@]} task candidate(s) for $active_node"
    planner_status_next_action="Critique or import the staged candidates"
    planner_status_outcome="tasks-staged"
  else
    planner_status_activity="Planning generated ${#batch_ids[@]} task(s) for $active_node"
    planner_status_next_action="Dispatch the generated tasks"
    planner_status_outcome="tasks-generated"
  fi
  exit 0
fi

if [[ "$count" -ne 1 ]]; then
  singular_append_event "planner.failed" "planner output was not a valid task batch" \
    "{\"area\":\"$active_area\",\"runId\":\"$run_id\",\"failureClass\":\"invalid-output\",\"count\":$count,\"logRef\":\"$codex_log\",\"outputRef\":\"$out\"}"
  echo "planner-failed"; exit 1
fi

# Backward-compatible single-task markdown output.
if [[ -n "$stage_dir" ]]; then
  mkdir -p "$stage_dir"
  dest="$stage_dir/$next_id.candidate.md"
else
  dest="$SINGULAR_TASKS_DIR/$next_id.md"
fi
tmp="$run_dir/$next_id.candidate.md"
printf '%s\n' "$body" >"$tmp"

body_id="$(singular_task_field "$tmp" taskId 2>/dev/null || echo '')"
if [[ -n "$body_id" && "$body_id" != "$next_id" ]]; then
  # Token-safe rewrite (never substring-corrupts a longer TASK-#### token).
  singular_rewrite_task_id_token "$tmp" "$body_id" "$next_id"
fi

v_status="$(singular_task_field "$tmp" status 2>/dev/null || echo '')"
v_area="$(singular_task_field "$tmp" area 2>/dev/null || echo '')"
v_owned="$(singular_task_field "$tmp" ownedFiles 2>/dev/null || echo '[]')"
v_mode="$(singular_task_field "$tmp" dispatchMode 2>/dev/null || echo '')"
if [[ "$v_status" != "ready" || "$v_area" != "$active_area" || "$v_owned" == "[]" || "$v_mode" != "canonical" ]]; then
  singular_append_event "planner.failed" "planner output failed validation" \
    "{\"area\":\"$active_area\",\"runId\":\"$run_id\",\"failureClass\":\"invalid-output\",\"status\":\"$v_status\",\"area_field\":\"$v_area\",\"dispatchMode\":\"$v_mode\",\"logRef\":\"$codex_log\",\"outputRef\":\"$out\"}"
  echo "planner-failed (status=$v_status area=$v_area owned=$v_owned mode=$v_mode)"; exit 1
fi

if [[ -z "$stage_dir" ]]; then
  duplicate_json="$(singular_find_duplicate_task_signature "$tmp" "$active_node" 2>/dev/null || true)"
  if [[ -n "$duplicate_json" ]]; then
    event_json="$(singular_duplicate_candidate_event_json "$run_id" "$active_node" "$duplicate_json")"
    singular_append_event "origin.l1_import_rejected" "duplicate-candidate" "$event_json"
    echo "planner-failed (duplicate-candidate)"
    exit 1
  fi
fi

mv "$tmp" "$dest"
# Accepted single task: persist the finalized planner session-meta (a no-op
# unless SINGULAR_PLANNER_SESSION=1, which is the default). Never fatal.
singular_ctx_planner_session_finalize "$active_node" 0 "$next_id" "$run_id" \
  "$(basename "$codex_runner")" "$(singular_prompt_sha "$prompt_file" 2>/dev/null || true)" \
  "$planner_head_sha" 1 >/dev/null 2>&1 || true
if [[ -n "$stage_dir" ]]; then
  singular_append_event "planner.staged" "task staged" \
    "{\"area\":\"$active_area\",\"taskId\":\"$next_id\",\"runId\":\"$run_id\",\"node\":\"$active_node\"}"
  echo "staged:$next_id"
  planner_status_activity="Planning staged task $next_id for $active_node"
  planner_status_next_action="Critique or import the staged candidate"
  planner_status_outcome="task-staged"
else
  singular_append_event "planner.generated" "task generated" \
    "{\"area\":\"$active_area\",\"taskId\":\"$next_id\",\"runId\":\"$run_id\"}"
  echo "generated:$next_id"
  planner_status_activity="Planning generated task $next_id for $active_node"
  planner_status_next_action="Dispatch the generated task"
  planner_status_outcome="task-generated"
fi
