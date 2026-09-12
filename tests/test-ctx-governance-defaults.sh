#!/usr/bin/env bash
# Covers the 0.20.0 governance-posture change: the independence pin became
# STRUCTURAL (it binds above the routing flag, in every configuration), the
# context subsystem ships ON by default, the planner ladder grew a window gate,
# and the window budget is resolved per PROVIDER from engine/providers.json.
#
# This is the regression test the audit's P3 asked for, widened to every behavior
# change that shipped with it. The single most important assertion in this file is
# INDEPENDENCE IS UNCONDITIONAL: an audit step resolves to fresh for EVERY value
# of SINGULAR_CTX_ROUTING over a session-meta that is otherwise fully resumable.
# Before this change that same fixture returned `resume <sessionId>` with the flag
# unset or 0 — the reviewer resumed the session that rejected the prior attempt.
#
# Contract asserted here:
#   1. final-audit and paired-audit pin to `fresh tainted` for routing unset/0/1.
#   2. re-critique and critic-recheck pin identically (both skeptic-resume
#      authorities are pinned BEFORE their consult hooks are wired).
#   3. A non-independence step (implement) is NOT pinned, and still resumes.
#   4. No SINGULAR_* knob relaxes a pinned step.
#   5. The four governance knobs default to 1, and an explicit 0 still wins.
#   6. The planner ladder's gate 12 refuses an over-window transcript, skips when
#      no transcript is supplied, and keeps every prior gate's reason ordering.
#   7. The window budget resolves runner -> provider -> providers.json, with the
#      env override winning and an unresolvable runner falling back to 200000.
#   8. The window estimate includes the fixed engine-side overhead allowance.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}
pass() { echo "ok: $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# This file measures ENGINE DEFAULTS through a configuration-free consumer.
# Keeping the consumer separate from ENGINE_HOME prevents this checkout's own
# JSON and operator layers from participating without manufacturing selectors.
export SINGULAR_ROOT="$tmp/consumer"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# ---------------------------------------------------------------------------
# Fixture: a reviewer session-meta that passes EVERY gate of the legacy decider.
# ---------------------------------------------------------------------------
wt="$tmp/wt"; mkdir -p "$wt"
git -C "$wt" init -q                 || fail "git init"
git -C "$wt" config user.email t@t   || fail "git config"
git -C "$wt" config user.name  tester|| fail "git config"
echo seed >"$wt/seed.txt"
git -C "$wt" add -A                  || fail "git add"
git -C "$wt" commit -qm seed         || fail "git commit"
HEAD_SHA="$(git -C "$wt" rev-parse HEAD)"

run_dir="$tmp/run"; mkdir -p "$run_dir"
META="$run_dir/session-reviewer.json"
NOW="$(python3 -c 'from datetime import datetime,timezone;print(datetime.now(timezone.utc).isoformat().replace("+00:00","Z"))')"
cat >"$META" <<JSON
{
  "schema": "singular.orchestration.session-meta.v0",
  "provider": "codex",
  "sessionId": "SESS-REVIEWER-1",
  "role": "reviewer",
  "taskId": "TASK-0001",
  "runId": "RUN-0001",
  "runner": "codex-run.sh",
  "promptSha256": "deadbeef",
  "createdAt": "$NOW",
  "headShaAtCreate": "$HEAD_SHA",
  "cwd": "$wt",
  "lastUsedAttempt": 1
}
JSON
# A small transcript so the window gate has something measurable and passes.
printf 'x%.0s' $(seq 1 400) >"$run_dir/auditor-codex.log"

# Sanity: the fixture really is resumable by the step-BLIND legacy decider. If
# this ever stops being true the pin assertions below become vacuous.
got="$(singular_session_resume_decide "$META" reviewer TASK-0001 RUN-0001 \
        codex-run.sh deadbeef "$wt" "$HEAD_SHA")"
assert_eq "$got" "resume SESS-REVIEWER-1" "fixture is resumable by the legacy decider"
pass "fixture resumable by the step-blind legacy decider (assertions are not vacuous)"

route_at() { # <step> <routing-value|unset>
  local step="$1" routing="$2"
  if [[ "$routing" == "unset" ]]; then
    env -u SINGULAR_CTX_ROUTING bash -c '
      set -uo pipefail
      source "$1" >/dev/null 2>&1
      singular_ctx_route_decide reviewer "$2" "$3" TASK-0001 RUN-0001 \
        codex-run.sh deadbeef "$4" "$5"
    ' _ "$LIB" "$step" "$META" "$wt" "$HEAD_SHA"
  else
    SINGULAR_CTX_ROUTING="$routing" bash -c '
      set -uo pipefail
      source "$1" >/dev/null 2>&1
      singular_ctx_route_decide reviewer "$2" "$3" TASK-0001 RUN-0001 \
        codex-run.sh deadbeef "$4" "$5"
    ' _ "$LIB" "$step" "$META" "$wt" "$HEAD_SHA"
  fi
}

# --- 1 + 2: every independence-required step pins, in every configuration ----
for step in final-audit paired-audit re-critique critic-recheck; do
  for routing in unset 0 1; do
    got="$(route_at "$step" "$routing")"
    assert_eq "$got" "fresh tainted" "pin: step=$step SINGULAR_CTX_ROUTING=$routing"
  done
done
pass "independence pin binds for 4 steps x 3 routing states (12 combinations)"

# --- 3: a non-independence step is NOT pinned and still resumes --------------
got="$(route_at implement unset)"
assert_eq "$got" "resume SESS-REVIEWER-1" "implement is not an independence step (routing unset)"
got="$(route_at implement 0)"
assert_eq "$got" "resume SESS-REVIEWER-1" "implement is not an independence step (routing 0)"
pass "non-independence steps are unaffected by the pin (resume still reachable)"

# --- 4: no knob relaxes a pinned step ---------------------------------------
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_AFFINITY=1 \
       SINGULAR_SESSION_WINDOW_TOKENS=100000000 SINGULAR_SESSION_DIFF_MAX_LINES=999999 \
       bash -c '
         set -uo pipefail
         source "$1" >/dev/null 2>&1
         singular_ctx_route_decide reviewer final-audit "$2" TASK-0001 RUN-0001 \
           codex-run.sh deadbeef "$3" "$4"
       ' _ "$LIB" "$META" "$wt" "$HEAD_SHA")"
assert_eq "$got" "fresh tainted" "no knob combination relaxes final-audit"
pass "no SINGULAR_* knob combination reaches a pinned step"

# --- 5: governance defaults are ON, and an explicit 0 still wins -------------
for knob in SINGULAR_CTX_ROUTING SINGULAR_PLANNER_SESSION SINGULAR_CTX_PACKET SINGULAR_PLAN_CRITIQUE; do
  got="$(env -u "$knob" bash -c '
    source "$1" >/dev/null 2>&1; printf "%s" "${!2}"' _ "$LIB" "$knob")"
  assert_eq "$got" "1" "default of $knob"
  got="$(env "$knob=0" bash -c '
    source "$1" >/dev/null 2>&1; printf "%s" "${!2}"' _ "$LIB" "$knob")"
  assert_eq "$got" "0" "explicit 0 override of $knob"
done
pass "4 governance knobs default to 1; an explicit 0 still wins (escape hatch intact)"

# --- 7: window budget resolution --------------------------------------------
assert_eq "$(singular_ctx_route_window_budget "$ENGINE_HOME/engine/claude-run.sh")" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["providers"]["claude"]["contextWindowTokens"])' "$ENGINE_HOME/engine/providers.json")" \
  "budget resolves from providers.json for a known adapter"
