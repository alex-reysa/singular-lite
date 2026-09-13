#!/usr/bin/env python3
"""Programmable review policy: classify, bound, record, and grant exceptions.

Stdlib only. Importable as a module and runnable as
`python3 engine/review_policy.py <verb> ...`.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

LEDGER_SCHEMA = "singular.review-policy.ledger.v1"
POLICY_VERSION = 1
# Two total rounds: the initial review plus at most one follow-up. The L1
# driver bounds product repairs to maxReviewRounds - 1, so high-risk tasks are
# also capped here unless a project raises maxReviewRounds explicitly.
DEFAULT_MAX_REVIEW_ROUNDS = 2
DEFAULT_BLOCKING = ["P0", "P1"]
SEVERITIES = ("P0", "P1", "P2", "P3")
VERDICTS = ("accepted", "needs-fix", "blocked", "needs-human")
LANES = ("native", "maintenance", "consultant")
ROUND_KINDS = ("initial", "followup")

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_LEDGER = 3
EXIT_EXHAUSTED = 4


class PolicyError(Exception):
    """Invalid configuration, usage, or arguments (exit 2)."""


class LedgerError(Exception):
    """Ledger or filesystem I/O failure (exit 3)."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def _nonblank(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _as_str(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _dump(obj: Any) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def _print_json(obj: Any) -> None:
    sys.stdout.write(_dump(obj))


def logical_change_id(task_id: str | None, dag_node: str | None) -> str:
    """dagNode if non-empty, else taskId. Maintenance ids are supplied explicitly."""
    node = (dag_node or "").strip()
    if node:
        return node
    return (task_id or "").strip()


def _parse_bool_env(raw: str, name: str) -> bool:
    if raw == "1":
        return True
    if raw == "0":
        return False
    raise PolicyError(f"{name} must be 0 or 1, got {raw!r}")


def _parse_int_ge(raw: str, name: str, minimum: int) -> int:
    if not re.fullmatch(r"[+-]?[0-9]+", raw.strip()):
        raise PolicyError(f"{name} must be an integer >= {minimum}, got {raw!r}")
    value = int(raw)
    if value < minimum:
        raise PolicyError(f"{name} must be an integer >= {minimum}, got {raw!r}")
    return value


def _parse_severities(raw: Any, name: str) -> list[str]:
    if isinstance(raw, str):
        parts = [part.strip() for part in raw.split(",")]
        parts = [part for part in parts if part]
        if not parts:
            raise PolicyError(f"{name} must be a comma list from {', '.join(SEVERITIES)}")
    elif isinstance(raw, list):
        parts = []
        for item in raw:
            if not isinstance(item, str):
                raise PolicyError(f"{name} items must be strings")
            token = item.strip()
            if token:
                parts.append(token)
    else:
        raise PolicyError(f"{name} must be a list of severities")
    seen: set[str] = set()
    out: list[str] = []
    for part in parts:
        if part not in SEVERITIES:
            raise PolicyError(
                f"{name} contains invalid severity {part!r}; "
                f"allowed: {', '.join(SEVERITIES)}"
            )
        if part not in seen:
            seen.add(part)
            out.append(part)
    return out


def _apply_json_policy(policy: dict[str, Any], sources: dict[str, str], blob: Any, source: str) -> None:
    if not isinstance(blob, dict):
        raise PolicyError("reviewPolicy must be a JSON object")
    if "version" in blob:
        version = blob["version"]
        if not isinstance(version, int) or isinstance(version, bool) or version != POLICY_VERSION:
            raise PolicyError(f"reviewPolicy.version must be {POLICY_VERSION}, got {version!r}")
        policy["version"] = version
        sources["version"] = source
    if "maxReviewRounds" in blob:
        value = blob["maxReviewRounds"]
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise PolicyError(
                f"reviewPolicy.maxReviewRounds must be an integer >= 1, got {value!r}"
            )
        policy["maxReviewRounds"] = value
        sources["maxReviewRounds"] = source
    if "blockingSeverities" in blob:
        policy["blockingSeverities"] = _parse_severities(
            blob["blockingSeverities"], "reviewPolicy.blockingSeverities"
        )
        sources["blockingSeverities"] = source
    if "requireClassification" in blob:
        flag = blob["requireClassification"]
        if not isinstance(flag, bool):
            raise PolicyError(
                "reviewPolicy.requireClassification must be a boolean, "
                f"got {flag!r}"
            )
        policy["requireClassification"] = flag
        sources["requireClassification"] = source


