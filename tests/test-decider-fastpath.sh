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
  # This fixture pins the risk-tier repair semantics (normal=1, high=2).
  # The review policy bounds repairs to maxReviewRounds-1 and defaults to
  # two rounds; keep the high-risk two-repair ceiling reachable here so the
  # cases below keep asserting the tier table. Policy behaviour itself is
  # pinned by tests/test-review-policy.sh and test-first-audit-correction.sh.
  export SINGULAR_REVIEW_MAX_ROUNDS=3
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
if [[ "${1:-}" == "--describe-contract" ]]; then
  printf '%s\n' '{"schema":"singular.runner-contract.v1","version":1,"provider":"codex","arguments":["--worktree","--prompt-file","--level","--run-id","--output-last-message","--role","--capability-profile","--result-file","--describe-contract"],"structuredResult":"singular.orchestration.runner-result.v0","structuredProviderError":"singular.orchestration.provider-error.v0"}'
  exit 0
fi
level=""; out=""; chdir=""; prompt=""; run_id=""; result_file=""
role="${SINGULAR_RUNNER_ROLE:-}"; capability="${SINGULAR_RUNNER_CAPABILITY_PROFILE:-fixture}"
if [[ -n "${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}" \
    && -n "${MOCK_ORIGIN_CAP_LEAK_FILE:-}" ]]; then
  printf '%s\n' "${SINGULAR_RUNNER_ROLE:-unknown}" \
    >>"$MOCK_ORIGIN_CAP_LEAK_FILE"
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C|--worktree) chdir="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    --capability-profile) capability="$2"; shift 2 ;;
    --result-file) result_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
write_result() {
  local rc=$?
  [[ "$rc" -eq 0 && -n "$result_file" ]] || return "$rc"
  python3 - "$result_file" "$run_id" "$role" "$capability" "$out" <<'PY'
import datetime, json, sys
path, run_id, role, capability, output = sys.argv[1:]
json.dump({
    "schema":"singular.orchestration.runner-result.v0", "contractVersion":1,
    "provider":"codex", "runId":run_id, "role":role,
    "capabilityProfile":capability, "exitCode":0, "outcome":"succeeded",
    "failureClass":"none", "providerErrorRef":None, "outputRef":output,
    "recordedAt":datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z"),
}, open(path, "w", encoding="utf-8"))
PY
}
trap write_result EXIT
cdir="${MOCK_COUNTER_DIR:-/tmp}"; mkdir -p "$cdir"
# Decider call (decide.sh dispatches the decider prompt at --level readonly). Emit
# a decider-verdict action so the fast-disabled path actually advances.
if [[ "$prompt" == *decider-prompt-* ]]; then
  dc_file="$cdir/decider-calls"; n=0; [[ -f "$dc_file" ]] && n="$(cat "$dc_file")"; n=$((n+1)); printf '%s' "$n" >"$dc_file"
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
  if [[ "${MOCK_ADVANCE_TARGET:-0}" == "1" ]]; then
    printf 'target moved after admission\n' >"$SINGULAR_ROOT/target-moved.txt"
    git -C "$SINGULAR_ROOT" add target-moved.txt
    git -C "$SINGULAR_ROOT" -c user.name=test -c user.email=test@example.local \
      commit -qm 'move target after admission'
  fi
  mkdir -p "$chdir/internal/widget" "$chdir/.singular-evidence"
  if [[ "${MOCK_WORKER_DELETE:-0}" == "1" ]]; then
    rm -f "$chdir/internal/widget/parser.go"
  elif [[ "${MOCK_WORKER_NO_WRITE:-0}" != "1" ]]; then
    printf 'package widget\n// v%s\n' "$n" >"$chdir/internal/widget/parser.go"
  fi
  printf 'red\n' >"$chdir/.singular-evidence/red.log"; printf 'green\n' >"$chdir/.singular-evidence/green.log"; printf 'reg\n' >"$chdir/.singular-evidence/regression.log"
  python3 - "$out" <<'PY'
import json, sys
import os
claim = [os.environ.get("MOCK_WORKER_CHANGED_CLAIM", "internal/widget/parser.go")]
json.dump({"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"uncommitted","workspace":"/tmp","ownedFiles":["internal/widget/parser.go"],"changedFiles":claim,"commands":[{"cmd":"true","exitCode":0,"logRef":""}],"tests":[{"name":"t","phase":"red","status":"fail","logRef":""},{"name":"t","phase":"green","status":"pass","logRef":""}],"evidence":[{"kind":"red","ref":".singular-evidence/red.log"}],"blockers":[],"nextAction":"audit","createdAt":"2026-01-01T00:00:00Z"}, open(sys.argv[1],"w"))
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
python3 - "$out" "$verdict" "${MOCK_AUDIT_FINDINGS:-[]}" "$run_id" <<'PY'
import json, sys
findings = json.loads(sys.argv[3])
json.dump({"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-0001","runId":sys.argv[4],"branch":"agent/widget/TASK-0001-generic","verdict":sys.argv[2],"evidenceReviewed":[],"commandsRun":[],"findings":findings,"requiredFixes":findings if sys.argv[2] == "needs-fix" else [],"rationale":"ok"}, open(sys.argv[1],"w"))
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
  printf 'preserve untracked\n' >"$SINGULAR_WORKTREES_DIR/TASK-0001/untracked-preserve.txt"
  printf 'preserve ignored\n' >"$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence/ignored-preserve.log"
  singular_task_set_status "$SINGULAR_TASKS_DIR/TASK-0001.md" ready
  calls_before="$(cat "$MOCK_COUNTER_DIR/worker-calls")"
  rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "ordinary re-entry is refused after durable ceiling ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "$calls_before" \
    "ordinary re-entry: no additional product pass"
  assert_eq "$(cat "$SINGULAR_WORKTREES_DIR/TASK-0001/untracked-preserve.txt")" \
    "preserve untracked" "ordinary exhausted re-entry preserves untracked candidate"
  assert_eq "$(cat "$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence/ignored-preserve.log")" \
    "preserve ignored" "ordinary exhausted re-entry preserves ignored evidence"
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
# It leaves the exact candidate unchanged, which used to park immediately. A
# format slip from an otherwise successful worker is not a product signal
# (field run 2026-09-14: one stray "]" deadlocked the queue), so the FIRST
# such failure gets exactly one bounded re-emit charged to the product budget;
# a REPEATED one parks the unchanged candidate.
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
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "2" "no-packet: first format failure gets one re-emit, the repeat parks"
  assert_not_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"worker.infra_retry"' "no-packet: NOT classified as worker-infra"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"l1.packet_format_retry_eligible"' \
    "no-packet: the one re-emit is explicit"
  local idx
  idx="$(find "$SINGULAR_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_contains "$(cat "$idx")" '"failureClass": "worker-no-packet"' "no-packet: archived worker-no-packet"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"l1.unchanged_candidate_parked"' \
    "no-packet: the repeated unchanged-candidate park is explicit"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" "no-packet: the re-emit consumed one product repair, no more"
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

test_driver_deterministic_manifest_rejection_is_single_attempt() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh" out rc=0 run_dir events
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-evidence-input"
  out="$(SINGULAR_EVIDENCE_CONFIG_JSON='{"maxComposedBytes":1}' \
    "$SCRIPT_DIR/l1-drive.sh" --no-audit TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "deterministic evidence input parks ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" \
    "deterministic evidence input: one worker pass"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "0" \
    "deterministic evidence input: no product repair consumed"
  run_dir="$(find "$SINGULAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
  assert_file "$run_dir/evidence-manifest-build-try-0.log" \
    "deterministic evidence input first attempt"
  assert_no_file "$run_dir/evidence-manifest-build-try-1.log" \
    "deterministic evidence input unchanged retry"
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"type":"evidence.input_rejected"' \
    "deterministic evidence input event"
  assert_not_contains "$events" '"type":"evidence.infra_retry"' \
    "deterministic evidence input is not transient infrastructure"
  assert_not_contains "$events" 'decider-prompt' \
    "deterministic evidence input does not consult a model decider"
  echo "ok: deterministic manifest rejection is one attempt with no product repair debit"
}

test_driver_transient_manifest_failure_gets_one_retry() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh" engine_view entry counter out rc=0 events
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-evidence-transient"
  engine_view="$FIXTURE_TMP/engine-view"
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
if [[ "$count" -eq 1 ]]; then exit 75; fi
exec "${REAL_EVIDENCE_MANIFEST:?}" "$@"
STUB
  chmod +x "$engine_view/evidence-manifest.sh"
  counter="$FIXTURE_TMP/manifest-calls"
  export MOCK_MANIFEST_COUNTER="$counter"
  export REAL_EVIDENCE_MANIFEST="$ENGINE_HOME/engine/evidence-manifest.sh"
  out="$(SINGULAR_EVIDENCE_CONFIG_JSON='{"maxComposedBytes":1}' \
    "$engine_view/l1-drive.sh" --no-audit TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "transient evidence retry reaches deterministic stop ($out)"
  assert_eq "$(cat "$counter")" "2" "transient evidence gets exactly one extra attempt"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" \
    "transient evidence retry does not rerun worker"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "0" \
    "transient evidence retry does not consume product repair"
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"type":"evidence.infra_retry"' \
    "transient evidence retry event"
  assert_contains "$events" '"type":"evidence.input_rejected"' \
    "second deterministic rejection event"
  unset MOCK_MANIFEST_COUNTER REAL_EVIDENCE_MANIFEST
  echo "ok: transient manifest failure receives one bounded infrastructure retry"
}

