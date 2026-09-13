#!/usr/bin/env bash
set -euo pipefail

# OS-enforced read-only for claude-run.sh. A mock `claude` attempts create,
# open-for-write, rename and unlink inside the worktree and reports how many
# raised PermissionError. Under --level readonly those four must fail; l2 must
# still be able to write. The evidence broker's fail-closed path (REQUIRE=1 with
# a missing sandbox-exec) must exit 78 without launching the mock.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
CLAUDE_RUN="$SCRIPT_DIR/claude-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if [[ ! -x /usr/bin/sandbox-exec ]]; then
  echo "PASS: test-claude-readonly-os-sandbox (skipped: /usr/bin/sandbox-exec absent)"
  exit 0
fi

# Nested seatbelt (this process already sandboxed) cannot apply another profile.
# The 4/4 denial proof is skipped in that case; REQUIRE=1 and l2 still run.
sandbox_apply_ok="no"
if /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
  sandbox_apply_ok="yes"
fi

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-claude-os-sandbox.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

# Mock claude: record argv, then try the four mutating operations the host
# verified sandbox-exec denies. Count PermissionError. Writes the count into
# the envelope result so the runner's --output-last-message captures it.
# MOCK_ARGS_OUT and MOCK_LAUNCHED live outside the denied worktree subpaths.
cat >"$bindir/claude" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_LAUNCHED:-}" ]] && printf 'launched\n' >"$MOCK_LAUNCHED"
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" >"$MOCK_ARGS_OUT"
cat >/dev/null 2>&1 || true
python3 - <<'PY'
import json, os, sys
wt = os.getcwd()
errors = 0
try:
    open(os.path.join(wt, "sandbox-create"), "x").close()
except PermissionError:
    errors += 1
try:
    open(os.path.join(wt, "existing-file"), "w").close()
except PermissionError:
    errors += 1
try:
    os.rename(os.path.join(wt, "rename-src"), os.path.join(wt, "rename-dst"))
except PermissionError:
    errors += 1
try:
    os.unlink(os.path.join(wt, "unlink-me"))
except PermissionError:
    errors += 1
print(json.dumps({
    "type": "result", "subtype": "success", "is_error": False,
    "result": str(errors),
}))
PY
MOCK
chmod +x "$bindir/claude"

export PATH="$bindir:$PATH"
export SINGULAR_TARGET_BRANCH="test-target"
export SINGULAR_CLAUDE_MAX_BUDGET_USD=0

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.singular-state/\n' > .gitignore \
      && printf 'seed\n' > existing-file \
      && printf 'src\n' > rename-src \
      && printf 'gone\n' > unlink-me \
      && git add .gitignore existing-file rename-src unlink-me \
      && git commit -qm init \
      && git branch "$SINGULAR_TARGET_BRANCH" )
}

run_claude() {
  local repo="$1"; shift
  ( cd "$repo" && \
      SINGULAR_ROOT="$repo" \
      SINGULAR_STATE_DIR="$repo/.singular-state" \
      SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      "$CLAUDE_RUN" "$@" )
}

# --- readonly: 4/4 PermissionError, disallowedTools kept, profile names worktree
if [[ "$sandbox_apply_ok" != "yes" ]]; then
  pass "readonly 4/4 skipped (sandbox_apply not permitted in this process)"
else
repo="$workroot/ro"
new_repo "$repo"
out="$workroot/ro-last.json"
args_out="$workroot/ro-args.txt"
log="$workroot/ro.log"
run_id="RUN-os-ro"
if ! run_claude "$repo" --worktree "$repo" --level readonly --run-id "$run_id" \
    --prompt-file /dev/null --output-last-message "$out" \
    >"$log" 2>&1; then
  tail -40 "$log" >&2
  fail "readonly os-sandbox run failed"
