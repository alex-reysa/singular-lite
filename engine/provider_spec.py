#!/usr/bin/env python3
"""The provider spec: what a provider IS, stated once.

``engine/providers.json`` carries the per-provider data that every consumer used
to keep a private copy of -- binary name, model default and id pattern, the
CLI's own model listing, the authentication probe, the update pin. That
duplication is not a tidiness complaint: the default model lived in the grok
adapter (five fallback sites) *and* in doctor's table, nothing checked either
against the installed CLI, and a model id that never existed shipped in every
grok invocation the engine ever built.

Consumers: ``engine/doctor.py``, the provider adapters, and the schema-enum
generator read this module. ``engine/lib.sh`` keeps literal tables instead --
it is sourced by every script in the engine and must not spawn an interpreter
to do it -- and ``tests/test-provider-spec.sh`` pins those literals to this
file, so a value still has exactly one place where it is decided.

Bash consumers use the ``--shell`` mode, which emits NUL-delimited key/value
pairs rather than shell assignments: no eval, no quoting rules to get wrong.

Stdlib only, no engine imports -- the same rule as ``provider_resolver.py``,
because doctor, the console and the adapters all import it from different roots.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any

SPEC_SCHEMA = "singular.provider-spec.v0"
SPEC_PATH = Path(__file__).resolve().with_name("providers.json")

# Where a provider's model inventory comes from, for the doctor conformance
# probe: the provider binary's own listing subcommand, a standalone command
# (a catalog that does not live in the CLI -- OpenRouter serves its own over
# HTTP), codex's on-disk cache, or nothing provable.
INVENTORY_LISTING = "listing"
INVENTORY_COMMAND = "command"
INVENTORY_CODEX_CACHE = "codex-cache"
INVENTORY_NONE = "none"
INVENTORIES = {
    INVENTORY_LISTING,
    INVENTORY_COMMAND,
    INVENTORY_CODEX_CACHE,
    INVENTORY_NONE,
}
INVENTORIES_WITH_ARGV = {INVENTORY_LISTING, INVENTORY_COMMAND}

# Platform keys for declared OS-enforced read-only. `any` matches every host;
# `darwin` / `linux` are sys.platform values. Values name the mechanism or an
# absolute tool path the adapter actually applies.
READ_ONLY_ENFORCEMENT_KEYS = frozenset({"any", "darwin", "linux"})

_CACHE: dict[str, dict[str, Any]] = {}


class SpecError(ValueError):
    """The spec is missing, malformed, or internally inconsistent."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SpecError(message)


def _string_list(value: Any, label: str) -> list[str]:
    _require(isinstance(value, list), f"{label} must be an array")
    for item in value:
        _require(
            isinstance(item, str) and item and item == item.strip(),
            f"{label} entries must be non-empty strings without edge whitespace",
        )
    return list(value)


