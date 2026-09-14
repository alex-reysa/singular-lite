#!/usr/bin/env python3
"""Real invocation coverage for the opt-in shared context service."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone
from pathlib import Path

from engine.campaign_manifest import (
    SETTING_PROJECTION_VERSION,
    classify_resolved_setting,
    resolved_settings_projection,
    runner_child_environment,
)
from engine.context_service import ContextError, ContextService


ROOT = Path(__file__).resolve().parents[1]
BASH = Path("/opt/homebrew/bin/bash")
if not BASH.exists():
    BASH = Path(shutil.which("bash") or "/bin/bash")


def run(argv: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = {k: v for k, v in os.environ.items() if not k.startswith("SINGULAR_")}
    merged.update(env or {})
    return subprocess.run(argv, cwd=cwd, env=merged, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=90)


def write(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ContextInvocationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="singular-context-invoke.", dir="/tmp")
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def reset_fixture(self, prefix: str = "singular-context-invoke.") -> None:
        self.temp.cleanup()
        self.temp = tempfile.TemporaryDirectory(prefix=prefix, dir="/tmp")
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()

    def run_dir(self) -> Path:
        run_dirs = list((self.repo / ".singular-state/runs").glob("RUN-*"))
        self.assertEqual(len(run_dirs), 1, run_dirs)
        return run_dirs[0]

    def ledger_details(self) -> list[dict[str, object]]:
        ledger = self.repo / ".singular-state/evidence-deliveries.sqlite3"
        if not ledger.exists():
            return []
        with sqlite3.connect(ledger) as db:
            return [json.loads(row[0]) for row in db.execute("select detail from deliveries")]

    def require_real_broker(self) -> None:
        with tempfile.TemporaryDirectory(prefix="singular-broker-probe.", dir="/tmp") as root:
            path = str(Path(root) / "broker.sock")
            channel = socket.socket(socket.AF_UNIX)
            try:
                channel.bind(path)
            except OSError as exc:
                self.fail(f"real AF_UNIX broker unavailable for host acceptance: {exc}")
            finally:
                channel.close()

    def assert_final_delivery_binding(
        self, capture: Path, run_dir: Path, kind: str, count: int
    ) -> None:
        delivered = (capture / f"{kind}-{count}.md").read_bytes()
        prompt_path = Path((capture / f"{kind}-{count}.prompt-path").read_text().strip())
        digest = hashlib.sha256(delivered).hexdigest()
        self.assertEqual(prompt_path.name, f"delivery-prompt-{digest}.md")
        self.assertEqual(prompt_path.read_bytes(), delivered)

        events = [json.loads(line) for line in
                  (self.repo / ".singular-state/events.ndjson").read_text().splitlines()]
        selected = [event["data"] for event in events
                    if event.get("type") == "context.bundle_selected"
                    and event.get("data", {}).get("promptSha256") == "sha256:" + digest]
        self.assertTrue(selected, (kind, count, digest))
        for event_data in selected:
            bundle_path = run_dir / event_data["bundleRef"]
            self.assertTrue(bundle_path.is_file(), event_data)
            bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
            self.assertEqual(bundle["prompt"].encode(), delivered)
            self.assertEqual(bundle["promptSha256"], "sha256:" + digest)
            self.assertEqual(event_data["bundleId"], bundle["bundleId"])
            self.assertEqual(
                event_data["policy"]["resolvedSettingsProjectionVersion"],
                SETTING_PROJECTION_VERSION,
            )
            self.assertEqual(
                event_data["policy"]["configSha256"], bundle["policy"]["configSha256"]
            )
            self.assertEqual(
                event_data["invocation"]["invocationId"],
                bundle["invocation"]["invocationId"],
            )

        required = [detail for detail in self.ledger_details()
                    if detail.get("kind") == "required-prompt"
                    and detail.get("promptSha256") == digest]
        self.assertTrue(required, (kind, count, digest, self.ledger_details()))
        selected_refs = {item["bundleRef"] for item in selected}
        selected_ids = {item["bundleId"] for item in selected}
        for detail in required:
            self.assertEqual(detail["promptBytes"], len(delivered))
            self.assertIn(detail["bundleRef"], selected_refs)
            self.assertIn(detail["bundleId"], selected_ids)

    def config(self, *, enabled: bool = True, missing: bool = False) -> Path:
        write(self.repo / "context/shared.md", "ORBIT-CONTEXT planner implement widget invariant\n")
        write(self.repo / "context/worker.json", "WORKER-CONCLUSION-UNTRUSTED implement widget\n")
        config = {
            "contextService": {
                "enabled": enabled,
                "projectId": "invocation-fixture",
                "revision": "fixture-revision",
                "budgetBytes": 16384,
                "codePaths": ["context/missing.md" if missing else "context/shared.md"],
                "runRecordPaths": ["context/worker.json"],
                "rolePolicy": {
                    "planner": ["code"],
                    "implementer": ["code", "run"],
                    "review-target": ["code"],
                },
            }
        }
        path = self.repo / "singular.config.json"
        write(path, json.dumps(config, sort_keys=True))
        return path

    def test_campaign_policy_projection_separates_invocation_identity_without_hiding_policy(self) -> None:
        stable = {
            "SINGULAR_TASKS_DIR": "/canonical/tasks",
            "SINGULAR_CONTEXT_BUDGET_BYTES": "16384",
            "SINGULAR_CONTEXT_CONFIG_FILE": "/root/singular.config.json",
            "SINGULAR_CAPABILITY_PROFILES_JSON": '{"implementer":["shell"]}',
            "SINGULAR_UNKNOWN_POLICY_SENTINEL": "frozen",
        }
        first = {
            **stable,
            "SINGULAR_RUNNER_ROLE": "implementer",
            "SINGULAR_RUNNER_CAPABILITY_PROFILE": "implementer-core",
            "SINGULAR_RUNNER_RUN_ID": "RUN-one",
            "SINGULAR_TEST_TASK_CONTRACT": "/worktree/tasks/TASK-0001.md",
            "SINGULAR_TEST_TASK_ID": "TASK-0001",
            "SINGULAR_TEST_TASKS_DIR": "/worktree/tasks",
            "SINGULAR_EXPECTED_CAMPAIGN_BINDING": "campaign:one",
        }
        second = {
            **stable,
            "SINGULAR_RUNNER_ROLE": "auditor",
            "SINGULAR_RUNNER_CAPABILITY_PROFILE": "audit-core",
            "SINGULAR_RUNNER_RUN_ID": "RUN-two",
            "SINGULAR_TEST_TASK_CONTRACT": "/worktree/tasks/TASK-0002.md",
            "SINGULAR_TEST_TASK_ID": "TASK-0002",
            "SINGULAR_TEST_TASKS_DIR": "/worktree/tasks",
            "SINGULAR_EXPECTED_CAMPAIGN_BINDING": "campaign:two",
        }
        one = resolved_settings_projection(first)
        two = resolved_settings_projection(second)
        self.assertEqual(one["version"], SETTING_PROJECTION_VERSION)
        self.assertEqual(resolved_settings_projection({})["policy"], {})
        self.assertEqual(one["policy"], two["policy"])
        self.assertEqual(classify_resolved_setting("SINGULAR_RUNNER_ROLE"), "invocation")
        self.assertEqual(classify_resolved_setting("SINGULAR_RUNNER_RESULT_FILE"), "transport")
        self.assertEqual(classify_resolved_setting("SINGULAR_CONTEXT_CONFIG_FILE"), "policy")
        self.assertEqual(classify_resolved_setting("SINGULAR_TASKS_DIR"), "policy")
        self.assertEqual(classify_resolved_setting("SINGULAR_CONTEXT_BUDGET_BYTES"), "policy")
        self.assertEqual(classify_resolved_setting("SINGULAR_UNKNOWN_POLICY_SENTINEL"), "policy")
        changed = resolved_settings_projection({
            **second, "SINGULAR_UNKNOWN_POLICY_SENTINEL": "changed",
        })
        self.assertNotEqual(one["policy"], changed["policy"])
        changed_selector = resolved_settings_projection({
            **second,
            "SINGULAR_CONTEXT_CONFIG_FILE": "/alternate/singular.config.json",
        })
        self.assertNotEqual(one["policy"], changed_selector["policy"])
        child = runner_child_environment({
            **first,
            "SINGULAR_RESERVATION_OWNER": "secret-host-authority",
            "SINGULAR_GIT_LOCK_CAPABILITY": "secret-lock",
            "SINGULAR_CODEX_MODEL": "gpt-fixture",
            "SINGULAR_MEMORY_CREDENTIAL_KEY": "non-secret-test-sentinel",
            "PATH": "/usr/bin:/bin",
        })
        self.assertNotIn("SINGULAR_RESERVATION_OWNER", child)
        self.assertNotIn("SINGULAR_GIT_LOCK_CAPABILITY", child)
        self.assertNotIn("SINGULAR_CONTEXT_CONFIG_FILE", child)
        self.assertNotIn("SINGULAR_MEMORY_CREDENTIAL_KEY", child)
        self.assertEqual(child["SINGULAR_RUNNER_ROLE"], "implementer")
        self.assertEqual(child["SINGULAR_TEST_TASK_ID"], "TASK-0001")
        self.assertEqual(child["SINGULAR_CODEX_MODEL"], "gpt-fixture")

    def test_admission_evidence_uses_verified_frozen_policy_projection(self) -> None:
        from engine import evidence_delivery

        policy = {
            "SINGULAR_CONTEXT_CONFIG_FILE": {
                "bytes": 20, "sha256": hashlib.sha256(b"selected-policy.json").hexdigest(),
            },
            "SINGULAR_UNKNOWN_POLICY_SENTINEL": {
                "bytes": 6, "sha256": hashlib.sha256(b"frozen").hexdigest(),
            },
        }
        manifest = self.repo / "manifest.json"
        write(manifest, json.dumps({
            "schema": "singular.orchestration.campaign-manifest.v1",
            "campaignId": "frozen-policy-test",
            "configuration": {"resolvedSettings": policy},
        }, sort_keys=True))
        raw = manifest.read_bytes()
        binding = (
            "campaign:frozen-policy-test:sha256:" + hashlib.sha256(raw).hexdigest()
        )
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=f"{binding}\n{manifest}\n", stderr="",
        )
        with mock.patch.object(evidence_delivery.subprocess, "run", return_value=completed):
            admitted = evidence_delivery.verify_campaign(binding)
        self.assertEqual(admitted, {"binding": binding, "policy": policy})
        evidence = evidence_delivery.invocation_setting_evidence(admitted["policy"])
        expected = "sha256:" + hashlib.sha256(json.dumps(
            policy, sort_keys=True, separators=(",", ":"),
        ).encode()).hexdigest()
        self.assertEqual(evidence["policySha256"], expected)
        self.assertIsNone(
            evidence_delivery.invocation_setting_evidence(policy_verified=False)["policySha256"]
        )

    def test_frozen_policy_config_is_distinct_from_invocation_workspace(self) -> None:
        policy_root = Path(self.temp.name) / "policy-root"
        workspace = Path(self.temp.name) / "worker-workspace"
        config = policy_root / "singular.config.json"
        source = workspace / "context/shared.md"
        task = workspace / "docs/orchestration/tasks/TASK-0001.md"
        base = Path(self.temp.name) / "base.md"
        write(source, "WORKSPACE-SOURCE-V1\n")
        write(task, "# TASK-0001\n\n[open] preserve the workspace contract\n")
        write(base, "AUTHORITATIVE HOST PROMPT\n")
        write(config, json.dumps({
            "contextService": {
                "enabled": True,
                "projectId": "frozen-policy-fixture",
                "budgetBytes": 8192,
                "codePaths": ["context/shared.md"],
                "rolePolicy": {"implementer": ["code"]},
            }
        }))

        service = ContextService.from_config(
            config, role="implementer", phase="implement", workspace=workspace,
        )
        bundle = service.build(
            task=task, phase="implement", budget_bytes=8192, base_prompt=base,
            delivery="initial", invocation_id="RUN-one:implementer",
            campaign_binding="campaign:frozen",
        )
        self.assertEqual(service.config_path, config.resolve())
        self.assertEqual(service.root, workspace.resolve())
        self.assertEqual(bundle["policy"]["configPath"], str(config.resolve()))
        self.assertEqual(bundle["policy"]["configSha256"], "sha256:" + file_sha256(config))
        self.assertEqual(bundle["invocation"]["workspace"], str(workspace.resolve()))
        self.assertEqual(bundle["invocation"]["invocationId"], "RUN-one:implementer")
        self.assertEqual(bundle["invocation"]["campaignBinding"], "campaign:frozen")
        self.assertIn("WORKSPACE-SOURCE-V1", bundle["prompt"])

        write(workspace / "singular.config.json", json.dumps({
            "contextService": {"enabled": False, "budgetBytes": 1}
        }))
        second = ContextService.from_config(
            config, role="implementer", phase="retry", workspace=workspace,
        ).build(
            task=task, phase="retry", budget_bytes=8192, base_prompt=base,
            delivery="delta", prior_bundle=bundle,
            invocation_id="RUN-one:implementer:retry",
            campaign_binding="campaign:frozen",
        )
        self.assertIn("code:context/shared.md unchanged", second["prompt"])
        self.assertEqual(second["policy"], bundle["policy"])

    def test_shell_boundary_reports_structured_invalid_policy_without_launch(self) -> None:
        config = self.config()
        invalid = self.repo / "invalid-context.json"
        invalid.write_text("{", encoding="utf-8")
        task = self.repo / "task.md"
        task.write_text("# TASK-0001\n", encoding="utf-8")
        receipt = self.repo / "context-denied.json"
        marker = self.repo / "provider-called"
        provider = self.repo / "provider.sh"
        provider.write_text(
            f"#!/usr/bin/env bash\nprintf called >'{marker}'\n", encoding="utf-8"
        )
        provider.chmod(0o755)
        script = (
            '. "$1/engine/lib.sh"; . "$1/engine/ctx-rehydrate-event.sh"; '
            'SINGULAR_CONTEXT_CONFIG_FILE="$2" singular_context_invocation_run '
            'implementer implement "$3" "$4" "" RUN:implementer "$5" legacy '
            '"$6" -- "$7"'
        )
        result = run(
            [
                str(BASH), "-c", script, "context-shell", str(ROOT), str(invalid),
                str(task), str(self.repo / "bundle.json"), str(receipt),
                str(self.repo), str(provider),
            ],
            cwd=self.repo,
            env={
                "SINGULAR_ROOT": str(self.repo),
                "SINGULAR_ENGINE_HOME": str(ROOT),
                "SINGULAR_JSON_CONFIG_FILE": str(config),
            },
        )
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertFalse(marker.exists())
        denial = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(denial["status"], "denied")
        self.assertEqual(denial["denial"]["reason"], "context-invalid")
        self.assertEqual(denial["retrievalDebitBytes"], 0)
        self.assertEqual(
            denial["policy"]["resolvedSettingsProjectionVersion"],
            SETTING_PROJECTION_VERSION,
        )
        self.assertIsNone(denial["policy"]["resolvedPolicySha256"])
        self.assertEqual(denial["invocation"]["invocationId"], "RUN:implementer")

        receipt.unlink()
        missing = self.repo / "missing-context.json"
        result = run(
            [
                str(BASH), "-c", script, "context-shell", str(ROOT), str(missing),
                str(task), str(self.repo / "bundle.json"), str(receipt),
                str(self.repo), str(provider),
            ],
            cwd=self.repo,
            env={
                "SINGULAR_ROOT": str(self.repo),
                "SINGULAR_ENGINE_HOME": str(ROOT),
                "SINGULAR_JSON_CONFIG_FILE": str(config),
            },
        )
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertFalse(marker.exists())
        missing_denial = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(missing_denial["denial"]["reason"], "context-invalid")
        self.assertIsNone(missing_denial["policy"]["resolvedPolicySha256"])

    def test_invocation_bundle_is_atomic_delta_bounded_and_revalidates(self) -> None:
        config = self.config()
        task = self.repo / "task.md"
        base = self.repo / "base.md"
        write(task, "# Task\n\nImplement the ORBIT-CONTEXT widget.\n")
        write(base, "AUTHORITATIVE DRIVER PROMPT\ncomplete obligations\n")
        first = ContextService.from_config(config, role="implementer", phase="implement").build(
            task=task, phase="implement", budget_bytes=4096, query="ORBIT-CONTEXT implement widget",
            base_prompt=base, delivery="initial",
        )
        self.assertTrue(first["prompt"].startswith("AUTHORITATIVE DRIVER PROMPT"))
        self.assertEqual(first["prompt"].count("AUTHORITATIVE DRIVER PROMPT"), 1)
        self.assertIn("ORBIT-CONTEXT", first["prompt"])
        self.assertIn("WORKER-CONCLUSION-UNTRUSTED", first["prompt"])
        self.assertLessEqual(len(first["prompt"].encode()), 4096)
        self.assertEqual(first["promptSha256"], "sha256:" + hashlib.sha256(first["prompt"].encode()).hexdigest())

        effective = run([
            sys.executable, str(ROOT / "engine/context_cli.py"), "effective-config",
            "--config", str(config), "--role", "review-target", "--phase", "final-audit",
        ], cwd=self.repo)
        self.assertEqual(effective.returncode, 0, effective.stdout)
        effective_data = json.loads(effective.stdout)
        self.assertTrue(effective_data["contextService"]["enabled"])
        self.assertEqual(effective_data["contextService"]["budgetBytes"], 16384)
        self.assertEqual(effective_data["contextService"]["allowedKinds"], ["code"])
        self.assertTrue(effective_data["contextService"]["sources"][0]["provenance"])

        second = ContextService.from_config(config, role="implementer", phase="retry").build(
            task=task, phase="retry", budget_bytes=4096, query="ORBIT-CONTEXT implement widget",
            base_prompt=base, delivery="delta", prior_bundle=first,
        )
        shared_ref = "code:context/shared.md"
        self.assertIn(f"{shared_ref} unchanged", second["prompt"])
        self.assertNotIn("ORBIT-CONTEXT planner implement widget invariant", second["prompt"])
        self.assertTrue(any("unchanged_immutable_reference" in item["reasons"] for item in second["provenance"]))

        write(self.repo / "context/shared.md", "ORBIT-CONTEXT CHANGED invariant\n")
        changed = ContextService.from_config(config, role="implementer", phase="retry").build(
            task=task, phase="retry", budget_bytes=4096, query="ORBIT-CONTEXT CHANGED",
            base_prompt=base, delivery="delta", prior_bundle=second,
        )
        self.assertIn("ORBIT-CONTEXT CHANGED", changed["prompt"])
        self.assertTrue(any(item["ref"] == shared_ref and "changed_source" in item["reasons"]
                            for item in changed["provenance"]))

        (self.repo / "context/shared.md").unlink()
        with self.assertRaisesRegex(ContextError, "missing source"):
            ContextService.from_config(config, role="implementer", phase="retry").build(
                task=task, phase="retry", budget_bytes=4096, base_prompt=base,
                delivery="delta", prior_bundle=changed,
            )

    def test_delta_obligation_provenance_preserves_offsets_and_budget_classes(self) -> None:
        config = self.config()
        task = self.repo / "task.md"
        base = self.repo / "base.md"
        task_text = "# Task\n\nA mandatory contract added after the driver prompt.\n"
        run_text = (
            "model preface that is not an obligation\n"
            "[open] preserve the first mandatory invariant\n"
            "unrelated model conclusion between obligations\n"
            "[violated] preserve the second mandatory invariant\n"
        )
        write(task, task_text)
        write(base, "AUTHORITATIVE DRIVER PROMPT\n")
        write(self.repo / "context/worker.json", run_text)
        first = ContextService.from_config(config, role="implementer", phase="implement").build(
            task=task, phase="implement", budget_bytes=8192, base_prompt=base,
            delivery="initial",
        )
        delta = ContextService.from_config(config, role="implementer", phase="retry").build(
            task=task, phase="retry", budget_bytes=8192, base_prompt=base,
            delivery="delta", prior_bundle=first,
        )
        source = (self.repo / "context/worker.json").read_bytes()
        obligation_items = [
            item for item in delta["provenance"]
            if "mandatory_open_or_violated_obligation" in item["reasons"]
        ]
        self.assertEqual(len(obligation_items), 2)
        self.assertGreater(obligation_items[0]["range"]["startByte"], 0)
        self.assertGreater(obligation_items[1]["range"]["startByte"],
                           obligation_items[0]["range"]["endByte"])
        for item in obligation_items:
            start, end = item["range"]["startByte"], item["range"]["endByte"]
            excerpt = source[start:end]
            self.assertEqual(item["excerptSha256"],
                             "sha256:" + hashlib.sha256(excerpt).hexdigest())
        budget = delta["budget"]
        self.assertEqual(budget["mandatoryBytes"] + budget["optionalBytes"],
                         budget["usedBytes"])
        self.assertGreater(budget["mandatoryBytes"], len(base.read_bytes()))
        self.assertIn(task_text, delta["prompt"])

    def test_invocation_snapshot_refuses_config_and_source_drift_and_freshly_reads_task(self) -> None:
        config = self.config()
        task = self.repo / "task.md"
        base = self.repo / "base.md"
        write(task, "# Task\n\nFIRST TASK CONTRACT\n")
        write(base, "AUTHORITATIVE DRIVER PROMPT\n")

        stale_config = ContextService.from_config(
            config, role="implementer", phase="implement"
        )
        original_config = config.read_text(encoding="utf-8")
        write(config, original_config + "\n")
        with self.assertRaisesRegex(ContextError, "configuration changed"):
            stale_config.build(
                task=task, phase="implement", budget_bytes=8192,
                base_prompt=base, delivery="initial", invocation_id="config-drift",
                campaign_binding="legacy",
            )

        write(config, original_config)
        stale_source = ContextService.from_config(
            config, role="implementer", phase="implement"
        )
        write(self.repo / "context/shared.md", "SOURCE CHANGED AFTER SNAPSHOT\n")
        with self.assertRaisesRegex(ContextError, "configured source changed"):
            stale_source.build(
                task=task, phase="implement", budget_bytes=8192,
                base_prompt=base, delivery="initial", invocation_id="source-drift",
                campaign_binding="legacy",
            )

        fresh = ContextService.from_config(config, role="implementer", phase="implement")
        first = fresh.build(
            task=task, phase="implement", budget_bytes=8192,
            base_prompt=base, delivery="initial", invocation_id="task-first",
            campaign_binding="legacy",
        )
        write(task, "# Task\n\nSECOND TASK CONTRACT\n")
        second = ContextService.from_config(
            config, role="implementer", phase="implement"
        ).build(
            task=task, phase="implement", budget_bytes=8192,
            base_prompt=base, delivery="initial", invocation_id="task-second",
            campaign_binding="legacy",
        )
        self.assertIn("FIRST TASK CONTRACT", first["prompt"])
        self.assertNotIn("FIRST TASK CONTRACT", second["prompt"])
        self.assertIn("SECOND TASK CONTRACT", second["prompt"])
        self.assertNotEqual(first["promptSha256"], second["promptSha256"])

    def test_doctor_exposes_effective_context_policy_and_provenance(self) -> None:
        config = self.config()
        sys.path.insert(0, str(ROOT / "engine"))
        try:
            from doctor import Doctor, JsonConfigResolution
            doctor = Doctor(
                engine=ROOT, repo=self.repo, bash=BASH, bash_version="5.2",
                output_json=True, repair_model_cache=False,
            )
            doctor.config = json.loads(config.read_text(encoding="utf-8"))
            doctor.config_resolution = JsonConfigResolution(config, "selector")
            with mock.patch.dict(os.environ, {"SINGULAR_CONTEXT_BUDGET_BYTES": "12288"}):
                from context_service import context_policy_view
                policy = context_policy_view(
                    config,
                    workspace=self.repo,
                    environment=os.environ,
                    source="selector",
                )
                doctor.runtime_env = dict(os.environ)
                doctor.effective_config_projection = {
                    "schema": "singular.effective-configuration.v1",
                    "paths": {"state": str(self.repo / ".singular-state")},
                    "contextService": policy,
                }
                doctor.context_service_check()
        finally:
            sys.path.pop(0)
        check = next(item for item in doctor.checks if item["id"] == "runtime.context-service")
        self.assertEqual(check["status"], "pass")
        effective = check["details"]["effectivePolicy"]
        self.assertTrue(effective["enabled"])
        self.assertEqual(effective["roles"]["implementer"]["budgetBytes"], 12288)
        self.assertEqual(
            effective["roles"]["implementer"]["budgetSource"],
            "SINGULAR_CONTEXT_BUDGET_BYTES",
        )
        review = effective["roles"]["review-target"]
        self.assertEqual(review["allowedKinds"], ["code"])
        self.assertTrue(review["sources"][0]["provenance"])
        self.assertIn("contextService", doctor.effective_config_projection)

    def planner_fixture(self, *, enabled: bool = True, missing: bool = False) -> tuple[Path, Path]:
        config = self.config(enabled=enabled, missing=missing)
        (self.repo / "docs/orchestration/tasks").mkdir(parents=True, exist_ok=True)
        write(self.repo / "docs/orchestration/prompts/l1-planner.md", "PLAN ORBIT-CONTEXT [AREA] [TARGET] [NEXT-ID]\n")
        write(self.repo / "schemas/task-batch.v0.schema.json",
              (ROOT / "schemas/task-batch.v0.schema.json").read_text(encoding="utf-8"))
        write(self.repo / "schemas/orchestration/dag.v0.schema.json",
              (ROOT / "schemas/dag.v0.schema.json").read_text(encoding="utf-8"))
        write(self.repo / "docs/orchestration/dag.v0.json", json.dumps({
            "schema": "singular.orchestration.dag.v0", "layers": ["engine_runtime"],
            "kinds": ["runtime"], "nodes": [{"id": "context-node", "stage": "S1",
            "area": "widget", "layer": "engine_runtime", "kind": "runtime",
            "dependsOn": [], "requiredCompletion": "ORBIT-CONTEXT remains complete"}],
        }))
        stub = Path(self.temp.name) / "planner-stub.sh"
        write(stub, f"""#!{BASH}
