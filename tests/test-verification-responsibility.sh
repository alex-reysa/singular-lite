#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A focused body that does not itself need shared-registry writes must still run
# when the host probe is denied. The harness records the unavailable host check
# instead of claiming that it passed or aborting before discovery.
fixture="$tmp/harness"
mkdir -p "$fixture/tests" "$fixture/engine" "$fixture/bin" \
  "$fixture/docs/orchestration/tasks"
cp "$ROOT/tests/run.sh" "$fixture/tests/run.sh"
cp "$ROOT/engine/git-preflight.sh" "$fixture/engine/git-preflight.sh"
cp "$ROOT/engine/bash-guard.sh" "$fixture/engine/bash-guard.sh"
cat >"$fixture/tests/test-supported.sh" <<'SH'
#!/usr/bin/env bash
echo body-ran
SH
cat >"$fixture/tests/test-host-only.sh" <<'SH'
#!/usr/bin/env bash
# singular-test: host-only
echo host-only-ran
SH
cat >"$fixture/tests/test-unlisted.sh" <<'SH'
#!/usr/bin/env bash
echo unlisted-ran
SH
cat >"$fixture/docs/orchestration/tasks/TASK-1107.md" <<'MD'
# TASK-1107: focused fixture

Test policy: `strict_test_first`
Gate command: `bash tests/run.sh test-supported.sh; bash tests/run.sh test-host-only.sh`
MD
printf 'fixture\n' >"$fixture/data.txt"
git -C "$fixture" init -q
git -C "$fixture" config user.name fixture
git -C "$fixture" config user.email fixture@example.local
git -C "$fixture" add .
git -C "$fixture" commit -qm fixture
real_git="$(command -v git)"
cat >"$fixture/bin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" worktree add "*) echo 'fatal: unable to create .git/worktrees/x: Operation not permitted' >&2; exit 128 ;;
  *) exec "$REAL_GIT_BIN" "$@" ;;
esac
SH
chmod +x "$fixture/tests/test-supported.sh" "$fixture/tests/test-host-only.sh" \
  "$fixture/tests/test-unlisted.sh" "$fixture/bin/git"

# A basename alone is not authority to continue after the host preflight was
# denied. The host must supply the canonical task contract that selected the
# focused body.
rc=0
out="$(PATH="$fixture/bin:$PATH" REAL_GIT_BIN="$real_git" \
  bash "$fixture/tests/run.sh" test-supported.sh 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" != *"body-ran"* ]] \
  || fail "untrusted focused basename executed after preflight denial (rc=$rc): $out"

rc=0
out="$(PATH="$fixture/bin:$PATH" REAL_GIT_BIN="$real_git" \
  SINGULAR_TEST_TASK_CONTRACT="$fixture/docs/orchestration/tasks/TASK-1107.md" \
  SINGULAR_TEST_TASK_ID=TASK-1107 \
  SINGULAR_TEST_TASKS_DIR="$fixture/docs/orchestration/tasks" \
  bash "$fixture/tests/run.sh" test-unlisted.sh 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" != *"unlisted-ran"* ]] \
  || fail "unlisted focused body executed after preflight denial (rc=$rc): $out"

rc=0
out="$(PATH="$fixture/bin:$PATH" REAL_GIT_BIN="$real_git" \
  SINGULAR_TEST_TASK_CONTRACT="$fixture/docs/orchestration/tasks/TASK-1107.md" \
  SINGULAR_TEST_TASK_ID=TASK-1107 \
  SINGULAR_TEST_TASKS_DIR="$fixture/docs/orchestration/tasks" \
  bash "$fixture/tests/run.sh" test-host-only.sh 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" != *"host-only-ran"* ]] \
  || fail "host-only focused body executed after preflight denial (rc=$rc): $out"

