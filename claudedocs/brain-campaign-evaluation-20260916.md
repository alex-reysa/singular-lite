# Brain rescue campaign — measured evaluation

Campaign `BRAIN-RESCUE-20260910` on the Singular engine, runtimes A9 → A15B,
2026-09-10 → 2026-09-16. Every number below is read from
`.singular-state/events.ndjson`, the per-run `*runner-result.json` files and
their provider envelopes, and the review ledger (`wu9/evaluation/metrics.json`
is the raw extract). Where an observation is missing it is said to be
missing; nothing is inferred from a single before/after run.

## 1. What was delivered

| Node | Task | Result | Released |
|---|---|---|---|
| B1 package + ingest | TASK-1101 | accepted, integrated 09:18 (46 min dispatch→integration) | 0.22.0 |
| B2 context service | TASK-1103 (after 1102) | needs-fix ×1 then accepted; integrated in 24 min | 0.22.0 |
| B3 invocation coverage | TASK-1113 (successor of 1104) | accepted; integrated in 101 min incl. one audit-infra retry | 0.22.0 |
| B4 reviewed memory | TASK-1117 (successor of 1105 → 1116) | accepted on exact source, no blocking finding; integrated in 104 min | 0.22.0 |
| B5 evaluation harness | TASK-1106 | accepted; integrated after a 100-min integration refusal (see §4) | 0.22.1 |
| Reconciliation discovery | TASK-1114 | worker candidate (81 min, 8 owned files, +1,918/−483) parked on two packet-format slips; adopted under supervisor provenance, exact-source qualified: gate 5/5, audit **accepted** (1 P2 + 3 P3 backlog), integrated 21:02Z | unreleased (on `codex/brain-integration`) |
| Invocation admission | TASK-1115 | single attempt (20 min, +1,119 lines) cut off by the account's Claude session limit; partial candidate fails 4/9 gate members; **parked**, WIP preserved on its branch | — |

Releases: **0.22.0** (`49cb3d37`, tag `v0.22.0`) and **0.22.1** (`e57feb13`,
`v0.22.1`) on the public repository; installed as the machine's current
engine. Full regression on the release tree: 228 pass / 16 fail, all 16
pre-existing and re-verified on the untouched A14 source.

Final host regression on the tree with TASK-1114 integrated (`0918341`,
245 scripts, 8 jobs, 2026-09-16 07:44–08:20Z): **228 pass / 15 pre-existing
failures**; two additional failures in that run (`test-console-cli`,
`test-setup`) were disk-exhaustion artifacts and pass on rerun. A16 was
built from that tree (1,178 blobs verified immutable), qualified by live
canary and re-published gates, and is the active campaign runtime.

## 2. Provider spend and usage (whole campaign, 96 invocations)

| Provider / role | Calls | Succeeded | Cached input | Output | Cost |
|---|---|---|---|---|---|
| codex (gpt-6-astra) / implementer | 40 | 33 | 170.8 M | 788 k | quota, $0 marginal |
| codex / auditor | 28 | 28 | 22.9 M | 188 k | quota |
| codex / planner | 5 | 5 | 2.3 M | 17 k | quota |
| codex / decider | 4 | 4 | 44 k | 0.7 k | quota |
| claude (opus-5) / implementer | 12 | 6 | 58 M | 546 k | **$59.34** |
| claude / auditor | 7 | 6 | 2.3 M | 62 k | **$7.02** |

Claude implementer cost (total **$66.36** across the campaign, $17.38 of it
after the 2026-09-15 20:05Z authorization) is dominated by: B5 ($15.63,
35 min, 130 k output tokens), the two TASK-1114 one-hour timeouts ($15.15,
~147 k output tokens, zero source edits), the productive TASK-1114 worker
($3.19, 81 min under the 3 h clock) plus its exact-source qualification
($4.17), and the TASK-1115 attempt ($9.58) killed by the session limit.
**Productive Claude spend for B4 + B5 + 1114: ~$28; lost to environment
(session limits ×3, reboot, timeouts, packet slips): ~$38.**

The Codex phase (Sep 10–13) integrated B1–B3 at zero marginal cost until
the account's usage limit tripped on 2026-09-14 16:32Z (reset Sep 19); no
credits were bought and the intelligence roles were moved to Claude.

## 3. Cycle time and rounds

Healthy path, no intervention: **16–47 min dispatch → integration**
(TASK-1112 16 min, TASK-1103 24 min, TASK-1109 24 min, TASK-1101 46 min),
with one worker pass of 6–35 min, a host gate of seconds to 4 min, and an
audit of 2–4 min per round.

