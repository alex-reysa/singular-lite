#!/usr/bin/env bash
set -euo pipefail

# T-F1 (decider fast-path) + T-E6 (infra-failure isolation) tests.
#
# Unit (singular_decider_fast_action):
#   - the full policy table at left>0 and left<=0 for every class;
#   - a same-class repeat -> empty (escalate to the model);
#   - SINGULAR_DECIDER_FAST=0 -> empty for everything.
#
# Driver-level (a SINGULAR_RUNNER stub stands in for the worker+auditor CLIs, keyed
# off --level / the prompt-file name, the same drop-in contract the real runners
# honor — final-message capture via --output-last-message):
#   - a gate-red attempt WITH retry budget takes the fast-path: NO
#     decider-prompt-*.md is created, a decider.fast_path event fires, and the
#     archived deciderAuthority is "policy";
#   - the same with SINGULAR_DECIDER_FAST=0 consults decide.sh: a decider-prompt is
#     created and the authority is "decider";
#   - an auditor that emits prose once then a valid verdict: the worker runs
#     ONCE, the auditor runs 2x, the lease retryCount is unchanged, and one
#     audit.infra_retry event fires (higher configured values are hard-capped);
#   - a worker that exits 124 (timeout) every try: a worker.infra_retry event
#     fires, NO decider-prompt is created (worker-infra parks via the fast-path),
#     and the attempt is archived/parked as worker-infra.
#   - a detached scheduler's planned lease remains unattempted: a normal task
#     still gets its initial pass plus one repair, while exhausted re-entry gets
#     no newly-minted pass.
#   - a disposable audit gate that mutates committed source parks immediately as
#     integrity-violation, without consulting the model or bumping retryCount.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-decider-fastpath.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing file $1"; }
assert_no_file() { [[ ! -f "$1" ]] || fail "$2: unexpected file $1"; }

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" \
    "$root/docs/orchestration/tasks" \
    "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/l2-test-first-developer.md"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/auditor.md"
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$root/docs/orchestration/prompts/decider.md"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n' >"$root/.gitignore"
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="${1:-}"
  [[ -n "$tmp" ]] || tmp="$(mktemp -d)"
  mkdir -p "$tmp"
  FIXTURE_TMP="$tmp"
  make_repo "$tmp/repo"
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
  export SINGULAR_TARGET_BRANCH="target"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  unset SINGULAR_MODULES SINGULAR_WORKER_RED_LOG SINGULAR_WORKER_CONTRACT_EXTRA SINGULAR_RUNNER \
    SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE SINGULAR_ATTEMPT_TASK_ID SINGULAR_ATTEMPT_STARTED_AT \
    SINGULAR_DECIDER_FAST SINGULAR_WORKER_INFRA_MAX SINGULAR_AUDIT_INFRA_MAX \
    SINGULAR_AUDIT_VERIFY_INFRA_MAX SINGULAR_EVIDENCE_INFRA_MAX \
    SINGULAR_TASK_RISK_TIER SINGULAR_DEFAULT_RISK_TIER \
    SINGULAR_LOCAL_CONFIG_FILE SINGULAR_BASE_REF SINGULAR_DISPATCH_BASE_SHA \
    SINGULAR_DISPATCH_BATCH_ID SINGULAR_PAIRED_AUDIT_PCT 2>/dev/null || true
  unset MOCK_AUDIT_FINDINGS 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
}

assert_fixture_configuration_context() {
  local root root_resolved
  root="$1"
  root_resolved="$(cd "$root" && pwd -P)"
  assert_eq "$SINGULAR_ROOT" "$root" "fixture consumer root"
  assert_eq "$SINGULAR_JSON_CONFIG_SOURCE" "default" "fixture JSON provenance"
  assert_eq "$SINGULAR_JSON_CONFIG_FILE" "$root_resolved/singular.config.json" \
    "fixture optional JSON default"
  assert_eq "$SINGULAR_JSON_CONFIG_DEFAULT_ROOT" "$root_resolved" \
    "fixture JSON default root"
  assert_eq "$SINGULAR_JSON_CONFIG_DEFAULT_FILE" "$root_resolved/singular.config.json" \
    "fixture JSON default file"
  assert_eq "$SINGULAR_CONFIG_FILE" "$root/singular.config.sh" \
    "fixture shell configuration"
  assert_eq "$SINGULAR_STATE_DIR" "$root/.singular-state" "fixture state directory"
  assert_eq "$SINGULAR_ORIGIN_STATE_FILE" "$root/.singular-state/origin-state.json" \
    "fixture origin state"
  assert_eq "$SINGULAR_GIT_LOCK_DIR" "$root/.singular-state/locks/git-op.lock" \
    "fixture git lock"
  assert_eq "$SINGULAR_PLANNER_BACKOFF_FILE" "$root/.singular-state/planner-backoff.json" \
    "fixture planner backoff"
  assert_eq "$SINGULAR_RECONCILE_INDEX_FILE" "$root/.singular-state/reconcile-index.json" \
    "fixture reconcile index"
}

fixture_tree_digest() {
  find "$1" -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
}

test_fixture_configuration_context_isolated() {
  local boundary_tmp first_tmp second_tmp first_root second_root before after out
  boundary_tmp="$(mktemp -d)"
  first_tmp="$boundary_tmp/first"
  second_tmp="$boundary_tmp/second"
  first_root="$first_tmp/repo"
  second_root="$second_tmp/repo"

  (
    with_fixture "$first_tmp"
    assert_fixture_configuration_context "$first_root"
    printf 'first-consumer-canary\n' >"$SINGULAR_STATE_DIR/config-boundary.canary"
    (cd "$SINGULAR_ROOT" && "$SCRIPT_DIR/gate-check.sh" RUN-CONFIG-FIRST \
      --task-id TASK-0001 -- true) >/dev/null
    out="$(SINGULAR_DRAIN_TIMEOUT_SECS=5 SINGULAR_DRAIN_POLL_SECS=0 \
      "$SCRIPT_DIR/reconcile.sh" --drain)"
    assert_contains "$out" "workers_running=0" "first fixture bounded reconcile"
    assert_file "$SINGULAR_RUNS_DIR/RUN-CONFIG-FIRST/gate-report.json" \
      "first fixture real gate report"
  )
  before="$(fixture_tree_digest "$first_root")"

  (
    with_fixture "$second_tmp"
    assert_fixture_configuration_context "$second_root"
    (cd "$SINGULAR_ROOT" && "$SCRIPT_DIR/gate-check.sh" RUN-CONFIG-SECOND \
      --task-id TASK-0001 -- true) >/dev/null
    out="$(SINGULAR_DRAIN_TIMEOUT_SECS=5 SINGULAR_DRAIN_POLL_SECS=0 \
      "$SCRIPT_DIR/reconcile.sh" --drain)"
    assert_contains "$out" "workers_running=0" "second fixture bounded reconcile"
    assert_file "$SINGULAR_RUNS_DIR/RUN-CONFIG-SECOND/gate-report.json" \
      "second fixture real gate report"
  )

  after="$(fixture_tree_digest "$first_root")"
  assert_eq "$after" "$before" "second consumer left first fixture byte-identical"
  assert_eq "$(cat "$first_root/.singular-state/config-boundary.canary")" \
    "first-consumer-canary" "first fixture canary"
  assert_no_file "$first_root/.singular-state/runs/RUN-CONFIG-SECOND/gate-report.json" \
    "second fixture gate artifacts contained"
  echo "ok: fixture configuration context and entrypoint containment"
}

