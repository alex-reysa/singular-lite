#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Keep the consumer prompt mirrors aligned and make the v1 output contract
# explicit enough that verificationResults cannot be emitted as an
# underspecified array.
python3 - "$ROOT/templates/prompts/auditor.md" \
  "$ROOT/docs/orchestration/prompts/auditor.md" <<'PY'
import sys

required_top_level = (
    "schema",
    "taskId",
    "runId",
    "branch",
    "verdict",
    "evidenceReviewed",
    "verificationResults",
    "commandsRun",
    "findings",
    "requiredFixes",
    "rationale",
)
required_verification = ("status", "command", "evidenceRefs", "rationale")
prompts = [open(path, encoding="utf-8").read() for path in sys.argv[1:]]
assert prompts[0] == prompts[1], "auditor prompt mirrors diverged"
prompt = prompts[0]
for field in required_top_level:
    assert f"`{field}`" in prompt, f"auditor prompt omits top-level {field}"
for field in required_verification:
    assert f"`{field}`" in prompt, f"auditor prompt omits verificationResults.{field}"
assert "Every `verificationResults[]` object contains all four required members" in prompt
PY

repo="$tmp/repo"
run_dir="$tmp/runs/RUN-AUDIT"
mkdir -p "$repo" "$run_dir" "$tmp/worktrees" "$tmp/state"

git -C "$repo" init -q
git -C "$repo" checkout -q -b main
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
cat >"$repo/.gitignore" <<'EOF'
.singular-state/
.turbo/
node_modules/
EOF
cat >"$repo/singular.config.json" <<'JSON'
{
  "schemaVersion": "v2",
  "targetBranch": "main",
  "gateCommand": "strict adapter supplied by test"
}
JSON
printf 'committed\n' >"$repo/app.txt"
git -C "$repo" add .gitignore singular.config.json app.txt
git -C "$repo" commit -qm init
head_sha="$(git -C "$repo" rev-parse HEAD)"
tree_sha="$(git -C "$repo" rev-parse 'HEAD^{tree}')"

base_env=(
  SINGULAR_ROOT="$repo"
  SINGULAR_STATE_DIR="$tmp/state"
  SINGULAR_RUNS_DIR="$tmp/runs"
  SINGULAR_WORKTREES_DIR="$tmp/worktrees"
  SINGULAR_GIT_LOCK_DIR="$tmp/state/locks/git-op.lock"
  SINGULAR_TARGET_BRANCH="main"
  SINGULAR_BOOTSTRAP_JSON="{}"
)

verification_sequence=0
verification_request=""
verification_task_contract=""
verification_policy_contract=""
verification_args=()
prepare_verification() {
  local command="$1"
  verification_sequence=$((verification_sequence + 1))
  verification_request="$run_dir/verification-request-$verification_sequence.json"
  verification_task_contract="$run_dir/verification-task-contract-$verification_sequence.md"
  verification_policy_contract="$run_dir/verification-policy-$verification_sequence.json"
  printf '# TASK-0001: audit verification fixture\n\nStatus: running\nTest policy: `strict_test_first`\nGate command: `%s`\n' \
    "$command" >"$verification_task_contract"
  printf '%s\n' '{"campaign":"campaign:audit-test","policy":"strict-test-first"}' \
    >"$verification_policy_contract"
  python3 "$ROOT/engine/gate-report.py" create-verification-request \
    --output "$verification_request" --task-id TASK-0001 --run-id RUN-AUDIT \
    --attempt "$verification_sequence" --head-sha "$head_sha" \
    --tree-sha "$tree_sha" --campaign campaign:audit-test \
    --task-contract "$verification_task_contract" \
    --policy-contract "$verification_policy_contract" \
    --suite-id task-contract-gate >/dev/null
  verification_args=(
    --verification-request "$verification_request"
    --task-contract "$verification_task_contract"
    --policy-contract "$verification_policy_contract"
  )
}

