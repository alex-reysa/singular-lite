#!/usr/bin/env python3
"""Read-only structured diagnostics and human-gate health summaries."""

from __future__ import annotations

import argparse
from collections import Counter
import collections
import datetime as dt
import json
from pathlib import Path
import re
from typing import Any

from human_gate import validate_gate


CATEGORIES = (
    "product-failure",
    "orchestration-failure",
    "provider-failure",
    "optional-dependency-warning",
    "acknowledged-baseline",
    "infrastructure-inconclusive",
    "info",
)
CATEGORY_ALIASES = {
    "product": "product-failure",
    "orchestration": "orchestration-failure",
    "provider": "provider-failure",
    "optional-dependency": "optional-dependency-warning",
    "infrastructure": "infrastructure-inconclusive",
    "informational": "info",
}
SEVERITIES = {"info", "warning", "error"}
MAX_EVENT_BYTES = 512 * 1024
MAX_EVENT_RECORDS = 500
MAX_DIAGNOSTIC_GROUPS = 50


def _json_record(path: Path) -> tuple[dict[str, Any] | None, str]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, "missing"
    except (OSError, json.JSONDecodeError):
        return None, "corrupt"
    return (value, "ok") if isinstance(value, dict) else (None, "corrupt")


def _blocked_dependencies(task_id: str, tasks: Path, leases: Path) -> list[str]:
    task_path = tasks / f"{task_id}.md"
    try:
        match = re.search(
            r"^Depends on:\s*\[(.*?)\]",
            task_path.read_text(encoding="utf-8"),
            re.M,
        )
    except OSError:
        return []
    declared = re.findall(r"TASK-[0-9]+", match.group(1)) if match else []
    blocked: list[str] = []
    for dependency in declared:
        status = ""
        try:
            status_match = re.search(
                r"^Status:\s*([A-Za-z0-9_-]+)",
                (tasks / f"{dependency}.md").read_text(encoding="utf-8"),
                re.M,
            )
            status = status_match.group(1).lower() if status_match else ""
        except OSError:
            pass
        lease, lease_status = _json_record(leases / f"{dependency}.json")
        if lease_status == "ok" and lease and lease.get("status"):
            status = str(lease["status"]).lower()
        if status != "integrated":
            blocked.append(dependency)
    return blocked


