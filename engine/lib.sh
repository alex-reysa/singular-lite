#!/usr/bin/env bash
set -euo pipefail

# Bash selection is a bootstrap concern: capture it before loading repo config
# and restore it afterwards so a committed config cannot change the interpreter
# used to run the engine. Operators may set it in the process/service
# environment (including launchd's local env file).
_singular_bootstrap_bash_bin="${SINGULAR_BASH_BIN:-}"

singular_repo_root() {
  git rev-parse --show-toplevel
}

# Engine install location. The engine ships its OWN schemas (and other engine
# assets); resolve them relative to THIS file, not the consumer repo, so a repo
# that holds only config still validates. SINGULAR_ROOT remains the *consumer* repo.
# Override SINGULAR_ENGINE_HOME / SINGULAR_SCHEMA_DIR when vendoring or testing.
# Where this file actually lives. SINGULAR_ENGINE_DIR below is an overridable
# knob — tests shim it to a directory of selected ctx-*.sh symlinks to control
# which bricks load — so engine EXECUTABLES must not resolve through it, or a
# shimmed brick lookup silently takes bootstrap-worktree.sh and readonly_guard.py
# with it.
SINGULAR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGULAR_ENGINE_DIR="${SINGULAR_ENGINE_DIR:-$SINGULAR_LIB_DIR}"
SINGULAR_ENGINE_HOME="${SINGULAR_ENGINE_HOME:-$(cd "$SINGULAR_ENGINE_DIR/.." && pwd)}"
SINGULAR_SCHEMA_DIR="${SINGULAR_SCHEMA_DIR:-$SINGULAR_ENGINE_HOME/schemas}"

SINGULAR_ROOT="${SINGULAR_ROOT:-$(singular_repo_root)}"
SINGULAR_ORCH_DIR="${SINGULAR_ORCH_DIR:-$SINGULAR_ROOT/docs/orchestration}"
SINGULAR_STATE_DIR="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}"

# ---- Consumer configuration --------------------------------------------------
# All per-repo variation lives in the CONSUMER repo, never in engine files. The
# engine loads, in increasing precedence (each can override the previous),
# BEFORE the ${VAR:-default} block below so a repo's settings win:
#   singular.config.json          declarative: targetBranch, gateCommand, runner,
#                             areas{}, proofLayers[], identity{}, prewarm, env{}
#   singular.config.sh            optional shell extras (computed values / functions)
#   .singular-state/config.local.sh  gitignored operator overrides + secrets
# Never edit engine/ to customize a repo — put it in these files.

# Translate the declarative JSON config into SINGULAR_* env exports.
singular_json_config_to_env() {
  python3 - "$1" <<'PY'
import json, sys, shlex, re
cfg = json.load(open(sys.argv[1]))
out = []
_VAR = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
def setv(var, val):
    if val is None: return
    if not _VAR.match(var):
        sys.stderr.write("singular: ignoring invalid config env key: %r\n" % var)
        return
    out.append("export %s=%s" % (var, shlex.quote(str(val))))
setv("SINGULAR_TARGET_BRANCH", cfg.get("targetBranch"))
setv("SINGULAR_CONFIG_SCHEMA_VERSION", cfg.get("schemaVersion"))
setv("SINGULAR_DEFAULT_GATE_CMD", cfg.get("gateCommand"))
setv("SINGULAR_RUNNER", cfg.get("runner"))
setv("SINGULAR_AREA_PREFIX", cfg.get("areaPrefix"))
setv("SINGULAR_PREWARM_CMD", cfg.get("prewarm"))
areas = cfg.get("areas")
if isinstance(areas, dict):
    lines = []
    for k, v in areas.items():
        if isinstance(v, list): v = ":".join(v)
        lines.append("%s=%s" % (k, v))
    setv("SINGULAR_AREA_PATHS", "\n".join(lines))
pl = cfg.get("proofLayers")
if isinstance(pl, list): setv("SINGULAR_PROOF_LAYERS", ",".join(pl))
pg = cfg.get("proofGrandfather")
if isinstance(pg, list): setv("SINGULAR_PROOF_GRANDFATHER", ",".join(pg))
mods = cfg.get("modules")
if isinstance(mods, list): setv("SINGULAR_MODULES", " ".join(mods))
ssl = cfg.get("singleSliceLayers")
if isinstance(ssl, list): setv("SINGULAR_SINGLE_SLICE_LAYERS", ",".join(ssl))
wcp = cfg.get("worktreeCopyPaths")
if isinstance(wcp, list): setv("SINGULAR_WORKTREE_COPY_PATHS_JSON", json.dumps(wcp, separators=(",", ":")))
pf = cfg.get("provisionFiles")
if isinstance(pf, list): setv("SINGULAR_PROVISION_FILES_JSON", json.dumps(pf, separators=(",", ":")))
ea = cfg.get("envAllowlist")
if isinstance(ea, list): setv("SINGULAR_ENV_ALLOWLIST_JSON", json.dumps(ea, separators=(",", ":")))
capability_profiles = cfg.get("capabilityProfiles")
if isinstance(capability_profiles, dict):
    setv("SINGULAR_CAPABILITY_PROFILES_JSON", json.dumps(capability_profiles, separators=(",", ":")))
role_profiles = cfg.get("roleProfiles")
if isinstance(role_profiles, dict):
    setv("SINGULAR_ROLE_PROFILES_JSON", json.dumps(role_profiles, separators=(",", ":")))
capabilities = cfg.get("capabilities")
if isinstance(capabilities, dict):
    setv("SINGULAR_CAPABILITIES_JSON", json.dumps(capabilities, separators=(",", ":")))
evidence = cfg.get("evidence")
if isinstance(evidence, dict):
    setv("SINGULAR_EVIDENCE_CONFIG_JSON", json.dumps(evidence, separators=(",", ":")))
bootstrap = cfg.get("bootstrap")
if isinstance(bootstrap, dict):
    setv("SINGULAR_BOOTSTRAP_JSON", json.dumps(bootstrap, separators=(",", ":")))
resources = cfg.get("resources")
if isinstance(resources, dict):
    setv("SINGULAR_DISK_RESERVE_BYTES", resources.get("diskReserveBytes"))
    setv("SINGULAR_ESTIMATED_WORKTREE_BYTES", resources.get("estimatedWorktreeBytes"))
    setv("SINGULAR_MAX_CONCURRENT", resources.get("maxConcurrent"))
control_state = cfg.get("controlState")
if isinstance(control_state, dict):
    setv("SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC", control_state.get("commitIntervalSeconds"))
legacy_compatibility = cfg.get("legacyCompatibility")
if isinstance(legacy_compatibility, dict) and isinstance(
    legacy_compatibility.get("unboundWaivers"), bool
):
    setv(
        "SINGULAR_LEGACY_UNBOUND_WAIVERS",
        "1" if legacy_compatibility["unboundWaivers"] else "0",
    )
setv("SINGULAR_PROMOTER", cfg.get("promoter"))
ident = cfg.get("identity") or {}
l0 = ident.get("l0") or {}; l1 = ident.get("l1") or {}
setv("SINGULAR_GIT_L0_NAME", l0.get("name")); setv("SINGULAR_GIT_L0_EMAIL", l0.get("email"))
setv("SINGULAR_GIT_L1_NAME", l1.get("name")); setv("SINGULAR_GIT_L1_EMAIL", l1.get("email"))
for k, v in (cfg.get("env") or {}).items():
    if k == "SINGULAR_BASH_BIN":
        sys.stderr.write("singular: ignoring bootstrap-only config env key: SINGULAR_BASH_BIN\n")
        continue
    setv(k, v)
print("\n".join(out))
PY
}

# Consumer-relative paths have the same meaning from any invocation cwd.
singular_normalize_consumer_path_var() {
  local key="$1" value
  value="${!key:-}"
  [[ -z "$value" || "$value" == /* ]] || printf -v "$key" '%s/%s' "$SINGULAR_ROOT" "$value"
}

SINGULAR_JSON_CONFIG_FILE="${SINGULAR_JSON_CONFIG_FILE:-$SINGULAR_ROOT/singular.config.json}"
singular_normalize_consumer_path_var SINGULAR_JSON_CONFIG_FILE
if [[ -f "$SINGULAR_JSON_CONFIG_FILE" ]]; then
  _singular_cfg_env="$(singular_json_config_to_env "$SINGULAR_JSON_CONFIG_FILE")" \
    || { echo "singular: failed to parse $SINGULAR_JSON_CONFIG_FILE" >&2; exit 2; }
  eval "$_singular_cfg_env"
  unset _singular_cfg_env
fi
SINGULAR_CONFIG_FILE="${SINGULAR_CONFIG_FILE:-$SINGULAR_ROOT/singular.config.sh}"
singular_normalize_consumer_path_var SINGULAR_CONFIG_FILE
if [[ -f "$SINGULAR_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SINGULAR_CONFIG_FILE"
fi
singular_normalize_consumer_path_var SINGULAR_STATE_DIR
SINGULAR_LOCAL_CONFIG_FILE="${SINGULAR_LOCAL_CONFIG_FILE:-$SINGULAR_STATE_DIR/config.local.sh}"
singular_normalize_consumer_path_var SINGULAR_LOCAL_CONFIG_FILE
if [[ -f "$SINGULAR_LOCAL_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SINGULAR_LOCAL_CONFIG_FILE"
fi
for _singular_path_var in SINGULAR_STATE_DIR SINGULAR_TASKS_DIR SINGULAR_ORCH_DIR; do
  singular_normalize_consumer_path_var "$_singular_path_var"
done
unset _singular_path_var
if [[ -n "$_singular_bootstrap_bash_bin" ]]; then
  SINGULAR_BASH_BIN="$_singular_bootstrap_bash_bin"
  export SINGULAR_BASH_BIN
else
  unset SINGULAR_BASH_BIN 2>/dev/null || true
fi
unset _singular_bootstrap_bash_bin
# ------------------------------------------------------------------------------

singular_bash_bin() {
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    printf '%s\n' "$SINGULAR_BASH_BIN"
  else
    command -v bash 2>/dev/null || printf '%s\n' /bin/bash
  fi
}

# Resolve the exact Codex executable used by the runner and doctor. An explicit
# value is intentionally strict: it must be an absolute executable path and is
# never replaced by another PATH candidate when broken.
#
# This is the authoritative implementation — codex-run.sh resolves once per
# provider invocation, so it must not pay for a python start. engine/
# provider_resolver.py is the twin that doctor and the console read, and
# tests/test-provider-resolver-parity.sh asserts the two agree on path, exit
# code AND message text. Editing either side is a two-sided edit.
singular_resolve_codex_bin() {
  local configured="${SINGULAR_CODEX_BIN:-}" resolved=""
  if [[ -n "$configured" ]]; then
    if [[ "$configured" != /* ]]; then
      echo "SINGULAR_CODEX_BIN must be an absolute path: $configured" >&2
      return 2
    fi
    if [[ ! -x "$configured" ]]; then
      echo "SINGULAR_CODEX_BIN is not executable: $configured" >&2
      return 127
    fi
    printf '%s\n' "$configured"
    return 0
  fi
  resolved="$(command -v codex 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    echo "codex CLI not found on PATH (set SINGULAR_CODEX_BIN)" >&2
    return 127
  fi
  case "$resolved" in
    /*) ;;
    *) resolved="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd -P)/$(basename "$resolved")" ;;
  esac
  [[ -x "$resolved" ]] || {
    echo "resolved codex CLI is not executable: $resolved" >&2
    return 127
  }
  printf '%s\n' "$resolved"
}

SINGULAR_LOCK_FILE="$SINGULAR_STATE_DIR/locks/origin.lock.json"
SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
SINGULAR_TASKS_DIR="${SINGULAR_TASKS_DIR:-$SINGULAR_ORCH_DIR/tasks}"
SINGULAR_LEASES_DIR="${SINGULAR_LEASES_DIR:-$SINGULAR_STATE_DIR/leases}"
SINGULAR_INBOX_DIR="${SINGULAR_INBOX_DIR:-$SINGULAR_STATE_DIR/inbox}"
SINGULAR_RUNS_DIR="${SINGULAR_RUNS_DIR:-$SINGULAR_STATE_DIR/runs}"
SINGULAR_WORKTREES_DIR="${SINGULAR_WORKTREES_DIR:-$SINGULAR_ROOT/.worktrees}"
SINGULAR_ORIGIN_STATE_FILE="${SINGULAR_ORIGIN_STATE_FILE:-$SINGULAR_STATE_DIR/origin-state.json}"
SINGULAR_GIT_LOCK_DIR="${SINGULAR_GIT_LOCK_DIR:-$SINGULAR_STATE_DIR/locks/git-op.lock}"
SINGULAR_PACKET_SCHEMA="${SINGULAR_PACKET_SCHEMA:-$SINGULAR_SCHEMA_DIR/state-packet.v0.schema.json}"
SINGULAR_AUDIT_SCHEMA="${SINGULAR_AUDIT_SCHEMA:-$SINGULAR_SCHEMA_DIR/audit-verdict.v0.schema.json}"
SINGULAR_DECIDER_SCHEMA="${SINGULAR_DECIDER_SCHEMA:-$SINGULAR_SCHEMA_DIR/decider-verdict.v0.schema.json}"
SINGULAR_GATE_SCHEMA="${SINGULAR_GATE_SCHEMA:-$SINGULAR_SCHEMA_DIR/gate-result.v0.schema.json}"
SINGULAR_TASKBATCH_SCHEMA="${SINGULAR_TASKBATCH_SCHEMA:-$SINGULAR_SCHEMA_DIR/task-batch.v0.schema.json}"
SINGULAR_SUPERVISOR_SCHEMA="${SINGULAR_SUPERVISOR_SCHEMA:-$SINGULAR_SCHEMA_DIR/supervisor-report.v0.schema.json}"
SINGULAR_SECRET_PATTERNS_FILE="${SINGULAR_SECRET_PATTERNS_FILE:-$SINGULAR_ENGINE_DIR/secret-patterns.tsv}"
# Post-worker + integrate validation. No universal default — a repo MUST set its
# gate command (per task `Gate command:` or via config). Empty = no implicit gate.
SINGULAR_DEFAULT_GATE_CMD="${SINGULAR_DEFAULT_GATE_CMD:-}"
# Worker source-tree convention: area -> write-scope path. SINGULAR_AREA_PATHS is a
# newline list of "area=path1[:path2]" entries (set in singular.config.sh); unmapped
# areas fall back to SINGULAR_AREA_PREFIX + area.
SINGULAR_AREA_PREFIX="${SINGULAR_AREA_PREFIX:-internal/}"
SINGULAR_AREA_PATHS="${SINGULAR_AREA_PATHS:-}"
# Optional pre-worker prewarm (e.g. dependency fetch). Empty = none.
SINGULAR_PREWARM_CMD="${SINGULAR_PREWARM_CMD:-}"
# Bot git identity for L0/L1 control-state commits (override per project).
SINGULAR_GIT_L0_NAME="${SINGULAR_GIT_L0_NAME:-singular L0}"
SINGULAR_GIT_L0_EMAIL="${SINGULAR_GIT_L0_EMAIL:-l0@singular.local}"
SINGULAR_GIT_L1_NAME="${SINGULAR_GIT_L1_NAME:-singular L1}"
SINGULAR_GIT_L1_EMAIL="${SINGULAR_GIT_L1_EMAIL:-l1@singular.local}"
# A runner given as a bare filename (e.g. "claude-run.sh") resolves against the
# engine dir; an absolute/relative path is used as-is.
if [[ -n "${SINGULAR_RUNNER:-}" && "$SINGULAR_RUNNER" != */* ]]; then
  SINGULAR_RUNNER="$SINGULAR_ENGINE_DIR/$SINGULAR_RUNNER"
fi
# A gate promoter given as a bare name resolves to a singular-ext module
# (<engine>/singular-ext/<name>.sh); an absolute/relative path is used as-is.
if [[ -n "${SINGULAR_PROMOTER:-}" && "$SINGULAR_PROMOTER" != */* ]]; then
  SINGULAR_PROMOTER="$SINGULAR_ENGINE_HOME/singular-ext/$SINGULAR_PROMOTER.sh"
fi

# Autonomy controls.
SINGULAR_MAX_RETRIES="${SINGULAR_MAX_RETRIES:-3}"            # per-task worker retries before the decider escalates
SINGULAR_AUTO_INTEGRATE="${SINGULAR_AUTO_INTEGRATE:-1}"      # direct reconcile/auto/launchd all integrate accepted work by default
# Decider fast-path (T-F1): when 1 (default), singular_decider_fast_action resolves
# clear-cut failure classes by policy without paying a model decider round-trip;
# set 0 to force every failure through decide.sh (the historical behavior).
SINGULAR_DECIDER_FAST="${SINGULAR_DECIDER_FAST:-1}"
# Infra-failure isolation (T-E6): bounded re-runs of ONLY the failed role when a
# runner times out / refuses / yields no parseable output (broken infrastructure,
# not a real worker/audit failure). These NEVER reach the main retry loop or bump
# the lease retryCount; on exhaustion they surface as worker-infra / audit-infra.
SINGULAR_WORKER_INFRA_MAX="${SINGULAR_WORKER_INFRA_MAX:-1}"  # extra worker re-runs on an infra failure
SINGULAR_AUDIT_INFRA_MAX="${SINGULAR_AUDIT_INFRA_MAX:-2}"    # extra auditor re-runs on an infra failure
# Context-continuity fix/re-audit prompts (T-E3/T-E4). STRUCTURED=1 renders a
# structured fix prompt on retries (authoritative findings + scoped evidence);
# =0 reproduces the legacy fix_hints tail byte-for-byte. SECTION_MAX_CHARS caps
# each appended section so a runaway ledger/log can't blow the prompt budget.
SINGULAR_FIX_PROMPT_STRUCTURED="${SINGULAR_FIX_PROMPT_STRUCTURED:-1}"
SINGULAR_CONTEXT_SECTION_MAX_CHARS="${SINGULAR_CONTEXT_SECTION_MAX_CHARS:-4000}"
SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE="${SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE:-1}"  # task preflight: require non-empty acceptanceCriteria
SINGULAR_MAX_HOURS="${SINGULAR_MAX_HOURS:-20}"              # autonomate.sh wall-clock budget
SINGULAR_MAX_CONSEC_FAILS="${SINGULAR_MAX_CONSEC_FAILS:-5}" # circuit breaker threshold
SINGULAR_STOP_FILE="${SINGULAR_STOP_FILE:-$SINGULAR_STATE_DIR/STOP}"
SINGULAR_STATUS_FILE="${SINGULAR_STATUS_FILE:-$SINGULAR_STATE_DIR/STATUS.md}"
SINGULAR_BREAKER_FILE="${SINGULAR_BREAKER_FILE:-$SINGULAR_STATE_DIR/circuit.json}"
SINGULAR_PLANNER_BACKOFF_FILE="${SINGULAR_PLANNER_BACKOFF_FILE:-$SINGULAR_STATE_DIR/planner-backoff.json}"
# Provider-pressure concurrency adaptation (OPT-IN: default OFF). A planner
# backoff answers "should the loop plan right now"; it says nothing about how
# many workers to run once the window closes. The field run kept re-entering the
# same 429 because concurrency only ever adapted to disk. When enabled, an
# AIMD-style controller halves the dispatch ceiling for ONE provider after a
# cluster of distinct, schema-validated, hash-bound overload/429 evidence, then
# restores it a slot at a time after quiet successful iterations.
#
# With ADAPT=0 nothing observes, nothing is written, and resource-plan output is
# byte-identical to 0.16.0 — the state file is never created.
SINGULAR_PROVIDER_PRESSURE_ADAPT="${SINGULAR_PROVIDER_PRESSURE_ADAPT:-0}"
SINGULAR_PROVIDER_PRESSURE_FILE="${SINGULAR_PROVIDER_PRESSURE_FILE:-$SINGULAR_STATE_DIR/provider-pressure.json}"
# Distinct in-window evidence events before the multiplicative decrease. One 429
# is a data point, not pressure; the default of 2 is the smallest value that can
# still tell a cluster from a single event.
SINGULAR_PROVIDER_PRESSURE_CLUSTER="${SINGULAR_PROVIDER_PRESSURE_CLUSTER:-2}"
SINGULAR_PROVIDER_PRESSURE_WINDOW_SEC="${SINGULAR_PROVIDER_PRESSURE_WINDOW_SEC:-900}" # evidence older than this cannot cluster
SINGULAR_PROVIDER_PRESSURE_RECOVER_QUIET="${SINGULAR_PROVIDER_PRESSURE_RECOVER_QUIET:-3}" # quiet successful iterations per +1 slot
SINGULAR_PROVIDER_PRESSURE_MIN_SLOTS="${SINGULAR_PROVIDER_PRESSURE_MIN_SLOTS:-1}"     # pressure never starves runnable work
SINGULAR_PROVIDER_PRESSURE_MAX_EVENTS="${SINGULAR_PROVIDER_PRESSURE_MAX_EVENTS:-32}"  # per-provider digest ring bound
# Single source of truth for shipped-adapter -> provider identity. Both the
# provider-scoped backoff check and the provider-pressure controller resolve
# identity through singular_runner_provider_identity, which reads this map;
# nothing else may turn a runner path into a provider name.
SINGULAR_ADAPTER_PROVIDERS_JSON='{"codex-run.sh":"codex","claude-run.sh":"claude","gemini-run.sh":"gemini","opencode-run.sh":"opencode","cursor-run.sh":"cursor","openrouter-run.sh":"openrouter","grok-run.sh":"grok"}'
# ---- Governance posture: the context subsystem ships ON (0.20.0) -------------
# Singular's promise is governed autonomy, so a default install must RUN the
# procedure, not merely contain it. Through 0.19.0 these four shipped `0` and the
# README's "Recommended" column was the only thing steering an operator to the
# governed configuration -- which meant the out-of-box experience was the one with
# the fewest guarantees, and every external description of how Singular manages
# context described a configuration nobody was running by default.
#
# Defaulting here (rather than at each read site) keeps ONE place to read the
# posture from and preserves every escape hatch. Each assignment is
# `${VAR:-<default>}`, and BOTH configuration layers are applied earlier in this
# same file -- singular.config.json's env{} at ~line 131 and
# .singular-state/config.local.sh at ~line 141 -- so an operator value set by
# either one survives untouched. A plain environment export survives too, EXCEPT
# where singular.config.json's env{} names the same key: that block is eval'd over
# the process environment, so in a repo that pins a knob there, `VAR=0 singular ...`
# does not override it and the config must be edited instead.
# Setting any of them to 0 restores the 0.19.0 behavior for that feature.
#
# NOT promoted, and deliberately: SINGULAR_REHYDRATE and SINGULAR_CTX_GRAPH stay
# opt-in. Rehydration's per-section cap (SINGULAR_CONTEXT_SECTION_MAX_CHARS)
# truncates within a section content-blind, so the line that mattered can be cut
# from a section selected precisely because it mattered. That is fixed before
# rehydrate is promoted, not after.
#
# The independence pin is NOT in this list and never will be: it binds above the
# routing flag in engine/ctx-route.sh and has no knob at all.
SINGULAR_CTX_ROUTING="${SINGULAR_CTX_ROUTING:-1}"        # 5-strategy routing + lease/window/diff gates
SINGULAR_PLANNER_SESSION="${SINGULAR_PLANNER_SESSION:-1}" # per-node planner session persistence + resume
SINGULAR_CTX_PACKET="${SINGULAR_CTX_PACKET:-1}"          # planner context packets into worker/fix/audit prompts
SINGULAR_PLAN_CRITIQUE="${SINGULAR_PLAN_CRITIQUE:-1}"    # skeptic critic over staged plan batches before import
export SINGULAR_CTX_ROUTING SINGULAR_PLANNER_SESSION SINGULAR_CTX_PACKET SINGULAR_PLAN_CRITIQUE

# Supervisor briefing + ask (0.10.0). All INERT by default: the autonomate loop
# only spawns a periodic briefing when the interval knob is >0, and `singular ask`
# / `singular report` are explicit operator verbs. With INTERVAL_MIN=0 (default) a
# reconcile cycle creates ZERO supervisor artifacts (byte-identical to 0.9.0).
SINGULAR_SUPERVISOR_INTERVAL_MIN="${SINGULAR_SUPERVISOR_INTERVAL_MIN:-0}"    # minutes between auto briefings; 0 = off
SINGULAR_SUPERVISOR_TIMEOUT_SEC="${SINGULAR_SUPERVISOR_TIMEOUT_SEC:-900}"    # readonly briefing runner wall budget
SINGULAR_ASK_TIMEOUT_SEC="${SINGULAR_ASK_TIMEOUT_SEC:-600}"                  # readonly ask runner wall budget
# Detached dispatch (default ON; set to 0 for the legacy batch path). When on,
# reconcile spawns workers in their own session and returns within seconds;
# completion is observed by the reaper on later cycles via dispatch records +
# exit files, so import/integrate/recover/STOP regain their ~SINGULAR_SLEEP cadence
# while workers run. Setting 0 restores batch dispatch: reconcile waits for
# every worker before returning, exactly as the original loop did. Dispatch
# records live outside ensure_state_dirs on purpose: the dir is created only by
# the dispatch-record write path so other commands stay dormant.
SINGULAR_DETACHED_DISPATCH="${SINGULAR_DETACHED_DISPATCH:-1}"
SINGULAR_DISPATCH_DIR="${SINGULAR_DISPATCH_DIR:-$SINGULAR_STATE_DIR/dispatch}"
# Spawn long-lived children as SESSION LEADERS (singular_setsid_exec). A session
# leader's pid IS its process-group id, which is the only descendant-containment
# proof that does not need `ps`: a sandbox that denies process enumeration can
# still be handed one negative pid. Set 0 to restore the pre-0.17 topology
# (children share the spawner's group; cleanup falls back to a ps tree walk).
SINGULAR_SESSION_SPAWN="${SINGULAR_SESSION_SPAWN:-1}"

# L1 node leases + parallel-area planning.
SINGULAR_L1_LEASES_DIR="${SINGULAR_L1_LEASES_DIR:-$SINGULAR_STATE_DIR/l1-leases}"
SINGULAR_L1_LEASE_SCHEMA="${SINGULAR_L1_LEASE_SCHEMA:-$SINGULAR_SCHEMA_DIR/l1-lease.v0.schema.json}"
SINGULAR_L1_STALE_MINUTES="${SINGULAR_L1_STALE_MINUTES:-60}"
# Live L1 fanout (OPT-IN: default OFF — when unset, the actuation path is
# byte-identical to single-node planning). When enabled, L0 plans multiple
# independent DAG nodes concurrently (default 3), then imports their staged task
# proposals serially under the origin lock. L0 stays the only scheduler/importer.
SINGULAR_ENABLE_L1_PARALLEL="${SINGULAR_ENABLE_L1_PARALLEL:-0}"   # 1 enables concurrent L1 planners
SINGULAR_MAX_L1_CONCURRENT="${SINGULAR_MAX_L1_CONCURRENT:-3}"     # default L1 planner concurrency when enabled
SINGULAR_L1_TASKS_PER_NODE="${SINGULAR_L1_TASKS_PER_NODE:-1}"     # tasks each L1 planner proposes per node
SINGULAR_L2_SLICE_BUDGET="${SINGULAR_L2_SLICE_BUDGET:-1}"         # independent strict-test-first slices folded per L2 task (1 = today)
SINGULAR_L2_SLICE_BUDGET_MAX="${SINGULAR_L2_SLICE_BUDGET_MAX:-3}" # hard cap on slice budget (per-task blast-radius guard)
SINGULAR_MIN_DISK_GB="${SINGULAR_MIN_DISK_GB:-2}"                 # below this free-space floor, fanout blocks entirely

# 0.5.0 field-hardening knobs (see CHANGELOG "Migrating from 0.4.0").
# NOTE: the WAKE and task-id-counter paths are derived at CALL time via
# singular_wake_file / singular_task_id_counter_file so fixtures that re-point
# SINGULAR_STATE_DIR after sourcing lib.sh keep working; export the
# corresponding env var to pin a path explicitly.
SINGULAR_SLEEP_POLL_SEC="${SINGULAR_SLEEP_POLL_SEC:-10}"                     # interruptible-sleep chunk size
# Whole-tree liveness: a dispatch is alive if any process in its tree/pgroup
# survives OR its run dir saw writes within this window. HARD_MINUTES bounds
# conservatism: past that lease age we report dead regardless.
SINGULAR_TREE_ACTIVITY_WINDOW_SEC="${SINGULAR_TREE_ACTIVITY_WINDOW_SEC:-120}"
SINGULAR_STALE_HARD_MINUTES="${SINGULAR_STALE_HARD_MINUTES:-240}"
# Legacy pmgo.* schema ids in verdicts: "warn" tolerates + rewrites for
# validation (file untouched); "reject" hard-fails (post-migration hygiene).
SINGULAR_LEGACY_SCHEMA_MODE="${SINGULAR_LEGACY_SCHEMA_MODE:-warn}"

singular_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

singular_run_id() {
  date -u +"ORIGIN-%Y%m%dT%H%M%SZ-$$"
}

singular_ensure_state_dirs() {
  # NOTE: $SINGULAR_L1_LEASES_DIR is intentionally NOT created here. It is created
  # only by the L1 lease write path (singular_l1_lease_write), so ordinary commands
  # stay fully dormant w.r.t. the (deferred) L1-parallel machinery.
  mkdir -p "$SINGULAR_STATE_DIR/locks" "$SINGULAR_STATE_DIR/runs" "$SINGULAR_STATE_DIR/inbox"
}

singular_count_files() {
  local dir="$1"
  shift || true
  [[ -d "$dir" ]] || { echo 0; return 0; }
  find "$dir" "$@" -type f 2>/dev/null | wc -l | tr -d ' '
}

singular_ensure_gitignore_entries() {
  local gi="$SINGULAR_ROOT/.gitignore" entry
  mkdir -p "$(dirname "$gi")"
  touch "$gi"
  for entry in "$@"; do
    [[ -n "$entry" ]] || continue
    grep -qxF "$entry" "$gi" 2>/dev/null || printf '%s\n' "$entry" >>"$gi"
  done
}

singular_ensure_repo_scaffold() {
  mkdir -p \
    "$SINGULAR_ORCH_DIR/prompts" \
    "$SINGULAR_ORCH_DIR/tasks" \
    "$SINGULAR_ORCH_DIR/areas/core" \
    "$SINGULAR_ORCH_DIR/gates" \
    "$SINGULAR_ORCH_DIR/packets/imported" \
    "$SINGULAR_ROOT/schemas/orchestration"

  if [[ ! -f "$SINGULAR_ORCH_DIR/decisions.md" ]]; then
    cat >"$SINGULAR_ORCH_DIR/decisions.md" <<'EOF'
# Decisions

## Decision Log
EOF
  fi
  if [[ ! -f "$SINGULAR_ORCH_DIR/project-state.md" ]]; then
    cat >"$SINGULAR_ORCH_DIR/project-state.md" <<'EOF'
# Project State

Initial singular scaffold. Reconcile snapshots will be maintained below.
EOF
  fi
  if [[ ! -f "$SINGULAR_ORCH_DIR/tasks/TEMPLATE.md" ]]; then
    cat >"$SINGULAR_ORCH_DIR/tasks/TEMPLATE.md" <<'EOF'
# TASK-XXXX: <title>

Status: ready
Area: core
DAG node: <node-id>
Target branch: `agent/integration`
Worker branch: `agent/core/TASK-XXXX-<slug>`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Describe the smallest independently verifiable change.

## Scope

Owned files:

- `path/to/file`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The gate command passes.
EOF
  fi
  if [[ ! -f "$SINGULAR_ORCH_DIR/planner-contract.md" ]]; then
    cat >"$SINGULAR_ORCH_DIR/planner-contract.md" <<'EOF'
# Planner Contract

Create small, canonical tasks that can be validated by their gate command. Keep
owned files narrow, declare dependencies explicitly, and do not broaden scope
without a recorded decision.
EOF
  fi
  if [[ ! -f "$SINGULAR_ORCH_DIR/areas/core/state.md" ]]; then
    cat >"$SINGULAR_ORCH_DIR/areas/core/state.md" <<'EOF'
# Core Area State

Status: starter
EOF
  fi
  if [[ -d "$SINGULAR_SCHEMA_DIR" ]]; then
    local schema base tmp repo_schema="" engine_schema=""
    if [[ -f "$SINGULAR_ROOT/singular.config.json" ]]; then
      repo_schema="$(python3 - "$SINGULAR_ROOT/singular.config.json" <<'PY' 2>/dev/null || true
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8")).get("schemaVersion")
print(value if isinstance(value, str) else "")
PY
)"
    fi
    if [[ -f "$SINGULAR_ENGINE_HOME/SCHEMA_VERSION" ]]; then
      engine_schema="$(tr -d '[:space:]' <"$SINGULAR_ENGINE_HOME/SCHEMA_VERSION")"
    fi
    # The engine bundle becomes authoritative only after migration has advanced
    # the consumer config to the same schema version. Until then, preserve every
    # existing mirror byte-for-byte and do not introduce newer contracts.
    if [[ -n "$repo_schema" && "$repo_schema" == "$engine_schema" ]]; then
      while IFS= read -r schema; do
        [[ -n "$schema" ]] || continue
        base="$(basename "$schema")"
        tmp="$SINGULAR_ROOT/schemas/orchestration/.$base.tmp.$$"
        cp "$schema" "$tmp"
        mv "$tmp" "$SINGULAR_ROOT/schemas/orchestration/$base"
      done < <(find "$SINGULAR_SCHEMA_DIR" -maxdepth 1 -name '*.schema.json' -type f 2>/dev/null | sort)
    fi
  fi
  singular_ensure_gitignore_entries ".singular-state/" ".worktrees/" ".singular-evidence/" ".singular-cache/"
}

singular_json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))' 
}

singular_json_field() {
  local file="$1"
  local field="$2"
  python3 - "$file" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
value = data
for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(2)
    value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

singular_packet_has_accept_waiver() {
  local packet="$1"
  local current_campaign_binding
  singular_unbound_waivers_enabled || return 1
  current_campaign_binding="$(singular_campaign_binding 2>/dev/null)" || return 1
  python3 - "$packet" "$SINGULAR_RUNS_DIR" "$SINGULAR_ORCH_DIR/decisions.md" \
    "$current_campaign_binding" <<'PY'
import json
import os
import sys

packet_path, runs_dir, decisions_path, current_binding = sys.argv[1:5]
try:
    with open(packet_path, encoding="utf-8") as f:
        packet = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(1)

task = str(packet.get("taskId", ""))
run = str(packet.get("runId", ""))
branch = str(packet.get("branch", ""))
if not task or not run or packet.get("status") != "accepted":
    sys.exit(1)

evidence = packet.get("evidence", [])
packet_binding = next((
    str(item.get("ref", "")) for item in evidence
    if isinstance(item, dict) and item.get("kind") == "campaign-binding"
), "")
if not packet_binding and current_binding == "legacy":
    packet_binding = "legacy"
has_waiver_ref = any(
    isinstance(item, dict)
    and item.get("kind") == "waiver"
    and item.get("ref") == "decider:accept-waiver"
    for item in evidence
)
if not has_waiver_ref:
    sys.exit(1)

decision_json_ok = False
decision_path = os.path.join(runs_dir, run, "decision-audit-needs-fix.json")
try:
    with open(decision_path, encoding="utf-8") as f:
        decision = json.load(f)
    decision_binding = str(decision.get("campaignBinding", ""))
    decision_run = str(decision.get("runId", ""))
    if not decision_binding and current_binding == "legacy":
        decision_binding = "legacy"
    if not decision_run and current_binding == "legacy":
        decision_run = run
    decision_json_ok = (
        decision.get("taskId") == task
        and decision.get("action") == "accept-waiver"
        and decision.get("failureClass") == "audit-needs-fix"
        and decision_run == run
        and packet_binding == current_binding
        and decision_binding == current_binding
    )
except (OSError, json.JSONDecodeError):
    decision_json_ok = False

# Markdown is an operator-facing journal, not structured authority. Combining
# task/run/branch substrings from unrelated sections allowed a false waiver;
# only the run-local decision JSON can authorize this compatibility path.
if decision_json_ok:
    sys.exit(0)
sys.exit(1)
PY
}

# Unbound decider waivers predate exact-artifact human approvals. Schema v2
# disables them unless the operator deliberately selects the legacy
# compatibility switch; pre-v2 consumers retain their historical behavior.
singular_unbound_waivers_enabled() {
  local selected="${SINGULAR_LEGACY_UNBOUND_WAIVERS:-}"
  if [[ -n "$selected" ]]; then
    case "${selected,,}" in
      1|true|yes|on) return 0 ;;
      *) return 1 ;;
    esac
  fi
  [[ "${SINGULAR_CONFIG_SCHEMA_VERSION:-}" != "v2" ]]
}

singular_packet_acceptance_mode() {
  local packet="$1"
  local audit_record="$2"
  local verdict=""
  if [[ -f "$audit_record" ]]; then
    verdict="$(singular_json_field "$audit_record" verdict 2>/dev/null || true)"
    if [[ "$verdict" == "accepted" ]]; then
      echo "accepted"
      return 0
    fi
  fi
  if singular_packet_has_accept_waiver "$packet"; then
    echo "accepted-waiver"
    return 0
  fi
  return 1
}

singular_scope_amendment_path_allowed() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  case "$path" in
    .singular-cache|.singular-cache/*|.singular-state|.singular-state/*|.singular-evidence|.singular-evidence/*)
      return 1
      ;;
  esac
  return 0
}

# ---- Decider/parking hooks (generic; overridden by enabled modules) ----------
# Whether a terminal external-resource blocker applies to a failed gate. Generic: never.
singular_gate_red_external_proof_env_blocker() { return 1; }
# Whether the worker introduced a skipped proof path. Generic: never.
singular_strict_proof_skip_detected() { return 1; }
# Terminal parking rationale for a failure class (non-empty => park). Generic: none.
singular_terminal_blocker_rationale() { printf ''; }

# ---- Decider fast-path (T-F1) -------------------------------------------------
# Resolve a clear-cut failure class to a recovery action by policy, avoiding a
# model decider round-trip. Prints exactly ONE action token on stdout, OR prints
# nothing (empty) meaning "consult the model decider (decide.sh)".
#   singular_decider_fast_action <failure_class> <retry_count> <max_retries> <prev_failure_class>
# retry_count/max_retries are evaluated as the CALLER's budget accounting (the
# loop's 0-based attempt vs max_retries) so "retries remaining" (left) matches
# exactly when the existing loop decides to retry-vs-park. Logic, in order:
#   1. integrity-violation              -> escalate-parked (human judgment is
#      mandatory; never retry or consult the model).
#   2. SINGULAR_DECIDER_FAST != 1        -> empty (force the model path).
#   3. failure_class == prev (repeat)    -> empty (a same-class repeat may be
#      systemic; escalate to the model for judgment).
#   4. table on left = max_retries - retry_count (>0 => budget remains).
singular_decider_fast_action() {
  local failure_class="$1" retry_count="${2:-0}" max_retries="${3:-0}" prev="${4:-}"
  # Deterministic containment event: a human must judge the work. This precedes
  # both the disable and repeat guards so the class can never reach the model.
  if [[ "$failure_class" == "integrity-violation" ]]; then
    printf 'escalate-parked'
    return 0
  fi
  [[ "${SINGULAR_DECIDER_FAST:-1}" == "1" ]] || return 0
  [[ "$retry_count" =~ ^[0-9]+$ ]] || retry_count=0
  [[ "$max_retries" =~ ^[0-9]+$ ]] || max_retries=0
  # A same-class repeat escalates to the model (could be systemic).
  if [[ -n "$failure_class" && "$failure_class" == "$prev" ]]; then
    return 0
  fi
  local left=$((max_retries - retry_count))
  local has_budget="no"
  [[ "$left" -gt 0 ]] && has_budget="yes"
  case "$failure_class" in
    gate-red|worker-no-packet|packet-invalid|no-changes|commit-failed)
      if [[ "$has_budget" == "yes" ]]; then printf 'retry'; else printf 'escalate-parked'; fi ;;
    scope-violation)
      if [[ "$has_budget" == "yes" ]]; then printf 'amend-scope'; else printf 'escalate-parked'; fi ;;
    worker-infra|audit-infra)
      # A model decider cannot fix broken infrastructure, so this never consults
      # the retry budget. It parks as `escalate-infra` rather than
      # `escalate-parked` because the two mean opposite things to whoever reads
      # the queue: escalate-parked is "a human must judge this work",
      # escalate-infra is "the work is fine, the environment is not". The
      # decider correctly diagnosed exactly that in the field ("a
      # dependency-provisioning gap in the disposable audit workspace, not a
      # product defect") and had no action in its vocabulary to say it. Both
      # come back through `singular unpark`.
      printf 'escalate-infra' ;;
    audit-needs-fix)
      # Buildable while budget remains; otherwise the model weighs accept-waiver.
      if [[ "$has_budget" == "yes" ]]; then printf 'retry'; else return 0; fi ;;
    *)
      # audit-blocked, audit-needs-human, audit-unknown, secret-detected,
      # proof-skip-detected, and any unlisted class -> the model decides.
      return 0 ;;
  esac
}

singular_append_event() {
  local type="$1"
  local message="$2"
  local data
  if [[ $# -ge 3 ]]; then
    data="$3"
  else
    data="{}"
  fi
  singular_ensure_state_dirs
  python3 - "$SINGULAR_EVENTS_FILE" "$type" "$message" "$data" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, typ, message, data_raw = sys.argv[1:5]
try:
    data = json.loads(data_raw)
except json.JSONDecodeError:
    data = {"raw": data_raw}
event = {
    "ts": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "type": typ,
    "message": message,
    "data": data,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}

# Verify the immutable campaign boundary before a control-plane mutation.
#
# Planning fanout deliberately points SINGULAR_TASKS_DIR at a request-scoped
# staging directory.  That path is not campaign policy: the canonical task
# root is.  Normalize it only when the staged task directory is actually
# contained by SINGULAR_PLANNING_ARTIFACT_DIR; an arbitrary caller-provided
# task directory remains fingerprinted and therefore fails closed.
#
# Arguments: entrypoint [phase].  Returns 2 for every refusal so callers do not
# accidentally classify campaign drift as a product/gate failure.  Event
# emission is best-effort because an unavailable journal must not turn a clean
# refusal into a different failure class.
singular_campaign_verify_or_refuse() {
  local entrypoint="${1:-control-plane}" phase="${2:-entry}"
  local campaign_script="$SINGULAR_LIB_DIR/campaign.sh"
  local verify_tasks_dir="$SINGULAR_TASKS_DIR" verify_rc=0 event_json=""

  if [[ -n "${SINGULAR_PLANNING_ARTIFACT_DIR:-}" ]] \
      && python3 - "$SINGULAR_TASKS_DIR" "$SINGULAR_PLANNING_ARTIFACT_DIR" <<'PY' >/dev/null 2>&1
import os
import sys

tasks = os.path.realpath(sys.argv[1])
artifacts = os.path.realpath(sys.argv[2])
try:
    contained = os.path.commonpath((tasks, artifacts)) == artifacts
except ValueError:
    contained = False
raise SystemExit(0 if contained else 1)
PY
  then
    verify_tasks_dir="$SINGULAR_ORCH_DIR/tasks"
  fi

  SINGULAR_TASKS_DIR="$verify_tasks_dir" \
    "$campaign_script" verify --quiet || verify_rc=$?
  [[ "$verify_rc" -eq 0 ]] && return 0

  echo "$entrypoint: campaign runtime drift at $phase; control-plane mutation refused" >&2
  event_json="$(python3 - "$entrypoint" "$phase" \
      "${SINGULAR_CAMPAIGN_MANIFEST:-$SINGULAR_STATE_DIR/campaign/manifest.json}" \
      "$verify_rc" <<'PY' 2>/dev/null || true
import json
import sys

print(json.dumps({
    "entrypoint": sys.argv[1],
    "phase": sys.argv[2],
    "manifest": sys.argv[3],
    "verifyExitCode": int(sys.argv[4]),
}, separators=(",", ":")))
PY
)"
  singular_append_event "campaign.drift_detected" \
    "$entrypoint refused campaign runtime drift" "${event_json:-{}}" \
    >/dev/null 2>&1 || true
  return 2
}

# Return one opaque identity for the campaign policy under which durable work
# is produced.  `legacy` is an identity too: work accepted before a campaign
# starts must not silently cross into a newly frozen campaign.  Partial state
# is never treated as legacy.
singular_campaign_binding() {
  local manifest="${SINGULAR_CAMPAIGN_MANIFEST:-$SINGULAR_STATE_DIR/campaign/manifest.json}"
  local active="$(dirname "$manifest")/ACTIVE"
  local epoch="$(dirname "$manifest")/EPOCH"
  local transition="$(dirname "$manifest")/TRANSITION"
  local enforced="$SINGULAR_STATE_DIR/CAMPAIGN_ENFORCED"
  python3 - "$manifest" "$active" "$enforced" "$epoch" "$transition" <<'PY'
import hashlib
import json
import os
import re
import sys

manifest, active, enforced, epoch, transition = sys.argv[1:6]
if os.path.exists(transition):
    raise SystemExit(2)
present = [os.path.isfile(path) for path in (manifest, active, enforced)]
if not any(present):
    if os.path.isfile(epoch):
        try:
            inactive_epoch = open(epoch, encoding="utf-8").read().strip()
        except OSError:
            raise SystemExit(2)
        if not re.fullmatch(r"[0-9a-f]{48}", inactive_epoch):
            raise SystemExit(2)
        print(f"legacy:epoch:{inactive_epoch}")
    elif os.path.exists(epoch):
        raise SystemExit(2)
    else:
        # Virgin repositories retain the historical compatibility identity.
        print("legacy")
    raise SystemExit(0)
if not all(present):
    raise SystemExit(2)
try:
    raw = open(manifest, "rb").read()
    data = json.loads(raw)
    campaign_id = str(data.get("campaignId", ""))
    manifest_epoch = str(data.get("campaignEpoch", ""))
    active_id = open(active, encoding="utf-8").read().strip()
    latch = open(enforced, encoding="utf-8").read().strip()
except (OSError, ValueError, TypeError):
    raise SystemExit(2)
if not re.fullmatch(r"[A-Za-z0-9._:-]+", campaign_id):
    raise SystemExit(2)
if active_id != campaign_id or latch != "singular-campaign-enforced-v1":
    raise SystemExit(2)
epoch_suffix = ""
if manifest_epoch:
    try:
        active_epoch = open(epoch, encoding="utf-8").read().strip()
    except OSError:
        raise SystemExit(2)
    if not re.fullmatch(r"[0-9a-f]{48}", manifest_epoch) or active_epoch != manifest_epoch:
        raise SystemExit(2)
    epoch_suffix = f":epoch:{manifest_epoch}"
elif os.path.exists(epoch):
    # An upgraded legacy manifest may coexist with a transition epoch; bind it
    # even though the historical manifest did not record the field.
    try:
        active_epoch = open(epoch, encoding="utf-8").read().strip()
    except OSError:
        raise SystemExit(2)
    if not re.fullmatch(r"[0-9a-f]{48}", active_epoch):
        raise SystemExit(2)
    epoch_suffix = f":epoch:{active_epoch}"
print(f"campaign:{campaign_id}:sha256:{hashlib.sha256(raw).hexdigest()}{epoch_suffix}")
PY
}

_singular_campaign_binding_compare() {
  local expected="$1" entrypoint="${2:-control-plane}" phase="${3:-binding-check}"
  local actual="" event_json=""
  actual="$(singular_campaign_binding 2>/dev/null)" || actual=""
  if [[ -n "$actual" && "$actual" == "$expected" ]]; then
    return 0
  fi
  echo "$entrypoint: campaign identity changed at $phase; control-plane mutation refused" >&2
  event_json="$(python3 - "$entrypoint" "$phase" "$expected" "$actual" <<'PY' 2>/dev/null || true
import json
import sys
print(json.dumps({
    "entrypoint": sys.argv[1],
    "phase": sys.argv[2],
    "expectedBinding": sys.argv[3],
    "actualBinding": sys.argv[4],
}, separators=(",", ":")))
PY
)"
  singular_append_event "campaign.identity_mismatch" \
    "$entrypoint refused work from a different campaign identity" \
    "${event_json:-{}}" >/dev/null 2>&1 || true
  return 2
}

# Full policy checkpoint for a long-running operation. This intentionally
# fingerprints engine/config/prompt bytes and then compares the opaque campaign
# identity captured by the caller. Use it at entry/cycle boundaries and after
# provider or gate work, outside serialized publication critical sections.
singular_campaign_binding_matches() {
  local expected="$1" entrypoint="${2:-control-plane}" phase="${3:-binding-check}"
  singular_campaign_verify_or_refuse "$entrypoint" "$phase" || return 2
  _singular_campaign_binding_compare "$expected" "$entrypoint" "$phase"
}

# Serialize campaign transitions with the tiny publication critical sections
# that turn a reviewed result into authoritative state. Long-running model and
# gate work stays outside this lock; publishers acquire it only for the final
# binding compare-and-swap plus mutation.
singular_campaign_lock_path() {
  local manifest="${SINGULAR_CAMPAIGN_MANIFEST:-$SINGULAR_STATE_DIR/campaign/manifest.json}"
  python3 - "$manifest" <<'PY'
import os
import sys

manifest = os.path.abspath(sys.argv[1])
parent = os.path.dirname(manifest)
if parent == os.path.sep:
    print("unsafe campaign publication lock parent: %s" % parent, file=sys.stderr)
    raise SystemExit(2)
print(os.path.join(parent, ".publication-lock"))
PY
}

singular_campaign_lock_owned() {
  local lock_dir owner_file owner_pid pid_file_pid owner_token process_id
  lock_dir="$(singular_campaign_lock_path)" || return 2
  owner_file="$lock_dir/owner.json"
  process_id="${BASHPID:-$$}"
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  owner_pid="$(singular_json_field "$owner_file" pid 2>/dev/null || true)"
  owner_token="$(singular_json_field "$owner_file" token 2>/dev/null || true)"
  pid_file_pid="$(cat "$lock_dir/pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$owner_pid" == "$process_id" && "$pid_file_pid" == "$process_id" \
      && -n "${SINGULAR_CAMPAIGN_LOCK_CAPABILITY:-}" \
      && "$owner_token" == "$SINGULAR_CAMPAIGN_LOCK_CAPABILITY" ]]
}

# Final publication CAS. The expensive runtime fingerprint must already have
# been checked before taking the lock; while holding it, only ACTIVE/latch,
# manifest bytes and epoch are compared. This closes campaign replace/end ABA
# races without serializing parallel publishers behind recursive tree hashing.
singular_campaign_publication_cas() {
  local expected="$1" entrypoint="${2:-control-plane}" phase="${3:-publication-cas}"
  if ! singular_campaign_lock_owned; then
    echo "$entrypoint: campaign publication CAS requires the owned publication lock" >&2
    return 2
  fi
  _singular_campaign_binding_compare "$expected" "$entrypoint" "$phase"
}

singular_campaign_lock_remove_stale() {
  local stale_path="$1" lock_dir suffix
  lock_dir="$(singular_campaign_lock_path)" || return 2
  suffix="${stale_path#"$lock_dir.stale."}"
  if [[ "$stale_path" != "$lock_dir.stale."* \
      || ! "$suffix" =~ ^[1-9][0-9]*\.[0-9a-f]{32}$ ]]; then
    echo "refusing cleanup outside campaign publication lock: $stale_path" >&2
    return 2
  fi
  # rm does not follow a command-line symlink. Quarantining first and removing
  # only this capability-suffixed exact path avoids traversing an attacker-
  # supplied lock symlink via "$stale/owner.json" or "$stale/pid".
  rm -rf -- "$stale_path"
}

singular_campaign_lock_acquire() {
  local lock_dir owner_file owner_pid pid_file_pid owner_token process_id waited=0 stale temporary
  local wait_limit="${SINGULAR_CAMPAIGN_LOCK_WAIT_TICKS:-600}"
  lock_dir="$(singular_campaign_lock_path)" || return 2
  owner_file="$lock_dir/owner.json"
  process_id="${BASHPID:-$$}"
  [[ "$wait_limit" =~ ^[1-9][0-9]*$ ]] || wait_limit=600
  if ! owner_token="$(python3 -c 'import secrets; print(secrets.token_hex(16))')" \
      || [[ ! "$owner_token" =~ ^[0-9a-f]{32}$ ]]; then
    echo "could not generate campaign publication lock capability" >&2
    return 1
  fi
  mkdir -p "$(dirname "$lock_dir")" || return 1
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [[ -L "$lock_dir" ]]; then
      echo "refusing symlink campaign publication lock: $lock_dir" >&2
      return 2
    fi
    owner_pid=""
    pid_file_pid=""
    owner_pid="$(singular_json_field "$owner_file" pid 2>/dev/null || true)"
    pid_file_pid="$(cat "$lock_dir/pid" 2>/dev/null | tr -d '[:space:]' || true)"
    if { [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] \
          && singular_pid_alive "$owner_pid"; } \
        || { [[ "$pid_file_pid" =~ ^[1-9][0-9]*$ ]] \
          && singular_pid_alive "$pid_file_pid"; }; then
      waited=$((waited + 1))
      if [[ "$waited" -ge "$wait_limit" ]]; then
        echo "timed out waiting for campaign publication lock: $lock_dir" >&2
        return 75
      fi
      sleep 0.1
      continue
    fi
    # A creator can briefly own the directory before its pid file is visible.
    if [[ -z "$owner_pid" && -z "$pid_file_pid" && "$waited" -lt 10 ]]; then
      waited=$((waited + 1))
      if [[ "$waited" -ge "$wait_limit" ]]; then
        echo "timed out waiting for campaign publication lock: $lock_dir" >&2
        return 75
      fi
      sleep 0.1
      continue
    fi
    stale="$lock_dir.stale.$process_id.$owner_token"
    if mv "$lock_dir" "$stale" 2>/dev/null; then
      singular_campaign_lock_remove_stale "$stale" || return $?
      waited=0
    fi
  done
  if ! printf '%s\n' "$process_id" >"$lock_dir/pid"; then
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  temporary="$lock_dir/.owner.$process_id.tmp"
  if ! python3 - "$temporary" "$process_id" "$owner_token" <<'PY'
import json
import sys

path, pid, token = sys.argv[1:4]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({"pid": int(pid), "token": token}, stream, separators=(",", ":"))
    stream.write("\n")
PY
  then
    rm -f "$temporary" 2>/dev/null || true
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  if ! mv "$temporary" "$owner_file"; then
    rm -f "$temporary" 2>/dev/null || true
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  SINGULAR_CAMPAIGN_LOCK_CAPABILITY="$owner_token"
  return 0
}

singular_campaign_lock_release() {
  local lock_dir owner_file owner_pid pid_file_pid owner_token process_id
  lock_dir="$(singular_campaign_lock_path)" || return 2
  owner_file="$lock_dir/owner.json"
  process_id="${BASHPID:-$$}"
  [[ -d "$lock_dir" ]] || return 0
  [[ ! -L "$lock_dir" ]] || return 1
  owner_pid="$(singular_json_field "$owner_file" pid 2>/dev/null || true)"
  owner_token="$(singular_json_field "$owner_file" token 2>/dev/null || true)"
  pid_file_pid="$(cat "$lock_dir/pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$owner_pid" == "$process_id" && "$pid_file_pid" == "$process_id" \
      && -n "${SINGULAR_CAMPAIGN_LOCK_CAPABILITY:-}" \
      && "$owner_token" == "$SINGULAR_CAMPAIGN_LOCK_CAPABILITY" ]] || return 1
  rm -f "$owner_file"
  rm -f "$lock_dir/pid"
  if rmdir "$lock_dir"; then
    unset SINGULAR_CAMPAIGN_LOCK_CAPABILITY
    return 0
  fi
  return 1
}

singular_require_target_branch() {
  if [[ -z "${SINGULAR_TARGET_BRANCH:-}" ]]; then
    echo "SINGULAR_TARGET_BRANCH is required" >&2
    return 2
  fi
  if ! git -C "$SINGULAR_ROOT" rev-parse --verify --quiet "$SINGULAR_TARGET_BRANCH" >/dev/null; then
    echo "target branch not found: $SINGULAR_TARGET_BRANCH" >&2
    return 2
  fi
}

singular_current_branch() {
  git -C "$SINGULAR_ROOT" branch --show-current
}

singular_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Replace the CURRENT process with "$@" as the leader of a NEW session.
#
# Meant to be the last command of a background job (`spawn_something args &`):
# `exec` preserves the pid, so `$!` in the spawner IS the session leader, and
# setsid makes that pid equal to its own process-group id. The spawner keeps the
# child un-reaped, which is what makes the pid (and therefore the pgid) safe to
# signal later: neither can be recycled while the entry is still in the table.
#
# That equality — pgid == pid — is the whole point. It is a containment proof
# that costs one integer and no process enumeration, which is what
# singular_kill_tree needs in a sandbox that denies `ps`.
#
# SINGULAR_SESSION_SPAWN=0 restores the old topology (plain exec, child stays in
# the spawner's group). Same idiom as engine/reconcile.sh's detached dispatch.
singular_setsid_exec() {
  if [[ "${SINGULAR_SESSION_SPAWN:-1}" == "0" ]]; then
    exec "$@"
  fi
  exec python3 -c 'import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])' "$@"
}

# Durably record what a spawner knows about a session it just created:
#   {"pid":N,"pgid":N|0,"sessionSpawn":bool,"verified":bool,"startedAt":"..."}
# `verified` is true only when the kernel confirms pgid == pid, i.e. the child
# really is a session/group leader and the negative-pid kill is safe. A denied
# or failed lookup records pgid 0 + verified false rather than guessing: an
# unproven group is exactly the thing that must NOT be signalled.
#
# The lookup is os.getpgid, never `ps` — this record has to be writable in the
# same restricted sandboxes the group kill exists for. Three 50ms attempts
# absorb the race where the record is written before the child reaches setsid.
# args: path pid
singular_session_record_write() {
  local path="$1" pid="${2:-}"
  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir" 2>/dev/null || true
  local spawn=1
  [[ "${SINGULAR_SESSION_SPAWN:-1}" == "0" ]] && spawn=0
  python3 - "$path" "$pid" "$spawn" <<'PY'
import json
import os
import sys
import time
from datetime import datetime, timezone

path, pid_raw, spawn_raw = sys.argv[1:4]
try:
    pid = int(pid_raw)
except ValueError:
    pid = 0
pgid = 0
verified = False
if pid > 0:
    for attempt in range(3):
        try:
            pgid = os.getpgid(pid)
        except ProcessLookupError:
            pgid, verified = 0, False
            break
        except OSError:
            pgid, verified = 0, False
        else:
            verified = pgid == pid
        if verified:
            break
        if attempt < 2:
            time.sleep(0.05)
record = {
    "pid": pid,
    "pgid": pgid,
    "sessionSpawn": spawn_raw != "0",
    "verified": verified,
    "startedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# Process-group id of a pid, via os.getpgid (no `ps`). Empty when unknowable.
singular_pgid_of() {
  python3 - "${1:-}" <<'PY' 2>/dev/null || true
import os
import sys

try:
    sys.stdout.write("%d\n" % os.getpgid(int(sys.argv[1])))
except Exception:
    pass
PY
}

# rc 0 if any process remains in <pgid>. EPERM counts as ALIVE: "I am not
# allowed to signal it" is not "it is gone", and every caller here is deciding
# whether cleanup finished.
singular_pgroup_alive() {
  local pgid="${1:-}"
  [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]] || return 1
  python3 - "$pgid" <<'PY' 2>/dev/null
import os
import sys

try:
    os.kill(-int(sys.argv[1]), 0)
except ProcessLookupError:
    sys.exit(1)
except Exception:
    sys.exit(0)
sys.exit(0)
PY
}

# Kill a pid and everything it spawned. Args 1-2 are unchanged from 0.16:
#   singular_kill_tree <pid> [grace_sec] [session]
# The optional third argument is the literal word `session`: the caller's
# assertion that it spawned <pid> through singular_setsid_exec and has not
# waited on it yet. Shared by the provider runners / decide.sh / gate guards.
#
# ALWAYS returns 0 — callers run under `set -euo pipefail` and a cleanup trap
# must not become the failure. The outcome is reported instead through the
# global SINGULAR_KILL_TREE_RESULT (verified|degraded), plus
# SINGULAR_KILL_TREE_REASON / SINGULAR_KILL_TREE_MODE.
#
# THREE MODES, in decreasing order of proof:
#   group-proven    os.getpgid(pid) == pid (a session leader), and not our own
#                   group. One os.kill(-pgid, sig) reaches every descendant.
#   group-asserted  os.getpgid was DENIED but the caller passed `session` and
#                   the group still answers os.kill(-pid, 0). Safe because the
#                   spawner still holds the un-reaped child, so pid/pgid cannot
#                   have been recycled under us.
#   tree            neither proof holds: fall back to the 0.16 behaviour, a
#                   `ps` snapshot walk killed leaves-first. A negative pid is
#                   NEVER signalled without one of the two proofs above.
# Both group modes still attempt enumeration, and individually signal any
# descendant that has left the group (a child that called setsid itself).
#
# WHY: 0.16 built the target list solely from `ps -A`, ignored its return code,
# and wrapped the lot in `2>/dev/null || true`. In a sandbox that denies `ps`
# the child map came back empty, only the root was signalled, descendants
# survived a timeout — and the failure was invisible (field finding PMGO-004).
# So the kill now ends with a bounded VERIFY poll and, when it cannot prove the
# tree is gone, says so on stderr and in a `kill.unverified` event.
#
# DELIBERATE DEVIATION: in a group mode with a verified group death, a failed
# `ps` enumeration does NOT degrade the result — the group is proof enough, and
# the enumeration was only looking for escapees. That case emits an
# informational `kill.enumeration_unavailable` event instead. Tree mode keeps
# the strict rule, because there enumeration IS the containment.
#
# grace_sec (default 0) keeps its 0.16 meaning: >0 sends SIGTERM first and
# SIGKILLs only what is still alive when it expires, so a runner can run the
# EXIT trap that holds its read-only restore guard; 0 is an immediate SIGKILL
# with no handler. An empty pid is a verified no-op: the runner guards that call
# this from an EXIT trap may have nothing to kill, and nothing cannot survive.
singular_kill_tree() {
  local pid="${1:-}" grace="${2:-0}" claim="${3:-}"
  SINGULAR_KILL_TREE_RESULT="verified"
  SINGULAR_KILL_TREE_REASON=""
  SINGULAR_KILL_TREE_MODE="none"
  [[ -n "$pid" ]] || return 0
  local out="" rc=0
  out="$(python3 - "$pid" "$grace" "$claim" <<'PY'
import os
import signal
import subprocess
import sys
import time

VERIFY_SEC = 5.0
STEP = 0.2


def emit(status, reason, mode, note=""):
    """Single machine-readable line for bash; stderr stays for real errors."""
    if note:
        sys.stdout.write("KILLTREE_NOTE %s %s\n" % (note, mode))
    sys.stdout.write("KILLTREE_RESULT %s %s %s\n" % (status, reason or "-", mode))
    sys.stdout.flush()
    raise SystemExit(0 if status == "verified" else 3)


def enumerate_descendants(root):
    """(enumeration_ok, dfs order). ok is False when ps was denied/failed."""
    try:
        proc = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid="],
                              capture_output=True, text=True)
    except OSError:
        return False, []
    if proc.returncode != 0:
        return False, []
    children = {}
    for line in (proc.stdout or "").splitlines():
        f = line.split()
        if len(f) != 2:
            continue
        try:
            pid, ppid = int(f[0]), int(f[1])
        except ValueError:
            continue
        children.setdefault(ppid, []).append(pid)
    order, stack, seen = [], [root], set([root])
    while stack:
        p = stack.pop()
        for c in children.get(p, []):
            if c in seen:
                continue
            seen.add(c)
            order.append(c)
            stack.append(c)
    return True, order


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True   # EPERM: it is there, we just may not signal it
    return True


def group_alive(pgid):
    try:
        os.kill(-pgid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def main():
    try:
        root = int(sys.argv[1])
    except ValueError:
        emit("degraded", "invalid-pid", "none")
    try:
        grace = float(sys.argv[2] or 0)
    except ValueError:
        grace = 0.0
    asserted = len(sys.argv) > 3 and sys.argv[3] == "session"
    if root <= 1:
        emit("degraded", "invalid-pid", "none")

    try:
        own_pgid = os.getpgid(0)
    except OSError:
        own_pgid = -1

    mode, pgid = "tree", 0
    try:
        found = os.getpgid(root)
    except PermissionError:
        # The sandbox case. Only an explicit session claim (third argument)
        # from the caller can stand in for the lookup, and only while the
        # group still answers. (No apostrophes, backticks, or unbalanced
        # quotes in this heredoc: bash 3.2 scans $( ) without understanding
        # embedded heredocs, and one stray quote breaks the parse of this
        # whole file for pre-4 shells that only need to fail cleanly.)
        if asserted and root != own_pgid and group_alive(root):
            mode, pgid = "group-asserted", root
    except OSError:
        pass          # gone, or unknowable -> tree mode handles both
    else:
        if found == root and found != own_pgid and found > 1:
            mode, pgid = "group-proven", found

    enum_ok, order = enumerate_descendants(root)
    escapees = []
    if mode != "tree":
        for pid in order:
            try:
                if os.getpgid(pid) == pgid:
                    continue
            except OSError:
                pass  # cannot prove membership -> signal it directly too
            escapees.append(pid)
    # Leaves first so a parent cannot spawn a replacement for a child it lost.
    targets = list(reversed(order)) + [root]

    def send(sig):
        if mode == "tree":
            # The root goes LAST: it is the bash runner holding the EXIT trap,
            # and signalling it before its children would have it restore the
            # worktree while the provider is still writing to it.
            for pid in list(reversed(order)):
                try:
                    os.kill(pid, sig)
                except OSError:
                    pass
            try:
                os.kill(root, sig)
            except OSError:
                pass
            return
        try:
            os.kill(-pgid, sig)
        except OSError:
            pass
        for pid in escapees:
            try:
                os.kill(pid, sig)
            except OSError:
                pass

    def alive():
        if mode == "tree":
            return any(pid_alive(p) for p in targets)
        if group_alive(pgid):
            return True
        return any(pid_alive(p) for p in escapees)

    died_on_term = False
    if grace > 0:
        send(signal.SIGTERM)
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            if not alive():
                died_on_term = True
                break
            time.sleep(STEP)
    if not died_on_term:
        send(signal.SIGKILL)

    deadline = time.monotonic() + VERIFY_SEC
    gone = not alive()
    while not gone and time.monotonic() < deadline:
        time.sleep(STEP)
        gone = not alive()

    if not gone:
        emit("degraded", "survivors-or-unsignalable", mode)
    if mode == "tree" and not enum_ok:
        emit("degraded", "enumeration-unavailable", mode)
    emit("verified", "", mode, note="" if enum_ok else "enumeration-unavailable")


try:
    main()
except SystemExit:
    raise
except Exception as exc:
    sys.stderr.write("singular_kill_tree: internal error: %s: %s\n"
                     % (type(exc).__name__, exc))
    raise SystemExit(3)
PY
  )" || rc=$?

  local key a b c status="" reason="" mode="" note=""
  while IFS=' ' read -r key a b c; do
    case "$key" in
      KILLTREE_RESULT) status="$a"; reason="$b"; mode="$c" ;;
      KILLTREE_NOTE)   note="$a"; [[ -n "$mode" ]] || mode="$b" ;;
    esac
  done <<<"$out"

  local pid_json="$pid"
  [[ "$pid" =~ ^[0-9]+$ ]] || pid_json="\"$pid\""
  [[ -n "$mode" ]] || mode="unknown"
  SINGULAR_KILL_TREE_MODE="$mode"

  if (( rc == 0 )) && [[ "$status" == "verified" ]]; then
    if [[ -n "$note" && -n "${SINGULAR_STATE_DIR:-}" ]]; then
      singular_append_event "kill.enumeration_unavailable" \
        "process enumeration unavailable; group kill verified for pid $pid" \
        "{\"pid\":$pid_json,\"mode\":\"$mode\"}" 2>/dev/null || true
    fi
    return 0
  fi

  [[ -n "$reason" && "$reason" != "-" ]] || reason="internal-error"
  SINGULAR_KILL_TREE_RESULT="degraded"
  SINGULAR_KILL_TREE_REASON="$reason"
  printf 'singular_kill_tree: UNVERIFIED cleanup for pid %s (%s); descendants may survive\n' \
    "$pid" "$reason" >&2
  if [[ -n "${SINGULAR_STATE_DIR:-}" ]]; then
    singular_append_event "kill.unverified" "unverified kill for pid $pid" \
      "{\"pid\":$pid_json,\"mode\":\"$mode\",\"reason\":\"$reason\"}" 2>/dev/null || true
  fi
  return 0
}

# Seconds a timed-out runner gets to run its EXIT trap — which is where the
# read-only restore guard lives — before the tree is SIGKILLed.
singular_kill_grace_sec() {
  local grace="${SINGULAR_KILL_GRACE_SEC:-10}"
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=10
  printf '%s\n' "$grace"
}

# Same idea for a provider CLI killed mid-stream: it has no restore guard of
# its own, so it gets a short courtesy TERM to flush and close, not the runner's
# full trap budget.
singular_provider_kill_grace_sec() {
  local grace="${SINGULAR_PROVIDER_KILL_GRACE_SEC:-2}"
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=2
  printf '%s\n' "$grace"
}

# Does this host actually support the containment singular_kill_tree depends on?
#
# Prints exactly one line — `ok` or `degraded:<reason>` — and ALWAYS returns 0,
# so a caller under `set -e` reads the verdict instead of dying on it. The probe
# is the real primitive end to end (spawn a child in a NEW session, confirm the
# kernel made it its own group leader, kill the group, confirm the group is
# gone), because the question is whether the syscalls work here, and no amount
# of `uname` answers that. One short-lived child, well under a second.
#
# Nothing but a kernel-confirmed leader group is ever signalled: killpg(0) would
# hit the caller's own shell, and this runs from autonomate's startup.
#
# Same test seam as doctor's runtime.process-group-kill — both variables
# required, unknown states ignored — so a CI job can exercise the refusal path
# without a sandbox that denies setsid.
singular_process_control_preflight() {
  if [[ "${SINGULAR_TEST_PROCESS_CONTROL:-0}" == "1" ]]; then
    case "${SINGULAR_TEST_PROCESS_CONTROL_STATE:-}" in
      ok|no-ps)
        # no-ps degrades enumeration only; the group kill still contains a
        # session-spawned tree, which is what this gate is about.
        printf '%s\n' "ok"
        return 0
        ;;
      no-group-kill)
        printf '%s\n' "degraded:simulated-no-group-kill"
        return 0
        ;;
    esac
  fi
  local out=""
  out="$(python3 - <<'PY' 2>/dev/null || true
import os
import signal
import subprocess
import sys
import time


def probe():
    child = None
    pgid = 0
    try:
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        pgid = os.getpgid(child.pid)
        if pgid != child.pid:
            return "degraded:no-session-leader"
        os.killpg(pgid, signal.SIGTERM)
        child.wait(timeout=5)
        deadline = time.monotonic() + 2.0
        while True:
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                return "ok"
            except OSError:
                return "degraded:group-unverifiable"
            if time.monotonic() >= deadline:
                return "degraded:group-survived"
            time.sleep(0.05)
    except subprocess.TimeoutExpired:
        return "degraded:group-survived"
    except (OSError, ValueError) as exc:
        return "degraded:%s" % type(exc).__name__
    finally:
        if child is not None and child.poll() is None:
            if pgid > 1 and pgid == child.pid:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except OSError:
                    pass
            try:
                child.kill()
            except OSError:
                pass
            try:
                child.wait(timeout=2)
            except Exception:
                pass


sys.stdout.write(probe() + "\n")
PY
  )"
  out="$(printf '%s' "$out" | sed -n '1p' | tr -d '[:space:]')"
  case "$out" in
    ok|degraded:*) printf '%s\n' "$out" ;;
    # No line at all means the probe process itself could not run — which is
    # not evidence that cleanup works.
    *) printf '%s\n' "degraded:probe-unavailable" ;;
  esac
  return 0
}

singular_origin_lock_path() {
  python3 - "$SINGULAR_LOCK_FILE" "$SINGULAR_STATE_DIR" <<'PY'
import os
import sys

configured = os.path.abspath(sys.argv[1])
expected = os.path.abspath(os.path.join(sys.argv[2], "locks", "origin.lock.json"))
if configured != expected or configured == os.path.sep:
    print(
        "unsafe origin lock path: %s (expected %s)" % (configured, expected),
        file=sys.stderr,
    )
    raise SystemExit(2)
print(expected)
PY
}

singular_origin_guard_lock_path() {
  local lock_file
  lock_file="$(singular_origin_lock_path)" || return 2
  printf '%s.guard\n' "$lock_file"
}

singular_origin_guard_remove_stale() {
  local stale_path="$1" guard_dir suffix
  guard_dir="$(singular_origin_guard_lock_path)" || return 2
  suffix="${stale_path#"$guard_dir.stale."}"
  if [[ "$stale_path" != "$guard_dir.stale."* \
      || ! "$suffix" =~ ^[1-9][0-9]*\.[0-9a-f]{64}$ ]]; then
    echo "refusing cleanup outside origin guard lock: $stale_path" >&2
    return 2
  fi
  # The quarantined path may itself be a hostile symlink. Removing the exact
  # command-line path recursively unlinks that symlink without following it.
  rm -rf -- "$stale_path"
}

singular_acquire_lock() {
  local run_id="$1"
  local capability capability_sha lock_file guard_dir guard_pid metadata_pid process_id waited=0 stale
  singular_ensure_state_dirs
  lock_file="$(singular_origin_lock_path)" || return 2
  guard_dir="$(singular_origin_guard_lock_path)" || return 2
  process_id="${BASHPID:-$$}"
  if ! capability="$(python3 -c 'import secrets; print(secrets.token_hex(32))')" \
      || [[ ! "$capability" =~ ^[0-9a-f]{64}$ ]]; then
    echo "could not generate origin lock capability" >&2
    return 1
  fi
  capability_sha="$(singular_sha256_text "$capability")"

  # A metadata symlink is never valid, whether or not a guard exists.
  if [[ -L "$lock_file" ]]; then
    echo "refusing symlink origin lock metadata: $lock_file" >&2
    return 2
  fi

  # mkdir is the ownership decision. The JSON file is metadata only; two
  # reconcilers can no longer both observe absence and overwrite each other.
  while ! mkdir "$guard_dir" 2>/dev/null; do
    if [[ -L "$guard_dir" ]]; then
      echo "refusing symlink origin guard lock: $guard_dir" >&2
      return 2
    fi
    guard_pid=""
    guard_pid="$(cat "$guard_dir/pid" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$guard_pid" =~ ^[1-9][0-9]*$ ]] && singular_pid_alive "$guard_pid"; then
      echo "active origin lock exists for pid $guard_pid: $lock_file" >&2
      singular_append_event "origin.lock_skipped" "active origin lock exists" \
        "{\"pid\":\"$guard_pid\"}"
      return 75
    fi
    # Allow an acquiring process a brief window to publish its owner pid.
    if [[ -z "$guard_pid" && "$waited" -lt 10 ]]; then
      waited=$((waited + 1))
      sleep 0.1
      continue
    fi
    stale="$guard_dir.stale.$process_id.$capability"
    if mv "$guard_dir" "$stale" 2>/dev/null; then
      singular_origin_guard_remove_stale "$stale" || return $?
      waited=0
    fi
  done
  # Publish ownership immediately. A contender can now prove this process is
  # live while the backward-compatible standalone metadata is reconciled.
  if ! printf '%s\n' "$process_id" >"$guard_dir/pid"; then
    rmdir "$guard_dir" 2>/dev/null || true
    return 1
  fi

  # Legacy metadata lives outside the guard directory. Touch it only after we
  # own the canonical guard name: stale recovery that quarantines a guard must
  # never race ahead and move metadata published by a newer guard generation.
  if [[ -L "$lock_file" || ( -e "$lock_file" && ! -f "$lock_file" ) ]]; then
    echo "refusing unsafe origin lock metadata: $lock_file" >&2
    rm -f "$guard_dir/pid" 2>/dev/null || true
    rmdir "$guard_dir" 2>/dev/null || true
    return 2
  fi
  if [[ -f "$lock_file" ]]; then
    metadata_pid="$(singular_json_field "$lock_file" pid 2>/dev/null || true)"
    if [[ "$metadata_pid" =~ ^[1-9][0-9]*$ ]] \
        && singular_pid_alive "$metadata_pid"; then
      echo "active legacy origin lock exists for pid $metadata_pid: $lock_file" >&2
      singular_append_event "origin.lock_skipped" "active legacy origin lock exists" \
        "{\"pid\":\"$metadata_pid\"}"
      rm -f "$guard_dir/pid" 2>/dev/null || true
      rmdir "$guard_dir" 2>/dev/null || true
      return 75
    fi
    stale="$lock_file.stale.$(date -u +%Y%m%dT%H%M%SZ).$process_id.$capability"
    if ! mv "$lock_file" "$stale"; then
      rm -f "$guard_dir/pid" 2>/dev/null || true
      rmdir "$guard_dir" 2>/dev/null || true
      return 1
    fi
    singular_append_event "origin.lock_stale" "moved stale origin lock" \
      "{\"path\":\"$stale\"}"
  fi
  SINGULAR_ORIGIN_LOCK_CAPABILITY="$capability"
  # Keep the bearer token shell-local. Trusted direct children receive it via
  # singular_with_origin_lock_capability; workers, providers, hooks, gates and
  # arbitrary dispatch adapters never inherit it transitively.
  export -n SINGULAR_ORIGIN_LOCK_CAPABILITY 2>/dev/null || true
  if ! python3 - "$lock_file" "$run_id" "$process_id" \
    "${SINGULAR_LOCK_MINUTES:-60}" "$capability_sha" <<'PY'
import json
import os
import sys
from datetime import datetime, timedelta, timezone

path, run_id, pid, minutes, capability_sha = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
)
now = datetime.now(timezone.utc).replace(microsecond=0)
data = {
    "schema": "singular.orchestration.lock.v0",
    "owner": "origin",
    "runId": run_id,
    "startedAt": now.isoformat().replace("+00:00", "Z"),
    "expiresAt": (now + timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z"),
    "pid": pid,
    "capabilitySha256": capability_sha,
}
temporary = path + ".tmp." + str(pid)
with open(temporary, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(temporary, path)
PY
  then
    unset SINGULAR_ORIGIN_LOCK_CAPABILITY
    rm -f "$guard_dir/pid" 2>/dev/null || true
    rmdir "$guard_dir" 2>/dev/null || true
    return 1
  fi
}

singular_release_lock() {
  local run_id="$1"
  local existing lock_file lock_pid guard_dir guard_pid process_id stored_sha actual_sha
  lock_file="$(singular_origin_lock_path)" || return 2
  guard_dir="$(singular_origin_guard_lock_path)" || return 2
  process_id="${BASHPID:-$$}"
  [[ ! -L "$lock_file" && ! -L "$guard_dir" ]] || return 1
  existing="$(singular_json_field "$lock_file" runId 2>/dev/null || true)"
  lock_pid="$(singular_json_field "$lock_file" pid 2>/dev/null || true)"
  guard_pid="$(cat "$guard_dir/pid" 2>/dev/null | tr -d '[:space:]' || true)"
  stored_sha="$(singular_json_field "$lock_file" capabilitySha256 2>/dev/null || true)"
  actual_sha="$(singular_sha256_text "${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}" 2>/dev/null || true)"
  if [[ "$existing" == "$run_id" && "$lock_pid" == "$process_id" \
      && "$guard_pid" == "$process_id" \
      && -n "${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}" \
      && -n "$stored_sha" && "$stored_sha" == "$actual_sha" ]]; then
    rm -f "$lock_file"
    rm -f "$guard_dir/pid"
    rmdir "$guard_dir" 2>/dev/null || true
    unset SINGULAR_ORIGIN_LOCK_CAPABILITY
    return 0
  fi
  return 1
}

# Validate a child process's inherited authority to reuse the origin lock.
# A public `--from-reconcile` flag alone is not authority: only the process
# that acquired the lock knows this per-acquisition random capability, and only
# explicitly authorized direct children receive it for one invocation.
singular_require_inherited_origin_lock() {
  local expected_run_id="${1:-}"
  local token="${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}"
  local lock_run_id lock_pid stored_sha actual_sha lock_file guard_dir guard_pid
  lock_file="$(singular_origin_lock_path)" || return 2
  guard_dir="$(singular_origin_guard_lock_path)" || return 2
  [[ -n "$token" && -f "$lock_file" && ! -L "$lock_file" \
      && -d "$guard_dir" && ! -L "$guard_dir" ]] || {
    echo "inherited origin lock capability is missing" >&2
    return 2
  }
  lock_run_id="$(singular_json_field "$lock_file" runId 2>/dev/null || true)"
  lock_pid="$(singular_json_field "$lock_file" pid 2>/dev/null || true)"
  guard_pid="$(cat "$guard_dir/pid" 2>/dev/null | tr -d '[:space:]' || true)"
  stored_sha="$(singular_json_field "$lock_file" capabilitySha256 2>/dev/null || true)"
  actual_sha="$(singular_sha256_text "$token" 2>/dev/null || true)"
  if [[ -z "$lock_run_id" || "$guard_pid" != "$lock_pid" \
      || -z "$stored_sha" || "$stored_sha" != "$actual_sha" \
      || ( -n "$expected_run_id" && "$lock_run_id" != "$expected_run_id" ) ]] \
      || ! singular_pid_alive "$lock_pid"; then
    echo "inherited origin lock capability did not verify" >&2
    return 2
  fi
  # Environment-imported variables retain their export attribute in Bash.
  # De-export after authentication so project gates/providers launched by this
  # trusted child do not receive the bearer token by accident.
  export -n SINGULAR_ORIGIN_LOCK_CAPABILITY 2>/dev/null || true
  return 0
}

singular_with_origin_lock_capability() {
  local token="${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}"
  [[ "$token" =~ ^[0-9a-f]{64}$ ]] || {
    echo "origin lock capability is unavailable for trusted child" >&2
    return 2
  }
  env SINGULAR_ORIGIN_LOCK_CAPABILITY="$token" "$@"
}

singular_git_lock_path() {
  # This lock protects repository-wide .git mutations, so stale recovery may
  # only ever remove the one narrow lock below the current state directory.
  # Resolve `.` and duplicate separators lexically, without following symlinks,
  # then require an exact match. This also catches callers that rebind
  # SINGULAR_STATE_DIR but accidentally retain a lock path from another run.
  python3 - "$SINGULAR_GIT_LOCK_DIR" "$SINGULAR_STATE_DIR" <<'PY'
import os
import sys

configured = os.path.abspath(sys.argv[1])
expected = os.path.abspath(os.path.join(sys.argv[2], "locks", "git-op.lock"))
if configured != expected or configured == os.path.sep:
    print(
        "unsafe git operation lock path: %s (expected %s)" % (configured, expected),
        file=sys.stderr,
    )
    raise SystemExit(2)
print(expected)
PY
}

singular_git_lock_remove_stale() {
  local stale_path="$1" lock_dir suffix
  lock_dir="$(singular_git_lock_path)" || return 2
  suffix="${stale_path#"$lock_dir.stale."}"
  if [[ "$stale_path" != "$lock_dir.stale."* \
      || ! "$suffix" =~ ^[1-9][0-9]*\.[0-9a-f]{32}$ ]]; then
    echo "refusing recursive cleanup outside git operation lock: $stale_path" >&2
    return 2
  fi
  rm -rf -- "$stale_path"
}

singular_git_lock_acquire() {
  singular_ensure_state_dirs
  local lock_dir owner_file owner_pid pid_file_pid owner_token process_id
  local waited=0 stale temporary
  local wait_limit="${SINGULAR_GIT_LOCK_WAIT_TICKS:-600}"

  lock_dir="$(singular_git_lock_path)" || return 2
  owner_file="$lock_dir/owner.json"
  process_id="${BASHPID:-$$}"
  [[ "$wait_limit" =~ ^[1-9][0-9]*$ ]] || wait_limit=600
  if ! owner_token="$(python3 -c 'import secrets; print(secrets.token_hex(16))')" \
      || [[ ! "$owner_token" =~ ^[0-9a-f]{32}$ ]]; then
    echo "could not generate git operation lock capability" >&2
    return 1
  fi

  mkdir -p "$(dirname "$lock_dir")"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    owner_pid="$(singular_json_field "$owner_file" pid 2>/dev/null || true)"
    pid_file_pid="$(cat "$lock_dir/pid" 2>/dev/null | tr -d '[:space:]' || true)"

    # Treat either live owner record as authoritative. The two files are
    # written in order, so this also protects the short publication window.
    if { [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] \
          && singular_pid_alive "$owner_pid"; } \
        || { [[ "$pid_file_pid" =~ ^[1-9][0-9]*$ ]] \
          && singular_pid_alive "$pid_file_pid"; }; then
      waited=$((waited + 1))
      if [[ "$waited" -ge "$wait_limit" ]]; then
        echo "timed out waiting for git operation lock: $lock_dir" >&2
        return 75
      fi
      sleep 0.1
      continue
    fi

    # A creator can own the directory briefly before publishing either owner
    # record. Give that window a bounded grace period before stale recovery.
    if [[ -z "$owner_pid" && -z "$pid_file_pid" && "$waited" -lt 10 ]]; then
      waited=$((waited + 1))
      if [[ "$waited" -ge "$wait_limit" ]]; then
        echo "timed out waiting for git operation lock: $lock_dir" >&2
        return 75
      fi
      sleep 0.1
      continue
    fi

    stale="$lock_dir.stale.$process_id.$owner_token"
    if mv "$lock_dir" "$stale" 2>/dev/null; then
      singular_git_lock_remove_stale "$stale" || return $?
      waited=0
    fi
  done

  if ! printf '%s\n' "$process_id" >"$lock_dir/pid"; then
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  temporary="$lock_dir/.owner.$process_id.tmp"
  if ! python3 - "$temporary" "$process_id" "$owner_token" <<'PY'
import json
import sys

path, pid, token = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({"pid": int(pid), "token": token}, stream, separators=(",", ":"))
    stream.write("\n")
PY
  then
    rm -f "$temporary" 2>/dev/null || true
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  if ! mv "$temporary" "$owner_file"; then
    rm -f "$temporary" 2>/dev/null || true
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  SINGULAR_GIT_LOCK_CAPABILITY="$owner_token"
  return 0
}

singular_git_lock_release() {
  local lock_dir owner_file owner_pid pid_file_pid owner_token process_id
  lock_dir="$(singular_git_lock_path)" || return 2
  owner_file="$lock_dir/owner.json"
  process_id="${BASHPID:-$$}"
  [[ -d "$lock_dir" ]] || return 0
  [[ ! -L "$lock_dir" ]] || return 1
  owner_pid="$(singular_json_field "$owner_file" pid 2>/dev/null || true)"
  owner_token="$(singular_json_field "$owner_file" token 2>/dev/null || true)"
  pid_file_pid="$(cat "$lock_dir/pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$owner_pid" == "$process_id" && "$pid_file_pid" == "$process_id" \
      && -n "${SINGULAR_GIT_LOCK_CAPABILITY:-}" \
      && "$owner_token" == "$SINGULAR_GIT_LOCK_CAPABILITY" ]] || return 1
  rm -f "$owner_file"
  rm -f "$lock_dir/pid"
  if rmdir "$lock_dir"; then
    unset SINGULAR_GIT_LOCK_CAPABILITY
    return 0
  fi
  return 1
}

singular_with_git_lock() {
  singular_git_lock_acquire || return $?
  set +e
  "$@"
  local ec=$?
  set -e
  local release_ec=0
  singular_git_lock_release || release_ec=$?
  if [[ "$ec" -ne 0 ]]; then
    return "$ec"
  fi
  return "$release_ec"
}

singular_validate_packet_basic() {
  local packet="$1"
  local schema="$SINGULAR_PACKET_SCHEMA"
  python3 - "$packet" "$schema" <<'PY'
import json
import re
import sys

path, schema_path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
with open(schema_path, "r", encoding="utf-8") as f:
    schema = json.load(f)
required = schema["required"]
properties = set(schema["properties"].keys())
missing = [key for key in required if key not in data]
if missing:
    print("missing required fields: " + ", ".join(missing), file=sys.stderr)
    sys.exit(2)
extra = sorted(set(data.keys()) - properties)
if extra:
    print("unknown fields: " + ", ".join(extra), file=sys.stderr)
    sys.exit(2)
if data["schema"] != "singular.orchestration.state-packet.v0":
    print("unsupported schema: " + str(data["schema"]), file=sys.stderr)
    sys.exit(2)
for key in ["ownedFiles", "changedFiles", "commands", "tests", "evidence", "blockers"]:
    if not isinstance(data[key], list):
        print(f"{key} must be an array", file=sys.stderr)
        sys.exit(2)

# commands[].cmd is executable input, not a display label. Reject the concrete
# annotation grammar observed in stranded packets without attempting to parse or
# constrain general shell syntax. In particular, grouping parentheses, quoted
# parentheses, and shell comments remain valid.
trailing_result_annotation = re.compile(
    r"[ \t]+\("
    r"(?:attempt(?:-|[ \t]+)[0-9]+[ \t]+)?"
    r"(?:red|green|regression)[ \t]*:"
    r"[^()\r\n]+"
    r"\)[ \t]*$",
    re.IGNORECASE,
)

def has_shell_comment_start(prefix):
    """Return whether prefix contains an unquoted # that starts a shell word."""
    state = "unquoted"
    escaped = False
    for index, char in enumerate(prefix):
        if state == "single":
            if char == "'":
                state = "unquoted"
            continue
        if state == "double":
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                state = "unquoted"
            continue
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "'":
            state = "single"
        elif char == '"':
            state = "double"
        elif char == "#":
            previous = prefix[index - 1] if index else ""
            if index == 0 or previous.isspace() or previous in ";|&()<>":
                return True
    return False

for index, command in enumerate(data["commands"]):
    if not isinstance(command, dict):
        print(f"commands[{index}] must be an object", file=sys.stderr)
        sys.exit(2)
    cmd = command.get("cmd")
    if not isinstance(cmd, str) or not cmd.strip():
        print(
            f"commands[{index}].cmd must be non-empty executable shell text",
            file=sys.stderr,
        )
        sys.exit(2)
    annotation = trailing_result_annotation.search(cmd)
    if annotation:
        prefix = cmd[:annotation.start()]
        # A parenthetical inside an actual shell comment is executable shell
        # text and cannot trigger the historical syntax error.
        if not has_shell_comment_start(prefix):
            print(
                f"commands[{index}].cmd contains a trailing human annotation; "
                "record the exact executable command only and move attempt, "
                "result, and count commentary to packet rationale or evidence",
                file=sys.stderr,
            )
            sys.exit(2)
print("ok")
PY
}

# ---- Extension hooks (generic; overridden by enabled project modules) --------
# Choose the L2 worker runner for a task. Generic: always the default runner.
# A module may override to route specific tasks to an alternate runner
# (args: task_file default_runner alt_runner).
singular_select_l2_runner() {
  local task_file="$1" default_runner="$2" alt_runner="${3:-}"
  printf '%s\n' "$default_runner"
}

# Extra worker-prompt contract text for a task. Generic: none. A module may
# override to append project-specific obligations (args: task_file task_id).
singular_worker_contract_extra() {
  printf ''
}

# Red-evidence log path for a task's worker prompt. Generic: none (empty), so
# the prompt keeps its default red log. A module may override to point specific
# tasks at a project-specific red artifact (args: task_file task_id).
singular_worker_red_log() {
  printf ''
}

# Per-task guard for worker/import packets. Generic: accept. A module may
# override to enforce project-specific durable-proof requirements
# (args: packet task_file workspace run_dir).
singular_packet_module_guard() {
  return 0
}


singular_write_run_snapshot() {
  local run_id="$1"
  local snapshot="$2"
  local run_dir="$SINGULAR_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  printf "%s\n" "$snapshot" >"$run_dir/reconcile-snapshot.md"
}

singular_update_project_snapshot() {
  local snapshot_file="$SINGULAR_ORCH_DIR/project-state.md"
  local snapshot="$1"
  python3 - "$snapshot_file" "$snapshot" <<'PY'
import sys
from pathlib import Path

path, snapshot = sys.argv[1], sys.argv[2]
start = "<!-- singular:reconcile-snapshot:start -->"
end = "<!-- singular:reconcile-snapshot:end -->"
p = Path(path)
p.parent.mkdir(parents=True, exist_ok=True)
if p.exists():
    text = p.read_text(encoding="utf-8")
else:
    text = "# Project State\n"
replacement = f"{start}\n{snapshot.rstrip()}\n{end}"
if start not in text or end not in text:
    text = text.rstrip() + "\n\n## Latest Reconcile Snapshot\n\n" + replacement + "\n"
else:
    prefix, rest = text.split(start, 1)
    _, suffix = rest.split(end, 1)
    text = prefix + replacement + suffix
p.write_text(text, encoding="utf-8")
PY
}

# --- Actuation helpers (L0 scheduling, L1 driving) ---

singular_run_dir() {
  echo "$SINGULAR_RUNS_DIR/$1"
}

# Extract a single JSON object from a model's final message and write it back
# normalized. Handles the common cases where the message is pure JSON, wrapped in
# ```json fences, or has prose around a JSON object. Exits non-zero if no parseable
# JSON object is found. Usage: singular_extract_json <in> <out>
singular_extract_json() {
  local infile="$1" outfile="$2"
  python3 - "$infile" "$outfile" <<'PY'
import json
import sys

infile, outfile = sys.argv[1], sys.argv[2]
with open(infile, "r", encoding="utf-8") as f:
    text = f.read()

def try_load(s):
    try:
        return json.loads(s), True
    except Exception:
        return None, False

obj, ok = try_load(text)
if not ok:
    # Strip code fences if present.
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else stripped
        if stripped.rstrip().endswith("```"):
            stripped = stripped.rstrip()[:-3]
    obj, ok = try_load(stripped)

if not ok:
    # Scan for ALL balanced top-level {...} objects (respecting strings) and keep
    # the LARGEST one that parses as JSON. Agentic models (e.g. Claude) emit the
    # real payload after reasoning prose and may add a small trailing note object;
    # the largest valid object is the intended payload, and preferring it avoids
    # latching onto an inline example/snippet that appears earlier in the prose.
    # (Codex clean JSON already parsed via the whole-text attempt above, so this
    # path never changes the codex result.)
    candidates = []
    n = len(text)
    start = text.find("{")
    while start != -1:
        depth = 0
        in_str = False
        esc = False
        end = -1
        for i in range(start, n):
            c = text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            else:
                if c == '"':
                    in_str = True
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
        if end == -1:
            break
        cand, cok = try_load(text[start:end + 1])
        if cok:
            candidates.append((end - start, cand))
        start = text.find("{", end + 1)
    if candidates:
        candidates.sort(key=lambda p: p[0])
        obj = candidates[-1][1]
        ok = True

if not ok:
    sys.stderr.write("no parseable JSON object found\n")
    sys.exit(2)

with open(outfile, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
PY
}

singular_l1_normalize_worker_packet_schema() {
  local packet="$1"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
legacy_schema = "schemas/orchestration/state-packet.v0.schema.json"
schema_const = "singular.orchestration.state-packet.v0"
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
schema = str(data.get("schema", ""))
normalized = schema.replace("\\", "/")
if schema == legacy_schema or normalized.endswith("/" + legacy_schema):
    data["schema"] = schema_const
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PY
}

singular_l1_prepare_worker_packet() {
  local raw_message="$1" packet="$2" validation_log="$3"
  [[ -n "$validation_log" ]] && mkdir -p "$(dirname "$validation_log")"
  if [[ ! -f "$raw_message" ]]; then
    [[ -n "$validation_log" ]] && echo "missing worker final message: $raw_message" >"$validation_log"
    return 10
  fi
  if ! singular_extract_json "$raw_message" "$packet" 2>"$validation_log"; then
    return 11
  fi
  singular_l1_normalize_worker_packet_schema "$packet"
  if ! singular_validate_packet_basic "$packet" >"$validation_log" 2>&1; then
    return 12
  fi
  return 0
}

singular_audit_record_path() {
  echo "$SINGULAR_RUNS_DIR/$1/audit.json"
}

singular_worker_run_id() {
  # Stable-ish per-invocation run id for L1/L2 work.
  date -u +"RUN-%Y%m%dT%H%M%SZ-$$"
}

# Parse a task markdown file into a normalized JSON object on stdout.
singular_task_json() {
  local task_file="$1"
  python3 - "$task_file" <<'PY'
import json
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    task_document = f.read()
    lines = task_document.splitlines()

def strip_ticks(s):
    return s.strip().strip("`").strip()

data = {
    "taskDocument": task_document,
    "taskId": "",
    "title": "",
    "status": "",
    "area": "",
    "targetBranch": "",
    "workerBranch": "",
    "testPolicy": "",
    "gateCommand": "",
    "dispatchMode": "",
    "dagNode": "",
    "supersedes": [],
    "supersededBy": [],
    "dependsOn": [],
    "objective": "",
    "ownedFiles": [],
    "forbiddenFiles": [],
    "prerequisites": [],
    "acceptanceCriteria": [],
    "planCritique": [],
}

header_keys = {
    "status": "status",
    "area": "area",
    "target branch": "targetBranch",
    "worker branch": "workerBranch",
    "test policy": "testPolicy",
    "gate command": "gateCommand",
    "dispatch mode": "dispatchMode",
    "dag node": "dagNode",
}

def parse_depends(raw):
    raw = strip_ticks(raw)
    if raw in ("", "[]", "none", "None", "NONE"):
        return []
    return re.findall(r"TASK-\d{4,}", raw)

section = None
subsection = None
objective_lines = []
for raw in lines:
    line = raw.rstrip()
    m = re.match(r"^#\s+(TASK-\d{4,})\s*:\s*(.*)$", line)
    if m:
        data["taskId"] = m.group(1)
        data["title"] = m.group(2).strip()
        continue
    hm = re.match(r"^##\s+(.*)$", line)
    if hm:
        section = hm.group(1).strip().lower()
        subsection = None
        continue
    if section is None:
        km = re.match(r"^([A-Za-z][A-Za-z ]+):\s*(.*)$", line)
        if km:
            key = km.group(1).strip().lower()
            if key == "depends on":
                data["dependsOn"] = parse_depends(km.group(2))
            elif key == "supersedes" or key == "superseded by":
                # "Supersedes:" declares intentional replacement (duplicate-guard
                # bypass); "Superseded by:" is the inverse pointer written by the
                # supersede verb. Both parse to TASK-id lists.
                field = "supersedes" if key == "supersedes" else "supersededBy"
                data[field] = parse_depends(km.group(2))
            elif key in header_keys:
                data[header_keys[key]] = strip_ticks(km.group(2))
        continue
    if section == "objective":
        if line.strip():
            objective_lines.append(line.strip())
        continue
    if section == "scope":
        sm = re.match(r"^(Owned files|Forbidden files)\s*:?\s*$", line.strip(), re.I)
        if sm:
            subsection = sm.group(1).lower()
            continue
        im = re.match(r"^[-*]\s+(.*)$", line.strip())
        if im:
            item = strip_ticks(im.group(1))
            if subsection == "owned files":
                data["ownedFiles"].append(item)
            elif subsection == "forbidden files":
                data["forbiddenFiles"].append(item)
        continue
    if section == "prerequisites":
        im = re.match(r"^[-*]\s+(.*)$", line.strip())
        if im:
            data["prerequisites"].append(im.group(1).strip())
        continue
    if section == "acceptance criteria":
        im = re.match(r"^[-*]\s+(.*)$", line.strip())
        if im:
            data["acceptanceCriteria"].append(im.group(1).strip())
        continue
    if section.startswith("plan critique"):
        # Advisory findings carried forward from the plan critic (0.21.0);
        # rendered into the worker and auditor prompts, never into scope.
        im = re.match(r"^[-*]\s+(.*)$", line.strip())
        if im:
            data["planCritique"].append(im.group(1).strip())
        continue
    if section == "executable dag frontier" and not data["dagNode"]:
        # Planner-appended provenance ("- node: `X`") — the dagNode fallback for
        # tasks authored before the `DAG node:` header existed.
        nm = re.match(r"^[-*]\s+node:\s*(.+)$", line.strip(), re.I)
        if nm:
            data["dagNode"] = strip_ticks(nm.group(1))
        continue

data["objective"] = " ".join(objective_lines).strip()
print(json.dumps(data, separators=(",", ":")))
PY
}

# The DAG node a task belongs to (header `DAG node:` first, planner frontier
# section as fallback). Empty when the task predates node attribution.
singular_task_node() {
  singular_task_field "$1" dagNode 2>/dev/null || true
}

# JSON index of every task attributed to a DAG node, scanning the tasks dir
# INCLUDING subdirs (tasks/superseded/ etc.). One python pass — a per-file
# singular_task_json fan-out is too slow for promoter/health paths. The parse
# here is a deliberate minimal subset of singular_task_json (header lines,
# owned-files list, frontier-section node fallback); keep the two in sync.
# Output: [{"taskId","status","ownedFiles":[],"supersededBy":[],"file"}...]
singular_node_task_index_json() {
  local node="$1"
  python3 - "$SINGULAR_TASKS_DIR" "$node" <<'PY'
import json
import os
import re
import sys

tasks_dir, want_node = sys.argv[1], sys.argv[2]
out = []


def strip_ticks(s):
    return s.strip().strip("`").strip()


for dirpath, _dirs, files in os.walk(tasks_dir):
    for name in sorted(files):
        if not (name.startswith("TASK-") and name.endswith(".md")):
            continue
        path = os.path.join(dirpath, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        task_id = status = dag_node = ""
        owned, superseded_by = [], []
        section = subsection = None
        for raw in lines:
            line = raw.rstrip()
            m = re.match(r"^#\s+(TASK-\d{4,})\s*:", line)
            if m:
                task_id = m.group(1)
                continue
            hm = re.match(r"^##\s+(.*)$", line)
            if hm:
                section = hm.group(1).strip().lower()
                subsection = None
                continue
            if section is None:
                km = re.match(r"^([A-Za-z][A-Za-z ]+):\s*(.*)$", line)
                if km:
                    key = km.group(1).strip().lower()
                    if key == "status":
                        status = strip_ticks(km.group(2)).lower()
                    elif key == "dag node":
                        dag_node = strip_ticks(km.group(2))
                    elif key == "superseded by":
                        superseded_by = re.findall(r"TASK-\d{4,}", km.group(2))
                continue
            if section == "scope":
                sm = re.match(r"^(Owned files|Forbidden files)\s*:?\s*$", line.strip(), re.I)
                if sm:
                    subsection = sm.group(1).lower()
                    continue
                im = re.match(r"^[-*]\s+(.*)$", line.strip())
                if im and subsection == "owned files":
                    owned.append(strip_ticks(im.group(1)))
                continue
            if section == "executable dag frontier" and not dag_node:
                nm = re.match(r"^[-*]\s+node:\s*(.+)$", line.strip(), re.I)
                if nm:
                    dag_node = strip_ticks(nm.group(1))
                continue
        if task_id and dag_node == want_node:
            out.append({
                "taskId": task_id,
                "status": status,
                "ownedFiles": sorted(set(owned)),
                "supersededBy": superseded_by,
                "file": path,
            })
print(json.dumps(out, separators=(",", ":")))
PY
}

# A node is "pending promotion" when its planned work is done but its gate has
# not been published: >=1 task, zero open tasks (ready/planned/running/
# needs-review/accepted), >=1 integrated, every terminal task satisfied
# (integrated; or superseded/blocked/failed/cancelled with an integrated task
# covering its owned files or an integrated supersededBy successor), and the
# gate result is not passed. Planner suppression + integrate-time promotion
# both key on this predicate.
singular_node_pending_promotion() {
  local node="$1"
  local index gate_status=""
  index="$(singular_node_task_index_json "$node")" || return 1
  local gate="$SINGULAR_ORCH_DIR/gates/$node.gate-result.json"
  if [[ -f "$gate" ]]; then
    gate_status="$(singular_json_field "$gate" status 2>/dev/null || true)"
  fi
  python3 - "$gate_status" <<PY
import json
import sys

tasks = json.loads('''$index''')
gate_status = sys.argv[1]
# passed -> nothing to promote; failed/blocked -> promotion was ATTEMPTED and
# refused, so the node needs more work and must stay plannable (suppressing
# here would deadlock an all-integrated node behind a red gate).
if gate_status in ("passed", "passed-with-acknowledged-baseline", "failed", "blocked") or not tasks:
    sys.exit(1)

OPEN = {"ready", "planned", "running", "needs-review", "accepted", ""}
by_id = {t["taskId"]: t for t in tasks}
integrated = [t for t in tasks if t["status"] == "integrated"]
if not integrated:
    sys.exit(1)
if any(t["status"] in OPEN for t in tasks):
    sys.exit(1)


def satisfied(t, depth=0):
    if t["status"] == "integrated":
        return True
    if depth > 16:
        return False
    for succ in t.get("supersededBy", []):
        nxt = by_id.get(succ)
        if nxt is not None and satisfied(nxt, depth + 1):
            return True
    owned = set(t.get("ownedFiles", []))
    if owned:
        for it in integrated:
            if owned <= set(it.get("ownedFiles", [])):
                return True
    return False


sys.exit(0 if all(satisfied(t) for t in tasks) else 1)
PY
}

# Return success only when NODE currently has a schema-valid, authoritative
# passing gate (including any configured human-gate requirement). Callers must
# not infer this transition from promoter stdout: a custom promoter may log
# anything, while dag.sh area-gate is the completion authority.
singular_authoritative_gate_passed() {
  local node="$1"
  [[ -n "$node" ]] || return 1
  "$SINGULAR_LIB_DIR/dag.sh" area-gate "$node" >/dev/null 2>&1
}

# Snapshot every authoritative passing gate as a JSON array in DAG order. A
# malformed/missing DAG or invalid gate fails closed to an empty snapshot; the
# transition counter below can therefore never manufacture progress from log
# text or a partially valid gate record.
singular_authoritative_gate_snapshot_json() {
  local dag_file="${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}"
  [[ -f "$dag_file" ]] || { printf '[]\n'; return 0; }
  local nodes node
  nodes="$(python3 - "$dag_file" <<'PY' 2>/dev/null || true
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    nodes = data.get("nodes", [])
    if not isinstance(nodes, list):
        raise ValueError("nodes is not a list")
    for entry in nodes:
        if isinstance(entry, dict) and isinstance(entry.get("id"), str) and entry["id"]:
            print(entry["id"])
except Exception:
    pass
PY
)"
  local -a passed=()
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if singular_authoritative_gate_passed "$node"; then
      passed+=("$node")
    fi
  done <<<"$nodes"
  printf '%s\n' ${passed[@]+"${passed[@]}"} | python3 -c \
    'import json,sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin if line.rstrip("\n")], separators=(",", ":")))'
}

# Count only false->true transitions between two authoritative snapshots.
# Invalid caller input returns non-zero rather than becoming breaker-resetting
# progress.
singular_authoritative_gate_transition_count() {
  local before="$1" after="$2"
  python3 - "$before" "$after" <<'PY'
import json
import sys

try:
    before = json.loads(sys.argv[1])
    after = json.loads(sys.argv[2])
    if not isinstance(before, list) or not isinstance(after, list):
        raise ValueError("snapshots must be arrays")
    if not all(isinstance(item, str) and item for item in before + after):
        raise ValueError("snapshot members must be non-empty strings")
except Exception:
    raise SystemExit(2)

print(len(set(after) - set(before)))
PY
}

# Read a single field from a parsed task file (dotted path supported).
singular_task_field() {
  local task_file="$1"
  local field="$2"
  local json
  json="$(singular_task_json "$task_file")" || return $?
  python3 -c '
import json, sys
field, raw = sys.argv[1], sys.argv[2]
data = json.loads(raw)
value = data
for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(2)
    value = value[part]
print(json.dumps(value, separators=(",", ":")) if isinstance(value, (dict, list)) else value)
' "$field" "$json"
}

# Host-only task preflight (runs BEFORE any run_id/lease/worktree is created).
# Validates a parsed task JSON (singular_task_json output) and prints one
# human-readable refusal reason per line on stdout; returns non-zero on any
# failure, zero (and prints nothing) when the task is dispatchable.
#
#   singular_task_preflight <task_json> [<effective_gate_cmd>] [<effective_target_branch>] [<require_gate 0|1>]
#
# - effective_gate_cmd / effective_target_branch: pass the post-fallback values
#   the driver computed (config default gate, SINGULAR_TARGET_BRANCH). When empty,
#   the task's own fields are used.
# - require_gate=0 skips the empty-gate refusal (the historical dry-run
#   exemption); every other check still applies.
# - acceptanceCriteria is required when SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE=1
#   (the default).
# Owned/forbidden conflicts use the same segment-boundary semantics as
# scope-check.sh: "a/b" conflicts with "a/b" and "a/b/c", but NOT with "a/bc".
# Forbidden entries are considered only when path-like (contain "/" and no
# space), matching the driver's forbidden-prefix filter, so prose entries like
# "Any file outside the owned scope." are ignored.
singular_task_preflight() {
  local task_json="$1" gate_cmd="${2-}" target_branch="${3-}" require_gate="${4:-1}"
  python3 - "$task_json" "$gate_cmd" "$target_branch" "$require_gate" \
    "${SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE:-1}" <<'PY'
import json
import sys

task_raw, gate_arg, target_arg, require_gate, require_accept = sys.argv[1:6]
try:
    task = json.loads(task_raw)
    if not isinstance(task, dict):
        raise ValueError("task JSON must be an object")
except Exception as exc:
    print(f"unparseable task JSON: {exc}")
    sys.exit(1)

reasons = []

def field(key):
    return str(task.get(key, "") or "").strip()

target_branch = target_arg.strip() or field("targetBranch")
for key, label in (
    ("taskId", "taskId"),
    ("area", "area"),
    ("workerBranch", "workerBranch"),
    ("objective", "objective"),
):
    if not field(key):
        reasons.append(f"missing {label}")
if not target_branch:
    reasons.append("missing targetBranch")
if field("workerBranch") and target_branch and field("workerBranch") == target_branch:
    reasons.append(f"workerBranch equals targetBranch ({target_branch})")

owned = [str(x).strip() for x in (task.get("ownedFiles") or []) if str(x).strip()]
if not owned:
    reasons.append("task declares no owned files")

# Forbidden-prefix filter mirrors the driver: path-like entries only.
forbidden = [
    str(x).strip() for x in (task.get("forbiddenFiles") or [])
    if "/" in str(x) and " " not in str(x) and str(x).strip()
]

def paths_conflict(a, b):
    a, b = a.rstrip("/"), b.rstrip("/")
    if not a or not b:
        return False
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")

for own in owned:
    for forb in forbidden:
        if paths_conflict(own, forb):
            reasons.append(f"owned path conflicts with forbidden path: {own} vs {forb}")

gate_cmd = gate_arg if gate_arg.strip() else str(task.get("gateCommand", "") or "")
if require_gate == "1" and not "".join(gate_cmd.split()):
    reasons.append("no gate command (set 'Gate command:' in the task or gateCommand in singular.config.json)")

if require_accept == "1":
    accept = [str(x).strip() for x in (task.get("acceptanceCriteria") or []) if str(x).strip()]
    if not accept:
        reasons.append("task declares no acceptance criteria")

if reasons:
    print("\n".join(reasons))
    sys.exit(1)
PY
}

# Provider runner contract v1 --------------------------------------------------
#
# Provider output contains model-authored prose, repository text and command
# transcripts. None of those are provider status. Runners therefore normalize
# only provider-controlled terminal envelopes into two durable sidecars:
# runner-result.v0 (every invocation) and provider-error.v0 (terminal errors).
# Quota/backoff code consumes these sidecars exclusively.

singular_capability_b64_decode() {
  python3 - "$1" <<'PY'
import base64
import sys
sys.stdout.write(base64.b64decode(sys.argv[1]).decode("utf-8"))
PY
}

singular_capability_optional_warn_once() {
  local provider="$1" role="$2" profile="$3" capability="$4" reason="$5"
  local warning_dir="$SINGULAR_STATE_DIR/warnings/capabilities"
  local warning_key marker marker_rc=0
  warning_key="$(singular_sha256_text "$capability")"
  marker="$warning_dir/$warning_key.warned"
  mkdir -p "$warning_dir"
  python3 - "$marker" "$capability" <<'PY' 2>/dev/null || marker_rc=$?
import json
import os
import sys
from datetime import datetime, timezone

path, capability = sys.argv[1:3]
try:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    raise SystemExit(1)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump({
        "capability": capability,
        "warnedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }, handle, separators=(",", ":"))
    handle.write("\n")
PY
  [[ "$marker_rc" -eq 1 ]] && return 0
  echo "singular: optional capability unavailable for $profile ($role): $capability ($reason); continuing" >&2
  local event_json
  event_json="$(python3 - "$provider" "$role" "$profile" "$capability" "$reason" <<'PY'
import json
import sys
provider, role, profile, capability, reason = sys.argv[1:6]
print(json.dumps({
    "provider": provider,
    "role": role,
    "profile": profile,
    "capability": capability,
    "reason": reason,
}, separators=(",", ":")))
PY
)"
  singular_append_event "capability.optional_unavailable" \
    "optional capability unavailable; provider run continues" "$event_json" || true
}

# Resolve roleProfiles over the call-site fallback, validate the selected
# capability profile, and preflight its required/optional capabilities. Results
# are returned through these globals:
#   SINGULAR_RESOLVED_CAPABILITY_PROFILE
#   SINGULAR_RESOLVED_CAPABILITY_STRICT (yes|no)
#   SINGULAR_RESOLVED_PROVIDER_ARGS[] (literal argv; never eval'd)
#
# A consumer with no declared capabilityProfiles remains legacy-compatible:
# the fallback profile name is recorded, strict isolation is off, and no new
# capability gate is introduced.
singular_runner_capability_prepare() {
  local provider="$1" role="$2" fallback_profile="$3" worktree="$4" provider_bin="${5:-}"
  local report rc=0 kind first second decoded
  local profiles_json="${SINGULAR_CAPABILITY_PROFILES_JSON:-}"
  local roles_json="${SINGULAR_ROLE_PROFILES_JSON:-}"
  local registry_json="${SINGULAR_CAPABILITIES_JSON:-}"
  local schema_version="${SINGULAR_CONFIG_SCHEMA_VERSION:-}"
  local -a errors=()

  SINGULAR_RESOLVED_CAPABILITY_PROFILE="$fallback_profile"
  SINGULAR_RESOLVED_CAPABILITY_STRICT="no"
  SINGULAR_RESOLVED_CAPABILITY_DECLARED="no"
  SINGULAR_RESOLVED_PROVIDER_ARGS=()
  SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT=0

  report="$(python3 - "$profiles_json" "$roles_json" "$registry_json" \
    "$schema_version" "$provider" "$role" "$fallback_profile" "$worktree" \
    "$provider_bin" "$SINGULAR_ENGINE_HOME" "${HOME:-}" <<'PY'
import base64
import json
import os
import pathlib
import re
import shutil
import sys

(profiles_raw, roles_raw, registry_raw, schema_version, provider, role,
 fallback, worktree_raw, provider_bin, engine_home_raw, home_raw) = sys.argv[1:12]
worktree = pathlib.Path(worktree_raw)
engine_home = pathlib.Path(engine_home_raw)
home = pathlib.Path(home_raw) if home_raw else pathlib.Path("/")

def enc(value):
    return base64.b64encode(str(value).encode("utf-8")).decode("ascii")

def emit(kind, first="", second=""):
    print("\t".join((kind, enc(first), enc(second))))

def load_object(raw, label):
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        emit("ERROR", label, f"invalid JSON: {exc}")
        raise SystemExit(78)
    if not isinstance(value, dict):
        emit("ERROR", label, "must be a JSON object")
        raise SystemExit(78)
    return value

profiles = load_object(profiles_raw, "capabilityProfiles")
roles = load_object(roles_raw, "roleProfiles")
registry = load_object(registry_raw, "capabilities")

# No profile declaration means the pre-v2 compatibility path.
if not profiles:
    emit("PROFILE", fallback, "legacy")
    raise SystemExit(0)

mapped = roles.get(role)
if mapped is not None and (not isinstance(mapped, str) or not mapped):
    emit("ERROR", "roleProfiles", f"role {role!r} must map to a non-empty profile name")
    raise SystemExit(78)
profile_name = mapped if isinstance(mapped, str) and mapped else fallback
profile = profiles.get(profile_name)
if not isinstance(profile, dict):
    emit("ERROR", profile_name or "(empty)", f"selected profile for role {role!r} is not declared")
    raise SystemExit(78)
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", profile_name):
    emit("ERROR", profile_name, "profile name contains unsupported characters")
    raise SystemExit(78)

startup = profile.get("startup", "lazy")
if startup != "lazy":
    emit("ERROR", profile_name, "startup must be 'lazy'")
    raise SystemExit(78)

schema_match = re.fullmatch(r"v([0-9]+)", schema_version or "")
strict_default = bool(schema_match and int(schema_match.group(1)) >= 2)
strict = profile.get("strict", strict_default)
if not isinstance(strict, bool):
    emit("ERROR", profile_name, "strict must be a boolean")
    raise SystemExit(78)

def capability_list(key):
    value = profile.get(key, [])
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        emit("ERROR", profile_name, f"{key} must be an array of non-empty strings")
        raise SystemExit(78)
    return list(dict.fromkeys(value))

required = capability_list("required")
optional = [item for item in capability_list("optional") if item not in required]

emit("PROFILE", profile_name, "strict" if strict else "declared")

provider_args_raw = profile.get("providerArgs", [])
if isinstance(provider_args_raw, dict):
    unknown = sorted(set(provider_args_raw) - {"codex", "claude", "gemini", "opencode", "cursor", "openrouter", "grok", "default"})
    if unknown:
        emit("ERROR", profile_name, "providerArgs has unsupported provider keys: " + ", ".join(unknown))
        raise SystemExit(78)
    provider_args = provider_args_raw.get(provider, provider_args_raw.get("default", []))
elif isinstance(provider_args_raw, list):
    provider_args = provider_args_raw
else:
    emit("ERROR", profile_name, "providerArgs must be an argv array or provider-to-argv object")
    raise SystemExit(78)
if not isinstance(provider_args, list) or len(provider_args) > 64:
    emit("ERROR", profile_name, "providerArgs argv must contain at most 64 entries")
    raise SystemExit(78)
for arg in provider_args:
    if (
        not isinstance(arg, str)
        or not arg
        or len(arg) > 4096
        or arg != arg.strip()
        or any(ord(ch) < 32 or ord(ch) == 127 for ch in arg)
    ):
        emit("ERROR", profile_name, "providerArgs entries must be bounded, non-empty strings without control or edge whitespace")
        raise SystemExit(78)

capability_args_raw = profile.get("capabilityArgs", {})
if not isinstance(capability_args_raw, dict):
    emit("ERROR", profile_name, "capabilityArgs must map capability IDs to provider argv")
    raise SystemExit(78)
unknown_capability_args = sorted(set(capability_args_raw) - set(required) - set(optional))
if unknown_capability_args:
    emit(
        "ERROR",
        profile_name,
        "capabilityArgs contains undeclared capabilities: " + ", ".join(unknown_capability_args),
    )
    raise SystemExit(78)

def selected_capability_args(capability):
    raw = capability_args_raw.get(capability)
    if raw is None:
        return []
    if isinstance(raw, dict):
        unknown = sorted(
            set(raw)
            - {"codex", "claude", "gemini", "opencode", "cursor", "openrouter", "grok", "default"}
        )
        if unknown:
            emit(
                "ERROR",
                profile_name,
                f"capabilityArgs.{capability} has unsupported provider keys: "
                + ", ".join(unknown),
            )
            raise SystemExit(78)
        argv = raw.get(provider, raw.get("default", []))
    elif isinstance(raw, list):
        argv = raw
    else:
        emit(
            "ERROR",
            profile_name,
            f"capabilityArgs.{capability} must be an argv array or provider-to-argv object",
        )
        raise SystemExit(78)
    if not isinstance(argv, list) or len(argv) > 64:
        emit(
            "ERROR",
            profile_name,
            f"capabilityArgs.{capability} must contain at most 64 argv entries",
        )
        raise SystemExit(78)
    for arg in argv:
        if (
            not isinstance(arg, str)
            or not arg
            or len(arg) > 4096
            or arg != arg.strip()
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in arg)
        ):
            emit(
                "ERROR",
                profile_name,
                f"capabilityArgs.{capability} entries must be bounded, non-empty strings "
                "without control or edge whitespace",
            )
            raise SystemExit(78)
    return argv

activation_args = {
    capability: selected_capability_args(capability)
    for capability in required + optional
}

if strict and provider in {"cursor", "grok"} and not provider_args:
    emit(
        "ERROR",
        profile_name,
        (
            f"{provider} has no proven built-in strict isolation mode; configure "
            f"capabilityProfiles.{profile_name}.providerArgs.{provider} as a validated "
            "literal argv array, or explicitly set strict:false"
        ),
    )

def mcp_names():
    names = set()
    roots = [pathlib.Path(os.environ.get("SINGULAR_ROOT", worktree_raw)) / ".mcp.json", home / ".claude.json"]
    for path in roots:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            servers = value.get("mcpServers", {})
            if isinstance(servers, dict):
                names.update(map(str, servers))
        except (OSError, json.JSONDecodeError):
            pass
    try:
        text = (home / ".codex/config.toml").read_text(encoding="utf-8")
        names.update(re.findall(r"^\[mcp_servers\.([^\]]+)\]", text, flags=re.MULTILINE))
    except OSError:
        pass
    return names

def plugin_names():
    names = set()
    for root in (engine_home / "plugin", home / ".codex/plugins"):
        try:
            names.update(path.name for path in root.iterdir() if path.is_dir())
        except OSError:
            pass
    return names

mcps = mcp_names()
plugins = plugin_names()

def available(capability):
    if capability == "filesystem":
        return worktree.is_dir(), f"worktree is unavailable: {worktree}"
    if capability == "git":
        return shutil.which("git") is not None, "git is not on PATH"
    if capability == "schemas":
        return (engine_home / "schemas").is_dir(), f"schema bundle is missing under {engine_home}"
    if capability == "skills":
        ok = (engine_home / "plugin/skills").is_dir() or (worktree / ".agents/skills").is_dir()
        return ok, "no engine or worktree skill directory is available"
    if capability == "runner-contract":
        return True, ""
    if capability == "provider-executable":
        ok = bool(provider_bin) and os.path.isfile(provider_bin) and os.access(provider_bin, os.X_OK)
        return ok, f"{provider} executable is unavailable"
    if capability.startswith("mcp:"):
        name = capability.split(":", 1)[1]
        return name in mcps, f"MCP server {name} is not configured"
    if capability.startswith("plugin:"):
        name = capability.split(":", 1)[1]
        return name in plugins, f"plugin {name} is not installed"
    if capability.startswith("executable:"):
        name = capability.split(":", 1)[1]
        return shutil.which(name) is not None, f"{name} is not on PATH"
    if capability.startswith("file:"):
        path = pathlib.Path(capability.split(":", 1)[1])
        if not path.is_absolute():
            path = worktree / path
        return path.is_file(), f"{path} is missing"
    descriptor = registry.get(capability)
    if not isinstance(descriptor, dict):
        return False, "no capability descriptor is declared"
    kind = descriptor.get("type")
    value = descriptor.get("value") or descriptor.get("name")
    if kind == "builtin":
        return bool(descriptor.get("available", True)), "capability is disabled"
    if kind == "executable" and isinstance(value, str):
        return shutil.which(value) is not None, f"{value} is not on PATH"
    if kind == "file" and isinstance(value, str):
        path = pathlib.Path(value)
        if not path.is_absolute():
            path = worktree / path
        return path.is_file(), f"{path} is missing"
    if kind == "mcp" and isinstance(value, str):
        return value in mcps, f"MCP server {value} is not configured"
    if kind == "plugin" and isinstance(value, str):
        return value in plugins, f"plugin {value} is not installed"
    if kind == "environment" and isinstance(value, str):
        return bool(os.environ.get(value)), f"environment variable {value} is absent"
    return False, "capability descriptor is unsupported"

def external(capability):
    if capability.startswith(("mcp:", "plugin:")):
        return True
    descriptor = registry.get(capability)
    return isinstance(descriptor, dict) and descriptor.get("type") in {"mcp", "plugin"}

def requires_explicit_activation(capability):
    # Native strict modes intentionally start without user skills, MCP servers,
    # or plugins. A validated provider argv override is therefore required
    # before claiming one of those capabilities is active.
    return capability == "skills" or external(capability)

for capability in required:
    ok, reason = available(capability)
    if not ok:
        emit("ERROR", capability, reason)
    elif strict and requires_explicit_activation(capability) and not activation_args[capability]:
        emit(
            "ERROR",
            capability,
            (
                "strict isolation requires capabilityArgs."
                f"{capability} bound to this exact external capability"
            ),
        )
for capability in optional:
    ok, reason = available(capability)
    if strict and requires_explicit_activation(capability) and not activation_args[capability]:
        emit(
            "WARN",
            capability,
            "strict isolation did not activate this optional capability (capabilityArgs absent)",
        )
    elif not ok:
        emit("WARN", capability, reason)

combined_provider_args = list(provider_args)
for capability in required:
    ok, _ = available(capability)
    if ok:
        for arg in activation_args[capability]:
            if arg not in combined_provider_args:
                combined_provider_args.append(arg)
for capability in optional:
    ok, _ = available(capability)
    if ok:
        for arg in activation_args[capability]:
            if arg not in combined_provider_args:
                combined_provider_args.append(arg)

if strict:
    sys.path.insert(0, str(engine_home / "engine"))
    try:
        from capability_policy import strict_provider_arg_violation
    except (ImportError, OSError) as exc:
        emit("ERROR", profile_name, f"strict provider argument policy is unavailable: {exc}")
        raise SystemExit(78)
    violation = strict_provider_arg_violation(provider, combined_provider_args)
    if violation:
        emit("ERROR", profile_name, violation)
        raise SystemExit(78)

for arg in combined_provider_args:
    emit("ARG", arg)
PY
)" || rc=$?

  while IFS=$'\t' read -r kind first second; do
    [[ -n "$kind" ]] || continue
    first="$(singular_capability_b64_decode "$first")"
    second="$(singular_capability_b64_decode "$second")"
    case "$kind" in
      PROFILE)
        SINGULAR_RESOLVED_CAPABILITY_PROFILE="$first"
        SINGULAR_RESOLVED_CAPABILITY_DECLARED="yes"
        if [[ "$second" == "strict" ]]; then
          SINGULAR_RESOLVED_CAPABILITY_STRICT="yes"
        elif [[ "$second" == "legacy" ]]; then
          SINGULAR_RESOLVED_CAPABILITY_DECLARED="no"
        fi
        ;;
      ARG)
        SINGULAR_RESOLVED_PROVIDER_ARGS+=("$first")
        SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT=$((SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT + 1))
        ;;
      WARN)
        singular_capability_optional_warn_once \
          "$provider" "$role" "$SINGULAR_RESOLVED_CAPABILITY_PROFILE" "$first" "$second"
        ;;
      ERROR)
        errors+=("$first: $second")
        ;;
    esac
  done <<<"$report"

  if [[ "$rc" -ne 0 || ${#errors[@]} -gt 0 ]]; then
    local error
    for error in "${errors[@]}"; do
      echo "singular: capability preflight failed for $provider/$role ($SINGULAR_RESOLVED_CAPABILITY_PROFILE): $error" >&2
      local event_json
      event_json="$(python3 - "$provider" "$role" "$SINGULAR_RESOLVED_CAPABILITY_PROFILE" "$error" <<'PY'
import json
import sys
provider, role, profile, error = sys.argv[1:5]
print(json.dumps({
    "provider": provider,
    "role": role,
    "profile": profile,
    "error": error,
    "remediation": "Repair required capabilities/profile providerArgs before retrying.",
}, separators=(",", ":")))
PY
)"
      singular_append_event "capability.preflight_failed" \
        "required capability or strict isolation preflight failed" "$event_json" || true
    done
    [[ ${#errors[@]} -gt 0 ]] || echo "singular: capability profile preflight failed for $provider/$role" >&2
    return 78
  fi
  return 0
}

singular_runner_reject_strict_legacy_extra_args() {
  local provider="$1" variable_name="$2" raw_value="${3:-}"
  if [[ "$SINGULAR_RESOLVED_CAPABILITY_STRICT" == "yes" && -n "$raw_value" ]]; then
    echo "singular: $variable_name is disabled for strict $provider capability profiles; use bounded profile providerArgs/capabilityArgs" >&2
    return 78
  fi
  return 0
}

# --------------------------------------------------------------------------- #
# Shared runner skeleton                                                        #
# --------------------------------------------------------------------------- #
# The ~60% of every adapter that is identical, in one place: argument parsing,
# the exit/signal traps, the backgrounded session-leader spawn, the wall-clock
# timeout and its kill-tree, the envelope capture, the read-only guard ordering
# and the normalized result write. What stays in each adapter is the part that
# is genuinely that provider's: model and effort selection, argv construction,
# sandbox semantics, envelope parsing, session-id extraction.
#
# The split is not tidiness. Six hand-copied containment skeletons drift: grok's
# timeout used a bare `kill -9` on the direct child while its siblings had long
# since adopted singular_kill_tree, so every timed-out grok run left the
# provider's descendants alive and writing to a worktree the guard was trying to
# restore. Lines like these need exactly one copy to review.
#
# State the skeleton owns, and the adapters must not write directly:
SINGULAR_RUNNER_PROVIDER=""        # provider id, for the result record
SINGULAR_RUNNER_LABEL=""           # message prefix, e.g. "cursor-run"
SINGULAR_RUNNER_CHILD_PID=""       # provider session leader while un-reaped
SINGULAR_RUNNER_RO_JOURNAL=""      # read-only guard journal awaiting restore
SINGULAR_RUNNER_RESULT_WRITTEN="no"
SINGULAR_RUNNER_ENVELOPE=""        # provider stdout capture
SINGULAR_RUNNER_ENVELOPE_ERR=""    # provider stderr capture
SINGULAR_RUNNER_EXIT_CODE=0        # provider exit status after the wait
# Opt-in extras an adapter sets before spawning. Left empty they cost nothing,
# which is what keeps the skeleton behaviorally identical for the adapters that
# never had them: no extra file appears, no extra text is printed.
SINGULAR_RUNNER_CLEANUP_PATHS=()   # adapter temp dirs, removed by the exit trap
SINGULAR_RUNNER_SESSION_RECORD=""  # where to record the spawned session, if anywhere
SINGULAR_RUNNER_TIMEOUT_NOTE=""    # appended to the timeout message

# Parse the runner argument vocabulary. Every adapter accepts exactly the set
# singular_runner_describe_contract advertises -- a per-adapter copy of this loop
# is how grok came to reject --session-meta and --resume-session that the generic
# contract promised, so every host call site passing them died with exit 2
# before the provider was ever reached.
#
# Sets, in the caller's shell: worktree prompt_file level run_id output_schema
# output_last_message capture_packet allow_prefixes[] session_meta_path
# resume_session_id runner_role capability_profile result_file describe_contract
singular_runner_parse_args() {
  worktree=""
  prompt_file=""
  level="l2"
  run_id=""
  output_schema=""
  output_last_message=""
  capture_packet="auto"
  allow_prefixes=()
  session_meta_path=""
  resume_session_id=""
  runner_role="${SINGULAR_RUNNER_ROLE:-unknown}"
  capability_profile="${SINGULAR_RUNNER_CAPABILITY_PROFILE:-default}"
  result_file="${SINGULAR_RUNNER_RESULT_FILE:-}"
  describe_contract="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C|--worktree) worktree="$2"; shift 2 ;;
      --prompt-file) prompt_file="$2"; shift 2 ;;
      --level) level="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --output-schema) output_schema="$2"; capture_packet="yes"; shift 2 ;;
      --output-last-message) output_last_message="$2"; capture_packet="yes"; shift 2 ;;
      --no-output-capture) capture_packet="no"; shift ;;
      --allow-prefix) allow_prefixes+=("$2"); shift 2 ;;
      --session-meta) session_meta_path="$2"; shift 2 ;;
      --resume-session) resume_session_id="$2"; shift 2 ;;
      --role) runner_role="$2"; shift 2 ;;
      --capability-profile) capability_profile="$2"; shift 2 ;;
      --result-file) result_file="$2"; shift 2 ;;
      --describe-contract) describe_contract="yes"; shift ;;
      *) echo "unknown option: $1" >&2; return 2 ;;
    esac
  done
  if [[ -z "$run_id" ]]; then
    run_id="RUN-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  if [[ -z "$result_file" ]]; then
    result_file="$(singular_runner_default_result_file "$run_id")"
  fi
  return 0
}

# Kill the provider session, restore the worktree, write the result -- in that
# order, on every exit path including the signals.
#
# The order is the contract. An interrupted run leaves the provider CLI and its
# descendants alive, still writing to the worktree; restoring first would lose
# that race. And the guard restore has to live in the trap rather than in
# straight-line code after the run, because ask/supervise/decide background this
# runner and SIGTERM it on the way to a kill -- on every one of those paths,
# straight-line code simply never executes.
singular_runner_on_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n "$SINGULAR_RUNNER_CHILD_PID" ]]; then
    singular_kill_tree "$SINGULAR_RUNNER_CHILD_PID" 0 session 2>/dev/null || true
    wait "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null || true
    SINGULAR_RUNNER_CHILD_PID=""
  fi
  singular_readonly_guard_restore "$SINGULAR_RUNNER_RO_JOURNAL" || true
  SINGULAR_RUNNER_RO_JOURNAL=""
  if [[ "$SINGULAR_RUNNER_RESULT_WRITTEN" != "yes" ]]; then
    singular_runner_result_write "$SINGULAR_RUNNER_PROVIDER" "$run_id" "$runner_role" \
      "$capability_profile" "$result_file" "$rc" "$SINGULAR_RUNNER_ENVELOPE" \
      "$SINGULAR_RUNNER_ENVELOPE_ERR" "$output_last_message" || true
  fi
  if [[ -n "$SINGULAR_RUNNER_ENVELOPE" ]]; then
    rm -f "$SINGULAR_RUNNER_ENVELOPE" "$SINGULAR_RUNNER_ENVELOPE_ERR" 2>/dev/null || true
  fi
  if [[ ${#SINGULAR_RUNNER_CLEANUP_PATHS[@]} -gt 0 ]]; then
    rm -rf "${SINGULAR_RUNNER_CLEANUP_PATHS[@]}" 2>/dev/null || true
  fi
  exit "$rc"
}

# args: provider [label]
# Exiting from a signal handler runs the EXIT trap, which is the only thing that
# still kills the provider session and restores the worktree. Without these, the
# default disposition tears the runner down and leaves the session running.
# SIGKILL itself remains uncoverable; singular_readonly_guard_sweep answers that.
singular_runner_install_traps() {
  SINGULAR_RUNNER_PROVIDER="$1"
  SINGULAR_RUNNER_LABEL="${2:-$1-run}"
  SINGULAR_RUNNER_RESULT_WRITTEN="no"
  trap singular_runner_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

# Temp files for the provider's stdout/stderr, owned by the trap above.
singular_runner_capture_files() {
  SINGULAR_RUNNER_ENVELOPE="$(mktemp "${TMPDIR:-/tmp}/singular-${1}-env.XXXXXX")"
  SINGULAR_RUNNER_ENVELOPE_ERR="$SINGULAR_RUNNER_ENVELOPE.err"
}

# Take the read-only snapshot the guard restores from, if this is a read-only run.
# args: readonly_run worktree tag
singular_runner_guard_capture() {
  [[ "$1" == "yes" ]] || return 0
  SINGULAR_RUNNER_RO_JOURNAL="$(singular_readonly_guard_capture "$2" "$3")"
}

# Restore now rather than at exit, so a later scope check sees the restored tree.
# The trap still holds the timeout and signal paths; restoring a consumed journal
# twice is a no-op.
singular_runner_guard_restore_now() {
  [[ -n "$SINGULAR_RUNNER_RO_JOURNAL" ]] || return 0
  singular_readonly_guard_restore "$SINGULAR_RUNNER_RO_JOURNAL" || true
  SINGULAR_RUNNER_RO_JOURNAL=""
}

singular_runner_spawn_one() {
  # cwd is the caller's local, reached by dynamic scope: providers that take a
  # working directory as a flag pass "" and stay where they are.
  if [[ -n "$cwd" ]]; then
    cd "$cwd" || exit 1
  fi
  # LAST command, so the `&` at the call site makes $! the session leader itself
  # (pid == pgid) and singular_kill_tree group-kills the whole tree with one
  # negative pid, without `ps` -- which is the whole point (PMGO-004: in a
  # sandbox that denies process enumeration only the direct child was signalled,
  # and the provider's descendants survived every timeout, invisibly).
  singular_setsid_exec "$@"
}

# Run the provider bounded by a wall clock and reap it. Sets
# SINGULAR_RUNNER_EXIT_CODE (124 on timeout).
# args: timeout_sec stdin_file cwd -- argv...
#
# The provider always runs in the BACKGROUND, even with the timeout disabled:
# bash defers a trapped signal until the foreground child finishes, so a
# foreground run would swallow the SIGTERM that ask/supervise/decide send on
# their way to a kill -- and with it the read-only guard's only chance to run.
# `wait` is interruptible by a trapped signal; a foreground child is not.
# Redirections live on the call site so they bind to the job.
singular_runner_spawn_wait() {
  local timeout="$1" stdin_file="$2" cwd="$3"
  shift 3
  [[ "${1:-}" == "--" ]] && shift
  local rc=0 timed_out="no" deadline=0
  if [[ -n "$stdin_file" ]]; then
    singular_runner_spawn_one "$@" \
      <"$stdin_file" >"$SINGULAR_RUNNER_ENVELOPE" 2>"$SINGULAR_RUNNER_ENVELOPE_ERR" &
  else
    singular_runner_spawn_one "$@" \
      >"$SINGULAR_RUNNER_ENVELOPE" 2>"$SINGULAR_RUNNER_ENVELOPE_ERR" &
  fi
  SINGULAR_RUNNER_CHILD_PID=$!
  # What this spawner knows about the session, recorded ps-free so a crashed
  # runner leaves behind a signalable group instead of an orphan tree.
  if [[ -n "$SINGULAR_RUNNER_SESSION_RECORD" ]]; then
    singular_session_record_write "$SINGULAR_RUNNER_SESSION_RECORD" \
      "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null || true
  fi
  if [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]]; then
    deadline=$((SECONDS + timeout))
    while kill -0 "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null; do
      if [[ "$SECONDS" -ge "$deadline" ]]; then
        timed_out="yes"
        # TERM the provider session, then KILL what is left.
        singular_kill_tree "$SINGULAR_RUNNER_CHILD_PID" \
          "$(singular_provider_kill_grace_sec)" session
        wait "$SINGULAR_RUNNER_CHILD_PID" 2>/dev/null || true
        rc=124
        break
      fi
      sleep 2
    done
    if [[ "$timed_out" != "yes" ]]; then
      rc=0; wait "$SINGULAR_RUNNER_CHILD_PID" || rc=$?
    else
      echo "$SINGULAR_RUNNER_LABEL: TIMED OUT after ${timeout}s; killed run $run_id$SINGULAR_RUNNER_TIMEOUT_NOTE" >&2
    fi
  else
    rc=0; wait "$SINGULAR_RUNNER_CHILD_PID" || rc=$?
  fi
  SINGULAR_RUNNER_CHILD_PID=""
  SINGULAR_RUNNER_EXIT_CODE="$rc"
  return 0
}

# Surface the provider's own output, and keep the envelope beside the run.
# args: run_dir
singular_runner_report_envelope() {
  cat "$SINGULAR_RUNNER_ENVELOPE" >&2 || true
  if [[ -s "$SINGULAR_RUNNER_ENVELOPE_ERR" ]]; then
    cat "$SINGULAR_RUNNER_ENVELOPE_ERR" >&2 || true
  fi
  if [[ -n "${1:-}" ]]; then
    cp "$SINGULAR_RUNNER_ENVELOPE" \
      "$1/$SINGULAR_RUNNER_PROVIDER-envelope.json" 2>/dev/null || true
  fi
}

# L0/L1 write scope, verified after the run.
# args: level worktree allow_prefix...
singular_runner_scope_enforce() {
  local level="$1" worktree="$2"
  shift 2
  [[ "$level" == "l0" || "$level" == "l1" ]] || return 0
  local scope_args=(--worktree "$worktree") prefix
  for prefix in "$@"; do
    scope_args+=(--allow-prefix "$prefix")
  done
  "$SINGULAR_ENGINE_DIR/scope-check.sh" "${scope_args[@]}"
}

# The normalized runner result, written once. The trap writes it only if this
# did not.
# args: exit_code
singular_runner_finish() {
  if singular_runner_result_write "$SINGULAR_RUNNER_PROVIDER" "$run_id" "$runner_role" \
    "$capability_profile" "$result_file" "$1" "$SINGULAR_RUNNER_ENVELOPE" \
    "$SINGULAR_RUNNER_ENVELOPE_ERR" "$output_last_message"; then
    SINGULAR_RUNNER_RESULT_WRITTEN="yes"
  fi
}

# Load one provider's row from engine/providers.json into the caller's shell.
#
# Sets, for <provider>:
#   SINGULAR_SPEC_BINARY        executable name the adapter dispatches
#   SINGULAR_SPEC_MODEL_ENV     the SINGULAR_<P>_MODEL variable name
#   SINGULAR_SPEC_MODEL_DEFAULT the model id used when nothing is configured
#   SINGULAR_SPEC_MODEL_PREFIX  namespace every model ref must carry, if any
#   SINGULAR_SPEC_UPDATE_ARGS[] update-pin flags, to be passed FIRST
#
# and EXPORTS the row's update-pin environment. Applying the pin on load is
# deliberate: a spec row saying a provider must not replace its own executable
# mid-run is not advice an adapter may decline, and six adapters each
# remembering to do it is six chances to forget -- which is the state the five
# unpinned adapters were in.
#
# Reads through a NUL-delimited pipe rather than eval: no quoting rules to get
# wrong on data that ends up in an argv. Returns 78 (configuration error, same
# as the capability preflight) when the spec cannot be read, because dispatching
# with an empty model default and no pin is worse than not dispatching.
singular_provider_spec_load() {
  local provider="$1" reader="$SINGULAR_ENGINE_DIR/provider_spec.py"
  SINGULAR_SPEC_BINARY=""
  SINGULAR_SPEC_MODEL_ENV=""
  SINGULAR_SPEC_MODEL_DEFAULT=""
  SINGULAR_SPEC_MODEL_PREFIX=""
  SINGULAR_SPEC_UPDATE_ARGS=()
  if [[ ! -f "$reader" ]]; then
    echo "singular: provider spec reader is missing: $reader" >&2
    return 78
  fi
  local key value loaded="no"
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    loaded="yes"
    case "$key" in
      binary) SINGULAR_SPEC_BINARY="$value" ;;
      modelEnv) SINGULAR_SPEC_MODEL_ENV="$value" ;;
      modelDefault) SINGULAR_SPEC_MODEL_DEFAULT="$value" ;;
      modelPrefix) SINGULAR_SPEC_MODEL_PREFIX="$value" ;;
      updateArg) SINGULAR_SPEC_UPDATE_ARGS+=("$value") ;;
      updateEnv) export "${value?}" ;;
    esac
  done < <(python3 "$reader" --shell "$provider" 2>/dev/null)
  if [[ "$loaded" != "yes" || -z "$SINGULAR_SPEC_BINARY" ]]; then
    echo "singular: provider spec has no usable row for $provider ($reader)" >&2
    return 78
  fi
  return 0
}

singular_runner_describe_contract() {
  local provider="$1"
  python3 - "$provider" <<'PY'
import json, sys
provider = sys.argv[1]
print(json.dumps({
    "schema": "singular.runner-contract.v1",
    "version": 1,
    "provider": provider,
    "arguments": [
        "--worktree", "--prompt-file", "--level", "--run-id",
        "--output-schema", "--output-last-message", "--no-output-capture",
        "--allow-prefix", "--session-meta", "--resume-session",
        "--role", "--capability-profile", "--result-file",
        "--describe-contract",
    ],
    "structuredResult": "singular.orchestration.runner-result.v0",
    "structuredProviderError": "singular.orchestration.provider-error.v0",
}, separators=(",", ":")))
PY
}

singular_runner_contract_prepare() {
  local runner="$1" role="$2" capability_profile="$3" result_file="$4"
  local runner_key probe should_probe="no"
  SINGULAR_RUNNER_CONTRACT_ARGS=()

  # Contract probing is bounded and cached for this host process. A legacy
  # custom runner receives the pre-v1 environment variables only; a conforming
  # v1 runner receives the public argv contract on every actual invocation.
  if ! declare -p SINGULAR_RUNNER_CONTRACT_CACHE >/dev/null 2>&1; then
    declare -gA SINGULAR_RUNNER_CONTRACT_CACHE=()
  fi
  runner_key="$(python3 - "$runner" <<'PY'
import hashlib
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1]).expanduser()
try:
    resolved = path.resolve()
    stat = resolved.stat()
    fingerprint = f"{resolved}\0{stat.st_mtime_ns}\0{stat.st_size}"
except OSError:
    fingerprint = os.path.abspath(str(path))
print(hashlib.sha256(fingerprint.encode("utf-8")).hexdigest())
PY
)"
  probe="${SINGULAR_RUNNER_CONTRACT_CACHE[$runner_key]:-}"
  if [[ -z "$probe" ]]; then
    # Do not execute an unmarked legacy runner merely to ask its version:
    # historical custom runners may ignore unknown argv and begin real work.
    # Built-ins and normal script/binary v1 implementations advertise the
    # literal option; opaque launchers can opt in explicitly.
    if [[ "${SINGULAR_RUNNER_CONTRACT_VERSION:-}" == "1" ]] \
      || { [[ -f "$runner" ]] && LC_ALL=C grep -a -q -- '--describe-contract' "$runner" 2>/dev/null; }; then
      should_probe="yes"
    fi
    if [[ "$should_probe" == "yes" ]]; then
      probe="$(python3 - "$runner" <<'PY'
import json
import subprocess
import sys

runner = sys.argv[1]
required = {
    "--describe-contract",
    "--role",
    "--capability-profile",
    "--result-file",
}
try:
    result = subprocess.run(
        [runner, "--describe-contract"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=3,
        check=False,
    )
    contract = json.loads(result.stdout) if result.returncode == 0 else {}
    arguments = set(contract.get("arguments", []))
    valid = (
        contract.get("schema") == "singular.runner-contract.v1"
        and contract.get("version") == 1
        and required.issubset(arguments)
        and "--stage-dir" not in arguments
        and contract.get("structuredResult")
        == "singular.orchestration.runner-result.v0"
        and contract.get("structuredProviderError")
        == "singular.orchestration.provider-error.v0"
    )
except (OSError, subprocess.SubprocessError, json.JSONDecodeError, TypeError):
    valid = False
print("v1" if valid else "legacy")
PY
)"
    else
      probe="legacy"
    fi
    SINGULAR_RUNNER_CONTRACT_CACHE["$runner_key"]="$probe"
  fi
  if [[ "$probe" == "v1" ]]; then
    SINGULAR_RUNNER_CONTRACT_ARGS=(
      --role "$role"
      --capability-profile "$capability_profile"
      --result-file "$result_file"
    )
  fi
}

singular_runner_default_result_file() {
  local run_id="$1"
  printf '%s\n' "$SINGULAR_STATE_DIR/runs/$run_id/runner-result.json"
}

# Write the contract sidecars atomically. envelope_file must contain the raw
# provider stdout envelope/JSONL. stderr_file is accepted for providers (Gemini)
# that place their JSON envelope on stderr, but arbitrary stderr prose is never
# classified. output_file is recorded as a reference only and is never parsed.
singular_runner_result_write() {
  local provider="$1" run_id="$2" role="${3:-unknown}" capability_profile="${4:-default}"
  local result_file="$5" exit_code="${6:-1}" envelope_file="${7:-}" stderr_file="${8:-}"
  local output_file="${9:-}"
  [[ -n "$result_file" ]] || return 2
  mkdir -p "$(dirname "$result_file")"
  python3 - "$provider" "$run_id" "$role" "$capability_profile" "$result_file" \
    "$exit_code" "$envelope_file" "$stderr_file" "$output_file" <<'PY'
import datetime
import hashlib
import json
import os
import re
import sys
import tempfile

(provider, run_id, role, capability_profile, result_path, exit_raw,
 envelope_path, stderr_path, output_path) = sys.argv[1:10]
try:
    exit_code = int(exit_raw)
except Exception:
    exit_code = 1
role = role or "unknown"
capability_profile = capability_profile or "default"
result_stem = os.path.basename(result_path)
if result_stem.endswith(".json"):
    result_stem = result_stem[:-5]

# Preserve the byte-identical provider envelope beside the normalized result.
# Runners may delete their private temp file after this function returns; audit
# and operators still retain a hash-verifiable raw artifact.
provider_envelope_path = None
provider_envelope_bytes = b""
for candidate in (
    envelope_path,
    stderr_path if provider == "gemini" else "",
):
    if not candidate or not os.path.isfile(candidate):
        continue
    try:
        raw_candidate = open(candidate, "rb").read()
    except OSError:
        continue
    if raw_candidate:
        provider_envelope_bytes = raw_candidate
        provider_envelope_path = os.path.join(
            os.path.dirname(result_path), result_stem + ".provider-envelope.raw"
        )
        break

def read_objects(path):
    if not path or not os.path.isfile(path):
        return []
    try:
        raw = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    if not raw.strip():
        return []
    try:
        value = json.loads(raw)
        return [value]
    except Exception:
        pass
    values = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            values.append(json.loads(line))
        except Exception:
            continue
    # Gemini has emitted a warning followed by one JSON object on stderr. Codex
    # classification accepts only complete JSON/JSONL provider records.
    if not values and provider != "codex":
        start = raw.find("{")
        if start >= 0:
            try:
                value, _ = json.JSONDecoder().raw_decode(raw[start:])
                values.append(value)
            except Exception:
                pass
    return values

objects = read_objects(envelope_path)
if provider == "gemini" and not objects:
    objects = read_objects(stderr_path)

CODEX_SUCCESS_TYPES = {
    "turn.completed", "response.completed", "session.completed",
    "thread.completed",
}
CODEX_RECONNECT_RE = re.compile(
    r"Reconnecting\.\.\. (?P<attempt>[1-9]|10)/(?P<limit>[1-9]|10) "
    r"\((?P<reason>[^\r\n]+)\)"
)

def codex_reconnect_parts(obj):
    if not isinstance(obj, dict) or obj.get("type") != "error":
        return None
    message = obj.get("message")
    if not isinstance(message, str):
        return None
    match = CODEX_RECONNECT_RE.fullmatch(message)
    if match is None:
        return None
    attempt = int(match.group("attempt"))
    limit = int(match.group("limit"))
    if attempt > limit:
        return None
    return attempt, limit, match.group("reason")

def is_terminal_error(obj):
    if not isinstance(obj, dict):
        return False
    typ = str(obj.get("type", "") or "").lower()
    if provider == "codex":
        return typ in {
            "error", "turn.failed", "response.failed", "request.failed",
            "session.failed", "thread.failed",
        } and (typ == "error" or obj.get("error") is not None)
    if provider == "claude":
        return typ == "result" and (
            obj.get("is_error") is True or obj.get("api_error_status") is not None
            or str(obj.get("subtype", "")).lower() in {"error", "failed"}
        )
    if provider == "gemini":
        return obj.get("error") is not None
    if provider in {"opencode", "openrouter"}:
        # openrouter is dispatched through the OpenCode CLI, so its terminal
        # envelope is OpenCode's own error event.
        return typ == "error" and obj.get("error") is not None
    if provider == "cursor":
        return typ == "error" or obj.get("is_error") is True
    if provider == "grok":
        return typ == "error" or obj.get("error") is not None
    return False

terminal = None
codex_success_seen = False
for candidate in reversed(objects):
    if (
        provider == "codex"
        and isinstance(candidate, dict)
        and str(candidate.get("type", "") or "").lower() in CODEX_SUCCESS_TYPES
    ):
        codex_success_seen = True
        continue
    if is_terminal_error(candidate):
        if (
            provider == "codex"
            and codex_success_seen
            and codex_reconnect_parts(candidate) is not None
        ):
            continue
        terminal = candidate
        break

STATUS_KEYS = {
    "status", "statuscode", "status_code", "httpstatus", "http_status",
    "api_error_status",
}
CODE_KEYS = {"code", "error_code", "errorcode", "name"}
MESSAGE_KEYS = {"message", "detail", "error_description", "description"}

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            if isinstance(child, (dict, list)):
                yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            if isinstance(child, (dict, list)):
                yield from walk(child)

def int_status(scope):
    for obj in walk(scope):
        for key, value in obj.items():
            if key.lower() not in STATUS_KEYS:
                continue
            if isinstance(value, int) and not isinstance(value, bool) and 100 <= value <= 599:
                return value
            if isinstance(value, str) and re.fullmatch(r"[1-5][0-9]{2}", value.strip()):
                return int(value.strip())
    return None

def string_field(scope, keys):
    for obj in walk(scope):
        for key, value in obj.items():
            if key.lower() in keys and isinstance(value, str) and value.strip():
                return value.strip()
    return ""

def error_scope(obj):
    if not isinstance(obj, dict):
        return {}
    # Only fields of a terminal error envelope enter this scope. Successful
    # result/assistant payloads and item/command events never reach here.
    # openrouter is dispatched through the OpenCode CLI, so its terminal
    # envelope nests the status and code under `error` exactly as OpenCode's
    # does; without it here the provider-controlled 429/503 would never be
    # found and every OpenRouter quota window would degrade to provider-exit.
    if provider in {"gemini", "opencode", "openrouter"} and isinstance(obj.get("error"), (dict, list)):
        return obj["error"]
    return obj

provider_error = None
raw_event_bytes = b""
if terminal is not None:
    scope = error_scope(terminal)
    status = int_status(scope)
    if status is None and provider == "claude":
        status = int_status({"api_error_status": terminal.get("api_error_status")})
    if status is None and provider == "codex":
        reconnect = codex_reconnect_parts(terminal)
        if reconnect is not None:
            match = re.search(
                r"\bunexpected status ([1-5][0-9]{2})(?:\b|:)",
                reconnect[2],
                re.IGNORECASE,
            )
            if match is not None:
                status = int(match.group(1))
    raw_code = string_field(scope, CODE_KEYS).lower().replace("-", "_").replace(" ", "_")
    message = string_field(scope, MESSAGE_KEYS)
    if not message and provider in {"claude", "cursor"}:
        # In an is_error terminal result, result is provider error text rather
        # than an assistant message. It is used only for the narrow 403
        # entitlement recognizer and a bounded diagnostic excerpt.
        value = terminal.get("result")
        if isinstance(value, str):
            message = value
    message_l = message.lower()
    entitlement_phrases = (
        "organization has disabled",
        "subscription access",
        "disabled claude subscription",
        "entitlement disabled",
        "account is not entitled",
    )
    # Quota classes require the exact provider-controlled HTTP status. Provider
    # error codes alone are not authoritative: SDKs and wrappers also surface
    # those strings in non-terminal/local failure paths.
    if status == 429:
        kind, canonical_code, retryable = "usage-limit", "rate_limit_exceeded", True
    elif status in (503, 529):
        kind, canonical_code, retryable = "overloaded", "provider_overloaded", True
    elif status == 403 and any(p in message_l for p in entitlement_phrases):
        kind, canonical_code, retryable = "entitlement", "entitlement_denied", False
    else:
        kind, canonical_code, retryable = "provider-error", (raw_code or None), False
    event_type = str(terminal.get("type") or terminal.get("subtype") or f"{provider}.error")
    excerpt = re.sub(r"\s+", " ", message).strip()[:512]
    canonical = json.dumps(terminal, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    raw_event_bytes = canonical.encode("utf-8")
    provider_error = {
        "schema": "singular.orchestration.provider-error.v0",
        "provider": provider,
        "runId": run_id,
        "role": role,
        "source": "terminal-envelope",
        "eventType": event_type,
        "kind": kind,
        "httpStatus": status,
        "code": canonical_code,
        "retryable": retryable,
        "excerpt": excerpt,
        "rawEventSha256": hashlib.sha256(raw_event_bytes).hexdigest(),
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).replace(
            microsecond=0).isoformat().replace("+00:00", "Z"),
    }

provider_error_path = None
raw_event_path = None
if provider_error is not None:
    provider_error_path = os.path.join(
        os.path.dirname(result_path), result_stem + ".provider-error.json"
    )
    raw_event_path = os.path.join(
        os.path.dirname(result_path), result_stem + ".provider-event.json"
    )
    provider_error["rawEventRef"] = raw_event_path

# Optional usage comes only from provider-owned metadata containers. Missing
# counters stay absent; we never estimate from prompt/output bytes.
def usage_containers():
    allowed_codex = {
        "turn.completed", "response.completed", "session.completed",
        "thread.completed", "turn.failed", "response.failed", "error",
    }
    for obj in reversed(objects):
        if not isinstance(obj, dict):
            continue
        typ = str(obj.get("type", "") or "").lower()
        if provider == "codex" and typ not in allowed_codex:
            continue
        if provider == "opencode" and typ not in {
            "session.idle", "session.completed", "message.updated", "error",
        }:
            continue
        for key in ("usage", "token_usage", "usageMetadata", "stats"):
            value = obj.get(key)
            if isinstance(value, dict):
                yield value
        # Claude/Cursor/Grok error/result envelopes sometimes place token
        # counters directly at top level.
        if provider in {"claude", "cursor", "grok"}:
            yield obj

def token_value(scope, aliases):
    for obj in walk(scope):
        for key, value in obj.items():
            if key in aliases and isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                return value
    return None

usage = {}
for container in usage_containers():
    found = {
        "inputTokens": token_value(container, {
            "input_tokens", "inputTokens", "prompt_tokens", "promptTokenCount",
        }),
        "cachedInputTokens": token_value(container, {
            "cached_input_tokens", "cachedInputTokens",
            "cache_read_input_tokens", "cachedContentTokenCount",
        }),
        "outputTokens": token_value(container, {
            "output_tokens", "outputTokens", "completion_tokens",
            "candidatesTokenCount",
        }),
    }
    found = {key: value for key, value in found.items() if value is not None}
    if found:
        usage = found
        break

if exit_code in (124, 137):
    outcome, failure_class = "timed-out", "timeout"
elif provider_error is not None:
    outcome = "provider-error"
    # "quota" means a WINDOW the account has to wait out: a usage limit that
    # resets, or an entitlement an operator has to change. "overloaded" is
    # neither — a 503/529 is the provider shedding load and it typically clears
    # in seconds. Collapsing the two made a capacity blip select the 30-minute
    # quota backoff, and because autonomate's quota nap `continue`s past
    # reconcile, one 529 idled the entire graph for half an hour.
    #
    # It still must not trip the circuit breaker (that is why it was bucketed
    # as quota in the first place), so it gets its own class rather than being
    # demoted to provider-exit: short backoff AND the no-breaker path.
    if provider_error["kind"] in {"usage-limit", "entitlement"}:
        failure_class = "quota"
    elif provider_error["kind"] == "overloaded":
        failure_class = "provider-overloaded"
    else:
        failure_class = "provider-exit"
elif exit_code == 0:
    outcome, failure_class = "succeeded", "none"
else:
    outcome, failure_class = "failed", "provider-exit"

now = datetime.datetime.now(datetime.timezone.utc).replace(
    microsecond=0).isoformat().replace("+00:00", "Z")
result = {
    "schema": "singular.orchestration.runner-result.v0",
    "contractVersion": 1,
    "provider": provider,
    "runId": run_id,
    "role": role,
    "capabilityProfile": capability_profile,
    "exitCode": exit_code,
    "outcome": outcome,
    "failureClass": failure_class,
    "providerErrorRef": provider_error_path,
    "outputRef": output_path or None,
    "recordedAt": now,
}
if usage:
    result["usage"] = usage
if provider_envelope_path is not None:
    result["providerEnvelopeRef"] = provider_envelope_path
    result["providerEnvelopeSha256"] = hashlib.sha256(
        provider_envelope_bytes
    ).hexdigest()

def atomic_json(path, value):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".runner-result.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass

def atomic_bytes(path, value):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".runner-evidence.", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass

if provider_envelope_path is not None:
    atomic_bytes(provider_envelope_path, provider_envelope_bytes)
if provider_error is not None:
    atomic_bytes(raw_event_path, raw_event_bytes)
    atomic_json(provider_error_path, provider_error)
atomic_json(result_path, result)
PY

  local provider_error_json
  provider_error_json="$(python3 - "$result_file" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    result = json.load(open(sys.argv[1], encoding="utf-8"))
    ref = result.get("providerErrorRef")
    if ref and not os.path.isabs(ref):
        ref = os.path.join(os.path.dirname(sys.argv[1]), ref)
    error = json.load(open(ref, encoding="utf-8")) if ref else None
    if isinstance(error, dict):
        print(json.dumps(error, separators=(",", ":")))
except Exception:
    pass
PY
)"
  if [[ -n "$provider_error_json" ]]; then
    singular_append_event "provider.error" "provider terminal error normalized" \
      "{\"runnerResultRef\":$(printf '%s' "$result_file" | singular_json_escape),\"providerError\":$provider_error_json}" \
      2>/dev/null || true
  fi

  # One normalized result is written for every actual runner execution.  Emit
  # the measurement from that authority boundary instead of asking campaign
  # metrics to infer model calls from routing/session events (which may be
  # emitted even when a resume is rejected before a provider is reached, or may
  # be absent for a direct fresh call).  This event is observability-only: a
  # journal write failure can never alter the runner outcome.
  local runner_completed_json
  runner_completed_json="$(python3 - "$result_file" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
    result = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(0)

record = {
    "runnerResultRef": path,
    "provider": result.get("provider"),
    "runId": result.get("runId"),
    "role": result.get("role"),
    "capabilityProfile": result.get("capabilityProfile"),
    "exitCode": result.get("exitCode"),
    "outcome": result.get("outcome"),
    "failureClass": result.get("failureClass"),
}
if isinstance(result.get("usage"), dict):
    record["usage"] = result["usage"]
print(json.dumps(record, separators=(",", ":")))
PY
)"
  if [[ -n "$runner_completed_json" ]]; then
    singular_append_event "runner.completed" "runner execution completed" \
      "$runner_completed_json" 2>/dev/null || true
  fi
}

# Validate a runner-result and its provider-error binding. On matching evidence,
# print a compact normalized record; otherwise return nonzero. Validation is
# deliberately independent of jsonschema availability so it is always active.
#
# $2 selects which provider window is being asked about:
#   quota               usage-limit / entitlement — a window to wait out
#   provider-overloaded 503/529 — transient capacity, clears in seconds
#   any                 either (the cycle scanner, which needs the kind back to
#                       decide which class to arm)
# The class and the provider-error kind are cross-checked, so a 529 can never
# satisfy a quota query and a 429 can never satisfy an overload query.
singular_runner_quota_evidence_json() {
  local result_file="$1" expected_class="${2:-quota}"
  [[ -f "$result_file" ]] || return 1
  python3 - "$result_file" "$expected_class" <<'PY'
import hashlib, json, os, re, sys
result_path = os.path.abspath(sys.argv[1])
expected_class = sys.argv[2]
CLASS_KINDS = {
    "quota": {"usage-limit", "entitlement"},
    "provider-overloaded": {"overloaded"},
}
if expected_class == "any":
    allowed_classes = set(CLASS_KINDS)
elif expected_class in CLASS_KINDS:
    allowed_classes = {expected_class}
else:
    sys.exit(1)
try:
    result = json.load(open(result_path, encoding="utf-8"))
except Exception:
    sys.exit(1)
required_result = {
    "schema", "contractVersion", "provider", "runId", "role",
    "capabilityProfile", "exitCode", "outcome", "failureClass",
    "providerErrorRef", "outputRef", "recordedAt",
}
providers = {"codex", "claude", "gemini", "opencode", "cursor", "openrouter", "grok"}
optional_result = {"usage", "providerEnvelopeRef", "providerEnvelopeSha256"}
if not required_result.issubset(result) or not set(result).issubset(required_result | optional_result):
    sys.exit(1)
if result.get("schema") != "singular.orchestration.runner-result.v0":
    sys.exit(1)
if result.get("contractVersion") != 1 or result.get("provider") not in providers:
    sys.exit(1)
result_class = result.get("failureClass")
if result_class not in allowed_classes or result.get("outcome") != "provider-error":
    sys.exit(1)
if not isinstance(result.get("exitCode"), int) or isinstance(result.get("exitCode"), bool):
    sys.exit(1)
if "usage" in result:
    usage = result["usage"]
    if not isinstance(usage, dict) or not usage or not set(usage).issubset({
        "inputTokens", "cachedInputTokens", "outputTokens",
    }):
        sys.exit(1)
    if any(not isinstance(value, int) or isinstance(value, bool) or value < 0
           for value in usage.values()):
        sys.exit(1)
envelope_ref = result.get("providerEnvelopeRef")
envelope_sha = result.get("providerEnvelopeSha256")
if bool(envelope_ref) != bool(envelope_sha):
    sys.exit(1)
if envelope_ref:
    if not isinstance(envelope_ref, str) or not re.fullmatch(r"[0-9a-f]{64}", str(envelope_sha)):
        sys.exit(1)
    if not os.path.isabs(envelope_ref):
        envelope_ref = os.path.join(os.path.dirname(result_path), envelope_ref)
    try:
        envelope_raw = open(envelope_ref, "rb").read()
    except OSError:
        sys.exit(1)
    if hashlib.sha256(envelope_raw).hexdigest() != envelope_sha:
        sys.exit(1)
ref = result.get("providerErrorRef")
if not isinstance(ref, str) or not ref:
    sys.exit(1)
if not os.path.isabs(ref):
    ref = os.path.join(os.path.dirname(result_path), ref)
try:
    error = json.load(open(ref, encoding="utf-8"))
except Exception:
    sys.exit(1)
required_error = {
    "schema", "provider", "runId", "role", "source", "eventType", "kind",
    "httpStatus", "code", "retryable", "excerpt", "rawEventSha256", "recordedAt",
}
optional_error = {"rawEventRef"}
if not required_error.issubset(error) or not set(error).issubset(required_error | optional_error):
    sys.exit(1)
if error.get("schema") != "singular.orchestration.provider-error.v0":
    sys.exit(1)
if error.get("provider") != result.get("provider") or error.get("runId") != result.get("runId"):
    sys.exit(1)
if error.get("role") != result.get("role") or error.get("source") != "terminal-envelope":
    sys.exit(1)
kind, status, code = error.get("kind"), error.get("httpStatus"), error.get("code")
retryable = error.get("retryable")
excerpt = error.get("excerpt")
if not isinstance(excerpt, str):
    sys.exit(1)
entitlement_phrases = (
    "organization has disabled",
    "subscription access",
    "disabled claude subscription",
    "entitlement disabled",
    "account is not entitled",
)
valid = (
    kind == "usage-limit"
    and status == 429
    and code == "rate_limit_exceeded"
    and retryable is True
) or (
    kind == "overloaded"
    and status in (503, 529)
    and code == "provider_overloaded"
    and retryable is True
) or (
    kind == "entitlement"
    and status == 403
    and code == "entitlement_denied"
    and retryable is False
    and any(phrase in excerpt.lower() for phrase in entitlement_phrases)
)
if not valid:
    sys.exit(1)
# failureClass is written by the host classifier; `kind` comes from the
# separately hash-bound provider-error sidecar. They must agree, or a result
# that merely CLAIMS quota over a 529 envelope buys the 30-minute backoff.
# Checking against the declared class (not the queried one) also closes the
# "any" query, which the cycle scanner and singular_limit_marker_scan use.
if kind not in CLASS_KINDS.get(result_class, set()):
    sys.exit(1)
digest = error.get("rawEventSha256")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    sys.exit(1)
raw_event_ref = error.get("rawEventRef")
if raw_event_ref is not None:
    if not isinstance(raw_event_ref, str) or not raw_event_ref:
        sys.exit(1)
    if not os.path.isabs(raw_event_ref):
        raw_event_ref = os.path.join(os.path.dirname(ref), raw_event_ref)
    try:
        raw_event = open(raw_event_ref, "rb").read()
    except OSError:
        sys.exit(1)
    if hashlib.sha256(raw_event).hexdigest() != digest:
        sys.exit(1)
print(json.dumps({
    "resultRef": result_path,
    "providerErrorRef": os.path.abspath(ref),
    "provider": error["provider"],
    "runId": error["runId"],
    "role": error["role"],
    "eventType": error["eventType"],
    "kind": kind,
    "httpStatus": status,
    "code": code,
    "retryable": error["retryable"],
    "excerpt": error["excerpt"],
    "rawEventSha256": digest,
}, separators=(",", ":")))
PY
}

singular_runner_result_failure_class() {
  local result_file="$1"
  [[ -f "$result_file" ]] || return 1
  python3 - "$result_file" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
if data.get("schema") != "singular.orchestration.runner-result.v0":
    sys.exit(1)
value = data.get("failureClass")
if value not in {"none", "quota", "provider-overloaded", "timeout", "provider-exit"}:
    sys.exit(1)
if value in {"quota", "provider-overloaded"}:
    # Both provider-window classes require the bound provider-error validation
    # path; a self-declared class in the result file is not evidence.
    sys.exit(1)
print(value)
PY
}

singular_planner_failure_class() {
  local log_file="$1" exit_code="${2:-0}" output_file="${3:-}" result_file="${4:-}"
  local structured=""
  if [[ -n "$result_file" ]] && singular_runner_quota_evidence_json "$result_file" quota >/dev/null 2>&1; then
    echo "quota"
    return 0
  fi
  if [[ -n "$result_file" ]] \
    && singular_runner_quota_evidence_json "$result_file" provider-overloaded >/dev/null 2>&1; then
    echo "provider-overloaded"
    return 0
  fi
  if [[ -n "$result_file" ]]; then
    structured="$(singular_runner_result_failure_class "$result_file" 2>/dev/null || true)"
  fi
  case "$structured" in
    timeout) echo "timeout"; return 0 ;;
    provider-exit) echo "codex-exit"; return 0 ;;
    none) ;;
  esac
  if [[ "$exit_code" == "124" || "$exit_code" == "137" ]]; then
    echo "timeout"
  elif [[ "$exit_code" =~ ^[0-9]+$ && "$exit_code" -ne 0 ]]; then
    echo "codex-exit"
  elif [[ ! -s "$output_file" ]]; then
    echo "empty-output"
  else
    echo "invalid-output"
  fi
}

# Canonical shipped-adapter identity. A provider name is printed ONLY when the
# given runner path resolves to the matching adapter under SINGULAR_ENGINE_DIR.
# Everything else — a custom wrapper, a basename collision such as
# /tmp/custom/codex-run.sh, an unreadable or dangling path — prints nothing and
# returns 1, so every caller treats it as "provider unknown" instead of guessing
# a built-in. This is the only path->provider mapping in the engine.
singular_runner_provider_identity() {
  local runner="${1:-}"
  [[ -n "$runner" ]] || return 1
  python3 - "$runner" "$SINGULAR_ENGINE_DIR" "$SINGULAR_ADAPTER_PROVIDERS_JSON" <<'PY'
import json
import sys
from pathlib import Path

selected_runner, engine_dir, adapters_raw = sys.argv[1:4]
try:
    adapter_providers = json.loads(adapters_raw)
except Exception:
    sys.exit(1)
selected_path = Path(selected_runner)
adapter_name = selected_path.name
if adapter_name not in adapter_providers:
    sys.exit(1)
try:
    if selected_path.resolve(strict=True) != Path(engine_dir, adapter_name).resolve(strict=True):
        sys.exit(1)
except (OSError, RuntimeError):
    sys.exit(1)
print(adapter_providers[adapter_name])
PY
}

# The runner the next planner/worker turn will actually use. Mirrors
# generate-tasks.sh's planner-runner precedence.
singular_selected_runner_path() {
  printf '%s\n' "${SINGULAR_RUNNER:-${SINGULAR_CODEX_RUNNER:-$SINGULAR_ENGINE_DIR/codex-run.sh}}"
}

# Provider identity of the currently selected runner, or empty + rc 1.
singular_selected_provider_identity() {
  singular_runner_provider_identity "$(singular_selected_runner_path)"
}

singular_planner_backoff_active_json() {
  [[ -f "$SINGULAR_PLANNER_BACKOFF_FILE" ]] || return 1
  # Provider identity is trusted only for a canonically resolved shipped
  # adapter; a basename-colliding custom runner remains unknown and therefore
  # keeps the conservative global-backoff behavior.
  local selected_provider
  selected_provider="$(singular_selected_provider_identity 2>/dev/null || true)"
  python3 - "$SINGULAR_PLANNER_BACKOFF_FILE" "$selected_provider" "$SINGULAR_ADAPTER_PROVIDERS_JSON" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, selected_provider, adapters_raw = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    until_raw = str(data.get("until", ""))
    until = datetime.fromisoformat(until_raw.replace("Z", "+00:00"))
except Exception:
    sys.exit(1)
now = datetime.now(timezone.utc)
if until <= now:
    sys.exit(1)
# Provider-less v0 records and unknown/custom current runners remain global
# backoffs for compatibility. A known built-in provider switch is the only case
# where an unexpired record becomes non-blocking; the record stays untouched so
# its evidence is still available and becomes active again if the runner reverts.
known_providers = set(json.loads(adapters_raw).values())
record_provider = data.get("provider")
if (
    record_provider in known_providers
    and selected_provider in known_providers
    and record_provider != selected_provider
):
    sys.exit(1)
print(json.dumps(data, separators=(",", ":")))
PY
}

singular_planner_backoff_set() {
  local failure_class="$1" run_id="${2:-}" node="${3:-}" evidence_ref="${4:-}"
  local quota_evidence=""
  # A path is not evidence. Both provider-window classes require a schema-valid
  # runner result bound to a normalized provider terminal envelope. Legacy/custom
  # runner logs intentionally fail this gate and remain ordinary failures.
  if [[ "$failure_class" == "quota" || "$failure_class" == "provider-overloaded" ]]; then
    if [[ -n "$evidence_ref" ]]; then
      quota_evidence="$(singular_runner_quota_evidence_json "$evidence_ref" "$failure_class" 2>/dev/null || true)"
    fi
    if [[ -z "$quota_evidence" ]]; then
      local rejected_json
      rejected_json="$(python3 - "$run_id" "$node" "$evidence_ref" <<'PY'
import json, sys
print(json.dumps({
    "runId": sys.argv[1],
    "node": sys.argv[2],
    "evidenceRef": sys.argv[3] or None,
}, separators=(",", ":")))
PY
)"
      singular_append_event "backoff.rejected_invalid_evidence" \
        "$failure_class backoff refused: structured provider evidence missing or invalid" \
        "$rejected_json" 2>/dev/null || true
      echo "$failure_class backoff refused: structured provider evidence missing or invalid (runId=$run_id node=$node)" >&2
      return 1
    fi
    # The one observation choke point for provider pressure: past this line the
    # evidence is schema-valid and hash-bound to a normalized provider envelope,
    # and every arming caller (planner and the breaker chokepoint alike) funnels
    # through here. Off by default, and never able to fail the backoff itself.
    singular_provider_pressure_observe "$evidence_ref" >/dev/null 2>&1 || true
  fi
  local seconds
  # A usage limit is a window measured in tens of minutes; provider overload
  # clears in seconds. Same no-breaker treatment, an order of magnitude apart in
  # how long the loop stands down.
  if [[ "$failure_class" == "quota" ]]; then
    seconds="${SINGULAR_PLANNER_QUOTA_BACKOFF_SECONDS:-1800}"
  elif [[ "$failure_class" == "provider-overloaded" ]]; then
    seconds="${SINGULAR_PLANNER_OVERLOAD_BACKOFF_SECONDS:-180}"
  else
    seconds="${SINGULAR_PLANNER_BACKOFF_SECONDS:-900}"
  fi
  [[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 1 ]] || seconds=900
  singular_ensure_state_dirs
  python3 - "$SINGULAR_PLANNER_BACKOFF_FILE" "$failure_class" "$seconds" "$run_id" "$node" \
    "$evidence_ref" "$quota_evidence" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path, failure_class, seconds_raw, run_id, node, evidence_ref, evidence_raw = sys.argv[1:8]
now = datetime.now(timezone.utc).replace(microsecond=0)
until = now + timedelta(seconds=int(seconds_raw))
evidence = json.loads(evidence_raw) if evidence_raw else {}
data = {
    "schema": "singular.orchestration.planner-backoff.v0",
    "failureClass": failure_class,
    "runId": run_id,
    "node": node,
    # logRef remains for v0 readers, but now points to the normalized
    # provider-error record rather than an untrusted transcript.
    "logRef": evidence.get("providerErrorRef", evidence_ref),
    "evidenceRef": evidence_ref or None,
    "providerErrorRef": evidence.get("providerErrorRef"),
    "provider": evidence.get("provider"),
    "providerEventType": evidence.get("eventType"),
    "providerCode": evidence.get("code"),
    "httpStatus": evidence.get("httpStatus"),
    "startedAt": now.isoformat().replace("+00:00", "Z"),
    "until": until.isoformat().replace("+00:00", "Z"),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# Remove the planner backoff (operator "clear-backoff" primitive). Prints what
# was cleared; emits backoff.cleared with the prior record. Always exits 0 —
# clearing an absent backoff is a no-op, not an error.
singular_planner_backoff_clear() {
  if [[ ! -f "$SINGULAR_PLANNER_BACKOFF_FILE" ]]; then
    echo "no active backoff"
    return 0
  fi
  local prior
  prior="$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),separators=(",",":")))' \
    "$SINGULAR_PLANNER_BACKOFF_FILE" 2>/dev/null || echo '{}')"
  rm -f "$SINGULAR_PLANNER_BACKOFF_FILE"
  singular_append_event "backoff.cleared" "planner backoff cleared by operator" "{\"previous\":$prior}"
  echo "backoff cleared (was: $prior)"
}

# --- provider-pressure controller -------------------------------------------
#
# Evidence in, slots out. The ONLY accepted input is a runner result that has
# already passed singular_runner_quota_evidence_json: schema-validated,
# cross-checked against a hash-bound provider-error sidecar, and carrying a
# normalized provider/kind/httpStatus. Raw logs, prompt prose, packet text and
# self-declared failure classes cannot reach this path by construction.
#
# Multiplicative decrease on a cluster of DISTINCT evidence; additive increase
# of one slot per quiet-success interval; hard floor of
# SINGULAR_PROVIDER_PRESSURE_MIN_SLOTS so pressure can never starve runnable
# work. The cap is only a ceiling — resource-plan.sh still takes the min with
# configured and disk-affordable slots, so recovery cannot outrun either.

singular_provider_pressure_enabled() {
  [[ "${SINGULAR_PROVIDER_PRESSURE_ADAPT:-0}" == "1" ]]
}

# The same configured baseline resource-plan.sh starts from, so a decrease
# halves the real ceiling rather than an invented one.
singular_provider_pressure_configured_slots() {
  local configured="${SINGULAR_MAX_CONCURRENT:-${SINGULAR_MAX_L1_CONCURRENT:-3}}"
  [[ "$configured" =~ ^[0-9]+$ && "$configured" -ge 1 ]] || configured=3
  printf '%s\n' "$configured"
}

# mode: observe | success | status. Never called directly; see the three
# wrappers below, which own the enablement and evidence-validation gates.
_singular_provider_pressure_run() {
  local mode="$1" provider="${2:-}" evidence="${3:-}"
  python3 - "$mode" "$SINGULAR_PROVIDER_PRESSURE_FILE" "$provider" "$evidence" \
    "$SINGULAR_ADAPTER_PROVIDERS_JSON" "$(singular_provider_pressure_configured_slots)" \
    "${SINGULAR_PROVIDER_PRESSURE_CLUSTER:-2}" "${SINGULAR_PROVIDER_PRESSURE_WINDOW_SEC:-900}" \
    "${SINGULAR_PROVIDER_PRESSURE_RECOVER_QUIET:-3}" "${SINGULAR_PROVIDER_PRESSURE_MIN_SLOTS:-1}" \
    "${SINGULAR_PROVIDER_PRESSURE_MAX_EVENTS:-32}" <<'PY'
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone

(mode, path, provider_arg, evidence_raw, adapters_raw, configured_raw,
 cluster_raw, window_raw, quiet_raw, min_slots_raw, max_events_raw) = sys.argv[1:12]

SCHEMA = "singular.orchestration.provider-pressure.v0"
KNOWN = set(json.loads(adapters_raw).values())
MAX_PROVIDERS = 16
PRESSURE_KINDS = ("usage-limit", "overloaded")


def bounded_int(raw, default, minimum):
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return default
    return value if value >= minimum else default


configured = bounded_int(configured_raw, 3, 1)
cluster = bounded_int(cluster_raw, 2, 1)
window = bounded_int(window_raw, 900, 0)
quiet_target = bounded_int(quiet_raw, 3, 1)
min_slots = bounded_int(min_slots_raw, 1, 1)
# A floor above the configured ceiling would persist a cap that load() then
# discards as out of range, leaving the controller to re-reduce and re-discard
# forever while emitting a reduction event each time. Clamp instead.
min_slots = min(min_slots, configured)
max_events = bounded_int(max_events_raw, 32, 1)

now = datetime.now(timezone.utc).replace(microsecond=0)
now_iso = now.isoformat().replace("+00:00", "Z")
HEX = set("0123456789abcdef")


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def parse_ts(raw):
    try:
        stamp = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return stamp.replace(tzinfo=timezone.utc) if stamp.tzinfo is None else stamp


def in_window(event):
    if window == 0:
        return True
    stamp = parse_ts(event.get("observedAt"))
    return stamp is not None and stamp > now - timedelta(seconds=window)


def load():
    """Corruption-safe load. Anything unparseable, unknown or out of range is
    dropped rather than trusted: the controller must fail OPEN to the ordinary
    resource plan, never to zero slots and never by crashing health."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(raw, dict) or raw.get("schema") != SCHEMA:
        return {}
    providers_raw = raw.get("providers")
    if not isinstance(providers_raw, dict):
        return {}
    clean = {}
    for name, entry in list(providers_raw.items())[:MAX_PROVIDERS]:
        if name not in KNOWN or not isinstance(entry, dict):
            continue
        cap = entry.get("cap")
        if not is_int(cap) or cap < min_slots or cap > configured:
            cap = None
        quiet = entry.get("quietSuccesses")
        if not is_int(quiet) or quiet < 0:
            quiet = 0
        events = []
        raw_events = entry.get("events")
        if isinstance(raw_events, list):
            for event in raw_events[-max_events:]:
                if not isinstance(event, dict):
                    continue
                digest = event.get("digest")
                if not isinstance(digest, str) or len(digest) != 64:
                    continue
                if not set(digest).issubset(HEX):
                    continue
                observed = event.get("observedAt")
                if parse_ts(observed) is None:
                    continue
                status = event.get("httpStatus")
                events.append({
                    "digest": digest,
                    "kind": str(event.get("kind", ""))[:32],
                    "httpStatus": status if is_int(status) else None,
                    "observedAt": str(observed),
                    "consumed": bool(event.get("consumed")),
                })
        clean[name] = {
            "cap": cap,
            "events": events,
            "quietSuccesses": min(quiet, quiet_target),
            "lastReducedAt": entry.get("lastReducedAt") if isinstance(entry.get("lastReducedAt"), str) else None,
            "lastRecoveredAt": entry.get("lastRecoveredAt") if isinstance(entry.get("lastRecoveredAt"), str) else None,
        }
    return clean


def acquire_lock():
    """mkdir is the atomic primitive the rest of the engine already uses. A lock
    we cannot take within the spin is abandoned rather than allowed to wedge the
    loop; os.replace still keeps the file itself intact, so the worst case is a
    single lost observation, not corruption."""
    lock = path + ".lock"
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    except OSError:
        return None
    for _ in range(100):
        try:
            os.mkdir(lock)
            return lock
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lock) > 60:
                    os.rmdir(lock)
                    continue
            except OSError:
                pass
            time.sleep(0.05)
        except OSError:
            return None
    return None


def release_lock(lock):
    if lock:
        try:
            os.rmdir(lock)
        except OSError:
            pass


def store(state):
    doc = {
        "schema": SCHEMA,
        "updatedAt": now_iso,
        "providers": {name: state[name] for name in sorted(state)},
    }
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False
    return True


def entry_for(state, name):
    return state.get(name) or {
        "cap": None, "events": [], "quietSuccesses": 0,
        "lastReducedAt": None, "lastRecoveredAt": None,
    }


def report(state, name, changed, action):
    entry = entry_for(state, name)
    print(json.dumps({
        "enabled": True,
        "provider": name or None,
        "cap": entry["cap"],
        "events": sum(1 for event in entry["events"] if in_window(event)),
        "pendingEvents": sum(1 for event in entry["events"]
                             if in_window(event) and not event["consumed"]),
        "quietSuccesses": entry["quietSuccesses"],
        "clusterThreshold": cluster,
        "recoverQuiet": quiet_target,
        "minSlots": min_slots,
        "lastReducedAt": entry["lastReducedAt"],
        "lastRecoveredAt": entry["lastRecoveredAt"],
        "changed": changed,
        "action": action,
    }, separators=(",", ":")))


if mode == "status":
    # Read-only: no lock (os.replace makes a torn read impossible) and no write,
    # so inspecting an untouched deployment never creates state.
    name = provider_arg if provider_arg in KNOWN else ""
    report(load(), name, False, "none")
    sys.exit(0)

if mode == "observe":
    try:
        evidence = json.loads(evidence_raw)
    except ValueError:
        sys.exit(1)
    if not isinstance(evidence, dict):
        sys.exit(1)
    # Provider comes from the validated, hash-bound evidence, never from the
    # runner path: an event is attributed to whoever actually emitted it.
    name = evidence.get("provider")
    kind = evidence.get("kind")
    status = evidence.get("httpStatus")
    if name not in KNOWN or kind not in PRESSURE_KINDS or not is_int(status):
        # 403 entitlement is a hard denial, not congestion. Fewer workers will
        # not make an unentitled account entitled, and throttling on it would
        # bury the real problem under a shrinking pool.
        sys.exit(1)
    # Identity is the EVENT, never where it happens to sit on disk. Hashing
    # providerErrorRef in would make two copies of one provider event — the
    # relative-ref form the validator accepts, then a copied run directory —
    # look like a cluster. Under-counting genuinely identical events is the safe
    # direction; over-counting buys a reduction nothing justified.
    digest = hashlib.sha256("\0".join([
        str(evidence.get("rawEventSha256", "")),
        str(evidence.get("runId", "")),
        str(evidence.get("role", "")),
        str(kind),
        str(status),
    ]).encode("utf-8")).hexdigest()

    lock = acquire_lock()
    try:
        state = load()
        entry = entry_for(state, name)
        if any(event["digest"] == digest for event in entry["events"]):
            # Replaying the same provider event is not a second event. Without
            # this, one 429 re-read on each cycle would look like a cluster.
            state[name] = entry
            report(state, name, False, "duplicate")
            sys.exit(0)
        entry["events"] = (entry["events"] + [{
            "digest": digest,
            "kind": kind,
            "httpStatus": status,
            "observedAt": now_iso,
            "consumed": False,
        }])[-max_events:]
        # New pressure ends any recovery run in progress.
        entry["quietSuccesses"] = 0
        pending = [event for event in entry["events"]
                   if in_window(event) and not event["consumed"]]
        action = "recorded"
        if len(pending) >= cluster:
            base = entry["cap"] if entry["cap"] is not None else configured
            previous = entry["cap"]
            entry["cap"] = max(min_slots, base // 2)
            # Consumed, not discarded: the digests stay for dedup, but they can
            # never fund a second reduction.
            for event in entry["events"]:
                event["consumed"] = True
            if entry["cap"] != previous:
                entry["lastReducedAt"] = now_iso
                action = "reduced"
            else:
                # Already at the floor. The cluster is still consumed, but
                # announcing another "reduced" would report a cut that did not
                # happen — sustained pressure would spam one per cluster.
                action = "held"
        state[name] = entry
        # A write that did not land is not a reduction. Reporting the in-memory
        # entry here would tell the operator (and the event log) that capacity
        # was cut when the on-disk ceiling never moved.
        if store(state):
            report(state, name, True, action)
        else:
            report(load(), name, False, "write-failed")
    finally:
        release_lock(lock)
    sys.exit(0)

if mode == "success":
    name = provider_arg if provider_arg in KNOWN else ""
    if not name:
        sys.exit(0)
    lock = acquire_lock()
    try:
        state = load()
        entry = state.get(name)
        if not entry or entry["cap"] is None:
            # Nothing is throttled: a healthy loop must not write state.
            report(state, name, False, "none")
            sys.exit(0)
        entry["quietSuccesses"] += 1
        action = "quiet"
        if entry["quietSuccesses"] >= quiet_target:
            entry["quietSuccesses"] = 0
            entry["lastRecoveredAt"] = now_iso
            restored = entry["cap"] + 1
            if restored >= configured:
                # Back to the configured ceiling: drop the cap entirely rather
                # than tracking a ceiling that no longer constrains anything.
                entry["cap"] = None
                action = "cleared"
            else:
                entry["cap"] = restored
                action = "recovered"
        state[name] = entry
        if store(state):
            report(state, name, True, action)
        else:
            report(load(), name, False, "write-failed")
    finally:
        release_lock(lock)
    sys.exit(0)

sys.exit(2)
PY
}

# Record one validated provider-pressure event. Takes a runner RESULT PATH, not
# text: the evidence is re-validated here so no caller can inject a pressure
# event from an unvalidated source. Returns 1 when the file is not valid
# congestion evidence, which every caller treats as "nothing to record".
singular_provider_pressure_observe() {
  local result_file="${1:-}"
  singular_provider_pressure_enabled || return 1
  [[ -n "$result_file" && -f "$result_file" ]] || return 1
  local evidence
  evidence="$(singular_runner_quota_evidence_json "$result_file" any 2>/dev/null || true)"
  [[ -n "$evidence" ]] || return 1
  local report
  report="$(_singular_provider_pressure_run observe "" "$evidence" 2>/dev/null || true)"
  [[ -n "$report" ]] || return 1
  printf '%s\n' "$report"
  case "$report" in
    *'"action":"reduced"'*)
      singular_append_event "provider_pressure.reduced" \
        "clustered provider congestion evidence reduced the dispatch ceiling" "$report" 2>/dev/null || true
      ;;
    *'"action":"write-failed"'*)
      # Otherwise a permanently unwritable state directory leaves the controller
      # inert with no operator signal at all.
      singular_append_event "provider_pressure.write_failed" \
        "provider-pressure state could not be written; the dispatch ceiling is unchanged" "$report" 2>/dev/null || true
      ;;
  esac
  return 0
}

# One quiet successful iteration for the currently selected provider. A no-op
# unless that provider actually has a reduced cap.
singular_provider_pressure_success() {
  singular_provider_pressure_enabled || return 1
  local provider
  provider="$(singular_selected_provider_identity 2>/dev/null || true)"
  [[ -n "$provider" ]] || return 1
  local report
  report="$(_singular_provider_pressure_run success "$provider" "" 2>/dev/null || true)"
  [[ -n "$report" ]] || return 1
  printf '%s\n' "$report"
  case "$report" in
    *'"action":"recovered"'*|*'"action":"cleared"'*)
      singular_append_event "provider_pressure.recovered" \
        "quiet successful interval restored dispatch capacity" "$report" 2>/dev/null || true
      ;;
    *'"action":"write-failed"'*)
      singular_append_event "provider_pressure.write_failed" \
        "provider-pressure state could not be written; the dispatch ceiling is unchanged" "$report" 2>/dev/null || true
      ;;
  esac
  return 0
}

# Pressure ceiling for the currently selected provider, for resource-plan.sh and
# health. Read-only and side-effect free; prints nothing when adaptation is off.
singular_provider_pressure_status_json() {
  singular_provider_pressure_enabled || return 1
  local provider
  provider="$(singular_selected_provider_identity 2>/dev/null || true)"
  _singular_provider_pressure_run status "$provider" "" 2>/dev/null || return 1
}

# Compatibility name retained for extensions. A "marker scan" now means strict
# runner-result/provider-error validation; arbitrary text files never match.
singular_limit_marker_scan() {
  local file="$1"
  # "any": before overload was split out of quota this matched all three kinds,
  # and extensions asking "is there a provider limit window here" still want that.
  singular_runner_quota_evidence_json "$file" any
}

# Detect a usage-limit/overload/entitlement window from this cycle's durable,
# validated runner results. Raw runner logs, prompts, packets, verdicts, command
# output and repository/test prose are excluded by construction.
singular_cycle_limit_window_evidence_json() {
  local runs_dir="${SINGULAR_RUNS_DIR:-$SINGULAR_STATE_DIR/runs}"
  [[ -d "$runs_dir" ]] || return 1
  local candidates
  candidates="$(python3 - "$runs_dir" "${SINGULAR_LIMIT_SCAN_WINDOW_SEC:-900}" <<'PY'
import os
import sys
import time

runs_dir = sys.argv[1]
try:
    window = int(sys.argv[2])
except ValueError:
    window = 900
now = time.time()


def recent(path):
    try:
        return now - os.path.getmtime(path) <= window
    except OSError:
        return False


out = []
try:
    entries = list(os.scandir(runs_dir))
except OSError:
    entries = []
for entry in entries:
    try:
        if not entry.is_dir() or not recent(entry.path):
            continue
    except OSError:
        continue
    for root, _dirs, files in os.walk(entry.path):
        for name in files:
            if name == "runner-result.json" or name.endswith("-runner-result.json") or name.endswith(".runner-result.json"):
                path = os.path.join(root, name)
                if recent(path):
                    try:
                        out.append((os.path.getmtime(path), path))
                    except OSError:
                        pass
for _mtime, p in sorted(out, reverse=True):
    print(p)
PY
)"
  [[ -n "$candidates" ]] || return 1
  local file hit
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if hit="$(singular_runner_quota_evidence_json "$file" any 2>/dev/null)"; then
      printf '%s\n' "$hit"
      return 0
    fi
  done <<<"$candidates"
  return 1
}

# Thin compat wrapper (0.4.0 name): true iff structured evidence exists.
singular_cycle_limit_window_detected() {
  singular_cycle_limit_window_evidence_json >/dev/null
}

singular_blocked_gate_planner_guard_json() {
  local node="$1"
  local gate="$SINGULAR_ORCH_DIR/gates/$node.gate-result.json"
  [[ -f "$gate" ]] || return 1
  python3 - "$node" "$gate" <<'PY'
import json
import sys

node, path = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as f:
        gate = json.load(f)
except Exception:
    sys.exit(1)
if gate.get("node") != node or gate.get("status") != "blocked":
    sys.exit(1)
# A needs-work gate is an instruction to plan a remediation slice, not a stop.
# Legacy classless blocks remain conservative and reach this guard; explicit
# blocked-external records are normally rejected earlier by dag.sh node-fields.
if gate.get("blockerClass") == "needs-work":
    sys.exit(1)
missing = []
for evidence in gate.get("evidence", []):
    if evidence.get("kind") == "task-set":
        missing.extend(str(item) for item in evidence.get("taskIds", []) if item)
if not missing:
    sys.exit(1)
print(json.dumps({
    "node": node,
    "gateRef": f"docs/orchestration/gates/{node}.gate-result.json",
    "missingTaskIds": missing,
    "rationale": gate.get("rationale", ""),
}, separators=(",", ":")))
PY
}

# Duplicate-candidate guard (v2, 0.5.0). args: candidate_file [node] [mode].
# mode "create" (default; planner/importer): an existing task blocks the
#   candidate only while it is OPEN (ready/planned/running/needs-review/
#   accepted). Terminal tasks (blocked/superseded/integrated/failed/cancelled/
#   stale) never block — 0.4.0 scanned every task regardless of status, so a
#   node whose only task was blocked could never re-plan (deadlock -> breaker;
#   the field workaround was fake "legacy token" lines + file-scope inflation).
# mode "dispatch" (ready-frontier dedup): integrated also blocks — dispatching
#   a ready twin of integrated work is wasted compute.
# Node identity: explicit `DAG node:` header (dagNode) first; the legacy
# S#/D#-token regex is a fallback only. Both nodes non-empty -> must be equal.
# Either side missing -> only a FULL signature (title AND objective AND
# ownedFiles) matches; owned-files-alone no longer matches across unknown
# nodes (the 0.4.0 empty-node wildcard).
# A candidate whose `Supersedes:` header names the existing task bypasses the
# guard (intentional replacement); bypasses are reported on fd 2 as
# "SUPERSEDES <candidate> <existing>" for the caller to event.
singular_find_duplicate_task_signature() {
  local candidate="$1" node="${2:-}" mode="${3:-create}"
  # f MUST be local: this helper is called from inside callers' own
  # while-read-f loops (singular_list_ready_tasks) and bash dynamic scoping
  # would otherwise clobber their loop variable at EOF.
  local candidate_json task_input f
  candidate_json="$(singular_task_json "$candidate")" || return 1
  task_input="$(mktemp)"
  while IFS= read -r f; do
    [[ -n "$f" && "$f" != "$candidate" ]] || continue
    case "$(basename "$f")" in TEMPLATE.md) continue ;; esac
    printf '%s\t%s\n' "$f" "$(singular_task_json "$f")" >>"$task_input"
  done < <(find "$SINGULAR_TASKS_DIR" -maxdepth 1 -name 'TASK-*.md' -type f 2>/dev/null | sort)
  python3 - "$node" "$candidate_json" "$task_input" "$mode" <<'PY'
import json
import re
import sys

node, candidate_raw, task_input, mode = sys.argv[1:5]
candidate = json.loads(candidate_raw)

BLOCKING = {"ready", "planned", "running", "needs-review", "accepted", ""}
if mode == "dispatch":
    BLOCKING = BLOCKING | {"integrated"}

def norm_text(value):
    value = str(value or "").replace("`", " ").lower()
    return " ".join(value.split())

def norm_path(value):
    value = str(value or "").strip().strip("`").strip()
    while value.startswith("./"):
        value = value[2:]
    return value.rstrip("/")

def owned_sig(task):
    return sorted({norm_path(item) for item in task.get("ownedFiles", []) if norm_path(item)})

def infer_node(task):
    explicit = str(task.get("dagNode", "") or "").strip()
    if explicit:
        return explicit
    text = " ".join(
        str(task.get(key, ""))
        for key in ("title", "objective")
    )
    matches = re.findall(r"\b[DS]\d+\.[A-Za-z0-9_]+\b", text)
    return matches[0] if matches else ""

candidate_sig = {
    "node": node or infer_node(candidate),
    "title": norm_text(candidate.get("title")),
    "objective": norm_text(candidate.get("objective")),
    "ownedFiles": owned_sig(candidate),
}
if not candidate_sig["title"] or not candidate_sig["objective"] or not candidate_sig["ownedFiles"]:
    sys.exit(1)
supersedes = {str(t) for t in candidate.get("supersedes", [])}

with open(task_input, "r", encoding="utf-8") as f:
    lines = [line.rstrip("\n") for line in f if line.strip()]
for raw in lines:
    path, task_raw = raw.split("\t", 1)
    task = json.loads(task_raw)
    status = str(task.get("status", "") or "").strip().lower()
    if status not in BLOCKING:
        continue
    existing_id = str(task.get("taskId", "") or "")
    if existing_id and existing_id in supersedes:
        print(f"SUPERSEDES {candidate.get('taskId','')} {existing_id}", file=sys.stderr)
        continue
    existing_node = infer_node(task)
    existing_owned = owned_sig(task)
    if existing_owned != candidate_sig["ownedFiles"]:
        continue
    existing_title = norm_text(task.get("title"))
    existing_objective = norm_text(task.get("objective"))
    full_match = existing_title == candidate_sig["title"] and existing_objective == candidate_sig["objective"]
    if candidate_sig["node"] and existing_node:
        if existing_node != candidate_sig["node"]:
            continue
        matched = True  # same node + same owned files
    else:
        # Unknown node on either side: only a full signature is conclusive.
        matched = full_match
    if not matched:
        continue
    print(json.dumps({
        "reason": "duplicate-candidate",
        "match": "full-signature" if full_match else "owned-files",
        "existingTaskId": existing_id,
        "existingStatus": task.get("status", ""),
        "existingPath": path,
        "candidateTaskId": candidate.get("taskId", ""),
        "node": candidate_sig["node"],
        "existingNode": existing_node,
        "title": task.get("title", ""),
    }, separators=(",", ":")))
    sys.exit(0)
sys.exit(1)
PY
  local rc=$?
  rm -f "$task_input"
  return "$rc"
}

singular_duplicate_candidate_event_json() {
  local run_id="$1" node="$2" duplicate_json="$3"
  python3 - "$run_id" "$node" "$duplicate_json" <<'PY'
import json
import sys

run_id, node, raw = sys.argv[1:4]
data = json.loads(raw)
data["runId"] = run_id
if node:
    data["node"] = node
print(json.dumps(data, separators=(",", ":")))
PY
}

# List task files whose Status header equals "ready", sorted by task id, without
# applying dispatch duplicate policy. A single parser process keeps queue
# telemetry linear even when a campaign has dozens of ready tasks.
singular_list_status_ready_tasks() {
  [[ -d "$SINGULAR_TASKS_DIR" ]] || return 0
  python3 - "$SINGULAR_TASKS_DIR" <<'PY'
import pathlib
import sys

tasks_dir = pathlib.Path(sys.argv[1])
for path in sorted(tasks_dir.glob("TASK-*.md")):
    if path.name == "TEMPLATE.md" or not path.is_file():
        continue
    try:
        ready = any(line.strip().lower() == "status: ready" for line in path.open(encoding="utf-8"))
    except OSError:
        continue
    if ready:
        print(path)
PY
}

# List ready task files after applying the legacy duplicate-dispatch policy.
singular_list_ready_tasks() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "${SINGULAR_SKIP_DUPLICATE_READY_TASKS:-1}" == "1" ]] && singular_find_duplicate_task_signature "$f" "" dispatch >/dev/null 2>&1; then
      continue
    fi
    echo "$f"
  done < <(singular_list_status_ready_tasks)
}

# Select a deterministic ready frontier for canonical parallel dispatch.
# Emits task file paths, sorted by task id, greedily selected up to the provided
# slot count. Readiness is stricter than Status: ready: dependencies must be
# integrated, no active lease may exist for the task, and file scopes must not
# overlap active leases or earlier selected tasks.
singular_select_dispatch_frontier() {
  local limit="${1:-1}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=1
  [[ "$limit" -gt 0 ]] || return 0
  [[ -d "$SINGULAR_TASKS_DIR" ]] || return 0

  local task_json_lines
  task_json_lines="$(
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      [[ "$(basename "$f")" == "TEMPLATE.md" ]] && continue
      printf '%s\t%s\n' "$f" "$(singular_task_json "$f")"
    done < <(find "$SINGULAR_TASKS_DIR" -maxdepth 1 -name 'TASK-*.md' -type f 2>/dev/null | sort)
  )"

  local frontier_input
  frontier_input="$(mktemp)"
  printf '%s\n' "$task_json_lines" >"$frontier_input"
  python3 - "$limit" "$SINGULAR_LEASES_DIR" "$frontier_input" <<'PY'
import json
import os
import re
import sys

limit = int(sys.argv[1])
leases_dir = sys.argv[2]
tasks_path = sys.argv[3]

tasks = []
with open(tasks_path, "r", encoding="utf-8") as src:
  raw_lines = list(src)
for raw in raw_lines:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    path, task_raw = raw.split("\t", 1)
    task = json.loads(task_raw)
    task["_path"] = path
    tasks.append(task)

statuses = {t.get("taskId", ""): t.get("status", "") for t in tasks}
active_scopes = []
active_statuses = {"running", "planned", "needs-review"}
blocking_task_statuses = active_statuses
lease_by_task = {}

def useful_scope(value):
    value = str(value or "").strip().strip("`").strip()
    if not value or "/" not in value or " " in value:
        return ""
    return value.rstrip("/")

def add_scope(target, values):
    for value in values or []:
        clean = useful_scope(value)
        if clean:
            target.append(clean)

def path_conflict(a, b):
    if not a or not b:
        return False
    return a == b or a.startswith(b.rstrip("/") + "/") or b.startswith(a.rstrip("/") + "/")

def any_conflict(left, right):
    return any(path_conflict(a, b) for a in left for b in right)

def owned_sig(task):
    return sorted({useful_scope(item) for item in task.get("ownedFiles", []) if useful_scope(item)})

def infer_node(task):
    explicit = str(task.get("dagNode", "") or "").strip()
    if explicit:
        return explicit
    text = " ".join(str(task.get(key, "")) for key in ("title", "objective"))
    matches = re.findall(r"\b[DS]\d+\.[A-Za-z0-9_]+\b", text)
    return matches[0] if matches else ""

if os.path.isdir(leases_dir):
    for name in sorted(os.listdir(leases_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(leases_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                lease = json.load(f)
        except Exception:
            continue
        task_id = lease.get("taskId")
        if task_id:
            lease_by_task[task_id] = lease
        if lease.get("status") in active_statuses:
            scope = []
            owned = lease.get("ownedFiles")
            if isinstance(owned, list) and owned:
                add_scope(scope, owned)
            else:
                add_scope(scope, str(lease.get("fileScope", "")).split())
            active_scopes.append(scope)

selected = []
selected_scopes = []
for task in sorted(tasks, key=lambda t: t.get("taskId", "")):
    task_id = task.get("taskId", "")
    if len(selected) >= limit:
        break
    if task.get("status") != "ready":
        continue
    if os.environ.get("SINGULAR_SKIP_DUPLICATE_READY_TASKS", "1") == "1":
        # v2 (0.5.0): only OPEN non-ready twins and integrated twins suppress a
        # ready task. Terminal-but-unfinished statuses (blocked/superseded/
        # failed/cancelled/stale) never do — 0.4.0 blocked here too, so a
        # legitimate successor of a blocked task sat at frontier=0 forever.
        # A task whose `Supersedes:` header names the twin bypasses suppression.
        duplicate = False
        blocking = {"planned", "running", "needs-review", "accepted", "integrated"}
        supersedes = {str(t) for t in task.get("supersedes", [])}
        task_node = infer_node(task)
        task_owned = owned_sig(task)
        if task_owned:
            for other in tasks:
                if other is task:
                    continue
                if str(other.get("status", "")).strip().lower() not in blocking:
                    continue
                if str(other.get("taskId", "")) in supersedes:
                    continue
                other_node = infer_node(other)
                if task_node and other_node and task_node != other_node:
                    continue
                if owned_sig(other) == task_owned:
                    duplicate = True
                    break
        if duplicate:
            continue
    if task.get("dispatchMode") != "canonical":
        continue
    lease = lease_by_task.get(task_id)
    if lease and lease.get("status") in blocking_task_statuses:
        continue
    deps = task.get("dependsOn") or []
    if any(statuses.get(dep) != "integrated" for dep in deps):
        continue
    scope = []
    add_scope(scope, task.get("ownedFiles", []))
    if any(any_conflict(scope, active) for active in active_scopes):
        continue
    if any(any_conflict(scope, prior) for prior in selected_scopes):
        continue
    selected.append(task["_path"])
    selected_scopes.append(scope)

for path in selected:
    print(path)
PY
  rm -f "$frontier_input"
}

singular_lease_path() {
  echo "$SINGULAR_LEASES_DIR/$1.json"
}

singular_lease_status() {
  local task_id="$1"
  local lease
  lease="$(singular_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  singular_json_field "$lease" status 2>/dev/null || true
}

# Write (create or overwrite) a lease record for a task.
singular_lease_write() {
  # args: task_id branch area owner scope status [runId] [worktree] [baseSha] [batchId] [ownedFilesJson] [forbiddenFilesJson]
  local task_id="$1" branch="$2" area="$3" owner="$4" scope="$5" status="$6"
  local run_id="${7:-}" worktree="${8:-}"
  local base_sha="${9:-}" batch_id="${10:-}" owned_json="${11:-}" forbidden_json="${12:-}"
  mkdir -p "$SINGULAR_LEASES_DIR"
  local lease
  lease="$(singular_lease_path "$task_id")"
  # Protect accepted/integrated work: a fresh lease write for a DIFFERENT
  # branch over a terminal-good lease is an identity collision (the 0.4.0
  # allocator reused archived ids and the failed pre-lease destroyed the
  # superseded task's lease). Refuse instead of clobbering.
  if [[ -f "$lease" ]]; then
    local prev_status prev_branch
    prev_status="$(singular_json_field "$lease" status 2>/dev/null || true)"
    prev_branch="$(singular_json_field "$lease" branch 2>/dev/null || true)"
    if [[ ( "$prev_status" == "accepted" || "$prev_status" == "integrated" ) \
      && -n "$prev_branch" && -n "$branch" && "$prev_branch" != "$branch" ]]; then
      singular_append_event "lease.write_refused_protected" \
        "refused to overwrite $prev_status lease with different branch" \
        "{\"taskId\":\"$task_id\",\"prevBranch\":\"$prev_branch\",\"newBranch\":\"$branch\",\"prevStatus\":\"$prev_status\"}"
      echo "lease write refused: $task_id has $prev_status lease for $prev_branch (incoming: $branch)" >&2
      return 1
    fi
  fi
  python3 - "$lease" "$task_id" "$branch" "$area" "$owner" "$scope" "$status" "$run_id" "$worktree" \
    "$base_sha" "$batch_id" "$owned_json" "$forbidden_json" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

(path, task_id, branch, area, owner, scope, status, run_id, worktree,
 base_sha, batch_id, owned_raw, forbidden_raw) = sys.argv[1:14]
max_retries = int(os.environ.get("SINGULAR_MAX_RETRIES", "3"))
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
created = now
retry_count = 0
product_pass_started = False
product_pass_started_at = ""
product_pass_started_run_id = ""
def parse_array(raw, fallback=None):
    if raw:
        try:
            value = json.loads(raw)
            if isinstance(value, list):
                return [str(v) for v in value]
        except Exception:
            pass
    return list(fallback or [])

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            prev = json.load(f)
        created = prev.get("createdAt", now)
        retry_count = int(prev.get("retryCount", 0))
        previous_marker = prev.get("productPassStarted")
        if isinstance(previous_marker, bool):
            product_pass_started = previous_marker
        else:
            # Compatibility for leases written before productPassStarted was
            # introduced.  A scheduler-only reservation was `planned`; an
            # explicit operator budget reset was `ready` with retryCount zero.
            # Every other legacy lease remains conservatively "started" so an
            # upgrade cannot mint a new initial product pass.
            previous_status = str(prev.get("status", ""))
            product_pass_started = not (
                retry_count == 0 and previous_status in {"planned", "ready"}
            )
        product_pass_started_at = str(prev.get("productPassStartedAt", "") or "")
        product_pass_started_run_id = str(prev.get("productPassStartedRunId", "") or "")
        if not base_sha:
            base_sha = prev.get("baseSha", "")
        if not batch_id:
            batch_id = prev.get("batchId", "")
    except Exception:
        pass
owned_files = parse_array(owned_raw, scope.split())
forbidden_files = parse_array(forbidden_raw, [])
data = {
    "taskId": task_id,
    "branch": branch,
    "area": area,
    "owner": owner,
    "fileScope": scope,
    "ownedFiles": owned_files,
    "forbiddenFiles": forbidden_files,
    "baseSha": base_sha,
    "batchId": batch_id,
    "runId": run_id,
    "worktree": worktree,
    "status": status,
    "retryCount": retry_count,
    "maxRetries": max_retries,
    "productPassStarted": product_pass_started,
    "createdAt": created,
    "updatedAt": now,
}
if product_pass_started_at:
    data["productPassStartedAt"] = product_pass_started_at
if product_pass_started_run_id:
    data["productPassStartedRunId"] = product_pass_started_run_id
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# Update only the status (and updatedAt) of an existing lease.
singular_lease_set_status() {
  local task_id="$1" status="$2"
  local lease
  lease="$(singular_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  python3 - "$lease" "$status" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, status = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["status"] = status
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# Return a lease to a dispatchable state and give the task its retry budget back.
#
# retryCount and productPassStarted form the durable product-budget state.
# Resetting only the count would still make re-entry look like a continuation
# after a prior initial pass; reset both to begin the operator-authorized lineage.
singular_lease_unpark() {
  local task_id="$1"
  local lease
  lease="$(singular_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  python3 - "$lease" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["status"] = "ready"
data["retryCount"] = 0
data["productPassStarted"] = False
data.pop("productPassStartedAt", None)
data.pop("productPassStartedRunId", None)
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# Durably distinguish scheduler reservation from execution.  Detached dispatch
# creates a `planned` lease before l1-drive starts; that reservation must not
# consume the task's initial product pass.  l1-drive flips this marker before it
# invokes any worker so a crash/re-entry cannot mint another initial pass.
singular_lease_mark_product_pass_started() {
  local task_id="$1" run_id="${2:-}"
  local lease
  lease="$(singular_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  python3 - "$lease" "$run_id" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, run_id = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
if data.get("productPassStarted") is not True:
    data["productPassStarted"] = True
    data["productPassStartedAt"] = now
if run_id and not data.get("productPassStartedRunId"):
    data["productPassStartedRunId"] = run_id
data["updatedAt"] = now
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# Increment a lease's retryCount; echo the new count.
singular_lease_bump_retry() {
  local task_id="$1"
  local lease
  lease="$(singular_lease_path "$task_id")"
  [[ -f "$lease" ]] || { echo 0; return 1; }
  python3 - "$lease" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["retryCount"] = int(data.get("retryCount", 0)) + 1
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print(data["retryCount"])
PY
}

# Overwrite a lease's ownedFiles with a JSON array. Used when amend-scope widens
# the worker's owned set mid-drive: the parallel-L1 scheduler derives its
# scope-overlap guard from lease.ownedFiles, so a widened scope that is not
# written back would let a concurrent task collide on the newly-owned paths.
singular_lease_update_owned() {
  local task_id="$1" owned_json="$2"
  local lease
  lease="$(singular_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  python3 - "$lease" "$owned_json" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, owned_raw = sys.argv[1], sys.argv[2]
try:
    owned = json.loads(owned_raw)
    if not isinstance(owned, list):
        raise ValueError("ownedFiles must be a JSON array")
except Exception as e:
    sys.stderr.write("singular_lease_update_owned: %s\n" % e)
    sys.exit(1)
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["ownedFiles"] = [str(x).strip() for x in owned if str(x).strip()]
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

singular_lease_field() {
  local task_id="$1" field="$2"
  local lease
  lease="$(singular_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  singular_json_field "$lease" "$field" 2>/dev/null || true
}

# --- Dispatch records (detached dispatch + shadow accounting) ---
# One record per spawned worker under $SINGULAR_DISPATCH_DIR: <taskId>.json with
# {taskId, runId, pid, pidStart, startedAt, log, baseSha, batchId, state}.
# The spawn wrapper drops <taskId>.exit (the driver's exit code) when the worker
# returns; singular_reap_dispatches consumes exit files (or detects dead pids) and
# finalizes records to state=reaped. pidStart (ps lstart) defeats pid reuse.

singular_dispatch_record_path() {
  printf '%s/%s.json' "$SINGULAR_DISPATCH_DIR" "$1"
}

singular_dispatch_exit_path() {
  printf '%s/%s.exit' "$SINGULAR_DISPATCH_DIR" "$1"
}

singular_dispatch_pid_start() {
  # Process start time for pid-reuse detection; empty if the pid is gone.
  local pid="$1"
  [[ -n "$pid" ]] || { echo ""; return 0; }
  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//' || true
}

singular_dispatch_record_write() {
  # args: task_id run_id pid pid_start log base_sha batch_id
  local task_id="$1" run_id="$2" pid="$3" pid_start="$4" log="$5" base_sha="$6" batch_id="$7"
  mkdir -p "$SINGULAR_DISPATCH_DIR"
  # pgid: recorded for whole-tree liveness checks and (when the dispatch was
  # setsid'd, i.e. pgid == pid) safe orphan process-group cleanup. os.getpgid
  # first: it is a syscall, so the record still carries a real pgid in a sandbox
  # that denies `ps` — which is exactly where the group kill is the only
  # containment left. `ps` stays as the fallback, never the source of truth.
  local pgid=""
  if [[ -n "$pid" ]]; then
    pgid="$(singular_pgid_of "$pid" | tr -d '[:space:]' || true)"
    if [[ -z "$pgid" ]]; then
      pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
  fi
  python3 - "$(singular_dispatch_record_path "$task_id")" "$task_id" "$run_id" "$pid" "$pid_start" "$log" "$base_sha" "$batch_id" "$pgid" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, task_id, run_id, pid, pid_start, log, base_sha, batch_id, pgid = sys.argv[1:10]
data = {
    "taskId": task_id,
    "runId": run_id,
    "pid": int(pid) if pid.isdigit() else 0,
    "pidStart": pid_start,
    "pgid": int(pgid) if pgid.isdigit() else 0,
    "startedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "log": log,
    "baseSha": base_sha,
    "batchId": batch_id,
    "state": "launched",
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

singular_dispatch_exit_write() {
  # Called by the spawn wrapper after the driver returns. tmp+mv so a reader
  # never sees a partial code.
  local task_id="$1" ec="$2"
  mkdir -p "$SINGULAR_DISPATCH_DIR"
  local exit_file tmp
  exit_file="$(singular_dispatch_exit_path "$task_id")"
  tmp="$exit_file.tmp"
  printf '%s\n' "$ec" >"$tmp"
  mv -f "$tmp" "$exit_file"
}

singular_dispatch_record_finalize() {
  # args: task_id exit_code outcome  -- marks the record reaped, removes .exit
  local task_id="$1" ec="$2" outcome="$3"
  local record
  record="$(singular_dispatch_record_path "$task_id")"
  [[ -f "$record" ]] || return 0
  python3 - "$record" "$ec" "$outcome" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, ec, outcome = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["state"] = "reaped"
data["exitCode"] = int(ec)
data["outcome"] = outcome
data["reapedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
  rm -f "$(singular_dispatch_exit_path "$task_id")"
}

# Whole-tree dispatch liveness. The 0.4.0 reaper checked only the recorded root
# pid, so a dead wrapper with a still-running auditor child was "crashed" — the
# lease was deleted under a live process (field audit: accepted work destroyed,
# then an infinite re-dispatch loop). Alive (rc 0) if ANY of:
#   - root pid alive with matching pidStart (pid-reuse-safe),
#   - any live process in the recorded pgid (skipped when it is our own group),
#   - any live descendant reachable from the root pid,
#   - any process whose command line carries the run id (survives reparenting),
#   - any file under the run dir modified within SINGULAR_TREE_ACTIVITY_WINDOW_SEC.
# Bounded conservatism: if lease_age_min >= SINGULAR_STALE_HARD_MINUTES, report
# dead regardless (prefer false-alive inside the window, never forever).
# args: task_id pid pid_start run_id pgid [lease_age_min]
singular_dispatch_tree_alive() {
  local task_id="$1" pid="$2" pid_start="$3" run_id="$4" pgid="${5:-0}" lease_age_min="${6:-}"
  if [[ -n "$lease_age_min" && "$lease_age_min" =~ ^[0-9]+$ ]] \
    && (( lease_age_min >= ${SINGULAR_STALE_HARD_MINUTES:-240} )); then
    return 1
  fi
  if singular_pid_alive "$pid"; then
    local now_start
    now_start="$(singular_dispatch_pid_start "$pid")"
    if [[ -z "$pid_start" || "$now_start" == "$pid_start" ]]; then
      return 0
    fi
  fi
  python3 - "$pid" "$pgid" "$run_id" <<'PY' && return 0
import os
import subprocess
import sys

pid_raw, pgid_raw, run_id = sys.argv[1:4]
try:
    root = int(pid_raw)
except ValueError:
    root = 0
try:
    pgid = int(pgid_raw)
except ValueError:
    pgid = 0

out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid="],
                     capture_output=True, text=True).stdout
children = {}
groups = {}
for line in out.splitlines():
    f = line.split()
    if len(f) != 3:
        continue
    try:
        p, pp, pg = int(f[0]), int(f[1]), int(f[2])
    except ValueError:
        continue
    children.setdefault(pp, []).append(p)
    groups.setdefault(pg, []).append(p)

# Live descendant of the recorded root pid.
stack = [root]
seen = set()
while stack:
    p = stack.pop()
    for c in children.get(p, []):
        if c in seen:
            continue
        seen.add(c)
        stack.append(c)
if seen:
    sys.exit(0)

# Live member of the recorded process group — but never our own group (a
# non-detached dispatch shares the reconciler's pgid; that proves nothing).
own_pgid = os.getpgid(0)
if pgid > 1 and pgid != own_pgid and groups.get(pgid):
    sys.exit(0)

# Command line carrying the run id (orphan re-parented past the tree walk).
if run_id:
    probe = subprocess.run(["pgrep", "-f", run_id], capture_output=True, text=True)
    pids = [x for x in probe.stdout.split() if x.isdigit() and int(x) != os.getpid()]
    if pids:
        sys.exit(0)
sys.exit(1)
PY
  # Recent run-dir writes: an active runner streams logs even when the process
  # topology is unreadable.
  if [[ -n "$run_id" && -d "$SINGULAR_RUNS_DIR/$run_id" ]]; then
    if python3 - "$SINGULAR_RUNS_DIR/$run_id" "${SINGULAR_TREE_ACTIVITY_WINDOW_SEC:-120}" <<'PY'
import os
import sys
import time

base, window = sys.argv[1], int(sys.argv[2])
now = time.time()
for dirpath, _dirs, files in os.walk(base):
    for name in files:
        try:
            if now - os.path.getmtime(os.path.join(dirpath, name)) <= window:
                sys.exit(0)
        except OSError:
            continue
sys.exit(1)
PY
    then
      return 0
    fi
  fi
  return 1
}

# Kill a dispatch's process GROUP — but only when the recorded pgid proves a
# setsid leader (pgid == recorded pid), never our own group, never pgid <= 1.
# Bounds the field leak of orphan Vite/Playwright gate servers surviving their
# parked workers. SINGULAR_KILL_ORPHAN_PGROUP=0 disables.
singular_kill_dispatch_pgroup() {
  local task_id="$1"
  [[ "${SINGULAR_KILL_ORPHAN_PGROUP:-1}" == "1" ]] || return 1
  local record pgid pid
  record="$(singular_dispatch_record_path "$task_id")"
  [[ -f "$record" ]] || return 1
  pgid="$(singular_json_field "$record" pgid 2>/dev/null || true)"
  pid="$(singular_json_field "$record" pid 2>/dev/null || true)"
  [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]] || return 1
  [[ "$pgid" == "$pid" ]] || return 1                      # setsid leader proven
  # os.getpgid/os.kill rather than ps/pgrep: the four guards above are what make
  # a negative-pid signal safe, and they must still be answerable where process
  # enumeration is denied. An empty own-pgid keeps 0.16's behaviour (the guard
  # compares unequal and the kill proceeds).
  local own_pgid
  own_pgid="$(singular_pgid_of "$$" | tr -d '[:space:]' || true)"
  [[ "$pgid" != "$own_pgid" ]] || return 1
  kill -TERM -- "-$pgid" 2>/dev/null || true
  local waited=0
  while singular_pgroup_alive "$pgid" && (( waited < 5 )); do
    sleep 1; waited=$((waited + 1))
  done
  if singular_pgroup_alive "$pgid"; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  singular_append_event "dispatch.pgroup_killed" "dispatch process group terminated" \
    "{\"taskId\":\"$task_id\",\"pgid\":$pgid}" 2>/dev/null || true
  return 0
}

# Reap finished/crashed dispatches. Echoes counter lines for the caller:
#   reaped_ok=N reaped_failures=N reaped_refused=N reaped_terminal=N workers_running=N
# Exit-code contract (l1-drive): 0 = ok/no-op, 2 = REFUSAL (preconditions
# unmet, no state consumed — never breaker input), 3 = TERMINAL (a decided
# outcome: parked/blocked — counts as failure), anything else = crash/infra.
# 0.4.0 counted every nonzero exit as a failure, so deterministic refusals
# (e.g. task-id collisions re-dispatching into a preserved worktree) pumped
# the breaker to a halt.
# For every record in state=launched:
#  - .exit file present -> reaped + classified per the contract
#  - no .exit -> whole-TREE liveness decides (singular_dispatch_tree_alive:
#    descendants, pgroup, run-id command lines, recent run-dir writes). The
#    0.4.0 root-pid-only check declared a dead wrapper with a live auditor
#    "crashed" and failed the lease under it (accepted work destroyed).
# args: run_id  (the CURRENT cycle's run id, for event attribution)
singular_reap_dispatches() {
  local run_id="$1"
  local reaped_ok=0 reaped_failures=0 reaped_refused=0 reaped_terminal=0 workers_running=0
  if [[ -d "$SINGULAR_DISPATCH_DIR" ]]; then
    local record tid state pid pid_start pgid rec_run ec lease_status outcome
    for record in "$SINGULAR_DISPATCH_DIR"/*.json; do
      [[ -f "$record" ]] || continue
      state="$(singular_json_field "$record" state 2>/dev/null || true)"
      [[ "$state" == "launched" ]] || continue
      tid="$(singular_json_field "$record" taskId 2>/dev/null || true)"
      [[ -n "$tid" ]] || continue
      pid="$(singular_json_field "$record" pid 2>/dev/null || true)"
      pid_start="$(singular_json_field "$record" pidStart 2>/dev/null || true)"
      pgid="$(singular_json_field "$record" pgid 2>/dev/null || true)"
      rec_run="$(singular_json_field "$record" runId 2>/dev/null || true)"
      if [[ -f "$(singular_dispatch_exit_path "$tid")" ]]; then
        ec="$(head -1 "$(singular_dispatch_exit_path "$tid")" 2>/dev/null | tr -d '[:space:]')"
        [[ "$ec" =~ ^[0-9]+$ ]] || ec=1
        case "$ec" in
          0) outcome="ok";       reaped_ok=$((reaped_ok + 1)) ;;
          2) outcome="refused";  reaped_refused=$((reaped_refused + 1)) ;;
          3) outcome="terminal"; reaped_terminal=$((reaped_terminal + 1)) ;;
          *) outcome="failed";   reaped_failures=$((reaped_failures + 1)) ;;
        esac
        singular_dispatch_record_finalize "$tid" "$ec" "$outcome"
        singular_append_event "origin.dispatch_reaped" "dispatch reaped" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":$ec,\"outcome\":\"$outcome\"}"
        continue
      fi
      if singular_dispatch_tree_alive "$tid" "$pid" "$pid_start" "$rec_run" "${pgid:-0}"; then
        workers_running=$((workers_running + 1))
        continue
      fi
      lease_status="$(singular_lease_status "$tid" 2>/dev/null || true)"
      case "$lease_status" in
        planned|running|needs-review) singular_lease_set_status "$tid" "failed" 2>/dev/null || true ;;
      esac
      reaped_failures=$((reaped_failures + 1))
      singular_dispatch_record_finalize "$tid" "-1" "crashed"
      singular_append_event "origin.dispatch_reaped" "dispatch crashed (tree dead, no exit file)" \
        "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":-1,\"outcome\":\"crashed\",\"leaseStatus\":\"$lease_status\"}"
    done
  fi
  echo "reaped_ok=$reaped_ok"
  echo "reaped_failures=$reaped_failures"
  echo "reaped_refused=$reaped_refused"
  echo "reaped_terminal=$reaped_terminal"
  echo "workers_running=$workers_running"
}

# --- L1 node leases (parallel-area planning) ---
# An L1 lease reserves a single DAG node (and, in V1, its whole area) so that
# only one L1 planner advances a given area at a time. Completion authority is
# unchanged: an L1 lease NEVER means "complete" — the gate-result.v0 record is
# the only completion truth. These helpers mirror the L2 task-lease helpers.

# Map a DAG area to its repo-relative write-scope prefix(es). V1 uses the single
# convention internal/<area>/, centralized here so V2 can extend it (e.g. to a
# real per-node ownedFiles manifest) in one place.
singular_l1_area_write_scopes() {
  local area="$1"
  [[ -n "$area" ]] || return 0
  # Consumer-provided area->path map (SINGULAR_AREA_PATHS: newline list of
  # "area=path1[:path2]"); unmapped areas fall back to SINGULAR_AREA_PREFIX + area.
  if [[ -n "${SINGULAR_AREA_PATHS:-}" ]]; then
    local line key val p
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      key="${line%%=*}"
      val="${line#*=}"
      if [[ "$key" == "$area" ]]; then
        local paths
        IFS=':' read -ra paths <<< "$val"
        for p in "${paths[@]}"; do
          [[ -n "$p" ]] && echo "$p"
        done
        return 0
      fi
    done <<< "$SINGULAR_AREA_PATHS"
  fi
  echo "${SINGULAR_AREA_PREFIX:-internal/}$area/"
}

# Validate a JSON string against a JSON-Schema subset (dependency-free; mirrors
# the rules dag.sh enforces on gate-results). Supports type, const, enum,
# minLength, pattern, format:date-time, array minItems/items, and object
# required/properties/additionalProperties. Exits non-zero with a stderr message
# on the first violation (fail-closed). args: <json-string> <schema-path> [root-label]
singular_json_schema_check() {
  python3 - "$2" "$1" "${3:-value}" <<'PY'
import json
import re
import sys
from datetime import datetime

schema_path, raw, root = sys.argv[1], sys.argv[2], sys.argv[3]
with open(schema_path, "r", encoding="utf-8") as f:
    schema = json.load(f)
try:
    data = json.loads(raw)
except Exception as exc:
    sys.stderr.write("invalid JSON: %s\n" % exc)
    sys.exit(2)


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(2)


def check(val, spec, where):
    kind = spec.get("type")
    if kind == "string" and not isinstance(val, str):
        fail(f"{where} must be a string")
    if kind == "boolean" and not isinstance(val, bool):
        fail(f"{where} must be a boolean")
    if kind == "array" and not isinstance(val, list):
        fail(f"{where} must be an array")
    if kind == "object" and not isinstance(val, dict):
        fail(f"{where} must be an object")
    if kind == "integer" and (not isinstance(val, int) or isinstance(val, bool)):
        fail(f"{where} must be an integer")
    if "const" in spec and val != spec["const"]:
        fail(f"{where} must equal {spec['const']!r}")
    if "enum" in spec and val not in spec["enum"]:
        fail(f"{where} must be one of {spec['enum']}")
    if kind == "string":
        min_len = spec.get("minLength")
        if min_len is not None and len(val) < min_len:
            fail(f"{where} must be at least {min_len} character(s)")
        if spec.get("format") == "date-time":
            try:
                datetime.fromisoformat(str(val).replace("Z", "+00:00"))
            except ValueError:
                fail(f"{where} must be an ISO-8601 date-time")
        pattern = spec.get("pattern")
        # JSON Schema `pattern` uses regular-expression search semantics, not
        # an implicit whole-string match.  Schemas that require a full match
        # carry their own ^...$ anchors.
        if pattern and not re.search(pattern, val):
            fail(f"{where} must match pattern {pattern}")
    if kind == "array":
        min_items = spec.get("minItems")
        if min_items is not None and len(val) < min_items:
            fail(f"{where} must have at least {min_items} item(s)")
        item_spec = spec.get("items", {})
        for idx, item in enumerate(val):
            check(item, item_spec, f"{where}[{idx}]")
    if kind == "object":
        props = spec.get("properties", {})
        if spec.get("additionalProperties") is False:
            unknown = sorted(set(val) - set(props))
            if unknown:
                fail(f"{where} has unknown field(s): {', '.join(unknown)}")
        for key in spec.get("required", []):
            if key not in val:
                fail(f"{where} missing required field: {key}")
        for key, child in props.items():
            if key in val:
                check(val[key], child, f"{where}.{key}" if where else key)


check(data, schema, root)
PY
}

# Load a verdict file as compact JSON, normalizing a legacy "pmgo.orchestration.*"
# schema id to "singular.orchestration.*" for validation purposes only (the file
# is never rewritten). Default mode "warn" keeps 0.4.0-era consumers alive with
# a stderr warning + schema.legacy_id_tolerated event; SINGULAR_LEGACY_SCHEMA_MODE=reject
# hard-fails with a migration pointer (post-migration hygiene). Prints the
# (possibly normalized) compact JSON on stdout.
singular_normalize_schema_id() {
  local file="$1" label="${2:-verdict}"
  python3 - "$file" "${SINGULAR_LEGACY_SCHEMA_MODE:-warn}" "$label" <<'PY'
import json
import sys

path, mode, label = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
schema = str(data.get("schema", ""))
if schema.startswith("pmgo.orchestration."):
    new = "singular.orchestration." + schema[len("pmgo.orchestration."):]
    if mode == "reject":
        print(
            f"{label}: legacy schema id {schema!r} — run migrations/v0-to-v1.sh "
            "or set SINGULAR_LEGACY_SCHEMA_MODE=warn",
            file=sys.stderr,
        )
        sys.exit(2)
    print(f"{label}: tolerating legacy schema id {schema!r} -> {new!r}", file=sys.stderr)
    data["schema"] = new
print(json.dumps(data, separators=(",", ":")))
PY
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    # Emit the tolerance event only when a rewrite actually happened.
    if grep -q '"schema"[[:space:]]*:[[:space:]]*"pmgo\.orchestration\.' "$file" 2>/dev/null; then
      singular_append_event "schema.legacy_id_tolerated" "legacy pmgo schema id tolerated" \
        "{\"file\":\"$file\",\"label\":\"$label\"}" 2>/dev/null || true
    fi
  fi
  return $rc
}

# Central audit-verdict validator (symmetric with singular_validate_decider_verdict —
# 0.4.0 validated decider verdicts centrally but audit verdicts nowhere, so a
# malformed auditor JSON silently poisoned acceptance decisions). Schema-checks
# against SINGULAR_AUDIT_SCHEMA plus cross-field checks: taskId must match when
# both sides are non-empty; runId mismatch is warn-only (infra retries reuse runs).
singular_validate_audit_verdict() {
  local verdict="$1" task_id="${2:-}" run_id="${3:-}"
  local data
  data="$(singular_normalize_schema_id "$verdict" "audit verdict")" || return $?
  singular_json_schema_check "$data" "$SINGULAR_AUDIT_SCHEMA" "audit verdict" || return $?
  python3 - "$verdict" "$task_id" "$run_id" <<'PY'
import json
import sys

path, task_id, run_id = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
verdict_task = data.get("taskId", "")
if task_id and verdict_task and verdict_task != task_id:
    print(
        "audit verdict taskId mismatch: expected %r, got %r" % (task_id, verdict_task),
        file=sys.stderr,
    )
    sys.exit(2)
verdict_run = data.get("runId", "")
if run_id and verdict_run and verdict_run != run_id:
    print(
        "audit verdict runId mismatch (warn-only): expected %r, got %r" % (run_id, verdict_run),
        file=sys.stderr,
    )
PY
}

singular_validate_decider_verdict() {
  local verdict="$1" failure_class="$2" task_id="${3:-}"
  local data
  data="$(singular_normalize_schema_id "$verdict" "decider verdict")" || return $?
  singular_json_schema_check "$data" "$SINGULAR_DECIDER_SCHEMA" "decider verdict" || return $?
  python3 - "$verdict" "$failure_class" "$task_id" <<'PY'
import json
import sys

path, failure_class, task_id = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
if data.get("failureClass") != failure_class:
    print(
        "decider verdict failureClass mismatch: expected %r, got %r"
        % (failure_class, data.get("failureClass")),
        file=sys.stderr,
    )
    sys.exit(2)
verdict_task = data.get("taskId")
if task_id and verdict_task and verdict_task != task_id:
    print(
        "decider verdict taskId mismatch: expected %r, got %r"
        % (task_id, verdict_task),
        file=sys.stderr,
    )
    sys.exit(2)
PY
}

singular_write_decider_verdict() {
  local out="$1" task_id="$2" failure_class="$3" action="$4" rationale="$5" next_owner="$6"
  mkdir -p "$(dirname "$out")"
  python3 - "$out" "$task_id" "$failure_class" "$action" "$rationale" "$next_owner" <<'PY'
import json
import sys
from datetime import datetime, timezone

out, task_id, failure_class, action, rationale, next_owner = sys.argv[1:7]
data = {
    "schema": "singular.orchestration.decider-verdict.v0",
    "failureClass": failure_class,
    "action": action,
    "rationale": rationale,
    "nextOwner": next_owner,
    "params": {"fallbackGeneratedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")},
}
if task_id:
    data["taskId"] = task_id
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# Pretty-write a compact JSON string to a path, matching the repo's lease format
# (indent=2 + trailing newline). The JSON is passed as an argument (NOT stdin),
# since stdin is consumed by the heredoc that carries this script.
# args: <dest-path> <compact-json>
singular_write_json_pretty() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
data = json.loads(sys.argv[2])
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# ---- Supervisor briefing + ask (0.10.0) -------------------------------------
# Read-only overseer helpers. Every function here is INERT until an explicit
# supervise.sh / ask.sh spawn (or the autonomate interval gate) calls it, so
# merely sourcing lib.sh writes nothing and an ordinary reconcile cycle stays
# byte-identical to 0.9.0.

# The writable-settings menu the supervisor may PROPOSE (never apply). The real
# whitelist + typed validation lives server-side (_settings_write_spec); this is
# the human-facing knob list surfaced to the model as guidance / defense-in-depth.
singular_settings_whitelist_keys() {
  cat <<'EOF'
SINGULAR_CODEX_MODEL
SINGULAR_CODEX_SERVICE_TIER
SINGULAR_CODEX_PLANNER_REASONING_EFFORT
SINGULAR_CODEX_L2_REASONING_EFFORT
SINGULAR_CODEX_AUDITOR_REASONING_EFFORT
SINGULAR_MAX_CONCURRENT
SINGULAR_MAX_L1_CONCURRENT
SINGULAR_ENABLE_L1_PARALLEL
SINGULAR_L1_TASKS_PER_NODE
SINGULAR_L2_SLICE_BUDGET
SINGULAR_L2_SLICE_BUDGET_MAX
SINGULAR_MAX_RETRIES
SINGULAR_MAX_CONSEC_FAILS
SINGULAR_MAX_HOURS
SINGULAR_MIN_DISK_GB
SINGULAR_L1_STALE_MINUTES
SINGULAR_PLANNER_BACKOFF_SECONDS
SINGULAR_PLANNER_QUOTA_BACKOFF_SECONDS
SINGULAR_PLANNER_OVERLOAD_BACKOFF_SECONDS
SINGULAR_OVERLOAD_WAIT_BUDGET
SINGULAR_AUTO_INTEGRATE
SINGULAR_PUSH
SINGULAR_GENERATE
SINGULAR_SLEEP
SINGULAR_TARGET_BRANCH
SINGULAR_SUPERVISOR_INTERVAL_MIN
EOF
}

# Build the shared read-only situational digest into <out> as a delimited file.
# Sections (each clamped to 4000 chars, ~24KB ceiling): STATUS.md verbatim,
# ops health JSON, DAG frontier JSON, gate table JSON, the last 30 events
# (compact ts/type/message), the config env{} block, and the settings whitelist.
# Both supervise.sh and ask.sh consume this via singular_render_supervisor_prompt.
singular_supervisor_digest() {
  local out="$1"
  singular_ensure_state_dirs
  local status health frontier gates events cfgenv whitelist
  status="$(cat "$SINGULAR_STATUS_FILE" 2>/dev/null || true)"; [[ -n "$status" ]] || status="(no STATUS.md written yet)"
  health="$("$(singular_bash_bin)" "$SINGULAR_ENGINE_DIR/ops.sh" health --json 2>/dev/null || true)"; [[ -n "$health" ]] || health="{}"
  # An unevaluable DAG must not reach the supervisor as an empty frontier: the
  # model would reason about a graph with no ready work when the real answer is
  # "the graph could not be read".
  frontier="$(singular_dag_next_areas_json || true)"
  [[ -n "$frontier" ]] || frontier='{"frontierUnavailable":true}'
  gates="$("$(singular_bash_bin)" "$SINGULAR_ENGINE_DIR/ops.sh" gates --json 2>/dev/null || true)"; [[ -n "$gates" ]] || gates="{}"
  events="$(tail -n 30 "$SINGULAR_EVENTS_FILE" 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
        print("%s  %s  %s" % (e.get("ts", ""), e.get("type", ""), e.get("message", "")))
    except Exception:
        pass
' 2>/dev/null || true)"
  [[ -n "$events" ]] || events="(no events yet)"
  cfgenv="$(python3 - "$SINGULAR_JSON_CONFIG_FILE" 2>/dev/null <<'PY' || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    env = cfg.get("env") or {}
    for k in sorted(env):
        print("%s=%s" % (k, env[k]))
except Exception:
    pass
PY
)"
  [[ -n "$cfgenv" ]] || cfgenv="(no config env{})"
  whitelist="$(singular_settings_whitelist_keys)"
  python3 - "$out" "$status" "$health" "$frontier" "$gates" "$events" "$cfgenv" "$whitelist" <<'PY'
import sys
out = sys.argv[1]
keys = ["STATUS-MD", "HEALTH-JSON", "FRONTIER-JSON", "GATES-JSON", "EVENTS-TAIL", "CONFIG-ENV", "SETTINGS-WHITELIST"]
vals = sys.argv[2:9]
CLAMP = 4000
parts = []
for key, val in zip(keys, vals):
    s = (val or "").strip("\n")
    if len(s) > CLAMP:
        s = s[:CLAMP] + "\n…(truncated)"
    parts.append("<<<SINGULAR:%s>>>\n%s\n" % (key, s))
parts.append("<<<SINGULAR:END>>>\n")
with open(out, "w", encoding="utf-8") as f:
    f.write("".join(parts))
PY
}

# Render a supervisor/ask prompt template into <out> by substituting the digest
# sections for [STATUS-MD] [HEALTH-JSON] [FRONTIER-JSON] [GATES-JSON]
# [EVENTS-TAIL] [CONFIG-ENV] [SETTINGS-WHITELIST], plus [QUESTION] from the
# (optional) question FILE. The question is read from a file and written into the
# rendered prompt file ONLY — it never transits a runner argv.
singular_render_supervisor_prompt() {
  local tmpl="$1" digest="$2" out="$3" qfile="${4:-}"
  python3 - "$tmpl" "$digest" "$out" "$qfile" <<'PY'
import sys
tmpl_path, digest_path, out_path, qfile = sys.argv[1:5]
with open(tmpl_path, "r", encoding="utf-8") as f:
    tmpl = f.read()
sections = {}
cur = None
buf = []
with open(digest_path, "r", encoding="utf-8") as f:
    for line in f:
        s = line.rstrip("\n")
        if s.startswith("<<<SINGULAR:") and s.endswith(">>>"):
            if cur is not None:
                sections[cur] = "\n".join(buf).strip("\n")
            key = s[len("<<<SINGULAR:"):-3]
            if key == "END":
                cur = None
                break
            cur = key
            buf = []
        else:
            buf.append(line.rstrip("\n"))
    if cur is not None:
        sections[cur] = "\n".join(buf).strip("\n")
question = ""
if qfile:
    try:
        with open(qfile, "r", encoding="utf-8") as f:
            question = f.read().strip()
    except Exception:
        question = ""
repl = {
    "[STATUS-MD]": sections.get("STATUS-MD", ""),
    "[HEALTH-JSON]": sections.get("HEALTH-JSON", ""),
    "[FRONTIER-JSON]": sections.get("FRONTIER-JSON", ""),
    "[GATES-JSON]": sections.get("GATES-JSON", ""),
    "[EVENTS-TAIL]": sections.get("EVENTS-TAIL", ""),
    "[CONFIG-ENV]": sections.get("CONFIG-ENV", ""),
    "[SETTINGS-WHITELIST]": sections.get("SETTINGS-WHITELIST", ""),
    "[QUESTION]": question,
}
for needle, value in repl.items():
    tmpl = tmpl.replace(needle, value)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl)
PY
}

# Validate an extracted supervisor report against SINGULAR_SUPERVISOR_SCHEMA
# (required schema/stage/narrative, additionalProperties false, string items),
# then post-check the constraints the shared checker does not cover: risks /
# nextSteps are <=8 strings and proposedSettings is a string->string map.
# Returns non-zero (with a stderr reason) on any violation. Symmetric with
# singular_validate_decider_verdict.
singular_validate_supervisor_report() {
  local file="$1" data
  data="$(python3 - "$file" <<'PY' 2>/dev/null || true
import json, sys
try:
    print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))
except Exception:
    sys.exit(2)
PY
)"
  [[ -n "$data" ]] || { echo "supervisor report: not parseable JSON" >&2; return 2; }
  singular_json_schema_check "$data" "$SINGULAR_SUPERVISOR_SCHEMA" "supervisor report" || return $?
  python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("risks", "nextSteps"):
    v = d.get(k)
    if v is None:
        continue
    if not isinstance(v, list) or len(v) > 8 or any(not isinstance(x, str) for x in v):
        print("supervisor report: %s must be at most 8 strings" % k, file=sys.stderr)
        sys.exit(2)
ps = d.get("proposedSettings")
if ps is not None:
    if not isinstance(ps, dict) or any(
        not isinstance(k, str) or not isinstance(val, str) for k, val in ps.items()
    ):
        print("supervisor report: proposedSettings must be a string->string map", file=sys.stderr)
        sys.exit(2)
PY
}

singular_l1_lease_path() {
  echo "$SINGULAR_L1_LEASES_DIR/$1.json"
}

singular_l1_lease_status() {
  local node="$1" lease
  lease="$(singular_l1_lease_path "$node")"
  [[ -f "$lease" ]] || return 1
  singular_json_field "$lease" status 2>/dev/null || true
}

singular_l1_lease_field() {
  local node="$1" field="$2" lease
  lease="$(singular_l1_lease_path "$node")"
  [[ -f "$lease" ]] || return 1
  singular_json_field "$lease" "$field" 2>/dev/null || true
}

# Write (create or overwrite) an L1 node lease. The candidate object is built,
# then FULLY validated against the schema (every field, incl. minLength/pattern/
# enum/additionalProperties) before anything is written — fail-closed, so a
# malformed lease (empty node, bad status/baseSha, unknown field) is never
# persisted and the leases dir is not even created. On update, startedAt is
# preserved and baseSha falls back to the prior value when omitted.
# args: node area stage layer status runId baseSha targetBranch [scopesJson]
singular_l1_lease_write() {
  local node="$1" area="$2" stage="$3" layer="$4" status="$5"
  local run_id="$6" base_sha="$7" target_branch="$8" scopes_json="${9:-}"
  if [[ -z "$scopes_json" ]]; then
    scopes_json="$(singular_l1_area_write_scopes "$area" \
      | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().split() if l]))')"
  fi
  local lease started=""
  lease="$(singular_l1_lease_path "$node")"
  if [[ -f "$lease" ]]; then
    started="$(singular_json_field "$lease" startedAt 2>/dev/null || true)"
    [[ -n "$base_sha" ]] || base_sha="$(singular_json_field "$lease" baseSha 2>/dev/null || true)"
  fi
  local data
  data="$(python3 - "$node" "$area" "$stage" "$layer" "$status" "$run_id" \
    "$base_sha" "$target_branch" "$scopes_json" "$started" <<'PY'
import json
import sys
from datetime import datetime, timezone

(node, area, stage, layer, status, run_id,
 base_sha, target_branch, scopes_raw, started) = sys.argv[1:11]
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
try:
    scopes = json.loads(scopes_raw) if scopes_raw else []
    if not isinstance(scopes, list):
        scopes = []
except Exception:
    scopes = []
data = {
    "schema": "singular.orchestration.l1-lease.v0",
    "node": node,
    "area": area,
    "stage": stage,
    "layer": layer,
    "status": status,
    "runId": run_id,
    "baseSha": base_sha,
    "targetBranch": target_branch,
    "allowedWriteScopes": [str(s) for s in scopes],
    "startedAt": started or now,
    "updatedAt": now,
}
print(json.dumps(data, separators=(",", ":")))
PY
)" || return $?
  singular_json_schema_check "$data" "$SINGULAR_L1_LEASE_SCHEMA" "l1 lease" || return $?
  mkdir -p "$SINGULAR_L1_LEASES_DIR"
  singular_write_json_pretty "$lease" "$data"
}

# Update only the status (and updatedAt) of an existing L1 lease. The full
# mutated object is re-validated against the schema; on any violation (e.g. a
# bogus status) the call fails and the existing lease is left untouched.
singular_l1_lease_set_status() {
  local node="$1" status="$2" lease
  lease="$(singular_l1_lease_path "$node")"
  [[ -f "$lease" ]] || return 1
  local data
  data="$(python3 - "$lease" "$status" <<'PY'
import json
import sys
from datetime import datetime, timezone
path, status = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["status"] = status
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
print(json.dumps(data, separators=(",", ":")))
PY
)" || return $?
  singular_json_schema_check "$data" "$SINGULAR_L1_LEASE_SCHEMA" "l1 lease" || return $?
  singular_write_json_pretty "$lease" "$data"
}

# Echo active L1 node ids (status in proposed|planning|active), sorted.
singular_l1_list_active() {
  local lease status node
  [[ -d "$SINGULAR_L1_LEASES_DIR" ]] || return 0
  while IFS= read -r lease; do
    [[ -n "$lease" ]] || continue
    status="$(singular_json_field "$lease" status 2>/dev/null || true)"
    case "$status" in
      proposed|planning|active)
        node="$(singular_json_field "$lease" node 2>/dev/null || true)"
        [[ -n "$node" ]] && echo "$node"
        ;;
    esac
  done < <(find "$SINGULAR_L1_LEASES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
}

# Report stale active L1 leases (status proposed|planning|active whose updatedAt
# exceeds SINGULAR_L1_STALE_MINUTES). REPORT ONLY — never auto-clears or reuses a
# lease, so a stale slot is surfaced for a human/decider, never silently
# reclaimed. Emits "<node> <status> <ageMinutes|unknown>" per stale lease.
singular_l1_list_stale() {
  local minutes="${SINGULAR_L1_STALE_MINUTES:-60}" lease status node updated
  [[ -d "$SINGULAR_L1_LEASES_DIR" ]] || return 0
  while IFS= read -r lease; do
    [[ -n "$lease" ]] || continue
    status="$(singular_json_field "$lease" status 2>/dev/null || true)"
    case "$status" in proposed|planning|active) ;; *) continue ;; esac
    node="$(singular_json_field "$lease" node 2>/dev/null || true)"
    updated="$(singular_json_field "$lease" updatedAt 2>/dev/null || true)"
    python3 - "$node" "$status" "$updated" "$minutes" <<'PY'
import sys
from datetime import datetime, timezone
node, status, updated, minutes = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
def age(u):
    if not u:
        return None
    try:
        t = datetime.fromisoformat(u.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (datetime.now(timezone.utc) - t).total_seconds() / 60.0
a = age(updated)
if a is None or a >= minutes:
    print("%s %s %s" % (node, status, "unknown" if a is None else int(a)))
PY
  done < <(find "$SINGULAR_L1_LEASES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
}

# Reclaim stale L1 planning leases (0.5.0). singular_l1_list_stale is
# report-only; in the field three orphaned `active` L1 leases from an
# interrupted planning run excluded their nodes from the frontier for hours
# with no recovery path short of hand-editing lease JSON. Marks each stale
# lease failed (frontier selection only excludes proposed|planning|active) and
# emits recover.l1_lease_reclaimed. Planners are short-lived; the wall-clock
# threshold (SINGULAR_L1_STALE_MINUTES) is conservative.
singular_l1_reclaim_stale() {
  local line node status age reclaimed=0
  while IFS=' ' read -r node status age; do
    [[ -n "$node" ]] || continue
    if ! singular_l1_lease_set_status "$node" failed; then
      echo "recover: could not reclassify l1 lease $node (see error above)" >&2
      continue
    fi
    singular_append_event "recover.l1_lease_reclaimed" "stale l1 planning lease reclassified failed" \
      "{\"node\":\"$node\",\"previousStatus\":\"$status\",\"ageMin\":\"$age\"}"
    echo "recover: reclaimed stale l1 lease $node ($status, ${age}m)"
    reclaimed=$((reclaimed + 1))
  done < <(singular_l1_list_stale)
  return 0
}

# Select up to `limit` ready L1 nodes for parallel planning. READ-ONLY: queries
# dag.sh next-areas and the existing l1-leases; writes nothing. Drops nodes that
# (a) already have an active L1 lease, (b) belong to an area that already has an
# active L1 lease (the V1 primary guard), or (c) overlap an active lease's
# allowedWriteScopes. Emits selected node ids in DAG order, one per line.
# Evaluate the DAG frontier, and SAY SO when it cannot be evaluated.
#
# dag.sh produces a precise diagnostic on stderr and exits 2 — "gate-result.v1
# for loc-00-contract evidence[0] ref must be a safe repository-relative path:
# /private/tmp/…" — and every caller sent it to /dev/null and reported an empty
# frontier. An invalid DAG was therefore indistinguishable from "no ready work",
# which cost a field operator 34 minutes staring at frontier=0 while three nodes
# were ready and one malformed gate file was the whole problem.
#
# Non-fatal by design: the loop must keep dispatching, integrating and reaping
# other work. It just may not do it silently. Prints the frontier JSON on
# success; on failure prints nothing, warns, emits dag.evaluation_failed, and
# returns non-zero so the caller can distinguish the two.
singular_dag_next_areas_json() {
  local err_file out rc=0
  err_file="$(mktemp)"
  # SINGULAR_LIB_DIR, never SINGULAR_ENGINE_DIR: the latter is an overridable knob
  # (tests shim it to a directory of selected ctx-*.sh symlinks) and resolving an
  # engine executable through it breaks under that shim.
  out="$("$SINGULAR_LIB_DIR/dag.sh" next-areas 2>"$err_file")" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$err_file"
    printf '%s' "$out"
    return 0
  fi
  local err
  err="$(cat "$err_file" 2>/dev/null || true)"
  rm -f "$err_file"
  [[ -n "$err" ]] || err="dag.sh next-areas exited $rc without a diagnostic"
  echo "dag: frontier evaluation failed: $err" >&2
  singular_dag_evaluation_failed_event "$err" "$rc"
  return "$rc"
}

# One event per distinct diagnostic. The frontier is evaluated every cycle, so an
# unthrottled event would bury events.ndjson under thousands of copies of the
# same line; keying the marker on the message means a CHANGED error still
# reports. Mirrors singular_capability_optional_warn_once's O_EXCL marker.
singular_dag_evaluation_failed_event() {
  local err="$1" exit_code="${2:-2}"
  local warning_dir="$SINGULAR_STATE_DIR/warnings/dag"
  local key marker
  key="$(singular_sha256_text "$err")"
  marker="$warning_dir/$key.warned"
  mkdir -p "$warning_dir" 2>/dev/null || return 0
  python3 - "$marker" <<'PY' 2>/dev/null || return 0
import os
import sys

try:
    os.close(os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
except FileExistsError:
    raise SystemExit(1)
PY
  local payload
  payload="$(python3 - "$err" "$exit_code" <<'PY'
import json
import sys

print(json.dumps({"stderr": sys.argv[1], "exitCode": int(sys.argv[2])},
                 separators=(",", ":")))
PY
)"
  singular_append_event "dag.evaluation_failed" \
    "dag frontier could not be evaluated; an empty frontier here is not 'no work'" \
    "$payload" 2>/dev/null || true
}

singular_select_l1_frontier() {
  local limit="${1:-1}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=1
  [[ "$limit" -gt 0 ]] || return 0

  local frontier_json
  # A failure here still yields no nodes -- the loop must not stop -- but it is
  # now reported rather than presented as "no eligible frontier nodes".
  frontier_json="$(singular_dag_next_areas_json)" || return 0

  # Pre-resolve each candidate area's configured write scopes through the
  # config-driven map (singular_l1_area_write_scopes), so the overlap guard below
  # compares the SAME scopes the leases carry — not a hardcoded internal/<area>/.
  local _frontier_areas _area scopes_map_json="{}"
  _frontier_areas="$(printf '%s' "$frontier_json" | python3 -c '
import json, sys
try:
    frontier = json.load(sys.stdin).get("frontier", [])
except Exception:
    frontier = []
seen = []
for entry in frontier:
    area = entry.get("area")
    if area and str(area) not in seen:
        seen.append(str(area))
for area in seen:
    print(area)
')"
  while IFS= read -r _area; do
    [[ -n "$_area" ]] || continue
    scopes_map_json="$(singular_l1_area_write_scopes "$_area" | python3 -c '
import json, sys
area, current = sys.argv[1], json.loads(sys.argv[2])
current[area] = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(current, separators=(",", ":")))
' "$_area" "$scopes_map_json")"
  done <<< "$_frontier_areas"

  python3 - "$limit" "$SINGULAR_L1_LEASES_DIR" "$frontier_json" "$scopes_map_json" <<'PY'
import json
import os
import sys

limit = int(sys.argv[1])
leases_dir = sys.argv[2]
frontier_raw = sys.argv[3]
scopes_map_raw = sys.argv[4] if len(sys.argv) > 4 else "{}"

try:
    frontier = json.loads(frontier_raw).get("frontier", [])
except Exception:
    frontier = []

try:
    scopes_map = json.loads(scopes_map_raw)
    if not isinstance(scopes_map, dict):
        scopes_map = {}
except Exception:
    scopes_map = {}

ACTIVE = {"proposed", "planning", "active"}

def useful_scope(value):
    value = str(value or "").strip()
    if not value or "/" not in value or " " in value:
        return ""
    return value.rstrip("/")

def path_conflict(a, b):
    if not a or not b:
        return False
    return a == b or a.startswith(b.rstrip("/") + "/") or b.startswith(a.rstrip("/") + "/")

def any_conflict(left, right):
    return any(path_conflict(a, b) for a in left for b in right)

active_nodes = set()
active_areas = set()
active_scopes = []  # one scope-list per active lease

if os.path.isdir(leases_dir):
    for name in sorted(os.listdir(leases_dir)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(leases_dir, name), "r", encoding="utf-8") as f:
                lease = json.load(f)
        except Exception:
            continue
        if lease.get("status") not in ACTIVE:
            continue
        node = lease.get("node")
        area = lease.get("area")
        if node:
            active_nodes.add(node)
        if area:
            active_areas.add(area)
        scope = [s for s in (useful_scope(v) for v in lease.get("allowedWriteScopes", [])) if s]
        active_scopes.append(scope)

selected = []
selected_areas = set()
selected_scopes = []
for entry in frontier:                       # DAG order preserved
    if len(selected) >= limit:
        break
    node = entry.get("node")
    area = entry.get("area")
    if not node:
        continue
    if node in active_nodes:                  # (a) node already leased
        continue
    if area in active_areas:                  # (b) area already leased
        continue
    if area in selected_areas:                # one node per area within this batch
        continue
    if area:
        scope_list = scopes_map.get(str(area))
        if scope_list is None:
            # Area absent from the pre-resolved map: same fallback the config
            # loader uses (SINGULAR_AREA_PREFIX, default internal/) + area.
            prefix = os.environ.get("SINGULAR_AREA_PREFIX") or "internal/"
            scope_list = ["%s%s/" % (prefix, area)]
        scope = [useful_scope(v) for v in scope_list]
    else:
        scope = []
    scope = [s for s in scope if s]
    if any(any_conflict(scope, a) for a in active_scopes):    # (c) scope overlap vs active
        continue
    if any(any_conflict(scope, s) for s in selected_scopes):  # scope overlap within batch
        continue
    selected.append(node)
    selected_areas.add(area)
    selected_scopes.append(scope)

for node in selected:
    print(node)
PY
}

# Free space (whole GiB, floored) on the repo's filesystem. df -k is POSIX
# (1024-blocks) and identical on macOS and Linux; column 4 is Available in KiB.
# Flooring rounds DOWN free space, the safe direction for a guard.
singular_free_disk_gb() {
  df -k "$SINGULAR_ROOT" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1024 / 1024 }'
}

# Highest TASK-#### number observable across EVERY durable surface: task files
# (including tasks/superseded/ and any archive subdir), leases (filenames and
# taskId fields, incl. quarantined), dispatch records, worktree dirs, imported
# packet dirs, and agent/* branches. The 0.4.0 allocator scanned only the
# active tasks dir at maxdepth 1, so archiving the highest task let the next
# plan REUSE its id and collide with the preserved worktree/lease/branch
# (field audit: 4 collisions, 2 breaker halts, 1 destroyed lease).
singular_task_id_scan_max() {
  python3 - "$SINGULAR_TASKS_DIR" "$SINGULAR_LEASES_DIR" "$SINGULAR_DISPATCH_DIR" \
    "$SINGULAR_WORKTREES_DIR" "$SINGULAR_ORCH_DIR/packets/imported" "$SINGULAR_ROOT" <<'PY'
import os
import re
import subprocess
import sys

tasks_dir, leases_dir, dispatch_dir, worktrees_dir, imported_dir, root = sys.argv[1:7]
pat = re.compile(r"TASK-0*(\d+)")
best = 0


def see(text):
    global best
    for m in pat.finditer(text or ""):
        n = int(m.group(1))
        if n > best:
            best = n


for base in (tasks_dir,):
    for dirpath, _dirs, files in os.walk(base):
        for name in files:
            if name.startswith("TASK-") and name.endswith(".md"):
                see(name)
for base in (leases_dir, dispatch_dir):
    for dirpath, _dirs, files in os.walk(base) if os.path.isdir(base) else []:
        for name in files:
            see(name)
for base in (worktrees_dir, imported_dir):
    try:
        for name in os.listdir(base):
            see(name)
    except OSError:
        pass
try:
    out = subprocess.run(
        ["git", "-C", root, "for-each-ref", "--format=%(refname:short)", "refs/heads/agent/"],
        capture_output=True, text=True, timeout=10,
    ).stdout
    see(out)
except Exception:
    pass
print(best)
PY
}

# Allocate `count` fresh sequential task ids, printed one per line. Monotonic
# via a durable counter file seeded/self-healed from singular_task_id_scan_max on
# every allocation (a deleted or stale counter can never regress below observed
# reality). Serialized by a mkdir lock; gaps from failed planner runs are
# intentional — monotonicity is the invariant, not density.
singular_task_id_counter_file() {
  printf '%s' "${SINGULAR_TASK_ID_COUNTER_FILE:-$SINGULAR_STATE_DIR/task-id-counter}"
}

singular_task_id_next() {
  local count="${1:-1}"
  [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || count=1
  singular_ensure_state_dirs
  local counter lock
  counter="$(singular_task_id_counter_file)"
  mkdir -p "$(dirname "$counter")" 2>/dev/null || true
  lock="$counter.lock"
  local waited=0
  until mkdir "$lock" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if (( waited >= 50 )); then
      echo "task-id allocator lock busy: $lock" >&2
      return 1
    fi
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null || true" RETURN
  local stored=0 scan seed i
  if [[ -f "$counter" ]]; then
    stored="$(head -1 "$counter" 2>/dev/null | tr -d '[:space:]')"
    [[ "$stored" =~ ^[0-9]+$ ]] || stored=0
  fi
  scan="$(singular_task_id_scan_max)"
  [[ "$scan" =~ ^[0-9]+$ ]] || scan=0
  seed=$(( stored > scan ? stored : scan ))
  printf '%s\n' "$((seed + count))" >"$counter"
  for ((i = 1; i <= count; i++)); do
    printf 'TASK-%04d\n' "$((seed + i))"
  done
  rmdir "$lock" 2>/dev/null || true
  trap - RETURN
}

# Deprecated 0.4.0 alias: the old maxdepth-1 active-dir scan. Kept for any
# external caller; new code must use singular_task_id_next.
singular_max_task_id() {
  singular_task_id_scan_max
}

# Rewrite every WHOLE TASK-#### token equal to $2 with $3 in file $1. Token-safe
# (matches complete TASK-\d{4,} tokens and replaces only exact-id matches), so
# rewriting TASK-0001 can never corrupt TASK-0010/TASK-00011 the way an unanchored
# substring `sed s/.../.../g` would. No-op when the ids are equal/empty.
singular_rewrite_task_id_token() {
  local file="$1" from="$2" to="$3"
  [[ -n "$from" && -n "$to" && "$from" != "$to" ]] || return 0
  python3 - "$file" "$from" "$to" <<'PY'
import re
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
new = re.sub(r"TASK-\d{4,}", lambda m: to if m.group(0) == frm else m.group(0), text)
with open(path, "w", encoding="utf-8") as f:
    f.write(new)
PY
}

# Plan up to SINGULAR_MAX_L1_CONCURRENT independent DAG nodes in parallel, then
# import their staged task proposals serially. Concurrent planners write ONLY to
# their private staging dir + their own lease + a private events file; the L0
# process (this function) is the only writer of the global tasks dir and global
# events. STOP and low disk fail closed. One planner failing never aborts or
# discards another's staged batch.
singular_l1_fanout() {
  local run_id="$1" base_sha="$2"
  # The caller's live remaining capacity is a harder ceiling than the static
  # planner cap. Direct/legacy callers that omit it retain the configured cap.
  local remaining_capacity="${3:-}"
  if singular_stop_requested; then
    singular_append_event "origin.fanout_aborted" "STOP sentinel present; no l1 fanout" "{\"runId\":\"$run_id\"}"
    return 0
  fi
  local cap="${SINGULAR_MAX_L1_CONCURRENT:-3}"
  [[ "$cap" =~ ^[0-9]+$ && "$cap" -ge 1 ]] || cap=1
  [[ -n "$remaining_capacity" ]] || remaining_capacity="$cap"
  [[ "$remaining_capacity" =~ ^[0-9]+$ ]] || remaining_capacity=0
  [[ "$cap" -gt "$remaining_capacity" ]] && cap="$remaining_capacity"
  if [[ "$cap" -eq 0 ]]; then
    echo "actuation: l1 fanout: no remaining dispatch capacity"
    echo "l1_planner_failures=0"
    echo "l1_import_rejections=0"
    return 0
  fi
  local free_gb min_gb
  free_gb="$(singular_free_disk_gb)"; [[ "$free_gb" =~ ^[0-9]+$ ]] || free_gb=0
  min_gb="${SINGULAR_MIN_DISK_GB:-1}"
  [[ "$min_gb" =~ ^[0-9]+$ ]] || min_gb=1
  if [[ "$free_gb" -lt "$min_gb" ]]; then
    singular_append_event "origin.disk_pressure" "low disk; l1 fanout blocked" \
      "{\"runId\":\"$run_id\",\"freeGb\":$free_gb,\"minGb\":$min_gb}"
    singular_append_event "origin.fanout_aborted" "low disk; no l1 fanout" \
      "{\"runId\":\"$run_id\",\"freeGb\":$free_gb,\"minGb\":$min_gb}"
    echo "actuation: l1 fanout blocked by low disk (free=${free_gb}GiB min=${min_gb}GiB)"
    return 0
  fi
  local -a nodes=()
  mapfile -t nodes < <(singular_select_l1_frontier "$cap")
  # Pending-promotion pre-filter (0.5.0): nodes whose tasks are complete but
  # whose gate is unpublished must not be re-planned (duplicate churn).
  if [[ "${SINGULAR_SUPPRESS_UNPROMOTED_REPLAN:-1}" == "1" && "${#nodes[@]}" -gt 0 ]]; then
    local -a plannable=()
    local _n
    for _n in "${nodes[@]}"; do
      if singular_node_pending_promotion "$_n" 2>/dev/null; then
        echo "actuation: l1 fanout: skipped pending-promotion node=$_n"
      else
        plannable+=("$_n")
      fi
    done
    nodes=(${plannable[@]+"${plannable[@]}"})
  fi
  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "actuation: l1 fanout: no eligible frontier nodes"
    return 0
  fi
  local plan_root="$SINGULAR_RUNS_DIR/$run_id/l1-staging"
  local planner_driver="${SINGULAR_L1_PLAN_NODE:-$(dirname "${BASH_SOURCE[0]}")/l1-plan-node.sh}"
  local tasks_per_node="${SINGULAR_L1_TASKS_PER_NODE:-1}"
  [[ "$tasks_per_node" =~ ^[0-9]+$ && "$tasks_per_node" -ge 1 ]] || tasks_per_node=1
  singular_append_event "origin.l1_fanout" "l1 fanout started" \
    "{\"runId\":\"$run_id\",\"cap\":$cap,\"nodes\":${#nodes[@]},\"freeGb\":$free_gb}"
  echo "actuation: l1 fanout cap=$cap nodes=${#nodes[@]} (${nodes[*]})"
  local -a pids=() pnodes=()
  local node node_dir node_count max_for_node
  local candidates_remaining="$remaining_capacity" node_index=0 nodes_left
  for node in "${nodes[@]}"; do
    # Reserve at least one candidate for every selected independent node, then
    # give this node any remaining configured batch allowance. The sum of all
    # --count values can never exceed the live dispatch capacity.
    nodes_left=$(( ${#nodes[@]} - node_index ))
    max_for_node=$(( candidates_remaining - nodes_left + 1 ))
    node_count="$tasks_per_node"
    [[ "$node_count" -gt "$max_for_node" ]] && node_count="$max_for_node"
    [[ "$node_count" -ge 1 ]] || break
    node_dir="$plan_root/$node"
    mkdir -p "$node_dir"
    ( "$planner_driver" --node "$node" --run-id "$run_id" --stage-dir "$node_dir" \
        --base-sha "$base_sha" --count "$node_count" ) >"$node_dir/plan.log" 2>&1 &
    pids+=("$!"); pnodes+=("$node")
    candidates_remaining=$((candidates_remaining - node_count))
    node_index=$((node_index + 1))
  done
	  local -a import_nodes=()
	  local i ec planner_failures=0 import_rejections=0 import_out parsed_rejections
	  for i in "${!pids[@]}"; do
	    ec=0; wait "${pids[$i]}" || ec=$?
	    if [[ "$ec" -eq 0 ]]; then
	      import_nodes+=("${pnodes[$i]}")
	    else
	      planner_failures=$((planner_failures + 1))
	      singular_append_event "origin.l1_planner_failed" "l1 planner failed (isolated)" \
	        "{\"runId\":\"$run_id\",\"node\":\"${pnodes[$i]}\",\"exitCode\":$ec}"
	    fi
	  done
	  if [[ "${#import_nodes[@]}" -gt 0 ]]; then
	    import_out="$(singular_l1_import_staged "$run_id" --max-candidates "$remaining_capacity" "${import_nodes[@]}" 2>&1)" || true
	    printf '%s\n' "$import_out"
	    parsed_rejections="$(printf '%s\n' "$import_out" | sed -n 's/^l1_import_rejections=//p' | tail -1)"
	    [[ "$parsed_rejections" =~ ^[0-9]+$ ]] && import_rejections="$parsed_rejections"
	  fi
	  echo "l1_planner_failures=$planner_failures"
	  echo "l1_import_rejections=$import_rejections"
	  return 0
	}

# Serially import staged task proposals into the global tasks dir. Runs only in
# the single L0 process under the origin lock the caller already holds. Real
# TASK-#### ids are allocated sequentially (recomputed per node so ids stay
# globally monotonic no matter how many planners ran), and the per-node batch is
# imported all-or-nothing after validating shape (status/area/ownedFiles/
# dispatchMode). A node's lease is released on success, marked failed otherwise.
singular_l1_import_staged() {
		  local run_id="$1"; shift
		  local max_candidates=-1 imported_candidates=0
		  if [[ "${1:-}" == "--max-candidates" ]]; then
		    max_candidates="${2:-}"
		    shift 2
		    [[ "$max_candidates" =~ ^[0-9]+$ ]] || max_candidates=0
		  fi
		  local node stage_dir node_area cand
	  local import_rejections=0
	  for node in "$@"; do
    stage_dir="$SINGULAR_RUNS_DIR/$run_id/l1-staging/$node"
    local -a cands=()
    local candidate_batch_dir=""
    if [[ -d "$stage_dir" ]]; then
      candidate_batch_dir="$(singular_task_batch_candidate_dir "$stage_dir" 2>/dev/null || true)"
      if [[ -n "$candidate_batch_dir" ]]; then
        mapfile -t cands < <(find "$candidate_batch_dir" -maxdepth 1 \
          -name '*.candidate.md' -type f 2>/dev/null | sort)
      fi
    fi
	    if [[ "${#cands[@]}" -eq 0 ]]; then
	      if [[ -f "$stage_dir/NO-TASKS" ]]; then
	        # Valid empty batch (0.5.0): release the node lease, no rejection.
	        rm -f "$(singular_l1_lease_path "$node")" 2>/dev/null || true
	        singular_append_event "origin.l1_no_tasks" "planner returned a valid empty batch; node lease released" "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
	        echo "no-tasks:$node"
	        continue
	      fi
	      import_rejections=$((import_rejections + 1))
	      singular_l1_lease_set_status "$node" failed 2>/dev/null || true
	      singular_append_event "origin.l1_import_rejected" "no staged candidates" "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
	      continue
    fi
	    if [[ "$max_candidates" -ge 0 \
	        && $((imported_candidates + ${#cands[@]})) -gt "$max_candidates" ]]; then
	      import_rejections=$((import_rejections + 1))
	      singular_l1_lease_set_status "$node" failed 2>/dev/null || true
	      singular_append_event "origin.l1_import_rejected" \
	        "staged candidate batch exceeds remaining dispatch capacity" \
	        "{\"runId\":\"$run_id\",\"node\":\"$node\",\"candidates\":${#cands[@]},\"alreadyImported\":$imported_candidates,\"maxCandidates\":$max_candidates}"
	      echo "candidate-budget-exceeded node=$node candidates=${#cands[@]} remaining=$((max_candidates - imported_candidates))"
	      continue
	    fi
	    node_area="$(singular_l1_lease_field "$node" area 2>/dev/null || true)"
	    if [[ -z "$node_area" ]]; then
      # Fail closed: a missing/unreadable lease means the node was never validly
      # planned (l1-plan-node writes the lease before planning). Import nothing.
	      import_rejections=$((import_rejections + 1))
	      singular_l1_lease_set_status "$node" failed 2>/dev/null || true
	      singular_append_event "origin.l1_import_rejected" "missing or unreadable l1 lease at import" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
      continue
    fi
    # Validate the whole batch first (all-or-nothing); real ids come from the
    # durable monotonic allocator AFTER validation succeeds (so a rejected
    # batch never burns ids).
	    local ok=1 real v_id v_status v_area v_owned v_mode
	    local duplicate_json="" duplicate_event_json=""
	    local -a src=() ids=() temps=()
    for cand in "${cands[@]}"; do
      v_id="$(singular_task_field "$cand" taskId 2>/dev/null || echo '')"
      v_status="$(singular_task_field "$cand" status 2>/dev/null || echo '')"
      v_area="$(singular_task_field "$cand" area 2>/dev/null || echo '')"
      v_owned="$(singular_task_field "$cand" ownedFiles 2>/dev/null || echo '[]')"
      v_mode="$(singular_task_field "$cand" dispatchMode 2>/dev/null || echo '')"
	      if [[ -z "$v_id" || "$v_status" != "ready" || "$v_area" != "$node_area" || "$v_owned" == "[]" || "$v_mode" != "canonical" ]]; then
	        ok=0; break
	      fi
	      if duplicate_json="$(singular_find_duplicate_task_signature "$cand" "$node" 2>/dev/null)"; then
	        ok=2; break
	      fi
	      src+=("$cand"); temps+=("$v_id")
	    done
	    if [[ "$ok" -eq 1 ]]; then
	      while IFS= read -r real; do
	        [[ -n "$real" ]] && ids+=("$real")
	      done < <(singular_task_id_next "${#src[@]}")
	      [[ ${#ids[@]} -eq ${#src[@]} ]] || ok=0
	    fi
	    if [[ "$ok" -eq 2 ]]; then
	      import_rejections=$((import_rejections + 1))
	      singular_l1_lease_set_status "$node" failed 2>/dev/null || true
	      duplicate_event_json="$(singular_duplicate_candidate_event_json "$run_id" "$node" "$duplicate_json")"
	      singular_append_event "origin.l1_import_rejected" "duplicate-candidate" "$duplicate_event_json"
	      echo "duplicate-candidate node=$node existing=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("existingTaskId",""))' "$duplicate_json")"
	      continue
	    fi
	    if [[ "$ok" -ne 1 ]]; then
	      import_rejections=$((import_rejections + 1))
	      singular_l1_lease_set_status "$node" failed 2>/dev/null || true
      singular_append_event "origin.l1_import_rejected" "staged batch failed validation" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
      continue
    fi
    # Rewrite each candidate's temp id (token-safe) to its real id and VERIFY the
    # result, all BEFORE promoting any file — so a botched rewrite fails the whole
    # node with nothing left in the global tasks dir (all-or-nothing).
    local j rid mv_ok=1
    local -a moved=()
    for j in "${!src[@]}"; do
      singular_rewrite_task_id_token "${src[$j]}" "${temps[$j]}" "${ids[$j]}" || { ok=0; break; }
      if [[ "$(singular_task_field "${src[$j]}" taskId 2>/dev/null || echo '')" != "${ids[$j]}" ]]; then
        ok=0; break
      fi
    done
	    if [[ "$ok" -ne 1 ]]; then
	      import_rejections=$((import_rejections + 1))
	      singular_l1_lease_set_status "$node" failed 2>/dev/null || true
      singular_append_event "origin.l1_import_rejected" "id rewrite verification failed" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
      continue
    fi
    # Promote all-or-nothing: guard every mv so a failure mid-batch (e.g. ENOSPC)
    # never aborts the whole import under `set -e`; on failure, roll back the files
    # already promoted so a partial batch never lands in the global tasks dir, mark
    # the node failed, and move on to the next node.
    for j in "${!src[@]}"; do
      # Collision preflight: never overwrite an existing task file. With the
      # monotonic allocator this cannot happen; if it does (foreign file, clock
      # rollback), reject the batch loudly instead of destroying state.
      if [[ -e "$SINGULAR_TASKS_DIR/${ids[$j]}.md" ]]; then
        singular_append_event "origin.task_id_collision" "refusing to overwrite existing task file" \
          "{\"runId\":\"$run_id\",\"node\":\"$node\",\"taskId\":\"${ids[$j]}\"}"
        mv_ok=0; break
      fi
      if mv "${src[$j]}" "$SINGULAR_TASKS_DIR/${ids[$j]}.md" 2>/dev/null; then
        moved+=("${ids[$j]}")
      else
        mv_ok=0; break
      fi
    done
	    if [[ "$mv_ok" -ne 1 ]]; then
	      import_rejections=$((import_rejections + 1))
	    for rid in "${moved[@]}"; do
        rm -f "$SINGULAR_TASKS_DIR/$rid.md" 2>/dev/null || true
      done
      singular_l1_lease_set_status "$node" failed 2>/dev/null || true
      singular_append_event "origin.l1_import_rejected" "promotion failed; rolled back partial batch" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
      continue
    fi
    for rid in "${moved[@]}"; do
      singular_append_event "planner.generated" "task imported from l1 plan" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\",\"taskId\":\"$rid\"}"
	      echo "generated:$rid"
	    done
	    imported_candidates=$((imported_candidates + ${#moved[@]}))
		    singular_l1_lease_set_status "$node" released 2>/dev/null || true
	  done
	  echo "l1_import_rejections=$import_rejections"
	}

# --- Context continuity (per-attempt archives, capsules, findings ledger) ----
# Everything in this section is ADDITIVE observability: a failure here must
# never abort a drive. Callers wrap these with `|| <warning event>` guards.

singular_sha256_file() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

singular_sha256_text() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "$1"
}

# Emit the shared credential patterns as `<label>\t<ERE>` lines, the contract
# every consumer already reads with `IFS=$'\t' read -r label regex`.
#
# The definition lives in engine/secret-patterns.tsv so the console's python
# redactor can consume the same list; it previously lived as a function body
# inside secret-scan.sh (a self-executing script lib.sh does not source), which
# forced l1-drive.sh to sed it out and eval it. Defining it here means every
# consumer that sources lib.sh gets it directly.
#
# Emits nothing and fails when the file is missing: callers treat an empty
# pattern set as an internal error rather than silently scanning for nothing.
singular_secret_scan_patterns() {
  local file="${SINGULAR_SECRET_PATTERNS_FILE:-$SINGULAR_ENGINE_DIR/secret-patterns.tsv}"
  [[ -f "$file" ]] || {
    echo "secret patterns file not found: $file" >&2
    return 2
  }
  local emitted=0 label regex
  while IFS="$(printf '\t')" read -r label regex; do
    [[ -z "$label" || "${label:0:1}" == "#" ]] && continue
    [[ -n "$regex" ]] || continue
    printf '%s\t%s\n' "$label" "$regex"
    emitted=$((emitted + 1))
  done <"$file"
  [[ "$emitted" -gt 0 ]] || {
    echo "secret patterns file defines no patterns: $file" >&2
    return 2
  }
  return 0
}

# --- Read-only working-tree guard ---------------------------------------------
# A read-only run must leave the working tree exactly as it found it. Two of the
# six runners can be told that by their CLI (codex takes an OS sandbox; the rest
# take tool denials that a shell command can walk around), so the engine takes a
# snapshot before the run and puts the tree back after.
#
# The snapshot is of content, not of paths — engine/readonly_guard.py explains at
# length why the path-diff version this replaces could not be made correct. The
# short version: a list of paths cannot describe a state you want to return to,
# so the old guard let an agent's overwrite of an already-dirty file survive,
# restored everything else from HEAD (discarding whatever uncommitted work was
# in it), missed staged mutations entirely, and deleted untracked files that
# appeared mid-run — which, since read-only runs execute against $SINGULAR_ROOT
# for up to 1200s while the rest of the engine keeps writing there, meant it
# deleted freshly imported task files.
#
# SINGULAR_READONLY_GUARD_MODE selects restore (default), report (log what it
# would do and change nothing) or off.
singular_readonly_guard_mode() {
  printf '%s\n' "${SINGULAR_READONLY_GUARD_MODE:-restore}"
}

# Express an absolute engine directory as a worktree-relative prefix, or print
# nothing when it lives outside the worktree and so cannot collide with it.
singular_readonly_guard_relative() {
  local worktree="$1" candidate="$2"
  [[ -n "$candidate" ]] || return 0
  python3 - "$worktree" "$candidate" <<'PY' 2>/dev/null || true
import os
import sys

worktree, candidate = (os.path.abspath(p) for p in sys.argv[1:3])
if candidate == worktree:
    raise SystemExit(0)
rel = os.path.relpath(candidate, worktree)
if rel.startswith(os.pardir + os.sep) or rel == os.pardir:
    raise SystemExit(0)
print(rel)
PY
}

# Snapshot $1 and print the journal directory the restore will need. Prints
# nothing (and succeeds) when the guard is off or cannot be armed — a guard that
# fails to start must never take the run down with it.
singular_readonly_guard_capture() {
  local worktree="$1" label="${2:-run}"
  [[ "$(singular_readonly_guard_mode)" != "off" ]] || return 0
  [[ -n "$worktree" && -d "$worktree" ]] || return 0

  local base="$SINGULAR_STATE_DIR/readonly-guard"
  mkdir -p "$base" 2>/dev/null || return 0
  local journal
  journal="$(mktemp -d "$base/${label}.XXXXXX" 2>/dev/null)" || return 0

  # The engine writes to these directories from other processes for the whole
  # duration of a read-only run. They are engine-owned state, not agent output —
  # read-only runs report through the packet, never by writing files — so the
  # guard stays out of them entirely rather than racing whoever else is there.
  local args=(capture --worktree "$worktree" --journal "$journal"
              --label "$label" --owner-pid "$$")
  local dir rel
  for dir in "$SINGULAR_ORCH_DIR" "$SINGULAR_STATE_DIR" \
             "$SINGULAR_ROOT/.singular-cache" "$SINGULAR_ROOT/.singular-evidence"; do
    rel="$(singular_readonly_guard_relative "$worktree" "$dir")"
    [[ -n "$rel" ]] && args+=(--exclude "$rel")
  done

  if ! python3 "$SINGULAR_LIB_DIR/readonly_guard.py" "${args[@]}" \
       >"$journal/capture.json" 2>"$journal/capture.err"; then
    echo "readonly guard: capture failed, run is unguarded (see $journal/capture.err)" >&2
    return 0
  fi
  printf '%s\n' "$journal"
}

# Put the worktree back. Safe to call with an empty journal argument, and safe to
# call twice — the second call finds no journal and reports no-journal.
singular_readonly_guard_restore() {
  local journal="${1:-}"
  [[ -n "$journal" && -d "$journal" ]] || return 0
  local mode result outcome
  mode="$(singular_readonly_guard_mode)"
  [[ "$mode" != "off" ]] || return 0
  [[ "$mode" == "report" ]] || mode="restore"

  result="$(python3 "$SINGULAR_LIB_DIR/readonly_guard.py" restore \
    --journal "$journal" --mode "$mode" --consume 2>"$journal/restore.err")" || {
    echo "readonly guard: restore failed (see $journal/restore.err)" >&2
    return 0
  }
  outcome="$(printf '%s' "$result" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("outcome",""))' 2>/dev/null || true)"
  case "$outcome" in
    restored|reported|degraded)
      # Worth an event on every one of these: a read-only run that changed the
      # tree is a containment failure whether or not the guard undid it, and a
      # degraded guard means the run was effectively unguarded.
      echo "readonly guard: $outcome ($journal)" >&2
      singular_append_event "readonly_guard.$outcome" \
        "read-only guard $outcome" "$result" || true
      ;;
  esac
  return 0
}

# Finish the restores of runs that were SIGKILLed. Nothing runs inside a killed
# process, so its journal is still on disk with its owner pid recorded; this is
# how that tree eventually gets put back.
singular_readonly_guard_sweep() {
  local base="$SINGULAR_STATE_DIR/readonly-guard"
  [[ -d "$base" ]] || return 0
  [[ "$(singular_readonly_guard_mode)" != "off" ]] || return 0
  python3 "$SINGULAR_LIB_DIR/readonly_guard.py" sweep --root "$base" \
    >/dev/null 2>&1 || true
  return 0
}

# A fingerprint of everything an attempt could have changed, plus how it failed.
# Two attempts with the same fingerprint did the same thing and got the same
# answer, so the next one will too.
#
# TASK-0006 spent attempts 2 through 6 at a byte-identical head SHA on an
# identical failure — 25 minutes of worker, gate and decider cycles on a rerun
# that could not have differed. `prev_failure_class` already existed but was only
# used to escalate the fast path to the model decider, never to stop.
#
# The head SHA alone is not enough. Most failure classes (scope-violation,
# packet-invalid, gate-red) happen BEFORE any commit, so head stays put whether
# or not the model did useful work — parking on that would kill tasks the next
# attempt would have fixed. The uncommitted diff is what tells those apart, so
# it is hashed too, along with the gate's structured signals when there are any.
singular_attempt_progress_signature() {
  local worktree="$1" failure_class="$2" head_sha="$3" gate_report="${4:-}"
  {
    printf '%s\n%s\n' "$failure_class" "$head_sha"
    git -C "$worktree" diff HEAD 2>/dev/null || true
    git -C "$worktree" ls-files --others --exclude-standard -z 2>/dev/null || true
    if [[ -n "$gate_report" && -f "$gate_report" ]]; then
      python3 - "$gate_report" <<'PY' 2>/dev/null || true
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(0)
for key in ("failureSignals", "infrastructureSignals"):
    value = data.get(key)
    if isinstance(value, list):
        for item in sorted(str(v) for v in value):
            print(f"{key}:{item}")
PY
    fi
  } | shasum -a 256 | awk '{print $1}'
}

# Express an artifact path as a repository-relative *reference*.
#
# dag.sh's safe_repo_artifact rejects an absolute ref before it checks anything
# else, so a gate report citing an absolute logRef could never back a
# deterministic-proof gate-result: the engine could not satisfy its own strict
# validator. The conversion belongs at the caller, not in the validator (which
# is a trust boundary and must keep refusing absolute paths) and not in
# gate_report.py (whose --log-ref / --log-path split is already the right seam:
# the ref is the citation, the path is what gets opened and hashed).
#
# Anchors on the RESOLVED root, matching safe_repo_artifact's
# `Path(repo_root).resolve()`. Resolving both sides also means an artifact
# reached through a symlinked parent is cited by its real location, which is
# what safe_repo_artifact's no-symlink-traversal rule wants.
#
# Prints the repo-relative form when the path lies inside the repo, and the
# input unchanged otherwise: SINGULAR_STATE_DIR may legitimately live outside the
# repo, and there the strict path is simply unsatisfiable — a configuration
# fact, not something to paper over with a fabricated ref.
singular_repo_relative_ref() {
  local path="$1" root="${2:-$SINGULAR_ROOT}"
  python3 - "$path" "$root" <<'PY'
import os
import sys

path, root = sys.argv[1], sys.argv[2]
if not path or not os.path.isabs(path):
    print(path)
    raise SystemExit(0)
try:
    real_root = os.path.realpath(root)
    real_path = os.path.realpath(path)
except OSError:
    print(path)
    raise SystemExit(0)
rel = os.path.relpath(real_path, real_root)
if os.path.isabs(rel) or rel == os.pardir or rel.startswith(os.pardir + os.sep):
    print(path)
else:
    print(rel)
PY
}

singular_tracked_source_snapshot() {
  local worktree="$1" output="$2"
  python3 - "$worktree" "$output" <<'PY'
import hashlib
import json
import os
import stat
import subprocess
import sys

root, output = sys.argv[1:3]
result = subprocess.run(
    [
        "git", "-C", root, "ls-files", "-z", "--cached", "--others",
        "--exclude-standard",
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if result.returncode:
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode)
snapshot = {}
excluded_roots = {".singular-state", ".singular-cache", ".singular-evidence", ".worktrees"}
for raw in result.stdout.split(b"\0"):
    if not raw:
        continue
    relative = os.fsdecode(raw)
    if relative.replace("\\", "/").split("/", 1)[0] in excluded_roots:
        continue
    path = os.path.join(root, relative)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        snapshot[relative] = {"missing": True}
        continue
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        payload = os.fsencode(os.readlink(path))
        kind = "symlink"
    elif stat.S_ISREG(info.st_mode):
        with open(path, "rb") as stream:
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        payload = None
        kind = "file"
    else:
        raise SystemExit(f"unsupported source object: {relative}")
    snapshot[relative] = {
        "kind": kind,
        "mode": mode,
        "device": info.st_dev,
        "inode": info.st_ino,
        "size": info.st_size,
        "mtimeNs": info.st_mtime_ns,
        "ctimeNs": info.st_ctime_ns,
        "sha256": (
            hashlib.sha256(payload).hexdigest()
            if payload is not None
            else digest.hexdigest()
        ),
    }
temporary = output + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, output)
PY
}

singular_tracked_source_changes() {
  local before="$1" after="$2"
  python3 - "$before" "$after" <<'PY'
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

singular_check_result_write() {
  local output="$1" check_id="$2" status="$3" exit_code="$4" log_ref="${5:-}"
  python3 - "$output" "$check_id" "$status" "$exit_code" "$log_ref" <<'PY'
import datetime
import hashlib
import json
import os
import sys
import tempfile

output, check_id, status, exit_raw, log_ref = sys.argv[1:6]
if status not in {"passed", "failed", "not-run", "inconclusive"}:
    raise SystemExit(2)
try:
    exit_code = int(exit_raw)
except ValueError:
    raise SystemExit(2)
record = {
    "schema": "singular.orchestration.check-result.v0",
    "check": check_id,
    "status": status,
    "exitCode": exit_code,
    "logRef": log_ref or None,
    "logSha256": None,
    "recordedAt": datetime.datetime.now(datetime.timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z"),
}
if log_ref and os.path.isfile(log_ref):
    record["logSha256"] = hashlib.sha256(open(log_ref, "rb").read()).hexdigest()
directory = os.path.dirname(output) or "."
os.makedirs(directory, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".check-result.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, output)
finally:
    try:
        os.unlink(temporary)
    except OSError:
        pass
PY
}

# --- Session affinity / runtime resume (T-E5) --------------------------------
# Runtime session reuse is a pure OPTIMIZATION: every gate or runtime failure
# degrades to a fresh run, never changing outcomes (only token cost). The runner
# writes a session-meta JSON describing the session it just ran; the host merges
# its authority fields and decides whether the NEXT run may resume it.
#
# session-meta schema (singular.orchestration.session-meta.v0):
#   provider, sessionId, model, effort, cwd, exitCode, createdAt   (runner-authored)
#   role, taskId, runId, runner, promptSha256, headShaAtCreate, lastUsedAttempt
#                                                                  (host-authored)

# Runner-side meta writers (called from codex-run.sh / claude-run.sh). They emit
# ONLY the runner-authored fields; the host adds the rest via _finalize. An empty
# sessionId is normal (parse miss / no session) and tells the host to go fresh.
singular_session_meta_write_provider() {
  local path="$1" provider="$2" session_id="$3" model="$4" effort="$5" cwd="$6" exit_code="$7"
  [[ -n "$path" ]] || return 0
  local created; created="$(singular_timestamp 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - "$path" "$provider" "$session_id" "$model" "$effort" "$cwd" "$exit_code" "$created" <<'PY' 2>/dev/null || true
import json, sys
path, provider, sid, model, effort, cwd, ec, created = sys.argv[1:9]
try:
    rc = int(ec)
except Exception:
    rc = ec
doc = {
    "schema": "singular.orchestration.session-meta.v0",
    "provider": provider,
    "sessionId": sid,
    "model": model,
    "effort": effort,
    "cwd": cwd,
    "exitCode": rc,
    "createdAt": created,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
}
singular_codex_session_meta_write() {
  # <path> <session_id> <model> <effort> <cwd> <exit_code>
  singular_session_meta_write_provider "$1" "codex" "$2" "$3" "$4" "$5" "$6"
}
singular_claude_session_meta_write() {
  # <path> <session_id> <model> <effort> <cwd> <exit_code>
  singular_session_meta_write_provider "$1" "claude" "$2" "$3" "$4" "$5" "$6"
}

# sha256 of the rendered BASE prompt (reuses singular_sha256_file). Missing file ->
# empty (the resume decider treats an empty/mismatched sha as a fresh trigger).
singular_prompt_sha() {
  local prompt_file="$1"
  [[ -n "$prompt_file" && -f "$prompt_file" ]] || { printf '%s' ""; return 0; }
  singular_sha256_file "$prompt_file" 2>/dev/null || printf '%s' ""
}

# Merge host-authority fields into the runner-written meta. If the runner wrote
# no meta (resume unsupported / parse miss), create a minimal one with an empty
# sessionId. NEVER fails the drive.
#   singular_session_meta_finalize <meta_path> <role> <task_id> <run_id> \
#                              <runner_basename> <prompt_sha> <head_sha> <attempt>
singular_session_meta_finalize() {
  local meta_path="$1" role="$2" task_id="$3" run_id="$4" runner="$5" prompt_sha="$6" head_sha="$7" attempt="$8"
  [[ -n "$meta_path" ]] || return 0
  python3 - "$meta_path" "$role" "$task_id" "$run_id" "$runner" "$prompt_sha" "$head_sha" "$attempt" <<'PY' 2>/dev/null || true
import json, sys
(path, role, task_id, run_id, runner, prompt_sha, head_sha, attempt) = sys.argv[1:9]
doc = {}
try:
    with open(path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        doc = loaded
except Exception:
    doc = {}
doc.setdefault("schema", "singular.orchestration.session-meta.v0")
doc.setdefault("provider", "")
doc.setdefault("sessionId", "")
doc.setdefault("model", "")
doc.setdefault("effort", "")
doc.setdefault("cwd", "")
doc.setdefault("exitCode", "")
doc.setdefault("createdAt", "")
doc["role"] = role
doc["taskId"] = task_id
doc["runId"] = run_id
doc["runner"] = runner
doc["promptSha256"] = prompt_sha
doc["headShaAtCreate"] = head_sha
try:
    doc["lastUsedAttempt"] = int(attempt)
except Exception:
    doc["lastUsedAttempt"] = attempt
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
}

# Decide whether the next run may resume the recorded session. Prints EXACTLY one
# line: `resume <sessionId>` or `fresh <reason>`. Gates evaluate in order; the
# FIRST failure wins and its name is the reason. Per-role meta FILES make
# cross-role reuse structurally impossible; gate 4 is defense-in-depth.
#   singular_session_resume_decide <meta_path> <role> <task_id> <run_id> \
#       <runner_basename> <prompt_sha> <worktree> <lineage_head>
singular_session_resume_decide() {
  local meta_path="$1" role="$2" task_id="$3" run_id="$4" runner="$5" prompt_sha="$6" worktree="$7" lineage_head="$8"

  # Gate 1: affinity disabled.
  if [[ "${SINGULAR_SESSION_AFFINITY:-1}" != "1" ]]; then
    printf 'fresh disabled\n'; return 0
  fi
  # Gate 2: meta missing/unparseable.
  if [[ ! -f "$meta_path" ]]; then
    printf 'fresh no-session\n'; return 0
  fi
  # Parse all fields in one python pass; emit each field on its OWN line (NUL is
  # awkward in bash 3.2; newline-per-field reads cleanly into an array even with
  # empty values, which a tab-delimited `read` collapses). A parse failure ->
  # "no-session". Each field's trailing newline is what delimits it; values here
  # are session ids / shas / paths and never contain newlines.
  local parsed
  parsed="$(python3 - "$meta_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        m = json.load(f)
    assert isinstance(m, dict)
except Exception:
    print("__UNPARSEABLE__")
    sys.exit(0)
def g(k):
    v = m.get(k, "")
    return "" if v is None else str(v).replace("\n", " ")
for val in (g("provider"), g("sessionId"), g("role"), g("taskId"), g("runId"),
            g("runner"), g("promptSha256"), g("createdAt"), g("headShaAtCreate"), g("cwd")):
    print(val)
PY
)"
  if [[ -z "$parsed" || "$parsed" == "__UNPARSEABLE__"* ]]; then
    printf 'fresh no-session\n'; return 0
  fi
  local m_fields=()
  while IFS= read -r line; do m_fields+=("$line"); done <<<"$parsed"
  local m_provider="${m_fields[0]:-}" m_sid="${m_fields[1]:-}" m_role="${m_fields[2]:-}"
  local m_task="${m_fields[3]:-}" m_run="${m_fields[4]:-}" m_runner="${m_fields[5]:-}"
  local m_psha="${m_fields[6]:-}" m_created="${m_fields[7]:-}" m_head="${m_fields[8]:-}" m_cwd="${m_fields[9]:-}"

  # Gate 3: provider or sessionId empty.
  if [[ -z "$m_provider" || -z "$m_sid" ]]; then
    printf 'fresh no-session-id\n'; return 0
  fi
  # Gate 4: role mismatch (defense-in-depth; per-role files should prevent this).
  if [[ "$m_role" != "$role" ]]; then
    printf 'fresh role-mismatch\n'; return 0
  fi
  # Gate 5: run mismatch (task or run).
  if [[ "$m_task" != "$task_id" || "$m_run" != "$run_id" ]]; then
    printf 'fresh run-mismatch\n'; return 0
  fi
  # Gate 6: runner changed.
  if [[ "$m_runner" != "$runner" ]]; then
    printf 'fresh runner-changed\n'; return 0
  fi
  # Gate 7: prompt template changed.
  if [[ "$m_psha" != "$prompt_sha" ]]; then
    printf 'fresh prompt-template-changed\n'; return 0
  fi
  # Gate 8: expired.
  local max_age="${SINGULAR_SESSION_MAX_AGE_SEC:-14400}"
  local age_ok
  age_ok="$(python3 - "$m_created" "$max_age" <<'PY' 2>/dev/null || true
import sys
from datetime import datetime, timezone
created, max_age = sys.argv[1], sys.argv[2]
try:
    max_age = int(max_age)
except Exception:
    max_age = 14400
if not created:
    print("EXPIRED"); sys.exit(0)
s = created.strip().replace("Z", "+00:00")
try:
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
except Exception:
    print("EXPIRED"); sys.exit(0)
age = (datetime.now(timezone.utc) - dt).total_seconds()
print("OK" if age <= max_age else "EXPIRED")
PY
)"
  if [[ "$age_ok" != "OK" ]]; then
    printf 'fresh expired\n'; return 0
  fi
  # Gate 9: lineage. If headShaAtCreate is empty we have nothing to test against —
  # allow (skip lineage); a non-empty head must be an ancestor of lineage_head.
  if [[ -n "$m_head" && -n "$lineage_head" ]]; then
    if ! git -C "$worktree" merge-base --is-ancestor "$m_head" "$lineage_head" 2>/dev/null; then
      printf 'fresh head-rewritten\n'; return 0
    fi
  fi
  # Gate 10: worktree moved.
  if [[ "$m_cwd" != "$worktree" ]]; then
    printf 'fresh worktree-moved\n'; return 0
  fi

  printf 'resume %s\n' "$m_sid"
}

# Stable finding identity: "f-" + first 12 hex chars of sha256 over the
# normalized text (backticks stripped, lowercased, whitespace collapsed to
# single spaces, trimmed) — so re-reports that differ only in formatting map to
# the same finding.
singular_finding_id() {
  python3 -c '
import hashlib, sys
text = sys.argv[1].replace("`", "").lower()
text = " ".join(text.split())
print("f-" + hashlib.sha256(text.encode("utf-8")).hexdigest()[:12])
' "$1"
}

# Per-attempt artifact archive (T-E1). Copies the attempt's mutable run-dir ROOT
# artifacts into <run_dir>/attempts/<n>/ (root files are never moved/renamed;
# the console keeps parsing them at the root) and upserts attempts/index.json.
#   singular_attempt_archive <run_dir> <n> <failure_class> <verdict> <head_sha> <decider_action> <authority>
# failure_class empty == accepted attempt (failure.txt records "accepted").
# Optional caller-provided globals: SINGULAR_ATTEMPT_TASK_ID (else packet.json's
# taskId), SINGULAR_ATTEMPT_STARTED_AT (else archive time).
singular_attempt_archive() {
  local run_dir="$1" n="$2" failure_class="$3" verdict="$4" head_sha="$5"
  local decider_action="$6" authority="$7"
  local dest="$run_dir/attempts/$n"
  mkdir -p "$dest"
  local f
  for f in l2-active-prompt.md auditor-active-prompt.md last-message.json packet.json worker-codex.log auditor-codex.log \
           scope-check.log gate-check.json gate-check.log secret-scan.log audit.json; do
    if [[ -f "$run_dir/$f" ]]; then cp "$run_dir/$f" "$dest/$f"; fi
  done
  for f in "$run_dir"/decision-*.json; do
    if [[ -f "$f" ]]; then cp "$f" "$dest/"; fi
  done
  for f in "$run_dir"/worker-attempt-"$n"-try-*.log \
           "$run_dir"/*-attempt-"$n"-try-*runner-result.json \
           "$run_dir"/*-attempt-"$n"-try-*.provider-envelope.raw; do
    if [[ -f "$f" ]]; then cp "$f" "$dest/"; fi
  done
  printf '%s\n' "${failure_class:-accepted}" >"$dest/failure.txt"

  local run_id task_id started ended
  run_id="$(basename "$run_dir")"
  ended="$(singular_timestamp)"
  started="${SINGULAR_ATTEMPT_STARTED_AT:-$ended}"
  task_id="${SINGULAR_ATTEMPT_TASK_ID:-}"
  if [[ -z "$task_id" && -f "$run_dir/packet.json" ]]; then
    task_id="$(singular_json_field "$run_dir/packet.json" taskId 2>/dev/null || true)"
  fi
  python3 - "$run_dir/attempts/index.json" "$run_id" "$task_id" "$n" "$started" "$ended" \
    "$failure_class" "$verdict" "$head_sha" "$decider_action" "$authority" \
    "${SINGULAR_ATTEMPT_WORKER_STRATEGY:-}" "${SINGULAR_ATTEMPT_REVIEWER_STRATEGY:-}" <<'PY'
import json
import os
import sys

(path, run_id, task_id, n_raw, started, ended,
 failure_class, verdict, head_sha, decider_action, authority,
 worker_strategy, reviewer_strategy) = sys.argv[1:14]
n = int(n_raw)
data = {
    "schema": "singular.orchestration.attempts-index.v0",
    "runId": run_id,
    "taskId": task_id,
    "attempts": [],
    "updatedAt": ended,
}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            prev = json.load(f)
        if isinstance(prev.get("attempts"), list):
            data["attempts"] = [a for a in prev["attempts"] if isinstance(a, dict)]
        if not task_id:
            data["taskId"] = str(prev.get("taskId", ""))
    except Exception:
        pass
entry = {
    "n": n,
    "startedAt": started,
    "endedAt": ended,
    "failureClass": failure_class,
    "auditVerdict": verdict,
    "headSha": head_sha,
    "deciderAction": decider_action,
    "deciderAuthority": authority,
    "dir": f"attempts/{n}",
}
# Session-affinity strategy (T-E5): ADDITIVE index fields. Only emitted when the
# driver provided a strategy, so the existing index schema/shape is unchanged for
# any caller that doesn't set them.
if worker_strategy:
    entry["workerStrategy"] = worker_strategy
if reviewer_strategy:
    entry["reviewerStrategy"] = reviewer_strategy
attempts = [a for a in data["attempts"] if a.get("n") != n]
attempts.append(entry)
attempts.sort(key=lambda a: a.get("n", 0))
data["attempts"] = attempts
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  singular_append_event "l1.attempt_archived" "attempt artifacts archived" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"n\":$n,\"failureClass\":\"$failure_class\",\"verdict\":\"$verdict\"}" \
    2>/dev/null || true
}

# Implementer context capsule: a compact, hash-stamped summary of what the
# worker attempt produced, for later-wave session resume / fix prompts.
#   singular_capsule_write_implementer <run_dir> <n> <packet_json_path> <head_sha> <owned_json> <forbidden_json>
# ownedFiles/forbiddenFiles come from the ARGV (the driver's CURRENT post-amend
# scope), never from the packet. Every list is capped at 20 items. contentHash
# is sha256 over the canonical JSON (sorted keys, no whitespace) EXCLUDING
# createdAt/contentHash/packetSha256.
singular_capsule_write_implementer() {
  local run_dir="$1" n="$2" packet_path="$3" head_sha="$4" owned_json="$5" forbidden_json="$6"
  python3 - "$run_dir" "$n" "$packet_path" "$head_sha" "$owned_json" "$forbidden_json" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone

run_dir, n_raw, packet_path, head_sha, owned_raw, forbidden_raw = sys.argv[1:7]

def parse_list(raw):
    try:
        value = json.loads(raw)
        return value if isinstance(value, list) else []
    except Exception:
        return []

try:
    with open(packet_path, "r", encoding="utf-8") as f:
        packet = json.load(f)
    if not isinstance(packet, dict):
        packet = {}
except Exception:
    packet = {}

def plist(key):
    value = packet.get(key)
    return value if isinstance(value, list) else []

def cap(items):
    return items[:20]

with open(packet_path, "rb") as f:
    packet_sha = hashlib.sha256(f.read()).hexdigest()

capsule = {
    "schema": "singular.orchestration.context-capsule.v0",
    "role": "implementer",
    "taskId": str(packet.get("taskId", "")),
    "runId": str(packet.get("runId", "")),
    "attempt": int(n_raw),
    "headSha": head_sha,
    "baseRef": str(packet.get("baseRef", "")),
    "branch": str(packet.get("branch", "")),
    "ownedFiles": cap(parse_list(owned_raw)),
    "forbiddenFiles": cap(parse_list(forbidden_raw)),
    "changedFiles": cap(plist("changedFiles")),
    "commands": cap(plist("commands")),
    "tests": cap(plist("tests")),
    "blockers": cap(plist("blockers")),
    "nextAction": str(packet.get("nextAction", "")),
    "packetSha256": packet_sha,
}
hashable = {k: v for k, v in capsule.items() if k not in ("createdAt", "contentHash", "packetSha256")}
canonical = json.dumps(hashable, sort_keys=True, separators=(",", ":"))
capsule["contentHash"] = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
capsule["createdAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
with open(f"{run_dir}/implementer-capsule.json", "w", encoding="utf-8") as f:
    json.dump(capsule, f, indent=2)
    f.write("\n")
PY
}

# Reviewer context capsule: what the auditor reviewed and concluded.
#   singular_capsule_write_reviewer <run_dir> <n> <audit_json_path> <prior_head> <new_head>
# diffRange is "" on attempt 1 (empty prior_head). Tolerates junk/partial
# verdict JSON (auditors emit junk) — missing/odd fields degrade to empty
# values, never a crash. rationale is capped at 1500 chars.
singular_capsule_write_reviewer() {
  local run_dir="$1" n="$2" audit_path="$3" prior_head="$4" new_head="$5"
  python3 - "$run_dir" "$n" "$audit_path" "$prior_head" "$new_head" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone

run_dir, n_raw, audit_path, prior_head, new_head = sys.argv[1:6]

try:
    with open(audit_path, "r", encoding="utf-8") as f:
        audit = json.load(f)
    if not isinstance(audit, dict):
        audit = {}
except Exception:
    audit = {}

def alist(key):
    value = audit.get(key)
    if not isinstance(value, list):
        return []
    return [str(item) for item in value]

def finding_id(text):
    norm = " ".join(str(text).replace("`", "").lower().split())
    return "f-" + hashlib.sha256(norm.encode("utf-8")).hexdigest()[:12]

finding_ids = []
for text in alist("findings") + alist("requiredFixes"):
    fid = finding_id(text)
    if fid not in finding_ids:
        finding_ids.append(fid)

try:
    with open(audit_path, "rb") as f:
        audit_sha = hashlib.sha256(f.read()).hexdigest()
except Exception:
    audit_sha = ""

task_id = str(audit.get("taskId", "") or "")
run_id = str(audit.get("runId", "") or "")
if not task_id or not run_id:
    try:
        with open(f"{run_dir}/packet.json", "r", encoding="utf-8") as f:
            packet = json.load(f)
        task_id = task_id or str(packet.get("taskId", ""))
        run_id = run_id or str(packet.get("runId", ""))
    except Exception:
        pass

capsule = {
    "schema": "singular.orchestration.context-capsule.v0",
    "role": "reviewer",
    "taskId": task_id,
    "runId": run_id,
    "attempt": int(n_raw),
    "verdict": str(audit.get("verdict", "") or ""),
    "auditedHeadSha": new_head,
    "diffRange": f"{prior_head}..{new_head}" if prior_head else "",
    "findingIds": finding_ids,
    "evidenceReviewed": alist("evidenceReviewed"),
    "commandsRun": alist("commandsRun"),
    "rationale": str(audit.get("rationale", "") or "")[:1500],
    "auditSha256": audit_sha,
    "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
with open(f"{run_dir}/reviewer-capsule.json", "w", encoding="utf-8") as f:
    json.dump(capsule, f, indent=2)
    f.write("\n")
PY
}

# Findings ledger: upsert <run_dir>/findings-status.json from one audit verdict.
#   singular_findings_ledger_update <run_dir> <n> <audit_json_path>
# Rules, in order:
#   1. every findings[]/requiredFixes[] string in the new audit is upserted by
#      id (lastSeenAttempt bumped); a previously RESOLVED finding that is
#      re-reported is REOPENED (resolvedAttempt/resolvedBy cleared);
#   2. a verdict findingsStatus object ({id: "resolved"|"still-open"}) is
#      applied: resolved -> status=resolved, resolvedAttempt=n,
#      resolvedBy="auditor-status";
#   3. verdict "accepted" resolves ALL open findings (resolvedBy
#      "audit-accepted");
#   4. absence alone never resolves anything.
# Echoes "open=K resolved=K new=K" on stdout; the caller emits the
# findings.ledger_updated event from those counts.
singular_findings_ledger_update() {
  local run_dir="$1" n="$2" audit_path="$3"
  python3 - "$run_dir" "$n" "$audit_path" <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

run_dir, n_raw, audit_path = sys.argv[1:4]
n = int(n_raw)
ledger_path = os.path.join(run_dir, "findings-status.json")

try:
    with open(audit_path, "r", encoding="utf-8") as f:
        audit = json.load(f)
    if not isinstance(audit, dict):
        audit = {}
except Exception:
    audit = {}

def alist(key):
    value = audit.get(key)
    if not isinstance(value, list):
        return []
    return [str(item) for item in value]

def finding_id(text):
    norm = " ".join(str(text).replace("`", "").lower().split())
    return "f-" + hashlib.sha256(norm.encode("utf-8")).hexdigest()[:12]

ledger = {}
if os.path.exists(ledger_path):
    try:
        with open(ledger_path, "r", encoding="utf-8") as f:
            ledger = json.load(f)
        if not isinstance(ledger, dict):
            ledger = {}
    except Exception:
        ledger = {}

task_id = str(audit.get("taskId", "") or ledger.get("taskId", "") or "")
run_id = str(audit.get("runId", "") or ledger.get("runId", "") or os.path.basename(run_dir.rstrip("/")))
findings = [f for f in ledger.get("findings", []) if isinstance(f, dict)] if isinstance(ledger.get("findings"), list) else []
by_id = {f.get("id"): f for f in findings if f.get("id")}

new_count = 0
# Rule 1: upsert every reported finding/requiredFix; reopen if resolved.
for source, key in (("finding", "findings"), ("requiredFix", "requiredFixes")):
    for text in alist(key):
        fid = finding_id(text)
        entry = by_id.get(fid)
        if entry is None:
            entry = {
                "id": fid,
                "text": str(text),
                "source": source,
                "status": "open",
                "firstSeenAttempt": n,
                "lastSeenAttempt": n,
                "resolvedAttempt": None,
                "resolvedBy": None,
            }
            findings.append(entry)
            by_id[fid] = entry
            new_count += 1
        else:
            entry["lastSeenAttempt"] = n
            if entry.get("status") == "resolved":
                entry["status"] = "open"
                entry["resolvedAttempt"] = None
                entry["resolvedBy"] = None

# Rule 2: explicit auditor findingsStatus map.
status_map = audit.get("findingsStatus")
if isinstance(status_map, dict):
    for fid, state in status_map.items():
        entry = by_id.get(str(fid))
        if entry is None:
            continue
        if str(state) == "resolved":
            entry["status"] = "resolved"
            entry["resolvedAttempt"] = n
            entry["resolvedBy"] = "auditor-status"

# Rule 3: an accepted verdict resolves everything still open.
if str(audit.get("verdict", "")) == "accepted":
    for entry in findings:
        if entry.get("status") == "open":
            entry["status"] = "resolved"
            entry["resolvedAttempt"] = n
            entry["resolvedBy"] = "audit-accepted"

now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
out = {
    "schema": "singular.orchestration.findings-ledger.v0",
    "taskId": task_id,
    "runId": run_id,
    "findings": findings,
    "updatedAt": now,
}
with open(ledger_path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
open_count = sum(1 for f in findings if f.get("status") == "open")
resolved_count = sum(1 for f in findings if f.get("status") == "resolved")
print(f"open={open_count} resolved={resolved_count} new={new_count}")
PY
}

# Structured fix prompt (T-E3). Renders <base_prompt> + appended retry sections
# (scope / authoritative findings / class-scoped evidence / LOW-authority prior
# summary) into <out_path>. Findings come ONLY from open ledger entries; if the
# ledger is missing/empty AND failure_class starts with "audit-", the legacy
# attempt_ctx tail is folded into the Evidence section as a fallback.
#   singular_render_fix_prompt <out> <base_prompt> <run_dir> <n> <failure_class> \
#     <attempt_ctx_file> <owned_json> <forbidden_json>
# Returns nonzero on any rendering error (caller falls back to legacy fix_hints).
singular_render_fix_prompt() {
  local out_path="$1" base_prompt="$2" run_dir="$3" n="$4" failure_class="$5"
  local attempt_ctx="$6" owned_json="$7" forbidden_json="$8"
  local gate_log="$run_dir/gate-check.log"
  local scope_log="$run_dir/scope-check.log"
  local capsule="$run_dir/implementer-capsule.json"
  local ledger="$run_dir/findings-status.json"
  python3 - "$out_path" "$base_prompt" "$ledger" "$capsule" "$n" "$failure_class" \
    "$attempt_ctx" "$gate_log" "$scope_log" "$owned_json" "$forbidden_json" \
    "$SINGULAR_CONTEXT_SECTION_MAX_CHARS" <<'PY'
import json
import os
import sys

(out_path, base_prompt, ledger_path, capsule_path, n_raw, failure_class,
 attempt_ctx, gate_log, scope_log, owned_raw, forbidden_raw, cap_raw) = sys.argv[1:13]
n = int(n_raw)
cap = int(cap_raw)
prev = n - 1
TRUNC = "\n[... section truncated to fit the context budget ...]"

def section_cap(text):
    if len(text) <= cap:
        return text
    keep = max(0, cap - len(TRUNC))
    return text[:keep] + TRUNC

def parse_list(raw):
    try:
        v = json.loads(raw)
        return [str(x) for x in v] if isinstance(v, list) else []
    except Exception:
        return []

def tail_chars(path, nbytes):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()[-nbytes:]
    except Exception:
        return ""

def tail_lines(path, count):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        return "\n".join(lines[-count:])
    except Exception:
        return ""

def scope_disallowed_block(path):
    # Extract the "disallowed paths:" block emitted by scope-check.sh, up to the
    # next "allowed prefixes:"/"forbidden prefixes:" header (forbidden-paths
    # block included when present).
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except Exception:
        return ""
    out, capture = [], False
    for line in lines:
        s = line.strip()
        if s.startswith("scope check failed; forbidden paths touched:") or \
           s.startswith("scope check failed; disallowed paths:"):
            capture = True
            out.append(line)
            continue
        if capture:
            if s.startswith("allowed prefixes:") or s.startswith("forbidden prefixes:"):
                break
            out.append(line)
    return "\n".join(out).strip()

with open(base_prompt, "r", encoding="utf-8") as f:
    base = f.read()

# --- Open findings from the ledger -------------------------------------------
open_findings = []
ledger_present = False
try:
    with open(ledger_path, "r", encoding="utf-8") as f:
        ledger = json.load(f)
    if isinstance(ledger, dict) and isinstance(ledger.get("findings"), list):
        ledger_present = True
        for entry in ledger["findings"]:
            if isinstance(entry, dict) and entry.get("status") == "open":
                open_findings.append(entry)
except Exception:
    ledger_present = False
open_findings.sort(key=lambda e: (e.get("firstSeenAttempt") or 0, str(e.get("id"))))

owned = parse_list(owned_raw)
forbidden = parse_list(forbidden_raw)

parts = []
parts.append(base.rstrip("\n"))
parts.append("")
parts.append(f"## Previous-attempt feedback (attempt {prev} failed: {failure_class})")
parts.append("")
parts.append("### Current scope (authoritative — supersedes the scope listed above if different)")
parts.append("Owned: " + (", ".join(owned) if owned else "(none)"))
parts.append("Forbidden: " + (", ".join(forbidden) if forbidden else "(none)"))
parts.append("")

# --- Authoritative findings ---------------------------------------------------
parts.append("### Authoritative findings — fix ALL of these (open items from the findings ledger)")
if open_findings:
    lines = []
    for e in open_findings:
        text = str(e.get("text", ""))[:500]
        lines.append(f"- [from attempt {e.get('firstSeenAttempt')}] ({e.get('id')}) {text}")
    parts.append(section_cap("\n".join(lines)))
else:
    parts.append("(no open ledger findings recorded)")
parts.append("")

# --- Evidence (class-scoped) --------------------------------------------------
parts.append("### Evidence (host logs, informational)")
if failure_class == "gate-red":
    evidence = tail_lines(gate_log, 40)
elif failure_class == "scope-violation":
    evidence = scope_disallowed_block(scope_log)
elif failure_class == "packet-invalid":
    evidence = tail_lines(attempt_ctx, 40)
else:
    evidence = tail_lines(attempt_ctx, 30)
# Fallback: empty/missing ledger AND an audit-* failure -> fold in the ctx tail.
if (not ledger_present or not open_findings) and failure_class.startswith("audit-"):
    legacy = tail_chars(attempt_ctx, 3000)
    if legacy:
        evidence = (evidence + "\n" + legacy) if evidence else legacy
parts.append(section_cap(evidence) if evidence else "(no evidence captured)")
parts.append("")

# --- Prior implementer summary (LOW authority) -------------------------------
capsule = None
try:
    with open(capsule_path, "r", encoding="utf-8") as f:
        c = json.load(f)
    if isinstance(c, dict):
        capsule = c
except Exception:
    capsule = None
if capsule is not None:
    parts.append("### Prior implementer summary (LOW authority — may be stale or wrong; trust the findings and the code)")
    parts.append("nextAction: " + str(capsule.get("nextAction", "")))
    blockers = capsule.get("blockers") if isinstance(capsule.get("blockers"), list) else []
    parts.append("blockers: " + (", ".join(str(b) for b in blockers[:5]) if blockers else "(none)"))
    changed = capsule.get("changedFiles") if isinstance(capsule.get("changedFiles"), list) else []
    parts.append("changedFiles: " + (", ".join(str(x) for x in changed[:20]) if changed else "(none)"))
    parts.append("")

parts.append("Address every Authoritative finding; do not relitigate resolved ones; stay in scope.")

with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(parts) + "\n")
PY
}

# Re-audit delta prompt (T-E4). Renders <base_audit_prompt> + re-audit context
# (prior findings/ledger status + fix diff since the auditor's last review +
# per-id verification targets + a findingsStatus output-contract addition) into
# <out_path>. n==1, missing reviewer capsule, or empty prior_head -> plain copy
# (byte-identical to the base audit prompt).
#   singular_render_reaudit_prompt <out> <base_audit_prompt> <run_dir> <n> \
#     <prior_head> <new_head> <worktree>
# Returns nonzero on rendering error (caller falls back to the base audit prompt).
singular_render_reaudit_prompt() {
  local out_path="$1" base_prompt="$2" run_dir="$3" n="$4" prior_head="$5"
  local new_head="$6" worktree="$7"
  local capsule="$run_dir/reviewer-capsule.json"
  local ledger="$run_dir/findings-status.json"
  if [[ "$n" -lt 2 || ! -f "$capsule" || -z "$prior_head" ]]; then
    cp "$base_prompt" "$out_path"
    return 0
  fi

  # Diff only when prior_head is a genuine ancestor of new_head; otherwise history
  # was rewritten (amend/rebase) and a range diff would be meaningless.
  local ancestry_ok="no" stat_out=""
  local diff_ref="reaudit-diff-attempt-${n}.patch"
  local diff_artifact="$run_dir/$diff_ref"
  if git -C "$worktree" merge-base --is-ancestor "$prior_head" "$new_head" 2>/dev/null; then
    ancestry_ok="yes"
    stat_out="$(git -C "$worktree" diff --stat "$prior_head..$new_head" 2>/dev/null || true)"
    git -C "$worktree" diff --binary "$prior_head..$new_head" \
      >"$diff_artifact" 2>/dev/null || return 1
  else
    rm -f "$diff_artifact" 2>/dev/null || true
  fi

  SINGULAR_REAUDIT_STAT="$stat_out" \
  python3 - "$out_path" "$base_prompt" "$ledger" "$n" "$prior_head" "$new_head" \
    "$ancestry_ok" "$diff_ref" <<'PY'
import json
import os
import sys

(out_path, base_prompt, ledger_path, n_raw, prior_head, new_head,
 ancestry_ok, diff_ref) = sys.argv[1:9]

with open(base_prompt, "r", encoding="utf-8") as f:
    base = f.read()

findings = []
try:
    with open(ledger_path, "r", encoding="utf-8") as f:
        ledger = json.load(f)
    if isinstance(ledger, dict) and isinstance(ledger.get("findings"), list):
        findings = [e for e in ledger["findings"] if isinstance(e, dict)]
except Exception:
    findings = []
# Open first, then resolved; stable by id within each group.
findings.sort(key=lambda e: (0 if e.get("status") == "open" else 1, str(e.get("id"))))
open_findings = [e for e in findings if e.get("status") == "open"]

parts = [base.rstrip("\n"), ""]
parts.append(f"## Re-audit context (attempt {n_raw}; you previously audited {prior_head})")
parts.append("")
parts.append("### Your prior findings and current ledger status (authoritative)")
if findings:
    for e in findings:
        state = "open" if e.get("status") == "open" else "resolved"
        parts.append(f"- ({e.get('id')}) [{state}] {str(e.get('text', ''))}")
else:
    parts.append("(no ledger findings recorded)")

if ancestry_ok == "yes":
    stat = os.environ.get("SINGULAR_REAUDIT_STAT", "")[:2048]
    parts.append(f"### Fix diff since your last audit ({prior_head}..{new_head})")
    parts.append(stat)
    parts.append(
        f"The raw delta is artifact `{diff_ref}` in the evidence manifest. "
        "Its bytes are intentionally not embedded in this prompt; retrieve only "
        "the bounded portion needed for a named finding through evidence-show.sh."
    )
else:
    parts.append(
        f"History was rewritten since your last audit ({prior_head} is not an "
        f"ancestor of {new_head}); perform a full review of the current branch state."
    )

parts.append("### Verification targets")
parts.append("Verify each of these open finding ids is resolved by this diff; report per-id status:")
if open_findings:
    for e in open_findings:
        parts.append(f"- {e.get('id')}: {str(e.get('text', ''))[:200]}")
else:
    parts.append("(no open findings to verify)")

parts.append("### Output contract addition")
parts.append(
    'In addition to the audit-verdict fields, include an optional field '
    '"findingsStatus": an object mapping finding id -> "resolved" | "still-open" '
    "for every verification target above."
)

with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(parts) + "\n")
PY
}

# --- Kill switch + circuit breaker ---

singular_stop_requested() {
  [[ -f "$SINGULAR_STOP_FILE" ]]
}

singular_wake_file() {
  printf '%s' "${SINGULAR_WAKE_FILE:-$SINGULAR_STATE_DIR/WAKE}"
}

# Interruptible nap: sleeps `total` seconds in SINGULAR_SLEEP_POLL_SEC chunks,
# checking control files between chunks so a nap never outlives operator intent.
# Returns: 0 = slept the full duration; 1 = woken early (WAKE file consumed, or
# — with watch_backoff=1 — the planner backoff was cleared/expired); 2 = STOP.
# Never signal/kill sleep children to wake the loop: touch the WAKE file
# (singular wake) instead.
singular_interruptible_sleep() {
  local total="$1" watch_backoff="${2:-0}"
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  local poll="${SINGULAR_SLEEP_POLL_SEC:-10}"
  [[ "$poll" =~ ^[0-9]+$ && "$poll" -ge 1 ]] || poll=10
  local wake slept=0 chunk
  wake="$(singular_wake_file)"

  # A completion/refill event may arrive between the cycle's last state read
  # and this nap.  Checking only after the first chunk imposed one full poll
  # interval (10s by default) on an already-pending wake and defeated the
  # work-conserving scheduler's immediate refill contract.
  if singular_stop_requested; then
    return 2
  fi
  if [[ -f "$wake" ]]; then
    rm -f "$wake" 2>/dev/null || true
    return 1
  fi
  if [[ "$watch_backoff" == "1" ]] && ! singular_planner_backoff_active_json >/dev/null 2>&1; then
    return 1
  fi

  while (( slept < total )); do
    chunk=$(( total - slept < poll ? total - slept : poll ))
    sleep "$chunk"
    slept=$((slept + chunk))
    if singular_stop_requested; then
      return 2
    fi
    if [[ -f "$wake" ]]; then
      rm -f "$wake" 2>/dev/null || true
      return 1
    fi
    if [[ "$watch_backoff" == "1" ]] && ! singular_planner_backoff_active_json >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

singular_request_wake() {
  singular_ensure_state_dirs
  local wake
  wake="$(singular_wake_file)"
  : >"$wake"
  singular_append_event "autonomate.wake_requested" "operator requested wake" "{}"
  echo "wake requested ($wake)"
}

singular_breaker_count() {
  [[ -f "$SINGULAR_BREAKER_FILE" ]] || { echo 0; return 0; }
  singular_json_field "$SINGULAR_BREAKER_FILE" consecFails 2>/dev/null || echo 0
}

singular_breaker_reset() {
  singular_ensure_state_dirs
  printf '{"consecFails":0,"updatedAt":"%s"}\n' "$(singular_timestamp)" >"$SINGULAR_BREAKER_FILE"
}

# Increment the consecutive-failure counter; echo the new value.
singular_breaker_trip() {
  singular_ensure_state_dirs
  python3 - "$SINGULAR_BREAKER_FILE" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
path = sys.argv[1]
n = 0
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            n = int(json.load(f).get("consecFails", 0))
    except Exception:
        n = 0
n += 1
with open(path, "w", encoding="utf-8") as f:
    json.dump({"consecFails": n, "updatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")}, f)
    f.write("\n")
print(n)
PY
}

# Write a human-readable STATUS report (the thing the user reads after ~20h).
singular_write_status() {
  # args: iteration note
  local iteration="${1:-0}" note="${2:-}"
  singular_ensure_state_dirs
  local branch head ready active imported integrated decisions parked breaker stop
  branch="$(singular_current_branch 2>/dev/null || echo '?')"
  head="$(git -C "$SINGULAR_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  ready="$(singular_list_status_ready_tasks 2>/dev/null | wc -l | tr -d ' ')"
  active="$(singular_active_lease_count 2>/dev/null || echo 0)"
  imported="$(singular_count_files "$SINGULAR_ORCH_DIR/packets/imported" -name '*.json' -not -name '*.audit.json')"
  integrated="$(grep -c '"integration.integrated"' "$SINGULAR_EVENTS_FILE" 2>/dev/null || echo 0)"
  parked="$(grep -c '"escalate-parked"\|"decider.parked"' "$SINGULAR_EVENTS_FILE" 2>/dev/null || echo 0)"
  breaker="$(singular_breaker_count)"
  stop="no"; singular_stop_requested && stop="yes"
  {
    echo "# singular Autonomous Status"
    echo ""
    echo "Updated: $(singular_timestamp)"
    echo "Generated by: reconcile iteration $iteration (pid $$) — snapshot as of the"
    echo "last cycle; may be stale while the loop idles. Live view: \`singular health\`."
    echo "Iteration: $iteration"
    echo "Note: ${note:-(running)}"
    echo "STOP requested: $stop"
    echo ""
    echo "- branch: \`$branch\` @ \`$head\`"
    echo "- ready tasks: $ready"
    echo "- active leases: $active"
    echo "- imported packets: $imported"
    echo "- integrations (lifetime): $integrated"
    echo "- parked escalations (lifetime): $parked"
    echo "- circuit-breaker consecutive failures: $breaker / ${SINGULAR_MAX_CONSEC_FAILS}"
    echo ""
    echo "## Recent decisions"
    echo ""
    grep '"decision.recorded"\|"decider.' "$SINGULAR_EVENTS_FILE" 2>/dev/null | tail -10 \
      | python3 -c 'import json,sys
for l in sys.stdin:
    try:
        e=json.loads(l); d=e.get("data",{})
        print("- %s  %s  %s" % (e.get("ts",""), e.get("type",""), json.dumps(d)))
    except Exception: pass' || true
    echo ""
    echo "## Recent events"
    echo ""
    tail -15 "$SINGULAR_EVENTS_FILE" 2>/dev/null | python3 -c 'import json,sys
for l in sys.stdin:
    try:
        e=json.loads(l); print("- %s  %s  %s" % (e.get("ts",""), e.get("type",""), e.get("message","")))
    except Exception: pass' || true
  } >"$SINGULAR_STATUS_FILE"
}

# Set the Status: header of a task markdown file in place.
# Read the `Status:` header of a task file, lowercased. Empty when absent.
singular_task_status() {
  local task_file="$1"
  [[ -f "$task_file" ]] || return 1
  python3 - "$task_file" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as stream:
    for line in stream:
        if line.lower().startswith("status:"):
            print(line.split(":", 1)[1].strip().lower())
            break
PY
}

singular_task_set_status() {
  local task_file="$1" status="$2"
  python3 - "$task_file" "$status" <<'PY'
import os
import re
import sys

path, status = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines(keepends=True)
out = []
done = False
in_header = True
for line in lines:
    if line.startswith("## "):
        in_header = False
    if in_header and not done and re.match(r"^Status:\s*", line):
        out.append(f"Status: {status}\n")
        done = True
    else:
        out.append(line)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("".join(out))
os.replace(tmp, path)
PY
}

# Count leases whose status is an active/in-flight value.
singular_active_lease_count() {
  [[ -d "$SINGULAR_LEASES_DIR" ]] || { echo 0; return 0; }
  python3 - "$SINGULAR_LEASES_DIR" <<'PY'
import json
import os
import sys

leases_dir = sys.argv[1]
active = {"running", "planned", "needs-review"}
count = 0
try:
    names = sorted(os.listdir(leases_dir))
except OSError:
    print(0)
    raise SystemExit(0)
for name in names:
    if not name.endswith(".json"):
        continue
    path = os.path.join(leases_dir, name)
    if not os.path.isfile(path):
        continue
    try:
        with open(path, "r", encoding="utf-8") as f:
            status = json.load(f).get("status", "")
    except Exception:
        continue
    if status in active:
        count += 1
print(count)
PY
}

# Count git worktrees other than the primary repo worktree.
singular_extra_worktree_count() {
  git -C "$SINGULAR_ROOT" worktree list --porcelain \
    | awk -v root="$SINGULAR_ROOT" '/^worktree / {p=substr($0,10); if (p != root) c++} END {print c+0}'
}

# True (0) if a worktree path is registered with git.
singular_worktree_registered() {
  local path="$1"
  git -C "$SINGULAR_ROOT" worktree list --porcelain \
    | awk -v p="$path" '/^worktree / {if (substr($0,10) == p) found=1} END {exit found?0:1}'
}

singular_worktree_provision() {
  local worktree="$1" run_dir="${2:-}"
  local specs="${SINGULAR_PROVISION_FILES_JSON:-[]}"
  local allow="${SINGULAR_ENV_ALLOWLIST_JSON:-[]}"
  python3 - "$SINGULAR_ROOT" "$worktree" "$run_dir" "$specs" "$allow" <<'PY'
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
worktree = pathlib.Path(sys.argv[2]).resolve()
run_dir = pathlib.Path(sys.argv[3]).resolve() if sys.argv[3] else None
specs_raw, allow_raw = sys.argv[4], sys.argv[5]

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(2)

def load_list(raw, label):
    try:
        value = json.loads(raw or "[]")
    except Exception as exc:
        fail(f"{label} must be JSON: {exc}")
    if not isinstance(value, list):
        fail(f"{label} must be an array")
    return value

def clean_rel(value, label):
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty relative path")
    p = pathlib.PurePosixPath(value)
    if p.is_absolute() or any(part in ("", ".", "..") for part in p.parts):
        fail(f"{label} must be a clean relative path: {value!r}")
    return value

def under(base, path):
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False

def git_ignored(cwd, rel):
    return subprocess.run(
        ["git", "-C", str(cwd), "check-ignore", "-q", "--", rel],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0

specs = load_list(specs_raw, "provisionFiles")
allowlist = load_list(allow_raw, "envAllowlist")
copied = []
for idx, item in enumerate(specs):
    if not isinstance(item, dict):
        fail(f"provisionFiles[{idx}] must be an object")
    source = clean_rel(item.get("source"), f"provisionFiles[{idx}].source")
    target = clean_rel(item.get("target"), f"provisionFiles[{idx}].target")
    required = bool(item.get("required", False))
    src = root / source
    dst = worktree / target
    if not src.exists():
        if required:
            fail(f"required provision file missing: {source}")
        continue
    resolved = src.resolve()
    if not under(root, resolved):
        fail(f"provision source escapes repo: {source}")
    if not src.is_file():
        fail(f"provision source is not a file: {source}")
    if not git_ignored(root, source):
        fail(f"provision source is not gitignored: {source}")
    if not git_ignored(worktree, target):
        fail(f"provision target is not gitignored in worktree: {target}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    copied.append({"source": source, "target": target})

env_written = ""
if allowlist:
    name_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
    exact = set()
    prefixes = []
    for idx, pattern in enumerate(allowlist):
        if not isinstance(pattern, str) or not pattern:
            fail(f"envAllowlist[{idx}] must be a non-empty string")
        if pattern.endswith("*"):
            prefix = pattern[:-1]
            if not prefix or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", prefix):
                fail(f"envAllowlist[{idx}] has invalid prefix pattern: {pattern!r}")
            prefixes.append(prefix)
        else:
            if not name_re.match(pattern):
                fail(f"envAllowlist[{idx}] has invalid env name: {pattern!r}")
            exact.add(pattern)
    env_rel = ".singular-state/worktree-env.sh"
    if not git_ignored(worktree, env_rel):
        fail(f"worktree env file target is not gitignored: {env_rel}")
    env_path = worktree / env_rel
    env_path.parent.mkdir(parents=True, exist_ok=True)
    names = []
    for name in sorted(os.environ):
        if name in exact or any(name.startswith(prefix) for prefix in prefixes):
            if name_re.match(name):
                names.append(name)
    with open(env_path, "w", encoding="utf-8") as f:
        f.write("# generated by singular; sourced only for worktree prewarm/gate phases\n")
        for name in names:
            f.write(f"export {name}={shlex.quote(os.environ[name])}\n")
    env_written = str(env_path)

if run_dir:
    run_dir.mkdir(parents=True, exist_ok=True)
    with open(run_dir / "worktree-provision.json", "w", encoding="utf-8") as f:
        json.dump({"copied": copied, "envFile": env_written}, f, indent=2)
        f.write("\n")
print(json.dumps({"copied": copied, "envFile": env_written}, separators=(",", ":")))
PY
  local env_file="$worktree/.singular-state/worktree-env.sh"
  if [[ -f "$env_file" ]]; then
    export SINGULAR_WORKTREE_ENV_FILE="$env_file"
  fi
}

singular_worktree_env_configured() {
  [[ -n "${SINGULAR_ENV_ALLOWLIST_JSON:-}" && "${SINGULAR_ENV_ALLOWLIST_JSON:-[]}" != "[]" ]]
}

# Dependency trees to copy into a fresh worktree, as a JSON array of clean
# relative paths. node_modules is always included: it used to be a DEFAULT that
# the config REPLACED, so a monorepo that declared a nested path
# (["apps/web/node_modules"]) silently stopped copying the root one and got a
# worktree that was worse than the one it was trying to fix.
singular_worktree_copy_paths_json() {
  local configured="${SINGULAR_WORKTREE_COPY_PATHS_JSON:-${SINGULAR_AUDIT_VERIFY_COPY_PATHS_JSON:-[]}}"
  python3 - "$configured" <<'PY'
import json
import pathlib
import sys

try:
    values = json.loads(sys.argv[1] or "[]")
except Exception:
    raise SystemExit(2)
if not isinstance(values, list):
    raise SystemExit(2)
paths = ["node_modules"]
for value in values:
    if not isinstance(value, str) or not value:
        raise SystemExit(2)
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise SystemExit(2)
    if value not in paths:
        paths.append(value)
print(json.dumps(paths, separators=(",", ":")))
PY
}

# Copy the declared dependency trees from $1 into $2. macOS clonefile copies are
# copy-on-write; other platforms use GNU reflinks when available, then a plain
# recursive copy. A declared path that does not exist in the source is reported
# rather than skipped in silence — "I did not copy what you asked for" is
# precisely the information missing when an audit worktree fails a gate the
# worker passed.
singular_worktree_copy_paths() {
  local source_worktree="$1" target_worktree="$2"
  local paths_json relative source_path target_path copy_ok rc=0
  paths_json="$(singular_worktree_copy_paths_json)" || {
    echo "worktree copy paths are not a clean relative-path array" >&2
    return 2
  }
  local -a relatives=()
  mapfile -t relatives < <(python3 -c 'import json,sys;[print(p) for p in json.loads(sys.argv[1])]' "$paths_json")
  for relative in "${relatives[@]}"; do
    [[ -n "$relative" ]] || continue
    source_path="$source_worktree/$relative"
    target_path="$target_worktree/$relative"
    if [[ ! -e "$source_path" ]]; then
      # node_modules is implicit, so its absence is normal for a repo that has
      # none; anything the operator asked for by name is not.
      if [[ "$relative" != "node_modules" ]]; then
        echo "worktree copy: declared path is absent in the source worktree: $relative" >&2
        singular_append_event "worktree.copy_path_absent" \
          "declared worktree copy path is absent in the source worktree" \
          "{\"path\":\"$relative\",\"source\":\"$source_worktree\"}" || true
      fi
      continue
    fi
    [[ -e "$target_path" ]] && continue
    mkdir -p "$(dirname "$target_path")"
    copy_ok="no"
    if cp -cR "$source_path" "$target_path" >/dev/null 2>&1; then
      copy_ok="yes"
    else
      rm -rf "$target_path"
      if cp -a --reflink=auto "$source_path" "$target_path" >/dev/null 2>&1; then
        copy_ok="yes"
      else
        rm -rf "$target_path"
        if cp -R "$source_path" "$target_path" >/dev/null 2>&1; then
          copy_ok="yes"
        fi
      fi
    fi
    if [[ "$copy_ok" != "yes" ]]; then
      echo "worktree copy: failed to copy $relative" >&2
      SINGULAR_WORKTREE_PREPARE_DETAIL="dependency-copy-failed:$relative"
      rc=1
    fi
  done
  return "$rc"
}

# The one way a worktree becomes runnable. Three sites used to build worktrees
# three different ways, and the differences decided outcomes: the AUDITOR
# re-runs the gate whose result accepts or rejects the work, in the one worktree
# that never received `prewarm`, while the worker that produced the green result
# did. accept-existing-packet got neither prewarm nor the dependency copies. An
# environment difference between those worktrees is indistinguishable, from the
# outside, from the work being wrong.
#
#   $1 worktree, $2 run_dir (may be empty), $3 source worktree for dependency
#   copies (empty to skip), $4 log file.
#
# Sets SINGULAR_WORKTREE_PREPARE_STAGE to the stage that failed, and
# SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FAILED when bootstrap failed under
# SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FATAL=no. Callers pass extra environment
# for the bootstrap/prewarm children in the SINGULAR_WORKTREE_PREPARE_ENV array.
singular_worktree_prepare() {
  local worktree="$1" run_dir="${2:-}" source_worktree="${3:-}" log="${4:-/dev/null}"
  local bootstrap_fatal="${SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FATAL:-yes}"
  SINGULAR_WORKTREE_PREPARE_STAGE=""
  SINGULAR_WORKTREE_PREPARE_DETAIL=""
  SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FAILED="no"
  local -a child_env=()
  if [[ "$(declare -p SINGULAR_WORKTREE_PREPARE_ENV 2>/dev/null)" == "declare -a"* ]]; then
    child_env=("${SINGULAR_WORKTREE_PREPARE_ENV[@]}")
  fi

  SINGULAR_WORKTREE_PREPARE_STAGE="provision"
  singular_worktree_provision "$worktree" "$run_dir" >>"$log" 2>&1 || return 1

  if [[ -n "$source_worktree" ]]; then
    SINGULAR_WORKTREE_PREPARE_STAGE="copy-paths"
    singular_worktree_copy_paths "$source_worktree" "$worktree" >>"$log" 2>&1 || return 1
  fi

  SINGULAR_WORKTREE_PREPARE_STAGE="bootstrap"
  local bootstrap_rc=0
  if [[ "${#child_env[@]}" -gt 0 ]]; then
    env "${child_env[@]}" "$SINGULAR_LIB_DIR/bootstrap-worktree.sh" \
      --worktree "$worktree" >>"$log" 2>&1 || bootstrap_rc=$?
  else
    "$SINGULAR_LIB_DIR/bootstrap-worktree.sh" --worktree "$worktree" \
      >>"$log" 2>&1 || bootstrap_rc=$?
  fi
  if [[ "$bootstrap_rc" -ne 0 ]]; then
    SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FAILED="yes"
    [[ "$bootstrap_fatal" == "no" ]] || return 1
  fi

  # Legacy optional prewarm, non-fatal wherever it runs — but it now runs
  # EVERYWHERE, which is the point of this function.
  SINGULAR_WORKTREE_PREPARE_STAGE="prewarm"
  if [[ -n "${SINGULAR_PREWARM_CMD:-}" ]]; then
    if [[ "${#child_env[@]}" -gt 0 ]]; then
      env "${child_env[@]}" "$(singular_bash_bin)" -c \
        "cd $(printf '%q' "$worktree") && $SINGULAR_PREWARM_CMD" >>"$log" 2>&1 \
        || echo "  warning: prewarm command failed (exit $?); continuing" >&2
    else
      singular_run_in_worktree_env "$worktree" "$(singular_bash_bin)" -c \
        "$SINGULAR_PREWARM_CMD" >>"$log" 2>&1 \
        || echo "  warning: prewarm command failed (exit $?); continuing" >&2
    fi
  fi

  SINGULAR_WORKTREE_PREPARE_STAGE=""
  return 0
}

singular_run_in_worktree_env() {
  local worktree="$1"
  shift
  if singular_worktree_env_configured && [[ -n "${SINGULAR_WORKTREE_ENV_FILE:-}" && -f "$SINGULAR_WORKTREE_ENV_FILE" ]]; then
    (
      cd "$worktree"
      env -i \
        HOME="${HOME:-}" \
        PATH="${PATH:-/usr/bin:/bin}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        SHELL="${SHELL:-/bin/sh}" \
        SINGULAR_ROOT="$SINGULAR_ROOT" \
        SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" \
        SINGULAR_ENGINE_HOME="$SINGULAR_ENGINE_HOME" \
        SINGULAR_WORKTREE_ENV_FILE="$SINGULAR_WORKTREE_ENV_FILE" \
        "$(singular_bash_bin)" -c 'set -a; . "$SINGULAR_WORKTREE_ENV_FILE"; set +a; exec "$@"' bash "$@"
    )
  else
    ( cd "$worktree" && SINGULAR_ROOT="$SINGULAR_ROOT" SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" "$@" )
  fi
}

# Append a recovery event with the fields required by operating-model section 13.
singular_record_recovery() {
  # args: failure taskId branch strategy authority expectedEvidence nextOwner
  local failure="$1" task_id="$2" branch="$3" strategy="$4"
  local authority="${5:-origin}" expected="${6:-}" next_owner="${7:-origin}"
  local data
  data="$(python3 - "$failure" "$task_id" "$branch" "$strategy" "$authority" "$expected" "$next_owner" <<'PY'
import json
import sys
keys = ["failure", "taskId", "branch", "strategy", "authority", "expectedEvidence", "nextOwner"]
print(json.dumps(dict(zip(keys, sys.argv[1:8])), separators=(",", ":")))
PY
)"
  singular_append_event "recovery.action" "recovery action recorded" "$data"
}

# Write a machine-readable origin snapshot to .singular-state/origin-state.json.
singular_write_origin_state() {
  local run_id="$1"
  singular_ensure_state_dirs
  local branch head target inbox imported active worktrees
  branch="$(singular_current_branch)"
  head="$(git -C "$SINGULAR_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  target="${SINGULAR_TARGET_BRANCH:-}"
  inbox="$(singular_count_files "$SINGULAR_INBOX_DIR" -maxdepth 1 -name '*.json')"
  imported="$(singular_count_files "$SINGULAR_ORCH_DIR/packets/imported" -name '*.json' -not -name '*.audit.json')"
  active="$(singular_active_lease_count)"
  worktrees="$(singular_extra_worktree_count)"

  local ready_json leases_json
  # Snapshot telemetry should not pay the legacy O(ready × tasks) duplicate
  # signature scan. The dispatch frontier performs the authoritative duplicate,
  # dependency, lease, and scope checks before launching any worker.
  ready_json="$(singular_list_status_ready_tasks | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  if [[ -d "$SINGULAR_LEASES_DIR" ]]; then
    leases_json="$(find "$SINGULAR_LEASES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  else
    leases_json="[]"
  fi

  # 0.5.0 (additive): gates{passed,total}, completedNodes, per-status
  # taskCounts, and writer provenance — 0.4.0 emitted none of these, so every
  # console/summary field reading them was null by construction.
  python3 - "$SINGULAR_ORIGIN_STATE_FILE" "$run_id" "$branch" "$head" "$target" \
    "$inbox" "$imported" "$active" "$worktrees" "$ready_json" "$leases_json" \
    "$SINGULAR_ORCH_DIR/gates" "$SINGULAR_TASKS_DIR" "${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}" \
    "$$" "${SINGULAR_ORIGIN_STATE_ENTRY:-reconcile}" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone

(path, run_id, branch, head, target, inbox, imported, active, worktrees,
 ready_json, leases_json, gates_dir, tasks_dir, dag_file, writer_pid, entry) = sys.argv[1:17]

total_nodes = 0
try:
    total_nodes = len(json.load(open(dag_file)).get("nodes", []))
except Exception:
    pass
completed = []
if os.path.isdir(gates_dir):
    for name in sorted(os.listdir(gates_dir)):
        if not name.endswith(".gate-result.json"):
            continue
        try:
            g = json.load(open(os.path.join(gates_dir, name)))
        except Exception:
            continue
        if g.get("status") in ("passed", "passed-with-acknowledged-baseline"):
            completed.append(str(g.get("node", name.removesuffix(".gate-result.json"))))

task_counts = {}
if os.path.isdir(tasks_dir):
    for name in sorted(os.listdir(tasks_dir)):
        if not name.startswith("TASK-") or not name.endswith(".md"):
            continue
        status = ""
        try:
            with open(os.path.join(tasks_dir, name), encoding="utf-8") as f:
                for i, line in enumerate(f):
                    if i > 40:
                        break
                    m = re.match(r"^Status:\s*(.+?)\s*$", line)
                    if m:
                        status = m.group(1).strip().lower()
                        break
        except OSError:
            continue
        if status:
            task_counts[status] = task_counts.get(status, 0) + 1

data = {
    "schema": "singular.orchestration.origin-state.v0",
    "runId": run_id,
    "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "generatedByPid": int(writer_pid),
    "generatedByEntry": entry,
    "branch": branch,
    "headSha": head,
    "targetBranch": target,
    "packets": {"inbox": int(inbox), "imported": int(imported)},
    "activeLeases": int(active),
    "extraWorktrees": int(worktrees),
    "gates": {"passed": len(completed), "total": total_nodes},
    "completedNodes": completed,
    "taskCounts": task_counts,
    "readyTasks": json.loads(ready_json),
    "leaseFiles": json.loads(leases_json),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# ---- Project modules (extensions) -------------------------------------------
# Load optional modules listed in SINGULAR_MODULES (space-separated names or paths),
# AFTER all generic engine functions are defined so a module's overrides win.
# A bare name resolves to <engine>/singular-ext/<name>.sh then <repo>/singular-ext/<name>.sh.
# The generic engine sets no modules; a project opts in via config `modules`.
if [[ -n "${SINGULAR_MODULES:-}" ]]; then
  for _singular_mod in $SINGULAR_MODULES; do
    if [[ -f "$_singular_mod" ]]; then
      # shellcheck disable=SC1090
      source "$_singular_mod"
    elif [[ -f "$SINGULAR_ENGINE_HOME/singular-ext/${_singular_mod}.sh" ]]; then
      # shellcheck disable=SC1090
      source "$SINGULAR_ENGINE_HOME/singular-ext/${_singular_mod}.sh"
    elif [[ -f "$SINGULAR_ROOT/singular-ext/${_singular_mod}.sh" ]]; then
      # shellcheck disable=SC1090
      source "$SINGULAR_ROOT/singular-ext/${_singular_mod}.sh"
    else
      echo "singular: module not found: $_singular_mod" >&2
      exit 2
    fi
  done
  unset _singular_mod
fi

# ---- Context-evolution loader (structural hook) -----------------------------
# Source every engine/ctx-*.sh once, in sorted order, AFTER all generic engine
# functions and modules are defined so context-evolution slices get the last
# word. This block is the ONLY place ctx-*.sh files load: later stages ship
# context logic as new engine/ctx-*.sh files, never by editing lib.sh again. A
# ctx file that fails to source is FATAL (fail closed) — never silently skipped.
# With zero ctx-*.sh present the loop is a no-op (byte-identical prior behavior).
for _singular_ctx in "$SINGULAR_ENGINE_DIR"/ctx-*.sh; do
  [[ -e "$_singular_ctx" ]] || continue
  # shellcheck disable=SC1090
  source "$_singular_ctx" \
    || { echo "singular: failed to source context file: $_singular_ctx" >&2; exit 2; }
done
unset _singular_ctx
