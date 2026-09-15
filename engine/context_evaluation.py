#!/usr/bin/env python3
"""B5 evaluation: a labeled retrieval harness and a campaign analyser.

Two independent, deterministic surfaces live here.

``evaluate_corpus`` replays a declared labeled corpus through the real B2
context service and reports inclusion/recall inside the byte budget, incorrect
selections, budget omissions and abstentions, then compares them with the
metrics the corpus itself declares. Nothing is inferred: a case either matches
its label or is reported as a failure.

``analyze_campaign`` reads retained orchestration events, runner-result
provider sidecars, host gate reports and the operator intervention log, and
reports integrated/unfinished tasks, retries, review cost, ready-to-dispatch
wait, gate durations, control-plane work and provider counters by role. Every
counter that the retained evidence does not contain is reported as ``unknown``;
it is never defaulted to zero, and cumulative provider tokens are never
presented as context occupancy or as money.

Both surfaces are pure readers. They never write into the state directories
they measure.
"""

from __future__ import annotations

import hashlib
import json
import os
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping

try:
    from engine.context_service import (
        ContextError, ContextOverflow, ContextService,
    )
except ImportError:  # installed execution from engine/
    from context_service import (  # type: ignore
        ContextError, ContextOverflow, ContextService,
    )


CORPUS_SCHEMA = "singular.context.evaluation-corpus.v1"
REPORT_SCHEMA = "singular.context.evaluation-report.v1"
CAMPAIGN_SCHEMA = "singular.context.campaign-analysis.v1"

OPERATIONS = ("search", "get", "build")
OUTCOMES = ("results", "abstention", "refusal")
BUDGET_OMISSION_REASON = "aggregate_byte_budget"
# Review roles at the invocation boundary. `review-target` is the current
# policy name; the two earlier names stay readable in retained events.
REVIEW_ROLES = frozenset({"review-target", "reviewer", "auditor"})

# Comparison keys of `expectedMetrics`; a corpus may declare any subset.
_SCALAR_EXPECTATIONS = (
    "cases", "incorrectSelections", "budgetOmissions", "abstentions",
    "refusals", "resultCases", "failures",
)


class EvaluationError(ValueError):
    """The evaluation inputs are unusable; no metric is reported."""


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 16), b""):
            digest.update(block)
    return "sha256:" + digest.hexdigest()


def _read_json(path: Path, label: str) -> Any:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise EvaluationError(f"{label} is unreadable: {path}: {exc}") from exc
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EvaluationError(f"{label} is not valid UTF-8 JSON: {path}: {exc}") from exc


# ---------------------------------------------------------------------------
# Labeled retrieval corpus
# ---------------------------------------------------------------------------


