#!/usr/bin/env python3
"""Resolve and invoke the pinned singular-brain producer.

The consumer selects a brain configuration explicitly or through brainConfig
in its selected singular JSON configuration.  This module is also imported by
doctor so both surfaces use identical path and payload rules.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Mapping, Sequence


EXPECTED_VERSION = "0.2.0"
EXPECTED_SCHEMA_VERSION = "1"
EXPECTED_REVISION = "e05f259be5cabda2bb8caa241f23cc1f48e9f059"
COMMANDS = {"gen", "check", "lint", "bless"}


class BrainConfigurationError(ValueError):
    """A configured producer input is absent or invalid."""


class BrainUnconfigured(BrainConfigurationError):
    """The opt-in brainConfig key was not supplied."""


def absolute_path(raw: str, base: Path) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def selected_singular_config_path(
    repo_root: Path | None,
    *,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
) -> Path:
    values = os.environ if env is None else env
    invocation_dir = (cwd or Path.cwd()).resolve()
    selected = values.get("SINGULAR_JSON_CONFIG_FILE", "")
    if selected:
        return absolute_path(selected, invocation_dir)
    if repo_root is None:
        raise BrainConfigurationError(
            "no consumer repository was found; pass --config PATH or set SINGULAR_JSON_CONFIG_FILE"
        )
    return (repo_root.resolve() / "singular.config.json").resolve()


def load_singular_config(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise BrainConfigurationError(f"selected singular configuration does not exist: {path}") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise BrainConfigurationError(f"selected singular configuration is invalid: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise BrainConfigurationError(f"selected singular configuration must contain a JSON object: {path}")
    return value


def resolve_brain_config(
    *,
    explicit: str | None,
    repo_root: Path | None,
    cwd: Path,
    env: Mapping[str, str] | None = None,
) -> tuple[Path, Path | None]:
    """Return (absolute brain config, selected singular config if consulted)."""
    if explicit is not None:
        if not explicit:
            raise BrainConfigurationError("--config requires a non-empty path")
        return absolute_path(explicit, cwd), None
    singular_path = selected_singular_config_path(repo_root, env=env, cwd=cwd)
    config = load_singular_config(singular_path)
    raw = config.get("brainConfig")
    if raw is None:
        raise BrainUnconfigured(
            f"brain is unconfigured in {singular_path}; add a non-empty brainConfig path or pass --config PATH"
        )
    if not isinstance(raw, str) or not raw:
        raise BrainConfigurationError(f"brainConfig in {singular_path} must be a non-empty string")
    return absolute_path(raw, singular_path.parent), singular_path


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_vendor(engine_home: Path) -> tuple[Path | None, str | None]:
    vendor = engine_home / "vendor" / "singular-brain"
    if not vendor.is_dir():
        return None, f"vendored singular-brain payload is missing: {vendor}"
    try:
        version = (vendor / "VERSION").read_text(encoding="utf-8").strip()
        schema = (vendor / "SCHEMA_VERSION").read_text(encoding="utf-8").strip()
        provenance = json.loads((vendor / "PROVENANCE.json").read_text(encoding="utf-8"))
        inventory = (vendor / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"vendored singular-brain payload metadata is unreadable: {exc}"
    if version != EXPECTED_VERSION:
        return None, f"vendored singular-brain version mismatch: expected {EXPECTED_VERSION}, found {version or '<empty>'}"
    if schema != EXPECTED_SCHEMA_VERSION:
        return None, f"vendored singular-brain schema mismatch: expected {EXPECTED_SCHEMA_VERSION}, found {schema or '<empty>'}"
    if not isinstance(provenance, dict) or provenance.get("sourceRevision") != EXPECTED_REVISION:
        return None, f"vendored singular-brain provenance does not identify pinned revision {EXPECTED_REVISION}"
    seen = 0
    for line in inventory:
        if not line.strip():
            continue
        digest, separator, relative = line.partition("  ")
        if not separator or len(digest) != 64 or Path(relative).is_absolute() or ".." in Path(relative).parts:
            return None, f"vendored singular-brain hash inventory has an invalid record: {line!r}"
        target = vendor / relative
        if not target.is_file():
            return None, f"vendored singular-brain payload is incomplete; inventory file is missing: {relative}"
        if _sha256(target) != digest:
            return None, f"vendored singular-brain payload hash mismatch: {relative}"
        seen += 1
    if not seen:
        return None, "vendored singular-brain hash inventory is empty"
    cli = vendor / "engine" / "cli.mjs"
    return cli, None


def node_diagnostic(env: Mapping[str, str] | None = None) -> tuple[str | None, str | None]:
    values = os.environ if env is None else env
    node = shutil.which("node", path=values.get("PATH"))
    if not node:
        return None, "Node.js is required for configured brain manifest commands but 'node' is not on PATH"
    try:
        result = subprocess.run(
            [node, "--version"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=5, check=False, env=dict(values),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"Node.js is unusable for configured brain manifest commands: {exc}"
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        return None, f"Node.js is unusable for configured brain manifest commands: {detail[0] if detail else 'version probe failed'}"
    return node, None


def parse_manifest_arguments(argv: Sequence[str]) -> tuple[str, str | None, list[str]]:
    if not argv or argv[0] not in COMMANDS:
        raise BrainConfigurationError("usage: singular manifest {gen|check|lint|bless} [options]")
    command = argv[0]
    explicit = None
    forwarded: list[str] = []
    positional: list[str] = []
    i = 1
    while i < len(argv):
        value = argv[i]
        if value in {"--config", "--scope"}:
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                raise BrainConfigurationError(f"{value} requires a value")
            argument = argv[i + 1]
            if value == "--config":
                if explicit is not None:
                    raise BrainConfigurationError("--config may be specified only once")
                explicit = argument
            else:
                forwarded.extend((value, argument))
            i += 2
            continue
        if value == "--all":
            if command != "bless":
                raise BrainConfigurationError(f"{command} does not support --all")
            forwarded.append(value)
        elif value.startswith("-"):
            raise BrainConfigurationError(f"unsupported argument: {value}")
        else:
            positional.append(value)
        i += 1
    if positional and command != "bless":
        raise BrainConfigurationError(f"{command} does not accept entry paths: {positional[0]}")
    forwarded.extend(positional)
    return command, explicit, forwarded


def run_manifest(engine_home: Path, repo_root: Path | None, cwd: Path, argv: Sequence[str]) -> int:
    try:
        command, explicit, forwarded = parse_manifest_arguments(argv)
        config, _ = resolve_brain_config(
            explicit=explicit, repo_root=repo_root, cwd=cwd, env=os.environ
        )
        cli, vendor_error = verify_vendor(engine_home)
        if vendor_error:
            raise BrainConfigurationError(vendor_error)
        node, node_error = node_diagnostic()
        if node_error:
            raise BrainConfigurationError(node_error)
        assert cli is not None and node is not None
        result = subprocess.run(
            [node, str(cli), command, "--config", str(config), *forwarded],
            cwd=str(cwd),
            check=False,
        )
        return result.returncode
    except BrainConfigurationError as exc:
        print(f"singular manifest: {exc}", file=sys.stderr)
        return 2


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--engine-home", required=True)
    parser.add_argument("--repo-root", default="")
    parser.add_argument("--cwd", required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    forwarded = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    return run_manifest(
        Path(args.engine_home).resolve(),
        Path(args.repo_root).resolve() if args.repo_root else None,
        Path(args.cwd).resolve(),
        forwarded,
    )


if __name__ == "__main__":
    raise SystemExit(main())
