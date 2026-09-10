#!/usr/bin/env bash
set -euo pipefail

# Drives a task through l1-drive.sh's acceptance path in a hermetic SINGULAR_ROOT
# (isolated events log, stub SINGULAR_RUNNER yielding an accepted verdict, default
# provisioning) and asserts the FIRST post-acceptance paired-audit hook this
# node owns: a call site placed STRICTLY AFTER acceptance is finalized (packet
# status accepted, lease/task status accepted, accept decision recorded, inbox
# packet written, l1.task_accepted appended) that delegates into
# singular_ctx_paired_audit_record from the integrated engine/ctx-paired-audit.sh.
#
#   (a) default-OFF (SINGULAR_PAIRED_AUDIT_PCT unset AND =0): the accepted path is
#       byte-identical to pre-hook behavior — the same acceptance artifacts and
#       events, NO ctx.paired_audit event, and NO paired-audit.json.
#   (b) PCT=100 on an accepted task: exactly one ctx.paired_audit event and one
#       paired-audit.json in the run dir, while the acceptance outcome (packet
#       status accepted, lease/task status accepted, the accept decision, the
#       inbox packet at $SINGULAR_INBOX_DIR/$run_id.json, and the l1.task_accepted
#       event) is unchanged; the ctx.paired_audit event is ordered STRICTLY after
#       l1.task_accepted.
#   (c) invariance: a FAILING paired runner never changes the accept/reject
#       decision or the process exit status — the accepted outcome is untouched.
#   (d) a non-accepted (needs-fix/parked) run invokes NO paired audit and writes
#       NO paired record.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-l1-drive-paired-audit-hook.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub any inherited SINGULAR_* env (a leaked SINGULAR_DISPATCH_*
# or SINGULAR_RUNNER from a real drive would otherwise poison the sandbox). run.sh
# does this for the suite; do it here so a direct invocation is hermetic too.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-paired-hook.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
# A minimal decider prompt so decide.sh (non-accepted path) can assemble a prompt.
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' > "$drv_root/docs/orchestration/prompts/decider.md"

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

## Objective

Implement the widget parser. Keep [ACCEPTANCE CRITERIA] literal in this objective.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Parser handles empty input.
  REQUIRED-CONTINUATION: keep this late mandatory obligation.

  Literal example: `[TARGET] $(do-not-execute)`
EOF
git -C "$drv_root" add .
git -C "$drv_root" commit -qm init

# Mock runner. Writes a schema-valid worker packet (l2) and a verdict record
# (readonly). The paired-audit pass is distinguishable by its output path
# (.../paired-audit-raw.json): when FAIL_PAIRED=1 that specific invocation fails
# (rc 1, no output) to prove a failing paired runner does not disturb acceptance.
# The auditor verdict is MOCK_AUDIT_VERDICT (default accepted).
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<MOCK
#!/usr/bin/env bash
set -uo pipefail
level=""; worktree=""; out=""; prompt=""; run_id=""
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    --level) level="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    -C|--worktree) worktree="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --prompt-file) prompt="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --run-id) run_id="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --output-last-message) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ "\$level" == "l2" ]]; then
  mkdir -p "\$worktree/internal/widget"
  printf 'package widget\n' > "\$worktree/internal/widget/parser.go"
  [[ -n "\$out" ]] && cat > "\$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  exit 0
fi
# read-only: auditor / paired-audit / decider all run at --level readonly.
if [[ "\$out" == *paired-audit-raw.json ]]; then
  # The paired-audit pass. Optionally fail it to prove acceptance invariance.
  if [[ "\${FAIL_PAIRED:-0}" == "1" ]]; then exit 1; fi
  [[ -n "\$out" ]] && printf '{"verdict":"accepted","findings":[]}\n' > "\$out"
  exit 0
