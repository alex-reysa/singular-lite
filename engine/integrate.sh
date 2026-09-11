#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile). macOS /bin/bash is 3.2; re-exec under Homebrew bash
# if launched with an old interpreter.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "integrate.sh requires bash >= 4 (mapfile); install via 'brew install bash'" >&2
  exit 1
fi

# L0 Integration step: merge ACCEPTED worker branches into the integration target
# branch. Local only — this NEVER pushes and NEVER touches `main`.
#
# A branch is eligible when its imported packet has status=accepted, the matching
# auditor verdict is accepted, the branch head matches the packet headSha, and the
# commit is not already merged into the target. Each merge is verified BEFORE it is
# finalized: `git merge --no-ff --no-commit` stages the merge, the regression gate
# runs on the merged tree, and only a green gate is committed; any conflict or red
# gate is aborted (`git merge --abort`) and recorded for a human. Per-task isolation
# means one bad task never blocks the others or leaves the target mid-merge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lifecycle.sh"

task_filter=""
dry_run="no"
from_reconcile="no"
run_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task_filter="$2"; shift 2 ;;
    --dry-run) dry_run="yes"; shift ;;
    --from-reconcile) from_reconcile="yes"; shift ;;
    --run-id) run_id="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Direct integration is an authoritative mutation entrypoint. Verify before
# creating state, taking the origin lock, or staging a merge.
singular_campaign_verify_or_refuse integrate entry || exit 2
integration_campaign_binding="$(singular_campaign_binding)" || {
  echo "integrate: inconsistent campaign identity at entry" >&2
  exit 2
}

singular_ensure_state_dirs
singular_require_target_branch

# ---- Pre-flight policy guards (fail fast, before any lock) ----
current_branch="$(singular_current_branch)"
if [[ -z "$current_branch" ]]; then
  echo "refuse: detached HEAD; integration must run on the target branch" >&2
  exit 2
fi
if [[ "$current_branch" != "$SINGULAR_TARGET_BRANCH" ]]; then
  echo "refuse: on '$current_branch', not target '$SINGULAR_TARGET_BRANCH'; checkout the target first" >&2
  exit 2
fi
if [[ "$SINGULAR_TARGET_BRANCH" == "main" ]]; then
  echo "refuse: target is 'main' (release-only); integration into main is human-gated" >&2
  exit 2
