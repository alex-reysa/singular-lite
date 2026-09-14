# Engine architecture audit — 2026-09-14

Scope: the Singular 0.21.0 brain-rescue engine (runtimes A11–A14) and the
supervisor workflow around it, measured over 2026-09-12T15Z → 2026-09-14T16Z.
Author: Claude (Fable 5.1) as supervisor, on the user's direct instruction to
"cut the red tape". Numbers come from `.singular-state/events.ndjson`, the
per-run `*runner-result.json` / provider envelopes, and the review ledger.

## 1. Stability vs bureaucracy — verdict

**The engine is not stable; it is stalled.** Every single stall of the last
48 hours was the engine refusing its *own* legitimate state, never bad code
reaching the target:

| Stall | Root cause | Category |
|---|---|---|
| TASK-1116 native attempt: 85 identical admission refusals (05:18Z) | reconciler commits control state to the target, so a preseeded branch is "behind" seconds after every hand refresh | self-inflicted guard |
| TASK-1116 continuation: `recover continuation` refused (06:20Z) | `outcome-unknown` disposition has no public successor verb → engine fix, review, A14 | missing verb |
| TASK-1116 after reboot (15:08Z) | one-shot authority consumed; no successor verb; required a new task id + supersede + review-exception migration | missing verb |
| TASK-1117 (15:29Z) | one stray `"]` in a *successful* worker's packet → `worker-no-packet` → unchanged candidate → park | over-strict parser + park rule |
| TASK-1117 unpark (15:40Z) | `unpark` leaves the terminal attempt on the lease; `reserve()` refuses "requires explicit successor authority"; refusals don't advance the breaker → silent 20 s spin | two public verbs contradict each other |
| TASK-1117 after hand archive (15:42Z) | target advanced by a control-state commit → ancestry refusal → `finish()` **deleted the lease** and its history (planned + `productPassStarted=false`) | self-inflicted guard + destructive cleanup |

Not one of these protected the product. The gates that *do* protect the
product (scope check, secret scan, declared gate command, fresh audit, exact
tree regression) never fired a false positive in the window. The bureaucracy
is entirely in the **lifecycle-identity layer**: one-shot authorities,
generation-bound reservations, disposition kinds, and the rule that every
re-entry needs an authority object the engine has no verb to mint.

**Where the sweet spot is.** Keep the product guards exactly as they are —
they are cheap, deterministic and have caught real defects (TASK-1104/1105
needs-fix rounds were genuine). Loosen the *lifecycle* layer along one
principle: **an operator or supervisor decision is itself successor
authority.** Concretely (implemented today, see §3):

- a public re-entry verb (`unpark`) must yield a dispatchable lease, and its
  history must be archived, never deleted;
- the engine must repair the *shape* of provider output when the content is
  unambiguous, and log that it did;
- a candidate that is intentionally unchanged (qualification-only tasks) must
  not be parked for a format slip;
- the engine, not the supervisor, refreshes a retained branch onto the base
  it itself moved.

What should stay strict: one-shot continuation authority (it prevents two
workers on one partial candidate), campaign/epoch binding (it prevents a
stale engine from judging a candidate), budgets (they cap spend), and the
independent audit.

## 2. Performance and overhead (last 48 h)

**Provider spend.** 37 provider invocations. Codex (Astra) roles: 18
implementer + 14 auditor + 1 decider, 96.5 M input tokens (97 % cached),
0.56 M output. Claude: 3 implementer runs, 4.0 M cached input, 43 k output,
**$4.78 total**; the reboot-killed run cost ~$0.7 with nothing recorded.
Per productive Claude implementer run: ~$0.7–3.4, 9–17 min.

**Cycle time, when the engine runs unimpeded** (event timelines):

| Task | dispatch → integrated | worker | gate | audit | outcome |
|---|---|---|---|---|---|
| TASK-1103 | 24 min | 13 + 6 min | ~5 s | ~2 min ×2 | accepted after 1 fix round |
| TASK-1113 (2nd dispatch) | 23 min | 11 min | 3.5 min | 4 min | accepted, integrated |
| TASK-1104 | 54 min → parked | 29 + 18 min | 1 min | 2.5 min ×2 | needs-fix ×2 |
| TASK-1105 | 44 min → parked | 20 + 13 min | 3.5 min | 2 min ×2 | needs-fix ×2 |

So a healthy task costs ~25 min and one or two audit rounds. **Wall-clock
budget of the window: ~48 h. Productive engine time: ~2.5 h. Integrations: 2.**
The other ~45 h were supervisor time spent on lifecycle recovery (ESCALATION-001
through -004, two runtime builds, three gate re-publications, one continuation
engine fix, one task supersede with ledger migration) plus a reboot.

