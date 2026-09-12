#!/usr/bin/env python3
"""Real invocation coverage for the opt-in shared context service."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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


class ContextInvocationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="singular-context-invoke.", dir="/tmp")
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

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
            doctor.effective_config_projection = {
                "schema": "singular.effective-configuration.v1",
                "paths": {"state": str(self.repo / ".singular-state")},
            }
            doctor.context_service_check()
        finally:
            sys.path.pop(0)
        check = next(item for item in doctor.checks if item["id"] == "runtime.context-service")
        self.assertEqual(check["status"], "pass")
        self.assertTrue(check["details"]["enabled"])
        self.assertEqual(check["details"]["roles"]["implementer"]["budgetBytes"], 16384)
        review = check["details"]["roles"]["review-target"]
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
prompt=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) prompt="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$prompt" "{self.temp.name}/planner-captured.md"
python3 - "$out" <<'PY'
import json,sys
md = '''# TASK-0001: context widget\n\nStatus: ready\nArea: widget\nTarget branch: `target`\nWorker branch: `agent/widget/TASK-0001-context`\nTest policy: `strict_test_first`\nGate command: `true`\nDispatch mode: canonical\nDepends on: []\n\n## Objective\n\nImplement ORBIT-CONTEXT.\n\n## Scope\n\nOwned files:\n\n- `widget.txt`\n\nForbidden files:\n\n- `outside.txt`\n\n## Acceptance Criteria\n\n- Context is present.\n'''
json.dump({{"schema":"singular.orchestration.task-batch.v0","tasks":[{{"taskId":"TASK-0001","markdown":md}}]}}, open(sys.argv[1],"w"))
PY
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
        events = (self.repo / ".singular-state/events.ndjson").read_text(encoding="utf-8")
        self.assertIn(bundle["bundleId"], events)
        self.assertIn(bundle["promptSha256"], events)

        off_temp = tempfile.TemporaryDirectory(prefix="singular-context-off.", dir="/tmp")
        self.addCleanup(off_temp.cleanup)
        prior_temp, prior_repo = self.temp, self.repo
        self.temp = off_temp
        self.repo = Path(off_temp.name) / "repo"; self.repo.mkdir()
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
args=("$@")
i=0
while [[ $i -lt ${{#args[@]}} ]]; do
  case "${{args[$i]}}" in
    --prompt-file) prompt="${{args[$((i+1))]}}"; i=$((i+2)) ;;
    --output-last-message) out="${{args[$((i+1))]}}"; i=$((i+2)) ;;
    -C|--worktree) worktree="${{args[$((i+1))]}}"; i=$((i+2)) ;;
    --run-id) run_id="${{args[$((i+1))]}}"; i=$((i+2)) ;;
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
printf '%s\n' "$@" >"{capture}/$kind.args"
if [[ "$role" == implementer ]]; then
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
elif [[ "$kind" == paired ]]; then
  printf '%s\n' '{{"verdict":"accepted","findings":[]}}' >"$out"
elif [[ "$role" == auditor ]]; then
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

    def test_real_worker_final_and_paired_audits_use_isolated_atomic_bundles(self) -> None:
        config, stub, capture = self.worker_fixture()
        env = {
            "SINGULAR_ROOT": str(self.repo), "SINGULAR_ENGINE_HOME": str(ROOT),
            "SINGULAR_ORCH_DIR": str(self.repo / "docs/orchestration"),
            "SINGULAR_TASKS_DIR": str(self.repo / "docs/orchestration/tasks"),
            "SINGULAR_STATE_DIR": str(self.repo / ".singular-state"),
            "SINGULAR_TARGET_BRANCH": "target", "SINGULAR_RUNNER": str(stub),
            "SINGULAR_JSON_CONFIG_FILE": str(config), "SINGULAR_MAX_RETRIES": "0",
            "SINGULAR_WORKER_INFRA_MAX": "0", "SINGULAR_AUDIT_INFRA_MAX": "0",
            "SINGULAR_AUDIT_VERIFY": "0", "SINGULAR_PAIRED_AUDIT_PCT": "100",
            "SINGULAR_CTX_ROUTING": "0", "SINGULAR_DISK_RESERVE_BYTES": "0",
            "SINGULAR_MIN_DISK_GB": "0", "TMPDIR": "/tmp",
            "SINGULAR_TEST_CONTEXT_INVOCATION_DIRECT_AUDIT": "1",
        }
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
        self.assertNotIn("--resume-session", (capture / "auditor.args").read_text())
        self.assertNotIn("--resume-session", (capture / "paired.args").read_text())

        run_dirs = list((self.repo / ".singular-state/runs").glob("RUN-*"))
        self.assertEqual(len(run_dirs), 1)
        run_dir = run_dirs[0]
        expected = {
            "context-implementer-attempt-1.bundle.json": worker,
            "context-review-target-attempt-1.bundle.json": final,
            "context-review-target-paired.bundle.json": paired,
        }
        events = (self.repo / ".singular-state/events.ndjson").read_text(encoding="utf-8")
        for name, delivered in expected.items():
            bundle = json.loads((run_dir / name).read_text(encoding="utf-8"))
            self.assertEqual(bundle["prompt"], delivered, name)
            self.assertEqual(bundle["promptSha256"], "sha256:" + hashlib.sha256(delivered.encode()).hexdigest())
            self.assertIn(bundle["bundleId"], events)
        audit_bundle = json.loads((run_dir / "context-review-target-attempt-1.bundle.json").read_text())
        self.assertEqual(audit_bundle["identity"]["role"], "review-target")
        self.assertNotIn("run", {item["kind"] for item in audit_bundle["provenance"]})

    def test_real_worker_product_retry_receives_context_delta_references(self) -> None:
        config, stub, capture = self.worker_fixture()
        env = {
            "SINGULAR_ROOT": str(self.repo), "SINGULAR_ENGINE_HOME": str(ROOT),
            "SINGULAR_ORCH_DIR": str(self.repo / "docs/orchestration"),
            "SINGULAR_TASKS_DIR": str(self.repo / "docs/orchestration/tasks"),
            "SINGULAR_STATE_DIR": str(self.repo / ".singular-state"),
            "SINGULAR_TARGET_BRANCH": "target", "SINGULAR_RUNNER": str(stub),
            "SINGULAR_JSON_CONFIG_FILE": str(config), "SINGULAR_MAX_RETRIES": "1",
            "SINGULAR_WORKER_INFRA_MAX": "0", "SINGULAR_AUDIT_INFRA_MAX": "0",
            "SINGULAR_AUDIT_VERIFY": "0", "SINGULAR_PAIRED_AUDIT_PCT": "0",
            "SINGULAR_CTX_ROUTING": "0", "SINGULAR_DISK_RESERVE_BYTES": "0",
            "SINGULAR_MIN_DISK_GB": "0", "TMPDIR": "/tmp",
            "SINGULAR_TEST_CONTEXT_INVOCATION_DIRECT_AUDIT": "1",
            "DRIVER_STUB_RETRY": "1",
        }
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


if __name__ == "__main__":
    unittest.main()
