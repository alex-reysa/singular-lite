#!/usr/bin/env bash
# Run the full engine regression suite. Exits non-zero if any test file fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
failed=""
gate_report_file="${SINGULAR_GATE_REPORT_FILE:-}"
# These are host-set by gate-check.sh after it resolves the canonical task
# record. Capture them before the general SINGULAR_* scrub below.
focused_task_contract="${SINGULAR_TEST_TASK_CONTRACT:-}"
focused_task_id="${SINGULAR_TEST_TASK_ID:-}"
focused_tasks_dir="${SINGULAR_TEST_TASKS_DIR:-}"
# Durable per-run artifact directory, set by `singular test`'s supervisor. Read
# here, before the env scrub below, for the same reason gate_report_file is:
# the scrub deletes every SINGULAR_* from the environment a few lines down.
# Unset (the default, and every direct `bash tests/run.sh` invocation) means no
# per-test logs and no progress file — the output below is then byte-identical
# to what this harness has always printed.
run_dir="${SINGULAR_TEST_RUN_DIR:-}"
# Parallelism (0.21.0). SINGULAR_TEST_JOBS=N runs up to N test files at once;
# unset or 1 keeps the historical serial loop byte-for-byte. Read before the
# scrub below for the same reason as the two variables above. Every test file
# already builds its own scratch repository under mktemp, so files are
# independent by construction; a file that is NOT (it binds a fixed port,
# mutates a shared cache, or inspects the checkout's own state) declares
# `# singular-test: serial` anywhere in its first 40 lines and is run after the
# parallel batch, one at a time. Output ordering is preserved: results are
# printed in discovery order regardless of completion order, so the PASS/FAIL
# lines, the summary, and progress.jsonl look exactly like a serial run.
jobs="${SINGULAR_TEST_JOBS:-1}"
[[ "$jobs" =~ ^[0-9]+$ && "$jobs" -ge 1 ]] || jobs=1

# Environmental preflights, before any test is discovered or run. Both fail
# once, loudly, instead of letting every dependent test fail separately.
#
#   1. Bash >= 4 (PMGO-007). The suite and the engine need it; the harness
#      itself used to invoke tests with a bare `bash`, so macOS Bash 3.2
#      produced cryptic per-test failures instead of one diagnosis. The shim
#      re-execs this script under a vetted interpreter when needed, which is
#      also why it is sourced before the env scrub below: that scrub unsets
#      SINGULAR_BASH_BOOTSTRAPPED, harmlessly, because every test is launched
#      with "$BASH" (already >= 4) and their own inline guards then no-op.
#   2. A real Git working tree with history and disposable worktrees
#      (PMGO-010). Most tests need all three; a `git archive` extraction has
#      none of them.
# shellcheck source=../engine/bash-guard.sh
. "$TESTS_DIR/../engine/bash-guard.sh" || exit 2
# shellcheck source=../engine/git-preflight.sh
. "$TESTS_DIR/../engine/git-preflight.sh" || exit 2
preflight_out=""
preflight_rc=0
host_required_check=""
preflight_out="$(singular_git_source_preflight "$TESTS_DIR/.." 2>&1)" || preflight_rc=$?
if [[ "$preflight_rc" -ne 0 ]]; then
  # A basename-filtered run is worker-focused. Its bodies may create their own
  # disposable repositories and should execute when only the checkout's shared
  # registry or temporary probe workspace is unavailable. The missing host
  # capability is explicit and remains unrun; an unfiltered canonical suite,
  # or missing source/history, still fails before discovery.
  if [[ "$#" -gt 0 && ( "$preflight_rc" -eq 2 || "$preflight_rc" -eq 3 ) ]]; then
    # Positional basenames are only a filter. They do not authorize execution
    # after a host capability check fails. Continue only when the host supplied
    # the canonical task contract, its strict policy selects this exact focused
    # invocation, and every selected body is present and worker-capable.
    focused_eligibility="$(python3 - "$focused_task_contract" "$focused_task_id" \
        "$focused_tasks_dir" "$TESTS_DIR" "$@" <<'PY' 2>&1
