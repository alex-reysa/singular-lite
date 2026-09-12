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
from typing import Any

try:  # Import works both as engine.context_service and as an installed script.
    from engine import brain_documents
except ImportError:  # pragma: no cover - exercised by the installed CLI
    import brain_documents  # type: ignore


BUNDLE_SCHEMA = "singular.context.bundle.v1"
SEARCH_SCHEMA = "singular.context.search.v1"
GET_SCHEMA = "singular.context.get.v1"
EXPLAIN_SCHEMA = "singular.context.explain.v1"
POLICY_VERSION = "singular.context.policy.v1"
RETRIEVAL_VERSION = "exact-lexical.v1"
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
    ) -> "ContextService":
        config_path = Path(os.path.abspath(config))
        value, config_raw = _read_json(config_path, "context configuration")
        root = config_path.parent.resolve()
        settings = value.get("contextService")
        if settings is None:
            settings = {}
        if not isinstance(settings, dict):
            raise ContextError("contextService must be an object")
        enabled = settings.get("enabled", False)
        if not isinstance(enabled, bool):
            raise ContextError("contextService.enabled must be boolean")
        project_id = settings.get("projectId", root.name)
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
        raw_kinds = policy.get(role, policy.get("*", []))
        if not isinstance(raw_kinds, list) or not all(
            isinstance(item, str) and item in {"brain", "code", "run"}
            for item in raw_kinds
        ):
            raise ContextError(f"contextService.rolePolicy.{role} must list brain/code/run")
        allowed = frozenset(raw_kinds)
        if not enabled:
            return cls(
                enabled=False, root=root, config_path=config_path,
                project_id=project_id, revision=revision, role=role, phase=phase,
                allowed_kinds=allowed, sources=(), config_hash=config_hash,
            )

        sources: list[Source] = []
        if "brain" in allowed and "contextManifest" in value:
            try:
                normalized, bodies = brain_documents.normalize(config_path)
            except brain_documents.ConsumerError as exc:
                raise ContextError(f"brain source is invalid: {exc}") from exc
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
        return {
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
        return {
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
    ) -> dict[str, Any]:
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
                "prompt": "",
                "promptSha256": _sha256(prompt),
                "provenance": [],
                "omissions": [],
                "budget": {
                    "unit": "utf8-bytes", "limitBytes": budget_bytes,
                    "usedBytes": 0, "remainingBytes": budget_bytes,
                    "mandatoryBytes": 0, "optionalBytes": 0,
                    "estimator": "utf8-exact.v1", "accountingBoundary": "host-invocation",
                    "providerVisibleBytes": None,
                    "unknownComponents": ["provider_system_content", "tool_schemas", "session_history", "model_output"],
                },
                "limitations": LEXICAL_LIMIT,
            }
            result["bundleId"] = _sha256(_canonical(result))
            return result
        if budget_bytes < 0:
            raise ContextError("budget-bytes must be non-negative")
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
        mandatory_bytes = sum(len(part) for _, part, _, _, _, _, _ in mandatory_parts)
        if mandatory_bytes > budget_bytes:
            raise ContextOverflow(
                "mandatory-overflow: task constraints and open/violated obligations "
                f"require {mandatory_bytes} UTF-8 bytes but budget is {budget_bytes}"
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
            available = budget_bytes - used
            header = f"=== retrieved:{source.ref} ===\n".encode()
            if available <= len(header):
                omissions.append({"ref": source.ref, "reason": "aggregate_byte_budget"})
                continue
            excerpt, start, end, truncated = self._excerpt(source, query_text, available - len(header))
            if not excerpt:
                omissions.append({"ref": source.ref, "reason": "aggregate_byte_budget"})
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
        bundle_identity = dict(self.identity)
        if phase != self.phase:
            bundle_identity["phase"] = phase
            bundle_identity["snapshotId"] = _sha256(_canonical({
                "sourceSnapshotId": self.identity["snapshotId"], "phase": phase,
            }))
        bundle: dict[str, Any] = {
            "schema": BUNDLE_SCHEMA,
            "contractVersion": 1,
            "status": "ok",
            "identity": bundle_identity,
            "prompt": prompt,
            "promptSha256": _sha256(prompt_bytes),
            "provenance": provenance,
            "omissions": sorted(omissions, key=lambda item: (item["ref"], item["reason"])),
            "budget": {
                "unit": "utf8-bytes", "limitBytes": budget_bytes,
                "usedBytes": len(prompt_bytes), "remainingBytes": budget_bytes - len(prompt_bytes),
                "mandatoryBytes": mandatory_bytes, "optionalBytes": optional_used,
                "estimator": "utf8-exact.v1", "accountingBoundary": "host-invocation",
                "providerVisibleBytes": None,
                "unknownComponents": ["provider_system_content", "tool_schemas", "session_history", "model_output"],
            },
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
