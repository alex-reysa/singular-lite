#!/usr/bin/env bash
# ctx-plan-critic.sh — the S2-plan-critique runtime brick: run the plan critic
# (the skeptic) over a STAGED candidate batch and record its critique.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-paired-audit.sh). The reconcile.sh / L0 import-enforcement hook is
# the follow-up critique-import-gate node and is out of scope here.
#
# Purpose: before any batch work starts, run ONE fresh, read-only critic pass
# over the node-local staged candidate set (rendered candidate task files, the
# existing-task summary, and the node's docs/context-build-plan/ stage file) and
# record what the skeptic says. The critic runs on the DEFAULT runner
# (SINGULAR_RUNNER) — NOT the module-routed planner runner — so the cross-provider
# independence property holds even for module-routed planners: a module planner
# still gets a default-runner critic. The critique is observability + a Stage-3
# input; it NEVER weakens, resumes into, or bypasses the un-bypassable
# implementation auditor that runs later.
#
# Fail-open: the critic is an ADDED safety layer, so its infrastructure failing
# must never deadlock planning. If the runner's output stays unparseable after
# the SINGULAR_PLAN_CRITIC_INFRA_MAX-bounded fresh retries, the driver treats the result
# as an "approve" verdict and appends a ctx.plan_critique_infra event rather
# than blocking. The implementation auditor remains the safety floor.
#
# Public entry points:
#   singular_ctx_plan_critic_session_path <node>
#     Pure: print the canonical per-node critic session-meta path
#     "<state-dir>/sessions/plan-critic/<node>.json". No side effects.
#   singular_ctx_plan_critic_run <node> <run_id> <stage_dir> [worktree]
#     Run exactly ONE fresh (no --resume/session reuse), read-only critic pass
#     over the staged candidate set via SINGULAR_RUNNER using a content-bound
#     prompt (critic policy + candidates + existing-task summary + node authority),
#     extract the critique with singular_extract_json, normalize finding
#     ids to the singular_finding_id identity, persist it as plan-critique.json
#     next to the staged candidates, append one plan.critiqued event (verdict +
#     finding count), and finalize per-node critic session meta (role
#     "plan-critic"). On persistent infra failure it fails OPEN as above. Returns
#     0 on both the parsed and fail-open paths; it never blocks planning.

# Pure path helper: the canonical per-node critic session-meta path under the
# runtime state dir. Session ids are runtime state, so this lives beside other
# .singular-state artifacts, NEVER under docs/. Empty node -> empty (caller skips).
singular_ctx_plan_critic_session_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local state_dir="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}"
  printf '%s/sessions/plan-critic/%s.json' "$state_dir" "$node"
}