fi
if [[ "\${SINGULAR_RUNNER_ROLE:-}" == "auditor" \
    && "\${MOCK_AUDIT_REPAIR:-0}" == "1" ]]; then
  repair_count_file="$workroot/audit-repair-count"
  repair_count=0
  [[ -f "\$repair_count_file" ]] && repair_count="\$(cat "\$repair_count_file")"
  repair_count=\$((repair_count + 1))
  printf '%s\n' "\$repair_count" >"\$repair_count_file"
  if [[ "\$repair_count" -eq 1 || "\${MOCK_AUDIT_ALWAYS_INVALID:-0}" == "1" ]]; then
    [[ -n "\$out" ]] && cat >"\$out" <<JSON
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-0001","runId":"\$run_id","branch":"agent/widget/TASK-0001-generic","verdict":"accepted","evidenceReviewed":["audit-verification.json"],"verificationResults":[{"status":"passed"}],"commandsRun":["bash strict-gate.sh"],"findings":[],"requiredFixes":[],"rationale":"malformed fixture"}
JSON
    exit 0
  fi
  python3 - "\$prompt" <<'PY'
import sys

prompt = open(sys.argv[1], encoding="utf-8").read()
required = [
    "## Audit Verdict Repair (authoritative)",
    "validatorOrBinderError",
    "invalidResponse",
    "audit verdict.verificationResults[0] missing required field: command",
    "Required top-level members: schema, taskId, runId, branch, verdict,",
    "Each verificationResults[] object requires exactly status,",
]
for value in required:
    assert value in prompt, f"repair prompt omitted {value!r}"
PY
  repair_status="\$(sed -n 's/.*classification is \`\\([^\`]*\\)\`.*/\\1/p' "\$prompt" | tail -1)"
  [[ -n "\$repair_status" ]] || repair_status="passed"
  [[ -n "\$out" ]] && cat >"\$out" <<JSON
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-0001","runId":"\$run_id","branch":"agent/widget/TASK-0001-generic","verdict":"accepted","evidenceReviewed":["audit-verification.json"],"verificationResults":[{"status":"\$repair_status","command":"bash strict-gate.sh","exitCode":0,"evidenceRefs":["audit-verification.json"],"rationale":"matches host verification"}],"commandsRun":["bash strict-gate.sh"],"findings":[],"requiredFixes":[],"rationale":"repaired fixture"}
JSON
  exit 0
fi
[[ -n "\$out" ]] && printf '{"verdict":"%s","findings":[]}\n' "\${MOCK_AUDIT_VERDICT:-accepted}" > "\$out"
exit 0
MOCK
chmod +x "$mock_runner"

EVENTS="$drv_root/.singular-state/events.ndjson"

# Reset all mutable state so each scenario drives from a clean, ready task.
reset_state() {
  git -C "$drv_root" checkout -q target 2>/dev/null || true
  rm -rf "$drv_root/.singular-state/runs" "$drv_root/.singular-state/leases" \
    "$drv_root/.singular-state/inbox" "$drv_root/.worktrees" 2>/dev/null || true
  : > "$EVENTS"
  rm -f "$drv_root/docs/orchestration/decisions.md" 2>/dev/null || true
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
      SINGULAR_MAX_RETRIES=0 \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 )
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }
pa_event_count() {
  [[ -f "$EVENTS" ]] || { echo 0; return 0; }
  local c; c="$(grep -c '"type":"ctx.paired_audit"' "$EVENTS" 2>/dev/null)" || true
  echo "${c:-0}"
}
json_field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

# Assert the standard accepted outcome for a run (independent of the paired hook).
assert_accepted() {
  local run_dir="$1"
  local run_id; run_id="$(basename "$run_dir")"
  # Both real driver prompt assemblies retain multiline mandatory task data.
  python3 - "$run_dir" <<'PYCONTRACT'
from pathlib import Path
import sys
for name in ('l2-prompt.md', 'auditor-prompt.md'):
    text = (Path(sys.argv[1]) / name).read_text()
    assert 'REQUIRED-CONTINUATION: keep this late mandatory obligation.' in text
    assert '`[TARGET] $(do-not-execute)`' in text
    assert 'Keep [ACCEPTANCE CRITERIA] literal in this objective.' in text
PYCONTRACT
  # Packet status accepted (inbox copy is the accepted artifact).
  local inbox="$drv_root/.singular-state/inbox/$run_id.json"
  [[ -f "$inbox" ]] || fail "accepted: no inbox packet at $inbox"
  assert_eq "$(json_field "$inbox" status)" "accepted" "accepted: inbox packet status"
  # Lease + task status accepted.
  assert_eq "$(SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
    bash -c 'source "'"$SCRIPT_DIR"'/lib.sh"; singular_lease_status TASK-0001')" "accepted" "accepted: lease status"
  grep -q 'Status: accepted' "$TASK_MD" || fail "accepted: task md not set to accepted"
  # The accept decision was recorded.
  grep -q 'accept' "$drv_root/docs/orchestration/decisions.md" || fail "accepted: no accept decision recorded"
  # The l1.task_accepted event fired.
  grep -q '"type":"l1.task_accepted"' "$EVENTS" || fail "accepted: no l1.task_accepted event"
}

