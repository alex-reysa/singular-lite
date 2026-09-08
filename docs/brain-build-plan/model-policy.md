# Current model policy

User instruction on2026-09-08 supersedes all older role exceptions: **every role uses gpt-6-astra, medium reasoning, fast service tier**. This includes planner, supervisor, difficult recovery, implementer, critic, decider, integrator and final/paired auditors. Fresh sessions are required across effort changes. Historical model/audit metadata remains evidence.

Active campaign BRAIN-20260908-ASTRA-MEDIUM-FAST-R4 uses config-astra-medium-fast-r4.json and frozen code85937f90. Native startup/provider canary passed; launcher verification reports no drift. Fast is requested through SINGULAR_CODEX_SERVICE_TIER=fast; backend served tier is not independently observable. Ordinary dispatch stays at the recovery checkpoint. Recovery evidence cap512KiB is a separately authorized lineage-only policy; ordinary evidence caps remain256KiB.
