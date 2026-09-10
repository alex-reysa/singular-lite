#!/usr/bin/env bash
set -euo pipefail

# Continuity-core regression tests (T-F2, T-E1, T-E2 + structural split):
# - singular_task_preflight: pass + every refusal reason, incl. owned/forbidden
#   segment-boundary semantics ("a/b" conflicts with "a/b/c", NOT "a/bc");
# - singular_attempt_archive: per-attempt artifact copies + attempts/index.json
#   upsert across attempts;
# - singular_finding_id: normalization (whitespace/backticks/case-insensitive);
# - singular_findings_ledger_update: open -> auditor-status resolve -> re-report
#   reopen -> accepted resolves all; absence alone never resolves;
# - implementer capsule: argv scope (post-amend) wins over the packet's scope,
#   lists capped at 20;
# - reviewer capsule: tolerates junk verdict JSON (missing/odd fields);
# - l1-drive.sh --dry-run stdout for a valid generic task remains byte-identical
#   (run-ids and the intentionally changed retry-policy field normalized) to
#   the HEAD revision on the same fixture.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-continuity-core.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing file $1"; }

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" \
    "$root/docs/orchestration/tasks" \
    "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/l2-test-first-developer.md"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/auditor.md"
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
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
    SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE SINGULAR_ATTEMPT_TASK_ID SINGULAR_ATTEMPT_STARTED_AT 2>/dev/null || true
  # Re-source so derived paths (events file, lock dirs) follow the fixture env.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
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

GOOD_TASK='{"taskId":"TASK-0001","area":"widget","workerBranch":"agent/widget/TASK-0001","targetBranch":"target","objective":"Do the thing.","gateCommand":"true","ownedFiles":["internal/widget/parser.go"],"forbiddenFiles":["Any file outside the owned scope."],"acceptanceCriteria":["Parser handles empty input."]}'

mutate_task() {
  # mutate_task <key> <json-value> -> GOOD_TASK with key replaced
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d[sys.argv[2]]=json.loads(sys.argv[3]); print(json.dumps(d))' \
    "$GOOD_TASK" "$1" "$2"
}

expect_preflight_fail() {
  # expect_preflight_fail <label> <expected-reason-substr> <task_json> [args...]
  local label="$1" expect="$2" json="$3"; shift 3
  local out rc=0
  out="$(singular_task_preflight "$json" "$@")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "$label: preflight must fail"
  assert_contains "$out" "$expect" "$label"
}

test_preflight_pass_and_failures() {
  with_fixture
  local out rc

  # Pass: valid task, no output, rc 0.
  out="$(singular_task_preflight "$GOOD_TASK")" || fail "preflight: valid task must pass"
  assert_eq "$out" "" "preflight: valid task prints nothing"

  # Pass: the real fixture task file parsed through singular_task_json.
  write_generic_task
  out="$(singular_task_preflight "$(singular_task_json "$SINGULAR_TASKS_DIR/TASK-0001.md")")" \
    || fail "preflight: parsed fixture task must pass"

  expect_preflight_fail "empty taskId" "missing taskId" "$(mutate_task taskId '""')"
  expect_preflight_fail "empty area" "missing area" "$(mutate_task area '""')"
  expect_preflight_fail "empty workerBranch" "missing workerBranch" "$(mutate_task workerBranch '""')"
  expect_preflight_fail "empty targetBranch" "missing targetBranch" "$(mutate_task targetBranch '""')"
  expect_preflight_fail "empty objective" "missing objective" "$(mutate_task objective '""')"
  expect_preflight_fail "worker==target" "workerBranch equals targetBranch" "$(mutate_task workerBranch '"target"')"
  expect_preflight_fail "no owned files" "no owned files" "$(mutate_task ownedFiles '[]')"

  # Owned/forbidden conflicts use segment-boundary semantics.
  expect_preflight_fail "forbidden under owned" "conflicts with forbidden" \
    "$(mutate_task forbiddenFiles '["internal/widget/parser.go/sub"]')"
  expect_preflight_fail "owned under forbidden" "conflicts with forbidden" \
    "$(mutate_task forbiddenFiles '["internal/widget"]')"
  expect_preflight_fail "owned equals forbidden" "conflicts with forbidden" \
    "$(mutate_task forbiddenFiles '["internal/widget/parser.go"]')"
  # Segment boundary: "a/b" must NOT conflict with "a/bc".
  local seg_task
  seg_task="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["ownedFiles"]=["a/b"]; d["forbiddenFiles"]=["a/bc"]; print(json.dumps(d))' "$GOOD_TASK")"
  out="$(singular_task_preflight "$seg_task")" || fail "segment boundary: a/b vs a/bc must NOT conflict ($out)"
  seg_task="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["ownedFiles"]=["a/b"]; d["forbiddenFiles"]=["a/b/c"]; print(json.dumps(d))' "$GOOD_TASK")"
  expect_preflight_fail "segment boundary conflict" "conflicts with forbidden" "$seg_task"

  # Gate command: whitespace-only fails when required, passes when exempt (dry-run).
  expect_preflight_fail "blank gate" "no gate command" "$(mutate_task gateCommand '"   "')" "" "" 1
  out="$(singular_task_preflight "$(mutate_task gateCommand '"   "')" "" "" 0)" \
    || fail "blank gate with require_gate=0 (dry-run exemption) must pass"
  # An effective gate cmd passed by the driver (config default) satisfies the check.
  out="$(singular_task_preflight "$(mutate_task gateCommand '""')" "make check" "" 1)" \
    || fail "effective gate cmd from argv must satisfy the gate check"

  # Acceptance criteria requirement is env-switchable (default on).
  expect_preflight_fail "no acceptance criteria" "no acceptance criteria" "$(mutate_task acceptanceCriteria '[]')"
  rc=0
  out="$(SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE=0 singular_task_preflight "$(mutate_task acceptanceCriteria '[]')")" || rc=$?
  assert_eq "$rc" "0" "acceptance check disabled via SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE=0"

  echo "ok: preflight"
}

