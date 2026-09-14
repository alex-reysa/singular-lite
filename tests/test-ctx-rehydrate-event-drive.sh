#!/usr/bin/env bash
set -euo pipefail

# Drives a task through engine/l1-drive.sh in a hermetic SINGULAR_ROOT (isolated
# events log, stub SINGULAR_RUNNER acting as both implementer and auditor) and
# asserts this slice's driver wire-in: the implementer routing-decision emission
# of `context.strategy_selected` gains an explicit `rehydrate` branch that records
# the assembled strategy-event payload (strategy=rehydrate + refusal reason + the
# nested packet manifest) via the integrated pure assembler
# `singular_ctx_rehydrate_event_data`. The `resume` and `fresh` (`else`) branches
# stay byte-identical, so with SINGULAR_REHYDRATE unset every emitted event is
# exactly as before this wire-in.
#
# The scenario forces the implementer decision to `rehydrate <reason>` at the
# non-pinned `implement` step:
#   attempt 1 : worker OK (writes a valid packet + a session meta carrying a
#               session id) but the auditor returns needs-fix -> a retry is queued
#               and the implementer session meta is finalized (resumable).
#   attempt 2 : the routing spine would `resume` the finalized session, but the
#               window-pressure resume gate (SINGULAR_SESSION_WINDOW_MAX_PCT=0)
#               refuses it. Behind SINGULAR_REHYDRATE=1 the refusal upgrades to
#               `rehydrate window-pressure` (run_dir holds attempt-1 durable
#               artifacts). The worker then emits no packet, so the attempt fails
#               BEFORE any durable artifact under run_dir is rewritten -> run_dir
#               is frozen at its attempt-1 state, and the manifest recorded in the
#               event equals the manifest recomputed over run_dir at drive end.
#
# Assertions:
#   (RED core) ON rehydrate recording: with SINGULAR_CTX_ROUTING=1 and
#     SINGULAR_REHYDRATE=1 the LAST implementer context.strategy_selected event has
#     data.strategy == "rehydrate", data.reason == "window-pressure",
#     data.role == "implementer", and a nested data.manifest whose sources equal
#     `singular_ctx_rehydrate_manifest` applied to `singular_ctx_rehydrate_sources
#     <run_dir>` for that run.
#   (OFF-parity) with SINGULAR_REHYDRATE unset (and =0) the same path records the
#     existing strategy=fresh event with reason "window-pressure" and NO manifest.
#   (resume unchanged) with no window pressure the attempt-2 decision resumes and
#     the event records strategy=resume with the session id and NO manifest.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-event-drive.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub inherited SINGULAR_* so a leaked knob can't poison the sandbox.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-rehydrate-event-drive.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

# Source lib.sh (which auto-sources the ctx-*.sh bricks) so the test can recompute
# the expected manifest with the SAME pure helpers the driver delegates into.
export SINGULAR_ROOT="$workroot/libroot"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"
[[ "$(type -t singular_ctx_rehydrate_event_data)" == "function" ]] \
  || fail "singular_ctx_rehydrate_event_data not defined (assembler missing)"
[[ "$(type -t singular_ctx_rehydrate_sources)" == "function" ]] \
  || fail "singular_ctx_rehydrate_sources not defined (resolver missing)"
[[ "$(type -t singular_ctx_rehydrate_manifest)" == "function" ]] \
  || fail "singular_ctx_rehydrate_manifest not defined (assembler missing)"

# --- Driver fixture repo -----------------------------------------------------
drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' > "$drv_root/docs/orchestration/prompts/decider.md"

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

TASK_MD="$drv_root/docs/orchestration/tasks/TASK-0001.md"
EVENTS="$drv_root/.singular-state/events.ndjson"

