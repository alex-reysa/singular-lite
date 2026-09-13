#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-review-policy.sh requires bash >= 4" >&2
  exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${SINGULAR_TEST_PYTHON:-$(command -v python3 2>/dev/null || true)}"
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || { echo "missing python3" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-review-policy.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/evidence"
STATE="$tmp/state"
CONFIG="$tmp/singular.config.json"
printf '%s\n' '{"schemaVersion":"v2","targetBranch":"target"}' >"$CONFIG"

rp() {
  "$PYTHON_BIN" "$ENGINE_HOME/engine/review_policy.py" \
    --config "$CONFIG" --state-dir "$STATE" "$@"
}

write_verdict() {
  local path="$1" verdict="${2:-needs-fix}"
  shift 2
  CLASSIFIED_JSON="${CLASSIFIED_JSON:-[]}" \
  FINDINGS_JSON="${FINDINGS_JSON:-[]}" \
  FIXES_JSON="${FIXES_JSON:-[]}" \
  "$PYTHON_BIN" - "$path" "$verdict" <<'PY'
import json, os, sys
path, verdict = sys.argv[1:3]
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": "RUN-1",
    "branch": "agent/x/TASK-0001",
    "verdict": verdict,
    "evidenceReviewed": ["red.log"],
    "verificationResults": [{
        "status": "passed",
        "command": "true",
        "evidenceRefs": ["red.log"],
        "rationale": "host passed",
    }],
    "commandsRun": ["true"],
    "findings": json.loads(os.environ.get("FINDINGS_JSON") or "[]"),
    "requiredFixes": json.loads(os.environ.get("FIXES_JSON") or "[]"),
    "rationale": "fixture",
}
classified = json.loads(os.environ.get("CLASSIFIED_JSON") or "[]")
if classified:
    record["classifiedFindings"] = classified
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
PY
}

# --- defaults / env precedence / invalid env ---------------------------------
out="$(rp effective)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["maxReviewRounds"], d["requireClassification"], ",".join(d["blockingSeverities"]), d["sources"]["maxReviewRounds"])' <<<"$out")" \
  "2 True P0,P1 default" "defaults"

printf '%s\n' '{"schemaVersion":"v2","reviewPolicy":{"version":1,"maxReviewRounds":5,"blockingSeverities":["P0"],"requireClassification":false}}' >"$CONFIG"
out="$(rp effective)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["maxReviewRounds"], d["requireClassification"], ",".join(d["blockingSeverities"]), d["sources"]["maxReviewRounds"])' <<<"$out")" \
  "5 False P0 config" "config JSON"

out="$(SINGULAR_REVIEW_MAX_ROUNDS=4 SINGULAR_REVIEW_BLOCKING_SEVERITIES=P0,P1,P2 SINGULAR_REVIEW_REQUIRE_CLASSIFICATION=1 rp effective)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["maxReviewRounds"], d["requireClassification"], ",".join(d["blockingSeverities"]), d["sources"]["maxReviewRounds"], d["sources"]["requireClassification"])' <<<"$out")" \
  "4 True P0,P1,P2 env env" "env overrides JSON"

rc=0
SINGULAR_REVIEW_MAX_ROUNDS=0 rp effective >"$tmp/bad-max.out" 2>"$tmp/bad-max.err" || rc=$?
assert_eq "$rc" "2" "invalid max rounds exit 2"
assert_contains "$(cat "$tmp/bad-max.err")" "SINGULAR_REVIEW_MAX_ROUNDS" "invalid max rounds names the env"

rc=0
SINGULAR_REVIEW_BLOCKING_SEVERITIES=P9 rp effective >/dev/null 2>"$tmp/bad-sev.err" || rc=$?
assert_eq "$rc" "2" "invalid severity exit 2"

rc=0
SINGULAR_REVIEW_REQUIRE_CLASSIFICATION=yes rp effective >/dev/null 2>"$tmp/bad-flag.err" || rc=$?
assert_eq "$rc" "2" "invalid requireClassification exit 2"

rc=0
SINGULAR_REVIEW_MAX_ROUNDS= rp effective >/dev/null 2>"$tmp/empty-env.err" || rc=$?
assert_eq "$rc" "2" "empty env is a hard error"

printf '%s\n' '{"schemaVersion":"v2","targetBranch":"target"}' >"$CONFIG"

