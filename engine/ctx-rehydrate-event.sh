#!/usr/bin/env bash
# ctx-rehydrate-event.sh — pure, read-only strategy-event payload builder (stage
# S5-routing, node `rehydrate-path`, layer engine_runtime). Sourced exactly once
# by the context-evolution loader block in lib.sh (it matches the ctx-*.sh glob),
# and called by the rehydrate strategy path before worker invocation.
#
#   singular_ctx_rehydrate_event_data \
#     <role> <task-id> <run-id> <attempt> <reason> <run_dir> [extra-id=path ...]
#
# Prints a single compact JSON object on stdout, suitable as the third (`data`)
# argument to `singular_append_event "context.strategy_selected"`. It extends the
# existing resume/fresh strategy payload shape ADDITIVELY:
#
#   {"taskId":…,"runId":…,"role":…,"attempt":<n>,"strategy":"rehydrate",
#    "reason":"<reason>","manifest":<manifest-json>}
#
# with `attempt` numeric, the other scalars strings, and `manifest` a NESTED JSON
# object (not a stringified blob) so `singular_append_event`'s json.loads stores it
# as structured data rather than a {"raw":…} fallback.
#
# `manifest` is the deterministic output of singular_ctx_rehydrate_manifest applied
# to singular_ctx_rehydrate_sources <run_dir> [extra…] — i.e.
#   {"schema":"singular.orchestration.ctx-rehydrate-manifest.v0",
#    "sources":[{"id","sha256"}…]}
# recording exactly which surviving durable artifacts, at which content hashes,
# the run rehydrates from. It records the MANIFEST (ids + hashes) only, never the
# packet body, so durable artifact bytes are not duplicated into the event stream.
#
# Quarantine-aware transitively: quarantined artifacts are absent from
# manifest.sources because the assembler already composes
# singular_ctx_artifact_exclude. Deterministic: identical run_dir bytes yield
# byte-identical event data. Robust to an empty source set: manifest.sources is []
# and the object is still well-formed valid JSON.
#
# Pure and READ-ONLY: it reads artifact bytes (transitively, to hash them) but
# never writes, renames, or deletes anything, and appends NO events itself (it
# produces the data string; l1-drive.sh records it). It confers NO independence:
# `rehydrate` remains tainted per singular_ctx_route_strategy_tainted.

