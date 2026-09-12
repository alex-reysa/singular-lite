#!/usr/bin/env bash
# Campaign freeze control plane. An explicit campaign pins the executable and
# policy surface before autonomous work begins; verify is intentionally read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
manifest_path="${SINGULAR_CAMPAIGN_MANIFEST:-$SINGULAR_STATE_DIR/campaign/manifest.json}"
campaign_dir="$(dirname "$manifest_path")"
active_path="$campaign_dir/ACTIVE"
transition_path="$campaign_dir/TRANSITION"
epoch_path="$campaign_dir/EPOCH"
# This latch intentionally lives outside the ACTIVE/manifest pair. Once a repo
# opts into campaign enforcement, deleting both members of that pair must not
# silently downgrade it to a legacy unfrozen repo.
enforced_path="$SINGULAR_STATE_DIR/CAMPAIGN_ENFORCED"
campaign_lock_held="no"
campaign_git_lock_held="no"
campaign_candidate=""
campaign_release_locks() {
  if [[ "$campaign_lock_held" == "yes" ]]; then
    singular_campaign_lock_release 2>/dev/null || true
    campaign_lock_held="no"
  fi
  if [[ "$campaign_git_lock_held" == "yes" ]]; then
    singular_git_lock_release 2>/dev/null || true
    campaign_git_lock_held="no"
  fi
  if [[ -n "$campaign_candidate" ]]; then
    rm -f "$campaign_candidate" 2>/dev/null || true
    campaign_candidate=""
  fi
}
trap campaign_release_locks EXIT

# Resolve the knobs that autonomate.sh historically defaulted only in its own
# process. Campaign creation and the per-cycle verifier must see the same
# effective values even when the operator left them unset.
SINGULAR_AUTO_INTEGRATE="${SINGULAR_AUTO_INTEGRATE:-1}"
SINGULAR_PUSH="${SINGULAR_PUSH:-1}"
SINGULAR_GENERATE="${SINGULAR_GENERATE:-1}"
SINGULAR_SLEEP="${SINGULAR_SLEEP:-20}"
SINGULAR_QUOTA_SLEEP_CAP="${SINGULAR_QUOTA_SLEEP_CAP:-300}"
SINGULAR_QUOTA_WAIT_BUDGET="${SINGULAR_QUOTA_WAIT_BUDGET:-10800}"
SINGULAR_OVERLOAD_WAIT_BUDGET="${SINGULAR_OVERLOAD_WAIT_BUDGET:-3600}"

campaign_export_settings() {
  # lib.sh resolves a substantial part of the policy as non-exported shell
  # defaults. Export every scalar SINGULAR_* value for the manifest subprocess;
  # campaign_manifest.py stores only value digests and filters invocation-local
  # runner outputs. Arrays are call-local argv/state and cannot be exported.
  local name declaration declaration_flags
  while IFS= read -r name; do
    declaration="$(declare -p "$name" 2>/dev/null || true)"
    declaration_flags="${declaration#declare -}"
    declaration_flags="${declaration_flags%% *}"
    case "$declaration_flags" in
      *a*|*A*) continue ;;
    esac
    export "$name"
  done < <(compgen -A variable SINGULAR_ | sort)
}

