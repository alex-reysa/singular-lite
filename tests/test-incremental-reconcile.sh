#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"
if [[ "${INCREMENTAL_RECONCILE_PRIVATE_CHILD:-}" != 1 ]]; then
  exec "$PYTHON" - "$0" <<'PY'
import os
import subprocess
import sys

env = {key: value for key, value in os.environ.items() if not key.startswith("SINGULAR_")}
env.update(INCREMENTAL_RECONCILE_PRIVATE_CHILD="1", PYTHONDONTWRITEBYTECODE="1")
raise SystemExit(subprocess.run(["/opt/homebrew/bin/bash", sys.argv[1]], env=env).returncode)
PY
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The engine tree under test. INCREMENTAL_ENGINE_HOME points the whole fixture
# -- the unit section below as well as the real reconcile --actuate /
# integrate.sh section further down -- at another checkout of the engine, which
# is how the pre-implementation baseline is compared against this one on the
# same pinned corpus. Unset (every ordinary run, including the gate) means this
# checkout, byte for byte as before.
engine_source="${INCREMENTAL_ENGINE_HOME:-$ROOT}"

# INCREMENTAL_RECONCILE_SKIP_UNIT=1 runs only the real reconcile --actuate /
# integrate.sh section, so that behavioral evidence can be captured on its own.
if [[ "${INCREMENTAL_RETROSPECTIVE_BASELINE:-0}" != 1 && "${INCREMENTAL_RECONCILE_SKIP_UNIT:-0}" != 1 ]]; then
repo="$tmp/repo"
tasks="$repo/tasks"
packets="$repo/packets"
leases="$repo/state/leases"
audits="$repo/state/audits"
events="$repo/state/events.ndjson"
index="$repo/state/reconcile-index.json"
mkdir -p "$tasks" "$packets/TASK-1108" "$leases" "$audits"
: >"$events"

git -C "$repo" init -q
git -C "$repo" checkout -q -b target
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.local
printf 'base\n' >"$repo/app.txt"
git -C "$repo" add app.txt
git -C "$repo" commit -qm base
git -C "$repo" checkout -q -b worker
printf 'candidate\n' >"$repo/app.txt"
git -C "$repo" commit -qam candidate
candidate_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q target
git -C "$repo" branch -D worker >/dev/null

printf 'Task: TASK-1108\nStatus: ready\nDepends on: []\n' >"$tasks/TASK-1108.md"
printf '{"taskId":"TASK-1108","status":"accepted","headSha":"%s","branch":"worker"}\n' \
  "$candidate_head" >"$packets/TASK-1108/RUN-1.json"
printf '{"taskId":"TASK-1108","verdict":"accepted"}\n' \
  >"$packets/TASK-1108/RUN-1.audit.json"
printf '{"taskId":"TASK-1108","status":"accepted","campaignBinding":"campaign-a"}\n' \
  >"$leases/TASK-1108.json"

# Explicit, declared work limits. The fixture drives them down so bounded event,
# directory-entry, content-byte and validation work is observable rather than
# asserted; no limit is derived from elapsed time.
MAX_EVENTS=64
SWEEP_ENTRIES=4096
SWEEP_DIRS=256
SWEEP_BYTES=$((8 * 1024 * 1024))
HASH_BLOCK=$((1024 * 1024))

plan() {
  "$PYTHON" "$engine_source/engine/reconcile_index.py" plan \
    --index "$index" --tasks "$tasks" --packets "$packets" --leases "$leases" \
    --audits "$audits" --events "$events" --repo "$repo" \
    --max-events "$MAX_EVENTS" --max-sweep-entries "$SWEEP_ENTRIES" \
    --max-sweep-dirs "$SWEEP_DIRS" --max-sweep-bytes "$SWEEP_BYTES" \
    --hash-block-bytes "$HASH_BLOCK" \
    --target-head "$1" --policy "$2" --campaign "$3" --full-scan-every "$4"
}
commit_index() {
  "$PYTHON" "$engine_source/engine/reconcile_index.py" commit --index "$index" >/dev/null
}
status_index() {
  "$PYTHON" "$engine_source/engine/reconcile_index.py" status --index "$index"
}
# J <json> <python-assertions>: assertion bodies read `doc`; failures print it.
J() {
  "$PYTHON" - "$1" "$2" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
try:
    exec(sys.argv[2])
except AssertionError:
    print(json.dumps(doc, indent=2, sort_keys=True), file=sys.stderr)
    raise
PY
}
assert_plan() {
  J "$1" "
assert doc['runCanonical'] is ('$2' == 'yes'), 'runCanonical'
assert doc['metrics']['canonicalRequested'] == $3, 'canonicalRequested'
assert 'expensiveHistoricalValidations' not in doc['metrics'], 'metrics leak'
assert doc['authority'] == 'discovery-only', 'authority'
assert doc['schema'] == 'singular.orchestration.reconcile-index-plan.v1', 'schema'
"
}
emit_event() {
  printf '{"ts":"2026-09-15T00:00:00Z","type":"%s","message":"m","data":{"taskId":"%s","runId":"RUN-X"}}\n' \
    "$1" "$2" >>"$events"
}

# 1. A missing index reconstructs safely: canonical discovery is scheduled, the
# plan grants nothing, and no filtered selection is offered until a baseline
# sweep pass has actually been acknowledged.
first="$(plan head-a gate-a campaign-a 50)"
assert_plan "$first" yes 1
J "$first" "
assert 'missing-index' in doc['reasons'], doc['reasons']
assert doc['dirtyComplete'] is False, 'no filtered selection without a baseline'
assert doc['sweep']['passComplete'] is True, 'small fixture completes one pass'
assert doc['sweep']['pass'] == 1, doc['sweep']
assert not any(k in doc for k in ('eligible', 'accepted', 'acceptedCandidates')), doc
"
commit_index

