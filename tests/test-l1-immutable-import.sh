#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-l1-immutable-import.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SINGULAR_ROOT="$(mktemp -d)"
trap 'rm -rf "$SINGULAR_ROOT"' EXIT
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/bootstrap-state"
export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/bootstrap-orch"
export SINGULAR_TASKS_DIR="$SINGULAR_ROOT/bootstrap-tasks"
export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
export SINGULAR_DISPATCH_DIR="$SINGULAR_STATE_DIR/dispatch"
export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/worktrees"
export SINGULAR_JSON_CONFIG_FILE="$SINGULAR_ROOT/no-config.json"
export SINGULAR_CONFIG_FILE="$SINGULAR_ROOT/no-config.sh"
export SINGULAR_LOCAL_CONFIG_FILE="$SINGULAR_ROOT/no-local.sh"
source "$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

fixture() {
  local root="$SINGULAR_ROOT/fixture-$1"
  rm -rf "$root"
  mkdir -p "$root/tasks" "$root/state/runs/RUN-import/l1-staging/node" \
    "$root/schemas"
  export SINGULAR_TASKS_DIR="$root/tasks"
  export SINGULAR_STATE_DIR="$root/state"
  export SINGULAR_ORCH_DIR="$root/orch"
  export SINGULAR_RUNS_DIR="$root/state/runs"
  export SINGULAR_LEASES_DIR="$root/state/leases"
  export SINGULAR_DISPATCH_DIR="$root/state/dispatch"
  export SINGULAR_WORKTREES_DIR="$root/worktrees"
  export SINGULAR_EVENTS_FILE="$root/state/events.ndjson"
  export SINGULAR_L1_LEASES_DIR="$root/state/l1-leases"
  export SINGULAR_TASKBATCH_SCHEMA="$ENGINE_HOME/schemas/task-batch.v0.schema.json"
  export SINGULAR_TEST_IMPORT_FAIL_AT=""
  stage="$SINGULAR_RUNS_DIR/RUN-import/l1-staging/node"
  singular_l1_lease_write node brain stage layer active RUN-import abc1234 target
}

write_candidate() {
  local path="$1" id="$2" other="$3"
  cat >"$path" <<EOF
# $id: Immutable candidate

Status: ready
Area: brain
DAG node: node
Target branch: \`target\`
Worker branch: \`worker/$id\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: [TASK-9000]

## Objective

Reference $id and sibling $other without cascading.

## Scope

Owned files:

- \`engine/$id file.sh\` — exact path

## Acceptance Criteria

- Imported safely.
EOF
}

publish_generation() {
  local replacement="$stage/replacement"
  mkdir -p "$replacement"
  write_candidate "$stage/TASK-0002.candidate.md" TASK-0002 TASK-0001
  write_candidate "$stage/TASK-0001.candidate.md" TASK-0001 TASK-0002
  cp "$stage"/*.candidate.md "$replacement/"
  singular_task_batch_replace_stage "$replacement" "$stage" || fail "generation publish failed"
  candidate_dir="$(singular_task_batch_candidate_dir "$stage")"
  canonical_before="$stage/canonical.before"
  (
    find "$candidate_dir" -type f -name '*.candidate.md' -exec stat -f '%N %Lp' {} \;
    shasum -a 256 "$candidate_dir"/*.candidate.md
    shasum -a 256 "$stage/.candidate-current.json"
  ) >"$canonical_before"
  printf '{"binding":"must remain byte-identical"}\n' >"$stage/plan-critique.json"
  critique_before="$(shasum -a 256 "$stage/plan-critique.json")"
}

assert_canonical_unchanged() {
  local after="$stage/canonical.after"
  (
    find "$candidate_dir" -type f -name '*.candidate.md' -exec stat -f '%N %Lp' {} \;
    shasum -a 256 "$candidate_dir"/*.candidate.md
    shasum -a 256 "$stage/.candidate-current.json"
  ) >"$after"
  cmp -s "$canonical_before" "$after" || fail "canonical bytes, modes, hashes, or pointer changed"
  assert_eq "$(shasum -a 256 "$stage/plan-critique.json")" "$critique_before" \
    "critique binding changed"
  [[ -z "$(find "$stage" -maxdepth 1 -type d -name '.import-*' -print -quit)" ]] \
    || fail "private import scratch leaked"
}

fixture success
publish_generation
printf '1\n' >"$SINGULAR_STATE_DIR/task-id-counter"
out="$(singular_l1_import_staged RUN-import node 2>&1)" || fail "immutable import failed: $out"
assert_contains "$out" "generated:TASK-0002" "second allocated id missing"
assert_contains "$out" "generated:TASK-0003" "third allocated id missing"
assert_contains "$(cat "$SINGULAR_TASKS_DIR/TASK-0002.md")" \
  'Reference TASK-0002 and sibling TASK-0003 without cascading.' \
  "whole-batch mapping cascaded or missed a sibling reference"
assert_contains "$(cat "$SINGULAR_TASKS_DIR/TASK-0003.md")" \
  'Reference TASK-0003 and sibling TASK-0002 without cascading.' \
  "whole-batch mapping cascaded or missed a sibling reference"
assert_contains "$(cat "$SINGULAR_TASKS_DIR/TASK-0002.md")" 'Depends on: [TASK-9000]' \
  "external dependency changed"
assert_canonical_unchanged

for failure in prepare rewrite:2 publish:2; do
  fixture "${failure//:/-}"
  cat >"$SINGULAR_TASKS_DIR/TASK-7000.md" <<'EOF'
# TASK-7000: Unrelated

Status: integrated
Area: other
DAG node: other

## Objective

Preserve this unrelated task.

## Scope

Owned files:

- other/file.txt
EOF
  publish_generation
  out="$(SINGULAR_TEST_IMPORT_FAIL_AT="$failure" singular_l1_import_staged RUN-import node 2>&1 || true)"
  assert_eq "$(find "$SINGULAR_TASKS_DIR" -maxdepth 1 -name 'TASK-*.md' | wc -l | tr -d ' ')" "1" \
    "$failure left a partial published batch"
  assert_contains "$(cat "$SINGULAR_TASKS_DIR/TASK-7000.md")" "Preserve this unrelated task." \
    "$failure removed or rewrote an unrelated task"
  assert_canonical_unchanged
  counter="$(cat "$SINGULAR_STATE_DIR/task-id-counter" 2>/dev/null || echo 0)"
  if [[ "$failure" == prepare ]]; then
    assert_eq "$counter" "0" "preparation failure should occur before allocation"
  else
    assert_eq "$counter" "7002" "$failure recycled or failed to reserve allocated ids"
  fi
done

echo "test-l1-immutable-import.sh: ok"
