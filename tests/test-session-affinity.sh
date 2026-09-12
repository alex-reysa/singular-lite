#!/usr/bin/env bash
set -euo pipefail

# Session-affinity unit + integration tests (T-E5). Covers:
#  - singular_session_resume_decide: each gate fires with the right reason, in order
#    (disabled, no-session, no-session-id, role-mismatch, run-mismatch,
#    runner-changed, prompt-template-changed, expired, head-rewritten via a real
#    2-commit non-ancestor fixture, worktree-moved), all-pass -> resume;
#  - singular_session_meta_finalize: merges host fields, synthesizes a minimal meta
#    when the runner wrote nothing, never fails;
#  - the runner-written meta -> finalize -> decide roundtrip produces `resume`;
#  - SINGULAR_SESSION_AFFINITY=0 -> every decision is `fresh disabled`;
#  - the implementer meta is NEVER usable for the reviewer (role gate), proving
#    cross-role reuse is structurally impossible (separate file + role mismatch).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-session-affinity.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-affinity.XXXXXX")"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

export SINGULAR_ROOT="$workroot/repo"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

# A real worktree so the lineage gate (git merge-base --is-ancestor) is exercised.
wt="$workroot/wt"; mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
echo a > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"
echo b > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"
# A divergent branch so HEAD1 is NOT an ancestor of HEAD_FORK (head-rewritten).
git -C "$wt" checkout -q -b fork "$HEAD1"
echo x > "$wt/x"; git -C "$wt" add x; git -C "$wt" commit -qm fork1
HEAD_FORK="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" checkout -q master 2>/dev/null || git -C "$wt" checkout -q main 2>/dev/null || git -C "$wt" checkout -q "$HEAD2"

PROMPT="$workroot/prompt.md"; printf 'base prompt\n' > "$PROMPT"
PSHA="$(singular_prompt_sha "$PROMPT")"
[[ -n "$PSHA" ]] || fail "singular_prompt_sha returned empty for a real file"

# Forge a meta file. forge_meta <path> [k=v ...] over a base good doc.
forge_meta() {
  local path="$1"; shift
  python3 - "$path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
doc = {
    "schema": "singular.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-1", "model": "m", "effort": "e",
    "cwd": "__WT__", "exitCode": 0, "createdAt": "__NOW__",
    "role": "implementer", "taskId": "TASK-1", "runId": "RUN-1",
    "runner": "codex-run.sh", "promptSha256": "__PSHA__",
    "headShaAtCreate": "__HEAD1__", "lastUsedAttempt": 1,
}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    doc[k] = v
with open(path, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
PY
}

# Substitution helper: forge with placeholders resolved.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mk() { # mk <path> [extra k=v ...] — writes a base-good meta then applies overrides
  local path="$1"; shift
  forge_meta "$path" \
    "cwd=$wt" "createdAt=$NOW" "promptSha256=$PSHA" "headShaAtCreate=$HEAD1" "$@"
}

decide() { # decide <meta> <role> <task> <run> <runner> <psha> <wt> <lineage_head>
  singular_session_resume_decide "$@"
}

# --- Gate 1: affinity disabled -------------------------------------------------
m="$workroot/g1.json"; mk "$m"
out="$(SINGULAR_SESSION_AFFINITY=0 decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "gate1 disabled"
pass "gate 1: SINGULAR_SESSION_AFFINITY=0 -> fresh disabled"

# --- Gate 2: meta missing ------------------------------------------------------
out="$(decide "$workroot/does-not-exist.json" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session" "gate2 missing"
# Unparseable meta -> also no-session.
m="$workroot/g2.json"; printf 'not json{' > "$m"
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session" "gate2 unparseable"
pass "gate 2: missing/unparseable meta -> fresh no-session"

