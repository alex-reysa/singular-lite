# Astra model policy requested 2026-09-07

The user explicitly requested replacing every GPT-5.6 Sol role with GPT-6 Astra Light (low) and returning to normal speed. This supersedes older Sol High execution preferences in campaign/task documents; historical audits and model metadata remain unchanged evidence.

| Role | Model | Effort | Service tier |
|---|---|---|---|
| Implementation | gpt-6-astra | low | normal |
| Plan critic | gpt-6-astra | low | normal |
| Final and paired auditors | gpt-6-astra | low | normal |
| Planner, difficult recovery decider, supervisor/assistant | gpt-6-astra | high | normal |

Prepared configuration: .singular-state/campaign-policy/config-astra-light.json. All models now match, so this profile uses the frozen native Codex runner directly. Existing model/effort session-affinity guards remain required; never resume a Sol session as Astra or reuse incompatible effort. Native per-role model configuration remains queued for future mixed-model use.

MODEL-POLICY-ASTRA-LIGHT is the immediate operator checkpoint. The local Codex model catalog confirms that Light maps to low reasoning effort. The service-tier override is explicitly empty, so the strict native runner sends no fast override. A fresh canary is required before activation; the earlier Medium/Fast probe remains historical evidence only. Preserve current in-flight runs under recorded R2 policy, finish or fence them at a safe terminal boundary, and integrate eligible audited candidates under that policy where possible. Preserve remaining candidates, worktrees and evidence. Then run native canary and explicit replacement campaign using this profile with a new identity, keeping frozen source 85937f90 unchanged. Update launcher selection at the verified boundary and verify model, effort, service tier and new binding. Clear the operator transition STOP only after success. Do not restart old Sol dispatch.

Unintegrated old acceptance never transfers automatically; require applicable fresh current-campaign audit and full exact merged-tree gate. Historical audit/task-status fields cannot manufacture new authority. This model-policy replacement precedes TASK-1014; adopting stabilization source remains the later RUNTIME-STABILIZATION checkpoint after TASK-1013/TASK-1014 full integration. Do not wait for that later repair to honor the model request.

Evidence: .singular-state/campaign-evidence/astra-light-transition/. Durable state and recurring follow-up use the latest policy. Machine-global Codex defaults and account settings are unchanged.

Latest user correction: normal speed for every role, and only roles previously moved to Medium now use Light/low. Planning and difficult decisions stay High. Preserve historical model records; never reactivate the superseded Fast profile.