# 2. The immediately following unchanged cycle is clean: zero dirty work and no
# canonical scheduling. Discovery caches the negative outcome too.
second="$(plan head-a gate-a campaign-a 50)"
assert_plan "$second" no 0
J "$second" "
assert doc['dirtyTasks'] == [], doc['dirtyTasks']
assert doc['dirtyComplete'] is True, 'acknowledged baseline offers selection'
assert doc['receipts']['subprocesses'] >= 1, doc['receipts']
"

# 3. Existing packet.imported events identify the task after publication. A
# bounded cursor consumes them and deduplicates the dirty work they name.
emit_event packet.imported TASK-1108
emit_event packet.imported TASK-1108
emit_event l1.task_accepted TASK-1108
evented="$(plan head-a gate-a campaign-a 50)"
assert_plan "$evented" yes 1
J "$evented" "
assert doc['dirtyTasks'] == ['TASK-1108'], doc['dirtyTasks']
assert doc['events']['read'] == 3, doc['events']
assert doc['events']['backlogBytes'] == 0, doc['events']
assert 'event-dirty' in doc['reasons'], doc['reasons']
"
commit_index
after_events="$(plan head-a gate-a campaign-a 50)"
assert_plan "$after_events" no 0
J "$after_events" "assert doc['events']['read'] == 0, doc['events']"

# 4. The event limit is a real bound: more arrivals than the per-cycle budget
# leave a reported backlog instead of an unbounded pass.
for _ in 1 2 3 4 5 6; do emit_event packet.imported TASK-1108; done
MAX_EVENTS=2
bounded="$(plan head-a gate-a campaign-a 50)"
J "$bounded" "
assert doc['events']['read'] == 2, doc['events']
assert doc['events']['backlogBytes'] > 0, doc['events']
assert doc['dirtyComplete'] is False, 'a backlog must not offer a filtered selection'
"
commit_index
MAX_EVENTS=64
drained="$(plan head-a gate-a campaign-a 50)"
J "$drained" "assert doc['events']['backlogBytes'] == 0, doc['events']"
commit_index

# 5. An unrelated arrival dirties only its own entry. Every historical entry
# must not be forced back through expensive canonical validation.
printf 'Task: TASK-1109\nStatus: ready\nDepends on: []\n' >"$tasks/TASK-1109.md"
unrelated="$(plan head-a gate-a campaign-a 50)"
assert_plan "$unrelated" yes 1
J "$unrelated" "
assert doc['dirtyTasks'] == ['TASK-1109'], doc['dirtyTasks']
assert doc['dirtyComplete'] is True, 'a complete observation may still be selective'
"
commit_index

# 6. Candidate ref, commit and tree availability stay per-candidate dependency
# identity, including through packed refs. Restoring one invalidates one entry.
git -C "$repo" branch worker "$candidate_head"
git -C "$repo" pack-refs --all --prune
restored_ref="$(plan head-a gate-a campaign-a 50)"
assert_plan "$restored_ref" yes 1
J "$restored_ref" "
assert doc['dirtyTasks'] == ['TASK-1108'], doc['dirtyTasks']
assert 'candidate-dependency-changed' in doc['reasons'], doc['reasons']
"
commit_index
candidate_tree="$(git -C "$repo" rev-parse "$candidate_head^{tree}")"
for object_id in "$candidate_head" "$candidate_tree"; do
  object_path="$repo/.git/objects/${object_id:0:2}/${object_id:2}"
  saved_object="$tmp/object-$object_id"
  cp "$object_path" "$saved_object"
  rm "$object_path"
  unavailable="$(plan head-a gate-a campaign-a 50)"
  assert_plan "$unavailable" yes 1
  J "$unavailable" "assert doc['dirtyTasks'] == ['TASK-1108'], doc['dirtyTasks']"
  commit_index
  mkdir -p "$(dirname "$object_path")"
  cp "$saved_object" "$object_path"
  available="$(plan head-a gate-a campaign-a 50)"
  assert_plan "$available" yes 1
  commit_index
done

# 7. A true shared dependency change may invalidate every affected entry, and
# the sweep/event work for that cycle still respects the declared limits.
shared="$(plan head-b gate-a campaign-a 50)"
assert_plan "$shared" yes 1
J "$shared" "
assert set(doc['dirtyTasks']) == {'TASK-1108', 'TASK-1109'}, doc['dirtyTasks']
assert 'shared-dependency-changed' in doc['reasons'], doc['reasons']
assert doc['sweep']['entriesScanned'] <= $SWEEP_ENTRIES, doc['sweep']
assert doc['receipts']['bytesHashed'] <= $SWEEP_BYTES, doc['receipts']
"
commit_index
for args in 'head-b gate-b campaign-a' 'head-b gate-b campaign-b'; do
  changed="$(plan $args 50)"
  assert_plan "$changed" yes 1
  commit_index
done

# 8. Each retained location is swept independently: task contract, packet,
# audit sidecar and lease all invalidate their own entry.
printf '{"taskId":"TASK-1108","verdict":"accepted"}\n' >"$audits/TASK-1108.audit.json"
new_audit="$(plan head-b gate-b campaign-b 50)"
assert_plan "$new_audit" yes 1
commit_index
for field in task packet audit lease; do
  case "$field" in
    task) printf '\nObjective: changed\n' >>"$tasks/TASK-1108.md" ;;
    packet) printf ' ' >>"$packets/TASK-1108/RUN-1.json" ;;
    audit) printf ' ' >>"$audits/TASK-1108.audit.json" ;;
    lease) printf ' ' >>"$leases/TASK-1108.json" ;;
  esac
  changed="$(plan head-b gate-b campaign-b 50)"
  assert_plan "$changed" yes 1
  J "$changed" "assert doc['dirtyTasks'] == ['TASK-1108'], ('$field', doc['dirtyTasks'])"
  commit_index
done