write_generic_task() {
  cat >"$SINGULAR_TASKS_DIR/TASK-0001.md" <<'EOF'
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
}

# ============================== Unit: fast-path table ==========================
test_fast_action_table() {
  with_fixture
  unset SINGULAR_DECIDER_FAST

  # left>0 (budget remains): retry_count=0 max_retries=3 -> left=3.
  local prev="" out
  for cls in gate-red worker-no-packet packet-invalid no-changes commit-failed; do
    out="$(singular_decider_fast_action "$cls" 0 3 "$prev")"
    assert_eq "$out" "retry" "fast table $cls left>0"
    out="$(singular_decider_fast_action "$cls" 3 3 "$prev")"
    assert_eq "$out" "escalate-parked" "fast table $cls left<=0"
  done

  out="$(singular_decider_fast_action scope-violation 0 3 "$prev")"
  assert_eq "$out" "amend-scope" "fast table scope-violation left>0"
  out="$(singular_decider_fast_action scope-violation 3 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table scope-violation left<=0"

  # Infra classes park unconditionally (budget irrelevant), and as
  # `escalate-infra` rather than `escalate-parked`. The two mean opposite things
  # to whoever reads the queue: escalate-parked is "a human must judge this
  # work", escalate-infra is "the work is fine, the environment is not". The
  # decider diagnosed exactly that in the field and had no action to say it.
  out="$(singular_decider_fast_action worker-infra 0 3 "$prev")"
  assert_eq "$out" "escalate-infra" "fast table worker-infra budget"
  out="$(singular_decider_fast_action worker-infra 3 3 "$prev")"
  assert_eq "$out" "escalate-infra" "fast table worker-infra no-budget"
  out="$(singular_decider_fast_action audit-infra 0 3 "$prev")"
  assert_eq "$out" "escalate-infra" "fast table audit-infra budget"
  out="$(singular_decider_fast_action audit-infra 3 3 "$prev")"
  assert_eq "$out" "escalate-infra" "fast table audit-infra no-budget"

  # A committed-source mutation is a deterministic containment event, not an
  # infrastructure failure. Human judgment is mandatory even with retry budget,
  # and the repeat guard must never hand this class to the model decider.
  out="$(singular_decider_fast_action integrity-violation 0 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table integrity-violation budget"
  out="$(singular_decider_fast_action integrity-violation 3 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table integrity-violation no-budget"
  out="$(singular_decider_fast_action integrity-violation 0 3 integrity-violation)"
  assert_eq "$out" "escalate-parked" "fast table integrity-violation repeat"

  # Host admission policy is equally deterministic: neither retry budget, a
  # repeat, nor disabling the ordinary fast table may delegate it to a model.
  out="$(singular_decider_fast_action configured-context 0 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table configured-context budget"
  out="$(singular_decider_fast_action configured-context 3 3 configured-context)"
  assert_eq "$out" "escalate-parked" "fast table configured-context repeat"
  out="$(SINGULAR_DECIDER_FAST=0 singular_decider_fast_action configured-context 0 3 "$prev")"
  assert_eq "$out" "escalate-parked" "configured-context bypasses model when fast table disabled"

  # ...and it is a declared action, not a string the engine invented: the
  # decider-verdict schema has to accept what the fast path emits, or a model
  # decider choosing the same action fails validation.
  python3 - "$ENGINE_HOME/schemas/decider-verdict.v0.schema.json" <<'SCHEMA'
import json
import sys

actions = json.load(open(sys.argv[1]))["properties"]["action"]["enum"]
assert "escalate-infra" in actions, "escalate-infra missing from decider-verdict.v0"
SCHEMA

  # audit-needs-fix: retry while budget remains, else EMPTY (model weighs waiver).
  out="$(singular_decider_fast_action audit-needs-fix 0 3 "$prev")"
  assert_eq "$out" "retry" "fast table audit-needs-fix left>0"
  out="$(singular_decider_fast_action audit-needs-fix 3 3 "$prev")"
  assert_eq "$out" "" "fast table audit-needs-fix left<=0 -> model"

  # Model-only classes -> empty regardless of budget.
  for cls in audit-blocked audit-needs-human audit-unknown secret-detected proof-skip-detected something-else; do
    out="$(singular_decider_fast_action "$cls" 0 3 "$prev")"
    assert_eq "$out" "" "fast table $cls -> model (budget)"
    out="$(singular_decider_fast_action "$cls" 3 3 "$prev")"
    assert_eq "$out" "" "fast table $cls -> model (no budget)"
  done
  echo "ok: fast-path table"
}

test_fast_action_repeat_and_disabled() {
  with_fixture

  # Same-class repeat escalates to the model (empty), even with budget.
  local out
  out="$(singular_decider_fast_action gate-red 0 3 gate-red)"
  assert_eq "$out" "" "fast repeat: same class -> model"
  # A DIFFERENT prev still fast-paths.
  out="$(singular_decider_fast_action gate-red 0 3 scope-violation)"
  assert_eq "$out" "retry" "fast repeat: different prev still fast-paths"

  # SINGULAR_DECIDER_FAST=0 disables ordinary table actions (force the model
  # path), but cannot disable deterministic containment/admission policy.
  for cls in gate-red scope-violation worker-infra audit-infra audit-needs-fix no-changes; do
    out="$(SINGULAR_DECIDER_FAST=0 singular_decider_fast_action "$cls" 0 3 "")"
    assert_eq "$out" "" "fast disabled: $cls -> empty"
  done
  # Integrity containment is mandatory policy, not an optional fast-path. Even
  # operators disabling ordinary fast actions must never hand it to the model.
  out="$(SINGULAR_DECIDER_FAST=0 singular_decider_fast_action integrity-violation 0 3 "")"
  assert_eq "$out" "escalate-parked" "fast disabled: integrity-violation still parks"
  out="$(SINGULAR_DECIDER_FAST=0 singular_decider_fast_action configured-context 0 3 "")"
  assert_eq "$out" "escalate-parked" "fast disabled: configured-context still parks"
  echo "ok: fast-path repeat + disabled"
}

