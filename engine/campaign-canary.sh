#!/usr/bin/env bash
# Non-destructive campaign preflight. The configured production runner receives
# one bounded read-only live probe in a disposable checkout. Lifecycle coverage
# then uses a deterministic v1 fixture runner in a cloned repository, never
# against the campaign target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

fixture="no"; json="no"; provider_unchecked_waiver="no"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture) fixture="yes"; shift ;;
    --json) json="yes"; shift ;;
    --allow-provider-unchecked) provider_unchecked_waiver="yes"; shift ;;
    *) echo "campaign canary: unknown option: $1" >&2; exit 2 ;;
  esac
done

failures=(); checks=()
check() { local name="$1"; shift; if "$@"; then checks+=("$name"); else failures+=("$name"); fi; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-campaign-canary.XXXXXX")"
worktree="$tmp/bootstrap-worktree"
fixture_repo="$tmp/lifecycle-repo"
fixture_runner="$tmp/fixture-v1-runner.sh"
source_target_sha=""
validated_bash_bin=""
lifecycle_audit_verification="not-run"
provider_probe_state="not-run"
provider_probe_invoked="no"
cleanup() {
  git -C "$SINGULAR_ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

write_fixture_runner() {
  # This runner has no provider command. It writes the host-consumed packet
  # contracts so adapter parsing and lifecycle wiring are tested together.
  cat >"$fixture_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--describe-contract" ]]; then
  printf '%s\n' '{"schema":"singular.runner-contract.v1","version":1,"provider":"codex","arguments":["--worktree","--prompt-file","--level","--run-id","--output-last-message","--role","--capability-profile","--result-file","--describe-contract"],"structuredResult":"singular.orchestration.runner-result.v0","structuredProviderError":"singular.orchestration.provider-error.v0"}'
  exit 0
fi
out=""; run_id=""; worktree=""; role="${SINGULAR_RUNNER_ROLE:-}"
result_file="${SINGULAR_RUNNER_RESULT_FILE:-}"; capability="${SINGULAR_RUNNER_CAPABILITY_PROFILE:-fixture}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--worktree) worktree="${2:-}"; shift 2 ;;
    --run-id) run_id="${2:-}"; shift 2 ;;
    --output-last-message) out="${2:-}"; shift 2 ;;
    --role) role="${2:-}"; shift 2 ;;
    --capability-profile) capability="${2:-}"; shift 2 ;;
    --result-file) result_file="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" && -n "$run_id" && -n "$worktree" ]] || exit 2
if [[ "$role" == "supervisor" ]]; then
  printf '%s\n' '{"ok":true,"probe":"campaign-readonly"}' >"$out"
elif [[ "$role" == "implementer" ]]; then
  mkdir -p "$worktree/.singular-evidence"
  printf 'canary lifecycle implementation\n' >"$worktree/canary.txt"
  printf 'intentional red fixture (nonzero test observed)\n' >"$worktree/.singular-evidence/red.log"
  printf 'green fixture passed\n' >"$worktree/.singular-evidence/green.log"
  printf 'gate fixture passed\n' >"$worktree/.singular-evidence/regression.log"
  python3 - "$out" "$run_id" "$worktree" <<'PY'
