#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_SOURCE="${SCHEMA_OWNERSHIP_ENGINE_SOURCE:-$ROOT}"
BASH_BIN="${SINGULAR_BASH_BIN:-/opt/homebrew/bin/bash}"
PYTHON_BIN_DIR="/Library/Frameworks/Python.framework/Versions/3.12/bin"
export PATH="$PYTHON_BIN_DIR:$PATH"
export PYTHONDONTWRITEBYTECODE=1
tmp="$(mktemp -d)"
cleanup() {
  # Only the disposable copy may have restrictive fixture modes. Never chmod
  # the source engine merely to make teardown succeed.
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
repo="$tmp/repo"
mkdir -p "$repo/schemas/orchestration"
git -C "$tmp" init -q repo

write_config() {
  printf '{"schemaVersion":"%s"}\n' "$1" >"$repo/singular.config.json"
}

# A consumer that has not migrated must keep its prior schema bytes and must not
# receive any new v2 contract merely because scaffold runs.
write_config v1
printf '{"stale":true}\n' >"$repo/schemas/orchestration/dag.v0.schema.json"
before="$(shasum -a 256 "$repo/schemas/orchestration/dag.v0.schema.json" | awk '{print $1}')"
SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ENGINE_SOURCE" "$BASH_BIN" "$ENGINE_SOURCE/engine/scaffold.sh"
after="$(shasum -a 256 "$repo/schemas/orchestration/dag.v0.schema.json" | awk '{print $1}')"
[[ "$before" == "$after" ]] || {
  echo "pre-migration scaffold rewrote an existing v1 mirror" >&2
  exit 1
}
[[ ! -e "$repo/schemas/orchestration/human-gate.v0.schema.json" ]] || {
  echo "pre-migration scaffold introduced a v2 schema" >&2
  exit 1
}

# Once migration bookkeeping says v2, the engine bundle is authoritative:
# stale copies are replaced, every basename is mirrored byte-for-byte, and an
# unrecognized consumer extension remains consumer-owned.
printf '%s\n' '{"consumerExtension":true}' \
  >"$repo/schemas/orchestration/acme-extension.v0.schema.json"
cp "$repo/schemas/orchestration/acme-extension.v0.schema.json" "$tmp/acme-extension.before.json"
write_config v2
SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ENGINE_SOURCE" "$BASH_BIN" "$ENGINE_SOURCE/engine/scaffold.sh"
while IFS= read -r schema; do
  mirror="$repo/schemas/orchestration/$(basename "$schema")"
  cmp -s "$schema" "$mirror" || {
    echo "post-migration scaffold mirror mismatch: $(basename "$schema")" >&2
    exit 1
  }
done < <(find "$ENGINE_SOURCE/schemas" -maxdepth 1 -type f -name '*.schema.json' | sort)
cmp -s "$tmp/acme-extension.before.json" \
  "$repo/schemas/orchestration/acme-extension.v0.schema.json" || {
  echo "explicit scaffold changed consumer-only schema extension" >&2
  exit 1
}

# Exercise the public frozen-campaign reconcile entrypoint against a disposable
# consumer. The engine copy is made writable only while it is assembled, then
# frozen; the source checkout is never chmodded or instrumented.
frozen="$tmp/frozen-engine"
mkdir -p "$frozen"
for item in engine schemas templates vendor singular-ext cli; do
  cp -R "$ENGINE_SOURCE/$item" "$frozen/$item"
done
cp "$ENGINE_SOURCE/VERSION" "$ENGINE_SOURCE/SCHEMA_VERSION" "$frozen/"
# The campaign canary makes and instruments its own nested engine fixture, so
# its input copy must remain owner-writable during setup. Campaign publication
# below freezes and verifies the exact resulting bytes and modes.
chmod -R u+w "$frozen"

campaign_repo="$tmp/campaign-consumer"
mkdir -p "$campaign_repo"
git -C "$campaign_repo" init -q
git -C "$campaign_repo" checkout -q -b integration
git -C "$campaign_repo" config user.name schema-ownership-test
git -C "$campaign_repo" config user.email schema-ownership@example.test
python3 - "$campaign_repo/singular.config.json" "$frozen/engine/codex-run.sh" <<'PY'
import json
import sys

path, runner = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": "v2",
        "targetBranch": "integration",
        "gateCommand": "true",
        "runner": runner,
        "bootstrap": {"required": False, "commands": []},
        "controlState": {"commitIntervalSeconds": 86400},
    }, handle, indent=2)
    handle.write("\n")
PY