def load_policy(env: dict[str, str] | None = None, config_path: str | None = None) -> dict[str, Any]:
    """Resolve review policy. Env field overrides win over JSON; defaults last.

    Invalid values are a hard error, never silently defaulted.
    """
    env = dict(os.environ if env is None else env)
    policy: dict[str, Any] = {
        "version": POLICY_VERSION,
        "maxReviewRounds": DEFAULT_MAX_REVIEW_ROUNDS,
        "blockingSeverities": list(DEFAULT_BLOCKING),
        "requireClassification": True,
    }
    sources = {
        "version": "default",
        "maxReviewRounds": "default",
        "blockingSeverities": "default",
        "requireClassification": "default",
    }

    json_blob = None
    json_source = "config"
    raw_json = env.get("SINGULAR_REVIEW_POLICY_JSON")
    if raw_json is not None and raw_json != "":
        try:
            json_blob = json.loads(raw_json)
        except json.JSONDecodeError as exc:
            raise PolicyError(f"invalid SINGULAR_REVIEW_POLICY_JSON: {exc}") from exc
        json_source = "config"
    elif config_path:
        path = Path(config_path)
        if path.is_file():
            try:
                cfg = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise PolicyError(f"invalid review policy config {config_path}: {exc}") from exc
            if isinstance(cfg, dict) and "reviewPolicy" in cfg:
                json_blob = cfg.get("reviewPolicy")
                json_source = "config"

    if json_blob is not None:
        _apply_json_policy(policy, sources, json_blob, json_source)

    if "SINGULAR_REVIEW_MAX_ROUNDS" in env and env["SINGULAR_REVIEW_MAX_ROUNDS"] != "":
        policy["maxReviewRounds"] = _parse_int_ge(
            env["SINGULAR_REVIEW_MAX_ROUNDS"], "SINGULAR_REVIEW_MAX_ROUNDS", 1
        )
        sources["maxReviewRounds"] = "env"
    if "SINGULAR_REVIEW_BLOCKING_SEVERITIES" in env and env["SINGULAR_REVIEW_BLOCKING_SEVERITIES"] != "":
        policy["blockingSeverities"] = _parse_severities(
            env["SINGULAR_REVIEW_BLOCKING_SEVERITIES"],
            "SINGULAR_REVIEW_BLOCKING_SEVERITIES",
        )
        sources["blockingSeverities"] = "env"
    if "SINGULAR_REVIEW_REQUIRE_CLASSIFICATION" in env and env["SINGULAR_REVIEW_REQUIRE_CLASSIFICATION"] != "":
        policy["requireClassification"] = _parse_bool_env(
            env["SINGULAR_REVIEW_REQUIRE_CLASSIFICATION"],
            "SINGULAR_REVIEW_REQUIRE_CLASSIFICATION",
        )
        sources["requireClassification"] = "env"

    # Empty-but-present env vars are invalid, never a silent default.
    for name in (
        "SINGULAR_REVIEW_MAX_ROUNDS",
        "SINGULAR_REVIEW_BLOCKING_SEVERITIES",
        "SINGULAR_REVIEW_REQUIRE_CLASSIFICATION",
    ):
        if name in env and env[name] == "":
            raise PolicyError(f"{name} is empty; omit it to use JSON/defaults")

    out = dict(policy)
    out["sources"] = sources
    return out


def _classified_items(verdict: dict[str, Any]) -> list[dict[str, Any]]:
    raw = verdict.get("classifiedFindings")
    if not isinstance(raw, list):
        return []
    items = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        ident = _as_str(entry.get("id")).strip()
        severity = _as_str(entry.get("severity")).strip()
        summary = _as_str(entry.get("summary"))
        if not ident or severity not in SEVERITIES or not summary.strip():
            continue
        item = {
            "id": ident,
            "severity": severity,
            "summary": summary,
        }
        for key in ("trigger", "impact", "requirement", "location"):
            if key in entry and entry[key] is not None:
                item[key] = _as_str(entry[key])
        items.append(item)
    return items


