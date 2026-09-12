#!/usr/bin/env bash
# Covers the config loader (singular.config.json -> SINGULAR_* env), the area->path map,
# and the security guard that rejects malicious config env keys.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
tmp_resolved="$(cd "$tmp" && pwd -P)"
canary="$tmp/CANARY"
cat > "$tmp/singular.config.json" <<EOF
{
  "targetBranch": "agent/cfg-target",
  "gateCommand": "npm test && npm run build",
  "areas": { "mcp": "axon-402-mcp/", "cli": ["axon-cli/", "axon-cli-operator/"] },
  "proofLayers": ["storage_proof"],
  "provisionFiles": [{"source": ".env.local", "target": ".env.local", "required": true}],
  "envAllowlist": ["PUBLIC_*", "EXACT_NAME"],
  "capabilityProfiles": {"planner-core": {"required": ["filesystem"], "optional": ["mcp:browser"]}},
  "roleProfiles": {"planner": "planner-core"},
  "evidence": {"maxComposedBytes": 262144, "retrievalBudgetBytes": 131072},
  "bootstrap": {"commands": [{"command": "npm ci", "lockfiles": ["package-lock.json"]}]},
  "resources": {"diskReserveBytes": 4096, "estimatedWorktreeBytes": 8192, "maxConcurrent": 4},
  "controlState": {"commitIntervalSeconds": 300},
  "legacyCompatibility": {"unboundWaivers": false},
  "env": {
    "SINGULAR_GOOD_KEY": "ok",
    "SINGULAR_MAX_CONCURRENT": "9",
    "SINGULAR_BASH_BIN": "/committed/config/must-not-select-bash",
    "BAD KEY; touch $canary; X": "1"
  }
}
EOF
git -C "$tmp" init -q

out="$(SINGULAR_ROOT="$tmp" bash -c '
  source "'"$SCRIPT_DIR"'/lib.sh" 2>/dev/null
  echo "TB=$SINGULAR_TARGET_BRANCH"
  echo "GATE=$SINGULAR_DEFAULT_GATE_CMD"
  echo "PL=$SINGULAR_PROOF_LAYERS"
  echo "PF=$SINGULAR_PROVISION_FILES_JSON"
  echo "EA=$SINGULAR_ENV_ALLOWLIST_JSON"
  echo "CP=$SINGULAR_CAPABILITY_PROFILES_JSON"
  echo "RP=$SINGULAR_ROLE_PROFILES_JSON"
  echo "EV=$SINGULAR_EVIDENCE_CONFIG_JSON"
  echo "BS=$SINGULAR_BOOTSTRAP_JSON"
  echo "DR=$SINGULAR_DISK_RESERVE_BYTES"
  echo "WE=$SINGULAR_ESTIMATED_WORKTREE_BYTES"
  echo "MC=$SINGULAR_MAX_CONCURRENT"
  echo "CI=$SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC"
  echo "UW=$SINGULAR_LEGACY_UNBOUND_WAIVERS"
  echo "GOOD=${SINGULAR_GOOD_KEY:-<unset>}"
  echo "BASHBIN=${SINGULAR_BASH_BIN:-<unset>}"
  echo "MCP=$(singular_l1_area_write_scopes mcp)"
  echo "CLI=$(singular_l1_area_write_scopes cli | tr "\n" " ")"
  echo "FOO=$(singular_l1_area_write_scopes foo)"
')"