# 9. Content identity, not mtime: a same-size replacement with restored
# timestamps is still discovered by the sweep.
"$PYTHON" - "$tasks/TASK-1108.md" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
before = p.stat()
raw = p.read_bytes()
replacement = raw.replace(b"changed", b"CHANGED")
assert len(replacement) == len(raw)
p.write_bytes(replacement)
os.utime(p, ns=(before.st_atime_ns, before.st_mtime_ns))
PY
silent="$(plan head-b gate-b campaign-b 50)"
assert_plan "$silent" yes 1
J "$silent" "
assert doc['dirtyTasks'] == ['TASK-1108'], doc['dirtyTasks']
assert 'sweep-content-changed' in doc['reasons'], doc['reasons']
"
commit_index

# 10. Deletion behind the cursor and a missing-to-present transition are both
# discovered; neither fabricates eligible work.
rm "$audits/TASK-1108.audit.json"
deleted="$(plan head-b gate-b campaign-b 50)"
assert_plan "$deleted" yes 1
J "$deleted" "
assert doc['dirtyTasks'] == ['TASK-1108'], doc['dirtyTasks']
assert 'sweep-entry-removed' in doc['reasons'], doc['reasons']
"
commit_index
printf '{"taskId":"TASK-1108","verdict":"accepted"}\n' >"$audits/TASK-1108.audit.json"
restored_entry="$(plan head-b gate-b campaign-b 50)"
assert_plan "$restored_entry" yes 1
commit_index

# 11. A fair bounded sweep over a fixed retained population: with a tiny
# directory-entry budget and a continuous arrival on every cycle, the pass makes
# reserved progress and completes inside the reported revisit bound. Continuous
# events must not restart or starve the population's sweep.
for n in $(seq 1 24); do
  printf 'Task: TASK-12%02d\nStatus: ready\nDepends on: []\n' "$n" \
    >"$tasks/TASK-12$(printf '%02d' "$n").md"
done
population_seed="$(plan head-b gate-b campaign-b 500)"
commit_index
SWEEP_ENTRIES=3
bound_start="$(plan head-b gate-b campaign-b 500)"
bound="$(J "$bound_start" "print(doc['sweep']['revisitBoundCycles'])")"
[[ "$bound" -ge 1 ]] || { echo "FAIL: no reported revisit bound" >&2; exit 1; }
commit_index
cycles=0
completed=0
while [[ "$cycles" -lt "$((bound + 4))" ]]; do
  emit_event packet.imported TASK-1108
  cycle_out="$(plan head-b gate-b campaign-b 500)"
  J "$cycle_out" "
assert doc['sweep']['entriesScanned'] <= $SWEEP_ENTRIES, doc['sweep']
assert doc['sweep']['pass'] >= 2, doc['sweep']
"
  cycles=$((cycles + 1))
  if [[ "$(J "$cycle_out" "print('yes' if doc['sweep']['passComplete'] else 'no')")" == yes ]]; then
    completed=1
    commit_index
    break
  fi
  commit_index
done
[[ "$completed" == 1 ]] \
  || { echo "FAIL: continuous arrivals starved the retained sweep ($cycles cycles, bound $bound)" >&2; exit 1; }
[[ "$cycles" -ge 2 ]] \
  || { echo "FAIL: bounded entry budget did not actually bound the sweep" >&2; exit 1; }
SWEEP_ENTRIES=4096

# 12. Bounded content bytes: an artifact larger than the per-cycle byte budget
# is hashed across cycles by block, never in one unbounded pass, and its effect
# on the revisit bound is reported.
"$PYTHON" - "$packets/TASK-1108/RUN-2.json" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(b'{"taskId":"TASK-1108","pad":"' + b'x' * (6 * 1024) + b'"}\n')
PY
SWEEP_BYTES=2048
HASH_BLOCK=1024
oversized_cycles=0
while [[ "$oversized_cycles" -lt 12 ]]; do
  over_out="$(plan head-b gate-b campaign-b 500)"
  J "$over_out" "assert doc['receipts']['bytesHashed'] <= $SWEEP_BYTES, doc['receipts']"
  oversized_cycles=$((oversized_cycles + 1))
  commit_index
  if [[ "$(J "$over_out" "print('yes' if doc['sweep']['passComplete'] else 'no')")" == yes ]]; then
    J "$over_out" "assert doc['sweep']['oversizedDeferred'] >= 0, doc['sweep']"
    break
  fi
done
[[ "$oversized_cycles" -ge 2 ]] \
  || { echo "FAIL: an over-budget artifact was hashed in one unbounded pass" >&2; exit 1; }
SWEEP_BYTES=$((8 * 1024 * 1024))
HASH_BLOCK=$((1024 * 1024))
settle="$(plan head-b gate-b campaign-b 500)"
commit_index
settled="$(plan head-b gate-b campaign-b 500)"
assert_plan "$settled" no 0

# 13. Plan versus acknowledgement: a change arriving between observation and
# acknowledgement is not swallowed by the commit and remains discoverable.
observed="$(plan head-b gate-b campaign-b 500)"
assert_plan "$observed" no 0
printf '\nObjective: raced\n' >>"$tasks/TASK-1108.md"
commit_index
raced="$(plan head-b gate-b campaign-b 500)"
assert_plan "$raced" yes 1
J "$raced" "assert 'TASK-1108' in doc['dirtyTasks'], doc['dirtyTasks']"
commit_index

# 14. Interruption before acknowledgement keeps the work discoverable: repeated
# unacknowledged plans keep scheduling the canonical pass.
printf '\nObjective: unacked\n' >>"$tasks/TASK-1108.md"
unacked_one="$(plan head-b gate-b campaign-b 500)"
assert_plan "$unacked_one" yes 1
unacked_two="$(plan head-b gate-b campaign-b 500)"
assert_plan "$unacked_two" yes 1
commit_index
acked="$(plan head-b gate-b campaign-b 500)"
assert_plan "$acked" no 0

