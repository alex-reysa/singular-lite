#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
run="$repo/.singular-state/runs/RUN-evidence"
mkdir -p "$repo/src" "$run/worker-evidence"
git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'old\n' >"$repo/src/value.txt"
git -C "$repo" add src/value.txt
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"
printf 'new\n' >"$repo/src/value.txt"
git -C "$repo" add src/value.txt
git -C "$repo" commit -qm change
head="$(git -C "$repo" rev-parse HEAD)"

python3 - "$run/worker-evidence/huge.log" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("assertion: " + ("x" * 10000), encoding="utf-8")
PY
cp "$run/worker-evidence/huge.log" "$run/gate-check.log"
printf 'scope clean\n' >"$run/scope-check.log"
printf 'secret log exists but has no structured result\n' >"$run/secret-scan.log"
cat >"$run/packet.json" <<JSON
{
  "schema": "singular.orchestration.state-packet.v0",
  "taskId": "TASK-0001",
  "runId": "RUN-evidence",
  "headSha": "$head",
  "baseRef": "$base",
  "changedFiles": ["src/value.txt"],
  "commands": [
    {
      "cmd": "run tests",
      "exitCode": 1,
      "logRef": "worker-evidence/huge.log"
    }
  ]
}
JSON
command_sha="$(printf '%s' 'run tests' | shasum -a 256 | awk '{print $1}')"
cat >"$run/gate-observation.json" <<'JSON'
{
  "schema": "singular.orchestration.gate-observation.v0",
  "failures": [{"signature": "known"}]
}
JSON
cat >"$run/gate-baseline.json" <<JSON
{
  "schema": "singular.orchestration.gate-baseline.v0",
  "commandSha256": "$command_sha",
  "failures": [{"signature": "known"}],
  "acknowledgedBy": "owner",
  "recordedAt": "2026-07-24T10:00:00Z"
}
JSON
# --log-ref is the REPOSITORY-relative citation gate-check.sh emits (0.15.1);
# --log-path is the absolute file. This reader resolves a relative logRef
# against the RUN directory, so a repo-relative ref misses and the gate would
# silently downgrade to "inconclusive" unless it reads logPath. Using the ref
# form gate-check.sh really produces is what makes the assertion below a guard
# rather than a coincidence -- an absolute --log-ref satisfies both readers and
# proves nothing.
python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-0001 --run-id RUN-evidence --head-sha "$head" \
  --command "run tests" --raw-exit-code 1 \
  --log-ref ".singular-state/runs/RUN-evidence/gate-check.log" \
  --log-path "$run/gate-check.log" \
  --observation "$run/gate-observation.json" --baseline "$run/gate-baseline.json" \
  --integrity-status verified --phase worker --workspace-kind worker \
  --output "$run/gate-report.json" >/dev/null
SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
  bash -c 'source "$1"; singular_check_result_write "$2" scope passed 0 "$3"' \
  _ "$ROOT/engine/lib.sh" "$run/scope-check-result.json" "$run/scope-check.log"
SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
  bash -c 'source "$1"; singular_check_result_write "$2" secret passed 0 "$3"' \
  _ "$ROOT/engine/lib.sh" "$run/secret-scan-result.json" "$run/secret-scan.log"
cat >"$run/worker-runner-result.json" <<'JSON'
{
  "schema": "singular.orchestration.runner-result.v0",
  "usage": {
    "inputTokens": 4200,
    "cachedInputTokens": 1000,
    "outputTokens": 300
  }
}
JSON
cat >"$run/auditor-attempt-1-try-0-runner-result.json" <<'JSON'
{
  "schema": "singular.orchestration.runner-result.v0",
  "role": "auditor",
  "usage": {
    "inputTokens": 8000,
    "cachedInputTokens": 2000,
    "outputTokens": 500
  }
}
JSON

export SINGULAR_EVIDENCE_CAMPAIGN_BINDING="campaign:fixture-stable"
evidence_config='{"maxComposedBytes":65536,"maxExcerptBytes":128,"retrievalBudgetBytes":200,"auditInputTokenCanary":10000}'
SINGULAR_EVIDENCE_CONFIG_JSON="$evidence_config" "$ROOT/engine/evidence-manifest.sh" \
  --run-dir "$run" --task-id TASK-0001 --worktree "$repo" \
  --base-ref "$base" --head-sha "$head" >/dev/null

