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

changes_file="$(mktemp "${TMPDIR:-/tmp}/singular-scope-changes.XXXXXX")"
trap 'rm -f "$changes_file"' EXIT
change_args=(--worktree "$worktree" --base "${base:-HEAD}" --head HEAD --include-working --format nul)
if ! python3 "$SCRIPT_DIR/git_changes.py" "${change_args[@]}" >"$changes_file"; then
  echo "scope check failed: Git change discovery failed" >&2
  exit 2
fi
scope_args=(--check-scope --paths-nul "$changes_file")
for prefix in "${allow_prefixes[@]}"; do
  scope_args+=(--allow-prefix "$prefix")
done
for prefix in "${forbid_prefixes[@]}"; do
  scope_args+=(--forbid-prefix "$prefix")
done
python3 "$SCRIPT_DIR/git_changes.py" "${scope_args[@]}"
