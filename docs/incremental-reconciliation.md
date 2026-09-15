# Incremental reconciliation discovery

`engine/reconcile_index.py` decides one thing: whether the canonical
integrator has to look at retained work this cycle, and which task identities
are worth looking at. It grants nothing. Every final candidate, audit, scope,
source, secret, campaign and exact-tree check stays in `engine/integrate.sh`,
uncached, and runs on every candidate the integrator actually examines.

This replaces the previous global all-or-nothing rediscovery, in which any
change anywhere forced a full canonical pass over every historical entry.

## What the index observes

Three bounded observers feed one deduplicated dirty set.

**The retained event stream**, through a persistent byte cursor. Only
*arrival* events mark a task dirty — by default the `packet.`, `task.`,
`lease.`, `l1.`, `l2.`, `worker.`, `candidate.` and `audit.` families
(`SINGULAR_RECONCILE_DIRTY_EVENT_PREFIXES` overrides the list). Reconcile and
integrate also emit events as *consequences* of the canonical pass they just
ran (`origin.*`, `integration.*`, `recovery.*`, `decision.*`, `reconcile.*`);
treating those as new causes would make every cycle dirty forever. The stream
is only an accelerator — the sweep below, not the stream, is what guarantees
completeness, so a conservative allowlist cannot hide work.

**An independent fair sweep** of the retained task, packet, audit and lease
locations, with a persistent directory/entry cursor. Directory discovery is
itself bounded: the sweep opens at most `--max-sweep-dirs` directories and
examines at most `--max-sweep-entries` directory entries per cycle, resuming
exactly where it stopped. Subdirectories found mid-pass join that pass's
frontier rather than restarting it.

**Dependency identity**, split into shared and per-candidate parts. The shared
part is the target branch head, the gate policy/source and the campaign/epoch.
The per-candidate part is the accepted packet's branch, its candidate ref
(resolved through `for-each-ref`, so packed refs count), and the availability
of the audited commit and tree (one `cat-file --batch-check`). Two git
subprocesses per cycle, regardless of corpus size.

## Content identity, not mtime

Each swept artifact is hashed in fixed-size blocks (`--hash-block-bytes`). Its
content identity is a digest over the size and the ordered block digests, so a
same-size, timestamp-preserving replacement is still discovered. Stat identity
(device, inode, size, mtime) is recorded but never decides on its own.

Block hashing is resumable. An artifact larger than the whole per-cycle byte
budget is hashed across cycles: its completed block digests and byte offset are
retained, and it resumes on the next cycle instead of forcing one unbounded
read. Per-cycle hashed bytes never exceed `--max-sweep-bytes`, except that the
first artifact of a cycle is always granted one block so an oversized artifact
advances rather than stalling the pass forever.

## The revisit bound

A sweep pass starts at the retained roots and ends when the frontier is empty.
Entries not seen during a completed pass are treated as removed. Every plan
reports `sweep.revisitBoundCycles`, an upper bound in cycles on finishing the
current pass:

```
ceil(remainingEntries / maxSweepEntries)
  + ceil(deferredBytes / maxSweepBytes)
  + 1
```

For a fixed retained population of `P` entries and a per-cycle entry budget of
`E`, a pass completes in at most `ceil(P / E) + 1` cycles. Continuous arrivals
do not restart the pass and do not starve it: the sweep budget is independent
of the event budget, so an unbounded stream of events cannot consume the
cycle's directory-entry or byte allowance, and new artifacts are visited within
the same pass when they fall ahead of the cursor or in the next pass otherwise.

Two things extend the bound, and both are reported rather than hidden:

* **Oversized artifacts.** An artifact of `B` bytes adds up to
  `ceil(B / maxSweepBytes)` cycles to the pass. `sweep.oversizedDeferred`
  counts artifacts carried into the next cycle.
* **Changing populations.** Arrivals during a pass are visited in that pass
  when they sort after the cursor, which raises `P` for that pass only. A
  population that grows faster than `E` per cycle lengthens each pass
  proportionally; it never resets the cursor.

