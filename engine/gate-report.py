#!/usr/bin/env python3
"""Create and verify hash-bound Singular gate reports."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
from typing import Any

import infra_patterns


PRODUCT_PATTERNS = (
    ("assertion", re.compile(r"\b(assertionerror|assertion failed|expected .+ (?:to|but)|received:)\b", re.I)),
    (
        "test-failure",
        re.compile(
            r"(?:^|\n)\s*(?:not ok\b|FAIL(?:\s+\S|:))|\btests?\s+failed\b|\btest suite failed\b",
            re.I,
        ),
    ),
    ("compile-error", re.compile(r"\b(?:syntaxerror|typeerror:|compilation failed|build failed)\b", re.I)),
)

# Loaded from engine/infra-patterns.tsv through the shared module, so the v2
# normalizer in gate_report.py classifies with exactly the same table. It used
# to be a tuple literal here, in a module the v2 path never imports, which made
# infrastructure detection dead code for every current consumer.
INFRA_PATTERNS = infra_patterns.load(infra_patterns.ALL)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
HEX_RE = re.compile(r"\b[0-9a-f]{8,}\b", re.I)
NUMBER_RE = re.compile(r"\b\d+\b")


def sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def evidence_binding(report: dict[str, Any]) -> str:
    bound = {
        "headSha": report.get("headSha"),
        "commandSha256": report.get("commandSha256"),
        "rawExitCode": report.get("rawExitCode"),
        "logSha256": report.get("logSha256"),
        "outcome": report.get("outcome"),
        "baselineSha256": report.get("baselineSha256", ""),
    }
    return sha_bytes(
        json.dumps(bound, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def normalized_signature(text: str) -> tuple[str, str]:
    for raw in text.splitlines():
        line = ANSI_RE.sub("", raw).strip()
        if not line:
            continue
        if any(pattern.search(line) for _, pattern in PRODUCT_PATTERNS):
            normalized = " ".join(line.lower().split())
            normalized = HEX_RE.sub("<hex>", normalized)
            normalized = NUMBER_RE.sub("<n>", normalized)
            return sha_bytes(normalized.encode("utf-8")), line[:240]
    normalized = "gate command exited nonzero"
    return sha_bytes(normalized.encode("utf-8")), normalized


def classify(
    exit_code: int,
    text: str,
    integrity_status: str,
    setup_errors: list[str],
) -> tuple[str, list[str], list[str]]:
    product = [name for name, pattern in PRODUCT_PATTERNS if pattern.search(text)]
    infrastructure = [name for name, pattern in INFRA_PATTERNS if pattern.search(text)]
    infrastructure.extend(
        "host-required:" + match.group(1) + ":unrun"
        for match in re.finditer(r"(?:^|\n)HOST_REQUIRED\s+(\S+)\s+unrun(?:\n|$)", text)
    )
    infrastructure.extend(error for error in setup_errors if error)
    if integrity_status == "violation":
        infrastructure.append("source-integrity-violation")
        return "inconclusive-infrastructure", product, sorted(set(infrastructure))
    if setup_errors:
        return "inconclusive-infrastructure", product, sorted(set(infrastructure))
    # An explicit HOST_REQUIRED marker is a statement that the aggregate is
    # incomplete, even when every body that could run exited zero. Keep that
    # result unavailable to evidence consumers instead of letting the process
    # exit status erase the host-owned pending check.
    if any(item.startswith("host-required:") for item in infrastructure):
        return "inconclusive-infrastructure", product, sorted(set(infrastructure))
    if exit_code == 0:
        return "passed", product, sorted(set(infrastructure))
    # A genuine assertion/build failure remains a product failure even if the
    # same log also contains an unrelated infrastructure warning.
    if product:
        return "failed-product", sorted(set(product)), sorted(set(infrastructure))
    if infrastructure:
        return "inconclusive-infrastructure", [], sorted(set(infrastructure))
    # A bare terminal status is not product evidence. Timeouts, signals, missing
    # executables, and other host-side termination paths can all produce a
    # non-zero code without an assertion. Only a recognizable product signal
    # above may turn raw output into failed-product.
    if exit_code in {124, 137, 143}:
        return "inconclusive-infrastructure", [], ["gate-command-timeout"]
    return (
        "inconclusive-infrastructure",
        [],
        [f"unknown-terminal-exit:{exit_code}"],
    )


def valid_head(value: str) -> str:
    value = value.strip().lower()
    return value if re.fullmatch(r"[0-9a-f]{40,64}", value) else "0" * 40


def atomic_json(path: pathlib.Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


REQUEST_FIELDS = {
    "schema", "taskId", "runId", "attempt", "headSha", "treeSha",
    "campaignBinding", "taskContractPath", "taskContractSha256",
    "policyContractPath", "policyContractSha256", "suiteId",
    "commandIdentity", "requestIdentity", "createdAt",
}


def trusted_gate_command(task_contract: pathlib.Path) -> str:
    text = task_contract.read_text(encoding="utf-8")
    match = re.search(r"^Gate command:\s*`([^`]+)`\s*$", text, re.MULTILINE)
    if not match or not match.group(1).strip():
        raise ValueError("trusted task contract has no Gate command")
    return match.group(1).strip()


def request_binding(request: dict[str, Any]) -> str:
    return sha_bytes(json.dumps(
        {key: request.get(key) for key in sorted(REQUEST_FIELDS - {"requestIdentity", "createdAt"})},
        sort_keys=True, separators=(",", ":"),
    ).encode("utf-8"))


def load_verification_request(
    request_path: pathlib.Path,
    task_contract: pathlib.Path,
    policy_contract: pathlib.Path,
) -> tuple[dict[str, Any], str]:
    request = json.loads(request_path.read_text(encoding="utf-8"))
    if not isinstance(request, dict):
        raise ValueError("verification request is not an object")
    unexpected = sorted(set(request) - REQUEST_FIELDS)
    missing = sorted(REQUEST_FIELDS - set(request))
    if unexpected:
        raise ValueError("verification request contains unsupported fields: " + ", ".join(unexpected))
    if missing:
        raise ValueError("verification request missing: " + ", ".join(missing))
    if request.get("schema") != "singular.orchestration.verification-request.v0":
        raise ValueError("unsupported verification request schema")
    if not isinstance(request.get("attempt"), int) or isinstance(request.get("attempt"), bool):
        raise ValueError("verification request attempt is invalid")
    if request.get("taskContractSha256") != sha_bytes(task_contract.read_bytes()):
        raise ValueError("verification task contract changed")
    if request.get("policyContractSha256") != sha_bytes(policy_contract.read_bytes()):
        raise ValueError("verification policy contract changed")
    try:
        policy = json.loads(policy_contract.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"verification policy contract is malformed: {exc}") from exc
    if not isinstance(policy, dict):
        raise ValueError("verification policy contract is not an object")
    trusted_campaign = str(policy.get("campaign", ""))
    if trusted_campaign and request.get("campaignBinding") != trusted_campaign:
        raise ValueError("verification request campaign does not match trusted policy")
    if pathlib.Path(str(request.get("taskContractPath"))).resolve() != task_contract.resolve():
        raise ValueError("verification task contract path mismatch")
    if pathlib.Path(str(request.get("policyContractPath"))).resolve() != policy_contract.resolve():
        raise ValueError("verification policy contract path mismatch")
    command = trusted_gate_command(task_contract)
    if request.get("commandIdentity") != sha_bytes(command.encode("utf-8")):
        raise ValueError("trusted verification command identity changed")
    if request.get("requestIdentity") != request_binding(request):
        raise ValueError("verification request binding mismatch")
    if valid_head(str(request.get("headSha", ""))) != request.get("headSha"):
        raise ValueError("verification request head is invalid")
    if valid_head(str(request.get("treeSha", ""))) != request.get("treeSha"):
        raise ValueError("verification request tree is invalid")
    return request, command


def command_create_verification_request(args: argparse.Namespace) -> int:
    task_contract = pathlib.Path(args.task_contract).resolve()
    policy_contract = pathlib.Path(args.policy_contract).resolve()
    command = trusted_gate_command(task_contract)
    head_sha = valid_head(args.head_sha)
    tree_sha = valid_head(args.tree_sha)
    if head_sha != args.head_sha.strip() or tree_sha != args.tree_sha.strip():
        raise ValueError("verification request requires exact lowercase commit/tree identities")
    request: dict[str, Any] = {
        "schema": "singular.orchestration.verification-request.v0",
        "taskId": args.task_id,
        "runId": args.run_id,
        "attempt": args.attempt,
        "headSha": head_sha,
        "treeSha": tree_sha,
        "campaignBinding": args.campaign,
        "taskContractPath": str(task_contract),
        "taskContractSha256": sha_bytes(task_contract.read_bytes()),
        "policyContractPath": str(policy_contract),
        "policyContractSha256": sha_bytes(policy_contract.read_bytes()),
        "suiteId": args.suite_id,
        "commandIdentity": sha_bytes(command.encode("utf-8")),
        "createdAt": utc_now(),
    }
    request["requestIdentity"] = request_binding(request)
    atomic_json(pathlib.Path(args.output), request)
    print(request["requestIdentity"])
    return 0


def command_resolve_verification_request(args: argparse.Namespace) -> int:
    request, command = load_verification_request(
        pathlib.Path(args.request), pathlib.Path(args.task_contract), pathlib.Path(args.policy_contract)
    )
    if args.expected_task and request.get("taskId") != args.expected_task:
        raise ValueError("verification request task mismatch")
    print(command)
    return 0


def result_binding(report: dict[str, Any]) -> str:
    request = report.get("verificationRequest") or {}
    bound = {
        "requestIdentity": request.get("requestIdentity"),
        "taskId": report.get("taskId"), "headSha": report.get("headSha"),
        "commandSha256": report.get("commandSha256"), "outcome": report.get("outcome"),
        "rawExitCode": report.get("rawExitCode"), "logSha256": report.get("logSha256"),
        "evidenceBindingSha256": report.get("evidenceBindingSha256"),
        "evidenceSourceCommandIdentity": report.get("evidenceSourceCommandIdentity"),
        "evidenceSourceOutcome": report.get("evidenceSourceOutcome"),
    }
    return sha_bytes(json.dumps(bound, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def command_bind_verification_result(args: argparse.Namespace) -> int:
    request, command = load_verification_request(
        pathlib.Path(args.request), pathlib.Path(args.task_contract), pathlib.Path(args.policy_contract)
    )
    path = pathlib.Path(args.report)
    report = json.loads(path.read_text(encoding="utf-8"))
    if report.get("taskId") != request.get("taskId"):
        raise ValueError("verification result task mismatch")
    if report.get("headSha") != request.get("headSha"):
        raise ValueError("verification result head mismatch")
    evidence_source_command = str(args.evidence_source_command or "")
    if evidence_source_command:
        if not report.get("evidenceOnly") or report.get("outcome") != "not-rerun-evidence-verified":
            raise ValueError("verification evidence substitution is not evidence-only")
        if report.get("command") != evidence_source_command or report.get("commandSha256") != sha_bytes(
            evidence_source_command.encode("utf-8")
        ):
            raise ValueError("verification evidence source command mismatch")
        report["evidenceSourceCommandIdentity"] = report["commandSha256"]
    elif report.get("commandSha256") != sha_bytes(command.encode("utf-8")):
        raise ValueError("verification result command mismatch")
    report["verificationRequest"] = {
        key: request[key] for key in (
            "requestIdentity", "runId", "attempt", "headSha", "treeSha",
            "campaignBinding", "taskContractSha256", "policyContractSha256",
            "suiteId", "commandIdentity",
        )
    }
    report["verificationResultBindingSha256"] = result_binding(report)
    atomic_json(path, report)
    return 0


def command_verify_verification_result(args: argparse.Namespace) -> int:
    request, command = load_verification_request(
        pathlib.Path(args.request), pathlib.Path(args.task_contract), pathlib.Path(args.policy_contract)
    )
    report_path = pathlib.Path(args.report)
    try:
        raw_report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"verification result unreadable: {exc}") from exc
    evidence_only = bool(raw_report.get("evidenceOnly"))
    expected_command = str(raw_report.get("command", "")) if evidence_only else command
    report, reason = load_verified_evidence(
        report_path, request["headSha"], expected_command, allow_evidence_only=evidence_only
    )
    if report is None:
        raise ValueError(reason)
    expected = {
        key: request[key] for key in (
            "requestIdentity", "runId", "attempt", "headSha", "treeSha",
            "campaignBinding", "taskContractSha256", "policyContractSha256",
            "suiteId", "commandIdentity",
        )
    }
    if report.get("verificationRequest") != expected:
        raise ValueError("verification result request binding mismatch")
    if evidence_only and report.get("evidenceSourceCommandIdentity") != report.get("commandSha256"):
        raise ValueError("verification evidence source command binding mismatch")
    if report.get("verificationResultBindingSha256") != result_binding(report):
        raise ValueError("verification result binding mismatch")
    return 0


def command_create(args: argparse.Namespace) -> int:
    log = pathlib.Path(args.log).resolve()
    try:
        raw = log.read_bytes()
    except OSError:
        raw = b""
        args.setup_error.append("gate-log-missing")
    text = raw.decode("utf-8", errors="replace")
    outcome, product, infrastructure = classify(
        args.exit_code, text, args.integrity_status, args.setup_error
    )
    unexpected: list[dict[str, str]] = []
    if outcome == "failed-product":
        signature, title = normalized_signature(text)
        unexpected.append({"signature": signature, "title": title})
    report: dict[str, Any] = {
        "schema": "singular.orchestration.gate-report.v0",
        "taskId": args.task_id,
        "runId": args.run_id,
        "headSha": valid_head(args.head_sha),
        "command": args.command,
        "commandSha256": sha_bytes(args.command.encode("utf-8")),
        "outcome": outcome,
        "expectedFailures": [],
        "unexpectedFailures": unexpected,
        "resolvedExpectedFailures": [],
        "rawExitCode": args.exit_code,
        "logRef": getattr(args, "log_ref", None) or str(log),
        "logPath": str(log),
        "logSha256": sha_bytes(raw),
        "logBytes": len(raw),
        "durationMs": max(0, args.duration_ms),
        "phase": args.phase,
        "workspaceKind": args.workspace_kind,
        "evidenceOnly": False,
        "sourceIntegrity": {
            "status": args.integrity_status,
            "changedPaths": sorted(set(args.changed_path)),
        },
        "failureSignals": product,
        "infrastructureSignals": infrastructure,
        "recordedAt": utc_now(),
    }
    report["evidenceBindingSha256"] = evidence_binding(report)
    atomic_json(pathlib.Path(args.output), report)
    return {"passed": 0, "failed-product": 10, "inconclusive-infrastructure": 20}[outcome]


def load_verified_evidence(
    report_path: pathlib.Path, expected_head: str, expected_command: str,
    *, allow_evidence_only: bool = False,
) -> tuple[dict[str, Any] | None, str]:
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"gate report unreadable: {exc}"
    required = {
        "schema",
        "taskId",
        "runId",
        "headSha",
        "command",
        "commandSha256",
        "evidenceBindingSha256",
        "outcome",
        "rawExitCode",
        "logRef",
        "logSha256",
    }
    missing = sorted(required - set(report))
    if missing:
        return None, "gate report missing: " + ", ".join(missing)
    if report.get("schema") != "singular.orchestration.gate-report.v0":
        return None, "unsupported gate report schema"
    if report.get("headSha") != valid_head(expected_head):
        return None, "gate report head mismatch"
    if report.get("command") != expected_command:
        return None, "gate report command mismatch"
    if report.get("commandSha256") != sha_bytes(expected_command.encode("utf-8")):
        return None, "gate report command hash mismatch"
    successful_outcomes = {"passed", "passed-with-acknowledged-baseline"}
    if allow_evidence_only:
        successful_outcomes.add("not-rerun-evidence-verified")
    if report.get("outcome") not in successful_outcomes:
        return None, "gate report is not successful evidence"
    raw_exit_code = report.get("rawExitCode")
    if not isinstance(raw_exit_code, int) or isinstance(raw_exit_code, bool):
        return None, "gate report exit code is invalid"
    unexpected = report.get("unexpectedFailures", [])
    expected = report.get("expectedFailures", [])
    if not isinstance(unexpected, list) or not isinstance(expected, list):
        return None, "gate report failure lists are invalid"
    if unexpected:
        return None, "successful gate report contains unexpected failures"
    source_outcome = report.get("evidenceSourceOutcome") if report.get("outcome") == "not-rerun-evidence-verified" else report.get("outcome")
    if source_outcome == "passed" and raw_exit_code != 0:
        return None, "passed gate report has a nonzero exit code"
    if (
        source_outcome == "passed-with-acknowledged-baseline"
        and not expected
    ):
        return None, "acknowledged gate report contains no expected failures"
    if source_outcome not in {"passed", "passed-with-acknowledged-baseline"}:
        return None, "evidence-only report has an invalid source outcome"
    source_integrity = report.get("sourceIntegrity")
    if (
        not isinstance(source_integrity, dict)
        or source_integrity.get("status") != "verified"
    ):
        return None, "successful gate report lacks verified source integrity"
    binding = report.get("evidenceBindingSha256")
    if binding != evidence_binding(report):
        return None, "gate report evidence binding mismatch"
    # logPath (0.15.1) is the absolute filesystem location. logRef is a
    # REPOSITORY-relative citation for dag.sh, and this resolver anchors a
    # relative ref at the REPORT'S OWN DIRECTORY -- a third, incompatible base.
    # Reading logRef here would look for
    # .singular-state/runs/RUN-x/.singular-state/runs/RUN-x/gate-check.log,
    # fail, and surface as an unreadable gate log -> audit-infra -> a parked
    # task, for a gate that actually passed.
    log = pathlib.Path(str(report.get("logPath") or report.get("logRef", "")))
    if not log.is_absolute():
        log = (report_path.parent / log).resolve()
    try:
        raw = log.read_bytes()
    except OSError as exc:
        return None, f"gate log unreadable: {exc}"
    if sha_bytes(raw) != report.get("logSha256"):
        return None, "gate log hash mismatch"
    baseline_ref = report.get("baselineRef")
    baseline_sha = report.get("baselineSha256")
    if bool(baseline_ref) != bool(baseline_sha):
        return None, "gate report baseline binding is incomplete"
    if source_outcome == "passed-with-acknowledged-baseline" and not baseline_ref:
        return None, "acknowledged gate report is missing its baseline binding"
    if baseline_ref:
        baseline_path = pathlib.Path(str(baseline_ref))
        if not baseline_path.is_absolute():
            baseline_path = (report_path.parent / baseline_path).resolve()
        try:
            baseline_raw = baseline_path.read_bytes()
            baseline = json.loads(baseline_raw)
        except (OSError, json.JSONDecodeError) as exc:
            return None, f"gate baseline unreadable: {exc}"
        if sha_bytes(baseline_raw) != baseline_sha:
            return None, "gate baseline hash mismatch"
        if (
            not isinstance(baseline, dict)
            or baseline.get("schema") != "singular.orchestration.gate-baseline.v0"
        ):
            return None, "gate baseline schema mismatch"
        if baseline.get("commandSha256") != report.get("commandSha256"):
            return None, "gate baseline command hash mismatch"
    return report, ""


def command_bind(args: argparse.Namespace) -> int:
    path = pathlib.Path(args.report)
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"gate-report: cannot bind invalid report: {exc}", file=sys.stderr)
        return 2
    report["headSha"] = valid_head(args.head_sha)
    if args.task_id:
        report["taskId"] = args.task_id
    report["evidenceBindingSha256"] = evidence_binding(report)
    atomic_json(path, report)
    return 0


def command_verify(args: argparse.Namespace) -> int:
    _, reason = load_verified_evidence(
        pathlib.Path(args.report), args.expected_head, args.expected_command
    )
    if reason:
        print(reason, file=sys.stderr)
        return 4
    return 0


def command_copy_evidence(args: argparse.Namespace) -> int:
    source_path = pathlib.Path(args.report)
    report, reason = load_verified_evidence(
        source_path, args.expected_head, args.expected_command
    )
    if report is None:
        print(reason, file=sys.stderr)
        return 4
    report = dict(report)
    report["evidenceSourceOutcome"] = report["outcome"]
    report["outcome"] = "not-rerun-evidence-verified"
    report["phase"] = "audit-verification"
    report["workspaceKind"] = "evidence-only"
    report["evidenceOnly"] = True
    report["durationMs"] = 0
    report["sourceIntegrity"] = {"status": "verified", "changedPaths": []}
    report["infrastructureSignals"] = []
    report["failureSignals"] = []
    report["recordedAt"] = utc_now()
    report["evidenceBindingSha256"] = evidence_binding(report)
    atomic_json(pathlib.Path(args.output), report)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="subcommand", required=True)

    create = commands.add_parser("create")
    create.add_argument("--output", required=True)
    create.add_argument("--task-id", required=True)
    create.add_argument("--run-id", required=True)
    create.add_argument("--head-sha", required=True)
    create.add_argument("--command", required=True)
    create.add_argument("--exit-code", required=True, type=int)
    create.add_argument("--log", required=True)
    # The citation written into the report. `--log` stays the file that gets
    # opened and hashed; without this split the report's logRef was
    # .resolve()d — absolute AND symlink-dereferenced, both of which
    # dag.sh's safe_repo_artifact refuses — so the fallback path would have
    # reintroduced an unvalidatable ref on exactly the error path.
    create.add_argument("--log-ref")
    create.add_argument("--duration-ms", type=int, default=0)
    create.add_argument(
        "--phase", choices=("worker", "audit-verification", "integration", "other"), default="other"
    )
    create.add_argument(
        "--workspace-kind",
        choices=("worker", "disposable", "evidence-only", "integration"),
        default="worker",
    )
    create.add_argument(
        "--integrity-status",
        choices=("verified", "violation", "not-checked"),
        default="not-checked",
    )
    create.add_argument("--changed-path", action="append", default=[])
    create.add_argument("--setup-error", action="append", default=[])
    create.set_defaults(handler=command_create)

    bind = commands.add_parser("bind-head")
    bind.add_argument("--report", required=True)
    bind.add_argument("--head-sha", required=True)
    bind.add_argument("--task-id")
    bind.set_defaults(handler=command_bind)

    verify = commands.add_parser("verify-evidence")
    verify.add_argument("--report", required=True)
    verify.add_argument("--expected-head", required=True)
    verify.add_argument("--expected-command", required=True)
    verify.set_defaults(handler=command_verify)

    copy_evidence = commands.add_parser("copy-evidence")
    copy_evidence.add_argument("--report", required=True)
    copy_evidence.add_argument("--output", required=True)
    copy_evidence.add_argument("--expected-head", required=True)
    copy_evidence.add_argument("--expected-command", required=True)
    copy_evidence.set_defaults(handler=command_copy_evidence)

    request = commands.add_parser("create-verification-request")
    for flag in ("output", "task_id", "run_id", "head_sha", "tree_sha", "campaign", "task_contract", "policy_contract", "suite_id"):
        request.add_argument("--" + flag.replace("_", "-"), required=True)
    request.add_argument("--attempt", type=int, required=True)
    request.set_defaults(handler=command_create_verification_request)

    resolve = commands.add_parser("resolve-verification-request")
    for flag in ("request", "task_contract", "policy_contract"):
        resolve.add_argument("--" + flag.replace("_", "-"), required=True)
    resolve.add_argument("--expected-task", default="")
    resolve.set_defaults(handler=command_resolve_verification_request)

    bind_result = commands.add_parser("bind-verification-result")
    for flag in ("request", "report", "task_contract", "policy_contract"):
        bind_result.add_argument("--" + flag.replace("_", "-"), required=True)
    bind_result.add_argument("--evidence-source-command", default="")
    bind_result.set_defaults(handler=command_bind_verification_result)

    verify_result = commands.add_parser("verify-verification-result")
    for flag in ("request", "report", "task_contract", "policy_contract"):
        verify_result.add_argument("--" + flag.replace("_", "-"), required=True)
    verify_result.set_defaults(handler=command_verify_verification_result)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
