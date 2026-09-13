#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp=""
cleanup() {
  [[ -z "${tmp:-}" ]] || rm -rf "$tmp"
}
trap cleanup EXIT

make_repo() {
  local root="$1"
  mkdir -p "$root/internal/dispatch" "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  printf 'package dispatch\n' >"$root/internal/dispatch/runtime.go"
  git -C "$root" add internal/dispatch/runtime.go
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  cleanup
  tmp="$(mktemp -d)"
  make_repo "$tmp/repo"
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_TARGET_BRANCH="target"
}

test_empty_forbid_prefixes_are_safe_under_system_bash() {
  with_fixture
  printf '\nconst started = true\n' >>"$SINGULAR_ROOT/internal/dispatch/runtime.go"
  local out rc=0
  out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" --allow-prefix internal/dispatch/runtime.go 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "scope check with no forbidden prefixes should pass: $out"
  assert_contains "$out" "all allowed" "empty forbidden prefix result"
}

test_forbidden_prefix_still_fails_under_system_bash() {
  with_fixture
  printf '\nconst started = true\n' >>"$SINGULAR_ROOT/internal/dispatch/runtime.go"
  local out rc=0
  out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" --allow-prefix internal/dispatch/runtime.go --forbid-prefix internal/dispatch/runtime.go 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "forbidden prefix should fail"
  assert_contains "$out" "forbidden paths touched" "forbidden prefix failure"
}

# A directory prefix is naturally written with a trailing slash -- it is the form
# every adapter uses for its own l0/l1 default. Both forms must mean the same
# thing in both directions: the allow form used to admit nothing (so any direct
# l0/l1 dispatch failed the moment the run touched a file), and the forbid form
# used to deny nothing at all.
test_directory_prefix_admits_its_contents_in_both_forms() {
  local prefix
  for prefix in docs/orchestration docs/orchestration/; do
    with_fixture
    mkdir -p "$SINGULAR_ROOT/docs/orchestration"
    printf 'plan\n' >"$SINGULAR_ROOT/docs/orchestration/plan.md"
    local out rc=0
    out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" \
      --allow-prefix "$prefix" 2>&1)" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "allow-prefix '$prefix' should admit its own directory: $out"
    assert_contains "$out" "all allowed" "allow-prefix '$prefix' result"
  done
}

test_directory_prefix_still_rejects_outside_writes_in_both_forms() {
  local prefix
  for prefix in docs/orchestration docs/orchestration/; do
    with_fixture
    mkdir -p "$SINGULAR_ROOT/docs/orchestration"
    printf 'plan\n' >"$SINGULAR_ROOT/docs/orchestration/plan.md"
    printf 'stray\n' >"$SINGULAR_ROOT/outside.txt"
    local out rc=0
    out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" \
      --allow-prefix "$prefix" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "allow-prefix '$prefix' must still reject outside.txt: $out"
    assert_contains "$out" "outside.txt" "allow-prefix '$prefix' violation list"
  done
}

# The sibling-name rule survives normalization: a prefix is a path segment, not
# a string prefix.
test_directory_prefix_does_not_match_sibling_names() {
  with_fixture
  mkdir -p "$SINGULAR_ROOT/docs"
  printf 'x\n' >"$SINGULAR_ROOT/docs/orchestration-notes.md"
  local out rc=0
  out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" \
    --allow-prefix "docs/orchestration/" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "docs/orchestration/ must not admit docs/orchestration-notes.md: $out"
  assert_contains "$out" "orchestration-notes.md" "sibling-name violation"
}

test_forbidden_directory_prefix_denies_in_both_forms() {
  local prefix
  for prefix in internal/dispatch internal/dispatch/; do
    with_fixture
    printf '\nconst started = true\n' >>"$SINGULAR_ROOT/internal/dispatch/runtime.go"
    local out rc=0
    out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" \
      --allow-prefix internal --forbid-prefix "$prefix" 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "forbid-prefix '$prefix' must deny its contents: $out"
    assert_contains "$out" "forbidden paths touched" "forbid-prefix '$prefix' failure"
  done
}

test_committed_and_working_paths_are_nul_safe_and_complete() {
  with_fixture
  local base out rc=0 source_name destination_name working_name paths_json
  source_name=$'source "quoted" -> arrow\nand newline.txt'
  destination_name=$'destination -> literal\nname.txt'
  mkdir -p "$SINGULAR_ROOT/owned" "$SINGULAR_ROOT/outside"
  printf 'rename me\n' >"$SINGULAR_ROOT/outside/$source_name"
  printf 'delete me\n' >"$SINGULAR_ROOT/outside/delete.txt"
  printf 'mode\n' >"$SINGULAR_ROOT/owned/mode.sh"
  git -C "$SINGULAR_ROOT" add owned outside
  git -C "$SINGULAR_ROOT" -c user.name=test -c user.email=test@example.local commit -q -m paths
  base="$(git -C "$SINGULAR_ROOT" rev-parse HEAD)"
  git -C "$SINGULAR_ROOT" mv "outside/$source_name" "owned/$destination_name"
  git -C "$SINGULAR_ROOT" rm -q outside/delete.txt
  chmod +x "$SINGULAR_ROOT/owned/mode.sh"
  git -C "$SINGULAR_ROOT" add owned/mode.sh
  git -C "$SINGULAR_ROOT" -c user.name=test -c user.email=test@example.local commit -q -m delta
  working_name=$'untracked -> name\ntail.txt'
  printf 'working\n' >"$SINGULAR_ROOT/owned/$working_name"

  paths_json="$(python3 "$SCRIPT_DIR/git_changes.py" --worktree "$SINGULAR_ROOT" \
    --base "$base" --head HEAD --include-working)"
  python3 - "$paths_json" "outside/$source_name" "owned/$destination_name" \
    "outside/delete.txt" "owned/mode.sh" "owned/$working_name" <<'PY'
import json, sys
actual = json.loads(sys.argv[1])
expected = sys.argv[2:]
assert all(path in actual for path in expected), (actual, expected)
assert len(actual) == len(set(actual)), actual
PY

  out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" \
    --base "$base" --allow-prefix owned 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "rename source and committed deletion outside scope were not checked"
  assert_contains "$out" "outside/delete.txt" "committed deletion path"

  rc=0
  out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" \
    --base "$base" --allow-prefix owned --allow-prefix outside 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "NUL-safe committed/working scope should pass: $out"
}

test_git_errors_fail_closed() {
  with_fixture
  local out rc=0
  out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$SINGULAR_ROOT" \
    --base does-not-exist --allow-prefix internal 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "invalid Git base was treated as an empty successful scope"
  assert_contains "$out" "Git change discovery failed" "Git failure diagnostic"
}

test_empty_forbid_prefixes_are_safe_under_system_bash
test_forbidden_prefix_still_fails_under_system_bash
test_directory_prefix_admits_its_contents_in_both_forms
test_directory_prefix_still_rejects_outside_writes_in_both_forms
test_directory_prefix_does_not_match_sibling_names
test_forbidden_directory_prefix_denies_in_both_forms
test_committed_and_working_paths_are_nul_safe_and_complete
test_git_errors_fail_closed

echo "test-scope-check.sh: ok"