fi
# Refuse only on NON-control-state dirt. Control-state churn under
# docs/orchestration/ (generated tasks, imported packets, decisions, snapshots)
# is expected mid-cycle and never participates in the code merge; reconcile
# commits it separately at the end of the cycle.
if [[ "$dry_run" != "yes" ]]; then
  code_dirt=0
  code_dirt_path=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == '??'* ]] && continue   # untracked files never enter the merge
    p="${line:3}"; p="${p##* -> }"
    case "$p" in docs/orchestration/*) ;; *) code_dirt=1; code_dirt_path="$p"; break ;; esac
  done < <(git -C "$SINGULAR_ROOT" status --porcelain)
  if [[ "$code_dirt" -eq 1 ]]; then
    echo "refuse: working tree has non-control-state changes ($code_dirt_path); commit or stash before integrating" >&2
    exit 2
  fi
fi

[[ -n "$run_id" ]] || run_id="$(singular_run_id)"

integration_status_activity="Integration failed"
integration_status_next_action="Inspect the integration evidence"
integration_status_outcome="integration-failed"
integration_gate_tmp=""
integration_gate_worktree=""
integration_gate_worktree_added="no"
integration_campaign_lock_held="no"

# A staged integration tree is tested in a disposable detached worktree. Keep
# its lifecycle explicit so a red gate, setup error, interrupt, or ordinary exit
# cannot leave a registered worktree behind.
singular_integration_gate_cleanup() {
  local cleanup_complete="yes"
  if [[ "$integration_gate_worktree_added" == "yes" && -n "$integration_gate_worktree" ]]; then
    if singular_git_lock_acquire; then
      if ! git -C "$SINGULAR_ROOT" worktree remove --force "$integration_gate_worktree" >/dev/null 2>&1; then
        cleanup_complete="no"
      fi
      singular_git_lock_release
    else
      # Never mutate shared .git metadata outside the repo-wide git lock. A
      # registered disposable checkout is safer to leave for bounded GC than
      # to race another worktree/commit operation.
      cleanup_complete="no"
    fi
    if [[ "$cleanup_complete" != "yes" ]]; then
      singular_append_event "integration.gate_cleanup_deferred" \
        "disposable integration gate worktree cleanup deferred for GC" \
        "{\"runId\":\"$run_id\",\"worktree\":\"$integration_gate_worktree\"}" \
        >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$cleanup_complete" == "yes" && -n "$integration_gate_tmp" ]]; then
    case "$integration_gate_tmp" in
      "$SINGULAR_STATE_DIR"/tmp/integration-gate.*)
        rm -rf -- "$integration_gate_tmp" 2>/dev/null || true ;;
    esac
  fi
  integration_gate_tmp=""
  integration_gate_worktree=""
  integration_gate_worktree_added="no"
}

# Abort an uncommitted integration without destroying bytes that appeared in
# the main checkout while its exact-tree gate was running. `git merge --abort`
# is preferred because it restores the complete pre-merge state. It can refuse
# when a concurrent worktree edit overlaps a merged path; in that case a mixed
# reset clears MERGE_HEAD and the staged tree while deliberately preserving the
# worktree. The task-status edit is engine-owned, so restore that one control
# file from the pre-merge parent to avoid a false `integrated` lifecycle state.
singular_integration_abort_merge() {
  local task_path="${1:-}" parent="${2:-HEAD}" task_rel="" cleanup_rc=0
  if ! singular_git_lock_acquire; then
    return 1
  fi
  if git -C "$SINGULAR_ROOT" merge --abort >/dev/null 2>&1; then
    singular_git_lock_release
    return 0
  fi
  git -C "$SINGULAR_ROOT" reset --mixed "$parent" >/dev/null 2>&1 \
    || cleanup_rc=$?
  if [[ "$cleanup_rc" -eq 0 && -n "$task_path" ]]; then
    case "$task_path" in
      "$SINGULAR_ROOT"/*) task_rel="${task_path#"$SINGULAR_ROOT"/}" ;;
      *) task_rel="$task_path" ;;
    esac
    git -C "$SINGULAR_ROOT" restore --source="$parent" --worktree -- "$task_rel" \
      >/dev/null 2>&1 || cleanup_rc=$?
  fi
  if [[ -e "$SINGULAR_ROOT/.git/MERGE_HEAD" ]] \
      || ! git -C "$SINGULAR_ROOT" diff --cached --quiet; then
    cleanup_rc=1
  fi
  singular_git_lock_release
  return "$cleanup_rc"
}

singular_integration_status_write() {
  local activity="$1" next_action="$2" task="${3:-}"
  local args=(
    write --run-id "$run_id" --phase integrating --state active
    --activity "$activity" --safe-cancel true --next-action "$next_action"
    --process-type integrator --pid "$$"
  )
  [[ -n "$task" ]] && args+=(--task-id "$task")
  "$SCRIPT_DIR/run-status.sh" "${args[@]}" >/dev/null 2>&1 || true
}

singular_integrate_on_exit() {
  local rc=$?
  local state="failed"
  trap - EXIT
  if [[ "$integration_campaign_lock_held" == "yes" ]]; then
    singular_campaign_lock_release 2>/dev/null || true
    integration_campaign_lock_held="no"
  fi
  singular_integration_gate_cleanup
  [[ "$rc" -eq 0 ]] && state="completed"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$run_id" --phase terminal --state "$state" \
    --activity "$integration_status_activity" --safe-cancel false \
    --next-action "$integration_status_next_action" --process-type integrator --pid "$$" \
    --outcome "$integration_status_outcome" >/dev/null 2>&1 || true
  if [[ "$from_reconcile" != "yes" ]]; then
    singular_release_lock "$run_id" || true
  fi
  exit "$rc"
}

singular_integration_status_write \
  "Discovering accepted work for integration" "Verify eligible worker heads"
trap singular_integrate_on_exit EXIT

# ---- Lock (shared with reconcile when invoked via --from-reconcile) ----
if [[ "$from_reconcile" == "yes" ]]; then
  singular_require_inherited_origin_lock "$run_id" || {
    echo "integrate: --from-reconcile requires verified inherited lock authority" >&2
    exit 2
  }
else
  singular_acquire_lock "$run_id"
fi

gate_cmd="${SINGULAR_DEFAULT_GATE_CMD}"
integrated_this_run=0
declare -a integrated_nodes=()
declare -A immediate_promotion_attempted=()
gates_promoted_this_run=0
failed_integrations=0
skipped=0
eligible=0

# ---- Eligibility discovery ----
declare -a dirs=()
if [[ -n "$task_filter" ]]; then
  dirs=("$SINGULAR_ORCH_DIR/packets/imported/$task_filter")
else
  mapfile -t dirs < <(find "$SINGULAR_ORCH_DIR/packets/imported" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

# headSha prefix-tolerant comparison (matches import-packet.sh semantics).
sha_matches() {
  local want="$1" actual="$2"
  [[ "$actual" == "${want:0:${#actual}}" || "$want" == "$actual" ]]
}

push_enabled="${SINGULAR_PUSH:-0}"

singular_log_slug() {
  local s="${1//\//__}"
  printf '%s' "$s" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

# Ask the decider for an action at an integration failure point. Echoes action.
integration_decide() {
  local fc="$1" task="$2" branch="$3" ctx="$4"
  local out
  out="$("$SCRIPT_DIR/decide.sh" --task "$task" --failure-class "$fc" --branch "$branch" \
    --run "$run_id" --context-file "${ctx:-/dev/null}" --worktree "$SINGULAR_ROOT" 2>/dev/null || true)"
  singular_integration_status_write \
    "Resuming integration after the decision for $task" \
    "Apply the selected integration recovery action" "$task"
  printf '%s\n' "$out" | sed -n 's/^action=//p' | tail -1
}

integration_candidate_failed() {
  local task="$1" head="$2" tree="$3" campaign="$4" failure="$5" target_head="$6" next="$7"
  local failure_invalidation_key="${8:-$integration_invalidation_key}"
  [[ "${candidate_lifecycle_enabled:-no}" == "yes" ]] || return 0
  singular_lifecycle_candidate_failed "$task" "$head" "$tree" "$campaign" \
    "$failure" "$target_head" "$failure_invalidation_key" "$next" || {
      echo "refuse: could not preserve accepted candidate state for $task" >&2
      return 1
    }
}

# Resolve the one target-history commit that carries a durable integration
# proof and exactly matches the tree and ordered parents that passed the gate.
# The proof marker narrows the history lookup; the object checks remain the
# authority and prevent an ordinary/manual ancestor from being finalized.
integration_proven_commit() {
  local proof_id="$1" tested_tree="$2" target_parent="$3" candidate_parent="$4"
  local commit message tree parents found=""
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    message="$(git -C "$SINGULAR_ROOT" show -s --format=%B "$commit" 2>/dev/null || true)"
    printf '%s\n' "$message" | grep -Fxq "Integration-Proof: $proof_id" || continue
    tree="$(git -C "$SINGULAR_ROOT" rev-parse "$commit^{tree}" 2>/dev/null || true)"
    parents="$(git -C "$SINGULAR_ROOT" rev-list --parents -n 1 "$commit" 2>/dev/null || true)"
    [[ "$tree" == "$tested_tree" ]] || continue
    [[ "$parents" == "$commit $target_parent $candidate_parent" ]] || continue
    if [[ -n "$found" ]]; then
      return 2
    fi
    found="$commit"
  done < <(git -C "$SINGULAR_ROOT" log "$SINGULAR_TARGET_BRANCH" --format=%H \
    --fixed-strings --grep="Integration-Proof: $proof_id" 2>/dev/null || true)
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

# Push a branch to origin (no force). Secret-scans the outgoing range first; on a
# non-fast-forward, fetches and retries once, else records and skips (no block).
push_branch() {
  local b="$1"
  [[ "$push_enabled" == "1" ]] || return 0
  git -C "$SINGULAR_ROOT" remote get-url origin >/dev/null 2>&1 || { echo "push: no origin remote; skipping"; return 0; }
  local range="$b"
  if git -C "$SINGULAR_ROOT" rev-parse --verify --quiet "origin/$b" >/dev/null; then range="origin/$b..$b"; fi
  local scan_log="$run_dir/secret-scan-push-$(singular_log_slug "$b").log"
  if ! "$SCRIPT_DIR/secret-scan.sh" --worktree "$SINGULAR_ROOT" --range "$range" >"$scan_log" 2>&1; then
    singular_append_event "push.blocked" "secret-scan blocked push" "{\"runId\":\"$run_id\",\"branch\":\"$b\"}"
    echo "push BLOCKED for $b (secret-scan)"; return 0
  fi
  if git -C "$SINGULAR_ROOT" push origin "$b" >/dev/null 2>&1; then
    singular_append_event "push.ok" "pushed to origin" "{\"runId\":\"$run_id\",\"branch\":\"$b\"}"
    echo "pushed $b -> origin"; return 0
  fi
  git -C "$SINGULAR_ROOT" fetch origin >/dev/null 2>&1 || true
  if git -C "$SINGULAR_ROOT" push origin "$b" >/dev/null 2>&1; then
    singular_append_event "push.ok" "pushed to origin (after fetch)" "{\"runId\":\"$run_id\",\"branch\":\"$b\"}"
    echo "pushed $b -> origin (after fetch)"; return 0
  fi
  singular_append_event "push.failed" "push failed (non-ff or remote error)" "{\"runId\":\"$run_id\",\"branch\":\"$b\"}"
  echo "push FAILED for $b (parked)"; return 0
}

# run_dir for this integration run's logs.
run_dir="$(singular_run_dir "$run_id")"; mkdir -p "$run_dir"

for d in "${dirs[@]}"; do
  [[ -d "$d" ]] || continue
  task_id="$(basename "$d")"
  # Early-skip terminal leases: never re-process already-integrated work.
  # The hundreds of integrated tasks were re-scanned every cycle (find over
  # all imported packets) and paid python+git merge-base cost before the
  # idempotency guard below; this short-circuits them with one cheap lease
  # read. Guarded by -z task_filter so an explicit --task re-integration still
  # runs; the merge-base guard below remains the correctness safety net.
  if [[ -z "$task_filter" ]]; then
    case "$(singular_lease_status "$task_id" 2>/dev/null || true)" in
      integrated|blocked|cancelled|superseded|stale) skipped=$((skipped + 1)); continue ;;
    esac
  fi
  # newest accepted packet for this task (exclude audit sidecars)
  packet="$(find "$d" -maxdepth 1 -name '*.json' -not -name '*.audit.json' -type f 2>/dev/null | sort | tail -1)"
  [[ -n "$packet" ]] || continue

  status="$(singular_json_field "$packet" status 2>/dev/null || echo "")"
  [[ "$status" == "accepted" ]] || { continue; }

  branch="$(singular_json_field "$packet" branch 2>/dev/null || echo "")"
  head_sha="$(singular_json_field "$packet" headSha 2>/dev/null || echo "")"
  run_packet="$(basename "$packet" .json)"
  sidecar="${packet%.json}.audit.json"

  # Audit sidecar must say accepted, unless a decider accept-waiver is recorded
  # in the packet evidence and durable decision trail.
  acceptance_mode="$(singular_packet_acceptance_mode "$packet" "$sidecar" 2>/dev/null || true)"
  if [[ -z "$acceptance_mode" ]]; then
    echo "skip $task_id: no accepted auditor verdict or recorded accept-waiver"
    skipped=$((skipped + 1))
    continue
  fi

  packet_campaign_binding="$(python3 - "$packet" <<'PY' 2>/dev/null || true
import json
import sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
for item in packet.get("evidence", []):
    if isinstance(item, dict) and item.get("kind") == "campaign-binding":
        print(item.get("ref", ""))
        break
PY
)"
  lease_campaign_binding="$(singular_lease_field "$task_id" campaignBinding 2>/dev/null || true)"
  audit_campaign_binding=""
  if [[ "$acceptance_mode" == "accepted" ]]; then
    audit_campaign_binding="$(python3 - "$sidecar" <<'PY' 2>/dev/null || true
import json
import sys
audit = json.load(open(sys.argv[1], encoding="utf-8"))
for item in audit.get("evidenceReviewed", []):
    marker = str(item)
    if marker.startswith("campaign-binding:"):
        print(marker[len("campaign-binding:"):])
        break
PY
)"
  fi
  candidate_lifecycle_enabled="no"
  candidate_campaign_binding="$packet_campaign_binding"
  if [[ "$integration_campaign_binding" == "legacy" && -z "$candidate_campaign_binding" ]]; then
    candidate_campaign_binding="legacy"
  fi
  candidate_tree="$(git -C "$SINGULAR_ROOT" rev-parse "$head_sha^{tree}" 2>/dev/null || true)"
  task_file="$SINGULAR_TASKS_DIR/$task_id.md"
  if [[ -z "$candidate_tree" ]]; then
    echo "skip $task_id: accepted candidate tree is unavailable"
    skipped=$((skipped + 1))
    continue
  fi
  target_head="$(git -C "$SINGULAR_ROOT" rev-parse "$SINGULAR_TARGET_BRANCH" 2>/dev/null || true)"
  # Candidate failures that depend on branch availability must be invalidated
  # when that ref appears or moves. The accepted head remains the authority;
  # this observed ref head only decides whether unchanged recovery work can be
  # suppressed for the cycle.
  candidate_branch_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
    "$branch^{commit}" 2>/dev/null || true)"
  integration_invalidation_key="$(singular_sha256_text \
    "$target_head|$integration_campaign_binding|$gate_cmd")"
  branch_invalidation_key="$(singular_sha256_text \
    "$branch|$candidate_branch_head")"
  already_merged="no"
  git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$head_sha" "$SINGULAR_TARGET_BRANCH" \
    2>/dev/null && already_merged="yes"
  existing_candidate="no"
  if python3 - "$(singular_lease_path "$task_id")" <<'PY' >/dev/null 2>&1
import json, sys
assert isinstance(json.load(open(sys.argv[1], encoding="utf-8")).get("acceptedCandidate"), dict)
PY
  then
    existing_candidate="yes"
  fi
  # Crash recovery: a verified merge may commit before candidate publication.
  # Ancestry alone is insufficient because an accepted candidate can be merged
  # manually or after a red gate. Require the durable green-gate receipt plus
  # the exact committed tree and ordered parents. This precedes task-contract
  # hashing because the verified merge changed Status to integrated.
  if [[ "$already_merged" == "yes" && "$existing_candidate" == "yes" ]]; then
    proof_rc=0
    proof_data=()
    recovery_reason="verified integration proof is unavailable"
    if [[ "$candidate_campaign_binding" == "$integration_campaign_binding" ]]; then
      proof_out="$(singular_lifecycle_candidate_proof "$task_id" "$head_sha" \
        "$candidate_tree" "$candidate_campaign_binding" "$gate_cmd" 2>&1)" || proof_rc=$?
      if [[ "$proof_rc" -eq 0 ]]; then
        mapfile -t proof_data <<<"$proof_out"
      else
        recovery_reason="$proof_out"
      fi
    else
      proof_rc=2
      recovery_reason="retained candidate belongs to another campaign"
    fi
    proven_merge=""
    if [[ "$proof_rc" -eq 0 && ${#proof_data[@]} -eq 5 ]]; then
      proven_merge="$(integration_proven_commit "${proof_data[0]}" "${proof_data[1]}" \
        "${proof_data[2]}" "${proof_data[3]}" 2>/dev/null || true)"
      [[ -n "$proven_merge" ]] \
        || recovery_reason="no target commit matches the tested tree, ordered parents, and proof marker"
    fi
    if [[ -n "$proven_merge" ]]; then
      if [[ "$dry_run" != "yes" ]]; then
        singular_lifecycle_candidate_integrated "$task_id" "$head_sha" "$candidate_tree" \
          "$candidate_campaign_binding" "$proven_merge" "${proof_data[0]}" || {
            echo "refuse: proven merge does not match retained lifecycle authority" >&2
            exit 2
          }
      fi
      echo "skip $task_id: verified integration $proven_merge already reaches $SINGULAR_TARGET_BRANCH"
      if [[ "$dry_run" != "yes" ]]; then
        singular_append_event "integration.skipped" "verified retained candidate integration recovered" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"verified-integration-recovered\",\"mergeCommit\":\"$proven_merge\",\"targetHead\":\"$target_head\"}"
      fi
    else
      recovery_action="inspect the retained candidate; only a host-tested exact merge proof can publish integration"
      if [[ "$dry_run" != "yes" ]]; then
        singular_lifecycle_candidate_blocked "$task_id" "$head_sha" "$candidate_tree" \
          "$candidate_campaign_binding" "unverified-already-merged" "$target_head" \
          "$recovery_action" || {
            echo "refuse: could not retain actionable recovery state for merged candidate" >&2
            exit 2
          }
        singular_append_event "integration.recovery_blocked" \
          "ancestor lacks a verified exact-merge receipt" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"targetHead\":\"$target_head\"}"
      fi
      echo "skip $task_id: already reachable but integration is unverified ($recovery_reason); action: $recovery_action"
    fi
    skipped=$((skipped + 1))
    continue
  fi
  if [[ -f "$task_file" && "$dry_run" != "yes" && "$already_merged" != "yes" ]]; then
    candidate_lifecycle_enabled="yes"
    if ! singular_lifecycle_retain_candidate "$task_id" "$packet" "$sidecar" "$task_file" \
        "$run_packet" "$branch" "$head_sha" "$candidate_tree" "$candidate_campaign_binding" \
        "$acceptance_mode" >/dev/null; then
      echo "skip $task_id: accepted candidate lifecycle binding failed closed"
      skipped=$((skipped + 1))
      continue
    fi
    recovery_claimed="no"
    if [[ -n "${SINGULAR_RECOVERY_AUTHORIZATION_ID:-}" ]]; then
      if python3 "$SCRIPT_DIR/task_lifecycle.py" claim-recovery \
          --lease "$(singular_lease_path "$task_id")" \
          --authorization-id "$SINGULAR_RECOVERY_AUTHORIZATION_ID" --action regate \
          --head "$head_sha" --tree "$candidate_tree" \
          --campaign "$candidate_campaign_binding" --run "$run_id" >/dev/null; then
        recovery_claimed="yes"
        singular_append_event "integration.regate_authorized" \
          "single-use unchanged candidate regate authority claimed" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"headSha\":\"$head_sha\",\"authorizationId\":\"$SINGULAR_RECOVERY_AUTHORIZATION_ID\"}" || true
      else
        echo "skip $task_id: recovery authorization is invalid, stale, or already consumed"
        skipped=$((skipped + 1))
        continue
      fi
    fi
    candidate_check_rc=0
    if [[ "$recovery_claimed" != "yes" ]]; then
      candidate_check_out="$(singular_lifecycle_candidate_check "$task_id" "$head_sha" \
        "$candidate_tree" "$candidate_campaign_binding" "$target_head" \
        "$integration_invalidation_key" "$branch_invalidation_key" 2>&1)" || candidate_check_rc=$?
    fi
    if [[ "$candidate_check_rc" -eq 3 ]]; then
      echo "skip $task_id: unchanged failed integration; action: $candidate_check_out"
      skipped=$((skipped + 1))
      continue
    elif [[ "$candidate_check_rc" -ne 0 ]]; then
      echo "skip $task_id: durable candidate authority mismatch ($candidate_check_out)"
      skipped=$((skipped + 1))
      continue
    fi
  fi
  if [[ "$integration_campaign_binding" == "legacy" ]]; then
    [[ -n "$packet_campaign_binding" ]] || packet_campaign_binding="legacy"
    [[ -n "$lease_campaign_binding" ]] || lease_campaign_binding="legacy"
    if [[ "$acceptance_mode" == "accepted" && -z "$audit_campaign_binding" ]]; then
      audit_campaign_binding="legacy"
    fi
  fi
  campaign_binding_ok="yes"
  [[ "$packet_campaign_binding" == "$integration_campaign_binding" ]] \
    || campaign_binding_ok="no"
  [[ "$lease_campaign_binding" == "$integration_campaign_binding" ]] \
    || campaign_binding_ok="no"
  if [[ "$acceptance_mode" == "accepted" \
      && "$audit_campaign_binding" != "$integration_campaign_binding" ]]; then
    campaign_binding_ok="no"
  fi
  if [[ "$campaign_binding_ok" != "yes" ]]; then
    echo "skip $task_id: accepted artifacts do not belong to the current campaign"
    if [[ "$dry_run" != "yes" ]]; then
      singular_record_recovery \
        "accepted packet/audit campaign binding mismatch for $task_id" \
        "$task_id" "$branch" "re-audit-current-campaign" "origin" \
        "review exact head under the current campaign policy" "origin" || true
      integration_candidate_failed "$task_id" "$head_sha" "$candidate_tree" \
        "$packet_campaign_binding" "campaign-mismatch" "$target_head" \
        "re-audit the exact candidate under the current campaign" || exit 2
      singular_append_event "integration.campaign_mismatch" \
        "accepted work refused across campaign identity" \
        "$(python3 - "$run_id" "$task_id" "$integration_campaign_binding" \
            "$packet_campaign_binding" "$audit_campaign_binding" "$lease_campaign_binding" <<'PY'
import json
import sys
print(json.dumps({
    "runId": sys.argv[1],
    "taskId": sys.argv[2],
    "currentBinding": sys.argv[3],
    "packetBinding": sys.argv[4],
    "auditBinding": sys.argv[5],
    "leaseBinding": sys.argv[6],
}, separators=(",", ":")))
PY
)" || true
    fi
    skipped=$((skipped + 1))
    continue
  fi
  singular_campaign_binding_matches \
    "$packet_campaign_binding" integrate pre-merge || exit 2

  # Branch must exist.
  if ! git -C "$SINGULAR_ROOT" rev-parse --verify --quiet "$branch^{commit}" >/dev/null; then
    echo "skip $task_id: branch missing ($branch)"
    if [[ "$dry_run" != "yes" ]]; then
      singular_record_recovery "integration branch missing for accepted packet" \
        "$task_id" "$branch" "escalate-parked" "origin" "restore branch or supersede accepted packet" "human"
      "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "decide:escalate-parked" \
        --rationale "integration branch missing: $branch; restore the branch or supersede the imported packet" \
        --run "$run_id" --branch "$branch" --authority origin >/dev/null 2>&1 || true
      integration_candidate_failed "$task_id" "$head_sha" "$candidate_tree" \
        "$packet_campaign_binding" "branch-missing" "$target_head" \
        "restore the accepted branch or explicitly supersede the candidate" \
        "$branch_invalidation_key" || exit 2
      singular_append_event "integration.parked" "accepted packet has no integration branch" \
        "$(python3 - "$run_id" "$task_id" "$branch" <<'PY'
import json, sys
run_id, task_id, branch = sys.argv[1:4]
print(json.dumps({"runId": run_id, "taskId": task_id, "branch": branch, "reason": "branch-missing", "action": "escalate-parked"}, separators=(",", ":")))
PY
)"
    fi
    skipped=$((skipped + 1))
    continue
  fi

  actual_head="$(git -C "$SINGULAR_ROOT" rev-parse "$branch")"
  if ! sha_matches "$head_sha" "$actual_head"; then
    echo "skip $task_id: branch head $actual_head != packet headSha $head_sha"
    singular_record_recovery "branch advanced past audited headSha for $task_id" \
      "$task_id" "$branch" "request-human-decision" "origin" "re-audit at current head" "human"
    integration_candidate_failed "$task_id" "$head_sha" "$candidate_tree" \
      "$packet_campaign_binding" "branch-head-changed" "$target_head" \
      "restore the audited head or perform a fresh audit" || exit 2
    skipped=$((skipped + 1))
    continue
  fi

  # Idempotency guard: skip if already merged into the target.
  if git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$head_sha" "$SINGULAR_TARGET_BRANCH" 2>/dev/null; then
    echo "skip $task_id: already merged into $SINGULAR_TARGET_BRANCH"
    singular_append_event "integration.skipped" "branch already integrated" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"already-merged\"}"
    skipped=$((skipped + 1))
    continue
  fi

  eligible=$((eligible + 1))
  singular_integration_status_write \
    "Integrating accepted task $task_id" "Verify and finalize the merge" "$task_id"

  if [[ "$dry_run" == "yes" ]]; then
    echo "eligible: $task_id -> merge $branch ($actual_head) into $SINGULAR_TARGET_BRANCH"
    continue
  fi

  # ---- Verify-before-finalize merge ----
  singular_append_event "integration.started" "integration started" \
    "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"branch\":\"$branch\",\"headSha\":\"$actual_head\",\"target\":\"$SINGULAR_TARGET_BRANCH\"}"

  # The merge/abort pair mutates the main worktree index and shared refs, so it
  # runs under the repo-wide git lock that workers use for their git ops. The
  # gate run below stays OUTSIDE the lock: it can take minutes and holding the
  # lock through it would starve worker commits (lock wait caps at 60s).
  merge_ec=0
  if singular_git_lock_acquire; then
    git -C "$SINGULAR_ROOT" merge --no-ff --no-commit "$actual_head" >/dev/null 2>&1 || merge_ec=$?
    if [[ "$merge_ec" -ne 0 ]]; then
      git -C "$SINGULAR_ROOT" diff --name-only --diff-filter=U >"$run_dir/conflict-$task_id.log" 2>/dev/null || true
      git -C "$SINGULAR_ROOT" merge --abort 2>/dev/null || true
    fi
    singular_git_lock_release
  else
    singular_append_event "integration.failed" "git lock unavailable" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"git-lock-timeout\"}"
    echo "FAILED $task_id: git lock unavailable; retrying next cycle"
    integration_candidate_failed "$task_id" "$head_sha" "$candidate_tree" \
      "$packet_campaign_binding" "git-lock-timeout" "$target_head" \
      "retry integration after the repository lock is available" || exit 2
    failed_integrations=$((failed_integrations + 1)); continue
  fi
  # An integration conflict must not rewrite an already-audited branch in
  # place. A rebase creates a new candidate identity and requires an explicit
  # repair attempt plus fresh audit before this entrypoint can consume it.
  if [[ "$merge_ec" -ne 0 && "${SINGULAR_INTEGRATE_REBASE:-0}" == "1" ]]; then
    echo "  rebase-and-regate refused: accepted candidate requires a fresh repair/audit lifecycle"
  fi
  if [[ "$merge_ec" -ne 0 ]]; then
    action="$(integration_decide "integration-conflict" "$task_id" "$branch" "$run_dir/conflict-$task_id.log")"
    echo "  decider (conflict): ${action:-escalate-parked}"
    git -C "$SINGULAR_ROOT" rebase --abort 2>/dev/null || true
    git -C "$SINGULAR_ROOT" checkout -q "$SINGULAR_TARGET_BRANCH" 2>/dev/null || true
    singular_record_recovery "merge conflict integrating $task_id into $SINGULAR_TARGET_BRANCH" \
      "$task_id" "$branch" "${action:-escalate-parked}" "decider" "fresh conflict resolution with re-audit if branch changes" "origin"
    singular_append_event "integration.failed" "integration merge conflict" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"conflict\",\"action\":\"${action:-escalate-parked}\",\"note\":\"rebase not attempted or failed (SINGULAR_INTEGRATE_REBASE)\"}"
    echo "FAILED $task_id: merge conflict (decider: ${action:-escalate-parked}; rebase not attempted or failed)"
    integration_candidate_failed "$task_id" "$head_sha" "$candidate_tree" \
      "$packet_campaign_binding" "integration-conflict" "$target_head" \
      "repair the conflict in a new attempt and obtain a fresh audit" || exit 2
    failed_integrations=$((failed_integrations + 1)); continue
  fi

  # The task's terminal status is tracked source, so it must be part of the
  # exact staged tree covered by the mandatory integration gate.  Previously
  # this transition happened after the merge commit and silently made the
  # promotion checkout differ from the tree that had passed regression.
  task_file="$SINGULAR_TASKS_DIR/$task_id.md"
  if [[ -f "$task_file" ]]; then
    singular_task_set_status "$task_file" "integrated"
    if singular_git_lock_acquire; then
      task_status_stage_ec=0
      git -C "$SINGULAR_ROOT" add -- "$task_file" || task_status_stage_ec=$?
      singular_git_lock_release
      if [[ "$task_status_stage_ec" -ne 0 ]]; then
        singular_integration_abort_merge "$task_file" HEAD || true
        singular_append_event "integration.failed" "could not stage terminal task status" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"task-status-stage-failed\"}"
        echo "FAILED $task_id: could not stage terminal task status"
        failed_integrations=$((failed_integrations + 1)); continue
      fi
    else
      singular_integration_abort_merge "$task_file" HEAD || true
      singular_append_event "integration.failed" "git lock unavailable while staging terminal task status" \
        "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"git-lock-timeout\"}"
      echo "FAILED $task_id: git lock unavailable while staging task status"
      failed_integrations=$((failed_integrations + 1)); continue
    fi
  fi

  # Freeze the exact staged tree and both intended parents into an unreachable
  # synthetic commit. The mandatory gate runs in a disposable checkout of that
  # object, so unrelated unstaged/control-state bytes in the integration
  # checkout cannot make an uncommitted tree pass. The synthetic object never
  # updates a ref and cannot itself authorize promotion.
  gate_run_id="$run_id-integrate-$task_id"
  gate_run_dir="$SINGULAR_RUNS_DIR/$gate_run_id"
  gate_prepare_log="$run_dir/integration-gate-prepare-$task_id.log"
  mkdir -p "$SINGULAR_STATE_DIR/tmp" "$gate_run_dir"
  : >"$gate_prepare_log"
  integration_gate_setup_ec=0
  integration_gate_setup_reason=""
  tested_tree=""
  tested_parent=""
  tested_merge_head=""
  synthetic_commit=""
  if ! integration_gate_tmp="$(mktemp -d "$SINGULAR_STATE_DIR/tmp/integration-gate.XXXXXX")"; then
    integration_gate_setup_ec=20
    integration_gate_setup_reason="worktree-temp-create-failed"
  else
    integration_gate_worktree="$integration_gate_tmp/worktree"
  fi

  if [[ "$integration_gate_setup_ec" -eq 0 ]]; then
    if singular_git_lock_acquire; then
      if ! tested_tree="$(git -C "$SINGULAR_ROOT" write-tree 2>>"$gate_prepare_log")"; then
        integration_gate_setup_ec=20
        integration_gate_setup_reason="staged-tree-snapshot-failed"
      elif ! tested_parent="$(git -C "$SINGULAR_ROOT" rev-parse --verify HEAD 2>>"$gate_prepare_log")"; then
        integration_gate_setup_ec=20
        integration_gate_setup_reason="integration-parent-snapshot-failed"
      elif ! tested_merge_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify MERGE_HEAD 2>>"$gate_prepare_log")"; then
        integration_gate_setup_ec=20
        integration_gate_setup_reason="merge-parent-snapshot-failed"
      elif ! synthetic_commit="$(
        printf 'singular integration gate %s %s\n' "$run_id" "$task_id" \
          | git -C "$SINGULAR_ROOT" \
              -c user.name="$SINGULAR_GIT_L0_NAME" \
              -c user.email="$SINGULAR_GIT_L0_EMAIL" \
              commit-tree "$tested_tree" -p "$tested_parent" -p "$tested_merge_head" \
              2>>"$gate_prepare_log"
      )"; then
        integration_gate_setup_ec=20
        integration_gate_setup_reason="synthetic-commit-create-failed"
      elif ! git -C "$SINGULAR_ROOT" worktree add --detach -q \
          "$integration_gate_worktree" "$synthetic_commit" >>"$gate_prepare_log" 2>&1; then
        integration_gate_setup_ec=20
        integration_gate_setup_reason="worktree-create-failed"
      else
        integration_gate_worktree_added="yes"
      fi
      singular_git_lock_release
    else
      integration_gate_setup_ec=20
      integration_gate_setup_reason="git-lock-timeout"
    fi
  fi

  if [[ "$integration_gate_setup_ec" -eq 0 ]]; then
    if ! singular_worktree_prepare \
        "$integration_gate_worktree" "" "$SINGULAR_ROOT" "$gate_prepare_log"; then
      integration_gate_setup_ec=20
      integration_gate_setup_reason="worktree-prepare-${SINGULAR_WORKTREE_PREPARE_STAGE:-failed}"
    elif [[ -n "$(git -C "$integration_gate_worktree" status --porcelain=v1 --untracked-files=all 2>>"$gate_prepare_log")" ]]; then
      integration_gate_setup_ec=20
      integration_gate_setup_reason="prepared-worktree-not-clean"
      git -C "$integration_gate_worktree" status --porcelain=v1 --untracked-files=all \
        >>"$gate_prepare_log" 2>&1 || true
    fi
  fi

  if [[ "$integration_gate_setup_ec" -ne 0 ]]; then
    singular_integration_gate_cleanup
    singular_integration_abort_merge "$task_file" "${tested_parent:-HEAD}" || true
    singular_record_recovery \
      "could not create exact-tree integration gate workspace ($integration_gate_setup_reason) for $task_id" \
      "$task_id" "$branch" "escalate-parked" "origin" \
      "disposable gate over the exact staged merge tree" "origin"
    singular_append_event "integration.failed" "integration gate workspace setup failed" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"$integration_gate_setup_reason\"}"
    echo "FAILED $task_id: exact-tree integration gate setup failed ($integration_gate_setup_reason)"
    integration_candidate_failed "$task_id" "$head_sha" "$candidate_tree" \
      "$packet_campaign_binding" "gate-setup-$integration_gate_setup_reason" "$target_head" \
      "retry after the integration gate workspace is available" || exit 2
    failed_integrations=$((failed_integrations + 1))
    continue
  fi

  gate_ec=0
  singular_run_in_worktree_env "$integration_gate_worktree" env \
    SINGULAR_ROOT="$integration_gate_worktree" \
    SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" \
    "$SCRIPT_DIR/gate-check.sh" "$gate_run_id" \
    --task-id "$task_id" --phase integration --workspace-kind integration -- \
    "$(singular_bash_bin)" -c "$gate_cmd" >/dev/null 2>&1 || gate_ec=$?
  if [[ "$gate_ec" -eq 0 ]]; then
    if [[ "$(git -C "$integration_gate_worktree" rev-parse HEAD 2>/dev/null || true)" != "$synthetic_commit" ]] \
        || [[ -n "$(git -C "$integration_gate_worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)" ]]; then
      gate_ec=20
      printf '%s\n' \
        'gate-check: disposable exact-tree worktree changed during the integration gate' \
        >>"$gate_run_dir/gate-check.log"
    fi
  fi
  singular_integration_gate_cleanup
  if [[ "$gate_ec" -ne 0 ]]; then
    if ! singular_integration_abort_merge "$task_file" "$tested_parent"; then
      echo "refuse: integration gate failed and merge cleanup is incomplete" >&2
      exit 2
    fi
    action="$(integration_decide "integration-gate-red" "$task_id" "$branch" "$SINGULAR_RUNS_DIR/$run_id-integrate-$task_id/gate-check.log")"
    singular_record_recovery "post-merge regression gate red (exit $gate_ec) for $task_id" \
      "$task_id" "$branch" "${action:-escalate-parked}" "decider" "green regression on merged tree" "human"
    singular_append_event "integration.failed" "integration gate red" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"gate-red\",\"exitCode\":$gate_ec,\"action\":\"${action:-escalate-parked}\"}"
    echo "FAILED $task_id: post-merge gate red (decider: ${action:-escalate-parked})"
    integration_candidate_failed "$task_id" "$head_sha" "$candidate_tree" \
      "$packet_campaign_binding" "gate-red" "$target_head" \
      "correct the candidate or change a gate dependency before retrying" || exit 2
    failed_integrations=$((failed_integrations + 1))
    continue
  fi

  # The exact staged tree is green, but a long gate is also a window in which
  # the frozen engine/config/prompt policy can change. Re-verify immediately
  # before finalization; on drift abort the uncommitted merge so HEAD remains
  # exactly at the pre-integration parent.
  if ! singular_campaign_binding_matches \
      "$packet_campaign_binding" integrate post-exact-gate; then
    singular_integration_abort_merge "$task_file" "$tested_parent" || {
      echo "refuse: campaign drift and merge cleanup is incomplete" >&2
      exit 2
    }
    echo "refuse: campaign runtime drift after exact-tree gate; merge aborted before commit" >&2
    exit 2
  fi

  # Reacquire the git lock and require the staged tree plus both parents to be
  # byte-for-byte identical to the synthetic commit that passed. Secret scan
  # and commit happen under the same lock so no engine git operation can race
  # between validation and finalization. Project hooks are disabled here: an
  # agent-authored pre-commit hook must not rewrite the tested index.
  finalize_reason=""
  merge_commit=""
  integration_proof_id=""
  if singular_git_lock_acquire; then
    # The pre-lock check above avoids waiting on known drift; this in-lock
    # check closes the wait/commit TOCTOU. It also compares the operation's
    # original opaque binding, so a valid replacement manifest is not allowed
    # to inherit the old audit.
    if ! singular_campaign_lock_acquire; then
      finalize_reason="campaign-publication-lock-timeout"
    else
      integration_campaign_lock_held="yes"
    fi
    if [[ -z "$finalize_reason" ]] && ! singular_campaign_publication_cas \
        "$packet_campaign_binding" integrate pre-commit-locked; then
      finalize_reason="campaign-identity-changed"
    elif [[ -z "$finalize_reason" ]]; then
      current_tree="$(git -C "$SINGULAR_ROOT" write-tree 2>/dev/null || true)"
      current_parent="$(git -C "$SINGULAR_ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
      current_merge_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify MERGE_HEAD 2>/dev/null || true)"
    fi
    if [[ -z "$finalize_reason" ]]; then
      commit_args=(
        --no-edit -q
        -m "integrate($task_id): merge $branch into $SINGULAR_TARGET_BRANCH"
        -m "Worker head: $actual_head"
        -m "Packet: docs/orchestration/packets/imported/$task_id/$run_packet.json"
        -m "Acceptance: $acceptance_mode. Regression gate: green (run $run_id)."
      )
      if [[ "$current_tree" != "$tested_tree" \
          || "$current_parent" != "$tested_parent" \
          || "$current_merge_head" != "$tested_merge_head" ]]; then
        finalize_reason="tested-tree-or-parent-changed"
      elif ! "$SCRIPT_DIR/secret-scan.sh" --worktree "$SINGULAR_ROOT" --staged \
          >"$run_dir/secret-scan-merge-$task_id.log" 2>&1; then
        finalize_reason="secret-detected"
      elif [[ "$candidate_lifecycle_enabled" == "yes" ]] \
          && ! integration_proof_id="$(singular_lifecycle_candidate_tested \
            "$task_id" "$head_sha" "$candidate_tree" "$packet_campaign_binding" \
            "$tested_tree" "$tested_parent" "$tested_merge_head" "$synthetic_commit" \
            "$gate_run_id" "$gate_run_dir/gate-report.json" "$gate_cmd")"; then
        finalize_reason="integration-proof-publication-failed"
      fi
      if [[ -z "$finalize_reason" ]]; then
        [[ -z "$integration_proof_id" ]] \
          || commit_args+=(-m "Integration-Proof: $integration_proof_id")
        if ! git -C "$SINGULAR_ROOT" \
            -c user.name="$SINGULAR_GIT_L0_NAME" \
            -c user.email="$SINGULAR_GIT_L0_EMAIL" \
            -c core.hooksPath=/dev/null \
            commit "${commit_args[@]}"; then
          finalize_reason="merge-commit-failed"
        else
          merge_commit="$(git -C "$SINGULAR_ROOT" rev-parse HEAD 2>/dev/null || true)"
          committed_tree="$(git -C "$SINGULAR_ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
          committed_parents="$(git -C "$SINGULAR_ROOT" rev-list --parents -n 1 HEAD 2>/dev/null || true)"
          if [[ "$committed_tree" != "$tested_tree" \
              || "$committed_parents" != "$merge_commit $tested_parent $tested_merge_head" ]]; then
            finalize_reason="committed-tree-or-parent-mismatch"
          fi
        fi
      fi
    fi
    if [[ "$integration_campaign_lock_held" == "yes" ]]; then
      singular_campaign_lock_release 2>/dev/null || true
      integration_campaign_lock_held="no"
    fi
    singular_git_lock_release
  else
    finalize_reason="git-lock-timeout"
  fi

  if [[ -n "$finalize_reason" ]]; then
    if [[ -z "$merge_commit" ]]; then
      singular_integration_abort_merge "$task_file" "$tested_parent" || {
        echo "refuse: finalization failed and merge cleanup is incomplete" >&2
        exit 2
      }
    fi
    singular_record_recovery \
      "exact-tree integration finalization failed ($finalize_reason) for $task_id" \
      "$task_id" "$branch" "escalate-parked" "origin" \
      "commit with tested tree $tested_tree and parents $tested_parent $tested_merge_head" "human"
    singular_append_event "integration.failed" "exact-tree integration finalization failed" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"$finalize_reason\"}"
    echo "FAILED $task_id: exact-tree integration finalization failed ($finalize_reason)"
    integration_candidate_failed "$task_id" "$head_sha" "$candidate_tree" \
      "$packet_campaign_binding" "finalize-$finalize_reason" "$target_head" \
      "retry after integration finalization infrastructure is repaired" || exit 2
    failed_integrations=$((failed_integrations + 1))
    if [[ -n "$merge_commit" ]]; then
      echo "refuse: committed integration identity mismatch requires operator recovery" >&2
      exit 2
    fi
    continue
  fi

  echo "INTEGRATED $task_id: $branch ($actual_head) -> $SINGULAR_TARGET_BRANCH @ $merge_commit"

  # Finalize durable candidate state immediately after the verified commit.
  # Promotion can be long-running; restart recovery above closes the remaining
  # commit/publication crash window using the durable exact-merge proof.
  if [[ "$candidate_lifecycle_enabled" == "yes" ]]; then
    singular_lifecycle_candidate_integrated "$task_id" "$head_sha" "$candidate_tree" \
      "$packet_campaign_binding" "$merge_commit" "$integration_proof_id" || {
        echo "refuse: merge committed but durable candidate finalization failed for $task_id" >&2
        exit 2
      }
  else
    singular_lease_set_status "$task_id" "integrated" 2>/dev/null || true
  fi

  # Promote before writing any post-integration decision artifacts.  The task
  # status is already part of the tested merge commit, so readiness is true;
  # running here minimizes queue latency. Promotion still runs its own full
  # gate: same-UID cache or caller-provided handoff state is not trusted proof.
  # The post-loop pass remains as an idempotent fallback for custom promoters.
  integrated_node="$(singular_task_node "$task_file" 2>/dev/null || true)"
  if [[ -n "$integrated_node" ]]; then
    integrated_nodes+=("$integrated_node")
    if [[ "${SINGULAR_AUTO_PROMOTE_GATES:-1}" == "1" ]] \
        && singular_node_pending_promotion "$integrated_node" 2>/dev/null; then
      immediate_promotion_attempted["$integrated_node"]=1
      echo "integration: node $integrated_node pending promotion; invoking promoter..."
      promotion_was_passed=0
      singular_authoritative_gate_passed "$integrated_node" && promotion_was_passed=1
      promo_out="$(singular_with_origin_lock_capability \
        "$SCRIPT_DIR/promote-gate.sh" --from-reconcile --if-ready \
        "$integrated_node" 2>&1)" || true
      printf '%s\n' "$promo_out" | sed 's/^/  promotion: /'
      promotion_is_passed=0
      singular_authoritative_gate_passed "$integrated_node" && promotion_is_passed=1
      if [[ "$promotion_was_passed" -eq 0 && "$promotion_is_passed" -eq 1 ]]; then
        gates_promoted_this_run=$((gates_promoted_this_run + 1))
      fi
      singular_append_event "integration.promotion_attempted" "integrate-time gate promotion attempted" \
        "{\"runId\":\"$run_id\",\"node\":\"$integrated_node\"}"
    fi
  fi

  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "integrate" \
    --rationale "merged $branch ($actual_head) into $SINGULAR_TARGET_BRANCH as $merge_commit; gate green; acceptance=$acceptance_mode" \
    --run "$run_id" --branch "$branch" --authority origin || true
  singular_append_event "integration.integrated" "branch integrated" \
    "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"branch\":\"$branch\",\"headSha\":\"$actual_head\",\"mergeCommit\":\"$merge_commit\",\"target\":\"$SINGULAR_TARGET_BRANCH\"}"
  task_file="$SINGULAR_TASKS_DIR/$task_id.md"
  [[ -f "$task_file" ]] && singular_task_set_status "$task_file" "integrated" || true
  integrated_this_run=$((integrated_this_run + 1))
  # Event-driven promotion (0.5.0): remember the node so the post-loop pass
  # can promote it the moment its last task lands, instead of waiting for an
  # empty-queue reconcile cycle that may never coincide (field audit: every
  # gate needed manual promotion).
  # Push the updated target and the worker branch to origin (no-op unless SINGULAR_PUSH=1).
  push_branch "$SINGULAR_TARGET_BRANCH"
  push_branch "$branch"
done

if [[ "$dry_run" == "yes" ]]; then
  integration_status_activity="Integration dry run found $eligible eligible task(s)"
  integration_status_next_action="Review the eligible integration set"
  integration_status_outcome="dry-run"
  echo "eligible=$eligible (dry-run; no merges performed)"
  echo "skipped=$skipped"
  exit 0
fi

# Integrate-time gate promotion (0.5.0, SINGULAR_AUTO_PROMOTE_GATES=1 default):
# for each node whose tasks all just reached a satisfied state and whose gate
# is unpublished, run the configured promoter in non-strict named-node mode.
if [[ "${SINGULAR_AUTO_PROMOTE_GATES:-1}" == "1" && ${#integrated_nodes[@]} -gt 0 ]]; then
  mapfile -t _promo_nodes < <(printf '%s\n' "${integrated_nodes[@]}" | sort -u)
  for _node in "${_promo_nodes[@]}"; do
    [[ -n "$_node" ]] || continue
    [[ -z "${immediate_promotion_attempted[$_node]:-}" ]] || continue
    if singular_node_pending_promotion "$_node" 2>/dev/null; then
      echo "integration: node $_node pending promotion; invoking promoter..."
      promotion_was_passed=0
      singular_authoritative_gate_passed "$_node" && promotion_was_passed=1
      promo_out="$(singular_with_origin_lock_capability \
        "$SCRIPT_DIR/promote-gate.sh" --from-reconcile --if-ready \
        "$_node" 2>&1)" || true
      printf '%s\n' "$promo_out" | sed 's/^/  promotion: /'
      promotion_is_passed=0
      singular_authoritative_gate_passed "$_node" && promotion_is_passed=1
      if [[ "$promotion_was_passed" -eq 0 && "$promotion_is_passed" -eq 1 ]]; then
        gates_promoted_this_run=$((gates_promoted_this_run + 1))
      fi
      singular_append_event "integration.promotion_attempted" "integrate-time gate promotion attempted" \
        "{\"runId\":\"$run_id\",\"node\":\"$_node\"}"
    fi
  done
fi

singular_write_origin_state "$run_id" 2>/dev/null || true
echo "integrated_this_run=$integrated_this_run"
echo "failed_integrations=$failed_integrations"
echo "gates_promoted_this_run=$gates_promoted_this_run"
echo "skipped=$skipped"
singular_append_event "integration.completed" "integration run completed" \
  "{\"runId\":\"$run_id\",\"eligible\":$eligible,\"integratedThisRun\":$integrated_this_run,\"failedIntegrations\":$failed_integrations,\"skipped\":$skipped}"

if [[ "$failed_integrations" -eq 0 ]]; then
  integration_status_activity="Integration completed; $integrated_this_run task(s) merged"
  integration_status_next_action="Continue orchestration"
  integration_status_outcome="integrated-$integrated_this_run"
else
  integration_status_activity="Integration completed with $failed_integrations failure(s)"
  integration_status_next_action="Inspect and repair failed integrations"
  integration_status_outcome="integration-failures-$failed_integrations"
fi
[[ "$failed_integrations" -eq 0 ]]
