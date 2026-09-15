# B5 findings: retrieval evaluation and native delivery efficiency

This report states what was measured, from which retained inputs, and what
remains unknown. Every number below was produced by the two commands in
[Reproducing this report](#reproducing-this-report) against retained evidence
in this repository. Nothing here is an estimate, and nothing here establishes
a causal or general reliability claim.

## Measured inputs and their identities

The campaign analysis was run against these exact inputs. Paths are absolute in
the tool output; they are written here relative to the campaign source root
`/Users/alejandro/Desktop/999. PROJECTS/singular-lite-brain-integration`, which
is the `repositoryRoot` recorded in the rescue checkpoint.

| Input | Path | Identity |
| --- | --- | --- |
| Orchestration events | `.singular-state/events.ndjson` | `sha256:786d488faf37e31790d450145b434ad55772820b28e1f6078170bf980fdea19f`, 24,371,160 bytes, 57,451 parsed lines, 0 unparseable |
| Provider/gate sidecars | `.singular-state/runs/` | directory; 87 distinct `*runner-result.json` sidecars (68 archived byte-identical attempt copies collapsed) and 45 distinct `gate-check.json` reports (22 collapsed) |
| Operator interventions | `.singular-state/rescue-20260910/autonomous-recovery-20260912/operator-interventions.jsonl` | `sha256:35aa3bc385cff9e160a980c71da9ba48506950ea3cf5349b7ba8ec1b346c940b`, 56,189 bytes |
| Rescue checkpoint | `.singular-state/rescue-20260910/checkpoint.json` | `sha256:91d039b5bf015a1a6cea36009f686ca90f4069ab721996d2368aa364a155236a`, 44,351 bytes, schema `singular.rescue.checkpoint.v33` |
| Native snapshot index | `.singular-state/rescue-20260910/native-observations-before-A6.json` | `sha256:704dde08fcdc52575c346424d45428cd13b08875c9e24f0f8cd1d055d1473f45`, 8,663 bytes, schema `singular.rescue.measurement-snapshot.v1` |
| Earlier handoff baseline | `.singular-state/campaign-evidence/operator-observations.ndjson` | 66 retained operator observation records, read for classification context only |

`events.ndjson` is a live append-only stream. The figures below describe the
snapshot identified by the hash above; a later re-run reads a superset and will
report larger counts — the reconcile counters in particular grow with every
control-plane cycle. The two rescue references and the intervention log are
read-only inputs here — this task writes nothing into `.singular-state/`.

Retained run artifacts need both a recursive scan and content deduplication to
be counted correctly. The engine keeps a byte-identical copy of each attempt
under `attempts/<n>/` and stages planner/critic invocations one level below the
run directory. Scanning only the run directory silently drops 2 staged provider
invocations and 11 distinct earlier-attempt gate runs; scanning recursively
without collapsing identical bytes double-counts 68 sidecars and 22 gate
reports. The analyser does both and reports the collapsed counts explicitly.

### Raw identity verification of the snapshot

`native-observations-before-A6.json` names 12 provider sidecars with their
SHA-256. All 12 were located by resolving the recorded relative paths against
the documented campaign source root, re-hashed, and matched: **12 verified, 0
missing, 0 mismatched**. The snapshot is therefore usable as a starting index,
but it is explicitly scoped to "selected native A4/A5 work before A6 maintenance
adoption; not all historical runs or total project usage". The campaign-wide
figures in this report supersede it in breadth, not in authority.

## Part 1 — Labeled retrieval evaluation

The corpus is `tests/fixtures/context-evaluation/corpus.json`
(`sha256:8a170ce6aa80a784e819ca83893fd7f1516ddc0c7596b4cce559193657fb9028`),
18 labeled cases over a project fixture whose brain manifest is produced by the
real vendored `singular-brain` generator at evaluation time. It runs against
the real B2 service through `singular context evaluate` and needs no provider.

| Metric | Measured |
| --- | --- |
| Cases | 18 |
| Inclusion / recall within budget | 14 of 14 expected references included (recall 1.0) |
| Incorrect selections | 0 |
| Budget omissions | 2 (both in the case that declares them) |
| Abstentions | 5 |
| Refusals | 4 |
| Cases returning results | 9 |
| Failures against the declared labels | 0 |

Label coverage, all declared labels present: `exact-fact` 1, `lexical-fact` 1,
`paraphrased-fact` 2, `long-document` 2, `contradictory-sources` 1,
`wrong-version` 1, `wrong-root` 2, `wrong-role` 2, `revoked-source` 2,
`missing-knowledge` 1, `budget-omission` 1, `mandatory-priority` 2.

What the individual cases establish on this corpus:

* An exact identifier (`COBALT-LATCH-4417`) and a lexical phrase both retrieve
  only the current contract. The superseded contract, which contains a
  contradicting rollback rule and matches the same tokens, is never selected;
  it is reported as an omission with reason `ineligible:lifecycle_superseded`.
* A quarantined-on-disk document is neither retrieved by its own unique token
  nor readable by exact reference, even though its front matter still claims
  `status: canonical`. The read is refused with
  `ineligible source reference under B1 policy`.
* A fact 5,275 bytes into a long runbook is reachable: search returns a range
  starting at byte 5,115, and heading pagination returns the section directly.
* A wrong-version read is refused by hash comparison, not silently re-pointed
  at the current bytes.
* With a configuration whose `sourceRoot` points at the wrong directory, every
  brain document resolves as `missing` and the query abstains — it does not
  fall back to a partial answer. A code path escaping the workspace is refused
  outright at `containment:`.
* A run record retrieved by an implementer is withheld from a review role even
  though the fixture's `rolePolicy` deliberately grants `run` to `auditor`. The
  service's hard trust boundary, not the configuration, is what holds.
* A paraphrase of the contract's own heading ("rollback latch requirement for
  migrations") retrieves the contract with an `exact_phrase` bonus, and also
  retrieves the code and run sources that share three of its five tokens —
  above `exact-lexical.v1`'s half-coverage threshold. A paraphrase sharing no
  tokens at all ("undo mechanism semantics") abstains explicitly. That is a
  property of the retrieval version, not evidence that the knowledge is absent;
  the corpus labels the second case as a documented limit.
* Mandatory content wins the budget: the task contract and the open obligation
  from the run record are emitted before any optional match, and a 100-byte
  budget produces `mandatory-overflow` rather than a truncated prompt.

**These numbers describe this fixed 18-case corpus only.** They are not a
reliability estimate for retrieval in general, and a single corpus cannot
support one.

## Part 2 — Campaign delivery analysis

All counters below come from the retained event stream and sidecars identified
above. Failed, superseded and setup work is included. These are observed
counters of the retained stream, **not total project usage**.

### Tasks

* Dispatched: 24 — TASK-1001, 1003, 1004, 1009, 1010, 1011, 1013, 1017, 1019,
  1022, 1101, 1102, 1103, 1104, 1105, 1106, 1107, 1108, 1109, 1111, 1112, 1113,
  1116, 1117.
* Integrated: 8 — TASK-1001, 1009, 1101, 1103, 1109, 1112, 1113, 1117.
* Accepted by an L1 driver: 11. The three acceptances that were never
  integrated — TASK-1003, TASK-1010, TASK-1011 — each have a retained
  `recovery.action` recording "post-merge regression gate red (exit 1)", with
  strategies `retry`, `split-task` and `split-task` respectively.
* Unfinished (dispatched, never integrated): 16 — TASK-1003, 1004, 1010, 1011,
  1013, 1017, 1019, 1022, 1102, 1104, 1105, 1106, 1107, 1108, 1111, 1116.
* Ended terminal without acceptance at least once: 14. This overlaps
  `integrated`: TASK-1113 and TASK-1117 each have a terminal attempt in their
  history and a later accepted, integrated one. The counter is per event, not
  per task outcome.

### Retries and refused work

| Counter | Observed |
| --- | --- |
| Worker infrastructure retries | 5 |
| Evidence infrastructure retries | 2 |
| Attempts archived | 37 |
| Product-repair budget consumptions | 13 |
| Dispatch reservation refusals | 28 |
| Provider invocations with a non-`none` failure class | 15 |

### Latency

| Measure | Observations | Min | Mean | Max | Total |
| --- | --- | --- | --- | --- | --- |
| Ready-to-dispatch wait (s) | 126 | 9.0 | 65.18 | 1,349.0 | 8,213.0 |
| Worker-completion to gate completion (s) | 34 | 3.0 | 97.44 | 269.0 | 3,313.0 |

Ready-to-dispatch wait is defined as the elapsed time from the origin reconcile
that admitted the task to the `origin.dispatch` event of the same origin run.
It is a control-plane admission latency, not queue age from task authorship;
the event stream carries no "task became ready" transition to measure from, so
queue age is **unknown**.

Host gate durations come from the `durationMs` field of the retained gate
reports:

| Workspace | Reports | Min | Max | Total |
| --- | --- | --- | --- | --- |
| Worker gate | 34 | 2,184 ms | 267,164 ms | 3,279,395 ms (~54.7 min) |
| Integration (host) gate | 11 | 74,540 ms | 1,303,370 ms | 6,011,599 ms (~100.2 min) |

The host integration gate is the dominant fixed cost per accepted change: 11
integration runs consumed about 1.83× the wall-clock of all 34 worker gates
combined. Per run that is a mean of 546,509 ms (~9.1 min) for an integration
gate against 96,453 ms (~1.6 min) for a worker gate — about 5.7× — on a
sample of 11 and 34 runs respectively, on one machine, under varying disk
pressure.

### Control-plane work

| Event | Count |
| --- | --- |
| `origin.reconcile_started` / `origin.reconcile_completed` | 928 / 928 |
| `origin.control_state_committed` | 59 |
| `origin.control_state_deferred` | 178 |
| `recovery.action` | 26,234 |
| `integration.campaign_mismatch` | 26,226 |
| `origin.reservation_refused` | 28 |

The two large counters are not 26k distinct incidents. Broken down by strategy,
the 26,234 recovery actions are 26,227 `re-audit-current-campaign` plus exactly
7 others (4 `rebuild-context`, 2 `split-task`, 1 `retry`). The 26,227 cover 116
distinct task ids, and the 26,226 `integration.campaign_mismatch` events cover
115 — that is one standing condition per retained cross-campaign packet,
re-emitted per reconcile cycle while it stood, averaging about 226 emissions
per task. It is a real measured cost of the control plane and it dominates the
event stream by volume, but it is repetition of standing conditions, not 26k
separate failures. Attributing it to any particular defect is outside what the
retained stream shows.

### Review cost

| Measure | Observed |
| --- | --- |
| Audit verdicts | accepted 11, needs-fix 14, blocked 2 |
| Retained review context bundles | 5 |
| Review context prompt bytes | 185,657 |
| Bytes per accepted review | 16,877.9 |

**Bytes per accepted review is a lower bound over a covered subset, not a
complete rate.** Context bundles were only recorded from B3 onward, so 5
retained review bundles cover 11 accepted reviews. The analyser reports this
explicitly as a `review-context-coverage` unknown rather than presenting the
quotient as a complete per-review figure.

### Provider counters by role

Totals are sums of the retained sidecars' own counters. Cumulative input and
cached-input are provider invocation counters. **They are not context
occupancy, not unique source bytes, and not money.**

| Role | Sidecars | With usage | Without usage | Input | Cached input | Output |
| --- | --- | --- | --- | --- | --- | --- |
| implementer | 45 | 38 | 7 | 174,860,246 | 183,296,390 | 928,417 |
| auditor | 31 | 30 | 1 | 24,879,584 | 24,149,458 | 214,298 |
| planner | 6 | 6 | 0 | 2,976,262 | 2,467,840 | 20,342 |
| decider | 4 | 4 | 0 | 89,662 | 43,520 | 739 |
| critic | 1 | 1 | 0 | 1,043,274 | 929,024 | 8,448 |

**The per-role totals for `implementer` and `auditor` are not comparable
quantities.** Both roles span two providers whose `cachedInputTokens` mean
different things, which is why `implementer` shows more cached input than input
at all. Measured per provider:

| Role | Provider | Sidecars | Input | Cached input | Output |
| --- | --- | --- | --- | --- | --- |
| implementer | codex | 40 (33 with usage) | 174,860,016 | 170,807,808 | 788,192 |
| implementer | claude | 5 | 230 | 12,488,582 | 140,225 |
| auditor | codex | 28 | 24,879,544 | 22,885,632 | 187,572 |
| auditor | claude | 3 (2 with usage) | 40 | 1,263,826 | 26,726 |

`planner`, `decider` and `critic` are single-provider (`codex`) and their role
totals are therefore comparable as stated.

The `codex` sidecars report cached input as a subset of input (e.g. 22,992 /
12,160). The `claude` sidecars report a separate cache-read counter with a
near-zero uncached input (e.g. 76 / 3,231,199). Summing them yields a number
with no single meaning. The analyser emits a `mixed-provider-token-semantics`
unknown for each affected role and publishes the per-provider split as the
measured figure. Any future cost or efficiency comparison must use the
per-provider rows, not the role totals.

### Operator interventions

84 intervention records are retained. **0 of them claim unattended credit.** 3
occurred during a qualifying sequence and 4 are recorded as rescuing or
advancing a required transition. Interventions are counted separately from
native delivery throughout this report and are never credited as uninterrupted
native transitions.

The checkpoint records the same distinction independently:
`unattended.currentConsecutiveIntegrations` is **0** against a required 3, and
`currentSequenceStatus` is "closed for supervised B4 product recovery after
second needs-fix". TASK-1110 is direct maintenance under the supervisor's own
authority; it is not native autonomy credit and is not counted as one here.
TASK-1116 and TASK-1117 are recorded in the checkpoint as "assisted"
(`provenance: "assisted; no unattended credit"`), so they likewise do not
establish unattended delivery.

Three delivery provenances are kept apart and must not be merged:

1. **Direct Codex/Claude supervision** — the supervisor diagnosing, repairing
   and adopting engine changes directly. Recorded in the intervention log.
2. **Local fixtures** — frozen-campaign and canary receipts that exercise the
   host path without a live provider sequence.
3. **Uninterrupted native transitions** — a dispatch that runs to acceptance and
   integration with no intervention in between. The retained evidence shows
   **0 consecutive such transitions** at the snapshot read.

### External maintenance and review usage

The checkpoint records some external maintenance/review usage directly, and it
is reproduced here as observed rather than recomputed: `wu2_review` round 1 was
"Opus 5, 55 turns, 53 min, $6.43" and round 2 "Opus 5, 38 turns, 22 min,
$2.49"; the parked TASK-1117 attempt `RUN-20260914T151954Z-17409` is recorded at
"$0.68"; the Opus implementer probe at "$0.479624, 2 turns, 6.4 s". These are the
only monetary figures in the retained evidence. **There is no retained total for
external maintenance/review usage across the campaign, so the total is unknown.**
Cumulative token counters cannot be converted into it.

## Explicitly unknown

The analyser reported 14 unknowns at this read, in 6 kinds:

| Kind | Count | Meaning |
| --- | --- | --- |
| `runner-result-without-usage` | 8 | retained sidecars with no usage counters — unknown, not zero |
| `mixed-provider-token-semantics` | 2 | `implementer` and `auditor` span providers with different cached-input semantics |
| `review-context-coverage` | 1 | 5 retained review bundles cover 11 accepted reviews |
| `provider-monetary-cost` | 1 | sidecars record tokens only |
| `provider-served-tier` | 1 | requested speed is recorded; provider-observed service tier is not |
| `context-occupancy` | 1 | cumulative input/cached input is not context occupancy |

Beyond the analyser's own list, the following remain unknown and were not
estimated: queue age before control-plane admission; host suspension and
wall-clock gap causes; direct maintenance agent usage totals; the
provider-observed service tier for every invocation; and the counters of any
run whose evidence was destroyed by the 2026-09-14T14:57:37Z host reboot
recorded in the checkpoint (`nativeRuns[1].outcome`: HOST-INTERRUPTED, "no
provider result or acceptance exists for this run").

## Measured improvement versus inference

**Measured.** All of the following are direct readings, not inferences:

* The labeled corpus metrics in Part 1, reproducible from a clean checkout.
* Every counter in Part 2, from the hash-identified inputs.
* Superseded, quarantined, wrong-root, wrong-version and wrong-role sources are
  excluded or refused by the service on this corpus, with a recorded reason in
  every case.
* Mandatory task contract and open obligations preempt optional matches within
  the byte budget, and overflow fails loudly.

**Inferred, and labeled as such.** The host integration gate being the dominant
per-change fixed cost follows from the duration totals, but the sample is 11
integration gates on one machine under varying disk pressure; it is a reading of
this campaign, not a benchmark. Likewise, the 26k repeated campaign-mismatch
emissions are measured, while any claim about which change would reduce them is
inference.

**Not claimed.** This campaign is a single before/after development run with 8
integrations. No causal improvement is attributed to the brain/context/memory
layer, and no general retrieval or delivery reliability is claimed. The
checkpoint's own qualification bar — three consecutive representative unattended
integrations with a dependency chain and a genuine review correction — stands at
0 of 3, so unattended reliability is not merely unproven, it is explicitly not
yet demonstrated.

## Retained obligation status

The original TASK-1015 incremental reconciliation obligation is **pending, not
complete.**

* Integrated: `engine/reconcile_index.py` and the reconciliation/diagnostics
  subset delivered by TASK-1112
  (merge `414deeace06b27f798fa2acd6281393ba8b684ca`, recorded in the
  checkpoint's `outcomes.integrated`).
* Not integrated: the discovery and scaling obligations of
  `docs/orchestration/brain-tasks/TASK-1015.md` — event-driven dirty discovery,
  the fair bounded retained-artifact sweep, and per-entry dependency
  invalidation. These are carried by
  `docs/orchestration/rescue-tasks/TASK-1114.md`, whose status is `ready` and
  which depends on TASK-1106. Its gate command requires
  `tests/test-incremental-reconcile.sh`, which does not exist in this tree.

No measured evidence for that obligation is presented here, because none exists
yet. It is reported as pending.

## Reproducing this report

Both commands are pure readers, need no paid provider, and write nothing into
the state directories they measure.

```bash
# Part 1 — labeled retrieval evaluation (regenerate the manifest in a scratch
# copy first; the committed fixture holds the sources, not the generated
# manifest).
cp -Rp tests/fixtures/context-evaluation /tmp/eval-corpus
node vendor/singular-brain/engine/cli.mjs \
  --config /tmp/eval-corpus/project/brain/singular-brain.config.json gen
singular context evaluate --corpus /tmp/eval-corpus/corpus.json \
  --output /tmp/evaluation-report.json

# Part 2 — campaign analysis of retained evidence.
singular context campaign-report \
  --events .singular-state/events.ndjson \
  --runs .singular-state/runs \
  --interventions .singular-state/rescue-20260910/autonomous-recovery-20260912/operator-interventions.jsonl \
  --checkpoint .singular-state/rescue-20260910/checkpoint.json \
  --observations .singular-state/rescue-20260910/native-observations-before-A6.json \
  --output /tmp/campaign-analysis.json
```

`singular context evaluate` exits 0 when the measured metrics match the corpus'
declared metrics, 4 when they deviate (the report is still published), and 2
when the inputs are unusable. `singular context campaign-report` exits 2 when
the event stream or runs directory is absent, because there is then nothing
measured to report; a declared-but-absent optional input is reported as an
`absent-input` unknown instead.

Adoption, activation and rollback are documented separately in
[`context-adoption.md`](context-adoption.md).
