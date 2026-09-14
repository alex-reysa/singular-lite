#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile). macOS /bin/bash is 3.2; re-exec under Homebrew bash.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "l1-drive.sh requires bash >= 4 (mapfile); install via 'brew install bash'" >&2
  exit 1
fi

# L1 Area Orchestrator driver (AI-native, self-healing).
#
# Drives ONE ready task: worktree + lease + L2 worker + scope + gate + commit +
# auditor. On any failure it consults the autonomous decider (decide.sh) instead
# of stopping for a human: it auto-fixes and retries (bounded by maxRetries),
# accepts-with-waiver, or records a terminal/parked outcome and moves on. A
# secret-scan guards every commit. An EXIT trap reclassifies a stranded lease.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lifecycle.sh"

# L1 and every provider it launches are outside the L0 origin-lock authority
# boundary. Even a misconfigured parent or direct caller must not turn an
# inherited bearer token into provider-visible ambient authority.
unset SINGULAR_ORIGIN_LOCK_CAPABILITY

# Worker/auditor runner. Defaults to the codex runner; set SINGULAR_RUNNER to a
# drop-in (e.g. claude-run.sh) to dispatch a different CLI. Same flag surface
# and same --output-last-message contract is required of any runner.
SINGULAR_RUNNER_BIN="${SINGULAR_RUNNER:-$SCRIPT_DIR/codex-run.sh}"
audit_runner="$(singular_role_runner auditor "$SINGULAR_RUNNER_BIN")" || exit 78

task_id=""
dry_run="no"
reset="no"
require_audit="${SINGULAR_REQUIRE_AUDIT:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run="yes"; shift ;;
    --reset) reset="yes"; shift ;;
    --no-audit) require_audit="0"; shift ;;
    --task) task_id="$2"; shift 2 ;;
    TASK-*) task_id="$1"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$task_id" ]]; then
  echo "usage: $0 TASK-XXXX [--dry-run] [--reset] [--no-audit]" >&2
  exit 2
fi

# A direct drive is a control-plane mutation entrypoint just like reconcile.
# Verify before run directories, leases, worktrees, or retry accounting exist.
singular_campaign_verify_or_refuse l1-drive entry || exit 2
l1_campaign_binding="$(singular_campaign_binding)" || {
  echo "l1-drive: campaign identity is inconsistent at entry" >&2
  exit 2
}

singular_ensure_state_dirs
singular_require_target_branch

# Honor the kill switch at the dispatch entry point, not only in the loop
# wrappers, so a manual `make orch-drive` cannot dispatch a worker while frozen.
if singular_stop_requested; then
  singular_append_event "l1.frozen" "STOP sentinel present; refusing to dispatch" "{\"taskId\":\"$task_id\"}"
  echo "frozen (STOP sentinel present; $SINGULAR_STOP_FILE); refusing to dispatch $task_id"
  exit 0
fi

task_file="$SINGULAR_TASKS_DIR/$task_id.md"
if [[ ! -f "$task_file" ]]; then
  echo "task file not found: $task_file" >&2
  exit 2
fi

task_json="$(singular_task_json "$task_file")"
tf() { printf '%s' "$task_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d[sys.argv[1]]; print(json.dumps(v) if isinstance(v,(list,dict)) else v)' "$1"; }

area="$(tf area)"
worker_branch="$(tf workerBranch)"
target_branch="$(tf targetBranch)"
test_policy="$(tf testPolicy)"
gate_cmd="$(tf gateCommand)"
[[ -n "$gate_cmd" ]] || gate_cmd="$SINGULAR_DEFAULT_GATE_CMD"
# tests/run.sh treats focused execution after a registry-write denial as
# authorized only when L1 supplies the canonical task selected by the host.
# Keep this invocation identity on the implementer command itself. gate-check
# independently derives the same binding from --task-contract; neither value
# may escape into later frozen-campaign identity checks.
[[ -n "$target_branch" ]] || target_branch="$SINGULAR_TARGET_BRANCH"
dispatch_batch_id="${SINGULAR_DISPATCH_BATCH_ID:-}"
dispatch_base_sha="${SINGULAR_DISPATCH_BASE_SHA:-}"
branch_base=""
packet_base_ref=""

mapfile -t owned_files < <(printf '%s' "$task_json" | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)["ownedFiles"]]')
mapfile -t forbidden_files < <(printf '%s' "$task_json" | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)["forbiddenFiles"]]')

# ---- Host-only task preflight (fail closed BEFORE run_id/lease/worktree) ----
# Absorbs the historical ad-hoc refusals (empty gate command [fail closed: a
# task with no gate command would otherwise run `bash -c ""`, which exits 0 and
# silently passes the regression check], empty owned files) plus the structural
# checks singular_task_preflight enforces. Dry-run keeps its historical exemption
# from the empty-gate refusal only.
preflight_require_gate=1
[[ "$dry_run" == "yes" ]] && preflight_require_gate=0
if ! preflight_reasons="$(singular_task_preflight "$task_json" "$gate_cmd" "$target_branch" "$preflight_require_gate")"; then
  echo "refusing to dispatch $task_id: task preflight failed:" >&2
  printf '%s\n' "$preflight_reasons" >&2
  if [[ "$dry_run" == "yes" ]]; then
    echo "DRY RUN - task would be parked (preflight); no state mutated."
    exit 3
  fi
  preflight_joined="$(printf '%s' "$preflight_reasons" | python3 -c 'import sys; print("; ".join(l.strip() for l in sys.stdin if l.strip()))')"
  preflight_event="$(printf '%s\n' "$preflight_reasons" | python3 -c 'import json,sys
print(json.dumps({"taskId": sys.argv[1], "reasons": [l.strip() for l in sys.stdin if l.strip()]}, separators=(",", ":")))' "$task_id")"
  singular_campaign_lock_acquire || exit 75
  if ! singular_campaign_publication_cas \
      "$l1_campaign_binding" l1-drive preflight-publication; then
    singular_campaign_lock_release 2>/dev/null || true
    exit 2
  fi
  singular_task_set_status "$task_file" "blocked" || true
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
    --rationale "task preflight failed: $preflight_joined" --run "preflight" \
    --branch "$worker_branch" --authority l1 || true
  preflight_event_rc=0
  singular_append_event "l1.preflight_failed" "task preflight failed" "$preflight_event" \
    || preflight_event_rc=$?
  singular_campaign_lock_release || exit 75
  [[ "$preflight_event_rc" -eq 0 ]] || exit "$preflight_event_rc"
  exit 3
fi

run_id="$(singular_worker_run_id)"
authorized_repair_worktree=""
authorized_repair=()
authorized_continuation=()
authorized_continuation_candidate_base=""
lease_path="$(singular_lease_path "$task_id")"
if [[ -f "$lease_path" ]]; then
  mapfile -t authorized_repair < <(python3 - "$lease_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    lease = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(0)
authority = lease.get("recoveryAuthorization")
if not isinstance(authority, dict) or authority.get("action") != "repair":
    raise SystemExit(0)
if authority.get("state") not in {"issued", "claimed", "audit-accepted", "gate-passed"}:
    raise SystemExit(0)
for key in (
    "authorizationId", "successorRunId", "successorBranch", "successorWorktree",
    "predecessorHeadSha", "predecessorTreeSha", "campaignBinding",
):
    print(authority.get(key, ""))
PY
  )
  if [[ "${#authorized_repair[@]}" -eq 7 ]]; then
    [[ "$reset" != "yes" ]] || {
      echo "l1-drive: --reset is forbidden for an authorized repair" >&2
      exit 2
    }
    [[ "${authorized_repair[6]}" == "$l1_campaign_binding" ]] || {
      echo "l1-drive: authorized repair campaign is stale" >&2
      exit 2
    }
    run_id="${authorized_repair[1]}"
    worker_branch="${authorized_repair[2]}"
    authorized_repair_worktree="${authorized_repair[3]}"
    branch_base="${authorized_repair[4]}"
    packet_base_ref="${authorized_repair[4]}"
  fi
  mapfile -t authorized_continuation < <(python3 - "$lease_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    lease = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(0)
authority = lease.get("continuationAuthorization")
if not isinstance(authority, dict) or authority.get("state") != "reserved":
    raise SystemExit(0)
for key in (
    "authorizationId", "campaignBinding", "candidateSourceSha", "integrationTargetSha",
    "engineSourceFingerprint", "branch", "worktree",
    "reservationOwner", "reservationGeneration", "reservationRunId",
):
    print(authority.get(key, ""))
PY
  )
  if [[ "${#authorized_continuation[@]}" -eq 10 ]]; then
    [[ "$reset" != "yes" ]] || {
      echo "l1-drive: --reset is forbidden for an authorized continuation" >&2
      exit 2
    }
    [[ "${authorized_continuation[1]}" == "$l1_campaign_binding" ]] || {
      echo "l1-drive: authorized continuation campaign is stale" >&2
      exit 2
    }
    [[ "${authorized_continuation[4]}" == "$(singular_campaign_engine_source_fingerprint 2>/dev/null || true)" ]] || {
      echo "l1-drive: authorized continuation engine fingerprint is stale" >&2
      exit 2
    }
    [[ "${authorized_continuation[7]}" == "${SINGULAR_RESERVATION_OWNER:-}" \
        && "${authorized_continuation[8]}" == "${SINGULAR_RESERVATION_GENERATION:-}" ]] || {
      echo "l1-drive: continuation reservation owner or generation mismatch" >&2
      exit 2
    }
    worker_branch="${authorized_continuation[5]}"
    authorized_repair_worktree="${authorized_continuation[6]}"
    authorized_continuation_candidate_base="$(singular_lease_field "$task_id" \
      continuationAuthorization.candidateBaseSha 2>/dev/null || true)"
  fi
fi

