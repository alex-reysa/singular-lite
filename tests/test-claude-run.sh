#!/usr/bin/env bash
set -euo pipefail

# Deterministic contract tests for claude-run.sh. A mock `claude` binary stands
# in for the real CLI so these run offline, for free, and in CI. They assert the
# drop-in contract: final-message capture into --output-last-message, the
# read-only restore guard (untracked + tracked), L2 write-persistence, fenced
# JSON extraction via singular_extract_json, is_error propagation, and L0/L1
# scope-check enforcement.
#
# Capture files (--output-last-message) are written OUTSIDE the repo, mirroring
# real usage where they live under gitignored .singular-state/runs (which the
# read-only restore guard never touches because it excludes ignored files).

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
CLAUDE_RUN="$SCRIPT_DIR/claude-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-claude-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

# --- Mock claude ---------------------------------------------------------------
# Honors env injected per-case:
#   MOCK_RESULT    -> string placed in the envelope .result
#   MOCK_WRITE     -> if set, mock overwrites $MOCK_WRITE to simulate an agent
#                     mutating the working tree (worst case for the read-only guard)
#   MOCK_IS_ERROR  -> "1" makes the envelope is_error=true
cat >"$bindir/claude" <<'MOCK'
#!/usr/bin/env bash
# MOCK_ARGS_OUT: record the argv the runner assembled (to assert --model/--effort).
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
cat >/dev/null 2>&1 || true   # consume the piped prompt
if [[ -n "${MOCK_WRITE:-}" ]]; then printf 'MUTATED\n' > "$MOCK_WRITE"; fi
# MOCK_SLEEP simulates a slow/runaway agentic run; MOCK_MARKER is touched only if
# the sleep completes (i.e. the timeout guard did NOT kill it).
# MOCK_CHILD_OUT runs that sleep as a background DESCENDANT and records its pid,
# so a test can prove a kill reached past the direct child.
if [[ -n "${MOCK_SLEEP:-}" ]]; then
  if [[ -n "${MOCK_CHILD_OUT:-}" ]]; then
    sleep "$MOCK_SLEEP" &
    mock_child=$!
    printf '%s\n' "$mock_child" >"$MOCK_CHILD_OUT"
    wait "$mock_child"
  else
    sleep "$MOCK_SLEEP"
  fi
  [[ -n "${MOCK_MARKER:-}" ]] && touch "$MOCK_MARKER"
fi
python3 - <<PY
import json, os
env = {
  "type": "result", "subtype": "success",
  "is_error": os.environ.get("MOCK_IS_ERROR") == "1",
  "result": os.environ.get("MOCK_RESULT", '{"verdict":"accepted"}'),
}
sid = os.environ.get("MOCK_SESSION_ID")
if sid is not None:
    env["session_id"] = sid
print(json.dumps(env))
PY
MOCK
chmod +x "$bindir/claude"

export PATH="$bindir:$PATH"
export SINGULAR_TARGET_BRANCH="test-target"
export SINGULAR_CLAUDE_MAX_BUDGET_USD=0   # omit budget flag in tests
# These cases exercise the post-run restore guard with a mock that writes into
# the worktree. Disable the OS sandbox so the mock can still mutate; the guard
# remains the second layer this file is pinning.
export SINGULAR_CLAUDE_OS_SANDBOX=0

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.singular-state/\n' > .gitignore && git add .gitignore && git commit -qm init \
      && git branch "$SINGULAR_TARGET_BRANCH" )
}

run_claude_run() {
  local repo="$1"; shift
  ( cd "$repo" && SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" "$CLAUDE_RUN" "$@" )
}

extract() { # extract a field from a captured message file (mirrors singular_extract_json)
  python3 - "$1" "$2" <<'PY'
import json,sys
text=open(sys.argv[1]).read()
def load(s):
    try: return json.loads(s)
    except Exception: return None
o=load(text)
if o is None:
    s=text.strip()
    if s.startswith("```"):
        s=s.split("\n",1)[1] if "\n" in s else s
        if s.rstrip().endswith("```"): s=s.rstrip()[:-3]
    o=load(s)
if o is None:
    i=text.find("{")
    while i!=-1 and o is None:
        depth=0
        for j in range(i,len(text)):
            if text[j]=="{": depth+=1
            elif text[j]=="}":
                depth-=1
                if depth==0: o=load(text[i:j+1]); break
        if o is None: i=text.find("{",i+1)
assert o is not None, "no JSON found"
print(o.get(sys.argv[2],""))
PY
}

i=0; out() { i=$((i+1)); echo "$workroot/out-$i.json"; }

# --- Case 1: L2 capture + packet extraction ------------------------------------
r="$workroot/c1"; new_repo "$r"; o="$(out)"
MOCK_RESULT='{"status":"needs-review","summary":"ok"}' \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ -f "$o" ]] || fail "c1: output file not written"
[[ "$(extract "$o" status)" == "needs-review" ]] || fail "c1: status not extracted"
pass "c1 L2 final-message captured + extractable"

