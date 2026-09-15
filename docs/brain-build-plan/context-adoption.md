# Context, memory and evaluation: adoption and rollback

How to install a pinned engine, turn the brain/context/memory layer on, adopt an
immutable runtime, roll back, and what the memory approval policy does and does
not allow. The measured evidence that motivates this document is in
[`context-findings.md`](context-findings.md); the reliability caveats there
apply here too.

The whole layer is **opt-in and project-local**. A repository that configures
nothing keeps its previous behaviour byte-for-byte.

## 1. Pinned installation

The engine is pinned per repository. Nothing resolves "latest".

```bash
./install.sh                     # installs versioned engines under ~/.singular
singular update 0.21.0           # writes .singular-version in this repository
singular version                 # prints the CLI and the resolved engine version
singular doctor --json           # structured preflight; run before anything else
```

`.singular-version` is the pin. `singular.config.json` may additionally carry
`engineVersion` as a fallback pin. `SINGULAR_ENGINE_HOME` overrides both and is
intended for testing and vendored checkouts, not for normal operation.

The brain producer is vendored, not fetched: `vendor/singular-brain/` holds the
exact upstream engine plus `VERSION`, `SCHEMA_VERSION`, `PROVENANCE.json` and
`SHA256SUMS`. Regeneration uses that vendored copy and nothing else.

```bash
singular manifest gen            # produce the manifest from the vendored engine
singular manifest check          # verify the committed manifest byte-for-byte
singular manifest lint
singular manifest bless
```

## 2. Opt-in activation

Three independent switches. Each is off unless the repository configures it.

**Brain ingestion** — add `contextManifest` to `singular.config.json`. Without
it, the brain node stays optional and unconfigured.

```json
{
  "contextManifest": {
    "format": "singular-brain.manifest.v1",
    "manifest": "brain/generated/KNOWLEDGE.json",
    "sourceId": "your-brain",
    "expectedScope": "knowledge",
    "sourceRoot": "brain",
    "select": ["notes/migration-policy.md"]
  }
}
```

`select` is an allowlist: a document the manifest lists but `select` omits is
never a context source. `sourceRoot` bounds path resolution; an entry resolving
outside it is refused, not silently included.

**Context service** — add `contextService` and set `enabled`. While
`enabled` is `false` or absent, `build` returns a `disabled` bundle and the
driver behaves exactly as it did before the layer existed.

```json
{
  "contextService": {
    "enabled": true,
    "projectId": "your-project",
    "budgetBytes": 65536,
    "codePaths": ["src/selected.py"],
    "runRecordPaths": [".singular-state/runs/RUN-ID/runner-result.json"],
    "rolePolicy": {
      "implementer": ["brain", "code", "run", "memory"],
      "review-target": ["brain", "code"]
    }
  }
}
```

`rolePolicy` is a narrowing allowlist. Review roles (`review-target`,
`reviewer`, `auditor`) never receive `run` sources regardless of what the
policy grants — that boundary is enforced in the service, not in configuration,
so a permissive wildcard cannot import worker conclusions into an audit.
`SINGULAR_CONTEXT_BUDGET_BYTES` overrides `budgetBytes` per invocation and is
reported in `singular context effective-config`.

