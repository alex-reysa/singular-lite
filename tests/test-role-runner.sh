#!/usr/bin/env bash
set -euo pipefail

# singular_role_runner resolution plus the two call sites this work unit wires:
# the paired-audit hook and decide.sh must pick SINGULAR_ROLE_RUNNER_AUDITOR /
# SINGULAR_ROLE_RUNNER_DECIDER when set, not the default SINGULAR_RUNNER.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-role-runner.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-role-runner.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

# --- helper resolution -------------------------------------------------------
helper_root="$workroot/helper"
mkdir -p "$helper_root/docs/orchestration/prompts" "$helper_root/.singular-state" \
  "$helper_root/custom"
git -C "$helper_root" init -q
git -C "$helper_root" config user.email t@t
git -C "$helper_root" config user.name t
git -C "$helper_root" checkout -q -b target
git -C "$helper_root" commit -q --allow-empty -m init

printf '#!/usr/bin/env bash\nexit 0\n' >"$helper_root/custom/runner.sh"
chmod +x "$helper_root/custom/runner.sh"

(
  export SINGULAR_ROOT="$helper_root"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  export SINGULAR_CONFIG_FILE="/dev/null"
  export SINGULAR_LOCAL_CONFIG_FILE="/dev/null"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
  default="$SCRIPT_DIR/codex-run.sh"

  got="$(singular_role_runner auditor "$default")" || fail "unset: helper returned $?"
  assert_eq "$got" "$default" "unset → default"

  export SINGULAR_ROLE_RUNNER_AUDITOR="claude-run.sh"
  got="$(singular_role_runner auditor "$default")" || fail "bare name: helper returned $?"
  assert_eq "$got" "$SINGULAR_ENGINE_DIR/claude-run.sh" "bare name → engine dir"
  unset SINGULAR_ROLE_RUNNER_AUDITOR

  export SINGULAR_ROLE_RUNNER_AUDITOR="custom/runner.sh"
  got="$(singular_role_runner auditor "$default")" || fail "relative: helper returned $?"
  assert_eq "$got" "$SINGULAR_ROOT/custom/runner.sh" "relative → consumer root"
  unset SINGULAR_ROLE_RUNNER_AUDITOR

  export SINGULAR_ROLE_RUNNER_AUDITOR="$workroot/missing-runner.sh"
  set +e
  err="$(singular_role_runner auditor "$default" 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "78" "missing runner → 78"
  [[ "$err" == *"missing or not executable"* ]] \
    || fail "missing runner diagnostic: $err"
)
pass "helper resolution (unset / bare / relative / missing)"

# --- behavioural: paired-audit picks SINGULAR_ROLE_RUNNER_AUDITOR -------------
pa_root="$workroot/paired"
mkdir -p "$pa_root/docs/orchestration/prompts" "$pa_root/docs/orchestration/tasks" \
  "$pa_root/.singular-state/runs/RUN-paired"
git -C "$pa_root" init -q
git -C "$pa_root" config user.email t@t
git -C "$pa_root" config user.name t
git -C "$pa_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$pa_root/docs/orchestration/prompts/auditor.md"
printf '# TASK-0001\n\nStatus: accepted\n' >"$pa_root/docs/orchestration/tasks/TASK-0001.md"
git -C "$pa_root" add .
git -C "$pa_root" commit -qm init
head_sha="$(git -C "$pa_root" rev-parse HEAD)"

run_dir="$pa_root/.singular-state/runs/RUN-paired"
python3 - "$run_dir" "$head_sha" <<'PY'
import hashlib, json, sys
from pathlib import Path
run_dir = Path(sys.argv[1])
head = sys.argv[2]
packet = {"schema": "singular.orchestration.state-packet.v0",
          "taskId": "TASK-0001", "runId": "RUN-paired", "headSha": head}
command = "true"
report = dict(packet, schema="singular.orchestration.gate-report.v0",
              outcome="passed", command=command,
              commandSha256=hashlib.sha256(command.encode()).hexdigest(),
              sourceIntegrity={"status": "verified"})
artifacts = []
for name, value in (("packet.json", packet), ("audit-verification.json", report)):
    raw = json.dumps(value, sort_keys=True).encode()
    (run_dir / name).write_bytes(raw)
    artifacts.append({"ref": name, "bytes": len(raw),
                      "sha256": hashlib.sha256(raw).hexdigest()})
(run_dir / "evidence-manifest.json").write_text(json.dumps({
    "schema": "singular.orchestration.evidence-manifest.v0",
    "taskId": "TASK-0001", "runId": "RUN-paired", "headSha": head,
    "budget": {"limitBytes": 262144, "excerptLimitBytes": 2048,
               "retrievalLimitBytes": 262144},
    "artifacts": artifacts,
}, sort_keys=True))
PY