rc=0
out="$(PATH="$fixture/bin:$PATH" REAL_GIT_BIN="$real_git" \
  SINGULAR_TEST_TASK_CONTRACT="$fixture/docs/orchestration/tasks/TASK-1107.md" \
  SINGULAR_TEST_TASK_ID=TASK-1107 \
  SINGULAR_TEST_TASKS_DIR="$fixture/docs/orchestration/tasks" \
  SINGULAR_GATE_REPORT_FILE="$tmp/host-required-observation.json" \
  bash "$fixture/tests/run.sh" test-supported.sh 2>&1)" || rc=$?
[[ "$rc" == 2 ]] \
  || fail "incomplete focused verification was reported successful (rc=$rc): $out"
[[ "$out" == *"HOST_REQUIRED git-registry-write unrun"* ]] \
  || fail "registry denial was not reported as host_required/unrun"
[[ "$out" == *"body-ran"* || "$out" == *"PASS  test-supported.sh"* ]] \
  || fail "focused body did not run"
python3 - "$tmp/host-required-observation.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["failures"] == []
assert d["hostRequired"] == [
    {"check": "git-registry-write", "status": "unrun"},
]
PY

# The real gate entrypoint, rather than a caller-supplied environment label,
# resolves and exports the canonical task contract used by the harness.
rc=0
(cd "$fixture" && PATH="$fixture/bin:$PATH" REAL_GIT_BIN="$real_git" \
  SINGULAR_ROOT="$fixture" SINGULAR_STATE_DIR="$tmp/harness-state" \
  SINGULAR_TASKS_DIR="$fixture/docs/orchestration/tasks" \
  SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
  "$ROOT/engine/gate-check.sh" RUN-FOCUSED \
    --task-id TASK-1107 --phase worker --workspace-kind worker \
    --task-contract "$fixture/docs/orchestration/tasks/TASK-1107.md" -- \
    bash tests/run.sh test-supported.sh) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 20 ]] \
  || fail "focused gate did not preserve host-required result (rc=$rc)"
grep -q 'PASS  test-supported.sh' "$tmp/harness-state/runs/RUN-FOCUSED/gate-check.log" \
  || fail "gate-check did not run the contract-authorized focused body"
grep -q 'HOST_REQUIRED git-registry-write unrun' \
  "$tmp/harness-state/runs/RUN-FOCUSED/gate-check.log" \
  || fail "gate-check did not retain the unrun host requirement"

# Both report adapters must preserve the incomplete aggregate. In particular,
# an exit-zero compatibility producer cannot turn the explicit unrun marker
# into successful evidence merely because the supported focused body passed.
printf 'HOST_REQUIRED git-registry-write unrun\n' >"$tmp/host-required.log"
rc=0
python3 "$ROOT/engine/gate-report.py" create \
  --output "$tmp/host-required-report.json" --task-id TASK-1107 \
  --run-id RUN-HOST-REQUIRED --head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --command 'bash tests/run.sh test-supported.sh' --exit-code 0 \
  --log "$tmp/host-required.log" --integrity-status verified \
  >/dev/null 2>&1 || rc=$?
[[ "$rc" == 20 ]] \
  || fail "HOST_REQUIRED compatibility report was accepted (rc=$rc)"
python3 - "$tmp/host-required-report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["outcome"] == "inconclusive-infrastructure", d
assert "host-required:git-registry-write:unrun" in d["infrastructureSignals"], d
PY

# A real body failure remains a failure even when the host-only probe is also
# unavailable.
cat >"$fixture/tests/test-supported.sh" <<'SH'
#!/usr/bin/env bash
echo 'AssertionError: deliberate behavior failure' >&2
exit 1
SH
rc=0
out="$(PATH="$fixture/bin:$PATH" REAL_GIT_BIN="$real_git" \
  SINGULAR_TEST_TASK_CONTRACT="$fixture/docs/orchestration/tasks/TASK-1107.md" \
  SINGULAR_TEST_TASK_ID=TASK-1107 \
  SINGULAR_TEST_TASKS_DIR="$fixture/docs/orchestration/tasks" \
  bash "$fixture/tests/run.sh" test-supported.sh 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" == *"FAIL  test-supported.sh"* ]] \
  || fail "behavior failure was hidden by infrastructure classification"

