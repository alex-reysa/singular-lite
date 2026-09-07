#!/usr/bin/env bash
# PMGO-006: `singular setup` — one idempotent path from "a repository" to a
# verified, STOPPED repository.
#
# What is actually being pinned here is the safety ordering, not the happy path:
#
#   * STOP is the FIRST thing written into the repo, and setup never removes it;
#   * authoritative historical gates are hashed BEFORE a migration can run, and
#     verified SEMANTICALLY afterwards — the v0-to-v1 namespace rebrand rewrites
#     gate bytes legitimately, so a hash comparison would condemn every correct
#     migration, while a flipped `status` must be caught and named;
#   * prerequisites fail before mutation, each with a stable code and one
#     recovery action;
#   * a second run repeats no migration, rewrites no config, and still ends in a
#     coherent state;
#   * there is EXACTLY ONE `Next:` line, always.
#
# Doctor is host-sensitive (it probes the selected provider's real executable),
# so fixtures that must reach `validated` pin a stub provider through
# .singular-state/config.local.sh — the operator override lib.sh sources last.
# Nothing here ever starts the real full suite: every run passes --no-test
# except where the absence of a run is the thing being asserted.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/cli/singular"
ENGINE_VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
ENGINE_SCHEMA="$(tr -d '[:space:]' <"$ROOT/SCHEMA_VERSION")"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected [$2] in [$1]"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want [$2] got [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

json_field() { # file dotted.path
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, field = sys.argv[1:3]
try:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
except (OSError, ValueError) as exc:
    print("<%s>" % exc)
    raise SystemExit(0)
for part in field.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
print("" if value is None else value)
PY
}

# A provider executable that is always present and always authenticated, so
# doctor's provider probes describe THIS fixture instead of this laptop.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/codex" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.0.0-stub" ;;
  *) echo "stub" ;;
esac
exit 0
SH
chmod +x "$stub_bin/codex"

new_repo() { # dir
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" checkout -q -b main
  printf 'seed\n' >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" -c user.name=test -c user.email=test@example.local commit -q -m init
}

# .singular-state/config.local.sh is sourced after singular.config.json, so it is
# the one place a fixture can pin the provider a migrated config will select.
pin_stub_provider() { # repo [engine-home]
  local engine_home="${2:-$ROOT}"
  mkdir -p "$1/.singular-state"
  cat >"$1/.singular-state/config.local.sh" <<SH
export SINGULAR_RUNNER="$engine_home/engine/codex-run.sh"
export SINGULAR_CODEX_BIN="$stub_bin/codex"
SH
}

# Minimal installable-looking engine, in the style of tests/test-versioning.sh's
# make_engine: enough for pin resolution, cmd_migrate, and nothing more.
make_engine() { # dir version schemaVersion
  mkdir -p "$1/engine" "$1/schemas" "$1/migrations" "$1/templates"
  echo "$2" >"$1/VERSION"
  echo "$3" >"$1/SCHEMA_VERSION"
  : >"$1/engine/lib.sh"
}

write_config() { # path schemaVersion [key=json ...]
  python3 - "$@" <<'PY'
import json
import sys

path, schema_version = sys.argv[1:3]
config = {
    "schemaVersion": schema_version,
    "targetBranch": "main",
    "gateCommand": "true",
    "areas": {},
}
for pair in sys.argv[3:]:
    key, _, raw = pair.partition("=")
    config[key] = json.loads(raw)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY
}

write_gate() { # repo node status [schemaNamespace]
  local ns="${4:-singular}"
  mkdir -p "$1/docs/orchestration/gates/logs"
  printf 'fixture gate log\n' >"$1/docs/orchestration/gates/logs/$2.log"
  python3 - "$1/docs/orchestration/gates/$2.gate-result.json" "$2" "$3" "$ns" \
    "$1/docs/orchestration/gates/logs/$2.log" <<'PY'
import hashlib
import json
import sys

path, node, status, namespace, log = sys.argv[1:6]
with open(log, "rb") as handle:
    log_sha = hashlib.sha256(handle.read()).hexdigest()
document = {
    "schema": "%s.orchestration.gate-result.v0" % namespace,
    "node": node,
    "status": status,
    "authoritative": True,
    "evidenceClass": "deterministic-proof",
    "evidence": [
        {
            "kind": "command-log",
            "ref": "%s-gate" % node,
            "command": "true",
            "exitCode": 0,
            "logRef": "docs/orchestration/gates/logs/%s.log" % node,
            "sha256": log_sha,
            "headSha": "0" * 40,
        }
    ],
    "decidedBy": "operator:fixture",
    "rationale": "historical verdict recorded before this engine existed",
    "recordedAt": "2026-01-02T03:04:05Z",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
}

write_dag() { # repo node...
  mkdir -p "$1/docs/orchestration"
  local repo="$1"; shift
  python3 - "$repo/docs/orchestration/dag.v0.json" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
nodes = [
    {
        "id": node,
        "stage": "M0",
        "area": "core",
        "layer": "scaffold",
        "kind": "build",
        "dependsOn": [],
        "requiredCompletion": "fixture node %s" % node,
    }
    for node in sys.argv[2:]
]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"schema": "singular.orchestration.dag.v0", "nodes": nodes},
              handle, indent=2)
    handle.write("\n")