import pathlib
import re
import shlex
import sys

contract_raw, expected_task, tasks_raw, tests_raw, *requested = sys.argv[1:]
if not contract_raw or not expected_task or not tasks_raw:
    raise SystemExit("focused verification requires a host-resolved task contract")
contract = pathlib.Path(contract_raw).resolve()
tasks_dir = pathlib.Path(tasks_raw).resolve()
try:
    contract.relative_to(tasks_dir)
except ValueError:
    raise SystemExit("focused verification task contract is outside the canonical task directory")
if contract != tasks_dir / f"{expected_task}.md" or not contract.is_file():
    raise SystemExit("focused verification task contract is not canonical")
text = contract.read_text(encoding="utf-8")
title = re.search(r"^#\s+(TASK-[0-9]{4,})(?::|\s|$)", text, re.MULTILINE)
if not title or title.group(1) != expected_task:
    raise SystemExit("focused verification task identity mismatch")
policy = re.search(r"^Test policy:\s*`?([^`\n]+)`?\s*$", text, re.MULTILINE)
if not policy or policy.group(1).strip() != "strict_test_first":
    raise SystemExit("focused verification requires strict_test_first policy")
gate = re.search(r"^Gate command:\s*`([^`]+)`\s*$", text, re.MULTILINE)
if not gate:
    raise SystemExit("focused verification task contract has no gate command")
lexer = shlex.shlex(gate.group(1), posix=True, punctuation_chars=";&|")
lexer.whitespace_split = True
tokens = list(lexer)
authorized = []
for index, token in enumerate(tokens):
    if pathlib.PurePosixPath(token).name != "run.sh":
        continue
    selected = []
    for candidate in tokens[index + 1:]:
        if candidate in {";", "&&", "&", "||", "|"}:
            break
        if re.fullmatch(r"test-[A-Za-z0-9_.-]+\.sh", candidate):
            selected.append(candidate)
    if selected:
        authorized.append(selected)
if requested not in authorized:
    raise SystemExit("focused verification filter does not match the trusted gate command")
tests_dir = pathlib.Path(tests_raw).resolve()
for name in requested:
    candidates = [tests_dir / name, tests_dir.parent / "singular-ext" / "tests" / name]
    matches = [path for path in candidates if path.is_file()]
    if len(matches) != 1:
        raise SystemExit(f"focused verification body is unknown or ambiguous: {name}")
    header = "\n".join(matches[0].read_text(encoding="utf-8", errors="replace").splitlines()[:40])
    if re.search(r"^#\s*singular-test:\s*(?:host-only|host-required)(?:\s|=|$)", header, re.MULTILINE):
        raise SystemExit(f"focused verification body is host-only: {name}")
print("eligible")
PY
)" || {
      printf '%s\n' "$preflight_out" >&2
      printf 'tests/run.sh: %s\n' "$focused_eligibility" >&2
      exit 1
    }
    printf '%s\n' "$preflight_out" >&2
    case "$preflight_rc" in
      2) host_required_check="git-registry-write" ;;
      3) host_required_check="temporary-workspace" ;;
    esac
    echo "HOST_REQUIRED $host_required_check unrun" >&2
  else
    printf '%s\n' "$preflight_out" >&2
    exit 1
  fi
fi

