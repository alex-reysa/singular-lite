#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-campaign-event-contract.sh requires bash >= 4" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN=/opt/homebrew/bin/bash
PYTHON_BIN=/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12
[[ -x "$BASH_BIN" ]] || { echo "missing pinned Bash: $BASH_BIN" >&2; exit 1; }
[[ -x "$PYTHON_BIN" ]] || { echo "missing pinned Python: $PYTHON_BIN" >&2; exit 1; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/singular-campaign-events.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
fixture="$scratch/repo"
state="$fixture/.singular-state"
manifest="$state/campaign/manifest.json"
events="$state/events.ndjson"
mkdir -p "$fixture/docs/orchestration/tasks" "$state/campaign"
git -C "$fixture" init -q
git -C "$fixture" config user.name campaign-event-test
git -C "$fixture" config user.email campaign-event@example.invalid
printf 'seed\n' >"$fixture/seed.txt"
git -C "$fixture" add seed.txt
git -C "$fixture" commit -qm seed

# This is structurally active campaign state but deliberately omits the frozen
# runtime snapshot. The real campaign verifier therefore reports drift with 3.
printf '%s\n' '{"schema":"singular.orchestration.campaign-manifest.v1","campaignId":"event-contract"}' \
  >"$manifest"
printf '%s\n' 'event-contract' >"$state/campaign/ACTIVE"
printf '%s\n' 'singular-campaign-enforced-v1' >"$state/CAMPAIGN_ENFORCED"

export PYTHONDONTWRITEBYTECODE=1
export SINGULAR_ROOT="$fixture"
export SINGULAR_STATE_DIR="$state"
export SINGULAR_ORCH_DIR="$fixture/docs/orchestration"
export SINGULAR_CONFIG_FILE="$fixture/missing.config.sh"
export SINGULAR_LOCAL_CONFIG_FILE="$state/missing.config.local.sh"
export SINGULAR_ENGINE_HOME="$ROOT"
export SINGULAR_CAMPAIGN_MANIFEST="$manifest"

cd "$fixture"
# shellcheck source=/dev/null
. "$ROOT/engine/lib.sh"

reset_events() {
  rm -f "$events"
  SINGULAR_EVENTS_FILE="$events"
}

assert_one_event() {
  local expected_type="$1" expected_data="$2" allow_raw="${3:-0}"
  "$PYTHON_BIN" - "$events" "$expected_type" "$expected_data" "$allow_raw" <<'PY'
import json
import sys

path, expected_type, expected_data, allow_raw = sys.argv[1:]
records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(records) == 1, records
event = records[0]
assert event["type"] == expected_type, event
assert event["data"] == json.loads(expected_data), event
if allow_raw != "1":
    assert "raw" not in event["data"], event
PY
}

reset_events
drift_entrypoint=$'drift "entry" \\ boundary'
drift_phase=$'post-check\nwith-tab\tand-backslash\\'
rc=0
singular_campaign_verify_or_refuse "$drift_entrypoint" "$drift_phase" \
  >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "drift refusal returned $rc, expected 2" >&2; exit 1; }
drift_expected="$($PYTHON_BIN - "$drift_entrypoint" "$drift_phase" "$manifest" <<'PY'
import json, sys
print(json.dumps({
    "entrypoint": sys.argv[1],
    "phase": sys.argv[2],
    "manifest": sys.argv[3],
    "verifyExitCode": 3,
}, separators=(",", ":")))
PY
)"
assert_one_event campaign.drift_detected "$drift_expected"

reset_events
binding_entrypoint=$'binding "entry" \\ boundary'
binding_phase=$'publication\ncheck\twith-backslash\\'
expected_binding=$'campaign:expected:"quoted"\\value\nline'
actual_binding=$'campaign:actual:"quoted"\\value\nline'
singular_campaign_binding() { printf '%s\n' "$actual_binding"; }
rc=0
_singular_campaign_binding_compare "$expected_binding" "$binding_entrypoint" \
  "$binding_phase" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "binding refusal returned $rc, expected 2" >&2; exit 1; }
binding_expected="$($PYTHON_BIN - "$binding_entrypoint" "$binding_phase" \
    "$expected_binding" "$actual_binding" <<'PY'
import json, sys
print(json.dumps({
    "entrypoint": sys.argv[1],
    "phase": sys.argv[2],
    "expectedBinding": sys.argv[3],
    "actualBinding": sys.argv[4],
}, separators=(",", ":")))
PY
)"
assert_one_event campaign.identity_mismatch "$binding_expected"

# Fail only producer-side `python3 - ...` invocations. The actual append path
# still uses the pinned interpreter and must receive the explicit `{}` fallback.
python_shim="$scratch/python-shim"
mkdir -p "$python_shim"
cat >"$python_shim/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${CAMPAIGN_EVENT_FORCE_GENERATION_FAILURE:-0}" == "1" \
    && "${1:-}" == "-" && "${2:-}" != "${CAMPAIGN_EVENT_JOURNAL:-}" ]]; then
  exit 91
fi
exec "${CAMPAIGN_EVENT_REAL_PYTHON:?}" "$@"
SH
chmod +x "$python_shim/python3"
export CAMPAIGN_EVENT_FORCE_GENERATION_FAILURE=1
export CAMPAIGN_EVENT_JOURNAL="$events"
export CAMPAIGN_EVENT_REAL_PYTHON="$PYTHON_BIN"
original_path="$PATH"
PATH="$python_shim:$PATH"

reset_events
rc=0
singular_campaign_verify_or_refuse fallback-drift fallback-phase \
  >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "fallback drift refusal returned $rc, expected 2" >&2; exit 1; }
assert_one_event campaign.drift_detected '{}'

reset_events
rc=0
_singular_campaign_binding_compare expected fallback-binding fallback-phase \
  >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "fallback binding refusal returned $rc, expected 2" >&2; exit 1; }
assert_one_event campaign.identity_mismatch '{}'

PATH="$original_path"
unset CAMPAIGN_EVENT_FORCE_GENERATION_FAILURE CAMPAIGN_EVENT_JOURNAL \
  CAMPAIGN_EVENT_REAL_PYTHON

# Journal failures remain best-effort and cannot change either refusal's exit 2.
failed_journal="$state/events-as-directory"
mkdir -p "$failed_journal"
SINGULAR_EVENTS_FILE="$failed_journal"
rc=0
singular_campaign_verify_or_refuse journal-failure drift-phase \
  >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "drift journal failure returned $rc, expected 2" >&2; exit 1; }
rc=0
_singular_campaign_binding_compare expected journal-failure binding-phase \
  >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "binding journal failure returned $rc, expected 2" >&2; exit 1; }

# The generic append contract intentionally preserves malformed input as raw.
reset_events
malformed=$'{"broken":"quoted"} trailing\\\nline'
singular_append_event generic.malformed "malformed fixture payload" "$malformed"
malformed_expected="$($PYTHON_BIN - "$malformed" <<'PY'
import json, sys
print(json.dumps({"raw": sys.argv[1]}, separators=(",", ":")))
PY
)"
assert_one_event generic.malformed "$malformed_expected" 1

echo "PASS: campaign event producers preserve structured payload contracts"