# 15. Truncated, rotated and duplicated event streams are cursor discontinuities
# that fail safe to canonical discovery rather than hiding eligible work.
: >"$events"
truncated="$(plan head-b gate-b campaign-b 500)"
assert_plan "$truncated" yes 1
J "$truncated" "
assert doc['events']['discontinuity'] is True, doc['events']
assert 'event-cursor-discontinuity' in doc['reasons'], doc['reasons']
assert doc['dirtyComplete'] is False, 'a discontinuity must not offer a filtered selection'
"
commit_index
emit_event packet.imported TASK-1109
rotated="$(plan head-b gate-b campaign-b 500)"
assert_plan "$rotated" yes 1
commit_index
mv "$events" "$events.1"
: >"$events"
emit_event packet.imported TASK-1109
rotation="$(plan head-b gate-b campaign-b 500)"
assert_plan "$rotation" yes 1
J "$rotation" "assert doc['events']['discontinuity'] is True, doc['events']"
commit_index

# 16. Loss, corruption and forged acceptance in the index all fail safe to
# canonical discovery. A forged entry never becomes eligible or accepted work.
rm "$index"
lost="$(plan head-b gate-b campaign-b 500)"
assert_plan "$lost" yes 1
J "$lost" "assert 'missing-index' in doc['reasons'], doc['reasons']"
commit_index
printf '{broken\n' >"$index"
corrupt="$(plan head-b gate-b campaign-b 500)"
assert_plan "$corrupt" yes 1
J "$corrupt" "
assert 'corrupt-index' in doc['reasons'], doc['reasons']
assert doc['dirtyComplete'] is False, doc
"
commit_index
"$PYTHON" - "$index" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["eligible"] = ["TASK-9999"]
doc["acceptedCandidates"] = [{"taskId": "TASK-9999", "verdict": "accepted"}]
path.write_text(json.dumps(doc), encoding="utf-8")
PY
forged="$(plan head-b gate-b campaign-b 500)"
assert_plan "$forged" yes 1
J "$forged" "
assert 'forged-index' in doc['reasons'], doc['reasons']
assert 'TASK-9999' not in doc['dirtyTasks'], doc['dirtyTasks']
assert doc['dirtyComplete'] is False, doc
assert 'eligible' not in doc and 'acceptedCandidates' not in doc, doc
"
commit_index
recovered="$(plan head-b gate-b campaign-b 500)"
assert_plan "$recovered" no 0

# A retained index written by the superseded discovery schema is a cold start,
# not damage: it rebuilds from retained authority and offers no selection.
"$PYTHON" - "$index" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schema": "singular.orchestration.reconcile-index.v1",
    "cycle": 4, "lastFullCycle": 4, "quick": {}, "content": {}, "dependencies": {},
}), encoding="utf-8")
PY
outdated_status="$(status_index)"
J "$outdated_status" "
assert doc['present'] is True, doc
assert doc['healthy'] is False, doc
assert doc['reason'] == 'outdated-index', doc
"
outdated="$(plan head-b gate-b campaign-b 500)"
assert_plan "$outdated" yes 1
J "$outdated" "
assert 'outdated-index' in doc['reasons'], doc['reasons']
assert doc['dirtyComplete'] is False, doc
"
commit_index
upgraded="$(plan head-b gate-b campaign-b 500)"
assert_plan "$upgraded" no 0

# 17. Unchanged diagnostics are deduplicated by reason and dependency identity;
# a changed or resolved condition is reported when it is observed.
printf '\nObjective: diag\n' >>"$tasks/TASK-1109.md"
diag_one="$(plan head-b gate-b campaign-b 500)"
J "$diag_one" "
assert any(d['state'] == 'new' for d in doc['diagnostics']), doc['diagnostics']
"
diag_two="$(plan head-b gate-b campaign-b 500)"
J "$diag_two" "
assert doc['suppressedDiagnostics'] >= 1, doc
assert all(d['state'] != 'new' for d in doc['diagnostics']), doc['diagnostics']
"
commit_index
diag_resolved="$(plan head-b gate-b campaign-b 500)"
J "$diag_resolved" "
assert any(d['state'] == 'resolved' for d in doc['diagnostics']), doc['diagnostics']
"
commit_index

# 18. The retained periodic canonical rediscovery is preserved: it schedules a
# canonical pass on an unchanged corpus and withdraws the filtered selection.
periodic="$(plan head-b gate-b campaign-b 1)"
assert_plan "$periodic" yes 1
J "$periodic" "
assert 'periodic-canonical-rediscovery' in doc['reasons'], doc['reasons']
assert doc['dirtyComplete'] is False, doc
assert doc['scan'] == 'full', doc
"
commit_index

# 19. Status is a non-authoritative health projection over retained index state.
status_out="$(status_index)"
J "$status_out" "
assert doc['schema'] == 'singular.orchestration.reconcile-index-status.v1', doc
assert doc['authority'] == 'discovery-only', doc
assert doc['healthy'] is True, doc
assert doc['entries'] > 0, doc
assert doc['eventBacklogBytes'] == 0, doc
assert isinstance(doc['sweep']['pass'], int), doc
assert 'remainingEntries' in doc['sweep'], doc
"
fi

# Exercise the real reconcile --actuate -> canonical integrate.sh path. A thin
# engine facade wraps only the integrator so the test can count actual calls;
# the wrapper always execs the production integrator. Runner and gate fixtures
# are local and never invoke a provider.
actual_repo="$tmp/actual-repo"
actual_orch="$actual_repo/docs/orchestration"
actual_state="$actual_repo/.singular-state"
fixture_engine="$tmp/fixture-engine"
canonical_count="$tmp/canonical-count"
validation_count="$tmp/validation-count"
dispatch_count="$tmp/dispatch-count"
publication_count="$tmp/publication-count"
integration_receipt="$tmp/integration-receipt.ndjson"
reconcile_receipt="$tmp/reconcile-receipt.json"
mkdir -p "$actual_orch/tasks" "$actual_orch/packets/imported/TASK-2201" \
  "$actual_orch/gates" "$actual_state/runs/RUN-INCREMENTAL" "$fixture_engine"
