#!/usr/bin/env bash
set -euo pipefail

# claude-run.sh — Claude Code drop-in replacement for codex-run.sh.
#
# Same CLI surface and same output contract as codex-run.sh so the orchestration
# can dispatch the `claude` CLI instead of `codex` by setting SINGULAR_RUNNER to this
# script (per-call sites honor ${SINGULAR_RUNNER:-$SCRIPT_DIR/codex-run.sh}).
#
# Contract preserved:
#   --worktree/-C, --prompt-file, --level l1|l2|readonly, --run-id,
#   --output-last-message, --output-schema, --no-output-capture, --allow-prefix.
#   The final assistant message text is written to --output-last-message so the
#   existing singular_extract_json / singular_l1_prepare_worker_packet pipeline can dig
#   the JSON packet/verdict out of it exactly as it does for codex output.
#
# Privilege levels (mapped from codex sandbox semantics):
#   readonly  -> agent may read + run read-only shell, MUST NOT mutate the repo.
#                Enforced in layers: on macOS, sandbox-exec denies file-write*
#                under the worktree / SINGULAR_ROOT / SINGULAR_STATE_DIR; file-write
#                tools are denied; any working-tree mutation the run leaves behind
#                is reverted after the run (git restore guard). The OS sandbox is
#                the review-evidence admission surface; tool denial + restore
#                remain defense in depth.
#   l2        -> workspace-write + Bash + NETWORK (real-PostgreSQL proof needs
#                egress). File scope is enforced downstream by scope-check.sh in
#                l1-drive.sh, identical to the codex path.
#   l0|l1     -> workspace-write limited to --allow-prefix paths, verified by
#                scope-check.sh after the run (mirrors codex-run.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Argument vocabulary, traps, spawn/timeout/kill, capture, guard ordering and the
# result write are the shared skeleton in lib.sh (singular_runner_*). What
# remains below is claude's own: level mapping, model and effort selection,
# argv (including the strict MCP config), envelope parsing, and session affinity.
#
# Session affinity (T-E5): both flags are ADDITIVE. With NEITHER passed the
# invocation path stays byte-identical to the pre-affinity runner.
singular_runner_parse_args "$@" || exit $?

if [[ "$describe_contract" == "yes" ]]; then
  singular_runner_describe_contract claude
  exit 0
fi

singular_runner_install_traps claude claude-run

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

singular_require_target_branch

# Provider facts (default model, update pin) come from engine/providers.json.
# The pin -- DISABLE_AUTOUPDATER -- is exported by this call: claude's installer
# can replace the executable while a run is using it.
singular_provider_spec_load claude || exit $?

claude_bin="$(command -v "$SINGULAR_SPEC_BINARY" 2>/dev/null || true)"

# --- Level -> behavior ----------------------------------------------------------
readonly_run="no"
case "$level" in
  l0|l1)
    if [[ ${#allow_prefixes[@]} -eq 0 ]]; then allow_prefixes=("docs/orchestration/"); fi
    ;;
  l2) ;;
  readonly|read-only) readonly_run="yes" ;;
  *) echo "unknown level: $level" >&2; exit 2 ;;
esac

profile_rc=0
singular_runner_capability_prepare claude "$runner_role" "$capability_profile" \
  "$worktree" "$claude_bin" || profile_rc=$?
capability_profile="$SINGULAR_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${SINGULAR_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
singular_runner_reject_strict_legacy_extra_args \
  claude SINGULAR_CLAUDE_EXTRA_ARGS "${SINGULAR_CLAUDE_EXTRA_ARGS:-}" || exit $?
[[ -n "$claude_bin" ]] || { echo "claude CLI not found on PATH" >&2; exit 127; }
profile_native_args=()
strict_mcp_config=""
if [[ "$SINGULAR_RESOLVED_CAPABILITY_STRICT" == "yes" ]]; then
  # A temp DIRECTORY with trailing X's, holding a fixed-name file. The template
  # must end in the X's: BSD/macOS mktemp only substitutes TRAILING X's, so the
  # old "...XXXXXX.json" template created a file named literally
  # "singular-claude-empty-mcp.XXXXXX.json". That works once, and the EXIT trap
  # removes it — but any hard kill (a stopped run, an OOM, a reboot mid-run)
  # leaves the literal name behind, and every later strict claude run then dies
  # with "mktemp: mkstemp failed: File exists" until someone deletes it by hand.
  # A persistent, self-inflicted provider outage from a leaked temp file.
  strict_mcp_dir="$(mktemp -d "${TMPDIR:-/tmp}/singular-claude-mcp.XXXXXX")"
  SINGULAR_RUNNER_CLEANUP_PATHS+=("$strict_mcp_dir")
  strict_mcp_config="$strict_mcp_dir/mcp.json"
  printf '{"mcpServers":{}}\n' >"$strict_mcp_config"
  profile_native_args+=(--safe-mode --strict-mcp-config --mcp-config "$strict_mcp_config")