**Memory** — see [§5](#5-memory-approval-policy-and-local-scope). Memory is a
separate opt-in on top of the context service.

Verify activation before relying on it:

```bash
singular context effective-config --role review-target --phase final-audit
singular doctor --json
```

## 3. Immutable runtime adoption

Engine changes become operational only through a **new** immutable runtime and
a **new** campaign identity. An existing runtime or campaign identity is never
modified in place, and never hot-patched.

The adoption sequence used throughout this campaign, as recorded in the rescue
checkpoint:

1. Merge the reviewed source; record its head and tree.
2. Prepare a fresh runtime directory from that exact source, copy every tracked
   blob, and remove write bits.
3. Re-hash every tracked blob against the source tree and verify: 0 missing, 0
   mismatched, 0 extra, 0 writable. The A15 runtime records
   `"1118 blobs re-hashed: 0 missing, 0 mismatch, 0 writable"`.
4. Start a new campaign bound to that runtime, with a new campaign identity and
   epoch.
5. Run a live canary against the new runtime and keep its receipt.
6. Re-publish the gate proofs under the new runtime and commit them.
7. Run `singular doctor --json` and retain the raw report.
8. Record the adoption — runtime path, source head/tree, campaign identity,
   launcher commit, canary receipt, gate-proof commit, doctor summary — in the
   durable checkpoint.

Only after all eight steps is the runtime the active one. A partially adopted
runtime is not used.

## 4. Rollback

The previous runtime is left on disk, verified and untouched, specifically so
rollback is a selection rather than a rebuild. At the time of the measured read,
the checkpoint carries A14 as `previousRuntime` with `"role": "rollback (on
disk, untouched)"` alongside its own verification record and rollback receipt.

To roll back:

1. Set `STOP` so no new dispatch is admitted, and wait for in-flight work to
   reach a terminal state. Do not run reconcile, integrate, reap, dispatch or
   rescue during the switch.
2. End the current campaign explicitly (`singular campaign end`). Do not leave
   two campaign identities live.
3. Re-point the launcher at the retained previous runtime directory and start
   its campaign identity.
4. Re-run the canary (`singular campaign canary`) and `singular doctor --json`
   against the restored runtime, and keep both receipts.
5. Record the rollback — from-runtime, to-runtime, reason, receipts — in the
   checkpoint before clearing `STOP`.

Rolling back the *feature* rather than the runtime is cheaper and independent:
set `contextService.enabled` to `false`. Feature-off behaviour is compatible by
construction, so a repository can disable retrieval without changing its engine
pin or its runtime. Removing `contextManifest` likewise returns the brain node
to unconfigured/optional.

Approved memory records are **not** deleted by any rollback. Retire them
explicitly with `singular memory supersede` or `singular memory tombstone`; a
source-cache rebuild must not resurrect retired content.

## 5. Memory approval policy and local scope

Persistent memory is opt-in, project-local, and governed by consumer policy.

* Model-authored content always enters as an untrusted `proposed` record with a
  retained source hash. **Model output is a candidate, not self-authorising
  truth.**
* A record becomes eligible for retrieval only after a separately identified
  authority is verified against a pinned authority document and, where
  configured, pinned code identity. The authority's subject must differ from the
  proposer — a proposer cannot approve its own candidate.
* Consumer policy selects allowed scopes, approver roles, retrieval roles, and
  whether a human rather than an authorised internal reviewer role is required.
* Rejected, quarantined or disputed candidates are retained and labelled; they
  are never silently merged into approved knowledge.
* Host-observed facts keep their own provenance and are not rewritten into a
  universally loaded catalogue.
* Approved knowledge becomes an authored artefact indexed by brain, with
  supersession and tombstone semantics. Deleting and rebuilding the index
  retains legitimate memory and respects tombstones.

```bash
singular memory propose --scope … --source-ref …   # untrusted candidate
singular memory review                             # inspect pending candidates
singular memory approve|reject|quarantine …        # governed decision
singular memory supersede|tombstone …              # retirement
singular memory rebuild                            # rebuild the derived index
```

**Local scope.** Everything is confined to the project:

* No vector store, no separate memory server, no remote embedding service.
* No automatic cross-project ingestion; sources are the configured manifest,
  selected worktree code, configured run records and approved local memory.
* Retrieval is deterministic exact-reference and lexical matching
  (`exact-lexical.v1`) with no third-party runtime dependency.
* `search`, `get`, `explain` and `effective-config` are read-only and work in a
  read-only agent sandbox: they write no cache lock, budget ledger or retrieval
  accounting into `/tmp` or the source tree. Any accounting happens at the host
  invocation boundary.
* Disposable caches are worktree-specific and rebuildable.

## 6. Running the evaluation

Both B5 commands are pure readers, need no paid provider, and write nothing into
the state directories they measure.

```bash
cp -Rp tests/fixtures/context-evaluation /tmp/eval-corpus
node vendor/singular-brain/engine/cli.mjs \
  --config /tmp/eval-corpus/project/brain/singular-brain.config.json gen
singular context evaluate --corpus /tmp/eval-corpus/corpus.json

singular context campaign-report \
  --events .singular-state/events.ndjson \
  --runs .singular-state/runs \
  --interventions .singular-state/rescue-20260910/autonomous-recovery-20260912/operator-interventions.jsonl
```

`evaluate` exits 0 on a match with the corpus' declared metrics, 4 on a measured
deviation (the report is still published), and 2 when the inputs are unusable.
`campaign-report` exits 2 when the event stream or runs directory is absent; a
declared-but-absent optional input is reported as an `absent-input` unknown.

## 7. What this adoption does and does not establish

**Measured.** The labeled corpus metrics and the campaign counters in
[`context-findings.md`](context-findings.md) are direct readings of retained,
hash-identified evidence. On that corpus, superseded, quarantined, wrong-root,
wrong-version and wrong-role sources are excluded or refused with a recorded
reason, mandatory task content preempts optional matches within the budget, and
byte overflow fails loudly rather than silently truncating.

**Inference, labelled as such.** That the host integration gate is the dominant
per-change fixed cost follows from 11 integration-gate durations on one machine
under varying disk pressure. It describes this campaign; it is not a benchmark.

**Not claimed.** This is a single before/after development run with 8
integrations. No causal improvement is attributed to the context or memory
layer, and no general retrieval or delivery reliability is claimed — the sample
cannot support either. Unattended reliability is not merely unproven: the
checkpoint's own bar of three consecutive representative unattended integrations
stands at 0 of 3, and every recent native run is recorded as assisted.

The original TASK-1015 incremental reconciliation obligation remains **pending**;
only the TASK-1112 diagnostics/reconciliation subset is integrated. Do not read
this adoption as covering it.
