#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-integration-exact-tree.sh requires bash >= 4" >&2
  exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A private session owns every fixture descendant. Strip inherited engine selection
# only in the child environment; the caller's campaign remains untouched.
if [[ "${EXACT_TREE_PRIVATE_CHILD:-}" != 1 ]]; then
  exec python3 - "$0" "$ENGINE_HOME" <<'PYWRAP'
import os, pathlib, shutil, signal, subprocess, sys, tempfile, time
scratch = tempfile.mkdtemp(prefix='exact-tree-')
env = {k: v for k, v in os.environ.items() if not k.startswith('SINGULAR_')}
repo = scratch + '/repo'
state = repo + '/.singular-state'
env.update(EXACT_TREE_PRIVATE_CHILD='1', EXACT_TREE_TMP=scratch, TMPDIR=scratch,
    SINGULAR_ROOT=repo, SINGULAR_ORCH_DIR=repo+'/docs/orchestration',
    SINGULAR_TASKS_DIR=repo+'/docs/orchestration/tasks', SINGULAR_STATE_DIR=state,
    SINGULAR_WORKTREES_DIR=repo+'/.worktrees', SINGULAR_RUNS_DIR=state+'/runs',
    SINGULAR_RUNTIME_DIR=state+'/runtime', SINGULAR_ENGINE_HOME=sys.argv[2],
    SINGULAR_JSON_CONFIG_FILE=repo+'/singular.config.json',
    SINGULAR_CONFIG_FILE=repo+'/singular.config.sh',
    SINGULAR_LOCAL_CONFIG_FILE=state+'/config.local.sh')
def signal_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except PermissionError:
        # macOS may report EPERM for a group containing only reparented zombies.
        # Confirm there are no live members; real permission failures stay fatal.
        rows = subprocess.check_output(['ps', '-axo', 'pgid=,stat='], text=True)
        members = [row.split()[1] for row in rows.splitlines()
                   if len(row.split()) == 2 and row.split()[0] == str(pgid)]
        if any(not state.startswith('Z') for state in members):
            raise
        raise ProcessLookupError(pgid)

proc = None
rc = 1
def interrupted(signum, frame):
    print('fixture interrupted: signal ' + str(signum), file=sys.stderr)
    raise SystemExit(128 + signum)
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, interrupted)
try:
    proc = subprocess.Popen(['bash', sys.argv[1]], env=env, start_new_session=True)
    if os.environ.get('EXACT_TREE_PROCESS_RECORD'):
        pathlib.Path(os.environ['EXACT_TREE_PROCESS_RECORD']).write_text(str(proc.pid))
    try:
        rc = proc.wait(timeout=45)
    except subprocess.TimeoutExpired:
        print('FAIL: fixture lifecycle timed out', file=sys.stderr)
        rc = 1
