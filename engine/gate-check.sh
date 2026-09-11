#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

run_id="${1:-RUN-$(date -u +%Y%m%dT%H%M%SZ)}"
shift || true

task_id="${SINGULAR_GATE_TASK_ID:-TASK-0000}"
phase="${SINGULAR_GATE_PHASE:-other}"
workspace_kind="${SINGULAR_GATE_WORKSPACE_KIND:-worker}"
verification_request=""
verification_task_contract=""
verification_policy_contract=""
verification_attempt=""
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --task-id) task_id="${2:-}"; shift 2 ;;
    --phase) phase="${2:-}"; shift 2 ;;
    --workspace-kind) workspace_kind="${2:-}"; shift 2 ;;
    --verification-request) verification_request="${2:-}"; shift 2 ;;
    --task-contract) verification_task_contract="${2:-}"; shift 2 ;;
    --policy-contract) verification_policy_contract="${2:-}"; shift 2 ;;
    --attempt) verification_attempt="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [[ -n "$verification_task_contract" && -z "$verification_request" ]]; then
  canonical_task_contract="$SINGULAR_TASKS_DIR/$task_id.md"
  if ! python3 - "$verification_task_contract" "$canonical_task_contract" "$task_id" <<'PY'
import pathlib
import re
import sys

provided, canonical, task_id = map(str, sys.argv[1:4])
provided_path = pathlib.Path(provided).resolve()
canonical_path = pathlib.Path(canonical).resolve()
if provided_path != canonical_path or not provided_path.is_file():
    raise SystemExit("gate-check: task contract is not the canonical task record")
text = provided_path.read_text(encoding="utf-8")
match = re.search(r"^#\s+(TASK-[0-9]{4,})(?::|\s|$)", text, re.MULTILINE)
if not match or match.group(1) != task_id:
    raise SystemExit("gate-check: task contract identity mismatch")
PY
  then
    exit 2
  fi
  export SINGULAR_TEST_TASK_CONTRACT="$verification_task_contract"
  export SINGULAR_TEST_TASK_ID="$task_id"
  export SINGULAR_TEST_TASKS_DIR="$SINGULAR_TASKS_DIR"
fi

trusted_gate_command=""
verification_expected_head=""
verification_expected_tree=""
if [[ -n "$verification_request" ]]; then
  [[ -n "$verification_task_contract" && -n "$verification_policy_contract" ]] || {
    echo "gate-check: verification request requires trusted task and policy contracts" >&2
    exit 2
  }
  [[ "$verification_attempt" =~ ^[1-9][0-9]*$ ]] || {
    echo "gate-check: verification request requires a positive --attempt" >&2
    exit 2
  }
  actual_request_head="$(git -C "$PWD" rev-parse HEAD 2>/dev/null || true)"
  actual_request_tree="$(git -C "$PWD" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  [[ "$actual_request_head" =~ ^[0-9a-f]{40,64}$ \
      && "$actual_request_tree" =~ ^[0-9a-f]{40,64}$ ]] || {
    echo "gate-check: current candidate identity is unavailable" >&2
    exit 2
  }
  verification_expected_head="$actual_request_head"
  verification_expected_tree="$actual_request_tree"
  verification_expected_campaign="$(singular_campaign_binding 2>/dev/null)" || {
    echo "gate-check: current campaign identity is unavailable" >&2
    exit 2
  }
  resolve_args=(
    resolve-verification-request
    --request "$verification_request"
    --task-contract "$verification_task_contract"
    --policy-contract "$verification_policy_contract"
    --expected-task "$task_id"
    --expected-run "$run_id"
    --expected-head "$verification_expected_head"
    --expected-tree "$verification_expected_tree"
    --expected-attempt "$verification_attempt"
    --expected-suite task-contract-gate
    --expected-campaign "$verification_expected_campaign"
  )
  current_task_contract="$SINGULAR_TASKS_DIR/$task_id.md"
  [[ -f "$current_task_contract" ]] \
    && resolve_args+=(--current-task-contract "$current_task_contract")
  trusted_gate_command="$(python3 "$SCRIPT_DIR/gate-report.py" "${resolve_args[@]}")" || exit 2
  # Shell interpretation is host-owned and only applied to the command read
  # from the trusted task contract. No packet/request command is accepted.
  set -- "$(singular_bash_bin)" -c "$trusted_gate_command"
