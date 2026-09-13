#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_dir=""
task_id=""
worktree=""
base_ref=""
head_sha=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --task-id) task_id="${2:-}"; shift 2 ;;
    --worktree) worktree="${2:-}"; shift 2 ;;
    --base-ref) base_ref="${2:-}"; shift 2 ;;
    --head-sha) head_sha="${2:-}"; shift 2 ;;
    *) echo "evidence-manifest: unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$run_dir" && -d "$run_dir" ]] || {
  echo "evidence-manifest: --run-dir is required" >&2
  exit 2
}
[[ "$task_id" =~ ^TASK-[0-9]{4,}$ ]] || {
  echo "evidence-manifest: valid --task-id is required" >&2
  exit 2
}
[[ -n "$worktree" && -d "$worktree/.git" || -f "$worktree/.git" ]] || {
  echo "evidence-manifest: --worktree must be a git worktree" >&2
  exit 2
}
[[ -n "$base_ref" && -n "$head_sha" ]] || {
  echo "evidence-manifest: --base-ref and --head-sha are required" >&2
  exit 2
}

out="$run_dir/evidence-manifest.json"
tmp="$out.tmp.$$"
trap 'rm -f "$tmp"' EXIT

python3 - "$run_dir" "$task_id" "$worktree" "$base_ref" "$head_sha" "$tmp" "$SCRIPT_DIR" <<'PY'
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys

run_dir = pathlib.Path(sys.argv[1]).resolve()
task_id, worktree_raw, base_ref, head_sha, output_raw, engine_dir = sys.argv[2:8]
worktree = pathlib.Path(worktree_raw).resolve()
output = pathlib.Path(output_raw)
sys.path.insert(0, engine_dir)
from git_changes import GitChangeError, committed_paths, require_ancestor
defaults = {
    "maxComposedBytes": 262144,
    "maxExcerptBytes": 2048,
    "retrievalBudgetBytes": 262144,
    "auditInputTokenCanary": 100000,
}
hard_max = dict(defaults)
try:
    configured = json.loads(os.environ.get("SINGULAR_EVIDENCE_CONFIG_JSON", "{}"))
except json.JSONDecodeError:
    configured = {}
if not isinstance(configured, dict):
    configured = {}

def bounded_config(name, *, allow_zero=False):
    value = configured.get(name, defaults[name])
    minimum = 0 if allow_zero else 1
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < minimum
        or value > hard_max[name]
    ):
        return defaults[name]
    return value

limit_bytes = bounded_config("maxComposedBytes")
excerpt_limit = min(
    bounded_config("maxExcerptBytes"),
    limit_bytes,
)
retrieval_limit = bounded_config("retrievalBudgetBytes", allow_zero=True)
audit_input_token_canary = bounded_config("auditInputTokenCanary")

def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()