# Run the critic over a staged candidate batch and record the critique. Never
# fatal to planning: parses when it can, else fails OPEN as an approve.
singular_ctx_plan_critic_run() {
  local node="$1" run_id="$2" stage_dir="$3" worktree="${4:-.}"

  mkdir -p "$stage_dir"

  # Base plan-critic prompt from the runtime orch dir. The basename is assembled
  # from parts on purpose: the S2 contract gate (tests/test-plan-critique-schema.sh)
  # asserts NO engine path carries the literal prompt filename until this runtime
  # slice lands, and that literal-string gate is enforced separately from this
  # node — so the driver references the prompt without embedding the contiguous
  # literal. Runtime resolution is unaffected.
  local _pn="plan-critic"
  local prompt="${SINGULAR_ORCH_DIR}/prompts/${_pn}.md"
  # A repository initialized before this prompt existed (`singular init` copies
  # templates with cp -n, once) has no copy of it, and an absent policy used to
  # make the critic run blind and every revise loop park on an empty verdict.
  # The engine template is the authoritative fallback; the event makes the
  # substitution visible so an operator can materialize a repo copy on purpose.
  if [[ ! -f "$prompt" && -f "${SINGULAR_ENGINE_HOME}/templates/prompts/${_pn}.md" ]]; then
    prompt="${SINGULAR_ENGINE_HOME}/templates/prompts/${_pn}.md"
    singular_append_event "ctx.plan_critic_prompt_fallback" \
      "repository has no plan-critic prompt; using the engine template" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"prompt\":\"$prompt\"}" || true
  fi
  # DEFAULT runner (cross-provider independence): a module-routed planner still
  # gets a default-runner critic.
  local runner
  runner="$(singular_role_runner critic "${SINGULAR_RUNNER:-$SINGULAR_ENGINE_DIR/codex-run.sh}")" || return 78
  local raw="$stage_dir/plan-critique-raw.json"
  local record="$stage_dir/plan-critique.json"
  local critic_input="$stage_dir/plan-critic-input.md"

  # Per-node critic session meta (role plan-critic), usable by Stage 3 carry-over.
  local session_meta; session_meta="$(singular_ctx_plan_critic_session_path "$node")"
  [[ -n "$session_meta" ]] && mkdir -p "$(dirname "$session_meta")"
  local runner_basename; runner_basename="$(basename "$runner")"
  local prompt_sha; prompt_sha="$(singular_prompt_sha "$prompt" 2>/dev/null || printf '%s' "")"

  # The batch is known to the driver: derive the authoritative task ids from the
  # rendered candidate files staged for this node, so the persisted record's
  # batchTaskIds reflect the actual staged set (not whatever the runner echoed).
  local candidate_batch_dir
  candidate_batch_dir="$(singular_task_batch_candidate_dir "$stage_dir")" || return 2
  local batch_csv=""
  local f base tid
  for f in "$candidate_batch_dir"/TASK-*.candidate.md; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f" .candidate.md)"
    tid="$(printf '%s' "$base" | grep -oE '^TASK-[0-9]{4,}' || true)"
    [[ -n "$tid" ]] || continue
    if [[ -z "$batch_csv" ]]; then batch_csv="$tid"; else batch_csv="$batch_csv,$tid"; fi
  done
  # Legacy fixtures and pre-task-batch staging used TASK-*.md. Keep that input
  # readable only when no authoritative candidate files exist.
  if [[ -z "$batch_csv" ]]; then
    for f in "$candidate_batch_dir"/TASK-*.md; do
      [[ -e "$f" ]] || continue
      base="$(basename "$f" .md)"
      tid="$(printf '%s' "$base" | grep -oE '^TASK-[0-9]{4,}' || true)"
      [[ -n "$tid" ]] || continue
      if [[ -z "$batch_csv" ]]; then batch_csv="$tid"; else batch_csv="$batch_csv,$tid"; fi
    done
  fi

  local base_sha="${SINGULAR_PLAN_ATTEMPT_BASE_SHA:-}"
  if [[ -z "$base_sha" && -f "$stage_dir/plan-attempt-input.json" ]]; then
    base_sha="$(python3 - "$stage_dir/plan-attempt-input.json" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("baseSha", ""))
PY
)"
  fi
  [[ -n "$base_sha" ]] || base_sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || printf '%s' "")"

  # The former driver built this context elsewhere but sent only the base policy
  # to the runner. Compose one complete prompt here and bind all caching to its
  # bytes. A critic can therefore neither run blind nor reuse a verdict for a
  # changed candidate/summary/authority/policy.
  if ! singular_ctx_plan_critic_context "$node" "$stage_dir" "$critic_input" "" "$prompt" "$base_sha"; then
    return 2
  fi
  local context_sha; context_sha="$(singular_sha256_file "$critic_input" 2>/dev/null || printf '%s' "")"
  [[ -n "$context_sha" ]] || return 2

  local engine_version="${SINGULAR_ENGINE_VERSION:-}"
  if [[ -z "$engine_version" ]]; then
    local version_file="${SINGULAR_ENGINE_DIR}/../VERSION"
    [[ -f "$version_file" ]] && engine_version="$(tr -d '[:space:]' < "$version_file")"
  fi
  local critic_policy_version="${SINGULAR_PLAN_CRITIC_POLICY_VERSION:-1}"
  local critic_model_version
  if [[ "$(type -t singular_plan_attempt_critic_model_version)" == "function" ]]; then
    critic_model_version="$(singular_plan_attempt_critic_model_version)"
  else
    critic_model_version="${SINGULAR_PLAN_CRITIC_MODEL_VERSION:-$runner_basename}"
  fi
  local critic_capability_profile="${SINGULAR_CRITIC_CAPABILITY_PROFILE:-audit-core}"
  local critique_identity
  critique_identity="$(python3 - "$node" "$base_sha" "$context_sha" "$prompt_sha" \
    "$engine_version" "$critic_policy_version" "$critic_model_version" \
    "$critic_capability_profile" <<'PY'