# The preflight itself distinguishes source/history, registry permission and
# temporary workspace failures with stable classifications.
set +e
PATH="$fixture/bin:$PATH" REAL_GIT_BIN="$real_git" \
  bash -c '. "$1"; singular_git_source_preflight "$2"' \
  _ "$ROOT/engine/git-preflight.sh" "$fixture" >"$tmp/preflight.out" 2>&1
rc=$?
set -e
[[ "$rc" == 2 ]] || fail "registry permission did not use its distinct return code"
grep -q 'classification=registry-permission' "$tmp/preflight.out" \
  || fail "registry permission classification missing"

# Consume a mixed failure through both report implementations. The body
# failure must remain actionable even though a host check is also unrun.
printf '%s\n' 'FAIL test-supported.sh' 'HOST_REQUIRED git-registry-write unrun' \
  >"$tmp/mixed.log"
cat >"$tmp/mixed-observation.json" <<'JSON'
{"schema":"singular.orchestration.gate-observation.v0","failures":[{"signature":"engine-regression:test-supported.sh","title":"test-supported.sh"}],"hostRequired":[{"check":"git-registry-write","status":"unrun"}],"infrastructureFailure":true,"infrastructureReason":"host-required:git-registry-write:unrun"}
JSON
rc=0
python3 "$ROOT/engine/gate-report.py" create \
  --output "$tmp/mixed-compat.json" --task-id TASK-1107 --run-id RUN-MIXED \
  --head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --command 'bash tests/run.sh test-supported.sh' --exit-code 1 \
  --log "$tmp/mixed.log" --integrity-status verified >/dev/null || rc=$?
[[ "$rc" == 10 ]] || fail "compatibility report hid product failure (rc=$rc)"
python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-1107 --run-id RUN-MIXED \
  --head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --command 'bash tests/run.sh test-supported.sh' --raw-exit-code 1 \
  --log-ref mixed.log --log-path "$tmp/mixed.log" \
  --observation "$tmp/mixed-observation.json" --integrity-status verified \
  --output "$tmp/mixed-strict.json" >/dev/null
python3 - "$tmp/mixed-compat.json" "$tmp/mixed-strict.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    report = json.load(open(path, encoding="utf-8"))
    assert report["outcome"] == "failed-product", report
    assert report["unexpectedFailures"], report
    assert "host-required:git-registry-write:unrun" in report["infrastructureSignals"], report
PY

# A host verification request carries identity, never executable authority.
# gate-check resolves the command from the trusted task contract and binds the
# result to contract/attempt/head/tree/campaign/policy/suite/log identities.
repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/tasks" "$repo/.singular-state/runs/RUN-HOST"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.local
cat >"$repo/trusted-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo trusted-command-ran
[[ -z "${GATE_MARKER:-}" ]] || : >"$GATE_MARKER"
[[ -z "${SINGULAR_GATE_REPORT_FILE:-}" ]] || printf '%s\n' \
  '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$repo/trusted-gate.sh"
cat >"$repo/docs/orchestration/tasks/TASK-1107.md" <<'MD'
# TASK-1107: fixture

Status: ready
Test policy: `strict_test_first`
Gate command: `bash trusted-gate.sh`
MD
policy="$repo/.singular-state/runs/RUN-HOST/verification-policy-2.json"
printf '{"campaign":"legacy","policy":"policy:test"}\n' >"$policy"
printf 'fixture\n' >"$repo/data.txt"
git -C "$repo" add .
git -C "$repo" commit -qm fixture
head_sha="$(git -C "$repo" rev-parse HEAD)"
tree_sha="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
request="$repo/.singular-state/runs/RUN-HOST/verification-request-2.json"
bound_task_contract="$repo/.singular-state/runs/RUN-HOST/verification-task-contract-2.md"
cp "$repo/docs/orchestration/tasks/TASK-1107.md" "$bound_task_contract"
python3 "$ROOT/engine/gate-report.py" create-verification-request \
  --output "$request" --task-id TASK-1107 --run-id RUN-HOST --attempt 2 \
  --head-sha "$head_sha" --tree-sha "$tree_sha" --campaign legacy \
  --task-contract "$bound_task_contract" \
  --policy-contract "$policy" --suite-id task-contract-gate >/dev/null