assert_contains "$out" "TB=agent/cfg-target" "targetBranch -> SINGULAR_TARGET_BRANCH"
assert_contains "$out" "GATE=npm test && npm run build" "gateCommand -> SINGULAR_DEFAULT_GATE_CMD"
assert_contains "$out" "PL=storage_proof" "proofLayers -> SINGULAR_PROOF_LAYERS"
assert_contains "$out" 'PF=[{"source":".env.local","target":".env.local","required":true}]' "provisionFiles -> SINGULAR_PROVISION_FILES_JSON"
assert_contains "$out" 'EA=["PUBLIC_*","EXACT_NAME"]' "envAllowlist -> SINGULAR_ENV_ALLOWLIST_JSON"
assert_contains "$out" 'CP={"planner-core":{"required":["filesystem"],"optional":["mcp:browser"]}}' "capabilityProfiles -> SINGULAR_CAPABILITY_PROFILES_JSON"
assert_contains "$out" 'RP={"planner":"planner-core"}' "roleProfiles -> SINGULAR_ROLE_PROFILES_JSON"
assert_contains "$out" 'EV={"maxComposedBytes":262144,"retrievalBudgetBytes":131072}' "evidence -> SINGULAR_EVIDENCE_CONFIG_JSON"
assert_contains "$out" 'BS={"commands":[{"command":"npm ci","lockfiles":["package-lock.json"]}]}' "bootstrap -> SINGULAR_BOOTSTRAP_JSON"
assert_contains "$out" "DR=4096" "resources.diskReserveBytes mapping"
assert_contains "$out" "WE=8192" "resources.estimatedWorktreeBytes mapping"
assert_contains "$out" "MC=9" "explicit env overrides resources.maxConcurrent"
assert_contains "$out" "CI=300" "controlState.commitIntervalSeconds mapping"
assert_contains "$out" "UW=0" "legacyCompatibility.unboundWaivers mapping"
assert_contains "$out" "GOOD=ok" "valid env key is exported"
assert_contains "$out" "BASHBIN=<unset>" "bootstrap-only bash bin is ignored in repo config"
assert_contains "$out" "MCP=axon-402-mcp/" "area map: mcp"
assert_contains "$out" "CLI=axon-cli/ axon-cli-operator/" "area map: cli (multi-path)"
assert_contains "$out" "FOO=internal/foo/" "unmapped area falls back to prefix"

# SECURITY: a malicious env KEY must be rejected, not eval'd.
[[ ! -f "$canary" ]] || fail "SECURITY: malicious config env key executed code (canary created)"

# A real bootstrap environment value survives repo config loading unchanged.
out="$(SINGULAR_ROOT="$tmp" SINGULAR_BASH_BIN="$BASH" bash -c '
  source "'"$SCRIPT_DIR"'/lib.sh" 2>/dev/null
  echo "$SINGULAR_BASH_BIN"
')"
[[ "$out" == "$BASH" ]] || fail "bootstrap SINGULAR_BASH_BIN was not preserved"

# An explicitly selected JSON file is authority, not an optional hint. Missing
# selected input must stop startup before defaults or shell layers can fabricate
# an effective runtime; an absent default remains optional.
set +e
missing_out="$(SINGULAR_ROOT="$tmp" SINGULAR_JSON_CONFIG_FILE=missing.json \
  /opt/homebrew/bin/bash -c 'source "$1/lib.sh"' _ "$SCRIPT_DIR" 2>&1)"
missing_rc=$?
set -e
[[ "$missing_rc" -eq 2 ]] || fail "missing explicit JSON exited $missing_rc, expected 2"
assert_contains "$missing_out" "selected JSON configuration is missing:" \
  "missing explicit JSON diagnostic"

absent="$tmp/absent-default"
mkdir -p "$absent"
absent_resolved="$(cd "$absent" && pwd -P)"
SINGULAR_ROOT="$absent" /opt/homebrew/bin/bash -c \
  'source "$1/lib.sh"; singular_effective_configuration_json' _ "$SCRIPT_DIR" \
  >"$tmp/absent.json"
python3 - "$tmp/absent.json" <<'PY'
import json, sys
view = json.load(open(sys.argv[1], encoding="utf-8"))
assert view["configuration"]["status"] == "absent", view
assert view["configuration"]["source"] == "default", view
PY

