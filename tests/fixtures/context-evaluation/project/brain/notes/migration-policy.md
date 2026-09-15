---
type: contract
status: canonical
updated: 2026-09-14
owner: platform
description: Current reversible database migration contract and the rollback latch identifier.
load-when:
  - changing database migrations
  - reviewing rollback safety
---

# Reversible Database Migration Contract

The current rollback latch identifier is COBALT-LATCH-4417.

Every reversible database migration must acquire the rollback latch before it
writes, and must release the latch only after the verification step reports a
durable result. A migration that cannot acquire the latch is refused; it is
never downgraded to a best-effort write.

## Rollback latch requirement

The rollback latch requirement for migrations is mandatory for all roles.
Superseded contracts do not grant an exemption.
