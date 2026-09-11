#!/usr/bin/env bash
# Install the singular orchestration engine for the current machine.
#
#   bash install.sh            # install this checkout's version
#
# Layout created:
#   $SINGULAR_HOME/versions/<ver>/    versioned engine (engine, schemas, cli, plugin, ...)
#   $SINGULAR_HOME/current  -> versions/<ver>
#   $SINGULAR_HOME/bin/singular -> versions/<ver>/cli/singular
# SINGULAR_HOME defaults to ~/.singular; set it before invoking this script to
# choose another machine-install root.
#
# Multiple versions coexist; each repo pins which it uses (.singular-version /
# singular.config.json engineVersion). `singular update <ver>` repins a repo.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SRC/VERSION" && -f "$SRC/engine/lib.sh" ]] || {
  echo "install.sh must run from an engine checkout (with VERSION + engine/)" >&2; exit 1; }

# Bash >= 4 preflight: same shim, same diagnosis, as the CLI and the engine
# entrypoints. Installing under macOS Bash 3.2 must not be the thing that
# teaches an operator the requirement three commands later.
# shellcheck source=engine/bash-guard.sh
. "$SRC/engine/bash-guard.sh"

VER="$(tr -d '[:space:]' < "$SRC/VERSION")"
[[ -n "$VER" ]] || { echo "install.sh: VERSION is empty — refusing to install (would wipe versions/*)" >&2; exit 1; }
SINGULAR_HOME="${SINGULAR_HOME:-$HOME/.singular}"
if [[ "$SINGULAR_HOME" != /* ]]; then
  echo "install.sh: SINGULAR_HOME must be an absolute path: $SINGULAR_HOME" >&2
  exit 1
fi
export SINGULAR_HOME
DEST="$SINGULAR_HOME/versions/$VER"

echo "Installing singular engine $VER -> $DEST"
mkdir -p "$DEST" "$SINGULAR_HOME/bin"

# Copy the engine payload, preserving exec bits. Exclude runtime/VCS cruft.
#
# Optional items must not abort the install. The `[[ -e ]] &&` form says these
# are optional, but under `set -e` a missing one makes copy() return 1 and kills
# the script — mid-loop, after some payload is already in place, leaving a
# half-populated version dir while `current` still points at the old release.
# An explicit `return 0` makes the stated intent actually true. (Hit for real:
# an empty, untracked `promoters/` vanished from the checkout and took the whole
# install down with it, silently, after copying engine/ and schemas/.)
copy() {
  [[ -e "$SRC/$1" ]] || return 0
  cp -Rp "$SRC/$1" "$DEST/"
}
rm -rf "$DEST"/* 2>/dev/null || true
# `tests` is deliberately NOT in this list: the regression suite needs real Git
# history and disposable worktrees, and an installed version is a plain `cp -Rp`
# tree with no `.git`. Shipping it would only move the failure later — a run dir
# and a supervisor created, then SINGULAR_TEST_SOURCE_UNSUPPORTED from run.sh's
# own preflight. The suite runs from an engine CHECKOUT; `singular test` refuses
# up front anywhere else. (The chmod below tolerates the absent dir.)
for item in engine schemas promoters templates plugin singular-ext cli migrations vendor VERSION SCHEMA_VERSION CHANGELOG.md; do
  copy "$item"
done

# Normalize exec bits (defensive against transfer mode loss).
chmod +x "$DEST/cli/singular" 2>/dev/null || true
find "$DEST/engine" "$DEST/tests" "$DEST/singular-ext" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

# current -> this version; bin launcher -> this version's CLI.
ln -sfn "$DEST" "$SINGULAR_HOME/current"
ln -sfn "$DEST/cli/singular" "$SINGULAR_HOME/bin/singular"

echo "Installed. 'current' -> $VER"

# PATH guidance.
if [[ "$SINGULAR_HOME" != "$HOME/.singular" ]]; then
  echo ""
  echo "Persist the custom install root (append to your ~/.zshrc or ~/.bashrc):"
  printf '    export SINGULAR_HOME=%q\n' "$SINGULAR_HOME"
fi
case ":$PATH:" in
  *":$SINGULAR_HOME/bin:"*) echo "$SINGULAR_HOME/bin is already on PATH." ;;
  *)
    echo ""
    echo "Add singular to PATH (append to your ~/.zshrc or ~/.bashrc):"
    if [[ "$SINGULAR_HOME" == "$HOME/.singular" ]]; then
      echo '    export PATH="$HOME/.singular/bin:$PATH"'
    else
      echo '    export PATH="$SINGULAR_HOME/bin:$PATH"'
    fi
    if [[ -w /usr/local/bin ]]; then
      ln -sfn "$SINGULAR_HOME/bin/singular" /usr/local/bin/singular
      echo "(also linked /usr/local/bin/singular for this session)"
    fi
    ;;
esac

echo ""
echo "Verify:  singular version  &&  singular doctor"
