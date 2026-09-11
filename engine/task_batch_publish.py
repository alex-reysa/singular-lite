#!/usr/bin/env python3
"""Publish and resolve immutable staged-candidate batch generations.

The authoritative staged batch is selected by one atomically replaced manifest.
Readers resolve that manifest once and then consume an immutable generation, so
they can observe either the complete old batch or the complete new batch, never
a per-file mixture. Direct candidate files remain a read-only legacy fallback
until the first generation has been published.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import time
from typing import Any


POINTER_SCHEMA = "singular.orchestration.candidate-batch-pointer.v0"
POINTER_NAME = ".candidate-current.json"
FORMAT_MARKER = ".candidate-generation-format"
GENERATIONS_NAME = ".candidate-generations"
CANDIDATE_RE = re.compile(r"TASK-[0-9]{4,}\.candidate\.md")
GENERATION_RE = re.compile(r"batch-[0-9a-f]{64}")


class BatchError(RuntimeError):
    """A fail-closed staged-batch publication or resolution error."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def batch_record(directory: Path) -> dict[str, Any]:
    if not directory.is_dir():
        raise BatchError(f"candidate batch directory is missing: {directory}")
    entries: list[dict[str, Any]] = []
    for path in sorted(directory.iterdir(), key=lambda item: item.name):
        if not CANDIDATE_RE.fullmatch(path.name):
            continue
        if not path.is_file() or path.is_symlink():
            raise BatchError(f"candidate must be a regular file: {path}")
        content = path.read_bytes()
        entries.append(
            {
                "name": path.name,
                "sha256": sha256_bytes(content),
                "size": len(content),
            }
        )
    if not entries:
        raise BatchError(f"candidate batch is empty: {directory}")
    canonical = json.dumps(
        entries, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return {"candidates": entries, "batchSha256": sha256_bytes(canonical)}


def pointer_record(generation: str, record: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": POINTER_SCHEMA,
        "generation": generation,
        "batchSha256": record["batchSha256"],
        "candidates": record["candidates"],
    }


def atomic_json(path: Path, data: dict[str, Any]) -> None:
    descriptor, raw = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    temporary = Path(raw)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def validate_pointer(stage_dir: Path, pointer: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    if not isinstance(pointer, dict) or pointer.get("schema") != POINTER_SCHEMA:
        raise BatchError("candidate pointer schema is invalid")
    generation = pointer.get("generation")
    if not isinstance(generation, str) or not GENERATION_RE.fullmatch(generation):
        raise BatchError("candidate pointer generation is invalid")
    expected = {
        "schema": POINTER_SCHEMA,
        "generation": generation,
        "batchSha256": pointer.get("batchSha256"),
        "candidates": pointer.get("candidates"),
    }
    if pointer != expected:
        raise BatchError("candidate pointer has unexpected fields")
    generation_root = stage_dir / GENERATIONS_NAME
    directory = generation_root / generation
    try:
        directory.resolve().relative_to(generation_root.resolve())
    except (OSError, ValueError) as exc:
        raise BatchError("candidate generation escapes its stage directory") from exc
    if directory.is_symlink():
        raise BatchError("candidate generation must not be a symlink")
    actual = batch_record(directory)
    if pointer_record(generation, actual) != pointer:
        raise BatchError("candidate generation does not match its pointer")
    return directory, actual


def resolve_batch(stage_dir: Path) -> tuple[Path, dict[str, Any], str]:
    pointer_path = stage_dir / POINTER_NAME
    if pointer_path.exists() or pointer_path.is_symlink():
        if pointer_path.is_symlink() or not pointer_path.is_file():
            raise BatchError("candidate pointer must be a regular file")
        try:
            pointer = json.loads(pointer_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise BatchError("candidate pointer is unreadable") from exc
        directory, record = validate_pointer(stage_dir, pointer)
        token = "pointer:" + sha256_bytes(pointer_path.read_bytes())
        return directory, record, token
    if (stage_dir / FORMAT_MARKER).exists():
        raise BatchError("candidate generation pointer is missing")
    record = batch_record(stage_dir)
    token = "legacy:" + record["batchSha256"]
    return stage_dir, record, token


def write_generation(
    stage_dir: Path, candidate_dir: Path, record: dict[str, Any]
) -> tuple[str, Path]:
    generation = "batch-" + record["batchSha256"]
    generation_root = stage_dir / GENERATIONS_NAME
    generation_root.mkdir(mode=0o700, exist_ok=True)
    final = generation_root / generation
    if final.exists():
        if final.is_symlink() or batch_record(final) != record:
            raise BatchError("existing candidate generation failed integrity validation")
        # Files are read-only and the pointer hash-verifies every byte. Keep the
        # directory owner-writable so normal run-state garbage collection can
        # remove retired generations on platforms where immutable directories
        # otherwise make recursive cleanup fail.
        final.chmod(0o755)
        return generation, final

    temporary = Path(tempfile.mkdtemp(prefix=".candidate-generation-", dir=generation_root))
    try:
        for item in record["candidates"]:
            source = candidate_dir / item["name"]
            destination = temporary / item["name"]
            with source.open("rb") as reader, destination.open("xb") as writer:
                shutil.copyfileobj(reader, writer)
                writer.flush()
                os.fsync(writer.fileno())
            destination.chmod(0o444)
        if batch_record(temporary) != record:
            raise BatchError("candidate generation changed while it was copied")
        fsync_directory(temporary)
        try:
            os.rename(temporary, final)
        except FileExistsError:
            if final.is_symlink() or batch_record(final) != record:
                raise BatchError("concurrent candidate generation has invalid content")
        final.chmod(0o755)
        fsync_directory(generation_root)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return generation, final


def wait_at_test_barrier() -> None:
    """Permit a regression to kill publication immediately before pointer swap."""

    ready_raw = os.environ.get("SINGULAR_TEST_BATCH_PUBLISH_READY", "")
    release_raw = os.environ.get("SINGULAR_TEST_BATCH_PUBLISH_RELEASE", "")
    if not ready_raw:
        return
    ready = Path(ready_raw)
    ready.parent.mkdir(parents=True, exist_ok=True)
    ready.write_text("ready\n", encoding="utf-8")
    if not release_raw:
        return
    release = Path(release_raw)
    while not release.exists():
        time.sleep(0.01)


def publish(stage_dir: Path, candidate_dir: Path) -> dict[str, Any]:
    if stage_dir == candidate_dir:
        raise BatchError("replacement directory must differ from stage directory")
    if not stage_dir.is_dir() or not candidate_dir.is_dir():
        raise BatchError("stage and replacement directories must exist")

    lock_path = stage_dir / ".candidate-publish.lock"
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        _, current, current_token = resolve_batch(stage_dir)
        replacement = batch_record(candidate_dir)
        current_names = [item["name"] for item in current["candidates"]]
        replacement_names = [item["name"] for item in replacement["candidates"]]
        if replacement_names != current_names:
            raise BatchError("replacement candidate filename set does not match current batch")

        generation, _ = write_generation(stage_dir, candidate_dir, replacement)
        wait_at_test_barrier()

        # Detect a changed legacy batch or pointer before committing publication.
        # The writer lock serializes cooperating publishers; this token also
        # catches non-cooperating stage mutations during generation construction.
        _, _, latest_token = resolve_batch(stage_dir)
        if latest_token != current_token:
            raise BatchError("current candidate batch changed during publication")

        pointer = pointer_record(generation, replacement)
        atomic_json(stage_dir / POINTER_NAME, pointer)
        marker = stage_dir / FORMAT_MARKER
        if not marker.exists():
            descriptor = os.open(marker, os.O_CREAT | os.O_WRONLY, 0o444)
            os.close(descriptor)
            fsync_directory(stage_dir)
        return pointer


def prepare_import(stage_dir: Path, output_dir: Path) -> dict[str, Any]:
    """Copy one pinned canonical generation into a private writable directory."""

    if output_dir.exists() or output_dir.is_symlink():
        raise BatchError("private import directory already exists")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    lock_path = stage_dir / ".candidate-publish.lock"
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        source_dir, record, token = resolve_batch(stage_dir)
        source_modes = {
            item["name"]: (source_dir / item["name"]).stat().st_mode & 0o7777
            for item in record["candidates"]
        }
        temporary = Path(
            tempfile.mkdtemp(prefix=".candidate-import-", dir=str(output_dir.parent))
        )
        try:
            for item in record["candidates"]:
                source = source_dir / item["name"]
                destination = temporary / item["name"]
                with source.open("rb") as reader, destination.open("xb") as writer:
                    shutil.copyfileobj(reader, writer)
                    writer.flush()
                    os.fsync(writer.fileno())
                destination.chmod(0o600)
            if batch_record(temporary) != record:
                raise BatchError("private candidate copy failed integrity validation")
            # Re-resolve and compare the selection, bytes, and source modes while
            # the cooperative publisher lock is still held. Canonical inputs are
            # never chmodded, renamed, or rewritten by this operation.
            latest_dir, latest_record, latest_token = resolve_batch(stage_dir)
            latest_modes = {
                item["name"]: (latest_dir / item["name"]).stat().st_mode & 0o7777
                for item in latest_record["candidates"]
            }
            if latest_token != token or latest_record != record or latest_modes != source_modes:
                raise BatchError("canonical candidate batch changed during private copy")
            fsync_directory(temporary)
            os.rename(temporary, output_dir)
            fsync_directory(output_dir.parent)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
        return {
            "sourceToken": token,
            "sourceDirectory": str(source_dir),
            **record,
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("--stage-dir", required=True)
    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("--stage-dir", required=True)
    publish_parser.add_argument("--candidate-dir", required=True)
    prepare_parser = subparsers.add_parser("prepare-import")
    prepare_parser.add_argument("--stage-dir", required=True)
    prepare_parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    try:
        stage_dir = Path(args.stage_dir).resolve()
        if args.command == "resolve":
            directory, _, _ = resolve_batch(stage_dir)
            print(directory)
            return
        if args.command == "prepare-import":
            prepared = prepare_import(stage_dir, Path(args.output_dir).resolve())
            print(json.dumps(prepared, sort_keys=True, separators=(",", ":")))
            return
        pointer = publish(stage_dir, Path(args.candidate_dir).resolve())
        print(json.dumps(pointer, sort_keys=True, separators=(",", ":")))
    except (BatchError, OSError, ValueError) as exc:
        parser.exit(2, f"task-batch-publish: {exc}\n")


if __name__ == "__main__":
    main()