# Classify a retained accepted checkpoint before selecting a fresh admission
# base. Recognition is deliberately read-only and narrow: the packet marker is
# enough to preserve the checkpoint, but never enough to authorize identities.
# The packet's B/H must still agree exactly with the original host-written lease
# and the retained Git objects before current target ancestry is considered.
accepted_checkpoint_mode=""
accepted_checkpoint_run=""
accepted_checkpoint_packet=""
accepted_checkpoint_base=""
accepted_checkpoint_head=""
accepted_checkpoint_workspace=""
accepted_checkpoint_recognition=""
l1_refuse_recognized_accepted_checkpoint() {
  local reason="$1"
  echo "AWAITING EVIDENCE: $task_id — accepted checkpoint preserved; resume refused ($reason)." >&2
  exit 3
}
if [[ -f "$lease_path" ]]; then
  retained_lease_status="$(singular_lease_status "$task_id" 2>/dev/null || true)"
  retained_lease_run="$(singular_lease_field "$task_id" runId 2>/dev/null || true)"
  if [[ -n "$retained_lease_run" \
      && "$retained_lease_run" != */* \
      && "$retained_lease_run" != *..* ]]; then
    retained_packet="$SINGULAR_RUNS_DIR/$retained_lease_run/packet.json"
    retained_audit="$(singular_audit_record_path "$retained_lease_run")"
    if [[ -f "$retained_packet" ]]; then
      mapfile -d '' -t _accepted_checkpoint_fields < <(
        python3 - "$retained_packet" "$retained_audit" "$retained_lease_status" <<'PY' 2>/dev/null || true
import json
import sys

path, audit_path, lease_status = sys.argv[1:]
packet = None
try:
    value = json.load(open(path, encoding="utf-8"))
    if isinstance(value, dict):
        packet = value
except Exception:
    pass
audit_accepted = False
try:
    audit = json.load(open(audit_path, encoding="utf-8"))
    audit_accepted = isinstance(audit, dict) and audit.get("verdict") == "accepted"
except Exception:
    pass
blockers = packet.get("blockers", []) if isinstance(packet, dict) else None
awaiting = (
    isinstance(packet, dict)
    and packet.get("status") == "blocked"
    and isinstance(blockers, list)
    and any(
        isinstance(item, dict)
        and item.get("class") == "blocked-external"
        and item.get("reason") == "awaiting-evidence"
        and item.get("productAuditVerdict") == "accepted"
        and item.get("consumesProductRepairBudget") is False
        for item in blockers
    )
)
packet_accepted = isinstance(packet, dict) and packet.get("status") == "accepted"
retained = lease_status == "accepted" or audit_accepted or awaiting or packet_accepted
if awaiting:
    mode = "awaiting-evidence"
elif packet_accepted:
    mode = "accepted-existing"
elif retained:
    mode = "invalid-retained"
else:
    raise SystemExit(0)
values = (
    mode,
    packet.get("runId", "") if isinstance(packet, dict) else "",
    packet.get("taskId", "") if isinstance(packet, dict) else "",
    packet.get("branch", "") if isinstance(packet, dict) else "",
    packet.get("workspace", "") if isinstance(packet, dict) else "",
    packet.get("baseRef", "") if isinstance(packet, dict) else "",
    packet.get("headSha", "") if isinstance(packet, dict) else "",
)
encoded = [
    value if isinstance(value, str) else "__invalid_accepted_checkpoint_field__"
    for value in values
]
sys.stdout.buffer.write(b"\0".join(value.encode() for value in encoded) + b"\0")
PY
      )
      if [[ "${#_accepted_checkpoint_fields[@]}" -eq 7 ]]; then
        accepted_checkpoint_mode="${_accepted_checkpoint_fields[0]}"
        accepted_checkpoint_run="${_accepted_checkpoint_fields[1]}"
        accepted_checkpoint_task="${_accepted_checkpoint_fields[2]}"
        accepted_checkpoint_branch="${_accepted_checkpoint_fields[3]}"
        accepted_checkpoint_workspace="${_accepted_checkpoint_fields[4]}"
        accepted_checkpoint_base="${_accepted_checkpoint_fields[5]}"
        accepted_checkpoint_head="${_accepted_checkpoint_fields[6]}"
        accepted_checkpoint_packet="$retained_packet"
        accepted_checkpoint_recognition="packet-or-audit"
      fi
    fi
    retained_audit_accepted="$(python3 - "$retained_audit" <<'PY' 2>/dev/null || true
import json
import sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
    if isinstance(value, dict) and value.get("verdict") == "accepted":
        print("yes")
except Exception:
    pass
PY
)"
    if [[ -z "$accepted_checkpoint_mode" \
        && ( "$retained_lease_status" == "accepted" \
          || "$retained_audit_accepted" == "yes" ) ]]; then
      accepted_checkpoint_mode="invalid-retained"
      accepted_checkpoint_run="$retained_lease_run"
      accepted_checkpoint_recognition="accepted-lease-or-audit"
    fi
  fi
fi
if [[ -n "$accepted_checkpoint_mode" ]]; then
  [[ "${#authorized_continuation[@]}" -ne 10 ]] \
    || l1_refuse_recognized_accepted_checkpoint \
      "accepted-checkpoint-continuation-authority-conflict"
  [[ "$accepted_checkpoint_mode" != "invalid-retained" ]] \
    || l1_refuse_recognized_accepted_checkpoint \
      "accepted-checkpoint-invalid-retained-state"
  retained_lease_base="$(singular_lease_field "$task_id" baseSha 2>/dev/null || true)"
  retained_lease_branch="$(singular_lease_field "$task_id" branch 2>/dev/null || true)"
  retained_lease_worktree="$(singular_lease_field "$task_id" worktree 2>/dev/null || true)"
  [[ "$accepted_checkpoint_run" == "$retained_lease_run" \
      && "$accepted_checkpoint_task" == "$task_id" \
      && "$accepted_checkpoint_branch" == "$worker_branch" \
      && "$retained_lease_branch" == "$worker_branch" ]] \
    || l1_refuse_recognized_accepted_checkpoint "checkpoint-admission-identity-mismatch"
  [[ -n "$accepted_checkpoint_workspace" \
      && -n "$retained_lease_worktree" \
      && "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
          "$accepted_checkpoint_workspace")" \
        == "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
          "$retained_lease_worktree")" ]] \
    || l1_refuse_recognized_accepted_checkpoint "checkpoint-workspace-identity-mismatch"
  [[ -n "$accepted_checkpoint_base" \
      && "$accepted_checkpoint_base" == "$retained_lease_base" ]] \
    || l1_refuse_recognized_accepted_checkpoint "accepted-base-admission-mismatch"
  [[ -z "$dispatch_base_sha" || "$dispatch_base_sha" == "$accepted_checkpoint_base" ]] \
    || l1_refuse_recognized_accepted_checkpoint "accepted-base-override-conflict"
  accepted_checkpoint_resolved_base="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
    "$accepted_checkpoint_base^{commit}" 2>/dev/null || true)"
  accepted_checkpoint_resolved_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
    "$accepted_checkpoint_head^{commit}" 2>/dev/null || true)"
  [[ -n "$accepted_checkpoint_resolved_base" \
      && "$accepted_checkpoint_resolved_base" == "$accepted_checkpoint_base" ]] \
    || l1_refuse_recognized_accepted_checkpoint "accepted-base-invalid"
  [[ -n "$accepted_checkpoint_resolved_head" \
      && "$accepted_checkpoint_resolved_head" == "$accepted_checkpoint_head" ]] \
    || l1_refuse_recognized_accepted_checkpoint "accepted-head-invalid"
  git -C "$SINGULAR_ROOT" merge-base --is-ancestor \
    "$accepted_checkpoint_base" "$accepted_checkpoint_head" >/dev/null 2>&1 \
    || l1_refuse_recognized_accepted_checkpoint "accepted-base-head-lineage-invalid"
  retained_accepted_branch_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
    "$worker_branch^{commit}" 2>/dev/null || true)"
  if [[ -n "$retained_accepted_branch_head" \
      && "$retained_accepted_branch_head" != "$accepted_checkpoint_head" ]]; then
    l1_refuse_recognized_accepted_checkpoint "accepted-head-mismatch"
  fi
  if [[ -d "$accepted_checkpoint_workspace" ]]; then
    retained_accepted_workspace_head="$(git -C "$accepted_checkpoint_workspace" \
      rev-parse HEAD 2>/dev/null || true)"
    [[ "$retained_accepted_workspace_head" == "$accepted_checkpoint_head" ]] \
      || l1_refuse_recognized_accepted_checkpoint "accepted-head-mismatch"
  fi
fi

# Resolve the product base exactly once, before run publication, cleanup, pass
# accounting, or provider work. Scheduler reservation and integration targets
# remain separate lifecycle identities; neither may replace the candidate base.
requested_candidate_base="$dispatch_base_sha"
if [[ "${#authorized_repair[@]}" -eq 7 ]]; then
  requested_candidate_base="${authorized_repair[4]}"
elif [[ "${#authorized_continuation[@]}" -eq 10 ]]; then
  # A continuation's dispatch base is the scheduler reservation on the current
  # target. Its product fork base is the separately authorized candidate base.
  # Treating the former as an override would relabel preserved work whenever
  # the target advanced—the exact distinction this authority record exists for.
  requested_candidate_base="$authorized_continuation_candidate_base"
  [[ -n "$requested_candidate_base" ]] || {
    echo "l1-drive: continuation authority has no candidate base" >&2
    exit 2
  }
elif [[ -n "$accepted_checkpoint_mode" ]]; then
  requested_candidate_base="$accepted_checkpoint_base"
fi
[[ -n "$requested_candidate_base" ]] || requested_candidate_base="$target_branch"
packet_base_ref="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
  "$requested_candidate_base^{commit}" 2>/dev/null)" || {
  echo "l1-drive: admitted base does not resolve to a local commit: $requested_candidate_base" >&2
  exit 2
}
branch_base="$packet_base_ref"

if [[ "${#authorized_continuation[@]}" -eq 10 ]]; then
  continuation_candidate="${authorized_continuation[2]}"
  continuation_integration_target="${authorized_continuation[3]}"
  continuation_reservation_base="$(singular_lease_field "$task_id" reservationBaseSha 2>/dev/null || true)"
  [[ -z "$dispatch_base_sha" || "$dispatch_base_sha" == "$continuation_reservation_base" ]] \
    && git -C "$SINGULAR_ROOT" rev-parse --verify "$continuation_candidate^{commit}" >/dev/null 2>&1 \
    && git -C "$SINGULAR_ROOT" rev-parse --verify "$continuation_integration_target^{commit}" >/dev/null 2>&1 \
    && git -C "$SINGULAR_ROOT" rev-parse --verify "$continuation_reservation_base^{commit}" >/dev/null 2>&1 \
    && git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$packet_base_ref" "$continuation_candidate" \
      >/dev/null 2>&1 \
    && git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$continuation_integration_target" \
      "$continuation_reservation_base" >/dev/null 2>&1 || {
      echo "l1-drive: continuation candidate-base or integration-target lineage is invalid" >&2
      exit 2
    }
elif [[ "${#authorized_repair[@]}" -ne 7 && -z "$accepted_checkpoint_mode" ]]; then
  retained_branch_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
    "$worker_branch^{commit}" 2>/dev/null || true)"
  if [[ -n "$retained_branch_head" ]]; then
    admission_lineage_head="$retained_branch_head"
  else
    admission_lineage_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
      "$target_branch^{commit}" 2>/dev/null)" || {
      echo "l1-drive: target branch does not resolve to a local commit: $target_branch" >&2
      exit 2
    }
  fi
  git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$packet_base_ref" \
    "$admission_lineage_head" >/dev/null 2>&1 || {
      echo "l1-drive: admitted base is not an ancestor of the retained/fresh candidate lineage" >&2
      exit 2
    }
fi
run_dir="$(singular_run_dir "$run_id")"
mkdir -p "$run_dir"
if [[ -n "$accepted_checkpoint_mode" ]]; then
  # Publication provenance is independent of unspent execution authority. A
  # consumed continuation is claimed, so it is intentionally absent from the
  # reserved-only execution selector above; recognition has nevertheless
  # checked this retained packet workspace against the lease already.
  worktree="$accepted_checkpoint_workspace"
else
  worktree="${authorized_repair_worktree:-$SINGULAR_WORKTREES_DIR/$task_id}"
fi
# Product repair and infrastructure recovery are intentionally separate budget
# domains.  `Risk tier:` is optional task metadata, so existing task files are
# ordinary-risk by default.  An operator may override it for one dispatch with
# SINGULAR_TASK_RISK_TIER, or set retryPolicy.defaultRiskTier in repo config.
# Unknown explicit values fail safe to the high-risk policy: they retain the
# stricter audit/gate path and receive at most two bounded product repairs.
retry_policy_json="$(python3 - "$task_file" "$SINGULAR_ROOT/singular.config.json" \
  "${SINGULAR_TASK_RISK_TIER:-}" "${SINGULAR_DEFAULT_RISK_TIER:-}" \
  "${SINGULAR_MAX_RETRIES:-}" <<'PY'
import json
import os
import re
import sys

task_path, config_path, operator_tier, env_default, configured_cap = sys.argv[1:6]
task_tier = ""
try:
    for line in open(task_path, encoding="utf-8"):
        if line.startswith("## "):
            break
        match = re.match(r"^Risk tier:\s*(.*?)\s*$", line, re.I)
        if match:
            task_tier = match.group(1).strip().strip("`")
            break
except OSError:
    pass

config_default = ""
try:
    config = json.load(open(config_path, encoding="utf-8"))
    policy = config.get("retryPolicy", {}) if isinstance(config, dict) else {}
    if isinstance(policy, dict):
        config_default = str(policy.get("defaultRiskTier", "") or "")
except Exception:
    pass

if operator_tier:
    raw, source = operator_tier, "operator-env"
elif task_tier:
    raw, source = task_tier, "task-metadata"
elif env_default:
    raw, source = env_default, "environment-default"
elif config_default:
    raw, source = config_default, "repo-config-default"
else:
    raw, source = "normal", "backward-compatible-default"

token = re.sub(r"[\s_]+", "-", raw.strip().lower())
ordinary = {"low", "normal", "ordinary", "standard"}
high = {"high", "high-risk", "critical"}
if token in ordinary:
    tier, ceiling = "normal", 1
elif token in high:
    tier, ceiling = "high", 2
else:
    tier, ceiling = "high", 2
    source = f"{source}:fail-safe-unknown"

# SINGULAR_MAX_RETRIES remains a backward-compatible *lowering* control, but
# can no longer expand the risk-derived hard ceiling.
try:
    requested = int(configured_cap) if configured_cap != "" else ceiling
except ValueError:
    requested = ceiling
requested = max(0, requested)
maximum = min(ceiling, requested)
print(json.dumps({
    "riskTier": tier,
    "riskSignal": raw,
    "riskSource": source,
    "productRepairMax": maximum,
    "riskCeiling": ceiling,
}, separators=(",", ":")))
PY
)"
risk_tier="$(printf '%s' "$retry_policy_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["riskTier"])')"
risk_signal="$(printf '%s' "$retry_policy_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["riskSignal"])')"
risk_source="$(printf '%s' "$retry_policy_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["riskSource"])')"
max_retries="$(printf '%s' "$retry_policy_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["productRepairMax"])')"
product_repair_max="$max_retries"
review_policy_json=""
review_policy_err="$run_dir/review-policy-effective.err"
if ! review_policy_json="$(python3 "$SCRIPT_DIR/review_policy.py" effective 2>"$review_policy_err")"; then
  echo "l1-drive: review policy is invalid; refusing to run paid work" >&2
  if [[ -s "$review_policy_err" ]]; then
    cat "$review_policy_err" >&2
  fi
  exit 2
fi
review_max_rounds="$(printf '%s' "$review_policy_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["maxReviewRounds"])')"
review_logical_change="$(tf dagNode 2>/dev/null || true)"
review_logical_change="${review_logical_change#\"}"
review_logical_change="${review_logical_change%\"}"
[[ -n "$review_logical_change" && "$review_logical_change" != "null" ]] || review_logical_change="$task_id"
review_bound=$((review_max_rounds - 1))
[[ "$review_bound" -lt 0 ]] && review_bound=0
if [[ "$max_retries" -gt "$review_bound" ]]; then
  max_retries="$review_bound"
fi
singular_append_event "l1.review_policy_bound" \
  "review policy bounded product repair retries" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"logicalChange\":\"$review_logical_change\",\"maxReviewRounds\":$review_max_rounds,\"productRepairMax\":$product_repair_max}" \
  || true
bounded_infra_budget() {
  local requested="${1:-1}"
  [[ "$requested" =~ ^[0-9]+$ ]] || requested=1
  if [[ "$requested" -eq 0 ]]; then printf '0'; else printf '1'; fi
}
worker_infra_max="$(bounded_infra_budget "${SINGULAR_WORKER_INFRA_MAX:-1}")"
audit_infra_max="$(bounded_infra_budget "${SINGULAR_AUDIT_INFRA_MAX:-1}")"
verify_infra_max="$(bounded_infra_budget "${SINGULAR_AUDIT_VERIFY_INFRA_MAX:-1}")"
evidence_infra_max="$(bounded_infra_budget "${SINGULAR_EVIDENCE_INFRA_MAX:-1}")"
product_repairs_used="$(singular_lease_field "$task_id" retryCount 2>/dev/null || true)"
[[ "$product_repairs_used" =~ ^[0-9]+$ ]] || product_repairs_used=0
prior_product_lease="no"
prior_product_lease_status="$(singular_lease_status "$task_id" 2>/dev/null || true)"
prior_product_pass_marker="$(singular_lease_field "$task_id" productPassStarted 2>/dev/null || true)"
if [[ "$prior_product_pass_marker" == "True" || "$prior_product_pass_marker" == "true" ]]; then
  prior_product_lease="yes"
elif [[ "$prior_product_pass_marker" == "False" || "$prior_product_pass_marker" == "false" ]]; then
  # A fresh detached scheduler reservation and `singular unpark` both carry an
  # explicit false marker.  Neither has spent the new lineage's initial pass.
  # A nonzero retry count contradicts that invariant and therefore fails safe
  # to "started" instead of minting budget from malformed durable state.
  if [[ "$product_repairs_used" -eq 0 ]]; then
    prior_product_lease="no"
  else
    prior_product_lease="yes"
  fi
elif [[ -f "$(singular_lease_path "$task_id")" ]]; then
  # Compatibility for pre-marker leases: planned was scheduler-only, and ready
  # + retry zero was the explicit operator reset.  All other legacy states stay
  # conservative so an upgrade cannot regain product budget.
  prior_product_lease="yes"
  if [[ "$product_repairs_used" -eq 0 \
    && ( "$prior_product_lease_status" == "planned" || "$prior_product_lease_status" == "ready" ) ]]; then
    prior_product_lease="no"
  fi
fi
if [[ "$prior_product_lease" == "yes" && "${#authorized_continuation[@]}" -ne 10 ]]; then
  product_passes_remaining=$((max_retries - product_repairs_used))
else
  product_passes_remaining=$((max_retries + 1))
fi
[[ "$product_passes_remaining" -lt 0 ]] && product_passes_remaining=0
if [[ "${#authorized_continuation[@]}" -eq 10 ]]; then
  # This authority contributes exactly one visible worker invocation through
  # its own durable allowance. Preserve every predecessor product counter and
  # suppress the otherwise automatic worker-infrastructure retry.
  product_passes_remaining=1
  worker_infra_max=0
fi
continuation_preparation_failures=0
if [[ "${#authorized_continuation[@]}" -eq 10 ]]; then
  continuation_preparation_failures="$(singular_lease_field "$task_id" \
    continuationAuthorization.preparationFailureCount 2>/dev/null || true)"
  [[ "$continuation_preparation_failures" =~ ^[0-9]+$ ]] \
    || continuation_preparation_failures=0
fi
repo_schema_version="$(python3 - "$SINGULAR_ROOT/singular.config.json" <<'PY' 2>/dev/null || true
import json
import sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("schemaVersion", "") or "")
except Exception:
    pass
PY
)"
audit_write_contract="v0"
audit_write_schema="singular.orchestration.audit-verdict.v0"
audit_write_schema_path="$SINGULAR_SCHEMA_DIR/audit-verdict.v0.schema.json"
if [[ "$repo_schema_version" == "v2" ]]; then
  audit_write_contract="v1"
  audit_write_schema="singular.orchestration.audit-verdict.v1"
  audit_write_schema_path="$SINGULAR_SCHEMA_DIR/audit-verdict.v1.schema.json"
fi
l1_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$l1_pgid" =~ ^[1-9][0-9]*$ ]] || l1_pgid="$$"

l1_status() {
  local phase="$1" state="$2" activity="$3" safe_cancel="$4" next_action="$5"
  local outcome="${6:-}" process_type="${7:-l1-driver}"
  local process_pid="${8:-$$}" process_pgid="${9:-$l1_pgid}"
  local -a args=(
    write --run-id "$run_id" --task-id "$task_id"
    --phase "$phase" --state "$state" --activity "$activity"
    --safe-cancel "$safe_cancel" --next-action "$next_action"
    --process-type "$process_type" --pid "$process_pid"
  )
  [[ -n "$process_pgid" ]] && args+=(--pgid "$process_pgid")
  [[ -n "$outcome" ]] && args+=(--outcome "$outcome")
  "$SCRIPT_DIR/run-status.sh" "${args[@]}" >/dev/null 2>&1 || true
}

l1_status planning active "Assembling task and audit context" true \
  "Prepare the isolated worker workspace"

echo "L1 drive: $task_id (area=$area, policy=$test_policy)"
echo "  worker_branch=$worker_branch  target=$target_branch  base=$branch_base  run=$run_id"
[[ -n "$dispatch_batch_id" ]] && echo "  batch=$dispatch_batch_id"
echo "  owned_files=${owned_files[*]}"
[[ ${#forbidden_files[@]} -gt 0 ]] && echo "  forbidden_files=${forbidden_files[*]}"
echo "  gate_cmd=$gate_cmd  risk_tier=$risk_tier  product_repairs=$max_retries"
singular_append_event "l1.retry_budget_configured" "bounded retry domains configured" \
  "$(python3 - "$task_id" "$run_id" "$risk_tier" "$risk_signal" "$risk_source" \
      "$max_retries" "$worker_infra_max" "$audit_infra_max" "$verify_infra_max" \
      "$evidence_infra_max" "$product_repairs_used" <<'PY'
import json, sys
(task_id, run_id, tier, signal, source, product, worker, audit, verify,
 evidence, used) = sys.argv[1:12]
print(json.dumps({
    "taskId": task_id, "runId": run_id,
    "riskTier": tier, "riskSignal": signal, "riskSource": source,
    "productRepair": {"used": int(used), "max": int(product)},
    "infrastructure": {
        "workerMaxExtraRetriesPerPhase": int(worker),
        "auditorMaxExtraRetriesPerPhase": int(audit),
        "verificationMaxExtraRetriesPerPhase": int(verify),
        "evidenceMaxExtraRetriesPerPhase": int(evidence),
    },
}, separators=(",", ":")))
PY
)"

# ---- L2 base prompt assembly ----
# A project module may append extra worker-contract obligations (generic: none).
export SINGULAR_WORKER_CONTRACT_EXTRA="$(singular_worker_contract_extra "$task_file" "$task_id" 2>/dev/null || true)"
# A project module may redirect the red-evidence log to a task-specific artifact
# (generic: empty -> the prompt keeps its default red log path).
export SINGULAR_WORKER_RED_LOG="$(singular_worker_red_log "$task_file" "$task_id" 2>/dev/null || true)"
l2_prompt="$run_dir/l2-prompt.md"
python3 - "$SINGULAR_ORCH_DIR/prompts/l2-test-first-developer.md" "$l2_prompt" "$task_json" "$run_id" "$packet_base_ref" <<'PY'
import json
import sys

template_path, out_path, task_raw, run_id, base_ref = sys.argv[1:6]
t = json.loads(task_raw)
with open(template_path, "r", encoding="utf-8") as f:
    tmpl = f.read()
import os
owned = t["ownedFiles"]; forbidden = t["forbiddenFiles"]; accept = t["acceptanceCriteria"]
red_log = os.environ.get("SINGULAR_WORKER_RED_LOG") or ".singular-evidence/red.log"
# Extra obligations contributed by an enabled project module (generic: empty).
extra_module_contract = os.environ.get("SINGULAR_WORKER_CONTRACT_EXTRA", "")
if extra_module_contract and not extra_module_contract.endswith("\n"):
    extra_module_contract += "\n"
subs = {
    "[TASK-ID]": t["taskId"], "[BRANCH]": t["workerBranch"], "[TARGET]": t["targetBranch"],
    "[OWNED FILES]": ", ".join(owned) if owned else "(none)",
    "[FORBIDDEN FILES]": "; ".join(forbidden) if forbidden else "(none)",
    "[OBJECTIVE]": t["objective"],
    "[ACCEPTANCE CRITERIA]": "\n".join(f"- {c}" for c in accept) if accept else "(none)",
}
# One substitution pass: inserted task text is data, never another template.
import re
tmpl = re.sub("|".join(re.escape(k) for k in subs), lambda m: subs[m.group()], tmpl)
contract = f"""

---

## Execution Contract For This Run (authoritative)

You run non-interactively in a Codex sandbox selected by L0 for this task. Your
working directory is the worktree for this task.

- Edit ONLY these owned files: {", ".join(owned)}. Out-of-scope edits are rejected.
- Test-first: write `{red_log}` (failing test before impl),
  `.singular-evidence/green.log` (passing after impl), `.singular-evidence/regression.log`
  (`{t['gateCommand'] or '(your gate command)'}`).
{extra_module_contract}- Do NOT run git. Leave changes uncommitted; the L1 driver commits.
- Do NOT broaden architecture beyond the objective.

Your FINAL message MUST be a single JSON object matching the state packet schema
reference `schemas/orchestration/state-packet.v0.schema.json`. Set
schema exactly to "singular.orchestration.state-packet.v0" and include: packetId,
runId "{run_id}", taskId "{t['taskId']}", area "{t['area']}", role "l2-developer",
status "needs-review", baseRef "{base_ref}", branch "{t['workerBranch']}",
headSha "uncommitted", workspace (abs worktree path), ownedFiles {json.dumps(owned)},
changedFiles, commands[{{cmd,exitCode,logRef}}], tests[{{name,phase,status,logRef}}]
with red+green phases, evidence[{{kind,ref}}], blockers[], nextAction, createdAt.
Every commands[].cmd value MUST contain only the exact executable shell text
that was run. The host re-executes successful commands verbatim. Put attempt
labels, pass/fail counts, result summaries, and explanations in the command's
optional rationale or in evidence[], never append them to cmd. For example,
cmd may be "bun test path/to/test.ts"; it must not be
"bun test path/to/test.ts (attempt-2 green: 40 pass, 0 fail)".
No additional top-level fields are permitted. Do not emit `risks`; put any
unresolved blocking condition in blockers[] and any non-blocking note in
nextAction. Emit ONLY that JSON object.
"""
advisory = t.get("planCritique") or []
if advisory:
    contract += (
        "\n## Plan critique (advisory, recorded before dispatch)\n\n"
        "The plan critic recorded these findings about this task. Address each one "
        "within your owned files, or state in the packet's nextAction why it does "
        "not apply. They do not widen your scope.\n\n"
        + "\n".join(f"- {item}" for item in advisory) + "\n"
    )
with open(out_path, "w", encoding="utf-8") as f:
    complete = tmpl + contract + "\n\n## Complete task contract (mandatory)\n\n" + t.get("taskDocument", "")
    if len(complete.encode("utf-8")) > 262144:
        raise SystemExit("mandatory task prompt exceeds 262144-byte limit")
    f.write(complete)
PY

# ---- Auditor prompt assembly ----
audit_prompt="$run_dir/auditor-prompt.md"
python3 - "$SINGULAR_ORCH_DIR/prompts/auditor.md" "$audit_prompt" "$task_json" "$run_id" \
  "$run_dir" "$SCRIPT_DIR" "$audit_write_contract" <<'PY'
import json
import sys
template_path, out_path, task_raw, run_id, run_dir, script_dir, audit_contract = sys.argv[1:8]
t = json.loads(task_raw)
with open(template_path, "r", encoding="utf-8") as f:
    tmpl = f.read().replace("[TASK-ID]", t["taskId"])
forbidden = ", ".join(t["forbiddenFiles"]) if t["forbiddenFiles"] else "(none)"
if audit_contract == "v1":
    verdict_contract = f"""Your FINAL message MUST be a single JSON object matching
`schemas/orchestration/audit-verdict.v1.schema.json`: schema
"singular.orchestration.audit-verdict.v1", taskId "{t['taskId']}", runId
"{run_id}", branch "{t['workerBranch']}", verdict
(accepted|needs-fix|blocked|needs-human), evidenceReviewed[],
verificationResults[{{status, command, evidenceRefs, rationale}}], commandsRun[],
findings[], requiredFixes[], rationale. Every verificationResults[] object MUST
contain all four required members: status (passed|failed-product|
inconclusive-infrastructure|not-rerun-evidence-verified), command (non-empty
string), evidenceRefs (array of non-empty strings), and rationale (non-empty
string). It MAY also contain integer exitCode. No other verification-result
members are permitted. Reproduce the host gate classification and never turn
an infrastructure limitation into a product finding. classifiedFindings[] is
required for every finding: each item is {{id, severity, summary}} with
severity P0|P1|P2|P3. P0 is an exploitable or data-loss defect that must
block merge. P1 is a correctness or contract break that must block merge.
P2 is a non-blocking defect. P3 is a nit, style note, or suggestion. P0/P1
items MUST also carry non-blank trigger, impact, and requirement. findings[]
and requiredFixes[] strings MUST correspond to classified items. The host
records P2/P3 as non-blocking backlog; do not emit reviewPolicy (host-owned).
No additional top-level fields are permitted except optional findingsStatus
and classifiedFindings. Emit ONLY that JSON object."""
else:
    verdict_contract = f"""Your FINAL message MUST be a single JSON object matching
`schemas/orchestration/audit-verdict.v0.schema.json`: schema
"singular.orchestration.audit-verdict.v0", taskId "{t['taskId']}", runId
"{run_id}", branch "{t['workerBranch']}", verdict
(accepted|needs-fix|blocked|needs-human), evidenceReviewed[], commandsRun[],
findings[], requiredFixes[], rationale. Reproduce the host gate classification
in the rationale and never turn an infrastructure limitation into a product
finding. Emit ONLY that JSON object."""
contract = f"""

---

## Audit Context For This Run (authoritative)

- Task: {t['taskId']} ({t['area']}); worker branch {t['workerBranch']} (committed)
- Owned files: {", ".join(t['ownedFiles'])}
- Forbidden files (must NOT be modified): {forbidden}
- Compact evidence manifest: {run_dir}/evidence-manifest.json
- Host verification report: {run_dir}/audit-verification.json
- To inspect one raw artifact declared by the manifest, use only:
  `{script_dir}/evidence-show.sh {run_dir}/evidence-manifest.json <artifact-ref> [max-bytes] [byte-offset]`

Read-only. The host has already verified the committed gate: either by
rerunning it in a disposable writable worktree at the exact committed head with
isolated caches, or by hash-binding the worker's own gate evidence to that head.
The Host Verification Binding section at the end of this prompt states which.
Do not rerun tests in the original worktree. Start from the compact manifest
and fetch a bounded raw artifact only for a named finding; do not bulk-read raw
evidence. Verify scope, red/green evidence, and acceptance criteria. Do NOT
approve without evidence.

{verdict_contract}
"""
advisory = t.get("planCritique") or []
if advisory:
    contract += (
        "\n## Plan critique (advisory, recorded before dispatch)\n\n"
        "The plan critic recorded these findings about this task before it was "
        "dispatched. Check that the worker addressed each one or explicitly declined "
        "it in the packet's nextAction. An ignored should-fix finding inside the "
        "owned files is a finding; a note never blocks.\n\n"
        + "\n".join(f"- {item}" for item in advisory) + "\n"
    )
with open(out_path, "w", encoding="utf-8") as f:
    complete = tmpl + contract + "\n\n## Complete task contract (mandatory)\n\n" + t.get("taskDocument", "")
    if len(complete.encode("utf-8")) > 262144:
        raise SystemExit("mandatory task prompt exceeds 262144-byte limit")
    f.write(complete)
PY

if [[ "$dry_run" == "yes" ]]; then
  echo ""
  echo "DRY RUN — no worktree, no codex, no commit. Prompts assembled at $run_dir."
  singular_append_event "l1.dry_run" "l1 drive dry run" "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
  l1_status terminal completed "Dry-run context assembly completed" true \
    "No action required" "dry-run"
  exit 0
fi

# Selection is read-only for dry runs. A real repair launch claims and
# revalidates host authority before touching its branch or worktree. A partial
# continuation is claimed atomically with its started-attempt disposition at
# the provider invocation boundary below. No provider process starts before
# either recovery authority is claimed.
if [[ "${#authorized_repair[@]}" -eq 7 && -z "$accepted_checkpoint_mode" ]]; then
  singular_lifecycle_claim_repair "$task_id" "${authorized_repair[0]}" \
    "${authorized_repair[1]}" "${authorized_repair[4]}" "${authorized_repair[5]}" \
    >/dev/null || exit 2
fi

# ---- Outcome tracking + EXIT trap ----
_l1_outcome="incomplete"
_l1_lease_written="no"
_l1_campaign_lock_held="no"
_l1_git_lock_held="no"
l1_record_attempt() {
  local state="$1" disposition="${2:-}" failure_class="${3:-}" action="${4:-}"
  if [[ -z "${SINGULAR_RESERVATION_OWNER:-}" \
      || ! "${SINGULAR_RESERVATION_GENERATION:-}" =~ ^[1-9][0-9]*$ ]]; then
    return 0
  fi
  singular_lifecycle_record_attempt "$task_id" "$SINGULAR_RESERVATION_OWNER" \
    "$SINGULAR_RESERVATION_GENERATION" "$run_id" "$state" \
    "$disposition" "$failure_class" "$action"
}
l1_campaign_publication_end() {
  if [[ "$_l1_campaign_lock_held" == "yes" ]]; then
    if singular_campaign_lock_release; then
      _l1_campaign_lock_held="no"
      return 0
    fi
    return 1
  fi
  return 0
}
l1_campaign_publication_begin() {
  local expected="$1" phase="$2"
  if [[ "$_l1_campaign_lock_held" == "yes" ]]; then
    singular_campaign_publication_cas "$expected" l1-drive "$phase"
    return $?
  fi
  singular_campaign_lock_acquire || return $?
  _l1_campaign_lock_held="yes"
  if singular_campaign_publication_cas "$expected" l1-drive "$phase"; then
    return 0
  fi
  l1_campaign_publication_end 2>/dev/null || true
  return 2
}
l1_git_campaign_publication_begin() {
  local expected="$1" phase="$2" rc=0
  singular_git_lock_acquire || return $?
  _l1_git_lock_held="yes"
  l1_campaign_publication_begin "$expected" "$phase" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if singular_git_lock_release; then
      _l1_git_lock_held="no"
    else
      return 75
    fi
    return "$rc"
  fi
  return 0
}
l1_git_campaign_publication_end() {
  l1_campaign_publication_end || return $?
  if [[ "$_l1_git_lock_held" == "yes" ]]; then
    if singular_git_lock_release; then
      _l1_git_lock_held="no"
    else
      return 1
    fi
  fi
  return 0
}
l1_campaign_mismatch_exit() {
  local reason="$1"
  _l1_outcome="campaign-mismatch"
  l1_record_attempt terminal campaign-mismatch campaign-mismatch \
    re-audit-current-campaign 2>/dev/null || true
  singular_record_recovery "$reason" \
    "$task_id" "$worker_branch" "re-audit-current-campaign" "origin" \
    "review exact head under the current campaign policy" "origin" || true
  singular_append_event "l1.campaign_mismatch" \
    "l1 preserved artifacts without publishing across campaign identity" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}" || true
  echo "l1-drive: campaign identity changed; artifacts preserved and re-audit required" >&2
  exit 2
}
l1_on_exit() {
  local code=$?
  local exit_publication_safe="no"
  # Keep an already-held publication lock through terminal bookkeeping. When
  # an unexpected exit strands a written lease, reacquire and compare the
  # campaign binding before changing any shared task/lease/recovery state.
  if [[ "$_l1_campaign_lock_held" == "yes" ]]; then
    if singular_campaign_publication_cas \
        "$l1_campaign_binding" l1-drive exit-trap-publication; then
      exit_publication_safe="yes"
    else
      _l1_outcome="campaign-mismatch"
    fi
  elif [[ "$_l1_outcome" == "accept-pending" \
      || ( "$_l1_outcome" == "incomplete" && "$_l1_lease_written" == "yes" ) ]]; then
    if l1_campaign_publication_begin \
        "$l1_campaign_binding" exit-trap-publication; then
      exit_publication_safe="yes"
    else
      _l1_outcome="campaign-mismatch"
    fi
  fi
  if [[ "$_l1_outcome" != "accepted" && "$_l1_outcome" != "terminal" ]]; then
    l1_status terminal failed "L1 driver exited before a durable terminal handoff" true \
      "Inspect the run artifacts and recovery record" "exit-$code"
  fi
  if [[ "$_l1_outcome" == "campaign-mismatch" ]]; then
    : # Old-campaign work may not mutate task/lease state during replacement.
  elif [[ "$_l1_outcome" == "accept-pending" && "$exit_publication_safe" == "yes" ]]; then
    # Audit ACCEPTED but the driver died before inbox placement. Never fail
    # the lease — the committed branch + packet + audit record are intact and
    # the next dispatch self-heals via accept-existing-packet (0.4.0 marked
    # the lease failed here, orphaning accepted work behind an exit-2
    # re-dispatch loop).
    singular_record_recovery "accepted work stranded before inbox placement; next dispatch auto-heals via accept-existing-packet" \
      "$task_id" "$worker_branch" "accept-existing-packet" "origin" "auto-heal on next dispatch" "origin" || true
    singular_append_event "l1.accept_interrupted" "l1 drive died between acceptance and inbox placement" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"code\":$code}" || true
  elif [[ "$_l1_outcome" == "incomplete" && "$_l1_lease_written" == "yes" \
      && "$exit_publication_safe" == "yes" ]]; then
    singular_lease_set_status "$task_id" "failed" 2>/dev/null || true
    singular_record_recovery "l1-drive exited before a terminal outcome (code $code)" \
      "$task_id" "$worker_branch" "rebuild-context" "origin" "rerun or decide" "origin" || true
    singular_append_event "l1.aborted" "l1 drive aborted" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"code\":$code}" || true
  fi
  l1_campaign_publication_end 2>/dev/null || true
  if [[ "$_l1_git_lock_held" == "yes" ]]; then
    singular_git_lock_release 2>/dev/null || true
    _l1_git_lock_held="no"
  fi
}
trap l1_on_exit EXIT
l1_status implementing active "Preparing the isolated worker workspace" false \
  "Run the implementer after bootstrap"

# ---- Worktree lifecycle: reset / orphan auto-recovery ----
remove_worktree() {
  if singular_worktree_registered "$worktree"; then
    git -C "$SINGULAR_ROOT" worktree remove --force "$worktree" 2>/dev/null || true
  fi
  rm -rf "$worktree"
  git -C "$SINGULAR_ROOT" worktree prune 2>/dev/null || true
}

l1_candidate_inspect() {
  local inspect_dir="$1" committed_json status_file ignored_file
  committed_json="$(python3 "$SCRIPT_DIR/git_changes.py" --worktree "$inspect_dir" \
    --base "$packet_base_ref" --head HEAD 2>"$run_dir/admission-lineage.log")" || return 2
  L1_CANDIDATE_COMMITTED="$([[ "$committed_json" == "[]" ]] && printf no || printf yes)"
  status_file="$run_dir/admission-status.z"
  if ! git -C "$inspect_dir" status --porcelain=v1 -z --untracked-files=all \
      >"$status_file" 2>>"$run_dir/admission-lineage.log"; then
    return 2
  fi
  L1_CANDIDATE_DIRTY="$([[ -s "$status_file" ]] && printf yes || printf no)"
  ignored_file="$run_dir/admission-ignored-paths.z"
  if ! git -C "$inspect_dir" ls-files --others --ignored --exclude-standard -z \
      >"$ignored_file" 2>>"$run_dir/admission-lineage.log"; then
    return 2
  fi
  L1_CANDIDATE_IGNORED="$([[ -s "$ignored_file" ]] && printf yes || printf no)"
  if [[ "$L1_CANDIDATE_COMMITTED" == yes || "$L1_CANDIDATE_DIRTY" == yes \
      || "$L1_CANDIDATE_IGNORED" == yes ]]; then
    L1_CANDIDATE_USEFUL=yes
  else
    L1_CANDIDATE_USEFUL=no
  fi
}

l1_candidate_admission_checks() {
  local inspect_dir="$1" scope_rc=0 secret_rc=0
  local -a admission_scope=(--worktree "$inspect_dir" --base "$packet_base_ref")
  local f
  for f in "${owned_files[@]}"; do admission_scope+=(--allow-prefix "$f"); done
  for f in "${forbidden_files[@]}"; do admission_scope+=(--forbid-prefix "$f"); done
  "$SCRIPT_DIR/scope-check.sh" "${admission_scope[@]}" \
    >"$run_dir/admission-scope-check.log" 2>&1 || scope_rc=$?
  "$SCRIPT_DIR/secret-scan.sh" --worktree "$inspect_dir" --base "$packet_base_ref" \
    >"$run_dir/admission-secret-scan.log" 2>&1 || secret_rc=$?
  [[ "$scope_rc" -eq 0 && "$secret_rc" -eq 0 ]]
}

l1_preserve_candidate() {
  local from="$1" reason="$2" retained head branch
  retained="$SINGULAR_STATE_DIR/retained-worktrees/${task_id}-${run_id}"
  [[ ! -e "$retained" ]] || {
    echo "l1-drive: retained candidate destination already exists: $retained" >&2
    return 2
  }
  mkdir -p "$(dirname "$retained")"
  head="$(git -C "$from" rev-parse HEAD 2>/dev/null)" || return 2
  branch="$(git -C "$from" branch --show-current 2>/dev/null || true)"
  # Ask Git to move the linked worktree directly. Path spelling may differ on
  # platforms where /var resolves through /private/var, so an exact textual
  # worktree-list membership check is not a sound ownership test here.
  git -C "$SINGULAR_ROOT" worktree move "$from" "$retained" || return 2
  if [[ -n "$branch" ]]; then
    git -C "$retained" checkout -q --detach "$head" || return 2
  fi
  python3 - "$run_dir/retained-candidate.json" "$task_id" "$run_id" "$from" \
      "$retained" "$head" "$branch" "$packet_base_ref" "$reason" <<'PY'
import json, os, sys
(path, task, run, original, retained, head, branch, base, reason) = sys.argv[1:]
value = {"schema": "singular.orchestration.retained-candidate.v0", "taskId": task,
         "runId": run, "originalWorktree": original, "retainedWorktree": retained,
         "headSha": head, "branch": branch, "admittedBaseSha": base, "reason": reason}
with open(path + ".tmp", "w", encoding="utf-8") as stream:
    json.dump(value, stream, indent=2, sort_keys=True); stream.write("\n")
os.replace(path + ".tmp", path)
PY
  singular_append_event "l1.candidate_preserved" \
    "useful unaccepted candidate preserved before canonical reprovisioning" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$head\",\"admittedBaseSha\":\"$packet_base_ref\",\"retainedWorktree\":\"$retained\",\"reason\":\"$reason\"}" || true
}

# Resume publication for an immutable head whose product audit was already
# accepted but whose final evidence materialization exhausted its transient
# infrastructure budget.  This recovery runs before --reset/orphan cleanup so
# neither the accepted branch nor its worktree can be destroyed.  It never
# invokes a worker, gate, auditor, decider, or product-pass marker.
l1_try_resume_accepted_awaiting_evidence() {
  [[ "${SINGULAR_RESUME_ACCEPTED_EVIDENCE:-1}" == "1" ]] || return 1
  local lease_status accepted_run accepted_run_dir accepted_packet accepted_audit
  local accepted_base accepted_head actual_branch_head actual_workspace_head audit_schema
  local accepted_lease_base accepted_resolved_base accepted_resolved_head
  local checkpoint_binding audit_binding lease_binding publication_state authority_state
  local checkpoint_packet_json allowed_historical_run=""
  local publication_needs_evidence="no"
  local -a _checkpoint_bindings=()
  [[ -n "$accepted_checkpoint_mode" ]] || return 1
  lease_status="$(singular_lease_status "$task_id" 2>/dev/null || true)"
  [[ "$lease_status" == "blocked" || "$lease_status" == "failed" \
      || "$lease_status" == "accepted" || "$lease_status" == "integrated" ]] \
    || l1_refuse_recognized_accepted_checkpoint "accepted-lease-status-invalid"
  accepted_run="$accepted_checkpoint_run"
  [[ -n "$accepted_run" ]] || return 1
  accepted_run_dir="$SINGULAR_RUNS_DIR/$accepted_run"
  accepted_packet="$accepted_run_dir/packet.json"
  accepted_audit="$(singular_audit_record_path "$accepted_run")"
  [[ -f "$accepted_packet" ]] || return 1

  # Recognition has already fenced cleanup. Determine which producer-created
  # publication transition was retained without treating recognition as
  # acceptance authority.
  if ! python3 - "$accepted_packet" "$task_id" "$accepted_checkpoint_mode" <<'PY' >/dev/null 2>&1
import json, sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
assert packet.get("taskId") == sys.argv[2]
mode = sys.argv[3]
if mode == "awaiting-evidence":
    assert packet.get("status") == "blocked"
    assert isinstance(packet.get("blockers"), list)
    assert any(
        isinstance(item, dict)
        and item.get("class") == "blocked-external"
        and item.get("reason") == "awaiting-evidence"
        and item.get("productAuditVerdict") == "accepted"
        and item.get("consumesProductRepairBudget") is False
        for item in packet["blockers"]
    )
elif mode == "accepted-existing":
    assert packet.get("status") == "accepted"
else:
    raise AssertionError(mode)
PY
  then
    l1_refuse_recognized_accepted_checkpoint "accepted-checkpoint-shape-invalid"
  fi
  [[ "$accepted_checkpoint_mode" != "awaiting-evidence" ]] \
    || publication_needs_evidence="yes"
  checkpoint_binding="$(python3 - "$accepted_packet" <<'PY' 2>/dev/null || true
import json
import sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
for item in packet.get("evidence", []):
    if isinstance(item, dict) and item.get("kind") == "campaign-binding":
        print(item.get("ref", ""))
        break
PY
)"
  if [[ -z "$checkpoint_binding" && "$l1_campaign_binding" == "legacy" ]]; then
    checkpoint_binding="legacy"
  fi
  [[ -n "$checkpoint_binding" && "$checkpoint_binding" == "$l1_campaign_binding" ]] \
    || l1_refuse_recognized_accepted_checkpoint \
      "accepted-checkpoint-campaign-mismatch"
  l1_evidence_resume_refuse() {
    local reason="$1"
    if ! l1_campaign_publication_begin \
        "$checkpoint_binding" "evidence-resume-refusal-$reason"; then
      l1_campaign_mismatch_exit \
        "campaign identity changed while refusing an evidence checkpoint"
    fi
    _l1_outcome="terminal"
    singular_append_event "l1.accepted_evidence_resume_refused" \
      "accepted evidence checkpoint failed closed and was preserved" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$accepted_run\",\"resumeRunId\":\"$run_id\",\"reason\":\"$reason\",\"productAccepted\":true,\"published\":false,\"consumesProductRepairBudget\":false}" \
      || true
    l1_status terminal failed "Accepted evidence checkpoint could not be safely resumed" true \
      "Inspect the checkpoint mismatch; do not rerun or delete product work" "awaiting-evidence"
    echo "AWAITING EVIDENCE: $task_id — accepted checkpoint preserved; resume refused ($reason)." >&2
    exit 3
  }

  [[ -f "$accepted_audit" ]] \
    || l1_evidence_resume_refuse "accepted-audit-missing"
  [[ -d "$worktree" ]] \
    || l1_evidence_resume_refuse "accepted-worktree-missing"
  git -C "$SINGULAR_ROOT" rev-parse --verify --quiet "$worker_branch" >/dev/null \
    || l1_evidence_resume_refuse "accepted-branch-missing"

  # A generic blocked packet never reaches this point and cannot borrow audit
  # authority. The recognized checkpoint must now bind every exact identity.
  if ! python3 - "$accepted_packet" "$accepted_audit" "$task_id" "$accepted_run" \
      "$worker_branch" "$worktree" <<'PY' >/dev/null 2>&1
import json
import os
import sys

packet_path, audit_path, task_id, run_id, branch, worktree = sys.argv[1:7]
packet = json.load(open(packet_path, encoding="utf-8"))
audit = json.load(open(audit_path, encoding="utf-8"))
head = packet.get("headSha", "")
assert packet.get("taskId") == task_id
assert packet.get("runId") == run_id
assert packet.get("branch") == branch
assert os.path.realpath(packet.get("workspace", "")) == os.path.realpath(worktree)
assert packet.get("status") in {"blocked", "accepted"}
assert head
assert audit.get("taskId") == task_id
assert audit.get("verdict") == "accepted"
assert audit.get("branch") == branch
if packet.get("status") == "blocked":
    assert any(
        isinstance(item, dict)
        and item.get("class") == "blocked-external"
        and item.get("reason") == "awaiting-evidence"
        and item.get("headSha") == head
        and item.get("productAuditVerdict") == "accepted"
        and item.get("consumesProductRepairBudget") is False
        for item in packet.get("blockers", [])
    )
PY
  then
    l1_evidence_resume_refuse "checkpoint-identity-mismatch"
  fi
  singular_validate_packet_basic "$accepted_packet" >/dev/null 2>&1 \
    || l1_evidence_resume_refuse "checkpoint-packet-invalid"
  checkpoint_packet_json="$(python3 - "$accepted_packet" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.dumps(json.load(handle), separators=(",", ":")))
PY
  )" || l1_evidence_resume_refuse "checkpoint-packet-invalid"
  singular_json_schema_check "$checkpoint_packet_json" "$SINGULAR_PACKET_SCHEMA" \
    "accepted publication packet" >/dev/null 2>&1 \
    || l1_evidence_resume_refuse "checkpoint-packet-schema-invalid"
  python3 - "$SCRIPT_DIR" "$accepted_packet" "$task_json" <<'PY' >/dev/null 2>&1 \
    || l1_evidence_resume_refuse "checkpoint-task-ownership-mismatch"
import json
import sys
sys.path.insert(0, sys.argv[1])
from git_changes import require_scope_membership

packet = json.load(open(sys.argv[2], encoding="utf-8"))
task = json.loads(sys.argv[3])
assert packet.get("ownedFiles") == task.get("ownedFiles")
changed = packet.get("changedFiles")
assert isinstance(changed, list) and all(isinstance(path, str) for path in changed)
require_scope_membership(changed, task.get("ownedFiles", []), task.get("forbiddenFiles", []))
PY
  audit_schema="$(singular_json_field "$accepted_audit" schema 2>/dev/null || true)"
  if [[ "$audit_schema" == "singular.orchestration.audit-verdict.v1" ]]; then
    SINGULAR_AUDIT_SCHEMA="$SINGULAR_SCHEMA_DIR/audit-verdict.v1.schema.json" \
      singular_validate_audit_verdict "$accepted_audit" "$task_id" "$accepted_run" \
      >/dev/null 2>&1 || l1_evidence_resume_refuse "accepted-audit-invalid"
  else
    singular_validate_audit_verdict "$accepted_audit" "$task_id" "$accepted_run" \
      >/dev/null 2>&1 || l1_evidence_resume_refuse "accepted-audit-invalid"
  fi

  mapfile -t _checkpoint_bindings < <(
    python3 - "$accepted_packet" "$accepted_audit" \
      "$(singular_lease_path "$task_id")" <<'PY' 2>/dev/null
import json
import sys

packet_path, audit_path, lease_path = sys.argv[1:4]
packet = json.load(open(packet_path, encoding="utf-8"))
audit = json.load(open(audit_path, encoding="utf-8"))
lease = json.load(open(lease_path, encoding="utf-8"))
packet_binding = next((
    str(item.get("ref", "")) for item in packet.get("evidence", [])
    if isinstance(item, dict) and item.get("kind") == "campaign-binding"
), "")
audit_binding = next((
    str(item)[len("campaign-binding:"):]
    for item in audit.get("evidenceReviewed", [])
    if str(item).startswith("campaign-binding:")
), "")
print(packet_binding or "__missing__")
print(audit_binding or "__missing__")
print(str(lease.get("campaignBinding", "")) or "__missing__")
PY
  )
  checkpoint_binding="${_checkpoint_bindings[0]:-__missing__}"
  audit_binding="${_checkpoint_bindings[1]:-__missing__}"
  lease_binding="${_checkpoint_bindings[2]:-__missing__}"
  if [[ "$l1_campaign_binding" == "legacy" ]]; then
    [[ "$checkpoint_binding" == "__missing__" ]] && checkpoint_binding="legacy"
    [[ "$audit_binding" == "__missing__" ]] && audit_binding="legacy"
    [[ "$lease_binding" == "__missing__" ]] && lease_binding="legacy"
  fi
  [[ "$checkpoint_binding" == "$l1_campaign_binding" \
      && "$audit_binding" == "$l1_campaign_binding" \
      && "$lease_binding" == "$l1_campaign_binding" ]] \
    || l1_evidence_resume_refuse "accepted-campaign-evidence-mismatch"
  singular_campaign_binding_matches \
    "$checkpoint_binding" l1-drive pre-evidence-resume \
    || l1_evidence_resume_refuse "accepted-current-campaign-mismatch"

  accepted_base="$(singular_json_field "$accepted_packet" baseRef 2>/dev/null || true)"
  accepted_head="$(singular_json_field "$accepted_packet" headSha 2>/dev/null || true)"
  accepted_lease_base="$(singular_lease_field "$task_id" baseSha 2>/dev/null || true)"
  [[ -n "$accepted_base" && "$accepted_base" == "$accepted_lease_base" \
      && "$accepted_base" == "$packet_base_ref" \
      && "$accepted_head" == "$accepted_checkpoint_head" ]] \
    || l1_evidence_resume_refuse "accepted-admission-identity-mismatch"
  accepted_resolved_base="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
    "$accepted_base^{commit}" 2>/dev/null || true)"
  accepted_resolved_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify \
    "$accepted_head^{commit}" 2>/dev/null || true)"
  [[ "$accepted_resolved_base" == "$accepted_base" \
      && "$accepted_resolved_head" == "$accepted_head" ]] \
    || l1_evidence_resume_refuse "accepted-base-head-invalid"
  git -C "$SINGULAR_ROOT" merge-base --is-ancestor \
    "$accepted_base" "$accepted_head" >/dev/null 2>&1 \
    || l1_evidence_resume_refuse "accepted-base-head-lineage-invalid"
  actual_branch_head="$(git -C "$SINGULAR_ROOT" rev-parse "$worker_branch" 2>/dev/null || true)"
  actual_workspace_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$accepted_head" && "$actual_branch_head" == "$accepted_head" \
    && "$actual_workspace_head" == "$accepted_head" ]] \
    || l1_evidence_resume_refuse "accepted-head-mismatch"
  local non_generated_dirty
  non_generated_dirty="$(
    git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null \
      | sed 's/^...//' \
      | while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          path="${path##* -> }"
          case "$path" in
            .singular-cache|.singular-cache/*|.singular-state|.singular-state/*|.singular-evidence|.singular-evidence/*) ;;
            *) printf '%s\n' "$path" ;;
          esac
        done
  )"
  [[ -z "$non_generated_dirty" ]] \
    || l1_evidence_resume_refuse "accepted-workspace-dirty"

  # Validate the same packet/audit identity consumed at import, plus the exact
  # lifecycle writer contract for a claimed native repair successor. This is
  # read-only: a valid claim remains claimed until import retains the audit.
  singular_packet_module_guard "$accepted_packet" "$task_file" \
    "$worktree" "$accepted_run_dir" >/dev/null 2>&1 \
    || l1_evidence_resume_refuse "checkpoint-task-ownership-mismatch"
  authority_state="$(python3 "$SINGULAR_TASK_LIFECYCLE" validate-accepted-publication \
    --lease "$(singular_lease_path "$task_id")" --packet "$accepted_packet" \
    --audit "$accepted_audit" --task-contract "$task_file" --task "$task_id" \
    --run "$accepted_run" --branch "$worker_branch" --worktree "$worktree" \
    --base "$accepted_base" --head "$accepted_head" \
    --campaign "$checkpoint_binding" --repo-root "$SINGULAR_ROOT" 2>/dev/null)" \
    || l1_evidence_resume_refuse "checkpoint-lifecycle-authority-mismatch"
  if [[ "$authority_state" == repair-* ]]; then
    allowed_historical_run="$(singular_lease_field "$task_id" \
      recoveryAuthorization.predecessorRunId 2>/dev/null || true)"
  fi

  # Duplicate success is permitted only after the complete accepted authority
  # above validates. Exact artifacts are compared as JSON values because the
  # supported producer/importer may reserialize canonical JSON without changing
  # its acceptance identity. An unrelated packet under this task is conflict,
  # never evidence for this run.
  publication_state="$(python3 - "$accepted_packet" "$accepted_audit" \
      "$SINGULAR_INBOX_DIR" "$SINGULAR_ORCH_DIR/packets/imported/$task_id" \
      "$accepted_run" "$task_id" "$allowed_historical_run" <<'PY'
import json
import os
import stat
import sys

packet_path, audit_path, inbox_dir, imported_dir, run_id, task_id, allowed_historical_run = sys.argv[1:]

def load_regular(path, label):
    value = os.lstat(path)
    if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
        raise ValueError(f"{label} is not a regular non-symlink file")
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{label} is not a JSON object")
    return value

canonical_packet = load_regular(packet_path, "canonical packet")
canonical_audit = load_regular(audit_path, "canonical audit")
states = []
inbox = os.path.join(inbox_dir, run_id + ".json")
if os.path.lexists(inbox):
    if load_regular(inbox, "queued packet") != canonical_packet:
        raise ValueError("queued packet does not match the accepted run")
    states.append("queued")

exact_packet = os.path.join(imported_dir, run_id + ".json")
exact_audit = os.path.join(imported_dir, run_id + ".audit.json")
if os.path.isdir(imported_dir):
    for name in os.listdir(imported_dir):
        path = os.path.join(imported_dir, name)
        if not name.endswith(".json") or name.endswith(".audit.json"):
            continue
        if allowed_historical_run and name == allowed_historical_run + ".json":
            continue
        if name != run_id + ".json":
            raise ValueError("unrelated imported packet exists for accepted task")
        if load_regular(path, "imported packet") != canonical_packet:
            raise ValueError("imported packet does not match the accepted run")
    if os.path.lexists(exact_packet):
        if not os.path.lexists(exact_audit):
            raise ValueError("imported accepted packet has no audit sidecar")
        if load_regular(exact_audit, "imported audit") != canonical_audit:
            raise ValueError("imported audit does not match the accepted run")
        states.append("imported")
    elif os.path.lexists(exact_audit):
        raise ValueError("imported audit exists without its accepted packet")
print("imported" if "imported" in states else "queued" if states else "none")
PY
  )" || l1_evidence_resume_refuse "accepted-publication-artifact-mismatch"
  if [[ "$publication_state" != "none" ]]; then
    echo "accepted packet for $task_id already queued/imported; dispatch is a no-op"
    _l1_outcome="accepted"
    l1_status terminal completed "Existing accepted packet is already queued or imported" true \
      "Continue origin reconciliation" "accepted-existing"
    exit 0
  fi

  singular_append_event "l1.accepted_evidence_resume_started" \
    "resuming accepted publication for an immutable product head" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$accepted_run\",\"resumeRunId\":\"$run_id\",\"headSha\":\"$accepted_head\",\"auditVerdict\":\"accepted\",\"authorityState\":\"$authority_state\",\"evidenceFinalizationRequired\":\"$publication_needs_evidence\",\"consumesProductRepairBudget\":false}" \
    || true
  l1_status auditing active "Resuming accepted publication for exact head" true \
    "Complete only the missing evidence/publication transitions" "" "evidence-resume"

  local evidence_try evidence_rc=0 evidence_log
  if [[ "$publication_needs_evidence" == "yes" ]]; then
    for ((evidence_try=0; evidence_try<=evidence_infra_max; evidence_try++)); do
      evidence_log="$accepted_run_dir/evidence-manifest-resume-try-${evidence_try}.log"
      if [[ "$evidence_try" -gt 0 ]]; then
        singular_append_event "evidence.infra_retry" \
          "accepted-head evidence finalization failed; retrying evidence only" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$accepted_run\",\"resumeRunId\":\"$run_id\",\"stage\":\"accepted-publication-resume\",\"try\":$evidence_try,\"budgetDomain\":\"evidence-infrastructure\",\"maxExtraRetries\":$evidence_infra_max,\"consumesProductRepairBudget\":false}" \
          || true
      fi
      evidence_rc=0
      "$SCRIPT_DIR/evidence-manifest.sh" \
        --run-dir "$accepted_run_dir" --task-id "$task_id" --worktree "$worktree" \
        --base-ref "$(singular_json_field "$accepted_packet" baseRef)" \
        --head-sha "$accepted_head" >"$evidence_log" 2>&1 || evidence_rc=$?
      [[ "$evidence_rc" -eq 0 ]] && break
      if [[ "$evidence_rc" -eq 2 ]]; then
        singular_append_event "evidence.input_rejected" \
          "deterministic accepted-head evidence input rejected; unchanged retry suppressed" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$accepted_run\",\"resumeRunId\":\"$run_id\",\"stage\":\"accepted-publication-resume\",\"try\":$evidence_try,\"budgetDomain\":\"evidence-input\",\"consumesProductRepairBudget\":false}" \
          || true
        break
      fi
    done
  fi
  if [[ "$evidence_rc" -ne 0 ]]; then
    if ! l1_campaign_publication_begin \
        "$checkpoint_binding" pre-resume-exhausted-state; then
      l1_campaign_mismatch_exit \
        "campaign identity changed while evidence resume was running"
    fi
    _l1_outcome="terminal"
    singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true
    singular_task_set_status "$task_file" "blocked" 2>/dev/null || true
    singular_append_event "l1.accepted_evidence_resume_exhausted" \
      "accepted product remains preserved; evidence-only resume budget exhausted" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$accepted_run\",\"resumeRunId\":\"$run_id\",\"headSha\":\"$accepted_head\",\"retriesUsed\":$evidence_infra_max,\"maxExtraRetries\":$evidence_infra_max,\"productAccepted\":true,\"published\":false,\"consumesProductRepairBudget\":false}" \
      || true
    l1_status terminal failed "Accepted product still awaits evidence infrastructure" true \
      "Retry evidence finalization later; do not rerun product work" "awaiting-evidence"
    echo "AWAITING EVIDENCE: $task_id — accepted head $accepted_head remains preserved."
    exit 3
  fi

  if ! l1_campaign_publication_begin \
      "$checkpoint_binding" pre-resumed-state-mutation; then
    l1_campaign_mismatch_exit \
      "campaign identity changed while evidence resume was running"
  fi

  # When evidence was the missing transition, remove only the host-authored
  # blocker and restore the accepted handoff shape atomically. A packet already
  # accepted before interruption remains byte-identical.
  if [[ "$publication_needs_evidence" == "yes" ]]; then
    python3 - "$accepted_packet" "$accepted_head" <<'PY'
import json
import os
import sys

path, head = sys.argv[1:3]
packet = json.load(open(path, encoding="utf-8"))
packet["blockers"] = [
    item for item in packet.get("blockers", [])
    if not (
        isinstance(item, dict)
        and item.get("reason") == "awaiting-evidence"
        and item.get("headSha") == head
    )
]
packet["status"] = "accepted"
packet["nextAction"] = "import into control state and reconcile"
temporary = path + ".evidence-resumed.tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(packet, stream, indent=2)
    stream.write("\n")
PY
    local resumed_packet_tmp="$accepted_packet.evidence-resumed.tmp"
    singular_validate_packet_basic "$resumed_packet_tmp" >/dev/null 2>&1 || {
      rm -f "$resumed_packet_tmp"
      l1_evidence_resume_refuse "resumed-packet-invalid"
    }
    mv "$resumed_packet_tmp" "$accepted_packet"
  fi
  singular_lease_set_status "$task_id" "accepted"
  singular_task_set_status "$task_file" "accepted"
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "accept" \
    --rationale "resumed evidence finalization for previously accepted exact head $accepted_head; no product work rerun" \
    --run "$accepted_run" --branch "$worker_branch" --authority l1 >/dev/null 2>&1 || true
  local inbox_packet="$SINGULAR_INBOX_DIR/$accepted_run.json"
  _l1_outcome="accept-pending"
  cp "$accepted_packet" "$inbox_packet.tmp"
  mv "$inbox_packet.tmp" "$inbox_packet"
  _l1_outcome="accepted"
  l1_status terminal completed "Accepted evidence finalized and packet queued" true \
    "Continue origin integration" "accepted-evidence-resumed"
  singular_append_event "l1.accepted_evidence_resume_completed" \
    "accepted product packet completed its retained publication" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$accepted_run\",\"resumeRunId\":\"$run_id\",\"headSha\":\"$accepted_head\",\"auditVerdict\":\"accepted\",\"authorityState\":\"$authority_state\",\"evidenceFinalizationRequired\":\"$publication_needs_evidence\",\"productAccepted\":true,\"published\":true,\"workerRerun\":false,\"auditorRerun\":false,\"consumesProductRepairBudget\":false}" \
    || true
  l1_campaign_publication_end
  echo "RESUMED ACCEPTED EVIDENCE: $task_id — queued accepted head $accepted_head."
  exit 0
}

# A deterministic refusal that repeats forever starves the loop (0.4.0: a
# task-id collision re-dispatched into a preserved worktree every cycle until
# the breaker halted the run). Count refusals per task; at the threshold,
# park the task as a DECIDED outcome (exit 3) so the frontier stops
# re-selecting it and an operator sees exactly why.
l1_refusals_file="$SINGULAR_DISPATCH_DIR/$task_id.refusals"
l1_note_refusal_and_maybe_park() {
  local reason="$1" n=0
  if ! l1_campaign_publication_begin \
      "$l1_campaign_binding" pre-refusal-state-mutation; then
    l1_campaign_mismatch_exit \
      "campaign identity changed before refusal accounting"
  fi
  mkdir -p "$SINGULAR_DISPATCH_DIR"
  [[ -f "$l1_refusals_file" ]] && n="$(head -1 "$l1_refusals_file" 2>/dev/null | tr -d '[:space:]')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1))
  printf '%s\n' "$n" >"$l1_refusals_file"
  if (( n >= ${SINGULAR_REFUSAL_PARK_THRESHOLD:-3} )); then
    singular_task_set_status "$task_file" "blocked" 2>/dev/null || true
    "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
      --rationale "repeated dispatch refusal x$n: $reason" --run "$run_id" \
      --authority "l1-driver" 2>/dev/null || true
    singular_append_event "l1.refusal_parked" "task parked after repeated dispatch refusals" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"refusals\":$n,\"reason\":\"$reason\"}"
    rm -f "$l1_refusals_file"
    echo "parked $task_id after $n refusals: $reason" >&2
    exit 3
  fi
  l1_campaign_publication_end
}

# Auto-heal stranded accepted work (E5): an `accepted` lease whose packet
# never reached the inbox (driver died post-acceptance, reap race) used to
# refuse every re-dispatch forever (exit-2 loop -> breaker). If the prior
# run's packet exists and validates, accept it deterministically and enqueue —
# no worker/auditor re-run.
l1_try_auto_accept_existing() {
  [[ "${SINGULAR_AUTO_ACCEPT_EXISTING:-1}" == "1" ]] || return 1
  local prev_run cand cand_binding
  prev_run="$(singular_lease_field "$task_id" runId 2>/dev/null || true)"
  [[ -n "$prev_run" ]] || return 1
  cand="$SINGULAR_RUNS_DIR/$prev_run/packet.json"
  [[ -f "$cand" ]] || return 1
  [[ "$(singular_json_field "$cand" taskId 2>/dev/null || true)" == "$task_id" ]] || return 1
  cand_binding="$(python3 - "$cand" <<'PY' 2>/dev/null || true
import json
import sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
for item in packet.get("evidence", []):
    if isinstance(item, dict) and item.get("kind") == "campaign-binding":
        print(item.get("ref", ""))
        break
PY
)"
  # Missing provenance is accepted only for legacy packets while the current
  # engine is also in legacy mode. Frozen campaigns always require an exact
  # binding and never auto-heal a prior campaign's semantic verdict.
  if [[ -z "$cand_binding" && "$l1_campaign_binding" == "legacy" ]]; then
    cand_binding="legacy"
  fi
  if [[ -z "$cand_binding" || "$cand_binding" != "$l1_campaign_binding" ]] \
      || ! singular_campaign_binding_matches \
          "$cand_binding" l1-drive pre-existing-packet-recovery; then
    l1_campaign_mismatch_exit \
      "stranded accepted packet belongs to a different or unbound campaign"
  fi
  if "$SCRIPT_DIR/accept-existing-packet.sh" "$cand"; then
    if ! l1_campaign_publication_begin \
        "$cand_binding" pre-resumed-packet-publication; then
      l1_campaign_mismatch_exit \
        "campaign identity changed before stranded packet publication"
    fi
    _l1_outcome="accept-pending"
    cp "$cand" "$SINGULAR_INBOX_DIR/$prev_run.json.tmp" \
      && mv "$SINGULAR_INBOX_DIR/$prev_run.json.tmp" "$SINGULAR_INBOX_DIR/$prev_run.json"
    singular_append_event "l1.auto_accepted_existing" "stranded accepted packet re-accepted and enqueued" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$prev_run\",\"packet\":\"$cand\"}"
    echo "auto-accepted stranded packet for $task_id (run $prev_run); enqueued to inbox"
    _l1_outcome="accepted"
    l1_campaign_publication_end
    l1_status terminal completed "Recovered and queued an existing accepted packet" true \
      "Continue origin reconciliation" "accepted-existing"
    exit 0
  fi
  return 1
}

# Accepted recovery and the established accepted-packet no-op are authoritative
# terminal continuations, not fresh product work. They must run before the
# exhausted product-repair guard and before reset/orphan cleanup.
l1_try_resume_accepted_awaiting_evidence || true
if [[ "$accepted_checkpoint_mode" == "accepted-existing" ]]; then
  l1_try_auto_accept_existing || true
fi
if [[ -n "$accepted_checkpoint_mode" ]]; then
  l1_refuse_recognized_accepted_checkpoint "accepted-checkpoint-recovery-refused"
fi

# A prior started pass owns its counters and candidate regardless of checkout
# status or --reset. Refuse before any orphan/reset mutation, but only after the
# accepted terminal continuations above have had their idempotent opportunity.
if [[ "$prior_product_lease" == "yes" && "$product_passes_remaining" -le 0 ]]; then
  if ! l1_campaign_publication_begin \
      "$l1_campaign_binding" pre-exhausted-reentry-state; then
    l1_campaign_mismatch_exit \
      "campaign identity changed before exhausted re-entry publication"
  fi
  _l1_outcome="terminal"
  singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true
  singular_task_set_status "$task_file" "blocked" 2>/dev/null || true
  l1_status terminal failed "Durable product repair ceiling already exhausted" true \
    "Change task authority or explicitly unpark with a reset budget" "repair-budget-exhausted"
  singular_append_event "l1.product_repair_budget_exhausted" \
    "re-entry suppressed because durable product pass ceiling was already exhausted" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"riskTier\":\"$risk_tier\",\"riskSource\":\"$risk_source\",\"budgetDomain\":\"product-repair\",\"used\":$product_repairs_used,\"max\":$max_retries,\"priorLease\":true,\"productPassesRemaining\":0}" \
    || true
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
    --rationale "durable product repair ceiling exhausted before re-entry; refusing a fresh pass" \
    --run "$run_id" --branch "$worker_branch" --authority l1 >/dev/null 2>&1 || true
  echo "NOT ACCEPTED (escalate-parked): $task_id — durable product repair ceiling already exhausted."
  exit 3
fi

if [[ "${#authorized_continuation[@]}" -eq 10 ]]; then
  [[ -d "$worktree" && "$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)" == "${authorized_continuation[2]}" \
      && "$(git -C "$worktree" branch --show-current 2>/dev/null || true)" == "$worker_branch" ]] || {
    echo "l1-drive: authorized continuation worktree identity changed before preparation" >&2
    exit 2
  }
  if ! l1_candidate_inspect "$worktree"; then
    echo "l1-drive: continuation candidate Git/lineage inspection failed before preparation" >&2
    exit 2
  fi
  if ! l1_candidate_admission_checks "$worktree"; then
    singular_append_event "l1.candidate_admission_refused" \
      "authorized continuation failed scope or secret admission before provider work" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"admittedBaseSha\":\"$packet_base_ref\",\"consumesProductRepairBudget\":false}" || true
    echo "l1-drive: authorized continuation failed candidate admission; checkout preserved" >&2
    exit 3
  fi
elif singular_worktree_registered "$worktree" || [[ -e "$worktree" ]]; then
  existing_lease="$(singular_lease_status "$task_id" 2>/dev/null || echo none)"
  assess_existing=no
  case "$existing_lease" in
    accepted)
      if [[ "$reset" != yes ]]; then
        l1_try_auto_accept_existing || true
        l1_note_refusal_and_maybe_park "accepted worktree without importable packet (lease: $existing_lease)"
        echo "active/accepted worktree for $task_id (lease: $existing_lease); refusing (use --reset)" >&2
        exit 2
      fi
      assess_existing=yes ;;
    running|planned|needs-review|integrated)
      if [[ "$reset" != yes ]]; then
        l1_note_refusal_and_maybe_park "active/accepted worktree (lease: $existing_lease)"
        echo "active/accepted worktree for $task_id (lease: $existing_lease); refusing (use --reset)" >&2
        exit 2
      fi
      assess_existing=yes ;;
    *) assess_existing=yes ;;
  esac
  if [[ "$assess_existing" == yes ]]; then
    echo "assessing retained worktree for $task_id (lease: $existing_lease)"
    if ! l1_candidate_inspect "$worktree"; then
      echo "l1-drive: retained candidate Git/lineage inspection failed; preserving checkout" >&2
      exit 2
    fi
    admission_ok=yes
    l1_candidate_admission_checks "$worktree" || admission_ok=no
    if ! l1_git_campaign_publication_begin \
        "$l1_campaign_binding" pre-orphan-worktree-mutation; then
      l1_campaign_mismatch_exit \
        "campaign identity changed before orphan worktree recovery"
    fi
    if [[ "$L1_CANDIDATE_USEFUL" == yes ]]; then
      preserve_reason="reprovision-committed-candidate"
      [[ "$L1_CANDIDATE_DIRTY" == yes ]] && preserve_reason="partial-candidate-requires-continuation"
      [[ "$admission_ok" == yes ]] || preserve_reason="candidate-admission-refused"
      if ! l1_preserve_candidate "$worktree" "$preserve_reason"; then
        l1_git_campaign_publication_end
        echo "l1-drive: could not preserve useful candidate; refusing cleanup" >&2
        exit 2
      fi
    else
      remove_worktree
      branch_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify "$worker_branch^{commit}" 2>/dev/null || true)"
      if [[ -n "$branch_head" && "$branch_head" == "$packet_base_ref" ]]; then
        git -C "$SINGULAR_ROOT" branch -D "$worker_branch" >/dev/null 2>&1 || {
          l1_git_campaign_publication_end
          echo "l1-drive: failed to remove empty orphan branch" >&2
          exit 2
        }
      fi
    fi
    l1_git_campaign_publication_end
    if [[ "$admission_ok" != yes ]]; then
      singular_append_event "l1.candidate_admission_refused" \
        "retained candidate failed scope or secret admission before provider work" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"admittedBaseSha\":\"$packet_base_ref\",\"consumesProductRepairBudget\":false}" || true
      echo "l1-drive: retained candidate failed admission; preserved without dispatch" >&2
      exit 3
    fi
    if [[ "$L1_CANDIDATE_DIRTY" == yes ]]; then
      echo "l1-drive: retained partial candidate requires explicit continuation; no worker dispatched" >&2
      exit 3
    fi
    singular_append_event "l1.orphan_recovered" "reclaimed orphaned worktree" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"priorLease\":\"$existing_lease\",\"candidatePreserved\":$([[ "$L1_CANDIDATE_USEFUL" == yes ]] && printf true || printf false)}"
  fi
fi

# ---- Lease + branch + worktree ----
owned_json="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
forbidden_json="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
if ! l1_campaign_publication_begin \
    "$l1_campaign_binding" pre-lease-publication; then
  l1_campaign_mismatch_exit \
    "campaign identity changed before lease publication"
fi
singular_lease_write "$task_id" "$worker_branch" "$area" "l2-developer" "${owned_files[*]}" \
  "running" "$run_id" "$worktree" "$packet_base_ref" "$dispatch_batch_id" "$owned_json" "$forbidden_json"
# Keep decide.sh and operator tooling on the same product-repair ceiling as this
# driver.  The lease field is the legacy public budget surface; infrastructure
# retries never touch retryCount or maxRetries.
python3 - "$(singular_lease_path "$task_id")" "$max_retries" "$l1_campaign_binding" \
  "$([[ "${#authorized_continuation[@]}" -eq 10 ]] && printf yes || printf no)" <<'PY'
import json
import os
import sys

path, maximum, campaign_binding, continuation = sys.argv[1:5]
with open(path, encoding="utf-8") as handle:
    lease = json.load(handle)
if continuation == "yes":
    predecessor = lease.get("continuationAuthorization", {}).get("predecessorAccounting", {})
    lease["maxRetries"] = int(predecessor.get("maxRetries", lease.get("maxRetries", maximum)) or 0)
else:
    lease["maxRetries"] = int(maximum)
lease["campaignBinding"] = campaign_binding
temporary = path + ".retry-budget.tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(lease, handle, indent=2)
    handle.write("\n")
os.replace(temporary, path)
PY
_l1_lease_written="yes"
rm -f "$l1_refusals_file" 2>/dev/null || true  # a successful dispatch clears refusal history
singular_append_event "l1.dispatch_started" "l1 dispatch started" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$worker_branch\",\"baseSha\":\"$packet_base_ref\",\"batchId\":\"$dispatch_batch_id\",\"riskTier\":\"$risk_tier\",\"productRepairMax\":$max_retries}"
l1_campaign_publication_end
if ! l1_git_campaign_publication_begin \
    "$l1_campaign_binding" pre-worktree-creation; then
  l1_campaign_mismatch_exit \
    "campaign identity changed before worker branch/worktree creation"
fi
git_ec=0
set +e
if [[ "${#authorized_continuation[@]}" -eq 10 ]]; then
  : # Authorization preserves this exact worktree; the claim follows preparation.
else
  if ! git -C "$SINGULAR_ROOT" rev-parse --verify --quiet "$worker_branch" >/dev/null; then
    git -C "$SINGULAR_ROOT" branch "$worker_branch" "$branch_base"
    git_ec=$?
  fi
  if [[ "$git_ec" -eq 0 ]]; then
    mkdir -p "$SINGULAR_WORKTREES_DIR"
    git -C "$SINGULAR_ROOT" worktree add "$worktree" "$worker_branch"
    git_ec=$?
  fi
fi
set -e
l1_git_campaign_publication_end
if [[ "$git_ec" -ne 0 ]]; then
  echo "failed to create worker branch/worktree for $task_id from $branch_base" >&2
  exit "$git_ec"
fi
singular_append_event "l1.worktree_created" "worker worktree created" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"worktree\":\"$worktree\"}"
provision_log="$run_dir/worktree-provision.log"
# The shared preparer, so the worker worktree and the auditor's disposable
# worktree are built the same way by construction. Bootstrap stays non-fatal
# here (it is fatal in the audit path) and the failure is reported through
# SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FAILED below.
SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FATAL=no
if ! singular_worktree_prepare "$worktree" "$run_dir" "$SINGULAR_ROOT" "$provision_log"; then
  provision_out="$(cat "$provision_log" 2>/dev/null || true)"
  if ! l1_campaign_publication_begin \
      "$l1_campaign_binding" pre-provision-failure-state; then
    l1_campaign_mismatch_exit \
      "campaign identity changed while worker workspace provisioning was running"
  fi
  _l1_outcome="terminal"
  l1_status terminal failed "Worker workspace provisioning failed" true \
    "Inspect worktree-provision.log and repair the host dependency" "provision-failed"
  if [[ "${#authorized_continuation[@]}" -ne 10 ]]; then
    singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true
    singular_task_set_status "$task_file" "blocked" || true
    "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
      --rationale "worktree provisioning failed before runner invocation; see $provision_log" \
      --run "$run_id" --branch "$worker_branch" --authority l1 >/dev/null 2>&1 || true
  fi
  singular_append_event "l1.provision_failed" "worktree provisioning failed" \
    "$(python3 - "$task_id" "$run_id" "$provision_log" "$provision_out" <<'PY'
import json, sys
task_id, run_id, log, reason = sys.argv[1:5]
print(json.dumps({"taskId": task_id, "runId": run_id, "log": log, "reason": reason[:500]}, separators=(",", ":")))
PY
)"
  echo "worktree provisioning failed for $task_id (see $provision_log)" >&2
  exit 3
fi
singular_append_event "l1.provisioned" "worktree provisioning completed" \
  "$(python3 - "$task_id" "$run_id" "${SINGULAR_WORKTREE_ENV_FILE:-}" <<'PY'
import json, sys
task_id, run_id, env_file = sys.argv[1:4]
print(json.dumps({"taskId": task_id, "runId": run_id, "envFile": env_file}, separators=(",", ":")))
PY
)"
bootstrap_failure=""
bootstrap_log="$provision_log"
if [[ "$SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FAILED" == "yes" ]]; then
  bootstrap_failure="required-bootstrap-failed"
  singular_append_event "l1.bootstrap_failed" \
    "required worktree bootstrap failed (infrastructure)" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"log\":\"$bootstrap_log\"}" || true
else
  singular_append_event "l1.bootstrap_completed" "worktree bootstrap completed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"log\":\"$bootstrap_log\"}" || true
fi
if [[ "${#authorized_continuation[@]}" -eq 10 && -n "$bootstrap_failure" ]]; then
  # The shared preparer intentionally reports required bootstrap failure via a
  # flag. Treat that flag as pre-invocation preparation failure: the wrapper's
  # owner-bound finish transaction returns this still-reserved authority to
  # issued state, with counters and partial bytes untouched.
  _l1_outcome="terminal"
  if [[ "$continuation_preparation_failures" -ge 1 ]]; then
    singular_task_set_status "$task_file" "blocked" 2>/dev/null || true
  fi
  l1_status terminal failed "Required worker bootstrap failed before continuation invocation" true \
    "Repair bootstrap infrastructure, then reserve the exact continuation again" \
    "continuation-preparation-failed"
  echo "required bootstrap failed before continuation worker invocation (see $bootstrap_log)" >&2
  exit 3
fi

# A retained branch can exist without its canonical worktree. Inspect the
# provisioned candidate as the final admission boundary, still before the
# product-pass marker, continuation claim, or provider invocation. This also
# catches deterministic bootstrap-created scope/secret violations.
if ! l1_candidate_inspect "$worktree"; then
  echo "l1-drive: provisioned candidate Git/lineage inspection failed before provider work" >&2
  exit 2
fi
if ! l1_candidate_admission_checks "$worktree"; then
  _l1_outcome="terminal"
  singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true
  singular_task_set_status "$task_file" "blocked" 2>/dev/null || true
  l1_status terminal failed "Candidate admission rejected before provider work" true \
    "Inspect the retained candidate scope and secret results" "candidate-admission-refused"
  singular_append_event "l1.candidate_admission_refused" \
    "provisioned candidate failed scope or secret admission before provider work" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"admittedBaseSha\":\"$packet_base_ref\",\"consumesProductRepairBudget\":false}" || true
  echo "l1-drive: provisioned candidate failed admission; checkout preserved" >&2
  exit 3
fi

# ---- One attempt: worker -> scope -> gate -> commit -> stamp -> audit ----
# Sets globals: attempt_failure (class), attempt_ctx (file). worker_rc/audit_rc
# hold the raw runner exit codes of the latest attempt (captured, not yet acted
# on — later waves branch on timeout/resume codes such as 124/86).
head_sha=""
packet="$run_dir/packet.json"
audit_record="$(singular_audit_record_path "$run_id")"
verdict="unknown"
attempt_failure=""
attempt_ctx=""
accepted_audit_pending_evidence="no"
worker_rc=0
audit_rc=0
continuation_invocation_started="no"

# Session affinity (T-E5): per-role meta FILES (separate paths) make cross-role
# session reuse structurally impossible. Strategy globals are recorded per attempt
# for the archive index (additive fields).
session_meta_implementer="$run_dir/session-implementer.json"
session_meta_reviewer="$run_dir/session-reviewer.json"
latest_worker_context_bundle=""
worker_strategy="fresh"
worker_strategy_reason="init"
reviewer_strategy="fresh"
reviewer_strategy_reason="init"

# Evidence materialization has its own one-extra-try budget for each call site.
# A retry here never re-enters implementation, never changes the lease retry
# count, and never alters an already-issued product verdict.
l1_build_evidence_manifest() {
  local stage="$1" canonical_log="$2"
  local evidence_try=0 evidence_rc=0 try_log
  for ((evidence_try=0; evidence_try<=evidence_infra_max; evidence_try++)); do
    try_log="${canonical_log%.log}-try-${evidence_try}.log"
    if [[ "$evidence_try" -gt 0 ]]; then
      singular_append_event "evidence.infra_retry" \
        "evidence infrastructure failure; retrying evidence phase only" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"stage\":\"$stage\",\"try\":$evidence_try,\"budgetDomain\":\"evidence-infrastructure\",\"maxExtraRetries\":$evidence_infra_max,\"consumesProductRepairBudget\":false}" \
        || true
    fi
    evidence_rc=0
    SINGULAR_EVIDENCE_CAMPAIGN_BINDING="$l1_campaign_binding" \
    "$SCRIPT_DIR/evidence-manifest.sh" \
      --run-dir "$run_dir" --task-id "$task_id" --worktree "$worktree" \
      --base-ref "$packet_base_ref" --head-sha "$head_sha" \
      >"$try_log" 2>&1 || evidence_rc=$?
    cp "$try_log" "$canonical_log" 2>/dev/null || true
    [[ "$evidence_rc" -eq 0 ]] && return 0
    if [[ "$evidence_rc" -eq 2 ]]; then
      singular_append_event "evidence.input_rejected" \
        "deterministic evidence input rejected; unchanged retry suppressed" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"stage\":\"$stage\",\"try\":$evidence_try,\"budgetDomain\":\"evidence-input\",\"consumesProductRepairBudget\":false}" \
        || true
      return 2
    fi
  done
  singular_append_event "evidence.infra_exhausted" \
    "evidence infrastructure retry budget exhausted" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"stage\":\"$stage\",\"budgetDomain\":\"evidence-infrastructure\",\"retriesUsed\":$evidence_infra_max,\"maxExtraRetries\":$evidence_infra_max,\"consumesProductRepairBudget\":false}" \
    || true
  return "$evidence_rc"
}

# Durable `decision-record` extra spec (node rehydrate-path, layer engine_runtime).
# The repo-level decision log lives OUTSIDE run_dir, so the pure resolver
# singular_ctx_rehydrate_sources never emits it; it is supplied as a class-tagged
# extra computed by the pure leaf over SINGULAR_ROOT. It is snapshotted ONCE here at
# drive start (existence-gated) so a rehydrate attempt rehydrates the decision log
# as it stood when the run began — NOT this run's own in-flight decider appends
# (record-decision.sh mutates docs/orchestration/decisions.md between attempts, and
# capturing those would be circular). Empty when the decision log is absent at
# drive start. Both rehydrate sites reference this identical spec, so the injected
# packet and the recorded manifest carry the SAME decision record (id + content
# hash) by construction. Its CONTENT is hashed/rendered later at rehydrate time.
decision_source_extra="$(singular_ctx_rehydrate_decision_source "$SINGULAR_ROOT" 2>/dev/null || true)"

# Worker-runner selection (singular_select_l2_runner): generic engine returns the
# default runner; an enabled module may route specific tasks to an alternate
# runner (3rd arg). An explicit SINGULAR_RUNNER override always wins.
l2_default="$(singular_role_runner implementer "$SINGULAR_RUNNER_BIN")" || exit 78
l2_runner="$(singular_select_l2_runner "$task_file" "$l2_default" "$SCRIPT_DIR/claude-run.sh")"
if [[ "$l2_runner" != "$SINGULAR_RUNNER_BIN" ]]; then
  echo "  module-routed L2 worker -> $(basename "$l2_runner")"
  singular_append_event "l1.worker_runner_selected" "worker routed to alternate runner" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"runner\":\"$(basename "$l2_runner")\"}"
fi

# ---- One attempt = three phases, called in order by the retry loop ----------
# prepare_worker_prompt <n> / run_worker_phase <n> / run_audit_phase <n>, where
# <n> is the 1-based attempt number. Globals carried between phases: fix_hints
# (in), attempt_failure/attempt_ctx (failure class + context file), head_sha,
# verdict, worker_rc/audit_rc. Failure semantics match the historical single
# run_attempt exactly: any worker-phase failure (scope/gate/commit/packet)
# aborts before the audit phase runs.

# Assemble the active worker prompt for attempt <n>: base prompt + prior-attempt
# fix hints. Later waves swap in a dedicated fix-prompt rendering here.
prepare_worker_prompt() {
  local n="$1"
  local active_prompt="$run_dir/l2-active-prompt.md"
  # Attempt 1 is always a plain copy of the base prompt (byte-identical invariant).
  if [[ "$n" -le 1 ]]; then
    cp "$l2_prompt" "$active_prompt"
    return 0
  fi
  # Structured fix prompt (T-E3): authoritative findings + scoped evidence. On a
  # renderer failure, fall back to the legacy fix_hints path verbatim. The
  # fix_hints global keeps being set in the retry loop so the legacy path (and
  # SINGULAR_FIX_PROMPT_STRUCTURED=0) stays byte-identical to today.
  if [[ "${SINGULAR_FIX_PROMPT_STRUCTURED:-1}" == "1" ]]; then
    local cur_owned_json cur_forbidden_json
    cur_owned_json="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    cur_forbidden_json="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    if singular_render_fix_prompt "$active_prompt" "$l2_prompt" "$run_dir" "$n" \
         "${prev_failure_class:-unknown}" "${prev_attempt_ctx:-/dev/null}" \
         "$cur_owned_json" "$cur_forbidden_json" 2>/dev/null; then
      return 0
    fi
    singular_append_event "l1.fix_prompt_fallback" "structured fix prompt render failed; using legacy hints" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
  fi
  cp "$l2_prompt" "$active_prompt"
  if [[ -n "$fix_hints" ]]; then
    { echo ""; echo "---"; echo "## Previous attempt feedback (fix these, stay in scope)"; echo ""; echo "$fix_hints"; } >>"$active_prompt"
  fi
}

# Inject the assembled durable-context rehydration packet into the implementer's
# already-rendered active prompt when the routing decision upgraded a refused
# resume to `rehydrate` (only behind SINGULAR_REHYDRATE=1; the spine never yields
# `rehydrate` otherwise, so with the flag unset this is a no-op and $active_prompt
# stays byte-identical). The run stays FRESH (worker_resume_id empty -> no
# --resume-session): a fresh session PLUS injected durable context, not a resume.
# The packet is assembled by delegating into the integrated pure bricks —
# singular_ctx_rehydrate_packet over singular_ctx_rehydrate_sources "$run_dir" — so
# determinism, the per-section SINGULAR_CONTEXT_SECTION_MAX_CHARS cap, and
# quarantine exclusion all come for free; no rehydration/resolution logic is
# inlined here. The section is headed as injected durable context from a
# refused-resume lineage — reference-only, NOT authoritative — because rehydrated
# content is tainted / model-authored, not host-verified. Called ONCE at
# attempt-open (outside the infra-retry try loop) so try>0 reuse the same
# $active_prompt (idempotent). Mirrors assumptions_inject_fix / the fix-hints
# append. Legacy composition stays fail-soft; configured brain validation errors
# propagate so the affected worker cannot run without its requested context.
rehydrate_inject_packet() {
  local active_prompt="$1"
  [[ "${worker_strategy:-}" == "rehydrate" ]] || return 0
  # The repo-level `decision-record` lives OUTSIDE run_dir; it is supplied as the
  # class-tagged extra `decision_source_extra` snapshotted at drive start. The event
  # record site passes the IDENTICAL spec, so the injected packet and the recorded
  # manifest carry the SAME decision record. Empty when the decision log was absent
  # at drive start.
  # SUBGRAPH branch (node subgraph-rehydrate; behind SINGULAR_CTX_SUBGRAPH_REHYDRATE
  # and only on the treatment arm with a present non-empty corpus). The shared
  # selector yields the contradictions-first subgraph packet keyed on the SAME
  # task_id / arm-mode / node the manifest-record site (ctx-rehydrate-event.sh)
  # keys on, so the injected packet and the recorded manifest carry the SAME
  # subgraph sources by construction. Inject THAT under the identical reference-
  # only / NOT-authoritative header and skip the flat durable composition. With the
  # knob off / control arm / absent corpus the selector returns non-zero/empty and
  # the flat path below runs unchanged (byte-identical to today).
  local packet=""
  local subgraph_packet
  if subgraph_packet="$(singular_ctx_route_subgraph_render "$task_id" packet 2>/dev/null)" \
     && [[ -n "$subgraph_packet" ]]; then
    packet="$subgraph_packet"
  else
    local -a specs=()
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && specs+=("$line")
    done < <(singular_ctx_rehydrate_sources "$run_dir" ${decision_source_extra:+"$decision_source_extra"} 2>/dev/null)
    packet="$(singular_ctx_rehydrate_packet ${specs[@]+"${specs[@]}"} 2>/dev/null)" || return 0
  fi
  if [[ -n "$packet" ]]; then
    {
      echo ""
      echo "---"
      echo ""
      echo "## Injected durable context (rehydrated from a refused-resume lineage)"
      echo ""
      echo "> Reference only, NOT authoritative. This is durable context rehydrated"
      echo "> from a prior (tainted, model-authored) session's artifacts, not"
      echo "> host-verified evidence. Do not pass its content off as authoritative."
      echo ""
      printf '%s\n' "$packet"
    } >> "$active_prompt" 2>/dev/null || true
  fi

  # Authored-knowledge augmentation (node rehydrate-path; OPTIONAL, NOT part of
  # requiredCompletion). AFTER the durable packet, ALSO append the eligible
  # authored-knowledge entries under a reference-only / NOT-authoritative wrapper.
  # The hook is a minimal delegating append into the integrated config-gated
  # render (TASK-0058–0061); no config/selection/render logic is inlined here.
  # The render internally gates on SINGULAR_CTX_MANIFEST (default 0) and the
  # OPTIONAL singular.config.json `contextManifest` field, so with either OFF it
  # returns empty and nothing is appended — the durable-only injection is
  # byte-identical. The trigger set comes from the pure builder
  # singular_ctx_rehydrate_authored_triggers (TASK-0064): the run's deterministic,
  # de-duplicated `load-when` tokens (role `implementer`, step `implement`, task
  # id) rather than the bare literal `implement`, so authored entries scoped to a
  # role or task — not only the literal step — become eligible. The enriched set
  # is a strict superset of {implement}, so implement-scoped entries still match
  # (backward compatible). The manifest-record site
  # (engine/ctx-rehydrate-event.sh) passes the IDENTICAL set so the injected and
  # recorded authored entries stay consistent. Minimal delegation: the set is
  # computed and passed expanded; no selection/render logic is inlined here.
  # Legacy failures remain non-fatal; strict brain descriptor failures propagate.
  #
  # NODE dimension (TASK-0066 -> TASK-0067): resolve the run's executable DAG node
  # via the pure read-only resolver singular_ctx_rehydrate_authored_node "$task_id"
  # and thread it into the builder's position-3 [node] slot so node-scoped
  # `load-when` entries (e.g. ["rehydrate-path"]) become eligible. The resolver
  # returns empty (fail-safe) on an absent or ambiguous task->node association;
  # the builder skips empty dimensions, so the set stays {implementer, implement,
  # task-id} — byte-identical to the pre-node-dimension behavior. The
  # manifest-record site resolves the node from the SAME task_id via the SAME
  # deterministic resolver, so both derive the identical token and identical set.
  local node
  node="$(singular_ctx_rehydrate_authored_node "$task_id" 2>/dev/null)" || node=""
  local -a authored_triggers=()
  local trigger
  while IFS= read -r trigger; do
    [[ -n "$trigger" ]] && authored_triggers+=("$trigger")
  done < <(singular_ctx_rehydrate_authored_triggers implementer implement "$node" "$task_id" 2>/dev/null)
  local authored
  authored="$(singular_ctx_rehydrate_authored_config_render ${authored_triggers[@]+"${authored_triggers[@]}"})" || return $?
  [[ -n "$authored" ]] || return 0
  {
    echo ""
    echo "---"
    echo ""
    echo "## Injected authored knowledge (reference material, NOT authoritative)"
    echo ""
    echo "> Reference only, NOT authoritative. Human-curated authored-knowledge"
    echo "> entries eligible for this step, augmenting the rehydration packet."
    echo "> Per-entry markers frame each section; do not treat as host-verified"
    echo "> evidence."
    echo ""
    printf '%s\n' "$authored"
  } >> "$active_prompt" 2>/dev/null || true
  return 0
}

# Worker invocation through scope/gate/commit/packet stamping + validation.
# Sets head_sha, attempt_failure, attempt_ctx, worker_rc. Returns 0 when a
# validated packet exists on a committed branch, 1 otherwise.
run_worker_phase() {
  local n="$1"
  # Re-resolve locally so focused tests that extract this function retain the
  # same one-extra-try contract without depending on driver-global setup.
  local worker_infra_max="${worker_infra_max:-${SINGULAR_WORKER_INFRA_MAX:-1}}"
  [[ "$worker_infra_max" =~ ^[0-9]+$ ]] || worker_infra_max=1
  [[ "$worker_infra_max" -gt 1 ]] && worker_infra_max=1
  l1_status implementing active "Running implementer attempt $n" false \
    "Validate scope and run the regression gate" "" "worker-controller"
  if [[ -n "$bootstrap_failure" ]]; then
    if [[ "$worker_infra_max" -gt 0 ]]; then
      local bootstrap_retry_log="$run_dir/worktree-bootstrap-retry.log"
      singular_append_event "worker.infra_retry" \
        "worktree bootstrap infrastructure failure; retrying bootstrap phase only" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":1,\"stage\":\"bootstrap\",\"reason\":\"required-bootstrap-failed\",\"budgetDomain\":\"worker-infrastructure\",\"maxExtraRetries\":$worker_infra_max,\"consumesProductRepairBudget\":false}" \
        || true
      SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FATAL=no
      singular_worktree_prepare "$worktree" "$run_dir" "$SINGULAR_ROOT" \
        "$bootstrap_retry_log" >/dev/null 2>&1 || true
      if [[ "${SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FAILED:-yes}" == "no" ]]; then
        bootstrap_failure=""
        bootstrap_log="$bootstrap_retry_log"
        singular_append_event "l1.bootstrap_recovered" \
          "required worktree bootstrap recovered within infrastructure budget" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"budgetDomain\":\"worker-infrastructure\",\"consumesProductRepairBudget\":false}" \
          || true
      fi
    fi
  fi
  if [[ -n "$bootstrap_failure" ]]; then
    singular_append_event "worker.infra_exhausted" \
      "worktree bootstrap infrastructure retry budget exhausted" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"stage\":\"bootstrap\",\"budgetDomain\":\"worker-infrastructure\",\"retriesUsed\":$worker_infra_max,\"maxExtraRetries\":$worker_infra_max,\"consumesProductRepairBudget\":false}" \
      || true
    attempt_failure="worker-infra"
    attempt_ctx="$bootstrap_log"
    return 1
  fi
  local active_prompt="$run_dir/l2-active-prompt.md"

  # ---- Worker runner with bounded infra-retry (T-E6) ------------------------
  # A worker "infra failure" is the runner itself failing/timing out — rc 124
  # (claude-run kills the tree on SINGULAR_CLAUDE_TIMEOUT_SEC), or rc!=0 with a truly
  # empty/missing last-message file. That is distinct from worker-no-packet (the
  # model ran fine and emitted prose: output EXISTS but carries no packet) — which
  # the packet-validation path below already classifies. We re-run ONLY the worker
  # up to SINGULAR_WORKER_INFRA_MAX extra times; this never bumps the lease retryCount.
  # QUOTA GUARD: singular_planner_failure_class returns "quota" (priority over timeout/
  # empty) when the log carries a usage/rate-limit marker; we must NOT swallow that
  # as worker-infra, so a quota classification falls through to the normal path
  # (the breaker/quota-backoff machinery owns it).
  local worker_try worker_fc worker_result_file worker_try_log worker_classification_log
  local worker_context_status worker_context_denial

  # ---- Session affinity (T-E5): resume decision (first try only) ------------
  # Reuse the implementer's prior runtime session iff every gate passes; else go
  # fresh. Lineage head = the worktree's current HEAD. The decision is computed
  # ONCE per attempt; infra retries (try>0) always run FRESH (no --resume-session).
  local l2_runner_basename worker_prompt_sha worker_resume_id="" worker_decision
  local worker_capability_profile
  l2_runner_basename="$(basename "$l2_runner")"
  worker_prompt_sha="$(singular_prompt_sha "$l2_prompt" 2>/dev/null || true)"
  local worktree_head; worktree_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"
  # Routed through the ctx-* adapter (SINGULAR_CTX_ROUTING; default 1. Set 0 for
  # OFF-parity with the direct decider call). Step `implement` is not an
  # independence-required step, so the routing gates (window/diff/lease) may apply.
  worker_decision="$(singular_ctx_route_decide implementer implement "$session_meta_implementer" \
    "$task_id" "$run_id" "$l2_runner_basename" "$worker_prompt_sha" "$worktree" "$worktree_head" 2>/dev/null || echo "fresh decide-error")"
  worker_strategy="${worker_decision%% *}"
  worker_strategy_reason="${worker_decision#* }"
  if [[ "${#authorized_continuation[@]}" -eq 10 ]]; then
    # A one-shot continuation cannot spend a second provider call on a resume
    # fallback. It always starts a fresh invocation under the exact immutable
    # runtime fingerprint authorized by the host.
    worker_strategy="fresh"
    worker_strategy_reason="authorized-continuation"
  fi

  # A strict brain descriptor is itself rehydratable authored context. If a
  # would-be resume was refused after all durable artifacts were quarantined,
  # the generic router conservatively reports fresh because its durable-only
  # manifest is empty. Keep that refusal on the existing rehydrate boundary so
  # the configured descriptor is validated, rendered, and recorded before the
  # affected worker runs. Feature-off, absent config, legacy strings, no-session,
  # and routing errors retain their prior decisions.
  if [[ "$worker_strategy" == "fresh" && "${SINGULAR_REHYDRATE:-0}" == "1" ]]; then
    case "$worker_strategy_reason" in
      session-lease|window-pressure|diff-volume)
        if singular_ctx_rehydrate_authored_brain_configured; then
          worker_strategy="rehydrate"
        fi
        ;;
    esac
  fi
  if [[ "$worker_strategy" == "resume" ]]; then
    worker_resume_id="$worker_strategy_reason"; worker_strategy_reason="resume"
    singular_append_event "context.strategy_selected" "session resume strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"strategy\":\"resume\",\"reason\":\"resume\",\"sessionId\":\"$worker_resume_id\"}" || true
  elif [[ "$worker_strategy" == "rehydrate" ]]; then
    # A refused-resume lineage step upgraded to rehydrate (only behind
    # SINGULAR_REHYDRATE=1; the routing spine never yields `rehydrate` otherwise).
    # Record strategy=rehydrate, the refusal reason, and the NESTED packet manifest
    # (ids + hashes only) by delegating into the integrated pure assembler over the
    # durable-artifact root run_dir. No resume session is reused (rehydrate is a
    # fresh session with injected context); the packet-injection hook is a later
    # slice. worker_resume_id stays empty so the worker runs fresh below.
    # The repo-level `decision-record` lives OUTSIDE run_dir; supply it as a trailing
    # class-tagged extra so the recorded manifest carries the SAME decision record
    # (id + content hash) the packet-injection hook injects — both reference the
    # identical drive-start `decision_source_extra`, so they agree by construction.
    local rehydrate_event_data
    if ! rehydrate_event_data="$(singular_ctx_rehydrate_event_data implementer "$task_id" "$run_id" "$n" "$worker_strategy_reason" "$run_dir" ${decision_source_extra:+"$decision_source_extra"})"; then
      echo "configured brain context validation failed before worker invocation" >&2
      attempt_failure="configured-context"
      attempt_ctx="${SINGULAR_JSON_CONFIG_FILE:-$active_prompt}"
      return 1
    fi
    singular_append_event "context.strategy_selected" "rehydrate strategy selected" \
      "$rehydrate_event_data" || true
  else
    singular_append_event "context.strategy_selected" "fresh-run strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"strategy\":\"fresh\",\"reason\":\"$worker_strategy_reason\"}" || true
  fi

  # ---- Rehydrate packet injection (node rehydrate-path; behind SINGULAR_REHYDRATE)
  # On a `rehydrate` decision, append the assembled durable-context packet to the
  # already-rendered active prompt ONCE, before the (fresh) worker try loop. No-op
  # for resume/fresh, so with SINGULAR_REHYDRATE unset $active_prompt is unchanged.
  if ! rehydrate_inject_packet "$active_prompt"; then
    echo "configured brain context rendering failed before worker invocation" >&2
    attempt_failure="configured-context"
    attempt_ctx="${SINGULAR_JSON_CONFIG_FILE:-$active_prompt}"
    return 1
  fi

  # Context-service delivery is independent of the native resume/rehydrate
  # router. Attempt 1 receives selected sources; later product attempts compare
  # a freshly validated snapshot with the prior bundle and carry only changed
  # bytes, mandatory obligations, and immutable references.
  local context_bundle="$run_dir/context-implementer-attempt-${n}.bundle.json"
  local context_prior="" context_phase="implement-first"
  if [[ "$n" -gt 1 ]]; then
    context_prior="$latest_worker_context_bundle"
    [[ -n "$context_prior" ]] \
      || context_prior="$run_dir/context-implementer-attempt-$((n - 1)).bundle.json"
    context_phase="implement-retry"
  elif [[ "$worker_strategy" == "resume" && -f "$context_bundle" ]]; then
    context_prior="$context_bundle"
    context_phase="implement-resume"
  fi
  local context_config="${SINGULAR_CONTEXT_CONFIG_FILE:-${SINGULAR_JSON_CONFIG_FILE:-$SINGULAR_ROOT/singular.config.json}}"
  local context_task="$task_file"
  context_task="$(singular_context_worktree_path "$task_file" "$worktree")"
  local context_settings context_enabled
  context_settings="$(singular_context_invocation_settings "$context_config")" || {
    echo "configured context service failed before worker invocation" >&2
    attempt_failure="configured-context"
    attempt_ctx="$context_config"
    return 1
  }
  context_enabled="${context_settings%%$'\t'*}"
  # Keep the routed/fix prompt separate from provider-visible context. Every
  # provider boundary restores this base and asks the service for a new source
  # snapshot. This prevents cumulative injection while ensuring infrastructure
  # retries and resume fallbacks observe changed, missing, or revoked sources.
  local context_base_prompt="$run_dir/l2-context-base-attempt-${n}.md"
  cp "$active_prompt" "$context_base_prompt" || return 1
  prepare_worker_context_base() {
    cp "$context_base_prompt" "$active_prompt" || return 1
    return 0
  }

  local worker_resume_failed="no"
  for ((worker_try=0; worker_try<=worker_infra_max; worker_try++)); do
    worker_try_log="$run_dir/worker-attempt-${n}-try-${worker_try}.log"
    worker_classification_log="$worker_try_log"
    if [[ "$worker_try" -gt 0 ]]; then
      singular_append_event "worker.infra_retry" "worker infra failure; re-running worker only" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$worker_try,\"reason\":\"$worker_fc\",\"budgetDomain\":\"worker-infrastructure\",\"maxExtraRetries\":$worker_infra_max,\"consumesProductRepairBudget\":false}"
      echo "  worker infra retry $worker_try/$worker_infra_max ($worker_fc)..."
    fi
    prepare_worker_context_base || return 1
    rm -f "$run_dir/last-message.json"
    # Resume only on the FIRST try; infra retries are always fresh.
    local worker_run_args=(--level l2 -C "$worktree" --run-id "$run_id" \
      --prompt-file "$active_prompt" --output-last-message "$run_dir/last-message.json" \
      --session-meta "$session_meta_implementer")
    if [[ "$worker_try" -eq 0 && -n "$worker_resume_id" && "$worker_resume_failed" == "no" ]]; then
      echo "  running L2 worker via $l2_runner_basename (resume $worker_resume_id)..."
      worker_run_args+=(--resume-session "$worker_resume_id")
      worker_result_file="$run_dir/implementer-attempt-${n}-try-${worker_try}-resume-runner-result.json"
    else
      echo "  running L2 worker via $l2_runner_basename..."
      worker_result_file="$run_dir/implementer-attempt-${n}-try-${worker_try}-runner-result.json"
    fi
    worker_rc=0
    worker_capability_profile="${SINGULAR_IMPLEMENTER_CAPABILITY_PROFILE:-implementer-core}"
    singular_runner_contract_prepare \
      "$l2_runner" implementer "$worker_capability_profile" "$worker_result_file"
    if [[ "${#authorized_continuation[@]}" -eq 10 \
        && "$continuation_invocation_started" == "no" ]]; then
      if ! singular_lifecycle_claim_continuation "$task_id" "${authorized_continuation[0]}" \
          "${authorized_continuation[7]}" "${authorized_continuation[8]}" "$run_id" \
          "${authorized_continuation[2]}" "${authorized_continuation[3]}" \
          "${authorized_continuation[6]}" "$task_file" "$packet_base_ref" >/dev/null; then
        attempt_failure="continuation-claim-failed"
        attempt_ctx="$(singular_lease_path "$task_id")"
        return 1
      fi
      continuation_invocation_started="yes"
      singular_append_event "l1.continuation_claimed" \
        "one-shot continuation claimed at the worker invocation boundary" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"authorizationId\":\"${authorized_continuation[0]}\",\"candidateSourceSha\":\"${authorized_continuation[2]}\",\"integrationTargetSha\":\"${authorized_continuation[3]}\",\"engineSourceFingerprint\":\"${authorized_continuation[4]}\",\"worktree\":\"$worktree\",\"additionalWorkerAttemptsClaimed\":1}" || true
    fi
    local worker_context_receipt="$run_dir/context-invocation-implementer-attempt-${n}-try-${worker_try}.json"
    rm -f "$worker_context_receipt"
    SINGULAR_RUNNER_ROLE=implementer \
    SINGULAR_RUNNER_CAPABILITY_PROFILE="$worker_capability_profile" \
    SINGULAR_RUNNER_RESULT_FILE="$worker_result_file" \
    SINGULAR_TEST_TASK_CONTRACT="$task_file" \
    SINGULAR_TEST_TASK_ID="$task_id" \
    SINGULAR_TEST_TASKS_DIR="$SINGULAR_TASKS_DIR" \
      singular_context_invocation_run implementer "$context_phase" \
        "$context_task" "$context_bundle" "$context_prior" \
        "$run_id:$task_id:implementer:attempt-$n:try-$worker_try" \
        "$worker_context_receipt" "$l1_campaign_binding" "$worktree" -- \
        "$l2_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
          "${worker_run_args[@]}" >"$worker_try_log" 2>&1 || worker_rc=$?
    worker_context_status="$(singular_context_receipt_status "$worker_context_receipt" 2>/dev/null || true)"
    if [[ "$worker_context_status" == "denied" ]]; then
      worker_context_denial="$(singular_context_receipt_denial_reason "$worker_context_receipt" 2>/dev/null || true)"
      [[ "$worker_context_denial" != "campaign-mismatch" ]] \
        || l1_campaign_mismatch_exit "campaign policy changed before worker admission"
      cat "$worker_try_log" >&2
      echo "configured context service denied worker invocation ($worker_context_denial)" >&2
      attempt_failure="configured-context"
      attempt_ctx="$context_config"
      return 1
    elif [[ "$worker_context_status" == "admitted" ]]; then
      context_prior="$(singular_context_receipt_bundle_path "$worker_context_receipt" 2>/dev/null || true)"
      [[ -z "$context_prior" ]] || latest_worker_context_bundle="$context_prior"
    elif [[ "$context_enabled" == "1" ]]; then
      [[ "$worker_rc" -ne 2 ]] \
        || l1_campaign_mismatch_exit "campaign policy changed at worker admission checkpoint"
      cat "$worker_try_log" >&2
      echo "configured context service failed before worker invocation" >&2
      attempt_failure="configured-context"
      attempt_ctx="$context_config"
      return 1
    fi
    context_phase="implement-retry"
    printf -- '--- worker try %s (attempt %s) ---\n' "$worker_try" "$n" \
      >>"$run_dir/worker-codex.log" || true
    cat "$worker_try_log" >>"$run_dir/worker-codex.log" 2>/dev/null || true

    # Resume-refused (86) or resume-failure (86): the runner could not reuse the
    # session. Fall back to FRESH within the SAME try (don't consume an infra/main
    # retry on a resume miss). This is a pure optimization miss; the task outcome
    # is unchanged.
    if [[ "$worker_rc" -eq 86 && -n "$worker_resume_id" && "$worker_resume_failed" == "no" ]]; then
      worker_resume_failed="yes"
      singular_append_event "context.resume_failed" "implementer resume failed; re-running fresh" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"sessionId\":\"$worker_resume_id\"}" || true
      worker_strategy="fresh"; worker_strategy_reason="resume-failed"
      echo "  worker resume failed; falling back to fresh run..."
      worker_classification_log="$run_dir/worker-attempt-${n}-try-${worker_try}-resume-fallback.log"
      worker_result_file="$run_dir/implementer-attempt-${n}-try-${worker_try}-resume-fallback-runner-result.json"
      worker_rc=0
      rm -f "$run_dir/last-message.json"
      prepare_worker_context_base || return 1
      singular_runner_contract_prepare \
        "$l2_runner" implementer "$worker_capability_profile" "$worker_result_file"
      worker_context_receipt="$run_dir/context-invocation-implementer-attempt-${n}-try-${worker_try}-fallback.json"
      rm -f "$worker_context_receipt"
      SINGULAR_RUNNER_ROLE=implementer \
      SINGULAR_RUNNER_CAPABILITY_PROFILE="$worker_capability_profile" \
      SINGULAR_RUNNER_RESULT_FILE="$worker_result_file" \
      SINGULAR_TEST_TASK_CONTRACT="$task_file" \
      SINGULAR_TEST_TASK_ID="$task_id" \
      SINGULAR_TEST_TASKS_DIR="$SINGULAR_TASKS_DIR" \
        singular_context_invocation_run implementer "$context_phase" \
          "$context_task" "$context_bundle" "$context_prior" \
          "$run_id:$task_id:implementer:attempt-$n:try-$worker_try:fallback" \
          "$worker_context_receipt" "$l1_campaign_binding" "$worktree" -- \
          "$l2_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
            --level l2 -C "$worktree" --run-id "$run_id" \
            --prompt-file "$active_prompt" --output-last-message "$run_dir/last-message.json" \
            --session-meta "$session_meta_implementer" >"$worker_classification_log" 2>&1 || worker_rc=$?
      worker_context_status="$(singular_context_receipt_status "$worker_context_receipt" 2>/dev/null || true)"
      if [[ "$worker_context_status" == "denied" ]]; then
        worker_context_denial="$(singular_context_receipt_denial_reason "$worker_context_receipt" 2>/dev/null || true)"
        [[ "$worker_context_denial" != "campaign-mismatch" ]] \
          || l1_campaign_mismatch_exit "campaign policy changed before worker fallback admission"
        cat "$worker_classification_log" >&2
        echo "configured context service denied worker fallback ($worker_context_denial)" >&2
        attempt_failure="configured-context"
        attempt_ctx="$context_config"
        return 1
      elif [[ "$worker_context_status" == "admitted" ]]; then
        context_prior="$(singular_context_receipt_bundle_path "$worker_context_receipt" 2>/dev/null || true)"
        [[ -z "$context_prior" ]] || latest_worker_context_bundle="$context_prior"
      elif [[ "$context_enabled" == "1" ]]; then
        [[ "$worker_rc" -ne 2 ]] \
          || l1_campaign_mismatch_exit "campaign policy changed at worker fallback checkpoint"
        cat "$worker_classification_log" >&2
        echo "configured context service failed before worker invocation" >&2
        attempt_failure="configured-context"
        attempt_ctx="$context_config"
        return 1
      fi
      printf -- '--- worker resume-fallback try %s (attempt %s) ---\n' "$worker_try" "$n" \
        >>"$run_dir/worker-codex.log" || true
      cat "$worker_classification_log" >>"$run_dir/worker-codex.log" 2>/dev/null || true
    fi

    # Classify infra-vs-not. quota -> NOT infra (let the normal/breaker path own
    # it). timeout(rc 124)/empty-output(rc!=0, empty file) -> infra: retry the
    # worker only. invalid-output (output exists, rc 0) -> NOT infra; that is a
    # potential worker-no-packet handled by packet validation below.
    worker_fc="$(singular_planner_failure_class "$worker_classification_log" "$worker_rc" \
      "$run_dir/last-message.json" "$worker_result_file")"
    # "empty-output" only counts as infra when the runner itself failed (rc!=0);
    # a rc-0 run that emitted an empty file is a clean run with no packet (prose),
    # which is worker-no-packet, owned by the packet-validation path — NOT infra.
    [[ "$worker_fc" == "empty-output" && "$worker_rc" -eq 0 ]] && worker_fc="invalid-output"
    case "$worker_fc" in
      timeout|empty-output) : ;;          # infra: loop to re-run the worker
      *) break ;;                         # quota / codex-exit-with-output / clean: stop retrying
    esac
  done
  singular_append_event "l1.worker_completed" "l2 worker completed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
  # Persisted worker infra failure (still timeout/empty after the retry budget):
  # surface worker-infra so the fast-path decider parks it; retryCount untouched.
  if [[ "$worker_fc" == "timeout" || "$worker_fc" == "empty-output" ]]; then
    singular_append_event "worker.infra_exhausted" \
      "worker infrastructure retry budget exhausted" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"budgetDomain\":\"worker-infrastructure\",\"retriesUsed\":$worker_infra_max,\"maxExtraRetries\":$worker_infra_max,\"consumesProductRepairBudget\":false}" \
      || true
    attempt_failure="worker-infra"; attempt_ctx="$run_dir/worker-codex.log"
    return 1
  fi

  local worker_packet_log="$run_dir/worker-packet-validation.log"
  local worker_packet_ec=0
  singular_l1_prepare_worker_packet "$run_dir/last-message.json" "$run_dir/last-message.json" "$worker_packet_log" \
    || worker_packet_ec=$?
  if [[ "$worker_packet_ec" -ne 0 ]]; then
    case "$worker_packet_ec" in
      10|11)
        attempt_failure="worker-no-packet"; attempt_ctx="$run_dir/worker-codex.log" ;;
      *)
        attempt_failure="packet-invalid"; attempt_ctx="$worker_packet_log" ;;
    esac
    return 1
  fi

  if [[ -d "$worktree/.singular-evidence" ]]; then
    rm -rf "$run_dir/worker-evidence"; cp -R "$worktree/.singular-evidence" "$run_dir/worker-evidence"
  fi
  local storage_guard_log="$run_dir/module-packet-guard.log"
  if ! singular_packet_module_guard "$run_dir/last-message.json" "$task_file" "$worktree" "$run_dir" >"$storage_guard_log" 2>&1; then
    attempt_failure="packet-invalid"; attempt_ctx="$storage_guard_log"; return 1
  fi

  # Scope (owned allow + forbidden deny).
  local scope_args=(--worktree "$worktree" --base "$packet_base_ref")
  local f
  for f in "${owned_files[@]}"; do scope_args+=(--allow-prefix "$f"); done
  for f in "${forbidden_files[@]}"; do scope_args+=(--forbid-prefix "$f"); done
  local scope_rc=0
  "$SCRIPT_DIR/scope-check.sh" "${scope_args[@]}" >"$run_dir/scope-check.log" 2>&1 \
    || scope_rc=$?
  singular_check_result_write "$run_dir/scope-check-result.json" scope \
    "$([[ "$scope_rc" -eq 0 ]] && echo passed || echo failed)" \
    "$scope_rc" "$run_dir/scope-check.log"
  if [[ "$scope_rc" -ne 0 ]]; then
    attempt_failure="scope-violation"; attempt_ctx="$run_dir/scope-check.log"; return 1
  fi
  if singular_strict_proof_skip_detected "$task_file" "$worktree" "${owned_files[@]}"; then
    {
      echo "strict proof task introduced a skipped proof path"
      echo "task=$task_id"
      echo "owned_files=${owned_files[*]}"
      echo "acceptance forbids silent or skipped proof paths"
    } >"$run_dir/proof-skip-check.log"
    attempt_failure="proof-skip-detected"; attempt_ctx="$run_dir/proof-skip-check.log"; return 1
  fi

  # Regression gate.
  local gate_exit=0
  l1_status gating active "Running the worker regression gate for attempt $n" false \
    "Classify the gate and commit verified content" "" "gate-controller"
  singular_run_in_worktree_env "$worktree" "$SCRIPT_DIR/gate-check.sh" "$run_id" \
    --task-id "$task_id" --phase worker --workspace-kind worker \
    --task-contract "$task_file" -- \
    "$(singular_bash_bin)" -c "$gate_cmd" || gate_exit=$?
  local gate_outcome
  gate_outcome="$(singular_json_field "$run_dir/gate-report.json" outcome 2>/dev/null || true)"
  if [[ "$gate_exit" -ne 0 ]]; then
    if [[ "$gate_outcome" == "inconclusive-infrastructure" || -z "$gate_outcome" ]]; then
      attempt_failure="audit-infra"; attempt_ctx="$run_dir/gate-report.json"; return 1
    fi
    attempt_failure="gate-red"; attempt_ctx="$run_dir/gate-check.log"; return 1
  fi
  singular_append_event "l1.gate_passed" "regression gate passed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"outcome\":\"$gate_outcome\"}"

  # Stage the complete owned delta, including deletions, then scan both the
  # immutable committed range and every staged/working/untracked content surface.
  local stage_rc=0 tracked_scope_file="$run_dir/stage-owned-paths.z"
  local visible_scope_file="$run_dir/stage-visible-paths.z"
  for f in "${owned_files[@]}"; do
    if ! git -C "$worktree" ls-files -z -- "$f" >"$tracked_scope_file"; then
      stage_rc=2
      break
    fi
    if ! git -C "$worktree" status --porcelain=v1 -z --untracked-files=all -- "$f" \
        >"$visible_scope_file"; then
      stage_rc=2
      break
    fi
    # Ignored, untracked evidence is intentionally not a product commit.
    # Tracked paths still use -A so owned deletions and mode changes are staged.
    if [[ -s "$tracked_scope_file" || -s "$visible_scope_file" ]]; then
      git -C "$worktree" add -A -- "$f" || { stage_rc=$?; break; }
    fi
  done
  if [[ "$stage_rc" -ne 0 ]]; then
    attempt_failure="commit-failed"; attempt_ctx="$run_dir/stage-owned-paths.z"; return 1
  fi
  local secret_rc=0
  "$SCRIPT_DIR/secret-scan.sh" --worktree "$worktree" --base "$packet_base_ref" \
    >"$run_dir/secret-scan.log" 2>&1 || secret_rc=$?
  singular_check_result_write "$run_dir/secret-scan-result.json" secret \
    "$([[ "$secret_rc" -eq 0 ]] && echo passed || echo failed)" \
    "$secret_rc" "$run_dir/secret-scan.log"
  if [[ "$secret_rc" -ne 0 ]]; then
    git -C "$worktree" reset -q >/dev/null 2>&1 || true
    attempt_failure="secret-detected"; attempt_ctx="$run_dir/secret-scan.log"; return 1
  fi
  local cached_diff_rc=0
  git -C "$worktree" diff --cached --quiet || cached_diff_rc=$?
  if [[ "$cached_diff_rc" -eq 0 ]]; then
    # Empty staged diff. If the owned files at HEAD already differ from the
    # base — a PRIOR attempt committed the content — and the gate above just
    # passed, this is a valid empty-diff retry, not a failure. 0.4.0 raised
    # `no-changes` here, the decider's revalidate-evidence could not audit a
    # no-change replay, and fully green work terminally parked (field audit:
    # TASK-0052/0053). Truly-no-content (HEAD == base on owned paths) still
    # fails as before.
    local owned_diff_rc=0
    git -C "$worktree" diff --quiet "$packet_base_ref"...HEAD -- "${owned_files[@]}" 2>/dev/null \
      || owned_diff_rc=$?
    if [[ "$owned_diff_rc" -eq 1 ]]; then
      singular_append_event "l1.no_changes_reconciled" \
        "gate green and owned content already committed at HEAD; proceeding with empty diff" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$(git -C "$worktree" rev-parse HEAD)\"}"
      head_sha="$(git -C "$worktree" rev-parse HEAD)"
    else
      # rc 0 = no content vs base; rc >1 = diff failed — both fail conservatively.
      attempt_failure="no-changes"; attempt_ctx="$run_dir/worker-codex.log"; return 1
    fi
  elif [[ "$cached_diff_rc" -eq 1 ]]; then
    singular_git_lock_acquire
    local commit_ec=0
    set +e
    git -C "$worktree" -c user.name="$SINGULAR_GIT_L1_NAME" -c user.email="$SINGULAR_GIT_L1_EMAIL" \
      commit -q -m "$task_id: ${test_policy} worker output (run $run_id)" \
      -m "Driven by L1 from $packet_base_ref. Owned: ${owned_files[*]}."
    commit_ec=$?
    set -e
    singular_git_lock_release
    if [[ "$commit_ec" -ne 0 ]]; then
      attempt_failure="commit-failed"; attempt_ctx="$run_dir/worker-codex.log"; return 1
    fi
    head_sha="$(git -C "$worktree" rev-parse HEAD)"
    singular_append_event "l1.committed" "worker branch committed" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$head_sha\"}"
  else
    attempt_failure="commit-failed"; attempt_ctx="$run_dir/worker-codex.log"; return 1
  fi

  # The gate ran immediately before commit. Bind its command and full-log
  # hashes to the commit containing those exact tested bytes.
  if ! "$SCRIPT_DIR/gate-report.py" bind-head \
      --report "$run_dir/gate-report.json" --head-sha "$head_sha" --task-id "$task_id" \
      >"$run_dir/gate-report-bind.log" 2>&1 \
    || ! cp "$run_dir/gate-report.json" "$run_dir/gate-check.json"; then
    attempt_failure="audit-infra"; attempt_ctx="$run_dir/gate-report-bind.log"; return 1
  fi

  local changed_json
  if ! changed_json="$(python3 "$SCRIPT_DIR/git_changes.py" --worktree "$worktree" \
      --base "$packet_base_ref" --head "$head_sha")"; then
    attempt_failure="packet-invalid"; attempt_ctx="$run_dir/packet.json"; return 1
  fi
  python3 - "$run_dir/last-message.json" "$packet" "$run_id" "$task_id" "$area" \
    "$worker_branch" "$packet_base_ref" "$head_sha" "$worktree" \
    "$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')" \
    "$changed_json" \
    "$l1_campaign_binding" <<'PY'
import json, sys
(src,dst,run_id,task_id,area,branch,base_ref,head_sha,workspace,owned_json,changed_json,campaign_binding)=sys.argv[1:13]
with open(src) as f: p=json.load(f)
p["schema"]="singular.orchestration.state-packet.v0"; p["runId"]=run_id; p["taskId"]=task_id
p["area"]=area; p["role"]=p.get("role") or "l2-developer"; p["baseRef"]=base_ref
p["branch"]=branch; p["headSha"]=head_sha; p["workspace"]=workspace
p["ownedFiles"]=json.loads(owned_json)
changed=json.loads(changed_json)
p["changedFiles"]=changed
p.setdefault("packetId",f"{run_id}-packet")
for k in ("commands","tests","evidence","blockers"): p.setdefault(k,[])
p.setdefault("nextAction","await auditor verdict"); p.setdefault("status","needs-review")
p["evidence"].append({"kind":"gate-report","ref":f"runs/{run_id}/gate-report.json"})
p["evidence"] = [item for item in p["evidence"] if item.get("kind") != "campaign-binding"]
p["evidence"].append({"kind":"campaign-binding","ref":campaign_binding})
with open(dst,"w") as f: json.dump(p,f,indent=2); f.write("\n")
PY
  singular_validate_packet_basic "$packet" >/dev/null 2>&1 || { attempt_failure="packet-invalid"; attempt_ctx="$packet"; return 1; }

  # Compact, hash-bound reviewer input. Full raw evidence remains available
  # only through evidence-show.sh's declared-reference and byte-budget checks.
  local manifest_rc=0
  l1_build_evidence_manifest \
    "pre-audit-build" "$run_dir/evidence-manifest-build.log" || manifest_rc=$?
  if [[ "$manifest_rc" -ne 0 ]]; then
    [[ "$manifest_rc" -eq 2 ]] && attempt_failure="evidence-invalid" || attempt_failure="audit-infra"
    attempt_ctx="$run_dir/evidence-manifest-build.log"; return 1
  fi

  # Implementer context capsule (additive observability; never aborts the
  # drive). Scope arrays are the CURRENT post-amend scope, not the packet's.
  local capsule_owned capsule_forbidden
  capsule_owned="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  capsule_forbidden="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  singular_capsule_write_implementer "$run_dir" "$n" "$packet" "$head_sha" "$capsule_owned" "$capsule_forbidden" >/dev/null 2>&1 \
    || singular_append_event "l1.capsule_write_failed" "implementer capsule write failed (non-fatal)" \
         "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n}" || true

  # Assumption ledger (node assumption-ledger; behind SINGULAR_CTX_PACKET): record this
  # attempt's ledger (assumption statuses) alongside the implementer capsule write,
  # additively and non-fatally. No-op when OFF.
  assumptions_record_capsule "$n" || true

  # Session affinity (T-E5): merge host-authority fields into the runner-written
  # implementer meta so the NEXT attempt can resume it. headShaAtCreate = the
  # committed head (the lineage anchor the resume decider checks). Never fatal.
  singular_session_meta_finalize "$session_meta_implementer" implementer "$task_id" "$run_id" \
    "$l2_runner_basename" "$worker_prompt_sha" "$head_sha" "$n" >/dev/null 2>&1 || true
  return 0
}

# Dual-read the legacy v0 audit contract and the v1 verification contract.
validate_audit_record() {
  local record="$1" schema
  schema="$(singular_json_field "$record" schema 2>/dev/null || true)"
  if [[ "$schema" == "singular.orchestration.audit-verdict.v1" ]]; then
    SINGULAR_AUDIT_SCHEMA="$SINGULAR_SCHEMA_DIR/audit-verdict.v1.schema.json" \
      singular_validate_audit_verdict "$record" "$task_id" "$run_id"
  else
    singular_validate_audit_verdict "$record" "$task_id" "$run_id"
  fi
}

# Render a fresh auditor repair prompt after a structurally parseable response
# fails schema validation or host binding. The retry count remains owned by the
# existing SINGULAR_AUDIT_INFRA_MAX loop; this helper only makes the next retry
# actionable instead of replaying an unchanged prompt.
render_audit_repair_prompt() {
  local base_prompt="$1" output_prompt="$2" error_file="$3"
  local invalid_response_file="$4" contract="$5"
  python3 - "$base_prompt" "$output_prompt" "$error_file" \
    "$invalid_response_file" "$contract" <<'PY'
import json
import sys

base_path, output_path, error_path, invalid_path, contract = sys.argv[1:6]

def read_bounded(path, limit):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        value = handle.read(limit + 1)
    if len(value) > limit:
        value = value[:limit] + "\n[truncated by host]"
    return value

with open(base_path, "r", encoding="utf-8") as handle:
    base = handle.read()
error = read_bounded(error_path, 8192)
invalid = read_bounded(invalid_path, 65536)

if contract == "v1":
    required_contract = """Return exactly one audit-verdict.v1 JSON object.
Required top-level members: schema, taskId, runId, branch, verdict,
evidenceReviewed, verificationResults, commandsRun, findings, requiredFixes,
and rationale. No other top-level members are allowed except optional
findingsStatus, classifiedFindings, and reviewPolicy. Each
verificationResults[] object requires exactly status, command, evidenceRefs,
and rationale; optional integer exitCode is also allowed. status must be one
of passed, failed-product, inconclusive-infrastructure, or
not-rerun-evidence-verified. command and rationale must be non-empty strings.
evidenceRefs must be an array of non-empty strings."""
else:
    required_contract = """Return exactly one audit-verdict.v0 JSON object.
Required top-level members: schema, taskId, runId, branch, verdict,
evidenceReviewed, commandsRun, findings, requiredFixes, and rationale. No
other top-level members are allowed except optional findingsStatus."""

repair_input = json.dumps(
    {
        "validatorOrBinderError": error,
        "invalidResponse": invalid,
    },
    ensure_ascii=False,
    indent=2,
)
repair = f"""

---

## Audit Verdict Repair (authoritative)

Your previous response was rejected before its verdict could influence
acceptance. Produce a corrected response from a fresh evaluation. Do not repeat
the invalid shape.

{required_contract}

The host-supplied prior error and invalid response are:

<audit-repair-input>
{repair_input}
</audit-repair-input>

Emit ONLY the corrected JSON object.
"""
with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(base + repair)
PY
}

append_audit_evidence() {
  python3 - "$packet" "$run_id" <<'PY'
import json
import sys

packet, run_id = sys.argv[1:3]
with open(packet, encoding="utf-8") as handle:
    data = json.load(handle)
refs = [
    ("audit", f"runs/{run_id}/audit.json"),
    ("audit-verification", f"runs/{run_id}/audit-verification.json"),
    ("evidence-manifest", f"runs/{run_id}/evidence-manifest.json"),
]
for kind, ref in refs:
    if not any(e.get("kind") == kind and e.get("ref") == ref for e in data["evidence"]):
        data["evidence"].append({"kind": kind, "ref": ref})
with open(packet, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

# Preserve an exact-head product acceptance when only evidence finalization is
# unavailable.  The packet remains non-publishable (`blocked`) and records a
# machine-readable external blocker, while audit.json remains the authoritative
# product verdict.  This path is deliberately outside the product repair loop:
# repairing evidence infrastructure cannot require another implementation.
mark_product_audit_awaiting_evidence() {
  local stage="$1" context_ref="$2"
  python3 - "$packet" "$task_id" "$run_id" "$head_sha" "$audit_record" \
    "$stage" "$context_ref" <<'PY'
import json
import os
import sys

packet_path, task_id, run_id, head_sha, audit_path, stage, context_ref = sys.argv[1:8]
with open(packet_path, encoding="utf-8") as stream:
    packet = json.load(stream)

blocker = {
    "class": "blocked-external",
    "reason": "awaiting-evidence",
    "stage": stage,
    "taskId": task_id,
    "runId": run_id,
    "headSha": head_sha,
    "productAuditVerdict": "accepted",
    "auditRef": os.path.basename(audit_path),
    "contextRef": os.path.basename(context_ref) if context_ref else "unavailable",
    "consumesProductRepairBudget": False,
}
blockers = packet.setdefault("blockers", [])
if not any(
    isinstance(item, dict)
    and item.get("reason") == "awaiting-evidence"
    and item.get("headSha") == head_sha
    for item in blockers
):
    blockers.append(blocker)
packet["status"] = "blocked"
packet["nextAction"] = (
    "repair evidence infrastructure and resume publication for the accepted "
    "head; do not rerun implementation or product review"
)
temporary = packet_path + ".awaiting-evidence.tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(packet, stream, indent=2)
    stream.write("\n")
os.replace(temporary, packet_path)
PY
}

write_host_audit_verdict() {
  local verification_status="$1" host_verdict="$2" rationale="$3"
  python3 - "$audit_record" "$run_dir/audit-verification.json" "$task_id" "$run_id" \
    "$worker_branch" "$verification_status" "$host_verdict" "$rationale" "$gate_cmd" \
    "$audit_write_contract" <<'PY'
import json
import sys

(output, report_path, task_id, run_id, branch, status, verdict, rationale,
 command, contract) = sys.argv[1:11]
try:
    report = json.load(open(report_path, encoding="utf-8"))
except Exception:
    report = {}
finding = rationale
unexpected = report.get("unexpectedFailures")
if isinstance(unexpected, list) and unexpected and isinstance(unexpected[0], dict):
    finding = str(unexpected[0].get("title") or rationale)
exit_code = report.get("rawExitCode")
verification = {
    "status": status,
    "command": command,
    "evidenceRefs": [f"runs/{run_id}/audit-verification.json"],
    "rationale": rationale,
}
if isinstance(exit_code, int):
    verification["exitCode"] = exit_code
data = {
    "schema": f"singular.orchestration.audit-verdict.{contract}",
    "taskId": task_id,
    "runId": run_id,
    "branch": branch,
    "verdict": verdict,
    "evidenceReviewed": [
        f"runs/{run_id}/evidence-manifest.json",
        f"runs/{run_id}/audit-verification.json",
    ],
    "commandsRun": [command],
    "findings": [finding],
    "requiredFixes": [finding] if status == "failed-product" else [],
    "rationale": rationale,
}
if contract == "v1":
    data["verificationResults"] = [verification]
with open(output, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

# Auditor invocation through verdict extraction + packet evidence append.
# Sets verdict, attempt_failure, attempt_ctx, audit_rc. Returns 0 when the
# attempt is acceptable (verdict accepted, or audits disabled), 1 otherwise.
run_audit_phase() {
  local n="$1"
  local audit_infra_max="${audit_infra_max:-${SINGULAR_AUDIT_INFRA_MAX:-1}}"
  local verify_infra_max="${verify_infra_max:-${SINGULAR_AUDIT_VERIFY_INFRA_MAX:-1}}"
  [[ "$audit_infra_max" =~ ^[0-9]+$ ]] || audit_infra_max=1
  [[ "$verify_infra_max" =~ ^[0-9]+$ ]] || verify_infra_max=1
  [[ "$audit_infra_max" -gt 1 ]] && audit_infra_max=1
  [[ "$verify_infra_max" -gt 1 ]] && verify_infra_max=1
  local model_verification_status=""
  l1_status auditing active "Verifying committed evidence for attempt $n" true \
    "Classify host verification and obtain the audit verdict" "" "audit-controller"

  # Re-audit delta prompt (T-E4). prior_head is the existing reviewer capsule's
  # auditedHeadSha (read BEFORE the capsule is overwritten this attempt) — the
  # SHA the auditor last reviewed. Render to a NEW per-attempt file and pass THAT
  # to the runner; on attempt 1 / no capsule / empty prior_head the renderer is a
  # plain copy (byte-identical to the base audit prompt). Renderer failure ->
  # warning event + fall back to the base audit prompt.
  local prior_head active_audit_prompt="$run_dir/auditor-active-prompt.md"
  prior_head="$(singular_json_field "$run_dir/reviewer-capsule.json" auditedHeadSha 2>/dev/null || true)"
  export SINGULAR_REVIEW_ROUND_LABEL="Round $n of $review_max_rounds"
  if singular_render_reaudit_prompt "$active_audit_prompt" "$audit_prompt" "$run_dir" "$n" \
       "$prior_head" "$head_sha" "$worktree" 2>/dev/null; then
    :
  else
    singular_append_event "l1.reaudit_prompt_fallback" "re-audit prompt render failed; using base audit prompt" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
    if cp "$audit_prompt" "$active_audit_prompt" 2>/dev/null; then
      singular_review_round_policy_append "$active_audit_prompt" 2>/dev/null || true
    else
      active_audit_prompt="$audit_prompt"
    fi
  fi
  unset SINGULAR_REVIEW_ROUND_LABEL

  # Assumption ledger (node assumption-ledger; behind SINGULAR_CTX_PACKET): inject the
  # assembled auditSection (staged at attempt-open) into the per-attempt auditor prompt
  # so the auditor verifies the assumptions and flags violations citing the assumption
  # id. No-op when OFF (byte-identical) and never aborts the drive.
  assumptions_inject_audit "$active_audit_prompt" || true

  local verification_outcome="" verification_integrity="" verification_rc=0
  local host_verification_status=""
  local verification_try=0 verification_ready="no"

  # Disposable rerun policy (0.21.0). SINGULAR_AUDIT_VERIFY:
  #   1     always rerun the committed gate in a disposable worktree (0.20 default)
  #   0     never rerun; hash-bound worker evidence only
  #   auto  (default) rerun only when the worker gate cannot stand on its own:
  #         a high-risk task, a worker gate that is not a clean `passed` at this
  #         exact head, a source-integrity anomaly, or a report from another
  #         phase. Otherwise the host-executed worker gate (it ran under
  #         gate-check.sh, not under the model) is the audit's gate evidence,
  #         and the exact-tree integration gate remains the clean-checkout proof.
  # In the field the rerun repeated a suite the host had just run, on every
  # attempt of every task, and was the largest single share of gate time.
  local audit_verify_mode="${SINGULAR_AUDIT_VERIFY:-auto}" audit_verify_run="yes"
  local audit_verify_reason=""
  case "$audit_verify_mode" in
    1) audit_verify_run="yes"; audit_verify_reason="always" ;;
    0) audit_verify_run="no"; audit_verify_reason="disabled" ;;
    *)
      audit_verify_reason="$(python3 - "$run_dir/gate-report.json" "$head_sha" "$risk_tier" <<'PY'
import json, sys
report_path, head, tier = sys.argv[1:4]
try:
    report = json.load(open(report_path, encoding="utf-8"))
except Exception:
    print("rerun:worker-gate-report-unreadable"); raise SystemExit(0)
if tier == "high":
    print("rerun:high-risk"); raise SystemExit(0)
if report.get("outcome") != "passed":
    print("rerun:worker-gate-outcome-%s" % (report.get("outcome") or "unknown")); raise SystemExit(0)
if (report.get("sourceIntegrity") or {}).get("status") != "verified":
    print("rerun:worker-gate-integrity-unverified"); raise SystemExit(0)
if report.get("phase") != "worker" or report.get("workspaceKind") != "worker":
    print("rerun:worker-gate-phase-mismatch"); raise SystemExit(0)
if not head or report.get("headSha") != head:
    print("rerun:worker-gate-head-mismatch"); raise SystemExit(0)
print("skip:host-executed-worker-gate-verified")
PY
)"
      if [[ "$audit_verify_reason" == skip:* ]]; then
        audit_verify_run="no"
      else
        audit_verify_run="yes"
      fi
      ;;
  esac
  if [[ "$audit_verify_run" == "no" && "$audit_verify_mode" != "0" ]]; then
    singular_append_event "audit.verification_skipped" \
      "disposable gate rerun skipped; hash-bound host-executed worker gate stands" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"mode\":\"$audit_verify_mode\",\"reason\":\"${audit_verify_reason#skip:}\",\"riskTier\":\"$risk_tier\"}" || true
  fi

  local verification_request="$run_dir/verification-request-${n}.json"
  local verification_task_contract="$run_dir/verification-task-contract-${n}.md"
  local verification_policy="$run_dir/verification-policy-${n}.json"
  local verification_tree=""
  verification_tree="$(git -C "$worktree" rev-parse "$head_sha^{tree}" 2>/dev/null || true)"
  local verification_contract_rc=0
  cp "$task_file" "$verification_task_contract" || verification_contract_rc=$?
  if [[ "$verification_contract_rc" -eq 0 ]]; then
    python3 - "$verification_policy" "$l1_campaign_binding" "$gate_cmd" <<'PY' \
      || verification_contract_rc=$?
import json, os, sys
path, campaign, gate_command = sys.argv[1:4]
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump({
        "campaign": campaign,
        "gateCommand": gate_command,
        "policy": campaign,
    }, handle, sort_keys=True)
    handle.write("\n")
os.replace(temporary, path)
PY
  fi
  if [[ "$verification_contract_rc" -ne 0 \
      || ! "$verification_tree" =~ ^[0-9a-fA-F]{40,64}$ ]] \
      || ! "$SCRIPT_DIR/gate-report.py" create-verification-request \
          --output "$verification_request" --task-id "$task_id" --run-id "$run_id" \
          --attempt "$n" --head-sha "$head_sha" --tree-sha "$verification_tree" \
          --campaign "$l1_campaign_binding" --task-contract "$verification_task_contract" \
          --policy-contract "$verification_policy" --suite-id "task-contract-gate" \
          >"$run_dir/verification-request-${n}.out" \
          2>"$run_dir/verification-request-${n}.err"; then
      write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
        "The host could not bind verification to the trusted task/policy contract."
      verdict="blocked"
      append_audit_evidence
      attempt_failure="audit-infra"
      attempt_ctx="$run_dir/verification-request-${n}.err"
    return 1
  fi

  # Re-run the committed gate in a disposable writable worktree. Cache and log
  # writes are isolated there; the original audited worktree remains untouched.
  if [[ "$audit_verify_run" == "yes" ]]; then
    for ((verification_try=0; verification_try<=verify_infra_max; verification_try++)); do
      if [[ "$verification_try" -gt 0 ]]; then
        singular_append_event "audit.verification_infra_retry" \
          "audit verification infrastructure failure; retrying disposable gate only" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$verification_try,\"budgetDomain\":\"verification-infrastructure\",\"maxExtraRetries\":$verify_infra_max,\"consumesProductRepairBudget\":false}" || true
      fi
      verification_rc=0
      "$SCRIPT_DIR/audit-verify.sh" \
        --run-dir "$run_dir" --task-id "$task_id" --source-worktree "$worktree" \
        --head-sha "$head_sha" --gate-command "$gate_cmd" \
        --worker-gate-report "$run_dir/gate-report.json" \
        --verification-request "$verification_request" \
        --task-contract "$verification_task_contract" --policy-contract "$verification_policy" \
        --attempt "$n" --try "$verification_try" \
        >"$run_dir/audit-verification-driver.log" 2>&1 || verification_rc=$?
      verification_outcome="$(singular_json_field "$run_dir/audit-verification.json" outcome 2>/dev/null || true)"
      verification_integrity="$(
        singular_json_field "$run_dir/audit-verification.json" sourceIntegrity.status \
          2>/dev/null || true
      )"
      if [[ "$verification_integrity" == "violation" ]]; then
        # A gate that tries to modify committed source has crossed the audit
        # integrity boundary. Never mask that deterministic violation with the
        # worker's earlier evidence-only report.
        write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
          "The independently rerun gate attempted to mutate committed source; the disposable worktree was discarded and evidence-only substitution is forbidden."
        verdict="blocked"
        append_audit_evidence
        attempt_failure="integrity-violation"
        attempt_ctx="$run_dir/audit-verification.json"
        singular_append_event "audit.source_integrity_violation" \
          "audit gate attempted source mutation; task parked without evidence-only fallback" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$verification_try,\"contextRef\":\"$(basename "$attempt_ctx")\"}" \
          || true
        return 1
      fi
      case "$verification_outcome" in
        passed|passed-with-acknowledged-baseline|not-rerun-evidence-verified)
          if [[ "$verification_rc" -eq 0 ]]; then
            verification_ready="yes"
            break
          fi
          ;;
        failed-product)
          if [[ "$verification_rc" -eq 10 ]]; then
            write_host_audit_verdict "failed-product" "needs-fix" \
              "The independently rerun gate failed with a product-test signal at the committed head."
            verdict="needs-fix"
            append_audit_evidence
            singular_append_event "l1.audit_completed" "host audit verification found a product failure" \
              "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"needs-fix\",\"verification\":\"failed-product\"}"
            attempt_failure="audit-needs-fix"
            attempt_ctx="$run_dir/audit-verification.json"
            return 1
          fi
          ;;
        *)
          : # infrastructure/invalid report: bounded disposable retry
          ;;
      esac
    done
  fi

  # A deterministic, successful worker gate may substitute only after every
  # disposable rerun was infrastructure-inconclusive (or reruns were disabled).
  if [[ "$verification_ready" != "yes" ]]; then
    if [[ "$audit_verify_run" == "yes" ]]; then
      singular_append_event "audit.verification_infra_exhausted" \
        "disposable verification retry budget exhausted; checking exact evidence" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"budgetDomain\":\"verification-infrastructure\",\"retriesUsed\":$verify_infra_max,\"maxExtraRetries\":$verify_infra_max,\"consumesProductRepairBudget\":false}" \
        || true
    fi
    verification_rc=0
    "$SCRIPT_DIR/audit-verify.sh" \
      --run-dir "$run_dir" --task-id "$task_id" --source-worktree "$worktree" \
      --head-sha "$head_sha" --gate-command "$gate_cmd" \
      --worker-gate-report "$run_dir/gate-report.json" \
      --worker-gate-command "$(singular_bash_bin) -c $gate_cmd" --evidence-only \
      --verification-request "$verification_request" \
      --task-contract "$verification_task_contract" --policy-contract "$verification_policy" \
      --attempt "$n" \
      >"$run_dir/audit-verification-evidence-only.log" 2>&1 || verification_rc=$?
    verification_outcome="$(singular_json_field "$run_dir/audit-verification.json" outcome 2>/dev/null || true)"
    if [[ "$verification_rc" -eq 0 && "$verification_outcome" == "not-rerun-evidence-verified" ]]; then
      verification_ready="yes"
      singular_append_event "audit.evidence_only_verified" \
        "disposable rerun inconclusive; hash-bound worker gate evidence verified" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
    else
      write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
        "The gate could not be rerun in a disposable workspace and the original gate evidence did not verify."
      verdict="blocked"
      append_audit_evidence
      singular_append_event "l1.audit_completed" "audit verification infrastructure failure" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"infra\",\"verification\":\"inconclusive-infrastructure\"}"
      attempt_failure="audit-infra"
      attempt_ctx="$run_dir/audit-verification.json"
      return 1
    fi
  fi

  # The report outcome is only descriptive until the complete request/result
  # binding validates. Reject a failed validator before any paid auditor sees
  # the report, even when stale JSON still says "passed".
  if ! singular_validate_verification_binding \
      "$verification_request" "$run_dir/audit-verification.json" \
      "$verification_task_contract" "$verification_policy" \
      "$task_id" "$run_id" "$head_sha" "$verification_tree" "$task_file" \
      "$l1_campaign_binding" "$n" \
      >"$run_dir/verification-consumption-${n}.out" \
      2>"$run_dir/verification-consumption-${n}.err"; then
    write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
      "The host verification request/result binding was rejected before audit."
    verdict="blocked"
    append_audit_evidence
    attempt_failure="audit-infra"
    attempt_ctx="$run_dir/verification-consumption-${n}.err"
    return 1
  fi

  # The host owns verification classification. In particular, successful
  # hash-bound evidence-only validation is not equivalent to a real rerun.
  # Normalize only the acknowledged-baseline success alias; every other v1
  # classification remains exact.
  if ! host_verification_status="$(
    python3 "$SCRIPT_DIR/audit-verdict-host-bind.py" \
      --host-report "$run_dir/audit-verification.json" 2>/dev/null
  )"; then
    write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
      "The host verification report did not contain a supported classification."
    verdict="blocked"
    append_audit_evidence
    attempt_failure="audit-infra"
    attempt_ctx="$run_dir/audit-verification.json"
    return 1
  fi

  # Refresh the compact manifest so it includes the host verification report.
  local manifest_rc=0
  l1_build_evidence_manifest \
    "host-verification-refresh" "$run_dir/evidence-manifest-audit-refresh.log" || manifest_rc=$?
  if [[ "$manifest_rc" -ne 0 ]]; then
    write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
      "The host verification completed, but its hash-bound evidence manifest could not be refreshed."
    verdict="blocked"
    append_audit_evidence
    [[ "$manifest_rc" -eq 2 ]] && attempt_failure="evidence-invalid" || attempt_failure="audit-infra"
    attempt_ctx="$run_dir/evidence-manifest-audit-refresh.log"
    return 1
  fi

  # Give the model the exact host-derived value it must reproduce. Use a
  # per-attempt copy so a prompt-render fallback can never mutate the reusable
  # base prompt.
  local bound_audit_prompt="$run_dir/auditor-bound-prompt-attempt-$n.md"
  if ! cp "$active_audit_prompt" "$bound_audit_prompt" \
    || ! python3 - "$bound_audit_prompt" "$host_verification_status" <<'PY'
import sys

path, classification = sys.argv[1:3]
with open(path, "a", encoding="utf-8") as handle:
    handle.write(
        "\n\n---\n\n"
        "## Host Verification Binding (authoritative)\n\n"
        f"The host verification classification is `{classification}`. "
        "For audit-verdict.v1, the aggregate of verificationResults.status "
        "MUST equal this exact value. Do not report `passed` for "
        "`not-rerun-evidence-verified`.\n"
    )
PY
  then
    write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
      "The host verification completed, but its classification could not be bound into the auditor prompt."
    verdict="blocked"
    append_audit_evidence
    attempt_failure="audit-infra"
    attempt_ctx="$bound_audit_prompt"
    return 1
  fi
  active_audit_prompt="$bound_audit_prompt"

  # Auditors always assemble from a fresh review-target snapshot. The service
  # enforces the review trust boundary by excluding run/model-authored sources,
  # even if a wildcard role policy is accidentally permissive.
  local audit_context_bundle="$run_dir/context-review-target-attempt-${n}.bundle.json"
  local audit_context_config="${SINGULAR_CONTEXT_CONFIG_FILE:-${SINGULAR_JSON_CONFIG_FILE:-$SINGULAR_ROOT/singular.config.json}}"
  local audit_context_task="$task_file"
  audit_context_task="$(singular_context_worktree_path "$task_file" "$worktree")"
  # ---- Auditor runner with bounded infra-retry (T-E6) -----------------------
  # An auditor "infra failure" is the runner itself timing out (rc 124) / refusing
  # (later-wave rc 86), the record file never appearing, or output that carries no
  # parseable JSON verdict (broken/empty model output, the l1.audit_unparseable
  # path) — distinct from a real needs-fix verdict. We re-run ONLY the auditor,
  # fresh (no session reuse), up to SINGULAR_AUDIT_INFRA_MAX extra times. This never
  # bumps the lease retryCount and never re-runs the worker. If a parseable verdict
  # appears on any try, we proceed to the normal ledger/capsule/verdict handling;
  # if exhausted, the attempt fails as audit-infra and the (fast-path) decider parks it.
  verdict="unknown"

  # ---- Session affinity (T-E5): reviewer resume decision (first try only) ----
  # The auditor runs on $audit_runner (role-runner, default SINGULAR_RUNNER_BIN).
  # It uses a SEPARATE per-role meta file + role gate, so the reviewer can NEVER
  # be offered the implementer's session. Lineage head = head_sha (the audited
  # head). prompt_sha is the BASE auditor prompt (the active prompt is per-attempt
  # delta).
  local audit_runner_basename reviewer_prompt_sha reviewer_resume_id="" reviewer_decision
  audit_runner_basename="$(basename "$audit_runner")"
  reviewer_prompt_sha="$(singular_prompt_sha "$audit_prompt" 2>/dev/null || true)"
  # Routed through the ctx-* adapter (SINGULAR_CTX_ROUTING; default 1). Step
  # `final-audit` is an independence-required step, so the taint pin binds here in
  # EVERY configuration — including SINGULAR_CTX_ROUTING=0 — and a would-be resume
  # is refused as `fresh tainted`. This is the one step the routing flag cannot
  # reach; the auditor never grades a diff from inside its own prior verdict.
  reviewer_decision="$(singular_ctx_route_decide reviewer final-audit "$session_meta_reviewer" \
    "$task_id" "$run_id" "$audit_runner_basename" "$reviewer_prompt_sha" "$worktree" "$head_sha" 2>/dev/null || echo "fresh decide-error")"
  reviewer_strategy="${reviewer_decision%% *}"
  reviewer_strategy_reason="${reviewer_decision#* }"
  if [[ "$reviewer_strategy" == "resume" ]]; then
    reviewer_resume_id="$reviewer_strategy_reason"; reviewer_strategy_reason="resume"
    singular_append_event "context.strategy_selected" "session resume strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"strategy\":\"resume\",\"reason\":\"resume\",\"sessionId\":\"$reviewer_resume_id\"}" || true
  else
    singular_append_event "context.strategy_selected" "fresh-run strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"strategy\":\"fresh\",\"reason\":\"$reviewer_strategy_reason\"}" || true
  fi
  local reviewer_resume_failed="no"

  local audit_parsed="no" audit_try infra_reason audit_result_file audit_fc
  local audit_context_status audit_context_denial
  local audit_capability_profile
  local audit_pid="" audit_child_pgid=""
  local audit_schema audit_validation_rc
  local audit_repair_error_file="" audit_repair_response_file=""
  local audit_prompt_for_try repair_prompt
  # Auditor runner output is durable (0.6.0): the console streams it as a
  # labeled session pane; previously it went to /dev/null.
  local auditor_log="$run_dir/auditor-codex.log"
  local review_check_file="$run_dir/review-policy-check-attempt-${n}.json"
  local review_check_err="$run_dir/review-policy-check-attempt-${n}.err"
  local review_check_rc=0
  python3 "$SCRIPT_DIR/review_policy.py" check \
    --logical-change "$review_logical_change" --task "$task_id" \
    >"$review_check_file" 2>"$review_check_err" || review_check_rc=$?
  if [[ "$review_check_rc" -eq 4 ]]; then
    local review_used review_allowed
    review_used="$(singular_json_field "$review_check_file" used 2>/dev/null || echo 0)"
    review_allowed="$(singular_json_field "$review_check_file" allowedRounds 2>/dev/null || echo 0)"
    singular_append_event "review.rounds_exhausted" \
      "review rounds exhausted; auditor not launched" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"logicalChange\":\"$review_logical_change\",\"used\":$review_used,\"allowedRounds\":$review_allowed}" \
      || true
    attempt_failure="review-rounds-exhausted"
    attempt_ctx="$review_check_file"
    return 1
  elif [[ "$review_check_rc" -ne 0 ]]; then
    attempt_failure="audit-infra"
    attempt_ctx="$review_check_err"
    [[ -s "$review_check_err" ]] || attempt_ctx="$review_check_file"
    return 1
  fi
  for ((audit_try=0; audit_try<=audit_infra_max; audit_try++)); do
    if [[ "$audit_try" -gt 0 ]]; then
      singular_append_event "audit.infra_retry" "auditor infra failure; re-running auditor only" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$audit_try,\"reason\":\"$infra_reason\",\"budgetDomain\":\"auditor-infrastructure\",\"maxExtraRetries\":$audit_infra_max,\"consumesProductRepairBudget\":false}"
      echo "  auditor infra retry $audit_try/$audit_infra_max ($infra_reason)..."
    fi
    audit_prompt_for_try="$active_audit_prompt"
    if [[ "$audit_try" -gt 0 && -n "$audit_repair_error_file" \
        && -n "$audit_repair_response_file" ]]; then
      repair_prompt="$run_dir/auditor-repair-prompt-attempt-${n}-try-${audit_try}.md"
      if ! render_audit_repair_prompt "$active_audit_prompt" "$repair_prompt" \
          "$audit_repair_error_file" "$audit_repair_response_file" \
          "$audit_write_contract"; then
        infra_reason="repair-prompt-failed"
        singular_append_event "l1.audit_repair_prompt_failed" \
          "auditor validation-feedback repair prompt could not be rendered" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$audit_try}" \
          || true
        break
      fi
      audit_prompt_for_try="$repair_prompt"
      singular_append_event "l1.audit_repair_retry" \
        "auditor validation-feedback repair retry prepared" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$audit_try,\"reason\":\"$infra_reason\"}" \
        || true
    fi
    # Resume only on the FIRST try; wave-4 audit-infra retries stay FRESH.
    local audit_run_args=(--level readonly -C "$worktree" --run-id "$run_id" \
      --prompt-file "$audit_prompt_for_try" --output-last-message "$audit_record" \
      --session-meta "$session_meta_reviewer")
    if [[ "$audit_try" -eq 0 && -n "$reviewer_resume_id" && "$reviewer_resume_failed" == "no" ]]; then
      echo "  running auditor via $audit_runner_basename (read-only, resume $reviewer_resume_id)..."
      audit_run_args+=(--resume-session "$reviewer_resume_id")
      audit_result_file="$run_dir/auditor-attempt-${n}-try-${audit_try}-resume-runner-result.json"
    else
      echo "  running auditor via $audit_runner_basename (read-only)..."
      audit_result_file="$run_dir/auditor-attempt-${n}-try-${audit_try}-runner-result.json"
    fi
    audit_rc=0
    rm -f "$audit_record"
    printf -- '--- auditor try %s (attempt %s) ---\n' "$audit_try" "$n" >>"$auditor_log" || true
    audit_capability_profile="${SINGULAR_AUDITOR_CAPABILITY_PROFILE:-audit-core}"
    singular_runner_contract_prepare \
      "$audit_runner" auditor "$audit_capability_profile" "$audit_result_file"
    local audit_bundle_for_try="$audit_context_bundle"
    if [[ "$audit_try" -gt 0 ]]; then
      audit_bundle_for_try="$run_dir/context-review-target-attempt-${n}-try-${audit_try}.bundle.json"
    fi
    local audit_context_receipt="$run_dir/context-invocation-review-target-attempt-${n}-try-${audit_try}.json"
    local -a audit_context_delivery_args=(--campaign-binding "$l1_campaign_binding")
    if [[ -f "$audit_context_config" ]]; then
      audit_context_delivery_args+=(
        --context-config "$audit_context_config"
        --context-workspace "$worktree"
        --context-role review-target --context-phase final-audit
        --context-task "$audit_context_task" --context-bundle "$audit_bundle_for_try"
        --context-invocation-id "$run_id:$task_id:review-target:attempt-$n:try-$audit_try"
        --receipt "$audit_context_receipt" --events-file "$SINGULAR_EVENTS_FILE"
      )
    fi
    rm -f "$audit_context_receipt"
    SINGULAR_RUNNER_ROLE=auditor \
    SINGULAR_RUNNER_CAPABILITY_PROFILE="$audit_capability_profile" \
    SINGULAR_RUNNER_RESULT_FILE="$audit_result_file" \
      python3 "$SCRIPT_DIR/evidence_delivery.py" run \
        --manifest "$run_dir/evidence-manifest.json" \
        --ledger "$SINGULAR_STATE_DIR/evidence-deliveries.sqlite3" \
        --required packet.json --required audit-verification.json \
        "${audit_context_delivery_args[@]}" -- \
        "$audit_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
        "${audit_run_args[@]}" >>"$auditor_log" 2>&1 &
    audit_pid="$!"
    audit_child_pgid="$(ps -o pgid= -p "$audit_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$audit_child_pgid" =~ ^[1-9][0-9]*$ ]] || audit_child_pgid="$l1_pgid"
    l1_status auditing active "Auditor is reviewing attempt $n" true \
      "Wait for the auditor verdict" "" "auditor" "$audit_pid" "$audit_child_pgid"
    if wait "$audit_pid"; then
      audit_rc=0
    else
      audit_rc=$?
    fi
    audit_context_status="$(singular_context_receipt_status "$audit_context_receipt" 2>/dev/null || true)"
    if [[ "$audit_context_status" == "denied" ]]; then
      audit_context_denial="$(singular_context_receipt_denial_reason "$audit_context_receipt" 2>/dev/null || true)"
      [[ "$audit_context_denial" != "campaign-mismatch" ]] \
        || l1_campaign_mismatch_exit "campaign policy changed before auditor admission"
      attempt_failure="configured-context"
      attempt_ctx="$audit_context_receipt"
      return 1
    fi
    l1_status auditing active "Classifying the auditor response for attempt $n" true \
      "Validate the audit verdict" "" "audit-controller"

    # Resume-refused/failure (86): fall back to FRESH within the SAME try (don't
    # consume an infra retry on a resume miss). Pure optimization miss.
    if [[ "$audit_rc" -eq 86 && -n "$reviewer_resume_id" && "$reviewer_resume_failed" == "no" ]]; then
      reviewer_resume_failed="yes"
      singular_append_event "context.resume_failed" "reviewer resume failed; re-running fresh" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"sessionId\":\"$reviewer_resume_id\"}" || true
      reviewer_strategy="fresh"; reviewer_strategy_reason="resume-failed"
      echo "  auditor resume failed; falling back to fresh run..."
      audit_result_file="$run_dir/auditor-attempt-${n}-try-${audit_try}-resume-fallback-runner-result.json"
      audit_context_receipt="$run_dir/context-invocation-review-target-attempt-${n}-try-${audit_try}-fallback.json"
      audit_rc=0
      rm -f "$audit_record"
      rm -f "$audit_context_receipt"
      printf -- '--- auditor resume-fallback (attempt %s) ---\n' "$n" >>"$auditor_log" || true
      singular_runner_contract_prepare \
        "$audit_runner" auditor "$audit_capability_profile" "$audit_result_file"
      audit_context_delivery_args=(--campaign-binding "$l1_campaign_binding")
      if [[ -f "$audit_context_config" ]]; then
        audit_context_delivery_args+=(
          --context-config "$audit_context_config"
          --context-workspace "$worktree"
          --context-role review-target --context-phase final-audit
          --context-task "$audit_context_task" --context-bundle "$audit_bundle_for_try"
          --context-invocation-id "$run_id:$task_id:review-target:attempt-$n:try-$audit_try:fallback"
          --receipt "$audit_context_receipt" --events-file "$SINGULAR_EVENTS_FILE"
        )
      fi
      SINGULAR_RUNNER_ROLE=auditor \
      SINGULAR_RUNNER_CAPABILITY_PROFILE="$audit_capability_profile" \
      SINGULAR_RUNNER_RESULT_FILE="$audit_result_file" \
        python3 "$SCRIPT_DIR/evidence_delivery.py" run \
          --manifest "$run_dir/evidence-manifest.json" \
          --ledger "$SINGULAR_STATE_DIR/evidence-deliveries.sqlite3" \
          --required packet.json --required audit-verification.json \
          "${audit_context_delivery_args[@]}" -- \
          "$audit_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
          --level readonly -C "$worktree" --run-id "$run_id" \
          --prompt-file "$active_audit_prompt" --output-last-message "$audit_record" \
          --session-meta "$session_meta_reviewer" >>"$auditor_log" 2>&1 &
      audit_pid="$!"
      audit_child_pgid="$(ps -o pgid= -p "$audit_pid" 2>/dev/null | tr -d '[:space:]' || true)"
      [[ "$audit_child_pgid" =~ ^[1-9][0-9]*$ ]] || audit_child_pgid="$l1_pgid"
      l1_status auditing active "Auditor is reviewing attempt $n" true \
        "Wait for the fresh auditor verdict" "" "auditor" "$audit_pid" "$audit_child_pgid"
      if wait "$audit_pid"; then
        audit_rc=0
      else
        audit_rc=$?
      fi
      audit_context_status="$(singular_context_receipt_status "$audit_context_receipt" 2>/dev/null || true)"
      if [[ "$audit_context_status" == "denied" ]]; then
        audit_context_denial="$(singular_context_receipt_denial_reason "$audit_context_receipt" 2>/dev/null || true)"
        [[ "$audit_context_denial" != "campaign-mismatch" ]] \
          || l1_campaign_mismatch_exit "campaign policy changed before auditor fallback admission"
        attempt_failure="configured-context"
        attempt_ctx="$audit_context_receipt"
        return 1
      fi
      l1_status auditing active "Classifying the auditor response for attempt $n" true \
        "Validate the audit verdict" "" "audit-controller"
    fi
    audit_fc="$(singular_planner_failure_class "$auditor_log" "$audit_rc" \
      "$audit_record" "$audit_result_file")"
    # Structured provider results take precedence. Neither provider-window class
    # is retried here; the cycle-level validated-provider-evidence path owns any
    # backoff. Without the provider-overloaded arm a 529 fell through to the
    # `! -f "$audit_record"` branch below and was mislabelled `no-record`.
    if [[ "$audit_fc" == "quota" || "$audit_fc" == "provider-overloaded" ]]; then
      infra_reason="$audit_fc"
      break
    elif [[ "$audit_fc" == "timeout" ]]; then
      infra_reason="timeout"
    elif [[ "$audit_fc" == "codex-exit" ]]; then
      infra_reason="provider-exit"
    elif [[ ! -f "$audit_record" ]]; then
      infra_reason="no-record"
    elif ! singular_extract_json "$audit_record" "$audit_record" 2>/dev/null; then
      # No parseable JSON verdict (prose-only, refusal, or truncated output). Keep
      # the existing l1.audit_unparseable signal firing per infra try.
      infra_reason="unparseable"
      singular_append_event "l1.audit_unparseable" "auditor produced no parseable JSON verdict" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
    else
      audit_schema="$(singular_json_field "$audit_record" schema 2>/dev/null || true)"
      audit_validation_rc=0
      validate_audit_record "$audit_record" 2>"$run_dir/audit-validate.err" \
        || audit_validation_rc=$?
      if [[ "$audit_schema" == "singular.orchestration.audit-verdict.v1" \
          && "$audit_validation_rc" -ne 0 ]]; then
        # v1 is captured as plain provider output because the public schema is
        # richer than provider strict-output subsets. Host validation is always
        # fail-closed before any v1 verdict can influence acceptance.
        infra_reason="invalid-verdict"
        audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
        audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.validate.err"
        cp "$audit_record" "$audit_repair_response_file"
        cp "$run_dir/audit-validate.err" "$audit_repair_error_file"
        cp "$audit_record" "$audit_record.invalid.json" 2>/dev/null || true
        singular_append_event "l1.audit_invalid_verdict" "auditor v1 verdict failed host schema validation" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"detail\":\"$(head -1 "$run_dir/audit-validate.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}"
      elif [[ -n "$audit_schema" \
          && "$audit_schema" != "singular.orchestration.audit-verdict.v1" \
          && "$audit_schema" != "singular.orchestration.audit-verdict.v0" \
          && "$audit_schema" != "pmgo.orchestration.audit-verdict.v0" ]]; then
        infra_reason="unsupported-verdict-schema"
        audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
        audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.validate.err"
        cp "$audit_record" "$audit_repair_response_file"
        printf 'unsupported audit verdict schema %q; expected %s\n' \
          "$audit_schema" "$audit_write_schema" >"$audit_repair_error_file"
      elif [[ -z "$audit_schema" && "$audit_write_contract" == "v1" ]]; then
        infra_reason="unsupported-verdict-schema"
        audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
        audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.validate.err"
        cp "$audit_record" "$audit_repair_response_file"
        printf 'audit verdict schema is missing; expected %s\n' \
          "$audit_write_schema" >"$audit_repair_error_file"
      elif [[ "${SINGULAR_AUDIT_VERDICT_VALIDATE:-warn}" == "strict" \
          && "$audit_validation_rc" -ne 0 ]]; then
        infra_reason="invalid-verdict"
        audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
        audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.validate.err"
        cp "$audit_record" "$audit_repair_response_file"
        cp "$run_dir/audit-validate.err" "$audit_repair_error_file"
        cp "$audit_record" "$audit_record.invalid.json" 2>/dev/null || true
        singular_append_event "l1.audit_invalid_verdict" "legacy auditor verdict failed schema validation" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"detail\":\"$(head -1 "$run_dir/audit-validate.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}"
      elif [[ "$audit_schema" == "singular.orchestration.audit-verdict.v1" ]]; then
        # Schema validity is not enough: the model must reproduce the
        # host-owned verification aggregate exactly. A model cannot upgrade
        # hash-verified evidence-only validation into a real rerun pass.
        if model_verification_status="$(
          python3 "$SCRIPT_DIR/audit-verdict-host-bind.py" \
            --host-report "$run_dir/audit-verification.json" \
            --verdict "$audit_record" 2>"$run_dir/audit-verification-bind.err"
        )"; then
          audit_parsed="yes"
          break
        else
          # Host authority (0.21.0). The classification is a host fact the
          # model was asked to echo. When the echo is wrong, rewrite the
          # verdict's verificationResults to the host value and keep the
          # model's product judgment, instead of paying for a second auditor
          # pass whose only job would be to type the host's own value back.
          # The pre-normalization verdict is kept beside it.
          # SINGULAR_AUDIT_VERIFY_NORMALIZE=0 restores the repair retry.
          if [[ "${SINGULAR_AUDIT_VERIFY_NORMALIZE:-1}" != "0" ]] \
            && model_verification_status="$(
              python3 "$SCRIPT_DIR/audit-verdict-host-bind.py" \
                --host-report "$run_dir/audit-verification.json" \
                --verdict "$audit_record" --normalize \
                --command "$gate_cmd" \
                --evidence-ref "runs/$run_id/audit-verification.json" \
                2>"$run_dir/audit-verification-normalize.err"
            )"; then
            singular_append_event "l1.audit_verification_normalized" \
              "auditor verification classification rewritten to the host classification" \
              "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"hostVerification\":\"$host_verification_status\",\"detail\":\"$(head -1 "$run_dir/audit-verification-bind.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}" \
              || true
            audit_parsed="yes"
            break
          fi
          model_verification_status=""
          infra_reason="verification-classification-mismatch"
          audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
          audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.bind.err"
          cp "$audit_record" "$audit_repair_response_file"
          cp "$run_dir/audit-verification-bind.err" "$audit_repair_error_file"
          cp "$audit_record" "$audit_record.invalid.json" 2>/dev/null || true
          singular_append_event "l1.audit_verification_mismatch" \
            "auditor verification classification did not match the host report" \
            "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"hostVerification\":\"$host_verification_status\",\"detail\":\"$(head -1 "$run_dir/audit-verification-bind.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}" \
            || true
        fi
      else
        if [[ "${SINGULAR_AUDIT_VERDICT_VALIDATE:-warn}" == "warn" \
            && "$audit_validation_rc" -ne 0 ]]; then
        singular_append_event "l1.audit_verdict_warned" "auditor verdict failed schema validation (warn mode; proceeding)" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"detail\":\"$(head -1 "$run_dir/audit-validate.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}" || true
        fi
        audit_parsed="yes"
        break
      fi
    fi
  done
  if [[ "$audit_parsed" == "yes" ]]; then
    # The model verdict is already schema- and host-validated. Stamp the
    # engine-owned campaign provenance before it can influence acceptance;
    # this uses the existing string evidence contract and adds no review pass.
    if ! python3 - "$audit_record" "$l1_campaign_binding" "$head_sha" <<'PY'
import json
import os
import sys

path, binding, head_sha = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    audit = json.load(handle)
reviewed = [
    str(item) for item in audit.get("evidenceReviewed", [])
    if not str(item).startswith(("campaign-binding:", "reviewed-head-sha:"))
]
reviewed.extend(("campaign-binding:" + binding, "reviewed-head-sha:" + head_sha))
audit["evidenceReviewed"] = reviewed
temporary = path + ".campaign-binding.tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(audit, handle, indent=2)
    handle.write("\n")
os.replace(temporary, path)
PY
    then
      attempt_failure="audit-infra"
      attempt_ctx="$audit_record"
      return 1
    fi
    local review_record_file="$run_dir/review-policy-attempt-${n}.json"
    local review_record_err="$run_dir/review-policy-attempt-${n}.err"
    local reviewer_model="" reviewer_effort=""
    if [[ -f "$session_meta_reviewer" ]]; then
      reviewer_model="$(singular_json_field "$session_meta_reviewer" model 2>/dev/null || true)"
      reviewer_effort="$(singular_json_field "$session_meta_reviewer" effort 2>/dev/null || true)"
    fi
    if ! python3 "$SCRIPT_DIR/review_policy.py" record \
      --logical-change "$review_logical_change" \
      --task "$task_id" \
      --run "$run_id" \
      --attempt "$n" \
      --verdict "$audit_record" \
      --head "$head_sha" \
      --campaign "$l1_campaign_binding" \
      --lane native \
      --reviewer-runner "$(basename "$audit_runner")" \
      --reviewer-model "$reviewer_model" \
      --reviewer-effort "$reviewer_effort" \
      --apply >"$review_record_file" 2>"$review_record_err"
    then
      attempt_failure="audit-infra"
      attempt_ctx="$review_record_err"
      return 1
    fi
    singular_append_event "review.policy_applied" \
      "review policy recorded a completed verdict round" \
      "$(python3 - "$review_record_file" "$task_id" "$run_id" "$n" "$review_logical_change" <<'PY'
import json, sys
path, task_id, run_id, attempt, logical = sys.argv[1:6]
try:
    rec = json.load(open(path, encoding="utf-8"))
except Exception:
    rec = {}
def arr(key):
    v = rec.get(key) or []
    return v if isinstance(v, list) else []
print(json.dumps({
    "taskId": task_id,
    "runId": run_id,
    "attempt": int(attempt),
    "logicalChange": logical,
    "round": rec.get("round") or 0,
    "originalVerdict": rec.get("originalVerdict") or "",
    "effectiveVerdict": rec.get("effectiveVerdict") or "",
    "blocking": arr("blocking"),
    "backlog": arr("backlog"),
    "downgraded": arr("downgraded"),
    "unclassifiedCount": int(rec.get("unclassifiedCount") or 0),
}, separators=(",", ":")))
PY
)" || true
    {
      verdict="$(singular_json_field "$audit_record" verdict 2>/dev/null || echo unknown)"
      # Findings ledger + reviewer capsule on every parseable verdict (additive
      # observability; never aborts the drive). prior_head is the previous
      # attempt's auditedHeadSha when a reviewer capsule already exists.
      local ledger_out ledger_event
      ledger_out="$(singular_findings_ledger_update "$run_dir" "$n" "$audit_record" 2>/dev/null)" \
        || { ledger_out=""; singular_append_event "l1.findings_ledger_failed" "findings ledger update failed (non-fatal)" \
               "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true; }
      if [[ -n "$ledger_out" ]]; then
        ledger_event="$(python3 -c 'import json,sys
parts = dict(kv.split("=", 1) for kv in sys.argv[3].split() if "=" in kv)
print(json.dumps({"taskId": sys.argv[1], "runId": sys.argv[2], "attempt": int(sys.argv[4]),
                  "open": int(parts.get("open", 0)), "resolved": int(parts.get("resolved", 0)),
                  "new": int(parts.get("new", 0))}, separators=(",", ":")))' \
          "$task_id" "$run_id" "$ledger_out" "$n" 2>/dev/null || true)"
        [[ -n "$ledger_event" ]] && { singular_append_event "findings.ledger_updated" "findings ledger updated" "$ledger_event" || true; }
      fi
      # prior_head was captured at the top of run_audit_phase (before this
      # attempt overwrites the reviewer capsule); reuse it for the diffRange.
      singular_capsule_write_reviewer "$run_dir" "$n" "$audit_record" "$prior_head" "$head_sha" >/dev/null 2>&1 \
        || singular_append_event "l1.capsule_write_failed" "reviewer capsule write failed (non-fatal)" \
             "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n}" || true
      # Session affinity (T-E5): merge host-authority fields into the reviewer meta
      # so a later audit try (this run) can resume it. headShaAtCreate = head_sha
      # (the audited head). Never fatal.
      singular_session_meta_finalize "$session_meta_reviewer" reviewer "$task_id" "$run_id" \
        "$audit_runner_basename" "$reviewer_prompt_sha" "$head_sha" "$n" >/dev/null 2>&1 || true
      # Assumption ledger attempt-close (node assumption-ledger; behind
      # SINGULAR_CTX_PACKET): fold the auditor findings (which cite assumption ids) into
      # this attempt's input ledger via the integrated host-derived transition and
      # persist the updated ledger to the run_dir sidecar, so the NEXT attempt's
      # assemble carries sticky `violated` statuses. No-op when OFF; never fatal.
      assumptions_attempt_close "$audit_record" || true
    }
  else
    # Auditor infra failure persisted across SINGULAR_AUDIT_INFRA_MAX fresh re-runs:
    # a model decider cannot fix broken/empty auditor output. Surface as
    # audit-infra so the (fast-path) decider parks it; retryCount stays untouched.
    singular_append_event "l1.audit_completed" "auditor completed (infra failure)" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"infra\"}"
    singular_append_event "audit.infra_exhausted" \
      "auditor infrastructure retry budget exhausted" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"budgetDomain\":\"auditor-infrastructure\",\"retriesUsed\":$audit_infra_max,\"maxExtraRetries\":$audit_infra_max,\"consumesProductRepairBudget\":false}" \
      || true
    attempt_failure="audit-infra"; attempt_ctx="$run_dir/worker-codex.log"
    [[ -f "$audit_record" ]] && attempt_ctx="$audit_record"
    return 1
  fi
  echo "  auditor verdict=$verdict"
  singular_append_event "l1.audit_completed" "auditor completed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"$verdict\",\"verification\":\"${model_verification_status:-legacy}\"}"
  append_audit_evidence
  # Persist the final provider usage and every per-try runner sidecar after the
  # auditor invocation. The pre-audit manifest remains the bounded prompt input;
  # this refresh is the durable post-run accounting record.
  local manifest_rc=0
  l1_build_evidence_manifest \
    "post-verdict-finalization" "$run_dir/evidence-manifest-final-refresh.log" || manifest_rc=$?
  if [[ "$manifest_rc" -ne 0 ]]; then
    # audit.json already contains a parseable verdict for this exact head.  An
    # evidence writer failure may delay publication, but it cannot erase an
    # accepted product audit or send the implementation through a repair cycle.
    if [[ "$require_audit" == "1" && "$verdict" == "accepted" ]]; then
      accepted_audit_pending_evidence="yes"
      [[ "$manifest_rc" -eq 2 ]] \
        && attempt_failure="evidence-invalid-after-accept" \
        || attempt_failure="evidence-infra-after-accept"
      singular_append_event "l1.audit_accepted_awaiting_evidence" \
        "accepted product audit preserved; evidence finalization is blocked externally" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$head_sha\",\"stage\":\"final-manifest-refresh\",\"auditVerdict\":\"accepted\",\"consumesProductRepairBudget\":false}" \
        || true
    else
      attempt_failure="audit-infra"
    fi
    attempt_ctx="$run_dir/evidence-manifest-final-refresh.log"
    return 1
  fi

  if [[ "${model_verification_status:-}" == "failed-product" ]]; then
    attempt_failure="audit-needs-fix"; attempt_ctx="$audit_record"; return 1
  fi
  if [[ "${model_verification_status:-}" == "inconclusive-infrastructure" ]]; then
    if [[ "$require_audit" == "1" && "$verdict" == "accepted" ]]; then
      accepted_audit_pending_evidence="yes"
      attempt_failure="evidence-infra-after-accept"
      attempt_ctx="$audit_record"
      singular_append_event "l1.audit_accepted_awaiting_evidence" \
        "accepted product audit preserved; host verification is inconclusive infrastructure" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$head_sha\",\"stage\":\"host-verification\",\"auditVerdict\":\"accepted\",\"consumesProductRepairBudget\":false}" \
        || true
      return 1
    fi
    attempt_failure="audit-infra"; attempt_ctx="$audit_record"; return 1
  fi

  if [[ "$require_audit" == "1" && "$verdict" != "accepted" ]]; then
    attempt_failure="audit-$verdict"; attempt_ctx="$audit_record"; return 1
  fi
  return 0
}

# Archive one attempt's artifacts (T-E1): wraps singular_attempt_archive with the
# driver's globals; a failure here NEVER aborts the drive.
# args: n failure_class decider_action authority
archive_attempt() {
  SINGULAR_ATTEMPT_TASK_ID="$task_id" SINGULAR_ATTEMPT_STARTED_AT="$attempt_started_at" \
    SINGULAR_ATTEMPT_WORKER_STRATEGY="${worker_strategy:-}" \
    SINGULAR_ATTEMPT_REVIEWER_STRATEGY="${reviewer_strategy:-}" \
    singular_attempt_archive "$run_dir" "$1" "$2" "$verdict" "$head_sha" "$3" "$4" >/dev/null 2>&1 \
    || { singular_append_event "l1.attempt_archive_failed" "attempt archive failed (non-fatal)" \
           "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"n\":$1}" 2>/dev/null || true; }
}

# ---- Assumption ledger wire-in (node assumption-ledger; behind SINGULAR_CTX_PACKET) --
# Terminal driver wire-in for the S4-context-packets assumption-ledger node. Every
# site below is a no-op unless SINGULAR_CTX_PACKET is set to a non-zero value (default
# 0), so with the flag unset/0 l1-drive.sh renders byte-identical prompts, writes no
# ledger sidecar / section files, and emits no assumptions events. Each site delegates
# into the integrated PURE bricks (singular_ctx_assumptions_assemble at attempt-open,
# singular_ctx_assumptions_transition at attempt-close) and adds no rendering of its
# own. Fail-closed: on any error the attempt proceeds WITHOUT injection (non-fatal),
# preserving the run. These sites are additive and disjoint from the post-acceptance
# paired-audit (TASK-0006) and critic-recheck (TASK-0033) hooks, so this node's
# l1-drive.sh ownership does not collide with theirs.
assumptions_ctx_enabled() { [[ -n "${SINGULAR_CTX_PACKET:-}" && "${SINGULAR_CTX_PACKET}" != "0" ]]; }
assumptions_ledger_sidecar="$run_dir/assumptions-ledger.json"
assumptions_fix_section_file="$run_dir/assumptions-fix-section.md"
assumptions_audit_section_file="$run_dir/assumptions-audit-section.md"
assumptions_attempt_ledger_file="$run_dir/assumptions-attempt-ledger.json"

# Attempt-open: assemble the per-run ledger as carry(prior, seed(task)) from the task
# packet and the per-run prior sidecar (empty on attempt 1) and stage this attempt's
# fixSection/auditSection + input-ledger snapshot to run_dir files. Non-fatal; on any
# error nothing is staged (fail-closed) and the attempt proceeds without injection.
assumptions_attempt_open() {
  assumptions_ctx_enabled || return 0
  rm -f "$assumptions_fix_section_file" "$assumptions_audit_section_file" \
    "$assumptions_attempt_ledger_file" 2>/dev/null || true
  local prior='' envelope
  [[ -f "$assumptions_ledger_sidecar" ]] && prior="$(cat "$assumptions_ledger_sidecar" 2>/dev/null || true)"
  envelope="$(singular_ctx_assumptions_assemble "$task_file" "$prior" 2>/dev/null)" || return 0
  [[ -n "$envelope" ]] || return 0
  python3 - "$envelope" "$assumptions_fix_section_file" "$assumptions_audit_section_file" \
    "$assumptions_attempt_ledger_file" <<'PY' 2>/dev/null || return 0
import json, sys
env = json.loads(sys.argv[1])
fix = env.get("fixSection") or ""
aud = env.get("auditSection") or ""
led = env.get("ledger") or {}
if fix:
    open(sys.argv[2], "w", encoding="utf-8").write(fix)
if aud:
    open(sys.argv[3], "w", encoding="utf-8").write(aud)
open(sys.argv[4], "w", encoding="utf-8").write(json.dumps(led, sort_keys=True))
PY
  return 0
}

# Inject the staged fixSection into the implementer's already-rendered active/fix
# prompt (the file the worker runner reads). Called AFTER prepare_worker_prompt so it
# applies uniformly across the attempt-1 copy and the retry fix-prompt render. No-op
# when OFF or when the section is empty (a zero-assumption task).
assumptions_inject_fix() {
  assumptions_ctx_enabled || return 0
  [[ -s "$assumptions_fix_section_file" ]] || return 0
  { echo ""; echo "---"; echo ""; cat "$assumptions_fix_section_file"; } \
    >> "$run_dir/l2-active-prompt.md" 2>/dev/null || true
  return 0
}

# Inject the staged auditSection into the per-attempt auditor prompt (the file the
# auditor runner reads), around the re-audit render site and before the runner reads
# it. No-op when OFF or when the section is empty.
assumptions_inject_audit() {
  local active_audit_prompt="$1"
  assumptions_ctx_enabled || return 0
  [[ -s "$assumptions_audit_section_file" ]] || return 0
  { echo ""; echo "---"; echo ""; cat "$assumptions_audit_section_file"; } \
    >> "$active_audit_prompt" 2>/dev/null || true
  return 0
}

# Record the per-attempt ledger (assumption statuses) alongside the implementer
# capsule write — additive and non-fatal: a failure logs an event and never aborts
# the attempt. No-op when OFF.
assumptions_record_capsule() {
  local n="$1"
  assumptions_ctx_enabled || return 0
  [[ -f "$assumptions_attempt_ledger_file" ]] || return 0
  cp "$assumptions_attempt_ledger_file" "$run_dir/assumptions-attempt-$n.json" 2>/dev/null \
    || singular_append_event "l1.assumptions_record_failed" "per-attempt assumption ledger record failed (non-fatal)" \
         "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
  return 0
}

# Attempt-close: after a parseable auditor verdict, fold the auditor findings (which
# the injected auditSection instructs the auditor to cite by assumption id) into this
# attempt's input ledger via the integrated host-derived transition, then persist the
# updated ledger to the run_dir sidecar so the NEXT attempt's assemble carries sticky
# `violated` statuses. Non-fatal; fail-closed leaves the prior sidecar untouched.
assumptions_attempt_close() {
  local audit_record="$1"
  assumptions_ctx_enabled || return 0
  [[ -f "$assumptions_attempt_ledger_file" && -f "$audit_record" ]] || return 0
  local ledger findings updated
  ledger="$(cat "$assumptions_attempt_ledger_file" 2>/dev/null || true)"
  [[ -n "$ledger" ]] || return 0
  findings="$(python3 - "$audit_record" 2>/dev/null <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception:
    r = {}
f = r.get("findings") if isinstance(r, dict) else None
sys.stdout.write(json.dumps(f if isinstance(f, list) else []))
PY
)" || return 0
  updated="$(singular_ctx_assumptions_transition "$ledger" "$findings" 2>/dev/null)" || return 0
  [[ -n "$updated" ]] || return 0
  printf '%s\n' "$updated" > "$assumptions_ledger_sidecar.tmp" 2>/dev/null \
    && mv "$assumptions_ledger_sidecar.tmp" "$assumptions_ledger_sidecar" 2>/dev/null || true
  return 0
}

# Exact candidate fingerprint at an attempt boundary.  It includes committed
# head, tracked diff bytes, and untracked file content, so a byte-identical
# candidate cannot spend another implement/audit cycle merely by being
# described differently.
l1_candidate_signature() {
  local candidate_worktree="$1" path
  {
    # Index entries bind tracked modes + blob content.  Deliberately exclude
    # commit identity: an empty/no-op commit is ceremony, not product progress.
    git -C "$candidate_worktree" ls-files -s 2>/dev/null || true
    git -C "$candidate_worktree" diff --binary HEAD 2>/dev/null || true
    while IFS= read -r -d '' path; do
      printf 'untracked:%s:' "$path"
      shasum -a 256 "$candidate_worktree/$path" 2>/dev/null || true
    done < <(git -C "$candidate_worktree" ls-files --others --exclude-standard -z 2>/dev/null || true)
  } | shasum -a 256 | awk '{print $1}'
}

# Canonical audit-feedback identity shared by first-feedback eligibility and
# repeated-feedback detection.  The worker ledger consumes strings from both
# arrays with this item equivalence, so array placement, ordering, duplicates,
# whitespace, case and backticks cannot manufacture a new repair opportunity.
l1_normalized_findings_signature() {
  local record="$1"
  [[ -f "$record" ]] || return 0
  python3 - "$record" <<'PY' 2>/dev/null || true
import hashlib
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(0)
normalized = set()
for field in ("findings", "requiredFixes"):
    values = data.get(field)
    if not isinstance(values, list):
        continue
    for value in values:
        if not isinstance(value, str):
            continue
        item = " ".join(value.replace("`", "").lower().split())
        if item:
            normalized.add(item)
if not normalized:
    raise SystemExit(0)
canonical = json.dumps(sorted(normalized), separators=(",", ":"),
                       ensure_ascii=False)
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
PY
}

# ---- Decider-driven retry loop ----
# prev_failure_class/prev_attempt_ctx carry the PRIOR attempt's failure into the
# next prepare_worker_prompt (the per-iteration reset clears attempt_failure
# before the structured fix prompt is rendered); they mirror fix_hints.
accepted="no"; waiver="no"; fix_hints=""; prev_failure_class=""; prev_attempt_ctx=""; terminal_action=""
prev_progress_signature=""
prev_findings_signature=""
terminal_authority="decider"
terminal_rationale=""
attempt_started_at=""

# A started lease means a prior process already crossed the product-work
# boundary.  Its first pass in this process is therefore a repair, not another
# free initial pass.  Consume that repair durably before invoking the worker so
# repeated crashes cannot keep re-entering on the same retryCount.  The
# precomputed product_passes_remaining intentionally includes this first
# re-entry repair; later in-process repairs continue to use the ordinary bump
# below.  A crash after this write may conservatively consume the repair.
if [[ "$prior_product_lease" == "yes" && "${#authorized_continuation[@]}" -ne 10 ]]; then
  if ! l1_campaign_publication_begin \
      "$l1_campaign_binding" pre-reentry-budget-mutation; then
    l1_campaign_mismatch_exit \
      "campaign identity changed before re-entry budget accounting"
  fi
  reentry_retry_count=""
  if ! reentry_retry_count="$(singular_lease_bump_retry "$task_id" 2>/dev/null)" \
      || [[ ! "$reentry_retry_count" =~ ^[0-9]+$ ]] \
      || [[ "$reentry_retry_count" -ne $((product_repairs_used + 1)) ]] \
      || [[ "$reentry_retry_count" -gt "$max_retries" ]]; then
    reentry_observed_json="null"
    [[ "$reentry_retry_count" =~ ^[0-9]+$ ]] \
      && reentry_observed_json="$reentry_retry_count"
    _l1_outcome="terminal"
    singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true
    singular_task_set_status "$task_file" "blocked" 2>/dev/null || true
    l1_status terminal failed "Re-entry repair could not be durably authorized" true \
      "Inspect the lease; refuse product work until budget state is repaired" \
      "repair-budget-record-failed"
    singular_append_event "l1.product_repair_budget_record_failed" \
      "re-entry suppressed because durable repair accounting failed" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"riskTier\":\"$risk_tier\",\"riskSource\":\"$risk_source\",\"budgetDomain\":\"product-repair\",\"usedBefore\":$product_repairs_used,\"observedAfter\":$reentry_observed_json,\"max\":$max_retries,\"priorLease\":true}" \
      || true
    "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
      --rationale "durable product repair accounting failed before crash re-entry; refusing an unaccounted pass" \
      --run "$run_id" --branch "$worker_branch" --authority l1 >/dev/null 2>&1 || true
    echo "NOT ACCEPTED (escalate-parked): $task_id — re-entry repair could not be durably authorized." >&2
    exit 3
  fi
  product_repairs_used="$reentry_retry_count"
  singular_append_event "l1.product_repair_budget_consumed" \
    "crash re-entry repair authorized before product work" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"riskTier\":\"$risk_tier\",\"riskSource\":\"$risk_source\",\"failureClass\":\"interrupted-product-pass\",\"action\":\"reentry-repair\",\"budgetDomain\":\"product-repair\",\"used\":$product_repairs_used,\"max\":$max_retries,\"priorLease\":true,\"consumedBeforeWorker\":true}" \
    || true
  l1_campaign_publication_end
fi

for ((attempt=0; attempt<product_passes_remaining; attempt++)); do
  if ! l1_campaign_publication_begin \
      "$l1_campaign_binding" pre-product-pass-marker; then
    l1_campaign_mismatch_exit \
      "campaign identity changed before another product pass"
  fi
  if [[ "${#authorized_continuation[@]}" -ne 10 ]]; then
    if ! singular_lease_mark_product_pass_started "$task_id" "$run_id"; then
      singular_append_event "l1.product_pass_marker_failed" \
        "refusing to run product work without durable pass accounting" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$((attempt + 1))}" || true
      echo "cannot durably mark product pass started for $task_id; refusing unaccounted execution" >&2
      exit 1
    fi
    if ! l1_record_attempt started; then
      singular_append_event "l1.attempt_lifecycle_record_failed" \
        "refusing to run product work without owner-bound attempt disposition" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$((attempt + 1))}" || true
      echo "cannot durably bind product attempt to its dispatch reservation" >&2
      exit 1
    fi
  fi
  l1_campaign_publication_end
  [[ "$attempt" -gt 0 ]] && echo "  retry attempt $attempt/$max_retries (last: $attempt_failure)"
  n=$((attempt + 1))
  attempt_started_at="$(singular_timestamp)"
  attempt_failure=""; attempt_ctx=""
  accepted_audit_pending_evidence="no"
  verdict="unknown"; head_sha=""
  attempt_ok="no"
  attempt_start_candidate_signature="$(l1_candidate_signature "$worktree" 2>/dev/null || true)"
  # Assumption ledger (node assumption-ledger; behind SINGULAR_CTX_PACKET): assemble
  # this attempt's ledger from the task packet + per-run prior sidecar BEFORE the
  # prompt is rendered, then inject the assembled fixSection into the already-rendered
  # active/fix prompt. Both no-op when OFF (byte-identical) and never abort the drive.
  assumptions_attempt_open "$n" || true
  prepare_worker_prompt "$n"
  assumptions_inject_fix || true
  if run_worker_phase "$n"; then
    if run_audit_phase "$n"; then attempt_ok="yes"; fi
  fi
  if [[ "${#authorized_continuation[@]}" -eq 10 \
      && "$continuation_invocation_started" == "no" ]]; then
    _l1_outcome="terminal"
    if [[ "$continuation_preparation_failures" -ge 1 ]]; then
      singular_task_set_status "$task_file" "blocked" 2>/dev/null || true
    fi
    l1_status terminal failed "Continuation preparation failed before worker invocation" true \
      "Repair the recorded preparation condition, then reserve the exact continuation again" \
      "continuation-preparation-failed"
    singular_append_event "l1.continuation_preparation_failed" \
      "one-shot continuation remains unspent because provider invocation did not start" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"authorizationId\":\"${authorized_continuation[0]}\",\"failureClass\":\"$attempt_failure\"}" || true
    echo "continuation preparation failed before worker invocation; authority remains unspent" >&2
    exit 3
  fi
  if [[ "$attempt_ok" == "yes" ]]; then
    accepted="yes"
    archive_attempt "$n" "" "accept" "l1"
    break
  fi

  singular_campaign_binding_matches \
    "$l1_campaign_binding" l1-drive post-attempt \
    || l1_campaign_mismatch_exit \
      "campaign identity changed while product work or review was running"

  # Product review has completed and accepted this immutable head.  Evidence
  # infrastructure is a publication blocker, not a product-repair signal, so
  # bypass both the no-progress/decider path and the lease retry counter.
  if [[ "$accepted_audit_pending_evidence" == "yes" ]]; then
    if ! l1_campaign_publication_begin \
        "$l1_campaign_binding" pre-awaiting-evidence-state; then
      l1_campaign_mismatch_exit \
        "campaign identity changed after product audit acceptance"
    fi
    terminal_action="awaiting-evidence"
    terminal_authority="l1"
    terminal_rationale="product audit accepted exact head $head_sha; publication is blocked-external while evidence finalization is repaired. The accepted verdict is preserved and no product repair budget was consumed."
    if ! mark_product_audit_awaiting_evidence \
      "${attempt_failure:-evidence-finalization}" "${attempt_ctx:-}"; then
      singular_append_event "l1.awaiting_evidence_marker_failed" \
        "accepted audit remains authoritative but the blocked packet marker could not be written" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$head_sha\",\"auditVerdict\":\"accepted\"}" \
        || true
    fi
    archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
    break
  fi

  # Review-round exhaustion is a policy terminal. It must not consume product
  # repair budget and must not call the decider.
  if [[ "$attempt_failure" == "review-rounds-exhausted" ]]; then
    terminal_action="escalate-parked"
    terminal_authority="policy"
    review_used="$(singular_json_field "${attempt_ctx:-/dev/null}" used 2>/dev/null || echo "?")"
    review_allowed="$(singular_json_field "${attempt_ctx:-/dev/null}" allowedRounds 2>/dev/null || echo "?")"
    terminal_rationale="review rounds exhausted for $review_logical_change ($review_used/$review_allowed); unresolved blockers remain blocked; choose reduce-scope, revert, defer or a recorded review-policy exception"
    archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
    break
  fi

  # Product retries normally require a changed candidate. A first validated
  # needs-fix audit with normalized findings is different: those fresh findings
  # change the next worker's input even when the audited candidate was already
  # committed before this invocation and this worker correctly made no edit.
  # Only that first actionable review gets through this guard; empty feedback
  # remains a no-output/no-change failure, and an exact candidate plus repeated
  # normalized findings is parked below before another repair can be charged.
  attempt_end_candidate_signature="$(l1_candidate_signature "$worktree" 2>/dev/null || true)"
  candidate_unchanged="no"
  if [[ -n "$attempt_start_candidate_signature" \
      && "$attempt_start_candidate_signature" == "$attempt_end_candidate_signature" ]]; then
    candidate_unchanged="yes"
  fi
  current_findings_signature="$(l1_normalized_findings_signature "${attempt_ctx:-/dev/null}")"
  first_actionable_audit_feedback="no"
  if [[ "$attempt_failure" == audit-needs-fix* \
      && -n "$current_findings_signature" \
      && -z "$prev_findings_signature" ]]; then
    first_actionable_audit_feedback="yes"
  fi
  case "$attempt_failure" in
    gate-red|worker-no-packet|packet-invalid|no-changes|commit-failed|scope-violation)
      if [[ "$candidate_unchanged" == "yes" ]]; then
        terminal_action="escalate-parked"
        terminal_authority="l1"
        terminal_rationale="no product progress: attempt $n left the exact candidate unchanged after $attempt_failure; another implement/audit pass would evaluate identical source."
        singular_append_event "l1.unchanged_candidate_parked" \
          "task parked before another expensive pass because candidate content was unchanged" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"failureClass\":\"$attempt_failure\",\"candidateSignature\":\"$attempt_end_candidate_signature\",\"productRepairsUsed\":$product_repairs_used,\"productRepairMax\":$max_retries}" \
          || true
        archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
        break
      fi
      ;;
    audit-needs-fix|audit-needs-fix*)
      if [[ "$candidate_unchanged" == "yes" ]]; then
        if [[ "$first_actionable_audit_feedback" == "yes" ]]; then
          singular_append_event "l1.actionable_audit_correction_eligible" \
            "fresh validated audit findings made one bounded correction eligible" \
            "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"failureClass\":\"$attempt_failure\",\"candidateSignature\":\"$attempt_end_candidate_signature\",\"findingsSignature\":\"$current_findings_signature\",\"productRepairsUsed\":$product_repairs_used,\"productRepairMax\":$max_retries}" \
            || true
        elif [[ -n "$current_findings_signature" \
            && "$current_findings_signature" == "$prev_findings_signature" ]]; then
          : # The exact-candidate + repeated-findings guard below owns this terminal.
        else
          terminal_action="escalate-parked"
          terminal_authority="l1"
          terminal_rationale="no actionable review progress: attempt $n left the exact candidate unchanged after $attempt_failure without first-time normalized findings."
          singular_append_event "l1.unchanged_candidate_parked" \
            "task parked before another expensive pass because candidate content was unchanged" \
            "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"failureClass\":\"$attempt_failure\",\"candidateSignature\":\"$attempt_end_candidate_signature\",\"productRepairsUsed\":$product_repairs_used,\"productRepairMax\":$max_retries}" \
            || true
          archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
          break
        fi
      fi
      ;;
  esac

  if [[ -n "$current_findings_signature" \
      && "$current_findings_signature" == "$prev_findings_signature" ]]; then
    terminal_action="escalate-parked"
    terminal_authority="l1"
    if [[ "$candidate_unchanged" == "yes" ]]; then
      terminal_rationale="no review progress: attempt $n left the exact candidate unchanged and reproduced the same normalized product findings as attempt $((n - 1)); another implement/audit pass is suppressed."
    else
      terminal_rationale="no review progress: attempt $n reproduced the same normalized product findings as attempt $((n - 1)); another implement/audit pass is suppressed."
    fi
    singular_append_event "l1.identical_findings_parked" \
      "task parked before another expensive pass because normalized findings repeated" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"failureClass\":\"$attempt_failure\",\"candidateSignature\":\"$attempt_end_candidate_signature\",\"candidateUnchanged\":$([[ "$candidate_unchanged" == yes ]] && printf true || printf false),\"findingsSignature\":\"$current_findings_signature\",\"productRepairsUsed\":$product_repairs_used,\"productRepairMax\":$max_retries}" \
      || true
    archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
    break
  fi
  [[ -n "$current_findings_signature" ]] && prev_findings_signature="$current_findings_signature"

  blocker_rationale="$(singular_terminal_blocker_rationale "$attempt_failure" "${attempt_ctx:-/dev/null}" 2>/dev/null || true)"
  if [[ -n "$blocker_rationale" ]]; then
    terminal_action="escalate-parked"
    terminal_authority="l1"
    terminal_rationale="$blocker_rationale"
    echo "  $attempt_failure: parking (project blocker)"
    archive_attempt "$n" "$attempt_failure" "escalate-parked" "l1"
    break
  fi

  # No-progress guard. An attempt that produced the same code and the same
  # failure as the one before it will produce them again; there is nothing for a
  # retry to act on. Checked BEFORE the decider so a provably pointless cycle
  # does not also pay for a decider round-trip.
  #
  # Parked with a reason of its own, not as a product failure, because the two
  # call for opposite responses: a product failure wants another attempt, this
  # wants a human or a changed environment. `singular unpark` is how it comes
  # back once something outside the loop is different.
  progress_signature="$(singular_attempt_progress_signature \
    "$worktree" "$attempt_failure" "$head_sha" "$run_dir/gate-report.json" 2>/dev/null || true)"
  if [[ -n "$progress_signature" && "$progress_signature" == "$prev_progress_signature" ]]; then
    terminal_action="escalate-parked"
    terminal_authority="l1"
    terminal_rationale="no progress: attempt $n reproduced attempt $((n - 1)) exactly — same head ($([[ -n "$head_sha" ]] && echo "${head_sha:0:12}" || echo "no commit")), same uncommitted changes, same $attempt_failure failure. A further retry cannot differ; unpark once the environment or the task changes."
    echo "  $attempt_failure: parking (no progress since the previous attempt)"
    singular_append_event "l1.no_progress_parked" \
      "task parked because an attempt reproduced the previous one exactly" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"failureClass\":\"$attempt_failure\",\"headSha\":\"$head_sha\"}" || true
    archive_attempt "$n" "$attempt_failure" "escalate-parked" "l1"
    break
  fi
  prev_progress_signature="$progress_signature"

  case "$attempt_failure" in
    gate-red|worker-no-packet|packet-invalid|no-changes|commit-failed|scope-violation|audit-needs-fix|audit-needs-fix*)
      if [[ "$product_repairs_used" -ge "$max_retries" ]]; then
        terminal_action="escalate-parked"
        terminal_authority="policy"
        terminal_rationale="product repair budget exhausted for $risk_tier-risk task after $product_repairs_used of $max_retries allowed repairs; audit and merged-tree gate authority remain unchanged."
        singular_append_event "l1.product_repair_budget_exhausted" \
          "bounded product repair budget exhausted before another decision round" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"riskTier\":\"$risk_tier\",\"riskSource\":\"$risk_source\",\"failureClass\":\"$attempt_failure\",\"budgetDomain\":\"product-repair\",\"used\":$product_repairs_used,\"max\":$max_retries}" \
          || true
        archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
        break
      fi
      ;;
  esac

  # Failure -> decider. Try the policy fast-path first (T-F1): for clear-cut
  # classes with retry budget it resolves the action WITHOUT a model round-trip,
  # records provenance as authority=policy, and skips decide.sh. budget accounting
  # mirrors the loop's own retry-vs-park test below ($attempt vs max_retries), so
  # "retries left" is computed identically. An empty fast action falls through to
  # the model decider unchanged (authority=decider).
  decider_authority="decider"
  action=""
  if [[ "$verdict" == "needs-human" ]]; then
    l1_status awaiting-human waiting "Auditor requested human judgment" true \
      "Record an artifact-bound human approval or park the task"
  fi
  l1_status deciding active "Selecting the recovery action for $attempt_failure" true \
    "Retry within policy or record a terminal decision" "" "decision-controller"
  case "$attempt_failure" in
    worker-infra|audit-infra|evidence-infra*)
      # Infrastructure exhausted its own local one-extra-try budget.  This is
      # mandatory domain separation even when ordinary decider fast paths are
      # disabled: a model action may not convert it into a product repair.
      fast_action="escalate-infra"
      ;;
    evidence-invalid*)
      # Schema/identity/lineage/budget input rejection is stable for unchanged
      # bytes. It is neither retryable infrastructure nor product repair work.
      fast_action="escalate-parked"
      ;;
    *)
      fast_action="$(singular_decider_fast_action "$attempt_failure" "$product_repairs_used" "$max_retries" "$prev_failure_class")"
      ;;
  esac
  if [[ -n "$fast_action" ]]; then
    action="$fast_action"
    decider_authority="policy"
    echo "  failure: $attempt_failure -> fast-path: $action"
  else
    # Failure -> consult the autonomous decider.
    echo "  failure: $attempt_failure -> consulting decider..."
    decider_rc=0
    dec_out="$(SINGULAR_EXPECTED_CAMPAIGN_BINDING="$l1_campaign_binding" \
      "$SCRIPT_DIR/decide.sh" --task "$task_id" --failure-class "$attempt_failure" \
      --branch "$worker_branch" --run "$run_id" --context-file "${attempt_ctx:-/dev/null}" \
      --worktree "$worktree" 2>/dev/null)" || decider_rc=$?
    [[ "$decider_rc" -ne 2 ]] \
      || l1_campaign_mismatch_exit "campaign policy changed before decider admission"
    action="$(printf '%s\n' "$dec_out" | sed -n 's/^action=//p' | tail -1)"
    [[ -n "$action" ]] || action="escalate-parked"
    echo "  decider: $action"
  fi

  if ! l1_campaign_publication_begin \
      "$l1_campaign_binding" pre-decision-publication; then
    l1_campaign_mismatch_exit \
      "campaign identity changed while selecting a recovery action"
  fi
  if [[ "$decider_authority" == "policy" ]]; then
    "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "decide:$action" \
      --rationale "fast-path: $attempt_failure -> $action" --run "$run_id" \
      --branch "$worker_branch" --authority policy >/dev/null 2>&1 || true
    singular_append_event "decider.fast_path" "decider fast-path resolved a failure" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"failureClass\":\"$attempt_failure\",\"action\":\"$action\",\"retryCount\":$product_repairs_used,\"budgetDomain\":\"$([[ \"$attempt_failure\" == *-infra* ]] && printf infrastructure || printf product-repair)\",\"productRepairsUsed\":$product_repairs_used,\"productRepairMax\":$max_retries}"
  fi

  case "$action" in
    retry|rerun-tests|rebuild-context|revalidate-evidence|amend-scope)
      if [[ $((attempt + 1)) -ge "$product_passes_remaining" ]]; then
        terminal_action="escalate-parked"
        terminal_authority="policy"
        terminal_rationale="durable product pass ceiling reached for this invocation; refusing a retry that would exceed the risk budget across re-entry"
        singular_append_event "l1.product_repair_budget_exhausted" \
          "product repair suppressed because no durable product pass remains" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"riskTier\":\"$risk_tier\",\"riskSource\":\"$risk_source\",\"failureClass\":\"$attempt_failure\",\"budgetDomain\":\"product-repair\",\"used\":$product_repairs_used,\"max\":$max_retries,\"priorLease\":$([[ \"$prior_product_lease\" == yes ]] && printf true || printf false),\"productPassesRemaining\":$product_passes_remaining}" \
          || true
        archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
        break
      fi
      if [[ "$product_repairs_used" -ge "$max_retries" ]]; then
        terminal_action="escalate-parked"
        terminal_authority="policy"
        terminal_rationale="product repair budget exhausted for $risk_tier-risk task after $product_repairs_used of $max_retries allowed repairs; audit and merged-tree gate authority remain unchanged."
        singular_append_event "l1.product_repair_budget_exhausted" \
          "bounded product repair budget exhausted" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"riskTier\":\"$risk_tier\",\"riskSource\":\"$risk_source\",\"failureClass\":\"$attempt_failure\",\"budgetDomain\":\"product-repair\",\"used\":$product_repairs_used,\"max\":$max_retries}" \
          || true
        archive_attempt "$n" "$attempt_failure" "escalate-parked" "l1"
        break
      fi
      if ! singular_lease_bump_retry "$task_id" >/dev/null 2>&1; then
        terminal_action="escalate-parked"
        terminal_authority="l1"
        terminal_rationale="product repair authorization could not be durably recorded; refusing an unaccounted retry"
        singular_append_event "l1.product_repair_budget_record_failed" \
          "product repair suppressed because durable budget accounting failed" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"failureClass\":\"$attempt_failure\",\"budgetDomain\":\"product-repair\",\"used\":$product_repairs_used,\"max\":$max_retries}" \
          || true
        archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
        break
      fi
      product_repairs_used=$((product_repairs_used + 1))
      singular_append_event "l1.product_repair_budget_consumed" \
        "product repair authorized within bounded risk policy" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"riskTier\":\"$risk_tier\",\"riskSource\":\"$risk_source\",\"failureClass\":\"$attempt_failure\",\"action\":\"$action\",\"budgetDomain\":\"product-repair\",\"used\":$product_repairs_used,\"max\":$max_retries}" \
        || true
      # Feed the failure context back to the worker as fix hints. prev_* mirror
      # this for the structured fix prompt (read after the per-iteration reset).
      fix_hints="The previous attempt failed with: $attempt_failure. Address it. Findings:"$'\n'"$(tail -c 3000 "${attempt_ctx:-/dev/null}" 2>/dev/null || true)"
      prev_failure_class="$attempt_failure"
      prev_attempt_ctx="${attempt_ctx:-/dev/null}"
      if [[ "$action" == "amend-scope" && "$attempt_failure" == "scope-violation" ]]; then
        # Minimally widen owned files with the disallowed (not forbidden) paths.
        while IFS= read -r p; do
          p="$(echo "$p" | sed 's/^ *//')"
          [[ -n "$p" ]] || continue
          if ! singular_scope_amendment_path_allowed "$p"; then
            echo "  amend-scope: ignored generated/local path $p"
            continue
          fi
          already_owned="no"
          for owned in "${owned_files[@]}"; do
            [[ "$owned" == "$p" ]] && already_owned="yes" && break
          done
          [[ "$already_owned" == "no" ]] && owned_files+=("$p")
        done < <(sed -n '/disallowed paths:/,/allowed prefixes:/p' "$run_dir/scope-check.log" 2>/dev/null | grep -E '^  ' | grep -v 'prefixes:' || true)
        echo "  amend-scope: owned files now ${owned_files[*]}"
        # Persist the widened scope to the lease so the parallel-L1 scheduler's
        # scope-overlap guard (which reads lease.ownedFiles) cannot dispatch a
        # concurrent task that collides with a path this drive just took ownership of.
        amended_owned_json="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
        singular_lease_update_owned "$task_id" "$amended_owned_json" 2>/dev/null || true
      fi
      archive_attempt "$n" "$attempt_failure" "$action" "$decider_authority"
      l1_campaign_publication_end
      continue ;;
    accept-waiver)
      if singular_unbound_waivers_enabled; then
        accepted="yes"; waiver="yes"
        archive_attempt "$n" "$attempt_failure" "accept-waiver" "$decider_authority"
      else
        terminal_action="escalate-parked"
        terminal_authority="policy"
        terminal_rationale="unbound accept-waiver is disabled; record an exact-artifact human approval or repair the product failure"
        archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
        singular_append_event "governance.unbound_waiver_rejected" \
          "legacy unbound waiver rejected; exact-artifact approval required" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"failureClass\":\"$attempt_failure\"}" \
          || true
      fi
      break ;;
    *)
      terminal_action="$action"
      terminal_authority="$decider_authority"
      archive_attempt "$n" "$attempt_failure" "$action" "$decider_authority"
      break ;;
  esac