if python3 "$ROOT/engine/gate-report.py" create-verification-request \
    --output "$tmp/malformed-request.json" --task-id TASK-1107 \
    --run-id RUN-MALFORMED --attempt 2 --head-sha not-a-commit \
    --tree-sha "$tree_sha" --campaign legacy \
    --task-contract "$bound_task_contract" \
    --policy-contract "$policy" --suite-id focused \
    >/dev/null 2>&1; then
  fail "malformed candidate identity was normalized into a verification request"
fi
if python3 "$ROOT/engine/gate-report.py" create-verification-request \
    --output "$tmp/nonpositive-attempt.json" --task-id TASK-1107 \
    --run-id RUN-MALFORMED --attempt 0 --head-sha "$head_sha" \
    --tree-sha "$tree_sha" --campaign legacy \
    --task-contract "$bound_task_contract" \
    --policy-contract "$policy" --suite-id task-contract-gate \
    >/dev/null 2>&1; then
  fail "nonpositive verification attempt was issued"
fi
python3 - "$request" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert "command" not in d and "commands" not in d
assert d["commandIdentity"]
PY

# gate-check refuses mismatched run/attempt/head identities before it creates
# run evidence or launches the trusted command.
for mismatch in run attempt; do
  marker="$tmp/gate-$mismatch-command-ran"
  rc=0
  if [[ "$mismatch" == run ]]; then
    (cd "$repo" && GATE_MARKER="$marker" "$ROOT/engine/gate-check.sh" RUN-WRONG \
      --task-id TASK-1107 --verification-request "$request" \
      --task-contract "$bound_task_contract" --policy-contract "$policy" \
      --attempt 2) \
      >"$tmp/gate-$mismatch.log" 2>&1 || rc=$?
  else
    (cd "$repo" && GATE_MARKER="$marker" "$ROOT/engine/gate-check.sh" RUN-HOST \
      --task-id TASK-1107 --verification-request "$request" \
      --task-contract "$bound_task_contract" --policy-contract "$policy" \
      --attempt 7) \
      >"$tmp/gate-$mismatch.log" 2>&1 || rc=$?
  fi
  [[ "$rc" -ne 0 && ! -e "$marker" ]] \
    || fail "gate-check $mismatch mismatch launched the trusted command"
  if [[ "$mismatch" == run && -e "$repo/.singular-state/runs/RUN-WRONG" ]]; then
    fail "gate-check created run evidence before rejecting the run mismatch"
  fi
done

printf 'new head\n' >"$repo/new-head.txt"
git -C "$repo" add new-head.txt
git -C "$repo" commit -qm 'new head fixture'
marker="$tmp/gate-head-command-ran"
rc=0
(cd "$repo" && GATE_MARKER="$marker" "$ROOT/engine/gate-check.sh" RUN-HOST \
  --task-id TASK-1107 --verification-request "$request" \
  --task-contract "$bound_task_contract" --policy-contract "$policy" \
  --attempt 2) \
  >"$tmp/gate-head.log" 2>&1 || rc=$?
[[ "$rc" -ne 0 && ! -e "$marker" ]] \
  || fail "gate-check stale head launched the trusted command"
git -C "$repo" reset -q --hard "$head_sha"

export SINGULAR_ROOT="$repo"
export SINGULAR_STATE_DIR="$repo/.singular-state"
export SINGULAR_LOCAL_CONFIG_FILE=/dev/null
(cd "$repo" && "$ROOT/engine/gate-check.sh" RUN-HOST \
  --task-id TASK-1107 \
  --verification-request "$request" \
  --task-contract "$bound_task_contract" \
  --policy-contract "$policy" --attempt 2) >/dev/null