# --- Gate 3: empty provider or sessionId --------------------------------------
m="$workroot/g3.json"; mk "$m" "sessionId="
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session-id" "gate3 empty sid"
mk "$m" "provider="
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session-id" "gate3 empty provider"
pass "gate 3: empty provider/sessionId -> fresh no-session-id"

# --- Gate 4: role mismatch (defense-in-depth) ----------------------------------
m="$workroot/g4.json"; mk "$m" "role=implementer"
out="$(decide "$m" reviewer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh role-mismatch" "gate4 role"
pass "gate 4: role mismatch -> fresh role-mismatch"

# --- Gate 5: run mismatch (task or run) ----------------------------------------
m="$workroot/g5.json"; mk "$m"
out="$(decide "$m" implementer TASK-OTHER RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh run-mismatch" "gate5 task"
out="$(decide "$m" implementer TASK-1 RUN-OTHER codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh run-mismatch" "gate5 run"
pass "gate 5: task/run mismatch -> fresh run-mismatch"

# --- Gate 6: runner changed ----------------------------------------------------
m="$workroot/g6.json"; mk "$m" "runner=codex-run.sh"
out="$(decide "$m" implementer TASK-1 RUN-1 claude-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh runner-changed" "gate6 runner"
pass "gate 6: runner changed -> fresh runner-changed"

# --- Gate 7: prompt-template-changed ------------------------------------------
m="$workroot/g7.json"; mk "$m"
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "DIFFERENT-SHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh prompt-template-changed" "gate7 prompt"
pass "gate 7: prompt sha changed -> fresh prompt-template-changed"

# --- Gate 8: expired (old createdAt) ------------------------------------------
m="$workroot/g8.json"; mk "$m" "createdAt=2000-01-01T00:00:00Z"
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh expired" "gate8 expired"
pass "gate 8: stale createdAt -> fresh expired"

# --- Gate 9: head-rewritten (HEAD2 not an ancestor of HEAD_FORK) ---------------
# HEAD_FORK branched off HEAD1 then diverged, so HEAD2 (the c2 commit) is NOT an
# ancestor of HEAD_FORK -> lineage gate fails -> head-rewritten.
m="$workroot/g9.json"; mk "$m" "headShaAtCreate=$HEAD2"
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD_FORK")"
assert_eq "$out" "fresh head-rewritten" "gate9 non-ancestor"
# Empty headShaAtCreate with a non-empty sessionId -> lineage skipped (allowed).
m="$workroot/g9b.json"; mk "$m" "headShaAtCreate="
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "resume SID-1" "gate9 empty head skips lineage"
pass "gate 9: non-ancestor head -> fresh head-rewritten; empty head skips lineage"

# --- Gate 10: worktree moved ---------------------------------------------------
m="$workroot/g10.json"; mk "$m" "cwd=/some/other/worktree"
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh worktree-moved" "gate10 cwd"
pass "gate 10: cwd != worktree -> fresh worktree-moved"

# --- All pass -> resume <sessionId> -------------------------------------------
m="$workroot/ok.json"; mk "$m"
out="$(decide "$m" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "resume SID-1" "all-pass resume"
pass "all gates pass -> resume SID-1"

# --- Finalize: minimal meta synthesized when the runner wrote nothing ----------
mp="$workroot/fin-missing.json"
singular_session_meta_finalize "$mp" implementer TASK-9 RUN-9 codex-run.sh "$PSHA" "$HEAD1" 3 \
  || fail "finalize must never fail"
[[ -f "$mp" ]] || fail "finalize must synthesize a meta when none exists"
assert_eq "$(python3 -c 'import json;print(json.load(open("'"$mp"'"))["sessionId"])')" "" "finalize: empty sessionId when synthesized"
assert_eq "$(python3 -c 'import json;print(json.load(open("'"$mp"'"))["role"])')" "implementer" "finalize: role merged"
pass "finalize synthesizes a minimal meta (empty sessionId) when runner wrote none"

