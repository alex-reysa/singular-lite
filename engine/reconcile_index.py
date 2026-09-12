#!/usr/bin/env python3
"""Discovery-only reconciliation index with bounded full scans."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Any, Iterable

INDEX_SCHEMA = "singular.orchestration.reconcile-index.v1"
PLAN_SCHEMA = "singular.orchestration.reconcile-index-plan.v1"


def _files(tasks: Path, packets: Path, leases: Path) -> list[Path]:
    found: list[Path] = []
    if tasks.is_dir():
        found.extend(path for path in tasks.rglob("TASK-*.md") if path.is_file())
    if packets.is_dir():
        found.extend(path for path in packets.rglob("*.json") if path.is_file())
    if leases.is_dir():
        found.extend(path for path in leases.glob("*.json") if path.is_file())
    return sorted(set(found), key=str)


def _key(path: Path, roots: Iterable[tuple[str, Path]]) -> str:
    for label, root in roots:
        try:
            return f"{label}/{path.relative_to(root)}"
        except ValueError:
            pass
    return str(path)


def _quick(tasks: Path, packets: Path, leases: Path) -> dict[str, list[int]]:
    roots = (("tasks", tasks), ("packets", packets), ("leases", leases))
    result: dict[str, list[int]] = {}
    for path in _files(tasks, packets, leases):
        try:
            stat = path.stat()
        except OSError:
            continue
        result[_key(path, roots)] = [
            int(stat.st_dev), int(stat.st_ino), int(stat.st_size), int(stat.st_mtime_ns)
        ]
    return result


def _content(tasks: Path, packets: Path, leases: Path) -> dict[str, str]:
    roots = (("tasks", tasks), ("packets", packets), ("leases", leases))
    result: dict[str, str] = {}
    for path in _files(tasks, packets, leases):
        try:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError:
            continue
        result[_key(path, roots)] = digest
    return result


def _count_candidates(packets: Path) -> int:
    return sum(1 for path in packets.iterdir() if path.is_dir()) if packets.is_dir() else 0


def _load(path: Path) -> tuple[dict[str, Any], str]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict) or value.get("schema") != INDEX_SCHEMA:
            raise ValueError("wrong schema")
        return value, ""
    except FileNotFoundError:
        return {}, "missing-index"
    except (OSError, json.JSONDecodeError, ValueError):
        return {}, "corrupt-index"


def _store(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f"{path.name}.tmp-{os.getpid()}")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temp, path)


def _dependencies(args: argparse.Namespace) -> dict[str, str]:
    return {"targetHead": args.target_head, "policy": args.policy, "campaign": args.campaign}


def plan(args: argparse.Namespace) -> dict[str, Any]:
    state, load_reason = _load(args.index.resolve())
    cycle = int(state.get("cycle", 0) or 0) + 1
    last_full = int(state.get("lastFullCycle", 0) or 0)
    quick = _quick(args.tasks, args.packets, args.leases)
    dependencies = _dependencies(args)
    identity_changed = bool(state) and state.get("quick") != quick
    dependency_changed = bool(state) and state.get("dependencies") != dependencies
    quick_changed = not state or identity_changed or dependency_changed
    scan = "full" if quick_changed or cycle - last_full >= args.full_scan_every else "quick"
    content = _content(args.tasks, args.packets, args.leases) if scan == "full" else None
    content_changed = bool(state) and content is not None and state.get("content") != content
    reasons = [load_reason] if load_reason else []
    if dependency_changed:
        reasons.append("dependency-identity-changed")
    if identity_changed:
        reasons.append("file-identity-changed")
    if content_changed:
        reasons.append("content-changed")
    run_canonical = bool(load_reason or quick_changed or content_changed)
    next_state = dict(state)
    next_state.update({"schema": INDEX_SCHEMA, "cycle": cycle})
    # A bounded full scan that confirms the committed discovery baseline is
    # unchanged completes the periodic scan itself. Advance its watermark so
    # the next cycle returns to stat-only discovery. Changed inputs are never
    # acknowledged here: only a successful canonical pass may commit them.
    if scan == "full" and not run_canonical:
        next_state.update({
            "lastFullCycle": cycle,
            "dependencies": dependencies,
            "quick": quick,
            "content": content,
        })
    _store(args.index.resolve(), next_state)
    return {
        "schema": PLAN_SCHEMA,
        "authority": "discovery-only",
        "runCanonical": run_canonical,
        "scan": scan,
        "cycle": cycle,
        "reasons": reasons,
        "metrics": {
            "statIdentities": len(quick),
            "contentHashes": len(content or {}),
            "expensiveHistoricalValidations": (
                _count_candidates(args.packets) if run_canonical else 0
            ),
        },
    }


def commit(args: argparse.Namespace) -> dict[str, Any]:
    state, _ = _load(args.index.resolve())
    cycle = int(state.get("cycle", 1) or 1)
    value = {
        "schema": INDEX_SCHEMA,
        "authority": "discovery-only",
        "cycle": cycle,
        "lastFullCycle": cycle,
        "dependencies": _dependencies(args),
        "quick": _quick(args.tasks, args.packets, args.leases),
        "content": _content(args.tasks, args.packets, args.leases),
    }
    _store(args.index.resolve(), value)
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("plan", "commit"))
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--tasks", type=Path, required=True)
    parser.add_argument("--packets", type=Path, required=True)
    parser.add_argument("--leases", type=Path, required=True)
    parser.add_argument("--target-head", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--campaign", required=True)
    parser.add_argument("--full-scan-every", type=int, default=20)
    args = parser.parse_args()
    if args.full_scan_every < 1:
        parser.error("--full-scan-every must be at least 1")
    return args


def main() -> None:
    args = parse_args()
    value = plan(args) if args.action == "plan" else commit(args)
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