def _validate(data: Any, source: str) -> dict[str, Any]:
    _require(isinstance(data, dict), f"{source}: top level must be an object")
    _require(
        data.get("schema") == SPEC_SCHEMA,
        f"{source}: schema must be {SPEC_SCHEMA}",
    )
    providers = data.get("providers")
    _require(
        isinstance(providers, dict) and providers,
        f"{source}: providers must be a non-empty object",
    )
    for name, entry in providers.items():
        label = f"{source}: provider {name}"
        _require(
            isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9-]*", name or ""),
            f"{label}: provider names are lowercase slugs",
        )
        _require(isinstance(entry, dict), f"{label} must be an object")
        for key in ("adapter", "binary"):
            _require(
                isinstance(entry.get(key), str) and entry[key],
                f"{label}.{key} must be a non-empty string",
            )
        _require(
            isinstance(entry.get("binaryEnv", ""), str),
            f"{label}.binaryEnv must be a string",
        )
        _require(
            isinstance(entry.get("strictIsolation"), bool),
            f"{label}.strictIsolation must be a boolean",
        )
        model = entry.get("model")
        _require(isinstance(model, dict), f"{label}.model must be an object")
        _require(
            isinstance(model.get("env"), str) and model["env"],
            f"{label}.model.env must be a non-empty string",
        )
        _require(
            isinstance(model.get("default", ""), str),
            f"{label}.model.default must be a string",
        )
        try:
            re.compile(str(model.get("pattern", "")))
        except re.error as exc:
            raise SpecError(f"{label}.model.pattern is not a regex: {exc}") from exc
        inventory = model.get("inventory")
        _require(
            inventory in INVENTORIES,
            f"{label}.model.inventory must be one of {sorted(INVENTORIES)}",
        )
        listing = _string_list(model.get("listing", []), f"{label}.model.listing")
        _require(
            bool(listing) == (inventory in INVENTORIES_WITH_ARGV),
            f"{label}.model.listing is required by, and only by, inventories "
            f"{sorted(INVENTORIES_WITH_ARGV)}",
        )
        _require(
            isinstance(model.get("listingPrefix", ""), str),
            f"{label}.model.listingPrefix must be a string",
        )
        auth = entry.get("auth")
        _require(isinstance(auth, dict), f"{label}.auth must be an object")
        probe = _string_list(auth.get("probe", []), f"{label}.auth.probe")
        env_names = _string_list(auth.get("env", []), f"{label}.auth.env")
        files = _string_list(
            auth.get("credentialFiles", []), f"{label}.auth.credentialFiles"
        )
        for path in files:
            _require(
                not path.startswith(("/", "~")),
                f"{label}.auth.credentialFiles entries are HOME-relative",
            )
        _require(
            bool(probe) != bool(env_names or files),
            f"{label}.auth declares either a probe command or an env/credential "
            "pair, never both and never neither",
        )
        _require(
            isinstance(auth.get("hint", ""), str),
            f"{label}.auth.hint must be a string",
        )
        pin = entry.get("updatePin")
        _require(isinstance(pin, dict), f"{label}.updatePin must be an object")
        _string_list(pin.get("args", []), f"{label}.updatePin.args")
        pin_env = pin.get("env", {})
        _require(isinstance(pin_env, dict), f"{label}.updatePin.env must be an object")
        for key, value in pin_env.items():
            _require(
                isinstance(key, str)
                and bool(re.fullmatch(r"[A-Z][A-Z0-9_]*", key))
                and isinstance(value, str)
                and value != "",
                f"{label}.updatePin.env maps NAME to a non-empty string",
            )
        # An unpinnable CLI is a fact to record, not a blank to leave: the
        # evidence line is what a reviewer reads instead of re-deriving it.
        _require(
            isinstance(pin.get("evidence"), str) and pin["evidence"],
            f"{label}.updatePin.evidence must say what pins it, or why nothing does",
        )
        enforcement = entry.get("readOnlyEnforcement", {})
        _require(
            isinstance(enforcement, dict),
            f"{label}.readOnlyEnforcement must be an object",
        )
        for key, value in enforcement.items():
            _require(
                key in READ_ONLY_ENFORCEMENT_KEYS,
                f"{label}.readOnlyEnforcement keys must be one of "
                f"{sorted(READ_ONLY_ENFORCEMENT_KEYS)}",
            )
            _require(
                isinstance(value, str) and value and value == value.strip(),
                f"{label}.readOnlyEnforcement.{key} must be a non-empty string",
            )
    adapters = [entry["adapter"] for entry in providers.values()]
    _require(
        len(set(adapters)) == len(adapters),
        f"{source}: two providers claim the same adapter",
    )
    return data