done

# ---- Terminal (non-accept) handling — never blocks on a human ----
if [[ "$accepted" != "yes" ]]; then
  # Parking, cancellation, supersession, and evidence checkpoints are semantic
  # outcomes too. They may not mutate task/lease/decision state from a review
  # completed under a campaign that has since been replaced.
  if ! l1_campaign_publication_begin \
      "$l1_campaign_binding" pre-terminal-state-mutation; then
    l1_campaign_mismatch_exit \
      "campaign identity changed before terminal result publication"
  fi
  _l1_outcome="terminal"
  [[ -n "$terminal_action" ]] || terminal_action="escalate-parked"
  if [[ -z "$terminal_rationale" ]]; then
    if [[ "$terminal_action" == "escalate-infra" ]]; then
      terminal_rationale="environment failure ($attempt_failure), not a product defect: the workspace could not run the gate. Repair the environment, then \`singular unpark $task_id\`."
    else
      terminal_rationale="decider terminal action after $attempt_failure"
    fi
  fi
  if [[ "$terminal_action" == "awaiting-evidence" ]]; then
    l1_status terminal failed "Product audit accepted; publication awaits evidence infrastructure" true \
      "Repair evidence infrastructure and resume the accepted head" "$terminal_action"
  else
    l1_status terminal failed "Task ended without acceptance: $terminal_action" true \
      "Inspect the decision and referenced failure evidence" "$terminal_action"
  fi
  case "$terminal_action" in
    supersede) singular_lease_set_status "$task_id" "superseded" 2>/dev/null || true; singular_task_set_status "$task_file" "superseded" || true ;;
    cancel)    singular_lease_set_status "$task_id" "cancelled"  2>/dev/null || true; singular_task_set_status "$task_file" "cancelled"  || true ;;
    split-task|fork) singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true; singular_task_set_status "$task_file" "blocked" || true ;;
    *)         singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true; singular_task_set_status "$task_file" "blocked" || true ;;
  esac
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "$terminal_action" \
    --rationale "$terminal_rationale" --run "$run_id" --branch "$worker_branch" --authority "$terminal_authority" || true
  if [[ "$terminal_action" == "awaiting-evidence" ]]; then
    singular_append_event "l1.task_awaiting_evidence" \
      "product audit accepted; publication blocked on external evidence infrastructure" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"action\":\"awaiting-evidence\",\"lastFailure\":\"$attempt_failure\",\"headSha\":\"$head_sha\",\"auditVerdict\":\"accepted\",\"productAccepted\":true,\"published\":false,\"consumesProductRepairBudget\":false}"
  else
    singular_append_event "l1.task_terminal" "l1 task ended without acceptance" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"action\":\"$terminal_action\",\"lastFailure\":\"$attempt_failure\"}"
  fi
  l1_record_attempt terminal blocked "$attempt_failure" "$terminal_action" || {
    echo "l1-drive: terminal state is durable but owner-bound disposition publication failed" >&2
    l1_campaign_publication_end
    exit 75
  }
  echo ""
  if [[ "$terminal_action" == "awaiting-evidence" ]]; then
    echo "AWAITING EVIDENCE: $task_id — product audit accepted $head_sha; publication is blocked externally."
  else
    echo "NOT ACCEPTED ($terminal_action): $task_id — recorded and parked; loop continues elsewhere."
  fi
  echo "  packet: $packet  audit: $audit_record  worktree: $worktree"
  l1_campaign_publication_end
  exit 3