assert_eq "$(singular_ctx_route_window_budget /nowhere/nope-run.sh)" "200000" \
  "unresolvable runner falls back to the conservative 200000"
assert_eq "$(singular_ctx_route_window_budget "")" "200000" \
  "empty runner falls back to the conservative 200000"
assert_eq "$(SINGULAR_SESSION_WINDOW_TOKENS=4242 singular_ctx_route_window_budget "$ENGINE_HOME/engine/claude-run.sh")" \
  "4242" "explicit SINGULAR_SESSION_WINDOW_TOKENS override wins"

# Every shipped provider carries the field, as a positive integer.
python3 - "$ENGINE_HOME/engine/providers.json" <<'PY' || fail "providers.json contextWindowTokens conformance"
import json, sys
doc = json.load(open(sys.argv[1]))
missing = [n for n, s in doc["providers"].items()
           if not isinstance(s.get("contextWindowTokens"), int)
           or s["contextWindowTokens"] <= 0]
if missing:
    print("providers missing a positive integer contextWindowTokens:", missing)
    sys.exit(1)
PY
pass "window budget resolves runner -> provider -> providers.json (override + fallbacks)"

# --- 7b: the REAL call shape — bare basename, foreign cwd, distinct values ----
# The routing call sites pass `basename "$l2_runner"`, not a path, and the process
# cwd during a run is the worktree. An earlier version of this resolution passed a
# repo-root-relative path in tests and was DEAD at every real call site: the
# identity lookup resolved the basename against the wrong directory, failed, and
# the budget silently fell through to the 200000 constant. Because the shipped
# per-provider values are all seeded at 200000, that failure was invisible — a
# resolved value and a fallback value are the same number today. This fixture
# therefore uses DISTINCT values so the two outcomes cannot be confused.
edir="$tmp/edir"; mkdir -p "$edir"
cp "$ENGINE_HOME/engine/codex-run.sh" "$ENGINE_HOME/engine/claude-run.sh" "$edir/" \
  || fail "could not stage adapters for the resolution fixture"
