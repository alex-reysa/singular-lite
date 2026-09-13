#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ambient="$(mktemp -d)"
trap 'rm -rf "$ambient"' EXIT
mkdir -p "$ambient/.singular-state/campaign"
printf '%s\n' '{"schema":"singular.orchestration.campaign-manifest.v0","campaignId":"ambient-frozen-fixture"}' \
  >"$ambient/.singular-state/campaign/manifest.json"
printf '%s\n' '{"type":"ambient.marker"}' >"$ambient/.singular-state/events.ndjson"
before="$(shasum -a 256 "$ambient/.singular-state/campaign/manifest.json" \
  "$ambient/.singular-state/events.ndjson")"
rc=0
(
  cd "$ambient"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test_evidence_delivery.py" "$ROOT"
) || rc=$?
after="$(shasum -a 256 "$ambient/.singular-state/campaign/manifest.json" \
  "$ambient/.singular-state/events.ndjson")"
[[ "$before" == "$after" ]] || {
  echo "ambient frozen campaign or journal changed during evidence fixture" >&2
  exit 1
}
echo "ambient frozen campaign and journal unchanged"
exit "$rc"
