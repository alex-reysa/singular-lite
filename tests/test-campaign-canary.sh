#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$tmp" init -q repo
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
printf 'seed\n' >"$repo/seed.txt"
git -C "$repo" add seed.txt
git -C "$repo" commit -qm seed
git -C "$repo" branch -M canary-target
target_before="$(git -C "$repo" rev-parse canary-target)"
printf '{"schemaVersion":"v2","targetBranch":"canary-target","gateCommand":"true","runner":"missing-runner.sh","bootstrap":{"required":false,"commands":[]}}\n' >"$repo/singular.config.json"

# A fixture lifecycle must not hide a broken production adapter.  The default
# path checks that adapter and stops before lifecycle execution; --fixture
# explicitly replaces only that contract check, never the lifecycle itself.
if production_out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/engine/campaign-canary.sh" --json)"; then
  echo "campaign canary accepted a missing production runner" >&2
  exit 1
fi
python3 - "$production_out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["failures"] == ["production-runner-contract"], data
assert data["providerInvoked"] is False
assert data["providerUnchecked"] is True
assert data["providerUncheckedWaived"] is False
assert data["lifecycle"]["covered"] is False
PY

# A conforming deterministic stub exercises the same bounded live-readonly
# invocation contract without any network access.
live_runner="$tmp/live-probe-runner.sh"
provider_calls="$tmp/provider-calls.log"
cat >"$live_runner" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--describe-contract" ]]; then
  printf '%s\n' '{"schema":"singular.runner-contract.v1","version":1,"provider":"codex","arguments":["--worktree","--prompt-file","--level","--run-id","--output-last-message","--role","--capability-profile","--result-file","--describe-contract"],"structuredResult":"singular.orchestration.runner-result.v0","structuredProviderError":"singular.orchestration.provider-error.v0"}'
  exit 0
fi
run_id=""; role=""; capability=""; result=""; output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) run_id="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    --capability-profile) capability="$2"; shift 2 ;;
    --result-file) result="$2"; shift 2 ;;
    --output-last-message) output="$2"; shift 2 ;;
    --worktree|--prompt-file|--level) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$run_id" && -n "$result" && -n "$output" && "$role" == "supervisor" ]]
printf '%s|%s\n' "$role" "$capability" >>"${CANARY_PROVIDER_CALLS:?}"
printf '%s\n' '{"ok":true}' >"$output"
python3 - "$result" "$run_id" "$role" "$capability" "$output" <<'PY'
import json, sys
path, run_id, role, capability, output = sys.argv[1:]
json.dump({"schema":"singular.orchestration.runner-result.v0","contractVersion":1,"provider":"codex","runId":run_id,"role":role,"capabilityProfile":capability,"exitCode":0,"outcome":"succeeded","failureClass":"none","providerErrorRef":None,"outputRef":output,"recordedAt":"2026-08-30T00:00:00Z"}, open(path, "w", encoding="utf-8"))
PY
SH
chmod +x "$live_runner"

# Reproduce the production leak: the outer canary must honor this consumer
# provider and probe policy, while its cloned deterministic lifecycle must not
# inherit any of the consumer's external config/task/state/worktree/gate paths.
consumer="$tmp/hostile-consumer"
consumer_tasks="$consumer/tasks"
consumer_state="$consumer/state"
consumer_worktrees="$consumer/worktrees"
consumer_config_reads="$consumer/config-reads.log"
hostile_gate="$consumer/hostile-gate.sh"
bash_pin_calls="$consumer/bash-pin-calls.log"
bash_fallbacks="$consumer/bash-fallbacks.log"
lifecycle_path="$consumer/lifecycle-path"
pinned_bash="$consumer/pinned-bash"
real_bash="$(command -v bash)"
mkdir -p "$consumer_tasks" "$consumer_state" "$consumer_worktrees" "$lifecycle_path"
printf 'host task sentinel\n' >"$consumer_tasks/HOST-TASK.md"
printf 'host state sentinel\n' >"$consumer_state/sentinel"
printf 'host worktree sentinel\n' >"$consumer_worktrees/sentinel"
cat >"$pinned_bash" <<'SH'
#!/bin/sh
printf 'pin|%s|bootstrapped=%s\n' "$*" "${SINGULAR_BASH_BOOTSTRAPPED:-unset}" >>"${CANARY_BASH_PIN_CALLS:?}"
exec "${CANARY_REAL_BASH:?}" "$@"
SH
chmod +x "$pinned_bash"
cat >"$lifecycle_path/bash" <<'SH'
#!/bin/sh
if [ -n "${SINGULAR_BASH_BIN:-}" ] && [ -x "$SINGULAR_BASH_BIN" ]; then
  exec "$SINGULAR_BASH_BIN" "$@"
fi
printf 'unpinned|%s\n' "$*" >>"${CANARY_BASH_FALLBACKS:?}"
echo "fixture lifecycle lost the configured Bash selection" >&2
exit 91
SH
chmod +x "$lifecycle_path/bash"
cat >"$hostile_gate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
touch "${CANARY_HOST_MUTATION:?}"
exit 97
SH
chmod +x "$hostile_gate"
cat >"$consumer/singular.config.sh" <<'SH'
printf 'shell|%s\n' "$SINGULAR_ROOT" >>"${CANARY_CONFIG_READS:?}"
SH
cat >"$consumer/config.local.sh" <<'SH'
printf 'local|%s\n' "$SINGULAR_ROOT" >>"${CANARY_CONFIG_READS:?}"
SH
python3 - "$consumer/singular.config.json" "$live_runner" "$hostile_gate" \
  "$consumer_tasks" "$consumer_state" "$consumer_worktrees" \
  "$consumer/singular.config.sh" "$consumer/config.local.sh" <<'PY'