fi

if [[ $# -eq 0 ]]; then
  set -- make check
fi

run_dir="$SINGULAR_STATE_DIR/runs/$run_id"
mkdir -p "$run_dir"
log="$run_dir/gate-check.log"
observation="$run_dir/gate-observation.json"
report="$run_dir/gate-report.json"
summary="$run_dir/gate-check.json" # compatibility mirror
if [[ -n "$verification_request" ]]; then
  command_text="$trusted_gate_command"
else
  command_text="$*"
fi
head_sha="$(git -C "$PWD" rev-parse HEAD 2>/dev/null || printf '%040d' 0)"
started_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000)')"
rm -f "$observation" "$report" "$summary"
source_before="$run_dir/gate-source-before.json"
source_after="$run_dir/gate-source-after.json"
status_before="$run_dir/gate-status-before.txt"
status_after="$run_dir/gate-status-after.txt"
integrity_status="verified"
changed_paths=()
if ! singular_tracked_source_snapshot "$PWD" "$source_before" >"$run_dir/gate-source-snapshot.err" 2>&1; then
  integrity_status="violation"
  changed_paths+=("source-integrity-snapshot-failed")
fi
git -C "$PWD" status --porcelain=v1 --untracked-files=all 2>/dev/null \
  | sed -E '\#^.. (\.singular-state|\.singular-cache|\.singular-evidence)(/|$)#d' \
  >"$status_before" || true

gate_cache_requested="${SINGULAR_GATE_PROOF_CACHE:-0}"
# Project gates currently run under the orchestration user's UID with inherited
# filesystem access. Therefore no persistent cache directory or same-UID MAC
# can safely authorize skipping a later gate. Retain the legacy flag only to
# explain why it has no effect; every gate execution is authoritative and cold.
if [[ "$gate_cache_requested" == "1" ]]; then
  printf '%s\n' \
    'gate-proof-cache: persistent reuse disabled: no isolated gate executor is configured; executing the gate' \
    >"$run_dir/gate-proof-cache-disabled.err"
fi
log_ref="$(singular_repo_relative_ref "$log")"
baseline_path="${SINGULAR_GATE_BASELINE_FILE:-}"
baseline_ref=""
if [[ -n "$baseline_path" ]]; then
  baseline_ref="$(singular_repo_relative_ref "$baseline_path")"
fi

# Wall-clock bound on the consumer's gate. There was none: no timeout, no
# watchdog, no kill. A gate that hangs — a test waiting on a port, a package
# manager waiting on a prompt — held the worker slot forever, and because the
# STOP sentinel is only checked between cycles, one hung gate made cooperative
# STOP never work at all.
#
# Exit 124 matches `timeout`, and gate_report.py already maps 124/137/143 to
# `gate-command-timeout` infrastructure, so a timed-out gate is inconclusive
# rather than a product failure the model gets asked to fix.
# Set SINGULAR_GATE_TIMEOUT_SEC=0 to disable.
gate_timeout="${SINGULAR_GATE_TIMEOUT_SEC:-3600}"
[[ "$gate_timeout" =~ ^[0-9]+$ ]] || gate_timeout=3600

# The gate as a SESSION LEADER. A gate is an arbitrary, uncooperative tree — a
# shell wrapping a test runner wrapping workers — so containment cannot depend
# on `ps`: where enumeration is denied the old walk found no children and killed
# only the top shell (PMGO-004). singular_setsid_exec is the LAST command here,
# so $! below is the leader itself (pid == pgid) and one negative pid reaches
# everything. The gate keeps its argv form; it is never re-parsed by a shell.
singular_gate_spawn() {
  export SINGULAR_GATE_REPORT_FILE="$observation"
  singular_setsid_exec "$@"
}

set +e
if [[ "$gate_timeout" -gt 0 ]]; then
  singular_gate_spawn "$@" >"$log" 2>&1 &
  gate_pid=$!
  gate_deadline=$((SECONDS + gate_timeout)); gate_timed_out="no"
  while kill -0 "$gate_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$gate_deadline" ]]; then
      gate_timed_out="yes"
      # The whole tree: a gate is usually a shell wrapping a test runner
      # wrapping workers, and killing only the shell leaves all of it running.
      # `session` is the spawner's assertion that $gate_pid came from
      # singular_setsid_exec above and has not been waited on yet.
      singular_kill_tree "$gate_pid" "$(singular_kill_grace_sec)" session
      wait "$gate_pid" 2>/dev/null
      exit_code=124
      break
    fi
    sleep 2
  done
  if [[ "$gate_timed_out" != "yes" ]]; then
    wait "$gate_pid"
    exit_code=$?
  else
    echo "gate-check: TIMED OUT after ${gate_timeout}s; killed the gate tree" >&2
    printf '\ngate-check: TIMED OUT after %ss\n' "$gate_timeout" >>"$log"
  fi