test_driver_invalid_bases_refuse_before_worker_or_debit() {
  local kind base tmp stub out rc calls
  for kind in missing nonancestor; do
    tmp="$(mktemp -d)"
    (
      with_fixture "$tmp"
      write_generic_task
      stub="$FIXTURE_TMP/mock-runner.sh"
      make_seq_runner "$stub"
      export SINGULAR_RUNNER="$stub"
      export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-invalid-base"
      if [[ "$kind" == missing ]]; then
        base=does-not-exist
      else
        tree="$(git -C "$SINGULAR_ROOT" rev-parse 'target^{tree}')"
        base="$(printf 'unrelated base\n' | git -C "$SINGULAR_ROOT" \
          -c user.name=test -c user.email=test@example.local commit-tree "$tree")"
      fi
      rc=0
      out="$(SINGULAR_DISPATCH_BASE_SHA="$base" \
        "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
      assert_eq "$rc" "2" "$kind base deterministic refusal ($out)"
      calls=0
      [[ -f "$MOCK_COUNTER_DIR/worker-calls" ]] && calls="$(cat "$MOCK_COUNTER_DIR/worker-calls")"
      assert_eq "$calls" "0" "$kind base worker launch"
      assert_no_file "$SINGULAR_LEASES_DIR/TASK-0001.json" "$kind base lease/debit"
    )
  done
  echo "ok: missing and nonancestor bases refuse before worker launch or product debit"
}

test_driver_continuation_keeps_candidate_and_reservation_bases_distinct() {
  with_fixture
  write_generic_task
  local candidate_base candidate_source reservation_base worktree fingerprint stub out rc=0 lease
  candidate_base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  git -C "$SINGULAR_ROOT" branch agent/widget/TASK-0001-generic "$candidate_base"
  mkdir -p "$SINGULAR_WORKTREES_DIR"
  worktree="$SINGULAR_WORKTREES_DIR/TASK-0001"
  git -C "$SINGULAR_ROOT" worktree add -q "$worktree" agent/widget/TASK-0001-generic
  printf 'out of scope candidate\n' >"$worktree/outside.txt"
  git -C "$worktree" add outside.txt
  git -C "$worktree" -c user.name=test -c user.email=test@example.local \
    commit -qm 'preserved continuation candidate'
  candidate_source="$(git -C "$worktree" rev-parse HEAD)"
  printf 'scheduler target advanced\n' >"$SINGULAR_ROOT/reservation.txt"
  git -C "$SINGULAR_ROOT" add reservation.txt
  git -C "$SINGULAR_ROOT" commit -qm 'scheduler reservation base'
  reservation_base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  fingerprint="$(singular_campaign_engine_source_fingerprint 2>/dev/null || true)"
  singular_lease_write TASK-0001 agent/widget/TASK-0001-generic widget l2-developer \
    "internal/widget/parser.go" planned RESERVATION-RUN "$worktree" "$reservation_base" \
    RESERVATION-BATCH '["internal/widget/parser.go"]' '[]'
  lease="$SINGULAR_LEASES_DIR/TASK-0001.json"
  python3 - "$lease" "$candidate_base" "$candidate_source" "$reservation_base" \
    "$worktree" "$fingerprint" <<'PY'
import json, os, sys
path, candidate_base, candidate, reservation, worktree, fingerprint = sys.argv[1:]
lease = json.load(open(path, encoding="utf-8"))
lease.update({"reservationOwner": "owner", "reservationGeneration": 1,
              "reservationRunId": "RESERVATION-RUN", "reservationBaseSha": reservation})
lease["continuationAuthorization"] = {
    "authorizationId": "AUTH-CONTINUATION", "state": "reserved",
    "campaignBinding": "legacy", "candidateSourceSha": candidate,
    "candidateBaseSha": candidate_base, "integrationTargetSha": candidate_base,
    "engineSourceFingerprint": fingerprint, "branch": "agent/widget/TASK-0001-generic",
    "worktree": worktree, "reservationOwner": "owner", "reservationGeneration": 1,
    "reservationRunId": "RESERVATION-RUN",
}
with open(path + ".tmp", "w", encoding="utf-8") as stream:
    json.dump(lease, stream); stream.write("\n")
os.replace(path + ".tmp", path)
PY
  stub="$FIXTURE_TMP/mock-runner.sh"
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-continuation-bases"
  out="$(SINGULAR_DISPATCH_BASE_SHA="$reservation_base" \
    SINGULAR_RESERVATION_OWNER=owner SINGULAR_RESERVATION_GENERATION=1 \
    "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "continuation admission result ($out)"
  assert_contains "$out" "failed candidate admission" \
    "continuation passed distinct-base lineage checks"
  [[ ! -f "$MOCK_COUNTER_DIR/worker-calls" ]] || fail "continuation rejection launched worker"
  assert_eq "$(singular_json_field "$lease" retryCount)" "0" \
    "continuation rejection did not consume repair"
  assert_eq "$(git -C "$worktree" rev-parse HEAD)" "$candidate_source" \
    "continuation rejection preserved candidate head"
  echo "ok: continuation candidate base remains distinct from scheduler reservation base"
}

