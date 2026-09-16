# Host-managed invocation admission, accounting and provider conformance

TASK-1115. This document is the owned record of what the host actually
enforces at the provider invocation boundary, what it only measures, and what
it cannot observe at all. Everything here describes fixture-observed behavior
of the integrated context service and host evidence delivery. Nothing here is
a runtime-adoption claim, an operational readiness claim, or evidence that an
unattended campaign completed.

## 1. The host-bound invocation envelope

Every admitted invocation publishes exactly one envelope
(`singular.context.envelope.v1`), carried on the immutable context bundle and
on the host delivery receipt, and mirrored into the `context.bundle_selected`
event. It binds:

| Binding | Source |
| --- | --- |
| `taskContractSha256` | SHA-256 of the exact task/DAG contract bytes read for this invocation |
| `role`, `phase` | the invocation role and phase, identical to the bundle identity |
| `runId`, `attemptId`, `sessionId` | host run, attempt/try, and provider session when known |
| `candidateRevision`, `worktree` | the candidate worktree revision and path the bundle was built from |
| `requestedModel`, `effectiveModel` | requested vs. observed provider model; these are distinct fields and are never conflated |
| `providerName`, `providerExecutable`, `providerBuild` | the adapter actually launched and its build when observable |
| `capabilityProfile` | the runner capability profile for this role |
| `policyVersion`, `policySha256` | the effective context policy identity |
| `sourceVersions`, `sourceVersionsSha256` | every configured source ref, hash and validity |
| `campaignBinding` | the verified frozen campaign identity |
| `bundleSnapshotId` | the immutable bundle snapshot this prompt came from |

An identity the host does not know is preserved explicitly as `null` and named
in `unknownBindings`. It is never dropped, and never reported as `0` or `""`.
`sessionId` and `providerBuild` are genuinely unknowable at some supported
entrypoints, so they stay unknown without blocking admission. Every other
binding is required under strict admission: with
`SINGULAR_INVOCATION_ENVELOPE_STRICT=1`, an unavailable required binding is a
deterministic refusal (`envelope-binding-unavailable`) that happens **before**
the provider is launched and before any retrieval is charged.

Both strict schema copies (`schemas/context-bundle.v1.schema.json` and
`schemas/orchestration/context-bundle.v1.schema.json`) are byte-identical and
declare `envelope` as an **optional** top-level property, so bundles retained
before this extension still validate unchanged. No historical bundle is
rewritten and no existing constraint was relaxed.

## 2. Separated accounting

`budget.accounts` partitions the delivered prompt. Every delivered byte is
charged exactly once, to exactly one account:

- `mandatoryTaskPolicyBytes` — task/planning contract, open/violated
  obligations, revocation notices and policy framing.
- `requiredEvidenceBytes` — complete host-delivered review evidence.
- `optionalSelectedBytes` — selected code/documents/approved memory actually
  admitted into the remaining allowance.
- `visibleHistoryBytes`, `toolSkillContentBytes`, `providerSystemBytes` —
  provider-supplied components. These are **`null`**: missing is unknown, never
  zero.

`budget.measurement` states units and identity: `unit` is `utf8-bytes`, the
estimator identity is `utf8-exact.v1` (exact host-composed bytes, not an
estimate), `tokenizer` is `null` because no supported provider build exposes
one to the host, `coverage` is `host-composed-prompt-only`, and `overlapRule`
records the exactly-once partition. `providerObservableBytes` is `null`.
Cumulative input and cached-input usage reported by a provider turn is neither
instantaneous context occupancy nor money, and is recorded as such.

`budget.outputReserve` records the requested reserve verbatim. A reserve
declared in `utf8-bytes` is exact host accounting and is subtracted from the
byte allowance. A reserve declared in `tokens` has **no** declared supported
byte conversion for any provider Singular launches, so `conversion` is `null`,
`reservedBytes` is `null` and `appliedToByteLimit` is `false`: a token reserve
is never subtracted from a byte limit.

## 3. Admission