fi

if [[ "$capture_packet" == "auto" && "$level" == "l2" ]]; then
  capture_packet="yes"
elif [[ "$capture_packet" == "auto" ]]; then
  capture_packet="no"
fi

run_dir=""
if [[ "$capture_packet" == "yes" ]]; then
  run_dir="$SINGULAR_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  if [[ -z "$output_last_message" ]]; then
    output_last_message="$run_dir/last-message.json"
  fi
fi

# --- Model selection (mirrors codex reasoning-effort-by-role keying) -------------
# The default is the spec's, in one variable rather than six literals: six copies
# of a default is six chances to edit one of them, which is how a model id that
# no CLI served reached every invocation the engine built for a provider.
claude_default_model="$SINGULAR_SPEC_MODEL_DEFAULT"
singular_claude_model() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "${prompt_file:-}")"
  case "$level" in
    l2)
      printf '%s\n' "${SINGULAR_CLAUDE_L2_MODEL:-${SINGULAR_CLAUDE_MODEL:-$claude_default_model}}" ;;
    l0|l1)
      printf '%s\n' "${SINGULAR_CLAUDE_L1_MODEL:-${SINGULAR_CLAUDE_MODEL:-$claude_default_model}}" ;;
    readonly|read-only)
      case "$prompt_name" in
        planner-prompt.md)    printf '%s\n' "${SINGULAR_CLAUDE_PLANNER_MODEL:-${SINGULAR_CLAUDE_MODEL:-$claude_default_model}}" ;;
        auditor-*.md)    printf '%s\n' "${SINGULAR_CLAUDE_AUDITOR_MODEL:-${SINGULAR_CLAUDE_MODEL:-$claude_default_model}}" ;;
        decider-prompt-*.md)  printf '%s\n' "${SINGULAR_CLAUDE_DECIDER_MODEL:-${SINGULAR_CLAUDE_MODEL:-$claude_default_model}}" ;;
        *)                    printf '%s\n' "${SINGULAR_CLAUDE_MODEL:-$claude_default_model}" ;;
      esac ;;
  esac
}
claude_model="$(singular_claude_model "$level" "$prompt_file")"

# --- Reasoning-effort selection (per-role, env-overridable; empty = model default).
# Implementer (l2) runs Opus at medium effort for bulk code-writing; the gatekeeping
# planner + auditor run at xhigh. Decider/L1/other left at the model default (empty).
singular_claude_effort() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "${prompt_file:-}")"
  case "$level" in
    l2)
      printf '%s\n' "${SINGULAR_CLAUDE_L2_EFFORT:-${SINGULAR_CLAUDE_EFFORT:-medium}}" ;;
    readonly|read-only)
      case "$prompt_name" in
        planner-prompt.md) printf '%s\n' "${SINGULAR_CLAUDE_PLANNER_EFFORT:-${SINGULAR_CLAUDE_EFFORT:-xhigh}}" ;;
        auditor-*.md) printf '%s\n' "${SINGULAR_CLAUDE_AUDITOR_EFFORT:-${SINGULAR_CLAUDE_EFFORT:-xhigh}}" ;;
        decider-prompt-*.md) printf '%s\n' "${SINGULAR_CLAUDE_DECIDER_EFFORT:-${SINGULAR_CLAUDE_EFFORT:-}}" ;;
        *) printf '%s\n' "${SINGULAR_CLAUDE_EFFORT:-}" ;;
      esac ;;
    *)
      printf '%s\n' "${SINGULAR_CLAUDE_EFFORT:-}" ;;
  esac
}
claude_effort="$(singular_claude_effort "$level" "$prompt_file")"