else
  SINGULAR_GATE_REPORT_FILE="$observation" "$@" >"$log" 2>&1
  exit_code=$?
fi
set -e
finished_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000)')"
if [[ "$integrity_status" == "verified" ]]; then
  if ! singular_tracked_source_snapshot "$PWD" "$source_after" >>"$run_dir/gate-source-snapshot.err" 2>&1; then
    integrity_status="violation"
    changed_paths+=("source-integrity-snapshot-failed")
  else
    mapfile -t metadata_changed_paths < <(
      singular_tracked_source_changes "$source_before" "$source_after"
    )
    git -C "$PWD" status --porcelain=v1 --untracked-files=all 2>/dev/null \
      | sed -E '\#^.. (\.singular-state|\.singular-cache|\.singular-evidence)(/|$)#d' \
      >"$status_after" || true
    mapfile -t final_changed_paths < <(
      python3 - "$status_before" "$status_after" <<'PY'
import sys

before = set(open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines())
after = set(open(sys.argv[2], encoding="utf-8", errors="replace").read().splitlines())
for line in sorted(before ^ after):
    path = line[3:].strip() if len(line) > 3 else ""
    if path:
        print(path)
PY
    )
    changed_paths+=("${metadata_changed_paths[@]}" "${final_changed_paths[@]}")
    if [[ "${#changed_paths[@]}" -gt 0 ]]; then
      integrity_status="violation"
    fi
  fi
fi

# The REF is the citation dag.sh validates (repo-relative, or the strict path is
# unreachable); the PATH is what gets opened and hashed and must stay absolute,
# because gate-check.sh runs with $PWD set to a worktree while SINGULAR_ROOT and
# SINGULAR_STATE_DIR still point at the main repo. Relativize against
# SINGULAR_ROOT for the same reason — never against $PWD.
normalize_args=(
  --task-id "$task_id"
  --run-id "$run_id"
  --head-sha "$head_sha"
  --command "$command_text"
  --raw-exit-code "$exit_code"
  --log-ref "$log_ref"
  --log-path "$log"
  --duration-ms "$((finished_ms - started_ms))"
  --phase "$phase"
  --workspace-kind "$workspace_kind"
  --integrity-status "$integrity_status"
  --output "$report"
)
for changed_path in "${changed_paths[@]}"; do
  normalize_args+=(--changed-path "$changed_path")
