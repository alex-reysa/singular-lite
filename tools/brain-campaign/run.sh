#!/usr/bin/env bash
set -euo pipefail
campaign_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SINGULAR_ROOT="$campaign_root"
export SINGULAR_ENGINE_HOME="$campaign_root/.singular-state/runtime/0.21.0"
export SINGULAR_JSON_CONFIG_FILE="$campaign_root/.singular-state/campaign-policy/config.json"
export SINGULAR_CONFIG_FILE=/dev/null
export SINGULAR_LOCAL_CONFIG_FILE=/dev/null
export SINGULAR_BASH_BIN="${SINGULAR_BASH_BIN:-/opt/homebrew/bin/bash}"
# Child scripts and test fixtures use /usr/bin/env bash. Pin their shell too;
# SINGULAR_BASH_BIN alone is scrubbed by the regression harness.
# Codex itself is separately pinned by absolute path in campaign config.
export PATH="/opt/homebrew/bin:/Users/alejandro/.local/share/fnm/node-versions/v24.14.0/installation/bin:$PATH"
cd "$campaign_root"
exec "$SINGULAR_BASH_BIN" "$SINGULAR_ENGINE_HOME/cli/singular" "$@"
