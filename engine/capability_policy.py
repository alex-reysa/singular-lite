#!/usr/bin/env python3
"""Shared strict-profile provider argument policy.

Provider arguments are always passed as literal argv. For providers where
Singular supplies a native strict-isolation mode, they also must not replace or
expand the host-owned sandbox, filesystem, tool, MCP, plugin, or approval
boundary. Cursor and Grok are intentionally absent: their strict profiles
require an operator-validated providerArgs isolation mechanism.
"""

from __future__ import annotations

from collections.abc import Sequence


STRICT_PROVIDER_DENIED_OPTIONS: dict[str, frozenset[str]] = {
    "codex": frozenset(
        {
            "--",
            "--add-dir",
            "--approval-policy",
            "--ask-for-approval",
            "--cd",
            "--config",
            "--dangerously-bypass-approvals-and-sandbox",
            "--yolo",
            "--disable",
            "--enable",
            "--full-auto",
            "--profile",
            "--sandbox",
            "--search",
            "--web-search",
            "-C",
            "-a",
            "-c",
            "-s",
        }
    ),
    "claude": frozenset(
        {
            "--",
            "--add-dir",
            "--agents",
            "--allowed-tools",
            "--allowedtools",
            "--chrome",
            "--dangerously-skip-permissions",
            "--disallowed-tools",
            "--disallowedtools",
            "--ide",
            "--mcp-config",
            "--permission-mode",
            "--permission-prompt-tool",
            "--plugin-dir",
            "--remote-control",
            "--remote-control-server",
            "--safe-mode",
            "--setting-sources",
            "--settings",
            "--strict-mcp-config",
            "--tools",
        }
    ),
    "gemini": frozenset(
        {
            "--",
            "--allowed-mcp-server-names",
            "--allowed-tools",
            "--approval-mode",
            "--extensions",
            "--include-directories",
            "--include-directory",
            "--policy",
            "--sandbox",
            "--sandbox-image",
            "--settings",
            "--settings-file",
            "--trusted-folders",
            "--tools",
            "--yolo",
            "-e",
            "-s",
            "-y",
        }
    ),
    "opencode": frozenset(
        {
            "--",
            "--add-dir",
            "--agent",
            "--allowed-tools",
            "--attach",
            "--config",
            "--cwd",
            "--directory",
            "--file",
            "--mcp",
            "--permission",
            "--plugin",
            "--pure",
            "--tools",
        }
    ),
}


def _matches_option(argument: str, denied: str) -> bool:
    if denied == "--":
        return argument == denied
    if denied.startswith("--"):
        normalized = argument.split("=", 1)[0].lower().replace("_", "-")
        return normalized == denied
    # Value-taking short flags commonly accept `-C/path` as well as `-C /path`.
    return (
        argument == denied
        or argument.startswith(denied + "=")
        or (len(argument) > len(denied) and argument.startswith(denied))
    )


# openrouter dispatches through the OpenCode CLI, so it has OpenCode's proven
# `--pure` isolation and exactly OpenCode's boundary to protect. Aliased rather
# than copied: two lists that must be equal are two lists that can diverge.
STRICT_PROVIDER_DENIED_OPTIONS["openrouter"] = STRICT_PROVIDER_DENIED_OPTIONS["opencode"]


def strict_provider_arg_violation(
    provider: str, arguments: Sequence[str]
) -> str | None:
    """Return a stable failure message when strict argv weakens host isolation."""

    denied_options = STRICT_PROVIDER_DENIED_OPTIONS.get(provider)
    if not denied_options:
        return None
    for argument in arguments:
        for denied in denied_options:
            if _matches_option(argument, denied):
                return (
                    f"providerArgs option {argument!r} is forbidden for strict "
                    f"{provider} profiles because {denied} can replace or expand "
                    "the host-owned sandbox/capability boundary"
                )
    return None