python3 - "$run/evidence-manifest.json" <<'PY'
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
assert data["schema"] == "singular.orchestration.evidence-manifest.v0"
assert data["diffSha256"]
assert data["files"][0]["path"] == "src/value.txt"
assert data["expectedFailureCount"] == 1
assert data["unexpectedFailureCount"] == 0
assert data["checks"]["scope"]["status"] == "passed"
assert data["checks"]["secret"]["status"] == "passed"
assert data["checks"]["gate"]["status"] == "passed"
assert data["budget"]["limitBytes"] == 65536
assert data["budget"]["composedBytes"] <= 65536
assert data["budget"]["excerptLimitBytes"] == 128
assert data["budget"]["retrievalLimitBytes"] == 200
assert data["budget"]["auditInputTokenCanary"] == 10000
assert data["budget"]["actualAuditInputTokens"] == 8000
assert max(len(c.get("excerpt", "")) for c in data["commands"]) <= 128
assert any(a["ref"] == "worker-evidence/huge.log" for a in data["artifacts"])
assert any(
    a["ref"] == "auditor-attempt-1-try-0-runner-result.json"
    for a in data["artifacts"]
)
diff_artifact = next(a for a in data["artifacts"] if a["ref"] == "committed.diff")
diff_bytes = (path.parent / diff_artifact["ref"]).read_bytes()
assert hashlib.sha256(diff_bytes).hexdigest() == data["diffSha256"]
assert diff_artifact["sha256"] == data["diffSha256"]
assert data["providerUsage"] == {
    "inputTokens": 12200,
    "cachedInputTokens": 3000,
    "outputTokens": 800,
}
PY

# Exact packet identity and a structured passing secret result are deterministic
# evidence inputs. Re-running unchanged bad bytes must fail with the dedicated
# input-rejection exit and leave the last valid manifest intact.
manifest_sha="$(shasum -a 256 "$run/evidence-manifest.json" | awk '{print $1}')"
cp "$run/packet.json" "$tmp/packet.valid.json"
python3 - "$run/packet.json" <<'PY'
import json, sys
path = sys.argv[1]
packet = json.load(open(path, encoding="utf-8"))
packet["changedFiles"] = ["worker-invented.txt"]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(packet, stream); stream.write("\n")
PY
rc=0
SINGULAR_EVIDENCE_CONFIG_JSON="$evidence_config" "$ROOT/engine/evidence-manifest.sh" \
  --run-dir "$run" --task-id TASK-0001 --worktree "$repo" \
  --base-ref "$base" --head-sha "$head" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "packet delta mismatch was not deterministic rc=2" >&2; exit 1; }
[[ "$(shasum -a 256 "$run/evidence-manifest.json" | awk '{print $1}')" == "$manifest_sha" ]] \
  || { echo "packet mismatch replaced the valid manifest" >&2; exit 1; }
cp "$tmp/packet.valid.json" "$run/packet.json"

cp "$run/secret-scan-result.json" "$tmp/secret.valid.json"
python3 - "$run/secret-scan-result.json" <<'PY'
import json, sys
path = sys.argv[1]
result = json.load(open(path, encoding="utf-8"))
result["status"] = "not-run"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(result, stream); stream.write("\n")
PY
rc=0
SINGULAR_EVIDENCE_CONFIG_JSON="$evidence_config" "$ROOT/engine/evidence-manifest.sh" \
  --run-dir "$run" --task-id TASK-0001 --worktree "$repo" \
  --base-ref "$base" --head-sha "$head" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo "not-run secret result was not deterministic rc=2" >&2; exit 1; }
cp "$tmp/secret.valid.json" "$run/secret-scan-result.json"

canary_warning="$tmp/canary-warning.log"
cp "$run/evidence-manifest.json" "$tmp/evidence-manifest-before-canary.json"
SINGULAR_EVIDENCE_CONFIG_JSON='{"auditInputTokenCanary":8000}' \
  "$ROOT/engine/evidence-manifest.sh" \
    --run-dir "$run" --task-id TASK-0001 --worktree "$repo" \
    --base-ref "$base" --head-sha "$head" >/dev/null 2>"$canary_warning"
