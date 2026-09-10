#!/usr/bin/env bash
set -euo pipefail

# Minimal recovery wiring (operating model section 13).
#
#   --scan   (default) Reclassify stale "running" leases and report orphaned
#            worktrees. Non-destructive. Records a recovery event per action.
#   --prune  In addition, remove orphaned worktree working directories whose
#            lease is in a terminal state (accepted/failed/stale/cancelled).
#            Branches are preserved (they may hold accepted commits).
#
# A "stale" lease is one in status running/planned/needs-review whose updatedAt
# is older than SINGULAR_STALE_MINUTES (default 60) and for which no packet is
# awaiting import and none has been imported. Such a task is reclassified rather
# than left to strand a worktree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lifecycle.sh"

mode="scan"
case "${1:-}" in
  --scan|"") mode="scan" ;;
  --prune) mode="prune" ;;
  *) echo "usage: $0 [--scan|--prune]" >&2; exit 2 ;;
esac

singular_ensure_state_dirs
stale_minutes="${SINGULAR_STALE_MINUTES:-60}"
recovery_decider="${SINGULAR_RECOVERY_DECIDER:-$SCRIPT_DIR/decide.sh}"
actions=0
known_orphans=0

# 1. Reclassify stale leases.
if [[ -d "$SINGULAR_LEASES_DIR" ]]; then
  while IFS= read -r lease; do
    [[ -n "$lease" ]] || continue
    if ! python3 - "$lease" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        json.load(f)
except Exception:
    raise SystemExit(1)
PY
    then
      superseded_dir="$SINGULAR_LEASES_DIR/superseded"
      mkdir -p "$superseded_dir"
      dest="$superseded_dir/$(basename "$lease")"
      if [[ -e "$dest" ]]; then
        dest="$superseded_dir/$(basename "$lease" .json).$(singular_timestamp).json"
      fi
      mv "$lease" "$dest"
      echo "recover: quarantined unreadable lease $(basename "$lease")"
      actions=$((actions + 1))
      continue
    fi
    task_id="$(singular_json_field "$lease" taskId 2>/dev/null || true)"
    if [[ -z "$task_id" ]]; then
      task_id="$(basename "$lease" .json)"
    fi
    status="$(singular_json_field "$lease" status 2>/dev/null || true)"
    branch="$(singular_json_field "$lease" branch 2>/dev/null || true)"
    run_id="$(singular_json_field "$lease" runId 2>/dev/null || true)"
    updated="$(singular_json_field "$lease" updatedAt 2>/dev/null || true)"
    case "$status" in running|planned|needs-review) ;; *) continue ;; esac

    task_file="$SINGULAR_TASKS_DIR/$task_id.md"
    # Markdown status is a queue projection, not ownership or acceptance
    # authority. A stale edit must never close another process's reservation.
    if python3 - "$lease" <<'PY' >/dev/null 2>&1
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8")).get("acceptedCandidate")
assert isinstance(c, dict) and c.get("state") != "integrated"
PY
    then
      echo "recover: retained accepted candidate $task_id; action: integrate or authorize repair"
      continue
    fi
    if [[ -z "$(singular_json_field "$lease" reservationGeneration 2>/dev/null || true)" ]] \
        && [[ "$(singular_task_field "$task_file" status 2>/dev/null || true)" == "integrated" ]] \
        && find "$SINGULAR_ORCH_DIR/packets/imported/$task_id" -maxdepth 1 \
          -name '*.json' -not -name '*.audit.json' -type f 2>/dev/null | grep -q .; then
      legacy_sha="$(singular_sha256_file "$lease")"
      if singular_lifecycle_legacy_finish "$task_id" "$legacy_sha" integrated \
          "legacy-integrated-projection" "none"; then
        echo "recover: closed stale lease $task_id from task status integrated"
        actions=$((actions + 1))
        continue
      fi
    fi

    # Skip if a packet for this run is queued for import or already imported.
    if [[ -n "$run_id" && -f "$SINGULAR_INBOX_DIR/$run_id.json" ]]; then
      continue
    fi
    if [[ -n "$task_id" ]] && find "$SINGULAR_ORCH_DIR/packets/imported/$task_id" -name '*.json' -not -name '*.audit.json' -type f 2>/dev/null | grep -q .; then
      continue
    fi

    # Lease age (minutes) feeds both the wall-clock staleness test and the
    # hard-cap override inside the tree-liveness check.
    lease_age_min="$(python3 - "$updated" <<'PY'