default_record="$workroot/default-roles.txt"
auditor_record="$workroot/auditor-roles.txt"
: >"$default_record"
: >"$auditor_record"

write_mock() {
  local path="$1" record="$2"
  cat >"$path" <<MOCK
#!/usr/bin/env bash
set -uo pipefail
printf '%s\\n' "\${SINGULAR_RUNNER_ROLE:-unset}" >>"$record"
out=""
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    --output-last-message) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
[[ -n "\$out" ]] && printf '{"verdict":"accepted","findings":[]}\\n' >"\$out"
exit 0
MOCK
  chmod +x "$path"
}

default_runner="$workroot/default-runner.sh"
auditor_runner="$workroot/auditor-runner.sh"
write_mock "$default_runner" "$default_record"
write_mock "$auditor_runner" "$auditor_record"

(
  export SINGULAR_ROOT="$pa_root"
  export SINGULAR_ORCH_DIR="$pa_root/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$pa_root/.singular-state"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_TARGET_BRANCH="target"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  export SINGULAR_RUNNER="$default_runner"
  export SINGULAR_ROLE_RUNNER_AUDITOR="$auditor_runner"
  export SINGULAR_PAIRED_AUDIT_PCT="100"
  export SINGULAR_CONFIG_FILE="/dev/null"
  export SINGULAR_LOCAL_CONFIG_FILE="/dev/null"
  export PYTHONDONTWRITEBYTECODE=1
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
  singular_ctx_paired_audit_record RUN-paired TASK-0001 "$run_dir" "$pa_root"
) || fail "paired-audit hook failed"

[[ -s "$auditor_record" ]] || fail "paired-audit: auditor role runner was not launched"
grep -qx 'auditor' "$auditor_record" \
  || fail "paired-audit: expected role auditor, got $(cat "$auditor_record")"
[[ ! -s "$default_record" ]] \
  || fail "paired-audit: default runner was launched ($(cat "$default_record"))"
pass "paired-audit hook picks SINGULAR_ROLE_RUNNER_AUDITOR"

# --- behavioural: decide.sh picks SINGULAR_ROLE_RUNNER_DECIDER ----------------
dec_root="$workroot/decider"
mkdir -p "$dec_root/docs/orchestration/prompts" "$dec_root/docs/orchestration/tasks" \
  "$dec_root/.singular-state"
git -C "$dec_root" init -q
git -C "$dec_root" config user.email t@t
git -C "$dec_root" config user.name t
git -C "$dec_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/decider.md" "$dec_root/docs/orchestration/prompts/decider.md"
printf '# TASK-0001\n\nStatus: ready\n' >"$dec_root/docs/orchestration/tasks/TASK-0001.md"
git -C "$dec_root" add .
git -C "$dec_root" commit -qm init

decider_record="$workroot/decider-roles.txt"
default_dec_record="$workroot/default-decider-roles.txt"
: >"$decider_record"
: >"$default_dec_record"
decider_runner="$workroot/decider-runner.sh"
default_dec_runner="$workroot/default-decider-runner.sh"
write_mock "$decider_runner" "$decider_record"
write_mock "$default_dec_runner" "$default_dec_record"

set +e
decide_out="$(
  cd "$dec_root" && env \
    SINGULAR_ROOT="$dec_root" \
    SINGULAR_ORCH_DIR="$dec_root/docs/orchestration" \
    SINGULAR_TASKS_DIR="$dec_root/docs/orchestration/tasks" \
    SINGULAR_STATE_DIR="$dec_root/.singular-state" \
    SINGULAR_EVENTS_FILE="$dec_root/.singular-state/events.ndjson" \
    SINGULAR_TARGET_BRANCH=target \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_CONFIG_FILE=/dev/null \
    SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
    SINGULAR_RUNNER="$default_dec_runner" \
    SINGULAR_ROLE_RUNNER_DECIDER="$decider_runner" \
    SINGULAR_DECIDER_TIMEOUT_SEC=30 \
    PYTHONDONTWRITEBYTECODE=1 \
    "$SCRIPT_DIR/decide.sh" --failure-class gate-red --run RUN-decider --task TASK-0001
)"
decide_rc=$?
set -e
[[ "$decide_rc" -eq 0 || "$decide_rc" -eq 2 ]] \
  || fail "decide.sh exited $decide_rc: $decide_out"
[[ -s "$decider_record" ]] || fail "decide.sh: decider role runner was not launched"
grep -qx 'decider' "$decider_record" \
  || fail "decide.sh: expected role decider, got $(cat "$decider_record")"
[[ ! -s "$default_dec_record" ]] \
  || fail "decide.sh: default runner was launched ($(cat "$default_dec_record"))"
pass "decide.sh picks SINGULAR_ROLE_RUNNER_DECIDER"

echo "PASS: test-role-runner"