# --- classify via record (accepted unchanged) --------------------------------
write_verdict "$tmp/accepted.json" accepted
out="$(rp record --logical-change TASK-0001 --task TASK-0001 --run RUN-1 \
  --attempt 1 --verdict "$tmp/accepted.json" --head deadbeef --lane native)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["originalVerdict"], d["effectiveVerdict"], d["applied"], d["unclassifiedCount"])' <<<"$out")" \
  "accepted accepted False 0" "accepted unchanged"

# Reset ledger for the remaining classify/budget cases.
rm -rf "$STATE/review-policy"
mkdir -p "$STATE"

# P2-only needs-fix → accepted with backlog
FINDINGS_JSON='["style leftover","dead comment"]' \
CLASSIFIED_JSON='[{"id":"f-style","severity":"P2","summary":"style leftover"},{"id":"f-dead","severity":"P2","summary":"dead comment"}]' \
  write_verdict "$tmp/p2.json" needs-fix
out="$(rp record --logical-change LC-P2 --task TASK-0001 --run RUN-p2 \
  --attempt 1 --verdict "$tmp/p2.json" --head abc --lane native)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["effectiveVerdict"], d["applied"], len(d["backlog"]), len(d["blocking"]))' <<<"$out")" \
  "accepted True 2 0" "P2-only accepted with backlog"
assert_eq "$(grep -c . "$STATE/review-policy/backlog.ndjson")" "2" "P2 backlog lines"

# P1 with trigger/impact/requirement → needs-fix
FINDINGS_JSON='["broken contract"]' \
CLASSIFIED_JSON='[{"id":"f-p1","severity":"P1","summary":"broken contract","trigger":"gate red","impact":"wrong result","requirement":"must pass gate"}]' \
  write_verdict "$tmp/p1.json" needs-fix
out="$(rp record --logical-change LC-P1 --task TASK-0001 --run RUN-p1 \
  --attempt 1 --verdict "$tmp/p1.json" --head def --lane native)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["effectiveVerdict"], ",".join(d["blocking"]), len(d["downgraded"]))' <<<"$out")" \
  "needs-fix f-p1 0" "supported P1 stays blocking"

# P1 missing trigger → downgraded to P2 → accepted
FINDINGS_JSON='["unsupported blocker"]' \
CLASSIFIED_JSON='[{"id":"f-weak","severity":"P1","summary":"unsupported blocker","impact":"maybe","requirement":"fix it"}]' \
  write_verdict "$tmp/p1-weak.json" needs-fix
out="$(rp record --logical-change LC-WEAK --task TASK-0001 --run RUN-weak \
  --attempt 1 --verdict "$tmp/p1-weak.json" --head ghi --lane native)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["effectiveVerdict"], d["applied"], ",".join(d["downgraded"]), d["reason"])' <<<"$out")" \
  "accepted True f-weak unsupported-blocking-claim" "unsupported P1 downgraded"

# classification missing → needs-fix with unclassifiedCount
FINDINGS_JSON='["raw finding A","raw finding B"]' \
FIXES_JSON='["raw finding A"]' \
CLASSIFIED_JSON='[]' \
  write_verdict "$tmp/unclass.json" needs-fix
out="$(rp record --logical-change LC-MISS --task TASK-0001 --run RUN-miss \
  --attempt 1 --verdict "$tmp/unclass.json" --head jkl --lane native)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["effectiveVerdict"], d["unclassifiedCount"], d["reason"], len(d["blocking"]))' <<<"$out")" \
  "needs-fix 2 classification-missing 2" "classification-missing fail-safe"

# --- check/record budget, grant, persistence ---------------------------------
rm -rf "$STATE/review-policy"
mkdir -p "$STATE"
FINDINGS_JSON='["blocker"]' \
CLASSIFIED_JSON='[{"id":"f-block","severity":"P1","summary":"blocker","trigger":"t","impact":"i","requirement":"r"}]' \
  write_verdict "$tmp/round.json" needs-fix

out="$(SINGULAR_REVIEW_MAX_ROUNDS=2 rp check --logical-change BUDGET --task TASK-0001)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["allowed"], d["used"], d["allowedRounds"])' <<<"$out")" \
  "True 0 2" "first check allowed"

SINGULAR_REVIEW_MAX_ROUNDS=2 rp record --logical-change BUDGET --task TASK-0001 --run RUN-a --attempt 1 \
  --verdict "$tmp/round.json" --head h1 >/dev/null
SINGULAR_REVIEW_MAX_ROUNDS=2 rp record --logical-change BUDGET --task TASK-0001 --run RUN-b --attempt 2 \
  --verdict "$tmp/round.json" --head h2 >/dev/null