# ---- Session affinity: resume-refusal gate (exit 86) ------------------------
# Model selection lives in the runner. Refuse to resume a session recorded under
# a different model/effort than this runner derives now (exit 86 -> host goes fresh).
if [[ -n "$resume_session_id" && -n "$session_meta_path" && -f "$session_meta_path" ]]; then
  if ! python3 - "$session_meta_path" "$claude_model" "$claude_effort" <<'PY'
import json, sys
path, model_now, effort_now = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as f:
        m = json.load(f)
except Exception:
    sys.exit(0)
prev_model = str(m.get("model", "") or "")
prev_effort = str(m.get("effort", "") or "")
if prev_model and prev_model != model_now:
    sys.exit(1)
if prev_effort and prev_effort != effort_now:
    sys.exit(1)
sys.exit(0)
PY
  then
    echo "claude-run: resume-refused (model/effort changed vs $session_meta_path)" >&2
    exit 86
  fi
fi

if [[ "$level" == "l2" ]]; then
  export GOCACHE="${SINGULAR_GO_BUILD_CACHE:-/private/tmp/singular-build-cache}"
  mkdir -p "$GOCACHE"
fi

# --- Assemble the claude invocation ---------------------------------------------
cmd=("$claude_bin" -p --output-format json --model "$claude_model")
if [[ ${#profile_native_args[@]} -gt 0 ]]; then
  cmd+=("${profile_native_args[@]}")
fi
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$claude_effort" ]] && cmd+=(--effort "$claude_effort")
# Session resume (T-E5): -r <id> resumes; --fork-session forks a fresh branch off
# the resumed session when SINGULAR_CLAUDE_FORK_ON_RESUME=1. Additive: absent flag ->
# cmd is unchanged from HEAD.
if [[ -n "$resume_session_id" ]]; then
  cmd+=(-r "$resume_session_id")
  [[ "${SINGULAR_CLAUDE_FORK_ON_RESUME:-0}" == "1" ]] && cmd+=(--fork-session)
fi

# Runaway protection: no --max-turns exists, so cap dollar spend per run.
claude_budget="${SINGULAR_CLAUDE_MAX_BUDGET_USD:-5}"
if [[ "$claude_budget" != "0" && -n "$claude_budget" ]]; then
  cmd+=(--max-budget-usd "$claude_budget")
fi

# Output-shape enforcement at the seam. The role prompts already ask for JSON-only
# output, but Claude tends to wrap the JSON in reasoning prose; a system-prompt
# constraint is far stickier than a user-prompt one and keeps every role's final
# message parseable. Do NOT instruct literal id reuse here — the planner is
# expected to renumber placeholder TASK ids to the next free id. Env-overridable.
claude_system_prompt="${SINGULAR_CLAUDE_SYSTEM_PROMPT:-Your FINAL assistant message MUST be exactly one JSON object and nothing else: no prose, no preamble, no \"Here is\", no code fences, no trailing commentary. If you cannot comply, still emit a single JSON object describing the problem.}"
if [[ "$readonly_run" == "yes" ]]; then
  # Deny file-mutation tools (first line); the post-run restore guard is the
  # working-tree backstop. Bash stays available for read-only review (git diff,
  # viewing logs) the way the codex read-only sandbox permits. The system-prompt
  # clause additionally forbids state-mutating commands, since tool-denial alone
  # does not stop a Bash `git commit`/`git checkout` the codex OS sandbox blocked.
  # The tool denials stop the edit tools; the Bash denials stop the one class of
  # mutation the restore guard genuinely cannot repair. The guard puts the
  # WORKING TREE back — it does not move HEAD back, so a Bash `git commit` or
  # `git reset --hard` leaves damage no post-run restore can express. Bash stays
  # open otherwise, because read-only review (git diff, git log, reading files)
  # is the entire point of a read-only run.
  ro_denied_tools="Edit,Write,NotebookEdit,MultiEdit"
  for ro_git_verb in add commit checkout switch reset rebase merge cherry-pick \
                     revert push stash apply am clean restore rm mv tag branch \
                     update-ref update-index gc prune reflog; do
    ro_denied_tools+=",Bash(git $ro_git_verb:*)"
  done
  cmd+=(--disallowedTools "$ro_denied_tools")
  claude_system_prompt+=" You are STRICTLY READ-ONLY: do not create, modify, or delete any file, and do not run any state-mutating command (no git add/commit/checkout/reset/rebase/push/stash, no redirections that write files); use only reads and read-only inspection commands."
fi
if [[ -n "$claude_system_prompt" ]]; then
  cmd+=(--append-system-prompt "$claude_system_prompt")
fi
cmd+=(--dangerously-skip-permissions)

if [[ -n "${SINGULAR_CLAUDE_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${SINGULAR_CLAUDE_EXTRA_ARGS})
fi

# --- OS-enforced read-only (sandbox-exec on macOS) ------------------------------
# Applies only at readonly. SINGULAR_CLAUDE_OS_SANDBOX=auto|1|0 (default auto);
# SINGULAR_CLAUDE_SANDBOX_EXEC defaults to /usr/bin/sandbox-exec. Evidence
# delivery sets SINGULAR_RUNNER_REQUIRE_OS_READONLY=1 so a missing tool fails
# closed here, before the restore-guard snapshot or any provider launch.
if [[ "$readonly_run" == "yes" ]]; then
  claude_os_sandbox="${SINGULAR_CLAUDE_OS_SANDBOX:-auto}"
  claude_sandbox_exec="${SINGULAR_CLAUDE_SANDBOX_EXEC:-/usr/bin/sandbox-exec}"
  sandbox_available="no"
  [[ -n "$claude_sandbox_exec" && -x "$claude_sandbox_exec" ]] && sandbox_available="yes"
  apply_sandbox="no"
  case "$claude_os_sandbox" in
    1) apply_sandbox="yes" ;;
    0) apply_sandbox="no" ;;
    auto) [[ "$sandbox_available" == "yes" ]] && apply_sandbox="yes" ;;
  esac
  if [[ "$apply_sandbox" == "yes" && "$sandbox_available" != "yes" ]]; then
    apply_sandbox="no"
  fi
  if [[ "${SINGULAR_RUNNER_REQUIRE_OS_READONLY:-}" == "1" && "$apply_sandbox" != "yes" ]]; then
    echo "claude-run: OS-enforced read-only is required for this invocation but unavailable" >&2
    exit 78
  fi
  if [[ "$apply_sandbox" == "yes" ]]; then
    singular_claude_sandbox_realpath() {
      local dir="$1"
      [[ -n "$dir" && -d "$dir" ]] || return 1
      ( cd "$dir" && pwd -P )
    }
    sandbox_paths=()
    singular_claude_sandbox_add_path() {
      local resolved existing
      resolved="$(singular_claude_sandbox_realpath "$1")" || return 0
      for existing in "${sandbox_paths[@]+"${sandbox_paths[@]}"}"; do
        [[ "$existing" == "$resolved" ]] && return 0
      done
      sandbox_paths+=("$resolved")
    }
    singular_claude_sandbox_add_path "$worktree"
    singular_claude_sandbox_add_path "${SINGULAR_ROOT:-}"
    singular_claude_sandbox_add_path "${SINGULAR_STATE_DIR:-}"
    if [[ -n "$run_dir" && -d "$run_dir" ]]; then
      os_readonly_profile="$run_dir/claude-readonly-sandbox.sb"
    else
      # BSD/macOS mktemp only substitutes trailing X's, so the profile lives
      # in a temp directory under the exact name the contract asks for.
      os_readonly_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-readonly-sandbox.XXXXXX")"
      os_readonly_profile="$os_readonly_dir/claude-readonly-sandbox.sb"
      SINGULAR_RUNNER_CLEANUP_PATHS+=("$os_readonly_dir")
    fi
    {
      printf '(version 1)\n(allow default)\n'
      for sandbox_path in "${sandbox_paths[@]+"${sandbox_paths[@]}"}"; do
        printf '(deny file-write* (subpath "%s"))\n' "$sandbox_path"
      done
    } >"$os_readonly_profile"
    cmd=("$claude_sandbox_exec" -f "$os_readonly_profile" "${cmd[@]}")
    echo "claude-run: readonly os-sandbox=sandbox-exec profile=$os_readonly_profile" >&2
  fi
fi

# --- Read-only snapshot (for restore-after) -------------------------------------
singular_runner_guard_capture "$readonly_run" "$worktree" "claude-$run_id"

# --- Run claude in the working directory ----------------------------------------
# stdout (the --output-format json envelope) and stderr (CLI notices/errors) are
# captured to SEPARATE files so a stray stderr line never corrupts the JSON parse.
singular_runner_capture_files claude
envelope="$SINGULAR_RUNNER_ENVELOPE"
envelope_err="$SINGULAR_RUNNER_ENVELOPE_ERR"

echo "claude-run: level=$level model=$claude_model worktree=$worktree run_id=$run_id" >&2
# Wall-clock guard: `claude -p` has no --max-turns, so an agentic session can
# loop; bound it (default 1200s). Set SINGULAR_CLAUDE_TIMEOUT_SEC=0 to disable.
SINGULAR_RUNNER_TIMEOUT_NOTE=" (output left empty so the caller treats it as a soft failure)"
if [[ -n "$run_dir" && -d "$run_dir" ]]; then
  SINGULAR_RUNNER_SESSION_RECORD="$run_dir/runner-session.json"
fi
# claude takes no working-directory flag, so the spawn cds into the worktree.
singular_runner_spawn_wait "${SINGULAR_CLAUDE_TIMEOUT_SEC:-1200}" "$prompt_file" \
  "$worktree" -- "${cmd[@]}"
exit_code="$SINGULAR_RUNNER_EXIT_CODE"

# Surface stdout (the envelope — also the source for retry fix-hints) then any
# stderr (CLI notices/errors) into the caller's log, and keep a copy under run dir.
if [[ -n "$run_dir" ]]; then cp "$envelope" "$run_dir/claude-envelope.json" 2>/dev/null || true; fi

# --- Session-meta (T-E5): parse session_id from the envelope -------------------
# Always (re)write the meta from the envelope when --session-meta is passed, even
# on fork (the id may churn). The host merges its authority fields afterwards.
if [[ -n "$session_meta_path" ]]; then
  session_id="$(python3 - "$envelope" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        env = json.load(f)
except Exception:
    env = {}
sid = env.get("session_id") if isinstance(env, dict) else None
sys.stdout.write(sid if isinstance(sid, str) else "")
PY
)"
  singular_claude_session_meta_write "$session_meta_path" "$session_id" "$claude_model" \
    "$claude_effort" "$worktree" "$exit_code" || true
fi

# --- Extract the final assistant message into the output file -------------------
if [[ "$capture_packet" == "yes" && -n "$output_last_message" ]]; then
  parse_ec=0
  python3 - "$envelope" "$output_last_message" <<'PY' || parse_ec=$?
import json, sys
env_path, out_path = sys.argv[1], sys.argv[2]
try:
    with open(env_path, "r", encoding="utf-8") as f:
        env = json.load(f)
except Exception as e:
    sys.stderr.write(f"claude-run: could not parse claude envelope as JSON: {e}\n")
    sys.exit(3)
result = env.get("result")
if result is None and isinstance(env, dict):
    # stream-json fallback: last result event, if a NDJSON stream slipped through.
    result = env.get("text")
if result is None:
    sys.stderr.write("claude-run: claude envelope had no 'result' field\n")
    sys.exit(3)
if not isinstance(result, str):
    result = json.dumps(result)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(result)
    if not result.endswith("\n"):
        f.write("\n")
sys.exit(4 if env.get("is_error") else 0)
PY
  if [[ "$parse_ec" -ne 0 ]]; then
    # is_error (4) or missing result (3) — treat as a soft failure; callers that
    # need a packet detect the missing/empty output themselves, exactly as with
    # codex. Preserve a nonzero exit so hard errors propagate.
    if [[ "$exit_code" -eq 0 ]]; then exit_code="$parse_ec"; fi
  fi
fi

# --- Read-only restore guard: revert anything the run mutated -------------------
# Explicitly here, and not only from the EXIT trap, because the scope check below
# must see the restored tree — tests c8/c9 pin that ordering.
singular_runner_guard_restore_now

# --- Scope enforcement for L0/L1 (mirrors codex-run.sh) -------------------------
singular_runner_scope_enforce "$level" "$worktree" "${allow_prefixes[@]}"

if [[ "$capture_packet" == "yes" ]]; then
  echo "last_message=$output_last_message" >&2
fi

singular_runner_finish "$exit_code"
# Temp envelope files are removed by the EXIT trap registered above.
exit "$exit_code"
