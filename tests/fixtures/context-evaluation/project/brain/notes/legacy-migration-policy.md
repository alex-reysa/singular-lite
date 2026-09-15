---
type: contract
status: superseded
updated: 2026-09-02
owner: platform
description: Retired migration contract retained only as history; contradicts the current rollback latch rule.
load-when:
  - auditing retired migration history
  - comparing superseded contracts
---

# Retired Reversible Database Migration Contract

The retired rollback latch identifier was ZIRCON-LATCH-0001.

This retired contract allowed a reversible database migration to skip the
rollback latch when the operator asserted a manual backup. That permission
contradicts the current contract and must never be retrieved as authority.

## Rollback latch requirement

The retired rollback latch requirement for migrations was advisory only.