# --- Case 2: L2 write persists (no restore at l2) ------------------------------
r="$workroot/c2"; new_repo "$r"; o="$(out)"
MOCK_RESULT='{"status":"x"}' MOCK_WRITE="$r/created.txt" \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ -f "$r/created.txt" ]] || fail "c2: L2 write should persist"
pass "c2 L2 write persists"

# --- Case 3: readonly removes untracked file the run created -------------------
r="$workroot/c3"; new_repo "$r"; o="$(out)"
MOCK_RESULT='{"verdict":"accepted"}' MOCK_WRITE="$r/sneaky.txt" \
  run_claude_run "$r" --level readonly -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ ! -e "$r/sneaky.txt" ]] || fail "c3: readonly did not remove run-created untracked file"
[[ "$(extract "$o" verdict)" == "accepted" ]] || fail "c3: verdict not extracted"
pass "c3 readonly removes run-created untracked file + verdict captured"

# --- Case 4: readonly reverts a tracked-file modification ----------------------
r="$workroot/c4"; new_repo "$r"; o="$(out)"
printf 'ORIGINAL\n' > "$r/tracked.txt"; ( cd "$r" && git add tracked.txt && git commit -qm seed )
MOCK_RESULT='{"verdict":"needs-fix"}' MOCK_WRITE="$r/tracked.txt" \
  run_claude_run "$r" --level readonly -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ "$(cat "$r/tracked.txt")" == "ORIGINAL" ]] || fail "c4: readonly did not revert tracked mod (got: $(cat "$r/tracked.txt"))"
pass "c4 readonly reverts tracked modification"

# --- Case 5: readonly preserves a pre-existing untracked file (evidence) -------
r="$workroot/c5"; new_repo "$r"; o="$(out)"
printf 'EVIDENCE\n' > "$r/evidence-keep.txt"   # pre-existing untracked
MOCK_RESULT='{"verdict":"accepted"}' \
  run_claude_run "$r" --level readonly -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ -f "$r/evidence-keep.txt" ]] || fail "c5: readonly wrongly removed pre-existing untracked file"
pass "c5 readonly preserves pre-existing untracked evidence"

# --- Case 6: fenced ```json result is still extractable ------------------------
r="$workroot/c6"; new_repo "$r"; o="$(out)"
MOCK_RESULT=$'```json\n{"verdict":"accepted","note":"fenced"}\n```' \
  run_claude_run "$r" --level readonly -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ "$(extract "$o" note)" == "fenced" ]] || fail "c6: fenced JSON not extracted"
pass "c6 fenced JSON result extractable"

# --- Case 7: is_error propagates to a nonzero exit ----------------------------
r="$workroot/c7"; new_repo "$r"; o="$(out)"; ec=0
MOCK_RESULT='{"verdict":"accepted"}' MOCK_IS_ERROR=1 \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "c7: is_error did not produce nonzero exit"
pass "c7 is_error -> nonzero exit"

# --- Case 8: L1 scope-check fails on out-of-prefix write ----------------------
r="$workroot/c8"; new_repo "$r"; o="$(out)"; mkdir -p "$r/docs/orchestration"; ec=0
MOCK_RESULT='{"ok":true}' MOCK_WRITE="$r/out-of-scope.txt" \
  run_claude_run "$r" --level l1 -C "$r" --allow-prefix "docs/orchestration" \
  --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "c8: scope-check should fail on out-of-prefix write"
pass "c8 L1 scope-check rejects out-of-prefix write"