cp -R "$engine_source/schemas" "$actual_repo/"
cp -R "$engine_source/engine/." "$fixture_engine/"
cat >"$fixture_engine/integrate.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf 'canonical\n' >>"$CANONICAL_COUNT_FILE"
wrapper_output="$(mktemp)"
trap 'rm -f "$wrapper_output"' EXIT
wrapper_rc=0
"$REAL_ENGINE_HOME/engine/integrate.sh" "$@" >"$wrapper_output" 2>&1 || wrapper_rc=$?
cat "$wrapper_output"
grep '^INTEGRATED ' "$wrapper_output" >>"$PUBLICATION_COUNT_FILE" 2>/dev/null || true
exit "$wrapper_rc"
SH
chmod +x "$fixture_engine/integrate.sh"

git -C "$actual_repo" init -q
git -C "$actual_repo" checkout -q -b target
git -C "$actual_repo" config user.name test
git -C "$actual_repo" config user.email test@example.local
cat >"$actual_repo/singular.config.json" <<'JSON'
{
  "schemaVersion": "v2",
  "targetBranch": "target",
  "gateCommand": "bash fixture-gate.sh",
  "bootstrap": {"required": false, "commands": []}
}
JSON
: >"$actual_repo/singular.config.sh"
: >"$actual_state/config.local.sh"
cat >"$actual_repo/fixture-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'validated\n' >>"$VALIDATION_COUNT_FILE"
[[ "$(cat app.txt)" == "candidate" ]]
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
cat >"$tmp/fixture-driver.sh" <<'SH'
#!/usr/bin/env bash
printf 'dispatched\n' >>"$DISPATCH_COUNT_FILE"
exit 0
SH
chmod +x "$actual_repo/fixture-gate.sh" "$tmp/fixture-driver.sh"
printf 'base\n' >"$actual_repo/app.txt"
printf '%s\n' '.singular-state/' '.worktrees/' '.singular-cache/' '.singular-evidence/' \
  >"$actual_repo/.gitignore"
cat >"$actual_orch/tasks/TASK-2201.md" <<'EOF'
# TASK-2201: Incremental canonical fixture

Status: accepted
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-2201-incremental`
Test policy: `strict_test_first`
Gate command: `bash fixture-gate.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise actual indexed canonical integration.

## Scope

Owned files:

- `app.txt`

## Acceptance Criteria

- The exact candidate integrates once.
EOF
git -C "$actual_repo" add .
git -C "$actual_repo" commit -qm baseline
git -C "$actual_repo" checkout -q -b agent/core/TASK-2201-incremental
printf 'candidate\n' >"$actual_repo/app.txt"
git -C "$actual_repo" commit -qam candidate
actual_head="$(git -C "$actual_repo" rev-parse HEAD)"
actual_tree="$(git -C "$actual_repo" rev-parse 'HEAD^{tree}')"

verification_run="$actual_state/runs/RUN-INCREMENTAL"
cp "$actual_orch/tasks/TASK-2201.md" "$verification_run/verification-task-contract-1.md"
printf '%s\n' '{"campaign":"legacy","policy":"legacy"}' \
  >"$verification_run/verification-policy-1.json"
"$PYTHON" "$engine_source/engine/gate-report.py" create-verification-request \
  --output "$verification_run/verification-request-1.json" \
  --task-id TASK-2201 --run-id RUN-INCREMENTAL --attempt 1 \
  --head-sha "$actual_head" --tree-sha "$actual_tree" --campaign legacy \
  --task-contract "$verification_run/verification-task-contract-1.md" \
  --policy-contract "$verification_run/verification-policy-1.json" \
  --suite-id task-contract-gate >/dev/null
(cd "$actual_repo" && env \
  PATH="/opt/homebrew/bin:$PATH" \
  VALIDATION_COUNT_FILE="$validation_count" \
  SINGULAR_ROOT="$actual_repo" SINGULAR_ORCH_DIR="$actual_orch" \
  SINGULAR_TASKS_DIR="$actual_orch/tasks" SINGULAR_STATE_DIR="$actual_state" \
  SINGULAR_RUNS_DIR="$actual_state/runs" SINGULAR_TARGET_BRANCH=target \
  SINGULAR_ENGINE_HOME="$engine_source" SINGULAR_DEFAULT_GATE_CMD='bash fixture-gate.sh' \
  SINGULAR_JSON_CONFIG_FILE="$actual_repo/singular.config.json" \
  SINGULAR_CONFIG_FILE="$actual_repo/singular.config.sh" \
  SINGULAR_LOCAL_CONFIG_FILE="$actual_state/config.local.sh" \
  /opt/homebrew/bin/bash "$engine_source/engine/gate-check.sh" RUN-INCREMENTAL \
    --task-id TASK-2201 \
    --verification-request "$verification_run/verification-request-1.json" \
    --task-contract "$verification_run/verification-task-contract-1.md" \
    --policy-contract "$verification_run/verification-policy-1.json" \
    --attempt 1) >/dev/null
mv "$verification_run/gate-report.json" "$verification_run/audit-verification.json"
: >"$validation_count"

