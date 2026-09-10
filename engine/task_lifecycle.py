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
import fcntl
import hashlib
import json
import os
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


def reserve(args: argparse.Namespace) -> None:
    lease_path = Path(args.lease)
    with locked(lease_path, missing=True) as lease:
        if lease.get("taskId") not in (None, "", args.task):
            raise LifecycleError("lease task identity mismatch")
        candidate = lease.get("acceptedCandidate")
        if isinstance(candidate, dict) and candidate.get("state") != "integrated":
            raise LifecycleError("durable accepted candidate requires integration recovery, not redispatch")
        imported_dir = Path(args.imported_dir)
        if imported_dir.is_dir():
            for packet_path in sorted(imported_dir.glob("*.json")):
                if packet_path.name.endswith(".audit.json"):
                    continue
                packet = read_object(packet_path)
                if packet.get("taskId") == args.task and packet.get("status") == "accepted":
                    raise LifecycleError(
                        f"accepted packet {packet_path.name} requires integration, not redispatch"
                    )
        status = str(lease.get("status", ""))
        if status in {"accepted", "integrated"}:
            raise LifecycleError(f"{status} work cannot be reserved for implementation")
        current_owner = str(lease.get("reservationOwner", ""))
        current_generation = max(
            int(lease.get("reservationGeneration", 0) or 0),
            int(lease.get("lastReservationGeneration", 0) or 0),
        )
        if status in ACTIVE and current_owner:
            if current_owner == args.owner and lease.get("reservationRunId") == args.run:
                print(current_generation)
                return
            raise LifecycleError(f"reservation already owned by {current_owner}@{current_generation}")
        generation = current_generation + 1
        timestamp = now()
        lease.update({
            "taskId": args.task,
            "branch": args.branch,
            "area": args.area,
            "owner": args.owner,
            "fileScope": " ".join(json.loads(args.scope_json)),
            "ownedFiles": json.loads(args.scope_json),
            "baseSha": args.base,
            "batchId": args.batch,
            "runId": args.run,
            "worktree": args.worktree,
            "status": "planned",
            "reservationOwner": args.owner,
            "reservationGeneration": generation,
            "reservationRunId": args.run,
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
        print(generation)


def bind_dispatch(args: argparse.Namespace) -> None:
    record_path = Path(args.record)
    with locked(record_path, missing=True) as record:
        if record.get("state") == "launched" and not reservation_matches(
            record, args.owner, args.generation
        ):
            raise LifecycleError("dispatch record already belongs to another reservation")
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
        })


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
            # Native l1-drive currently rewrites compatibility lease fields and
            # therefore drops the reservation token. In that case the locked
            # dispatch token remains the CAS authority; task, branch, base and
            # batch must still match before cleanup may touch the lease.
            if lease.get("taskId") != args.task:
                raise LifecycleError("lease task changed before reservation cleanup")
            if args.batch and lease.get("batchId") not in (None, "", args.batch):
                raise LifecycleError("lease batch changed before reservation cleanup")
            status = str(lease.get("status", ""))
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
                lease["status"] = "failed"
                lease["failureReason"] = args.reason
                lease["nextAction"] = args.next_action
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
    if args.acceptance_mode == "accepted":
        audit_path = Path(args.audit)
        audit = read_object(audit_path)
        for field, expected in (("taskId", args.task), ("runId", args.run), ("branch", args.branch)):
            if str(audit.get(field, "")) != expected:
                raise LifecycleError(f"audit {field} binding mismatch")
        if audit.get("verdict") != "accepted":
            raise LifecycleError("audit verdict is not accepted")
    task_path = Path(args.task_file)
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
        for failure in reversed(candidate.get("failures") or []):
            if isinstance(failure, dict) and (
                failure.get("failureClass") in {"gate-red", "integration-conflict"}
                and failure.get("invalidationKey") == args.invalidation_key
            ):
                print(
                    failure.get("nextAction")
                    or candidate.get("nextAction")
                    or "repair the candidate or change an invalidating input"
                )
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
        key = f"{args.failure_class}:{args.target_head}:{args.head}:{args.invalidation_key}"
        if not any(isinstance(item, dict) and item.get("key") == key for item in failures):
            failures.append({
                "key": key,
                "failureClass": args.failure_class,
                "targetHead": args.target_head,
                "invalidationKey": args.invalidation_key,
                "nextAction": args.next_action,
                "observedAt": now(),
            })
        candidate["state"] = "integration-failed"
        candidate["nextAction"] = args.next_action
        # A failed attempt cannot leave a gate receipt that could later be
        # mistaken for authority to finalize a manually-created merge.
        candidate.pop("integrationProof", None)
        lease["status"] = "accepted"
        lease["nextAction"] = args.next_action
        lease["updatedAt"] = now()


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
    reserve_p.set_defaults(action=reserve)

    bind = commands.add_parser("bind-dispatch")
    for flag in ("record", "task", "run", "pid_start", "log", "base", "batch", "owner"):
        bind.add_argument("--" + flag.replace("_", "-"), required=True)
    bind.add_argument("--pid", type=int, required=True)
    bind.add_argument("--pgid", type=int, default=0)
    bind.add_argument("--generation", type=int, required=True)
    bind.set_defaults(action=bind_dispatch)

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
    for flag in ("lease", "record", "task", "owner", "batch", "reason", "next_action"):
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

    retain = commands.add_parser("retain-candidate")
    for flag in ("lease", "packet", "audit", "task_file", "task", "run", "branch", "head", "tree", "campaign", "acceptance_mode"):
        retain.add_argument("--" + flag.replace("_", "-"), required=True)
    retain.set_defaults(action=retain_candidate)

    check = commands.add_parser("candidate-check")
    for flag in ("lease", "head", "tree", "campaign", "target_head", "invalidation_key"):
        check.add_argument("--" + flag.replace("_", "-"), required=True)
    check.set_defaults(action=candidate_check)

    failed = commands.add_parser("candidate-failed")
    for flag in ("lease", "head", "tree", "campaign", "failure_class", "target_head", "invalidation_key", "next_action"):
        failed.add_argument("--" + flag.replace("_", "-"), required=True)
    failed.set_defaults(action=candidate_failed)

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