# --- Case 9: L1 scope-check passes when writes stay in-prefix ------------------
r="$workroot/c9"; new_repo "$r"; o="$(out)"; mkdir -p "$r/docs/orchestration"; ec=0
MOCK_RESULT='{"ok":true}' MOCK_WRITE="$r/docs/orchestration/in-scope.txt" \
  run_claude_run "$r" --level l1 -C "$r" --allow-prefix "docs/orchestration" \
  --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c9: scope-check wrongly failed on in-prefix write (ec=$ec)"
pass "c9 L1 scope-check accepts in-prefix write"

# --- Case 10: wall-clock timeout kills a runaway run + its whole child tree ----
r="$workroot/c10"; new_repo "$r"; o="$(out)"; marker="$r/completed.marker"; ec=0
start=$SECONDS
MOCK_SLEEP=6 MOCK_MARKER="$marker" SINGULAR_CLAUDE_TIMEOUT_SEC=2 \
  SINGULAR_PROVIDER_KILL_GRACE_SEC=1 \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
elapsed=$((SECONDS - start))
[[ "$ec" -eq 124 ]] || fail "c10: timeout should exit 124 (got $ec)"
[[ "$elapsed" -lt 10 ]] || fail "c10: timeout path exceeded bounded runner startup + kill budget (took ${elapsed}s)"
sleep 6   # past the mock's sleep; marker must NOT appear if the child was killed
[[ ! -e "$marker" ]] || fail "c10: child survived the timeout kill (marker created)"
pass "c10 wall-clock timeout exits 124 and kills the whole child tree"

# --- Case 11: per-role model + reasoning effort reach the claude invocation -------
# l2 implementer -> opus-4-8 at medium effort; planner -> opus-4-8 at xhigh.
r="$workroot/c11"; new_repo "$r"; o="$(out)"; args="$workroot/c11-l2.args"
MOCK_RESULT='{"status":"x"}' MOCK_ARGS_OUT="$args" \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--model claude-opus-4-8" "$args" || fail "c11: l2 not on opus-4-8 (got: $(cat "$args"))"
grep -q -- "--effort medium" "$args" || fail "c11: l2 effort not medium (got: $(cat "$args"))"
pass "c11 l2 implementer -> opus-4-8 + effort medium"

r="$workroot/c12"; new_repo "$r"; o="$(out)"; args="$workroot/c12-pl.args"
mkdir -p "$r/docs/orchestration/prompts"; : >"$r/docs/orchestration/prompts/planner-prompt.md"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_claude_run "$r" --level readonly -C "$r" --prompt-file "$r/docs/orchestration/prompts/planner-prompt.md" \
  --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--effort xhigh" "$args" || fail "c12: planner effort not xhigh (got: $(cat "$args"))"
pass "c12 planner -> effort xhigh"

# --- Case 13: --session-meta written from the envelope session_id (T-E5) ------
r="$workroot/c13"; new_repo "$r"; o="$(out)"; meta="$workroot/c13-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="sess-claude-abc" \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ -f "$meta" ]] || fail "c13: session-meta not written"
[[ "$(extract "$meta" sessionId)" == "sess-claude-abc" ]] || fail "c13: sessionId not parsed (got: $(extract "$meta" sessionId))"
[[ "$(extract "$meta" provider)" == "claude" ]] || fail "c13: provider not claude"
[[ "$(extract "$meta" model)" == "claude-opus-4-8" ]] || fail "c13: model not recorded"
pass "c13 --session-meta written from envelope session_id"

# --- Case 14: --resume-session adds -r <id> to the claude argv (T-E5) ----------
r="$workroot/c14"; new_repo "$r"; o="$(out)"; args="$workroot/c14.args"; meta="$workroot/c14-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="sess2" MOCK_ARGS_OUT="$args" \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "resume-id-77" >/dev/null 2>&1
grep -q -- "-r resume-id-77" "$args" || fail "c14: -r <id> not in argv (got: $(cat "$args"))"
grep -q -- "--fork-session" "$args" && fail "c14: --fork-session present when fork disabled"
pass "c14 --resume-session adds -r <id> (no fork by default)"