test_candidate_signature_ignores_empty_commit_identity() {
  with_fixture
  eval "$(awk '/^l1_candidate_signature\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' "$SCRIPT_DIR/l1-drive.sh")"
  local before after changed
  before="$(l1_candidate_signature "$SINGULAR_ROOT")"
  git -C "$SINGULAR_ROOT" -c user.name=test -c user.email=test@example.local \
    commit -q --allow-empty -m 'ceremonial empty commit'
  after="$(l1_candidate_signature "$SINGULAR_ROOT")"
  assert_eq "$after" "$before" "candidate signature: empty commit is not product progress"
  printf 'real product byte\n' >"$SINGULAR_ROOT/real-product.txt"
  changed="$(l1_candidate_signature "$SINGULAR_ROOT")"
  [[ "$changed" != "$after" ]] || fail "candidate signature: source-byte change must count as progress"
  echo "ok: candidate signature binds source tree bytes, not commit identity"
}

# ============================== Driver-level ===================================
# A sequencing runner: auditor verdict follows MOCK_AUDIT_VERDICT_SEQ by call #.
make_seq_runner() {
  local stub="$1"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
level=""; out=""; chdir=""; prompt=""
if [[ -n "${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}" \
    && -n "${MOCK_ORIGIN_CAP_LEAK_FILE:-}" ]]; then
  printf '%s\n' "${SINGULAR_RUNNER_ROLE:-unknown}" \
    >>"$MOCK_ORIGIN_CAP_LEAK_FILE"
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C) chdir="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    --run-id) shift 2 ;;
    *) shift ;;
  esac
done
cdir="${MOCK_COUNTER_DIR:-/tmp}"; mkdir -p "$cdir"
# Decider call (decide.sh dispatches the decider prompt at --level readonly). Emit
# a decider-verdict action so the fast-disabled path actually advances.
if [[ "$prompt" == *decider-prompt-* ]]; then
  fc="${prompt##*decider-prompt-}"
  fc="${fc%.md}"
  python3 - "$out" "${MOCK_DECIDER_ACTION:-retry}" "$fc" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.decider-verdict.v0","failureClass":sys.argv[3],"taskId":"TASK-0001","action":sys.argv[2],"rationale":"mock decider","nextOwner":"l1"}, open(sys.argv[1],"w"))
PY
  exit 0
fi
if [[ "$level" == "l2" ]]; then
  wc_file="$cdir/worker-calls"; n=0; [[ -f "$wc_file" ]] && n="$(cat "$wc_file")"; n=$((n+1)); printf '%s' "$n" >"$wc_file"
  rc="${MOCK_WORKER_RC:-0}"
  if [[ "$rc" -ne 0 ]]; then : >"$out"; exit "$rc"; fi
  # Clean run (rc 0) but no packet (prose/empty output): must classify as
  # worker-no-packet via the main retry loop, NOT worker-infra.
  if [[ "${MOCK_WORKER_EMPTY:-0}" == "1" ]]; then : >"$out"; exit 0; fi
  mkdir -p "$chdir/internal/widget" "$chdir/.singular-evidence"
  printf 'package widget\n// v%s\n' "$n" >"$chdir/internal/widget/parser.go"
  printf 'red\n' >"$chdir/.singular-evidence/red.log"; printf 'green\n' >"$chdir/.singular-evidence/green.log"; printf 'reg\n' >"$chdir/.singular-evidence/regression.log"
  python3 - "$out" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"uncommitted","workspace":"/tmp","ownedFiles":["internal/widget/parser.go"],"changedFiles":["internal/widget/parser.go"],"commands":[{"cmd":"true","exitCode":0,"logRef":""}],"tests":[{"name":"t","phase":"red","status":"fail","logRef":""},{"name":"t","phase":"green","status":"pass","logRef":""}],"evidence":[{"kind":"red","ref":".singular-evidence/red.log"}],"blockers":[],"nextAction":"audit","createdAt":"2026-01-01T00:00:00Z"}, open(sys.argv[1],"w"))
PY
  exit 0
fi
ac_file="$cdir/audit-calls"; n=0; [[ -f "$ac_file" ]] && n="$(cat "$ac_file")"; n=$((n+1)); printf '%s' "$n" >"$ac_file"
prose_tries="${MOCK_AUDIT_PROSE_TRIES:-0}"
if [[ "$n" -le "$prose_tries" ]]; then printf 'prose, no JSON here\n' >"$out"; exit 0; fi
# Per-call verdict from the sequence (1-indexed by parseable-call order). The prose
# tries do not advance the verdict sequence; subtract them.
seq=(${MOCK_AUDIT_VERDICT_SEQ:-accepted})
vi=$((n - prose_tries - 1)); [[ "$vi" -lt 0 ]] && vi=0
verdict="${seq[$vi]:-${seq[${#seq[@]}-1]}}"
python3 - "$out" "$verdict" "${MOCK_AUDIT_FINDINGS:-[]}" <<'PY'
import json, sys
findings = json.loads(sys.argv[3])
json.dump({"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-0001","runId":"r","branch":"agent/widget/TASK-0001-generic","verdict":sys.argv[2],"evidenceReviewed":[],"commandsRun":[],"findings":findings,"requiredFixes":findings if sys.argv[2] == "needs-fix" else [],"rationale":"ok"}, open(sys.argv[1],"w"))
PY
exit 0
STUB
  chmod +x "$stub"
}

test_driver_scrubs_origin_capability_from_provider_runner() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner-capability-probe.sh"
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/capability-counters"
  export MOCK_AUDIT_VERDICT_SEQ="accepted"
  export MOCK_ORIGIN_CAP_LEAK_FILE="$FIXTURE_TMP/provider-origin-capability.leaked"
  export SINGULAR_ORIGIN_LOCK_CAPABILITY="fixture-origin-authority-must-not-leak"

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "capability-confinement driver accepts ($out)"
  [[ ! -e "$MOCK_ORIGIN_CAP_LEAK_FILE" ]] \
    || fail "origin lock capability reached provider runner roles: $(tr '\n' ' ' <"$MOCK_ORIGIN_CAP_LEAK_FILE")"
  unset MOCK_ORIGIN_CAP_LEAK_FILE SINGULAR_ORIGIN_LOCK_CAPABILITY
  echo "ok: driver scrubs origin capability from implementer/provider runners"
}

