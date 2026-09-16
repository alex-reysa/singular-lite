#!/usr/bin/env bash
set -euo pipefail

# Focused gate for the host-managed invocation envelope, reserve accounting and
# admission boundary (TASK-1115). It runs the directly coupled Python cases and
# a finite set of LOCAL conformance checks. Nothing here calls a paid provider
# or a network service: the only provider probes are non-billable local
# `--version`/`--help` reads, and an absent CLI is recorded as unverified
# rather than reported as a pass.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- 1. Directly coupled Python cases ----------------------------------------
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
  tests.test_context_invocation.InvocationEnvelopeBudgetTest \
  || fail "coupled invocation envelope/budget cases failed"
pass "coupled invocation envelope and budget cases"

# --- 2. The two strict schema copies stay byte-identical ---------------------
cmp -s schemas/context-bundle.v1.schema.json \
       schemas/orchestration/context-bundle.v1.schema.json \
  || fail "the two context-bundle schema copies diverged"
pass "both context-bundle schema copies are identical"

# --- 3. Schema conformance of the envelope/budget contract -------------------
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY' || fail "bundle schema contract check failed"
import json
import sys
from pathlib import Path

schema = json.loads(Path("schemas/context-bundle.v1.schema.json").read_text(encoding="utf-8"))
defs = schema["$defs"]
problems = []
if "envelope" not in schema["properties"]:
    problems.append("top-level envelope property is missing")
if "envelope" in schema.get("required", []):
    problems.append("envelope must stay optional so retained bundles still validate")
budget = defs["budget"]["properties"]
for key in ("accounts", "outputReserve", "measurement"):
    if key not in budget:
        problems.append(f"budget.{key} is missing")
for key in ("accounts", "outputReserve", "measurement"):
    if key in defs["budget"].get("required", []):
        problems.append(f"budget.{key} must stay optional for retained bundles")
envelope = defs.get("envelope", {}).get("properties", {})
for key in ("version", "taskContractSha256", "role", "phase", "runId", "attemptId",
            "sessionId", "candidateRevision", "worktree", "requestedModel",
            "effectiveModel", "providerName", "providerExecutable", "providerBuild",
            "capabilityProfile", "policyVersion", "policySha256", "sourceVersions",
            "sourceVersionsSha256", "campaignBinding", "bundleSnapshotId",
            "unknownBindings", "strict"):
    if key not in envelope:
        problems.append(f"envelope.{key} is missing")
if problems:
    print("\n".join(problems), file=sys.stderr)
    raise SystemExit(1)
PY
pass "bundle schema declares the envelope and reserve accounts compatibly"

# --- 4. Capability matrix covers every provider the host composes for --------
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY' || fail "provider support matrix conformance failed"
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))
from engine import capability_policy

providers = json.loads(Path("engine/providers.json").read_text(encoding="utf-8"))["providers"]
problems = []
for name in sorted(capability_policy.PROVIDER_CONTEXT_CONTROLS):
    if name not in providers:
        problems.append(f"{name} is not a declared provider")
    matrix = capability_policy.context_control_support(name)
    if sorted(matrix) != sorted(capability_policy.CONTEXT_CONTROLS):
        problems.append(f"{name} does not cover the declared control set")
    guarantee = capability_policy.managed_boundary_guarantee(name)
    if guarantee["strictWholeProviderGuarantee"]:
        problems.append(f"{name} must not claim a whole-provider guarantee")
    if not guarantee["coverageGaps"]:
        problems.append(f"{name} must name its coverage gaps")
    if capability_policy.output_reserve_conversion(name) is not None:
        problems.append(f"{name} declares an unsupported byte/token conversion")
# Every provider the host actually composes prompts for must be represented.
for name in ("codex", "claude"):
    if name not in capability_policy.PROVIDER_CONTEXT_CONTROLS:
        problems.append(f"{name} has no declared context-control support record")
if problems:
    print("\n".join(problems), file=sys.stderr)
    raise SystemExit(1)
PY
pass "provider context-control matrix is finite and refuses whole-provider guarantees"

# --- 5. Owned documentation carries the same finite matrix -------------------
doc="docs/invocation-context-budget.md"
[[ -f "$doc" ]] || fail "$doc is missing"
for row in "Initial prompt control" "Host-broker retrieval" \
           "Resume/history inspection" "Resume/history removal" \
           "Visible tool/skill content" "Output control" "Usage observation"; do
  grep -qF "$row" "$doc" || fail "$doc does not document the '$row' control"
done
grep -qF "utf8-exact.v1" "$doc" || fail "$doc does not name the estimator identity"
grep -qF "unverified" "$doc" || fail "$doc does not record unverified controls"
pass "owned documentation carries the finite support matrix"

# --- 6. Non-billable local provider probe (pinned evidence, never a pass) -----
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/singular-context-budget.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
probe_file="$probe_dir/provider-probe.txt"
: >"$probe_file"
for binary in "${SINGULAR_CODEX_BIN:-codex}" "${SINGULAR_CLAUDE_BIN:-claude}"; do
  if command -v "$binary" >/dev/null 2>&1; then
    version="$("$binary" --version 2>&1 | head -1 || true)"
    printf '%s\tversion\t%s\n' "$binary" "${version:-<empty>}" >>"$probe_file"
  else
    printf '%s\tunverified\tlocal CLI unavailable in this host environment\n' \
      "$binary" >>"$probe_file"
  fi
done
grep -q . "$probe_file" || fail "local provider probe produced no pinned evidence"
echo "--- local non-billable provider probe ---"
cat "$probe_file"
pass "local non-billable provider probe recorded (absent CLIs stay unverified)"

echo "ALL INVOCATION CONTEXT BUDGET CHECKS PASSED"