git -C "$actual_repo" checkout -q target
cat >"$actual_orch/packets/imported/TASK-2201/RUN-INCREMENTAL.json" <<JSON
{
  "schema":"singular.orchestration.state-packet.v0",
  "packetId":"RUN-INCREMENTAL",
  "runId":"RUN-INCREMENTAL",
  "taskId":"TASK-2201",
  "area":"core",
  "role":"l2-developer",
  "status":"accepted",
  "baseRef":"target",
  "branch":"agent/core/TASK-2201-incremental",
  "headSha":"$actual_head",
  "workspace":"$actual_repo",
  "ownedFiles":["app.txt"],
  "changedFiles":["app.txt"],
  "commands":[{"cmd":"bash fixture-gate.sh","exitCode":0}],
  "tests":[{"name":"incremental","phase":"regression","status":"passed"}],
  "evidence":[{"kind":"audit-verification","ref":"runs/RUN-INCREMENTAL/audit-verification.json"}],
  "blockers":[],
  "nextAction":"integrate",
  "createdAt":"2026-09-12T00:00:00Z"
}
JSON
cat >"$actual_orch/packets/imported/TASK-2201/RUN-INCREMENTAL.audit.json" <<JSON
{
  "schema":"singular.orchestration.audit-verdict.v1",
  "taskId":"TASK-2201",
  "runId":"RUN-INCREMENTAL",
  "branch":"agent/core/TASK-2201-incremental",
  "verdict":"accepted",
  "evidenceReviewed":["audit-verification.json","reviewed-head-sha:$actual_head"],
  "verificationResults":[{"status":"passed","command":"bash fixture-gate.sh","exitCode":0,"evidenceRefs":["audit-verification.json"],"rationale":"local host-bound fixture"}],
  "commandsRun":[],
  "findings":[],
  "requiredFixes":[],
  "rationale":"fixture accepted"
}
JSON
mkdir -p "$actual_orch/packets/imported/TASK-2202" \
  "$actual_orch/packets/imported/TASK-2203"
# Malformed candidate: unparseable packet bytes.
printf '{broken\n' >"$actual_orch/packets/imported/TASK-2202/RUN-MALFORMED.json"
# Nonterminal candidate: a well-formed packet that was never accepted.
cat >"$actual_orch/packets/imported/TASK-2203/RUN-NONTERMINAL.json" <<JSON
{
  "schema":"singular.orchestration.state-packet.v0",
  "packetId":"RUN-NONTERMINAL",
  "runId":"RUN-NONTERMINAL",
  "taskId":"TASK-2203",
  "area":"core",
  "role":"l2-developer",
  "status":"needs-review",
  "baseRef":"target",
  "branch":"agent/core/TASK-2203-nonterminal",
  "headSha":"$actual_head",
  "workspace":"$actual_repo",
  "ownedFiles":["app.txt"],
  "changedFiles":["app.txt"],
  "commands":[],
  "tests":[],
  "evidence":[],
  "blockers":[],
  "nextAction":"await review",
  "createdAt":"2026-09-12T00:00:00Z"
}
JSON
for pinned in TASK-2202 TASK-2203; do
  cat >"$actual_orch/tasks/$pinned.md" <<EOF
# $pinned: Pinned discovery corpus member

