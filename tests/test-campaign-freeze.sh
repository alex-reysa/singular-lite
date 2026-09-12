#!/usr/bin/env bash
set -euo pipefail

unset SINGULAR_CONTEXT_CONFIG_FILE SINGULAR_CONTEXT_BUDGET_BYTES 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/prompts"
git -C "$tmp" init -q repo
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
printf 'seed\n' >"$repo/seed.txt"
printf 'consumer planner policy\n' >"$repo/docs/orchestration/prompts/l1-planner.md"
git -C "$repo" add seed.txt
git -C "$repo" commit -qm seed
git -C "$repo" branch -M canary-target
printf '{"schemaVersion":"v2","targetBranch":"canary-target","gateCommand":"true","runner":"%s/engine/codex-run.sh","bootstrap":{"required":false,"commands":[]}}\n' "$ROOT" >"$repo/singular.config.json"

cycle_stub="$repo/reconcile-cycle-stub.sh"
cat >"$cycle_stub" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${SINGULAR_TEST_CYCLE_MUTATE:-0}" == "1" && ! -f "$SINGULAR_STATE_DIR/cycle-mutated" ]]; then
  python3 - "$SINGULAR_JSON_CONFIG_FILE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["gateCommand"] = "printf changed-during-live-cycle"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
  : >"$SINGULAR_STATE_DIR/cycle-mutated"
fi
echo "imported_this_run=0"
echo "dispatched_this_run=0"
echo "integrated_this_run=0"
echo "failed_dispatches=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "planner_backoff_active_this_run=0"
echo "l1_import_rejections_this_run=0"
echo "reaped_ok=0"
echo "reaped_failures=0"
echo "workers_running=0"
echo "gates_promoted_this_run=0"
SH
chmod +x "$cycle_stub"

run() {
  ( cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN="$ROOT/tests/fixtures/does-not-exist" \
      SINGULAR_RECONCILE_SCRIPT="$cycle_stub" SINGULAR_SLEEP=0 bash "$ROOT/engine/campaign.sh" "$@" )
}