result="$repo/.singular-state/runs/RUN-HOST/gate-report.json"
python3 "$ROOT/engine/gate-report.py" verify-verification-result \
  --request "$request" --report "$result" \
  --task-contract "$bound_task_contract" \
  --policy-contract "$policy" --expected-task TASK-1107 \
  --expected-run RUN-HOST --expected-head "$head_sha" \
  --expected-tree "$tree_sha" \
  --current-task-contract "$repo/docs/orchestration/tasks/TASK-1107.md" \
  --require-pass >/dev/null

# Canonical execution refuses an absent request before the gate command can
# run. This is the paid-audit boundary, not a post-hoc evidence check.
missing_request_marker="$tmp/missing-request-command-ran"
if "$ROOT/engine/audit-verify.sh" \
    --run-dir "$repo/.singular-state/runs/RUN-HOST" \
    --task-id TASK-1107 --source-worktree "$repo" --head-sha "$head_sha" \
    --gate-command "touch '$missing_request_marker'" >/dev/null 2>&1; then
  fail "non-evidence audit verification accepted an absent request"
fi
[[ ! -e "$missing_request_marker" ]] \
  || fail "audit command ran before its request was validated"

# Every audit-verification consumption path requires and verifies the same
# request/result identity, including evidence-only substitution.
if "$ROOT/engine/audit-verify.sh" --run-dir "$repo/.singular-state/runs/RUN-HOST" \
    --task-id TASK-1107 --source-worktree "$repo" --head-sha "$head_sha" \
    --gate-command 'bash trusted-gate.sh' --worker-gate-report "$result" \
    --worker-gate-command 'bash trusted-gate.sh' --evidence-only \
    >/dev/null 2>&1; then
  fail "evidence-only audit verification bypassed the request binding"
fi
"$ROOT/engine/audit-verify.sh" --run-dir "$repo/.singular-state/runs/RUN-HOST" \
  --task-id TASK-1107 --source-worktree "$repo" --head-sha "$head_sha" \
  --gate-command 'bash trusted-gate.sh' --worker-gate-report "$result" \
  --worker-gate-command 'bash trusted-gate.sh' --evidence-only \
  --attempt 2 \
  --verification-request "$request" \
  --task-contract "$bound_task_contract" \
  --policy-contract "$policy" >/dev/null
python3 "$ROOT/engine/gate-report.py" verify-verification-result \
  --request "$request" --report "$repo/.singular-state/runs/RUN-HOST/audit-verification.json" \
  --task-contract "$bound_task_contract" \
  --policy-contract "$policy" --expected-task TASK-1107 \
  --expected-run RUN-HOST --expected-head "$head_sha" \
  --expected-tree "$tree_sha" --require-pass >/dev/null

cp "$request" "$tmp/request-pristine.json"

bound_result="$repo/.singular-state/runs/RUN-HOST/audit-verification.json"
expect_verify_rejected() {
  local label="$1" candidate_request="$2" candidate_report="$3"
  if python3 "$ROOT/engine/gate-report.py" verify-verification-result \
      --request "$candidate_request" --report "$candidate_report" \
      --task-contract "$bound_task_contract" --policy-contract "$policy" \
      --expected-task TASK-1107 --expected-run RUN-HOST \
      --expected-head "$head_sha" --expected-tree "$tree_sha" \
      --expected-suite task-contract-gate \
      --expected-campaign legacy \
      --current-task-contract "$repo/docs/orchestration/tasks/TASK-1107.md" \
      --require-pass >/dev/null 2>&1; then
    fail "$label verification binding was accepted"
  fi
}

expect_verify_rejected missing-request "$tmp/absent-request.json" "$bound_result"
expect_verify_rejected missing-result "$tmp/request-pristine.json" "$tmp/absent-result.json"

if python3 "$ROOT/engine/gate-report.py" verify-verification-result \
    --request "$tmp/request-pristine.json" --report "$bound_result" \
    --task-contract "$bound_task_contract" --policy-contract "$policy" \
    --expected-task TASK-1107 --expected-run RUN-HOST \
    --expected-head "$head_sha" --expected-tree "$tree_sha" \
    --expected-suite task-contract-gate \
    --expected-campaign campaign:replacement --require-pass \
    >/dev/null 2>&1; then
  fail "obsolete verification campaign was relabeled as current"
