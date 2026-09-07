# Brain integration campaign

Authorized by the user on 2026-09-07: use singular-lite itself to implement the
brain/context/memory proposal and collect evidence about the orchestration.
Base: singular-lite 0.21.0, 0f92cba1fb1f2b51d6762b493b0ac7aaded8fdd9.
Upstream brain: 0.2.0, e05f259be5cabda2bb8caa241f23cc1f48e9f059.

Use `docs/brain-build-plan/assessment.md` for the assessment and rationale.
This campaign file defines the executable scope and completion requirements.
The approved design replaces the historical context-evolution plan's rule that
all new logic must be tiny ctx-*.sh wrappers. Prefer a cohesive Python service.

The bootstrap TASK-1001 canary-isolation repair is an explicitly reviewed patch
to the release baseline; its source revision is recorded in runtime-baseline.json.
The frozen orchestrator is in `.singular-state/runtime/0.21.0-brain-bootstrap`. Changes to the
product's engine must not change this runtime during the campaign. The launcher
is `tools/brain-campaign/run.sh`. Campaign configuration, source snapshots, and
raw observations stay in `.singular-state/`; do not commit runtime logs.
Workers must not modify the launcher, runner wrapper, frozen runtime, campaign
policy, active DAG, planner contract, or this campaign scope to pass a task.

Models: GPT-6 Astra high for planner, recovery decider, supervisor; GPT-5.6 Sol
high for implementer, plan critic, final auditor, and paired auditor. The L0
scheduler remains deterministic. Use fresh audit sessions and preserve all
existing audit, exact-tree gate, scope, secret-scan, and campaign-binding rules.

The initial rollout remains opt-in for ordinary consumers. Implement complete
vertical behavior with focused tests and meaningful task widths. Do not create
tasks that merely restate a completion gate or add an uncalled wrapper. Usually
aim for one to three implementation tasks per node, not one task per helper.
No vectors, separate memory server, remote embedding service, or automatic
cross-project ingestion is required in this campaign.

## B1 — Package and ingest actual brain output

Vendor the exact upstream engine plus VERSION, SCHEMA_VERSION and applicable
provenance/license metadata under vendor/singular-brain. The read-only upstream
snapshot is `.singular-state/upstream/singular-brain-0.2.0` in the campaign root;
the original repository is the adjacent `singular-brain` directory. Copy its
test fixtures as necessary into the consumer test fixture tree. Keep upstream
engine bytes unchanged in the initial vendor import.

Add `singular manifest gen|check|lint|bless` with explicit consumer config,
installation payload coverage, doctor checks, and campaign fingerprint coverage.
Node must remain optional when brain is unconfigured. Consume the real
singular-brain.manifest.v1 through a validated adapter. Preserve legacy fixture
ingestion through an explicit compatibility path, without ambiguously guessing
schema fields. Resolve paths against declared roots, contain symlinks/paths,
reject duplicate identities and invalid configured manifests, handle nested
freshness and status, and distinguish live source hashes from review hashes.
Natural-language loadWhen text must not be treated as exact role tokens.

Completion test `tests/test-brain-ingestion-e2e.sh`: run the vendored generator
on a copied actual corpus; select expected eligible entries; expose stale,
superseded, malformed, duplicate, quarantine, wrong-root and missing-source
conditions correctly; verify invocation from a different cwd and installed
payload behavior. Tests must cover the real producer, not only invented JSON.

## B2 — Bounded context build, search, get, explain

Add a shared local Python library/CLI for brain documents, selected current
worktree code, and existing run records. Expose `singular context build|search|
get|explain` with a documented versioned interface. Search uses exact references
and lexical ranking initially; no third-party runtime dependency is required.
Preserve source project/worktree revision and role policy across operations.
Allow section/line pagination so facts after the first 4000 characters can be
retrieved. Include full-source and excerpt hashes, source locations, selection
reasons, validity, budget usage and omissions. Required task constraints and
open/violated obligations have priority over optional material. Enforce an
aggregate budget and explicit failure if mandatory content cannot fit.