run_verify() {
  local command="$1" expected_rc="$2" rc=0
  prepare_verification "$command"
  env "${base_env[@]}" "$ROOT/engine/audit-verify.sh" \
    --run-dir "$run_dir" --task-id TASK-0001 \
    --source-worktree "$repo" --head-sha "$head_sha" \
    --gate-command "$command" --attempt 1 --try 0 \
    "${verification_args[@]}" \
    >"$run_dir/driver.log" 2>&1 || rc=$?
  [[ "$rc" -eq "$expected_rc" ]] || {
    echo "audit verification exit mismatch: expected $expected_rc, got $rc" >&2
    cat "$run_dir/driver.log" >&2
    exit 1
  }
}

outcome() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["outcome"])' \
    "$run_dir/audit-verification.json"
}

# Turbo/Vitest/Bun-style cache writes are allowed in ignored workspace paths
# and isolated cache roots, while the original audited checkout stays unchanged.
original_before="$(git -C "$repo" status --porcelain=v1 --untracked-files=all)"
pass_observation='printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[]}" >"$SINGULAR_GATE_REPORT_FILE"'
cache_command="$pass_observation; mkdir -p .turbo node_modules/.vite; printf cache > .turbo/state; printf vite > node_modules/.vite/state; test -n \"\$TURBO_CACHE_DIR\"; printf external > \"\$TURBO_CACHE_DIR/entry\""
run_verify "$cache_command" 0
[[ "$(outcome)" == "passed" ]]
[[ "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" == "$original_before" ]]
[[ ! -e "$repo/.turbo/state" && ! -e "$repo/node_modules/.vite/state" ]]

run_verify 'printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[{\"signature\":\"assertion-one\"}]}" >"$SINGULAR_GATE_REPORT_FILE"; printf "AssertionError: expected one to equal two\n" >&2; exit 1' 10
[[ "$(outcome)" == "failed-product" ]]

run_verify 'printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[],\"infrastructureFailure\":true,\"infrastructureReason\":\"read-only-filesystem\"}" >"$SINGULAR_GATE_REPORT_FILE"; printf "Read-only file system\n" >&2; exit 1' 20
[[ "$(outcome)" == "inconclusive-infrastructure" ]]

# Infrastructure setup prose containing the word "failed" is not itself a
# product-test signal.
run_verify 'printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[],\"infrastructureFailure\":true,\"infrastructureReason\":\"permission-denied\"}" >"$SINGULAR_GATE_REPORT_FILE"; printf "tool setup failed: EACCES permission denied\n" >&2; exit 1' 20
[[ "$(outcome)" == "inconclusive-infrastructure" ]]

# A genuine product assertion wins over an unrelated infrastructure warning.
run_verify 'printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[{\"signature\":\"assertion-mixed\"}],\"infrastructureFailure\":true,\"infrastructureReason\":\"read-only-filesystem\"}" >"$SINGULAR_GATE_REPORT_FILE"; printf "Read-only file system\nAssertionError: expected one to equal two\n" >&2; exit 1' 10
[[ "$(outcome)" == "failed-product" ]]

# Any attempted source mutation invalidates the disposable attempt; the source
# checkout itself remains byte-identical because the worktree is discarded.
run_verify "$pass_observation; printf mutated > app.txt" 20
[[ "$(outcome)" == "inconclusive-infrastructure" ]]
[[ "$(cat "$repo/app.txt")" == "committed" ]]
python3 - "$run_dir/audit-verification.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["sourceIntegrity"]["status"] == "violation"
assert "app.txt" in data["sourceIntegrity"]["changedPaths"]
PY

# Restoring the original bytes before exit does not erase the write attempt:
# tracked metadata changes are part of the integrity evidence.
run_verify "$pass_observation; cp app.txt \"\$TMPDIR/original-app\"; printf temporary > app.txt; cp \"\$TMPDIR/original-app\" app.txt" 20
[[ "$(outcome)" == "inconclusive-infrastructure" ]]
[[ "$(cat "$repo/app.txt")" == "committed" ]]
python3 - "$run_dir/audit-verification.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["sourceIntegrity"]["status"] == "violation"
assert "app.txt" in data["sourceIntegrity"]["changedPaths"]
assert "source-integrity-violation" in data["infrastructureSignals"]
PY

# v2 strict gates cannot turn a bare zero exit into passing evidence.
run_verify 'true' 20
[[ "$(outcome)" == "inconclusive-infrastructure" ]]
python3 - "$run_dir/audit-verification.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert "strict-gate-observation-missing" in data["infrastructureSignals"]
PY