Status: ready
Area: core
Target branch: \`target\`
Worker branch: \`agent/core/$pinned-pinned\`
Test policy: \`strict_test_first\`
Gate command: \`bash fixture-gate.sh\`
Dispatch mode: canonical
Depends on: []

## Objective

Remain a pinned non-eligible corpus member for discovery comparison.

## Scope

Owned files:

- \`app.txt\`

## Acceptance Criteria

- Never becomes eligible.
EOF
done
git -C "$actual_repo" add docs/orchestration
git -C "$actual_repo" commit -qm packet
git -C "$actual_repo" branch -D agent/core/TASK-2201-incremental >/dev/null

count_lines() {
  if [[ -f "$1" ]]; then wc -l <"$1" | tr -d ' '; else printf '0'; fi
}
# Actual instrumented expensive boundaries inside the production integrator,
# not canonical invocations or final gate calls alone.
count_kind() {
  local n=0
  if [[ -f "$integration_receipt" ]]; then
    n="$(grep -c "\"kind\":\"$1\"" "$integration_receipt" 2>/dev/null || true)"
  fi
  printf '%s' "${n:-0}"
}
run_actual() {
  env \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/homebrew/bin:$PATH" \
    REAL_ENGINE_HOME="$engine_source" CANONICAL_COUNT_FILE="$canonical_count" \
    VALIDATION_COUNT_FILE="$validation_count" DISPATCH_COUNT_FILE="$dispatch_count" \
    PUBLICATION_COUNT_FILE="$publication_count" \
    SINGULAR_INTEGRATION_RECEIPT_FILE="$integration_receipt" \
    SINGULAR_RECONCILE_RECEIPT_FILE="$reconcile_receipt" \
    SINGULAR_ROOT="$actual_repo" SINGULAR_ORCH_DIR="$actual_orch" \
    SINGULAR_TASKS_DIR="$actual_orch/tasks" SINGULAR_STATE_DIR="$actual_state" \
    SINGULAR_RUNS_DIR="$actual_state/runs" SINGULAR_LEASES_DIR="$actual_state/leases" \
    SINGULAR_WORKTREES_DIR="$actual_repo/.worktrees" \
    SINGULAR_ENGINE_HOME="$engine_source" SINGULAR_TARGET_BRANCH=target \
    SINGULAR_DEFAULT_GATE_CMD='bash fixture-gate.sh' \
    SINGULAR_JSON_CONFIG_FILE="$actual_repo/singular.config.json" \
    SINGULAR_CONFIG_FILE="$actual_repo/singular.config.sh" \
    SINGULAR_LOCAL_CONFIG_FILE="$actual_state/config.local.sh" \
    SINGULAR_RECONCILE_INDEX_FILE="$actual_state/reconcile-index.json" \
    SINGULAR_RECONCILE_FULL_SCAN_EVERY=50 \
    SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_GENERATE=0 SINGULAR_PUSH=0 \
    SINGULAR_MAX_DISPATCH=0 SINGULAR_DETACHED_DISPATCH=0 \
    SINGULAR_L1_DRIVER="$tmp/fixture-driver.sh" \
    SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC=999999 \
    "$@" /opt/homebrew/bin/bash "$fixture_engine/reconcile.sh" --actuate
}

actual_first="$(run_actual 2>&1)"
if [[ "${INCREMENTAL_RETROSPECTIVE_BASELINE:-0}" == 1 ]]; then
  [[ "$(count_lines "$canonical_count")" == 1 ]] \
    || { echo "$actual_first" >&2; exit 1; }
  # The uncorrected source acknowledges before its control-state commit. Run a
  # second still-missing cycle to stabilize that target identity, then restore
  # only the packed ref. The following public --actuate call must rediscover it.
  #
  # How many canonical passes that stabilizing cycle costs is a property of the
  # uncorrected source, not of this fixture: a source that already withholds the
  # canonical pass on an unchanged corpus spends none. Record the observed count
  # and keep going, so the baseline always reaches the restoration probe below
  # instead of stopping at an incidental difference in stabilization cost.
  baseline_stabilize="$(run_actual 2>&1)"
  baseline_scans="$(count_lines "$canonical_count")"
  echo "# retrospective baseline: canonical passes after stabilization: $baseline_scans"
  [[ "$baseline_scans" == 1 || "$baseline_scans" == 2 ]] \
    || { echo "$baseline_stabilize" >&2; exit 1; }
  git -C "$actual_repo" branch agent/core/TASK-2201-incremental "$actual_head"
  git -C "$actual_repo" pack-refs --all --prune
  baseline_restored="$(run_actual 2>&1)"
  if [[ "$(count_lines "$canonical_count")" == "$baseline_scans" \
      && "$(count_lines "$validation_count")" == 0 \
      && "$baseline_restored" == *"integrated_this_run=0"* ]]; then
    echo "FAIL: restored packed candidate ref was not rediscovered by actual reconcile --actuate" >&2
    exit 1
  fi
  echo "PASS: retrospective baseline unexpectedly rediscovered restored ref"
  exit 0
fi
[[ "$actual_first" == *"canonical_integration_scans_this_run=1"* ]] \
  || { echo "$actual_first" >&2; exit 1; }
[[ "$actual_first" == *"integrated_this_run=0"* ]] \
  || { echo "$actual_first" >&2; exit 1; }
[[ "$(count_lines "$canonical_count")" == 1 ]] || exit 1
[[ "$(count_lines "$validation_count")" == 0 ]] || exit 1

# The immediately following unchanged cycle runs neither the canonical wrapper
# nor the expensive exact-tree gate.
actual_second="$(run_actual 2>&1)"
[[ "$actual_second" == *"canonical_integration_scans_this_run=0"* ]] \
  || { echo "$actual_second" >&2; exit 1; }
[[ "$(count_lines "$canonical_count")" == 1 ]] || exit 1
[[ "$(count_lines "$validation_count")" == 0 ]] || exit 1

# The measured expensive boundaries: the baseline cycle actually validates
# historical eligibility inside the production integrator, and the following
# unchanged cycle performs none, including for the retained nonterminal entry
# whose candidate branch is still missing. This fixture has no eligible
# dispatch work at all.
[[ "$(count_kind historical-validation)" -ge 1 ]] \
  || { echo "FAIL: no instrumented historical validation in the baseline cycle" >&2; exit 1; }
: >"$integration_receipt"
actual_third="$(run_actual 2>&1)"
[[ "$actual_third" == *"canonical_integration_scans_this_run=0"* ]] \
  || { echo "$actual_third" >&2; exit 1; }
[[ "$(count_kind historical-validation)" == 0 ]] \
  || { echo "FAIL: an unchanged cycle revalidated historical eligibility" >&2; exit 1; }
[[ "$(count_kind final-authority-check)" == 0 ]] \
  || { echo "FAIL: an unchanged cycle ran a final authority check" >&2; exit 1; }
[[ "$(count_lines "$dispatch_count")" == 0 ]] || exit 1

# Repeat over a complete sweep of the retained population. Unchanged sweep
# hashes must not trigger expensive revalidation on any cycle of the pass.
sweep_cycles=0
while [[ "$sweep_cycles" -lt 6 ]]; do
  sweep_out="$(run_actual 2>&1)"
  [[ "$sweep_out" == *"canonical_integration_scans_this_run=0"* ]] \
    || { echo "$sweep_out" >&2; exit 1; }
  sweep_cycles=$((sweep_cycles + 1))
done
[[ "$(count_kind historical-validation)" == 0 ]] \
  || { echo "FAIL: a complete unchanged sweep revalidated historical eligibility" >&2; exit 1; }
[[ "$(count_lines "$canonical_count")" == 1 ]] || exit 1

# Reproducible receipts separate sweep work, rebuild cost, canonical validation
# and unrelated control-plane activity. TASK-1106's evaluator accepts them as a
# declared observation input; this task adds no second reporting service.
[[ -f "$reconcile_receipt" ]] \
  || { echo "FAIL: no reconcile discovery receipt was produced" >&2; exit 1; }
"$PYTHON" - "$reconcile_receipt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["schema"] == "singular.orchestration.reconcile-index-receipt.v1", doc
assert doc["authority"] == "discovery-only", doc
for key in ("sweep", "rebuild", "events", "canonical", "platform", "corpus"):
    assert key in doc, (key, sorted(doc))
for key in ("directoryEntriesScanned", "filesHashed", "bytesHashed", "elapsedMs"):
    assert key in doc["sweep"], (key, doc["sweep"])
for key in ("historicalValidations", "finalAuthorityChecks", "subprocesses"):
    assert key in doc["canonical"], (key, doc["canonical"])
serialized = json.dumps(doc).lower()
for forbidden in ("savings", "tokens", "usd", "threshold"):
    assert forbidden not in serialized, forbidden
PY
"$PYTHON" "$engine_source/engine/context_cli.py" campaign-report \
  --events "$actual_state/events.ndjson" --runs "$actual_state/runs" \
  --observations "$reconcile_receipt" --output "$tmp/campaign-report.json" >/dev/null
"$PYTHON" - "$tmp/campaign-report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
record = report["inputs"]["observations"]
assert record["present"] is True, record
assert record["sha256"], record
PY

# Disabling the index invokes the same production canonical integrator. While
# the branch is missing both modes agree there is no eligible integration.
actual_no_index="$(run_actual SINGULAR_RECONCILE_INDEX=0 2>&1)"
[[ "$actual_no_index" == *"canonical_integration_scans_this_run=1"* ]] || exit 1
[[ "$actual_no_index" == *"integrated_this_run=0"* ]] || exit 1

# Canonical and indexed discovery must reach the same per-candidate eligible
# and deferred outcomes on the same pinned corpus: a retained accepted
# candidate whose branch is missing, a malformed packet, and a well-formed
# nonterminal packet. The comparison is over the integrator's own decisions,
# not over the index's opinion of them.
integration_decisions() {
  printf '%s\n' "$1" | sed -nE 's/^  integ: (skip|FAILED|INTEGRATED) /\1 /p' | sort
}
canonical_decisions="$(integration_decisions "$actual_no_index")"
[[ -n "$canonical_decisions" ]] \
  || { echo "FAIL: canonical discovery produced no comparable decisions" >&2; exit 1; }
rm -f "$actual_state/reconcile-index.json"
actual_indexed_full="$(run_actual 2>&1)"
indexed_decisions="$(integration_decisions "$actual_indexed_full")"
if [[ "$canonical_decisions" != "$indexed_decisions" ]]; then
  echo "FAIL: canonical and indexed discovery disagreed on the pinned corpus" >&2
  diff <(printf '%s\n' "$canonical_decisions") <(printf '%s\n' "$indexed_decisions") >&2 || true
  exit 1
fi
printf '%s\n' "$canonical_decisions" | grep -q '^skip TASK-2201' \
  || { echo "FAIL: retained accepted candidate was not deferred by both modes" >&2; exit 1; }
# The malformed and nonterminal packets are deferred without a printed reason;
# compare the integrator's own accounting rather than assuming a message.
integration_accounting() {
  printf '%s\n' "$1" | sed -nE 's/^  integ: (integrated_this_run|failed_integrations|skipped)=/\1=/p' | sort
}
canonical_accounting="$(integration_accounting "$actual_no_index")"
indexed_accounting="$(integration_accounting "$actual_indexed_full")"
[[ -n "$canonical_accounting" ]] \
  || { echo "FAIL: canonical discovery produced no comparable accounting" >&2; exit 1; }
if [[ "$canonical_accounting" != "$indexed_accounting" ]]; then
  echo "FAIL: canonical and indexed eligibility accounting disagreed" >&2
  diff <(printf '%s\n' "$canonical_accounting") <(printf '%s\n' "$indexed_accounting") >&2 || true
  exit 1
fi
printf '%s\n' "$canonical_accounting" | grep -q '^integrated_this_run=0$' \
  || { echo "FAIL: a pinned non-eligible corpus member was integrated" >&2; exit 1; }
for pinned in TASK-2201 TASK-2202 TASK-2203; do
  for mode_output in "$actual_no_index" "$actual_indexed_full"; do
    if printf '%s\n' "$mode_output" | grep -q "INTEGRATED $pinned"; then
      echo "FAIL: $pinned was integrated from the pinned non-eligible corpus" >&2
      exit 1
    fi
  done
done
[[ "$(count_lines "$publication_count")" == 0 ]] || exit 1

# Restore through packed-refs. The indexed path notices immediately, executes
# the real gate and integrator, then stops before index acknowledgement.
git -C "$actual_repo" branch agent/core/TASK-2201-incremental "$actual_head"
git -C "$actual_repo" pack-refs --all --prune
interrupted_rc=0
run_actual SINGULAR_TEST_INTERRUPT_BEFORE_RECONCILE_INDEX_ACK=1 \
  >"$tmp/interrupted-reconcile.out" 2>&1 || interrupted_rc=$?
[[ "$interrupted_rc" == 97 ]] \
  || { cat "$tmp/interrupted-reconcile.out" >&2; exit 1; }
grep -q 'INTEGRATED TASK-2201' "$tmp/interrupted-reconcile.out" || exit 1
[[ "$(count_lines "$validation_count")" == 1 ]] || exit 1
[[ "$(count_lines "$publication_count")" == 1 ]] || exit 1
[[ "$(grep -c '"type":"integration.integrated"' "$actual_state/events.ndjson")" == 1 ]] || exit 1

# A fresh process replays canonical work from the unacknowledged baseline, but
# terminal lifecycle and ancestry guards prevent another gate or publication.
actual_resume="$(run_actual 2>&1)"
[[ "$actual_resume" == *"canonical_integration_scans_this_run=1"* ]] \
  || { echo "$actual_resume" >&2; exit 1; }
[[ "$(count_lines "$validation_count")" == 1 ]] || exit 1
[[ "$(count_lines "$publication_count")" == 1 ]] || exit 1
[[ "$(grep -c '"type":"integration.integrated"' "$actual_state/events.ndjson")" == 1 ]] || exit 1

# Deleted and corrupt state both fail open to canonical discovery without
# duplicating the already accepted publication or dispatching a provider.
rm "$actual_state/reconcile-index.json"
actual_missing_index="$(run_actual 2>&1)"
[[ "$actual_missing_index" == *"canonical_integration_scans_this_run=1"* ]] || exit 1
printf '{broken\n' >"$actual_state/reconcile-index.json"
actual_corrupt_index="$(run_actual 2>&1)"
[[ "$actual_corrupt_index" == *"canonical_integration_scans_this_run=1"* ]] || exit 1
[[ "$(count_lines "$validation_count")" == 1 ]] || exit 1
[[ "$(count_lines "$dispatch_count")" == 0 ]] || exit 1
[[ "$(count_lines "$publication_count")" == 1 ]] || exit 1
[[ "$(grep -c '"type":"integration.integrated"' "$actual_state/events.ndjson")" == 1 ]] || exit 1

echo "PASS: test-incremental-reconcile"
