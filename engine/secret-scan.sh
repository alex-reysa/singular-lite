#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 && -x /opt/homebrew/bin/bash ]]; then
  exec /opt/homebrew/bin/bash "$0" "$@"
fi

# Credential accident-guard. Scans added content for high-confidence secret
# patterns before a commit or push. This is deliberately NOT a decision the
# decider can override — it prevents accidentally leaking live credentials (e.g.
# the Supabase service-role tokens in the environment) to git/origin.
#
# Usage:
#   secret-scan.sh --worktree PATH --staged          # scan staged diff (pre-commit)
#   secret-scan.sh --worktree PATH --range A..B       # scan a commit range (pre-push)
#   secret-scan.sh --worktree PATH --base SHA         # admitted range + staged/working/untracked
#   secret-scan.sh --worktree PATH                    # scan unstaged + untracked
#   secret-scan.sh --artifacts RUN_DIR                # scan durable context artifacts
#
# Exit 0 = clean; exit 2 = secrets or an inspection failure (rule labels only).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# The pattern set now lives in engine/secret-patterns.tsv and is exposed by
# singular_secret_scan_patterns() in lib.sh (sourced above), so the console's
# python redactor can read the same definition.

worktree="$SINGULAR_ROOT"
mode="working"
range=""
base=""
artifacts_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree|-C) worktree="$2"; shift 2 ;;
    --staged) mode="staged"; shift ;;
    --range) mode="range"; range="$2"; shift 2 ;;
    --base) mode="admission"; base="$2"; shift 2 ;;
    --artifacts)
      [[ $# -ge 2 ]] || { echo "missing value for --artifacts" >&2; exit 2; }
      mode="artifacts"; artifacts_dir="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$mode" == "artifacts" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/ctx-artifact-scan.sh"
  singular_ctx_artifact_scan "$artifacts_dir"
  exit $?
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/singular-secret-scan.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
patch_file="$scratch/patches"
added_lines_file="$scratch/added-lines"
added_paths_file="$scratch/added-paths"
untracked_file="$scratch/untracked"
patterns_file="$scratch/patterns.tsv"
: >"$patch_file"
: >"$added_paths_file"
: >"$untracked_file"

append_git() {
  local output="$1"
  shift
  if ! git -C "$worktree" "$@" >>"$output"; then
    echo "secret-scan: Git inspection failed; refusing." >&2
    exit 2
  fi
}

# Capture every content surface that can enter the candidate. The admitted mode
# is the L1 contract: committed base..HEAD plus staged, unstaged, and untracked
# bytes. Other modes retain the public pre-commit/pre-push behavior.
case "$mode" in
  staged)
    append_git "$patch_file" diff --no-ext-diff --no-textconv --text --cached -U0
    append_git "$added_paths_file" diff --cached --name-only -z --diff-filter=A
    ;;
  range)
    [[ -n "$range" ]] || { echo "secret-scan: --range requires a value" >&2; exit 2; }
    append_git "$patch_file" diff --no-ext-diff --no-textconv --text -U0 "$range"
    append_git "$added_paths_file" diff --name-only -z --diff-filter=A "$range"
    ;;
  admission)
    [[ -n "$base" ]] || { echo "secret-scan: --base requires a value" >&2; exit 2; }
    if ! python3 "$SCRIPT_DIR/git_changes.py" --worktree "$worktree" \
        --base "$base" --head HEAD >/dev/null; then
      echo "secret-scan: invalid admitted base/candidate lineage; refusing." >&2
      exit 2
    fi
    append_git "$patch_file" diff --no-ext-diff --no-textconv --text -U0 "$base"...HEAD
    append_git "$patch_file" diff --no-ext-diff --no-textconv --text --cached -U0
    append_git "$patch_file" diff --no-ext-diff --no-textconv --text -U0
    append_git "$added_paths_file" diff --name-only -z --diff-filter=A "$base"...HEAD
    append_git "$added_paths_file" diff --cached --name-only -z --diff-filter=A
    append_git "$untracked_file" ls-files --others --exclude-standard -z
    ;;
  *)
    append_git "$patch_file" diff --no-ext-diff --no-textconv --text -U0
    append_git "$untracked_file" ls-files --others --exclude-standard -z
    ;;
esac

# Parse patch hunks rather than grepping every '+' line, so a content line that
# starts with '+++ ' is not mistaken for a file header. Append complete untracked
# files because they have no Git patch until staged.
python3 - "$patch_file" "$added_lines_file" <<'PY'
import pathlib, sys
source, output = map(pathlib.Path, sys.argv[1:3])
inside_hunk = False
with source.open("rb") as stream, output.open("wb") as target:
    for line in stream:
        if line.startswith(b"diff --git "):
            inside_hunk = False
        elif line.startswith(b"@@"):
            inside_hunk = True
        elif inside_hunk and line.startswith(b"+"):
            target.write(line[1:])
PY
while IFS= read -r -d '' p; do
  if [[ -f "$worktree/$p" ]]; then
    printf '\n' >>"$added_lines_file"
    if ! command cat -- "$worktree/$p" >>"$added_lines_file"; then
      echo "secret-scan: could not inspect untracked content; refusing." >&2
      exit 2
    fi
  fi
  printf '%s\0' "$p" >>"$added_paths_file"
done <"$untracked_file"

hits=0
report() { echo "secret-scan: $1" >&2; hits=$((hits + 1)); }

scan() {
  local label="$1" regex="$2"
  local scan_rc=0
  # Do not echo matching credential material. Labels identify the rule while
  # keeping the actual candidate bytes confined to the worktree.
  grep -qE -e "$regex" "$added_lines_file" || scan_rc=$?
  if [[ "$scan_rc" -eq 0 ]]; then
    report "$label match in added content"
  elif [[ "$scan_rc" -gt 1 ]]; then
    echo "secret-scan: pattern evaluation failed; refusing." >&2
    exit 2
  fi
}

if ! singular_secret_scan_patterns >"$patterns_file"; then
  echo "secret-scan: secret pattern loading failed; refusing." >&2
  exit 2
fi
while IFS="$(printf '\t')" read -r label regex; do
  scan "$label" "$regex"
done <"$patterns_file"

# Flag any added dotenv files outright.
while IFS= read -r -d '' p; do
  case "$(basename "$p")" in
    .env|.env.*) [[ "$(basename "$p")" == ".env.example" ]] || report "dotenv file added: $p" ;;
  esac
done <"$added_paths_file"

if [[ "$hits" -gt 0 ]]; then
  echo "secret-scan: $hits potential secret(s) found; refusing." >&2
  exit 2
fi
echo "secret-scan: clean"