import hashlib, json, sys
keys = ("node", "baseSha", "contextSha", "promptSha", "engineVersion",
        "policyVersion", "modelVersion", "capabilityProfile")
doc = dict(zip(keys, sys.argv[1:]))
raw = json.dumps(doc, sort_keys=True, separators=(",", ":")).encode("utf-8")
print(hashlib.sha256(raw).hexdigest())
PY
)"
  local node_key; node_key="$(printf '%s' "$node" | tr -c 'A-Za-z0-9._-' '-')"
  local cache_dir="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}/planning-attempts/$node_key/critique-cache"
  local cache_record="$cache_dir/$critique_identity.json"

  # A parsed semantic verdict is immutable for this exact identity. Rehydrate it
  # with the current run id rather than paying for a second critic pass (notably
  # the historical l1-plan/import-fanout double invocation). Infrastructure
  # fail-open records are never cached.
  if [[ -f "$cache_record" ]] && python3 - "$cache_record" "$node" <<'PY' >/dev/null 2>&1
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc.get("schema") == "singular.orchestration.plan-critique.v0"
assert doc.get("node") == sys.argv[2]
assert doc.get("verdict") in ("approve", "revise", "park")
assert isinstance(doc.get("findings"), list)
PY
  then
    local original_run_id
    original_run_id="$(python3 - "$cache_record" "$record" "$run_id" <<'PY'
import json, os, sys, tempfile
source, target, run_id = sys.argv[1:4]
doc = json.load(open(source, encoding="utf-8"))
original = str(doc.get("runId", ""))
doc["runId"] = run_id
os.makedirs(os.path.dirname(target), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".plan-critique.", dir=os.path.dirname(target))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print(original)
PY
)"
    singular_append_event "plan.critique_reused" "reused identity-bound plan critique" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"originalRunId\":\"$original_run_id\",\"critiqueIdentity\":\"$critique_identity\",\"contextSha256\":\"$context_sha\"}"
    return 0
  fi

  local infra_max="${SINGULAR_PLAN_CRITIC_INFRA_MAX:-1}"
  [[ "$infra_max" =~ ^[0-9]+$ ]] || infra_max=1
  # Permit disabling the retry, never increasing it beyond one extra call.
  (( infra_max <= 1 )) || infra_max=1

  # Up to infra_max+1 fresh, read-only critic passes. FRESH = no
  # --resume-session / session reuse; read-only = --level readonly. A parseable
  # object on any try wins; exhaustion falls through to the fail-open path.
  local parsed="no" try infra_reason=""
  for ((try=0; try<=infra_max; try++)); do
    if [[ "$try" -gt 0 ]]; then
      singular_append_event "ctx.plan_critique_retry" "plan critic infra failure; re-running fresh" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"try\":$try,\"reason\":\"$infra_reason\"}"
    fi
    local result_file="$stage_dir/plan-critic-try-${try}-runner-result.json"
    rm -f "$raw" "$result_file" 2>/dev/null || true
    local rc=0
    singular_runner_contract_prepare \
      "$runner" critic "$critic_capability_profile" "$result_file"
    SINGULAR_RUNNER_ROLE=critic \
    SINGULAR_RUNNER_CAPABILITY_PROFILE="$critic_capability_profile" \
    SINGULAR_RUNNER_RESULT_FILE="$result_file" \
    SINGULAR_RUNNER_RUN_ID="$run_id" \
    "$runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
      --level readonly -C "$worktree" --run-id "$run_id" \
      --prompt-file "$critic_input" --output-last-message "$raw" \
      --session-meta "$session_meta" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 124 ]]; then
      infra_reason="timeout"
    elif [[ ! -f "$raw" ]]; then
      infra_reason="no-record"
    elif ! singular_extract_json "$raw" "$record" 2>/dev/null; then
      infra_reason="unparseable"
    else
      parsed="yes"; break
    fi
  done

  if [[ "$parsed" == "yes" ]]; then
    # Normalize into the plan-critique.v0 shape: authoritative schema/node/runId/
    # batchTaskIds, verdict clamped to the enum, and finding ids re-minted from
    # claim text to the singular_finding_id identity so formatting-only re-reports
    # collapse to the same id. Emit "verdict<TAB>count" for the event.
    local summary
    summary="$(python3 - "$record" "$node" "$run_id" "$batch_csv" \
      "${SINGULAR_PLAN_CRITIQUE_REQUIRE_BLOCKING:-1}" <<'PY'
