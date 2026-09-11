#!/usr/bin/env bash
set -euo pipefail

# Re-run a committed worker gate in a disposable writable worktree. The
# original audited worktree is never used as the command's cwd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

run_dir=""
task_id=""
source_worktree=""
head_sha=""
gate_command=""
worker_gate_report=""
worker_gate_command=""
attempt="1"
try_number="0"
evidence_only="no"
verification_request=""
verification_task_contract=""
verification_policy_contract=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --task-id) task_id="${2:-}"; shift 2 ;;
    --source-worktree) source_worktree="${2:-}"; shift 2 ;;
    --head-sha) head_sha="${2:-}"; shift 2 ;;
    --gate-command) gate_command="${2:-}"; shift 2 ;;
    --worker-gate-report) worker_gate_report="${2:-}"; shift 2 ;;
    --worker-gate-command) worker_gate_command="${2:-}"; shift 2 ;;
    --attempt) attempt="${2:-}"; shift 2 ;;
    --try) try_number="${2:-}"; shift 2 ;;
    --evidence-only) evidence_only="yes"; shift ;;
    --verification-request) verification_request="${2:-}"; shift 2 ;;
    --task-contract) verification_task_contract="${2:-}"; shift 2 ;;
    --policy-contract) verification_policy_contract="${2:-}"; shift 2 ;;
    *) echo "audit-verify: unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$verification_request" && -n "$verification_task_contract" \
    && -n "$verification_policy_contract" ]] || {
  echo "audit-verify: identity-bound verification request, task contract, and policy contract are required" >&2
  exit 2
}
trusted_gate_command="$(python3 "$SCRIPT_DIR/gate-report.py" resolve-verification-request \
  --request "$verification_request" --task-contract "$verification_task_contract" \
  --policy-contract "$verification_policy_contract" --expected-task "$task_id")" || exit 2
if [[ -n "$gate_command" && "$gate_command" != "$trusted_gate_command" ]]; then
  echo "audit-verify: caller gate command differs from trusted verification contract" >&2
  exit 2
fi
gate_command="$trusted_gate_command"