Build prompt text and provenance together from one read/immutable bundle, with
atomic publication and deterministic ordering. Get must verify source integrity
and refuse wrong-version reads. Search/get/explain must work in a read-only
agent sandbox, without writing cache locks or budget ledgers in /tmp or the
source tree; place any required accounting at the host invocation boundary. Any disposable cache must be rebuildable and
worktree-specific. Avoid mutating committed indexes inside a verification gate.

Completion test `tests/test-context-service-e2e.sh`: actual generated corpus,
exact and paraphrased lexical queries with documented limits, late-section
fetch, aggregate cap and mandatory overflow, tamper/missing-source handling,
deterministic bundle hashes, and distinct concurrent worktree snapshots.

## B3 — Invocation coverage and independent audits

Wire the shared service to planner and worker first attempts as well as retries,
independently of whether the session router chooses rehydrate. Keep configured
feature-off behavior compatible. Resumes receive a documented delta rather than
unbounded duplication; changed/revoked sources cannot silently retain authority.
Auditors remain fresh and receive only policy-appropriate references selected
from the review task/target, never a worker-authored acceptance conclusion.
Keep critique advisory findings visible without allowing scope expansion.
Replace duplicate authored packet/event rereads with bundle references.

Completion test `tests/test-context-invocation-e2e.sh`: exercise real driver
prompt assembly with stub providers; prove planner and first worker receive
required knowledge, retries stay bounded, packet and event match, feature-off
compatibility holds, and final/paired audits cannot consume worker conclusions
as established authority. Add effective-config/doctor diagnostics and docs.

## B4 — Reviewed memory across tasks

Reuse execution events, tasks, findings, assumptions, and gate records. Add a
bounded `singular memory propose` path and explicit review/approval/supersession
interfaces or source-record workflow governed by consumer policy. Model output
is a candidate, not self-authorizing truth. Host-observed facts retain their
specific provenance. Approved knowledge becomes an authored artifact indexed by
brain; rejected or disputed candidates remain separate and labeled. Do not
automatically rewrite provider logs into a universally loaded catalog.

Define idempotent candidate capture, scope, source references, code-change
revalidation, supersession, and deletion/tombstone semantics across the
project-local memory/index/bundle surfaces. Preserve review ledgers. A source
cache rebuild must not resurrect explicitly retired content. Restore useful
task checkpoints without a provider session; report absent retained sources.

Completion test `tests/test-memory-lifecycle-e2e.sh`: task A produces a cited
candidate; review accepts it; task B retrieves it; rejected self-authorizing
claims are never approved automatically; replay is idempotent; supersession and
deletion behave correctly; index deletion/rebuild retains legitimate memory
and respects tombstones; a fresh process reopens the retained state.

## B5 — Evaluation and operational documentation

Add a deterministic labeled retrieval corpus/harness covering contracts, prior
failures, wrong versions, stale docs, missing knowledge, long documents, and
role restrictions. Record inclusion/recall within budget, incorrect selections,
omissions and abstention. Add an analysis command for existing campaign events
and runner-result sidecars to report invocations/tokens by role and available
model, retries, time to integration, failure causes, and missing observations.
Do not claim a causal improvement from this single before/after development run.

Completion test `tests/test-context-evaluation-e2e.sh`: evaluator computes known
fixture metrics and preserves missing-data semantics. Write adoption/rollback
instructions and a findings report from actual retained campaign observations.
Full regression is required before final delivery. Subsequent use of the newly
built runtime is a replacement campaign with a new frozen identity, never a
hot patch to this one.

## Retained setup evidence

Use .singular-state/campaign-evidence/operator-observations.ndjson and the
native runs/events as the raw baseline. Classify operator-induced setup failures,
provider/sandbox limits, product defects, and test flakiness separately. The
console and doctor in 0.21.0 do not consistently resolve custom task/config
paths; use the runtime's configured paths and actual session/runner sidecars
for this campaign. Do not claim the new memory layer caused baseline changes.

The replacement campaign uses 0.21.0's default single-node planning path with
Astra High. Its optional parallel planner path failed to import a read-only
canonical candidate because the importer rewrites IDs in place. The initial B1
plan received Sol High critiques; ongoing serial generation uses Astra's plan
and the normal Sol High implementation/final/paired-audit pipeline. The
original candidate and critique remain retained. The operator only normalized
owned-path formatting before publishing that first reviewed task.