# Hermetic guard: scrub inherited SINGULAR_* env. When this suite runs as the
# regression gate under l1-drive, the drive has already exported the consumer
# repo's config into the environment (SINGULAR_RUNNER, SINGULAR_AREA_PREFIX,
# SINGULAR_TARGET_BRANCH, ...) and lib.sh's ${VAR:-default} fallbacks keep the
# leaked values, so sandboxed tests see the consumer's config instead of
# pristine defaults (and a leaked SINGULAR_RUNNER replaces test runner stubs
# with a real CLI). Tests set every SINGULAR_* var they need internally.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v
# NOTE: the env scrub cannot scrub what lib.sh re-reads from DISK. A test that
# sources lib.sh with the CHECKOUT as its root also sources the operator's
# .singular-state/config.local.sh, whose exports land after the scrub — and an
# operator SINGULAR_MODULES there loads module overrides into the test shell
# at source time, where a later `unset SINGULAR_MODULES` cannot unload the
# already-defined functions. A global SINGULAR_LOCAL_CONFIG_FILE=/dev/null here
# is NOT the fix: setup/config tests legitimately author fixture local configs
# and rely on default path resolution. Tests that source lib.sh at the checkout
# root and assert GENERIC hook behavior must pin
# SINGULAR_LOCAL_CONFIG_FILE=/dev/null themselves (see
# test-storage-proof-redlog.sh and singular-ext/tests/*-selection.sh).

# Positional arguments are a basename filter: `bash tests/run.sh test-a.sh
# test-b.sh` runs only those two files. Discovery itself is untouched — the
# filter is applied to the same list, so singular-ext glob semantics still hold
# — and with no arguments (every existing caller) nothing is filtered at all.
# This is what makes `singular test --rerun-failures` possible without a second,
# divergent discovery path.
filter=" $* "

if [[ -n "$run_dir" ]]; then mkdir -p "$run_dir/logs"; fi

# Generic engine suite + the singular-ext (opt-in module) suite, if present.
EXT_DIR="$(cd "$TESTS_DIR/../singular-ext/tests" 2>/dev/null && pwd || true)"

# One finished test -> one PASS/FAIL line, the failure tail, the counters, and
# the progress.jsonl row. Shared by the serial loop and the parallel flusher so
# the two cannot drift in what they print.
record_result() {
  local name="$1" rc="$2" out="$3" seconds="$4" status
  if [[ "$rc" -eq 0 ]]; then
    printf "PASS  %s\n" "$name"
    pass=$((pass + 1))
    status="pass"
  else
    printf "FAIL  %s\n" "$name"
    printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    fail=$((fail + 1))
    failed="$failed $name"
    status="fail"
  fi
  # One JSON line per finished test, appended immediately: this is what makes a
  # run resumable-to-read — counts survive the supervisor being killed, and an
  # interrupted manifest is reconciled from exactly these lines. Test basenames
  # come from a `test-*.sh` glob and need no JSON escaping.
  if [[ -n "$run_dir" ]]; then
    printf '{"test":"%s","status":"%s","seconds":%d,"log":"logs/%s.log"}\n' \
      "$name" "$status" "$seconds" "$name" >>"$run_dir/progress.jsonl"
  fi
}

# Discovery is shared too: the filter is applied to one list, so a parallel run
# executes exactly the files a serial run would, in the same order.
declare -a discovered=()
for t in "$TESTS_DIR"/test-*.sh ${EXT_DIR:+"$EXT_DIR"/test-*.sh}; do
  [[ -e "$t" ]] || continue
  name="$(basename "$t")"
  if [[ "$#" -gt 0 && "$filter" != *" $name "* ]]; then continue; fi
  discovered+=("$t")
done

