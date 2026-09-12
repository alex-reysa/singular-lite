#!/usr/bin/env python3
"""Unit tests for the read-only session-terminal log parsing in singular_graph_server.

These cover the *pure* parsing layer — classify_codex_record, parse_log_lines,
and the byte-cursor read_log_window — with no orchestration repo required. Run:

    python3 -m unittest scripts.test_singular_graph_server
    python3 scripts/test_singular_graph_server.py
"""

from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import http.client
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock
from pathlib import Path

import singular_graph_server as srv

# Every module global apply_console_adapter may mutate — tests that apply an
# adapter snapshot these first and restore them afterwards so the rest of the
# suite keeps seeing the pristine built-ins.
ADAPTER_GLOBALS = [
    "CONSOLE_ADAPTER", "ROLE_CATALOG", "ROLE_PROMPT_MAP", "EVENT_MAP", "NOISE_EVENT_TYPES",
    "TASK_ID_RE", "NODE_ID_RE", "AREA_ID_RE",
    "_PLANNER_AREA_RE", "_PLANNER_NODE_RE", "_PLANNER_STAGE_RE", "_PLANNER_LAYER_RE",
    "SETTINGS_SPEC", "DAG_REL", "STAGE_DOC_REL", "GATES_REL", "TASKS_DIR_REL", "AREAS_DIR_REL",
    "STATE_DIR_REL", "EVENTS_LOG_REL", "AUTONOMATE_LOG_REL", "STATUS_REL", "CIRCUIT_REL",
    "STOP_REL", "ORCH_SCRIPTS_REL", "PLATFORM_VISION_REL", "CONSOLE_COMMANDS",
    "PROCESS_MATCHERS", "CODEX_LOG_NAMES", "PLAIN_LOG_NAMES", "SETTINGS_SOURCE",
]

# The engine event types that must arrive via the adapter ONLY (the built-in
# EVENT_MAP must not gain them).
NEW_ENGINE_EVENT_TYPES = [
    "context.strategy_selected", "context.resume_failed", "findings.ledger_updated",
    "l1.attempt_archived", "audit.infra_retry", "worker.infra_retry",
    "decider.fast_path", "l1.preflight_failed",
]


def apply_adapter_with_restore(testcase: unittest.TestCase, adapter: dict) -> None:
    saved = {name: getattr(srv, name) for name in ADAPTER_GLOBALS}

    def restore() -> None:
        for name, val in saved.items():
            setattr(srv, name, val)

    testcase.addCleanup(restore)
    srv.apply_console_adapter(adapter)


class ClassifyCodexRecordTests(unittest.TestCase):
    def test_agent_message_completed(self) -> None:
        rec = srv.classify_codex_record(
            {"type": "item.completed", "item": {"id": "item_0", "type": "agent_message", "text": "  hello  "}}
        )
        self.assertEqual(rec, {"kind": "message", "role": "agent", "id": "item_0",
                               "text": "hello", "truncated": False})

    def test_agent_message_started_is_dropped(self) -> None:
        # item.started agent_message carries no text yet — should be dropped.
        self.assertIsNone(srv.classify_codex_record(
            {"type": "item.started", "item": {"id": "item_0", "type": "agent_message"}}))

    def test_agent_message_truncation(self) -> None:
        big = "x" * (srv.AGENT_MSG_CAP + 50)
        rec = srv.classify_codex_record(
            {"type": "item.completed", "item": {"type": "agent_message", "text": big}})
        self.assertTrue(rec["truncated"])
        self.assertEqual(len(rec["text"]), srv.AGENT_MSG_CAP)

    def test_command_execution_completed(self) -> None:
        rec = srv.classify_codex_record({
            "type": "item.completed",
            "item": {"id": "item_1", "type": "command_execution",
                     "command": "go test ./...", "aggregated_output": "ok\n",
                     "exit_code": 0, "status": "completed"},
        })
        self.assertEqual(rec["kind"], "command")
        self.assertEqual(rec["command"], "go test ./...")
        self.assertEqual(rec["exitCode"], 0)
        self.assertEqual(rec["status"], "completed")
        self.assertEqual(rec["output"], "ok\n")

    def test_command_execution_started_in_progress(self) -> None:
        rec = srv.classify_codex_record({
            "type": "item.started",
            "item": {"id": "item_1", "type": "command_execution",
                     "command": "sleep 1", "aggregated_output": "", "exit_code": None,
                     "status": "in_progress"},
        })
        self.assertEqual(rec["status"], "in_progress")
        self.assertIsNone(rec["exitCode"])

    def test_command_output_tail_capped(self) -> None:
        out = "L" * (srv.CMD_OUTPUT_CAP + 200)
        rec = srv.classify_codex_record({
            "type": "item.completed",
            "item": {"type": "command_execution", "command": "x", "aggregated_output": out, "exit_code": 0},
        })
        self.assertTrue(rec["outputTruncated"])
        self.assertEqual(len(rec["output"]), srv.CMD_OUTPUT_CAP)

    def test_file_change(self) -> None:
        rec = srv.classify_codex_record({
            "type": "item.completed",
            "item": {"id": "item_25", "type": "file_change", "status": "completed",
                     "changes": [{"path": "/a/b/foo.go", "kind": "add"}]},
        })
        self.assertEqual(rec["kind"], "file")
        self.assertEqual(rec["changes"], [{"path": "/a/b/foo.go", "kind": "add"}])

    def test_turn_completed_usage(self) -> None:
        rec = srv.classify_codex_record({"type": "turn.completed", "usage": {"output_tokens": 24196}})
        self.assertEqual(rec["kind"], "meta")
        self.assertIn("24196", rec["text"])

    def test_thread_and_turn_started(self) -> None:
        self.assertEqual(srv.classify_codex_record({"type": "thread.started"})["text"], "thread started")
        self.assertEqual(srv.classify_codex_record({"type": "turn.started"})["text"], "turn started")

    def test_orchestration_event_line(self) -> None:
        rec = srv.classify_codex_record(
            {"ts": "2026-06-04T15:00:35Z", "type": "l1.dispatch_started",
             "message": "l1 dispatch started", "data": {"taskId": "TASK-0477"}})
        self.assertEqual(rec["kind"], "event")
        self.assertEqual(rec["eventType"], "l1.dispatch_started")
        self.assertEqual(rec["ts"], "2026-06-04T15:00:35Z")
        self.assertEqual(rec["text"], "l1 dispatch started")


class ParseLogLinesTests(unittest.TestCase):
    def test_mixed_worker_log(self) -> None:
        lines = [
            '{"type":"thread.started","thread_id":"abc"}',
            '{"type":"turn.started"}',
            '2026-06-04T14:25:45.962429Z  WARN codex_core::exec: transient retry on tool call',
            '{"type":"item.completed","item":{"type":"agent_message","text":"Doing TDD."}}',
            '{"type":"item.completed","item":{"id":"item_1","type":"command_execution",'
            '"command":"go test","aggregated_output":"ok","exit_code":0,"status":"completed"}}',
            '',  # blank lines dropped
        ]
        recs = srv.parse_log_lines(lines)
        kinds = [r["kind"] for r in recs]
        self.assertEqual(kinds, ["meta", "meta", "log", "message", "command"])
        warn = recs[2]
        self.assertEqual(warn["level"], "WARN")
        self.assertEqual(warn["ts"], "2026-06-04T14:25:45.962429Z")
        self.assertTrue(warn["text"].startswith("codex_core::exec"))

    def test_planner_batch_agent_message(self) -> None:
        payload = json.dumps({"schema": "singular.orchestration.task-batch.v0", "tasks": [{"taskId": "TASK-0475"}]})
        line = json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": payload}})
        recs = srv.parse_log_lines([line])
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["kind"], "message")
        self.assertIn("task-batch.v0", recs[0]["text"])

    def test_raw_mode_returns_verbatim(self) -> None:
        lines = ['{"type":"turn.started"}', "plain text line"]
        recs = srv.parse_log_lines(lines, raw=True)
        self.assertTrue(all(r["kind"] == "log" for r in recs))
        self.assertEqual(recs[0]["text"], '{"type":"turn.started"}')

    def test_malformed_json_falls_back_to_log(self) -> None:
        recs = srv.parse_log_lines(['{"type": broken'])
        self.assertEqual(recs[0]["kind"], "log")
        self.assertEqual(recs[0]["text"], '{"type": broken')

    def test_plain_line_without_iso_prefix(self) -> None:
        recs = srv.parse_log_lines(["last_message=/path/to/file"])
        self.assertEqual(recs[0]["kind"], "log")
        self.assertEqual(recs[0]["text"], "last_message=/path/to/file")
        self.assertEqual(recs[0]["diagnostic"]["category"], "info")

    def test_codex_loader_noise_dropped_in_parsed_kept_in_raw(self) -> None:
        noise = "2026-06-04T14:25:53Z  WARN codex_core_skills::loader: ignoring interface.icon_small: x"
        manifest = "2026-06-04T14:25:45Z  WARN codex_core_plugins::manifest: ignoring interface.defaultPrompt[0]"
        signal = '{"type":"item.completed","item":{"type":"agent_message","text":"real work"}}'
        parsed = srv.parse_log_lines([noise, manifest, signal])
        self.assertEqual([r["kind"] for r in parsed], ["message"])  # both WARNs dropped
        raw = srv.parse_log_lines([noise, manifest, signal], raw=True)
        self.assertEqual(len(raw), 3)  # raw keeps every line verbatim
        self.assertTrue(all(r["kind"] == "log" for r in raw))


class ReadLogWindowTests(unittest.TestCase):
    def _write(self, text: str) -> Path:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        tmp.write(text)
        tmp.flush()
        tmp.close()
        path = Path(tmp.name)
        self.addCleanup(path.unlink)
        return path

    def test_initial_tail_then_forward_advances(self) -> None:
        path = self._write("line1\nline2\nline3\n")
        first = srv.read_log_window(path, None)
        self.assertEqual(first["rawLines"], ["line1", "line2", "line3"])
        self.assertEqual(first["cursor"], first["size"])
        self.assertFalse(first["reset"])
        # No new bytes -> empty, cursor stable (idempotent follow poll).
        again = srv.read_log_window(path, first["cursor"])
        self.assertEqual(again["rawLines"], [])
        self.assertEqual(again["cursor"], first["cursor"])

    def test_forward_read_picks_up_appended_lines(self) -> None:
        path = self._write("a\nb\n")
        first = srv.read_log_window(path, None)
        with path.open("a") as fh:
            fh.write("c\nd\n")
        nxt = srv.read_log_window(path, first["cursor"])
        self.assertEqual(nxt["rawLines"], ["c", "d"])
        self.assertEqual(nxt["cursor"], nxt["size"])

    def test_trailing_partial_line_not_consumed(self) -> None:
        path = self._write("complete\npartial-no-newline")
        win = srv.read_log_window(path, None)
        # Only the newline-terminated line is consumed; the cursor stops before
        # the partial tail so the next poll re-reads it once it completes.
        self.assertEqual(win["rawLines"], ["complete"])
        self.assertLess(win["cursor"], win["size"])
        # Complete the partial line, then the next forward read yields it.
        with path.open("a") as fh:
            fh.write("-done\n")
        nxt = srv.read_log_window(path, win["cursor"])
        self.assertEqual(nxt["rawLines"], ["partial-no-newline-done"])

    def test_stale_cursor_resets_to_tail(self) -> None:
        path = self._write("x\ny\nz\n")
        win = srv.read_log_window(path, 10_000_000)
        self.assertTrue(win["reset"])
        self.assertEqual(win["rawLines"], ["x", "y", "z"])

    def test_oversized_single_line_is_skipped(self) -> None:
        # A single line longer than the window must not stall the cursor forever.
        path = self._write("Z" * 5000)
        win = srv.read_log_window(path, 0, max_bytes=1024)
        self.assertEqual(win["cursor"], 1024)
        self.assertTrue(win["rawLines"][0].startswith("[line too long"))

    def test_missing_file(self) -> None:
        win = srv.read_log_window(Path("/no/such/file.log"), None)
        self.assertEqual(win["rawLines"], [])
        self.assertEqual(win["size"], 0)

    def test_unicode_line_separators_do_not_oversplit(self) -> None:
        # A JSON record whose text contains a literal U+2028 / NEL must stay ONE
        # physical line — only \n terminates a record (str.splitlines would split here).
        payload = '{"type":"item.completed","item":{"type":"agent_message","text":"a bc"}}'
        path = self._write(payload + "\n")
        win = srv.read_log_window(path, None)
        self.assertEqual(len(win["rawLines"]), 1)
        recs = srv.parse_log_lines(win["rawLines"])
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["kind"], "message")
        self.assertIn(" ", recs[0]["text"])


class PlannerPromptTests(unittest.TestCase):
    def test_parses_area_node_stage_layer(self) -> None:
        text = (
            "# L1 Area Planner Prompt\n\n"
            "You are the singular Area Planner for area `workflow`. You keep going.\n\n"
            "Executable DAG node: `D2.service`\nStage: `D2`\nLayer: `service`\n"
        )
        info = srv._parse_planner_prompt(text)
        self.assertEqual(info, {"area": "workflow", "node": "D2.service", "stage": "D2", "layer": "service"})

    def test_missing_fields_are_none(self) -> None:
        self.assertEqual(srv._parse_planner_prompt("nothing here"),
                         {"area": None, "node": None, "stage": None, "layer": None})


class WorkerStateTests(unittest.TestCase):
    def test_terminal_lease_statuses_win(self) -> None:
        self.assertEqual(srv._worker_state("blocked", None, True, True), "blocked")
        self.assertEqual(srv._worker_state("failed", None, True, True), "failed")
        self.assertEqual(srv._worker_state("accepted", None, True, True), "awaiting")
        self.assertEqual(srv._worker_state("integrated", None, True, True), "integrated")

    def test_running_lease_active_while_worktree_backs_it(self) -> None:
        # A running worker stays active through a long quiet model turn (stale log)
        # as long as its worktree is present; only a vanished worktree reads stale.
        self.assertEqual(srv._worker_state("running", None, False, True), "active")
        self.assertEqual(srv._worker_state("running", None, True, False), "active")
        self.assertEqual(srv._worker_state("running", None, False, False), "stale")

    def test_no_lease_uses_packet_and_freshness(self) -> None:
        self.assertEqual(srv._worker_state(None, "needs-review", False, False), "awaiting")
        self.assertEqual(srv._worker_state(None, None, True, False), "active")
        self.assertEqual(srv._worker_state(None, None, False, False), "stale")


# --------------------------------------------------------------------------- #
# Provenance pure-parser tests                                                  #
# --------------------------------------------------------------------------- #

def _ev(etype, ts, **data):
    return {"type": etype, "ts": ts, "message": etype, "data": data}


class ProjectEventTests(unittest.TestCase):
    def test_worker_failure_toned_red_with_reason(self) -> None:
        row = srv.project_event(_ev("l1.worker_completed", "2026-06-05T10:00:00Z",
                                    runId="RUN-1", exitCode=1, failure="no state packet"))
        self.assertEqual(row["tone"], "red")
        self.assertFalse(row["advancing"])
        self.assertIn("exited 1", row["label"])
        self.assertEqual(row["reason"], "no state packet")

    def test_worker_success_is_advancing_forest(self) -> None:
        row = srv.project_event(_ev("l1.worker_completed", "t", runId="RUN-1", exitCode=0))
        self.assertEqual(row["tone"], "forest")
        self.assertTrue(row["advancing"])
        self.assertIsNone(row["reason"])

    def test_integration_label_carries_merge_commit(self) -> None:
        row = srv.project_event(_ev("integration.integrated", "t", taskId="TASK-1",
                                    mergeCommit="db81fc7edb285", branch="agent/x"))
        self.assertEqual(row["tone"], "violet")
        self.assertIn("db81fc7", row["label"])

    def test_audit_non_accepted_is_amber(self) -> None:
        row = srv.project_event(_ev("l1.audit_completed", "t", verdict="needs-fix"))
        self.assertEqual(row["tone"], "amber")
        self.assertFalse(row["advancing"])

    def test_node_suffix_appended(self) -> None:
        row = srv.project_event(_ev("planner.staged", "t", node="D6.storage_spec", taskId="TASK-9"))
        self.assertTrue(row["label"].endswith("D6.storage_spec"))
        self.assertEqual(row["nodeId"], "D6.storage_spec")

    def test_unknown_type_falls_back_to_message(self) -> None:
        row = srv.project_event({"type": "weird.thing", "ts": "t", "message": "hi", "data": {}})
        self.assertEqual(row["tone"], "gray")
        self.assertEqual(row["label"], "hi")


class BuildEventsIndexTests(unittest.TestCase):
    def _lines(self):
        return [
            json.dumps(_ev("planner.generated", "t1", taskId="TASK-1", node="D1.contract", runId="O-1")),
            json.dumps(_ev("integration.skipped", "t2", taskId="TASK-1")),   # noise
            json.dumps(_ev("l1.dispatch_started", "t3", taskId="TASK-1", branch="agent/a", runId="R-1")),
            json.dumps(_ev("integration.integrated", "t4", branch="agent/a", mergeCommit="abc1234")),
            "not json",
        ]

    def test_buckets_and_noise_dropped(self) -> None:
        idx = srv.build_events_index(self._lines())
        self.assertIn("TASK-1", idx["by_task"])
        self.assertEqual(len(idx["by_task"]["TASK-1"]), 2)          # skipped dropped
        self.assertIn("agent/a", idx["by_branch"])
        self.assertIn("D1.contract", idx["by_node"])
        types = [r["type"] for r in idx["tail_rows"]]
        self.assertNotIn("integration.skipped", types)


class BuildOriginChainTests(unittest.TestCase):
    def test_orders_by_phase_when_ts_tie(self) -> None:
        # All same second; must still read in lifecycle order via phase rank.
        evs = [
            _ev("l1.committed", "2026-06-05T10:00:00Z", runId="R"),
            _ev("planner.generated", "2026-06-05T10:00:00Z", runId="O", node="D1.contract"),
            _ev("l1.dispatch_started", "2026-06-05T10:00:00Z", runId="R", branch="b"),
        ]
        chain = srv.build_origin_chain(evs)
        self.assertEqual([c["type"] for c in chain],
                         ["planner.generated", "l1.dispatch_started", "l1.committed"])

    def test_branch_integration_folded_in_and_deduped(self) -> None:
        task_evs = [_ev("l1.dispatch_started", "t1", taskId="T", branch="agent/a", runId="R")]
        branch_evs = [
            _ev("integration.integrated", "t9", branch="agent/a", mergeCommit="deadbeef"),
            _ev("integration.integrated", "t9", branch="agent/a", mergeCommit="deadbeef"),  # dup
        ]
        chain = srv.build_origin_chain(task_evs, branch_evs, "agent/a")
        integ = [c for c in chain if c["type"] == "integration.integrated"]
        self.assertEqual(len(integ), 1)
        self.assertEqual(integ[0]["extra"]["mergeCommit"], "deadbeef")


class ResolveProvenanceLinkTests(unittest.TestCase):
    def test_events_confidence(self) -> None:
        evs = [
            _ev("planner.generated", "t", node="D6.storage_spec", runId="O-1"),
            _ev("l1.dispatch_started", "t", runId="R-1", branch="agent/x", batchId="O-1-batch"),
        ]
        link = srv.resolve_task_provenance_link(evs, {"runId": "R-9"})
        self.assertEqual(link["linkConfidence"], "events")
        self.assertEqual(link["parentNode"], "D6.storage_spec")
        self.assertEqual(link["stage"], "D6")
        self.assertEqual(link["workerRunId"], "R-1")
        self.assertEqual(link["plannerRunId"], "O-1")

    def test_lease_confidence_when_no_node_event(self) -> None:
        link = srv.resolve_task_provenance_link([], {"runId": "R-1", "batchId": "B-1", "branch": "b"})
        self.assertEqual(link["linkConfidence"], "lease")
        self.assertIsNone(link["parentNode"])
        self.assertEqual(link["workerRunId"], "R-1")

    def test_none_confidence(self) -> None:
        link = srv.resolve_task_provenance_link([], None)
        self.assertEqual(link["linkConfidence"], "none")


class ParsePlannerBatchTests(unittest.TestCase):
    def test_title_match(self) -> None:
        batch = {"tasks": [
            {"taskId": "TASK-0001", "markdown": "# TASK-0001: Recovery plan storage\n..."},
            {"taskId": "TASK-0002", "markdown": "# TASK-0002: Replay result deviation storage specification\n..."},
        ]}
        m = srv.parse_planner_batch(batch, "Replay result deviation storage specification")
        self.assertEqual(m["localId"], "TASK-0002")
        self.assertEqual(m["candidateCount"], 2)

    def test_no_match_returns_count_only(self) -> None:
        batch = {"tasks": [{"taskId": "TASK-0001", "markdown": "# TASK-0001: Something else\n"}]}
        m = srv.parse_planner_batch(batch, "Totally different title")
        self.assertIsNone(m["localId"])
        self.assertEqual(m["candidateCount"], 1)


class ParseDagTests(unittest.TestCase):
    def setUp(self) -> None:
        self.reg = srv.parse_dag({"nodes": [
            {"id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract"},
            {"id": "S0.storage_substrate_base", "stage": "S0", "area": "storage", "layer": "base"},
        ]})

    def test_indexes(self) -> None:
        self.assertIn("D1.contract", self.reg["by_id"])
        self.assertEqual(len(self.reg["by_area"]["artifact"]), 1)
        self.assertEqual(len(self.reg["by_stage"]["S0"]), 1)

    def test_node_id_validity_and_traversal_rejection(self) -> None:
        self.assertTrue(srv.node_id_valid("D1.contract", self.reg))
        self.assertTrue(srv.node_id_valid("S0.storage_substrate_base", self.reg))
        self.assertFalse(srv.node_id_valid("../etc/passwd", self.reg))
        self.assertFalse(srv.node_id_valid("D1/contract", self.reg))
        self.assertFalse(srv.node_id_valid("D9.unknown", self.reg))  # well-formed but absent


class StageCardTests(unittest.TestCase):
    DOC = ("# Plan\n## 7. Stage Cards\n"
           "### D0: Shared Kernel Spine\nD0 body line\nmore D0\n"
           "### D1: Artifact Kernel\nD1 body line\n"
           "## 8. Next\n").splitlines()

    def test_finds_card_and_stops_at_next_heading(self) -> None:
        card = srv.find_stage_card(self.DOC, "D0")
        self.assertEqual(card["section"], "D0: Shared Kernel Spine")
        self.assertIn("D0 body line", card["text"])
        self.assertNotIn("D1 body", card["text"])

    def test_no_card_returns_none(self) -> None:
        self.assertIsNone(srv.find_stage_card(self.DOC, "S0"))

    def test_hash_stable_and_sensitive(self) -> None:
        h1 = srv.stage_section_hash("abc")
        self.assertEqual(h1, srv.stage_section_hash("abc"))
        self.assertNotEqual(h1, srv.stage_section_hash("abc "))
        self.assertTrue(h1.startswith("sha256:"))

    def test_build_source_refs_shape_and_s0_empty(self) -> None:
        node = {"stage": "D1", "description": "Artifact stuff.", "requiredCompletion": "contract_complete"}
        refs = srv.build_source_refs(node, self.DOC)
        self.assertEqual(len(refs), 1)
        self.assertEqual(refs[0]["document"], srv.STAGE_DOC_REL)
        self.assertIn("contract_complete", refs[0]["reason"])
        self.assertTrue(refs[0]["contentHash"].startswith("sha256:"))
        s0 = srv.build_source_refs({"stage": "S0", "description": "x"}, self.DOC)
        self.assertEqual(s0, [])


class SynthesizeGateBlockingTests(unittest.TestCase):
    def test_passed_has_empty_reason(self) -> None:
        out = srv.synthesize_gate_blocking({"status": "passed"}, set())
        self.assertEqual(out["reason"], "")

    def test_acknowledged_baseline_is_successful(self) -> None:
        status = "passed-with-acknowledged-baseline"
        out = srv.synthesize_gate_blocking(
            {"status": status, "upstreamGates": ["D0.contract"]},
            set(),
            {"D0.contract": status},
        )
        self.assertEqual(out["reason"], "")
        self.assertEqual(out["upstreamBlockers"], [])

    def test_blocked_lists_missing_and_upstream(self) -> None:
        gate = {"status": "blocked", "rationale": "closeout incomplete",
                "upstreamGates": ["D0.contract"],
                "evidence": [{"kind": "task-set", "taskIds": ["TASK-1", "TASK-2"]}]}
        out = srv.synthesize_gate_blocking(gate, {"TASK-1"}, {"D0.contract": "blocked"})
        self.assertIn("TASK-2", out["missingTaskIds"])
        self.assertIn("TASK-1", out["acceptedTaskIds"])
        self.assertIn("D0.contract", out["upstreamBlockers"])
        self.assertIn("blocked", out["reason"].lower())

    def test_absent_stale_invalid(self) -> None:
        self.assertIn("No promotion", srv.synthesize_gate_blocking({"status": "absent"}, set())["reason"])
        self.assertIn("stale", srv.synthesize_gate_blocking({"status": "stale"}, set())["reason"])
        self.assertIn("invalid", srv.synthesize_gate_blocking({"status": "invalid"}, set())["reason"])

    def test_none_gate(self) -> None:
        out = srv.synthesize_gate_blocking(None, set())
        self.assertIn("No gate result", out["reason"])


class DetectDuplicateTasksTests(unittest.TestCase):
    def test_identical_owned_files_flagged(self) -> None:
        leases = [
            {"taskId": "TASK-A", "area": "binding", "status": "integrated",
             "ownedFiles": ["x.go", "x_test.go"], "updatedAt": "2026-01-01"},
            {"taskId": "TASK-B", "area": "binding", "status": "superseded",
             "ownedFiles": ["x.go", "x_test.go"], "updatedAt": "2026-01-02"},
        ]
        dups = srv.detect_duplicate_tasks(leases)
        self.assertIn("TASK-B", dups)
        self.assertEqual(dups["TASK-B"]["duplicateOf"], "TASK-A")
        self.assertEqual(dups["TASK-B"]["confidence"], "high")
        self.assertNotIn("TASK-A", dups)

    def test_distinct_files_no_flag(self) -> None:
        leases = [
            {"taskId": "TASK-A", "area": "binding", "status": "integrated", "ownedFiles": ["a.go"]},
            {"taskId": "TASK-B", "area": "binding", "status": "integrated", "ownedFiles": ["b.go"]},
        ]
        self.assertEqual(srv.detect_duplicate_tasks(leases), {})


class EventsOverlayTests(unittest.TestCase):
    def test_bounded_read_types_filter_and_noise(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".singular-state").mkdir()
            (repo / "docs/orchestration").mkdir(parents=True)
            (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps(
                {"nodes": [{"id": "D1.contract", "stage": "D1", "area": "artifact"}]}))
            lines = [
                json.dumps(_ev("integration.skipped", "t0", taskId="T0")),       # dropped
                json.dumps(_ev("planner.generated", "t1", taskId="T1", node="D1.contract")),
                json.dumps(_ev("l1.committed", "t2", taskId="T1", headSha="abcdef0")),
            ]
            (repo / ".singular-state/events.ndjson").write_text("\n".join(lines) + "\n")
            # no filter: noise excluded, area resolved for node rows
            res = srv.collect_events_overlay(repo, None, 100, None)
            types = [r["type"] for r in res["rows"]]
            self.assertNotIn("integration.skipped", types)
            row = [r for r in res["rows"] if r["type"] == "planner.generated"][0]
            self.assertEqual(row["areaId"], "artifact")
            # types filter keeps only the requested type
            only = srv.collect_events_overlay(repo, None, 100, {"l1.committed"})
            self.assertEqual([r["type"] for r in only["rows"]], ["l1.committed"])
            self.assertEqual(res["cursor"], res["size"])