run_frozen() {
  local script="$1"
  shift
  (
    cd "$campaign_repo"
    env \
      PYTHONDONTWRITEBYTECODE=1 \
      SINGULAR_BASH_BIN="$BASH_BIN" \
      SINGULAR_ROOT="$campaign_repo" \
      SINGULAR_ENGINE_HOME="$frozen" \
      SINGULAR_CODEX_BIN="$tmp/missing-codex" \
      SINGULAR_RECONCILE_SCRIPT="$frozen/engine/reconcile.sh" \
      SINGULAR_PUSH=1 \
      SINGULAR_GENERATE=1 \
      SINGULAR_AUTO_INTEGRATE=1 \
      SINGULAR_SLEEP=20 \
      SINGULAR_QUOTA_SLEEP_CAP=300 \
      SINGULAR_QUOTA_WAIT_BUDGET=10800 \
      SINGULAR_OVERLOAD_WAIT_BUDGET=3600 \
      SINGULAR_CAMPAIGN_PROBE_TIMEOUT_SEC=10 \
      "$BASH_BIN" "$frozen/engine/$script" "$@"
  )
}

publish_frozen_campaign_fixture() {
  # campaign start currently depends on the repository-wide lifecycle canary,
  # whose unrelated audit fixture is not part of this schema regression. Use
  # the canonical manifest producer, then prove the public verifier accepts the
  # complete ACTIVE/manifest/epoch/latch state before any reconcile call.
  (
    cd "$campaign_repo"
    env \
      PYTHONDONTWRITEBYTECODE=1 \
      SINGULAR_BASH_BIN="$BASH_BIN" \
      SINGULAR_ROOT="$campaign_repo" \
      SINGULAR_ENGINE_HOME="$frozen" \
      SINGULAR_CODEX_BIN="$tmp/missing-codex" \
      SINGULAR_RECONCILE_SCRIPT="$frozen/engine/reconcile.sh" \
      SINGULAR_PUSH=1 SINGULAR_GENERATE=1 SINGULAR_AUTO_INTEGRATE=1 \
      SINGULAR_SLEEP=20 SINGULAR_QUOTA_SLEEP_CAP=300 \
      SINGULAR_QUOTA_WAIT_BUDGET=10800 SINGULAR_OVERLOAD_WAIT_BUDGET=3600 \
      SINGULAR_CAMPAIGN_PROBE_TIMEOUT_SEC=10 \
      "$BASH_BIN" -s -- "$frozen" "$campaign_repo" <<'SH'
set -euo pipefail
engine="$1"
repo="$2"
source "$engine/engine/lib.sh"

while IFS= read -r name; do
  declaration="$(declare -p "$name" 2>/dev/null || true)"
  declaration_flags="${declaration#declare -}"
  declaration_flags="${declaration_flags%% *}"
  case "$declaration_flags" in
    *a*|*A*) continue ;;
  esac
  export "$name"
done < <(compgen -A variable SINGULAR_ | sort)

manifest="$SINGULAR_STATE_DIR/campaign/manifest.json"
epoch="000000000000000000000000000000000000000000000001"
mkdir -p "$(dirname "$manifest")"
planner_template="${SINGULAR_PLANNER_TEMPLATE:-$SINGULAR_ORCH_DIR/prompts/l1-planner.md}"
critic_template="${SINGULAR_PLAN_CRITIC_TEMPLATE:-$SINGULAR_ORCH_DIR/prompts/plan-critic.md}"
context_config="${SINGULAR_CONTEXT_CONFIG_FILE:-$SINGULAR_JSON_CONFIG_FILE}"
python3 "$engine/engine/campaign_manifest.py" create \
  --output "$manifest" --campaign-id schema-ownership-regression \
  --campaign-epoch "$epoch" --provider-assurance deterministic-test-fixture \
  --engine-home "$SINGULAR_ENGINE_HOME" \
  --config-json "$SINGULAR_JSON_CONFIG_FILE" \
  --config-shell "$SINGULAR_CONFIG_FILE" \
  --config-local "$SINGULAR_LOCAL_CONFIG_FILE" \
  --bash-bin "$(singular_bash_bin)" --runner "${SINGULAR_RUNNER:-}" \
  --gate-command "${SINGULAR_DEFAULT_GATE_CMD:-}" \
  --gate-driver "$engine/engine/gate-check.sh" \
  --gate-schema "$SINGULAR_GATE_SCHEMA" \
  --evidence-driver "$engine/engine/evidence-manifest.sh" \
  --packet-schema "$SINGULAR_PACKET_SCHEMA" \
  --audit-schema "$SINGULAR_AUDIT_SCHEMA" \
  --active-policy "consumer-prompts=$SINGULAR_ORCH_DIR/prompts" \
  --active-policy "engine-prompt-fallbacks=$SINGULAR_ENGINE_HOME/templates/prompts" \
  --active-policy "consumer-planner-contract=$SINGULAR_ORCH_DIR/planner-contract.md" \
  --active-policy "campaign-dag=${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}" \
  --active-policy "active-schema-root=$SINGULAR_SCHEMA_DIR" \
  --active-policy "secret-patterns=${SINGULAR_SECRET_PATTERNS_FILE:-}" \
  --active-policy "planner-template=$planner_template" \
  --active-policy "critic-template=$critic_template" \
  --active-policy "promoter=${SINGULAR_PROMOTER:-}" \
  --active-policy "reconcile-driver=${SINGULAR_RECONCILE_SCRIPT:-$engine/engine/reconcile.sh}" \
  --active-policy "gate-baseline=${SINGULAR_GATE_BASELINE_FILE:-}" \
  --active-policy "context-service-config=$context_config" >/dev/null
printf '%s\n' schema-ownership-regression >"$(dirname "$manifest")/ACTIVE"
printf '%s\n' "$epoch" >"$(dirname "$manifest")/EPOCH"
printf '%s\n' singular-campaign-enforced-v1 >"$SINGULAR_STATE_DIR/CAMPAIGN_ENFORCED"
SH
  )
}