test_attempt_archive() {
  with_fixture
  local run_id="RUN-ARCH-1" run_dir
  run_dir="$SINGULAR_RUNS_DIR/$run_id"
  mkdir -p "$run_dir"
  echo "prompt v1" >"$run_dir/l2-active-prompt.md"
  echo "re-audit prompt v1" >"$run_dir/auditor-active-prompt.md"
  echo '{"taskId":"TASK-0009","runId":"RUN-ARCH-1"}' >"$run_dir/packet.json"
  echo "worker log" >"$run_dir/worker-codex.log"
  echo '{"exitCode":1}' >"$run_dir/gate-check.json"
  echo "gate log" >"$run_dir/gate-check.log"
  echo '{"action":"retry"}' >"$run_dir/decision-gate-red.json"

  SINGULAR_ATTEMPT_TASK_ID="TASK-0009" SINGULAR_ATTEMPT_STARTED_AT="2026-01-01T00:00:00Z" \
    singular_attempt_archive "$run_dir" 1 "gate-red" "unknown" "" "retry" "decider" \
    || fail "archive attempt 1 must succeed"

  assert_file "$run_dir/attempts/1/failure.txt" "attempt 1"
  assert_eq "$(cat "$run_dir/attempts/1/failure.txt")" "gate-red" "attempt 1 failure class"
  assert_file "$run_dir/attempts/1/l2-active-prompt.md" "attempt 1 prompt copy"
  assert_file "$run_dir/attempts/1/auditor-active-prompt.md" "attempt 1 re-audit prompt copy"
  assert_file "$run_dir/attempts/1/packet.json" "attempt 1 packet copy"
  assert_file "$run_dir/attempts/1/worker-codex.log" "attempt 1 worker log copy"
  assert_file "$run_dir/attempts/1/gate-check.json" "attempt 1 gate json copy"
  assert_file "$run_dir/attempts/1/decision-gate-red.json" "attempt 1 decision copy"
  # Root files stay in place (additive only).
  assert_file "$run_dir/packet.json" "root packet untouched"

  local idx="$run_dir/attempts/index.json"
  assert_file "$idx" "attempts index"
  assert_eq "$(singular_json_field "$idx" schema)" "singular.orchestration.attempts-index.v0" "index schema"
  assert_eq "$(singular_json_field "$idx" taskId)" "TASK-0009" "index taskId"
  assert_eq "$(singular_json_field "$idx" runId)" "RUN-ARCH-1" "index runId"
  local entry
  entry="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["attempts"]; print(len(a), a[0]["n"], a[0]["failureClass"], a[0]["deciderAction"], a[0]["deciderAuthority"], a[0]["dir"], a[0]["startedAt"])' "$idx")"
  assert_eq "$entry" "1 1 gate-red retry decider attempts/1 2026-01-01T00:00:00Z" "index attempt-1 entry"

  # Second (accepted) attempt appends a new entry.
  echo "prompt v2" >"$run_dir/l2-active-prompt.md"
  echo '{"verdict":"accepted"}' >"$run_dir/audit.json"
  SINGULAR_ATTEMPT_TASK_ID="TASK-0009" singular_attempt_archive "$run_dir" 2 "" "accepted" "abc1234" "accept" "l1" \
    || fail "archive attempt 2 must succeed"
  assert_eq "$(cat "$run_dir/attempts/2/failure.txt")" "accepted" "accepted attempt failure.txt"
  assert_file "$run_dir/attempts/2/audit.json" "attempt 2 audit copy"
  assert_eq "$(cat "$run_dir/attempts/2/l2-active-prompt.md")" "prompt v2" "attempt 2 captures its own prompt"
  assert_eq "$(cat "$run_dir/attempts/1/l2-active-prompt.md")" "prompt v1" "attempt 1 archive immutable"
  entry="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["attempts"]; print(len(a), a[1]["n"], repr(a[1]["failureClass"]), a[1]["auditVerdict"], a[1]["headSha"], a[1]["deciderAction"])' "$idx")"
  assert_eq "$entry" "2 2 '' accepted abc1234 accept" "index attempt-2 entry (empty failureClass on accept)"

  # Re-archiving the same n upserts (no duplicate entries).
  SINGULAR_ATTEMPT_TASK_ID="TASK-0009" singular_attempt_archive "$run_dir" 2 "" "accepted" "abc1234" "accept" "l1" || true
  assert_eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["attempts"]))' "$idx")" "2" "index upsert by n"

  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"l1.attempt_archived"' "archive event emitted"
  echo "ok: attempt archive"
}

test_finding_id_normalization() {
  with_fixture
  local a b c
  a="$(singular_finding_id 'Fix the `parser` bug')"
  b="$(singular_finding_id '  fix   the parser BUG ')"
  c="$(singular_finding_id 'a different finding')"
  assert_eq "$a" "$b" "finding id: whitespace/backticks/case normalize to same id"
  [[ "$a" != "$c" ]] || fail "finding id: different text must differ"
  [[ "$a" =~ ^f-[0-9a-f]{12}$ ]] || fail "finding id format: got $a"
  echo "ok: finding id"
}