# --- Case 15: --fork-session added when SINGULAR_CLAUDE_FORK_ON_RESUME=1 -----------
r="$workroot/c15"; new_repo "$r"; o="$(out)"; args="$workroot/c15.args"; meta="$workroot/c15-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="sess3" MOCK_ARGS_OUT="$args" SINGULAR_CLAUDE_FORK_ON_RESUME=1 \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "resume-id-88" >/dev/null 2>&1
grep -q -- "-r resume-id-88" "$args" || fail "c15: -r <id> not in argv"
grep -q -- "--fork-session" "$args" || fail "c15: --fork-session missing when fork enabled (got: $(cat "$args"))"
pass "c15 --fork-session added when SINGULAR_CLAUDE_FORK_ON_RESUME=1"

# --- Case 16: model mismatch vs existing meta -> exit 86 (resume-refused) ------
r="$workroot/c16"; new_repo "$r"; o="$(out)"; meta="$workroot/c16-meta.json"; ec=0
# Forge a meta recorded under a DIFFERENT model than the runner derives now.
cat >"$meta" <<JSON
{"schema":"singular.orchestration.session-meta.v0","provider":"claude","sessionId":"s","model":"claude-some-other","effort":"medium","cwd":"$r","exitCode":0,"createdAt":"2026-01-01T00:00:00Z"}
JSON
MOCK_RESULT='{"status":"x"}' MOCK_ARGS_OUT="$workroot/c16.args" \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "s" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "c16: model mismatch should exit 86 (got $ec)"
[[ ! -f "$workroot/c16.args" ]] || fail "c16: runner should not have invoked claude on refusal"
pass "c16 model mismatch -> exit 86 (resume-refused, no model run)"

# --- Case 17: matching model -> NOT refused (proceeds, -r in argv) -------------
r="$workroot/c17"; new_repo "$r"; o="$(out)"; args="$workroot/c17.args"; meta="$workroot/c17-meta.json"; ec=0
cat >"$meta" <<JSON
{"schema":"singular.orchestration.session-meta.v0","provider":"claude","sessionId":"s","model":"claude-opus-4-8","effort":"medium","cwd":"$r","exitCode":0,"createdAt":"2026-01-01T00:00:00Z"}
JSON
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="s" MOCK_ARGS_OUT="$args" \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "s" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c17: matching model+effort should proceed (got $ec)"
grep -q -- "-r s" "$args" || fail "c17: -r <id> not in argv on matching meta"
pass "c17 matching model/effort -> proceeds with resume"

# --- Case 18: readonly guard restores a file that was ALREADY dirty -----------
# The defect that mattered most in the old path-diff guard. A file dirty before
# the run appeared in its "before" list, so the diff saw no change when the agent
# overwrote it and the agent's write survived — in $SINGULAR_ROOT, over an
# operator's uncommitted work.
r="$workroot/c18"; new_repo "$r"; o="$(out)"
printf 'committed\n' >"$r/wip.txt"
( cd "$r" && git add wip.txt && git commit -qm wip )
printf 'OPERATOR-WIP\n' >"$r/wip.txt"
MOCK_RESULT='{"ok":true}' MOCK_WRITE="$r/wip.txt" \
  run_claude_run "$r" --level readonly -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ "$(cat "$r/wip.txt")" == "OPERATOR-WIP" ]] \
  || fail "c18: readonly run overwrote uncommitted work (got: $(cat "$r/wip.txt"))"
pass "c18 readonly guard restores an already-dirty file to its pre-run bytes"

# --- Case 19: the guard runs when the runner is killed, not just when it ends --
# ask/supervise/decide background this runner and kill it on timeout. The old
# guard was straight-line code after the run, so on that path it never executed
# at all and every mutation persisted. It lives in the EXIT trap now, which a
# SIGTERM handler reaches on its way out.
r="$workroot/c19"; new_repo "$r"; o="$(out)"
printf 'committed\n' >"$r/killed.txt"
( cd "$r" && git add killed.txt && git commit -qm killed )
# Invoked directly rather than through run_claude_run: that helper wraps the
# runner in a subshell, and $! would name the subshell, so the SIGTERM would
# never reach claude-run.sh's trap at all.
( cd "$r" && MOCK_RESULT='{"ok":true}' MOCK_WRITE="$r/killed.txt" MOCK_SLEEP=20 \
    SINGULAR_CLAUDE_TIMEOUT_SEC=0 SINGULAR_ROOT="$r" SINGULAR_STATE_DIR="$r/.singular-state" \
    exec "$CLAUDE_RUN" --level readonly -C "$r" --output-last-message "$o" ) \
  >/dev/null 2>&1 &
