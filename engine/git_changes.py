#!/usr/bin/env python3
"""Fail-closed, NUL-safe Git change path collection.

This leaf is shared by admission scope checks, state-packet production, and
evidence manifests so all three interpret renames and unusual filenames the
same way.  A rename/copy contributes both its source and destination path.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

from task_parser import TaskParseError, validate_scope_path


class GitChangeError(RuntimeError):
    pass


class ScopeMembershipError(RuntimeError):
    pass


def _scope_prefix(value: str, label: str) -> str:
    try:
        validated = validate_scope_path(value)
    except TaskParseError as exc:
        raise ScopeMembershipError(f"invalid {label}: {value!r}: {exc}") from exc
    return validated.rstrip("/")


def path_matches_scope(path: str, prefix: str) -> bool:
    """Match one validated repository path against one path-segment prefix."""
    normalized = prefix.rstrip("/")
    return path == normalized or path.startswith(normalized + "/")


def scope_membership(
    paths: list[str], allow_prefixes: list[str], forbid_prefixes: list[str], *,
    validate_paths: bool = True,
) -> tuple[list[str], list[str]]:
    """Return forbidden and disallowed paths using admission scope semantics."""
    if not allow_prefixes:
        raise ScopeMembershipError("at least one allowed scope prefix is required")
    allowed = [_scope_prefix(value, "allowed scope prefix") for value in allow_prefixes]
    forbidden = [_scope_prefix(value, "forbidden scope prefix") for value in forbid_prefixes]
    checked_paths = paths
    if validate_paths:
        checked_paths = []
        for value in paths:
            try:
                checked_paths.append(validate_scope_path(value))
            except TaskParseError as exc:
                raise ScopeMembershipError(f"invalid changed path: {value!r}: {exc}") from exc

    forbidden_hits: list[str] = []
    violations: list[str] = []
    for path in checked_paths:
        # Forbidden precedence is intentional even when an allow prefix also
        # matches. This is the same decision admission applies to Git paths.
        if any(path_matches_scope(path, prefix) for prefix in forbidden):
            forbidden_hits.append(path)
        elif not any(path_matches_scope(path, prefix) for prefix in allowed):
            violations.append(path)
    return forbidden_hits, violations


def require_scope_membership(
    paths: list[str], allow_prefixes: list[str], forbid_prefixes: list[str], *,
    validate_paths: bool = True,
) -> None:
    forbidden_hits, violations = scope_membership(
        paths, allow_prefixes, forbid_prefixes, validate_paths=validate_paths
    )
    if forbidden_hits or violations:
        details: list[str] = []
        if forbidden_hits:
            details.append("forbidden paths touched:\n" + "".join(
                f"  {path}\n" for path in forbidden_hits
            ).rstrip())
        if violations:
            details.append("disallowed paths:\n" + "".join(
                f"  {path}\n" for path in violations
            ).rstrip())
        raise ScopeMembershipError("\n".join(details))


def _git(worktree: Path, *args: str) -> bytes:
    completed = subprocess.run(
        ["git", "-C", str(worktree), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise GitChangeError(detail or f"git {' '.join(args)} failed")
    return completed.stdout


def resolve_commit(worktree: Path, ref: str) -> str:
    value = _git(worktree, "rev-parse", "--verify", f"{ref}^{{commit}}")
    resolved = value.decode("ascii", errors="strict").strip()
    if not resolved:
        raise GitChangeError(f"Git ref did not resolve to a commit: {ref}")
    return resolved


def require_ancestor(worktree: Path, base: str, head: str) -> tuple[str, str]:
    resolved_base = resolve_commit(worktree, base)
    resolved_head = resolve_commit(worktree, head)
    completed = subprocess.run(
        ["git", "-C", str(worktree), "merge-base", "--is-ancestor", resolved_base, resolved_head],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode == 1:
        raise GitChangeError(
            f"admitted base {resolved_base} is not an ancestor of candidate {resolved_head}"
        )
    if completed.returncode:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise GitChangeError(detail or "git merge-base ancestry check failed")
    return resolved_base, resolved_head


def _decode_path(raw: bytes) -> str:
    return raw.decode("utf-8", errors="surrogateescape")


def _dedupe(paths: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for path in paths:
        if path not in seen:
            seen.add(path)
            result.append(path)
    return result


def committed_paths(worktree: Path, base: str, head: str = "HEAD") -> list[str]:
    resolved_base, resolved_head = require_ancestor(worktree, base, head)
    fields = _git(
        worktree,
        "diff",
        "--name-status",
        "-z",
        "--find-renames",
        f"{resolved_base}...{resolved_head}",
    ).split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    paths: list[str] = []
    index = 0
    while index < len(fields):
        status = fields[index]
        index += 1
        if not status:
            raise GitChangeError("git diff emitted an empty status record")
        kind = chr(status[0])
        needed = 2 if kind in {"R", "C"} else 1
        if index + needed > len(fields):
            raise GitChangeError("git diff emitted a truncated path record")
        for raw in fields[index:index + needed]:
            paths.append(_decode_path(raw))
        index += needed
    return _dedupe(paths)


def working_paths(worktree: Path) -> list[str]:
    fields = _git(
        worktree,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
    ).split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    paths: list[str] = []
    index = 0
    while index < len(fields):
        record = fields[index]
        index += 1
        if len(record) < 4 or record[2:3] != b" ":
            raise GitChangeError("git status emitted a malformed porcelain record")
        status = record[:2]
        paths.append(_decode_path(record[3:]))
        if b"R" in status or b"C" in status:
            if index >= len(fields):
                raise GitChangeError("git status emitted a truncated rename record")
            paths.append(_decode_path(fields[index]))
            index += 1
    return _dedupe(paths)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worktree")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--include-working", action="store_true")
    parser.add_argument("--format", choices=("json", "nul"), default="json")
    parser.add_argument("--check-scope", action="store_true")
    parser.add_argument("--paths-nul")
    parser.add_argument("--allow-prefix", action="append", default=[])
    parser.add_argument("--forbid-prefix", action="append", default=[])
    args = parser.parse_args()
    if args.check_scope:
        if not args.paths_nul:
            parser.error("--check-scope requires --paths-nul")
        try:
            raw_paths = Path(args.paths_nul).read_bytes().split(b"\0")
            if raw_paths and raw_paths[-1] == b"":
                raw_paths.pop()
            paths = [_decode_path(raw) for raw in raw_paths]
            # Git supplies NUL-delimited repository paths here. Admission keeps
            # unusual Git names representable so it can report every violation;
            # declared prefixes were validated above. Packet consumers use the
            # default path validation for untrusted changedFiles strings.
            require_scope_membership(
                paths, args.allow_prefix, args.forbid_prefix, validate_paths=False
            )
        except (OSError, UnicodeError, ScopeMembershipError) as exc:
            print(f"scope check failed; {exc}", file=sys.stderr)
            return 2
        if paths:
            print(f"scope check: {len(paths)} changed path(s), all allowed")
        else:
            print("scope check: no changed files")
        return 0
    if not args.worktree or not args.base:
        parser.error("--worktree and --base are required")
    worktree = Path(args.worktree)
    try:
        paths = committed_paths(worktree, args.base, args.head)
        if args.include_working:
            paths = _dedupe(paths + working_paths(worktree))
    except (GitChangeError, OSError, UnicodeError) as exc:
        print(f"git-changes: {exc}", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(paths, ensure_ascii=True, separators=(",", ":")))
    else:
        sys.stdout.buffer.write(b"\0".join(path.encode("utf-8", errors="surrogateescape") for path in paths))
        if paths:
            sys.stdout.buffer.write(b"\0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
