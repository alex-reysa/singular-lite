#!/usr/bin/env python3
"""Contract tests for the B5 evaluation harness and campaign analyser.

Two independent surfaces are exercised here:

*   the deterministic labeled retrieval corpus in
    ``tests/fixtures/context-evaluation/corpus.json``, evaluated against the
    real B2 context service and compared with the corpus' own known metrics,
    and
*   the campaign analyser, run over a deterministic events/sidecar fixture
    whose absent counters must be reported as ``unknown`` rather than zero.

Neither surface needs a paid provider.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from engine.context_evaluation import (
    EvaluationError,
    analyze_campaign,
    evaluate_corpus,
    load_corpus,
)


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "context-evaluation"
CAMPAIGN = FIXTURE / "campaign"


def _generate_manifest(project: Path) -> None:
    producer = ROOT / "vendor" / "singular-brain" / "engine" / "cli.mjs"
    subprocess.run(
        ["node", str(producer), "--config",
         str(project / "brain" / "singular-brain.config.json"), "gen"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


class LabeledCorpusTest(unittest.TestCase):
    """The corpus is evaluated against a freshly produced real manifest."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="singular-context-eval.")
        self.corpus_root = Path(self.temp.name) / "corpus"
        shutil.copytree(FIXTURE, self.corpus_root)
        _generate_manifest(self.corpus_root / "project")
        self.corpus_path = self.corpus_root / "corpus.json"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_corpus_declares_every_required_label(self) -> None:
        corpus = load_corpus(self.corpus_path)
        labels = {case["label"] for case in corpus["cases"]}
        self.assertEqual(set(corpus["requiredLabels"]) - labels, set())

    def test_evaluation_matches_the_known_fixture_metrics(self) -> None:
        report = evaluate_corpus(self.corpus_path)
        self.assertEqual(report["schema"], "singular.context.evaluation-report.v1")
        self.assertEqual(report["deviations"], [])
        self.assertTrue(report["matchesExpected"])
        self.assertEqual(report["status"], "ok")
        metrics = report["metrics"]
        expected = report["expectedMetrics"]
        self.assertEqual(metrics["cases"], expected["cases"])
        self.assertEqual(metrics["inclusion"]["expected"], expected["inclusion"]["expected"])
        self.assertEqual(metrics["inclusion"]["included"], expected["inclusion"]["included"])
        self.assertEqual(metrics["inclusion"]["recall"], 1.0)
        self.assertEqual(metrics["incorrectSelections"], 0)
        self.assertEqual(metrics["budgetOmissions"], expected["budgetOmissions"])
        self.assertEqual(metrics["abstentions"], expected["abstentions"])
        self.assertEqual(metrics["refusals"], expected["refusals"])
        self.assertEqual(metrics["failures"], 0)
        self.assertEqual(metrics["missingLabels"], [])

    def test_every_case_is_reported_with_its_label_and_outcome(self) -> None:
        report = evaluate_corpus(self.corpus_path)
        by_id = {case["id"]: case for case in report["cases"]}
        self.assertEqual(len(by_id), 18)
        self.assertEqual(by_id["exact-reference-fact"]["observedOutcome"], "results")
        self.assertEqual(by_id["missing-knowledge-abstains"]["observedOutcome"], "abstention")
        self.assertEqual(by_id["wrong-version-read-refused"]["observedOutcome"], "refusal")
        self.assertIn("wrong-version", by_id["wrong-version-read-refused"]["reason"])
        self.assertEqual(by_id["aggregate-budget-omissions"]["budgetOmissions"], 2)
        self.assertEqual(
            by_id["wrong-role-run-record-withheld"]["observedOutcome"], "abstention"
        )
        self.assertEqual(
            by_id["permitted-role-run-record-retrieved"]["observedRefs"],
            ["run:runs/RUN-fixture/runner-result.json"],
        )
        self.assertTrue(all(case["status"] == "pass" for case in report["cases"]))

    def test_contradictory_and_revoked_sources_are_never_selected(self) -> None:
        report = evaluate_corpus(self.corpus_path)
        selected = {ref for case in report["cases"] for ref in case["observedRefs"]}
        self.assertNotIn("brain:eval-brain:knowledge:notes/legacy-migration-policy.md", selected)
        self.assertNotIn("brain:eval-brain:knowledge:notes/revoked-access.md", selected)

    def test_a_regressed_expectation_is_reported_not_silently_passed(self) -> None:
        corpus = json.loads(self.corpus_path.read_text(encoding="utf-8"))
        corpus["expectedMetrics"]["abstentions"] = 99
        self.corpus_path.write_text(json.dumps(corpus), encoding="utf-8")
        report = evaluate_corpus(self.corpus_path)
        self.assertFalse(report["matchesExpected"])
        self.assertEqual(report["status"], "deviated")
        self.assertTrue(any("abstentions" in item for item in report["deviations"]))

    def test_a_changed_source_breaks_the_pinned_version_case(self) -> None:
        note = self.corpus_root / "project" / "brain" / "notes" / "long-runbook.md"
        note.write_text(note.read_text(encoding="utf-8") + "\ntampered\n", encoding="utf-8")
        report = evaluate_corpus(self.corpus_path)
        failing = [case for case in report["cases"] if case["status"] == "fail"]
        self.assertTrue(failing)
        self.assertFalse(report["matchesExpected"])

    def test_a_malformed_corpus_is_refused(self) -> None:
        self.corpus_path.write_text(json.dumps({"schema": "wrong"}), encoding="utf-8")
        with self.assertRaises(EvaluationError):
            load_corpus(self.corpus_path)