# Mock runner. L2 (implementer): on the attempt named by WORKER_FAIL_ON it emits an
# EMPTY last-message (worker-no-packet -> the attempt fails before any durable
# artifact under run_dir is rewritten); otherwise it writes an attempt-varying owned
# file, a schema-valid packet, and a session meta carrying a session id (so the NEXT
# attempt's meta is resumable). Read-only (auditor): first call needs-fix, then
# accepted, driving exactly one retry.
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<MOCK
#!/usr/bin/env bash
set -uo pipefail
source "$SCRIPT_DIR/lib.sh"
level=""; worktree=""; out=""; meta=""
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    --level) level="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    -C|--worktree) worktree="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --output-last-message) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --session-meta) meta="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ "\$level" == "l2" ]]; then
  # Emit stdout so the driver's worker-codex.log transcript is non-empty (the
  # window-pressure resume gate reads that file; an empty transcript estimates 0
  # tokens and would PASS even at MAX_PCT=0).
  echo "mock l2 worker ran"
  c=0; [[ -f "\${L2_COUNT_FILE:-/dev/null}" ]] && c="\$(cat "\$L2_COUNT_FILE" 2>/dev/null || echo 0)"
  c=\$((c+1)); [[ -n "\${L2_COUNT_FILE:-}" ]] && echo "\$c" > "\$L2_COUNT_FILE"
  if [[ -n "\${WORKER_FAIL_ON:-}" && "\$c" == "\${WORKER_FAIL_ON}" ]]; then
    # Emit no packet: an empty last-message is worker-no-packet (fails early).
    [[ -n "\$out" ]] && : > "\$out"
    exit 0
  fi
  mkdir -p "\$worktree/internal/widget"
  printf 'package widget\n// attempt %s\n' "\$c" > "\$worktree/internal/widget/parser.go"
  [[ -n "\$out" ]] && cat > "\$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  [[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "WORKER-SID" "gpt-5.5" "medium" "\$worktree" 0
  exit 0
fi
# read-only: the auditor.
ac=0; [[ -f "\${AUDIT_COUNT_FILE:-/dev/null}" ]] && ac="\$(cat "\$AUDIT_COUNT_FILE" 2>/dev/null || echo 0)"
ac=\$((ac+1)); [[ -n "\${AUDIT_COUNT_FILE:-}" ]] && echo "\$ac" > "\$AUDIT_COUNT_FILE"
[[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "REVIEWER-SID" "gpt-5.5" "high" "\$worktree" 0
if [[ "\${SCENARIO:-accept}" == "needs-fix-first" && "\$ac" -eq 1 ]]; then
  [[ -n "\$out" ]] && printf '{"verdict":"needs-fix","findings":[{"summary":"fix it"}]}\n' > "\$out"
  exit 0
fi
[[ -n "\$out" ]] && printf '{"verdict":"accepted","findings":[]}\n' > "\$out"
exit 0
MOCK
chmod +x "$mock_runner"

reset_state() {
  git -C "$drv_root" checkout -q target 2>/dev/null || true
  rm -rf "$drv_root/.singular-state/runs" "$drv_root/.singular-state/leases" \
    "$drv_root/.singular-state/inbox" "$drv_root/.singular-state/review-policy" \
    "$drv_root/.worktrees" 2>/dev/null || true
  : > "$EVENTS"
  rm -f "$drv_root/docs/orchestration/decisions.md" 2>/dev/null || true
  rm -f "$workroot/l2-count" "$workroot/audit-count" 2>/dev/null || true
  python3 - "$TASK_MD" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r"Status: \w+", "Status: ready", t, count=1)
open(p, "w").write(t)
PY
  git -C "$drv_root" worktree prune 2>/dev/null || true
  git -C "$drv_root" branch -D agent/widget/TASK-0001-generic 2>/dev/null || true
}

# Drive TASK-0001. Leading VAR=val args are passed to the drive's env. Never fails
# the test on a non-zero drive exit (a terminal-failure drive is expected in the
# rehydrate/off scenarios where attempt 2 emits no packet).
run_drive() {
  ( cd "$drv_root" && env SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
      SINGULAR_ORCH_DIR="$drv_root/docs/orchestration" SINGULAR_TASKS_DIR="$drv_root/docs/orchestration/tasks" \
      SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock_runner" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      L2_COUNT_FILE="$workroot/l2-count" AUDIT_COUNT_FILE="$workroot/audit-count" \
      SINGULAR_MAX_RETRIES=1 \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 ) || true
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }

# The LAST implementer context.strategy_selected event's `data` object (compact JSON).
last_impl_strategy_data() {
  python3 - "$1" <<'PY'
import json, sys
last = None
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("type") != "context.strategy_selected":
        continue
    d = ev.get("data", {})
    if isinstance(d, dict) and d.get("role") == "implementer":
        last = d
if last is None:
    sys.exit(3)
sys.stdout.write(json.dumps(last, sort_keys=True, separators=(",", ":")))
PY
}

jq_field() { python3 -c 'import json,sys
v = json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print(v if v is not None else "")' "$1" "$2"; }

# The manifest.sources the assembler would embed for this run, recomputed over the
# (frozen) run_dir with the SAME pure helpers the driver delegates into.
expected_manifest_sources() {
  local run_dir="$1"
  local -a specs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && specs+=("$line")
  done < <(singular_ctx_rehydrate_sources "$run_dir")
  local manifest
  manifest="$(singular_ctx_rehydrate_manifest ${specs[@]+"${specs[@]}"})"
  python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]).get("sources"), sort_keys=True, separators=(",", ":")))' "$manifest"
}