test_findings_ledger_lifecycle() {
  with_fixture
  local run_dir="$SINGULAR_RUNS_DIR/RUN-LEDGER-1" out id_a id_b ledger
  mkdir -p "$run_dir"
  ledger="$run_dir/findings-status.json"
  id_a="$(singular_finding_id 'Parser drops nil input')"
  id_b="$(singular_finding_id 'Handle empty payload')"

  # Attempt 1: two new findings open.
  cat >"$run_dir/a1.json" <<EOF
{"taskId":"TASK-0009","runId":"RUN-LEDGER-1","verdict":"needs-fix",
 "findings":["Parser drops nil input"],"requiredFixes":["Handle empty payload"]}
EOF
  out="$(singular_findings_ledger_update "$run_dir" 1 "$run_dir/a1.json")" || fail "ledger update 1"
  assert_eq "$out" "open=2 resolved=0 new=2" "ledger attempt 1 counts"
  assert_eq "$(singular_json_field "$ledger" schema)" "singular.orchestration.findings-ledger.v0" "ledger schema"
  assert_eq "$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; e=f[sys.argv[2]]; print(e["status"], e["source"], e["firstSeenAttempt"], e["lastSeenAttempt"])' "$ledger" "$id_a")" \
    "open finding 1 1" "ledger A initial"
  assert_eq "$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; print(f[sys.argv[2]]["source"])' "$ledger" "$id_b")" \
    "requiredFix" "ledger B source"

  # Attempt 2: auditor findingsStatus resolves A; B re-reported (absence alone
  # would not have resolved A — only the explicit status does).
  cat >"$run_dir/a2.json" <<EOF
{"taskId":"TASK-0009","runId":"RUN-LEDGER-1","verdict":"needs-fix",
 "findings":[],"requiredFixes":["Handle empty payload"],
 "findingsStatus":{"$id_a":"resolved"}}
EOF
  out="$(singular_findings_ledger_update "$run_dir" 2 "$run_dir/a2.json")" || fail "ledger update 2"
  assert_eq "$out" "open=1 resolved=1 new=0" "ledger attempt 2 counts"
  assert_eq "$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; e=f[sys.argv[2]]; print(e["status"], e["resolvedAttempt"], e["resolvedBy"])' "$ledger" "$id_a")" \
    "resolved 2 auditor-status" "ledger A resolved by auditor status"
  assert_eq "$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; e=f[sys.argv[2]]; print(e["status"], e["lastSeenAttempt"])' "$ledger" "$id_b")" \
    "open 2" "ledger B still open, lastSeen bumped"

  # Attempt 3: A re-reported (with different formatting) -> REOPENED.
  cat >"$run_dir/a3.json" <<EOF
{"taskId":"TASK-0009","runId":"RUN-LEDGER-1","verdict":"needs-fix",
 "findings":["parser  drops NIL input"],"requiredFixes":[]}
EOF
  out="$(singular_findings_ledger_update "$run_dir" 3 "$run_dir/a3.json")" || fail "ledger update 3"
  assert_eq "$out" "open=2 resolved=0 new=0" "ledger attempt 3 counts (reopen, no new)"
  assert_eq "$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; e=f[sys.argv[2]]; print(e["status"], e["resolvedAttempt"], e["resolvedBy"], e["firstSeenAttempt"], e["lastSeenAttempt"])' "$ledger" "$id_a")" \
    "open None None 1 3" "ledger A reopened (resolution cleared, firstSeen kept)"

  # Attempt 4: accepted verdict resolves everything still open.
  echo '{"taskId":"TASK-0009","runId":"RUN-LEDGER-1","verdict":"accepted"}' >"$run_dir/a4.json"
  out="$(singular_findings_ledger_update "$run_dir" 4 "$run_dir/a4.json")" || fail "ledger update 4"
  assert_eq "$out" "open=0 resolved=2 new=0" "ledger attempt 4 counts"
  assert_eq "$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["findings"]; print(all(x["status"]=="resolved" for x in f), len(f))' "$ledger")" \
    "True 2" "ledger accepted resolves all open"
  assert_eq "$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; print(f[sys.argv[2]]["resolvedBy"], f[sys.argv[2]]["resolvedAttempt"])' "$ledger" "$id_a")" \
    "audit-accepted 4" "ledger A resolved by acceptance"
  echo "ok: findings ledger"
}

test_implementer_capsule_scope_and_caps() {
  with_fixture
  local run_dir="$SINGULAR_RUNS_DIR/RUN-CAP-1" capsule owned_json
  mkdir -p "$run_dir"
  # Packet declares a DIFFERENT (stale) scope and >20 changed files.
  python3 - "$run_dir/packet.json" <<'PY'
import json, sys
packet = {
    "schema": "singular.orchestration.state-packet.v0",
    "taskId": "TASK-0009", "runId": "RUN-CAP-1",
    "baseRef": "target", "branch": "agent/widget/TASK-0009",
    "ownedFiles": ["packet/stale.go"],
    "changedFiles": [f"internal/widget/f{i}.go" for i in range(25)],
    "commands": [{"cmd": f"cmd{i}", "exitCode": 0, "logRef": ""} for i in range(25)],
    "tests": [{"name": "t1", "phase": "red", "status": "fail", "logRef": ""}],
    "blockers": [],
    "nextAction": "await auditor verdict",
}
with open(sys.argv[1], "w") as f:
    json.dump(packet, f)
PY
  owned_json="$(python3 -c 'import json; print(json.dumps([f"argv/own{i}.go" for i in range(25)]))')"
  singular_capsule_write_implementer "$run_dir" 2 "$run_dir/packet.json" "deadbeef" \
    "$owned_json" '["argv/forbidden.go"]' || fail "implementer capsule write"
  capsule="$run_dir/implementer-capsule.json"
  assert_file "$capsule" "implementer capsule"
  assert_eq "$(singular_json_field "$capsule" role)" "implementer" "capsule role"
  assert_eq "$(singular_json_field "$capsule" attempt)" "2" "capsule attempt"
  assert_eq "$(singular_json_field "$capsule" headSha)" "deadbeef" "capsule headSha"
  # Scope comes from ARGV (post-amend), capped at 20 — never from the packet.
  assert_eq "$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(len(c["ownedFiles"]), c["ownedFiles"][0], c["forbiddenFiles"])' "$capsule")" \
    "20 argv/own0.go ['argv/forbidden.go']" "capsule scope from argv + cap"
  assert_not_contains "$(cat "$capsule")" "packet/stale.go" "capsule must not use the packet's stale scope"
  assert_eq "$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(len(c["changedFiles"]), len(c["commands"]))' "$capsule")" \
    "20 20" "capsule list caps"
  assert_eq "$(singular_json_field "$capsule" packetSha256)" "$(singular_sha256_file "$run_dir/packet.json")" "capsule packetSha256"
  # contentHash: sha256 over canonical JSON minus createdAt/contentHash/packetSha256.
  assert_eq "$(singular_json_field "$capsule" contentHash)" \
    "$(python3 -c 'import hashlib,json,sys
c=json.load(open(sys.argv[1]))
h={k:v for k,v in c.items() if k not in ("createdAt","contentHash","packetSha256")}
print(hashlib.sha256(json.dumps(h,sort_keys=True,separators=(",",":")).encode()).hexdigest())' "$capsule")" \
    "capsule contentHash recomputes"
  echo "ok: implementer capsule"
}

