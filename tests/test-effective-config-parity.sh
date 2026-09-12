#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo with spaces"
mkdir -p "$repo/config dir" "$repo/tasks custom" "$repo/state custom" \
  "$repo/docs/orchestration" "$repo/shell-state" "$repo/local-tasks" \
  "$repo/local-state" "$repo/custom-runner"
git -C "$repo" init -q
git -C "$repo" -c user.name=test -c user.email=test@example.com \
  commit -q --allow-empty -m init

cat >"$repo/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"wrong","env":{"SINGULAR_CODEX_MODEL":"wrong-model"}}
JSON
cat >"$repo/docs/orchestration/dag.v0.json" <<'JSON'
{"schema":"singular.orchestration.dag.v0","nodes":[{"id":"config-parity","stage":"S0","area":"brain","layer":"test","kind":"contract","dependsOn":[],"requiredCompletion":"done"}]}
JSON
cat >"$repo/config dir/custom.json" <<'JSON'
{
  "schemaVersion":"v2",
  "targetBranch":"main",
  "runner":"codex-run.sh",
  "env": {
    "SINGULAR_CODEX_IMPLEMENTER_MODEL":"gpt-5.6-sol",
    "SINGULAR_CODEX_AUDITOR_MODEL":"gpt-6-astra",
    "SINGULAR_CODEX_L2_REASONING_EFFORT":"high",
    "SINGULAR_CODEX_AUDITOR_REASONING_EFFORT":"medium",
    "SINGULAR_CODEX_SERVICE_TIER":"",
    "SINGULAR_TASKS_DIR":"tasks custom",
    "SINGULAR_STATE_DIR":"state custom"
  }
}
JSON
cat >"$repo/config dir/runtime.sh" <<'SH'
SINGULAR_RUNNER="$SINGULAR_ENGINE_HOME/engine/gemini-run.sh"
SINGULAR_GEMINI_MODEL="shell-model"
SINGULAR_TASKS_DIR="shell-tasks"
SINGULAR_STATE_DIR="shell-state"
export SINGULAR_RUNNER SINGULAR_GEMINI_MODEL SINGULAR_TASKS_DIR SINGULAR_STATE_DIR
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/custom-runner/codex-run.sh"
chmod +x "$repo/custom-runner/codex-run.sh"
cat >"$repo/config dir/local.sh" <<'SH'
SINGULAR_GEMINI_MODEL=""
SINGULAR_TASKS_DIR="local-tasks"
SINGULAR_STATE_DIR="local-state"
SINGULAR_DIAGNOSTIC_SECRET="must-not-escape"
export SINGULAR_GEMINI_MODEL SINGULAR_TASKS_DIR SINGULAR_STATE_DIR SINGULAR_DIAGNOSTIC_SECRET
SH

before="$(find "$repo" -path "$repo/.git" -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256)"

selector="config dir/custom.json"
shell_selector="config dir/runtime.sh"
local_selector="config dir/local.sh"
doctor_json="$(cd / && env SINGULAR_JSON_CONFIG_FILE="$selector" \
  SINGULAR_CONFIG_FILE="$shell_selector" SINGULAR_LOCAL_CONFIG_FILE="$local_selector" \
  SINGULAR_CODEX_BIN=/bin/true HOME="$tmp/home" \
  python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$repo" \
    --bash "${BASH:-/bin/bash}" --bash-version "${BASH_VERSION:-5.0}" --json 2>/dev/null || true)"
console_json="$(cd / && env SINGULAR_JSON_CONFIG_FILE="$selector" \
  SINGULAR_CONFIG_FILE="$shell_selector" SINGULAR_LOCAL_CONFIG_FILE="$local_selector" \
  SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN=/bin/true \
  python3 "$ROOT/plugin/scripts/singular_graph_server.py" \
    --repo "$repo" --config)"
effective_json="$(cd / && env SINGULAR_JSON_CONFIG_FILE="$selector" \
  SINGULAR_CONFIG_FILE="$shell_selector" SINGULAR_LOCAL_CONFIG_FILE="$local_selector" \
  SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN=/bin/true \
  bash -c 'source "$1/engine/lib.sh" >/dev/null; singular_effective_configuration_json' _ "$ROOT")"