PY
}

setup() { # repo [args...]
  local repo="$1"; shift
  (
    cd "$repo" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
      bash "$CLI" setup "$@" 2>&1
  )
}
mkdir -p "$tmp/home"

# --- (a) a fresh repository reaches `validated` in one command ----------------
repo_a="$tmp/a"
new_repo "$repo_a"
pin_stub_provider "$repo_a"
out="$(setup "$repo_a" --no-test)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(a) setup --no-test should exit 0 (rc=$rc)\n$out"
[[ -f "$repo_a/.singular-state/STOP" ]] || fail "(a) STOP was not written"
assert_eq "$(tr -d '[:space:]' <"$repo_a/.singular-version")" "$ENGINE_VERSION" "(a) .singular-version"
[[ -f "$repo_a/singular.config.json" ]] || fail "(a) scaffold did not write singular.config.json"
[[ -f "$repo_a/docs/orchestration/dag.v0.json" ]] || fail "(a) scaffold did not write the starter DAG"
[[ -d "$repo_a/schemas/orchestration" ]] || fail "(a) scaffold did not mirror schemas"
assert_eq "$(json_field "$repo_a/.singular-state/setup/state.json" state)" "validated" "(a) setup state"
assert_eq "$(json_field "$repo_a/.singular-state/setup/state.json" schema)" "singular.setup-state.v0" "(a) state schema"
next_lines="$(printf '%s\n' "$out" | grep -c '^Next: ')"
assert_eq "$next_lines" "1" "(a) exactly one Next: line (got: $(printf '%s\n' "$out" | grep '^Next: '))"
assert_contains "$out" "STOP written" "(a) STOP reported as created"
assert_contains "$out" "State: validated (STOP active; no workers dispatched)" "(a) state line"
# `validated` must never be dressed up as stopped-ready without a passing run.
assert_not_contains "$out" "State: stopped-ready" "(a) --no-test cannot reach stopped-ready"

# The legacy state root is mirrored only when it already exists (see (g)).
[[ ! -e "$repo_a/.pmgo-state" ]] || fail "(a) setup created a legacy .pmgo-state/ root"

# --- (b) historical gates survive a real v0 -> v2 migration -------------------
# Started at v0 deliberately: v1-to-v2 never rewrites gate bytes, so only the
# v0-to-v1 namespace rebrand can exercise the "byte change, no semantic change"
# path this verification exists to tolerate.
repo_b="$tmp/b"
new_repo "$repo_b"
pin_stub_provider "$repo_b"
write_config "$repo_b/singular.config.json" v0
write_dag "$repo_b" alpha beta
write_gate "$repo_b" alpha passed pmgo
write_gate "$repo_b" beta failed pmgo
gate_alpha_before="$(sha "$repo_b/docs/orchestration/gates/alpha.gate-result.json")"
git -C "$repo_b" add -A
git -C "$repo_b" -c user.name=test -c user.email=test@example.local commit -q -m v0

out="$(setup "$repo_b" --no-test)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(b) setup on a v0 repo should exit 0 (rc=$rc)\n$out"
assert_contains "$out" "2 gate-result file(s) hashed" "(b) snapshot covers both gates"
assert_contains "$out" "repository migrated to schema $ENGINE_SCHEMA" "(b) migration reached the engine schema"
assert_eq "$(json_field "$repo_b/singular.config.json" schemaVersion)" "$ENGINE_SCHEMA" "(b) config schemaVersion"
assert_contains "$out" "2 gate(s) semantically preserved" "(b) semantic verification passed"
assert_contains "$out" "byte-rewritten (namespace rebrand — informational)" "(b) byte deltas are informational"