test_reviewer_capsule_tolerates_junk() {
  with_fixture
  local run_dir="$SINGULAR_RUNS_DIR/RUN-REV-1" capsule
  mkdir -p "$run_dir"
  # Junk verdict: wrong types, missing arrays — must not crash.
  echo '{"verdict":42,"findings":"not-a-list","rationale":12345}' >"$run_dir/audit.json"
  singular_capsule_write_reviewer "$run_dir" 1 "$run_dir/audit.json" "" "feedf00d" \
    || fail "reviewer capsule must tolerate junk verdict JSON"
  capsule="$run_dir/reviewer-capsule.json"
  assert_file "$capsule" "reviewer capsule"
  assert_eq "$(singular_json_field "$capsule" role)" "reviewer" "reviewer role"
  assert_eq "$(singular_json_field "$capsule" verdict)" "42" "junk verdict coerced to string"
  assert_eq "$(singular_json_field "$capsule" diffRange)" "" "attempt-1 diffRange empty"
  assert_eq "$(singular_json_field "$capsule" auditedHeadSha)" "feedf00d" "auditedHeadSha"
  assert_eq "$(singular_json_field "$capsule" findingIds)" "[]" "junk findings -> empty findingIds"

  # A sane second attempt: prior head feeds diffRange; finding ids stable.
  cat >"$run_dir/audit.json" <<'EOF'
{"taskId":"TASK-0009","runId":"RUN-REV-1","verdict":"needs-fix",
 "findings":["Parser drops nil input"],"requiredFixes":["Parser  drops NIL input"],
 "evidenceReviewed":["runs/RUN-REV-1/gate-check.json"],"commandsRun":["git diff"],
 "rationale":"needs work"}
EOF
  singular_capsule_write_reviewer "$run_dir" 2 "$run_dir/audit.json" "feedf00d" "cafe1234" \
    || fail "reviewer capsule attempt 2"
  assert_eq "$(singular_json_field "$capsule" diffRange)" "feedf00d..cafe1234" "attempt-2 diffRange"
  # findings + requiredFixes normalize to the SAME id -> deduped to one.
  assert_eq "$(singular_json_field "$capsule" findingIds)" "[\"$(singular_finding_id 'Parser drops nil input')\"]" \
    "findingIds use normalized finding ids"
  assert_eq "$(singular_json_field "$capsule" auditSha256)" "$(singular_sha256_file "$run_dir/audit.json")" "auditSha256"
  echo "ok: reviewer capsule"
}

# --- Dry-run byte-parity vs HEAD ------------------------------------------------
# Proves the structural split + preflight changed nothing observable for a valid
# task: stdout+stderr of `l1-drive.sh --dry-run` on a generic fixture task is
# byte-identical to the HEAD revision of l1-drive.sh run on the same fixture
# (run-ids normalized; both share the CURRENT lib.sh, whose changes are additive).
normalize_run_ids() {
  sed -E \
    -e 's/RUN-[0-9]{8}T[0-9]{6}Z-[0-9]+/RUN-XXXXXXXXTXXXXXXZ-X/g' \
    -e 's/  (max_retries=[0-9]+|risk_tier=[^ ]+  product_repairs=[0-9]+)$/  RETRY_POLICY/'
}

