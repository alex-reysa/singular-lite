#!/usr/bin/env bash
# ctx-rehydrate-authored-config.sh — pure, read-only config-gated entry point for
# the authored-knowledge manifest (stage S5-routing, node `rehydrate-path`, layer
# engine_runtime; singular-brain integration point 4). Sourced exactly once by the
# context-evolution loader block in lib.sh (it matches the ctx-*.sh glob). The
# rehydrate driver and strategy-event builder call these functions at their
# existing authored-context boundary.
#
# This extends the explicitly optional authored-knowledge configuration gate.
# SINGULAR_CTX_MANIFEST (default 0) gates the feature; with it unset the entry
# point emits nothing. Legacy string manifests keep the original authored
# selector, while object descriptors use the local standard-library brain
# consumer without depending on the producer runtime.
#
#   singular_ctx_rehydrate_authored_config_render   [trigger ...]
#   singular_ctx_rehydrate_authored_config_manifest [trigger ...]
#
# Both emit the authored packet section / manifest entries ONLY when
# SINGULAR_CTX_MANIFEST=1 AND singular.config.json declares `contextManifest`.
# A string value is the original fixture/legacy path and delegates to the old
# selector. An object with format singular-brain.manifest.v1 delegates to the
# strict shared Python consumer; explicit `select` paths replace trigger matching.
#
# `contextManifest` is an OPTIONAL ADDITIVE field over SINGULAR_JSON_CONFIG_FILE.
# Every relative descriptor or legacy path resolves against that config file's
# directory. No path is inferred from the manifest location or current directory.
#
# Pure, read-only, deterministic. Flag-off/absent and legacy errors stay fail-soft.
# A present object is configured intent, so malformed or unsafe brain input emits
# an actionable diagnostic and exits nonzero. The functions never mutate sources.

# Internal: apply the feature gate and classify contextManifest as the legacy
# string contract or the strict singular-brain descriptor object. Missing and
# malformed legacy configuration stays fail-soft; a present object is returned
# to the caller and validated by brain_documents.py without fallback.
_singular_ctx_rehydrate_authored_config_value() {
  [[ "${SINGULAR_CTX_MANIFEST:-0}" == "1" ]] || return 1

  local cfg="${SINGULAR_JSON_CONFIG_FILE:-}"
  [[ -n "$cfg" && -f "$cfg" && -r "$cfg" ]] || return 1

  # The field's absence is the OFF default. Invalid outer config and unsupported
  # scalar values preserve the pre-object compatibility path's empty result.
  python3 - "$cfg" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        value = json.load(fh).get("contextManifest")
except (OSError, ValueError, AttributeError):
    sys.exit(1)
if isinstance(value, str) and value:
    print("legacy\t" + value)
elif isinstance(value, dict):
    print("brain")
else:
    sys.exit(1)
PY
}

# Return success only for an enabled, explicitly configured brain descriptor.
# This is a classification check, not validation: the driver uses it solely to
# keep a refused-resume attempt on the rehydrate path when every durable source
# has been quarantined. The normal manifest/render calls below remain the single
# strict validation authority and propagate any configured descriptor error.
singular_ctx_rehydrate_authored_brain_configured() {
  local value
  value="$(_singular_ctx_rehydrate_authored_config_value)" || return 1
  [[ "$value" == "brain" ]]
}

_singular_ctx_rehydrate_authored_legacy_path() {
  local cfg="$1" rel="$2"

  local resolved
  case "$rel" in
    /*) resolved="$rel" ;;
    *)  resolved="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)/$rel" ;;
  esac

  [[ -f "$resolved" && -r "$resolved" ]] || return 1
  printf '%s\n' "$resolved"
}

# singular_ctx_rehydrate_authored_config_render [trigger ...]
singular_ctx_rehydrate_authored_config_render() {
  local cfg="${SINGULAR_JSON_CONFIG_FILE:-}" value
  value="$(_singular_ctx_rehydrate_authored_config_value)" || return 0
  if [[ "$value" == $'legacy\t'* ]]; then
    local resolved
    resolved="$(_singular_ctx_rehydrate_authored_legacy_path "$cfg" "${value#*$'\t'}")" || return 0
    singular_ctx_rehydrate_authored_render "$resolved" "$@"
    return
  fi
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/brain_documents.py" \
    render --config "$cfg" --max-chars "${SINGULAR_CONTEXT_SECTION_MAX_CHARS:-4000}"
}

# singular_ctx_rehydrate_authored_config_manifest [trigger ...]
singular_ctx_rehydrate_authored_config_manifest() {
  local cfg="${SINGULAR_JSON_CONFIG_FILE:-}" value
  value="$(_singular_ctx_rehydrate_authored_config_value)" || return 0
  if [[ "$value" == $'legacy\t'* ]]; then
    local resolved
    resolved="$(_singular_ctx_rehydrate_authored_legacy_path "$cfg" "${value#*$'\t'}")" || return 0
    singular_ctx_rehydrate_authored_manifest "$resolved" "$@"
    return
  fi
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/brain_documents.py" \
    authored-manifest --config "$cfg"
}
