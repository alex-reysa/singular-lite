#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/engine/codex-run.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/state"
git -C "$tmp/repo" init -q
git -C "$tmp/repo" -c user.name=test -c user.email=test@example.com \
  commit -q --allow-empty -m init
branch="$(git -C "$tmp/repo" branch --show-current)"
printf 'test\n' >"$tmp/prompt.md"

cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
python3 - "$CODEX_ARGS_FILE" "$@" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(sys.argv[2:], handle)
PY
if [[ -n "${CODEX_ENV_FILE:-}" ]]; then
  python3 - "$CODEX_ENV_FILE" <<'PY'
import json, os, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({key: os.environ.get(key) for key in (
        "SINGULAR_EVIDENCE_SOCKET", "SINGULAR_EVIDENCE_CAPABILITY",
        "SINGULAR_EVIDENCE_ROLE")}, handle)
PY
fi
printf '%s\n' '{"type":"thread.started","thread_id":"role-session"}'
printf '%s\n' '{"type":"turn.completed"}'
SH
chmod +x "$tmp/bin/codex"

invoke() {
  local name="$1" prompt="$2" role="$3"; shift 3
  local role_args=()
  [[ -z "$role" ]] || role_args=(--role "$role")
  CODEX_ARGS_FILE="$tmp/$name.args.json" env \
    CODEX_ENV_FILE="${CODEX_ENV_FILE:-}" \
    PATH="$tmp/bin:$PATH" SINGULAR_ROOT="$tmp/repo" \
    SINGULAR_STATE_DIR="$tmp/state" SINGULAR_TARGET_BRANCH="$branch" \
    SINGULAR_CODEX_TIMEOUT_SEC=0 SINGULAR_CODEX_IDLE_SEC=0 \
    SINGULAR_CODEX_COMPLETION_GRACE_SEC=0 \
    SINGULAR_CODEX_MODEL=global-model \
    SINGULAR_CODEX_PLANNER_MODEL=planner-model \
    SINGULAR_CODEX_IMPLEMENTER_MODEL=implementer-model \
    SINGULAR_CODEX_AUDITOR_MODEL=auditor-model \
    SINGULAR_CODEX_CRITIC_MODEL=critic-model \
    SINGULAR_CODEX_DECIDER_MODEL=decider-model \
    SINGULAR_CODEX_SUPERVISOR_MODEL=supervisor-model \
    SINGULAR_CODEX_INTEGRATOR_MODEL=integrator-model \
    SINGULAR_CODEX_PLANNER_REASONING_EFFORT=medium \
    SINGULAR_CODEX_L2_REASONING_EFFORT=high \
    SINGULAR_CODEX_AUDITOR_REASONING_EFFORT=medium \
    SINGULAR_CODEX_CRITIC_REASONING_EFFORT=medium \
    SINGULAR_CODEX_DECIDER_REASONING_EFFORT=medium \
    SINGULAR_CODEX_SUPERVISOR_REASONING_EFFORT=medium \
    SINGULAR_CODEX_INTEGRATOR_REASONING_EFFORT=medium \
    "$@" bash "$RUNNER" --worktree "$tmp/repo" --level readonly \
      --run-id "RUN-$name" --prompt-file "$prompt" --no-output-capture \
      --allow-prefix docs/ --session-meta "$tmp/$name.meta.json" \
      ${role_args[@]+"${role_args[@]}"} >/dev/null
}

assert_route() {
  local name="$1" model="$2" effort="$3" role="$4"
  python3 - "$tmp/$name.args.json" "$tmp/$name.meta.json" \
    "$model" "$effort" "$role" <<'PY' || fail "$name route mismatch"
import json, sys
args = json.load(open(sys.argv[1], encoding="utf-8"))
meta = json.load(open(sys.argv[2], encoding="utf-8"))
model, effort, role = sys.argv[3:]
assert args[args.index("-m") + 1] == model, args
assert f'model_reasoning_effort="{effort}"' in args, args
effective = meta["effective"]
assert effective["role"] == role, effective
assert effective["model"] == model, effective
assert effective["reasoningEffort"] == effort, effective
assert effective["requestedServiceTier"] is None, effective
assert effective["providerObservedServiceTier"] is None, effective
PY
}

for row in \
  planner:planner-model:medium:planner \
  implementer:implementer-model:high:implementer \
  auditor:auditor-model:medium:auditor \
  critic:critic-model:medium:critic \
  decider:decider-model:medium:decider \
  supervisor:supervisor-model:medium:supervisor \
  integrator:integrator-model:medium:integrator \
  assistant:supervisor-model:medium:supervisor \
  reviewer:auditor-model:medium:auditor \
  final-auditor:auditor-model:medium:auditor \
  paired-auditor:auditor-model:medium:auditor
do
  IFS=: read -r role model effort effective_role <<<"$row"
  invoke "$role" "$tmp/prompt.md" "$role" SINGULAR_RUNNER_ROLE=critic
  assert_route "$role" "$model" "$effort" "$effective_role"
done

# Explicit --role beats both the environment role and a conflicting prompt name.
printf 'planner\n' >"$tmp/planner-prompt.md"
invoke explicit "$tmp/planner-prompt.md" implementer SINGULAR_RUNNER_ROLE=critic
assert_route explicit implementer-model high implementer

# With no declared role, the documented prompt-name inference remains available.
invoke inferred "$tmp/planner-prompt.md" ""
assert_route inferred planner-model medium planner