def load_corpus(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Validate and return the declared labeled corpus."""
    corpus_path = Path(os.path.abspath(path))
    value = _read_json(corpus_path, "evaluation corpus")
    if not isinstance(value, dict):
        raise EvaluationError("evaluation corpus must be a JSON object")
    if value.get("schema") != CORPUS_SCHEMA:
        raise EvaluationError(
            f"evaluation corpus schema must be {CORPUS_SCHEMA!r}; got {value.get('schema')!r}"
        )
    for field in ("project", "configs", "cases", "requiredLabels", "expectedMetrics"):
        if field not in value:
            raise EvaluationError(f"evaluation corpus is missing required field: {field}")
    if not isinstance(value["configs"], dict) or not value["configs"]:
        raise EvaluationError("evaluation corpus configs must be a non-empty object")
    cases = value["cases"]
    if not isinstance(cases, list) or not cases:
        raise EvaluationError("evaluation corpus cases must be a non-empty array")
    identifiers: set[str] = set()
    for index, case in enumerate(cases):
        prefix = f"evaluation corpus case[{index}]"
        if not isinstance(case, dict):
            raise EvaluationError(f"{prefix} must be an object")
        for field in ("id", "label", "operation", "role", "expect"):
            if field not in case:
                raise EvaluationError(f"{prefix} is missing required field: {field}")
        if case["id"] in identifiers:
            raise EvaluationError(f"{prefix} repeats case id {case['id']!r}")
        identifiers.add(case["id"])
        if case["operation"] not in OPERATIONS:
            raise EvaluationError(
                f"{prefix} operation must be one of {'/'.join(OPERATIONS)}"
            )
        expect = case["expect"]
        if not isinstance(expect, dict) or expect.get("outcome") not in OUTCOMES:
            raise EvaluationError(
                f"{prefix} expect.outcome must be one of {'/'.join(OUTCOMES)}"
            )
        config = case.get("config", "default")
        if config not in value["configs"]:
            raise EvaluationError(f"{prefix} names an undeclared config: {config!r}")
    value["corpusPath"] = str(corpus_path)
    return value


def _budget_omissions(payload: Mapping[str, Any]) -> int:
    omissions = payload.get("omissions")
    if not isinstance(omissions, list):
        return 0
    return sum(
        1 for item in omissions
        if isinstance(item, dict) and item.get("reason") == BUDGET_OMISSION_REASON
    )


def _run_case(case: Mapping[str, Any], project: Path, configs: Mapping[str, Path]) -> dict[str, Any]:
    """Execute one labeled case and return its raw observation."""
    config = configs[case.get("config", "default")]
    role = case["role"]
    operation = case["operation"]
    observation: dict[str, Any] = {
        "observedOutcome": "results",
        "observedRefs": [],
        "budgetOmissions": 0,
        "abstained": False,
        "startBytes": [],
        "text": "",
        "reason": None,
    }
    try:
        service = ContextService.from_config(
            config, role=role, phase=case.get("phase"), workspace=project,
        )
        if operation == "search":
            result = service.search(
                case["query"],
                limit=int(case.get("limit", 5)),
                max_bytes=int(case.get("maxBytes", 4000)),
            )
            observation["observedRefs"] = [item["ref"] for item in result["results"]]
            observation["startBytes"] = [
                item["range"]["startByte"] for item in result["results"]
            ]
            observation["text"] = "\n".join(item["excerpt"] for item in result["results"])
            observation["abstained"] = bool(result["abstained"])
            observation["budgetOmissions"] = _budget_omissions(result)
        elif operation == "get":
            result = service.get(
                case["ref"],
                version=case["version"],
                section=case.get("section"),
                start_line=int(case.get("startLine", 1)),
                line_count=case.get("lineCount"),
                max_bytes=int(case.get("maxBytes", 4000)),
                cursor=case.get("cursor"),
            )
            observation["observedRefs"] = [result["ref"]]
            observation["startBytes"] = [result["range"]["startByte"]]
            observation["text"] = result["text"]
        else:
            task = case.get("task", "task.md")
            task_path = Path(task)
            if not task_path.is_absolute():
                task_path = project / task_path
            result = service.build(
                task=task_path,
                phase=case.get("phase") or "evaluate",
                budget_bytes=int(case["budgetBytes"]),
                query=case.get("query"),
            )
            observation["observedRefs"] = [item["ref"] for item in result["provenance"]]
            observation["text"] = result["prompt"]
            observation["budgetOmissions"] = _budget_omissions(result)
            observation["abstained"] = not result["provenance"]
    except (ContextOverflow, ContextError) as exc:
        observation["observedOutcome"] = "refusal"
        observation["reason"] = str(exc)
        return observation
    if observation["abstained"] or not observation["observedRefs"]:
        observation["observedOutcome"] = "abstention"
    return observation


def _score_case(case: Mapping[str, Any], observation: Mapping[str, Any]) -> dict[str, Any]:
    expect = case["expect"]
    must_include = list(expect.get("mustInclude", []))
    must_not_include = list(expect.get("mustNotInclude", []))
    observed = list(observation["observedRefs"])
    found = [ref for ref in must_include if ref in observed]
    incorrect = [ref for ref in must_not_include if ref in observed]
    deviations: list[str] = []

    if observation["observedOutcome"] != expect["outcome"]:
        deviations.append(
            f"expected outcome {expect['outcome']}, observed {observation['observedOutcome']}"
        )
    for ref in must_include:
        if ref not in observed:
            deviations.append(f"expected reference not included: {ref}")
    for ref in incorrect:
        deviations.append(f"incorrect selection: {ref}")
    if "budgetOmissions" in expect and observation["budgetOmissions"] != expect["budgetOmissions"]:
        deviations.append(
            f"expected {expect['budgetOmissions']} budget omissions, "
            f"observed {observation['budgetOmissions']}"
        )
    minimum = expect.get("minStartByte")
    if minimum is not None:
        reachable = [value for value in observation["startBytes"] if value >= minimum]
        if not reachable:
            deviations.append(
                f"no retrieved range starts at or beyond byte {minimum}: "
                f"{observation['startBytes']}"
            )
    for needle in expect.get("mustContain", []):
        if needle not in observation["text"]:
            deviations.append(f"expected text not retrieved: {needle}")
    reason_contains = expect.get("reasonContains")
    if reason_contains is not None:
        if not observation["reason"] or reason_contains not in observation["reason"]:
            deviations.append(
                f"expected refusal reason containing {reason_contains!r}, "
                f"observed {observation['reason']!r}"
            )

    return {
        "id": case["id"],
        "label": case["label"],
        "operation": case["operation"],
        "role": case["role"],
        "config": case.get("config", "default"),
        "query": case.get("query"),
        "expectedOutcome": expect["outcome"],
        "observedOutcome": observation["observedOutcome"],
        "observedRefs": observed,
        "expectedInclusions": len(must_include),
        "includedInclusions": len(found),
        "incorrectSelections": len(incorrect),
        "budgetOmissions": observation["budgetOmissions"],
        "abstained": observation["observedOutcome"] == "abstention",
        "reason": observation["reason"],
        "deviations": deviations,
        "status": "pass" if not deviations else "fail",
    }


def evaluate_corpus(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Replay the labeled corpus and compare it with its declared metrics."""
    corpus = load_corpus(path)
    corpus_path = Path(corpus["corpusPath"])
    root = corpus_path.parent
    project = (root / corpus["project"]).resolve()
    if not project.is_dir():
        raise EvaluationError(f"evaluation corpus project is missing: {project}")
    configs: dict[str, Path] = {}
    for name, relative in corpus["configs"].items():
        candidate = (project / relative).resolve()
        if not candidate.is_file():
            raise EvaluationError(f"evaluation corpus config {name!r} is missing: {candidate}")
        configs[name] = candidate

    scored = [_score_case(case, _run_case(case, project, configs)) for case in corpus["cases"]]

    expected_inclusions = sum(case["expectedInclusions"] for case in scored)
    included_inclusions = sum(case["includedInclusions"] for case in scored)
    coverage = Counter(case["label"] for case in scored)
    missing_labels = sorted(set(corpus["requiredLabels"]) - set(coverage))
    metrics = {
        "cases": len(scored),
        "inclusion": {
            "expected": expected_inclusions,
            "included": included_inclusions,
            "recall": (
                round(included_inclusions / expected_inclusions, 6)
                if expected_inclusions else None
            ),
        },
        "incorrectSelections": sum(case["incorrectSelections"] for case in scored),
        "budgetOmissions": sum(case["budgetOmissions"] for case in scored),
        "abstentions": sum(1 for case in scored if case["observedOutcome"] == "abstention"),
        "refusals": sum(1 for case in scored if case["observedOutcome"] == "refusal"),
        "resultCases": sum(1 for case in scored if case["observedOutcome"] == "results"),
        "failures": sum(1 for case in scored if case["status"] == "fail"),
        "coverage": dict(sorted(coverage.items())),
        "missingLabels": missing_labels,
    }

    expected = corpus["expectedMetrics"]
    deviations: list[str] = []
    for key in _SCALAR_EXPECTATIONS:
        if key in expected and metrics[key] != expected[key]:
            deviations.append(f"{key}: expected {expected[key]}, measured {metrics[key]}")
    declared_inclusion = expected.get("inclusion", {})
    for key in ("expected", "included"):
        if key in declared_inclusion and metrics["inclusion"][key] != declared_inclusion[key]:
            deviations.append(
                f"inclusion.{key}: expected {declared_inclusion[key]}, "
                f"measured {metrics['inclusion'][key]}"
            )
    if missing_labels:
        deviations.append("required labels without a case: " + ", ".join(missing_labels))
    for case in scored:
        for item in case["deviations"]:
            deviations.append(f"{case['id']}: {item}")

    return {
        "schema": REPORT_SCHEMA,
        "status": "ok" if not deviations else "deviated",
        "corpus": {
            "path": str(corpus_path),
            "sha256": _sha256_file(corpus_path),
            "corpusVersion": corpus.get("corpusVersion"),
            "project": str(project),
            "retrievalVersion": "exact-lexical.v1",
        },
        "metrics": metrics,
        "expectedMetrics": expected,
        "matchesExpected": not deviations,
        "deviations": deviations,
        "cases": scored,
        "limitations": [
            "Retrieval is deterministic exact-reference and lexical matching; a "
            "paraphrase below the documented token-coverage threshold abstains "
            "explicitly and is not evidence that the knowledge is absent.",
            "Byte accounting is exact UTF-8 at the host invocation boundary; "
            "provider system content, tool schemas, session history and model "
            "output remain unknown.",
            "These metrics describe this fixed corpus only; they do not "
            "establish general retrieval reliability.",
        ],
    }


# ---------------------------------------------------------------------------
# Campaign analysis
# ---------------------------------------------------------------------------


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _interval(series: Iterable[float]) -> dict[str, Any]:
    values = sorted(series)
    if not values:
        return {
            "observations": 0, "minSeconds": None, "maxSeconds": None,
            "totalSeconds": None, "meanSeconds": None,
        }
    total = round(sum(values), 6)
    return {
        "observations": len(values),
        "minSeconds": round(values[0], 6),
        "maxSeconds": round(values[-1], 6),
        "totalSeconds": total,
        "meanSeconds": round(total / len(values), 6),
    }


def _retained(runs: Path, pattern: str) -> tuple[list[tuple[Path, bytes]], int]:
    """Every retained artifact matching `pattern`, archived copies collapsed.

    The engine keeps a byte-identical copy of each attempt under
    ``attempts/<n>/`` and stages planner/critic invocations one level below the
    run directory. Scanning only the run directory drops the staged work;
    scanning recursively without collapsing identical bytes counts each
    archived attempt twice. Content identity is the only thing that separates
    the two, so it is what this deduplicates on.
    """
    seen: set[str] = set()
    found: list[tuple[Path, bytes]] = []
    duplicates = 0
    # Shallowest first, so the live artifact in the run directory is the one
    # reported and the archived copy below it is the duplicate, not the reverse.
    for path in sorted(runs.rglob(pattern), key=lambda item: (len(item.parts), item.as_posix())):
        try:
            raw = path.read_bytes()
        except OSError:
            continue
        digest = hashlib.sha256(raw).hexdigest()
        if digest in seen:
            duplicates += 1
            continue
        seen.add(digest)
        found.append((path, raw))
    return found, duplicates


def _display(path: Path, base: Path) -> str:
    try:
        return path.relative_to(base).as_posix()
    except ValueError:
        return str(path)


def _input_record(path: Path | None, *, required: bool, label: str) -> dict[str, Any]:
    if path is None:
        return {"path": None, "present": False}
    record: dict[str, Any] = {"path": str(path), "present": path.exists()}
    if not record["present"]:
        if required:
            raise EvaluationError(f"{label} is absent: {path}")
        return record
    if path.is_file():
        record["sha256"] = _sha256_file(path)
        record["bytes"] = path.stat().st_size
    return record


def _load_events(path: Path) -> tuple[list[dict[str, Any]], int, int]:
    events: list[dict[str, Any]] = []
    total = 0
    unparseable = 0
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            total += 1
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                unparseable += 1
                continue
            if isinstance(value, dict):
                events.append(value)
            else:
                unparseable += 1
    return events, total, unparseable


def _event_data(event: Mapping[str, Any]) -> dict[str, Any]:
    data = event.get("data")
    return data if isinstance(data, dict) else {}


def analyze_campaign(
    *,
    events: str | os.PathLike[str],
    runs: str | os.PathLike[str],
    interventions: str | os.PathLike[str] | None = None,
    checkpoint: str | os.PathLike[str] | None = None,
    observations: str | os.PathLike[str] | None = None,
) -> dict[str, Any]:
    """Report measured campaign delivery from retained events and sidecars."""
    events_path = Path(os.path.abspath(events))
    runs_path = Path(os.path.abspath(runs))
    interventions_path = Path(os.path.abspath(interventions)) if interventions else None
    checkpoint_path = Path(os.path.abspath(checkpoint)) if checkpoint else None
    observations_path = Path(os.path.abspath(observations)) if observations else None

    unknowns: list[dict[str, Any]] = []

    inputs: dict[str, Any] = {
        "events": _input_record(events_path, required=True, label="campaign event stream"),
        "runs": _input_record(runs_path, required=True, label="campaign runs directory"),
        "interventions": _input_record(
            interventions_path, required=False, label="operator intervention log"
        ),
        "checkpoint": _input_record(checkpoint_path, required=False, label="rescue checkpoint"),
        "observations": _input_record(
            observations_path, required=False, label="native observation snapshot"
        ),
    }
    if not runs_path.is_dir():
        raise EvaluationError(f"campaign runs directory is not a directory: {runs_path}")
    for name in ("interventions", "checkpoint", "observations"):
        record = inputs[name]
        if record["path"] is not None and not record["present"]:
            unknowns.append({
                "kind": "absent-input",
                "ref": record["path"],
                "detail": f"declared {name} input is absent; its counters stay unknown",
            })

    parsed, total_lines, unparseable = _load_events(events_path)
    inputs["events"]["lines"] = total_lines
    inputs["events"]["unparseableLines"] = unparseable
    if unparseable:
        unknowns.append({
            "kind": "unparseable-event-line",
            "ref": str(events_path),
            "detail": f"{unparseable} retained event line(s) could not be parsed and are excluded",
        })

    counts: Counter[str] = Counter()
    dispatched: set[str] = set()
    integrated: set[str] = set()
    accepted: set[str] = set()
    terminal: set[str] = set()
    verdicts: Counter[str] = Counter()
    review_prompt_bytes = 0
    review_bundles = 0
    reconcile_started: dict[str, datetime] = {}
    dispatch_waits: list[float] = []
    worker_completed: dict[str, datetime] = {}
    gate_waits: list[float] = []
    referenced_sidecars: list[tuple[str, str]] = []
    failed_provider_invocations = 0

    for event in parsed:
        kind = event.get("type")
        if not isinstance(kind, str):
            continue
        counts[kind] += 1
        data = _event_data(event)
        task = data.get("taskId")
        run = data.get("runId")
        when = _parse_timestamp(event.get("ts"))
        if kind in {"origin.dispatch", "l1.dispatch_started"} and isinstance(task, str):
            dispatched.add(task)
        if kind == "integration.integrated" and isinstance(task, str):
            integrated.add(task)
        if kind == "l1.task_accepted" and isinstance(task, str):
            accepted.add(task)
        if kind == "l1.task_terminal" and isinstance(task, str):
            terminal.add(task)
        if kind == "origin.reconcile_started" and isinstance(run, str) and when:
            reconcile_started.setdefault(run, when)
        if kind == "origin.dispatch" and isinstance(run, str) and when:
            started = reconcile_started.get(run)
            if started is not None:
                dispatch_waits.append((when - started).total_seconds())
        if kind == "l1.worker_completed" and isinstance(run, str) and when:
            worker_completed.setdefault(run, when)
        if kind == "gate_check.completed" and isinstance(run, str) and when:
            started = worker_completed.pop(run, None)
            if started is not None:
                gate_waits.append((when - started).total_seconds())
        if kind == "l1.audit_completed":
            verdict = data.get("verdict")
            verdicts[verdict if isinstance(verdict, str) else "unknown"] += 1
        if kind == "context.bundle_selected" and data.get("role") in REVIEW_ROLES:
            prompt_bytes = data.get("promptBytes")
            if isinstance(prompt_bytes, int) and not isinstance(prompt_bytes, bool):
                review_prompt_bytes += prompt_bytes
                review_bundles += 1
        if kind == "runner.completed":
            failure = data.get("failureClass")
            if isinstance(failure, str) and failure not in {"", "none"}:
                failed_provider_invocations += 1
            reference = data.get("runnerResultRef")
            role = data.get("role")
            if isinstance(reference, str) and reference:
                referenced_sidecars.append(
                    (reference, role if isinstance(role, str) and role else "unknown")
                )

    # Provider counters come from the retained sidecars themselves, which carry
    # the raw identity; the events only tell us which sidecars were expected.
    display_base = runs_path.parent
    usage: dict[str, dict[str, Any]] = {}

    def role_bucket(role: str) -> dict[str, Any]:
        return usage.setdefault(role, {
            "sidecars": 0, "sidecarsWithUsage": 0, "sidecarsWithoutUsage": 0,
            "observedInputTokens": 0, "observedCachedInputTokens": 0,
            "observedOutputTokens": 0, "referencedSidecarsMissing": 0,
            "byProvider": {},
        })

    def provider_bucket(bucket: dict[str, Any], provider: str) -> dict[str, Any]:
        return bucket["byProvider"].setdefault(provider, {
            "sidecars": 0, "sidecarsWithUsage": 0, "sidecarsWithoutUsage": 0,
            "observedInputTokens": 0, "observedCachedInputTokens": 0,
            "observedOutputTokens": 0,
        })

    sidecars, duplicate_sidecars = _retained(runs_path, "*runner-result.json")
    inputs["runs"]["sidecars"] = len(sidecars)
    inputs["runs"]["archivedDuplicateSidecars"] = duplicate_sidecars
    for sidecar, raw_sidecar in sidecars:
        try:
            record = json.loads(raw_sidecar.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            unknowns.append({
                "kind": "runner-result-without-usage",
                "ref": _display(sidecar, display_base),
                "detail": "runner-result sidecar is unreadable; its counters stay unknown",
            })
            continue
        if not isinstance(record, dict):
            continue
        role = record.get("role")
        provider = record.get("provider")
        bucket = role_bucket(role if isinstance(role, str) and role else "unknown")
        provider_counters = provider_bucket(
            bucket, provider if isinstance(provider, str) and provider else "unknown"
        )
        bucket["sidecars"] += 1
        provider_counters["sidecars"] += 1
        counters = record.get("usage")
        if not isinstance(counters, dict):
            bucket["sidecarsWithoutUsage"] += 1
            provider_counters["sidecarsWithoutUsage"] += 1
            unknowns.append({
                "kind": "runner-result-without-usage",
                "ref": _display(sidecar, display_base),
                "detail": "retained provider sidecar carries no usage counters; unknown, not zero",
            })
            continue
        bucket["sidecarsWithUsage"] += 1
        provider_counters["sidecarsWithUsage"] += 1
        for field, key in (
            ("inputTokens", "observedInputTokens"),
            ("cachedInputTokens", "observedCachedInputTokens"),
            ("outputTokens", "observedOutputTokens"),
        ):
            value = counters.get(field)
            if isinstance(value, int) and not isinstance(value, bool):
                bucket[key] += value
                provider_counters[key] += value

    for reference, role in sorted(set(referenced_sidecars)):
        candidate = Path(reference)
        if not candidate.is_absolute():
            candidate = events_path.parent / candidate
        if candidate.exists():
            continue
        bucket = role_bucket(role)
        bucket["referencedSidecarsMissing"] += 1
        unknowns.append({
            "kind": "missing-runner-result-sidecar",
            "ref": reference,
            "detail": "an event references a provider sidecar that is not retained; unknown, not zero",
        })

    for role, bucket in sorted(usage.items()):
        if bucket["sidecarsWithUsage"] == 0:
            bucket["observedInputTokens"] = None
            bucket["observedCachedInputTokens"] = None
            bucket["observedOutputTokens"] = None
        bucket["byProvider"] = dict(sorted(bucket["byProvider"].items()))
        bucket["providers"] = sorted(bucket["byProvider"])
        # Providers do not agree on what `cachedInputTokens` means: some report
        # it as a subset of `inputTokens`, others as a separate cache-read
        # counter. A role spanning several providers therefore has a per-role
        # sum whose units are not comparable; the per-provider split below is
        # the measured figure, and the role total is flagged here rather than
        # quietly presented as one number.
        if len(bucket["providers"]) > 1:
            unknowns.append({
                "kind": "mixed-provider-token-semantics",
                "ref": f"providerUsageByRole.{role}",
                "detail": (
                    "this role spans providers " + ", ".join(bucket["providers"]) +
                    "; cached-input semantics differ between them, so the role total "
                    "is not a comparable quantity — read byProvider instead"
                ),
            })

    gate_by_kind: dict[str, dict[str, Any]] = {}
    gate_reports, duplicate_gate_reports = _retained(runs_path, "gate-check.json")
    inputs["runs"]["gateReports"] = len(gate_reports)
    inputs["runs"]["archivedDuplicateGateReports"] = duplicate_gate_reports
    for report, raw_report in gate_reports:
        try:
            record = json.loads(raw_report.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            unknowns.append({
                "kind": "unparseable-event-line",
                "ref": _display(report, display_base),
                "detail": "gate report is unreadable; its duration stays unknown",
            })
            continue
        if not isinstance(record, dict):
            continue
        duration = record.get("durationMs")
        if not isinstance(duration, int) or isinstance(duration, bool):
            continue
        kind = record.get("workspaceKind")
        bucket = gate_by_kind.setdefault(
            kind if isinstance(kind, str) and kind else "unknown",
            {"observations": 0, "totalMs": 0, "minMs": duration, "maxMs": duration},
        )
        bucket["observations"] += 1
        bucket["totalMs"] += duration
        bucket["minMs"] = min(bucket["minMs"], duration)
        bucket["maxMs"] = max(bucket["maxMs"], duration)

    accepted_reviews = verdicts.get("accepted", 0)
    bytes_per_accepted_review = (
        round(review_prompt_bytes / accepted_reviews, 6) if accepted_reviews else None
    )
    # Context bundles were only recorded from B3 onward, so an older accepted
    # review can have no retained bundle at all. Say so instead of dividing
    # partial bytes by a complete review count and calling it a rate.
    review_coverage_complete = accepted_reviews > 0 and review_bundles >= accepted_reviews
    if bytes_per_accepted_review is None:
        unknowns.append({
            "kind": "review-context-coverage",
            "ref": str(events_path),
            "detail": "no accepted review is retained, so bytes per accepted review is unknown",
        })
    elif not review_coverage_complete:
        unknowns.append({
            "kind": "review-context-coverage",
            "ref": str(events_path),
            "detail": (
                f"{review_bundles} retained review context bundle(s) cover "
                f"{accepted_reviews} accepted review(s); bytes per accepted review is a "
                "lower bound over the covered subset, not a complete rate"
            ),
        })

    if interventions_path is not None and interventions_path.is_file():
        records = 0
        during = 0
        rescues = 0
        credited = 0
        with interventions_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    unknowns.append({
                        "kind": "unparseable-event-line",
                        "ref": str(interventions_path),
                        "detail": "an intervention record could not be parsed and is excluded",
                    })
                    continue
                if not isinstance(entry, dict):
                    continue
                records += 1
                if entry.get("duringQualifyingSequence") is True:
                    during += 1
                if entry.get("rescuesOrAdvancesRequiredTransition") is True or \
                        entry.get("rescuesRequiredTransition") is True:
                    rescues += 1
                if entry.get("unattendedCredit") is True or \
                        entry.get("nativeCredit") is True:
                    credited += 1
        intervention_counts: dict[str, Any] = {
            "records": records,
            "duringQualifyingSequence": during,
            "rescuesOrAdvancesRequiredTransition": rescues,
            "unattendedCredit": credited,
        }
    else:
        intervention_counts = {
            "records": None,
            "duringQualifyingSequence": None,
            "rescuesOrAdvancesRequiredTransition": None,
            "unattendedCredit": None,
        }

    unknowns.extend([
        {
            "kind": "provider-monetary-cost",
            "ref": None,
            "detail": "retained sidecars record token counters only; monetary cost is unknown",
        },
        {
            "kind": "provider-served-tier",
            "ref": None,
            "detail": "requested speed is recorded; the provider-observed service tier is not",
        },
        {
            "kind": "context-occupancy",
            "ref": None,
            "detail": (
                "input and cached input are cumulative provider invocation counters, "
                "not context occupancy or unique source bytes"
            ),
        },
    ])

    return {
        "schema": CAMPAIGN_SCHEMA,
        "inputs": inputs,
        "tasks": {
            "dispatched": sorted(dispatched),
            "integrated": sorted(integrated),
            "accepted": sorted(accepted),
            "terminalWithoutAcceptance": sorted(terminal),
            "unfinished": sorted(dispatched - integrated),
        },
        "retries": {
            "workerInfraRetries": counts.get("worker.infra_retry", 0),
            "evidenceInfraRetries": counts.get("evidence.infra_retry", 0),
            "attemptsArchived": counts.get("l1.attempt_archived", 0),
            "reservationRefusals": counts.get("origin.reservation_refused", 0),
            "productRepairConsumed": counts.get("l1.product_repair_budget_consumed", 0),
            "failedProviderInvocations": failed_provider_invocations,
        },
        "readyToDispatchWaitSeconds": dict(_interval(dispatch_waits), definition=(
            "elapsed time from the origin reconcile that admitted the task to the "
            "origin.dispatch event of the same origin run"
        )),
        "gateDurations": {
            "byWorkspaceKind": dict(sorted(gate_by_kind.items())),
            "workerCompletedToGateCompletedSeconds": dict(_interval(gate_waits), definition=(
                "elapsed time from l1.worker_completed to gate_check.completed in the same run"
            )),
        },
        "controlPlane": {
            "reconcileStarted": counts.get("origin.reconcile_started", 0),
            "reconcileCompleted": counts.get("origin.reconcile_completed", 0),
            "controlStateCommitted": counts.get("origin.control_state_committed", 0),
            "controlStateDeferred": counts.get("origin.control_state_deferred", 0),
            "recoveryActions": counts.get("recovery.action", 0),
            "campaignMismatches": counts.get("integration.campaign_mismatch", 0),
            "reservationRefusals": counts.get("origin.reservation_refused", 0),
        },
        "reviews": {
            "verdicts": dict(sorted(verdicts.items())),
            "acceptedReviews": accepted_reviews,
            "reviewContextBundles": review_bundles,
            "reviewContextPromptBytes": review_prompt_bytes,
            "bytesPerAcceptedReview": bytes_per_accepted_review,
            "reviewContextCoverageComplete": review_coverage_complete,
            "definition": (
                "host-composed review context prompt bytes divided by accepted reviews; "
                "provider-side prompt composition is not included"
            ),
        },
        "providerUsageByRole": dict(sorted(usage.items())),
        "interventions": intervention_counts,
        "eventCounts": dict(sorted(counts.items())),
        "unknowns": unknowns,
        "limitations": [
            "Failed, superseded and setup work is included; these are observed "
            "counters of the retained stream, not total project usage.",
            "Operator interventions are counted separately and never credited as "
            "uninterrupted native delivery.",
            "Cumulative provider tokens are neither context occupancy nor money.",
        ],
    }
