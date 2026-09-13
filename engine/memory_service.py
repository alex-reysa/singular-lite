#!/usr/bin/env python3
"""Governed, project-local persistent memory for Singular.

The durable authority is the set of immutable proposals plus explicit lifecycle
decisions in ``memoryService.storePath``.  The derived index may be deleted and
rebuilt without changing either approvals or retirement decisions.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import hmac
import json
import os
import re
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterator, Mapping


SCHEMA = "singular.orchestration.memory-record.v1"
AUTHORITY_SCHEMA = "singular.memory.authority.v1"
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


class MemoryError(ValueError):
    """A memory request or governed record is invalid."""


def _sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _read_json(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except FileNotFoundError as exc:
        raise MemoryError(f"{label} is missing: {path}") from exc
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MemoryError(f"{label} is invalid: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise MemoryError(f"{label} must be a JSON object: {path}")
    return value, raw


def _relative(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise MemoryError(f"containment: {label} must be a safe relative POSIX path")
    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value or any(
        part in ("", ".", "..") for part in path.parts
    ) or re.match(r"^[A-Za-z]:", value):
        raise MemoryError(f"containment: {label} escapes the project: {value!r}")
    return value


def _contained(root: Path, relative: str, label: str) -> Path:
    result = root.joinpath(*PurePosixPath(relative).parts).resolve(strict=False)
    try:
        result.relative_to(root)
    except ValueError as exc:
        raise MemoryError(f"containment: {label} resolves outside the project") from exc
    return result


def _atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix="." + path.name + ".", suffix=".tmp",
            dir=path.parent, delete=False,
        ) as handle:
            temporary = handle.name
            handle.write(_canonical(value) + b"\n")
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


class MemoryStore:
    """Filesystem-backed lifecycle store with cross-process serialization."""

    def __init__(self, config_path: Path, root: Path) -> None:
        config, _ = _read_json(config_path, "configuration")
        settings = config.get("memoryService", {})
        if not isinstance(settings, dict):
            raise MemoryError("memoryService must be an object")
        if settings.get("enabled", False) is not True:
            raise MemoryError("memoryService is disabled")
        self.root = root.resolve()
        self.config_path = config_path.resolve()
        self.settings = settings
        store_relative = _relative(settings.get("storePath", ".singular-memory"),
                                   "memoryService.storePath")
        self.store = _contained(self.root, store_relative, "memoryService.storePath")
        self.max_content = self._positive("maxContentBytes", 16384)
        self.max_checkpoint = self._positive("maxCheckpointBytes", 32768)

    def _positive(self, key: str, default: int) -> int:
        value = self.settings.get(key, default)
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            raise MemoryError(f"memoryService.{key} must be a positive integer")
        return value

    @contextlib.contextmanager
    def locked(self) -> Iterator[None]:
        self.store.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(self.store / ".lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def _record_path(self, memory_id: str) -> Path:
        if not re.fullmatch(r"mem-[0-9a-f]{32}", memory_id):
            raise MemoryError(f"invalid memory id: {memory_id!r}")
        return self.store / "records" / f"{memory_id}.json"

    def read_record(self, memory_id: str) -> dict[str, Any]:
        record, _ = _read_json(self._record_path(memory_id), "memory record")
        return record

    def write_record(self, record: dict[str, Any]) -> None:
        _atomic_json(self._record_path(record["memoryId"]), record)

    def records(self) -> list[dict[str, Any]]:
        directory = self.store / "records"
        if not directory.is_dir():
            return []
        records = [_read_json(path, "memory record")[0]
                   for path in sorted(directory.glob("mem-*.json"))]
        return records

    def _operation_path(self, operation_id: str) -> Path:
        if not isinstance(operation_id, str) or not operation_id:
            raise MemoryError("operation-id must be non-empty")
        name = hashlib.sha256(operation_id.encode("utf-8")).hexdigest()
        return self.store / "operations" / f"{name}.json"

    def replay(self, operation_id: str, request: Mapping[str, Any]) -> dict[str, Any] | None:
        path = self._operation_path(operation_id)
        if not path.exists():
            return None
        operation, _ = _read_json(path, "operation record")
        fingerprint = _sha256(_canonical(request))
        if operation.get("operationId") != operation_id or operation.get("fingerprint") != fingerprint:
            raise MemoryError(f"operation-id conflict: {operation_id}")
        self._recover_operation(path, operation)
        response = operation.get("response")
        if not isinstance(response, dict):
            raise MemoryError(f"operation record is corrupt: {operation_id}")
        return response

    def _recover_operation(self, path: Path, operation: dict[str, Any]) -> None:
        if operation.get("state") == "committed":
            return
        if operation.get("state") != "prepared":
            raise MemoryError(f"operation journal is corrupt: {operation.get('operationId')}")
        for record in operation.get("recordWrites", []):
            if not isinstance(record, dict):
                raise MemoryError("operation journal contains an invalid memory record")
            self.write_record(record)
        for checkpoint in operation.get("checkpointWrites", []):
            if not isinstance(checkpoint, dict) or not isinstance(checkpoint.get("checkpointId"), str):
                raise MemoryError("operation journal contains an invalid checkpoint")
            _atomic_json(
                self.store / "checkpoints" / f"{checkpoint['checkpointId']}.json",
                checkpoint,
            )
        if operation.get("refreshIndex", False):
            self._write_index_unlocked()
        if os.environ.get("SINGULAR_MEMORY_FAIL_AFTER_STATE") == operation.get("operationId"):
            raise MemoryError(
                f"injected interruption after durable state: {operation.get('operationId')}"
            )
        operation["state"] = "committed"
        _atomic_json(path, operation)

    def commit_operation(
        self,
        operation_id: str,
        request: Mapping[str, Any],
        response: dict[str, Any],
        *,
        record_writes: list[dict[str, Any]] | None = None,
        checkpoint_writes: list[dict[str, Any]] | None = None,
        refresh_index: bool = False,
    ) -> None:
        path = self._operation_path(operation_id)
        operation = {
            "operationId": operation_id,
            "fingerprint": _sha256(_canonical(request)),
            "response": response,
            "state": "prepared",
            "recordWrites": record_writes or [],
            "checkpointWrites": checkpoint_writes or [],
            "refreshIndex": refresh_index,
        }
        _atomic_json(path, operation)
        if os.environ.get("SINGULAR_MEMORY_FAIL_AFTER_JOURNAL") == operation_id:
            raise MemoryError(f"injected interruption after durable journal: {operation_id}")
        self._recover_operation(path, operation)

    def verify_credential(
        self, credential_path: str, expected: Mapping[str, Any]
    ) -> dict[str, Any]:
        configured_id = self.settings.get("credentialKeyId")
        configured_hash = self.settings.get("credentialKeySha256")
        if not isinstance(configured_id, str) or not configured_id:
            raise MemoryError("memoryService.credentialKeyId must be configured")
        if not isinstance(configured_hash, str) or not HASH_RE.match(configured_hash):
            raise MemoryError("memoryService.credentialKeySha256 must be configured")
        secret = os.environ.get("SINGULAR_MEMORY_CREDENTIAL_KEY")
        if not secret or _sha256(secret.encode("utf-8")) != configured_hash:
            raise MemoryError("authenticated host credential key is unavailable or invalid")
        relative, _, raw = self.local_file(credential_path, "decision credential")
        try:
            document = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MemoryError("decision credential is invalid") from exc
        if not isinstance(document, dict):
            raise MemoryError("decision credential must be an object")
        signature = document.pop("signature", None)
        expected_signature = "hmac-sha256:" + hmac.new(
            secret.encode("utf-8"), _canonical(document), hashlib.sha256
        ).hexdigest()
        if not isinstance(signature, str) or not hmac.compare_digest(signature, expected_signature):
            raise MemoryError("decision credential signature is invalid")
        if document.get("schema") != "singular.memory.credential.v1":
            raise MemoryError("decision credential schema is invalid")
        if document.get("keyId") != configured_id:
            raise MemoryError("decision credential key identity is invalid")
        for key, value in expected.items():
            if document.get(key) != value:
                label = "credential subject" if key in {"subjectId", "subjectType"} else "credential claim"
                raise MemoryError(f"{label} mismatch for {key}")
        allowed = {"schema", "keyId", *expected.keys()}
        if set(document) != allowed:
            raise MemoryError("decision credential has unbound claims")
        return {
            "path": relative,
            "sha256": _sha256(raw),
            "claimsSha256": _sha256(_canonical(document)),
            "keyId": configured_id,
            "subjectId": str(document["subjectId"]),
            "subjectType": str(document["subjectType"]),
            "claims": document,
            "signature": signature,
        }

    def local_file(self, raw: str, label: str, maximum: int | None = None) -> tuple[str, Path, bytes]:
        relative = _relative(raw, label)
        path = _contained(self.root, relative, label)
        try:
            content = path.read_bytes()
        except FileNotFoundError as exc:
            raise MemoryError(f"retained source is missing: {relative}") from exc
        except OSError as exc:
            raise MemoryError(f"retained source is unreadable: {relative}: {exc}") from exc
        if maximum is not None and len(content) > maximum:
            raise MemoryError(f"{label} exceeds configured byte bound {maximum}")
        return relative, path, content

    def policy(self, policy_id: str) -> dict[str, Any]:
        policies = self.settings.get("consumerPolicies", {})
        if not isinstance(policies, dict) or not isinstance(policies.get(policy_id), dict):
            raise MemoryError(f"unknown consumer policy: {policy_id}")
        policy = policies[policy_id]
        scopes = policy.get("scopes")
        roles = policy.get("approverRoles")
        context_roles = policy.get("contextRoles")
        if (not isinstance(scopes, list) or not all(isinstance(x, str) for x in scopes)
                or not isinstance(roles, list) or not all(isinstance(x, str) for x in roles)
                or not isinstance(context_roles, list)
                or not all(isinstance(x, str) for x in context_roles)
                or not isinstance(policy.get("humanReviewRequired"), bool)):
            raise MemoryError(f"consumer policy is invalid: {policy_id}")
        return policy

    def authority(self, authority_id: str, permission: str,
                  record: dict[str, Any] | None = None) -> dict[str, Any]:
        configured = self.settings.get("authorities", {})
        spec = configured.get(authority_id) if isinstance(configured, dict) else None
        if not isinstance(spec, dict):
            raise MemoryError(f"unverified approval authority: {authority_id}")
        source_rel, _, source_raw = self.local_file(
            str(spec.get("source", "")), f"authority {authority_id} source"
        )
        expected = spec.get("sha256")
        if not isinstance(expected, str) or not HASH_RE.match(expected) or _sha256(source_raw) != expected:
            raise MemoryError(f"authority source identity drift: {authority_id}")
        try:
            document = json.loads(source_raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MemoryError(f"authority source is invalid: {authority_id}") from exc
        if (not isinstance(document, dict) or document.get("schema") != AUTHORITY_SCHEMA
                or document.get("authorityId") != authority_id
                or not isinstance(document.get("subjectId"), str)
                or document.get("subjectType") not in {"human", "internal-role"}
                or permission not in document.get("permissions", [])):
            raise MemoryError(f"authority does not grant {permission}: {authority_id}")
        code_identity = spec.get("codeIdentity", [])
        if not isinstance(code_identity, list):
            raise MemoryError(f"authority codeIdentity is invalid: {authority_id}")
        verified_code: list[dict[str, str]] = []
        for index, item in enumerate(code_identity):
            if not isinstance(item, dict):
                raise MemoryError(f"authority codeIdentity[{index}] is invalid")
            relative, _, raw = self.local_file(
                str(item.get("path", "")), f"authority code identity {index}"
            )
            expected_code = item.get("sha256")
            if not isinstance(expected_code, str) or _sha256(raw) != expected_code:
                raise MemoryError(f"code identity drift for authority {authority_id}: {relative}")
            verified_code.append({"path": relative, "sha256": expected_code})
        if record is not None:
            policy = self.policy(record["policyId"])
            if record.get("scope") not in policy["scopes"]:
                raise MemoryError(
                    f"memory scope {record.get('scope')!r} is revoked by current consumer policy"
                )
            roles = document.get("roles", [])
            if not isinstance(roles, list) or not set(roles).intersection(policy["approverRoles"]):
                raise MemoryError(f"authority has no policy approver role: {authority_id}")
            if document["subjectId"] == record["proposer"]["actorId"]:
                raise MemoryError("approval must be independent; self-approval is forbidden")
            if policy["humanReviewRequired"] and document["subjectType"] != "human":
                raise MemoryError("consumer policy requires human review")
        return {
            "authorityId": authority_id,
            "subjectId": document["subjectId"],
            "subjectType": document["subjectType"],
            "roles": document.get("roles", []),
            "source": {"path": source_rel, "sha256": expected},
            "codeIdentity": verified_code,
        }

    def trust(self, record: dict[str, Any]) -> str:
        if record.get("status") != "approved":
            return "untrusted" if record.get("status") == "proposed" else "retired"
        approval = record.get("approval")
        if not isinstance(approval, dict):
            return "invalid-authority"
        try:
            current = self.authority(approval.get("authorityId", ""), "approve", record)
        except MemoryError:
            return "invalid-authority"
        if current != {key: approval.get(key) for key in current}:
            return "invalid-authority"
        try:
            self.validate_artifacts(record)
        except MemoryError:
            return "invalid-source"
        return "trusted"

    def validate_artifacts(self, record: dict[str, Any]) -> None:
        for source in record.get("sources", []):
            _, _, raw = self.local_file(source["path"], "retained source")
            if _sha256(raw) != source.get("sha256"):
                raise MemoryError(f"retained source identity drift: {source['path']}")
        content = record.get("content", {})
        try:
            _, _, raw = self.local_file(content["path"], "authored artifact")
        except KeyError as exc:
            raise MemoryError("authored artifact identity is missing") from exc
        if _sha256(raw) != content.get("sha256"):
            raise MemoryError(f"authored artifact identity drift: {content['path']}")
        for source in record.get("codeIdentity", []):
            _, _, raw = self.local_file(source["path"], "code provenance")
            if _sha256(raw) != source.get("sha256"):
                raise MemoryError(f"code provenance identity drift: {source['path']}")

    def view(self, record: dict[str, Any]) -> dict[str, Any]:
        result = json.loads(json.dumps(record))
        result["trust"] = self.trust(record)
        return result

    def _write_index_unlocked(self) -> dict[str, Any]:
        trusted = [record["memoryId"] for record in self.records()
                   if self.trust(record) == "trusted"]
        index = {"schema": "singular.memory.index.v1", "trusted": trusted,
                 "trustedCount": len(trusted), "rebuiltAt": _now()}
        _atomic_json(self.store / "index.json", index)
        return index

    def propose(self, args: argparse.Namespace) -> dict[str, Any]:
        policy = self.policy(args.policy)
        if args.scope not in policy["scopes"]:
            raise MemoryError(f"scope {args.scope!r} is not allowed by policy {args.policy!r}")
        credential = self.verify_credential(args.credential, {
            "action": "propose", "operationId": args.operation_id,
            "subjectId": args.actor, "subjectType": "internal-role", "taskId": args.task,
            "scope": args.scope, "policyId": args.policy,
            "contentPath": args.content_file, "sourcePath": args.source,
            "codePaths": args.code,
        })
        content_rel, _, content = self.local_file(args.content_file, "content-file", self.max_content)
        source_rel, _, source = self.local_file(args.source, "retained source")
        code: list[dict[str, str]] = []
        for item in args.code:
            relative, _, raw = self.local_file(item, "code provenance")
            code.append({"path": relative, "sha256": _sha256(raw)})
        request = {
            "kind": "propose", "taskId": args.task, "actorId": args.actor,
            "scope": args.scope, "policyId": args.policy, "content": content_rel,
            "source": source_rel, "code": code,
            "credentialClaims": credential["claimsSha256"],
        }
        with self.locked():
            replay = self.replay(args.operation_id, request)
            if replay is not None:
                return replay
            memory_id = "mem-" + hashlib.sha256(
                _canonical({"operationId": args.operation_id, "request": request})
            ).hexdigest()[:32]
            created = _now()
            record = {
                "schema": SCHEMA,
                "memoryId": memory_id,
                "status": "proposed",
                "trust": "untrusted",
                "scope": args.scope,
                "policyId": args.policy,
                "proposal": {"operationId": args.operation_id, "taskId": args.task,
                             "createdAt": created},
                "proposer": {"actorId": args.actor, "taskId": args.task,
                             "credential": credential},
                "content": {"path": content_rel, "sha256": _sha256(content),
                            "bytes": len(content)},
                "sources": [{"path": source_rel, "sha256": _sha256(source)}],
                "codeIdentity": code,
                "createdAt": created,
                "updatedAt": created,
            }
            response = {"schema": "singular.memory.operation.v1", "memory": record}
            self.commit_operation(
                args.operation_id, request, response,
                record_writes=[record], refresh_index=True,
            )
            return response

    def review(self, args: argparse.Namespace) -> dict[str, Any]:
        record = self.read_record(args.memory_id)
        authority = self.authority(args.authority, "review", record)
        return {"schema": "singular.memory.review.v1", "memoryId": args.memory_id,
                "eligible": record["status"] == "proposed", "authority": authority}

    def decide(self, args: argparse.Namespace, action: str) -> dict[str, Any]:
        with self.locked():
            record = self.read_record(args.memory_id)
            permission = "reject" if action == "quarantine" else action
            authority = self.authority(args.authority, permission, record)
            expected_credential = {
                "action": action, "operationId": args.operation_id,
                "subjectId": authority["subjectId"],
                "subjectType": authority["subjectType"],
                "authorityId": args.authority, "memoryId": args.memory_id,
            }
            if getattr(args, "reason", None) is not None:
                expected_credential["reason"] = args.reason
            credential = self.verify_credential(args.credential, expected_credential)
            request = {"kind": action, "memoryId": args.memory_id,
                       "authorityId": args.authority,
                       "reason": getattr(args, "reason", None),
                       "credentialClaims": credential["claimsSha256"]}
            replay = self.replay(args.operation_id, request)
            if replay is not None:
                return replay
            if record["status"] != "proposed":
                raise MemoryError(f"{action} requires proposed memory; found {record['status']}")
            if action == "approve":
                self.validate_artifacts(record)
            record["status"] = (
                "approved" if action == "approve" else
                "quarantined" if action == "quarantine" else "rejected"
            )
            record["trust"] = "trusted" if action == "approve" else "retired"
            decision_field = (
                "approval" if action == "approve" else
                "quarantine" if action == "quarantine" else "rejection"
            )
            record[decision_field] = {
                **authority, "operationId": args.operation_id,
                "reason": getattr(args, "reason", None), "decidedAt": _now(),
                "credential": credential,
            }
            record["updatedAt"] = _now()
            response = {"schema": "singular.memory.operation.v1", "memory": self.view(record)}
            self.commit_operation(
                args.operation_id, request, response,
                record_writes=[record], refresh_index=True,
            )
            return response

    def supersede(self, args: argparse.Namespace) -> dict[str, Any]:
        with self.locked():
            old = self.read_record(args.memory_id)
            replacement = self.read_record(args.by)
            authority = self.authority(args.authority, "supersede", old)
            credential = self.verify_credential(args.credential, {
                "action": "supersede", "operationId": args.operation_id,
                "subjectId": authority["subjectId"],
                "subjectType": authority["subjectType"],
                "authorityId": args.authority, "memoryId": args.memory_id,
                "byMemoryId": args.by,
            })
            request = {"kind": "supersede", "memoryId": args.memory_id,
                       "by": args.by, "authorityId": args.authority,
                       "credentialClaims": credential["claimsSha256"]}
            replay = self.replay(args.operation_id, request)
            if replay is not None:
                return replay
            if old["status"] != "approved" or replacement["status"] != "approved":
                raise MemoryError("supersession requires approved current and replacement memories")
            if self.trust(replacement) != "trusted":
                raise MemoryError("supersession replacement is not trusted")
            old["status"] = "superseded"
            old["trust"] = "retired"
            old["supersession"] = {**authority, "operationId": args.operation_id,
                                    "byMemoryId": args.by, "decidedAt": _now(),
                                    "credential": credential}
            old["updatedAt"] = _now()
            response = {"schema": "singular.memory.operation.v1", "memory": old}
            self.commit_operation(
                args.operation_id, request, response,
                record_writes=[old], refresh_index=True,
            )
            return response

    def tombstone(self, args: argparse.Namespace) -> dict[str, Any]:
        with self.locked():
            record = self.read_record(args.memory_id)
            authority = self.authority(args.authority, "tombstone", record)
            credential = self.verify_credential(args.credential, {
                "action": "tombstone", "operationId": args.operation_id,
                "subjectId": authority["subjectId"],
                "subjectType": authority["subjectType"],
                "authorityId": args.authority, "memoryId": args.memory_id,
                "reason": args.reason,
            })
            request = {"kind": "tombstone", "memoryId": args.memory_id,
                       "authorityId": args.authority, "reason": args.reason,
                       "credentialClaims": credential["claimsSha256"]}
            replay = self.replay(args.operation_id, request)
            if replay is not None:
                return replay
            if record["status"] not in {"approved", "superseded"}:
                raise MemoryError(f"tombstone cannot retire status {record['status']}")
            record["status"] = "tombstoned"
            record["trust"] = "retired"
            record["tombstone"] = {**authority, "operationId": args.operation_id,
                                   "reason": args.reason, "decidedAt": _now(),
                                   "credential": credential}
            record["updatedAt"] = _now()
            response = {"schema": "singular.memory.operation.v1", "memory": record}
            self.commit_operation(
                args.operation_id, request, response,
                record_writes=[record], refresh_index=True,
            )
            return response

    def rebuild(self) -> dict[str, Any]:
        with self.locked():
            return self._write_index_unlocked()

    def checkpoint_save(self, args: argparse.Namespace) -> dict[str, Any]:
        credential = self.verify_credential(args.credential, {
            "action": "checkpoint", "operationId": args.operation_id,
            "subjectId": args.actor, "subjectType": "internal-role", "taskId": args.task,
            "payloadPath": args.payload_file, "sourcePath": args.source,
        })
        payload_rel, _, raw = self.local_file(args.payload_file, "checkpoint payload",
                                              self.max_checkpoint)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MemoryError("checkpoint payload must be valid UTF-8 JSON") from exc
        source_rel, _, source = self.local_file(args.source, "retained source")
        request = {"kind": "checkpoint-save", "taskId": args.task,
                   "actorId": args.actor, "payload": payload_rel, "source": source_rel,
                   "credentialClaims": credential["claimsSha256"]}
        with self.locked():
            replay = self.replay(args.operation_id, request)
            if replay is not None:
                return replay
            checkpoint_id = "cp-" + hashlib.sha256(
                _canonical({"operationId": args.operation_id, "request": request})
            ).hexdigest()[:32]
            result = {
                "schema": "singular.memory.checkpoint.v1", "checkpointId": checkpoint_id,
                "taskId": args.task, "actorId": args.actor, "payload": payload,
                "payloadSource": {"path": payload_rel, "sha256": _sha256(raw)},
                "sources": [{"path": source_rel, "sha256": _sha256(source)}],
                "credential": credential,
                "createdAt": _now(),
            }
            self.commit_operation(
                args.operation_id, request, result, checkpoint_writes=[result]
            )
            return result

    def checkpoint_recover(self, task: str) -> dict[str, Any]:
        directory = self.store / "checkpoints"
        candidates: list[dict[str, Any]] = []
        if directory.is_dir():
            for path in sorted(directory.glob("cp-*.json")):
                record, _ = _read_json(path, "checkpoint")
                if record.get("taskId") == task:
                    candidates.append(record)
        if not candidates:
            raise MemoryError(f"no retained checkpoint for task {task}")
        result = max(candidates, key=lambda item: (item.get("createdAt", ""),
                                                   item.get("checkpointId", "")))
        for source in result.get("sources", []):
            _, _, raw = self.local_file(source["path"], "retained source")
            if _sha256(raw) != source.get("sha256"):
                raise MemoryError(f"retained source identity drift: {source['path']}")
        payload_source = result.get("payloadSource", {})
        _, _, payload_raw = self.local_file(payload_source.get("path", ""),
                                            "checkpoint payload", self.max_checkpoint)
        if _sha256(payload_raw) != payload_source.get("sha256"):
            raise MemoryError("checkpoint payload identity drift")
        return result


def trusted_memories(config_path: Path, root: Path, role: str) -> list[dict[str, Any]]:
    """Return currently trusted authored artifacts for context retrieval."""
    try:
        store = MemoryStore(config_path, root)
    except MemoryError as exc:
        if str(exc) == "memoryService is disabled":
            return []
        raise
    results: list[dict[str, Any]] = []
    with store.locked():
        for record in store.records():
            policy = store.policy(record["policyId"])
            if role not in policy["contextRoles"] or store.trust(record) != "trusted":
                continue
            dependencies: dict[Path, str] = {}

            def dependency(relative: str, expected: str, label: str) -> tuple[Path, bytes]:
                _, path, raw = store.local_file(relative, label)
                actual = _sha256(raw)
                if actual != expected:
                    raise MemoryError(f"{label} identity drift: {relative}")
                dependencies[path] = actual
                return path, raw

            record_path = store._record_path(record["memoryId"])
            record_raw = record_path.read_bytes()
            dependencies[record_path] = _sha256(record_raw)
            content = record["content"]
            path, raw = dependency(content["path"], content["sha256"], "authored artifact")
            for source in record["sources"]:
                dependency(source["path"], source["sha256"], "retained source")
            for source in record.get("codeIdentity", []):
                dependency(source["path"], source["sha256"], "code provenance")
            approval = record["approval"]
            dependency(
                approval["source"]["path"], approval["source"]["sha256"],
                "approval authority source",
            )
            for source in approval.get("codeIdentity", []):
                dependency(source["path"], source["sha256"], "approval code identity")
            results.append({
                "ref": "memory:" + record["memoryId"], "path": path,
                "relativePath": content["path"], "raw": raw,
                "sha256": content["sha256"], "title": PurePosixPath(content["path"]).name,
                "eligibilityInputs": [
                    {"path": input_path, "sha256": input_hash}
                    for input_path, input_hash in sorted(
                        dependencies.items(), key=lambda item: str(item[0])
                    )
                ],
                "provenance": {
                    "origin": SCHEMA,
                    "proposal": record["proposal"],
                    "proposer": record["proposer"],
                    "sources": record["sources"],
                    "approval": record["approval"],
                    "policyId": record["policyId"],
                },
            })
    return sorted(results, key=lambda item: item["ref"])


def _leaf(subparsers: argparse._SubParsersAction, name: str, help_text: str,
          *, operation: bool = False, authority: bool = False) -> argparse.ArgumentParser:
    parser = subparsers.add_parser(name, help=help_text)
    parser.add_argument("--config")
    if operation:
        parser.add_argument("--operation-id", required=True)
        parser.add_argument("--credential", required=True)
    if authority:
        parser.add_argument("--authority", required=True)
    return parser


def _commands() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="singular memory")
    sub = parser.add_subparsers(dest="command", required=True)
    propose = _leaf(sub, "propose", "capture an untrusted cited proposal", operation=True)
    propose.add_argument("--task", required=True)
    propose.add_argument("--actor", required=True)
    propose.add_argument("--scope", required=True)
    propose.add_argument("--policy", required=True)
    propose.add_argument("--content-file", required=True)
    propose.add_argument("--source", required=True)
    propose.add_argument("--code", action="append", default=[])
    review = _leaf(sub, "review", "validate reviewer eligibility", authority=True)
    review.add_argument("--memory-id", required=True)
    for name in ("approve", "reject", "quarantine"):
        decision = _leaf(sub, name, f"{name} a proposal", operation=True, authority=True)
        decision.add_argument("--memory-id", required=True)
        if name in {"reject", "quarantine"}:
            decision.add_argument("--reason", required=True)
    supersede = _leaf(sub, "supersede", "retire memory in favor of another",
                      operation=True, authority=True)
    supersede.add_argument("--memory-id", required=True)
    supersede.add_argument("--by", required=True)
    tombstone = _leaf(sub, "tombstone", "durably retire memory", operation=True,
                      authority=True)
    tombstone.add_argument("--memory-id", required=True)
    tombstone.add_argument("--reason", required=True)
    show = _leaf(sub, "show", "show memory with live trust revalidation")
    show.add_argument("--memory-id", required=True)
    _leaf(sub, "rebuild", "rebuild the derived trusted index")
    checkpoint = sub.add_parser("checkpoint", help="save or recover a bounded checkpoint")
    checkpoint_sub = checkpoint.add_subparsers(dest="checkpoint_command", required=True)
    save = _leaf(checkpoint_sub, "save", "save checkpoint", operation=True)
    save.add_argument("--task", required=True)
    save.add_argument("--actor", required=True)
    save.add_argument("--payload-file", required=True)
    save.add_argument("--source", required=True)
    recover = _leaf(checkpoint_sub, "recover", "recover checkpoint")
    recover.add_argument("--task", required=True)
    return parser


def _outer() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--engine-home")
    parser.add_argument("--repo-root")
    parser.add_argument("--cwd")
    parser.add_argument("remainder", nargs=argparse.REMAINDER)
    return parser


def main(argv: list[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)
    root = Path.cwd().resolve()
    cwd = root
    if raw and any(raw[0] == name or raw[0].startswith(name + "=")
                   for name in ("--engine-home", "--repo-root", "--cwd")):
        outer = _outer().parse_args(raw)
        root = Path(outer.repo_root or root).resolve()
        cwd = Path(outer.cwd or cwd).resolve()
        raw = outer.remainder
        if raw and raw[0] == "--":
            raw = raw[1:]
    args = _commands().parse_args(raw)
    try:
        config_raw = getattr(args, "config", None)
        config = Path(config_raw).expanduser() if config_raw else root / "singular.config.json"
        if not config.is_absolute():
            config = cwd / config
        store = MemoryStore(config.resolve(), root)
        if args.command == "propose":
            result = store.propose(args)
        elif args.command == "review":
            result = store.review(args)
        elif args.command in {"approve", "reject", "quarantine"}:
            result = store.decide(args, args.command)
        elif args.command == "supersede":
            result = store.supersede(args)
        elif args.command == "tombstone":
            result = store.tombstone(args)
        elif args.command == "show":
            result = {"schema": "singular.memory.operation.v1",
                      "memory": store.view(store.read_record(args.memory_id))}
        elif args.command == "rebuild":
            result = store.rebuild()
        elif args.checkpoint_command == "save":
            result = store.checkpoint_save(args)
        else:
            result = store.checkpoint_recover(args.task)
        json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"),
                  ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    except MemoryError as exc:
        print(f"memory service: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