# ---------------------------------------------------------------------------
# (RED core) ON rehydrate: strategy=rehydrate + reason + nested manifest.
# ---------------------------------------------------------------------------
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
  SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON: no run dir produced"
data="$(last_impl_strategy_data "$EVENTS")" || fail "ON: no implementer strategy_selected event"
assert_eq "$(jq_field "$data" strategy)" "rehydrate" "ON: strategy recorded as rehydrate"
assert_eq "$(jq_field "$data" reason)" "window-pressure" "ON: refusal reason carried forward"
assert_eq "$(jq_field "$data" role)" "implementer" "ON: role is implementer"
# The nested manifest (object, not a stringified blob) records the packet manifest.
manifest_schema="$(jq_field "$data" manifest.schema)"
assert_eq "$manifest_schema" "singular.orchestration.ctx-rehydrate-manifest.v0" "ON: nested manifest schema"
got_sources="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["manifest"]["sources"], sort_keys=True, separators=(",",":")))' "$data")"
want_sources="$(expected_manifest_sources "$run_dir")"
[[ "$want_sources" != "[]" && "$want_sources" != "null" ]] \
  || fail "ON: expected a non-empty durable source set under run_dir (sanity)"
assert_eq "$got_sources" "$want_sources" "ON: manifest.sources == manifest(sources(run_dir))"
pass "(ON) rehydrate recorded: strategy=rehydrate, reason, nested packet manifest"

# ---------------------------------------------------------------------------
# (OFF-parity) SINGULAR_REHYDRATE unset -> the same path records strategy=fresh
# with reason window-pressure and NO manifest (byte-identical to pre-wire-in).
# ---------------------------------------------------------------------------
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
  SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
[[ -n "$(run_dir_of)" ]] || fail "OFF: no run dir produced"
data="$(last_impl_strategy_data "$EVENTS")" || fail "OFF: no implementer strategy_selected event"
assert_eq "$(jq_field "$data" strategy)" "fresh" "OFF: refused resume recorded as fresh (no rehydrate upgrade)"
assert_eq "$(jq_field "$data" reason)" "window-pressure" "OFF: refusal reason carried forward"
[[ "$(jq_field "$data" manifest.schema)" == "" ]] || fail "OFF: fresh event must carry no manifest"
pass "(OFF) SINGULAR_REHYDRATE unset: refused resume records fresh window-pressure, no manifest"

# ---------------------------------------------------------------------------
# (resume unchanged) no window pressure -> attempt-2 decision resumes and records
# strategy=resume with the session id and NO manifest.
# ---------------------------------------------------------------------------
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 \
  SCENARIO=needs-fix-first >/dev/null 2>&1
[[ -n "$(run_dir_of)" ]] || fail "resume: no run dir produced"
data="$(last_impl_strategy_data "$EVENTS")" || fail "resume: no implementer strategy_selected event"
assert_eq "$(jq_field "$data" strategy)" "resume" "resume: attempt-2 decision resumes the session"
assert_eq "$(jq_field "$data" sessionId)" "WORKER-SID" "resume: records the resumed session id"
[[ "$(jq_field "$data" manifest.schema)" == "" ]] || fail "resume: resume event must carry no manifest"
pass "(resume) unchanged: attempt-2 records strategy=resume with session id, no manifest"

echo "ALL CTX-REHYDRATE-EVENT-DRIVE TESTS PASSED"