grep -q 'warning: auditor input-token canary exceeded (8000 >= 8000)' "$canary_warning" || {
  echo "expected an inclusive auditor input-token telemetry warning" >&2
  exit 1
}
python3 - "$run/evidence-manifest.json" <<'PY'
import json, sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["budget"]["auditInputTokenCanary"] == 8000
assert manifest["budget"]["actualAuditInputTokens"] == 8000
PY
# Host regeneration must preserve the original domain when a caller omits it.
unset SINGULAR_EVIDENCE_CAMPAIGN_BINDING
SINGULAR_EVIDENCE_CONFIG_JSON="$evidence_config" "$ROOT/engine/evidence-manifest.sh" \
  --run-dir "$run" --task-id TASK-0001 --worktree "$repo" \
  --base-ref "$base" --head-sha "$head" >/dev/null
if SINGULAR_EVIDENCE_CAMPAIGN_BINDING="changed" "$ROOT/engine/evidence-manifest.sh" \
  --run-dir "$run" --task-id TASK-0001 --worktree "$repo" \
  --base-ref "$base" --head-sha "$head" >/dev/null 2>&1; then
  echo "manifest refresh changed accounting campaign" >&2; exit 1
fi
python3 - "$run/evidence-manifest.json" <<'BINDING'
import json, sys
assert json.load(open(sys.argv[1]))['campaignBinding'] == 'campaign:fixture-stable'
BINDING
# The retrieval assertions below intentionally exercise the original 200-byte
# manifest budget. Restore those exact bytes after this independent canary case.
cp "$tmp/evidence-manifest-before-canary.json" "$run/evidence-manifest.json"

cat >"$tmp/retrieve.sh" <<'RETRIEVE'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"; run="$2"; tmp="$3"
"$ROOT/engine/evidence-show.sh" "$run/evidence-manifest.json" \
  worker-evidence/huge.log 128 >"$tmp/excerpt"
[[ "$(wc -c <"$tmp/excerpt" | tr -d ' ')" -lt 256 ]]
"$ROOT/engine/evidence-show.sh" "$run/evidence-manifest.json" \
  worker-evidence/huge.log 128 >"$tmp/excerpt-two"
[[ "$(wc -c <"$tmp/excerpt-two" | tr -d ' ')" -lt 200 ]]
if "$ROOT/engine/evidence-show.sh" "$run/evidence-manifest.json" \
  worker-evidence/huge.log 1 >/dev/null 2>&1; then
  echo "expected cumulative evidence budget to be exhausted" >&2
  exit 1
fi

printf 'tamper\n' >>"$run/worker-evidence/huge.log"
if "$ROOT/engine/evidence-show.sh" "$run/evidence-manifest.json" \
  worker-evidence/huge.log 128 >/dev/null 2>&1; then
  echo "expected tampered evidence to be rejected" >&2
  exit 1
fi

RETRIEVE
consumer="$tmp/consumer"
mkdir -p "$consumer/.singular-state"
git -C "$consumer" init -q
(
  cd "$consumer"
  unset SINGULAR_JSON_CONFIG_FILE SINGULAR_JSON_CONFIG_SOURCE \
    SINGULAR_CONFIG_PROVENANCE_FILE SINGULAR_CAMPAIGN_MANIFEST
  SINGULAR_ROOT="$consumer" \
  SINGULAR_STATE_DIR="$consumer/.singular-state" \
  SINGULAR_ENGINE_HOME="$ROOT" \
  SINGULAR_CONFIG_FILE=/dev/null \
  SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
  SINGULAR_BASH_BIN=/opt/homebrew/bin/bash \
  python3 "$ROOT/engine/evidence_delivery.py" run \
    --manifest "$run/evidence-manifest.json" --ledger "$tmp/delivery.sqlite3" -- \
    "$BASH" "$tmp/retrieve.sh" "$ROOT" "$run" "$tmp"
)

echo "evidence manifest tests passed"