# A bounded audited gate cannot hold a verifier slot forever. Exit 124 is
# infrastructure, and the timeout guard terminates the command tree.
timeout_started="$(date +%s)"
SINGULAR_AUDIT_GATE_TIMEOUT_SEC=1 run_verify 'sleep 30' 20
timeout_elapsed="$(( $(date +%s) - timeout_started ))"
[[ "$timeout_elapsed" -lt 10 ]] || {
  echo "audited gate timeout exceeded bound (${timeout_elapsed}s)" >&2
  exit 1
}
[[ "$(outcome)" == "inconclusive-infrastructure" ]]
python3 - "$run_dir/audit-verification.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["rawExitCode"] == 124
assert "gate-command-timeout" in data["infrastructureSignals"]
assert "strict-gate-observation-missing" in data["infrastructureSignals"]
PY

# An unexplained terminal exit with an otherwise valid empty observation is
# inconclusive infrastructure, not fabricated failed-product evidence.
run_verify "$pass_observation; exit 70" 20
[[ "$(outcome)" == "inconclusive-infrastructure" ]]
python3 - "$run_dir/audit-verification.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert "unknown-terminal-exit:70" in data["infrastructureSignals"]
assert data["unexpectedFailures"] == []
PY

# When a disposable rerun is unavailable, only a successful report whose
# command, committed head, and full raw log hash still match may substitute.
printf 'gate passed\n' >"$run_dir/worker-gate.log"
python3 "$ROOT/engine/gate-report.py" create \
  --output "$run_dir/worker-gate.json" --task-id TASK-0001 \
  --run-id RUN-AUDIT --head-sha "$head_sha" --command true \
  --exit-code 0 --log "$run_dir/worker-gate.log" \
  --phase worker --workspace-kind worker --integrity-status verified >/dev/null
prepare_verification true
env "${base_env[@]}" "$ROOT/engine/audit-verify.sh" \
  --run-dir "$run_dir" --task-id TASK-0001 \
  --source-worktree "$repo" --head-sha "$head_sha" \
  --gate-command true --worker-gate-report "$run_dir/worker-gate.json" \
  --evidence-only "${verification_args[@]}" >/dev/null
[[ "$(outcome)" == "not-rerun-evidence-verified" ]]

# The worker gate may have recorded the host shell wrapper while the
# disposable verifier receives only the inner configured command. The caller
# must bind both explicitly rather than weakening exact command verification.
python3 "$ROOT/engine/gate-report.py" create \
  --output "$run_dir/wrapped-worker-gate.json" --task-id TASK-0001 \
  --run-id RUN-AUDIT --head-sha "$head_sha" --command "bash -c true" \
  --exit-code 0 --log "$run_dir/worker-gate.log" \
  --phase worker --workspace-kind worker --integrity-status verified >/dev/null
prepare_verification true
env "${base_env[@]}" "$ROOT/engine/audit-verify.sh" \
  --run-dir "$run_dir" --task-id TASK-0001 \
  --source-worktree "$repo" --head-sha "$head_sha" \
  --gate-command true --worker-gate-command "bash -c true" \
  --worker-gate-report "$run_dir/wrapped-worker-gate.json" \
  --evidence-only "${verification_args[@]}" >/dev/null
[[ "$(outcome)" == "not-rerun-evidence-verified" ]]

# A successful-looking report is not eligible for evidence-only substitution
# unless the producing gate verified source integrity.
python3 "$ROOT/engine/gate-report.py" create \
  --output "$run_dir/unverified-gate.json" --task-id TASK-0001 \
  --run-id RUN-AUDIT --head-sha "$head_sha" --command true \
  --exit-code 0 --log "$run_dir/worker-gate.log" \
  --phase worker --workspace-kind worker --integrity-status not-checked >/dev/null
prepare_verification true
if env "${base_env[@]}" "$ROOT/engine/audit-verify.sh" \
  --run-dir "$run_dir" --task-id TASK-0001 \
  --source-worktree "$repo" --head-sha "$head_sha" \
  --gate-command true --worker-gate-report "$run_dir/unverified-gate.json" \
  --evidence-only "${verification_args[@]}" >/dev/null 2>&1; then
  echo "unverified source integrity must fail evidence-only validation" >&2
  exit 1