class PlanOverviewTests(unittest.TestCase):
    def test_parse_shell_default(self) -> None:
        text = 'SINGULAR_CODEX_MODEL="${SINGULAR_CODEX_MODEL:-gpt-5.5}"\n' \
               'SINGULAR_MAX_DISPATCH="${SINGULAR_MAX_DISPATCH:-$max_concurrent}"\n' \
               'SINGULAR_L2_SLICE_BUDGET="${SINGULAR_L2_SLICE_BUDGET:-1}"\n'
        self.assertEqual(srv.parse_shell_default(text, "SINGULAR_CODEX_MODEL"), "gpt-5.5")
        self.assertEqual(srv.parse_shell_default(text, "SINGULAR_MAX_DISPATCH"), "$max_concurrent")
        self.assertEqual(srv.parse_shell_default(text, "SINGULAR_L2_SLICE_BUDGET"), "1")
        self.assertIsNone(srv.parse_shell_default(text, "SINGULAR_NOT_PRESENT"))

    def test_compute_plan_progress(self) -> None:
        registry = srv.parse_dag({"nodes": [
            {"id": "D0.contract", "stage": "D0", "area": "kernel", "layer": "contract"},
            {"id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract"},
            {"id": "D1.service", "stage": "D1", "area": "artifact", "layer": "service"},
            {"id": "S0.base", "stage": "S0", "area": "storage", "layer": "base"},
        ]})
        gates = {
            "D0.contract": "passed-with-acknowledged-baseline",
            "D1.contract": "passed",
            "S0.base": "passed",
        }
        progress, stages, frontier = srv.compute_plan_progress(registry, gates)
        # Combined figures are unchanged; with no gate records the provenance is
        # unknown, so every passed gate reads as current-campaign work.
        self.assertEqual(progress, {
            "passedNodes": 3, "totalNodes": 4, "pct": 75,
            "cohorts": {"historical": {"passed": 0, "total": 0},
                        "current": {"passed": 3, "total": 4, "pct": 75}}})
        d1 = [s for s in stages if s["stage"] == "D1"][0]
        self.assertEqual((d1["passed"], d1["total"], d1["status"]), (1, 2, "active"))
        # D0/S0 complete; ordering puts D-stages before S-stages
        self.assertEqual([s["stage"] for s in stages], ["D0", "D1", "S0"])
        self.assertEqual([f["nodeId"] for f in frontier], ["D1.service"])

    def test_collect_settings_typed_shape(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            orch = repo / "scripts" / "orchestration"
            orch.mkdir(parents=True)
            (orch / "lib.sh").write_text(
                'SINGULAR_L2_SLICE_BUDGET="${SINGULAR_L2_SLICE_BUDGET:-2}"\n'
                'SINGULAR_ENABLE_L1_PARALLEL="${SINGULAR_ENABLE_L1_PARALLEL:-0}"\n'
            )
            (orch / "autonomate.sh").write_text(
                'export SINGULAR_AUTO_INTEGRATE="${SINGULAR_AUTO_INTEGRATE:-1}"\n'
            )
            (orch / "codex-run.sh").write_text("")
            (orch / "reconcile.sh").write_text("")
            groups = srv.collect_settings(repo)
            # every group carries title + category alias + layout
            self.assertTrue(all(g["title"] == g["category"] and "layout" in g for g in groups))
            self.assertEqual(groups[0]["layout"], "matrix")  # models group
            flat = {it["envKey"]: it for g in groups for it in g["items"]}
            # parsed default wins over fallback; metadata is carried through
            self.assertEqual(flat["SINGULAR_L2_SLICE_BUDGET"]["value"], "2")
            self.assertEqual(flat["SINGULAR_L2_SLICE_BUDGET"]["kind"], "count")
            # duration unit is split OUT of the label, not baked in parens
            loop = flat["SINGULAR_MAX_HOURS"]
            self.assertEqual((loop["unit"], loop["label"]), ("h", "loop budget"))
            # booleans expose boolValue, never rendered as raw 0/1 downstream
            self.assertIs(flat["SINGULAR_ENABLE_L1_PARALLEL"]["boolValue"], False)
            self.assertIs(flat["SINGULAR_AUTO_INTEGRATE"]["boolValue"], True)
            # derived dispatch stays an honest non-resolved string
            self.assertEqual(flat["SINGULAR_MAX_DISPATCH"]["kind"], "derived")
            self.assertEqual(flat["SINGULAR_MAX_DISPATCH"]["value"], "follows max concurrent")
            # every item carries meaning help text
            self.assertTrue(all(isinstance(it["meaning"], str) for it in flat.values()))

    def test_compute_loop_pulse(self) -> None:
        import json as _json
        now = srv._iso_to_epoch("2026-06-05T21:00:00Z")
        ev = lambda t, **d: _json.dumps({"type": t, "ts": d.pop("ts"), "data": d})
        lines = [
            ev("planner.generated", ts="2026-06-05T20:55:00Z", taskId="T1", area="evidence"),
            ev("planner.generated", ts="2026-06-05T20:54:00Z", taskId="T2", area="recovery"),
            ev("integration.integrated", ts="2026-06-05T20:58:00Z", taskId="T2"),
            ev("integration.integrated", ts="2026-06-05T20:59:00Z", taskId="T1"),  # newest advance
            ev("integration.integrated", ts="2026-06-05T11:00:00Z", taskId="T0"),  # old, out of window
        ]
        index = srv.build_events_index(lines)
        registry = srv.parse_dag({"nodes": [
            {"id": "D5.x", "stage": "D5", "area": "evidence", "layer": "service"},
            {"id": "D6.y", "stage": "D6", "area": "recovery", "layer": "service"},
            {"id": "S0.base", "stage": "S0", "area": "storage", "layer": "base"},
        ]})
        gates = {"S0.base": "passed"}  # D5.x / D6.y absent => frontier
        pulse, activity = srv.compute_loop_pulse(index, registry, gates, now)
        # newest advance is T1 (evidence) -> active area; old T0 excluded from the 1h window
        self.assertEqual(pulse["activeArea"], "evidence")
        self.assertEqual(pulse["recentIntegrations"], 2)
        self.assertEqual(pulse["lastIntegrationAt"], "2026-06-05T20:59:00Z")
        # frontier areas only (storage/S0 passed is dropped); evidence flagged active + has throughput
        areas = {a["area"]: a for a in activity}
        self.assertEqual(set(areas), {"evidence", "recovery"})
        self.assertTrue(areas["evidence"]["active"])
        self.assertEqual(areas["evidence"]["recentIntegrations"], 1)
        self.assertFalse(areas["recovery"]["active"])
        self.assertEqual([n["id"] for n in areas["evidence"]["nodes"]], ["D5.x"])

    def test_parse_status_md(self) -> None:
        text = ("# singular Autonomous Status\nUpdated: 2026-06-05T13:28:30Z\nIteration: 6\n"
                "Note: stopped (STOP sentinel)\nSTOP requested: yes\n"
                "- branch: `codex/singular-bootstrap-target` @ `c0d342d`\n"
                "- ready tasks: 5\n- active leases: 0\n- imported packets: 536\n"
                "- integrations (lifetime): 535\n- parked escalations (lifetime): 71\n"
                "- circuit-breaker consecutive failures: 0 / 5\n")
        s = srv.parse_status_md(text)
        self.assertEqual(s["iteration"], 6)
        self.assertEqual(s["note"], "stopped (STOP sentinel)")
        self.assertTrue(s["stopRequested"])
        self.assertEqual(s["integrationsLifetime"], 535)
        self.assertEqual(s["parkedLifetime"], 71)
        self.assertEqual(s["branch"], "codex/singular-bootstrap-target")
        self.assertEqual(s["breaker"], "0 / 5")


class NodeRankAndStageOrderTests(unittest.TestCase):
    """PMGO-001: rank comes from the dependency edges, and stage order follows
    rank — the lexical D-prefix/numeric key survives only as the tie-break."""

    def test_ranks_chain_diamond_and_dangling(self) -> None:
        registry = srv.parse_dag({"nodes": [
            {"id": "root", "stage": "S0", "dependsOn": []},
            {"id": "left", "stage": "S1", "dependsOn": ["root"]},
            {"id": "right", "stage": "S1", "dependsOn": ["root"]},
            {"id": "join", "stage": "S2", "dependsOn": ["left", "right"]},
            # dependency on an id the registry does not know: ignored, not fatal
            {"id": "orphan", "stage": "S3", "dependsOn": ["nowhere"]},
        ]})
        ranks = srv.compute_node_ranks(registry["by_id"])
        self.assertEqual(ranks, {"root": 0, "left": 1, "right": 1, "join": 2, "orphan": 0})

    def test_ranks_tolerate_a_cycle_without_crashing(self) -> None:
        registry = srv.parse_dag({"nodes": [
            {"id": "a", "dependsOn": ["b"]},
            {"id": "b", "dependsOn": ["a"]},
            {"id": "c", "dependsOn": []},
            {"id": "d", "dependsOn": ["c", "a"]},
        ]})
        ranks = srv.compute_node_ranks(registry["by_id"])
        self.assertEqual(set(ranks), {"a", "b", "c", "d"})  # every node ranked
        self.assertEqual(ranks["c"], 0)
        self.assertTrue(all(isinstance(v, int) for v in ranks.values()))

    def _inverted_registry(self) -> dict:
        """Unique stage per node, with the NUMERIC stage order exactly inverted
        against the dependency order: lexical sorting yields D1, D5, D9;
        dependency order is D9 -> D5 -> D1."""
        return {"nodes": [
            {"id": "first", "stage": "D9", "area": "core", "layer": "contract",
             "kind": "contract", "dependsOn": [], "requiredCompletion": "x"},
            {"id": "second", "stage": "D5", "area": "core", "layer": "service",
             "kind": "runtime", "dependsOn": ["first"], "requiredCompletion": "x"},
            {"id": "third", "stage": "D1", "area": "core", "layer": "service",
             "kind": "runtime", "dependsOn": ["second"], "requiredCompletion": "x"},
        ]}

    def test_plan_progress_stages_follow_dependencies_not_stage_numbers(self) -> None:
        registry = srv.parse_dag(self._inverted_registry())
        _progress, stages, _frontier = srv.compute_plan_progress(registry, {})
        self.assertEqual([s["stage"] for s in stages], ["D9", "D5", "D1"])

    def test_dag_view_stages_follow_dependencies_not_stage_numbers(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / "docs/orchestration/gates").mkdir(parents=True)
            (repo / "docs/orchestration/dag.v0.json").write_text(
                json.dumps({"schema": "singular.orchestration.dag.v0",
                            **self._inverted_registry()}))
            view = srv.collect_dag_view(repo)
            self.assertEqual([s["id"] for s in view["stages"]], ["D9", "D5", "D1"])
            ranks = {n["id"]: n["rank"] for n in view["nodes"]}
            self.assertEqual(ranks, {"first": 0, "second": 1, "third": 2})

    def test_equal_ranks_keep_the_legacy_lexical_order(self) -> None:
        # No edges anywhere -> every stage rank ties -> the old key decides, so
        # existing plans keep the exact stage order they render today.
        registry = srv.parse_dag({"nodes": [
            {"id": "s0", "stage": "S0"}, {"id": "d1", "stage": "D1"},
            {"id": "d0", "stage": "D0"},
        ]})
        _progress, stages, _frontier = srv.compute_plan_progress(registry, {})
        self.assertEqual([s["stage"] for s in stages], ["D0", "D1", "S0"])


class GateCohortTests(unittest.TestCase):
    """PMGO-002: passed gates split into the historical accepted-as-done set and
    what the current campaign earned. The combined figures never move."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / "docs/orchestration/gates").mkdir(parents=True)
        return repo

    def _dag(self, repo: Path, node_ids: list[str]) -> None:
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({
            "schema": "singular.orchestration.dag.v0",
            "nodes": [{"id": nid, "stage": "D0", "area": "core", "layer": "contract",
                       "kind": "contract", "dependsOn": [], "requiredCompletion": "x"}
                      for nid in node_ids]}))

    def _gate(self, repo: Path, node_id: str, status: str, evidence_class: str) -> None:
        (repo / "docs/orchestration/gates" / f"{node_id}.gate-result.json").write_text(
            json.dumps({"node": node_id, "status": status, "authoritative": True,
                        "evidenceClass": evidence_class,
                        "recordedAt": "2026-06-25T22:53:13Z"}))

    def test_gate_cohort_classification(self) -> None:
        self.assertEqual(srv._gate_cohort(
            {"status": "passed", "evidenceClass": "grandfathered"}), "historical")
        self.assertEqual(srv._gate_cohort(
            {"status": "passed", "evidenceClass": "deterministic-proof"}), "current")
        # acknowledged-baseline is a successful status too, and provenance still
        # decides which campaign it belongs to
        self.assertEqual(srv._gate_cohort(
            {"status": "passed-with-acknowledged-baseline", "evidenceClass": None}), "current")
        self.assertEqual(srv._gate_cohort(
            {"status": "passed-with-acknowledged-baseline",
             "evidenceClass": "grandfathered"}), "historical")
        # nothing unsuccessful belongs to a cohort
        for status in ("absent", "failed", "blocked", "stale"):
            self.assertIsNone(srv._gate_cohort({"status": status}), status)
        self.assertIsNone(srv._gate_cohort(None))

    def test_mixed_provenance_counts(self) -> None:
        repo = self._repo()
        self._dag(repo, ["h1", "h2", "c1", "absent1"])
        self._gate(repo, "h1", "passed", "grandfathered")
        self._gate(repo, "h2", "passed-with-acknowledged-baseline", "grandfathered")
        self._gate(repo, "c1", "passed", "deterministic-proof")
        registry = srv.load_dag_registry(repo)
        records = srv._all_gate_records(repo)
        statuses = srv._all_gate_statuses(repo)
        self.assertEqual(statuses["h2"], "passed-with-acknowledged-baseline")
        progress, _stages, _frontier = srv.compute_plan_progress(registry, statuses, records)
        self.assertEqual((progress["passedNodes"], progress["totalNodes"], progress["pct"]),
                         (3, 4, 75))
        self.assertEqual(progress["cohorts"], {
            "historical": {"passed": 2, "total": 2},
            "current": {"passed": 1, "total": 2, "pct": 50}})
        # the same block reaches /api/state + /api/home through the gate summary
        self.assertEqual(srv.collect_gates_summary(repo)["cohorts"], progress["cohorts"])

    def test_axon_shape_every_passed_gate_is_historical(self) -> None:
        # The reported shape: 2 authoritative grandfathered gates, 2 future nodes
        # with no gate at all, and a loop that has never actuated.
        repo = self._repo()
        self._dag(repo, ["old1", "old2", "new1", "new2"])
        self._gate(repo, "old1", "passed", "grandfathered")
        self._gate(repo, "old2", "passed", "grandfathered")
        registry = srv.load_dag_registry(repo)
        records = srv._all_gate_records(repo)
        progress, _stages, _frontier = srv.compute_plan_progress(
            registry, srv._all_gate_statuses(repo), records)
        # combined math is untouched: still the same 2/4 = 50% it reports today
        self.assertEqual((progress["passedNodes"], progress["totalNodes"], progress["pct"]),
                         (2, 4, 50))
        # ... but the current campaign has produced nothing, and says so
        self.assertEqual(progress["cohorts"]["current"], {"passed": 0, "total": 2, "pct": 0})
        self.assertEqual(progress["cohorts"]["historical"], {"passed": 2, "total": 2})

    def test_home_digest_carries_cohorts(self) -> None:
        repo = self._repo()
        self._dag(repo, ["old1", "new1"])
        self._gate(repo, "old1", "passed", "grandfathered")
        home = srv.collect_home(repo)
        self.assertEqual(home["gates"]["passed"], 1)
        self.assertEqual(home["gates"]["cohorts"]["historical"], {"passed": 1, "total": 1})
        self.assertEqual(home["gates"]["cohorts"]["current"],
                         {"passed": 0, "total": 1, "pct": 0})


# --------------------------------------------------------------------------- #
# Console adapter tests (C1/C2/C3)                                              #
# --------------------------------------------------------------------------- #

class ConsoleAdapterPrecedenceTests(unittest.TestCase):
    """repo override > engine-shipped > built-in, merged per top-level KEY."""

    def _fixture(self, base: Path) -> tuple[Path, Path]:
        repo = base / "repo"
        (repo / "docs/orchestration").mkdir(parents=True)
        engine = base / "engine-home"
        (engine / "plugin/adapters").mkdir(parents=True)
        return repo, engine

    def test_per_key_precedence_repo_over_engine_over_builtin(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo, engine = self._fixture(Path(d))
            # (b) engine-shipped: provides commands AND noiseEventTypes
            (engine / "plugin/adapters/console-adapter.v0.json").write_text(json.dumps({
                "schema": "singular.console-adapter.v0",
                "commands": {"status": ["singular", "status"]},
                "noiseEventTypes": ["engine.noise"],
            }))
            # (a2) repo adapter file: provides noiseEventTypes only
            (repo / "docs/orchestration/console-adapter.json").write_text(json.dumps({
                "noiseEventTypes": ["repo.noise"],
            }))
            # (a1) inline console block: provides commands only
            (repo / "singular.config.json").write_text(json.dumps({
                "schemaVersion": "v0",
                "console": {"commands": {"status": ["custom", "status"]}},
            }))
            merged = srv.load_console_adapter(repo, str(engine))
            builtin = srv.builtin_console_adapter()
            # commands: inline repo block wins over the engine layer
            self.assertEqual(merged["commands"], {"status": ["custom", "status"]})
            # noiseEventTypes: repo file wins over the engine layer
            self.assertEqual(merged["noiseEventTypes"], ["repo.noise"])
            # untouched keys fall through to built-in
            self.assertEqual(merged["rolePromptMap"], builtin["rolePromptMap"])
            self.assertEqual(merged["paths"], builtin["paths"])
            # applying merges dict-valued keys over the built-in (per-key merge:
            # a repo that only overrides `commands.status` keeps everything else)
            apply_adapter_with_restore(self, merged)
            self.assertEqual(srv.CONSOLE_COMMANDS["status"], ["custom", "status"])
            self.assertEqual(srv.CONSOLE_COMMANDS["nextArea"], ["make", "orch-next-area"])
            self.assertEqual(srv.NOISE_EVENT_TYPES, {"repo.noise"})

    def test_engine_layer_alone_and_builtin_fallthrough(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo, engine = self._fixture(Path(d))
            (engine / "plugin/adapters/console-adapter.v0.json").write_text(json.dumps({
                "commands": {"status": ["singular", "status"]},
            }))
            merged = srv.load_console_adapter(repo, str(engine))
            self.assertEqual(merged["commands"], {"status": ["singular", "status"]})
            # no adapter at all -> pure built-in document
            none = srv.load_console_adapter(repo, None)
            self.assertEqual(none, srv.builtin_console_adapter())

    def test_schema_version_selects_engine_adapter_file(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo, engine = self._fixture(Path(d))
            (repo / "singular.config.json").write_text(json.dumps({"schemaVersion": "v1"}))
            (engine / "plugin/adapters/console-adapter.v0.json").write_text(json.dumps({
                "commands": {"status": ["wrong", "file"]}}))
            (engine / "plugin/adapters/console-adapter.v1.json").write_text(json.dumps({
                "commands": {"status": ["right", "file"]}}))
            merged = srv.load_console_adapter(repo, str(engine))
            self.assertEqual(merged["commands"], {"status": ["right", "file"]})

    def test_malformed_layer_warns_and_falls_through(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo, engine = self._fixture(Path(d))
            (engine / "plugin/adapters/console-adapter.v0.json").write_text("{not json")
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                merged = srv.load_console_adapter(repo, str(engine))
            self.assertIn("malformed", err.getvalue())
            self.assertEqual(merged, srv.builtin_console_adapter())

    def test_bad_key_keeps_builtin_for_that_key_only(self) -> None:
        bad = dict(srv.builtin_console_adapter())
        bad["idPatterns"] = {"task": "(unbalanced", "node": "x", "area": "y"}
        bad["commands"] = {"status": ["singular", "status"]}
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            apply_adapter_with_restore(self, bad)
        self.assertIn("idPatterns", err.getvalue())
        self.assertEqual(srv.TASK_ID_RE.pattern, r"^TASK-\d+$")  # built-in kept
        self.assertEqual(srv.CONSOLE_COMMANDS["status"], ["singular", "status"])  # good key applied


class TargetBranchFlowTests(unittest.TestCase):
    """C4: a config-driven targetBranch flows into env injection, the drift
    check, and the snapshot — never the baked-in default."""

    def test_config_branch_flows_to_env_drift_and_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / "singular.config.json").write_text(json.dumps(
                {"targetBranch": "custom/integration"}))
            self.assertEqual(srv.load_repo_target_branch(repo), "custom/integration")
            saved = srv.TARGET_BRANCH
            self.addCleanup(lambda: setattr(srv, "TARGET_BRANCH", saved))
            srv.TARGET_BRANCH = srv.load_repo_target_branch(repo)  # what main() does
            # subprocess env injection
            res = srv.run_command(repo, ["sh", "-c", 'printf %s "$SINGULAR_TARGET_BRANCH"'])
            self.assertEqual(res["stdout"], "custom/integration")
            # drift check + snapshot field
            saved_procs = srv.collect_processes
            self.addCleanup(lambda: setattr(srv, "collect_processes", saved_procs))
            srv.collect_processes = lambda: []
            snap = srv.collect_snapshot(repo)
            self.assertEqual(snap["targetBranch"], "custom/integration")
            self.assertEqual(
                snap["git"]["drift"]["raw"]["cmd"],
                ["git", "rev-list", "--left-right", "--count",
                 "origin/custom/integration...custom/integration"])


class CliProjectFixtureTests(unittest.TestCase):
    """C3: a CLI project (no Makefile, no scripts/orchestration) with
    SINGULAR_ENGINE_HOME + the shipped v0 adapter gets singular commands and reads its
    settings defaults from the engine's own scripts."""

    SHIPPED_ADAPTER = Path(srv.__file__).resolve().parent.parent / "adapters/console-adapter.v0.json"

    def test_singular_commands_and_engine_settings_source(self) -> None:
        if not self.SHIPPED_ADAPTER.is_file():
            # The standalone plugin copy ships the console adapterless (the engine
            # owns plugin/adapters/); skip rather than error when it isn't co-located.
            self.skipTest(f"shipped adapter not co-located: {self.SHIPPED_ADAPTER}")
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            repo = base / "cli-project"
            repo.mkdir()
            (repo / "singular.config.json").write_text(json.dumps(
                {"schemaVersion": "v0", "targetBranch": "main"}))
            engine = base / "engine-home"
            (engine / "plugin/adapters").mkdir(parents=True)
            (engine / "plugin/adapters/console-adapter.v0.json").write_text(
                self.SHIPPED_ADAPTER.read_text())
            (engine / "engine").mkdir()
            (engine / "engine/lib.sh").write_text(
                'SINGULAR_MAX_CONCURRENT="${SINGULAR_MAX_CONCURRENT:-4}"\n')
            (engine / "engine/codex-run.sh").write_text("")
            (engine / "engine/reconcile.sh").write_text("")
            (engine / "engine/autonomate.sh").write_text("")
            saved_env = os.environ.get("SINGULAR_ENGINE_HOME")

            def restore_env() -> None:
                if saved_env is None:
                    os.environ.pop("SINGULAR_ENGINE_HOME", None)
                else:
                    os.environ["SINGULAR_ENGINE_HOME"] = saved_env

            self.addCleanup(restore_env)
            os.environ["SINGULAR_ENGINE_HOME"] = str(engine)
            apply_adapter_with_restore(self, srv.load_console_adapter(repo, str(engine)))
            # commands are the singular CLI equivalents, not make orch-* targets
            self.assertEqual(srv.CONSOLE_COMMANDS["status"], ["singular", "status"])
            self.assertEqual(srv.CONSOLE_COMMANDS["validateDag"], ["singular", "validate-dag"])
            self.assertEqual(srv.console_command("areaGate", node="D1.contract"),
                             ["singular", "area-gate", "D1.contract"])
            # settings source resolves to the engine's scripts via the template
            self.assertEqual(srv.SETTINGS_SOURCE, "{engineHome}/engine")
            self.assertEqual(srv.resolve_settings_dir(repo), engine / "engine")
            flat = {it["envKey"]: it for g in srv.collect_settings(repo) for it in g["items"]}
            self.assertEqual(flat["SINGULAR_MAX_CONCURRENT"]["value"], "4")
            # the new engine event types arrive via the shipped adapter
            for etype in NEW_ENGINE_EVENT_TYPES:
                self.assertIn(etype, srv.EVENT_MAP)
            row = srv.project_event(_ev("context.strategy_selected", "t", taskId="TASK-1"))
            self.assertEqual(row["label"], "Context strategy selected")

    def test_settings_source_engine_home_fallback_without_adapter(self) -> None:
        # No adapter, but SINGULAR_ENGINE_HOME set -> engine/*.sh; unset -> legacy repo dir.
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            saved_env = os.environ.get("SINGULAR_ENGINE_HOME")

            def restore_env() -> None:
                if saved_env is None:
                    os.environ.pop("SINGULAR_ENGINE_HOME", None)
                else:
                    os.environ["SINGULAR_ENGINE_HOME"] = saved_env

            self.addCleanup(restore_env)
            os.environ["SINGULAR_ENGINE_HOME"] = "/opt/singular-engine"
            self.assertEqual(srv.resolve_settings_dir(repo), Path("/opt/singular-engine/engine"))
            os.environ.pop("SINGULAR_ENGINE_HOME", None)
            self.assertEqual(srv.resolve_settings_dir(repo), repo / "scripts/orchestration")


class UnknownEventTypeRenderingTests(unittest.TestCase):
    def test_builtin_event_map_does_not_gain_new_engine_types(self) -> None:
        for etype in NEW_ENGINE_EVENT_TYPES:
            self.assertNotIn(etype, srv.builtin_console_adapter()["eventMap"])

    def test_unknown_types_in_events_ndjson_render_gracefully(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".singular-state").mkdir()
            lines = [json.dumps(_ev(t, "2026-06-09T00:00:00Z", taskId="TASK-1"))
                     for t in NEW_ENGINE_EVENT_TYPES + ["totally.unknown_type"]]
            (repo / ".singular-state/events.ndjson").write_text("\n".join(lines) + "\n")
            res = srv.collect_events_overlay(repo, None, 100, None)  # must not raise
            self.assertEqual(len(res["rows"]), len(lines))
            by_type = {r["type"]: r for r in res["rows"]}
            for etype in NEW_ENGINE_EVENT_TYPES + ["totally.unknown_type"]:
                row = by_type[etype]
                # sane default: message text as label, muted tone, control phase
                self.assertEqual(row["label"], etype)  # _ev sets message=etype
                self.assertEqual(row["tone"], "gray")
                self.assertEqual(row["phase"], "control")
                self.assertFalse(row["advancing"])


class NoAdapterSnapshotIdentityTests(unittest.TestCase):
    """HARD back-compat gate: with no adapter resolvable, the key endpoint
    payloads must be deep-equal to those produced by the committed (HEAD)
    server run as a module against the same fixture."""

    FIXED_NOW = "2026-06-09T12:00:00Z"
    FIXED_DISK = {"df": {"ok": True}, "du": {"ok": True},
                  "capacityPercent": 50, "free": "100Gi", "watch": False}

    def _build_fixture(self, repo: Path) -> None:
        (repo / "docs/orchestration/tasks").mkdir(parents=True)
        (repo / "docs/orchestration/gates").mkdir(parents=True)
        (repo / "docs/orchestration/areas/artifact").mkdir(parents=True)
        (repo / ".singular-state/leases").mkdir(parents=True)
        (repo / "scripts/orchestration").mkdir(parents=True)
        (repo / "singular.config.json").write_text(json.dumps(
            {"schemaVersion": "v0", "targetBranch": "agent/integration"}))
        (repo / "docs/orchestration/tasks/TASK-0001.md").write_text(
            "# TASK-0001: Sample slice\n"
            "Status: integrated\nArea: artifact\nTarget Branch: `agent/integration`\n"
            "Worker Branch: `agent/task-0001`\nTest Policy: `test-first`\n"
            "Gate Command: `go test ./...`\nDepends On: []\n\n"
            "## Objective\nDo a sample thing.\n\n## Acceptance Criteria\n- it works\n")
        (repo / "docs/orchestration/areas/artifact/state.md").write_text("# artifact\n")
        (repo / ".singular-state/leases/TASK-0001.json").write_text(json.dumps({
            "taskId": "TASK-0001", "status": "integrated", "owner": "l2-developer",
            "runId": "RUN-1", "area": "artifact", "branch": "agent/task-0001",
            "worktree": str(repo / ".worktrees/none"), "updatedAt": "2026-06-08T10:00:00Z",
            "ownedFiles": ["a.go"]}))
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({"nodes": [
            {"id": "D0.contract", "stage": "D0", "area": "kernel", "layer": "contract",
             "description": "Kernel contract.", "requiredCompletion": "contract_complete"},
            {"id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract",
             "description": "Artifact contract.", "requiredCompletion": "contract_complete",
             "dependsOn": ["D0.contract"]}]}))
        (repo / "docs/orchestration/gates/D0.contract.gate-result.json").write_text(
            json.dumps({"node": "D0.contract", "status": "passed", "authoritative": True,
                        "evidence": [{"kind": "task-set", "taskIds": ["TASK-0001"]}]}))
        (repo / "docs/plan-and-dag.md").write_text(
            "# Plan\n## 7. Stage Cards\n### D0: Kernel\nD0 body\n### D1: Artifact\nD1 body\n")
        events = [
            _ev("planner.generated", "2026-06-08T09:00:00Z", taskId="TASK-0001",
                node="D1.contract", runId="ORIGIN-1", area="artifact"),
            _ev("l1.dispatch_started", "2026-06-08T09:01:00Z", taskId="TASK-0001",
                runId="RUN-1", branch="agent/task-0001"),
            _ev("integration.skipped", "2026-06-08T09:02:00Z", taskId="TASK-0001"),
            _ev("integration.integrated", "2026-06-08T09:03:00Z", taskId="TASK-0001",
                branch="agent/task-0001", mergeCommit="abc1234def"),
            # unknown-to-the-built-in type: both servers must degrade identically
            _ev("worker.infra_retry", "2026-06-08T09:04:00Z", taskId="TASK-0001"),
        ]
        (repo / ".singular-state/events.ndjson").write_text(
            "\n".join(json.dumps(e) for e in events) + "\n")
        (repo / ".singular-state/autonomate.out.log").write_text("loop line 1\nloop line 2\n")
        (repo / ".singular-state/STATUS.md").write_text(
            "# singular Autonomous Status\nUpdated: 2026-06-08T10:00:00Z\nIteration: 3\n"
            "Note: running\n- ready tasks: 1\n- integrations (lifetime): 12\n")
        (repo / ".singular-state/circuit.json").write_text(json.dumps({"consecFails": 0}))
        (repo / "scripts/orchestration/lib.sh").write_text(
            'SINGULAR_MAX_CONCURRENT="${SINGULAR_MAX_CONCURRENT:-2}"\n'
            'SINGULAR_TARGET_BRANCH="${SINGULAR_TARGET_BRANCH:-agent/integration}"\n')
        (repo / ".singular-state/.env").write_text("SINGULAR_SLEEP=5\nDATABASE_URL=secret\n")

    def _load_head_module(self, tmp: Path):
        root = Path(srv.__file__).resolve().parents[2]
        proc = subprocess.run(
            ["git", "-C", str(root), "show", "HEAD:plugin/scripts/singular_graph_server.py"],
            capture_output=True, text=True)
        if proc.returncode != 0:
            self.skipTest(f"cannot read HEAD server from git: {proc.stderr.strip()}")
        path = tmp / "singular_graph_server_head.py"
        path.write_text(proc.stdout)
        spec = importlib.util.spec_from_file_location("singular_graph_server_head", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def _pin(self, mod) -> None:
        """Pin the only honestly-volatile inputs (clock, live ps, live df/du)
        identically in a module; everything else must match for real."""
        mod.utc_now = lambda: self.FIXED_NOW
        mod.collect_processes = lambda: []
        mod.collect_disk = lambda repo: dict(self.FIXED_DISK)

    def test_key_endpoints_identical_to_head_without_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            repo = base / "repo"
            repo.mkdir()
            self._build_fixture(repo)
            saved_env = os.environ.pop("SINGULAR_ENGINE_HOME", None)
            if saved_env is not None:
                self.addCleanup(lambda: os.environ.__setitem__("SINGULAR_ENGINE_HOME", saved_env))
            head = self._load_head_module(base)
            saved = {n: getattr(srv, n) for n in
                     ("utc_now", "collect_processes", "collect_disk", "TARGET_BRANCH")}
            self.addCleanup(lambda: [setattr(srv, n, v) for n, v in saved.items()])
            self._pin(srv)
            self._pin(head)
            # mirror main() startup for both servers; no adapter is resolvable here
            srv.initialize_configuration(repo, force=True)
            self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
            apply_adapter_with_restore(self, srv.load_console_adapter(repo, None))
            head.TARGET_BRANCH = head.load_repo_target_branch(repo)

            def wire(payload) -> str:  # exactly what send_json serializes
                return json.dumps(payload, indent=2)

            # /api/state is intentionally NOT compared since 0.5.0: the built-in
            # probes went native (no make orch-* subprocesses), gateD0/gateD1
            # were replaced by orchestration.gates, and disk.du became a
            # non-blocking background peek — see NativeFrontierTests /
            # ValidateDagNativeTests / SnapshotNoSubprocessTests below.
            # /api/overview (includes settings groups). 0.17.0 added three
            # fields: progress.cohorts (PMGO-002), loop.stopReason (PMGO-003)
            # and l1Selection (AXON-002). They are dropped from BOTH sides
            # rather than the comparison being dropped — everything else must
            # still be byte-identical, and the new fields have their own
            # assertions below.
            #
            # Both sides, not just the working tree's: the baseline is whatever
            # `git show HEAD:` yields, so it MOVES. While the change was
            # uncommitted HEAD predated these fields and stripping one side
            # happened to work; the moment the change landed, HEAD grew them
            # too and a one-sided strip could never match again — the test
            # would fail forever on a clean tree for no product reason.
            # Stripping symmetrically is what the assertion always meant:
            # "nothing changed except what we declared."
            def drop_new_overview_fields(payload: dict) -> dict:
                out = dict(payload)
                out.pop("l1Selection", None)
                out.pop("generation", None)
                out.pop("settings", None)  # effective settings have dedicated contract tests
                out["progress"] = {k: v for k, v in (out.get("progress") or {}).items()
                                   if k != "cohorts"}
                out["loop"] = {k: v for k, v in (out.get("loop") or {}).items()
                               if k != "stopReason"}
                return out

            self.assertEqual(wire(drop_new_overview_fields(srv.collect_overview(repo))),
                             wire(drop_new_overview_fields(head.collect_overview(repo))))
            self.assertEqual(wire(srv.collect_settings(repo)),
                             wire(head.collect_settings(repo)))
            # /api/events live overlay
            self.assertEqual(wire(srv.collect_events_overlay(repo, None, 120, None)),
                             wire(head.collect_events_overlay(repo, None, 120, None)))
            # /api/task detail
            self.assertEqual(wire(srv.collect_task_detail(repo, "TASK-0001")),
                             wire(head.collect_task_detail(repo, "TASK-0001")))
            # /api/roles static catalog
            self.assertEqual(wire(srv.ROLE_CATALOG), wire(head.ROLE_CATALOG))


class ProcessMatcherSemanticsTests(unittest.TestCase):
    """The matcher rewrite must filter ps output exactly like the inline checks."""

    PS = "\n".join([
        "  PID  PPID COMMAND",
        "  100     1 bash scripts/orchestration/autonomate.sh",
        "  101     1 codex --cd /x/SINGULAR exec something",
        "  102     1 python3 plugin/scripts/singular_graph_server.py --repo .",   # excluded
        "  103     1 rg --files",                                            # not matched
        "  104     1 bash /repo/.worktrees/task-1/run.sh",
        "  105     1 some autonomate thing | Cursor Helper",                 # excluded (lowered)
    ])

    def test_filtering_matches_legacy_semantics(self) -> None:
        saved = srv.run_command
        self.addCleanup(lambda: setattr(srv, "run_command", saved))
        srv.run_command = lambda repo, cmd, timeout=5: {"ok": True, "stdout": self.PS}
        rows = srv.collect_processes()
        pids = [r["pid"] for r in rows]
        self.assertEqual(pids, ["100", "101", "104"])


class NativeFrontierTests(unittest.TestCase):
    """O1 (0.5.0): compute_frontier_native must replicate `engine/dag.sh
    next-areas` exactly — file-order iteration, passed+authoritative completes,
    blocked+authoritative excludes, all-deps-gated joins the frontier."""

    ENTRY_KEYS = {"node", "stage", "area", "layer", "kind", "requiredCompletion"}

    def _node(self, node_id: str, deps: list[str]) -> dict:
        return {"id": node_id, "stage": node_id.split(".")[0], "area": "core",
                "layer": "contract", "kind": "build", "dependsOn": deps,
                "requiredCompletion": "done"}

    def _write_dag(self, repo: Path, nodes: list[dict]) -> None:
        (repo / "docs/orchestration/gates").mkdir(parents=True, exist_ok=True)
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps(
            {"schema": "singular.orchestration.dag.v0", "nodes": nodes}))

    def _gate(self, repo: Path, node_id: str, status: str, authoritative: bool = True) -> None:
        (repo / "docs/orchestration/gates" / f"{node_id}.gate-result.json").write_text(
            json.dumps({"node": node_id, "status": status, "authoritative": authoritative}))

    def test_membership_and_entry_shape(self) -> None:
        # 4 nodes: passed, ready, dep-blocked, authoritative-blocked.
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [
                self._node("D0.passed", []),
                self._node("D1.ready", ["D0.passed"]),
                self._node("D2.depblocked", ["D1.ready"]),
                self._node("D3.authblocked", []),
            ])
            self._gate(repo, "D0.passed", "passed")
            self._gate(repo, "D3.authblocked", "blocked")
            out = srv.compute_frontier_native(repo)
            self.assertEqual([f["node"] for f in out["frontier"]], ["D1.ready"])
            self.assertNotIn("allComplete", out)
            entry = out["frontier"][0]
            self.assertEqual(set(entry), self.ENTRY_KEYS)
            self.assertEqual(entry["stage"], "D1")
            self.assertEqual(entry["area"], "core")
            self.assertEqual(entry["requiredCompletion"], "done")

    def test_non_authoritative_blocked_stays_eligible(self) -> None:
        # dag.sh only excludes blocked gates that are ALSO authoritative.
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [self._node("D0.a", [])])
            self._gate(repo, "D0.a", "blocked", authoritative=False)
            out = srv.compute_frontier_native(repo)
            self.assertEqual([f["node"] for f in out["frontier"]], ["D0.a"])

    def test_all_complete(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [self._node("D0.a", []), self._node("D1.b", ["D0.a"])])
            self._gate(repo, "D0.a", "passed-with-acknowledged-baseline")
            self._gate(repo, "D1.b", "passed")
            out = srv.compute_frontier_native(repo)
            self.assertEqual(out, {"frontier": [], "allComplete": True})

    def test_unreadable_gate_json_reads_not_passed(self) -> None:
        # A corrupt gate file is not-passed (never raises): the node stays on the
        # frontier and its dependents stay excluded.
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [self._node("D0.a", []), self._node("D1.b", ["D0.a"])])
            (repo / "docs/orchestration/gates/D0.a.gate-result.json").write_text("{not json")
            out = srv.compute_frontier_native(repo)
            self.assertEqual([f["node"] for f in out["frontier"]], ["D0.a"])
            self.assertNotIn("allComplete", out)

    def test_passed_but_not_authoritative_does_not_complete(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [self._node("D0.a", []), self._node("D1.b", ["D0.a"])])
            self._gate(repo, "D0.a", "passed", authoritative=False)
            out = srv.compute_frontier_native(repo)
            # D0.a not complete (stays frontier-eligible); D1.b dep not gated.
            self.assertEqual([f["node"] for f in out["frontier"]], ["D0.a"])


