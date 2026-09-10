#!/usr/bin/env bash
set -euo pipefail

# E6 (0.5.0): codex-run.sh wall-clock timeout + idle-output liveness guard.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$1' got '$2'"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/wt" "$tmp/state"
git -C "$tmp/wt" init -q
git -C "$tmp/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
target_branch="$(git -C "$tmp/wt" branch --show-current)"
printf 'hello\n' >"$tmp/prompt.md"

run_codex() {
  # args: env-pairs... — invokes codex-run with the fake codex on PATH
  local test_run_id="${TEST_RUN_ID:-RUN-T}"
  env PATH="$tmp/bin:$PATH" SINGULAR_ROOT="$tmp/wt" SINGULAR_STATE_DIR="$tmp/state" SINGULAR_TARGET_BRANCH="$target_branch" "$@" \
    bash "$SCRIPT_DIR/codex-run.sh" --worktree "$tmp/wt" --level l2 --run-id "$test_run_id" \
      --prompt-file "$tmp/prompt.md" >/dev/null 2>"$tmp/err.log"
}

# 1. Wall-clock timeout: fake codex hangs -> rc 124 fast, no orphans.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"t1"}'
sleep 60 &
child=$!
echo "$child" >"${CODEX_CHILD_FILE:-/dev/null}"
wait "$child"
SH
chmod +x "$tmp/bin/codex"
rc=0
CODEX_CHILD_FILE="$tmp/child.pid" run_codex env SINGULAR_CODEX_TIMEOUT_SEC=3 SINGULAR_CODEX_IDLE_SEC=0 CODEX_CHILD_FILE="$tmp/child.pid" || rc=$?
assert_eq "124" "$rc" "hung codex times out with rc 124"
grep -q "TIMED OUT" "$tmp/err.log" || fail "timeout reported on stderr"
if [[ -s "$tmp/child.pid" ]]; then
  child="$(cat "$tmp/child.pid")"
  sleep 0.3
  kill -0 "$child" 2>/dev/null && fail "grandchild survived the kill tree"
fi

# 2. Idle guard: output stalls -> rc 124; continuous output -> rc 0.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"t2"}'
sleep 30
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=60 SINGULAR_CODEX_IDLE_SEC=3 || rc=$?
assert_eq "124" "$rc" "stalled output is killed by the idle guard"
grep -q "IDLE" "$tmp/err.log" || fail "idle kill reported on stderr"

cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
for i in 1 2 3 4; do echo "{\"type\":\"tick\",\"n\":$i}"; sleep 1; done
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=60 SINGULAR_CODEX_IDLE_SEC=3 || rc=$?
assert_eq "0" "$rc" "steadily streaming run is never idle-killed"

# 3. Guards disabled: legacy path, exit propagates.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"done"}'
exit 7
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=0 SINGULAR_CODEX_IDLE_SEC=0 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=0 || rc=$?
assert_eq "7" "$rc" "disabled guards propagate the codex exit code"

# 4. A parsed terminal completion event starts a grace period. If Codex remains
# alive, its whole process tree is cleaned up while the completed run stays
# successful and its already-written last-message artifact remains intact.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
out_file=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "-o" ]] && out_file="$arg"
  prev="$arg"
done
[[ -n "$out_file" ]] && printf '%s\n' '{"status":"accepted"}' >"$out_file"
echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
sleep 60 &
child=$!
echo "$child" >"${CODEX_CHILD_FILE:-/dev/null}"
wait "$child"
SH
chmod +x "$tmp/bin/codex"
rc=0
started="$SECONDS"
CODEX_CHILD_FILE="$tmp/completed-child.pid" run_codex env \
  SINGULAR_CODEX_TIMEOUT_SEC=60 SINGULAR_CODEX_IDLE_SEC=60 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=1 SINGULAR_PROVIDER_KILL_GRACE_SEC=1 \
  CODEX_CHILD_FILE="$tmp/completed-child.pid" || rc=$?
elapsed=$(( SECONDS - started ))
assert_eq "0" "$rc" "semantically completed hung codex exits successfully"
(( elapsed < 10 )) || fail "semantic completion cleanup took too long (${elapsed}s)"
grep -q "semantic completion observed" "$tmp/err.log" \
  || fail "semantic completion was not reported"
grep -q "completion grace expired" "$tmp/err.log" \
  || fail "completion grace cleanup was not reported"
grep -q '"status":"accepted"' "$tmp/state/runs/RUN-T/last-message.json" \
  || fail "last-message artifact was not preserved after completion cleanup"
if [[ -s "$tmp/completed-child.pid" ]]; then
  child="$(cat "$tmp/completed-child.pid")"
  sleep 0.3
  kill -0 "$child" 2>/dev/null && fail "completed provider grandchild survived cleanup"
fi

