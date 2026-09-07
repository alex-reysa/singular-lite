# Planner contract — brain integration campaign

Use docs/brain-build-plan/campaign.md as the node-specific authority. Read current
code before emitting tasks. This contract replaces the older self-dock rules.

Plan complete, bounded vertical capabilities. Prefer 1–3 tasks per node with up
to 8 explicitly owned files, or a named vendor/fixture subtree where importing
upstream. Do not fragment a feature into uncalled leaves. Dependent tasks must
wait for integration; same-batch tasks must have disjoint owned files. Complete
the node-specific end-to-end acceptance test in the final task, after all node
behaviors exist, never as a placeholder that allows premature promotion.

Tasks are strict_test_first: meaningful red before implementation and green
after. Scope can include necessary implementation, caller wiring, schema, and
tests in one vertical task. The host owns gate execution. Task Gate command may
run scoped regression through `bash tests/run.sh TEST-FILE...`, including the
new tests and affected existing boundary tests; never use true or drop needed
coverage. The final task in B5 must use the full `SINGULAR_TEST_JOBS=4 bash
tests/run.sh` gate. Keep full regression available and do not weaken assertions.

Use docs/orchestration/brain-tasks/TEMPLATE.md. Area: brain. Target branch:
codex/brain-integration. Worker branch: codex/brain/TASK-XXXX-<slug>.
Use the assigned DAG node and task IDs. Preserve independent fresh auditors,
exact-tree proofs, source integrity, capability isolation, and secret scanning.
New features are opt-in, compatible when disabled, and generic in engine/.
Do not alter campaign policy, active DAG, tools/brain-campaign/, frozen runtime,
or upstream snapshot. No arbitrary new cloud services or paid embeddings.

Observed bootstrap constraints: write each acceptance criterion as one complete
physical bullet line because 0.21.0's prompt renderer drops continuation lines.
Keep the complete task discoverable. The worker sandbox cannot write the parent
checkout's shared Git worktree registry, so tests/run.sh may fail its source
preflight even when direct individual test scripts pass. Prefer explicit direct
focused test commands for task gates where appropriate; preserve the final full
host regression requirement and report sandbox failures accurately. Do not
weaken tests or widen filesystem access. Retained operational observations are
in the campaign root's .singular-state/campaign-evidence/ directory.

The Objective must explicitly direct the worker to the complete task at
"$SINGULAR_TASKS_DIR/TASK-XXXX.md" (using its actual task ID); newly generated
tasks may not yet exist in the worker checkout. Put mandatory requirements in
the rendered Objective and complete single-line Acceptance Criteria, not only
in extra sections. The context integration must later carry an immutable full
task snapshot itself. Integration runs the full default suite for every task,
so favor cohesive vertical tasks rather than tiny mechanical splits.
