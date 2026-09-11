#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/root/.singular-state" "$tmp/root/tasks"

run_lib() {
  SINGULAR_ROOT="$tmp/root" \
  SINGULAR_STATE_DIR="$tmp/root/.singular-state" \
  SINGULAR_TASKS_DIR="$tmp/root/tasks" \
  SINGULAR_JSON_CONFIG_FILE="$tmp/root/no-config.json" \
  SINGULAR_CONFIG_FILE="$tmp/root/no-config.sh" \
  SINGULAR_LOCAL_CONFIG_FILE="$tmp/root/no-local.sh" \
  bash -c "source '$ENGINE_HOME/engine/lib.sh'; $1"
}

write_valid_task() {
  local path="$1"
  cat >"$path" <<'EOF'
# TASK-4242: Parser fidelity

Status: ready
Area: brain
DAG node: brain-package
Target branch: `target`
Worker branch: `worker/TASK-4242`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Preserve task data.

## Scope

Owned files:

- `engine/path with spaces.py` — implementation and fixtures
- `Release Notes.md` — quoted root-level path
- engine/plain.py

Forbidden files:

- `private/no touch.md` — immutable source
- `Do Not Touch.md` — quoted root-level restriction
- Any file outside the owned scope.

## Acceptance Criteria

- The first obligation survives.
  Continuation paragraph with literal [TASK-ID] and $(printf inert).

  - Nested obligation with `literal code`.
- The late obligation survives too.
EOF
}

task="$tmp/root/tasks/TASK-4242.md"
write_valid_task "$task"
parsed="$(run_lib "singular_task_json '$task'")" || fail "valid annotated task did not parse"
python3 - "$parsed" <<'PY' || fail "parsed task fields lost fidelity"
import json, sys
d = json.loads(sys.argv[1])
assert d["ownedFiles"] == ["engine/path with spaces.py", "Release Notes.md", "engine/plain.py"], d["ownedFiles"]
assert d["forbiddenFiles"] == ["private/no touch.md", "Do Not Touch.md"], d["forbiddenFiles"]
assert len(d["acceptanceCriteria"]) == 2, d["acceptanceCriteria"]
assert "Continuation paragraph with literal [TASK-ID] and $(printf inert)." in d["acceptanceCriteria"][0]
assert "- Nested obligation with `literal code`." in d["acceptanceCriteria"][0]
assert d["taskDocument"].endswith("The late obligation survives too.\n")
PY

index="$(run_lib "singular_node_task_index_json brain-package")" || fail "node index rejected valid task"
python3 - "$index" <<'PY' || fail "node index scope differs from task JSON"
import json, sys
d = [item for item in json.loads(sys.argv[1]) if item["taskId"] == "TASK-4242"]
assert len(d) == 1, d
assert d[0]["ownedFiles"] == ["Release Notes.md", "engine/path with spaces.py", "engine/plain.py"], d
PY

run_lib "singular_task_preflight '$parsed' true target 1" >/dev/null \
  || fail "preflight rejected a valid forbidden path containing spaces"

for body in \
  '- `engine/a.py` and `engine/b.py`' \
  '- `engine/unclosed.py' \
  '- `../engine/traversal.py`' \
  '- engine/*.py' \
  '- engine/a.py rationale'; do
  bad="$tmp/root/tasks/TASK-4999.md"
  python3 - "$task" "$bad" "$body" <<'PY'
from pathlib import Path
import sys
source, target, replacement = sys.argv[1:4]
text = Path(source).read_text(encoding="utf-8")
text = text.replace("- `engine/path with spaces.py` — implementation and fixtures", replacement)
Path(target).write_text(text, encoding="utf-8")
PY
  err="$(run_lib "singular_task_json '$bad'" 2>&1)" && fail "ambiguous scope parsed: $body"
  assert_contains "$err" "TASK-4999.md:" "invalid scope diagnostic names task and line"
done

# Exercise the real driver prompt builder with a disposable legacy campaign.
repo="$tmp/driver"
mkdir -p "$repo/docs/orchestration/tasks" "$repo/docs/orchestration/prompts" \
  "$repo/schemas/orchestration" "$repo/.singular-state"
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$repo/docs/orchestration/prompts/"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$repo/docs/orchestration/prompts/"
cp "$ENGINE_HOME/schemas/state-packet.v0.schema.json" "$repo/schemas/orchestration/"
write_valid_task "$repo/docs/orchestration/tasks/TASK-4242.md"
(
  cd "$repo"
  git init -q
  git checkout -q -b target
  git add .
  git -c user.name=test -c user.email=test@example.local commit -q -m init
)
mkdir -p "$repo/private"
printf 'changed\n' >"$repo/private/no touch.md"
scope_out="$(
  SINGULAR_ROOT="$repo" SINGULAR_JSON_CONFIG_FILE="$repo/no-config.json" \
    SINGULAR_CONFIG_FILE="$repo/no-config.sh" SINGULAR_LOCAL_CONFIG_FILE="$repo/no-local.sh" \
    bash "$ENGINE_HOME/engine/scope-check.sh" --worktree "$repo" \
      --allow-prefix private --forbid-prefix 'private/no touch.md' 2>&1
)" && fail "space-bearing forbidden path was not enforced"
assert_contains "$scope_out" "private/no touch.md" "scope check lost forbidden path with spaces"
rm -f "$repo/private/no touch.md"
printf 'changed\n' >"$repo/Do Not Touch.md"
root_scope_out="$(
  SINGULAR_ROOT="$repo" SINGULAR_JSON_CONFIG_FILE="$repo/no-config.json" \
    SINGULAR_CONFIG_FILE="$repo/no-config.sh" SINGULAR_LOCAL_CONFIG_FILE="$repo/no-local.sh" \
    bash "$ENGINE_HOME/engine/scope-check.sh" --worktree "$repo" \
      --allow-prefix 'Do Not Touch.md' --forbid-prefix 'Do Not Touch.md' 2>&1
)" && fail "root-level forbidden path with spaces was not enforced"
assert_contains "$root_scope_out" "Do Not Touch.md" \
  "scope check lost root-level forbidden path with spaces"
rm -f "$repo/Do Not Touch.md"
driver_out="$(
  SINGULAR_ROOT="$repo" \
  SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
  SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_TARGET_BRANCH=target \
  SINGULAR_WORKTREES_DIR="$repo/.worktrees" \
  SINGULAR_JSON_CONFIG_FILE="$repo/no-config.json" \
  SINGULAR_CONFIG_FILE="$repo/no-config.sh" \
  SINGULAR_LOCAL_CONFIG_FILE="$repo/no-local.sh" \
  SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE=1 \
    bash "$ENGINE_HOME/engine/l1-drive.sh" TASK-4242 --dry-run 2>&1
)" || fail "real driver dry-run failed: $driver_out"
run_dir="$(find "$repo/.singular-state/runs" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$run_dir" ]] || fail "driver did not create a run directory"
for prompt in "$run_dir/l2-prompt.md" "$run_dir/auditor-prompt.md"; do
  content="$(cat "$prompt")"
  assert_contains "$content" 'Continuation paragraph with literal [TASK-ID] and $(printf inert).' \
    "mandatory continuation missing from $(basename "$prompt")"
  assert_contains "$content" '- Nested obligation with `literal code`.' \
    "nested obligation missing from $(basename "$prompt")"
  assert_contains "$content" '`engine/path with spaces.py` — implementation and fixtures' \
    "full task snapshot missing from $(basename "$prompt")"
done

echo "test-task-parsing-fidelity.sh: ok"