binding() {
  ( cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" \
      bash -c '. "$1/engine/lib.sh"; singular_campaign_binding' bash "$ROOT" )
}

virgin_binding="$(binding)"
[[ "$virgin_binding" == "legacy" ]] \
  || { echo "virgin repository did not expose the compatibility binding" >&2; exit 1; }

# The runner contract exits before provider discovery, so this is fully local.
if run start --id unwaived-campaign >"$tmp/unwaived.log" 2>&1; then
  echo "campaign start accepted an unchecked live provider without an explicit waiver" >&2
  exit 1
fi
grep -q 'production-runner-live-readonly-probe' "$tmp/unwaived.log" || { cat "$tmp/unwaived.log" >&2; exit 1; }
run start --id fixture-campaign --allow-provider-unchecked >"$tmp/start.log"
manifest="$repo/.singular-state/campaign/manifest.json"
active="$repo/.singular-state/campaign/ACTIVE"
enforced="$repo/.singular-state/CAMPAIGN_ENFORCED"
[[ -f "$manifest" ]] || { echo "manifest not written" >&2; exit 1; }
[[ "$(cat "$active")" == "fixture-campaign" ]] || { echo "ACTIVE marker not bound to campaign id" >&2; exit 1; }
[[ -f "$enforced" ]] || { echo "campaign start did not create persistent enforcement latch" >&2; exit 1; }
[[ ! -e "$repo/.singular-state/campaign/TRANSITION" ]] || { echo "campaign start left transition marker" >&2; exit 1; }
python3 - "$manifest" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["assurance"]["provider"] == "live-provider-unchecked-explicit-waiver", data["assurance"]
PY
run verify --quiet
fixture_binding="$(binding)"
[[ "$fixture_binding" == campaign:fixture-campaign:sha256:* ]] \
  || { echo "active campaign binding was not content-addressed" >&2; exit 1; }

# Publication CAS is deliberately cheap: once the expensive policy checkpoint
# has run outside the critical section, repeated publishers compare only the
# frozen manifest/ACTIVE/latch/epoch identity while holding the lock. A Python
# shim records campaign_manifest.py verify calls and fails if one occurs under
# the publication lock.
real_python3="$(command -v python3)"
python_shim_dir="$tmp/python-shim"
mkdir -p "$python_shim_dir"
cat >"$python_shim_dir/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == */campaign_manifest.py && "${2:-}" == "verify" ]]; then
  printf 'verify\n' >>"${CAMPAIGN_VERIFY_COUNT_FILE:?}"
  if [[ -e "${CAMPAIGN_TEST_LOCK_PATH:?}" ]]; then
    printf 'verify-under-lock\n' >"${CAMPAIGN_VERIFY_UNDER_LOCK_FILE:?}"
    exit 98
  fi
fi
exec "${CAMPAIGN_REAL_PYTHON3:?}" "$@"
SH
chmod +x "$python_shim_dir/python3"
: >"$tmp/campaign-verify-count"
(
  cd "$repo"
  export PATH="$python_shim_dir:$PATH"
  export CAMPAIGN_REAL_PYTHON3="$real_python3"
  export CAMPAIGN_VERIFY_COUNT_FILE="$tmp/campaign-verify-count"
  export CAMPAIGN_VERIFY_UNDER_LOCK_FILE="$tmp/campaign-verify-under-lock"
  export CAMPAIGN_TEST_LOCK_PATH="$repo/.singular-state/campaign/.publication-lock"
  export SINGULAR_ENGINE_HOME="$ROOT"
  export SINGULAR_CODEX_BIN="$ROOT/tests/fixtures/does-not-exist"
  export SINGULAR_RECONCILE_SCRIPT="$cycle_stub"
  export SINGULAR_SLEEP=0
  # shellcheck source=/dev/null
  . "$ROOT/engine/lib.sh"
  expected="$(singular_campaign_binding)"
  if singular_campaign_publication_cas "$expected" test unlocked-cas \
      >/dev/null 2>&1; then
    echo "campaign publication CAS succeeded without lock ownership" >&2
    exit 1
  fi
  singular_campaign_lock_acquire
  singular_campaign_publication_cas "$expected" test locked-cas-1
  singular_campaign_publication_cas "$expected" test locked-cas-2
  singular_campaign_publication_cas "$expected" test locked-cas-3
  singular_campaign_lock_release
  singular_campaign_binding_matches "$expected" test full-checkpoint
)
[[ ! -e "$tmp/campaign-verify-under-lock" ]] \
  || { cat "$tmp/campaign-verify-under-lock" >&2; exit 1; }
[[ "$(wc -l <"$tmp/campaign-verify-count" | tr -d '[:space:]')" == "1" ]] \
  || { echo "publication CAS repeated the full campaign fingerprint" >&2; exit 1; }

# Enforcement cannot be bypassed by deleting either the ACTIVE/manifest pair
# or the independent latch. Replacement also refuses every partial state.
cp "$manifest" "$tmp/manifest.saved"
cp "$active" "$tmp/active.saved"
rm -f "$manifest" "$active"
if run verify --quiet >/dev/null 2>&1; then
  echo "deleting the ACTIVE/manifest pair bypassed the enforcement latch" >&2
  exit 1
fi
if run start --replace --id invalid-replacement --allow-provider-unchecked >/dev/null 2>&1; then
  echo "campaign replace accepted a latch without its ACTIVE/manifest pair" >&2
  exit 1
fi
cp "$tmp/manifest.saved" "$manifest"
cp "$tmp/active.saved" "$active"
mv "$enforced" "$tmp/enforced.saved"
if run verify --quiet >/dev/null 2>&1; then
  echo "campaign verify accepted an ACTIVE/manifest pair without its latch" >&2
  exit 1
fi
if run start --replace --id invalid-replacement --allow-provider-unchecked >/dev/null 2>&1; then
  echo "campaign replace accepted an ACTIVE/manifest pair without its latch" >&2
  exit 1
fi
mv "$tmp/enforced.saved" "$enforced"
run verify --quiet

# Request-scoped execution identity is not frozen campaign policy. These exact
# variables may change per dispatch/planning/publication without false drift.
SINGULAR_DISPATCH_BATCH_ID=batch-2 \
SINGULAR_DISPATCH_BASE_SHA=deadbeef \
SINGULAR_PLANNING_RUN_ID=PLAN-2 \
SINGULAR_PLANNING_ARTIFACT_DIR="$repo/.singular-state/planning/PLAN-2" \
SINGULAR_PLAN_ATTEMPT_BASE_SHA=cafebabe \
SINGULAR_ATTEMPT_TASK_ID=TASK-9999 \
SINGULAR_ATTEMPT_STARTED_AT=2026-08-30T01:02:03Z \
SINGULAR_ATTEMPT_WORKER_STRATEGY=fresh \
SINGULAR_ATTEMPT_REVIEWER_STRATEGY=resume \
SINGULAR_WORKTREE_ENV_FILE="$repo/.singular-state/request.env" \
  run verify --quiet

# A staged planning task view is normalized only when it is contained by the
# declared planning artifact directory.
stage="$repo/.singular-state/planning/PLAN-STAGED"
mkdir -p "$stage/.plan-relevant-tasks"
( cd "$repo" && \
  SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN="$ROOT/tests/fixtures/does-not-exist" \
  SINGULAR_RECONCILE_SCRIPT="$cycle_stub" SINGULAR_SLEEP=0 \
  SINGULAR_PLANNING_ARTIFACT_DIR="$stage" \
  SINGULAR_TASKS_DIR="$stage/.plan-relevant-tasks" \
  bash -c '. "$1/engine/lib.sh"; singular_campaign_verify_or_refuse test staged-planning' bash "$ROOT" )

# Replacement archives the old pair but keeps enforcement continuously latched.
run start --id replacement-campaign --replace --allow-provider-unchecked >"$tmp/replace.log"
[[ -f "$enforced" ]] || { echo "campaign replace dropped enforcement latch" >&2; exit 1; }
[[ "$(cat "$active")" == "replacement-campaign" ]] \
  || { echo "campaign replace did not publish the replacement ACTIVE id" >&2; exit 1; }
find "$repo/.singular-state/campaign/history" -name 'fixture-campaign.*.replaced.json' -type f | grep -q . \
  || { echo "campaign replace did not archive the prior manifest" >&2; exit 1; }
run verify --quiet
replacement_binding="$(binding)"
[[ "$replacement_binding" == campaign:replacement-campaign:sha256:* \
    && "$replacement_binding" != "$fixture_binding" ]] \
  || { echo "campaign replacement reused the prior campaign identity" >&2; exit 1; }
if ( cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" \
    bash -c '. "$1/engine/lib.sh"; singular_campaign_binding_matches "$2" test replacement-check' \
      bash "$ROOT" "$fixture_binding" ) >/dev/null 2>&1; then
  echo "prior campaign binding remained valid after replacement" >&2
  exit 1
fi

# Native reconcile dispatches through dispatch-wrap, which injects a fresh
# owner/generation CAS token into L1. Those values must reach the job while the
# frozen campaign check treats them as invocation identity rather than policy.
# STOP keeps this regression entirely before provider/worktree mutation.
native_l1="$tmp/native-l1-entry.sh"
native_tokens="$tmp/native-reservation-tokens"
cat >"$native_l1" <<SH
#!/usr/bin/env bash
set -euo pipefail
[[ "\${SINGULAR_RESERVATION_OWNER:-}" == 'reconcile:RUN-NATIVE:TASK-9999' ]]
[[ "\${SINGULAR_RESERVATION_GENERATION:-}" == 7 ]]
printf '%s@%s\n' "\$SINGULAR_RESERVATION_OWNER" "\$SINGULAR_RESERVATION_GENERATION" \
  >'$native_tokens'
exec '$ROOT/engine/l1-drive.sh' "\$@"
SH
chmod +x "$native_l1"
: >"$repo/.singular-state/STOP"
native_out="$tmp/native-dispatch.out"
if ! ( cd "$repo" && \
    SINGULAR_ENGINE_HOME="$ROOT" \
    SINGULAR_CODEX_BIN="$ROOT/tests/fixtures/does-not-exist" \
    SINGULAR_RECONCILE_SCRIPT="$cycle_stub" SINGULAR_SLEEP=0 \
    "$ROOT/engine/dispatch-wrap.sh" TASK-9999 "$native_l1" \
      reconcile:RUN-NATIVE:TASK-9999 7 RUN-NATIVE-batch \
  ) >"$native_out" 2>&1; then
  cat "$native_out" >&2
  echo "native reservation context caused campaign drift at L1 entry" >&2
  exit 1
fi
rm -f "$repo/.singular-state/STOP"
[[ "$(cat "$native_tokens")" == 'reconcile:RUN-NATIVE:TASK-9999@7' ]] \
  || { echo "dispatch-wrap stripped reservation CAS authority from L1" >&2; exit 1; }
grep -q 'frozen (STOP sentinel present' "$native_out" \
  || { cat "$native_out" >&2; echo "native fixture did not reach L1 after campaign verification" >&2; exit 1; }
[[ ! -e "$repo/.worktrees/TASK-9999" ]] \
  || { echo "native STOP fixture reached provider/worktree mutation" >&2; exit 1; }

# The exclusion is exact-name only; a different setting under the same prefix
# remains frozen like every unknown resolved SINGULAR_* policy input.
SINGULAR_RUNNER_ROLE=implementer \
SINGULAR_RUNNER_CAPABILITY_PROFILE=implementer-core \
SINGULAR_RUNNER_RUN_ID=RUN-INVOKE \
SINGULAR_TEST_TASK_CONTRACT="$repo/docs/orchestration/tasks/TASK-9999.md" \
SINGULAR_TEST_TASK_ID=TASK-9999 \
SINGULAR_TEST_TASKS_DIR="$repo/docs/orchestration/tasks" \
SINGULAR_EXPECTED_CAMPAIGN_BINDING="$replacement_binding" \
  run verify --quiet || {
    echo "invocation identity was mistaken for frozen policy drift" >&2
    exit 1
  }

if SINGULAR_CONTEXT_CONFIG_FILE="$repo/singular.config.json" \
    run verify --quiet >/dev/null 2>&1; then
  echo "invocation introduced an alternate context policy selector" >&2
  exit 1
fi

if SINGULAR_CONTEXT_BUDGET_BYTES=99999 run verify --quiet >/dev/null 2>&1; then
  echo "effective context budget escaped the frozen policy projection" >&2
  exit 1
fi
run verify --quiet

if SINGULAR_RESERVATION_POLICY_SENTINEL=changed run verify --quiet >/dev/null 2>&1; then
  echo "reservation exclusion widened to unrelated resolved settings" >&2
  exit 1
fi

# Excluding request identity must not hide a real resolved-policy change.
if SINGULAR_RESERVATION_OWNER=reconcile:RUN-NATIVE:TASK-9999 \
    SINGULAR_RESERVATION_GENERATION=8 SINGULAR_ENABLE_L1_PARALLEL=1 \
    run verify --quiet >/dev/null 2>&1; then
  echo "reservation context hid resolved campaign policy drift" >&2
  exit 1
fi

# Campaign transitions share the git->campaign lock order with integration and
# must never fingerprint or deactivate a transient staged merge tree.
git -C "$repo" checkout -qb staged-merge-source
printf 'staged merge probe\n' >"$repo/staged-merge-probe.txt"
git -C "$repo" add staged-merge-probe.txt
git -C "$repo" commit -qm 'staged merge probe'
git -C "$repo" checkout -q canary-target
git -C "$repo" merge --no-ff --no-commit staged-merge-source >/dev/null
if run end >"$tmp/staged-merge-end.log" 2>&1; then
  echo "campaign end accepted a repository with MERGE_HEAD" >&2
  exit 1
fi
grep -q 'repository has a staged merge' "$tmp/staged-merge-end.log" \
  || { cat "$tmp/staged-merge-end.log" >&2; exit 1; }
[[ "$(cat "$active")" == "replacement-campaign" && -f "$manifest" && -f "$enforced" ]] \
  || { echo "refused staged-merge transition damaged active campaign state" >&2; exit 1; }
git -C "$repo" merge --abort
run verify --quiet

# Consumer prompt content and resolved behavior knobs are campaign policy, not
# mutable runtime state. Both must invalidate the active manifest.
printf 'hotpatched consumer planner policy\n' >>"$repo/docs/orchestration/prompts/l1-planner.md"
if run verify --quiet >/dev/null 2>&1; then
  echo "active consumer prompt drift was accepted" >&2
  exit 1
fi
printf 'consumer planner policy\n' >"$repo/docs/orchestration/prompts/l1-planner.md"
run verify --quiet
if SINGULAR_ENABLE_L1_PARALLEL=1 run verify --quiet >/dev/null 2>&1; then
  echo "resolved autonomy knob drift was accepted" >&2
  exit 1
fi
run verify --quiet

# Drift introduced by the first reconcile invocation must be caught at the
# second cycle boundary, before reconcile can be invoked again.
if ( cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN="$ROOT/tests/fixtures/does-not-exist" \
    SINGULAR_RECONCILE_SCRIPT="$cycle_stub" SINGULAR_SLEEP=0 \
    SINGULAR_TEST_CYCLE_MUTATE=1 SINGULAR_TEST_PROCESS_CONTROL=1 SINGULAR_TEST_PROCESS_CONTROL_STATE=ok \
    bash "$ROOT/engine/autonomate.sh" ) >"$tmp/live-drift.log" 2>&1; then
  echo "live autonomate continued after post-start drift" >&2
  exit 1
fi
grep -q 'campaign runtime drift at cycle-boundary' "$tmp/live-drift.log" || { cat "$tmp/live-drift.log" >&2; exit 1; }
[[ -f "$repo/.singular-state/cycle-mutated" ]] || { echo "cycle stub was never invoked" >&2; exit 1; }

# A changed policy surface must halt a frozen campaign, but a legacy repo with
# no manifest remains compatible.
if run verify --quiet >/dev/null 2>&1; then
  echo "campaign drift was accepted" >&2
  exit 1
fi
# The autonomous entrypoint must enforce the same pin before it can dispatch.
if ( cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN="$ROOT/tests/fixtures/does-not-exist" bash "$ROOT/engine/autonomate.sh" --once ) >"$tmp/auto.log" 2>&1; then
  echo "autonomate ran through campaign drift" >&2
  exit 1
fi
grep -q 'campaign runtime drift' "$tmp/auto.log" || { cat "$tmp/auto.log" >&2; exit 1; }
reconcile_events_before="$(grep -c 'origin.reconcile_started' "$repo/.singular-state/events.ndjson" 2>/dev/null || true)"
if ( cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN="$ROOT/tests/fixtures/does-not-exist" \
    SINGULAR_RECONCILE_SCRIPT="$cycle_stub" SINGULAR_SLEEP=0 \
    bash "$ROOT/engine/reconcile.sh" --actuate ) >"$tmp/direct-actuate.log" 2>&1; then
  echo "direct reconcile --actuate bypassed campaign drift" >&2
  exit 1
fi
grep -q 'campaign runtime drift at entry' "$tmp/direct-actuate.log" || { cat "$tmp/direct-actuate.log" >&2; exit 1; }
reconcile_events_after="$(grep -c 'origin.reconcile_started' "$repo/.singular-state/events.ndjson" 2>/dev/null || true)"
[[ "$reconcile_events_after" == "$reconcile_events_before" ]] \
  || { echo "drifted direct actuation entered reconcile mutation path" >&2; exit 1; }
for direct_case in \
  "engine/reconcile.sh --apply" \
  "engine/l1-drive.sh TASK-9999" \
  "engine/integrate.sh --dry-run" \
  "engine/promote-gate.sh D1.contract" \
  "singular-ext/promote-gate.sh D1.contract"
do
  read -r direct_script direct_arg <<<"$direct_case"
  direct_log="$tmp/direct-$(basename "$direct_script")-${direct_arg#--}.log"
  if ( cd "$repo" && \
      SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN="$ROOT/tests/fixtures/does-not-exist" \
      SINGULAR_RECONCILE_SCRIPT="$cycle_stub" SINGULAR_SLEEP=0 \
      bash "$ROOT/$direct_script" "$direct_arg" ) >"$direct_log" 2>&1; then
    echo "direct mutation entrypoint bypassed campaign drift: $direct_case" >&2
    exit 1
  fi
  grep -q 'campaign runtime drift at entry' "$direct_log" \
    || { cat "$direct_log" >&2; exit 1; }
done
run end >"$tmp/end.log"
[[ ! -e "$manifest" && ! -e "$active" ]] || { echo "campaign end left ACTIVE state" >&2; exit 1; }
[[ ! -e "$enforced" ]] || { echo "campaign end left enforcement latch" >&2; exit 1; }
[[ ! -e "$repo/.singular-state/campaign/TRANSITION" ]] || { echo "campaign end left transition marker" >&2; exit 1; }
find "$repo/.singular-state/campaign/history" -name 'replacement-campaign.*.ended.json' -type f | grep -q . \
  || { echo "campaign end did not archive manifest" >&2; exit 1; }
run verify --quiet
inactive_binding="$(binding)"
[[ "$inactive_binding" == legacy:epoch:* && "$inactive_binding" != "$virgin_binding" ]] \
  || { echo "campaign end did not rotate the inactive identity" >&2; exit 1; }
if ( cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" \
    bash -c '. "$1/engine/lib.sh"; singular_campaign_binding_matches "$2" test aba-check' \
      bash "$ROOT" "$virgin_binding" ) >/dev/null 2>&1; then
  echo "a legacy operation survived a complete campaign start/end ABA cycle" >&2
  exit 1
fi
if SINGULAR_CAMPAIGN_REQUIRE_MANIFEST=1 run verify --quiet >/dev/null 2>&1; then
  echo "strict manifest policy accepted missing manifest" >&2
  exit 1
fi

# The canary is bound to the candidate runtime snapshot computed immediately
# after it passes. Hold the git lock so start waits, mutate policy after the
# candidate appears, and prove the stale canary cannot freeze the new bytes.
cp "$repo/singular.config.json" "$tmp/config.before-canary-race.json"
git_lock_ready="$tmp/git-lock-ready"
git_lock_release="$tmp/git-lock-release"
(
  cd "$repo"
  SINGULAR_ENGINE_HOME="$ROOT" bash -c '
    . "$1/engine/lib.sh"
    singular_git_lock_acquire
    : >"$2"
    while [[ ! -e "$3" ]]; do sleep 0.05; done
    singular_git_lock_release
  ' bash "$ROOT" "$git_lock_ready" "$git_lock_release"
) &
git_lock_pid=$!
for _ in $(seq 1 200); do
  [[ -e "$git_lock_ready" ]] && break
  sleep 0.05
done
[[ -e "$git_lock_ready" ]] || { echo "campaign race fixture did not acquire git lock" >&2; exit 1; }
(
  set +e
  run start --id stale-canary-campaign --allow-provider-unchecked \
    >"$tmp/stale-canary-start.log" 2>&1
  printf '%s\n' "$?" >"$tmp/stale-canary-start.rc"
) &
stale_start_pid=$!
candidate_seen="no"
for _ in $(seq 1 1800); do
  if find "$repo/.singular-state/campaign" -maxdepth 1 \
      -name '.manifest-candidate.*.json' -type f 2>/dev/null | grep -q .; then
    candidate_seen="yes"
    break
  fi
  if ! kill -0 "$stale_start_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
if [[ "$candidate_seen" != "yes" ]]; then
  : >"$git_lock_release"
  wait "$git_lock_pid" 2>/dev/null || true
  wait "$stale_start_pid" 2>/dev/null || true
  cat "$tmp/stale-canary-start.log" >&2 2>/dev/null || true
  echo "campaign start never produced its post-canary candidate" >&2
  exit 1
fi
python3 - "$repo/singular.config.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["gateCommand"] = "printf changed-after-canary"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, separators=(",", ":"))
    stream.write("\n")
PY
: >"$git_lock_release"
wait "$git_lock_pid"
wait "$stale_start_pid"
[[ "$(cat "$tmp/stale-canary-start.rc")" != "0" ]] \
  || { echo "campaign start froze policy bytes not exercised by its canary" >&2; exit 1; }
grep -q 'runtime changed after canary' "$tmp/stale-canary-start.log" \
  || { cat "$tmp/stale-canary-start.log" >&2; exit 1; }
[[ ! -e "$manifest" && ! -e "$active" && ! -e "$enforced" ]] \
  || { echo "failed stale-canary start published campaign state" >&2; exit 1; }
find "$repo/.singular-state/campaign" -maxdepth 1 \
  -name '.manifest-candidate.*.json' -type f 2>/dev/null | grep -q . \
  && { echo "failed stale-canary start leaked its candidate" >&2; exit 1; }
cp "$tmp/config.before-canary-race.json" "$repo/singular.config.json"
run verify --quiet

# ACTIVE is a fail-closed pair: neither half is accepted on its own.
printf 'orphan-campaign\n' >"$active"
if run verify --quiet >/dev/null 2>&1; then
  echo "orphan ACTIVE marker was accepted" >&2
  exit 1
fi
rm -f "$active"

# The engine fingerprint is source-wide: a nine-file hot patch is drift even
# when VERSION is unchanged. Exercise it against a minimal copied source shape.
home="$tmp/engine-home"
mkdir -p "$home/engine" "$home/schemas" "$home/singular-ext" "$home/templates/prompts" "$home/cli"
printf '1.0.0\n' >"$home/VERSION"
printf 'v2\n' >"$home/SCHEMA_VERSION"
printf 'lib\n' >"$home/engine/lib.sh"
printf 'reconcile-one\n' >"$home/engine/reconcile.sh"
printf '{}\n' >"$home/schemas/gate.json"
printf 'planner policy\n' >"$home/templates/prompts/planner.md"
printf '#!/usr/bin/env bash\n' >"$home/cli/singular"
printf '{}\n' >"$tmp/config.json"
printf 'runner\n' >"$tmp/runner"
printf 'driver\n' >"$tmp/gate"
printf 'evidence\n' >"$tmp/evidence"
args=(--engine-home "$home" --config-json "$tmp/config.json" --config-shell "$tmp/missing-shell" --config-local "$tmp/missing-local" --bash-bin "$(command -v bash)" --runner "$tmp/runner" --gate-command true --gate-driver "$tmp/gate" --gate-schema "$tmp/gate" --evidence-driver "$tmp/evidence" --packet-schema "$tmp/gate" --audit-schema "$tmp/gate" --active-policy "test-prompts=$home/templates/prompts")
export SINGULAR_MODEL_API_KEY="campaign-secret-sentinel-must-not-leak"
python3 "$ROOT/engine/campaign_manifest.py" create --output "$tmp/source-manifest.json" --campaign-id source --provider-assurance test-fixture "${args[@]}" >/dev/null
if grep -q 'campaign-secret-sentinel-must-not-leak' "$tmp/source-manifest.json"; then
  echo "campaign manifest leaked a raw SINGULAR_* secret" >&2
  exit 1
fi
# Import/bytecode caches are runtime by-products, not shipped policy. Creating
# one must not falsely halt the campaign.
mkdir -p "$home/engine/__pycache__"
printf 'compiled cache\n' >"$home/engine/__pycache__/reconcile.cpython-999.pyc"
python3 "$ROOT/engine/campaign_manifest.py" verify --manifest "$tmp/source-manifest.json" "${args[@]}" >/dev/null
printf 'reconcile-hotpatch\n' >>"$home/engine/reconcile.sh"
if python3 "$ROOT/engine/campaign_manifest.py" verify --manifest "$tmp/source-manifest.json" "${args[@]}" >/dev/null 2>&1; then
  echo "engine source hot patch was accepted" >&2
  exit 1
fi
# Prompt templates are executable policy and must be frozen too.
sed -i.bak '$d' "$home/engine/reconcile.sh"
rm -f "$home/engine/reconcile.sh.bak"
python3 "$ROOT/engine/campaign_manifest.py" create --output "$tmp/source-manifest.json" --campaign-id source --provider-assurance test-fixture "${args[@]}" >/dev/null
printf 'changed planner policy\n' >>"$home/templates/prompts/planner.md"
if python3 "$ROOT/engine/campaign_manifest.py" verify --manifest "$tmp/source-manifest.json" "${args[@]}" >/dev/null 2>&1; then
  echo "engine prompt hot patch was accepted" >&2
  exit 1
fi
echo "PASS campaign freeze"
