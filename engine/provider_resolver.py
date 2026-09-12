#!/usr/bin/env python3
"""Shared provider-executable resolution.

The python twin of ``singular_resolve_codex_bin`` (engine/lib.sh). Bash stays
authoritative for the runtime hot path — codex-run.sh resolves once per provider
invocation, and shelling a python interpreter there would add latency to every
planner/worker/auditor run and make a broken python break all orchestration.
This module exists so the two *diagnostic* consumers — ``singular doctor`` and
the console's Providers surface — answer the identical question the same way.
``tests/test-provider-resolver-parity.sh`` pins the two implementations
together; edit one and you must edit the other.

Why this module exists at all: the console daemon never sources lib.sh
(cli/singular execs it with only SINGULAR_ENGINE_HOME), so it used to resolve the
provider with a bare ``shutil.which`` over its own PATH. A field run showed the
Providers card reporting an unauthenticated /opt/homebrew/bin/codex while the
orchestration was actually driving a different Codex entirely.

Stdlib only, no engine imports — mirrors engine/capability_policy.py.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import shutil
from typing import Any, Mapping

# Resolution outcomes. The console needs "explicitly configured but broken" to
# be distinguishable from "nothing on PATH": the first is an operator
# misconfiguration that must never silently fall back to some other binary, the
# second is a plain missing install.
OK = "ok"
NOT_ABSOLUTE = "not-absolute"              # override set, not an absolute path
NOT_EXECUTABLE = "not-executable"          # override set, missing or not +x
NOT_ON_PATH = "not-on-path"                # no override, nothing found
PATH_NOT_EXECUTABLE = "path-not-executable"  # PATH hit, but not +x

# Only codex has a strict override today. Providers absent from this map resolve
# by PATH alone, and a codex override must never leak into their resolution.
OVERRIDE_ENV_KEYS = {"codex": "SINGULAR_CODEX_BIN"}

# Codex role routing is shared by the native runner, doctor and console.  The
# values are configuration keys, never campaign model names: generic engine
# defaults continue to come from providers.json.
CODEX_ROLE_ALIASES = {
    "worker": "implementer",
    "developer": "implementer",
    "reviewer": "auditor",
    "final": "auditor",
    "final-audit": "auditor",
    "final-auditor": "auditor",
    "paired-audit": "auditor",
    "paired-auditor": "auditor",
    "plan-critic": "critic",
    "skeptic": "critic",
    "advocate": "critic",
    "assistant": "supervisor",
}
CODEX_ROLE_MODEL_ENV = {
    "planner": "SINGULAR_CODEX_PLANNER_MODEL",
    "implementer": "SINGULAR_CODEX_IMPLEMENTER_MODEL",
    "auditor": "SINGULAR_CODEX_AUDITOR_MODEL",
    "critic": "SINGULAR_CODEX_CRITIC_MODEL",
    "decider": "SINGULAR_CODEX_DECIDER_MODEL",
    "supervisor": "SINGULAR_CODEX_SUPERVISOR_MODEL",
    "integrator": "SINGULAR_CODEX_INTEGRATOR_MODEL",
}
CODEX_ROLE_EFFORT_ENV = {
    "planner": "SINGULAR_CODEX_PLANNER_REASONING_EFFORT",
    "implementer": "SINGULAR_CODEX_L2_REASONING_EFFORT",
    "auditor": "SINGULAR_CODEX_AUDITOR_REASONING_EFFORT",
    "critic": "SINGULAR_CODEX_CRITIC_REASONING_EFFORT",
    "decider": "SINGULAR_CODEX_DECIDER_REASONING_EFFORT",
    "supervisor": "SINGULAR_CODEX_SUPERVISOR_REASONING_EFFORT",
    "integrator": "SINGULAR_CODEX_INTEGRATOR_REASONING_EFFORT",
}
CODEX_ROLE_EFFORT_DEFAULT = {
    "planner": "high",
    "implementer": "medium",
    "auditor": "high",
    "critic": "high",
    "decider": "high",
    "supervisor": "high",
    "integrator": "high",
}


class ConfigResolutionError(ValueError):
    """The explicitly selected JSON configuration cannot be used."""


@dataclass(frozen=True)
class JsonConfigResolution:
    path: Path
    source: str  # "selector" | "default"


def resolve_json_config(repo: Path | str, env: Mapping[str, str]) -> JsonConfigResolution:
    """Resolve the JSON config once, before any caller changes cwd.

    Relative explicit selectors are rooted at the consumer repository.  This
    gives CLI, doctor and a detached console one stable meaning for the same
    selector even when each process starts in a different directory.
    """
    root = Path(repo).resolve()
    selected = str(env.get("SINGULAR_JSON_CONFIG_FILE", "") or "").strip()
    if selected:
        path = Path(selected).expanduser()
        if not path.is_absolute():
            path = root / path
        return JsonConfigResolution(path=path.resolve(), source="selector")
    return JsonConfigResolution(path=root / "singular.config.json", source="default")


def load_json_config(
    repo: Path | str, env: Mapping[str, str]
) -> tuple[dict[str, Any], JsonConfigResolution]:
    """Read the selected config and fail with its exact path in the message."""
    resolution = resolve_json_config(repo, env)
    try:
        loaded = json.loads(resolution.path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ConfigResolutionError(
            f"selected JSON configuration is missing: {resolution.path}"
        ) from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigResolutionError(
            f"selected JSON configuration is invalid: {resolution.path}: {exc}"
        ) from exc
    if not isinstance(loaded, dict):
        raise ConfigResolutionError(
            f"selected JSON configuration is invalid: {resolution.path}: "
            "top level must be an object"
        )
    return loaded, resolution


def normalize_codex_role(role: str) -> str:
    value = str(role or "").strip().lower().replace("_", "-")
    return CODEX_ROLE_ALIASES.get(value, value)


def codex_role_settings(
    env: Mapping[str, str], role: str, default_model: str
) -> dict[str, str | None]:
    """Resolve observable Codex model/effort/tier settings for one role."""
    effective_role = normalize_codex_role(role)
    model_key = CODEX_ROLE_MODEL_ENV.get(effective_role)
    role_model = str(env.get(model_key, "") or "").strip() if model_key else ""
    global_model = str(env.get("SINGULAR_CODEX_MODEL", "") or "").strip()
    if role_model:
        model, model_source = role_model, model_key
    elif global_model:
        model, model_source = global_model, "SINGULAR_CODEX_MODEL"
    else:
        model, model_source = default_model, "provider-default"

    effort_key = CODEX_ROLE_EFFORT_ENV.get(effective_role)
    effort = str(env.get(effort_key, "") or "").strip() if effort_key else ""
    if effort:
        effort_source: str | None = effort_key
    elif effective_role in {"supervisor", "integrator"} and str(
        env.get("SINGULAR_CODEX_READONLY_REASONING_EFFORT", "") or ""
    ).strip():
        effort = str(env["SINGULAR_CODEX_READONLY_REASONING_EFFORT"]).strip()
        effort_source = "SINGULAR_CODEX_READONLY_REASONING_EFFORT"
    else:
        effort = CODEX_ROLE_EFFORT_DEFAULT.get(effective_role, "")
        effort_source = "runner-default" if effort else None

    tier_present = "SINGULAR_CODEX_SERVICE_TIER" in env
    raw_tier = str(env.get("SINGULAR_CODEX_SERVICE_TIER", "") or "").strip()
    if tier_present and raw_tier in {"", "normal", "standard", "default"}:
        tier, tier_source = "default", "explicit-clear" if not raw_tier else "explicit"
    elif raw_tier:
        tier, tier_source = raw_tier, "explicit"
    else:
        tier, tier_source = None, None
    return {
        "role": effective_role,
        "model": model,
        "modelSource": model_source,
        "reasoningEffort": effort or None,
        "reasoningEffortSource": effort_source,
        "requestedServiceTier": tier,
        "serviceTierSource": tier_source,
        # Codex JSONL does not currently attest the queue actually used.
        "providerObservedServiceTier": None,
    }


def effective_configuration(
    repo: Path | str,
    env: Mapping[str, str],
    *,
    environment_is_effective: bool = False,
) -> dict[str, Any]:
    """Return the shared read-only effective configuration diagnostic."""
    root = Path(repo).resolve()
    resolution = resolve_json_config(root, env)
    try:
        config, resolution = load_json_config(root, env)
        status, error = "ok", ""
    except ConfigResolutionError as exc:
        config, status, error = {}, "error", str(exc)
    effective_env = {str(key): str(value) for key, value in env.items()}
    config_env = config.get("env") if isinstance(config.get("env"), dict) else {}
    if not environment_is_effective:
        for key, value in config_env.items():
            if isinstance(value, (str, int, float)) and not isinstance(value, bool):
                effective_env[str(key)] = str(value)

    def consumer_path(key: str, fallback: str) -> str:
        raw = str(effective_env.get(key, "") or "").strip()
        path = Path(raw).expanduser() if raw else root / fallback
        if not path.is_absolute():
            path = root / path
        return str(path.resolve())

    runner = str(
        config_env.get("SINGULAR_RUNNER")
        or config.get("runner")
        or effective_env.get("SINGULAR_RUNNER")
        or "codex-run.sh"
    )
    roles = {
        role: codex_role_settings(effective_env, role, "gpt-5.5")
        for role in (
            "planner", "implementer", "auditor", "critic", "decider",
            "supervisor", "integrator",
        )
    }
    result: dict[str, Any] = {
        "schema": "singular.effective-configuration.v1",
        "configuration": {
            "path": str(resolution.path),
            "source": resolution.source,
            "status": status,
        },
        "runner": runner,
        "paths": {
            "root": str(root),
            "tasks": consumer_path("SINGULAR_TASKS_DIR", "docs/orchestration/tasks"),
            "state": consumer_path("SINGULAR_STATE_DIR", ".singular-state"),
        },
        "roles": roles,
    }
    if error:
        result["configuration"]["message"] = error
    return result


@dataclass(frozen=True)
class ProviderResolution:
    """One provider's resolved executable plus why it resolved that way."""

    provider: str
    binary: str
    path: str | None
    source: str          # "configured" | "path" | "none"
    outcome: str
    configured: str | None
    override_key: str | None
    message: str
    exit_code: int       # 0 | 2 | 127 — mirrors singular_resolve_codex_bin's rc

    @property
    def ok(self) -> bool:
        return self.outcome == OK


