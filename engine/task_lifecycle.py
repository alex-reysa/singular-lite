#!/usr/bin/env python3
"""Owner-bound reservations and durable accepted-candidate state.

The existing lease remains the operational record.  A reservation is temporary
and compare-and-set by owner plus generation.  ``acceptedCandidate`` is durable:
reservation cleanup and integration failures may update its state, but may not
erase its identity or history.  Packet and audit files remain the acceptance
authority; this helper validates and snapshots their exact bindings.
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator


ACTIVE = {"planned", "running", "needs-review"}


class LifecycleError(RuntimeError):
    pass


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def failure_identity(failure: dict[str, Any]) -> str:
    explicit = str(failure.get("failureId", "") or "")
    if explicit:
        return explicit
    legacy_key = str(failure.get("key", "") or "")
    return sha256_text("legacy:" + legacy_key) if legacy_key else ""


def failure_counters(lease: dict[str, Any]) -> tuple[dict[str, int], dict[str, int]]:
    budgets = lease.setdefault("failureBudgets", {})
    for name in ("product", "infrastructure", "regate"):
        budgets[name] = int(budgets.get(name, 0) or 0)
    limits = lease.setdefault("failureLimits", {
        "product": int(lease.get("maxRetries", 3) or 0),
        "infrastructure": int(os.environ.get("SINGULAR_INFRASTRUCTURE_RECOVERY_MAX", "3")),
        "regate": int(os.environ.get("SINGULAR_REGATE_MAX", "3")),
    })
    for name in ("product", "infrastructure", "regate"):
        limits[name] = int(limits.get(name, 0) or 0)
    return budgets, limits


def ensure_recovery_capacity(lease: dict[str, Any], budget_domain: str) -> None:
    budgets, limits = failure_counters(lease)
    if budgets[budget_domain] >= limits[budget_domain]:
        raise LifecycleError(f"{budget_domain} recovery budget is exhausted")


def verification_artifacts(
    args: argparse.Namespace,
) -> tuple[Path, Path, Path, Path] | None:
    """Locate the host verification tuple consumed by accepted audit authority."""
    if args.acceptance_mode not in {"accepted", "accepted-waiver"}:
        return None
    report_arg = str(args.verification_report or "")
    request_arg = str(args.verification_request or "")
    policy_arg = str(args.verification_policy or "")
    report = Path(report_arg)
    request = Path(request_arg)
    policy = Path(policy_arg)
    if not all((report_arg, request_arg, policy_arg)):
        runs_dir = os.environ.get("SINGULAR_RUNS_DIR", "")
        if not runs_dir:
            raise LifecycleError("accepted audit is missing host verification paths")
        run_dir = Path(runs_dir) / args.run
        report = run_dir / "audit-verification.json"
        report_value = read_object(report)
        bound_request = report_value.get("verificationRequest")
        attempt = bound_request.get("attempt") if isinstance(bound_request, dict) else None
        if not isinstance(attempt, int) or isinstance(attempt, bool):
            raise LifecycleError("accepted audit has no bound verification attempt")
        request = run_dir / f"verification-request-{attempt}.json"
        policy = run_dir / f"verification-policy-{attempt}.json"
    request_value = read_object(request)
    bound_task = Path(str(request_value.get("taskContractPath", "")))
    if not str(request_value.get("taskContractPath", "")):
        raise LifecycleError("accepted audit request has no bound task contract")
    return request, report, bound_task, policy


def validate_verification_binding(
    request: Path, report: Path, bound_task_contract: Path, policy_contract: Path,
    current_task_contract: Path, task_id: str, run_id: str, head_sha: str, tree_sha: str,
    campaign: str,
) -> None:
    """Call the canonical validator; keep request/result logic out of lifecycle."""
    validator = Path(__file__).with_name("gate-report.py")
    command = [
        sys.executable, str(validator), "verify-verification-result",
        "--request", str(request), "--report", str(report),
        "--task-contract", str(bound_task_contract), "--policy-contract", str(policy_contract),
        "--current-task-contract", str(current_task_contract),
        "--expected-task", task_id, "--expected-run", run_id,
        "--expected-head", head_sha, "--expected-tree", tree_sha,
        "--expected-campaign", campaign,
        "--expected-suite", "task-contract-gate", "--require-pass",
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip().splitlines()
        raise LifecycleError(
            "accepted candidate verification binding failed"
            + (f": {detail[0]}" if detail else "")
        )


def validate_audit_acceptance(
    audit: Path, task_id: str, run_id: str, branch: str, head_sha: str
) -> None:
    """Use the canonical audit identity validator at direct lifecycle consumers."""
    validator = Path(__file__).with_name("audit-verdict-host-bind.py")
    command = [
        sys.executable, str(validator), "--validate-acceptance",
        "--verdict", str(audit), "--expected-task", task_id,
        "--expected-run", run_id, "--expected-branch", branch,
        "--expected-head", head_sha,
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip().splitlines()
        raise LifecycleError(
            "accepted candidate audit binding failed"
            + (f": {detail[0]}" if detail else "")
        )


def validate_candidate_artifacts(
    candidate: dict[str, Any], *, allow_status_transition: bool = False
) -> None:
    """Re-read the acceptance authorities instead of trusting cached hashes."""
    packet_path = Path(str(candidate.get("packetPath", "")))
    if not packet_path.is_file() or sha256(packet_path) != candidate.get("packetSha256"):
        raise LifecycleError("recovery predecessor packet is missing or changed")
    packet = read_object(packet_path)
    for field in ("taskId", "runId", "branch", "headSha"):
        if str(packet.get(field, "")) != str(candidate.get(field, "")):
            raise LifecycleError(f"recovery predecessor packet {field} mismatch")
    if packet.get("status") != "accepted":
        raise LifecycleError("recovery predecessor packet is not accepted")

    if candidate.get("acceptanceMode") == "accepted":
        audit_path = Path(str(candidate.get("auditPath", "")))
        if not audit_path.is_file() or sha256(audit_path) != candidate.get("auditSha256"):
            raise LifecycleError("recovery predecessor audit is missing or changed")
        validate_audit_acceptance(
            audit_path, str(candidate.get("taskId", "")),
            str(candidate.get("runId", "")), str(candidate.get("branch", "")),
            str(candidate.get("headSha", "")),
        )

    task_path = Path(str(candidate.get("taskContractPath", "")))
    task_matches = (
        task_path.is_file()
        and sha256(task_path) == candidate.get("taskContractSha256")
    )
    if not task_matches and not allow_status_transition:
        raise LifecycleError("recovery task contract is missing or changed")
    if candidate.get("acceptanceMode") in {"accepted", "accepted-waiver"}:
        if not task_matches and candidate.get("acceptanceMode") != "accepted":
            raise LifecycleError(
                "recovery task contract status transition lacks verified acceptance"
            )
        request_path = Path(str(candidate.get("verificationRequestPath", "")))
        report_path = Path(str(candidate.get("verificationReportPath", "")))
        bound_task_path = Path(str(candidate.get("verificationTaskContractPath", "")))
        policy_path = Path(str(candidate.get("verificationPolicyPath", "")))
        for label, path, expected in (
            ("request", request_path, candidate.get("verificationRequestSha256")),
            ("report", report_path, candidate.get("verificationReportSha256")),
            ("bound task contract", bound_task_path, candidate.get("verificationTaskContractSha256")),
            ("policy", policy_path, candidate.get("verificationPolicySha256")),
        ):
            if not path.is_file() or sha256(path) != expected:
                raise LifecycleError(f"recovery verification {label} is missing or changed")
        validate_verification_binding(
            request_path, report_path, bound_task_path, policy_path, task_path,
            str(candidate.get("taskId", "")), str(candidate.get("runId", "")),
            str(candidate.get("headSha", "")), str(candidate.get("treeSha", "")),
            str(candidate.get("campaignBinding", "")),
        )


def recovery_predecessor(lease: dict[str, Any], authority: dict[str, Any]) -> dict[str, Any]:
    candidates = []
    current = lease.get("acceptedCandidate")
    if isinstance(current, dict):
        candidates.append(current)
    candidates.extend(item for item in lease.get("candidateHistory", []) if isinstance(item, dict))
    for candidate in candidates:
        if all(
            str(candidate.get(field, "")) == str(authority.get(authority_field, ""))
            for field, authority_field in (
                ("taskId", "taskId"), ("runId", "predecessorRunId"),
                ("headSha", "predecessorHeadSha"), ("treeSha", "predecessorTreeSha"),
                ("campaignBinding", "campaignBinding"),
            )
        ):
            return candidate
    raise LifecycleError("recovery predecessor identity is no longer retained")


def validate_recovery_authorization(
    lease: dict[str, Any], authority: dict[str, Any], *, allow_status_transition: bool = False
) -> dict[str, Any]:
    authority_path = Path(str(authority.get("authorityPath", "")))
    if not authority_path.is_file() or sha256(authority_path) != authority.get("authoritySha256"):
        raise LifecycleError("recovery authority evidence is missing or changed")
    if authority.get("policyIdentity") != authority.get("campaignBinding"):
        raise LifecycleError("recovery policy identity is stale")
    predecessor = recovery_predecessor(lease, authority)
    task_path = Path(str(authority.get("taskContractPath", "")))
    task_matches = (
        task_path.is_file()
        and sha256(task_path) == authority.get("taskContractSha256")
    )
    if not task_matches and not allow_status_transition:
        raise LifecycleError("recovery task contract is missing or changed")
    if (
        not task_matches
        and authority.get("taskContractSha256") != predecessor.get("taskContractSha256")
    ):
        raise LifecycleError("recovery task contract authorization changed")
    validate_candidate_artifacts(
        predecessor, allow_status_transition=allow_status_transition
    )
    if authority.get("predecessorPacketSha256") != predecessor.get("packetSha256"):
        raise LifecycleError("recovery predecessor packet binding changed")
    if authority.get("predecessorAuditSha256") != predecessor.get("auditSha256"):
        raise LifecycleError("recovery predecessor audit binding changed")
    return predecessor


def repair_dispatch_eligible(lease: dict[str, Any], task_path: Path) -> bool:
    """Return whether an accepted task has one unspent, exact repair frontier."""
    authority = lease.get("recoveryAuthorization")
    if not isinstance(authority, dict):
        return False
    if authority.get("action") != "repair" or authority.get("state") != "issued":
        return False
    if lease.get("status") != "ready" or lease.get("reservationOwner"):
        return False
    if authority.get("reservationOwner") or authority.get("reservationGeneration"):
        return False
    if authority.get("campaignBinding") != lease.get("campaignBinding", "legacy"):
        return False
    if not task_path.is_file() or sha256(task_path) != authority.get("taskContractSha256"):
        return False
    predecessor_run = str(authority.get("predecessorRunId", ""))
    for field in ("attemptLifecycle", "terminalDisposition"):
        value = lease.get(field)
        if isinstance(value, dict) and str(value.get("runId", "")) != predecessor_run:
            return False
    try:
        validate_recovery_authorization(lease, authority)
    except LifecycleError:
        return False
    return True


def check_repair_dispatch_eligible(args: argparse.Namespace) -> None:
    if not repair_dispatch_eligible(read_object(Path(args.lease)), Path(args.task_contract)):
        raise LifecycleError("repair is not dispatch eligible")
    print("eligible")


def read_object(path: Path, *, missing: bool = False) -> dict[str, Any]:
    if missing and not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LifecycleError(f"unreadable lifecycle record {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise LifecycleError(f"lifecycle record is not an object: {path}")
    return value


def publish(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


@contextmanager
def locked(path: Path, *, missing: bool = False) -> Iterator[dict[str, Any]]:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lifecycle.lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        value = read_object(path, missing=missing)
        yield value
        if value.pop("_deleteRecord", False):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            return
        publish(path, value)


def reservation_matches(record: dict[str, Any], owner: str, generation: int) -> bool:
    return (
        record.get("reservationOwner") == owner
        and record.get("reservationGeneration") == generation
    )


def git_output(worktree: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(worktree), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode:
        raise LifecycleError((completed.stderr or completed.stdout).strip() or "git command failed")
    return completed.stdout.strip()


def git_is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    completed = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, descendant],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return completed.returncode == 0


def partial_paths(worktree: Path) -> tuple[list[str], list[str]]:
    def names(*args: str) -> list[str]:
        completed = subprocess.run(
            ["git", "-C", str(worktree), *args],
            capture_output=True,
            check=False,
        )
        if completed.returncode:
            raise LifecycleError(completed.stderr.decode(errors="replace").strip() or "git status failed")
        return [item.decode("utf-8", errors="surrogateescape") for item in completed.stdout.split(b"\0") if item]

    unstaged = names("diff", "--name-only", "-z")
    staged = names("diff", "--cached", "--name-only", "-z")
    untracked = names("ls-files", "--others", "--exclude-standard", "-z")
    return sorted(set(unstaged + staged + untracked)), sorted(set(staged))


def partial_snapshot(worktree: Path, paths: list[str] | None = None,
                     staged_paths: list[str] | None = None) -> dict[str, Any]:
    discovered, discovered_staged = partial_paths(worktree)
    paths = discovered if paths is None else paths
    staged_paths = discovered_staged if staged_paths is None else staged_paths
    entries: dict[str, Any] = {}
    for relative in paths:
        candidate = worktree / relative
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            entries[relative] = {"kind": "missing"}
            continue
        mode = format(stat.S_IMODE(info.st_mode), "04o")
        if stat.S_ISLNK(info.st_mode):
            raw = os.readlink(candidate).encode("utf-8", errors="surrogateescape")
            kind = "symlink"
        elif stat.S_ISREG(info.st_mode):
            raw = candidate.read_bytes()
            kind = "file"
        else:
            raw = b""
            kind = "other"
        entries[relative] = {
            "kind": kind,
            "mode": mode,
            "sha256": hashlib.sha256(raw).hexdigest(),
        }
    staged: dict[str, str] = {}
    for relative in staged_paths:
        completed = subprocess.run(
            ["git", "-C", str(worktree), "ls-files", "--stage", "--", relative],
            capture_output=True,
            check=False,
        )
        if completed.returncode:
            raise LifecycleError("cannot snapshot staged partial work")
        staged[relative] = completed.stdout.decode("utf-8", errors="surrogateescape")
    value = {"paths": paths, "stagedPaths": staged_paths, "entries": entries, "staged": staged}
    value["sha256"] = sha256_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
    return value


def reserve(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    with locked(lease_path, missing=True) as lease:
        if lease.get("taskId") not in (None, "", args.task):
            raise LifecycleError("lease task identity mismatch")
        candidate = lease.get("acceptedCandidate")
        recovery = lease.get("recoveryAuthorization")
        repair = (
            recovery if isinstance(recovery, dict)
            and recovery.get("action") == "repair"
            and recovery.get("state") in {"issued", "claimed"}
            else None
        )
        reservation_run = args.run
        execution_run = args.run
        if repair is not None:
            validate_recovery_authorization(lease, repair)
            if args.campaign != repair.get("campaignBinding"):
                raise LifecycleError("reservation campaign does not match repair authority")
            exact = (
                args.run == repair.get("successorRunId")
                and args.branch == repair.get("successorBranch")
                and str(Path(args.worktree)) == str(Path(str(repair.get("successorWorktree"))))
            )
            scheduler_override = str(args.owner).startswith("reconcile:")
            if not exact and not scheduler_override:
                raise LifecycleError("reservation does not match the authorized repair successor")
            if scheduler_override:
                execution_run = str(repair["successorRunId"])
                args.branch = str(repair["successorBranch"])
                args.worktree = str(repair["successorWorktree"])
        status = str(lease.get("status", ""))
        current_owner = str(lease.get("reservationOwner", ""))
        current_generation = max(
            int(lease.get("reservationGeneration", 0) or 0),
            int(lease.get("lastReservationGeneration", 0) or 0),
        )
        if repair is not None and repair.get("state") == "claimed":
            same_reservation = (
                status in ACTIVE
                and current_owner == args.owner
                and lease.get("reservationRunId") == reservation_run
                and repair.get("reservationOwner") == args.owner
                and repair.get("reservationGeneration") == current_generation
                and repair.get("reservationRunId") == reservation_run
            )
            if same_reservation:
                print(current_generation)
                return
            raise LifecycleError("claimed repair authority cannot reserve another execution")
        if isinstance(candidate, dict) and candidate.get("state") != "integrated":
            raise LifecycleError("durable accepted candidate requires integration recovery, not redispatch")
        imported_dir = Path(args.imported_dir)
        if imported_dir.is_dir():
            for packet_path in sorted(imported_dir.glob("*.json")):
                if packet_path.name.endswith(".audit.json"):
                    continue
                packet = read_object(packet_path)
                if packet.get("taskId") == args.task and packet.get("status") == "accepted":
                    if repair is not None and (
                        packet.get("runId") == repair.get("predecessorRunId")
                        and packet.get("headSha") == repair.get("predecessorHeadSha")
                    ):
                        continue
                    raise LifecycleError(
                        f"accepted packet {packet_path.name} requires integration, not redispatch"
                    )
        continuation = lease.get("continuationAuthorization")
        continuation_issued = (
            continuation if isinstance(continuation, dict)
            and continuation.get("state") == "issued"
            else None
        )
        if (
            isinstance(continuation, dict)
            and continuation_issued is None
            and repair is None
        ):
            raise LifecycleError("continuation authority is not reservable")
        terminal = lease.get("terminalDisposition")
        attempt = lease.get("attemptLifecycle")
        predecessor_run = str(repair.get("predecessorRunId", "")) if repair else ""
        predecessor_attempt = (
            isinstance(attempt, dict)
            and attempt.get("state") in {"started", "terminal"}
            and str(attempt.get("runId", "")) == predecessor_run
        )
        predecessor_terminal = (
            isinstance(terminal, dict)
            and str(terminal.get("runId", "")) == predecessor_run
        )
        if continuation_issued is not None:
            exact_continuation = (
                args.branch == continuation_issued.get("branch")
                and str(Path(args.worktree).resolve())
                == str(Path(str(continuation_issued.get("worktree"))).resolve())
                and args.campaign == continuation_issued.get("campaignBinding")
                and args.engine_source_fingerprint
                == continuation_issued.get("engineSourceFingerprint")
                and git_is_ancestor(
                    Path(args.repo_root),
                    str(continuation_issued.get("targetHeadAtAuthorization", "")),
                    args.base,
                )
            )
            if not exact_continuation:
                raise LifecycleError("reservation does not match the one-shot continuation authority")
        elif isinstance(terminal, dict) or isinstance(attempt, dict):
            # A validated accepted-candidate repair is the other existing form
            # of explicit successor authority. Its predecessor terminal state
            # remains history, but must not force the unrelated partial-work
            # continuation protocol.
            if repair is None or not (
                (not isinstance(attempt, dict) or predecessor_attempt)
                and (not isinstance(terminal, dict) or predecessor_terminal)
            ):
                raise LifecycleError("terminal or started work requires explicit successor authority")
        if status in {"accepted", "integrated"}:
            raise LifecycleError(f"{status} work cannot be reserved for implementation")
        if status in ACTIVE and current_owner:
            if current_owner == args.owner and lease.get("reservationRunId") == reservation_run:
                print(current_generation)
                return
            raise LifecycleError(f"reservation already owned by {current_owner}@{current_generation}")
        generation = current_generation + 1
        timestamp = now()
        # Admission has succeeded. Move the predecessor generation's immutable
        # outcome aside before binding a fresh current generation. The guards
        # above inspect these fields before they are archived, so history can
        # never turn into implicit redispatch authority.
        if isinstance(attempt, dict):
            history = lease.setdefault("attemptHistory", [])
            identity = (
                attempt.get("reservationOwner"), attempt.get("reservationGeneration"),
                attempt.get("runId"), attempt.get("state"),
            )
            if not any(
                isinstance(item, dict) and (
                    item.get("reservationOwner"), item.get("reservationGeneration"),
                    item.get("runId"), item.get("state"),
                ) == identity
                for item in history
            ):
                history.append(copy.deepcopy(attempt))
            lease.pop("attemptLifecycle", None)
        if isinstance(terminal, dict):
            history = lease.setdefault("terminalDispositionHistory", [])
            identity = (
                terminal.get("reservationOwner"), terminal.get("reservationGeneration"),
                terminal.get("runId"), terminal.get("kind"),
            )
            if not any(
                isinstance(item, dict) and (
                    item.get("reservationOwner"), item.get("reservationGeneration"),
                    item.get("runId"), item.get("kind"),
                ) == identity
                for item in history
            ):
                history.append(copy.deepcopy(terminal))
            lease.pop("terminalDisposition", None)
        lease.update({
            "taskId": args.task,
            "branch": args.branch,
            "area": args.area,
            "owner": args.owner,
            "fileScope": " ".join(json.loads(args.scope_json)),
            "ownedFiles": json.loads(args.scope_json),
            "baseSha": args.base,
            "reservationBaseSha": args.base,
            "campaignBinding": args.campaign,
            "batchId": args.batch,
            "runId": execution_run,
            "worktree": args.worktree,
            "status": "planned",
            "reservationOwner": args.owner,
            "reservationGeneration": generation,
            "reservationRunId": reservation_run,
            "reservationDeadlineAt": (
                datetime.now(timezone.utc) + timedelta(seconds=args.deadline_seconds)
            ).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "nextAction": "launch and monitor the reserved task",
            "updatedAt": timestamp,
        })
        lease.setdefault("createdAt", timestamp)
        lease.setdefault("retryCount", 0)
        lease.setdefault("maxRetries", int(os.environ.get("SINGULAR_MAX_RETRIES", "3")))
        lease.setdefault("productPassStarted", False)
        if continuation_issued is not None:
            continuation_issued.update({
                "state": "reserved",
                "reservationOwner": args.owner,
                "reservationGeneration": generation,
                "reservationRunId": reservation_run,
                "reservedAt": timestamp,
            })
        if repair is not None:
            repair.update({
                "reservationOwner": args.owner,
                "reservationGeneration": generation,
                "reservationRunId": reservation_run,
                "reservedAt": timestamp,
            })
        print(generation)


def bind_dispatch(args: argparse.Namespace) -> None:
    record_path = Path(args.record)
    with locked(record_path, missing=True) as record:
        if record.get("state") == "launched" and not reservation_matches(
            record, args.owner, args.generation
        ):
            raise LifecycleError("dispatch record already belongs to another reservation")
        same_generation = reservation_matches(record, args.owner, args.generation)
        if record and not same_generation:
            # Per-task dispatch files are reused. Preserve the complete prior
            # generation record, including its terminal attempt and exit
            # evidence, then remove only generation-local current fields.
            prior_owner = str(record.get("reservationOwner", ""))
            prior_generation = int(record.get("reservationGeneration", 0) or 0)
            if prior_owner and prior_generation:
                history = record.setdefault("dispatchHistory", [])
                prior = {
                    key: copy.deepcopy(value)
                    for key, value in record.items()
                    if key not in {"dispatchHistory", "_deleteRecord"}
                }
                if not any(
                    isinstance(item, dict)
                    and item.get("reservationOwner") == prior_owner
                    and int(item.get("reservationGeneration", 0) or 0) == prior_generation
                    for item in history
                ):
                    history.append(prior)
            for key in (
                "attemptLifecycle", "exitCode", "outcome", "reapedAt", "finishedAt"
            ):
                record.pop(key, None)
        record.update({
            "taskId": args.task,
            "runId": args.run,
            "pid": args.pid,
            "pidStart": args.pid_start,
            "pgid": args.pgid,
            "log": args.log,
            "baseSha": args.base,
            "batchId": args.batch,
            "state": "launched",
            "startedAt": now(),
            "reservationOwner": args.owner,
            "reservationGeneration": args.generation,
            "campaignBinding": args.campaign,
        })


def record_attempt(args: argparse.Namespace) -> None:
    if args.state not in {"started", "terminal"}:
        raise LifecycleError("invalid attempt lifecycle state")
    if args.state == "terminal" and args.disposition not in {
        "completed", "blocked", "campaign-mismatch", "retryable-failure"
    }:
        raise LifecycleError("invalid terminal disposition")
    if args.state == "started" and (args.disposition or args.failure_class or args.terminal_action):
        raise LifecycleError("started attempt cannot carry a terminal disposition")
    lease_path = Path(args.lease)
    record_path = Path(args.record)
    with locked(record_path) as record:
        if not reservation_matches(record, args.owner, args.generation):
            raise LifecycleError("stale worker cannot publish attempt disposition")
        if record.get("runId") != args.reservation_run:
            raise LifecycleError("attempt reservation run does not match dispatch")
        if record.get("campaignBinding", "legacy") != args.campaign:
            raise LifecycleError("attempt campaign does not match dispatch")
        with locked(lease_path) as lease:
            if not reservation_matches(lease, args.owner, args.generation):
                raise LifecycleError("attempt does not own the current lease")
            if lease.get("reservationRunId") != args.reservation_run:
                raise LifecycleError("attempt reservation run does not match lease")
            if lease.get("campaignBinding", "legacy") != args.campaign:
                raise LifecycleError("attempt campaign does not match lease")
            previous = record.get("attemptLifecycle")
            if isinstance(previous, dict):
                same = (
                    previous.get("taskId") == args.task
                    and previous.get("runId") == args.run
                    and previous.get("campaignBinding") == args.campaign
                )
                if not same:
                    raise LifecycleError("another attempt already owns this dispatch")
                if previous.get("state") == "terminal":
                    if args.state == "terminal" and previous.get("disposition") == args.disposition:
                        return
                    raise LifecycleError("terminal attempt disposition is immutable")
            timestamp = now()
            value = {
                "schema": "singular.orchestration.attempt-lifecycle.v0",
                "taskId": args.task,
                "runId": args.run,
                "reservationRunId": args.reservation_run,
                "reservationOwner": args.owner,
                "reservationGeneration": args.generation,
                "campaignBinding": args.campaign,
                "state": args.state,
                "updatedAt": timestamp,
            }
            if isinstance(previous, dict):
                value["startedAt"] = previous.get("startedAt", timestamp)
                if previous.get("continuationAuthorizationId"):
                    value["continuationAuthorizationId"] = previous[
                        "continuationAuthorizationId"
                    ]
            else:
                value["startedAt"] = timestamp
            if args.state == "terminal":
                if not isinstance(previous, dict) or previous.get("state") != "started":
                    raise LifecycleError("terminal attempt requires a started predecessor")
                value.update({
                    "disposition": args.disposition,
                    "failureClass": args.failure_class,
                    "action": args.terminal_action,
                    "finishedAt": timestamp,
                })
            record["attemptLifecycle"] = copy.deepcopy(value)
            lease["attemptLifecycle"] = copy.deepcopy(value)
            if args.state == "terminal":
                lease["terminalDisposition"] = {
                    "schema": "singular.orchestration.terminal-disposition.v0",
                    "kind": args.disposition,
                    "failureClass": args.failure_class,
                    "action": args.terminal_action,
                    "runId": args.run,
                    "reservationRunId": args.reservation_run,
                    "reservationOwner": args.owner,
                    "reservationGeneration": args.generation,
                    "campaignBinding": args.campaign,
                    "recordedAt": timestamp,
                }


def write_exit(args: argparse.Namespace) -> None:
    record = read_object(Path(args.record))
    if not reservation_matches(record, args.owner, args.generation) or record.get("state") != "launched":
        raise LifecycleError("stale wrapper cannot publish an exit for this dispatch")
    publish(Path(args.exit_file), {
        "exitCode": args.exit_code,
        "reservationOwner": args.owner,
        "reservationGeneration": args.generation,
        "writtenAt": now(),
    })


def read_exit(args: argparse.Namespace) -> None:
    record = read_object(Path(args.record))
    result = read_object(Path(args.exit_file))
    owner = str(result.get("reservationOwner", ""))
    generation = int(result.get("reservationGeneration", 0) or 0)
    if not reservation_matches(record, owner, generation):
        raise LifecycleError("exit attribution does not match the current dispatch")
    print(int(result.get("exitCode", 1)))
    print(owner)
    print(generation)


def reconcile_orphan_reservation(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    record_path = Path(args.record)
    if record_path.exists():
        record = read_object(record_path)
        if record.get("state") == "launched" and reservation_matches(
            record, args.owner, args.generation
        ):
            raise LifecycleError("launched reservation must be finished by its dispatch owner")
    with locked(lease_path) as lease:
        existing = lease.get("terminalDisposition")
        exact = {
            "reservationOwner": args.owner,
            "reservationGeneration": args.generation,
            "reservationRunId": args.run,
            "campaignBinding": args.campaign,
            "reservationBaseSha": args.reservation_base,
            "candidateSourceSha": args.candidate_source,
            "worktree": str(Path(args.worktree).resolve()),
        }
        if isinstance(existing, dict) and existing.get("kind") == "orphan-reservation":
            if all(existing.get(key) == value for key, value in exact.items()):
                print(existing.get("reconciliationId", ""))
                return
            raise LifecycleError("reconciled orphan identity mismatch")
        if not reservation_matches(lease, args.owner, args.generation):
            raise LifecycleError("orphan reservation owner or generation mismatch")
        if lease.get("reservationRunId") != args.run:
            raise LifecycleError("orphan reservation run mismatch")
        if lease.get("campaignBinding", "legacy") != args.campaign:
            raise LifecycleError("orphan reservation campaign mismatch")
        if lease.get("baseSha") != args.reservation_base:
            raise LifecycleError("orphan reservation base mismatch")
        if str(Path(str(lease.get("worktree", ""))).resolve()) != exact["worktree"]:
            raise LifecycleError("orphan reservation worktree mismatch")
        worktree = Path(exact["worktree"])
        if git_output(worktree, "rev-parse", "HEAD") != args.candidate_source:
            raise LifecycleError("orphan candidate source does not match the preserved worktree")
        if str(lease.get("status", "")) not in ACTIVE:
            raise LifecycleError("orphan reservation is no longer active")
        timestamp = now()
        identity = sha256_text(json.dumps(exact, sort_keys=True, separators=(",", ":")))
        lease["status"] = "blocked"
        lease["failureReason"] = "unlaunched-orphan-reservation"
        lease["nextAction"] = "authorize an exact one-shot continuation or supersede"
        lease["terminalDisposition"] = {
            "schema": "singular.orchestration.terminal-disposition.v0",
            "kind": "orphan-reservation",
            **exact,
            "reconciliationId": identity,
            "recordedAt": timestamp,
        }
        lease["lastReservationOwner"] = args.owner
        lease["lastReservationGeneration"] = max(
            int(lease.get("lastReservationGeneration", 0) or 0), args.generation
        )
        lease.pop("reservationOwner", None)
        lease.pop("reservationRunId", None)
        lease.pop("reservationDeadlineAt", None)
        lease["updatedAt"] = timestamp
        print(identity)


def authorize_continuation(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    authority_path = Path(args.authority)
    task_path = Path(args.task_contract)
    authority = read_object(authority_path)
    if authority.get("schema") != "singular.orchestration.continuation-authority.v0":
        raise LifecycleError("unsupported continuation authority schema")
    expected = {
        "taskId": args.expected_task,
        "predecessorOwner": args.predecessor_owner,
        "predecessorGeneration": args.predecessor_generation,
        "predecessorRunId": args.predecessor_run,
        "predecessorCampaignBinding": args.predecessor_campaign,
        "predecessorReservationBaseSha": args.predecessor_reservation_base,
        "candidateSourceSha": args.candidate_source,
        "candidateBaseSha": args.candidate_base,
        "integrationTargetSha": args.integration_target,
        "integrationTargetBranch": args.integration_target_branch,
        "targetHeadAtAuthorization": args.target_head_at_authorization,
        "engineSourceFingerprint": args.engine_source_fingerprint,
        "campaignBinding": args.expected_campaign,
        "worktree": str(Path(args.worktree).resolve()),
    }
    for key, value in expected.items():
        observed = authority.get(key)
        if key == "worktree":
            observed = str(Path(str(observed)).resolve())
        if observed != value:
            raise LifecycleError(f"continuation authority {key} mismatch")
    if authority.get("taskContractSha256") != sha256(task_path):
        raise LifecycleError("continuation task contract changed before authorization")
    worktree = Path(expected["worktree"])
    if not worktree.is_dir():
        raise LifecycleError("continuation worktree is missing")
    top = Path(git_output(worktree, "rev-parse", "--show-toplevel")).resolve()
    if top != worktree.resolve():
        raise LifecycleError("continuation worktree identity mismatch")
    repo = Path(git_output(worktree, "rev-parse", "--show-toplevel")).resolve()
    if not git_is_ancestor(repo, args.candidate_base, args.candidate_source):
        raise LifecycleError("continuation candidate base is not an ancestor of candidate source")
    if not git_is_ancestor(repo, args.candidate_base, args.integration_target):
        raise LifecycleError("continuation candidate base is not an ancestor of integration target")

    with locked(lease_path) as lease:
        if isinstance(lease.get("continuationAuthorization"), dict):
            raise LifecycleError("one-shot continuation authority already exists")
        terminal = lease.get("terminalDisposition")
        if not isinstance(terminal, dict) or terminal.get("kind") != "orphan-reservation":
            raise LifecycleError("continuation requires an exactly reconciled orphan reservation")
        terminal_expected = {
            "reservationOwner": args.predecessor_owner,
            "reservationGeneration": args.predecessor_generation,
            "reservationRunId": args.predecessor_run,
            "campaignBinding": args.predecessor_campaign,
            "reservationBaseSha": args.predecessor_reservation_base,
            "candidateSourceSha": args.candidate_source,
            "worktree": expected["worktree"],
        }
        if any(terminal.get(key) != value for key, value in terminal_expected.items()):
            raise LifecycleError("continuation predecessor does not match orphan reconciliation")
        if str(Path(str(lease.get("worktree", ""))).resolve()) != expected["worktree"]:
            raise LifecycleError("continuation lease worktree mismatch")
        if lease.get("branch") != authority.get("branch"):
            raise LifecycleError("continuation branch mismatch")
        before_head = git_output(worktree, "rev-parse", "HEAD")
        if before_head != args.candidate_source:
            raise LifecycleError("continuation candidate source is not the worktree head")
        partial_before = partial_snapshot(worktree)
        partial_after = partial_snapshot(
            worktree, partial_before["paths"], partial_before["stagedPaths"]
        )
        if (partial_after["entries"], partial_after["staged"]) != (
            partial_before["entries"], partial_before["staged"]
        ):
            raise LifecycleError("continuation authorization changed partial work bytes or staged identity")
        timestamp = now()
        durable = copy.deepcopy(authority)
        durable.update({
            "authorizationId": sha256(authority_path),
            "authorityPath": str(authority_path),
            "authoritySha256": sha256(authority_path),
            "state": "issued",
            "issuedAt": timestamp,
            "partialSnapshotSha256": partial_before["sha256"],
            "partialSnapshot": partial_after,
            "additionalWorkerAttemptsAuthorized": 1,
            "additionalWorkerAttemptsClaimed": 0,
            "additionalWorkerAttemptsRemaining": 1,
            "preparationFailureCount": 0,
            "automaticPreparationRetriesRemaining": 1,
            "predecessorAccounting": {
                "retryCount": int(lease.get("retryCount", 0) or 0),
                "maxRetries": int(lease.get("maxRetries", 0) or 0),
                "productPassStarted": lease.get("productPassStarted") is True,
                "productPassStartedRunId": str(lease.get("productPassStartedRunId", "") or ""),
                "infrastructureAttempts": "retained-in-run-artifacts-usage-unknown",
            },
        })
        lease["continuationAuthorization"] = durable
        lease["status"] = "ready"
        lease["nextAction"] = "reserve and claim the exact one-shot native continuation"
        # The retained candidate deliberately stays at its original source.
        # The separately bound executing source identifies the newer immutable
        # engine/runtime driving it; integration later performs the ordinary
        # exact-tree merge and gate against the then-current target.
        lease["updatedAt"] = timestamp
        print(durable["authorizationId"])


def claim_continuation(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    record_path = Path(args.record)
    task_path = Path(args.task_contract)
    # This is the continuation's invocation boundary. Dispatch is locked first
    # (the same order as record_attempt/finish), then the authority claim and
    # started-attempt disposition are published together. A crash before this
    # transaction leaves an unspent reserved authority; a crash after it leaves
    # an owner-bound started attempt and therefore fails closed.
    with locked(record_path) as record:
        if not reservation_matches(record, args.owner, args.generation):
            raise LifecycleError("continuation attempt does not own the dispatch")
        if record.get("runId") != args.reservation_run:
            raise LifecycleError("continuation reservation run does not match dispatch")
        if record.get("campaignBinding", "legacy") != args.campaign:
            raise LifecycleError("continuation campaign does not match dispatch")
        if isinstance(record.get("attemptLifecycle"), dict):
            raise LifecycleError("continuation dispatch already has an attempt")
        with locked(lease_path) as lease:
            authority = lease.get("continuationAuthorization")
            if not isinstance(authority, dict) or authority.get("state") != "reserved":
                raise LifecycleError("continuation authority is not reserved or was already consumed")
            if authority.get("authorizationId") != args.authorization_id:
                raise LifecycleError("continuation authorization id mismatch")
            exact = (
                authority.get("reservationOwner") == args.owner
                and authority.get("reservationGeneration") == args.generation
                and authority.get("reservationRunId") == args.reservation_run
                and authority.get("campaignBinding") == args.campaign
                and authority.get("candidateSourceSha") == args.candidate_source
                and authority.get("candidateBaseSha") == args.candidate_base
                and authority.get("integrationTargetSha") == args.integration_target
                and authority.get("engineSourceFingerprint")
                == args.engine_source_fingerprint
                and str(Path(str(authority.get("worktree"))).resolve())
                == str(Path(args.worktree).resolve())
            )
            if not exact or not reservation_matches(lease, args.owner, args.generation):
                raise LifecycleError("continuation claim does not match the reserved execution")
            if authority.get("taskContractSha256") != sha256(task_path):
                raise LifecycleError("continuation task contract changed before claim")
            worktree = Path(args.worktree)
            if git_output(worktree, "rev-parse", "HEAD") != args.candidate_source:
                raise LifecycleError("continuation candidate source changed before claim")
            if not git_is_ancestor(Path(args.repo_root), args.candidate_base, args.candidate_source):
                raise LifecycleError("continuation candidate base is not an ancestor of candidate source")
            if not git_is_ancestor(
                Path(args.repo_root),
                str(authority.get("targetHeadAtAuthorization", "")),
                args.reservation_base,
            ):
                raise LifecycleError("continuation target head is not an ancestor of the reservation base")
            if lease.get("reservationBaseSha") != args.reservation_base:
                raise LifecycleError("continuation reservation base changed before claim")
            expected_snapshot = authority.get("partialSnapshot")
            if not isinstance(expected_snapshot, dict):
                raise LifecycleError("continuation partial snapshot is missing")
            actual_snapshot = partial_snapshot(
                worktree,
                [str(item) for item in expected_snapshot.get("paths", [])],
                [str(item) for item in expected_snapshot.get("stagedPaths", [])],
            )
            if (actual_snapshot["entries"], actual_snapshot["staged"]) != (
                expected_snapshot.get("entries"), expected_snapshot.get("staged")
            ):
                raise LifecycleError("continuation partial work changed after authorization")
            timestamp = now()
            attempt = {
                "schema": "singular.orchestration.attempt-lifecycle.v0",
                "taskId": args.task,
                "runId": args.run,
                "reservationRunId": args.reservation_run,
                "reservationOwner": args.owner,
                "reservationGeneration": args.generation,
                "campaignBinding": args.campaign,
                "state": "started",
                "continuationAuthorizationId": args.authorization_id,
                "startedAt": timestamp,
                "updatedAt": timestamp,
            }
            authority.update({
                "state": "claimed",
                "executionRunId": args.run,
                "claimedAt": timestamp,
                "additionalWorkerAttemptsClaimed": 1,
                "additionalWorkerAttemptsRemaining": 0,
            })
            record["attemptLifecycle"] = copy.deepcopy(attempt)
            lease["attemptLifecycle"] = copy.deepcopy(attempt)
            lease["updatedAt"] = timestamp


def rearm_continuation_preparation(args: argparse.Namespace) -> None:
    """Rearm an unspent continuation after distinct host-repair evidence."""
    evidence_path = Path(args.evidence).resolve()
    if not evidence_path.is_file():
        raise LifecycleError("continuation preparation recovery evidence is missing")
    evidence_sha = sha256(evidence_path)
    with locked(Path(args.lease)) as lease:
        authority = lease.get("continuationAuthorization")
        if not isinstance(authority, dict):
            raise LifecycleError("missing continuation authority")
        if authority.get("authorizationId") != args.authorization_id:
            raise LifecycleError("continuation authorization id mismatch")
        if authority.get("state") != "preparation-blocked":
            raise LifecycleError("continuation preparation is not blocked")
        if int(authority.get("additionalWorkerAttemptsClaimed", 0) or 0) != 0:
            raise LifecycleError("claimed continuation cannot be rearmed")
        if int(authority.get("additionalWorkerAttemptsRemaining", 0) or 0) != 1:
            raise LifecycleError("continuation has no unspent worker allowance")
        history = authority.setdefault("preparationRecoveryEvidence", [])
        if any(
            isinstance(item, dict) and item.get("sha256") == evidence_sha
            for item in history
        ):
            raise LifecycleError("continuation preparation recovery evidence was already used")
        timestamp = now()
        history.append({
            "path": str(evidence_path),
            "sha256": evidence_sha,
            "recordedAt": timestamp,
        })
        authority["state"] = "issued"
        authority["preparationRearmCount"] = int(
            authority.get("preparationRearmCount", 0) or 0
        ) + 1
        authority["lastPreparationRearmedAt"] = timestamp
        lease["status"] = "ready"
        lease["failureReason"] = ""
        lease["nextAction"] = "reserve the same unspent continuation after host preparation repair"
        lease["updatedAt"] = timestamp
        print(authority["authorizationId"])


def finish(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    record_path = Path(args.record)
    # Lock dispatch first, then lease. bind-dispatch only locks dispatch and
    # reserve only locks lease, so this order cannot form a lock cycle. It does
    # close the reserve-before-bind window: if a successor reservation exists,
    # its lease token refuses the predecessor even while the old dispatch
    # record is still visible.
    with locked(record_path) as record:
        if not reservation_matches(record, args.owner, args.generation):
            raise LifecycleError("stale owner cannot finish this dispatch")
        if record.get("runId") != args.reservation_run:
            raise LifecycleError("stale reservation run cannot finish this dispatch")
        if record.get("campaignBinding", "legacy") != args.campaign:
            raise LifecycleError("stale campaign cannot finish this dispatch")
        if not lease_path.exists():
            return
        with locked(lease_path) as lease:
            candidate = lease.get("acceptedCandidate")
            if isinstance(candidate, dict) and candidate.get("state") != "integrated":
                return
            lease_owner = str(lease.get("reservationOwner", ""))
            lease_generation = int(lease.get("reservationGeneration", 0) or 0)
            if (
                not lease_owner
                and str(lease.get("lastReservationOwner", "")) == args.owner
                and int(lease.get("lastReservationGeneration", 0) or 0) == args.generation
            ):
                # Wrapper finish may commit before it can publish the exit.
                # The reaper repeats finish before finalizing that same dispatch.
                return
            if (lease_owner or lease_generation) and (
                lease_owner != args.owner or lease_generation != args.generation
            ):
                raise LifecycleError(
                    "stale owner cannot finish successor lease "
                    f"{lease_owner}@{lease_generation}"
                )
            if lease.get("campaignBinding", "legacy") != args.campaign:
                raise LifecycleError("dispatch campaign cannot finish a different lease campaign")
            # Native l1-drive currently rewrites compatibility lease fields and
            # therefore drops the reservation token. In that case the locked
            # dispatch token remains the CAS authority; task, branch, base and
            # batch must still match before cleanup may touch the lease.
            if lease.get("taskId") != args.task:
                raise LifecycleError("lease task changed before reservation cleanup")
            if args.batch and lease.get("batchId") not in (None, "", args.batch):
                raise LifecycleError("lease batch changed before reservation cleanup")
            status = str(lease.get("status", ""))
            attempt = record.get("attemptLifecycle")
            continuation = lease.get("continuationAuthorization")
            if (
                isinstance(continuation, dict)
                and continuation.get("state") == "reserved"
                and continuation.get("reservationOwner") == args.owner
                and continuation.get("reservationGeneration") == args.generation
                and continuation.get("reservationRunId") == args.reservation_run
                and not isinstance(attempt, dict)
            ):
                # Preparation or pre-worker context assembly failed. Nothing
                # consumed the separately authorized worker invocation, so
                # make the exact authority reservable again without changing
                # its predecessor accounting or partial-work snapshot.
                timestamp = now()
                failures = int(continuation.get("preparationFailureCount", 0) or 0) + 1
                retries_remaining = max(
                    0,
                    int(continuation.get("automaticPreparationRetriesRemaining", 1) or 0) - 1,
                )
                continuation["preparationFailureCount"] = failures
                continuation["automaticPreparationRetriesRemaining"] = retries_remaining
                continuation["state"] = "issued" if failures == 1 else "preparation-blocked"
                continuation["lastPreparationFailure"] = args.reason
                continuation["lastPreparationFailureAt"] = timestamp
                for key in (
                    "reservationOwner", "reservationGeneration", "reservationRunId", "reservedAt"
                ):
                    continuation.pop(key, None)
                lease["status"] = "ready" if failures == 1 else "blocked"
                lease["failureReason"] = args.reason
                lease["nextAction"] = (
                    "retry the exact one-shot continuation after repairing host preparation"
                    if failures == 1
                    else "inspect the repeated preparation failure; explicit recovery is required"
                )
                lease["updatedAt"] = timestamp
                lease["lastReservationOwner"] = args.owner
                lease["lastReservationGeneration"] = max(
                    int(lease.get("lastReservationGeneration", 0) or 0), args.generation
                )
                lease.pop("reservationOwner", None)
                lease.pop("reservationRunId", None)
                lease.pop("reservationDeadlineAt", None)
                return
            disposition = ""
            failure_reason = args.reason
            next_action = args.next_action
            if isinstance(attempt, dict):
                if (
                    attempt.get("reservationRunId") != args.reservation_run
                    or attempt.get("campaignBinding") != args.campaign
                    or attempt.get("runId") != lease.get("runId")
                ):
                    raise LifecycleError("attempt disposition is not bound to the finishing lease")
                if attempt.get("state") == "terminal":
                    disposition = str(attempt.get("disposition", ""))
                    failure_reason = str(attempt.get("failureClass", "") or args.reason)
                    next_action = str(attempt.get("action", "") or args.next_action)
                elif attempt.get("state") == "started":
                    disposition = "outcome-unknown"
                    failure_reason = "started-attempt-exited-without-terminal-disposition"
                    next_action = "inspect preserved attempt artifacts and authorize an exact continuation"
                    lease["terminalDisposition"] = {
                        "schema": "singular.orchestration.terminal-disposition.v0",
                        "kind": disposition,
                        "failureClass": failure_reason,
                        "action": next_action,
                        "runId": attempt.get("runId", ""),
                        "reservationRunId": args.reservation_run,
                        "reservationOwner": args.owner,
                        "reservationGeneration": args.generation,
                        "campaignBinding": args.campaign,
                        "recordedAt": now(),
                    }
            if (
                status == "planned"
                and lease.get("productPassStarted") is False
                and args.reason.startswith("driver-")
            ):
                # A driver that never acquired execution ownership leaves only
                # a disposable scheduler reservation and no attempt history.
                lease["_deleteRecord"] = True
                return
            if status in ACTIVE:
                if disposition in {"blocked", "campaign-mismatch", "outcome-unknown"}:
                    lease["status"] = "blocked"
                elif disposition == "completed":
                    pass
                else:
                    lease["status"] = "failed"
                lease["failureReason"] = failure_reason
                lease["nextAction"] = next_action
                lease["updatedAt"] = now()
            lease["lastReservationOwner"] = args.owner
            lease["lastReservationGeneration"] = max(
                int(lease.get("lastReservationGeneration", 0) or 0),
                args.generation,
            )
            lease.pop("reservationOwner", None)
            lease.pop("reservationRunId", None)
            lease.pop("reservationDeadlineAt", None)


def legacy_finish(args: argparse.Namespace) -> None:
    """One-time CAS closure for leases written before reservation generations."""
    lease_path = Path(args.lease)
    with locked(lease_path) as lease:
        if lease.get("reservationOwner") or lease.get("reservationGeneration"):
            raise LifecycleError("generated reservation requires its original owner token")
        if sha256(lease_path) != args.lease_sha:
            raise LifecycleError("legacy lease changed during recovery")
        if isinstance(lease.get("acceptedCandidate"), dict):
            raise LifecycleError("legacy recovery cannot alter a durable candidate")
        if str(lease.get("status", "")) not in ACTIVE:
            raise LifecycleError("legacy lease is no longer active")
        lease["status"] = args.new_status
        lease["failureReason"] = args.reason
        lease["nextAction"] = args.next_action
        lease["legacyRecoveryCasSha256"] = args.lease_sha
        lease["updatedAt"] = now()


def finalize(args: argparse.Namespace) -> None:
    record_path = Path(args.record)
    with locked(record_path) as record:
        if not reservation_matches(record, args.owner, args.generation):
            raise LifecycleError("stale reaper cannot finalize this dispatch")
        if record.get("state") == "reaped":
            return
        record.update({
            "state": "reaped",
            "exitCode": args.exit_code,
            "outcome": args.outcome,
            "reapedAt": now(),
        })
    try:
        Path(args.exit_file).unlink()
    except FileNotFoundError:
        pass


def retain_candidate(args: argparse.Namespace) -> None:
    packet_path = Path(args.packet)
    packet = read_object(packet_path)
    if packet.get("status") != "accepted" or packet.get("taskId") != args.task:
        raise LifecycleError("packet is not accepted for this task")
    for field, expected in (("runId", args.run), ("branch", args.branch), ("headSha", args.head)):
        if str(packet.get(field, "")) != expected:
            raise LifecycleError(f"packet {field} binding mismatch")
    audit_path: Path | None = None
    audit: dict[str, Any] = {}
    if args.acceptance_mode == "accepted":
        audit_path = Path(args.audit)
        audit = read_object(audit_path)
        validate_audit_acceptance(
            audit_path, args.task, args.run, args.branch, args.head
        )
    task_path = Path(args.task_file)
    verification = verification_artifacts(args)
    verification_identity: dict[str, Any] = {"auditSchema": str(audit.get("schema", ""))}
    if verification is not None:
        request_path, report_path, bound_task_path, policy_path = verification
        validate_verification_binding(
            request_path, report_path, bound_task_path, policy_path, task_path,
            args.task, args.run, args.head, args.tree,
            args.campaign,
        )
        verification_identity.update({
            "verificationRequestPath": str(request_path),
            "verificationRequestSha256": sha256(request_path),
            "verificationReportPath": str(report_path),
            "verificationReportSha256": sha256(report_path),
            "verificationTaskContractPath": str(bound_task_path),
            "verificationTaskContractSha256": sha256(bound_task_path),
            "verificationPolicyPath": str(policy_path),
            "verificationPolicySha256": sha256(policy_path),
        })
    identity = {
        "taskId": args.task,
        "runId": args.run,
        "branch": args.branch,
        "headSha": args.head,
        "treeSha": args.tree,
        "campaignBinding": args.campaign,
        "acceptanceMode": args.acceptance_mode,
        "packetPath": str(packet_path),
        "packetSha256": sha256(packet_path),
        "auditPath": str(audit_path) if audit_path else "",
        "auditSha256": sha256(audit_path) if audit_path else "",
        "taskContractPath": str(task_path),
        "taskContractSha256": sha256(task_path),
        **verification_identity,
    }
    lease_path = Path(args.lease)
    with locked(lease_path, missing=True) as lease:
        previous = lease.get("acceptedCandidate")
        if isinstance(previous, dict):
            previous_identity = {key: previous.get(key, "") for key in identity}
            if previous_identity != identity:
                raise LifecycleError("accepted candidate identity changed without a fresh lifecycle")
            # Preserve failure state/history across unchanged reconciliation.
            print(previous.get("state", "accepted"))
            return
        recovery = lease.get("recoveryAuthorization")
        if isinstance(recovery, dict) and recovery.get("action") == "repair":
            if recovery.get("state") not in {"issued", "claimed"}:
                raise LifecycleError("repair authorization is not active")
            validate_recovery_authorization(lease, recovery)
            for field, observed in (
                ("successorRunId", args.run),
                ("successorBranch", args.branch),
            ):
                if str(recovery.get(field, "")) != observed:
                    raise LifecycleError(f"repair candidate {field} mismatch")
            if args.acceptance_mode != "accepted" or audit_path is None:
                raise LifecycleError("changed repair candidate requires a fresh accepted audit")
            recovery["state"] = "audit-accepted"
            recovery["auditAcceptedAt"] = now()
            recovery["successorHeadSha"] = args.head
            recovery["successorTreeSha"] = args.tree
            recovery["successorAuditSha256"] = sha256(audit_path)
        timestamp = now()
        identity.update({"state": "accepted", "acceptedAt": timestamp, "failures": []})
        lease.update({
            "taskId": args.task,
            "branch": args.branch,
            "runId": args.run,
            "status": "accepted",
            "acceptedCandidate": identity,
            "nextAction": "integrate the accepted candidate",
            "updatedAt": timestamp,
        })
        lease.setdefault("createdAt", timestamp)
        print("accepted")


def candidate_check(args: argparse.Namespace) -> None:
    lease = read_object(Path(args.lease))
    candidate = lease.get("acceptedCandidate")
    if not isinstance(candidate, dict):
        raise LifecycleError("missing durable accepted candidate")
    expected = (args.head, args.tree, args.campaign)
    observed = tuple(candidate.get(key, "") for key in ("headSha", "treeSha", "campaignBinding"))
    if observed != expected:
        raise LifecycleError(f"candidate identity mismatch: expected {expected}, observed {observed}")
    if candidate.get("state") == "integrated":
        raise LifecycleError("candidate is already integrated")
    if candidate.get("state") == "integration-failed":
        failures = [
            failure for failure in candidate.get("failures") or []
            if isinstance(failure, dict)
        ]
        for failure in reversed(failures):
            failure_class = failure.get("failureClass") if isinstance(failure, dict) else ""
            expected_key = (
                args.branch_key
                if failure_class == "branch-missing" and args.branch_key
                else args.invalidation_key
            )
            if failure.get("invalidationKey") == expected_key:
                print(
                    failure.get("nextAction")
                    or candidate.get("nextAction")
                    or "repair the candidate or change an invalidating input"
                )
                raise SystemExit(3)
        if failures:
            latest = failures[-1]
            domain = str(latest.get("domain", "") or "")
            if domain not in {"product", "infrastructure", "regate"}:
                domain = (
                    "infrastructure"
                    if str(latest.get("failureClass", "")) in {
                        "branch-missing", "git-lock-timeout", "setup-failed",
                        "gate-infrastructure", "gate-report-invalid",
                    }
                    else "product"
                )
            budgets, limits = failure_counters(lease)
            if budgets[domain] >= limits[domain]:
                print(f"{domain} recovery budget is exhausted")
                raise SystemExit(3)


def candidate_failed(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    with locked(lease_path) as lease:
        candidate = lease.get("acceptedCandidate")
        if not isinstance(candidate, dict):
            raise LifecycleError("missing durable accepted candidate")
        observed = tuple(candidate.get(key, "") for key in ("headSha", "treeSha", "campaignBinding"))
        expected = (args.head, args.tree, args.campaign)
        if observed != expected:
            raise LifecycleError("candidate compare-and-set failed")
        failures = candidate.setdefault("failures", [])
        authority = lease.get("recoveryAuthorization")
        execution_binding = {
            "failureClass": args.failure_class,
            "targetHead": args.target_head,
            "candidateHead": args.head,
            "candidateTree": args.tree,
            "campaignBinding": args.campaign,
            "invalidationKey": args.invalidation_key,
        }
        recovery_context: dict[str, Any] = {}
        if isinstance(authority, dict) and authority.get("state") in {
            "claimed", "audit-accepted", "gate-passed",
        }:
            recovery_context = {
                "authorizationId": str(authority.get("authorizationId", "")),
                "action": str(authority.get("action", "")),
                "successorRunId": str(authority.get("successorRunId", "")),
                "claimId": str(authority.get("claimId", "")),
            }
        elif (
            isinstance(authority, dict)
            and authority.get("state") == "failed"
            and authority.get("executionFailureBinding") == execution_binding
        ):
            recovery_context = {
                "authorizationId": str(authority.get("authorizationId", "")),
                "action": str(authority.get("action", "")),
                "successorRunId": str(authority.get("successorRunId", "")),
                "claimId": str(authority.get("claimId", "")),
            }
        domain = args.domain
        if not domain:
            domain = (
                "infrastructure"
                if args.failure_class in {
                    "branch-missing", "git-lock-timeout", "setup-failed",
                    "gate-infrastructure", "gate-report-invalid",
                }
                else "regate"
                if recovery_context.get("action") == "regate"
                else "product"
            )
        legacy_key = f"{args.failure_class}:{args.target_head}:{args.head}:{args.invalidation_key}"
        failure_key = {
            "failureClass": args.failure_class,
            "targetHead": args.target_head,
            "candidateHead": args.head,
            "invalidationKey": args.invalidation_key,
            "recovery": recovery_context,
        }
        failure_id = args.failure_id or sha256_text(json.dumps(
            failure_key, sort_keys=True, separators=(",", ":")
        ))
        if (
            recovery_context
            and isinstance(authority, dict)
            and authority.get("state") == "failed"
            and authority.get("executionFailureId") != failure_id
        ):
            raise LifecycleError("completed recovery execution cannot publish a second failure")
        key = failure_id
        existing = next(
            (item for item in failures if isinstance(item, dict) and (
                item.get("failureId") == failure_id or item.get("key") == legacy_key
            )),
            None,
        )
        if existing is not None:
            was_unaccounted = not existing.get("failureId")
            immutable = {
                "failureClass": args.failure_class,
                "targetHead": args.target_head,
                "invalidationKey": args.invalidation_key,
                "domain": domain,
                "recoveryAuthorizationId": recovery_context.get("authorizationId", ""),
                "recoveryAction": recovery_context.get("action", ""),
                "recoveryRunId": recovery_context.get("successorRunId", ""),
            }
            if any(existing.get(name, "") != value for name, value in immutable.items()):
                raise LifecycleError("failure identity replay changed its binding")
            existing["failureId"] = failure_id
            existing["domain"] = domain
        else:
            was_unaccounted = True
            failures.append({
                "key": key,
                "failureId": failure_id,
                "domain": domain,
                "failureClass": args.failure_class,
                "targetHead": args.target_head,
                "invalidationKey": args.invalidation_key,
                "nextAction": args.next_action,
                "recoveryAuthorizationId": recovery_context.get("authorizationId", ""),
                "recoveryAction": recovery_context.get("action", ""),
                "recoveryRunId": recovery_context.get("successorRunId", ""),
                "observedAt": now(),
            })
        if was_unaccounted:
            budgets, _ = failure_counters(lease)
            budgets[domain] += 1
        candidate["state"] = "integration-failed"
        candidate["nextAction"] = args.next_action
        # A failed attempt cannot leave a gate receipt that could later be
        # mistaken for authority to finalize a manually-created merge.
        candidate.pop("integrationProof", None)
        lease["status"] = "accepted"
        lease["nextAction"] = args.next_action
        lease["updatedAt"] = now()
        if recovery_context and isinstance(authority, dict):
            authority["state"] = "failed"
            authority["executionCompletedAt"] = now()
            authority["executionFailureId"] = failure_id
            authority["executionFailureDomain"] = domain
            authority["executionFailureBinding"] = execution_binding


def authorize_recovery(args: argparse.Namespace) -> None:
    """Consume host-authored recovery authority without erasing its predecessor."""
    authority_path = Path(args.authority)
    authority = read_object(authority_path)
    allowed = {
        "schema", "taskId", "predecessorRunId", "predecessorHeadSha",
        "predecessorTreeSha", "campaignBinding", "policyIdentity", "failureId",
        "action", "successorRunId", "successorBranch", "successorWorktree",
        "authorizedBy",
    }
    unexpected = sorted(set(authority) - allowed)
    if unexpected:
        raise LifecycleError("recovery authority contains unsupported fields: " + ", ".join(unexpected))
    missing = sorted(name for name in allowed if not str(authority.get(name, "")))
    if missing:
        raise LifecycleError("recovery authority missing: " + ", ".join(missing))
    if authority.get("schema") != "singular.orchestration.recovery-authority.v0":
        raise LifecycleError("unsupported recovery authority schema")
    if authority.get("taskId") != args.expected_task:
        raise LifecycleError("recovery task identity mismatch")
    if authority.get("campaignBinding") != args.expected_campaign:
        raise LifecycleError("recovery campaign identity mismatch")
    if authority.get("policyIdentity") != args.expected_policy:
        raise LifecycleError("recovery policy identity mismatch")
    action = str(authority.get("action"))
    if action not in {"repair", "regate"}:
        raise LifecycleError("recovery action is not permitted")
    task_path = Path(args.task_contract)
    task_sha = sha256(task_path)
    authority_sha = sha256(authority_path)
    with locked(Path(args.lease)) as lease:
        candidate = lease.get("acceptedCandidate")
        if not isinstance(candidate, dict):
            raise LifecycleError("missing retained predecessor candidate")
        for field, authority_field in (
            ("taskId", "taskId"), ("runId", "predecessorRunId"),
            ("headSha", "predecessorHeadSha"), ("treeSha", "predecessorTreeSha"),
            ("campaignBinding", "campaignBinding"),
        ):
            if str(candidate.get(field, "")) != str(authority.get(authority_field, "")):
                raise LifecycleError(f"recovery predecessor {field} mismatch")
        if candidate.get("taskContractSha256") != task_sha:
            raise LifecycleError(
                "recovery task contract changed "
                f"({task_path}: expected {candidate.get('taskContractSha256')}, observed {task_sha})"
            )
        validate_candidate_artifacts(candidate)
        failure = next(
            (item for item in candidate.get("failures", [])
             if isinstance(item, dict) and failure_identity(item) == authority.get("failureId")),
            None,
        )
        if failure is None:
            raise LifecycleError("recovery failure identity is not eligible")
        if not failure.get("failureId"):
            historical_domain = str(failure.get("domain", "") or "")
            if historical_domain not in {"product", "infrastructure", "regate"}:
                historical_domain = (
                    "infrastructure"
                    if failure.get("failureClass") in {"branch-missing", "git-lock-timeout", "setup-failed"}
                    else "product"
                )
            failure["failureId"] = str(authority["failureId"])
            failure["domain"] = historical_domain
            budgets = lease.setdefault("failureBudgets", {})
            for name in ("product", "infrastructure", "regate"):
                budgets[name] = int(budgets.get(name, 0) or 0)
            budgets[historical_domain] += 1
        failure_domain = str(failure.get("domain", ""))
        eligible_domains = {"product", "infrastructure", "regate"}
        if failure_domain not in eligible_domains:
            raise LifecycleError(
                f"{action} recovery cannot consume a {failure_domain or 'missing'} failure"
            )
        budget_domain = (
            "infrastructure" if failure_domain == "infrastructure"
            else "product" if action == "repair" else "regate"
        )
        ensure_recovery_capacity(lease, budget_domain)
        existing = lease.get("recoveryAuthorization")
        history_authorizations = lease.setdefault("recoveryAuthorizations", [])
        all_authorizations = [
            item for item in history_authorizations + ([existing] if isinstance(existing, dict) else [])
            if isinstance(item, dict)
        ]
        if any(item.get("authoritySha256") == authority_sha for item in all_authorizations):
            raise LifecycleError("recovery authority replay was already recorded")
        if any(item.get("failureId") == authority.get("failureId") for item in all_authorizations):
            raise LifecycleError("recovery failure was already consumed by an authorization")
        if isinstance(existing, dict) and existing.get("state") in {
            "issued", "claimed", "audit-accepted", "gate-passed",
        }:
            raise LifecycleError("recovery authorization is already active")
        if isinstance(existing, dict):
            history_authorizations.append(copy.deepcopy(existing))
        predecessor_worktree = str(lease.get("worktree", "") or "")
        successor_run = str(authority["successorRunId"])
        successor_branch = str(authority["successorBranch"])
        successor_worktree = str(authority["successorWorktree"])
        if successor_run == candidate.get("runId"):
            raise LifecycleError("recovery requires a distinct successor run")
        if action == "repair":
            if successor_branch == candidate.get("branch"):
                raise LifecycleError("repair requires a distinct successor branch")
            if predecessor_worktree and successor_worktree == predecessor_worktree:
                raise LifecycleError("repair requires a separate successor worktree")
        elif successor_branch != candidate.get("branch"):
            raise LifecycleError("unchanged regate cannot change the candidate branch")
        binding = {
            **authority,
            "authorityPath": str(authority_path),
            "authoritySha256": authority_sha,
            "taskContractPath": str(task_path),
            "taskContractSha256": task_sha,
            "predecessorPacketSha256": candidate.get("packetSha256", ""),
            "predecessorAuditSha256": candidate.get("auditSha256", ""),
            "predecessorWorktree": predecessor_worktree,
            "freshAuditRequired": action == "repair",
            "budgetDomain": budget_domain,
            "state": "issued",
            "authorizedAt": now(),
        }
        authorization_id = sha256_text(json.dumps(binding, sort_keys=True, separators=(",", ":")))
        binding["authorizationId"] = authorization_id
        lease["recoveryAuthorization"] = binding
        if action == "repair":
            history = lease.setdefault("candidateHistory", [])
            if not any(
                isinstance(item, dict) and item.get("headSha") == candidate.get("headSha")
                and item.get("runId") == candidate.get("runId") for item in history
            ):
                history.append(copy.deepcopy(candidate))
            lease.pop("acceptedCandidate", None)
            lease.update({
                "status": "ready", "runId": successor_run, "branch": successor_branch,
                "worktree": successor_worktree,
                "nextAction": "launch the authorized repair in its separate worktree",
            })
        else:
            candidate["nextAction"] = "run the authorized unchanged exact-tree regate"
            lease["nextAction"] = candidate["nextAction"]
        lease["updatedAt"] = now()
        print(authorization_id)


def claim_recovery(args: argparse.Namespace) -> None:
    with locked(Path(args.lease)) as lease:
        authority = lease.get("recoveryAuthorization")
        if not isinstance(authority, dict):
            raise LifecycleError("missing recovery authorization")
        if authority.get("authorizationId") != args.authorization_id:
            raise LifecycleError("recovery authorization identity mismatch")
        if authority.get("action") != args.recovery_action or authority.get("successorRunId") != args.run:
            raise LifecycleError("recovery authorization action/run mismatch")
        if authority.get("campaignBinding") != args.campaign:
            raise LifecycleError("recovery authorization campaign mismatch")
        if args.recovery_action == "repair":
            if not args.owner or not args.generation or not args.reservation_run:
                raise LifecycleError("repair claim requires its scheduler reservation identity")
            exact_reservation = (
                authority.get("reservationOwner") == args.owner
                and authority.get("reservationGeneration") == args.generation
                and authority.get("reservationRunId") == args.reservation_run
                and reservation_matches(lease, args.owner, args.generation)
                and lease.get("reservationRunId") == args.reservation_run
                and lease.get("runId") == args.run
            )
            if not exact_reservation:
                raise LifecycleError("repair claim does not match its scheduler reservation")
        predecessor = validate_recovery_authorization(lease, authority)
        claim_binding = {
            "authorizationId": args.authorization_id,
            "action": args.recovery_action,
            "runId": args.run,
            "headSha": args.head,
            "treeSha": args.tree,
            "campaignBinding": args.campaign,
        }
        claim_id = sha256_text(json.dumps(claim_binding, sort_keys=True, separators=(",", ":")))
        budget_domain = str(authority.get("budgetDomain", "") or "")
        if budget_domain not in {"product", "infrastructure", "regate"}:
            budget_domain = "product" if args.recovery_action == "repair" else "regate"
        if authority.get("state") in {"claimed", "audit-accepted", "gate-passed"}:
            if authority.get("claimId") != claim_id:
                raise LifecycleError("recovery authorization claim replay changed identity")
            ensure_recovery_capacity(lease, budget_domain)
            print(authority["authorizationId"])
            return
        if authority.get("state") != "issued":
            raise LifecycleError("recovery authorization was already published")
        if args.recovery_action == "regate":
            candidate = lease.get("acceptedCandidate")
            if not isinstance(candidate, dict):
                raise LifecycleError("unchanged regate lost its candidate")
            if (candidate.get("headSha"), candidate.get("treeSha")) != (args.head, args.tree):
                raise LifecycleError("unchanged regate candidate identity changed")
        elif (predecessor.get("headSha"), predecessor.get("treeSha")) != (args.head, args.tree):
            raise LifecycleError("repair predecessor identity changed")
        ensure_recovery_capacity(lease, budget_domain)
        authority["state"] = "claimed"
        authority["claimId"] = claim_id
        authority["claimedAt"] = now()
        authority["executionStartedAt"] = authority["claimedAt"]
        lease["updatedAt"] = now()
        print(authority["authorizationId"])


def validate_accepted_publication(args: argparse.Namespace) -> None:
    """Validate L1's retained acceptance without advancing lifecycle state.

    In particular, a repair successor keeps its claimed authorization until the
    imported packet is retained.  That claim is provenance for the successor,
    not competing dispatch authority, but only when every original claim and
    scheduler-generation binding still agrees.
    """
    lease = read_object(Path(args.lease))
    packet = read_object(Path(args.packet))
    audit_path = Path(args.audit)
    task_path = Path(args.task_contract)

    expected = {
        "taskId": args.task,
        "runId": args.run,
        "branch": args.branch,
        "baseSha": args.base,
        "campaignBinding": args.campaign,
    }
    for field, value in expected.items():
        observed = str(lease.get(field, "") or "")
        if field == "campaignBinding" and not observed and args.campaign == "legacy":
            observed = "legacy"
        if observed != value:
            raise LifecycleError(f"accepted publication lease {field} mismatch")
    if os.path.realpath(str(lease.get("worktree", ""))) != os.path.realpath(args.worktree):
        raise LifecycleError("accepted publication lease worktree mismatch")

    for field, value in (
        ("taskId", args.task), ("runId", args.run), ("branch", args.branch),
        ("baseRef", args.base), ("headSha", args.head),
    ):
        if str(packet.get(field, "")) != value:
            raise LifecycleError(f"accepted publication packet {field} mismatch")
    if os.path.realpath(str(packet.get("workspace", ""))) != os.path.realpath(args.worktree):
        raise LifecycleError("accepted publication packet workspace mismatch")
    if packet.get("status") not in {"blocked", "accepted"}:
        raise LifecycleError("accepted publication packet has no retained acceptance state")

    validate_audit_acceptance(audit_path, args.task, args.run, args.branch, args.head)
    packet_bindings = [
        str(item.get("ref", "")) for item in packet.get("evidence", [])
        if isinstance(item, dict) and item.get("kind") == "campaign-binding"
    ]
    audit = read_object(audit_path)
    audit_bindings = [
        str(item)[len("campaign-binding:"):]
        for item in audit.get("evidenceReviewed", [])
        if str(item).startswith("campaign-binding:")
    ]
    if args.campaign == "legacy":
        packet_bindings = packet_bindings or ["legacy"]
        audit_bindings = audit_bindings or ["legacy"]
    if packet_bindings != [args.campaign] or audit_bindings != [args.campaign]:
        raise LifecycleError("accepted publication campaign evidence mismatch")

    # The importer will retain this same host-verification tuple. Validate it
    # before L1 either publishes or reports a duplicate, so an accepted model
    # verdict cannot stand in for the host's exact-head proof.
    run_dir = Path(args.packet).parent
    report_path = run_dir / "audit-verification.json"
    report = read_object(report_path)
    bound_request = report.get("verificationRequest")
    attempt_number = bound_request.get("attempt") if isinstance(bound_request, dict) else None
    if not isinstance(attempt_number, int) or isinstance(attempt_number, bool):
        raise LifecycleError("accepted publication has no bound verification attempt")
    request_path = run_dir / f"verification-request-{attempt_number}.json"
    policy_path = run_dir / f"verification-policy-{attempt_number}.json"
    request = read_object(request_path)
    bound_task_value = str(request.get("taskContractPath", ""))
    if not bound_task_value:
        raise LifecycleError("accepted publication verification has no task contract")
    resolved_tree = subprocess.run(
        ["git", "-C", args.repo_root, "rev-parse", f"{args.head}^{{tree}}"],
        capture_output=True, text=True, check=False,
    )
    if resolved_tree.returncode:
        raise LifecycleError("accepted publication head tree is unavailable")
    validate_verification_binding(
        request_path, report_path, Path(bound_task_value), policy_path, task_path,
        args.task, args.run, args.head, resolved_tree.stdout.strip(), args.campaign,
    )

    candidate = lease.get("acceptedCandidate")
    if isinstance(candidate, dict):
        for field, value in (
            ("taskId", args.task), ("runId", args.run), ("branch", args.branch),
            ("headSha", args.head), ("campaignBinding", args.campaign),
        ):
            if str(candidate.get(field, "")) != value:
                raise LifecycleError(f"retained accepted candidate {field} mismatch")
        validate_candidate_artifacts(candidate)

    continuation = lease.get("continuationAuthorization")
    authority = lease.get("recoveryAuthorization")
    if isinstance(continuation, dict):
        if isinstance(authority, dict):
            raise LifecycleError("accepted publication has conflicting successor authorities")
        authority_path = Path(str(continuation.get("authorityPath", "")))
        authority_sha = str(continuation.get("authoritySha256", ""))
        if (
            not authority_path.is_file()
            or not authority_sha
            or sha256(authority_path) != authority_sha
            or str(continuation.get("authorizationId", "")) != authority_sha
        ):
            raise LifecycleError("continuation authority evidence is missing or changed")
        recorded = read_object(authority_path)
        if any(continuation.get(key) != value for key, value in recorded.items()):
            raise LifecycleError("recorded continuation authorization changed")
        if continuation.get("state") != "claimed":
            raise LifecycleError("accepted continuation authority is not consumed")
        for field, value in (
            ("taskId", args.task),
            ("executionRunId", args.run),
            ("branch", args.branch),
            ("campaignBinding", args.campaign),
            ("candidateBaseSha", args.base),
        ):
            if str(continuation.get(field, "")) != value:
                raise LifecycleError(f"accepted continuation {field} mismatch")
        if os.path.realpath(str(continuation.get("worktree", ""))) != os.path.realpath(
            args.worktree
        ):
            raise LifecycleError("accepted continuation worktree mismatch")
        candidate_source = str(continuation.get("candidateSourceSha", ""))
        if not candidate_source or not git_is_ancestor(
            Path(args.repo_root), candidate_source, args.head
        ):
            raise LifecycleError("accepted continuation head lost its authorized source")

        owner = str(continuation.get("reservationOwner", ""))
        try:
            generation = int(continuation.get("reservationGeneration", 0) or 0)
            attempt_generation = int(
                (lease.get("attemptLifecycle") or {}).get("reservationGeneration", 0) or 0
            )
            lease_generation = int(
                lease.get("reservationGeneration")
                or lease.get("lastReservationGeneration")
                or 0
            )
            allowance = (
                int(continuation.get("additionalWorkerAttemptsAuthorized", 0) or 0),
                int(continuation.get("additionalWorkerAttemptsClaimed", 0) or 0),
                int(continuation.get("additionalWorkerAttemptsRemaining", -1)),
            )
            predecessor_retry = int(
                (continuation.get("predecessorAccounting") or {}).get("retryCount", -1)
            )
            predecessor_max = int(
                (continuation.get("predecessorAccounting") or {}).get("maxRetries", -1)
            )
            lease_retry = int(lease.get("retryCount", -2))
            lease_max = int(lease.get("maxRetries", -2))
        except (TypeError, ValueError, AttributeError) as exc:
            raise LifecycleError("accepted continuation has malformed numeric identity") from exc
        reservation_run = str(continuation.get("reservationRunId", ""))
        if not owner or generation < 1 or not reservation_run:
            raise LifecycleError("accepted continuation lacks scheduler identity")
        attempt = lease.get("attemptLifecycle")
        if not isinstance(attempt, dict):
            raise LifecycleError("accepted continuation lost its scheduler attempt binding")
        if (
            attempt.get("taskId") != args.task
            or attempt.get("runId") != args.run
            or attempt.get("reservationOwner") != owner
            or attempt_generation != generation
            or attempt.get("reservationRunId") != reservation_run
            or attempt.get("campaignBinding") != args.campaign
            or attempt.get("continuationAuthorizationId")
            != continuation.get("authorizationId")
            or attempt.get("state") not in {"started", "terminal"}
        ):
            raise LifecycleError("accepted continuation scheduler attempt identity mismatch")
        lease_owner = str(lease.get("reservationOwner") or lease.get("lastReservationOwner") or "")
        if lease_owner != owner or lease_generation != generation:
            raise LifecycleError("accepted continuation scheduler generation mismatch")
        if allowance != (1, 1, 0):
            raise LifecycleError("accepted continuation allowance is not exactly consumed")
        predecessor = continuation.get("predecessorAccounting")
        if not isinstance(predecessor, dict) or (
            predecessor_retry != lease_retry
            or predecessor_max != lease_max
            or bool(predecessor.get("productPassStarted"))
            != (lease.get("productPassStarted") is True)
            or str(predecessor.get("productPassStartedRunId", ""))
            != str(lease.get("productPassStartedRunId", "") or "")
        ):
            raise LifecycleError("accepted continuation predecessor accounting mismatch")
        print("continuation-claimed")
        return
    if not isinstance(authority, dict):
        print("ordinary-retained" if isinstance(candidate, dict) else "ordinary")
        return
    if authority.get("action") != "repair" or authority.get("state") not in {
        "claimed", "audit-accepted", "gate-passed",
    }:
        raise LifecycleError("accepted publication has conflicting recovery authority")
    validate_recovery_authorization(lease, authority, allow_status_transition=True)
    for field, value in (
        ("taskId", args.task), ("successorRunId", args.run),
        ("successorBranch", args.branch), ("campaignBinding", args.campaign),
    ):
        if str(authority.get(field, "")) != value:
            raise LifecycleError(f"accepted repair successor {field} mismatch")
    if os.path.realpath(str(authority.get("successorWorktree", ""))) != os.path.realpath(
        args.worktree
    ):
        raise LifecycleError("accepted repair successor worktree mismatch")
    if str(authority.get("predecessorHeadSha", "")) != args.base:
        raise LifecycleError("accepted repair successor base mismatch")
    claim_binding = {
        "authorizationId": str(authority.get("authorizationId", "")),
        "action": "repair",
        "runId": args.run,
        "headSha": str(authority.get("predecessorHeadSha", "")),
        "treeSha": str(authority.get("predecessorTreeSha", "")),
        "campaignBinding": args.campaign,
    }
    claim_id = sha256_text(json.dumps(claim_binding, sort_keys=True, separators=(",", ":")))
    if authority.get("claimId") != claim_id:
        raise LifecycleError("accepted repair claim identity mismatch")

    attempt = lease.get("attemptLifecycle")
    if not isinstance(attempt, dict):
        raise LifecycleError("accepted repair lost its scheduler attempt binding")
    owner = str(authority.get("reservationOwner", ""))
    generation = int(authority.get("reservationGeneration", 0) or 0)
    reservation_run = str(authority.get("reservationRunId", ""))
    if not owner or generation < 1 or not reservation_run:
        raise LifecycleError("accepted repair claim lacks scheduler identity")
    if (
        attempt.get("taskId") != args.task
        or attempt.get("runId") != args.run
        or attempt.get("reservationOwner") != owner
        or int(attempt.get("reservationGeneration", 0) or 0) != generation
        or attempt.get("reservationRunId") != reservation_run
        or attempt.get("campaignBinding") != args.campaign
    ):
        raise LifecycleError("accepted repair scheduler attempt identity mismatch")
    lease_owner = str(lease.get("reservationOwner") or lease.get("lastReservationOwner") or "")
    lease_generation = int(
        lease.get("reservationGeneration") or lease.get("lastReservationGeneration") or 0
    )
    if lease_owner != owner or lease_generation != generation:
        raise LifecycleError("accepted repair scheduler generation mismatch")

    if authority.get("state") in {"audit-accepted", "gate-passed"}:
        if (
            authority.get("successorHeadSha") != args.head
            or authority.get("successorTreeSha") != resolved_tree.stdout.strip()
            or authority.get("successorAuditSha256") != sha256(audit_path)
        ):
            raise LifecycleError("accepted repair retained successor identity mismatch")
    print("repair-" + str(authority.get("state")))


def candidate_tested(args: argparse.Namespace) -> None:
    gate_report_path = Path(args.gate_report)
    gate_report = read_object(gate_report_path)
    if gate_report.get("outcome") not in {"passed", "passed-with-acknowledged-baseline"}:
        raise LifecycleError("integration gate report is not green")
    if str(gate_report.get("headSha", "")) != args.synthetic_commit:
        raise LifecycleError("integration gate report does not cover the synthetic commit")
    if args.candidate_parent != args.head:
        raise LifecycleError("tested merge parent is not the accepted candidate")

    proof = {
        "testedTree": args.tested_tree,
        "targetParent": args.target_parent,
        "candidateParent": args.candidate_parent,
        "syntheticCommit": args.synthetic_commit,
        "gateRunId": args.gate_run,
        "gateReportPath": str(gate_report_path),
        "gateReportSha256": sha256(gate_report_path),
        "gateCommandSha256": sha256_text(args.gate_command),
        "campaignBinding": args.campaign,
    }
    proof_id = sha256_text(json.dumps(proof, sort_keys=True, separators=(",", ":")))
    proof["proofId"] = proof_id
    proof["recordedAt"] = now()

    lease_path = Path(args.lease)
    with locked(lease_path) as lease:
        candidate = lease.get("acceptedCandidate")
        if not isinstance(candidate, dict):
            raise LifecycleError("missing durable accepted candidate")
        observed = tuple(candidate.get(key, "") for key in ("headSha", "treeSha", "campaignBinding"))
        expected = (args.head, args.tree, args.campaign)
        if observed != expected:
            raise LifecycleError("candidate compare-and-set failed")
        candidate["integrationProof"] = proof
        candidate["state"] = "integration-tested"
        candidate["nextAction"] = "commit the exact tested merge and publish its proof"
        lease["status"] = "accepted"
        lease["nextAction"] = candidate["nextAction"]
        lease["updatedAt"] = now()
        authority = lease.get("recoveryAuthorization")
        if isinstance(authority, dict) and authority.get("state") in {"claimed", "audit-accepted"}:
            authority["state"] = "gate-passed"
            authority["gateProofId"] = proof_id
            authority["gatePassedAt"] = now()
    print(proof_id)


def candidate_proof(args: argparse.Namespace) -> None:
    lease = read_object(Path(args.lease))
    candidate = lease.get("acceptedCandidate")
    if not isinstance(candidate, dict):
        raise LifecycleError("missing durable accepted candidate")
    observed = tuple(candidate.get(key, "") for key in ("headSha", "treeSha", "campaignBinding"))
    expected = (args.head, args.tree, args.campaign)
    if observed != expected:
        raise LifecycleError("candidate compare-and-set failed")
    proof = candidate.get("integrationProof")
    if not isinstance(proof, dict):
        raise LifecycleError("accepted candidate has no verified integration proof")
    if proof.get("campaignBinding") != args.campaign:
        raise LifecycleError("integration proof belongs to another campaign")
    if proof.get("candidateParent") != args.head:
        raise LifecycleError("integration proof candidate parent changed")
    if proof.get("gateCommandSha256") != sha256_text(args.gate_command):
        raise LifecycleError("integration gate command changed after testing")
    report_path = Path(str(proof.get("gateReportPath", "")))
    if not report_path.is_file() or sha256(report_path) != proof.get("gateReportSha256"):
        raise LifecycleError("integration gate report is missing or changed")
    report = read_object(report_path)
    if (
        report.get("outcome") not in {"passed", "passed-with-acknowledged-baseline"}
        or str(report.get("headSha", "")) != proof.get("syntheticCommit")
    ):
        raise LifecycleError("integration gate report no longer proves this merge")
    for key in ("proofId", "testedTree", "targetParent", "candidateParent", "syntheticCommit"):
        value = str(proof.get(key, ""))
        if not value:
            raise LifecycleError(f"integration proof is missing {key}")
        print(value)


def candidate_blocked(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    with locked(lease_path) as lease:
        candidate = lease.get("acceptedCandidate")
        if not isinstance(candidate, dict):
            raise LifecycleError("missing durable accepted candidate")
        observed = tuple(candidate.get(key, "") for key in ("headSha", "treeSha", "campaignBinding"))
        expected = (args.head, args.tree, args.campaign)
        if observed != expected:
            raise LifecycleError("candidate compare-and-set failed")
        candidate["state"] = "integration-blocked"
        candidate["nextAction"] = args.next_action
        candidate["recoveryBlock"] = {
            "reason": args.reason,
            "targetHead": args.target_head,
            "observedAt": now(),
        }
        lease["status"] = "accepted"
        lease["nextAction"] = args.next_action
        lease["updatedAt"] = now()


def candidate_integrated(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    with locked(lease_path) as lease:
        candidate = lease.get("acceptedCandidate")
        if not isinstance(candidate, dict):
            raise LifecycleError("missing durable accepted candidate")
        observed = tuple(candidate.get(key, "") for key in ("headSha", "treeSha", "campaignBinding"))
        expected = (args.head, args.tree, args.campaign)
        if observed != expected:
            raise LifecycleError("candidate compare-and-set failed")
        proof = candidate.get("integrationProof")
        if not isinstance(proof, dict) or proof.get("proofId") != args.proof_id:
            raise LifecycleError("candidate integration proof changed before publication")
        candidate.update({"state": "integrated", "mergeCommit": args.merge, "integratedAt": now()})
        authority = lease.get("recoveryAuthorization")
        if isinstance(authority, dict) and authority.get("state") in {"claimed", "audit-accepted", "gate-passed"}:
            authority["state"] = "published"
            authority["publishedAt"] = now()
            authority["mergeCommit"] = args.merge
        lease["status"] = "integrated"
        lease["nextAction"] = "none"
        lease["updatedAt"] = now()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)
    reserve_p = commands.add_parser("reserve")
    for flag in ("lease", "task", "owner", "run", "branch", "area", "scope_json", "base", "batch", "worktree", "imported_dir"):
        reserve_p.add_argument("--" + flag.replace("_", "-"), required=True)
    reserve_p.add_argument("--deadline-seconds", type=int, default=14400)
    reserve_p.add_argument("--campaign", default="legacy")
    reserve_p.add_argument("--repo-root", default="")
    reserve_p.add_argument("--engine-source-fingerprint", default="legacy")
    reserve_p.set_defaults(action=reserve)

    bind = commands.add_parser("bind-dispatch")
    for flag in ("record", "task", "run", "pid_start", "log", "base", "batch", "owner"):
        bind.add_argument("--" + flag.replace("_", "-"), required=True)
    bind.add_argument("--pid", type=int, required=True)
    bind.add_argument("--pgid", type=int, default=0)
    bind.add_argument("--generation", type=int, required=True)
    bind.add_argument("--campaign", default="legacy")
    bind.set_defaults(action=bind_dispatch)

    attempt = commands.add_parser("record-attempt")
    for flag in ("lease", "record", "task", "owner", "run", "reservation_run", "campaign", "state"):
        attempt.add_argument("--" + flag.replace("_", "-"), required=True)
    attempt.add_argument("--generation", type=int, required=True)
    attempt.add_argument("--disposition", default="")
    attempt.add_argument("--failure-class", default="")
    attempt.add_argument("--action", dest="terminal_action", default="")
    attempt.set_defaults(action=record_attempt)

    exit_p = commands.add_parser("write-exit")
    for flag in ("record", "exit_file", "owner"):
        exit_p.add_argument("--" + flag.replace("_", "-"), required=True)
    exit_p.add_argument("--generation", type=int, required=True)
    exit_p.add_argument("--exit-code", type=int, required=True)
    exit_p.set_defaults(action=write_exit)

    read_p = commands.add_parser("read-exit")
    read_p.add_argument("--record", required=True)
    read_p.add_argument("--exit-file", required=True)
    read_p.set_defaults(action=read_exit)

    finish_p = commands.add_parser("finish")
    for flag in ("lease", "record", "task", "owner", "batch", "reason", "next_action", "reservation_run", "campaign"):
        finish_p.add_argument("--" + flag.replace("_", "-"), required=True)
    finish_p.add_argument("--generation", type=int, required=True)
    finish_p.set_defaults(action=finish)

    legacy = commands.add_parser("legacy-finish")
    for flag in ("lease", "lease_sha", "new_status", "reason", "next_action"):
        legacy.add_argument("--" + flag.replace("_", "-"), required=True)
    legacy.set_defaults(action=legacy_finish)

    finalize_p = commands.add_parser("finalize")
    for flag in ("record", "exit_file", "owner", "outcome"):
        finalize_p.add_argument("--" + flag.replace("_", "-"), required=True)
    finalize_p.add_argument("--generation", type=int, required=True)
    finalize_p.add_argument("--exit-code", type=int, required=True)
    finalize_p.set_defaults(action=finalize)

    orphan = commands.add_parser("reconcile-orphan-reservation")
    for flag in (
        "lease", "record", "task", "owner", "run", "campaign",
        "reservation_base", "candidate_source", "worktree",
    ):
        orphan.add_argument("--" + flag.replace("_", "-"), required=True)
    orphan.add_argument("--generation", type=int, required=True)
    orphan.set_defaults(action=reconcile_orphan_reservation)

    continuation = commands.add_parser("authorize-continuation")
    for flag in (
        "lease", "authority", "task_contract", "expected_task", "expected_campaign",
        "predecessor_owner", "predecessor_run", "predecessor_campaign",
        "predecessor_reservation_base", "candidate_source", "candidate_base", "integration_target",
        "integration_target_branch", "target_head_at_authorization",
        "engine_source_fingerprint", "worktree",
    ):
        continuation.add_argument("--" + flag.replace("_", "-"), required=True)
    continuation.add_argument("--predecessor-generation", type=int, required=True)
    continuation.set_defaults(action=authorize_continuation)

    claim_cont = commands.add_parser("claim-continuation")
    for flag in (
        "lease", "record", "task", "task_contract", "authorization_id", "owner", "reservation_run",
        "campaign", "candidate_source", "candidate_base", "integration_target",
        "engine_source_fingerprint", "repo_root", "reservation_base", "worktree", "run",
    ):
        claim_cont.add_argument("--" + flag.replace("_", "-"), required=True)
    claim_cont.add_argument("--generation", type=int, required=True)
    claim_cont.set_defaults(action=claim_continuation)

    rearm_cont = commands.add_parser("rearm-continuation-preparation")
    for flag in ("lease", "authorization_id", "evidence"):
        rearm_cont.add_argument("--" + flag.replace("_", "-"), required=True)
    rearm_cont.set_defaults(action=rearm_continuation_preparation)

    retain = commands.add_parser("retain-candidate")
    for flag in ("lease", "packet", "audit", "task_file", "task", "run", "branch", "head", "tree", "campaign", "acceptance_mode"):
        retain.add_argument("--" + flag.replace("_", "-"), required=True)
    retain.add_argument("--verification-request", default="")
    retain.add_argument("--verification-report", default="")
    retain.add_argument("--verification-policy", default="")
    retain.set_defaults(action=retain_candidate)

    check = commands.add_parser("candidate-check")
    for flag in ("lease", "head", "tree", "campaign", "target_head", "invalidation_key"):
        check.add_argument("--" + flag.replace("_", "-"), required=True)
    check.add_argument("--branch-key", default="")
    check.set_defaults(action=candidate_check)

    failed = commands.add_parser("candidate-failed")
    for flag in ("lease", "head", "tree", "campaign", "failure_class", "target_head", "invalidation_key", "next_action"):
        failed.add_argument("--" + flag.replace("_", "-"), required=True)
    failed.add_argument("--failure-id", default="")
    failed.add_argument("--domain", choices=("product", "infrastructure", "regate"), default="")
    failed.set_defaults(action=candidate_failed)

    authorize = commands.add_parser("authorize-recovery")
    for flag in ("lease", "authority", "task_contract", "expected_task", "expected_campaign", "expected_policy"):
        authorize.add_argument("--" + flag.replace("_", "-"), required=True)
    authorize.set_defaults(action=authorize_recovery)

    claim = commands.add_parser("claim-recovery")
    for flag in ("lease", "authorization_id", "head", "tree", "campaign", "run"):
        claim.add_argument("--" + flag.replace("_", "-"), required=True)
    claim.add_argument("--action", dest="recovery_action", choices=("repair", "regate"), required=True)
    claim.add_argument("--owner", default="")
    claim.add_argument("--generation", type=int, default=0)
    claim.add_argument("--reservation-run", default="")
    claim.set_defaults(action=claim_recovery)

    repair_eligible = commands.add_parser("repair-dispatch-eligible")
    repair_eligible.add_argument("--lease", required=True)
    repair_eligible.add_argument("--task-contract", required=True)
    repair_eligible.set_defaults(action=check_repair_dispatch_eligible)

    publication = commands.add_parser("validate-accepted-publication")
    for flag in (
        "lease", "packet", "audit", "task_contract", "task", "run", "branch",
        "worktree", "base", "head", "campaign", "repo_root",
    ):
        publication.add_argument("--" + flag.replace("_", "-"), required=True)
    publication.set_defaults(action=validate_accepted_publication)

    tested = commands.add_parser("candidate-tested")
    for flag in (
        "lease", "head", "tree", "campaign", "tested_tree", "target_parent",
        "candidate_parent", "synthetic_commit", "gate_run", "gate_report", "gate_command",
    ):
        tested.add_argument("--" + flag.replace("_", "-"), required=True)
    tested.set_defaults(action=candidate_tested)

    proof = commands.add_parser("candidate-proof")
    for flag in ("lease", "head", "tree", "campaign", "gate_command"):
        proof.add_argument("--" + flag.replace("_", "-"), required=True)
    proof.set_defaults(action=candidate_proof)

    blocked = commands.add_parser("candidate-blocked")
    for flag in ("lease", "head", "tree", "campaign", "reason", "target_head", "next_action"):
        blocked.add_argument("--" + flag.replace("_", "-"), required=True)
    blocked.set_defaults(action=candidate_blocked)

    integrated = commands.add_parser("candidate-integrated")
    for flag in ("lease", "head", "tree", "campaign", "merge", "proof_id"):
        integrated.add_argument("--" + flag.replace("_", "-"), required=True)
    integrated.set_defaults(action=candidate_integrated)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.action(args)
    except LifecycleError as exc:
        print(f"lifecycle: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
