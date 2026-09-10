#!/usr/bin/env bash
# AXON-001: two configuration sources describe the same knob and disagree.
#
# `resources.maxConcurrent: 3` and `env: {"SINGULAR_MAX_CONCURRENT": "2"}` both
# set the dispatch cap. engine/lib.sh emits structured fields first and the
# env{} map last, and the eval applies them in that order — so the legacy env
# entry silently wins and the operator who raised the structured field keeps
# running at the old concurrency. doctor must name the disagreement, both
# values, and which one actually takes effect.
#
# The check reads the REAL generator's emission rather than re-deriving the
# structured->env mapping, so these cases also pin that behavior: a key emitted
# twice with equal values is not a conflict, and an env{} key with no structured
# counterpart is not one either.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
fakehome="$tmp/home"
mkdir -p "$repo/schemas/orchestration" "$fakehome"
for schema in "$ROOT"/schemas/*.schema.json; do
  cp "$schema" "$repo/schemas/orchestration/"
done
git -C "$tmp" init -q repo
git -C "$repo" config user.email conflict@example.com
git -C "$repo" config user.name conflict
git -C "$repo" commit -q --allow-empty -m init

# The engine's own schemaVersion, so the mismatch cascade never masks this check.
esv="$(tr -d '[:space:]' <"$ROOT/SCHEMA_VERSION")"

# write_config <python literal for "resources"> <python literal for "controlState">
#              <python literal for "env">
write_config() {
  python3 - "$repo/singular.config.json" "$esv" "$1" "$2" "$3" <<'PY'
import ast, json, sys
path, schema_version, resources, control_state, env = sys.argv[1:]
data = {
    "schemaVersion": schema_version,
    "targetBranch": "main",
    "gateCommand": "true",
}
for key, raw in (
    ("resources", resources),
    ("controlState", control_state),
    ("env", env),
):
    value = ast.literal_eval(raw)
    if value:
        data[key] = value
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

conflict_check() {
  local report
  report="$(
    cd "$repo" \
      && env HOME="$fakehome" SINGULAR_ENGINE_HOME="$ROOT" \
        bash "$ROOT/cli/singular" doctor --json 2>/dev/null
  )" || true
  [[ -n "$report" ]] || fail "doctor produced no JSON report"
  python3 - "$report" <<'PY'
import json, sys
checks = json.loads(sys.argv[1])["checks"]
matches = [item for item in checks if item["id"] == "config.source-conflict"]
if len(matches) != 1:
    raise SystemExit("expected exactly one config.source-conflict entry, got %d" % len(matches))
print(json.dumps(matches[0]))
PY
}

# --- (a) structured 3 vs legacy env 2: the env{} map wins, so say so ----------
write_config "{'maxConcurrent': 3}" "{}" "{'SINGULAR_MAX_CONCURRENT': '2'}"
check="$(conflict_check)" || exit 1
python3 - "$check" <<'PY' || exit 1
import json, sys
item = json.loads(sys.argv[1])
assert item["status"] == "warn", item
assert "SINGULAR_MAX_CONCURRENT" in item["message"], item["message"]
for token in ("3", "2"):
    assert token in item["message"], (token, item["message"])
assert "effective 2" in item["message"], item["message"]
remediation = item["remediation"]
assert "remove the legacy env override" in remediation.lower(), remediation
assert "align it with the structured field" in remediation, remediation
assert "explicit operator approval" in remediation, remediation
config = item.get("details", {}).get("config")
if config is not None:
    assert config in item["message"], item
    assert remediation.startswith(f"Update {config}:"), remediation
conflicts = item["details"]["conflicts"]
assert len(conflicts) == 1, conflicts
entry = conflicts[0]
assert entry["key"] == "SINGULAR_MAX_CONCURRENT", entry
assert entry["structuredValue"] == "3", entry
assert entry["envValue"] == "2", entry
assert entry["effective"] == "2", entry
# The loaded runtime agrees with the winner named above; nothing else overrode it.
assert not entry.get("runtimeDiffers"), entry
PY

# --- (b) same knob, same value: agreement is not a conflict -------------------
write_config "{'maxConcurrent': 3}" "{}" "{'SINGULAR_MAX_CONCURRENT': '3'}"
check="$(conflict_check)" || exit 1
python3 - "$check" <<'PY' || exit 1
import json, sys
item = json.loads(sys.argv[1])
assert item["status"] == "pass", item
message = item["message"]
assert message.startswith("no conflicting configuration sources"), message
config = item.get("details", {}).get("config")
if config is not None:
    assert message == f"no conflicting configuration sources in {config}", message
assert item["details"]["conflicts"] == [], item["details"]
PY

# --- (c) an env{} key with no structured counterpart is not a conflict --------
write_config "{'maxConcurrent': 3}" "{}" "{'SINGULAR_CODEX_MODEL': 'gpt-5.6-sol'}"
check="$(conflict_check)" || exit 1
python3 - "$check" <<'PY' || exit 1
import json, sys
item = json.loads(sys.argv[1])
assert item["status"] == "pass", item
assert item["details"]["conflicts"] == [], item["details"]
PY

# --- (d) two conflicting knobs at once: report both, not the first -----------
# controlState.commitIntervalSeconds -> SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC
# and resources.maxConcurrent -> SINGULAR_MAX_CONCURRENT (engine/lib.sh,
# singular_json_config_to_env).
write_config \
  "{'maxConcurrent': 3}" \
  "{'commitIntervalSeconds': 300}" \
  "{'SINGULAR_MAX_CONCURRENT': '2', 'SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC': '60'}"
check="$(conflict_check)" || exit 1
python3 - "$check" <<'PY' || exit 1
import json, sys
item = json.loads(sys.argv[1])
assert item["status"] == "warn", item
conflicts = {entry["key"]: entry for entry in item["details"]["conflicts"]}
assert set(conflicts) == {
    "SINGULAR_MAX_CONCURRENT",
    "SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC",
}, sorted(conflicts)
assert conflicts["SINGULAR_MAX_CONCURRENT"]["structuredValue"] == "3"
assert conflicts["SINGULAR_MAX_CONCURRENT"]["effective"] == "2"
assert conflicts["SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC"]["structuredValue"] == "300"
assert conflicts["SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC"]["effective"] == "60"
for key in conflicts:
    assert key in item["message"], (key, item["message"])
PY

# --- (e) a THIRD source beats the winner named above -------------------------
# .singular-state/config.local.sh is sourced after the JSON eval, so the value
# doctor derives from the generator is not necessarily the one the run uses.
# Naming the wrong effective value would be its own AXON-001.
mkdir -p "$repo/.singular-state"
printf 'export SINGULAR_MAX_CONCURRENT=7\n' >"$repo/.singular-state/config.local.sh"
write_config "{'maxConcurrent': 3}" "{}" "{'SINGULAR_MAX_CONCURRENT': '2'}"
check="$(conflict_check)" || exit 1
rm -rf "$repo/.singular-state"
python3 - "$check" <<'PY' || exit 1
import json, sys
item = json.loads(sys.argv[1])
assert item["status"] == "warn", item
entry = item["details"]["conflicts"][0]
assert entry["effective"] == "2", entry
assert entry["runtimeDiffers"] is True, entry
assert entry["runtimeValue"] == "7", entry
assert "the loaded runtime uses 7" in item["message"], item["message"]
PY

# TASK-1018: keep both the baseline and path-qualified producer contracts
# recognizable without depending on a historical worktree.  The same validator
# rejects missing meaning and a path that does not match details.config.
python3 - "$ROOT/tests/fixtures/config-conflict-diagnostics.json" <<'PY' || exit 1
import copy
import json
import sys

fixture = json.load(open(sys.argv[1], encoding="utf-8"))
selected = fixture["selectedConfig"]

def validate(item):
    if item.get("status") not in {"pass", "warn"}:
        return False
    details = item.get("details")
    if not isinstance(details, dict) or not isinstance(details.get("conflicts"), list):
        return False
    path = details.get("config")
    if path is not None:
        if path != selected or path not in str(item.get("message", "")):
            return False
    conflicts = details["conflicts"]
    if not conflicts:
        return str(item.get("message", "")).startswith(
            "no conflicting configuration sources"
        )
    remediation = str(item.get("remediation", ""))
    lower = remediation.lower()
    if not all(token in lower for token in (
        "remove the legacy env override",
        "align it with the structured field",
        "explicit operator approval",
    )):
        return False
    if path is not None and not remediation.startswith(f"Update {path}:"):
        return False
    for conflict in conflicts:
        if not all(key in conflict for key in (
            "key", "structuredValue", "envValue", "effective"
        )):
            return False
        for value in (
            conflict["key"], conflict["structuredValue"],
            conflict["envValue"], conflict["effective"],
        ):
            if str(value) not in str(item.get("message", "")):
                return False
    return True

for specimen in fixture["specimens"]:
    assert validate(specimen["diagnostic"]), specimen["name"]

producer = next(
    row["diagnostic"] for row in fixture["specimens"]
    if row["name"] == "producer-conflict"
)
mutations = []
for field in ("remediation", "message"):
    bad = copy.deepcopy(producer)
    bad[field] = ""
    mutations.append(bad)
for field in ("structuredValue", "envValue", "effective"):
    bad = copy.deepcopy(producer)
    bad["details"]["conflicts"][0].pop(field)
    mutations.append(bad)
bad = copy.deepcopy(producer)
bad["details"]["config"] = "/wrong/config.json"
mutations.append(bad)
bad = copy.deepcopy(producer)
bad["remediation"] = bad["remediation"].replace(
    "explicit operator approval", "automatic approval"
)
mutations.append(bad)
assert all(not validate(item) for item in mutations), mutations
PY

echo "PASS: test-config-conflict"