set -euo pipefail
prompt=""; out=""; session_meta=""; has_resume=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) prompt="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --session-meta) session_meta="$2"; shift 2 ;;
    --resume-session) has_resume=1; shift 2 ;;
    *) shift ;;
  esac
done
count=0
[[ ! -f "{self.temp.name}/planner.count" ]] || count="$(cat "{self.temp.name}/planner.count")"
count=$((count + 1))
printf '%s\n' "$count" >"{self.temp.name}/planner.count"
cp "$prompt" "{self.temp.name}/planner-$count.md"
cp "$prompt" "{self.temp.name}/planner-captured.md"
if [[ "$has_resume" == 1 && "$count" == 1 && -n "${{PLANNER_STUB_RESUME_TRANSITION:-}}" ]]; then
  case "$PLANNER_STUB_RESUME_TRANSITION" in
    changed) printf 'ORBIT-CONTEXT CHANGED DURING PLANNER RESUME\n' >"$PWD/context/shared.md" ;;
    missing) rm -f "$PWD/context/shared.md" ;;
    revoked)
      python3 - "$PWD/singular.config.json" <<'PY'
import json,sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["contextService"]["codePaths"] = []
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
      ;;
  esac
  exit 86
fi
if [[ "$has_resume" == 0 && "$count" -gt 1 ]]; then
  case "${{PLANNER_STUB_RESUME_TRANSITION:-}}" in
    changed) printf 'ORBIT-CONTEXT planner implement widget invariant\n' >"$PWD/context/shared.md" ;;
    revoked)
      python3 - "$PWD/singular.config.json" <<'PY'