fi

# The audit may have taken minutes.  Verify its original campaign identity
# before touching packet, lease, task, or decision state.  A replacement
# campaign requires a new review; it must not inherit the prior verdict.
singular_campaign_binding_matches \
  "$l1_campaign_binding" l1-drive post-accepted-audit-checkpoint \
  || l1_campaign_mismatch_exit \
    "campaign runtime changed after accepted product audit"
if ! l1_campaign_publication_begin \
    "$l1_campaign_binding" pre-accepted-state-mutation; then
  l1_campaign_mismatch_exit \
    "campaign identity changed after audit; accepted verdict cannot cross campaign boundary"
fi

# ---- Accept: finalize status BEFORE inbox placement, then enqueue ----
# From this point an interruption may preserve accepted state for same-campaign
# auto-healing. Every recovery/publication path rechecks the binding.
_l1_outcome="accept-pending"
python3 - "$packet" "$waiver" <<'PY'
import json, sys
packet, waiver = sys.argv[1], sys.argv[2]
with open(packet) as f: p=json.load(f)
p["status"]="accepted"
p["nextAction"]="import into control state and reconcile"
if waiver=="yes":
    p["evidence"].append({"kind":"waiver","ref":"decider:accept-waiver"})
with open(packet,"w") as f: json.dump(p,f,indent=2); f.write("\n")
PY

