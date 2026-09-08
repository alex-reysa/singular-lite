# Continuous dogfooding and runtime adoption

The user authorized logging new bugs/inefficiencies and restarting with important validated improvements so subsequent work exercises the improved engine. This standing instruction applies throughout this iteration; routine validated replacement does not require another confirmation.

## Evidence and issue tracking

Maintain dogfooding-issues.json as the committed issue register, linked to native tasks, exact run IDs, gate/audit logs and evidence hashes. Raw observations remain in .singular-state/campaign-evidence/operator-observations.ndjson. Separate product defects, test-contract failures, provider limits, setup mistakes and hypotheses. Never infer cost or context occupancy from cumulative cached tokens, and never treat missing usage as zero. Keep old evidence immutable; append corrected interpretations and observed outcomes.

Current significant observations: the consumer schema omission is TASK-1017; the producer's sole full-gate failure is a case-sensitive diagnostic assertion, with a native split-task decision still needing a bounded task; the lifecycle worker timed out once and began its permitted fresh infrastructure retry. These mean the system is active and its gates work, but efficient delivery is not yet established.

## Adopt important improvements as they become usable

After each native integration, compare the current frozen runtime source/configuration with the integrated product. Material changes to lifecycle/recovery, dispatch/planning, verification, configuration/models, context/memory or installed runtime behavior trigger an adoption checkpoint. Documentation-only or test-only changes do not by themselves require replacing the executor. Coalesce improvements already validated at the same boundary.

Do not wait for B1–B5 completion, or automatically wait for TASK-1014 when TASK-1013 alone has passed fresh audit and full integration. The earliest useful verified improvement should benefit the next applicable work. The pending Astra Medium/Fast policy is the immediate checkpoint; combine its adoption with a fully integrated lifecycle repair if both are ready, otherwise keep policy adoption and later code adoption separate.

Before replacement: verify exact candidate audit and full merged-tree gate, preserve old runtime/configuration/checkpoint and pending candidate evidence, stop new dispatch, and drain or explicitly fence old ownership. A long running worker or its retry must not silently defer adoption forever; inspect the next provider/checkpoint boundary and preserve its work before selecting a supported transition. Never deploy unreviewed worker code, reset historical candidates or fake an accepted binding.

Create a new immutable runtime snapshot from the reviewed integrated commit when adopting code. Use a new campaign identity/epoch and native canary with required real-provider assurance. Publish launcher/configuration selection at the controlled boundary, verify the selected engine and actual native invocation settings, and preserve a verified rollback path. Old unintegrated semantic acceptance needs current-campaign authority. No hotpatches or gate waivers.

After replacement: record old/new source SHA, campaign/binding/epoch, config/runner hashes, included fix IDs, audit/full-gate references and canary results. Mark fixes adopted, not proven effective. Observe the first applicable native runs and compare integration outcome, gate failures, retry domains, time to integration, historical validations and available role/model usage. Keep model, workload and code changes explicit as confounders; this evolving single campaign is not a causal experiment.

Use runtime-adoptions.json for every prepared/completed replacement and its follow-up observations. Close an issue only after relevant post-adoption behavior is verified, or record precisely why it is deferred. The recurring operator follow-up must advance these checkpoints and issue-linked repairs while preserving active work and the latest Astra Medium/High Fast preference.

## Latest model and speed correction

The user superseded the pending Medium/Fast profile: use GPT-6 Astra Light (low reasoning effort) for implementation, critics and final/paired audits; retain Astra High for planning/difficult decisions; use normal speed for all roles. MODEL-POLICY-ASTRA-LIGHT and .singular-state/campaign-policy/config-astra-light.json replace the earlier Fast checkpoint. The old Medium/Fast probe is historical, not validation of the new profile. Perform the normal controlled replacement and required canary; do not activate the superseded Fast profile. This does not change the ongoing brain work or continuous adoption requirements.

## Verified adoption on 2026-09-08

BRAIN-20260908-ASTRA-LIGHT-R3 is active: Astra Light/low implementation, critic and independent audit; Astra High planning/recovery; normal speed. Native lifecycle canary and live provider assurance passed, and the real audit-role probe reports low. Launcher verification reports zero drift. Frozen code remains 85937f90; TASK-1013 ended after two infrastructure timeouts with preserved changes and requires bounded native recovery. Old candidate audits are preserved historical evidence, never rebound. The timed pause expired and continuation is authorized. See runtime-adoptions.json and dogfooding-issues.json for DF-013 fixture hang and DF-014 contract discovery.
