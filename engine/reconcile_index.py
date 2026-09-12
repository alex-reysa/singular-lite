#!/usr/bin/env python3
"""Discovery-only reconciliation index with bounded full scans."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
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


def _accepted_candidates(packets: Path) -> list[dict[str, str]]:
    """Return the same newest accepted packet identity integrate.sh considers."""
    candidates: list[dict[str, str]] = []
    if not packets.is_dir():
        return candidates
    for task_dir in sorted((path for path in packets.iterdir() if path.is_dir()), key=str):
        packet_paths = sorted(
            path
            for path in task_dir.glob("*.json")
            if path.is_file() and not path.name.endswith(".audit.json")
        )
        if not packet_paths:
            continue
        packet_path = packet_paths[-1]
        try:
            packet = json.loads(packet_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(packet, dict) or packet.get("status") != "accepted":
            continue
        branch = packet.get("branch")
        head = packet.get("headSha")
        if not isinstance(branch, str) or not isinstance(head, str):
            continue
        candidates.append({
            "packet": str(packet_path.relative_to(packets)),
            "taskId": str(packet.get("taskId", task_dir.name)),
            "branch": branch,
            "auditedHead": head,
        })
    return candidates


def _git_output(repo: Path, args: list[str], input_text: str | None = None) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
    ).stdout


def _git_dependencies(repo: Path, packets: Path) -> list[dict[str, Any]]:
    """Resolve candidate refs and objects in two bounded, packed-ref-aware calls."""
    candidates = _accepted_candidates(packets)
    if not candidates:
        return []
    try:
        refs = {}
        for line in _git_output(repo, ["for-each-ref", "--format=%(refname)%09%(objectname)"]).splitlines():
            ref, separator, object_name = line.partition("\t")
            if separator:
                refs[ref] = object_name

        expressions: list[str] = []
        for candidate in candidates:
            expressions.extend((
                f'{candidate["auditedHead"]}^{{commit}}',
                f'{candidate["auditedHead"]}^{{tree}}',
            ))
        object_lines = _git_output(
            repo,
            ["cat-file", "--batch-check=%(objectname) %(objecttype)"],
            "\n".join(expressions) + "\n",
        ).splitlines()
    except (OSError, subprocess.CalledProcessError):
        return [{**candidate, "gitQuery": "unavailable"} for candidate in candidates]

    for offset, candidate in enumerate(candidates):
        branch = candidate["branch"]
        branch_names = (
            branch,
            f"refs/heads/{branch}",
            f"refs/remotes/{branch}",
            f"refs/tags/{branch}",
        )
        branch_head = next((refs[name] for name in branch_names if name in refs), "")
        commit_line = object_lines[offset * 2] if offset * 2 < len(object_lines) else ""
        tree_line = object_lines[offset * 2 + 1] if offset * 2 + 1 < len(object_lines) else ""
        commit_parts = commit_line.split()
        tree_parts = tree_line.split()
        commit_type = commit_parts[1] if len(commit_parts) == 2 else ""
        tree_object = tree_parts[0] if len(tree_parts) == 2 else ""
        tree_type = tree_parts[1] if len(tree_parts) == 2 else ""
        candidate.update({
            "branchHead": branch_head,
            "commitAvailable": commit_type == "commit",
            "treeObject": tree_object if tree_type == "tree" else "",
        })
    return candidates


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


def _dependencies(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "targetHead": args.target_head,
        "policy": args.policy,
        "campaign": args.campaign,
        "candidates": _git_dependencies(args.repo, args.packets),
    }


def plan(args: argparse.Namespace) -> dict[str, Any]:
    state, load_reason = _load(args.index.resolve())
    cycle = int(state.get("cycle", 0) or 0) + 1
    last_full = int(state.get("lastFullCycle", 0) or 0)
    quick = _quick(args.tasks, args.packets, args.leases)
    dependencies = _dependencies(args)
    identity_changed = bool(state) and state.get("quick") != quick
    dependency_changed = bool(state) and state.get("dependencies") != dependencies
    quick_changed = not state or identity_changed or dependency_changed
    periodic_due = bool(state) and cycle - last_full >= args.full_scan_every
    scan = "full" if quick_changed or periodic_due else "quick"
    content = _content(args.tasks, args.packets, args.leases) if scan == "full" else None
    content_changed = bool(state) and content is not None and state.get("content") != content
    reasons = [load_reason] if load_reason else []
    if dependency_changed:
        reasons.append("dependency-identity-changed")
    if identity_changed:
        reasons.append("file-identity-changed")
    if content_changed:
        reasons.append("content-changed")
    if periodic_due:
        reasons.append("periodic-canonical-rediscovery")
    run_canonical = bool(load_reason or quick_changed or content_changed or periodic_due)
    next_state = dict(state)
    next_state.update({"schema": INDEX_SCHEMA, "cycle": cycle})
    # Planning never acknowledges discovery. In particular, a periodic scan
    # schedules the canonical integrator even when indexed bytes are unchanged;
    # only commit() after a successful canonical pass advances the watermark.
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
            "candidateDependencies": len(dependencies["candidates"]),
            "canonicalRequested": int(run_canonical),
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
    parser.add_argument("--repo", type=Path, required=True)
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