snapshot="$repo_b/.singular-state/setup/gates-pre-migrate.json"
[[ -f "$snapshot" ]] || fail "(b) no gate snapshot was written"
assert_eq "$(json_field "$snapshot" schema)" "singular.setup.gate-snapshot.v0" "(b) snapshot schema"
python3 - "$snapshot" "$gate_alpha_before" <<'PY' || fail "(b) snapshot did not record hashes and verdicts"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    snapshot = json.load(handle)
gates = {entry["path"]: entry for entry in snapshot["gates"]}
alpha = gates["docs/orchestration/gates/alpha.gate-result.json"]
assert alpha["sha256"] == sys.argv[2], (alpha["sha256"], sys.argv[2])
assert alpha["node"] == "alpha" and alpha["status"] == "passed", alpha
assert alpha["authoritative"] is True, alpha
assert alpha["recordedAt"] == "2026-01-02T03:04:05Z", alpha
assert gates["docs/orchestration/gates/beta.gate-result.json"]["status"] == "failed"
assert snapshot["count"] == 2 and snapshot["headCommit"], snapshot
PY
# The rebrand really did change the bytes — otherwise (b) proves nothing.
[[ "$(sha "$repo_b/docs/orchestration/gates/alpha.gate-result.json")" != "$gate_alpha_before" ]] \
  || fail "(b) fixture did not exercise a byte-level gate rewrite"
grep -q '"status": "passed"' "$repo_b/docs/orchestration/gates/alpha.gate-result.json" \
  || fail "(b) migration changed a historical verdict"
verification="$repo_b/.singular-state/setup/gate-verification.json"
python3 - "$verification" <<'PY' || fail "(b) gate verification evidence is wrong"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["checked"] == 2, report
assert report["semanticDeltas"] == [], report
assert len(report["byteRewrittenInformational"]) == 2, report
PY

# --- (c) a migration that flips a historical verdict is caught and named ------
repo_c="$tmp/c"
new_repo "$repo_c"
write_config "$repo_c/singular.config.json" v0
write_gate "$repo_c" alpha failed
engine_c="$tmp/engine-tamper"
make_engine "$engine_c" "9.0.0" v1
cat >"$engine_c/migrations/v0-to-v1.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$1/docs/orchestration/gates/alpha.gate-result.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["status"] = "passed"          # the exact thing a migration may not do
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
PY
SH
chmod +x "$engine_c/migrations/v0-to-v1.sh"
out="$(cd "$repo_c" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$engine_c" bash "$CLI" setup --no-test 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "(c) a rewritten gate verdict must fail setup\n$out"
assert_contains "$out" "SINGULAR_GATE_PRESERVATION_FAILED" "(c) stable code"
assert_contains "$out" "alpha.gate-result.json" "(c) the offending file is named"
assert_contains "$out" "status" "(c) the offending field is named"
assert_contains "$out" "gates-pre-migrate.json" "(c) recovery points at the snapshot"
assert_eq "$(json_field "$repo_c/.singular-state/setup/last-result.json" code)" \
  "SINGULAR_GATE_PRESERVATION_FAILED" "(c) persisted failure code"
assert_eq "$(json_field "$repo_c/.singular-state/setup/last-result.json" schema)" \
  "singular.operator-failure.v0" "(c) persisted failure schema"
assert_eq "$(json_field "$repo_c/.singular-state/setup/state.json" state)" "installed" \
  "(c) the ladder stops where it truthfully got to"
[[ -f "$repo_c/.singular-state/STOP" ]] || fail "(c) STOP must exist even on a failed run"

# --- (d) a second run repeats nothing ----------------------------------------
config_before="$(sha "$repo_b/singular.config.json")"
gate_before="$(sha "$repo_b/docs/orchestration/gates/alpha.gate-result.json")"
out="$(setup "$repo_b" --no-test)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(d) rerun should exit 0 (rc=$rc)\n$out"
assert_contains "$out" "STOP already present" "(d) STOP is not rewritten"
assert_contains "$out" "singular.config.json exists — init not re-run" "(d) scaffold is skipped"
assert_contains "$out" "matches engine schema — nothing to migrate" "(d) no duplicate migration"
assert_not_contains "$out" "repository migrated to schema" "(d) migration did not run twice"
assert_eq "$(sha "$repo_b/singular.config.json")" "$config_before" "(d) config is byte-identical"
assert_eq "$(sha "$repo_b/docs/orchestration/gates/alpha.gate-result.json")" "$gate_before" \
  "(d) gate files are byte-identical"
[[ -f "$repo_b/.singular-state/STOP" ]] || fail "(d) STOP disappeared across a rerun"
assert_eq "$(json_field "$repo_b/.singular-state/setup/state.json" state)" "validated" "(d) state stays coherent"
assert_eq "$(printf '%s\n' "$out" | grep -c '^Next: ')" "1" "(d) still exactly one Next: line"

# --- (h) --json success: one object, on stdout, with a next action ------------
stdout_only="$(cd "$repo_b" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
  bash "$CLI" setup --no-test --json 2>/dev/null)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(h) setup --json should exit 0 (rc=$rc)"