# Fast-path provenance: attempt-1 audit-needs-fix (a fast-path 'retry' class) with
# budget, attempt-2 accepted. The needs-fix failure is resolved by the policy
# fast-path WITHOUT a model decider round-trip: NO decider-prompt-*.md is created,
# a decider.fast_path event fires, and the archived deciderAuthority is "policy".
test_driver_fastpath_provenance() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters1"
  export MOCK_AUDIT_VERDICT_SEQ="needs-fix accepted"

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "fast-path provenance run accepts ($out)"
  local prompts
  prompts="$(find "$SINGULAR_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_eq "$prompts" "" "fast-path: no decider prompt created"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"decider.fast_path"' "fast-path event emitted"
  local idx
  idx="$(find "$SINGULAR_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_file "$idx" "fast-path: attempts index exists"
  assert_contains "$(cat "$idx")" '"deciderAuthority": "policy"' "fast-path: authority policy archived"
  assert_contains "$(cat "$idx")" '"deciderAction": "retry"' "fast-path: action retry archived"
  # retryCount IS bumped here (a real retry, not an infra retry).
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" "fast-path retry bumps retryCount"
  echo "ok: driver fast-path provenance (policy authority, no decider prompt)"
}

# Same needs-fix->accepted run but SINGULAR_DECIDER_FAST=0: decide.sh IS consulted
# (a decider prompt is created) and the authority is "decider".
test_driver_decider_when_fast_disabled() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters2"
  export MOCK_AUDIT_VERDICT_SEQ="needs-fix accepted"
  export SINGULAR_DECIDER_FAST=0

  local out rc=0
  out="$(SINGULAR_DECIDER_TIMEOUT_SEC=60 "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "driver (fast disabled) run accepts ($out)"
  local prompts
  prompts="$(find "$SINGULAR_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_contains "$prompts" "decider-prompt-audit-needs-fix.md" "fast disabled: decider prompt created"
  assert_not_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"decider.fast_path"' "fast disabled: no fast_path event"
  local idx
  idx="$(find "$SINGULAR_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_contains "$(cat "$idx")" '"deciderAuthority": "decider"' "fast disabled: authority decider archived"
  unset SINGULAR_DECIDER_FAST
  echo "ok: driver decider consulted when fast disabled"
}

# Ordinary tasks receive one repair after initial execution. Explicit high-risk
# tasks receive two; an unknown explicit category fails safe to the same high
# policy instead of silently becoming ordinary.
test_driver_risk_bounded_product_repairs() {
  local stub out rc events calls_before
  (
  with_fixture
  write_generic_task
  stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-risk-normal"
  export MOCK_AUDIT_VERDICT_SEQ="needs-fix needs-fix accepted"
  export SINGULAR_MAX_RETRIES=99

  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "ordinary risk parks after one product repair ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "2" \
    "ordinary risk: initial execution plus one repair"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "2" \
    "ordinary risk: no third audit ceremony"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" \
    "ordinary risk: exactly one product repair consumed"
  assert_eq "$(singular_lease_field TASK-0001 maxRetries)" "1" \
    "ordinary risk: legacy lease surface exposes bounded ceiling"
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"l1.product_repair_budget_consumed"' \
    "ordinary risk: consumption event"
  assert_contains "$events" '"l1.product_repair_budget_exhausted"' \
    "ordinary risk: exhaustion event"
  assert_contains "$events" '"productRepairMax":1' \
    "ordinary risk: configured budget is machine-readable"

  # A reset/re-entry without the explicit unpark budget reset must not mint a
  # second initial pass after the durable lease already consumed its ceiling.
  singular_task_set_status "$SINGULAR_TASKS_DIR/TASK-0001.md" ready
  calls_before="$(cat "$MOCK_COUNTER_DIR/worker-calls")"
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "ordinary re-entry is refused after durable ceiling ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "$calls_before" \
    "ordinary re-entry: no additional product pass"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"priorLease":true' \
    "ordinary re-entry: durable lease provenance is observable"
  )

  (
  with_fixture
  write_generic_task
  python3 - "$SINGULAR_TASKS_DIR/TASK-0001.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("Test policy: `strict_test_first`", "Risk tier: `high`\nTest policy: `strict_test_first`")
open(path, "w", encoding="utf-8").write(text)
PY
  stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-risk-high"
  export MOCK_AUDIT_VERDICT_SEQ="needs-fix needs-fix accepted"
  export SINGULAR_MAX_RETRIES=99
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "high risk accepts after two bounded repairs ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "3" \
    "high risk: initial execution plus two repairs"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "2" \
    "high risk: exactly two product repairs consumed"
  assert_eq "$(singular_lease_field TASK-0001 maxRetries)" "2" \
    "high risk: lease exposes two-repair ceiling"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"riskTier":"high"' \
    "high risk: resolved tier is observable"
  )

  (
  with_fixture
  write_generic_task
  export SINGULAR_TASK_RISK_TIER="unrecognized-category"
  stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-risk-unknown"
  export MOCK_AUDIT_VERDICT_SEQ="accepted"
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "unknown explicit risk still runs ($out)"
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"riskTier":"high"' "unknown risk: fail-safe high tier"
  assert_contains "$events" 'fail-safe-unknown' "unknown risk: fail-safe provenance"
  assert_contains "$events" '"productRepairMax":2' "unknown risk: two-repair ceiling"
  unset SINGULAR_MAX_RETRIES SINGULAR_TASK_RISK_TIER
  )
  echo "ok: risk-bounded product repair policy (normal=1, high/unknown=2)"
}

# Detached dispatch reserves a task with a planned lease before l1-drive starts.
# That scheduler reservation is not a product pass; the driver must durably mark
# the first real pass and retain the exhausted budget across reset/re-entry.
test_driver_detached_planned_lease_preserves_product_budget() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-detached-planned"
  export MOCK_AUDIT_VERDICT_SEQ="needs-fix needs-fix accepted"
  export SINGULAR_MAX_RETRIES=99

  local owned_json='["internal/widget/parser.go"]'
  singular_lease_write TASK-0001 agent/widget/TASK-0001-generic widget l2-developer \
    "internal/widget/parser.go" planned ORIGIN-DETACHED "" \
    "$(git -C "$SINGULAR_ROOT" rev-parse target)" ORIGIN-DETACHED-batch \
    "$owned_json" '[]'
  assert_eq "$(singular_lease_field TASK-0001 productPassStarted)" "False" \
    "detached reservation: planned lease is explicitly unattempted"

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "detached reservation parks after one repair ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "2" \
    "detached reservation: initial execution plus one repair"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "2" \
    "detached reservation: exactly two product audits"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" \
    "detached reservation: one repair consumed"
  assert_eq "$(singular_lease_field TASK-0001 maxRetries)" "1" \
    "detached reservation: normal-risk ceiling retained"
  assert_eq "$(singular_lease_field TASK-0001 productPassStarted)" "True" \
    "detached reservation: first real product pass is durable"

  singular_task_set_status "$SINGULAR_TASKS_DIR/TASK-0001.md" ready
  local calls_before
  calls_before="$(cat "$MOCK_COUNTER_DIR/worker-calls")"
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "detached exhausted re-entry is refused ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "$calls_before" \
    "detached exhausted re-entry: no product budget regained"
  assert_eq "$(singular_lease_field TASK-0001 productPassStarted)" "True" \
    "detached exhausted re-entry: durable started marker preserved"
  unset SINGULAR_MAX_RETRIES
  echo "ok: detached planned lease preserves initial+repair budget and exhausted re-entry"
}

