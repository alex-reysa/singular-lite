#!/usr/bin/env bash

# Shell entrypoints for task_lifecycle.py.  Callers source lib.sh first; these
# functions deliberately keep lifecycle authority local to the four maintenance
# entrypoints rather than silently changing every legacy lease caller.

SINGULAR_TASK_LIFECYCLE="${SINGULAR_TASK_LIFECYCLE:-$SCRIPT_DIR/task_lifecycle.py}"

singular_lifecycle_reserve() {
  local task_id="$1" owner="$2" run_id="$3" branch="$4" area="$5"
  local owned_json="$6" base_sha="$7" batch_id="$8" worktree="$9"
  python3 "$SINGULAR_TASK_LIFECYCLE" reserve \
    --lease "$(singular_lease_path "$task_id")" --task "$task_id" \
    --owner "$owner" --run "$run_id" --branch "$branch" --area "$area" \
    --scope-json "$owned_json" --base "$base_sha" --batch "$batch_id" \
    --worktree "$worktree" --imported-dir "$SINGULAR_ORCH_DIR/packets/imported/$task_id" \
    --deadline-seconds "${SINGULAR_DISPATCH_DEADLINE_SECS:-14400}"
}

singular_lifecycle_dispatch_record_write() {
  local task_id="$1" run_id="$2" pid="$3" pid_start="$4" log="$5"
  local base_sha="$6" batch_id="$7" owner="$8" generation="$9" pgid=""
  pgid="$(singular_pgid_of "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$pgid" =~ ^[0-9]+$ ]] || pgid=0
  python3 "$SINGULAR_TASK_LIFECYCLE" bind-dispatch \
    --record "$(singular_dispatch_record_path "$task_id")" --task "$task_id" \
    --run "$run_id" --pid "$pid" --pid-start "$pid_start" --pgid "$pgid" \
    --log "$log" --base "$base_sha" --batch "$batch_id" \
    --owner "$owner" --generation "$generation"
}

singular_lifecycle_exit_write() {
  local task_id="$1" ec="$2" owner="$3" generation="$4"
  # A short bounded wait closes the spawn-before-record publication window for
  # very fast workers.  It never authorizes from a record created by a successor.
  local ticks=0
  while [[ ! -f "$(singular_dispatch_record_path "$task_id")" && "$ticks" -lt 20 ]]; do
    sleep 0.05
    ticks=$((ticks + 1))
  done
  python3 "$SINGULAR_TASK_LIFECYCLE" write-exit \
    --record "$(singular_dispatch_record_path "$task_id")" \
    --exit-file "$(singular_dispatch_exit_path "$task_id")" \
    --owner "$owner" --generation "$generation" --exit-code "$ec"
}

singular_lifecycle_finish() {
  local task_id="$1" owner="$2" generation="$3" batch="$4" reason="$5" next_action="$6"
  python3 "$SINGULAR_TASK_LIFECYCLE" finish \
    --lease "$(singular_lease_path "$task_id")" \
    --record "$(singular_dispatch_record_path "$task_id")" \
    --task "$task_id" --owner "$owner" --generation "$generation" \
    --batch "$batch" --reason "$reason" --next-action "$next_action"
}

singular_lifecycle_legacy_finish() {
  local task_id="$1" lease_sha="$2" status="$3" reason="$4" next_action="$5"
  python3 "$SINGULAR_TASK_LIFECYCLE" legacy-finish \
    --lease "$(singular_lease_path "$task_id")" --lease-sha "$lease_sha" \
    --new-status "$status" --reason "$reason" --next-action "$next_action"
}

singular_lifecycle_dispatch_finalize() {
  local task_id="$1" ec="$2" outcome="$3" owner="$4" generation="$5"
  python3 "$SINGULAR_TASK_LIFECYCLE" finalize \
    --record "$(singular_dispatch_record_path "$task_id")" \
    --exit-file "$(singular_dispatch_exit_path "$task_id")" \
    --owner "$owner" --generation "$generation" --exit-code "$ec" --outcome "$outcome"
}