[[ -n "$run_dir" && -d "$run_dir" ]] || { echo "audit-verify: --run-dir is required" >&2; exit 2; }
[[ "$task_id" =~ ^TASK-[0-9]{4,}$ ]] || { echo "audit-verify: valid --task-id is required" >&2; exit 2; }
[[ -n "$source_worktree" && -d "$source_worktree" ]] || { echo "audit-verify: --source-worktree is required" >&2; exit 2; }
[[ "$head_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || { echo "audit-verify: valid --head-sha is required" >&2; exit 2; }
[[ -n "$gate_command" ]] || { echo "audit-verify: --gate-command is required" >&2; exit 2; }
[[ -n "$worker_gate_report" ]] || worker_gate_report="$run_dir/gate-check.json"
[[ -n "$worker_gate_command" ]] || worker_gate_command="$gate_command"

output="$run_dir/audit-verification.json"
if [[ "$evidence_only" == "yes" ]]; then
  [[ -n "$verification_request" ]] || {
    echo "audit-verify: evidence-only verification requires an identity-bound request" >&2
    exit 2
  }
  "$SCRIPT_DIR/gate-report.py" copy-evidence \
    --report "$worker_gate_report" \
    --output "$output" \
    --expected-head "$head_sha" \
    --expected-command "$worker_gate_command"
  "$SCRIPT_DIR/gate-report.py" bind-verification-result \
    --request "$verification_request" --report "$output" \
    --task-contract "$verification_task_contract" \
    --policy-contract "$verification_policy_contract" \
    --evidence-source-command "$worker_gate_command"
  "$SCRIPT_DIR/gate-report.py" verify-verification-result \
    --request "$verification_request" --report "$output" \
    --task-contract "$verification_task_contract" \
    --policy-contract "$verification_policy_contract" --require-pass
  printf '%s\n' "$output"
  exit 0
fi

safe_run_id="${run_dir##*/}"
safe_run_id="${safe_run_id//[^A-Za-z0-9_.-]/_}"
sandbox_base="$(mktemp -d "${TMPDIR:-/tmp}/singular-audit-${safe_run_id}.XXXXXX")"
verify_worktree="$sandbox_base/worktree"
cache_root="$sandbox_base/cache"
log="$run_dir/audit-verification-${attempt}-${try_number}.log"
worktree_added="no"

cleanup() {
  if [[ "$worktree_added" == "yes" ]]; then
    if singular_git_lock_acquire 2>/dev/null; then
      git -C "$SINGULAR_ROOT" worktree remove --force "$verify_worktree" >/dev/null 2>&1 || true
      git -C "$SINGULAR_ROOT" worktree prune >/dev/null 2>&1 || true
      singular_git_lock_release
    fi
  fi
  rm -rf "$sandbox_base"
}
trap cleanup EXIT

workspace_fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
import subprocess
import sys

root = sys.argv[1]
head = subprocess.run(
    ["git", "-C", root, "rev-parse", "HEAD"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    check=False,
).stdout
status = subprocess.run(
    ["git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    check=False,
).stdout
print(hashlib.sha256(head + b"\0" + status).hexdigest())
PY
}

tracked_source_snapshot() {
  python3 - "$1" "$2" <<'PY'
import json
import os
import stat
import subprocess
import sys

root, output = sys.argv[1:3]
result = subprocess.run(
    ["git", "-C", root, "ls-files", "-z"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if result.returncode:
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode)

snapshot = {}
for raw in result.stdout.split(b"\0"):
    if not raw:
        continue
    relative = os.fsdecode(raw)
    path = os.path.join(root, relative)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        snapshot[relative] = {"missing": True}
        continue
    snapshot[relative] = {
        "device": info.st_dev,
        "inode": info.st_ino,
        "kind": stat.S_IFMT(info.st_mode),
        "mode": stat.S_IMODE(info.st_mode),
        "size": info.st_size,
        # Reads may update atime. Writes, replacements, and chmod operations
        # necessarily change at least ctime on supported audit hosts, even if a
        # command restores the original bytes and mtime before it exits.
        "mtimeNs": info.st_mtime_ns,
        "ctimeNs": info.st_ctime_ns,
    }

temporary = output + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, output)
PY
}

tracked_source_changes() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

before_path, after_path = sys.argv[1:3]
with open(before_path, encoding="utf-8") as handle:
    before = json.load(handle)
with open(after_path, encoding="utf-8") as handle:
    after = json.load(handle)
for path in sorted(set(before) | set(after)):
    if before.get(path) != after.get(path):
        print(path)
PY
}

emit_setup_failure() {
  local reason="$1"
  printf 'audit verification setup failed: %s\n' "$reason" >"$log"
  local report_rc=0
  "$SCRIPT_DIR/gate-report.py" create \
    --output "$output" \
    --task-id "$task_id" \
    --run-id "${run_dir##*/}" \
    --head-sha "$head_sha" \
    --command "$gate_command" \
    --exit-code 125 \
    --log "$log" \
    --phase audit-verification \
    --workspace-kind disposable \
    --integrity-status not-checked \
    --setup-error "$reason" || report_rc=$?
  printf '%s\n' "$output"
  [[ "$report_rc" -eq 0 ]] && report_rc=20
  return "$report_rc"
}

original_before="$(workspace_fingerprint "$source_worktree")"

if [[ "${SINGULAR_AUDIT_VERIFY_FORCE_SETUP_FAILURE:-0}" == "1" ]]; then
  emit_setup_failure "forced-setup-failure"
  exit $?
fi

if ! singular_git_lock_acquire; then
  emit_setup_failure "git-lock-timeout"
  exit $?
fi
add_rc=0
git -C "$SINGULAR_ROOT" worktree add --detach -q "$verify_worktree" "$head_sha" >"$log" 2>&1 || add_rc=$?
if [[ "$add_rc" -eq 0 ]]; then worktree_added="yes"; fi
singular_git_lock_release
if [[ "$add_rc" -ne 0 ]]; then
  emit_setup_failure "worktree-create-failed"
  exit $?
fi

resolved_head="$(git -C "$verify_worktree" rev-parse HEAD 2>/dev/null || true)"
if [[ "$resolved_head" != "$head_sha" ]]; then
  emit_setup_failure "worktree-head-mismatch"
  exit $?
fi

# One shared preparer for provision -> dependency copies -> bootstrap -> prewarm,
# so this disposable worktree is environment-equivalent to the worker's by
# construction rather than by two code paths happening to agree. They did not:
# this one never ran `prewarm`, and it is the worktree where the auditor re-runs
# the gate whose result decides whether the work is accepted. A green worker gate
# that fails here is indistinguishable, from the outside, from broken work.
if ! singular_worktree_prepare "$verify_worktree" "" "$source_worktree" "$log"; then
  case "$SINGULAR_WORKTREE_PREPARE_STAGE" in
    provision) emit_setup_failure "worktree-provision-failed" ;;
    copy-paths) emit_setup_failure "${SINGULAR_WORKTREE_PREPARE_DETAIL:-dependency-copy-failed}" ;;
    bootstrap) emit_setup_failure "worktree-bootstrap-failed" ;;
    *) emit_setup_failure "worktree-prepare-failed" ;;
  esac
  exit $?
