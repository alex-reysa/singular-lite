#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  exec /opt/homebrew/bin/bash "$0" "$@"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/engine/secret-scan.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" checkout -q -b target
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.local
printf 'base\n' >"$repo/value.txt"
git -C "$repo" add value.txt
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"

synthetic_prefix='sk-'
synthetic_body='AAAAAAAAAAAAAAAAAAAA'
synthetic="${synthetic_prefix}${synthetic_body}"
out=""; rc=0
out="$(SINGULAR_ROOT="$repo" "$SCAN" --worktree "$repo" --base "$base" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || { echo "clean candidate was refused" >&2; exit 1; }
[[ "$out" == *"secret-scan: clean"* ]] || { echo "missing clean result" >&2; exit 1; }
[[ "$out" != *"$synthetic"* ]] || { echo "clean scan disclosed synthetic credential bytes" >&2; exit 1; }

printf 'credential=%s\n' "$synthetic" >"$repo/value.txt"
git -C "$repo" add value.txt
git -C "$repo" commit -qm committed-secret
out=""; rc=0
out="$(SINGULAR_ROOT="$repo" "$SCAN" --worktree "$repo" --base "$base" 2>&1)" || rc=$?
[[ "$rc" -eq 2 ]] || { echo "committed secret was not refused" >&2; exit 1; }
[[ "$out" == *"OpenAI key match in added content"* ]] || { echo "missing secret rule label" >&2; exit 1; }
[[ "$out" != *"$synthetic"* ]] || { echo "secret scan disclosed matching credential bytes" >&2; exit 1; }

printf 'clean\n' >"$repo/value.txt"
git -C "$repo" add value.txt
git -C "$repo" commit -qm clean-head
base="$(git -C "$repo" rev-parse HEAD)"

printf 'staged=%s\n' "$synthetic" >"$repo/staged-only.txt"
git -C "$repo" add staged-only.txt
out=""; rc=0
out="$(SINGULAR_ROOT="$repo" "$SCAN" --worktree "$repo" --staged 2>&1)" || rc=$?
[[ "$rc" -eq 2 ]] || { echo "staged-only secret was not refused" >&2; exit 1; }
[[ "$out" == *"OpenAI key match in added content"* ]] || { echo "staged-only rule label missing" >&2; exit 1; }
[[ "$out" != *"$synthetic"* ]] || { echo "staged-only credential was disclosed" >&2; exit 1; }
git -C "$repo" reset -q -- staged-only.txt
rm "$repo/staged-only.txt"

printf 'unstaged=%s\n' "$synthetic" >"$repo/value.txt"
out=""; rc=0
out="$(SINGULAR_ROOT="$repo" "$SCAN" --worktree "$repo" 2>&1)" || rc=$?
[[ "$rc" -eq 2 ]] || { echo "unstaged-only secret was not refused" >&2; exit 1; }
[[ "$out" == *"OpenAI key match in added content"* ]] || { echo "unstaged-only rule label missing" >&2; exit 1; }
[[ "$out" != *"$synthetic"* ]] || { echo "unstaged-only credential was disclosed" >&2; exit 1; }
printf 'clean\n' >"$repo/value.txt"

printf 'token=%s\n' "$synthetic" >"$repo/untracked -> credential"$'\n'".txt"
rc=0
SINGULAR_ROOT="$repo" "$SCAN" --worktree "$repo" --base "$base" >/dev/null 2>"$tmp/working.err" || rc=$?
[[ "$rc" -eq 2 ]] || { echo "untracked secret was not refused" >&2; exit 1; }
grep -Fq "OpenAI key match in added content" "$tmp/working.err" || { echo "untracked rule label missing" >&2; exit 1; }
! grep -Fq "$synthetic" "$tmp/working.err" || { echo "untracked credential was disclosed" >&2; exit 1; }

rm "$repo/untracked -> credential"$'\n'".txt"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'binary\0credential=%s\n' "$synthetic" >"$repo/binary.dat"
git -C "$repo" add binary.dat
git -C "$repo" commit -qm binary-secret
rc=0
SINGULAR_ROOT="$repo" "$SCAN" --worktree "$repo" --base "$base" \
  >/dev/null 2>"$tmp/binary.err" || rc=$?
[[ "$rc" -eq 2 ]] || { echo "binary committed secret was not refused" >&2; exit 1; }
! grep -Fq "$synthetic" "$tmp/binary.err" || { echo "binary credential was disclosed" >&2; exit 1; }

rc=0
SINGULAR_ROOT="$repo" "$SCAN" --worktree "$repo" --base does-not-exist \
  >/dev/null 2>"$tmp/git.err" || rc=$?
[[ "$rc" -eq 2 ]] || { echo "Git failure was treated as clean" >&2; exit 1; }

echo "test-secret-scan.sh: ok"
