#!/usr/bin/env bash
set -euo pipefail
# Packet extraction tolerates bounded structural LLM quirks (field run
# 2026-09-14: a successful worker closed the `nextAction` string with `"]`,
# the engine saw "no packet", parked the unchanged candidate and the queue
# deadlocked). Values are never invented; a real non-packet still fails.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$tmp/.singular-state"
source "$ROOT/engine/lib.sh" >/dev/null

fixture="$ROOT/tests/fixtures/worker-packet/stray-bracket-field-run.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$fixture" 2>/dev/null \
  && fail "fixture unexpectedly parses as JSON; the test would prove nothing"

# 1. The field-run packet is recovered, with every value intact.
singular_extract_json "$fixture" "$tmp/out.json" 2>"$tmp/err" || fail "field-run packet not recovered: $(cat "$tmp/err")"
grep -q "packet repaired: dropped unmatched ']'" "$tmp/err" || fail "repair not logged: $(cat "$tmp/err")"
python3 - "$tmp/out.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == "singular.orchestration.state-packet.v0", d["schema"]
assert d["taskId"] == "TASK-1117" and d["runId"] == "RUN-20260914T151954Z-17409"
assert isinstance(d["nextAction"], str) and d["nextAction"].startswith("Hand the exact preserved source")
assert d["status"] == "needs-review" and d["changedFiles"] == []
assert d["createdAt"] == "2026-09-14T15:28:23Z"
PY
pass "field-run packet with a stray ']' is recovered unchanged"

# 2. A valid packet is untouched (no repair log line).
printf '{"schema":"x","nextAction":"a","n":[1,2]}\n' >"$tmp/valid.json"
singular_extract_json "$tmp/valid.json" "$tmp/valid.out" 2>"$tmp/err2" || fail "valid packet refused"
[[ ! -s "$tmp/err2" ]] || fail "valid packet reported a repair: $(cat "$tmp/err2")"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["n"][1])' "$tmp/valid.out")" == 2 ]] || fail "valid packet altered"
pass "valid packet passes through untouched"

# 3. Trailing comma and an unclosed object at the end are repaired; a bracket
#    inside a string is never touched.
printf 'Done. {"schema":"x","note":"keep ] this","list":[1,2,],"nextAction":"go",\n' >"$tmp/tail.json"
singular_extract_json "$tmp/tail.json" "$tmp/tail.out" 2>"$tmp/err3" || fail "trailing-comma/unclosed packet not recovered: $(cat "$tmp/err3")"
python3 - "$tmp/tail.out" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["note"] == "keep ] this", d
assert d["list"] == [1, 2] and d["nextAction"] == "go"
PY
pass "trailing comma and unclosed object repaired; string content preserved"

# 4. Prose with no object at all is still "no packet".
printf 'I could not produce a packet.\n' >"$tmp/prose.json"
if singular_extract_json "$tmp/prose.json" "$tmp/prose.out" 2>"$tmp/err4"; then fail "prose accepted as a packet"; fi
grep -q "no parseable JSON object found" "$tmp/err4" || fail "unexpected prose error: $(cat "$tmp/err4")"
pass "prose without an object is still refused"
# 5. A complete packet lacking only createdAt is defaulted by the host, not refused.
singular_extract_json "$fixture" "$tmp/base.json" 2>/dev/null
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("createdAt"); json.dump(d, open(sys.argv[2],"w"))' "$tmp/base.json" "$tmp/nocreated.json"
SINGULAR_PACKET_SCHEMA="$ROOT/schemas/orchestration/state-packet.v0.schema.json" singular_validate_packet_basic "$tmp/nocreated.json" 2>"$tmp/err5" || fail "packet without createdAt refused: $(cat "$tmp/err5")"
grep -q "defaulted missing createdAt" "$tmp/err5" || fail "createdAt default not logged"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["createdAt"].endswith("Z"), d' "$tmp/nocreated.json"
pass "missing createdAt is defaulted by the host"
echo "test-worker-packet-repair: ok"
