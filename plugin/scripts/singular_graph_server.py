#!/usr/bin/env python3
"""Serve a read-only singular orchestration console for the Codex Browser panel.

The server reads only durable singular records and runs read-only checks. It never
mutates orchestration state, leases, worktrees, gates, branches, or the STOP
sentinel. The UI is served from sibling ``assets/`` files (index.html, styles.css,
app.js); the backend exposes a small read-only JSON API.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter, OrderedDict
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse


DEFAULT_REPO = os.environ.get("SINGULAR_REPO", ".")
TARGET_BRANCH = "agent/integration"


def _load_human_gate_validator():
    """Load the engine-owned contract validator so console state cannot drift.

    The console and engine ship together.  SINGULAR_ENGINE_HOME supports installed
    layouts; the source-tree location keeps development and packaged tests simple.
    Missing validator code fails closed in ``collect_human_gates``.
    """
    candidates = []
    configured = os.environ.get("SINGULAR_ENGINE_HOME")
    if configured:
        candidates.append(Path(configured) / "engine" / "human_gate.py")
    candidates.append(Path(__file__).resolve().parents[2] / "engine" / "human_gate.py")
    for path in candidates:
        if not path.is_file():
            continue
        try:
            spec = importlib.util.spec_from_file_location(
                "_singular_human_gate_contract", path
            )
            if spec is None or spec.loader is None:
                continue
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module.validate_gate
        except Exception:
            continue
    return None


VALIDATE_HUMAN_GATE = _load_human_gate_validator()


# --------------------------------------------------------------------------- #
# Credential redaction                                                         #
# --------------------------------------------------------------------------- #
# Everything this server hands a browser passes through here. The console binds
# 127.0.0.1 but renders inside a browser process — reachable by other origins'
# JS, extensions, and the browser's own cache and history. "The operator could
# cat the file" is true and beside the point; cat does not put bytes in Chrome.
#
# The motivating leak is not hypothetical and not subtle: engine/secret-scan.sh
# quotes the offending line into secret-scan.log when it blocks a commit, and
# secret-scan.log is in PLAIN_LOG_NAMES. The gate that stops a credential
# reaching git writes it into a file the console streams. This repo's own
# .singular-state carries JWT-shaped strings in exactly that file today.

def _engine_file(relative: str) -> Path | None:
    """Locate an engine-owned file the same way the human-gate validator does."""
    candidates = []
    configured = os.environ.get("SINGULAR_ENGINE_HOME")
    if configured:
        candidates.append(Path(configured) / "engine" / relative)
    candidates.append(Path(__file__).resolve().parents[2] / "engine" / relative)
    for path in candidates:
        if path.is_file():
            return path
    return None


# Console-only rules. Deliberately NOT in engine/secret-patterns.tsv: that file
# gates commits, where a false positive is a refused commit and an operator
# hunting a phantom. These two are anchored on a key NAME rather than on value
# entropy, which is what keeps them safe enough to display-redact but too fuzzy
# to block a commit with.
# Convention for these rules: the LAST capture group is the credential and is
# replaced; every earlier group is kept verbatim. That keeps the header/key name
# on screen, which is the whole diagnostic value of redacting rather than
# dropping ("an Authorization header was here" beats a blank line).
_DISPLAY_PATTERNS: tuple[tuple[str, str], ...] = (
    # The `(?!\[redacted:)` guard on each value group keeps an already-masked
    # token from being masked again under a different kind — which happens for
    # real when the config env pass runs before the generic one.
    ("authorization",
     r"(?i)\b((?:proxy-)?authorization)(\s*[:=]\s*)"
     r"(?:(?:bearer|basic|token|digest)\s+)?(?!\[redacted:)(\S+)"),
    # KEY=VALUE / "key": "value" where the KEY NAME looks secret-ish.
    ("key",
     r"(?i)(?<![\w-])([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|APIKEY|API_KEY"
     r"|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|AUTH_CONTENT|SESSION_ID|SESSIONID)"
     r"[A-Z0-9_]*)([\"']?\s*[:=]\s*[\"']?)(?!\[redacted:)([^\s\"',}]{6,})"),
)

# Literal fragments that must appear before any rule is worth running. This is
# the performance contract: >99.9% of 256 KiB log windows contain no credential,
# and a single literal alternation over one is ~1ms versus ~10-25ms for the full
# rule set. Bare "auth" or "token" would be catastrophic here — this codebase's
# logs are dense with "authoritative", "auth-status", "input_tokens" — so the
# key-name fragments are uppercase-anchored to match env-var shape, not prose.
_PREFILTER_LITERALS = (
    "eyJ", "sk-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "sbp_", "AKIA",
    "-----BEGIN", "authorization", "Authorization", "AUTHORIZATION",
    "_TOKEN", "_SECRET", "_KEY", "_PASSWORD", "PASSWD", "CREDENTIAL",
    "AUTH_CONTENT", "SESSION_ID", "SESSIONID", "APIKEY",
)


def _slugify_pattern_label(label: str) -> str:
    """"JWT / bearer token" -> "jwt-bearer-token" for the [redacted:<slug>] token."""
    slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
    return slug or "secret"


def _load_secret_rules() -> tuple[tuple[re.Pattern, str, int], ...]:
    """(compiled, replacement, group) rules: engine gate patterns + display rules.

    The gate patterns come from engine/secret-patterns.tsv so the console and
    engine/secret-scan.sh cannot drift to two notions of "looks like a secret".
    Fails OPEN on the file (missing or unreadable -> display rules still apply)
    but never fails open on redaction itself: a missing data file must not cause
    the console to serve MORE than it otherwise would.
    """
    rules: list[tuple[re.Pattern, str, int]] = []
    path = _engine_file("secret-patterns.tsv")
    if path is not None:
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                label, _, regex = line.partition("\t")
                if not regex.strip():
                    continue
                try:
                    rules.append((re.compile(regex),
                                  f"[redacted:{_slugify_pattern_label(label)}]", 0))
                except re.error as exc:
                    print(f"singular console: skipping unusable secret pattern "
                          f"{label!r}: {exc}", file=sys.stderr)
        except OSError as exc:
            print(f"singular console: secret pattern file unreadable ({exc}); "
                  "display rules still apply", file=sys.stderr)
    for kind, regex in _DISPLAY_PATTERNS:
        compiled = re.compile(regex)
        rules.append((compiled, f"[redacted:{kind}]", compiled.groups))
    return tuple(rules)


REDACT_ENABLED = os.environ.get("SINGULAR_CONSOLE_REDACT", "1") not in ("0", "false", "no")
_SECRET_RULES = _load_secret_rules()
_SECRET_PREFILTER = re.compile("|".join(re.escape(s) for s in _PREFILTER_LITERALS))


def redact_secrets(text):
    """Replace credential-shaped substrings with stable [redacted:<kind>] tokens.

    Returns the IDENTICAL object when nothing matches — asserted by tests, so a
    future unconditional re.sub chain fails rather than quietly tripling the cost
    of every log poll.

    Deliberately anchored rules only. No bare-entropy rule: a 40-hex git SHA, a
    64-hex sha256 artifact hash (engine/human_gate.py pins exactly that shape),
    and base64 diff excerpts are all legitimate content this console exists to
    display, and every one of them would match a naive high-entropy rule.
    """
    if not text:
        return text if isinstance(text, str) else ""
    if not REDACT_ENABLED or not _SECRET_PREFILTER.search(text):
        return text
    for compiled, replacement, group in _SECRET_RULES:
        if group:
            # Keep every group but the last (header/key name and separator),
            # replace the last one (the credential itself).
            text = compiled.sub(
                lambda m, _r=replacement, _g=group: (
                    "".join(m.group(i) or "" for i in range(1, _g)) + _r),
                text)
        else:
            text = compiled.sub(replacement, text)
    return text


def redact_json_strings(value, _depth: int = 0):
    """Redact every string leaf of a decoded-JSON structure.

    For payloads whose shape is not fixed — event `data` objects composed by
    runners, for instance. Depth-capped so a pathological record cannot make the
    console recurse; realistic event payloads are two or three levels deep.
    """
    if not REDACT_ENABLED or _depth > 6:
        return value
    if isinstance(value, str):
        return redact_secrets(value)
    if isinstance(value, dict):
        return {k: redact_json_strings(v, _depth + 1) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_json_strings(v, _depth + 1) for v in value]
    return value


def redact_fields(record: dict, *keys: str) -> dict:
    """Redact the named string fields of a record in place."""
    for key in keys:
        value = record.get(key)
        if isinstance(value, str) and value:
            record[key] = redact_secrets(value)
    return record


# Row kinds produced by parse_log_lines/classify_codex_record, mapped to the
# fields that carry free text. The default covers any future kind by construction
# so a new record type cannot silently open a hole.
_REDACT_ROW_FIELDS = {
    "command": ("command", "output", "text"),
}


def redact_lines(records: list) -> list:
    """Redact every text-bearing field of parsed/raw log rows, in place."""
    if not REDACT_ENABLED:
        return records
    for record in records:
        if isinstance(record, dict):
            redact_fields(record, *_REDACT_ROW_FIELDS.get(record.get("kind"),
                                                          ("text",)))
    return records


def load_repo_target_branch(repo) -> str:
    """Read targetBranch from the same selected JSON config as the engine."""
    cfg, _resolution, _error = _selected_json_config(Path(repo))
    tb = cfg.get("targetBranch") if isinstance(cfg, dict) else None
    if isinstance(tb, str) and tb:
        return tb
    return TARGET_BRANCH
ASSETS_DIR = (Path(__file__).resolve().parent.parent / "assets")
WATCH_DISK_CAPACITY = 99
SNAPSHOT_TTL_SECONDS = 6.0
TASK_ID_RE = re.compile(r"^TASK-\d+$")

# Repo-relative orchestration layout. Externalizable via the console adapter
# (paths.*); these literals remain the built-in fallback so a repo with no
# adapter behaves exactly as before.
TASKS_DIR_REL = "docs/orchestration/tasks"
AREAS_DIR_REL = "docs/orchestration/areas"
PROMPTS_DIR_REL = "docs/orchestration/prompts"
STATE_DIR_REL = ".singular-state"
EVENTS_LOG_REL = "events.ndjson"            # within the state dir
AUTONOMATE_LOG_REL = "autonomate.out.log"   # within the state dir

# Lease/status vocabularies for durable agent-state derivation. These describe
# only what the records assert; the UI maps them to tones.
DONE_STATUSES = {"integrated", "merged", "complete", "completed", "released"}
AWAITING_STATUSES = {"accepted"}
BLOCKED_STATUSES = {"blocked"}
FAILED_STATUSES = {"failed", "error", "errored"}
# Terminal set used for "is this lease still owned by a worker" checks.
TERMINAL_LEASE_STATUSES = DONE_STATUSES | AWAITING_STATUSES | BLOCKED_STATUSES | FAILED_STATUSES

# Assets are served by extension allowlist + resolved-path containment (not a
# per-file registry) so the SPA can ship ES modules in subdirectories.
ASSET_EXT_TYPES = {
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".mjs": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml; charset=utf-8",
}


def resolve_asset(name: str) -> tuple[Path, str] | None:
    """Map an /assets/<name> request to (file, content type), or None.

    Rejects absolute paths, dot-prefixed components (covers ``..`` and
    dotfiles), unknown extensions, and anything resolving outside ASSETS_DIR.
    """
    if not name or name.startswith("/"):
        return None
    pure = PurePosixPath(name)
    if any(part.startswith(".") for part in pure.parts):
        return None
    content_type = ASSET_EXT_TYPES.get(pure.suffix.lower())
    if content_type is None:
        return None
    root = ASSETS_DIR.resolve()
    path = (root / name).resolve()
    if root not in path.parents or not path.is_file():
        return None
    return path, content_type


# The engine's --detach loop writes ``autonomate.log``; the legacy/adapter name
# is ``autonomate.out.log``. Both are accepted; freshest existing file wins.
AUTONOMATE_LOG_ENGINE = "autonomate.log"


def resolve_autonomate_log(repo: Path) -> str:
    """State-relative name of the L0 supervisor log for this repo."""
    best, best_mtime = None, 0.0
    for name in dict.fromkeys((AUTONOMATE_LOG_REL, AUTONOMATE_LOG_ENGINE)):
        try:
            mtime = state_path(repo, name).stat().st_mtime
        except OSError:
            continue
        if mtime > best_mtime:
            best, best_mtime = name, mtime
    return best or AUTONOMATE_LOG_REL

# Which run-dir prompt file implies which worker role. Decider is matched by the
# "decider-prompt-" prefix (its suffix carries the recovery reason).
ROLE_PROMPT_MAP = {
    "l2-prompt.md": "developer",
    "l2-active-prompt.md": "developer",
    "l2-repair-prompt.md": "recovery-worker",
    "auditor-prompt.md": "auditor",
    "planner-prompt.md": "planner",
}

# Declared role/skill catalog — sourced from docs/operating-model-selfdevelop.md
# (§4.3 worker types, §8 test-first policy, §9 skills model, §14 autonomous decider).
# This is REFERENCE data, not a live registry: singular records only owner/role on
# leases and packets (uniformly l2-developer today); other roles are inferred from
# run artifacts. Served static via /api/roles and cached client-side.
ROLE_CATALOG = {
    "schema": "singular.codex.role-catalog.v0",
    "source": "operating-model-selfdevelop.md §4.3 worker types · §8 test-first · §9 skills · §14 decider",
    "note": (
        "Declared roles and disciplines from the operating model. This is a reference "
        "catalog, not a live registry — singular records no per-agent skill list. Owner/role "
        "is recorded on leases and packets (uniformly l2-developer today); other roles are "
        "inferred from which prompt files exist in a task's run directory."
    ),
    "layers": [
        {
            "id": "L0", "label": "orchestration origin", "writes": False,
            "summary": "Highest reconciler. Reconstructs state, supervises L1, enforces policy. Does not implement code.",
            "disciplines": ["state reconciliation", "drift detection", "policy enforcement", "decision logging"],
        },
        {
            "id": "L1", "label": "area orchestrator", "writes": False,
            "summary": "Manages one bounded area. Decomposes work, imports packets, requires evidence. Does not implement code.",
            "disciplines": ["task decomposition", "packet import", "evidence gating", "integration readiness"],
        },
    ],
    "workers": [
        {"id": "developer", "label": "developer", "recordedAs": "l2-developer", "writes": True,
         "promptFile": "l2-prompt.md",
         "disciplines": ["strict test-first development", "scoped implementation", "state packet emission"],
         "typicalTools": ["go test", "go vet", "go build", "git diff"]},
        {"id": "planner", "label": "planner", "writes": False,
         "promptFile": "planner-prompt.md",
         "disciplines": ["task planning", "batch decomposition"],
         "typicalTools": ["planner batch json"]},
        {"id": "test-engineer", "label": "test engineer", "writes": True,
         "disciplines": ["test-first development", "characterization tests"],
         "typicalTools": ["go test"]},
        {"id": "auditor", "label": "auditor", "writes": False,
         "promptFile": "auditor-prompt.md",
         "disciplines": ["diff auditing", "scope-compliance check", "evidence verification"],
         "typicalTools": ["git diff", "jq", "rg", "scope-check"]},
        {"id": "reviewer", "label": "reviewer", "writes": False,
         "disciplines": ["integration review", "cross-task consistency", "review hygiene"],
         "typicalTools": ["git diff"]},
        {"id": "integration-worker", "label": "integration worker", "writes": True,
         "disciplines": ["branch integration", "gate verification"],
         "typicalTools": ["git merge", "gate-check"]},
        {"id": "documentation-worker", "label": "documentation worker", "writes": True,
         "disciplines": ["documentation update"],
         "typicalTools": []},
        {"id": "recovery-worker", "label": "recovery worker", "writes": True,
         "promptFile": "l2-repair-prompt.md",
         "disciplines": ["recovery and replay", "systematic debugging"],
         "typicalTools": ["git", "go test"]},
        {"id": "decider", "label": "autonomous decider", "writes": False,
         "promptFile": "decider-prompt-*.md", "source": "§14",
         "disciplines": ["recovery-action selection", "escalate / park"],
         "typicalTools": ["decide.sh"]},
    ],
    # §9 recommended bootstrap skills — the shared discipline vocabulary.
    "disciplines": [
        "test-first development", "worktree and branch hygiene", "task planning",
        "scoped implementation", "evidence capture", "diff auditing",
        "integration review", "recovery and replay", "documentation update",
        "state packet emission",
    ],
}


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def strip_ticks(value: str) -> str:
    value = value.strip()
    if value.startswith("`") and value.endswith("`"):
        return value[1:-1]
    return value


def run_command(repo: Path, cmd: list[str], timeout: int = 12) -> dict[str, Any]:
    env = os.environ.copy()
    env["SINGULAR_TARGET_BRANCH"] = TARGET_BRANCH
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(repo),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        return {"ok": False, "exit": 127, "stdout": "", "stderr": str(exc), "cmd": cmd}
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "exit": None,
            "stdout": exc.stdout or "",
            "stderr": f"timed out after {timeout}s",
            "cmd": cmd,
        }
    return {
        "ok": proc.returncode == 0,
        "exit": proc.returncode,
        "stdout": proc.stdout.strip(),
        "stderr": proc.stderr.strip(),
        "cmd": cmd,
    }


def read_json(path: Path, fallback: Any = None) -> Any:
    try:
        return json.loads(path.read_text())
    except Exception:
        return fallback


def _selected_json_config(
    repo: Path, env: dict[str, str] | None = None
) -> tuple[dict[str, Any], dict[str, str], str]:
    """Selected config, stable resolution metadata, and an actionable error."""
    repo = repo.resolve()
    selected_env = env if env is not None else os.environ
    resolver = _load_provider_resolver()
    if resolver is not None and hasattr(resolver, "load_json_config"):
        resolution = resolver.resolve_json_config(repo, selected_env)
        if resolution.source == "default" and not resolution.path.exists():
            return {}, {
                "path": str(resolution.path),
                "source": str(resolution.source),
                "status": "absent",
            }, ""
        try:
            cfg, resolved = resolver.load_json_config(repo, selected_env)
            return cfg, {
                "path": str(resolved.path),
                "source": str(resolved.source),
                "status": "ok",
            }, ""
        except Exception as exc:
            return {}, {
                "path": str(resolution.path),
                "source": str(resolution.source),
                "status": "error",
            }, str(exc)
    raw = str(selected_env.get("SINGULAR_JSON_CONFIG_FILE", "") or "").strip()
    path = Path(raw).expanduser() if raw else repo / "singular.config.json"
    if not path.is_absolute():
        path = repo / path
    path = path.resolve()
    if not raw and not path.exists():
        return {}, {
            "path": str(path),
            "source": "default",
            "status": "absent",
        }, ""
    cfg = read_json(path, None)
    if isinstance(cfg, dict):
        return cfg, {
            "path": str(path),
            "source": "selector" if raw else "default",
            "status": "ok",
        }, ""
    return {}, {
        "path": str(path),
        "source": "selector" if raw else "default",
        "status": "error",
    }, f"selected JSON configuration is missing or invalid: {path}"


def _configured_path(repo: Path, env_key: str, fallback: str) -> Path:
    cfg, _resolution, _error = _selected_json_config(repo)
    cfg_env = cfg.get("env") if isinstance(cfg.get("env"), dict) else {}
    raw = str(cfg_env.get(env_key) or "").strip()
    if not raw:
        return repo / fallback
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = repo / path
    return path


def state_path(repo: Path, *parts: str) -> Path:
    """Join a path inside the effective durable state dir."""
    return _configured_path(repo, "SINGULAR_STATE_DIR", STATE_DIR_REL).joinpath(*parts)


def tasks_path(repo: Path) -> Path:
    return _configured_path(repo, "SINGULAR_TASKS_DIR", TASKS_DIR_REL)


def tail_lines(path: Path, limit: int, max_bytes: int = 262144) -> list[str]:
    """Read only the tail of a file. events.ndjson / autonomate.out.log run to
    multiple MB, so we seek the last ``max_bytes`` rather than loading the whole
    file into memory on every snapshot."""
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return []
    try:
        with path.open("rb") as handle:
            if size > max_bytes:
                handle.seek(size - max_bytes)
                handle.readline()  # drop the partial first line
            chunk = handle.read()
    except OSError:
        return []
    # Split strictly on \n (str.splitlines() also breaks on U+2028/U+2029/NEL etc.,
    # which can appear unescaped inside a JSON payload and corrupt one line into many).
    lines = chunk.decode("utf-8", errors="replace").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines[-limit:]


# High-volume, low-signal event types suppressed from the global feed tail.
NOISE_EVENT_TYPES = {"integration.skipped"}


def parse_events(path: Path, limit: int = 40, drop_noise: bool = True) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    # Pull a larger tail then filter, so suppressed noise does not starve signal.
    for line in tail_lines(path, limit * 12):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            event = {"raw": line}
        if drop_noise and isinstance(event, dict) and event.get("type") in NOISE_EVENT_TYPES:
            continue
        events.append(event)
    events = events[-limit:]
    # Event payloads are composed by runners and carry arbitrary free text
    # (messages, failure reasons, command excerpts), so redact string leaves
    # before any of this reaches a browser. Bounded: at most `limit` events.
    return [redact_json_strings(event) for event in events]


# --------------------------------------------------------------------------- #
# Task markdown parsing                                                        #
# --------------------------------------------------------------------------- #

HEADER_FIELD_RE = re.compile(r"^([A-Za-z][A-Za-z -]+):\s*(.+)$")
TASK_HEADING_RE = re.compile(r"#\s+(TASK-\d+):\s*(.+)")


def _split_sections(lines: list[str]) -> dict[str, list[str]]:
    """Group markdown lines under their ``## Section`` heading (lowercased key)."""
    sections: dict[str, list[str]] = {"_preamble": []}
    current = "_preamble"
    for line in lines:
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            current = heading.group(1).strip().lower()
            sections.setdefault(current, [])
            continue
        sections.setdefault(current, []).append(line)
    return sections


def _bullets(lines: list[str]) -> list[str]:
    items: list[str] = []
    for line in lines:
        match = re.match(r"^\s*[-*]\s+(.+?)\s*$", line)
        if match:
            items.append(strip_ticks(match.group(1)))
    return items


def _prose(lines: list[str]) -> str:
    return "\n".join(line.rstrip() for line in lines).strip()


def _scope_files(lines: list[str]) -> tuple[list[str], list[str]]:
    """Parse a ``## Scope`` section into (owned, forbidden) file lists."""
    owned: list[str] = []
    forbidden: list[str] = []
    bucket: list[str] | None = None
    for line in lines:
        lowered = line.strip().lower()
        if lowered.startswith("owned files"):
            bucket = owned
            continue
        if lowered.startswith("forbidden files"):
            bucket = forbidden
            continue
        match = re.match(r"^\s*[-*]\s+(.+?)\s*$", line)
        if match and bucket is not None:
            bucket.append(strip_ticks(match.group(1)))
    return owned, forbidden


def _packet_history(lines: list[str]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    headers: list[str] = []
    for line in lines:
        if "|" not in line:
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if all(set(cell) <= {"-", ":", " "} for cell in cells):
            continue  # separator row
        if not headers:
            headers = [cell.lower() for cell in cells]
            continue
        if any(cells):
            rows.append({headers[i] if i < len(headers) else f"col{i}": cells[i] for i in range(len(cells))})
    return rows


def parse_task(path: Path) -> dict[str, Any]:
    """Light parse used for list/graph rows (header fields only)."""
    text = path.read_text(errors="replace")
    lines = text.splitlines()
    task_id = path.stem
    title = task_id
    fields: dict[str, str] = {}
    for line in lines[:80]:
        if line.startswith("# "):
            match = TASK_HEADING_RE.match(line)
            if match:
                task_id = match.group(1)
                title = match.group(2).strip()
            continue
        match = HEADER_FIELD_RE.match(line)
        if match:
            key = match.group(1).strip().lower().replace(" ", "_")
            fields[key] = strip_ticks(match.group(2))
    raw_depends = fields.get("depends_on", "")
    depends = [] if raw_depends == "[]" else [item.strip() for item in raw_depends.split(",") if item.strip()]
    return {
        "id": task_id,
        "title": title,
        "status": fields.get("status", "unknown"),
        "area": fields.get("area", "unknown"),
        "targetBranch": fields.get("target_branch", ""),
        "workerBranch": fields.get("worker_branch", ""),
        "testPolicy": fields.get("test_policy", ""),
        "gateCommand": fields.get("gate_command", ""),
        "dispatchMode": fields.get("dispatch_mode", ""),
        "dependsOn": depends,
        "path": str(path),
    }


def parse_task_detail(path: Path) -> dict[str, Any]:
    """Full parse including objective, scope, criteria, evidence, history."""
    base = parse_task(path)
    text = path.read_text(errors="replace")
    sections = _split_sections(text.splitlines())
    owned, forbidden = _scope_files(sections.get("scope", []))
    base.update(
        {
            "objective": _prose(sections.get("objective", [])),
            "ownedFiles": owned,
            "forbiddenFiles": forbidden,
            "prerequisites": _bullets(sections.get("prerequisites", [])) or _prose(sections.get("prerequisites", [])),
            "acceptanceCriteria": _bullets(sections.get("acceptance criteria", [])),
            "requiredEvidence": _bullets(sections.get("required evidence", [])),
            "risks": _prose(sections.get("risks", [])),
            "packetHistory": _packet_history(sections.get("packet history", [])),
        }
    )
    return base


def collect_tasks(repo: Path) -> list[dict[str, Any]]:
    task_dir = tasks_path(repo)
    tasks = []
    for path in sorted(task_dir.glob("TASK-*.md")):
        if path.name == "TEMPLATE.md":
            continue
        try:
            tasks.append(parse_task(path))
        except Exception as exc:  # pragma: no cover - defensive
            tasks.append({"id": path.stem, "title": path.stem, "status": "parse-error", "error": str(exc)})
    return tasks


def collect_leases(repo: Path) -> list[dict[str, Any]]:
    leases = []
    for path in sorted(state_path(repo, "leases").glob("TASK-*.json")):
        data = read_json(path, {})
        if not isinstance(data, dict):
            continue
        data["path"] = str(path)
        data["worktreeExists"] = bool(data.get("worktree") and Path(str(data["worktree"])).exists())
        leases.append(data)
    return leases


# An L1 node lease whose status is in this set is a LIVE planner (a node actively
# being planned in parallel). released/failed free the slot and are not active.
# Mirrors the orchestration lib's active set; the gate-result remains the only
# completion authority — an L1 lease never means "complete".
L1_ACTIVE_STATUSES = {"proposed", "planning", "active"}


def collect_l1_leases(repo: Path) -> list[dict[str, Any]]:
    """Durable L1 node leases (.singular-state/l1-leases/<node>.json), written by the
    live L1 fanout. Absent when fanout is off. Read-only. The `active` flag is the
    honest "deployed planner" signal — lease-file existence alone is NOT activity;
    a released/failed lease is history, not a live agent."""
    leases = []
    root = state_path(repo, "l1-leases")
    if not root.exists():
        return leases
    for path in sorted(root.glob("*.json")):
        data = read_json(path, {})
        if not isinstance(data, dict) or not data.get("node"):
            continue
        data["path"] = str(path)
        data["active"] = data.get("status") in L1_ACTIVE_STATUSES
        leases.append(data)
    return leases


def collect_worktrees(repo: Path) -> list[dict[str, Any]]:
    root = repo / ".worktrees"
    worktrees = []
    if not root.exists():
        return worktrees
    for path in sorted(root.iterdir()):
        if path.is_dir():
            worktrees.append({"name": path.name, "path": str(path)})
    return worktrees


def collect_pid_files(repo: Path) -> list[dict[str, Any]]:
    results = []
    state = state_path(repo)
    if not state.exists():
        return results
    # Look only where pid files actually live — never rglob the runs/ archive,
    # which holds tens of thousands of entries and would dominate snapshot time.
    candidates: list[Path] = []
    for pattern in ("*pid*", "*.pid", "locks/*pid*", "locks/*.pid"):
        candidates.extend(state.glob(pattern))
    seen: set[Path] = set()
    for path in candidates:
        if path in seen or not path.is_file() or "pid" not in path.name.lower():
            continue
        seen.add(path)
        value = path.read_text(errors="replace").strip()
        pid_match = re.search(r"\d+", value)
        pid = int(pid_match.group(0)) if pid_match else None
        alive = False
        if pid:
            try:
                os.kill(pid, 0)
                alive = True
            except OSError:
                alive = False
        results.append({"path": str(path), "pid": pid, "alive": alive, "raw": value})
    return results


# How orchestration processes are recognized in `ps` output. Externalizable via
# the console adapter (processMatchers); these literals remain the built-in
# fallback. include* substrings match case-insensitively (against the lowered
# command line); excludeSubstrings matches case-sensitively, mirroring the
# original inline checks.
PROCESS_MATCHERS: dict[str, Any] = {
    "includeSubstrings": ["scripts/orchestration", "autonomate", "l1-drive", "/.worktrees/"],
    "includeAllOf": [["codex", "singular", "exec"]],
    "excludeSubstrings": ["singular_graph_server.py", " rg "],
    "excludeSubstringsLowered": ["cursor helper"],
}


def collect_processes() -> list[dict[str, Any]]:
    ps = run_command(Path.cwd(), ["ps", "-axo", "pid,ppid,command"], timeout=5)
    matchers = PROCESS_MATCHERS
    rows = []
    for line in ps.get("stdout", "").splitlines():
        lowered = line.lower()
        is_orchestration = (
            any(s in lowered for s in matchers.get("includeSubstrings") or [])
            or any(all(t in lowered for t in group) for group in matchers.get("includeAllOf") or [])
        )
        if not is_orchestration:
            continue
        if (any(s in line for s in matchers.get("excludeSubstrings") or [])
                or any(s in lowered for s in matchers.get("excludeSubstringsLowered") or [])):
            continue
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            rows.append({"pid": parts[0], "ppid": parts[1], "command": parts[2]})
    return rows


DISK_DU_TTL_SECONDS = 300.0


class DiskUsageCache:
    """Background cache for the `du` walk over the state dir / runs / worktrees.

    With 600+ run dirs the du can take tens of seconds, which used to sit
    directly on the snapshot path (under the snapshot single-flight lock) and
    hang /api/state. peek() is strictly non-blocking: it returns the last
    computed value tagged with ``ageSeconds`` (kicking a daemon-thread refresh
    when past TTL, at most one in flight) or ``{"computing": true}`` when cold.
    """

    def __init__(self, ttl: float = DISK_DU_TTL_SECONDS) -> None:
        self.ttl = ttl
        self._lock = threading.Lock()
        self._value: dict[str, Any] | None = None
        self._stamp: float = 0.0
        self._key: str = ""
        self._inflight = False

    def _compute(self, repo: Path, key: str) -> None:
        try:
            value = run_command(
                repo, ["du", "-sh", STATE_DIR_REL, STATE_DIR_REL + "/runs", ".worktrees"],
                timeout=60)
        except Exception as exc:  # defensive: a du failure must never surface as a crash
            value = {"ok": False, "exit": None, "stdout": "", "stderr": str(exc), "cmd": ["du"]}
        with self._lock:
            self._value = value
            self._stamp = time.monotonic()
            self._key = key
            self._inflight = False

    def peek(self, repo: Path) -> dict[str, Any]:
        key = str(repo)
        with self._lock:
            have = self._value is not None and self._key == key
            age = (time.monotonic() - self._stamp) if have else None
            fresh = have and age < self.ttl
            start = not fresh and not self._inflight
            if start:
                self._inflight = True
        if start:
            threading.Thread(target=self._compute, args=(repo, key), daemon=True).start()
        if have:
            out = dict(self._value)
            out["ageSeconds"] = int(age)
            if not fresh:
                out["computing"] = True  # refresh in flight; last value still shown
            return out
        return {"computing": True}


DISK_DU_CACHE = DiskUsageCache()


def collect_disk(repo: Path) -> dict[str, Any]:
    """Disk view: `df` stays inline (fast); the slow `du` comes from the
    non-blocking background cache above. capacity/watch derive from df only."""
    df = run_command(repo, ["df", "-h", "."], timeout=5)
    capacity = None
    free = None
    lines = df.get("stdout", "").splitlines()
    if len(lines) >= 2:
        parts = lines[1].split()
        if len(parts) >= 5:
            free = parts[3]
            try:
                capacity = int(parts[4].rstrip("%"))
            except ValueError:
                capacity = None
    runs_dir = state_path(repo, "runs")
    try:
        run_dir_count = len(os.listdir(runs_dir))
    except OSError:
        run_dir_count = 0
    return {
        "df": df,
        "du": DISK_DU_CACHE.peek(repo),
        "runDirCount": run_dir_count,
        "capacityPercent": capacity,
        "free": free,
        "watch": capacity is not None and capacity >= WATCH_DISK_CAPACITY,
    }


def parse_next_area(stdout: str) -> dict[str, str]:
    result = {}
    for line in stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    return result


def parse_next_areas(stdout: str) -> dict[str, Any]:
    """Parse `dag.sh next-areas` JSON: {"frontier":[{node,area,stage,layer,...}],
    "allComplete"?:true}. Returns {"frontier": []} if unparseable."""
    for line in stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict) and isinstance(data.get("frontier"), list):
                return data
    return {"frontier": []}


def task_sort_key(task: dict[str, Any]) -> int:
    match = re.search(r"(\d+)$", task.get("id", ""))
    return int(match.group(1)) if match else -1


# --------------------------------------------------------------------------- #
# Durable agent-state derivation                                              #
# --------------------------------------------------------------------------- #

def process_matches(processes: list[dict[str, Any]], *needles: str) -> bool:
    """Word/path-boundary match so e.g. TASK-0309 does not match TASK-03091 and a
    worktree path is matched as a delimited segment, not an incidental substring."""
    tokens = [n for n in needles if n]
    if not tokens:
        return False
    patterns = [re.compile(r"(?<![\w-])" + re.escape(t) + r"(?![\w-])") for t in tokens]
    for proc in processes:
        command = str(proc.get("command", ""))
        if any(p.search(command) for p in patterns):
            return True
    return False


def derive_task_state(task: dict[str, Any], lease: dict[str, Any] | None, processes: list[dict[str, Any]]) -> str:
    """Map durable facts to one of:
    active, awaiting, blocked, failed, stale, integrated, idle.
    Only durable signals count; accepted markdown alone never reads as active.
    """
    status = str((lease or {}).get("status") or task.get("status") or "").lower()
    worktree_exists = bool((lease or {}).get("worktreeExists"))
    # Terminal lease statuses are authoritative: an incidental process-substring
    # match must never flip a blocked/integrated/awaiting task back to "active".
    if status in BLOCKED_STATUSES:
        return "blocked"
    if status in FAILED_STATUSES:
        return "failed"
    if status in AWAITING_STATUSES:
        return "awaiting"
    if status in DONE_STATUSES:
        # Retained worktrees are normal evidence during active overnight runs.
        # Completion stays integrated; the runtime tab still shows whether the
        # worktree remains on disk.
        return "integrated"
    # Non-terminal / no recorded lease — a live matching process is the strongest signal.
    worker_branch = task.get("workerBranch") or (lease or {}).get("branch") or ""
    worktree = (lease or {}).get("worktree") or ""
    if process_matches(processes, task.get("id", ""), worker_branch, worktree):
        return "active"
    if lease and status:
        # Worker still owns an open lease: live if a worktree backs it, else stale.
        return "active" if worktree_exists else "stale"
    if worktree_exists:
        return "stale"
    return "idle"


def derive_area_state(task_states: list[str]) -> str:
    """Area liveness, by precedence. Completion is carried in counts, not here,
    so a fully-integrated-but-quiet area reads ``idle`` rather than celebrating."""
    present = set(task_states)
    for state in ("active", "blocked", "failed", "awaiting", "stale"):
        if state in present:
            return state
    return "idle"


def derive_l0_state(stop_present: bool, processes: list[dict[str, Any]], active_origin_lock: bool) -> str:
    if active_origin_lock or processes:
        return "active"
    if stop_present:
        return "stopped"
    return "idle"


STATE_SEVERITY = {"failed": 0, "blocked": 1, "active": 2, "awaiting": 3, "stale": 4, "idle": 5, "integrated": 6,
                  # Planner-session terminals (see PLANNER_TERMINAL_STATES). Slotted
                  # alongside the existing six rather than renumbering them, so the
                  # `.get(state, 9)` default keeps its meaning.
                  "rejected": 0, "empty": 5, "accepted": 6}


def _task_projection(origin_state: Any, state_totals: dict) -> dict[str, Any]:
    """The dock's counts, from ONE source with ONE revision.

    The audit caught the dock rendering "1 active · 1 ready" for a single task.
    Cause: `active` came from the console's own derive_task_state pass over the
    task files, while `ready` came from origin-state.json's readyTasks — two
    definitions, two vintages, and nothing forbidding a task from landing in
    both. A task file keeps `Status: ready` while it runs, so a dispatched task
    is genuinely both "leased and running" and "ready" by header.

    The engine already computes the authoritative answer under the origin lock
    every cycle (singular_write_origin_state), so project from it rather than
    inventing a third derivation, and carry a `revision` so a client can tell
    two payloads apart instead of silently blending them.
    """
    out: dict[str, Any] = {
        "active": int(state_totals.get("active", 0) or 0),
        "ready": None,
        "source": "console",
        "revision": None,
    }
    if isinstance(origin_state, dict):
        ready = origin_state.get("readyTasks")
        if isinstance(ready, list):
            out["ready"] = len(ready)
        elif isinstance(ready, int):
            out["ready"] = ready
        if out["ready"] is not None:
            out["source"] = "origin-state"
        # Content-derived, not a counter: two endpoints reading the same
        # on-disk state must agree even when computed seconds apart.
        stamp = origin_state.get("generatedAt")
        head = origin_state.get("headSha")
        if stamp or head:
            out["revision"] = f"{stamp or '-'}:{str(head or '-')[:12]}"
    return out


def classify_health(snapshot: dict[str, Any]) -> str:
    drift = snapshot["git"].get("drift", {})
    if drift.get("left", 0):
        return "blocker"
    if snapshot["locks"].get("activeOriginLock"):
        return "watch"
    if snapshot["disk"].get("watch"):
        return "watch"
    if snapshot["stop"].get("present") and not snapshot["runtime"].get("processes"):
        return "watch"
    return "healthy"


def build_l2_tasks(
    tasks: list[dict[str, Any]],
    leases: list[dict[str, Any]],
    processes: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    lease_by_task = {lease.get("taskId"): lease for lease in leases}
    merged = []
    for task in tasks:
        item = dict(task)
        lease = lease_by_task.get(task.get("id"))
        if lease:
            item["leaseStatus"] = lease.get("status")
            item["owner"] = lease.get("owner")
            item["runId"] = lease.get("runId")
            item["worktree"] = lease.get("worktree")
            item["worktreeExists"] = lease.get("worktreeExists")
            item["updatedAt"] = lease.get("updatedAt")
            item["retryCount"] = lease.get("retryCount")
            item["maxRetries"] = lease.get("maxRetries")
        item["state"] = derive_task_state(task, lease, processes)
        merged.append(item)
    return sorted(merged, key=task_sort_key, reverse=True)


def build_l1_areas(
    repo: Path,
    merged_tasks: list[dict[str, Any]],
    l1_leases: list[dict[str, Any]] | None = None,
    frontier_areas: list[str] | None = None,
) -> list[dict[str, Any]]:
    l1_leases = l1_leases or []
    leases_by_area: dict[str, list[dict[str, Any]]] = {}
    for lease in l1_leases:
        leases_by_area.setdefault(lease.get("area"), []).append(lease)
    area_names = {path.parent.name for path in (repo / AREAS_DIR_REL).glob("*/state.md")}
    area_names.update(task.get("area", "unknown") for task in merged_tasks)
    # An area with a live L1 planner but no L2 tasks yet must still appear.
    area_names.update(lease.get("area") for lease in l1_leases if lease.get("area"))
    # A ready DAG frontier node's area is shown even before any planner/task exists.
    area_names.update(area for area in (frontier_areas or []) if area)
    by_area: list[dict[str, Any]] = []
    for area in sorted(name for name in area_names if name):
        area_tasks = [task for task in merged_tasks if task.get("area") == area]
        counts: dict[str, int] = {}
        state_counts: dict[str, int] = {}
        for task in area_tasks:
            counts[task.get("status", "unknown")] = counts.get(task.get("status", "unknown"), 0) + 1
            state_counts[task["state"]] = state_counts.get(task["state"], 0) + 1
        recent = sorted(area_tasks, key=task_sort_key, reverse=True)[:8]
        active = [task for task in area_tasks if task["state"] in ("active", "awaiting", "blocked", "failed", "stale")]
        area_leases = leases_by_area.get(area, [])
        # Honest active-planner signal: only a lease in an active status counts.
        active_lease = next((lease for lease in area_leases if lease.get("active")), None)
        state = derive_area_state([task["state"] for task in area_tasks])
        # A live L1 planner makes the area active even before it has spawned tasks.
        if active_lease and state == "idle":
            state = "active"
        by_area.append(
            {
                "id": f"L1:{area}",
                "area": area,
                "state": state,
                "taskCount": len(area_tasks),
                "counts": counts,
                "stateCounts": state_counts,
                "activeTasks": active,
                "recentTasks": recent,
                "l1Active": bool(active_lease),
                "l1Lease": active_lease,
                "l1Leases": area_leases,
            }
        )
    return by_area


def build_agents(
    repo: Path,
    merged_tasks: list[dict[str, Any]],
    l1_areas: list[dict[str, Any]],
    stop_present: bool,
    processes: list[dict[str, Any]],
    active_origin_lock: bool,
    stale_locks: list[str],
    origin_state: dict[str, Any],
) -> dict[str, Any]:
    l0 = {
        "id": "L0",
        "label": "origin",
        "state": derive_l0_state(stop_present, processes, active_origin_lock),
        "stop": stop_present,
        "activeOriginLock": active_origin_lock,
        "staleLocks": stale_locks,
        "processes": len(processes),
        "runId": origin_state.get("runId") if isinstance(origin_state, dict) else None,
        "headSha": origin_state.get("headSha") if isinstance(origin_state, dict) else None,
        "packets": origin_state.get("packets") if isinstance(origin_state, dict) else None,
        "activeLeases": origin_state.get("activeLeases") if isinstance(origin_state, dict) else None,
    }
    l1 = [
        {
            "id": area["id"],
            "area": area["area"],
            "state": area["state"],
            "taskCount": area["taskCount"],
            "stateCounts": area["stateCounts"],
            "l1Active": area.get("l1Active", False),
            "l1Lease": area.get("l1Lease"),
        }
        for area in l1_areas
    ]
    notable = [
        {
            "id": task["id"],
            "title": task.get("title"),
            "area": task.get("area"),
            "state": task["state"],
            "leaseStatus": task.get("leaseStatus"),
            "workerBranch": task.get("workerBranch"),
            "runId": task.get("runId"),
            "worktreeExists": task.get("worktreeExists"),
            "retryCount": task.get("retryCount"),
            "maxRetries": task.get("maxRetries"),
            "updatedAt": task.get("updatedAt"),
        }
        for task in merged_tasks
        if task["state"] in ("active", "awaiting", "blocked", "failed", "stale")
    ]
    notable.sort(key=lambda t: (STATE_SEVERITY.get(t["state"], 9), -task_sort_key(t)))
    return {"l0": l0, "l1": l1, "l2": notable}


# --------------------------------------------------------------------------- #
# Task detail (read-only, single task)                                        #
# --------------------------------------------------------------------------- #

def collect_task_events(repo: Path, task_id: str, limit: int = 24) -> list[dict[str, Any]]:
    path = state_path(repo, EVENTS_LOG_REL)
    # Bounded tail read: scan only recent history (~1MB) for the task so we never
    # pull the multi-MB event log into memory. Older integrated tasks may show no
    # events here — acceptable, since the inspector also surfaces packet/audit refs.
    lines = tail_lines(path, limit=10_000_000, max_bytes=1_048_576)
    matches: list[dict[str, Any]] = []
    for line in lines:
        if task_id not in line:
            continue  # cheap pre-filter before parsing
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        data = event.get("data") if isinstance(event, dict) else None
        if isinstance(data, dict) and data.get("taskId") == task_id:
            matches.append(event)
        elif task_id in str(event.get("message", "")):
            matches.append(event)
    return matches[-limit:]


def find_task_packets(repo: Path, task_id: str, run_id: str | None) -> list[dict[str, Any]]:
    inbox = state_path(repo, "inbox")
    found: list[dict[str, Any]] = []
    if not inbox.exists():
        return found
    candidates = list(inbox.glob("*.json")) + list((inbox / "superseded").glob("*.json"))
    for path in candidates:
        data = read_json(path, None)
        if not isinstance(data, dict) or data.get("taskId") != task_id:
            continue
        found.append(
            {
                "path": str(path),
                "packetId": data.get("packetId"),
                "runId": data.get("runId"),
                "role": data.get("role"),
                "status": data.get("status"),
                "headSha": data.get("headSha"),
                "changedFiles": data.get("changedFiles"),
                "commands": data.get("commands"),
                "tests": data.get("tests"),
                "evidence": data.get("evidence"),
                "blockers": data.get("blockers"),
                "nextAction": data.get("nextAction"),
                "createdAt": data.get("createdAt"),
                "superseded": "superseded" in path.parts,
            }
        )
    found.sort(key=lambda p: str(p.get("createdAt") or ""), reverse=True)
    return found


def find_integrate_runs(repo: Path, task_id: str) -> list[dict[str, Any]]:
    runs = state_path(repo, "runs")
    out: list[dict[str, Any]] = []
    if not runs.exists():
        return out
    for path in sorted(runs.glob(f"*integrate-{task_id}")):
        gate = read_json(path / "gate-check.json", None)
        out.append(
            {
                "dir": str(path),
                "exists": True,
                "gateCheck": gate if isinstance(gate, dict) else None,
                "hasLog": (path / "gate-check.log").exists(),
                "logRef": str(path / "gate-check.log") if (path / "gate-check.log").exists() else None,
            }
        )
    return out


def find_gate_refs(repo: Path, task_id: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for path in sorted((repo / "docs/orchestration/gates").glob("*.gate-result.json")):
        data = read_json(path, None)
        if not isinstance(data, dict):
            continue
        evidence = data.get("evidence") or []
        referenced = any(
            isinstance(item, dict) and task_id in (item.get("taskIds") or [])
            for item in evidence
        )
        if referenced:
            out.append(
                {
                    "node": data.get("node"),
                    "status": data.get("status"),
                    "authoritative": data.get("authoritative"),
                    "evidenceClass": data.get("evidenceClass"),
                    "commandLogs": [
                        {
                            "ref": item.get("ref"),
                            "exitCode": item.get("exitCode"),
                            "logRef": item.get("logRef"),
                            "skipGuardRed": str(item.get("ref", "")).endswith("-skip-guard-red"),
                        }
                        for item in evidence
                        if isinstance(item, dict) and item.get("kind") == "command-log"
                    ],
                    "path": str(path),
                }
            )
    return out


def derive_run_roles(repo: Path, run_id: str | None) -> list[dict[str, Any]]:
    """Infer which worker roles touched a task from the prompt files present in its
    run directory. Read-only: a single non-recursive listing of one known dir."""
    if not run_id:
        return []
    run_dir = state_path(repo, "runs") / run_id
    if not run_dir.is_dir():
        return []
    roles: list[dict[str, Any]] = []
    seen: set[str] = set()
    try:
        names = sorted(p.name for p in run_dir.iterdir() if p.is_file())
    except OSError:
        return []
    for name in names:
        role = ROLE_PROMPT_MAP.get(name)
        reason = None
        if role is None and name.startswith("decider-prompt-") and name.endswith(".md"):
            role = "decider"
            reason = name[len("decider-prompt-"):-len(".md")] or None
        if role and role not in seen:
            seen.add(role)
            roles.append({"role": role, "promptFile": name, "reason": reason})
    return roles


def derive_tools_used(packets: list[dict[str, Any]], run_dir: Path | None, gate_command: str) -> dict[str, Any]:
    """Observed commands/tools for a task, from already-loaded packet data plus the
    run's audit.json and gate-check.json. Read-only; bounded row counts."""
    cap = 16
    worker_cmds: list[dict[str, Any]] = []
    if packets:
        for entry in (packets[0].get("commands") or [])[:cap]:
            if isinstance(entry, dict):
                worker_cmds.append({"cmd": entry.get("cmd"), "exitCode": entry.get("exitCode")})
            elif isinstance(entry, str):
                worker_cmds.append({"cmd": entry, "exitCode": None})
    auditor_cmds: list[str] = []
    gate_check: dict[str, Any] | None = None
    if run_dir is not None and run_dir.is_dir():
        audit = read_json(run_dir / "audit.json", None)
        if isinstance(audit, dict):
            ran = audit.get("commandsRun")
            if isinstance(ran, list):
                auditor_cmds = [str(c) for c in ran[:cap]]
        gc = read_json(run_dir / "gate-check.json", None)
        if isinstance(gc, dict):
            gate_check = {"cmd": gc.get("cmd"), "exitCode": gc.get("exitCode")}
    return {
        "workerCommands": worker_cmds,
        "auditorCommands": auditor_cmds,
        "gateCommand": gate_command or None,
        "gateCheck": gate_check,
    }


def collect_task_detail(repo: Path, task_id: str) -> dict[str, Any] | None:
    repo = repo.resolve()
    path = tasks_path(repo) / f"{task_id}.md"
    if not path.exists():
        return None
    detail = parse_task_detail(path)
    lease_path = state_path(repo, "leases") / f"{task_id}.json"
    lease = read_json(lease_path, None)
    if isinstance(lease, dict):
        lease = dict(lease)
        lease["path"] = str(lease_path)
        lease["worktreeExists"] = bool(lease.get("worktree") and Path(str(lease["worktree"])).exists())
    else:
        lease = None
    processes = collect_processes()
    detail["lease"] = lease
    detail["state"] = derive_task_state(detail, lease, processes)
    detail["worktree"] = {
        "path": (lease or {}).get("worktree"),
        "exists": bool((lease or {}).get("worktreeExists")),
    }
    run_id = (lease or {}).get("runId")
    detail["runId"] = run_id
    detail["packets"] = find_task_packets(repo, task_id, run_id)
    detail["integrateRuns"] = find_integrate_runs(repo, task_id)
    detail["gates"] = find_gate_refs(repo, task_id)
    detail["events"] = collect_task_events(repo, task_id)
    # Observed-this-run agents + tools (honest proxies; singular has no skill registry).
    run_dir = (state_path(repo, "runs") / run_id) if run_id else None
    detail["agentsInvolved"] = {
        "owner": (lease or {}).get("owner"),
        "packetRole": detail["packets"][0].get("role") if detail["packets"] else None,
        "rolesFromPrompts": derive_run_roles(repo, run_id),
        "runId": run_id,
        "source": (
            "owner/role recorded on lease + packet (uniformly l2-developer); other roles "
            "inferred from *-prompt.md files in runs/<runId>/"
        ),
    }
    detail["toolsUsed"] = derive_tools_used(detail["packets"], run_dir, detail.get("gateCommand", ""))
    # Provenance: the causal chain (source doc -> node -> planner -> worker ->
    # packet -> audit -> integration -> gate). Additive; degrades gracefully when an
    # input is missing. See the "Provenance (read-only derivation)" section.
    detail["provenance"] = build_task_provenance(repo, detail, lease)
    detail["generatedAt"] = utc_now()
    detail["schema"] = "singular.codex.task-detail.v0"
    return detail


# --------------------------------------------------------------------------- #
# Snapshot                                                                      #
# --------------------------------------------------------------------------- #

# Adapter ESCAPE HATCH for the snapshot's orchestration probes. Since 0.5.0 the
# BUILT-IN probes are computed natively (compute_frontier_native /
# validate_dag_native / collect_status_native below) — the server already parses
# the DAG registry, gate files and STATUS.md, so shelling out to `make orch-*`
# (6 subprocesses x 12s timeout under the snapshot lock) is gone. A console
# adapter that EXPLICITLY configures a command for a probe (commands.status,
# commands.validateDag, commands.nextArea, commands.nextAreas) still runs that
# subprocess exactly as before; only the built-in fallback is native. These
# `make orch-*` argv lists remain as the reference built-ins so overridden-ness
# can be detected per key. "{node}" is substituted by console_command(..., node=...).
CONSOLE_COMMANDS: dict[str, list[str]] = {
    "status": ["make", "orch-status"],
    "validateDag": ["make", "orch-validate-dag"],
    "nextArea": ["make", "orch-next-area"],
    "nextAreas": ["make", "orch-next-areas"],
}


def console_command(name: str, **params: str) -> list[str]:
    """Resolve one configured command to an argv list, filling {placeholders}."""
    out: list[str] = []
    for part in (CONSOLE_COMMANDS.get(name) or []):
        part = str(part)
        if params and "{" in part:
            try:
                part = part.format(**params)
            except (KeyError, IndexError, ValueError):
                pass  # leave the part untouched rather than crash a snapshot
        out.append(part)
    return out


def probe_command_overridden(name: str) -> bool:
    """True when a console adapter explicitly configured a subprocess for this
    probe (argv differs from the pristine built-in). Only then does the
    snapshot shell out; the built-in fallback is native since 0.5.0."""
    builtin = (_BUILTIN_CONSOLE_ADAPTER.get("commands") or {}).get(name) or []
    current = CONSOLE_COMMANDS.get(name)
    if current is None:
        return False
    return [str(p) for p in current] != [str(p) for p in builtin]


# ---- Native (no-subprocess) built-in probes ---------------------------------- #

def _gate_passed_data(gate: Any) -> bool:
    return bool(isinstance(gate, dict)
                and gate.get("status") in {"passed", "passed-with-acknowledged-baseline"}
                and gate.get("authoritative") is True)


def compute_frontier_native(repo: Path) -> dict[str, Any]:
    """Native replica of `engine/dag.sh next-areas` (the default `make
    orch-next-areas` probe). Semantics mirror dag.sh exactly: iterate registry
    nodes in file order; a node with a passed+authoritative gate is done; a
    node with a blocked+authoritative gate is excluded from the frontier; a
    node whose dependsOn are ALL gate-passed joins the frontier. Missing or
    unreadable gate JSON reads as not-passed — fail-closed for the node, never
    an exception for the snapshot. Returns {"frontier": [...]} plus
    "allComplete": true when every node is gate-passed (shape-compatible with
    parse_next_areas output)."""
    repo = repo.resolve()
    by_id = load_dag_registry(repo).get("by_id") or {}
    gates: dict[str, Any] = {}

    def gate(node_id: str) -> Any:
        if node_id not in gates:
            try:
                gates[node_id] = _load_gate_for_node(repo, node_id)
            except Exception:
                gates[node_id] = None
        return gates[node_id]

    def passed(node_id: str) -> bool:
        return _gate_passed_data(gate(node_id))

    frontier: list[dict[str, Any]] = []
    all_complete = bool(by_id)
    for node_id, node in by_id.items():
        if passed(node_id):
            continue
        all_complete = False
        g = gate(node_id)
        if isinstance(g, dict) and g.get("status") == "blocked" and g.get("authoritative") is True:
            continue
        deps = node.get("dependsOn")
        deps = deps if isinstance(deps, list) else []
        if all(passed(str(dep)) for dep in deps):
            entry: dict[str, Any] = {"node": node_id}
            for key in ("stage", "area", "layer", "kind", "requiredCompletion"):
                entry[key] = node.get(key)
            frontier.append(entry)
    out: dict[str, Any] = {"frontier": frontier}
    if all_complete:
        out["allComplete"] = True
    return out


_DAG_REQUIRED_NODE_FIELDS = ("id", "stage", "area", "layer", "kind", "dependsOn", "requiredCompletion")


def validate_dag_native(repo: Path) -> dict[str, Any]:
    """Native replica of the structural checks in `engine/dag.sh validate-dag`
    (required node fields present, unique ids, every dependsOn references a
    known id). Returns a run_command-shaped dict so the UI's `.ok` chip logic
    is untouched."""
    errors: list[str] = []
    data = read_json((repo / DAG_REL), None)
    nodes: list[Any] = []
    if not isinstance(data, dict):
        errors.append(f"dag file missing or unreadable: {DAG_REL}")
    else:
        raw_nodes = data.get("nodes")
        if not isinstance(raw_nodes, list) or not raw_nodes:
            errors.append("dag.nodes must be a non-empty array")
        else:
            nodes = raw_nodes
    seen: set[str] = set()
    for idx, node in enumerate(nodes):
        if not isinstance(node, dict):
            errors.append(f"node[{idx}] must be an object")
            continue
        missing = sorted(set(_DAG_REQUIRED_NODE_FIELDS) - set(node))
        if missing:
            errors.append(f"node[{idx}] missing required fields: {', '.join(missing)}")
        node_id = str(node.get("id") or "")
        if not node_id:
            errors.append(f"node[{idx}] has empty id")
            continue
        if node_id in seen:
            errors.append(f"duplicate node id: {node_id}")
        seen.add(node_id)
    for node in nodes:
        if not isinstance(node, dict):
            continue
        deps = node.get("dependsOn")
        for dep in (deps if isinstance(deps, list) else []):
            if str(dep) not in seen:
                errors.append(f"unknown dependency for {node.get('id')}: {dep}")
    ok = not errors
    return {"ok": ok, "exit": 0 if ok else 1, "stdout": "ok" if ok else "; ".join(errors),
            "stderr": "", "cmd": ["native:validate-dag"], "native": True}


def collect_status_native(repo: Path, origin_state: Any) -> dict[str, Any]:
    """Native replacement for the default `make orch-status` probe: the parsed
    operator STATUS.md + circuit breaker + the origin-state already loaded by
    collect_snapshot, in the same run_command envelope shape (native: True)."""
    status_path = repo / STATUS_REL
    try:
        parsed = parse_status_md(status_path.read_text(errors="replace"))
    except OSError:
        parsed = parse_status_md("")
    circuit = read_json(repo / CIRCUIT_REL, {}) or {}
    packets = origin_state.get("packets") if isinstance(origin_state, dict) else None
    lines = [
        f"branch: {parsed.get('branch') or '?'} @ {parsed.get('headSha') or '?'}",
        f"iteration: {parsed.get('iteration')}",
        f"ready tasks: {parsed.get('readyTasks')}",
        f"active leases: {parsed.get('activeLeases')}",
        f"imported packets: {parsed.get('importedPackets')}",
        f"integrations (lifetime): {parsed.get('integrationsLifetime')}",
        f"consecutive failures: {circuit.get('consecFails')}",
    ]
    return {
        "ok": True, "exit": 0, "stdout": "\n".join(lines), "stderr": "",
        "cmd": ["native:status"], "native": True,
        "data": {
            **parsed,
            "circuit": circuit if isinstance(circuit, dict) else {},
            "packets": packets if isinstance(packets, dict) else {},
        },
    }


def collect_gates_summary(repo: Path) -> dict[str, Any]:
    """Plan-wide gate progress from the gate files + registry (replaces the
    hardwired gateD0/gateD1 subprocess probes): passed/total across every
    registry node plus the per-node gate status ("absent" when no file), plus
    `cohorts` splitting that passed set into historical accepted-as-done
    evidence and what the current campaign earned (PMGO-002)."""
    registry_ids = list(load_dag_registry(repo).get("by_id") or {})
    records = _all_gate_records(repo)
    by_node = {node_id: str((records.get(node_id) or {}).get("status") or "absent")
               for node_id in registry_ids}
    return {
        "passed": sum(1 for s in by_node.values() if s in SUCCESSFUL_GATE_STATUSES),
        "total": len(registry_ids),
        "byNode": by_node,
        "cohorts": _cohort_progress((_gate_cohort(records.get(n)) for n in registry_ids),
                                    len(registry_ids)),
    }


def collect_resource_plan_native(repo: Path) -> dict[str, Any]:
    """Read-only adaptive worktree-capacity calculation for console APIs.

    Reuse the most recent reconcile estimate when present, but always combine
    it with current free space so the operator sees today's schedulable slots.
    """
    defaults = {
        "configuredSlots": 3,
        "reserveBytes": 2147483648,
        "estimatedWorktreeBytes": 268435456,
    }
    config = read_json(repo / "singular.config.json", {}) or {}
    resources = config.get("resources") if isinstance(config, dict) else {}
    resources = resources if isinstance(resources, dict) else {}
    config_env = config.get("env") if isinstance(config, dict) else {}
    config_env = config_env if isinstance(config_env, dict) else {}

    def integer(value: Any, fallback: int, *, positive: bool = False) -> int:
        if isinstance(value, bool):
            return fallback
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return fallback
        if parsed < (1 if positive else 0):
            return fallback
        return parsed

    configured = integer(
        os.environ.get(
            "SINGULAR_MAX_CONCURRENT",
            config_env.get(
                "SINGULAR_MAX_CONCURRENT",
                resources.get("maxConcurrent", defaults["configuredSlots"]),
            ),
        ),
        defaults["configuredSlots"],
    )
    reserve = integer(
        os.environ.get(
            "SINGULAR_DISK_RESERVE_BYTES",
            config_env.get(
                "SINGULAR_DISK_RESERVE_BYTES",
                resources.get("diskReserveBytes", defaults["reserveBytes"]),
            ),
        ),
        defaults["reserveBytes"],
    )
    estimate = integer(
        os.environ.get(
            "SINGULAR_ESTIMATED_WORKTREE_BYTES",
            config_env.get(
                "SINGULAR_ESTIMATED_WORKTREE_BYTES",
                resources.get(
                    "estimatedWorktreeBytes", defaults["estimatedWorktreeBytes"]
                ),
            ),
        ),
        defaults["estimatedWorktreeBytes"],
        positive=True,
    )
    source = "live-config"

    runs_dir = state_path(repo, "runs")
    latest: Path | None = None
    try:
        latest = max(
            runs_dir.glob("*/resource-plan.json"),
            key=lambda path: path.stat().st_mtime_ns,
            default=None,
        )
    except OSError:
        latest = None
    prior = read_json(latest, None) if latest else None
    if isinstance(prior, dict) and prior.get("schema") == "singular.orchestration.resource-plan.v0":
        configured = integer(prior.get("configuredSlots"), configured)
        reserve = integer(prior.get("reserveBytes"), reserve)
        estimate = integer(
            prior.get("estimatedWorktreeBytes"), estimate, positive=True
        )
        source = "latest-reconcile"

    try:
        free = shutil.disk_usage(repo).free
    except OSError:
        free = 0
    affordable = max(0, free - reserve) // estimate
    effective = min(configured, affordable)
    if effective == configured:
        reason = "configured-capacity-available"
    elif effective == 0:
        reason = "insufficient-disk-after-reserve"
    else:
        reason = "disk-limited-concurrency"
    return {
        "schema": "singular.orchestration.resource-plan.v0",
        "configuredSlots": configured,
        "effectiveSlots": effective,
        "freeBytes": free,
        "reserveBytes": reserve,
        "estimatedWorktreeBytes": estimate,
        "affordableSlots": affordable,
        "reason": reason,
        "source": source,
        **({"recordRef": str(latest)} if latest else {}),
    }


def collect_snapshot(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    tasks = collect_tasks(repo)
    leases = collect_leases(repo)
    l1_leases = collect_l1_leases(repo)
    processes = collect_processes()
    origin_state = read_json(state_path(repo, "origin-state.json"), {})
    # Built-in probes are NATIVE (no subprocess); an adapter that explicitly
    # configures a probe command keeps the subprocess path (escape hatch).
    if probe_command_overridden("status"):
        status = run_command(repo, console_command("status"))
    else:
        status = collect_status_native(repo, origin_state)
    if probe_command_overridden("validateDag"):
        validate_dag = run_command(repo, console_command("validateDag"))
    else:
        validate_dag = validate_dag_native(repo)
    next_areas_raw = None
    if probe_command_overridden("nextAreas"):
        next_areas_raw = run_command(repo, console_command("nextAreas"))
        next_areas_parsed = parse_next_areas(next_areas_raw.get("stdout", ""))
    else:
        next_areas_parsed = compute_frontier_native(repo)
    next_area_raw = None
    if probe_command_overridden("nextArea"):
        next_area_raw = run_command(repo, console_command("nextArea"))
        next_area = parse_next_area(next_area_raw.get("stdout", ""))
    else:
        # Same dict shape parse_next_area produced: the first frontier entry,
        # or {"allComplete": true} when every node is gate-passed.
        frontier = next_areas_parsed.get("frontier") or []
        if frontier and isinstance(frontier[0], dict):
            next_area = dict(frontier[0])
        elif next_areas_parsed.get("allComplete"):
            next_area = {"allComplete": True}
        else:
            next_area = {}
    drift_cmd = run_command(
        repo,
        ["git", "rev-list", "--left-right", "--count", f"origin/{TARGET_BRANCH}...{TARGET_BRANCH}"],
    )
    drift_left = drift_right = 0
    if drift_cmd["ok"]:
        parts = drift_cmd["stdout"].split()
        if len(parts) >= 2:
            drift_left, drift_right = int(parts[0]), int(parts[1])
    origin_state_compact = {}
    if isinstance(origin_state, dict):
        for key in (
            "schema", "runId", "generatedAt", "branch", "headSha", "targetBranch",
            # taskCounts was missing from this passthrough, which is why the dock
            # took "ready" from the engine's projection but "active" from the
            # console's own re-derivation — two vintages of two different
            # definitions, and one task rendered as "1 active · 1 ready".
            "packets", "activeLeases", "extraWorktrees", "readyTasks", "taskCounts",
        ):
            if key in origin_state:
                origin_state_compact[key] = origin_state[key]
    lock_dir = state_path(repo, "locks")
    locks = sorted(str(path) for path in lock_dir.glob("*")) if lock_dir.exists() else []
    stale_locks = [path for path in locks if "stale" in Path(path).name]
    active_origin_lock = (lock_dir / "origin.lock.json").exists()

    l2_tasks = build_l2_tasks(tasks, leases, processes)
    frontier_areas = [f.get("area") for f in next_areas_parsed.get("frontier", []) if isinstance(f, dict)]
    l1_areas = build_l1_areas(repo, l2_tasks, l1_leases, frontier_areas)
    stop_present = state_path(repo, "STOP").exists()
    agents = build_agents(
        repo, l2_tasks, l1_areas, stop_present, processes,
        active_origin_lock, stale_locks, origin_state if isinstance(origin_state, dict) else {},
    )

    state_totals: dict[str, int] = {}
    for task in l2_tasks:
        state_totals[task["state"]] = state_totals.get(task["state"], 0) + 1

    snapshot: dict[str, Any] = {
        "schema": "singular.codex.orchestration-graph.v1",
        "generatedAt": utc_now(),
        "repo": str(repo),
        "targetBranch": TARGET_BRANCH,
        "stop": {"present": stop_present},
        "runtime": {
            "pidFiles": collect_pid_files(repo),
            "processes": processes,
            "worktrees": collect_worktrees(repo),
        },
        "locks": {"files": locks, "staleLocks": stale_locks, "activeOriginLock": active_origin_lock},
        "git": {
            "status": run_command(repo, ["git", "status", "--short", "--branch"]),
            "drift": {"left": drift_left, "right": drift_right, "raw": drift_cmd},
        },
        "orchestration": {
            "status": status,
            "validateDag": validate_dag,
            "gates": collect_gates_summary(repo),
            "nextArea": next_area,
            "nextAreas": next_areas_parsed,
            "originState": origin_state_compact,
        },
        "events": parse_events(state_path(repo, EVENTS_LOG_REL), 40),
        # autonomateTail is gone: it shipped 80 raw loop-stdout lines on every
        # 10s /api/state poll with zero consumers anywhere in plugin/assets or
        # plugin/adapters (verified by grep). The same log is streamable on
        # demand — and redacted — via /api/session/origin.
        "disk": collect_disk(repo),
        "resources": collect_resource_plan_native(repo),
        "l1Areas": l1_areas,
        "l1Leases": l1_leases,
        "l2Tasks": l2_tasks,
        "agents": agents,
        "loop": _snapshot_loop_liveness(repo),
        "summary": {
            "tasksTotal": len(tasks),
            "leasesTotal": len(leases),
            "packetsInbox": origin_state.get("packets", {}).get("inbox") if isinstance(origin_state, dict) else None,
            "packetsImported": origin_state.get("packets", {}).get("imported") if isinstance(origin_state, dict) else None,
            "stateCounts": state_totals,
            # One block carrying BOTH numbers the dock renders, so it never
            # composes "active" from here with "ready" from somewhere else. See
            # _task_projection for why that composition was the bug.
            "taskCounts": _task_projection(origin_state, state_totals),
            "activeAgents": len(agents["l2"]),
            "l1PlannersActive": sum(1 for area in l1_areas if area.get("l1Active")),
            "frontierCount": len(next_areas_parsed.get("frontier", [])),
        },
    }
    # Raw subprocess envelopes exist only on the adapter-configured path; the
    # native path has no subprocess output to carry.
    if next_area_raw is not None:
        snapshot["orchestration"]["nextAreaRaw"] = next_area_raw
    if next_areas_raw is not None:
        snapshot["orchestration"]["nextAreasRaw"] = next_areas_raw
    snapshot["health"] = classify_health(snapshot)
    return snapshot


# --------------------------------------------------------------------------- #
# Live session terminal (read-only observer)                                   #
# --------------------------------------------------------------------------- #
#
# The session APIs power the always-on terminal in the console work dock. They
# are a strict read-only OBSERVER: they tail Codex/orchestration log files and
# parse durable records. They never write, and — unlike collect_snapshot — they
# run NO subprocesses (no make/git/ps). Liveness is inferred from lease status
# plus log-file freshness, so a single /api/sessions call is pure filesystem I/O
# and stays well under the 2s client poll cadence even with hundreds of run dirs.

SESSIONS_TTL_SECONDS = 2.0
SESSION_SCAN_LIMIT = 120         # most-recent run dirs classified per discovery
SESSION_RETURN_LIMIT = 16        # default sessions returned (origin always included)
SESSION_RETURN_HARD_MAX = 40     # ?limit= ceiling; discovery builds up to this many
SESSION_LIVE_WINDOW = 90.0       # log mtime within N s => the stream is "live"
SESSION_PEEK_BYTES = 16384       # tail bytes read to summarize a session's last line
SESSION_LOG_MAX_BYTES = 262144   # cap per /api/session read (tail or forward window)
SESSION_LINE_LIMIT_MAX = 2000
SESSION_LINE_LIMIT_DEFAULT = 500
CMD_OUTPUT_CAP = 1400            # chars of a command's output tail retained
AGENT_MSG_CAP = 6000             # chars of an agent/reasoning message retained

# A session id is either the literal "origin" feed or a run-dir basename. The
# pattern only guarantees a traversal-safe basename (no '/', no leading dot so
# '..' is rejected); the real safety guard is the resolved-path containment check
# in _resolve_session_log (the dir must resolve to a direct child of runs/). This
# stays decoupled from the orchestrator's run-dir naming (RUN-/ORIGIN- today).
SESSION_ID_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._-]*$")
INTEGRATE_RE = re.compile(r"-integrate-(TASK-\d+)$")
TASK_IN_TEXT_RE = re.compile(r"TASK-\d+")
# Lease statuses that mean a worker is still mid-flight (vs. terminal/awaiting).
WORKER_ACTIVE_LEASE = {"running", "dispatched", "active"}
# Plain (non-Codex) per-run logs worth streaming as secondary panes.
PLAIN_LOG_NAMES = ("gate-check.log", "scope-check.log", "secret-scan.log")
# Codex thread logs, in role-priority order (primary stream first).
CODEX_LOG_NAMES = (("worker-codex.log", "worker"), ("auditor-codex.log", "auditor"),
                   ("planner-codex.log", "planner"), ("decider-codex.log", "decider"),
                   ("assistant-codex.log", "assistant"), ("supervisor-codex.log", "supervisor"))
# Rendered per-run prompt files surfaced as secondary session panes (AFTER the
# logs — logs stay the primary stream). decider-prompt-*.md is matched by prefix
# (its suffix carries the recovery reason).
PROMPT_FILE_NAMES = ("l2-prompt.md", "l2-active-prompt.md", "l2-repair-prompt.md",
                     "planner-prompt.md", "auditor-prompt.md", "auditor-active-prompt.md",
                     "reaudit-prompt.md", "auditor-reaudit-prompt.md",
                     "ask-prompt.md", "supervisor-prompt.md")
# 0.10.0 supervisor/ask session files, ALSO pinned outside the adapter surface:
# an adapter's logFileMaps replaces CODEX_LOG_NAMES/PROMPT_FILE_NAMES wholesale,
# so a pre-0.10 engine-shipped or repo adapter snapshot would silently strip the
# additions above and break assistant-session streaming. _session_log_files
# unions these back in (deduped) so ASK-/SUP- runs stream regardless of adapter age.
ASSISTANT_LOG_NAMES = (("assistant-codex.log", "assistant"),
                       ("supervisor-codex.log", "supervisor"))
ASSISTANT_PROMPT_NAMES = ("ask-prompt.md", "supervisor-prompt.md")
# "<iso>  LEVEL  message" — the shape Codex emits for its plain stderr lines.
ISO_LEVEL_LINE_RE = re.compile(r"^(\d{4}-\d\d-\d\dT[\d:.]+Z)\s+([A-Z]+)\s+(.*)$")
# Codex plugin/skill loader chatter — hundreds of identical WARN lines per run that
# carry no orchestration signal. Dropped from parsed view; raw view keeps everything.
LOG_NOISE_RE = re.compile(r"codex_core_(plugins::manifest|skills::loader)")
MODEL_CACHE_WARNING_RE = re.compile(
    r"(supports_reasoning_summaries|model[-_ ]cache.*(?:schema|incompat|unknown field))",
    re.IGNORECASE,
)
OPTIONAL_MCP_WARNING_RE = re.compile(
    r"(mcp|plugin|connector).*(invalid_grant|unavailable|failed to (?:start|load|initialize))",
    re.IGNORECASE,
)
INFRA_WARNING_RE = re.compile(
    r"(inconclusive-infrastructure|read-only file system|cache.*permission denied)",
    re.IGNORECASE,
)
# planner-prompt.md header fields we surface as session identity.
_PLANNER_AREA_RE = re.compile(r"Area Planner for area `([^`]+)`")
_PLANNER_NODE_RE = re.compile(r"Executable DAG node:\s*`([^`]+)`")
_PLANNER_STAGE_RE = re.compile(r"^Stage:\s*`([^`]+)`", re.MULTILINE)
_PLANNER_LAYER_RE = re.compile(r"^Layer:\s*`([^`]+)`", re.MULTILINE)


def _safe_mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def _iso_from_mtime(ts: float) -> str:
    if not ts:
        return ""
    return dt.datetime.fromtimestamp(ts, dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _read_head(path: Path, max_bytes: int = 4096) -> str:
    try:
        with path.open("rb") as fh:
            return fh.read(max_bytes).decode("utf-8", errors="replace")
    except OSError:
        return ""


def _diagnostic(category: str, severity: str, *, expected: bool = False,
                impact: str = "none", source: str = "console",
                dedupe_key: str | None = None) -> dict[str, Any]:
    data: dict[str, Any] = {
        "category": category,
        "severity": severity,
        "expected": expected,
        "impact": impact,
        "source": source,
    }
    if dedupe_key:
        data["dedupeKey"] = dedupe_key
    return data


def _event_diagnostic(event_type: str) -> dict[str, Any]:
    event = event_type.lower()
    if "baseline" in event:
        return _diagnostic("acknowledged-baseline", "warning", expected=True,
                           impact="non-blocking", source="orchestrator")
    if ".infra" in event or "infrastructure" in event:
        return _diagnostic("infrastructure-inconclusive", "warning",
                           impact="retryable", source="orchestrator")
    if "provider" in event and ("error" in event or "failed" in event):
        return _diagnostic("provider-failure", "error", impact="blocking",
                           source="provider")
    if re.search(r"(?:^|[._])(?:failed|invalid|rejected)(?:[._]|$)", event):
        return _diagnostic("orchestration-failure", "error", impact="blocking",
                           source="orchestrator")
    return _diagnostic("info", "info", source="orchestrator")


def classify_codex_record(obj: dict[str, Any]) -> dict[str, Any] | None:
    """Map one Codex thread JSON record (or an orchestration event line) to a
    compact terminal line. Pure — no I/O, no time. Returns None to drop a record
    (e.g. an item.started agent_message which has no text yet)."""
    schema = obj.get("schema")
    if schema == "singular.orchestration.provider-error.v0":
        retryable = bool(obj.get("retryable"))
        return {
            "kind": "diagnostic",
            "text": str(obj.get("excerpt") or obj.get("kind") or "provider error"),
            "providerError": obj,
            "diagnostic": _diagnostic(
                "provider-failure", "warning" if retryable else "error",
                impact="retryable" if retryable else "blocking",
                source=str(obj.get("provider") or "provider"),
                dedupe_key=f"provider:{obj.get('provider')}:{obj.get('kind')}:{obj.get('providerCode')}",
            ),
        }
    if schema == "singular.orchestration.gate-report.v0":
        outcome = str(obj.get("outcome") or "")
        acknowledged = outcome == "passed-with-acknowledged-baseline"
        return {
            "kind": "diagnostic",
            "text": outcome or "gate report",
            "gateReport": obj,
            "diagnostic": _diagnostic(
                "acknowledged-baseline" if acknowledged else
                "infrastructure-inconclusive" if outcome == "inconclusive-infrastructure" else
                "product-failure" if outcome == "failed-product" else "info",
                "warning" if acknowledged or outcome == "inconclusive-infrastructure" else
                "error" if outcome == "failed-product" else "info",
                expected=acknowledged,
                impact="non-blocking" if acknowledged else
                "retryable" if outcome == "inconclusive-infrastructure" else
                "blocking" if outcome == "failed-product" else "none",
                source="gate",
            ),
        }
    rtype = obj.get("type")
    if rtype in ("item.started", "item.completed"):
        item = obj.get("item") if isinstance(obj.get("item"), dict) else {}
        itype = item.get("type")
        done = rtype == "item.completed"
        if itype == "agent_message":
            if not done:
                return None  # the text only arrives on completion
            text = str(item.get("text") or "").strip()
            return {"kind": "message", "role": "agent", "id": item.get("id"),
                    "text": text[:AGENT_MSG_CAP], "truncated": len(text) > AGENT_MSG_CAP}
        if itype == "command_execution":
            out = str(item.get("aggregated_output") or "")
            exit_code = item.get("exit_code")
            failed = isinstance(exit_code, int) and exit_code != 0
            return {"kind": "command", "id": item.get("id"),
                    "command": str(item.get("command") or ""),
                    "status": item.get("status") or ("completed" if done else "in_progress"),
                    "exitCode": exit_code,
                    "output": out[-CMD_OUTPUT_CAP:], "outputTruncated": len(out) > CMD_OUTPUT_CAP,
                    "diagnostic": _diagnostic(
                        "product-failure" if failed else "info",
                        "error" if failed else "info",
                        impact="blocking" if failed else "none",
                        source="command")}
        if itype == "file_change":
            changes = [{"path": c.get("path"), "kind": c.get("kind")}
                       for c in (item.get("changes") or []) if isinstance(c, dict)]
            return {"kind": "file", "id": item.get("id"),
                    "status": item.get("status") or ("completed" if done else "in_progress"),
                    "changes": changes}
        if itype == "reasoning":
            if not done:
                return None
            text = str(item.get("text") or "").strip()
            return {"kind": "reasoning", "id": item.get("id"), "text": text[:AGENT_MSG_CAP]} if text else None
        return {"kind": "meta", "text": str(itype or "item")} if done else None
    if rtype == "turn.completed":
        usage = obj.get("usage") if isinstance(obj.get("usage"), dict) else {}
        inp = usage.get("input_tokens")
        tok = usage.get("output_tokens")
        return {
            "kind": "meta",
            "text": "turn complete"
                    + (f" · {inp} in tok" if inp is not None else "")
                    + (f" · {tok} out tok" if tok is not None else ""),
            "usage": {
                "inputTokens": inp,
                "cachedInputTokens": usage.get("cached_input_tokens"),
                "outputTokens": tok,
            },
            "diagnostic": _diagnostic("info", "info", source="provider"),
        }
    if rtype == "turn.started":
        return {"kind": "meta", "text": "turn started"}
    if rtype == "thread.started":
        return {"kind": "meta", "text": "thread started"}
    # An orchestration event line (events.ndjson): {ts,type,message,data}.
    msg = obj.get("message")
    if rtype and msg is not None:
        data = obj.get("data") if isinstance(obj.get("data"), dict) else {}
        diag = data.get("diagnostic") if isinstance(data.get("diagnostic"), dict) else None
        return {"kind": "event", "ts": obj.get("ts"), "eventType": str(rtype),
                "text": str(msg), "diagnostic": diag or _event_diagnostic(str(rtype))}
    if rtype:
        return {"kind": "meta", "text": str(rtype)}
    return None


def _plain_log_diagnostic(line: str, level: str | None = None) -> dict[str, Any]:
    if MODEL_CACHE_WARNING_RE.search(line):
        return _diagnostic(
            "optional-dependency-warning", "warning", impact="non-blocking",
            source="model-cache", dedupe_key="optional:model-cache-schema",
        )
    if OPTIONAL_MCP_WARNING_RE.search(line):
        return _diagnostic(
            "optional-dependency-warning", "warning", impact="non-blocking",
            source="capability", dedupe_key="optional:mcp-startup",
        )
    if INFRA_WARNING_RE.search(line):
        return _diagnostic(
            "infrastructure-inconclusive", "warning", impact="retryable",
            source="runtime",
        )
    if level in {"ERROR", "FATAL"}:
        return _diagnostic("orchestration-failure", "error", impact="blocking",
                           source="runtime")
    return _diagnostic("info", "warning" if level == "WARN" else "info",
                       source="runtime")


def _dedupe_diagnostics(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    indexes: dict[str, int] = {}
    for record in records:
        diagnostic = record.get("diagnostic")
        key = diagnostic.get("dedupeKey") if isinstance(diagnostic, dict) else None
        if not key:
            output.append(record)
            continue
        if key in indexes:
            current = output[indexes[key]]
            current["count"] = int(current.get("count") or 1) + 1
            continue
        record["count"] = 1
        indexes[key] = len(output)
        output.append(record)
    return output


def parse_log_lines(raw_lines: list[str], raw: bool = False) -> list[dict[str, Any]]:
    """Parse raw log lines into terminal records. JSON Codex/event records become
    typed rows; everything else is a plain `log` row (ISO/level split when present).
    With raw=True every line is returned verbatim as a `log` row. Pure."""
    out: list[dict[str, Any]] = []
    for line in raw_lines:
        line = line.rstrip("\r\n")
        if not line.strip():
            continue
        if not raw and line.lstrip()[:1] == "{":
            try:
                obj = json.loads(line.lstrip())
            except json.JSONDecodeError:
                obj = None
            if isinstance(obj, dict):
                rec = classify_codex_record(obj)
                if rec is not None:
                    out.append(rec)
                continue
        if not raw and LOG_NOISE_RE.search(line):
            continue  # codex plugin/skill loader chatter — no signal in parsed view
        m = ISO_LEVEL_LINE_RE.match(line)
        if m and not raw:
            out.append({"kind": "log", "ts": m.group(1), "level": m.group(2),
                        "text": m.group(3),
                        "diagnostic": _plain_log_diagnostic(m.group(3), m.group(2))})
        else:
            out.append({"kind": "log", "text": line,
                        "diagnostic": _plain_log_diagnostic(line)})
    return out if raw else _dedupe_diagnostics(out)


def read_log_window(path: Path, cursor: int | None, max_bytes: int = SESSION_LOG_MAX_BYTES) -> dict[str, Any]:
    """Read a bounded window of a log file for incremental streaming.

    cursor None / out-of-range -> tail the last ``max_bytes`` (initial load / reset).
    cursor in range            -> forward read of up to ``max_bytes`` new bytes.
    Only COMPLETE (newline-terminated) lines are consumed; a trailing partial line
    is left for the next poll. Returns raw line strings plus the next byte cursor.
    A pathologically long single line is skipped to keep the cursor from stalling."""
    try:
        size = path.stat().st_size
    except OSError:
        return {"rawLines": [], "cursor": 0, "size": 0, "reset": cursor not in (None, 0)}
    reset = False
    if cursor is None or cursor < 0 or cursor > size:
        reset = cursor is not None  # an explicit but stale/too-large cursor was reset
        start = max(0, size - max_bytes)
        try:
            with path.open("rb") as fh:
                fh.seek(start)
                if start > 0:
                    start += len(fh.readline())  # drop the partial leading line
                data = fh.read()
        except OSError:
            return {"rawLines": [], "cursor": size, "size": size, "reset": reset}
    else:
        start = cursor
        try:
            with path.open("rb") as fh:
                fh.seek(start)
                data = fh.read(max_bytes)
        except OSError:
            return {"rawLines": [], "cursor": start, "size": size, "reset": False}
    nl = data.rfind(b"\n")
    if nl == -1:
        if len(data) >= max_bytes:  # oversized line with no newline: skip past it
            return {"rawLines": ["[line too long — truncated by console]"],
                    "cursor": start + len(data), "size": size, "reset": reset}
        return {"rawLines": [], "cursor": start, "size": size, "reset": reset}
    # Split strictly on \n — str.splitlines() also breaks on U+2028/U+2029/NEL/FF,
    # which can appear unescaped inside a Codex JSON payload and split one physical
    # line (one JSON record) into several bogus fragments. parse_log_lines strips \r.
    complete = data[:nl + 1].decode("utf-8", errors="replace")
    return {"rawLines": complete[:-1].split("\n"), "cursor": start + nl + 1, "size": size, "reset": reset}


def _session_log_files(run_dir: Path) -> list[dict[str, str]]:
    """Streamable logs present in a run dir, primary (Codex thread) first. The
    0.10.0 assistant/supervisor names are unioned in from their pinned constants
    (deduped) so an older adapter's wholesale logFileMaps override cannot strip
    them from ASK-/SUP- run dirs."""
    files: list[dict[str, str]] = []
    seen: set[str] = set()
    for name, role in (*CODEX_LOG_NAMES, *ASSISTANT_LOG_NAMES):
        if name not in seen and (run_dir / name).is_file():
            seen.add(name)
            files.append({"name": name, "kind": "codex", "role": role})
    for name in PLAIN_LOG_NAMES:
        if (run_dir / name).is_file():
            files.append({"name": name, "kind": "plain"})
    # Rendered prompts come AFTER the logs so the log stream stays primary; they
    # are accepted by _resolve_session_log (which validates against this list).
    for name in (*PROMPT_FILE_NAMES, *ASSISTANT_PROMPT_NAMES):
        if name not in seen and (run_dir / name).is_file():
            seen.add(name)
            files.append({"name": name, "kind": "prompt"})
    for path in sorted(run_dir.glob("decider-prompt-*.md")):
        if path.is_file():
            files.append({"name": path.name, "kind": "prompt"})
    return files


def _parse_planner_prompt(text: str) -> dict[str, str | None]:
    def grab(rx: re.Pattern[str]) -> str | None:
        m = rx.search(text)
        return m.group(1) if m else None
    return {"area": grab(_PLANNER_AREA_RE), "node": grab(_PLANNER_NODE_RE),
            "stage": grab(_PLANNER_STAGE_RE), "layer": grab(_PLANNER_LAYER_RE)}


def _task_id_from_prompt(run_dir: Path, names: set[str]) -> str | None:
    for name in ("l2-active-prompt.md", "l2-prompt.md", "l2-repair-prompt.md", "auditor-prompt.md"):
        if name in names:
            m = TASK_IN_TEXT_RE.search(_read_head(run_dir / name, 2048))
            if m:
                return m.group(0)
    return None


def _worker_state(lease_status: str | None, pkt_status: str | None, fresh: bool, worktree_exists: bool) -> str:
    """Map durable worker signals to the same state vocabulary the UI already uses.
    A deployed worker holding a running lease counts as active while a worktree
    backs it (mirrors derive_task_state) — a long quiet model turn must not read
    as stale; only a vanished worktree and a silent log do."""
    s = str(lease_status or "").lower()
    if s in BLOCKED_STATUSES:
        return "blocked"
    if s in FAILED_STATUSES:
        return "failed"
    if s in AWAITING_STATUSES:  # 'accepted' — worker done, L1 reviewing
        return "awaiting"
    if s in DONE_STATUSES or s == "superseded":  # superseded = replaced run, terminal/historical
        return "integrated"
    if s in WORKER_ACTIVE_LEASE:
        return "active" if (worktree_exists or fresh) else "stale"
    # No / unknown lease — lean on the packet status and freshness.
    p = str(pkt_status or "").lower()
    if p in ("needs-review", "accepted"):
        return "awaiting"
    if p == "blocked":
        return "blocked"
    if fresh:
        return "active"
    return "awaiting" if pkt_status else "stale"


def _worker_phase(names: set[str], pkt_status: str | None) -> str:
    if "gate-check.json" in names:
        return "gate"
    if "audit.json" in names:
        return "audit"
    if "packet.json" in names or "last-message.json" in names:
        return "packet"
    return "working"


def _classify_run_dir(repo: Path, path: Path, name: str, mtime: float,
                      events_by_node: dict | None = None) -> dict[str, Any] | None:
    now = time.time()
    fresh = (now - mtime) < SESSION_LIVE_WINDOW
    integ = INTEGRATE_RE.search(name)
    if integ:
        session = _integration_session(path, name, mtime, fresh, integ.group(1))
        lifecycle = read_json(path / "run-status.json", None)
        if (
            isinstance(lifecycle, dict)
            and lifecycle.get("schema") == "singular.orchestration.run-status.v0"
            and lifecycle.get("runId") == name
        ):
            _apply_run_status(session, lifecycle)
        return session
    try:
        names = set(os.listdir(path))
    except OSError:
        return None
    lifecycle = read_json(path / "run-status.json", None)
    lifecycle = lifecycle if (
        isinstance(lifecycle, dict)
        and lifecycle.get("schema") == "singular.orchestration.run-status.v0"
        and lifecycle.get("runId") == name
    ) else None
    session = None
    if "worker-codex.log" in names:
        session = _worker_session(repo, path, name, mtime, fresh, names)
    elif "planner-codex.log" in names:
        # The planner's node is only known after the prompt is parsed, so hand
        # over the whole by-node map and let the session pick its own bucket.
        session = _planner_session(repo, path, name, mtime, fresh, names,
                                   node_events=events_by_node)
    elif "gate-check.log" in names or "audit.json" in names or "auditor-codex.log" in names:
        session = _gate_session(path, name, mtime, fresh, names)
    # 0.10.0 supervisor/ask run dirs (ASK-* / SUP-*): operator-initiated readonly
    # sessions, listed as kind "assistant". recommend_auto never auto-picks them.
    if "assistant-codex.log" in names or "supervisor-codex.log" in names or "ask.json" in names:
        session = _assistant_session(path, name, mtime, fresh, names)
    if lifecycle and session is None:
        session = {
            "id": name, "runId": name, "kind": "worker", "layer": "L2",
            "role": "orchestrator", "taskId": lifecycle.get("taskId"),
            "node": lifecycle.get("node"), "area": None,
            "startedAt": None, "updatedAt": lifecycle.get("updatedAt"),
            "logFiles": _session_log_files(path),
            "_mtime": mtime, "_dir": str(path),
        }
    if lifecycle and session is not None:
        _apply_run_status(session, lifecycle)
    return session


def _apply_run_status(session: dict[str, Any], status: dict[str, Any]) -> None:
    phase = str(status.get("phase") or "")
    ui_state = {
        "active": "active",
        "waiting": "awaiting",
        "completed": "integrated",
        "failed": "failed",
        "stale": "stale",
        "cancelled": "stopped",
    }.get(str(status.get("state") or ""), "stale")
    kind_role_layer = {
        "planning": ("planner", "planner", "L1"),
        "implementing": ("worker", "implementer", "L2"),
        "gating": ("audit", "gate", "L1"),
        "auditing": ("audit", "auditor", "L1"),
        "deciding": ("audit", "decider", "L1"),
        "integrating": ("integration", "integration-worker", "L1"),
        "awaiting-human": ("human-gate", "operator", "L0"),
    }
    if phase in kind_role_layer:
        session["kind"], session["role"], session["layer"] = kind_role_layer[phase]
    session.update({
        "phase": phase,
        "state": ui_state,
        "live": ui_state == "active",
        "lifecycle": status,
        "phaseStartedAt": status.get("phaseStartedAt"),
        "lastProgressAt": status.get("lastProgressAt"),
        "currentActivity": status.get("currentActivity"),
        "safeCancel": status.get("safeCancel"),
        "nextAction": status.get("nextAction"),
        "outcome": status.get("outcome"),
        "updatedAt": status.get("updatedAt") or session.get("updatedAt"),
        "implementerState": "active" if phase == "implementing" else "completed",
    })
    process = status.get("process") if isinstance(status.get("process"), dict) else {}
    if process:
        session["processType"] = process.get("type")
        session["pid"] = process.get("pid")
        session["pgid"] = process.get("pgid")
        session["startedAt"] = process.get("startedAt") or session.get("startedAt")


def _session_meta_compact(meta: dict[str, Any]) -> dict[str, Any]:
    return {k: meta.get(k) for k in ("provider", "model", "effort", "exitCode")
            if meta.get(k) is not None}


def _attach_session_meta(sess: dict[str, Any], path: Path) -> None:
    """Merge durable session-meta (singular.orchestration.session-meta.v0) into
    a session row. Flat fields mirror the implementer — the pane's primary
    agent; sessionMeta carries the per-role split for the Agents surface.
    No-op when the run wrote no meta (graceful degradation)."""
    impl = read_json(path / "session-implementer.json", None)
    rev = read_json(path / "session-reviewer.json", None)
    impl = impl if isinstance(impl, dict) else None
    rev = rev if isinstance(rev, dict) else None
    primary = impl or rev
    if primary:
        for key in ("provider", "model", "effort", "runner"):
            if primary.get(key) is not None:
                sess[key] = primary[key]
        if primary.get("exitCode") is not None:
            sess["exitCode"] = primary["exitCode"]
        if primary.get("lastUsedAttempt") is not None:
            sess["attempt"] = primary["lastUsedAttempt"]
    meta: dict[str, Any] = {}
    if impl:
        meta["implementer"] = _session_meta_compact(impl)
    if rev:
        meta["reviewer"] = _session_meta_compact(rev)
    if meta:
        sess["sessionMeta"] = meta


def _worker_session(repo: Path, path: Path, name: str, mtime: float, fresh: bool, names: set[str]) -> dict[str, Any]:
    packet = read_json(path / "last-message.json", None)
    if not isinstance(packet, dict):
        packet = read_json(path / "packet.json", None)
    packet = packet if isinstance(packet, dict) else {}
    task_id = packet.get("taskId") or _task_id_from_prompt(path, names)
    lease = read_json(state_path(repo, "leases") / f"{task_id}.json", None) if task_id else None
    lease = lease if isinstance(lease, dict) else {}
    lease_status = lease.get("status")
    pkt_status = packet.get("status")
    worktree = lease.get("worktree")
    worktree_exists = bool(worktree and Path(str(worktree)).exists())
    state = _worker_state(lease_status, pkt_status, fresh, worktree_exists)
    sess = {
        "id": name, "kind": "worker", "layer": "L2",
        "role": lease.get("owner") or packet.get("role") or "l2-developer",
        "taskId": task_id, "area": lease.get("area") or packet.get("area"),
        "runId": name, "branch": lease.get("branch") or packet.get("branch"),
        "state": state,
        "phase": _worker_phase(names, pkt_status),
        "leaseStatus": lease_status, "packetStatus": pkt_status,
        "worktree": worktree, "worktreeExists": worktree_exists,
        "startedAt": lease.get("createdAt") or packet.get("createdAt"),
        "updatedAt": lease.get("updatedAt") or _iso_from_mtime(mtime),
        "logFiles": _session_log_files(path),
        "live": state == "active",
        "_mtime": mtime, "_dir": str(path),
    }
    _attach_session_meta(sess, path)
    return sess


# Terminal dispositions for a PLANNER session. Deliberately separate from the
# lease/task vocabularies above: a planner never "integrates" anything — its
# batch is accepted or rejected. In particular `accepted` here is a batch
# disposition and must NOT be folded into DONE_STATUSES, where the same token
# already means "worker done, L1 reviewing" (see AWAITING_STATUSES).
PLANNER_TERMINAL_STATES = frozenset({"accepted", "rejected", "failed", "empty"})

# Event types that settle a planner run, newest-first precedence.
_PLANNER_REJECTED_EVENTS = ("origin.l1_import_rejected", "plan.revise_parked")
_PLANNER_FAILED_EVENTS = ("origin.l1_planner_failed", "planner.failed")
_PLANNER_EMPTY_EVENTS = ("origin.l1_no_tasks", "planner.no_tasks")
_PLANNER_ACCEPTED_EVENTS = ("planner.staged", "planner.generated")


def derive_planner_state(*, fresh: bool, has_batch: bool, critique: Any,
                         node_events: list, run_id: str) -> tuple:
    """-> (state, criticVerdict, stateReason, stateSource). Pure: no I/O, no clock.

    A planner that emitted a batch used to report `integrated` purely because
    planner-batch.json existed — so a batch the critic REJECTED painted the same
    forest green as a healthy live session.

    Two signal sources, and which one leads depends on the path taken:
      * plan-critique.json sits beside planner-batch.json, but ONLY on the
        fanout path (engine/l1-plan-node.sh sets SINGULAR_PLANNING_ARTIFACT_DIR).
        The serial reconcile path never writes one.
      * events carry the disposition on both paths, so they are load-bearing.

    Rejection wins any disagreement: the critique records the CRITIC's verdict,
    while origin.l1_import_rejected records L0's disposition, which is strictly
    later and can reject an approved batch (duplicate candidate, missing lease,
    id-rewrite failure). The louder, later truth is the operational one.
    """
    verdict = None
    if isinstance(critique, dict) and str(critique.get("schema", "")).endswith(
            "plan-critique.v0"):
        raw = critique.get("verdict")
        if raw in ("approve", "revise", "park"):
            rid = critique.get("runId")
            if not rid or rid == run_id:
                verdict = raw

    ev_state = ev_reason = None
    for ev in reversed(node_events or []):
        if not isinstance(ev, dict):
            continue
        data = ev.get("data") if isinstance(ev.get("data"), dict) else {}
        if data.get("runId") not in (None, run_id):
            continue
        etype = str(ev.get("type") or "")
        if etype in _PLANNER_REJECTED_EVENTS:
            ev_state, ev_reason = "rejected", (data.get("reason") or etype)
            break
        if etype in _PLANNER_FAILED_EVENTS:
            ev_state, ev_reason = "failed", etype
            break
        if etype in _PLANNER_EMPTY_EVENTS:
            ev_state, ev_reason = "empty", etype
            break
        if etype == "plan.critiqued":
            v = data.get("verdict")
            ev_state = "accepted" if v == "approve" else "rejected"
            ev_reason = f"critique-{v}"
            break
        if etype in _PLANNER_ACCEPTED_EVENTS:
            ev_state, ev_reason = "accepted", etype
            break

    # Rejection from either source wins.
    if ev_state == "rejected":
        return "rejected", verdict, ev_reason, "events"
    if verdict in ("revise", "park"):
        return "rejected", verdict, f"critique-{verdict}", "critique"
    if verdict == "approve" and ev_state not in ("failed", "empty"):
        return "accepted", verdict, "critique-approve", "critique"
    if ev_state:
        return ev_state, verdict, ev_reason, "events"
    # A terminal signal outranks freshness: writing the critique bumps the run
    # dir's mtime, so a just-rejected planner would otherwise read as live.
    if fresh:
        return "active", verdict, "live", "mtime"
    if has_batch:
        return "accepted", verdict, "batch-present", "artifacts"
    return "idle", verdict, None, "artifacts"


def _planner_session(repo: Path, path: Path, name: str, mtime: float, fresh: bool,
                     names: set[str], node_events: dict | None = None) -> dict[str, Any]:
    info = _parse_planner_prompt(_read_head(path / "planner-prompt.md", 4096)) if "planner-prompt.md" in names else {}
    batch = read_json(path / "planner-batch.json", None) if "planner-batch.json" in names else None
    n_tasks = len(batch.get("tasks", [])) if isinstance(batch, dict) else None
    critique = read_json(path / "plan-critique.json", None) if "plan-critique.json" in names else None
    events = (node_events or {}).get(info.get("node")) or []
    state, verdict, reason, source = derive_planner_state(
        fresh=fresh, has_batch=n_tasks is not None, critique=critique,
        node_events=events, run_id=name)
    sess = {
        "id": name, "kind": "planner", "layer": "L1", "role": "planner",
        "node": info.get("node"), "area": info.get("area"),
        "stage": info.get("stage"), "planLayer": info.get("layer"),
        "runId": name, "taskCount": n_tasks,
        "state": state, "phase": ("emitted" if n_tasks is not None else "planning"),
        "criticVerdict": verdict, "stateReason": reason, "stateSource": source,
        "terminal": state in PLANNER_TERMINAL_STATES,
        "startedAt": None, "updatedAt": _iso_from_mtime(mtime),
        "logFiles": _session_log_files(path),
        # Derived, not raw mtime freshness. This is what disarms the frontend's
        # `if (s.live) return "success"` short-circuit at the source, so a
        # settled planner can never paint as a live one.
        "live": state == "active", "_mtime": mtime, "_dir": str(path),
    }
    # Planner session-meta is durable under sessions/planner/<node>.json,
    # keyed by node with the runId it belongs to.
    node = info.get("node")
    if node:
        meta = read_json(state_path(repo, "sessions", "planner", f"{node}.json"), None)
        if isinstance(meta, dict) and (not meta.get("runId") or meta.get("runId") == name):
            for key in ("provider", "model", "effort", "runner"):
                if meta.get(key) is not None:
                    sess[key] = meta[key]
            if meta.get("exitCode") is not None:
                sess["exitCode"] = meta["exitCode"]
    _attach_session_meta(sess, path)
    return sess


def _integration_session(path: Path, name: str, mtime: float, fresh: bool, task_id: str) -> dict[str, Any]:
    gate = read_json(path / "gate-check.json", None)
    exit_code = gate.get("exitCode") if isinstance(gate, dict) else None
    if gate is None:
        state, phase = ("active" if fresh else "stale"), "gating"
    else:
        state, phase = ("integrated" if exit_code == 0 else "failed"), "gate-done"
    return {
        "id": name, "kind": "integration", "layer": "L1", "role": "integration-worker",
        "taskId": task_id, "area": None, "runId": name,
        "gateCmd": gate.get("cmd") if isinstance(gate, dict) else None, "gateExit": exit_code,
        "state": state, "phase": phase,
        "startedAt": None, "updatedAt": _iso_from_mtime(mtime),
        "logFiles": _session_log_files(path),
        "live": fresh and gate is None, "_mtime": mtime, "_dir": str(path),
    }


def _gate_session(path: Path, name: str, mtime: float, fresh: bool, names: set[str]) -> dict[str, Any]:
    audit = read_json(path / "audit.json", None) if "audit.json" in names else None
    task_id = audit.get("taskId") if isinstance(audit, dict) else _task_id_from_prompt(path, names)
    verdict = audit.get("verdict") if isinstance(audit, dict) else None
    sess = {
        "id": name, "kind": "audit", "layer": "L1", "role": "auditor",
        "taskId": task_id, "area": None, "runId": name, "verdict": verdict,
        "state": "active" if fresh else "idle", "phase": "audit",
        "startedAt": None, "updatedAt": _iso_from_mtime(mtime),
        "logFiles": _session_log_files(path),
        "live": fresh, "_mtime": mtime, "_dir": str(path),
    }
    _attach_session_meta(sess, path)
    return sess


def _assistant_session(path: Path, name: str, mtime: float, fresh: bool,
                       names: set[str]) -> dict[str, Any]:
    """A SUP-/ASK- run dir: the supervisor briefing + operator-ask sessions
    (0.10.0), listed as kind "assistant" (label = the question head for an ask, or
    "supervisor briefing"). L0-level, operator-initiated: recommend_auto never
    auto-selects it. The ask's ask.json state maps onto the shared UI vocabulary."""
    is_ask = "ask.json" in names or name.startswith("ASK-")
    if is_ask:
        ask = read_json(path / "ask.json", None)
        ask = ask if isinstance(ask, dict) else {}
        raw_state = str(ask.get("state") or "")
        question = str(ask.get("question") or "").strip()
        label = (question[:80] + "…") if len(question) > 80 else (question or "operator question")
        if raw_state == "done":
            state = "integrated"
        elif raw_state in ("error", "timeout"):
            state = "failed"
        elif raw_state in ("pending", "running"):
            state = "active" if fresh else "stale"
        else:
            state = "active" if fresh else "idle"
        role, phase = "assistant", "ask"
    else:
        label = "supervisor briefing"
        state = "active" if fresh else "idle"
        role, phase = "supervisor", "briefing"
    sess = {
        "id": name, "kind": "assistant", "layer": "L0", "role": role,
        "taskId": None, "area": None, "runId": name, "label": label,
        "state": state, "phase": phase,
        "startedAt": None, "updatedAt": _iso_from_mtime(mtime),
        "logFiles": _session_log_files(path),
        "live": fresh and state == "active",
        "_mtime": mtime, "_dir": str(path),
    }
    _attach_session_meta(sess, path)
    return sess


def _origin_session(repo: Path) -> dict[str, Any]:
    state_dir = state_path(repo)
    auto_log = resolve_autonomate_log(repo)
    mtime = max(_safe_mtime(state_dir / auto_log), _safe_mtime(state_dir / EVENTS_LOG_REL))
    fresh = (time.time() - mtime) < SESSION_LIVE_WINDOW
    stop = (state_dir / "STOP").exists()
    state = "active" if fresh else ("stopped" if stop else "idle")
    return {
        "id": "origin", "kind": "origin", "layer": "L0", "role": "origin",
        "area": None, "runId": None,
        "state": state, "phase": ("stop" if stop else "reconcile"),
        "stop": stop,
        "updatedAt": _iso_from_mtime(mtime),
        "logFiles": [{"name": EVENTS_LOG_REL, "kind": "event"},
                     {"name": auto_log, "kind": "plain"}],
        "live": fresh, "_mtime": mtime,
    }


def _mark_active_planners(repo: Path, sessions: list[dict[str, Any]]) -> None:
    """Promote planner sessions whose DAG node holds an *active* L1 lease — the
    honest "deployed planner" signal (a released/failed lease is history)."""
    leases = collect_l1_leases(repo)
    by_node = {lease.get("node"): lease for lease in leases}
    for sess in sessions:
        if sess.get("kind") != "planner":
            continue
        lease = by_node.get(sess.get("node"))
        if lease and lease.get("active"):
            # A NEWER run holding the node's lease must not resurrect an older
            # run whose batch was already accepted or rejected — otherwise a
            # re-plan repaints last round's rejection as live activity.
            lease_run = lease.get("runId")
            if sess.get("terminal") and lease_run not in (None, sess.get("runId")):
                continue
            sess["state"] = "active"
            sess["live"] = True
            sess["leaseStatus"] = lease.get("status")


def _attach_summary(repo: Path, sess: dict[str, Any]) -> None:
    """Peek the tail of a session's primary log for its last message/command —
    bounded to the returned (visible) set so /api/sessions stays cheap."""
    files = sess.get("logFiles") or []
    if not files:
        return
    base = Path(sess["_dir"]) if sess.get("_dir") else state_path(repo)
    recs = parse_log_lines(read_log_window(base / files[0]["name"], None, SESSION_PEEK_BYTES)["rawLines"])
    last_msg = last_cmd = None
    for rec in recs:
        if rec["kind"] in ("message", "event"):
            last_msg = rec.get("text")
        elif rec["kind"] == "command":
            last_cmd = rec.get("command")
    # Redact after the 240-char slice: ≤480 chars per session row, so the cost
    # is negligible even across a full /api/sessions page.
    sess["lastMessage"] = redact_secrets(last_msg[:240]) if last_msg else None
    sess["lastCommand"] = redact_secrets(last_cmd[:240]) if last_cmd else None


def discover_sessions(repo: Path) -> list[dict[str, Any]]:
    repo = repo.resolve()
    runs_root = state_path(repo, "runs")
    sessions: list[dict[str, Any]] = []
    if runs_root.is_dir():
        try:
            # follow_symlinks=False: a symlink planted in runs/ pointing outside the
            # archive must not be discovered (its log tail would leak into /api/sessions).
            # _resolve_session_log already rejects such ids via resolved-path containment.
            entries = [e for e in os.scandir(runs_root) if e.is_dir(follow_symlinks=False)]
        except OSError:
            entries = []

        def _entry_mtime(e: os.DirEntry[str]) -> float:
            try:
                return e.stat(follow_symlinks=False).st_mtime  # cached on the DirEntry
            except OSError:
                return 0.0
        # Stat each entry once (DirEntry.stat is cached) and reuse the value for both
        # the recency sort and classification — no second round of stat() syscalls.
        pairs = sorted(((e, _entry_mtime(e)) for e in entries), key=lambda p: p[1], reverse=True)
        # Read the shared events index ONCE (3s TTL, 4 MiB window) rather than
        # per run dir: planner sessions need it to tell an accepted batch from a
        # rejected one, and the serial planner path leaves no critique file.
        try:
            events_by_node = load_events_index(repo).get("by_node") or {}
        except Exception:
            events_by_node = {}
        for entry, mtime in pairs[:SESSION_SCAN_LIMIT]:
            sess = _classify_run_dir(repo, Path(entry.path), entry.name, mtime,
                                     events_by_node=events_by_node)
            if sess:
                sessions.append(sess)
    _mark_active_planners(repo, sessions)
    # Live first, then most-recent. Cap the run-dir set, then always append the
    # origin feed so the L0 fallback is never trimmed away.
    sessions.sort(key=lambda s: (0 if s.get("live") else 1, -(s.get("_mtime") or 0.0)))
    trimmed = sessions[:max(0, SESSION_RETURN_HARD_MAX - 1)]
    trimmed.append(_origin_session(repo))
    for sess in trimmed:
        _attach_summary(repo, sess)
        sess.pop("_mtime", None)
        sess.pop("_dir", None)
    return trimmed


def recommend_auto(sessions: list[dict[str, Any]]) -> dict[str, Any]:
    """Smart pane recommendation, in the priority the operator expects:
    live planners → 1-3 live workers → live gate/audit/integration → origin feed.
    When nothing is actively live, the L0 origin/event feed is the canonical view;
    recent (idle) sessions stay in the list for manual selection/pinning."""
    live = [s for s in sessions if s.get("live")]
    planners = [s for s in live if s["kind"] == "planner"]
    workers = [s for s in live if s["kind"] == "worker"]
    gates = [s for s in live if s["kind"] in ("integration", "audit")]
    if planners:
        return {"mode": "planner", "sessionIds": [s["id"] for s in planners[:3]]}
    if workers:
        return {"mode": "worker", "sessionIds": [s["id"] for s in workers[:3]]}
    if gates:
        return {"mode": "gate", "sessionIds": [s["id"] for s in gates[:2]]}
    return {"mode": "origin", "sessionIds": ["origin"]}


def _human_gate_repo_file(repo: Path, ref: Any) -> Path | None:
    if not isinstance(ref, str) or not ref:
        return None
    rel = Path(ref)
    if rel.is_absolute() or ".." in rel.parts:
        return None
    path = (repo / rel).resolve()
    try:
        path.relative_to(repo.resolve())
    except ValueError:
        return None
    return path if path.is_file() else None


def _human_gate_hash(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return ""
    return digest.hexdigest()


def collect_human_gates(repo: Path) -> list[dict[str, Any]]:
    dag = read_json(repo / "docs" / "orchestration" / "dag.v0.json", None)
    nodes = dag.get("nodes", []) if isinstance(dag, dict) else []
    by_id = {
        str(node.get("id")): node
        for node in nodes
        if isinstance(node, dict) and node.get("id")
    }
    reverse: dict[str, set[str]] = {}
    for node_id, node in by_id.items():
        for dependency in node.get("dependsOn", []):
            reverse.setdefault(str(dependency), set()).add(node_id)

    def descendants(node_id: str) -> list[str]:
        found: set[str] = set()
        queue = list(reverse.get(node_id, set()))
        while queue:
            current = queue.pop()
            if current in found:
                continue
            found.add(current)
            queue.extend(reverse.get(current, set()))
        return sorted(found)

    output = []
    for node_id, node in by_id.items():
        config = node.get("humanGate")
        if not isinstance(config, dict):
            continue
        request_ref = config.get("requestRef")
        approval_ref = config.get("approvalRef")
        request_path = _human_gate_repo_file(repo, request_ref)
        request = read_json(request_path, None) if request_path else None
        request = request if isinstance(request, dict) else {}
        if not isinstance(request_ref, str) or not isinstance(approval_ref, str):
            result = {
                "state": "invalid",
                "reason": "human-gate references must be non-empty strings",
            }
        elif VALIDATE_HUMAN_GATE is None:
            result = {
                "state": "invalid",
                "reason": "human-gate contract validator unavailable",
            }
        else:
            try:
                result = VALIDATE_HUMAN_GATE(
                    repo.resolve(),
                    request_ref,
                    approval_ref,
                    node_id,
                )
            except Exception as exc:  # fail closed; the console is an observer
                result = {
                    "state": "invalid",
                    "reason": f"human-gate validation failed: {exc}",
                }
        state = str(result.get("state") or "invalid")
        reason = str(result.get("reason") or "human-gate validation failed")
        output.append({
            "node": node_id,
            "state": state,
            "reason": reason,
            "gateId": result.get("gateId", request.get("gateId")),
            "owner": result.get("owner", request.get("requiredOwner")),
            "approvalType": request.get("approvalType"),
            "expiresAt": result.get("expiresAt", request.get("expiresAt")),
            "requestRef": request_ref,
            "approvalRef": approval_ref,
            "blockedNodes": descendants(node_id) if state != "approved" else [],
        })
    return output


def collect_sessions(repo: Path) -> dict[str, Any]:
    sessions = discover_sessions(repo)
    return {
        "schema": "singular.codex.sessions.v0",
        "generatedAt": utc_now(),
        "repo": str(repo.resolve()),
        "sessions": sessions,
        "auto": recommend_auto(sessions),
        "resources": collect_resource_plan_native(repo),
        "humanGates": collect_human_gates(repo),
    }


def slice_sessions(data: dict[str, Any], limit: int) -> dict[str, Any]:
    """Post-cache ?limit= slice: keep the first N-1 run-dir sessions + origin.
    The cache always holds the hard-max set; slicing is per request."""
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        limit = SESSION_RETURN_LIMIT
    limit = max(1, min(limit, SESSION_RETURN_HARD_MAX))
    sessions = data.get("sessions") or []
    if len(sessions) <= limit:
        return data
    out = dict(data)
    out["sessions"] = ([s for s in sessions if s.get("id") != "origin"][:limit - 1]
                       + [s for s in sessions if s.get("id") == "origin"])
    return out


def _resolve_session_log(repo: Path, session_id: str, file_name: str | None) -> tuple[Path | None, list[dict[str, str]]]:
    """Resolve (path, logFiles) for a session, validating every component against
    path traversal. file_name must be one of the session's own logFiles."""
    if session_id == "origin":
        auto_log = resolve_autonomate_log(repo)
        files = [{"name": EVENTS_LOG_REL, "kind": "event"},
                 {"name": auto_log, "kind": "plain"}]
        # Either autonomate name is accepted so pre-0.6.0 clients keep working;
        # a requested-but-absent alias falls through to the resolved log.
        accepted = {EVENTS_LOG_REL, AUTONOMATE_LOG_REL, AUTONOMATE_LOG_ENGINE, auto_log}
        chosen = file_name if file_name in accepted else EVENTS_LOG_REL
        if chosen != EVENTS_LOG_REL and not state_path(repo, chosen).is_file():
            chosen = auto_log
        path = state_path(repo) / chosen
        return (path if path.is_file() else None, files)
    if not SESSION_ID_RE.match(session_id):
        return (None, [])
    runs_root = state_path(repo, "runs").resolve()
    run_dir = (runs_root / session_id).resolve()
    if run_dir.parent != runs_root or not run_dir.is_dir():
        return (None, [])
    files = _session_log_files(run_dir)
    if not files:
        return (None, [])
    names = {f["name"] for f in files}
    chosen = file_name if file_name in names else files[0]["name"]
    path = run_dir / chosen
    return (path if path.is_file() else None, files)


def read_session(repo: Path, session_id: str, cursor: int | None, limit: int,
                 file_name: str | None, raw: bool) -> dict[str, Any] | None:
    repo = repo.resolve()
    target, log_files = _resolve_session_log(repo, session_id, file_name)
    if target is None:
        return None
    window = read_log_window(target, cursor)
    raw_lines = window["rawLines"]
    # An initial/reset read (or an explicit cursor=0 from-start request) returns a
    # full byte window; bound the work to ~limit displayable rows. Slice the raw
    # lines BEFORE parsing (headroom for dropped noise/None records), then cap
    # after — so JSON classification never runs over rows we will not return.
    initial = window["reset"] or cursor is None or cursor == 0
    if initial:
        raw_lines = raw_lines[-(limit * 3):]
    lines = parse_log_lines(raw_lines, raw=raw)
    if initial:
        lines = lines[-limit:]
    # Redact AFTER the slice, so only rows actually returned pay for it, and at
    # the single choke point both modes and /api/session/origin share.
    #
    # raw=True is redacted too, deliberately. "Raw" here means unparsed, not
    # unredacted: it is not an expert escape hatch but a default rendering path
    # (consoles/surface.js streams the supervisor pane with raw:true, and
    # viewSessionPrompt fetches every prompt with raw=1), and secret-scan.log —
    # the file most likely to contain a live credential, because the commit gate
    # quotes the offending line into it — is served through exactly this path.
    lines = redact_lines(lines)
    return {
        "schema": "singular.codex.session-lines.v0",
        "sessionId": session_id,
        "file": target.name,
        "logFiles": log_files,
        "raw": raw,
        "lines": lines,
        "cursor": window["cursor"],
        "size": window["size"],
        "reset": window["reset"],
        "generatedAt": utc_now(),
    }


# --------------------------------------------------------------------------- #
# Provenance (read-only derivation)                                            #
# --------------------------------------------------------------------------- #
#
# The provenance APIs answer "why does this node/task/gate exist" by tracing the
# durable causal chain: source-doc Stage Card -> DAG node -> planner run -> task
# -> worker run -> evidence packet -> audit -> integration commit -> gate result.
# Like the session terminal this is a STRICT READ-ONLY observer: pure filesystem
# reads of durable singular records, NO subprocesses (no make/git/ps), no writes.
# Heavy inputs (the multi-MB events.ndjson, the DAG, the plan doc) are read behind
# small single-flight TTL caches so the 2s overlay poll never re-scans them.

EVENTS_INDEX_MAX_BYTES = 4_194_304   # 4 MB tail of events.ndjson behind the shared index
EVENTS_INDEX_TTL = 3.0               # shared events-index cache window
DAG_TTL = 30.0                       # DAG + plan-doc caches (mtime/size keyed; edits invalidate)
PLANNER_RUNS_TTL = 30.0             # planner-run index cache window
OVERLAY_ROW_LIMIT_MAX = 400
OVERLAY_ROW_LIMIT_DEFAULT = 120
# A DAG node id (e.g. "D6.storage_spec", "S0.storage_substrate_base"). Traversal
# safety is enforced by registry membership in collect_node_detail, not the regex.
# Accepts both legacy "D1.contract"-style ids and slug ids ("ctx-loader") —
# real consumer DAGs use hyphenated slugs; the old pattern 400'd them.
NODE_ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,64}$")
AREA_ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")
DAG_REL = "docs/orchestration/dag.v0.json"
STAGE_DOC_REL = "docs/plan-and-dag.md"
GATES_REL = "docs/orchestration/gates"

# Canonical lifecycle order for stable origin-chain sorting. Many events share a
# one-second timestamp, so ts alone is not a total order; we break ties by phase.
CHAIN_ORDER = [
    "planner.generated", "planner.staged", "origin.dispatch", "l1.dispatch_started",
    "l1.worktree_created", "l1.worker_completed", "gate_check.completed", "l1.gate_passed",
    "l1.committed", "l1.audit_completed", "decider.verdict", "recovery.action",
    "l1.task_failed", "decision.recorded", "packet.imported", "integration.started",
    "integration.integrated",
]
CHAIN_RANK = {t: i for i, t in enumerate(CHAIN_ORDER)}

# event type -> (label template, tone, phase). Tones map onto the UI's six-tone
# system: cobalt(active) / forest(good) / amber(warn) / red(bad) / violet(integration)
# / gray(muted). Data-dependent cases (exit codes, verdicts) are refined in
# project_event(); this table is the default. advancing => the event moved real work
# forward (feeds the progressing/spinning pulse).
EVENT_MAP = {
    "origin.reconcile_started": ("Origin reconcile started", "gray", "control", False),
    "origin.reconcile_completed": ("Origin reconcile complete", "gray", "control", False),
    "origin.l1_fanout": ("L1 fanout", "cobalt", "plan", True),
    "origin.dispatch": ("Origin dispatching", "cobalt", "dispatch", True),
    "origin.dispatch_failed": ("Dispatch failed", "red", "dispatch", False),
    "origin.l1_planner_failed": ("L1 planner failed", "red", "plan", False),
    "origin.l1_import_rejected": ("L1 import rejected", "amber", "dispatch", False),
    "origin.control_state_committed": ("Control state committed", "gray", "control", False),
    "l1.dry_run": ("L1 dry run", "gray", "plan", False),
    "planner.generated": ("Task generated", "cobalt", "plan", True),
    "planner.staged": ("Task candidate staged", "cobalt", "plan", True),
    "planner.failed": ("Planner produced no output", "amber", "plan", False),
    "planner.area_complete": ("Planner: area complete", "forest", "plan", True),
    "planner.blocked": ("Planner blocked", "amber", "plan", False),
    "planner.frozen": ("Planner frozen", "amber", "plan", False),
    "packet.imported": ("Task imported", "forest", "dispatch", True),
    "packet.accepted_existing": ("Packet accepted (existing)", "forest", "dispatch", True),
    "packet.import_rejected": ("Import rejected", "amber", "dispatch", False),
    "packet.import_failed": ("Packet import failed", "red", "dispatch", False),
    "l1.dispatch_started": ("L1 dispatch started", "cobalt", "dispatch", True),
    "l1.worktree_created": ("Worker worktree created", "cobalt", "execute", True),
    "l1.worker_completed": ("Worker completed", "forest", "execute", True),
    "l1.committed": ("Worker branch committed", "forest", "execute", True),
    "l1.gate_passed": ("Regression gate passed", "forest", "gate", True),
    "gate_check.completed": ("Gate check passed", "forest", "gate", True),
    "l1.audit_completed": ("Audit accepted", "forest", "audit", True),
    "decider.verdict": ("Decider verdict", "amber", "recover", False),
    "decider.parked": ("Parked for human review", "red", "recover", False),
    "decision.recorded": ("Decision recorded", "forest", "audit", True),
    "l1.task_accepted": ("Task accepted", "forest", "audit", True),
    "l1.task_failed": ("Task failed", "red", "execute", False),
    "l1.task_terminal": ("Task ended unaccepted", "red", "recover", False),
    "recovery.action": ("Recovery action", "amber", "recover", False),
    "l1.orphan_recovered": ("Orphan lease recovered", "amber", "recover", True),
    "l1.frozen": ("L1 frozen", "amber", "recover", False),
    "l1.aborted": ("L1 aborted", "red", "recover", False),
    "integration.started": ("Integration started", "violet", "integrate", True),
    "integration.integrated": ("Integrated", "violet", "integrate", True),
    "integration.completed": ("Integration run done", "violet", "integrate", True),
    "integration.failed": ("Integration failed", "red", "integrate", False),
    "gate_promotion.started": ("Gate promotion started", "violet", "gate", True),
    "gate_promotion.completed": ("Gate promoted", "forest", "gate", True),
    "gate_promotion.blocked": ("Gate promotion blocked", "red", "gate", False),
    "push.ok": ("Pushed control state", "forest", "push", True),
    "push.failed": ("Push failed", "red", "push", False),
    "push.blocked": ("Secret-scan blocked push", "red", "push", False),
    "autonomate.started": ("Autonomous loop started", "cobalt", "control", False),
    "autonomate.stopped": ("Stopped by STOP sentinel", "amber", "control", False),
    "autonomate.exited": ("Autonomous loop exited", "gray", "control", False),
}
_FAILURE_TYPES = {
    "origin.dispatch_failed", "origin.l1_planner_failed", "planner.failed", "l1.task_failed",
    "l1.task_terminal", "l1.aborted", "packet.import_failed", "packet.import_rejected",
    "integration.failed", "push.failed", "push.blocked", "decider.parked", "gate_promotion.blocked",
}


def _ev_data(ev: dict[str, Any]) -> dict[str, Any]:
    data = ev.get("data")
    return data if isinstance(data, dict) else {}


def project_event(ev: dict[str, Any]) -> dict[str, Any]:
    """Project one events.ndjson record to a typed overlay/chain row. Pure — no I/O.
    Refines the static EVENT_MAP for data-dependent cases (exit codes, verdicts) and
    extracts a plain-language failure ``reason`` when the row is a failure."""
    etype = str(ev.get("type") or "")
    data = _ev_data(ev)
    label, tone, phase, advancing = EVENT_MAP.get(etype, (str(ev.get("message") or etype) or etype, "gray", "control", False))
    exit_code = data.get("exitCode")
    verdict = data.get("verdict")
    # Data-dependent refinements.
    if etype == "l1.worker_completed" and isinstance(exit_code, int) and exit_code != 0:
        label, tone, advancing = f"Worker exited {exit_code}", "red", False
    elif etype == "gate_check.completed" and isinstance(exit_code, int) and exit_code != 0:
        label, tone, advancing = f"Gate check failed · exit {exit_code}", "red", False
    elif etype == "l1.audit_completed" and verdict and verdict != "accepted":
        label, tone, advancing = f"Audit · {verdict}", "amber", False
    elif etype == "decision.recorded":
        decision = data.get("decision")
        if decision and decision != "accept":
            label, tone, advancing = f"Decision · {decision}", "amber", False
    node = data.get("node")
    task_id = data.get("taskId")
    suffix = node or task_id
    if suffix and etype in ("planner.generated", "planner.staged", "l1.dispatch_started",
                            "origin.dispatch", "integration.started", "gate_promotion.started",
                            "gate_promotion.completed", "gate_promotion.blocked"):
        label = f"{label} · {suffix}"
    if etype == "integration.integrated" and data.get("mergeCommit"):
        label = f"Integrated · merge {str(data['mergeCommit'])[:7]}"
    if etype == "l1.committed" and data.get("headSha"):
        label = f"Committed · {str(data['headSha'])[:7]}"
    reason = None
    if etype in _FAILURE_TYPES or (isinstance(exit_code, int) and exit_code != 0) or tone == "red":
        reason = (data.get("failure") or data.get("reason") or data.get("lastFailure")
                  or data.get("failureClass") or (f"exit {exit_code}" if isinstance(exit_code, int) and exit_code != 0 else None))
        if reason is not None:
            reason = str(reason)[:200]
    return {
        "ts": ev.get("ts"),
        "type": etype,
        # label/reason are the only free-text fields here and both can carry an
        # event message a runner composed. Redacting in this pure projector
        # covers the cached events-index path and the uncached overlay path at
        # once, rather than scanning the whole 4 MiB index window per rebuild.
        "label": redact_secrets(label),
        "tone": tone,
        "phase": phase,
        "advancing": bool(advancing),
        "taskId": task_id,
        "nodeId": node,
        "runId": data.get("runId"),
        "branch": data.get("branch"),
        "reason": redact_secrets(reason) if reason else reason,
    }


def build_events_index(lines: list[str]) -> dict[str, Any]:
    """Parse a tail of events.ndjson once into reusable buckets. Pure (operates on
    already-read lines). Drops NOISE_EVENT_TYPES (integration.skipped dominates the
    file). Returns by_task / by_branch / by_node buckets plus projected tail rows."""
    by_task: dict[str, list[dict[str, Any]]] = {}
    by_branch: dict[str, list[dict[str, Any]]] = {}
    by_node: dict[str, list[dict[str, Any]]] = {}
    cycles: list[dict[str, Any]] = []
    tail_rows: list[dict[str, Any]] = []
    for line in lines:
        line = line.strip()
        if not line or line[:1] != "{":
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(ev, dict):
            continue
        etype = ev.get("type")
        if etype in NOISE_EVENT_TYPES:
            continue
        data = _ev_data(ev)
        tid = data.get("taskId")
        branch = data.get("branch")
        node = data.get("node")
        if tid:
            by_task.setdefault(tid, []).append(ev)
        if branch:
            by_branch.setdefault(branch, []).append(ev)
        if node:
            by_node.setdefault(node, []).append(ev)
        if etype in ("origin.reconcile_started", "origin.reconcile_completed"):
            cycles.append(ev)   # L0 cycle spans for /api/timeline (carry runId+mode only)
        tail_rows.append(project_event(ev))
    return {"by_task": by_task, "by_branch": by_branch, "by_node": by_node,
            "cycles": cycles, "tail_rows": tail_rows}


def _chain_sort_key(ev: dict[str, Any]) -> tuple[str, int]:
    return (str(ev.get("ts") or ""), CHAIN_RANK.get(str(ev.get("type") or ""), 50))


def build_origin_chain(task_events: list[dict[str, Any]],
                       branch_events: list[dict[str, Any]] | None = None,
                       branch: str | None = None) -> list[dict[str, Any]]:
    """Build the ordered, deduped lifecycle trace for one task. Pure. Folds in
    branch-keyed integration.* events (which carry no taskId) only for the matching
    branch, and orders by (ts, lifecycle-phase) so same-second events read correctly."""
    pool: list[dict[str, Any]] = list(task_events or [])
    if branch and branch_events:
        for ev in branch_events:
            etype = ev.get("type")
            if etype in ("integration.started", "integration.integrated", "integration.failed"):
                pool.append(ev)
    seen: set[tuple] = set()
    rows: list[dict[str, Any]] = []
    for ev in sorted(pool, key=_chain_sort_key):
        data = _ev_data(ev)
        key = (str(ev.get("ts") or ""), str(ev.get("type") or ""), str(data.get("runId") or ""))
        if key in seen:
            continue
        seen.add(key)
        row = project_event(ev)
        extra = {k: data[k] for k in ("headSha", "mergeCommit", "verdict", "exitCode", "batchId", "node")
                 if data.get(k) is not None}
        rows.append({"ts": row["ts"], "type": row["type"], "label": row["label"],
                     "tone": row["tone"], "phase": row["phase"], "runId": row["runId"], "extra": extra})
    return rows


def resolve_task_provenance_link(task_events: list[dict[str, Any]], lease: dict[str, Any] | None) -> dict[str, Any]:
    """Derive the planner/worker/node link for a task from its events + lease.
    The durable chain is taskId -> events(planner.generated.node, origin.dispatch.runId,
    l1.dispatch_started.runId/branch); lease.batchId/runId is the cross-check fallback."""
    lease = lease or {}
    node = plannerRunId = workerRunId = branch = None
    batchId = lease.get("batchId")
    for ev in task_events or []:
        etype = ev.get("type")
        data = _ev_data(ev)
        if etype in ("planner.generated", "planner.staged") and data.get("node") and not node:
            node = data.get("node")
            plannerRunId = plannerRunId or data.get("runId")
        elif etype == "origin.dispatch":
            plannerRunId = plannerRunId or data.get("runId")
            batchId = batchId or data.get("batchId")
        elif etype == "l1.dispatch_started":
            workerRunId = workerRunId or data.get("runId")
            branch = branch or data.get("branch")
            batchId = batchId or data.get("batchId")
    workerRunId = workerRunId or lease.get("runId")
    branch = branch or lease.get("branch")
    if node:
        confidence = "events"
    elif batchId or workerRunId:
        confidence = "lease"
    else:
        confidence = "none"
    stage = node.split(".")[0] if node and "." in node else None
    return {"parentNode": node, "stage": stage, "plannerRunId": plannerRunId,
            "workerRunId": workerRunId, "batchId": batchId, "branch": branch,
            "linkConfidence": confidence}


def _task_title_norm(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (title or "").lower()).strip()


def parse_planner_batch(data: dict[str, Any], canonical_title: str | None) -> dict[str, Any] | None:
    """Best-effort: find the staged candidate in a planner-batch.json whose markdown
    title matches the canonical task title. Batch ids are sequence-local (TASK-0001),
    so we match on title, not id. Pure. Returns None when no confident match."""
    if not isinstance(data, dict):
        return None
    tasks = data.get("tasks")
    if not isinstance(tasks, list):
        return None
    want = _task_title_norm(canonical_title or "")
    for entry in tasks:
        if not isinstance(entry, dict):
            continue
        md = str(entry.get("markdown") or "")
        m = TASK_HEADING_RE.match(md.splitlines()[0]) if md else None
        cand_title = m.group(2).strip() if m else ""
        if want and _task_title_norm(cand_title) == want:
            return {"localId": entry.get("taskId"), "title": cand_title, "candidateCount": len(tasks)}
    return {"localId": None, "title": None, "candidateCount": len(tasks)}


def parse_dag(data: dict[str, Any]) -> dict[str, Any]:
    """Index the DAG (docs/orchestration/dag.v0.json) by id / area / stage. Pure."""
    by_id: dict[str, dict[str, Any]] = {}
    by_area: dict[str, list[dict[str, Any]]] = {}
    by_stage: dict[str, list[dict[str, Any]]] = {}
    nodes = data.get("nodes") if isinstance(data, dict) else None
    for node in (nodes or []):
        if not isinstance(node, dict) or not node.get("id"):
            continue
        nid = str(node["id"])
        by_id[nid] = node
        if node.get("area"):
            by_area.setdefault(str(node["area"]), []).append(node)
        if node.get("stage"):
            by_stage.setdefault(str(node["stage"]), []).append(node)
    return {"by_id": by_id, "by_area": by_area, "by_stage": by_stage}


def node_id_valid(node_id: str, registry: dict[str, Any]) -> bool:
    return bool(NODE_ID_RE.match(node_id)) and node_id in (registry.get("by_id") or {})


def find_stage_card(doc_lines: list[str], stage: str) -> dict[str, Any] | None:
    """Locate the '### {stage}:' Stage Card in plan-and-dag.md and capture its body
    up to the next '### '/'## ' heading. Pure. Returns None when there is no card
    (e.g. S0 has no Stage Card)."""
    if not stage:
        return None
    head_re = re.compile(r"^###\s+" + re.escape(stage) + r"\b")
    start = None
    for i, line in enumerate(doc_lines):
        if head_re.match(line):
            start = i
            break
    if start is None:
        return None
    end = len(doc_lines)
    for j in range(start + 1, len(doc_lines)):
        if doc_lines[j].startswith("### ") or doc_lines[j].startswith("## "):
            end = j
            break
    section_text = "\n".join(doc_lines[start:end]).strip()
    heading = doc_lines[start].lstrip("# ").strip()
    body = "\n".join(doc_lines[start + 1:end]).strip()
    return {"section": heading, "lineStart": start + 1, "lineEnd": end,
            "excerpt": body[:320], "text": section_text}


def stage_section_hash(section_text: str) -> str:
    return "sha256:" + hashlib.sha256((section_text or "").encode("utf-8")).hexdigest()


def build_source_refs(node: dict[str, Any], doc_lines: list[str]) -> list[dict[str, Any]]:
    """Stage-level source references for a node: link node.stage -> Stage Card with a
    content hash for drift stability. Per-node precise refs are a future singular
    enhancement; the 'why' sentence comes from node.description + requiredCompletion."""
    stage = str(node.get("stage") or "")
    reason = str(node.get("description") or "").strip()
    rc = node.get("requiredCompletion")
    if rc:
        reason = (reason + " " if reason else "") + f"Required completion: {rc}."
    card = find_stage_card(doc_lines, stage)
    if not card:
        return []
    return [{
        "document": STAGE_DOC_REL,
        "section": card["section"],
        "lineStart": card["lineStart"],
        "lineEnd": card["lineEnd"],
        "contentHash": stage_section_hash(card["text"]),
        "excerpt": card["excerpt"],
        "reason": reason,
    }]


def synthesize_gate_blocking(gate: dict[str, Any] | None, integrated_ids: set[str],
                             upstream_status: dict[str, str] | None = None) -> dict[str, Any]:
    """Plain-language pass/block explanation for a gate. Pure. Splits the gate's
    evidence task-set into accepted (integrated) vs missing, and names upstream gates
    that are not passed. Defensive: all live gates are 'passed' today, so blocked /
    absent / stale / invalid are exercised by unit fixtures."""
    upstream_status = upstream_status or {}
    if not isinstance(gate, dict):
        return {"reason": "No gate result recorded for this node yet.",
                "acceptedTaskIds": [], "missingTaskIds": [], "upstreamBlockers": []}
    status = str(gate.get("status") or "absent")
    evidence = gate.get("evidence") or []
    task_ids: list[str] = []
    for item in evidence:
        if isinstance(item, dict) and item.get("kind") == "task-set":
            task_ids.extend([t for t in (item.get("taskIds") or []) if isinstance(t, str)])
    accepted = [t for t in task_ids if t in integrated_ids]
    missing = [t for t in task_ids if t not in integrated_ids]
    upstream = gate.get("upstreamGates") or []
    successful = {"passed", "passed-with-acknowledged-baseline"}
    upstream_blockers = [
        u for u in upstream if upstream_status.get(u, "passed") not in successful
    ]
    rationale = str(gate.get("rationale") or "").strip()
    if status in successful:
        reason = ""
    elif status == "blocked":
        bits = ["Gate is blocked."]
        if upstream_blockers:
            bits.append("Upstream gates not passed: " + ", ".join(upstream_blockers) + ".")
        if missing:
            bits.append("Evidence tasks not yet integrated: " + ", ".join(missing[:8]) + ".")
        if rationale:
            bits.append(rationale)
        reason = " ".join(bits)
    elif status == "absent":
        reason = "No promotion rule has produced a gate result for this node yet."
    elif status == "stale":
        reason = "Gate result is stale relative to current evidence; re-promotion is required."
    elif status == "invalid":
        reason = "Gate result is invalid or contradictory and cannot be trusted."
    else:
        reason = rationale or f"Gate status: {status}."
    return {"reason": reason, "acceptedTaskIds": accepted, "missingTaskIds": missing,
            "upstreamBlockers": upstream_blockers}


def detect_duplicate_tasks(leases: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Advisory duplicate/supersession detection. Clusters leases by identical owned
    files within the same area; the integrated/accepted (or newest) member is
    canonical, the rest are flagged duplicateOf it. Pure. NEVER asserted as fact —
    two legitimately different tasks can edit the same file."""
    clusters: dict[tuple, list[dict[str, Any]]] = {}
    for lease in leases:
        owned = lease.get("ownedFiles")
        tid = lease.get("taskId")
        if not tid or not owned or not isinstance(owned, list):
            continue
        key = (str(lease.get("area") or ""), frozenset(owned))
        clusters.setdefault(key, []).append(lease)
    out: dict[str, dict[str, Any]] = {}
    for members in clusters.values():
        if len(members) < 2:
            continue

        def _rank(m: dict[str, Any]) -> tuple:
            done = str(m.get("status") or "") in DONE_STATUSES
            awaiting = str(m.get("status") or "") in AWAITING_STATUSES
            return (done, awaiting, str(m.get("updatedAt") or ""))

        ordered = sorted(members, key=_rank, reverse=True)
        canonical = ordered[0]
        any_superseded = any(str(m.get("status") or "") == "superseded" for m in members)
        for m in ordered[1:]:
            tid = m.get("taskId")
            superseded = str(m.get("status") or "") == "superseded"
            out[tid] = {
                "duplicateOf": canonical.get("taskId"),
                "supersededBy": canonical.get("taskId") if superseded else None,
                "confidence": "high" if any_superseded else "medium",
                "advisory": True,
                "basis": "identical owned files in the same area",
            }
    return out


# --- cached read-only loaders ------------------------------------------------ #

class _ComputeCache:
    """Generic single-flight TTL cache keyed by an arbitrary string. Mirrors
    SnapshotCache/SessionsCache: one thread computes, others reuse. Read-only.

    Holds up to ``CAPACITY`` (key, value) slots in an LRU OrderedDict so live +
    archived (?plan=) roots do not thrash a single slot when they alternate.
    Single-flight is preserved via a global compute gate (the underlying
    collectors are cheap, pure-filesystem reads), matching the pre-multi-slot
    lock discipline. ``invalidate()`` clears every slot."""

    CAPACITY = 4

    def __init__(self, compute, ttl: float) -> None:
        self._compute_fn = compute
        self.ttl = ttl
        self._lock = threading.Lock()
        self._gate = threading.Lock()
        self._slots: "OrderedDict[str, tuple[Any, float]]" = OrderedDict()

    def _fresh(self, key: str) -> Any:
        with self._lock:
            entry = self._slots.get(key)
            if entry is not None:
                value, stamp = entry
                if value is not None and (time.monotonic() - stamp) < self.ttl:
                    self._slots.move_to_end(key)  # LRU touch
                    return value
        return None

    def get(self, key: str, compute_arg) -> Any:
        cached = self._fresh(key)
        if cached is not None:
            return cached
        with self._gate:
            cached = self._fresh(key)
            if cached is not None:
                return cached
            value = self._compute_fn(compute_arg)
            with self._lock:
                self._slots[key] = (value, time.monotonic())
                self._slots.move_to_end(key)
                while len(self._slots) > self.CAPACITY:
                    self._slots.popitem(last=False)  # evict least-recently-used
            return value

    def invalidate(self) -> None:
        """Drop every cached slot so the next get() recomputes. Used after a
        settings write mutates the underlying config."""
        with self._lock:
            self._slots.clear()


def _events_path(repo: Path) -> Path:
    return state_path(repo, EVENTS_LOG_REL)


_EVENTS_INDEX_CACHE = _ComputeCache(
    lambda repo: build_events_index(
        read_log_window(_events_path(repo), None, EVENTS_INDEX_MAX_BYTES)["rawLines"]),
    EVENTS_INDEX_TTL)


def load_events_index(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    return _EVENTS_INDEX_CACHE.get(str(repo), repo)


def _stat_key(path: Path) -> str:
    try:
        st = path.stat()
        return f"{path}:{int(st.st_mtime)}:{st.st_size}"
    except OSError:
        return f"{path}:missing"


_DAG_CACHE = _ComputeCache(lambda repo: parse_dag(read_json(repo / DAG_REL, {}) or {}), DAG_TTL)


def load_dag_registry(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    return _DAG_CACHE.get(_stat_key(repo / DAG_REL), repo)


def _read_doc_lines(repo: Path) -> list[str]:
    try:
        return (repo / STAGE_DOC_REL).read_text(errors="replace").splitlines()
    except OSError:
        return []


_DOC_CACHE = _ComputeCache(_read_doc_lines, DAG_TTL)


def load_stage_doc(repo: Path) -> list[str]:
    repo = repo.resolve()
    return _DOC_CACHE.get(_stat_key(repo / STAGE_DOC_REL), repo)


def _scan_planner_runs(repo: Path) -> list[dict[str, Any]]:
    """Index L1 planner invocation run dirs (runs/RUN-*/planner-prompt.md). Read-only;
    bounded — only dirs that actually hold a planner prompt are parsed."""
    runs_root = state_path(repo, "runs")
    out: list[dict[str, Any]] = []
    if not runs_root.exists():
        return out
    try:
        entries = list(os.scandir(runs_root))
    except OSError:
        return out
    for entry in entries:
        try:
            if not entry.is_dir(follow_symlinks=False):
                continue
        except OSError:
            continue
        prompt = Path(entry.path) / "planner-prompt.md"
        if not prompt.is_file():
            continue
        info = _parse_planner_prompt(_read_head(prompt, 4096))
        batch = Path(entry.path) / "planner-batch.json"
        out.append({
            "runId": entry.name,
            "dir": entry.path,
            "node": info.get("node"),
            "area": info.get("area"),
            "stage": info.get("stage"),
            "promptRef": str(prompt),
            "batchRef": str(batch) if batch.is_file() else None,
            "mtime": _safe_mtime(prompt),
        })
    out.sort(key=lambda r: r["mtime"])
    return out


_PLANNER_RUNS_CACHE = _ComputeCache(_scan_planner_runs, PLANNER_RUNS_TTL)


def load_planner_runs(repo: Path) -> list[dict[str, Any]]:
    repo = repo.resolve()
    return _PLANNER_RUNS_CACHE.get(str(repo), repo)


def _match_planner_run(planner_runs: list[dict[str, Any]], node: str | None,
                       before_ts: float) -> dict[str, Any] | None:
    """Pick the planner run for a node nearest at-or-before the task's first event."""
    if not node:
        return None
    best = None
    for run in planner_runs:
        if run.get("node") != node:
            continue
        if before_ts and run["mtime"] > before_ts + 120:  # allow small clock slack
            continue
        if best is None or run["mtime"] > best["mtime"]:
            best = run
    return best


def _iso_to_epoch(ts: str | None) -> float:
    if not ts:
        return 0.0
    try:
        return dt.datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


# --- duplicate map (cached; needs all leases) -------------------------------- #

_DUP_CACHE = _ComputeCache(lambda repo: detect_duplicate_tasks(collect_leases(repo)), DAG_TTL)


def load_duplicate_map(repo: Path) -> dict[str, dict[str, Any]]:
    repo = repo.resolve()
    return _DUP_CACHE.get(str(repo), repo)


def build_task_provenance(repo: Path, detail: dict[str, Any], lease: dict[str, Any] | None) -> dict[str, Any]:
    """Assemble the provenance block for a task detail. Read-only; reuses the shared
    events index, DAG registry, plan doc, planner-run index, and duplicate map (all
    cached). The events index is a 4 MB tail, so very old tasks may have a partial
    origin chain — recent/active tasks (the ones inspected live) are always in-window."""
    repo = repo.resolve()
    task_id = detail.get("id")
    index = load_events_index(repo)
    registry = load_dag_registry(repo)
    task_events = index["by_task"].get(task_id, [])
    link = resolve_task_provenance_link(task_events, lease)
    branch = link.get("branch")
    branch_events = index["by_branch"].get(branch, []) if branch else []
    chain = build_origin_chain(task_events, branch_events, branch)
    # integration commit: last branch-matched integration.integrated mergeCommit
    integration_commit = None
    for ev in chain:
        if ev["type"] == "integration.integrated" and ev["extra"].get("mergeCommit"):
            integration_commit = ev["extra"]["mergeCommit"]
    node = link.get("parentNode")
    node_def = (registry.get("by_id") or {}).get(node) if node else None
    source_refs = build_source_refs(node_def, load_stage_doc(repo)) if node_def else []
    why = ""
    if node_def:
        why = str(node_def.get("description") or "").strip()
        rc = node_def.get("requiredCompletion")
        if rc:
            why = (why + " " if why else "") + f"It serves node {node} toward {rc}."
    # best-effort planner prompt / batch / staged candidate
    planner_prompt_ref = planner_batch_ref = staged_candidate = None
    first_ts = _iso_to_epoch(task_events[0].get("ts")) if task_events else 0.0
    match = _match_planner_run(load_planner_runs(repo), node, first_ts)
    if match:
        planner_prompt_ref = match.get("promptRef")
        planner_batch_ref = match.get("batchRef")
        if planner_batch_ref:
            staged_candidate = parse_planner_batch(read_json(Path(planner_batch_ref), {}) or {}, detail.get("title"))
    dup = load_duplicate_map(repo).get(task_id, {})
    return {
        "taskId": task_id,
        "parentNode": node,
        "stage": link.get("stage"),
        "area": detail.get("area"),
        "batchId": link.get("batchId"),
        "plannerRunId": link.get("plannerRunId"),
        "workerRunId": link.get("workerRunId"),
        "plannerPromptRef": planner_prompt_ref,
        "plannerBatchRef": planner_batch_ref,
        "stagedCandidate": staged_candidate,
        "linkConfidence": link.get("linkConfidence"),
        "whyTaskExists": why,
        "originChain": chain,
        "integrationCommit": integration_commit,
        "duplicateOf": dup.get("duplicateOf"),
        "supersededBy": dup.get("supersededBy"),
        "duplicateAdvisory": dup or None,
        "sourceRefs": source_refs,
    }


# --- node / area / overlay collectors ---------------------------------------- #

def _integrated_task_ids(repo: Path) -> set[str]:
    out: set[str] = set()
    for lease in collect_leases(repo):
        if str(lease.get("status") or "") in DONE_STATUSES and lease.get("taskId"):
            out.add(str(lease["taskId"]))
    return out


def _load_gate_for_node(repo: Path, node_id: str) -> dict[str, Any] | None:
    path = (repo / GATES_REL / f"{node_id}.gate-result.json").resolve()
    gates_root = (repo / GATES_REL).resolve()
    if gates_root not in path.parents:  # containment guard
        return None
    data = read_json(path, None)
    return data if isinstance(data, dict) else None


def collect_node_detail(repo: Path, node_id: str) -> dict[str, Any] | None:
    repo = repo.resolve()
    registry = load_dag_registry(repo)
    if not node_id_valid(node_id, registry):
        return None
    node_def = registry["by_id"][node_id]
    gate = _load_gate_for_node(repo, node_id)
    integrated = _integrated_task_ids(repo)
    # upstream gate statuses (cheap: a few files)
    upstream_status: dict[str, str] = {}
    for up in (node_def.get("dependsOn") or []):
        ug = _load_gate_for_node(repo, up)
        upstream_status[up] = str((ug or {}).get("status") or "absent")
    blocking = synthesize_gate_blocking(gate, integrated, upstream_status)
    # tasks that serve this node: events by_node + gate evidence task-set
    index = load_events_index(repo)
    task_ids: set[str] = set()
    for ev in index["by_node"].get(node_id, []):
        tid = _ev_data(ev).get("taskId")
        if tid:
            task_ids.add(tid)
    if gate:
        for item in (gate.get("evidence") or []):
            if isinstance(item, dict) and item.get("kind") == "task-set":
                task_ids.update([t for t in (item.get("taskIds") or []) if isinstance(t, str)])
    lease_by_task = {l.get("taskId"): l for l in collect_leases(repo)}
    tasks_generated = []
    for tid in sorted(task_ids):
        l = lease_by_task.get(tid) or {}
        tasks_generated.append({"taskId": tid, "status": l.get("status"),
                                "runId": l.get("runId"), "batchId": l.get("batchId")})
    planner_runs = [r for r in load_planner_runs(repo) if r.get("node") == node_id]
    l1_leases = [l for l in collect_l1_leases(repo) if l.get("node") == node_id]
    is_frontier = any(l.get("active") for l in l1_leases) or (gate or {}).get("status") in (None, "absent", "blocked", "stale")
    why_frontier = blocking["reason"] or (
        f"{node_def.get('description','')} Required completion: {node_def.get('requiredCompletion')}." )
    source_refs = build_source_refs(node_def, load_stage_doc(repo))
    return {
        "schema": "singular.codex.node-detail.v0",
        "generatedAt": utc_now(),
        "nodeId": node_id,
        "definition": node_def,
        "gate": {
            "status": (gate or {}).get("status", "absent"),
            "authoritative": (gate or {}).get("authoritative"),
            "evidenceClass": (gate or {}).get("evidenceClass"),
            "predicate": node_def.get("requiredCompletion"),
            "upstreamGates": node_def.get("dependsOn") or [],
            "upstreamStatus": upstream_status,
            "rationale": (gate or {}).get("rationale"),
            "recordedAt": (gate or {}).get("recordedAt"),
            "decidedBy": (gate or {}).get("decidedBy"),
            "blocking": blocking,
            "commandLogs": [
                {"ref": i.get("ref"), "command": i.get("command"), "exitCode": i.get("exitCode"),
                 "logRef": i.get("logRef")}
                for i in ((gate or {}).get("evidence") or [])
                if isinstance(i, dict) and i.get("kind") == "command-log"
            ],
            "path": str((repo / GATES_REL / f"{node_id}.gate-result.json")) if gate else None,
        },
        "tasksGenerated": tasks_generated,
        "plannerRuns": [{"runId": r["runId"], "promptRef": r["promptRef"], "batchRef": r["batchRef"]}
                        for r in planner_runs] + [
            {"runId": l.get("runId"), "status": l.get("status"), "startedAt": l.get("startedAt"),
             "updatedAt": l.get("updatedAt"), "active": l.get("active")} for l in l1_leases],
        "frontier": {"isFrontier": bool(is_frontier), "why": why_frontier.strip()},
        "sourceRefs": source_refs,
    }


def collect_area_nodes(repo: Path, area: str) -> dict[str, Any] | None:
    repo = repo.resolve()
    registry = load_dag_registry(repo)
    nodes = (registry.get("by_area") or {}).get(area)
    if not nodes:
        return None
    integrated = _integrated_task_ids(repo)
    leases = collect_leases(repo)
    l1_leases = collect_l1_leases(repo)
    active_nodes = {l.get("node") for l in l1_leases if l.get("active")}
    index = load_events_index(repo)
    out_nodes = []
    for node in sorted(nodes, key=lambda n: str(n.get("id"))):
        nid = str(node["id"])
        gate = _load_gate_for_node(repo, nid)
        task_ids: set[str] = set()
        for ev in index["by_node"].get(nid, []):
            tid = _ev_data(ev).get("taskId")
            if tid:
                task_ids.add(tid)
        if gate:
            for item in (gate.get("evidence") or []):
                if isinstance(item, dict) and item.get("kind") == "task-set":
                    task_ids.update([t for t in (item.get("taskIds") or []) if isinstance(t, str)])
        total = len(task_ids)
        integ = len([t for t in task_ids if t in integrated])
        gate_status = (gate or {}).get("status", "absent")
        is_frontier = nid in active_nodes or gate_status in ("absent", "blocked", "stale")
        out_nodes.append({
            "nodeId": nid,
            "stage": node.get("stage"),
            "layer": node.get("layer"),
            "kind": node.get("kind"),
            "dependsOn": node.get("dependsOn") or [],
            "gateStatus": gate_status,
            "predicate": node.get("requiredCompletion"),
            "taskCounts": {"total": total, "integrated": integ, "open": total - integ},
            "frontier": bool(is_frontier),
        })
    return {"schema": "singular.codex.area-nodes.v0", "generatedAt": utc_now(),
            "area": area, "nodes": out_nodes}


def collect_events_overlay(repo: Path, cursor: int | None, limit: int,
                           types: set[str] | None) -> dict[str, Any]:
    """Byte-cursor typed projection of events.ndjson for the live overlay. Reuses the
    same read_log_window byte mechanics as the session terminal; cheap and read-only."""
    repo = repo.resolve()
    window = read_log_window(_events_path(repo), cursor, EVENTS_INDEX_MAX_BYTES)
    rows: list[dict[str, Any]] = []
    registry = load_dag_registry(repo)
    node_area = {nid: n.get("area") for nid, n in (registry.get("by_id") or {}).items()}
    for line in window["rawLines"]:
        line = line.strip()
        if not line or line[:1] != "{":
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(ev, dict) or ev.get("type") in NOISE_EVENT_TYPES:
            continue
        if types and ev.get("type") not in types:
            continue
        row = project_event(ev)
        if row.get("nodeId"):
            row["areaId"] = node_area.get(row["nodeId"])
        rows.append(row)
    rows = rows[-limit:]
    return {"schema": "singular.codex.events-overlay.v0", "generatedAt": utc_now(),
            "rows": rows, "cursor": window["cursor"], "size": window["size"], "reset": window["reset"]}


# --------------------------------------------------------------------------- #
# Plan overview (read-only mission control)                                    #
# --------------------------------------------------------------------------- #
#
# Answers the operator-orientation questions the per-entity views don't: what
# feeds L0/L1, what the settings are, which phases are done, and overall %.
# Strict read-only: parses the DAG, gate-results, STATUS.md and the orchestration
# shell config (for env-overridable DEFAULTS — there is no single runtime config
# file). No subprocesses.

STATUS_REL = ".singular-state/STATUS.md"
CIRCUIT_REL = ".singular-state/circuit.json"
STOP_REL = ".singular-state/STOP"
ORCH_SCRIPTS_REL = "scripts/orchestration"
PLATFORM_VISION_REL = "docs/core/platform-vision.md"

# Settings surfaced to the operator. Values are env-overridable DEFAULTS parsed
# from scripts/orchestration/*.sh (KEY="${KEY:-DEFAULT}"); fallback is the known
# default if parsing misses. Each spec row carries STATIC display metadata so the
# frontend can render by type:
#   (envKey, label, fallback, kind, unit, meaning)
#   kind   -> model | reasoning | enum | count | duration | bytes | bool | derived | identifier
#   unit   -> "" | s | min | h | GB   (split OUT of the label — never baked into parens)
#   meaning-> one-line plain-language help ("" when obvious)
# A group is (title, layout, items); layout "matrix" renders the models group as a
# role x {model,reasoning} ladder. kind/unit/meaning/layout are metadata only — NOT
# a new data source; collect_settings still derives every value from the SAME shell
# defaults via parse_shell_default.
SETTINGS_SPEC = [
    ("Models & reasoning · role matrix", "matrix", [
        ("SINGULAR_CODEX_MODEL", "model", "gpt-5.5", "model", "",
         "Codex model all three roles run on"),
        ("SINGULAR_CODEX_SERVICE_TIER", "service tier", "default", "enum", "",
         "API service tier (default = standard queue)"),
        ("SINGULAR_CODEX_PLANNER_REASONING_EFFORT", "planner reasoning", "xhigh", "reasoning", "",
         "effort the L1 area planner spends — plan quality gates everything downstream"),
        ("SINGULAR_CODEX_L2_REASONING_EFFORT", "worker reasoning", "medium", "reasoning", "",
         "effort each L2 developer worker spends on a task slice"),
        ("SINGULAR_CODEX_AUDITOR_REASONING_EFFORT", "auditor reasoning", "high", "reasoning", "",
         "effort the diff auditor spends reviewing a packet before the gate"),
    ]),
    ("Throughput · work flowing per cycle", "list", [
        ("SINGULAR_MAX_CONCURRENT", "max concurrent workers", "1", "count", "",
         "L2 workers running at the same time"),
        ("SINGULAR_MAX_DISPATCH", "max dispatch / cycle", "follows max concurrent", "derived", "",
         "tasks dispatched per cycle; unset, so it follows max concurrent workers"),
        ("SINGULAR_MAX_L1_CONCURRENT", "max parallel L1 planners", "3", "count", "",
         "area planners that may plan at once — only when parallel planning is on (below)"),
        ("SINGULAR_ENABLE_L1_PARALLEL", "L1 parallel planning", "0", "bool", "",
         "off = plan one area at a time; gates the parallel-planner limit above"),
        ("SINGULAR_L1_TASKS_PER_NODE", "tasks per planner node", "1", "count", "",
         "tasks an L1 planner emits per DAG node"),
        ("SINGULAR_L2_SLICE_BUDGET", "L2 slice budget", "1", "count", "",
         "starting work-slices granted to a worker per task"),
        ("SINGULAR_L2_SLICE_BUDGET_MAX", "L2 slice budget cap", "3", "count", "",
         "hard ceiling the slice budget can grow to"),
    ]),
    ("Safety limits", "list", [
        ("SINGULAR_MAX_RETRIES", "max task retries", "3", "count", "",
         "attempts on a failing task before it is parked as a blocked escalation"),
        ("SINGULAR_MAX_CONSEC_FAILS", "circuit-breaker threshold", "5", "count", "",
         "consecutive failures that trip the breaker and halt the loop"),
        ("SINGULAR_MAX_HOURS", "loop budget", "20", "duration", "h",
         "wall-clock hours before the loop voluntarily exits"),
        ("SINGULAR_MIN_DISK_GB", "min free disk", "2", "bytes", "GB",
         "loop refuses to start a cycle below this free-space floor"),
        ("SINGULAR_L1_STALE_MINUTES", "L1 stale timeout", "60", "duration", "min",
         "an L1 planner lease idle this long is reclaimed as stale"),
        ("SINGULAR_PLANNER_BACKOFF_SECONDS", "planner backoff", "900", "duration", "s",
         "wait after a planner error before re-planning"),
        ("SINGULAR_PLANNER_QUOTA_BACKOFF_SECONDS", "planner quota backoff", "1800", "duration", "s",
         "longer wait after a planner quota / rate-limit rejection"),
        ("SINGULAR_PLANNER_OVERLOAD_BACKOFF_SECONDS", "planner overload backoff", "180", "duration", "s",
         "short wait after a provider 503/529; transient capacity, not a usage limit"),
        ("SINGULAR_OVERLOAD_WAIT_BUDGET", "overload wait budget", "3600", "duration", "s",
         "total overload sleep-through before the loop writes STOP (separate from the quota budget)"),
    ]),
    ("Loop behavior", "list", [
        ("SINGULAR_AUTO_INTEGRATE", "auto-integrate", "1", "bool", "",
         "on = merge passing worker branches into the target automatically"),
        ("SINGULAR_PUSH", "push to remote", "1", "bool", "",
         "on = push the target branch to origin after integrating"),
        ("SINGULAR_GENERATE", "task generation", "1", "bool", "",
         "on = let planners generate new tasks; off = drain the existing queue only"),
        ("SINGULAR_SLEEP", "cycle sleep", "20", "duration", "s",
         "pause between loop cycles"),
        # Home's "enable auto-briefing" button POSTs this key. It was absent from
        # SETTINGS_SPEC and from every _CONFIG_* tuple, so the write whitelist
        # rejected it with 400 and the button could never work. Listing it here
        # makes it writable AND gives it a labelled System-panel row, rather than
        # leaving it a writable-but-invisible knob.
        ("SINGULAR_SUPERVISOR_INTERVAL_MIN", "auto-briefing interval", "0", "duration", "min",
         "minutes between automatic read-only supervisor briefings; 0 = off"),
        ("SINGULAR_TARGET_BRANCH", "target branch", "codex/singular-bootstrap-target", "identifier", "",
         "branch the loop integrates and pushes to"),
    ]),
]

_BOOL_TRUE = {"1", "on", "true", "yes"}


def _apply_bool_value(item: dict[str, Any]) -> dict[str, Any]:
    """Recompute the derived boolValue from item["value"], in place.

    The single place the bool derivation lives. It used to be inline in
    collect_settings only, so _overlay_config_env — which rewrites `value` when
    singular.config.json env{} sets a key — left a STALE boolValue behind. The
    frontend short-circuits on `boolValue === true`, so a bool key set to "0" in
    config rendered as ON: the System panel showed the opposite of the truth for
    SINGULAR_AUTO_INTEGRATE, SINGULAR_PUSH, SINGULAR_GENERATE and
    SINGULAR_ENABLE_L1_PARALLEL.
    """
    if item.get("kind") == "bool":
        item["boolValue"] = str(item.get("value") or "").strip().lower() in _BOOL_TRUE
    return item

# Where the env-overridable shell DEFAULTS live. SETTINGS_SOURCE is an adapter
# template ("{engineHome}" / "{repo}" placeholders); None means "no adapter
# source configured" and the resolver falls back to $SINGULAR_ENGINE_HOME/engine,
# then to the legacy in-repo scripts/orchestration layout (exact old behavior).
SETTINGS_SOURCE: str | None = None
SETTINGS_FILE_NAMES = ("lib.sh", "codex-run.sh", "reconcile.sh", "autonomate.sh")


def resolve_settings_dir(repo: Path) -> Path:
    """Resolve the directory holding the orchestration shell defaults.

    Precedence: adapter ``settingsSource`` template -> ``$SINGULAR_ENGINE_HOME/engine``
    -> legacy ``<repo>/scripts/orchestration``. A template that needs {engineHome}
    while the env var is unset cannot resolve and falls through."""
    engine_home = os.environ.get("SINGULAR_ENGINE_HOME") or ""
    template = SETTINGS_SOURCE
    if template and not ("{engineHome}" in template and not engine_home):
        return Path(template.replace("{engineHome}", engine_home).replace("{repo}", str(repo)))
    if engine_home:
        return Path(engine_home) / "engine"
    return repo / ORCH_SCRIPTS_REL


def parse_shell_default(text: str, key: str) -> str | None:
    """Extract DEFAULT from a `KEY="${KEY:-DEFAULT}"` shell assignment. Pure."""
    m = re.search(r"\b" + re.escape(key) + r'\s*=\s*"?\$\{' + re.escape(key) + r":-([^}]*)\}", text)
    return m.group(1).strip() if m else None


def parse_env_overrides(repo: Path, keys: set[str]) -> dict[str, str]:
    """Read `.singular-state/.env` and return {KEY: value} for the given config keys ONLY.

    Whitelisted to `keys` (the SETTINGS_SPEC knobs), so secrets in .env — DATABASE_URL,
    POSTGRES_*, PG*, passwords — are never parsed or surfaced to the dashboard. Read-only.
    """
    out: dict[str, str] = {}
    try:
        raw = state_path(repo, ".env").read_text(errors="replace")
    except OSError:
        return out
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, _, value = line.partition("=")
        key = key.strip()
        if key not in keys:  # whitelist — non-config (secret) lines are never read
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
            value = value[1:-1]
        out[key] = value
    return out


def collect_settings(repo: Path) -> list[dict[str, Any]]:
    """Parse env-overridable DEFAULTS into typed, grouped display rows. Read-only.

    Output: [{title, category(alias), layout, items:[{envKey,key,label,value,default,
    source,overridden,kind,unit,meaning,boolValue?}]}]. `value` is the EFFECTIVE config:
    the `.singular-state/.env` override if set, else the shell default. `source` is "env" or
    "default" and `default` carries the shell default for reference. Secrets in .env are
    never read (parse_env_overrides is whitelisted to the settings keys). Read-only.
    """
    text = ""
    settings_dir = resolve_settings_dir(repo)
    for name in SETTINGS_FILE_NAMES:
        try:
            text += "\n" + (settings_dir / name).read_text(errors="replace")
        except OSError:
            pass
    # Live override layer: the values the loop actually sources from .env at launch.
    # Whitelisted to the settings keys so DB credentials in .env are never read.
    spec_keys = {it[0] for _t, _l, group_items in SETTINGS_SPEC for it in group_items}
    overrides = parse_env_overrides(repo, spec_keys)
    groups = []
    for title, layout, items in SETTINGS_SPEC:
        rows = []
        for key, label, fallback, kind, unit, meaning in items:
            default_val = parse_shell_default(text, key) or fallback
            # Derived knobs (e.g. SINGULAR_MAX_DISPATCH -> $max_concurrent): the shell default
            # is unresolved, but an explicit .env override IS the real, resolved value.
            if default_val.startswith("$"):
                default_val = "follows max concurrent"
            if key == "SINGULAR_CODEX_SERVICE_TIER" and default_val in ("", "default"):
                default_val = "default"
            override = overrides.get(key)
            if override not in (None, ""):
                val, source = override, "env"
            else:
                val, source = default_val, "default"
            row = {"key": key, "envKey": key, "label": label, "value": val,
                   "default": default_val, "source": source, "overridden": source == "env",
                   "kind": kind, "unit": unit, "meaning": meaning}
            rows.append(_apply_bool_value(row))
        # `category` kept as an alias of `title` for backward compatibility.
        groups.append({"title": title, "category": title, "layout": layout, "items": rows})
    return groups


# The gate statuses that mean "this node is done". Cohort membership is decided
# by evidenceClass, never by status: a grandfathered gate is exactly as passed as
# a freshly proven one, it simply belongs to an earlier campaign.
SUCCESSFUL_GATE_STATUSES = {"passed", "passed-with-acknowledged-baseline"}


def _all_gate_records(repo: Path) -> dict[str, dict[str, Any]]:
    """{node: {"status", "evidenceClass"}} for every gate-result file. Read-only.

    The provenance-carrying generalization of _all_gate_statuses. Progress has to
    tell an accepted-as-done historical gate (evidenceClass "grandfathered") from
    one the current campaign actually earned, and status alone cannot: both say
    "passed"."""
    out: dict[str, dict[str, Any]] = {}
    root = repo / GATES_REL
    if not root.exists():
        return out
    for path in root.glob("*.gate-result.json"):
        data = read_json(path, None)
        if isinstance(data, dict) and data.get("node"):
            evidence = data.get("evidenceClass")
            out[str(data["node"])] = {
                "status": str(data.get("status") or "absent"),
                "evidenceClass": str(evidence) if isinstance(evidence, str) and evidence else None,
            }
    return out


def _all_gate_statuses(repo: Path) -> dict[str, str]:
    """{node: status} — the status-only projection of _all_gate_records."""
    return {node: record["status"] for node, record in _all_gate_records(repo).items()}


def _gate_cohort(record: Any) -> str | None:
    """"historical" | "current" | None for one gate record (or raw gate file dict).

    None for anything not successful: an absent, failed or blocked gate belongs
    to no completion cohort. Successful + evidenceClass "grandfathered" is
    historical — authoritative evidence the CURRENT campaign did not produce.
    Every other successful gate is current-campaign work."""
    if not isinstance(record, dict):
        return None
    if str(record.get("status") or "") not in SUCCESSFUL_GATE_STATUSES:
        return None
    return "historical" if str(record.get("evidenceClass") or "") == "grandfathered" else "current"


def _cohort_progress(cohorts: Any, total: int) -> dict[str, Any]:
    """The `cohorts` block from an iterable of per-node cohort values. Pure.

    PMGO-002: one combined percentage let "30% — 13/44 gated complete" stand
    beside a loop that had never actuated, and every reading of that was wrong.
    historical.total == historical.passed by construction — the historical cohort
    IS the accepted-as-done set, green by definition, and can never serve as a
    denominator the current campaign is measured against. Everything else in the
    plan, including nodes with no gate at all, is current-campaign work."""
    values = list(cohorts)
    historical = sum(1 for c in values if c == "historical")
    current = sum(1 for c in values if c == "current")
    current_total = max(0, total - historical)
    return {
        "historical": {"passed": historical, "total": historical},
        "current": {"passed": current, "total": current_total,
                    "pct": round(100 * current / current_total) if current_total else 0},
    }


def compute_node_ranks(by_id: dict[str, Any]) -> dict[str, int]:
    """Longest-path depth over ALL dependsOn edges: {node: rank}. Pure.

    rank(root) = 0, rank(n) = 1 + max(rank(dep)) — the earliest wave a node could
    run in. Kahn's algorithm, so every dependency is ranked before its dependent.
    Edges to ids outside the registry are ignored: a dangling dependency is a
    validation error, not a reason to sink the node's rank. Cycle tolerance —
    nodes that never dequeue are ranked from whatever deps DID rank; nothing
    raises, and every node in by_id gets a rank so callers never handle a missing
    key."""
    deps: dict[str, list[str]] = {}
    dependents: dict[str, list[str]] = {}
    indegree: dict[str, int] = {}
    for nid, node in by_id.items():
        raw = node.get("dependsOn") if isinstance(node, dict) else None
        seen: set[str] = set()
        clean: list[str] = []
        for dep in (raw if isinstance(raw, list) else []):
            dep = str(dep)
            if dep == nid or dep in seen or dep not in by_id:
                continue
            seen.add(dep)
            clean.append(dep)
        deps[nid] = clean
        indegree[nid] = len(clean)
        for dep in clean:
            dependents.setdefault(dep, []).append(nid)

    ranks: dict[str, int] = {}
    queue = [nid for nid, degree in indegree.items() if degree == 0]
    cursor = 0
    while cursor < len(queue):
        nid = queue[cursor]
        cursor += 1
        ranks[nid] = 1 + max([ranks[d] for d in deps[nid] if d in ranks], default=-1)
        for child in dependents.get(nid, []):
            indegree[child] -= 1
            if indegree[child] == 0:
                queue.append(child)
    for nid in by_id:  # cycle members never dequeue; rank them from what is known
        if nid not in ranks:
            ranks[nid] = 1 + max([ranks[d] for d in deps.get(nid, []) if d in ranks], default=0)
    return ranks


def _stage_sort_key(stage: str) -> tuple[int, int]:
    """Legacy lexical stage order: D-stages first, then numeric suffix.

    Kept as the TIE-BREAK inside _stage_order_key (and as the fallback for any
    call path with no rank data), so stage order is byte-identical wherever
    dependency ranks agree."""
    return (0 if stage[:1] == "D" else 1, int(re.sub(r"\D", "", stage) or 0))


def _stage_rank_map(by_stage: Any, ranks: dict[str, int]) -> dict[str, int]:
    """{stage: min rank over its member nodes}. Pure.

    min, not max: a stage's position is the earliest wave in which any of its
    work becomes reachable."""
    out: dict[str, int] = {}
    for stage, nodes in (by_stage or {}).items():
        member_ranks = [ranks[str(n.get("id"))] for n in (nodes or [])
                        if isinstance(n, dict) and str(n.get("id")) in ranks]
        out[str(stage)] = min(member_ranks) if member_ranks else 0
    return out


def _stage_order_key(stage: str, stage_ranks: dict[str, int]) -> tuple:
    """Topology-first stage order: dependency rank, then the legacy lexical key,
    then the id. PMGO-001: with only the lexical key, a stage could be ordered
    (and drawn) ahead of a stage holding its own prerequisites."""
    return (stage_ranks.get(str(stage), 0),) + _stage_sort_key(stage) + (str(stage),)


def compute_plan_progress(registry: dict[str, Any], gate_status: dict[str, str],
                          gate_records: dict[str, Any] | None = None) -> tuple:
    """Per-stage + overall plan completion from the DAG + gate statuses. Pure.

    Stages come out in dependency order (see _stage_order_key). `progress` keeps
    the combined passedNodes/totalNodes/pct exactly as before and adds `cohorts`,
    which separates the historical accepted-as-done set from the current campaign
    (PMGO-002). `gate_records` carries the provenance; without it every
    successful gate counts as current — the honest reading when no evidenceClass
    is known."""
    by_stage = registry.get("by_stage") or {}
    stage_ranks = _stage_rank_map(by_stage, compute_node_ranks(registry.get("by_id") or {}))
    records = gate_records if isinstance(gate_records, dict) else {}
    stages = []
    total = passed = 0
    cohorts: list[str | None] = []
    for s in sorted(by_stage, key=lambda stage: _stage_order_key(stage, stage_ranks)):
        nodes = []
        p = 0
        for n in sorted(by_stage[s], key=lambda x: str(x.get("id"))):
            nid = str(n.get("id"))
            st = gate_status.get(nid, "absent")
            if st in SUCCESSFUL_GATE_STATUSES:
                p += 1
            cohorts.append(_gate_cohort(records.get(nid) or {"status": st}))
            nodes.append({"id": n.get("id"), "status": st, "layer": n.get("layer")})
        t = len(by_stage[s])
        total += t
        passed += p
        stages.append({"stage": s, "total": t, "passed": p,
                       "status": "complete" if p == t else ("active" if p > 0 else "pending"),
                       "nodes": nodes})
    pct = round(100 * passed / total) if total else 0
    frontier = []
    for stg in stages:
        if stg["status"] == "complete":
            continue
        for n in stg["nodes"]:
            if n["status"] in ("absent", "blocked", "stale"):
                frontier.append({"nodeId": n["id"], "stage": stg["stage"], "status": n["status"]})
    progress = {"passedNodes": passed, "totalNodes": total, "pct": pct,
                "cohorts": _cohort_progress(cohorts, total)}
    return progress, stages, frontier[:10]


def parse_status_md(text: str) -> dict[str, Any]:
    """Parse the operator-facing .singular-state/STATUS.md. Pure."""
    def grab(rx, cast=str):
        m = re.search(rx, text)
        if not m:
            return None
        try:
            return cast(m.group(1).strip())
        except (ValueError, TypeError):
            return None
    return {
        "iteration": grab(r"Iteration:\s*(\d+)", int),
        "note": grab(r"Note:\s*(.+)"),
        "stopRequested": bool(re.search(r"STOP requested:\s*yes", text)),
        "readyTasks": grab(r"ready tasks:\s*(\d+)", int),
        "activeLeases": grab(r"active leases:\s*(\d+)", int),
        "importedPackets": grab(r"imported packets:\s*(\d+)", int),
        "integrationsLifetime": grab(r"integrations \(lifetime\):\s*(\d+)", int),
        "parkedLifetime": grab(r"parked escalations \(lifetime\):\s*(\d+)", int),
        "breaker": grab(r"consecutive failures:\s*([\d\s/]+)"),
        "branch": grab(r"branch:\s*`([^`]+)`"),
        "headSha": grab(r"@\s*`([^`]+)`"),
        "updatedAt": grab(r"Updated:\s*(\S+)"),
    }


# A coarse 34-node % stays flat for hours while many L2 tasks integrate toward one
# node's gate — so an operator can't tell "grinding the frontier" from "stuck". The
# pulse derives a genuinely-live signal from the SAME cached events tail (no extra
# reads): loop heartbeat (last integration / activity) + per-area frontier throughput,
# joining each task to its area via the planner.generated event that carries `area`.
PULSE_WINDOW_SECONDS = 3600  # "recent" throughput window (1h)
_ADVANCE_TYPES = ("integration.integrated", "l1.committed")


def compute_loop_pulse(index: dict[str, Any], registry: dict[str, Any],
                       gate_status: dict[str, str], now_epoch: float) -> tuple[dict, list]:
    """Live heartbeat + per-area frontier throughput from the events index. Pure.

    Returns (pulse, frontierActivity). frontierActivity groups the not-yet-passed
    nodes by area and attributes recent integrations to the area feeding them.
    """
    by_task = index.get("by_task") or {}
    tail = index.get("tail_rows") or []

    # task -> area, and the freshest planner.generated (what's being planned now).
    task_area: dict[str, str] = {}
    latest_plan_epoch, latest_plan_area = 0.0, None
    for tid, evs in by_task.items():
        for ev in evs:
            if ev.get("type") == "planner.generated":
                area = _ev_data(ev).get("area")
                if area:
                    task_area[tid] = str(area)
                    e = _iso_to_epoch(ev.get("ts"))
                    if e > latest_plan_epoch:
                        latest_plan_epoch, latest_plan_area = e, str(area)
                break

    last_integration = last_activity = 0.0
    integrated_tasks: set[str] = set()                 # distinct integrated taskIds in window
    area_recent: dict[str, dict[str, float]] = {}      # area -> {count, lastEpoch}
    latest_advance_epoch, latest_advance_area = 0.0, None
    for r in tail:
        e = _iso_to_epoch(r.get("ts"))
        if e > last_activity:
            last_activity = e
        t = r.get("type")
        if t == "integration.integrated" and e > last_integration:
            last_integration = e
        if t in _ADVANCE_TYPES:
            tid = r.get("taskId")
            area = task_area.get(tid)
            # activeArea tracks the freshest work signal (commit OR integration); the
            # throughput COUNT tracks only true integrations so it reconciles with the
            # global integ/hr and the "integrated" label.
            if e > latest_advance_epoch:
                latest_advance_epoch, latest_advance_area = e, area
            if t == "integration.integrated":
                in_window = (now_epoch - e) <= PULSE_WINDOW_SECONDS
                if tid and in_window:
                    integrated_tasks.add(tid)
                if area:
                    slot = area_recent.setdefault(area, {"count": 0.0, "lastEpoch": 0.0})
                    if in_window:
                        slot["count"] += 1
                    if e > slot["lastEpoch"]:
                        slot["lastEpoch"] = e

    active_area = latest_advance_area or latest_plan_area

    # Not-yet-passed nodes grouped by the area whose tasks feed them.
    frontier_by_area: dict[str, list[dict[str, Any]]] = {}
    for nid, node in (registry.get("by_id") or {}).items():
        if gate_status.get(nid, "absent") not in {
            "passed", "passed-with-acknowledged-baseline"
        }:
            frontier_by_area.setdefault(str(node.get("area") or "—"), []).append(
                {"id": nid, "status": gate_status.get(nid, "absent"), "stage": node.get("stage")})
    activity = []
    for area, nodes in frontier_by_area.items():
        slot = area_recent.get(area, {"count": 0.0, "lastEpoch": 0.0})
        activity.append({
            "area": area,
            "nodes": sorted(nodes, key=lambda n: str(n["id"])),
            "recentIntegrations": int(slot["count"]),
            "lastAt": _iso_from_mtime(slot["lastEpoch"]) if slot["lastEpoch"] else None,
            "active": area == active_area,
        })
    activity.sort(key=lambda a: (a["active"], a["recentIntegrations"], a["lastAt"] or ""), reverse=True)

    pulse = {
        "lastIntegrationAt": _iso_from_mtime(last_integration) if last_integration else None,
        "lastActivityAt": _iso_from_mtime(last_activity) if last_activity else None,
        "activityAgeSeconds": int(now_epoch - last_activity) if last_activity else None,
        "recentIntegrations": len(integrated_tasks),
        "windowSeconds": PULSE_WINDOW_SECONDS,
        "activeArea": active_area,
    }
    return pulse, activity


# --------------------------------------------------------------------------- #
# L1 selection replica (AXON-002) + stop reason (PMGO-003)                     #
# --------------------------------------------------------------------------- #
#
# "Ready by dependency" and "runnable now" are different numbers and only the
# first one was ever observable. engine/lib.sh `singular_select_l1_frontier`
# computes the second — one node per area, no write-scope overlap, capped — and
# then throws the reasons away with the loop's stdout. Safe serialization
# therefore looks exactly like a broken parallel engine. What follows is a
# read-only replica of that selection so the console can name the constraint per
# node instead of leaving the operator to infer one.

# What the replica models, declared in the payload as `policy` so the UI never
# implies more coverage than exists. The engine's pending-promotion pre-filter
# (singular_l1_fanout -> singular_node_pending_promotion) is deliberately NOT
# replicated: it asks whether a node's tasks are all complete-but-unpromoted,
# which depends on supersession chains across superseded/archived task files
# that the console's task projection does not reconstruct. Guessing it could
# report a node as excluded that the engine would happily plan; omitting it can
# only report a node as runnable that the engine then skips — fail-open, and the
# loop's own log says so when it happens.
_L1_SELECTION_POLICY = ("node-lease", "area-lease", "scope-overlap", "cap")

# engine/lib.sh: SINGULAR_AREA_PREFIX="${SINGULAR_AREA_PREFIX:-internal/}".
_DEFAULT_AREA_PREFIX = "internal/"

def _cfg_area_paths(cfg: dict[str, Any]) -> str | None:
    """config `areas` {area: path | [paths]} -> the SINGULAR_AREA_PATHS text."""
    areas = cfg.get("areas")
    if not isinstance(areas, dict):
        return None
    lines = []
    for key, value in areas.items():
        if isinstance(value, list):
            value = ":".join(str(v) for v in value)
        lines.append(f"{key}={value}")
    return "\n".join(lines)


# Structured singular.config.json fields that engine/lib.sh's
# singular_json_config_to_env turns into these env vars. env{} still wins: the
# loader emits the env map last, so it overrides on every source.
_CONFIG_DERIVED_ENV = {
    "SINGULAR_AREA_PATHS": _cfg_area_paths,
    "SINGULAR_AREA_PREFIX": lambda cfg: cfg.get("areaPrefix"),
}


def _engine_env_value(repo: Path, key: str) -> str | None:
    """One engine env knob, resolved from the repo's files. Read-only.

    Precedence mirrors collect_config: `.singular-state/.env` (whitelisted to this
    key, so secrets are never parsed) > singular.config.json env{} > the
    structured config field engine/lib.sh derives the same variable from. The
    console's OWN process environment is deliberately not consulted: the console
    observes the repo's configuration, it is not a participant in the loop's
    shell, and inheriting a stray export would make it report a cap the engine
    would never use."""
    override = parse_env_overrides(repo, {key}).get(key)
    if override not in (None, ""):
        return override
    cfg, _resolution, _error = _selected_json_config(repo)
    cfg = cfg if isinstance(cfg, dict) else {}
    config_env = cfg.get("env") if isinstance(cfg.get("env"), dict) else {}
    value = config_env.get(key)
    if isinstance(value, (str, int, float)) and not isinstance(value, bool) and str(value) != "":
        return str(value)
    derive = _CONFIG_DERIVED_ENV.get(key)
    if derive is not None:
        derived = derive(cfg)
        if derived not in (None, ""):
            return str(derived)
    return None


def _l1_area_scopes(repo: Path, areas: Any) -> dict[str, list[str]]:
    """{area: [write-scope path...]}, mirroring engine/lib.sh
    `singular_l1_area_write_scopes`: the SINGULAR_AREA_PATHS map (one
    "area=path1[:path2]" per line) when the area is mapped, else
    SINGULAR_AREA_PREFIX (default internal/) + area + "/". Read-only."""
    mapped: dict[str, list[str]] = {}
    raw = _engine_env_value(repo, "SINGULAR_AREA_PATHS") or ""
    for line in raw.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        mapped[key] = [part for part in value.split(":") if part]
    prefix = _engine_env_value(repo, "SINGULAR_AREA_PREFIX") or _DEFAULT_AREA_PREFIX
    out: dict[str, list[str]] = {}
    for area in (areas or []):
        area = str(area)
        if not area:
            continue
        out[area] = list(mapped[area]) if area in mapped else [f"{prefix}{area}/"]
    return out


def _l1_selection_limits(repo: Path) -> tuple[bool, int]:
    """(enabled, cap) exactly as the engine resolves them. Read-only.

    SINGULAR_ENABLE_L1_PARALLEL != "1" means there is no fanout at all — the loop
    advances one node per cycle — so the honest cap is 1, not whatever
    SINGULAR_MAX_L1_CONCURRENT happens to say. When enabled, singular_l1_fanout's
    own rule applies: default 3, and any non-numeric or zero value floors to 1."""
    enabled = str(_engine_env_value(repo, "SINGULAR_ENABLE_L1_PARALLEL") or "").strip() == "1"
    if not enabled:
        return False, 1
    raw = _engine_env_value(repo, "SINGULAR_MAX_L1_CONCURRENT")
    raw = "3" if raw in (None, "") else str(raw).strip()
    return True, (int(raw) if raw.isdigit() and int(raw) >= 1 else 1)


def compute_l1_selection_native(frontier_entries: Any, l1_leases: Any,
                                area_scopes: Any, cap: Any,
                                enabled: bool = True) -> dict[str, Any]:
    """Replica of engine/lib.sh `singular_select_l1_frontier`. Pure.

    Returns {"selected": [node...], "exclusions": {node: {"rule", "detail"}}}.
    `selected` is the same node list the engine would plan for the same frontier,
    leases and scope map — frontier order preserved, one node per area, no
    write-scope overlap, capped. `exclusions` is the part the engine computes and
    discards.

    Rules, in the engine's order: `node-lease` (the node itself already holds an
    active L1 lease), `area-lease` (its area does), `batch-area` (one node per
    area within a batch), `scope-overlap-active` / `scope-overlap-batch` (a
    path-prefix conflict between write scopes), `cap` (the selection is full).
    An intrinsic rule is reported ahead of `cap` so a node blocked by both is
    named by the constraint that would still block it if the cap were raised;
    the engine breaks out of its loop when full, which is why reporting a
    different label there cannot change `selected`."""
    try:
        limit = int(cap)
    except (TypeError, ValueError):
        limit = 1
    limit = max(0, limit)
    if not enabled:
        limit = min(limit, 1)

    def useful_scope(value: Any) -> str:
        value = str(value or "").strip()
        if not value or "/" not in value or " " in value:
            return ""
        return value.rstrip("/")

    def path_conflict(a: str, b: str) -> bool:
        if not a or not b:
            return False
        return a == b or a.startswith(b.rstrip("/") + "/") or b.startswith(a.rstrip("/") + "/")

    def first_conflict(left: list[str], right: list[str]) -> tuple[str, str] | None:
        for a in left:
            for b in right:
                if path_conflict(a, b):
                    return a, b
        return None

    def scopes_of(raw: Any) -> list[str]:
        items = raw if isinstance(raw, list) else []
        return [s for s in (useful_scope(v) for v in items) if s]

    active_nodes: set[str] = set()
    active_area_holder: dict[str, str] = {}
    active_scopes: list[tuple[str, list[str]]] = []
    for lease in (l1_leases or []):
        if not isinstance(lease, dict) or lease.get("status") not in L1_ACTIVE_STATUSES:
            continue
        holder = str(lease.get("node") or "")
        area = str(lease.get("area") or "")
        if holder:
            active_nodes.add(holder)
        if area and area not in active_area_holder:
            active_area_holder[area] = holder
        active_scopes.append((holder, scopes_of(lease.get("allowedWriteScopes"))))

    selected: list[str] = []
    exclusions: dict[str, dict[str, str]] = {}
    selected_area_holder: dict[str, str] = {}
    selected_scopes: list[tuple[str, list[str]]] = []
    for entry in (frontier_entries or []):
        if not isinstance(entry, dict):
            continue
        node = str(entry.get("node") or "")
        if not node:
            continue
        area = str(entry.get("area") or "")
        label = f"{area} area" if area else "an area-less node"
        if node in active_nodes:
            exclusions[node] = {"rule": "node-lease",
                                "detail": f"{node} already holds an active L1 lease"}
            continue
        if area in active_area_holder:
            holder = active_area_holder[area]
            exclusions[node] = {"rule": "area-lease",
                                "detail": f"{label} has an active L1 lease"
                                          + (f" ({holder})" if holder else "")}
            continue
        if area in selected_area_holder:
            holder = selected_area_holder[area]
            exclusions[node] = {"rule": "batch-area",
                                "detail": f"{label} already selected ({holder})"}
            continue
        if area:
            scope_list = area_scopes.get(area) if isinstance(area_scopes, dict) else None
            if scope_list is None:
                # Unmapped area: the same fallback the engine's loader applies.
                scope_list = [f"{_DEFAULT_AREA_PREFIX}{area}/"]
            scopes = scopes_of(list(scope_list))
        else:
            scopes = []

        excluded: dict[str, str] | None = None
        for holder, other in active_scopes:
            clash = first_conflict(scopes, other)
            if clash:
                excluded = {"rule": "scope-overlap-active",
                            "detail": f"write scope {clash[0]} overlaps {clash[1]} held by "
                                      + (f"active lease {holder}" if holder else "an active lease")}
                break
        if excluded is None:
            for holder, other in selected_scopes:
                clash = first_conflict(scopes, other)
                if clash:
                    excluded = {"rule": "scope-overlap-batch",
                                "detail": f"write scope {clash[0]} overlaps {clash[1]} already "
                                          f"selected by {holder}"}
                    break
        if excluded is None and len(selected) >= limit:
            excluded = {"rule": "cap", "detail": f"concurrency cap {limit} reached"}
        if excluded is not None:
            exclusions[node] = excluded
            continue
        selected.append(node)
        selected_area_holder.setdefault(area, node)
        selected_scopes.append((node, scopes))
    return {"selected": selected, "exclusions": exclusions}


def compute_l1_selection(repo: Path, frontier_entries: Any = None) -> dict[str, Any]:
    """The `l1Selection` payload block plus the per-node decisions behind it.

    Read-only. Returns {"block", "selected", "exclusions"}. /api/dag and
    /api/overview emit the same `block`, so the DAG lens and the plan header
    can never disagree about why a ready node is not running."""
    if frontier_entries is None:
        frontier_entries = compute_frontier_native(repo).get("frontier") or []
    entries = [e for e in frontier_entries if isinstance(e, dict)]
    enabled, cap = _l1_selection_limits(repo)
    areas: list[str] = []
    for entry in entries:
        area = str(entry.get("area") or "")
        if area and area not in areas:
            areas.append(area)
    result = compute_l1_selection_native(entries, collect_l1_leases(repo),
                                         _l1_area_scopes(repo, areas), cap, enabled)
    area_by_node = {str(e.get("node")): e.get("area") for e in entries if e.get("node")}
    block = {
        "enabled": enabled,
        "cap": cap,
        "readyByDependency": len(entries),
        "runnableNow": len(result["selected"]),
        "serialized": [{"node": node, "area": area_by_node.get(node),
                        "rule": excl["rule"], "detail": excl["detail"]}
                       for node, excl in result["exclusions"].items()],
        "policy": list(_L1_SELECTION_POLICY),
    }
    return {"block": block, "selected": result["selected"], "exclusions": result["exclusions"]}


def derive_stop_reason(repo: Path, loop_info: dict[str, Any]) -> str | None:
    """Why the loop is stopped, in one operator sentence, or None when it isn't.

    PMGO-003: the console could prove the loop was stopped and could not say why,
    so "stopped" read as "broken". Order is by actionability — an unapproved
    human gate on a node that is otherwise dependency-ready is a decision waiting
    on a person, and naming the node turns the status into a next action. Failing
    that, the loop's own STATUS.md note when it explains a stop or halt, and
    finally the bare sentinel."""
    if not loop_info.get("stopPresent"):
        return None
    try:
        ready = {str(e.get("node")) for e in (compute_frontier_native(repo).get("frontier") or [])
                 if isinstance(e, dict)}
        for gate in collect_human_gates(repo):
            if str(gate.get("state") or "") == "approved":
                continue
            node = str(gate.get("node") or "")
            if node and node in ready:
                return f"operator approval required for {node}"
    except Exception:  # an observer never fails the page over a stop reason
        pass
    note = str(loop_info.get("note") or "").strip()
    if note and re.search(r"stop|halt", note, re.I):
        return note
    return "STOP sentinel present"


def collect_overview(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    registry = load_dag_registry(repo)
    gate_records = _all_gate_records(repo)
    gate_status = {node: record["status"] for node, record in gate_records.items()}
    progress, stages, frontier = compute_plan_progress(registry, gate_status, gate_records)
    status_path = repo / STATUS_REL
    loop = parse_status_md(status_path.read_text(errors="replace") if status_path.exists() else "")
    loop["stopPresent"] = (repo / STOP_REL).exists()
    circuit = read_json(repo / CIRCUIT_REL, {}) or {}
    loop["consecFails"] = circuit.get("consecFails")
    loop["stopReason"] = derive_stop_reason(repo, loop)
    pulse, frontier_activity = compute_loop_pulse(
        load_events_index(repo), registry, gate_status, _iso_to_epoch(utc_now()))
    pulse["running"] = (not loop.get("stopPresent")) and not re.search(
        r"stop|halt", str(loop.get("note") or ""), re.I)
    pulse["iteration"] = loop.get("iteration")
    pulse["integrationsLifetime"] = loop.get("integrationsLifetime")
    pulse["parkedLifetime"] = loop.get("parkedLifetime")
    tasks_dir = repo / TASKS_DIR_REL
    tasks_count = sum(1 for _ in tasks_dir.glob("TASK-*.md")) if tasks_dir.exists() else 0
    inputs = {
        "runtime": [
            {"path": DAG_REL, "role": "frontier structure",
             "note": "the executable DAG — read every cycle to pick the next node"},
            {"path": GATES_REL + "/", "role": "completion authority", "count": len(gate_status),
             "note": "gate-result files; a passed gate marks a node complete"},
            {"path": TASKS_DIR_REL + "/", "role": "ready queue", "count": tasks_count,
             "note": "TASK-*.md; only Status: ready slices are dispatched"},
        ],
        "authoring": [
            {"path": STAGE_DOC_REL,
             "note": "the source the DAG was distilled from — NOT read at runtime"},
            {"path": PLATFORM_VISION_REL,
             "note": "product vision behind the plan — NOT read at runtime"},
        ],
        "plannerPrompt": {
            "note": "each L1 planner prompt is assembled per run from a template + the DAG "
                    "node's fields + the existing-task list; the assembled prompt is saved at",
            "ref": ".singular-state/runs/<id>/planner-prompt.md",
        },
    }
    return {
        "schema": "singular.codex.plan-overview.v0",
        "generatedAt": utc_now(),
        "progress": progress,
        "stages": stages,
        "frontier": frontier,
        # Same block /api/dag emits: ready-by-dependency vs runnable-now and the
        # named reason for the difference, so the plan header and the DAG lens
        # cannot tell two different stories about the same cycle.
        "l1Selection": compute_l1_selection(repo)["block"],
        "pulse": pulse,
        "frontierActivity": frontier_activity,
        "inputs": inputs,
        "settings": collect_settings(repo),
        "loop": loop,
    }


_OVERVIEW_CACHE = _ComputeCache(collect_overview, 6.0)


def load_overview(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    return _OVERVIEW_CACHE.get(str(repo), repo)


# --------------------------------------------------------------------------- #
# /api/dag — full DAG view for the Plan surface (singular.codex.dag.v0)        #
# --------------------------------------------------------------------------- #

_DAG_TASK_BUCKETS = ("integrated", "active", "ready", "blocked", "failed", "other")
_DAG_ACTIVE_STATUSES = {"running", "planned", "dispatched", "needs-review",
                        "accepted", "in-progress", "active"}
_DAG_NODE_LINE_RE = re.compile(r"^dag node:\s*(\S+)", re.IGNORECASE)


def _dag_task_bucket(status: str | None) -> str:
    s = (status or "").lower()
    if s in DONE_STATUSES:
        return "integrated"
    if s in _DAG_ACTIVE_STATUSES:
        return "active"
    if s == "ready":
        return "ready"
    if s in BLOCKED_STATUSES:
        return "blocked"
    if s in FAILED_STATUSES:
        return "failed"
    return "other"


def _events_node_map(events_idx: dict[str, Any]) -> dict[str, str]:
    """task -> DAG node from the events index (newest event with data.node wins)."""
    out: dict[str, str] = {}
    for tid, evs in (events_idx.get("by_task") or {}).items():
        for ev in evs:
            node = _ev_data(ev).get("node")
            if node:
                out[tid] = str(node)
    return out


def _task_header_node(path_str: str) -> str | None:
    """`DAG node:` header from a task file head (0.5.0+ tasks carry it)."""
    try:
        with open(path_str, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i > 40:
                    break
                m = _DAG_NODE_LINE_RE.match(line)
                if m:
                    return strip_ticks(m.group(1))
    except OSError:
        pass
    return None


def collect_dag_view(repo: Path) -> dict[str, Any]:
    """Full DAG for the Plan surface lenses: registry nodes merged with gate
    results, per-node task rollups, L1 leases, the live frontier, and stage/
    area swimlane metadata. Task->node attribution comes from events (the
    newest event carrying data.node wins) with the `DAG node:` task header as
    fallback. Pure filesystem; no subprocesses. Empty repo -> empty arrays."""
    repo = repo.resolve()
    raw = read_json(repo / DAG_REL, {}) or {}
    by_id = (load_dag_registry(repo).get("by_id") or {})
    validate_env = validate_dag_native(repo)
    validate = {"ok": bool(validate_env.get("ok")),
                "errors": ([] if validate_env.get("ok")
                           else [e for e in str(validate_env.get("stdout") or "").split("; ") if e])}

    task_node = dict(_events_node_map(load_events_index(repo)))

    tasks = collect_tasks(repo)
    leases = collect_leases(repo)
    lease_status = {str(l.get("taskId")): str(l.get("status") or "") for l in leases if l.get("taskId")}
    lease_area = {str(l.get("taskId")): str(l.get("area") or "") for l in leases if l.get("taskId")}

    status_by_task: dict[str, str] = {}
    area_by_task: dict[str, str] = {}
    for t in tasks:
        tid = str(t.get("id"))
        status_by_task[tid] = lease_status.get(tid) or str(t.get("status") or "unknown")
        area_by_task[tid] = str(t.get("area") or "") or lease_area.get(tid, "")
        if tid not in task_node:
            node = _task_header_node(str(t.get("path") or ""))
            if node:
                task_node[tid] = node
    for tid, status in lease_status.items():
        status_by_task.setdefault(tid, status)
        area_by_task.setdefault(tid, lease_area.get(tid, ""))

    node_tasks: dict[str, list[str]] = {}
    for tid, node in task_node.items():
        if tid in status_by_task and node in by_id:
            node_tasks.setdefault(node, []).append(tid)

    def counts_of(tids: list[str]) -> dict[str, int]:
        counts = {bucket: 0 for bucket in _DAG_TASK_BUCKETS}
        counts["total"] = len(tids)
        for tid in tids:
            counts[_dag_task_bucket(status_by_task.get(tid))] += 1
        return counts

    l1_by_node = {str(l.get("node")): l for l in collect_l1_leases(repo)}
    frontier_entries = compute_frontier_native(repo).get("frontier") or []
    frontier_ids = {str(e.get("node")) for e in frontier_entries}
    # AXON-002: dependency-ready is not runnable. Replicate the engine's own L1
    # selection so each ready node carries the constraint that holds it back.
    selection = compute_l1_selection(repo, frontier_entries)
    runnable_ids = set(selection["selected"])
    exclusions = selection["exclusions"]

    ranks = compute_node_ranks(by_id)

    # Human gates: the node carrying the gate, and every node the gate blocks
    # while it is unapproved (collect_human_gates already empties blockedNodes
    # once approved).
    human_gate_by_node: dict[str, dict[str, Any]] = {}
    human_gate_blocked: dict[str, list[str]] = {}
    for gate in collect_human_gates(repo):
        gate_node = str(gate.get("node") or "")
        if not gate_node:
            continue
        projection: dict[str, Any] = {"state": gate.get("state"), "gateId": gate.get("gateId")}
        if gate.get("reason"):
            projection["reason"] = gate.get("reason")
        human_gate_by_node[gate_node] = projection
        if str(gate.get("state") or "") != "approved":
            for blocked in (gate.get("blockedNodes") or []):
                human_gate_blocked.setdefault(str(blocked), []).append(gate_node)

    nodes_out: list[dict[str, Any]] = []
    node_out_by_id: dict[str, dict[str, Any]] = {}
    edges: list[dict[str, str]] = []
    stage_nodes: dict[str, list[str]] = {}
    area_nodes: dict[str, list[str]] = {}
    for nid, node in by_id.items():
        try:
            gate = _load_gate_for_node(repo, nid)
        except Exception:
            gate = None
        if isinstance(gate, dict):
            gate_out: dict[str, Any] = {"status": str(gate.get("status") or "unknown"),
                                        "recordedAt": gate.get("recordedAt"),
                                        "evidenceClass": gate.get("evidenceClass"),
                                        "authoritative": gate.get("authoritative")}
            cohort = _gate_cohort(gate)
            if cohort:  # only a successful gate belongs to a completion cohort
                gate_out["cohort"] = cohort
        else:
            gate_out = {"status": "absent"}
        tids = sorted(node_tasks.get(nid, []))
        entry: dict[str, Any] = {
            "id": nid,
            "stage": node.get("stage"), "area": node.get("area"),
            "layer": node.get("layer"), "kind": node.get("kind"),
            "dependsOn": [str(d) for d in (node.get("dependsOn") or []) if str(d)],
            "requiredCompletion": node.get("requiredCompletion"),
            "description": node.get("description"),
            # Longest-path depth over all dependsOn edges: equal ranks are nodes
            # that can genuinely run in the same wave.
            "rank": ranks.get(nid, 0),
            "gate": gate_out,
            "tasks": {"taskIds": tids, "counts": counts_of(tids)},
            "frontier": nid in frontier_ids,
        }
        if nid in frontier_ids:
            entry["runnable"] = nid in runnable_ids
            excluded = exclusions.get(nid)
            if excluded:
                entry["exclusion"] = dict(excluded)
        if nid in human_gate_by_node:
            entry["humanGate"] = human_gate_by_node[nid]
        if nid in human_gate_blocked:
            entry["humanGateBlockedBy"] = sorted(human_gate_blocked[nid])
        lease = l1_by_node.get(nid)
        if isinstance(lease, dict):
            scopes = lease.get("allowedWriteScopes")
            entry["l1Lease"] = {"status": lease.get("status"),
                                "active": bool(lease.get("active")),
                                "area": lease.get("area"),
                                "allowedWriteScopes": ([str(s) for s in scopes]
                                                       if isinstance(scopes, list) else []),
                                "updatedAt": lease.get("updatedAt")}
        nodes_out.append(entry)
        node_out_by_id[nid] = entry
        for dep in entry["dependsOn"]:
            edges.append({"from": dep, "to": nid})
        if entry["stage"]:
            stage_nodes.setdefault(str(entry["stage"]), []).append(nid)
        if entry["area"]:
            area_nodes.setdefault(str(entry["area"]), []).append(nid)

    stages = []
    # Dependency order first (PMGO-001), lexical order only as the tie-break.
    stage_ranks = {sid: min([ranks.get(i, 0) for i in ids] or [0])
                   for sid, ids in stage_nodes.items()}
    for sid in sorted(stage_nodes, key=lambda s: _stage_order_key(s, stage_ranks)):
        ids = sorted(stage_nodes[sid])
        passed = sum(
            1 for i in ids
            if node_out_by_id[i]["gate"]["status"]
            in {"passed", "passed-with-acknowledged-baseline"}
        )
        has_active = any(node_out_by_id[i]["tasks"]["counts"]["active"] for i in ids)
        status = ("complete" if passed == len(ids)
                  else "in-progress" if (passed or has_active) else "pending")
        stages.append({"id": sid, "nodes": ids, "total": len(ids), "passed": passed,
                       "status": status})

    area_task_ids: dict[str, list[str]] = {}
    for tid, area in area_by_task.items():
        if area:
            area_task_ids.setdefault(area, []).append(tid)
    areas = [{"id": aid, "nodes": sorted(area_nodes[aid]),
              "taskCounts": counts_of(area_task_ids.get(aid, []))}
             for aid in sorted(area_nodes)]

    return {
        "schema": "singular.codex.dag.v0",
        "generatedAt": utc_now(),
        "validate": validate,
        "layers": [str(x) for x in raw.get("layers")] if isinstance(raw.get("layers"), list) else [],
        "kinds": [str(x) for x in raw.get("kinds")] if isinstance(raw.get("kinds"), list) else [],
        "stages": stages,
        "areas": areas,
        "nodes": nodes_out,
        "edges": edges,
        "l1Selection": selection["block"],
    }


_DAG_VIEW_CACHE = _ComputeCache(collect_dag_view, 6.0)


def load_dag_view(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    return _DAG_VIEW_CACHE.get(str(repo), repo)


# --------------------------------------------------------------------------- #
# /api/timeline — real execution intervals (singular.codex.timeline.v0)        #
# --------------------------------------------------------------------------- #

_INTERVAL_SOFT_CLOSE_TYPES = ("l1.task_accepted", "l1.task_failed",
                              "l1.task_terminal", "l1.aborted")
_TIMELINE_CYCLE_CAP = 250


def build_task_intervals(task_events: list[dict[str, Any]],
                         dispatch_rec: dict[str, Any] | None = None,
                         lease: dict[str, Any] | None = None) -> tuple[list[dict[str, Any]], bool]:
    """Reconstruct per-attempt execution intervals for one task. Pure.

    Each l1.dispatch_started opens an attempt; the canonical close is the
    first origin.dispatch_reaped in that attempt's window (it carries
    exitCode/outcome), falling back to accept/fail/terminal events. Dispatch
    records are overwritten per attempt, so they can only reconcile the
    LATEST attempt (state=launched with no reapedAt -> live). Tasks that
    predate the events window synthesize one interval from the dispatch
    record, else from lease createdAt->updatedAt. Returns (intervals, live)."""
    events = sorted((e for e in (task_events or []) if isinstance(e, dict)),
                    key=lambda e: str(e.get("ts") or ""))
    starts = [e for e in events if e.get("type") == "l1.dispatch_started"]
    reaps = [e for e in events if e.get("type") == "origin.dispatch_reaped"]
    softs = [e for e in events if e.get("type") in _INTERVAL_SOFT_CLOSE_TYPES]
    rec = dispatch_rec if isinstance(dispatch_rec, dict) else {}
    lease = lease if isinstance(lease, dict) else {}

    intervals: list[dict[str, Any]] = []
    for i, start in enumerate(starts):
        s_ts = str(start.get("ts") or "")
        next_ts = str(starts[i + 1].get("ts") or "") if i + 1 < len(starts) else None

        def first_in_window(pool: list[dict[str, Any]]) -> dict[str, Any] | None:
            for ev in pool:
                ts = str(ev.get("ts") or "")
                if ts >= s_ts and (next_ts is None or ts <= next_ts):
                    return ev
            return None

        close = first_in_window(reaps) or first_in_window(softs)
        close_data = _ev_data(close) if close else {}
        intervals.append({
            "startedAt": start.get("ts"),
            "endedAt": close.get("ts") if close else None,
            "kind": "dispatch" if i == 0 else "retry",
            "runId": _ev_data(start).get("runId"),
            "outcome": close_data.get("outcome"),
            "exitCode": close_data.get("exitCode"),
            "source": "events",
        })

    live = False
    if intervals and intervals[-1]["endedAt"] is None:
        last = intervals[-1]
        if rec.get("state") == "reaped" and rec.get("reapedAt"):
            last["endedAt"] = rec.get("reapedAt")
            if last["outcome"] is None:
                last["outcome"] = rec.get("outcome")
            if last["exitCode"] is None:
                last["exitCode"] = rec.get("exitCode")
            last["source"] = "dispatch"
        elif rec.get("state") == "launched":
            live = True

    if not intervals:
        if rec.get("startedAt"):
            live = rec.get("state") == "launched" and not rec.get("reapedAt")
            intervals.append({"startedAt": rec.get("startedAt"), "endedAt": rec.get("reapedAt"),
                              "kind": "dispatch", "runId": rec.get("runId"),
                              "outcome": rec.get("outcome"), "exitCode": rec.get("exitCode"),
                              "source": "dispatch"})
        elif lease.get("createdAt"):
            intervals.append({"startedAt": lease.get("createdAt"), "endedAt": lease.get("updatedAt"),
                              "kind": "dispatch", "runId": lease.get("runId"),
                              "outcome": None, "exitCode": None, "source": "lease"})
    return intervals, live


def collect_timeline(repo: Path) -> dict[str, Any]:
    """Real execution history for the Gantt lens: per-task attempt intervals,
    gate marks, and L0 reconcile cycle spans. Pure filesystem; bounded by the
    events-index tail window (window.truncated flags degraded coverage)."""
    repo = repo.resolve()
    idx = load_events_index(repo)
    by_task_ev = idx.get("by_task") or {}
    node_map = _events_node_map(idx)
    leases = {str(l.get("taskId")): l for l in collect_leases(repo) if l.get("taskId")}
    tasks_meta = {t["id"]: t for t in collect_tasks(repo)}
    dispatch: dict[str, dict[str, Any]] = {}
    for path in sorted(state_path(repo, "dispatch").glob("TASK-*.json")):
        d = read_json(path, {})
        if isinstance(d, dict) and d.get("taskId"):
            dispatch[str(d["taskId"])] = d

    tasks_out: list[dict[str, Any]] = []
    for tid in sorted(set(by_task_ev) | set(leases) | set(dispatch)):
        lease = leases.get(tid) or {}
        meta = tasks_meta.get(tid) or {}
        evs = by_task_ev.get(tid) or []
        intervals, live = build_task_intervals(evs, dispatch.get(tid), lease)
        if not intervals:
            continue
        integrated_at = None
        for ev in evs:
            if ev.get("type") == "integration.integrated":
                integrated_at = ev.get("ts")
        status = str(lease.get("status") or meta.get("status") or "unknown")
        node = node_map.get(tid)
        if not node and meta.get("path"):
            node = _task_header_node(str(meta["path"]))
        tasks_out.append({
            "taskId": tid,
            "node": node,
            "area": lease.get("area") or meta.get("area") or None,
            "status": status,
            "retryCount": lease.get("retryCount"),
            "branch": lease.get("branch") or meta.get("workerBranch") or None,
            "intervals": intervals,
            "liveNow": live,
            "integratedAt": integrated_at or (lease.get("updatedAt")
                                              if _dag_task_bucket(status) == "integrated" else None),
        })

    gates: list[dict[str, Any]] = []
    for nid in (load_dag_registry(repo).get("by_id") or {}):
        try:
            gate = _load_gate_for_node(repo, nid)
        except Exception:
            gate = None
        if isinstance(gate, dict) and gate.get("recordedAt"):
            gates.append({"node": nid, "status": gate.get("status"),
                          "recordedAt": gate.get("recordedAt"),
                          "evidenceClass": gate.get("evidenceClass")})
    gates.sort(key=lambda g: str(g["recordedAt"]))

    cycles: list[dict[str, Any]] = []
    open_by_run: dict[str, dict[str, Any]] = {}
    for ev in idx.get("cycles") or []:
        data = _ev_data(ev)
        rid = str(data.get("runId") or "")
        if ev.get("type") == "origin.reconcile_started":
            span = {"runId": rid, "startedAt": ev.get("ts"), "endedAt": None,
                    "mode": data.get("mode")}
            open_by_run[rid] = span
            cycles.append(span)
        elif rid in open_by_run and open_by_run[rid]["endedAt"] is None:
            open_by_run[rid]["endedAt"] = ev.get("ts")
    cycles = cycles[-_TIMELINE_CYCLE_CAP:]

    truncated = False
    try:
        truncated = _events_path(repo).stat().st_size > EVENTS_INDEX_MAX_BYTES
    except OSError:
        pass
    return {
        "schema": "singular.codex.timeline.v0",
        "generatedAt": utc_now(),
        "now": utc_now(),
        "window": {"truncated": truncated},
        "tasks": tasks_out,
        "gates": gates,
        "cycles": cycles,
        "counts": {"tasks": len(tasks_out),
                   "intervals": sum(len(t["intervals"]) for t in tasks_out),
                   "cycles": len(cycles)},
    }


def filter_timeline_since(data: dict[str, Any], since: str) -> dict[str, Any]:
    """Post-cache ?since= filter: keep tasks with any open interval or one
    ending at/after `since` (ISO-8601 Z strings compare lexically)."""
    def keep_task(t: dict[str, Any]) -> bool:
        if t.get("liveNow"):
            return True
        return any(i.get("endedAt") is None or str(i["endedAt"]) >= since
                   for i in t.get("intervals") or [])

    out = dict(data)
    out["tasks"] = [t for t in data.get("tasks") or [] if keep_task(t)]
    out["cycles"] = [c for c in data.get("cycles") or []
                     if c.get("endedAt") is None or str(c["endedAt"]) >= since]
    out["gates"] = [g for g in data.get("gates") or [] if str(g.get("recordedAt") or "") >= since]
    out["counts"] = {"tasks": len(out["tasks"]),
                     "intervals": sum(len(t.get("intervals") or []) for t in out["tasks"]),
                     "cycles": len(out["cycles"])}
    return out


_TIMELINE_CACHE = _ComputeCache(collect_timeline, 6.0)


def load_timeline(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    return _TIMELINE_CACHE.get(str(repo), repo)


# --------------------------------------------------------------------------- #
# Provider registry (single source of truth for /api/providers + derivation)   #
# --------------------------------------------------------------------------- #
#
# One dict per agent-CLI runtime singular can drive. Probe logic reads this table
# (no per-provider if-ladders): ``authProbe`` names a non-interactive status
# subcommand + a parser; ``inference`` names a pure FS/env fallback. Auth
# resolution order is CLI status -> env-key presence -> credential-file
# inference -> unknown. SECRETS RULE: parsers/inference emit only presence
# booleans, counts, provider ids, type strings, and the email/plan the CLI
# itself prints — never token/key VALUES or file contents.
PROVIDERS = [
    {"id": "claude", "name": "Claude Code", "binary": "claude",
     "runnerScript": "claude-run.sh", "loginCommand": "claude auth login",
     "envKeys": ["ANTHROPIC_API_KEY"],
     "authProbe": {"args": ["auth", "status"], "parser": "claude"},
     "inference": "credfile", "credFiles": [".claude/.credentials.json"]},
    {"id": "codex", "name": "Codex CLI", "binary": "codex",
     "runnerScript": "codex-run.sh", "loginCommand": "codex login",
     "envKeys": ["OPENAI_API_KEY"],
     "authProbe": {"args": ["login", "status"], "parser": "codex"},
     "inference": "credfile", "credFiles": [".codex/auth.json"]},
    {"id": "gemini", "name": "Gemini CLI", "binary": "gemini",
     "runnerScript": "gemini-run.sh", "loginCommand": "gemini",
     "envKeys": ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
     "authProbe": None, "inference": "gemini"},
    {"id": "opencode", "name": "OpenCode", "binary": "opencode",
     "runnerScript": "opencode-run.sh", "loginCommand": "opencode auth login",
     "envKeys": ["OPENCODE_AUTH_CONTENT"],
     "authProbe": {"args": ["auth", "list"], "parser": "opencode"},
     "inference": "opencode"},
    {"id": "cursor", "name": "Cursor CLI", "binary": "cursor-agent",
     "runnerScript": "cursor-run.sh", "loginCommand": "cursor-agent login",
     "envKeys": ["CURSOR_API_KEY"],
     "authProbe": {"args": ["about", "--format", "json"], "parser": "cursor"},
     "inference": "credfile", "credFiles": [".cursor/cli-config.json"]},
    {"id": "openrouter", "name": "OpenRouter", "binary": "opencode",
     "runnerScript": "openrouter-run.sh", "loginCommand": None,
     "envKeys": ["OPENROUTER_API_KEY"],
     # No probe and no credential-file inference: OPENROUTER_API_KEY is the
     # signal, and OpenCode's own auth store would report "authenticated" for
     # any provider the operator has logged into, OpenRouter or not.
     "authProbe": None, "inference": None},
    {"id": "grok", "name": "Grok CLI", "binary": "grok",
     "runnerScript": "grok-run.sh", "loginCommand": None,
     "envKeys": [],
     "authProbe": None, "inference": None},
]
_PROVIDERS_BY_RUNNER = {p["runnerScript"]: p["id"] for p in PROVIDERS}


def _provider_from_runner(runner: str) -> str:
    """Provider id for a runner script basename via the registry.

    claude-run.sh->claude ... cursor-run.sh->cursor; an unknown ``<name>-run.sh``
    yields ``<name>`` (basename minus the suffix); anything else defaults to the
    engine's own default runtime, codex."""
    base = os.path.basename(str(runner or "")).strip()
    if base in _PROVIDERS_BY_RUNNER:
        return _PROVIDERS_BY_RUNNER[base]
    if base.endswith("-run.sh"):
        return base[: -len("-run.sh")] or "codex"
    return "codex"


def _engine_dir(env: dict[str, str] | None = None) -> Path:
    """Directory holding the runner scripts, resolved like resolve_settings_dir:
    ``$SINGULAR_ENGINE_HOME/engine`` when set (how ``singular console`` launches the
    server), else the installed layout ``plugin/../engine`` relative to __file__."""
    env = env if env is not None else os.environ
    home = env.get("SINGULAR_ENGINE_HOME")
    if home:
        return Path(home) / "engine"
    return Path(__file__).resolve().parent.parent.parent / "engine"


# --------------------------------------------------------------------------- #
# /api/config — resolved per-role runner config (singular.codex.config.v0)     #
# --------------------------------------------------------------------------- #
# Key families mirror engine/claude-run.sh + engine/codex-run.sh resolution;
# the trailing literal is the runner script's own fallback default.

_CONFIG_ROLE_KEYS = {
    "claude": {
        "planner":     ("SINGULAR_CLAUDE_PLANNER_MODEL", "SINGULAR_CLAUDE_PLANNER_EFFORT", "xhigh"),
        "implementer": ("SINGULAR_CLAUDE_L2_MODEL", "SINGULAR_CLAUDE_L2_EFFORT", "medium"),
        "auditor":     ("SINGULAR_CLAUDE_AUDITOR_MODEL", "SINGULAR_CLAUDE_AUDITOR_EFFORT", "xhigh"),
        "decider":     ("SINGULAR_CLAUDE_DECIDER_MODEL", "SINGULAR_CLAUDE_DECIDER_EFFORT", None),
    },
    "codex": {
        "planner":     ("SINGULAR_CODEX_PLANNER_MODEL", "SINGULAR_CODEX_PLANNER_REASONING_EFFORT", "high"),
        "implementer": ("SINGULAR_CODEX_IMPLEMENTER_MODEL", "SINGULAR_CODEX_L2_REASONING_EFFORT", "medium"),
        "auditor":     ("SINGULAR_CODEX_AUDITOR_MODEL", "SINGULAR_CODEX_AUDITOR_REASONING_EFFORT", "high"),
        "critic":      ("SINGULAR_CODEX_CRITIC_MODEL", "SINGULAR_CODEX_CRITIC_REASONING_EFFORT", "high"),
        "decider":     ("SINGULAR_CODEX_DECIDER_MODEL", "SINGULAR_CODEX_DECIDER_REASONING_EFFORT", "high"),
        "supervisor":  ("SINGULAR_CODEX_SUPERVISOR_MODEL", "SINGULAR_CODEX_SUPERVISOR_REASONING_EFFORT", "high"),
        "integrator":  ("SINGULAR_CODEX_INTEGRATOR_MODEL", "SINGULAR_CODEX_INTEGRATOR_REASONING_EFFORT", "high"),
    },
    # 0.9.0 providers: gemini/opencode/cursor/grok expose a single flat model key
    # (no per-role model, no reasoning-effort mapping v1). An empty fallback means
    # "CLI default" — the runner omits the model flag when the key is unset. Grok
    # is the exception and its fallback below is grok-4.6: that adapter always
    # passes --model. Every fallback here is pinned to engine/providers.json by
    # tests/test-provider-spec.sh, because a card that names a different default
    # than the one dispatch sends is the operator being told a fiction.
    "gemini":   {r: ("SINGULAR_GEMINI_MODEL", None, None) for r in ("planner", "implementer", "auditor", "decider")},
    "opencode": {r: ("SINGULAR_OPENCODE_MODEL", None, None) for r in ("planner", "implementer", "auditor", "decider")},
    "cursor":   {r: ("SINGULAR_CURSOR_MODEL", None, None) for r in ("planner", "implementer", "auditor", "decider")},
    "grok":     {r: ("SINGULAR_GROK_MODEL", None, None) for r in ("planner", "implementer", "auditor", "decider")},
    "openrouter": {r: ("SINGULAR_OPENROUTER_MODEL", None, None) for r in ("planner", "implementer", "auditor", "decider")},
}
_CONFIG_MODEL_FALLBACK = {"claude": ("SINGULAR_CLAUDE_MODEL", "claude-opus-4-8"),
                          "codex": ("SINGULAR_CODEX_MODEL", "gpt-5.5"),
                          "gemini": ("SINGULAR_GEMINI_MODEL", ""),
                          "opencode": ("SINGULAR_OPENCODE_MODEL", ""),
                          "cursor": ("SINGULAR_CURSOR_MODEL", ""),
                          "openrouter": ("SINGULAR_OPENROUTER_MODEL", ""),
                          "grok": ("SINGULAR_GROK_MODEL", "grok-4.6")}
_CONFIG_EFFORT_FALLBACK = {"claude": "SINGULAR_CLAUDE_EFFORT", "codex": None,
                           "gemini": None, "opencode": None, "cursor": None,
                           "openrouter": None, "grok": None}
_CONFIG_LIMIT_KEYS = (("maxConcurrent", "SINGULAR_MAX_CONCURRENT"),
                      ("maxDispatch", "SINGULAR_MAX_DISPATCH"),
                      ("l1Parallel", "SINGULAR_ENABLE_L1_PARALLEL"),
                      ("sliceBudget", "SINGULAR_L2_SLICE_BUDGET"),
                      ("pairedAuditPct", "SINGULAR_PAIRED_AUDIT_PCT"))
_CONFIG_FLAG_KEYS = (("ctxPacket", "SINGULAR_CTX_PACKET"),
                     ("ctxRouting", "SINGULAR_CTX_ROUTING"),
                     ("ctxArtifactScan", "SINGULAR_CTX_ARTIFACT_SCAN"),
                     ("planCritique", "SINGULAR_PLAN_CRITIQUE"),
                     ("plannerSession", "SINGULAR_PLANNER_SESSION"))


def collect_config(repo: Path) -> dict[str, Any]:
    """Resolved per-role model/effort + limits/flags for the Agents surface.
    Precedence mirrors the engine: .singular-state/.env override (whitelisted
    keys only — secrets are never read) > singular.config.json env{} > the
    runner script's fallback default. Read-only."""
    repo = repo.resolve()
    cfg, config_resolution, config_error = _selected_json_config(repo)
    if config_error:
        return {
            "schema": "singular.codex.config.v0",
            "generatedAt": utc_now(),
            "ok": False,
            "configuration": {**config_resolution, "message": config_error},
            "runner": None,
            "provider": None,
            "roles": {},
            "limits": {},
            "flags": {},
            "paths": {},
        }
    cfg_env = cfg.get("env") if isinstance(cfg.get("env"), dict) else {}
    # env{} SINGULAR_RUNNER wins over the top-level "runner" key (engine/lib.sh
    # emits env{} last, so it overrides on every source) — the runner switch is
    # written there via POST /api/settings.
    runner = str(cfg_env.get("SINGULAR_RUNNER") or cfg.get("runner") or "codex-run.sh")
    provider = _provider_from_runner(runner)

    role_keys = _CONFIG_ROLE_KEYS.get(provider)
    if role_keys is None:
        # Runner outside the registry: fall back to the flat single-model
        # convention SINGULAR_<PROVIDER>_MODEL (no per-role model, no effort).
        flat = f"SINGULAR_{provider.upper().replace('-', '_')}_MODEL"
        role_keys = {r: (flat, None, None) for r in ("planner", "implementer", "auditor", "decider")}
        fallback_model_key, fallback_model = flat, ""
        fallback_effort_key = None
    else:
        fallback_model_key, fallback_model = _CONFIG_MODEL_FALLBACK[provider]
        fallback_effort_key = _CONFIG_EFFORT_FALLBACK[provider]
    wanted: set[str] = {fallback_model_key}
    if fallback_effort_key:
        wanted.add(fallback_effort_key)
    for model_key, effort_key, _default in role_keys.values():
        wanted.update(k for k in (model_key, effort_key) if k)
    wanted.update(key for _name, key in _CONFIG_LIMIT_KEYS)
    wanted.update(key for _name, key in _CONFIG_FLAG_KEYS)
    if provider == "codex":
        wanted.update({
            "SINGULAR_CODEX_SERVICE_TIER",
            "SINGULAR_CODEX_READONLY_REASONING_EFFORT",
        })
    overrides = parse_env_overrides(repo, wanted)

    def resolve(key: str | None) -> tuple[str | None, str | None]:
        """(value, tier) for one env key: env > config > None."""
        if not key:
            return None, None
        if key in overrides and overrides[key] != "":
            return overrides[key], "env"
        val = cfg_env.get(key)
        if isinstance(val, (str, int, float)) and str(val) != "":
            return str(val), "config"
        return None, None

    roles: dict[str, Any] = {}
    for role, (model_key, effort_key, effort_default) in role_keys.items():
        model, model_src = resolve(model_key)
        src_key = model_key
        if model is None:
            model, model_src = resolve(fallback_model_key)
            src_key = fallback_model_key
        if model is None:
            model, model_src, src_key = fallback_model, "runner-default", fallback_model_key
        effort, effort_src = resolve(effort_key)
        effort_src_key = effort_key
        if effort is None and fallback_effort_key:
            effort, effort_src = resolve(fallback_effort_key)
            effort_src_key = fallback_effort_key
        if effort is None and effort_default is not None:
            effort, effort_src, effort_src_key = effort_default, "runner-default", effort_key
        roles[role] = {"model": model, "effort": effort,
                       "source": {"model": src_key, "modelTier": model_src,
                                  "effort": effort_src_key, "effortTier": effort_src}}

    if provider == "codex":
        resolver = _load_provider_resolver()
        if resolver is not None and hasattr(resolver, "codex_role_settings"):
            effective_env = dict(os.environ)
            for key, value in cfg_env.items():
                if isinstance(value, (str, int, float)) and not isinstance(value, bool):
                    effective_env[str(key)] = str(value)
            # Preserve the console's supported local override layer. Empty
            # values are significant for model fallback and normal-tier clears.
            effective_env.update(overrides)
            for role in tuple(roles):
                resolved = resolver.codex_role_settings(
                    effective_env, role, _CONFIG_MODEL_FALLBACK["codex"][1]
                )
                roles[role].update({
                    "model": resolved["model"],
                    "effort": resolved["reasoningEffort"],
                    "requestedServiceTier": resolved["requestedServiceTier"],
                    "providerObservedServiceTier": resolved["providerObservedServiceTier"],
                    "source": {
                        "model": resolved["modelSource"],
                        "effort": resolved["reasoningEffortSource"],
                        "serviceTier": resolved["serviceTierSource"],
                    },
                })

    def bag(pairs: tuple) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for name, key in pairs:
            val, _tier = resolve(key)
            out[name] = val
        return out

    return {
        "schema": "singular.codex.config.v0",
        "generatedAt": utc_now(),
        "ok": True,
        "configuration": config_resolution,
        "runner": runner,
        "provider": provider,
        "roles": roles,
        "limits": bag(_CONFIG_LIMIT_KEYS),
        "flags": bag(_CONFIG_FLAG_KEYS),
        "paths": {
            "root": str(repo),
            "tasks": str(_configured_path(repo, "SINGULAR_TASKS_DIR", TASKS_DIR_REL)),
            "state": str(_configured_path(repo, "SINGULAR_STATE_DIR", STATE_DIR_REL)),
        },
    }


_CONFIG_CACHE = _ComputeCache(collect_config, 30.0)


def load_config_view(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    return _CONFIG_CACHE.get(str(repo), repo)


# --------------------------------------------------------------------------- #
# Settings write (singular.codex.settings.v0)                                   #
# --------------------------------------------------------------------------- #
#
# The ONLY write surface in the console. It edits the whitelisted env{} block of
# singular.config.json (never leases, gates, worktrees, or the STOP sentinel), so
# the operator can retune the loop without hand-editing JSON. collect_settings
# stays read-only and untouched — this layer validates + applies, then invalidates
# the config/overview caches so the next read reflects the change.

# SINGULAR_SLEEP / SINGULAR_MAX_HOURS bound the current nap and the loop's wall
# budget, so a change only takes effect once autonomate loops back around; every
# other knob is consumed at the top of the next cycle.
#
# SINGULAR_SUPERVISOR_INTERVAL_MIN belongs here too: engine/autonomate.sh sources
# lib.sh once at startup and then reads the knob from its own shell env inside
# the loop, so a write does NOT take effect next cycle. Reporting it as
# next-cycle would promise an effect that never arrives.
_LOOP_RESTART_KEYS = {"SINGULAR_SLEEP", "SINGULAR_MAX_HOURS",
                      "SINGULAR_SUPERVISOR_INTERVAL_MIN"}

# 0.9.0 providers: writable keys not covered by SETTINGS_SPEC or the _CONFIG_*
# structures. The four *_MODEL keys are already whitelisted via _CONFIG_MODEL_FALLBACK;
# these are the ones with no other home. SINGULAR_RUNNER switches the default runner:
# engine/lib.sh emits the config env{} block AFTER the top-level "runner" key, so on
# every source the env{} SINGULAR_RUNNER wins — writing it here (kind "runner",
# validated to a bare <name>-run.sh) retargets the loop next cycle. The three
# *_TIMEOUT_SEC knobs bound the new runners' wall budget.
_PROVIDER_WRITE_KINDS = {
    "SINGULAR_RUNNER": "runner",
    "SINGULAR_GEMINI_TIMEOUT_SEC": "count",
    "SINGULAR_OPENCODE_TIMEOUT_SEC": "count",
    "SINGULAR_CURSOR_TIMEOUT_SEC": "count",
}
_RUNNER_VALUE_RE = re.compile(r"^[a-z][a-z0-9-]*-run\.sh$")


def _settings_applies_at(key: str) -> str:
    return "loop-restart" if key in _LOOP_RESTART_KEYS else "next-cycle"


def _settings_write_spec() -> tuple[set[str], dict[str, str]]:
    """(whitelist, kind_by_key) for the writable settings surface.

    Whitelist = SETTINGS_SPEC keys (minus derived, which have no real value to
    write) ∪ every model/effort env key from both providers + the model/effort
    fallbacks ∪ the config limit/flag env keys. `kind_by_key` carries the
    SETTINGS_SPEC display kind where known (drives typed validation)."""
    kinds: dict[str, str] = {}
    derived: set[str] = set()
    whitelist: set[str] = set()
    for _title, _layout, items in SETTINGS_SPEC:
        for env_key, _label, _fallback, kind, _unit, _meaning in items:
            kinds[env_key] = kind
            if kind == "derived":
                derived.add(env_key)
                continue
            whitelist.add(env_key)
    for provider_roles in _CONFIG_ROLE_KEYS.values():
        for model_key, effort_key, _default in provider_roles.values():
            whitelist.add(model_key)
            if effort_key:  # flat-model providers (gemini/opencode/cursor/grok) have none
                whitelist.add(effort_key)
    for model_key, _fallback in _CONFIG_MODEL_FALLBACK.values():
        whitelist.add(model_key)
    for effort_key in _CONFIG_EFFORT_FALLBACK.values():
        if effort_key:
            whitelist.add(effort_key)
    for _name, key in _CONFIG_LIMIT_KEYS:
        whitelist.add(key)
    for _name, key in _CONFIG_FLAG_KEYS:
        whitelist.add(key)
    # 0.9.0 provider knobs: runner switch + new-runner timeouts (the *_MODEL keys
    # already came in via _CONFIG_MODEL_FALLBACK above).
    for key, kind in _PROVIDER_WRITE_KINDS.items():
        whitelist.add(key)
        kinds[key] = kind
    # Derived knobs (e.g. SINGULAR_MAX_DISPATCH) are read-only even though they
    # also appear in _CONFIG_LIMIT_KEYS — the derived exclusion wins.
    whitelist -= derived
    return whitelist, kinds


def _infer_setting_kind(key: str, kinds: dict[str, str]) -> str:
    if key in kinds:
        return kinds[key]
    if key.endswith("_MODEL"):
        return "model"
    if key.endswith("_EFFORT") or key.endswith("_REASONING_EFFORT"):
        return "reasoning"
    return "string"


def _normalize_setting_value(kind: str, raw: Any) -> tuple[bool, str]:
    """Kind-typed validation. Returns (ok, normalized_value_or_error). An empty
    string is the delete sentinel (reverts a key to its default) and is always
    accepted. Numbers are stringified; booleans map to 1/0."""
    if isinstance(raw, bool):
        sval = "1" if raw else "0"
    elif isinstance(raw, float):
        sval = str(int(raw)) if raw.is_integer() else str(raw)
    elif isinstance(raw, int):
        sval = str(raw)
    elif isinstance(raw, str):
        sval = raw
    else:
        return False, "value must be a string or number"
    if sval.strip() == "":
        return True, ""  # delete sentinel — revert to default
    if kind in ("count", "duration", "bytes"):
        try:
            n = int(sval.strip())
        except ValueError:
            return False, f"{kind} must be a non-negative integer"
        if n < 0:
            return False, f"{kind} must be a non-negative integer"
        return True, str(n)
    if kind == "bool":
        low = sval.strip().lower()
        if low in ("1", "true"):
            return True, "1"
        if low in ("0", "false"):
            return True, "0"
        return False, "bool must be 0 or 1"
    if kind == "runner":
        # A bare <name>-run.sh script name (lowercase, no path separators): the
        # engine (lib.sh) prepends its engine dir, so a path or traversal is
        # rejected outright.
        rv = sval.strip()
        if not _RUNNER_VALUE_RE.match(rv):
            return False, "runner must be a bare <name>-run.sh script name (no path)"
        return True, rv
    # model / reasoning / enum / identifier / string
    if len(sval) > 120:
        return False, "value too long (max 120 chars)"
    if "\n" in sval or "\r" in sval:
        return False, "value must not contain newlines"
    return True, sval


def _atomic_write_text(path: Path, text: str) -> None:
    """Write text to a NamedTemporaryFile in the same directory, then os.replace
    it into place — an atomic swap so a reader never sees a half-written config."""
    tmp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
                "w", dir=str(path.parent), prefix=".singular-cfg-", suffix=".json",
                delete=False, encoding="utf-8") as tf:
            tf.write(text)
            tmp_name = tf.name
        os.replace(tmp_name, str(path))
    except Exception:
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
        raise


def apply_settings_changes(repo: Path, changes: Any) -> tuple[int, dict[str, Any]]:
    """Validate + apply a batch of settings changes to singular.config.json's env{}.
    Pure of HTTP so tests can exercise it directly. Returns (status_code, payload).

    Rejects (400, nothing written) any unknown/read-only key or any value that
    fails kind-typed validation. Requires an existing singular.config.json object
    (else 409). An empty-string value deletes the key (reverts to default); every
    other top-level config key and unrelated env key is preserved."""
    repo = Path(repo)
    if not isinstance(changes, dict):
        return 400, {"error": "changes must be an object"}
    whitelist, kinds = _settings_write_spec()
    unknown = sorted(k for k in changes if k not in whitelist)
    if unknown:
        return 400, {"error": "unknown or read-only keys", "keys": unknown}
    normalized: dict[str, str] = {}
    for key, raw in changes.items():
        kind = _infer_setting_kind(key, kinds)
        ok, result = _normalize_setting_value(kind, raw)
        if not ok:
            return 400, {"error": result, "key": key}
        normalized[key] = result
    cfg_path = repo / "singular.config.json"
    obj = read_json(cfg_path, None)
    if not isinstance(obj, dict):
        return 409, {"error": "no singular.config.json — initialize the repo first"}
    env = obj.get("env")
    if not isinstance(env, dict):
        env = {}
        obj["env"] = env
    for key, value in normalized.items():
        if value == "":
            env.pop(key, None)  # revert to default
        else:
            env[key] = value
    _atomic_write_text(cfg_path, json.dumps(obj, indent=2) + "\n")
    _CONFIG_CACHE.invalidate()
    _OVERVIEW_CACHE.invalidate()
    # A runner switch (SINGULAR_RUNNER) or model/timeout change moves the config-
    # derived provider fields (activeRunner/isDefaultRunner/roles), so drop the
    # 60s providers cache too — the next /api/providers reflects the write.
    _PROVIDERS_CACHE.invalidate()
    return 200, {
        "ok": True,
        "applied": normalized,
        "appliesAt": {k: _settings_applies_at(k) for k in normalized},
        "config": collect_config(repo),
        "settings": _overlay_config_env(repo, collect_settings(repo)),
    }


def _overlay_config_env(repo: Path, groups: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Overlay singular.config.json env{} onto collect_settings rows.

    collect_settings (byte-pinned; untouched) only knows .env + shell defaults,
    but the engine's authoritative layer — and the target POST /api/settings
    writes to — is config env{}. Without this overlay the System panel shows
    stale defaults for keys the config actually sets, and saved edits never
    appear to land. A .env row keeps source "env"; otherwise a config-set key
    wins over the shell default and reads source "config"."""
    cfg, _resolution, _error = _selected_json_config(repo)
    config_env = cfg.get("env") if isinstance(cfg, dict) and isinstance(cfg.get("env"), dict) else {}
    if not config_env:
        return groups
    for group in groups:
        for item in group.get("items") or []:
            key = item.get("envKey")
            if key in config_env and item.get("source") != "env":
                item["value"] = str(config_env[key])
                item["source"] = "config"
                item["overridden"] = True
                # `value` just changed, so the derived boolValue must follow it.
                _apply_bool_value(item)
    return groups


def collect_settings_view(repo: Path) -> dict[str, Any]:
    """GET /api/settings envelope: the read-only groups (with config env{}
    overlaid) plus an appliesAt map for every whitelisted (writable) key, so
    the UI can label when a change lands."""
    whitelist, _kinds = _settings_write_spec()
    return {
        "schema": "singular.codex.settings.v0",
        "generatedAt": utc_now(),
        "groups": _overlay_config_env(repo, collect_settings(repo)),
        "appliesAt": {k: _settings_applies_at(k) for k in sorted(whitelist)},
    }


# --------------------------------------------------------------------------- #
# /api/providers — runtime status probes (singular.providers.v0)               #
# --------------------------------------------------------------------------- #
#
# collect_providers is the DELIBERATE exception to NewCollectorsNoSubprocessTests:
# like collect_snapshot's git calls it shells out (a --version + an auth-status
# probe per installed CLI), but every probe is capture_output, text, timeout=3s,
# never shell=True, short-circuits when the binary is absent, runs in a bounded
# ThreadPoolExecutor(max_workers=6), and the whole payload is cached 60s
# (?refresh=1 bypasses). It is therefore NOT added to that test's collector list.
# SECRETS RULE: parsers/inference emit only presence booleans, counts, provider
# ids, type strings, and the email/plan the CLI itself prints — never token/key
# VALUES or credential-file contents.

PROVIDERS_TTL = 60.0
PROVIDERS_RUN_SCAN_CAP = 200          # newest run dirs scanned for session-meta
PROVIDER_PROBE_TIMEOUT = 3            # seconds per version/auth subprocess
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_VERSION_RE = re.compile(r"\d+\.\d+(?:\.\d+)?(?:[-.][0-9A-Za-z]+)*")


def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text or "")


def _providers_json(text: str) -> Any:
    """Best-effort parse of JSON a CLI prints to stdout (tolerating ANSI / banner
    noise around the object). Returns the parsed value or None."""
    if not text:
        return None
    t = _strip_ansi(text).strip()
    try:
        return json.loads(t)
    except Exception:
        pass
    i, j = t.find("{"), t.rfind("}")
    if 0 <= i < j:
        try:
            return json.loads(t[i:j + 1])
        except Exception:
            return None
    return None


def _run_probe(cmd: list[str], env: dict[str, str]) -> "subprocess.CompletedProcess[str] | None":
    """One provider probe: capture_output, text, 3s timeout, never shell=True.
    Returns None on timeout / OS error (an indeterminate probe)."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=PROVIDER_PROBE_TIMEOUT, env=env, check=False)
    except (subprocess.TimeoutExpired, OSError):
        return None


def _parse_version(text: str) -> str | None:
    m = _VERSION_RE.search(_strip_ansi(text or ""))
    return m.group(0) if m else None


# --- auth-status parsers (one per CLI output contract) ----------------------- #

def _auth_parse_claude(r: "subprocess.CompletedProcess[str]") -> dict[str, Any]:
    obj = _providers_json(r.stdout)
    if isinstance(obj, dict):
        return {"authStatus": "authenticated" if obj.get("loggedIn") else "unauthenticated",
                "authMethod": obj.get("authMethod"), "email": obj.get("email"),
                "plan": obj.get("subscriptionType")}
    return {"authStatus": "authenticated" if r.returncode == 0 else "unauthenticated"}


def _auth_parse_codex(r: "subprocess.CompletedProcess[str]") -> dict[str, Any]:
    low = (_strip_ansi(r.stdout) + " " + _strip_ansi(r.stderr)).lower()
    if "logged in" in low and "not logged in" not in low:
        method = "ChatGPT" if "chatgpt" in low else ("API key" if "api key" in low else None)
        return {"authStatus": "authenticated", "authMethod": method}
    if "not logged in" in low or r.returncode != 0:
        return {"authStatus": "unauthenticated"}
    return {"authStatus": "unknown"}


def _auth_parse_cursor(r: "subprocess.CompletedProcess[str]") -> dict[str, Any] | None:
    obj = _providers_json(r.stdout)
    if isinstance(obj, dict) and "userEmail" in obj:
        email = obj.get("userEmail")
        if not email or email == "Not logged in":
            return {"authStatus": "unauthenticated"}
        return {"authStatus": "authenticated", "authMethod": "cursor",
                "email": email, "plan": obj.get("subscriptionTier")}
    text = _strip_ansi(r.stdout) + " " + _strip_ansi(r.stderr)
    m = re.search(r"Logged in as\s+(\S+)", text)
    if m:
        return {"authStatus": "authenticated", "authMethod": "cursor", "email": m.group(1)}
    if "not logged in" in text.lower():
        return {"authStatus": "unauthenticated"}
    return None  # indeterminate -> fall through to inference


def _auth_parse_opencode(r: "subprocess.CompletedProcess[str]") -> dict[str, Any]:
    text = _strip_ansi(r.stdout) + " " + _strip_ansi(r.stderr)
    m = re.search(r"(\d+)\s+credential", text)
    if m:
        n = int(m.group(1))
        if n > 0:
            return {"authStatus": "authenticated", "authMethod": "opencode",
                    "detail": f"{n} credential(s)"}
        return {"authStatus": "unauthenticated"}
    return {"authStatus": "unknown"} if r.returncode == 0 else {"authStatus": "unauthenticated"}


_AUTH_PARSERS = {
    "claude": _auth_parse_claude, "codex": _auth_parse_codex,
    "cursor": _auth_parse_cursor, "opencode": _auth_parse_opencode,
}


# --- pure FS/env auth inference (fallback; presence / ids / types only) ------- #

def _infer_gemini(home: Path, spec: dict[str, Any]) -> dict[str, Any] | None:
    if (home / ".gemini" / "oauth_creds.json").exists():   # existence only, never read
        return {"authStatus": "authenticated", "authMethod": "oauth-personal"}
    settings = read_json(home / ".gemini" / "settings.json", None)
    if isinstance(settings, dict):
        sec = settings.get("security") if isinstance(settings.get("security"), dict) else {}
        auth = sec.get("auth") if isinstance(sec.get("auth"), dict) else {}
        selected = auth.get("selectedType") or settings.get("selectedAuthType")
        if selected:
            # A mode is declared but no key/session is confirmable non-interactively.
            return {"authStatus": "unknown", "authMethod": str(selected)}
    return None


def _infer_opencode(home: Path, spec: dict[str, Any]) -> dict[str, Any] | None:
    obj = read_json(home / ".local" / "share" / "opencode" / "auth.json", None)
    if not isinstance(obj, dict):
        return None
    if not obj:
        return {"authStatus": "unauthenticated"}
    provs = sorted(str(k) for k in obj.keys())                 # provider ids only
    types = sorted({str(v.get("type")) for v in obj.values()   # type strings only
                    if isinstance(v, dict) and v.get("type")})
    return {"authStatus": "authenticated", "authMethod": "opencode",
            "detail": f"{len(obj)} credential(s): {', '.join(provs)}",
            "credentialTypes": types}


def _infer_credfile(home: Path, spec: dict[str, Any]) -> dict[str, Any] | None:
    for rel in spec.get("credFiles", []):
        if (home / rel).exists():           # existence only, never read contents
            return {"authStatus": "authenticated", "authMethod": "credential-file"}
    return None


_INFERENCE = {"gemini": _infer_gemini, "opencode": _infer_opencode, "credfile": _infer_credfile}


def _resolve_auth(spec: dict[str, Any], exe: str, env: dict[str, str],
                  home: Path) -> dict[str, Any]:
    """Auth resolution order: CLI status command -> env-key presence ->
    credential-file inference -> unknown."""
    ap = spec.get("authProbe")
    if ap:
        r = _run_probe([exe, *ap["args"]], env)
        if r is not None:
            parsed = _AUTH_PARSERS[ap["parser"]](r)
            if parsed and parsed.get("authStatus") in ("authenticated", "unauthenticated"):
                return parsed
    for key in spec.get("envKeys", []):
        if env.get(key):
            return {"authStatus": "authenticated", "authMethod": f"api-key ({key})"}
    inf = spec.get("inference")
    if inf:
        result = _INFERENCE[inf](home, spec)
        if result:
            return result
    return {"authStatus": "unknown"}


def _provider_rollup(out: dict[str, Any]) -> tuple[str, str]:
    """(status, one-line human message) for a probed provider."""
    binary = out["binary"]
    # An explicitly configured executable that is broken is NOT "missing" — the
    # operator pinned something and it is wrong. Reporting that as "not
    # installed" sends them looking for an install problem that does not exist.
    res = out.get("resolution") or {}
    if res.get("outcome") in ("not-absolute", "not-executable", "path-not-executable"):
        return "misconfigured", (res.get("message")
                                 or "provider executable is misconfigured")
    if not out["installed"]:
        return "missing", f"not installed — `{binary}` not on PATH"
    auth = out["authStatus"]
    login = out.get("loginCommand")
    pinned = " · pinned by " + res["overrideKey"] if (
        res.get("source") == "configured" and res.get("overrideKey")) else ""
    if auth == "authenticated":
        email, plan = out.get("email"), out.get("plan")
        if email and plan:
            msg = f"authenticated as {email} · {plan}"
        elif email:
            msg = f"authenticated as {email}"
        elif out.get("authMethod"):
            msg = f"authenticated ({out['authMethod']})"
        else:
            msg = "authenticated"
        return "ready", msg + pinned
    if auth == "unauthenticated":
        return "error", (f"not authenticated — run `{login}`" if login else "not authenticated")
    return "warning", (f"installed — auth state unknown (run `{login}`)" if login
                       else "installed — auth state unknown")


# --- subscription-quota probe (Codex-only real usage; SECRETS RULE) ---------- #
#
# Only Codex exposes real subscription usage headlessly: its rollout JSONL logs
# carry a rate_limits object (used_percent / window / resets_at / plan_type).
# Cursor exposes a tier only; every other runtime exposes nothing without reading
# a credential file — which is FORBIDDEN. The Codex path reads ONLY rollout JSONL
# files under ~/.codex/sessions, never any credential/auth file. ANY failure
# degrades to an unavailable payload — the quota probe never raises into the probe.

CODEX_QUOTA_TAIL_BYTES = 262144       # bytes tailed from the newest rollout jsonl
CODEX_ROLLOUT_DAY_LOOKBACK = 14       # dated day-dir candidates per clock (UTC+local)


def _codex_rollout_byname_fallback(sessions: Path) -> list[Path]:
    """When no dated day-dir candidate exists (clock skew / stale machine), walk
    the newest year/month by NAME and take the last 7 day dirs. Bounded, pure FS."""
    def _latest_child(parent: Path) -> Path | None:
        try:
            names = sorted((e.name for e in os.scandir(parent)
                            if e.is_dir(follow_symlinks=False)), reverse=True)
        except OSError:
            return None
        return (parent / names[0]) if names else None

    year = _latest_child(sessions)
    month = _latest_child(year) if year is not None else None
    if month is None:
        return []
    try:
        days = sorted((month / e.name for e in os.scandir(month)
                       if e.is_dir(follow_symlinks=False)),
                      key=lambda p: p.name, reverse=True)
    except OSError:
        return []
    return days[:7]


def _codex_rollout_newest(home: Path) -> Path | None:
    """Newest-BY-MTIME ``rollout-*.jsonl`` under ``~/.codex/sessions``. A rollout is
    filed under the date its session STARTED, which can differ both from wall-clock
    day and from the file's freshest mtime (a long-lived session keeps appending),
    so recency by name is unreliable — mtime wins. Candidate day dirs are the last
    14 days for BOTH the UTC and local 'today' (<=28 stats); a by-name fallback
    covers the no-dated-dir case. Pure FS."""
    sessions = home / ".codex" / "sessions"
    if not sessions.is_dir():
        return None
    day_dirs: list[Path] = []
    seen: set[str] = set()
    for base in (dt.datetime.now(dt.UTC), dt.datetime.now()):
        for i in range(CODEX_ROLLOUT_DAY_LOOKBACK):
            d = base - dt.timedelta(days=i)
            rel = f"{d.year:04d}/{d.month:02d}/{d.day:02d}"
            if rel in seen:
                continue
            seen.add(rel)
            cand = sessions / rel
            if cand.is_dir():
                day_dirs.append(cand)
    if not day_dirs:
        day_dirs = _codex_rollout_byname_fallback(sessions)
    newest: Path | None = None
    newest_mtime = -1.0
    for day_dir in day_dirs:
        try:
            entries = list(os.scandir(day_dir))
        except OSError:
            continue
        for e in entries:
            if not (e.name.startswith("rollout-") and e.name.endswith(".jsonl")):
                continue
            try:
                m = e.stat(follow_symlinks=False).st_mtime
            except OSError:
                continue
            if m > newest_mtime:
                newest_mtime, newest = m, Path(e.path)
    return newest


def _find_rate_limits(obj: Any, depth: int = 0) -> dict[str, Any] | None:
    """Locate the rate_limits object inside a parsed rollout line. Codex nests it
    under ``payload.rate_limits`` (a token_count event), but the envelope is
    version-dependent, so search tolerantly to a bounded depth for a dict carrying
    a ``rate_limits`` dict — or a dict that itself looks like one. Pure; depth<=4."""
    if depth > 4 or obj is None:
        return None
    if isinstance(obj, dict):
        rl = obj.get("rate_limits")
        if isinstance(rl, dict):
            return rl
        if "limit_id" in obj or "primary" in obj or "secondary" in obj:
            return obj
        for value in obj.values():
            found = _find_rate_limits(value, depth + 1)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = _find_rate_limits(value, depth + 1)
            if found is not None:
                return found
    return None


def _codex_quota(home: Path) -> dict[str, Any]:
    """Codex subscription quota from the newest rollout JSONL's LAST rate_limits
    record. Tails ~256KB (rollouts reach tens of MB), scans lines backwards for the
    last one carrying rate_limits, and normalizes the snake_case shape to camelCase.
    The top-level usedPercent/windowMinutes/resetsAt mirror ``primary`` (falling back
    to ``secondary``); both null => no-rollout-data. SECRETS RULE: reads ONLY rollout
    JSONL, never a credential file; ANY exception => unavailable, never raises."""
    try:
        newest = _codex_rollout_newest(home)
        if newest is None:
            return {"available": False, "reason": "no-rollout"}
        st = newest.stat()
        with newest.open("rb") as fh:
            seeked = st.st_size > CODEX_QUOTA_TAIL_BYTES
            if seeked:
                fh.seek(st.st_size - CODEX_QUOTA_TAIL_BYTES)
            data = fh.read()
        lines = data.decode("utf-8", errors="replace").split("\n")
        if seeked and lines:
            lines = lines[1:]  # drop the partial first line the seek landed inside
        rate_limits: dict[str, Any] | None = None
        for line in reversed(lines):
            if '"rate_limits"' not in line:
                continue
            stripped = line.strip()
            if not stripped:
                continue
            try:
                parsed = json.loads(stripped)
            except Exception:
                continue
            found = _find_rate_limits(parsed)
            if found is not None:
                rate_limits = found
                break
        if rate_limits is None:
            return {"available": False, "reason": "no-rollout-data"}

        def _window(side: Any) -> dict[str, Any] | None:
            if not isinstance(side, dict):
                return None
            return {"usedPercent": side.get("used_percent"),
                    "windowMinutes": side.get("window_minutes"),
                    "resetsAt": side.get("resets_at")}

        primary = _window(rate_limits.get("primary"))
        secondary = _window(rate_limits.get("secondary"))
        if primary is None and secondary is None:
            return {"available": False, "reason": "no-rollout-data"}
        lead = primary or secondary or {}
        credits = rate_limits.get("credits")
        return {
            "available": True,
            "usedPercent": lead.get("usedPercent"),
            "windowMinutes": lead.get("windowMinutes"),
            "resetsAt": lead.get("resetsAt"),
            "primary": primary,
            "secondary": secondary,
            "planType": rate_limits.get("plan_type"),
            "credits": credits if isinstance(credits, dict) else None,
            "staleSeconds": max(0, int(time.time() - st.st_mtime)),
            "source": "rollout",
        }
    except Exception:
        return {"available": False, "reason": "rollout-parse-error"}


def _provider_quota(pid: str, installed: bool, home: Path) -> dict[str, Any]:
    """Per-provider subscription-quota dispatch. codex -> real rollout probe;
    cursor -> tier-only (no headless usage endpoint); an absent CLI -> cli-missing;
    everything else -> not-exposed (would require a forbidden credential read)."""
    if not installed:
        return {"available": False, "reason": "cli-missing"}
    if pid == "codex":
        return _codex_quota(home)
    if pid == "cursor":
        return {"available": False, "reason": "tier-only"}
    return {"available": False, "reason": "not-exposed"}


_PROVIDER_RESOLVER_CACHE: dict[str, Any] = {}
_PROVIDER_RESOLVER_LOCK = threading.Lock()


def _load_provider_resolver():
    """Import engine/provider_resolver.py in-process (never a subprocess).

    The console daemon never sources lib.sh — cli/singular execs it with only
    SINGULAR_ENGINE_HOME — so it used to resolve providers with a bare
    shutil.which over its own PATH. That is how the Providers card came to
    report an unauthenticated /opt/homebrew/bin/codex while the orchestration
    was driving a different Codex entirely.

    Returns None on a plugin-only checkout; the caller then degrades to the old
    PATH-only behaviour and marks the result non-authoritative.
    """
    path = _engine_file("provider_resolver.py")
    key = str(path) if path else ""
    with _PROVIDER_RESOLVER_LOCK:
        if key in _PROVIDER_RESOLVER_CACHE:
            return _PROVIDER_RESOLVER_CACHE[key]
        module = None
        if path is not None:
            name = "_singular_provider_resolver"
            try:
                spec = importlib.util.spec_from_file_location(name, path)
                if spec is not None and spec.loader is not None:
                    module = importlib.util.module_from_spec(spec)
                    # Register BEFORE exec: @dataclass resolves its own module
                    # through sys.modules[cls.__module__], which is None for a
                    # module loaded by path alone, and the class body raises.
                    sys.modules[name] = module
                    try:
                        spec.loader.exec_module(module)
                    except Exception:
                        sys.modules.pop(name, None)
                        raise
            except Exception:
                module = None
        _PROVIDER_RESOLVER_CACHE[key] = module
        return module


def _provider_resolution_env(repo: Path, env: dict[str, str]) -> dict[str, str]:
    """The environment the ENGINE would see, not the console's own.

    engine/lib.sh evals `export K=V` for every singular.config.json env{} key
    AFTER the process environment exists, so config WINS. os.environ alone is
    not sufficient — that asymmetry is the split-brain itself.

    Known residual gap: singular.config.sh and .singular-state/config.local.sh are
    shell files sourced after env{}, and the console does not eval shell. If one
    of those sets SINGULAR_CODEX_BIN the console can still disagree, which is why
    the payload carries `authoritative`.
    """
    merged = dict(env)
    cfg = read_json(repo / "singular.config.json", None)
    cfg_env = cfg.get("env") if isinstance(cfg, dict) else None
    if isinstance(cfg_env, dict):
        for key, value in cfg_env.items():
            # SINGULAR_BASH_BIN is bootstrap-only and skipped by lib.sh too.
            if key == "SINGULAR_BASH_BIN" or not isinstance(value, (str, int, float)):
                continue
            merged[str(key)] = str(value)
    return merged


def _probe_provider(spec: dict[str, Any], env: dict[str, str], home: Path,
                    resolver=None) -> dict[str, Any]:
    binary = spec["binary"]
    resolution = None
    if resolver is not None:
        try:
            resolution = resolver.resolve_provider_bin(spec["id"], binary, env)
        except Exception:
            resolution = None
    if resolution is not None:
        # A configured-but-broken override must NOT fall back to a PATH
        # candidate. Silently probing a different binary than the operator
        # pinned is the defect this whole path exists to fix.
        exe = resolution.path if resolution.ok else None
    else:
        exe = shutil.which(binary, path=env.get("PATH") or "")
    out: dict[str, Any] = {
        "id": spec["id"], "name": spec["name"], "binary": binary,
        "installed": exe is not None, "path": exe, "version": None,
        "authStatus": "unknown", "authMethod": None, "email": None, "plan": None,
        "loginCommand": spec.get("loginCommand"),
        "envKeys": list(spec.get("envKeys", [])),
        "envKeyPresent": {k: bool(env.get(k)) for k in spec.get("envKeys", [])},
        "runnerScript": spec["runnerScript"],
    }
    # How this executable was chosen, so the card can say "pinned by
    # SINGULAR_CODEX_BIN" vs "found on PATH" — the row that would have made the
    # original split-brain self-evident instead of a two-hour investigation.
    out["resolution"] = {
        "source": resolution.source if resolution else "path",
        "outcome": resolution.outcome if resolution else ("ok" if exe else "not-on-path"),
        "overrideKey": resolution.override_key if resolution else None,
        "configuredPath": resolution.configured if resolution else None,
        "message": resolution.message if resolution else "",
        "authoritative": resolution is not None,
    }
    # Additive quota field (singular.providers.v0 stays; not byte-pinned). Set on
    # both the installed and not-installed paths so the field is always present.
    out["quota"] = _provider_quota(spec["id"], exe is not None, home)
    if exe is None:
        out["status"], out["message"] = _provider_rollup(out)
        return out
    vr = _run_probe([exe, *spec.get("versionArgs", ["--version"])], env)
    if vr is not None:
        out["version"] = _parse_version((vr.stdout or "") + "\n" + (vr.stderr or ""))
    auth = _resolve_auth(spec, exe, env, home)
    for key in ("authStatus", "authMethod", "email", "plan", "detail", "credentialTypes"):
        if auth.get(key) is not None:
            out[key] = auth[key]
    out["status"], out["message"] = _provider_rollup(out)
    return out


def _active_runner(repo: Path) -> str:
    """Basename of the runner the engine would launch: config env{} SINGULAR_RUNNER
    (wins in engine/lib.sh) > top-level "runner" > engine default codex-run.sh."""
    cfg, _resolution, _error = _selected_json_config(repo)
    env = cfg.get("env") if isinstance(cfg.get("env"), dict) else {}
    runner = env.get("SINGULAR_RUNNER") or cfg.get("runner") or "codex-run.sh"
    return os.path.basename(str(runner))


def _provider_session_stats(repo: Path) -> dict[str, dict[str, Any]]:
    """Per-provider {recentSessions, lastUsedAt, lastExitCode} from durable
    session-meta. Scans the newest ~200 run dirs' session-*.json plus every
    sessions/planner/*.json, grouping by the meta's "provider" field. Pure FS."""
    stats: dict[str, dict[str, Any]] = {}
    metas: list[Path] = []
    runs_root = state_path(repo, "runs")
    if runs_root.is_dir():
        try:
            dirs = [e for e in os.scandir(runs_root) if e.is_dir(follow_symlinks=False)]
        except OSError:
            dirs = []
        dirs.sort(key=lambda e: _safe_mtime(Path(e.path)), reverse=True)
        for entry in dirs[:PROVIDERS_RUN_SCAN_CAP]:
            try:
                metas.extend(Path(entry.path).glob("session-*.json"))
            except OSError:
                continue
    planner_dir = state_path(repo, "sessions", "planner")
    if planner_dir.is_dir():
        try:
            metas.extend(planner_dir.glob("*.json"))
        except OSError:
            pass
    for path in metas:
        obj = read_json(path, None)
        if not isinstance(obj, dict):
            continue
        pid = obj.get("provider")
        if not pid:
            continue
        entry = stats.setdefault(str(pid), {"recentSessions": 0, "lastUsedAt": None,
                                            "lastExitCode": None, "_epoch": -1.0})
        entry["recentSessions"] += 1
        ts = obj.get("createdAt")
        epoch = _iso_to_epoch(ts) if ts else _safe_mtime(path)
        if epoch > entry["_epoch"]:
            entry["_epoch"] = epoch
            entry["lastUsedAt"] = ts or _iso_from_mtime(_safe_mtime(path))
            entry["lastExitCode"] = obj.get("exitCode")
    for entry in stats.values():
        entry.pop("_epoch", None)
    return stats


def _compute_providers(repo: Path, env: dict[str, str], home: Path) -> dict[str, Any]:
    repo = Path(repo)
    checked_at = utc_now()
    engine_dir = _engine_dir(env)
    active_runner = _active_runner(repo)
    cfg = collect_config(repo)                 # pure-FS; reuses the runner->provider fix
    active_provider = cfg.get("provider")
    active_roles = sorted(cfg.get("roles", {}).keys())
    session_stats = _provider_session_stats(repo)
    # Prime the resolver import and build the engine-equivalent env BEFORE the
    # pool, so six worker threads cannot race exec_module and every probe sees
    # the same config-layered environment the engine would.
    resolver = _load_provider_resolver()
    resolve_env = _provider_resolution_env(repo, env)
    with ThreadPoolExecutor(max_workers=6) as pool:
        probes = list(pool.map(
            lambda spec: _probe_provider(spec, resolve_env, home, resolver=resolver),
            PROVIDERS))
    providers: list[dict[str, Any]] = []
    for spec, probe in zip(PROVIDERS, probes):
        pid = spec["id"]
        probe["runnerPresent"] = (engine_dir / spec["runnerScript"]).is_file()
        probe["isDefaultRunner"] = spec["runnerScript"] == active_runner
        probe["roles"] = list(active_roles) if pid == active_provider else []
        st = session_stats.get(pid, {})
        probe["lastUsedAt"] = st.get("lastUsedAt")
        probe["lastExitCode"] = st.get("lastExitCode")
        probe["recentSessions"] = st.get("recentSessions", 0)
        probe["checkedAt"] = checked_at
        providers.append(probe)
    counts = Counter(p["status"] for p in providers)
    ready = counts.get("ready", 0)
    attention = (counts.get("warning", 0) + counts.get("error", 0)
                 + counts.get("missing", 0) + counts.get("misconfigured", 0))
    return {
        "schema": "singular.providers.v0",
        "checkedAt": checked_at,
        "repo": str(repo),
        "activeProvider": active_provider,
        "activeRunner": active_runner,
        "providers": providers,
        "summary": {
            "ready": ready, "warning": counts.get("warning", 0),
            "error": counts.get("error", 0), "missing": counts.get("missing", 0),
            "misconfigured": counts.get("misconfigured", 0),
            "attention": attention,
            "message": f"{ready} ready · {attention} attention",
        },
    }


_PROVIDERS_CACHE = _ComputeCache(
    lambda repo: _compute_providers(repo, os.environ, Path.home()), PROVIDERS_TTL)


def collect_providers(repo: Path, refresh: bool = False, *,
                      env: dict[str, str] | None = None,
                      home: Path | None = None) -> dict[str, Any]:
    """Runtime provider/runtime status (singular.providers.v0). Subprocess-based
    (version + auth probes) but cached 60s; ``refresh`` bypasses + repopulates.

    ``env``/``home`` overrides bypass the cache (tests point probes at a fake
    PATH + credential HOME); production uses os.environ + Path.home()."""
    repo = Path(repo).resolve()
    if env is not None or home is not None:
        return _compute_providers(repo, env if env is not None else os.environ,
                                  Path(home) if home is not None else Path.home())
    if refresh:
        _PROVIDERS_CACHE.invalidate()
    return _PROVIDERS_CACHE.get(str(repo), repo)


# --------------------------------------------------------------------------- #
# Prompts (singular.codex.prompts.v0)                                           #
# --------------------------------------------------------------------------- #
#
# Read-only view of the durable role prompt library plus per-role attribution.
# Rendered per-run prompts live inside session run dirs and are served through
# the session terminal (see _session_log_files); these endpoints serve the
# canonical library under docs/orchestration/prompts.

PROMPT_ROLE_MAP = {
    "l1-planner.md": "planner",
    "l2-test-first-developer.md": "developer",
    "auditor.md": "auditor",
    "reviewer.md": "reviewer",
    "decider.md": "decider",
    "l0-origin.md": "origin",
    "l1-area-orchestrator.md": "l1-orchestrator",
    "plan-critic.md": "critic",
}
PROMPT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.md$")
PROMPT_MAX_BYTES = 262144  # 256 KB read cap


def collect_prompts(repo: Path) -> dict[str, Any]:
    """List the role prompt library (docs/orchestration/prompts/*.md). Read-only;
    pure filesystem. Sorted by name; role is null for prompts with no mapping."""
    root = repo / PROMPTS_DIR_REL
    prompts: list[dict[str, Any]] = []
    if root.is_dir():
        for path in root.glob("*.md"):
            if not path.is_file():
                continue
            try:
                st = path.stat()
            except OSError:
                continue
            prompts.append({"name": path.name, "bytes": st.st_size,
                            "mtime": int(st.st_mtime), "role": PROMPT_ROLE_MAP.get(path.name)})
    prompts.sort(key=lambda p: p["name"])
    return {"schema": "singular.codex.prompts.v0", "generatedAt": utc_now(), "prompts": prompts}


def collect_prompt(repo: Path, name: str) -> dict[str, Any] | None:
    """One prompt's content, resolved + containment-guarded under the prompts dir.
    Returns None (404) on a bad name, traversal, or missing file. Read-only."""
    if not PROMPT_NAME_RE.match(name):
        return None
    root = (repo / PROMPTS_DIR_REL).resolve()
    path = (root / name).resolve()
    if root not in path.parents or not path.is_file():
        return None
    try:
        st = path.stat()
    except OSError:
        return None
    try:
        content = path.read_bytes()[:PROMPT_MAX_BYTES].decode("utf-8", errors="replace")
    except OSError:
        return None
    return {"name": name, "path": str(path), "size": st.st_size,
            "mtime": int(st.st_mtime), "content": redact_secrets(content)}


# --------------------------------------------------------------------------- #
# Raw primitives (singular.codex.raw.v0)                                        #
# --------------------------------------------------------------------------- #
#
# A read-only "view source" for the durable records behind the console — task
# markdown, gate results, leases, dispatch/inbox records, singleton config/dag.
# Each root pins a base dir + an allowed-name rule (regex or explicit allowlist);
# resolve() + parent-containment is the traversal guard. 256 KB read cap.

RAW_MAX_BYTES = 262144

RAW_ROOTS: dict[str, dict[str, Any]] = {
    # dir roots: base + a filename regex; "superseded" adds a tasks/superseded fallback
    "task": {"base": "docs/orchestration/tasks", "re": r"^TASK-\d+\.md$", "superseded": True},
    "gate": {"base": "docs/orchestration/gates", "re": r"^[A-Za-z0-9._-]+\.gate-result\.json$"},
    "gate-review": {"base": "docs/orchestration/gates/evidence", "re": r"^[A-Za-z0-9._-]+\.json$"},
    "lease": {"base": ".singular-state/leases", "re": r"^TASK-\d+\.json$"},
    "l1-lease": {"base": ".singular-state/l1-leases", "re": r"^[A-Za-z0-9._-]+\.json$"},
    "dispatch": {"base": ".singular-state/dispatch", "re": r"^TASK-\d+\.json$"},
    "inbox": {"base": ".singular-state/inbox", "re": r"^[A-Za-z0-9._-]+\.json$"},
    # explicit-name allowlist under the state dir
    "state": {"base": ".singular-state",
              "allow": {"origin-state.json", "circuit.json", "planner-backoff.json",
                        "STATUS.md", "task-id-counter"}},
    # singletons: the request name must equal the file's basename
    "config": {"singleton": "singular.config.json"},
    "dag": {"singleton": "docs/orchestration/dag.v0.json"},
}


# Env-var names whose VALUE is a credential. Key-name based, not value-shape
# based, and that is the whole point: SINGULAR_CLAUDE_MODEL="claude-opus-4-8" and
# ANTHROPIC_API_KEY="sk-ant-..." are both long opaque strings, and only the name
# tells them apart. Value-shape detection would either miss short credentials or
# redact model ids and break the Providers surface.
_CONFIG_SECRET_NAME_RE = re.compile(
    r"(?i)(SECRET|TOKEN|PASSWORD|PASSWD|APIKEY|API_KEY|ACCESS_KEY|PRIVATE_KEY"
    r"|CREDENTIAL|AUTH_CONTENT|SESSION_ID|SESSIONID)")


def _redact_config_env(content: str) -> tuple[str, bool]:
    """Mask credential-valued keys inside singular.config.json's env{} block.

    Dropping env{} outright is not an option: providers/surface.js reads
    obj.env from this endpoint to drive the per-provider model knobs. Leaving it
    is not an option either — the provider registry names OPENCODE_AUTH_CONTENT,
    ANTHROPIC_API_KEY and friends, and an engine-sanctioned config may set any of
    them. So mask the values and keep the keys, which preserves both the shipped
    feature and the operator's ability to see WHICH keys are configured.
    """
    try:
        obj = json.loads(content)
    except (ValueError, TypeError):
        return content, False           # caller still runs the generic pass
    env = obj.get("env") if isinstance(obj, dict) else None
    if not isinstance(env, dict):
        return content, False
    provider_keys = {key for spec in PROVIDERS for key in (spec.get("envKeys") or [])}
    changed = False
    for key, value in list(env.items()):
        if not isinstance(value, str) or not value:
            continue
        if key in provider_keys or _CONFIG_SECRET_NAME_RE.search(key):
            env[key] = "[redacted:config-env]"
            changed = True
    if not changed:
        return content, False
    return json.dumps(obj, indent=2) + "\n", True


def collect_raw(repo: Path, root: str, name: str) -> dict[str, Any] | None:
    """Serve one raw record by (root, name), traversal-guarded. Returns None for
    an unknown root/name or a missing file. Over-cap content is truncated with a
    ``truncated`` flag. Read-only; pure filesystem."""
    spec = RAW_ROOTS.get(root)
    if spec is None:
        return None
    repo = repo.resolve()
    if "singleton" in spec:
        rel = spec["singleton"]
        if name != PurePosixPath(rel).name:
            return None
        base_root = repo
        path = (repo / rel).resolve()
    else:
        base_root = (repo / spec["base"]).resolve()
        if "re" in spec:
            if not re.match(spec["re"], name):
                return None
        elif name not in spec["allow"]:
            return None
        path = (base_root / name).resolve()
    if base_root != path and base_root not in path.parents:  # containment guard
        return None
    if not path.is_file():
        if spec.get("superseded"):
            sup_root = (repo / spec["base"] / "superseded").resolve()
            alt = (sup_root / name).resolve()
            if sup_root in alt.parents and alt.is_file():
                path = alt
            else:
                return None
        else:
            return None
    try:
        st = path.stat()
        data = path.read_bytes()
    except OSError:
        return None
    truncated = len(data) > RAW_MAX_BYTES
    content = data[:RAW_MAX_BYTES].decode("utf-8", errors="replace")
    redacted = False
    if root == "config":
        content, redacted = _redact_config_env(content)
    content = redact_secrets(content)
    out: dict[str, Any] = {
        "schema": "singular.codex.raw.v0",
        "root": root,
        "name": name,
        "path": str(path),
        # size/mtime stay FILE facts. Redaction changes the bytes, so content
        # deliberately no longer matches size; `redacted` lets the client say so
        # rather than silently presenting altered JSON as the file's contents.
        "size": st.st_size,
        "mtime": int(st.st_mtime),
        "content": content,
    }
    if redacted:
        out["redacted"] = True
    if truncated:
        out["truncated"] = True
    return out


# --------------------------------------------------------------------------- #
# Home (singular.codex.home.v0)                                                 #
# --------------------------------------------------------------------------- #
#
# The console's landing digest: one glanceable health verdict, an attention feed
# (what needs an operator's eyes), plan/gate/task rollups, live loop state
# (dispatch, autonomate pid, breaker, backoff), and a 14-day activity sparkline.
# Pure filesystem: os.kill(pid, 0) liveness probes and shutil.disk_usage (a
# syscall, not a subprocess) are the only "live" reads — collect_disk's df/du is
# deliberately avoided so collect_home stays subprocess-free.

HOME_L1_STALE_MINUTES = 120


def _snapshot_loop_liveness(repo: Path) -> dict:
    """Honest autonomate-daemon liveness for the status dock (0.11.0, additive).
    agents.l0.state counts engine *processes* — tests and manual ops inflate
    it — while this field answers only "is the loop daemon itself alive"
    (pidfile + signal-0 probe, the same authority ops_health uses)."""
    path = state_path(repo, "autonomate.pid")
    pid: int | None = None
    alive = False
    if path.is_file():
        m = re.search(r"\d+", path.read_text(errors="replace"))
        pid = int(m.group(0)) if m else None
        alive = _pid_alive(pid)
    return {"pid": pid, "alive": alive}


def _pid_alive(pid: Any) -> bool:
    """True when a signal-0 probe reaches a live process. os.kill(pid, 0) is a
    liveness check, not a subprocess."""
    try:
        pid_int = int(pid)
    except (TypeError, ValueError):
        return False
    if pid_int <= 0:
        return False
    try:
        os.kill(pid_int, 0)
        return True
    except OSError:
        return False


def _parse_ts(value: Any) -> dt.datetime | None:
    """Parse an ISO-8601 or epoch timestamp to an aware UTC datetime, else None."""
    if isinstance(value, (int, float)):
        try:
            return dt.datetime.fromtimestamp(float(value), dt.UTC)
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str) and value:
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.UTC)
    return None


def _breaker_threshold(repo: Path) -> int:
    """Circuit-breaker trip count = the SINGULAR_MAX_CONSEC_FAILS shell default
    parsed from the settings-dir files (fallback 3)."""
    text = ""
    settings_dir = resolve_settings_dir(repo)
    for name in SETTINGS_FILE_NAMES:
        try:
            text += "\n" + (settings_dir / name).read_text(errors="replace")
        except OSError:
            pass
    raw = parse_shell_default(text, "SINGULAR_MAX_CONSEC_FAILS")
    try:
        return int(raw) if raw is not None else 3
    except ValueError:
        return 3


# 0.10.0 supervisor briefing: the fields home surfaces from the latest briefing
# document the engine's supervise.sh publishes. narrative is capped so a runaway
# model can't bloat the home poll.
_BRIEFING_KEYS = ("schema", "stage", "narrative", "risks", "nextSteps",
                  "proposedSettings", "generatedAt", "runId")
_BRIEFING_NARRATIVE_CAP = 4000


def _load_supervisor_briefing(repo: Path) -> dict[str, Any] | None:
    """The latest supervisor briefing (.singular-state/supervisor/latest.json),
    filtered to known keys with the narrative capped. None when absent. Pure FS."""
    raw = read_json(state_path(repo, "supervisor", "latest.json"), None)
    if not isinstance(raw, dict):
        return None
    out = {key: raw[key] for key in _BRIEFING_KEYS if key in raw}
    narrative = out.get("narrative")
    if isinstance(narrative, str) and len(narrative) > _BRIEFING_NARRATIVE_CAP:
        out["narrative"] = narrative[:_BRIEFING_NARRATIVE_CAP]
    return out


def _supervisor_config(repo: Path) -> dict[str, Any]:
    """{intervalMin, enabled} from config env SINGULAR_SUPERVISOR_INTERVAL_MIN
    (0/unset/invalid = disabled — matches the engine's inert default). Pure FS."""
    cfg = read_json(repo / "singular.config.json", None)
    env = cfg.get("env") if isinstance(cfg, dict) and isinstance(cfg.get("env"), dict) else {}
    raw = env.get("SINGULAR_SUPERVISOR_INTERVAL_MIN")
    try:
        interval = int(str(raw).strip()) if raw not in (None, "") else 0
    except (ValueError, TypeError):
        interval = 0
    interval = max(0, interval)
    return {"intervalMin": interval, "enabled": interval > 0}


def collect_home(repo: Path) -> dict[str, Any]:
    """The landing digest. Read-only; pure filesystem (no subprocesses)."""
    repo = repo.resolve()
    now = dt.datetime.now(dt.UTC)

    # --- activity rollup + last-activity from the shared events index ---------
    tail = load_events_index(repo).get("tail_rows") or []
    days = [(now.date() - dt.timedelta(days=i)).isoformat() for i in range(13, -1, -1)]
    day_index = {d: {"date": d, "dispatches": 0, "integrations": 0, "failures": 0} for d in days}
    last_activity: str | None = None
    for row in tail:
        ts = row.get("ts")
        if isinstance(ts, str) and ts:
            last_activity = ts  # rows are in file order; the last non-empty ts is newest
        day = ts[:10] if isinstance(ts, str) else None
        etype = row.get("type")
        bucket = day_index.get(day) if day else None
        if bucket is None:
            continue
        if etype == "l1.dispatch_started":
            bucket["dispatches"] += 1
        elif etype == "integration.integrated":
            bucket["integrations"] += 1
        # project_event marks failures with tone "red" (the six-tone system has no
        # "error" tone); count task failures + red-toned dispatch reaps as failures.
        if etype == "l1.task_failed" or (etype == "origin.dispatch_reaped" and row.get("tone") == "red"):
            bucket["failures"] += 1
    activity_by_day = [day_index[d] for d in days]

    # --- plan / gate / frontier rollups ---------------------------------------
    gates = collect_gates_summary(repo)
    # byNode is dropped (the digest never renders it); cohorts rides along so the
    # landing page can separate historical evidence from this campaign's work.
    gates_out = {"passed": gates.get("passed", 0), "total": gates.get("total", 0),
                 "cohorts": gates.get("cohorts")}
    frontier_nodes = [str(e.get("node")) for e in (compute_frontier_native(repo).get("frontier") or [])]
    frontier = {"count": len(frontier_nodes), "nodes": frontier_nodes}

    # --- task counts (lease status first, task-file status fallback) ----------
    tasks = collect_tasks(repo)
    leases = collect_leases(repo)
    lease_status = {str(l.get("taskId")): str(l.get("status") or "")
                    for l in leases if l.get("taskId")}
    status_by_task: dict[str, str] = {}
    for t in tasks:
        tid = str(t.get("id"))
        status_by_task[tid] = lease_status.get(tid) or str(t.get("status") or "unknown")
    for tid, status in lease_status.items():
        status_by_task.setdefault(tid, status)
    task_counts = {bucket: 0 for bucket in _DAG_TASK_BUCKETS}
    task_counts["total"] = len(status_by_task)
    for status in status_by_task.values():
        task_counts[_dag_task_bucket(status)] += 1

    # --- live loop state ------------------------------------------------------
    launched = pid_alive = 0
    dispatch_dir = state_path(repo, "dispatch")
    if dispatch_dir.is_dir():
        for path in sorted(dispatch_dir.glob("TASK-*.json")):
            rec = read_json(path, {})
            if not isinstance(rec, dict) or str(rec.get("state")) != "launched":
                continue
            launched += 1
            if _pid_alive(rec.get("pid")):
                pid_alive += 1
    dispatch = {"launched": launched, "pidAlive": pid_alive}

    auto_pid_path = state_path(repo, "autonomate.pid")
    auto_pid: int | None = None
    auto_alive = False
    auto_pidfile_present = auto_pid_path.is_file()
    if auto_pidfile_present:
        m = re.search(r"\d+", auto_pid_path.read_text(errors="replace"))
        auto_pid = int(m.group(0)) if m else None
        auto_alive = _pid_alive(auto_pid)
    autonomate = {"pid": auto_pid, "alive": auto_alive}

    stop_present = (repo / STOP_REL).exists()

    circuit = read_json(repo / CIRCUIT_REL, {}) or {}
    try:
        consec = int(circuit.get("consecFails") or 0)
    except (TypeError, ValueError):
        consec = 0
    threshold = _breaker_threshold(repo)
    breaker = {"consecFails": consec, "threshold": threshold}

    backoff_raw = read_json(state_path(repo, "planner-backoff.json"), None)
    backoff: dict[str, Any] | None = None
    if isinstance(backoff_raw, dict):
        until = _parse_ts(backoff_raw.get("until"))
        backoff = dict(backoff_raw)
        backoff["active"] = bool(until and until > now)

    # --- disk watch via a pure syscall (no df subprocess) ---------------------
    disk_watch = False
    capacity_pct: int | None = None
    try:
        usage = shutil.disk_usage(str(repo))
        if usage.total:
            capacity_pct = int(round(100 * usage.used / usage.total))
            disk_watch = capacity_pct >= WATCH_DISK_CAPACITY
    except OSError:
        pass

    # --- attention feed -------------------------------------------------------
    attention: list[dict[str, Any]] = []
    if stop_present:
        attention.append({"severity": "watch", "text": "STOP sentinel present — the loop is halted",
                          "link": "/api/raw/state/STATUS.md"})
    if threshold and consec >= threshold:
        attention.append({"severity": "blocker",
                          "text": f"circuit breaker tripped ({consec}/{threshold} consecutive failures)",
                          "link": "/api/raw/state/circuit.json"})
    elif threshold and consec == threshold - 1:
        attention.append({"severity": "watch",
                          "text": f"circuit breaker near trip ({consec}/{threshold} consecutive failures)",
                          "link": "/api/raw/state/circuit.json"})
    if backoff and backoff.get("active"):
        failure_class = backoff.get("failureClass") or "error"
        attention.append({"severity": "watch",
                          "text": f"planner backing off ({failure_class}) until {backoff.get('until')}",
                          "link": "/api/raw/state/planner-backoff.json"})
    for lease in collect_l1_leases(repo):
        if not lease.get("active"):
            continue
        updated = _parse_ts(lease.get("updatedAt"))
        if updated is None:
            continue
        idle_min = (now - updated).total_seconds() / 60.0
        if idle_min > HOME_L1_STALE_MINUTES:
            attention.append({"severity": "watch",
                              "text": f"L1 lease {lease.get('node')} idle {int(idle_min)} min"})
    if disk_watch:
        attention.append({"severity": "watch", "text": f"disk at {capacity_pct}% capacity"})
    if auto_pidfile_present and not auto_alive:
        attention.append({"severity": "watch", "text": "loop pidfile is stale"})

    severities = {a["severity"] for a in attention}
    health = "blocker" if "blocker" in severities else ("watch" if "watch" in severities else "ok")

    # --- supervisor loop / briefing (0.10.0; additive, pure-FS) ---------------
    try:
        status_text = (repo / STATUS_REL).read_text(errors="replace")
    except OSError:
        status_text = ""
    status = parse_status_md(status_text) if status_text else {}
    loop = {"iteration": status.get("iteration"), "note": status.get("note"),
            "updatedAt": status.get("updatedAt")}
    briefing = _load_supervisor_briefing(repo)
    supervisor = _supervisor_config(repo)

    return {
        "schema": "singular.codex.home.v0",
        "generatedAt": utc_now(),
        "health": health,
        "attention": attention,
        "gates": gates_out,
        "frontier": frontier,
        "taskCounts": task_counts,
        "dispatch": dispatch,
        "autonomate": autonomate,
        "stop": stop_present,
        "breaker": breaker,
        "backoff": backoff,
        "lastActivityAt": last_activity,
        "activityByDay": activity_by_day,
        "notable": tail[-12:],
        "loop": loop,
        "briefing": briefing,
        "supervisor": supervisor,
    }


_HOME_CACHE = _ComputeCache(collect_home, 6.0)


def load_home(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    return _HOME_CACHE.get(str(repo), repo)


# --------------------------------------------------------------------------- #
# Supervisor ask / report (singular.orchestration.ask.v0)                       #
# --------------------------------------------------------------------------- #
#
# The console's ONLY two write endpoints beyond /api/settings. Each POST is a
# DELIBERATE subprocess exception (a spawner, not a collector): it launches an
# engine script (engine/ask.sh, engine/supervise.sh) via subprocess.Popen with a
# list argv (NEVER shell=True), cwd=repo, start_new_session=True so the readonly
# runner outlives the request. The operator question transits question.md on disk
# and NEVER a runner argv. The GET side (collect_ask/collect_asks) stays pure-FS.

ASK_ID_RE = re.compile(r"^ASK-[A-Za-z0-9-]+$")
ASK_QUESTION_MAX = 2000            # chars accepted on POST /api/ask (post-CR-strip)
ASK_QUESTION_STORE_CAP = 280       # question head persisted (mirrors the engine)
ASK_ANSWER_CAP = 32768             # answer.md bytes returned by /api/ask/<id>
ASK_LIST_LIMIT = 20                # newest ASK runs on /api/asks
ASK_LIST_ANSWER_CAP = 2000         # answer head kept per /api/asks list entry
ASK_BUSY_SCAN = 10                 # newest ASK dirs inspected for the busy guard
ASK_TOKEN_BYTES = 2               # token_hex bytes in a minted ASK id (engine parity)
ASK_CRASH_STALE_SECONDS = 60.0     # running + dead pid + stale ask.json => crashed
REPORT_MIN_INTERVAL_SECONDS = 60.0  # throttle window for POST /api/report

_ASK_SPAWN_LOCK = threading.Lock()
_REPORT_SPAWN_LOCK = threading.Lock()


def _validate_ask_question(raw: str) -> tuple[bool, str]:
    """Sanitize + bound an operator question: strip CR, reject other C0 control
    chars (except \\n and \\t), cap at 2000 chars, reject empty. Returns
    (ok, cleaned_or_error)."""
    q = raw.replace("\r", "")
    if len(q) > ASK_QUESTION_MAX:
        return False, f"question too long (max {ASK_QUESTION_MAX} chars)"
    if any(ord(ch) < 0x20 and ch not in ("\n", "\t") for ch in q):
        return False, "question contains control characters"
    q = q.strip()
    if not q:
        return False, "question must not be empty"
    return True, q


def _ask_dirs_newest(repo: Path, limit: int) -> list[tuple[float, Path, str]]:
    """(mtime, path, name) for the newest ``limit`` ASK-* run dirs. Pure FS."""
    runs_root = state_path(repo, "runs")
    out: list[tuple[float, Path, str]] = []
    if runs_root.is_dir():
        try:
            for entry in os.scandir(runs_root):
                if entry.name.startswith("ASK-") and entry.is_dir(follow_symlinks=False):
                    out.append((_safe_mtime(Path(entry.path)), Path(entry.path), entry.name))
        except OSError:
            pass
    out.sort(key=lambda t: t[0], reverse=True)
    return out[:limit]


def _active_ask(repo: Path) -> str | None:
    """runId of a currently-running ask (state running + a live pid) among the
    newest few ASK dirs, else None. Backs the single-flight busy guard."""
    for _mtime, path, name in _ask_dirs_newest(repo, ASK_BUSY_SCAN):
        ask = read_json(path / "ask.json", None)
        if (isinstance(ask, dict) and str(ask.get("state")) == "running"
                and _pid_alive(ask.get("pid"))):
            return name
    return None


def _ask_state(ask: dict[str, Any], ask_json_path: Path) -> str:
    """Derive the reported ask state, applying the crash rule: a `running` ask
    whose pid is dead and whose ask.json has gone stale (>60s) is a crashed engine
    process, surfaced as `error`."""
    state = str(ask.get("state") or "pending")
    if state == "running":
        mtime = _safe_mtime(ask_json_path)
        stale = (time.time() - mtime) if mtime else 0.0
        if not _pid_alive(ask.get("pid")) and stale > ASK_CRASH_STALE_SECONDS:
            return "error"
    return state


def collect_ask(repo: Path, run_id: str, *, answer_cap: int = ASK_ANSWER_CAP) -> dict[str, Any] | None:
    """One ASK run's live state (pure FS; id regex + path containment). Derives a
    terminal `error` when the engine crashed mid-run. `proposedSettings` are
    re-filtered through the settings write whitelist (defense in depth — the engine
    already restricts them). None when the run dir is absent / outside runs/."""
    repo = repo.resolve()
    if not ASK_ID_RE.match(run_id):
        return None
    runs_root = state_path(repo, "runs").resolve()
    run_dir = (runs_root / run_id).resolve()
    if run_dir.parent != runs_root or not run_dir.is_dir():
        return None
    ask = read_json(run_dir / "ask.json", None)
    ask = ask if isinstance(ask, dict) else {}
    state = _ask_state(ask, run_dir / "ask.json")
    try:
        answer = (run_dir / "answer.md").read_text(errors="replace")[:answer_cap]
    except OSError:
        answer = None
    proposed: dict[str, str] = {}
    raw_proposed = ask.get("proposedSettings")
    if isinstance(raw_proposed, dict):
        whitelist, _kinds = _settings_write_spec()
        proposed = {str(k): str(v) for k, v in raw_proposed.items() if k in whitelist}
    return {
        "schema": "singular.orchestration.ask.v0",
        "runId": run_id,
        "state": state,
        # Model output is among the likeliest places for a credential the model
        # READ to be echoed back, so both directions are redacted after capping.
        "question": redact_secrets(str(ask.get("question") or "")[:ASK_QUESTION_STORE_CAP]),
        "createdAt": ask.get("createdAt"),
        "updatedAt": ask.get("updatedAt"),
        "answeredAt": ask.get("answeredAt"),
        "answer": redact_secrets(answer) if answer else answer,
        "proposedSettings": proposed,
    }


def collect_asks(repo: Path) -> dict[str, Any]:
    """Newest-20 ASK runs as a list (pure FS). List entries keep only an answer
    head; the full answer is fetched per-run via /api/ask/<id>."""
    repo = repo.resolve()
    asks: list[dict[str, Any]] = []
    for _mtime, _path, name in _ask_dirs_newest(repo, ASK_LIST_LIMIT):
        detail = collect_ask(repo, name, answer_cap=ASK_LIST_ANSWER_CAP)
        if detail is not None:
            asks.append(detail)
    return {"schema": "singular.orchestration.asks.v0", "generatedAt": utc_now(), "asks": asks}


def _spawn_engine_script(repo: Path, script: str, args: list[str]) -> None:
    """Launch an engine script detached from the request. DELIBERATE subprocess
    exception: a list argv (never shell=True), cwd=repo, start_new_session=True so
    the readonly runner survives the HTTP response; SINGULAR_ROOT is pinned to the
    served repo (lib.sh honors it). Inherits the server env otherwise (the console
    sets SINGULAR_ENGINE_HOME; the child self-resolves it from its own path too)."""
    engine_script = _engine_dir() / script
    child_env = {**os.environ, "SINGULAR_ROOT": str(repo)}
    subprocess.Popen(
        ["bash", str(engine_script), *args],
        cwd=str(repo), env=child_env,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def spawn_ask(repo: Path, question: str) -> tuple[int, dict[str, Any]]:
    """Mint an ASK run, stage question.md + ask.json{pending}, and spawn
    engine/ask.sh detached. The question is written to disk and NEVER passed in the
    runner argv. Returns (202, {runId,...}) or (429, {...activeRunId}) when an ask
    is already running. The mint + spawn are serialized so two POSTs can't race."""
    repo = Path(repo).resolve()
    with _ASK_SPAWN_LOCK:
        active = _active_ask(repo)
        if active is not None:
            return 429, {"error": "an ask is already running", "activeRunId": active}
        stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
        run_id = f"ASK-{stamp}-{secrets.token_hex(ASK_TOKEN_BYTES)}"
        run_dir = state_path(repo, "runs", run_id)
        try:
            run_dir.mkdir(parents=True, exist_ok=True)
            _atomic_write_text(run_dir / "question.md", question + "\n")
            now = utc_now()
            _atomic_write_text(run_dir / "ask.json", json.dumps({
                "schema": "singular.orchestration.ask.v0", "runId": run_id,
                "state": "pending", "question": question[:ASK_QUESTION_STORE_CAP],
                "createdAt": now, "updatedAt": now,
            }, indent=2) + "\n")
            _spawn_engine_script(repo, "ask.sh", ["--run-id", run_id])
        except OSError as exc:
            return 500, {"error": f"could not start ask: {exc}"}
        return 202, {"runId": run_id, "state": "pending"}


def _supervisor_last_activity(repo: Path) -> float | None:
    """Freshest signal of supervisor activity: max of the engine's
    supervisor/last-run epoch stamp and the newest SUP-* run dir mtime. None when
    no briefing has ever run. Backs the POST /api/report throttle."""
    times: list[float] = []
    stamp = state_path(repo, "supervisor", "last-run")
    try:
        times.append(float(stamp.read_text().strip()))
    except (OSError, ValueError):
        pass
    runs_root = state_path(repo, "runs")
    if runs_root.is_dir():
        try:
            for entry in os.scandir(runs_root):
                if entry.name.startswith("SUP-") and entry.is_dir(follow_symlinks=False):
                    times.append(_safe_mtime(Path(entry.path)))
        except OSError:
            pass
    return max(times) if times else None


def spawn_report(repo: Path) -> tuple[int, dict[str, Any]]:
    """Spawn engine/supervise.sh --once detached (same deliberate-subprocess
    exception as spawn_ask). 429 when a briefing ran within the last 60s (covers
    both an in-flight SUP run and a just-finished one). Returns (202, {...})."""
    repo = Path(repo).resolve()
    with _REPORT_SPAWN_LOCK:
        last = _supervisor_last_activity(repo)
        if last is not None and (time.time() - last) < REPORT_MIN_INTERVAL_SECONDS:
            wait = int(REPORT_MIN_INTERVAL_SECONDS - (time.time() - last)) + 1
            return 429, {"error": "a briefing ran within the last minute",
                         "retryAfterSeconds": max(1, wait)}
        try:
            _spawn_engine_script(repo, "supervise.sh", ["--once"])
        except OSError as exc:
            return 500, {"error": f"could not start briefing: {exc}"}
        return 202, {"state": "requested"}


# --------------------------------------------------------------------------- #
# Plan threads registry (singular.plans.v0)                                     #
# --------------------------------------------------------------------------- #

# A plan id as minted by `singular plan archive` (plan-<UTCstamp>[-<slug>]). Also
# the sole gate for the ?plan= filesystem-root param, so the charset is tight.
PLAN_ID_RE = re.compile(r"^plan-[A-Za-z0-9-]{1,64}$")

# Fields surfaced for each archived plan; mirrors the engine's index.json entry
# (ops.sh) and the plan manifest.json (both share these keys).
_PLAN_ENTRY_FIELDS = ("id", "name", "archivedAt", "gates", "taskCount",
                      "eventCount", "headSha", "branch")


def _plan_entry(src: dict[str, Any]) -> dict[str, Any]:
    return {k: src.get(k) for k in _PLAN_ENTRY_FIELDS}


def collect_plans(repo: Path) -> dict[str, Any]:
    """Pure-filesystem read of the archived-plan registry. Reads
    ``.singular-state/plans/index.json`` and self-heals by also scanning
    ``plans/*/manifest.json`` for any archived dir missing from the index
    (merge by id; index entries win). Sorted newest-first. Missing/empty →
    ``plans: []``."""
    plans_dir = state_path(repo, "plans")
    entries: dict[str, dict[str, Any]] = {}
    # Self-heal first so index entries (authoritative) overwrite manifest-derived
    # ones on the merge below.
    if plans_dir.is_dir():
        try:
            children = sorted(plans_dir.iterdir())
        except OSError:
            children = []
        for child in children:
            if not child.is_dir():
                continue
            manifest = read_json(child / "manifest.json")
            if isinstance(manifest, dict) and isinstance(manifest.get("id"), str) and manifest["id"]:
                entries[manifest["id"]] = _plan_entry(manifest)
    index = read_json(plans_dir / "index.json")
    if isinstance(index, dict):
        for item in index.get("plans") or []:
            if isinstance(item, dict) and isinstance(item.get("id"), str) and item["id"]:
                entries[item["id"]] = _plan_entry(item)
    plans = sorted(entries.values(), key=lambda p: p.get("archivedAt") or "", reverse=True)
    return {"schema": "singular.plans.v0", "generatedAt": utc_now(), "plans": plans}


_PLANS_CACHE = _ComputeCache(collect_plans, 6.0)


def load_plans(repo: Path) -> dict[str, Any]:
    repo = repo.resolve()
    return _PLANS_CACHE.get(str(repo), repo)


# --------------------------------------------------------------------------- #
# Console adapter (singular.console-adapter.v0)                                     #
# --------------------------------------------------------------------------- #
#
# Everything project-shaped in this console (role catalog, event map, id
# patterns, paths, commands, process matchers, log maps, settings spec/source)
# can be externalized into a versioned adapter document. Resolution happens
# ONCE at startup (mirroring load_repo_target_branch + its call in main()),
# with per-KEY precedence:
#
#   (a) repo override   — singular.config.json "console" block (inline object),
#                         then docs/orchestration/console-adapter.json
#   (b) engine-shipped  — $SINGULAR_ENGINE_HOME/plugin/adapters/
#                         console-adapter.<schemaVersion>.json
#   (c) built-in        — the module constants above (exact legacy behavior)
#
# With no adapter resolvable the constants are untouched and every endpoint
# behaves byte-identically to the pre-adapter console. A malformed adapter
# layer (or one malformed key) warns to stderr and falls through — the console
# never crashes over adapter content.

CONSOLE_ADAPTER_SCHEMA = "singular.console-adapter.v0"


def _build_builtin_console_adapter() -> dict[str, Any]:
    """Snapshot the built-in constants in adapter (JSON-shaped) form."""
    return {
        "schema": CONSOLE_ADAPTER_SCHEMA,
        "roleCatalog": ROLE_CATALOG,
        "rolePromptMap": dict(ROLE_PROMPT_MAP),
        "eventMap": {k: list(v) for k, v in EVENT_MAP.items()},
        "noiseEventTypes": sorted(NOISE_EVENT_TYPES),
        "idPatterns": {
            "task": TASK_ID_RE.pattern,
            "node": NODE_ID_RE.pattern,
            "area": AREA_ID_RE.pattern,
        },
        # Inline (?m) carries the re.MULTILINE flag through the JSON round trip.
        "plannerPromptPatterns": {
            "area": _PLANNER_AREA_RE.pattern,
            "node": _PLANNER_NODE_RE.pattern,
            "stage": "(?m)" + _PLANNER_STAGE_RE.pattern,
            "layer": "(?m)" + _PLANNER_LAYER_RE.pattern,
        },
        "settingsSpec": [
            {"title": title, "layout": layout,
             "items": [{"envKey": key, "label": label, "default": fallback,
                        "kind": kind, "unit": unit, "meaning": meaning}
                       for key, label, fallback, kind, unit, meaning in items]}
            for title, layout, items in SETTINGS_SPEC
        ],
        "paths": {
            "dagFile": DAG_REL,
            "stageDoc": STAGE_DOC_REL,
            "gatesDir": GATES_REL,
            "tasksDir": TASKS_DIR_REL,
            "areasDir": AREAS_DIR_REL,
            "stateDir": STATE_DIR_REL,
            "eventsLog": EVENTS_LOG_REL,
            "autonomateLog": AUTONOMATE_LOG_REL,
            "statusFile": STATUS_REL,
            "circuitFile": CIRCUIT_REL,
            "stopFile": STOP_REL,
            "orchScriptsDir": ORCH_SCRIPTS_REL,
            "platformVision": PLATFORM_VISION_REL,
        },
        "commands": {k: list(v) for k, v in CONSOLE_COMMANDS.items()},
        "processMatchers": {k: list(v) for k, v in PROCESS_MATCHERS.items()},
        "logFileMaps": {
            "codexLogs": [[name, role] for name, role in CODEX_LOG_NAMES],
            "plainLogs": list(PLAIN_LOG_NAMES),
        },
        "settingsSource": SETTINGS_SOURCE,
    }


# Primed at import time, before any adapter can mutate the globals, so the (c)
# fallback layer always reflects the pristine built-ins.
_BUILTIN_CONSOLE_ADAPTER = _build_builtin_console_adapter()


def builtin_console_adapter() -> dict[str, Any]:
    return _BUILTIN_CONSOLE_ADAPTER


def _adapter_warn(msg: str) -> None:
    print(f"singular console adapter: {msg}", file=sys.stderr)


def _read_adapter_layer(path: Path, origin: str) -> dict[str, Any] | None:
    """Read one adapter JSON layer. Missing file -> None (silent). Malformed
    JSON / non-object -> warn to stderr and return None (fall through)."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        data = json.loads(text)
    except ValueError as exc:
        _adapter_warn(f"ignoring malformed {origin} ({path}): {exc}")
        return None
    if not isinstance(data, dict):
        _adapter_warn(f"ignoring {origin} ({path}): top level must be an object")
        return None
    return data


def load_console_adapter(repo, engine_home: str | None = None,
                         schema_version: str | None = None) -> dict[str, Any]:
    """Resolve the effective console adapter for ``repo`` with per-KEY precedence
    repo override > engine-shipped > built-in. Never raises on adapter content."""
    repo = Path(repo)
    cfg = read_json(repo / "singular.config.json", None)
    cfg = cfg if isinstance(cfg, dict) else {}
    if schema_version is None:
        sv = cfg.get("schemaVersion")
        schema_version = sv if isinstance(sv, str) and sv else "v0"
    merged = dict(builtin_console_adapter())

    def overlay(layer: dict[str, Any] | None) -> None:
        if not layer:
            return
        merged.update({k: v for k, v in layer.items() if k != "schema"})

    if engine_home:
        overlay(_read_adapter_layer(
            Path(engine_home) / "plugin" / "adapters" / f"console-adapter.{schema_version}.json",
            "engine adapter"))
    overlay(_read_adapter_layer(repo / "docs/orchestration/console-adapter.json", "repo adapter"))
    inline = cfg.get("console")
    if isinstance(inline, dict):
        overlay(inline)
    elif inline is not None:
        _adapter_warn("ignoring singular.config.json 'console': must be an object")
    return merged


# The resolved adapter document (None until apply_console_adapter runs).
CONSOLE_ADAPTER: dict[str, Any] | None = None


def apply_console_adapter(adapter: dict[str, Any]) -> None:
    """Install a resolved adapter into the module globals every collector reads.
    Each key is applied independently; an invalid value warns and keeps the
    built-in for that key only, so bad adapter content can never take the
    console down."""
    builtin = builtin_console_adapter()
    g = globals()

    def value(key: str, deep_merge: bool = False) -> Any:
        raw = adapter.get(key)
        if raw is None:
            return builtin[key]
        if deep_merge and isinstance(raw, dict) and isinstance(builtin[key], dict):
            return {**builtin[key], **raw}
        return raw

    def apply(key: str, fn) -> None:
        try:
            g.update(fn())
        except Exception as exc:  # defensive: one bad key never kills startup
            _adapter_warn(f"key '{key}' invalid, keeping built-in: {exc}")

    apply("roleCatalog", lambda: {"ROLE_CATALOG": value("roleCatalog")})
    apply("rolePromptMap", lambda: {"ROLE_PROMPT_MAP": dict(value("rolePromptMap", True))})
    apply("eventMap", lambda: {"EVENT_MAP": {
        str(k): (str(v[0]), str(v[1]), str(v[2]), bool(v[3]))
        for k, v in value("eventMap", True).items()}})
    apply("noiseEventTypes", lambda: {"NOISE_EVENT_TYPES": {str(t) for t in value("noiseEventTypes")}})

    def _id_patterns() -> dict[str, Any]:
        pats = value("idPatterns", True)
        return {"TASK_ID_RE": re.compile(pats["task"]),
                "NODE_ID_RE": re.compile(pats["node"]),
                "AREA_ID_RE": re.compile(pats["area"])}
    apply("idPatterns", _id_patterns)

    def _planner_patterns() -> dict[str, Any]:
        pats = {**builtin["plannerPromptPatterns"], **(adapter.get("plannerPromptPatterns") or {})}
        return {"_PLANNER_AREA_RE": re.compile(pats["area"]),
                "_PLANNER_NODE_RE": re.compile(pats["node"]),
                "_PLANNER_STAGE_RE": re.compile(pats["stage"]),
                "_PLANNER_LAYER_RE": re.compile(pats["layer"])}
    apply("plannerPromptPatterns", _planner_patterns)

    def _settings_spec() -> dict[str, Any]:
        spec = []
        for group in value("settingsSpec"):
            items = [(it["envKey"], it["label"], it["default"],
                      it.get("kind", ""), it.get("unit", ""), it.get("meaning", ""))
                     for it in group["items"]]
            spec.append((group["title"], group.get("layout", "list"), items))
        return {"SETTINGS_SPEC": spec}
    apply("settingsSpec", _settings_spec)

    def _paths() -> dict[str, Any]:
        paths = value("paths", True)
        return {"DAG_REL": str(paths["dagFile"]),
                "STAGE_DOC_REL": str(paths["stageDoc"]),
                "GATES_REL": str(paths["gatesDir"]),
                "TASKS_DIR_REL": str(paths["tasksDir"]),
                "AREAS_DIR_REL": str(paths["areasDir"]),
                "STATE_DIR_REL": str(paths["stateDir"]),
                "EVENTS_LOG_REL": str(paths["eventsLog"]),
                "AUTONOMATE_LOG_REL": str(paths["autonomateLog"]),
                "STATUS_REL": str(paths["statusFile"]),
                "CIRCUIT_REL": str(paths["circuitFile"]),
                "STOP_REL": str(paths["stopFile"]),
                "ORCH_SCRIPTS_REL": str(paths["orchScriptsDir"]),
                "PLATFORM_VISION_REL": str(paths["platformVision"])}
    apply("paths", _paths)

    apply("commands", lambda: {"CONSOLE_COMMANDS": {
        str(k): [str(p) for p in v] for k, v in value("commands", True).items()}})
    apply("processMatchers", lambda: {"PROCESS_MATCHERS": dict(value("processMatchers", True))})

    def _log_file_maps() -> dict[str, Any]:
        maps = value("logFileMaps", True)
        return {"CODEX_LOG_NAMES": tuple((str(n), str(r)) for n, r in maps["codexLogs"]),
                "PLAIN_LOG_NAMES": tuple(str(n) for n in maps["plainLogs"])}
    apply("logFileMaps", _log_file_maps)

    src = adapter.get("settingsSource", builtin["settingsSource"])
    g["SETTINGS_SOURCE"] = str(src) if src else None
    g["CONSOLE_ADAPTER"] = adapter


# --------------------------------------------------------------------------- #
# HTTP server                                                                   #
# --------------------------------------------------------------------------- #

class SnapshotCache:
    """TTL cache with stale-serve so /api/state never hangs a poll.

    fresh-enough cached -> returned as before. Stale cached (and not ?fresh=1)
    -> a single background daemon refresh is kicked and the OLD snapshot is
    returned IMMEDIATELY, marked stale/computing with its age. Cold start and
    ?fresh=1 keep blocking (single-flight) semantics. Background failures are
    recorded on ``last_error`` (surfaced by /api/health), never propagated."""

    def __init__(self, ttl: float = SNAPSHOT_TTL_SECONDS) -> None:
        self.ttl = ttl
        self._lock = threading.Lock()
        self._compute = threading.Lock()  # single-flight guard around collect_snapshot
        self._value: dict[str, Any] | None = None
        self._stamp: float = 0.0
        self._key: str = ""
        self._refreshing = False
        self.last_error: str | None = None

    def _fresh_enough(self, key: str) -> dict[str, Any] | None:
        with self._lock:
            if self._value is not None and self._key == key and (time.monotonic() - self._stamp) < self.ttl:
                return self._value
        return None

    def _cached(self, key: str) -> tuple[dict[str, Any] | None, float]:
        with self._lock:
            if self._value is not None and self._key == key:
                return self._value, time.monotonic() - self._stamp
        return None, 0.0

    def _store(self, snapshot: dict[str, Any], key: str) -> None:
        with self._lock:
            self._value = snapshot
            self._stamp = time.monotonic()
            self._key = key
            self.last_error = None

    def age_seconds(self) -> float | None:
        with self._lock:
            if self._value is None:
                return None
            return time.monotonic() - self._stamp

    def _refresh_in_background(self, repo: Path, key: str) -> None:
        try:
            with self._compute:
                if self._fresh_enough(key) is None:
                    self._store(collect_snapshot(repo), key)
        except Exception as exc:  # never let a refresh failure escape the daemon thread
            with self._lock:
                self.last_error = f"{type(exc).__name__}: {exc}"
        finally:
            with self._lock:
                self._refreshing = False

    def get(self, repo: Path, fresh: bool = False) -> dict[str, Any]:
        key = str(repo.resolve())
        if not fresh:
            cached = self._fresh_enough(key)
            if cached is not None:
                return cached
            value, age = self._cached(key)
            if value is not None:
                # Stale-serve: hand the old snapshot back immediately (marked so
                # the UI can say so) while at most one daemon thread refreshes.
                with self._lock:
                    start = not self._refreshing
                    if start:
                        self._refreshing = True
                if start:
                    threading.Thread(
                        target=self._refresh_in_background, args=(repo, key), daemon=True,
                    ).start()
                stale = dict(value)
                stale["stale"] = True
                stale["computing"] = True
                stale["snapshotAgeSeconds"] = int(age)
                return stale
        # Cold start or explicit ?fresh=1: block and compute (single-flight; the
        # native probes make this fast).
        with self._compute:
            if not fresh:
                cached = self._fresh_enough(key)
                if cached is not None:
                    return cached
            snapshot = collect_snapshot(repo)
            self._store(snapshot, key)
            return snapshot


SNAPSHOT_CACHE = SnapshotCache()


class SessionsCache:
    """Independent 2s TTL cache for the session list. Decoupled from the snapshot
    cache so the terminal can poll at 2s without dragging in the slower make/git
    snapshot fan-out — collect_sessions is pure filesystem reads."""

    def __init__(self, ttl: float = SESSIONS_TTL_SECONDS) -> None:
        self.ttl = ttl
        self._lock = threading.Lock()
        self._compute = threading.Lock()
        self._value: dict[str, Any] | None = None
        self._stamp: float = 0.0
        self._key: str = ""

    def _fresh_enough(self, key: str) -> dict[str, Any] | None:
        with self._lock:
            if self._value is not None and self._key == key and (time.monotonic() - self._stamp) < self.ttl:
                return self._value
        return None

    def get(self, repo: Path) -> dict[str, Any]:
        key = str(repo.resolve())
        cached = self._fresh_enough(key)
        if cached is not None:
            return cached
        with self._compute:
            cached = self._fresh_enough(key)
            if cached is not None:
                return cached
            value = collect_sessions(repo)
            with self._lock:
                self._value = value
                self._stamp = time.monotonic()
                self._key = key
            return value


SESSIONS_CACHE = SessionsCache()


class Handler(BaseHTTPRequestHandler):
    repo: Path = Path(DEFAULT_REPO)

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def resolve_plan_repo(self, query: dict[str, list[str]]):
        """Resolve the read-collector root for a request's optional ?plan= param.

        No ``plan`` param → ``(Handler.repo, False)`` (live). Otherwise the id is
        validated against ``PLAN_ID_RE``, required to exist in the archived-plan
        registry, and its ``plans/<id>`` dir must resolve *inside* the plans dir
        and be an existing directory → ``(that_dir, True)``. Any failure returns
        ``None`` and the caller replies 404 ``{"error": "unknown plan"}``."""
        raw = query.get("plan", [None])[0]
        if raw is None or raw == "":
            return (self.repo, False)
        pid = raw
        if not PLAN_ID_RE.match(pid):
            return None
        listing = load_plans(self.repo)
        if pid not in {p.get("id") for p in listing.get("plans", [])}:
            return None
        plans_dir = state_path(self.repo, "plans").resolve()
        candidate = (state_path(self.repo, "plans") / pid).resolve()
        try:
            candidate.relative_to(plans_dir)
        except ValueError:
            return None
        if candidate == plans_dir or not candidate.is_dir():
            return None
        return (candidate, True)

    def _plan_root(self, query: dict[str, list[str]]):
        """resolve_plan_repo(), but on failure it sends the 404 and returns None
        so the route can just ``if resolved is None: return``."""
        resolved = self.resolve_plan_repo(query)
        if resolved is None:
            self.send_json({"error": "unknown plan"}, 404)
        return resolved

    def _no_cache_headers(self) -> None:
        self.send_header("Cache-Control", "no-store, must-revalidate")

    def send_json(self, data: Any, status: int = 200, cache: str | None = None) -> None:
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        if cache:
            self.send_header("Cache-Control", cache)
        else:
            self._no_cache_headers()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_asset(self, filename: str | Path, content_type: str) -> None:
        path = filename if isinstance(filename, Path) else ASSETS_DIR / filename
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            self.send_json({"error": f"asset not found: {filename}", "assetsDir": str(ASSETS_DIR)}, 500)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self._no_cache_headers()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_HEAD(self) -> None:  # noqa: N802
        """Answer reachability preflights (ranger-cli, uptime probes send HEAD;
        BaseHTTPRequestHandler otherwise 501s the verb). Headers only, no body:
        200 for the app root and the health route, 404 for everything else —
        honest without duplicating the GET router."""
        route = urlparse(self.path).path
        if route in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            return
        if route == "/api/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        route = parsed.path
        if route == "/":
            self.send_asset("index.html", "text/html; charset=utf-8")
            return
        if route.startswith("/assets/"):
            resolved = resolve_asset(unquote(route[len("/assets/"):]))
            if resolved is None:
                self.send_json({"error": "not found"}, 404)
                return
            self.send_asset(resolved[0], resolved[1])
            return
        if route == "/api/state":
            query = parse_qs(parsed.query)
            # Always use the operator-configured repo; never run subprocesses in a
            # caller-supplied cwd (the ?repo= param is intentionally ignored).
            fresh = query.get("fresh", ["0"])[0] not in ("0", "", "false")
            self.send_json(SNAPSHOT_CACHE.get(self.repo, fresh=fresh))
            return
        if route.startswith("/api/task/"):
            resolved = self._plan_root(parse_qs(parsed.query))
            if resolved is None:
                return
            repo, _ = resolved
            task_id = unquote(route[len("/api/task/"):]).strip("/")
            if not TASK_ID_RE.match(task_id):
                self.send_json({"error": "invalid task id"}, 400)
                return
            detail = collect_task_detail(repo, task_id)
            if detail is None:
                self.send_json({"error": f"task not found: {task_id}"}, 404)
                return
            self.send_json(detail)
            return
        if route == "/api/sessions":
            query = parse_qs(parsed.query)
            resolved = self._plan_root(query)
            if resolved is None:
                return
            repo, is_archived = resolved
            limit = query.get("limit", [SESSION_RETURN_LIMIT])[0]
            # Archived data is cold + immutable: bypass the live SessionsCache
            # (single-slot, 2s TTL) and read the mini-repo directly.
            sessions = collect_sessions(repo) if is_archived else SESSIONS_CACHE.get(repo)
            self.send_json(slice_sessions(sessions, limit))
            return
        if route.startswith("/api/session/"):
            session_id = unquote(route[len("/api/session/"):]).strip("/")
            query = parse_qs(parsed.query)
            resolved = self._plan_root(query)
            if resolved is None:
                return
            repo, _ = resolved

            def _int(name: str) -> int | None:
                raw = query.get(name, [None])[0]
                if raw is None or raw == "":
                    return None
                try:
                    return int(raw)
                except ValueError:
                    return None

            cursor = _int("cursor")
            limit = _int("limit") or SESSION_LINE_LIMIT_DEFAULT
            limit = max(1, min(SESSION_LINE_LIMIT_MAX, limit))
            file_name = query.get("file", [None])[0] or None
            raw = query.get("raw", ["0"])[0] not in ("0", "", "false")
            data = read_session(repo, session_id, cursor, limit, file_name, raw)
            if data is None:
                self.send_json({"error": f"session not found: {session_id}"}, 404)
                return
            self.send_json(data)
            return
        if route.startswith("/api/node/"):
            resolved = self._plan_root(parse_qs(parsed.query))
            if resolved is None:
                return
            repo, _ = resolved
            node_id = unquote(route[len("/api/node/"):]).strip("/")
            if not NODE_ID_RE.match(node_id):
                self.send_json({"error": "invalid node id"}, 400)
                return
            detail = collect_node_detail(repo, node_id)
            if detail is None:
                self.send_json({"error": f"node not found: {node_id}"}, 404)
                return
            self.send_json(detail)
            return
        if route.startswith("/api/area/") and route.endswith("/nodes"):
            resolved = self._plan_root(parse_qs(parsed.query))
            if resolved is None:
                return
            repo, _ = resolved
            area = unquote(route[len("/api/area/"):-len("/nodes")]).strip("/")
            if not AREA_ID_RE.match(area):
                self.send_json({"error": "invalid area"}, 400)
                return
            detail = collect_area_nodes(repo, area)
            if detail is None:
                self.send_json({"error": f"area not found: {area}"}, 404)
                return
            self.send_json(detail)
            return
        if route == "/api/dag":
            resolved = self._plan_root(parse_qs(parsed.query))
            if resolved is None:
                return
            self.send_json(load_dag_view(resolved[0]))
            return
        if route == "/api/config":
            self.send_json(load_config_view(self.repo))
            return
        if route == "/api/settings":
            self.send_json(collect_settings_view(self.repo))
            return
        if route == "/api/providers":
            # Live-only (like /api/config, /api/settings): a ?plan= param is
            # ignored — provider status is always the live machine's runtimes.
            query = parse_qs(parsed.query)
            refresh = query.get("refresh", ["0"])[0] not in ("0", "", "false")
            self.send_json(collect_providers(self.repo, refresh=refresh))
            return
        if route == "/api/prompts":
            resolved = self._plan_root(parse_qs(parsed.query))
            if resolved is None:
                return
            self.send_json(collect_prompts(resolved[0]))
            return
        if route.startswith("/api/prompt/"):
            resolved = self._plan_root(parse_qs(parsed.query))
            if resolved is None:
                return
            repo, _ = resolved
            name = unquote(route[len("/api/prompt/"):]).strip("/")
            data = collect_prompt(repo, name)
            if data is None:
                self.send_json({"error": f"prompt not found: {name}"}, 404)
                return
            self.send_json(data)
            return
        if route.startswith("/api/raw/"):
            resolved = self._plan_root(parse_qs(parsed.query))
            if resolved is None:
                return
            repo, _ = resolved
            rest = unquote(route[len("/api/raw/"):]).strip("/")
            raw_root, sep, raw_name = rest.partition("/")
            if not sep or not raw_name:
                self.send_json({"error": "raw request must be /api/raw/<root>/<name>"}, 400)
                return
            data = collect_raw(repo, raw_root, raw_name)
            if data is None:
                self.send_json({"error": f"raw not found: {raw_root}/{raw_name}"}, 404)
                return
            self.send_json(data)
            return
        if route == "/api/timeline":
            query = parse_qs(parsed.query)
            resolved = self._plan_root(query)
            if resolved is None:
                return
            since = (query.get("since", [""])[0] or "").strip()
            data = load_timeline(resolved[0])
            self.send_json(filter_timeline_since(data, since) if since else data)
            return
        if route == "/api/overview":
            resolved = self._plan_root(parse_qs(parsed.query))
            if resolved is None:
                return
            self.send_json(load_overview(resolved[0]))
            return
        if route == "/api/home":
            self.send_json(load_home(self.repo))
            return
        if route == "/api/asks":
            # Live-only (like /api/home): the supervisor ask thread is always the
            # live machine's; a ?plan= param is ignored.
            self.send_json(collect_asks(self.repo))
            return
        if route.startswith("/api/ask/"):
            run_id = unquote(route[len("/api/ask/"):]).strip("/")
            detail = collect_ask(self.repo, run_id)
            if detail is None:
                self.send_json({"error": f"ask not found: {run_id}"}, 404)
                return
            self.send_json(detail)
            return
        if route == "/api/plans":
            self.send_json(load_plans(self.repo))
            return
        if route == "/api/events":
            query = parse_qs(parsed.query)
            resolved = self._plan_root(query)
            if resolved is None:
                return
            repo, _ = resolved
            raw_cursor = query.get("cursor", [None])[0]
            try:
                cursor = int(raw_cursor) if raw_cursor not in (None, "") else None
            except ValueError:
                cursor = None
            try:
                limit = int(query.get("limit", [OVERLAY_ROW_LIMIT_DEFAULT])[0])
            except ValueError:
                limit = OVERLAY_ROW_LIMIT_DEFAULT
            limit = max(1, min(OVERLAY_ROW_LIMIT_MAX, limit))
            type_csv = query.get("types", [None])[0]
            types = {t for t in type_csv.split(",") if t} if type_csv else None
            self.send_json(collect_events_overlay(repo, cursor, limit, types))
            return
        if route == "/api/roles":
            # Static declared reference data — safe to cache hard.
            self.send_json(ROLE_CATALOG, cache="public, max-age=86400, immutable")
            return
        if route == "/api/health":
            # Pure liveness: reports the snapshot cache's age/last error without
            # computing anything.
            age = SNAPSHOT_CACHE.age_seconds()
            self.send_json({
                "ok": True,
                "generatedAt": utc_now(),
                "repo": str(self.repo),
                "snapshotAgeSeconds": int(age) if age is not None else None,
                "lastSnapshotError": SNAPSHOT_CACHE.last_error,
                # Surfaced so a disabled security control cannot be silently
                # off: SINGULAR_CONSOLE_REDACT=0 is answerable without a browser.
                "redaction": REDACT_ENABLED,
            })
            return
        self.send_json({"error": "not found"}, 404)

    def _read_json_body(self, limit: int = 65536) -> tuple[bool, Any]:
        """Read + JSON-parse a request body, sending the 400 itself on any framing
        or parse error. Returns (ok, value); on ok the value is the parsed JSON (an
        empty body parses to {}). Shared by the /api/ask + /api/report write routes;
        /api/settings keeps its own byte-identical reader."""
        raw_len = self.headers.get("Content-Length")
        if raw_len is None:
            self.send_json({"error": "Content-Length required"}, 400)
            return False, None
        try:
            length = int(raw_len)
        except ValueError:
            self.send_json({"error": "invalid Content-Length"}, 400)
            return False, None
        if length < 0 or length > limit:
            self.send_json({"error": "request body too large"}, 400)
            return False, None
        body = self.rfile.read(length) if length else b""
        if not body:
            return True, {}
        try:
            return True, json.loads(body.decode("utf-8"))
        except Exception:
            self.send_json({"error": "malformed JSON body"}, 400)
            return False, None

    def _post_settings(self) -> None:
        # The console's primary write route; behavior is byte-identical to pre-0.10.
        raw_len = self.headers.get("Content-Length")
        if raw_len is None:
            self.send_json({"error": "Content-Length required"}, 400)
            return
        try:
            length = int(raw_len)
        except ValueError:
            self.send_json({"error": "invalid Content-Length"}, 400)
            return
        if length < 0 or length > 65536:
            self.send_json({"error": "request body too large"}, 400)
            return
        body = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(body.decode("utf-8"))
        except Exception:
            self.send_json({"error": "malformed JSON body"}, 400)
            return
        if not isinstance(payload, dict) or not isinstance(payload.get("changes"), dict):
            self.send_json({"error": 'body must be {"changes": {KEY: value, ...}}'}, 400)
            return
        status, resp = apply_settings_changes(self.repo, payload["changes"])
        self.send_json(resp, status)

    def _post_ask(self) -> None:
        # Deliberate spawner (not a collector): stages the question on disk and
        # launches engine/ask.sh — the question NEVER transits the runner argv.
        ok, payload = self._read_json_body()
        if not ok:
            return
        if not isinstance(payload, dict):
            self.send_json({"error": 'body must be {"question": "..."}'}, 400)
            return
        question = payload.get("question")
        if not isinstance(question, str):
            self.send_json({"error": "question must be a string"}, 400)
            return
        valid, cleaned = _validate_ask_question(question)
        if not valid:
            self.send_json({"error": cleaned}, 400)
            return
        status, resp = spawn_ask(self.repo, cleaned)
        self.send_json(resp, status)

    def _post_report(self) -> None:
        # Deliberate spawner: launches engine/supervise.sh --once (throttled).
        status, resp = spawn_report(self.repo)
        self.send_json(resp, status)

    def do_POST(self) -> None:
        # Write routes only: /api/settings, /api/ask, /api/report. Everything else
        # 404s. Archived plans are read-only mini-repos: reject any write scoped to
        # one before touching live state.
        parsed = urlparse(self.path)
        if parse_qs(parsed.query).get("plan"):
            self.send_json({"error": "archived plans are read-only"}, 400)
            return
        route = parsed.path
        if route == "/api/settings":
            self._post_settings()
            return
        if route == "/api/ask":
            self._post_ask()
            return
        if route == "/api/report":
            self._post_report()
            return
        self.send_json({"error": "not found"}, 404)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve a read-only singular orchestration console for a target repo.")
    parser.add_argument("--repo", default=os.environ.get("SINGULAR_REPO", DEFAULT_REPO), help="target repo path (defaults to SINGULAR_REPO or cwd)")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host")
    parser.add_argument("--port", type=int, default=8765, help="Bind port")
    parser.add_argument("--snapshot", action="store_true", help="Print one JSON snapshot and exit")
    parser.add_argument("--task", help="Print one task detail JSON (e.g. TASK-0309) and exit")
    parser.add_argument("--sessions", action="store_true", help="Print the live session list JSON and exit")
    parser.add_argument("--session", help="Print one session's terminal lines JSON and exit (run id or 'origin')")
    parser.add_argument("--node", help="Print one DAG node's provenance JSON (e.g. D1.contract) and exit")
    parser.add_argument("--area", help="Print one area's nodes JSON (e.g. artifact) and exit")
    parser.add_argument("--events", action="store_true", help="Print the live event overlay JSON and exit")
    parser.add_argument("--overview", action="store_true", help="Print the plan overview JSON and exit")
    parser.add_argument("--dag", action="store_true", help="Print the full DAG view JSON (nodes+gates+tasks+edges) and exit")
    parser.add_argument("--timeline", action="store_true", help="Print the execution timeline JSON (task intervals+gates+cycles) and exit")
    parser.add_argument("--config", action="store_true", help="Print the resolved per-role runner config JSON and exit")
    parser.add_argument("--providers", action="store_true", help="Print the runtime provider/runtime status JSON and exit")
    parser.add_argument("--prompts", action="store_true", help="Print the role prompt library JSON and exit")
    parser.add_argument("--prompt", help="Print one prompt's content JSON (e.g. auditor.md) and exit")
    parser.add_argument("--raw", help="Print one raw record JSON (e.g. config/singular.config.json) and exit")
    parser.add_argument("--home", action="store_true", help="Print the home landing digest JSON and exit")
    parser.add_argument("--plans", action="store_true", help="Print the archived-plan registry JSON and exit")
    return parser.parse_args(argv)


def write_console_state(repo: Path, url: str) -> list[Path]:
    """Persist the served URL + pid into the repo's state dir so `singular
    console --ensure/--status/--stop` and `singular status` can find a running
    console. Best-effort: failures warn to stderr, never abort serving. Opt
    out with SINGULAR_CONSOLE_NO_STATE=1."""
    if os.environ.get("SINGULAR_CONSOLE_NO_STATE") == "1":
        return []
    written: list[Path] = []
    for path, content in ((state_path(repo, "console.url"), url),
                          (state_path(repo, "console.pid"), str(os.getpid()))):
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content + "\n")
            written.append(path)
        except OSError as exc:
            print(f"singular console: could not write {path}: {exc}", file=sys.stderr)
    return written


def remove_console_state(paths: list[Path]) -> None:
    for path in paths:
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:
            print(f"singular console: could not remove {path}: {exc}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    repo = Path(args.repo).expanduser()
    if not repo.exists():
        print(f"repo not found: {repo}", file=sys.stderr)
        return 2
    global TARGET_BRANCH
    TARGET_BRANCH = load_repo_target_branch(repo)
    # Resolve the console adapter once at startup (repo > engine-shipped >
    # built-in, per key). With no adapter resolvable this is a no-op and the
    # console behaves exactly as before.
    apply_console_adapter(load_console_adapter(repo, os.environ.get("SINGULAR_ENGINE_HOME")))
    if args.task:
        detail = collect_task_detail(repo, args.task)
        if detail is None:
            print(f"task not found: {args.task}", file=sys.stderr)
            return 3
        print(json.dumps(detail, indent=2))
        return 0
    if args.snapshot:
        print(json.dumps(collect_snapshot(repo), indent=2))
        return 0
    if args.sessions:
        print(json.dumps(slice_sessions(collect_sessions(repo), SESSION_RETURN_LIMIT), indent=2))
        return 0
    if args.session:
        data = read_session(repo, args.session.strip("/"), None, SESSION_LINE_LIMIT_DEFAULT, None, False)
        if data is None:
            print(f"session not found: {args.session}", file=sys.stderr)
            return 3
        print(json.dumps(data, indent=2))
        return 0
    if args.node:
        detail = collect_node_detail(repo, args.node.strip("/"))
        if detail is None:
            print(f"node not found: {args.node}", file=sys.stderr)
            return 3
        print(json.dumps(detail, indent=2))
        return 0
    if args.area:
        detail = collect_area_nodes(repo, args.area.strip("/"))
        if detail is None:
            print(f"area not found: {args.area}", file=sys.stderr)
            return 3
        print(json.dumps(detail, indent=2))
        return 0
    if args.events:
        print(json.dumps(collect_events_overlay(repo, None, OVERLAY_ROW_LIMIT_DEFAULT, None), indent=2))
        return 0
    if args.overview:
        print(json.dumps(collect_overview(repo), indent=2))
        return 0
    if args.dag:
        print(json.dumps(collect_dag_view(repo), indent=2))
        return 0
    if args.timeline:
        print(json.dumps(collect_timeline(repo), indent=2))
        return 0
    if args.config:
        print(json.dumps(collect_config(repo), indent=2))
        return 0
    if args.providers:
        print(json.dumps(collect_providers(repo), indent=2))
        return 0
    if args.prompts:
        print(json.dumps(collect_prompts(repo), indent=2))
        return 0
    if args.prompt:
        data = collect_prompt(repo, args.prompt.strip("/"))
        if data is None:
            print(f"prompt not found: {args.prompt}", file=sys.stderr)
            return 3
        print(json.dumps(data, indent=2))
        return 0
    if args.raw:
        raw_root, sep, raw_name = args.raw.strip("/").partition("/")
        data = collect_raw(repo, raw_root, raw_name) if sep and raw_name else None
        if data is None:
            print(f"raw not found: {args.raw}", file=sys.stderr)
            return 3
        print(json.dumps(data, indent=2))
        return 0
    if args.home:
        print(json.dumps(collect_home(repo), indent=2))
        return 0
    if args.plans:
        print(json.dumps(collect_plans(repo), indent=2))
        return 0
    Handler.repo = repo
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    bound_port = server.server_address[1]
    url = f"http://{args.host}:{bound_port}"
    print(f"singular orchestration console serving {repo} at {url}", flush=True)
    state_files = write_console_state(repo, url)

    def _on_sigterm(signum: int, frame: Any) -> None:
        # Raise so serve_forever unwinds through the finally block (state files
        # are removed) instead of the process dying mid-request.
        raise SystemExit(0)

    try:
        signal.signal(signal.SIGTERM, _on_sigterm)
    except (ValueError, OSError):  # non-main thread / restricted env: best-effort
        pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        remove_console_state(state_files)
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