# Empty role override falls through to the global model, then the provider default.
invoke global "$tmp/prompt.md" implementer SINGULAR_CODEX_IMPLEMENTER_MODEL=
assert_route global global-model high implementer
CODEX_ARGS_FILE="$tmp/default.args.json" env PATH="$tmp/bin:$PATH" \
  SINGULAR_ROOT="$tmp/repo" SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_TARGET_BRANCH="$branch" SINGULAR_CODEX_TIMEOUT_SEC=0 \
  SINGULAR_CODEX_IDLE_SEC=0 SINGULAR_CODEX_COMPLETION_GRACE_SEC=0 \
  bash "$RUNNER" --worktree "$tmp/repo" --level l2 --run-id RUN-default \
    --role implementer --prompt-file "$tmp/prompt.md" --no-output-capture \
    --allow-prefix docs/ >/dev/null
python3 - "$tmp/default.args.json" <<'PY' || fail "provider default was not used"
import json, sys
args = json.load(open(sys.argv[1], encoding="utf-8"))
assert args[args.index("-m") + 1] == "gpt-5.5", args
PY

# An explicitly empty tier means normal/default and clears inherited fast config.
invoke normal "$tmp/prompt.md" implementer SINGULAR_CODEX_SERVICE_TIER=
python3 - "$tmp/normal.args.json" "$tmp/normal.meta.json" <<'PY' \
  || fail "explicit normal speed did not clear fast"
import json, sys
args = json.load(open(sys.argv[1], encoding="utf-8"))
meta = json.load(open(sys.argv[2], encoding="utf-8"))
assert 'service_tier="default"' in args, args
assert 'service_tier="fast"' not in args, args
assert meta["effective"]["requestedServiceTier"] == "default", meta
assert meta["effective"]["serviceTierSource"] == "explicit-clear", meta
PY

# Read-only evidence access keeps its capability environment and grants exactly
# one existing Unix socket through a profile that still extends read-only.
socket_path="$tmp/evidence.sock"
python3 - "$socket_path" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(30)
PY
socket_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$socket_path" ]] && break; sleep 0.1; done
[[ -S "$socket_path" ]] || fail "test evidence socket did not start"
CODEX_ENV_FILE="$tmp/evidence.env.json" invoke evidence "$tmp/prompt.md" auditor \
  SINGULAR_EVIDENCE_SOCKET="$socket_path" \
  SINGULAR_EVIDENCE_CAPABILITY=ephemeral-capability \
  SINGULAR_EVIDENCE_ROLE=auditor

# The socket grant enforces its boundary even when a declared capability
# profile opts out of strict mode and tries to replace the sandbox in argv.
cat >"$tmp/unsafe.json" <<JSON
{
  "schemaVersion":"v2",
  "targetBranch":"$branch",
  "capabilityProfiles":{
    "unsafe-audit":{
      "strict":false,
      "startup":"lazy",
      "required":[],
      "optional":[],
      "providerArgs":{"codex":["--sandbox=danger-full-access"]}
    }
  },
  "roleProfiles":{"auditor":"unsafe-audit"}
}
JSON
rm -f "$tmp/evidence-unsafe.args.json"
rc=0
invoke evidence-unsafe "$tmp/prompt.md" auditor \
  SINGULAR_JSON_CONFIG_FILE="$tmp/unsafe.json" \
  SINGULAR_EVIDENCE_SOCKET="$socket_path" || rc=$?
[[ "$rc" -eq 78 ]] || fail "unsafe evidence providerArgs must fail 78 (got $rc)"
[[ ! -e "$tmp/evidence-unsafe.args.json" ]] || fail "unsafe evidence providerArgs reached provider"

kill "$socket_pid" 2>/dev/null || true
wait "$socket_pid" 2>/dev/null || true
python3 - "$tmp/evidence.args.json" "$tmp/evidence.env.json" "$socket_path" <<'PY' \
  || fail "evidence socket permission profile mismatch"
import json, sys
args = json.load(open(sys.argv[1], encoding="utf-8"))
env = json.load(open(sys.argv[2], encoding="utf-8"))
socket_path = sys.argv[3].replace("\\", "\\\\").replace('"', '\\"')
assert "--ignore-user-config" in args, args
assert "--sandbox" not in args, args
assert args[args.index("-P") + 1] == "singular-evidence", args
assert 'permissions.singular-evidence.extends=":read-only"' in args, args
assert f'permissions.singular-evidence.network.unix_sockets={{"{socket_path}"="allow"}}' in args, args
assert 'default_permissions="singular-evidence"' in args, args
assert 'features.network_proxy=true' in args, args
assert 'permissions.singular-evidence.network.enabled=true' in args, args
assert env["SINGULAR_EVIDENCE_CAPABILITY"] == "ephemeral-capability", env
assert env["SINGULAR_EVIDENCE_ROLE"] == "auditor", env
assert env["SINGULAR_EVIDENCE_SOCKET"], env
PY

rm -f "$tmp/invalid.args.json"
rc=0
CODEX_ARGS_FILE="$tmp/invalid.args.json" env PATH="$tmp/bin:$PATH" \
  SINGULAR_ROOT="$tmp/repo" SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_TARGET_BRANCH="$branch" SINGULAR_EVIDENCE_SOCKET=relative.sock \
  bash "$RUNNER" --worktree "$tmp/repo" --level readonly --role auditor \
    --run-id RUN-invalid --prompt-file "$tmp/prompt.md" --no-output-capture \
    --allow-prefix docs/ >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 78 ]] || fail "relative evidence socket must fail 78 (got $rc)"
[[ ! -e "$tmp/invalid.args.json" ]] || fail "invalid socket reached provider"

echo "PASS: test-codex-role-models"
