#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
CLI="$ENGINE_HOME/cli/singular"
BASH_BIN=/opt/homebrew/bin/bash
PYTHON_BIN=/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12
[[ -x "$BASH_BIN" ]] || { echo "missing pinned Bash: $BASH_BIN" >&2; exit 1; }
[[ -x "$PYTHON_BIN" ]] || { echo "missing pinned Python: $PYTHON_BIN" >&2; exit 1; }
PINNED_PATH="$(dirname "$PYTHON_BIN"):$(dirname "$BASH_BIN"):/usr/bin:/bin"

export PYTHONDONTWRITEBYTECODE=1

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing file $1"; }
assert_dir() { [[ -d "$1" ]] || fail "$2: missing dir $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

file_mode() {
  "$PYTHON_BIN" - "$1" <<'PY'
import os, stat, sys
print(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode))
PY
}

assert_mode_lacks() {
  local path="$1" forbidden="$2" label="$3" mode
  mode="$(file_mode "$path")"
  (( (mode & forbidden) == 0 )) \
    || fail "$label: mode $(printf '%04o' "$mode") includes $(printf '%04o' "$forbidden")"
}

assert_mode_exact() {
  local path="$1" expected="$2" label="$3" mode actual
  mode="$(file_mode "$path")"
  printf -v actual '%04o' "$mode"
  [[ "$actual" == "$expected" ]] \
    || fail "$label: want mode $expected got $actual"
}

tree_bytes_modes_digest() {
  "$PYTHON_BIN" - "$1" <<'PY'
import hashlib, os, stat, sys
root = os.path.abspath(sys.argv[1])
digest = hashlib.sha256()
root_info = os.lstat(root)
digest.update((1).to_bytes(4, "big")); digest.update(b".")
digest.update(stat.S_IFMT(root_info.st_mode).to_bytes(4, "big"))
digest.update(stat.S_IMODE(root_info.st_mode).to_bytes(4, "big"))
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    dirs.sort(); files.sort()
    for name in dirs + files:
        path = os.path.join(current, name)
        relative = os.path.relpath(path, root).encode()
        info = os.lstat(path)
        digest.update(len(relative).to_bytes(4, "big")); digest.update(relative)
        digest.update(stat.S_IFMT(info.st_mode).to_bytes(4, "big"))
        digest.update(stat.S_IMODE(info.st_mode).to_bytes(4, "big"))
        if stat.S_ISLNK(info.st_mode):
            raw = os.readlink(path).encode()
            digest.update(len(raw).to_bytes(8, "big")); digest.update(raw)
        elif stat.S_ISREG(info.st_mode):
            raw = open(path, "rb").read()
            digest.update(len(raw).to_bytes(8, "big")); digest.update(raw)
print(digest.hexdigest())
PY
}

json_file_field() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import json
import sys
path, field = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    value = json.load(f)
for part in field.split("."):
    value = value[part]
print(value)
PY
}

run_frozen_cli() { # umask repo frozen fixture-root command...
  local creation_mask="$1" repo="$2" frozen="$3" fixture_root="$4"
  shift 4
  (
    umask "$creation_mask"
    cd "$repo"
    env -u SINGULAR_CONFIG_FILE -u SINGULAR_LOCAL_CONFIG_FILE \
      -u SINGULAR_JSON_CONFIG_FILE -u SINGULAR_JSON_CONFIG_SOURCE \
      PATH="$PINNED_PATH" HOME="$fixture_root/home" \
      SINGULAR_HOME="$fixture_root/singular-home" \
      SINGULAR_ENGINE_HOME="$frozen" SINGULAR_BASH_BIN="$BASH_BIN" \
      "$BASH_BIN" "$frozen/cli/singular" "$@"
  )
}

new_git_repo() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" checkout -q -b main
  printf 'seed\n' >"$root/README.md"
  git -C "$root" add README.md
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

test_frozen_engine_creates_editable_consumer_copies_without_touching_existing_files() {
  local tmp frozen before_engine after_engine stub_bin mask expected_file expected_gate
  local repo out prompt marker report version_mode rc existing links setup_repo
  local config_sha config_mode prompt_sha prompt_mode gate_sha gate_mode pin_sha pin_mode
  local outside_sha before_targets after_targets setup_config_sha setup_prompt_sha setup_gate_sha
  tmp="$(mktemp -d)"
  frozen="$tmp/frozen-engine"
  stub_bin="$tmp/bin"
  mkdir -p "$frozen/cli"
  cp -R "$ENGINE_HOME/engine" "$ENGINE_HOME/schemas" "$ENGINE_HOME/templates" "$frozen/"
  cp "$ENGINE_HOME/cli/singular" "$frozen/cli/singular"
  cp "$ENGINE_HOME/VERSION" "$ENGINE_HOME/SCHEMA_VERSION" "$frozen/"
  chmod -R a-w "$frozen"
  before_engine="$(tree_bytes_modes_digest "$frozen")"

  mkdir -p "$stub_bin"
  cat >"$stub_bin/npm" <<'SH'
#!/usr/bin/env bash
printf 'deterministic local npm stub\n'
printf 'ran\n' >"$GATE_STUB_MARKER"
SH
  cat >"$stub_bin/codex" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.0.0-stub" ;;
  *) echo "stub" ;;
