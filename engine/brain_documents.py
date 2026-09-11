#!/usr/bin/env python3
"""Validate, normalize, select, and render singular-brain manifest v1 documents.

This module is deliberately standard-library-only and read-only. Descriptor paths
are resolved relative to the effective singular JSON configuration file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any


OUTPUT_SCHEMA = "singular.context.brain-documents.v1"
FORMAT = "singular-brain.manifest.v1"
AUTHORED_SCHEMA = "singular.orchestration.ctx-rehydrate-authored-manifest.v0"
ADAPTERS = {"markdown-doc", "claude-skill"}
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
MANIFEST_FIELDS = {"schema", "scope", "title", "entries"}
DESCRIPTOR_FIELDS = {
    "format", "manifest", "sourceId", "expectedScope", "sourceRoot", "select"
}
ENTRY_FIELDS = {"path", "section", "adapter", "tier", "title"}
TIER1_OPTIONAL_STRINGS = {
    "type", "status", "ratified", "updated", "owner", "description", "note"
}
TIER1_FIELDS = ENTRY_FIELDS | TIER1_OPTIONAL_STRINGS | {"loadWhen", "relates", "freshness"}
TIER2_FIELDS = ENTRY_FIELDS | {"excerpt", "statusHint", "updated"}
TRUNCATION = "\n[... authored section truncated to fit the context budget ...]"
MARKER = "[authored-knowledge -- not authoritative]"


class ConsumerError(Exception):
    """A configured brain input is invalid and must fail closed."""


def _sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _load_json(path: Path, label: str) -> tuple[Any, bytes]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ConsumerError(f"{label} is not readable: {path}: {exc.strerror}") from exc
    try:
        return json.loads(raw.decode("utf-8")), raw
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConsumerError(f"{label} is not valid UTF-8 JSON: {path}: {exc}") from exc


def _string(value: Any, field: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        suffix = "a non-empty string" if nonempty else "a string"
        raise ConsumerError(f"{field} must be {suffix}")
    return value


def _descriptor(config_path: Path) -> dict[str, Any]:
    config, _ = _load_json(config_path, "configuration")
    if not isinstance(config, dict):
        raise ConsumerError("configuration must be a JSON object")
    if "contextManifest" not in config:
        raise ConsumerError("configuration.contextManifest is absent")
    value = config["contextManifest"]
    if not isinstance(value, dict):
        raise ConsumerError("configuration.contextManifest must be an object for brain mode")
    missing = sorted(DESCRIPTOR_FIELDS - value.keys())
    unknown = sorted(value.keys() - DESCRIPTOR_FIELDS)
    if missing:
        raise ConsumerError("contextManifest missing required field(s): " + ", ".join(missing))
    if unknown:
        raise ConsumerError("contextManifest has unknown field(s): " + ", ".join(unknown))
    if _string(value["format"], "contextManifest.format") != FORMAT:
        raise ConsumerError(
            f"contextManifest.format must be {FORMAT!r}; got {value['format']!r}"
        )
    for key in ("manifest", "sourceId", "expectedScope", "sourceRoot"):
        _string(value[key], f"contextManifest.{key}")
    select = value["select"]
    if not isinstance(select, list):
        raise ConsumerError("contextManifest.select must be an array of artifact paths")
    seen: set[str] = set()
    for index, selected in enumerate(select):
        _safe_relative(selected, f"contextManifest.select[{index}]")
        if selected in seen:
            raise ConsumerError(f"contextManifest.select contains duplicate path: {selected}")
        seen.add(selected)
    return value


def _resolve_config_path(config_path: Path, configured: str) -> Path:
    candidate = Path(configured)
    if not candidate.is_absolute():
        candidate = config_path.parent / candidate
    return Path(os.path.abspath(candidate))


def _safe_relative(value: Any, field: str) -> str:
    path = _string(value, field)
    if "\\" in path or "\x00" in path:
        raise ConsumerError(f"{field} must use a safe POSIX relative path: {path!r}")
    pure = PurePosixPath(path)
    if pure.is_absolute() or path.startswith("/") or any(p in ("", ".", "..") for p in pure.parts):
        raise ConsumerError(f"{field} must be a canonical relative path without traversal: {path!r}")
    if re.match(r"^[A-Za-z]:", path):
        raise ConsumerError(f"{field} must not be an absolute path: {path!r}")
    canonical = pure.as_posix()
    if canonical != path:
        raise ConsumerError(f"{field} must be canonical; got {path!r}, expected {canonical!r}")
    return canonical


def _normalize_text(raw: bytes, field: str) -> str:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ConsumerError(f"{field} must contain UTF-8 text: {exc}") from exc
    if text.startswith("\ufeff"):
        text = text[1:]
    return text.replace("\r\n", "\n")


def _frontmatter(
    text: str, *, folded: bool, lenient: bool
) -> tuple[dict[str, Any], str]:
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return {}, text
    try:
        end = lines.index("---", 1)
    except ValueError:
        if lenient:
            return {}, text
        raise ConsumerError(
            'source frontmatter parse error: opening "---" has no exact closing "---" line'
        )
    fields: dict[str, Any] = {}
    list_key: str | None = None
    i = 1
    while i < end:
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        match_item = re.match(r"^\s+-\s+(.+?)\s*$", line)
        if match_item and list_key and isinstance(fields.get(list_key), list):
            fields[list_key].append(_strip_quotes(match_item.group(1)))
            i += 1
            continue
        match_key = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):(?:\s+(.*?))?\s*$", line)
        if not match_key:
            if not lenient:
                raise ConsumerError(
                    f"source frontmatter parse error at line {i + 1}: {line!r}"
                )
            list_key = None
            i += 1
            continue
        key, value = match_key.group(1), match_key.group(2)
        if folded and value in (">", ">-"):
            values: list[str] = []
            while i + 1 < end and re.match(r"^\s+\S", lines[i + 1]):
                values.append(lines[i + 1].strip())
                i += 1
            fields[key] = " ".join(values)
            list_key = None
        elif value is None or value == "":
            fields[key] = []
            list_key = key
        else:
            fields[key] = _strip_quotes(value)
            list_key = None
        i += 1
    return fields, "\n".join(lines[end + 1 :])


def _strip_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _live_metadata(adapter: str, raw: bytes) -> tuple[dict[str, Any], str, str]:
    text = _normalize_text(raw, "source")
    fields, body = _frontmatter(
        text,
        folded=adapter == "claude-skill",
        lenient=adapter == "claude-skill",
    )
    if adapter == "claude-skill":
        normalized: dict[str, Any] = {"type": "skill", "status": "vendored"}
        description = fields.get("description")
        if isinstance(description, str) and description:
            normalized["description"] = description
        fields = normalized
    description = fields.get("description") if isinstance(fields.get("description"), str) else ""
    load_when = fields.get("load-when")
    parts = [description]
    if isinstance(load_when, list):
        parts.extend(v for v in load_when if isinstance(v, str))
    meta_hash = _sha256("\n".join(parts).encode("utf-8"))
    return fields, meta_hash, _sha256(body.encode("utf-8"))


def _validate_entry(entry: Any, index: int) -> dict[str, Any]:
    prefix = f"manifest.entries[{index}]"
    if not isinstance(entry, dict):
        raise ConsumerError(f"{prefix} must be an object")
    for field in ("path", "section", "adapter", "title"):
        _string(entry.get(field), f"{prefix}.{field}")
    rel = _safe_relative(entry["path"], f"{prefix}.path")
    adapter = entry["adapter"]
    if adapter not in ADAPTERS:
        raise ConsumerError(f"{prefix}.adapter is unsupported: {adapter!r}")
    tier = entry.get("tier")
    if isinstance(tier, bool) or tier not in (1, 2):
        raise ConsumerError(f"{prefix}.tier must be integer 1 or 2")
    if adapter == "claude-skill" and tier != 1:
        raise ConsumerError(f"{prefix}: claude-skill entries must be tier 1")
    allowed = TIER1_FIELDS if tier == 1 else TIER2_FIELDS
    unknown = sorted(entry.keys() - allowed)
    if unknown:
        raise ConsumerError(f"{prefix} has unexpected field(s): " + ", ".join(unknown))
    if tier == 1:
        for field in TIER1_OPTIONAL_STRINGS:
            if field in entry and not isinstance(entry[field], str):
                raise ConsumerError(f"{prefix}.{field} must be a string")
        if "loadWhen" in entry:
            load_when = entry["loadWhen"]
            if not isinstance(load_when, list) or not all(isinstance(x, str) for x in load_when):
                raise ConsumerError(f"{prefix}.loadWhen must be an array of strings")
        if "relates" in entry:
            relates = entry["relates"]
            if not isinstance(relates, list) or not all(isinstance(x, str) for x in relates):
                raise ConsumerError(f"{prefix}.relates must be an array of strings")
        if "freshness" in entry:
            fresh = entry["freshness"]
            if not isinstance(fresh, dict):
                raise ConsumerError(f"{prefix}.freshness must be an object")
            _string(fresh.get("state"), f"{prefix}.freshness.state")
            for field in ("meta", "body"):
                if field in fresh and (not isinstance(fresh[field], str) or not HASH_RE.match(fresh[field])):
                    raise ConsumerError(f"{prefix}.freshness.{field} must be sha256:<64 lowercase hex>")
    else:
        if "excerpt" in entry and not isinstance(entry["excerpt"], str):
            raise ConsumerError(f"{prefix}.excerpt must be a string")
        if "updated" in entry and not isinstance(entry["updated"], str):
            raise ConsumerError(f"{prefix}.updated must be a string")
        if "statusHint" in entry:
            hint = entry["statusHint"]
            if not isinstance(hint, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in hint.items()):
                raise ConsumerError(f"{prefix}.statusHint must be an object of string values")
    result = dict(entry)
    result["path"] = rel
    return result


def normalize(config: str | os.PathLike[str]) -> tuple[dict[str, Any], dict[str, bytes]]:
    config_path = Path(os.path.abspath(config))
    descriptor = _descriptor(config_path)
    manifest_path = _resolve_config_path(config_path, descriptor["manifest"])
    declared_root = _resolve_config_path(config_path, descriptor["sourceRoot"])
    try:
        resolved_root = declared_root.resolve(strict=True)
    except OSError as exc:
        raise ConsumerError(f"contextManifest.sourceRoot is not resolvable: {declared_root}: {exc}") from exc
    if not resolved_root.is_dir():
        raise ConsumerError(f"contextManifest.sourceRoot is not a directory: {declared_root}")

    manifest, manifest_raw = _load_json(manifest_path, "contextManifest.manifest")
    if not isinstance(manifest, dict):
        raise ConsumerError("manifest must be a JSON object")
    unknown_manifest_fields = sorted(manifest.keys() - MANIFEST_FIELDS)
    if unknown_manifest_fields:
        raise ConsumerError(
            "manifest has unknown field(s): " + ", ".join(unknown_manifest_fields)
        )
    if manifest.get("schema") != FORMAT:
        raise ConsumerError(f"manifest.schema must be {FORMAT!r}; got {manifest.get('schema')!r}")
    scope = _string(manifest.get("scope"), "manifest.scope")
    if scope != descriptor["expectedScope"]:
        raise ConsumerError(
            f"manifest.scope mismatch: expected {descriptor['expectedScope']!r}, got {scope!r}"
        )
    _string(manifest.get("title"), "manifest.title")
    entries = manifest.get("entries")
    if not isinstance(entries, list):
        raise ConsumerError("manifest.entries must be an array")

    manifest_hash = _sha256(manifest_raw)
    selected_paths = set(descriptor["select"])
    records: list[dict[str, Any]] = []
    bodies: dict[str, bytes] = {}
    by_declared: dict[str, dict[str, Any]] = {}
    identities: set[str] = set()
    resolved_sources: dict[Path, str] = {}

    for index, raw_entry in enumerate(entries):
        entry = _validate_entry(raw_entry, index)
        rel = entry["path"]
        if rel in by_declared:
            raise ConsumerError(f"duplicate manifest artifact path: {rel}")
        declared_source = declared_root.joinpath(*PurePosixPath(rel).parts)
        reasons: list[str] = []
        raw: bytes | None = None
        resolved_source: Path | None = None
        exists = declared_source.exists()
        if exists:
            try:
                resolved_source = declared_source.resolve(strict=True)
            except OSError as exc:
                raise ConsumerError(f"manifest entry {rel!r} cannot be resolved: {exc}") from exc
            try:
                resolved_source.relative_to(resolved_root)
            except ValueError as exc:
                raise ConsumerError(
                    f"manifest entry {rel!r} resolves outside contextManifest.sourceRoot: {resolved_source}"
                ) from exc
            if not resolved_source.is_file():
                reasons.append("source_not_regular_file")
            else:
                previous = resolved_sources.get(resolved_source)
                if previous is not None:
                    raise ConsumerError(
                        f"canonical source collision: {previous!r} and {rel!r} resolve to {resolved_source}"
                    )
                resolved_sources[resolved_source] = rel
                try:
                    raw = resolved_source.read_bytes()
                except OSError as exc:
                    reasons.append("source_unreadable")
        else:
            reasons.append("missing_source")

        canonical_rel = rel
        if resolved_source is not None:
            canonical_rel = resolved_source.relative_to(resolved_root).as_posix()
        artifact_id = f"{descriptor['sourceId']}:{scope}:{canonical_rel}"
        if artifact_id in identities:
            raise ConsumerError(f"duplicate artifact identity: {artifact_id}")
        identities.add(artifact_id)

        declared_quarantine = rel.endswith(".quarantined") or Path(str(declared_source) + ".quarantined").exists()
        resolved_quarantine = False
        if resolved_source is not None:
            resolved_quarantine = (
                str(resolved_source).endswith(".quarantined")
                or Path(str(resolved_source) + ".quarantined").exists()
            )
        if declared_quarantine:
            reasons.append("declared_path_quarantined")
        if resolved_quarantine:
            reasons.append("resolved_source_quarantined")

        live_full = _sha256(raw) if raw is not None else None
        live_fields: dict[str, Any] = {}
        live_meta = None
        live_body = None
        if raw is not None:
            live_fields, live_meta, live_body = _live_metadata(entry["adapter"], raw)

        fresh = entry.get("freshness")
        review_state = fresh.get("state") if isinstance(fresh, dict) else "unknown"
        review_meta = fresh.get("meta") if isinstance(fresh, dict) else None
        review_body = fresh.get("body") if isinstance(fresh, dict) else None
        meta_matches = review_meta is not None and live_meta == review_meta
        body_matches = review_body is not None and live_body == review_body
        if review_state == "unknown" or review_meta is None or review_body is None:
            reasons.append("review_unknown")
        elif review_state != "clean":
            reasons.append("review_" + re.sub(r"[^a-z0-9]+", "_", review_state.lower()).strip("_"))
        if review_meta is not None and live_meta is not None and not meta_matches:
            reasons.append("routing_metadata_changed")
        if review_body is not None and live_body is not None and not body_matches:
            reasons.append("review_body_mismatch")

        manifest_status = entry.get("status") if entry["tier"] == 1 else None
        source_status = live_fields.get("status") if isinstance(live_fields.get("status"), str) else None
        if manifest_status is None:
            lifecycle_state = "unknown"
            reasons.append("lifecycle_unknown")
        elif manifest_status.lower() == "superseded":
            lifecycle_state = "superseded"
            reasons.append("lifecycle_superseded")
        else:
            lifecycle_state = "current"
        if raw is not None and source_status != manifest_status:
            reasons.append("lifecycle_metadata_changed")

        # Stable ordering and no duplicate reason strings.
        reasons = list(dict.fromkeys(reasons))
        selected = rel in selected_paths
        record = {
            "sourceId": descriptor["sourceId"],
            "scope": scope,
            "artifactId": artifact_id,
            "artifactPath": rel,
            "canonicalPath": canonical_rel,
            "declaredSourcePath": str(declared_source),
            "resolvedSourcePath": str(resolved_source) if resolved_source else None,
            "adapter": entry["adapter"],
            "tier": entry["tier"],
            "section": entry["section"],
            "title": entry["title"],
            "description": entry.get("description") or entry.get("excerpt"),
            "loadWhen": entry.get("loadWhen", []),
            "statusHint": entry.get("statusHint"),
            "review": {
                "state": review_state,
                "metaHash": review_meta,
                "bodyHash": review_body,
                "liveMetaHash": live_meta,
                "liveBodyHash": live_body,
                "metaMatches": meta_matches if review_meta is not None and live_meta is not None else None,
                "bodyMatches": body_matches if review_body is not None and live_body is not None else None,
            },
            "lifecycle": {
                "state": lifecycle_state,
                "manifestStatus": manifest_status,
                "sourceStatus": source_status,
            },
            "integrity": {"liveSourceSha256": live_full},
            "provenance": {
                "manifestPath": str(manifest_path),
                "manifestSha256": manifest_hash,
                "sourceLocation": str(declared_source),
                "approval": "unknown",
                "authoritative": False,
                "hostVerified": False,
            },
            "selected": selected,
            "eligible": not reasons,
            "included": selected and not reasons,
            "exclusionReasons": reasons,
        }
        records.append(record)
        by_declared[rel] = record
        if raw is not None:
            bodies[artifact_id] = raw

    selection = []
    for requested in descriptor["select"]:
        record = by_declared.get(requested)
        if record is None:
            selection.append({
                "requestedPath": requested,
                "artifactId": None,
                "included": False,
                "exclusionReasons": ["not_in_manifest"],
            })
        else:
            selection.append({
                "requestedPath": requested,
                "artifactId": record["artifactId"],
                "included": record["included"],
                "exclusionReasons": record["exclusionReasons"],
            })

    output = {
        "schema": OUTPUT_SCHEMA,
        "format": FORMAT,
        "sourceId": descriptor["sourceId"],
        "scope": scope,
        "manifestPath": str(manifest_path),
        "declaredSourceRoot": str(declared_root),
        "resolvedSourceRoot": str(resolved_root),
        "manifestSha256": manifest_hash,
        "selection": selection,
        "documents": sorted(records, key=lambda item: item["artifactId"]),
    }
    return output, bodies


def _included(output: dict[str, Any]) -> list[dict[str, Any]]:
    return [record for record in output["documents"] if record["included"]]


def render(output: dict[str, Any], bodies: dict[str, bytes], cap: int) -> str:
    parts: list[str] = []
    for record in _included(output):
        body = bodies[record["artifactId"]].decode("utf-8", "replace")
        if len(body) > cap:
            keep = max(0, cap - len(TRUNCATION))
            body = body[:keep] + TRUNCATION
        parts.extend((f"=== authored:{record['artifactId']} ===", MARKER, body))
    return "\n".join(parts) + ("\n" if parts else "")


def authored_manifest(output: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": AUTHORED_SCHEMA,
        "sources": [
            {
                "id": record["artifactId"],
                "sha256": record["integrity"]["liveSourceSha256"].removeprefix("sha256:"),
                "class": "authored-knowledge",
                "authoritative": False,
            }
            for record in _included(output)
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("normalize", "render", "authored-manifest"):
        sub = subparsers.add_parser(command)
        sub.add_argument("--config", required=True, help="effective singular JSON config file")
        if command == "render":
            sub.add_argument("--max-chars", type=int, default=4000)
    args = parser.parse_args(argv)
    try:
        output, bodies = normalize(args.config)
        if args.command == "normalize":
            json.dump(output, sys.stdout, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            sys.stdout.write("\n")
        elif args.command == "render":
            if args.max_chars < 0:
                raise ConsumerError("--max-chars must be non-negative")
            sys.stdout.write(render(output, bodies, args.max_chars))
        else:
            json.dump(authored_manifest(output), sys.stdout, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            sys.stdout.write("\n")
    except ConsumerError as exc:
        print(f"brain manifest consumer: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
