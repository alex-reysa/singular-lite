#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 && -x /opt/homebrew/bin/bash ]]; then
  exec /opt/homebrew/bin/bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

worktree="$SINGULAR_ROOT"
base=""
allow_prefixes=()
forbid_prefixes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree|-C)
      worktree="$2"
      shift 2
      ;;
    --base)
      base="$2"
      shift 2
      ;;
    --allow-prefix)
      allow_prefixes+=("$2")
      shift 2
      ;;
    --forbid-prefix)
      forbid_prefixes+=("$2")
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ${#allow_prefixes[@]} -eq 0 ]]; then
  echo "at least one --allow-prefix is required" >&2
  exit 2
fi

# Direct callers receive the same fail-closed path validation as task parsing.
# Quoting/annotation has already been interpreted by task_parser.py; this layer
# accepts only the resulting repository-relative path values.
for prefix in "${allow_prefixes[@]}"; do
  [[ -n "$prefix" ]] || continue
  python3 "$SINGULAR_LIB_DIR/task_parser.py" validate-path "$prefix" >/dev/null || {
    echo "invalid scope prefix: $prefix" >&2
    exit 2
  }
done
if [[ ${#forbid_prefixes[@]} -gt 0 ]]; then
  for prefix in "${forbid_prefixes[@]}"; do
    [[ -n "$prefix" ]] || continue
    python3 "$SINGULAR_LIB_DIR/task_parser.py" validate-path "$prefix" >/dev/null || {
      echo "invalid scope prefix: $prefix" >&2
      exit 2
    }
  done
fi

# A path matches a prefix only if it equals the prefix or sits beneath it as a
# path segment (so "internal/artifact" does NOT match "internal/artifact-x.go").
#
# The trailing slash is normalized first, because a directory prefix is
# naturally written with one -- it is how every adapter writes its own l0/l1
# default, `docs/orchestration/`. Unnormalized, the segment test expanded to
# `docs/orchestration//*`, which matches nothing: an allow prefix in that form
# admitted no file at all (so a direct l0/l1 dispatch failed its scope check the
# moment the run touched anything), and a FORBID prefix in that form denied
# nothing, which is the direction that matters.
_path_matches() {
  local path="$1" prefix="$2"
  while [[ "$prefix" == */ && "${#prefix}" -gt 1 ]]; do
    prefix="${prefix%/}"
  done
  [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]
}

declare -a files=()
changes_file="$(mktemp "${TMPDIR:-/tmp}/singular-scope-changes.XXXXXX")"
trap 'rm -f "$changes_file"' EXIT
change_args=(--worktree "$worktree" --base "${base:-HEAD}" --head HEAD --include-working --format nul)
if ! python3 "$SCRIPT_DIR/git_changes.py" "${change_args[@]}" >"$changes_file"; then
  echo "scope check failed: Git change discovery failed" >&2
  exit 2
fi
while IFS= read -r -d '' path; do
  files+=("$path")
done <"$changes_file"

if [[ ${#files[@]} -eq 0 ]]; then
  echo "scope check: no changed files"
  exit 0
fi

violations=()
forbidden_hits=()
for ((file_i = 0; file_i < ${#files[@]}; file_i++)); do
  path="${files[$file_i]}"
  # Forbidden takes precedence: a forbidden path is a violation even if it would
  # otherwise match an allow prefix.
  forbidden="no"
  for ((forbid_i = 0; forbid_i < ${#forbid_prefixes[@]}; forbid_i++)); do
    prefix="${forbid_prefixes[$forbid_i]}"
    if _path_matches "$path" "$prefix"; then
      forbidden="yes"
      break
    fi
  done
  if [[ "$forbidden" == "yes" ]]; then
    forbidden_hits+=("$path")
    continue
  fi
  allowed="no"
  for ((allow_i = 0; allow_i < ${#allow_prefixes[@]}; allow_i++)); do
    prefix="${allow_prefixes[$allow_i]}"
    if _path_matches "$path" "$prefix"; then
      allowed="yes"
      break
    fi
  done
  if [[ "$allowed" != "yes" ]]; then
    violations+=("$path")
  fi
done

if [[ ${#forbidden_hits[@]} -gt 0 || ${#violations[@]} -gt 0 ]]; then
  if [[ ${#forbidden_hits[@]} -gt 0 ]]; then
    echo "scope check failed; forbidden paths touched:" >&2
    printf '  %s\n' "${forbidden_hits[@]}" >&2
  fi
  if [[ ${#violations[@]} -gt 0 ]]; then
    echo "scope check failed; disallowed paths:" >&2
    printf '  %s\n' "${violations[@]}" >&2
  fi
  echo "allowed prefixes:" >&2
  printf '  %s\n' "${allow_prefixes[@]}" >&2
  if [[ ${#forbid_prefixes[@]} -gt 0 ]]; then
    echo "forbidden prefixes:" >&2
    printf '  %s\n' "${forbid_prefixes[@]}" >&2
  fi
  exit 2
fi

echo "scope check: ${#files[@]} changed path(s), all allowed"