test_dry_run_byte_identical_to_head() {
  with_fixture
  write_generic_task

  local old_engine="$FIXTURE_TMP/old-engine"
  mkdir -p "$old_engine"
  cp "$SCRIPT_DIR"/*.sh "$old_engine/"
  git -C "$ENGINE_HOME" show HEAD:engine/l1-drive.sh >"$old_engine/l1-drive.sh" \
    || fail "cannot extract HEAD l1-drive.sh"
  chmod +x "$old_engine/l1-drive.sh"

  local new_out old_out
  new_out="$("$SCRIPT_DIR/l1-drive.sh" --dry-run TASK-0001 2>&1)" || fail "new l1-drive dry run failed: $new_out"
  old_out="$("$old_engine/l1-drive.sh" --dry-run TASK-0001 2>&1)" || fail "HEAD l1-drive dry run failed: $old_out"
  new_out="$(printf '%s\n' "$new_out" | normalize_run_ids)"
  old_out="$(printf '%s\n' "$old_out" | normalize_run_ids)"
  if [[ "$new_out" != "$old_out" ]]; then
    diff <(printf '%s\n' "$old_out") <(printf '%s\n' "$new_out") >&2 || true
    fail "dry-run output must match HEAD outside the intentional retry-policy field"
  fi
  echo "ok: dry-run byte parity vs HEAD"
}

# --- Preflight wiring in the driver ---------------------------------------------
test_drive_preflight_blocks_bad_task() {
  with_fixture
  write_generic_task
  # Break the task: drop acceptance criteria AND blank the objective.
  python3 - "$SINGULAR_TASKS_DIR/TASK-0001.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace("Implement the widget parser.", "")
text = text.replace("- Parser handles empty input.", "")
open(path, "w").write(text)
PY
  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "driver preflight failure exits 3"
  assert_contains "$out" "task preflight failed" "driver echoes preflight refusal"
  assert_contains "$out" "missing objective" "driver echoes the reasons"
  assert_eq "$(singular_task_field "$SINGULAR_TASKS_DIR/TASK-0001.md" status)" "blocked" "task parked as blocked"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"l1.preflight_failed"' "preflight event emitted"
  assert_contains "$(cat "$SINGULAR_ORCH_DIR/decisions.md")" "escalate-parked" "decision recorded"
  [[ ! -d "$SINGULAR_LEASES_DIR" || -z "$(ls -A "$SINGULAR_LEASES_DIR" 2>/dev/null)" ]] \
    || fail "preflight failure must not create a lease"
  echo "ok: driver preflight wiring"
}

# --- T-E3: structured fix prompt ------------------------------------------------
# Build a fixture run_dir with a ledger (2 open from attempt 1, 1 resolved, 1
# open from attempt 2), an implementer capsule, and a gate-check.log; render the
# structured fix prompt for n=2 / gate-red and assert its shape.
fixprompt_fixture() {
  local rd="$1"
  mkdir -p "$rd"
  printf 'BASE WORKER PROMPT BODY\nschema "singular.orchestration.state-packet.v0"\n' >"$rd/base-prompt.md"
  cat >"$rd/findings-status.json" <<'JSON'
{"schema":"singular.orchestration.findings-ledger.v0","taskId":"TASK-0001","runId":"R",
 "findings":[
  {"id":"f-open1","text":"first open finding","source":"finding","status":"open","firstSeenAttempt":1,"lastSeenAttempt":2,"resolvedAttempt":null,"resolvedBy":null},
  {"id":"f-open2","text":"second open finding","source":"requiredFix","status":"open","firstSeenAttempt":1,"lastSeenAttempt":2,"resolvedAttempt":null,"resolvedBy":null},
  {"id":"f-done","text":"already resolved finding","source":"finding","status":"resolved","firstSeenAttempt":1,"lastSeenAttempt":1,"resolvedAttempt":2,"resolvedBy":"auditor-status"},
  {"id":"f-open3","text":"third open finding","source":"finding","status":"open","firstSeenAttempt":2,"lastSeenAttempt":2,"resolvedAttempt":null,"resolvedBy":null}
 ],"updatedAt":"2026-01-01T00:00:00Z"}
JSON
  cat >"$rd/implementer-capsule.json" <<'JSON'
{"schema":"singular.orchestration.context-capsule.v0","role":"implementer","nextAction":"finish the parser","blockers":["bx"],"changedFiles":["src/widget.py"]}
JSON
  printf 'gate noise line\nanother gate line\nGATE FAILED: regression\n' >"$rd/gate-check.log"
}

test_fix_prompt_structured() {
  with_fixture
  local rd="$FIXTURE_TMP/fixrun"
  fixprompt_fixture "$rd"
  local out="$rd/out.md"
  singular_render_fix_prompt "$out" "$rd/base-prompt.md" "$rd" 2 gate-red /dev/null \
    '["src/widget.py"]' '[]' || fail "fix prompt render must succeed"
  local body; body="$(cat "$out")"
  assert_contains "$body" "Authoritative findings" "fix: findings header"
  assert_contains "$body" "[from attempt 1] (f-open1) first open finding" "fix: open1 attribution"
  assert_contains "$body" "[from attempt 1] (f-open2) second open finding" "fix: open2 attribution"
  assert_contains "$body" "[from attempt 2] (f-open3) third open finding" "fix: open3 attribution"
  assert_not_contains "$body" "f-done" "fix: resolved finding excluded"
  assert_not_contains "$body" "already resolved finding" "fix: resolved text excluded"
  assert_contains "$body" "Current scope (authoritative" "fix: scope header"
  assert_contains "$body" "GATE FAILED: regression" "fix: last gate log line"
  assert_contains "$body" "Prior implementer summary (LOW authority" "fix: low-authority header"
  assert_contains "$body" "Address every Authoritative finding; do not relitigate resolved ones; stay in scope." "fix: closing line"
  # The base prompt's raw audit-JSON byte-tail must not leak into the appended
  # sections (we appended only the contract reference string, never a verdict).
  assert_not_contains "$body" '"schema": "singular.orchestration.audit-verdict' "fix: no raw audit JSON"
  echo "ok: structured fix prompt"
}

# (b) section cap: one oversized finding -> capped section + truncation marker.
test_fix_prompt_section_cap() {
  with_fixture
  local rd="$FIXTURE_TMP/fixcap"
  mkdir -p "$rd"
  printf 'BASE\n' >"$rd/base-prompt.md"
  printf 'gate fail\n' >"$rd/gate-check.log"
  python3 - "$rd/findings-status.json" <<'PY'
import json, sys
big = "X" * 6000
json.dump({"schema":"singular.orchestration.findings-ledger.v0","taskId":"TASK-0001","runId":"R",
  "findings":[{"id":"f-big","text":big,"source":"finding","status":"open",
               "firstSeenAttempt":1,"lastSeenAttempt":1,"resolvedAttempt":None,"resolvedBy":None}],
  "updatedAt":"now"}, open(sys.argv[1],"w"))
PY
  # A small section cap (200) makes the section-level truncation fire on top of
  # the per-finding 500-char cap; the oversized 6000-char finding is reduced to
  # the section budget and a truncation marker is appended.
  local out="$rd/out.md"
  SINGULAR_CONTEXT_SECTION_MAX_CHARS=200 singular_render_fix_prompt "$out" "$rd/base-prompt.md" "$rd" 2 gate-red /dev/null '["a"]' '[]' \
    || fail "cap render must succeed"
  # The findings section (everything between its header and the next header) must
  # be <= cap + marker and carry the truncation marker.
  local section
  section="$(awk '/^### Authoritative findings/{f=1;next} /^### Evidence/{f=0} f' "$out")"
  assert_contains "$section" "section truncated" "cap: truncation marker present"
  local len=${#section}
  [[ "$len" -le 300 ]] || fail "cap: section length $len exceeds cap+marker"
  echo "ok: fix prompt section cap"
}

# (b-default) Section cap at its DEFAULT (4000). The lowered-cap test above proves
# the mechanism fires; this proves the DEFAULT path works: enough open findings
# (12 x ~400 chars each, > 4000 joined) trip the section-level truncation marker
# at the default cap WITHOUT any SINGULAR_CONTEXT_SECTION_MAX_CHARS override.
test_fix_prompt_section_cap_default() {
  with_fixture
  local rd="$FIXTURE_TMP/fixcapdef"
  mkdir -p "$rd"
  printf 'BASE\n' >"$rd/base-prompt.md"
  printf 'gate fail\n' >"$rd/gate-check.log"
  # 12 distinct findings, each ~400 chars of text -> per-finding text is under the
  # 500-char per-finding cap (kept whole), so the JOINED section (~12 * ~430 with
  # the "- [from attempt N] (id) " prefix ~= 5100 chars) overflows the 4000 default.
  python3 - "$rd/findings-status.json" <<'PY'
import json, sys
findings = []
for i in range(12):
    findings.append({
        "id": f"f-{i:012d}", "text": (f"finding {i:02d} " + "y" * 390),
        "source": "finding", "status": "open",
        "firstSeenAttempt": 1, "lastSeenAttempt": 1,
        "resolvedAttempt": None, "resolvedBy": None,
    })
json.dump({"schema":"singular.orchestration.findings-ledger.v0","taskId":"TASK-0001","runId":"R",
  "findings": findings, "updatedAt":"now"}, open(sys.argv[1],"w"))
PY
  local out="$rd/out.md"
  # NO SINGULAR_CONTEXT_SECTION_MAX_CHARS override: exercise the 4000 default. The
  # with_fixture re-source already unset any inherited value.
  singular_render_fix_prompt "$out" "$rd/base-prompt.md" "$rd" 2 gate-red /dev/null '["a"]' '[]' \
    || fail "default-cap render must succeed"
  local section
  section="$(awk '/^### Authoritative findings/{f=1;next} /^### Evidence/{f=0} f' "$out")"
  assert_contains "$section" "section truncated" "default-cap: truncation marker present at 4000"
  # The section must be capped near the 4000 default (the marker text adds ~58).
  local len=${#section}
  [[ "$len" -le 4100 ]] || fail "default-cap: section length $len exceeds the 4000 default + marker"
  [[ "$len" -ge 3900 ]] || fail "default-cap: section length $len far below the 4000 cap (did it truncate per-finding instead?)"
  # Sanity: the SAME findings WITHOUT exceeding the cap (only 1 finding) must NOT
  # carry the marker — proving the marker is the default cap firing, not always-on.
  python3 - "$rd/findings-status.json" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.findings-ledger.v0","taskId":"TASK-0001","runId":"R",
  "findings":[{"id":"f-solo","text":"finding 00 "+("y"*390),"source":"finding","status":"open",
               "firstSeenAttempt":1,"lastSeenAttempt":1,"resolvedAttempt":None,"resolvedBy":None}],
  "updatedAt":"now"}, open(sys.argv[1],"w"))
PY
  singular_render_fix_prompt "$out" "$rd/base-prompt.md" "$rd" 2 gate-red /dev/null '["a"]' '[]' \
    || fail "default-cap solo render must succeed"
  section="$(awk '/^### Authoritative findings/{f=1;next} /^### Evidence/{f=0} f' "$out")"
  assert_not_contains "$section" "section truncated" "default-cap: single small finding under 4000 is NOT truncated"
  echo "ok: fix prompt section cap (default 4000)"
}

# (a) Leak-path test for the audit-fallback fold. The existing "no raw audit JSON"
# case used attempt_ctx=/dev/null, so it never exercised the audit-fallback fold.
# Here: empty/absent ledger + failure_class="audit-needs-fix" + a REAL attempt_ctx
# containing audit-verdict JSON -> the legacy tail fold MUST appear in the EVIDENCE
# section, the Authoritative findings section MUST be empty (no open ledger items),
# and the raw JSON MUST NOT leak into the findings block. If the renderer ever folds
# raw JSON into an authoritative section, that is a SOURCE bug (stop + report).
test_fix_prompt_audit_fallback_confinement() {
  with_fixture
  local rd="$FIXTURE_TMP/fixfold"
  mkdir -p "$rd"
  printf 'BASE WORKER PROMPT\n' >"$rd/base-prompt.md"
  # No ledger file at all (absent) AND no gate-check.log: the only context the
  # renderer can fold is the attempt_ctx audit JSON, via the audit-* fallback.
  local ctx="$rd/audit-ctx.json"
  cat >"$ctx" <<'EOF'
{"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-0001","runId":"R",
 "branch":"agent/widget/TASK-0001","verdict":"needs-fix","evidenceReviewed":[],
 "commandsRun":[],"findings":["LEAK-CANARY-finding-text"],
 "requiredFixes":["LEAK-CANARY-fix-text"],"rationale":"raw json that must stay in Evidence only"}
EOF
  local out="$rd/out.md"
  singular_render_fix_prompt "$out" "$rd/base-prompt.md" "$rd" 2 audit-needs-fix "$ctx" '["a"]' '[]' \
    || fail "audit-fallback render must succeed"
  local body; body="$(cat "$out")"

  # Section-scope the two blocks.
  local findings_section evidence_section
  findings_section="$(awk '/^### Authoritative findings/{f=1;next} /^### Evidence/{f=0} f' "$out")"
  evidence_section="$(awk '/^### Evidence/{f=1;next} /^### /{if(f)f=0} f' "$out")"

  # The findings section must be EMPTY (no open ledger items) and must carry the
  # "(no open ledger findings recorded)" placeholder, NOT the raw audit JSON.
  assert_contains "$findings_section" "(no open ledger findings recorded)" "fold: empty findings placeholder"
  assert_not_contains "$findings_section" '"schema":"singular.orchestration.audit-verdict' "fold: raw audit JSON must NOT leak into findings"
  assert_not_contains "$findings_section" "LEAK-CANARY-finding-text" "fold: audit finding text must NOT leak into the authoritative findings block"
  assert_not_contains "$findings_section" "LEAK-CANARY-fix-text" "fold: audit fix text must NOT leak into the authoritative findings block"

  # The legacy tail fold MUST be in the Evidence section (that is where raw audit
  # context is intended to live for an audit-* failure).
  assert_contains "$evidence_section" '"schema":"singular.orchestration.audit-verdict' "fold: raw audit JSON folded into Evidence"
  assert_contains "$evidence_section" "LEAK-CANARY-fix-text" "fold: audit fix text present in Evidence (the fold target)"

  # Confinement (the load-bearing claim): every occurrence of the raw audit schema
  # string in the WHOLE file is inside the Evidence section. The renderer folds the
  # ctx tail twice for an audit-* failure with no open ledger items (once as the
  # class-scoped tail, once via the legacy fallback fold) — both copies live under
  # Evidence, so the file-wide count must equal the Evidence-section count.
  local file_hits ev_hits
  file_hits="$(grep -c '"schema":"singular.orchestration.audit-verdict' "$out" || true)"
  ev_hits="$(printf '%s\n' "$evidence_section" | grep -c '"schema":"singular.orchestration.audit-verdict' || true)"
  [[ "$file_hits" -ge 1 ]] || fail "fold: expected the raw audit JSON to be folded at least once"
  assert_eq "$ev_hits" "$file_hits" "fold: every raw-audit-JSON occurrence is confined to the Evidence section"
  echo "ok: fix prompt audit-fallback confinement"
}

# (c) STRUCTURED=0 -> byte-identical to the legacy fix_hints rendering. We build
# the legacy output exactly as prepare_worker_prompt does when STRUCTURED=0 and
# confirm the structured renderer is NOT what produces it (the structured output
# differs). This guards the env gate + legacy byte path.
test_fix_prompt_legacy_byte_identical() {
  with_fixture
  local rd="$FIXTURE_TMP/fixleg"
  mkdir -p "$rd"
  printf 'BASE WORKER PROMPT\n' >"$rd/base-prompt.md"
  printf 'context line one\ncontext line two\n' >"$rd/attempt-ctx.log"
  local attempt_failure="gate-red"
  local fix_hints
  fix_hints="The previous attempt failed with: $attempt_failure. Address it. Findings:"$'\n'"$(tail -c 3000 "$rd/attempt-ctx.log" 2>/dev/null || true)"
  # Legacy rendering (SINGULAR_FIX_PROMPT_STRUCTURED=0 path of prepare_worker_prompt).
  local legacy_a="$rd/legacy-a.md"
  cp "$rd/base-prompt.md" "$legacy_a"
  { echo ""; echo "---"; echo "## Previous attempt feedback (fix these, stay in scope)"; echo ""; echo "$fix_hints"; } >>"$legacy_a"
  # An independent reconstruction must be byte-identical.
  local legacy_b="$rd/legacy-b.md"
  cp "$rd/base-prompt.md" "$legacy_b"
  printf '\n---\n## Previous attempt feedback (fix these, stay in scope)\n\n%s\n' "$fix_hints" >>"$legacy_b"
  cmp "$legacy_a" "$legacy_b" || fail "legacy fix_hints rendering not byte-stable"
  # The structured renderer must produce a DIFFERENT (structured) artifact, so
  # the env gate genuinely chooses between two distinct shapes.
  printf 'gate fail\n' >"$rd/gate-check.log"
  local structured="$rd/structured.md"
  singular_render_fix_prompt "$structured" "$rd/base-prompt.md" "$rd" 2 gate-red "$rd/attempt-ctx.log" '["a"]' '[]' \
    || fail "structured render must succeed"
  if cmp -s "$legacy_a" "$structured"; then fail "structured output must differ from legacy"; fi
  assert_contains "$(cat "$structured")" "Current scope (authoritative" "legacy-test: structured is structured"
  echo "ok: legacy fix prompt byte path"
}

# --- T-E4: re-audit delta prompt ------------------------------------------------
# (d) n=1 -> byte-identical to the base audit prompt.
test_reaudit_n1_byte_identical() {
  with_fixture
  local rd="$FIXTURE_TMP/ra1"
  mkdir -p "$rd"
  printf 'AUDITOR BASE PROMPT\nschema reference here\n' >"$rd/audit-base.md"
  local out="$rd/auditor-active-prompt.md"
  singular_render_reaudit_prompt "$out" "$rd/audit-base.md" "$rd" 1 "deadbeef" "cafef00d" "$SINGULAR_ROOT" \
    || fail "reaudit n=1 render must succeed"
  cmp "$rd/audit-base.md" "$out" || fail "reaudit n=1 must be byte-identical to base audit prompt"
  echo "ok: reaudit n=1 byte-identical"
}

# (e) n=2 in a real tiny git fixture (two commits) -> stat + diff + verification
# targets + findingsStatus instruction.
test_reaudit_n2_diff() {
  with_fixture
  local rd="$FIXTURE_TMP/ra2"
  mkdir -p "$rd"
  printf 'AUDITOR BASE\n' >"$rd/audit-base.md"
  local wt="$FIXTURE_TMP/ra2-wt"
  mkdir -p "$wt"; git -C "$wt" init -q
  git -C "$wt" -c user.email=t@e.l -c user.name=t commit -q --allow-empty -m seed
  printf 'one\n' >"$wt/f.txt"; git -C "$wt" add .
  git -C "$wt" -c user.email=t@e.l -c user.name=t commit -q -m c1
  local s1; s1="$(git -C "$wt" rev-parse HEAD)"
  printf 'one\ntwo\n' >"$wt/f.txt"; git -C "$wt" add .
  git -C "$wt" -c user.email=t@e.l -c user.name=t commit -q -m c2
  local s2; s2="$(git -C "$wt" rev-parse HEAD)"
  printf '{"auditedHeadSha":"%s"}\n' "$s1" >"$rd/reviewer-capsule.json"
  cat >"$rd/findings-status.json" <<JSON
{"schema":"singular.orchestration.findings-ledger.v0","taskId":"TASK-0001","runId":"R",
 "findings":[
  {"id":"f-o1","text":"open finding to verify","source":"finding","status":"open","firstSeenAttempt":1,"lastSeenAttempt":1},
  {"id":"f-r1","text":"resolved already","source":"finding","status":"resolved","firstSeenAttempt":1,"lastSeenAttempt":1,"resolvedAttempt":1,"resolvedBy":"auditor-status"}
 ],"updatedAt":"now"}
JSON
  local out="$rd/auditor-active-prompt.md"
  singular_render_reaudit_prompt "$out" "$rd/audit-base.md" "$rd" 2 "$s1" "$s2" "$wt" \
    || fail "reaudit n=2 render must succeed"
  local body; body="$(cat "$out")"
  assert_contains "$body" "$s1..$s2" "reaudit: diff range"
  assert_contains "$body" "f.txt" "reaudit: diff stat path"
  assert_contains "$body" "reaudit-diff-attempt-2.patch" "reaudit: bounded diff artifact reference"
  assert_not_contains "$body" "+two" "reaudit: raw diff is not embedded outside evidence budget"
  assert_contains "$(cat "$rd/reaudit-diff-attempt-2.patch")" "+two" \
    "reaudit: raw diff remains available as a separate artifact"
  assert_contains "$body" "Verification targets" "reaudit: verification header"
  assert_contains "$body" "f-o1: open finding to verify" "reaudit: open verification target"
  assert_not_contains "$body" "f-r1: resolved already" "reaudit: resolved not a verification target"
  assert_contains "$body" "(f-o1) [open]" "reaudit: ledger status open"
  assert_contains "$body" "(f-r1) [resolved]" "reaudit: ledger status resolved"
  assert_contains "$body" "\"findingsStatus\"" "reaudit: findingsStatus instruction"
  echo "ok: reaudit n=2 diff"
}

# (f) ancestry broken (rewrite) -> "History was rewritten" text, no diff section.
test_reaudit_history_rewritten() {
  with_fixture
  local rd="$FIXTURE_TMP/ra3"
  mkdir -p "$rd"
  printf 'AUDITOR BASE\n' >"$rd/audit-base.md"
  local wt="$FIXTURE_TMP/ra3-wt"
  mkdir -p "$wt"; git -C "$wt" init -q
  printf 'a\n' >"$wt/f.txt"; git -C "$wt" add .
  git -C "$wt" -c user.email=t@e.l -c user.name=t commit -q -m c1
  local s1; s1="$(git -C "$wt" rev-parse HEAD)"
  printf 'b\n' >"$wt/f.txt"; git -C "$wt" add .
  git -C "$wt" -c user.email=t@e.l -c user.name=t commit -q -m c2
  local s2; s2="$(git -C "$wt" rev-parse HEAD)"
  printf '{"auditedHeadSha":"%s"}\n' "$s2" >"$rd/reviewer-capsule.json"
  printf '{"findings":[]}\n' >"$rd/findings-status.json"
  # prior_head=s2 is NOT an ancestor of new_head=s1 -> rewrite path.
  local out="$rd/auditor-active-prompt.md"
  singular_render_reaudit_prompt "$out" "$rd/audit-base.md" "$rd" 2 "$s2" "$s1" "$wt" \
    || fail "reaudit rewrite render must succeed"
  local body; body="$(cat "$out")"
  assert_contains "$body" "History was rewritten" "reaudit: rewrite notice"
  assert_not_contains "$body" "Fix diff since your last audit" "reaudit: no diff section on rewrite"
  echo "ok: reaudit history rewritten"
}

# (g) schema: validate structurally via the engine's own validation path
# (set/required checks, same as accept-existing-packet.sh) — old verdict and a
# new verdict-with-findingsStatus both pass; the schema file stays valid JSON
# with the new property and an untouched required[].
test_audit_schema_findings_status() {
  with_fixture
  local schema="$ENGINE_HOME/schemas/audit-verdict.v0.schema.json"
  assert_file "$schema" "schema file"
  python3 - "$schema" <<'PY' || fail "schema structural validation failed"
import json, sys
schema = json.load(open(sys.argv[1]))
# Schema is valid JSON with the new property, additive only.
assert "findingsStatus" in schema["properties"], "findingsStatus property missing"
fs = schema["properties"]["findingsStatus"]
assert fs["type"] == "object", "findingsStatus must be object"
assert fs["additionalProperties"]["enum"] == ["resolved", "still-open"], "wrong enum"
# required[] untouched (findingsStatus NOT required).
assert "findingsStatus" not in schema["required"], "findingsStatus must stay optional"
assert schema["properties"]["schema"]["const"] == "singular.orchestration.audit-verdict.v0"
# Replicate the engine's set/required validation (accept-existing-packet.sh).
def validate(verdict):
    missing = [k for k in schema["required"] if k not in verdict]
    extra = sorted(set(verdict) - set(schema["properties"]))
    return missing, extra
base = {
    "schema": "singular.orchestration.audit-verdict.v0", "taskId": "TASK-0001",
    "runId": "R", "branch": "b", "verdict": "needs-fix",
    "evidenceReviewed": [], "commandsRun": [], "findings": ["x"],
    "requiredFixes": [], "rationale": "r",
}
m, e = validate(base)
assert not m and not e, f"old verdict should validate: missing={m} extra={e}"
new = dict(base); new["findingsStatus"] = {"f-x": "resolved", "f-y": "still-open"}
m, e = validate(new)
assert not m and not e, f"new verdict-with-findingsStatus should validate: missing={m} extra={e}"
print("schema-ok")
PY
  echo "ok: audit schema findingsStatus additive"
}

# (h) runner keying: the auditor model/effort selection honors the NEW per-attempt
# prompt name auditor-active-prompt.md (case patterns widened to auditor-*.md).
# The runners aren't source-safe (they parse argv on load), so we extract the
# pure selector functions and exercise them in isolation.
test_lease_update_owned() {
  # amend-scope widens the in-memory owned set; the lease must be rewritten so the
  # parallel-L1 scope-overlap guard (which reads lease.ownedFiles) sees the new scope.
  with_fixture
  singular_lease_write TASK-0001 agent/widget/TASK-0001 widget l2-developer \
    "internal/widget/parser.go" running RUN-LEASE-1 "" "" "" \
    '["internal/widget/parser.go"]' '[]'
  assert_eq "$(singular_lease_field TASK-0001 ownedFiles)" '["internal/widget/parser.go"]' \
    "initial lease ownedFiles"
  singular_lease_update_owned TASK-0001 '["internal/widget/parser.go","internal/widget/extra.go"]' \
    || fail "lease_update_owned must succeed"
  local owned
  owned="$(singular_lease_field TASK-0001 ownedFiles)"
  assert_contains "$owned" "internal/widget/extra.go" "lease ownedFiles widened with extra.go"
  assert_contains "$owned" "internal/widget/parser.go" "lease ownedFiles keeps parser.go"
  # Bad input is a no-op-with-error, never a crash that aborts the drive.
  local rc=0
  singular_lease_update_owned TASK-0001 'not-json' 2>/dev/null || rc=$?
  assert_eq "$rc" "1" "lease_update_owned rejects non-array JSON (rc 1, no crash)"
  echo "ok: singular_lease_update_owned persists the widened amend-scope set"
}

test_runner_auditor_prompt_keying() {
  with_fixture
  # Static guarantee: both runners match the active prompt name.
  grep -q 'auditor-\*\.md)' "$SCRIPT_DIR/codex-run.sh" || fail "codex-run.sh effort pattern not widened"
  local claude_hits
  claude_hits="$(grep -c 'auditor-\*\.md)' "$SCRIPT_DIR/claude-run.sh" || true)"
  assert_eq "$claude_hits" "2" "claude-run.sh must widen BOTH model+effort patterns"

  # Functional: extract claude-run.sh's selector functions and confirm the auditor
  # env vars are honored for prompt_file=auditor-active-prompt.md.
  local fns="$FIXTURE_TMP/claude-selectors.sh"
  awk '/^singular_claude_model\(\) \{/{m=1} m{print} /^\}/{if(m){m=0}}' "$SCRIPT_DIR/claude-run.sh" >"$fns"
  awk '/^singular_claude_effort\(\) \{/{e=1} e{print} /^\}/{if(e){e=0}}' "$SCRIPT_DIR/claude-run.sh" >>"$fns"
  local model effort
  model="$(SINGULAR_CLAUDE_AUDITOR_MODEL=audmodel bash -c '
    source "'"$fns"'"
    singular_claude_model readonly /x/auditor-active-prompt.md')" || fail "model selector failed"
  effort="$(SINGULAR_CLAUDE_AUDITOR_EFFORT=audeffort bash -c '
    source "'"$fns"'"
    singular_claude_effort readonly /x/auditor-active-prompt.md')" || fail "effort selector failed"
  assert_eq "$model" "audmodel" "auditor-active-prompt.md keys to the auditor model"
  assert_eq "$effort" "audeffort" "auditor-active-prompt.md keys to the auditor effort"

  # Codex prompt-name routing is tested through actual runner argv/session
  # output in test-codex-role-models.sh, avoiding private-function extraction.
  echo "ok: runner auditor prompt keying"
}

test_preflight_pass_and_failures
test_attempt_archive
test_finding_id_normalization
test_findings_ledger_lifecycle
test_implementer_capsule_scope_and_caps
test_reviewer_capsule_tolerates_junk
test_dry_run_byte_identical_to_head
test_drive_preflight_blocks_bad_task
test_fix_prompt_structured
test_fix_prompt_section_cap
test_fix_prompt_section_cap_default
test_fix_prompt_audit_fallback_confinement
test_fix_prompt_legacy_byte_identical
test_reaudit_n1_byte_identical
test_reaudit_n2_diff
test_reaudit_history_rewritten
test_audit_schema_findings_status
test_lease_update_owned
test_runner_auditor_prompt_keying

echo "continuity-core tests passed"