fi

mkdir -p "$cache_root/tmp" "$cache_root/xdg" "$cache_root/turbo" \
  "$cache_root/vite" "$cache_root/bun" "$cache_root/npm" "$cache_root/yarn" \
  "$cache_root/corepack" "$cache_root/node" "$cache_root/cargo" "$cache_root/go"

source_snapshot_before="$sandbox_base/tracked-source-before.json"
source_snapshot_after="$sandbox_base/tracked-source-after.json"
if ! tracked_source_snapshot "$verify_worktree" "$source_snapshot_before" >>"$log" 2>&1; then
  emit_setup_failure "source-integrity-snapshot-failed"
  exit $?
fi

observation="$run_dir/audit-gate-observation-${attempt}-${try_number}.json"
rm -f "$observation"
gate_timeout="${SINGULAR_AUDIT_GATE_TIMEOUT_SEC:-1200}"
[[ "$gate_timeout" =~ ^[0-9]+$ ]] || gate_timeout=1200

# Cache + report variables supplied only to the disposable command; they stay
# outside the source checkout. Declared ONCE and shared by both spawn paths
# below so the guarded and unguarded gates cannot drift apart.
gate_env=(
  SINGULAR_GATE_REPORT_FILE="$observation"
  TMPDIR="$cache_root/tmp/"
  TMP="$cache_root/tmp"
  TEMP="$cache_root/tmp"
  XDG_CACHE_HOME="$cache_root/xdg"
  TURBO_CACHE_DIR="$cache_root/turbo"
  VITE_CACHE_DIR="$cache_root/vite"
  BUN_INSTALL_CACHE_DIR="$cache_root/bun"
  BUN_TMPDIR="$cache_root/tmp"
  npm_config_cache="$cache_root/npm"
  YARN_CACHE_FOLDER="$cache_root/yarn"
  COREPACK_HOME="$cache_root/corepack"
  NODE_COMPILE_CACHE="$cache_root/node"
  CARGO_TARGET_DIR="$cache_root/cargo"
  GOCACHE="$cache_root/go"
)

run_gate_command() {
  # Reuse the worker gate's allowlisted environment boundary so a denied host
  # variable cannot leak into verification.
  singular_run_in_worktree_env "$verify_worktree" env "${gate_env[@]}" \
    "$(singular_bash_bin)" -c "$gate_command"
}

# The same gate, spawned as a SESSION LEADER. An audited gate is an arbitrary,
# uncooperative tree, so containment cannot depend on `ps`: where enumeration is
# denied the old walk found no children and killed only the top shell, leaving
# the gate running in a disposable worktree nobody would ever look at again
# (PMGO-004). singular_setsid_exec is the LAST command here, so $! at the call
# site is the leader itself (pid == pgid) and one negative pid reaches the tree.
#
# ONLY valid as a background job — it replaces the calling process.
#
# singular_run_in_worktree_env is a shell function that runs its command in a
# SUBSHELL, so it cannot be exec'd; the new session therefore re-enters it after
# sourcing lib.sh, exactly the way every other engine child process obtains it.
# Inlining the boundary here instead would fork it into two copies that drift.
run_gate_command_session() {
  export SINGULAR_ROOT SINGULAR_STATE_DIR SINGULAR_ENGINE_HOME
  export SINGULAR_AUDIT_GATE_LIB="$SCRIPT_DIR/lib.sh"
  export SINGULAR_AUDIT_GATE_WORKTREE="$verify_worktree"
  export SINGULAR_AUDIT_GATE_COMMAND="$gate_command"
  singular_setsid_exec "$(singular_bash_bin)" -c '
set -euo pipefail
gate_env=("$@")
set --
source "$SINGULAR_AUDIT_GATE_LIB"
singular_run_in_worktree_env "$SINGULAR_AUDIT_GATE_WORKTREE" env "${gate_env[@]}" \
  "$(singular_bash_bin)" -c "$SINGULAR_AUDIT_GATE_COMMAND"
' singular-audit-gate "${gate_env[@]}"
}

