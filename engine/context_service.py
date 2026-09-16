#!/usr/bin/env python3
"""Bounded, immutable local context retrieval for Singular.

The service is intentionally standard-library-only.  A service instance is one
immutable read snapshot: configuration and authorized source bytes are read
once, while ``get`` additionally checks the live file against that snapshot so
a stale reference can never be used to read changed bytes.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence

try:  # Import works both as engine.context_service and as an installed script.
    from engine import brain_documents, capability_policy, memory_service
except ImportError:  # pragma: no cover - exercised by the installed CLI
    import brain_documents  # type: ignore
    import capability_policy  # type: ignore
    import memory_service  # type: ignore


BUNDLE_SCHEMA = "singular.context.bundle.v1"
SEARCH_SCHEMA = "singular.context.search.v1"
GET_SCHEMA = "singular.context.get.v1"
EXPLAIN_SCHEMA = "singular.context.explain.v1"
POLICY_VERSION = "singular.context.policy.v1"
POLICY_BINDING_VERSION = "singular.context.policy-binding.v1"
RETRIEVAL_VERSION = "exact-lexical.v1"
ENVELOPE_VERSION = "singular.context.envelope.v1"
ESTIMATOR_IDENTITY = "utf8-exact.v1"
#: Every host binding the envelope publishes. A value of ``None`` is preserved
#: explicitly and named in ``unknownBindings``; it is never silently dropped and
#: never reported as a zero or an empty string.
ENVELOPE_IDENTITY_FIELDS = (
    "taskContractSha256",
    "runId",
    "attemptId",
    "sessionId",
    "candidateRevision",
    "requestedModel",
    "effectiveModel",
    "providerName",
    "providerExecutable",
    "providerBuild",
    "capabilityProfile",
    "campaignBinding",
)
#: Bindings a STRICT admission must have. ``sessionId`` and ``providerBuild``
#: are genuinely unknowable at some supported entrypoints, so they stay
#: explicitly unknown rather than blocking an otherwise fully bound invocation.
ENVELOPE_REQUIRED_BINDINGS = tuple(
    name for name in ENVELOPE_IDENTITY_FIELDS
    if name not in {"sessionId", "providerBuild"}
)
#: Prompt components the host neither composes nor can measure. They are
#: reported as unknown; they are never assumed to be zero.
UNKNOWN_PROMPT_COMPONENTS = (
    "provider_system_content",
    "tool_schemas",
    "session_history",
    "model_output",
)
OUTPUT_RESERVE_ENFORCEMENT = (
    "host-requested output reserve; no provider-enforced output cap is "
    "demonstrated for any supported provider build, so this reserve is a host "
    "budgeting decision and not a provider guarantee"
)
OVERLAP_RULE = (
    "accounts partition the delivered prompt: every delivered byte is charged "
    "exactly once, to exactly one account, and no byte is counted twice"
)
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:/-]*")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)
OBLIGATION_RE = re.compile(r"\[(open|violated)\]", re.IGNORECASE)
LEXICAL_LIMIT = (
    "exact/lexical retrieval only; synonyms and semantic paraphrases may be "
    "missed, so an empty result is an abstention rather than evidence of absence"
)


class ContextError(ValueError):
    """A context source, request, or immutable reference is invalid."""


class ContextOverflow(ContextError):
    """Mandatory context cannot fit within the host-managed byte budget."""


def resolve_context_config(
    workspace: str | os.PathLike[str],
    environment: Mapping[str, str],
    *,
    explicit: str | os.PathLike[str] | None = None,
    invocation_directory: str | os.PathLike[str] | None = None,
) -> tuple[Path, str]:
    """Resolve the one context policy selected for an invocation.

    An explicit CLI argument is relative to the invocation directory. Runtime
    selectors are relative to the project root, matching lib.sh's configuration
    path normalization. The selected JSON configuration is the legacy fallback.
    """
    root = Path(os.path.abspath(workspace)).resolve()
    if explicit is not None and str(explicit).strip():
        raw = Path(str(explicit)).expanduser()
        base = Path(os.path.abspath(invocation_directory or os.getcwd())).resolve()
        return ((base / raw).resolve() if not raw.is_absolute() else raw.resolve()), "explicit"
    selected = str(environment.get("SINGULAR_CONTEXT_CONFIG_FILE", "") or "").strip()
    if selected:
        raw = Path(selected).expanduser()
        return ((root / raw).resolve() if not raw.is_absolute() else raw.resolve()), "selector"
    selected = str(environment.get("SINGULAR_JSON_CONFIG_FILE", "") or "").strip()
    if selected:
        raw = Path(selected).expanduser()
        return ((root / raw).resolve() if not raw.is_absolute() else raw.resolve()), "json"
    return (root / "singular.config.json").resolve(), "default"


def _sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def _read_json(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except FileNotFoundError as exc:
        raise ContextError(f"{label} is missing: {path}") from exc
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ContextError(f"{label} is invalid: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ContextError(f"{label} must be a JSON object: {path}")
    return value, raw


def _relative(raw: Any, label: str) -> str:
    if not isinstance(raw, str) or not raw or "\\" in raw or "\x00" in raw:
        raise ContextError(f"containment: {label} must be a safe relative POSIX path")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ContextError(f"containment: {label} escapes the configured project: {raw!r}")
    if path.as_posix() != raw or re.match(r"^[A-Za-z]:", raw):
        raise ContextError(f"containment: {label} is not canonical: {raw!r}")
    return raw


def _contained(root: Path, relative: str, label: str) -> Path:
    candidate = root.joinpath(*PurePosixPath(relative).parts)
    # resolve(strict=False) resolves every existing parent and therefore catches
    # symlink escapes even when the final leaf is missing.
    resolved = candidate.resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ContextError(f"containment: {label} resolves outside {root}: {resolved}") from exc
    return resolved


def _git_revision(root: Path, config_hash: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        result = None
    if result is not None and result.returncode == 0 and re.fullmatch(
        r"[0-9a-f]{40,64}", result.stdout.strip()
    ):
        return result.stdout.strip()
    return "unversioned:" + config_hash.removeprefix("sha256:")


def _utf8_prefix(data: bytes, limit: int) -> tuple[bytes, bool]:
    if len(data) <= limit:
        return data, False
    clipped = data[: max(0, limit)]
    while clipped:
        try:
            clipped.decode("utf-8")
            break
        except UnicodeDecodeError:
            clipped = clipped[:-1]
    return clipped, True


@dataclass(frozen=True)
class Source:
    ref: str
    kind: str
    path: Path
    relative_path: str
    title: str
    description: str
    raw: bytes | None
    source_hash: str | None
    validity: str
    provenance: dict[str, Any]

    @property
    def text(self) -> str:
        return self.raw.decode("utf-8", "replace") if self.raw is not None else ""


def _output_reserve_record(
    value: Mapping[str, Any] | None, provider: str | None = None
) -> dict[str, Any]:
    """Normalize a requested output reserve without inventing a conversion.

    A reserve declared in ``utf8-bytes`` is exact host-managed accounting and is
    subtracted from the byte allowance. A reserve declared in ``tokens`` has no
    supported byte conversion for any provider Singular launches, so it is
    recorded and explicitly NOT subtracted from a byte limit.
    """
    record: dict[str, Any] = {
        "requested": None,
        "conversion": None,
        "reservedBytes": None,
        "appliedToByteLimit": False,
        "enforcement": OUTPUT_RESERVE_ENFORCEMENT,
    }
    if value is None:
        return record
    if not isinstance(value, Mapping):
        raise ContextError("output reserve must be an object")
    unit = value.get("unit")
    amount = value.get("value")
    if unit not in {"tokens", "utf8-bytes"}:
        raise ContextError("output reserve unit must be tokens or utf8-bytes")
    if not isinstance(amount, int) or isinstance(amount, bool) or amount < 0:
        raise ContextError("output reserve value must be a non-negative integer")
    record["requested"] = dict(value)
    if unit == "utf8-bytes":
        record["reservedBytes"] = amount
        record["appliedToByteLimit"] = True
        return record
    conversion = capability_policy.output_reserve_conversion(provider or "")
    record["conversion"] = conversion
    if conversion is not None:  # pragma: no cover - no provider declares one yet
        record["reservedBytes"] = int(amount * conversion["bytesPerToken"])
        record["appliedToByteLimit"] = True
    return record


def _budget_record(
    *,
    limit_bytes: int,
    used_bytes: int,
    mandatory_bytes: int,
    optional_bytes: int,
    evidence_bytes: int,
    reserve: dict[str, Any],
) -> dict[str, Any]:
    """One budget block with separated, disjoint host accounts."""
    reserved = reserve["reservedBytes"] or 0
    return {
        "unit": "utf8-bytes",
        "limitBytes": limit_bytes,
        "usedBytes": used_bytes,
        "remainingBytes": limit_bytes - reserved - used_bytes,
        "mandatoryBytes": mandatory_bytes,
        "optionalBytes": optional_bytes,
        "estimator": ESTIMATOR_IDENTITY,
        "accountingBoundary": "host-invocation",
        "providerVisibleBytes": None,
        "unknownComponents": list(UNKNOWN_PROMPT_COMPONENTS),
        "accounts": {
            "mandatoryTaskPolicyBytes": mandatory_bytes - evidence_bytes,
            "requiredEvidenceBytes": evidence_bytes,
            "optionalSelectedBytes": optional_bytes,
            # Provider-supplied components are outside the host boundary.
            # Missing is unknown, never zero.
            "visibleHistoryBytes": None,
            "toolSkillContentBytes": None,
            "providerSystemBytes": None,
        },
        "outputReserve": reserve,
        "measurement": {
            "hostManagedExactBytes": used_bytes,
            "providerObservableBytes": None,
            "coverage": "host-composed-prompt-only",
            "overlapRule": OVERLAP_RULE,
            "tokenizer": None,
            "estimatorIdentity": ESTIMATOR_IDENTITY,
            "cumulativeUsageNote": (
                "cumulative input and cached-input usage reported by a provider "
                "is neither instantaneous context occupancy nor money"
            ),
        },
    }


def build_envelope(
    *,
    role: str,
    phase: str | None,
    worktree: str,
    revision: str | None,
    policy_sha256: str | None,
    source_versions: list[dict[str, Any]] | None = None,
    task_digest: str | None = None,
    snapshot_id: str | None = None,
    binding: Mapping[str, Any] | None = None,
    strict: bool = False,
) -> dict[str, Any]:
    """Compose one host-bound invocation envelope from what the host knows.

    This is deliberately independent of :class:`ContextService` so the host
    delivery boundary can publish an attributable envelope even for a launch
    that carries no context bundle. An identity the host does not know is
    preserved as ``None`` and named in ``unknownBindings``; it is never dropped
    and never reported as a zero or an empty string. Strict admission refuses
    outright when a required binding is unavailable.
    """
    supplied: dict[str, Any] = {}
    for key, value in dict(binding or {}).items():
        if isinstance(value, str):
            value = value.strip()
        supplied[key] = value or None
    versions = list(source_versions or [])
    record: dict[str, Any] = {
        "version": ENVELOPE_VERSION,
        "taskContractSha256": supplied.get("taskContractSha256") or task_digest,
        "role": role,
        "phase": phase,
        "runId": supplied.get("runId"),
        "attemptId": supplied.get("attemptId"),
        "sessionId": supplied.get("sessionId"),
        "candidateRevision": supplied.get("candidateRevision") or revision,
        "worktree": worktree,
        "requestedModel": supplied.get("requestedModel"),
        "effectiveModel": supplied.get("effectiveModel"),
        "providerName": supplied.get("providerName"),
        "providerExecutable": supplied.get("providerExecutable"),
        "providerBuild": supplied.get("providerBuild"),
        "capabilityProfile": supplied.get("capabilityProfile"),
        "policyVersion": POLICY_VERSION,
        "policySha256": policy_sha256,
        "sourceVersions": versions,
        "sourceVersionsSha256": _sha256(_canonical(versions)),
        "campaignBinding": supplied.get("campaignBinding"),
        "bundleSnapshotId": snapshot_id,
        "unknownBindings": [],
        "strict": bool(strict),
    }
    # Resolve against the final values: a derived default (task digest,
    # candidate revision) is known even when the caller supplied nothing.
    record["unknownBindings"] = sorted(
        name for name in ENVELOPE_IDENTITY_FIELDS if record.get(name) is None
    )
    if strict:
        missing = [
            name for name in ENVELOPE_REQUIRED_BINDINGS if record.get(name) is None
        ]
        if missing:
            raise ContextError(
                "strict-binding: required invocation envelope binding(s) "
                "unavailable: " + ", ".join(missing)
            )
    return record


def envelope_binding_digest(envelope: Mapping[str, Any]) -> str:
    """Digest the authorization/identity fields a retained session is bound to.

    Session reuse compares this digest, not a warning: a change in
    authorization, model, provider, policy or capability identity means the
    retained history cannot be verifiably re-authorized.
    """
    bound = {
        key: envelope.get(key)
        for key in (
            "role", "requestedModel", "effectiveModel", "providerName",
            "providerExecutable", "providerBuild", "capabilityProfile",
            "policyVersion", "policySha256", "sourceVersionsSha256",
            "campaignBinding", "taskContractSha256",
        )
    }
    return _sha256(_canonical(bound))


def _number_optional_selections(provenance: list[dict[str, Any]]) -> None:
    """Stamp the deterministic admission order onto every optional selection."""
    order = 0
    for item in provenance:
        if item.get("priority") != "optional":
            continue
        order += 1
        item["selectionOrder"] = order


class ContextService:
    """One project/worktree/role-bound immutable source snapshot."""

    def __init__(
        self,
        *,
        enabled: bool,
        root: Path,
        config_path: Path,
        project_id: str,
        revision: str,
        role: str,
        phase: str | None,
        allowed_kinds: frozenset[str],
        sources: tuple[Source, ...],
        config_hash: str,
        budget_bytes: int,
        budget_source: str = "contextService.budgetBytes",
        eligibility_inputs: tuple[tuple[Path, str], ...] = (),
        memory_eligibility_inputs: tuple[tuple[Path, str], ...] = (),
        memory_membership_inputs: tuple[tuple[Path, str | None], ...] = (),
    ) -> None:
        self.enabled = enabled
        self.root = root
        self.config_path = config_path
        self.project_id = project_id
        self.revision = revision
        self.role = role
        self.phase = phase
        self.allowed_kinds = allowed_kinds
        self.sources = sources
        self.config_hash = config_hash
        self.budget_bytes = budget_bytes
        self.budget_source = budget_source
        self.eligibility_inputs = eligibility_inputs
        self.memory_eligibility_inputs = memory_eligibility_inputs
        self.memory_membership_inputs = memory_membership_inputs
        self.policy_identity = {
            "version": POLICY_BINDING_VERSION,
            "configPath": str(config_path),
            "configSha256": config_hash,
        }
        source_versions = [
            {"ref": item.ref, "sha256": item.source_hash, "validity": item.validity}
            for item in sources
        ]
        snapshot_material = {
            "projectId": project_id,
            "worktree": str(root),
            "revision": revision,
            "role": role,
            "phase": phase,
            "policyVersion": POLICY_VERSION,
            "configSha256": config_hash,
            "sources": source_versions,
            "eligibilityInputs": [
                {"path": str(path), "sha256": digest}
                for path, digest in eligibility_inputs
            ],
            "memoryMembershipInputs": [
                {"path": str(path), "sha256": digest}
                for path, digest in memory_membership_inputs
            ],
        }
        self.identity = {
            "projectId": project_id,
            "worktree": str(root),
            "revision": revision,
            "role": role,
            "phase": phase,
            "policyVersion": POLICY_VERSION,
            "retrievalVersion": RETRIEVAL_VERSION,
            "snapshotId": _sha256(_canonical(snapshot_material)),
        }

    @classmethod
    def from_config(
        cls,
        config: str | os.PathLike[str],
        *,
        role: str,
        phase: str | None = None,
        workspace: str | os.PathLike[str] | None = None,
        environment: Mapping[str, str] | None = None,
    ) -> "ContextService":
        config_path = Path(os.path.abspath(config)).resolve(strict=False)
        value, config_raw = _read_json(config_path, "context configuration")
        policy_root = config_path.parent.resolve()
        root = (
            Path(os.path.abspath(workspace)).resolve()
            if workspace is not None else policy_root
        )
        if not root.is_dir():
            raise ContextError(f"invocation workspace is missing or not a directory: {root}")
        settings = value.get("contextService")
        if settings is None:
            settings = {}
        if not isinstance(settings, dict):
            raise ContextError("contextService must be an object")
        enabled = settings.get("enabled", False)
        if not isinstance(enabled, bool):
            raise ContextError("contextService.enabled must be boolean")
        project_id = settings.get("projectId", policy_root.name)
        if not isinstance(project_id, str) or not project_id:
            raise ContextError("contextService.projectId must be a non-empty string")
        config_hash = _sha256(config_raw)
        revision = settings.get("revision")
        if revision is None:
            revision = _git_revision(root, config_hash)
        if not isinstance(revision, str) or not revision:
            raise ContextError("contextService.revision must be a non-empty string")
        policy = settings.get("rolePolicy", {})
        if not isinstance(policy, dict):
            raise ContextError("contextService.rolePolicy must be an object")
        if role == "review-target":
            # `review-target` names the trust policy at the invocation boundary;
            # retain compatibility with earlier auditor/reviewer config keys.
            raw_kinds = policy.get(
                role, policy.get("reviewer", policy.get("auditor", policy.get("*", [])))
            )
        else:
            raw_kinds = policy.get(role, policy.get("*", []))
        if not isinstance(raw_kinds, list) or not all(
            isinstance(item, str) and item in {"brain", "code", "run", "memory"}
            for item in raw_kinds
        ):
            raise ContextError(
                f"contextService.rolePolicy.{role} must list brain/code/run/memory"
            )
        allowed = frozenset(raw_kinds)
        # Audits evaluate the review target, never model-authored run history.
        # This is a hard trust boundary in addition to the configured role
        # policy, so a permissive wildcard cannot accidentally import worker
        # conclusions into an auditor.
        if role in {"review-target", "reviewer", "auditor"}:
            allowed = frozenset(kind for kind in allowed if kind != "run")
        budget_bytes = settings.get("budgetBytes", 65536)
        if not isinstance(budget_bytes, int) or isinstance(budget_bytes, bool) or budget_bytes < 1:
            raise ContextError("contextService.budgetBytes must be a positive integer")
        budget_source = "contextService.budgetBytes"
        resolved_environment = environment if environment is not None else os.environ
        budget_override = resolved_environment.get("SINGULAR_CONTEXT_BUDGET_BYTES")
        if budget_override:
            if not budget_override.isdigit() or int(budget_override) < 1:
                raise ContextError(
                    "SINGULAR_CONTEXT_BUDGET_BYTES must be a positive integer"
                )
            budget_bytes = int(budget_override)
            budget_source = "SINGULAR_CONTEXT_BUDGET_BYTES"
        if not enabled:
            return cls(
                enabled=False, root=root, config_path=config_path,
                project_id=project_id, revision=revision, role=role, phase=phase,
                allowed_kinds=allowed, sources=(), config_hash=config_hash,
                budget_bytes=budget_bytes, budget_source=budget_source,
            )

        sources: list[Source] = []
        eligibility_inputs: dict[Path, str] = {}
        memory_eligibility_inputs: dict[Path, str] = {}
        memory_membership_inputs: dict[Path, str | None] = {}
        if "memory" in allowed:
            try:
                memory_snapshot = memory_service.trusted_memory_snapshot(
                    config_path, root, role, configuration=(value, config_raw)
                )
            except memory_service.MemoryError as exc:
                raise ContextError(f"memory source is invalid: {exc}") from exc
            memories = memory_snapshot["memories"]
            for dependency in memory_snapshot["dependencies"]:
                path = Path(dependency["path"]).resolve()
                memory_eligibility_inputs[path] = dependency["sha256"]
                eligibility_inputs[path] = dependency["sha256"]
            for membership in memory_snapshot["memberships"]:
                memory_membership_inputs[Path(membership["path"]).resolve()] = membership["sha256"]
            for item in memories:
                for dependency in item["eligibilityInputs"]:
                    path = Path(dependency["path"]).resolve()
                    expected = dependency["sha256"]
                    prior = memory_eligibility_inputs.get(path)
                    if prior is not None and prior != expected:
                        raise ContextError(
                            f"memory source has conflicting snapshot identity: {path}"
                        )
                    memory_eligibility_inputs[path] = expected
                    eligibility_inputs[path] = expected
                sources.append(Source(
                    ref=item["ref"],
                    kind="memory",
                    path=item["path"],
                    relative_path=item["relativePath"],
                    title=item["title"],
                    description="Policy-approved authored memory",
                    raw=item["raw"],
                    source_hash=item["sha256"],
                    validity="current-reviewed",
                    provenance=item["provenance"],
                ))
        if "brain" in allowed and "contextManifest" in value:
            try:
                normalized, bodies = brain_documents.normalize(config_path)
            except brain_documents.ConsumerError as exc:
                raise ContextError(f"brain source is invalid: {exc}") from exc
            eligibility_inputs[Path(normalized["manifestPath"]).resolve()] = normalized[
                "manifestSha256"
            ]
            for record in normalized["documents"]:
                if not record["selected"]:
                    continue
                artifact = record["artifactId"]
                raw = bodies.get(artifact)
                path = Path(record["resolvedSourcePath"] or record["declaredSourcePath"])
                if record["included"]:
                    validity = "current-reviewed"
                elif "missing_source" in record["exclusionReasons"]:
                    validity = "missing"
                else:
                    validity = "ineligible:" + ",".join(record["exclusionReasons"])
                sources.append(Source(
                    ref="brain:" + artifact,
                    kind="brain",
                    path=path,
                    relative_path=record["artifactPath"],
                    title=record["title"],
                    description=record.get("description") or "",
                    raw=raw,
                    source_hash=_sha256(raw) if raw is not None else None,
                    validity=validity,
                    provenance={
                        "origin": "singular-brain.manifest.v1",
                        "manifestPath": record["provenance"]["manifestPath"],
                        "manifestSha256": record["provenance"]["manifestSha256"],
                        "review": record["review"],
                        "lifecycle": record["lifecycle"],
                    },
                ))

        for kind, key in (("code", "codePaths"), ("run", "runRecordPaths")):
            configured = settings.get(key, [])
            if not isinstance(configured, list):
                raise ContextError(f"contextService.{key} must be an array")
            # Validate containment even for a role that cannot see this kind, so
            # malformed configuration never becomes role-dependent.
            paths: list[tuple[str, Path]] = []
            for index, raw_path in enumerate(configured):
                relative = _relative(raw_path, f"contextService.{key}[{index}]")
                paths.append((relative, _contained(root, relative, f"contextService.{key}[{index}]")))
            if kind not in allowed:
                continue
            for relative, path in paths:
                try:
                    raw = path.read_bytes()
                    validity = "current"
                    source_hash: str | None = _sha256(raw)
                except FileNotFoundError:
                    raw = None
                    validity = "missing"
                    source_hash = None
                except OSError as exc:
                    raise ContextError(f"configured {kind} source is unreadable: {path}: {exc}") from exc
                sources.append(Source(
                    ref=f"{kind}:{relative}", kind=kind, path=path,
                    relative_path=relative, title=PurePosixPath(relative).name,
                    description=f"Configured {kind} source {relative}", raw=raw,
                    source_hash=source_hash, validity=validity,
                    provenance={"origin": "worktree" if kind == "code" else "retained-run-record"},
                ))
        sources.sort(key=lambda item: item.ref)
        return cls(
            enabled=True, root=root, config_path=config_path,
            project_id=project_id, revision=revision, role=role, phase=phase,
            allowed_kinds=allowed, sources=tuple(sources), config_hash=config_hash,
            budget_bytes=budget_bytes, budget_source=budget_source,
            eligibility_inputs=tuple(sorted(
                eligibility_inputs.items(), key=lambda item: str(item[0])
            )),
            memory_eligibility_inputs=tuple(sorted(
                memory_eligibility_inputs.items(), key=lambda item: str(item[0])
            )),
            memory_membership_inputs=tuple(sorted(
                memory_membership_inputs.items(), key=lambda item: str(item[0])
            )),
        )

    def envelope(
        self,
        *,
        phase: str | None,
        task_digest: str,
        snapshot_id: str,
        binding: Mapping[str, Any] | None = None,
        strict: bool = False,
    ) -> dict[str, Any]:
        """Publish one host-bound invocation envelope.

        Everything the host actually knows is bound here: the task-contract
        digest, role/phase, run and attempt/session, the candidate worktree
        revision, requested and effective model, provider executable and build,
        capability profile, policy and source versions, campaign identity and
        the immutable bundle snapshot. An identity the host does not know is
        preserved as ``None`` and named in ``unknownBindings``. Strict admission
        refuses outright when a required binding is unavailable.
        """
        return build_envelope(
            role=self.role,
            phase=phase,
            worktree=str(self.root),
            revision=self.revision,
            policy_sha256=self.config_hash,
            source_versions=[
                {"ref": item.ref, "sha256": item.source_hash,
                 "validity": item.validity}
                for item in self.sources
            ],
            task_digest=task_digest,
            snapshot_id=snapshot_id,
            binding=binding,
            strict=strict,
        )

    def describe(self) -> dict[str, Any]:
        """Effective invocation configuration and source provenance."""
        return {
            "enabled": self.enabled,
            "projectId": self.project_id,
            "role": self.role,
            "phase": self.phase,
            "budgetBytes": self.budget_bytes,
            "budgetSource": self.budget_source,
            "allowedKinds": sorted(self.allowed_kinds),
            "identity": self.identity,
            "policy": self.policy_identity,
            "sources": [
                {
                    "ref": source.ref,
                    "kind": source.kind,
                    "sourceLocation": str(source.path),
                    "sourceSha256": source.source_hash,
                    "validity": source.validity,
                    "provenance": source.provenance,
                }
                for source in self.sources
            ],
        }

    def validate_snapshot(self) -> None:
        """Refuse config/source drift after this invocation snapshot was read."""
        try:
            current_config = self.config_path.read_bytes()
        except OSError as exc:
            raise ContextError(
                f"context configuration changed during invocation: {self.config_path}: {exc}"
            ) from exc
        if _sha256(current_config) != self.config_hash:
            raise ContextError(
                f"context configuration changed during invocation: {self.config_path}"
            )
        for path, expected_hash in self.eligibility_inputs:
            try:
                current = path.read_bytes()
            except OSError as exc:
                raise ContextError(
                    f"context eligibility metadata changed during invocation: {path}: {exc}"
                ) from exc
            if _sha256(current) != expected_hash:
                raise ContextError(
                    f"context eligibility metadata changed during invocation: {path}"
                )
        for source in self.sources:
            try:
                current = source.path.read_bytes()
            except FileNotFoundError:
                current = None
            except OSError as exc:
                raise ContextError(
                    f"configured source changed during invocation: {source.ref}: {exc}"
                ) from exc
            if current != source.raw:
                raise ContextError(
                    f"configured source changed during invocation: {source.ref}"
                )
        for path, expected_hash in self.memory_membership_inputs:
            if memory_service._directory_identity(path) != expected_hash:
                raise ContextError(
                    f"memory transaction membership changed during invocation: {path}"
                )

    def validate_memory_snapshot(self) -> None:
        """Refuse retirement or dependency drift of snapshotted memory."""
        if not self.memory_eligibility_inputs and not self.memory_membership_inputs:
            return
        try:
            current_config = self.config_path.read_bytes()
        except OSError as exc:
            raise ContextError(
                f"context configuration changed during invocation: {self.config_path}: {exc}"
            ) from exc
        if _sha256(current_config) != self.config_hash:
            raise ContextError(
                f"context configuration changed during invocation: {self.config_path}"
            )
        for path, expected_hash in self.memory_eligibility_inputs:
            try:
                current = path.read_bytes()
            except OSError as exc:
                raise ContextError(
                    f"context eligibility metadata changed during invocation: {path}: {exc}"
                ) from exc
            if _sha256(current) != expected_hash:
                raise ContextError(
                    f"context eligibility metadata changed during invocation: {path}"
                )
        for path, expected_hash in self.memory_membership_inputs:
            try:
                current_hash = memory_service._directory_identity(path)
            except OSError as exc:
                raise ContextError(
                    f"memory transaction membership changed during invocation: {path}: {exc}"
                ) from exc
            if current_hash != expected_hash:
                raise ContextError(
                    f"memory transaction membership changed during invocation: {path}"
                )

    def _disabled(self, schema: str) -> dict[str, Any]:
        return {
            "schema": schema,
            "status": "disabled",
            "identity": self.identity,
            "reason": "contextService.enabled is false or absent",
        }

    def _source(self, ref: str) -> Source:
        for source in self.sources:
            if source.ref == ref:
                return source
        raise ContextError(f"unknown or unauthorized source reference: {ref}")

    @staticmethod
    def _match(source: Source, query: str) -> tuple[int, list[str], int]:
        folded = query.casefold().strip()
        haystack = "\n".join((source.title, source.description, source.text)).casefold()
        reasons: list[str] = []
        score = 0
        location = -1
        if folded == source.ref.casefold():
            score += 1000
            reasons.append("exact_reference")
            location = 0
        if folded and folded in haystack:
            score += 100
            reasons.append("exact_phrase")
            location = haystack.find(folded)
        tokens = list(dict.fromkeys(token.casefold() for token in TOKEN_RE.findall(query)))
        matched = [token for token in tokens if token in haystack]
        if matched:
            score += 10 * len(matched)
            reasons.append("lexical_tokens:" + ",".join(matched))
            if location < 0:
                location = min(haystack.find(token) for token in matched)
        # A lone generic word from a longer query is too weak to disclose a
        # source. Two-word paraphrases can still retrieve on one shared anchor,
        # while lower lexical coverage abstains explicitly.
        if "exact_phrase" not in reasons and tokens and len(matched) * 2 < len(tokens):
            return 0, [], 0
        return score, reasons, max(0, location)

    @staticmethod
    def _excerpt(source: Source, query: str, cap: int) -> tuple[bytes, int, int, bool]:
        raw = source.raw or b""
        text = source.text
        folded = text.casefold()
        positions = [folded.find(token.casefold()) for token in TOKEN_RE.findall(query)]
        positions = [position for position in positions if position >= 0]
        char_position = min(positions) if positions else 0
        byte_position = len(text[:char_position].encode("utf-8"))
        start = max(0, byte_position - min(160, cap // 3))
        while start < len(raw) and (raw[start] & 0xC0) == 0x80:
            start += 1
        excerpt, truncated = _utf8_prefix(raw[start:], max(0, cap))
        return excerpt, start, start + len(excerpt), truncated or start > 0

    def search(
        self, query: str, *, limit: int = 5, max_bytes: int = 4000
    ) -> dict[str, Any]:
        if not self.enabled:
            result = self._disabled(SEARCH_SCHEMA)
            result.update({"query": query, "results": [], "abstained": True, "limitations": LEXICAL_LIMIT})
            return result
        if not isinstance(query, str) or not query.strip():
            raise ContextError("search query must be non-empty")
        if limit < 0 or max_bytes < 0:
            raise ContextError("search limit and max-bytes must be non-negative")
        self.validate_memory_snapshot()
        ranked: list[tuple[int, str, list[str], Source]] = []
        for source in self.sources:
            if source.raw is None or source.validity not in {"current", "current-reviewed"}:
                continue
            score, reasons, _ = self._match(source, query)
            if score:
                ranked.append((score, source.ref, reasons, source))
        ranked.sort(key=lambda item: (-item[0], item[1]))
        remaining = max_bytes
        results: list[dict[str, Any]] = []
        omissions: list[dict[str, str]] = []
        for score, _, reasons, source in ranked[:limit]:
            if remaining <= 0:
                omissions.append({"ref": source.ref, "reason": "aggregate_byte_budget"})
                continue
            excerpt, start, end, truncated = self._excerpt(source, query, remaining)
            if not excerpt:
                omissions.append({"ref": source.ref, "reason": "aggregate_byte_budget"})
                continue
            remaining -= len(excerpt)
            results.append({
                "ref": source.ref,
                "kind": source.kind,
                "title": source.title,
                "score": score,
                "reasons": reasons,
                "validity": source.validity,
                "sourceLocation": str(source.path),
                "sourceSha256": source.source_hash,
                "excerpt": excerpt.decode("utf-8"),
                "excerptSha256": _sha256(excerpt),
                "range": {"startByte": start, "endByte": end},
                "truncated": truncated,
                "provenance": source.provenance,
            })
        result = {
            "schema": SEARCH_SCHEMA,
            "status": "ok",
            "identity": self.identity,
            "query": query,
            "retrievalVersion": RETRIEVAL_VERSION,
            "limitations": LEXICAL_LIMIT,
            "results": results,
            "abstained": not results,
            "omissions": omissions,
            "budget": {
                "unit": "utf8-bytes", "limitBytes": max_bytes,
                "usedBytes": max_bytes - remaining, "remainingBytes": remaining,
            },
        }
        self.validate_memory_snapshot()
        return result

    def get(
        self,
        ref: str,
        *,
        version: str,
        section: str | None = None,
        start_line: int = 1,
        line_count: int | None = None,
        max_bytes: int = 4000,
        cursor: str | None = None,
    ) -> dict[str, Any]:
        if not self.enabled:
            result = self._disabled(GET_SCHEMA)
            result.update({"ref": ref, "text": ""})
            return result
        if start_line < 1 or (line_count is not None and line_count < 1) or max_bytes < 0:
            raise ContextError("pagination values are outside their valid range")
        source = self._source(ref)
        if source.kind == "memory":
            self.validate_memory_snapshot()
        if source.raw is None or source.validity == "missing":
            raise ContextError(f"missing source: {ref}: {source.path}")
        if source.validity not in {"current", "current-reviewed"}:
            raise ContextError(f"ineligible source reference under B1 policy: {ref}")
        if not HASH_RE.match(version):
            raise ContextError("wrong-version: version must be sha256:<64 lowercase hex>")
        if version != source.source_hash:
            raise ContextError(
                f"wrong-version: {ref} snapshot is {source.source_hash}, requested {version}"
            )
        try:
            live = source.path.read_bytes()
        except FileNotFoundError as exc:
            raise ContextError(f"missing source: {ref}: {source.path}") from exc
        except OSError as exc:
            raise ContextError(f"unreadable source: {ref}: {exc}") from exc
        live_hash = _sha256(live)
        if live_hash != source.source_hash:
            raise ContextError(
                f"modified source: {ref}: expected {source.source_hash}, found {live_hash}"
            )
        try:
            text = live.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ContextError(f"source is not UTF-8 text: {ref}") from exc
        base_char = 0
        end_char = len(text)
        resolved_section: str | None = None
        if section:
            matches = list(HEADING_RE.finditer(text))
            match_index = next(
                (index for index, match in enumerate(matches)
                 if match.group(2).strip().casefold() == section.strip().casefold()),
                None,
            )
            if match_index is None:
                raise ContextError(f"section not found in {ref}: {section}")
            match = matches[match_index]
            level = len(match.group(1))
            for later in matches[match_index + 1:]:
                if len(later.group(1)) <= level:
                    end_char = later.start()
                    break
            base_char = match.start()
            resolved_section = match.group(2).strip()
        section_start = len(text[:base_char].encode("utf-8"))
        section_end = len(text[:end_char].encode("utf-8"))
        selected = live[section_start:section_end]

        if cursor and cursor.startswith("line:"):
            if not re.fullmatch(r"line:[1-9][0-9]*", cursor):
                raise ContextError("cursor must be line:<positive-integer> or byte:<non-negative-integer>")
            start_line = int(cursor.split(":", 1)[1])
            cursor = None
        if cursor:
            if not re.fullmatch(r"byte:[0-9]+", cursor):
                raise ContextError("cursor must be line:<positive-integer> or byte:<non-negative-integer>")
            start_byte = int(cursor.split(":", 1)[1])
            if start_byte < section_start or start_byte > section_end:
                raise ContextError("byte cursor is outside the selected source section")
            try:
                live[:start_byte].decode("utf-8")
            except UnicodeDecodeError as exc:
                raise ContextError("byte cursor does not identify a UTF-8 boundary") from exc
            relative_start = start_byte - section_start
        else:
            line_bytes = [line.encode("utf-8") for line in text[base_char:end_char].splitlines(keepends=True)]
            line_offset = min(start_line - 1, len(line_bytes))
            relative_start = sum(len(line) for line in line_bytes[:line_offset])
            start_byte = section_start + relative_start

        target_end = section_end
        if line_count is not None:
            position = relative_start
            for _ in range(line_count):
                newline = selected.find(b"\n", position)
                if newline < 0:
                    position = len(selected)
                    break
                position = newline + 1
            target_end = section_start + position
        requested = live[start_byte:target_end]
        page, truncated_bytes = _utf8_prefix(requested, max_bytes)
        if requested and not page:
            raise ContextError("max-bytes is too small for the next UTF-8 code point")
        end_byte = start_byte + len(page)
        has_more = truncated_bytes or target_end < section_end
        line_at_start = selected[:relative_start].count(b"\n") + 1
        next_line = line_at_start + page.count(b"\n")
        result = {
            "schema": GET_SCHEMA,
            "status": "ok",
            "identity": self.identity,
            "ref": ref,
            "kind": source.kind,
            "title": source.title,
            "validity": source.validity,
            "sourceLocation": str(source.path),
            "sourceSha256": source.source_hash,
            "section": resolved_section,
            "text": page.decode("utf-8"),
            "excerptSha256": _sha256(page),
            "range": {
                "startByte": start_byte,
                "endByte": end_byte,
                "startLine": line_at_start,
                "nextLine": next_line if has_more else None,
            },
            "continuationCursor": f"byte:{end_byte}" if has_more else None,
            "truncated": has_more,
            "reasons": ["exact_reference", "immutable_version_verified"] + (["heading_section"] if section else ["line_page"]),
            "provenance": source.provenance,
            "budget": {"unit": "utf8-bytes", "limitBytes": max_bytes, "usedBytes": len(page)},
        }
        if source.kind == "memory":
            self.validate_memory_snapshot()
        return result

    @staticmethod
    def _obligations(source: Source) -> list[tuple[int, int, bytes]]:
        if source.kind != "run" or source.raw is None:
            return []
        result: list[tuple[int, int, bytes]] = []
        offset = 0
        for line in source.raw.splitlines(keepends=True):
            end = offset + len(line)
            if OBLIGATION_RE.search(line.decode("utf-8", "replace")):
                result.append((offset, end, line))
            offset = end
        return result

    def build(
        self,
        *,
        task: str | os.PathLike[str],
        phase: str,
        budget_bytes: int,
        query: str | None = None,
        base_prompt: str | os.PathLike[str] | None = None,
        delivery: str = "full",
        prior_bundle: dict[str, Any] | str | os.PathLike[str] | None = None,
        required_evidence: list[dict[str, Any]] | None = None,
        final_budget_bytes: int | None = None,
        invocation_id: str | None = None,
        campaign_binding: str | None = None,
        envelope: Mapping[str, Any] | None = None,
        envelope_strict: bool = False,
        output_reserve: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        invocation = {
            "invocationId": invocation_id,
            "campaignBinding": campaign_binding,
            "workspace": str(self.root),
        }
        if not self.enabled:
            prompt = b""
            disabled_identity = dict(self.identity)
            disabled_identity["phase"] = phase
            result: dict[str, Any] = {
                "schema": BUNDLE_SCHEMA,
                "contractVersion": 1,
                "status": "disabled",
                "reason": "contextService.enabled is false or absent",
                "identity": disabled_identity,
                "policy": self.policy_identity,
                "invocation": invocation,
                "prompt": "",
                "promptSha256": _sha256(prompt),
                "provenance": [],
                "omissions": [],
                "budget": _budget_record(
                    limit_bytes=budget_bytes, used_bytes=0, mandatory_bytes=0,
                    optional_bytes=0, evidence_bytes=0,
                    reserve=_output_reserve_record(output_reserve),
                ),
                "limitations": LEXICAL_LIMIT,
            }
            result["bundleId"] = _sha256(_canonical(result))
            return result
        if budget_bytes < 0:
            raise ContextError("budget-bytes must be non-negative")
        if base_prompt is not None:
            return self._build_invocation(
                task=task,
                phase=phase,
                budget_bytes=budget_bytes,
                query=query,
                base_prompt=base_prompt,
                delivery="initial" if delivery == "full" else delivery,
                prior_bundle=prior_bundle,
                required_evidence=required_evidence or [],
                final_budget_bytes=final_budget_bytes,
                invocation_id=invocation_id,
                campaign_binding=campaign_binding,
                envelope=envelope,
                envelope_strict=envelope_strict,
                output_reserve=output_reserve,
            )
        task_raw_value = os.fspath(task)
        if re.fullmatch(r"TASK-[0-9]{4,}", task_raw_value):
            candidates = [
                self.root / "docs" / "orchestration" / directory / f"{task_raw_value}.md"
                for directory in ("tasks", "rescue-tasks", "brain-tasks")
            ]
            task_path = next((candidate for candidate in candidates if candidate.is_file()), candidates[0])
        else:
            task_path = Path(task_raw_value)
        if not task_path.is_absolute():
            task_path = self.root / task_path
        task_path = task_path.resolve(strict=False)
        try:
            task_path.relative_to(self.root)
        except ValueError as exc:
            raise ContextError(f"containment: task resolves outside worktree: {task_path}") from exc
        try:
            task_raw = task_path.read_bytes()
        except FileNotFoundError as exc:
            raise ContextError(f"mandatory task source is missing: {task_path}") from exc
        try:
            task_raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ContextError(f"mandatory task source is not UTF-8: {task_path}") from exc

        task_ref = "task:" + task_path.relative_to(self.root).as_posix()
        mandatory_parts: list[tuple[str, bytes, Source | None, list[str], int, int, bytes]] = [(
            task_ref,
            (f"=== required-task:{task_ref} ===\n").encode() + task_raw + (b"" if task_raw.endswith(b"\n") else b"\n"),
            None,
            ["mandatory_task_contract", "constraints_and_acceptance"],
            0,
            len(task_raw),
            task_raw,
        )]
        for source in self.sources:
            for index, (start, end, line) in enumerate(self._obligations(source), 1):
                mandatory_parts.append((
                    f"{source.ref}#obligation-{index}",
                    (f"=== open-or-violated-obligation:{source.ref} ===\n").encode() + line,
                    source,
                    ["mandatory_open_or_violated_obligation"],
                    start,
                    end,
                    line,
                ))
        reserve = _output_reserve_record(output_reserve)
        reserved_bytes = reserve["reservedBytes"] or 0
        allowance = budget_bytes - reserved_bytes
        mandatory_bytes = sum(len(part) for _, part, _, _, _, _, _ in mandatory_parts)
        if mandatory_bytes > allowance:
            label = (
                "mandatory-reserve-overflow" if reserved_bytes
                and mandatory_bytes <= budget_bytes else "mandatory-overflow"
            )
            raise ContextOverflow(
                f"{label}: task constraints and open/violated obligations "
                f"require {mandatory_bytes} UTF-8 bytes with a declared "
                f"{reserved_bytes}-byte output reserve but budget is {budget_bytes}"
            )

        prompt_parts = [part for _, part, _, _, _, _, _ in mandatory_parts]
        provenance: list[dict[str, Any]] = []
        for ref, _, source, reasons, source_start, source_end, excerpt in mandatory_parts:
            is_task = source is None
            provenance.append({
                "ref": ref,
                "kind": "task" if is_task else source.kind,
                "sourceLocation": str(task_path if is_task else source.path),
                "sourceSha256": _sha256(task_raw) if is_task else source.source_hash,
                "excerptSha256": _sha256(excerpt),
                "range": {"startByte": source_start, "endByte": source_end},
                "reasons": reasons,
                "validity": "snapshot-read" if is_task else source.validity,
                "priority": "mandatory",
            })

        used = mandatory_bytes
        optional_used = 0
        omissions: list[dict[str, str]] = []
        query_text = query or task_raw.decode("utf-8")
        ranked: list[tuple[int, str, list[str], Source]] = []
        mandatory_source_refs = {item.ref for item in self.sources if self._obligations(item)}
        for source in self.sources:
            if source.raw is None or source.validity not in {"current", "current-reviewed"}:
                omissions.append({"ref": source.ref, "reason": source.validity})
                continue
            if source.ref in mandatory_source_refs:
                continue
            score, reasons, _ = self._match(source, query_text)
            if score:
                ranked.append((score, source.ref, reasons, source))
            else:
                omissions.append({"ref": source.ref, "reason": "no_lexical_match"})
        ranked.sort(key=lambda item: (-item[0], item[1]))
        for _, _, reasons, source in ranked:
            available = allowance - used
            header = f"=== retrieved:{source.ref} ===\n".encode()
            if available <= len(header):
                omissions.append({"ref": source.ref, "reason": "aggregate_byte_budget",
                                  "priority": "optional"})
                continue
            excerpt, start, end, truncated = self._excerpt(source, query_text, available - len(header))
            if not excerpt:
                omissions.append({"ref": source.ref, "reason": "aggregate_byte_budget",
                                  "priority": "optional"})
                continue
            block = header + excerpt + (b"" if excerpt.endswith(b"\n") else b"\n")
            if len(block) > available:  # newline can consume the final byte
                block = header + excerpt
            prompt_parts.append(block)
            used += len(block)
            optional_used += len(block)
            provenance.append({
                "ref": source.ref, "kind": source.kind,
                "sourceLocation": str(source.path), "sourceSha256": source.source_hash,
                "excerptSha256": _sha256(excerpt),
                "range": {"startByte": start, "endByte": end},
                "reasons": reasons, "validity": source.validity,
                "priority": "optional", "truncated": truncated,
                "provenance": source.provenance,
            })
        prompt_bytes = b"".join(prompt_parts)
        prompt = prompt_bytes.decode("utf-8")
        try:
            if task_path.read_bytes() != task_raw:
                raise ContextError(f"mandatory task source changed during invocation: {task_path}")
        except OSError as exc:
            raise ContextError(f"mandatory task source changed during invocation: {exc}") from exc
        self.validate_snapshot()
        bundle_identity = dict(self.identity)
        if phase != self.phase:
            bundle_identity["phase"] = phase
            bundle_identity["snapshotId"] = _sha256(_canonical({
                "sourceSnapshotId": self.identity["snapshotId"], "phase": phase,
            }))
        _number_optional_selections(provenance)
        bundle: dict[str, Any] = {
            "schema": BUNDLE_SCHEMA,
            "contractVersion": 1,
            "status": "ok",
            "identity": bundle_identity,
            "policy": self.policy_identity,
            "invocation": invocation,
            "envelope": self.envelope(
                phase=phase, task_digest=_sha256(task_raw),
                snapshot_id=bundle_identity["snapshotId"],
                binding=envelope, strict=envelope_strict,
            ),
            "prompt": prompt,
            "promptSha256": _sha256(prompt_bytes),
            "provenance": provenance,
            "omissions": sorted(omissions, key=lambda item: (item["ref"], item["reason"])),
            "budget": _budget_record(
                limit_bytes=budget_bytes, used_bytes=len(prompt_bytes),
                mandatory_bytes=mandatory_bytes, optional_bytes=optional_used,
                evidence_bytes=0, reserve=reserve,
            ),
            "limitations": LEXICAL_LIMIT,
        }
        bundle["bundleId"] = _sha256(_canonical(bundle))
        return bundle

    def _build_invocation(
        self,
        *,
        task: str | os.PathLike[str],
        phase: str,
        budget_bytes: int,
        query: str | None,
        base_prompt: str | os.PathLike[str],
        delivery: str,
        prior_bundle: dict[str, Any] | str | os.PathLike[str] | None,
        required_evidence: list[dict[str, Any]],
        final_budget_bytes: int | None,
        invocation_id: str | None,
        campaign_binding: str | None,
        envelope: Mapping[str, Any] | None = None,
        envelope_strict: bool = False,
        output_reserve: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Build the exact provider prompt from one immutable source snapshot.

        The existing driver prompt remains authoritative. Initial delivery adds
        selected source bodies once; delta delivery adds changed bodies,
        mandatory obligation lines, and immutable references for unchanged
        sources. The resulting prompt and its event provenance therefore come
        from the same signed bundle.
        """
        if delivery not in {"initial", "delta"}:
            raise ContextError("delivery must be initial or delta")
        if final_budget_bytes is not None and (
            not isinstance(final_budget_bytes, int)
            or isinstance(final_budget_bytes, bool)
            or final_budget_bytes < 1
        ):
            raise ContextError("final composed budget must be a positive integer")
        base_path = Path(base_prompt).resolve(strict=False)
        try:
            base_raw = base_path.read_bytes()
        except FileNotFoundError as exc:
            raise ContextError(f"mandatory base prompt is missing: {base_path}") from exc
        try:
            base_text = base_raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ContextError(f"mandatory base prompt is not UTF-8: {base_path}") from exc

        task_path = Path(os.fspath(task))
        if not task_path.is_absolute():
            task_path = self.root / task_path
        task_path = task_path.resolve(strict=False)
        try:
            task_path.relative_to(self.root)
        except ValueError as exc:
            raise ContextError(
                f"containment: task resolves outside worktree: {task_path}"
            ) from exc
        try:
            task_raw = task_path.read_bytes()
            task_text = task_raw.decode("utf-8")
        except FileNotFoundError as exc:
            raise ContextError(f"mandatory task source is missing: {task_path}") from exc
        except UnicodeDecodeError as exc:
            raise ContextError(f"mandatory task source is not UTF-8: {task_path}") from exc

        missing = [source for source in self.sources if source.raw is None or source.validity == "missing"]
        if missing:
            refs = ", ".join(source.ref for source in missing)
            raise ContextError(f"missing source: configured invocation source(s): {refs}")
        invalid = [
            source for source in self.sources
            if source.validity not in {"current", "current-reviewed"}
        ]
        if invalid:
            refs = ", ".join(f"{source.ref} ({source.validity})" for source in invalid)
            raise ContextError(f"ineligible configured invocation source(s): {refs}")

        prior: dict[str, Any] = {}
        prior_path: Path | None = None
        if prior_bundle is not None:
            if isinstance(prior_bundle, dict):
                prior = prior_bundle
            else:
                prior_path = Path(prior_bundle).resolve(strict=False)
                prior, _ = _read_json(prior_path, "prior context bundle")
            if prior.get("schema") != BUNDLE_SCHEMA:
                raise ContextError("wrong-version: prior bundle must be singular.context.bundle.v1")
            claimed = prior.get("bundleId")
            unsigned = dict(prior)
            unsigned.pop("bundleId", None)
            if claimed != _sha256(_canonical(unsigned)):
                raise ContextError("modified prior context bundle")
            prior_identity = prior.get("identity")
            if not isinstance(prior_identity, dict):
                raise ContextError("prior context bundle has no compatible identity")
            compatibility = {
                "projectId": self.project_id,
                "worktree": str(self.root),
                "role": self.role,
            }
            mismatched = [
                key for key, expected in compatibility.items()
                if prior_identity.get(key) != expected
            ]
            prior_host_binding = prior.get("invocation", {})
            if (
                campaign_binding is not None
                and prior_host_binding.get("campaignBinding") != campaign_binding
            ):
                mismatched.append("campaignBinding")
            if mismatched:
                # An incompatible bundle is not authority and contributes no
                # references. A fresh bounded initial delivery is safe and is
                # required for provider fallbacks that cannot reuse memory.
                prior = {}
                prior_path = None
                delivery = "initial"
        elif delivery == "delta":
            delivery = "initial"

        previous = {
            item.get("ref"): item.get("sourceSha256")
            for item in prior.get("provenance", [])
            if isinstance(item, dict) and item.get("kind") in {"brain", "code", "run", "memory"}
        }
        current_refs = {source.ref for source in self.sources}
        revoked = sorted(ref for ref in previous if ref not in current_refs)
        changed = sorted(
            source.ref for source in self.sources
            if previous.get(source.ref) != source.source_hash
        )
        # Admission identity first. A strict refusal must happen before any
        # composition, publication or provider launch, not after it.
        invocation_envelope = self.envelope(
            phase=phase, task_digest=_sha256(task_raw),
            snapshot_id=self.identity["snapshotId"],
            binding=envelope, strict=envelope_strict,
        )
        reserve = _output_reserve_record(
            output_reserve, invocation_envelope.get("providerName")
        )
        reserved_bytes = reserve["reservedBytes"] or 0
        allowance = budget_bytes - reserved_bytes

        # Compose in ordered segments. Each segment records the bytes it would
        # contribute and how many of those are mandatory, so optional material
        # can be trimmed deterministically without ever dropping a mandatory
        # task obligation, required review artifact, or revocation notice.
        segments: list[dict[str, Any]] = []

        def segment(data: bytes, *, mandatory: int, provenance: list[dict[str, Any]],
                    ref: str | None = None, trim: dict[str, Any] | None = None,
                    evidence: int = 0) -> None:
            segments.append({
                "data": data, "mandatory": mandatory,
                "optional": len(data) - mandatory, "provenance": provenance,
                "ref": ref, "trim": trim, "evidence": evidence,
            })

        segment(base_raw, mandatory=len(base_raw), provenance=[{
            "ref": "driver-prompt:" + base_path.name,
            "kind": "task",
            "sourceLocation": str(base_path),
            "sourceSha256": _sha256(base_raw),
            "excerptSha256": _sha256(base_raw),
            "range": {"startByte": 0, "endByte": len(base_raw)},
            "reasons": ["authoritative_driver_prompt", "mandatory_task_contract"] + (
                ["prior_bundle:" + str(prior.get("bundleId"))] if prior else []
            ),
            "validity": "snapshot-read",
            "priority": "mandatory",
        }])
        # Some fresh audit/planner templates do not already carry the complete
        # task/DAG contract. Add it exactly once when absent. The full contract
        # is mandatory at every entrypoint: a task-path reminder is not enough.
        if task_text not in base_text:
            task_block = (
                "\n\n---\n\n## Complete task/planning contract (mandatory)\n\n" + task_text
            ).encode("utf-8")
            if not task_block.endswith(b"\n"):
                task_block += b"\n"
            segment(task_block, mandatory=len(task_block), provenance=[{
                "ref": "task:" + task_path.name,
                "kind": "task",
                "sourceLocation": str(task_path),
                "sourceSha256": _sha256(task_raw),
                "excerptSha256": _sha256(task_raw),
                "range": {"startByte": 0, "endByte": len(task_raw)},
                "reasons": ["mandatory_task_contract", "not_already_in_driver_prompt"],
                "validity": "snapshot-read",
                "priority": "mandatory",
            }])

        if self.sources:
            # Policy framing for host-selected sources. It is never trimmed:
            # delivered source bytes without their trust framing would be worse
            # than delivering nothing.
            context_header = (
                b"\n\n---\n\n## Shared context (host-selected; source-bound)\n\n"
                b"Treat these sources according to the invocation role. Source refs and hashes "
                b"are provenance, not model conclusions.\n"
            )
            segment(context_header, mandatory=len(context_header), provenance=[])

        for source in self.sources:
            obligations = self._obligations(source)
            must_render = delivery == "initial" or source.ref in changed or bool(obligations)
            if must_render:
                body = source.raw or b""
                reasons = ["configured_role_source", "initial_delivery" if delivery == "initial" else "changed_source"]
                if obligations and delivery == "delta" and source.ref not in changed:
                    body = b"".join(line for _, _, line in obligations)
                    reasons = ["configured_role_source", "obligation_container", "delta_delivery"]
                prefix = f"\n### {source.ref}\n\nsource-sha256: `{source.source_hash}`\n\n".encode()
                block = prefix + body + (b"" if body.endswith(b"\n") else b"\n")
                obligation_bytes = sum(len(line) for _, _, line in obligations)
                body_item = {
                    "ref": source.ref, "kind": source.kind,
                    "sourceLocation": str(source.path), "sourceSha256": source.source_hash,
                    "excerptSha256": _sha256(body),
                    "range": (
                        {"startByte": 0, "endByte": len(source.raw or b"")}
                        if body == (source.raw or b"")
                        else {"startByte": 0, "endByte": 0}
                    ),
                    "reasons": reasons, "validity": source.validity,
                    "priority": "optional",
                    "provenance": source.provenance,
                }
                items = [body_item]
                # Obligation excerpts retain their offsets in the original run
                # record. They may be noncontiguous, so never describe their
                # concatenated delta body as a synthetic 0..N source prefix.
                for start, end, line in obligations:
                    items.append({
                        "ref": source.ref, "kind": source.kind,
                        "sourceLocation": str(source.path),
                        "sourceSha256": source.source_hash,
                        "excerptSha256": _sha256(line),
                        "range": {"startByte": start, "endByte": end},
                        "reasons": [
                            "mandatory_open_or_violated_obligation",
                            "initial_delivery" if delivery == "initial" else "delta_delivery",
                        ],
                        "validity": source.validity,
                        "priority": "mandatory",
                        "provenance": source.provenance,
                    })
                # A source that carries mandatory obligations keeps its framing
                # prefix mandatory too, so the obligation-only rendering below is
                # always affordable once the mandatory account has been admitted.
                head_mandatory = len(prefix) if obligations else 0
                segment(
                    block, mandatory=head_mandatory + obligation_bytes,
                    provenance=items, ref=source.ref,
                    trim={
                        "kind": "source-body", "prefix": prefix, "body": body,
                        "source": source, "item": body_item,
                        "obligations": obligations, "reasons": reasons,
                        "prefixOptional": 0 if obligations else len(prefix),
                    },
                )
            else:
                ref_line = f"\n- {source.ref} unchanged at `{source.source_hash}`; use this immutable reference.\n".encode()
                segment(ref_line, mandatory=0, ref=source.ref, provenance=[{
                    "ref": source.ref, "kind": source.kind,
                    "sourceLocation": str(source.path), "sourceSha256": source.source_hash,
                    "excerptSha256": _sha256(ref_line),
                    "range": {"startByte": 0, "endByte": 0},
                    "reasons": ["unchanged_immutable_reference", "delta_delivery"],
                    "validity": source.validity, "priority": "optional",
                    "provenance": source.provenance,
                }], trim={"kind": "droppable"})

        if revoked:
            revoked_notice = ("\nRevoked since the prior bundle: " + ", ".join(revoked) +
                              ". Do not rely on prior bytes.\n").encode()
            segment(revoked_notice, mandatory=len(revoked_notice), provenance=[])

        if prior and prior_path is not None:
            prior_notice = (
                "\nRetained prior context bundle: `" + str(prior_path) + "` "
                "(" + str(prior.get("bundleId")) + "). Unchanged-source references "
                "resolve through this immutable host artifact.\n"
            ).encode()
            segment(prior_notice, mandatory=0, ref="prior-bundle",
                    provenance=[], trim={"kind": "droppable"})

        if required_evidence:
            evidence_header = b"\n\n## Complete host-delivered review evidence\n"
            segment(evidence_header, mandatory=len(evidence_header), provenance=[],
                    evidence=len(evidence_header))
            for item in required_evidence:
                ref = item.get("ref")
                data = item.get("data")
                source_location = item.get("sourceLocation", "")
                if not isinstance(ref, str) or not ref or not isinstance(data, bytes):
                    raise ContextError("required evidence snapshot is invalid")
                digest = _sha256(data)
                block = (
                    ("\nArtifact: " + ref + " SHA256: " + digest.removeprefix("sha256:") + "\n").encode()
                    + data + b"\n"
                )
                segment(block, mandatory=len(block), evidence=len(block), provenance=[{
                    "ref": "evidence:" + ref,
                    # Required review evidence is part of the invocation's
                    # task contract. Keep the strict v1 kind vocabulary while
                    # identifying its host origin in nested provenance.
                    "kind": "task",
                    "sourceLocation": str(source_location),
                    "sourceSha256": digest,
                    "excerptSha256": digest,
                    "range": {"startByte": 0, "endByte": len(data)},
                    "reasons": ["required_host_evidence", "mandatory_review_input"],
                    "validity": "snapshot-read",
                    "priority": "mandatory",
                    "provenance": {"origin": "host-evidence", "evidenceRef": ref},
                }])

        mandatory_bytes = sum(item["mandatory"] for item in segments)
        evidence_bytes = sum(item["evidence"] for item in segments)
        if mandatory_bytes > allowance:
            label = (
                "mandatory-reserve-overflow"
                if reserved_bytes and mandatory_bytes <= budget_bytes
                else "mandatory-overflow"
            )
            raise ContextOverflow(
                f"{label}: mandatory task contract, open/violated obligations and "
                f"required review evidence need {mandatory_bytes} UTF-8 bytes with a "
                f"declared {reserved_bytes}-byte output reserve, but the composed "
                f"budget is {budget_bytes}"
            )

        # Optional material is admitted in this exact declared order into the
        # remaining allowance. Overflow here is optional overflow: it never
        # becomes a mandatory-overflow refusal and never drops mandatory bytes.
        remaining = allowance - mandatory_bytes
        parts: list[bytes] = []
        provenance: list[dict[str, Any]] = []
        omissions: list[dict[str, str]] = [
            {"ref": ref, "reason": "revoked_since_prior_bundle"} for ref in revoked
        ]
        for item in segments:
            optional_cost = item["optional"]
            if optional_cost == 0 or optional_cost <= remaining:
                remaining -= optional_cost
                parts.append(item["data"])
                provenance.extend(item["provenance"])
                continue
            trim = item["trim"]
            if trim is None or trim["kind"] == "droppable":
                omissions.append({
                    "ref": item["ref"] or "context", "reason": "aggregate_byte_budget",
                    "priority": "optional",
                })
                continue
            prefix, body = trim["prefix"], trim["body"]
            source, body_item = trim["source"], trim["item"]
            obligations = trim["obligations"]
            if obligations:
                # Degrade deterministically to the mandatory obligation lines.
                kept = b"".join(line for _, _, line in obligations)
                block = prefix + kept + (b"" if kept.endswith(b"\n") else b"\n")
                body_item["excerptSha256"] = _sha256(kept)
                body_item["range"] = {"startByte": 0, "endByte": 0}
                body_item["reasons"] = list(trim["reasons"]) + ["optional_body_trimmed_to_obligations"]
                body_item["truncated"] = True
                remaining = max(0, remaining - (len(block) - item["mandatory"]))
                parts.append(block)
                provenance.extend(item["provenance"])
                omissions.append({
                    "ref": source.ref, "reason": "aggregate_byte_budget",
                    "priority": "optional",
                })
                continue
            available_body = remaining - trim["prefixOptional"] - 1
            if available_body <= 0:
                omissions.append({
                    "ref": source.ref, "reason": "aggregate_byte_budget",
                    "priority": "optional",
                })
                continue
            kept, truncated = _utf8_prefix(body, available_body)
            if not kept:
                omissions.append({
                    "ref": source.ref, "reason": "aggregate_byte_budget",
                    "priority": "optional",
                })
                continue
            block = prefix + kept + (b"" if kept.endswith(b"\n") else b"\n")
            body_item["excerptSha256"] = _sha256(kept)
            body_item["range"] = {"startByte": 0, "endByte": len(kept)}
            body_item["reasons"] = list(trim["reasons"]) + ["optional_truncated_to_remaining_allowance"]
            body_item["truncated"] = bool(truncated)
            remaining -= len(block)
            parts.append(block)
            provenance.extend(item["provenance"])

        prompt_raw = b"".join(parts)
        if len(prompt_raw) > budget_bytes:
            raise ContextOverflow(
                f"mandatory-overflow: aggregate invocation requires {len(prompt_raw)} "
                f"UTF-8 bytes but budget is {budget_bytes}"
            )
        if final_budget_bytes is not None and len(prompt_raw) > final_budget_bytes:
            raise ContextOverflow(
                f"complete review input exceeds composed budget: {len(prompt_raw)} "
                f"UTF-8 bytes > {final_budget_bytes}"
            )
        try:
            if base_path.read_bytes() != base_raw:
                raise ContextError(f"mandatory base prompt changed during invocation: {base_path}")
            if task_path.read_bytes() != task_raw:
                raise ContextError(f"mandatory task source changed during invocation: {task_path}")
        except OSError as exc:
            raise ContextError(f"mandatory invocation source changed during invocation: {exc}") from exc
        self.validate_snapshot()
        identity = dict(self.identity)
        identity["phase"] = phase
        _number_optional_selections(provenance)
        # Every delivered byte is charged to exactly one account. Mandatory
        # bytes are never trimmed, so the delivered optional total is the exact
        # remainder of the composed prompt.
        optional_delivered = max(0, len(prompt_raw) - mandatory_bytes)
        bundle: dict[str, Any] = {
            "schema": BUNDLE_SCHEMA,
            "contractVersion": 1,
            "status": "ok",
            "identity": identity,
            "policy": self.policy_identity,
            "invocation": {
                "invocationId": invocation_id,
                "campaignBinding": campaign_binding,
                "workspace": str(self.root),
            },
            "envelope": invocation_envelope,
            "prompt": prompt_raw.decode("utf-8"),
            "promptSha256": _sha256(prompt_raw),
            "provenance": provenance,
            # Optional overflow is recorded as an optional omission. It is never
            # relabelled as a mandatory overflow, which is a refusal, not a
            # selection outcome.
            "omissions": sorted(
                omissions, key=lambda item: (item["ref"], item["reason"])
            ),
            "budget": _budget_record(
                limit_bytes=budget_bytes, used_bytes=len(prompt_raw),
                mandatory_bytes=mandatory_bytes, optional_bytes=optional_delivered,
                evidence_bytes=evidence_bytes, reserve=reserve,
            ),
            "limitations": LEXICAL_LIMIT,
        }
        bundle["bundleId"] = _sha256(_canonical(bundle))
        return bundle

    def explain(self, bundle: dict[str, Any] | str | os.PathLike[str]) -> dict[str, Any]:
        if not self.enabled:
            return self._disabled(EXPLAIN_SCHEMA)
        if not isinstance(bundle, dict):
            value, _ = _read_json(Path(bundle), "context bundle")
            bundle = value
        if bundle.get("schema") != BUNDLE_SCHEMA:
            raise ContextError("wrong-version: explain requires singular.context.bundle.v1")
        claimed = bundle.get("bundleId")
        unsigned = dict(bundle)
        unsigned.pop("bundleId", None)
        actual = _sha256(_canonical(unsigned))
        if claimed != actual:
            raise ContextError(f"modified bundle: expected {claimed}, computed {actual}")
        return {
            "schema": EXPLAIN_SCHEMA,
            "status": "ok",
            "bundleId": claimed,
            "identity": bundle["identity"],
            "promptSha256": bundle["promptSha256"],
            "budget": bundle["budget"],
            "selections": bundle["provenance"],
            "omissions": bundle["omissions"],
            "limitations": bundle["limitations"],
        }


