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

The provider rules remain stdlib-only. The effective-configuration projection
also imports the stdlib-only context service so every diagnostic consumer uses
the same selected context policy and workspace semantics.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import shutil
from typing import Any, Mapping

try:
    from engine.context_service import (
        ContextError,
        context_policy_view,
        resolve_context_config,
    )
except ImportError:  # installed execution from engine/
    from context_service import (  # type: ignore
        ContextError,
        context_policy_view,
        resolve_context_config,
    )

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
DIAGNOSTIC_ROLES = (
    "planner", "implementer", "auditor", "critic", "decider",
    "supervisor", "integrator",
)
DIAGNOSTIC_SETTING_KEYS = (
    "SINGULAR_MAX_CONCURRENT", "SINGULAR_MAX_DISPATCH", "SINGULAR_MAX_L1_CONCURRENT",
    "SINGULAR_ENABLE_L1_PARALLEL", "SINGULAR_L1_TASKS_PER_NODE",
    "SINGULAR_L2_SLICE_BUDGET", "SINGULAR_L2_SLICE_BUDGET_MAX",
    "SINGULAR_MAX_RETRIES", "SINGULAR_MAX_CONSEC_FAILS", "SINGULAR_MAX_HOURS",
    "SINGULAR_MIN_DISK_GB", "SINGULAR_L1_STALE_MINUTES",
    "SINGULAR_PLANNER_BACKOFF_SECONDS", "SINGULAR_PLANNER_QUOTA_BACKOFF_SECONDS",
    "SINGULAR_PLANNER_OVERLOAD_BACKOFF_SECONDS", "SINGULAR_OVERLOAD_WAIT_BUDGET",
    "SINGULAR_AUTO_INTEGRATE", "SINGULAR_PUSH", "SINGULAR_GENERATE", "SINGULAR_SLEEP",
    "SINGULAR_SUPERVISOR_INTERVAL_MIN", "SINGULAR_TARGET_BRANCH",
    "SINGULAR_PAIRED_AUDIT_PCT", "SINGULAR_CTX_PACKET", "SINGULAR_CTX_ROUTING",
    "SINGULAR_CTX_ARTIFACT_SCAN", "SINGULAR_PLAN_CRITIQUE", "SINGULAR_PLANNER_SESSION",
    "SINGULAR_AREA_PATHS", "SINGULAR_AREA_PREFIX",
)

# Safe runtime values consumed by provider discovery after the trusted shell
# configuration pass.  Credential values are deliberately excluded: this
# projection may cross a subprocess stdout boundary.  Presence of credentials
# remains a property of the console service environment and provider probes.
DIAGNOSTIC_PROVIDER_RUNTIME_KEYS = (
    "SINGULAR_CODEX_BIN", "SINGULAR_CLAUDE_BIN", "SINGULAR_GEMINI_BIN",
    "SINGULAR_OPENCODE_BIN", "SINGULAR_CURSOR_BIN", "SINGULAR_OPENROUTER_BIN",
    "SINGULAR_GROK_BIN",
)


def _provider_specs(env: Mapping[str, str]) -> dict[str, Any]:
    """Load the shipped adapter registry without importing mutable runtime code."""
    configured = str(env.get("SINGULAR_ENGINE_HOME", "") or "").strip()
    path = (Path(configured) / "engine/providers.json") if configured else Path(__file__).with_name("providers.json")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    providers = value.get("providers") if isinstance(value, dict) else None
    return providers if isinstance(providers, dict) else {}


def _runner_identity(
    root: Path, env: Mapping[str, str], raw_runner: str
) -> tuple[str, str | None, dict[str, Any]]:
    """Normalize the selected runner and prove its shipped provider identity."""
    specs = _provider_specs(env)
    adapters = {
        str(spec.get("adapter")): name
        for name, spec in specs.items()
        if isinstance(spec, dict) and spec.get("adapter")
    }
    configured_home = str(env.get("SINGULAR_ENGINE_HOME", "") or "").strip()
    engine_dir = (
        Path(configured_home).expanduser() / "engine"
        if configured_home
        else Path(__file__).resolve().parent
    ).resolve()
    selected = Path(raw_runner).expanduser()
    if len(selected.parts) == 1:
        selected = engine_dir / selected
    elif not selected.is_absolute():
        selected = root / selected
    selected = selected.resolve()
    provider = adapters.get(selected.name) if selected.parent == engine_dir else None
    return str(selected), provider, specs