done
[[ -f "$observation" ]] && normalize_args+=(--observation "$observation")
# The strict observation is required only where it does real work: reconciling a
# registered baseline's acknowledged failures. It is NOT implied by schemaVersion.
#
# It used to be. Every v2 gate got --require-observation, and gate_report.py
# raises "strict gate observation missing" BEFORE it looks at the exit code — so
# a gate that passed cleanly normalized to inconclusive-infrastructure, which
# l1-drive maps to audit-infra, which the decider parks UNCONDITIONALLY (it does
# not even consult the retry budget: a model cannot fix broken infrastructure).
# A green test suite therefore parked the task, permanently, with the failure
# reported as an infrastructure problem nobody could act on.
#
# Nothing in the engine told a consumer to emit that document — not the README,
# not the scaffold, whose suggested gate is `npm test && npm run build`. So a
# fresh `singular init` produced a repo where every task parks on a passing gate.
# The requirement was invisible and total.
#
# It also bought nothing. On a green gate there are no failures to classify; on
# a red gate without a report, the `gate-command-nonzero-without-report`
# signature below already covers it. Only the baseline path genuinely needs the
# structured signatures, and gate_report.py enforces that itself.
# No --require-observation is passed at all: gate_report.py already refuses a
# baseline whose observation is missing, with a message naming the baseline —
# strictly better than the generic one this flag would raise first.
if [[ -n "$baseline_path" ]]; then
  # baselineRef lands in the report and dag.sh validates it with the same
  # regular_repo_file() call as logRef, so fixing logRef alone would just move
  # the rejection one line down.
  normalize_args+=(--baseline "$baseline_path"
                   --baseline-ref "$baseline_ref")
fi

outcome=""
normalize_rc=0
outcome="$(python3 "$SCRIPT_DIR/gate_report.py" "${normalize_args[@]}" \
  2>"$run_dir/gate-report.err")" || normalize_rc=$?
if [[ "$normalize_rc" -ne 0 || ! -f "$report" ]]; then
  # Invalid adapter/baseline data is infrastructure-inconclusive, never a
  # fabricated product failure.
  fallback_rc=0
  fallback_args=(
    create
    --output "$report"
    --task-id "$task_id"
    --run-id "$run_id"
    --head-sha "$head_sha"
    --command "$command_text"
    --exit-code "$exit_code"
    --log "$log"
    --log-ref "$log_ref"
    --duration-ms "$((finished_ms - started_ms))"
    --phase "$phase"
    --workspace-kind "$workspace_kind"
    --integrity-status "$integrity_status"
    --setup-error gate-report-normalization-failed
  )
  for changed_path in "${changed_paths[@]}"; do
    fallback_args+=(--changed-path "$changed_path")
  done
  "$SCRIPT_DIR/gate-report.py" "${fallback_args[@]}" || fallback_rc=$?
  outcome="inconclusive-infrastructure"
fi

if [[ -n "$verification_request" ]]; then
  verification_final_head="$(git -C "$PWD" rev-parse HEAD 2>/dev/null || true)"
  verification_final_tree="$(git -C "$PWD" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  if [[ "$verification_final_head" != "$verification_expected_head" \
      || "$verification_final_tree" != "$verification_expected_tree" ]]; then
    echo "gate-check: candidate changed during host verification" >&2
    exit 20
  fi
  python3 "$SCRIPT_DIR/gate-report.py" bind-verification-result \
    --request "$verification_request" --report "$report" \
    --task-contract "$verification_task_contract" \
    --policy-contract "$verification_policy_contract" || exit 20
  python3 "$SCRIPT_DIR/gate-report.py" verify-verification-result \
    --request "$verification_request" --report "$report" \
    --task-contract "$verification_task_contract" \
    --policy-contract "$verification_policy_contract" \
    --expected-task "$task_id" --expected-run "$run_id" \
    --expected-head "$verification_expected_head" \
    --expected-tree "$verification_expected_tree" \
    --expected-attempt "$verification_attempt" \
    --expected-suite task-contract-gate \
    --expected-campaign "$verification_expected_campaign" || exit 20
fi

cp "$report" "$summary"
outcome="$(singular_json_field "$report" outcome 2>/dev/null || echo inconclusive-infrastructure)"
resolved_expected="$(
  python3 - "$report" <<'PY' 2>/dev/null || echo 0
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
resolved = data.get("resolvedExpectedFailures")
print(len(resolved) if isinstance(resolved, list) else 0)
PY
)"
if [[ "$resolved_expected" =~ ^[1-9][0-9]*$ ]]; then
  echo "warning: $resolved_expected acknowledged gate baseline failure(s) are now resolved; refresh the baseline" >&2
  singular_append_event "gate.baseline_stale" \
    "resolved expected failures make the acknowledged baseline stale" \
    "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"resolvedExpectedFailures\":$resolved_expected,\"reportRef\":\"$report\"}" \
    || true
