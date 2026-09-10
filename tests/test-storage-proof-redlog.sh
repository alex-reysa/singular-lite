#!/usr/bin/env bash
set -euo pipefail

# Regression tests for storage_proof red-log parity (one red artifact, not two).
#
# The L2 prompt's red_log is module-overridable via the singular_worker_red_log hook:
# - generic task (hook prints nothing): the rendered L2 prompt must stay
#   BYTE-IDENTICAL to the pre-hook base plus the mandatory complete task document
#   (red_log = .singular-evidence/red.log);
# - storage_proof task with the storage-proof module enabled: the prompt
#   instructs exactly ONE red artifact (.singular-evidence/<task>-skip-guard-red)
#   and never a second red file.
# Pure bash + fixtures; uses l1-drive.sh --dry-run (no worktree, no codex).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-storage-proof-redlog.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# shellcheck source=/dev/null
# Hermetic against operator config even when invoked directly (run.sh also
# pins this for the whole gate): lib.sh sources the repo's config.local.sh at
# source time, and an operator SINGULAR_MODULES there would load module
# overrides — this file tests the GENERIC hooks against the module-loaded
# ones, so a pre-loaded module makes its generic assertions unsatisfiable.
export SINGULAR_LOCAL_CONFIG_FILE=/dev/null
source "$SCRIPT_DIR/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

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
  unset SINGULAR_MODULES SINGULAR_WORKER_RED_LOG SINGULAR_WORKER_CONTRACT_EXTRA SINGULAR_RUNNER 2>/dev/null || true
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