kill_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ "$(cat "$r/killed.txt" 2>/dev/null)" == "MUTATED" ]] && break
  sleep 1
done
[[ "$(cat "$r/killed.txt")" == "MUTATED" ]] || fail "c19: mock never mutated the tree"
kill -TERM "$kill_pid" 2>/dev/null || true
wait "$kill_pid" 2>/dev/null || true
[[ "$(cat "$r/killed.txt")" == "committed" ]] \
  || fail "c19: a killed readonly run left its mutation behind (got: $(cat "$r/killed.txt"))"
pass "c19 readonly guard restores on SIGTERM, not only on a clean exit"

# --- Case 20: readonly denies the Bash mutations the guard cannot repair ------
# The guard restores the WORKING TREE. It does not move HEAD back, so a Bash
# `git commit` or `git reset --hard` leaves damage no post-run restore can
# express — which is why tool denial alone was never sufficient and why this
# runner's own comment used to admit the hole. Bash stays open otherwise;
# read-only review is the point of a read-only run.
r="$workroot/c20"; new_repo "$r"; o="$(out)"; args="$workroot/c20.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_claude_run "$r" --level readonly -C "$r" --output-last-message "$o" >/dev/null 2>&1
for denied in "Bash(git commit:*)" "Bash(git reset:*)" "Bash(git push:*)" "Bash(git checkout:*)"; do
  grep -qF -- "$denied" "$args" || fail "c20: readonly did not deny $denied"
done
grep -qF -- "Bash(git diff:*)" "$args" && fail "c20: read-only inspection must stay available"
args2="$workroot/c20b.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args2" \
  run_claude_run "$r" --level l2 -C "$r" --output-last-message "$o" >/dev/null 2>&1
grep -qF -- "Bash(git commit:*)" "$args2" && fail "c20: l2 must not inherit the readonly denials"
pass "c20 readonly denies state-mutating git via Bash; l2 unaffected"

# --- Case 21: ps-denied sandbox — the timeout kill still reaches descendants ---
# PMGO-004. The old cleanup built its target list from `ps -A` and ignored that
# command's exit status, so in a sandbox that denies process enumeration it
# SIGKILLed only the direct child; every descendant survived the timeout, and
# nothing anywhere said so. The provider now runs as its own session leader, so
# one negative pid reaches the whole tree with no `ps` at all — and the cleanup
# proves the tree is gone instead of assuming it (no UNVERIFIED line).
r="$workroot/c21"; new_repo "$r"; o="$(out)"; ec=0
psdeny="$workroot/psdeny"; mkdir -p "$psdeny"
printf '#!/usr/bin/env bash\nexit 1\n' >"$psdeny/ps"; chmod +x "$psdeny/ps"
childf="$workroot/c21-child.pid"; : >"$childf"
errlog="$workroot/c21.err"
# Invoked directly (not via run_claude_run) so the ps stub is on PATH for this
# case alone and never leaks into the rest of the suite.
( cd "$r" && PATH="$psdeny:$PATH" MOCK_RESULT='{"ok":true}' MOCK_SLEEP=30 \
    MOCK_CHILD_OUT="$childf" SINGULAR_CLAUDE_TIMEOUT_SEC=2 \
    SINGULAR_PROVIDER_KILL_GRACE_SEC=1 \
    SINGULAR_ROOT="$r" SINGULAR_STATE_DIR="$r/.singular-state" \
    exec "$CLAUDE_RUN" --level l2 -C "$r" --output-last-message "$o" ) \
  >/dev/null 2>"$errlog" || ec=$?
[[ "$ec" -eq 124 ]] || fail "c21: ps-denied timeout should still exit 124 (got $ec)"
[[ -s "$childf" ]] || fail "c21: the mock never recorded a descendant pid"
descendant="$(cat "$childf")"
sleep 0.5
kill -0 "$descendant" 2>/dev/null && fail "c21: descendant survived the ps-denied timeout kill"
grep -q "UNVERIFIED" "$errlog" && fail "c21: cleanup reported UNVERIFIED although the group was proven"
pass "c21 ps-denied timeout kills the provider's descendants, verified without ps"

echo "ALL CLAUDE-RUN CONTRACT TESTS PASSED"