python3 - "$stdout_only" <<'PY' || fail "(h) --json stdout is not one valid setup report"
import json
import sys

report = json.loads(sys.argv[1])   # json.loads rejects a second object outright
assert report["schema"] == "singular.setup-report.v0", report["schema"]
assert report["state"] == "validated", report["state"]
assert report["steps"], "steps must not be empty"
assert {"id", "status", "detail"} == set(report["steps"][0]), report["steps"][0]
assert report["nextAction"]["command"], report["nextAction"]
assert report["nextAction"]["instruction"], report["nextAction"]
assert report["safeToActuate"] is False, report
assert report["engineVersion"] and report["schemaVersion"], report
PY

# --- (e) a pin that is not installed, and cannot be downloaded ----------------
repo_e="$tmp/e"
new_repo "$repo_e"
echo "9.9.9" >"$repo_e/.singular-version"
scoped_home="$tmp/home-empty"
mkdir -p "$scoped_home"
stdout_only="$(cd "$repo_e" && env -u SINGULAR_ENGINE_HOME HOME="$scoped_home" \
  bash "$CLI" setup --no-test --json 2>/dev/null)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "(e) an uninstallable pin must fail"
python3 - "$stdout_only" <<'PY' || fail "(e) --json stdout is not one valid operator failure"
import json
import sys

failure = json.loads(sys.argv[1])
assert failure["schema"] == "singular.operator-failure.v0", failure["schema"]
assert failure["code"] == "SINGULAR_ENGINE_NOT_INSTALLED", failure["code"]
assert failure["safeToActuate"] is False, failure
assert failure["phase"] and failure["state"], failure
assert failure["recovery"]["command"] and failure["recovery"]["instruction"], failure
assert "no download mechanism" in failure["recovery"]["instruction"], failure["recovery"]
assert "install.sh" in failure["recovery"]["instruction"], failure["recovery"]
PY
# Nothing was written: engine resolution fails before the first repo write.
[[ ! -e "$repo_e/.singular-state" ]] || fail "(e) a prerequisite failure mutated the repository"

# --- (f) a schema this engine has no migration for ---------------------------
repo_f="$tmp/f"
new_repo "$repo_f"
write_config "$repo_f/singular.config.json" v9
engine_f="$tmp/engine-nomig"
make_engine "$engine_f" "9.0.0" "$ENGINE_SCHEMA"
out="$(cd "$repo_f" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$engine_f" bash "$CLI" setup --no-test 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "(f) a missing migration must fail setup\n$out"
assert_contains "$out" "SINGULAR_MIGRATION_MISSING" "(f) stable code"
assert_contains "$out" "no migration found for v9" "(f) names the unreachable step"
assert_eq "$(json_field "$repo_f/.singular-state/setup/last-result.json" code)" \
  "SINGULAR_MIGRATION_MISSING" "(f) persisted failure code"
assert_eq "$(json_field "$repo_f/singular.config.json" schemaVersion)" "v9" \
  "(f) a refused migration must not advance schemaVersion"

# --- (g) the legacy state root is mirrored, never created --------------------
repo_g="$tmp/g"
new_repo "$repo_g"
pin_stub_provider "$repo_g"
mkdir -p "$repo_g/.pmgo-state"
out="$(setup "$repo_g" --no-test)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(g) setup should exit 0 (rc=$rc)\n$out"
[[ -f "$repo_g/.pmgo-state/STOP" ]] || fail "(g) STOP was not mirrored into the legacy state root"
assert_contains "$out" "STOP mirrored into the legacy state root" "(g) the mirror is reported"
# ...and the repo that never had one still does not (asserted for repo_a above,
# re-asserted here so the pair reads as one claim).
[[ ! -e "$repo_a/.pmgo-state" ]] || fail "(g) a legacy state root was conjured into a clean repo"

# --- (i) a pending human decision outranks setup's own next action -----------
repo_i="$tmp/i"
new_repo "$repo_i"
pin_stub_provider "$repo_i"
mkdir -p "$repo_i/docs/orchestration/human-gates"
cat >"$repo_i/docs/orchestration/human-gates/G100.request.json" <<'JSON'
{
  "gateId": "G100",
  "node": "orchestration-control-repair",
  "approvalType": "operator",
  "requiredOwner": "operator@example.local"
}
JSON
out="$(setup "$repo_i" --no-test)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(i) setup should exit 0 (rc=$rc)\n$out"
assert_eq "$(printf '%s\n' "$out" | grep -c '^Next: ')" "1" "(i) exactly one Next: line"
assert_contains "$out" "Next: singular human-gate status G100" "(i) the pending gate is the next action"
assert_not_contains "$out" "approve-actuation" "(i) no invented verb"

