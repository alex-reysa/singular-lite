# Fixture Knowledge Registry

<!-- GENERATED — DO NOT EDIT. -->

Routing manifest over durable knowledge outside the docs canon.

## Folder Map

| Folder | Character | Purpose |
| --- | --- | --- |
| `notes/` | durable | Durable working notes |
| `handoffs/` | durable | Session checkpoints |
| `skills/` | vendored | Vendored skill packs; routing from SKILL.md name/description |

## Notes

- **`notes/decision-log.md`** — Decision Log
  `report` · canonical · updated 2026-07-04
  Running log of durable decisions and their rationale.
  Load when: revisiting a past decision · understanding why an approach was chosen.

## Handoffs

- **`handoffs/session-2026-07-05.md`** — Session Handoff 2026-07-05
  `report` · canonical · updated 2026-07-05
  Current session checkpoint — what shipped and what is next.
  Load when: resuming work after a break · checking the latest project state.

## Agent skills

- **`skills/example-skill/SKILL.md`** — example-skill
  `skill` · vendored
  Guides an example workflow end to end — folded block scalar so the parser must reassemble multiple wrapped lines into one description string, and a nested metadata map below that the lenient parser must skip without error.
