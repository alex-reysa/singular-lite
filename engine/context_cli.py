#!/usr/bin/env python3
"""Command-line interface for :mod:`context_service`."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

try:
    from engine.context_service import ContextError, ContextOverflow, ContextService, publish_bundle
except ImportError:  # installed execution from engine/
    from context_service import ContextError, ContextOverflow, ContextService, publish_bundle


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="singular context",
        description="Build and inspect bounded immutable local context bundles.",
    )
    parser.add_argument("--engine-home", help=argparse.SUPPRESS)
    parser.add_argument("--repo-root", help=argparse.SUPPRESS)
    parser.add_argument("--cwd", help=argparse.SUPPRESS)
    parser.add_argument("remainder", nargs=argparse.REMAINDER, help=argparse.SUPPRESS)
    return parser


def _commands() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="singular context")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def common(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--config")
        sub.add_argument("--workspace")
        sub.add_argument("--role")
        sub.add_argument("--phase")

    build = subparsers.add_parser("build", help="build one atomic prompt+provenance bundle")
    common(build)
    build.add_argument("--task", required=True)
    build.add_argument("--budget-bytes", required=True, type=int)
    build.add_argument("--query")
    build.add_argument("--output")
    build.add_argument("--base-prompt")
    build.add_argument("--prompt-output")
    build.add_argument("--prior-bundle")
    build.add_argument("--delivery", choices=("full", "initial", "delta"), default="full")

    search = subparsers.add_parser("search", help="exact-reference and lexical search")
    common(search)
    search.add_argument("--query", required=True)
    search.add_argument("--limit", type=int, default=5)
    search.add_argument("--max-bytes", type=int, default=4000)

    get = subparsers.add_parser("get", help="verified heading/line source pagination")
    common(get)
    get.add_argument("--ref", required=True)
    get.add_argument("--version", required=True)
    get.add_argument("--section")
    get.add_argument("--start-line", type=int, default=1)
    get.add_argument("--line-count", type=int)
    get.add_argument("--cursor")
    get.add_argument("--max-bytes", type=int, default=4000)

    explain = subparsers.add_parser("explain", help="verify and explain a retained bundle")
    common(explain)
    explain.add_argument("--bundle", required=True)

    effective = subparsers.add_parser(
        "effective-config", help="show effective context invocation policy and provenance"
    )
    common(effective)
    return parser


def _publish_prompt(prompt: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", prefix=".context-prompt.", suffix=".tmp",
            dir=destination.parent, delete=False,
        ) as handle:
            temporary = handle.name
            handle.write(prompt)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def _config(args: argparse.Namespace, repo_root: Path, cwd: Path) -> Path:
    raw = args.config or os.environ.get("SINGULAR_JSON_CONFIG_FILE")
    if raw:
        path = Path(raw)
        return (cwd / path).resolve() if not path.is_absolute() else path.resolve()
    return repo_root / "singular.config.json"


def main(argv: list[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)
    repo_root = Path.cwd().resolve()
    cwd = Path.cwd().resolve()
    if raw and raw[0].startswith("--engine-home"):
        outer = _parser().parse_args(raw)
        repo_root = Path(outer.repo_root or repo_root).resolve()
        cwd = Path(outer.cwd or cwd).resolve()
        raw = outer.remainder
        if raw and raw[0] == "--":
            raw = raw[1:]
    args = _commands().parse_args(raw)
    try:
        role = args.role or os.environ.get("SINGULAR_RUNNER_ROLE") or "assistant"
        service = ContextService.from_config(
            _config(args, repo_root, cwd), role=role, phase=args.phase,
            workspace=args.workspace,
        )
        if args.command == "search":
            result = service.search(args.query, limit=args.limit, max_bytes=args.max_bytes)
        elif args.command == "get":
            if args.cursor:
                if not re.fullmatch(r"(?:line:[1-9][0-9]*|byte:[0-9]+)", args.cursor):
                    raise ContextError("cursor must be line:<positive-integer> or byte:<non-negative-integer>")
            result = service.get(
                args.ref, version=args.version, section=args.section,
                start_line=args.start_line, line_count=args.line_count,
                max_bytes=args.max_bytes, cursor=args.cursor,
            )
        elif args.command == "build":
            prior = args.prior_bundle if args.prior_bundle else None
            result = service.build(
                task=args.task, phase=args.phase or "unspecified",
                budget_bytes=args.budget_bytes, query=args.query,
                base_prompt=args.base_prompt,
                delivery=args.delivery,
                prior_bundle=prior,
            )
            if args.output and service.enabled:
                output = Path(args.output)
                if not output.is_absolute():
                    output = cwd / output
                publish_bundle(result, output)
            if args.prompt_output and service.enabled:
                prompt_output = Path(args.prompt_output)
                if not prompt_output.is_absolute():
                    prompt_output = cwd / prompt_output
                _publish_prompt(result["prompt"], prompt_output)
        elif args.command == "effective-config":
            result = {
                "schema": "singular.context.effective-configuration.v1",
                "status": "ok" if service.enabled else "disabled",
                "contextService": service.describe(),
            }
        else:
            result = service.explain(args.bundle)
        json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    except ContextOverflow as exc:
        print(f"context service: {exc}", file=sys.stderr)
        return 3
    except ContextError as exc:
        print(f"context service: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