cli_json="$(cd "$repo" && env SINGULAR_JSON_CONFIG_FILE="$selector" \
  SINGULAR_CONFIG_FILE="$shell_selector" SINGULAR_LOCAL_CONFIG_FILE="$local_selector" \
  SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN=/bin/true \
  bash "$ROOT/cli/singular" health --json)"

python3 - "$doctor_json" "$console_json" "$effective_json" "$cli_json" \
  "$repo/config dir/custom.json" <<'PY' \
  || fail "CLI, doctor and console did not resolve the same custom config"
import json, os, sys
doctor, console, effective, cli = map(json.loads, sys.argv[1:5])
path = os.path.realpath(sys.argv[5])
check = next(item for item in doctor["checks"] if item["id"] == "repo.config")
assert check["status"] == "pass", check
assert check["details"]["path"] == path, check
assert check["details"]["source"] == "selector", check
assert console["configuration"] == {"path": path, "source": "selector", "status": "ok"}, console
assert doctor["effectiveConfiguration"] == effective, (doctor["effectiveConfiguration"], effective)
assert cli["effectiveConfiguration"] == effective, cli
assert effective["configuration"] == console["configuration"], (effective, console)
assert effective["configurationLayers"]["shell"] == os.path.join(os.path.dirname(os.path.dirname(path)), "config dir/runtime.sh"), effective
assert effective["configurationLayers"]["local"] == os.path.join(os.path.dirname(os.path.dirname(path)), "config dir/local.sh"), effective
assert effective["paths"] == console["paths"], (effective, console)
assert effective["provider"] == console["provider"] == "gemini", (effective, console)
assert effective["runner"].endswith("/engine/gemini-run.sh"), effective
assert console["runner"] == effective["runner"], console
assert effective["paths"]["tasks"] == os.path.join(os.path.dirname(os.path.dirname(path)), "local-tasks"), effective
assert effective["paths"]["state"] == os.path.join(os.path.dirname(os.path.dirname(path)), "local-state"), effective
for role in ("implementer", "auditor"):
    assert effective["roles"][role]["model"] in (None, ""), effective
    assert effective["roles"][role]["reasoningEffort"] is None, effective
    assert effective["roles"][role]["model"] == console["roles"][role]["model"]
    assert effective["roles"][role]["reasoningEffort"] == console["roles"][role]["effort"]
blob = json.dumps([doctor, console, effective, cli])
assert "must-not-escape" not in blob, blob
PY

after="$(find "$repo" -path "$repo/.git" -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256)"
[[ "$before" == "$after" ]] || fail "diagnostic entrypoints mutated fixture state"

custom_json="$(env SINGULAR_ENGINE_HOME="$ROOT" \
  SINGULAR_RUNNER="$repo/custom-runner/codex-run.sh" \
  python3 "$ROOT/engine/provider_resolver.py" effective-config --repo "$repo" \
    --environment-effective)"
python3 - "$custom_json" "$repo/custom-runner/codex-run.sh" <<'PY' \
  || fail "custom runner was guessed to be a shipped provider"
import json, os, sys
doc = json.loads(sys.argv[1])
assert doc["runner"] == os.path.realpath(sys.argv[2]), doc
assert doc["provider"] == "unknown", doc
assert all(role["model"] is None and role["reasoningEffort"] is None
           for role in doc["roles"].values()), doc
PY

custom_doctor="$(env SINGULAR_ENGINE_HOME="$ROOT" \
  SINGULAR_RUNNER="$repo/custom-runner/codex-run.sh" HOME="$tmp/home" \
  python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$repo" \
    --bash /opt/homebrew/bin/bash --bash-version 5.3 --json 2>/dev/null || true)"
python3 - "$custom_doctor" <<'PY' || fail "doctor guessed provider from custom basename"
import json, sys
report = json.loads(sys.argv[1])
selected = next(row for row in report["checks"] if row["id"] == "runner.selected")
assert selected["details"]["provider"] == "custom", selected
assert report["effectiveConfiguration"]["provider"] == "unknown", report
assert report["effectiveConfiguration"]["roles"], report
assert all(row["model"] is None for row in report["effectiveConfiguration"]["roles"].values())
assert not any(row["id"].startswith("model.selection.") for row in report["checks"]), report
PY