python3 - "$ENGINE_HOME/engine/providers.json" "$edir/providers.json" <<'PY' || fail "fixture providers.json"
import json, sys
doc = json.load(open(sys.argv[1]))
doc["providers"]["codex"]["contextWindowTokens"] = 777777
doc["providers"]["claude"]["contextWindowTokens"] = 555555
json.dump(doc, open(sys.argv[2], "w"), indent=2)
PY
got="$(cd / && SINGULAR_ENGINE_DIR="$edir" singular_ctx_route_window_budget codex-run.sh)"
assert_eq "$got" "777777" "bare basename resolves per-provider from a foreign cwd (codex)"
got="$(cd / && SINGULAR_ENGINE_DIR="$edir" singular_ctx_route_window_budget claude-run.sh)"
assert_eq "$got" "555555" "bare basename resolves per-provider from a foreign cwd (claude)"
got="$(cd / && SINGULAR_ENGINE_DIR="$edir" singular_ctx_route_window_budget "$edir/claude-run.sh")"
assert_eq "$got" "555555" "an explicit path still resolves"
got="$(cd / && SINGULAR_ENGINE_DIR="$edir" singular_ctx_route_window_budget nope-run.sh)"
assert_eq "$got" "200000" "an unknown adapter falls back conservatively, not to a neighbour's window"
pass "window budget resolves in the REAL call shape (bare basename + foreign cwd)"

# --- 8: the overhead allowance is actually applied ---------------------------
# Pick a transcript size that passes WITHOUT the overhead and refuses WITH it, so
# the assertion can only hold if the overhead is in the arithmetic.
#   threshold tokens = window * max_pct / 100 ; est = bytes/cpt + overhead
# With window=100000, max_pct=70, cpt=4: threshold = 70000 tokens.
# bytes = 4 * 65000 = 260000 -> est without overhead 65000 (pass); with 12000 -> 77000 (refuse).
probe="$tmp/probe.log"
python3 -c 'open("'"$probe"'","w").write("x"*260000)'
got="$(SINGULAR_SESSION_WINDOW_TOKENS=100000 singular_ctx_route_window_gate reviewer "$probe")"
assert_eq "$got" "refuse window-pressure" "overhead pushes a just-under estimate over the line"
smaller="$tmp/probe2.log"
python3 -c 'open("'"$smaller"'","w").write("x"*100000)'
got="$(SINGULAR_SESSION_WINDOW_TOKENS=100000 singular_ctx_route_window_gate reviewer "$smaller")"
assert_eq "$got" "pass" "a comfortably-small transcript still passes with the overhead applied"
pass "window estimate includes the fixed engine-side overhead allowance"

