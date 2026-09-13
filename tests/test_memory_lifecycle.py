from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "memory-lifecycle"
MEMORY_CLI = ROOT / "engine" / "memory_service.py"
CONTEXT_CLI = ROOT / "engine" / "context_cli.py"


def digest(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


class MemoryLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.workspace = Path(self.temp.name) / "project"
        shutil.copytree(FIXTURES, self.workspace)
        authority = self.workspace / "reviewer-authority.json"
        human = self.workspace / "human-authority.json"
        code = self.workspace / "reviewer-code.py"
        self.config = self.workspace / "singular.config.json"
        self.config.write_text(json.dumps({
            "contextService": {
                "enabled": True,
                "projectId": "fixture-project",
                "revision": "fixture-revision",
                "budgetBytes": 32768,
                "rolePolicy": {"implementer": ["memory"]},
            },
            "memoryService": {
                "enabled": True,
                "storePath": ".memory",
                "maxContentBytes": 4096,
                "maxCheckpointBytes": 4096,
                "authorities": {
                    "independent-reviewer": {
                        "source": "reviewer-authority.json",
                        "sha256": digest(authority),
                        "codeIdentity": [{"path": "reviewer-code.py", "sha256": digest(code)}],
                    },
                    "human-reviewer": {
                        "source": "human-authority.json",
                        "sha256": digest(human),
                        "codeIdentity": [{"path": "reviewer-code.py", "sha256": digest(code)}],
                    },
                },
                "consumerPolicies": {
                    "task": {
                        "scopes": ["project"],
                        "approverRoles": ["memory-reviewer"],
                        "humanReviewRequired": False,
                        "contextRoles": ["implementer"],
                    },
                    "human-only": {
                        "scopes": ["project"],
                        "approverRoles": ["memory-reviewer"],
                        "humanReviewRequired": True,
                        "contextRoles": ["implementer"],
                    },
                },
            },
        }, sort_keys=True), encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def memory(self, *args: str, ok: bool = True) -> dict:
        proc = subprocess.run(
            [sys.executable, str(MEMORY_CLI), "--repo-root", str(self.workspace),
             "--cwd", str(self.workspace), "--", *args, "--config", str(self.config)],
            text=True, capture_output=True,
        )
        if ok and proc.returncode != 0:
            self.fail(f"memory command failed ({proc.returncode}): {proc.stderr}")
        if not ok:
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
            return {"stderr": proc.stderr, "returncode": proc.returncode}
        return json.loads(proc.stdout)

    def propose(self, operation: str, *, actor: str = "task-a-worker",
                policy: str = "task", content: str = "candidate.md") -> dict:
        return self.memory(
            "propose", "--operation-id", operation, "--task", "TASK-A",
            "--actor", actor, "--scope", "project", "--policy", policy,
            "--content-file", content, "--source", "source-event.json",
            "--code", "reviewer-code.py",
        )

    def approve(self, memory_id: str, operation: str,
                authority: str = "independent-reviewer", ok: bool = True) -> dict:
        return self.memory(
            "approve", "--operation-id", operation, "--memory-id", memory_id,
            "--authority", authority, ok=ok,
        )

    def context_search(self, query: str) -> dict:
        proc = subprocess.run(
            [sys.executable, str(CONTEXT_CLI), "--repo-root", str(self.workspace),
             "--cwd", str(self.workspace), "--", "search", "--config", str(self.config),
             "--workspace", str(self.workspace), "--role", "implementer",
             "--query", query], text=True, capture_output=True,
        )
        if proc.returncode:
            self.fail(proc.stderr)
        return json.loads(proc.stdout)

    def context_get(self, ref: str, version: str) -> dict:
        proc = subprocess.run(
            [sys.executable, str(CONTEXT_CLI), "--repo-root", str(self.workspace),
             "--cwd", str(self.workspace), "--", "get", "--config", str(self.config),
             "--workspace", str(self.workspace), "--role", "implementer",
             "--ref", ref, "--version", version], text=True, capture_output=True,
        )
        if proc.returncode:
            self.fail(proc.stderr)
        return json.loads(proc.stdout)

    def test_proposal_requires_verified_independent_approval(self) -> None:
        proposed = self.propose("proposal-1")
        self.assertEqual(proposed["memory"]["status"], "proposed")
        self.assertEqual(proposed["memory"]["trust"], "untrusted")
        self.assertEqual(proposed["memory"]["sources"][0]["path"], "source-event.json")
        self.assertEqual(proposed["memory"]["sources"][0]["sha256"],
                         digest(self.workspace / "source-event.json"))
        self.assertTrue(self.context_search("transient capacity")["abstained"])

        self_review = self.approve(
            proposed["memory"]["memoryId"], "approval-self",
            authority="independent-reviewer", ok=False,
        ) if proposed["memory"]["proposer"]["actorId"] == "review-worker" else None
        self.assertIsNone(self_review)

        reviewed = self.memory(
            "review", "--memory-id", proposed["memory"]["memoryId"],
            "--authority", "independent-reviewer",
        )
        self.assertTrue(reviewed["eligible"])
        approved = self.approve(proposed["memory"]["memoryId"], "approval-1")
        self.assertEqual(approved["memory"]["status"], "approved")
        found = self.context_search("transient capacity")
        self.assertEqual([r["ref"] for r in found["results"]],
                         ["memory:" + proposed["memory"]["memoryId"]])
        provenance = found["results"][0]["provenance"]
        self.assertEqual(provenance["proposal"]["taskId"], "TASK-A")
        self.assertEqual(provenance["approval"]["authorityId"], "independent-reviewer")
        retrieved = self.context_get(found["results"][0]["ref"],
                                     found["results"][0]["sourceSha256"])
        self.assertEqual(retrieved["text"],
                         (self.workspace / "candidate.md").read_text(encoding="utf-8"))
        self.assertEqual(retrieved["provenance"]["proposal"]["taskId"], "TASK-A")

        self_proposed = self.propose("proposal-self", actor="review-worker")
        denied = self.approve(self_proposed["memory"]["memoryId"], "approval-self", ok=False)
        self.assertIn("independent", denied["stderr"])
        human_candidate = self.propose("proposal-human", policy="human-only")
        denied = self.approve(human_candidate["memory"]["memoryId"], "approval-not-human", ok=False)
        self.assertIn("human", denied["stderr"])
        self.approve(human_candidate["memory"]["memoryId"], "approval-human", "human-reviewer")

    def test_replay_reject_supersede_tombstone_restart_and_rebuild(self) -> None:
        first = self.propose("proposal-replay")
        replay = self.propose("proposal-replay")
        self.assertEqual(first, replay)
        altered = self.memory(
            "propose", "--operation-id", "proposal-replay", "--task", "TASK-A",
            "--actor", "other", "--scope", "project", "--policy", "task",
            "--content-file", "candidate.md", "--source", "source-event.json",
            ok=False,
        )
        self.assertIn("operation-id conflict", altered["stderr"])

        rejected = self.propose("proposal-rejected")
        self.memory("reject", "--operation-id", "reject-1", "--memory-id",
                    rejected["memory"]["memoryId"], "--authority", "independent-reviewer",
                    "--reason", "not general enough")
        self.assertNotIn("memory:" + rejected["memory"]["memoryId"],
                         [r["ref"] for r in self.context_search("transient capacity")["results"]])

        quarantined = self.propose("proposal-quarantined")
        quarantine = self.memory(
            "quarantine", "--operation-id", "quarantine-1", "--memory-id",
            quarantined["memory"]["memoryId"], "--authority", "independent-reviewer",
            "--reason", "citation requires investigation",
        )
        self.assertEqual(quarantine["memory"]["status"], "quarantined")
        self.assertNotIn("memory:" + quarantined["memory"]["memoryId"],
                         [r["ref"] for r in self.context_search("transient capacity")["results"]])

        old = self.propose("proposal-old")
        new = self.propose("proposal-new")
        self.approve(old["memory"]["memoryId"], "approve-old")
        self.approve(new["memory"]["memoryId"], "approve-new")
        self.memory("supersede", "--operation-id", "supersede-1", "--memory-id",
                    old["memory"]["memoryId"], "--by", new["memory"]["memoryId"],
                    "--authority", "independent-reviewer")
        self.memory("tombstone", "--operation-id", "tombstone-1", "--memory-id",
                    new["memory"]["memoryId"], "--authority", "independent-reviewer",
                    "--reason", "retired by policy")
        index = self.workspace / ".memory" / "index.json"
        index.unlink()
        rebuilt = self.memory("rebuild")
        self.assertEqual(rebuilt["trustedCount"], 0)
        self.assertTrue(self.context_search("transient capacity")["abstained"])
        reopened = self.memory("show", "--memory-id", new["memory"]["memoryId"])
        self.assertEqual(reopened["memory"]["status"], "tombstoned")

    def test_authority_and_source_drift_fail_closed(self) -> None:
        candidate = self.propose("proposal-drift")
        (self.workspace / "reviewer-code.py").write_text("DRIFT = True\n", encoding="utf-8")
        denied = self.approve(candidate["memory"]["memoryId"], "approval-drift", ok=False)
        self.assertIn("code identity drift", denied["stderr"])
        (self.workspace / "reviewer-code.py").write_bytes(
            (FIXTURES / "reviewer-code.py").read_bytes())
        self.approve(candidate["memory"]["memoryId"], "approval-valid")
        (self.workspace / "reviewer-code.py").write_text("DRIFT = True\n", encoding="utf-8")
        self.assertTrue(self.context_search("transient capacity")["abstained"])
        invalid_authority = self.memory("show", "--memory-id", candidate["memory"]["memoryId"])
        self.assertEqual(invalid_authority["memory"]["trust"], "invalid-authority")
        (self.workspace / "reviewer-code.py").write_bytes(
            (FIXTURES / "reviewer-code.py").read_bytes())
        self.assertFalse(self.context_search("transient capacity")["abstained"])

        missing_candidate = self.propose("proposal-missing-source")
        (self.workspace / "source-event.json").unlink()
        denied = self.approve(missing_candidate["memory"]["memoryId"],
                              "approval-missing-source", ok=False)
        self.assertIn("retained source", denied["stderr"])
        result = self.context_search("transient capacity")
        self.assertTrue(result["abstained"])
        invalid = self.memory("show", "--memory-id", candidate["memory"]["memoryId"])
        self.assertEqual(invalid["memory"]["trust"], "invalid-source")

    def test_concurrent_capture_and_bounded_checkpoint_recovery(self) -> None:
        def create(i: int) -> str:
            return self.propose(f"concurrent-{i}")["memory"]["memoryId"]

        with ThreadPoolExecutor(max_workers=6) as pool:
            ids = list(pool.map(create, range(12)))
        self.assertEqual(len(set(ids)), 12)
        saved = self.memory(
            "checkpoint", "save", "--operation-id", "checkpoint-1",
            "--task", "TASK-A", "--actor", "task-a-worker",
            "--payload-file", "checkpoint.json", "--source", "source-event.json",
        )
        recovered = self.memory("checkpoint", "recover", "--task", "TASK-A")
        self.assertEqual(recovered["checkpointId"], saved["checkpointId"])
        self.assertEqual(recovered["payload"]["nextAction"],
                         "Use the approved retry discipline in task B.")
        (self.workspace / "source-event.json").unlink()
        absent = self.memory("checkpoint", "recover", "--task", "TASK-A", ok=False)
        self.assertIn("retained source", absent["stderr"])


if __name__ == "__main__":
    unittest.main()
