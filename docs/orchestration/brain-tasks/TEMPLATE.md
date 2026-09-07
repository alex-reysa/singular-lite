# TASK-XXXX: <title>

Status: ready
Area: brain
Node: <assigned DAG node>
Target branch: `codex/brain-integration`
Worker branch: `codex/brain/TASK-XXXX-<slug>`
Test policy: `strict_test_first`
Gate command: `bash tests/test-<feature>.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Read the full task at "$SINGULAR_TASKS_DIR/TASK-XXXX.md" and docs/brain-build-plan/campaign.md. Describe a complete, bounded capability and include all mandatory implementation requirements in this Objective and the flat Acceptance Criteria.

## Scope

Owned files:

- `path/to/file`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The gate command passes.