esac
exit 0
SH
  chmod +x "$stub_bin/npm" "$stub_bin/codex"

  # The actual public CLI copies the frozen payload under both common masks.
  # Every byte comparison happens before the owner edits the copy.
  for mask in 022 077; do
    if [[ "$mask" == "022" ]]; then
      expected_file=0644
      expected_gate=0755
    else
      expected_file=0600
      expected_gate=0700
    fi
    repo="$tmp/init-$mask"
    new_git_repo "$repo"
    out="$(run_frozen_cli "$mask" "$repo" "$frozen" "$tmp" init 2>&1)"
    assert_contains "$out" "singular init ->" "frozen-engine init succeeds under umask $mask"
    cmp -s "$frozen/templates/singular.config.json" "$repo/singular.config.json" \
      || fail "umask $mask consumer config differs from frozen template"
    assert_mode_exact "$repo/singular.config.json" "$expected_file" \
      "umask $mask config creation mode"
    for prompt in "$frozen"/templates/prompts/*.md; do
      cmp -s "$prompt" "$repo/docs/orchestration/prompts/$(basename "$prompt")" \
        || fail "umask $mask prompt differs from frozen template: $(basename "$prompt")"
      assert_mode_exact "$repo/docs/orchestration/prompts/$(basename "$prompt")" \
        "$expected_file" "umask $mask prompt creation mode: $(basename "$prompt")"
    done
    cmp -s "$frozen/templates/gate-adapter.sh" "$repo/docs/orchestration/gates/gate.sh" \
      || fail "umask $mask consumer gate differs from frozen template"
    assert_mode_exact "$repo/docs/orchestration/gates/gate.sh" "$expected_gate" \
      "umask $mask gate creation mode"
    cmp -s "$frozen/VERSION" "$repo/.singular-version" \
      || fail "umask $mask consumer version pin differs from frozen VERSION"
    assert_mode_exact "$repo/.singular-version" "$expected_file" \
      "umask $mask version-pin creation mode"

    # Schema contracts are mirrors, not editable templates. Their frozen mode
    # and bytes remain intact, proving init did not apply a blanket chmod.
    cmp -s "$frozen/schemas/orchestration/audit-verdict.v1.schema.json" \
      "$repo/schemas/orchestration/audit-verdict.v1.schema.json" \
      || fail "umask $mask schema mirror differs from frozen engine schema"
    assert_mode_lacks "$repo/schemas/orchestration/audit-verdict.v1.schema.json" 128 \
      "umask $mask schema mirror remains read-only"

    marker="$tmp/gate-$mask.ran"
    report="$tmp/gate-$mask.json"
    out="$(env PATH="$stub_bin:$PINNED_PATH" GATE_STUB_MARKER="$marker" \
      SINGULAR_GATE_REPORT_FILE="$report" \
      "$repo/docs/orchestration/gates/gate.sh" 2>&1)"
    assert_contains "$out" "deterministic local npm stub" \
      "umask $mask copied gate executes the local stub"
    assert_file "$marker" "umask $mask copied gate executed directly"
    assert_eq "$(json_file_field "$report" schema)" \
      "singular.orchestration.gate-observation.v0" "umask $mask gate report schema"
    assert_eq "$(json_file_field "$report" failures)" "[]" \
      "umask $mask local gate reports no failures"

    "$PYTHON_BIN" - "$repo/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    config = json.load(stream)
config["targetBranch"] = "owner-edited"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(config, stream, indent=2)
    stream.write("\n")
PY
    printf '\nowner edit\n' >>"$repo/docs/orchestration/prompts/auditor.md"
    assert_eq "$(json_file_field "$repo/singular.config.json" targetBranch)" \
      "owner-edited" "umask $mask owner edits config"
    assert_contains "$(tail -n 1 "$repo/docs/orchestration/prompts/auditor.md")" \
      "owner edit" "umask $mask owner edits prompt"

    version_mode="$(file_mode "$repo/.singular-version")"
    out="$(run_frozen_cli "$mask" "$repo" "$frozen" "$tmp" update 9.9.9 2>&1)"
    assert_contains "$out" "to engine 9.9.9 (.singular-version)" \
      "umask $mask update rewrites editable frozen pin"
    assert_eq "$(tr -d '[:space:]' <"$repo/.singular-version")" "9.9.9" \
      "umask $mask update writes requested pin"
    assert_eq "$(file_mode "$repo/.singular-version")" "$version_mode" \
      "umask $mask update preserves consumer pin mode"
    run_frozen_cli "$mask" "$repo" "$frozen" "$tmp" update 9.9.9 >/dev/null
    assert_eq "$(file_mode "$repo/.singular-version")" "$version_mode" \
      "umask $mask repeated update preserves pin mode"
  done

  # Pre-create writable directories, then mask owner-write at file creation.
  # Passing here requires the descriptor-local owner-write addition; merely
  # deleting the old pathname chmod would leave fresh copies at 0444/0555.
  repo="$tmp/owner-write-masked"
  new_git_repo "$repo"
  run_frozen_cli 022 "$repo" "$frozen" "$tmp" init >/dev/null
  rm "$repo/singular.config.json" "$repo/.singular-version" \
    "$repo/docs/orchestration/gates/gate.sh" \
    "$repo/docs/orchestration/prompts/"*.md
  chmod 0755 "$repo" "$repo/docs" "$repo/docs/orchestration" \
    "$repo/docs/orchestration/prompts" "$repo/docs/orchestration/tasks" \
    "$repo/docs/orchestration/areas" "$repo/docs/orchestration/gates"
  out="$(run_frozen_cli 200 "$repo" "$frozen" "$tmp" init 2>&1)"
  assert_contains "$out" "singular init ->" "owner-write-masked init succeeds"
  assert_mode_exact "$repo/singular.config.json" 0644 \
    "descriptor chmod restores only required config owner-write"
  assert_mode_exact "$repo/docs/orchestration/prompts/auditor.md" 0644 \
    "descriptor chmod restores only required prompt owner-write"
  assert_mode_exact "$repo/docs/orchestration/gates/gate.sh" 0755 \
    "descriptor chmod restores required gate owner-write/execute"
  assert_mode_exact "$repo/.singular-version" 0644 \
    "descriptor chmod restores only required pin owner-write"

  # A second consumer already owns each class of file. Init must preserve exact
  # bytes and modes while filling only the absent scaffold around them. Repeating
  # under a different umask must not normalize anything already present.
  existing="$tmp/existing"
  new_git_repo "$existing"
  mkdir -p "$existing/docs/orchestration/prompts" "$existing/docs/orchestration/gates"
  printf '%s\n' '{"schemaVersion":"v2","targetBranch":"main","gateCommand":"true","areas":{}}' \
    >"$existing/singular.config.json"
  printf 'existing auditor\n' >"$existing/docs/orchestration/prompts/auditor.md"
  printf '#!/bin/sh\nexit 7\n' >"$existing/docs/orchestration/gates/gate.sh"
  printf 'existing-pin\n' >"$existing/.singular-version"
  ln -s "$tmp/absent-reviewer-target" "$existing/docs/orchestration/prompts/reviewer.md"
  chmod 0640 "$existing/singular.config.json"
  chmod 0600 "$existing/docs/orchestration/prompts/auditor.md"
  chmod 0711 "$existing/docs/orchestration/gates/gate.sh"
  chmod 0440 "$existing/.singular-version"
  config_sha="$(shasum -a 256 "$existing/singular.config.json" | awk '{print $1}')"
  config_mode="$(file_mode "$existing/singular.config.json")"
  prompt_sha="$(shasum -a 256 "$existing/docs/orchestration/prompts/auditor.md" | awk '{print $1}')"
  prompt_mode="$(file_mode "$existing/docs/orchestration/prompts/auditor.md")"
  gate_sha="$(shasum -a 256 "$existing/docs/orchestration/gates/gate.sh" | awk '{print $1}')"
  gate_mode="$(file_mode "$existing/docs/orchestration/gates/gate.sh")"
  pin_sha="$(shasum -a 256 "$existing/.singular-version" | awk '{print $1}')"
  pin_mode="$(file_mode "$existing/.singular-version")"

  out="$(run_frozen_cli 077 "$existing" "$frozen" "$tmp" init 2>&1)"
  run_frozen_cli 022 "$existing" "$frozen" "$tmp" init >/dev/null
  assert_contains "$out" "skip  singular.config.json (exists)" "init reports preserved config"
  assert_eq "$(shasum -a 256 "$existing/singular.config.json" | awk '{print $1}')" "$config_sha" \
    "init preserves existing config bytes"
  assert_eq "$(file_mode "$existing/singular.config.json")" "$config_mode" \
    "init preserves existing config mode"
  assert_eq "$(shasum -a 256 "$existing/docs/orchestration/prompts/auditor.md" | awk '{print $1}')" "$prompt_sha" \
    "init preserves existing prompt bytes"
  assert_eq "$(file_mode "$existing/docs/orchestration/prompts/auditor.md")" "$prompt_mode" \
    "init preserves existing prompt mode"
  assert_eq "$(shasum -a 256 "$existing/docs/orchestration/gates/gate.sh" | awk '{print $1}')" "$gate_sha" \
    "init preserves existing gate bytes"
  assert_eq "$(file_mode "$existing/docs/orchestration/gates/gate.sh")" "$gate_mode" \
    "init preserves existing gate mode"
  assert_eq "$(shasum -a 256 "$existing/.singular-version" | awk '{print $1}')" "$pin_sha" \
    "init preserves existing pin bytes"
  assert_eq "$(file_mode "$existing/.singular-version")" "$pin_mode" \
    "init preserves existing pin mode"
  [[ -L "$existing/docs/orchestration/prompts/reviewer.md" ]] \
    || fail "init replaced an existing prompt symlink"
  assert_eq "$(readlink "$existing/docs/orchestration/prompts/reviewer.md")" \
    "$tmp/absent-reviewer-target" "init preserves dangling prompt symlink target"
  [[ ! -e "$tmp/absent-reviewer-target" ]] \
    || fail "init followed dangling prompt symlink outside the consumer path"

  set +e
  out="$(run_frozen_cli 077 "$existing" "$frozen" "$tmp" update 8.8.8 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "update made an existing read-only pin writable"
  assert_eq "$(shasum -a 256 "$existing/.singular-version" | awk '{print $1}')" "$pin_sha" \
    "failed update preserves read-only pin bytes"
  assert_eq "$(file_mode "$existing/.singular-version")" "$pin_mode" \
    "failed update preserves read-only pin mode"

  printf 'outside pin bytes\n' >"$tmp/outside-version-pin"
  outside_sha="$(shasum -a 256 "$tmp/outside-version-pin" | awk '{print $1}')"
  mv "$existing/.singular-version" "$existing/.singular-version.saved"
  ln -s "$tmp/outside-version-pin" "$existing/.singular-version"
  set +e
  out="$(run_frozen_cli 077 "$existing" "$frozen" "$tmp" update 8.8.8 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "update accepted a symlink version pin"
  assert_contains "$out" "refusing to overwrite symlink" "update rejects symlink version pin"
  assert_eq "$(shasum -a 256 "$tmp/outside-version-pin" | awk '{print $1}')" "$outside_sha" \
    "rejected update leaves symlink target bytes unchanged"

  # Live and dangling symlinks at every copy target are entries owned by the
  # consumer. Init must preserve the links and every external target.
  links="$tmp/links"
  mkdir -p "$tmp/link-targets"
  printf '%s\n' '{"schemaVersion":"v2","targetBranch":"main","gateCommand":"true","areas":{}}' \
    >"$tmp/link-targets/config.json"
  printf 'live prompt target\n' >"$tmp/link-targets/auditor.md"
  printf '#!/bin/sh\nexit 23\n' >"$tmp/link-targets/gate.sh"
  chmod 0640 "$tmp/link-targets/config.json" "$tmp/link-targets/auditor.md"
  chmod 0710 "$tmp/link-targets/gate.sh"
  before_targets="$(tree_bytes_modes_digest "$tmp/link-targets")"
  new_git_repo "$links"
  mkdir -p "$links/docs/orchestration/prompts" "$links/docs/orchestration/gates"
  ln -s "$tmp/link-targets/config.json" "$links/singular.config.json"
  ln -s "$tmp/link-targets/auditor.md" "$links/docs/orchestration/prompts/auditor.md"
  ln -s "$tmp/missing-reviewer" "$links/docs/orchestration/prompts/reviewer.md"
  ln -s "$tmp/link-targets/gate.sh" "$links/docs/orchestration/gates/gate.sh"
  ln -s "$tmp/missing-version" "$links/.singular-version"
  run_frozen_cli 077 "$links" "$frozen" "$tmp" init >/dev/null
  run_frozen_cli 022 "$links" "$frozen" "$tmp" init >/dev/null
  assert_eq "$(readlink "$links/singular.config.json")" "$tmp/link-targets/config.json" \
    "init preserves live config symlink"
  assert_eq "$(readlink "$links/docs/orchestration/prompts/auditor.md")" \
    "$tmp/link-targets/auditor.md" "init preserves live prompt symlink"
  assert_eq "$(readlink "$links/docs/orchestration/prompts/reviewer.md")" \
    "$tmp/missing-reviewer" "init preserves dangling prompt symlink"
  assert_eq "$(readlink "$links/docs/orchestration/gates/gate.sh")" \
    "$tmp/link-targets/gate.sh" "init preserves live gate symlink"
  assert_eq "$(readlink "$links/.singular-version")" "$tmp/missing-version" \
    "init preserves dangling version symlink"
  [[ ! -e "$tmp/missing-reviewer" && ! -e "$tmp/missing-version" ]] \
    || fail "init followed a dangling consumer symlink"
  after_targets="$(tree_bytes_modes_digest "$tmp/link-targets")"
  assert_eq "$after_targets" "$before_targets" \
    "init preserves external symlink target bytes and modes"

  # Setup uses the same copy contract before calling init. Exercise the actual
  # public setup --no-test path with a deterministic local provider, then prove
  # setup and update remain mode-preserving and idempotent.
  setup_repo="$tmp/setup"
  new_git_repo "$setup_repo"
  mkdir -p "$setup_repo/.singular-state"
  cat >"$setup_repo/.singular-state/config.local.sh" <<SH
export SINGULAR_RUNNER="$frozen/engine/codex-run.sh"
export SINGULAR_CODEX_BIN="$stub_bin/codex"
SH
  out="$(run_frozen_cli 077 "$setup_repo" "$frozen" "$tmp" setup --no-test 2>&1)"
  assert_contains "$out" "State: validated (STOP active; no workers dispatched)" \
    "frozen setup --no-test validates with local provider stub"
  assert_file "$setup_repo/.singular-state/STOP" "setup writes STOP"
  assert_mode_exact "$setup_repo/.singular-version" 0600 "setup pin honors umask 077"
  assert_mode_exact "$setup_repo/singular.config.json" 0600 "setup config honors umask 077"
  assert_mode_exact "$setup_repo/docs/orchestration/prompts/auditor.md" 0600 \
    "setup prompt honors umask 077"
  assert_mode_exact "$setup_repo/docs/orchestration/gates/gate.sh" 0700 \
    "setup gate honors umask 077"
  setup_config_sha="$(shasum -a 256 "$setup_repo/singular.config.json" | awk '{print $1}')"
  setup_prompt_sha="$(shasum -a 256 "$setup_repo/docs/orchestration/prompts/auditor.md" | awk '{print $1}')"
  setup_gate_sha="$(shasum -a 256 "$setup_repo/docs/orchestration/gates/gate.sh" | awk '{print $1}')"
  version_mode="$(file_mode "$setup_repo/.singular-version")"
  run_frozen_cli 022 "$setup_repo" "$frozen" "$tmp" setup --no-test >/dev/null
  assert_eq "$(shasum -a 256 "$setup_repo/singular.config.json" | awk '{print $1}')" \
    "$setup_config_sha" "repeated setup preserves config bytes"
  assert_eq "$(shasum -a 256 "$setup_repo/docs/orchestration/prompts/auditor.md" | awk '{print $1}')" \
    "$setup_prompt_sha" "repeated setup preserves prompt bytes"
  assert_eq "$(shasum -a 256 "$setup_repo/docs/orchestration/gates/gate.sh" | awk '{print $1}')" \
    "$setup_gate_sha" "repeated setup preserves gate bytes"
  assert_eq "$(file_mode "$setup_repo/.singular-version")" "$version_mode" \
    "repeated setup preserves pin mode"
  run_frozen_cli 022 "$setup_repo" "$frozen" "$tmp" update 9.9.9 >/dev/null
  run_frozen_cli 077 "$setup_repo" "$frozen" "$tmp" update 9.9.9 >/dev/null
  assert_eq "$(tr -d '[:space:]' <"$setup_repo/.singular-version")" "9.9.9" \
    "repeated setup consumer update is idempotent"
  assert_eq "$(file_mode "$setup_repo/.singular-version")" "$version_mode" \
    "setup consumer update preserves pin mode"

  after_engine="$(tree_bytes_modes_digest "$frozen")"
  assert_eq "$after_engine" "$before_engine" \
    "init/setup/update leave frozen payload root, bytes and modes unchanged"
}

test_init_scaffolds_fresh_repo_and_reconcile_apply_is_noop_safe() {
  local tmp repo out rc
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"

  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" init 2>&1)"
  assert_contains "$out" "singular init ->" "init reports target repo"

  assert_dir "$repo/docs/orchestration/packets/imported" "init packet import scaffold"
  assert_dir "$repo/docs/orchestration/areas/core" "init starter area scaffold"
  assert_file "$repo/docs/orchestration/decisions.md" "init decisions log"
  assert_file "$repo/docs/orchestration/project-state.md" "init project snapshot"
  assert_file "$repo/docs/orchestration/tasks/TEMPLATE.md" "init task template"
  assert_file "$repo/docs/orchestration/planner-contract.md" "init planner contract"
  for schema in audit-verdict decider-verdict gate-result state-packet task-batch dag l1-lease; do
    assert_file "$repo/schemas/orchestration/$schema.v0.schema.json" "init schema mirror $schema"
  done
  for entry in ".singular-state/" ".worktrees/" ".singular-evidence/" ".singular-cache/"; do
    grep -qxF "$entry" "$repo/.gitignore" || fail "init gitignore missing $entry"
  done

  git -C "$repo" checkout -q -b agent/integration
  set +e
  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" reconcile --apply 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "fresh reconcile --apply"
  assert_contains "$out" "singular origin reconcile (apply)" "fresh reconcile prints summary"
  assert_contains "$(cat "$repo/docs/orchestration/project-state.md")" "Latest Reconcile Snapshot" "fresh reconcile writes project snapshot"
}

# PMGO-006: an operator who already ran `init` must be able to reach a verified
# stopped state without undoing anything. Every ladder step that init already
# satisfied has to report itself as satisfied — not redo the work — and the
# config init wrote must come out byte-for-byte identical.
test_setup_after_init_is_a_clean_noop_ladder() {
  local tmp repo out rc before_config before_dag
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"

  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" init 2>&1)"
  assert_contains "$out" "singular init ->" "init runs before setup"
  before_config="$(shasum -a 256 "$repo/singular.config.json" | awk '{print $1}')"
  before_dag="$(shasum -a 256 "$repo/docs/orchestration/dag.v0.json" | awk '{print $1}')"

  # doctor probes the SELECTED provider's real executable, so pin a stub one
  # through the operator override lib.sh sources last; otherwise this test would
  # assert facts about whichever CLI happens to be authenticated on the host.
  mkdir -p "$repo/.singular-state" "$tmp/bin"
  cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.0.0-stub" ;;
  *) echo "stub" ;;
esac
exit 0
SH
  chmod +x "$tmp/bin/codex"
  cat >"$repo/.singular-state/config.local.sh" <<SH
export SINGULAR_RUNNER="$SCRIPT_DIR/codex-run.sh"
export SINGULAR_CODEX_BIN="$tmp/bin/codex"
SH

  set +e
  out="$(cd "$repo" && HOME="$tmp/home" SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" setup --no-test 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "setup after init succeeds ($out)"
  assert_contains "$out" "singular.config.json exists — init not re-run" "setup does not re-scaffold"
  assert_contains "$out" ".singular-version present" "setup keeps the pin init wrote"
  assert_contains "$out" "matches engine schema — nothing to migrate" "setup migrates nothing"
  assert_not_contains "$out" "singular init ->" "setup did not re-run init"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^Next: ')" "1" "setup prints exactly one next action"
  assert_file "$repo/.singular-state/STOP" "setup leaves the repository stopped"
  assert_eq "$(json_file_field "$repo/.singular-state/setup/state.json" state)" "validated" \
    "setup reaches validated without a regression run"
  assert_eq "$(shasum -a 256 "$repo/singular.config.json" | awk '{print $1}')" "$before_config" \
    "setup left singular.config.json byte-identical"
  assert_eq "$(shasum -a 256 "$repo/docs/orchestration/dag.v0.json" | awk '{print $1}')" "$before_dag" \
    "setup left the DAG byte-identical"
}

test_v0_to_v2_migration_backfills_scaffold_rebrands_and_syncs_contracts() {
  local tmp repo out
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  cat >"$repo/singular.config.json" <<'JSON'
{
  "schemaVersion": "v0",
  "engineVersion": "0.3.0",
  "targetBranch": "agent/integration",
  "gateCommand": "true",
  "areas": {},
  "env": {
    "PMGO_COMPAT_MARKER": "pmgo.orchestration.decider-verdict.v0"
  }
}
JSON
  mkdir -p "$repo/docs/orchestration/prompts"
  printf 'legacy schema pmgo.orchestration.state-packet.v0\n' >"$repo/docs/orchestration/prompts/legacy.md"
  git -C "$repo" add singular.config.json docs/orchestration/prompts/legacy.md
  git -C "$repo" -c user.name=test -c user.email=test@example.local commit -q -m orchestration-v0

  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate 2>&1)"
  assert_contains "$out" "run   v0-to-v1.sh (v0 -> v1)" "migration announces v1 step"
  assert_contains "$out" "run   v1-to-v2.sh (v1 -> v2)" "migration announces v2 step"
  assert_eq "$(json_file_field "$repo/singular.config.json" schemaVersion)" "v2" "migration advances schemaVersion"
  grep -q 'singular.orchestration.decider-verdict.v0' "$repo/singular.config.json" || fail "migration did not rebrand config namespace"
  grep -q 'singular.orchestration.state-packet.v0' "$repo/docs/orchestration/prompts/legacy.md" || fail "migration did not rebrand orchestration namespace"
  assert_file "$repo/docs/orchestration/project-state.md" "migration project-state scaffold"
  assert_dir "$repo/docs/orchestration/packets/imported" "migration packet import scaffold"
  assert_file "$repo/schemas/orchestration/audit-verdict.v1.schema.json" "migration v1 audit contract"
  assert_file "$repo/schemas/orchestration/gate-result.v1.schema.json" "migration v1 gate contract"

  out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate 2>&1)"
  assert_contains "$out" "up to date, nothing to do" "migration is idempotent after v2"
}

write_missing_branch_fixture() {
  local repo="$1" packet_dir="$1/docs/orchestration/packets/imported/TASK-0001"
  local run_dir="$1/.singular-state/runs/RUN-MISSING"
  local head tree
  mkdir -p "$repo/docs/orchestration/tasks" "$packet_dir" \
    "$repo/.singular-state/leases" "$run_dir"
  cat >"$repo/docs/orchestration/decisions.md" <<'EOF'
# Decisions

## Decision Log
EOF
  cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Missing branch fixture

Status: accepted
Area: core
Target branch: `target`
Worker branch: `agent/missing/TASK-0001`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise missing branch integration handling.

## Scope

Owned files:

- `README.md`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
EOF
  git -C "$repo" add docs/orchestration/decisions.md docs/orchestration/tasks/TASK-0001.md
  git -C "$repo" -c user.name=test -c user.email=test@example.local \
    commit -q -m fixture-contract
  # Keep the accepted commit object available while deleting its branch. Using
  # target HEAD here makes the candidate an ancestor and exercises restart
  # proof handling instead of the missing-ref recovery path.
  git -C "$repo" checkout -q -b agent/missing/TASK-0001
  printf 'accepted candidate\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=test -c user.email=test@example.local \
    commit -q -m accepted-candidate
  head="$(git -C "$repo" rev-parse HEAD)"
  tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
  cp "$repo/docs/orchestration/tasks/TASK-0001.md" \
    "$run_dir/verification-task-contract-1.md"
  printf '%s\n' '{"campaign":"legacy","policy":"legacy"}' \
    >"$run_dir/verification-policy-1.json"
  python3 "$SCRIPT_DIR/gate-report.py" create-verification-request \
    --output "$run_dir/verification-request-1.json" --task-id TASK-0001 \
    --run-id RUN-MISSING --attempt 1 --head-sha "$head" --tree-sha "$tree" \
    --campaign legacy --task-contract "$run_dir/verification-task-contract-1.md" \
    --policy-contract "$run_dir/verification-policy-1.json" \
    --suite-id task-contract-gate >/dev/null
  (cd "$repo" && env \
    SINGULAR_ROOT="$repo" \
    SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
    SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    bash "$SCRIPT_DIR/gate-check.sh" RUN-MISSING --task-id TASK-0001 \
      --verification-request "$run_dir/verification-request-1.json" \
      --task-contract "$run_dir/verification-task-contract-1.md" \
      --policy-contract "$run_dir/verification-policy-1.json" --attempt 1) >/dev/null
  mv "$run_dir/gate-report.json" "$run_dir/audit-verification.json"
  git -C "$repo" checkout -q target
  git -C "$repo" branch -D agent/missing/TASK-0001 >/dev/null

  python3 - "$packet_dir/RUN-MISSING.json" "$head" <<'PY'
import json
import sys
path, head = sys.argv[1:3]
packet = {
    "schema": "singular.orchestration.state-packet.v0",
    "packetId": "RUN-MISSING",
    "runId": "RUN-MISSING",
    "taskId": "TASK-0001",
    "area": "core",
    "role": "l2-developer",
    "status": "accepted",
    "baseRef": "target",
    "branch": "agent/missing/TASK-0001",
    "headSha": head,
    "workspace": "/tmp/missing",
    "ownedFiles": ["README.md"],
    "changedFiles": ["README.md"],
    "commands": [],
    "tests": [],
    "evidence": [{"kind": "audit-verification", "ref": "runs/RUN-MISSING/audit-verification.json"}],
    "blockers": [],
    "nextAction": "integrate",
    "createdAt": "2026-01-01T00:00:00Z",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(packet, f, indent=2)
    f.write("\n")
PY
  python3 - "$packet_dir/RUN-MISSING.audit.json" "$head" <<'PY'
import json
import sys
head = sys.argv[2]
audit = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": "RUN-MISSING",
    "branch": "agent/missing/TASK-0001",
    "verdict": "accepted",
    "evidenceReviewed": [
        "audit-verification.json",
        "reviewed-head-sha:" + head,
    ],
    "verificationResults": [{
        "status": "passed",
        "command": "true",
        "exitCode": 0,
        "evidenceRefs": ["audit-verification.json"],
        "rationale": "host-bound missing-branch fixture gate",
    }],
    "commandsRun": [],
    "findings": [],
    "requiredFixes": [],
    "rationale": "fixture accepted",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(audit, f, indent=2)
    f.write("\n")
PY
  SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_LEASES_DIR="$repo/.singular-state/leases" SINGULAR_TARGET_BRANCH=target \
    bash -c 'source "$0/lib.sh"; singular_lease_write TASK-0001 agent/missing/TASK-0001 core l2 "README.md" accepted RUN-MISSING "" target "" "[\"README.md\"]" "[]"' "$SCRIPT_DIR"
}

test_integrate_retains_and_suppresses_missing_branch_until_restored() {
  local tmp repo out out2 out3 out4 lease decisions events failures head recovery
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  git -C "$repo" checkout -q -b target
  write_missing_branch_fixture "$repo"

  out="$(SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --run-id RUN-MISSING-INTEG 2>&1)"
  assert_contains "$out" "skip TASK-0001: branch missing" "first integrate reports missing branch"
  assert_eq "$(json_file_field "$repo/.singular-state/leases/TASK-0001.json" status)" "accepted" \
    "missing branch preserves accepted lease authority"
  assert_eq "$(json_file_field "$repo/.singular-state/leases/TASK-0001.json" acceptedCandidate.state)" \
    "integration-failed" "missing branch retains actionable candidate state"
  grep -q '^Status: accepted$' "$repo/docs/orchestration/tasks/TASK-0001.md" \
    || fail "missing branch changed accepted task authority"
  assert_contains "$(cat "$repo/docs/orchestration/decisions.md")" "decide:escalate-parked" "missing branch records parked decision"
  failures="$(python3 - "$repo/.singular-state/leases/TASK-0001.json" <<'PY'
import json, sys
candidate = json.load(open(sys.argv[1], encoding="utf-8"))["acceptedCandidate"]
assert candidate["failures"][0]["failureClass"] == "branch-missing", candidate
assert "restore" in candidate["nextAction"], candidate
print(len(candidate["failures"]))
PY
)"
  assert_eq "$failures" "1" "first missing branch publishes one durable failure"
  decisions="$(grep -c 'decide:escalate-parked' "$repo/docs/orchestration/decisions.md")"
  events="$(grep -c '"type":"integration.parked"' "$repo/.singular-state/events.ndjson")"
  recovery="$(grep -c '"type":"recovery.action"' "$repo/.singular-state/events.ndjson")"

  # Unrelated target progress does not change the missing ref dependency and
  # therefore must not republish the same recovery decision on the next cycle.
  printf 'unrelated target progress\n' >"$repo/unrelated.txt"
  git -C "$repo" add unrelated.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.local \
    commit -q -m unrelated-target-progress

  out2="$(SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --run-id RUN-MISSING-INTEG2 2>&1)"
  assert_contains "$out2" "unchanged failed integration" "unchanged missing branch is suppressed"
  assert_not_contains "$out2" "branch missing (" "unchanged cycle does not republish missing-branch handling"
  assert_eq "$(grep -c 'decide:escalate-parked' "$repo/docs/orchestration/decisions.md")" "$decisions" \
    "unchanged cycle publishes no duplicate decision"
  assert_eq "$(grep -c '"type":"integration.parked"' "$repo/.singular-state/events.ndjson")" "$events" \
    "unchanged cycle publishes no duplicate parked event"
  assert_eq "$(grep -c '"type":"recovery.action"' "$repo/.singular-state/events.ndjson")" "$recovery" \
    "unchanged cycle publishes no duplicate recovery row"

  lease="$(shasum -a 256 "$repo/.singular-state/leases/TASK-0001.json" | awk '{print $1}')"
  decisions="$(shasum -a 256 "$repo/docs/orchestration/decisions.md" | awk '{print $1}')"
  events="$(shasum -a 256 "$repo/.singular-state/events.ndjson" | awk '{print $1}')"

  out3="$(SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --task TASK-0001 --dry-run 2>&1)"
  assert_contains "$out3" "skip TASK-0001: branch missing" "dry-run reports current missing dependency"
  assert_eq "$(shasum -a 256 "$repo/.singular-state/leases/TASK-0001.json" | awk '{print $1}')" "$lease" \
    "dry-run does not mutate retained candidate"
  assert_eq "$(shasum -a 256 "$repo/docs/orchestration/decisions.md" | awk '{print $1}')" "$decisions" \
    "dry-run does not publish a decision"
  assert_eq "$(shasum -a 256 "$repo/.singular-state/events.ndjson" | awk '{print $1}')" "$events" \
    "dry-run does not publish an integration event"

  head="$(json_file_field "$repo/.singular-state/leases/TASK-0001.json" acceptedCandidate.headSha)"
  git -C "$repo" branch agent/missing/TASK-0001 "$head"
  out4="$(SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_RUNS_DIR="$repo/.singular-state/runs" SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_DEFAULT_GATE_CMD=true SINGULAR_AUTO_PROMOTE_GATES=0 \
    bash "$SCRIPT_DIR/integrate.sh" --task TASK-0001 --run-id RUN-MISSING-RESTORED 2>&1)"
  assert_contains "$out4" "INTEGRATED TASK-0001" "restoring exact branch permits integration"
  assert_eq "$(json_file_field "$repo/.singular-state/leases/TASK-0001.json" status)" "integrated" \
    "restored branch completes retained candidate"
}

test_l1_drive_provisions_gitignored_files_and_allowlisted_env() {
  local tmp repo runner out rc
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  git -C "$repo" checkout -q -b target
  mkdir -p "$repo/docs/orchestration/prompts" "$repo/docs/orchestration/tasks" "$repo/src"
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$repo/docs/orchestration/prompts/l2-test-first-developer.md"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$repo/docs/orchestration/prompts/auditor.md"
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$repo/docs/orchestration/prompts/decider.md"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n.env.local\n' >"$repo/.gitignore"
  cat >"$repo/.env.local" <<'EOF'
LOCAL_ONLY=present
EOF
  cat >"$repo/strict-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
test -f .env.local
test -f "$SINGULAR_WORKTREE_ENV_FILE"
. "$SINGULAR_WORKTREE_ENV_FILE"
test "${PUBLIC_ALLOWED:-}" = ok
test -z "${SECRET_DENIED:-}"
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
  chmod +x "$repo/strict-gate.sh"
  cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Provisioning fixture

Status: ready
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-0001-provisioning`
Test policy: `strict_test_first`
Gate command: `bash strict-gate.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Write the generated fixture file.

## Scope

Owned files:

- `src/generated.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Gate can read provisioned file and allowlisted env.
EOF
  git -C "$repo" add .gitignore docs/orchestration src strict-gate.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.local commit -q -m target-setup
  cat >"$repo/singular.config.json" <<JSON
{
  "schemaVersion": "v2",
  "targetBranch": "target",
  "gateCommand": "true",
  "provisionFiles": [
    {"source": ".env.local", "target": ".env.local", "required": true}
  ],
  "envAllowlist": ["PUBLIC_*"]
}
JSON
  runner="$tmp/runner.sh"
  cat >"$runner" <<'SH'
#!/usr/bin/env bash
level=""; out=""; chdir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C|--worktree) chdir="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file|--run-id|--session-meta|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  mkdir -p "$chdir/src" "$chdir/.singular-evidence"
  printf 'generated\n' >"$chdir/src/generated.txt"
  printf 'red\n' >"$chdir/.singular-evidence/red.log"
  printf 'green\n' >"$chdir/.singular-evidence/green.log"
  printf 'regression\n' >"$chdir/.singular-evidence/regression.log"
  python3 - "$out" <<'PY'
import json
import sys
packet = {
    "schema": "singular.orchestration.state-packet.v0",
    "packetId": "p",
    "runId": "r",
    "taskId": "TASK-0001",
    "area": "core",
    "role": "l2-developer",
    "status": "needs-review",
    "baseRef": "target",
    "branch": "agent/core/TASK-0001-provisioning",
    "headSha": "uncommitted",
    "workspace": "/tmp",
    "ownedFiles": ["src/generated.txt"],
    "changedFiles": ["src/generated.txt"],
    "commands": [{"cmd": "true", "exitCode": 0}],
    "tests": [{"name": "fixture", "phase": "red", "status": "fail", "logRef": ".singular-evidence/red.log"},
              {"name": "fixture", "phase": "green", "status": "pass", "logRef": ".singular-evidence/green.log"}],
    "evidence": [{"kind": "red", "ref": ".singular-evidence/red.log"}],
    "blockers": [],
    "nextAction": "audit",
    "createdAt": "2026-01-01T00:00:00Z",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(packet, f)
PY
  exit 0
fi
python3 - "$out" <<'PY'
import json
import sys
audit = {
    "schema": "singular.orchestration.audit-verdict.v0",
    "taskId": "TASK-0001",
    "runId": "r",
    "branch": "agent/core/TASK-0001-provisioning",
    "verdict": "accepted",
    "evidenceReviewed": [],
    "commandsRun": [],
    "findings": [],
    "requiredFixes": [],
    "rationale": "accepted",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(audit, f)
PY
SH
  chmod +x "$runner"

  set +e
  out="$(PUBLIC_ALLOWED=ok SECRET_DENIED=bad SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
    SINGULAR_STATE_DIR="$repo/.singular-state" SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" SINGULAR_WORKTREES_DIR="$repo/.worktrees" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$runner" SINGULAR_MAX_RETRIES=0 \
    bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "provisioned l1-drive accepts ($out)"
  assert_contains "$out" "ACCEPTED: TASK-0001" "provisioned task accepted"
}

if [[ "${SINGULAR_FRESH_CONSUMER_CASE:-all}" == "consumer-copy-only" ]]; then
  test_frozen_engine_creates_editable_consumer_copies_without_touching_existing_files
elif [[ "${SINGULAR_FRESH_CONSUMER_CASE:-all}" == "l1-only" ]]; then
  test_l1_drive_provisions_gitignored_files_and_allowlisted_env
else
  test_frozen_engine_creates_editable_consumer_copies_without_touching_existing_files
  test_init_scaffolds_fresh_repo_and_reconcile_apply_is_noop_safe
  test_setup_after_init_is_a_clean_noop_ladder
  test_v0_to_v2_migration_backfills_scaffold_rebrands_and_syncs_contracts
  test_integrate_retains_and_suppresses_missing_branch_until_restored
  test_l1_drive_provisions_gitignored_files_and_allowlisted_env
fi

echo "fresh consumer tests passed"
