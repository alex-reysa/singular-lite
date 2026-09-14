#!/usr/bin/env bash
set -euo pipefail

# Drives a task through l1-drive.sh in a hermetic SINGULAR_ROOT (isolated events log,
# stub SINGULAR_RUNNER acting as both implementer and auditor, default provisioning)
# and asserts this node's (assumption-ledger) terminal driver wire-in: the per-run
# assumption ledger seeded from the task's context packet flows into the fix and audit
# prompts behind SINGULAR_CTX_PACKET (default 0), host-derived status transitions are
# applied across attempts via the integrated pure bricks, and behavior is
# byte-identical when the flag is OFF.
#
#   (a) OFF byte-identical (SINGULAR_CTX_PACKET unset AND =0), even with a task that
#       DECLARES assumptions: the implementer's active prompt is byte-identical to the
#       base l2 prompt, the auditor's active prompt is byte-identical to the base
#       auditor prompt, NO assumptions section is injected into either, NO ledger
#       sidecar / section files / per-attempt ledger files are written, and the task
#       is accepted exactly as before.
#   (b) ON injection (SINGULAR_CTX_PACKET=1): the implementer's active/fix prompt gains
#       the assembled fixSection (`## Assumptions to uphold` listing the assumption id)
#       and the auditor's active prompt gains the assembled auditSection
#       (`## Assumption audit` instructing the auditor to cite the assumptionId), and
#       the per-attempt ledger is recorded alongside the implementer capsule.
#   (c) host-derived transitions across attempts (stubbed retry): an auditor finding in
#       attempt 1 citing assumption id A1 flips A1 to `violated` via the integrated
#       transition, the ledger is persisted to the run_dir `assumptions-ledger.json`
#       sidecar, and attempt 2's assembled fixSection surfaces A1 as `violated` (sticky
#       carry). The accept outcome and exit status are unchanged.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-assumptions-drive.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub any inherited SINGULAR_* env (a leaked SINGULAR_DISPATCH_* or
# SINGULAR_RUNNER / SINGULAR_CTX_PACKET from a real drive would otherwise poison the
# sandbox). run.sh does this for the suite; do it here so a direct invocation is
# hermetic too.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-assumptions-drive.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
# A minimal decider prompt so decide.sh could assemble a prompt if the fast-path ever
# fell through (it should not for audit-needs-fix with budget).
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' > "$drv_root/docs/orchestration/prompts/decider.md"

# Task with a context packet declaring ONE assumption (A1). The packet grammar is the
# one the seed's parser consumes: `- [status] claim — basis`.
TASK_MD="$drv_root/docs/orchestration/tasks/TASK-0001.md"
cat >"$TASK_MD" <<'EOF'
# TASK-0001: Generic widget parser

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Context packet

### Assumptions

- [open] the widget input is utf-8 — parser assumes utf8

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

# Mock runner: implementer (level l2) writes attempt-varying content to the owned file
# (so each retry produces a real commit) plus a schema-valid worker packet; auditor
# (level readonly) returns a verdict. SCENARIO controls the auditor:
#   accept -> always accepted.
#   retry  -> first auditor call: needs-fix with a finding citing assumptionId A1;
#             subsequent calls: accepted.
# Counters are kept in files under $L2_COUNT_FILE / $AUDIT_COUNT_FILE.
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
level=""; worktree=""; out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --level) level="${args[$((i+1))]}"; i=$((i+2)) ;;
    -C|--worktree) worktree="${args[$((i+1))]}"; i=$((i+2)) ;;
    --output-last-message) out="${args[$((i+1))]}"; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  c=0; [[ -f "${L2_COUNT_FILE:-/dev/null}" ]] && c="$(cat "$L2_COUNT_FILE" 2>/dev/null || echo 0)"
  c=$((c+1)); [[ -n "${L2_COUNT_FILE:-}" ]] && echo "$c" > "$L2_COUNT_FILE"
  mkdir -p "$worktree/internal/widget"
  printf 'package widget\n// attempt %s\n' "$c" > "$worktree/internal/widget/parser.go"
  [[ -n "$out" ]] && cat > "$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  exit 0