campaign_args() {
  local bash_bin planner_template critic_template context_config
  bash_bin="$(singular_bash_bin)"
  planner_template="${SINGULAR_PLANNER_TEMPLATE:-$SINGULAR_ORCH_DIR/prompts/l1-planner.md}"
  critic_template="${SINGULAR_PLAN_CRITIC_TEMPLATE:-$SINGULAR_ORCH_DIR/prompts/plan-critic.md}"
  context_config="${SINGULAR_CONTEXT_CONFIG_FILE:-$SINGULAR_JSON_CONFIG_FILE}"
  printf '%s\0' --engine-home "$SINGULAR_ENGINE_HOME" --config-json "$SINGULAR_JSON_CONFIG_FILE" \
    --config-shell "$SINGULAR_CONFIG_FILE" --config-local "$SINGULAR_LOCAL_CONFIG_FILE" \
    --bash-bin "$bash_bin" --runner "${SINGULAR_RUNNER:-}" --gate-command "${SINGULAR_DEFAULT_GATE_CMD:-}" \
    --gate-driver "$SCRIPT_DIR/gate-check.sh" --gate-schema "$SINGULAR_GATE_SCHEMA" \
    --evidence-driver "$SCRIPT_DIR/evidence-manifest.sh" --packet-schema "$SINGULAR_PACKET_SCHEMA" \
    --audit-schema "$SINGULAR_AUDIT_SCHEMA" \
    --active-policy "consumer-prompts=$SINGULAR_ORCH_DIR/prompts" \
    --active-policy "engine-prompt-fallbacks=$SINGULAR_ENGINE_HOME/templates/prompts" \
    --active-policy "consumer-planner-contract=$SINGULAR_ORCH_DIR/planner-contract.md" \
    --active-policy "campaign-dag=${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}" \
    --active-policy "active-schema-root=$SINGULAR_SCHEMA_DIR" \
    --active-policy "secret-patterns=${SINGULAR_SECRET_PATTERNS_FILE:-}" \
    --active-policy "planner-template=$planner_template" \
    --active-policy "critic-template=$critic_template" \
    --active-policy "promoter=${SINGULAR_PROMOTER:-}" \
    --active-policy "reconcile-driver=${SINGULAR_RECONCILE_SCRIPT:-$SCRIPT_DIR/reconcile.sh}" \
    --active-policy "gate-baseline=${SINGULAR_GATE_BASELINE_FILE:-}" \
    --active-policy "context-service-config=$context_config"
}
read_campaign_args() {
  campaign_export_settings
  CAMPAIGN_ARGS=()
  while IFS= read -r -d '' item; do CAMPAIGN_ARGS+=("$item"); done < <(campaign_args)
}
campaign_manifest_id() {
  python3 - "$manifest_path" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("campaignId", "")
except (OSError, ValueError):
    value = ""
print(value)
PY
}
campaign_manifest_epoch() {
  python3 - "$manifest_path" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("campaignEpoch", "")
except (OSError, ValueError):
    value = ""
print(value)
PY
}
campaign_new_epoch() {
  python3 -c 'import secrets; print(secrets.token_hex(24))'
}
campaign_write_epoch() {
  local value="$1" temporary="$epoch_path.tmp.${BASHPID:-$$}"
  [[ "$value" =~ ^[0-9a-f]{48}$ ]] || return 2
  printf '%s\n' "$value" >"$temporary" || return 2
  mv "$temporary" "$epoch_path"
}
campaign_state_consistent() {
  [[ -f "$manifest_path" && -f "$active_path" && -f "$enforced_path" ]] || return 1
  local manifest_id active_id manifest_epoch active_epoch
  manifest_id="$(campaign_manifest_id)"
  active_id="$(tr -d '\r\n' <"$active_path")"
  [[ "$manifest_id" =~ ^[A-Za-z0-9._:-]+$ && "$active_id" == "$manifest_id" ]] \
    || return 1
  manifest_epoch="$(campaign_manifest_epoch)"
  # Pre-epoch manifests remain readable for upgrade compatibility. Every new
  # campaign carries an epoch and requires the durable marker to match it.
  if [[ -n "$manifest_epoch" ]]; then
    [[ "$manifest_epoch" =~ ^[0-9a-f]{48}$ && -f "$epoch_path" ]] || return 1
    active_epoch="$(tr -d '\r\n' <"$epoch_path")"
    [[ "$active_epoch" == "$manifest_epoch" ]] || return 1
  fi
  return 0
}
campaign_archive_active() {
  local reason="$1" campaign_id stamp history_dir destination
  campaign_state_consistent || {
    echo "campaign: inconsistent ACTIVE state; expected matching $active_path and $manifest_path" >&2
    return 2
  }
  campaign_id="$(campaign_manifest_id)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  history_dir="$campaign_dir/history"
  destination="$history_dir/$campaign_id.$stamp.$reason.json"
  mkdir -p "$history_dir"
  [[ ! -e "$destination" && ! -e "$destination.ACTIVE" ]] \
    || destination="$history_dir/$campaign_id.$stamp.$reason.$$.json"
  mv "$manifest_path" "$destination" || return 2
  if ! mv "$active_path" "$destination.ACTIVE"; then
    mv "$destination" "$manifest_path" 2>/dev/null || true
    return 2
  fi
  printf '%s\n' "$destination"
}
campaign_begin_transition() {
  local action="$1" temporary="$transition_path.tmp.$$"
  mkdir -p "$campaign_dir"
  printf '%s\n' "$action" >"$temporary"
  mv "$temporary" "$transition_path"
}
campaign_enforce() {
  local temporary="$enforced_path.tmp.$$"
  mkdir -p "$SINGULAR_STATE_DIR"
  printf '%s\n' 'singular-campaign-enforced-v1' >"$temporary"
  mv "$temporary" "$enforced_path"
}
usage() {
  cat <<'EOF'
usage: campaign.sh {start|end|verify|status|canary} [options]
  start [--id ID] [--replace] [--allow-provider-unchecked]
                                run the canary, then freeze this campaign
  end                           archive and deactivate the current campaign
  verify [--quiet]             compare the current runtime with the frozen manifest
  status                       show the active manifest, if any
  canary [--fixture] [--json] [--allow-provider-unchecked]
                                non-destructive lifecycle canary
EOF
}
cmd="${1:-}"; shift || true
case "$cmd" in
  start)
    campaign_id="CAMPAIGN-$(date -u +%Y%m%dT%H%M%SZ)-$$"; replace="no"; provider_unchecked="no"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) campaign_id="${2:-}"; shift 2 ;;
        --replace) replace="yes"; shift ;;
        --allow-provider-unchecked) provider_unchecked="yes"; shift ;;
        *) echo "campaign start: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [[ "$campaign_id" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "campaign start: invalid id" >&2; exit 2; }
    replace_pending="no"
    if [[ -e "$transition_path" ]]; then
      echo "campaign start: incomplete prior campaign transition at $transition_path; refusing to overwrite fail-closed state" >&2
      exit 2
    fi
    if [[ -e "$manifest_path" || -e "$active_path" || -e "$enforced_path" ]]; then
      if [[ "$replace" != "yes" ]]; then
        echo "campaign start: active or enforced campaign state exists (run 'singular campaign end', or use --replace explicitly)" >&2; exit 2
      fi
      campaign_state_consistent || {
        echo "campaign start: cannot replace inconsistent enforced state; ACTIVE, manifest, and enforcement latch must all match" >&2
        exit 2
      }
      replace_pending="yes"
    fi
    canary_args=()
    [[ "$provider_unchecked" == "yes" ]] && canary_args+=(--allow-provider-unchecked)
    canary_rc=0
    canary_report="$("$SCRIPT_DIR/campaign-canary.sh" --json "${canary_args[@]}")" || canary_rc=$?
    if [[ "$canary_rc" -ne 0 ]]; then
      printf '%s\n' "$canary_report" >&2
      exit "$canary_rc"
    fi
    provider_assurance="$(python3 - "$canary_report" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