`sweep.remainingEntries` and `sweep.population` are reported every cycle, so a
lengthening pass is observable from `singular health` without inference.

## Per-entry dependency invalidation

Discovery outcomes — positive and negative alike — are cached per entry, keyed
by that entry's own identity. An unrelated local change dirties only its own
task: `dirtyTasks` names exactly the affected identities.

A genuinely shared change may invalidate every affected entry. Moving the
target branch, changing the gate policy/source, or changing the campaign/epoch
dirties every known task at once. That is correct, and the work stays bounded
and fair: the canonical pass runs once, and the sweep's per-cycle directory,
entry and byte limits are unchanged.

## Plan versus acknowledgement

`plan` observes and proposes. `commit` acknowledges. Only `cycle` and the
deduplicated diagnostic ledger become durable during `plan`; the observed
snapshot is written as a pending proposal.

`reconcile.sh` acknowledges at the existing end-of-actuation boundary, after
the complete actuate transaction has published its task, lease and
control-state effects. If that boundary is interrupted, the old baseline stands
and the next cycle replays canonical discovery; the integrator's durable guards
keep the replay from duplicating publication.

`commit` promotes exactly what `plan` observed. It does not re-read the corpus,
because re-reading would silently swallow a change that arrived while the
caller was publishing. Two identities are taken at acknowledgement time
instead, and only these:

* the target head, gate policy and campaign this actuation itself published
  under the origin lock; and
* the retained artifacts of the task identities this cycle's canonical pass
  actually validated, re-observed from the integrator's receipt.

The origin lock is held for the whole actuation, so the only writer of those
identities during it is the transaction being acknowledged. Everything else
stays at the identity `plan` observed, so an independent change racing the
acknowledgement is still discovered by the next sweep.

## Recovery

| Condition | Behavior |
| --- | --- |
| Index missing | `missing-index`; full canonical discovery; no filtered selection |
| Index corrupt | `corrupt-index`; full canonical discovery; no filtered selection |
| Index written by a superseded discovery schema | `outdated-index`; treated as a cold start, rebuilt from retained authority; not an attention item |
| Index carries acceptance-granting keys | `forged-index`; the keys are discarded, never read as data |
| Event stream truncated, rotated or replaced | `event-cursor-discontinuity`; cursor resets to 0; full canonical discovery |
| Duplicate events | deduplicated into one dirty task identity |
| Event backlog beyond `--max-events` | reported as `events.backlogBytes`; the filtered selection is withdrawn |
| Interruption before acknowledgement | the old baseline stands; canonical work replays; publication is not duplicated |
| Any unexpected error in `plan` | `index-error`; full canonical discovery |

In every case the fallback is *more* canonical work, never less. The index
cannot fabricate eligible work or durable acceptance: `plan` emits no
candidate, verdict or acceptance field, and any such key found in retained
state invalidates the whole index.

## Discovery selection

When a filtered selection is offered, `reconcile.sh` passes
`integrate.sh --dirty-tasks FILE`. A selection is offered only from an
observation that is complete, quiet and acknowledged — a loaded, healthy index,
no event-cursor discontinuity, an empty event backlog, at least one
acknowledged baseline sweep pass, and no periodic rediscovery due. The periodic
`--full-scan-every` rediscovery withdraws the selection on schedule, so nothing
stays hidden even if the index is wrong. Tasks the selection names still go
through the complete uncached canonical path.

## Activation and fallback