class CampaignAnalysisTest(unittest.TestCase):
    """Real campaign shapes, with absent counters preserved as unknown."""

    def setUp(self) -> None:
        self.expected = json.loads((CAMPAIGN / "expected.json").read_text(encoding="utf-8"))
        self.report = analyze_campaign(
            events=CAMPAIGN / "events.ndjson",
            runs=CAMPAIGN / "runs",
            interventions=CAMPAIGN / "operator-interventions.jsonl",
        )

    def test_inputs_are_identified_by_path_and_hash(self) -> None:
        self.assertEqual(self.report["schema"], "singular.context.campaign-analysis.v1")
        inputs = self.report["inputs"]
        self.assertEqual(inputs["events"]["path"], str(CAMPAIGN / "events.ndjson"))
        self.assertTrue(inputs["events"]["sha256"].startswith("sha256:"))
        self.assertTrue(inputs["events"]["present"])
        self.assertEqual(inputs["runs"]["path"], str(CAMPAIGN / "runs"))

    def test_integrated_and_unfinished_tasks(self) -> None:
        tasks = self.report["tasks"]
        self.assertEqual(tasks["dispatched"], self.expected["tasks"]["dispatched"])
        self.assertEqual(tasks["integrated"], self.expected["tasks"]["integrated"])
        self.assertEqual(tasks["accepted"], self.expected["tasks"]["accepted"])
        self.assertEqual(tasks["unfinished"], self.expected["tasks"]["unfinished"])

    def test_retries_include_failed_and_setup_work(self) -> None:
        self.assertEqual(self.report["retries"], self.expected["retries"])

    def test_ready_to_dispatch_wait_and_gate_durations(self) -> None:
        wait = self.report["readyToDispatchWaitSeconds"]
        for key, value in self.expected["readyToDispatchWaitSeconds"].items():
            self.assertEqual(wait[key], value, key)
        self.assertIn("definition", wait)
        gates = self.report["gateDurations"]
        self.assertEqual(
            gates["byWorkspaceKind"], self.expected["gateDurations"]["byWorkspaceKind"]
        )
        self.assertEqual(
            gates["workerCompletedToGateCompletedSeconds"]["totalSeconds"],
            self.expected["gateDurations"]["workerCompletedToGateCompletedSeconds"]["totalSeconds"],
        )

    def test_control_plane_work(self) -> None:
        self.assertEqual(self.report["controlPlane"], self.expected["controlPlane"])

    def test_bytes_per_accepted_review(self) -> None:
        reviews = self.report["reviews"]
        self.assertEqual(reviews["acceptedReviews"], self.expected["reviews"]["acceptedReviews"])
        self.assertEqual(reviews["verdicts"], self.expected["reviews"]["verdicts"])
        self.assertEqual(
            reviews["reviewContextPromptBytes"],
            self.expected["reviews"]["reviewContextPromptBytes"],
        )
        self.assertEqual(
            reviews["bytesPerAcceptedReview"],
            self.expected["reviews"]["bytesPerAcceptedReview"],
        )

    def test_provider_tokens_by_role_with_missing_counters_unknown(self) -> None:
        usage = self.report["providerUsageByRole"]
        for role, values in self.expected["providerUsageByRole"].items():
            for key, value in values.items():
                self.assertEqual(usage[role][key], value, f"{role}.{key}")
        self.assertIsNone(usage["planner"]["observedInputTokens"])
        self.assertEqual(usage["planner"]["referencedSidecarsMissing"], 1)

    def test_interventions_are_counted_separately_from_native_delivery(self) -> None:
        self.assertEqual(self.report["interventions"], self.expected["interventions"])

    def test_unknowns_are_explicit(self) -> None:
        kinds = sorted({item["kind"] for item in self.report["unknowns"]})
        self.assertEqual(kinds, sorted(self.expected["unknownKinds"]))
        refs = [item.get("ref") for item in self.report["unknowns"]]
        self.assertIn("runs/RUN-EVAL-B/planner-attempt-1-try-0-runner-result.json", refs)
        self.assertIn(
            "runs/RUN-EVAL-B/implementer-attempt-1-try-0-runner-result.json", refs
        )

    def test_absent_optional_input_is_unknown_not_an_error(self) -> None:
        report = analyze_campaign(
            events=CAMPAIGN / "events.ndjson",
            runs=CAMPAIGN / "runs",
            interventions=CAMPAIGN / "does-not-exist.jsonl",
        )
        self.assertFalse(report["inputs"]["interventions"]["present"])
        self.assertIsNone(report["interventions"]["records"])
        self.assertTrue(
            any(item["kind"] == "absent-input" for item in report["unknowns"])
        )

    def test_a_missing_events_stream_is_refused(self) -> None:
        with self.assertRaises(EvaluationError):
            analyze_campaign(events=CAMPAIGN / "nope.ndjson", runs=CAMPAIGN / "runs")

    def test_unparseable_event_lines_are_reported_not_dropped_silently(self) -> None:
        with tempfile.TemporaryDirectory(prefix="singular-campaign-eval.") as temp:
            stream = Path(temp) / "events.ndjson"
            stream.write_text(
                (CAMPAIGN / "events.ndjson").read_text(encoding="utf-8") + "{not json\n",
                encoding="utf-8",
            )
            report = analyze_campaign(events=stream, runs=CAMPAIGN / "runs")
            self.assertEqual(report["inputs"]["events"]["unparseableLines"], 1)
            self.assertTrue(
                any(item["kind"] == "unparseable-event-line" for item in report["unknowns"])
            )

    def test_nested_work_is_included_and_archived_copies_are_not_doubled(self) -> None:
        # The engine retains byte-identical copies of each attempt under
        # attempts/<n>/, and stages planner/critic invocations one level deeper
        # than the run directory. A single-level scan drops the latter; an
        # undeduplicated recursive scan double-counts the former.
        runs = self.report["inputs"]["runs"]
        for key, value in self.expected["runs"].items():
            self.assertEqual(runs[key], value, key)
        usage = self.report["providerUsageByRole"]
        self.assertEqual(usage["implementer"]["sidecars"], 3)
        self.assertEqual(usage["implementer"]["sidecarsWithoutUsage"], 1)
        self.assertEqual(usage["plan-critic"]["sidecars"], 1)
        self.assertEqual(
            sum(1 for item in self.report["unknowns"]
                if item["kind"] == "runner-result-without-usage"),
            1,
        )

    def test_provider_counters_are_broken_down_by_provider(self) -> None:
        usage = self.report["providerUsageByRole"]
        self.assertEqual(usage["implementer"]["providers"], ["fixture"])
        self.assertEqual(
            usage["implementer"]["byProvider"]["fixture"]["observedInputTokens"], 1000000
        )
        self.assertEqual(usage["planner"]["providers"], [])

    def test_report_is_deterministic(self) -> None:
        again = analyze_campaign(
            events=CAMPAIGN / "events.ndjson",
            runs=CAMPAIGN / "runs",
            interventions=CAMPAIGN / "operator-interventions.jsonl",
        )
        self.assertEqual(
            json.dumps(self.report, sort_keys=True), json.dumps(again, sort_keys=True)
        )