def context_policy_view(
    config: str | os.PathLike[str],
    *,
    workspace: str | os.PathLike[str],
    environment: Mapping[str, str],
    roles: Sequence[str] = ("planner", "implementer", "review-target", "assistant"),
    source: str | None = None,
) -> dict[str, Any]:
    """Produce the shared effective context-policy view for diagnostics."""
    descriptions: dict[str, dict[str, Any]] = {}
    for role in roles:
        descriptions[role] = ContextService.from_config(
            config,
            role=role,
            phase="diagnostic",
            workspace=workspace,
            environment=environment,
        ).describe()
    representative = descriptions[roles[0]]
    policy = representative["policy"]
    return {
        "status": "ok" if representative["enabled"] else "disabled",
        "configuration": {
            "path": policy["configPath"],
            "source": source,
            "status": "ok",
            "sha256": policy["configSha256"],
        },
        "workspace": str(Path(os.path.abspath(workspace)).resolve()),
        "enabled": representative["enabled"],
        "projectId": representative["projectId"],
        "budgetBytes": representative["budgetBytes"],
        "budgetSource": representative["budgetSource"],
        "roles": descriptions,
    }


def publish_bundle(bundle: dict[str, Any], destination: str | os.PathLike[str]) -> None:
    """Atomically publish the single prompt+provenance bundle JSON artifact."""
    path = Path(destination)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = _canonical(bundle) + b"\n"
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=".context-bundle.", suffix=".tmp",
            dir=path.parent, delete=False,
        ) as handle:
            temporary = handle.name
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