import sys
from datetime import datetime, timezone
updated = sys.argv[1]
try:
    t = datetime.fromisoformat(updated.replace("Z", "+00:00"))
    print(int((datetime.now(timezone.utc) - t).total_seconds() // 60))
except Exception:
    print(999999)
PY
)"

    # Tree-aware fast-stale (0.5.0): a launched dispatch record with no exit
    # file is stale only when the whole process TREE is dead (descendants,
    # pgroup, run-id command lines, recent run-dir writes). The 0.4.0
    # root-pid-only check reclaimed leases under live auditors (field audit:
    # accepted work destroyed, then an infinite re-dispatch loop).
    fast_stale="no"
    tree_alive="unknown"
    drec="$(singular_dispatch_record_path "$task_id")"
    reservation_owner="$(singular_json_field "$drec" reservationOwner 2>/dev/null || true)"
    reservation_generation="$(singular_json_field "$drec" reservationGeneration 2>/dev/null || true)"
    reservation_batch="$(singular_json_field "$drec" batchId 2>/dev/null || true)"
    if [[ ! -f "$drec" || -z "$reservation_owner" \
        || ! "$reservation_generation" =~ ^[1-9][0-9]*$ ]]; then
      if [[ "$lease_age_min" -ge "$stale_minutes" ]]; then
        if [[ -z "$(singular_json_field "$lease" reservationGeneration 2>/dev/null || true)" ]]; then
          # Upgrade compatibility: compare-and-set the exact legacy bytes. This
          # cannot authorize a generated reservation and never creates candidate
          # acceptance. A one-way integrated projection additionally requires a
          # retained imported record so Markdown alone is insufficient.
          legacy_sha="$(singular_sha256_file "$lease")"
          dec_out="$("$recovery_decider" --task "$task_id" --failure-class "stale-lease" \
            --branch "$branch" --run "${run_id:-RECOVER}" --worktree "$SINGULAR_ROOT" 2>/dev/null || true)"
          action="$(printf '%s\n' "$dec_out" | sed -n 's/^action=//p' | tail -1)"
          [[ -n "$action" ]] || action="escalate-parked"
          if singular_lifecycle_legacy_finish "$task_id" "$legacy_sha" failed \
              "stale-legacy-lease" "apply recovery decision $action"; then
            case "$action" in
              retry|rerun-tests|rebuild-context|revalidate-evidence)
                [[ -f "$task_file" ]] && singular_task_set_status "$task_file" ready || true ;;
            esac
            singular_append_event "recover.stale_retry_preserved" \
              "legacy stale lease CAS preserved product budget" \
              "{\"taskId\":\"$task_id\",\"runId\":\"${run_id:-}\",\"action\":\"$action\",\"leaseStatus\":\"failed\",\"productBudgetPreserved\":true,\"legacyCasSha256\":\"$legacy_sha\"}" || true
            echo "recover: preserved stale lease $task_id as failed/recoverable for retry (decider: $action)"
            actions=$((actions + 1))
          fi
        else
          echo "recover: $task_id is stale but lacks owner-bound dispatch authority; action: inspect and explicitly supersede or rebind"
        fi
      fi
      continue
    fi
    if [[ -f "$drec" && ! -f "$(singular_dispatch_exit_path "$task_id")" ]] \
      && [[ "$(singular_json_field "$drec" state 2>/dev/null || true)" == "launched" ]]; then
      dpid="$(singular_json_field "$drec" pid 2>/dev/null || true)"
      dpid_start="$(singular_json_field "$drec" pidStart 2>/dev/null || true)"
      dpgid="$(singular_json_field "$drec" pgid 2>/dev/null || true)"
      if singular_dispatch_tree_alive "$task_id" "$dpid" "$dpid_start" "$run_id" "${dpgid:-0}" "$lease_age_min"; then
        tree_alive="yes"
      else
        tree_alive="no"
        fast_stale="yes"
      fi
    fi

    if [[ "$tree_alive" == "yes" ]]; then
      echo "recover: skipped $task_id (process tree still alive)"
      continue
    fi
    if [[ "$fast_stale" == "yes" ]]; then
      is_stale="yes"
      echo "recover: dispatch tree gone for $task_id; treating lease as stale now"
    else
      is_stale="$([[ "$lease_age_min" -ge "$stale_minutes" ]] && echo yes || echo no)"
    fi
    if [[ "$is_stale" == "yes" ]]; then
      # Ask the autonomous decider what to do with the stale task (AI-native; no
      # human halt). retry/rerun/rebuild -> retain the lease as failed and make
      # the task dispatchable.  The lease is the durable product-budget and
      # lineage record: deleting it used to mint a fresh initial pass after
      # every crash. cancel/supersede remain terminal; otherwise park as stale.
      dec_out="$("$recovery_decider" --task "$task_id" --failure-class "stale-lease" \
        --branch "$branch" --run "${run_id:-RECOVER}" --worktree "$SINGULAR_ROOT" 2>/dev/null || true)"
      action="$(printf '%s\n' "$dec_out" | sed -n 's/^action=//p' | tail -1)"
      [[ -n "$action" ]] || action="escalate-parked"
      if ! singular_lifecycle_finish "$task_id" "$reservation_owner" \
          "$reservation_generation" "$reservation_batch" "stale-lease" \
          "apply recovery decision $action"; then
        echo "recover: owner changed for $task_id; stale recovery suppressed"
        continue
      fi
      if [[ "$fast_stale" == "yes" ]]; then
        # Close out only the dispatch generation whose dead tree was observed.
        singular_lifecycle_dispatch_finalize "$task_id" "-1" "crashed" \
          "$reservation_owner" "$reservation_generation" || true
      fi
      case "$action" in
        retry|rerun-tests|rebuild-context|revalidate-evidence)
          [[ -f "$task_file" ]] && singular_task_set_status "$task_file" "ready" || true
          singular_append_event "recover.stale_retry_preserved" \
            "owner-bound stale lease made recoverable without resetting product budget" \
            "{\"taskId\":\"$task_id\",\"runId\":\"${run_id:-}\",\"action\":\"$action\",\"leaseStatus\":\"failed\",\"productBudgetPreserved\":true,\"reservationOwner\":\"$reservation_owner\",\"reservationGeneration\":$reservation_generation}" \
            || true
          echo "recover: preserved stale lease $task_id as failed/recoverable for retry (decider: $action)" ;;
        cancel)
          [[ -f "$task_file" ]] && singular_task_set_status "$task_file" "cancelled" || true
          echo "recover: cancelled stale $task_id" ;;
        supersede)
          [[ -f "$task_file" ]] && singular_task_set_status "$task_file" "superseded" || true
          echo "recover: superseded stale $task_id" ;;
        *)         echo "recover: parked stale lease $task_id (decider: $action)" ;;
      esac
      actions=$((actions + 1))
    fi
  done < <(find "$SINGULAR_LEASES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
fi

# 1b. Stale L1 planning leases (0.5.0, SINGULAR_RECOVER_L1=1): reclassify to
# failed so their nodes re-enter the frontier; =0 restores report-only.
if [[ "${SINGULAR_RECOVER_L1:-1}" == "1" ]]; then
  singular_l1_reclaim_stale
else
  singular_l1_list_stale | while IFS=' ' read -r n s a; do
    [[ -n "$n" ]] && echo "recover: stale l1 lease $n ($s, ${a}m) — report-only (SINGULAR_RECOVER_L1=0)"
  done
fi

# 2. Detect (and optionally prune) orphaned worktrees.
if [[ -d "$SINGULAR_WORKTREES_DIR" ]]; then
  while IFS= read -r wt; do
    [[ -n "$wt" ]] || continue
    [[ -d "$wt" ]] || continue
    task_id="$(basename "$wt")"
    status="$(singular_lease_status "$task_id" 2>/dev/null || echo none)"
    case "$status" in
      running|planned|needs-review|accepted|integration-failed)
        # Active and accepted worktrees are not orphan cleanup targets. An
        # accepted branch remains useful across failed integration and restart.
        continue
        ;;
    esac
    if python3 - "$(singular_lease_path "$task_id")" <<'PY' >/dev/null 2>&1
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8")).get("acceptedCandidate")
assert isinstance(c, dict) and c.get("state") != "integrated"
PY
    then
      continue
    fi
    # Report-once (0.5.0): the field run printed the same ~40 orphaned
    # worktrees on every reconcile cycle for days. Track first/last sight in
    # recover-orphans.json and echo only new paths or status changes.
    orphans_file="$SINGULAR_STATE_DIR/recover-orphans.json"
    if python3 - "$orphans_file" "$wt" "$status" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, wt, status = sys.argv[1:4]