import datetime, json, sys
out, run_id, worktree = sys.argv[1:]
json.dump({"schema":"singular.orchestration.state-packet.v0","packetId":run_id+"-packet","runId":run_id,"taskId":"TASK-9999","area":"canary","role":"l2-developer","status":"needs-review","baseRef":"canary-target","branch":"agent/canary/TASK-9999-fixture","headSha":"uncommitted","workspace":worktree,"ownedFiles":["canary.txt"],"changedFiles":["canary.txt"],"commands":[{"cmd":"true","exitCode":0,"logRef":".singular-evidence/regression.log"}],"tests":[{"name":"fixture red","phase":"red","status":"failed","logRef":".singular-evidence/red.log"},{"name":"fixture green","phase":"green","status":"passed","logRef":".singular-evidence/green.log"}],"evidence":[{"kind":"red","ref":".singular-evidence/red.log"},{"kind":"green","ref":".singular-evidence/green.log"}],"blockers":[],"nextAction":"await auditor verdict","createdAt":datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")}, open(out, "w"))
PY
else
  python3 - "$out" "$run_id" "${SINGULAR_STATE_DIR:?}/runs/$run_id/audit-verification.json" <<'PY'
import json, sys
out, run_id, host_report = sys.argv[1:]
host = json.load(open(host_report, encoding="utf-8"))["outcome"]
status = "passed" if host == "passed-with-acknowledged-baseline" else host
assert status in {"passed", "not-rerun-evidence-verified"}, status
json.dump({"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-9999","runId":run_id,"branch":"agent/canary/TASK-9999-fixture","verdict":"accepted","evidenceReviewed":["runs/%s/evidence-manifest.json" % run_id, "runs/%s/audit-verification.json" % run_id],"verificationResults":[{"status":status,"command":"true","exitCode":0,"evidenceRefs":["runs/%s/audit-verification.json" % run_id],"rationale":"fixture verdict is bound to the exact host verification classification"}],"commandsRun":["true"],"findings":[],"requiredFixes":[],"rationale":"deterministic fixture acceptance"}, open(out, "w"))
PY
fi
if [[ -n "$result_file" ]]; then
  python3 - "$result_file" "$run_id" "$role" "$capability" "$out" <<'PY'
import datetime, json, sys
path, run_id, role, capability, output = sys.argv[1:]
json.dump({"schema":"singular.orchestration.runner-result.v0","contractVersion":1,"provider":"codex","runId":run_id,"role":role,"capabilityProfile":capability,"exitCode":0,"outcome":"succeeded","failureClass":"none","providerErrorRef":None,"outputRef":output,"recordedAt":datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")}, open(path,"w"))
PY
fi
EOF
  chmod +x "$fixture_runner"
}

check_bash() {
  local bash_bin; bash_bin="$(singular_bash_bin)"
  [[ "$bash_bin" == /* && -x "$bash_bin" ]] || return 1
  "$bash_bin" -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]' || return 1
  validated_bash_bin="$bash_bin"
}
check_target_branch() {
  source_target_sha="$(git -C "$SINGULAR_ROOT" rev-parse --verify "$SINGULAR_TARGET_BRANCH" 2>/dev/null)"
  [[ -n "$source_target_sha" ]]
}
check_runner_contract() {
  local runner="$1"
  [[ -n "$runner" && -x "$runner" ]] || return 1
  "$runner" --describe-contract >"$tmp/runner-contract.json"
  python3 - "$tmp/runner-contract.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
required = {"--worktree", "--prompt-file", "--level", "--run-id", "--output-last-message", "--role", "--capability-profile", "--result-file", "--describe-contract"}
assert data.get("schema") == "singular.runner-contract.v1" and data.get("version") == 1
assert required <= set(data.get("arguments") or [])
assert data.get("structuredResult") == "singular.orchestration.runner-result.v0"
assert data.get("structuredProviderError") == "singular.orchestration.provider-error.v0"
PY
}
check_bootstrap_worktree() {
  local head; head="$(git -C "$SINGULAR_ROOT" rev-parse --verify HEAD)"
  git -C "$SINGULAR_ROOT" worktree add --detach -q "$worktree" "$head"
  SINGULAR_ROOT="$worktree" SINGULAR_STATE_DIR="$worktree/.singular-state" SINGULAR_PREWARM_CMD="" \
    "$SCRIPT_DIR/bootstrap-worktree.sh" --worktree "$worktree" --dry-run >"$tmp/bootstrap.log" 2>&1
}
check_live_runner_probe() {
  local runner="$1" run_id="CAMPAIGN-PROBE-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local prompt="$tmp/live-provider-probe.md" output="$tmp/live-provider-output.json"
  local result="$tmp/live-provider-runner-result.json" log="$tmp/live-provider.log"
  local before_head before_status after_head after_status probe_pid probe_rc=0 timed_out="no"
  local timeout_sec="${SINGULAR_CAMPAIGN_PROBE_TIMEOUT_SEC:-120}"
  [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || timeout_sec=120
  [[ "$timeout_sec" -le 600 ]] || timeout_sec=600
  [[ -x "$runner" && -d "$worktree" ]] || return 1
  cat >"$prompt" <<'EOF'
This is a read-only orchestration capability probe in a disposable checkout.
Do not modify files, run mutating commands, or inspect secrets. Reply briefly
with a JSON object containing only {"ok":true}.
EOF
  before_head="$(git -C "$worktree" rev-parse HEAD)"
  before_status="$(git -C "$worktree" status --porcelain=v1 --untracked-files=all)"
  rm -f "$output" "$result"
  singular_runner_contract_prepare "$runner" supervisor \
    "${SINGULAR_CAMPAIGN_PROBE_CAPABILITY_PROFILE:-supervisor-core}" "$result"
  [[ ${#SINGULAR_RUNNER_CONTRACT_ARGS[@]} -gt 0 ]] || return 1
  provider_probe_invoked="yes"
  (
    export SINGULAR_ROOT="$worktree"
    export SINGULAR_STATE_DIR="$tmp/live-provider-state"
    export SINGULAR_RUNNER_ROLE=supervisor
    export SINGULAR_RUNNER_CAPABILITY_PROFILE="${SINGULAR_CAMPAIGN_PROBE_CAPABILITY_PROFILE:-supervisor-core}"
    export SINGULAR_RUNNER_RESULT_FILE="$result"
    export SINGULAR_RUNNER_RUN_ID="$run_id"
    # The probe's outer bound must contain the whole provider tree even when
    # process enumeration is denied. Force this disposable probe to be a
    # session leader; it does not change the campaign's pinned runtime setting.
    export SINGULAR_SESSION_SPAWN=1
    singular_setsid_exec "$runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
      --level readonly --worktree "$worktree" --run-id "$run_id" \
      --prompt-file "$prompt" --output-last-message "$output"
  ) >"$log" 2>&1 &
  probe_pid=$!
  probe_deadline=$((SECONDS + timeout_sec))
  while kill -0 "$probe_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$probe_deadline" ]]; then
      timed_out="yes"
      singular_kill_tree "$probe_pid" "$(singular_kill_grace_sec)" session 2>/dev/null || true
      wait "$probe_pid" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  if [[ "$timed_out" != "yes" ]]; then
    wait "$probe_pid" || probe_rc=$?
  else
    probe_rc=124
  fi
  after_head="$(git -C "$worktree" rev-parse HEAD)"
  after_status="$(git -C "$worktree" status --porcelain=v1 --untracked-files=all)"
  [[ "$probe_rc" -eq 0 && "$after_head" == "$before_head" && "$after_status" == "$before_status" \
      && -s "$output" && -f "$result" ]] || return 1
  python3 - "$result" "$run_id" "$output" \
    "${SINGULAR_CAMPAIGN_PROBE_CAPABILITY_PROFILE:-supervisor-core}" <<'PY'
import json, os, sys
result_path, run_id, output_path, capability = sys.argv[1:]
try:
    data = json.load(open(result_path, encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
required = {
    "schema", "contractVersion", "provider", "runId", "role",
    "capabilityProfile", "exitCode", "outcome", "failureClass",
    "providerErrorRef", "outputRef", "recordedAt",
}
allowed = required | {"usage", "providerEnvelopeRef", "providerEnvelopeSha256"}
assert required <= set(data) <= allowed
assert data["schema"] == "singular.orchestration.runner-result.v0"
assert data["contractVersion"] == 1 and data["runId"] == run_id
assert data["role"] == "supervisor" and data["capabilityProfile"] == capability
assert data["provider"] in {"codex", "claude", "gemini", "opencode", "cursor", "openrouter", "grok"}
assert isinstance(data["exitCode"], int) and not isinstance(data["exitCode"], bool)
assert data["exitCode"] == 0 and data["outcome"] == "succeeded"
assert data["failureClass"] == "none" and data["providerErrorRef"] is None
assert isinstance(data["outputRef"], str) and os.path.abspath(data["outputRef"]) == os.path.abspath(output_path)
assert isinstance(data["recordedAt"], str) and data["recordedAt"]
assert os.path.getsize(output_path) > 0
PY
}
write_fixture_task() {
  mkdir -p "$fixture_repo/docs/orchestration/tasks"
  cat >"$fixture_repo/docs/orchestration/tasks/TASK-9999.md" <<'EOF'
# TASK-9999: Deterministic campaign lifecycle fixture

Status: ready
Area: canary
Target branch: `canary-target`
Worker branch: `agent/canary/TASK-9999-fixture`
Test policy: `test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise the isolated campaign lifecycle with a deterministic fixture.

## Scope

Owned files:

- `canary.txt`
- `.singular-evidence`

Forbidden files:

- `outside.txt`

## Acceptance Criteria

- The fixture changes canary.txt and passes the deterministic gate.
EOF
}
check_fixture_lifecycle() {
  local lifecycle_env=(
    SINGULAR_ROOT="$fixture_repo" SINGULAR_ENGINE_HOME="$SCRIPT_DIR/.."
    SINGULAR_BASH_BIN="$validated_bash_bin"
    SINGULAR_JSON_CONFIG_FILE="$fixture_repo/singular.config.json"
    SINGULAR_CONFIG_FILE=/dev/null SINGULAR_LOCAL_CONFIG_FILE=/dev/null
    SINGULAR_ORCH_DIR="$fixture_repo/docs/orchestration"
    SINGULAR_TASKS_DIR="$fixture_repo/docs/orchestration/tasks"
    SINGULAR_STATE_DIR="$fixture_repo/.singular-state"
    SINGULAR_TARGET_BRANCH="canary-target"
    SINGULAR_WORKTREES_DIR="$fixture_repo/.worktrees"
    SINGULAR_RUNNER="$fixture_runner" SINGULAR_REQUIRE_AUDIT=1 SINGULAR_AUDIT_VERIFY=1
    SINGULAR_MAX_RETRIES=0 SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_PUSH=0
  )
  run_isolated_fixture_lifecycle() (
    local inherited
    while IFS= read -r inherited; do
      unset "$inherited" 2>/dev/null || true
    done < <(compgen -A variable SINGULAR_)
    env "${lifecycle_env[@]}" "$@"
  )
  git clone --quiet --no-hardlinks "$SINGULAR_ROOT" "$fixture_repo"
  git -C "$fixture_repo" config user.name campaign-canary
  git -C "$fixture_repo" config user.email campaign-canary@example.invalid
  git -C "$fixture_repo" checkout -q -B canary-target "$source_target_sha"
  printf '{"schemaVersion":"v2","targetBranch":"canary-target","gateCommand":"true","runner":"%s","bootstrap":{"required":false,"commands":[]}}\n' "$fixture_runner" >"$fixture_repo/singular.config.json"
  # The cloned consumer fixture may not have been initialized yet. L1's prompt
  # renderer is part of the real path, so supply the two canonical templates
  # rather than bypassing it with a hand-written packet.
  mkdir -p "$fixture_repo/docs/orchestration/prompts"
  cp "$SCRIPT_DIR/../templates/prompts/l2-test-first-developer.md" "$fixture_repo/docs/orchestration/prompts/"
  cp "$SCRIPT_DIR/../templates/prompts/auditor.md" "$fixture_repo/docs/orchestration/prompts/"
  write_fixture_task
  # These are fixture inputs, not work produced by the lifecycle under test.
  # Commit them before dispatch so exact-tree integration can distinguish the
  # deterministic fixture baseline from an illicit concurrent source change.
  git -C "$fixture_repo" add singular.config.json \
    docs/orchestration/prompts docs/orchestration/tasks/TASK-9999.md
  git -C "$fixture_repo" commit -q -m "campaign canary lifecycle fixture baseline"
  (
    cd "$fixture_repo"
    run_isolated_fixture_lifecycle "$SCRIPT_DIR/l1-drive.sh" TASK-9999 >"$tmp/l1-drive.log" 2>&1
  ) || {
    cat "$tmp/l1-drive.log" >&2
    find "$fixture_repo/.singular-state/runs" -name 'worker-packet-validation.log' -exec cat {} \; >&2 2>/dev/null || true
    find "$fixture_repo/.singular-state/runs" -name 'scope-check.log' -exec cat {} \; >&2 2>/dev/null || true
    find "$fixture_repo/.singular-state/runs" -name 'audit-verification-bind.err' -exec cat {} \; >&2 2>/dev/null || true
    find "$fixture_repo/.singular-state/runs" -name 'audit-verification.json' -exec cat {} \; >&2 2>/dev/null || true
    find "$fixture_repo/.singular-state/runs" -name 'audit-verification-driver.log' -exec cat {} \; >&2 2>/dev/null || true
    return 1
  }
  local inbox packet run_id
  inbox="$(find "$fixture_repo/.singular-state/inbox" -maxdepth 1 -name '*.json' -type f | sort | tail -1)"
  [[ -n "$inbox" && -f "$inbox" ]] || { echo "campaign canary: L1 accepted no inbox packet" >&2; return 1; }
  run_id="$(python3 - "$inbox" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["runId"])
PY
)"
  (
    cd "$fixture_repo"
    run_isolated_fixture_lifecycle "$SCRIPT_DIR/import-packet.sh" "$inbox" >"$tmp/import.log" 2>&1
    run_isolated_fixture_lifecycle "$SCRIPT_DIR/integrate.sh" --task TASK-9999 --run-id "CANARY-INTEGRATE-$run_id" >"$tmp/integrate.log" 2>&1
  ) || {
    cat "$tmp/import.log" "$tmp/integrate.log" >&2
    find "$fixture_repo/.singular-state/runs" -path '*integrate*/gate-report.json' -type f -exec cat {} \; >&2 2>/dev/null || true
    find "$fixture_repo/.singular-state/runs" -path '*integrate*/gate-source-snapshot.err' -type f -exec cat {} \; >&2 2>/dev/null || true
    return 1
  }
  packet="$fixture_repo/docs/orchestration/packets/imported/TASK-9999/$run_id.json"
  lifecycle_audit_verification="$(python3 - "$fixture_repo/.singular-state/runs/$run_id/audit-verification.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["outcome"])
PY
)"
  if [[ ! -f "$fixture_repo/canary.txt" ]]; then
    echo "campaign canary: integration returned without publishing canary.txt" >&2
    cat "$tmp/import.log" "$tmp/integrate.log" >&2
    return 1
  fi
  python3 - "$fixture_repo" "$packet" "$run_id" "$source_target_sha" \
    "$SINGULAR_ROOT" "$SINGULAR_TARGET_BRANCH" <<'PY'
import json, os, subprocess, sys
repo, packet, run_id, source_before, source, source_target = sys.argv[1:]
assert open(os.path.join(repo, "canary.txt"), encoding="utf-8").read() == "canary lifecycle implementation\n"
p = json.load(open(packet, encoding="utf-8"))
assert p["status"] == "accepted" and p["runId"] == run_id and p["headSha"] != "uncommitted"
a = json.load(open(os.path.join(repo, ".singular-state", "runs", run_id, "audit.json"), encoding="utf-8"))
assert a["verdict"] == "accepted"
lease = json.load(open(os.path.join(repo, ".singular-state", "leases", "TASK-9999.json"), encoding="utf-8"))
assert lease["status"] == "integrated"
events = open(os.path.join(repo, ".singular-state", "events.ndjson"), encoding="utf-8").read()
for event in ("l1.task_accepted", "packet.imported", "integration.integrated"):
    assert event in events, event
assert subprocess.check_output(
    ["git", "-C", source, "rev-parse", "--verify", source_target], text=True
).strip() == source_before
PY
}

write_fixture_runner
check "bash>=4" check_bash
check "target-branch" check_target_branch
if [[ "$fixture" == "yes" ]]; then
  check "fixture-runner-contract" check_runner_contract "$fixture_runner"
  selected_runner="$fixture_runner"
else
  selected_runner="${SINGULAR_RUNNER:-$SCRIPT_DIR/codex-run.sh}"
  check "production-runner-contract" check_runner_contract "$selected_runner"
fi
check "disposable-worktree-bootstrap" check_bootstrap_worktree
if [[ ${#failures[@]} -eq 0 ]]; then
  if check_live_runner_probe "$selected_runner"; then
    provider_probe_state="passed"
    if [[ "$fixture" == "yes" ]]; then
      checks+=("fixture-runner-live-readonly-probe")
    else
      checks+=("production-runner-live-readonly-probe")
    fi
  else
    provider_probe_state="failed"
    if [[ "$fixture" == "yes" ]]; then
      failures+=("fixture-runner-live-readonly-probe")
    elif [[ "$provider_unchecked_waiver" == "yes" ]]; then
      checks+=("provider-live-probe-explicitly-waived")
    else
      failures+=("production-runner-live-readonly-probe")
    fi
  fi
fi
if [[ ${#failures[@]} -eq 0 ]]; then
  check "fixture-lifecycle-worker-gate-audit-evidence-import-integration" check_fixture_lifecycle
fi
target_mutated="no"
if [[ -n "$source_target_sha" \
      && "$(git -C "$SINGULAR_ROOT" rev-parse --verify "$SINGULAR_TARGET_BRANCH" 2>/dev/null || true)" != "$source_target_sha" ]]; then
  target_mutated="yes"
  failures+=("campaign-target-mutated")
fi

if [[ "$json" == "yes" ]]; then
  python3 - "${checks[*]}" "${failures[*]}" "$fixture" "$lifecycle_audit_verification" \
    "$provider_unchecked_waiver" "$provider_probe_state" "$provider_probe_invoked" "$target_mutated" <<'PY'
import json, sys
checks = [item for item in sys.argv[1].split() if item]
failures = [item for item in sys.argv[2].split() if item]
lifecycle = "fixture-lifecycle-worker-gate-audit-evidence-import-integration"
fixture = sys.argv[3] == "yes"
probe_state = sys.argv[6]
probe_invoked = sys.argv[7] == "yes"
provider_invoked = probe_invoked and not fixture
provider_unchecked = fixture or probe_state != "passed"
waived = fixture or (provider_unchecked and sys.argv[5] == "yes")
target_mutated = sys.argv[8] == "yes"
print(json.dumps({"schema":"singular.orchestration.campaign-canary.v1", "ok":not failures, "fixture":fixture, "checks":checks, "failures":failures, "providerInvoked":provider_invoked, "providerUnchecked":provider_unchecked, "providerUncheckedWaived":waived, "providerProbe":{"invoked":probe_invoked, "state":probe_state}, "targetMutated":target_mutated, "lifecycle":{"mode":"isolated-fixture-v1-runner", "providerInvoked":False, "providerUnchecked":True, "providerUncheckedWaived":True, "targetMutated":target_mutated, "covered":lifecycle in checks, "auditVerification":sys.argv[4], "stages":["worker", "gate", "accepted-audit", "evidence", "packet-import", "integration"] if lifecycle in checks else []}}, sort_keys=True))
PY
elif [[ ${#failures[@]} -eq 0 ]]; then
  echo "campaign canary PASS: ${checks[*]}"
else
  echo "campaign canary FAIL: ${failures[*]}" >&2
fi
[[ ${#failures[@]} -eq 0 ]]
