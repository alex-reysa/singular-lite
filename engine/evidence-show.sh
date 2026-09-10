#!/usr/bin/env bash
set -euo pipefail
# Read-only client. Mutable cumulative accounting belongs to the host broker.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$SCRIPT_DIR/evidence_delivery.py" get "$@"