singular_lease_set_status "$task_id" "accepted"
singular_task_set_status "$task_file" "accepted"
dec_rationale="auditor accepted; regression gate green; scope clean"
[[ "$waiver" == "yes" ]] && dec_rationale="accepted via decider waiver (auditor: $verdict); gate green"
"$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "accept" \
  --rationale "$dec_rationale" --run "$run_id" --branch "$worker_branch"

inbox_packet="$SINGULAR_INBOX_DIR/$run_id.json"
cp "$packet" "$inbox_packet.tmp"
mv "$inbox_packet.tmp" "$inbox_packet"
_l1_outcome="accepted"
l1_record_attempt terminal completed "" accepted || {
  echo "l1-drive: accepted state is durable but owner-bound disposition publication failed" >&2
  l1_campaign_publication_end
  exit 75
}
l1_status integrating active "Accepted packet queued for origin integration" true \
  "Finish acceptance bookkeeping and let origin reconcile"
singular_append_event "l1.task_accepted" "l1 task accepted" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$worker_branch\",\"headSha\":\"$head_sha\",\"waiver\":\"$waiver\"}"
l1_campaign_publication_end

# ---- Artifact secret-scan finalize hook (DAG node artifact-secret-scan, layer
# engine_runtime; behind the default-OFF SINGULAR_CTX_ARTIFACT_SCAN knob) --------
# Strictly AFTER acceptance is finalized above and placed BEFORE the
# post-acceptance paired-audit fresh-audit prompt is assembled from durable
# artifacts (the singular_ctx_paired_audit_record hook below), beside the paired-
# audit / critic-recheck hooks. When the knob is unset or "0" this whole block is
# a no-op: no scan, no rename, no ctx.artifact_secret event, no manifest — so the
# accepted flow is byte-identical to pre-hook behavior. When ON it delegates into
# the integrated, already-tested containment bricks (ctx-artifact-quarantine.sh,
# ctx-artifact-exclude.sh, ctx-artifact-scan.sh) and adds no scan/exclude logic
# of its own:
#   1. singular_ctx_artifact_quarantine "$run_dir" renames any durable context
#      artifact whose content matches a secret pattern to `<path>.quarantined`
#      (evidence-preserving; content never deleted), records exactly one
#      ctx.artifact_secret event per hit, and leaves the accept/reject outcome
#      untouched. The rename already removes the artifact from its canonical path.
#   2. As belt-and-suspenders beyond the rename, enumerate the durable artifacts
#      (singular_ctx_artifact_scan_paths) and apply singular_ctx_artifact_exclude so
#      any quarantined artifact is dropped from the durable-artifact set that
#      feeds downstream rendered prompt assembly; the surviving safe set is staged
#      to $run_dir/durable-artifacts.manifest.
# Non-fatal (same pattern as the capsule-write-failed / paired-audit hooks): on
# any quarantine error it logs an l1.artifact_scan_failed event and NEVER aborts
# the drive. The quarantine/exclude result NEVER feeds back into the accept
# decision or the exit status.
if [[ -n "${SINGULAR_CTX_ARTIFACT_SCAN:-}" && "${SINGULAR_CTX_ARTIFACT_SCAN}" != "0" ]]; then
  # singular_secret_scan_patterns now lives in lib.sh (reading
  # engine/secret-patterns.tsv), so it is already defined here. It used to live
  # inside secret-scan.sh — a self-executing script lib.sh does not source —
  # which forced this branch to sed the function body out and eval it.
  if ! singular_ctx_artifact_quarantine "$run_dir" >/dev/null 2>&1; then
    singular_append_event "l1.artifact_scan_failed" "artifact secret-scan quarantine failed (non-fatal)" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}" || true
  fi
  # Belt-and-suspenders: the durable-artifact set that feeds downstream prompt
  # assembly, with every quarantined artifact excluded. Non-fatal.
  singular_ctx_artifact_scan_paths "$run_dir" 2>/dev/null \
    | singular_ctx_artifact_exclude > "$run_dir/durable-artifacts.manifest" 2>/dev/null \
    || true