fi

cp "$policy" "$tmp/policy-pristine.json"
printf '{"campaign":"campaign:test","policy":"mutated"}\n' >"$policy"
expect_verify_rejected mutated-policy "$tmp/request-pristine.json" "$bound_result"
cp "$tmp/policy-pristine.json" "$policy"

cp "$bound_task_contract" "$tmp/task-contract-pristine.md"
printf '\nGate command: `false`\n' >>"$bound_task_contract"
expect_verify_rejected mutated-task "$tmp/request-pristine.json" "$bound_result"
cp "$tmp/task-contract-pristine.md" "$bound_task_contract"

cp "$bound_result" "$tmp/mutated-command.json"
python3 - "$tmp/mutated-command.json" <<'PY'
import json, sys
path = sys.argv[1]
report = json.load(open(path, encoding="utf-8"))
report["command"] = "false"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(report, handle)
PY
expect_verify_rejected mutated-command "$tmp/request-pristine.json" "$tmp/mutated-command.json"

cp "$bound_result" "$tmp/mutated-head.json"
python3 - "$tmp/mutated-head.json" <<'PY'
import json, sys
path = sys.argv[1]
report = json.load(open(path, encoding="utf-8"))
report["headSha"] = "b" * 40
with open(path, "w", encoding="utf-8") as handle:
    json.dump(report, handle)
PY
expect_verify_rejected mutated-head "$tmp/request-pristine.json" "$tmp/mutated-head.json"

cp "$tmp/request-pristine.json" "$tmp/mutated-tree.json"
python3 - "$tmp/mutated-tree.json" <<'PY'
import json, sys
path = sys.argv[1]
request = json.load(open(path, encoding="utf-8"))
request["treeSha"] = "c" * 40
with open(path, "w", encoding="utf-8") as handle:
    json.dump(request, handle)
PY
expect_verify_rejected mutated-tree "$tmp/mutated-tree.json" "$bound_result"

# Lifecycle status is intentionally mutable. The immutable snapshot still
# rejects semantic task changes while a ready -> accepted status transition is
# valid at the acceptance boundary.
sed -i.bak 's/^Status: ready$/Status: accepted/' \
  "$repo/docs/orchestration/tasks/TASK-1107.md"
python3 "$ROOT/engine/gate-report.py" verify-verification-result \
  --request "$tmp/request-pristine.json" --report "$bound_result" \
  --task-contract "$bound_task_contract" --policy-contract "$policy" \
  --expected-task TASK-1107 --expected-run RUN-HOST \
  --expected-head "$head_sha" --expected-tree "$tree_sha" \
  --current-task-contract "$repo/docs/orchestration/tasks/TASK-1107.md" \
  --require-pass >/dev/null
rm "$repo/docs/orchestration/tasks/TASK-1107.md.bak"

# Packet commands cannot redirect host execution. Tampering any request binding
# fails before launch, and changing result logs fails closed.
python3 - "$request" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["packetCommand"]="touch /tmp/forbidden"
json.dump(d, open(p,"w"))
PY
if (cd "$repo" && "$ROOT/engine/gate-check.sh" RUN-MALICIOUS \
    --task-id TASK-1107 \
    --verification-request "$request" \
    --task-contract "$bound_task_contract" \
    --policy-contract "$policy" --attempt 2) >/dev/null 2>&1; then
  fail "request with packet command was accepted"
fi
cp "$tmp/request-pristine.json" "$request"
cp "$repo/.singular-state/runs/RUN-HOST/gate-check.log" "$tmp/gate-check-pristine.log"
printf 'tampered\n' >>"$repo/.singular-state/runs/RUN-HOST/gate-check.log"
if python3 "$ROOT/engine/gate-report.py" verify-verification-result \
  --request "$tmp/request-pristine.json" --report "$result" \
  --task-contract "$bound_task_contract" \
  --policy-contract "$policy" --require-pass >/dev/null 2>&1; then
  fail "changed verification log was accepted"