singular_lifecycle_reap_dispatches() {
  local run_id="$1" reaped_ok=0 reaped_failures=0 reaped_refused=0 reaped_terminal=0 workers_running=0
  local record tid state pid pid_start pgid rec_run ec owner generation batch outcome exit_data
  local finish_reason finish_next
  if [[ -d "$SINGULAR_DISPATCH_DIR" ]]; then
    for record in "$SINGULAR_DISPATCH_DIR"/*.json; do
      [[ -f "$record" ]] || continue
      state="$(singular_json_field "$record" state 2>/dev/null || true)"
      [[ "$state" == "launched" ]] || continue
      tid="$(singular_json_field "$record" taskId 2>/dev/null || true)"
      owner="$(singular_json_field "$record" reservationOwner 2>/dev/null || true)"
      generation="$(singular_json_field "$record" reservationGeneration 2>/dev/null || true)"
      batch="$(singular_json_field "$record" batchId 2>/dev/null || true)"
      if [[ -z "$tid" || -z "$owner" || ! "$generation" =~ ^[1-9][0-9]*$ ]]; then
        # Compatibility for dispatch records created before owner generations.
        # Generated leases never enter this path; only an entirely legacy pair
        # receives the historical behavior during upgrade.
        if [[ -n "$tid" \
            && -z "$(singular_lease_field "$tid" reservationGeneration 2>/dev/null || true)" ]]; then
          if [[ -f "$(singular_dispatch_exit_path "$tid")" ]]; then
            ec="$(head -1 "$(singular_dispatch_exit_path "$tid")" 2>/dev/null | tr -d '[:space:]')"
            [[ "$ec" =~ ^[0-9]+$ ]] || ec=1
            case "$ec" in
              0) outcome="ok"; reaped_ok=$((reaped_ok + 1)) ;;
              2) outcome="refused"; reaped_refused=$((reaped_refused + 1)) ;;
              3) outcome="terminal"; reaped_terminal=$((reaped_terminal + 1)) ;;
              *) outcome="failed"; reaped_failures=$((reaped_failures + 1)) ;;
            esac
            singular_dispatch_record_finalize "$tid" "$ec" "$outcome"
            continue
          fi
          pid="$(singular_json_field "$record" pid 2>/dev/null || true)"
          pid_start="$(singular_json_field "$record" pidStart 2>/dev/null || true)"
          pgid="$(singular_json_field "$record" pgid 2>/dev/null || true)"
          rec_run="$(singular_json_field "$record" runId 2>/dev/null || true)"
          if singular_dispatch_tree_alive "$tid" "$pid" "$pid_start" "$rec_run" "${pgid:-0}"; then
            workers_running=$((workers_running + 1))
          else
            case "$(singular_lease_status "$tid" 2>/dev/null || true)" in
              planned|running|needs-review) singular_lease_set_status "$tid" failed 2>/dev/null || true ;;
            esac
            reaped_failures=$((reaped_failures + 1))
            singular_dispatch_record_finalize "$tid" -1 crashed
          fi
        else
          workers_running=$((workers_running + 1))
        fi
        continue
      fi
      if [[ -f "$(singular_dispatch_exit_path "$tid")" ]]; then
        mapfile -t exit_data < <(python3 "$SINGULAR_TASK_LIFECYCLE" read-exit \
          --record "$record" --exit-file "$(singular_dispatch_exit_path "$tid")" 2>/dev/null) || exit_data=()
        if [[ ${#exit_data[@]} -ne 3 ]]; then
          # Stale/malformed exit remains evidence; do not consume the current dispatch.
          workers_running=$((workers_running + 1))
          continue
        fi
        ec="${exit_data[0]}"; owner="${exit_data[1]}"; generation="${exit_data[2]}"
        case "$ec" in
          0) outcome="ok"; reaped_ok=$((reaped_ok + 1)) ;;
          2) outcome="refused"; reaped_refused=$((reaped_refused + 1)) ;;
          3) outcome="terminal"; reaped_terminal=$((reaped_terminal + 1)) ;;
          *) outcome="failed"; reaped_failures=$((reaped_failures + 1)) ;;
        esac
        if [[ "$ec" -eq 0 ]]; then
          finish_reason="driver-returned-with-active-lease"
          finish_next="inspect publication state, then retry only if no accepted candidate exists"
        else
          finish_reason="driver-exit-$ec"
          finish_next="classify the bounded failure before retrying"
        fi
        # The wrapper normally performs this transition. Repeating it here is
        # idempotent and closes the narrow spawn/record publication race where
        # a very fast wrapper could not yet verify its dispatch record.
        singular_lifecycle_finish "$tid" "$owner" "$generation" "$batch" \
          "$finish_reason" "$finish_next" 2>/dev/null || true
        singular_lifecycle_dispatch_finalize "$tid" "$ec" "$outcome" "$owner" "$generation" || continue
        singular_append_event "origin.dispatch_reaped" "dispatch reaped" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":$ec,\"outcome\":\"$outcome\",\"reservationOwner\":\"$owner\",\"reservationGeneration\":$generation}"
        continue
      fi
      pid="$(singular_json_field "$record" pid 2>/dev/null || true)"
      pid_start="$(singular_json_field "$record" pidStart 2>/dev/null || true)"
      pgid="$(singular_json_field "$record" pgid 2>/dev/null || true)"
      rec_run="$(singular_json_field "$record" runId 2>/dev/null || true)"
      if singular_dispatch_tree_alive "$tid" "$pid" "$pid_start" "$rec_run" "${pgid:-0}"; then
        workers_running=$((workers_running + 1))
        continue
      fi
      if singular_lifecycle_finish "$tid" "$owner" "$generation" "$batch" \
          "dispatch-tree-vanished" "retry after bounded recovery classification"; then
        reaped_failures=$((reaped_failures + 1))
        singular_lifecycle_dispatch_finalize "$tid" -1 crashed "$owner" "$generation" || true
        singular_append_event "origin.dispatch_reaped" "dispatch crashed (tree dead, no exit file)" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":-1,\"outcome\":\"crashed\",\"reservationOwner\":\"$owner\",\"reservationGeneration\":$generation}"
      else
        workers_running=$((workers_running + 1))
      fi
    done
  fi
  echo "reaped_ok=$reaped_ok"
  echo "reaped_failures=$reaped_failures"
  echo "reaped_refused=$reaped_refused"
  echo "reaped_terminal=$reaped_terminal"
  echo "workers_running=$workers_running"
}

singular_lifecycle_retain_candidate() {
  local task_id="$1" packet="$2" audit="$3" task_file="$4" run="$5" branch="$6"
  local head="$7" tree="$8" campaign="$9" mode="${10}"
  python3 "$SINGULAR_TASK_LIFECYCLE" retain-candidate \
    --lease "$(singular_lease_path "$task_id")" --packet "$packet" --audit "$audit" \
    --task-file "$task_file" --task "$task_id" --run "$run" --branch "$branch" \
    --head "$head" --tree "$tree" --campaign "$campaign" --acceptance-mode "$mode"
}

singular_lifecycle_candidate_check() {
  local task_id="$1" head="$2" tree="$3" campaign="$4" target_head="$5" invalidation_key="$6"
  local branch_key="${7:-$invalidation_key}"
  python3 "$SINGULAR_TASK_LIFECYCLE" candidate-check \
    --lease "$(singular_lease_path "$task_id")" --head "$head" --tree "$tree" \
    --campaign "$campaign" --target-head "$target_head" --invalidation-key "$invalidation_key" \
    --branch-key "$branch_key"
}

singular_lifecycle_candidate_failed() {
  local task_id="$1" head="$2" tree="$3" campaign="$4" failure="$5" target_head="$6" invalidation_key="$7" next="$8"
  python3 "$SINGULAR_TASK_LIFECYCLE" candidate-failed \
    --lease "$(singular_lease_path "$task_id")" --head "$head" --tree "$tree" \
    --campaign "$campaign" --failure-class "$failure" --target-head "$target_head" \
    --invalidation-key "$invalidation_key" \
    --next-action "$next"
}

singular_lifecycle_candidate_tested() {
  local task_id="$1" head="$2" tree="$3" campaign="$4" tested_tree="$5"
  local target_parent="$6" candidate_parent="$7" synthetic_commit="$8" gate_run="$9"
  local gate_report="${10}" gate_command="${11}"
  python3 "$SINGULAR_TASK_LIFECYCLE" candidate-tested \
    --lease "$(singular_lease_path "$task_id")" --head "$head" --tree "$tree" \
    --campaign "$campaign" --tested-tree "$tested_tree" --target-parent "$target_parent" \
    --candidate-parent "$candidate_parent" --synthetic-commit "$synthetic_commit" \
    --gate-run "$gate_run" --gate-report "$gate_report" --gate-command "$gate_command"
}

singular_lifecycle_candidate_proof() {
  local task_id="$1" head="$2" tree="$3" campaign="$4" gate_command="$5"
  python3 "$SINGULAR_TASK_LIFECYCLE" candidate-proof \
    --lease "$(singular_lease_path "$task_id")" --head "$head" --tree "$tree" \
    --campaign "$campaign" --gate-command "$gate_command"
}

singular_lifecycle_candidate_blocked() {
  local task_id="$1" head="$2" tree="$3" campaign="$4" reason="$5" target_head="$6" next="$7"
  python3 "$SINGULAR_TASK_LIFECYCLE" candidate-blocked \
    --lease "$(singular_lease_path "$task_id")" --head "$head" --tree "$tree" \
    --campaign "$campaign" --reason "$reason" --target-head "$target_head" \
    --next-action "$next"
}

singular_lifecycle_candidate_integrated() {
  local task_id="$1" head="$2" tree="$3" campaign="$4" merge="$5" proof_id="$6"
  python3 "$SINGULAR_TASK_LIFECYCLE" candidate-integrated \
    --lease "$(singular_lease_path "$task_id")" --head "$head" --tree "$tree" \
    --campaign "$campaign" --merge "$merge" --proof-id "$proof_id"
}