fi

# Post-acceptance paired audit (observability only). Strictly AFTER acceptance is
# finalized above; self-guards on the default-OFF SINGULAR_PAIRED_AUDIT_PCT knob
# (unset/0 -> no fresh audit, no event, no file) so the accepted flow is
# byte-identical when disabled. The paired verdict NEVER feeds back into the
# accept decision or the exit status; a recorder/runner failure is non-fatal.
singular_ctx_paired_audit_record "$run_id" "$task_id" "$run_dir" "$worktree" || true

# Post-acceptance critic recheck (read-only; observability only). Strictly AFTER
# acceptance is finalized above, beside the paired-audit hook. Minimal delegation
# per the planner driver-hook rule: resolve the node and the prior plan-critique
# record via the pure/read-only locators (TASK-0032), and only when BOTH resolve
# invoke the recheck runner (TASK-0031). The runner self-guards on the default-OFF
# SINGULAR_CRITIC_RECHECK_PCT sampling gate (unset/0 -> no ctx.critic_recheck event,
# no recheck files, no state write) so the accepted flow is byte-identical when
# disabled. The recheck verdict/dispositions NEVER feed back into the accept
# decision or the exit status; a locator or runner failure is non-fatal (guarded).
#
# The integrated locators/runner are reached through an ASSEMBLED PREFIX (never the
# contiguous literal name), mirroring engine/ctx-critic-recheck-run.sh: this is the
# codebase's S2 contract-gate idiom that keeps a brick "structurally present but
# uncalled" under its own literal-substring invariance grep while a later slice
# (this hook) legitimately composes it (planner-contract rule 9). The delegation
# adds no recheck logic of its own.
_cr_pfx=singular_ctx_critic_recheck_
critic_recheck_node="$("${_cr_pfx}locate_node" "$task_id" "$worktree" 2>/dev/null || true)"
if [[ -n "$critic_recheck_node" ]]; then
  critic_recheck_record="$("${_cr_pfx}locate_record" "$critic_recheck_node" "$task_id" "$worktree" 2>/dev/null || true)"
  if [[ -n "$critic_recheck_record" ]]; then
    "${_cr_pfx}run" "$critic_recheck_node" "$run_id" "$task_id" "$run_dir" "$critic_recheck_record" "$worktree" || true
  fi
