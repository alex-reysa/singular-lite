#!/usr/bin/env python3
"""Create and verify an immutable runtime fingerprint for an autonomous campaign."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from typing import Any, Mapping


SCHEMA = "singular.orchestration.campaign-manifest.v1"
SETTING_PROJECTION_VERSION = "singular.campaign.resolved-settings.v1"
PER_RUN_SETTINGS = frozenset({"SINGULAR_INTEGRATION_RECEIPT_FILE"})

# Invocation-local outputs are not campaign policy.  They are populated by a
# runner while a model call is in flight (or by the test harness) and would make
# an otherwise immutable campaign appear to drift merely because a child
# process was launched.  Everything else in the resolved SINGULAR_* namespace
# is pinned below as a value digest, including defaults applied by lib.sh and
# consumer config/env overrides.
INVOCATION_SETTING_NAMES = {
    "SINGULAR_ATTEMPT_REVIEWER_STRATEGY",
    "SINGULAR_ATTEMPT_STARTED_AT",
    "SINGULAR_ATTEMPT_TASK_ID",
    "SINGULAR_ATTEMPT_WORKER_STRATEGY",
    "SINGULAR_AUTONOMATE_DETACHED",
    "SINGULAR_DISPATCH_BASE_SHA",
    "SINGULAR_DISPATCH_BATCH_ID",
    "SINGULAR_PLANNING_ARTIFACT_DIR",
    "SINGULAR_PLANNING_RUN_ID",
    "SINGULAR_PLAN_ATTEMPT_BASE_SHA",
    "SINGULAR_EXPECTED_CAMPAIGN_BINDING",
    "SINGULAR_EVIDENCE_CAMPAIGN_BINDING",
    # Per-dispatch compare-and-set authority. Reconcile creates a fresh token
    # for each launch and dispatch-wrap must carry it into L1, but that token is
    # not configuration or campaign policy.
    "SINGULAR_RESERVATION_OWNER",
    "SINGULAR_RESERVATION_GENERATION",
    "SINGULAR_RUNNER_ROLE",
    "SINGULAR_RUNNER_CAPABILITY_PROFILE",
    "SINGULAR_RUNNER_RUN_ID",
    "SINGULAR_TEST_TASK_CONTRACT",
    "SINGULAR_TEST_TASK_ID",
    "SINGULAR_TEST_TASKS_DIR",
    # Exact test-control and generated task-contract inputs. A new test seam is
    # not implicitly trusted: it must be reviewed and named here.
    "SINGULAR_TEST_CYCLE_MUTATE",
    "SINGULAR_TEST_PROCESS_CONTROL",
    "SINGULAR_TEST_PROCESS_CONTROL_STATE",
    "SINGULAR_WORKER_CONTRACT_EXTRA",
    "SINGULAR_WORKER_RED_LOG",
    "SINGULAR_WORKTREE_ENV_FILE",
}

# These are ephemeral child capabilities and result locations. They cross the
# provider boundary but are neither caller identity nor campaign policy.
TRANSPORT_SETTING_NAMES = {
    "SINGULAR_ORIGIN_LOCK_CAPABILITY",
    "SINGULAR_CAMPAIGN_LOCK_CAPABILITY",
    "SINGULAR_GIT_LOCK_CAPABILITY",
    "SINGULAR_RESOLVED_CAPABILITY_DECLARED",
    "SINGULAR_RESOLVED_CAPABILITY_PROFILE",
    "SINGULAR_RESOLVED_CAPABILITY_STRICT",
    "SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT",
    "SINGULAR_RUNNER_ENVELOPE",
    "SINGULAR_RUNNER_ENVELOPE_ERR",
    "SINGULAR_RUNNER_EXIT_CODE",
    "SINGULAR_RUNNER_RESULT_FILE",
    "SINGULAR_RUNNER_SESSION_RECORD",
    "SINGULAR_RUNNER_TIMEOUT_NOTE",
    "SINGULAR_EVIDENCE_SOCKET",
    "SINGULAR_EVIDENCE_CAPABILITY",
    "SINGULAR_EVIDENCE_ROLE",
}

# Host authority is retained through admission evidence but is never delegated
# to the provider process. This is one central boundary, not a per-caller scrub.
HOST_ONLY_SETTING_NAMES = {
    "SINGULAR_ORIGIN_LOCK_CAPABILITY",
    "SINGULAR_CAMPAIGN_LOCK_CAPABILITY",
    "SINGULAR_GIT_LOCK_CAPABILITY",
    "SINGULAR_RESERVATION_OWNER",
    "SINGULAR_RESERVATION_GENERATION",
    "SINGULAR_EXPECTED_CAMPAIGN_BINDING",
    "SINGULAR_CONTEXT_CONFIG_FILE",
    "SINGULAR_MEMORY_CREDENTIAL_KEY",
}


def classify_resolved_setting(name: str) -> str:
    """Classify one exact setting; unknown SINGULAR names remain policy."""
    if name in INVOCATION_SETTING_NAMES:
        return "invocation"
    if name in TRANSPORT_SETTING_NAMES:
        return "transport"
    return "policy"


def runner_child_environment(
    environment: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Return provider environment without delegating host-only authority."""
    source = environment if environment is not None else os.environ
    return {
        key: value
        for key, value in source.items()
        if key not in HOST_ONLY_SETTING_NAMES
    }