class ValidateDagNativeTests(unittest.TestCase):
    """O1 (0.5.0): validate_dag_native structural checks + run_command envelope."""

    def _write(self, repo: Path, nodes: list[dict]) -> None:
        (repo / "docs/orchestration").mkdir(parents=True, exist_ok=True)
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps(
            {"schema": "singular.orchestration.dag.v0", "nodes": nodes}))

    def _node(self, node_id: str, deps: list[str]) -> dict:
        return {"id": node_id, "stage": "D0", "area": "core", "layer": "contract",
                "kind": "build", "dependsOn": deps, "requiredCompletion": "done"}

    def test_valid_dag_ok_envelope(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write(repo, [self._node("D0.a", []), self._node("D0.b", ["D0.a"])])
            out = srv.validate_dag_native(repo)
            self.assertEqual(out, {"ok": True, "exit": 0, "stdout": "ok", "stderr": "",
                                   "cmd": ["native:validate-dag"], "native": True})

    def test_duplicate_id_fails(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write(repo, [self._node("D0.a", []), self._node("D0.a", [])])
            out = srv.validate_dag_native(repo)
            self.assertFalse(out["ok"])
            self.assertEqual(out["exit"], 1)
            self.assertIn("duplicate node id: D0.a", out["stdout"])

    def test_unknown_dependency_fails(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write(repo, [self._node("D0.a", ["D9.ghost"])])
            out = srv.validate_dag_native(repo)
            self.assertFalse(out["ok"])
            self.assertIn("unknown dependency for D0.a: D9.ghost", out["stdout"])

    def test_missing_required_fields_fail(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            node = self._node("D0.a", [])
            del node["layer"], node["kind"]
            self._write(repo, [node])
            out = srv.validate_dag_native(repo)
            self.assertFalse(out["ok"])
            self.assertIn("missing required fields: kind, layer", out["stdout"])

    def test_missing_dag_file_fails_soft(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = srv.validate_dag_native(Path(d))
            self.assertFalse(out["ok"])
            self.assertIn("missing or unreadable", out["stdout"])


class SnapshotNoSubprocessTests(unittest.TestCase):
    """O1 (0.5.0) hard guarantee: with the built-in (non-adapter) probe
    commands, collect_snapshot never shells out to make."""

    def test_collect_snapshot_runs_no_make(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".singular-state").mkdir()
            (repo / "docs/orchestration/tasks").mkdir(parents=True)
            (repo / "docs/orchestration/gates").mkdir(parents=True)
            (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({
                "schema": "singular.orchestration.dag.v0",
                "nodes": [{"id": "D0.a", "stage": "D0", "area": "core", "layer": "contract",
                           "kind": "build", "dependsOn": [], "requiredCompletion": "done"}]}))
            run_dir = repo / ".singular-state/runs/RUN-resource"
            run_dir.mkdir(parents=True)
            (run_dir / "resource-plan.json").write_text(json.dumps({
                "schema": "singular.orchestration.resource-plan.v0",
                "configuredSlots": 7,
                "effectiveSlots": 1,
                "freeBytes": 1,
                "reserveBytes": 0,
                "estimatedWorktreeBytes": 1024,
                "affordableSlots": 1,
                "reason": "disk-limited-concurrency",
            }))
            calls: list[list[str]] = []
            real_run = subprocess.run

            def recording_run(cmd, *args, **kwargs):
                calls.append([str(p) for p in cmd])
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="stubbed")

            saved = srv.subprocess.run
            self.addCleanup(lambda: setattr(srv.subprocess, "run", saved))
            srv.subprocess.run = recording_run
            snap = srv.collect_snapshot(repo)
            first_argv = [c[0] for c in calls if c]
            self.assertNotIn("make", first_argv)
            # sanity: the probes are the native envelopes, not subprocess runs
            self.assertTrue(snap["orchestration"]["status"].get("native"))
            self.assertTrue(snap["orchestration"]["validateDag"].get("native"))
            self.assertEqual(snap["orchestration"]["gates"],
                             {"passed": 0, "total": 1, "byNode": {"D0.a": "absent"},
                              "cohorts": {"historical": {"passed": 0, "total": 0},
                                          "current": {"passed": 0, "total": 1, "pct": 0}}})
            self.assertEqual(snap["resources"]["configuredSlots"], 7)
            self.assertEqual(snap["resources"]["reserveBytes"], 0)
            self.assertEqual(snap["resources"]["estimatedWorktreeBytes"], 1024)
            self.assertEqual(snap["resources"]["source"], "latest-reconcile")
            self.assertEqual(
                [f["node"] for f in snap["orchestration"]["nextAreas"]["frontier"]], ["D0.a"])
            self.assertEqual(snap["orchestration"]["nextArea"]["node"], "D0.a")
            self.assertNotIn("gateD0", snap["orchestration"])
            self.assertNotIn("gateD1", snap["orchestration"])
            del real_run  # only kept for clarity: restoration goes through addCleanup


class SnapshotCacheStaleServeTests(unittest.TestCase):
    """O1 (0.5.0): a stale cache hit returns immediately (marked stale/computing)
    while one background refresh recomputes; the refreshed value then serves."""

    def test_stale_serve_then_background_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            release = threading.Event()
            counter = {"n": 0}

            def slow_snapshot(_repo):
                counter["n"] += 1
                if counter["n"] > 1:      # only refreshes block; the priming call is instant
                    release.wait(5)
                return {"n": counter["n"]}

            saved = srv.collect_snapshot
            self.addCleanup(lambda: setattr(srv, "collect_snapshot", saved))
            srv.collect_snapshot = slow_snapshot

            cache = srv.SnapshotCache(ttl=0.05)
            self.assertEqual(cache.get(repo), {"n": 1})    # cold start blocks + primes
            time.sleep(0.1)                                # expire the TTL

            t0 = time.monotonic()
            stale = cache.get(repo)                        # refresh is blocked on `release`
            self.assertLess(time.monotonic() - t0, 1.0, "stale get must not block")
            self.assertEqual(stale["n"], 1)
            self.assertTrue(stale["stale"])
            self.assertTrue(stale["computing"])
            self.assertIsInstance(stale["snapshotAgeSeconds"], int)

            release.set()
            deadline = time.monotonic() + 5
            current: dict = {}
            while time.monotonic() < deadline:
                current = cache.get(repo)
                if current.get("n", 0) >= 2 and not current.get("stale"):
                    break
                time.sleep(0.02)
            self.assertGreaterEqual(current.get("n", 0), 2, "background refresh never landed")
            self.assertNotIn("stale", current)
            self.assertIsNone(cache.last_error)

    def test_background_refresh_failure_recorded_not_raised(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            counter = {"n": 0}

            def flaky_snapshot(_repo):
                counter["n"] += 1
                if counter["n"] > 1:
                    raise RuntimeError("boom")
                return {"n": 1}

            saved = srv.collect_snapshot
            self.addCleanup(lambda: setattr(srv, "collect_snapshot", saved))
            srv.collect_snapshot = flaky_snapshot
            cache = srv.SnapshotCache(ttl=0.05)
            cache.get(repo)
            time.sleep(0.1)
            stale = cache.get(repo)     # kicks the failing refresh; must not raise
            self.assertTrue(stale["stale"])
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and cache.last_error is None:
                time.sleep(0.02)
            self.assertIn("boom", cache.last_error or "")
            self.assertIsNotNone(cache.age_seconds())

    def test_background_refresh_stays_on_captured_generation(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / "singular.config.json").write_text(json.dumps({
                "runner": "codex-run.sh", "env": {}
            }))
            initial = srv.initialize_configuration(repo, force=True)
            self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
            entered = threading.Event()
            release = threading.Event()
            seen: list[str] = []

            def snapshot(root):
                generation = srv._effective_configuration_view(root)["generation"]["id"]
                seen.append(generation)
                if len(seen) == 2:
                    entered.set()
                    self.assertTrue(release.wait(5))
                return {"generation": {"id": generation}, "call": len(seen)}

            saved = srv.collect_snapshot
            self.addCleanup(setattr, srv, "collect_snapshot", saved)
            srv.collect_snapshot = snapshot
            cache = srv.SnapshotCache(ttl=0.02)
            self.assertEqual(
                cache.get(repo)["generation"]["id"], initial["generation"]["id"]
            )
            time.sleep(0.04)
            stale = cache.get(repo)
            self.assertTrue(stale["stale"])
            self.assertTrue(entered.wait(5))
            (repo / "singular.config.json").write_text(json.dumps({
                "runner": "gemini-run.sh", "env": {}
            }))
            replacement = srv.initialize_configuration(repo, force=True)
            release.set()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                with cache._lock:
                    if not cache._refreshing:
                        break
                time.sleep(0.01)
            current = cache.get(repo)
            self.assertEqual(seen[1], initial["generation"]["id"])
            self.assertEqual(current["generation"]["id"], replacement["generation"]["id"])
            self.assertEqual(len(seen), 3)


class DiskUsageCacheTests(unittest.TestCase):
    """O1 (0.5.0): the du walk lives in its own background cache; a cold peek
    never blocks on it."""

    def test_cold_peek_non_blocking_then_value_lands(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            release = threading.Event()

            def slow_du(_repo, cmd, timeout=60):
                release.wait(5)
                return {"ok": True, "exit": 0, "stdout": "du-output", "stderr": "", "cmd": cmd}

            saved = srv.run_command
            srv.run_command = slow_du
            try:
                cache = srv.DiskUsageCache(ttl=300)
                t0 = time.monotonic()
                cold = cache.peek(repo)
                self.assertLess(time.monotonic() - t0, 1.0, "cold peek must not block on du")
                self.assertEqual(cold, {"computing": True})
                release.set()
                deadline = time.monotonic() + 5
                value: dict = {}
                while time.monotonic() < deadline:
                    value = cache.peek(repo)
                    if "ageSeconds" in value:
                        break
                    time.sleep(0.02)
                self.assertEqual(value.get("stdout"), "du-output")
                self.assertIsInstance(value.get("ageSeconds"), int)
                self.assertNotIn("computing", value)  # fresh again after the refresh
            finally:
                srv.run_command = saved

    def test_stale_peek_returns_last_value_and_recomputes_once(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            release = threading.Event()
            counter = {"n": 0}

            def counting_du(_repo, cmd, timeout=60):
                counter["n"] += 1
                if counter["n"] > 1:
                    release.wait(5)
                return {"ok": True, "exit": 0, "stdout": f"du-{counter['n']}", "stderr": "", "cmd": cmd}

            saved = srv.run_command
            srv.run_command = counting_du
            try:
                cache = srv.DiskUsageCache(ttl=0.05)
                cache.peek(repo)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and cache.peek(repo) == {"computing": True}:
                    time.sleep(0.02)
                time.sleep(0.1)  # expire the TTL
                stale = cache.peek(repo)       # second compute blocks on `release`
                self.assertEqual(stale.get("stdout"), "du-1")
                self.assertTrue(stale.get("computing"))
                stale2 = cache.peek(repo)      # refresh already in flight: no second thread
                self.assertEqual(stale2.get("stdout"), "du-1")
                release.set()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and cache.peek(repo).get("stdout") != "du-2":
                    time.sleep(0.02)
                self.assertEqual(cache.peek(repo).get("stdout"), "du-2")
            finally:
                release.set()
                srv.run_command = saved


class ProbeOverrideEscapeHatchTests(unittest.TestCase):
    """The adapter escape hatch: an explicitly configured probe command still
    runs as a subprocess; the pristine built-in resolves to native."""

    def test_builtin_commands_not_overridden(self) -> None:
        for name in ("status", "validateDag", "nextArea", "nextAreas"):
            self.assertFalse(srv.probe_command_overridden(name), name)

    def test_adapter_command_marks_probe_overridden(self) -> None:
        adapter = dict(srv.builtin_console_adapter())
        adapter["commands"] = {"status": ["singular", "status"]}
        apply_adapter_with_restore(self, adapter)
        self.assertTrue(srv.probe_command_overridden("status"))
        # deep-merged untouched keys remain built-in -> still native
        self.assertFalse(srv.probe_command_overridden("validateDag"))
        self.assertFalse(srv.probe_command_overridden("nextAreas"))


class AssetRouteTests(unittest.TestCase):
    """0.6.0 asset serving: extension allowlist + containment, subdirs allowed."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "core").mkdir()
        (root / "styles.css").write_text("body{}")
        (root / "core" / "util.js").write_text("export {};")
        (root / "notes.txt").write_text("not served")
        saved = srv.ASSETS_DIR
        srv.ASSETS_DIR = root
        self.addCleanup(lambda: setattr(srv, "ASSETS_DIR", saved))
        self.root = root

    def test_top_level_css(self) -> None:
        resolved = srv.resolve_asset("styles.css")
        self.assertIsNotNone(resolved)
        self.assertEqual(resolved[0], (self.root / "styles.css").resolve())
        self.assertIn("text/css", resolved[1])

    def test_subdirectory_module(self) -> None:
        resolved = srv.resolve_asset("core/util.js")
        self.assertIsNotNone(resolved)
        self.assertEqual(resolved[0], (self.root / "core" / "util.js").resolve())
        self.assertIn("javascript", resolved[1])

    def test_rejections(self) -> None:
        for name in ("../test_singular_graph_server.py", "..%2fx.js", "/etc/passwd",
                     "notes.txt", ".hidden.js", "core/.env.js", "", "core/missing.js"):
            self.assertIsNone(srv.resolve_asset(name), name)


class CollectDagViewTests(unittest.TestCase):
    """/api/dag (0.6.0): registry + gates + task rollups + edges + swimlanes."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / "docs/orchestration/tasks").mkdir(parents=True)
        (repo / "docs/orchestration/gates").mkdir(parents=True)
        (repo / ".singular-state/leases").mkdir(parents=True)
        (repo / ".singular-state/l1-leases").mkdir(parents=True)
        return repo

    def _write_dag(self, repo: Path) -> None:
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({
            "schema": "singular.orchestration.dag.v0",
            "layers": ["contract", "runtime"], "kinds": ["contract", "runtime"],
            "nodes": [
                {"id": "alpha", "stage": "S0-base", "area": "core", "layer": "contract",
                 "kind": "contract", "dependsOn": [], "requiredCompletion": "x"},
                {"id": "beta", "stage": "S1-next", "area": "core", "layer": "runtime",
                 "kind": "runtime", "dependsOn": ["alpha"], "requiredCompletion": "y"},
            ],
        }))

    def test_full_view(self) -> None:
        repo = self._repo()
        self._write_dag(repo)
        (repo / "docs/orchestration/gates/alpha.gate-result.json").write_text(json.dumps(
            {"node": "alpha", "status": "passed", "authoritative": True,
             "evidenceClass": "deterministic-proof", "recordedAt": "2026-07-11T00:00:00Z"}))
        # TASK-0001 attributed via events; TASK-0002 via the DAG node: header.
        (repo / "docs/orchestration/tasks/TASK-0001.md").write_text(
            "# TASK-0001: first\n\nStatus: integrated\nArea: core\n")
        (repo / "docs/orchestration/tasks/TASK-0002.md").write_text(
            "# TASK-0002: second\n\nStatus: ready\nArea: core\nDAG node: beta\n")
        (repo / ".singular-state/leases/TASK-0001.json").write_text(json.dumps(
            {"taskId": "TASK-0001", "area": "core", "status": "integrated"}))
        (repo / ".singular-state/events.ndjson").write_text(json.dumps(
            {"ts": "2026-07-10T00:00:00Z", "type": "planner.staged",
             "data": {"taskId": "TASK-0001", "node": "alpha", "area": "core"}}) + "\n")
        (repo / ".singular-state/l1-leases/beta.json").write_text(json.dumps(
            {"node": "beta", "status": "planning", "updatedAt": "2026-07-10T01:00:00Z"}))

        view = srv.collect_dag_view(repo)
        self.assertEqual(view["schema"], "singular.codex.dag.v0")
        self.assertTrue(view["validate"]["ok"])
        self.assertEqual(view["edges"], [{"from": "alpha", "to": "beta"}])
        by_id = {n["id"]: n for n in view["nodes"]}
        self.assertEqual(by_id["alpha"]["gate"]["status"], "passed")
        self.assertEqual(by_id["alpha"]["gate"]["evidenceClass"], "deterministic-proof")
        self.assertEqual(by_id["alpha"]["tasks"]["taskIds"], ["TASK-0001"])
        self.assertEqual(by_id["alpha"]["tasks"]["counts"]["integrated"], 1)
        self.assertEqual(by_id["beta"]["gate"]["status"], "absent")
        self.assertEqual(by_id["beta"]["tasks"]["taskIds"], ["TASK-0002"])
        self.assertEqual(by_id["beta"]["tasks"]["counts"]["ready"], 1)
        self.assertTrue(by_id["beta"]["frontier"])   # alpha passed -> beta on frontier
        self.assertFalse(by_id["alpha"]["frontier"])
        self.assertEqual(by_id["beta"]["l1Lease"]["status"], "planning")
        self.assertTrue(by_id["beta"]["l1Lease"]["active"])
        stages = {s["id"]: s for s in view["stages"]}
        self.assertEqual(stages["S0-base"]["status"], "complete")
        self.assertEqual(stages["S1-next"]["passed"], 0)
        self.assertEqual(view["areas"][0]["id"], "core")
        self.assertEqual(view["areas"][0]["taskCounts"]["total"], 2)
        self.assertEqual(view["layers"], ["contract", "runtime"])

    def test_empty_repo(self) -> None:
        repo = self._repo()
        view = srv.collect_dag_view(repo)
        self.assertEqual(view["nodes"], [])
        self.assertEqual(view["edges"], [])
        self.assertEqual(view["stages"], [])
        self.assertEqual(view["areas"], [])
        self.assertFalse(view["validate"]["ok"])

    def test_node_id_re_accepts_slugs(self) -> None:
        for nid in ("ctx-loader", "D1.contract", "planner-store", "s7.eval-x"):
            self.assertTrue(srv.NODE_ID_RE.match(nid), nid)
        for bad in ("", "-lead", "a/b", "a b"):
            self.assertFalse(srv.NODE_ID_RE.match(bad), bad)

    def _write_wave_dag(self, repo: Path) -> None:
        """root, then a three-node wave: two nodes sharing the `mcp` area and one
        in `cli`. The audit's "ready 3, runnable 2" shape in miniature."""
        def node(nid: str, area: str, stage: str, deps: list[str]) -> dict:
            return {"id": nid, "stage": stage, "area": area, "layer": "service",
                    "kind": "runtime", "dependsOn": deps, "requiredCompletion": "x"}

        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({
            "schema": "singular.orchestration.dag.v0",
            "nodes": [node("root", "core", "S0", []),
                      node("mcp-a", "mcp", "S1", ["root"]),
                      node("mcp-b", "mcp", "S1", ["root"]),
                      node("cli-a", "cli", "S2", ["root"])]}))

    def test_ranks_cohort_lease_and_l1_selection(self) -> None:
        repo = self._repo()
        self._write_wave_dag(repo)
        (repo / "singular.config.json").write_text(json.dumps(
            {"env": {"SINGULAR_ENABLE_L1_PARALLEL": "1", "SINGULAR_MAX_L1_CONCURRENT": "3"}}))
        srv.initialize_configuration(repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        # root is historical evidence: authoritative, passed, grandfathered.
        (repo / "docs/orchestration/gates/root.gate-result.json").write_text(json.dumps(
            {"node": "root", "status": "passed", "authoritative": True,
             "evidenceClass": "grandfathered", "recordedAt": "2026-06-25T22:53:13Z"}))
        # A RELEASED lease is history, not an active planner: it must pass its
        # area/scopes through to the UI without influencing selection.
        (repo / ".singular-state/l1-leases/mcp-b.json").write_text(json.dumps(
            {"node": "mcp-b", "area": "mcp", "status": "released",
             "allowedWriteScopes": ["internal/mcp/"], "updatedAt": "2026-07-10T01:00:00Z"}))

        view = srv.collect_dag_view(repo)
        by_id = {n["id"]: n for n in view["nodes"]}
        # rank: longest path over dependsOn, not stage position
        self.assertEqual({n["id"]: n["rank"] for n in view["nodes"]},
                         {"root": 0, "mcp-a": 1, "mcp-b": 1, "cli-a": 1})
        # provenance rides on the gate projection
        self.assertEqual(by_id["root"]["gate"]["cohort"], "historical")
        self.assertNotIn("cohort", by_id["mcp-a"]["gate"])  # absent gate, no cohort
        # lease passthrough
        self.assertEqual(by_id["mcp-b"]["l1Lease"]["area"], "mcp")
        self.assertEqual(by_id["mcp-b"]["l1Lease"]["allowedWriteScopes"], ["internal/mcp/"])
        self.assertFalse(by_id["mcp-b"]["l1Lease"]["active"])
        # ready by dependency: all three; runnable: one per area
        self.assertEqual(sorted(n["id"] for n in view["nodes"] if n["frontier"]),
                         ["cli-a", "mcp-a", "mcp-b"])
        self.assertTrue(by_id["mcp-a"]["runnable"])
        self.assertTrue(by_id["cli-a"]["runnable"])
        self.assertFalse(by_id["mcp-b"]["runnable"])
        self.assertEqual(by_id["mcp-b"]["exclusion"]["rule"], "batch-area")
        self.assertIn("mcp area already selected (mcp-a)", by_id["mcp-b"]["exclusion"]["detail"])
        # a passed node is not on the frontier and carries no runnable verdict
        self.assertNotIn("runnable", by_id["root"])
        selection = view["l1Selection"]
        self.assertTrue(selection["enabled"])
        self.assertEqual(selection["cap"], 3)
        self.assertEqual(selection["readyByDependency"], 3)
        self.assertEqual(selection["runnableNow"], 2)
        self.assertEqual(selection["serialized"],
                         [{"node": "mcp-b", "area": "mcp", "rule": "batch-area",
                           "detail": "mcp area already selected (mcp-a)"}])
        self.assertEqual(selection["policy"],
                         ["node-lease", "area-lease", "scope-overlap", "cap"])
        # the plan header must tell the identical story
        self.assertEqual(srv.collect_overview(repo)["l1Selection"], selection)

    def test_l1_parallel_disabled_caps_at_one(self) -> None:
        repo = self._repo()
        self._write_wave_dag(repo)
        (repo / "docs/orchestration/gates/root.gate-result.json").write_text(json.dumps(
            {"node": "root", "status": "passed", "authoritative": True}))
        view = srv.collect_dag_view(repo)
        self.assertEqual(view["l1Selection"]["enabled"], False)
        self.assertEqual(view["l1Selection"]["cap"], 1)
        self.assertEqual(view["l1Selection"]["runnableNow"], 1)
        rules = {e["node"]: e["rule"] for e in view["l1Selection"]["serialized"]}
        self.assertEqual(rules, {"mcp-b": "batch-area", "cli-a": "cap"})

    def test_human_gate_projection(self) -> None:
        repo = self._repo()
        (repo / "docs/orchestration/human-gates").mkdir(parents=True)
        request_ref = "docs/orchestration/human-gates/G100.human-gate.json"
        (repo / request_ref).write_text(json.dumps({
            "schema": "singular.orchestration.human-gate.v0",
            "gateId": "G100", "node": "gate-node", "approvalType": "exact-artifact",
            "requiredOwner": "owner@example.com",
            "questions": [{"id": "risk", "prompt": "Accept?", "required": True}],
            "artifacts": [], "createdAt": "2026-07-24T10:00:00Z",
            "expiresAt": "2099-07-25T10:00:00Z"}))
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({
            "schema": "singular.orchestration.dag.v0",
            "nodes": [
                {"id": "gate-node", "stage": "S0", "area": "core", "layer": "contract",
                 "kind": "contract", "dependsOn": [], "requiredCompletion": "x",
                 "humanGate": {"requestRef": request_ref,
                               "approvalRef": "docs/orchestration/human-gates/G100.approval.json"}},
                {"id": "downstream", "stage": "S1", "area": "core", "layer": "service",
                 "kind": "runtime", "dependsOn": ["gate-node"], "requiredCompletion": "x"},
            ]}))
        view = srv.collect_dag_view(repo)
        by_id = {n["id"]: n for n in view["nodes"]}
        # no approval document exists, so the gate is anything but approved
        self.assertNotEqual(by_id["gate-node"]["humanGate"]["state"], "approved")
        self.assertEqual(by_id["gate-node"]["humanGate"]["gateId"], "G100")
        self.assertIn("reason", by_id["gate-node"]["humanGate"])
        # the descendant is blocked BY the gate node, and says which one
        self.assertEqual(by_id["downstream"]["humanGateBlockedBy"], ["gate-node"])
        self.assertNotIn("humanGateBlockedBy", by_id["gate-node"])
        self.assertNotIn("humanGate", by_id["downstream"])


class NativeL1SelectionTests(unittest.TestCase):
    """AXON-002: compute_l1_selection_native must reproduce engine/lib.sh
    `singular_select_l1_frontier` — same selection, plus the per-node reason the
    engine computes and discards."""

    def _entry(self, node: str, area: str) -> dict:
        return {"node": node, "area": area, "stage": "S1", "layer": "service",
                "kind": "runtime", "requiredCompletion": "x"}

    def _lease(self, node: str, area: str, status: str = "active",
               scopes: list[str] | None = None) -> dict:
        return {"node": node, "area": area, "status": status,
                "allowedWriteScopes": scopes if scopes is not None else [f"internal/{area}/"]}

    def _scopes(self, *areas: str) -> dict:
        return {area: [f"internal/{area}/"] for area in areas}

    def test_audit_wave_serializes_the_second_mcp_node(self) -> None:
        # The reported wave: theoretical width 4, practical width 3.
        frontier = [self._entry("B120", "mcp"), self._entry("B130", "mcp"),
                    self._entry("B160", "cli"), self._entry("C100", "platform")]
        out = srv.compute_l1_selection_native(
            frontier, [], self._scopes("mcp", "cli", "platform"), 3, True)
        self.assertEqual(out["selected"], ["B120", "B160", "C100"])
        self.assertEqual(list(out["exclusions"]), ["B130"])
        self.assertEqual(out["exclusions"]["B130"],
                         {"rule": "batch-area", "detail": "mcp area already selected (B120)"})

    def test_node_already_leased(self) -> None:
        frontier = [self._entry("B120", "mcp"), self._entry("B160", "cli")]
        out = srv.compute_l1_selection_native(
            frontier, [self._lease("B120", "mcp")], self._scopes("mcp", "cli"), 3, True)
        self.assertEqual(out["selected"], ["B160"])
        self.assertEqual(out["exclusions"]["B120"]["rule"], "node-lease")
        self.assertIn("B120", out["exclusions"]["B120"]["detail"])

    def test_area_already_leased_by_another_node(self) -> None:
        frontier = [self._entry("B130", "mcp"), self._entry("B160", "cli")]
        out = srv.compute_l1_selection_native(
            frontier, [self._lease("B120", "mcp")], self._scopes("mcp", "cli"), 3, True)
        self.assertEqual(out["selected"], ["B160"])
        self.assertEqual(out["exclusions"]["B130"]["rule"], "area-lease")
        self.assertIn("B120", out["exclusions"]["B130"]["detail"])

    def test_released_lease_frees_the_area(self) -> None:
        frontier = [self._entry("B130", "mcp")]
        out = srv.compute_l1_selection_native(
            frontier, [self._lease("B120", "mcp", status="released")],
            self._scopes("mcp"), 3, True)
        self.assertEqual(out["selected"], ["B130"])
        self.assertEqual(out["exclusions"], {})

    def test_scope_overlap_with_an_active_lease_in_another_area(self) -> None:
        # Distinct areas whose configured write scopes nest: the overlap guard,
        # not the area guard, is what serializes them.
        frontier = [self._entry("B160", "cli")]
        leases = [self._lease("B120", "mcp", scopes=["internal/shared/"])]
        out = srv.compute_l1_selection_native(
            frontier, leases, {"cli": ["internal/shared/cli/"]}, 3, True)
        self.assertEqual(out["selected"], [])
        self.assertEqual(out["exclusions"]["B160"]["rule"], "scope-overlap-active")
        self.assertIn("internal/shared", out["exclusions"]["B160"]["detail"])
        self.assertIn("B120", out["exclusions"]["B160"]["detail"])

    def test_scope_overlap_within_one_batch(self) -> None:
        frontier = [self._entry("B120", "mcp"), self._entry("B160", "cli")]
        scopes = {"mcp": ["internal/shared/"], "cli": ["internal/shared/cli/"]}
        out = srv.compute_l1_selection_native(frontier, [], scopes, 3, True)
        self.assertEqual(out["selected"], ["B120"])
        self.assertEqual(out["exclusions"]["B160"]["rule"], "scope-overlap-batch")
        self.assertIn("B120", out["exclusions"]["B160"]["detail"])

    def test_unmapped_area_falls_back_to_the_engine_default_prefix(self) -> None:
        # No entry in the scope map: internal/<area>/, exactly like the engine.
        frontier = [self._entry("B120", "mcp"), self._entry("B160", "cli")]
        leases = [self._lease("B999", "other", scopes=["internal/mcp/"])]
        out = srv.compute_l1_selection_native(frontier, leases, {}, 3, True)
        self.assertEqual(out["selected"], ["B160"])
        self.assertEqual(out["exclusions"]["B120"]["rule"], "scope-overlap-active")

    def test_cap_cuts_the_batch_off(self) -> None:
        frontier = [self._entry("B120", "mcp"), self._entry("B160", "cli"),
                    self._entry("C100", "platform")]
        out = srv.compute_l1_selection_native(
            frontier, [], self._scopes("mcp", "cli", "platform"), 2, True)
        self.assertEqual(out["selected"], ["B120", "B160"])
        self.assertEqual(out["exclusions"]["C100"],
                         {"rule": "cap", "detail": "concurrency cap 2 reached"})

    def test_intrinsic_rule_is_reported_ahead_of_the_cap(self) -> None:
        # B130 would still be serialized if the cap were raised; say so.
        frontier = [self._entry("B120", "mcp"), self._entry("B130", "mcp")]
        out = srv.compute_l1_selection_native(frontier, [], self._scopes("mcp"), 1, True)
        self.assertEqual(out["selected"], ["B120"])
        self.assertEqual(out["exclusions"]["B130"]["rule"], "batch-area")

    def test_fanout_disabled_forces_a_single_node(self) -> None:
        frontier = [self._entry("B120", "mcp"), self._entry("B160", "cli")]
        out = srv.compute_l1_selection_native(
            frontier, [], self._scopes("mcp", "cli"), 3, False)
        self.assertEqual(out["selected"], ["B120"])
        self.assertEqual(out["exclusions"]["B160"]["rule"], "cap")


class L1SelectionConfigTests(unittest.TestCase):
    """The knobs behind the replica, resolved from repo files the way the engine
    resolves them (never from the console's own process environment)."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state").mkdir()
        return repo

    def test_limits_default_to_disabled_cap_one(self) -> None:
        self.assertEqual(srv._l1_selection_limits(self._repo()), (False, 1))

    def test_limits_from_config_env(self) -> None:
        repo = self._repo()
        (repo / "singular.config.json").write_text(json.dumps(
            {"env": {"SINGULAR_ENABLE_L1_PARALLEL": "1", "SINGULAR_MAX_L1_CONCURRENT": "4"}}))
        srv.initialize_configuration(repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        self.assertEqual(srv._l1_selection_limits(repo), (True, 4))

    def test_enabled_default_cap_is_three_and_junk_floors_to_one(self) -> None:
        repo = self._repo()
        (repo / "singular.config.json").write_text(json.dumps(
            {"env": {"SINGULAR_ENABLE_L1_PARALLEL": "1"}}))
        srv.initialize_configuration(repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        self.assertEqual(srv._l1_selection_limits(repo), (True, 3))
        (repo / "singular.config.json").write_text(json.dumps(
            {"env": {"SINGULAR_ENABLE_L1_PARALLEL": "1", "SINGULAR_MAX_L1_CONCURRENT": "0"}}))
        srv.initialize_configuration(repo, force=True)
        self.assertEqual(srv._l1_selection_limits(repo), (True, 1))

    def test_state_env_file_does_not_override_runtime_config(self) -> None:
        repo = self._repo()
        (repo / "singular.config.json").write_text(json.dumps(
            {"env": {"SINGULAR_ENABLE_L1_PARALLEL": "0", "SINGULAR_MAX_L1_CONCURRENT": "2"}}))
        (repo / ".singular-state/.env").write_text(
            "SINGULAR_ENABLE_L1_PARALLEL=1\nSINGULAR_MAX_L1_CONCURRENT=5\nDATABASE_URL=secret\n")
        srv.initialize_configuration(repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        self.assertEqual(srv._l1_selection_limits(repo), (False, 1))

    def test_area_scopes_from_structured_config_and_prefix(self) -> None:
        repo = self._repo()
        (repo / "singular.config.json").write_text(json.dumps(
            {"areaPrefix": "src/", "areas": {"mcp": ["internal/mcp/", "cmd/mcp/"],
                                             "cli": "internal/cli/"}}))
        srv.initialize_configuration(repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        self.assertEqual(srv._l1_area_scopes(repo, ["mcp", "cli", "unmapped"]), {
            "mcp": ["internal/mcp/", "cmd/mcp/"],
            "cli": ["internal/cli/"],
            "unmapped": ["src/unmapped/"]})

    def test_area_scopes_default_prefix_when_unconfigured(self) -> None:
        self.assertEqual(srv._l1_area_scopes(self._repo(), ["mcp"]), {"mcp": ["internal/mcp/"]})


class StopReasonTests(unittest.TestCase):
    """PMGO-003: a stopped loop must say WHY, and name the next action when one
    exists."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / "docs/orchestration/gates").mkdir(parents=True)
        (repo / ".singular-state").mkdir()
        return repo

    def _gated_dag(self, repo: Path) -> None:
        (repo / "docs/orchestration/human-gates").mkdir(parents=True, exist_ok=True)
        request_ref = "docs/orchestration/human-gates/G100.human-gate.json"
        (repo / request_ref).write_text(json.dumps({
            "schema": "singular.orchestration.human-gate.v0",
            "gateId": "G100", "node": "G100", "approvalType": "exact-artifact",
            "requiredOwner": "owner@example.com",
            "questions": [{"id": "risk", "prompt": "Accept?", "required": True}],
            "artifacts": [], "createdAt": "2026-07-24T10:00:00Z",
            "expiresAt": "2099-07-25T10:00:00Z"}))
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({
            "schema": "singular.orchestration.dag.v0",
            "nodes": [
                {"id": "G100", "stage": "S0", "area": "core", "layer": "contract",
                 "kind": "contract", "dependsOn": [], "requiredCompletion": "x",
                 "humanGate": {"requestRef": request_ref,
                               "approvalRef": "docs/orchestration/human-gates/G100.approval.json"}},
                {"id": "B100", "stage": "S1", "area": "core", "layer": "service",
                 "kind": "runtime", "dependsOn": ["G100"], "requiredCompletion": "x"},
            ]}))

    def test_no_stop_no_reason(self) -> None:
        repo = self._repo()
        self._gated_dag(repo)
        self.assertIsNone(srv.derive_stop_reason(repo, {"stopPresent": False}))

    def test_pending_human_gate_on_a_ready_node_names_the_node(self) -> None:
        repo = self._repo()
        self._gated_dag(repo)
        self.assertEqual(srv.derive_stop_reason(repo, {"stopPresent": True}),
                         "operator approval required for G100")

    def test_stop_alone_falls_back_to_the_sentinel(self) -> None:
        repo = self._repo()
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps(
            {"schema": "singular.orchestration.dag.v0",
             "nodes": [{"id": "B100", "stage": "S0", "area": "core", "layer": "service",
                        "kind": "runtime", "dependsOn": [], "requiredCompletion": "x"}]}))
        self.assertEqual(srv.derive_stop_reason(repo, {"stopPresent": True}),
                         "STOP sentinel present")

    def test_status_note_explaining_a_halt_wins_over_the_sentinel(self) -> None:
        repo = self._repo()
        self.assertEqual(
            srv.derive_stop_reason(repo, {"stopPresent": True,
                                          "note": "stopped (budget exhausted)"}),
            "stopped (budget exhausted)")
        # a note that does not explain a stop is not a stop reason
        self.assertEqual(
            srv.derive_stop_reason(repo, {"stopPresent": True, "note": "iteration 6 done"}),
            "STOP sentinel present")

    def test_overview_publishes_the_stop_reason(self) -> None:
        repo = self._repo()
        self._gated_dag(repo)
        overview = srv.collect_overview(repo)
        self.assertIsNone(overview["loop"]["stopReason"])  # no sentinel yet
        (repo / ".singular-state/STOP").write_text("")
        srv._OVERVIEW_CACHE.invalidate()
        overview = srv.collect_overview(repo)
        self.assertTrue(overview["loop"]["stopPresent"])
        self.assertEqual(overview["loop"]["stopReason"],
                         "operator approval required for G100")


def _tev(ts: str, etype: str, **data: object) -> dict:
    return {"ts": ts, "type": etype, "data": data}


class BuildTaskIntervalsTests(unittest.TestCase):
    """Pure interval reconstruction: events open/close attempts; the dispatch
    record only reconciles the latest one (records are overwritten per attempt)."""

    def test_two_attempts_last_open_then_dispatch_close(self) -> None:
        events = [
            _tev("2026-07-10T10:00:00Z", "l1.dispatch_started", taskId="TASK-1", runId="RUN-a"),
            _tev("2026-07-10T10:20:00Z", "origin.dispatch_reaped", taskId="TASK-1", exitCode=1, outcome="failed"),
            _tev("2026-07-10T11:00:00Z", "l1.dispatch_started", taskId="TASK-1", runId="RUN-b"),
        ]
        rec = {"state": "reaped", "reapedAt": "2026-07-10T11:30:00Z", "exitCode": 0, "outcome": "ok"}
        intervals, live = srv.build_task_intervals(events, rec, None)
        self.assertFalse(live)
        self.assertEqual(len(intervals), 2)
        self.assertEqual((intervals[0]["kind"], intervals[0]["endedAt"], intervals[0]["outcome"]),
                         ("dispatch", "2026-07-10T10:20:00Z", "failed"))
        self.assertEqual((intervals[1]["kind"], intervals[1]["endedAt"], intervals[1]["source"]),
                         ("retry", "2026-07-10T11:30:00Z", "dispatch"))
        self.assertEqual(intervals[1]["outcome"], "ok")

    def test_launched_dispatch_is_live(self) -> None:
        events = [_tev("2026-07-10T10:00:00Z", "l1.dispatch_started", taskId="TASK-1", runId="RUN-a")]
        intervals, live = srv.build_task_intervals(events, {"state": "launched"}, None)
        self.assertTrue(live)
        self.assertIsNone(intervals[0]["endedAt"])

    def test_soft_close_via_task_events(self) -> None:
        events = [
            _tev("2026-07-10T10:00:00Z", "l1.dispatch_started", taskId="TASK-1", runId="RUN-a"),
            _tev("2026-07-10T10:40:00Z", "l1.task_accepted", taskId="TASK-1", runId="RUN-a"),
        ]
        intervals, live = srv.build_task_intervals(events, None, None)
        self.assertFalse(live)
        self.assertEqual(intervals[0]["endedAt"], "2026-07-10T10:40:00Z")

    def test_window_fallbacks(self) -> None:
        # No events at all: dispatch record, then lease timestamps.
        rec = {"state": "reaped", "startedAt": "2026-07-10T09:00:00Z",
               "reapedAt": "2026-07-10T09:30:00Z", "outcome": "ok", "exitCode": 0}
        intervals, live = srv.build_task_intervals([], rec, None)
        self.assertEqual((intervals[0]["source"], intervals[0]["endedAt"]), ("dispatch", "2026-07-10T09:30:00Z"))
        intervals, live = srv.build_task_intervals([], None,
            {"createdAt": "2026-07-10T09:00:00Z", "updatedAt": "2026-07-10T09:45:00Z", "runId": "RUN-x"})
        self.assertEqual((intervals[0]["source"], intervals[0]["endedAt"]), ("lease", "2026-07-10T09:45:00Z"))
        intervals, live = srv.build_task_intervals([], None, None)
        self.assertEqual(intervals, [])


class CollectTimelineTests(unittest.TestCase):
    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / "docs/orchestration/tasks").mkdir(parents=True)
        (repo / "docs/orchestration/gates").mkdir(parents=True)
        (repo / ".singular-state/leases").mkdir(parents=True)
        (repo / ".singular-state/dispatch").mkdir(parents=True)
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({
            "nodes": [{"id": "alpha", "stage": "S0", "area": "core", "layer": "x",
                       "kind": "contract", "dependsOn": [], "requiredCompletion": "x"}]}))
        return repo

    def test_timeline_shape(self) -> None:
        repo = self._repo()
        (repo / ".singular-state/events.ndjson").write_text("\n".join([
            json.dumps(_tev("2026-07-10T08:00:00Z", "origin.reconcile_started", runId="ORIGIN-1", mode="apply")),
            json.dumps(_tev("2026-07-10T08:00:05Z", "origin.reconcile_completed", runId="ORIGIN-1", mode="apply")),
            json.dumps(_tev("2026-07-10T09:00:00Z", "planner.staged", taskId="TASK-0001", node="alpha", area="core")),
            json.dumps(_tev("2026-07-10T10:00:00Z", "l1.dispatch_started", taskId="TASK-0001", runId="RUN-a")),
            json.dumps(_tev("2026-07-10T10:30:00Z", "origin.dispatch_reaped", taskId="TASK-0001", exitCode=0, outcome="ok")),
            json.dumps(_tev("2026-07-10T10:35:00Z", "integration.integrated", taskId="TASK-0001",
                            branch="agent/core/TASK-0001", runId="ORIGIN-2")),
            json.dumps(_tev("2026-07-10T11:00:00Z", "origin.reconcile_started", runId="ORIGIN-3", mode="apply")),
        ]) + "\n")
        (repo / ".singular-state/leases/TASK-0001.json").write_text(json.dumps(
            {"taskId": "TASK-0001", "area": "core", "status": "integrated", "retryCount": 0,
             "branch": "agent/core/TASK-0001", "createdAt": "2026-07-10T10:00:00Z",
             "updatedAt": "2026-07-10T10:35:00Z"}))
        (repo / "docs/orchestration/gates/alpha.gate-result.json").write_text(json.dumps(
            {"node": "alpha", "status": "passed", "authoritative": True,
             "evidenceClass": "deterministic-proof", "recordedAt": "2026-07-10T10:40:00Z"}))

        data = srv.collect_timeline(repo)
        self.assertEqual(data["schema"], "singular.codex.timeline.v0")
        self.assertEqual(data["counts"]["tasks"], 1)
        task = data["tasks"][0]
        self.assertEqual(task["node"], "alpha")
        self.assertEqual(task["intervals"][0]["endedAt"], "2026-07-10T10:30:00Z")
        self.assertEqual(task["integratedAt"], "2026-07-10T10:35:00Z")
        self.assertFalse(task["liveNow"])
        self.assertEqual(data["gates"], [{"node": "alpha", "status": "passed",
                                          "recordedAt": "2026-07-10T10:40:00Z",
                                          "evidenceClass": "deterministic-proof"}])
        cycles = data["cycles"]
        self.assertEqual(len(cycles), 2)
        self.assertEqual(cycles[0]["endedAt"], "2026-07-10T08:00:05Z")
        self.assertIsNone(cycles[1]["endedAt"])   # unpaired start stays open
        self.assertFalse(data["window"]["truncated"])

        # ?since= filter drops everything before the cutoff.
        filtered = srv.filter_timeline_since(data, "2026-07-10T10:50:00Z")
        self.assertEqual(filtered["counts"]["tasks"], 0)
        self.assertEqual(len(filtered["cycles"]), 1)   # the still-open cycle survives
        self.assertEqual(filtered["gates"], [])
        filtered = srv.filter_timeline_since(data, "2026-07-10T10:00:00Z")
        self.assertEqual(filtered["counts"]["tasks"], 1)


class SessionEnrichmentTests(unittest.TestCase):
    """0.6.0 sessions: durable session-meta merged into rows; auditor log
    discoverable; ?limit= slice keeps origin."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state/runs").mkdir(parents=True)
        (repo / ".singular-state/leases").mkdir(parents=True)
        return repo

    def test_worker_meta_merge(self) -> None:
        repo = self._repo()
        run = repo / ".singular-state/runs/RUN-x"
        run.mkdir()
        (run / "worker-codex.log").write_text("claude-run: level=l2\n")
        (run / "last-message.json").write_text(json.dumps(
            {"taskId": "TASK-0001", "area": "core", "status": "accepted"}))
        (run / "session-implementer.json").write_text(json.dumps(
            {"provider": "claude", "model": "claude-opus-4-8", "effort": "medium",
             "exitCode": 0, "runner": "claude-run.sh", "lastUsedAttempt": 2}))
        (run / "session-reviewer.json").write_text(json.dumps(
            {"provider": "claude", "model": "claude-opus-4-8", "effort": "xhigh", "exitCode": 0}))
        sessions = srv.discover_sessions(repo)
        worker = next(s for s in sessions if s["id"] == "RUN-x")
        self.assertEqual(worker["model"], "claude-opus-4-8")
        self.assertEqual(worker["effort"], "medium")
        self.assertEqual(worker["exitCode"], 0)
        self.assertEqual(worker["attempt"], 2)
        self.assertEqual(worker["sessionMeta"]["reviewer"]["effort"], "xhigh")

    def test_auditor_log_discoverable(self) -> None:
        repo = self._repo()
        run = repo / ".singular-state/runs/RUN-audit"
        run.mkdir()
        (run / "auditor-codex.log").write_text("{}\n")
        sessions = srv.discover_sessions(repo)
        audit = next(s for s in sessions if s["id"] == "RUN-audit")
        self.assertEqual(audit["kind"], "audit")
        self.assertIn("auditor-codex.log", [f["name"] for f in audit["logFiles"]])

    def test_limit_slice(self) -> None:
        repo = self._repo()
        for i in range(30):
            run = repo / f".singular-state/runs/RUN-{i:03d}"
            run.mkdir()
            (run / "gate-check.log").write_text("x\n")
        data = srv.collect_sessions(repo)
        self.assertGreater(len(data["sessions"]), 16)   # cache holds the hard-max set
        sliced = srv.slice_sessions(data, 16)
        self.assertEqual(len(sliced["sessions"]), 16)
        self.assertEqual(sliced["sessions"][-1]["id"], "origin")
        sliced24 = srv.slice_sessions(data, 24)
        self.assertEqual(len(sliced24["sessions"]), 24)
        self.assertEqual(srv.slice_sessions(data, 9999)["sessions"],
                         data["sessions"])  # clamped to hard max (31 here < 40)


class ConfigEndpointTests(unittest.TestCase):
    """/api/config reflects lib.sh's environment < JSON < shell < local order."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state").mkdir()
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        return repo

    def test_precedence(self) -> None:
        repo = self._repo()
        (repo / "singular.config.json").write_text(json.dumps({
            "runner": "claude-run.sh",
            "env": {"SINGULAR_CLAUDE_MODEL": "claude-opus-4-8",
                    "SINGULAR_CLAUDE_PLANNER_EFFORT": "high",
                    "SINGULAR_MAX_CONCURRENT": "3"}}))
        (repo / ".singular-state/.env").write_text(
            "SINGULAR_CLAUDE_PLANNER_EFFORT=xhigh\nDATABASE_URL=secret://never\n")
        (repo / "singular.config.sh").write_text(
            'export SINGULAR_CLAUDE_PLANNER_EFFORT=xhigh\n'
            'export SINGULAR_LOCAL_CONFIG_FILE="$SINGULAR_ROOT/operator/local.sh"\n')
        (repo / "operator").mkdir()
        (repo / "operator/local.sh").write_text(
            'export SINGULAR_CLAUDE_PLANNER_EFFORT=max\n')
        with mock.patch.dict(os.environ, {
                "SINGULAR_CLAUDE_PLANNER_EFFORT": "medium"}, clear=False):
            srv.initialize_configuration(repo, force=True)
            cfg = srv.collect_config(repo)
        self.assertEqual(cfg["provider"], "claude")
        self.assertEqual(cfg["roles"]["planner"]["model"], "claude-opus-4-8")   # config fallback key
        self.assertEqual(cfg["roles"]["planner"]["effort"], "max")              # local wins
        self.assertEqual(cfg["roles"]["planner"]["source"]["effortTier"], "effective")
        self.assertEqual(cfg["roles"]["implementer"]["effort"], "medium")       # runner default
        self.assertEqual(cfg["roles"]["implementer"]["source"]["effortTier"], "runner-default")
        self.assertEqual(cfg["limits"]["maxConcurrent"], "3")
        self.assertNotIn("secret", json.dumps(cfg))

    def test_codex_defaults(self) -> None:
        repo = self._repo()
        (repo / "singular.config.json").write_text(json.dumps({"runner": "codex-run.sh", "env": {}}))
        srv.initialize_configuration(repo, force=True)
        cfg = srv.collect_config(repo)
        self.assertEqual(cfg["provider"], "codex")
        self.assertEqual(cfg["roles"]["implementer"]["model"], "gpt-5.5")
        self.assertEqual(cfg["roles"]["auditor"]["effort"], "high")

    def test_empty_repo(self) -> None:
        repo = self._repo()
        srv.initialize_configuration(repo, force=True)
        cfg = srv.collect_config(repo)
        self.assertEqual(cfg["provider"], "codex")   # engine default runner
        self.assertEqual(cfg["configuration"]["status"], "absent")
        self.assertIsNone(cfg["limits"]["maxConcurrent"])


class NewCollectorsNoSubprocessTests(unittest.TestCase):
    """The 0.6.0 collectors must stay pure-filesystem (mirror of
    SnapshotNoSubprocessTests for dag/timeline/config)."""

    def test_no_subprocess(self) -> None:
        calls: list = []
        real_run = subprocess.run

        def record(*args, **kwargs):
            calls.append(args)
            return real_run(*args, **kwargs)

        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / ".singular-state").mkdir()
            (repo / "docs/orchestration/tasks").mkdir(parents=True)
            srv.initialize_configuration(repo, force=True)
            self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
            saved = subprocess.run
            subprocess.run = record
            try:
                srv.collect_dag_view(repo)
                srv.collect_timeline(repo)
                srv.collect_config(repo)
                # 0.7.0 read collectors (the W1 settings WRITE fn is excluded)
                srv.collect_home(repo)
                srv.collect_prompts(repo)
                srv.collect_prompt(repo, "auditor.md")
                srv.collect_raw(repo, "config", "singular.config.json")
                srv.collect_settings_view(repo)
                # 0.8.0 plan-threads registry read (pure-FS).
                srv.collect_plans(repo)
                # 0.10.0 supervisor ask read collectors (pure-FS).
                srv.collect_ask(repo, "ASK-does-not-exist")
                srv.collect_asks(repo)
                # Advancing beyond both superseded TTLs cannot replay lib.sh.
                with mock.patch.object(srv.time, "monotonic", return_value=time.monotonic() + 31):
                    srv.collect_config(repo)
                    srv.collect_home(repo)
                # Concurrent readers share the same initialized generation.
                with ThreadPoolExecutor(max_workers=8) as pool:
                    list(pool.map(lambda _n: srv.collect_config(repo), range(32)))
                # An unsupported root reports uninitialized without resolving.
                other = Path(tmp) / "archive"
                other.mkdir()
                self.assertEqual(
                    srv.collect_config(other)["configuration"]["reason"],
                    "configuration-not-initialized",
                )
            finally:
                subprocess.run = saved
        self.assertEqual(calls, [])


