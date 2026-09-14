#!/usr/bin/env bash
set -euo pipefail

# Drives a task through l1-drive.sh's acceptance path in a hermetic SINGULAR_ROOT
# (isolated events log, stub SINGULAR_RUNNER yielding an accepted verdict, default
# provisioning) and asserts the post-acceptance artifact-secret-scan finalize
# hook this node owns (DAG node artifact-secret-scan, layer engine_runtime): a
# call site placed STRICTLY AFTER acceptance is finalized (packet status
# accepted, lease/task status accepted, accept decision recorded, inbox packet
# written, l1.task_accepted appended) and BEFORE the post-acceptance paired-audit
# fresh-audit prompt is assembled from durable artifacts, behind the default-OFF
# SINGULAR_CTX_ARTIFACT_SCAN knob (default 0). The hook delegates into the already
# integrated containment bricks (singular_ctx_artifact_quarantine +
# singular_ctx_artifact_exclude) and adds no scan/exclude logic of its own.
#
#   (a) default-OFF (SINGULAR_CTX_ARTIFACT_SCAN unset AND =0): the accepted path is
#       byte-identical to pre-hook behavior — the seeded secret-bearing durable
#       artifact is left in place untouched (not renamed), NO ctx.artifact_secret
#       event, and NO durable-artifacts manifest is written.
#   (b) ON (=1) with a seeded secret in a durable context artifact: the artifact
#       is quarantined (renamed to <path>.quarantined; the original path is gone;
#       the .quarantined copy preserves the original bytes verbatim), exactly one
#       ctx.artifact_secret event fires ORDERED STRICTLY AFTER l1.task_accepted,
#       and the acceptance outcome (packet/lease/task status accepted, accept
#       decision, inbox packet, l1.task_accepted event) plus the process exit
#       status are UNCHANGED (evidence-invariance: quarantine never flips the
#       accept/reject decision).
#   (c) ON (=1): the durable-artifacts manifest assembled from durable artifacts
#       after the finalize hook (belt-and-suspenders exclude) EXCLUDES the
#       quarantined artifact and still includes a surviving clean artifact — a
#       quarantined artifact can never reach downstream prompt assembly.
#   (d) ON (=1) but the quarantine brick is unavailable (a genuine hook error):
#       the drive logs an l1.artifact_scan_failed event and STILL ACCEPTS (exit
#       0) — the hook is non-fatal and never aborts the drive.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-artifact-scan-hook.sh requires bash >= 4" >&2; exit 1
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

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-artifact-scan-hook.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
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

# The seeded secret. Split-literals so this test file itself carries no
# live-looking credential. It is written into a DURABLE CONTEXT ARTIFACT in the
# run dir (session-planner.json) — NOT into an owned/worktree file — so the
# commit-time secret-scan never sees it; only the finalize artifact-scan hook can.
SEED_SECRET="sbp_""abcdefghij0123456789KLMN"

# Mock runner. On --level l2 it writes the owned worker file, a schema-valid
# worker packet, and (when SEED_SECRET is set) seeds the secret into
# $run_dir/session-planner.json (a durable context artifact scanned by the
# finalize hook, never overwritten by the host). On --level readonly it writes
# the auditor / paired-audit verdict record.
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
  mkdir -p "$worktree/internal/widget"
  printf 'package widget\n' > "$worktree/internal/widget/parser.go"
  if [[ -n "$out" ]]; then
    run_dir="$(dirname "$out")"
    if [[ -n "${SEED_SECRET:-}" ]]; then
      printf '{"planner":"leaked credential %s"}\n' "$SEED_SECRET" \
        > "$run_dir/session-planner.json"
    fi
    cat > "$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  fi
  exit 0
fi
# read-only: auditor / paired-audit / decider all run at --level readonly.
[[ -n "$out" ]] && printf '{"verdict":"%s","findings":[]}\n' "${MOCK_AUDIT_VERDICT:-accepted}" > "$out"
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
      SINGULAR_MAX_RETRIES=0 SEED_SECRET="$SEED_SECRET" \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 )
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }
secret_event_count() {
  [[ -f "$EVENTS" ]] || { echo 0; return 0; }
  local c; c="$(grep -c '"type":"ctx.artifact_secret"' "$EVENTS" 2>/dev/null)" || true
  echo "${c:-0}"
}
json_field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

# Assert the standard accepted outcome for a run (independent of the scan hook).
assert_accepted() {
  local run_dir="$1"
  local run_id; run_id="$(basename "$run_dir")"
  local inbox="$drv_root/.singular-state/inbox/$run_id.json"
  [[ -f "$inbox" ]] || fail "accepted: no inbox packet at $inbox"
  assert_eq "$(json_field "$inbox" status)" "accepted" "accepted: inbox packet status"
  assert_eq "$(SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
    bash -c 'source "'"$SCRIPT_DIR"'/lib.sh"; singular_lease_status TASK-0001')" "accepted" "accepted: lease status"
  grep -q 'Status: accepted' "$TASK_MD" || fail "accepted: task md not set to accepted"
  grep -q 'accept' "$drv_root/docs/orchestration/decisions.md" || fail "accepted: no accept decision recorded"
  grep -q '"type":"l1.task_accepted"' "$EVENTS" || fail "accepted: no l1.task_accepted event"
}

seeded_artifact() { echo "$1/session-planner.json"; }