absent_repo="$tmp/absent optional"
mkdir -p "$absent_repo/shell state" "$absent_repo/local tasks" \
  "$absent_repo/docs/orchestration"
git -C "$absent_repo" init -q
git -C "$absent_repo" -c user.name=test -c user.email=test@example.com \
  commit -q --allow-empty -m init
printf '%s\n' '{"schema":"singular.orchestration.dag.v0","nodes":[]}' \
  >"$absent_repo/docs/orchestration/dag.v0.json"
printf '%s\n' "export SINGULAR_STATE_DIR='shell state' SINGULAR_CODEX_MODEL='shell-model'" \
  >"$absent_repo/singular.config.sh"
printf '%s\n' "export SINGULAR_TASKS_DIR='local tasks'" \
  >"$absent_repo/shell state/config.local.sh"
absent_doctor="$(cd / && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
  SINGULAR_CODEX_BIN=/bin/true python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" \
  --repo-root "$absent_repo" --bash /opt/homebrew/bin/bash --bash-version 5.3 \
  --json 2>/dev/null || true)"
absent_console="$(cd / && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
  SINGULAR_CODEX_BIN=/bin/true python3 "$ROOT/plugin/scripts/singular_graph_server.py" \
  --repo "$absent_repo" --config)"
python3 - "$absent_doctor" "$absent_console" "$absent_repo" <<'PY' \
  || fail "absent optional JSON became an explicit selector"
import json, os, sys
doctor, console = map(json.loads, sys.argv[1:3])
root = os.path.realpath(sys.argv[3])
for view in (doctor["effectiveConfiguration"], console):
    assert view["configuration"]["status"] == "absent", view
    assert view["configuration"]["source"] == "default", view
    assert view["paths"]["state"] == os.path.join(root, "shell state"), view
    assert view["paths"]["tasks"] == os.path.join(root, "local tasks"), view
    assert view["roles"]["implementer"]["model"] == "shell-model", view
repo_check = next(row for row in doctor["checks"] if row["id"] == "repo.config")
assert repo_check["status"] == "warn", repo_check
load = next(row for row in doctor["checks"] if row["id"] == "runtime.config-load")
assert load["status"] == "pass", load
PY

for bad in missing.json malformed.json; do
  [[ "$bad" != malformed.json ]] || printf '{bad\n' >"$repo/$bad"
  report="$(env SINGULAR_JSON_CONFIG_FILE="$bad" SINGULAR_CODEX_BIN=/bin/true \
    python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$repo" \
      --bash "${BASH:-/bin/bash}" --bash-version "${BASH_VERSION:-5.0}" --json 2>/dev/null || true)"
  python3 - "$report" "$repo/$bad" <<'PY' || fail "$bad did not fail actionably"
import json, os, sys
report = json.loads(sys.argv[1])
item = next(row for row in report["checks"] if row["id"] == "repo.config")
assert item["status"] == "fail", item
assert os.path.realpath(sys.argv[2]) in item["message"], item
PY
done