class ConfigurationSnapshotContractTests(unittest.TestCase):
    """Trusted initialization, immutable generations, and explicit invalidation."""

    def setUp(self) -> None:
        srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate()
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)

    def _repo(self, config: dict | None = None) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        if config is not None:
            (repo / "singular.config.json").write_text(json.dumps(config))
        return repo

    def test_absent_json_keeps_shell_and_post_shell_local_paths(self) -> None:
        repo = self._repo()
        state = repo / "state with spaces"
        state.mkdir()
        tasks = repo / "tasks from local"
        runner = repo / "bin" / "custom-run.sh"
        runner.parent.mkdir()
        runner.write_text("#!/bin/sh\nexit 0\n")
        runner.chmod(0o755)
        (repo / "singular.config.sh").write_text(
            "export SINGULAR_STATE_DIR='state with spaces'\n"
            "export SINGULAR_RUNNER='bin/custom-run.sh'\n")
        (state / "config.local.sh").write_text(
            "export SINGULAR_TASKS_DIR='tasks from local'\n")

        view = srv.initialize_configuration(repo, force=True)
        self.assertEqual(view["configuration"]["status"], "absent")
        self.assertEqual(Path(view["configurationLayers"]["local"]),
                         (state / "config.local.sh").resolve())
        self.assertEqual(srv.state_path(repo), state.resolve())
        self.assertEqual(srv.tasks_path(repo), tasks.resolve())
        self.assertEqual(view["runner"], str(runner.resolve()))
        self.assertEqual(view["provider"], "unknown")

    def test_meaningful_empty_and_secret_never_serialize(self) -> None:
        repo = self._repo({"runner": "codex-run.sh", "env": {
            "SINGULAR_CODEX_SERVICE_TIER": "priority"}})
        (repo / "singular.config.sh").write_text(
            "export SINGULAR_CODEX_SERVICE_TIER=''\n"
            "export SINGULAR_PRIVATE_TOKEN='do-not-serialize-this'\n")
        srv.initialize_configuration(repo, force=True)
        cfg = srv.collect_config(repo)
        self.assertEqual(cfg["roles"]["planner"]["requestedServiceTier"], "default")
        self.assertEqual(cfg["roles"]["planner"]["source"]["serviceTier"],
                         "explicit-clear")
        self.assertNotIn("do-not-serialize-this", json.dumps(cfg))

    def test_changed_file_exposes_restart_required_in_every_projection(self) -> None:
        repo = self._repo({"runner": "codex-run.sh", "env": {}})
        srv.initialize_configuration(repo, force=True)
        (repo / "singular.config.json").write_text(
            json.dumps({"runner": "gemini-run.sh", "env": {}}))
        cfg = srv.collect_config(repo)
        self.assertFalse(cfg["ok"])
        self.assertEqual(cfg["configuration"]["reason"], "configuration-changed")
        self.assertTrue(cfg["configuration"]["restartRequired"])
        lifecycle = srv.collect_lifecycle_view(repo)
        self.assertEqual(lifecycle["configuration"]["reason"], "configuration-changed")
        with self.assertRaises(srv.ConfigurationUnavailable):
            srv.state_path(repo)

    def test_environment_and_runner_identity_are_bound(self) -> None:
        runner = None
        repo = self._repo()
        runner = repo / "custom-run.sh"
        runner.write_text("#!/bin/sh\nexit 0\n")
        runner.chmod(0o755)
        (repo / "singular.config.json").write_text(json.dumps({
            "runner": str(runner), "env": {}}))
        srv.initialize_configuration(repo, force=True)
        runner.write_text("#!/bin/sh\nexit 1\n")
        changed = srv.collect_config(repo)["configuration"]
        self.assertIn("runner", [item["label"] for item in changed["changedInputs"]])
        srv.initialize_configuration(repo, force=True)
        with mock.patch.dict(os.environ, {"SINGULAR_TEST_SELECTOR": "changed"}):
            changed = srv.collect_config(repo)["configuration"]
            self.assertIn("environment", [item["label"] for item in changed["changedInputs"]])

    def test_custom_same_basename_never_implies_shipped_provider(self) -> None:
        repo = self._repo()
        custom = repo / "custom" / "codex-run.sh"
        custom.parent.mkdir()
        custom.write_text("#!/bin/sh\nexit 0\n")
        custom.chmod(0o755)
        (repo / "singular.config.json").write_text(json.dumps({
            "runner": str(custom), "env": {}}))
        view = srv.initialize_configuration(repo, force=True)
        self.assertEqual(view["provider"], "unknown")
        providers = srv.collect_providers(
            repo, env={"PATH": "", "HOME": str(repo)}, home=repo)
        self.assertEqual(providers["activeProvider"], "unknown")
        self.assertFalse(any(row["isDefaultRunner"] for row in providers["providers"]))

    def test_missing_bootstrap_preserves_selector_and_unknown_identity(self) -> None:
        repo = self._repo()
        selector = repo / "selected.json"
        selector.write_text(json.dumps({"runner": "gemini-run.sh", "env": {}}))
        missing_bash = repo / "missing-bash"
        with mock.patch.dict(os.environ, {
                "SINGULAR_JSON_CONFIG_FILE": str(selector),
                "SINGULAR_BASH_BIN": str(missing_bash)}):
            view = srv.initialize_configuration(repo, force=True)
            self.assertEqual(view["configuration"]["path"], str(selector.resolve()))
            self.assertEqual(view["configuration"]["source"], "selector")
            self.assertEqual(view["provider"], "unknown")
            providers = srv.collect_providers(
                repo, env={"PATH": "", "HOME": str(repo)}, home=repo)
            self.assertEqual(providers["activeProvider"], "unknown")
            self.assertIsNone(providers["activeRunner"])
            self.assertFalse(any(row["isDefaultRunner"] for row in providers["providers"]))
            self.assertTrue(all(row["status"] == "unknown"
                                for row in providers["providers"]))

    def test_complete_collection_pins_one_generation(self) -> None:
        repo = self._repo({"runner": "codex-run.sh", "env": {}})
        initial = srv.initialize_configuration(repo, force=True)
        with srv._EFFECTIVE_CONFIGURATION_CACHE.pin(repo):
            (repo / "singular.config.json").write_text(
                json.dumps({"runner": "gemini-run.sh", "env": {}}))
            first = srv.collect_config(repo)
            second = srv.collect_config(repo)
            self.assertEqual(first["generation"]["id"], initial["generation"]["id"])
            self.assertEqual(second["generation"]["status"], "current")
            self.assertEqual(first["provider"], "codex")
        self.assertEqual(srv.collect_config(repo)["configuration"]["reason"],
                         "configuration-changed")

    def test_settings_refreshes_exactly_once_and_updates_target_branch(self) -> None:
        repo = self._repo({"targetBranch": "branch-a", "runner": "codex-run.sh",
                           "env": {}})
        srv.initialize_configuration(repo, force=True)
        calls = 0
        original = srv._compute_effective_configuration

        def counted(root):
            nonlocal calls
            calls += 1
            return original(root)

        with mock.patch.object(srv, "_compute_effective_configuration", counted):
            status, response = srv.apply_settings_changes(
                repo, {"SINGULAR_RUNNER": "gemini-run.sh",
                       "SINGULAR_TARGET_BRANCH": "branch-b"})
            self.assertEqual(status, 200)
            self.assertEqual(response["config"]["provider"], "gemini")
            srv.collect_config(repo)
            srv.collect_lifecycle_view(repo)
        self.assertEqual(calls, 1)
        self.assertEqual(srv.TARGET_BRANCH, "branch-b")

    def test_settings_updates_the_selected_custom_json(self) -> None:
        repo = self._repo()
        selected = repo / "config with spaces" / "selected.json"
        selected.parent.mkdir()
        selected.write_text(json.dumps({"runner": "codex-run.sh", "env": {}}))
        with mock.patch.dict(os.environ, {
                "SINGULAR_JSON_CONFIG_FILE": "config with spaces/selected.json"}):
            srv.initialize_configuration(repo, force=True)
            status, response = srv.apply_settings_changes(
                repo, {"SINGULAR_MAX_CONCURRENT": "3"})
            self.assertEqual(status, 200)
            self.assertEqual(response["config"]["limits"]["maxConcurrent"], "3")
            self.assertEqual(json.loads(selected.read_text())["env"]
                             ["SINGULAR_MAX_CONCURRENT"], "3")
            self.assertFalse((repo / "singular.config.json").exists())

    def test_json_env_cannot_relabel_the_actual_selected_file(self) -> None:
        repo = self._repo({
            "runner": "claude-run.sh",
            "env": {"SINGULAR_JSON_CONFIG_FILE": "unselected.json"},
        })
        (repo / "unselected.json").write_text(
            json.dumps({"runner": "gemini-run.sh", "env": {}}))
        config = srv.initialize_configuration(repo, force=True)
        self.assertEqual(config["configuration"]["path"],
                         str((repo / "singular.config.json").resolve()))
        self.assertEqual(config["configuration"]["source"], "default")
        self.assertEqual(config["provider"], "claude")

    def test_settings_accepts_changed_selector_with_one_refresh(self) -> None:
        repo = self._repo({"runner": "codex-run.sh", "env": {}})
        srv.initialize_configuration(repo, force=True)
        selected = repo / "alternate.json"
        selected.write_text(json.dumps({"runner": "claude-run.sh", "env": {}}))
        calls = 0
        original = srv._compute_effective_configuration

        def counted(root):
            nonlocal calls
            calls += 1
            return original(root)

        with mock.patch.dict(os.environ, {"SINGULAR_JSON_CONFIG_FILE": str(selected)}), \
                mock.patch.object(srv, "_compute_effective_configuration", counted):
            self.assertEqual(srv.collect_config(repo)["configuration"]["reason"],
                             "configuration-changed")
            status, response = srv.apply_settings_changes(
                repo, {"SINGULAR_MAX_CONCURRENT": "4"})
            self.assertEqual(status, 200)
            self.assertEqual(response["config"]["provider"], "claude")
            self.assertEqual(response["config"]["limits"]["maxConcurrent"], "4")
            self.assertEqual(calls, 1)
        self.assertNotIn("SINGULAR_MAX_CONCURRENT",
                         json.loads((repo / "singular.config.json").read_text())["env"])

    def test_startup_shell_effect_is_not_replayed_by_reads(self) -> None:
        repo = self._repo({"runner": "codex-run.sh", "env": {}})
        marker = repo / "startup-effects"
        (repo / ".singular-state" / "leases").mkdir(parents=True)
        (repo / ".singular-state" / "locks").mkdir()
        (repo / ".singular-state" / "leases" / "TASK-1.json").write_text(
            '{"taskId":"TASK-1","status":"ready"}\n')
        (repo / ".singular-state" / "locks" / "origin.lock.json").write_text('{}\n')
        (repo / ".singular-state" / "events.ndjson").write_text("")
        (repo / "singular.config.sh").write_text(
            f"printf '%s\\n' startup >> {str(marker)!r}\n")
        srv.initialize_configuration(repo, force=True)

        def file_snapshot():
            return {
                str(path.relative_to(repo)): (
                    path.stat().st_mode & 0o7777, path.stat().st_mtime_ns,
                    hashlib.sha256(path.read_bytes()).hexdigest())
                for path in repo.rglob("*") if path.is_file()
            }

        before = file_snapshot()
        real_run = srv.subprocess.run
        calls = []

        def record(*args, **kwargs):
            calls.append(args)
            return real_run(*args, **kwargs)

        with mock.patch.object(srv.subprocess, "run", record):
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda _n: srv.collect_config(repo), range(32)))
            base = time.monotonic()
            with mock.patch.object(srv.time, "monotonic", return_value=base + 31):
                srv.collect_home(repo)
                srv.collect_lifecycle_view(repo)
        after = file_snapshot()
        self.assertEqual(calls, [])
        self.assertEqual(before, after)

    def test_warmed_derived_caches_cannot_bypass_changed_generation(self) -> None:
        repo = self._repo({"runner": "codex-run.sh", "env": {}})
        original_collect_processes = srv.collect_processes
        srv.collect_processes = lambda: []
        self.addCleanup(setattr, srv, "collect_processes", original_collect_processes)
        (repo / ".singular-state/runs").mkdir(parents=True)
        (repo / ".singular-state/leases").mkdir()
        (repo / "docs/orchestration/tasks").mkdir(parents=True)
        initial = srv.initialize_configuration(repo, force=True)
        caches = (
            srv._OVERVIEW_CACHE, srv._HOME_CACHE, srv._DAG_VIEW_CACHE,
            srv._TIMELINE_CACHE, srv._PROVIDERS_CACHE, srv._PLANS_CACHE,
            srv.SNAPSHOT_CACHE, srv.SESSIONS_CACHE,
        )
        for cache in caches:
            cache.invalidate()

        original_provider_compute = srv._PROVIDERS_CACHE._compute_fn

        def safe_provider_compute(root):
            cfg = srv.collect_config(root)
            return {
                "schema": "singular.providers.v0",
                "activeProvider": cfg["provider"] if cfg["ok"] else "unknown",
                "activeRunner": cfg["runner"] if cfg["ok"] else None,
                "generation": cfg["generation"],
                "providers": [],
                "summary": {},
            }

        srv._PROVIDERS_CACHE._compute_fn = safe_provider_compute
        self.addCleanup(setattr, srv._PROVIDERS_CACHE, "_compute_fn",
                        original_provider_compute)
        warm = {
            "overview": srv.load_overview(repo),
            "home": srv.load_home(repo),
            "dag": srv.load_dag_view(repo),
            "timeline": srv.load_timeline(repo),
            "providers": srv.collect_providers(repo),
            "state": srv.SNAPSHOT_CACHE.get(repo, fresh=True),
            "sessions": srv.SESSIONS_CACHE.get(repo),
            "plans": srv.load_plans(repo),
        }
        self.assertTrue(all(
            value["generation"]["id"] == initial["generation"]["id"]
            for value in warm.values()
        ))

        (repo / "singular.config.json").write_text(
            json.dumps({"runner": "gemini-run.sh", "env": {}})
        )
        providers = srv.collect_providers(repo)
        self.assertEqual(providers["activeProvider"], "unknown")
        self.assertEqual(providers["generation"]["status"], "changed")
        for loader in (
            srv.load_overview, srv.load_home, srv.load_dag_view,
            srv.load_timeline, lambda root: srv.SNAPSHOT_CACHE.get(root),
            srv.SESSIONS_CACHE.get, srv.load_plans,
        ):
            with self.assertRaises(srv.ConfigurationUnavailable):
                loader(repo)

    def test_authorized_refresh_replaces_every_warmed_generation(self) -> None:
        repo = self._repo({"runner": "codex-run.sh", "env": {}})
        original_collect_processes = srv.collect_processes
        srv.collect_processes = lambda: []
        self.addCleanup(setattr, srv, "collect_processes", original_collect_processes)
        (repo / ".singular-state/runs").mkdir(parents=True)
        (repo / ".singular-state/leases").mkdir()
        (repo / "docs/orchestration/tasks").mkdir(parents=True)
        initial = srv.initialize_configuration(repo, force=True)
        loaders = (
            srv.load_overview, srv.load_home, srv.load_dag_view,
            srv.load_timeline, lambda root: srv.SNAPSHOT_CACHE.get(root, fresh=True),
            srv.SESSIONS_CACHE.get, srv.load_plans,
        )
        for loader in loaders:
            loader(repo)
        status, response = srv.apply_settings_changes(
            repo, {"SINGULAR_MAX_CONCURRENT": "4"}
        )
        self.assertEqual(status, 200)
        replacement = response["config"]["generation"]["id"]
        self.assertNotEqual(replacement, initial["generation"]["id"])
        for loader in loaders:
            value = loader(repo)
            self.assertEqual(value["generation"]["id"], replacement)
            self.assertEqual(value["generation"]["status"], "current")

    def test_old_inflight_compute_is_isolated_from_replacement_generation(self) -> None:
        repo = self._repo({"runner": "codex-run.sh", "env": {}})
        initial = srv.initialize_configuration(repo, force=True)
        entered = threading.Event()
        release = threading.Event()
        calls: list[str] = []

        def compute(root):
            generation = srv._effective_configuration_view(root)["generation"]["id"]
            calls.append(generation)
            if generation == initial["generation"]["id"]:
                entered.set()
                self.assertTrue(release.wait(5))
            return {"generation": {"id": generation}}

        cache = srv._ComputeCache(compute, 60.0)
        old_result: list[dict] = []

        def old_request():
            with srv._EFFECTIVE_CONFIGURATION_CACHE.pin(repo):
                old_result.append(cache.get(str(repo), repo))

        thread = threading.Thread(target=old_request)
        thread.start()
        self.assertTrue(entered.wait(5))
        (repo / "singular.config.json").write_text(
            json.dumps({"runner": "gemini-run.sh", "env": {}})
        )
        replacement = srv.initialize_configuration(repo, force=True)
        release.set()
        thread.join(5)
        self.assertFalse(thread.is_alive())
        new_result = cache.get(str(repo), repo)
        self.assertEqual(old_result[0]["generation"]["id"], initial["generation"]["id"])
        self.assertEqual(new_result["generation"]["id"], replacement["generation"]["id"])
        self.assertEqual(calls, [initial["generation"]["id"],
                                 replacement["generation"]["id"]])