fi
cp "$tmp/gate-check-pristine.log" "$repo/.singular-state/runs/RUN-HOST/gate-check.log"

# A passed-looking report with a nonzero recorded verification result is never
# acceptance evidence, even when its hashes are freshly rebound.
cp "$repo/.singular-state/runs/RUN-HOST/audit-verification.json" "$tmp/nonzero-pass.json"
python3 - "$tmp/nonzero-pass.json" <<'PY'
import json, sys
path = sys.argv[1]
report = json.load(open(path, encoding="utf-8"))
report["rawExitCode"] = 9
with open(path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
python3 "$ROOT/engine/gate-report.py" bind-head \
  --report "$tmp/nonzero-pass.json" --head-sha "$head_sha"
python3 "$ROOT/engine/gate-report.py" bind-verification-result \
  --request "$tmp/request-pristine.json" --report "$tmp/nonzero-pass.json" \
  --task-contract "$bound_task_contract" \
  --policy-contract "$policy"
if python3 "$ROOT/engine/gate-report.py" verify-verification-result \
    --request "$tmp/request-pristine.json" --report "$tmp/nonzero-pass.json" \
    --task-contract "$bound_task_contract" \
    --policy-contract "$policy" --expected-task TASK-1107 \
    --expected-run RUN-HOST --expected-head "$head_sha" \
    --expected-tree "$tree_sha" --require-pass >/dev/null 2>&1; then
  fail "passed report with nonzero verification result was accepted"
fi

# The integration acceptance helper consumes the same validator. A verdict
# string alone cannot bless missing or rejected verification artifacts.
packet="$tmp/packet.json"
audit="$tmp/audit.json"
cat >"$packet" <<JSON
{"schema":"singular.orchestration.state-packet.v0","runId":"RUN-HOST","taskId":"TASK-1107","branch":"fixture/audit","headSha":"$head_sha","status":"accepted","evidence":[{"kind":"audit-verification","ref":"runs/RUN-HOST/audit-verification.json"}]}
JSON
cat >"$audit" <<JSON
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-1107","runId":"RUN-HOST","branch":"fixture/audit","verdict":"accepted","evidenceReviewed":["reviewed-head-sha:$head_sha"]}
JSON
if SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
    bash -c '. "$1"; singular_campaign_binding(){ printf "%s\n" legacy; }; singular_packet_acceptance_mode "$2" "$3"' \
      _ "$ROOT/engine/lib.sh" "$packet" "$audit" >/dev/null 2>&1; then
  :
else
  fail "valid bound verification was rejected by packet acceptance"
fi
for bad_heads in missing mismatched duplicate; do
  case "$bad_heads" in
    missing) reviewed='[]' ;;
    mismatched) reviewed='["reviewed-head-sha:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' ;;
    duplicate) reviewed="[\"reviewed-head-sha:$head_sha\",\"reviewed-head-sha:$head_sha\"]" ;;
  esac
  python3 - "$audit" "$reviewed" <<'PY'
import json, sys
path, reviewed = sys.argv[1:3]
data = json.load(open(path, encoding="utf-8"))
data["evidenceReviewed"] = json.loads(reviewed)
json.dump(data, open(path, "w", encoding="utf-8"))
PY
  if SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
      SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
      SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
      SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
      bash -c '. "$1"; singular_campaign_binding(){ printf "%s\n" legacy; }; singular_packet_acceptance_mode "$2" "$3"' \
        _ "$ROOT/engine/lib.sh" "$packet" "$audit" >/dev/null 2>&1; then
    fail "packet acceptance accepted $bad_heads v1 reviewed-head markers"
  fi
done
cat >"$audit" <<JSON
{"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-1107","runId":"RUN-HOST","branch":"fixture/audit","verdict":"accepted","evidenceReviewed":["reviewed-head-sha:$head_sha"]}
JSON
if ! SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
    bash -c '. "$1"; singular_campaign_binding(){ printf "%s\n" legacy; }; singular_packet_acceptance_mode "$2" "$3"' \
      _ "$ROOT/engine/lib.sh" "$packet" "$audit" >/dev/null 2>&1; then
  fail "packet acceptance rejected explicit marker-bound v0 compatibility"