# --- Roundtrip: runner meta -> finalize -> decide = resume ---------------------
rp="$workroot/round.json"
# Simulate the codex runner writing its half.
singular_codex_session_meta_write "$rp" "SID-RT" "m" "e" "$wt" 0
# Host merges its authority fields (head = HEAD1, an ancestor of HEAD2).
singular_session_meta_finalize "$rp" implementer TASK-RT RUN-RT codex-run.sh "$PSHA" "$HEAD1" 1
out="$(decide "$rp" implementer TASK-RT RUN-RT codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "resume SID-RT" "roundtrip resume"
pass "roundtrip: runner-write -> finalize -> decide = resume SID-RT"

# --- SINGULAR_SESSION_AFFINITY=0 forces fresh on a known-good meta ------------------
out="$(SINGULAR_SESSION_AFFINITY=0 decide "$rp" implementer TASK-RT RUN-RT codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "affinity-0 forces fresh"
pass "SINGULAR_SESSION_AFFINITY=0 forces fresh disabled even on a perfect meta"

# --- Reviewer can NEVER reuse the implementer meta -----------------------------
# Same good implementer meta, but decided under the reviewer role -> role gate
# blocks it. In the driver these are also SEPARATE files, so this is belt+braces.
out="$(decide "$rp" reviewer TASK-RT RUN-RT codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$out" "fresh role-mismatch" "reviewer cannot reuse implementer meta"
pass "reviewer is never offered the implementer session (role gate blocks reuse)"

# =============================================================================
# Driver-level wiring: a real l1-drive.sh run with a mock runner recording argv.
# Asserts: attempt-1 worker is FRESH (no prior meta) yet writes a meta carrying a
# session id; a contrived attempt-2 with all gates matching resumes (argv has
# --resume-session <id> + a context.strategy_selected strategy=resume event); the
# reviewer never receives the implementer session id (separate session-reviewer.json
# + role gate); and SINGULAR_SESSION_AFFINITY=0 puts NO --resume-session in any argv.
# =============================================================================

drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
cat >"$drv_root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Generic widget parser

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the widget parser.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Parser handles empty input.
EOF
git -C "$drv_root" add .
git -C "$drv_root" commit -qm init

# Mock runner: records argv per-role, writes a valid worker packet / accepted
# verdict, and honors --session-meta by writing a session id (the runner's job).
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
SD="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
level=""; worktree=""; out=""; meta=""; resume=""; argv="\$*"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --level) level="\$2"; shift 2 ;;
    -C|--worktree) worktree="\$2"; shift 2 ;;
    --output-last-message) out="\$2"; shift 2 ;;
    --session-meta) meta="\$2"; shift 2 ;;
    --resume-session) resume="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "\$level" == "l2" ]]; then
  printf '%s\n' "\$argv" >> "$workroot/worker-argv.log"
  if [[ "\${SINGULAR_TEST_FORCE_INFRA_RETRY:-0}" == "1" ]]; then
    count=0
    [[ -f "$workroot/worker-infra-count" ]] && count="\$(cat "$workroot/worker-infra-count")"
    printf '%s\n' "\$((count + 1))" > "$workroot/worker-infra-count"
    [[ "\$count" -gt 0 ]] || exit 124
  fi
  mkdir -p "\$worktree/internal/widget"
  printf 'package widget\n' > "\$worktree/internal/widget/parser.go"
  # A COMPLETE, schema-valid worker packet (the driver re-stamps authority fields
  # afterward but singular_l1_prepare_worker_packet validates the RAW packet first).
  [[ -n "\$out" ]] && cat > "\$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  [[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "WORKER-SID" "gpt-5.5" "medium" "\$worktree" 0