def sha_file(path):
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def git(*args, text=False):
    return subprocess.run(
        ["git", "-C", str(worktree), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    ).stdout

def inside(base, candidate):
    try:
        candidate.resolve().relative_to(base.resolve())
        return True
    except (OSError, ValueError):
        return False

def resolve_log(ref):
    if not isinstance(ref, str) or not ref:
        return None
    raw = pathlib.Path(ref)
    candidates = [raw] if raw.is_absolute() else [run_dir / raw, worktree / raw]
    for candidate in candidates:
        if candidate.is_file() and (inside(run_dir, candidate) or inside(worktree, candidate)):
            return candidate.resolve()
    return None

def excerpt(path):
    if not path:
        return None
    data = path.read_bytes()[:excerpt_limit]
    text = data.decode("utf-8", errors="replace")
    if path.stat().st_size > excerpt_limit:
        text += "\n[truncated at capture]"
    return text[:excerpt_limit]

def artifact_ref(path):
    path = path.resolve()
    if inside(run_dir, path):
        return path.relative_to(run_dir).as_posix()
    if inside(worktree, path):
        return "worktree/" + path.relative_to(worktree).as_posix()
    raise ValueError("artifact outside allowed roots")

try:
    resolved_base, resolved_head = require_ancestor(worktree, base_ref, head_sha)
except (GitChangeError, OSError, UnicodeError):
    sys.stderr.write("evidence-manifest: invalid base/head lineage\n")
    sys.exit(2)

try:
    diff = git("diff", "--binary", f"{resolved_base}...{resolved_head}")
    changed = committed_paths(worktree, resolved_base, resolved_head)
except (subprocess.CalledProcessError, GitChangeError, OSError, UnicodeError):
    sys.stderr.write("evidence-manifest: Git evidence collection failed\n")
    sys.exit(2)
diff_artifact = run_dir / "committed.diff"
diff_temporary = diff_artifact.with_name(diff_artifact.name + ".tmp")
diff_temporary.write_bytes(diff)
diff_temporary.replace(diff_artifact)

files = []
for name in changed:
    try:
        data = git("show", f"{resolved_head}:{name}")
    except subprocess.CalledProcessError:
        # A missing path at the candidate is an owned deletion or rename source.
        data = b""
    files.append({"path": name, "sha256": sha_bytes(data)})

packet = {}
packet_path = run_dir / "packet.json"
if packet_path.is_file():
    try:
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        sys.stderr.write("evidence-manifest: invalid packet input\n")
        sys.exit(2)
if packet_path.is_file():
    if packet.get("schema") != "singular.orchestration.state-packet.v0":
        sys.stderr.write("evidence-manifest: unsupported packet schema\n")
        sys.exit(2)
    expected_packet = {
        "taskId": task_id,
        "runId": run_dir.name,
        "headSha": resolved_head,
        "baseRef": resolved_base,
        "changedFiles": changed,
    }
    if any(packet.get(key) != value for key, value in expected_packet.items()):
        sys.stderr.write("evidence-manifest: packet base/head/delta identity mismatch\n")
        sys.exit(2)

gate = {}
gate_record_path = None
for gate_name in ("gate-report.json", "gate-check.json"):
    gate_path = run_dir / gate_name
    if gate_path.is_file():
        try:
            gate = json.loads(gate_path.read_text(encoding="utf-8"))
            gate_record_path = gate_path
            break
        except (OSError, json.JSONDecodeError):
            pass

commands = []
for index, command in enumerate(packet.get("commands", [])):
    if not isinstance(command, dict):
        continue
    ref = command.get("logRef")
    log_path = resolve_log(ref)
    exit_code = command.get("exitCode")
    if not isinstance(exit_code, int):
        exit_code = 1
    item = {
        "name": str(command.get("name") or f"packet-command-{index + 1}"),
        "command": str(command.get("cmd") or command.get("command") or "(unspecified)"),
        "exitCode": exit_code,
        "status": "passed" if exit_code == 0 else "failed-product",
        "durationMs": max(0, int(command.get("durationMs") or 0)),
        "logRef": artifact_ref(log_path) if log_path else str(ref or "unavailable"),
        "logSha256": sha_file(log_path) if log_path else sha_bytes(b""),
    }
    captured = excerpt(log_path)
    if captured:
        item["excerpt"] = captured
    commands.append(item)

gate_log = run_dir / "gate-check.log"
if gate:
    raw_exit = gate.get("rawExitCode", gate.get("exitCode", 1))
    if not isinstance(raw_exit, int):
        raw_exit = 1
    outcome = str(gate.get("outcome") or ("passed" if raw_exit == 0 else "failed-product"))
    status_map = {
        "passed": "passed",
        "passed-with-acknowledged-baseline": "passed",
        "not-rerun-evidence-verified": "passed",
        "failed-product": "failed-product",
        "inconclusive-infrastructure": "inconclusive-infrastructure",
    }
    item = {
        "name": "regression-gate",
        "command": str(gate.get("command") or "(gate command)"),
        "exitCode": raw_exit,
        "status": status_map.get(outcome, "failed-product"),
        "durationMs": max(0, int(gate.get("durationMs") or 0)),
        "logRef": "gate-check.log",
        "logSha256": sha_file(gate_log) if gate_log.is_file() else sha_bytes(b""),
    }
    captured = excerpt(gate_log if gate_log.is_file() else None)
    if captured:
        item["excerpt"] = captured
    commands.append(item)

audit_verification = {}
audit_verification_path = run_dir / "audit-verification.json"
if audit_verification_path.is_file():
    try:
        audit_verification = json.loads(
            audit_verification_path.read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        audit_verification = {}
if audit_verification:
    audit_log = resolve_log(audit_verification.get("logRef"))
    raw_exit = audit_verification.get("rawExitCode", 1)
    if not isinstance(raw_exit, int):
        raw_exit = 1
    outcome = str(audit_verification.get("outcome") or "inconclusive-infrastructure")
    status_map = {
        "passed": "passed",
        "passed-with-acknowledged-baseline": "passed",
        "not-rerun-evidence-verified": "passed",
        "failed-product": "failed-product",
        "inconclusive-infrastructure": "inconclusive-infrastructure",
    }
    item = {
        "name": "audit-verification-gate",
        "command": str(audit_verification.get("command") or "(gate command)"),
        "exitCode": raw_exit,
        "status": status_map.get(outcome, "inconclusive-infrastructure"),
        "durationMs": max(0, int(audit_verification.get("durationMs") or 0)),
        "logRef": artifact_ref(audit_log) if audit_log else "audit-verification.log",
        "logSha256": sha_file(audit_log) if audit_log else sha_bytes(b""),
    }
    captured = excerpt(audit_log)
    if captured:
        item["excerpt"] = captured
    commands.append(item)

artifacts = []
artifact_candidates = [
    run_dir / "gate-check.log",
    run_dir / "gate-check.json",
    run_dir / "gate-report.json",
    run_dir / "scope-check.log",
    run_dir / "secret-scan.log",
    run_dir / "packet.json",
    run_dir / "audit.json",
    run_dir / "audit-verification.json",
    run_dir / "worker-codex.log",
    run_dir / "auditor-codex.log",
    diff_artifact,
    run_dir / "scope-check-result.json",
    run_dir / "secret-scan-result.json",
]
artifact_candidates.extend(run_dir.glob("*runner-result.json"))
artifact_candidates.extend(run_dir.glob("*provider-error.json"))
artifact_candidates.extend(run_dir.glob("*provider-envelope.raw"))
artifact_candidates.extend(run_dir.glob("*provider-event.json"))
artifact_candidates.extend(run_dir.glob("reaudit-diff-attempt-*.patch"))
if audit_verification:
    audit_log = resolve_log(audit_verification.get("logRef"))
    if audit_log:
        artifact_candidates.append(audit_log)
worker_evidence = run_dir / "worker-evidence"
if worker_evidence.is_dir():
    artifact_candidates.extend(p for p in worker_evidence.rglob("*") if p.is_file())
seen = set()
for path in artifact_candidates:
    if not path.is_file():
        continue
    ref = artifact_ref(path)
    if ref in seen:
        continue
    seen.add(ref)
    artifacts.append({"ref": ref, "sha256": sha_file(path), "bytes": path.stat().st_size})

expected = gate.get("expectedFailures", [])
unexpected = gate.get("unexpectedFailures", [])
if not isinstance(expected, list):
    expected = []
if not isinstance(unexpected, list):
    unexpected = []
gate_outcome = str(gate.get("outcome") or ("passed" if gate.get("exitCode") == 0 else "failed"))

def structured_check(check, result_name):
    result_path = run_dir / result_name
    if not result_path.is_file():
        return {"status": "not-run"}
    record_ref = artifact_ref(result_path)
    output = {
        "status": "inconclusive",
        "ref": record_ref,
        "sha256": sha_file(result_path),
    }
    try:
        record = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return output
    status = record.get("status")
    exit_code = record.get("exitCode")
    if (
        record.get("schema") != "singular.orchestration.check-result.v0"
        or record.get("check") != check
        or status not in {"passed", "failed", "not-run", "inconclusive"}
        or not isinstance(exit_code, int)
        or isinstance(exit_code, bool)
        or (status == "passed" and exit_code != 0)
        or (status == "failed" and exit_code == 0)
    ):
        return output
    log_ref = record.get("logRef")
    log_sha = record.get("logSha256")
    if log_ref:
        log_path = pathlib.Path(str(log_ref))
        if not log_path.is_absolute():
            log_path = run_dir / log_path
        if (
            not log_path.is_file()
            or not isinstance(log_sha, str)
            or sha_file(log_path) != log_sha
        ):
            return output
    elif log_sha is not None or status not in {"not-run", "inconclusive"}:
        return output
    output["status"] = status
    return output

gate_check = {"status": "not-run"}
if gate_record_path is not None:
    gate_check = {
        "status": "inconclusive",
        "ref": artifact_ref(gate_record_path),
        "sha256": sha_file(gate_record_path),
    }
    gate_valid = gate.get("schema") == "singular.orchestration.gate-report.v0"
    gate_command = gate.get("command")
    gate_valid = gate_valid and isinstance(gate_command, str) and bool(gate_command)
    gate_valid = gate_valid and gate.get("commandSha256") == sha_bytes(
        gate_command.encode("utf-8")
    )
    gate_valid = gate_valid and gate.get("headSha") == resolved_head
    gate_integrity = gate.get("sourceIntegrity")
    gate_valid = gate_valid and isinstance(gate_integrity, dict)
    gate_valid = gate_valid and gate_integrity.get("status") == "verified"
    # logPath (0.15.1) is the absolute filesystem location; logRef is a
    # REPOSITORY-relative citation for dag.sh. This reader resolves a relative
    # ref against the RUN directory, so once logRef went repo-relative the
    # lookup missed and every gate check silently downgraded to inconclusive.
    # Prefer logPath and keep the old resolution as the fallback.
    gate_log_ref = gate.get("logPath") or gate.get("logRef")
    gate_log_sha = gate.get("logSha256")
    if isinstance(gate_log_ref, str) and gate_log_ref:
        gate_log_path = pathlib.Path(gate_log_ref)
        if not gate_log_path.is_absolute():
            gate_log_path = run_dir / gate_log_path
        gate_valid = (
            gate_valid
            and gate_log_path.is_file()
            and isinstance(gate_log_sha, str)
            and sha_file(gate_log_path) == gate_log_sha
        )
    else:
        gate_valid = False
    if gate_valid:
        if gate_outcome in {"passed", "passed-with-acknowledged-baseline"}:
            gate_check["status"] = "passed"
        elif gate_outcome == "failed-product":
            gate_check["status"] = "failed"
        elif gate_outcome == "inconclusive-infrastructure":
            gate_check["status"] = "inconclusive"

scope_check = structured_check("scope", "scope-check-result.json")
secret_check = structured_check("secret", "secret-scan-result.json")
if changed and secret_check.get("status") != "passed":
    sys.stderr.write("evidence-manifest: committed delta lacks a passing secret scan\n")
    sys.exit(2)

# Refresh cannot reset the retrieval domain by dropping an existing binding.
prior_binding = None
prior_path = run_dir / "evidence-manifest.json"
if prior_path.is_file():
    try:
        prior = json.loads(prior_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        sys.stderr.write("evidence-manifest: existing manifest is invalid\n")
        sys.exit(2)
    if prior.get("schema") != "singular.orchestration.evidence-manifest.v0":
        sys.stderr.write("evidence-manifest: existing manifest schema is invalid\n")
        sys.exit(2)
    if prior.get("taskId") != task_id or prior.get("runId") != run_dir.name:
        sys.stderr.write("evidence-manifest: existing manifest identity mismatch\n")
        sys.exit(2)
    prior_binding = prior.get("campaignBinding", "legacy")
campaign_binding = os.environ.get("SINGULAR_EVIDENCE_CAMPAIGN_BINDING", prior_binding or "legacy")
if prior_binding is not None and campaign_binding != prior_binding:
    sys.stderr.write("evidence-manifest: refresh cannot change campaign identity\n")
    sys.exit(2)

manifest = {
    "schema": "singular.orchestration.evidence-manifest.v0",
    "taskId": task_id,
    "runId": run_dir.name,
    "headSha": resolved_head,
    "campaignBinding": campaign_binding,
    "diffSha256": sha_bytes(diff),
    "files": files,
    "commands": commands,
    "expectedFailureCount": len(expected),
    "unexpectedFailureCount": len(unexpected),
    "checks": {
        "scope": scope_check,
        "secret": secret_check,
        "gate": gate_check,
    },
    "artifacts": artifacts,
    "budget": {
        "limitBytes": limit_bytes,
        "composedBytes": 0,
        "excerptLimitBytes": excerpt_limit,
        "retrievalLimitBytes": retrieval_limit,
        "auditInputTokenCanary": audit_input_token_canary,
        "actualAuditInputTokens": 0,
    },
    "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
}

usage = {"inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0}
usage_seen = False
audit_input_tokens = 0
for result_path in run_dir.glob("*runner-result.json"):
    try:
        result = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    counters = result.get("usage")
    if not isinstance(counters, dict):
        continue
    role = str(result.get("role") or "")
    is_auditor = role in {"auditor", "reviewer"} or result_path.name.startswith("auditor-")
    for key in usage:
        value = counters.get(key)
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            usage[key] += value
            usage_seen = True
            if is_auditor and key == "inputTokens":
                audit_input_tokens += value
if usage_seen:
    manifest["providerUsage"] = usage
manifest["budget"]["actualAuditInputTokens"] = audit_input_tokens
if audit_input_tokens >= audit_input_token_canary:
    # This is an observability canary, not product or evidence authority.  The
    # manifest is still complete and hash-bound when the threshold is crossed;
    # refusing to write it here used to discard an already completed auditor
    # verdict during the final refresh.  Keep the inclusive warning so operators
    # can tune prompt size, but never let telemetry reinterpret product review.
    sys.stderr.write(
        "evidence-manifest: warning: auditor input-token canary exceeded "
        f"({audit_input_tokens} >= {audit_input_token_canary})\n"
    )

for _ in range(3):
    encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    manifest["budget"]["composedBytes"] = len(encoded)
encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
if len(encoded) > limit_bytes:
    sys.stderr.write(
        f"evidence-manifest: composed evidence exceeds {limit_bytes} bytes ({len(encoded)})\n"
    )
    sys.exit(2)
output.write_bytes(encoded)
PY

mv "$tmp" "$out"
trap - EXIT
printf '%s\n' "$out"