fi
printf '%s\n' '{"schema":"singular.orchestration.audit-verdict.v9","verdict":"accepted"}' \
  >"$audit"
if SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
    bash -c '. "$1"; singular_campaign_binding(){ printf "%s\n" legacy; }; singular_packet_acceptance_mode "$2" "$3"' \
      _ "$ROOT/engine/lib.sh" "$packet" "$audit" >/dev/null 2>&1; then
  fail "packet acceptance accepted an unknown audit schema"
fi
cat >"$audit" <<JSON
{"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-1107","runId":"RUN-HOST","branch":"fixture/audit","verdict":"accepted","evidenceReviewed":["reviewed-head-sha:$head_sha"]}
JSON
mv "$repo/.singular-state/runs/RUN-HOST/verification-request-2.json" \
  "$repo/.singular-state/runs/RUN-HOST/verification-request-2.missing"
if SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
    bash -c '. "$1"; singular_campaign_binding(){ printf "%s\n" legacy; }; singular_packet_acceptance_mode "$2" "$3"' \
      _ "$ROOT/engine/lib.sh" "$packet" "$audit" >/dev/null 2>&1; then
  fail "packet acceptance ignored a missing verification request"
fi

# A new commit can retain the exact same tree. Fresh gate evidence for that
# commit still cannot reuse the prior commit's accepted audit marker.
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.local \
  commit -q --allow-empty -m 'same tree, new commit'
same_tree_head="$(git -C "$repo" rev-parse HEAD)"
[[ "$(git -C "$repo" rev-parse 'HEAD^{tree}')" == "$tree_sha" ]] \
  || fail "empty-commit stale-audit fixture changed the tree"
request3="$repo/.singular-state/runs/RUN-HOST/verification-request-3.json"
snapshot3="$repo/.singular-state/runs/RUN-HOST/verification-task-contract-3.md"
policy3="$repo/.singular-state/runs/RUN-HOST/verification-policy-3.json"
cp "$bound_task_contract" "$snapshot3"
cp "$policy" "$policy3"
python3 "$ROOT/engine/gate-report.py" create-verification-request \
  --output "$request3" --task-id TASK-1107 --run-id RUN-HOST --attempt 3 \
  --head-sha "$same_tree_head" --tree-sha "$tree_sha" --campaign legacy \
  --task-contract "$snapshot3" --policy-contract "$policy3" \
  --suite-id task-contract-gate >/dev/null
(cd "$repo" && "$ROOT/engine/gate-check.sh" RUN-HOST \
  --task-id TASK-1107 --verification-request "$request3" \
  --task-contract "$snapshot3" --policy-contract "$policy3" --attempt 3) \
  >/dev/null
cp "$repo/.singular-state/runs/RUN-HOST/gate-report.json" \
  "$repo/.singular-state/runs/RUN-HOST/audit-verification.json"
python3 - "$packet" "$audit" "$same_tree_head" "$head_sha" <<'PY'
import json, sys
packet_path, audit_path, current_head, stale_head = sys.argv[1:5]
packet = json.load(open(packet_path, encoding="utf-8"))
packet["headSha"] = current_head
json.dump(packet, open(packet_path, "w", encoding="utf-8"))
audit = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-1107",
    "runId": "RUN-HOST",
    "branch": "fixture/audit",
    "verdict": "accepted",
    "evidenceReviewed": ["reviewed-head-sha:" + stale_head],
}
json.dump(audit, open(audit_path, "w", encoding="utf-8"))
PY
if SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
    bash -c '. "$1"; singular_campaign_binding(){ printf "%s\n" legacy; }; singular_packet_acceptance_mode "$2" "$3"' \
      _ "$ROOT/engine/lib.sh" "$packet" "$audit" >/dev/null 2>&1; then
  fail "same-tree changed-commit candidate reused a stale accepted audit"
fi

echo "PASS: test-verification-responsibility"