def collect_lifecycle(tasks: Path, state: Path) -> dict[str, Any]:
    """Project lifecycle/candidate authority from durable records without writes."""
    tasks = tasks.resolve()
    state = state.resolve()
    runs_dir = state / "runs"
    leases_dir = state / "leases"
    unknown: list[dict[str, str]] = []
    records: list[dict[str, Any]] = []
    if runs_dir.is_dir():
        for path in sorted(runs_dir.glob("*/run-status.json")):
            data, status = _json_record(path)
            if status != "ok" or not data or data.get("schema") != "singular.orchestration.run-status.v0":
                unknown.append({"kind": "run-status", "record": str(path.relative_to(runs_dir)), "status": "corrupt"})
                continue
            records.append(data)
    records.sort(key=lambda item: str(item.get("updatedAt") or ""), reverse=True)
    active = [item for item in records if item.get("state") in ("active", "waiting")]
    counts = collections.Counter(str(item.get("phase") or "unknown") for item in active)

    candidates: list[dict[str, Any]] = []
    accepted_runs: set[str] = set()
    preserved_history: list[dict[str, Any]] = []
    history_runs: set[str] = set()
    if leases_dir.is_dir():
        for path in sorted(leases_dir.glob("*.json")):
            lease, status = _json_record(path)
            if status != "ok" or lease is None:
                unknown.append({"kind": "lease", "record": path.name, "status": status})
                continue
            candidate = lease.get("acceptedCandidate")
            history = lease.get("candidateHistory")
            if history is not None and not isinstance(history, list):
                unknown.append({"kind": "candidate-history", "record": path.name, "status": "corrupt"})
                history = []
            recovery = lease.get("recoveryAuthorization")
            recovery = recovery if isinstance(recovery, dict) else {}
            task_id = str(lease.get("taskId") or path.stem)
            for historical in history or []:
                if not isinstance(historical, dict):
                    continue
                history_run = str(historical.get("runId") or "")
                if not history_run or (isinstance(candidate, dict) and history_run == candidate.get("runId")):
                    continue
                history_runs.add(history_run)
                failures = [item for item in historical.get("failures", []) if isinstance(item, dict)]
                latest = failures[-1] if failures else {}
                audit, audit_status = _json_record(runs_dir / history_run / "audit.json")
                preserved_history.append({
                    "taskId": task_id, "runId": history_run,
                    "acceptedCandidate": False, "previouslyAccepted": True,
                    "state": historical.get("state"), "phase": None,
                    "headSha": historical.get("headSha"), "treeSha": historical.get("treeSha"),
                    "owner": recovery.get("authorizedBy") or lease.get("owner") or "origin",
                    "failureId": latest.get("failureId"), "failureDomain": latest.get("domain"),
                    "auditVerdict": audit.get("verdict") if audit_status == "ok" and audit else None,
                    "auditStatus": audit_status,
                    "permittedNextAction": lease.get("nextAction") or historical.get("nextAction"),
                    "failureBudgets": lease.get("failureBudgets") if isinstance(lease.get("failureBudgets"), dict) else None,
                })
            if not isinstance(candidate, dict):
                continue
            failures = [item for item in candidate.get("failures", []) if isinstance(item, dict)]
            latest = failures[-1] if failures else {}
            recovery_block = candidate.get("recoveryBlock")
            recovery_block = recovery_block if isinstance(recovery_block, dict) else {}
            run_id = candidate.get("runId")
            if isinstance(run_id, str) and run_id:
                accepted_runs.add(run_id)
            candidates.append({
                "taskId": task_id,
                "acceptedCandidate": True,
                "candidateRunId": run_id,
                "candidateHeadSha": candidate.get("headSha"),
                "candidateTreeSha": candidate.get("treeSha"),
                "state": candidate.get("state"),
                "blockedDependencies": _blocked_dependencies(task_id, tasks, leases_dir),
                "blockedReason": latest.get("failureClass") or recovery_block.get("reason"),
                "failureDomain": latest.get("domain"),
                "failureId": latest.get("failureId"),
                "owner": recovery.get("authorizedBy") or lease.get("owner") or "origin",
                "permittedNextAction": lease.get("nextAction") or candidate.get("nextAction"),
                "recoveryAction": recovery.get("action"),
                "recoveryState": recovery.get("state"),
                "failureBudgets": lease.get("failureBudgets") if isinstance(lease.get("failureBudgets"), dict) else None,
                "failureLimits": lease.get("failureLimits") if isinstance(lease.get("failureLimits"), dict) else None,
            })

    preserved: list[dict[str, Any]] = list(preserved_history)
    terminal_states = {"completed", "failed", "stale", "cancelled"}
    for record in records:
        run_id = str(record.get("runId") or "")
        if not run_id or run_id in accepted_runs or run_id in history_runs or str(record.get("state") or "") not in terminal_states:
            continue
        audit, audit_status = _json_record(runs_dir / run_id / "audit.json")
        preserved.append({
            "taskId": record.get("taskId"),
            "runId": run_id,
            "acceptedCandidate": False,
            "state": record.get("state"),
            "phase": record.get("phase"),
            "headSha": record.get("headSha"),
            "treeSha": record.get("treeSha"),
            "owner": record.get("owner"),
            "auditVerdict": audit.get("verdict") if audit_status == "ok" and audit else None,
            "auditStatus": audit_status,
            "permittedNextAction": record.get("nextAction"),
        })
    return {
        "schema": "singular.orchestration.lifecycle-diagnostics.v1",
        "paths": {"tasks": str(tasks), "state": str(state)},
        "active": active[:50],
        "activeCount": len(active),
        "phaseCounts": dict(sorted(counts.items())),
        "implementersActive": counts.get("implementing", 0),
        "candidates": candidates,
        "preservedAttempts": preserved,
        "unknownRecords": unknown,
        "sources": {
            "runs": "ok" if runs_dir.is_dir() else "missing",
            "leases": "ok" if leases_dir.is_dir() else "missing",
            "tasks": "ok" if tasks.is_dir() else "missing",
        },
    }