class AutonomateLogResolutionTests(unittest.TestCase):
    """The engine's --detach loop writes autonomate.log; the legacy name is
    autonomate.out.log. The server follows whichever exists (newest wins)."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        self.state = self.repo / ".singular-state"
        self.state.mkdir()

    def test_engine_name_only(self) -> None:
        (self.state / "autonomate.log").write_text("loop\n")
        self.assertEqual(srv.resolve_autonomate_log(self.repo), "autonomate.log")
        session = srv._origin_session(self.repo)
        self.assertIn({"name": "autonomate.log", "kind": "plain"}, session["logFiles"])
        # A pre-0.6.0 client asking for the legacy alias still gets the live log.
        path, _files = srv._resolve_session_log(self.repo, "origin", "autonomate.out.log")
        self.assertEqual(path, self.state / "autonomate.log")

    def test_newest_wins(self) -> None:
        (self.state / "autonomate.log").write_text("old\n")
        (self.state / "autonomate.out.log").write_text("new\n")
        now = time.time()
        os.utime(self.state / "autonomate.log", (now - 600, now - 600))
        os.utime(self.state / "autonomate.out.log", (now, now))
        self.assertEqual(srv.resolve_autonomate_log(self.repo), "autonomate.out.log")

    def test_neither_defaults_to_legacy(self) -> None:
        self.assertEqual(srv.resolve_autonomate_log(self.repo), "autonomate.out.log")
        path, _files = srv._resolve_session_log(self.repo, "origin", "autonomate.out.log")
        self.assertIsNone(path)

    def test_explicit_engine_file_served(self) -> None:
        (self.state / "autonomate.log").write_text("loop\n")
        path, files = srv._resolve_session_log(self.repo, "origin", "autonomate.log")
        self.assertEqual(path, self.state / "autonomate.log")
        self.assertIn({"name": "autonomate.log", "kind": "plain"}, files)


class SettingsOverlayTests(unittest.TestCase):
    """/api/settings rows use the same lib.sh-resolved generation as config."""

    def test_config_env_overlays_defaults_and_dotenv_is_not_authority(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / ".singular-state").mkdir()
            (repo / "singular.config.json").write_text(json.dumps(
                {"env": {"SINGULAR_MAX_CONCURRENT": "7", "SINGULAR_SLEEP": "45"}}))
            (repo / ".singular-state/.env").write_text("SINGULAR_SLEEP=9\n")
            srv.initialize_configuration(repo, force=True)
            self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
            view = srv.collect_settings_view(repo)
            items = {it["envKey"]: it for g in view["groups"] for it in g["items"]}
            conc = items["SINGULAR_MAX_CONCURRENT"]
            self.assertEqual((conc["value"], conc["source"], conc["overridden"]),
                             ("7", "effective", True))
            sleep = items["SINGULAR_SLEEP"]
            self.assertEqual((sleep["value"], sleep["source"]), ("45", "effective"))

    def test_post_response_settings_reflect_write(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / ".singular-state").mkdir()
            (repo / "singular.config.json").write_text(json.dumps({"env": {}}))
            status, payload = srv.apply_settings_changes(repo, {"SINGULAR_MAX_CONCURRENT": "4"})
            self.assertEqual(status, 200)
            items = {it["envKey"]: it for g in payload["settings"] for it in g["items"]}
            self.assertEqual(items["SINGULAR_MAX_CONCURRENT"]["value"], "4")
            self.assertEqual(items["SINGULAR_MAX_CONCURRENT"]["source"], "effective")


class SettingsWriteTests(unittest.TestCase):
    """W1: apply_settings_changes validates + applies to singular.config.json env{}
    without touching any other key. collect_settings stays read-only."""

    def _repo(self, config: dict | None = None) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state").mkdir()
        if config is not None:
            (repo / "singular.config.json").write_text(json.dumps(config))
        # invalidate shared caches so cross-test residue never leaks in
        srv._CONFIG_CACHE.invalidate()
        srv._OVERVIEW_CACHE.invalidate()
        return repo

    def test_unknown_key_rejected_nothing_written(self) -> None:
        repo = self._repo({"env": {}})
        status, payload = srv.apply_settings_changes(repo, {"DATABASE_URL": "postgres://x"})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"], "unknown or read-only keys")
        self.assertIn("DATABASE_URL", payload["keys"])
        self.assertEqual(json.loads((repo / "singular.config.json").read_text())["env"], {})

    def test_derived_kind_rejected(self) -> None:
        # SINGULAR_MAX_DISPATCH is kind=derived in SETTINGS_SPEC -> read-only.
        derived = [it[0] for _t, _l, items in srv.SETTINGS_SPEC for it in items if it[3] == "derived"]
        self.assertIn("SINGULAR_MAX_DISPATCH", derived)
        repo = self._repo({"env": {}})
        status, payload = srv.apply_settings_changes(repo, {"SINGULAR_MAX_DISPATCH": "5"})
        self.assertEqual(status, 400)
        self.assertIn("SINGULAR_MAX_DISPATCH", payload["keys"])

    def test_bool_and_count_validation(self) -> None:
        repo = self._repo({"env": {}})
        # bool: only 0/1 (or true/false) accepted
        status, _ = srv.apply_settings_changes(repo, {"SINGULAR_AUTO_INTEGRATE": "maybe"})
        self.assertEqual(status, 400)
        status, payload = srv.apply_settings_changes(repo, {"SINGULAR_AUTO_INTEGRATE": True})
        self.assertEqual(status, 200)
        self.assertEqual(payload["applied"]["SINGULAR_AUTO_INTEGRATE"], "1")
        # count: non-negative integer only
        status, _ = srv.apply_settings_changes(repo, {"SINGULAR_MAX_CONCURRENT": "-2"})
        self.assertEqual(status, 400)
        status, _ = srv.apply_settings_changes(repo, {"SINGULAR_MAX_CONCURRENT": "notanumber"})
        self.assertEqual(status, 400)
        status, payload = srv.apply_settings_changes(repo, {"SINGULAR_MAX_CONCURRENT": 4})
        self.assertEqual(status, 200)
        self.assertEqual(payload["applied"]["SINGULAR_MAX_CONCURRENT"], "4")

    def test_write_preserves_other_keys(self) -> None:
        repo = self._repo({
            "schemaVersion": "v0", "runner": "claude-run.sh", "targetBranch": "agent/integration",
            "env": {"CUSTOM_SECRET": "keepme", "SINGULAR_SLEEP": "5"}})
        status, payload = srv.apply_settings_changes(repo, {"SINGULAR_MAX_CONCURRENT": "3"})
        self.assertEqual(status, 200)
        obj = json.loads((repo / "singular.config.json").read_text())
        self.assertEqual(obj["schemaVersion"], "v0")
        self.assertEqual(obj["runner"], "claude-run.sh")
        self.assertEqual(obj["targetBranch"], "agent/integration")
        self.assertEqual(obj["env"]["CUSTOM_SECRET"], "keepme")   # unknown env key preserved
        self.assertEqual(obj["env"]["SINGULAR_SLEEP"], "5")
        self.assertEqual(obj["env"]["SINGULAR_MAX_CONCURRENT"], "3")
        self.assertEqual(payload["appliesAt"]["SINGULAR_MAX_CONCURRENT"], "next-cycle")

    def test_empty_string_deletes_key(self) -> None:
        repo = self._repo({"env": {"SINGULAR_MAX_CONCURRENT": "9", "CUSTOM_SECRET": "keepme"}})
        status, _ = srv.apply_settings_changes(repo, {"SINGULAR_MAX_CONCURRENT": ""})
        self.assertEqual(status, 200)
        env = json.loads((repo / "singular.config.json").read_text())["env"]
        self.assertNotIn("SINGULAR_MAX_CONCURRENT", env)
        self.assertEqual(env["CUSTOM_SECRET"], "keepme")

    def test_collect_config_reflects_write_cache_invalidated(self) -> None:
        repo = self._repo({"runner": "claude-run.sh", "env": {}})
        before = srv.load_config_view(repo)                       # primes the cache
        self.assertIsNone(before["limits"]["maxConcurrent"])
        srv.apply_settings_changes(repo, {"SINGULAR_MAX_CONCURRENT": "7"})
        after = srv.load_config_view(repo)                        # must see the new value
        self.assertEqual(after["limits"]["maxConcurrent"], "7")

    def test_loop_restart_applies_at(self) -> None:
        repo = self._repo({"env": {}})
        status, payload = srv.apply_settings_changes(repo, {"SINGULAR_SLEEP": "30"})
        self.assertEqual(status, 200)
        self.assertEqual(payload["appliesAt"]["SINGULAR_SLEEP"], "loop-restart")

    def test_missing_config_409(self) -> None:
        repo = self._repo(config=None)
        status, payload = srv.apply_settings_changes(repo, {"SINGULAR_MAX_CONCURRENT": "2"})
        self.assertEqual(status, 409)
        self.assertIn("initialize the repo first", payload["error"])

    def test_settings_view_shape(self) -> None:
        repo = self._repo({"env": {}})
        view = srv.collect_settings_view(repo)
        self.assertEqual(view["schema"], "singular.codex.settings.v0")
        self.assertEqual(view["groups"], srv.collect_settings(repo))
        self.assertEqual(view["appliesAt"]["SINGULAR_SLEEP"], "loop-restart")
        self.assertEqual(view["appliesAt"]["SINGULAR_MAX_CONCURRENT"], "next-cycle")
        self.assertNotIn("SINGULAR_MAX_DISPATCH", view["appliesAt"])  # derived is read-only


class PromptEndpointTests(unittest.TestCase):
    """W2: the role prompt library list/fetch + rendered per-run prompts served
    through the session terminal. Pure filesystem; traversal-guarded."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / "docs/orchestration/prompts").mkdir(parents=True)
        (repo / ".singular-state").mkdir()
        return repo

    def test_list_maps_roles(self) -> None:
        repo = self._repo()
        pdir = repo / "docs/orchestration/prompts"
        (pdir / "auditor.md").write_text("audit\n")
        (pdir / "l2-test-first-developer.md").write_text("dev\n")
        (pdir / "custom-note.md").write_text("x\n")
        out = srv.collect_prompts(repo)
        self.assertEqual(out["schema"], "singular.codex.prompts.v0")
        names = [p["name"] for p in out["prompts"]]
        self.assertEqual(names, sorted(names))  # sorted by name
        by_name = {p["name"]: p for p in out["prompts"]}
        self.assertEqual(by_name["auditor.md"]["role"], "auditor")
        self.assertEqual(by_name["l2-test-first-developer.md"]["role"], "developer")
        self.assertIsNone(by_name["custom-note.md"]["role"])  # unknown -> null
        self.assertEqual(by_name["auditor.md"]["bytes"], 6)

    def test_content_fetch(self) -> None:
        repo = self._repo()
        (repo / "docs/orchestration/prompts/reviewer.md").write_text("review body\n")
        data = srv.collect_prompt(repo, "reviewer.md")
        self.assertEqual(data["name"], "reviewer.md")
        self.assertEqual(data["content"], "review body\n")
        self.assertEqual(data["size"], 12)

    def test_traversal_and_bad_names_rejected(self) -> None:
        repo = self._repo()
        (repo / "secret.md").write_text("nope\n")
        for bad in ("../secret.md", "/etc/passwd", ".hidden.md", "auditor.txt", "..", "sub/x.md"):
            self.assertIsNone(srv.collect_prompt(repo, bad), bad)

    def test_missing_prompt_none(self) -> None:
        self.assertIsNone(srv.collect_prompt(self._repo(), "nope.md"))

    def test_run_dir_prompt_served_through_session(self) -> None:
        repo = self._repo()
        run = repo / ".singular-state/runs/RUN-1"
        run.mkdir(parents=True)
        (run / "worker-codex.log").write_text('{"type":"item.completed"}\n')
        (run / "l2-prompt.md").write_text("# worker prompt\ndo the thing\n")
        files = srv._session_log_files(run)
        self.assertIn({"name": "l2-prompt.md", "kind": "prompt"}, files)
        self.assertEqual(files[0]["kind"], "codex")  # logs stay primary
        # _resolve_session_log accepts the prompt name and read_session serves it raw
        path, _files = srv._resolve_session_log(repo, "RUN-1", "l2-prompt.md")
        self.assertEqual(path.resolve(), (run / "l2-prompt.md").resolve())
        session = srv.read_session(repo, "RUN-1", None, 50, "l2-prompt.md", True)
        self.assertEqual(session["file"], "l2-prompt.md")
        joined = "\n".join(line.get("text", "") for line in session["lines"])
        self.assertIn("do the thing", joined)


class RawEndpointTests(unittest.TestCase):
    """W3: /api/raw/<root>/<name> view-source over durable records. Each root is
    traversal-guarded by regex/allowlist + resolved-path containment."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        for rel in ("docs/orchestration/tasks/superseded", "docs/orchestration/gates/evidence",
                    ".singular-state/leases", ".singular-state/l1-leases",
                    ".singular-state/dispatch", ".singular-state/inbox"):
            (repo / rel).mkdir(parents=True)
        return repo

    def test_happy_path_each_root(self) -> None:
        repo = self._repo()
        (repo / "singular.config.json").write_text('{"schemaVersion":"v0"}')
        (repo / "docs/orchestration/dag.v0.json").write_text('{"nodes":[]}')
        (repo / "docs/orchestration/tasks/TASK-0007.md").write_text("# TASK-0007\n")
        (repo / "docs/orchestration/gates/D0.contract.gate-result.json").write_text('{"node":"D0.contract"}')
        (repo / "docs/orchestration/gates/evidence/ev-1.json").write_text('{"ev":1}')
        (repo / ".singular-state/leases/TASK-0007.json").write_text('{"taskId":"TASK-0007"}')
        (repo / ".singular-state/l1-leases/D0.contract.json").write_text('{"node":"D0.contract"}')
        (repo / ".singular-state/dispatch/TASK-0007.json").write_text('{"state":"launched"}')
        (repo / ".singular-state/inbox/pkt-1.json").write_text('{"pkt":1}')
        (repo / ".singular-state/circuit.json").write_text('{"consecFails":0}')
        cases = [
            ("config", "singular.config.json"), ("dag", "dag.v0.json"),
            ("task", "TASK-0007.md"), ("gate", "D0.contract.gate-result.json"),
            ("gate-review", "ev-1.json"), ("lease", "TASK-0007.json"),
            ("l1-lease", "D0.contract.json"), ("dispatch", "TASK-0007.json"),
            ("inbox", "pkt-1.json"), ("state", "circuit.json"),
        ]
        for root, name in cases:
            data = srv.collect_raw(repo, root, name)
            self.assertIsNotNone(data, f"{root}/{name}")
            self.assertEqual(data["schema"], "singular.codex.raw.v0")
            self.assertEqual(data["root"], root)
            self.assertEqual(data["name"], name)
            self.assertTrue(data["content"])
            self.assertNotIn("truncated", data)

    def test_superseded_task_fallback(self) -> None:
        repo = self._repo()
        (repo / "docs/orchestration/tasks/superseded/TASK-0009.md").write_text("# old\n")
        data = srv.collect_raw(repo, "task", "TASK-0009.md")
        self.assertIsNotNone(data)
        self.assertTrue(data["path"].endswith("superseded/TASK-0009.md"))

    def test_traversal_and_bad_names_rejected(self) -> None:
        repo = self._repo()
        (repo / ".singular-state/.env").write_text("SECRET=1\n")
        self.assertIsNone(srv.collect_raw(repo, "task", "../../etc/passwd"))
        self.assertIsNone(srv.collect_raw(repo, "gate", "../evidence/ev.json"))
        self.assertIsNone(srv.collect_raw(repo, "state", ".env"))          # not in allowlist
        self.assertIsNone(srv.collect_raw(repo, "state", "leases"))        # dir, not allowlisted
        self.assertIsNone(srv.collect_raw(repo, "config", "other.json"))   # wrong singleton name
        self.assertIsNone(srv.collect_raw(repo, "task", "TASK-0007.txt"))  # wrong extension

    def test_unknown_root_none(self) -> None:
        self.assertIsNone(srv.collect_raw(self._repo(), "bogus", "x.json"))

    def test_oversize_truncation(self) -> None:
        repo = self._repo()
        big = "y" * (srv.RAW_MAX_BYTES + 500)
        (repo / "docs/orchestration/tasks/TASK-0011.md").write_text(big)
        data = srv.collect_raw(repo, "task", "TASK-0011.md")
        self.assertTrue(data["truncated"])
        self.assertEqual(len(data["content"]), srv.RAW_MAX_BYTES)
        self.assertEqual(data["size"], len(big))


class CollectHomeTests(unittest.TestCase):
    """W4: the landing digest — attention triggers, activity rollup, empty-repo
    zeros. Pure filesystem."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state").mkdir()
        (repo / "docs/orchestration/tasks").mkdir(parents=True)
        return repo

    def test_empty_repo_zeros_ok(self) -> None:
        # Empty-repo behavior must not depend on the developer host's disk use.
        usage = type("Usage", (), {"total": 100_000_000_000, "used": 10_000_000_000,
                                    "free": 90_000_000_000})()
        with mock.patch.object(srv.shutil, "disk_usage", return_value=usage):
            home = srv.collect_home(self._repo())
        self.assertEqual(home["schema"], "singular.codex.home.v0")
        self.assertEqual(home["health"], "ok")
        self.assertEqual(home["attention"], [])
        self.assertEqual(home["gates"], {
            "passed": 0, "total": 0,
            "cohorts": {"historical": {"passed": 0, "total": 0},
                        "current": {"passed": 0, "total": 0, "pct": 0}}})
        self.assertEqual(home["frontier"], {"count": 0, "nodes": []})
        self.assertEqual(home["taskCounts"]["total"], 0)
        self.assertEqual(home["dispatch"], {"launched": 0, "pidAlive": 0})
        self.assertEqual(home["autonomate"], {"pid": None, "alive": False})
        self.assertFalse(home["stop"])
        self.assertIsNone(home["backoff"])
        self.assertIsNone(home["lastActivityAt"])
        self.assertEqual(len(home["activityByDay"]), 14)

    def test_stop_attention(self) -> None:
        repo = self._repo()
        (repo / ".singular-state/STOP").write_text("")
        home = srv.collect_home(repo)
        self.assertTrue(home["stop"])
        self.assertTrue(any(a["severity"] == "watch" and "STOP" in a["text"]
                            for a in home["attention"]))
        self.assertEqual(home["health"], "watch")

    def test_breaker_blocker_and_near(self) -> None:
        repo = self._repo()
        (repo / "scripts/orchestration").mkdir(parents=True)
        (repo / "scripts/orchestration/lib.sh").write_text(
            'SINGULAR_MAX_CONSEC_FAILS="${SINGULAR_MAX_CONSEC_FAILS:-4}"\n')
        (repo / ".singular-state/circuit.json").write_text(json.dumps({"consecFails": 4}))
        home = srv.collect_home(repo)
        self.assertEqual(home["breaker"], {"consecFails": 4, "threshold": 4})
        self.assertEqual(home["health"], "blocker")
        self.assertTrue(any(a["severity"] == "blocker" for a in home["attention"]))
        # one below threshold -> watch
        (repo / ".singular-state/circuit.json").write_text(json.dumps({"consecFails": 3}))
        srv._HOME_CACHE.invalidate()
        home = srv.collect_home(repo)
        self.assertTrue(any(a["severity"] == "watch" and "near trip" in a["text"]
                            for a in home["attention"]))

    def test_backoff_active_attention(self) -> None:
        repo = self._repo()
        future = (dt.datetime.now(dt.UTC) + dt.timedelta(minutes=30)).isoformat().replace("+00:00", "Z")
        (repo / ".singular-state/planner-backoff.json").write_text(
            json.dumps({"until": future, "failureClass": "quota"}))
        home = srv.collect_home(repo)
        self.assertTrue(home["backoff"]["active"])
        self.assertTrue(any("quota" in a["text"] for a in home["attention"]))

    def test_stale_l1_lease_attention(self) -> None:
        repo = self._repo()
        (repo / ".singular-state/l1-leases").mkdir()
        old = (dt.datetime.now(dt.UTC) - dt.timedelta(minutes=200)).isoformat().replace("+00:00", "Z")
        (repo / ".singular-state/l1-leases/D0.contract.json").write_text(
            json.dumps({"node": "D0.contract", "status": "active", "updatedAt": old}))
        home = srv.collect_home(repo)
        self.assertTrue(any("idle" in a["text"] for a in home["attention"]))

    def test_stale_autonomate_pidfile_attention(self) -> None:
        repo = self._repo()
        (repo / ".singular-state/autonomate.pid").write_text("999999999\n")
        home = srv.collect_home(repo)
        self.assertFalse(home["autonomate"]["alive"])
        self.assertTrue(any("pidfile is stale" in a["text"] for a in home["attention"]))

    def test_activity_rollup_across_days(self) -> None:
        repo = self._repo()
        now = dt.datetime.now(dt.UTC)

        def iso(days_ago: int) -> str:
            return (now - dt.timedelta(days=days_ago)).isoformat().replace("+00:00", "Z")

        events = [
            _ev("l1.dispatch_started", iso(2), taskId="TASK-1", branch="agent/task-1"),
            _ev("l1.dispatch_started", iso(1), taskId="TASK-2", branch="agent/task-2"),
            _ev("integration.integrated", iso(1), taskId="TASK-2", branch="agent/task-2",
                mergeCommit="abc1234"),
            _ev("l1.task_failed", iso(0), taskId="TASK-3"),
        ]
        (repo / ".singular-state/events.ndjson").write_text(
            "\n".join(json.dumps(e) for e in events) + "\n")
        home = srv.collect_home(repo)
        by_date = {d["date"]: d for d in home["activityByDay"]}
        self.assertEqual(by_date[(now.date() - dt.timedelta(days=2)).isoformat()]["dispatches"], 1)
        self.assertEqual(by_date[(now.date() - dt.timedelta(days=1)).isoformat()]["dispatches"], 1)
        self.assertEqual(by_date[(now.date() - dt.timedelta(days=1)).isoformat()]["integrations"], 1)
        self.assertEqual(by_date[now.date().isoformat()]["failures"], 1)
        self.assertIsNotNone(home["lastActivityAt"])
        self.assertLessEqual(len(home["notable"]), 12)