run_frozen scaffold.sh
cat >"$campaign_repo/docs/orchestration/dag.v0.json" <<'JSON'
{
  "schema": "singular.orchestration.dag.v0",
  "layers": ["scaffold"],
  "kinds": ["test"],
  "nodes": []
}
JSON
cat >>"$campaign_repo/docs/orchestration/project-state.md" <<'EOF'

<!-- singular:reconcile-snapshot:start -->
Baseline committed before the frozen campaign.
<!-- singular:reconcile-snapshot:end -->
EOF
git -C "$campaign_repo" add .
git -C "$campaign_repo" commit -qm 'initial singular scaffold'

publish_frozen_campaign_fixture
manifest="$campaign_repo/.singular-state/campaign/manifest.json"
[[ -f "$manifest" ]] || {
  echo "frozen campaign did not publish a manifest" >&2
  exit 1
}

# Model the later task's legitimate, integrated context-contract extension.
context_mirror="$campaign_repo/schemas/orchestration/context-bundle.v1.schema.json"
chmod u+w "$context_mirror"
python3 - "$context_mirror" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    schema = json.load(handle)
schema["x-consumer-integrated-change"] = {"task": "TASK-1115"}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(schema, handle, indent=2)
    handle.write("\n")
PY
chmod 0755 "$context_mirror"
git -C "$campaign_repo" add schemas/orchestration/context-bundle.v1.schema.json
git -C "$campaign_repo" commit -qm 'integrate context schema extension'
integrated_head="$(git -C "$campaign_repo" rev-parse HEAD)"
integrated_sha="$(shasum -a 256 "$context_mirror" | awk '{print $1}')"
integrated_mode="$(stat -f '%Lp' "$context_mirror")"

# Record real gate/source evidence on the integrated tree before reconciliation.
run_frozen campaign.sh verify --quiet
run_frozen gate-check.sh RUN-SCHEMA-OWNERSHIP \
  --task-id TASK-1115 -- true >/dev/null
gate_report="$campaign_repo/.singular-state/runs/RUN-SCHEMA-OWNERSHIP/gate-report.json"
gate_source="$campaign_repo/.singular-state/runs/RUN-SCHEMA-OWNERSHIP/gate-source-after.json"
python3 - "$manifest" "$gate_report" "$frozen" <<'PY'
import json
import pathlib
import sys

manifest_path, report_path, frozen = sys.argv[1:]
manifest = json.load(open(manifest_path, encoding="utf-8"))
report = json.load(open(report_path, encoding="utf-8"))
assert manifest["engine"]["sourceFingerprint"], manifest
schema_policy = manifest["activePolicy"]["active-schema-root"]
assert pathlib.Path(schema_policy["resolvedPath"]) == pathlib.Path(frozen, "schemas").resolve(), schema_policy
assert report["outcome"] == "passed", report
assert report["sourceIntegrity"]["status"] == "verified", report
PY
manifest_sha="$(shasum -a 256 "$manifest" | awk '{print $1}')"
gate_report_sha="$(shasum -a 256 "$gate_report" | awk '{print $1}')"

