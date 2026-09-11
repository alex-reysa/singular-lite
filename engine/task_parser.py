#!/usr/bin/env python3
"""Canonical fail-closed parser for Singular task markdown and scope paths."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any


TASK_ID_RE = re.compile(r"TASK-[0-9]{4,}")
PATH_TOKEN_RE = re.compile(r"(?:^|\s)(?:\.?[A-Za-z0-9_.-]+/)+[^\s,;]+")
GLOB_CHARS = frozenset("*?[]{}")


class TaskParseError(ValueError):
    """A task contract cannot be interpreted without widening its authority."""


def is_legacy_forbidden_prose(value: str) -> bool:
    """Recognize retained catch-all policy sentences, not quoted path syntax."""

    normalized = " ".join(value.lower().split())
    return normalized.startswith(
        (
            "any file outside ",
            "any files outside ",
            "all files outside ",
            "anything outside ",
        )
    )


def validate_scope_path(value: str) -> str:
    path = value.strip()
    if not path:
        raise TaskParseError("scope path is empty")
    if path != value:
        raise TaskParseError("scope path has leading or trailing whitespace")
    if "\\" in path:
        raise TaskParseError("scope path must use '/' separators")
    if path.startswith(("/", "~", "-")):
        raise TaskParseError("scope path must be a relative repository path")
    if any(char in path for char in GLOB_CHARS):
        raise TaskParseError("scope path uses unsupported glob syntax")
    if any(ord(char) < 32 or ord(char) == 127 for char in path):
        raise TaskParseError("scope path contains a control character")
    if any(char in path for char in ("$", "|", "&", ";", ",", "<", ">", '"', "'")):
        raise TaskParseError("scope path contains ambiguous punctuation")
    comparable = path[:-1] if path.endswith("/") else path
    if not comparable:
        raise TaskParseError("scope path is empty")
    parts = comparable.split("/")
    if any(part in ("", ".", "..") for part in parts) or "//" in comparable:
        raise TaskParseError("scope path contains traversal or an empty segment")
    return path


def parse_scope_item(raw: str, kind: str) -> str | None:
    """Extract one executable path, or None for legacy Forbidden prose."""

    item = raw.strip()
    tick_count = item.count("`")
    if tick_count:
        if tick_count != 2:
            raise TaskParseError("scope entry has malformed or multiple backtick spans")
        match = re.fullmatch(r"([^`]*)`([^`]+)`([^`]*)", item)
        if match is None:
            raise TaskParseError("scope entry has malformed backtick quoting")
        before, path, after = match.groups()
        # Annotation is prose only. A second unquoted path candidate would make
        # the ownership interpretation ambiguous even though one span is quoted.
        if PATH_TOKEN_RE.search(before) or PATH_TOKEN_RE.search(after):
            raise TaskParseError("scope entry contains an ambiguous path outside backticks")
        if kind == "forbidden" and is_legacy_forbidden_prose(path):
            # A few legacy task templates wrapped their human-only catch-all
            # sentence in ticks. Quoting otherwise explicitly marks a path,
            # including a root-level path containing spaces.
            return None
        return validate_scope_path(path)

    if any(char.isspace() for char in item):
        if kind == "forbidden" and not PATH_TOKEN_RE.search(item):
            # Historical tasks use sentences such as "Any file outside the
            # owned scope." They are human policy, never executable prefixes.
            return None
        raise TaskParseError("bare scope path contains whitespace or annotation")
    return validate_scope_path(item)


def _depends(raw: str) -> list[str]:
    value = raw.strip().strip("`").strip()
    if value in ("", "[]", "none", "None", "NONE"):
        return []
    return TASK_ID_RE.findall(value)


def _acceptance(lines: list[str]) -> list[str]:
    criteria: list[str] = []
    current: list[str] = []
    for raw in lines:
        top = re.match(r"^[-*]\s+(.*)$", raw)
        if top:
            if current:
                criteria.append("\n".join(current).rstrip())
            current = [top.group(1).rstrip()]
            continue
        if not current:
            if raw.strip():
                current = [raw.rstrip()]
            continue
        # Remove only Markdown's continuation indentation. Nested indentation
        # and all literal content remain represented in the criterion string.
        current.append(raw[2:] if raw.startswith("  ") else raw.rstrip())
    if current:
        criteria.append("\n".join(current).rstrip())
    return [item for item in criteria if item.strip()]


def parse_task(path: str | os.PathLike[str]) -> dict[str, Any]:
    source = Path(path)
    task_document = source.read_text(encoding="utf-8")
    lines = task_document.splitlines()
    data: dict[str, Any] = {
        "taskDocument": task_document,
        "taskId": "",
        "title": "",
        "status": "",
        "area": "",
        "targetBranch": "",
        "workerBranch": "",
        "testPolicy": "",
        "gateCommand": "",
        "dispatchMode": "",
        "dagNode": "",
        "supersedes": [],
        "supersededBy": [],
        "dependsOn": [],
        "objective": "",
        "ownedFiles": [],
        "forbiddenFiles": [],
        "prerequisites": [],
        "acceptanceCriteria": [],
        "planCritique": [],
    }
    header_keys = {
        "status": "status",
        "area": "area",
        "target branch": "targetBranch",
        "worker branch": "workerBranch",
        "test policy": "testPolicy",
        "gate command": "gateCommand",
        "dispatch mode": "dispatchMode",
        "dag node": "dagNode",
    }

    section: str | None = None
    subsection: str | None = None
    objective_lines: list[str] = []
    acceptance_lines: list[str] = []
    for number, raw in enumerate(lines, 1):
        line = raw.rstrip()
        match = re.match(r"^#\s+(TASK-\d{4,})\s*:\s*(.*)$", line)
        if match:
            data["taskId"] = match.group(1)
            data["title"] = match.group(2).strip()
            continue
        heading = re.match(r"^##\s+(.*)$", line)
        if heading:
            if section == "acceptance criteria":
                data["acceptanceCriteria"] = _acceptance(acceptance_lines)
                acceptance_lines = []
            section = heading.group(1).strip().lower()
            subsection = None
            continue
        if section is None:
            header = re.match(r"^([A-Za-z][A-Za-z ]+):\s*(.*)$", line)
            if header:
                key, value = header.group(1).strip().lower(), header.group(2)
                if key == "depends on":
                    data["dependsOn"] = _depends(value)
                elif key in ("supersedes", "superseded by"):
                    field = "supersedes" if key == "supersedes" else "supersededBy"
                    data[field] = _depends(value)
                elif key in header_keys:
                    data[header_keys[key]] = value.strip().strip("`").strip()
            continue
        if section == "objective":
            objective_lines.append(line)
            continue
        if section == "scope":
            scope_header = re.match(
                r"^(Owned files|Forbidden files)\s*:?\s*$", line.strip(), re.I
            )
            if scope_header:
                subsection = scope_header.group(1).lower()
                continue
            item_match = re.match(r"^[-*]\s+(.*)$", line.strip())
            if item_match and subsection in ("owned files", "forbidden files"):
                kind = "owned" if subsection == "owned files" else "forbidden"
                try:
                    item = parse_scope_item(item_match.group(1), kind)
                except TaskParseError as exc:
                    raise TaskParseError(f"{source}:{number}: {exc}") from exc
                if item is not None:
                    data["ownedFiles" if kind == "owned" else "forbiddenFiles"].append(item)
            elif line.strip():
                if subsection == "forbidden files" and not PATH_TOKEN_RE.search(line):
                    # Some retained tasks append explanatory prose after the
                    # legacy Forbidden list. It carries no path authority.
                    continue
                raise TaskParseError(f"{source}:{number}: malformed scope entry")
            continue
        if section == "prerequisites":
            item_match = re.match(r"^[-*]\s+(.*)$", line.strip())
            if item_match:
                data["prerequisites"].append(item_match.group(1).strip())
            continue
        if section == "acceptance criteria":
            acceptance_lines.append(raw.rstrip())
            continue
        if section.startswith("plan critique"):
            item_match = re.match(r"^[-*]\s+(.*)$", line.strip())
            if item_match:
                data["planCritique"].append(item_match.group(1).strip())
            continue
        if section == "executable dag frontier" and not data["dagNode"]:
            node_match = re.match(r"^[-*]\s+node:\s*(.+)$", line.strip(), re.I)
            if node_match:
                data["dagNode"] = node_match.group(1).strip().strip("`").strip()

    if section == "acceptance criteria":
        data["acceptanceCriteria"] = _acceptance(acceptance_lines)
    data["objective"] = "\n".join(objective_lines).strip()
    return data


def node_index(tasks_dir: str, wanted_node: str) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for source in sorted(Path(tasks_dir).rglob("TASK-*.md")):
        task = parse_task(source)
        if task["taskId"] and task["dagNode"] == wanted_node:
            output.append(
                {
                    "taskId": task["taskId"],
                    "status": str(task["status"]).lower(),
                    "ownedFiles": sorted(set(task["ownedFiles"])),
                    "supersededBy": task["supersededBy"],
                    "file": str(source),
                }
            )
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    task_parser = sub.add_parser("task")
    task_parser.add_argument("path")
    index_parser = sub.add_parser("index")
    index_parser.add_argument("tasks_dir")
    index_parser.add_argument("node")
    path_parser = sub.add_parser("validate-path")
    path_parser.add_argument("path")
    args = parser.parse_args()
    try:
        if args.command == "task":
            result: Any = parse_task(args.path)
        elif args.command == "index":
            result = node_index(args.tasks_dir, args.node)
        else:
            print(validate_scope_path(args.path))
            return
        print(json.dumps(result, separators=(",", ":")))
    except (OSError, TaskParseError) as exc:
        parser.exit(2, f"task-parser: {exc}\n")


if __name__ == "__main__":
    main()
