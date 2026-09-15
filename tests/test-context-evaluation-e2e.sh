#!/usr/bin/env bash
# B5 completion test: the evaluator computes the known labeled-corpus metrics,
# the campaign analyser reports real campaign shapes and preserves missing-data
# semantics, and both run through the public launcher from a foreign cwd
# without any paid provider.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-context-eval-e2e.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

while IFS= read -r inherited_name; do unset "$inherited_name"; done \
  < <(compgen -v | grep '^SINGULAR_' || true)
unset inherited_name

cd "$ROOT"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_context_evaluation

# ---------------------------------------------------------------------------
# Labeled retrieval corpus through the public launcher, from a foreign cwd.
# ---------------------------------------------------------------------------
corpus="$tmp/corpus with spaces"
cp -Rp "$ROOT/tests/fixtures/context-evaluation" "$corpus"
node "$ROOT/vendor/singular-brain/engine/cli.mjs" \
  --config "$corpus/project/brain/singular-brain.config.json" gen >/dev/null
# The launcher binds a consumer repository like every other subcommand, so the
# foreign invocation directory is a separate repository nested nowhere near the
# corpus it measures.
invoke="$tmp/foreign/cwd"
mkdir -p "$invoke"
git -C "$tmp/foreign" init -q

context() {
  ( cd "$invoke" && SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/cli/singular" context "$@" )
}

report="$tmp/evaluation-report.json"
context evaluate --corpus "$corpus/corpus.json" --output "$report" >"$tmp/evaluate.json"

python3 - "$tmp/evaluate.json" "$report" "$corpus/corpus.json" <<'PY'
import json, sys
emitted = json.load(open(sys.argv[1], encoding="utf-8"))
published = json.load(open(sys.argv[2], encoding="utf-8"))
corpus = json.load(open(sys.argv[3], encoding="utf-8"))
assert emitted == published, "published report differs from stdout"
assert emitted["schema"] == "singular.context.evaluation-report.v1"
assert emitted["status"] == "ok", emitted["status"]
assert emitted["matchesExpected"] is True
assert emitted["deviations"] == []
metrics = emitted["metrics"]
assert metrics["missingLabels"] == [], metrics["missingLabels"]
assert set(corpus["requiredLabels"]) <= set(metrics["coverage"]), metrics["coverage"]
assert metrics["inclusion"]["recall"] == 1.0
assert metrics["incorrectSelections"] == 0
assert metrics["failures"] == 0
assert metrics["cases"] == corpus["expectedMetrics"]["cases"]
assert metrics["budgetOmissions"] == corpus["expectedMetrics"]["budgetOmissions"]
assert metrics["abstentions"] == corpus["expectedMetrics"]["abstentions"]
assert metrics["refusals"] == corpus["expectedMetrics"]["refusals"]
# Real input identities, not invented ones.
assert emitted["corpus"]["sha256"].startswith("sha256:")
assert emitted["corpus"]["path"].endswith("corpus.json")
PY

# A corpus whose declared metrics no longer hold deviates loudly (exit 4) and
# still publishes the measured report.
# The drifted copy lives beside the corpus so it resolves the same project.
drifted="$corpus/drifted-corpus.json"
python3 - "$corpus/corpus.json" "$drifted" <<'PY'
import json, sys
corpus = json.load(open(sys.argv[1], encoding="utf-8"))
corpus["expectedMetrics"]["incorrectSelections"] = 7
json.dump(corpus, open(sys.argv[2], "w", encoding="utf-8"))
PY
set +e
context evaluate --corpus "$drifted" >"$tmp/drifted-report.json" 2>"$tmp/drifted.err"
drift_rc=$?
set -e
[[ "$drift_rc" -eq 4 ]] || { echo "expected exit 4 on deviation, got $drift_rc" >&2; exit 1; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert d["status"]=="deviated"; assert d["deviations"]' "$tmp/drifted-report.json"

# A malformed corpus is refused, not silently scored.
set +e
context evaluate --corpus "$ROOT/tests/fixtures/context-evaluation/campaign/expected.json" >/dev/null 2>"$tmp/malformed.err"
malformed_rc=$?
set -e
[[ "$malformed_rc" -eq 2 ]] || { echo "expected exit 2 on malformed corpus, got $malformed_rc" >&2; exit 1; }
grep -q 'context evaluation:' "$tmp/malformed.err"

# ---------------------------------------------------------------------------
# Campaign analysis of retained events and provider sidecars.
# ---------------------------------------------------------------------------
campaign="$corpus/campaign"
context campaign-report --events "$campaign/events.ndjson" --runs "$campaign/runs" \
  --interventions "$campaign/operator-interventions.jsonl" >"$tmp/campaign.json"

python3 - "$tmp/campaign.json" "$campaign/expected.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
expected = json.load(open(sys.argv[2], encoding="utf-8"))
assert report["schema"] == "singular.context.campaign-analysis.v1"
assert report["tasks"]["integrated"] == expected["tasks"]["integrated"]
assert report["tasks"]["unfinished"] == expected["tasks"]["unfinished"]
assert report["retries"] == expected["retries"]
assert report["controlPlane"] == expected["controlPlane"]
assert report["reviews"]["bytesPerAcceptedReview"] == expected["reviews"]["bytesPerAcceptedReview"]
assert report["interventions"] == expected["interventions"]
usage = report["providerUsageByRole"]
for role, values in expected["providerUsageByRole"].items():
    for key, value in values.items():
        assert usage[role][key] == value, (role, key, usage[role][key], value)
# Absent counters stay unknown, never zero.
assert usage["planner"]["observedOutputTokens"] is None
assert sorted({u["kind"] for u in report["unknowns"]}) == sorted(expected["unknownKinds"])
for entry in report["inputs"].values():
    assert "path" in entry and "present" in entry
PY

# An absent optional input is reported as unknown; an absent event stream is a
# refusal, because there is then nothing measured to report.
context campaign-report --events "$campaign/events.ndjson" --runs "$campaign/runs" \
  --interventions "$campaign/missing.jsonl" >"$tmp/campaign-partial.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert d["interventions"]["records"] is None; assert d["inputs"]["interventions"]["present"] is False; assert any(u["kind"]=="absent-input" for u in d["unknowns"])' "$tmp/campaign-partial.json"

set +e
context campaign-report --events "$campaign/absent-events.ndjson" --runs "$campaign/runs" >/dev/null 2>"$tmp/campaign.err"
campaign_rc=$?
set -e
[[ "$campaign_rc" -eq 2 ]] || { echo "expected exit 2 on absent events, got $campaign_rc" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The evaluation surface is discoverable and the B5 documents exist.
# ---------------------------------------------------------------------------
SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/cli/singular" help \
  | grep -q 'context build|search|get|explain|evaluate|campaign-report'
grep -q 'singular context evaluate' "$ROOT/README.md"
grep -q 'singular context campaign-report' "$ROOT/README.md"

for doc in docs/brain-build-plan/context-findings.md docs/brain-build-plan/context-adoption.md; do
  [[ -s "$ROOT/$doc" ]] || { echo "missing B5 document: $doc" >&2; exit 1; }
done

# Findings must cite the real retained inputs and keep the unproven-reliability
# and pending-obligation statements explicit.
python3 - "$ROOT/docs/brain-build-plan/context-findings.md" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
required = [
    ".singular-state/rescue-20260910/checkpoint.json",
    ".singular-state/rescue-20260910/native-observations-before-A6.json",
    ".singular-state/rescue-20260910/autonomous-recovery-20260912/operator-interventions.jsonl",
    ".singular-state/events.ndjson",
    "unknown",
    "TASK-1110",
    "TASK-1114",
    "TASK-1015",
]
missing = [item for item in required if item not in text]
assert not missing, f"findings report omits required references: {missing}"
PY

python3 - "$ROOT/docs/brain-build-plan/context-adoption.md" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read().lower()
required = ["install", "opt-in", "rollback", "immutable runtime", "memory", "project-local"]
missing = [item for item in required if item not in text]
assert not missing, f"adoption document omits required sections: {missing}"
PY

echo "test-context-evaluation-e2e: all assertions passed"