# ---------------------------------------------------------------------------
# (a) default-OFF: unset knob -> accepted path, no paired event/record.
# ---------------------------------------------------------------------------
reset_state
out="$(run_drive 2>&1)" || { echo "$out" | tail -20; fail "OFF (unset): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (unset): no run dir"
assert_accepted "$run_dir"
assert_eq "$(pa_event_count)" "0" "OFF (unset): ctx.paired_audit events"
[[ ! -e "$run_dir/paired-audit.json" ]] || fail "OFF (unset): paired-audit.json written"
pass "(a) default-OFF (unset): accepted with no paired event/record"

# default-OFF: explicit =0.
reset_state
out="$(run_drive SINGULAR_PAIRED_AUDIT_PCT=0 2>&1)" || { echo "$out" | tail -20; fail "OFF (=0): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (=0): no run dir"
assert_accepted "$run_dir"
assert_eq "$(pa_event_count)" "0" "OFF (=0): ctx.paired_audit events"
[[ ! -e "$run_dir/paired-audit.json" ]] || fail "OFF (=0): paired-audit.json written"
pass "(a) default-OFF (=0): accepted with no paired event/record"

# ---------------------------------------------------------------------------
# (b) PCT=100: exactly one paired event + record, acceptance unchanged, and the
#     ctx.paired_audit event is ordered STRICTLY after l1.task_accepted.
# ---------------------------------------------------------------------------
reset_state
out="$(run_drive SINGULAR_PAIRED_AUDIT_PCT=100 2>&1)" || { echo "$out" | tail -20; fail "PCT=100: drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "PCT=100: no run dir"
assert_accepted "$run_dir"
assert_eq "$(pa_event_count)" "1" "PCT=100: exactly one ctx.paired_audit event"
[[ -f "$run_dir/paired-audit.json" ]] || fail "PCT=100: paired-audit.json not written in run dir"
# Ordering: ctx.paired_audit strictly after l1.task_accepted.
accepted_ln="$(grep -n '"type":"l1.task_accepted"' "$EVENTS" | head -1 | cut -d: -f1)"
paired_ln="$(grep -n '"type":"ctx.paired_audit"' "$EVENTS" | head -1 | cut -d: -f1)"
[[ -n "$accepted_ln" && -n "$paired_ln" ]] || fail "PCT=100: missing accepted/paired event line"
[[ "$paired_ln" -gt "$accepted_ln" ]] \
  || fail "PCT=100: ctx.paired_audit ($paired_ln) not after l1.task_accepted ($accepted_ln)"
pass "(b) PCT=100: one paired event+record, acceptance unchanged, ordered after l1.task_accepted"

# ---------------------------------------------------------------------------
# (c) invariance: a FAILING paired runner leaves the accepted outcome and exit
#     status untouched.
# ---------------------------------------------------------------------------
reset_state
ec=0
out="$(run_drive SINGULAR_PAIRED_AUDIT_PCT=100 FAIL_PAIRED=1 2>&1)" || ec=$?
assert_eq "$ec" "0" "(c) failing paired runner: drive exit status unchanged (accepted)"
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "(c): no run dir"
assert_accepted "$run_dir"
pass "(c) failing paired runner: accepted outcome and exit status untouched"

# ---------------------------------------------------------------------------
# (d) non-accepted (needs-fix -> parked): NO paired audit is invoked.
# ---------------------------------------------------------------------------
reset_state
ec=0
out="$(run_drive SINGULAR_PAIRED_AUDIT_PCT=100 MOCK_AUDIT_VERDICT=needs-fix 2>&1)" || ec=$?
[[ "$ec" -ne 0 ]] || fail "(d) needs-fix: drive should NOT accept (expected non-zero exit)"
grep -q 'Status: accepted' "$TASK_MD" && fail "(d) needs-fix: task must not be accepted"
run_dir="$(run_dir_of)"
assert_eq "$(pa_event_count)" "0" "(d) needs-fix: no ctx.paired_audit event on non-accepted path"
[[ -z "$run_dir" || ! -e "$run_dir/paired-audit.json" ]] || fail "(d) needs-fix: paired-audit.json written on non-accepted path"
pass "(d) non-accepted path: no paired audit invoked, no paired record"

# ---------------------------------------------------------------------------
# (e) v1 schema-invalid output gets one bounded, fresh validation-feedback
#     repair retry. The repair prompt contains the exact contract, validator
#     error, and rejected response; a corrected verdict follows normal
#     acceptance.
# ---------------------------------------------------------------------------
reset_state
cat >"$drv_root/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"target","gateCommand":"bash strict-gate.sh"}
JSON
cat >"$drv_root/strict-gate.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' \
  '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$drv_root/strict-gate.sh"
python3 - "$TASK_MD" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"Gate command: `[^`]*`", "Gate command: `bash strict-gate.sh`", text, count=1)
open(path, "w", encoding="utf-8").write(text)
PY
git -C "$drv_root" add singular.config.json strict-gate.sh "$TASK_MD"
git -C "$drv_root" commit -qm "add v2 repair fixture"
rm -f "$workroot/audit-repair-count"
out="$(run_drive MOCK_AUDIT_REPAIR=1 SINGULAR_AUDIT_INFRA_MAX=1 2>&1)" \
  || { echo "$out" | tail -40; fail "(e) repairable v1 verdict did not accept"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "(e): no run dir"
assert_accepted "$run_dir"
assert_eq "$(cat "$workroot/audit-repair-count")" "2" \
  "(e) schema repair uses exactly one retry"
grep -q '"type":"l1.audit_invalid_verdict"' "$EVENTS" \
  || fail "(e): invalid v1 verdict event missing"
grep -q '"type":"l1.audit_repair_retry"' "$EVENTS" \
  || fail "(e): validation-feedback retry event missing"
repair_prompt="$run_dir/auditor-repair-prompt-attempt-1-try-1.md"
[[ -f "$repair_prompt" ]] || fail "(e): repair prompt artifact missing"
grep -Fq 'audit verdict.verificationResults[0] missing required field: command' \
  "$repair_prompt" || fail "(e): repair prompt omitted validator error"
grep -q '"invalidResponse"' "$repair_prompt" \
  || fail "(e): repair prompt omitted invalid response"
assert_eq "$(json_field "$run_dir/audit.json" schema)" \
  "singular.orchestration.audit-verdict.v1" "(e) repaired verdict schema"
pass "(e) v1 schema failure repaired once with validator feedback and accepted"

# ---------------------------------------------------------------------------
# (f) The same validation repair remains bounded by the existing retry budget.
#     If every fresh response is invalid, the verdict cannot influence
#     acceptance and the drive fails closed.
# ---------------------------------------------------------------------------
reset_state
rm -f "$workroot/audit-repair-count"
ec=0
out="$(run_drive MOCK_AUDIT_REPAIR=1 MOCK_AUDIT_ALWAYS_INVALID=1 \
  SINGULAR_AUDIT_INFRA_MAX=1 SINGULAR_DECIDER_FAST=1 2>&1)" || ec=$?
[[ "$ec" -ne 0 ]] || fail "(f): unrepaired invalid verdict must fail closed"
assert_eq "$(cat "$workroot/audit-repair-count")" "2" \
  "(f) invalid verdict retries remain bounded"
grep -q '"type":"l1.task_accepted"' "$EVENTS" \
  && fail "(f): unrepaired invalid verdict influenced acceptance"
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "(f): no run dir"
[[ -f "$run_dir/auditor-repair-prompt-attempt-1-try-1.md" ]] \
  || fail "(f): bounded repair prompt artifact missing"
pass "(f) unrepaired invalid verdict exhausted the bound and failed closed"

echo "ALL L1-DRIVE PAIRED-AUDIT-HOOK TESTS PASSED"