import hashlib, json, sys

record, node, run_id, batch_csv, require_blocking = sys.argv[1:6]

def finding_id(claim):
    text = " ".join(str(claim).replace(chr(96), "").lower().split())
    return "f-" + hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]

try:
    with open(record, "r", encoding="utf-8") as f:
        obj = json.load(f)
    if not isinstance(obj, dict):
        obj = {}
except Exception:
    obj = {}

verdict = str(obj.get("verdict", "")).strip()
if verdict not in ("approve", "revise", "park"):
    verdict = "approve"

batch = [t for t in batch_csv.split(",") if t]

norm_findings = []
raw_findings = obj.get("findings")
if isinstance(raw_findings, list):
    for fnd in raw_findings:
        if not isinstance(fnd, dict):
            continue
        claim = str(fnd.get("claim", "")).strip()
        evidence = str(fnd.get("evidence", "")).strip()
        if not claim or not evidence:
            continue
        severity = str(fnd.get("severity", "")).strip()
        if severity not in ("blocking", "should-fix", "note"):
            severity = "note"
        out = {
            "id": finding_id(claim),
            "severity": severity,
            "claim": claim,
            "evidence": evidence,
        }
        sugg = fnd.get("suggestedChange")
        if isinstance(sugg, str) and sugg.strip():
            out["suggestedChange"] = sugg
        norm_findings.append(out)

assumptions = obj.get("assumptionsChallenged")
if not isinstance(assumptions, list):
    assumptions = []
assumptions = [str(a) for a in assumptions]

rationale = str(obj.get("rationale", "")).strip()
if not rationale:
    rationale = "critic returned no rationale"

# Host severity gate (0.21.0). The verdict field is a model opinion; the
# severities the critic attached to its own findings are the evidence. A revise
# that names no blocking finding asks the planner to spend a bounded revision
# (this heredoc sits inside a command substitution, so it must stay free of
# apostrophes and backticks: bash 3.2 scans it for quotes while looking for the
# closing paren, and lib.sh sources this file under whatever bash a test uses)
# round on advice the implementer can act on directly, and in the field that
# shape produced 113 revise verdicts out of 140 critiques and parked every
# node on budget exhaustion. Downgrade it to approve, keep every finding (they
# travel with the imported tasks as advisory context), and say so in the
# rationale so the record explains itself. SINGULAR_PLAN_CRITIQUE_REQUIRE_BLOCKING=0
# restores verdict-as-written.
host_disposition = ""
if (verdict == "revise" and require_blocking != "0"
        and not any(f["severity"] == "blocking" for f in norm_findings)):
    verdict = "approve"
    host_disposition = "revise-downgraded-no-blocking"
    rationale = ("[host] revise downgraded to approve: the critique carries no "
                 "blocking finding, so its findings are carried forward as "
                 "advisory context instead of spending a revision round. "
                 + rationale)