# An answered request goes back to being nobody's next action.
cat >"$repo_i/docs/orchestration/human-gates/G100.approval.json" <<'JSON'
{"gateId": "G100", "decision": "approved"}
JSON
out="$(setup "$repo_i" --no-test)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(i) setup should exit 0 after approval (rc=$rc)\n$out"
assert_not_contains "$out" "human-gate status" "(i) an answered gate is not still pending"
assert_eq "$(printf '%s\n' "$out" | grep -c '^Next: ')" "1" "(i) still exactly one Next: line"

# --- (j) an engine home that cannot run its own suite ------------------------
#
# The regression suite needs real Git history and disposable worktrees, so it
# runs only from an engine CHECKOUT — and an installed engine is a plain
# `cp -Rp` tree with neither. That is a fact about the engine, not a defect in
# the repository being prepared, so setup reports it with its stable code and
# stops the ladder at the state it truthfully reached (`validated`) rather than
# failing a repository whose every own step passed. The next action must be one
# that can actually record a passing run: pointing at a bare `singular test` here
# would send the operator at a command that refuses.
#
# Both shapes are covered, because they are different codes:
#   j1  an installed engine (no tests/ at all)   -> SINGULAR_TEST_SUITE_UNAVAILABLE
#   j2  a suite present in a non-checkout tree   -> SINGULAR_TEST_SOURCE_UNSUPPORTED

# Exercise install.sh itself in isolated storage. Putting the disposable bin on
# PATH takes the installer's existing "already on PATH" branch, so it never
# attempts its optional /usr/local/bin convenience link.
run_installer() { # source singular-home
  local source="$1" singular_home="$2"
  mkdir -p "$singular_home/bin"
  env HOME="$tmp/home" SINGULAR_HOME="$singular_home" \
    PATH="$singular_home/bin:$PATH" bash "$source/install.sh" 2>&1
}

installed_payload_contract() { # installed engine root
  [[ ! -e "$1/tests" ]] || {
    echo "installed payload unexpectedly contains tests/" >&2
    return 1
  }
  [[ ! -e "$1/.git" ]] || {
    echo "installed payload unexpectedly contains .git" >&2
    return 1
  }
}

install_home="$tmp/install-home"
install_out="$(run_installer "$ROOT" "$install_home")"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(j) real installer failed in isolated storage (rc=$rc)\n$install_out"
assert_not_contains "$install_out" "also linked /usr/local/bin/singular" \
  "(j) isolated installer must not create a machine-global link"
engine_installed="$install_home/versions/$ENGINE_VERSION"
[[ -x "$install_home/bin/singular" ]] || fail "(j) installer did not create its scoped launcher"
[[ "$(readlink "$install_home/current")" == "$engine_installed" ]] \
  || fail "(j) installer current link does not select the installed engine"
installed_payload_contract "$engine_installed" \
  || fail "(j1) real installed payload violated the runtime payload contract"

# Additive payload directories are legitimate. Build a disposable source tree,
# add a harmless vendor sentinel to its install loop, and prove the real
# installer preserves it without weakening the exclusions above.
installer_variant="$tmp/installer-variant"
mkdir -p "$installer_variant"
cp -Rp "$ROOT/." "$installer_variant/"
mkdir -p "$installer_variant/vendor"
printf 'TASK-1009 harmless vendor sentinel\n' \
  >"$installer_variant/vendor/TASK-1009-sentinel.txt"
python3 - "$installer_variant/install.sh" vendor <<'PY'
import sys

