#!/usr/bin/env python3
"""Structured, read-only operator preflight for singular.

Write-like probes are exactly two, both engine-owned: a disposable detached Git
worktree that is removed before the check returns, and the model-listing cache
under ``.singular-state/doctor-cache/`` that keeps the provider model probe to
one bounded CLI call per executable per day. Neither touches repository or
provider state. Model-cache mutation is available only through the explicit
``--repair-model-cache`` option and always preserves the original as a
timestamped backup.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterable

import provider_spec
import brain_manifest
from capability_policy import strict_provider_arg_violation
from provider_resolver import (
    ConfigResolutionError,
    JsonConfigResolution,
    codex_role_settings,
    load_json_config,
    resolve_json_config,
    resolve_provider_bin,
    unavailable_effective_configuration,
)
from health_details import collect_lifecycle, unavailable_lifecycle


CHECK_SCHEMA = "singular.doctor-report.v1"
REQUIRED_RUNNER_ARGUMENTS = {
    "--worktree",
    "--prompt-file",
    "--level",
    "--run-id",
    "--output-schema",
    "--output-last-message",
    "--no-output-capture",
    "--allow-prefix",
    "--session-meta",
    "--resume-session",
    "--role",
    "--capability-profile",
    "--result-file",
    "--describe-contract",
}
# Provider facts come from engine/providers.json, never from a table kept here:
# doctor's private copy of the default model is half of how `grok-build` shipped
# (the adapter held the other half, and the two were edited apart). A spec that
# will not load is a loud failure below, not a silent empty provider list.
try:
    PROVIDER_SPEC_ERROR = ""
    PROVIDERS = {
        name: (entry["adapter"], entry["binary"])
        for name, entry in provider_spec.providers().items()
    }
    MODEL_ENV = provider_spec.model_env()
    MODEL_PATTERNS = provider_spec.model_patterns()
    # What each CLI must be asked to enumerate the models it actually serves,
    # appended to the resolved provider executable. Two hard requirements the
    # spec enforces on every entry: the argv is non-mutating, and it begins with
    # that CLI's update pin -- doctor runs a provider binary here, and a CLI that
    # can replace its own executable during preflight would swap the binary the
    # run is about to use. A provider whose installed CLI exposes no proven
    # listing declares none: absence yields "unverified", which is the honest
    # verdict, while a guess would be the grok-build failure with a different id.
    MODEL_LISTINGS = {
        name: listing
        for name in provider_spec.names()
        if (listing := provider_spec.model_listing(name))
    }
    STRICT_ISOLATION_PROVIDERS = provider_spec.strict_isolation_providers()
except provider_spec.SpecError as exc:  # pragma: no cover - reported by run()
    PROVIDER_SPEC_ERROR = str(exc)
    PROVIDERS = {}
    MODEL_ENV = {}
    MODEL_PATTERNS = {}
    MODEL_LISTINGS = {}
    STRICT_ISOLATION_PROVIDERS = set()
MODEL_LISTING_TIMEOUT_SEC = 10
MODEL_LISTING_TTL_SEC = 24 * 60 * 60
MODEL_LISTING_CACHE_SCHEMA = "singular.doctor.model-listing.v0"
# Selector aliases resolved by the provider, not model ids: they cannot be
# looked up in an inventory, so they are reported as unverifiable rather than
# absent.
MODEL_ALIASES = {"auto", "default"}
# Verdict a validated SINGULAR_TEST_PID_PROBE_STATE stands in for. The state
# names match engine/ops.sh's ops_pid_probe_state so one seam vocabulary covers
# both PID-probe surfaces; the verdicts are doctor's own.
PID_PROBE_SEAM_VERDICTS = {
    "alive": "alive",
    "dead": "stale",
    "unknown": "unknown-permission",
}
PROCESS_CONTROL_SEAM_STATES = {"ok", "no-group-kill", "no-ps"}
BUILTIN_CAPABILITIES = {
    "filesystem",
    "git",
    "schemas",
    "skills",
    "runner-contract",
    "provider-executable",
}
DEPLOY_KINDS = {"deploy", "deployment", "release", "publish"}


def utc_now() -> str:
    return (
        dt.datetime.now(dt.UTC)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def compact(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def first_line(value: str, limit: int = 512) -> str:
    for line in value.splitlines():
        if line.strip():
            return line.strip()[:limit]
    return ""


def command(
    argv: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 10,
) -> subprocess.CompletedProcess[str]:
    try:
        process = subprocess.Popen(
            argv,
            cwd=str(cwd) if cwd else None,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        return subprocess.CompletedProcess(argv, 127, "", str(exc))
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            process.kill()
        stdout, stderr = process.communicate()
        return subprocess.CompletedProcess(
            argv,
            124,
            stdout or "",
            ((stderr or "") + f"\nprobe timed out after {timeout}s").strip(),
        )


def parse_version(text: str) -> tuple[int, ...] | None:
    match = re.search(r"(?<![0-9])([0-9]+)\.([0-9]+)(?:\.([0-9]+))?", text)
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def parse_model_listing(text: str, pattern: re.Pattern[str] | None = None) -> list[str]:
    """Model ids out of a CLI's own listing output.

    JSON first (a bare array, or an object carrying one), then the plain-text
    shape every CLI listing shares: one id per line, bulleted or not, with an
    optional trailing annotation like `(default)`. Prose is rejected by that
    line shape, and what survives must still look like a model id -- the
    provider's own id pattern, or a digit or slash in the token -- because a
    prose word wrongly kept is a model wrongly believed to exist.
    """
    seen: dict[str, None] = {}
    stripped = text.strip()
    if stripped.startswith(("{", "[")):
        try:
            data = json.loads(stripped)
        except json.JSONDecodeError:
            data = None
        items: Any = None
        if isinstance(data, list):
            items = data
        elif isinstance(data, dict):
            for key in ("models", "data", "items"):
                if isinstance(data.get(key), list):
                    items = data[key]
                    break
        if isinstance(items, list):
            for item in items:
                if isinstance(item, str) and item.strip():
                    seen.setdefault(item.strip(), None)
                elif isinstance(item, dict):
                    for key in ("id", "slug", "model", "name"):
                        value = item.get(key)
                        if isinstance(value, str) and value.strip():
                            seen.setdefault(value.strip(), None)
                            break
            return list(seen)
    for line in text.splitlines():
        match = re.match(
            r"^\s*(?:[-*•>]\s+)?([A-Za-z0-9][A-Za-z0-9._:/@+-]*)\s*(?:\([^()]*\))?\s*$",
            line,
        )
        if not match:
            continue
        token = match.group(1)
        looks_like_id = any(char.isdigit() or char == "/" for char in token)
        if looks_like_id or (pattern is not None and pattern.search(token)):
            seen.setdefault(token, None)
    return list(seen)


def model_is_alias(value: str) -> bool:
    """Is this a selector the provider resolves, rather than a model id?

    `auto` cannot be looked up in a catalog, and neither can `openrouter/auto`:
    the namespace says which router will resolve it, the last segment says it is
    a selector. Reported as unverifiable rather than absent.
    """
    return value.rsplit("/", 1)[-1].strip().lower() in MODEL_ALIASES


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^a-z0-9._-]+", "-", value.lower()).strip("-")
    return slug[:80] or hashlib.sha256(value.encode()).hexdigest()[:12]


class Doctor:
    def __init__(
        self,
        *,
        engine: Path,
        repo: Path | None,
        bash: Path,
        bash_version: str,
        output_json: bool,
        repair_model_cache: bool,
    ) -> None:
        self.engine = engine.resolve()
        self.repo = repo.resolve() if repo else None
        self.bash = bash.resolve()
        self.bash_version = bash_version
        self.output_json = output_json
        self.repair_model_cache = repair_model_cache
        self.checks: list[dict[str, Any]] = []
        self.config: dict[str, Any] = {}
        self.config_resolution: JsonConfigResolution | None = (
            resolve_json_config(self.repo, os.environ) if self.repo else None
        )
        # Primary diagnosis, once one is reached. A repo whose schema does not
        # match the engine cannot have its artifacts interpreted by this engine,
        # so every check that reads one afterwards would report a derivative
        # error about a file the operator was never asked to fix (PMGO-008).
        self.blocking: dict[str, str] | None = None
        self.repo_pin = ""
        self.repo_pin_source = ""
        try:
            self.engine_version = (
                (self.engine / "VERSION").read_text(encoding="utf-8").strip()
            )
        except OSError:
            self.engine_version = ""
        # Populated only after lib.sh completes its full precedence chain.  The
        # inherited process environment is input, not evidence of an effective
        # runtime when configuration initialization fails.
        self.runtime_env: dict[str, str] = {}
        self.effective_config_projection: dict[str, Any] | None = None
        self.config_exports: str | None = None
        self.runner: Path | None = None
        self.provider: str | None = None
        self.provider_bin: Path | None = None
        self.provider_version_output = ""
        self.runner_contract_ok = False

    def add(
        self,
        check_id: str,
        status: str,
        message: str,
        *,
        required_for: Iterable[str] = (),
        remediation: str = "",
        dedupe_key: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        severity = {
            "pass": "info",
            "skip": "info",
            "warn": "warning",
            "fail": "error",
        }[status]
        self.checks.append(
            {
                "id": check_id,
                "status": status,
                "severity": severity,
                "requiredFor": sorted(set(required_for)),
                "message": message,
                "remediation": remediation,
                "dedupeKey": dedupe_key or check_id,
                **({"details": details} if details else {}),
            }
        )

    def load_config(self) -> None:
        if not self.repo:
            self.add(
                "repo.present",
                "warn",
                "not in a git repo",
                remediation="Run doctor from the repository singular will operate.",
            )
            return
        resolution = self.config_resolution or resolve_json_config(self.repo, os.environ)
        config_path = resolution.path
        if not config_path.is_file():
            if resolution.source == "selector":
                self.add(
                    "repo.config",
                    "fail",
                    f"selected JSON configuration is missing: {config_path}",
                    required_for=("all-runs",),
                    remediation=(
                        "Fix SINGULAR_JSON_CONFIG_FILE or create the selected file."
                    ),
                    details={"path": str(config_path), "source": resolution.source},
                )
                return
            self.add(
                "repo.config",
                "warn",
                "no singular.config.json (run: singular init)",
                required_for=("configured-runs",),
                remediation="Run singular init, then review the generated configuration.",
            )
            return
        try:
            loaded, resolution = load_json_config(self.repo, os.environ)
            self.config_resolution = resolution
            self.config = loaded
            self.add(
                "repo.config",
                "pass",
                f"selected repo config: {config_path}",
                required_for=("configured-runs",),
                details={"path": str(config_path), "source": resolution.source},
            )
        except ConfigResolutionError as exc:
            self.add(
                "repo.config",
                "fail",
                str(exc),
                required_for=("all-runs",),
                remediation=(
                    "Repair the selected JSON configuration before starting the engine."
                ),
                details={"path": str(config_path), "source": resolution.source},
            )

    def brain_checks(self) -> None:
        """Validate the opt-in producer without generating or blessing outputs."""
        if not self.repo or not self.config_resolution or not self.config:
            return
        selected = self.config_resolution.path
        try:
            brain_env = dict(self.runtime_env)
            brain_env["SINGULAR_JSON_CONFIG_FILE"] = str(selected)
            config_path, _ = brain_manifest.resolve_brain_config(
                explicit=None,
                repo_root=self.repo,
                cwd=Path.cwd(),
                env=brain_env,
            )
        except brain_manifest.BrainUnconfigured:
            self.add(
                "brain.configuration",
                "skip",
                "brain manifest producer is unconfigured (brainConfig absent); Node.js is optional",
                required_for=("brain-manifest",),
            )
            return
        except brain_manifest.BrainConfigurationError as exc:
            self.add(
                "brain.configuration",
                "fail",
                f"configured brain manifest input is invalid: {exc}",
                required_for=("brain-manifest",),
                remediation="Repair brainConfig in the selected singular JSON configuration.",
            )
            return
        if not config_path.is_file():
            self.add(
                "brain.configuration",
                "fail",
                f"configured brain manifest configuration is missing: {config_path}",
                required_for=("brain-manifest",),
                remediation=f"Create {config_path} or update brainConfig in {selected}.",
            )
            return
        cli, vendor_error = brain_manifest.verify_vendor(self.engine)
        if vendor_error:
            self.add(
                "brain.runtime",
                "fail",
                vendor_error,
                required_for=("brain-manifest",),
                remediation="Reinstall the selected singular engine from its verified release payload.",
            )
            return
        node, node_error = brain_manifest.node_diagnostic(self.runtime_env)
        if node_error:
            self.add(
                "brain.node",
                "fail",
                node_error,
                required_for=("brain-manifest",),
                remediation="Install a usable Node.js runtime and ensure node is on PATH.",
            )
            return
        assert cli is not None and node is not None
        result = command(
            [node, str(cli), "print-config", "--config", str(config_path)],
            cwd=self.repo,
            env=self.runtime_env,
        )
        if result.returncode != 0:
            self.add(
                "brain.configuration",
                "fail",
                f"configured brain manifest configuration is invalid: {first_line(result.stderr or result.stdout)}",
                required_for=("brain-manifest",),
                remediation=f"Repair {config_path}; doctor did not generate or bless any output.",
            )
            return
        self.add(
            "brain.configuration",
            "pass",
            f"brain manifest producer is configured: {config_path}",
            required_for=("brain-manifest",),
            details={"config": str(config_path), "runtime": str(cli), "node": node},
        )

    def basic_checks(self) -> None:
        bash_major = int(self.bash_version.split(".", 1)[0] or "0")
        if bash_major >= 4 and self.bash.is_file() and os.access(self.bash, os.X_OK):
            self.add(
                "runtime.bash",
                "pass",
                f"bash >= 4 ({self.bash_version}; {self.bash})",
                required_for=("all-runs",),
                details={"path": str(self.bash), "version": self.bash_version},
            )
        else:
            self.add(
                "runtime.bash",
                "fail",
                f"bash >= 4 required (found {self.bash_version}; {self.bash})",
                required_for=("all-runs",),
                remediation=(
                    "Install Bash >= 4 and set SINGULAR_BASH_BIN to its absolute path "
                    "in the process or service environment."
                ),
            )
        self.add(
            "runtime.python",
            "pass",
            f"python3 ({sys.executable})",
            required_for=("all-runs",),
            details={"path": sys.executable, "version": sys.version.split()[0]},
        )
        git_bin = shutil.which("git")
        if git_bin:
            version = command([git_bin, "--version"]).stdout.strip()
            self.add(
                "runtime.git",
                "pass",
                f"git ({version or git_bin})",
                required_for=("all-runs",),
                details={"path": git_bin},
            )
        else:
            self.add(
                "runtime.git",
                "fail",
                "git is not available",
                required_for=("all-runs",),
                remediation="Install Git and make it available on PATH.",
            )
        version = "?"
        try:
            version = (self.engine / "VERSION").read_text(encoding="utf-8").strip()
        except OSError:
            pass
        if (self.engine / "engine/lib.sh").is_file():
            self.add(
                "engine.resolved",
                "pass",
                f"engine resolved ({self.engine}, v{version})",
                required_for=("all-runs",),
                details={"path": str(self.engine), "version": version},
            )
        else:
            self.add(
                "engine.resolved",
                "fail",
                f"engine has no engine/lib.sh: {self.engine}",
                required_for=("all-runs",),
                remediation="Install the pinned engine or correct SINGULAR_ENGINE_HOME.",
            )
        if PROVIDER_SPEC_ERROR:
            # Without the spec doctor knows no provider: it would report every
            # provider check as "custom runner" and pass an engine that cannot
            # dispatch. Say the real thing once, and block.
            self.add(
                "engine.provider-spec",
                "fail",
                f"provider spec could not be read: {PROVIDER_SPEC_ERROR}",
                required_for=("all-runs",),
                remediation="Repair or reinstall engine/providers.json.",
                details={"path": str(provider_spec.SPEC_PATH)},
            )
        if self.repo:
            self.add(
                "repo.present",
                "pass",
                f"repo: {self.repo}",
                required_for=("all-runs",),
                details={"path": str(self.repo)},
            )

    def process_control_checks(self) -> None:
        """Can this host create a process session and terminate it as a group?

        Timeout cleanup rests on that primitive: a runner is spawned as a
        session leader so a single killpg reaches every descendant without
        enumerating anything. Where the primitive is missing, a timed-out
        agent's provider and shell children outlive the kill and keep writing
        to a worktree — and the restricted sandboxes that break it are the same
        ones that deny `ps`, so the fallback is gone too and the failure is
        silent (PMGO-004). So: probe both, run the real thing rather than
        infer from uname, and let the group-kill failure BLOCK rather than warn.
        An operator who cannot prove cleanup must not actuate unattended.
        """
        seam = ""
        if os.environ.get("SINGULAR_TEST_PROCESS_CONTROL") == "1":
            state = os.environ.get("SINGULAR_TEST_PROCESS_CONTROL_STATE", "")
            if state in PROCESS_CONTROL_SEAM_STATES:
                seam = state
        self.process_group_kill_check(seam)
        self.process_enumeration_check(seam)
        self.interpreter_crash_check()

    def interpreter_crash_check(self) -> None:
        """Surface recent crash reports for the interpreters every run depends on.

        A shell or Python that dies with SIGSEGV under load turns into a red
        gate, a worker that "produced no packet", or a planner that "failed"
        — every one of them attributed to product or provider by the loop,
        none of them fixable by a retry. macOS keeps the evidence in
        ~/Library/Logs/DiagnosticReports; during the 0.21.0 release run the
        Homebrew bash crashed twenty times inside Apple's os_log preferences
        refresh and only that directory said so. This check does not diagnose
        the crash; it makes sure nobody spends a day blaming the product.
        """
        # Never a `skip`: this check has no dependency that could block it, and
        # doctor prints skipped checks after the diagnosis that blocked them.
        # An absent directory or another platform is simply "nothing found".
        check_id = "runtime.interpreter-crashes"
        if sys.platform != "darwin":
            self.add(check_id, "pass",
                     "no interpreter crash-report source on this platform",
                     details={"platform": sys.platform})
            return
        reports_dir = Path.home() / "Library" / "Logs" / "DiagnosticReports"
        interpreters = ("bash", "python3", "python", "git", "sh", "zsh")
        window_seconds = 24 * 3600
        now = time.time()
        counts: dict[str, int] = {}
        newest = 0.0
        try:
            entries = list(reports_dir.iterdir())
        except OSError as exc:
            self.add(check_id, "pass",
                     "no interpreter crash reports found (directory not readable)",
                     details={"path": str(reports_dir), "error": str(exc)})
            return
        for entry in entries:
            if entry.suffix != ".ips":
                continue
            name = entry.name.split("-", 1)[0]
            if name not in interpreters:
                continue
            try:
                mtime = entry.stat().st_mtime
            except OSError:
                continue
            if now - mtime > window_seconds:
                continue
            counts[name] = counts.get(name, 0) + 1
            newest = max(newest, mtime)
        total = sum(counts.values())
        details: dict[str, Any] = {
            "path": str(reports_dir),
            "windowHours": 24,
            "counts": dict(sorted(counts.items())),
        }
        if total == 0:
            self.add(check_id, "pass",
                     "no interpreter crash reports in the last 24h",
                     details=details)
            return
        details["newestAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(newest))
        summary = ", ".join(f"{k} x{v}" for k, v in sorted(counts.items()))
        self.add(
            check_id,
            "warn",
            f"{total} interpreter crash report(s) in the last 24h ({summary})",
            required_for=("unattended-runs",),
            remediation=(
                "An interpreter that segfaults under load makes gates and workers "
                "fail at random and the loop attributes each failure to the product. "
                "Read the newest report under ~/Library/Logs/DiagnosticReports, pin a "
                "different build with SINGULAR_BASH_BIN if the crashing binary is bash, "
                "and lower SINGULAR_MAX_CONCURRENT / SINGULAR_TEST_JOBS until the "
                "reports stop."
            ),
            details=details,
        )

    def process_group_kill_check(self, seam: str) -> None:
        details: dict[str, Any] = {"probe": "spawn-setsid-killpg-verify"}
        if seam:
            details["seam"] = seam
            error = (
                "simulated: process sessions cannot be created or terminated here"
                if seam == "no-group-kill"
                else ""
            )
        else:
            error = self.probe_process_group_kill(details)
        if error:
            self.add(
                "runtime.process-group-kill",
                "fail",
                f"process-group termination is unavailable: {error}",
                required_for=("all-runs", "unattended-runs"),
                remediation=(
                    "This environment cannot create or terminate process sessions; "
                    "timed-out agents cannot be cleaned up safely. Do not run "
                    "unattended actuation here."
                ),
                details=details,
            )
        else:
            self.add(
                "runtime.process-group-kill",
                "pass",
                "process-group termination works (new session created, signalled "
                "as a group, and verified gone)",
                required_for=("all-runs", "unattended-runs"),
                details=details,
            )

    def probe_process_group_kill(self, details: dict[str, Any]) -> str:
        """Run the real primitive. Empty string on success, else the reason.

        Cleanup-safe by construction: the finally block kills anything the
        probe still owns, and a process group is only ever signalled once the
        kernel has confirmed it is the child's own — killpg(0, ...) would hit
        the operator's own shell.
        """
        child: subprocess.Popen[bytes] | None = None
        pgid = 0
        try:
            child = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            details["childPid"] = child.pid
            pgid = os.getpgid(child.pid)
            details["pgid"] = pgid
            if pgid != child.pid:
                return (
                    f"child {child.pid} did not become its own session leader "
                    f"(pgid {pgid})"
                )
            os.killpg(pgid, signal.SIGTERM)
            child.wait(timeout=5)
            # The child is reaped, so an empty group should answer ESRCH at
            # once; poll briefly anyway rather than race the process table.
            deadline = time.monotonic() + 2.0
            while True:
                try:
                    os.killpg(pgid, 0)
                except ProcessLookupError:
                    return ""
                except OSError as exc:
                    return f"process group {pgid} could not be verified gone: {exc}"
                if time.monotonic() >= deadline:
                    return f"process group {pgid} still exists after SIGTERM"
                time.sleep(0.05)
        except subprocess.TimeoutExpired:
            return "child survived SIGTERM sent to its own process group"
        except (OSError, ValueError) as exc:
            return f"{type(exc).__name__}: {exc}"
        finally:
            if child is not None and child.poll() is None:
                if pgid > 1 and pgid == child.pid:
                    try:
                        os.killpg(pgid, signal.SIGKILL)
                    except OSError:
                        pass
                try:
                    child.kill()
                except OSError:
                    pass
                try:
                    child.wait(timeout=2)
                except (subprocess.TimeoutExpired, OSError):
                    pass

    def process_enumeration_check(self, seam: str) -> None:
        """`ps` is now only the fallback, so its absence warns rather than fails.

        It still matters: the group kill covers descendants that stayed in the
        session, and enumeration is what finds the one that called setsid for
        itself. Losing it is a real reduction in containment, just not one that
        should stop a run on its own.
        """
        details: dict[str, Any] = {}
        stderr_line = ""
        if seam:
            details["seam"] = seam
            visible = seam != "no-ps"
            returncode = 0 if visible else 1
            if not visible:
                stderr_line = "simulated: ps is denied in this environment"
        else:
            result = command(["ps", "-A", "-o", "pid=", "-o", "ppid="])
            returncode = result.returncode
            stderr_line = first_line(result.stderr)
            visible = False
            if returncode == 0:
                own = str(os.getpid())
                for line in result.stdout.splitlines():
                    fields = line.split()
                    if fields and fields[0] == own:
                        visible = True
                        break
        details["returncode"] = returncode
        details["selfVisible"] = visible
        if stderr_line:
            details["stderr"] = stderr_line
        if returncode == 0 and visible:
            self.add(
                "runtime.process-enumeration",
                "pass",
                "process enumeration (ps) is available",
                details=details,
            )
        else:
            self.add(
                "runtime.process-enumeration",
                "warn",
                "process enumeration (ps) is unavailable; descendant-tree fallback "
                "cleanup is degraded",
                remediation=(
                    "Session-spawned runners are still killed as a group; restore "
                    "`ps` to recover the fallback that catches escaped descendants."
                ),
                details=details,
            )

    def effective_environment(self) -> None:
        if self.blocked("runtime.config-load"):
            return
        if not self.repo or not (self.engine / "engine/lib.sh").is_file():
            return
        script = r'''
source "$1/engine/lib.sh" >/dev/null
projection="$(singular_effective_configuration_json)"
config_exports=""
if [[ -f "$_singular_selected_json_config_file" ]]; then
  config_exports="$(singular_json_config_to_env "$_singular_selected_json_config_file")"
fi
exec "$2" -c 'import json,os,sys; print(json.dumps({"environment":dict(os.environ),"projection":json.loads(sys.argv[1]),"configExports":sys.stdin.read()},separators=(",",":")))' "$projection" <<<"$config_exports"
'''
        env = dict(os.environ)
        env["SINGULAR_ROOT"] = str(self.repo)
        env["SINGULAR_ENGINE_HOME"] = str(self.engine)
        if self.config_resolution and self.config_resolution.source == "selector":
            env["SINGULAR_JSON_CONFIG_FILE"] = str(self.config_resolution.path)
        else:
            env.pop("SINGULAR_JSON_CONFIG_FILE", None)
            env.pop("SINGULAR_JSON_CONFIG_SOURCE", None)
        result = command(
            [str(self.bash), "-c", script, "_", str(self.engine), sys.executable],
            cwd=self.repo,
            env=env,
        )
        if result.returncode != 0:
            detail = first_line(result.stderr or result.stdout)
            message = (
                f"selected runtime configuration failed to load: {detail or f'exit {result.returncode}'}"
            )
            self.effective_config_projection = unavailable_effective_configuration(
                self.repo,
                env,
                message,
                reason="configuration-load-failed",
                resolution=self.config_resolution,
            )
            self.add(
                "runtime.config-load",
                "fail",
                message,
                required_for=("all-runs",),
                remediation="Repair the repository or local singular configuration.",
            )
            if not self.blocking:
                self.blocking = {
                    "checkId": "runtime.config-load",
                    "code": "SINGULAR_CONFIGURATION_UNAVAILABLE",
                }
            return
        try:
            data = json.loads(result.stdout)
            if not isinstance(data, dict) or not isinstance(data.get("environment"), dict):
                raise ValueError("environment record is not an object")
            projection = data.get("projection")
            if not isinstance(projection, dict):
                raise ValueError("effective configuration projection is not an object")
            configuration = projection.get("configuration")
            if projection.get("schema") != "singular.effective-configuration.v1":
                raise ValueError("effective configuration projection has the wrong schema")
            if not isinstance(configuration, dict) or configuration.get("status") not in {"ok", "absent"}:
                raise ValueError(
                    str((configuration or {}).get("message") or "effective configuration is unavailable")
                )
            paths = projection.get("paths")
            if not isinstance(paths, dict) or not all(
                isinstance(paths.get(key), str) and paths.get(key)
                for key in ("root", "tasks", "state")
            ):
                raise ValueError("effective durable paths are unavailable")
            self.runtime_env = {str(k): str(v) for k, v in data["environment"].items()}
            self.effective_config_projection = projection
            self.config_exports = str(data.get("configExports") or "")
            self.add(
                "runtime.config-load",
                "pass",
                "selected runtime configuration loads",
                required_for=("all-runs",),
            )
        except (json.JSONDecodeError, ValueError) as exc:
            self.runtime_env = {}
            self.effective_config_projection = unavailable_effective_configuration(
                self.repo,
                env,
                f"selected runtime configuration returned invalid data: {exc}",
                reason="configuration-projection-invalid",
                resolution=self.config_resolution,
            )
            self.add(
                "runtime.config-load",
                "fail",
                f"selected runtime configuration returned invalid data: {exc}",
                required_for=("all-runs",),
                remediation="Inspect output emitted while sourcing engine/lib.sh.",
            )
            if not self.blocking:
                self.blocking = {
                    "checkId": "runtime.config-load",
                    "code": "SINGULAR_CONFIGURATION_UNAVAILABLE",
                }

    def config_source_conflict(self) -> None:
        """Two configuration sources, one silent winner (AXON-001).

        `resources.maxConcurrent: 3` and `env: {"SINGULAR_MAX_CONCURRENT": "2"}`
        both describe the dispatch cap; the env{} map wins and nothing said so,
        so an operator who raised the structured field kept running at the old
        concurrency. Rather than re-deriving the structured->env mapping here
        (which would drift the moment engine/lib.sh gains a field), this asks
        the REAL generator what it emits and reads the duplicates: setv() in
        singular_json_config_to_env appends in source order, structured fields
        first and the `env` map last, and `eval` applies them in that order --
        so for any key emitted twice, the first occurrence is the structured
        field and the last is the env{} override that actually takes effect.
        """
        if self.blocked("config.source-conflict"):
            return
        if not self.repo or not (self.engine / "engine/lib.sh").is_file():
            return
        config_path = (
            self.config_resolution.path
            if self.config_resolution
            else self.repo / "singular.config.json"
        )
        if not config_path.is_file():
            return
        if self.config_exports is None:
            self.add(
                "config.source-conflict",
                "skip",
                "configuration sources could not be compared because runtime initialization failed",
                required_for=("all-runs",),
                remediation="Repair singular.config.json (see runtime.config-load).",
            )
            return
        # shlex over the WHOLE emission, not line by line: setv() quotes with
        # shlex.quote, and a quoted value (areas, prompts) may span lines.
        try:
            tokens = shlex.split(self.config_exports)
        except ValueError as exc:
            self.add(
                "config.source-conflict",
                "skip",
                f"configuration export stream is unparseable: {exc}",
                required_for=("all-runs",),
                remediation="Inspect singular_json_config_to_env output by hand.",
            )
            return
        emitted: dict[str, list[str]] = {}
        index = 0
        while index < len(tokens):
            if tokens[index] != "export" or index + 1 >= len(tokens):
                index += 1
                continue
            assignment = tokens[index + 1]
            index += 2
            key, sep, value = assignment.partition("=")
            if not sep or not key:
                continue
            emitted.setdefault(key, []).append(value)
        conflicts: list[dict[str, Any]] = []
        for key in sorted(emitted):
            values = emitted[key]
            if len(values) < 2 or len(set(values)) == 1:
                continue
            structured, effective = values[0], values[-1]
            entry: dict[str, Any] = {
                "key": key,
                "structuredValue": structured,
                "envValue": effective,
                "effective": effective,
            }
            # A third source (singular.config.sh, .singular-state/config.local.sh)
            # sources AFTER the eval, so it can beat the winner named here.
            if self.runtime_env.get(key, effective) != effective:
                entry["runtimeDiffers"] = True
                entry["runtimeValue"] = self.runtime_env.get(key, "")
            conflicts.append(entry)
        if not conflicts:
            self.add(
                "config.source-conflict",
                "pass",
                f"no conflicting configuration sources in {config_path}",
                required_for=("all-runs",),
                details={"config": str(config_path), "conflicts": []},
            )
            return
        clauses = [
            (
                f"{item['key']} (structured field {item['structuredValue']}, "
                f"env{{}} map {item['envValue']}, effective {item['effective']}"
                + (
                    f", but the loaded runtime uses {item['runtimeValue']})"
                    if item.get("runtimeDiffers")
                    else ")"
                )
            )
            for item in conflicts
        ]
        self.add(
            "config.source-conflict",
            "warn",
            f"configuration sources disagree in {config_path}: " + "; ".join(clauses),
            required_for=("all-runs",),
            remediation=(
                f"Update {config_path}: remove the legacy env override or align "
                "it with the structured field; bind concurrency changes to "
                "explicit operator approval."
            ),
            details={"config": str(config_path), "conflicts": conflicts},
        )

    def blocked(self, *check_ids: str) -> bool:
        """Cascade guard: one primary diagnosis instead of a dozen derivatives.

        Every check that INTERPRETS a repository artifact calls this first. When
        a primary incompatibility is already known, the check records why it did
        not run instead of reporting what a schema the engine cannot read looks
        like. Environmental checks (bash, python, git, process control, disk,
        worktrees) never call it: those answer questions about the host, and
        their answers stay true no matter which schema the repo is on.
        """
        if not self.blocking:
            return False
        for check_id in check_ids:
            self.add(
                check_id,
                "skip",
                f"blocked by {self.blocking['checkId']} ({self.blocking['code']})",
                details={"blockedBy": self.blocking["checkId"]},
            )
        return True

    def pin_checks(self) -> None:
        """Which engine does this repo ask for, and is it the one being examined?

        Doctor never read .singular-version at all: the only pin comparison in
        the product lived in the CLI's legacy bash doctor, which nothing
        dispatched to (PMGO-008). Mirrors repo_pin() in cli/singular --
        .singular-version is authoritative, singular.config.json engineVersion is
        the fallback, and a disagreement is reported without changing which one
        wins.
        """
        if not self.repo:
            return
        try:
            file_pin = (
                (self.repo / ".singular-version").read_text(encoding="utf-8").strip()
            )
        except OSError:
            file_pin = ""
        config_pin = str(self.config.get("engineVersion", "") or "").strip()
        self.repo_pin = file_pin or config_pin
        self.repo_pin_source = (
            ".singular-version"
            if file_pin
            else ("singular.config.json engineVersion" if config_pin else "")
        )
        if file_pin and config_pin and file_pin != config_pin:
            self.add(
                "pin.sources",
                "warn",
                (
                    f".singular-version ({file_pin}) and singular.config.json "
                    f"engineVersion ({config_pin}) disagree; using .singular-version"
                ),
                required_for=("all-runs",),
                remediation=(
                    "Align singular.config.json engineVersion with .singular-version "
                    "(or delete one of them)."
                ),
                details={
                    "versionFile": file_pin,
                    "configEngineVersion": config_pin,
                    "resolved": file_pin,
                },
            )
        elif file_pin and config_pin:
            self.add(
                "pin.sources",
                "pass",
                f"engine pin sources agree: {file_pin}",
                required_for=("all-runs",),
                details={
                    "versionFile": file_pin,
                    "configEngineVersion": config_pin,
                    "resolved": file_pin,
                },
            )
        elif self.repo_pin:
            self.add(
                "pin.sources",
                "pass",
                f"engine pin: {self.repo_pin} ({self.repo_pin_source})",
                required_for=("all-runs",),
                details={"resolved": self.repo_pin, "source": self.repo_pin_source},
            )
        else:
            self.add(
                "pin.sources",
                "pass",
                (
                    "no engine pin declared (.singular-version, "
                    "singular.config.json engineVersion)"
                ),
                required_for=("all-runs",),
                details={"resolved": "", "source": ""},
            )
        if self.repo_pin and self.engine_version and self.repo_pin != self.engine_version:
            self.add(
                "pin.engine-version",
                "warn",
                (
                    f"repo pins engine {self.repo_pin} but the examined engine is "
                    f"{self.engine_version}; every check below describes "
                    f"{self.engine_version}, not the engine this repo runs"
                ),
                required_for=("all-runs",),
                remediation=(
                    "Re-run doctor under the pinned engine, or repin the repo: "
                    "singular update"
                ),
                details={
                    "repoPin": self.repo_pin,
                    "pinSource": self.repo_pin_source,
                    "engineVersion": self.engine_version,
                    "enginePath": str(self.engine),
                },
            )
        elif self.repo_pin:
            self.add(
                "pin.engine-version",
                "pass",
                f"examined engine matches the repo pin: {self.repo_pin}",
                required_for=("all-runs",),
                details={
                    "repoPin": self.repo_pin,
                    "pinSource": self.repo_pin_source,
                    "engineVersion": self.engine_version,
                },
            )
        else:
            self.add(
                "pin.engine-version",
                "pass",
                f"no repo engine pin; examined engine {self.engine_version or '?'}",
                required_for=("all-runs",),
                details={"repoPin": "", "engineVersion": self.engine_version},
            )

    def schema_checks(self) -> None:
        schema_dir = self.engine / "schemas"
        try:
            engine_schema = (self.engine / "SCHEMA_VERSION").read_text(
                encoding="utf-8"
            ).strip()
        except OSError:
            engine_schema = ""
        repo_schema = str(self.config.get("schemaVersion", "") or "")
        if engine_schema and repo_schema and engine_schema != repo_schema:
            # The message prefix is a contract (tests/test-versioning.sh); the
            # diagnosis the audit asked for is appended to it, not instead of it.
            message = (
                f"schemaVersion mismatch: repo {repo_schema} vs engine {engine_schema}"
            )
            details: dict[str, Any] = {
                "code": "SINGULAR_SCHEMA_MISMATCH",
                "repoSchema": repo_schema,
                "engineSchema": engine_schema,
                "engineVersion": self.engine_version,
                "repoPin": self.repo_pin,
                "alternateRemediation": "Run: singular migrate",
            }
            if self.repo_pin:
                message += (
                    f" — Repository: engine {self.repo_pin} / schema {repo_schema}; "
                    f"Selected engine: {self.engine_version or 'unknown'} / "
                    f"schema {engine_schema}. "
                    "No planning or actuation was attempted."
                )
            self.add(
                "schema.version",
                "fail",
                message,
                required_for=("all-runs",),
                remediation="Run: singular setup",
                details=details,
            )
            # Everything downstream that reads a repository artifact reads it
            # through a schema this engine cannot interpret. Stop here.
            self.blocking = {
                "checkId": "schema.version",
                "code": "SINGULAR_SCHEMA_MISMATCH",
            }
        elif engine_schema:
            suffix = repo_schema or "not declared"
            status = "pass" if repo_schema else "warn"
            self.add(
                "schema.version",
                status,
                f"engine schema: {engine_schema}; repo schema: {suffix}",
                required_for=("all-runs",),
                remediation="" if repo_schema else "Declare schemaVersion in singular.config.json.",
            )
        # The bundle comparison mirrors the REPO's schemas against the engine's.
        # It used to half-suppress itself on a version mismatch by silently
        # dropping the repo-consumer bundle, which read as a clean pass over a
        # repo nobody had looked at; now it says it did not run.
        if self.blocked("schema.bundle", "schema.fixture.runner-result"):
            return
        parsed: dict[Path, dict[str, Any]] = {}
        errors: list[str] = []

        authoritative_paths = sorted(schema_dir.glob("*.schema.json"))
        authoritative_names = {path.name for path in authoritative_paths}
        ids: dict[str, str] = {}
        for path in authoritative_paths:
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
                if (
                    not isinstance(value, dict)
                    or not isinstance(value.get("$schema"), str)
                    or not value["$schema"]
                    or not isinstance(value.get("$id"), str)
                    or not value["$id"]
                ):
                    raise ValueError("missing object $schema/$id")
                duplicate = ids.get(value["$id"])
                if duplicate:
                    raise ValueError(f"duplicate $id also used by {duplicate}")
                ids[value["$id"]] = path.name
                parsed[path] = value
            except (OSError, json.JSONDecodeError, ValueError) as exc:
                errors.append(f"authoritative/{path.name}: {exc}")
        if not authoritative_paths:
            errors.append("authoritative schema bundle is empty")

        consumer_dirs: list[tuple[str, Path]] = [
            ("engine-consumer", schema_dir / "orchestration")
        ]
        if (
            self.repo
            and repo_schema
            and repo_schema == engine_schema
        ):
            repo_consumer = self.repo / "schemas" / "orchestration"
            try:
                is_engine_consumer = (
                    repo_consumer.resolve()
                    == (schema_dir / "orchestration").resolve()
                )
            except OSError:
                is_engine_consumer = False
            if not is_engine_consumer:
                consumer_dirs.append(("repo-consumer", repo_consumer))

        consumer_counts: dict[str, int] = {}
        consumer_extensions: dict[str, list[str]] = {}
        for label, directory in consumer_dirs:
            if not directory.is_dir():
                errors.append(f"{label}: schema directory missing ({directory})")
                consumer_counts[label] = 0
                consumer_extensions[label] = []
                continue
            consumer_paths = sorted(directory.glob("*.schema.json"))
            consumer_names = {path.name for path in consumer_paths}
            consumer_counts[label] = len(consumer_paths)
            missing_names = sorted(authoritative_names - consumer_names)
            unexpected_names = sorted(consumer_names - authoritative_names)
            allowed_extensions = unexpected_names if label == "repo-consumer" else []
            consumer_extensions[label] = allowed_extensions
            if missing_names:
                errors.append(
                    f"{label}: missing schema copies: {', '.join(missing_names)}"
                )
            if unexpected_names and label != "repo-consumer":
                errors.append(
                    f"{label}: unexpected schema copies: {', '.join(unexpected_names)}"
                )
            for path in consumer_paths:
                try:
                    value = json.loads(path.read_text(encoding="utf-8"))
                    if (
                        not isinstance(value, dict)
                        or not isinstance(value.get("$schema"), str)
                        or not value["$schema"]
                        or not isinstance(value.get("$id"), str)
                        or not value["$id"]
                    ):
                        raise ValueError("missing object $schema/$id")
                except (OSError, json.JSONDecodeError, ValueError) as exc:
                    errors.append(f"{label}/{path.name}: {exc}")
                    continue
                authoritative = schema_dir / path.name
                if authoritative.is_file():
                    try:
                        if authoritative.read_bytes() != path.read_bytes():
                            errors.append(
                                f"{label}/{path.name}: consumer copy differs "
                                "from authoritative schema"
                            )
                    except OSError as exc:
                        errors.append(f"{label}/{path.name}: {exc}")
        if errors:
            self.add(
                "schema.bundle",
                "fail",
                f"schemas missing, invalid, or drifted: {'; '.join(errors[:8])}",
                required_for=("all-runs",),
                remediation="Restore the engine schema bundle and regenerate consumer mirrors.",
                details={
                    "authoritativeSchemaCount": len(authoritative_paths),
                    "consumerSchemaCounts": consumer_counts,
                    "consumerExtensions": consumer_extensions,
                    "errors": errors[:100],
                },
            )
        else:
            extension_count = sum(
                len(names) for names in consumer_extensions.values()
            )
            self.add(
                "schema.bundle",
                "pass",
                (
                    f"all {len(parsed)} authoritative schemas are present and "
                    f"byte-identical in {len(consumer_dirs)} consumer bundle(s); "
                    f"{extension_count} consumer-only extension(s) validated"
                ),
                required_for=("all-runs",),
                details={
                    "authoritativeSchemaCount": len(parsed),
                    "consumerSchemaCounts": consumer_counts,
                    "consumerExtensions": consumer_extensions,
                },
            )
        runner_schema = parsed.get(schema_dir / "runner-result.v0.schema.json")
        fixture = {
            "schema": "singular.orchestration.runner-result.v0",
            "contractVersion": 1,
            "provider": "codex",
            "runId": "doctor-fixture",
            "role": "doctor",
            "capabilityProfile": "doctor-core",
            "exitCode": 0,
            "outcome": "succeeded",
            "failureClass": "none",
            "providerErrorRef": None,
            "outputRef": None,
            "recordedAt": "2026-07-24T00:00:00Z",
        }
        fixture_errors = self.validate_simple_schema(runner_schema, fixture)
        if fixture_errors:
            self.add(
                "schema.fixture.runner-result",
                "fail",
                f"runner-result schema fixture failed: {'; '.join(fixture_errors)}",
                required_for=("provider-runs",),
                remediation="Repair runner-result.v0 schema/fixture compatibility.",
            )
        else:
            self.add(
                "schema.fixture.runner-result",
                "pass",
                "runner-result schema fixture validates",
                required_for=("provider-runs",),
            )

    @staticmethod
    def validate_simple_schema(
        schema: dict[str, Any] | None, value: dict[str, Any]
    ) -> list[str]:
        if not schema:
            return ["schema missing"]
        errors: list[str] = []
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                errors.append(f"missing {key}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    errors.append(f"unexpected {key}")
        for key, spec in properties.items():
            if key not in value or not isinstance(spec, dict):
                continue
            item = value[key]
            if "const" in spec and item != spec["const"]:
                errors.append(f"{key} const mismatch")
            if "enum" in spec and item not in spec["enum"]:
                errors.append(f"{key} enum mismatch")
            expected = spec.get("type")
            expected_types = expected if isinstance(expected, list) else [expected]
            type_ok = False
            for candidate in expected_types:
                type_ok = type_ok or {
                    "string": isinstance(item, str),
                    "integer": isinstance(item, int) and not isinstance(item, bool),
                    "boolean": isinstance(item, bool),
                    "null": item is None,
                    "object": isinstance(item, dict),
                    "array": isinstance(item, list),
                    None: True,
                }.get(candidate, True)
            if not type_ok:
                errors.append(f"{key} type mismatch")
        return errors

    def host_hygiene_checks(self) -> None:
        """Checks that describe the HOST, not the repository's data contract.

        These used to sit inside repo_hygiene_checks(), behind its cascade
        guard, so a schema mismatch made them vanish outright -- not even a
        `skip` with a blockedBy, which is the one thing blocked() promises. A
        broken ~/.codex/hooks.json breaks every Codex run on this machine
        whatever schema the repo is on, and a pidfile names a process that is
        either running or not; neither answer is a function of the schema. Both
        stay live, always, exactly as blocked()'s own docstring says the
        environmental checks must.

        Called from run() immediately before repo_hygiene_checks(), so the
        report keeps its established order.
        """
        codex_dir = Path(
            self.runtime_env.get(
                "CODEX_HOME", str(Path(self.runtime_env.get("HOME", str(Path.home()))) / ".codex")
            )
        )
        hooks = codex_dir / "hooks.json"
        if hooks.is_file():
            try:
                json.loads(hooks.read_text(encoding="utf-8"))
                self.add(
                    "codex.hooks",
                    "pass",
                    "~/.codex/hooks.json parses",
                    required_for=("codex-runs",),
                )
            except (OSError, json.JSONDecodeError) as exc:
                self.add(
                    "codex.hooks",
                    "fail",
                    f"~/.codex/hooks.json is not valid JSON: {exc}",
                    required_for=("codex-runs",),
                    remediation="Repair the file or replace it with an empty JSON object.",
                )
        else:
            self.add(
                "codex.hooks",
                "skip",
                "~/.codex/hooks.json is absent",
                required_for=("codex-runs",),
            )
        if not self.repo:
            return
        if self.blocking and self.blocking.get("checkId") == "runtime.config-load":
            self.add(
                "state.pidfiles",
                "skip",
                "state pidfiles were not inspected because the durable state root is unknown",
                details={"blockedBy": "runtime.config-load"},
            )
            return
        # A pidfile probe has FOUR outcomes, and they are not interchangeable.
        # This loop used to catch `(OSError, ValueError)` as one case and call
        # all of it "stale", so a sandbox that denies process inspection made
        # doctor report the live console server as a leftover (PMGO-005).
        # `kill(pid, 0)` answering EPERM means "the process may well be there,
        # I am not permitted to look" — the opposite of proof of death. Only
        # ESRCH is that proof, and only that verdict may suggest deleting the
        # file. Doctor itself never removes one in any verdict.
        for name in ("autonomate.pid", "console.pid"):
            path = self.repo / ".singular-state" / name
            if not path.is_file():
                continue
            check_id = f"state.pidfile.{safe_slug(name)}"
            dedupe_key = f"pidfile:{path}"
            try:
                pid: int | None = int(path.read_text(encoding="utf-8").strip())
            except (OSError, ValueError, OverflowError):
                pid = None
            if pid is not None and pid <= 0:
                # kill(2) reads 0 and negatives as process-GROUP selectors
                # rather than pids. Probing one asks about our own group, or
                # about every process we are allowed to signal, and would
                # report a garbage pidfile as naming something alive.
                pid = None
            verdict = "malformed" if pid is None else self.pidfile_probe_verdict(pid)
            details: dict[str, Any] = {"verdict": verdict}
            if pid is not None:
                details["pid"] = pid
            if verdict == "alive":
                self.add(
                    check_id,
                    "pass",
                    f"pidfile {path} names live PID {pid}",
                    dedupe_key=dedupe_key,
                    details=details,
                )
            elif verdict == "stale":
                self.add(
                    check_id,
                    "warn",
                    f"stale pidfile {path}",
                    remediation="Restart the process or remove this stale pidfile.",
                    dedupe_key=dedupe_key,
                    details=details,
                )
            elif verdict == "unknown-permission":
                self.add(
                    check_id,
                    "warn",
                    f"PID {pid} exists or is inaccessible; liveness unknown because "
                    "the environment denied process inspection. Do not delete the "
                    "pidfile automatically.",
                    remediation=(
                        "Verify process ownership manually from a process-capable "
                        "shell before acting."
                    ),
                    dedupe_key=dedupe_key,
                    details=details,
                )
            else:
                self.add(
                    check_id,
                    "warn",
                    f"malformed pidfile {path} (contents are not a PID)",
                    remediation="Regenerate or remove it; it cannot identify a process.",
                    dedupe_key=dedupe_key,
                    details=details,
                )

    def repo_hygiene_checks(self) -> None:
        """The half that INTERPRETS repository artifacts, and only that half.

        Scanning prompts and mirrored schemas for legacy `pmgo.*` ids is a
        statement about a data contract this engine may not be able to read at
        all, so it is exactly what the cascade guard is for -- and the skip
        entry it leaves keeps the audit trail intact.
        """
        if self.blocked("schema.legacy-ids"):
            return
        if not self.repo:
            return
        hits: list[str] = []
        for base in (
            self.repo / "docs/orchestration/prompts",
            self.repo / "schemas",
        ):
            if not base.is_dir():
                continue
            for path in base.rglob("*"):
                if path.suffix not in {".json", ".md"} or not path.is_file():
                    continue
                try:
                    if '"pmgo.' in path.read_text(encoding="utf-8", errors="replace"):
                        hits.append(str(path.relative_to(self.repo)))
                except OSError:
                    continue
                if len(hits) >= 5:
                    break
        if hits:
            self.add(
                "schema.legacy-ids",
                "fail",
                f"legacy pmgo.* schema ids found: {', '.join(hits)}",
                required_for=("all-runs",),
                remediation="Run migrations/v0-to-v1.sh or singular migrate.",
            )
        else:
            self.add(
                "schema.legacy-ids",
                "pass",
                "no legacy pmgo.* schema ids in prompts/schemas",
                required_for=("all-runs",),
            )

    def pidfile_probe_verdict(self, pid: int) -> str:
        """alive | stale | unknown-permission | malformed, for the loop above.

        The seam exists because EPERM cannot be provoked portably from a test
        process that owns everything it spawns, and EPERM is the exact case
        PMGO-005 was about. Both variables are required and the state must be
        one this map knows: a lone or misspelled variable falls through to the
        real syscall, so a value inherited from some other run can never
        quietly rewrite an operator's diagnosis. Same discipline, and the same
        state names, as ops_pid_probe_state in engine/ops.sh.
        """
        if os.environ.get("SINGULAR_TEST_PID_PROBE") == "1":
            seam = PID_PROBE_SEAM_VERDICTS.get(
                os.environ.get("SINGULAR_TEST_PID_PROBE_STATE", "")
            )
            if seam:
                return seam
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return "stale"
        except (OverflowError, ValueError):
            # Numeric, but no such thing as that pid on this platform.
            return "malformed"
        except OSError:
            # PermissionError and anything else the kernel refuses to answer.
            # Inconclusive is not dead.
            return "unknown-permission"
        return "alive"

    def resolve_runner(self) -> None:
        if self.blocked("runner.selected"):
            return
        projection = self.effective_config_projection or {}
        raw = projection.get("runner")
        if not isinstance(raw, str) or not raw:
            self.add(
                "runner.selected",
                "skip",
                "selected runner identity is unavailable",
                required_for=("provider-runs",),
                details={"provider": "unknown"},
            )
            return
        runner = Path(raw)
        if not runner.is_absolute() and self.repo:
            runner = self.repo / runner
        self.runner = runner.resolve()
        proved_provider = projection.get("provider")
        self.provider = (
            str(proved_provider)
            if isinstance(proved_provider, str) and proved_provider not in {"", "unknown"}
            else None
        )
        if self.runner.is_file() and os.access(self.runner, os.X_OK):
            self.add(
                "runner.selected",
                "pass",
                f"selected runner: {self.runner}",
                required_for=("provider-runs",),
                details={"path": str(self.runner), "provider": self.provider or "custom"},
            )
        else:
            self.add(
                "runner.selected",
                "fail",
                f"selected runner is not executable: {self.runner}",
                required_for=("provider-runs",),
                remediation="Select an executable runner in singular.config.json.",
            )

    def check_runner_contract(self) -> None:
        if self.blocked("runner.contract-v1"):
            return
        if not self.runner or not self.runner.is_file():
            return
        result = command(
            [str(self.runner), "--describe-contract"],
            cwd=self.repo,
            env=self.runtime_env,
        )
        if result.returncode != 0:
            detail = first_line(result.stderr or result.stdout)
            self.add(
                "runner.contract-v1",
                "fail",
                f"selected runner contract probe failed (exit {result.returncode}): {detail}",
                required_for=("provider-runs",),
                remediation=(
                    "Upgrade the runner to contract v1. Legacy custom runners cannot "
                    "start strict-profile or structured-error runs."
                ),
            )
            return
        try:
            contract = json.loads(result.stdout)
            arguments = set(contract.get("arguments", []))
            missing = sorted(REQUIRED_RUNNER_ARGUMENTS - arguments)
            errors = []
            if contract.get("schema") != "singular.runner-contract.v1":
                errors.append("wrong schema")
            if contract.get("version") != 1:
                errors.append("wrong version")
            if missing:
                errors.append("missing " + ",".join(missing))
            if "--stage-dir" in arguments:
                errors.append("forbidden orchestration argument --stage-dir")
            if (
                contract.get("structuredResult")
                != "singular.orchestration.runner-result.v0"
            ):
                errors.append("wrong structured result")
            if (
                contract.get("structuredProviderError")
                != "singular.orchestration.provider-error.v0"
            ):
                errors.append("wrong provider error")
            if errors:
                raise ValueError("; ".join(errors))
            self.runner_contract_ok = True
            self.add(
                "runner.contract-v1",
                "pass",
                "selected runner implements contract v1",
                required_for=("provider-runs",),
                details={
                    "provider": contract.get("provider"),
                    "arguments": sorted(arguments),
                },
            )
        except (json.JSONDecodeError, ValueError) as exc:
            self.add(
                "runner.contract-v1",
                "fail",
                f"selected runner returned an invalid contract: {exc}",
                required_for=("provider-runs",),
                remediation="Upgrade or repair the selected provider runner.",
            )

    def resolve_provider_executable(self) -> None:
        if self.blocked("provider.executable"):
            return
        if not self.provider:
            self.add(
                "provider.executable",
                "skip",
                "custom runner owns provider executable resolution",
                required_for=("custom-runner",),
            )
            return
        command_name = PROVIDERS[self.provider][1]
        # Shared with engine/lib.sh's singular_resolve_codex_bin and the console's
        # Providers probe. All three must answer identically or the operator gets
        # a card describing an executable the orchestration is not running;
        # tests/test-provider-resolver-parity.sh pins bash against this module.
        resolution = resolve_provider_bin(
            self.provider, command_name, self.runtime_env
        )
        if not resolution.ok:
            if resolution.configured:
                self.add(
                    "provider.executable",
                    "fail",
                    "selected Codex executable could not be resolved: "
                    f"{resolution.configured}",
                    required_for=("selected-provider",),
                    remediation=(
                        "Set SINGULAR_CODEX_BIN to an absolute executable path. "
                        "An explicit broken path never falls back to PATH."
                    ),
                )
                return
            self.add(
                "provider.executable",
                "fail",
                f"selected {self.provider} executable is not on PATH",
                required_for=("selected-provider",),
                remediation=f"Install {command_name} or select a different runner.",
            )
            return
        self.provider_bin = Path(resolution.path)
        label = "Codex" if self.provider == "codex" else self.provider
        self.add(
            "provider.executable",
            "pass",
            f"selected {label} executable: {self.provider_bin}",
            required_for=("selected-provider",),
            details={"provider": self.provider, "path": str(self.provider_bin)},
        )
        result = command(
            [str(self.provider_bin), "--version"],
            cwd=self.repo,
            env=self.runtime_env,
        )
        combined = (result.stdout or "") + (result.stderr or "")
        if result.returncode == 0:
            self.provider_version_output = combined
            shown = first_line(combined) or "version probe passed"
            self.add(
                "provider.spawn",
                "pass",
                f"selected {label} spawn: {shown}",
                required_for=("selected-provider",),
                details={"version": shown},
            )
        else:
            detail = first_line(combined)
            self.add(
                "provider.spawn",
                "fail",
                f"selected {label} spawn probe failed (exit {result.returncode}): {detail}",
                required_for=("selected-provider",),
                remediation="Repair the exact selected executable before starting the engine.",
            )

    def provider_auth(self) -> None:
        """Is the exact selected executable signed in?

        One generic pass over the spec's auth row, not a branch per provider:
        the branch is where grok was hardcoded ``authenticated = True``, so an
        unauthenticated host passed the gate and failed later, inside a run.
        A row declares either a probe command or an env/credential-file pair --
        never both, never neither -- and credential files are tested for
        existence only; they are never opened or printed.
        """
        if self.blocked("provider.authentication"):
            return
        if not self.provider or not self.provider_bin:
            return
        label = "Codex" if self.provider == "codex" else self.provider
        auth = provider_spec.entry(self.provider)["auth"]
        probe = list(auth.get("probe", []))
        if probe:
            argv = [str(self.provider_bin), *probe]
            result = command(argv, cwd=self.repo, env=self.runtime_env)
            combined = (result.stdout or "") + (result.stderr or "")
            if result.returncode == 0:
                self.add(
                    "provider.authentication",
                    "pass",
                    f"selected {label} authentication",
                    required_for=("selected-provider",),
                )
            else:
                self.add(
                    "provider.authentication",
                    "fail",
                    (
                        f"selected {label} authentication probe failed "
                        f"(exit {result.returncode}): {first_line(combined)}"
                    ),
                    required_for=("selected-provider",),
                    remediation=(
                        auth.get("hint", "")
                        or f"Authenticate the exact selected {label} executable."
                    ),
                )
            return
        home = Path(self.runtime_env.get("HOME", str(Path.home())))
        hint = auth.get("hint", "")
        authenticated = any(
            self.runtime_env.get(name) for name in auth.get("env", [])
        ) or any(
            (home / relative).is_file() for relative in auth.get("credentialFiles", [])
        )
        self.add(
            "provider.authentication",
            "pass" if authenticated else "fail",
            (
                f"selected {label} authentication"
                if authenticated
                else f"selected {label} authentication is not configured"
            ),
            required_for=("selected-provider",),
            remediation="" if authenticated else hint,
        )

    def model_checks(self) -> None:
        if self.blocked("model.availability"):
            return
        if not self.provider:
            self.model_conformance_check()
            return
        for provider, (env_name, default) in MODEL_ENV.items():
            model = self.runtime_env.get(env_name, default)
            if not model:
                continue
            valid = bool(MODEL_PATTERNS[provider].search(model))
            selected = provider == self.provider
            status = "pass" if valid else ("fail" if selected else "warn")
            if valid:
                message = f"{provider} model: {model}"
            else:
                message = f"{env_name} '{model}' has an unrecognized prefix (typo?)"
            self.add(
                f"model.selection.{provider}",
                status,
                message,
                required_for=("selected-provider",) if selected else (),
                remediation=(
                    "" if valid else f"Set {env_name} to a model ID accepted by {provider}."
                ),
            )
        if self.provider == "codex":
            default_model = MODEL_ENV["codex"][1]
            routing = {
                role: codex_role_settings(self.runtime_env, role, default_model)
                for role in (
                    "planner",
                    "implementer",
                    "auditor",
                    "critic",
                    "decider",
                    "supervisor",
                    "integrator",
                )
            }
            invalid = {
                role: str(settings["model"])
                for role, settings in routing.items()
                if not MODEL_PATTERNS["codex"].search(str(settings["model"] or ""))
            }
            self.add(
                "model.routing.codex",
                "fail" if invalid else "pass",
                (
                    "Codex role routing contains invalid models: "
                    + ", ".join(f"{role}={model}" for role, model in invalid.items())
                    if invalid
                    else "Codex role model, effort and requested service tier resolved"
                ),
                required_for=("codex-runs", "selected-provider"),
                remediation=(
                    "Set each SINGULAR_CODEX_<ROLE>_MODEL override to a Codex model ID."
                    if invalid
                    else ""
                ),
                details={
                    "roles": routing,
                    "providerObservedServiceTier": None,
                    "observation": "provider did not attest service tier during preflight",
                },
            )
        self.model_conformance_check()

    def wanted_models(self, provider: str) -> dict[str, str]:
        """Model ids this configuration would actually ask <provider> for.

        The configured default plus every SINGULAR_<P>_*_MODEL role override in
        scope: an override names a model exactly as capable of not existing as
        the default is, and under role-keyed selection it is the one a given
        dispatch will use.
        """
        env_name, default = MODEL_ENV[provider]
        prefix = f"SINGULAR_{provider.upper()}_"
        wanted: dict[str, str] = {}
        for name, raw in sorted(self.runtime_env.items()):
            if not name.startswith(prefix):
                continue
            if name != env_name and not name.endswith("_MODEL"):
                continue
            value = raw.strip()
            if value:
                wanted[name] = value
        if default and env_name not in wanted:
            wanted[env_name] = default
        return wanted

    def model_conformance_check(self) -> None:
        """Is every model this configuration would ask for served by the CLI?

        `model.selection.*` above validates shape, not existence -- which is
        exactly how `grok-build` shipped: it matched ^grok-, doctor passed it,
        and every grok invocation ever constructed asked for a model id the
        installed CLI never served. So the verdict here comes from the
        installation's own inventory: codex's model cache, or the provider's
        own `models` listing, run bounded, non-mutating, update-pinned, and
        cached per CLI version. A configured model absent from that inventory
        fails and blocks provider runs the way a dead runner does. An inventory
        that cannot be read is reported as unverified -- never as a pass,
        because a guessed pass is what let grok-build through.
        """
        if not self.provider:
            self.add(
                "model.availability",
                "skip",
                "custom runner owns model selection",
                required_for=("custom-runner",),
                remediation="Confirm the configured model with the provider before a large run.",
            )
            return
        provider = self.provider
        label = "Codex" if provider == "codex" else provider
        models, source, unavailable, details = self.model_inventory(provider)
        wanted = self.wanted_models(provider)
        details["wanted"] = wanted
        if unavailable:
            self.add(
                "model.availability",
                "warn" if self.provider_declares_inventory(provider) else "skip",
                f"{label} model availability is unverified: {unavailable}",
                required_for=("provider-runs", "selected-provider"),
                remediation=(
                    self.inventory_remediation(provider)
                    if self.provider_declares_inventory(provider)
                    else "Confirm the configured model with the provider before a large run."
                ),
                details=details,
                # An unreadable Codex cache is one operator card, shared with
                # model-cache.compatibility, not two descriptions of one file.
                dedupe_key=(
                    "codex:model-cache" if details.pop("cacheUnreadable", False) else None
                ),
            )
            return
        details["models"] = sorted(models)[:64]
        details["source"] = source
        missing = {
            name: value
            for name, value in wanted.items()
            if value not in models and not model_is_alias(value)
        }
        if missing:
            details["missing"] = missing
            shown = ", ".join(f"{name}={value}" for name, value in sorted(missing.items()))
            if provider == "codex":
                details.update({
                    "evidenceStatus": "cache-omission",
                    "inventoryProvenance": "codex-local-cache",
                    "inventoryComplete": False,
                    "providerRejected": False,
                })
                self.add(
                    "model.availability",
                    "warn",
                    f"configured Codex model is omitted from an incomplete local inventory: {shown}",
                    required_for=("provider-runs", "selected-provider"),
                    remediation=(
                        "Refresh the Codex inventory or run a bounded native canary; "
                        "only a provider response can establish rejection."
                    ),
                    details=details,
                )
                return
            self.add(
                "model.availability",
                "fail",
                f"configured {label} model is absent from the inventory: {shown}",
                required_for=("provider-runs", "selected-provider"),
                remediation=(
                    f"Set it to a model this {label} installation serves "
                    f"({', '.join(sorted(models)[:8])})."
                ),
                details=details,
            )
            return
        served = ", ".join(sorted({value for value in wanted.values()}))
        where = (
            f"the {label} catalog"
            if provider_spec.model_inventory(provider) == provider_spec.INVENTORY_COMMAND
            else "the installed CLI"
        )
        self.add(
            "model.availability",
            "pass",
            f"configured {label} models are served by {where}: {served}",
            required_for=("provider-runs", "selected-provider"),
            details=details,
        )

    def provider_declares_inventory(self, provider: str) -> bool:
        """Does this provider promise an inventory doctor can read at all?

        The distinction is the difference between "the CLI has a listing and it
        did not answer" (a warning an operator can act on) and "this CLI has no
        listing" (a fact about the provider, not a defect on this host).
        """
        return provider == "codex" or provider in MODEL_LISTINGS

    def inventory_remediation(self, provider: str) -> str:
        if provider == "codex":
            return "Run the selected Codex CLI once to refresh its model inventory."
        listing = " ".join(MODEL_LISTINGS.get(provider, ()))
        return (
            f"Run `{PROVIDERS[provider][1]} {listing}` against the selected "
            "executable and repair whatever it reports."
        )

    def model_inventory(
        self, provider: str
    ) -> tuple[set[str], str, str, dict[str, Any]]:
        """(model ids, source, unavailable reason, details)."""
        if provider == "codex":
            return self.codex_inventory()
        listing = MODEL_LISTINGS.get(provider)
        details: dict[str, Any] = {"provider": provider}
        if not listing:
            return set(), "", f"the {provider} CLI exposes no model listing", details
        # Two shapes: the provider binary answers for itself, or the catalog is
        # a standalone command because it does not live in the CLI at all
        # (OpenRouter serves its own over HTTP, and it is the same catalog no
        # matter which host CLI dispatches the model).
        standalone = provider_spec.model_inventory(provider) == provider_spec.INVENTORY_COMMAND
        if standalone:
            argv = list(listing)
            source = " ".join(argv)
            cache_key = f"command:{source}"
        else:
            if not self.provider_bin:
                return set(), "", "the selected executable was not resolved", details
            argv = [str(self.provider_bin), *listing]
            source = " ".join([PROVIDERS[provider][1], *listing])
            cache_key = f"{self.provider_bin}@{first_line(self.provider_version_output)}"
        details["listing"] = source
        prefix = provider_spec.model_listing_prefix(provider)
        if prefix:
            details["listingPrefix"] = prefix
        cache_path = self.model_listing_cache_path(provider)
        cached = self.cached_model_listing(cache_path, cache_key)
        if cached is not None:
            details["cache"] = "hit"
            details["cachePath"] = str(cache_path)
            return {prefix + model for model in cached}, source, "", details
        details["cache"] = "miss"
        models, error = self.probe_model_listing(provider, argv)
        if error:
            return set(), source, f"`{source}` did not answer: {error}", details
        if cache_path is not None:
            details["cachePath"] = str(cache_path)
            self.store_model_listing(cache_path, cache_key, models, source)
        return {prefix + model for model in models}, source, "", details

    def codex_inventory(self) -> tuple[set[str], str, str, dict[str, Any]]:
        cache = self.codex_cache_path()
        details: dict[str, Any] = {
            "provider": "codex",
            "cachePath": str(cache),
            "inventoryProvenance": "codex-local-cache",
            "inventoryComplete": False,
            "providerRejected": False,
        }
        try:
            data = json.loads(cache.read_text(encoding="utf-8"))
            fetched = data.get("fetched_at") or data.get("fetchedAt")
            if fetched:
                details["fetchedAt"] = str(fetched)
                try:
                    observed = dt.datetime.fromisoformat(str(fetched).replace("Z", "+00:00"))
                    details["inventoryStale"] = (
                        dt.datetime.now(dt.UTC) - observed
                    ).total_seconds() > MODEL_LISTING_TTL_SEC
                except (TypeError, ValueError):
                    details["inventoryStale"] = True
            slugs = {
                str(item.get("slug"))
                for item in data.get("models", [])
                if isinstance(item, dict) and item.get("slug")
            }
            if not slugs:
                return set(), "", "the local Codex inventory names no models", details
            return slugs, str(cache), "", details
        except FileNotFoundError:
            return set(), "", "no local Codex inventory has been written yet", details
        except (OSError, json.JSONDecodeError) as exc:
            details["cacheUnreadable"] = True
            return set(), "", f"the local Codex inventory is unreadable: {exc}", details

    def probe_model_listing(
        self, provider: str, argv: list[str]
    ) -> tuple[list[str], str]:
        """Ask for the catalog. Bounded, pinned, read-only.

        Where the argv runs the provider binary it carries that CLI's update pin
        as its first arguments: a provider that can replace its own executable
        during a preflight probe would swap the binary the run is about to use.
        """
        result = command(
            argv,
            cwd=self.repo,
            env=self.runtime_env,
            timeout=MODEL_LISTING_TIMEOUT_SEC,
        )
        if result.returncode != 0:
            detail = first_line(result.stderr or result.stdout)
            return [], detail or f"exit {result.returncode}"
        models = parse_model_listing(result.stdout, MODEL_PATTERNS[provider])
        if not models:
            models = parse_model_listing(result.stderr, MODEL_PATTERNS[provider])
        if not models:
            return [], "its output named no models"
        return models, ""

    def model_listing_cache_path(self, provider: str) -> Path | None:
        base = self.runtime_env.get("SINGULAR_STATE_DIR", "")
        root = Path(base) if base else (self.repo / ".singular-state" if self.repo else None)
        if root is None:
            return None
        return root / "doctor-cache" / f"models-{provider}.json"

    def cached_model_listing(
        self, path: Path | None, cli_key: str
    ) -> list[str] | None:
        """The last listing, if it still describes THIS executable and is fresh.

        Keyed by executable path plus version string, so an upgraded or
        re-pointed CLI is never validated against the inventory of the one it
        replaced, and bounded by a TTL so a listing that changed server-side is
        re-read within a day. A cache from the future is stale, not fresh.
        """
        if path is None:
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(data, dict):
            return None
        if data.get("schema") != MODEL_LISTING_CACHE_SCHEMA:
            return None
        if str(data.get("cliKey", "")) != cli_key:
            return None
        try:
            fetched = dt.datetime.fromisoformat(
                str(data.get("fetchedAt", "")).replace("Z", "+00:00")
            )
        except ValueError:
            return None
        age = (dt.datetime.now(dt.UTC) - fetched).total_seconds()
        if not 0 <= age <= MODEL_LISTING_TTL_SEC:
            return None
        models = data.get("models")
        if not isinstance(models, list) or not models:
            return None
        return [str(model) for model in models]

    def store_model_listing(
        self, path: Path, cli_key: str, models: list[str], source: str
    ) -> None:
        payload = {
            "schema": MODEL_LISTING_CACHE_SCHEMA,
            "cliKey": cli_key,
            "fetchedAt": utc_now(),
            "source": source,
            "models": models,
        }
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_name(f"{path.name}.tmp-{os.getpid()}")
            tmp.write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            os.replace(tmp, path)
        except OSError:
            # A cache that cannot be written is a slower probe on the next run,
            # never a failed preflight: the verdict above already stands on the
            # listing itself.
            pass

    def codex_cache_path(self) -> Path:
        base = self.runtime_env.get("CODEX_HOME")
        if base:
            return Path(base) / "models_cache.json"
        return Path(self.runtime_env.get("HOME", str(Path.home()))) / ".codex/models_cache.json"

    def maybe_repair_model_cache(self) -> None:
        if not self.repair_model_cache:
            return
        if self.blocked("model-cache.repair"):
            return
        cache = self.codex_cache_path()
        if not cache.is_file():
            self.add(
                "model-cache.repair",
                "skip",
                f"model cache is absent; nothing to back up: {cache}",
                remediation="Run Codex to regenerate its model inventory.",
            )
            return
        try:
            digest = hashlib.sha256(cache.read_bytes()).hexdigest()
            stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
            backup = cache.with_name(
                f"{cache.name}.bak-{stamp}-{digest[:12]}"
            )
            if backup.exists():
                raise FileExistsError(f"backup already exists: {backup}")
            os.replace(cache, backup)
            self.add(
                "model-cache.repair",
                "pass",
                f"model cache preserved as {backup}; Codex will regenerate it",
                remediation="Run the selected Codex CLI once to regenerate the cache.",
                details={"backup": str(backup), "sha256": digest},
            )
        except OSError as exc:
            self.add(
                "model-cache.repair",
                "fail",
                f"model cache backup-and-repair failed: {exc}",
                remediation="Check file ownership and free space, then retry explicitly.",
            )

    def model_cache_compatibility(self) -> None:
        if self.blocked("model-cache.compatibility"):
            return
        if self.provider != "codex":
            self.add(
                "model-cache.compatibility",
                "skip",
                "Codex model cache is not used by the selected provider",
                required_for=("codex-runs",),
            )
            return
        cache = self.codex_cache_path()
        if not cache.is_file():
            self.add(
                "model-cache.compatibility",
                "skip",
                "Codex model cache is absent",
                required_for=("codex-runs",),
                remediation="Run Codex once to populate its model inventory.",
            )
            return
        try:
            data = json.loads(cache.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or not isinstance(data.get("models"), list):
                raise ValueError("expected an object with a models array")
            cache_version_text = str(data.get("client_version", ""))
            cache_version = parse_version(cache_version_text)
            cli_version = parse_version(self.provider_version_output)
            incompatible_fields = sorted(
                {
                    "supports_reasoning_summaries"
                    for item in data["models"]
                    if isinstance(item, dict)
                    and "supports_reasoning_summaries" in item
                }
            )
            newer = bool(cache_version and cli_version and cache_version > cli_version)
            if newer or incompatible_fields:
                reasons = []
                if newer:
                    reasons.append(
                        f"cache client {cache_version_text} is newer than selected CLI "
                        f"{'.'.join(map(str, cli_version or ())) or '?'}"
                    )
                if incompatible_fields:
                    reasons.append("unsupported fields: " + ", ".join(incompatible_fields))
                self.add(
                    "model-cache.compatibility",
                    "warn",
                    "Codex model cache may be incompatible: " + "; ".join(reasons),
                    required_for=("codex-runs",),
                    remediation=(
                        "Upgrade the selected Codex CLI or run "
                        "singular doctor --repair-model-cache. Repair always keeps a backup."
                    ),
                    dedupe_key="codex:model-cache",
                    details={
                        "cachePath": str(cache),
                        "cacheClientVersion": cache_version_text or None,
                        "selectedCliVersion": (
                            ".".join(map(str, cli_version)) if cli_version else None
                        ),
                    },
                )
            else:
                self.add(
                    "model-cache.compatibility",
                    "pass",
                    "Codex model cache is compatible with the selected CLI",
                    required_for=("codex-runs",),
                )
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            self.add(
                "model-cache.compatibility",
                "warn",
                f"Codex model cache is invalid or unreadable: {exc}",
                required_for=("codex-runs",),
                remediation=(
                    "Run singular doctor --repair-model-cache. The original is backed up "
                    "before Codex regenerates it."
                ),
                dedupe_key="codex:model-cache",
            )

    def disposable_worktree(self) -> None:
        if not self.repo:
            return
        probe_parent = Path(tempfile.mkdtemp(prefix="singular-doctor-worktree-"))
        probe = probe_parent / "checkout"
        result = command(
            ["git", "-C", str(self.repo), "worktree", "add", "--detach", str(probe), "HEAD"],
            timeout=20,
        )
        cleanup_error = ""
        expected = command(["git", "-C", str(self.repo), "rev-parse", "HEAD"]).stdout.strip()
        actual = ""
        if result.returncode == 0:
            actual = command(["git", "-C", str(probe), "rev-parse", "HEAD"]).stdout.strip()
            cleanup = command(
                ["git", "-C", str(self.repo), "worktree", "remove", "--force", str(probe)],
                timeout=20,
            )
            if cleanup.returncode != 0:
                cleanup_error = first_line(cleanup.stderr or cleanup.stdout)
        shutil.rmtree(probe_parent, ignore_errors=True)
        if result.returncode == 0 and actual == expected and not cleanup_error:
            self.add(
                "git.disposable-worktree",
                "pass",
                "disposable worktree creation and cleanup succeeded",
                required_for=("worker-runs", "audit-runs"),
                details={"head": expected},
            )
        else:
            detail = cleanup_error or first_line(result.stderr or result.stdout)
            self.add(
                "git.disposable-worktree",
                "fail",
                f"disposable worktree probe failed: {detail or 'HEAD mismatch'}",
                required_for=("worker-runs", "audit-runs"),
                remediation="Repair Git worktree metadata and verify the repository has a HEAD commit.",
            )

    def mcp_names(self) -> set[str]:
        names: set[str] = set()
        if self.repo:
            path = self.repo / ".mcp.json"
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                servers = data.get("mcpServers", {})
                if isinstance(servers, dict):
                    names.update(map(str, servers))
            except (OSError, json.JSONDecodeError):
                pass
        home = Path(self.runtime_env.get("HOME", str(Path.home())))
        try:
            data = json.loads((home / ".claude.json").read_text(encoding="utf-8"))
            servers = data.get("mcpServers", {})
            if isinstance(servers, dict):
                names.update(map(str, servers))
        except (OSError, json.JSONDecodeError):
            pass
        try:
            text = (home / ".codex/config.toml").read_text(encoding="utf-8")
            names.update(
                re.findall(r"^\[mcp_servers\.([^\]]+)\]", text, flags=re.MULTILINE)
            )
        except OSError:
            pass
        return names

    def plugin_names(self) -> set[str]:
        names: set[str] = set()
        roots = [
            self.engine / "plugin",
            Path(self.runtime_env.get("HOME", str(Path.home()))) / ".codex/plugins",
        ]
        for root in roots:
            try:
                names.update(path.name for path in root.iterdir() if path.is_dir())
            except OSError:
                pass
        return names

    def capability_profiles(self) -> None:
        if self.blocked("capability.profiles"):
            return
        profiles = self.config.get("capabilityProfiles")
        role_profiles = self.config.get("roleProfiles")
        registry = self.config.get("capabilities", {})
        if profiles is None and role_profiles is None:
            self.add(
                "capability.profiles",
                "pass",
                (
                    "capability profiles: built-in local-only defaults "
                    "(external MCP/plugins are lazy and disabled)"
                ),
                required_for=("provider-runs",),
                details={
                    "startup": "lazy",
                    "required": ["filesystem", "git", "schemas", "runner-contract"],
                    "optional": [],
                },
            )
            return
        shape_errors: list[str] = []
        if not isinstance(profiles, dict) or not profiles:
            shape_errors.append("capabilityProfiles must be a non-empty object")
            profiles = {}
        if not isinstance(role_profiles, dict) or not role_profiles:
            shape_errors.append("roleProfiles must be a non-empty object")
            role_profiles = {}
        if not isinstance(registry, dict):
            shape_errors.append("capabilities must be an object")
            registry = {}

        schema_match = re.fullmatch(
            r"v([0-9]+)", str(self.config.get("schemaVersion", ""))
        )
        strict_default = bool(
            schema_match and int(schema_match.group(1)) >= 2
        )
        provider_keys = set(PROVIDERS) | {"default"}
        parsed_profiles: dict[str, dict[str, Any]] = {}

        def valid_argv(value: Any, label: str) -> list[str] | None:
            if not isinstance(value, list) or len(value) > 64:
                shape_errors.append(
                    f"{label} must be an argv array with at most 64 entries"
                )
                return None
            for argument in value:
                if (
                    not isinstance(argument, str)
                    or not argument
                    or len(argument) > 4096
                    or argument != argument.strip()
                    or any(ord(char) < 32 or ord(char) == 127 for char in argument)
                ):
                    shape_errors.append(
                        f"{label} entries must be bounded, non-empty strings "
                        "without control or edge whitespace"
                    )
                    return None
            return value

        def provider_argv_map(value: Any, label: str) -> dict[str, list[str]]:
            if isinstance(value, list):
                parsed = valid_argv(value, label)
                return {"default": parsed} if parsed is not None else {}
            if not isinstance(value, dict):
                shape_errors.append(
                    f"{label} must be an argv array or provider-to-argv object"
                )
                return {}
            unknown = sorted(set(value) - provider_keys)
            if unknown:
                shape_errors.append(
                    f"{label} has unsupported providers: "
                    f"{', '.join(map(str, unknown))}"
                )
            validated: dict[str, list[str]] = {}
            for provider_name, argv in value.items():
                if provider_name not in provider_keys:
                    continue
                parsed = valid_argv(argv, f"{label}.{provider_name}")
                if parsed is not None:
                    validated[provider_name] = parsed
            return validated

        def selected_argv(
            values: dict[str, list[str]], provider_name: str | None
        ) -> list[str]:
            if not provider_name:
                return []
            return list(values.get(provider_name, values.get("default", [])))

        for profile_name, profile in profiles.items():
            if (
                not isinstance(profile_name, str)
                or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", profile_name)
                is None
            ):
                shape_errors.append(
                    "capabilityProfiles keys must be safe non-empty profile names"
                )
                continue
            if not isinstance(profile, dict):
                shape_errors.append(f"profile {profile_name} must be an object")
                continue
            if profile.get("startup", "lazy") != "lazy":
                shape_errors.append(f"profile {profile_name} startup must be lazy")
            strict = profile.get("strict", strict_default)
            if not isinstance(strict, bool):
                shape_errors.append(f"profile {profile_name}.strict must be boolean")
                strict = strict_default
            required = profile.get("required", [])
            optional = profile.get("optional", [])
            if not isinstance(required, list) or not all(
                isinstance(item, str) and item for item in required
            ):
                shape_errors.append(f"profile {profile_name}.required must be strings")
                required = []
            if not isinstance(optional, list) or not all(
                isinstance(item, str) and item for item in optional
            ):
                shape_errors.append(f"profile {profile_name}.optional must be strings")
                optional = []
            required_values = list(dict.fromkeys(required))
            optional_values = [
                item for item in dict.fromkeys(optional) if item not in required_values
            ]
            provider_args_map = provider_argv_map(
                profile.get("providerArgs", []),
                f"profile {profile_name}.providerArgs",
            )
            capability_args_raw = profile.get("capabilityArgs", {})
            capability_args_maps: dict[str, dict[str, list[str]]] = {}
            if not isinstance(capability_args_raw, dict):
                shape_errors.append(
                    f"profile {profile_name}.capabilityArgs must map capability "
                    "IDs to provider argv"
                )
                capability_args_raw = {}
            declared_capabilities = set(required_values) | set(optional_values)
            undeclared = sorted(set(capability_args_raw) - declared_capabilities)
            if undeclared:
                shape_errors.append(
                    f"profile {profile_name}.capabilityArgs contains undeclared "
                    f"capabilities: {', '.join(map(str, undeclared))}"
                )
            for capability, argv_config in capability_args_raw.items():
                if capability not in declared_capabilities:
                    continue
                capability_args_maps[capability] = provider_argv_map(
                    argv_config,
                    f"profile {profile_name}.capabilityArgs.{capability}",
                )

            if strict:
                for provider_name in ("codex", "claude", "gemini", "opencode"):
                    combined = selected_argv(provider_args_map, provider_name)
                    for capability in required_values + optional_values:
                        for argument in selected_argv(
                            capability_args_maps.get(capability, {}), provider_name
                        ):
                            if argument not in combined:
                                combined.append(argument)
                    violation = strict_provider_arg_violation(
                        provider_name, combined
                    )
                    if violation:
                        shape_errors.append(
                            f"profile {profile_name}: {violation}"
                        )
            selected_capability_args = {
                capability: selected_argv(values, self.provider)
                for capability, values in capability_args_maps.items()
            }
            parsed_profiles[profile_name] = {
                "strict": strict,
                "required": required_values,
                "optional": optional_values,
                "providerArgs": selected_argv(provider_args_map, self.provider),
                "capabilityArgs": selected_capability_args,
            }

        active: dict[str, dict[str, set[str]]] = {}
        strict_unactivated_optional: dict[str, set[str]] = {}
        active_profiles: set[str] = set()
        for role, profile_name in role_profiles.items():
            if (
                not isinstance(role, str)
                or not role
                or not isinstance(profile_name, str)
                or not profile_name
            ):
                shape_errors.append("roleProfiles entries must map non-empty strings")
                continue
            profile = parsed_profiles.get(profile_name)
            if profile is None:
                shape_errors.append(f"role {role} references missing profile {profile_name}")
                continue
            active_profiles.add(profile_name)
            required = profile["required"]
            optional = profile["optional"]
            for level, values in (("required", required), ("optional", optional)):
                for capability in values:
                    target = active.setdefault(
                        capability, {"required": set(), "optional": set()}
                    )
                    target[level].add(role)
                    descriptor = registry.get(capability)
                    activation_required = capability == "skills" or (
                        capability.startswith(("mcp:", "plugin:"))
                        or (
                            isinstance(descriptor, dict)
                            and descriptor.get("type") in {"mcp", "plugin"}
                        )
                    )
                    if (
                        level == "optional"
                        and profile["strict"]
                        and activation_required
                        and not profile["capabilityArgs"].get(capability)
                    ):
                        strict_unactivated_optional.setdefault(capability, set()).add(
                            role
                        )
        if self.provider and self.provider not in STRICT_ISOLATION_PROVIDERS:
            for profile_name in sorted(active_profiles):
                profile = parsed_profiles[profile_name]
                if profile["strict"] and not profile["providerArgs"]:
                    shape_errors.append(
                        f"profile {profile_name} is strict, but {self.provider} has "
                        "no proven built-in isolation mode; configure a validated "
                        f"providerArgs.{self.provider} argv array or set strict:false"
                    )
        for profile_name in sorted(active_profiles):
            profile = parsed_profiles[profile_name]
            if not profile["strict"]:
                continue
            for capability in profile["required"]:
                descriptor = registry.get(capability)
                external = capability == "skills" or (
                    capability.startswith(("mcp:", "plugin:"))
                    or (
                        isinstance(descriptor, dict)
                        and descriptor.get("type") in {"mcp", "plugin"}
                    )
                )
                if external and not profile["capabilityArgs"].get(capability):
                    shape_errors.append(
                        f"profile {profile_name} requires external capability "
                        f"{capability}, but strict isolation requires "
                        f"capabilityArgs.{capability}"
                    )
        if shape_errors:
            self.add(
                "capability.profiles",
                "fail",
                "capability profile configuration is invalid: "
                + "; ".join(shape_errors[:8]),
                required_for=("provider-runs",),
                remediation=(
                    "Define lazy capabilityProfiles and map each runner role through "
                    "roleProfiles."
                ),
            )
            return
        self.add(
            "capability.profiles",
            "pass",
            f"capability profiles valid ({len(profiles)} profiles, {len(role_profiles)} roles)",
            required_for=tuple(map(str, role_profiles)),
            details={
                "startup": "lazy",
                "strictDefault": strict_default,
                "strictProfiles": sorted(
                    name
                    for name, profile in parsed_profiles.items()
                    if profile["strict"]
                ),
                "activatedCapabilities": sorted(
                    {
                        capability
                        for profile in parsed_profiles.values()
                        for capability, argv in profile["capabilityArgs"].items()
                        if argv
                    }
                ),
            },
        )
        mcp = self.mcp_names()
        plugins = self.plugin_names()
        for capability, consumers in sorted(active.items()):
            required_roles = consumers["required"]
            optional_roles = consumers["optional"] - required_roles
            unactivated_roles = strict_unactivated_optional.get(capability, set())
            availability_optional_roles = optional_roles - unactivated_roles
            required = bool(required_roles)
            available, reason = self.capability_available(
                capability, registry, mcp, plugins
            )
            if available:
                status = "pass"
                roles = required_roles | optional_roles
                message = f"capability available: {capability}"
            elif required:
                status = "fail"
                roles = required_roles
                message = f"required capability unavailable: {capability} ({reason})"
            elif availability_optional_roles:
                status = "warn"
                roles = availability_optional_roles
                message = f"optional capability unavailable: {capability} ({reason})"
            else:
                continue
            self.add(
                f"capability.{safe_slug(capability)}",
                status,
                message,
                required_for=roles,
                remediation=(
                    ""
                    if available
                    else "Install/configure the capability or remove it from the profile."
                ),
                dedupe_key=f"capability:{capability}",
            )
        for capability, roles in sorted(strict_unactivated_optional.items()):
            self.add(
                f"capability.activation.{safe_slug(capability)}",
                "warn",
                (
                    f"optional capability not activated by strict isolation: "
                    f"{capability} (capabilityArgs.{capability} absent)"
                ),
                required_for=roles,
                remediation=(
                    f"Add validated capabilityArgs.{capability} argv bound to this "
                    "exact capability only if it is needed."
                ),
                dedupe_key=f"capability-activation:{capability}",
            )

    def capability_available(
        self,
        capability: str,
        registry: dict[str, Any],
        mcp: set[str],
        plugins: set[str],
    ) -> tuple[bool, str]:
        if capability in BUILTIN_CAPABILITIES:
            values = {
                "filesystem": bool(self.repo and self.repo.is_dir()),
                "git": shutil.which("git") is not None,
                "schemas": (self.engine / "schemas").is_dir(),
                "skills": (self.engine / "plugin/skills").is_dir()
                or bool(self.repo and (self.repo / ".agents/skills").is_dir()),
                "runner-contract": self.runner_contract_ok,
                "provider-executable": self.provider_bin is not None,
            }
            return values[capability], "built-in preflight failed"
        if capability.startswith("mcp:"):
            name = capability.split(":", 1)[1]
            return name in mcp, f"MCP server {name} is not configured"
        if capability.startswith("plugin:"):
            name = capability.split(":", 1)[1]
            return name in plugins, f"plugin {name} is not installed"
        if capability.startswith("executable:"):
            name = capability.split(":", 1)[1]
            return shutil.which(name, path=self.runtime_env.get("PATH")) is not None, (
                f"{name} is not on PATH"
            )
        if capability.startswith("file:"):
            raw = capability.split(":", 1)[1]
            path = Path(raw)
            if not path.is_absolute() and self.repo:
                path = self.repo / path
            return path.is_file(), f"{path} is missing"
        descriptor = registry.get(capability)
        if not isinstance(descriptor, dict):
            return False, "no capability descriptor"
        kind = descriptor.get("type")
        value = descriptor.get("value") or descriptor.get("name")
        if kind == "builtin":
            return bool(descriptor.get("available", True)), "disabled"
        if kind == "executable" and isinstance(value, str):
            return shutil.which(value, path=self.runtime_env.get("PATH")) is not None, (
                f"{value} is not on PATH"
            )
        if kind == "file" and isinstance(value, str):
            path = Path(value)
            if not path.is_absolute() and self.repo:
                path = self.repo / path
            return path.is_file(), f"{path} is missing"
        if kind == "mcp" and isinstance(value, str):
            return value in mcp, f"MCP server {value} is not configured"
        if kind == "plugin" and isinstance(value, str):
            return value in plugins, f"plugin {value} is not installed"
        if kind == "environment" and isinstance(value, str):
            return bool(self.runtime_env.get(value)), f"environment variable {value} is absent"
        return False, "unsupported capability descriptor"

    def bootstrap_check(self) -> None:
        if self.blocked("bootstrap.dry-run"):
            return
        if not self.repo:
            return
        config: Any = self.config.get("bootstrap")
        if config is None:
            raw = self.runtime_env.get("SINGULAR_BOOTSTRAP_JSON", "")
            if raw:
                try:
                    config = json.loads(raw)
                except json.JSONDecodeError as exc:
                    self.add(
                        "bootstrap.dry-run",
                        "fail",
                        f"bootstrap configuration is invalid JSON: {exc}",
                        required_for=("worker-runs",),
                        remediation="Repair SINGULAR_BOOTSTRAP_JSON.",
                    )
                    return
        if config is None:
            self.add(
                "bootstrap.dry-run",
                "skip",
                "worktree bootstrap is not configured",
                required_for=("worker-runs",),
            )
            return
        if not isinstance(config, dict):
            self.add(
                "bootstrap.dry-run",
                "fail",
                "bootstrap configuration must be an object",
                required_for=("worker-runs",),
                remediation="Repair the bootstrap section in singular.config.json.",
            )
            return
        # `required: true` with nothing to run is a no-op that reads like a
        # guarantee. The dry-run below validates it happily, so it reported as
        # passing while bootstrapping nothing — and templates/singular.config.json
        # shipped exactly this block, so every `singular init` inherited it.
        declared_commands = config.get("commands")
        has_commands = bool(config.get("command")) or (
            isinstance(declared_commands, list) and len(declared_commands) > 0
        )
        if config.get("required") and not has_commands:
            self.add(
                "bootstrap.required-no-op",
                "warn",
                "bootstrap declares required: true but defines no commands, so it "
                "guarantees nothing",
                required_for=("worker-runs",),
                remediation=(
                    "Add the commands that must succeed before a worker runs "
                    "(for example npm ci), or drop required: true."
                ),
            )

        helper = self.engine / "engine/bootstrap-worktree.sh"
        env = dict(self.runtime_env)
        env["SINGULAR_ROOT"] = str(self.repo)
        env["SINGULAR_ENGINE_HOME"] = str(self.engine)
        env["SINGULAR_BOOTSTRAP_JSON"] = compact(config)
        result = command(
            [str(helper), "--worktree", str(self.repo), "--dry-run"],
            cwd=self.repo,
            env=env,
            timeout=20,
        )
        if result.returncode == 0:
            try:
                record = json.loads(result.stdout)
            except json.JSONDecodeError:
                record = {}
            self.add(
                "bootstrap.dry-run",
                "pass",
                "bootstrap configuration and lockfiles validate in dry-run mode",
                required_for=("worker-runs",),
                details={
                    "lockfiles": record.get("lockfiles", []),
                    "sharedLinks": record.get("sharedLinks", 0),
                    "required": record.get("required", True),
                },
            )
        else:
            self.add(
                "bootstrap.dry-run",
                "fail",
                f"bootstrap dry-run failed: {first_line(result.stderr or result.stdout)}",
                required_for=("worker-runs",),
                remediation="Repair lockfiles, shared-store allowlists, or bootstrap paths.",
            )

    def readonly_guard_check(self) -> None:
        """Report worktrees a read-only run left changed and nobody put back.

        A guard journal survives its run on purpose: SIGKILL executes no
        handler, so the journal is the only remaining record of what the tree
        looked like before. `singular reconcile` sweeps the ones whose owner is
        gone. One that is still here with a dead owner means a repository is
        sitting in a state a read-only run left it in.
        """
        if self.blocked("readonly-guard.pending"):
            return
        if not self.repo:
            return
        base = self.repo / ".singular-state" / "readonly-guard"
        raw = self.runtime_env.get("SINGULAR_STATE_DIR", "")
        if raw:
            base = Path(raw) / "readonly-guard"
        if not base.is_dir():
            self.add(
                "readonly-guard.pending",
                "pass",
                "no read-only guard journals are pending",
            )
            return
        pending: list[str] = []
        in_flight = 0
        for entry in sorted(base.iterdir()):
            journal = entry / "journal.json"
            if not journal.is_file():
                continue
            try:
                owner = int(json.loads(journal.read_text(encoding="utf-8")).get("ownerPid") or 0)
            except (OSError, ValueError, json.JSONDecodeError):
                owner = 0
            if owner > 0:
                try:
                    os.kill(owner, 0)
                except ProcessLookupError:
                    pending.append(entry.name)
                    continue
                except OSError:
                    in_flight += 1
                    continue
                else:
                    in_flight += 1
                    continue
            pending.append(entry.name)
        if pending:
            self.add(
                "readonly-guard.pending",
                "warn",
                f"{len(pending)} read-only guard journal(s) were never applied; a "
                "worktree may still hold changes a read-only run made",
                remediation="Run `singular reconcile` to apply them.",
                details={"journals": pending[:20], "inFlight": in_flight},
            )
        else:
            self.add(
                "readonly-guard.pending",
                "pass",
                "no read-only guard journals are pending"
                + (f" ({in_flight} run(s) in flight)" if in_flight else ""),
            )

    def resource_check(self) -> None:
        if self.blocked("resources.adaptive-disk"):
            return
        if not self.repo:
            return
        helper = self.engine / "engine/resource-plan.sh"
        env = dict(self.runtime_env)
        env["SINGULAR_ROOT"] = str(self.repo)
        resources = self.config.get("resources", {})
        if isinstance(resources, dict):
            mappings = {
                "diskReserveBytes": "SINGULAR_DISK_RESERVE_BYTES",
                "estimatedWorktreeBytes": "SINGULAR_ESTIMATED_WORKTREE_BYTES",
                # engine/lib.sh maps resources.maxConcurrent to
                # SINGULAR_MAX_CONCURRENT, and that is what reconcile.sh reads for
                # its dispatch cap. Mapping it to the L1 planner cap here made
                # doctor evaluate a different slot count than the loop actually
                # uses — L1 planners create no worktrees, so they never consume
                # the worktree budget this check is about.
                "maxConcurrent": "SINGULAR_MAX_CONCURRENT",
            }
            for source, target in mappings.items():
                if source in resources and target not in os.environ:
                    env[target] = str(resources[source])
        result = command([str(helper), "--json"], cwd=self.repo, env=env, timeout=20)
        if result.returncode != 0:
            self.add(
                "resources.adaptive-disk",
                "fail",
                f"adaptive disk calculation failed: {first_line(result.stderr or result.stdout)}",
                required_for=("worker-runs",),
                remediation="Correct disk reserve, estimate, and concurrency settings.",
            )
            return
        try:
            record = json.loads(result.stdout)
            effective = int(record["effectiveSlots"])
            configured = int(record["configuredSlots"])
            if effective == 0:
                status = "fail"
            elif effective < configured:
                status = "warn"
            else:
                status = "pass"
            self.add(
                "resources.adaptive-disk",
                status,
                (
                    f"adaptive disk capacity: {effective}/{configured} worker slots "
                    f"({record.get('reason', 'unknown')})"
                ),
                required_for=("worker-runs",),
                remediation=(
                    ""
                    if status == "pass"
                    else "Free disk, lower concurrency, or tune the documented reserve/estimate."
                ),
                details=record,
            )
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
            self.add(
                "resources.adaptive-disk",
                "fail",
                f"adaptive disk calculation returned invalid data: {exc}",
                required_for=("worker-runs",),
                remediation="Repair engine/resource-plan.sh.",
            )

    def governance_checks(self) -> None:
        if self.blocked("governance.unbound-waivers"):
            return
        compatibility = self.config.get("legacyCompatibility", {})
        if compatibility is None:
            compatibility = {}
        if not isinstance(compatibility, dict):
            self.add(
                "governance.unbound-waivers",
                "fail",
                "legacyCompatibility must be an object",
                required_for=("schema-v2-runs",),
                remediation="Use legacyCompatibility.unboundWaivers as a boolean.",
            )
            return
        selected = compatibility.get("unboundWaivers", False)
        if not isinstance(selected, bool):
            self.add(
                "governance.unbound-waivers",
                "fail",
                "legacyCompatibility.unboundWaivers must be a boolean",
                required_for=("schema-v2-runs",),
                remediation="Set it to false, or explicitly true only during migration.",
            )
        elif selected:
            self.add(
                "governance.unbound-waivers",
                "warn",
                "legacy artifact-unbound accept-waivers are explicitly enabled",
                required_for=("legacy-compatibility",),
                remediation="Migrate approvals to exact-artifact human gates, then disable the switch.",
            )
        else:
            self.add(
                "governance.unbound-waivers",
                "pass",
                "artifact-unbound accept-waivers are disabled",
                required_for=("schema-v2-runs",),
            )

    # Governance posture (P13) + dependent-flag diagnosis (P12).
    #
    # An operator running an unattended engine should be able to see, at a glance,
    # WHICH guarantees are live -- not infer them from a table of knobs. Before
    # 0.20.0 the shipped defaults ran the least-governed configuration and the
    # README's "Recommended" column was the only thing pointing anywhere else, so
    # "am I governed?" had no answer short of reading the source.
    #
    # Reads the EFFECTIVE environment captured by effective_environment(), which
    # is what the engine itself sees after singular.config.json env{} and
    # config.local.sh have been applied -- not this process's environment.
    GOVERNANCE_POSTURE = (
        ("SINGULAR_CTX_ROUTING", "1", "resume routing: lease + window + diff gates"),
        ("SINGULAR_PLANNER_SESSION", "1", "planner session persistence + resume gates"),
        ("SINGULAR_CTX_PACKET", "1", "planner context packets into worker/audit prompts"),
        ("SINGULAR_PLAN_CRITIQUE", "1", "skeptic critique of plan batches before import"),
    )

    def governance_posture(self) -> None:
        if self.blocked("governance.posture", "governance.flag-dependencies"):
            return
        if not self.runtime_env:
            return

        live, off = [], []
        for key, want, label in self.GOVERNANCE_POSTURE:
            if self.runtime_env.get(key, "") == want:
                live.append(label)
            else:
                off.append((key, label))

        detail = {
            "live": live,
            "disabled": [k for k, _ in off],
            # The independence pin is deliberately absent from the knob list: it
            # binds above the routing flag and has no knob at all.
            "structural": ["independence pin: audits always run fresh (no knob)"],
        }
        if not off:
            self.add(
                "governance.posture",
                "pass",
                f"governed posture: all {len(live)} context-governance gates are live",
                required_for=("governed-runs",),
                details=detail,
            )
        else:
            disabled = ", ".join(k for k, _ in off)
            self.add(
                "governance.posture",
                "warn",
                f"reduced governance posture: {len(off)} of "
                f"{len(self.GOVERNANCE_POSTURE)} gates disabled ({disabled})",
                required_for=("governed-runs",),
                remediation=(
                    "These ship enabled. Something set them to 0 -- check "
                    "singular.config.json env{} and .singular-state/config.local.sh. "
                    "Remove the override to restore the governed default."
                ),
                details=detail,
            )

        # P12: a dependent feature enabled without the feature it depends on is a
        # silent no-op. Say so rather than degrading quietly.
        rehydrate_on = self.runtime_env.get("SINGULAR_REHYDRATE", "0") == "1"
        graph_on = self.runtime_env.get("SINGULAR_CTX_GRAPH", "0") == "1"
        subgraph_on = self.runtime_env.get("SINGULAR_CTX_SUBGRAPH_REHYDRATE", "0") == "1"
        unmet = []
        if subgraph_on and not graph_on:
            unmet.append("SINGULAR_CTX_SUBGRAPH_REHYDRATE needs SINGULAR_CTX_GRAPH=1")
        if subgraph_on and not rehydrate_on:
            unmet.append("SINGULAR_CTX_SUBGRAPH_REHYDRATE needs SINGULAR_REHYDRATE=1")
        if unmet:
            self.add(
                "governance.flag-dependencies",
                "warn",
                "; ".join(unmet),
                required_for=("governed-runs",),
                remediation=(
                    "Enable the dependency or unset the dependent flag; as "
                    "configured the dependent feature silently does nothing."
                ),
                details={"unmet": unmet},
            )
        else:
            self.add(
                "governance.flag-dependencies",
                "pass",
                "every enabled context feature has its dependencies satisfied",
                required_for=("governed-runs",),
            )

    def _dag_frontier_probe(self):
        """Run `dag.sh next-areas` once; both DAG checks read the same result.

        Returns ("absent", None) when there is no DAG to evaluate, else
        ("ran", CompletedProcess).
        """
        cached = getattr(self, "_dag_probe_cache", None)
        if cached is not None:
            return cached
        if not self.repo or not (self.repo / "docs/orchestration/dag.v0.json").is_file():
            cached = ("absent", None)
        else:
            cached = ("ran", command(
                [str(self.bash), str(self.engine / "engine/dag.sh"), "next-areas"],
                cwd=self.repo,
                env=self.runtime_env,
                timeout=20,
            ))
        self._dag_probe_cache = cached
        return cached

    def dag_evaluation(self) -> None:
        """An unevaluable DAG is indistinguishable from an idle one in the loop.

        dag.sh emits a precise diagnostic and exits non-zero; every caller in the
        loop discarded it and reported an empty frontier, so a single malformed
        gate file presented as "no work to do". The loop now says so (see
        singular_dag_next_areas_json), and doctor is where an operator goes to ask
        why nothing is happening -- so it must answer that question directly.
        """
        if self.blocked("dag.evaluation"):
            return
        state, result = self._dag_frontier_probe()
        if state == "absent":
            self.add(
                "dag.evaluation",
                "skip",
                "no docs/orchestration/dag.v0.json to evaluate",
            )
            return
        if result.returncode != 0:
            lines = [
                line for line in
                ((result.stderr or "") + "\n" + (result.stdout or "")).splitlines()
                if line.strip()
            ]
            detail = lines[-1].strip() if lines else (
                f"dag.sh next-areas exited {result.returncode} without a diagnostic"
            )
            self.add(
                "dag.evaluation",
                "fail",
                f"the DAG frontier cannot be evaluated: {detail}",
                remediation=(
                    "Run `singular next-areas` to see the full diagnostic and fix the "
                    "offending node or gate file. Until then the loop reports an empty "
                    "frontier, which looks identical to having no ready work."
                ),
                details={"exitCode": result.returncode, "diagnostic": lines[-8:]},
            )
            return
        self.add("dag.evaluation", "pass", "the DAG frontier evaluates cleanly")

    def graph_promotability(self) -> None:
        """Can this graph advance without a human promoting every node?

        Two individually defensible defaults combine into a dead graph. The
        shipped promoter promotes only nodes in its own built-in registry, whose
        ids come from one specific consumer project; and `authority` defaults to
        `operator`, i.e. manual promotion, for evaluation nodes. So a consumer
        who writes their own DAG gets a graph that stalls after layer 0 with
        `promotion: no promotable frontier gates` as the only symptom -- which is
        also what a merely not-yet-ready frontier prints. That cost a field
        operator a full day before they wrote their own promoter.

        Both remedies already exist and neither is discoverable: the `promoter`
        config key, and `authority: agent-review-allowed`. This check names them.
        """
        if self.blocked("graph.promotability"):
            return
        if not self.repo:
            return
        dag_path = self.repo / "docs/orchestration/dag.v0.json"
        if not dag_path.is_file():
            self.add("graph.promotability", "skip", "no DAG to check for promotability")
            return
        try:
            nodes = json.loads(dag_path.read_text(encoding="utf-8")).get("nodes", [])
        except (OSError, json.JSONDecodeError, AttributeError) as exc:
            self.add(
                "graph.promotability",
                "warn",
                f"could not read the DAG to check promotability: {exc}",
                remediation="Fix docs/orchestration/dag.v0.json, then re-run doctor.",
            )
            return
        if not isinstance(nodes, list) or not nodes:
            self.add("graph.promotability", "skip", "the DAG declares no nodes")
            return

        promoter = self._resolve_promoter()
        shipped = self.engine / "singular-ext/promote-gate.sh"
        if promoter is not None and promoter.resolve() != shipped.resolve():
            # NEVER probe a promoter we did not ship. A consumer promoter takes a
            # bare NODE argument (tools/promote-gate.sh does), so `--registers X`
            # could be read as a node id and make it ACT -- a diagnostic must not
            # promote anything. An unintrospectable promoter is reported as such.
            self.add(
                "graph.promotability",
                "skip",
                f"a project promoter is configured ({promoter}); its registry is not "
                "introspectable, so promotability is not checked",
                details={"promoter": str(promoter)},
            )
            return
        unregistered = []
        operator_only = []
        for node in nodes:
            if not isinstance(node, dict):
                continue
            node_id = str(node.get("id") or "")
            if not node_id:
                continue
            if node.get("kind") == "evaluation":
                # Evaluation nodes are an authority decision, not a regression
                # run: the registry never applies to them.
                if node.get("authority", "operator") != "agent-review-allowed":
                    operator_only.append(node_id)
                continue
            if promoter is None or not self._promoter_registers(promoter, node_id):
                unregistered.append(node_id)

        if not unregistered and not operator_only:
            self.add(
                "graph.promotability",
                "pass",
                "every DAG node has a promoter or agent-review authority",
            )
            return

        parts = []
        if unregistered:
            parts.append(f"{len(unregistered)} node(s) have no registered promoter")
        if operator_only:
            parts.append(
                f"{len(operator_only)} evaluation node(s) default to operator authority"
            )
        self.add(
            "graph.promotability",
            "warn",
            "; ".join(parts) + " — this graph cannot advance unattended",
            remediation=(
                'Point "promoter" in singular.config.json at a promoter that registers '
                "these nodes (a bare name resolves to <engine>/singular-ext/<name>.sh; "
                "tools/promote-gate.sh is a worked example), and/or set "
                '"authority": "agent-review-allowed" on evaluation nodes you want '
                "promoted from a gate-review.v0 record instead of by hand."
            ),
            details={
                "promoter": str(promoter) if promoter else None,
                "unregisteredNodes": unregistered[:20],
                "operatorOnlyEvaluationNodes": operator_only[:20],
            },
        )

    def _resolve_promoter(self):
        """The promoter the loop would actually use, env over config over default."""
        configured = os.environ.get("SINGULAR_PROMOTER") or self.config.get("promoter")
        if not configured:
            return self.engine / "singular-ext/promote-gate.sh"
        candidate = Path(str(configured))
        if "/" not in str(configured):
            candidate = self.engine / "singular-ext" / f"{configured}.sh"
        elif not candidate.is_absolute() and self.repo:
            candidate = self.repo / candidate
        return candidate if candidate.is_file() else None

    def _promoter_registers(self, promoter: Path, node_id: str) -> bool:
        """Ask the promoter itself, rather than reimplementing its registry.

        A promoter that does not support the query is treated as registering
        nothing, which is the honest reading: the loop would skip the node.
        """
        result = command(
            [str(self.bash), str(promoter), "--registers", node_id],
            cwd=self.repo,
            env=self.runtime_env,
            timeout=20,
        )
        return result.returncode == 0

    def deployment_credentials(self) -> None:
        if self.blocked("deployment.credentials"):
            return
        if not self.repo:
            return
        state, result = self._dag_frontier_probe()
        if state == "absent":
            self.add(
                "deployment.credentials",
                "skip",
                "no deployment-capable node is ready",
                required_for=("deployment",),
            )
            return
        if result.returncode != 0:
            self.add(
                "deployment.credentials",
                "skip",
                "deployment credentials not checked because no DAG frontier is available",
                required_for=("deployment",),
            )
            return
        try:
            frontier = json.loads(result.stdout).get("frontier", [])
        except (json.JSONDecodeError, AttributeError):
            frontier = []
        deploy_nodes = [
            item
            for item in frontier
            if isinstance(item, dict)
            and any(
                str(item.get(key, "")).lower() in DEPLOY_KINDS
                or "deploy" in str(item.get(key, "")).lower()
                for key in ("kind", "layer", "stage")
            )
        ]
        if not deploy_nodes:
            self.add(
                "deployment.credentials",
                "skip",
                "no deployment-capable node is ready",
                required_for=("deployment",),
            )
            return
        declarations = self.config.get("deploymentCredentials", [])
        normalized: list[dict[str, Any]] = []
        if isinstance(declarations, dict):
            for ident, value in declarations.items():
                if isinstance(value, str):
                    normalized.append({"id": ident, "env": value})
                elif isinstance(value, dict):
                    normalized.append({"id": ident, **value})
        elif isinstance(declarations, list):
            normalized = [item for item in declarations if isinstance(item, dict)]
        ready_ids = {str(item.get("node")) for item in deploy_nodes}
        ready_traits = ready_ids | {
            str(item.get(key))
            for item in deploy_nodes
            for key in ("kind", "layer", "stage")
        }
        applicable = []
        malformed = []
        for item in normalized:
            ident = item.get("id")
            env_name = item.get("env")
            required_for = item.get("requiredFor", [])
            if not isinstance(ident, str) or not isinstance(env_name, str):
                malformed.append(str(ident or "?"))
                continue
            if required_for and (
                not isinstance(required_for, list)
                or not any(str(value) in ready_traits or value == "*" for value in required_for)
            ):
                continue
            applicable.append((ident, env_name))
        if malformed:
            self.add(
                "deployment.credentials",
                "fail",
                f"deployment credential declarations are malformed: {', '.join(malformed)}",
                required_for=ready_ids,
                remediation="Each declaration needs string id and env fields.",
            )
            return
        if not applicable:
            self.add(
                "deployment.credentials",
                "warn",
                "deployment-capable node is ready but no credential requirements are declared",
                required_for=ready_ids,
                remediation="Declare deploymentCredentials in singular.config.json.",
            )
            return
        missing = [ident for ident, env_name in applicable if not self.runtime_env.get(env_name)]
        if missing:
            self.add(
                "deployment.credentials",
                "fail",
                f"deployment credentials are missing: {', '.join(missing)}",
                required_for=ready_ids,
                remediation="Provide the declared credentials through the operator environment.",
                details={"missing": missing, "readyNodes": sorted(ready_ids)},
            )
        else:
            self.add(
                "deployment.credentials",
                "pass",
                f"deployment credentials available for: {', '.join(sorted(ready_ids))}",
                required_for=ready_ids,
                details={
                    "credentialIds": [ident for ident, _ in applicable],
                    "readyNodes": sorted(ready_ids),
                },
            )

    def run(self) -> int:
        # Order is the diagnosis. Host capability first (true regardless of any
        # repository), then which engine this repo asks for, then whether this
        # engine can read this repo at all. Only after that does anything load
        # or interpret a repository artifact -- so an incompatibility is stated
        # once, by the check that found it, instead of a dozen times by the
        # checks that tripped over it (PMGO-008).
        self.basic_checks()
        self.process_control_checks()
        self.load_config()
        self.pin_checks()
        self.schema_checks()
        self.effective_environment()
        self.brain_checks()
        self.config_source_conflict()
        self.host_hygiene_checks()
        self.repo_hygiene_checks()
        self.resolve_runner()
        self.check_runner_contract()
        self.resolve_provider_executable()
        self.provider_auth()
        self.maybe_repair_model_cache()
        self.model_checks()
        self.model_cache_compatibility()
        self.disposable_worktree()
        self.capability_profiles()
        self.bootstrap_check()
        self.readonly_guard_check()
        self.resource_check()
        self.governance_checks()
        self.governance_posture()
        self.dag_evaluation()
        self.graph_promotability()
        self.deployment_credentials()
        failed = sum(item["status"] == "fail" for item in self.checks)
        warned = sum(item["status"] == "warn" for item in self.checks)
        passed = sum(item["status"] == "pass" for item in self.checks)
        skipped = sum(item["status"] == "skip" for item in self.checks)
        report = {
            "schema": CHECK_SCHEMA,
            "generatedAt": utc_now(),
            "ok": failed == 0,
            "repo": str(self.repo) if self.repo else None,
            "engine": str(self.engine),
            "effectiveConfiguration": self.effective_config_projection if self.repo else None,
            "lifecycle": self._lifecycle_report(),
            # Additive: the primary diagnosis every "skip" entry points back to,
            # or null. Readers that predate it see the same schema id and the
            # same checks[] they always did.
            "blocking": self.blocking,
            "summary": {
                "passed": passed,
                "warnings": warned,
                "failed": failed,
                "skipped": skipped,
            },
            "checks": self.checks,
        }
        if self.output_json:
            print(json.dumps(report, indent=2, sort_keys=False))
        else:
            print("singular doctor")
            markers = {"pass": "ok", "warn": "warn", "fail": "FAIL", "skip": "info"}
            for item in self.checks:
                print(f"  {markers[item['status']]:<5} {item['message']} [{item['id']}]")
                if item["status"] in {"warn", "fail"} and item["remediation"]:
                    print(f"        remediation: {item['remediation']}")
        return 1 if failed else 0

    def _lifecycle_report(self) -> dict[str, Any] | None:
        if not self.repo:
            return None
        effective = self.effective_config_projection or unavailable_effective_configuration(
            self.repo,
            os.environ,
            "effective configuration was not initialized",
            reason="configuration-not-initialized",
            resolution=self.config_resolution,
        )
        configuration = effective.get("configuration") or {}
        generation = effective.get("generation") or {}
        paths = effective.get("paths") if isinstance(effective.get("paths"), dict) else {}
        if configuration.get("status") == "error" or not paths.get("tasks") or not paths.get("state"):
            return unavailable_lifecycle(configuration, generation)
        return collect_lifecycle(Path(paths["tasks"]), Path(paths["state"]))


def main() -> int:
    parser = argparse.ArgumentParser(description="Structured singular operator preflight")
    parser.add_argument("--engine-home", required=True)
    parser.add_argument("--repo-root", default="")
    parser.add_argument("--bash", required=True)
    parser.add_argument("--bash-version", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--repair-model-cache", action="store_true")
    args = parser.parse_args()
    return Doctor(
        engine=Path(args.engine_home),
        repo=Path(args.repo_root) if args.repo_root else None,
        bash=Path(args.bash),
        bash_version=args.bash_version,
        output_json=args.json,
        repair_model_cache=args.repair_model_cache,
    ).run()


if __name__ == "__main__":
    raise SystemExit(main())
