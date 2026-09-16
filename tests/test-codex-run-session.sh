#!/usr/bin/env bash
set -euo pipefail

# Deterministic contract tests for codex-run.sh session affinity (T-E5). A mock
# `codex` on PATH stands in for the real CLI (offline, free, CI-safe), emitting
# JSONL on stdout that includes a session-id event, and honoring -o by writing
# the final message there (as the real codex does). These assert:
#   (a) default invocation (no --session-meta) is byte-identical to HEAD behavior
#       — no tee artifacts, no session-meta written;
#   (b) with --session-meta: the session id is parsed from the JSONL, the meta is
#       written, and PIPESTATUS exit propagation is correct (mock exit code wins);
#   (c) --resume-session puts `exec resume <id>` in the recorded codex argv;
#   (d) model/effort mismatch vs an existing meta -> exit 86 (resume-refused),
#       and the model is NOT invoked.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
CODEX_RUN="$SCRIPT_DIR/codex-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-codex-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

# --- Mock codex ----------------------------------------------------------------
# Records argv to MOCK_ARGS_OUT, consumes stdin, emits JSONL (one of the lines is
# a session-id event), writes the final message to the file named after -o, and
# exits with MOCK_EXIT (default 0). MOCK_SESSION_ID defaults to a fixed id; set it
# empty to simulate a parse miss. MOCK_RESULT controls the written last-message.
cat >"$bindir/codex" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
cat >/dev/null 2>&1 || true   # consume the piped prompt

# Find the -o/--output-last-message target in argv (codex writes the final msg there).
out_file=""
prev=""
for a in "$@"; do
  case "$prev" in
    -o|--output-last-message) out_file="$a" ;;
  esac
  prev="$a"
done

sid="${MOCK_SESSION_ID-mock-codex-session-123}"
# Emit JSONL events. MOCK_SHAPE=thread reproduces the REAL current codex CLI
# (`{"type":"thread.started","thread_id":"<uuid>"}`); the default synthetic shape
# carries the id under .msg.session_id to also exercise the defensive nested scan.
if [[ "${MOCK_SHAPE:-msg}" == "thread" ]]; then
  if [[ -n "$sid" ]]; then
    printf '{"type":"thread.started","thread_id":"%s"}\n' "$sid"
  else
    printf '%s\n' '{"type":"thread.started"}'
  fi
else
  printf '%s\n' '{"type":"thread.started"}'
  if [[ -n "$sid" ]]; then
    printf '{"type":"session.created","msg":{"session_id":"%s"}}\n' "$sid"
  fi
fi
result="${MOCK_RESULT:-}"
[[ -z "$result" ]] && result='{"verdict":"accepted"}'
if [[ -n "$out_file" ]]; then
  printf '%s\n' "$result" > "$out_file"
fi
if [[ "${MOCK_TERMINAL_COMPLETE:-no}" == "yes" ]]; then
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":1}}'
  if [[ "${MOCK_FAILURE_AFTER_COMPLETE:-no}" == "yes" ]]; then
    sleep "${MOCK_FAILURE_DELAY_SEC:-2}"
    printf '%s\n' '{"type":"turn.failed","error":{"code":"transport_error","message":"provider terminal failure"}}'
  fi
  if [[ "${MOCK_HANG_AFTER_COMPLETE:-no}" == "yes" ]]; then
    sleep 60 &
    child=$!
    [[ -n "${MOCK_CHILD_OUT:-}" ]] && printf '%s\n' "$child" >"$MOCK_CHILD_OUT"
    wait "$child"
  fi
else
  printf '%s\n' '{"type":"item.completed"}'
fi
exit "${MOCK_EXIT:-0}"
MOCK
chmod +x "$bindir/codex"

export PATH="$bindir:$PATH"
export SINGULAR_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.singular-state/\n' > .gitignore && git add .gitignore && git commit -qm init \
      && git branch "$SINGULAR_TARGET_BRANCH" )
}