finally:
    if proc is not None:
        # Stop the complete private process group, including gate grandchildren.
        try: signal_group(proc.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: proc.wait(timeout=2)
        except subprocess.TimeoutExpired: pass
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try: signal_group(proc.pid, 0)
            except ProcessLookupError: break
            time.sleep(0.02)
        try: signal_group(proc.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        proc.wait()
    for log in pathlib.Path(scratch).glob('*.out'):
        if rc: print(log.name + ':\n' + log.read_text(), file=sys.stderr)
    if rc:
        for log in pathlib.Path(scratch).rglob('gate-check.log'):
            print(str(log.relative_to(scratch)) + ':\n' + log.read_text(), file=sys.stderr)
    shutil.rmtree(scratch)
sys.exit(rc if rc >= 0 else 128-rc)
PYWRAP
fi
tmp="$EXACT_TREE_TMP"
watcher_pid=""
integrator_pid=""
cleanup() {
  local rc=$?
  trap - EXIT
  for pid in "$watcher_pid" "$integrator_pid"; do
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
  done
  for pid in "$watcher_pid" "$integrator_pid"; do
    [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
  done
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
fail() { echo "FAIL: $*" >&2; exit 1; }
await_latch() {
  local path=$1 label=$2 deadline=$((SECONDS + 20))
  while [[ ! -e "$path" ]]; do
    (( SECONDS < deadline )) || fail "$label timed out"
    sleep 0.01
  done
}
run_integrator() {
  local output=$1; shift
  rm -f "$tmp/integrator-status"
  (
    trap - EXIT
    set +e
    if [[ "${EXACT_TREE_TEST_FAILURE:-}" == integrator ]]; then
      echo 'injected integrator failure' >&2
      rc=37
    else
      "$@"
      rc=$?
    fi
    printf '%s\n' "$rc" >"$tmp/integrator-status.tmp"
    mv "$tmp/integrator-status.tmp" "$tmp/integrator-status"
    exit "$rc"
  ) >"$output" 2>&1 &
  integrator_pid=$!
  local deadline=$((SECONDS + 30)) rc
  while [[ ! -e "$tmp/integrator-status" ]]; do
    if [[ -e "$tmp/watcher-status" ]]; then
      rc=$(cat "$tmp/watcher-status")
      if [[ "$rc" != 0 ]]; then
        cat "$tmp/watcher.out" >&2
        exit "$rc"
      fi
    fi
    (( SECONDS < deadline )) || fail 'integrator timed out'
    sleep 0.01
  done
  rc=$(cat "$tmp/integrator-status")
  wait "$integrator_pid" || true
  integrator_pid=""
  if [[ "$rc" == 2 ]] && grep -q 'merge committed but durable candidate finalization failed' "$output"; then
    return "$rc"
  fi
  if [[ "$rc" != 0 ]] && ! grep -q campaign-publication-lock-timeout "$output"; then
    cat "$output" >&2
    exit "$rc"
  fi
  return "$rc"
}
repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/tasks" \
  "$repo/docs/orchestration/packets/imported/TASK-0401" \
  "$repo/.singular-state"
: >"$repo/singular.config.sh"
: >"$repo/.singular-state/config.local.sh"
git -C "$repo" init -q
git -C "$repo" checkout -q -b target
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.local

cat >"$repo/singular.config.json" <<'JSON'
{
  "schemaVersion": "v2",
  "targetBranch": "target",
  "gateCommand": "bash integration-gate.sh",
  "bootstrap": {"required": false, "commands": []}
}
JSON
cat >"$repo/integration-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FORCE_GATE_RED:-0}" != 1 ]] || exit 1
if [[ -n "${MAIN_DIRT_READY:-}" ]]; then
  deadline=$((SECONDS + 8))
  while [[ ! -f "$MAIN_DIRT_READY" ]]; do
    (( SECONDS < deadline )) || { echo "dirt-ready timed out" >&2; exit 1; }
    sleep 0.01
  done
fi
[[ -z "${GATE_PWD_FILE:-}" ]] || printf '%s\n' "$PWD" >"$GATE_PWD_FILE"
[[ "$(cat app.txt)" == "merged-and-tested" ]]
printf '%s\n' \
  '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$repo/integration-gate.sh"
printf 'base\n' >"$repo/app.txt"
cat >"$repo/docs/orchestration/tasks/TASK-0401.md" <<'EOF'
# TASK-0401: Exact integration tree

Status: accepted
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-0401-exact-tree`
Test policy: `strict_test_first`
Gate command: `bash integration-gate.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Prove the exact staged merge tree.

## Scope

Owned files:

- `app.txt`
EOF
printf '%s\n' '.singular-state/' '.singular-cache/' '.singular-evidence/' '.worktrees/' \
  >"$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit -qm fixture

git -C "$repo" checkout -q -b agent/core/TASK-0401-exact-tree
printf 'merged-and-tested\n' >"$repo/app.txt"
git -C "$repo" add app.txt
git -C "$repo" commit -qm feature
feature_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q target

packet="$repo/docs/orchestration/packets/imported/TASK-0401/RUN-EXACT.json"
cat >"$packet" <<JSON
{
  "schema": "singular.orchestration.state-packet.v0",
  "packetId": "RUN-EXACT",
  "runId": "RUN-EXACT",
  "taskId": "TASK-0401",
  "area": "core",
  "role": "l2-developer",
  "status": "accepted",
  "baseRef": "target",
  "branch": "agent/core/TASK-0401-exact-tree",
  "headSha": "$feature_head",
  "workspace": "$repo",
  "ownedFiles": ["app.txt"],
  "changedFiles": ["app.txt"],
  "commands": [{"cmd": "bash integration-gate.sh", "exitCode": 0}],
  "tests": [{"name": "exact-tree", "phase": "regression", "status": "passed"}],
  "evidence": [{"kind": "test", "ref": "exact-tree"}],
  "blockers": [],
  "nextAction": "integrate",
  "createdAt": "2026-08-30T00:00:00Z"
}
JSON
cat >"${packet%.json}.audit.json" <<'JSON'
{
  "schema": "singular.orchestration.audit-verdict.v0",
  "taskId": "TASK-0401",
  "runId": "RUN-EXACT",
  "branch": "agent/core/TASK-0401-exact-tree",
  "verdict": "accepted",
  "evidenceReviewed": ["exact-tree"],
  "commandsRun": ["bash integration-gate.sh"],
  "findings": [],
  "requiredFixes": [],
  "rationale": "fixture accepted"
}
JSON
git -C "$repo" add docs/orchestration/packets
git -C "$repo" commit -qm packet
target_parent="$(git -C "$repo" rev-parse HEAD)"

# A green exact-tree gate is not permission to commit after the campaign
# publication boundary becomes unavailable. Hold the campaign lock only after
# the merge is staged, let the gate pass, and force the final lock acquisition
# to time out. The merge/index/task-status mutation must be fully aborted.
lock_fail_dirt_ready="$tmp/lock-fail-dirt-ready"
lock_fail_release="$tmp/lock-fail-release"
lock_fail_gate_pwd="$tmp/lock-fail-gate-pwd"
lock_fail_out="$tmp/integrate-lock-fail.out"
(
  trap 'rc=$?; type singular_campaign_lock_release >/dev/null 2>&1 && singular_campaign_lock_release || true; echo "$rc" >"$tmp/watcher-status.tmp"; mv "$tmp/watcher-status.tmp" "$tmp/watcher-status"' EXIT
  trap 'exit 143' TERM
  if [[ "${EXACT_TREE_TEST_FAILURE:-}" == watcher ]]; then
    echo 'injected watcher failure' >&2
    exit 38
  fi
  await_latch "$repo/.git/MERGE_HEAD" MERGE_HEAD
  export SINGULAR_ROOT="$repo"
  export SINGULAR_STATE_DIR="$repo/.singular-state"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  # shellcheck source=/dev/null
  source "$ENGINE_HOME/engine/lib.sh"
  singular_campaign_lock_acquire
  printf 'poison-lock-fail-main-worktree\n' >"$repo/app.txt"
  [[ "${EXACT_TREE_TEST_FAILURE:-}" == latch ]] || : >"$lock_fail_dirt_ready"
  # The parent releases us only after integrate returns. This makes the race
  # independent of machine speed while the publisher's 0.2s bounded wait
  # still guarantees the test itself terminates.
  await_latch "$lock_fail_release" release
  singular_campaign_lock_release
) >"$tmp/watcher.out" 2>&1 &
watcher_pid=$!
lock_fail_rc=0
run_integrator "$lock_fail_out" env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_AUTO_PROMOTE_GATES=0 \
  SINGULAR_PUSH=0 \
  SINGULAR_CAMPAIGN_LOCK_WAIT_TICKS=2 \
  MAIN_DIRT_READY="$lock_fail_dirt_ready" \
  GATE_PWD_FILE="$lock_fail_gate_pwd" \
  bash "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0401 --run-id RUN-LOCK-FAIL \
  || lock_fail_rc=$?
: >"$lock_fail_release"
wait "$watcher_pid"
watcher_pid=""
[[ "$lock_fail_rc" -ne 0 ]] \
  || fail "campaign publication lock timeout unexpectedly integrated: $(cat "$lock_fail_out")"
grep -q 'campaign-publication-lock-timeout' "$lock_fail_out" \
  || fail "campaign lock timeout reason missing: $(cat "$lock_fail_out")"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$target_parent" ]] \
  || fail "campaign lock timeout advanced target HEAD"
[[ ! -e "$repo/.git/MERGE_HEAD" ]] \
  || fail "campaign lock timeout left an in-progress merge"
git -C "$repo" diff --cached --quiet \
  || fail "campaign lock timeout left staged integration bytes"
grep -q '^Status: accepted$' "$repo/docs/orchestration/tasks/TASK-0401.md" \
  || fail "campaign lock timeout retained the staged integrated task status"
[[ "$(cat "$repo/app.txt")" == "poison-lock-fail-main-worktree" ]] \
  || fail "campaign lock timeout destroyed a concurrent worktree edit"
git -C "$repo" restore --worktree -- app.txt

# The mutation happens only after integrate's clean-worktree preflight and
# merge staging. An old in-place gate reads "poison-main-worktree" and fails;
# the exact-tree disposable gate reads the staged "merged-and-tested" bytes.
rm -f "$tmp/watcher-status"
main_dirt_ready="$tmp/main-dirt-ready"
gate_pwd_file="$tmp/gate-pwd"
(
  trap 'rc=$?; type singular_campaign_lock_release >/dev/null 2>&1 && singular_campaign_lock_release || true; echo "$rc" >"$tmp/watcher-status.tmp"; mv "$tmp/watcher-status.tmp" "$tmp/watcher-status"' EXIT
  trap 'exit 143' TERM
  if [[ "${EXACT_TREE_TEST_FAILURE:-}" == watcher ]]; then
    echo 'injected watcher failure' >&2
    exit 38
  fi
  await_latch "$repo/.git/MERGE_HEAD" MERGE_HEAD
  printf 'poison-main-worktree\n' >"$repo/app.txt"
  : >"$main_dirt_ready"
) >"$tmp/watcher.out" 2>&1 &
watcher_pid=$!

out="$tmp/integrate.out"
cat >"$tmp/fail-candidate-finalize.py" <<PY
import os
import sys
if len(sys.argv) > 1 and sys.argv[1] == "candidate-integrated":
    raise SystemExit(2)
os.execv(sys.executable, [sys.executable, "$ENGINE_HOME/engine/task_lifecycle.py", *sys.argv[1:]])
PY
integration_rc=0
run_integrator "$out" env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_AUTO_PROMOTE_GATES=0 \
  SINGULAR_PUSH=0 \
  SINGULAR_TASK_LIFECYCLE="$tmp/fail-candidate-finalize.py" \
  MAIN_DIRT_READY="$main_dirt_ready" \
  GATE_PWD_FILE="$gate_pwd_file" \
  bash "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0401 --run-id RUN-EXACT \
  || integration_rc=$?
wait "$watcher_pid"
watcher_pid=""

grep -q '^INTEGRATED TASK-0401:' "$out" || fail "integration did not complete: $(cat "$out")"
[[ "$integration_rc" -ne 0 ]] || fail "fixture did not interrupt candidate publication"
grep -q 'merge committed but durable candidate finalization failed' "$out" \
  || fail "candidate publication interruption was not exposed: $(cat "$out")"
[[ "$(cat "$gate_pwd_file")" != "$repo" ]] || fail "integration gate ran in the dirty main checkout"
[[ "$(git -C "$repo" show HEAD:app.txt)" == "merged-and-tested" ]] \
  || fail "committed tree did not preserve the tested staged bytes"
[[ "$(cat "$repo/app.txt")" == "poison-main-worktree" ]] \
  || fail "fixture did not retain distinct unstaged main-checkout bytes"
merge_commit="$(git -C "$repo" rev-parse HEAD)"
[[ "$(git -C "$repo" rev-list --parents -n 1 HEAD)" == \
    "$merge_commit $target_parent $feature_head" ]] \
  || fail "committed merge parents differ from the tested synthetic parents"
[[ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" == 1 ]] \
  || fail "disposable integration gate worktree leaked"

# The durable receipt recovers the exact integration commit after the target
# advances. It must not record the later target tip as the merge identity.
git -C "$repo" restore --worktree -- app.txt
printf 'later target work\n' >"$repo/later.txt"
git -C "$repo" add later.txt
git -C "$repo" commit -qm later
later_target="$(git -C "$repo" rev-parse HEAD)"
recovery_out="$tmp/integrate-recovery.out"
env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_AUTO_PROMOTE_GATES=0 \
  SINGULAR_PUSH=0 \
  bash "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0401 --run-id RUN-RECOVER >"$recovery_out" 2>&1 \
  || fail "verified integration recovery failed: $(cat "$recovery_out")"
grep -q "verified integration $merge_commit already reaches target" "$recovery_out" \
  || fail "restart did not recover the exact proven merge: $(cat "$recovery_out")"
python3 - "$repo/.singular-state/leases/TASK-0401.json" "$merge_commit" "$later_target" <<'PY'
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
candidate = lease["acceptedCandidate"]
assert candidate["state"] == "integrated", candidate
assert candidate["mergeCommit"] == sys.argv[2], candidate
assert candidate["mergeCommit"] != sys.argv[3], candidate
assert candidate["integrationProof"]["testedTree"]
assert candidate["integrationProof"]["targetParent"]
assert candidate["integrationProof"]["candidateParent"]
PY

# A failed candidate that is later merged manually is only an ancestor. With
# no green exact-merge receipt, restart retains it as actionable and must not
# publish integrated authority.
mkdir -p "$repo/docs/orchestration/packets/imported/TASK-0402"
cat >"$repo/docs/orchestration/tasks/TASK-0402.md" <<'EOF'
# TASK-0402: Unverified ancestor

Status: accepted
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-0402-unverified`
Test policy: `strict_test_first`
Gate command: `bash integration-gate.sh`
Dispatch mode: canonical
Depends on: []

## Scope

Owned files:

- `manual.txt`
EOF
git -C "$repo" add docs/orchestration/tasks/TASK-0402.md
git -C "$repo" commit -qm task-0402
git -C "$repo" checkout -q -b agent/core/TASK-0402-unverified
printf 'manual candidate\n' >"$repo/manual.txt"
git -C "$repo" add manual.txt
git -C "$repo" commit -qm manual-candidate
manual_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q target
packet2="$repo/docs/orchestration/packets/imported/TASK-0402/RUN-UNVERIFIED.json"
cat >"$packet2" <<JSON
{"runId":"RUN-UNVERIFIED","taskId":"TASK-0402","status":"accepted","branch":"agent/core/TASK-0402-unverified","headSha":"$manual_head","evidence":[]}
JSON
cat >"${packet2%.json}.audit.json" <<'JSON'
{"taskId":"TASK-0402","runId":"RUN-UNVERIFIED","branch":"agent/core/TASK-0402-unverified","verdict":"accepted","evidenceReviewed":[]}
JSON
git -C "$repo" add docs/orchestration/packets/imported/TASK-0402
git -C "$repo" commit -qm packet-0402
red_out="$tmp/integrate-red.out"
red_rc=0
env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_AUTO_PROMOTE_GATES=0 \
  SINGULAR_PUSH=0 \
  FORCE_GATE_RED=1 \
  bash "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0402 --run-id RUN-RED >"$red_out" 2>&1 \
  || red_rc=$?
[[ "$red_rc" -ne 0 ]] || fail "red integration fixture unexpectedly succeeded"
grep -q 'FAILED TASK-0402: post-merge gate red' "$red_out" \
  || fail "fixture did not record a red candidate: $(cat "$red_out")"
git -C "$repo" merge --no-ff -qm 'manual unverified merge' "$manual_head"
manual_merge="$(git -C "$repo" rev-parse HEAD)"
blocked_out="$tmp/integrate-unverified.out"
env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_AUTO_PROMOTE_GATES=0 \
  SINGULAR_PUSH=0 \
  bash "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0402 --run-id RUN-UNVERIFIED-RECOVERY >"$blocked_out" 2>&1 \
  || fail "unverified ancestor recovery did not stay bounded: $(cat "$blocked_out")"
grep -q 'already reachable but integration is unverified' "$blocked_out" \
  || fail "unverified ancestor was not exposed as actionable: $(cat "$blocked_out")"
python3 - "$repo/.singular-state/leases/TASK-0402.json" "$manual_merge" <<'PY'
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
candidate = lease["acceptedCandidate"]
assert lease["status"] == "accepted", lease
assert candidate["state"] == "integration-blocked", candidate
assert candidate.get("mergeCommit") != sys.argv[2], candidate
assert candidate["recoveryBlock"]["reason"] == "unverified-already-merged", candidate
assert "host-tested exact merge proof" in candidate["nextAction"], candidate
PY

echo "PASS: test-integration-exact-tree"