started_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000)')"
gate_exit=0
gate_timed_out="no"
if [[ "$gate_timeout" -gt 0 ]]; then
  run_gate_command_session >"$log" 2>&1 &
  gate_pid=$!
  gate_deadline=$((SECONDS + gate_timeout))
  while kill -0 "$gate_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$gate_deadline" ]]; then
      gate_timed_out="yes"
      # `session`: the spawner's assertion that $gate_pid came from
      # singular_setsid_exec above and has not been waited on yet.
      singular_kill_tree "$gate_pid" 0 session
      kill -KILL "$gate_pid" 2>/dev/null || true
      wait "$gate_pid" 2>/dev/null || true
      gate_exit=124
      break
    fi
    sleep 0.1
  done
  if [[ "$gate_timed_out" != "yes" ]]; then
    if wait "$gate_pid"; then
      gate_exit=0
    else
      gate_exit=$?
    fi
  else
    printf 'audit verification gate timed out after %ss\n' "$gate_timeout" >>"$log"
  fi
else
  run_gate_command >"$log" 2>&1 || gate_exit=$?
fi
finished_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000)')"

if ! tracked_source_snapshot "$verify_worktree" "$source_snapshot_after" >>"$log" 2>&1; then
  emit_setup_failure "source-integrity-snapshot-failed"
  exit $?
fi

mapfile -t changed_paths < <(
  git -C "$verify_worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null \
    | sed -E 's/^.. //' | sed '/^[[:space:]]*$/d'
)
mapfile -t metadata_changed_paths < <(
  tracked_source_changes "$source_snapshot_before" "$source_snapshot_after"
)
changed_paths+=("${metadata_changed_paths[@]}")
integrity_status="verified"
[[ ${#changed_paths[@]} -eq 0 ]] || integrity_status="violation"
original_after="$(workspace_fingerprint "$source_worktree")"
if [[ "$original_before" != "$original_after" ]]; then
  integrity_status="violation"
  changed_paths+=("original-worktree-changed-during-verification")
fi

report_args=(
  --task-id "$task_id"
  --run-id "${run_dir##*/}"
  --head-sha "$head_sha"
  --command "$gate_command"
  --duration-ms "$((finished_ms - started_ms))"
  --phase audit-verification
  --workspace-kind disposable
  --integrity-status "$integrity_status"
)
for changed in "${changed_paths[@]}"; do
  report_args+=(--changed-path "$changed")
done
report_rc=0
if [[ "${SINGULAR_CONFIG_SCHEMA_VERSION:-}" == "v2" ]]; then
  strict_args=(
    "${report_args[@]}"
    --raw-exit-code "$gate_exit"
    --log-ref "$log"
    --log-path "$log"
    --output "$output"
    --require-observation
  )
  [[ -f "$observation" ]] && strict_args+=(--observation "$observation")
  normalize_rc=0
  "$SCRIPT_DIR/gate_report.py" "${strict_args[@]}" \
    >"$run_dir/audit-gate-normalize-${attempt}-${try_number}.out" \
    2>"$run_dir/audit-gate-normalize-${attempt}-${try_number}.err" \
    || normalize_rc=$?
  if [[ "$normalize_rc" -ne 0 || ! -f "$output" ]]; then
    setup_reason="gate-report-normalization-failed"
    [[ -f "$observation" ]] || setup_reason="strict-gate-observation-missing"
    fallback_args=(
      create
      --output "$output"
      --exit-code "$gate_exit"
      --log "$log"
      --setup-error "$setup_reason"
      "${report_args[@]}"
    )
    if [[ "$gate_exit" -eq 124 || "$gate_exit" -eq 137 || "$gate_exit" -eq 143 ]]; then
      fallback_args+=(--setup-error gate-command-timeout)
    fi
    "$SCRIPT_DIR/gate-report.py" "${fallback_args[@]}" || report_rc=$?
  else
    normalized_outcome="$(singular_json_field "$output" outcome 2>/dev/null || true)"
    case "$normalized_outcome" in
      passed|passed-with-acknowledged-baseline) report_rc=0 ;;
      failed-product) report_rc=10 ;;
      *) report_rc=20 ;;
    esac
  fi
else
  legacy_args=(
    create
    --output "$output"
    --exit-code "$gate_exit"
    --log "$log"
    "${report_args[@]}"
  )
  "$SCRIPT_DIR/gate-report.py" "${legacy_args[@]}" || report_rc=$?
fi
"$SCRIPT_DIR/gate-report.py" bind-verification-result \
  --request "$verification_request" --report "$output" \
  --task-contract "$verification_task_contract" \
  --policy-contract "$verification_policy_contract" || report_rc=20
"$SCRIPT_DIR/gate-report.py" verify-verification-result \
  --request "$verification_request" --report "$output" \
  --task-contract "$verification_task_contract" \
  --policy-contract "$verification_policy_contract" || report_rc=20
printf '%s\n' "$output"
exit "$report_rc"
