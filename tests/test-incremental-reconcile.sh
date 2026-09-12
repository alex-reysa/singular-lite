#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
tasks="$repo/tasks"
packets="$repo/packets"
leases="$repo/state/leases"
index="$repo/state/reconcile-index.json"
mkdir -p "$tasks" "$packets/TASK-1108" "$leases"

printf 'Task: TASK-1108\nStatus: ready\nDepends on: []\n' >"$tasks/TASK-1108.md"
printf '{"taskId":"TASK-1108","status":"accepted","headSha":"abc","branch":"worker"}\n' \
  >"$packets/TASK-1108/RUN-1.json"
printf '{"taskId":"TASK-1108","verdict":"accepted"}\n' \
  >"$packets/TASK-1108/RUN-1.audit.json"
printf '{"taskId":"TASK-1108","status":"accepted","campaignBinding":"campaign-a"}\n' \
  >"$leases/TASK-1108.json"

plan() {
  python3 "$ROOT/engine/reconcile_index.py" plan \
    --index "$index" --tasks "$tasks" --packets "$packets" --leases "$leases" \
    --target-head "$1" --policy "$2" --campaign "$3" --full-scan-every "$4"
}
commit_index() {
  python3 "$ROOT/engine/reconcile_index.py" commit \
    --index "$index" --tasks "$tasks" --packets "$packets" --leases "$leases" \
    --target-head "$1" --policy "$2" --campaign "$3" --full-scan-every "$4" >/dev/null
}
assert_plan() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["runCanonical"] is (sys.argv[2] == "yes"), doc
assert doc["metrics"]["expensiveHistoricalValidations"] == int(sys.argv[3]), doc
assert doc["authority"] == "discovery-only", doc
assert doc["schema"] == "singular.orchestration.reconcile-index-plan.v1", doc
PY
}

# Initial reconstruction schedules the canonical validator and measures work by
# count, never elapsed time. Committing records only discovery identities.
first="$(plan head-a gate-a campaign-a 50)"
assert_plan "$first" yes 1
commit_index head-a gate-a campaign-a 50

# The second unchanged cycle performs no historical content validation.
second="$(plan head-a gate-a campaign-a 50)"
assert_plan "$second" no 0

# Every dependency identity that can change canonical eligibility invalidates
# discovery. The canonical integrator remains the only acceptance authority.
for field in task packet audit lease; do
  case "$field" in
    task) printf '\nObjective: changed\n' >>"$tasks/TASK-1108.md" ;;
    packet) printf ' ' >>"$packets/TASK-1108/RUN-1.json" ;;
    audit) printf ' ' >>"$packets/TASK-1108/RUN-1.audit.json" ;;
    lease) printf ' ' >>"$leases/TASK-1108.json" ;;
  esac
  changed="$(plan head-a gate-a campaign-a 50)"
  assert_plan "$changed" yes 1
  commit_index head-a gate-a campaign-a 50
done
for args in 'head-b gate-a campaign-a' 'head-b gate-b campaign-a' 'head-b gate-b campaign-b'; do
  changed="$(plan $args 50)"
  assert_plan "$changed" yes 1
  commit_index $args 50
done

# A same-size change with restored timestamps evades the cheap identity scan,
# then is found by the bounded periodic full-content scan. The fixture advances
# deterministic scan cycles; it makes no timing-based causal claim.
python3 - "$tasks/TASK-1108.md" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
before = p.stat()
raw = p.read_bytes()
replacement = raw.replace(b"changed", b"CHANGED")
assert len(replacement) == len(raw)
p.write_bytes(replacement)
os.utime(p, ns=(before.st_atime_ns, before.st_mtime_ns))
PY
quiet="$(plan head-b gate-b campaign-b 2)"
assert_plan "$quiet" no 0
periodic="$(plan head-b gate-b campaign-b 2)"
assert_plan "$periodic" yes 1
python3 - "$periodic" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["scan"] == "full", doc
assert "content-changed" in doc["reasons"], doc
PY
commit_index head-b gate-b campaign-b 2

# Missing/corrupt state reconstructs safely. A process restart over a committed
# index remains unchanged, so discovery cannot itself duplicate publication.
printf '{broken\n' >"$index"
corrupt="$(plan head-b gate-b campaign-b 50)"
assert_plan "$corrupt" yes 1
commit_index head-b gate-b campaign-b 50
restart="$(plan head-b gate-b campaign-b 50)"
assert_plan "$restart" no 0

# A periodic content scan that finds no change advances its own watermark. It
# performs no canonical historical validation, and the following cycle returns
# to the cheap identity scan instead of scanning full history forever.
unchanged_full="$(plan head-b gate-b campaign-b 2)"
assert_plan "$unchanged_full" no 0
python3 - "$unchanged_full" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["scan"] == "full", doc
assert doc["metrics"]["contentHashes"] > 0, doc
PY
after_unchanged_full="$(plan head-b gate-b campaign-b 2)"
assert_plan "$after_unchanged_full" no 0
python3 - "$after_unchanged_full" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["scan"] == "quick", doc
assert doc["metrics"]["contentHashes"] == 0, doc
PY

echo "PASS: test-incremental-reconcile"