fi
unset _cr_pfx

# ---- Experiment arm knob-state finalize hook (DAG node experiment-run, layer
# evaluation; behind the default-OFF SINGULAR_CTX_ARMSTATE knob) ----------------
# Beside the sibling per-run provenance blocks above (the SINGULAR_CTX_ARTIFACT_SCAN
# durable-artifacts block, the paired-audit recorder, and the critic-recheck
# block): durably RECORD this run's observed continuity knob-state so the
# experiment report's per-arm attribution (control = M0 knob-state vs treatment)
# is auditable on disk. TASK-0093 shipped the pure read-only emitter
# singular_ctx_experiment_armstate_json but left it present-but-uncalled; this hook
# is the separable driver wire-in that emitter's context packet deferred.
#
# Minimal delegating call site — it inlines NO knob-state logic and only forwards
# to the integrated emitter, writing its output (for the run's environment) to a
# durable arm-knob-state.json under the run directory, non-fatal (|| true),
# mirroring the SINGULAR_CTX_ARTIFACT_SCAN block that writes durable-artifacts.manifest.
# When the knob is unset or "0" this whole block is a no-op: no file, no event,
# no state write — the accepted flow is byte-identical to pre-hook behavior. The
# recorded knob-state NEVER feeds back into the accept decision or the exit status
# (evidence invariance; it only writes an auditable file).
if [[ -n "${SINGULAR_CTX_ARMSTATE:-}" && "${SINGULAR_CTX_ARMSTATE}" != "0" ]]; then
  singular_ctx_experiment_armstate_json > "$run_dir/arm-knob-state.json" 2>/dev/null || true
fi

l1_status terminal completed "Accepted packet and audit evidence are durable" true \
  "Origin may import and integrate the packet" "accepted"
echo ""
echo "ACCEPTED: $task_id @ $head_sha (waiver=$waiver)"
echo "  packet: $inbox_packet  audit: $audit_record (verdict: $verdict)"
echo "  next: 'make orch-reconcile' to import, or let L0 actuate."