assert_integrated_source_unchanged() {
  local label="$1"
  [[ "$(shasum -a 256 "$context_mirror" | awk '{print $1}')" == "$integrated_sha" ]] || {
    echo "$label rewrote the integrated context schema" >&2
    exit 1
  }
  [[ "$(stat -f '%Lp' "$context_mirror")" == "$integrated_mode" ]] || {
    echo "$label changed the integrated context schema mode" >&2
    exit 1
  }
  [[ "$(git -C "$campaign_repo" rev-parse HEAD)" == "$integrated_head" ]] || {
    echo "$label changed the integrated consumer HEAD" >&2
    exit 1
  }
  [[ -z "$(git -C "$campaign_repo" status --porcelain=v1 --untracked-files=all)" ]] || {
    echo "$label dirtied the integrated consumer source" >&2
    git -C "$campaign_repo" status --short >&2
    exit 1
  }
  [[ "$(shasum -a 256 "$manifest" | awk '{print $1}')" == "$manifest_sha" ]] || {
    echo "$label changed frozen campaign evidence" >&2
    exit 1
  }
  [[ "$(shasum -a 256 "$gate_report" | awk '{print $1}')" == "$gate_report_sha" ]] || {
    echo "$label changed gate evidence" >&2
    exit 1
  }
  run_frozen campaign.sh verify --quiet
}

run_frozen reconcile.sh --dry-run >"$tmp/reconcile-dry-run.log"
assert_integrated_source_unchanged "dry-run reconcile"
run_frozen reconcile.sh --apply >"$tmp/reconcile-apply.log"
assert_integrated_source_unchanged "apply reconcile"

# The gate's tracked-source snapshot remains byte-for-byte current because the
# existing mirror was never opened for replacement, even by apply mode.
current_source="$campaign_repo/.singular-state/current-source.json"
run_frozen_shell='source "$1/engine/lib.sh"; singular_tracked_source_snapshot "$2" "$3"'
(
  cd "$campaign_repo"
  env PYTHONDONTWRITEBYTECODE=1 SINGULAR_BASH_BIN="$BASH_BIN" \
    SINGULAR_ROOT="$campaign_repo" SINGULAR_ENGINE_HOME="$frozen" \
    SINGULAR_CODEX_BIN="$tmp/missing-codex" \
    SINGULAR_RECONCILE_SCRIPT="$frozen/engine/reconcile.sh" SINGULAR_PUSH=1 \
    SINGULAR_GENERATE=1 SINGULAR_AUTO_INTEGRATE=1 \
    SINGULAR_SLEEP=20 SINGULAR_QUOTA_SLEEP_CAP=300 \
    SINGULAR_QUOTA_WAIT_BUDGET=10800 SINGULAR_OVERLOAD_WAIT_BUDGET=3600 \
    SINGULAR_CAMPAIGN_PROBE_TIMEOUT_SEC=10 \
    "$BASH_BIN" -c "$run_frozen_shell" bash "$frozen" "$campaign_repo" "$current_source"
)
python3 - "$gate_source" "$current_source" <<'PY' || {
import json
import sys

before = json.load(open(sys.argv[1], encoding="utf-8"))
after = json.load(open(sys.argv[2], encoding="utf-8"))
semantic = ("missing", "kind", "mode", "size", "sha256")
for path in sorted(set(before) | set(after)):
    old = before.get(path) or {}
    new = after.get(path) or {}
    assert {key: old.get(key) for key in semantic} == {
        key: new.get(key) for key in semantic
    }, path
PY
  echo "reconcile invalidated the gate's tracked source bytes or modes" >&2
  python3 - "$gate_source" "$current_source" <<'PY' >&2
import json
import sys

before = json.load(open(sys.argv[1], encoding="utf-8"))
after = json.load(open(sys.argv[2], encoding="utf-8"))
semantic = ("missing", "kind", "mode", "size", "sha256")
for path in sorted(set(before) | set(after)):
    old = before.get(path) or {}
    new = after.get(path) or {}
    if ({key: old.get(key) for key in semantic}
            != {key: new.get(key) for key in semantic}):
        print(path)
PY
  exit 1
}

# Preserve mode still provisions a missing baseline mirror. Deleting a tracked
# canonical copy and reconciling restores engine bytes/mode and a clean tree.
missing_mirror="$campaign_repo/schemas/orchestration/context-graph.v0.schema.json"
chmod u+w "$missing_mirror"
rm "$missing_mirror"
run_frozen reconcile.sh --dry-run >"$tmp/reconcile-missing.log"
cmp -s "$frozen/schemas/context-graph.v0.schema.json" "$missing_mirror" || {
  echo "routine reconcile did not provision a missing baseline schema" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$missing_mirror")" == \
    "$(stat -f '%Lp' "$frozen/schemas/context-graph.v0.schema.json")" ]] || {
  echo "routine reconcile provisioned a missing baseline with the wrong mode" >&2
  exit 1
}
[[ -z "$(git -C "$campaign_repo" status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "missing baseline repair did not restore a clean consumer" >&2
  exit 1
}
run_frozen reconcile.sh --apply >"$tmp/reconcile-missing-apply.log"
run_frozen campaign.sh verify --quiet

echo "schema scaffold sync tests passed"
