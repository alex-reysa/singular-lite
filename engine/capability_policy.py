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



# ---------------------------------------------------------------------------
# Finite provider context-control support matrix (TASK-1115).
#
# This records what the HOST can actually control or observe at the invocation
# boundary for a given native provider build, and how that claim is evidenced.
# It is deliberately finite and conservative: a control Singular has not
# demonstrated stays `unverified`, and no entry may be read as a promise about
# provider-internal context occupancy, remote history or vendor-side memory.
# ---------------------------------------------------------------------------

#: Ordered evidence classes, weakest first. `fixture-argv` means the host has
#: observed the exact argv/prompt bytes it composed reaching the provider in a
#: local fixture; `capability-advertised` means only the CLI's own help/version
#: output claims it; `demonstrated-control` means the effect was observed on a
#: real provider run; `unverified` means Singular has no local evidence at all.
CONTROL_EVIDENCE_CLASSES = (
    "fixture-argv",
    "capability-advertised",
    "demonstrated-control",
    "unverified",
)

#: The exact control surface this matrix describes. Adding a row here is a
#: deliberate contract change: every declared provider must answer all of them.
CONTEXT_CONTROLS = (
    "initialPromptControl",
    "hostBrokerRetrieval",
    "resumeHistoryInspection",
    "resumeHistoryRemoval",
    "visibleToolSkillContent",
    "outputControl",
    "usageObservation",
)

_UNVERIFIED = {
    "support": "unknown",
    "evidence": "unverified",
    "note": "no local Singular evidence for this control on this provider build",
}


def unverified_context_controls() -> dict[str, dict[str, str]]:
    """The all-unknown row used for any provider without a declared record."""
    return {control: dict(_UNVERIFIED) for control in CONTEXT_CONTROLS}


def _record(support: str, evidence: str, note: str) -> dict[str, str]:
    if support not in {"supported", "unsupported", "partial", "unknown"}:
        raise ValueError(f"invalid control support value: {support!r}")
    if evidence not in CONTROL_EVIDENCE_CLASSES:
        raise ValueError(f"invalid control evidence class: {evidence!r}")
    return {"support": support, "evidence": evidence, "note": note}


PROVIDER_CONTEXT_CONTROLS: dict[str, dict[str, dict[str, str]]] = {
    "codex": {
        "initialPromptControl": _record(
            "supported", "fixture-argv",
            "the host composes the entire prompt and passes it on stdin behind "
            "`codex exec`; the delivered bytes are hashed into the bundle",
        ),
        "hostBrokerRetrieval": _record(
            "supported", "fixture-argv",
            "paged reads go through the host AF_UNIX broker and are charged to "
            "the durable ledger before the bytes are released",
        ),
        "resumeHistoryInspection": _record(
            "unknown", "unverified",
            "`codex exec resume <id>` replays provider-side history that the "
            "host cannot enumerate or hash",
        ),
        "resumeHistoryRemoval": _record(
            "unsupported", "unverified",
            "no supported interception point removes bytes from an existing "
            "provider session; the host refuses reuse instead",
        ),
        "visibleToolSkillContent": _record(
            "unknown", "unverified",
            "tool and skill descriptions are injected by the provider build; "
            "their bytes are neither host-composed nor host-observable",
        ),
        "outputControl": _record(
            "unsupported", "unverified",
            "no provider-enforced output cap is demonstrated; a configured "
            "output reserve is a host budgeting decision only",
        ),
        "usageObservation": _record(
            "partial", "fixture-argv",
            "`--json` turn events report cumulative input/cached-input/output "
            "token counts, which are not instantaneous occupancy or money",
        ),
    },
    "claude": {
        "initialPromptControl": _record(
            "supported", "fixture-argv",
            "the host composes the entire prompt and passes it as the single "
            "provider input; the delivered bytes are hashed into the bundle",
        ),
        "hostBrokerRetrieval": _record(
            "supported", "fixture-argv",
            "paged reads go through the host AF_UNIX broker under an "
            "OS-enforced read-only adapter profile",
        ),
        "resumeHistoryInspection": _record(
            "unknown", "unverified",
            "resumed sessions replay provider-side history the host cannot "
            "enumerate or hash",
        ),
        "resumeHistoryRemoval": _record(
            "unsupported", "unverified",
            "no supported interception point removes bytes from an existing "
            "provider session; the host refuses reuse instead",
        ),
        "visibleToolSkillContent": _record(
            "unknown", "unverified",
            "tool/skill content is provider-supplied and is not part of the "
            "host-composed prompt accounting",
        ),
        "outputControl": _record(
            "unsupported", "unverified",
            "no provider-enforced output cap is demonstrated from the host",
        ),
        "usageObservation": _record(
            "partial", "fixture-argv",
            "reported usage is cumulative per turn and is neither instantaneous "
            "context occupancy nor cost",
        ),
    },
}

# Providers Singular reaches through another CLI inherit that CLI's boundary.
# Aliased rather than copied for the same reason as the strict argv table above.
PROVIDER_CONTEXT_CONTROLS["openrouter"] = PROVIDER_CONTEXT_CONTROLS["codex"]


def context_control_support(provider: str) -> dict[str, dict[str, str]]:
    """Return the finite control matrix for one provider, defaulting to unknown."""
    declared = PROVIDER_CONTEXT_CONTROLS.get(provider)
    if declared is None:
        return unverified_context_controls()
    return {control: dict(declared[control]) for control in CONTEXT_CONTROLS}


def output_reserve_conversion(provider: str) -> dict[str, object] | None:
    """Declared byte<->token conversion for an output reserve, or None.

    Singular has no supported tokenizer identity for any provider build it
    launches, so this is None everywhere today. A token reserve must therefore
    never be subtracted from a byte limit; see ``context_service`` for the
    admission rule that depends on this.
    """
    del provider
    return None


def managed_boundary_guarantee(provider: str) -> dict[str, object]:
    """Describe exactly how far the host-managed boundary is enforceable.

    The guarantee covers the bytes the host composes and the retrieval it
    brokers. Anything a provider can read without crossing a supported
    interception point is reported as a coverage gap, and a strict
    whole-provider guarantee is refused rather than approximated.
    """
    controls = context_control_support(provider)
    gaps: list[dict[str, str]] = []
    for control, record in controls.items():
        if record["support"] in {"supported"}:
            continue
        gaps.append({
            "control": control,
            "support": record["support"],
            "evidence": record["evidence"],
            "reason": record["note"],
        })
    return {
        "provider": provider,
        "declared": provider in PROVIDER_CONTEXT_CONTROLS,
        "enforcedScope": "host-composed-prompt",
        "brokeredScope": "host-mediated evidence retrieval charged to the ledger",
        "strictWholeProviderGuarantee": False,
        "refusalReason": (
            "provider tools, provider-side retrieval and provider session "
            "history do not cross a supported host interception point, so no "
            "strict whole-provider context guarantee can be made"
        ),
        "coverageGaps": gaps,
        "controls": controls,
    }
