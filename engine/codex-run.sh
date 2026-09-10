#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Argument vocabulary, traps, capture, scope enforcement and the result write are
# the shared skeleton in lib.sh (singular_runner_*). What stays here is codex's
# own, and it is the largest residue of any adapter: sandbox mapping, role-keyed
# reasoning effort, the resume machinery, and a guard loop that is not just a
# wall clock -- it also watches the JSONL stream for silence and for semantic
# completion, and it runs the provider through a tee so that stream doubles as
# the liveness signal.
#
# Session affinity (T-E5): both flags are ADDITIVE. With NEITHER passed, the
# invocation path below stays byte-identical to the pre-affinity runner.
runner_role_flag_seen="no"
_singular_role_scan=("$@")
for ((_singular_i=0; _singular_i<${#_singular_role_scan[@]}; _singular_i++)); do
  if [[ "${_singular_role_scan[$_singular_i]}" == "--role" ]]; then
    runner_role_flag_seen="yes"
    break
  fi
done
unset _singular_role_scan _singular_i
singular_runner_parse_args "$@" || exit $?

if [[ "$describe_contract" == "yes" ]]; then
  singular_runner_describe_contract codex
  exit 0
fi

singular_runner_install_traps codex codex-run

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

singular_require_target_branch

singular_validate_codex_sandbox() {
  local value="$1" label="$2"
  case "$value" in
    read-only|workspace-write|danger-full-access) return 0 ;;
    *)
      echo "invalid $label: $value (expected read-only, workspace-write, or danger-full-access)" >&2
      return 2
      ;;
  esac
}

singular_codex_normalize_role() {
  local role
  role="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  role="${role//_/-}"
  case "$role" in
    worker|developer) printf '%s\n' implementer ;;
    reviewer|final|final-audit|final-auditor|paired-audit|paired-auditor)
      printf '%s\n' auditor ;;
    plan-critic|skeptic|advocate) printf '%s\n' critic ;;
    assistant) printf '%s\n' supervisor ;;
    *) printf '%s\n' "$role" ;;
  esac
}

singular_codex_infer_role() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "$prompt_file")"
  case "$prompt_name" in
    planner-prompt.md) printf '%s\n' planner ;;
    auditor.md|auditor-*.md|reviewer.md|reviewer-*.md) printf '%s\n' auditor ;;
    decider.md|decider-prompt-*.md) printf '%s\n' decider ;;
    *supervisor*|*ask*) printf '%s\n' supervisor ;;
    *critic*) printf '%s\n' critic ;;
    *) [[ "$level" == "l2" ]] && printf '%s\n' implementer || printf '%s\n' unknown ;;
  esac
}

singular_codex_model_env_for_role() {
  case "$1" in
    planner) printf '%s\n' SINGULAR_CODEX_PLANNER_MODEL ;;
    implementer) printf '%s\n' SINGULAR_CODEX_IMPLEMENTER_MODEL ;;
    auditor) printf '%s\n' SINGULAR_CODEX_AUDITOR_MODEL ;;
    critic) printf '%s\n' SINGULAR_CODEX_CRITIC_MODEL ;;
    decider) printf '%s\n' SINGULAR_CODEX_DECIDER_MODEL ;;
    supervisor) printf '%s\n' SINGULAR_CODEX_SUPERVISOR_MODEL ;;
    integrator) printf '%s\n' SINGULAR_CODEX_INTEGRATOR_MODEL ;;
    *) printf '\n' ;;
  esac
}