def _first_existing_on_path(binary: str, search_path: str) -> str | None:
    """First PATH entry holding a file named ``binary``, executable or not."""
    for entry in search_path.split(os.pathsep):
        if not entry:
            continue
        candidate = os.path.join(entry, binary)
        if os.path.isfile(candidate):
            return candidate
    return None


def resolve_provider_bin(provider: str, binary: str,
                         env: Mapping[str, str]) -> ProviderResolution:
    """Resolve ``binary`` exactly as engine/lib.sh does.

    ``env`` must be the environment the ENGINE would see, not os.environ: config
    ``env{}`` is exported over the process environment by lib.sh, so a console
    reading only its own environment sees a different answer than the runner.
    """
    override_key = OVERRIDE_ENV_KEYS.get(provider)
    configured = (env.get(override_key) or "").strip() if override_key else ""

    if configured:
        if not os.path.isabs(configured):
            return ProviderResolution(
                provider=provider, binary=binary, path=None, source="none",
                outcome=NOT_ABSOLUTE, configured=configured,
                override_key=override_key,
                message=f"{override_key} must be an absolute path: {configured}",
                exit_code=2)
        # An explicitly configured executable that is broken is a hard stop. It
        # is NEVER replaced by another PATH candidate — silently running a
        # different binary than the operator pinned is the whole defect.
        if not (os.path.isfile(configured) and os.access(configured, os.X_OK)):
            return ProviderResolution(
                provider=provider, binary=binary, path=None, source="none",
                outcome=NOT_EXECUTABLE, configured=configured,
                override_key=override_key,
                message=f"{override_key} is not executable: {configured}",
                exit_code=127)
        # Preserved as the operator spelled it: on macOS realpath() would
        # rewrite /var -> /private/var and the path would stop matching what
        # they configured.
        return ProviderResolution(
            provider=provider, binary=binary, path=configured,
            source="configured", outcome=OK, configured=configured,
            override_key=override_key, message="", exit_code=0)

    # `path=""` (not None) is deliberate: shutil.which(None) falls back to
    # os.environ/os.defpath, which would reintroduce exactly the split-brain
    # this module exists to remove. An empty PATH must mean "found nothing".
    search_path = env.get("PATH", "")
    found = shutil.which(binary, path=search_path)
    if not found:
        # Match `command -v` exactly. Verified bash behaviour: it prefers an
        # executable candidate (like shutil.which), but when the ONLY candidate
        # on PATH is non-executable it returns that path anyway. lib.sh then
        # reports "resolved ... is not executable", which is a materially better
        # diagnostic than "not found" — it tells the operator the binary is
        # right there with the wrong mode. shutil.which alone would lose that.
        found = _first_existing_on_path(binary, search_path)
    if not found:
        hint = f" (set {override_key})" if override_key else ""
        return ProviderResolution(
            provider=provider, binary=binary, path=None, source="none",
            outcome=NOT_ON_PATH, configured=None, override_key=override_key,
            message=f"{binary} CLI not found on PATH{hint}", exit_code=127)

    # Match bash's `cd "$(dirname)" && pwd -P` — it resolves symlinks in the
    # DIRECTORY only, leaving the final component alone.
    if not os.path.isabs(found):
        found = os.path.join(os.path.realpath(os.path.dirname(found)),
                             os.path.basename(found))
    if not os.access(found, os.X_OK):
        return ProviderResolution(
            provider=provider, binary=binary, path=None, source="none",
            outcome=PATH_NOT_EXECUTABLE, configured=None,
            override_key=override_key,
            message=f"resolved {binary} CLI is not executable: {found}",
            exit_code=127)
    return ProviderResolution(
        provider=provider, binary=binary, path=found, source="path",
        outcome=OK, configured=None, override_key=override_key,
        message="", exit_code=0)


def resolve_codex_bin(env: Mapping[str, str]) -> ProviderResolution:
    """Convenience wrapper — the parity target for singular_resolve_codex_bin."""
    return resolve_provider_bin("codex", "codex", env)


def _main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    effective = sub.add_parser("effective-config")
    effective.add_argument("--repo", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "effective-config":
        print(json.dumps(effective_configuration(args.repo, os.environ), separators=(",", ":")))


if __name__ == "__main__":
    _main()