test_driver_retains_precommitted_rejected_candidate_before_provider() {
  local variant
  for variant in scope-and-secret secret-only; do
    (
      with_fixture
      write_generic_task
      local synthetic_prefix='sk-' synthetic_body='AAAAAAAAAAAAAAAAAAAA' synthetic
      synthetic="${synthetic_prefix}${synthetic_body}"
      local base head stub out rc=0 retained lease candidate_path run_dir scope_log secret_log expected
      if [[ "$variant" == "secret-only" ]]; then
        candidate_path="internal/widget/parser.go"
      else
        candidate_path="outside-secret.txt"
      fi
      expected="$FIXTURE_TMP/expected-secret"
      printf '%s\n' "$synthetic" >"$expected"
      base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
      git -C "$SINGULAR_ROOT" branch agent/widget/TASK-0001-generic "$base"
      mkdir -p "$SINGULAR_WORKTREES_DIR"
      git -C "$SINGULAR_ROOT" worktree add -q "$SINGULAR_WORKTREES_DIR/TASK-0001" \
        agent/widget/TASK-0001-generic
      mkdir -p "$(dirname "$SINGULAR_WORKTREES_DIR/TASK-0001/$candidate_path")"
      printf '%s\n' "$synthetic" >"$SINGULAR_WORKTREES_DIR/TASK-0001/$candidate_path"
      git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" add "$candidate_path"
      git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" -c user.name=test -c user.email=test@example.local \
        commit -qm 'precommitted rejected candidate'
      head="$(git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" rev-parse HEAD)"
      singular_lease_write TASK-0001 agent/widget/TASK-0001-generic widget l2-developer \
        "internal/widget/parser.go" blocked RUN-OLD "$SINGULAR_WORKTREES_DIR/TASK-0001" \
        "$base" BATCH-OLD '["internal/widget/parser.go"]' '[]'
      stub="$FIXTURE_TMP/mock-runner.sh"
      make_seq_runner "$stub"
      export SINGULAR_RUNNER="$stub"
      export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-rejected-candidate"
      out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
      assert_eq "$rc" "3" "$variant retained candidate result"
      [[ "$out" != *"$synthetic"* ]] \
        || fail "$variant retained candidate disclosed synthetic credential bytes"
      [[ ! -e "$SINGULAR_WORKTREES_DIR/TASK-0001" ]] \
        || fail "$variant retained candidate still occupies canonical worktree"
      retained="$(find "$SINGULAR_STATE_DIR/retained-worktrees" -mindepth 1 -maxdepth 1 \
        -type d -print -quit)"
      [[ -n "$retained" ]] || fail "$variant rejected candidate was not retained"
      assert_eq "$(git -C "$retained" rev-parse HEAD)" "$head" \
        "$variant rejected candidate retained head"
      cmp -s "$expected" "$retained/$candidate_path" \
        || fail "$variant rejected candidate did not retain exact committed bytes"
      lease="$SINGULAR_LEASES_DIR/TASK-0001.json"
      assert_eq "$(singular_json_field "$lease" retryCount)" "0" \
        "$variant rejected candidate retry counter"
      assert_eq "$(singular_json_field "$lease" productPassStarted)" "False" \
        "$variant rejected candidate product marker"
      [[ ! -f "$MOCK_COUNTER_DIR/worker-calls" ]] \
        || fail "$variant rejected candidate launched a worker"
      run_dir="$(find "$SINGULAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
      scope_log="$run_dir/admission-scope-check.log"
      secret_log="$run_dir/admission-secret-scan.log"
      assert_file "$scope_log" "$variant retained candidate scope admission log"
      assert_file "$secret_log" "$variant retained candidate secret admission log"
      grep -Fq "OpenAI key match in added content" "$secret_log" \
        || fail "$variant retained candidate secret rule missing"
      ! grep -Fq "$synthetic" "$secret_log" \
        || fail "$variant retained candidate secret log disclosed credential bytes"
      if [[ "$variant" == "secret-only" ]]; then
        assert_contains "$(cat "$scope_log")" "all allowed" \
          "in-scope retained candidate scope admission"
      else
        assert_contains "$(cat "$scope_log")" "disallowed paths" \
          "out-of-scope retained candidate scope admission"
      fi
    )
  done
  echo "ok: precommitted scope and in-scope secret rejections preserve candidates before provider work"
}