fi

case "$outcome" in
  passed|passed-with-acknowledged-baseline) result_code=0 ;;
  inconclusive-infrastructure) result_code=20 ;;
  *) result_code="$exit_code"; [[ "$result_code" -ne 0 ]] || result_code=1 ;;
esac

# Proof ledger (0.21.0). An integration-phase gate runs in a disposable checkout
# of the exact staged merge tree (integrate.sh), which is the strongest gate
# evidence the engine produces; the promotion gate that follows it runs the
# same command on the same tree in the origin checkout, which is weaker, and
# used to run it again unconditionally. Record the passing integration result
# by TREE (not commit) so the promoter can cite it when the promoted tree is
# byte-identical, and fall back to a fresh run otherwise. Only the host writes
# here, only for integration-phase passes with verified source integrity; the
# record binds the command, the campaign, the report hash and the log bytes,
# and the promoter re-verifies every one of them before reuse.
proof_tree=""
if [[ "$phase" == "integration" && "$integrity_status" == "verified" ]] \
  && [[ "$outcome" == "passed" || "$outcome" == "passed-with-acknowledged-baseline" ]]; then
  proof_tree="$(git -C "$PWD" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  # The ledger keys on the consumer's gate command, not on this script's argv:
  # integrate.sh spawns the gate as `<bash> -c "<gateCommand>"`, while the
  # promoter compares the bare gateCommand string. Unwrap that one shape;
  # anything else is recorded verbatim and simply never matches.
  proof_command="$command_text"
  if [[ $# -eq 3 && "$2" == "-c" && "$(basename -- "$1")" == bash* ]]; then
    proof_command="$3"
  fi
  if [[ "$proof_tree" =~ ^[0-9a-f]{40,64}$ ]]; then
    proofs_dir="$SINGULAR_STATE_DIR/proofs"
    mkdir -p "$proofs_dir"
    python3 - "$proofs_dir/$proof_tree.json" "$proof_tree" "$head_sha" "$proof_command" \
      "$outcome" "$run_id" "$task_id" "$report" "$log" "$observation" \
      "$(singular_campaign_binding 2>/dev/null || echo legacy)" \
      "$(tr -d '[:space:]' <"$SINGULAR_ENGINE_HOME/VERSION" 2>/dev/null || echo unknown)" \
      "$(singular_timestamp)" <<'PY' 2>>"$run_dir/gate-report.err" || proof_tree=""
import hashlib, json, os, sys
(out, tree, head, command, outcome, run_id, task_id, report, log, observation,
 binding, engine_version, recorded_at) = sys.argv[1:14]
def sha(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()
record = {
    "schema": "singular.orchestration.gate-proof.v0",
    "treeSha": tree,
    "headSha": head,
    "command": command,
    "commandSha256": hashlib.sha256(command.encode("utf-8")).hexdigest(),
    "outcome": outcome,
    "phase": "integration",
    "workspaceKind": "integration",
    "runId": run_id,
    "taskId": task_id,
    "reportPath": report,
    "reportSha256": sha(report),
    "logPath": log,
    "logSha256": sha(log),
    "observationPath": observation if os.path.isfile(observation) else "",
    "campaignBinding": binding,
    "engineVersion": engine_version,
    "recordedAt": recorded_at,
}
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp, out)
PY
  fi
fi

singular_append_event "gate_check.completed" "gate check completed" \
  "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"exitCode\":$exit_code,\"resultCode\":$result_code,\"outcome\":\"$outcome\",\"cacheHit\":false,\"proofTree\":\"$proof_tree\",\"logRef\":\"$log\",\"reportRef\":\"$report\"}"
echo "gate check exit_code=$exit_code outcome=$outcome cache_hit=no log=$log report=$report"
exit "$result_code"