import json,sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["contextService"]["codePaths"] = ["context/shared.md"]
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
      ;;
  esac
fi
python3 - "$out" <<'PY'
import json,sys
md = '''# TASK-0001: context widget\n\nStatus: ready\nArea: widget\nTarget branch: `target`\nWorker branch: `agent/widget/TASK-0001-context`\nTest policy: `strict_test_first`\nGate command: `true`\nDispatch mode: canonical\nDepends on: []\n\n## Objective\n\nImplement ORBIT-CONTEXT.\n\n## Scope\n\nOwned files:\n\n- `widget.txt`\n\nForbidden files:\n\n- `outside.txt`\n\n## Acceptance Criteria\n\n- Context is present.\n'''
json.dump({{"schema":"singular.orchestration.task-batch.v0","tasks":[{{"taskId":"TASK-0001","markdown":md}}]}}, open(sys.argv[1],"w"))
PY
if [[ -n "$session_meta" ]]; then
  python3 - "$session_meta" "$PWD" <<'PY'
import json,sys
from datetime import datetime, timezone
json.dump({{
  "schema":"singular.orchestration.session-meta.v0", "provider":"fixture",
  "sessionId":"planner-fixture-session", "model":"fixture", "effort":"low",
  "cwd":sys.argv[2], "exitCode":0,
  "createdAt":datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}}, open(sys.argv[1], "w", encoding="utf-8"))
