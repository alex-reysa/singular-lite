# TASK-9000: Exercise bounded context

## Objective

Use the cobalt migration rule.

## Scope

- Owned files: `src/selected.py`
- Forbidden files: `secrets/`

## Acceptance Criteria

- Preserve immutable source versions.

## Context packet

### Assumptions

- [open] The migration remains reversible — deployment policy.
- [violated] Never publish a partial prompt — prior audit finding.