import json, sys
path, runner, gate, tasks, state, worktrees, shell_config, local_config = sys.argv[1:]
json.dump({
    "schemaVersion": "v2",
    "targetBranch": "canary-target",
    "gateCommand": gate,
    "runner": runner,
    "bootstrap": {"required": False, "commands": []},
    "env": {
        "SINGULAR_TASKS_DIR": tasks,
        "SINGULAR_STATE_DIR": state,
        "SINGULAR_WORKTREES_DIR": worktrees,
        "SINGULAR_CONFIG_FILE": shell_config,
        "SINGULAR_LOCAL_CONFIG_FILE": local_config,
    },
}, open(path, "w", encoding="utf-8"))
PY
if ! live_out="$(
  cd "$repo" && env \
    CANARY_PROVIDER_CALLS="$provider_calls" \
    CANARY_CONFIG_READS="$consumer_config_reads" \
    CANARY_HOST_MUTATION="$consumer/host-mutated" \
    CANARY_BASH_PIN_CALLS="$bash_pin_calls" \
    CANARY_BASH_FALLBACKS="$bash_fallbacks" \
    CANARY_REAL_BASH="$real_bash" \
    PATH="$lifecycle_path:$PATH" \
    SINGULAR_BASH_BIN="$pinned_bash" \
    SINGULAR_JSON_CONFIG_FILE="$consumer/singular.config.json" \
    SINGULAR_CAMPAIGN_PROBE_CAPABILITY_PROFILE="consumer-production-policy" \
    SINGULAR_ENGINE_HOME="$ROOT" \
    bash "$ROOT/engine/campaign-canary.sh" --json
)"; then
  echo "campaign canary leaked hostile consumer environment into fixture lifecycle" >&2
  printf '%s\n' "$live_out" >&2
  exit 1
fi
python3 - "$live_out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["ok"] is True, data
assert data["providerInvoked"] is True
assert data["providerUnchecked"] is False
assert data["providerUncheckedWaived"] is False
assert data["providerProbe"] == {"invoked": True, "state": "passed"}
assert "production-runner-live-readonly-probe" in data["checks"]
PY
[[ "$(cat "$provider_calls")" == "supervisor|consumer-production-policy" ]] || {
  echo "fixture lifecycle invoked the consumer provider or lost production probe policy" >&2
  cat "$provider_calls" >&2
  exit 1
}
[[ ! -e "$consumer/host-mutated" ]] || {
  echo "fixture lifecycle invoked the hostile consumer gate" >&2
  exit 1
}
[[ "$(find "$consumer_tasks" -mindepth 1 -maxdepth 1 -print | sort)" == "$consumer_tasks/HOST-TASK.md" ]]
[[ "$(find "$consumer_state" -mindepth 1 -maxdepth 1 -print | sort)" == "$consumer_state/sentinel" ]]
[[ "$(find "$consumer_worktrees" -mindepth 1 -maxdepth 1 -print | sort)" == "$consumer_worktrees/sentinel" ]]
if grep -q '/lifecycle-repo$' "$consumer_config_reads"; then
  echo "fixture lifecycle reread consumer external config" >&2
  cat "$consumer_config_reads" >&2
  exit 1
fi
[[ ! -s "$bash_fallbacks" ]] || {
  echo "fixture lifecycle fell back from the configured Bash selection" >&2
  cat "$bash_fallbacks" >&2
  exit 1
}
for expected_bash_call in \
  'l1-drive.sh TASK-9999' \
  'fixture-v1-runner.sh --role implementer' \
  'fixture-v1-runner.sh --role auditor' \
  'pin|-c true|bootstrapped=unset' \
  'import-packet.sh ' \
  'integrate.sh --task TASK-9999'; do
  grep -F -- "$expected_bash_call" "$bash_pin_calls" >/dev/null || {
    echo "configured Bash did not cover fixture lifecycle stage: $expected_bash_call" >&2
    cat "$bash_pin_calls" >&2
    exit 1
  }
done
if grep -q 'bootstrapped=1' "$bash_pin_calls"; then
  echo "fixture lifecycle inherited SINGULAR_BASH_BOOTSTRAPPED" >&2
  cat "$bash_pin_calls" >&2
  exit 1
fi

out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/engine/campaign-canary.sh" --fixture --json)"
python3 - "$out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["schema"] == "singular.orchestration.campaign-canary.v1"
assert data["fixture"] is True
assert data["ok"] is True, data
assert data["providerInvoked"] is False
assert data["providerUnchecked"] is True
assert data["providerUncheckedWaived"] is True
expected = {
    "bash>=4",
    "fixture-runner-contract",
    "disposable-worktree-bootstrap",
    "fixture-runner-live-readonly-probe",
    "fixture-lifecycle-worker-gate-audit-evidence-import-integration",
}
assert expected <= set(data["checks"])
assert data["lifecycle"] == {
    "mode": "isolated-fixture-v1-runner",
    "providerInvoked": False,
    "providerUnchecked": True,
    "providerUncheckedWaived": True,
    "targetMutated": False,
    "covered": True,
    "auditVerification": "not-rerun-evidence-verified",
    "stages": ["worker", "gate", "accepted-audit", "evidence", "packet-import", "integration"],
}
PY
[[ "$(git -C "$repo" rev-parse canary-target)" == "$target_before" ]] || {
  echo "fixture lifecycle mutated the campaign target" >&2
  exit 1
}
[[ "$(cat "$provider_calls")" == "supervisor|consumer-production-policy" ]] || {
  echo "fixture mode invoked the consumer provider" >&2
  cat "$provider_calls" >&2
  exit 1
}
echo "PASS campaign canary"