Admission runs before provider launch, on the final composed bytes, against
every applicable existing cap (the policy budget, the composed final cap, and
the declared reserve). Mandatory content plus a required reserve that cannot
fit is an explicit pre-invocation refusal: `mandatory-overflow`, or
`mandatory-reserve-overflow` when the reserve is what makes it unaffordable.
Optional content is admitted deterministically in declared order into the
remaining allowance; each optional selection records its `selectionOrder`,
truncation flag, source byte range and an `excerptSha256` over the delivered
bytes. Optional overflow is recorded as an optional `aggregate_byte_budget`
omission and is never relabelled as mandatory overflow.

The full task contract and open/violated obligations are retained at planner,
first-worker, retry and auditor assembly. A task-path reminder is not
sufficient and is not used.

## 4. Finite provider support matrix

Rows are the declared control set; `support` is the host-verifiable state and
`evidence` is how it was established. `fixture-argv` means the host observed
the composed argv/stdin and the delivered bytes in a local fixture.
`unverified` means no local non-billable evidence establishes the control; it
is **not** reported as a pass.

| Control | codex / openrouter | claude |
| --- | --- | --- |
| Initial prompt control | supported (fixture-argv) | supported (fixture-argv) |
| Host-broker retrieval | supported (fixture-argv) | supported (fixture-argv) |
| Resume/history inspection | unknown (unverified) | unknown (unverified) |
| Resume/history removal | unsupported (unverified) | unsupported (unverified) |
| Visible tool/skill content | unknown (unverified) | unknown (unverified) |
| Output control | unsupported (unverified) | unsupported (unverified) |
| Usage observation | partial (fixture-argv) | partial (fixture-argv) |

The machine-readable source of this table is
`engine/capability_policy.py::PROVIDER_CONTEXT_CONTROLS`;
`tests/test-invocation-context-budget.sh` refuses any divergence between the
code and this document's rows.

Provider probes are local, non-billable `--version`/`--help` reads only. No
paid fixture call and no browser probe was made. In this host environment the
probe records whichever CLIs are present; an absent CLI is pinned as
`unverified`.

## 5. Where the managed boundary is guaranteed — and where it is not

The host guarantee is scoped to `host-composed-prompt`, plus host-mediated
evidence retrieval charged to the durable ledger. A strict whole-provider
context guarantee is **refused** for every declared provider, with named
coverage gaps: resume/history inspection, resume/history removal, visible
tool/skill content, output control and usage observation. A configured output
reserve is not proof of a provider-enforced output cap. No claim is made about
universal provider context occupancy, provider history deletion, or remote
memory control.

## 6. Session reuse

Before reusing a retained provider session, the host compares the current
authorization/model/provider/policy/capability envelope binding
(`SINGULAR_INVOCATION_ENVELOPE_BINDING`) with the binding retained alongside
the session. A difference means unauthorized historical content cannot be
verifiably removed, so the resume is refused: `codex-run.sh` exits 86 without
launching the provider, and `singular_session_resume_decide` returns
`fresh envelope-changed` so the host reconstructs a fresh authorized
invocation. An identical retained binding still resumes — the gate is a
comparison, not a blanket refusal. A warning to ignore revoked history is not
used as a substitute.

## 7. Measurements, failed attempts and absent observations

- Focused gate (this task's declared nine members) — see the packet evidence
  for the exact commands and their raw logs.
- `tests/test-invocation-context-budget.sh` runs the directly coupled Python
  cases, both schema-copy conformance checks, the capability-matrix
  conformance check, this document's row check, and the local non-billable
  provider probe.
- Postimplementation fixture/campaign analysis reuses B5's evaluator
  (`tests/test-context-evaluation-e2e.sh`, `singular context evaluate` /
  `campaign-report`). B5's evaluator was not modified to produce a second
  report format.
- Absent observations: no provider-observable prompt byte count, no tokenizer
  identity, no provider-side history enumeration, no provider-enforced output
  cap. These stay `null`/`unverified` rather than being estimated.
- Host-failure backlog (pre-existing, re-verified on the untouched base tree,
  not introduced here): `test-capability-runtime.sh` legacy cursor-agent
  compatibility case and `test-session-affinity.sh`.
- The complete canonical host suite on the final exact integration tree is a
  separate handoff obligation. It has not been run here, and the focused gate
  does not stand in for it.

Fixture success is not runtime adoption, is not an operational claim, and is
not evidence of unattended completion.