test_driver_rejects_retained_branch_before_provider() {
  local variant
  for variant in scope-and-secret secret-only; do
    (
      with_fixture
      write_generic_task
      local synthetic_prefix='sk-' synthetic_body='AAAAAAAAAAAAAAAAAAAA' synthetic
      synthetic="${synthetic_prefix}${synthetic_body}"
      local base head stub out rc=0 lease candidate_path run_dir scope_log secret_log expected
      if [[ "$variant" == "secret-only" ]]; then
        candidate_path="internal/widget/parser.go"
      else
        candidate_path="outside-secret.txt"
      fi
      expected="$FIXTURE_TMP/expected-secret"
      printf '%s\n' "$synthetic" >"$expected"
      base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
      git -C "$SINGULAR_ROOT" checkout -q -b agent/widget/TASK-0001-generic
      mkdir -p "$(dirname "$SINGULAR_ROOT/$candidate_path")"
      printf '%s\n' "$synthetic" >"$SINGULAR_ROOT/$candidate_path"
      git -C "$SINGULAR_ROOT" add "$candidate_path"
      git -C "$SINGULAR_ROOT" -c user.name=test -c user.email=test@example.local \
        commit -qm 'retained branch rejected candidate'
      head="$(git -C "$SINGULAR_ROOT" rev-parse HEAD)"
      git -C "$SINGULAR_ROOT" checkout -q target
      stub="$FIXTURE_TMP/mock-runner.sh"
      make_seq_runner "$stub"
      export SINGULAR_RUNNER="$stub"
      export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-rejected-branch"
      out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
      assert_eq "$rc" "3" "$variant retained branch admission result"
      [[ "$out" != *"$synthetic"* ]] \
        || fail "$variant retained branch disclosed synthetic credential bytes"
      [[ ! -f "$MOCK_COUNTER_DIR/worker-calls" ]] \
        || fail "$variant retained branch launched a worker"
      assert_eq "$(git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" rev-parse HEAD)" "$head" \
        "$variant retained branch candidate head preserved"
      cmp -s "$expected" "$SINGULAR_WORKTREES_DIR/TASK-0001/$candidate_path" \
        || fail "$variant retained branch did not preserve exact candidate bytes"
      lease="$SINGULAR_LEASES_DIR/TASK-0001.json"
      assert_eq "$(singular_json_field "$lease" retryCount)" "0" \
        "$variant retained branch retry counter"
      assert_eq "$(singular_json_field "$lease" productPassStarted)" "False" \
        "$variant retained branch product marker"
      run_dir="$(find "$SINGULAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
      scope_log="$run_dir/admission-scope-check.log"
      secret_log="$run_dir/admission-secret-scan.log"
      assert_file "$scope_log" "$variant retained branch scope admission log"
      assert_file "$secret_log" "$variant retained branch secret admission log"
      grep -Fq "OpenAI key match in added content" "$secret_log" \
        || fail "$variant retained branch secret rule missing"
      ! grep -Fq "$synthetic" "$secret_log" \
        || fail "$variant retained branch secret log disclosed credential bytes"
      if [[ "$variant" == "secret-only" ]]; then
        assert_contains "$(cat "$scope_log")" "all allowed" \
          "in-scope retained branch scope admission"
      else
        assert_contains "$(cat "$scope_log")" "disallowed paths" \
          "out-of-scope retained branch scope admission"
      fi
    )
  done
  echo "ok: retained branch scope and in-scope secret checks refuse before provider launch"
}

test_driver_exhausted_preserves_partial_checkout_before_reset() {
  with_fixture
  write_generic_task
  local base stub out rc=0 lease
  base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  git -C "$SINGULAR_ROOT" branch agent/widget/TASK-0001-generic "$base"
  mkdir -p "$SINGULAR_WORKTREES_DIR"
  git -C "$SINGULAR_ROOT" worktree add -q "$SINGULAR_WORKTREES_DIR/TASK-0001" \
    agent/widget/TASK-0001-generic
  printf 'partial candidate\n' >"$SINGULAR_WORKTREES_DIR/TASK-0001/partial.txt"
  mkdir -p "$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence"
  printf 'ignored evidence\n' \
    >"$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence/preserved.log"
  singular_lease_write TASK-0001 agent/widget/TASK-0001-generic widget l2-developer \
    "internal/widget/parser.go" failed RUN-EXHAUSTED "$SINGULAR_WORKTREES_DIR/TASK-0001" \
    "$base" BATCH-EXHAUSTED '["internal/widget/parser.go"]' '[]'
  lease="$SINGULAR_LEASES_DIR/TASK-0001.json"
  python3 - "$lease" <<'PY'
import json, os, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value.update({"status": "failed", "retryCount": 1, "maxRetries": 1,
              "productPassStarted": True, "productPassStartedRunId": "RUN-EXHAUSTED"})
with open(path + ".tmp", "w", encoding="utf-8") as stream:
    json.dump(value, stream); stream.write("\n")
os.replace(path + ".tmp", path)
PY
  stub="$FIXTURE_TMP/mock-runner.sh"
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-exhausted-preserve"
  out="$("$SCRIPT_DIR/l1-drive.sh" --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "exhausted partial candidate result ($out)"
  assert_eq "$(cat "$SINGULAR_WORKTREES_DIR/TASK-0001/partial.txt")" \
    "partial candidate" "exhausted untracked candidate preserved in place"
  assert_eq "$(cat "$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence/preserved.log")" \
    "ignored evidence" "exhausted ignored evidence preserved in place"
  assert_eq "$(singular_json_field "$lease" retryCount)" "1" \
    "exhausted retry identity preserved"
  [[ ! -f "$MOCK_COUNTER_DIR/worker-calls" ]] || fail "exhausted candidate launched a worker"
  echo "ok: exhausted reset re-entry preserves partial and ignored candidate evidence"
}

test_driver_preserves_staged_untracked_and_ignored_partial_candidate() {
  with_fixture
  write_generic_task
  python3 - "$SINGULAR_TASKS_DIR/TASK-0001.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("- `internal/widget/parser.go`", "- `internal/widget/parser.go`\n- `internal/widget/note.txt`")
open(path, "w", encoding="utf-8").write(text)
PY
  local base stub out rc=0 retained
  base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  git -C "$SINGULAR_ROOT" branch agent/widget/TASK-0001-generic "$base"
  mkdir -p "$SINGULAR_WORKTREES_DIR"
  git -C "$SINGULAR_ROOT" worktree add -q "$SINGULAR_WORKTREES_DIR/TASK-0001" \
    agent/widget/TASK-0001-generic
  mkdir -p "$SINGULAR_WORKTREES_DIR/TASK-0001/internal/widget" \
    "$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence"
  printf 'staged candidate\n' >"$SINGULAR_WORKTREES_DIR/TASK-0001/internal/widget/parser.go"
  git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" add internal/widget/parser.go
  printf 'untracked candidate\n' >"$SINGULAR_WORKTREES_DIR/TASK-0001/internal/widget/note.txt"
  printf 'ignored evidence\n' >"$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence/partial.log"
  singular_lease_write TASK-0001 agent/widget/TASK-0001-generic widget l2-developer \
    "internal/widget/parser.go internal/widget/note.txt" blocked RUN-PARTIAL \
    "$SINGULAR_WORKTREES_DIR/TASK-0001" "$base" BATCH-PARTIAL \
    '["internal/widget/parser.go","internal/widget/note.txt"]' '[]'
  stub="$FIXTURE_TMP/mock-runner.sh"
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-partial-preserve"
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "partial candidate requires continuation ($out)"
  retained="$(find "$SINGULAR_STATE_DIR/retained-worktrees" -mindepth 1 -maxdepth 1 \
    -type d -print -quit)"
  [[ -n "$retained" ]] || fail "partial candidate was not retained"
  assert_eq "$(git -C "$retained" diff --cached --name-only)" \
    "internal/widget/parser.go" "partial candidate staged identity"
  assert_eq "$(cat "$retained/internal/widget/note.txt")" \
    "untracked candidate" "partial candidate untracked bytes"
  assert_eq "$(cat "$retained/.singular-evidence/partial.log")" \
    "ignored evidence" "partial candidate ignored evidence"
  [[ ! -e "$SINGULAR_WORKTREES_DIR/TASK-0001" ]] \
    || fail "partial candidate still occupies canonical worktree"
  [[ ! -f "$MOCK_COUNTER_DIR/worker-calls" ]] || fail "partial candidate launched a worker"
  echo "ok: staged, untracked, and ignored partial candidate state is retained intact"
}

