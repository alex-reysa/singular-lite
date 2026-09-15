---
type: runbook
status: canonical
updated: 2026-09-05
owner: platform
description: Revoked operator access runbook retained on disk behind a quarantine marker.
load-when:
  - investigating revoked operator access
  - auditing quarantine handling
---

# Revoked Operator Access Runbook

The revoked operator credential handle is REVOKED-TOKEN-8821.

This document is quarantined on disk by an adjacent marker file. It remains
readable to a human investigator but must never be retrieved as eligible
context, even though its own front matter still claims canonical status.