rc=0
SINGULAR_REVIEW_MAX_ROUNDS=2 rp check --logical-change BUDGET --task TASK-0001 >"$tmp/check3.json" 2>"$tmp/check3.err" || rc=$?
assert_eq "$rc" "4" "third check exit 4"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["allowed"], d["used"], d["allowedRounds"])' "$tmp/check3.json")" \
  "False 2 2" "third check exhausted payload"

printf 'evidence-bytes\n' >"$tmp/evidence/note.txt"
SINGULAR_REVIEW_MAX_ROUNDS=2 rp grant --logical-change BUDGET --rounds 1 --reason "operator exception" \
  --evidence "$tmp/evidence/note.txt" --authority "operator" >/dev/null
out="$(SINGULAR_REVIEW_MAX_ROUNDS=2 rp check --logical-change BUDGET --task TASK-0001)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["allowed"], d["used"], d["allowedRounds"])' <<<"$out")" \
  "True 2 3" "grant allows another round"

rc=0
SINGULAR_REVIEW_MAX_ROUNDS=2 rp grant --logical-change BUDGET --rounds 1 --reason "again" \
  --evidence "$tmp/evidence/note.txt" --authority "operator" \
  >/dev/null 2>"$tmp/grant2.err" || rc=$?
assert_eq "$rc" "2" "second grant refused"
assert_contains "$(cat "$tmp/grant2.err")" "unconsumed" "second grant names active exception"

# Ledger persists across processes
show="$(rp show --logical-change BUDGET)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); e=d["entry"]; print(len(e["rounds"]), len(e["exceptions"]), e["status"])' <<<"$show")" \
  "2 1 open" "ledger persists"

# --- --apply writes pre-policy and a schema-valid verdict --------------------
FINDINGS_JSON='["style leftover"]' \
CLASSIFIED_JSON='[{"id":"f-style","severity":"P2","summary":"style leftover"}]' \
  write_verdict "$tmp/apply.json" needs-fix
cp "$tmp/apply.json" "$tmp/apply.before.json"
out="$(rp record --logical-change LC-APPLY --task TASK-0001 --run RUN-apply \
  --attempt 1 --verdict "$tmp/apply.json" --head applyhead --apply)"
[[ -f "$tmp/apply.json.pre-policy.json" ]] || fail "--apply did not write .pre-policy.json"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$tmp/apply.json.pre-policy.json")" \
  "needs-fix" "pre-policy keeps original verdict"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["verdict"], d["reviewPolicy"]["effectiveVerdict"], d["reviewPolicy"]["originalVerdict"])' "$tmp/apply.json")" \
  "accepted accepted needs-fix" "applied verdict rewritten"

SINGULAR_ROOT="$tmp" \
SINGULAR_STATE_DIR="$tmp/state" \
SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
SINGULAR_AUDIT_SCHEMA="$ENGINE_HOME/schemas/audit-verdict.v1.schema.json" \
bash -c "source '$ENGINE_HOME/engine/lib.sh'; singular_validate_audit_verdict '$tmp/apply.json' TASK-0001 RUN-1" \
  || fail "applied verdict failed schema validation"

# --- v0 verdicts: effective verdict applied, no reviewPolicy stamp -----------
FINDINGS_JSON='["style leftover"]' \
CLASSIFIED_JSON='[]' \
  write_verdict "$tmp/v0.json" accepted
"$PYTHON_BIN" - "$tmp/v0.json" <<'PY0'
import json, sys
d = json.load(open(sys.argv[1])); d["schema"] = "singular.orchestration.audit-verdict.v0"
d.pop("verificationResults", None)
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY0
out="$(rp record --logical-change LC-V0 --task TASK-0001 --run RUN-v0 \
  --attempt 1 --verdict "$tmp/v0.json" --head v0head --apply)"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["verdict"], "reviewPolicy" in d)' "$tmp/v0.json")" \
  "accepted False" "v0 verdict is not stamped"
[[ ! -f "$tmp/v0.json.pre-policy.json" ]] || fail "unchanged v0 verdict must not write a pre-policy copy"
SINGULAR_ROOT="$tmp" \
SINGULAR_STATE_DIR="$tmp/state" \
SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
SINGULAR_AUDIT_SCHEMA="$ENGINE_HOME/schemas/audit-verdict.v0.schema.json" \
bash -c "source '$ENGINE_HOME/engine/lib.sh'; singular_validate_audit_verdict '$tmp/v0.json' TASK-0001 RUN-1" \
  || fail "applied v0 verdict failed v0 schema validation"

echo "PASS: test-review-policy"