test_driver_clean_same_task_candidate_reprovisions() {
  with_fixture
  write_generic_task
  local base head stub out rc=0 retained
  base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  git -C "$SINGULAR_ROOT" branch agent/widget/TASK-0001-generic "$base"
  mkdir -p "$SINGULAR_WORKTREES_DIR"
  git -C "$SINGULAR_ROOT" worktree add -q "$SINGULAR_WORKTREES_DIR/TASK-0001" \
    agent/widget/TASK-0001-generic
  mkdir -p "$SINGULAR_WORKTREES_DIR/TASK-0001/internal/widget"
  printf 'valid retained correction\n' \
    >"$SINGULAR_WORKTREES_DIR/TASK-0001/internal/widget/parser.go"
  git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" add internal/widget/parser.go
  git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" -c user.name=test -c user.email=test@example.local \
    commit -qm 'valid retained correction'
  mkdir -p "$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence"
  printf 'prior retained evidence\n' \
    >"$SINGULAR_WORKTREES_DIR/TASK-0001/.singular-evidence/prior.log"
  head="$(git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" rev-parse HEAD)"
  singular_lease_write TASK-0001 agent/widget/TASK-0001-generic widget l2-developer \
    "internal/widget/parser.go" blocked RUN-PRIOR "$SINGULAR_WORKTREES_DIR/TASK-0001" \
    "$base" BATCH-PRIOR '["internal/widget/parser.go"]' '[]'
  python3 - "$SINGULAR_LEASES_DIR/TASK-0001.json" <<'PY'
import json, os, sys
path = sys.argv[1]
lease = json.load(open(path, encoding="utf-8"))
lease.update({"productPassStarted": True, "productPassStartedRunId": "RUN-PRIOR",
              "retryCount": 0, "maxRetries": 1})
with open(path + ".tmp", "w", encoding="utf-8") as stream:
    json.dump(lease, stream); stream.write("\n")
os.replace(path + ".tmp", path)
PY
  stub="$FIXTURE_TMP/mock-runner.sh"
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-same-task"
  out="$(MOCK_WORKER_NO_WRITE=1 SINGULAR_EVIDENCE_CONFIG_JSON='{"maxComposedBytes":1}' \
    "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "same-task retained correction reaches deterministic stop ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" \
    "same-task retained correction dispatches one worker"
  assert_eq "$(git -C "$SINGULAR_WORKTREES_DIR/TASK-0001" rev-parse HEAD)" "$head" \
    "same-task correction reprovisioned exact candidate"
  retained="$(find "$SINGULAR_STATE_DIR/retained-worktrees" -mindepth 1 -maxdepth 1 \
    -type d -print -quit)"
  [[ -n "$retained" ]] || fail "same-task prior checkout was not retained"
  assert_eq "$(git -C "$retained" rev-parse HEAD)" "$head" \
    "same-task prior checkout retained exact head"
  assert_eq "$(cat "$retained/.singular-evidence/prior.log")" \
    "prior retained evidence" "same-task ignored evidence retained"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" \
    "same-task correction consumes exactly one durable repair"
  assert_eq "$(singular_lease_field TASK-0001 productPassStartedRunId)" "RUN-PRIOR" \
    "same-task correction preserves started-pass identity"
  echo "ok: clean same-task correction is retained and coherently reprovisioned"
}

test_driver_pins_base_across_target_movement_and_replaces_worker_delta() {
  with_fixture
  write_generic_task
  local admitted target_after stub out rc=0 run_dir packet
  admitted="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  git -C "$SINGULAR_ROOT" checkout -q -b agent/widget/TASK-0001-generic
  mkdir -p "$SINGULAR_ROOT/internal/widget"
  printf 'precommitted candidate\n' >"$SINGULAR_ROOT/internal/widget/parser.go"
  git -C "$SINGULAR_ROOT" add internal/widget/parser.go
  git -C "$SINGULAR_ROOT" -c user.name=test -c user.email=test@example.local \
    commit -qm 'precommitted candidate'
  git -C "$SINGULAR_ROOT" checkout -q target
  stub="$FIXTURE_TMP/mock-runner.sh"
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-moving-target"
  out="$(MOCK_ADVANCE_TARGET=1 MOCK_WORKER_NO_WRITE=1 \
    MOCK_WORKER_CHANGED_CLAIM=worker-invented.txt \
    SINGULAR_EVIDENCE_CONFIG_JSON='{"maxComposedBytes":1}' \
    "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "moving target fixture reaches deterministic manifest stop ($out)"
  target_after="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  [[ "$target_after" != "$admitted" ]] || fail "worker did not move target after admission"
  run_dir="$(find "$SINGULAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
  packet="$run_dir/packet.json"
  assert_file "$packet" "moving target host packet"
  python3 - "$packet" "$admitted" <<'PY'
import json, sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
assert packet["baseRef"] == sys.argv[2], packet
assert packet["changedFiles"] == ["internal/widget/parser.go"], packet
assert "worker-invented.txt" not in packet["changedFiles"], packet
PY
  assert_eq "$(singular_lease_field TASK-0001 baseSha)" "$admitted" \
    "moving target immutable lease base"
  echo "ok: moving target cannot change admitted base or host-derived packet delta"
}

test_driver_stages_owned_deletion_and_reports_exact_delta() {
  with_fixture
  write_generic_task
  mkdir -p "$SINGULAR_ROOT/internal/widget"
  printf 'delete me\n' >"$SINGULAR_ROOT/internal/widget/parser.go"
  git -C "$SINGULAR_ROOT" add internal/widget/parser.go
  git -C "$SINGULAR_ROOT" commit -qm 'tracked owned file'
  local base stub out rc=0 run_dir packet head
  base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  stub="$FIXTURE_TMP/mock-runner.sh"
  make_seq_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters-owned-deletion"
  out="$(MOCK_WORKER_DELETE=1 SINGULAR_EVIDENCE_CONFIG_JSON='{"maxComposedBytes":1}' \
    "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "owned deletion reaches deterministic manifest stop ($out)"
  run_dir="$(find "$SINGULAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
  packet="$run_dir/packet.json"
  assert_file "$packet" "owned deletion packet"
  head="$(singular_json_field "$packet" headSha)"
  [[ ! -e "$SINGULAR_WORKTREES_DIR/TASK-0001/internal/widget/parser.go" ]] \
    || fail "owned deletion was not committed"
  git -C "$SINGULAR_ROOT" diff --quiet "$base"..."$head" -- internal/widget/parser.go \
    && fail "owned deletion produced no committed delta"
  python3 - "$packet" "$base" <<'PY'
import json, sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
assert packet["baseRef"] == sys.argv[2], packet
assert packet["changedFiles"] == ["internal/widget/parser.go"], packet
PY
  echo "ok: owned deletion is staged, committed, and host-reported exactly"
}

