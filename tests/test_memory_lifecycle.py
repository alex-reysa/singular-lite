from __future__ import annotations

import functools
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
SANDBOX_EXEC = "/usr/bin/sandbox-exec"


def assert_schema_instance(test: unittest.TestCase, value: object,
                           schema: dict, root: dict, path: str = "$") -> None:
    if "$ref" in schema:
        target = root
        for part in schema["$ref"].removeprefix("#/").split("/"):
            target = target[part]
        assert_schema_instance(test, value, target, root, path)
        return
    if "const" in schema:
        test.assertEqual(value, schema["const"], path)
    if "enum" in schema:
        test.assertIn(value, schema["enum"], path)
    kinds = schema.get("type")
    if kinds:
        kinds = [kinds] if isinstance(kinds, str) else kinds
        matches = {
            "object": isinstance(value, dict),
            "array": isinstance(value, list),
            "string": isinstance(value, str),
            "integer": isinstance(value, int) and not isinstance(value, bool),
            "boolean": isinstance(value, bool),
            "null": value is None,
        }
        test.assertTrue(any(matches.get(kind, False) for kind in kinds), (path, kinds, value))
    if isinstance(value, dict):
        required = schema.get("required", [])
        test.assertFalse(set(required) - set(value), (path, set(required) - set(value)))
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            test.assertFalse(set(value) - set(properties), (path, set(value) - set(properties)))
        for key, child in value.items():
            if key in properties:
                assert_schema_instance(test, child, properties[key], root, f"{path}.{key}")
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        for index, child in enumerate(value):
            assert_schema_instance(test, child, schema["items"], root, f"{path}[{index}]")
    if isinstance(value, str) and "pattern" in schema:
        test.assertRegex(value, schema["pattern"], path)


