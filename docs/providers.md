# Providers

Each shipped provider is one row in `engine/providers.json` and one
`engine/<name>-run.sh` adapter. `singular doctor` and the console read that
spec; adapters load their row at spawn so model defaults and update pins are
not copied into six scripts.

## Role runners

`singular.config.json` `roleRunners` (projected as `SINGULAR_ROLE_RUNNER_<ROLE>`)
selects the adapter for one role without changing the default `runner`:

```json
"roleRunners": {
  "implementer": "grok-run.sh",
  "auditor": "claude-run.sh"
}
```

A bare name is `engine/<name>`. A relative path is rooted at the consumer repo.
A configured runner that is missing or not executable is a hard stop (exit 78):
the engine will not silently fall back to another provider. Unset roles keep
using `SINGULAR_RUNNER` (default `codex-run.sh`).

The wired consumers are: implementer (l1-drive, owned separately), auditor
(paired audit), planner (`generate-tasks.sh`, plan-revise loop), critic (plan
critic / recritic / recheck), decider (`decide.sh`), supervisor (`supervise.sh`).

`singular doctor` / effective-configuration report each role's resolved runner,
provider, model, and reasoning effort under `roleRunners`.

## Read-only enforcement

Review-evidence delivery (`engine/evidence_delivery.py`) will not launch a known
adapter unless:

1. `command[0]` resolves to the engine's own adapter file (no copies, no
   wrappers, no `$PATH` aliases of the same basename), and
2. that provider's `readOnlyEnforcement` declares a mechanism for `any` or the
   current `sys.platform` (`darwin` / `linux`). If the value is an absolute
   path, that tool must exist and be executable.

Declared today:

| Provider   | `readOnlyEnforcement`                         | Notes |
| ---------- | --------------------------------------------- | ----- |
| codex      | `{"any": "provider-native-sandbox"}`          | Codex CLI OS sandbox. |
| claude     | `{"darwin": "/usr/bin/sandbox-exec"}`         | See below. |
| gemini, opencode, cursor, openrouter, grok | `{}` | Not admitted for review evidence. |

On admission the broker sets `SINGULAR_RUNNER_REQUIRE_OS_READONLY=1` so the
adapter fails closed (exit 78) if it cannot actually apply the OS sandbox.

### Claude on macOS

`claude-run.sh --level readonly` with `SINGULAR_CLAUDE_OS_SANDBOX=auto` (default)
or `1` prefixes the CLI with `sandbox-exec -f <profile>` when
`/usr/bin/sandbox-exec` is executable. The profile is
`(version 1) (allow default)` plus one `(deny file-write* (subpath "<dir>"))`
for the worktree, `$SINGULAR_ROOT`, and `$SINGULAR_STATE_DIR` (deduped,
`pwd -P`). Tool denials, the read-only system-prompt clause, and the post-run
restore guard stay in place.

`SINGULAR_CLAUDE_OS_SANDBOX=0` skips the OS sandbox (tests of the restore guard).
`SINGULAR_CLAUDE_SANDBOX_EXEC` overrides the tool path.

Non-readonly levels (`l0` / `l1` / `l2`) do not wrap the argv.

### Grok

Grok's `--sandbox read-only` is not used here (it refuses to start on hosts
where `docker.sock` is a symlink). Grok is an l2 implementer
(`--sandbox workspace --yolo`). It has no `readOnlyEnforcement` entry and is
rejected as a review-evidence adapter.