GENERATED_PARTS = {
    "__pycache__",
    ".git",
    ".singular-state",
    ".singular-cache",
    "node_modules",
}
GENERATED_SUFFIXES = {".pyc", ".pyo", ".swp", ".swo", ".tmp", ".log", ".bak"}


def sha256_file(raw: str) -> str | None:
    path = Path(raw)
    if not raw or not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_fingerprint(raw: str) -> dict[str, Any]:
    path = Path(raw) if raw else None
    present = bool(path and path.is_file())
    return {
        "path": raw or None,
        "present": present,
        "sha256": sha256_file(raw),
        "mode": stat.S_IMODE(path.stat().st_mode) if present and path is not None else None,
    }


def _identity_candidate(root: Path, path: Path) -> bool:
    relative = path.relative_to(root)
    if any(part in GENERATED_PARTS for part in relative.parts):
        return False
    if path.name == ".DS_Store" or path.suffix.lower() in GENERATED_SUFFIXES:
        return False
    return path.is_file()


def tree_fingerprint(raw: str) -> dict[str, Any]:
    """Fingerprint the bytes actually consumed below a policy/config root.

    Generated caches, editor swap/backup files and logs are excluded so normal
    execution cannot invalidate a campaign. File names, executable modes and
    contents are included; a newly added prompt is therefore drift even when no
    existing file changed.
    """
    path = Path(raw) if raw else None
    if path is None or not path.exists():
        return {"path": raw or None, "present": False, "kind": None, "files": 0, "sha256": None}
    if path.is_file():
        return {
            "path": raw,
            "present": True,
            "kind": "file",
            "files": 1,
            "sha256": sha256_file(raw),
            "mode": stat.S_IMODE(path.stat().st_mode),
        }
    if not path.is_dir():
        return {"path": raw, "present": True, "kind": "other", "files": 0, "sha256": None}

    scan_root = path.resolve()
    digest = hashlib.sha256()
    candidates = sorted(
        (candidate for candidate in scan_root.rglob("*") if _identity_candidate(scan_root, candidate)),
        key=lambda candidate: candidate.relative_to(scan_root).as_posix(),
    )
    for candidate in candidates:
        relative = candidate.relative_to(scan_root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(stat.S_IMODE(candidate.stat().st_mode).to_bytes(4, "big"))
        with candidate.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    return {
        "path": raw,
        "resolvedPath": str(scan_root),
        "present": True,
        "kind": "directory",
        "files": len(candidates),
        "sha256": digest.hexdigest(),
    }


def source_fingerprint(engine_home: str) -> str:
    """Hash every shipped policy/executable source, including relative paths.

    VERSION alone cannot catch an in-place hot patch. This intentionally works
    for both a Git checkout and a copied installed engine and therefore catches
    a changed reconcile/driver/runner file even when no release version moved.
    """
    root = Path(engine_home)
    digest = hashlib.sha256()
    candidates: list[Path] = []
    def shipped_source(path: Path) -> bool:
        return _identity_candidate(root, path)

    # Templates are executable policy just as much as the shell and Python
    # drivers: changing a planner/auditor prompt during a campaign must be
    # detected.  Runtime caches and compiled bytecode are deliberately excluded
    # so merely importing a Python helper cannot create false campaign drift.
    for relative in ("engine", "schemas", "singular-ext", "templates", "vendor"):
        directory = root / relative
        if directory.is_dir():
            candidates.extend(path for path in directory.rglob("*") if shipped_source(path))
    for relative in ("cli/singular", "VERSION", "SCHEMA_VERSION"):
        path = root / relative
        if path.is_file():
            candidates.append(path)
    for path in sorted(set(candidates), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(stat.S_IMODE(path.stat().st_mode).to_bytes(4, "big"))
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def configured_brain_identity(config_json: str) -> dict[str, Any]:
    """Fingerprint the declared producer config, not its generated outputs."""
    config_path = Path(config_json) if config_json else None
    if config_path is None or not config_path.is_file():
        return {"configured": False, **file_fingerprint("")}
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"configured": False, **file_fingerprint("")}
    raw = data.get("brainConfig") if isinstance(data, dict) else None
    if not isinstance(raw, str) or not raw:
        return {"configured": False, **file_fingerprint("")}
    selected = Path(raw).expanduser()
    if not selected.is_absolute():
        selected = config_path.resolve().parent / selected
    selected = selected.resolve()
    return {"configured": True, **file_fingerprint(str(selected))}


def model_identity() -> dict[str, dict[str, Any]]:
    # Never persist raw environment values. Besides model names, a consumer may
    # reasonably have SINGULAR_MODEL_API_KEY or a provider argument containing
    # a credential; resolvedSettings already proves equality using digests.
    identity: dict[str, dict[str, Any]] = {}
    for key, value in sorted(os.environ.items()):
        if key in PER_RUN_SETTINGS:
            # Set by the reconciler for one integration run (TASK-1114's
            # integration receipt); never part of the frozen configuration.
            # Capturing it made every integration under a manifest created
            # before it existed report "drift" (2026-09-16).
            continue
        if not key.startswith("SINGULAR_"):
            continue
        if "MODEL" not in key and "EFFORT" not in key and key not in {
            "SINGULAR_RUNNER",
            "SINGULAR_ADAPTER_PROVIDERS_JSON",
        }:
            continue
        raw = value.encode("utf-8")
        identity[key] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
    return identity


def resolved_settings_projection(
    environment: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    """Return a secret-safe identity for every resolved campaign setting.

    campaign.sh exports all scalar SINGULAR_* variables after lib.sh has applied
    JSON, shell, local and default configuration. Values are never written to
    the manifest: only their byte length and SHA-256 digest are retained.
    """
    identities: dict[str, dict[str, dict[str, Any]]] = {
        "policy": {}, "invocation": {}, "transport": {},
    }
    source = environment if environment is not None else os.environ
    for key, value in sorted(source.items()):
        if not key.startswith("SINGULAR_"):
            continue
        if key in PER_RUN_SETTINGS:
            # Per-run values the reconciler sets for one integration; never
            # part of the frozen identity (2026-09-16 integration drift).
            continue
        raw = value.encode("utf-8")
        identities[classify_resolved_setting(key)][key] = {
            "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()
        }
    return {"version": SETTING_PROJECTION_VERSION, **identities}


def resolved_settings_identity(
    environment: Mapping[str, str] | None = None,
) -> dict[str, dict[str, Any]]:
    """Return only the authoritative policy portion used by campaign drift."""
    return resolved_settings_projection(environment)["policy"]


def active_policy_identity(specifications: list[str]) -> dict[str, dict[str, Any]]:
    policies: dict[str, dict[str, Any]] = {}
    for specification in specifications:
        label, separator, raw = specification.partition("=")
        if not separator or not label:
            raise ValueError(f"invalid active policy specification: {specification!r}")
        if label in policies:
            raise ValueError(f"duplicate active policy label: {label}")
        policies[label] = tree_fingerprint(raw)
    return policies


def command_version(argv: list[str]) -> str | None:
    try:
        result = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    output = (result.stdout or result.stderr).strip()
    return output.splitlines()[0][:512] if output else None


def current(args: argparse.Namespace) -> dict[str, Any]:
    version_path = Path(args.engine_home) / "VERSION"
    schema_path = Path(args.engine_home) / "SCHEMA_VERSION"
    engine_version = version_path.read_text(encoding="utf-8").strip() if version_path.is_file() else ""
    schema_version = schema_path.read_text(encoding="utf-8").strip() if schema_path.is_file() else ""
    return {
        "schema": SCHEMA,
        "engine": {
            "home": args.engine_home,
            "version": engine_version or None,
            "schemaVersion": schema_version or None,
            "versionFile": file_fingerprint(str(version_path)),
            "lib": file_fingerprint(str(Path(args.engine_home) / "engine" / "lib.sh")),
            "sourceFingerprint": source_fingerprint(args.engine_home),
        },
        "configuration": {
            "json": file_fingerprint(args.config_json),
            "shell": file_fingerprint(args.config_shell),
            # Hash only: local config may contain secrets and is never copied.
            "local": file_fingerprint(args.config_local),
            "brain": configured_brain_identity(args.config_json),
            "resolvedSettings": resolved_settings_identity(),
            "resolvedSettingsProjectionVersion": SETTING_PROJECTION_VERSION,
        },
        "activePolicy": active_policy_identity(args.active_policy),
        "runtime": {"bash": args.bash_bin, "bashVersion": command_version([args.bash_bin, "--version"])},
        "runner": {**file_fingerprint(args.runner), "modelIdentity": model_identity()},
        "gate": {
            "command": args.gate_command or None,
            "driver": file_fingerprint(args.gate_driver),
            "schema": file_fingerprint(args.gate_schema),
        },
        "evidence": {
            "driver": file_fingerprint(args.evidence_driver),
            "packetSchema": file_fingerprint(args.packet_schema),
            "auditSchema": file_fingerprint(args.audit_schema),
        },
    }


def atomic_write(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def flatten(value: Any, prefix: str = "") -> dict[str, Any]:
    if isinstance(value, dict):
        flattened: dict[str, Any] = {}
        for key in sorted(value):
            child = f"{prefix}.{key}" if prefix else key
            flattened.update(flatten(value[key], child))
        return flattened
    return {prefix: value}


def drift(expected: dict[str, Any], actual: dict[str, Any]) -> list[dict[str, Any]]:
    old, new = flatten(expected), flatten(actual)
    return [
        {"field": key, "expected": old.get(key), "actual": new.get(key)}
        for key in sorted(set(old) | set(new))
        if old.get(key) != new.get(key)
    ]


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--engine-home", required=True)
    parser.add_argument("--config-json", required=True)
    parser.add_argument("--config-shell", required=True)
    parser.add_argument("--config-local", required=True)
    parser.add_argument("--bash-bin", required=True)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--gate-command", default="")
    parser.add_argument("--gate-driver", required=True)
    parser.add_argument("--gate-schema", required=True)
    parser.add_argument("--evidence-driver", required=True)
    parser.add_argument("--packet-schema", required=True)
    parser.add_argument("--audit-schema", required=True)
    parser.add_argument("--active-policy", action="append", default=[])


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create")
    create.add_argument("--output", required=True)
    create.add_argument("--campaign-id", required=True)
    create.add_argument("--campaign-epoch", default="")
    create.add_argument("--provider-assurance", required=True)
    add_common(create)
    verify = sub.add_parser("verify")
    verify.add_argument("--manifest", required=True)
    add_common(verify)
    args = parser.parse_args()
    snapshot = current(args)
    if args.command == "create":
        snapshot["campaignId"] = args.campaign_id
        if args.campaign_epoch:
            snapshot["campaignEpoch"] = args.campaign_epoch
        snapshot["createdAt"] = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        snapshot["assurance"] = {"provider": args.provider_assurance}
        atomic_write(Path(args.output), snapshot)
        print(json.dumps(snapshot, sort_keys=True))
        return 0
    try:
        manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(json.dumps({"ok": False, "reason": "manifest-unreadable", "error": str(exc)}))
        return 2
    if manifest.get("schema") != SCHEMA:
        print(json.dumps({"ok": False, "reason": "manifest-schema", "expected": SCHEMA, "actual": manifest.get("schema")}))
        return 2
    expected = {
        key: value
        for key, value in manifest.items()
        if key not in {"campaignId", "campaignEpoch", "createdAt", "assurance"}
    }
    changes = drift(expected, snapshot)
    print(json.dumps({"ok": not changes, "campaignId": manifest.get("campaignId"), "manifest": args.manifest, "drift": changes}, sort_keys=True))
    return 0 if not changes else 3


if __name__ == "__main__":
    raise SystemExit(main())