run_codex_run() {
  local repo="$1"; shift
  ( cd "$repo" && SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" "$CODEX_RUN" "$@" )
}

field() { # read a top-level field from a JSON file
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"
}

i=0; out() { i=$((i+1)); echo "$workroot/out-$i.json"; }

# --- Case a: default invocation (no --session-meta) — no meta, no tee artifacts -
r="$workroot/a"; new_repo "$r"; o="$(out)"; args="$workroot/a.args"
MOCK_RESULT='{"status":"needs-review"}' MOCK_ARGS_OUT="$args" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ -f "$o" ]] || fail "a: output not written"
[[ "$(field "$o" status)" == "needs-review" ]] || fail "a: status not captured"
# The fresh argv must be the HEAD form: `exec` immediately (no `resume`), `--json`.
grep -q -- "exec -m " "$args" || fail "a: default argv not in HEAD `exec -m` form (got: $(cat "$args"))"
grep -q -- "resume" "$args" && fail "a: default argv unexpectedly contains 'resume'"
# No stray tee artifact under the workroot.
[[ -z "$(find "$workroot" -name 'singular-codex-jsonl.*' 2>/dev/null)" ]] || fail "a: tee artifact leaked"
pass "a default invocation byte-identical: no resume, no meta, no tee artifact"

# --- Case b: --session-meta parses the session id + PIPESTATUS exit propagation -
r="$workroot/b"; new_repo "$r"; o="$(out)"; meta="$workroot/b-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="mock-codex-session-123" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ -f "$meta" ]] || fail "b: session-meta not written"
[[ "$(field "$meta" sessionId)" == "mock-codex-session-123" ]] || fail "b: sessionId not parsed (got: $(field "$meta" sessionId))"
[[ "$(field "$meta" provider)" == "codex" ]] || fail "b: provider not codex"

# PIPESTATUS: mock exit code (not tee's) must win.
r="$workroot/b2"; new_repo "$r"; o="$(out)"; meta="$workroot/b2-meta.json"; ec=0
MOCK_RESULT='{"status":"x"}' MOCK_EXIT=7 \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 7 ]] || fail "b2: PIPESTATUS exit propagation wrong (want 7 got $ec)"
pass "b --session-meta parses session id + PIPESTATUS propagates the model's rc"

# --- Case b3: parse miss (empty session id) -> empty sessionId in meta ----------
r="$workroot/b3"; new_repo "$r"; o="$(out)"; meta="$workroot/b3-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ -f "$meta" ]] || fail "b3: meta not written on parse miss"
[[ -z "$(field "$meta" sessionId)" ]] || fail "b3: sessionId should be empty on parse miss (got: $(field "$meta" sessionId))"
pass "b3 parse miss -> empty sessionId (caller goes fresh)"

# --- Case b4: REAL codex shape — thread.started/thread_id is parsed -------------
# Locks the production key confirmed by the live smoke test (codex emits the
# resumable id as thread_id on a thread.started event, not session_id).
r="$workroot/b4"; new_repo "$r"; o="$(out)"; meta="$workroot/b4-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SHAPE="thread" MOCK_SESSION_ID="019eae91-2e20-71c1-9f8a-c30d1f7e851e" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ "$(field "$meta" sessionId)" == "019eae91-2e20-71c1-9f8a-c30d1f7e851e" ]] \
  || fail "b4: thread_id from thread.started not parsed (got: $(field "$meta" sessionId))"
pass "b4 real codex thread.started/thread_id is captured as the session id"

# --- Case b5: terminal completion cleanup preserves session/output artifacts ---
r="$workroot/b5"; new_repo "$r"; o="$(out)"; meta="$workroot/b5-meta.json"
child_out="$workroot/b5-child.pid"; ec=0
MOCK_RESULT='{"status":"accepted"}' MOCK_SHAPE="thread" \
  MOCK_SESSION_ID="completed-session-123" MOCK_TERMINAL_COMPLETE=yes \
  MOCK_HANG_AFTER_COMPLETE=yes MOCK_CHILD_OUT="$child_out" \
  SINGULAR_CODEX_TIMEOUT_SEC=60 SINGULAR_CODEX_IDLE_SEC=60 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=1 \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "b5: semantically completed hung run should succeed (got $ec)"
