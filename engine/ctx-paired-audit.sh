#!/usr/bin/env bash
# ctx-paired-audit.sh — sampled post-acceptance paired audit behind the
# default-OFF SINGULAR_PAIRED_AUDIT_PCT knob.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior. The
# l1-drive.sh post-acceptance call site is the follow-up slice of this node and
# is out of scope here.
#
# Purpose: after a task has ALREADY been accepted, sometimes run ONE extra,
# independent auditor pass over the just-accepted result and record what it
# would have said — as observability only. The paired verdict NEVER feeds back
# into the accept/reject decision; the recorder only records. When the knob is
# OFF it runs no fresh audit, appends no event, and writes no file, so the
# acceptance flow is byte-identical.
#
# Knob: SINGULAR_PAIRED_AUDIT_PCT (default 0 = OFF). Sampling is keyed on a stable
# content hash of the run/task id reduced modulo 100 — never $RANDOM or any
# host/process-specific source — so the decision is deterministic, reproducible
# across repeated calls and separate processes, and machine-independent:
#   0 (unset or "0") -> never samples;
#   100              -> always samples;
#   a mid value P    -> samples the reproducible subset whose bucket < P.
#
# Public entry points:
#   singular_ctx_paired_audit_bucket <id>
#     Pure: print the id's sampling bucket in 0..99 (stable content hash mod 100).
#   singular_ctx_paired_audit_should_sample <id>
#     Pure: exit 0 if the id is sampled under the current knob, else 1.
#   singular_ctx_paired_audit_record <run_id> <task_id> <run_dir> [worktree]
#     Only when sampled: run exactly ONE fresh (no --resume/session reuse),
#     read-only auditor pass over the accepted result via SINGULAR_RUNNER using the
#     base auditor prompt ($SINGULAR_ORCH_DIR/prompts/auditor.md), then record the
#     paired verdict + findings as one ctx.paired_audit event (via
#     singular_append_event) plus one paired-audit.json in <run_dir>. Disagreement
#     (paired verdict != "accepted" OR non-empty findings) is flagged in both;
#     agreement otherwise. It creates/moves/mutates nothing else — not the packet,
#     the primary audit record, the lease, the task file, or the inbox placement.