class CampaignMeasurementIntegrityTest(unittest.TestCase):
    """Counters whose meaning or coverage is not established stay unknown."""

    def _analyze(self, events: list[dict], sidecars: dict[str, dict]) -> dict:
        temp = tempfile.TemporaryDirectory(prefix="singular-campaign-integrity.")
        self.addCleanup(temp.cleanup)
        base = Path(temp.name)
        stream = base / "events.ndjson"
        stream.write_text(
            "".join(json.dumps(event, sort_keys=True) + "\n" for event in events),
            encoding="utf-8",
        )
        runs = base / "runs"
        for relative, payload in sidecars.items():
            target = runs / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
        runs.mkdir(parents=True, exist_ok=True)
        return analyze_campaign(events=stream, runs=runs)

    def test_mixed_provider_token_semantics_are_flagged_not_summed_blindly(self) -> None:
        # Retained evidence shows two incompatible conventions: one provider
        # reports cached input as a subset of input, another reports it as a
        # separate cache-read counter. A role that spans both cannot be summed
        # into one comparable total.
        report = self._analyze(
            [],
            {
                "RUN-X/implementer-attempt-1-try-0-runner-result.json": {
                    "schema": "singular.orchestration.runner-result.v0",
                    "provider": "alpha", "role": "implementer", "outcome": "succeeded",
                    "usage": {"inputTokens": 20000, "cachedInputTokens": 12000, "outputTokens": 200},
                },
                "RUN-Y/implementer-attempt-1-try-0-runner-result.json": {
                    "schema": "singular.orchestration.runner-result.v0",
                    "provider": "beta", "role": "implementer", "outcome": "succeeded",
                    "usage": {"inputTokens": 76, "cachedInputTokens": 3231199, "outputTokens": 26308},
                },
            },
        )
        implementer = report["providerUsageByRole"]["implementer"]
        self.assertEqual(implementer["providers"], ["alpha", "beta"])
        self.assertEqual(
            implementer["byProvider"]["beta"]["observedCachedInputTokens"], 3231199
        )
        self.assertEqual(
            implementer["byProvider"]["alpha"]["observedInputTokens"], 20000
        )
        flagged = [
            item for item in report["unknowns"]
            if item["kind"] == "mixed-provider-token-semantics"
        ]
        self.assertTrue(flagged)
        self.assertIn("implementer", flagged[0]["ref"])

    def test_review_context_coverage_shortfall_is_unknown(self) -> None:
        events = [
            {"ts": "2026-09-10T10:00:00Z", "type": "l1.audit_completed",
             "data": {"runId": "RUN-X", "taskId": "TASK-X", "verdict": "accepted"}},
            {"ts": "2026-09-10T11:00:00Z", "type": "l1.audit_completed",
             "data": {"runId": "RUN-Y", "taskId": "TASK-Y", "verdict": "accepted"}},
            {"ts": "2026-09-10T10:30:00Z", "type": "context.bundle_selected",
             "data": {"runId": "RUN-X", "role": "review-target", "promptBytes": 5000}},
        ]
        report = self._analyze(events, {})
        reviews = report["reviews"]
        self.assertEqual(reviews["acceptedReviews"], 2)
        self.assertEqual(reviews["reviewContextBundles"], 1)
        self.assertFalse(reviews["reviewContextCoverageComplete"])
        self.assertTrue(
            any(item["kind"] == "review-context-coverage" for item in report["unknowns"])
        )


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