PY
fi
""")
        stub.chmod(0o755)
        run(["git", "init", "-q"], cwd=self.repo)
        run(["git", "checkout", "-q", "-b", "target"], cwd=self.repo)
        run(["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "add", "."], cwd=self.repo)
        run(["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-qm", "init"], cwd=self.repo)
        return config, stub

    def planner_env(self, config: Path, stub: Path) -> dict[str, str]:
        return {
            "SINGULAR_ROOT": str(self.repo), "SINGULAR_ENGINE_HOME": str(ROOT),
            "SINGULAR_ORCH_DIR": str(self.repo / "docs/orchestration"),
            "SINGULAR_TASKS_DIR": str(self.repo / "docs/orchestration/tasks"),
            "SINGULAR_STATE_DIR": str(self.repo / ".singular-state"),
            "SINGULAR_TARGET_BRANCH": "target", "SINGULAR_RUNNER": str(stub),
            "SINGULAR_JSON_CONFIG_FILE": str(config), "SINGULAR_PLANNER_SESSION": "0",
        }

    def prepare_planner_resume(self, stub: Path) -> None:
        state = self.repo / ".singular-state/sessions/planner"
        state.mkdir(parents=True, exist_ok=True)
        head = run(["git", "rev-parse", "target"], cwd=self.repo).stdout.strip()
        template = self.repo / "docs/orchestration/prompts/l1-planner.md"
        write(state / "context-node.json", json.dumps({
            "schema": "singular.orchestration.session-meta.v0",
            "provider": "fixture",
            "sessionId": "planner-fixture-session",
            "role": "planner",
            "node": "context-node",
            "runner": stub.name,
            "promptSha256": file_sha256(template),
            "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "headShaAtCreate": head,
            "cwd": str(self.repo),
        }))
        write(state / "context-node.log", "")

    def test_real_planner_driver_injects_bundle_and_feature_off_is_compatible(self) -> None:
        config, stub = self.planner_fixture()
        result = run([str(BASH), str(ROOT / "engine/generate-tasks.sh"), "--node", "context-node", "--count", "1"],
                     cwd=self.repo, env=self.planner_env(config, stub))
        self.assertEqual(result.returncode, 0, result.stdout)
        captured = Path(self.temp.name, "planner-captured.md").read_text(encoding="utf-8")
        self.assertIn("ORBIT-CONTEXT planner implement widget invariant", captured)
        bundles = list((self.repo / ".singular-state/runs").glob("*/context-planner.bundle.json"))
        self.assertEqual(len(bundles), 1)
        bundle = json.loads(bundles[0].read_text(encoding="utf-8"))
        self.assertEqual(bundle["prompt"], captured)
        events = [json.loads(line) for line in
                  (self.repo / ".singular-state/events.ndjson").read_text().splitlines()]
        selected = next(event["data"] for event in events
                        if event.get("type") == "context.bundle_selected")
        self.assertEqual(selected["bundleId"], bundle["bundleId"])
        self.assertEqual(selected["promptSha256"], bundle["promptSha256"])
        self.assertEqual(selected["invocation"]["campaignBinding"], "legacy")
        self.assertEqual(bundle["invocation"]["campaignBinding"], "legacy")
        self.assertEqual(
            {key: selected["policy"][key] for key in bundle["policy"]},
            bundle["policy"],
        )

        off_temp = tempfile.TemporaryDirectory(prefix="singular-context-off.", dir="/tmp")
        self.addCleanup(off_temp.cleanup)
        prior_temp, prior_repo = self.temp, self.repo
        self.temp = off_temp
        self.repo = Path(off_temp.name) / "repo"
        self.repo.mkdir()
        off_config, off_stub = self.planner_fixture(enabled=False)
        off = run([str(BASH), str(ROOT / "engine/generate-tasks.sh"), "--node", "context-node", "--count", "1"],
                  cwd=self.repo, env=self.planner_env(off_config, off_stub))
        self.assertEqual(off.returncode, 0, off.stdout)
        off_prompt = Path(off_temp.name, "planner-captured.md").read_text(encoding="utf-8")
        self.assertNotIn("planner implement widget invariant", off_prompt)
        self.assertFalse(list((self.repo / ".singular-state/runs").glob("*/context-*.bundle.json")))
        self.temp, self.repo = prior_temp, prior_repo

    def test_missing_configured_source_fails_before_planner_provider(self) -> None:
        config, stub = self.planner_fixture(missing=True)
        result = run([str(BASH), str(ROOT / "engine/generate-tasks.sh"), "--node", "context-node", "--count", "1"],
                     cwd=self.repo, env=self.planner_env(config, stub))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("missing source", result.stdout)
        self.assertFalse(Path(self.temp.name, "planner-captured.md").exists())

    def test_planner_rc86_fresh_fallback_revalidates_changed_missing_and_revoked_sources(self) -> None:
        for transition in ("changed", "missing", "revoked"):
            with self.subTest(transition=transition):
                if transition != "changed":
                    self.reset_fixture("singular-planner-fallback.")
                config, stub = self.planner_fixture()
                self.prepare_planner_resume(stub)
                env = self.planner_env(config, stub)
                env.update({
                    "SINGULAR_PLANNER_SESSION": "1",
                    "PLANNER_STUB_RESUME_TRANSITION": transition,
                })
                result = run([
                    str(BASH), str(ROOT / "engine/generate-tasks.sh"),
                    "--node", "context-node", "--count", "1",
                ], cwd=self.repo, env=env)
                calls = int(Path(self.temp.name, "planner.count").read_text().strip())
                if transition == "missing":
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("missing source", result.stdout)
                    self.assertEqual(calls, 1, "fresh fallback must not launch with stale source bytes")
                    write(self.repo / "context/shared.md",
                          "ORBIT-CONTEXT planner implement widget invariant\n")
                else:
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(calls, 2)
                    fallback = Path(self.temp.name, "planner-2.md").read_text(encoding="utf-8")
                    if transition == "changed":
                        self.assertIn("ORBIT-CONTEXT CHANGED DURING PLANNER RESUME", fallback)
                        self.assertNotIn("planner implement widget invariant", fallback)
                    else:
                        self.assertIn("Revoked since the prior bundle: code:context/shared.md", fallback)

    def worker_fixture(self) -> tuple[Path, Path, Path]:
        config = self.config()
        tasks = self.repo / "docs/orchestration/tasks"
        tasks.mkdir(parents=True)
        (self.repo / "docs/orchestration/prompts").mkdir(parents=True)
        shutil.copy(ROOT / "templates/prompts/l2-test-first-developer.md",
                    self.repo / "docs/orchestration/prompts/l2-test-first-developer.md")
        shutil.copy(ROOT / "templates/prompts/auditor.md",
                    self.repo / "docs/orchestration/prompts/auditor.md")
        write(self.repo / "docs/orchestration/prompts/decider.md", "Decide [TASK-ID] [FAILURE CLASS]\n")
        task = tasks / "TASK-0001.md"
        write(task, """# TASK-0001: context widget

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-context`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the ORBIT-CONTEXT widget without trusting worker conclusions.

## Scope

Owned files:

- `widget.txt`

Forbidden files:

- `outside.txt`

## Acceptance Criteria

- REQUIRED-ORBIT-OBLIGATION remains visible to fresh auditors.
""")
        capture = Path(self.temp.name) / "captures"
        capture.mkdir()
        stub = Path(self.temp.name) / "driver-stub.sh"
        write(stub, f"""#!{BASH}
set -euo pipefail
role="${{SINGULAR_RUNNER_ROLE:-unknown}}"; prompt=""; out=""; worktree=""; run_id=""
session_meta=""; has_resume=0
args=("$@")
i=0
while [[ $i -lt ${{#args[@]}} ]]; do
  case "${{args[$i]}}" in
    --prompt-file) prompt="${{args[$((i+1))]}}"; i=$((i+2)) ;;
    --output-last-message) out="${{args[$((i+1))]}}"; i=$((i+2)) ;;
    -C|--worktree) worktree="${{args[$((i+1))]}}"; i=$((i+2)) ;;
    --run-id) run_id="${{args[$((i+1))]}}"; i=$((i+2)) ;;
    --session-meta) session_meta="${{args[$((i+1))]}}"; i=$((i+2)) ;;
    --resume-session) has_resume=1; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
if [[ "$*" == *--describe-contract* ]]; then exit 2; fi
kind="$role"
[[ "$out" == *paired-audit-raw.json ]] && kind="paired"
count=0; [[ ! -f "{capture}/$kind.count" ]] || count="$(cat "{capture}/$kind.count")"
count=$((count + 1)); printf '%s\n' "$count" >"{capture}/$kind.count"
cp "$prompt" "{capture}/$kind-$count.md"
cp "$prompt" "{capture}/$kind.md"
printf '%s\n' "$prompt" >"{capture}/$kind-$count.prompt-path"
printf '%s\n' "$@" >"{capture}/$kind.args"
printf '%s\n' "$@" >"{capture}/$kind-$count.args"
if [[ "$role" == implementer && "$count" -gt 1 ]]; then
  case "${{DRIVER_STUB_INFRA_TRANSITION:-}}" in
    changed) printf 'ORBIT-CONTEXT planner implement widget invariant\n' >"$worktree/context/shared.md" ;;
    revoked)
      python3 - "${{DRIVER_STUB_POLICY_CONFIG:?}}" <<'PY'
import json,sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["contextService"]["codePaths"] = ["context/shared.md"]
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
      ;;
  esac
fi
if [[ "$role" == implementer && "$has_resume" == 0 && "$count" -gt 2 ]]; then
  case "${{DRIVER_STUB_RESUME_TRANSITION:-}}" in
    changed) printf 'ORBIT-CONTEXT planner implement widget invariant\n' >"$worktree/context/shared.md" ;;
    revoked)
      python3 - "${{DRIVER_STUB_POLICY_CONFIG:?}}" <<'PY'
import json,sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["contextService"]["codePaths"] = ["context/shared.md"]
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
      ;;
  esac
fi
if [[ "$role" == implementer ]]; then
  if [[ "$has_resume" == 1 && -n "${{DRIVER_STUB_RESUME_TRANSITION:-}}" ]]; then
    case "${{DRIVER_STUB_RESUME_TRANSITION}}" in
      changed) printf 'ORBIT-CONTEXT CHANGED DURING WORKER RESUME\n' >"$worktree/context/shared.md" ;;
      missing) rm -f "$worktree/context/shared.md" ;;
      revoked)
        python3 - "${{DRIVER_STUB_POLICY_CONFIG:?}}" <<'PY'
import json,sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["contextService"]["codePaths"] = []
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
        ;;
    esac
    exit 86
  fi
  if [[ "${{DRIVER_STUB_INFRA_TRANSITION:-}}" != "" && "$count" == "1" ]]; then
    case "${{DRIVER_STUB_INFRA_TRANSITION}}" in
      changed) printf 'ORBIT-CONTEXT CHANGED BETWEEN PROVIDERS\n' >"$worktree/context/shared.md" ;;
      missing) rm -f "$worktree/context/shared.md" ;;
      revoked)
        python3 - "${{DRIVER_STUB_POLICY_CONFIG:?}}" <<'PY'
import json,sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["contextService"]["codePaths"] = []
json.dump(value, open(path, "w", encoding="utf-8"), sort_keys=True)
PY
        ;;
    esac
    exit 124
  fi
  printf 'ORBIT-CONTEXT implemented attempt %s\n' "$count" >"$worktree/widget.txt"
  python3 - "$out" "$worktree" <<'PY'
import json,sys
json.dump({{
 "schema":"singular.orchestration.state-packet.v0","packetId":"fixture-packet",
 "runId":"fixture","taskId":"TASK-0001","area":"widget","role":"l2-developer",
 "status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-context",
 "headSha":"uncommitted","workspace":sys.argv[2],"ownedFiles":["widget.txt"],
 "changedFiles":["widget.txt"],"commands":[],"tests":[],"evidence":[],"blockers":[],
 "nextAction":"audit","createdAt":"2026-09-12T00:00:00Z"
}}, open(sys.argv[1],"w"))
PY
  if [[ -n "$session_meta" ]]; then
    python3 - "$session_meta" "$worktree" <<'PY'
import json,sys
from datetime import datetime, timezone
json.dump({{
 "schema":"singular.orchestration.session-meta.v0", "provider":"fixture",
 "sessionId":"worker-fixture-session", "model":"fixture", "effort":"low",
 "cwd":sys.argv[2], "exitCode":0,
 "createdAt":datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
}}, open(sys.argv[1], "w", encoding="utf-8"))
PY
  fi
elif [[ "$kind" == paired ]]; then
  printf '%s\n' '{{"verdict":"accepted","findings":[]}}' >"$out"
elif [[ "$role" == auditor ]]; then
  if [[ "$count" == "1" ]]; then
    case "${{DRIVER_STUB_AUDIT_INFRA:-}}" in
      timeout) exit 124 ;;
      empty) : >"$out"; exit 1 ;;
    esac
  fi
  if [[ "${{DRIVER_STUB_AUDIT_REPAIR:-0}}" == "1" && "$count" == "1" ]]; then
    printf '%s\n' '{{"schema":"wrong.audit.schema","verdict":"accepted"}}' >"$out"
    exit 0
  fi
  python3 - "$out" "$run_id" "$count" "${{DRIVER_STUB_RETRY:-0}}" <<'PY'
import json,sys
retry = sys.argv[4] == "1" and sys.argv[3] == "1"
json.dump({{
 "schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-0001",
 "runId":sys.argv[2],"branch":"agent/widget/TASK-0001-context","verdict":"needs-fix" if retry else "accepted",
 "evidenceReviewed":["evidence-manifest.json","audit-verification.json"],
 "commandsRun":[],"findings":["change the widget"] if retry else [],
 "requiredFixes":["change the widget"] if retry else [],"rationale":"host evidence reviewed"
}}, open(sys.argv[1],"w"))
PY
else
  exit 91
fi
""")
        stub.chmod(0o755)
        for command in (["git", "init", "-q"], ["git", "checkout", "-q", "-b", "target"],
                        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "add", "."],
                        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-qm", "init"]):
            completed = run(command, cwd=self.repo)
            self.assertEqual(completed.returncode, 0, completed.stdout)
        return config, stub, capture

    def commit_context_enabled(self, config: Path, enabled: bool) -> None:
        value = json.loads(config.read_text(encoding="utf-8"))
        value["contextService"]["enabled"] = enabled
        write(config, json.dumps(value, sort_keys=True))
        for command in (
            ["git", "add", "singular.config.json"],
            ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid",
             "commit", "-qm", f"context {'on' if enabled else 'off'}"],
        ):
            completed = run(command, cwd=self.repo)
            self.assertEqual(completed.returncode, 0, completed.stdout)

    def publish_paired_evidence(self, run_dir: Path) -> None:
        head = run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
        packet = {
            "schema": "singular.orchestration.state-packet.v0",
            "taskId": "TASK-0001", "runId": "RUN-paired", "headSha": head,
        }
        command = "true"
        report = {
            **packet,
            "schema": "singular.orchestration.gate-report.v0",
            "outcome": "passed", "command": command,
            "commandSha256": hashlib.sha256(command.encode()).hexdigest(),
            "sourceIntegrity": {"status": "verified"},
        }
        artifacts = []
        for name, value in (("packet.json", packet), ("audit-verification.json", report)):
            raw = json.dumps(value, sort_keys=True).encode()
            (run_dir / name).write_bytes(raw)
            artifacts.append({
                "ref": name, "bytes": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest(),
            })
        write(run_dir / "evidence-manifest.json", json.dumps({
            "schema": "singular.orchestration.evidence-manifest.v0",
            "taskId": "TASK-0001", "runId": "RUN-paired", "headSha": head,
            "budget": {
                "limitBytes": 262144, "excerptLimitBytes": 2048,
                "retrievalLimitBytes": 262144,
            },
            "artifacts": artifacts,
        }, sort_keys=True))

    def worker_env(self, config: Path, stub: Path, **extra: str) -> dict[str, str]:
        self.require_real_broker()
        env = {
            "SINGULAR_ROOT": str(self.repo), "SINGULAR_ENGINE_HOME": str(ROOT),
            "SINGULAR_ORCH_DIR": str(self.repo / "docs/orchestration"),
            "SINGULAR_TASKS_DIR": str(self.repo / "docs/orchestration/tasks"),
            "SINGULAR_STATE_DIR": str(self.repo / ".singular-state"),
            "SINGULAR_TARGET_BRANCH": "target", "SINGULAR_RUNNER": str(stub),
            "SINGULAR_JSON_CONFIG_FILE": str(config), "SINGULAR_MAX_RETRIES": "0",
            "SINGULAR_WORKER_INFRA_MAX": "0", "SINGULAR_AUDIT_INFRA_MAX": "0",
            "SINGULAR_AUDIT_VERIFY": "0", "SINGULAR_PAIRED_AUDIT_PCT": "0",
            "SINGULAR_CTX_ROUTING": "0", "SINGULAR_DISK_RESERVE_BYTES": "0",
            "SINGULAR_MIN_DISK_GB": "0", "TMPDIR": "/tmp",
            # Host acceptance must exercise evidence_delivery.Broker itself.
            # An AF_UNIX-ineligible sandbox is unavailable, never a passing
            # substitute for the production transport.
            "PYTHONPATH": "",
            "DRIVER_STUB_POLICY_CONFIG": str(config),
        }
        env.update(extra)
        return env

    def test_real_worker_final_and_paired_audits_use_isolated_atomic_bundles(self) -> None:
        config, stub, capture = self.worker_fixture()
        env = self.worker_env(config, stub, SINGULAR_PAIRED_AUDIT_PCT="100")
        result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                     cwd=self.repo, env=env)
        self.assertEqual(result.returncode, 0, result.stdout)
        worker = (capture / "implementer.md").read_text(encoding="utf-8")
        final = (capture / "auditor.md").read_text(encoding="utf-8")
        paired = (capture / "paired.md").read_text(encoding="utf-8")
        self.assertIn("ORBIT-CONTEXT planner implement widget invariant", worker)
        self.assertIn("WORKER-CONCLUSION-UNTRUSTED", worker)
        for audit_prompt in (final, paired):
            self.assertIn("ORBIT-CONTEXT planner implement widget invariant", audit_prompt)
            self.assertIn("REQUIRED-ORBIT-OBLIGATION", audit_prompt)
            self.assertNotIn("WORKER-CONCLUSION-UNTRUSTED", audit_prompt)
            self.assertIn("## Complete host-delivered review evidence", audit_prompt)
            self.assertIn("Artifact: packet.json SHA256:", audit_prompt)
            self.assertIn("Artifact: audit-verification.json SHA256:", audit_prompt)
        self.assertNotIn("--resume-session", (capture / "auditor.args").read_text())
        self.assertNotIn("--resume-session", (capture / "paired.args").read_text())

        run_dir = self.run_dir()
        events = (self.repo / ".singular-state/events.ndjson").read_text(encoding="utf-8")
        worker_bundles = [json.loads(path.read_text()) for path in
                          run_dir.glob("context-implementer-attempt-1*.bundle.json")]
        matching_workers = [bundle for bundle in worker_bundles if bundle.get("prompt") == worker]
        self.assertEqual(len(matching_workers), 1)
        self.assertIn(matching_workers[0]["bundleId"], events)
        self.assert_final_delivery_binding(
            capture, run_dir, "auditor", 1
        )
        self.assert_final_delivery_binding(
            capture, run_dir, "paired", 1
        )
        audit_bundle = next(
            json.loads(path.read_text()) for path in
            run_dir.glob("context-review-target-attempt-1*.bundle.json")
            if json.loads(path.read_text()).get("prompt") == final
        )
        self.assertEqual(audit_bundle["identity"]["role"], "review-target")
        self.assertNotIn("run", {item["kind"] for item in audit_bundle["provenance"]})
        self.assertTrue((self.repo / ".singular-state/evidence-deliveries.sqlite3").is_file())

    def test_real_worker_product_retry_receives_context_delta_references(self) -> None:
        config, stub, capture = self.worker_fixture()
        env = self.worker_env(
            config, stub, SINGULAR_MAX_RETRIES="1", DRIVER_STUB_RETRY="1"
        )
        result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                     cwd=self.repo, env=env)
        self.assertEqual(result.returncode, 0, result.stdout)
        retry_prompt = (capture / "implementer-2.md").read_text(encoding="utf-8")
        self.assertIn("code:context/shared.md unchanged", retry_prompt)
        self.assertIn("run:context/worker.json unchanged", retry_prompt)
        self.assertNotIn("ORBIT-CONTEXT planner implement widget invariant", retry_prompt)
        self.assertNotIn("WORKER-CONCLUSION-UNTRUSTED", retry_prompt)
        run_dir = next((self.repo / ".singular-state/runs").glob("RUN-*"))
        retry_bundle = json.loads((run_dir / "context-implementer-attempt-2.bundle.json").read_text())
        reasons = [reason for item in retry_bundle["provenance"] for reason in item["reasons"]]
        self.assertIn("unchanged_immutable_reference", reasons)
        self.assertTrue(any(reason.startswith("prior_bundle:sha256:") for reason in reasons))
        self.assertLessEqual(retry_bundle["budget"]["usedBytes"], retry_bundle["budget"]["limitBytes"])

    def test_worker_infrastructure_retry_retains_prior_bundle_and_revalidates_changed_source(self) -> None:
        config, stub, capture = self.worker_fixture()
        env = self.worker_env(
            config, stub, SINGULAR_WORKER_INFRA_MAX="1",
            DRIVER_STUB_INFRA_TRANSITION="changed",
        )
        result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                     cwd=self.repo, env=env)
        self.assertEqual(result.returncode, 0, result.stdout)
        second = (capture / "implementer-2.md").read_text(encoding="utf-8")
        self.assertIn("ORBIT-CONTEXT CHANGED BETWEEN PROVIDERS", second)
        self.assertNotIn("planner implement widget invariant", second)
        first = (capture / "implementer-1.md").read_text(encoding="utf-8")
        run_dir = self.run_dir()
        bundles = [json.loads(path.read_text()) for path in
                   run_dir.glob("context-implementer-attempt-1*.bundle.json")]
        first_bundles = [bundle for bundle in bundles if bundle.get("prompt") == first]
        second_bundles = [bundle for bundle in bundles if bundle.get("prompt") == second]
        self.assertEqual(len(first_bundles), 1, "the earlier invocation bundle must remain immutable")
        self.assertEqual(len(second_bundles), 1, "the retry must publish a distinct bundle")
        reasons = [reason for item in second_bundles[0]["provenance"] for reason in item["reasons"]]
        self.assertIn("changed_source", reasons)
        self.assertIn("prior_bundle:" + first_bundles[0]["bundleId"], reasons)

    def test_worker_infrastructure_retry_revalidates_missing_and_revoked_sources(self) -> None:
        for transition in ("missing", "revoked"):
            with self.subTest(transition=transition):
                if transition != "missing":
                    self.reset_fixture("singular-context-transition.")
                config, stub, capture = self.worker_fixture()
                env = self.worker_env(
                    config, stub, SINGULAR_WORKER_INFRA_MAX="1",
                    DRIVER_STUB_INFRA_TRANSITION=transition,
                )
                result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                             cwd=self.repo, env=env)
                if transition == "missing":
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("missing source", result.stdout)
                    self.assertEqual((capture / "implementer.count").read_text().strip(), "1")
                    write(self.repo / ".worktrees/TASK-0001/context/shared.md",
                          "ORBIT-CONTEXT planner implement widget invariant\n")
                else:
                    self.assertEqual(result.returncode, 0, result.stdout)
                    second = (capture / "implementer-2.md").read_text(encoding="utf-8")
                    self.assertIn("Revoked since the prior bundle: code:context/shared.md", second)
                    run_dir = self.run_dir()
                    bundle = next(
                        json.loads(path.read_text()) for path in
                        run_dir.glob("context-implementer-attempt-1*.bundle.json")
                        if json.loads(path.read_text()).get("prompt") == second
                    )
                    self.assertIn({"ref": "code:context/shared.md",
                                   "reason": "revoked_since_prior_bundle"}, bundle["omissions"])

    def test_worker_rc86_fresh_fallback_revalidates_changed_missing_and_revoked_sources(self) -> None:
        for transition in ("changed", "missing", "revoked"):
            with self.subTest(transition=transition):
                if transition != "changed":
                    self.reset_fixture("singular-worker-fallback.")
                config, stub, capture = self.worker_fixture()
                env = self.worker_env(
                    config, stub, SINGULAR_MAX_RETRIES="1", DRIVER_STUB_RETRY="1",
                    DRIVER_STUB_RESUME_TRANSITION=transition,
                )
                result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                             cwd=self.repo, env=env)
                calls = int((capture / "implementer.count").read_text().strip())
                refused_args = (capture / "implementer-2.args").read_text(encoding="utf-8")
                self.assertIn("--resume-session", refused_args)
                if transition == "missing":
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("missing source", result.stdout)
                    self.assertEqual(calls, 2, "missing source must stop the fresh provider fallback")
                    write(self.repo / ".worktrees/TASK-0001/context/shared.md",
                          "ORBIT-CONTEXT planner implement widget invariant\n")
                    run_dir = self.run_dir()
                    refused = (capture / "implementer-2.md").read_text(encoding="utf-8")
                    retained = [json.loads(path.read_text()) for path in
                                run_dir.glob("context-implementer-attempt-2*.bundle.json")]
                    self.assertTrue(
                        any(bundle.get("prompt") == refused for bundle in retained),
                        "the admitted refused-resume bundle must remain immutable",
                    )
                    continue
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(calls, 3, (transition, refused_args, result.stdout))
                self.assertNotIn(
                    "--resume-session",
                    (capture / "implementer-3.args").read_text(encoding="utf-8"),
                )
                fallback = (capture / "implementer-3.md").read_text(encoding="utf-8")
                if transition == "changed":
                    self.assertIn("ORBIT-CONTEXT CHANGED DURING WORKER RESUME", fallback)
                else:
                    self.assertIn("Revoked since the prior bundle: code:context/shared.md", fallback)
                run_dir = self.run_dir()
                retained = [json.loads(path.read_text()) for path in
                            run_dir.glob("context-implementer-attempt-2*.bundle.json")]
                self.assertTrue(any(bundle.get("prompt") == fallback for bundle in retained))
                self.assertGreaterEqual(
                    len(retained), 2,
                    "the refused resume bundle and fresh fallback bundle must both remain addressable",
                )

    def test_public_boundary_refuses_invalid_config_and_campaign_drift_before_debit_or_provider(self) -> None:
        config, _, capture = self.worker_fixture()
        run_dir = self.repo / ".singular-state/runs/RUN-paired"
        run_dir.mkdir(parents=True)
        self.publish_paired_evidence(run_dir)
        provider = Path(self.temp.name) / "boundary-provider.sh"
        marker = capture / "boundary-provider-called"
        write(provider, f"#!{BASH}\nset -euo pipefail\ntouch '{marker}'\n")
        provider.chmod(0o755)
        base = run_dir / "base.md"
        write(base, "REVIEW BASE\n")
        ledger = self.repo / ".singular-state/evidence-deliveries.sqlite3"
        bundle = run_dir / "context-review-target-policy.bundle.json"
        receipt = run_dir / "context-invocation-policy.json"
        common = [
            sys.executable, str(ROOT / "engine/evidence_delivery.py"), "run",
            "--manifest", str(run_dir / "evidence-manifest.json"),
            "--ledger", str(ledger), "--required", "packet.json",
            "--required", "audit-verification.json", "--context-config", str(config),
            "--context-role", "review-target", "--context-phase", "final-audit",
            "--context-task", str(self.repo / "docs/orchestration/tasks/TASK-0001.md"),
            "--context-bundle", str(bundle), "--context-invocation-id", "policy-check",
            "--receipt", str(receipt), "--events-file",
            str(self.repo / ".singular-state/events.ndjson"),
        ]
        env = {
            "SINGULAR_ROOT": str(self.repo), "SINGULAR_ENGINE_HOME": str(ROOT),
            "SINGULAR_LIB_DIR": str(ROOT / "engine"),
            "SINGULAR_ORCH_DIR": str(self.repo / "docs/orchestration"),
            "SINGULAR_TASKS_DIR": str(self.repo / "docs/orchestration/tasks"),
            "SINGULAR_STATE_DIR": str(self.repo / ".singular-state"),
            "SINGULAR_JSON_CONFIG_FILE": str(config),
        }
        original = config.read_text(encoding="utf-8")
        write(config, '{"contextService":')
        invalid = run(
            common + ["--campaign-binding", "legacy", "--", str(provider),
                      "--prompt-file", str(base)],
            cwd=self.repo, env=env,
        )
        self.assertNotEqual(invalid.returncode, 0, invalid.stdout)
        self.assertRegex(invalid.stdout, r"context configuration|failed to parse")
        self.assertFalse(marker.exists())
        invalid_receipt = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(invalid_receipt["status"], "denied")
        self.assertEqual(invalid_receipt["denial"]["reason"], "context-invalid")
        self.assertEqual(invalid_receipt["retrievalDebitBytes"], 0)
        self.assertFalse(bundle.exists())
        self.assertEqual(self.ledger_details(), [])

        write(config, original)
        receipt.unlink()
        drift = run(
            common + ["--campaign-binding", "campaign:wrong", "--", str(provider),
                      "--prompt-file", str(base)],
            cwd=self.repo, env=env,
        )
        self.assertNotEqual(drift.returncode, 0, drift.stdout)
        self.assertIn("campaign identity changed", drift.stdout)
        self.assertFalse(marker.exists())
        drift_receipt = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(drift_receipt["status"], "denied")
        self.assertEqual(drift_receipt["denial"]["reason"], "campaign-mismatch")
        self.assertEqual(drift_receipt["retrievalDebitBytes"], 0)
        self.assertFalse(bundle.exists())
        self.assertEqual(self.ledger_details(), [])

    def test_audit_validation_repair_bundle_matches_host_delivered_prompt(self) -> None:
        config, stub, capture = self.worker_fixture()
        env = self.worker_env(
            config, stub, SINGULAR_AUDIT_INFRA_MAX="1", DRIVER_STUB_AUDIT_REPAIR="1"
        )
        result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                     cwd=self.repo, env=env)
        self.assertEqual(result.returncode, 0, result.stdout)
        repaired = (capture / "auditor-2.md").read_text(encoding="utf-8")
        self.assertIn("audit-repair-input", repaired)
        self.assertIn("wrong.audit.schema", repaired)
        self.assertIn("## Complete host-delivered review evidence", repaired)
        run_dir = self.run_dir()
        self.assert_final_delivery_binding(
            capture, run_dir, "auditor", 2
        )
        bundle = next(
            json.loads(path.read_text()) for path in
            run_dir.glob("context-review-target-attempt-1*.bundle.json")
            if json.loads(path.read_text()).get("prompt") == repaired
        )
        self.assertLessEqual(bundle["budget"]["usedBytes"], bundle["budget"]["limitBytes"])

    def test_identical_base_audit_timeout_and_empty_output_retries_reach_second_provider(self) -> None:
        for failure in ("timeout", "empty"):
            with self.subTest(failure=failure):
                if failure != "timeout":
                    self.reset_fixture("singular-audit-identical.")
                config, stub, capture = self.worker_fixture()
                env = self.worker_env(
                    config, stub, SINGULAR_AUDIT_INFRA_MAX="1",
                    DRIVER_STUB_AUDIT_INFRA=failure,
                )
                result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                             cwd=self.repo, env=env)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual((capture / "auditor.count").read_text().strip(), "2")
                first = (capture / "auditor-1.md").read_bytes()
                second = (capture / "auditor-2.md").read_bytes()
                self.assertEqual(first, second, "infrastructure retry must reproduce the same base input")
                run_dir = self.run_dir()
                self.assert_final_delivery_binding(
                    capture, run_dir, "auditor", 1,
                )
                self.assert_final_delivery_binding(
                    capture, run_dir, "auditor", 2,
                )
                prompt_sha = "sha256:" + hashlib.sha256(first).hexdigest()
                events = [json.loads(line) for line in
                          (self.repo / ".singular-state/events.ndjson").read_text().splitlines()]
                retry_bundles = {
                    event["data"]["bundleRef"] for event in events
                    if event.get("type") == "context.bundle_selected"
                    and event.get("data", {}).get("promptSha256") == prompt_sha
                }
                self.assertGreaterEqual(
                    len(retry_bundles), 2,
                    "each admitted auditor invocation must retain its own immutable bundle",
                )

    def test_final_composed_cap_includes_context_and_is_separate_from_retrieval_budget(self) -> None:
        config, stub, capture = self.worker_fixture()
        write(self.repo / "context/shared.md", "FINAL-CAP-CONTEXT " + ("x" * 5000) + "\n")
        run(["git", "add", "context/shared.md"], cwd=self.repo)
        committed = run([
            "git", "-c", "user.name=test", "-c", "user.email=test@example.invalid",
            "commit", "-qm", "large context source",
        ], cwd=self.repo)
        self.assertEqual(committed.returncode, 0, committed.stdout)
        env = self.worker_env(
            config, stub,
            SINGULAR_EVIDENCE_CONFIG_JSON=json.dumps({
                "maxComposedBytes": 10000,
                "retrievalBudgetBytes": 262144,
                "maxExcerptBytes": 2048,
                "auditInputTokenCanary": 100000,
            }),
        )
        result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                     cwd=self.repo, env=env)
        run_dir = self.run_dir()
        base = (run_dir / "auditor-bound-prompt-attempt-1.md").read_bytes()
        manifest = json.loads((run_dir / "evidence-manifest.json").read_text())
        required = []
        legacy_chunks = [base, b"\n\n## Complete host-delivered review evidence\n"]
        for ref in ("packet.json", "audit-verification.json"):
            data = (run_dir / ref).read_bytes()
            legacy_chunks.extend([
                f"\nArtifact: {ref} SHA256: {hashlib.sha256(data).hexdigest()}\n".encode(),
                data, b"\n",
            ])
            required.append({
                "ref": ref, "data": data, "sourceLocation": str(run_dir / ref),
            })
        pre_context_bytes = len(b"".join(legacy_chunks))
        self.assertLessEqual(
            pre_context_bytes, manifest["budget"]["limitBytes"],
            "fixture must be admitted before shared context is added",
        )
        packet = json.loads((run_dir / "packet.json").read_text())
        workspace = Path(packet["workspace"])
        uncapped = ContextService.from_config(
            config, role="review-target", phase="final-audit", workspace=workspace,
        ).build(
            task=workspace / "docs/orchestration/tasks/TASK-0001.md",
            phase="final-audit", budget_bytes=16384,
            base_prompt=run_dir / "auditor-bound-prompt-attempt-1.md",
            delivery="initial", required_evidence=required,
            invocation_id="cap-proof", campaign_binding="legacy",
        )
        self.assertGreater(
            len(uncapped["prompt"].encode()), manifest["budget"]["limitBytes"],
            "fixture must exceed the manifest cap only after final composition",
        )
        admission_count = (
            int((capture / "auditor.count").read_text())
            if (capture / "auditor.count").exists() else 0
        )
        debits = [detail for detail in self.ledger_details()
                  if detail.get("kind") == "required-prompt"]
        self.assertEqual(admission_count, 0, result.stdout)
        self.assertEqual(
            len(debits), 0,
            "final composed-cap refusal must precede evidence retrieval debit",
        )

    def test_primary_restricted_actual_adapter_is_rejected_context_on_and_off_before_debit(self) -> None:
        for enabled in (True, False):
            with self.subTest(enabled=enabled):
                if not enabled:
                    self.reset_fixture("singular-restricted-primary.")
                config, stub, capture = self.worker_fixture()
                if not enabled:
                    self.commit_context_enabled(config, False)
                restricted = stub.with_name("claude-run.sh")
                stub.rename(restricted)
                env = self.worker_env(config, restricted)
                result = run([str(BASH), str(ROOT / "engine/l1-drive.sh"), "TASK-0001"],
                             cwd=self.repo, env=env)
                self.assertFalse((capture / "auditor.count").exists(), result.stdout)
                self.assertFalse(
                    [detail for detail in self.ledger_details()
                     if detail.get("kind") == "required-prompt"],
                    "restricted adapter refusal must precede evidence debit",
                )
                audit_log = (self.run_dir() / "auditor-codex.log").read_text(encoding="utf-8")
                self.assertIn("OS-enforced read-only adapter", audit_log)

    def test_paired_restricted_actual_adapter_is_rejected_context_on_and_off_before_debit(self) -> None:
        for enabled in (True, False):
            with self.subTest(enabled=enabled):
                if not enabled:
                    self.reset_fixture("singular-restricted-paired.")
                config, stub, capture = self.worker_fixture()
                if not enabled:
                    self.commit_context_enabled(config, False)
                restricted = stub.with_name("claude-run.sh")
                stub.rename(restricted)
                run_dir = self.repo / ".singular-state/runs/RUN-paired"
                run_dir.mkdir(parents=True)
                self.publish_paired_evidence(run_dir)
                env = self.worker_env(
                    config, restricted, SINGULAR_PAIRED_AUDIT_PCT="100",
                    SINGULAR_RUNNER=str(restricted), SINGULAR_LIB_DIR=str(ROOT / "engine"),
                    SINGULAR_ENGINE_DIR=str(ROOT / "engine"),
                )
                script = (
                    'source "$1/engine/lib.sh"; '
                    'singular_ctx_paired_audit_record RUN-paired TASK-0001 "$2" "$3"'
                )
                result = run([
                    str(BASH), "-c", script, "paired-test", str(ROOT),
                    str(run_dir), str(self.repo),
                ], cwd=self.repo, env=env)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertFalse((capture / "paired.count").exists(), result.stdout)
                self.assertFalse(
                    [detail for detail in self.ledger_details()
                     if detail.get("kind") == "required-prompt"],
                    "paired restricted adapter refusal must precede evidence debit",
                )
                record = json.loads((run_dir / "paired-audit.json").read_text())
                self.assertNotEqual(record["runnerExit"], 0)


if __name__ == "__main__":
    unittest.main()