# storage_proof fixture: matches singular_task_requires_storage_proof_red_guard
# (objective: storage_proof + durable round-trip proof against real PostgreSQL;
# criteria: marked nonzero; required evidence: skip-guard-red).
write_proof_task() {
  cat >"$SINGULAR_TASKS_DIR/TASK-0002.md" <<'EOF'
# TASK-0002: storage_proof durable closure

Status: ready
Area: storage
Target branch: `target`
Worker branch: `agent/storage/TASK-0002-proof`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the focused D6.storage_proof / storage_proof closure: a durable
round-trip proof against a real PostgreSQL store.

## Scope

Owned files:

- `internal/storage/proof_test.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The red evidence includes a marked nonzero storage-proof skip-guard command log.

## Required Evidence

- Failing output including TASK-0002-skip-guard-red, then passing durable proof.
EOF
}

# Render the L2 prompt EXACTLY as the pre-hook l1-drive.sh did (verbatim copy of
# the original prompt-assembly python, red_log hardcoded). This is the byte-level
# reference a generic task's prompt must still match after the change.
render_prechange_prompt() {
  SINGULAR_WORKER_CONTRACT_EXTRA="" python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import sys

template_path, out_path, task_raw, run_id, base_ref = sys.argv[1:6]
t = json.loads(task_raw)
with open(template_path, "r", encoding="utf-8") as f:
    tmpl = f.read()
import os
owned = t["ownedFiles"]; forbidden = t["forbiddenFiles"]; accept = t["acceptanceCriteria"]
red_log = ".singular-evidence/red.log"
# Extra obligations contributed by an enabled project module (generic: empty).
extra_module_contract = os.environ.get("SINGULAR_WORKER_CONTRACT_EXTRA", "")
if extra_module_contract and not extra_module_contract.endswith("\n"):
    extra_module_contract += "\n"
subs = {
    "[TASK-ID]": t["taskId"], "[BRANCH]": t["workerBranch"], "[TARGET]": t["targetBranch"],
    "[OWNED FILES]": ", ".join(owned) if owned else "(none)",
    "[FORBIDDEN FILES]": "; ".join(forbidden) if forbidden else "(none)",
    "[OBJECTIVE]": t["objective"],
    "[ACCEPTANCE CRITERIA]": "\n".join(f"- {c}" for c in accept) if accept else "(none)",
}
for k, v in subs.items():
    tmpl = tmpl.replace(k, v)
contract = f"""

---

## Execution Contract For This Run (authoritative)

You run non-interactively in a Codex sandbox selected by L0 for this task. Your
working directory is the worktree for this task.

- Edit ONLY these owned files: {", ".join(owned)}. Out-of-scope edits are rejected.
- Test-first: write `{red_log}` (failing test before impl),
  `.singular-evidence/green.log` (passing after impl), `.singular-evidence/regression.log`
  (`{t['gateCommand'] or '(your gate command)'}`).
{extra_module_contract}- Do NOT run git. Leave changes uncommitted; the L1 driver commits.
- Do NOT broaden architecture beyond the objective.

Your FINAL message MUST be a single JSON object matching the state packet schema
reference `schemas/orchestration/state-packet.v0.schema.json`. Set
schema exactly to "singular.orchestration.state-packet.v0" and include: packetId,
runId "{run_id}", taskId "{t['taskId']}", area "{t['area']}", role "l2-developer",
status "needs-review", baseRef "{base_ref}", branch "{t['workerBranch']}",
headSha "uncommitted", workspace (abs worktree path), ownedFiles {json.dumps(owned)},
changedFiles, commands[{{cmd,exitCode,logRef}}], tests[{{name,phase,status,logRef}}]
with red+green phases, evidence[{{kind,ref}}], blockers[], nextAction, createdAt.
Every commands[].cmd value MUST contain only the exact executable shell text
that was run. The host re-executes successful commands verbatim. Put attempt
labels, pass/fail counts, result summaries, and explanations in the command's
optional rationale or in evidence[], never append them to cmd. For example,
cmd may be "bun test path/to/test.ts"; it must not be
"bun test path/to/test.ts (attempt-2 green: 40 pass, 0 fail)".
No additional top-level fields are permitted. Do not emit `risks`; put any
unresolved blocking condition in blockers[] and any non-blocking note in
nextAction. Emit ONLY that JSON object.
"""
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl + contract)
PY
}

latest_l2_prompt() {
  find "$SINGULAR_RUNS_DIR" -name l2-prompt.md -type f 2>/dev/null | sort | tail -1
}

assert_prompt_byte_identical_to_generic_reference() {
  local task_id="$1" label="$2"
  local prompt run_id task_json ref
  prompt="$(latest_l2_prompt)"
  [[ -f "$prompt" ]] || fail "$label: dry run must assemble the L2 prompt"
  run_id="$(basename "$(dirname "$prompt")")"
  task_json="$(singular_task_json "$SINGULAR_TASKS_DIR/$task_id.md")"
  ref="$SINGULAR_STATE_DIR/reference-l2-prompt.md"
  render_prechange_prompt "$SINGULAR_ORCH_DIR/prompts/l2-test-first-developer.md" \
    "$ref" "$task_json" "$run_id" "target"
  # The delivery rescue intentionally appends the complete task document to
  # every worker prompt. Keep the old generic base byte-for-byte and require
  # that exact document, rather than treating the new obligation as drift.
  python3 - "$ref" "$SINGULAR_TASKS_DIR/$task_id.md" <<'PY'
from pathlib import Path
import sys
reference, task = map(Path, sys.argv[1:])
with reference.open("ab") as stream:
    stream.write(b"\n\n## Complete task contract (mandatory)\n\n")
    stream.write(task.read_bytes())
PY
  if ! cmp -s "$ref" "$prompt"; then
    diff "$ref" "$prompt" >&2 || true
    fail "$label: generic base and mandatory task document must match the reference"
  fi
  assert_contains "$(cat "$prompt")" ".singular-evidence/red.log" \
    "$label: generic prompt keeps the default red log"
}

# --- (a) generic task: red_log unchanged, prompt byte-identical ----------------

test_generic_prompt_byte_identical_without_module() {
  with_fixture
  write_generic_task
  SINGULAR_MODULES= "$SCRIPT_DIR/l1-drive.sh" --dry-run TASK-0001 >/dev/null
  assert_prompt_byte_identical_to_generic_reference TASK-0001 "generic, no module"
}

# CRITICAL INVARIANT: with the module ENABLED but the hook printing nothing
# (non-proof task), the rendered prompt is still byte-identical to pre-change.
test_generic_prompt_byte_identical_with_module_enabled() {
  with_fixture
  write_generic_task
  SINGULAR_MODULES=storage-proof "$SCRIPT_DIR/l1-drive.sh" --dry-run TASK-0001 >/dev/null
  assert_prompt_byte_identical_to_generic_reference TASK-0001 "generic, module enabled"
}

# --- (b) storage_proof task: exactly ONE red artifact (the skip-guard path) ----

test_storage_proof_prompt_instructs_single_skip_guard_red_artifact() {
  with_fixture
  write_proof_task
  SINGULAR_MODULES=storage-proof "$SCRIPT_DIR/l1-drive.sh" --dry-run TASK-0002 >/dev/null
  local prompt body reds
  prompt="$(latest_l2_prompt)"
  [[ -f "$prompt" ]] || fail "dry run must assemble the L2 prompt"
  body="$(cat "$prompt")"
  assert_contains "$body" ".singular-evidence/TASK-0002-skip-guard-red" \
    "proof prompt names the skip-guard red artifact as the red log"
  assert_not_contains "$body" ".singular-evidence/red.log" \
    "proof prompt must NOT also instruct the generic red.log (no second red file)"
  # Every red-artifact path mentioned anywhere in the prompt is the same single one.
  reds="$(grep -oE '\.singular-evidence/[A-Za-z0-9._-]*red[A-Za-z0-9._-]*' "$prompt" | sort -u)"
  assert_eq "$reds" ".singular-evidence/TASK-0002-skip-guard-red" \
    "exactly one distinct red artifact path is instructed"
  assert_contains "$body" "ONLY red artifact" \
    "module contract clarifies the skip-guard requirements apply to the single red log"
}

# --- hook unit behavior ---------------------------------------------------------

test_red_log_hook_outputs() {
  with_fixture
  write_generic_task
  write_proof_task
  local got
  # Generic engine default (lib.sh sourced without modules): always empty.
  got="$(singular_worker_red_log "$SINGULAR_TASKS_DIR/TASK-0002.md" TASK-0002)"
  assert_eq "$got" "" "generic singular_worker_red_log prints nothing"
  # Module override: skip-guard path for proof tasks, nothing for others.
  got="$( (source "$ENGINE_HOME/singular-ext/storage-proof.sh"; singular_worker_red_log "$SINGULAR_TASKS_DIR/TASK-0002.md" TASK-0002) )"
  assert_eq "$got" ".singular-evidence/TASK-0002-skip-guard-red" "module hook names the skip-guard path for proof tasks"
  got="$( (source "$ENGINE_HOME/singular-ext/storage-proof.sh"; singular_worker_red_log "$SINGULAR_TASKS_DIR/TASK-0001.md" TASK-0001) )"
  assert_eq "$got" "" "module hook prints nothing for non-proof tasks"
}

test_red_log_hook_outputs
test_generic_prompt_byte_identical_without_module
test_generic_prompt_byte_identical_with_module_enabled
test_storage_proof_prompt_instructs_single_skip_guard_red_artifact

echo "storage-proof red-log parity tests passed"