path, item = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    source = handle.read()
needle = "for item in "
assert needle in source, "installer payload loop not found"
source = source.replace(needle, "%s%s " % (needle, item), 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(source)
PY

additive_home="$tmp/install-home-additive"
install_out="$(run_installer "$installer_variant" "$additive_home")"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(j) additive installer variant failed (rc=$rc)\n$install_out"
engine_additive="$additive_home/versions/$ENGINE_VERSION"
installed_payload_contract "$engine_additive" \
  || fail "(j) additive installed payload violated the runtime payload contract"
[[ "$(cat "$engine_additive/vendor/TASK-1009-sentinel.txt")" == \
    "TASK-1009 harmless vendor sentinel" ]] \
  || fail "(j) additive vendor sentinel was not preserved by the installer"

repo_j="$tmp/j"
new_repo "$repo_j"
pin_stub_provider "$repo_j" "$engine_installed"
# NOT --no-test: the default path is the one that used to die at step 13.
out="$(cd "$repo_j" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$engine_installed" \
  bash "$install_home/bin/singular" setup 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(j1) an engine that cannot self-test must not fail a good repo (rc=$rc)\n$out"
assert_contains "$out" "SINGULAR_TEST_SUITE_UNAVAILABLE" "(j1) the stable code is still reported"
assert_contains "$out" "State: validated" "(j1) the ladder stops at the state actually reached"
assert_not_contains "$out" "State: stopped-ready" "(j1) no passing run means no stopped-ready"
assert_eq "$(printf '%s\n' "$out" | grep -c '^Next: ')" "1" "(j1) exactly one Next: line"
assert_contains "$out" "Next: SINGULAR_ENGINE_HOME=<engine checkout> singular test" \
  "(j1) the next action names the checkout, not a command that would refuse"
assert_eq "$(json_field "$repo_j/.singular-state/setup/state.json" state)" "validated" "(j1) persisted state"
[[ -f "$repo_j/.singular-state/STOP" ]] || fail "(j1) STOP must still be in place"
# Nothing was started, so nothing may have been recorded.
[[ ! -e "$repo_j/.singular-state/test-runs" ]] || fail "(j1) a refused suite created run state"

# The code also has to survive into the machine-readable report, as a warning —
# a consumer reading only --json must be able to see why stopped-ready was not
# reached without parsing the human stream.
stdout_only="$(cd "$repo_j" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$engine_installed" \
  bash "$install_home/bin/singular" setup --json 2>/dev/null)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(j1) setup --json should exit 0 (rc=$rc)"
python3 - "$stdout_only" <<'PY' || fail "(j1) --json did not carry the suite verdict"
import json
import sys

report = json.loads(sys.argv[1])
assert report["state"] == "validated", report["state"]
assert report["safeToActuate"] is False, report
codes = [w["code"] for w in report["warnings"]]
assert "SINGULAR_TEST_SUITE_UNAVAILABLE" in codes, codes
assert report["lastTestRunId"] is None, report["lastTestRunId"]
step = next(s for s in report["steps"] if s["id"] == "test")
assert step["status"] == "skip", step
assert "<engine checkout>" in report["nextAction"]["command"], report["nextAction"]
PY

# j2: a negative installer variant deliberately ships tests/. The same payload
# contract must reject it, while setup still reports the stable non-checkout
# suite warning when this deliberately invalid runtime is exercised.
python3 - "$installer_variant/install.sh" tests <<'PY'
import sys

path, item = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    source = handle.read()
needle = "for item in "
assert needle in source, "installer payload loop not found"
source = source.replace(needle, "%s%s " % (needle, item), 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(source)
PY
unsafe_home="$tmp/install-home-with-tests"
install_out="$(run_installer "$installer_variant" "$unsafe_home")"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(j2) negative installer variant did not install (rc=$rc)\n$install_out"
engine_nogit="$unsafe_home/versions/$ENGINE_VERSION"
[[ -f "$engine_nogit/tests/run.sh" ]] || fail "(j2) fixture must ship the suite"
[[ ! -e "$engine_nogit/.git" ]] || fail "(j2) fixture must not be a Git checkout"
if installed_payload_contract "$engine_nogit" >/dev/null 2>&1; then
  fail "(j2) payload contract accepted an installed engine that ships tests/"
fi

repo_j2="$tmp/j2"
new_repo "$repo_j2"
pin_stub_provider "$repo_j2" "$engine_nogit"
out="$(cd "$repo_j2" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$engine_nogit" \
  bash "$unsafe_home/bin/singular" setup 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "(j2) a non-checkout engine must not fail a good repo (rc=$rc)\n$out"
assert_contains "$out" "SINGULAR_TEST_SOURCE_UNSUPPORTED" "(j2) the source code is reported"
assert_contains "$out" "State: validated" "(j2) the ladder stops at validated"
assert_eq "$(printf '%s\n' "$out" | grep -c '^Next: ')" "1" "(j2) exactly one Next: line"
[[ ! -e "$repo_j2/.singular-state/test-runs" ]] || fail "(j2) a refused suite created run state"

# --- (k) STOP is written BEFORE anything else, proved by ORDER not presence ---
#
# Every other case asserts that STOP exists, which a run that wrote it LAST
# would also satisfy: a scratch mutation moving the scaffold write ahead of the
# STOP write passed the entire suite. STOP-first is the single most
# safety-relevant ordering claim in this command — everything after it happens
# in a repository that cannot dispatch a worker — so it needs a case that can
# only pass in one order.
#
# Mechanism (deterministic on macOS: pure filesystem permissions, no timing, no
# mtimes, no probes of setup's internals). Build a repository where the scaffold
# write MUST fail and the STOP write MUST succeed, run setup, and look at what
# exists afterwards:
#
#   .singular-state/  created, left writable   -> STOP can always be written
#   repository root  chmod a-w                -> cmd_init's first cp cannot be
#   .singular-version pre-written              -> step 7 writes nothing, so the
#                                                pin guard does not fire first
#                                                and the run reaches the scaffold
#
#   STOP first     => STOP exists, singular.config.json does not.  (asserted)
#   Scaffold first => the scaffold fails before STOP is ever written, so STOP
#                     does not exist and this case fails.
#
# Presence alone cannot tell those apart. Order is the only thing measured here.
if [[ "$(id -u)" -ne 0 ]]; then
  repo_k="$tmp/k"
  new_repo "$repo_k"
  pin_stub_provider "$repo_k"
  mkdir -p "$repo_k/.singular-state/setup"
  printf '%s\n' "$ENGINE_VERSION" >"$repo_k/.singular-version"
  [[ ! -e "$repo_k/singular.config.json" ]] || fail "(k) fixture must be unscaffolded"
  [[ ! -e "$repo_k/.singular-state/STOP" ]] || fail "(k) fixture must not pre-create STOP"
  chmod a-w "$repo_k"
  out="$(cd "$repo_k" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
    bash "$CLI" setup --no-test 2>&1)"
  rc=$?
  chmod u+w "$repo_k"

  [[ "$rc" -ne 0 ]] || fail "(k) an unscaffoldable repository must fail setup\n$out"
  assert_contains "$out" "SINGULAR_REPO_UNWRITABLE" "(k) the scaffold refusal is coded"
  assert_contains "$out" "Phase: scaffold" "(k) the run really did reach the scaffold step"
  # The ordering claim itself.
  [[ -f "$repo_k/.singular-state/STOP" ]] \
    || fail "(k) STOP is not written FIRST: setup failed at the scaffold having never written it"
  assert_contains "$out" "STOP written" "(k) and this run wrote it, rather than inheriting one"
  # ...and the step it must precede genuinely did not happen, so the fixture
  # measured an order rather than a coincidence.
  [[ ! -e "$repo_k/singular.config.json" ]] || fail "(k) fixture did not actually block the scaffold"
  [[ ! -e "$repo_k/docs" ]] || fail "(k) fixture did not actually block the scaffold"