def _finding_strings(verdict: dict[str, Any]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for key in ("findings", "requiredFixes"):
        raw = verdict.get(key)
        if not isinstance(raw, list):
            continue
        for item in raw:
            text = _as_str(item).strip()
            if not text or text in seen:
                continue
            seen.add(text)
            out.append(text)
    return out


def classify(verdict: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    """Apply severity/classification rules. Never mutates the input verdict."""
    original = _as_str(verdict.get("verdict"))
    blocking_severities = set(policy.get("blockingSeverities") or DEFAULT_BLOCKING)
    require_classification = bool(policy.get("requireClassification", True))

    result: dict[str, Any] = {
        "originalVerdict": original,
        "effectiveVerdict": original,
        "applied": False,
        "blocking": [],
        "backlog": [],
        "downgraded": [],
        "unclassifiedCount": 0,
        "reason": None,
        "items": [],
    }

    if original != "needs-fix":
        # Informational only: do not change the verdict.
        items = _classified_items(verdict)
        result["items"] = items
        result["backlog"] = [item["id"] for item in items]
        return result

    items = _classified_items(verdict)
    if not items:
        if not require_classification:
            result["effectiveVerdict"] = original
            return result
        strings = _finding_strings(verdict)
        unclassified = []
        for index, text in enumerate(strings, start=1):
            ident = f"unclassified-{index}"
            unclassified.append(
                {
                    "id": ident,
                    "severity": "unclassified",
                    "summary": text,
                }
            )
        if not unclassified:
            unclassified.append(
                {
                    "id": "unclassified-1",
                    "severity": "unclassified",
                    "summary": "unclassified finding",
                }
            )
        result["items"] = unclassified
        result["blocking"] = [item["id"] for item in unclassified]
        result["unclassifiedCount"] = len(unclassified)
        result["reason"] = "classification-missing"
        result["effectiveVerdict"] = "needs-fix"
        return result

    blocking: list[str] = []
    backlog: list[str] = []
    downgraded: list[str] = []
    processed: list[dict[str, Any]] = []
    for item in items:
        copy = dict(item)
        severity = copy["severity"]
        if severity in {"P0", "P1"}:
            supported = all(_nonblank(copy.get(key, "")) for key in ("trigger", "impact", "requirement"))
            if not supported:
                copy["severity"] = "P2"
                copy["downgradeReason"] = "unsupported-blocking-claim"
                downgraded.append(copy["id"])
                severity = "P2"
        if severity in blocking_severities:
            blocking.append(copy["id"])
        else:
            backlog.append(copy["id"])
        processed.append(copy)

    result["items"] = processed
    result["blocking"] = blocking
    result["backlog"] = backlog
    result["downgraded"] = downgraded
    if downgraded:
        result["reason"] = "unsupported-blocking-claim"
    if not blocking:
        result["effectiveVerdict"] = "accepted"
        result["applied"] = True
    else:
        result["effectiveVerdict"] = "needs-fix"
        result["applied"] = False
    return result


def empty_ledger() -> dict[str, Any]:
    return {
        "schema": LEDGER_SCHEMA,
        "updatedAt": _utc_now(),
        "logicalChanges": {},
    }


def _load_ledger_unlocked(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return empty_ledger()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LedgerError(f"invalid review-policy ledger {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise LedgerError(f"review-policy ledger {path} is not an object")
    data.setdefault("schema", LEDGER_SCHEMA)
    data.setdefault("logicalChanges", {})
    if not isinstance(data["logicalChanges"], dict):
        raise LedgerError(f"review-policy ledger {path} logicalChanges is not an object")
    return data


def _atomic_write(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


@contextmanager
def locked_ledger(state_dir: Path) -> Iterator[dict[str, Any]]:
    policy_dir = state_dir / "review-policy"
    try:
        policy_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise LedgerError(f"cannot create review-policy state dir: {exc}") from exc
    ledger_path = policy_dir / "ledger.json"
    lock_path = policy_dir / "ledger.lock"
    try:
        lock = lock_path.open("a+", encoding="utf-8")
    except OSError as exc:
        raise LedgerError(f"cannot open review-policy ledger lock: {exc}") from exc
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        ledger = _load_ledger_unlocked(ledger_path)
        yield ledger
        ledger["updatedAt"] = _utc_now()
        ledger["schema"] = LEDGER_SCHEMA
        try:
            _atomic_write(ledger_path, ledger)
        except OSError as exc:
            raise LedgerError(f"cannot write review-policy ledger: {exc}") from exc
    finally:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        lock.close()


def _change_entry(ledger: dict[str, Any], logical_change: str) -> dict[str, Any]:
    changes = ledger.setdefault("logicalChanges", {})
    entry = changes.get(logical_change)
    if not isinstance(entry, dict):
        entry = {"status": "open", "rounds": [], "exceptions": []}
        changes[logical_change] = entry
    entry.setdefault("status", "open")
    entry.setdefault("rounds", [])
    entry.setdefault("exceptions", [])
    if not isinstance(entry["rounds"], list):
        entry["rounds"] = []
    if not isinstance(entry["exceptions"], list):
        entry["exceptions"] = []
    return entry


def _exception_active(exc: dict[str, Any], used: int, max_rounds: int) -> bool:
    extra = exc.get("additionalRounds")
    if not isinstance(extra, int) or isinstance(extra, bool) or extra < 1:
        return False
    # Unconsumed while the extra budget has not yet been spent.
    return used < (max_rounds + extra)


def _exception_matches_task(exc: dict[str, Any], task_id: str | None) -> bool:
    bound = exc.get("taskId", None)
    if bound is None or bound == "":
        return True
    return _as_str(bound) == _as_str(task_id)


def _open_round_count(entry: dict[str, Any]) -> int:
    """Rounds that count toward the current candidate.

    An accepted verdict closes that candidate, so a later dispatch of the same
    logical change (new run/candidate) starts a fresh budget. Unaccepted rounds
    after the last acceptance — including historical backfill — still count.
    """
    used = 0
    for item in entry.get("rounds") or []:
        if not isinstance(item, dict):
            continue
        if item.get("effectiveVerdict") == "accepted":
            used = 0
        else:
            used += 1
    return used


def allowed_rounds(entry: dict[str, Any], task_id: str | None, policy: dict[str, Any]) -> tuple[int, int]:
    used = _open_round_count(entry)
    max_rounds = int(policy["maxReviewRounds"])
    extra = 0
    for exc in entry.get("exceptions", []):
        if not isinstance(exc, dict):
            continue
        if not _exception_matches_task(exc, task_id):
            continue
        if not _exception_active(exc, used, max_rounds):
            continue
        add = exc.get("additionalRounds")
        if isinstance(add, int) and not isinstance(add, bool) and add > 0:
            extra += add
    return used, max_rounds + extra


def check(
    ledger: dict[str, Any],
    logical_change: str,
    task_id: str,
    policy: dict[str, Any],
) -> dict[str, Any]:
    """Refuse when rounds used >= allowed. Does not mutate the ledger."""
    changes = ledger.get("logicalChanges") if isinstance(ledger, dict) else {}
    if not isinstance(changes, dict):
        changes = {}
    entry = changes.get(logical_change) if logical_change in changes else None
    if not isinstance(entry, dict):
        entry = {"status": "open", "rounds": [], "exceptions": []}
    used, allowed = allowed_rounds(entry, task_id, policy)
    if used >= allowed:
        return {
            "allowed": False,
            "used": used,
            "allowedRounds": allowed,
            "reason": (
                f"review rounds exhausted for {logical_change} "
                f"({used}/{allowed})"
            ),
            "logicalChange": logical_change,
            "status": entry.get("status") or "exhausted",
        }
    return {
        "allowed": True,
        "used": used,
        "allowedRounds": allowed,
        "reason": "ok",
        "logicalChange": logical_change,
        "status": entry.get("status") or "open",
    }


def _item_by_id(classification: dict[str, Any], ident: str) -> dict[str, Any] | None:
    for item in classification.get("items") or []:
        if isinstance(item, dict) and item.get("id") == ident:
            return item
    return None


def _append_backlog(
    state_dir: Path,
    logical_change: str,
    task_id: str,
    run_id: str,
    round_no: int,
    classification: dict[str, Any],
    recorded_at: str,
) -> None:
    ids = classification.get("backlog") or []
    if not ids:
        return
    path = state_dir / "review-policy" / "backlog.ndjson"
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("a", encoding="utf-8") as handle:
            for ident in ids:
                item = _item_by_id(classification, ident) or {"id": ident}
                line = {
                    "logicalChange": logical_change,
                    "taskId": task_id,
                    "runId": run_id,
                    "round": round_no,
                    "id": item.get("id", ident),
                    "severity": item.get("severity", ""),
                    "summary": item.get("summary", ""),
                    "recordedAt": recorded_at,
                }
                for key in ("trigger", "impact", "requirement", "location"):
                    if item.get(key):
                        line[key] = item[key]
                handle.write(json.dumps(line, ensure_ascii=False) + "\n")
    except OSError as exc:
        raise LedgerError(f"cannot append review-policy backlog: {exc}") from exc


def _refresh_status(entry: dict[str, Any], policy: dict[str, Any], task_id: str | None) -> None:
    rounds = [item for item in entry.get("rounds", []) if isinstance(item, dict)]
    if rounds and _as_str(rounds[-1].get("effectiveVerdict")) == "accepted":
        entry["status"] = "accepted"
        return
    used, allowed = allowed_rounds(entry, task_id, policy)
    if used >= allowed:
        entry["status"] = "exhausted"
    else:
        entry["status"] = "open"


def record(
    ledger: dict[str, Any],
    logical_change: str,
    task_id: str,
    run_id: str,
    attempt: int,
    verdict: dict[str, Any],
    policy: dict[str, Any],
    *,
    head: str = "",
    campaign_binding: str = "",
    lane: str = "native",
    reviewer: dict[str, str] | None = None,
    historical: bool = False,
    recorded_at: str | None = None,
    state_dir: Path | None = None,
) -> dict[str, Any]:
    """Append one completed schema-valid round. Transport failures never call this."""
    if lane not in LANES:
        raise PolicyError(f"lane must be one of {', '.join(LANES)}, got {lane!r}")
    classification = classify(verdict, policy)
    entry = _change_entry(ledger, logical_change)
    round_no = len([item for item in entry["rounds"] if isinstance(item, dict)]) + 1
    kind = "initial" if round_no == 1 else "followup"
    stamp = recorded_at or _utc_now()
    reviewer = reviewer or {}
    round_row = {
        "round": round_no,
        "kind": kind,
        "taskId": task_id,
        "runId": run_id,
        "attempt": int(attempt),
        "head": head,
        "campaignBinding": campaign_binding,
        "lane": lane,
        "reviewer": {
            "runner": _as_str(reviewer.get("runner")),
            "model": _as_str(reviewer.get("model")),
            "effort": _as_str(reviewer.get("effort")),
        },
        "originalVerdict": classification["originalVerdict"],
        "effectiveVerdict": classification["effectiveVerdict"],
        "blocking": list(classification["blocking"]),
        "backlog": list(classification["backlog"]),
        "downgraded": list(classification["downgraded"]),
        "unclassifiedCount": int(classification["unclassifiedCount"]),
        "recordedAt": stamp,
        "historical": bool(historical),
    }
    if classification.get("reason"):
        round_row["reason"] = classification["reason"]
    entry["rounds"].append(round_row)
    _refresh_status(entry, policy, task_id)
    if state_dir is not None:
        _append_backlog(
            state_dir, logical_change, task_id, run_id, round_no, classification, stamp
        )
    used, allowed = allowed_rounds(entry, task_id, policy)
    out = dict(classification)
    out.update(
        {
            "logicalChange": logical_change,
            "round": round_no,
            "kind": kind,
            "maxRounds": int(policy["maxReviewRounds"]),
            "allowedRounds": allowed,
            "used": used,
            "status": entry["status"],
            "recordedAt": stamp,
            "historical": bool(historical),
        }
    )
    return out


def apply_to_verdict(
    verdict_path: str | Path,
    classification: dict[str, Any],
    round_info: dict[str, Any],
) -> dict[str, Any]:
    """Rewrite the verdict's effective field and stamp a top-level reviewPolicy object."""
    path = Path(verdict_path)
    try:
        original = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LedgerError(f"cannot read verdict {path}: {exc}") from exc
    if not isinstance(original, dict):
        raise LedgerError(f"verdict {path} is not a JSON object")

    effective = classification.get("effectiveVerdict") or original.get("verdict")
    policy_obj = {
        "version": int(round_info.get("version") or POLICY_VERSION),
        "logicalChange": _as_str(round_info.get("logicalChange")),
        "round": int(round_info.get("round") or 0),
        "maxRounds": int(round_info.get("maxRounds") or 0),
        "originalVerdict": classification.get("originalVerdict") or original.get("verdict"),
        "effectiveVerdict": effective,
        "blocking": list(classification.get("blocking") or []),
        "backlog": list(classification.get("backlog") or []),
        "downgraded": list(classification.get("downgraded") or []),
        "unclassifiedCount": int(classification.get("unclassifiedCount") or 0),
        "appliedAt": _utc_now(),
    }
    # The host stamp is a member of audit-verdict.v1 only. Legacy v0 schemas
    # forbid unknown members, so a v0 verdict receives the effective verdict
    # and the pre-policy copy, while the round record carries the details.
    stamp = _as_str(original.get("schema")) == "singular.orchestration.audit-verdict.v1"
    changed = original.get("verdict") != effective or (
        stamp and original.get("reviewPolicy") != policy_obj
    )
    if changed:
        pre = Path(str(path) + ".pre-policy.json")
        try:
            _atomic_write(pre, original)
        except OSError as exc:
            raise LedgerError(f"cannot write {pre}: {exc}") from exc
    rewritten = dict(original)
    rewritten["verdict"] = effective
    if stamp:
        rewritten["reviewPolicy"] = policy_obj
    elif not changed:
        return original
    try:
        _atomic_write(path, rewritten)
    except OSError as exc:
        raise LedgerError(f"cannot write verdict {path}: {exc}") from exc
    return rewritten


def grant(
    ledger: dict[str, Any],
    logical_change: str,
    additional_rounds: int,
    reason: str,
    evidence: list[str],
    policy: dict[str, Any],
    *,
    task_id: str | None = None,
    authority: str = "",
) -> dict[str, Any]:
    if not isinstance(additional_rounds, int) or isinstance(additional_rounds, bool) or additional_rounds < 1:
        raise PolicyError("additional rounds must be an integer >= 1")
    max_rounds = int(policy["maxReviewRounds"])
    if additional_rounds > max_rounds:
        raise PolicyError(
            f"additionalRounds {additional_rounds} exceeds maxReviewRounds {max_rounds}"
        )
    if not _nonblank(reason):
        raise PolicyError("grant requires a non-blank reason")
    if not _nonblank(authority):
        raise PolicyError("grant requires --authority")
    if not evidence:
        raise PolicyError("grant requires at least one --evidence path")

    entry = _change_entry(ledger, logical_change)
    used, _allowed = allowed_rounds(entry, task_id, policy)
    for exc in entry["exceptions"]:
        if not isinstance(exc, dict):
            continue
        if not _exception_matches_task(exc, task_id):
            continue
        if _exception_active(exc, used, max_rounds):
            raise PolicyError(
                f"an active (unconsumed) exception already exists for {logical_change}: "
                f"{exc.get('id')}"
            )

    hashed = []
    for raw in evidence:
        path = Path(raw)
        if not path.is_file():
            raise PolicyError(f"evidence path is missing or not a file: {raw}")
        try:
            digest = sha256_file(path)
        except OSError as exc:
            raise LedgerError(f"cannot hash evidence {raw}: {exc}") from exc
        hashed.append({"path": str(path), "sha256": digest})

    stamp = _utc_now()
    ident = "exc-" + hashlib.sha256(
        f"{logical_change}|{stamp}|{reason}|{authority}".encode()
    ).hexdigest()[:12]
    row = {
        "id": ident,
        "grantedAt": stamp,
        "additionalRounds": additional_rounds,
        "reason": reason,
        "evidence": hashed,
        "taskId": task_id if task_id else None,
        "authority": authority,
    }
    entry["exceptions"].append(row)
    _refresh_status(entry, policy, task_id)
    used, allowed = allowed_rounds(entry, task_id, policy)
    return {
        "exception": row,
        "logicalChange": logical_change,
        "used": used,
        "allowedRounds": allowed,
        "status": entry["status"],
    }


def _coerce_round(raw: dict[str, Any], index: int) -> dict[str, Any]:
    round_no = raw.get("round", index)
    try:
        round_no = int(round_no)
    except (TypeError, ValueError) as exc:
        raise PolicyError(f"backfill round number is invalid: {raw.get('round')!r}") from exc
    kind = raw.get("kind") or ("initial" if round_no == 1 else "followup")
    if kind not in ROUND_KINDS:
        raise PolicyError(f"backfill round kind must be initial or followup, got {kind!r}")
    reviewer = raw.get("reviewer") if isinstance(raw.get("reviewer"), dict) else {}
    return {
        "round": round_no,
        "kind": kind,
        "taskId": _as_str(raw.get("taskId")),
        "runId": _as_str(raw.get("runId")),
        "attempt": int(raw.get("attempt") or round_no),
        "head": _as_str(raw.get("head")),
        "campaignBinding": _as_str(raw.get("campaignBinding")),
        "lane": raw.get("lane") if raw.get("lane") in LANES else "native",
        "reviewer": {
            "runner": _as_str(reviewer.get("runner")),
            "model": _as_str(reviewer.get("model")),
            "effort": _as_str(reviewer.get("effort")),
        },
        "originalVerdict": _as_str(raw.get("originalVerdict") or raw.get("verdict") or "needs-fix"),
        "effectiveVerdict": _as_str(raw.get("effectiveVerdict") or raw.get("verdict") or "needs-fix"),
        "blocking": [str(x) for x in (raw.get("blocking") or [])],
        "backlog": [str(x) for x in (raw.get("backlog") or [])],
        "downgraded": [str(x) for x in (raw.get("downgraded") or [])],
        "unclassifiedCount": int(raw.get("unclassifiedCount") or 0),
        "recordedAt": _as_str(raw.get("recordedAt") or _utc_now()),
        "historical": True,
    }


def backfill(ledger: dict[str, Any], entries: list[dict[str, Any]], policy: dict[str, Any]) -> dict[str, Any]:
    """Add historical rounds/exceptions. Historical rounds count toward used."""
    added_rounds = 0
    added_exceptions = 0
    for item in entries:
        if not isinstance(item, dict):
            raise PolicyError("backfill entries must be objects")
        logical_change = _as_str(item.get("logicalChange")).strip()
        if not logical_change:
            raise PolicyError("backfill entry requires logicalChange")
        entry = _change_entry(ledger, logical_change)
        for raw_round in item.get("rounds") or []:
            if not isinstance(raw_round, dict):
                raise PolicyError("backfill rounds must be objects")
            entry["rounds"].append(_coerce_round(raw_round, len(entry["rounds"]) + 1))
            added_rounds += 1
        for raw_exc in item.get("exceptions") or []:
            if not isinstance(raw_exc, dict):
                raise PolicyError("backfill exceptions must be objects")
            extra = raw_exc.get("additionalRounds")
            if not isinstance(extra, int) or isinstance(extra, bool) or extra < 1:
                raise PolicyError("backfill exception additionalRounds must be an integer >= 1")
            evidence = raw_exc.get("evidence") or []
            if not isinstance(evidence, list):
                evidence = []
            entry["exceptions"].append(
                {
                    "id": _as_str(raw_exc.get("id")) or f"exc-historical-{len(entry['exceptions']) + 1}",
                    "grantedAt": _as_str(raw_exc.get("grantedAt") or _utc_now()),
                    "additionalRounds": extra,
                    "reason": _as_str(raw_exc.get("reason")),
                    "evidence": evidence,
                    "taskId": raw_exc.get("taskId", None),
                    "authority": _as_str(raw_exc.get("authority")),
                    "historical": True,
                }
            )
            added_exceptions += 1
        task_hint = None
        rounds = [row for row in entry["rounds"] if isinstance(row, dict)]
        if rounds:
            task_hint = rounds[-1].get("taskId")
        _refresh_status(entry, policy, task_hint)
    return {
        "addedRounds": added_rounds,
        "addedExceptions": added_exceptions,
        "updatedAt": _utc_now(),
    }


def _read_backlog(state_dir: Path, logical_change: str | None) -> list[dict[str, Any]]:
    path = state_dir / "review-policy" / "backlog.ndjson"
    if not path.is_file():
        return []
    rows = []
    try:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                if logical_change and row.get("logicalChange") != logical_change:
                    continue
                rows.append(row)
    except OSError as exc:
        raise LedgerError(f"cannot read review-policy backlog: {exc}") from exc
    return rows


def _resolve_root(ns: argparse.Namespace) -> Path:
    root = os.environ.get("SINGULAR_ROOT") or os.getcwd()
    return Path(root)


def _resolve_config(ns: argparse.Namespace) -> str | None:
    if getattr(ns, "config", None):
        return ns.config
    env = os.environ.get("SINGULAR_JSON_CONFIG_FILE")
    if env:
        return env
    candidate = _resolve_root(ns) / "singular.config.json"
    return str(candidate)


def _resolve_state_dir(ns: argparse.Namespace) -> Path:
    if getattr(ns, "state_dir", None):
        return Path(ns.state_dir)
    env = os.environ.get("SINGULAR_STATE_DIR")
    if env:
        return Path(env)
    return _resolve_root(ns) / ".singular-state"


def _load_verdict(path: str) -> dict[str, Any]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LedgerError(f"cannot read verdict {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise LedgerError(f"verdict {path} is not a JSON object")
    return data


def _cmd_effective(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    _print_json(policy)
    return EXIT_OK


def _cmd_show(ns: argparse.Namespace) -> int:
    state_dir = _resolve_state_dir(ns)
    path = state_dir / "review-policy" / "ledger.json"
    ledger = _load_ledger_unlocked(path) if path.is_file() else empty_ledger()
    if ns.logical_change:
        entry = (ledger.get("logicalChanges") or {}).get(ns.logical_change)
        _print_json(
            {
                "logicalChange": ns.logical_change,
                "entry": entry if isinstance(entry, dict) else None,
            }
        )
        return EXIT_OK
    _print_json(ledger)
    return EXIT_OK


def _cmd_check(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    state_dir = _resolve_state_dir(ns)
    path = state_dir / "review-policy" / "ledger.json"
    # Take the lock so a concurrent record cannot race the decision.
    with locked_ledger(state_dir) as ledger:
        result = check(ledger, ns.logical_change, ns.task, policy)
    _print_json(result)
    return EXIT_OK if result["allowed"] else EXIT_EXHAUSTED


def _cmd_record(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    state_dir = _resolve_state_dir(ns)
    verdict = _load_verdict(ns.verdict)
    reviewer = {
        "runner": ns.reviewer_runner or "",
        "model": ns.reviewer_model or "",
        "effort": ns.reviewer_effort or "",
    }
    with locked_ledger(state_dir) as ledger:
        result = record(
            ledger,
            ns.logical_change,
            ns.task,
            ns.run,
            ns.attempt,
            verdict,
            policy,
            head=ns.head or "",
            campaign_binding=ns.campaign or "",
            lane=ns.lane,
            reviewer=reviewer,
            state_dir=state_dir,
        )
        if ns.apply:
            apply_to_verdict(
                ns.verdict,
                result,
                {
                    "version": policy["version"],
                    "logicalChange": ns.logical_change,
                    "round": result["round"],
                    "maxRounds": policy["maxReviewRounds"],
                },
            )
            result["appliedToVerdict"] = True
        else:
            result["appliedToVerdict"] = False
    _print_json(result)
    return EXIT_OK


def _cmd_grant(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    state_dir = _resolve_state_dir(ns)
    with locked_ledger(state_dir) as ledger:
        result = grant(
            ledger,
            ns.logical_change,
            ns.rounds,
            ns.reason,
            list(ns.evidence or []),
            policy,
            task_id=ns.task,
            authority=ns.authority,
        )
    _print_json(result)
    return EXIT_OK


def _normalize_backfill_payload(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        if "entries" in payload and isinstance(payload["entries"], list):
            return payload["entries"]
        if "logicalChange" in payload:
            return [payload]
        if "logicalChanges" in payload and isinstance(payload["logicalChanges"], dict):
            entries = []
            for ident, body in payload["logicalChanges"].items():
                if not isinstance(body, dict):
                    continue
                item = dict(body)
                item["logicalChange"] = ident
                entries.append(item)
            return entries
    raise PolicyError("backfill file must be an object or array of logical-change entries")


def _cmd_backfill(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    try:
        payload = json.loads(Path(ns.file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LedgerError(f"cannot read backfill file {ns.file}: {exc}") from exc
    entries = _normalize_backfill_payload(payload)
    state_dir = _resolve_state_dir(ns)
    with locked_ledger(state_dir) as ledger:
        result = backfill(ledger, entries, policy)
    _print_json(result)
    return EXIT_OK


def _cmd_backlog(ns: argparse.Namespace) -> int:
    rows = _read_backlog(_resolve_state_dir(ns), ns.logical_change)
    _print_json({"backlog": rows, "count": len(rows)})
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="singular review-policy",
        description="Programmable review policy: classify findings, bound rounds, grant exceptions.",
    )
    parser.add_argument("--config", help="singular.config.json path")
    parser.add_argument("--state-dir", help="state directory (default: $SINGULAR_STATE_DIR)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("effective", help="print effective policy with sources")

    show = sub.add_parser("show", help="print the ledger or one logical change")
    show.add_argument("--logical-change")

    chk = sub.add_parser("check", help="whether another review round is allowed")
    chk.add_argument("--logical-change", required=True)
    chk.add_argument("--task", required=True)

    rec = sub.add_parser("record", help="record a completed schema-valid verdict")
    rec.add_argument("--logical-change", required=True)
    rec.add_argument("--task", required=True)
    rec.add_argument("--run", required=True)
    rec.add_argument("--attempt", required=True, type=int)
    rec.add_argument("--verdict", required=True)
    rec.add_argument("--head", required=True)
    rec.add_argument("--campaign", default="")
    rec.add_argument("--lane", default="native", choices=LANES)
    rec.add_argument("--reviewer-runner", default="")
    rec.add_argument("--reviewer-model", default="")
    rec.add_argument("--reviewer-effort", default="")
    rec.add_argument("--apply", action="store_true", help="rewrite the verdict file")

    gnt = sub.add_parser("grant", help="grant additional review rounds")
    gnt.add_argument("--logical-change", required=True)
    gnt.add_argument("--rounds", required=True, type=int)
    gnt.add_argument("--reason", required=True)
    gnt.add_argument("--evidence", nargs="+", required=True)
    gnt.add_argument("--task")
    gnt.add_argument("--authority", required=True)

    bf = sub.add_parser("backfill", help="add historical rounds/exceptions")
    bf.add_argument("--file", required=True)

    bl = sub.add_parser("backlog", help="print non-blocking backlog items")
    bl.add_argument("--logical-change")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        ns = parser.parse_args(argv)
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else EXIT_USAGE
        return EXIT_USAGE if code else EXIT_OK

    handlers: dict[str, Callable[[argparse.Namespace], int]] = {
        "effective": _cmd_effective,
        "show": _cmd_show,
        "check": _cmd_check,
        "record": _cmd_record,
        "grant": _cmd_grant,
        "backfill": _cmd_backfill,
        "backlog": _cmd_backlog,
    }
    try:
        return handlers[ns.command](ns)
    except PolicyError as exc:
        print(f"review-policy: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except LedgerError as exc:
        print(f"review-policy: {exc}", file=sys.stderr)
        return EXIT_LEDGER
    except OSError as exc:
        print(f"review-policy: {exc}", file=sys.stderr)
        return EXIT_LEDGER


if __name__ == "__main__":
    sys.exit(main())