fi
# read-only: the auditor.
ac=0; [[ -f "${AUDIT_COUNT_FILE:-/dev/null}" ]] && ac="$(cat "$AUDIT_COUNT_FILE" 2>/dev/null || echo 0)"
ac=$((ac+1)); [[ -n "${AUDIT_COUNT_FILE:-}" ]] && echo "$ac" > "$AUDIT_COUNT_FILE"
if [[ "${SCENARIO:-accept}" == "retry" && "$ac" -eq 1 ]]; then
  [[ -n "$out" ]] && printf '{"verdict":"needs-fix","findings":[{"assumptionId":"A1","status":"violated","summary":"input was not utf-8"}]}\n' > "$out"
  exit 0
fi
[[ -n "$out" ]] && printf '{"verdict":"accepted","findings":[]}\n' > "$out"
exit 0
MOCK
chmod +x "$mock_runner"

EVENTS="$drv_root/.singular-state/events.ndjson"

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

# Drive TASK-0001. Leading VAR=val args are passed to the drive's env.
run_drive() {
  ( cd "$drv_root" && env SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
      SINGULAR_ORCH_DIR="$drv_root/docs/orchestration" SINGULAR_TASKS_DIR="$drv_root/docs/orchestration/tasks" \
      SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock_runner" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      L2_COUNT_FILE="$workroot/l2-count" AUDIT_COUNT_FILE="$workroot/audit-count" \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 )
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }
json_field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

assert_accepted() {
  local run_dir="$1"
  local run_id; run_id="$(basename "$run_dir")"
  local inbox="$drv_root/.singular-state/inbox/$run_id.json"
  [[ -f "$inbox" ]] || fail "accepted: no inbox packet at $inbox"
  assert_eq "$(json_field "$inbox" status)" "accepted" "accepted: inbox packet status"
  grep -q 'Status: accepted' "$TASK_MD" || fail "accepted: task md not set to accepted"
  grep -q '"type":"l1.task_accepted"' "$EVENTS" || fail "accepted: no l1.task_accepted event"
}

# Assumption id A1's status in a ledger JSON file.
a1_status() { python3 -c 'import json,sys
o=json.load(open(sys.argv[1]))
by={a.get("id"):a.get("status") for a in o.get("assumptions",[])}
print(by.get("A1",""))' "$1"; }

# ---------------------------------------------------------------------------
# (a) OFF byte-identical, task DECLARES assumptions.
# SINGULAR_CTX_PACKET is set to 0 EXPLICITLY: as of 0.20.0 it defaults to 1, so an
# unset knob is ON and injects the assumption block. The escape hatch is the thing
# under test here, not the default.
# ---------------------------------------------------------------------------
reset_state
out="$(run_drive SINGULAR_CTX_PACKET=0 2>&1)" || { echo "$out" | tail -20; fail "OFF: drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF: no run dir"
assert_accepted "$run_dir"
# The active implementer prompt is byte-identical to the base l2 prompt (attempt 1 is a
# plain copy; no fix section injected).
cmp -s "$run_dir/l2-active-prompt.md" "$run_dir/l2-prompt.md" \
  || fail "OFF: l2 active prompt not byte-identical to base (assumptions injected?)"
# The active auditor prompt is byte-identical to the base auditor prompt.
cmp -s "$run_dir/auditor-active-prompt.md" "$run_dir/auditor-prompt.md" \
  || fail "OFF (unset): auditor active prompt not byte-identical to base"
grep -q '## Assumptions to uphold' "$run_dir/l2-active-prompt.md" && fail "OFF (unset): fix section injected"
grep -q '## Assumption audit' "$run_dir/auditor-active-prompt.md" && fail "OFF (unset): audit section injected"
[[ ! -e "$run_dir/assumptions-ledger.json" ]] || fail "OFF (unset): ledger sidecar written"
[[ -z "$(ls "$run_dir"/assumptions-*.md "$run_dir"/assumptions-attempt-*.json 2>/dev/null)" ]] \
  || fail "OFF (unset): assumptions section/attempt files written"
pass "(a) OFF (unset): prompts byte-identical to base, no assumptions artifacts"

# OFF byte-identical (explicit =0).
reset_state
out="$(run_drive SINGULAR_CTX_PACKET=0 2>&1)" || { echo "$out" | tail -20; fail "OFF (=0): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (=0): no run dir"
assert_accepted "$run_dir"
cmp -s "$run_dir/l2-active-prompt.md" "$run_dir/l2-prompt.md" \
  || fail "OFF (=0): l2 active prompt not byte-identical to base"
cmp -s "$run_dir/auditor-active-prompt.md" "$run_dir/auditor-prompt.md" \
  || fail "OFF (=0): auditor active prompt not byte-identical to base"
[[ ! -e "$run_dir/assumptions-ledger.json" ]] || fail "OFF (=0): ledger sidecar written"
pass "(a) OFF (=0): prompts byte-identical to base, no ledger sidecar"

# ---------------------------------------------------------------------------
# (b) ON injection: fix + audit sections appear; per-attempt ledger recorded.
# ---------------------------------------------------------------------------
reset_state
out="$(run_drive SINGULAR_CTX_PACKET=1 2>&1)" || { echo "$out" | tail -20; fail "ON: drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON: no run dir"
assert_accepted "$run_dir"
grep -q '## Assumptions to uphold' "$run_dir/l2-active-prompt.md" \
  || fail "ON: fixSection not injected into implementer prompt"
grep -q 'A1' "$run_dir/l2-active-prompt.md" || fail "ON: fixSection missing assumption id"
grep -q 'the widget input is utf-8' "$run_dir/l2-active-prompt.md" || fail "ON: fixSection missing assumption claim"
grep -q '## Assumption audit' "$run_dir/auditor-active-prompt.md" \
  || fail "ON: auditSection not injected into auditor prompt"
grep -q 'assumptionId' "$run_dir/auditor-active-prompt.md" || fail "ON: auditSection missing assumptionId instruction"
# The base prompts are NOT mutated (injection is on the per-attempt active files only).
grep -q '## Assumptions to uphold' "$run_dir/l2-prompt.md" && fail "ON: base l2 prompt was mutated"
grep -q '## Assumption audit' "$run_dir/auditor-prompt.md" && fail "ON: base auditor prompt was mutated"
# Per-attempt ledger recorded alongside the implementer capsule write.
[[ -f "$run_dir/assumptions-attempt-1.json" ]] || fail "ON: per-attempt ledger (attempt 1) not recorded"
assert_eq "$(a1_status "$run_dir/assumptions-attempt-1.json")" "open" "ON: attempt-1 recorded A1 status"
pass "(b) ON: fix+audit sections injected, base prompts intact, per-attempt ledger recorded"

# ---------------------------------------------------------------------------
# (c) host-derived transition across attempts (stubbed retry): attempt-1 finding
#     citing A1 flips A1 to violated in the persisted sidecar and surfaces it as
#     violated in attempt-2's fixSection (sticky carry). Accept unchanged.
# ---------------------------------------------------------------------------
reset_state
ec=0
out="$(run_drive SINGULAR_CTX_PACKET=1 SCENARIO=retry SINGULAR_MAX_RETRIES=1 2>&1)" || ec=$?
assert_eq "$ec" "0" "(c) retry: drive accepted (exit 0)"
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "(c) retry: no run dir"
assert_accepted "$run_dir"
# The auditor ran twice (attempt 1 needs-fix, attempt 2 accepted).
assert_eq "$(cat "$workroot/audit-count" 2>/dev/null || echo 0)" "2" "(c) retry: auditor invoked twice"
# Sidecar persisted with A1 flipped to violated by the host-derived transition.
[[ -f "$run_dir/assumptions-ledger.json" ]] || fail "(c) retry: ledger sidecar not persisted"
assert_eq "$(a1_status "$run_dir/assumptions-ledger.json")" "violated" "(c) retry: sidecar A1 status after transition"
# Attempt 2's active fix prompt (the file holds the LAST attempt) surfaces A1 as a
# violated assumption to address (sticky carry into the next attempt's assemble).
grep -q 'Violated assumptions' "$run_dir/l2-active-prompt.md" \
  || fail "(c) retry: attempt-2 fixSection does not surface violated assumptions"
# The per-attempt ledger for attempt 2 shows A1 violated (carried), attempt 1 open.
[[ -f "$run_dir/assumptions-attempt-2.json" ]] || fail "(c) retry: attempt-2 ledger not recorded"
assert_eq "$(a1_status "$run_dir/assumptions-attempt-2.json")" "violated" "(c) retry: attempt-2 recorded A1 sticky-violated"
assert_eq "$(a1_status "$run_dir/assumptions-attempt-1.json")" "open" "(c) retry: attempt-1 recorded A1 open"
pass "(c) retry: A1 flipped to violated, persisted, and carried sticky into attempt 2"

echo "ALL CTX-ASSUMPTIONS-DRIVE TESTS PASSED"