# ---------------------------------------------------------------------------
# (a) default-OFF (unset): accepted, seeded secret artifact untouched, no event,
#     no manifest.
# ---------------------------------------------------------------------------
reset_state
out="$(run_drive 2>&1)" || { echo "$out" | tail -20; fail "OFF (unset): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (unset): no run dir"
assert_accepted "$run_dir"
art="$(seeded_artifact "$run_dir")"
[[ -f "$art" ]] || fail "OFF (unset): seeded artifact should remain in place"
[[ ! -e "$art.quarantined" ]] || fail "OFF (unset): seeded artifact must NOT be quarantined"
assert_eq "$(secret_event_count)" "0" "OFF (unset): ctx.artifact_secret events"
[[ ! -e "$run_dir/durable-artifacts.manifest" ]] || fail "OFF (unset): manifest written"
pass "(a) default-OFF (unset): accepted, artifact untouched, no event/manifest"

# default-OFF: explicit =0.
reset_state
out="$(run_drive SINGULAR_CTX_ARTIFACT_SCAN=0 2>&1)" || { echo "$out" | tail -20; fail "OFF (=0): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (=0): no run dir"
assert_accepted "$run_dir"
art="$(seeded_artifact "$run_dir")"
[[ -f "$art" ]] || fail "OFF (=0): seeded artifact should remain in place"
[[ ! -e "$art.quarantined" ]] || fail "OFF (=0): seeded artifact must NOT be quarantined"
assert_eq "$(secret_event_count)" "0" "OFF (=0): ctx.artifact_secret events"
[[ ! -e "$run_dir/durable-artifacts.manifest" ]] || fail "OFF (=0): manifest written"
pass "(a) default-OFF (=0): accepted, artifact untouched, no event/manifest"

# ---------------------------------------------------------------------------
# (b) ON (=1): the seeded secret artifact is quarantined (renamed, bytes
#     preserved), exactly one ctx.artifact_secret event ordered strictly after
#     l1.task_accepted, and the acceptance outcome + exit status are unchanged.
# ---------------------------------------------------------------------------
reset_state
ec=0
out="$(run_drive SINGULAR_CTX_ARTIFACT_SCAN=1 2>&1)" || ec=$?
assert_eq "$ec" "0" "ON: drive exit status unchanged (accepted)"
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON: no run dir"
assert_accepted "$run_dir"
art="$(seeded_artifact "$run_dir")"
# Capture the quarantined bytes and prove containment + evidence-preservation.
[[ ! -e "$art" ]] || fail "ON: seeded artifact original should be renamed away"
[[ -f "$art.quarantined" ]] || fail "ON: seeded artifact should be quarantined"
grep -q "$SEED_SECRET" "$art.quarantined" \
  || fail "ON: quarantined artifact must preserve the original secret-bearing bytes"
assert_eq "$(secret_event_count)" "1" "ON: exactly one ctx.artifact_secret event"
grep -q "session-planner.json" "$EVENTS" || fail "ON: event must record the artifact path"
# Ordering: ctx.artifact_secret strictly after l1.task_accepted.
accepted_ln="$(grep -n '"type":"l1.task_accepted"' "$EVENTS" | head -1 | cut -d: -f1)"
secret_ln="$(grep -n '"type":"ctx.artifact_secret"' "$EVENTS" | head -1 | cut -d: -f1)"
[[ -n "$accepted_ln" && -n "$secret_ln" ]] || fail "ON: missing accepted/secret event line"
[[ "$secret_ln" -gt "$accepted_ln" ]] \
  || fail "ON: ctx.artifact_secret ($secret_ln) not after l1.task_accepted ($accepted_ln)"
pass "(b) ON: artifact quarantined+evidence-preserved, one event after accept, outcome unchanged"

# ---------------------------------------------------------------------------
# (c) ON (=1): the durable-artifacts manifest EXCLUDES the quarantined artifact
#     and still includes a surviving clean durable artifact.
# ---------------------------------------------------------------------------
[[ -f "$run_dir/durable-artifacts.manifest" ]] || fail "ON: durable-artifacts manifest not written"
manifest="$(cat "$run_dir/durable-artifacts.manifest")"
[[ "$manifest" != *"session-planner.json"* ]] \
  || fail "ON: manifest must NOT include the quarantined artifact"
[[ "$manifest" == *"packet.json"* ]] \
  || fail "ON: manifest must include a surviving clean durable artifact (packet.json)"
pass "(c) ON: manifest excludes the quarantined artifact, keeps clean artifacts"

# ---------------------------------------------------------------------------
# (d) ON (=1) with the quarantine brick unavailable: the hook error is logged as
#     l1.artifact_scan_failed and the drive still accepts (non-fatal).
# ---------------------------------------------------------------------------
reset_state
# Shim engine dir: symlink every real ctx-*.sh EXCEPT ctx-artifact-quarantine.sh
# so singular_ctx_artifact_quarantine is undefined at hook time (a genuine error).
ctxdir="$workroot/ctx-noquar"
rm -rf "$ctxdir"; mkdir -p "$ctxdir"
for f in "$SCRIPT_DIR"/ctx-*.sh; do
  [[ "$(basename "$f")" == "ctx-artifact-quarantine.sh" ]] && continue
  ln -s "$f" "$ctxdir/$(basename "$f")"
done
ec=0
out="$(run_drive SINGULAR_CTX_ARTIFACT_SCAN=1 SINGULAR_ENGINE_DIR="$ctxdir" 2>&1)" || ec=$?
assert_eq "$ec" "0" "(d) quarantine unavailable: drive still accepts (non-fatal)"
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "(d): no run dir"
assert_accepted "$run_dir"
grep -q '"type":"l1.artifact_scan_failed"' "$EVENTS" \
  || fail "(d): missing l1.artifact_scan_failed event on quarantine error"
assert_eq "$(secret_event_count)" "0" "(d) quarantine unavailable: no ctx.artifact_secret event"
pass "(d) quarantine unavailable: error logged, drive still accepts (non-fatal)"

echo "ALL CTX-ARTIFACT-SCAN-HOOK TESTS PASSED"