fi

# --- (l) every repo write is guarded, including the version pin --------------
#
# The pin write was the one `cp` in setup with no SINGULAR_REPO_UNWRITABLE guard:
# on a read-only repository root it printed a raw `cp: Permission denied` and
# exited 1 with no code, no recovery and no Next: line — and under --json it
# emitted ZERO bytes, where the contract is exactly one operator-failure.v0
# object.
#
# The fixture makes the pin write the FIRST failing write, deterministically:
# .singular-state/ is created (and stays writable) before the root is sealed, so
# step 6 can still create its setup/ dir and write STOP, and .singular-version is
# absent so step 7 must write into the read-only root.
#
# Ordered AFTER (k) on purpose: both fixtures seal the repository root, so a
# regression in setup's write ORDER shows up in both. (k) is the case that can
# say what actually broke, so it must be the one that speaks first.
if [[ "$(id -u)" -ne 0 ]]; then
  repo_l="$tmp/l"
  new_repo "$repo_l"
  pin_stub_provider "$repo_l"
  mkdir -p "$repo_l/.singular-state/setup"
  [[ ! -e "$repo_l/.singular-version" ]] || fail "(l) fixture must not already carry a pin"
  chmod a-w "$repo_l"
  stdout_only="$(cd "$repo_l" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
    bash "$CLI" setup --no-test --json 2>/dev/null)"
  rc=$?
  stderr_only="$(cd "$repo_l" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
    bash "$CLI" setup --no-test 2>&1 >/dev/null)"
  chmod u+w "$repo_l"

  [[ "$rc" -ne 0 ]] || fail "(l) an unwritable repository root must fail setup"
  [[ -n "$stdout_only" ]] || fail "(l) --json emitted no bytes on stdout"
  python3 - "$stdout_only" <<'PY' || fail "(l) --json stdout is not exactly one operator failure"
import json
import sys