# singular_ctx_rehydrate_event_data <role> <task-id> <run-id> <attempt> <reason> <run_dir> [extra-id=path ...]
singular_ctx_rehydrate_event_data() {
  local role="${1-}" task_id="${2-}" run_id="${3-}" attempt="${4-}" reason="${5-}" run_dir="${6-}"
  [[ $# -ge 6 ]] && shift 6 || shift $#

  # Resolve the surviving durable sources for this run (plus caller extras), then
  # assemble the quarantine-aware manifest over exactly those specs. Both helpers
  # are pure and read-only; the manifest is the single content-hash authority.
  # SUBGRAPH branch (node subgraph-rehydrate; behind SINGULAR_CTX_SUBGRAPH_REHYDRATE
  # and only on the treatment arm with a present non-empty corpus). The shared
  # selector yields the subgraph manifest keyed on the SAME task_id / arm-mode /
  # node the packet-injection site (l1-drive.sh) keys on, so the recorded manifest
  # documents exactly the injected sources (same-sources invariant). With the knob
  # off / control arm / absent corpus the selector returns non-zero/empty and the
  # flat manifest below is recorded unchanged (byte-identical to today).
  local manifest=""
  local subgraph_manifest
  if subgraph_manifest="$(singular_ctx_route_subgraph_render "$task_id" manifest 2>/dev/null)" \
     && [[ -n "$subgraph_manifest" ]]; then
    manifest="$subgraph_manifest"
  else
    local -a source_specs=()
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && source_specs+=("$line")
    done < <(singular_ctx_rehydrate_sources "$run_dir" "$@")

    if [[ ${#source_specs[@]} -gt 0 ]]; then
      manifest="$(singular_ctx_rehydrate_manifest "${source_specs[@]}")"
    else
      # Empty source set -> the manifest is still well-formed with sources: [].
      manifest="$(singular_ctx_rehydrate_manifest)"
    fi
  fi

  # OPTIONAL authored-knowledge counterpart (node rehydrate-path; NOT part of
  # requiredCompletion, does NOT gate the node). ALSO record the config-gated
  # authored manifest entries alongside the durable sources, using the SAME
  # trigger set TASK-0062 injects with so the recorded authored entries match the
  # injected authored section (consistency invariant). The set comes from the pure
  # builder singular_ctx_rehydrate_authored_triggers (TASK-0064): the run's
  # deterministic, de-duplicated `load-when` tokens (role `implementer`, step
  # `implement`, task id) rather than the bare literal `implement`, so authored
  # entries scoped to a role or task — not only the literal step — become
  # eligible. The enriched set is a strict superset of {implement}, so
  # implement-scoped entries still match (backward compatible), and the injection
  # site (engine/l1-drive.sh) passes the IDENTICAL set. This is a minimal
  # delegation into the integrated config gate (TASK-0058–0061): no
  # config/selection/render logic is inlined here. The gate internally checks
  # SINGULAR_CTX_MANIFEST (default 0) and the OPTIONAL singular.config.json
  # `contextManifest` field, so with either OFF it returns empty and nothing is
  # merged — OFF-parity keeps the event data byte-identical to the durable-only
  # payload. Non-fatal: on any error nothing is merged.
  #
  # NODE dimension (TASK-0066 -> TASK-0067): resolve the run's executable DAG node
  # via the pure read-only resolver singular_ctx_rehydrate_authored_node from this
  # site's own "$task_id" parameter (no signature change) and thread it into the
  # builder's position-3 [node] slot so node-scoped `load-when` entries become
  # eligible. Empty (fail-safe) on an absent/ambiguous association -> the builder
  # skips it and the set stays byte-identical to the pre-node-dimension behavior.
  # The injection site (engine/l1-drive.sh) resolves from the SAME task_id via the
  # SAME deterministic resolver, so both derive the identical token and identical
  # trigger set, preserving the injected<->recorded consistency invariant.
  local node
  node="$(singular_ctx_rehydrate_authored_node "$task_id" 2>/dev/null)" || node=""
  local -a authored_triggers=()
  local trigger
  while IFS= read -r trigger; do
    [[ -n "$trigger" ]] && authored_triggers+=("$trigger")
  done < <(singular_ctx_rehydrate_authored_triggers implementer implement "$node" "$task_id" 2>/dev/null)
  local authored
  # Legacy inputs remain fail-soft in the configuration adapter. A configured
  # brain descriptor is strict: preserve its diagnostic and nonzero status so
  # l1-drive can stop before invoking the affected worker.
  authored="$(singular_ctx_rehydrate_authored_config_manifest ${authored_triggers[@]+"${authored_triggers[@]}"})" || return $?

  # Embed the metadata scalars and the NESTED manifest object into a single
  # compact JSON object. Pure: reads its argv, writes only stdout.
  python3 - "$role" "$task_id" "$run_id" "$attempt" "$reason" "$manifest" "$authored" <<'PY'
import json
import sys

role, task_id, run_id, attempt_raw, reason, manifest_raw, authored_raw = sys.argv[1:8]

# `attempt` is numeric in the additive payload shape; stay non-fatal if a caller
# ever passes a non-integer by keeping the raw value rather than raising.
try:
    attempt = int(attempt_raw)
except ValueError:
    attempt = attempt_raw

try:
    manifest = json.loads(manifest_raw)
except json.JSONDecodeError:
    manifest = {"raw": manifest_raw}

# Merge the config-gated authored-knowledge manifest under a DISTINGUISHABLE
# `authored` key, recorded apart from the durable host-verified `sources` and
# never as authoritative. The gate returns empty when OFF/unconfigured, so the
# key is added ONLY when there is a well-formed authored manifest to record —
# preserving OFF-parity (byte-identical to the durable-only payload). A malformed
# legacy blob is skipped (fail-soft). Strict brain validation has already failed
# this function before this projection is reached.
if authored_raw.strip() and isinstance(manifest, dict):
    try:
        authored = json.loads(authored_raw)
    except json.JSONDecodeError:
        authored = None
    if authored is not None:
        manifest["authored"] = authored

obj = {
    "taskId": task_id,
    "runId": run_id,
    "role": role,
    "attempt": attempt,
    "strategy": "rehydrate",
    "reason": reason,
    "manifest": manifest,
}
# sort_keys keeps output byte-identical across runs for identical inputs.
sys.stdout.write(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
sys.stdout.write("\n")
PY
}

# Build and publish the exact prompt crossing a provider boundary. This hook is
# independent of resume/rehydrate routing: contextService.enabled is its only
# feature gate. The prompt bytes and the context.bundle_selected event are read
# from one immutable bundle, preventing prompt/provenance skew.
#
# singular_context_invocation_prepare ROLE PHASE TASK PROMPT BUNDLE [PRIOR]
singular_context_invocation_prepare() {
  local role="$1" phase="$2" task="$3" prompt="$4" bundle="$5" prior="${6:-}"
  local config="${SINGULAR_CONTEXT_CONFIG_FILE:-${SINGULAR_JSON_CONFIG_FILE:-$SINGULAR_ROOT/singular.config.json}}"
  [[ -f "$config" ]] || return 0

  local settings
  settings="$(python3 - "$config" 2>/dev/null <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
    settings = value.get("contextService") or {}
    if not isinstance(settings, dict):
        raise ValueError("contextService must be an object")
    enabled = settings.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ValueError("contextService.enabled must be boolean")
    budget = settings.get("budgetBytes", 65536)
    if not isinstance(budget, int) or isinstance(budget, bool) or budget < 1:
        raise ValueError("contextService.budgetBytes must be a positive integer")
    print(("1" if enabled else "0") + "\t" + str(budget))
except Exception as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(2)
PY
  )" || {
    echo "context service: invalid configuration: $config" >&2
    return 2
  }
  local enabled="${settings%%$'\t'*}" budget="${settings#*$'\t'}"
  [[ "$enabled" == "1" ]] || return 0
  [[ -z "${SINGULAR_CONTEXT_BUDGET_BYTES:-}" ]] || budget="$SINGULAR_CONTEXT_BUDGET_BYTES"
  [[ "$budget" =~ ^[1-9][0-9]*$ ]] || {
    echo "context service: invocation budget must be a positive integer" >&2
    return 2
  }

  local delivery="initial"
  [[ -n "$prior" && -f "$prior" ]] && delivery="delta"
  local engine_dir="${SINGULAR_ENGINE_DIR:-${SINGULAR_ENGINE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/engine}"
  local -a args=(
    build --config "$config" --role "$role" --phase "$phase"
    --task "$task" --base-prompt "$prompt" --prompt-output "$prompt"
    --budget-bytes "$budget" --delivery "$delivery" --output "$bundle"
  )
  [[ "$delivery" == "delta" ]] && args+=(--prior-bundle "$prior")
  python3 "$engine_dir/context_cli.py" "${args[@]}" >/dev/null || return $?

  local event_data
  event_data="$(python3 - "$bundle" "$role" "$phase" <<'PY'
import json, os, sys
path, role, phase = sys.argv[1:4]
data = json.load(open(path, encoding="utf-8"))
provenance = data["provenance"]
all_reasons = [reason for item in provenance for reason in item.get("reasons", [])]
prior = next((reason.split(":", 1)[1] for reason in all_reasons if reason.startswith("prior_bundle:")), None)
delivery = {
    "mode": "delta" if prior else "initial",
    "priorBundleId": prior,
    "changedRefs": [item["ref"] for item in provenance if "changed_source" in item.get("reasons", [])],
    "unchangedRefs": [item["ref"] for item in provenance if "unchanged_immutable_reference" in item.get("reasons", [])],
    "revokedRefs": [item["ref"] for item in data["omissions"] if item.get("reason") == "revoked_since_prior_bundle"],
}
print(json.dumps({
    "role": role,
    "phase": phase,
    "bundleId": data["bundleId"],
    "promptSha256": data["promptSha256"],
    "bundleRef": os.path.basename(path),
    "identity": data["identity"],
    "delivery": delivery,
    "budget": data["budget"],
    "omissions": data["omissions"],
    "sourceProvenance": [
        {key: item.get(key) for key in ("ref", "kind", "sourceSha256", "validity", "reasons")}
        for item in data["provenance"]
    ],
}, separators=(",", ":")))
PY
  )" || return $?
  singular_append_event "context.bundle_selected" \
    "context service prompt bundle selected for provider invocation" "$event_data"
}
