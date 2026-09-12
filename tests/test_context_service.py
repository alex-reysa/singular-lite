#!/usr/bin/env python3
"""Direct contract tests for the dependency-free B2 context service."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from engine.context_service import (
    ContextError,
    ContextOverflow,
    ContextService,
    publish_bundle,
)


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "context-service"


class ContextServiceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="singular-context-unit.")
        self.repo = Path(self.temp.name) / "repo"
        shutil.copytree(FIXTURE, self.repo)
        late = self.repo / "brain" / "notes" / "late-fact.md"
        original = late.read_text(encoding="utf-8")
        late.write_text(original.replace(
            "## Late Operations", "padding " * 800 + "\n\n## Late Operations"
        ), encoding="utf-8")
        producer = ROOT / "vendor" / "singular-brain" / "engine" / "cli.mjs"
        subprocess.run(
            ["node", str(producer), "--config", str(self.repo / "brain" / "singular-brain.config.json"), "gen"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.config = self.repo / "singular.config.json"
        self._write_config(self.repo, "fixture-project")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _write_config(self, root: Path, project: str, *, enabled: bool = True) -> Path:
        config = root / "singular.config.json"
        config.write_text(json.dumps({
            "contextManifest": {
                "format": "singular-brain.manifest.v1",
                "manifest": "brain/generated/KNOWLEDGE.json",
                "sourceId": "fixture-brain",
                "expectedScope": "knowledge",
                "sourceRoot": "brain",
                "select": ["notes/late-fact.md"],
            },
            "contextService": {
                "enabled": enabled,
                "projectId": project,
                "codePaths": ["src/selected.py"],
                "runRecordPaths": ["runs/RUN-fixture/runner-result.json"],
                "rolePolicy": {
                    "implementer": ["brain", "code", "run"],
                    "auditor": ["brain", "code"],
                },
            },
        }, sort_keys=True), encoding="utf-8")
        return config

    def service(self, role: str = "implementer") -> ContextService:
        return ContextService.from_config(self.config, role=role)

    def test_search_is_deterministic_exact_lexical_and_abstains(self) -> None:
        service = self.service()
        first = service.search("cobalt migration", limit=3, max_bytes=1000)
        second = self.service().search("cobalt migration", limit=3, max_bytes=1000)
        self.assertEqual(first, second)
        self.assertFalse(first["abstained"])
        self.assertEqual(first["results"][0]["ref"], "brain:fixture-brain:knowledge:notes/late-fact.md")
        self.assertIn("exact_phrase", first["results"][0]["reasons"])
        self.assertRegex(first["results"][0]["sourceSha256"], r"^sha256:[0-9a-f]{64}$")
        miss = service.search("azure schema transformation", limit=3, max_bytes=1000)
        self.assertTrue(miss["abstained"])
        self.assertEqual(miss["results"], [])
        self.assertIn("lexical", miss["limitations"])

    def test_get_checks_version_and_reaches_late_lines(self) -> None:
        service = self.service()
        result = service.search("AURORA-TAIL-731", limit=1, max_bytes=500)
        hit = result["results"][0]
        page = service.get(hit["ref"], version=hit["sourceSha256"], section="Late Operations", max_bytes=500)
        self.assertIn("AURORA-TAIL-731", page["text"])
        self.assertGreater(page["range"]["startByte"], 4000)
        self.assertRegex(page["excerptSha256"], r"^sha256:[0-9a-f]{64}$")
        with self.assertRaisesRegex(ContextError, "wrong-version"):
            service.get(hit["ref"], version="sha256:" + "0" * 64, max_bytes=200)
        source = self.repo / "brain" / "notes" / "late-fact.md"
        source.write_text(source.read_text(encoding="utf-8") + "\ntamper\n", encoding="utf-8")
        with self.assertRaisesRegex(ContextError, "modified"):
            service.get(hit["ref"], version=hit["sourceSha256"], max_bytes=200)
        source.unlink()
        with self.assertRaisesRegex(ContextError, "missing"):
            service.get(hit["ref"], version=hit["sourceSha256"], max_bytes=200)

    def test_get_rejects_b1_ineligible_review_and_lifecycle_states(self) -> None:
        manifest_path = self.repo / "brain" / "generated" / "KNOWLEDGE.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["entries"][0]["status"] = "superseded"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        lifecycle_service = self.service()
        lifecycle_source = next(source for source in lifecycle_service.sources if source.kind == "brain")
        self.assertIn("lifecycle_superseded", lifecycle_source.validity)
        with self.assertRaisesRegex(ContextError, "ineligible"):
            lifecycle_service.get(
                lifecycle_source.ref,
                version=lifecycle_source.source_hash,
                max_bytes=200,
            )

        producer = ROOT / "vendor" / "singular-brain" / "engine" / "cli.mjs"
        subprocess.run(
            ["node", str(producer), "--config", str(self.repo / "brain" / "singular-brain.config.json"), "gen"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        document = self.repo / "brain" / "notes" / "late-fact.md"
        document.write_text(document.read_text(encoding="utf-8") + "\nunreviewed change\n", encoding="utf-8")
        review_service = self.service()
        review_source = next(source for source in review_service.sources if source.kind == "brain")
        self.assertIn("review_body_mismatch", review_source.validity)
        with self.assertRaisesRegex(ContextError, "ineligible"):
            review_service.get(
                review_source.ref,
                version=review_source.source_hash,
                max_bytes=200,
            )

    def test_get_cursor_is_lossless_inside_long_multibyte_line(self) -> None:
        code = self.repo / "src" / "selected.py"
        prefix = code.read_bytes()
        long_line = ('LONG_VALUE = "' + ("é" * 3000) + " UTF8-TAIL-991" + '"\n').encode("utf-8")
        code.write_bytes(prefix + long_line)
        start_line = prefix.count(b"\n") + 1
        service = self.service()
        source = next(source for source in service.sources if source.kind == "code")
        pages: list[bytes] = []
        cursor = None
        for _ in range(40):
            page = service.get(
                source.ref,
                version=source.source_hash,
                start_line=start_line,
                line_count=1,
                max_bytes=257,
                cursor=cursor,
            )
            pages.append(page["text"].encode("utf-8"))
            cursor = page["continuationCursor"]
            if cursor is None:
                break
            self.assertRegex(cursor, r"^byte:[0-9]+$")
        else:
            self.fail("lossless continuation did not terminate")
        self.assertEqual(b"".join(pages), long_line)
        self.assertIn("UTF8-TAIL-991", b"".join(pages).decode("utf-8"))

    def test_bundle_is_immutable_deterministic_and_budgeted(self) -> None:
        service = self.service()
        task = self.repo / "task.md"
        first = service.build(task=task, phase="implement", budget_bytes=10000, query="cobalt rollback")
        second = self.service().build(task=task, phase="implement", budget_bytes=10000, query="cobalt rollback")
        self.assertEqual(first, second)
        self.assertEqual(first["schema"], "singular.context.bundle.v1")
        self.assertEqual(first["identity"]["projectId"], "fixture-project")
        self.assertEqual(first["identity"]["worktree"], str(self.repo.resolve()))
        self.assertEqual(first["budget"]["usedBytes"], len(first["prompt"].encode()))
        self.assertLessEqual(first["budget"]["usedBytes"], first["budget"]["limitBytes"])
        self.assertIn("[violated] Never publish a partial prompt", first["prompt"])
        self.assertIn("[open] Verify the rollback latch", first["prompt"])
        self.assertEqual(
            first["promptSha256"], "sha256:" + hashlib.sha256(first["prompt"].encode()).hexdigest()
        )
        self.assertRegex(first["bundleId"], r"^sha256:[0-9a-f]{64}$")
        self.assertTrue(all("sourceSha256" in item and "excerptSha256" in item and "reasons" in item
                            for item in first["provenance"]))
        for item in first["provenance"]:
            source = Path(item["sourceLocation"]).read_bytes()
            excerpt = source[item["range"]["startByte"]:item["range"]["endByte"]]
            self.assertEqual(
                item["excerptSha256"],
                "sha256:" + hashlib.sha256(excerpt).hexdigest(),
                item["ref"],
            )
        explanation = service.explain(first)
        self.assertEqual(explanation["bundleId"], first["bundleId"])
        self.assertEqual(explanation["identity"], first["identity"])
        self.assertEqual(explanation["omissions"], first["omissions"])
        with self.assertRaises(ContextOverflow):
            service.build(task=task, phase="implement", budget_bytes=32)

    def test_atomic_publication_and_read_only_operations(self) -> None:
        service = self.service()
        before = {p.relative_to(self.repo): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in self.repo.rglob("*") if p.is_file()}
        search = service.search("cobalt", limit=1, max_bytes=500)
        service.get(search["results"][0]["ref"], version=search["results"][0]["sourceSha256"], max_bytes=200)
        bundle = service.build(task=self.repo / "task.md", phase="implement", budget_bytes=9000)
        service.explain(bundle)
        after = {p.relative_to(self.repo): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in self.repo.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        destination = Path(self.temp.name) / "published" / "bundle.json"
        publish_bundle(bundle, destination)
        published = json.loads(destination.read_text(encoding="utf-8"))
        self.assertEqual(published["bundleId"], bundle["bundleId"])
        self.assertIn("prompt", published)
        self.assertIn("provenance", published)
        self.assertFalse(any(p.name.endswith(".tmp") for p in destination.parent.iterdir()))

    def test_role_policy_containment_feature_off_and_worktree_identity(self) -> None:
        auditor = self.service("auditor")
        self.assertTrue(auditor.search("provider-exit", limit=3, max_bytes=500)["abstained"])
        bad = json.loads(self.config.read_text(encoding="utf-8"))
        bad["contextService"]["codePaths"] = ["../outside.py"]
        self.config.write_text(json.dumps(bad), encoding="utf-8")
        with self.assertRaisesRegex(ContextError, "containment"):
            ContextService.from_config(self.config, role="implementer")

        self._write_config(self.repo, "fixture-project", enabled=False)
        disabled = ContextService.from_config(self.config, role="implementer")
        self.assertFalse(disabled.enabled)
        self.assertEqual(disabled.search("anything")["status"], "disabled")

        other = Path(self.temp.name) / "other"
        shutil.copytree(self.repo, other)
        a_config = self._write_config(self.repo, "fixture-project", enabled=True)
        b_config = self._write_config(other, "fixture-project", enabled=True)
        with ThreadPoolExecutor(max_workers=2) as pool:
            bundles = list(pool.map(
                lambda pair: ContextService.from_config(pair[0], role="implementer").build(
                    task=pair[1] / "task.md", phase="implement", budget_bytes=9000
                ),
                [(a_config, self.repo), (b_config, other)],
            ))
        self.assertNotEqual(bundles[0]["identity"]["snapshotId"], bundles[1]["identity"]["snapshotId"])
        self.assertNotEqual(bundles[0]["identity"]["worktree"], bundles[1]["identity"]["worktree"])


if __name__ == "__main__":
    unittest.main()