# An accepted auditor verdict is product authority for its exact immutable head.
# If the post-verdict evidence refresh fails, publication must park as an
# external evidence blocker without re-running the worker/auditor, consulting a
# decider, or consuming the lease's product-repair budget.
test_driver_accepted_audit_awaits_evidence() {
  with_fixture
  write_generic_task
  git -C "$SINGULAR_ROOT" add docs/orchestration/tasks/TASK-0001.md
  git -C "$SINGULAR_ROOT" commit -qm 'accepted recovery fixture admission base'
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
  rm "$engine_view/gate-check.sh"
  cat >"$engine_view/gate-check.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
counter="${MOCK_GATE_COUNTER:?}"
count=0
[[ -f "$counter" ]] && count="$(cat "$counter")"
printf '%s\n' "$((count + 1))" >"$counter"
exec "${REAL_GATE_CHECK:?}" "$@"
STUB
  chmod +x "$engine_view/gate-check.sh"
  export MOCK_MANIFEST_COUNTER="$FIXTURE_TMP/manifest-calls"
  export REAL_EVIDENCE_MANIFEST="$ENGINE_HOME/engine/evidence-manifest.sh"
  export MOCK_GATE_COUNTER="$MOCK_COUNTER_DIR/gate-calls"
  export REAL_GATE_CHECK="$ENGINE_HOME/engine/gate-check.sh"

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

  local run_dir audit packet head base target_after checkpoint_copy lease_copy task_copy
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
  base="$(singular_json_field "$packet" baseRef)"
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

  # The accepted B->H product is independent of later target movement B->T.
  # Recovery must select the original admitted B from host-written packet/lease
  # evidence, never relabel it with the now-current T.
  printf 'independent target advancement\n' >"$SINGULAR_ROOT/target-after-acceptance.txt"
  git -C "$SINGULAR_ROOT" add target-after-acceptance.txt
  git -C "$SINGULAR_ROOT" commit -qm 'advance target independently after accepted checkpoint'
  target_after="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  [[ "$target_after" != "$base" && "$target_after" != "$head" ]] \
    || fail "accepted recovery fixture did not keep B, H, and T distinct"
  git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$base" "$head" \
    || fail "accepted recovery fixture lost B->H ancestry"
  if git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$target_after" "$head"; then
    fail "accepted recovery fixture target T unexpectedly precedes candidate H"
  fi

  # Re-entry must recognize the durable accepted checkpoint before orphan or
  # --reset cleanup. Only the failed evidence phase runs again; the immutable
  # audit/head and product counters remain byte-for-byte authoritative.
  local audit_sha_before worker_calls_before audit_calls_before gate_calls_before
  local decider_calls_before retries_before manifest_calls_before state_sha_before
  audit_sha_before="$(shasum -a 256 "$audit" | awk '{print $1}')"
  worker_calls_before="$(cat "$MOCK_COUNTER_DIR/worker-calls")"
  audit_calls_before="$(cat "$MOCK_COUNTER_DIR/audit-calls")"
  gate_calls_before="$(cat "$MOCK_COUNTER_DIR/gate-calls")"
  decider_calls_before="0"
  [[ -f "$MOCK_COUNTER_DIR/decider-calls" ]] \
    && decider_calls_before="$(cat "$MOCK_COUNTER_DIR/decider-calls")"
  retries_before="$(singular_lease_field TASK-0001 retryCount)"
  manifest_calls_before="$(cat "$MOCK_MANIFEST_COUNTER")"
  checkpoint_copy="$FIXTURE_TMP/accepted-packet.original.json"
  lease_copy="$FIXTURE_TMP/accepted-lease.original.json"
  task_copy="$FIXTURE_TMP/accepted-task.original.md"
  cp "$packet" "$checkpoint_copy"
  cp "$(singular_lease_path TASK-0001)" "$lease_copy"
  cp "$SINGULAR_TASKS_DIR/TASK-0001.md" "$task_copy"

  checkpoint_state_sha() {
    shasum -a 256 "$packet" "$audit" "$(singular_lease_path TASK-0001)" \
      "$SINGULAR_TASKS_DIR/TASK-0001.md" | shasum -a 256 | awk '{print $1}'
  }
  assert_no_accepted_recovery_work() {
    local label="$1"
    assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "$worker_calls_before" \
      "$label: worker not rerun"
    assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "$audit_calls_before" \
      "$label: auditor not rerun"
    assert_eq "$(cat "$MOCK_COUNTER_DIR/gate-calls")" "$gate_calls_before" \
      "$label: gate not rerun"
    local decider_calls=0
    [[ -f "$MOCK_COUNTER_DIR/decider-calls" ]] \
      && decider_calls="$(cat "$MOCK_COUNTER_DIR/decider-calls")"
    assert_eq "$decider_calls" "$decider_calls_before" "$label: decider not invoked"
    assert_eq "$(cat "$MOCK_MANIFEST_COUNTER")" "$manifest_calls_before" \
      "$label: evidence not attempted"
  }

  # Recognition must distinguish malformed retained acceptance from an
  # ordinary failed worker packet. The accepted audit is sufficient to fence
  # cleanup, but never sufficient to accept malformed packet bytes.
  printf '{not-json\n' >"$packet"
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "invalid retained JSON refuses before reset ($out)"
  assert_contains "$out" "invalid-retained-state" \
    "invalid retained JSON: explicit preservation refusal"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "invalid retained JSON: accepted evidence remains byte-identical"
  assert_no_accepted_recovery_work "invalid retained JSON"
  cp "$checkpoint_copy" "$packet"

  python3 - "$packet" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["blockers"] = None
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "null blockers retained acceptance refuses ($out)"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "null blockers: retained state preserved"
  assert_no_accepted_recovery_work "null blockers"
  cp "$checkpoint_copy" "$packet"

  python3 - "$packet" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
del data["ownedFiles"]
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "missing required retained field refuses ($out)"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "missing required field: retained state preserved"
  assert_no_accepted_recovery_work "missing required field"
  cp "$checkpoint_copy" "$packet"

  # A recognized accepted marker is preservation authority, not payload
  # authority. Packet base B must agree exactly with the original lease base;
  # another ancestor (including H itself) cannot relabel the admitted product.
  python3 - "$packet" "$head" <<'PY'
import json, os, sys
path, wrong = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["baseRef"] = wrong
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "accepted packet wrong base refuses before paid work ($out)"
  assert_contains "$out" "accepted checkpoint preserved" \
    "wrong-base checkpoint: preservation outcome"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "wrong-base checkpoint: all checkpoint/task/lease history preserved"
  assert_no_accepted_recovery_work "wrong-base checkpoint"
  cp "$checkpoint_copy" "$packet"

  # A malformed selected base is likewise a recognized checkpoint refusal and
  # --reset may not turn it into orphan cleanup.
  python3 - "$packet" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["baseRef"] = "malformed accepted base"
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "malformed accepted base refuses before reset/paid work ($out)"
  assert_contains "$out" "accepted checkpoint preserved" \
    "malformed-base checkpoint: preservation outcome"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "malformed-base checkpoint: all checkpoint/task/lease history preserved"
  assert_no_accepted_recovery_work "malformed-base checkpoint"
  cp "$checkpoint_copy" "$packet"

  # Changed accepted H and changed original lease B are independent conflicts;
  # neither may fall through to fresh admission or cleanup.
  python3 - "$packet" "$target_after" <<'PY'
import json, os, sys
path, changed = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["headSha"] = changed
for blocker in data.get("blockers", []):
    if blocker.get("reason") == "awaiting-evidence":
        blocker["headSha"] = changed
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "changed accepted head refuses before paid work ($out)"
  assert_contains "$out" "accepted checkpoint preserved" \
    "changed-head checkpoint: preservation outcome"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "changed-head checkpoint: all checkpoint/task/lease history preserved"
  assert_no_accepted_recovery_work "changed-head checkpoint"
  cp "$checkpoint_copy" "$packet"

  python3 - "$(singular_lease_path TASK-0001)" "$head" <<'PY'
import json, os, sys
path, changed = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["baseSha"] = changed
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "accepted packet/lease base disagreement refuses ($out)"
  assert_contains "$out" "accepted checkpoint preserved" \
    "lease-base disagreement: preservation outcome"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "lease-base disagreement: all checkpoint/task/lease history preserved"
  assert_no_accepted_recovery_work "lease-base disagreement"
  cp "$lease_copy" "$(singular_lease_path TASK-0001)"

  rc=0
  out="$(SINGULAR_DISPATCH_BASE_SHA="$head" $engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "accepted checkpoint conflicting base override refuses ($out)"
  assert_contains "$out" "accepted checkpoint preserved" \
    "conflicting override: preservation outcome"
  assert_no_accepted_recovery_work "conflicting override"

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
  assert_eq "$(cat "$MOCK_MANIFEST_COUNTER")" "$manifest_calls_before" \
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

  # Exercise the two producer publication boundaries after evidence is durable:
  # accepted packet before lease transition, then accepted lease before inbox.
  # Re-entry completes only the missing transitions and preserves packet bytes.
  "$REAL_EVIDENCE_MANIFEST" --run-dir "$run_dir" --task-id TASK-0001 \
    --worktree "$SINGULAR_ROOT/.worktrees/TASK-0001" --base-ref "$base" \
    --head-sha "$head" >/dev/null
  python3 - "$packet" "$head" <<'PY'
import json, os, sys
path, head = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["blockers"] = [
    item for item in data["blockers"]
    if not (isinstance(item, dict) and item.get("reason") == "awaiting-evidence"
            and item.get("headSha") == head)
]
data["status"] = "accepted"
data["nextAction"] = "import into control state and reconcile"
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  local boundary packet_boundary_sha boundary_manifest_before
  packet_boundary_sha="$(shasum -a 256 "$packet" | awk '{print $1}')"
  boundary_manifest_before="$(cat "$MOCK_MANIFEST_COUNTER")"
  for boundary in packet lease; do
    cp "$lease_copy" "$(singular_lease_path TASK-0001)"
    cp "$task_copy" "$SINGULAR_TASKS_DIR/TASK-0001.md"
    if [[ "$boundary" == "lease" ]]; then
      python3 - "$(singular_lease_path TASK-0001)" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["status"] = "accepted"
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
    fi
    rc=0
    out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
    assert_eq "$rc" "0" "$boundary publication boundary completes ($out)"
    assert_contains "$out" "RESUMED ACCEPTED EVIDENCE" \
      "$boundary publication boundary: explicit continuation"
    assert_eq "$(shasum -a 256 "$packet" | awk '{print $1}')" "$packet_boundary_sha" \
      "$boundary publication boundary: accepted packet bytes preserved"
    assert_eq "$(cat "$MOCK_MANIFEST_COUNTER")" "$boundary_manifest_before" \
      "$boundary publication boundary: evidence not rerun"
    assert_eq "$(singular_lease_field TASK-0001 status)" "accepted" \
      "$boundary publication boundary: lease completed"
    assert_file "$SINGULAR_INBOX_DIR/$(basename "$run_dir").json" \
      "$boundary publication boundary: exact inbox publication"
    unlink "$SINGULAR_INBOX_DIR/$(basename "$run_dir").json"
  done
  cp "$checkpoint_copy" "$packet"
  cp "$lease_copy" "$(singular_lease_path TASK-0001)"
  cp "$task_copy" "$SINGULAR_TASKS_DIR/TASK-0001.md"

  # Exhaust the ordinary product-repair allowance after acceptance. Recovery
  # and its subsequent duplicate no-op must still precede that fresh-work guard.
  python3 - "$(singular_lease_path TASK-0001)" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["retryCount"] = data["maxRetries"]
data["productPassStarted"] = True
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  retries_before="$(singular_lease_field TASK-0001 retryCount)"
  rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "accepted evidence checkpoint resumes without product work ($out)"
  assert_contains "$out" "RESUMED ACCEPTED EVIDENCE" \
    "evidence resume: explicit success outcome"
  assert_eq "$(cat "$MOCK_MANIFEST_COUNTER")" "$((manifest_calls_before + 1))" \
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

  local packet_sha_after_resume inbox_count
  packet_sha_after_resume="$(shasum -a 256 "$packet" | awk '{print $1}')"
  worker_calls_before="$(cat "$MOCK_COUNTER_DIR/worker-calls")"
  audit_calls_before="$(cat "$MOCK_COUNTER_DIR/audit-calls")"
  gate_calls_before="$(cat "$MOCK_COUNTER_DIR/gate-calls")"
  decider_calls_before="0"
  [[ -f "$MOCK_COUNTER_DIR/decider-calls" ]] \
    && decider_calls_before="$(cat "$MOCK_COUNTER_DIR/decider-calls")"
  manifest_calls_before="$(cat "$MOCK_MANIFEST_COUNTER")"
  rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "duplicate accepted dispatch is an idempotent no-op ($out)"
  assert_contains "$out" "already queued/imported; dispatch is a no-op" \
    "duplicate accepted dispatch reaches existing no-op"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "$worker_calls_before" \
    "duplicate accepted dispatch: zero worker calls"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "$audit_calls_before" \
    "duplicate accepted dispatch: zero auditor calls"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/gate-calls")" "$gate_calls_before" \
    "duplicate accepted dispatch: zero gate calls"
  local duplicate_decider_calls=0
  [[ -f "$MOCK_COUNTER_DIR/decider-calls" ]] \
    && duplicate_decider_calls="$(cat "$MOCK_COUNTER_DIR/decider-calls")"
  assert_eq "$duplicate_decider_calls" "$decider_calls_before" \
    "duplicate accepted dispatch: zero decider calls"
  assert_eq "$(cat "$MOCK_MANIFEST_COUNTER")" "$manifest_calls_before" \
    "duplicate accepted dispatch: zero evidence calls"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "$retries_before" \
    "duplicate accepted dispatch: exhausted budget not debited"
  assert_eq "$(singular_lease_field TASK-0001 baseSha)" "$base" \
    "duplicate accepted dispatch: recorded admitted base B remains"
  assert_eq "$(singular_json_field "$packet" baseRef)" "$base" \
    "duplicate accepted dispatch: packet base B remains"
  assert_eq "$(singular_json_field "$packet" headSha)" "$head" \
    "duplicate accepted dispatch: packet head H remains"
  assert_eq "$(shasum -a 256 "$packet" | awk '{print $1}')" "$packet_sha_after_resume" \
    "duplicate accepted dispatch: accepted packet bytes unchanged"
  assert_eq "$(shasum -a 256 "$audit" | awk '{print $1}')" "$audit_sha_before" \
    "duplicate accepted dispatch: accepted audit bytes unchanged"
  assert_eq "$(git -C "$SINGULAR_ROOT/.worktrees/TASK-0001" rev-parse HEAD)" "$head" \
    "duplicate accepted dispatch: candidate worktree retained"
  assert_eq "$(git -C "$SINGULAR_ROOT" rev-parse agent/widget/TASK-0001-generic)" "$head" \
    "duplicate accepted dispatch: candidate branch retained"
  inbox_count="$(find "$SINGULAR_INBOX_DIR" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d '[:space:]')"
  assert_eq "$inbox_count" "1" "duplicate accepted dispatch: exactly one publication"

  # A queued filename is never sufficient proof. Schema, campaign, audit, and
  # the exact imported run are validated before the duplicate no-op.
  local accepted_packet_copy accepted_audit_copy inbox_packet imported_dir
  accepted_packet_copy="$FIXTURE_TMP/accepted-packet.publishable.json"
  accepted_audit_copy="$FIXTURE_TMP/accepted-audit.publishable.json"
  inbox_packet="$SINGULAR_INBOX_DIR/$(basename "$run_dir").json"
  imported_dir="$SINGULAR_ORCH_DIR/packets/imported/TASK-0001"
  cp "$packet" "$accepted_packet_copy"
  cp "$audit" "$accepted_audit_copy"

  python3 - "$packet" "$inbox_packet" <<'PY'
import json, os, sys
for path in sys.argv[1:]:
    data = json.load(open(path, encoding="utf-8"))
    data["schema"] = "singular.orchestration.state-packet.invalid"
    temporary = path + ".test.tmp"
    json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
    open(temporary, "a", encoding="utf-8").write("\n")
    os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh --reset TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "schema-broken queued duplicate refuses ($out)"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "schema-broken duplicate: retained authority preserved"
  assert_no_accepted_recovery_work "schema-broken duplicate"
  cp "$accepted_packet_copy" "$packet"
  cp "$accepted_packet_copy" "$inbox_packet"

  python3 - "$packet" "$inbox_packet" <<'PY'
import json, os, sys
for path in sys.argv[1:]:
    data = json.load(open(path, encoding="utf-8"))
    for item in data["evidence"]:
        if item.get("kind") == "campaign-binding":
            item["ref"] = "campaign:stale-fixture"
    temporary = path + ".test.tmp"
    json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
    open(temporary, "a", encoding="utf-8").write("\n")
    os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "old-campaign queued duplicate refuses ($out)"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "old-campaign duplicate: retained authority preserved"
  assert_no_accepted_recovery_work "old-campaign duplicate"
  cp "$accepted_packet_copy" "$packet"
  cp "$accepted_packet_copy" "$inbox_packet"

  python3 - "$audit" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["runId"] = "RUN-MISMATCHED-AUDIT"
temporary = path + ".test.tmp"
json.dump(data, open(temporary, "w", encoding="utf-8"), indent=2)
open(temporary, "a", encoding="utf-8").write("\n")
os.replace(temporary, path)
PY
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "mismatched accepted audit duplicate refuses ($out)"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "mismatched audit duplicate: retained authority preserved"
  assert_no_accepted_recovery_work "mismatched audit duplicate"
  cp "$accepted_audit_copy" "$audit"

  mkdir -p "$imported_dir"
  printf '{"unrelated":true}\n' >"$imported_dir/RUN-UNRELATED.json"
  state_sha_before="$(checkpoint_state_sha)"
  rc=0
  out="$($engine_view/l1-drive.sh TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "unrelated imported JSON is not duplicate proof ($out)"
  assert_eq "$(checkpoint_state_sha)" "$state_sha_before" \
    "unrelated import: retained authority preserved"
  assert_no_accepted_recovery_work "unrelated import"
  unlink "$imported_dir/RUN-UNRELATED.json"
  unset SINGULAR_MAX_RETRIES MOCK_MANIFEST_COUNTER REAL_EVIDENCE_MANIFEST \
    MOCK_GATE_COUNTER REAL_GATE_CHECK
  echo "ok: accepted B->H checkpoint survives independent T, validates authority, and resumes idempotently"
}