else
  printf '%s\n' "\$argv" >> "$workroot/auditor-argv.log"
  if [[ "\${SINGULAR_TEST_FORCE_INFRA_RETRY:-0}" == "1" ]]; then
    count=0
    [[ -f "$workroot/auditor-infra-count" ]] && count="\$(cat "$workroot/auditor-infra-count")"
    printf '%s\n' "\$((count + 1))" > "$workroot/auditor-infra-count"
    [[ "\$count" -gt 0 ]] || exit 124
  fi
  [[ -n "\$out" ]] && printf '{"verdict":"accepted"}\n' > "\$out"
  [[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "REVIEWER-SID" "gpt-5.5" "high" "\$worktree" 0
fi
exit 0
MOCK
chmod +x "$mock_runner"

run_drive() {
  # Leading VAR=val args (if any) are passed through to env for the drive.
  ( cd "$drv_root" && env SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
      SINGULAR_ORCH_DIR="$drv_root/docs/orchestration" SINGULAR_TASKS_DIR="$drv_root/docs/orchestration/tasks" \
      SINGULAR_TARGET_BRANCH=target SINGULAR_DISPATCH_BASE_SHA= SINGULAR_DISPATCH_BATCH_ID= \
      SINGULAR_CTX_ROUTING=0 SINGULAR_RUNNER="$mock_runner" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 )
}

# --- Attempt 1: fresh worker (no prior meta), meta written with a session id ----
: > "$workroot/worker-argv.log"; : > "$workroot/auditor-argv.log"
events="$drv_root/.singular-state/events.ndjson"
out="$(run_drive 2>&1)" || { echo "$out" | tail -20; fail "drive run failed"; }
# The implementer's FIRST run must be fresh (no --resume-session in worker argv).
grep -q -- "--resume-session" "$workroot/worker-argv.log" && fail "attempt-1 worker must be fresh (no --resume-session)"
grep -q -- "--session-meta" "$workroot/worker-argv.log" || fail "worker must always receive --session-meta"
# A session-implementer.json meta with the worker session id must have been finalized.
run_dir="$(ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1)"
[[ -n "$run_dir" ]] || fail "no run dir produced"
imeta="$run_dir/session-implementer.json"
[[ -f "$imeta" ]] || fail "session-implementer.json not written"
assert_eq "$(python3 -c 'import json;print(json.load(open("'"$imeta"'"))["sessionId"])')" "WORKER-SID" "implementer meta session id"
assert_eq "$(python3 -c 'import json;print(json.load(open("'"$imeta"'"))["role"])')" "implementer" "implementer meta role"
# The reviewer meta is SEPARATE and carries the reviewer session id, never the worker's.
rmeta="$run_dir/session-reviewer.json"
[[ -f "$rmeta" ]] || fail "session-reviewer.json not written"
assert_eq "$(python3 -c 'import json;print(json.load(open("'"$rmeta"'"))["sessionId"])')" "REVIEWER-SID" "reviewer meta session id"
assert_eq "$(python3 -c 'import json;print(json.load(open("'"$rmeta"'"))["role"])')" "reviewer" "reviewer meta role"
# The reviewer argv must never carry the implementer's session id.
if grep -q -- "WORKER-SID" "$workroot/auditor-argv.log"; then fail "reviewer argv leaked the implementer session id"; fi
# A fresh strategy_selected event for the implementer was emitted.
grep -q '"context.strategy_selected"' "$events" || fail "no context.strategy_selected event"
grep -q '"role":"implementer"' "$events" || fail "no implementer strategy event"
pass "driver attempt-1: worker fresh + per-role metas written (no cross-role leak)"

# --- Contrived attempt-2: a matching implementer meta -> resume in the argv -----
# Reuse the finalized attempt-1 implementer meta as the prior meta for a SECOND
# drive of the same task+run. We force matching gates by reusing run_dir's run id,
# the same runner basename, and the same prompt template (unchanged). To exercise
# the resume decision deterministically without re-running the whole loop, assert
# at the decision boundary: the decider returns resume for the finalized meta.
worker_prompt="$run_dir/l2-prompt.md"
[[ -f "$worker_prompt" ]] || worker_prompt="$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
wpsha="$(singular_prompt_sha "$worker_prompt")"
run_id="$(basename "$run_dir")"
# The worktree the worker ran in (the meta's recorded cwd) is the lineage anchor.
drv_wt="$(python3 -c 'import json;print(json.load(open("'"$imeta"'"))["cwd"])')"
task_run_head="$(git -C "$drv_wt" rev-parse HEAD)"
# Re-finalize the meta with a head that is an ancestor of the worktree head and a
# matching prompt sha so every gate passes for a same-run, same-runner resume.
singular_session_meta_finalize "$imeta" implementer TASK-0001 "$run_id" "$(basename "$mock_runner")" \
  "$wpsha" "$task_run_head" 1
dec="$(singular_session_resume_decide "$imeta" implementer TASK-0001 "$run_id" "$(basename "$mock_runner")" \
  "$wpsha" "$drv_wt" "$task_run_head")"
assert_eq "$dec" "resume WORKER-SID" "attempt-2 decision resumes the implementer session"
pass "driver attempt-2: matching gates -> decider returns 'resume WORKER-SID'"

# --- SINGULAR_SESSION_AFFINITY=0: no --resume-session ever, decisions all fresh -----
dec0="$(SINGULAR_SESSION_AFFINITY=0 singular_session_resume_decide "$imeta" implementer TASK-0001 "$run_id" \
  "$(basename "$mock_runner")" "$wpsha" "$drv_wt" "$task_run_head")"
assert_eq "$dec0" "fresh disabled" "affinity-0 decision is fresh disabled"
# A full drive under affinity=0 must put NO --resume-session in any argv.
: > "$workroot/worker-argv.log"; : > "$workroot/auditor-argv.log"
git -C "$drv_root" checkout -q target
rm -rf "$drv_root/.singular-state/runs" "$drv_root/.singular-state/leases" 2>/dev/null || true
# Reset task status back to ready for a second drive.
python3 - "$drv_root/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read().replace("Status: accepted", "Status: ready")
open(p, "w").write(t)
PY
git -C "$drv_root" worktree prune 2>/dev/null || true
out2="$(run_drive SINGULAR_SESSION_AFFINITY=0 2>&1)" || { echo "$out2" | tail -20; fail "affinity-0 drive failed"; }
grep -q -- "--resume-session" "$workroot/worker-argv.log" && fail "affinity-0: worker argv must contain no --resume-session"
grep -q -- "--resume-session" "$workroot/auditor-argv.log" && fail "affinity-0: auditor argv must contain no --resume-session"
pass "SINGULAR_SESSION_AFFINITY=0: no --resume-session in any argv; decisions fresh disabled"

# --- Infra retry contract: resumable try 0, fresh try 1 for BOTH roles --------
mkdir -p "$workroot/bin"
cat > "$workroot/bin/date" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == +RUN-* ]]; then
    printf 'RUN-AFFINITY-INFRA\n'
    exit 0
  fi
