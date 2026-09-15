#!/usr/bin/env python3
"""Discovery-only reconciliation index.

The index never grants acceptance. It decides only whether the canonical
integrator has to look at retained work this cycle, and which task identities
are worth looking at. Every final candidate, audit, scope, source, secret,
campaign and exact-tree check stays with integrate.sh, uncached.

Three bounded observers feed one dirty set:

* the existing event stream, consumed through a persistent byte cursor with an
  explicit per-cycle event limit;
* an independent fair sweep of retained task, packet, audit and lease
  locations, driven by a persistent directory/entry cursor with explicit
  directory, directory-entry and content-byte limits, so neither directory
  discovery nor large-file hashing can hide an unbounded all-files pass;
* per-candidate and shared dependency identity (task/packet/audit/lease bytes,
  candidate ref and commit/tree availability including packed refs, campaign,
  target head and gate policy).

Plan observes and proposes; commit acknowledges. The event and validation
watermarks advance only for the snapshot a plan actually observed, and only
after the caller has published successfully, so a change that arrives between
observation and acknowledgement stays discoverable on the next cycle.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import subprocess
import time
from pathlib import Path
from typing import Any, Iterable

INDEX_SCHEMA = "singular.orchestration.reconcile-index.v2"
PLAN_SCHEMA = "singular.orchestration.reconcile-index-plan.v1"
LEGACY_INDEX_SCHEMAS = ("singular.orchestration.reconcile-index.v1",)
STATUS_SCHEMA = "singular.orchestration.reconcile-index-status.v1"
RECEIPT_SCHEMA = "singular.orchestration.reconcile-index-receipt.v1"
AUTHORITY = "discovery-only"

# Keys that would turn a discovery cache into an acceptance record. Their
# presence anywhere in a loaded index is treated as forgery, never as data.
FORGED_KEYS = (
    "eligible", "accepted", "acceptedCandidates", "acceptedCandidate",
    "grants", "verdict", "verdicts", "authorized", "approval",
)

DEFAULT_MAX_EVENTS = 512
DEFAULT_MAX_SWEEP_ENTRIES = 512
DEFAULT_MAX_SWEEP_DIRS = 64
DEFAULT_MAX_SWEEP_BYTES = 8 * 1024 * 1024
DEFAULT_HASH_BLOCK_BYTES = 1024 * 1024
ANCHOR_BYTES = 4096

TASK_PATTERN = re.compile(r"TASK-\d{3,}")

# Events that report an *arrival* -- retained work appearing or changing from
# outside this reconcile transaction. Reconcile and integrate also emit events
# as consequences of the canonical pass they just ran (origin.*, integration.*,
# recovery.*, decision.*, reconcile.*); treating those as new causes would make
# every cycle dirty forever. The event stream is only an accelerator, so a
# conservative allowlist is safe: the independent fair sweep, not the stream,
# is what guarantees completeness.
DEFAULT_DIRTY_EVENT_PREFIXES = (
    "packet.", "task.", "lease.", "l1.", "l2.", "worker.", "candidate.", "audit.",
)


# --------------------------------------------------------------------------
# retained locations
# --------------------------------------------------------------------------

def _roots(args: argparse.Namespace) -> list[tuple[str, Path]]:
    found = [
        ("tasks", args.tasks),
        ("packets", args.packets),
        ("leases", args.leases),
    ]
    if getattr(args, "audits", None):
        found.append(("audits", args.audits))
    return [(label, Path(path)) for label, path in found if path is not None]


def _tracked(label: str, name: str) -> bool:
    if label == "tasks":
        return name.startswith("TASK-") and name.endswith(".md")
    return name.endswith(".json")


def _task_of(key: str) -> str | None:
    match = TASK_PATTERN.search(key)
    return match.group(0) if match else None


def _identity(stat: os.stat_result) -> list[int]:
    return [int(stat.st_dev), int(stat.st_ino), int(stat.st_size), int(stat.st_mtime_ns)]


def _digest(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


# --------------------------------------------------------------------------
# durable state
# --------------------------------------------------------------------------

def _load(path: Path) -> tuple[dict[str, Any], str]:
    """Load retained index state, refusing anything that could grant work."""
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}, "missing-index"
    except OSError:
        return {}, "corrupt-index"
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return {}, "corrupt-index"
    if not isinstance(value, dict):
        return {}, "corrupt-index"
    if value.get("schema") in LEGACY_INDEX_SCHEMAS:
        # A superseded discovery schema is a cold start, not damage: rebuild
        # from retained authority exactly as if no index existed.
        return {}, "outdated-index"
    if value.get("schema") != INDEX_SCHEMA:
        return {}, "corrupt-index"
    if any(key in value for key in FORGED_KEYS) or value.get("authority") != AUTHORITY:
        return {}, "forged-index"
    entries = value.get("entries")
    if not isinstance(entries, dict):
        return {}, "corrupt-index"
    for record in entries.values():
        if not isinstance(record, dict):
            return {}, "corrupt-index"
        if any(key in record for key in FORGED_KEYS):
            return {}, "forged-index"
    return value, ""


def _store(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f"{path.name}.tmp-{os.getpid()}")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temp, path)


# --------------------------------------------------------------------------
# dependency identity
# --------------------------------------------------------------------------

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
        except (OSError, json.JSONDecodeError, ValueError):
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


def _git_dependencies(repo: Path, packets: Path) -> tuple[list[dict[str, Any]], int]:
    """Resolve candidate refs and objects in two bounded, packed-ref-aware calls."""
    candidates = _accepted_candidates(packets)
    if not candidates:
        return [], 0
    try:
        refs = {}
        for line in _git_output(
            repo, ["for-each-ref", "--format=%(refname)%09%(objectname)"]
        ).splitlines():
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
        return [{**candidate, "gitQuery": "unavailable"} for candidate in candidates], 2

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
    return candidates, 2


def _dependencies(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    """Shared and per-candidate dependency identity, separately digested.

    Separation is what keeps an unrelated local change from forcing every
    historical entry back through expensive validation: only a genuinely
    shared change (target branch/tree, gate policy/source, campaign/epoch)
    invalidates every affected entry.
    """
    candidates, subprocess_count = _git_dependencies(Path(args.repo), Path(args.packets))
    shared = {
        "targetHead": args.target_head,
        "policy": args.policy,
        "campaign": args.campaign,
    }
    per_task: dict[str, str] = {}
    for candidate in candidates:
        task = str(candidate.get("taskId") or "") or _task_of(str(candidate.get("packet", "")))
        if not task:
            continue
        per_task[task] = _digest(candidate)
    return (
        {"global": shared, "globalDigest": _digest(shared), "candidates": per_task},
        subprocess_count,
    )


# --------------------------------------------------------------------------
# bounded event cursor
# --------------------------------------------------------------------------

def _anchor(path: Path, length: int) -> str:
    if length <= 0:
        return ""
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read(length)).hexdigest()


def _read_events(path: Path | None, cursor: dict[str, Any], limit: int,
                 prefixes: tuple[str, ...]) -> tuple[set[str], dict[str, Any]]:
    """Consume at most `limit` retained events from a persistent byte cursor."""
    info: dict[str, Any] = {
        "read": 0, "backlogBytes": 0, "bytesRead": 0,
        "unparseable": 0, "discontinuity": False,
        "cursor": {"offset": 0, "size": 0, "inode": 0, "anchorLen": 0, "anchorDigest": ""},
    }
    dirty: set[str] = set()
    if path is None:
        return dirty, info
    try:
        stat = path.stat()
    except OSError:
        # A retained stream that existed and is now unreadable is a cursor
        # discontinuity, not an empty backlog.
        info["discontinuity"] = bool(cursor)
        return dirty, info

    offset = int(cursor.get("offset", 0) or 0)
    anchor_len = int(cursor.get("anchorLen", 0) or 0)
    if cursor:
        rotated = int(cursor.get("inode", 0) or 0) not in (0, int(stat.st_ino))
        truncated = stat.st_size < offset
        replaced = False
        if anchor_len and not truncated:
            try:
                replaced = _anchor(path, anchor_len) != cursor.get("anchorDigest", "")
            except OSError:
                replaced = True
        if rotated or truncated or replaced:
            info["discontinuity"] = True
            offset = 0

    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            consumed = 0
            while info["read"] < limit:
                line = handle.readline()
                if not line or not line.endswith(b"\n"):
                    break
                consumed += len(line)
                info["read"] += 1
                task = _event_task(line, prefixes)
                if task:
                    dirty.add(task)
                elif not _event_parsed(line):
                    info["unparseable"] += 1
            offset += consumed
            info["bytesRead"] = consumed
            size = os.fstat(handle.fileno()).st_size
        info["backlogBytes"] = max(0, size - offset)
        anchor_len = min(offset, ANCHOR_BYTES)
        info["cursor"] = {
            "offset": offset,
            "size": size,
            "inode": int(stat.st_ino),
            "anchorLen": anchor_len,
            "anchorDigest": _anchor(path, anchor_len),
        }
    except OSError:
        info["discontinuity"] = True
    return dirty, info


def _event_parsed(line: bytes) -> bool:
    try:
        json.loads(line.decode("utf-8", "replace"))
        return True
    except (json.JSONDecodeError, ValueError):
        return False


def _event_task(line: bytes, prefixes: tuple[str, ...]) -> str | None:
    """Existing packet.imported and lifecycle events already name the task."""
    text = line.decode("utf-8", "replace")
    try:
        event = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(event, dict):
        return None
    kind = event.get("type")
    if not isinstance(kind, str) or not kind.startswith(prefixes):
        return None
    data = event.get("data")
    for source in (data if isinstance(data, dict) else {}, event):
        task = source.get("taskId")
        if isinstance(task, str) and TASK_PATTERN.fullmatch(task):
            return task
    match = TASK_PATTERN.search(text)
    return match.group(0) if match else None


# --------------------------------------------------------------------------
# fair bounded sweep
# --------------------------------------------------------------------------

def _hash_entry(
    path: Path, stat: os.stat_result, previous: dict[str, Any] | None,
    budget: int, block: int, reserve_first: bool,
) -> tuple[dict[str, Any], int]:
    """Hash a retained artifact block-wise, resuming across cycles.

    Content identity is a digest over the ordered block digests and the size,
    so arbitrarily large artifacts obtain real content identity without ever
    spending more than the declared per-cycle byte budget on them.
    """
    identity = _identity(stat)
    blocks: list[str] = []
    offset = 0
    partial = (previous or {}).get("partial")
    if isinstance(partial, dict) and partial.get("identity") == identity:
        raw_blocks = partial.get("blocks")
        if isinstance(raw_blocks, list) and all(isinstance(item, str) for item in raw_blocks):
            blocks = list(raw_blocks)
            offset = int(partial.get("offset", 0) or 0)
    used = 0
    with open(path, "rb") as handle:
        handle.seek(offset)
        while offset < stat.st_size:
            # Charge the bytes a fixed-size block will actually read, so the
            # per-cycle byte limit is a real ceiling rather than an average.
            # Block boundaries stay fixed, which is what makes the partial
            # block digests resumable across cycles.
            width = min(block, stat.st_size - offset)
            if used + width > budget and not (used == 0 and reserve_first):
                break
            chunk = handle.read(width)
            if not chunk:
                break
            blocks.append(hashlib.sha256(chunk).hexdigest())
            offset += len(chunk)
            used += len(chunk)
    record: dict[str, Any] = {"identity": identity}
    if offset >= stat.st_size:
        record["content"] = hashlib.sha256(
            (f"{stat.st_size}\n" + "\n".join(blocks)).encode()
        ).hexdigest()
    else:
        record["partial"] = {"identity": identity, "offset": offset, "blocks": blocks}
    return record, used


def _sweep(
    state: dict[str, Any], roots: list[tuple[str, Path]], previous: dict[str, Any],
    max_entries: int, max_dirs: int, max_bytes: int, block: int,
) -> dict[str, Any]:
    """Advance one bounded, resumable slice of the retained-artifact pass."""
    sweep_state = state.get("sweep") if isinstance(state.get("sweep"), dict) else {}
    pass_no = int(sweep_state.get("pass", 0) or 0)
    started = bool(sweep_state.get("started"))
    frontier = [item for item in (sweep_state.get("frontier") or []) if isinstance(item, str)]
    entry_cursor = str(sweep_state.get("entryCursor") or "")
    pass_entries = int(sweep_state.get("passEntries", 0) or 0)
    by_label = {label: path for label, path in roots}

    if not started:
        pass_no += 1
        started = True
        frontier = [f"{label}|" for label, path in roots if path.is_dir()]
        entry_cursor = ""
        pass_entries = 0

    visited: dict[str, dict[str, Any]] = {}
    scanned = 0
    directories = 0
    hashed_files = 0
    hashed_bytes = 0
    deferred = 0
    exhausted = False

    while frontier and not exhausted:
        if scanned >= max_entries or directories >= max_dirs:
            break
        label, _, reldir = frontier[0].partition("|")
        root = by_label.get(label)
        if root is None:
            frontier.pop(0)
            entry_cursor = ""
            continue
        directory = root / reldir if reldir else root
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            frontier.pop(0)
            entry_cursor = ""
            directories += 1
            continue
        directories += 1
        completed_directory = True
        for name in names:
            if entry_cursor and name <= entry_cursor:
                continue
            if scanned >= max_entries:
                completed_directory = False
                exhausted = True
                break
            path = directory / name
            child = os.path.join(reldir, name) if reldir else name
            scanned += 1
            try:
                stat = path.stat()
            except OSError:
                entry_cursor = name
                continue
            if os.path.isdir(path):
                # New locations join the current pass; each cycle's directory
                # and entry work stays inside the declared limits.
                frontier.append(f"{label}|{child}")
                entry_cursor = name
                continue
            if not _tracked(label, name):
                entry_cursor = name
                continue
            key = f"{label}/{Path(child).as_posix()}"
            remaining = max(0, max_bytes - hashed_bytes)
            # Reserve progress: the first artifact of a cycle always gets at
            # least one block, so an artifact larger than the whole byte
            # budget advances instead of stalling the pass forever.
            reserve_first = hashed_bytes == 0
            if remaining <= 0 and not reserve_first:
                completed_directory = False
                exhausted = True
                break
            try:
                record, used = _hash_entry(
                    path, stat, previous.get(key), remaining, block, reserve_first)
            except OSError:
                entry_cursor = name
                continue
            if used == 0 and "content" not in record:
                # No byte budget left for this artifact this cycle.
                completed_directory = False
                exhausted = True
                break
            hashed_bytes += used
            hashed_files += 1
            record["pass"] = pass_no
            task = _task_of(key)
            if task:
                record["taskId"] = task
            visited[key] = record
            if "partial" in record:
                # Resume on this artifact next cycle; the cursor stays put.
                deferred += 1
                completed_directory = False
                exhausted = True
                break
            entry_cursor = name
        if exhausted:
            break
        if completed_directory:
            frontier.pop(0)
            entry_cursor = ""

    pass_entries += len([key for key, record in visited.items() if "partial" not in record])
    complete = not frontier and not exhausted
    return {
        "visited": visited,
        "pass": pass_no,
        "passComplete": complete,
        "started": not complete,
        "frontier": frontier,
        "entryCursor": entry_cursor,
        "passEntries": pass_entries,
        "entriesScanned": scanned,
        "directoriesOpened": directories,
        "filesHashed": hashed_files,
        "bytesHashed": hashed_bytes,
        "oversizedDeferred": deferred,
    }


# --------------------------------------------------------------------------
# plan
# --------------------------------------------------------------------------

def _revisit_bound(population: int, visited: int, deferred: int,
                   max_entries: int, max_bytes: int, block: int) -> int:
    """Upper bound, in cycles, on revisiting the current retained population."""
    remaining = max(0, population - visited)
    entry_cycles = math.ceil(remaining / max_entries) if max_entries > 0 else remaining
    byte_cycles = math.ceil((deferred * block) / max_bytes) if max_bytes > 0 else deferred
    return int(entry_cycles + byte_cycles + 1)


def plan(args: argparse.Namespace) -> dict[str, Any]:
    started_at = time.monotonic()
    index_path = Path(args.index).resolve()
    state, load_reason = _load(index_path)
    cycle = int(state.get("cycle", 0) or 0) + 1
    last_full = int(state.get("lastFullCycle", 0) or 0)
    baseline_pass = int(state.get("baselinePass", 0) or 0)
    previous = state.get("entries") if isinstance(state.get("entries"), dict) else {}
    previous = {key: value for key, value in previous.items() if isinstance(value, dict)}

    reasons: list[str] = [load_reason] if load_reason else []
    dirty: set[str] = set()

    # 1. bounded event cursor
    event_cursor = state.get("events") if isinstance(state.get("events"), dict) else {}
    events_path = Path(args.events) if getattr(args, "events", None) else None
    prefixes = tuple(
        part for part in (args.dirty_event_prefixes or "").split(",") if part
    ) or DEFAULT_DIRTY_EVENT_PREFIXES
    event_dirty, events = _read_events(
        events_path, event_cursor, args.max_events, prefixes)
    if events["discontinuity"]:
        reasons.append("event-cursor-discontinuity")
    if event_dirty:
        reasons.append("event-dirty")
        dirty |= event_dirty

    # 2. independent fair sweep of retained locations
    sweep_started = time.monotonic()
    sweep = _sweep(
        state, _roots(args), previous,
        args.max_sweep_entries, args.max_sweep_dirs, args.max_sweep_bytes,
        args.hash_block_bytes,
    )
    sweep_elapsed_ms = int((time.monotonic() - sweep_started) * 1000)

    entries = dict(previous)
    content_changed = False
    for key, record in sweep["visited"].items():
        before = previous.get(key)
        entries[key] = {**(before or {}), **record}
        if "content" not in record:
            continue
        if before is None or before.get("content") != record["content"]:
            content_changed = True
            task = record.get("taskId") or _task_of(key)
            if task:
                dirty.add(task)
    if content_changed:
        reasons.append("sweep-content-changed")

    removed = False
    if sweep["passComplete"]:
        for key in list(entries):
            record = entries[key]
            if int(record.get("pass", 0) or 0) < sweep["pass"]:
                removed = True
                task = record.get("taskId") or _task_of(key)
                if task:
                    dirty.add(task)
                del entries[key]
    if removed:
        reasons.append("sweep-entry-removed")

    # 3. per-entry and shared dependency identity
    dependencies, subprocesses = _dependencies(args)
    stored = state.get("shared") if isinstance(state.get("shared"), dict) else {}
    known_tasks = {
        record.get("taskId") or _task_of(key)
        for key, record in entries.items()
    } | set(dependencies["candidates"])
    known_tasks = {task for task in known_tasks if task}
    if state and stored.get("globalDigest") != dependencies["globalDigest"]:
        reasons.append("shared-dependency-changed")
        dirty |= known_tasks
    stored_candidates = stored.get("candidates") if isinstance(stored.get("candidates"), dict) else {}
    if state:
        changed_candidates = {
            task for task in set(stored_candidates) | set(dependencies["candidates"])
            if stored_candidates.get(task) != dependencies["candidates"].get(task)
        }
        if changed_candidates:
            reasons.append("candidate-dependency-changed")
            dirty |= changed_candidates

    periodic_due = bool(state) and not load_reason and cycle - last_full >= args.full_scan_every
    if periodic_due:
        reasons.append("periodic-canonical-rediscovery")

    run_canonical = bool(dirty or load_reason or periodic_due or events["discontinuity"])
    # A filtered canonical selection is offered only from a complete, quiet,
    # acknowledged observation. Anything else falls back to full discovery, so
    # the index can never permanently hide eligible work.
    dirty_complete = bool(
        state
        and not load_reason
        and not periodic_due
        and not events["discontinuity"]
        and events["backlogBytes"] == 0
        and baseline_pass >= 1
    )

    population = len(entries) + len(sweep["frontier"])
    bound = _revisit_bound(
        population, sweep["passEntries"], sweep["oversizedDeferred"],
        args.max_sweep_entries, args.max_sweep_bytes, args.hash_block_bytes,
    )

    # 4. diagnostics deduplicated by reason and dependency identity
    identity_seed = ",".join(sorted(dirty)) + "|" + dependencies["globalDigest"]
    observed = {
        reason: hashlib.sha256(f"{reason}|{identity_seed}".encode()).hexdigest()[:16]
        for reason in dict.fromkeys(reasons)
    }
    retained = state.get("diagnostics") if isinstance(state.get("diagnostics"), dict) else {}
    diagnostics = [
        {"reason": reason, "state": "new", "identity": identity}
        for reason, identity in observed.items() if retained.get(reason) != identity
    ] + [
        {"reason": reason, "state": "resolved", "identity": str(identity)}
        for reason, identity in sorted(retained.items()) if reason not in observed
    ]
    suppressed = sum(1 for reason, identity in observed.items() if retained.get(reason) == identity)

    elapsed_ms = int((time.monotonic() - started_at) * 1000)
    receipts = {
        "directoryEntriesScanned": sweep["entriesScanned"],
        "directoriesOpened": sweep["directoriesOpened"],
        "filesHashed": sweep["filesHashed"],
        "bytesHashed": sweep["bytesHashed"],
        "eventsRead": events["read"],
        "eventBytesRead": events["bytesRead"],
        "subprocesses": subprocesses,
        "elapsedMs": elapsed_ms,
        "sweepElapsedMs": sweep_elapsed_ms,
    }

    # Planning never acknowledges. Only `cycle` and the deduplicated diagnostic
    # ledger become durable here; the observed snapshot is proposed, and commit
    # promotes it after the caller has published successfully.
    next_state = dict(state) if state else {}
    next_state.update({
        "schema": INDEX_SCHEMA,
        "authority": AUTHORITY,
        "cycle": cycle,
        "diagnostics": observed,
        "pending": {
            "cycle": cycle,
            "entries": entries,
            "events": events["cursor"],
            "shared": {
                "globalDigest": dependencies["globalDigest"],
                "candidates": dependencies["candidates"],
            },
            "sweep": {
                "pass": sweep["pass"],
                "started": sweep["started"],
                "frontier": sweep["frontier"],
                "entryCursor": sweep["entryCursor"],
                "passEntries": sweep["passEntries"],
                "passComplete": sweep["passComplete"],
            },
        },
    })
    next_state.setdefault("entries", previous)
    next_state.setdefault("baselinePass", baseline_pass)
    next_state.setdefault("lastFullCycle", last_full)
    for key in FORGED_KEYS:
        next_state.pop(key, None)
    _store(index_path, next_state)

    document = {
        "schema": PLAN_SCHEMA,
        "authority": AUTHORITY,
        "runCanonical": run_canonical,
        "scan": "full" if (run_canonical or sweep["passComplete"]) else "quick",
        "cycle": cycle,
        "reasons": list(dict.fromkeys(reasons)),
        "dirtyTasks": sorted(dirty),
        "dirtyComplete": dirty_complete,
        "events": {
            "read": events["read"],
            "backlogBytes": events["backlogBytes"],
            "bytesRead": events["bytesRead"],
            "unparseable": events["unparseable"],
            "discontinuity": events["discontinuity"],
        },
        "sweep": {
            "pass": sweep["pass"],
            "passComplete": sweep["passComplete"],
            "entriesScanned": sweep["entriesScanned"],
            "directoriesOpened": sweep["directoriesOpened"],
            "filesHashed": sweep["filesHashed"],
            "bytesHashed": sweep["bytesHashed"],
            "oversizedDeferred": sweep["oversizedDeferred"],
            "population": population,
            "remainingEntries": max(0, population - sweep["passEntries"]),
            "revisitBoundCycles": bound,
        },
        "diagnostics": diagnostics,
        "suppressedDiagnostics": suppressed,
        "limits": {
            "maxEvents": args.max_events,
            "maxSweepEntries": args.max_sweep_entries,
            "maxSweepDirectories": args.max_sweep_dirs,
            "maxSweepBytes": args.max_sweep_bytes,
            "hashBlockBytes": args.hash_block_bytes,
            "fullScanEvery": args.full_scan_every,
        },
        "metrics": {
            "statIdentities": len(entries),
            "contentHashes": sweep["filesHashed"],
            "candidateDependencies": len(dependencies["candidates"]),
            "canonicalRequested": int(run_canonical),
            "entries": len(entries),
            "dirtyTasks": len(dirty),
        },
        "receipts": receipts,
    }
    if getattr(args, "receipt", None):
        _write_receipt(Path(args.receipt), document, entries)
    return document


def _safe_plan(reason: str, detail: str) -> dict[str, Any]:
    """An unusable index fails to full canonical discovery, never to acceptance."""
    return {
        "schema": PLAN_SCHEMA,
        "authority": AUTHORITY,
        "runCanonical": True,
        "scan": "full",
        "cycle": 0,
        "reasons": [reason, detail][:2],
        "dirtyTasks": [],
        "dirtyComplete": False,
        "events": {"read": 0, "backlogBytes": 0, "bytesRead": 0,
                   "unparseable": 0, "discontinuity": False},
        "sweep": {"pass": 0, "passComplete": False, "entriesScanned": 0,
                  "directoriesOpened": 0, "filesHashed": 0, "bytesHashed": 0,
                  "oversizedDeferred": 0, "population": 0,
                  "remainingEntries": 0, "revisitBoundCycles": 1},
        "diagnostics": [{"reason": reason, "state": "new", "identity": ""}],
        "suppressedDiagnostics": 0,
        "limits": {},
        "metrics": {"statIdentities": 0, "contentHashes": 0,
                    "candidateDependencies": 0, "canonicalRequested": 1,
                    "entries": 0, "dirtyTasks": 0},
        "receipts": {"directoryEntriesScanned": 0, "directoriesOpened": 0,
                     "filesHashed": 0, "bytesHashed": 0, "eventsRead": 0,
                     "eventBytesRead": 0, "subprocesses": 0, "elapsedMs": 0,
                     "sweepElapsedMs": 0},
    }


# --------------------------------------------------------------------------
# receipts (consumed by the existing TASK-1106 evaluator as an observation)
# --------------------------------------------------------------------------

def _write_receipt(path: Path, document: dict[str, Any], entries: dict[str, Any]) -> None:
    corpus: dict[str, int] = {"entries": len(entries)}
    for label in ("tasks", "packets", "leases", "audits"):
        corpus[label] = sum(1 for key in entries if key.startswith(f"{label}/"))
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "authority": AUTHORITY,
        "cycle": document["cycle"],
        "sweep": {
            "directoryEntriesScanned": document["receipts"]["directoryEntriesScanned"],
            "directoriesOpened": document["receipts"]["directoriesOpened"],
            "filesHashed": document["receipts"]["filesHashed"],
            "bytesHashed": document["receipts"]["bytesHashed"],
            "oversizedDeferred": document["sweep"]["oversizedDeferred"],
            "pass": document["sweep"]["pass"],
            "passComplete": document["sweep"]["passComplete"],
            "remainingEntries": document["sweep"]["remainingEntries"],
            "revisitBoundCycles": document["sweep"]["revisitBoundCycles"],
            "elapsedMs": document["receipts"]["sweepElapsedMs"],
        },
        "rebuild": {
            "indexedEntries": len(entries),
            "subprocesses": document["receipts"]["subprocesses"],
            "reasons": document["reasons"],
            "elapsedMs": max(
                0, document["receipts"]["elapsedMs"] - document["receipts"]["sweepElapsedMs"]
            ),
        },
        "events": {
            "read": document["events"]["read"],
            "bytesRead": document["events"]["bytesRead"],
            "backlogBytes": document["events"]["backlogBytes"],
            "unparseable": document["events"]["unparseable"],
            "discontinuity": document["events"]["discontinuity"],
        },
        "corpus": corpus,
        "limits": document["limits"],
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "uncertainty": [
            "elapsed milliseconds are wall clock on a shared host and are not "
            "controlled for unrelated load",
            "counters are observations of this corpus only; no comparison "
            "target, expected improvement or rate is asserted",
        ],
    }
    _store(path, receipt)


# --------------------------------------------------------------------------
# commit / status
# --------------------------------------------------------------------------

def _settled_keys(task: str, roots: list[tuple[str, Path]]) -> list[tuple[str, Path]]:
    """Retained locations belonging to exactly one task identity."""
    found: list[tuple[str, Path]] = []
    for label, root in roots:
        if label == "tasks":
            candidates = [root / f"{task}.md"]
        elif label == "packets":
            directory = root / task
            candidates = sorted(directory.glob("*.json")) if directory.is_dir() else []
        else:
            candidates = sorted(root.glob(f"{task}*.json")) if root.is_dir() else []
        for path in candidates:
            if path.is_file():
                found.append((f"{label}/{path.relative_to(root).as_posix()}", path))
    return found


def _settle(
    entries: dict[str, Any], tasks: Iterable[str], roots: list[tuple[str, Path]],
    sweep_pass: int, block: int,
) -> int:
    """Re-observe only what this transaction itself published.

    The origin lock is held for the whole actuation, so the only writer of a
    validated task's retained artifacts during it is the transaction being
    acknowledged. Re-observing exactly those identities keeps the transaction's
    own effects from being rediscovered forever, while every artifact it did
    not publish stays at the identity plan observed -- so an independent change
    racing the acknowledgement is still discovered by the next sweep.
    """
    observed = 0
    for task in tasks:
        present = dict(_settled_keys(task, roots))
        for key in [k for k, record in entries.items()
                    if (record.get("taskId") or _task_of(k)) == task and k not in present]:
            del entries[key]
        for key, path in present.items():
            try:
                stat = path.stat()
                record, _ = _hash_entry(path, stat, None, stat.st_size + block, block, True)
            except OSError:
                continue
            if "content" not in record:
                continue
            record["pass"] = sweep_pass
            record["taskId"] = task
            entries[key] = record
            observed += 1
    return observed


def commit(args: argparse.Namespace) -> dict[str, Any]:
    """Promote the observed snapshot; never re-observe at acknowledgement time.

    Re-reading the corpus here would silently swallow a change that arrived
    while the caller was publishing. Promoting exactly what plan observed keeps
    that change discoverable on the next cycle.
    """
    index_path = Path(args.index).resolve()
    state, reason = _load(index_path)
    pending = state.get("pending") if isinstance(state.get("pending"), dict) else None
    if reason or not pending:
        return {"schema": INDEX_SCHEMA, "authority": AUTHORITY,
                "acknowledged": False, "reason": reason or "no-pending-observation"}
    sweep = pending.get("sweep") if isinstance(pending.get("sweep"), dict) else {}
    cycle = int(pending.get("cycle", state.get("cycle", 1)) or 1)
    shared = dict(pending.get("shared") or {})
    if args.target_head is not None:
        # The caller publishes the target branch under the origin lock during
        # this very actuation, so the acknowledged target/policy/campaign
        # identity is part of the published snapshot, not an unobserved change
        # racing it. Candidate, entry, event and sweep identity all stay
        # exactly as they were observed.
        shared["global"] = {
            "targetHead": args.target_head,
            "policy": args.policy,
            "campaign": args.campaign,
        }
        shared["globalDigest"] = _digest(shared["global"])
    baseline = int(state.get("baselinePass", 0) or 0)
    if sweep.get("passComplete"):
        baseline = int(sweep.get("pass", baseline) or baseline)
    entries = pending.get("entries") if isinstance(pending.get("entries"), dict) else {}
    entries = dict(entries)
    settled: list[str] = []
    if args.settled_tasks:
        try:
            settled = [
                line.strip() for line in
                Path(args.settled_tasks).read_text(encoding="utf-8").splitlines()
                if TASK_PATTERN.fullmatch(line.strip())
            ]
        except OSError:
            settled = []
    if settled:
        roots = _roots(args)
        if roots:
            _settle(entries, settled, roots, int(sweep.get("pass", 0) or 0),
                    args.hash_block_bytes)
        if args.repo is not None and args.packets is not None:
            refreshed, _ = _git_dependencies(Path(args.repo), Path(args.packets))
            by_task = {
                str(candidate.get("taskId") or ""): _digest(candidate)
                for candidate in refreshed
            }
            candidates = dict(shared.get("candidates") or {})
            for task in settled:
                if task in by_task:
                    candidates[task] = by_task[task]
                else:
                    candidates.pop(task, None)
            shared["candidates"] = candidates

    value = {
        "schema": INDEX_SCHEMA,
        "authority": AUTHORITY,
        "cycle": cycle,
        "lastFullCycle": cycle,
        "baselinePass": baseline,
        "shared": shared,
        "events": pending.get("events", {}),
        "sweep": {
            "pass": int(sweep.get("pass", 0) or 0),
            "started": bool(sweep.get("started")),
            "frontier": list(sweep.get("frontier") or []),
            "entryCursor": str(sweep.get("entryCursor") or ""),
            "passEntries": int(sweep.get("passEntries", 0) or 0),
        },
        "entries": entries,
        "diagnostics": state.get("diagnostics", {}),
    }
    _store(index_path, value)
    return {"schema": INDEX_SCHEMA, "authority": AUTHORITY,
            "acknowledged": True, "cycle": cycle, "baselinePass": baseline,
            "settledTasks": len(settled)}


def status(args: argparse.Namespace) -> dict[str, Any]:
    """Non-authoritative health projection over retained index state."""
    index_path = Path(args.index)
    state, reason = _load(index_path)
    document: dict[str, Any] = {
        "schema": STATUS_SCHEMA,
        "authority": AUTHORITY,
        "present": index_path.exists(),
        "healthy": not reason,
        "reason": reason,
        "cycle": int(state.get("cycle", 0) or 0),
        "baselinePass": int(state.get("baselinePass", 0) or 0),
        "entries": 0,
        "eventBacklogBytes": 0,
        "pendingAcknowledgement": isinstance(state.get("pending"), dict),
        "sweep": {"pass": 0, "remainingEntries": 0, "passComplete": True,
                  "frontierDirectories": 0},
    }
    if reason:
        return document
    entries = state.get("entries") if isinstance(state.get("entries"), dict) else {}
    events = state.get("events") if isinstance(state.get("events"), dict) else {}
    sweep = state.get("sweep") if isinstance(state.get("sweep"), dict) else {}
    current = int(sweep.get("pass", 0) or 0)
    frontier = [item for item in (sweep.get("frontier") or []) if isinstance(item, str)]
    document["entries"] = len(entries)
    document["eventBacklogBytes"] = max(
        0, int(events.get("size", 0) or 0) - int(events.get("offset", 0) or 0)
    )
    document["sweep"] = {
        "pass": current,
        "remainingEntries": sum(
            1 for record in entries.values()
            if isinstance(record, dict) and int(record.get("pass", 0) or 0) < current
        ),
        "passComplete": not bool(sweep.get("started")) and not frontier,
        "frontierDirectories": len(frontier),
    }
    return document


# --------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("plan", "commit", "status"))
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--tasks", type=Path)
    parser.add_argument("--packets", type=Path)
    parser.add_argument("--leases", type=Path)
    parser.add_argument("--audits", type=Path)
    parser.add_argument("--events", type=Path)
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--target-head")
    parser.add_argument("--policy")
    parser.add_argument("--campaign")
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--max-events", type=int, default=DEFAULT_MAX_EVENTS)
    parser.add_argument("--max-sweep-entries", type=int, default=DEFAULT_MAX_SWEEP_ENTRIES)
    parser.add_argument("--max-sweep-dirs", type=int, default=DEFAULT_MAX_SWEEP_DIRS)
    parser.add_argument("--max-sweep-bytes", type=int, default=DEFAULT_MAX_SWEEP_BYTES)
    parser.add_argument("--hash-block-bytes", type=int, default=DEFAULT_HASH_BLOCK_BYTES)
    parser.add_argument("--full-scan-every", type=int, default=20)
    parser.add_argument("--dirty-event-prefixes", default="")
    parser.add_argument("--settled-tasks", type=Path)
    args = parser.parse_args()
    if args.action == "plan":
        missing = [
            name for name in
            ("tasks", "packets", "leases", "repo", "target_head", "policy", "campaign")
            if getattr(args, name) is None
        ]
        if missing:
            parser.error("plan requires: " + ", ".join(f"--{n.replace('_', '-')}" for n in missing))
    for name in ("full_scan_every", "max_events", "max_sweep_entries",
                 "max_sweep_dirs", "max_sweep_bytes", "hash_block_bytes"):
        if getattr(args, name) < 1:
            parser.error(f"--{name.replace('_', '-')} must be at least 1")
    return args


def main() -> None:
    args = parse_args()
    if args.action == "commit":
        value = commit(args)
    elif args.action == "status":
        value = status(args)
    else:
        try:
            value = plan(args)
        except Exception as error:  # discovery must never fail closed
            value = _safe_plan("index-error", type(error).__name__)
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