# 5. Prose and non-terminal/malformed JSON that merely mention the event name
# must not bypass ordinary timeout behavior.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo 'provider log mentions {"type":"turn.completed"} but is not JSON'
echo 'provider log mentions {"type":"turn.failed","error":{"message":"no"}} but is not JSON'
echo 'provider log mentions {"type":"error","message":"Reconnecting... 2/5 (unexpected status 503 Service Unavailable)"} but is not JSON'
echo '{"type":"item.completed","message":"turn.completed"}'
echo '{"type":"item.completed","item":{"type":"turn.failed","error":{"message":"nested"}}}'
echo '{"type":"item.completed","item":{"type":"error","message":"Reconnecting... 2/5 (unexpected status 503 Service Unavailable)"}}'
echo '{"type":["turn.completed"]}'
echo '{"type":"turn.completed"'
sleep 60
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=3 SINGULAR_CODEX_IDLE_SEC=0 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=1 || rc=$?
assert_eq "124" "$rc" "completion mentions do not bypass wall timeout"
grep -q "TIMED OUT" "$tmp/err.log" || fail "ordinary timeout was not reported"
if grep -q "semantic completion observed" "$tmp/err.log"; then
  fail "malformed/prose completion mention triggered semantic completion"
fi

# 6. ps-denied sandbox (PMGO-004). The old cleanup built its target list from
# `ps -A` and ignored its exit status: where process enumeration is denied the
# list came back empty, only the direct child was signalled, the provider's
# descendants survived the timeout — and nothing said so. The provider pipeline
# now runs as its own session leader, so one negative pid reaches the whole tree
# with no `ps` involved, and the cleanup proves it rather than assuming it.
mkdir -p "$tmp/psdeny"
cat >"$tmp/psdeny/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$tmp/psdeny/ps"
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"t6"}'
sleep 60 &
child=$!
echo "$child" >"${CODEX_CHILD_FILE:-/dev/null}"
wait "$child"
SH
chmod +x "$tmp/bin/codex"
: >"$tmp/psdenied-child.pid"
rc=0
env PATH="$tmp/psdeny:$tmp/bin:$PATH" SINGULAR_ROOT="$tmp/wt" SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_TARGET_BRANCH="$target_branch" \
  SINGULAR_CODEX_TIMEOUT_SEC=3 SINGULAR_CODEX_IDLE_SEC=0 \
  SINGULAR_PROVIDER_KILL_GRACE_SEC=1 CODEX_CHILD_FILE="$tmp/psdenied-child.pid" \
  bash "$SCRIPT_DIR/codex-run.sh" --worktree "$tmp/wt" --level l2 --run-id RUN-PSDENY \
    --prompt-file "$tmp/prompt.md" >/dev/null 2>"$tmp/err.log" || rc=$?
assert_eq "124" "$rc" "ps-denied hung codex still times out with rc 124"
grep -q "TIMED OUT" "$tmp/err.log" || fail "ps-denied timeout was not reported on stderr"
[[ -s "$tmp/psdenied-child.pid" ]] || fail "ps-denied case: fake codex never spawned its grandchild"
child="$(cat "$tmp/psdenied-child.pid")"
sleep 0.3
kill -0 "$child" 2>/dev/null && fail "grandchild survived the kill with ps denied"
grep -q "UNVERIFIED" "$tmp/err.log" && fail "session kill reported UNVERIFIED although the group was proven"

# 7. Native Codex reports bounded SDK reconnect attempts as top-level error
# envelopes. They are provisional: a later terminal success and last-message
# must win instead of the runner killing the provider during its retry delay.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
out_file=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "-o" ]] && out_file="$arg"
  prev="$arg"
done
printf '%s\n' '{"type":"error","message":"Reconnecting... 2/5 (unexpected status 503 Service Unavailable: upstream connect error or disconnect/reset before headers. reset reason: connection termination, url: wss://chatgpt.com/backend-api/codex/responses, cf-ray: a38993f7dab17a85-ZRH)"}'
sleep 2
[[ -n "$out_file" ]] && printf '%s\n' '{"status":"accepted-after-reconnect"}' >"$out_file"
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":1}}'
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=20 SINGULAR_CODEX_IDLE_SEC=10 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=2 || rc=$?
assert_eq "0" "$rc" "bounded reconnect followed by completion succeeds"
grep -q 'accepted-after-reconnect' "$tmp/state/runs/RUN-T/last-message.json" \
  || fail "post-reconnect last-message was not preserved"
python3 - "$tmp/state/runs/RUN-T/runner-result.json" <<'PY' \
  || fail "preceding reconnect noise poisoned normalized success"
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["exitCode"] == 0, result
assert result["outcome"] == "succeeded", result
assert result["failureClass"] == "none", result
assert result["providerErrorRef"] is None, result
PY