# A process killed during product work cannot run its EXIT trap.  Recovery may
# make the preserved lease dispatchable again, but each re-entry must consume a
# durable repair *before* the worker is invoked. Otherwise every crash gets a
# fresh first pass and the risk ceiling is never reached.
make_crash_runner() {
  local stub="$1"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
level=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  counter="${MOCK_CRASH_COUNTER:?}"
  count=0
  [[ -f "$counter" ]] && count="$(cat "$counter")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$counter"
  kill -KILL "$PPID"
  exit 99
fi
exit 99
STUB
  chmod +x "$stub"
}

seed_started_product_lease() {
  local maximum="$1"
  singular_lease_write TASK-0001 agent/widget/TASK-0001-generic widget l2-developer \
    "internal/widget/parser.go" failed RUN-CRASH-SEED "" \
    "$(git -C "$SINGULAR_ROOT" rev-parse target)" CRASH-SEED-batch \
    '["internal/widget/parser.go"]' '[]'
  python3 - "$(singular_lease_path TASK-0001)" "$maximum" <<'PY'
import json
import os
import sys

path, maximum = sys.argv[1:3]
lease = json.load(open(path, encoding="utf-8"))
lease["status"] = "failed"
lease["retryCount"] = 0
lease["maxRetries"] = int(maximum)
lease["productPassStarted"] = True
lease["productPassStartedRunId"] = "RUN-CRASH-SEED"
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(lease, stream)
    stream.write("\n")
os.replace(temporary, path)
PY
}

test_driver_crash_reentry_budget_is_monotonic() {
  local stub out rc calls_before

  # Normal risk: the first crash re-entry consumes the only repair before the
  # worker. A second re-entry is refused without another worker invocation.
  (
  with_fixture
  write_generic_task
  stub="$FIXTURE_TMP/crash-runner.sh"; make_crash_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_CRASH_COUNTER="$FIXTURE_TMP/normal-crash-calls"
  export SINGULAR_WORKER_INFRA_MAX=0
  seed_started_product_lease 1
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "normal crash re-entry unexpectedly completed ($out)"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" \
    "normal crash re-entry consumes repair before worker"
  assert_eq "$(cat "$MOCK_CRASH_COUNTER")" "1" \
    "normal crash re-entry invokes one worker"
  singular_lease_set_status TASK-0001 failed
  singular_task_set_status "$SINGULAR_TASKS_DIR/TASK-0001.md" ready
  calls_before="$(cat "$MOCK_CRASH_COUNTER")"
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "normal repeated crash re-entry reaches durable ceiling ($out)"
  assert_eq "$(cat "$MOCK_CRASH_COUNTER")" "$calls_before" \
    "normal repeated crash cannot invoke an unbudgeted worker"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" \
    "normal repeated crash leaves monotonic count at ceiling"
  )

  # High risk: exactly two crash re-entries are authorized. The third is
  # refused, proving that repeated process death cannot exceed the two-repair
  # policy either.
  (
  with_fixture
  write_generic_task
  python3 - "$SINGULAR_TASKS_DIR/TASK-0001.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("Test policy: `strict_test_first`", "Risk tier: `high`\nTest policy: `strict_test_first`")
open(path, "w", encoding="utf-8").write(text)
PY
  stub="$FIXTURE_TMP/crash-runner.sh"; make_crash_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_CRASH_COUNTER="$FIXTURE_TMP/high-crash-calls"
  export SINGULAR_WORKER_INFRA_MAX=0
  seed_started_product_lease 2
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "high first crash re-entry unexpectedly completed ($out)"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" \
    "high first crash re-entry consumes first repair"
  singular_lease_set_status TASK-0001 failed
  singular_task_set_status "$SINGULAR_TASKS_DIR/TASK-0001.md" ready
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "high second crash re-entry unexpectedly completed ($out)"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "2" \
    "high second crash re-entry consumes second repair"
  assert_eq "$(cat "$MOCK_CRASH_COUNTER")" "2" \
    "high risk authorizes exactly two crash re-entry workers"
  singular_lease_set_status TASK-0001 failed
  singular_task_set_status "$SINGULAR_TASKS_DIR/TASK-0001.md" ready
  calls_before="$(cat "$MOCK_CRASH_COUNTER")"
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "high third crash re-entry reaches durable ceiling ($out)"
  assert_eq "$(cat "$MOCK_CRASH_COUNTER")" "$calls_before" \
    "high third crash cannot invoke an unbudgeted worker"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "2" \
    "high repeated crash leaves monotonic count at ceiling"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"consumedBeforeWorker":true' \
    "crash re-entry consumption is machine-readable"
  unset MOCK_CRASH_COUNTER SINGULAR_WORKER_INFRA_MAX
  )
  echo "ok: crash re-entry repair budgets are monotonic (normal=1, high=2)"
}

test_driver_identical_findings_park_before_third_pass() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-repeat-findings"
  export MOCK_AUDIT_VERDICT_SEQ="needs-fix needs-fix accepted"
  export MOCK_AUDIT_FINDINGS='["  parser   rejects empty input  "]'
  export SINGULAR_TASK_RISK_TIER=high

  local out rc=0 events
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "identical findings park despite remaining high-risk budget ($out)"
  local worker_calls
  worker_calls="$(cat "$MOCK_COUNTER_DIR/worker-calls")"
  [[ "$worker_calls" -ge 2 && "$worker_calls" -le 3 ]] || \
    fail "identical findings: unexpected worker calls $worker_calls"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "2" \
    "identical findings: no audit occurs after the repeated finding set"
  local repairs_used
  repairs_used="$(singular_lease_field TASK-0001 retryCount)"
  [[ "$repairs_used" -le 2 ]] || fail "identical findings: repair ceiling exceeded ($repairs_used)"
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"l1.identical_findings_parked"' \
    "identical findings: normalized repeat event"
  assert_contains "$events" '"productRepairMax":2' \
    "identical findings: park was no-progress, not exhaustion"
  unset MOCK_AUDIT_FINDINGS SINGULAR_TASK_RISK_TIER
  echo "ok: identical normalized findings suppress the next expensive pass"
}