done
exec /bin/date "$@"
SH
chmod +x "$workroot/bin/date"

git -C "$drv_root" checkout -q target
rm -rf "$drv_root/.singular-state/runs" "$drv_root/.singular-state/leases" 2>/dev/null || true
python3 - "$drv_root/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read().replace("Status: accepted", "Status: ready")
open(p, "w").write(t)
PY
git -C "$drv_root" worktree prune 2>/dev/null || true

retry_run_id="RUN-AFFINITY-INFRA"
retry_run_dir="$drv_root/.singular-state/runs/$retry_run_id"
retry_worker_meta="$retry_run_dir/session-implementer.json"
retry_reviewer_meta="$retry_run_dir/session-reviewer.json"
warmup_out="$(run_drive PATH="$workroot/bin:$PATH" 2>&1)" \
  || { echo "$warmup_out" | tail -40; fail "affinity retry warmup drive failed"; }
[[ -f "$retry_worker_meta" && -f "$retry_reviewer_meta" ]] \
  || fail "warmup drive must record both resumable role sessions"

git -C "$drv_root" checkout -q target
rm -rf "$drv_root/.singular-state/leases" 2>/dev/null || true
python3 - "$drv_root/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read().replace("Status: accepted", "Status: ready")
open(p, "w").write(t)
PY
git -C "$drv_root" worktree prune 2>/dev/null || true

