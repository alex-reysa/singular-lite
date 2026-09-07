# Dogfooding fixes queued in the brain iteration

On 2026-09-07 the user explicitly requested that the four observed orchestration defects be fixed in this same iteration. These are executable tasks in the active Singular queue, planned by GPT-6 Astra High through the native runner. GPT-5.6 Sol High will implement and freshly audit each task through the existing campaign pipeline.

| Task | Repair | Integration dependencies |
|---|---|---|
| [TASK-1005](../orchestration/brain-tasks/TASK-1005.md) | Native model selection by role, fallback compatibility and safe session reuse | TASK-1003 and TASK-1010 |
| [TASK-1006](../orchestration/brain-tasks/TASK-1006.md) | Effective configuration, runtime, task and state path parity across CLI, doctor and console | TASK-1005 |
| [TASK-1007](../orchestration/brain-tasks/TASK-1007.md) | Unambiguous scope parsing, paths containing spaces and complete obligations in worker/auditor prompts | TASK-1006 |
| [TASK-1008](../orchestration/brain-tasks/TASK-1008.md) | Read-only parallel candidate import using private publication copies and preserved critique binding | TASK-1007 |

Each task is `ready` when published. Dependency eligibility requires integration, not merely worker completion or audit acceptance. The sequence avoids conflicting edits to shared engine files and waits for both in-flight brain tasks. Consult native task files, leases and events for current status; this document records the queue extension, not completed repairs.

This is an explicitly authorized product-scope addendum to campaign `BRAIN-20260907-ASTRA-SOL-R2`, on `codex/brain-integration`, based on release 0.21.0. These supporting tasks are attributed to the existing brain-package node; the active DAG, planner policy, campaign configuration and executing runtime are unchanged. Exact task-owned files include the console server and its focused tests. Native canonical dispatch enforces task-owned scope; the area map is used by the planner's area reservation.

Behavioral red/green evidence, fresh audits and the full host integration regression suite remain required. No task can create the B1 end-to-end completion signature or alter gate authority. Repairs affect the product branch and hermetic test runtimes; using the resulting engine to run campaigns requires an explicit replacement with a newly frozen identity. Current serial planning and the per-role wrapper remain in place for this run.

Planner output, source observations, native parsed task records, model/session metadata, publication hashes and the operator queue event are retained under `.singular-state/campaign-evidence/dogfood-fix-queue/`. Original observations remain in `operator-observations.ndjson`. These task definitions address verified product behavior; they do not turn operator-induced setup errors or unverified cost hypotheses into product defects.

Dependency correction on 2026-09-07: TASK-1010 explicitly supersedes blocked TASK-1004. TASK-1005 now waits for TASK-1010 integration instead of the historical consumer task. TASK-1003 remains a required producer dependency; this edit does not clear its blocked state or claim integration.