fi
[[ -f "$out" ]] || fail "readonly: missing last-message"
denied="$(cat "$out")"
[[ "$denied" == "4" ]] || fail "readonly: expected 4/4 PermissionError, got '$denied'"
run_dir="$repo/.singular-state/runs/$run_id"
profile="$run_dir/claude-readonly-sandbox.sb"
[[ -f "$profile" ]] || fail "readonly: missing sandbox profile $profile"
repo_real="$(cd "$repo" && pwd -P)"
grep -F "$repo_real" "$profile" >/dev/null \
  || fail "readonly: profile does not name the worktree ($repo_real)"
grep -F '(version 1)' "$profile" >/dev/null || fail "readonly: profile missing version"
grep -F '(allow default)' "$profile" >/dev/null || fail "readonly: profile missing allow default"
grep -F 'claude-run: readonly os-sandbox=sandbox-exec profile=' "$log" >/dev/null \
  || fail "readonly: missing os-sandbox stderr line"
# argv recorded by the mock (after sandbox-exec) must still carry tool denials.
# Re-run with MOCK_ARGS_OUT: the first run already happened; spawn a second
# readonly invocation that records argv. The worktree is restored by the guard,
# so recreate the mutation targets.
( cd "$repo" && printf 'seed\n' > existing-file && printf 'src\n' > rename-src \
    && printf 'gone\n' > unlink-me )
MOCK_ARGS_OUT="$args_out" run_claude "$repo" --worktree "$repo" --level readonly \
  --run-id "RUN-os-ro-args" --prompt-file /dev/null \
  --output-last-message "$workroot/ro-last-2.json" >/dev/null 2>&1 \
  || fail "readonly argv-recording run failed"
[[ -f "$args_out" ]] || fail "readonly: mock did not record argv"
grep -F -- '--disallowedTools' "$args_out" >/dev/null \
  || fail "readonly: --disallowedTools missing from recorded argv"
pass "readonly os-sandbox denies 4/4 and keeps tool denials"
fi

# --- REQUIRE=1 with a missing sandbox-exec: exit 78, mock never launched
repo2="$workroot/require"
new_repo "$repo2"
launched="$workroot/require-launched"
require_log="$workroot/require.log"
set +e
SINGULAR_RUNNER_REQUIRE_OS_READONLY=1 \
SINGULAR_CLAUDE_SANDBOX_EXEC=/nonexistent \
MOCK_LAUNCHED="$launched" \
  run_claude "$repo2" --worktree "$repo2" --level readonly --run-id RUN-os-req \
    --prompt-file /dev/null --output-last-message "$workroot/require-last.json" \
    >"$require_log" 2>&1
require_rc=$?
set -e
[[ "$require_rc" -eq 78 ]] || fail "require: expected exit 78, got $require_rc"
grep -F 'OS-enforced read-only is required for this invocation but unavailable' \
  "$require_log" >/dev/null \
  || fail "require: missing unavailable diagnostic"
[[ ! -e "$launched" ]] || fail "require: mock was invoked"
pass "REQUIRE_OS_READONLY=1 with missing sandbox-exec exits 78 without launch"

# --- l2: mock is not sandboxed and can write
repo3="$workroot/l2"
new_repo "$repo3"
l2_out="$workroot/l2-last.json"
l2_log="$workroot/l2.log"
run_claude "$repo3" --worktree "$repo3" --level l2 --run-id RUN-os-l2 \
  --prompt-file /dev/null --output-last-message "$l2_out" \
  >"$l2_log" 2>&1 || { tail -40 "$l2_log" >&2; fail "l2 run failed"; }
l2_denied="$(cat "$l2_out")"
[[ "$l2_denied" == "0" ]] || fail "l2: expected 0 PermissionError (writes allowed), got '$l2_denied'"
[[ -f "$repo3/sandbox-create" ]] || fail "l2: mock create did not persist"
[[ -f "$repo3/rename-dst" ]] || fail "l2: mock rename did not persist"
[[ ! -f "$repo3/unlink-me" ]] || fail "l2: mock unlink did not persist"
grep -F 'os-sandbox=sandbox-exec' "$l2_log" >/dev/null \
  && fail "l2: OS sandbox was applied (argv must stay byte-identical)"
pass "l2 lets the mock write and does not apply os-sandbox"

echo "PASS: test-claude-readonly-os-sandbox"