# Auditor infra: prose x1 then a valid verdict. Worker runs ONCE; auditor 2x;
# lease retryCount unchanged; one audit.infra_retry event. A requested budget of
# 9 verifies the hard one-extra-try ceiling.
test_driver_audit_infra_retry() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters3"
  export MOCK_AUDIT_PROSE_TRIES=1
  export MOCK_AUDIT_VERDICT_SEQ="accepted"
  export SINGULAR_AUDIT_INFRA_MAX=9

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "audit-infra run accepts after fresh re-audits ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" "audit-infra: worker invoked exactly once"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "2" "audit-infra: auditor invoked 2x (1 + 1 infra retry)"
  local retries
  retries="$(singular_lease_field TASK-0001 retryCount)"
  assert_eq "$retries" "0" "audit-infra: lease retryCount unchanged"
  local infra_events
  infra_events="$(grep -c '"audit.infra_retry"' "$SINGULAR_EVENTS_FILE" || true)"
  assert_eq "$infra_events" "1" "audit-infra: one audit.infra_retry event"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"maxExtraRetries":1' \
    "audit-infra: machine-readable hard ceiling"
  unset MOCK_AUDIT_PROSE_TRIES SINGULAR_AUDIT_INFRA_MAX
  echo "ok: driver audit-infra isolation (worker x1, auditor x2, retryCount=0)"
}

# Worker infra: worker exits 124 every try. worker.infra_retry fires; the
# fast-path parks worker-infra (no decider prompt); attempt archived worker-infra.
test_driver_worker_infra_parks() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters4"
  export MOCK_WORKER_RC=124
  export SINGULAR_WORKER_INFRA_MAX=1

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "worker-infra run parks (exit 3) ($out)"
  # Worker invoked 1 + 1 infra retry = 2 times; auditor never (worker phase failed).
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "2" "worker-infra: worker invoked 2x (1 + 1 retry)"
  assert_no_file "$MOCK_COUNTER_DIR/audit-calls" "worker-infra: auditor never invoked"
  local wevents
  wevents="$(grep -c '"worker.infra_retry"' "$SINGULAR_EVENTS_FILE" || true)"
  assert_eq "$wevents" "1" "worker-infra: one worker.infra_retry event"
  # Fast-path parks worker-infra: NO decider prompt created.
  local prompts
  prompts="$(find "$SINGULAR_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_eq "$prompts" "" "worker-infra: no decider prompt (fast-path parked)"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"decider.fast_path"' "worker-infra: fast_path event emitted"
  # Attempt archived as worker-infra with policy authority + escalate-parked.
  local idx
  idx="$(find "$SINGULAR_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_file "$idx" "worker-infra: attempts index"
  assert_contains "$(cat "$idx")" '"failureClass": "worker-infra"' "worker-infra: archived failureClass"
  assert_contains "$(cat "$idx")" '"deciderAuthority": "policy"' "worker-infra: archived authority policy"
  # The lease retryCount must NOT have been bumped by the infra retry.
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "0" "worker-infra: retryCount unchanged"
  unset MOCK_WORKER_RC SINGULAR_WORKER_INFRA_MAX
  echo "ok: driver worker-infra parks via fast-path (no decider prompt)"
}

# Audit integrity: the worker gate stays read-only, while the independently
# rerun gate mutates committed source in its disposable audit worktree. This is
# terminal human-judgment work, never infrastructure and never an automatic
# retry, so the lease retryCount remains unchanged.
test_driver_integrity_violation_parks() {
  with_fixture
  write_generic_task
  python3 - "$SINGULAR_TASKS_DIR/TASK-0001.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace(
    "Gate command: `true`",
    "Gate command: `if [[ -n \"${SINGULAR_AUDIT_GATE_WORKTREE:-}\" ]]; then printf mutation >> internal/widget/parser.go; fi; true`",
)
open(path, "w", encoding="utf-8").write(text)
PY
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-integrity"
  export SINGULAR_MAX_RETRIES=2
  export SINGULAR_DECIDER_FAST=0
  # This scenario exercises the disposable rerun's own integrity guard, which
  # 0.21.0's risk-tiered default skips for a clean normal-risk worker gate.
  export SINGULAR_AUDIT_VERIFY=1

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "integrity-violation run parks (exit 3) ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" "integrity-violation: worker invoked once"
  assert_no_file "$MOCK_COUNTER_DIR/audit-calls" "integrity-violation: model auditor never invoked"
  local prompts
  prompts="$(find "$SINGULAR_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_eq "$prompts" "" "integrity-violation: no decider prompt"
  local events
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"audit.source_integrity_violation"' "integrity-violation: audit event emitted"
  assert_contains "$events" '"contextRef":"audit-verification.json"' "integrity-violation: failure context bound to verification artifact"
  assert_contains "$events" '"failureClass":"integrity-violation"' "integrity-violation: fast-path class"
  assert_contains "$events" '"action":"escalate-parked"' "integrity-violation: human-judgment park"
  assert_not_contains "$events" '"action":"escalate-infra"' "integrity-violation: not parked as infrastructure"
  local verification
  verification="$(find "$SINGULAR_RUNS_DIR" -name audit-verification.json | head -1)"
  assert_file "$verification" "integrity-violation: referenced verification artifact"
  assert_eq "$(singular_json_field "$verification" sourceIntegrity.status)" "violation" \
    "integrity-violation: referenced artifact records source mutation"
  local idx
  idx="$(find "$SINGULAR_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_file "$idx" "integrity-violation: attempts index"
  assert_contains "$(cat "$idx")" '"failureClass": "integrity-violation"' "integrity-violation: archived failureClass"
  assert_contains "$(cat "$idx")" '"deciderAction": "escalate-parked"' "integrity-violation: archived action"
  assert_contains "$(cat "$idx")" '"deciderAuthority": "policy"' "integrity-violation: archived authority policy"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "0" "integrity-violation: retryCount unchanged"
  unset SINGULAR_MAX_RETRIES SINGULAR_DECIDER_FAST SINGULAR_AUDIT_VERIFY
  echo "ok: driver integrity violation parks for human judgment (retryCount=0)"
}

# rc==0 but empty/prose worker output is worker-no-packet, not infrastructure.
# Because it also leaves the exact candidate unchanged, it parks immediately
# without spending a product repair on another expensive worker pass.
test_driver_empty_output_is_no_packet_not_infra() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters5"
  export MOCK_WORKER_EMPTY=1
  export SINGULAR_MAX_RETRIES=1

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "empty-output run parks after budget ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" "no-packet: unchanged candidate suppresses second worker pass"
  assert_not_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"worker.infra_retry"' "no-packet: NOT classified as worker-infra"
  local idx
  idx="$(find "$SINGULAR_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_contains "$(cat "$idx")" '"failureClass": "worker-no-packet"' "no-packet: archived worker-no-packet"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"l1.unchanged_candidate_parked"' \
    "no-packet: unchanged candidate park is explicit"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "0" "no-packet: no product repair consumed"
  unset MOCK_WORKER_EMPTY SINGULAR_MAX_RETRIES
  echo "ok: driver rc==0 empty output is worker-no-packet, not worker-infra"
}

