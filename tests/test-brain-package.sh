#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Consumer and Git selectors must come only from this disposable fixture. Keep
# PATH, TMPDIR, and interpreter pins (notably SINGULAR_BASH_BIN) intact.
unset SINGULAR_ROOT SINGULAR_ENGINE_HOME SINGULAR_HOME \
  SINGULAR_ENGINE_DIR SINGULAR_SCHEMA_DIR SINGULAR_ORCH_DIR \
  SINGULAR_JSON_CONFIG_FILE SINGULAR_CONFIG_FILE SINGULAR_LOCAL_CONFIG_FILE \
  SINGULAR_STATE_DIR SINGULAR_WORKTREES_DIR SINGULAR_TASKS_DIR \
  SINGULAR_RUNS_DIR SINGULAR_EVENTS_FILE SINGULAR_CAMPAIGN_MANIFEST \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE \
  GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM

fail() { echo "brain-package test failed: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"; }
run_rc() {
  local result_var="$1"; shift
  local captured status=0
  captured="$({ "$@"; } 2>&1)" || status=$?
  printf -v "$result_var" '%s' "$captured"
  return "$status"
}

# Public behavior comes first: this was the intentional strict-test-first red
# against the integrated baseline, where `manifest` was an unknown command.
help="$(SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/cli/singular" manifest --help)"
for command in gen check lint bless; do
  assert_contains "$help" "manifest $command" "manifest help does not document $command"
done
assert_contains "$help" "brainConfig" "manifest help does not document opt-in configuration"
assert_contains "$help" "--config PATH takes precedence" "manifest help does not document precedence"
assert_contains "$help" "invocation directory" "manifest help does not document explicit path base"
assert_contains "$help" "relative to that JSON file" "manifest help does not document brainConfig path base"
assert_contains "$help" "description_unverified" "manifest help does not distinguish review state"

# The vendor record is self-checking, pinned, and honest about absent licensing.
( cd "$ROOT/vendor/singular-brain" && shasum -a 256 -c SHA256SUMS >/dev/null )
[[ "$(tr -d '[:space:]' <"$ROOT/vendor/singular-brain/VERSION")" == "0.2.0" ]] || fail "wrong vendored VERSION"
[[ "$(tr -d '[:space:]' <"$ROOT/vendor/singular-brain/SCHEMA_VERSION")" == "1" ]] || fail "wrong vendored SCHEMA_VERSION"
python3 - "$ROOT/vendor/singular-brain/PROVENANCE.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["sourceRevision"] == "e05f259be5cabda2bb8caa241f23cc1f48e9f059"
assert data["license"] is None
assert "no LICENSE" in data["licenseNote"]
PY

consumer="$tmp/consumer with spaces"
corpus="$consumer/corpus with spaces"
invoke="$consumer/invoke elsewhere"
mkdir -p "$consumer/config" "$invoke"
cp -Rp "$ROOT/tests/fixtures/singular-brain/knowledge-scope" "$corpus"
git -C "$consumer" init -q
cat >"$consumer/singular.config.json" <<EOF
{"schemaVersion":"v2","brainConfig":"missing-default.json","resources":{"maxConcurrent":2},"env":{"SINGULAR_MAX_CONCURRENT":"7"}}
EOF
cat >"$consumer/config/custom.json" <<EOF
{"schemaVersion":"v2","brainConfig":"../corpus with spaces/singular-brain.config.json","resources":{"maxConcurrent":4},"env":{"SINGULAR_MAX_CONCURRENT":"9"}}
EOF

manifest() {
  ( cd "$invoke" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
      bash "$ROOT/cli/singular" manifest "$@" )
}

# Real producer golden path from a different cwd whose path contains spaces.
manifest gen --scope knowledge
cmp "$corpus/docs/KNOWLEDGE.md" "$corpus/expected/KNOWLEDGE.md"
cmp "$corpus/docs/KNOWLEDGE.json" "$corpus/expected/KNOWLEDGE.json"
cmp "$corpus/docs/.knowledge-freshness.json" "$corpus/expected/.knowledge-freshness.json"
python3 - "$corpus/docs/KNOWLEDGE.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema"] == "singular-brain.manifest.v1"
assert len(data["entries"]) == 3
PY
manifest check --scope knowledge
manifest lint --scope knowledge