**Overhead signature in the event log.** 543 reconcile iterations produced 10
dispatches; 28 `origin.reservation_refused` and 26 k historical
`integration.campaign_mismatch` events (skipped imported packets from older
campaigns, re-evaluated every cycle) — noise that hides the one line that
matters. Refusals do not advance the breaker, so a refused task loops every
20 s until an external watcher notices.

**Cost of the bureaucracy in provider terms is small** (the wasted Claude
call was $0.7; the engine spent nothing while stalled). The cost is
**latency and attention**: each stall consumed 1–9 h of wall time and a
human/supervisor decision, for a queue whose remaining work (B4, B5, 1114,
1115) is ~2 h of provider time.

## 3. Immediate engine changes (A15)

Implemented directly on `codex/brain-integration`, tested, no review round
(user directive):

1. `singular_extract_json` — bounded structural repair (drop unmatched
   closers, close unclosed openers, drop trailing commas; strings untouched)
   as the last resort before "no packet"; logs `packet repaired: …`.
   Test: `tests/test-worker-packet-repair.sh` with the real field packet.
2. `singular_lease_unpark` — archives `attemptLifecycle` /
   `terminalDisposition` into their history lists and records
   `operatorReentries[]`, so `reserve()` admits the re-entry.
3. `finish()` — a refused *planned* reservation is released, not deleted,
   when the lease carries any history. Test: `tests/test-operator-reentry.sh`.
4. `l1-drive` admission — a retained branch behind the admitted base is
   merged forward by the engine (`singular_refresh_retained_branch`, live
   checkout or plumbing), event `l1.base_refreshed`; conflicts still refuse.
   Test: `tests/test-retained-base-refresh.sh`.
5. `l1-drive` park rule — a *first* `worker-no-packet`/`packet-invalid` on an
   unchanged candidate is retried once (event
   `l1.packet_format_retry_eligible`); a repeat parks.
   `tests/test-decider-fastpath.sh` updated to the new contract.

Regression baseline: `test-orphan-continuation.sh` and
`test-accept-existing-packet.sh` fail identically on the untouched A14 source
(pre-existing host failures already on record); everything else run is green.

## 5. Two more deadlocks found while relaunching on A15 (16:40–16:46Z)

| Stall | Root cause | Fix status |
|---|---|---|
| Launch failed, lease stuck `planned` (16:40Z) | A STOP-frozen driver exits 0 without finalizing its dispatch record. The reaper then refuses to finish that record once the *next* reconcile has reserved the lease ("stale owner cannot finish successor lease"), counts it as `running`, and the successor cannot bind because the record is still `launched`. Reserve-before-bind deadlock. | Finalized the record by hand via `singular_lifecycle_dispatch_finalize`; reservation released mirroring `finish()`. Engine fix pending: a frozen exit must finalize its record; the reaper must finalize a record whose exit file exists regardless of successor reservations. |
| Refused ×3 "active/accepted worktree (lease: planned)" → parked (16:44Z) | The retained-worktree guard reads the lease status, and a detached dispatch has *just* set it to `planned` itself. So a retained worktree plus any fresh dispatch is always refused; `unpark` can only work if the worktree was pruned first. | Removed the stale worktree (branch and evidence kept), unparked, fresh dispatch succeeded. Engine fix pending: treat a `planned` lease owned by the driver's own reservation as not-active. |

Positive result from the same relaunch: `l1.base_refreshed` fired and the
engine moved `codex/brain-rescue/TASK-1117` onto the current target itself
(575f054a, owned content byte-identical to f5d28582) — the class of stall
that cost the most hours over the weekend is gone.

Provider note: the Codex account hit its usage limit at 16:32Z (until Sep 19).
The production runner and intelligence roles were routed to Claude in
config-A15; no credits were bought.

## 4. Recommended next simplifications (not done today)

- Reconciler control-state commits should not land on the integration target
  (put them on a `control` ref); that removes the base-drift class entirely.
- Refusals must count toward the breaker; a task refused N times parks with
  the refusal reason on the lease.
- A frozen/refused driver exit must finalize its dispatch record, and the
  reaper must honour an existing exit file even when a successor reservation
  exists (§5).
- The retained-worktree guard must not refuse the driver's own `planned`
  reservation (§5).
- Collapse `orphan-reservation` / `outcome-unknown` / operator re-entry into
  one `successor` authority minted by any recorded decision.
- Stop re-evaluating historical imported packets every cycle (26 k
  `campaign_mismatch` events).
- The review ledger's per-task exception binding forced a migration ceremony
  for a task supersede; bind exceptions to the logical change with an
  explicit "consumed" flag instead.