try:
    data = json.load(open(path))
except Exception:
    data = {}
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
entry = data.get(wt)
fresh = entry is None or entry.get("leaseStatus") != status
data[wt] = {"leaseStatus": status,
            "firstSeen": (entry or {}).get("firstSeen", now), "lastSeen": now}
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(data, open(path, "w"), indent=2)
sys.exit(0 if fresh else 1)
PY
    then
      echo "recover: orphaned worktree $wt (lease status: $status)"
    else
      known_orphans=$((known_orphans + 1))
    fi
    # Auto-prune (0.5.0, SINGULAR_AUTO_PRUNE=1, default 0): during --scan,
    # prune only worktrees that are integrated AND merged into the target AND
    # clean — the same predicate singular gc uses.
    if [[ "$mode" == "scan" && "${SINGULAR_AUTO_PRUNE:-0}" == "1" && "$status" == "integrated" ]]; then
      wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
      if [[ -n "$wt_head" ]] \
        && git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$wt_head" "${SINGULAR_TARGET_BRANCH:-HEAD}" 2>/dev/null \
        && [[ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        git -C "$SINGULAR_ROOT" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
        singular_record_recovery "auto-pruned integrated worktree" "$task_id" "n/a" "rebuild-context" "origin" "n/a" "origin"
        echo "recover: auto-pruned integrated worktree $wt"
        actions=$((actions + 1))
        continue
      fi
    fi
    if [[ "$mode" == "prune" ]]; then
      # Only delete the directory after git has released the worktree, so we
      # never leave git tracking a path we already removed.
      removed="no"
      if singular_worktree_registered "$wt"; then
        if git -C "$SINGULAR_ROOT" worktree remove --force "$wt" 2>/dev/null; then
          removed="yes"
        else
          echo "recover: git could not remove worktree $wt; leaving it in place" >&2
        fi
      else
        removed="yes"   # not registered with git; safe to delete directly
      fi
      if [[ "$removed" == "yes" ]]; then
        rm -rf "$wt"
        singular_record_recovery "orphaned worktree pruned" "$task_id" "n/a" "rebuild-context" "origin" "n/a" "origin"
        echo "recover: pruned worktree $wt"
        actions=$((actions + 1))
      fi
    fi
  done < <(find "$SINGULAR_WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

git -C "$SINGULAR_ROOT" worktree prune 2>/dev/null || true
if [[ "${known_orphans:-0}" -gt 0 ]]; then
  echo "recover: $known_orphans known orphaned worktree(s) (report-once; see .singular-state/recover-orphans.json)"
fi
echo "recover ($mode): $actions action(s)"
