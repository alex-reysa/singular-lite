from __future__ import annotations

import hashlib
import hmac
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
sys.path.insert(0, str(ROOT))

from engine.context_service import ContextError, ContextService


FIXTURES = ROOT / "tests" / "fixtures" / "memory-lifecycle"
MEMORY_CLI = ROOT / "engine" / "memory_service.py"
CONTEXT_CLI = ROOT / "engine" / "context_cli.py"
PUBLIC_CLI = ROOT / "cli" / "singular"
CREDENTIAL_KEY = b"fixture-host-held-memory-credential-key"


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
                "credentialKeyId": "fixture-host-key",
                "credentialKeySha256": "sha256:" + hashlib.sha256(CREDENTIAL_KEY).hexdigest(),
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

    @staticmethod
    def _argument(args: tuple[str, ...], name: str) -> str:
        return args[args.index(name) + 1]

    def credential(self, args: tuple[str, ...], *, subject: str | None = None) -> str | None:
        command = args[0]
        claims: dict[str, object]
        if command == "propose":
            actor = subject or self._argument(args, "--actor")
            claims = {
                "action": "propose", "operationId": self._argument(args, "--operation-id"),
                "subjectId": actor, "subjectType": "internal-role",
                "taskId": self._argument(args, "--task"),
                "scope": self._argument(args, "--scope"),
                "policyId": self._argument(args, "--policy"),
                "contentPath": self._argument(args, "--content-file"),
                "sourcePath": self._argument(args, "--source"),
                "codePaths": [args[index + 1] for index, value in enumerate(args)
                              if value == "--code"],
            }
        elif command == "checkpoint" and args[1] == "save":
            actor = subject or self._argument(args, "--actor")
            claims = {
                "action": "checkpoint", "operationId": self._argument(args, "--operation-id"),
                "subjectId": actor, "subjectType": "internal-role",
                "taskId": self._argument(args, "--task"),
                "payloadPath": self._argument(args, "--payload-file"),
                "sourcePath": self._argument(args, "--source"),
            }
        elif command in {"approve", "reject", "quarantine", "supersede", "tombstone"}:
            authority = self._argument(args, "--authority")
            default_subject = "human-operator" if authority == "human-reviewer" else "review-worker"
            resolved_subject = subject or default_subject
            claims = {
                "action": command, "operationId": self._argument(args, "--operation-id"),
                "subjectId": resolved_subject,
                "subjectType": "human" if resolved_subject == "human-operator" else "internal-role",
                "authorityId": authority, "memoryId": self._argument(args, "--memory-id"),
            }
            if "--by" in args:
                claims["byMemoryId"] = self._argument(args, "--by")
            if "--reason" in args:
                claims["reason"] = self._argument(args, "--reason")
        else:
            return None
        document = {
            "schema": "singular.memory.credential.v1",
            "keyId": "fixture-host-key",
            **claims,
        }
        signature = hmac.new(
            CREDENTIAL_KEY,
            json.dumps(document, sort_keys=True, separators=(",", ":")).encode(),
            hashlib.sha256,
        ).hexdigest()
        document["signature"] = "hmac-sha256:" + signature
        name = hashlib.sha256(json.dumps(document, sort_keys=True).encode()).hexdigest()[:20]
        relative = f".credentials/{name}.json"
        path = self.workspace / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document, sort_keys=True), encoding="utf-8")
        return relative

    def memory(self, *args: str, ok: bool = True, credential_subject: str | None = None,
               omit_credential: bool = False, extra_env: dict[str, str] | None = None,
               public: bool = False) -> dict:
        credential = None if omit_credential else self.credential(args, subject=credential_subject)
        operation = [*args]
        if credential:
            operation.extend(("--credential", credential))
        if public:
            command = ["bash", str(PUBLIC_CLI), "memory", *operation,
                       "--config", str(self.config)]
        else:
            command = [sys.executable, str(MEMORY_CLI), "--repo-root", str(self.workspace),
                       "--cwd", str(self.workspace), "--", *operation,
                       "--config", str(self.config)]
        environment = dict(os.environ)
        environment["SINGULAR_MEMORY_CREDENTIAL_KEY"] = CREDENTIAL_KEY.decode()
        if public:
            environment["SINGULAR_ENGINE_HOME"] = str(ROOT)
        environment.update(extra_env or {})
        proc = subprocess.run(
            command, text=True, capture_output=True, cwd=self.workspace, env=environment,
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
        unauthenticated = self.memory(
            "propose", "--operation-id", "proposal-no-credential", "--task", "TASK-A",
            "--actor", "task-a-worker", "--scope", "project", "--policy", "task",
            "--content-file", "candidate.md", "--source", "source-event.json",
            omit_credential=True, ok=False,
        )
        self.assertIn("credential", unauthenticated["stderr"])
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

        impersonated = self.memory(
            "approve", "--operation-id", "approval-impersonated", "--memory-id",
            proposed["memory"]["memoryId"], "--authority", "independent-reviewer",
            credential_subject="task-a-worker", ok=False,
        )
        self.assertIn("credential subject", impersonated["stderr"])

        self_proposed = self.propose("proposal-self", actor="review-worker")
        denied = self.approve(self_proposed["memory"]["memoryId"], "approval-self", ok=False)
        self.assertIn("independent", denied["stderr"])
        human_candidate = self.propose("proposal-human", policy="human-only")
        denied = self.memory(
            "approve", "--operation-id", "approval-not-human", "--memory-id",
            human_candidate["memory"]["memoryId"], "--authority", "human-reviewer",
            credential_subject="review-worker", ok=False,
        )
        self.assertIn("credential subject", denied["stderr"])
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
        survivor = self.propose("proposal-survivor")
        self.approve(survivor["memory"]["memoryId"], "approve-survivor")
        index = self.workspace / ".memory" / "index.json"
        index.unlink()
        rebuilt = self.memory("rebuild")
        self.assertEqual(rebuilt["trusted"], [survivor["memory"]["memoryId"]])
        self.assertEqual([item["ref"] for item in self.context_search("transient capacity")["results"]],
                         ["memory:" + survivor["memory"]["memoryId"]])
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

    def test_authenticated_identity_scope_revocation_and_interrupted_replay(self) -> None:
        impersonated = self.memory(
            "propose", "--operation-id", "proposal-impersonated", "--task", "TASK-A",
            "--actor", "task-a-worker", "--scope", "project", "--policy", "task",
            "--content-file", "candidate.md", "--source", "source-event.json",
            credential_subject="attacker", ok=False,
        )
        self.assertIn("credential subject", impersonated["stderr"])

        candidate = self.propose("proposal-scope-before")
        config = json.loads(self.config.read_text(encoding="utf-8"))
        config["memoryService"]["consumerPolicies"]["task"]["scopes"] = []
        self.config.write_text(json.dumps(config, sort_keys=True), encoding="utf-8")
        denied = self.approve(candidate["memory"]["memoryId"], "approve-revoked", ok=False)
        self.assertIn("scope", denied["stderr"])

        config["memoryService"]["consumerPolicies"]["task"]["scopes"] = ["project"]
        self.config.write_text(json.dumps(config, sort_keys=True), encoding="utf-8")
        durable = self.propose("proposal-interrupted")
        interrupted = self.memory(
            "approve", "--operation-id", "approve-interrupted", "--memory-id",
            durable["memory"]["memoryId"], "--authority", "independent-reviewer",
            extra_env={"SINGULAR_MEMORY_FAIL_AFTER_STATE": "approve-interrupted"}, ok=False,
        )
        self.assertIn("injected interruption", interrupted["stderr"])
        recovered = self.approve(durable["memory"]["memoryId"], "approve-interrupted")
        self.assertEqual(recovered["memory"]["status"], "approved")
        self.assertEqual(
            self.approve(durable["memory"]["memoryId"], "approve-interrupted"),
            recovered,
        )

        config["memoryService"]["consumerPolicies"]["task"]["scopes"] = []
        self.config.write_text(json.dumps(config, sort_keys=True), encoding="utf-8")
        self.assertTrue(self.context_search("transient capacity")["abstained"])
        invalid = self.memory("show", "--memory-id", durable["memory"]["memoryId"])
        self.assertEqual(invalid["memory"]["trust"], "invalid-authority")

    def test_memory_dependencies_are_one_revalidated_context_snapshot(self) -> None:
        candidate = self.propose("proposal-snapshot")
        self.approve(candidate["memory"]["memoryId"], "approve-snapshot")
        service = ContextService.from_config(
            self.config, role="implementer", workspace=self.workspace,
            environment=os.environ,
        )
        artifact = self.workspace / "candidate.md"
        artifact.write_text(artifact.read_text(encoding="utf-8") + "\nTAMPERED\n",
                            encoding="utf-8")
        with self.assertRaisesRegex(ContextError, "eligibility metadata changed"):
            service.search("transient capacity")
        artifact.write_bytes((FIXTURES / "candidate.md").read_bytes())

        service = ContextService.from_config(
            self.config, role="implementer", workspace=self.workspace,
            environment=os.environ,
        )
        (self.workspace / "reviewer-code.py").write_text("REVOKED = True\n", encoding="utf-8")
        with self.assertRaisesRegex(ContextError, "eligibility metadata changed"):
            service.search("transient capacity")
        (self.workspace / "reviewer-code.py").write_bytes(
            (FIXTURES / "reviewer-code.py").read_bytes())

        service = ContextService.from_config(
            self.config, role="implementer", workspace=self.workspace,
            environment=os.environ,
        )
        self.memory("tombstone", "--operation-id", "snapshot-retire", "--memory-id",
                    candidate["memory"]["memoryId"], "--authority", "independent-reviewer",
                    "--reason", "concurrent retirement")
        with self.assertRaisesRegex(ContextError, "eligibility metadata changed"):
            service.search("transient capacity")

    def test_public_launcher_executes_governed_lifecycle(self) -> None:
        subprocess.run(["git", "init", "-q"], cwd=self.workspace, check=True)
        proposed = self.memory(
            "propose", "--operation-id", "public-propose", "--task", "TASK-A",
            "--actor", "task-a-worker", "--scope", "project", "--policy", "task",
            "--content-file", "candidate.md", "--source", "source-event.json",
            "--code", "reviewer-code.py", public=True,
        )
        approved = self.memory(
            "approve", "--operation-id", "public-approve", "--memory-id",
            proposed["memory"]["memoryId"], "--authority", "independent-reviewer",
            public=True,
        )
        self.assertEqual(approved["memory"]["status"], "approved")
        retired = self.memory(
            "tombstone", "--operation-id", "public-retire", "--memory-id",
            proposed["memory"]["memoryId"], "--authority", "independent-reviewer",
            "--reason", "public lifecycle complete", public=True,
        )
        self.assertEqual(retired["memory"]["status"], "tombstoned")


if __name__ == "__main__":
    unittest.main()