def unavailable_lifecycle(
    configuration: dict[str, Any], generation: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Fail-closed lifecycle envelope when durable roots were not resolved."""
    reason = str(configuration.get("reason") or "configuration-unavailable")
    return {
        "schema": "singular.orchestration.lifecycle-diagnostics.v1",
        "configuration": configuration,
        "generation": generation or {},
        "paths": {},
        "active": [],
        "activeCount": 0,
        "phaseCounts": {},
        "implementersActive": 0,
        "candidates": [],
        "preservedAttempts": [],
        "unknownRecords": [{
            "kind": "configuration",
            "record": "startup-resolution",
            "status": reason,
            "restartRequired": bool(configuration.get("restartRequired")),
        }],
        "sources": {"runs": "unknown", "leases": "unknown", "tasks": "unknown"},
    }


def _bounded_text(value: Any, limit: int) -> str:
    return str(value or "")[:limit]


def _read_recent_events(path: Path) -> list[dict[str, Any]]:
    try:
        with path.open("rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            start = max(0, size - MAX_EVENT_BYTES)
            handle.seek(start)
            raw = handle.read()
    except OSError:
        return []
    if start:
        _, _, raw = raw.partition(b"\n")
    records: list[dict[str, Any]] = []
    for line in raw.splitlines()[-MAX_EVENT_RECORDS:]:
        try:
            value = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


def _diagnostic_for_event(event: dict[str, Any]) -> dict[str, Any]:
    event_type = _bounded_text(event.get("type") or "event", 128)
    message = _bounded_text(event.get("message"), 512)
    data = event.get("data") if isinstance(event.get("data"), dict) else {}
    explicit = data.get("diagnostic") if isinstance(data.get("diagnostic"), dict) else {}
    category = CATEGORY_ALIASES.get(
        str(explicit.get("category") or ""), str(explicit.get("category") or "")
    )
    lowered = f"{event_type} {message}".lower()
    if category not in CATEGORIES:
        if "baseline" in lowered:
            category = "acknowledged-baseline"
        elif "optional" in lowered and (
            "mcp" in lowered or "plugin" in lowered or "cache" in lowered
        ):
            category = "optional-dependency-warning"
        elif ".infra" in event_type.lower() or "infrastructure" in lowered:
            category = "infrastructure-inconclusive"
        elif "provider" in lowered and re.search(r"error|fail|invalid|reject", lowered):
            category = "provider-failure"
        elif "product" in lowered or "failed-product" in lowered:
            category = "product-failure"
        elif re.search(r"(?:^|[._])(?:failed|invalid|rejected)(?:[._]|$)", event_type.lower()):
            category = "orchestration-failure"
        else:
            category = "info"
    default_severity = (
        "error"
        if category in {"product-failure", "orchestration-failure", "provider-failure"}
        else "warning"
        if category
        in {
            "optional-dependency-warning",
            "acknowledged-baseline",
            "infrastructure-inconclusive",
        }
        else "info"
    )
    severity = str(explicit.get("severity") or default_severity)
    if severity not in SEVERITIES:
        severity = default_severity
    expected_value = explicit.get("expected")
    expected = (
        expected_value
        if isinstance(expected_value, bool)
        else category == "acknowledged-baseline"
    )
    default_impact = (
        "blocking"
        if severity == "error"
        else "retryable"
        if category == "infrastructure-inconclusive"
        else "non-blocking"
        if severity == "warning"
        else "none"
    )
    source = _bounded_text(
        explicit.get("source")
        or ("provider" if category == "provider-failure" else "orchestrator"),
        128,
    )
    dedupe_key = _bounded_text(
        explicit.get("dedupeKey")
        or f"{category}:{event_type}:{message[:160]}",
        256,
    )
    result = {
        "category": category,
        "severity": severity,
        "expected": expected,
        "impact": _bounded_text(explicit.get("impact") or default_impact, 64),
        "source": source,
        "dedupeKey": dedupe_key,
        "eventType": event_type,
        "message": message,
        "lastAt": event.get("ts"),
    }
    # Diagnostic 2.1 is additive. Preserve explicit evidence qualification so
    # consumers can distinguish a cache/catalog inference from a provider fact.
    for key in ("evidenceStatus", "inventoryProvenance"):
        if isinstance(explicit.get(key), str) and explicit[key]:
            result[key] = _bounded_text(explicit[key], 128)
    if isinstance(explicit.get("providerRejected"), bool):
        result["providerRejected"] = explicit["providerRejected"]
    return result


def collect_diagnostics(events_path: Path) -> dict[str, Any]:
    counts = Counter({category: 0 for category in CATEGORIES})
    groups: dict[str, dict[str, Any]] = {}
    total = 0
    for event in _read_recent_events(events_path):
        diagnostic = _diagnostic_for_event(event)
        total += 1
        counts[diagnostic["category"]] += 1
        key = diagnostic["dedupeKey"]
        if key in groups:
            groups[key]["count"] += 1
            groups[key]["lastAt"] = diagnostic["lastAt"]
            groups[key]["message"] = diagnostic["message"]
        else:
            groups[key] = {**diagnostic, "count": 1}
    items = sorted(
        groups.values(),
        key=lambda item: str(item.get("lastAt") or ""),
        reverse=True,
    )[:MAX_DIAGNOSTIC_GROUPS]
    return {
        "schema": "singular.diagnostics.v2.1",
        "total": total,
        "groups": len(groups),
        "counts": {category: counts[category] for category in CATEGORIES},
        "items": items,
    }


def _descendants(nodes: dict[str, dict[str, Any]], node_id: str) -> list[str]:
    reverse: dict[str, set[str]] = {}
    for candidate_id, node in nodes.items():
        dependencies = node.get("dependsOn")
        if not isinstance(dependencies, list):
            continue
        for dependency in dependencies:
            if isinstance(dependency, str):
                reverse.setdefault(dependency, set()).add(candidate_id)
    found: set[str] = set()
    queue = list(reverse.get(node_id, set()))
    while queue:
        current = queue.pop()
        if current in found:
            continue
        found.add(current)
        queue.extend(reverse.get(current, set()))
    return sorted(found)


def collect_human_gates(
    repo: Path,
    dag_path: Path,
    *,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    errors: list[str] = []
    try:
        dag = json.loads(dag_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        dag = {}
    except (OSError, json.JSONDecodeError) as exc:
        dag = {}
        errors.append(f"invalid DAG: {exc}")
    raw_nodes = dag.get("nodes", []) if isinstance(dag, dict) else []
    nodes = {
        str(node.get("id")): node
        for node in raw_nodes
        if isinstance(node, dict) and isinstance(node.get("id"), str) and node["id"]
    }
    items: list[dict[str, Any]] = []
    for node_id, node in nodes.items():
        config = node.get("humanGate")
        if not isinstance(config, dict):
            continue
        request_ref = config.get("requestRef")
        approval_ref = config.get("approvalRef")
        if not isinstance(request_ref, str) or not isinstance(approval_ref, str):
            result = {
                "node": node_id,
                "state": "invalid",
                "reason": "human-gate references must be non-empty strings",
            }
        else:
            result = validate_gate(
                repo,
                request_ref,
                approval_ref,
                node_id,
                now=now,
            )
        state = str(result.get("state") or "invalid")
        items.append(
            {
                **result,
                "node": node_id,
                "state": state,
                "requestRef": request_ref,
                "approvalRef": approval_ref,
                "blockedNodes": (
                    [] if state == "approved" else _descendants(nodes, node_id)
                ),
            }
        )
    states = Counter(str(item["state"]) for item in items)
    blocked_nodes = sorted(
        {
            node_id
            for item in items
            if item["state"] != "approved"
            for node_id in item["blockedNodes"]
        }
    )
    return {
        "total": len(items),
        "approved": states["approved"],
        "blocking": sum(count for state, count in states.items() if state != "approved"),
        "states": dict(sorted(states.items())),
        "blockedNodes": blocked_nodes,
        "items": items,
        **({"errors": errors} if errors else {}),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--dag", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--tasks", type=Path)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--now")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    now = None
    if args.now:
        now = dt.datetime.fromisoformat(args.now.replace("Z", "+00:00"))
        if now.tzinfo is None:
            raise SystemExit("--now must include a timezone")
        now = now.astimezone(dt.UTC)
    print(
        json.dumps(
            {
                "diagnostics": collect_diagnostics(args.events),
                "humanGates": collect_human_gates(
                    args.repo.resolve(), args.dag, now=now
                ),
                "lifecycle": collect_lifecycle(
                    args.tasks or args.repo / "docs/orchestration/tasks",
                    args.state or args.repo / ".singular-state",
                ),
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