[[ "$(field "$o" status)" == "accepted" ]] \
  || fail "b5: last-message artifact was not preserved"
[[ "$(field "$meta" sessionId)" == "completed-session-123" ]] \
  || fail "b5: session metadata was not preserved"
[[ "$(field "$meta" exitCode)" == "0" ]] \
  || fail "b5: completion cleanup should record exitCode 0"
if [[ -s "$child_out" ]]; then
  child="$(cat "$child_out")"
  sleep 0.3
  kill -0 "$child" 2>/dev/null && fail "b5: provider grandchild survived cleanup"
fi
pass "b5 terminal completion cleanup preserves last-message and session metadata"

# --- Case b6: a terminal failure after completion remains authoritative --------
# The failure is delayed long enough for the runner to enter completion grace,
# then Codex hangs. Cleanup must be nonzero and retain all structured evidence.
r="$workroot/b6"; new_repo "$r"; o="$(out)"; meta="$workroot/b6-meta.json"
child_out="$workroot/b6-child.pid"; result="$workroot/b6-runner-result.json"; ec=0
MOCK_RESULT='{"status":"accepted-before-provider-failure"}' MOCK_SHAPE="thread" \
  MOCK_SESSION_ID="failed-session-123" MOCK_TERMINAL_COMPLETE=yes \
  MOCK_FAILURE_AFTER_COMPLETE=yes MOCK_FAILURE_DELAY_SEC=2 \
  MOCK_HANG_AFTER_COMPLETE=yes MOCK_CHILD_OUT="$child_out" \
  SINGULAR_CODEX_TIMEOUT_SEC=60 SINGULAR_CODEX_IDLE_SEC=60 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=6 \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --result-file "$result" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "b6: terminal provider failure was converted to success"
[[ "$ec" -eq 1 ]] || fail "b6: terminal provider failure should exit 1 (got $ec)"
[[ "$(field "$o" status)" == "accepted-before-provider-failure" ]] \
  || fail "b6: last-message artifact was not preserved"
[[ "$(field "$meta" sessionId)" == "failed-session-123" ]] \
  || fail "b6: session metadata was not preserved"
[[ "$(field "$meta" exitCode)" == "1" ]] \
  || fail "b6: session metadata did not record the provider failure"
[[ "$(field "$result" exitCode)" == "1" ]] \
  || fail "b6: runner result exit code mismatch"
[[ "$(field "$result" outcome)" == "provider-error" ]] \
  || fail "b6: runner result did not classify the terminal envelope"
[[ "$(field "$result" failureClass)" == "provider-exit" ]] \
  || fail "b6: terminal failure should classify as provider-exit"
provider_error="$(field "$result" providerErrorRef)"
[[ -f "$provider_error" ]] || fail "b6: provider-error sidecar missing"
[[ "$(field "$provider_error" eventType)" == "turn.failed" ]] \
  || fail "b6: provider-error sidecar event type mismatch"
[[ "$(field "$provider_error" kind)" == "provider-error" ]] \
  || fail "b6: provider-error sidecar kind mismatch"
provider_envelope="$(field "$result" providerEnvelopeRef)"
[[ -f "$provider_envelope" ]] || fail "b6: raw provider JSONL artifact missing"
grep -q '"type":"turn.completed"' "$provider_envelope" \
  || fail "b6: completion event missing from preserved JSONL"
grep -q '"type":"turn.failed"' "$provider_envelope" \
  || fail "b6: failure event missing from preserved JSONL"
if [[ -s "$child_out" ]]; then
  child="$(cat "$child_out")"
  sleep 0.3
  kill -0 "$child" 2>/dev/null && fail "b6: provider grandchild survived failure cleanup"
fi
pass "b6 post-completion failure stays nonzero with structured evidence preserved"