run_parallel() {
  local pool total launched=0 finished=0 next_print=0 i t name rc out seconds
  local -a parallel=() serial=()
  pool="$(mktemp -d "${TMPDIR:-/tmp}/singular-test-pool.XXXXXX")"
  for t in "${discovered[@]}"; do
    if head -40 "$t" 2>/dev/null | grep -q '^# singular-test: serial'; then
      serial+=("$t")
    else
      parallel+=("$t")
    fi
  done
  total=${#parallel[@]}
  run_one() {
    local index="$1" path="$2" started rc
    started=$SECONDS
    "$BASH" "$path" </dev/null >"$pool/$index.out" 2>&1
    rc=$?
    printf '%s\n' "$((SECONDS - started))" >"$pool/$index.sec"
    # Written last: its presence is the completion signal the flusher polls.
    printf '%s\n' "$rc" >"$pool/$index.rc"
  }
  while (( next_print < total )); do
    while (( launched - finished < jobs && launched < total )); do
      run_one "$launched" "${parallel[$launched]}" &
      launched=$((launched + 1))
    done
    sleep 0.3
    finished=0
    for ((i = 0; i < launched; i++)); do
      [[ -f "$pool/$i.rc" ]] && finished=$((finished + 1))
    done
    while (( next_print < total )) && [[ -f "$pool/$next_print.rc" ]]; do
      t="${parallel[$next_print]}"
      name="$(basename "$t")"
      rc="$(<"$pool/$next_print.rc")"
      seconds="$(<"$pool/$next_print.sec")"
      out="$(<"$pool/$next_print.out")"
      [[ -n "$run_dir" ]] && cp "$pool/$next_print.out" "$run_dir/logs/$name.log"
      record_result "$name" "$rc" "$out" "$seconds"
      next_print=$((next_print + 1))
    done
  done
  wait
  rm -rf "$pool"
  # Declared-serial files run last, one at a time, exactly as the serial loop
  # would have run them.
  for t in "${serial[@]}"; do
    name="$(basename "$t")"
    started=$SECONDS
    if [[ -n "$run_dir" ]]; then
      out="$("$BASH" "$t" </dev/null 2>&1 | tee "$run_dir/logs/$name.log")"; rc=$?
    else
      out="$("$BASH" "$t" </dev/null 2>&1)"; rc=$?
    fi
    record_result "$name" "$rc" "$out" "$((SECONDS - started))"
  done
}

if [[ "$jobs" -gt 1 ]]; then
  run_parallel
fi
for t in "${discovered[@]}"; do
  [[ "$jobs" -gt 1 ]] && break
  name="$(basename "$t")"
  started=$SECONDS
  # </dev/null: no test may inherit the harness's stdin. A test that lets a
  # child read stdin (e.g. a runner mock's `cat` consuming a prompt) hangs
  # forever when the calling harness holds stdin open (detached l1-drive
  # gate) yet passes when stdin is /dev/null — harness-dependent flakiness
  # this closes for every current and future test.
  #
  # With a run dir the same combined stream is tee'd to a durable per-test log
  # as it is produced (an attached operator can watch a slow test grow), while
  # $out still holds it for the tail -3 display below. `set -o pipefail` (line
  # 3) is what keeps the TEST's exit status, not tee's, decisive.
  if [[ -n "$run_dir" ]]; then
    out="$("$BASH" "$t" </dev/null 2>&1 | tee "$run_dir/logs/$name.log")"; rc=$?
  else
    out="$("$BASH" "$t" </dev/null 2>&1)"; rc=$?
  fi
  record_result "$name" "$rc" "$out" "$((SECONDS - started))"
done

# A filter that matched nothing is an error, not an empty green run: silently
# reporting "0 passed, 0 failed" for a misspelled or deleted test name is the
# kind of false pass this whole command exists to eliminate.
if [[ "$#" -gt 0 && "$((pass + fail))" -eq 0 ]]; then
  echo "run.sh: no test file matched the filter:$(printf ' %s' "$@")" >&2
  exit 1
fi

echo ""
echo "SUMMARY: $pass passed, $fail failed"
[[ -n "$failed" ]] && echo "FAILED:$failed"
if [[ -n "$gate_report_file" ]]; then
  python3 - "$gate_report_file" "$failed" "$host_required_check" <<'PY'
import json
import os
import sys

path, failed, host_required = sys.argv[1:4]
failures = [
    {"signature": f"engine-regression:{name}", "title": name}
    for name in failed.split()
]
record = {
    "schema": "singular.orchestration.gate-observation.v0",
    "failures": failures,
}
if host_required:
    record["hostRequired"] = [{"check": host_required, "status": "unrun"}]
    record["infrastructureFailure"] = True
    record["infrastructureReason"] = f"host-required:{host_required}:unrun"
temporary = path + ".tmp"
parent = os.path.dirname(path)
if parent:
    os.makedirs(parent, exist_ok=True)
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
fi
[[ "$fail" -eq 0 ]] || exit 1
[[ -z "$host_required_check" ]] || exit 2