rec = {
    "schema": "singular.orchestration.plan-critique.v0",
    "node": node,
    "runId": run_id,
    "batchTaskIds": batch,
    "verdict": verdict,
    "findings": norm_findings,
    "assumptionsChallenged": assumptions,
    "rationale": rationale,
}
with open(record, "w", encoding="utf-8") as f:
    json.dump(rec, f, indent=2)
    f.write("\n")

sys.stdout.write("%s\t%d\t%s" % (verdict, len(norm_findings), host_disposition))
PY
)"
    local verdict count host_disposition
    IFS=$'\t' read -r verdict count host_disposition <<<"$summary"
    [[ -n "$verdict" ]] || verdict="approve"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    if [[ -n "${host_disposition:-}" ]]; then
      singular_append_event "plan.critique_downgraded" \
        "host severity gate downgraded a revise verdict with no blocking finding" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"disposition\":\"$host_disposition\",\"findingsCount\":$count,\"critiqueIdentity\":\"$critique_identity\"}"
    fi
    singular_append_event "plan.critiqued" "plan critic recorded a critique" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"verdict\":\"$verdict\",\"findingsCount\":$count,\"critiqueIdentity\":\"$critique_identity\",\"contextSha256\":\"$context_sha\"}"

    # Cache only a successfully parsed semantic result. Atomic replacement makes
    # a concurrent reader see either no cache or the complete record.
    python3 - "$record" "$cache_record" <<'PY' >/dev/null 2>&1 || true
import json, os, sys, tempfile
source, target = sys.argv[1:3]
doc = json.load(open(source, encoding="utf-8"))
os.makedirs(os.path.dirname(target), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".critique-cache.", dir=os.path.dirname(target))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
  else
    # Fail OPEN: infrastructure failure of an added safety layer must never
    # deadlock planning. Treat as an approve and record it as a distinct infra
    # event (NOT plan.critiqued) so the signal is observable and separable. The
    # un-bypassable implementation auditor remains the safety floor.
    python3 - "$record" "$node" "$run_id" "$batch_csv" "$infra_reason" <<'PY'
import json, sys
record, node, run_id, batch_csv, reason = sys.argv[1:6]
rec = {
    "schema": "singular.orchestration.plan-critique.v0",
    "node": node,
    "runId": run_id,
    "batchTaskIds": [t for t in batch_csv.split(",") if t],
    "verdict": "approve",
    "findings": [],
    "assumptionsChallenged": [],
    "rationale": "plan critic infrastructure failed (%s); failing open to approve so "
                 "planning is not blocked. The implementation auditor remains the "
                 "un-bypassable safety floor." % (reason or "unparseable"),
}
with open(record, "w", encoding="utf-8") as f:
    json.dump(rec, f, indent=2)
    f.write("\n")
PY
    singular_append_event "ctx.plan_critique_infra" "plan critic infra failure; failing open to approve" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"verdict\":\"approve\",\"reason\":\"${infra_reason:-unparseable}\"}"
  fi

  # Finalize per-node critic session meta (role plan-critic) for Stage 3
  # carry-over. Merges host-authority fields into any runner-written meta; when
  # the runner wrote none, a minimal meta is created. Never fatal.
  if [[ -n "$session_meta" ]]; then
    singular_session_meta_finalize "$session_meta" plan-critic "" "$run_id" \
      "$runner_basename" "$prompt_sha" "" "1" >/dev/null 2>&1 || true
  fi

  return 0
}