singular_codex_reasoning_effort() {
  local role="$1" level="$2" prompt_file="$3" prompt_name
  case "$role" in
    planner) printf '%s\n' "${SINGULAR_CODEX_PLANNER_REASONING_EFFORT:-high}" ;;
    implementer) printf '%s\n' "${SINGULAR_CODEX_L2_REASONING_EFFORT:-medium}" ;;
    auditor) printf '%s\n' "${SINGULAR_CODEX_AUDITOR_REASONING_EFFORT:-high}" ;;
    critic) printf '%s\n' "${SINGULAR_CODEX_CRITIC_REASONING_EFFORT:-high}" ;;
    decider) printf '%s\n' "${SINGULAR_CODEX_DECIDER_REASONING_EFFORT:-high}" ;;
    supervisor) printf '%s\n' "${SINGULAR_CODEX_SUPERVISOR_REASONING_EFFORT:-${SINGULAR_CODEX_READONLY_REASONING_EFFORT:-high}}" ;;
    integrator) printf '%s\n' "${SINGULAR_CODEX_INTEGRATOR_REASONING_EFFORT:-${SINGULAR_CODEX_READONLY_REASONING_EFFORT:-high}}" ;;
    *)
      # Legacy callers that predate runner roles keep level/prompt inference.
  case "$level" in
    l0|l1)
      printf '%s\n' "${SINGULAR_CODEX_L1_REASONING_EFFORT:-high}"
      ;;
    l2)
      printf '%s\n' "${SINGULAR_CODEX_L2_REASONING_EFFORT:-medium}"
      ;;
    readonly|read-only)
      prompt_name="$(basename "$prompt_file")"
      case "$prompt_name" in
        planner-prompt.md) printf '%s\n' "${SINGULAR_CODEX_PLANNER_REASONING_EFFORT:-high}" ;;
        auditor.md) printf '%s\n' "${SINGULAR_CODEX_AUDITOR_REASONING_EFFORT:-high}" ;;
        auditor-*.md) printf '%s\n' "${SINGULAR_CODEX_AUDITOR_REASONING_EFFORT:-high}" ;;
        reviewer.md|reviewer-*.md) printf '%s\n' "${SINGULAR_CODEX_AUDITOR_REASONING_EFFORT:-high}" ;;
        decider.md|decider-prompt-*.md) printf '%s\n' "${SINGULAR_CODEX_DECIDER_REASONING_EFFORT:-high}" ;;
        *critic*.md) printf '%s\n' "${SINGULAR_CODEX_CRITIC_REASONING_EFFORT:-high}" ;;
        *) printf '%s\n' "${SINGULAR_CODEX_READONLY_REASONING_EFFORT:-high}" ;;
      esac
      ;;
  esac
      ;;
  esac
}

case "$level" in
  l0|l1)
    sandbox="workspace-write"
    if [[ ${#allow_prefixes[@]} -eq 0 ]]; then
      allow_prefixes=("docs/orchestration/")
    fi
    ;;
  l2)
    sandbox="${SINGULAR_L2_SANDBOX:-workspace-write}"
    singular_validate_codex_sandbox "$sandbox" "SINGULAR_L2_SANDBOX"
    ;;
  readonly|read-only)
    sandbox="read-only"
    ;;
  *)
    echo "unknown level: $level" >&2
    exit 2
    ;;
esac

# Provider facts (default model, update pin) come from engine/providers.json.
# Codex's row declares no pin and says why: the CLI has no self-update path, and
# the executable this run uses is the one singular_resolve_codex_bin pinned.
singular_provider_spec_load codex || exit $?

codex_bin="$(singular_resolve_codex_bin 2>/dev/null || true)"
profile_rc=0
singular_runner_capability_prepare codex "$runner_role" "$capability_profile" \
  "$worktree" "$codex_bin" || profile_rc=$?
capability_profile="$SINGULAR_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${SINGULAR_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
if [[ -z "$codex_bin" ]]; then
  singular_resolve_codex_bin >/dev/null
  exit $?
fi
profile_native_args=()
if [[ "$SINGULAR_RESOLVED_CAPABILITY_STRICT" == "yes" ]]; then
  profile_native_args+=(--ignore-user-config)
fi