# --- Case c: --resume-session puts `exec resume <id>` in the codex argv ---------
r="$workroot/c"; new_repo "$r"; o="$(out)"; args="$workroot/c.args"; meta="$workroot/c-meta.json"
# No prior meta file -> no refusal; just verify the resume argv form.
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="s" MOCK_ARGS_OUT="$args" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "resume-xyz" >/dev/null 2>&1
grep -q -- "exec resume resume-xyz" "$args" || fail "c: 'exec resume <id>' not in argv (got: $(cat "$args"))"
grep -q -- "--json" "$args" || fail "c: --json missing in resume argv"
pass "c --resume-session yields 'exec resume <id>' in the codex argv"

# --- Case d: model mismatch vs existing meta -> exit 86, model NOT invoked ------
r="$workroot/d"; new_repo "$r"; o="$(out)"; args="$workroot/d.args"; ec=0
meta="$workroot/d-meta.json"
cat >"$meta" <<JSON
{"schema":"singular.orchestration.session-meta.v0","provider":"codex","sessionId":"s","model":"gpt-OTHER","effort":"medium","cwd":"$r","exitCode":0,"createdAt":"2026-01-01T00:00:00Z"}
JSON
MOCK_RESULT='{"status":"x"}' MOCK_ARGS_OUT="$args" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "s" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "d: model mismatch should exit 86 (got $ec)"
[[ ! -f "$args" ]] || fail "d: codex should not have been invoked on refusal"
pass "d model mismatch -> exit 86 (resume-refused, model not invoked)"

# --- Case e: the spawner records the provider session, ps-free ----------------
# runner-session.json is what a crashed runner leaves behind for recovery: the
# provider pid, its process-group id, and the KERNEL's confirmation that the two
# are equal — i.e. that the whole tree can be reached with one negative pid,
# which is the only containment proof available where `ps` is denied.
r="$workroot/e"; new_repo "$r"; o="$(out)"
MOCK_RESULT='{"status":"x"}' \
  run_codex_run "$r" --level l2 -C "$r" --run-id RUN-SESSION-E \
  --output-last-message "$o" >/dev/null 2>&1
record="$r/.singular-state/runs/RUN-SESSION-E/runner-session.json"
[[ -f "$record" ]] || fail "e: runner-session.json not written to the run dir"
python3 - "$record" <<'PY' || fail "e: session record did not prove a session leader ($(cat "$record"))"
import json
import sys

rec = json.load(open(sys.argv[1], encoding="utf-8"))
assert rec.get("sessionSpawn") is True, rec
assert isinstance(rec.get("pid"), int) and rec["pid"] > 1, rec
assert rec.get("pgid") == rec.get("pid"), rec
assert rec.get("verified") is True, rec
PY
pass "e run dir records a verified provider session (pid == pgid)"

# --- Case f: retained session envelope binding changed -> exit 86 --------------
# A warning to ignore revoked history is not enough. Before reusing a session the
# runner compares the CURRENT authorization/model/provider/policy/capability
# envelope binding against the one retained with the session. A difference means
# unauthorized historical content cannot be verifiably removed, so the resume is
# refused and the host reconstructs a fresh authorized invocation.
r="$workroot/f"; new_repo "$r"; o="$(out)"; args="$workroot/f.args"; ec=0
meta="$workroot/f-meta.json"
cat >"$meta" <<JSON
{"schema":"singular.orchestration.session-meta.v0","provider":"codex","sessionId":"s","cwd":"$r","exitCode":0,"createdAt":"2026-01-01T00:00:00Z","envelopeBinding":"sha256:aaaa"}
JSON
SINGULAR_INVOCATION_ENVELOPE_BINDING="sha256:bbbb" MOCK_RESULT='{"status":"x"}' MOCK_ARGS_OUT="$args"   run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o"   --session-meta "$meta" --resume-session "s" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "f: envelope-binding change should exit 86 (got $ec)"
[[ ! -f "$args" ]] || fail "f: codex must not be invoked when the envelope changed"
pass "f retained envelope binding change -> exit 86 (resume refused, fresh required)"