def _write_archived_plan(plans_dir: Path, pid: str, *, node_id: str,
                         archived_at: str, name: str | None = None,
                         with_manifest: bool = True, with_run: bool = False) -> dict:
    """Materialize a minimal archived mini-repo plan under plans_dir/<pid>/ with
    both subtrees. Returns the summary entry (index.json shape)."""
    root = plans_dir / pid
    (root / "docs/orchestration/tasks").mkdir(parents=True)
    (root / "docs/orchestration/gates").mkdir(parents=True)
    (root / ".singular-state/leases").mkdir(parents=True)
    (root / ".singular-state/l1-leases").mkdir(parents=True)
    (root / ".singular-state/runs").mkdir(parents=True)
    (root / "docs/orchestration/dag.v0.json").write_text(json.dumps({
        "schema": "singular.orchestration.dag.v0",
        "layers": ["contract"], "kinds": ["contract"],
        "nodes": [
            {"id": node_id, "stage": "A0-arch", "area": "core", "layer": "contract",
             "kind": "contract", "dependsOn": [], "requiredCompletion": "x"},
        ],
    }))
    (root / "docs/orchestration/gates" / f"{node_id}.gate-result.json").write_text(json.dumps(
        {"node": node_id, "status": "passed", "authoritative": True,
         "evidenceClass": "deterministic-proof", "recordedAt": archived_at}))
    (root / "docs/orchestration/tasks/TASK-0001.md").write_text(
        "# TASK-0001: archived task\n\nStatus: integrated\nArea: core\n")
    (root / ".singular-state/events.ndjson").write_text(json.dumps(
        {"ts": archived_at, "type": "plan.archived",
         "data": {"planId": pid, "name": name or pid}}) + "\n")
    if with_run:
        run_dir = root / ".singular-state/runs/RUN-arch-1"
        run_dir.mkdir(parents=True)
        (run_dir / "codex.jsonl").write_text(
            json.dumps({"type": "message", "role": "assistant", "content": "done"}) + "\n")
    summary = {
        "id": pid, "name": name or pid, "archivedAt": archived_at,
        "gates": {"passed": 1, "total": 1}, "taskCount": 1, "eventCount": 1,
        "headSha": "abc1234", "branch": "agent/integration",
    }
    if with_manifest:
        manifest = dict(summary)
        manifest.update({"schema": "singular.plan.manifest.v0",
                         "engineVersion": "0.8.0", "schemaVersion": "v0", "forced": False})
        (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return summary


class CollectPlansTests(unittest.TestCase):
    """0.8.0 singular.plans.v0: registry read, manifest self-heal, sort, empties."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return Path(tmp.name)

    def test_empty_repo(self) -> None:
        data = srv.collect_plans(self._repo())
        self.assertEqual(data["schema"], "singular.plans.v0")
        self.assertEqual(data["plans"], [])
        self.assertIn("generatedAt", data)

    def test_registry_and_self_heal_sorted(self) -> None:
        repo = self._repo()
        plans_dir = repo / ".singular-state/plans"
        plans_dir.mkdir(parents=True)
        # Plan A: in index.json AND has a manifest (index entry must win).
        a = _write_archived_plan(plans_dir, "plan-20260101T000000Z-alpha",
                                 node_id="a-node", archived_at="2026-01-01T00:00:00Z",
                                 name="Alpha")
        # Plan B: manifest only, NOT in index → self-heal must surface it.
        _write_archived_plan(plans_dir, "plan-20260201T000000Z-beta",
                             node_id="b-node", archived_at="2026-02-01T00:00:00Z",
                             name="Beta")
        # index.json lists only A, but with a different display name than its
        # manifest, so we can prove index wins the merge.
        index_entry = dict(a, name="Alpha (from index)")
        (plans_dir / "index.json").write_text(json.dumps(
            {"schema": "singular.plans.index.v0", "updatedAt": a["archivedAt"],
             "plans": [index_entry]}))

        data = srv.collect_plans(repo)
        ids = [p["id"] for p in data["plans"]]
        self.assertEqual(ids, ["plan-20260201T000000Z-beta", "plan-20260101T000000Z-alpha"])
        by_id = {p["id"]: p for p in data["plans"]}
        # index entry wins over the manifest for A.
        self.assertEqual(by_id["plan-20260101T000000Z-alpha"]["name"], "Alpha (from index)")
        # self-healed B carries only the pinned entry fields.
        self.assertEqual(set(by_id["plan-20260201T000000Z-beta"].keys()),
                         set(srv._PLAN_ENTRY_FIELDS))
        self.assertEqual(by_id["plan-20260201T000000Z-beta"]["gates"], {"passed": 1, "total": 1})
        self.assertEqual(by_id["plan-20260201T000000Z-beta"]["taskCount"], 1)

    def test_index_only_no_dir(self) -> None:
        # An index entry with no archived dir on disk is still returned.
        repo = self._repo()
        plans_dir = repo / ".singular-state/plans"
        plans_dir.mkdir(parents=True)
        (plans_dir / "index.json").write_text(json.dumps(
            {"schema": "singular.plans.index.v0",
             "plans": [{"id": "plan-20260301T000000Z-x", "name": "X",
                        "archivedAt": "2026-03-01T00:00:00Z", "gates": {"passed": 0, "total": 0},
                        "taskCount": 0, "eventCount": 0, "headSha": "deadbee", "branch": "main"}]}))
        data = srv.collect_plans(repo)
        self.assertEqual([p["id"] for p in data["plans"]], ["plan-20260301T000000Z-x"])


class PlanParamRoutingTests(unittest.TestCase):
    """0.8.0 ?plan= routing over the HTTP layer: archived mini-repo roots serve
    read-only; invalid/traversal ids 404; writes 400; excluded routes ignore."""

    PID = "plan-20260101T000000Z-test"

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.live = Path(tmp.name)
        for rel in ("docs/orchestration/tasks", "docs/orchestration/gates",
                    ".singular-state/leases", ".singular-state/l1-leases",
                    ".singular-state/runs"):
            (self.live / rel).mkdir(parents=True)
        # Live DAG has a node id distinct from the archived plan's.
        (self.live / "docs/orchestration/dag.v0.json").write_text(json.dumps({
            "schema": "singular.orchestration.dag.v0",
            "layers": ["contract"], "kinds": ["contract"],
            "nodes": [{"id": "live-node", "stage": "L0-live", "area": "core",
                       "layer": "contract", "kind": "contract", "dependsOn": [],
                       "requiredCompletion": "x"}],
        }))
        (self.live / "singular.config.json").write_text('{"env": {}}')
        self._config_before = (self.live / "singular.config.json").read_text()
        # Archived mini-repo plan + registry.
        plans_dir = self.live / ".singular-state/plans"
        plans_dir.mkdir(parents=True)
        summary = _write_archived_plan(plans_dir, self.PID, node_id="arch-node",
                                       archived_at="2026-01-01T00:00:00Z", name="Test Plan",
                                       with_run=True)
        (plans_dir / "index.json").write_text(json.dumps(
            {"schema": "singular.plans.index.v0", "updatedAt": summary["archivedAt"],
             "plans": [summary]}))
        # Fresh caches so the archived/live roots resolve against this fixture.
        for cache in (srv._PLANS_CACHE, srv._DAG_VIEW_CACHE, srv._TIMELINE_CACHE,
                      srv._OVERVIEW_CACHE):
            cache.invalidate()

        self._saved_repo = srv.Handler.repo
        srv.Handler.repo = self.live
        self.server = srv.ThreadingHTTPServer(("127.0.0.1", 0), srv.Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

        def _teardown() -> None:
            self.server.shutdown()
            self.server.server_close()
            self.thread.join()
            srv.Handler.repo = self._saved_repo
        self.addCleanup(_teardown)

    def _req(self, method: str, path: str, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        headers = {}
        raw_body = None
        if body is not None:
            raw_body = json.dumps(body).encode()
            headers = {"Content-Type": "application/json", "Content-Length": str(len(raw_body))}
        conn.request(method, path, body=raw_body, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        data = json.loads(payload) if payload else None
        return resp.status, data

    def test_dag_archived_vs_live(self) -> None:
        status, live = self._req("GET", "/api/dag")
        self.assertEqual(status, 200)
        self.assertEqual([n["id"] for n in live["nodes"]], ["live-node"])
        status, arch = self._req("GET", f"/api/dag?plan={self.PID}")
        self.assertEqual(status, 200)
        self.assertEqual([n["id"] for n in arch["nodes"]], ["arch-node"])

    def test_timeline_and_raw_and_sessions_archived(self) -> None:
        status, _ = self._req("GET", f"/api/timeline?plan={self.PID}")
        self.assertEqual(status, 200)
        status, raw = self._req("GET", f"/api/raw/dag/dag.v0.json?plan={self.PID}")
        self.assertEqual(status, 200)
        self.assertIn("arch-node", raw["content"])
        status, sess = self._req("GET", f"/api/sessions?plan={self.PID}")
        self.assertEqual(status, 200)
        self.assertEqual(sess["schema"], "singular.codex.sessions.v0")

    def test_unknown_and_malformed_and_traversal_404(self) -> None:
        for pid in ("plan-does-not-exist", "not-a-plan", "plan-..%2F..%2Fx",
                    "../x", "plan-with/slash"):
            status, data = self._req("GET", f"/api/dag?plan={pid}")
            self.assertEqual(status, 404, pid)
            self.assertEqual(data, {"error": "unknown plan"}, pid)

    def test_post_settings_with_plan_is_400_and_no_write(self) -> None:
        status, data = self._req("POST", f"/api/settings?plan={self.PID}",
                                 body={"changes": {"SINGULAR_MAX_CONCURRENT": "9"}})
        self.assertEqual(status, 400)
        self.assertEqual(data, {"error": "archived plans are read-only"})
        self.assertEqual((self.live / "singular.config.json").read_text(), self._config_before)

    def test_state_ignores_plan_param(self) -> None:
        # /api/state is excluded: a valid ?plan= is ignored, live data served, 200.
        status, _ = self._req("GET", f"/api/state?plan={self.PID}")
        self.assertEqual(status, 200)

    def test_plans_lists_archived(self) -> None:
        status, data = self._req("GET", "/api/plans")
        self.assertEqual(status, 200)
        self.assertEqual(data["schema"], "singular.plans.v0")
        self.assertEqual([p["id"] for p in data["plans"]], [self.PID])


class ComputeCacheMultiSlotTests(unittest.TestCase):
    """0.8.0 _ComputeCache multi-slot LRU: alternating keys don't thrash, capacity
    evicts LRU, invalidate() clears all slots. Single-flight/TTL preserved."""

    def _counting_cache(self, ttl: float = 60.0):
        calls: list = []

        def compute(arg):
            calls.append(arg)
            return {"arg": arg}

        return srv._ComputeCache(compute, ttl), calls

    def test_alternating_keys_no_evict(self) -> None:
        cache, calls = self._counting_cache()
        for _ in range(3):
            self.assertEqual(cache.get("a", "a"), {"arg": "a"})
            self.assertEqual(cache.get("b", "b"), {"arg": "b"})
        # Only one compute per distinct key despite repeated alternation.
        self.assertEqual(calls, ["a", "b"])

    def test_capacity_eviction_lru(self) -> None:
        cache, calls = self._counting_cache()
        for k in ("a", "b", "c", "d", "e"):  # 5 keys, capacity 4 -> 'a' evicted
            cache.get(k, k)
        self.assertEqual(len(calls), 5)
        # b..e still cached (no recompute); a was evicted (recompute).
        for k in ("b", "c", "d", "e"):
            cache.get(k, k)
        self.assertEqual(len(calls), 5)
        cache.get("a", "a")
        self.assertEqual(calls[-1], "a")
        self.assertEqual(len(calls), 6)

    def test_invalidate_clears_all(self) -> None:
        cache, calls = self._counting_cache()
        cache.get("a", "a")
        cache.get("b", "b")
        self.assertEqual(len(calls), 2)
        cache.invalidate()
        cache.get("a", "a")
        cache.get("b", "b")
        self.assertEqual(len(calls), 4)

    def test_ttl_expiry_recomputes(self) -> None:
        cache, calls = self._counting_cache(ttl=0.05)
        cache.get("a", "a")
        cache.get("a", "a")
        self.assertEqual(len(calls), 1)
        time.sleep(0.08)
        cache.get("a", "a")
        self.assertEqual(len(calls), 2)


# --- 0.9.0 providers: fake agent-CLI stubs (case on "$*", the space-joined args) #
_FAKE_CLAUDE = """#!/bin/sh
case "$*" in
  "--version") echo "2.1.198 (Claude Code)" ;;
  "auth status") echo '{"loggedIn":true,"authMethod":"claude.ai","email":"claude@example.com","subscriptionType":"max"}' ; exit 0 ;;
  *) exit 1 ;;
esac
"""
_FAKE_CODEX = """#!/bin/sh
case "$*" in
  "--version") echo "codex-cli 0.144.1" ;;
  "login status") echo "Logged in using ChatGPT" ; exit 0 ;;
  *) exit 1 ;;
esac
"""
_FAKE_CURSOR = """#!/bin/sh
case "$*" in
  "--version") echo "2026.07.16-899851b" ;;
  "about --format json") echo '{"cliVersion":"2026.07.16-899851b","subscriptionTier":"Pro","userEmail":"cursor@example.com"}' ; exit 0 ;;
  *) exit 1 ;;
esac
"""
_FAKE_GEMINI = """#!/bin/sh
case "$*" in
  "--version") echo "0.42.0" ;;
  *) exit 1 ;;
esac
"""
_FAKE_OPENCODE = """#!/bin/sh
case "$*" in
  "--version") echo "1.16.2" ;;
  "auth list") printf 'Credentials ~/.local/share/opencode/auth.json\\n0 credentials\\n' ; exit 0 ;;
  *) exit 1 ;;
