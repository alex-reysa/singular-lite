# Recovery review checkpoint

The production publication repair passes all 34 host tests with no skips, including valid/invalid lock ownership, production identity and proof revalidation, native publication/import, six crash replays, and runtime addition/change/removal refusal with unchanged state. Source3 remains **needs-fix**; these tests do not replace independent acceptance.

The root host evidence is `.singular-state/campaign-evidence/bootstrap-audit-bridge/lean-controller/host-final-5/`. The original failed fixtures and three independent reviews remain preserved. All models remain GPT-6 Astra medium, fast requested. No new runtime has been adopted.

| Recovery allowance | Bytes |
|---|---:|
| Current total (512 KiB) | 524,288 |
| Already consumed | 454,109 |
| Remaining | 70,179 |
| Corrected full source review, measured | 190,427 |
| Task audit, enforced capacity bound | 69,782 |
| Additional bytes needed at current closure | 190,030 |
| Proposed total (768 KiB) | 786,432 |
| Proposed increase (256 KiB) | 262,144 |
| Margin beyond current measured requirements | 72,114 |

**Approved by the user on 2026-09-08.** The separate768KiB authorization is recorded; native controller binding and fresh final-closure validation are running. Increase only this recovery's total to768KiB, preserving all charges and the same lineage. Keep262144 per input,2048 per page, and ordinary task limits unchanged. See `recovery-evidence-budget-amendment-proposal.json` for hashes, exact evidence and intended changes.

Bind the approved separate authorization amendment and update the controller's corresponding allowance checks and source/task ceilings consistently. Re-test and remeasure the final amended closure before any model delivery. The current measurement precedes these authorization edits; the proposed margin accommodates them but does not guarantee acceptance or unlimited retries. Then obtain fresh independent full-source acceptance, full native task gate, fresh task acceptance and guarded integration. No earlier needs-fix verdict becomes acceptance.

DF-023 records the real production capability-environment mismatch and the substituted fixture coverage that missed it. The corrected contract assigns cryptographic byte/hash verification to host code and content/code review to the model; the model must not claim hashes it did not compute. The new byte-integrity evidence and code remain subject to fresh independent review.