# --- Case f2: the binding is persisted by the REAL session-meta write path -------
# Audit F1 on the first candidate: no production writer recorded envelopeBinding,
# so the gate above only ever fired on hand-authored metas. Create the session
# through the runner's own meta write under one binding, then resume under a
# different binding: the retained meta must carry the first binding and the
# resume must be refused with exit 86.
r="$workroot/f2"; new_repo "$r"; o="$(out)"; args="$workroot/f2.args"; ec=0
meta="$workroot/f2-meta.json"
SINGULAR_INVOCATION_ENVELOPE_BINDING="sha256:first" MOCK_RESULT='{"status":"x"}' \
  run_codex_run "$r" --level l2 -C "$r" --run-id RUN-SESSION-F2 \
  --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1 || true
[[ -f "$meta" ]] || fail "f2: runner did not write the session meta"
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("envelopeBinding",""))' "$meta")" == "sha256:first" ]] \
  || fail "f2: real write path did not persist envelopeBinding ($(cat "$meta"))"
sid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sessionId",""))' "$meta")"
SINGULAR_INVOCATION_ENVELOPE_BINDING="sha256:second" MOCK_RESULT='{"status":"x"}' MOCK_ARGS_OUT="$args" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "${sid:-s}" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "f2: resume after a real-path binding change should exit 86 (got $ec)"
[[ ! -f "$args" ]] || fail "f2: codex must not be invoked when the retained binding differs"
pass "f2 binding persisted by the real write path; changed binding refused (exit 86)"

# An identical retained binding still resumes: the gate is a comparison, not a
# blanket refusal of every retained session.
r="$workroot/f2b"; new_repo "$r"; o="$(out)"; args="$workroot/f2b.args"
meta="$workroot/f2b-meta.json"
cat >"$meta" <<JSON
{"schema":"singular.orchestration.session-meta.v0","provider":"codex","sessionId":"s2","cwd":"$r","exitCode":0,"createdAt":"2026-01-01T00:00:00Z","envelopeBinding":"sha256:aaaa"}
JSON
SINGULAR_INVOCATION_ENVELOPE_BINDING="sha256:aaaa" MOCK_RESULT='{"status":"x"}' MOCK_ARGS_OUT="$args"   run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o"   --session-meta "$meta" --resume-session "s2" >/dev/null 2>&1
grep -q -- "exec resume s2" "$args"   || fail "f2: identical envelope binding must still resume (got: $(cat "$args"))"
pass "f2 identical retained envelope binding still resumes"

# --- Case g: the host resume decision refuses a changed envelope binding -------
r="$workroot/g"; new_repo "$r"
meta="$workroot/g-meta.json"
head_sha="$(git -C "$r" rev-parse HEAD)"
prompt_file="$workroot/g-prompt.md"; printf 'PROMPT\n' >"$prompt_file"
prompt_sha="$(shasum -a 256 "$prompt_file" | awk '{print $1}')"
created="$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')"
cat >"$meta" <<JSON
{"schema":"singular.orchestration.session-meta.v0","provider":"codex","sessionId":"sid-g","role":"implementer","taskId":"TASK-0001","runId":"RUN-G","runner":"codex-run.sh","promptSha256":"$prompt_sha","createdAt":"$created","headShaAtCreate":"$head_sha","cwd":"$r","envelopeBinding":"sha256:aaaa"}
JSON
decide() {
  SINGULAR_ROOT="$r" SINGULAR_STATE_DIR="$r/.singular-state"   SINGULAR_INVOCATION_ENVELOPE_BINDING="$1"     "${SINGULAR_BASH_BIN:-bash}" -c '
      source "$1/engine/lib.sh"
      singular_session_resume_decide "$2" implementer TASK-0001 RUN-G \
        codex-run.sh "$3" "$4" "$5"
    ' decide-test "$ENGINE_HOME" "$meta" "$prompt_sha" "$r" "$head_sha"
}
[[ "$(decide 'sha256:aaaa')" == "resume sid-g" ]]   || fail "g: identical envelope binding should resume (got: $(decide 'sha256:aaaa'))"
[[ "$(decide 'sha256:bbbb')" == "fresh envelope-changed" ]]   || fail "g: changed envelope binding should be refused (got: $(decide 'sha256:bbbb'))"
pass "g host resume decision refuses a changed retained envelope binding"

echo "ALL CODEX-RUN SESSION CONTRACT TESTS PASSED"