# Failed configuration never lends authority to inherited defaults or guessed
# lifecycle roots. Exercise the actual fresh-process doctor, console and CLI
# entrypoints for ordinary errexit failures as well as explicit exits and bad
# selected JSON.
PY=/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12
BASH_BIN=/opt/homebrew/bin/bash
for mode in malformed missing-selected shell-false shell-exit local-false local-exit; do
  bad_repo="$tmp/failure-$mode"
  mkdir -p "$bad_repo/docs/orchestration/tasks" "$bad_repo/.singular-state/runs" \
    "$bad_repo/.singular-state/leases" "$bad_repo/json tasks" "$bad_repo/json state"
  git -C "$bad_repo" init -q
  git -C "$bad_repo" -c user.name=test -c user.email=test@example.com \
    commit -q --allow-empty -m init
  printf '%s\n' '{"schema":"singular.orchestration.dag.v0","nodes":[]}' \
    >"$bad_repo/docs/orchestration/dag.v0.json"
  printf '%s\n' '{"schemaVersion":"v2","runner":"codex-run.sh","env":{"SINGULAR_CODEX_MODEL":"json-model","SINGULAR_TASKS_DIR":"json tasks","SINGULAR_STATE_DIR":"json state"}}' \
    >"$bad_repo/singular.config.json"
  selector_args=()
  local_args=()
  case "$mode" in
    malformed) printf '%s\n' '{bad' >"$bad_repo/singular.config.json" ;;
    missing-selected) selector_args=(SINGULAR_JSON_CONFIG_FILE=missing.json) ;;
    shell-false) printf '%s\n' false >"$bad_repo/singular.config.sh" ;;
    shell-exit) printf '%s\n' 'exit 7' >"$bad_repo/singular.config.sh" ;;
    local-false)
      printf '%s\n' false >"$bad_repo/local.sh"
      local_args=(SINGULAR_LOCAL_CONFIG_FILE=local.sh)
      ;;
    local-exit)
      printf '%s\n' 'exit 8' >"$bad_repo/local.sh"
      local_args=(SINGULAR_LOCAL_CONFIG_FILE=local.sh)
      ;;
  esac
  common=(env PYTHONDONTWRITEBYTECODE=1 HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
    SINGULAR_CODEX_BIN=/definitely/missing SINGULAR_CODEX_MODEL=inherited-model \
    "${selector_args[@]}" "${local_args[@]}")
  set +e
  (cd / && "${common[@]}" "$PY" "$ROOT/engine/doctor.py" --engine-home "$ROOT" \
    --repo-root "$bad_repo" --bash "$BASH_BIN" --bash-version 5.3 --json \
    >"$tmp/$mode-doctor.json" 2>"$tmp/$mode-doctor.stderr")
  doctor_rc=$?
  (cd / && "${common[@]}" "$PY" "$ROOT/plugin/scripts/singular_graph_server.py" \
    --repo "$bad_repo" --config >"$tmp/$mode-console.json" 2>"$tmp/$mode-console.stderr")
  console_rc=$?
  (cd / && "${common[@]}" "$PY" "$ROOT/plugin/scripts/singular_graph_server.py" \
    --repo "$bad_repo" --lifecycle >"$tmp/$mode-lifecycle.json" 2>"$tmp/$mode-lifecycle.stderr")
  lifecycle_rc=$?
  (cd "$bad_repo" && "${common[@]}" "$BASH_BIN" "$ROOT/cli/singular" health --json \
    >"$tmp/$mode-cli.stdout" 2>"$tmp/$mode-cli.stderr")
  cli_rc=$?
  set -e
  [[ "$doctor_rc" -eq 1 ]] || fail "$mode doctor exited $doctor_rc, expected 1"
  [[ "$console_rc" -eq 0 && "$lifecycle_rc" -eq 0 ]] \
    || fail "$mode console entrypoint failed unexpectedly"
  [[ "$cli_rc" -ne 0 ]] || fail "$mode CLI health fabricated a successful startup"
  "$PY" - "$mode" "$tmp/$mode-doctor.json" "$tmp/$mode-console.json" \
    "$tmp/$mode-lifecycle.json" <<'PY' || fail "$mode exposed authority after failed resolution"
import json, sys
mode = sys.argv[1]
doctor, console, lifecycle = (
    json.load(open(path, encoding="utf-8")) for path in sys.argv[2:5]
)
effective = doctor["effectiveConfiguration"]
for view in (effective, console):
    assert view["configuration"]["status"] == "error", (mode, view)
    assert view["provider"] == "unknown", (mode, view)
    assert view["runner"] is None, (mode, view)
    assert view["roles"] == {}, (mode, view)
    assert view["paths"].get("tasks") is None, (mode, view)
    assert view["paths"].get("state") is None, (mode, view)
assert effective["generation"]["status"] == "unavailable", (mode, effective)
assert console["generation"]["status"] == "unavailable", (mode, console)
assert lifecycle["paths"] == {}, (mode, lifecycle)
assert lifecycle["sources"] == {"runs":"unknown","leases":"unknown","tasks":"unknown"}, (mode, lifecycle)
assert lifecycle["unknownRecords"], (mode, lifecycle)
config_load = next(row for row in doctor["checks"] if row["id"] == "runtime.config-load")
assert config_load["status"] == "fail", (mode, config_load)
for ident in ("runner.selected", "provider.executable", "model.availability", "governance.posture"):
    rows = [row for row in doctor["checks"] if row["id"] == ident]
    assert rows and all(row["status"] == "skip" for row in rows), (mode, ident, rows)
PY
done

echo "PASS: test-effective-config-parity"