# Default provenance is a bound handoff, not a basename heuristic. It survives
# same-root re-entry even when the path is equivalently spelled, while a fresh
# explicit selection of that same default-named path remains strict.
reentry="$(SINGULAR_ROOT="$tmp" bash -c '
  source "$1/lib.sh"
  SINGULAR_JSON_CONFIG_FILE="$SINGULAR_ROOT/./singular.config.json"
  source "$1/lib.sh"
  printf "%s|%s\n" "$SINGULAR_JSON_CONFIG_SOURCE" "$SINGULAR_JSON_CONFIG_FILE"
' _ "$SCRIPT_DIR")"
[[ "$reentry" == "default|$tmp_resolved/singular.config.json" ]] \
  || fail "present default provenance did not survive normalized re-entry: $reentry"

absent_reentry="$(SINGULAR_ROOT="$absent" bash -c '
  source "$1/lib.sh"
  source "$1/lib.sh"
  printf "%s|%s\n" "$SINGULAR_JSON_CONFIG_SOURCE" "$SINGULAR_JSON_CONFIG_FILE"
' _ "$SCRIPT_DIR")"
[[ "$absent_reentry" == "default|$absent_resolved/singular.config.json" ]] \
  || fail "absent default provenance did not survive re-entry: $absent_reentry"

set +e
explicit_default_out="$(SINGULAR_ROOT="$absent" \
  SINGULAR_JSON_CONFIG_FILE="$absent/singular.config.json" \
  bash -c 'source "$1/lib.sh"' _ "$SCRIPT_DIR" 2>&1)"
explicit_default_rc=$?
set -e
[[ "$explicit_default_rc" -eq 2 ]] \
  || fail "explicit default-named missing JSON exited $explicit_default_rc, expected 2"
assert_contains "$explicit_default_out" "selected JSON configuration is missing:" \
  "explicit default-named missing JSON diagnostic"

# A complete normalized binding is recognized; SOURCE=default alone never
# exempts an arbitrary selection from strict missing-input handling.
normalized="$(SINGULAR_ROOT="$tmp" SINGULAR_JSON_CONFIG_FILE=./singular.config.json \
  SINGULAR_JSON_CONFIG_SOURCE=default SINGULAR_JSON_CONFIG_DEFAULT_ROOT=. \
  SINGULAR_JSON_CONFIG_DEFAULT_FILE=./singular.config.json bash -c '
    source "$1/lib.sh"
    printf "%s|%s\n" "$SINGULAR_JSON_CONFIG_SOURCE" "$SINGULAR_JSON_CONFIG_FILE"
  ' _ "$SCRIPT_DIR")"
[[ "$normalized" == "default|$tmp_resolved/singular.config.json" ]] \
  || fail "normalized default binding was not recognized: $normalized"

set +e
arbitrary_out="$(SINGULAR_ROOT="$absent" SINGULAR_JSON_CONFIG_FILE=other.json \
  SINGULAR_JSON_CONFIG_SOURCE=default bash -c 'source "$1/lib.sh"' \
  _ "$SCRIPT_DIR" 2>&1)"
arbitrary_rc=$?
set -e
[[ "$arbitrary_rc" -eq 2 ]] \
  || fail "unbound SOURCE=default bypassed strict selection (rc=$arbitrary_rc)"
assert_contains "$arbitrary_out" "$absent_resolved/other.json" \
  "unbound SOURCE=default selected path diagnostic"

# The engine handoff spans two generations of child processes. Shell/local
# layers must be re-applied at the consumer root on every level.
mkdir -p "$absent/shell-state"
printf '%s\n' \
  "export SINGULAR_STATE_DIR='shell-state' SINGULAR_CODEX_MODEL='shell-model'" \
  >"$absent/singular.config.sh"
printf '%s\n' "export SINGULAR_TASKS_DIR='local-tasks'" \
  >"$absent/shell-state/config.local.sh"
cat >"$tmp/provenance-handoff.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
level="$1"
lib="$2"
source "$lib"
printf '%s|%s|%s|%s|%s\n' "$level" "$SINGULAR_JSON_CONFIG_SOURCE" \
  "$SINGULAR_JSON_CONFIG_FILE" "$SINGULAR_STATE_DIR" "$SINGULAR_TASKS_DIR"