retry_wt="$(python3 -c 'import json;print(json.load(open("'"$retry_worker_meta"'"))["cwd"])')"
retry_head="$(git -C "$drv_root" rev-parse HEAD)"
singular_session_meta_finalize "$retry_worker_meta" implementer TASK-0001 "$retry_run_id" \
  "$(basename "$mock_runner")" "$(singular_prompt_sha "$retry_run_dir/l2-prompt.md")" "$retry_head" 1
singular_session_meta_finalize "$retry_reviewer_meta" reviewer TASK-0001 "$retry_run_id" \
  "$(basename "$mock_runner")" "$(singular_prompt_sha "$retry_run_dir/auditor-prompt.md")" "$retry_head" 1
retry_worker_decision="$(singular_session_resume_decide "$retry_worker_meta" implementer TASK-0001 \
  "$retry_run_id" "$(basename "$mock_runner")" "$(singular_prompt_sha "$retry_run_dir/l2-prompt.md")" \
  "$retry_wt" "$retry_head")"
assert_eq "$retry_worker_decision" "resume WORKER-SID" \
  "recorded worker session must be resumable before forcing its infra retry"

: > "$workroot/worker-argv.log"; : > "$workroot/auditor-argv.log"
rm -f "$workroot/worker-infra-count" "$workroot/auditor-infra-count"
retry_out="$(run_drive PATH="$workroot/bin:$PATH" SINGULAR_TEST_FORCE_INFRA_RETRY=1 \
  SINGULAR_WORKER_INFRA_MAX=1 SINGULAR_AUDIT_INFRA_MAX=1 2>&1)" \
  || { echo "$retry_out" | tail -40; fail "infra-retry affinity drive failed"; }
assert_eq "$(wc -l < "$workroot/worker-argv.log" | tr -d ' ')" "2" "worker infra retry invocation count"
assert_eq "$(wc -l < "$workroot/auditor-argv.log" | tr -d ' ')" "2" "auditor infra retry invocation count"
grep -q -- "--resume-session WORKER-SID" <(sed -n '1p' "$workroot/worker-argv.log") \
  || fail "worker try 0 must receive its resumable session"
grep -q -- "--resume-session" <(sed -n '2p' "$workroot/worker-argv.log") \
  && fail "worker try 1 must be fresh after infra failure"
# The AUDITOR never resumes — on any try. Until 0.20.0 this file asserted the
# opposite ("auditor try 0 must receive its resumable session"), which is the
# defect stated as an expectation: the reviewer's session-meta IS resumable here
# (the fixture forges REVIEWER-SID and the step-blind decider returns
# `resume REVIEWER-SID`), and the driver handed it straight to the auditor. That
# is an auditor grading a diff from inside the session that formed its previous
# verdict. `final-audit` is now an independence-pinned step, so the routing spine
# refuses it as `fresh tainted` in EVERY configuration, and no auditor invocation
# on any attempt may carry --resume-session.
grep -q -- "--resume-session" <(sed -n '1p' "$workroot/auditor-argv.log") \
  && fail "auditor try 0 must be fresh: final-audit is independence-pinned"
grep -q -- "--resume-session" <(sed -n '2p' "$workroot/auditor-argv.log") \
  && fail "auditor try 1 must be fresh after infra failure"
pass "infra retries: worker try 0 resumes; EVERY auditor invocation is fresh (independence pin)"

echo "ALL SESSION-AFFINITY TESTS PASSED"