The index is on by default and is disabled with `SINGULAR_RECONCILE_INDEX=0`,
which runs the same production `integrate.sh` over full canonical discovery.
That path is preserved for comparison and as the fallback; the fixture runs
both modes against the same pinned corpus and requires them to agree on
eligible and deferred outcomes.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SINGULAR_RECONCILE_INDEX` | `1` | `0` disables discovery entirely |
| `SINGULAR_RECONCILE_INDEX_FILE` | `.singular-state/reconcile-index.json` | retained discovery state |
| `SINGULAR_RECONCILE_FULL_SCAN_EVERY` | `20` | cycles between unfiltered canonical rediscoveries |
| `SINGULAR_RECONCILE_MAX_EVENTS` | `512` | events consumed per cycle |
| `SINGULAR_RECONCILE_SWEEP_ENTRIES` | `512` | directory entries examined per cycle |
| `SINGULAR_RECONCILE_SWEEP_DIRS` | `64` | directories opened per cycle |
| `SINGULAR_RECONCILE_SWEEP_BYTES` | `8388608` | content bytes hashed per cycle |
| `SINGULAR_RECONCILE_HASH_BLOCK_BYTES` | `1048576` | resumable hash block |

Deleting `SINGULAR_RECONCILE_INDEX_FILE` is a safe rollback: the next cycle
reports `missing-index` and rebuilds from retained authority.

## Diagnostics and health

A condition is emitted when it is first observed and when it resolves; an
unchanged `(reason, dependency identity)` pair is suppressed and counted in
`suppressedDiagnostics`. Emitted conditions reach the retained event stream as
`reconcile.index_diagnostic`.

`singular health` (and `--json`) exposes `reconcileIndex`: presence, health and
reason, cycle, entry count, event backlog in bytes, sweep pass, remaining
entries, pass completion and whether an acknowledgement is pending. A missing
index is a safe cold start and is not an attention item; a present but unusable
one is. Cache state is reported, never treated as authority.

## Receipts

Each cycle writes `reconcile-receipt.json` (override with
`SINGULAR_RECONCILE_RECEIPT_FILE`) with separated sections:

* `sweep` — directory entries scanned, directories opened, files hashed, bytes
  hashed, oversized deferrals, pass, remaining entries, revisit bound, elapsed;
* `rebuild` — indexed entries, discovery subprocesses, reasons, elapsed;
* `events` — events read, bytes read, backlog bytes, unparseable lines,
  discontinuity;
* `canonical` — canonical scans, subprocesses, **historical eligibility
  validations and final authority checks measured inside `integrate.sh` at the
  points where the cost is actually paid**, integrations and failures;
* `controlPlane` — reconcile's own control-state, snapshot and event writes,
  kept separate from sweep and canonical work;
* `corpus`, `limits`, `platform`, `uncertainty`.

`integrate.sh` appends one record per expensive boundary to
`SINGULAR_INTEGRATION_RECEIPT_FILE` when it is set, so a receipt cannot be
satisfied by counting canonical invocations alone.

The existing TASK-1106 evaluator consumes the receipt as a declared observation
input; no second reporting service exists:

```
python3 engine/context_cli.py campaign-report \
  --events .singular-state/events.ndjson \
  --runs .singular-state/runs \
  --observations .singular-state/runs/<RUN>/reconcile-receipt.json
```

Elapsed milliseconds are wall clock on a shared host and are not controlled for
unrelated load. The receipt states counts for the corpus it observed. It
asserts no performance target, no rate, no expected improvement, and no token
or monetary figure.

## What this task's evidence does and does not establish

`tests/test-incremental-reconcile.sh` exercises the real
`reconcile.sh --actuate` path into the production `integrate.sh` on a local
fixture with no provider calls. It establishes that, on that fixture, an
externally unchanged cycle following a completed baseline performs zero
measured historical eligibility validations and zero final authority checks,
across a complete sweep pass, including for a retained nonterminal entry whose
candidate branch is missing, and with no eligible dispatch work present.

It does not establish B1 completion, runtime adoption, operational improvement
or unattended delivery. Host-only checks remain unrun until the host performs
them; fixture results are not native acceptance. The complete canonical host
suite on the final exact integration tree remains a separate, pending
obligation before campaign delivery.

TASK-1009 at `3a47a736` and its historical 214/214 evidence, the
TASK-1010/TASK-1011 recovery, the B1–B3 integration, the subsequent B4/B5 work
and all unsuccessful attempts remain retained and unchanged by this task.