if [[ "$level" -lt 3 ]]; then
  export SINGULAR_ROOT SINGULAR_JSON_CONFIG_FILE SINGULAR_JSON_CONFIG_SOURCE \
    SINGULAR_JSON_CONFIG_DEFAULT_ROOT SINGULAR_JSON_CONFIG_DEFAULT_FILE \
    PROVENANCE_BASH
  "$PROVENANCE_BASH" "$0" "$((level + 1))" "$lib"
fi
SH
chmod +x "$tmp/provenance-handoff.sh"
handoff="$(SINGULAR_ROOT="$absent" PROVENANCE_BASH="${BASH:-/bin/bash}" \
  "${BASH:-/bin/bash}" "$tmp/provenance-handoff.sh" 1 "$SCRIPT_DIR/lib.sh")"
for level in 1 2 3; do
  assert_contains "$handoff" \
    "$level|default|$absent_resolved/singular.config.json|$absent/shell-state|$absent/local-tasks" \
    "default provenance child level $level"
done
present_handoff="$(SINGULAR_ROOT="$tmp" PROVENANCE_BASH="${BASH:-/bin/bash}" \
  "${BASH:-/bin/bash}" "$tmp/provenance-handoff.sh" 1 "$SCRIPT_DIR/lib.sh")"
for level in 1 2 3; do
  assert_contains "$present_handoff" \
    "$level|default|$tmp_resolved/singular.config.json|" \
    "present default provenance child level $level"
done

# Re-entry with a genuinely new selector stays a selector. Stale binding from
# another root also cannot turn a newly default-named missing path into optional.
printf '%s\n' '{"targetBranch":"other"}' >"$tmp/other.json"
new_selector="$(SINGULAR_ROOT="$tmp" bash -c '
  source "$1/lib.sh"
  SINGULAR_JSON_CONFIG_FILE=other.json
  source "$1/lib.sh"
  printf "%s|%s|%s\n" "$SINGULAR_JSON_CONFIG_SOURCE" \
    "$SINGULAR_JSON_CONFIG_FILE" "$SINGULAR_TARGET_BRANCH"
' _ "$SCRIPT_DIR")"
[[ "$new_selector" == "selector|$tmp_resolved/other.json|other" ]] \
  || fail "new selector inherited default provenance: $new_selector"

stale="$tmp/stale-root"
mkdir -p "$stale"
stale_resolved="$(cd "$stale" && pwd -P)"
set +e
stale_out="$(SINGULAR_ROOT="$tmp" STALE_ROOT="$stale" bash -c '
  source "$1/lib.sh"
  SINGULAR_ROOT="$STALE_ROOT"
  SINGULAR_JSON_CONFIG_FILE="$STALE_ROOT/singular.config.json"
  source "$1/lib.sh"
' _ "$SCRIPT_DIR" 2>&1)"
stale_rc=$?
set -e
[[ "$stale_rc" -eq 2 ]] || fail "stale provenance exited $stale_rc, expected 2"
assert_contains "$stale_out" "$stale_resolved/singular.config.json" \
  "stale provenance/new-root strict diagnostic"

# Keep lib.sh's native errexit behavior observable by callers: ordinary false
# and explicit exit in either trusted shell layer are startup failures.
for kind in false exit; do
  bad="$tmp/bad-$kind.sh"
  if [[ "$kind" == false ]]; then
    printf '%s\n' false >"$bad"
    expected=1
  else
    printf '%s\n' 'exit 7' >"$bad"
    expected=7
  fi
  set +e
  SINGULAR_ROOT="$absent" SINGULAR_CONFIG_FILE="$bad" \
    /opt/homebrew/bin/bash -c 'source "$1/lib.sh"' _ "$SCRIPT_DIR" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq "$expected" ]] || fail "shell $kind exited $rc, expected $expected"
done

rm -rf "$tmp"
echo "config-loader tests passed"