# --- 6: planner gate 12 -------------------------------------------------------
tpl="$tmp/l1-planner.md"
printf 'planner template\n' >"$tpl"
export SINGULAR_PLANNER_TEMPLATE="$tpl"
tpl_sha="$(singular_sha256_file "$tpl")"
pmeta="$tmp/planner.json"
cat >"$pmeta" <<JSON
{
  "schema": "singular.orchestration.session-meta.v0",
  "provider": "codex",
  "sessionId": "SESS-PLANNER-1",
  "role": "planner",
  "node": "NODE-1",
  "runner": "codex-run.sh",
  "promptSha256": "$tpl_sha",
  "createdAt": "$NOW",
  "headShaAtCreate": "$HEAD_SHA",
  "cwd": "$wt"
}
JSON

# No transcript supplied -> gate 12 skipped, resume stands (documented behavior:
# skip, not fail-closed, so the in-lineage revise path is not silently disabled).
got="$(SINGULAR_PLANNER_SESSION=1 singular_planner_resume_decide "$pmeta" NODE-1 codex-run.sh "$wt" "$HEAD_SHA")"
assert_eq "$got" "resume SESS-PLANNER-1" "planner: 5-arg caller keeps its exact contract (gate 12 skipped)"

# Small transcript supplied -> gate 12 passes.
small="$tmp/planner-small.log"; printf 'x%.0s' $(seq 1 400) >"$small"
got="$(SINGULAR_PLANNER_SESSION=1 singular_planner_resume_decide "$pmeta" NODE-1 codex-run.sh "$wt" "$HEAD_SHA" "$small")"
assert_eq "$got" "resume SESS-PLANNER-1" "planner: small transcript passes gate 12"

# Over-window transcript -> gate 12 refuses. This is the protection the planner —
# the longest-lived session in the engine — had none of before.
big="$tmp/planner-big.log"
python3 -c 'open("'"$big"'","w").write("x"*4000000)'
got="$(SINGULAR_PLANNER_SESSION=1 singular_planner_resume_decide "$pmeta" NODE-1 codex-run.sh "$wt" "$HEAD_SHA" "$big")"
assert_eq "$got" "fresh window-pressure" "planner: over-window transcript refuses at gate 12"

# A missing transcript path that IS supplied fails closed.
got="$(SINGULAR_PLANNER_SESSION=1 singular_planner_resume_decide "$pmeta" NODE-1 codex-run.sh "$wt" "$HEAD_SHA" "$tmp/absent.log")"
assert_eq "$got" "fresh window-pressure" "planner: supplied-but-missing transcript fails closed"

# Gate ORDER is preserved: an earlier gate still names the reason even when the
# transcript would also refuse.
got="$(SINGULAR_PLANNER_SESSION=1 singular_planner_resume_decide "$pmeta" OTHER-NODE codex-run.sh "$wt" "$HEAD_SHA" "$big")"
assert_eq "$got" "fresh node-mismatch" "planner: earlier gate still wins over gate 12"
got="$(SINGULAR_PLANNER_SESSION=0 singular_planner_resume_decide "$pmeta" NODE-1 codex-run.sh "$wt" "$HEAD_SHA" "$big")"
assert_eq "$got" "fresh disabled" "planner: gate 1 still wins over gate 12"
pass "planner gate 12 refuses window pressure without disturbing gate order"

echo "ctx-governance-defaults tests passed"