esac
"""


class CollectProvidersTests(unittest.TestCase):
    """S1: registry-driven runtime probes. Fake binaries on a test PATH + a fake
    HOME exercise version/auth parsing, the ready/warning/error/missing rollup,
    email/plan extraction, the secrets rule, singular-integration fields, and the
    60s cache. Probes read the injected env/home (collect_providers overrides)."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.repo = base / "repo"
        (self.repo / ".singular-state").mkdir(parents=True)
        (self.repo / "singular.config.json").write_text(
            json.dumps({"runner": "claude-run.sh", "env": {}}))
        # A seeded session-meta so claude reports lastUsed/exit/recentSessions.
        run = self.repo / ".singular-state/runs/RUN-20260101T000000Z-1"
        run.mkdir(parents=True)
        (run / "session-implementer.json").write_text(json.dumps({
            "schema": "singular.orchestration.session-meta.v0", "provider": "claude",
            "exitCode": 0, "createdAt": "2026-01-01T00:00:00Z", "role": "implementer"}))
        # Fake HOME: gemini in "gemini-api-key" mode but no key/creds -> unknown.
        self.home = base / "home"
        (self.home / ".gemini").mkdir(parents=True)
        (self.home / ".gemini/settings.json").write_text(
            json.dumps({"security": {"auth": {"selectedType": "gemini-api-key"}}}))
        # Fake PATH: all runtimes but grok (grok stays "missing").
        self.bindir = base / "bin"
        self.bindir.mkdir()
        for name, body in (("claude", _FAKE_CLAUDE), ("codex", _FAKE_CODEX),
                           ("cursor-agent", _FAKE_CURSOR), ("gemini", _FAKE_GEMINI),
                           ("opencode", _FAKE_OPENCODE)):
            p = self.bindir / name
            p.write_text(body)
            p.chmod(0o755)
        # Fake engine dir with only claude-run.sh present (gemini-run.sh absent).
        self.engine_home = base / "engine-home"
        (self.engine_home / "engine").mkdir(parents=True)
        (self.engine_home / "engine/claude-run.sh").write_text("")
        self.env = {"PATH": str(self.bindir), "HOME": str(self.home),
                    "SINGULAR_ENGINE_HOME": str(self.engine_home)}
        srv.initialize_configuration(self.repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        srv._PROVIDERS_CACHE.invalidate()
        self.addCleanup(srv._PROVIDERS_CACHE.invalidate)

    def _providers(self, env=None, home=None):
        payload = srv.collect_providers(self.repo, env=env or self.env,
                                        home=home or self.home)
        return payload, {p["id"]: p for p in payload["providers"]}

    def test_statuses_and_extraction(self) -> None:
        payload, by = self._providers()
        self.assertEqual(payload["schema"], "singular.providers.v0")
        # claude: ready, version, email + plan, method
        c = by["claude"]
        self.assertEqual((c["status"], c["installed"], c["version"]), ("ready", True, "2.1.198"))
        self.assertEqual((c["authStatus"], c["authMethod"]), ("authenticated", "claude.ai"))
        self.assertEqual((c["email"], c["plan"]), ("claude@example.com", "max"))
        # codex: ready via text probe
        self.assertEqual((by["codex"]["status"], by["codex"]["version"]), ("ready", "0.144.1"))
        self.assertEqual(by["codex"]["authMethod"], "ChatGPT")
        # cursor: ready via about --format json (email + tier)
        cur = by["cursor"]
        self.assertEqual((cur["status"], cur["version"]), ("ready", "2026.07.16-899851b"))
        self.assertEqual((cur["email"], cur["plan"]), ("cursor@example.com", "Pro"))
        # gemini: installed but auth unknown -> warning
        self.assertEqual((by["gemini"]["status"], by["gemini"]["authStatus"]), ("warning", "unknown"))
        self.assertEqual(by["gemini"]["authMethod"], "gemini-api-key")
        # opencode: 0 credentials -> unauthenticated -> error
        self.assertEqual((by["opencode"]["status"], by["opencode"]["authStatus"]),
                         ("error", "unauthenticated"))
        # openrouter: rides the installed opencode CLI, but OPENROUTER_API_KEY is
        # its own signal and it is unset here -> installed, auth unknown.
        orr = by["openrouter"]
        self.assertEqual((orr["status"], orr["installed"], orr["authStatus"]),
                         ("warning", True, "unknown"))
        # grok: not on PATH -> missing, no version, no subprocess
        self.assertEqual((by["grok"]["status"], by["grok"]["installed"], by["grok"]["version"]),
                         ("missing", False, None))
        self.assertEqual(payload["summary"]["ready"], 3)
        self.assertEqual(payload["summary"]["message"], "3 ready · 4 attention")

    def test_glue_fields_roles_default_runner_sessions(self) -> None:
        _payload, by = self._providers()
        c = by["claude"]
        self.assertTrue(c["isDefaultRunner"])            # runner=claude-run.sh
        self.assertEqual(c["roles"], ["auditor", "decider", "implementer", "planner"])
        self.assertTrue(c["runnerPresent"])              # claude-run.sh in fake engine
        self.assertGreaterEqual(c["recentSessions"], 1)
        self.assertEqual(c["lastExitCode"], 0)
        self.assertEqual(c["lastUsedAt"], "2026-01-01T00:00:00Z")
        # non-active providers: no roles, not default; gemini-run.sh absent
        self.assertEqual(by["codex"]["roles"], [])
        self.assertFalse(by["codex"]["isDefaultRunner"])
        self.assertFalse(by["gemini"]["runnerPresent"])

    def test_env_runner_override_wins(self) -> None:
        # config env{} SINGULAR_RUNNER overrides top-level "runner" (lib.sh order).
        (self.repo / "singular.config.json").write_text(json.dumps(
            {"runner": "codex-run.sh", "env": {"SINGULAR_RUNNER": "gemini-run.sh"}}))
        # External edits require a restart; this explicit reinitialization models it.
        srv.initialize_configuration(self.repo, force=True)
        payload, by = self._providers()
        self.assertEqual(payload["activeRunner"], "gemini-run.sh")
        self.assertEqual(payload["activeProvider"], "gemini")
        self.assertTrue(by["gemini"]["isDefaultRunner"])
        self.assertFalse(by["codex"]["isDefaultRunner"])
        self.assertTrue(by["gemini"]["roles"])           # active provider gets the roles

    def test_env_key_presence_authenticates(self) -> None:
        # No CLI probe for gemini; a GEMINI_API_KEY in env -> authenticated.
        env = dict(self.env, GEMINI_API_KEY="sk-fake")
        _payload, by = self._providers(env=env)
        self.assertEqual(by["gemini"]["authStatus"], "authenticated")
        self.assertIn("api-key", by["gemini"]["authMethod"])
        self.assertTrue(by["gemini"]["envKeyPresent"]["GEMINI_API_KEY"])

    def test_no_secret_values_leak(self) -> None:
        # Seed credential files with fake tokens; the payload must never carry them.
        (self.home / ".gemini/oauth_creds.json").write_text('{"access_token":"GEM_SECRET_TTT"}')
        oc = self.home / ".local/share/opencode"
        oc.mkdir(parents=True)
        (oc / "auth.json").write_text(json.dumps(
            {"anthropic": {"type": "oauth", "refresh": "OC_SECRET_RRR", "access": "OC_SECRET_AAA"}}))
        payload, _by = self._providers()
        blob = json.dumps(payload)
        for secret in ("GEM_SECRET_TTT", "OC_SECRET_RRR", "OC_SECRET_AAA"):
            self.assertNotIn(secret, blob)
        # And the opencode inference itself surfaces ids/types only, never values.
        spec = next(p for p in srv.PROVIDERS if p["id"] == "opencode")
        res = srv._infer_opencode(self.home, spec)
        self.assertEqual(res["authStatus"], "authenticated")
        self.assertIn("anthropic", res["detail"])
        self.assertEqual(res["credentialTypes"], ["oauth"])
        self.assertNotIn("OC_SECRET_RRR", json.dumps(res))

    def test_cache_ttl_and_refresh(self) -> None:
        # Default (no override) path is cached 60s; refresh=True bypasses.
        calls: list = []
        orig = srv._compute_providers

        def counting(repo, env, home):
            calls.append(str(repo))
            return {"schema": "singular.providers.v0", "providers": [], "summary": {}}

        srv._compute_providers = counting
        srv._PROVIDERS_CACHE.invalidate()
        try:
            srv.collect_providers(self.repo)
            srv.collect_providers(self.repo)
            self.assertEqual(len(calls), 1)            # second read served from cache
            srv.collect_providers(self.repo, refresh=True)
            self.assertEqual(len(calls), 2)            # refresh recomputed
        finally:
            srv._compute_providers = orig
            srv._PROVIDERS_CACHE.invalidate()

    def test_probes_never_use_shell(self) -> None:
        # Guard the SECRETS/injection posture: no probe uses shell=True.
        seen: list = []
        real = subprocess.run

        def record(*args, **kwargs):
            seen.append(kwargs.get("shell", False))
            return real(*args, **kwargs)

        saved = subprocess.run
        subprocess.run = record
        try:
            self._providers()
        finally:
            subprocess.run = saved
        self.assertTrue(seen)                     # probes did run
        self.assertFalse(any(seen))               # none with shell=True


class ProvidersRouteTests(unittest.TestCase):
    """S2: the HTTP layer for /api/providers + the runner-switch write path.
    PATH is pointed at an empty dir so probes short-circuit (deterministic, fast);
    probe correctness is covered by CollectProvidersTests."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.repo = base / "repo"
        (self.repo / ".singular-state").mkdir(parents=True)
        (self.repo / "singular.config.json").write_text(json.dumps({"env": {}}))
        self._config_before = (self.repo / "singular.config.json").read_text()
        empty = base / "empty-bin"
        empty.mkdir()
        self._saved_env = {k: os.environ.get(k) for k in ("PATH", "HOME")}
        os.environ["PATH"] = str(empty)          # all runtimes -> "missing", no subprocess
        os.environ["HOME"] = str(base / "home")

        def _restore_env() -> None:
            for k, v in self._saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

        self.addCleanup(_restore_env)
        srv.initialize_configuration(self.repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        for cache in (srv._PROVIDERS_CACHE, srv._CONFIG_CACHE, srv._OVERVIEW_CACHE):
            cache.invalidate()
        self.addCleanup(srv._PROVIDERS_CACHE.invalidate)
        self._saved_repo = srv.Handler.repo
        srv.Handler.repo = self.repo
        self.server = srv.ThreadingHTTPServer(("127.0.0.1", 0), srv.Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

        def _teardown() -> None:
            self.server.shutdown()
            self.server.server_close()
            self.thread.join()
            srv.Handler.repo = self._saved_repo

        self.addCleanup(_teardown)

    def _req(self, method: str, path: str, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        headers = {}
        raw = None
        if body is not None:
            raw = json.dumps(body).encode()
            headers = {"Content-Type": "application/json", "Content-Length": str(len(raw))}
        conn.request(method, path, body=raw, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        return resp.status, (json.loads(payload) if payload else None)

    def test_endpoint_payload(self) -> None:
        status, data = self._req("GET", "/api/providers")
        self.assertEqual(status, 200)
        self.assertEqual(data["schema"], "singular.providers.v0")
        ids = [p["id"] for p in data["providers"]]
        self.assertEqual(
            ids,
            ["claude", "codex", "gemini", "opencode", "cursor", "openrouter", "grok"],
        )
        for p in data["providers"]:
            self.assertEqual(p["status"], "missing")     # empty PATH
            self.assertIn("runnerScript", p)
        self.assertIn("message", data["summary"])

    def test_refresh_param(self) -> None:
        status, data = self._req("GET", "/api/providers?refresh=1")
        self.assertEqual(status, 200)
        self.assertEqual(data["schema"], "singular.providers.v0")

    def test_plan_param_ignored_live_only(self) -> None:
        # Unlike /api/dag, providers ignores ?plan= (live-only) -> 200, not 404.
        status, data = self._req("GET", "/api/providers?plan=plan-20260101T000000Z-x")
        self.assertEqual(status, 200)
        self.assertEqual(data["schema"], "singular.providers.v0")

    def test_runner_switch_roundtrip(self) -> None:
        calls = 0
        original = srv._compute_effective_configuration

        def counted(root):
            nonlocal calls
            calls += 1
            return original(root)

        with mock.patch.object(srv, "_compute_effective_configuration", counted):
            status, resp = self._req("POST", "/api/settings",
                                     body={"changes": {"SINGULAR_RUNNER": "gemini-run.sh"}})
            _s, cfg = self._req("GET", "/api/config")
            _s, prov = self._req("GET", "/api/providers")
        self.assertEqual(status, 200)
        self.assertEqual(calls, 1)
        self.assertEqual(resp["applied"]["SINGULAR_RUNNER"], "gemini-run.sh")
        env = json.loads((self.repo / "singular.config.json").read_text())["env"]
        self.assertEqual(env["SINGULAR_RUNNER"], "gemini-run.sh")
        # config + providers reflect the same replacement generation immediately.
        self.assertEqual(cfg["provider"], "gemini")
        self.assertEqual(cfg["generation"]["id"], prov["generation"]["id"])
        self.assertEqual(prov["activeRunner"], "gemini-run.sh")
        by = {p["id"]: p for p in prov["providers"]}
        self.assertTrue(by["gemini"]["isDefaultRunner"])

    def test_external_config_change_is_actionable_over_http(self) -> None:
        (self.repo / "singular.config.json").write_text(json.dumps({
            "runner": "gemini-run.sh", "env": {}}))
        status, cfg = self._req("GET", "/api/config")
        self.assertEqual(status, 200)
        self.assertEqual(cfg["configuration"]["reason"], "configuration-changed")
        status, lifecycle = self._req("GET", "/api/lifecycle")
        self.assertEqual(status, 200)
        self.assertTrue(lifecycle["configuration"]["restartRequired"])
        status, providers = self._req("GET", "/api/providers")
        self.assertEqual(status, 200)
        self.assertEqual(providers["activeProvider"], "unknown")
        self.assertFalse(any(row["isDefaultRunner"] for row in providers["providers"]))
        status, data = self._req("GET", "/api/dag")
        self.assertEqual(status, 409)
        self.assertEqual(data["configuration"]["reason"], "configuration-changed")

    def test_warmed_http_routes_share_invalidation_and_refresh_generation(self) -> None:
        fixtures = (
            ("old", "TASK-4101", "RUN-OLD", "plan-old"),
            ("new", "TASK-4202", "RUN-NEW", "plan-new"),
        )
        for label, task_id, run_id, plan_id in fixtures:
            tasks = self.repo / f"tasks-{label}"
            state = self.repo / f"state-{label}"
            tasks.mkdir()
            (state / "runs" / run_id).mkdir(parents=True)
            (state / "leases").mkdir()
            (state / "plans").mkdir()
            (tasks / f"{task_id}.md").write_text(
                f"# {task_id}: {label} fixture\n\nStatus: ready\nArea: diagnostic\n"
            )
            (state / "runs" / run_id / "run-status.json").write_text(json.dumps({
                "schema": "singular.orchestration.run-status.v0",
                "runId": run_id, "taskId": task_id, "state": "failed",
                "phase": "auditing", "updatedAt": "2026-09-12T12:00:00Z",
            }))
            (state / "plans" / "index.json").write_text(json.dumps({
                "plans": [{"id": plan_id, "name": f"{label} fixture",
                           "archivedAt": "2026-09-12T12:00:00Z"}]
            }))
        (self.repo / "singular.config.json").write_text(json.dumps({
            "runner": "codex-run.sh",
            "env": {"SINGULAR_TASKS_DIR": "tasks-old",
                    "SINGULAR_STATE_DIR": "state-old"},
        }))
        srv.initialize_configuration(self.repo, force=True)
        for cache in (
            srv._PROVIDERS_CACHE, srv._CONFIG_CACHE, srv._OVERVIEW_CACHE,
            srv._HOME_CACHE, srv._DAG_VIEW_CACHE, srv._TIMELINE_CACHE,
            srv._PLANS_CACHE, srv.SNAPSHOT_CACHE, srv.SESSIONS_CACHE,
        ):
            cache.invalidate()
        routes = (
            "/api/config", "/api/providers", "/api/overview", "/api/home",
            "/api/dag", "/api/timeline", "/api/lifecycle", "/api/settings",
            "/api/state", "/api/sessions", "/api/plans",
        )
        warm = {route: self._req("GET", route) for route in routes}
        self.assertTrue(all(status == 200 for status, _ in warm.values()))
        initial = warm["/api/config"][1]["generation"]["id"]
        self.assertIn("TASK-4101", {row["id"] for row in warm["/api/state"][1]["l2Tasks"]})
        self.assertIn("RUN-OLD", {row["id"] for row in warm["/api/sessions"][1]["sessions"]})
        self.assertEqual(["plan-old"], [row["id"] for row in warm["/api/plans"][1]["plans"]])

        (self.repo / "singular.config.json").write_text(json.dumps({
            "runner": "gemini-run.sh",
            "env": {"SINGULAR_MAX_CONCURRENT": "2",
                    "SINGULAR_TASKS_DIR": "tasks-new",
                    "SINGULAR_STATE_DIR": "state-new"},
        }))
        changed = {route: self._req("GET", route) for route in routes}
        for route in ("/api/config", "/api/providers", "/api/lifecycle"):
            self.assertEqual(changed[route][0], 200, route)
            self.assertEqual(changed[route][1]["generation"]["status"], "changed", route)
            self.assertNotEqual(changed[route], warm[route], route)
        providers = changed["/api/providers"][1]
        self.assertEqual(providers["activeProvider"], "unknown")
        self.assertIsNone(providers["activeRunner"])
        self.assertFalse(any(row["isDefaultRunner"] for row in providers["providers"]))
        for route in (
            "/api/overview", "/api/home", "/api/dag", "/api/timeline",
            "/api/settings", "/api/state", "/api/sessions", "/api/plans",
        ):
            self.assertEqual(changed[route][0], 409, route)
            self.assertEqual(
                changed[route][1]["configuration"]["reason"],
                "configuration-changed",
                route,
            )
            self.assertEqual(changed[route][1]["generation"]["status"], "changed", route)
            self.assertTrue(changed[route][1]["generation"]["restartRequired"], route)
            self.assertTrue(changed[route][1]["configuration"]["restartRequired"], route)
            self.assertNotEqual(changed[route], warm[route], route)

        status, response = self._req(
            "POST", "/api/settings",
            body={"changes": {"SINGULAR_MAX_CONCURRENT": "4"}},
        )
        self.assertEqual(status, 200)
        replacement = response["config"]["generation"]["id"]
        self.assertNotEqual(replacement, initial)
        refreshed = {route: self._req("GET", route) for route in routes}
        for route, (route_status, data) in refreshed.items():
            self.assertEqual(route_status, 200, route)
            self.assertEqual(data["generation"]["id"], replacement, route)
            self.assertEqual(data["generation"]["status"], "current", route)
        state = refreshed["/api/state"][1]
        sessions = refreshed["/api/sessions"][1]
        plans = refreshed["/api/plans"][1]
        lifecycle = refreshed["/api/lifecycle"][1]
        self.assertIn("TASK-4202", {row["id"] for row in state["l2Tasks"]})
        self.assertNotIn("TASK-4101", {row["id"] for row in state["l2Tasks"]})
        self.assertIn("RUN-NEW", {row["id"] for row in sessions["sessions"]})
        self.assertNotIn("RUN-OLD", {row["id"] for row in sessions["sessions"]})
        self.assertEqual(["plan-new"], [row["id"] for row in plans["plans"]])
        self.assertEqual(str((self.repo / "tasks-new").resolve()), lifecycle["paths"]["tasks"])
        self.assertEqual(str((self.repo / "state-new").resolve()), lifecycle["paths"]["state"])

    def test_http_reads_share_generation_past_former_ttls_and_concurrently(self) -> None:
        def forbidden(_root):
            raise AssertionError("configuration resolution replayed from a GET")

        base = time.monotonic()
        with mock.patch.object(srv, "_compute_effective_configuration", forbidden), \
                mock.patch.object(srv.time, "monotonic", return_value=base + 31):
            paths = ["/api/config", "/api/lifecycle", "/api/home", "/api/dag", "/api/asks"]
            with ThreadPoolExecutor(max_workers=len(paths)) as pool:
                results = list(pool.map(lambda path: self._req("GET", path), paths))
        self.assertTrue(all(status == 200 for status, _data in results))
        generations = [data["generation"]["id"] for _status, data in results[:3]]
        self.assertEqual(len(set(generations)), 1)

    def test_runner_switch_rejects_bad_values(self) -> None:
        for bad in ("evil.sh", "../claude-run.sh", "/etc/passwd", "claude-run.sh; rm -rf"):
            status, data = self._req("POST", "/api/settings",
                                     body={"changes": {"SINGULAR_RUNNER": bad}})
            self.assertEqual(status, 400, bad)
            self.assertIn("key", data)
        # nothing was written
        self.assertEqual((self.repo / "singular.config.json").read_text(), self._config_before)

    def test_new_provider_model_and_timeout_writable(self) -> None:
        status, resp = self._req("POST", "/api/settings", body={"changes": {
            "SINGULAR_GEMINI_MODEL": "gemini-3-pro", "SINGULAR_CURSOR_TIMEOUT_SEC": "600"}})
        self.assertEqual(status, 200)
        self.assertEqual(resp["applied"]["SINGULAR_GEMINI_MODEL"], "gemini-3-pro")
        self.assertEqual(resp["applied"]["SINGULAR_CURSOR_TIMEOUT_SEC"], "600")

    def test_providers_oneshot_pure_json(self) -> None:
        saved = {n: getattr(srv, n) for n in ADAPTER_GLOBALS}
        self.addCleanup(lambda: [setattr(srv, n, v) for n, v in saved.items()])
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = srv.main(["--repo", str(self.repo), "--providers"])
        self.assertEqual(rc, 0)
        data = json.loads(buf.getvalue())        # stdout is pure JSON
        self.assertEqual(data["schema"], "singular.providers.v0")
        self.assertEqual(len(data["providers"]), len(srv.PROVIDERS))


class CodexQuotaTests(unittest.TestCase):
    """B1: the Codex rollout quota probe. mtime beats the filename/day-dir date;
    the LAST rate_limits line wins; only the ~256KB tail is scanned; null
    primary/secondary and malformed lines degrade cleanly; a missing sessions dir
    is unavailable; staleSeconds derives from the file mtime. Reads ONLY rollout
    jsonl (never a credential file)."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)

    def _day_dir(self, base: dt.datetime, days_ago: int = 0) -> Path:
        d = base - dt.timedelta(days=days_ago)
        p = self.home / ".codex" / "sessions" / f"{d.year:04d}/{d.month:02d}/{d.day:02d}"
        p.mkdir(parents=True, exist_ok=True)
        return p

    def _line(self, used, *, plan="pro", window=10080, resets=1784950515,
              primary=True, secondary=None, extra=None) -> str:
        prim = ({"used_percent": used, "window_minutes": window, "resets_at": resets}
                if primary else None)
        payload = {"type": "token_count", "info": {"model_context_window": 200000},
                   "rate_limits": {"limit_id": "codex", "primary": prim,
                                   "secondary": secondary, "credits": {"balance": "0"},
                                   "plan_type": plan}}
        if extra:
            payload["info"]["note"] = extra
        return json.dumps({"timestamp": "t", "type": "event_msg", "payload": payload})

    def _write(self, day_dir: Path, name: str, lines: list[str],
               mtime: float | None = None) -> Path:
        p = day_dir / name
        p.write_text("\n".join(lines) + "\n")
        if mtime is not None:
            os.utime(p, (mtime, mtime))
        return p

    def test_mtime_beats_name(self) -> None:
        now = dt.datetime.now(dt.UTC)
        # An OLD-named file under an earlier day dir, but the freshest mtime.
        self._write(self._day_dir(now, days_ago=3), "rollout-2020-01-01T00-00-00-old.jsonl",
                    [self._line(42.0)], mtime=time.time())
        # A NEW-named file under today's dir, but a stale mtime.
        self._write(self._day_dir(now, days_ago=0), "rollout-2999-01-01T00-00-00-new.jsonl",
                    [self._line(10.0)], mtime=time.time() - 99999)
        q = srv._codex_quota(self.home)
        self.assertTrue(q["available"])
        self.assertEqual(q["usedPercent"], 42.0)   # newest mtime, not newest name

    def test_last_line_wins(self) -> None:
        now = dt.datetime.now(dt.UTC)
        self._write(self._day_dir(now), "rollout-a.jsonl",
                    [self._line(5.0), self._line(50.0), self._line(88.0)])
        q = srv._codex_quota(self.home)
        self.assertEqual(q["usedPercent"], 88.0)

    def test_tail_window_only(self) -> None:
        now = dt.datetime.now(dt.UTC)
        # A valid rate_limits line at the very start, then >256KB of padding with
        # no rate_limits: the tail read never reaches the start line.
        padding = ["x" * 200 for _ in range(1500)]  # ~300KB
        self._write(self._day_dir(now), "rollout-a.jsonl", [self._line(5.0), *padding])
        q = srv._codex_quota(self.home)
        self.assertFalse(q["available"])
        self.assertEqual(q["reason"], "no-rollout-data")

    def test_null_primary_and_secondary(self) -> None:
        now = dt.datetime.now(dt.UTC)
        self._write(self._day_dir(now), "rollout-a.jsonl",
                    [self._line(0.0, primary=False, secondary=None)])
        q = srv._codex_quota(self.home)
        self.assertEqual(q, {"available": False, "reason": "no-rollout-data"})

    def test_secondary_fallback(self) -> None:
        now = dt.datetime.now(dt.UTC)
        sec = {"used_percent": 55.0, "window_minutes": 300, "resets_at": 1784950000}
        self._write(self._day_dir(now), "rollout-a.jsonl",
                    [self._line(0.0, primary=False, secondary=sec)])
        q = srv._codex_quota(self.home)
        self.assertTrue(q["available"])
        self.assertEqual(q["usedPercent"], 55.0)     # top-level trio falls back to secondary
        self.assertIsNone(q["primary"])
        self.assertEqual(q["secondary"]["usedPercent"], 55.0)

    def test_malformed_lines_skipped(self) -> None:
        now = dt.datetime.now(dt.UTC)
        # A trailing line that contains the marker but is invalid JSON is skipped;
        # the earlier valid line is used.
        self._write(self._day_dir(now), "rollout-a.jsonl",
                    [self._line(20.0), '{"rate_limits": THIS IS BROKEN}'])
        q = srv._codex_quota(self.home)
        self.assertTrue(q["available"])
        self.assertEqual(q["usedPercent"], 20.0)

    def test_missing_sessions_dir(self) -> None:
        q = srv._codex_quota(self.home)   # nothing seeded
        self.assertEqual(q, {"available": False, "reason": "no-rollout"})

    def test_stale_seconds(self) -> None:
        now = dt.datetime.now(dt.UTC)
        self._write(self._day_dir(now), "rollout-a.jsonl", [self._line(30.0)],
                    mtime=time.time() - 8000)
        q = srv._codex_quota(self.home)
        self.assertTrue(q["available"])
        self.assertGreaterEqual(q["staleSeconds"], 7900)

    def test_byname_fallback_when_no_dated_dir(self) -> None:
        # A rollout under a very old (out-of-lookback) day dir is still found via
        # the by-name fallback (newest year/month/day by name).
        old = self.home / ".codex" / "sessions" / "2019" / "05" / "05"
        old.mkdir(parents=True)
        (old / "rollout-x.jsonl").write_text(self._line(7.0) + "\n")
        q = srv._codex_quota(self.home)
        self.assertTrue(q["available"])
        self.assertEqual(q["usedPercent"], 7.0)


class ProvidersQuotaFieldTests(unittest.TestCase):
    """B2: the additive per-provider `quota` field on collect_providers. Codex
    surfaces real rollout usage; cursor is tier-only; claude is not-exposed; an
    absent CLI is cli-missing. The secrets rule is re-verified over the new
    payload — the quota path reads only rollout jsonl, never a credential file."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.repo = base / "repo"
        (self.repo / ".singular-state").mkdir(parents=True)
        (self.repo / "singular.config.json").write_text(
            json.dumps({"runner": "codex-run.sh", "env": {}}))
        self.home = base / "home"
        self.home.mkdir()
        # Fake PATH: codex + cursor-agent + claude installed; grok absent.
        self.bindir = base / "bin"
        self.bindir.mkdir()
        for name, body in (("codex", _FAKE_CODEX), ("cursor-agent", _FAKE_CURSOR),
                           ("claude", _FAKE_CLAUDE)):
            p = self.bindir / name
            p.write_text(body)
            p.chmod(0o755)
        self.env = {"PATH": str(self.bindir), "HOME": str(self.home)}
        srv.initialize_configuration(self.repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        srv._PROVIDERS_CACHE.invalidate()
        self.addCleanup(srv._PROVIDERS_CACHE.invalidate)

    def _seed_rollout(self, extra: str | None = None) -> None:
        day = dt.datetime.now(dt.UTC)
        d = self.home / ".codex/sessions" / f"{day.year:04d}/{day.month:02d}/{day.day:02d}"
        d.mkdir(parents=True)
        rl = {"limit_id": "codex",
              "primary": {"used_percent": 30.0, "window_minutes": 10080, "resets_at": 1784950515},
              "secondary": None, "credits": {"balance": "0"}, "plan_type": "prolite"}
        info = {"note": extra} if extra else {}
        (d / "rollout-x.jsonl").write_text(json.dumps(
            {"timestamp": "t", "type": "event_msg",
             "payload": {"type": "token_count", "info": info, "rate_limits": rl}}) + "\n")

    def _providers(self):
        payload = srv.collect_providers(self.repo, env=self.env, home=self.home)
        return payload, {p["id"]: p for p in payload["providers"]}

    def test_codex_quota_available(self) -> None:
        self._seed_rollout()
        _payload, by = self._providers()
        q = by["codex"]["quota"]
        self.assertTrue(q["available"])
        self.assertEqual(q["usedPercent"], 30.0)
        self.assertEqual(q["planType"], "prolite")
        self.assertEqual(q["source"], "rollout")
        self.assertIn("resetsAt", q)
        self.assertIn("staleSeconds", q)

    def test_dispatch_by_provider(self) -> None:
        self._seed_rollout()
        _payload, by = self._providers()
        self.assertEqual(by["claude"]["quota"], {"available": False, "reason": "not-exposed"})
        self.assertEqual(by["cursor"]["quota"], {"available": False, "reason": "tier-only"})
        self.assertEqual(by["grok"]["quota"], {"available": False, "reason": "cli-missing"})

    def test_codex_installed_but_no_rollout(self) -> None:
        _payload, by = self._providers()   # codex on PATH, no sessions dir
        self.assertFalse(by["codex"]["quota"]["available"])
        self.assertEqual(by["codex"]["quota"]["reason"], "no-rollout")

    def test_no_secret_values_leak_via_quota(self) -> None:
        # A secret in a NON-rate_limits field of the rollout line must not surface;
        # neither must a credential-file token (the quota path never reads it — codex
        # auth resolves via the CLI probe / existence check, not by reading the file).
        self._seed_rollout(extra="ROLLOUT_SECRET_XYZ")
        (self.home / ".codex/auth.json").write_text('{"OPENAI_API_KEY":"CODEX_SECRET_KKK"}')
        payload, by = self._providers()
        self.assertTrue(by["codex"]["quota"]["available"])
        blob = json.dumps(payload)
        for secret in ("ROLLOUT_SECRET_XYZ", "CODEX_SECRET_KKK"):
            self.assertNotIn(secret, blob)


class CollectHomeSupervisorTests(unittest.TestCase):
    """C1: collect_home's additive supervisor fields — loop from STATUS.md,
    briefing filtered from supervisor/latest.json (None when absent), supervisor
    {intervalMin, enabled} from config env. Schema stays singular.codex.home.v0."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state").mkdir()
        (repo / "docs/orchestration/tasks").mkdir(parents=True)
        srv._HOME_CACHE.invalidate()
        self.addCleanup(srv._HOME_CACHE.invalidate)
        return repo

    def test_absent_supervisor_fields(self) -> None:
        home = srv.collect_home(self._repo())
        self.assertEqual(home["schema"], "singular.codex.home.v0")
        self.assertIsNone(home["briefing"])
        self.assertEqual(home["supervisor"], {"intervalMin": 0, "enabled": False})
        self.assertEqual(home["loop"], {"iteration": None, "note": None, "updatedAt": None})

    def test_loop_from_status_md(self) -> None:
        repo = self._repo()
        (repo / ".singular-state/STATUS.md").write_text(
            "# singular Autonomous Status\n\nIteration: 7\nNote: grinding core\n"
            "Updated: 2026-07-18T00:00:00Z\n")
        home = srv.collect_home(repo)
        self.assertEqual(home["loop"]["iteration"], 7)
        self.assertEqual(home["loop"]["note"], "grinding core")
        self.assertEqual(home["loop"]["updatedAt"], "2026-07-18T00:00:00Z")

    def test_briefing_filtered_and_capped(self) -> None:
        repo = self._repo()
        sup = repo / ".singular-state/supervisor"
        sup.mkdir()
        (sup / "latest.json").write_text(json.dumps({
            "schema": "singular.orchestration.supervisor-report.v0",
            "stage": "working core", "narrative": "x" * 5000,
            "risks": ["disk"], "nextSteps": ["watch"],
            "proposedSettings": {"SINGULAR_MAX_CONCURRENT": "2"},
            "generatedAt": "2026-07-18T00:00:00Z", "runId": "SUP-1",
            "unknownExtra": "should-be-dropped"}))
        home = srv.collect_home(repo)
        b = home["briefing"]
        self.assertEqual(b["stage"], "working core")
        self.assertEqual(len(b["narrative"]), 4000)      # narrative capped
        self.assertNotIn("unknownExtra", b)              # filtered to known keys
        self.assertEqual(b["proposedSettings"], {"SINGULAR_MAX_CONCURRENT": "2"})
        self.assertEqual(b["runId"], "SUP-1")

    def test_supervisor_enabled_from_config(self) -> None:
        repo = self._repo()
        (repo / "singular.config.json").write_text(json.dumps(
            {"env": {"SINGULAR_SUPERVISOR_INTERVAL_MIN": "15"}}))
        srv.initialize_configuration(repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        home = srv.collect_home(repo)
        self.assertEqual(home["supervisor"], {"intervalMin": 15, "enabled": True})
        # invalid / zero -> disabled
        (repo / "singular.config.json").write_text(json.dumps(
            {"env": {"SINGULAR_SUPERVISOR_INTERVAL_MIN": "nope"}}))
        srv.initialize_configuration(repo, force=True)
        srv._HOME_CACHE.invalidate()
        self.assertFalse(srv.collect_home(repo)["supervisor"]["enabled"])


class CollectAskTests(unittest.TestCase):
    """C2: collect_ask state derivation + safety. Covers pending/running/done/
    timeout passthrough, the crash rule (running + dead pid + stale ask.json →
    error), proposedSettings whitelist filtering, the answer cap, id-regex + path
    containment rejection, and the newest-first /api/asks list."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state/runs").mkdir(parents=True)
        return repo

    def _ask(self, repo: Path, run_id: str, ask_doc: dict, *,
             answer: str | None = None, mtime: float | None = None) -> Path:
        run_dir = repo / ".singular-state/runs" / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        (run_dir / "ask.json").write_text(json.dumps(ask_doc))
        if answer is not None:
            (run_dir / "answer.md").write_text(answer)
        if mtime is not None:
            os.utime(run_dir / "ask.json", (mtime, mtime))
        return run_dir

    def test_done_with_answer_and_proposed_whitelist(self) -> None:
        repo = self._repo()
        self._ask(repo, "ASK-1", {"state": "done", "question": "status?",
                  "proposedSettings": {"SINGULAR_MAX_CONCURRENT": "4", "DATABASE_URL": "nope"},
                  "answeredAt": "2026-07-18T00:00:00Z"}, answer="all good")
        d = srv.collect_ask(repo, "ASK-1")
        self.assertEqual(d["state"], "done")
        self.assertEqual(d["answer"], "all good")
        self.assertEqual(d["proposedSettings"], {"SINGULAR_MAX_CONCURRENT": "4"})  # non-whitelist dropped

    def test_pending_and_running_passthrough(self) -> None:
        repo = self._repo()
        self._ask(repo, "ASK-2", {"state": "pending"})
        self.assertEqual(srv.collect_ask(repo, "ASK-2")["state"], "pending")
        self._ask(repo, "ASK-3", {"state": "running", "pid": os.getpid()})  # live pid
        self.assertEqual(srv.collect_ask(repo, "ASK-3")["state"], "running")

    def test_crash_rule(self) -> None:
        repo = self._repo()
        # running + dead pid + stale (>60s) ask.json -> error
        self._ask(repo, "ASK-4", {"state": "running", "pid": 999999999},
                  mtime=time.time() - 120)
        self.assertEqual(srv.collect_ask(repo, "ASK-4")["state"], "error")
        # running + dead pid but FRESH ask.json -> still running (not yet stale)
        self._ask(repo, "ASK-5", {"state": "running", "pid": 999999999})
        self.assertEqual(srv.collect_ask(repo, "ASK-5")["state"], "running")

    def test_timeout_passthrough(self) -> None:
        repo = self._repo()
        self._ask(repo, "ASK-6", {"state": "timeout"})
        self.assertEqual(srv.collect_ask(repo, "ASK-6")["state"], "timeout")

    def test_answer_capped(self) -> None:
        repo = self._repo()
        self._ask(repo, "ASK-7", {"state": "done"}, answer="y" * (srv.ASK_ANSWER_CAP + 500))
        self.assertEqual(len(srv.collect_ask(repo, "ASK-7")["answer"]), srv.ASK_ANSWER_CAP)

    def test_bad_id_and_missing_dir(self) -> None:
        repo = self._repo()
        self.assertIsNone(srv.collect_ask(repo, "NOTASK-1"))     # wrong prefix
        self.assertIsNone(srv.collect_ask(repo, "ASK-../etc"))   # traversal chars
        self.assertIsNone(srv.collect_ask(repo, "ASK-nonexistent"))  # regex-ok, absent

    def test_collect_asks_newest_first(self) -> None:
        repo = self._repo()
        self._ask(repo, "ASK-a", {"state": "done"}, answer="a", mtime=time.time() - 100)
        self._ask(repo, "ASK-b", {"state": "pending"}, mtime=time.time())
        payload = srv.collect_asks(repo)
        self.assertEqual(payload["schema"], "singular.orchestration.asks.v0")
        self.assertEqual([a["runId"] for a in payload["asks"]], ["ASK-b", "ASK-a"])


class AskReportRouteTests(unittest.TestCase):
    """C3: the /api/ask + /api/report write routes over HTTP. Popen is monkeypatched
    (no engine script actually runs) so we can assert the 202 + staged files + argv
    shape (list argv, never shell, start_new_session, question NOT in argv), the 429
    busy/throttle guards, the 400s (long question, ?plan=), and 404s. GET
    /api/ask/<id> + /api/asks are exercised too."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        (self.repo / ".singular-state/runs").mkdir(parents=True)
        (self.repo / "singular.config.json").write_text('{"env": {}}')
        srv.initialize_configuration(self.repo, force=True)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)
        # Monkeypatch Popen: record every call, never launch anything.
        self.popen_calls: list = []
        real_popen = srv.subprocess.Popen

        def fake_popen(argv, **kwargs):
            self.popen_calls.append((argv, kwargs))

            class _Handle:
                pid = 4242
            return _Handle()

        srv.subprocess.Popen = fake_popen
        self.addCleanup(lambda: setattr(srv.subprocess, "Popen", real_popen))
        self._saved_repo = srv.Handler.repo
        srv.Handler.repo = self.repo
        self.server = srv.ThreadingHTTPServer(("127.0.0.1", 0), srv.Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

        def _teardown() -> None:
            self.server.shutdown()
            self.server.server_close()
            self.thread.join()
            srv.Handler.repo = self._saved_repo

        self.addCleanup(_teardown)

    def _req(self, method: str, path: str, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        headers = {}
        raw = None
        if body is not None:
            raw = json.dumps(body).encode()
            headers = {"Content-Type": "application/json", "Content-Length": str(len(raw))}
        conn.request(method, path, body=raw, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        return resp.status, (json.loads(payload) if payload else None)

    def test_post_ask_202_stages_files_and_argv_shape(self) -> None:
        secret = "SEEKRIT_QUESTION_MARKER"
        status, data = self._req("POST", "/api/ask",
                                 body={"question": f"what is {secret} status?"})
        self.assertEqual(status, 202)
        run_id = data["runId"]
        self.assertTrue(srv.ASK_ID_RE.match(run_id))
        run_dir = self.repo / ".singular-state/runs" / run_id
        self.assertTrue((run_dir / "question.md").is_file())
        self.assertTrue((run_dir / "ask.json").is_file())
        self.assertEqual(json.loads((run_dir / "ask.json").read_text())["state"], "pending")
        # exactly one spawn, correct argv/kwargs shape
        self.assertEqual(len(self.popen_calls), 1)
        argv, kwargs = self.popen_calls[0]
        self.assertEqual(argv[0], "bash")
        self.assertTrue(argv[1].endswith("engine/ask.sh"))
        self.assertEqual(argv[2:], ["--run-id", run_id])
        self.assertTrue(kwargs.get("start_new_session"))
        self.assertNotIn("shell", kwargs)                       # never shell=True
        self.assertEqual(kwargs.get("cwd"), str(self.repo.resolve()))
        # the question NEVER appears in the argv, but IS staged on disk
        self.assertNotIn(secret, " ".join(str(a) for a in argv))
        self.assertIn(secret, (run_dir / "question.md").read_text())

    def test_busy_guard_429(self) -> None:
        run_dir = self.repo / ".singular-state/runs/ASK-busy"
        run_dir.mkdir(parents=True)
        (run_dir / "ask.json").write_text(json.dumps(
            {"state": "running", "pid": os.getpid(), "runId": "ASK-busy"}))
        status, data = self._req("POST", "/api/ask", body={"question": "hi"})
        self.assertEqual(status, 429)
        self.assertEqual(data["activeRunId"], "ASK-busy")
        self.assertEqual(len(self.popen_calls), 0)              # nothing spawned

    def test_ask_400s(self) -> None:
        status, data = self._req("POST", "/api/ask?plan=plan-x", body={"question": "hi"})
        self.assertEqual(status, 400)                            # ?plan= rejected first
        self.assertEqual(data, {"error": "archived plans are read-only"})
        status, _ = self._req("POST", "/api/ask", body={"question": "y" * 2001})
        self.assertEqual(status, 400)                            # >2000 chars
        status, _ = self._req("POST", "/api/ask", body={"question": "   "})
        self.assertEqual(status, 400)                            # empty
        status, _ = self._req("POST", "/api/ask", body={"nope": 1})
        self.assertEqual(status, 400)                            # missing question
        self.assertEqual(len(self.popen_calls), 0)

    def test_get_ask_and_asks_and_404(self) -> None:
        run_dir = self.repo / ".singular-state/runs/ASK-x"
        run_dir.mkdir(parents=True)
        (run_dir / "ask.json").write_text(json.dumps(
            {"state": "done", "runId": "ASK-x", "question": "q",
             "proposedSettings": {"SINGULAR_MAX_CONCURRENT": "3"}}))
        (run_dir / "answer.md").write_text("here is the answer")
        status, data = self._req("GET", "/api/ask/ASK-x")
        self.assertEqual(status, 200)
        self.assertEqual(data["state"], "done")
        self.assertEqual(data["answer"], "here is the answer")
        self.assertEqual(data["proposedSettings"], {"SINGULAR_MAX_CONCURRENT": "3"})
        status, data = self._req("GET", "/api/asks")
        self.assertEqual(status, 200)
        self.assertIn("ASK-x", [a["runId"] for a in data["asks"]])
        status, _ = self._req("GET", "/api/ask/ASK-nope")
        self.assertEqual(status, 404)
        self.assertEqual(self.popen_calls, [])

    def test_post_report_202_and_throttle(self) -> None:
        status, data = self._req("POST", "/api/report")
        self.assertEqual(status, 202)
        self.assertEqual(data["state"], "requested")
        self.assertEqual(len(self.popen_calls), 1)
        argv, kwargs = self.popen_calls[0]
        self.assertTrue(argv[1].endswith("engine/supervise.sh"))
        self.assertEqual(argv[2:], ["--once"])
        self.assertTrue(kwargs.get("start_new_session"))
        # a fresh SUP run dir now throttles a second request (<60s)
        (self.repo / ".singular-state/runs/SUP-recent").mkdir(parents=True)
        status, data = self._req("POST", "/api/report")
        self.assertEqual(status, 429)
        self.assertIn("retryAfterSeconds", data)


class SessionsAssistantTests(unittest.TestCase):
    """C4: SUP-/ASK- run dirs are discovered as kind "assistant" (label = question
    head or "supervisor briefing"); recommend_auto never auto-selects them; the
    assistant-codex.log streams through read_session."""

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state/runs").mkdir(parents=True)
        return repo

    def _run(self, repo: Path, name: str, files: dict) -> Path:
        run_dir = repo / ".singular-state/runs" / name
        run_dir.mkdir(parents=True)
        for fname, content in files.items():
            (run_dir / fname).write_text(content)
        return run_dir

    def test_ask_classified_assistant_with_label(self) -> None:
        repo = self._repo()
        self._run(repo, "ASK-1", {
            "assistant-codex.log": "chatter\n",
            "ask.json": json.dumps({"state": "done", "question": "where are we in the plan?"}),
            "answer.md": "we are here"})
        ask = next(s for s in srv.discover_sessions(repo) if s["id"] == "ASK-1")
        self.assertEqual(ask["kind"], "assistant")
        self.assertEqual(ask["role"], "assistant")
        self.assertIn("where are we", ask["label"])
        self.assertTrue(any(f["name"] == "assistant-codex.log" for f in ask["logFiles"]))

    def test_supervisor_classified_assistant(self) -> None:
        repo = self._repo()
        self._run(repo, "SUP-1", {
            "supervisor-codex.log": "chatter\n",
            "session-supervisor.json": json.dumps({"role": "supervisor"}),
            "report-raw.json": "{}"})
        sup = next(s for s in srv.discover_sessions(repo) if s["id"] == "SUP-1")
        self.assertEqual(sup["kind"], "assistant")
        self.assertEqual(sup["label"], "supervisor briefing")

    def test_recommend_auto_never_picks_assistant(self) -> None:
        auto = srv.recommend_auto([{"id": "ASK-1", "kind": "assistant", "live": True}])
        self.assertEqual(auto, {"mode": "origin", "sessionIds": ["origin"]})

    def test_read_session_streams_assistant_log(self) -> None:
        repo = self._repo()
        self._run(repo, "ASK-2", {
            "assistant-codex.log": "assistant runner chatter\n",
            "ask.json": json.dumps({"state": "done", "question": "q"})})
        data = srv.read_session(repo, "ASK-2", None, 500, None, False)
        self.assertIsNotNone(data)
        self.assertEqual(data["file"], "assistant-codex.log")
        self.assertTrue(any("assistant runner chatter" in json.dumps(line)
                            for line in data["lines"]))

    def test_stale_adapter_cannot_strip_assistant_logs(self) -> None:
        # singular console always launches the server with SINGULAR_ENGINE_HOME set,
        # and a pre-0.10 adapter snapshot's logFileMaps replaces CODEX_LOG_NAMES /
        # PROMPT_FILE_NAMES wholesale (without the assistant names). The pinned
        # ASSISTANT_* constants must keep ASK-/SUP- runs streaming regardless.
        apply_adapter_with_restore(self, {
            "schema": "singular.console-adapter.v0",
            "logFileMaps": {"codexLogs": [["worker-codex.log", "worker"],
                                          ["planner-codex.log", "planner"],
                                          ["decider-codex.log", "decider"]],
                            "plainLogs": ["gate-check.log"]}})
        repo = self._repo()
        self._run(repo, "ASK-9", {
            "assistant-codex.log": "assistant runner chatter\n",
            "ask-prompt.md": "rendered prompt\n",
            "ask.json": json.dumps({"state": "done", "question": "q"})})
        data = srv.read_session(repo, "ASK-9", None, 500, None, False)
        self.assertIsNotNone(data)
        self.assertEqual(data["file"], "assistant-codex.log")   # still the primary stream
        names = [f["name"] for f in data["logFiles"]]
        self.assertIn("ask-prompt.md", names)                    # prompt pane survives too


class HeadProbeTests(unittest.TestCase):
    """0.11.x: HEAD reachability probes (ranger-cli/uptime checks) get headers
    instead of BaseHTTPRequestHandler's 501: 200 for / and /api/health, 404
    elsewhere, never a body."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._saved_repo = srv.Handler.repo
        srv.Handler.repo = Path(self._tmp.name)
        self.server = srv.ThreadingHTTPServer(("127.0.0.1", 0), srv.Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

        def _teardown() -> None:
            self.server.shutdown()
            self.server.server_close()
            self.thread.join()
            srv.Handler.repo = self._saved_repo
        self.addCleanup(_teardown)

    def _head(self, path: str):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        conn.request("HEAD", path)
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp.status, body

    def test_root_ok_no_body(self) -> None:
        status, body = self._head("/")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")

    def test_health_ok(self) -> None:
        status, body = self._head("/api/health")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")

    def test_unknown_404(self) -> None:
        status, _ = self._head("/api/state")
        self.assertEqual(status, 404)


class SnapshotLoopLivenessTests(unittest.TestCase):
    """0.11.0: snap["loop"] carries honest autonomate-daemon liveness (pidfile +
    signal-0), distinct from agents.l0.state's process-count heuristic."""

    def test_no_pidfile(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".singular-state").mkdir()
            self.assertEqual(srv._snapshot_loop_liveness(repo), {"pid": None, "alive": False})

    def test_dead_pid(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".singular-state").mkdir()
            (repo / ".singular-state" / "autonomate.pid").write_text("999999999\n")
            out = srv._snapshot_loop_liveness(repo)
            self.assertEqual(out["pid"], 999999999)
            self.assertFalse(out["alive"])

    def test_live_pid(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".singular-state").mkdir()
            (repo / ".singular-state" / "autonomate.pid").write_text(f"{os.getpid()}\n")
            out = srv._snapshot_loop_liveness(repo)
            self.assertEqual(out["pid"], os.getpid())
            self.assertTrue(out["alive"])


class FieldReportLifecycleAndDiagnosticTests(unittest.TestCase):
    def test_run_status_overrides_worker_file_inference(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            run = repo / ".singular-state" / "runs" / "RUN-auditing"
            run.mkdir(parents=True)
            (run / "worker-codex.log").write_text("{}\n")
            (run / "gate-check.json").write_text('{"exitCode":0}\n')
            (run / "auditor-codex.log").write_text("{}\n")
            (run / "run-status.json").write_text(json.dumps({
                "schema": "singular.orchestration.run-status.v0",
                "runId": "RUN-auditing",
                "taskId": "TASK-0001",
                "phase": "auditing",
                "state": "active",
                "process": {
                    "type": "auditor",
                    "pid": 4321,
                    "startedAt": "2026-07-24T10:00:00Z",
                },
                "phaseStartedAt": "2026-07-24T10:01:00Z",
                "lastProgressAt": "2026-07-24T10:02:00Z",
                "currentActivity": "rerunning Vitest",
                "safeCancel": True,
                "nextAction": "record verdict",
                "updatedAt": "2026-07-24T10:02:00Z",
            }))
            rows = srv.discover_sessions(repo)
            row = next(item for item in rows if item["id"] == "RUN-auditing")
            self.assertEqual(row["kind"], "audit")
            self.assertEqual(row["phase"], "auditing")
            self.assertEqual(row["role"], "auditor")
            self.assertEqual(row["pid"], 4321)
            self.assertEqual(row["implementerState"], "completed")
            self.assertEqual(row["currentActivity"], "rerunning Vitest")

    def test_optional_warning_is_deduplicated_and_raw_is_unchanged(self) -> None:
        lines = [
            "2026-07-24T10:00:00Z WARN model cache unknown field supports_reasoning_summaries",
            "2026-07-24T10:00:01Z WARN model cache unknown field supports_reasoning_summaries",
        ]
        parsed = srv.parse_log_lines(lines)
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["count"], 2)
        self.assertEqual(
            parsed[0]["diagnostic"]["category"],
            "optional-dependency-warning",
        )
        raw = srv.parse_log_lines(lines, raw=True)
        self.assertEqual([item["text"] for item in raw], lines)

    def test_structured_categories(self) -> None:
        provider = srv.classify_codex_record({
            "schema": "singular.orchestration.provider-error.v0",
            "provider": "codex",
            "kind": "usage-limit",
            "eventType": "turn.failed",
            "retryable": True,
            "excerpt": "usage limit",
            "recordedAt": "2026-07-24T10:00:00Z",
        })
        self.assertEqual(provider["diagnostic"]["category"], "provider-failure")
        baseline = srv.classify_codex_record({
            "schema": "singular.orchestration.gate-report.v0",
            "outcome": "passed-with-acknowledged-baseline",
        })
        self.assertEqual(
            baseline["diagnostic"]["category"],
            "acknowledged-baseline",
        )
        product = srv.classify_codex_record({
            "schema": "singular.orchestration.gate-report.v0",
            "outcome": "failed-product",
        })
        self.assertEqual(product["diagnostic"]["category"], "product-failure")
        infrastructure = srv.classify_codex_record({
            "schema": "singular.orchestration.gate-report.v0",
            "outcome": "inconclusive-infrastructure",
        })
        self.assertEqual(
            infrastructure["diagnostic"]["category"],
            "infrastructure-inconclusive",
        )
        orchestration = srv.classify_codex_record({
            "type": "l1.audit_invalid",
            "message": "invalid audit verdict",
        })
        self.assertEqual(
            orchestration["diagnostic"]["category"],
            "orchestration-failure",
        )
        informational = srv.classify_codex_record({
            "type": "l1.audit_completed",
            "message": "audit completed",
        })
        self.assertEqual(informational["diagnostic"]["category"], "info")
        optional = srv.parse_log_lines(
            ["WARN optional MCP server failed to start"]
        )[0]
        self.assertEqual(
            optional["diagnostic"]["category"],
            "optional-dependency-warning",
        )

    def test_human_gate_api_exposes_owner_staleness_and_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            orch = repo / "docs" / "orchestration"
            gates = orch / "human-gates"
            gates.mkdir(parents=True)
            artifact = repo / "release.txt"
            artifact.write_text("approved bytes\n")
            evidence_path = repo / "review.txt"
            evidence_path.write_text("review evidence\n")
            request_ref = "docs/orchestration/human-gates/release.human-gate.json"
            approval_ref = "docs/orchestration/human-gates/release.human-approval.json"
            request = {
                "schema": "singular.orchestration.human-gate.v0",
                "gateId": "release",
                "node": "release",
                "approvalType": "exact-artifact",
                "requiredOwner": "owner@example.com",
                "questions": [{"id": "risk", "prompt": "Accept?", "required": True}],
                "artifacts": [{
                    "ref": "release.txt",
                    "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                }],
                "blockedNodes": ["deploy"],
                "createdAt": "2026-07-24T10:00:00Z",
                "expiresAt": "2099-07-25T10:00:00Z",
            }
            request_path = repo / request_ref
            request_path.write_text(json.dumps(request))
            approval = {
                "schema": "singular.orchestration.human-approval.v0",
                "gateId": "release",
                "node": "release",
                "requestRef": request_ref,
                "requestSha256": hashlib.sha256(request_path.read_bytes()).hexdigest(),
                "approver": "owner@example.com",
                "decision": "approved",
                "answers": {"risk": "yes"},
                "artifacts": request["artifacts"],
                "evidence": [{
                    "ref": "review.txt",
                    "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
                }],
                "rationale": "approved",
                "approvedAt": "2026-07-24T11:00:00Z",
                "expiresAt": "2099-07-25T10:00:00Z",
            }
            (repo / approval_ref).write_text(json.dumps(approval))
            (orch / "dag.v0.json").write_text(json.dumps({
                "schema": "singular.orchestration.dag.v0",
                "nodes": [
                    {
                        "id": "release", "dependsOn": [],
                        "humanGate": {
                            "requestRef": request_ref,
                            "approvalRef": approval_ref,
                        },
                    },
                    {"id": "deploy", "dependsOn": ["release"]},
                ],
            }))
            self.assertEqual(srv.collect_human_gates(repo)[0]["state"], "approved")
            session_payload = srv.collect_sessions(repo)
            self.assertEqual(session_payload["humanGates"][0]["state"], "approved")
            self.assertIn("effectiveSlots", session_payload["resources"])

            approval_path = repo / approval_ref
            malformed_approval = dict(approval)
            malformed_approval.pop("requestRef")
            approval_path.write_text(json.dumps(malformed_approval))
            row = srv.collect_human_gates(repo)[0]
            self.assertEqual(row["state"], "invalid")
            self.assertIn("requestRef", row["reason"])

            malformed_approval = dict(approval)
            malformed_approval["evidence"] = []
            approval_path.write_text(json.dumps(malformed_approval))
            row = srv.collect_human_gates(repo)[0]
            self.assertEqual(row["state"], "invalid")
            self.assertIn("non-empty", row["reason"])

            approval_path.write_text(json.dumps(approval))
            malformed_request = dict(request)
            malformed_request["createdAt"] = malformed_request["expiresAt"]
            request_path.write_text(json.dumps(malformed_request))
            row = srv.collect_human_gates(repo)[0]
            self.assertEqual(row["state"], "invalid")
            self.assertIn("after creation", row["reason"])

            request_path.write_text(json.dumps(request))
            approval["requestSha256"] = hashlib.sha256(request_path.read_bytes()).hexdigest()
            approval_path.write_text(json.dumps(approval))
            artifact.write_text("changed\n")
            row = srv.collect_human_gates(repo)[0]
            self.assertEqual(row["state"], "stale")
            self.assertEqual(row["owner"], "owner@example.com")
            self.assertEqual(row["blockedNodes"], ["deploy"])


# Synthetic credentials, assembled at import time from harmless halves.
#
# They are NEVER written as literals: engine/secret-scan.sh scans added lines on
# every commit and would (correctly) refuse a file containing a credential-shaped
# string. Weakening the gate to accommodate its own tests would be exactly
# backwards, so the fixtures dodge it by construction instead.
FAKE = {
    "jwt-bearer-token": "eyJ" + "hbGciOiJIUzI1NiJ9." + "eyJ" + "zdWIiOiIxMjMifQ." + "dozjgNryP4J3jVmNHl0",
    "openai-key": "sk" + "-" + "abcdefghijklmnopqrstuvwxyz012345",
    "github-token": "ghp" + "_" + "abcdefghijklmnopqrstuvwxyz0123456789",
    # Slug is derived from the engine label "Supabase token (sbp_)".
    "supabase-token-sbp": "sbp" + "_" + "abcdefghijklmnopqrstuvwxyz0123",
    "aws-access-key-id": "AKIA" + "IOSFODNN7EXAMPLE",
    "private-key-block": "-----BEGIN " + "RSA PRIVATE KEY-----",
}
FAKE_JWT = FAKE["jwt-bearer-token"]


class RedactSecretsTests(unittest.TestCase):
    """R1: the shared pattern set, token format, identity and idempotence."""

    def test_credential_shapes_are_redacted(self):
        cases = {
            FAKE["jwt-bearer-token"]: "jwt-bearer-token",
            FAKE["openai-key"]: "openai-key",
            FAKE["github-token"]: "github-token",
            FAKE["supabase-token-sbp"]: "supabase-token-sbp",
            FAKE["aws-access-key-id"]: "aws-access-key-id",
        }
        for secret, slug in cases.items():
            out = srv.redact_secrets(f"prefix {secret} suffix")
            self.assertNotIn(secret, out, slug)
            self.assertIn(f"[redacted:{slug}]", out)

    def test_authorization_and_key_value_keep_their_names(self):
        # The key name is the diagnostic value — redacting must not blank it.
        out = srv.redact_secrets("Authorization: Bearer abc123def456ghi789")
        self.assertTrue(out.startswith("Authorization: "), out)
        self.assertNotIn("abc123def456ghi789", out)

        out = srv.redact_secrets('"OPENCODE_AUTH_CONTENT": "abc123def456"')
        self.assertIn("OPENCODE_AUTH_CONTENT", out)
        self.assertNotIn("abc123def456", out)

    def test_legitimate_high_entropy_content_survives(self):
        # This codebase is full of hashes; redacting them would gut the console.
        # A 40-hex git SHA, a 64-hex sha256 (engine/human_gate.py pins exactly
        # that shape for artifact hashes), and the prose that broke a naive
        # prefilter must all pass through untouched.
        keep = [
            "commit 8151b8c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6 landed",
            "sha256 5d2c1219eb3811839bb835d1f912afa8c18126426d9367d1652a59727e10b903",
            "authoritative auth-status input_tokens output_tokens",
            "SINGULAR_CLAUDE_MODEL=claude-opus-4-8",
            "merge 1a2b3c4",
        ]
        for text in keep:
            self.assertEqual(srv.redact_secrets(text), text, text)

    def test_returns_identical_object_when_nothing_matches(self):
        # The performance contract: >99.9% of log windows are clean, so a clean
        # window must not be rewritten. Pins the prefilter against a future
        # unconditional re.sub chain.
        clean = "ordinary log line with sha 8151b8c and input_tokens=42\n" * 500
        self.assertIs(srv.redact_secrets(clean), clean)

    def test_idempotent(self):
        once = srv.redact_secrets(f"API_KEY=supersecretvalue123 and {FAKE_JWT}")
        self.assertEqual(once, srv.redact_secrets(once))

    def test_prefilter_hits_every_positive_fixture(self):
        # A prefilter miss is a SILENT leak: the rules never run. Every pattern
        # that can redact must first be reachable through the cheap gate.
        positives = list(FAKE.values()) + [
            "Authorization: Bearer xyz123456789",
            "API_KEY=supersecretvalue123",
        ]
        for text in positives:
            self.assertIsNotNone(srv._SECRET_PREFILTER.search(text), text)

    def test_patterns_come_from_the_engine_file(self):
        # Console and engine/secret-scan.sh must not drift to two notions of
        # "looks like a secret".
        path = srv._engine_file("secret-patterns.tsv")
        self.assertIsNotNone(path, "engine/secret-patterns.tsv must be locatable")
        labels = [
            line.split("\t", 1)[0]
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        self.assertIn("JWT / bearer token", labels)
        self.assertGreaterEqual(len(labels), 6)


class SessionRedactionTests(unittest.TestCase):
    """R2: every session path redacts — raw mode included."""

    JWT = FAKE_JWT

    def _repo(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state/runs").mkdir(parents=True)
        return repo

    def test_secret_scan_log_is_redacted_in_both_modes(self):
        # The motivating leak: engine/secret-scan.sh quotes the offending line
        # into secret-scan.log when it BLOCKS a commit, and secret-scan.log is in
        # PLAIN_LOG_NAMES — so the gate that keeps a credential out of git hands
        # it to the browser instead.
        repo = self._repo()
        run = repo / ".singular-state/runs/RUN-x"
        run.mkdir()
        (run / "secret-scan.log").write_text(
            f"secret-scan: JWT / bearer token match in added lines:\n"
            f"    1:+token = {self.JWT}\n")
        self.assertIn("secret-scan.log", srv.PLAIN_LOG_NAMES)
        for raw in (True, False):
            out = srv.read_session(repo, "RUN-x", None, 500, "secret-scan.log", raw)
            blob = json.dumps(out)
            self.assertNotIn(self.JWT, blob, f"raw={raw}")
            self.assertIn("[redacted:jwt-bearer-token]", blob, f"raw={raw}")

    def test_command_output_and_agent_message_are_redacted(self):
        repo = self._repo()
        run = repo / ".singular-state/runs/RUN-y"
        run.mkdir()
        (run / "worker-codex.log").write_text("\n".join([
            json.dumps({"type": "item.completed", "item": {
                "type": "command_execution", "command": "echo hi",
                "aggregated_output": f"token {self.JWT}", "exit_code": 0}}),
            json.dumps({"type": "item.completed", "item": {
                "type": "agent_message", "text": f"the key is {self.JWT}"}}),
        ]) + "\n")
        out = srv.read_session(repo, "RUN-y", None, 500, "worker-codex.log", False)
        self.assertNotIn(self.JWT, json.dumps(out))

    def test_session_summary_peek_is_redacted(self):
        repo = self._repo()
        run = repo / ".singular-state/runs/RUN-z"
        run.mkdir()
        (run / "worker-codex.log").write_text(json.dumps({
            "type": "item.completed",
            "item": {"type": "agent_message", "text": f"key {self.JWT}"}}) + "\n")
        sessions = srv.discover_sessions(repo)
        self.assertNotIn(self.JWT, json.dumps(sessions))


class RawConfigRedactionTests(unittest.TestCase):
    """R3: /api/raw/config masks env{} values by key NAME, keeping the keys."""

    def _repo(self, config: dict) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state").mkdir(parents=True)
        (repo / "singular.config.json").write_text(json.dumps(config, indent=2))
        return repo

    def test_credentials_masked_but_model_knobs_survive(self):
        # providers/surface.js reads obj.env from this endpoint for the model
        # knobs, so dropping env{} would break a shipped feature. Only the key
        # NAME distinguishes a model id from a credential.
        repo = self._repo({"schemaVersion": "v2", "env": {
            "ANTHROPIC_API_KEY": "sk-ant-secretvalue000",
            "OPENCODE_AUTH_CONTENT": "opaqueauthblob123",
            "SINGULAR_CLAUDE_MODEL": "claude-opus-4-8",
            "SINGULAR_MAX_CONCURRENT": "3",
        }})
        out = srv.collect_raw(repo, "config", "singular.config.json")
        self.assertTrue(out["redacted"])
        env = json.loads(out["content"])["env"]
        self.assertEqual(env["ANTHROPIC_API_KEY"], "[redacted:config-env]")
        self.assertEqual(env["OPENCODE_AUTH_CONTENT"], "[redacted:config-env]")
        self.assertEqual(env["SINGULAR_CLAUDE_MODEL"], "claude-opus-4-8")
        self.assertEqual(env["SINGULAR_MAX_CONCURRENT"], "3")

    def test_clean_config_is_not_marked_redacted(self):
        repo = self._repo({"schemaVersion": "v2",
                           "env": {"SINGULAR_MAX_CONCURRENT": "3"}})
        out = srv.collect_raw(repo, "config", "singular.config.json")
        self.assertNotIn("redacted", out)
        self.assertEqual(json.loads(out["content"])["env"]["SINGULAR_MAX_CONCURRENT"], "3")


class SnapshotRedactionTests(unittest.TestCase):
    """R4: /api/state carries no raw loop stdout and no unredacted events."""

    def test_autonomate_tail_is_gone(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state").mkdir(parents=True)
        (repo / "docs/orchestration").mkdir(parents=True)
        snap = srv.collect_snapshot(repo)
        # 80 raw stdout lines on every 10s poll, with zero consumers.
        self.assertNotIn("autonomateTail", snap)

    def test_events_are_redacted(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        (repo / ".singular-state").mkdir(parents=True)
        jwt = FAKE_JWT
        (repo / ".singular-state/events.ndjson").write_text(json.dumps({
            "ts": "2026-07-25T10:00:00Z", "type": "l1.worker_completed",
            "message": f"worker said {jwt}", "data": {"taskId": "TASK-0001"},
        }) + "\n")
        events = srv.parse_events(repo / ".singular-state/events.ndjson", 40)
        self.assertNotIn(jwt, json.dumps(events))


class ProviderResolutionTests(unittest.TestCase):
    """P1: the console resolves providers exactly as the engine does."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        (self.repo / ".singular-state").mkdir(parents=True)
        (self.repo / "bin").mkdir()
        self.good = self.repo / "bin" / "codex"
        self.good.write_text("#!/bin/sh\necho codex 1.0\n")
        self.good.chmod(0o755)
        self.broken = self.repo / "broken-codex"
        self.broken.write_text("not executable")
        self.broken.chmod(0o644)
        srv._CONFIG_CACHE.invalidate()
        srv._PROVIDERS_CACHE.invalidate()
        self.addCleanup(srv._PROVIDERS_CACHE.invalidate)
        self.addCleanup(srv._CONFIG_CACHE.invalidate)
        self.addCleanup(srv._EFFECTIVE_CONFIGURATION_CACHE.invalidate)

    def _codex(self, config_env: dict) -> dict:
        (self.repo / "singular.config.json").write_text(
            json.dumps({"schemaVersion": "v2", "env": config_env}))
        srv.initialize_configuration(self.repo, force=True)
        srv._CONFIG_CACHE.invalidate()
        out = srv.collect_providers(
            self.repo,
            env={"PATH": str(self.repo / "bin"), "HOME": str(self.repo)},
            home=self.repo)
        return next(p for p in out["providers"] if p["id"] == "codex")

    def test_resolver_loads_in_process(self):
        # A module loaded by path is absent from sys.modules, and @dataclass
        # resolves its own module through sys.modules — so the loader must
        # register it before exec or the class body raises and the console
        # silently degrades to the old PATH-only behaviour.
        self.assertIsNotNone(srv._load_provider_resolver())

    def test_no_override_resolves_from_path(self):
        codex = self._codex({})
        self.assertTrue(codex["installed"])
        self.assertEqual(codex["resolution"]["source"], "path")
        self.assertTrue(codex["resolution"]["authoritative"])

    def test_config_env_override_is_honoured(self):
        # Startup resolves config env{} through lib.sh once; discovery consumes
        # the resulting safe executable projection without another shell pass.
        codex = self._codex({"SINGULAR_CODEX_BIN": str(self.good)})
        self.assertEqual(codex["resolution"]["source"], "configured")
        self.assertEqual(codex["path"], str(self.good))

    def test_broken_override_never_falls_back_to_path(self):
        # The reported defect: a working codex sits on PATH, but the operator
        # pinned a broken one. Probing the PATH copy would report health for an
        # executable the orchestration is not running.
        codex = self._codex({"SINGULAR_CODEX_BIN": str(self.broken)})
        self.assertEqual(codex["status"], "misconfigured")
        self.assertFalse(codex["installed"])
        self.assertIsNone(codex["path"])
        self.assertIn(str(self.broken), codex["message"])

    def test_relative_override_is_misconfigured_not_missing(self):
        codex = self._codex({"SINGULAR_CODEX_BIN": "relative/codex"})
        self.assertEqual(codex["status"], "misconfigured")
        self.assertIn("absolute", codex["message"])

    def test_misconfigured_counts_toward_attention(self):
        (self.repo / "singular.config.json").write_text(json.dumps(
            {"schemaVersion": "v2", "env": {"SINGULAR_CODEX_BIN": str(self.broken)}}))
        srv.initialize_configuration(self.repo, force=True)
        srv._CONFIG_CACHE.invalidate()
        out = srv.collect_providers(
            self.repo,
            env={"PATH": str(self.repo / "bin"), "HOME": str(self.repo)},
            home=self.repo)
        self.assertEqual(out["summary"]["misconfigured"], 1)
        self.assertGreaterEqual(out["summary"]["attention"], 1)


class DerivePlannerStateTests(unittest.TestCase):
    """P2: a rejected planner batch must never report as integrated/green."""

    def _ev(self, etype: str, run_id="RUN-x", **data):
        return {"type": etype, "data": {"runId": run_id, **data}}

    def test_no_state_is_ever_integrated(self):
        # The reported symptom. `integrated` is a lease vocabulary word; a
        # planner accepts or rejects a batch, it never integrates one.
        for critique in (None, {"schema": "singular.orchestration.plan-critique.v0",
                                "verdict": "approve"}):
            for events in ([], [self._ev("planner.staged")]):
                state, *_ = srv.derive_planner_state(
                    fresh=False, has_batch=True, critique=critique,
                    node_events=events, run_id="RUN-x")
                self.assertNotEqual(state, "integrated")

    def test_critique_verdicts(self):
        def run(verdict):
            return srv.derive_planner_state(
                fresh=False, has_batch=True,
                critique={"schema": "singular.orchestration.plan-critique.v0",
                          "verdict": verdict},
                node_events=[], run_id="RUN-x")[0]
        self.assertEqual(run("approve"), "accepted")
        self.assertEqual(run("revise"), "rejected")
        self.assertEqual(run("park"), "rejected")

    def test_events_settle_the_serial_path(self):
        # The serial reconcile path never writes plan-critique.json, so events
        # are the load-bearing signal for the case that actually shipped.
        cases = {
            "origin.l1_import_rejected": "rejected",
            "plan.revise_parked": "rejected",
            "origin.l1_planner_failed": "failed",
            "planner.failed": "failed",
            "origin.l1_no_tasks": "empty",
            "planner.staged": "accepted",
        }
        for etype, expected in cases.items():
            state, _v, _r, source = srv.derive_planner_state(
                fresh=False, has_batch=True, critique=None,
                node_events=[self._ev(etype)], run_id="RUN-x")
            self.assertEqual(state, expected, etype)
            self.assertEqual(source, "events", etype)

    def test_import_rejection_beats_an_approving_critique(self):
        # A critic-approved batch can still be rejected at import (duplicate
        # candidate, missing lease, id-rewrite failure). The later, louder
        # disposition wins.
        state, verdict, _reason, source = srv.derive_planner_state(
            fresh=False, has_batch=True,
            critique={"schema": "singular.orchestration.plan-critique.v0",
                      "verdict": "approve"},
            node_events=[self._ev("origin.l1_import_rejected", reason="plan-critique")],
            run_id="RUN-x")
        self.assertEqual(state, "rejected")
        self.assertEqual(verdict, "approve")
        self.assertEqual(source, "events")

    def test_terminal_beats_freshness(self):
        # Writing the critique bumps the run dir mtime, so a just-rejected
        # planner is "fresh" for the whole live window and would otherwise
        # paint as a live session.
        state, *_ = srv.derive_planner_state(
            fresh=True, has_batch=True,
            critique={"schema": "singular.orchestration.plan-critique.v0",
                      "verdict": "revise"},
            node_events=[], run_id="RUN-x")
        self.assertEqual(state, "rejected")

    def test_events_for_another_run_are_ignored(self):
        state, *_ = srv.derive_planner_state(
            fresh=False, has_batch=True, critique=None,
            node_events=[self._ev("origin.l1_import_rejected", run_id="RUN-other")],
            run_id="RUN-x")
        self.assertEqual(state, "accepted")

    def test_malformed_critique_is_not_trusted(self):
        for bad in ({"verdict": "approve"},                       # no schema
                    {"schema": "singular.orchestration.plan-critique.v0",
                     "verdict": "maybe"}):                        # bad verdict
            state, verdict, _r, source = srv.derive_planner_state(
                fresh=False, has_batch=True, critique=bad,
                node_events=[], run_id="RUN-x")
            self.assertIsNone(verdict)
            self.assertEqual(source, "artifacts")
            self.assertEqual(state, "accepted")

    def test_terminal_states_are_all_known_to_the_severity_map(self):
        for state in srv.PLANNER_TERMINAL_STATES:
            self.assertIn(state, srv.STATE_SEVERITY, state)
        self.assertEqual(srv.STATE_SEVERITY["rejected"],
                         srv.STATE_SEVERITY["failed"])


class PlannerSessionStateTests(unittest.TestCase):
    """P3: the derivation reaches /api/sessions end to end."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        (self.repo / ".singular-state/runs").mkdir(parents=True)
        srv._EVENTS_INDEX_CACHE.invalidate()
        self.addCleanup(srv._EVENTS_INDEX_CACHE.invalidate)

    def _planner(self, *, verdict=None, events=()):
        run = self.repo / ".singular-state/runs/RUN-p"
        run.mkdir(exist_ok=True)
        (run / "planner-codex.log").write_text("planning\n")
        # Must match _PLANNER_NODE_RE / _PLANNER_AREA_RE: the node is how a
        # planner session finds its events bucket.
        (run / "planner-prompt.md").write_text(
            "Area Planner for area `core`\nExecutable DAG node: `D1.contract`\n")
        (run / "planner-batch.json").write_text(json.dumps(
            {"schema": "singular.orchestration.task-batch.v0",
             "tasks": [{"taskId": "TASK-0001", "markdown": "x"}]}))
        if verdict:
            (run / "plan-critique.json").write_text(json.dumps({
                "schema": "singular.orchestration.plan-critique.v0",
                "node": "D1.contract", "runId": "RUN-p", "verdict": verdict}))
        if events:
            (self.repo / ".singular-state/events.ndjson").write_text(
                "\n".join(json.dumps(e) for e in events) + "\n")
        srv._EVENTS_INDEX_CACHE.invalidate()
        sessions = srv.discover_sessions(self.repo)
        return next(s for s in sessions if s["id"] == "RUN-p")

    def test_rejected_batch_is_not_live_and_not_green(self):
        sess = self._planner(verdict="revise")
        self.assertEqual(sess["state"], "rejected")
        self.assertFalse(sess["live"])         # disarms paneDotTone's short-circuit
        self.assertTrue(sess["terminal"])
        self.assertEqual(sess["criticVerdict"], "revise")

    def test_approved_batch_is_accepted(self):
        sess = self._planner(verdict="approve")
        self.assertEqual(sess["state"], "accepted")
        self.assertFalse(sess["live"])

    def test_import_rejection_event_without_a_critique_file(self):
        sess = self._planner(events=[{
            "ts": "2026-07-25T10:00:00Z", "type": "origin.l1_import_rejected",
            "message": "import rejected",
            "data": {"runId": "RUN-p", "node": "D1.contract",
                     "reason": "plan-critique", "observed": "revise"}}])
        self.assertEqual(sess["state"], "rejected")
        self.assertEqual(sess["stateSource"], "events")


if __name__ == "__main__":
    unittest.main(verbosity=2)