# Lint errors preserve upstream exit 1 and never rewrite generated state.
lint_source="$corpus/notes/decision-log.md"
cp "$lint_source" "$tmp/decision-log.valid.md"
python3 - "$lint_source" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("status: canonical", "status: invalid-review-state", 1), encoding="utf-8")
PY
before_lint_manifest="$(shasum -a 256 "$corpus/docs/KNOWLEDGE.json")"
before_lint_catalog="$(shasum -a 256 "$corpus/docs/KNOWLEDGE.md")"
before_lint_sidecar="$(shasum -a 256 "$corpus/docs/.knowledge-freshness.json")"
if run_rc output manifest lint --scope knowledge; then fail "invalid routing metadata passed lint"; else rc=$?; fi
[[ "$rc" -eq 1 ]] || fail "lint error should preserve upstream exit 1, got $rc"
assert_contains "$output" "invalid-review-state" "lint did not report the invalid routing metadata"
[[ "$before_lint_manifest" == "$(shasum -a 256 "$corpus/docs/KNOWLEDGE.json")" ]] || fail "lint error mutated generated manifest"
[[ "$before_lint_catalog" == "$(shasum -a 256 "$corpus/docs/KNOWLEDGE.md")" ]] || fail "lint error mutated generated catalog"
[[ "$before_lint_sidecar" == "$(shasum -a 256 "$corpus/docs/.knowledge-freshness.json")" ]] || fail "lint error mutated freshness state"
cp "$tmp/decision-log.valid.md" "$lint_source"

