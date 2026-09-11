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
mkdir -p "$fixture/tests" "$fixture/engine" "$fixture/bin" "$fixture/.git"
cp "$ROOT/tests/run.sh" "$fixture/tests/run.sh"
cp "$ROOT/engine/git-preflight.sh" "$fixture/engine/git-preflight.sh"
cp "$ROOT/engine/bash-guard.sh" "$fixture/engine/bash-guard.sh"
cat >"$fixture/tests/test-supported.sh" <<'SH'
#!/usr/bin/env bash
echo body-ran
SH
cat >"$fixture/bin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse --is-inside-work-tree "*) echo true ;;
  *" rev-parse -q --verify HEAD^{commit} "*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  *" rev-parse HEAD "*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  *" worktree add "*) echo 'fatal: unable to create .git/worktrees/x: Operation not permitted' >&2; exit 128 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fixture/tests/test-supported.sh" "$fixture/bin/git"
out="$(PATH="$fixture/bin:$PATH" SINGULAR_FOCUSED_HOST_REQUIRED=1 \
  bash "$fixture/tests/run.sh" test-supported.sh 2>&1)" \
  || fail "focused supported body did not execute under registry denial: $out"
[[ "$out" == *"HOST_REQUIRED git-registry-write unrun"* ]] \
  || fail "registry denial was not reported as host_required/unrun"
[[ "$out" == *"body-ran"* || "$out" == *"PASS  test-supported.sh"* ]] \
  || fail "focused body did not run"

# A real body failure remains a failure even when the host-only probe is also
# unavailable.
cat >"$fixture/tests/test-supported.sh" <<'SH'
#!/usr/bin/env bash
echo 'AssertionError: deliberate behavior failure' >&2
exit 1
SH
rc=0
out="$(PATH="$fixture/bin:$PATH" SINGULAR_FOCUSED_HOST_REQUIRED=1 \
  bash "$fixture/tests/run.sh" test-supported.sh 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" == *"FAIL  test-supported.sh"* ]] \
  || fail "behavior failure was hidden by infrastructure classification"

# The preflight itself distinguishes source/history, registry permission and
# temporary workspace failures with stable classifications.
set +e
PATH="$fixture/bin:$PATH" bash -c '. "$1"; singular_git_source_preflight "$2"' \
  _ "$ROOT/engine/git-preflight.sh" "$fixture" >"$tmp/preflight.out" 2>&1
rc=$?
set -e
[[ "$rc" == 2 ]] || fail "registry permission did not use its distinct return code"
grep -q 'classification=registry-permission' "$tmp/preflight.out" \
  || fail "registry permission classification missing"

# A host verification request carries identity, never executable authority.
# gate-check resolves the command from the trusted task contract and binds the
# result to contract/attempt/head/tree/campaign/policy/suite/log identities.
repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/tasks" "$repo/.singular-state"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.local
cat >"$repo/trusted-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo trusted-command-ran
[[ -z "${SINGULAR_GATE_REPORT_FILE:-}" ]] || printf '%s\n' \
  '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$repo/trusted-gate.sh"
cat >"$repo/docs/orchestration/tasks/TASK-1107.md" <<'MD'
# TASK-1107: fixture

Gate command: `bash trusted-gate.sh`
MD
printf '{"campaign":"campaign:test","policy":"policy:test"}\n' >"$repo/policy.json"
printf 'fixture\n' >"$repo/data.txt"
git -C "$repo" add .
git -C "$repo" commit -qm fixture
head_sha="$(git -C "$repo" rev-parse HEAD)"
tree_sha="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
request="$tmp/request.json"
python3 "$ROOT/engine/gate-report.py" create-verification-request \
  --output "$request" --task-id TASK-1107 --run-id RUN-VERIFY --attempt 2 \
  --head-sha "$head_sha" --tree-sha "$tree_sha" --campaign campaign:test \
  --task-contract "$repo/docs/orchestration/tasks/TASK-1107.md" \
  --policy-contract "$repo/policy.json" --suite-id focused >/dev/null
python3 - "$request" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert "command" not in d and "commands" not in d
assert d["commandIdentity"]
PY

export SINGULAR_ROOT="$repo"
export SINGULAR_STATE_DIR="$repo/.singular-state"
export SINGULAR_LOCAL_CONFIG_FILE=/dev/null
(cd "$repo" && "$ROOT/engine/gate-check.sh" RUN-HOST \
  --verification-request "$request" \
  --task-contract "$repo/docs/orchestration/tasks/TASK-1107.md" \
  --policy-contract "$repo/policy.json") >/dev/null
result="$repo/.singular-state/runs/RUN-HOST/gate-report.json"
python3 "$ROOT/engine/gate-report.py" verify-verification-result \
  --request "$request" --report "$result" \
  --task-contract "$repo/docs/orchestration/tasks/TASK-1107.md" \
  --policy-contract "$repo/policy.json" >/dev/null

cp "$request" "$tmp/request-pristine.json"

# Packet commands cannot redirect host execution. Tampering any request binding
# fails before launch, and changing result logs fails closed.
python3 - "$request" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["packetCommand"]="touch /tmp/forbidden"
json.dump(d, open(p,"w"))
PY
if (cd "$repo" && "$ROOT/engine/gate-check.sh" RUN-MALICIOUS \
    --verification-request "$request" \
    --task-contract "$repo/docs/orchestration/tasks/TASK-1107.md" \
    --policy-contract "$repo/policy.json") >/dev/null 2>&1; then
  fail "request with packet command was accepted"
fi
printf 'tampered\n' >>"$repo/.singular-state/runs/RUN-HOST/gate-check.log"
if python3 "$ROOT/engine/gate-report.py" verify-verification-result \
    --request "$tmp/request-pristine.json" --report "$result" \
    --task-contract "$repo/docs/orchestration/tasks/TASK-1107.md" \
    --policy-contract "$repo/policy.json" >/dev/null 2>&1; then
  fail "changed verification log was accepted"
fi

echo "PASS: test-verification-responsibility"