Review rounds (ledger): B2 context-service and B3 context-invocations each
closed in ≤ 3 cumulative rounds; memory-lifecycle (B4) consumed 2 historical
rounds on TASK-1105 and 1 on TASK-1117 (3 of a hard ceiling of 4);
maintenance changes (A12 boundary, A13 containment, A14 continuation) used
3, 4 and 1 rounds. Needs-fix verdicts were genuine each time (TASK-1104/1105
findings led to the corrected candidate that became B4); no audit was ever
overturned.

Retries: 7 of 40 Codex implementer calls and 4 of 8 Claude implementer
calls did not succeed; every non-success is attributable (audit-infra ×1,
session limit ×2, reboot ×1, timeout ×2, Codex quota ×1) — none to a
provider producing wrong code that a gate then caught, because the gates
ran on the host, not in the provider.

## 4. Where the time went

Wall clock Sep 12 15:00Z → Sep 15 19:00Z: ~76 h. Productive engine time
(worker + gate + audit + integration across all tasks): **≈ 6 h**. Two
integrations happened on Sep 12–13, three on Sep 14–15 after the engine was
made resilient.

The remaining ~70 h were consumed by, in order of cost:

1. **Lifecycle refusals of legitimate state** — the outcome-unknown
   continuation gap, the one-shot authority after the host reboot, `unpark`
   producing a non-reservable lease, base drift from the reconciler's own
   commits, the frozen-exit dispatch record, and the retained-worktree
   self-refusal. Six distinct deadlocks, 24 silent reservation refusals on
   TASK-1116 alone; each cost 1–9 h of wall time and a supervisor decision.
   Four are fixed in 0.22.0 (A15); two remain documented.
2. **Environment** — a host reboot mid-run, two Claude session-limit
   outages, the Codex quota exhaustion, and one worker task (1114) larger
   than its 1 h clock.
3. **Supervisor-inflicted** — uncommitted release files in the live target
   checkout refused auto-integration for 100 min (B5); an over-eager
   snapshot copy overwrote a lease image; a worktree with partial work was
   removed once; a queue-runner liveness detector halted the loop twice on
   false positives while a pre-existing worker was running.
4. **Packet-format slips** — after the A15 repair pass, the remaining
   failure mode is a *missing required field* (`createdAt`, twice on
   TASK-1114), which no structural repair can invent. It cost the product
   repair budget of a run whose candidate was complete and later audited
   clean. Two contract gates also listed tests that fail on the base tree in
   this host (pre-existing), which would have refused any candidate; both
   contracts were amended with the reason recorded.

Overhead signature in the log: 543 reconcile iterations produced 10
dispatches over the Sep 12–14 window; `integration.campaign_mismatch` fired
26 k times re-evaluating historical packets every cycle; refusals never
advanced the breaker.

## 5. What the data does and does not support

- **Supported:** with the product guards unchanged (scope, secrets, declared
  gate, fresh audit, exact-tree gate), a task whose worker finishes inside
  its clock integrates in well under an hour, and the audits' findings were
  real. The A15 resilience changes removed the two largest stall classes in
  the very next runs (`l1.base_refreshed` fired on both B4 and B5 dispatches;
  B5 integrated with zero refusals).
- **Not supported:** any claim that Claude vs Codex changed quality — the
  Claude phase ran only three productive implementations and different
  tasks. Any throughput number for "unattended" operation — every
  integration in the Claude phase followed at least one supervisor action
  (TASK-1117 is recorded as assisted provenance). Any cost per task for
  Codex — its usage is quota, not billed.
- **Unknown / missing observations:** worker transcripts for the timed-out
  runs (only the terminal envelope is retained, ~1.4 KB); the true cause of
  TASK-1114's two hours of edits-free work; whether the 236-script sweep the
  TASK-1116 worker started would have surfaced product defects (it was cut
  by the reboot).

## 6. Recommendations (engine, next maintenance cycle)

1. Finalize the dispatch record on a frozen/refused driver exit, and let the
   reaper honour an existing exit file despite a successor reservation.
2. The retained-worktree guard must accept the driver's own `planned`
   reservation.
3. Put reconciler control-state commits on a separate ref, not the
   integration target.
4. Count refusals toward the breaker; park with the reason on the lease.
5. Retain the worker's streamed transcript on timeout, not only the terminal
   envelope; size task clocks from the contract (owned-file count, gate
   script count) instead of one global value.
6. Stop re-evaluating historical imported packets every cycle.
7. Build A16 from the released 0.22.1 tree so runtime and repo schemas agree.