def load(path: Path | str | None = None) -> dict[str, Any]:
    """The validated spec document. Cached per resolved path."""
    resolved = Path(path).resolve() if path else SPEC_PATH
    key = str(resolved)
    if key not in _CACHE:
        try:
            raw = json.loads(resolved.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise SpecError(f"provider spec is missing: {resolved}") from exc
        except (OSError, json.JSONDecodeError) as exc:
            raise SpecError(f"provider spec is unreadable: {exc}") from exc
        _CACHE[key] = _validate(raw, str(resolved))
    return _CACHE[key]


def providers(path: Path | str | None = None) -> dict[str, dict[str, Any]]:
    return load(path)["providers"]


def names(path: Path | str | None = None) -> list[str]:
    """Provider ids in spec order -- the order enums and messages use."""
    return list(providers(path))


def entry(provider: str, path: Path | str | None = None) -> dict[str, Any]:
    found = providers(path).get(provider)
    if found is None:
        raise SpecError(f"unknown provider: {provider}")
    return found


def adapter_providers(path: Path | str | None = None) -> dict[str, str]:
    """{adapter basename: provider} -- lib.sh's basename map, from the spec."""
    return {item["adapter"]: name for name, item in providers(path).items()}


def binaries(path: Path | str | None = None) -> dict[str, str]:
    return {name: item["binary"] for name, item in providers(path).items()}


def model_env(path: Path | str | None = None) -> dict[str, tuple[str, str]]:
    return {
        name: (item["model"]["env"], item["model"].get("default", ""))
        for name, item in providers(path).items()
    }


def model_patterns(path: Path | str | None = None) -> dict[str, re.Pattern[str]]:
    return {
        name: re.compile(item["model"]["pattern"])
        for name, item in providers(path).items()
    }


def model_inventory(provider: str, path: Path | str | None = None) -> str:
    """Where this provider's model catalog is read from (INVENTORY_*)."""
    return str(entry(provider, path)["model"].get("inventory", INVENTORY_NONE))


def model_listing_prefix(provider: str, path: Path | str | None = None) -> str:
    """Namespace the listing's ids are relative to.

    OpenRouter's catalog serves `anthropic/claude-x` while the engine dispatches
    `openrouter/anthropic/claude-x`, so the comparison needs one of the two
    normalized. Normalizing the LISTING is the safe direction: nothing is
    stripped off the operator's configured value before it is checked.
    """
    return str(entry(provider, path)["model"].get("listingPrefix", ""))


def model_listing(provider: str, path: Path | str | None = None) -> tuple[str, ...]:
    """The argv that lists models -- update pin included where one applies.

    For a listing served by the provider binary the pin is prepended here rather
    than written into the listing itself, so it cannot be forgotten: doctor runs
    that argv against a real provider binary during preflight, and a CLI that
    can replace its own executable while answering would swap the binary the run
    is about to use. A standalone catalog command runs no provider binary, so
    there is nothing to pin.
    """
    item = entry(provider, path)
    model = item["model"]
    inventory = model.get("inventory")
    if inventory == INVENTORY_COMMAND:
        return tuple(model["listing"])
    if inventory != INVENTORY_LISTING:
        return ()
    return tuple(item["updatePin"].get("args", [])) + tuple(model["listing"])


def update_pin(
    provider: str, path: Path | str | None = None
) -> tuple[tuple[str, ...], dict[str, str]]:
    pin = entry(provider, path)["updatePin"]
    return tuple(pin.get("args", [])), dict(pin.get("env", {}))


def read_only_enforcement(
    provider: str, path: Path | str | None = None
) -> dict[str, str]:
    """Declared OS-enforced read-only mechanism, keyed by platform (`any`/`darwin`/`linux`)."""
    raw = entry(provider, path).get("readOnlyEnforcement") or {}
    if not isinstance(raw, dict):
        return {}
    return {str(key): str(value) for key, value in raw.items()}


def strict_isolation_providers(path: Path | str | None = None) -> set[str]:
    """Providers with a proven built-in isolation mode.

    Its complement is the set whose strict profiles need an operator-validated
    providerArgs argv instead -- doctor and lib.sh both refuse a strict profile
    there, and both must refuse for the same six-name reason.
    """
    return {
        name for name, item in providers(path).items() if item["strictIsolation"]
    }


def shell_pairs(provider: str, path: Path | str | None = None) -> list[tuple[str, str]]:
    """Flat key/value pairs for the bash consumers (see --shell)."""
    item = entry(provider, path)
    model = item["model"]
    pin_args, pin_env = update_pin(provider, path)
    pairs = [
        ("provider", provider),
        ("adapter", item["adapter"]),
        ("binary", item["binary"]),
        ("binaryEnv", item.get("binaryEnv", "")),
        ("modelEnv", model["env"]),
        ("modelDefault", model.get("default", "")),
        ("modelPrefix", model.get("listingPrefix", "")),
    ]
    pairs += [("updateArg", value) for value in pin_args]
    pairs += [("updateEnv", f"{name}={value}") for name, value in pin_env.items()]
    for key, value in read_only_enforcement(provider, path).items():
        pairs.append((f"readOnlyEnforcement.{key}", value))
    return pairs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read engine/providers.json")
    parser.add_argument("--spec", default="", help="spec path (default: engine/providers.json)")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--shell", metavar="PROVIDER", help="NUL-delimited key/value pairs")
    mode.add_argument("--names", action="store_true", help="provider ids, one per line")
    mode.add_argument("--validate", action="store_true", help="parse and validate only")
    args = parser.parse_args(argv)
    path = args.spec or None
    try:
        if args.names:
            for name in names(path):
                print(name)
        elif args.shell:
            out = sys.stdout.buffer
            for key, value in shell_pairs(args.shell, path):
                out.write(key.encode() + b"\0" + value.encode() + b"\0")
            out.flush()
        else:
            load(path)
    except SpecError as exc:
        print(f"provider-spec: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
