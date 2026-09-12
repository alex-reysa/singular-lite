#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_context_invocation