# A campaign transition during an otherwise ordinary product attempt invalidates
# every artifact produced by that attempt.  The driver must stop before writing
# any decision, task transition, or repair-budget mutation under the new
# campaign identity.
test_driver_campaign_transition_refuses_publication() {
  with_fixture
  write_generic_task
  python3 - "$SINGULAR_TASKS_DIR/TASK-0001.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace(
    "Gate command: `true`",
    "Gate command: `mkdir -p \"$SINGULAR_STATE_DIR\"; printf \"%s\\n\" singular-campaign-enforced-v1 > \"$SINGULAR_STATE_DIR/CAMPAIGN_ENFORCED\"; false`",
)
open(path, "w", encoding="utf-8").write(text)
PY
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-campaign-transition"
  export MOCK_AUDIT_VERDICT_SEQ="accepted"

  local out rc=0 events decisions=""
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "2" "campaign transition refuses L1 publication ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" \
    "campaign transition: worker invoked exactly once"
  assert_contains "$(sed -n '1,8p' "$SINGULAR_TASKS_DIR/TASK-0001.md")" "Status: ready" \
    "campaign transition: task state remains at entry value"
  assert_eq "$(singular_lease_field TASK-0001 status)" "running" \
    "campaign transition: lease state remains pre-publication"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "0" \
    "campaign transition: repair budget is not consumed"
  assert_no_file "$SINGULAR_RUNS_DIR"/*/decision-gate-red.json \
    "campaign transition: no authoritative decider artifact"
  [[ -f "$SINGULAR_ORCH_DIR/decisions.md" ]] && decisions="$(cat "$SINGULAR_ORCH_DIR/decisions.md")"
  assert_not_contains "$decisions" "decide:" \
    "campaign transition: no decision log entry"
  assert_not_contains "$decisions" "— accept" \
    "campaign transition: no terminal acceptance entry"
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  if [[ "$events" != *'"campaign.identity_mismatch"'* \
      && "$events" != *'"campaign.drift_detected"'* \
      && "$events" != *'"l1.campaign_mismatch"'* ]]; then
    fail "campaign transition: no machine-readable campaign refusal event: $events"
  fi
  echo "ok: campaign transition invalidates L1 publication without consuming product budget"
}

# An accepted auditor verdict is product authority for its exact immutable head.
# If the post-verdict evidence refresh fails, publication must park as an
# external evidence blocker without re-running the worker/auditor, consulting a
# decider, or consuming the lease's product-repair budget.
test_driver_accepted_audit_awaits_evidence() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-evidence-authority"
  export MOCK_AUDIT_VERDICT_SEQ="accepted"
  export SINGULAR_MAX_RETRIES=2

  # l1-drive addresses sibling engine programs through SCRIPT_DIR.  A symlinked
  # test view lets this fixture fail only the third manifest call (the final
  # post-verdict refresh) while exercising every real production helper.
  local engine_view="$FIXTURE_TMP/engine-view" entry
  mkdir -p "$engine_view"
  for entry in "$ENGINE_HOME"/engine/*; do
    ln -s "$entry" "$engine_view/$(basename "$entry")"
  done
  rm "$engine_view/evidence-manifest.sh"
  cat >"$engine_view/evidence-manifest.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
counter="${MOCK_MANIFEST_COUNTER:?}"
count=0
[[ -f "$counter" ]] && count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
if [[ "$count" -eq 3 || "$count" -eq 4 ]]; then
  echo "injected post-verdict evidence finalization failure" >&2
  exit 77
fi
exec "${REAL_EVIDENCE_MANIFEST:?}" "$@"
STUB
  chmod +x "$engine_view/evidence-manifest.sh"
  export MOCK_MANIFEST_COUNTER="$FIXTURE_TMP/manifest-calls"
  export REAL_EVIDENCE_MANIFEST="$ENGINE_HOME/engine/evidence-manifest.sh"

  local out rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "accepted audit with final evidence failure parks ($out)"
  assert_contains "$out" "AWAITING EVIDENCE" "accepted audit reports evidence blocker"
  assert_eq "$(cat "$MOCK_MANIFEST_COUNTER")" "4" "final evidence phase receives exactly one isolated retry"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" "evidence blocker: worker invoked once"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "1" "evidence blocker: auditor invoked once"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "0" \
    "evidence blocker: product-repair budget unchanged"
  assert_eq "$(singular_lease_field TASK-0001 status)" "blocked" \
    "evidence blocker: lease is non-dispatchable"
  assert_contains "$(cat "$SINGULAR_TASKS_DIR/TASK-0001.md")" "Status: blocked" \
    "evidence blocker: task is non-dispatchable"

  local run_dir audit packet head
  run_dir="$(find "$SINGULAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
  audit="$run_dir/audit.json"
  packet="$run_dir/packet.json"
  assert_file "$audit" "evidence blocker: accepted audit preserved"
  assert_file "$packet" "evidence blocker: packet preserved"
  assert_eq "$(singular_json_field "$audit" verdict)" "accepted" \
    "evidence blocker: product verdict remains accepted"
  assert_eq "$(singular_json_field "$packet" status)" "blocked" \
    "evidence blocker: packet is not publishable"
  head="$(git -C "$SINGULAR_ROOT/.worktrees/TASK-0001" rev-parse HEAD)"
  python3 - "$packet" "$head" <<'PY'
import json, sys

packet = json.load(open(sys.argv[1], encoding="utf-8"))
blockers = [b for b in packet["blockers"] if b.get("reason") == "awaiting-evidence"]
assert len(blockers) == 1, blockers
blocker = blockers[0]
assert blocker["class"] == "blocked-external", blocker
assert blocker["headSha"] == sys.argv[2], blocker
assert blocker["productAuditVerdict"] == "accepted", blocker
assert blocker["auditRef"] == "audit.json", blocker
assert blocker["consumesProductRepairBudget"] is False, blocker
assert "do not rerun implementation" in packet["nextAction"], packet["nextAction"]
PY
  assert_no_file "$SINGULAR_INBOX_DIR/$(basename "$run_dir").json" \
    "evidence blocker: accepted audit is not published without final evidence"
  local events prompts idx
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"l1.audit_accepted_awaiting_evidence"' \
    "evidence blocker: preservation event emitted"
  assert_contains "$events" '"l1.task_awaiting_evidence"' \
    "evidence blocker: terminal publication state is explicit"
  assert_contains "$events" '"action":"awaiting-evidence"' \
    "evidence blocker: terminal classification is awaiting-evidence"
  assert_not_contains "$events" '"type":"l1.task_terminal"' \
    "evidence blocker: accepted product audit is not recorded as generic rejection"
  assert_not_contains "$events" '"decider.fast_path"' \
    "evidence blocker: no product/infra decider path"
  assert_contains "$events" '"evidence.infra_retry"' \
    "evidence blocker: isolated evidence retry is observable"
  assert_contains "$events" '"consumesProductRepairBudget":false' \
    "evidence blocker: evidence retry is outside the product budget"
  prompts="$(find "$SINGULAR_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_eq "$prompts" "" "evidence blocker: no decider prompt"
  idx="$(find "$SINGULAR_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_contains "$(cat "$idx")" '"failureClass": "evidence-infra-after-accept"' \
    "evidence blocker: archive distinguishes post-accept evidence failure"
  assert_contains "$(cat "$idx")" '"deciderAction": "awaiting-evidence"' \
    "evidence blocker: archive preserves publication action"

  # Re-entry must recognize the durable accepted checkpoint before orphan or
  # --reset cleanup. Only the failed evidence phase runs again; the immutable
  # audit/head and product counters remain byte-for-byte authoritative.
  local audit_sha_before worker_calls_before audit_calls_before retries_before
  audit_sha_before="$(shasum -a 256 "$audit" | awk '{print $1}')"
  worker_calls_before="$(cat "$MOCK_COUNTER_DIR/worker-calls")"
  audit_calls_before="$(cat "$MOCK_COUNTER_DIR/audit-calls")"
  retries_before="$(singular_lease_field TASK-0001 retryCount)"

  # Once the marker is recognized, even a missing worktree must fail closed
  # before --reset can erase the surviving accepted branch/audit checkpoint.
  mv "$SINGULAR_ROOT/.worktrees/TASK-0001" "$SINGULAR_ROOT/.worktrees/TASK-0001.saved"
  rc=0
  out="$($engine_view/l1-drive.sh --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "missing accepted worktree fails closed before reset ($out)"
  assert_contains "$out" "accepted checkpoint preserved" \
    "missing-worktree checkpoint: preservation outcome"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "$worker_calls_before" \
    "missing-worktree checkpoint: worker not rerun"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "$audit_calls_before" \
    "missing-worktree checkpoint: auditor not rerun"
  assert_eq "$(cat "$MOCK_MANIFEST_COUNTER")" "4" \
    "missing-worktree checkpoint: evidence not attempted without exact head"
  assert_eq "$(git -C "$SINGULAR_ROOT" rev-parse agent/widget/TASK-0001-generic)" "$head" \
    "missing-worktree checkpoint: accepted branch preserved"
  assert_eq "$(singular_json_field "$packet" status)" "blocked" \
    "missing-worktree checkpoint: packet remains awaiting evidence"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"reason":"accepted-worktree-missing"' \
    "missing-worktree checkpoint: exact refusal reason"
  assert_not_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"l1.orphan_recovered"' \
    "missing-worktree checkpoint: orphan cleanup never ran"
  mv "$SINGULAR_ROOT/.worktrees/TASK-0001.saved" "$SINGULAR_ROOT/.worktrees/TASK-0001"

  rc=0
  out="$($engine_view/l1-drive.sh --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "accepted evidence checkpoint resumes without product work ($out)"
  assert_contains "$out" "RESUMED ACCEPTED EVIDENCE" \
    "evidence resume: explicit success outcome"
  assert_eq "$(cat "$MOCK_MANIFEST_COUNTER")" "5" \
    "evidence resume: only evidence finalization reruns"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "$worker_calls_before" \
    "evidence resume: worker not rerun"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "$audit_calls_before" \
    "evidence resume: auditor not rerun"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "$retries_before" \
    "evidence resume: product repair budget unchanged"
  assert_eq "$(shasum -a 256 "$audit" | awk '{print $1}')" "$audit_sha_before" \
    "evidence resume: accepted audit remains byte-identical"
  assert_eq "$(git -C "$SINGULAR_ROOT/.worktrees/TASK-0001" rev-parse HEAD)" "$head" \
    "evidence resume: exact accepted worktree head preserved despite --reset"
  assert_eq "$(git -C "$SINGULAR_ROOT" rev-parse agent/widget/TASK-0001-generic)" "$head" \
    "evidence resume: exact accepted branch head preserved"
  assert_eq "$(singular_json_field "$packet" status)" "accepted" \
    "evidence resume: packet becomes publishable"
  python3 - "$packet" <<'PY'
import json, sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
assert not any(
    isinstance(item, dict) and item.get("reason") == "awaiting-evidence"
    for item in packet.get("blockers", [])
), packet.get("blockers")
PY
  assert_file "$SINGULAR_INBOX_DIR/$(basename "$run_dir").json" \
    "evidence resume: existing accepted packet queued for origin integration"
  assert_eq "$(singular_lease_field TASK-0001 status)" "accepted" \
    "evidence resume: lease accepted"
  assert_contains "$(cat "$SINGULAR_TASKS_DIR/TASK-0001.md")" "Status: accepted" \
    "evidence resume: task accepted"
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"l1.accepted_evidence_resume_started"' \
    "evidence resume: checkpoint recovery started event"
  assert_contains "$events" '"l1.accepted_evidence_resume_completed"' \
    "evidence resume: checkpoint recovery completed event"
  assert_contains "$events" '"workerRerun":false' \
    "evidence resume: machine-readable worker non-rerun"
  assert_contains "$events" '"auditorRerun":false' \
    "evidence resume: machine-readable auditor non-rerun"
  unset SINGULAR_MAX_RETRIES MOCK_MANIFEST_COUNTER REAL_EVIDENCE_MANIFEST
  echo "ok: accepted exact-head audit resumes evidence-only publication without product retry"
}

( test_fixture_configuration_context_isolated )
( test_fast_action_table )
( test_fast_action_repeat_and_disabled )
( test_candidate_signature_ignores_empty_commit_identity )
( test_driver_scrubs_origin_capability_from_provider_runner )
( test_driver_fastpath_provenance )
( test_driver_decider_when_fast_disabled )
( test_driver_risk_bounded_product_repairs )
( test_driver_detached_planned_lease_preserves_product_budget )
( test_driver_crash_reentry_budget_is_monotonic )
( test_driver_identical_findings_park_before_third_pass )
( test_driver_audit_infra_retry )
( test_driver_worker_infra_parks )
( test_driver_integrity_violation_parks )
( test_driver_empty_output_is_no_packet_not_infra )
( test_driver_campaign_transition_refuses_publication )
( test_driver_accepted_audit_awaits_evidence )

echo "decider-fastpath tests passed"