def digest(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


@functools.lru_cache(maxsize=1)
def sandbox_apply_reason() -> str | None:
    """Report why an OS deny-write proof is unavailable, or None when usable.

    Presence of /usr/bin/sandbox-exec does not imply it can apply a profile:
    seatbelt refuses to nest, so an already-contained host returns
    ``sandbox_apply: Operation not permitted``. The behavioural read-only
    proof below therefore never depends on this probe; only the additional
    OS-enforced proof does.
    """
    if sys.platform != "darwin" or not os.access(SANDBOX_EXEC, os.X_OK):
        return f"{SANDBOX_EXEC} is unavailable on this platform"
    probe = subprocess.run([SANDBOX_EXEC, "-p", "(version 1)(allow default)",
                            "/usr/bin/true"], capture_output=True)
    if probe.returncode != 0:
        return "sandbox_apply is not permitted (nested seatbelt)"
    return None


def workspace_state(root: Path) -> dict[str, tuple]:
    """Capture every mutation an honest reader could make under ``root``.

    Content, inode and both timestamps are recorded so an atomic replace, an
    in-place rewrite, a truncation and a pure re-touch are all detected, and
    directory membership is recorded so creations and deletions are too.
    """
    state: dict[str, tuple] = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        info = path.lstat()
        if path.is_dir() and not path.is_symlink():
            state[relative] = ("dir", info.st_ino, info.st_mtime_ns, info.st_ctime_ns,
                               tuple(sorted(item.name for item in path.iterdir())))
        elif path.is_file() and not path.is_symlink():
            state[relative] = ("file", info.st_ino, info.st_mtime_ns, info.st_ctime_ns,
                               digest(path))
        else:
            state[relative] = ("other", info.st_ino, info.st_mtime_ns, info.st_ctime_ns)
    return state


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

    def public_context_search(self, *, ok: bool = True,
                              deny_writes: bool = False,
                              command: str = "search",
                              extra: tuple[str, ...] = ()) -> subprocess.CompletedProcess[str]:
        """Invoke a public read-only retrieval entrypoint.

        ``deny_writes`` additionally contains the reader in an OS policy that
        denies every write to the project and the engine tree. That containment
        is an extra proof, not the definition of the contract: the caller
        asserts the no-write behaviour from observed filesystem state either way.
        """
        prefix: list[str] = []
        if deny_writes:
            profile = (
                '(version 1) (allow default) '
                f'(deny file-write* (subpath "{self.workspace.resolve()}")) '
                f'(deny file-write* (subpath "{ROOT.resolve()}"))'
            )
            prefix = [SANDBOX_EXEC, "-p", profile]
        environment = {
            **os.environ,
            "SINGULAR_ENGINE_HOME": str(ROOT),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        proc = subprocess.run(
            [*prefix, "bash", str(PUBLIC_CLI), "context", command,
             "--config", str(self.config),
             "--workspace", str(self.workspace), "--role", "implementer", *extra],
            text=True, capture_output=True, cwd=self.workspace, env=environment,
        )
        if ok:
            self.assertEqual(proc.returncode, 0, proc.stderr)
        else:
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
        return proc

    def sandbox_context_search(self, *, ok: bool = True,
                               deny_writes: bool = True) -> subprocess.CompletedProcess[str]:
        return self.public_context_search(
            ok=ok, deny_writes=deny_writes,
            extra=("--query", "transient capacity"),
        )

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

    def test_interrupted_approval_replay_cannot_resurrect_tombstone(self) -> None:
        candidate = self.propose("proposal-retirement-race")
        memory_id = candidate["memory"]["memoryId"]
        interrupted = self.memory(
            "approve", "--operation-id", "approval-before-retirement",
            "--memory-id", memory_id, "--authority", "independent-reviewer",
            extra_env={
                "SINGULAR_MEMORY_FAIL_AFTER_STATE": "approval-before-retirement",
            },
            ok=False,
        )
        self.assertIn("injected interruption", interrupted["stderr"])
        self.memory(
            "tombstone", "--operation-id", "retire-after-interruption",
            "--memory-id", memory_id, "--authority", "independent-reviewer",
            "--reason", "durable retirement",
        )
        self.approve(memory_id, "approval-before-retirement")
        shown = self.memory("show", "--memory-id", memory_id)
        self.assertEqual(shown["memory"]["status"], "tombstoned")
        self.assertTrue(self.context_search("transient capacity")["abstained"])

    def test_prepared_intent_recovery_and_descendant_replay_are_revision_safe(self) -> None:
        candidate = self.propose("proposal-prepared-approval")
        memory_id = candidate["memory"]["memoryId"]
        self.memory(
            "approve", "--operation-id", "prepared-approval",
            "--memory-id", memory_id, "--authority", "independent-reviewer",
            extra_env={"SINGULAR_MEMORY_FAIL_AFTER_JOURNAL": "prepared-approval"},
            ok=False,
        )
        rejected = self.memory(
            "reject", "--operation-id", "conflicting-rejection",
            "--memory-id", memory_id, "--authority", "independent-reviewer",
            "--reason", "too late", ok=False,
        )
        self.assertIn("requires proposed memory", rejected["stderr"])
        self.memory(
            "tombstone", "--operation-id", "retire-prepared-approval",
            "--memory-id", memory_id, "--authority", "independent-reviewer",
            "--reason", "retired after recovered approval",
        )
        self.approve(memory_id, "prepared-approval")
        self.assertEqual(
            self.memory("show", "--memory-id", memory_id)["memory"]["status"],
            "tombstoned",
        )

        proposal = self.memory(
            "propose", "--operation-id", "interrupted-proposal", "--task", "TASK-A",
            "--actor", "task-a-worker", "--scope", "project", "--policy", "task",
            "--content-file", "candidate.md", "--source", "source-event.json",
            "--code", "reviewer-code.py",
            extra_env={"SINGULAR_MEMORY_FAIL_AFTER_STATE": "interrupted-proposal"},
            ok=False,
        )
        self.assertIn("injected interruption", proposal["stderr"])
        recovered = self.propose("interrupted-proposal")
        second_id = recovered["memory"]["memoryId"]
        self.approve(second_id, "approve-after-proposal-recovery")
        self.propose("interrupted-proposal")
        self.assertEqual(
            self.memory("show", "--memory-id", second_id)["memory"]["status"],
            "approved",
        )

    def test_derived_index_failure_does_not_undo_authoritative_commit(self) -> None:
        candidate = self.propose("proposal-index-failure")
        memory_id = candidate["memory"]["memoryId"]
        approved = self.memory(
            "approve", "--operation-id", "approval-index-failure",
            "--memory-id", memory_id, "--authority", "independent-reviewer",
            extra_env={"SINGULAR_MEMORY_FAIL_INDEX_REFRESH": "1"},
        )
        self.assertEqual(approved["memory"]["status"], "approved")
        (self.workspace / ".memory" / "index.json").unlink(missing_ok=True)
        rebuilt = self.memory("rebuild")
        self.assertIn(memory_id, rebuilt["trusted"])

    def test_memory_delta_revokes_retired_body_and_both_bundle_schemas_accept_it(self) -> None:
        candidate = self.propose("proposal-delta")
        memory_id = candidate["memory"]["memoryId"]
        self.approve(memory_id, "approval-delta")
        task = self.workspace / "task.md"
        base = self.workspace / "base.md"
        task.write_text("Use transient capacity safely.\n", encoding="utf-8")
        base.write_text("BASE DRIVER\n", encoding="utf-8")
        first = ContextService.from_config(
            self.config, role="implementer", workspace=self.workspace,
        ).build(
            task=task, phase="implement", budget_bytes=16000, base_prompt=base,
            delivery="initial", invocation_id="memory-initial",
        )
        body = (self.workspace / "candidate.md").read_text(encoding="utf-8")
        self.assertIn(body.strip(), first["prompt"])
        self.assertTrue(any(item.get("kind") == "memory" for item in first["provenance"]))
        for relative in (
            "schemas/context-bundle.v1.schema.json",
            "schemas/orchestration/context-bundle.v1.schema.json",
        ):
            schema = json.loads((ROOT / relative).read_text(encoding="utf-8"))
            assert_schema_instance(self, first, schema, schema)

        self.memory(
            "tombstone", "--operation-id", "retire-before-delta",
            "--memory-id", memory_id, "--authority", "independent-reviewer",
            "--reason", "withdraw before retry",
        )
        delta = ContextService.from_config(
            self.config, role="implementer", workspace=self.workspace,
        ).build(
            task=task, phase="implement", budget_bytes=16000, base_prompt=base,
            delivery="delta", prior_bundle=first, invocation_id="memory-retry",
        )
        ref = "memory:" + memory_id
        self.assertIn(f"Revoked since the prior bundle: {ref}", delta["prompt"])
        self.assertNotIn(body.strip(), delta["prompt"])
        self.assertIn({"ref": ref, "reason": "revoked_since_prior_bundle"},
                      delta["omissions"])

    def _assert_os_write_policy_denies(self) -> None:
        """Prove the deny-write profile this fixture uses is actually enforced."""
        victim = self.workspace / "write-policy-victim"
        rename_target = self.workspace / "write-policy-renamed"
        victim.write_text("retain", encoding="utf-8")
        profile = (
            '(version 1) (allow default) '
            f'(deny file-write* (subpath "{self.workspace.resolve()}"))'
        )
        control = subprocess.run(
            [SANDBOX_EXEC, "-p", profile, sys.executable, "-c",
             "import os,pathlib,sys; p=pathlib.Path(sys.argv[1]); q=pathlib.Path(sys.argv[2]); "
             "actions=[lambda:(p.parent/'denied-create').write_text('x'), "
             "lambda:open(p,'r+').close(), lambda:os.rename(p,q), lambda:os.unlink(p)]; "
             "denied=0\nfor action in actions:\n try: action()\n except PermissionError: denied += 1\n"
             "raise SystemExit(0 if denied == 4 else 9)",
             str(victim), str(rename_target)],
            text=True, capture_output=True,
        )
        self.assertEqual(control.returncode, 0, control.stderr)
        victim.unlink()

    def _assert_public_readers_never_write(self, *, deny_writes: bool) -> None:
        """Absent, populated and pending-journal stores must all stay untouched."""
        subprocess.run(["git", "init", "-q"], cwd=self.workspace, check=True)
        self.assertFalse((self.workspace / ".memory").exists())
        before_absent = workspace_state(self.workspace)
        absent = self.sandbox_context_search(deny_writes=deny_writes)
        self.assertTrue(json.loads(absent.stdout)["abstained"])
        self.assertFalse((self.workspace / ".memory").exists())
        self.assertEqual(before_absent, workspace_state(self.workspace))

        candidate = self.propose("readonly-populated")
        self.approve(candidate["memory"]["memoryId"], "readonly-approved")
        lock = self.workspace / ".memory" / ".lock"
        self.assertTrue(lock.is_file())
        before = workspace_state(self.workspace)
        populated = self.sandbox_context_search(deny_writes=deny_writes)
        self.assertFalse(json.loads(populated.stdout)["abstained"])
        self.assertEqual(before, workspace_state(self.workspace))

        # `get` and `build` are read-only publications too, not just `search`.
        body_ref = "memory:" + candidate["memory"]["memoryId"]
        fetched = self.public_context_search(
            deny_writes=deny_writes, command="get",
            extra=("--ref", body_ref, "--version",
                   candidate["memory"]["content"]["sha256"]),
        )
        self.assertEqual(json.loads(fetched.stdout)["ref"], body_ref)
        self.assertEqual(before, workspace_state(self.workspace))

        # A pending journal must fail closed for readers and still not repair,
        # recover, lock or otherwise write anything on the reader's behalf.
        self.memory(
            "propose", "--operation-id", "readonly-pending", "--task", "TASK-A",
            "--actor", "task-a-worker", "--scope", "project", "--policy", "task",
            "--content-file", "candidate.md", "--source", "source-event.json",
            "--code", "reviewer-code.py",
            extra_env={"SINGULAR_MEMORY_FAIL_AFTER_JOURNAL": "readonly-pending"},
            ok=False,
        )
        before_pending = workspace_state(self.workspace)
        pending = self.sandbox_context_search(ok=False, deny_writes=deny_writes)
        self.assertIn("recovery required", pending.stderr)
        self.assertEqual(before_pending, workspace_state(self.workspace))

    def test_public_memory_readers_are_read_only_for_absent_populated_and_pending_store(self) -> None:
        self._assert_public_readers_never_write(deny_writes=False)

    def test_public_memory_readers_are_os_enforced_read_only_for_absent_populated_and_pending_store(self) -> None:
        reason = sandbox_apply_reason()
        if reason is not None:
            # The behavioural contract is proven unconditionally by the sibling
            # test above; only the OS enforcement layer is host-dependent.
            raise unittest.SkipTest(f"OS deny-write proof unavailable: {reason}")
        self._assert_os_write_policy_denies()
        self._assert_public_readers_never_write(deny_writes=True)

    def test_ambiguous_legacy_and_malformed_journals_fail_closed(self) -> None:
        candidate = self.propose("legacy-journal-candidate")
        memory_id = candidate["memory"]["memoryId"]
        record = json.loads(
            (self.workspace / ".memory" / "records" / f"{memory_id}.json").read_text()
        )
        obsolete = json.loads(json.dumps(record))
        obsolete["status"] = "approved"
        obsolete["trust"] = "trusted"
        legacy_id = "candidate-era-unapplied-approval"
        legacy = {
            "operationId": legacy_id,
            "fingerprint": "sha256:" + "0" * 64,
            "response": {"schema": "singular.memory.operation.v1", "memory": obsolete},
            "state": "prepared", "recordWrites": [obsolete],
            "checkpointWrites": [], "refreshIndex": True,
        }
        operation_path = self.workspace / ".memory" / "operations" / (
            hashlib.sha256(legacy_id.encode()).hexdigest() + ".json"
        )
        operation_path.write_text(json.dumps(legacy, sort_keys=True), encoding="utf-8")
        blocked = self.memory("rebuild", ok=False)
        self.assertIn("ambiguous unapplied record intent", blocked["stderr"])
        operation_path.unlink()

        malformed = self.workspace / ".memory" / "operations" / "malformed.json"
        malformed.write_text("{", encoding="utf-8")
        blocked = self.memory("rebuild", ok=False)
        self.assertIn("operation journal is invalid", blocked["stderr"])
        malformed.unlink()
        self.assertEqual(
            self.memory("show", "--memory-id", memory_id)["memory"]["status"],
            "proposed",
        )


if __name__ == "__main__":
    unittest.main()
