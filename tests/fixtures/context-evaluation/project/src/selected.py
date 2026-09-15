"""Selected worktree code source for the labeled retrieval corpus."""

SELECTED_CODE_MARKER = "SELECTED-CODE-9001"


def acquire_rollback_latch(identifier: str) -> str:
    """Return the rollback latch identifier the migration contract requires."""
    return identifier