def _provider_role_settings(
    env: Mapping[str, str], provider: str, role: str, default_model: str
) -> dict[str, str | None]:
    """Format only settings the selected shipped adapter actually consumes."""
    if provider == "codex":
        return codex_role_settings(env, role, default_model)
    effective_role = normalize_codex_role(role)
    prefix = provider.upper().replace("-", "_")
    global_model_key = f"SINGULAR_{prefix}_MODEL"
    global_effort_key = f"SINGULAR_{prefix}_EFFORT"
    role_suffix = {
        "implementer": "L2", "planner": "PLANNER", "auditor": "AUDITOR",
        "decider": "DECIDER",
    }.get(effective_role)
    role_model_key = f"SINGULAR_{prefix}_{role_suffix}_MODEL" if role_suffix else ""
    role_effort_key = f"SINGULAR_{prefix}_{role_suffix}_EFFORT" if role_suffix else ""
    # Gemini/OpenCode/Cursor/OpenRouter expose only their flat model setting.
    supports_role_settings = provider in {"claude", "grok"}
    model_key = role_model_key if supports_role_settings and role_model_key in env else global_model_key
    model_raw = str(env.get(model_key, "") or "").strip()
    model = model_raw or default_model or None
    model_source = model_key if model_key in env else "provider-default"
    if supports_role_settings:
        effort_key = role_effort_key if role_effort_key and role_effort_key in env else global_effort_key
        effort_raw = str(env.get(effort_key, "") or "").strip()
        effort_defaults = {
            "claude": {"implementer": "medium", "planner": "xhigh", "auditor": "xhigh"},
            "grok": {"implementer": "medium", "planner": "high", "auditor": "high"},
        }
        effort = effort_raw or effort_defaults.get(provider, {}).get(effective_role)
        effort_source = effort_key if effort_key in env else ("runner-default" if effort else None)
    else:
        effort = effort_source = None
    return {
        "role": effective_role,
        "model": model,
        "modelSource": model_source,
        "reasoningEffort": effort,
        "reasoningEffortSource": effort_source,
        "requestedServiceTier": None,
        "serviceTierSource": None,
        "providerObservedServiceTier": None,
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
    default_path = (root / "singular.config.json").resolve()
    selected = str(env.get("SINGULAR_JSON_CONFIG_FILE", "") or "").strip()
    if selected:
        path = Path(selected).expanduser()
        if not path.is_absolute():
            path = root / path
        path = path.resolve()

        bound_root_raw = str(
            env.get("SINGULAR_JSON_CONFIG_DEFAULT_ROOT", "") or ""
        ).strip()
        bound_file_raw = str(
            env.get("SINGULAR_JSON_CONFIG_DEFAULT_FILE", "") or ""
        ).strip()

        def bound_path(raw: str) -> Path | None:
            if not raw:
                return None
            value = Path(raw).expanduser()
            if not value.is_absolute():
                value = root / value
            return value.resolve()

        source = "selector"
        if (
            env.get("SINGULAR_JSON_CONFIG_SOURCE") == "default"
            and bound_path(bound_root_raw) == root
            and bound_path(bound_file_raw) == default_path
            and path == default_path
        ):
            source = "default"
        return JsonConfigResolution(path=path, source=source)
    return JsonConfigResolution(path=default_path, source="default")


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


def unavailable_effective_configuration(
    repo: Path | str,
    env: Mapping[str, str],
    message: str,
    *,
    reason: str = "configuration-unavailable",
    resolution: JsonConfigResolution | None = None,
) -> dict[str, Any]:
    """Return the single fail-closed projection used after resolution failure.

    Selected input provenance remains diagnostic evidence, but runner/provider,
    model and durable path authority are deliberately unknown.  In particular,
    inherited environment values are not an effective runtime after lib.sh
    failed before completing its precedence chain.
    """
    root = Path(repo).resolve()
    selected = resolution or resolve_json_config(root, env)

    def diagnostic_path(raw: str, fallback: Path) -> str:
        path = Path(raw).expanduser() if raw else fallback
        if not path.is_absolute():
            path = root / path
        return str(path.resolve())

    shell_raw = str(env.get("SINGULAR_CONFIG_FILE", "") or "").strip()
    local_raw = str(env.get("SINGULAR_LOCAL_CONFIG_FILE", "") or "").strip()
    engine_raw = str(env.get("SINGULAR_ENGINE_HOME", "") or "").strip()
    context_path, context_source = resolve_context_config(root, env)
    return {
        "schema": "singular.effective-configuration.v1",
        "configuration": {
            "path": str(selected.path),
            "source": selected.source,
            "status": "error",
            "reason": reason,
            "message": message,
        },
        "configurationLayers": {
            "json": str(selected.path),
            "shell": diagnostic_path(shell_raw, root / "singular.config.sh"),
            # The default local layer depends on the unresolved state root.  Only
            # an explicit selector is safe to report as input provenance.
            "local": diagnostic_path(local_raw, root) if local_raw else None,
            "engine": diagnostic_path(
                engine_raw, Path(__file__).resolve().parent.parent
            ),
        },
        "generation": {
            "id": None,
            "status": "unavailable",
            "restartRequired": False,
        },
        "runner": None,
        "provider": "unknown",
        "targetBranch": None,
        "paths": {"root": str(root), "tasks": None, "state": None},
        "roles": {},
        "roleRunners": {},
        "settings": {},
        "providerRuntime": {},
        "contextService": {
            "status": "unavailable",
            "configuration": {
                "path": str(context_path),
                "source": context_source,
                "status": "unknown",
                "sha256": None,
            },
            "workspace": str(root),
            "enabled": None,
            "roles": {},
        },
    }


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
    if resolution.source == "default" and not resolution.path.exists():
        config, status, error = {}, "absent", ""
    else:
        try:
            config, resolution = load_json_config(root, env)
            status, error = "ok", ""
        except ConfigResolutionError as exc:
            config, status, error = {}, "error", str(exc)
    if status == "error":
        return unavailable_effective_configuration(
            root, env, error, reason="json-configuration-error", resolution=resolution
        )
    effective_env = {str(key): str(value) for key, value in env.items()}
    config_env = config.get("env") if isinstance(config.get("env"), dict) else {}
    if not environment_is_effective:
        for key, value in config_env.items():
            if isinstance(value, (str, int, float)) and not isinstance(value, bool):
                effective_env[str(key)] = str(value)

    context_path, context_source = resolve_context_config(root, effective_env)
    if status == "absent" and not str(
        effective_env.get("SINGULAR_CONTEXT_CONFIG_FILE", "") or ""
    ).strip():
        context_source = "default"
        context_view: dict[str, Any] = {
            "status": "disabled",
            "configuration": {
                "path": str(context_path), "source": context_source,
                "status": "absent", "sha256": None,
            },
            "workspace": str(root), "enabled": False,
            "projectId": root.name, "budgetBytes": 65536,
            "budgetSource": "contextService.budgetBytes", "roles": {},
        }
    else:
        try:
            context_view = context_policy_view(
                context_path,
                workspace=root,
                environment=effective_env,
                source=context_source,
            )
        except ContextError as exc:
            unavailable = unavailable_effective_configuration(
                root,
                effective_env,
                f"selected context policy is invalid: {exc}",
                reason="context-policy-error",
                resolution=resolution,
            )
            unavailable["contextService"] = {
                "status": "unavailable",
                "configuration": {
                    "path": str(context_path), "source": context_source,
                    "status": "error", "sha256": None,
                },
                "workspace": str(root), "enabled": None, "roles": {},
                "message": str(exc),
            }
            return unavailable

    if not environment_is_effective:
        role_runners_cfg = config.get("roleRunners")
        if isinstance(role_runners_cfg, dict):
            for role_name, role_runner in role_runners_cfg.items():
                if (
                    isinstance(role_name, str)
                    and role_name.isalpha()
                    and role_name == role_name.lower()
                    and isinstance(role_runner, str)
                    and role_runner
                ):
                    effective_env[f"SINGULAR_ROLE_RUNNER_{role_name.upper()}"] = (
                        role_runner
                    )

    def consumer_path(key: str, fallback: str) -> str:
        raw = str(effective_env.get(key, "") or "").strip()
        path = Path(raw).expanduser() if raw else root / fallback
        if not path.is_absolute():
            path = root / path
        return str(path.resolve())

    def layer_path(key: str, fallback: Path) -> str:
        raw = str(effective_env.get(key, "") or "").strip()
        path = Path(raw).expanduser() if raw else fallback
        if not path.is_absolute():
            path = root / path
        return str(path.resolve())

    runner_raw = str(
        effective_env.get("SINGULAR_RUNNER")
        or config_env.get("SINGULAR_RUNNER")
        or config.get("runner")
        or "codex-run.sh"
    )
    runner, provider, specs = _runner_identity(root, effective_env, runner_raw)
    if provider:
        spec = specs.get(provider) if isinstance(specs.get(provider), dict) else {}
        model_spec = spec.get("model") if isinstance(spec.get("model"), dict) else {}
        default_model = str(model_spec.get("default") or "")
        provider_roles = DIAGNOSTIC_ROLES if provider == "codex" else (
            "planner", "implementer", "auditor", "decider"
        )
        roles = {
            role: _provider_role_settings(effective_env, provider, role, default_model)
            for role in provider_roles
        }
    else:
        roles = {
            role: {
                "role": normalize_codex_role(role),
                "model": None,
                "modelSource": None,
                "reasoningEffort": None,
                "reasoningEffortSource": None,
                "requestedServiceTier": None,
                "serviceTierSource": None,
                "providerObservedServiceTier": None,
            }
            for role in DIAGNOSTIC_ROLES
        }

    def role_runner_entry(role: str) -> dict[str, Any]:
        key = "SINGULAR_ROLE_RUNNER_" + role.upper().replace("-", "_")
        raw = str(effective_env.get(key, "") or "").strip()
        if raw:
            selected, selected_provider, selected_specs = _runner_identity(
                root, effective_env, raw
            )
            source = key
        else:
            selected, selected_provider, selected_specs = runner, provider, specs
            source = "default"
        selected_name = selected_provider or "unknown"
        model = reasoning = None
        if selected_provider:
            spec = (
                selected_specs.get(selected_provider)
                if isinstance(selected_specs.get(selected_provider), dict)
                else {}
            )
            model_spec = spec.get("model") if isinstance(spec.get("model"), dict) else {}
            role_settings = _provider_role_settings(
                effective_env,
                selected_provider,
                role,
                str(model_spec.get("default") or ""),
            )
            model = role_settings.get("model")
            reasoning = role_settings.get("reasoningEffort")
        return {
            "runner": selected,
            "provider": selected_name,
            "source": source,
            "model": model,
            "reasoningEffort": reasoning,
        }

    role_runners = {role: role_runner_entry(role) for role in DIAGNOSTIC_ROLES}
    result: dict[str, Any] = {
        "schema": "singular.effective-configuration.v1",
        "configuration": {
            "path": str(resolution.path),
            "source": resolution.source,
            "status": status,
        },
        "configurationLayers": {
            "json": str(resolution.path),
            "shell": layer_path("SINGULAR_CONFIG_FILE", root / "singular.config.sh"),
            "local": layer_path(
                "SINGULAR_LOCAL_CONFIG_FILE",
                Path(consumer_path("SINGULAR_STATE_DIR", ".singular-state")) / "config.local.sh",
            ),
            "engine": layer_path(
                "SINGULAR_ENGINE_HOME", Path(__file__).resolve().parent.parent),
        },
        "runner": runner,
        "provider": provider or "unknown",
        "targetBranch": str(effective_env.get("SINGULAR_TARGET_BRANCH") or "") or None,
        "paths": {
            "root": str(root),
            "tasks": consumer_path("SINGULAR_TASKS_DIR", "docs/orchestration/tasks"),
            "state": consumer_path("SINGULAR_STATE_DIR", ".singular-state"),
        },
        "roles": roles,
        "roleRunners": role_runners,
        "settings": {
            key: effective_env[key] if key in effective_env else None
            for key in DIAGNOSTIC_SETTING_KEYS
        },
        "providerRuntime": {
            "searchPath": effective_env.get("PATH", ""),
            "executables": {
                key: effective_env[key]
                for key in DIAGNOSTIC_PROVIDER_RUNTIME_KEYS
                if key in effective_env
            },
        },
        "contextService": context_view,
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
    effective.add_argument("--environment-effective", action="store_true")
    args = parser.parse_args()
    if args.command == "effective-config":
        print(json.dumps(effective_configuration(
            args.repo, os.environ,
            environment_is_effective=args.environment_effective,
        ), separators=(",", ":")))


if __name__ == "__main__":
    _main()