if data.get("providerInvoked") is True and data.get("providerUnchecked") is False:
    print("live-provider-readonly-probe-passed")
elif data.get("providerUnchecked") is True and data.get("providerUncheckedWaived") is True:
    print("live-provider-unchecked-explicit-waiver")
else:
    raise SystemExit(2)
PY
)" || { echo "campaign start: canary did not provide a valid provider assurance" >&2; exit 2; }
    echo "campaign canary PASS: provider assurance=$provider_assurance"

    # Bind the canary to the exact runtime snapshot it exercised. The candidate
    # is computed immediately after the canary; after lock acquisition it is
    # verified again before becoming authoritative. A config/engine/prompt
    # change while waiting therefore forces a fresh canary rather than freezing
    # bytes that were never exercised.
    mkdir -p "$campaign_dir"
    candidate_epoch="$(campaign_new_epoch)"
    read_campaign_args
    campaign_candidate="$campaign_dir/.manifest-candidate.$$.json"
    python3 "$SCRIPT_DIR/campaign_manifest.py" create \
      --output "$campaign_candidate" --campaign-id "$campaign_id" \
      --campaign-epoch "$candidate_epoch" \
      --provider-assurance "$provider_assurance" "${CAMPAIGN_ARGS[@]}" >/dev/null

    # Campaign transitions use the same canonical lock order as integration:
    # git first, then campaign publication. A staged merge is a transient tree,
    # never a valid campaign fingerprint, so fail closed instead of freezing it.
    singular_git_lock_acquire || {
      echo "campaign start: could not acquire git operation lock" >&2
      exit 75
    }
    campaign_git_lock_held="yes"
    if git -C "$SINGULAR_ROOT" rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
      echo "campaign start: repository has a staged merge; finish or abort it before changing campaigns" >&2
      exit 2
    fi
    singular_campaign_lock_acquire || {
      echo "campaign start: could not acquire campaign publication lock" >&2
      exit 75
    }
    campaign_lock_held="yes"
    # The canary is deliberately outside the short publication lock. Recheck
    # all transition preconditions now that no semantic result can publish and
    # no other campaign transition can race this replacement.
    replace_pending="no"
    if [[ -e "$manifest_path" || -e "$active_path" || -e "$enforced_path" ]]; then
      if [[ "$replace" != "yes" ]]; then
        echo "campaign start: active or enforced campaign state appeared during canary" >&2
        exit 2
      fi
      campaign_state_consistent || {
        echo "campaign start: cannot replace inconsistent enforced state after canary" >&2
        exit 2
      }
      replace_pending="yes"
    fi
    read_campaign_args
    candidate_report="$(python3 "$SCRIPT_DIR/campaign_manifest.py" verify \
      --manifest "$campaign_candidate" "${CAMPAIGN_ARGS[@]}")" || {
      echo "campaign start: runtime changed after canary; refusing untested campaign snapshot" >&2
      printf '%s\n' "${candidate_report:-}" >&2
      exit 2
    }
    campaign_begin_transition "starting:$campaign_id"
    # Create the persistent enforcement boundary as part of the transition.
    # Replacement never removes it; only a successful explicit end may do so.
    campaign_enforce
    if [[ "$replace_pending" == "yes" ]]; then
      archived="$(campaign_archive_active replaced)" || exit $?
      echo "campaign replaced; prior manifest archived: $archived"
    fi
    campaign_write_epoch "$candidate_epoch" || {
      echo "campaign start: could not publish campaign epoch" >&2
      exit 2
    }
    mv "$campaign_candidate" "$manifest_path"
    campaign_candidate=""
    active_tmp="$active_path.tmp.$$"
    printf '%s\n' "$campaign_id" >"$active_tmp"
    mv "$active_tmp" "$active_path"
    rm -f "$transition_path"
    singular_append_event "campaign.started" "campaign runtime fingerprint frozen" \
      "{\"campaignId\":\"$campaign_id\",\"providerAssurance\":\"$provider_assurance\"}"
    echo "campaign started: $campaign_id"
    echo "manifest: $manifest_path"
    campaign_release_locks
    ;;
  end)
    [[ $# -eq 0 ]] || { echo "campaign end: unknown option: $1" >&2; exit 2; }
    singular_git_lock_acquire || {
      echo "campaign end: could not acquire git operation lock" >&2
      exit 75
    }
    campaign_git_lock_held="yes"
    if git -C "$SINGULAR_ROOT" rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
      echo "campaign end: repository has a staged merge; finish or abort it before changing campaigns" >&2
      exit 2
    fi
    singular_campaign_lock_acquire || {
      echo "campaign end: could not acquire campaign publication lock" >&2
      exit 75
    }
    campaign_lock_held="yes"
    [[ ! -e "$transition_path" ]] || { echo "campaign end: incomplete prior transition at $transition_path" >&2; exit 2; }
    campaign_state_consistent || { echo "campaign end: no consistent active campaign" >&2; exit 2; }
    campaign_id="$(campaign_manifest_id)"
    ended_epoch="$(campaign_new_epoch)"
    campaign_begin_transition "ending:$campaign_id"
    archived="$(campaign_archive_active ended)" || exit $?
    campaign_write_epoch "$ended_epoch" || {
      echo "campaign end: could not rotate inactive campaign epoch" >&2
      exit 2
    }
    rm -f "$transition_path"
    singular_append_event "campaign.ended" "campaign explicitly deactivated" "{\"campaignId\":\"$campaign_id\"}" || true
    rm -f "$enforced_path"
    echo "campaign ended: $campaign_id"
    echo "archived manifest: $archived"
    campaign_release_locks
    ;;
  verify)
    quiet="no"; [[ "${1:-}" == "--quiet" ]] && { quiet="yes"; shift; }
    [[ $# -eq 0 ]] || { echo "campaign verify: unknown option: $1" >&2; exit 2; }
    if [[ -e "$transition_path" ]]; then
      [[ "$quiet" == "yes" ]] || echo "campaign verify: incomplete campaign transition; refusing fail-closed" >&2
      exit 2
    fi
    if [[ ! -e "$manifest_path" && ! -e "$active_path" ]]; then
      if [[ -e "$enforced_path" ]]; then
        [[ "$quiet" == "yes" ]] || echo "campaign verify: enforcement latch present but ACTIVE/manifest pair is missing" >&2
        exit 2
      fi
      if [[ "${SINGULAR_CAMPAIGN_REQUIRE_MANIFEST:-0}" == "1" ]]; then
        [[ "$quiet" == "yes" ]] || echo "campaign verify: no active campaign manifest at $manifest_path" >&2
        exit 2
      fi
      [[ "$quiet" == "yes" ]] || echo "campaign: no active manifest (legacy/unfrozen run)"
      exit 0
    fi
    if ! campaign_state_consistent; then
      [[ "$quiet" == "yes" ]] || echo "campaign verify: inconsistent ACTIVE state (marker/manifest missing or campaign id mismatch)" >&2
      exit 2
    fi
    read_campaign_args
    rc=0; report="$(python3 "$SCRIPT_DIR/campaign_manifest.py" verify --manifest "$manifest_path" "${CAMPAIGN_ARGS[@]}")" || rc=$?
    if [[ "$quiet" != "yes" || "$rc" -ne 0 ]]; then printf '%s\n' "$report"; fi
    if [[ "$rc" -ne 0 ]]; then echo "campaign verify: runtime drift detected; start a replacement campaign after reviewing the change" >&2; exit "$rc"; fi
    [[ "$quiet" == "yes" ]] || echo "campaign verify: frozen runtime matches"
    ;;
  status)
    if [[ -e "$transition_path" ]]; then
      echo "campaign: INVALID transition state ($(cat "$transition_path" 2>/dev/null || echo unknown))" >&2
      exit 2
    elif [[ ! -e "$manifest_path" && ! -e "$active_path" ]]; then
      if [[ -e "$enforced_path" ]]; then
        echo "campaign: INVALID enforced state (ACTIVE/manifest pair missing)" >&2
        exit 2
      fi
      echo "campaign: no active manifest"
    elif campaign_state_consistent; then
      cat "$manifest_path"
    else
      echo "campaign: INVALID ACTIVE state (marker/manifest missing or campaign id mismatch)" >&2
      exit 2
    fi
    ;;
  canary) exec "$SCRIPT_DIR/campaign-canary.sh" "$@" ;;
  *) usage >&2; exit 2 ;;
esac