# 8. A reconnect notification is not itself success. If Codex exits without a
# later completion, keep it as failure evidence and narrowly recover the native
# `unexpected status 503` as retryable provider overload.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"type":"error","message":"Reconnecting... 5/5 (unexpected status 503 Service Unavailable: upstream connect error or disconnect/reset before headers)"}'
sleep 2
exit 0
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=20 SINGULAR_CODEX_IDLE_SEC=10 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=2 || rc=$?
[[ "$rc" -ne 0 ]] || fail "reconnect without later success was converted to success"
python3 - "$tmp/state/runs/RUN-T/runner-result.json" <<'PY' \
  || fail "unresolved reconnect evidence was not normalized"
import json, os, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["exitCode"] != 0, result
assert result["outcome"] == "provider-error", result
assert result["failureClass"] == "provider-overloaded", result
ref = result["providerErrorRef"]
assert ref and os.path.isfile(ref), result
error = json.load(open(ref, encoding="utf-8"))
assert error["eventType"] == "error", error
assert error["kind"] == "overloaded", error
assert error["httpStatus"] == 503, error
assert error["retryable"] is True, error
PY

# 9. Status-looking arbitrary error prose remains a generic provider failure;
# only the recognized native reconnect envelope may promote message text to an
# HTTP overload classification.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"type":"error","message":"model said HTTP503 and Reconnecting... 2/5 in quoted text"}'
sleep 2
exit 0
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=20 SINGULAR_CODEX_IDLE_SEC=10 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=2 || rc=$?
[[ "$rc" -ne 0 ]] || fail "generic terminal error was converted to success"
python3 - "$tmp/state/runs/RUN-T/runner-result.json" <<'PY' \
  || fail "arbitrary status prose gained overload authority"
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
error = json.load(open(result["providerErrorRef"], encoding="utf-8"))
assert result["failureClass"] == "provider-exit", result
assert error["kind"] == "provider-error", error
assert error["httpStatus"] is None, error
assert error["retryable"] is False, error
PY

# 10. A complete reconnect object nested in a prose-only stream is not a Codex
# JSONL record and must never gain terminal-envelope or HTTP-status authority.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'provider prose: {"type":"error","message":"Reconnecting... 5/5 (unexpected status 503 Service Unavailable: upstream connect error or disconnect/reset before headers)"} end prose'
exit 7
SH
chmod +x "$tmp/bin/codex"
rc=0
TEST_RUN_ID=RUN-PROSE run_codex env SINGULAR_CODEX_TIMEOUT_SEC=20 \
  SINGULAR_CODEX_IDLE_SEC=10 SINGULAR_CODEX_COMPLETION_GRACE_SEC=2 || rc=$?
assert_eq "7" "$rc" "prose-only reconnect stream keeps provider exit status"
python3 - "$tmp/state/runs/RUN-PROSE/runner-result.json" <<'PY' \
  || fail "prose-only reconnect JSON gained provider authority"
import json, os, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["exitCode"] == 7, result
assert result["outcome"] == "failed", result
assert result["failureClass"] == "provider-exit", result
assert result["providerErrorRef"] is None, result
ref = result.get("providerEnvelopeRef")
assert ref and os.path.isfile(ref), result
raw = open(ref, "r", encoding="utf-8").read()
assert '"type":"error"' in raw and "unexpected status 503" in raw, raw
PY

# 11. Counter parsing is deliberately bounded before integer conversion. A
# malformed 5000-digit counter stays a generic terminal provider failure while
# both the normalized result and byte-identical raw envelope remain available.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
digits="$(printf '%05000d' 0 | tr '0' '9')"
printf '{"type":"error","message":"Reconnecting... %s/5 (unexpected status 503 Service Unavailable)"}\n' "$digits"
exit 0
SH
chmod +x "$tmp/bin/codex"
rc=0
TEST_RUN_ID=RUN-HUGE-COUNTER run_codex env SINGULAR_CODEX_TIMEOUT_SEC=20 \
  SINGULAR_CODEX_IDLE_SEC=10 SINGULAR_CODEX_COMPLETION_GRACE_SEC=2 || rc=$?
[[ "$rc" -ne 0 ]] || fail "5000-digit reconnect counter was converted to success"
python3 - "$tmp/state/runs/RUN-HUGE-COUNTER/runner-result.json" <<'PY' \
  || fail "5000-digit reconnect counter lost generic result/raw evidence"
import json, os, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["exitCode"] != 0, result
assert result["outcome"] == "provider-error", result
assert result["failureClass"] == "provider-exit", result
error_ref = result["providerErrorRef"]
envelope_ref = result.get("providerEnvelopeRef")
assert error_ref and os.path.isfile(error_ref), result
assert envelope_ref and os.path.isfile(envelope_ref), result
error = json.load(open(error_ref, encoding="utf-8"))
assert error["kind"] == "provider-error", error
assert error["httpStatus"] is None, error
assert error["retryable"] is False, error
raw = open(envelope_ref, "r", encoding="utf-8").read()
assert "9" * 5000 in raw and "unexpected status 503" in raw, len(raw)
event = json.load(open(error["rawEventRef"], encoding="utf-8"))
assert "9" * 5000 in event["message"], len(event["message"])
PY

echo "PASS: test-codex-run-timeout"