run_case() {
  local name="$1" filter=",${SINGULAR_TEST_CASES:-},"
  if [[ "$filter" == ",," || "$filter" == *",$name,"* ]]; then
    ( "$name" )
  fi
}

run_case test_fixture_configuration_context_isolated
run_case test_fast_action_table
run_case test_fast_action_repeat_and_disabled
run_case test_candidate_signature_ignores_empty_commit_identity
run_case test_driver_scrubs_origin_capability_from_provider_runner
run_case test_driver_fastpath_provenance
run_case test_driver_decider_when_fast_disabled
run_case test_driver_risk_bounded_product_repairs
run_case test_driver_detached_planned_lease_preserves_product_budget
run_case test_driver_crash_reentry_budget_is_monotonic
run_case test_driver_identical_findings_park_before_third_pass
run_case test_driver_audit_infra_retry
run_case test_driver_worker_infra_parks
run_case test_driver_integrity_violation_parks
run_case test_driver_empty_output_is_no_packet_not_infra
run_case test_driver_campaign_transition_refuses_publication
run_case test_driver_deterministic_manifest_rejection_is_single_attempt
run_case test_driver_transient_manifest_failure_gets_one_retry
run_case test_driver_invalid_bases_refuse_before_worker_or_debit
run_case test_driver_continuation_keeps_candidate_and_reservation_bases_distinct
run_case test_driver_retains_precommitted_rejected_candidate_before_provider
run_case test_driver_rejects_retained_branch_before_provider
run_case test_driver_exhausted_preserves_partial_checkout_before_reset
run_case test_driver_preserves_staged_untracked_and_ignored_partial_candidate
run_case test_driver_clean_same_task_candidate_reprovisions
run_case test_driver_pins_base_across_target_movement_and_replaces_worker_delta
run_case test_driver_stages_owned_deletion_and_reports_exact_delta
run_case test_driver_accepted_audit_awaits_evidence

echo "decider-fastpath tests passed"