# json.loads rejects trailing content outright, so this also proves "exactly
# one object" rather than merely "starts with one".
failure = json.loads(sys.argv[1])
assert failure["schema"] == "singular.operator-failure.v0", failure["schema"]
assert failure["code"] == "SINGULAR_REPO_UNWRITABLE", failure["code"]
assert failure["phase"] == "version-pin", failure["phase"]
assert failure["safeToActuate"] is False, failure
assert failure["recovery"]["command"] and failure["recovery"]["instruction"], failure
assert ".singular-version" in failure["summary"], failure["summary"]
PY
  # The human stream leads with the code, exactly like every other refusal —
  # never a raw `cp:` diagnostic from the shell.
  assert_contains "$stderr_only" "SINGULAR_REPO_UNWRITABLE" "(l) human output leads with the code"
  assert_contains "$stderr_only" "Recovery: " "(l) human output carries one recovery action"
  assert_not_contains "$stderr_only" "Permission denied" "(l) the raw cp error must not leak"
  assert_eq "$(json_field "$repo_l/.singular-state/setup/last-result.json" code)" \
    "SINGULAR_REPO_UNWRITABLE" "(l) persisted failure code"
  # STOP was written before the refusal — the repository is stopped, not half-set-up.
  [[ -f "$repo_l/.singular-state/STOP" ]] || fail "(l) STOP must exist even on a failed run"
fi

# --- (m) a refusal is the ONLY thing on the failure path ---------------------
#
# Two ways raw machine text used to reach the operator ahead of, or inside, the
# one coded diagnosis this command promises.

# m1: a gate that became unreadable between snapshot and verification raised
# straight out of the verifier, so a Python traceback printed on stderr
# immediately BEFORE the SINGULAR_GATE_PRESERVATION_FAILED block. It must fail
# closed — an unverifiable gate is never a preserved gate — but say so once, in
# the contract's own shape.
if [[ "$(id -u)" -ne 0 ]]; then
  repo_m="$tmp/m"
  new_repo "$repo_m"
  write_config "$repo_m/singular.config.json" v0
  write_gate "$repo_m" alpha passed
  engine_m="$tmp/engine-unreadable"
  make_engine "$engine_m" "9.0.0" v1
  cat >"$engine_m/migrations/v0-to-v1.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
chmod 000 "$1/docs/orchestration/gates/alpha.gate-result.json"
SH
  chmod +x "$engine_m/migrations/v0-to-v1.sh"
  out="$(cd "$repo_m" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$engine_m" \
    bash "$CLI" setup --no-test 2>&1)"
  rc=$?
  chmod u+r "$repo_m/docs/orchestration/gates/alpha.gate-result.json" 2>/dev/null || true

  [[ "$rc" -ne 0 ]] || fail "(m1) an unverifiable gate must fail setup\n$out"
  assert_contains "$out" "SINGULAR_GATE_PRESERVATION_FAILED" "(m1) fails closed, with the code"
  assert_contains "$out" "alpha.gate-result.json" "(m1) the unreadable gate is named"
  assert_not_contains "$out" "Traceback (most recent call last)" "(m1) no interpreter traceback may leak"
  assert_not_contains "$out" 'File "<stdin>"' "(m1) no interpreter frame may leak"
  python3 - "$repo_m/.singular-state/setup/gate-verification.json" <<'PY' \
    || fail "(m1) the unreadable gate is not recorded as a delta"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
fields = [d["field"] for d in report["semanticDeltas"]]
assert "readability" in fields, report["semanticDeltas"]
PY
fi

# m2: doctor messages end in a captured probe's output, and a provider that
# fails while printing JSON put `... probe failed (exit 1): {` — a bare opening
# brace — into the operator's one-line summary.
broken_bin="$tmp/bin-broken"
mkdir -p "$broken_bin"
cat >"$broken_bin/codex" <<'SH'
#!/usr/bin/env bash
printf '{\n  "error": "packaged native executable ENOENT"\n}\n' >&2
exit 1
SH
chmod +x "$broken_bin/codex"

repo_m2="$tmp/m2"
new_repo "$repo_m2"
mkdir -p "$repo_m2/.singular-state"
cat >"$repo_m2/.singular-state/config.local.sh" <<SH
export SINGULAR_RUNNER="$ROOT/engine/codex-run.sh"
export SINGULAR_CODEX_BIN="$broken_bin/codex"
SH
stdout_only="$(cd "$repo_m2" && env HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ROOT" \
  bash "$CLI" setup --no-test --json 2>/dev/null)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "(m2) a broken selected provider must fail setup"
python3 - "$stdout_only" "$repo_m2/.singular-state/setup/doctor.json" <<'PY' \
  || fail "(m2) the operator summary still carries a raw fragment"
import json
import sys

failure = json.loads(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as handle:
    report = json.load(handle)

# The fixture is only meaningful if doctor really did produce the raw shape.
raw = [c["message"] for c in report["checks"]
       if c["message"].rstrip().endswith(("{", "[", ":"))]
assert raw, "fixture produced no dangling machine fragment for setup to clean up"

summary = failure["summary"]
assert summary, failure
assert "\n" not in summary, repr(summary)
assert not summary.rstrip().endswith(("{", "[", "(", ",", ":")), repr(summary)
PY

echo "setup tests passed"