fi

# Changing only a failed report's outcome cannot forge successful evidence:
# the terminal exit code, outcome, log hash, command, and head are one binding.
printf 'AssertionError: expected one to equal two\n' >"$run_dir/failed-gate.log"
python3 "$ROOT/engine/gate-report.py" create \
  --output "$run_dir/failed-gate.json" --task-id TASK-0001 \
  --run-id RUN-AUDIT --head-sha "$head_sha" --command false \
  --exit-code 1 --log "$run_dir/failed-gate.log" \
  --phase worker --workspace-kind worker --integrity-status verified \
  >/dev/null 2>&1 || true
python3 - "$run_dir/failed-gate.json" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path))
data["outcome"] = "passed"
data["unexpectedFailures"] = []
json.dump(data, open(path, "w"))
PY
prepare_verification false
if env "${base_env[@]}" "$ROOT/engine/audit-verify.sh" \
  --run-dir "$run_dir" --task-id TASK-0001 \
  --source-worktree "$repo" --head-sha "$head_sha" \
  --gate-command false --worker-gate-report "$run_dir/failed-gate.json" \
  --evidence-only "${verification_args[@]}" >/dev/null 2>&1; then
  echo "outcome-only gate report forgery must fail verification" >&2
  exit 1
fi

printf 'tampered\n' >>"$run_dir/worker-gate.log"
prepare_verification true
if env "${base_env[@]}" "$ROOT/engine/audit-verify.sh" \
  --run-dir "$run_dir" --task-id TASK-0001 \
  --source-worktree "$repo" --head-sha "$head_sha" \
  --gate-command true --worker-gate-report "$run_dir/worker-gate.json" \
  --evidence-only "${verification_args[@]}" >/dev/null 2>&1; then
  echo "tampered gate evidence must fail verification" >&2
  exit 1
fi

# Evidence-only validation rehashes the acknowledged baseline as well as the
# command log; a changed baseline invalidates the prior report immediately.
baseline_command='printf baseline'
baseline_command_sha="$(printf '%s' "$baseline_command" | shasum -a 256 | awk '{print $1}')"
printf 'known baseline failure\n' >"$run_dir/baseline-gate.log"
cat >"$run_dir/baseline-observation.json" <<'JSON'
{
  "schema": "singular.orchestration.gate-observation.v0",
  "failures": [{"signature": "known-baseline"}]
}
JSON
cat >"$run_dir/baseline.json" <<JSON
{
  "schema": "singular.orchestration.gate-baseline.v0",
  "commandSha256": "$baseline_command_sha",
  "failures": [{"signature": "known-baseline"}],
  "acknowledgedBy": "owner",
  "recordedAt": "2026-07-24T10:00:00Z"
}
JSON
python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-0001 --run-id RUN-AUDIT --head-sha "$head_sha" \
  --command "$baseline_command" --raw-exit-code 1 \
  --log-ref "$run_dir/baseline-gate.log" --log-path "$run_dir/baseline-gate.log" \
  --observation "$run_dir/baseline-observation.json" \
  --baseline "$run_dir/baseline.json" \
  --integrity-status verified \
  --output "$run_dir/baseline-gate.json" >/dev/null
prepare_verification "$baseline_command"
env "${base_env[@]}" "$ROOT/engine/audit-verify.sh" \
  --run-dir "$run_dir" --task-id TASK-0001 \
  --source-worktree "$repo" --head-sha "$head_sha" \
  --gate-command "$baseline_command" \
  --worker-gate-report "$run_dir/baseline-gate.json" --evidence-only \
  "${verification_args[@]}" >/dev/null
printf '\n' >>"$run_dir/baseline.json"
prepare_verification "$baseline_command"
if env "${base_env[@]}" "$ROOT/engine/audit-verify.sh" \
  --run-dir "$run_dir" --task-id TASK-0001 \
  --source-worktree "$repo" --head-sha "$head_sha" \
  --gate-command "$baseline_command" \
  --worker-gate-report "$run_dir/baseline-gate.json" --evidence-only \
  "${verification_args[@]}" \
  >/dev/null 2>&1; then
  echo "changed acknowledged baseline must fail evidence verification" >&2
  exit 1
fi

echo "audit verification tests passed"