# Print the sampling bucket (0..99) for an id via a stable content hash. Uses
# SHA-256 where available, else cksum's CRC — both deterministic and
# machine-independent. Never $RANDOM or any process/host-specific source.
singular_ctx_paired_audit_bucket() {
  local id="$1" hash
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$id" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$id" | shasum -a 256 | awk '{print $1}')"
  else
    hash="$(printf '%s' "$id" | cksum | awk '{print $1}')"
  fi
  # Reduce to 0..99. Interpret the low 6 hex digits as a number, then mod 100.
  # A decimal cksum digit string is a valid hex string too, so this is stable
  # across both hash sources.
  local low="${hash: -6}"
  if [[ "$low" =~ ^[0-9a-fA-F]+$ ]]; then
    printf '%s' $(( 16#$low % 100 ))
  else
    printf '0'
  fi
}

# Exit 0 if the id is sampled under SINGULAR_PAIRED_AUDIT_PCT, else 1. Pure/no
# side effects. Default 0 (OFF) never samples; 100 always; mid value P samples
# the reproducible subset whose bucket < P.
singular_ctx_paired_audit_should_sample() {
  local id="$1" pct="${SINGULAR_PAIRED_AUDIT_PCT:-0}" bucket
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  (( pct <= 0 )) && return 1
  (( pct >= 100 )) && return 0
  bucket="$(singular_ctx_paired_audit_bucket "$id")"
  (( bucket < pct )) && return 0
  return 1
}

# Post-acceptance recorder. Runs strictly after acceptance and ONLY records. No
# effect and no output when the knob is OFF or the id is not sampled.
singular_ctx_paired_audit_record() {
  local run_id="$1" task_id="$2" run_dir="$3" worktree="${4:-.}"

  # Sampling gate keyed on a stable content hash of the run/task id.
  local sample_key="${run_id}:${task_id}"
  singular_ctx_paired_audit_should_sample "$sample_key" || return 0

  local prompt="$run_dir/paired-audit-prompt.md"
  local base_prompt="$SINGULAR_ORCH_DIR/prompts/auditor.md"
  local raw="$run_dir/paired-audit-raw.json"
  local record="$run_dir/paired-audit.json"
  local runner="${SINGULAR_RUNNER:-$SINGULAR_ENGINE_DIR/codex-run.sh}"

  mkdir -p "$run_dir"

  # A paired audit is a brand-new review-target invocation. Assemble its exact
  # prompt from the task contract and role-filtered source snapshot; never reuse
  # the worker or primary reviewer bundle/session.
  cp "$base_prompt" "$prompt" || return $?
  local context_config="${SINGULAR_JSON_CONFIG_FILE:-$SINGULAR_ROOT/singular.config.json}"
  local context_task="$SINGULAR_TASKS_DIR/$task_id.md"
  if [[ "$context_config" == "$SINGULAR_ROOT/"* ]]; then
    local candidate_config="$worktree/${context_config#$SINGULAR_ROOT/}"
    [[ -f "$candidate_config" ]] && context_config="$candidate_config"
  fi
  if [[ "$context_task" == "$SINGULAR_ROOT/"* ]]; then
    local candidate_task="$worktree/${context_task#$SINGULAR_ROOT/}"
    [[ -f "$candidate_task" ]] && context_task="$candidate_task"
  fi
  SINGULAR_CONTEXT_CONFIG_FILE="$context_config" \
    singular_context_invocation_prepare review-target paired-audit \
      "$context_task" "$prompt" "$run_dir/context-review-target-paired.bundle.json" \
    || return $?
  if [[ ! -f "$run_dir/context-review-target-paired.bundle.json" ]]; then
    rm -f "$prompt" 2>/dev/null || true
    prompt="$base_prompt"
  fi

  # Exactly ONE fresh, read-only auditor pass over the accepted result. FRESH =
  # no --resume-session / session reuse; read-only = --level readonly. Runner failure is non-fatal (record still
  # captures what happened) and never feeds back into any outcome.
  local result_file="$run_dir/paired-audit-runner-result.json"
  rm -f "$result_file" 2>/dev/null || true
  local rc=0
  local audit_capability_profile="${SINGULAR_AUDITOR_CAPABILITY_PROFILE:-audit-core}"
  singular_runner_contract_prepare \
    "$runner" auditor "$audit_capability_profile" "$result_file"
  SINGULAR_RUNNER_ROLE=auditor \
  SINGULAR_RUNNER_CAPABILITY_PROFILE="$audit_capability_profile" \
  SINGULAR_RUNNER_RESULT_FILE="$result_file" \
  SINGULAR_RUNNER_RUN_ID="$run_id" \
  "$runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
    --level readonly -C "$worktree" --run-id "$run_id" \
    --prompt-file "$prompt" --output-last-message "$raw" >/dev/null 2>&1 || rc=$?

  # Parse verdict + findings and write the record; emit the event data on stdout.
  # Disagreement := verdict != "accepted" OR non-empty findings.
  local data
  data="$(python3 - "$raw" "$record" "$task_id" "$run_id" "$rc" <<'PY'
import json
import sys

raw, record, task_id, run_id, rc = sys.argv[1:6]

verdict = "unknown"
findings = []
try:
    with open(raw, "r", encoding="utf-8") as f:
        obj = json.load(f)
    if isinstance(obj, dict):
        verdict = str(obj.get("verdict", "unknown")) or "unknown"
        raw_findings = obj.get("findings")
        if isinstance(raw_findings, list):
            findings = [x for x in raw_findings if str(x).strip()]
        elif isinstance(raw_findings, str):
            s = raw_findings.strip()
            findings = [s] if s and s.lower() != "none" else []
        elif raw_findings:
            findings = [raw_findings]
except Exception:
    pass

count = len(findings)
disagreement = (verdict != "accepted") or (count > 0)

try:
    runner_exit = int(rc)
except (TypeError, ValueError):
    runner_exit = rc

rec = {
    "schema": "singular.orchestration.paired-audit.v0",
    "runId": run_id,
    "taskId": task_id,
    "sampled": True,
    "runnerExit": runner_exit,
    "verdict": verdict,
    "findings": findings,
    "findingsCount": count,
    "disagreement": disagreement,
    "agreement": not disagreement,
}
with open(record, "w", encoding="utf-8") as f:
    json.dump(rec, f, sort_keys=True, indent=2)
    f.write("\n")

data = {
    "taskId": task_id,
    "runId": run_id,
    "verdict": verdict,
    "findingsCount": count,
    "disagreement": disagreement,
    "agreement": not disagreement,
}
sys.stdout.write(json.dumps(data, separators=(",", ":")))
PY
)"

  # Record the paired result as exactly ONE ctx.paired_audit event. This is the
  # only mutation the recorder makes to shared state; it does not touch the
  # packet, primary audit record, lease, task file, or inbox placement.
  singular_append_event "ctx.paired_audit" "paired post-acceptance audit recorded" "$data"
}