# Scope is forwarded, and explicit --config overrides a conflicting brainConfig.
output=""
if run_rc output manifest check --scope absent; then fail "unknown scope unexpectedly succeeded"; else rc=$?; fi
[[ "$rc" -eq 2 ]] || fail "unknown scope should preserve upstream exit 2, got $rc"
assert_contains "$output" "unknown scope" "scope was not forwarded to upstream"
( cd "$invoke" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$consumer/singular.config.json" \
    bash "$ROOT/cli/singular" manifest check --config "../corpus with spaces/singular-brain.config.json" --scope knowledge )

# Stale output is exit 1; malformed configuration is exit 2.
printf '\nmanual drift\n' >>"$corpus/docs/KNOWLEDGE.json"
if run_rc output manifest check; then fail "stale output unexpectedly passed check"; else rc=$?; fi
[[ "$rc" -eq 1 ]] || fail "stale check should preserve upstream exit 1, got $rc"
manifest gen
printf '{not json\n' >"$consumer/bad-brain.json"
if run_rc output bash -c 'cd "$1" && SINGULAR_ENGINE_HOME="$2" bash "$2/cli/singular" manifest gen --config "$3"' \
    _ "$invoke" "$ROOT" "$consumer/bad-brain.json"; then fail "invalid config unexpectedly succeeded"; else rc=$?; fi
[[ "$rc" -eq 2 ]] || fail "invalid config should preserve upstream exit 2, got $rc"

# Missing values and unsupported arguments fail before shell content runs.
for args in "gen --config" "gen --scope" "gen --all" "check unexpected-path"; do
  read -r -a words <<<"$args"
  if run_rc output manifest "${words[@]}"; then fail "invalid arguments succeeded: $args"; else rc=$?; fi
  [[ "$rc" -eq 2 ]] || fail "invalid arguments should exit 2: $args (got $rc)"
done
canary="$tmp/argument-was-evaluated"
payload="\$(touch $canary)"
if run_rc output manifest gen "$payload"; then fail "injection-shaped positional succeeded"; else rc=$?; fi
[[ "$rc" -eq 2 && ! -e "$canary" ]] || fail "manifest arguments were shell-evaluated"

# Body drift survives gen as review debt; only explicit bless clears it.
printf '\nBody changed after routing review.\n' >>"$corpus/notes/decision-log.md"
manifest gen
python3 - "$corpus/docs/KNOWLEDGE.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
entry = next(item for item in data["entries"] if item["path"] == "notes/decision-log.md")
assert entry["freshness"]["state"] == "description_unverified", entry
PY
manifest check
manifest bless --scope knowledge notes/decision-log.md
python3 - "$corpus/docs/KNOWLEDGE.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
entry = next(item for item in data["entries"] if item["path"] == "notes/decision-log.md")
assert entry["freshness"]["state"] == "clean", entry
PY

# Losing the ledger fails closed; explicit bless is the sole recovery path.
rm "$corpus/docs/.knowledge-freshness.json"
for command in gen check lint; do
  before="$(shasum -a 256 "$corpus/docs/KNOWLEDGE.json")"
  if run_rc output manifest "$command"; then fail "$command accepted a missing sidecar"; else rc=$?; fi
  [[ "$rc" -eq 2 ]] || fail "$command missing-sidecar exit should be 2, got $rc"
  [[ "$before" == "$(shasum -a 256 "$corpus/docs/KNOWLEDGE.json")" ]] || fail "$command mutated generated output"
  [[ ! -e "$corpus/docs/.knowledge-freshness.json" ]] || fail "$command regenerated the sidecar"
done
manifest bless --all --scope knowledge
manifest check
manifest lint

# Doctor selects the same custom JSON and remains read-only.
before_manifest="$(shasum -a 256 "$corpus/docs/KNOWLEDGE.json")"
before_sidecar="$(shasum -a 256 "$corpus/docs/.knowledge-freshness.json")"
( cd "$consumer" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    bash "$ROOT/cli/singular" doctor --json >"$tmp/doctor.json" ) || true
python3 - "$tmp/doctor.json" "$corpus/singular-brain.config.json" "$consumer/config/custom.json" <<'PY'
import json, os, sys
by_id = {item["id"]: item for item in json.load(open(sys.argv[1]))["checks"]}
check = by_id["brain.configuration"]
assert check["status"] == "pass", check
assert check["details"]["config"] == os.path.realpath(sys.argv[2]), check
conflict = by_id["config.source-conflict"]
assert conflict["status"] == "warn", conflict
selected = os.path.realpath(sys.argv[3])
assert conflict["details"]["config"] == selected, conflict
assert selected in conflict["message"] and selected in conflict["remediation"], conflict
values = {item["key"]: item for item in conflict["details"]["conflicts"]}["SINGULAR_MAX_CONCURRENT"]
assert values["structuredValue"] == "4", values
assert values["envValue"] == "9" and values["effective"] == "9", values
PY
[[ "$before_manifest" == "$(shasum -a 256 "$corpus/docs/KNOWLEDGE.json")" ]] || fail "doctor regenerated manifest"
[[ "$before_sidecar" == "$(shasum -a 256 "$corpus/docs/.knowledge-freshness.json")" ]] || fail "doctor changed ledger"

printf '{"schemaVersion":"v2","brainConfig":"does-not-exist.json"}\n' >"$consumer/config/missing-brain.json"
( cd "$consumer" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$consumer/config/missing-brain.json" \
    python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/missing-config-doctor.json" ) || true
python3 - "$tmp/missing-config-doctor.json" <<'PY'
import json, sys
check = {i["id"]: i for i in json.load(open(sys.argv[1]))["checks"]}["brain.configuration"]
assert check["status"] == "fail" and "configuration is missing" in check["message"], check
PY
printf '{"schemaVersion":"v2","brainConfig":"../bad-brain.json"}\n' >"$consumer/config/invalid-brain.json"
( cd "$consumer" && SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$consumer/config/invalid-brain.json" \
    python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/invalid-config-doctor.json" ) || true
python3 - "$tmp/invalid-config-doctor.json" <<'PY'
import json, sys
check = {i["id"]: i for i in json.load(open(sys.argv[1]))["checks"]}["brain.configuration"]
assert check["status"] == "fail" and "configuration is invalid" in check["message"], check
assert "did not generate or bless" in check["remediation"], check
PY

# Feature-off doctor leaves Node optional; configured brain requires it.
printf '{"schemaVersion":"v2"}\n' >"$consumer/config/off.json"
no_node="$tmp/no-node-bin"; mkdir -p "$no_node"
for tool in bash git python3; do ln -s "$(command -v "$tool")" "$no_node/$tool"; done
( cd "$consumer" && PATH="$no_node" SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$consumer/config/off.json" \
    python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/off-doctor.json" ) || true
python3 - "$tmp/off-doctor.json" <<'PY'
import json, sys
by_id = {item["id"]: item for item in json.load(open(sys.argv[1]))["checks"]}
assert by_id["brain.configuration"]["status"] == "skip"
assert "brain.node" not in by_id
PY
( cd "$consumer" && PATH="$no_node" SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/node-doctor.json" ) || true
python3 - "$tmp/node-doctor.json" <<'PY'
import json, sys
by_id = {item["id"]: item for item in json.load(open(sys.argv[1]))["checks"]}
assert by_id["brain.node"]["status"] == "fail", by_id.get("brain.node")
assert "Install a usable Node.js" in by_id["brain.node"]["remediation"]
PY
bad_node="$tmp/bad-node-bin"; mkdir -p "$bad_node"
for tool in bash git python3; do ln -s "$(command -v "$tool")" "$bad_node/$tool"; done
printf '#!/bin/sh\necho unusable-node >&2\nexit 7\n' >"$bad_node/node"
chmod +x "$bad_node/node"
( cd "$consumer" && PATH="$bad_node" SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/unusable-node-doctor.json" ) || true
python3 - "$tmp/unusable-node-doctor.json" <<'PY'
import json, sys
by_id = {item["id"]: item for item in json.load(open(sys.argv[1]))["checks"]}
check = by_id["brain.node"]
assert check["status"] == "fail" and "unusable-node" in check["message"], check
PY

# Isolated installation includes and runs the full producer payload. PATH
# already contains its bin directory, preventing machine-global link changes.
install_home="$tmp/installed home"; mkdir -p "$install_home/bin"
PATH="$install_home/bin:$PATH" SINGULAR_HOME="$install_home" bash "$ROOT/install.sh" >"$tmp/install.log"
installed="$(cd "$install_home/current" && pwd -P)"
[[ -f "$installed/engine/brain_manifest.py" && -f "$installed/vendor/singular-brain/PROVENANCE.json" \
   && -f "$installed/vendor/singular-brain/SHA256SUMS" ]] || fail "installed producer payload is incomplete"
[[ ! -e "$installed/tests" && ! -e "$installed/.git" ]] || fail "installed payload shipped tests or Git metadata"
for command in gen check lint; do
  ( cd "$invoke" && env -u SINGULAR_ENGINE_HOME SINGULAR_HOME="$install_home" \
      SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
      bash "$install_home/bin/singular" manifest "$command" )
done
( cd "$invoke" && env -u SINGULAR_ENGINE_HOME SINGULAR_HOME="$install_home" \
    SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    bash "$install_home/bin/singular" manifest bless --all )

# Doctor diagnoses present-but-wrong-version and missing vendor payloads.
bad_home="$tmp/bad-installed"; cp -Rp "$installed" "$bad_home"
printf '9.9.9\n' >"$bad_home/vendor/singular-brain/VERSION"
( cd "$consumer" && SINGULAR_ENGINE_HOME="$bad_home" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    python3 "$bad_home/engine/doctor.py" --engine-home "$bad_home" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/bad-doctor.json" ) || true
python3 - "$tmp/bad-doctor.json" <<'PY'
import json, sys
check = {i["id"]: i for i in json.load(open(sys.argv[1]))["checks"]}["brain.runtime"]
assert check["status"] == "fail" and "version mismatch" in check["message"], check
assert "Reinstall" in check["remediation"], check
PY
schema_home="$tmp/schema-installed"; cp -Rp "$installed" "$schema_home"
printf '9\n' >"$schema_home/vendor/singular-brain/SCHEMA_VERSION"
( cd "$consumer" && SINGULAR_ENGINE_HOME="$schema_home" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    python3 "$schema_home/engine/doctor.py" --engine-home "$schema_home" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/schema-doctor.json" ) || true
python3 - "$tmp/schema-doctor.json" <<'PY'
import json, sys
check = {i["id"]: i for i in json.load(open(sys.argv[1]))["checks"]}["brain.runtime"]
assert check["status"] == "fail" and "schema mismatch" in check["message"], check
PY
partial_home="$tmp/partial-installed"; cp -Rp "$installed" "$partial_home"
rm "$partial_home/vendor/singular-brain/engine/hash.mjs"
( cd "$consumer" && SINGULAR_ENGINE_HOME="$partial_home" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    python3 "$partial_home/engine/doctor.py" --engine-home "$partial_home" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/partial-doctor.json" ) || true
python3 - "$tmp/partial-doctor.json" <<'PY'
import json, sys
check = {i["id"]: i for i in json.load(open(sys.argv[1]))["checks"]}["brain.runtime"]
assert check["status"] == "fail" and "payload is incomplete" in check["message"], check
PY
hash_home="$tmp/hash-installed"; cp -Rp "$installed" "$hash_home"
printf '\ntampered\n' >>"$hash_home/vendor/singular-brain/engine/hash.mjs"
( cd "$consumer" && SINGULAR_ENGINE_HOME="$hash_home" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    python3 "$hash_home/engine/doctor.py" --engine-home "$hash_home" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/hash-doctor.json" ) || true
python3 - "$tmp/hash-doctor.json" <<'PY'
import json, sys
check = {i["id"]: i for i in json.load(open(sys.argv[1]))["checks"]}["brain.runtime"]
assert check["status"] == "fail" and "hash mismatch" in check["message"], check
PY
missing_home="$tmp/missing-installed"; cp -Rp "$installed" "$missing_home"
rm -rf "$missing_home/vendor/singular-brain"
( cd "$consumer" && SINGULAR_ENGINE_HOME="$missing_home" SINGULAR_JSON_CONFIG_FILE="$consumer/config/custom.json" \
    python3 "$missing_home/engine/doctor.py" --engine-home "$missing_home" --repo-root "$consumer" \
      --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json >"$tmp/missing-doctor.json" ) || true
python3 - "$tmp/missing-doctor.json" <<'PY'
import json, sys
check = {i["id"]: i for i in json.load(open(sys.argv[1]))["checks"]}["brain.runtime"]
assert check["status"] == "fail" and "payload is missing" in check["message"], check
PY

# Future campaign identity covers vendor changes and brain config contents,
# while mutable outputs and generated caches are excluded.
python3 - "$ROOT" "$installed" "$consumer/config/custom.json" "$corpus" "$tmp" <<'PY'
import importlib.util, pathlib, shutil, sys
root, installed, singular_config, corpus, tmp = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("campaign_manifest", root / "engine/campaign_manifest.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
runtime = tmp / "fingerprint-runtime"; shutil.copytree(installed, runtime, symlinks=True)
base = module.source_fingerprint(str(runtime))
target = runtime / "vendor/singular-brain/engine/hash.mjs"
original = target.read_bytes(); target.write_bytes(original + b"\n")
assert module.source_fingerprint(str(runtime)) != base
target.write_bytes(original)
added = runtime / "vendor/singular-brain/engine/added.mjs"; added.write_text("added\n")
assert module.source_fingerprint(str(runtime)) != base
added.unlink()
removed = runtime / "vendor/singular-brain/engine/walk.mjs"; saved = removed.read_bytes(); removed.unlink()
assert module.source_fingerprint(str(runtime)) != base
removed.write_bytes(saved)
cache = runtime / "vendor/singular-brain/engine/__pycache__/ignored.pyc"
cache.parent.mkdir(); cache.write_bytes(b"cache")
assert module.source_fingerprint(str(runtime)) == base
identity = module.configured_brain_identity(str(singular_config))
brain_config = pathlib.Path(identity["path"]); original_config = brain_config.read_bytes()
brain_config.write_bytes(original_config + b" ")
assert module.configured_brain_identity(str(singular_config))["sha256"] != identity["sha256"]
brain_config.write_bytes(original_config)
same = module.configured_brain_identity(str(singular_config))["sha256"]
(corpus / "docs/KNOWLEDGE.json").write_text("generated drift\n")
(corpus / "docs/.knowledge-freshness.json").write_text("generated drift\n")
assert module.configured_brain_identity(str(singular_config))["sha256"] == same
PY

echo "brain-package tests passed"