# A host evidence broker is a read-only reviewer capability carried over one
# exact Unix socket.  Codex's legacy `--sandbox read-only` flag overrides custom
# permission profiles, so this opt-in path expresses the same filesystem policy
# as a named profile and grants only that socket.  User config is ignored here
# so it cannot widen the profile, replace it with an inherited sandbox mode, or
# start unrelated user-configured MCP servers.
evidence_permission_args=()
evidence_permission_profile="no"
if [[ -n "${SINGULAR_EVIDENCE_SOCKET:-}" ]]; then
  if [[ "$level" != "readonly" && "$level" != "read-only" ]]; then
    echo "codex-run: SINGULAR_EVIDENCE_SOCKET is allowed only for read-only roles" >&2
    exit 78
  fi
  if [[ "$SINGULAR_EVIDENCE_SOCKET" != /* || ! -S "$SINGULAR_EVIDENCE_SOCKET" ]]; then
    echo "codex-run: SINGULAR_EVIDENCE_SOCKET must name an existing absolute Unix socket: $SINGULAR_EVIDENCE_SOCKET" >&2
    exit 78
  fi
  evidence_socket_key="${SINGULAR_EVIDENCE_SOCKET//\\/\\\\}"
  evidence_socket_key="${evidence_socket_key//\"/\\\"}"
  evidence_permission_args=(
    -c 'permissions.singular-evidence.extends=":read-only"'
    -c "permissions.singular-evidence.network.unix_sockets={\"$evidence_socket_key\"=\"allow\"}"
    -c 'default_permissions="singular-evidence"'
    -c 'features.network_proxy=true'
    -c 'permissions.singular-evidence.network.enabled=true'
  )
  evidence_permission_profile="yes"
  if [[ ${#profile_provider_args[@]} -gt 0 ]]; then
    # This capability has an exact host-owned argv contract. Deny custom args,
    # including future CLI aliases, rather than relying on a partial denylist.
    echo "codex-run: evidence providerArgs are unsupported; the host owns the read-only boundary" >&2
    exit 78
  fi
  if [[ "$SINGULAR_RESOLVED_CAPABILITY_STRICT" != "yes" ]]; then
    profile_native_args+=(--ignore-user-config)
  fi
fi

if [[ "$capture_packet" == "auto" && "$level" == "l2" ]]; then
  capture_packet="yes"
elif [[ "$capture_packet" == "auto" ]]; then
  capture_packet="no"
fi

if [[ "$capture_packet" == "yes" ]]; then
  run_dir="$SINGULAR_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  if [[ -z "$output_last_message" ]]; then
    output_last_message="$run_dir/last-message.json"
  fi
fi

declared_role="$runner_role"
role_source="environment"
if [[ "$runner_role_flag_seen" == "yes" ]]; then
  role_source="explicit"
elif [[ -z "${SINGULAR_RUNNER_ROLE:-}" || "$runner_role" == "unknown" ]]; then
  declared_role="$(singular_codex_infer_role "$level" "$prompt_file")"
  role_source="inferred"
fi
effective_role="$(singular_codex_normalize_role "$declared_role")"

global_model="${SINGULAR_CODEX_MODEL:-}"
role_model_env="$(singular_codex_model_env_for_role "$effective_role")"
role_model=""
if [[ -n "$role_model_env" ]]; then
  role_model="${!role_model_env:-}"
fi
if [[ -n "$role_model" ]]; then
  codex_model="$role_model"
  codex_model_source="$role_model_env"
elif [[ -n "$global_model" ]]; then
  codex_model="$global_model"
  codex_model_source="SINGULAR_CODEX_MODEL"
else
  codex_model="$SINGULAR_SPEC_MODEL_DEFAULT"
  codex_model_source="provider-default"
fi
codex_reasoning_effort="$(singular_codex_reasoning_effort "$effective_role" "$level" "$prompt_file")"
case "$effective_role" in
  planner) codex_effort_env=SINGULAR_CODEX_PLANNER_REASONING_EFFORT ;;
  implementer) codex_effort_env=SINGULAR_CODEX_L2_REASONING_EFFORT ;;
  auditor) codex_effort_env=SINGULAR_CODEX_AUDITOR_REASONING_EFFORT ;;
  critic) codex_effort_env=SINGULAR_CODEX_CRITIC_REASONING_EFFORT ;;
  decider) codex_effort_env=SINGULAR_CODEX_DECIDER_REASONING_EFFORT ;;
  supervisor) codex_effort_env=SINGULAR_CODEX_SUPERVISOR_REASONING_EFFORT ;;
  integrator) codex_effort_env=SINGULAR_CODEX_INTEGRATOR_REASONING_EFFORT ;;
  *) codex_effort_env="" ;;
esac
if [[ -n "$codex_effort_env" && -n "${!codex_effort_env:-}" ]]; then
  codex_effort_source="$codex_effort_env"
elif [[ "$effective_role" == "supervisor" || "$effective_role" == "integrator" ]] \
  && [[ -n "${SINGULAR_CODEX_READONLY_REASONING_EFFORT:-}" ]]; then
  codex_effort_source=SINGULAR_CODEX_READONLY_REASONING_EFFORT
else
  case "$effective_role" in
    planner|implementer|auditor|critic|decider|supervisor|integrator)
      codex_effort_source=runner-default
      ;;
  *) codex_effort_source=legacy-level-inference ;;
  esac
fi

codex_service_tier=""
codex_service_tier_source=""
if [[ "${SINGULAR_CODEX_SERVICE_TIER+x}" == "x" ]]; then
  case "${SINGULAR_CODEX_SERVICE_TIER:-}" in
    ""|normal|standard|default)
      codex_service_tier="default"
      [[ -n "${SINGULAR_CODEX_SERVICE_TIER:-}" ]] \
        && codex_service_tier_source="explicit" \
        || codex_service_tier_source="explicit-clear"
      ;;
    *)
      codex_service_tier="$SINGULAR_CODEX_SERVICE_TIER"
      codex_service_tier_source="explicit"
      ;;
  esac
fi

# ---- Session affinity: resume-refusal gate (exit 86) ------------------------
# Model selection lives in the runner. If the host asks us to resume a session
# whose recorded model/effort no longer match what THIS runner derives now,
# refuse (exit 86) so the host goes fresh instead of feeding a model-shifted
# session. This keeps model knowledge entirely on the runner side.
if [[ -n "$resume_session_id" && -n "$session_meta_path" && -f "$session_meta_path" ]]; then
  if ! python3 - "$session_meta_path" "$codex_model" "$codex_reasoning_effort" <<'PY'
import json, sys
path, model_now, effort_now = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as f:
        m = json.load(f)
except Exception:
    sys.exit(0)  # unparseable meta -> let the host's own gates decide; don't refuse here
prev_model = str(m.get("model", "") or "")
prev_effort = str(m.get("effort", "") or "")
if prev_model and prev_model != model_now:
    sys.exit(1)
if prev_effort and prev_effort != effort_now:
    sys.exit(1)
sys.exit(0)
PY
  then
    echo "codex-run: resume-refused (model/effort changed vs $session_meta_path)" >&2
    exit 86
  fi
fi

if [[ "$level" == "l2" ]]; then
  export GOCACHE="${SINGULAR_GO_BUILD_CACHE:-/private/tmp/singular-build-cache}"
  mkdir -p "$GOCACHE"
fi

if [[ -n "$resume_session_id" ]]; then
  # Resume path. `codex exec resume` does NOT accept --sandbox/-C/--json as
  # subcommand flags; those live at the GLOBAL codex level (before `exec`), while
  # --json/-o belong to the resume subcommand. Verified form (codex exec resume
  # --help): codex -a never -m M --sandbox S -C WT [-c ...] exec resume <id> --json [-o out] -
  cmd=("$codex_bin" -a never -m "$codex_model")
  if [[ "$evidence_permission_profile" != "yes" ]]; then
    cmd+=(--sandbox "$sandbox")
  fi
  cmd+=(-C "$worktree")
  if [[ ${#evidence_permission_args[@]} -gt 0 ]]; then
    cmd+=("${evidence_permission_args[@]}")
  fi
  if [[ -n "$codex_reasoning_effort" ]]; then
    cmd+=(-c "model_reasoning_effort=\"$codex_reasoning_effort\"")
  fi
  if [[ -n "$codex_service_tier" ]]; then
    cmd+=(-c "service_tier=\"$codex_service_tier\"")
  fi
  cmd+=(exec)
  if [[ ${#profile_native_args[@]} -gt 0 ]]; then
    cmd+=("${profile_native_args[@]}")
  fi
  if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
    cmd+=("${profile_provider_args[@]}")
  fi
  cmd+=(resume "$resume_session_id" --json)
  if [[ "$capture_packet" == "yes" ]]; then
    if [[ -n "$output_schema" ]]; then
      cmd+=(--output-schema "$output_schema")
    fi
    cmd+=(-o "$output_last_message")
  fi
  cmd+=(-)
else
  cmd=("$codex_bin" -a never exec)
  if [[ ${#profile_native_args[@]} -gt 0 ]]; then
    cmd+=("${profile_native_args[@]}")
  fi
  if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
    cmd+=("${profile_provider_args[@]}")
  fi
  cmd+=(-m "$codex_model")
  if [[ "$evidence_permission_profile" != "yes" ]]; then
    cmd+=(--sandbox "$sandbox")
  fi
  cmd+=(-C "$worktree" --json)
  if [[ ${#evidence_permission_args[@]} -gt 0 ]]; then
    cmd+=("${evidence_permission_args[@]}")
  fi
  if [[ -n "$codex_reasoning_effort" ]]; then
    cmd+=(-c "model_reasoning_effort=\"$codex_reasoning_effort\"")
  fi
  if [[ -n "$codex_service_tier" ]]; then
    cmd+=(-c "service_tier=\"$codex_service_tier\"")
  fi
  if [[ "$capture_packet" == "yes" ]]; then
    # --output-schema uses OpenAI strict structured-output validation, which is far
    # stricter than JSON Schema (no const/format/pattern, no additionalProperties:true,
    # all properties required). Our packet/verdict schemas are intentionally richer,
    # so we only forward --output-schema when a caller explicitly opts in with a
    # strict-compatible schema; otherwise we just capture the final message and
    # validate it ourselves.
    if [[ -n "$output_schema" ]]; then
      cmd+=(--output-schema "$output_schema")
    fi
    cmd+=(-o "$output_last_message")
  fi
  cmd+=(-)
fi

# ---- Run --------------------------------------------------------------------
# Guard rails (0.5.0): SINGULAR_CODEX_TIMEOUT_SEC (default 2400; 0 disables)
# bounds wall clock — the field audit saw codex planners/auditors/workers hang
# 28-380 minutes with zero output and no engine-side bound (the claude runner
# has had SINGULAR_CLAUDE_TIMEOUT_SEC since 0.4.0). SINGULAR_CODEX_IDLE_SEC
# (default 0 = off; 600 recommended) additionally kills a run whose JSONL
# stream stops growing — codex --json emits an event per action, so byte
# growth is a faithful liveness signal. Both kill the whole process tree and
# surface exit 124, which every consumer already classifies as timeout/infra.
# SINGULAR_CODEX_COMPLETION_GRACE_SEC (default 10; 0 disables) recognizes only
# parsed, top-level Codex success events. It lets a semantically complete run
# exit normally, then cleans up a provider process tree that remains alive
# without converting the completed turn into a timeout.
codex_timeout="${SINGULAR_CODEX_TIMEOUT_SEC:-2400}"
codex_idle="${SINGULAR_CODEX_IDLE_SEC:-0}"
codex_completion_grace="${SINGULAR_CODEX_COMPLETION_GRACE_SEC:-10}"
[[ "$codex_timeout" =~ ^[0-9]+$ ]] || codex_timeout=2400
[[ "$codex_idle" =~ ^[0-9]+$ ]] || codex_idle=0
[[ "$codex_completion_grace" =~ ^[0-9]+$ ]] || codex_completion_grace=10

exit_code=0
# Always retain the provider JSONL until the normalized runner result is
# written. This is the sole status input; the final assistant message and
# command output are never scanned for quota prose.
jsonl_tmp="$(mktemp "${TMPDIR:-/tmp}/singular-codex-jsonl.XXXXXX")"
# The JSONL IS codex's envelope: it is the sole status input for the normalized
# result, and handing it to the skeleton is what puts its removal and the result
# write on every exit path, including the signals.
SINGULAR_RUNNER_ENVELOPE="$jsonl_tmp"
# Exported because the tee now lives inside a separate `bash -c` (the session
# leader): the path cannot be interpolated into that script without quoting the
# whole provider argv through it.
export SINGULAR_CODEX_JSONL_TMP="$jsonl_tmp"

singular_codex_completion_scan() {
  # Incrementally inspect only complete JSONL records appended since the last
  # scan. A final newline-free record is also parsed, but its offset is retained
  # so a later append cannot hide a previously incomplete record.
  python3 - "$jsonl_tmp" "$1" <<'PY'
import json
import re
import sys

path, raw_offset = sys.argv[1], sys.argv[2]
try:
    offset = max(0, int(raw_offset))
except ValueError:
    offset = 0

terminal_success_types = {
    "turn.completed",
    "response.completed",
    "session.completed",
    "thread.completed",
}
terminal_failure_types = {
    "turn.failed",
    "response.failed",
    "request.failed",
    "session.failed",
    "thread.failed",
}

def is_bounded_reconnect(event):
    if event.get("type") != "error" or not isinstance(event.get("message"), str):
        return False
    match = re.fullmatch(
        r"Reconnecting\.\.\. (?P<attempt>[1-9]|10)/(?P<limit>[1-9]|10) \([^\r\n]+\)",
        event["message"],
    )
    if match is None:
        return False
    attempt = int(match.group("attempt"))
    limit = int(match.group("limit"))
    return attempt <= limit

consumed = offset
outcome = "none"
try:
    with open(path, "rb") as stream:
        stream.seek(offset)
        chunk = stream.read()
    for raw_line in chunk.splitlines(keepends=True):
        line = raw_line.rstrip(b"\r\n")
        if line:
            try:
                event = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                event = None
            if isinstance(event, dict) and isinstance(event.get("type"), str):
                event_type = event["type"]
                if event_type == "error" and is_bounded_reconnect(event):
                    if outcome != "failed":
                        outcome = "reconnecting"
                elif event_type == "error" or (
                    event_type in terminal_failure_types
                    and event.get("error") is not None
                ):
                    outcome = "failed"
                elif event_type in terminal_success_types and outcome != "failed":
                    outcome = "completed"
        if raw_line.endswith((b"\n", b"\r")):
            consumed += len(raw_line)
        else:
            break
except OSError:
    pass

print(consumed, outcome)
PY
}

# The provider pipeline as a SESSION LEADER. singular_setsid_exec is the last
# command, so the `&` below makes $! the leader itself (pid == pgid) and
# singular_kill_tree can group-kill codex plus everything it spawned with one
# negative pid — no `ps`, which is the whole point (PMGO-004: in a sandbox that
# denies process enumeration, only the direct child was being signalled and the
# provider's descendants survived every timeout, invisibly).
#
# The tee stays INSIDE the session so the JSONL liveness signal is unchanged,
# and the inner shell reproduces the previous subshell's exit contract exactly:
# `exit "${PIPESTATUS[0]}"` — codex's status wins over tee's.
singular_codex_spawn_pipeline() {
  singular_setsid_exec "$(singular_bash_bin)" -c \
    '"$@" | tee "$SINGULAR_CODEX_JSONL_TMP"; exit "${PIPESTATUS[0]}"' \
    singular-codex-pipeline "${cmd[@]}"
}

run_codex_guarded() {
  # Background + poll: overall deadline, idle-output detection, and semantic
  # completion grace. The tee is unconditional here so the JSONL file doubles
  # as the liveness signal and remains available after process-tree cleanup.
  local deadline=0 idle_deadline=0 completion_deadline=0
  local size=0 prev_size=0 completion_scan_size=0 completion_scan_offset=0
  local completion_outcome="none" now
  (( codex_timeout > 0 )) && deadline=$(( SECONDS + codex_timeout ))
  (( codex_idle > 0 )) && idle_deadline=$(( SECONDS + codex_idle ))
  # The stdin redirect binds to the background job, so it survives the exec.
  if [[ -n "$prompt_file" ]]; then
    singular_codex_spawn_pipeline <"$prompt_file" &
  else
    singular_codex_spawn_pipeline &
  fi
  SINGULAR_RUNNER_CHILD_PID=$!
  # What this spawner knows about the session, recorded ps-free so a crashed
  # runner leaves behind a signalable group instead of an orphan tree.
  if [[ -n "${run_dir:-}" && -d "${run_dir:-}" ]]; then
    singular_session_record_write "$run_dir/runner-session.json" \
      "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null || true
  fi
  while kill -0 "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null; do
    sleep 1
    now=$SECONDS

    if (( codex_idle > 0 || codex_completion_grace > 0 )); then
      size="$(stat -f %z "$jsonl_tmp" 2>/dev/null || stat -c %s "$jsonl_tmp" 2>/dev/null || echo 0)"
    fi
    if (( codex_completion_grace > 0 )) \
      && [[ "$size" != "$completion_scan_size" ]]; then
      read -r completion_scan_offset completion_outcome \
        < <(singular_codex_completion_scan "$completion_scan_offset")
      completion_scan_size="$size"
      if [[ "$completion_outcome" == "failed" ]]; then
        echo "codex-run: terminal provider failure observed; terminating process tree" >&2
        singular_kill_tree "$SINGULAR_RUNNER_CHILD_PID" "$(singular_provider_kill_grace_sec)" session
        wait "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null || true
        SINGULAR_RUNNER_CHILD_PID=""
        return 1
      fi
      if [[ "$completion_outcome" == "reconnecting" ]]; then
        completion_deadline=0
        echo "codex-run: bounded provider reconnect observed; awaiting terminal outcome" >&2
      fi
      if [[ "$completion_outcome" == "completed" && "$completion_deadline" -eq 0 ]]; then
        completion_deadline=$(( now + codex_completion_grace ))
        echo "codex-run: semantic completion observed; allowing ${codex_completion_grace}s for provider shutdown" >&2
      fi
    fi
    if (( completion_deadline > 0 )); then
      if (( now >= completion_deadline )) && kill -0 "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null; then
        echo "codex-run: completion grace expired after ${codex_completion_grace}s; terminating process tree" >&2
        singular_kill_tree "$SINGULAR_RUNNER_CHILD_PID" "$(singular_provider_kill_grace_sec)" session
        wait "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null || true
        SINGULAR_RUNNER_CHILD_PID=""
        return 0
      fi
      continue
    fi

    if (( deadline > 0 && now >= deadline )); then
      echo "codex-run: TIMED OUT after ${codex_timeout}s; killing process tree" >&2
      singular_kill_tree "$SINGULAR_RUNNER_CHILD_PID" "$(singular_provider_kill_grace_sec)" session
      wait "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null || true
      SINGULAR_RUNNER_CHILD_PID=""
      return 124
    fi
    if (( codex_idle > 0 )); then
      if [[ "$size" != "$prev_size" ]]; then
        prev_size="$size"
        idle_deadline=$(( now + codex_idle ))
      elif (( now >= idle_deadline )); then
        echo "codex-run: IDLE (no output for ${codex_idle}s); killing process tree" >&2
        singular_kill_tree "$SINGULAR_RUNNER_CHILD_PID" "$(singular_provider_kill_grace_sec)" session
        wait "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null || true
        SINGULAR_RUNNER_CHILD_PID=""
        return 124
      fi
    fi
  done
  local rc=0
  wait "$SINGULAR_RUNNER_CHILD_PID" || rc=$?
  SINGULAR_RUNNER_CHILD_PID=""
  return "$rc"
}

if [[ "$codex_timeout" -gt 0 || "$codex_idle" -gt 0 || "$codex_completion_grace" -gt 0 ]]; then
  run_codex_guarded || exit_code=$?
else
  if [[ -n "$prompt_file" ]]; then
    if "${cmd[@]}" <"$prompt_file" | tee "$jsonl_tmp"; then
      exit_code=0
    else
      exit_code=${PIPESTATUS[0]}
    fi
  else
    if "${cmd[@]}" | tee "$jsonl_tmp"; then
      exit_code=0
    else
      exit_code=${PIPESTATUS[0]}
    fi
  fi
fi

# A provider can exit between guard polls, so classify the complete retained
# stream once more. A bounded reconnect is provisional only when a later Codex
# success event resolves it; otherwise it remains failure evidence.
final_scan_outcome="none"
read -r _ final_scan_outcome < <(singular_codex_completion_scan 0)
if [[ "$exit_code" -eq 0 && "$final_scan_outcome" == "failed" ]]; then
  echo "codex-run: terminal provider failure observed at shutdown" >&2
  exit_code=1
elif [[ "$exit_code" -eq 0 && "$final_scan_outcome" == "reconnecting" ]]; then
  echo "codex-run: provider exited without success after reconnect" >&2
  exit_code=1
fi

# ---- Session-meta: scan the JSONL for a session id, write the meta file ------
if [[ -n "$session_meta_path" ]]; then
  session_id=""
  if [[ -n "$jsonl_tmp" && -f "$jsonl_tmp" ]]; then
    # Defensive scan: codex event shape drifts. The current CLI emits the
    # resumable id as `thread_id` on a `{"type":"thread.started",...}` event;
    # older/other shapes used session_id/sessionId (top level, .msg, or .session).
    # `codex exec resume` accepts that id (a UUID) directly. A miss yields an
    # empty id, and the host falls back to a fresh run.
    session_id="$(python3 - "$jsonl_tmp" <<'PY' || true
import json, sys
found = ""
def pick(d):
    if not isinstance(d, dict):
        return ""
    for k in ("session_id", "sessionId", "thread_id"):
        v = d.get(k)
        if isinstance(v, str) and v:
            return v
    for sub in ("msg", "session"):
        s = d.get(sub)
        if isinstance(s, dict):
            for k in ("session_id", "sessionId", "thread_id", "id"):
                v = s.get(k)
                if isinstance(v, str) and v:
                    return v
    return ""
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            sid = pick(obj)
            if sid:
                found = sid
                break
except Exception:
    pass
sys.stdout.write(found)
PY
)"
  fi
  singular_codex_session_meta_write "$session_meta_path" "$session_id" "$codex_model" \
    "$codex_reasoning_effort" "$worktree" "$exit_code" || true
  python3 - "$session_meta_path" "$declared_role" "$effective_role" "$role_source" \
    "$codex_model" "$codex_model_source" "$codex_reasoning_effort" \
    "$codex_effort_source" "$codex_service_tier" "$codex_service_tier_source" <<'PY' \
    2>/dev/null || true
import json
import os
import sys

(path, requested_role, role, role_source, model, model_source, effort,
 effort_source, service_tier, service_tier_source) = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    meta = json.load(handle)
meta["effective"] = {
    "requestedRole": requested_role,
    "role": role,
    "roleSource": role_source,
    "model": model,
    "modelSource": model_source,
    "reasoningEffort": effort or None,
    "reasoningEffortSource": effort_source or None,
    "requestedServiceTier": service_tier or None,
    "serviceTierSource": service_tier_source or None,
    "providerObservedServiceTier": None,
}
tmp = f"{path}.tmp-{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp, path)
PY
fi
# ---- Resume-failure signalling (exit 86) ------------------------------------
# A resumed run that exits nonzero with empty output is indistinguishable, to the
# host, from a real model failure unless we flag it. Surface 86 so the host falls
# back to fresh within the same attempt rather than burning a retry.
if [[ -n "$resume_session_id" && "$exit_code" -ne 0 ]]; then
  out_empty="yes"
  if [[ -n "$output_last_message" && -s "$output_last_message" ]]; then out_empty="no"; fi
  if [[ "$out_empty" == "yes" ]]; then
    echo "codex-run: resume produced no usable output (rc=$exit_code); signalling resume-failure" >&2
    exit 86
  fi
fi

singular_runner_scope_enforce "$level" "$worktree" "${allow_prefixes[@]}"

if [[ "$capture_packet" == "yes" ]]; then
  echo "last_message=$output_last_message" >&2
fi

singular_runner_finish "$exit_code"
[[ -n "$jsonl_tmp" ]] && rm -f "$jsonl_tmp" 2>/dev/null || true
exit "$exit_code"
