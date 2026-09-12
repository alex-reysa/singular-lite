#!/usr/bin/env bash
# ctx-planner-session.sh — per-node planner session-meta persistence behind the
# SINGULAR_PLANNER_SESSION knob (default 1 as of 0.20.0; set 0 to disable).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-paired-audit.sh). The generate-tasks.sh / l1-plan-node.sh call site
# that passes --session-meta to the runner and invokes the finalize wrapper on a
# successful batch is the follow-up slice of this node and is out of scope here.
#
# Purpose: give the planner the same session-affinity lineage the L1 driver
# already gives the implementer/reviewer. A canonical per-node path anchors the
# planner's session-meta as RUNTIME STATE (under the state dir, never docs/,
# because session ids are runtime state, not repo truth). A guarded finalize
# wrapper delegates into the already-integrated singular_session_meta_finalize,
# reusing the singular.orchestration.session-meta.v0 shape with role "planner"
# and a new optional additive `node` field.
#
# Knob: SINGULAR_PLANNER_SESSION (default 1 = ON). When OFF the finalize wrapper
# is a no-op (no file written) independent of rc, so the flow is byte-identical.
#
# Evidence invariance: a failed/invalid planner run (non-zero rc) NEVER finalizes
# a resumable meta — a session that produced rejected output is not a lineage we
# extend blindly. (Stage 3 revision is the deliberate exception, out of scope.)
#
# Public entry points:
#   singular_ctx_planner_session_path <node>
#     Pure: print the canonical per-node planner session-meta path
#     `<state-dir>/sessions/planner/<node>.json`. No side effects.
#   singular_ctx_planner_session_finalize <node> <rc> <task_id> <run_id> \
#                                        <runner_basename> <prompt_sha> <head_sha> <attempt>
#     Guarded: only when SINGULAR_PLANNER_SESSION=1 AND rc==0, write/update a
#     finalized meta at the canonical path via singular_session_meta_finalize
#     (role "planner", headShaAtCreate = the planning-time head sha) and add the
#     additive `node` field. Never fatal.

# Pure path helper: the canonical per-node planner session-meta path under the
# runtime state dir. Session ids are runtime state, so this lives beside other
# .singular-state artifacts, NEVER under docs/. Empty node -> empty (caller skips).
singular_ctx_planner_session_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local state_dir="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}"
  printf '%s/sessions/planner/%s.json' "$state_dir" "$node"
}

# Pure path helper: the canonical per-node planner TRANSCRIPT, beside the meta.
#
# The window gate (planner ladder gate 12) needs the accumulated size of the
# session it is deciding about. The per-RUN planner log is the wrong file: a
# planner session persists ACROSS runs by design (gate 5 keys on node lineage, not
# runId), so at decide time the current run's log does not exist yet — measuring
# it would fail closed on every fresh run and disable planner resume entirely.
#
# This file is the session's own accumulated record instead. Its lifetime matches
# the session's: the caller appends each successful run's planner log to it, and
# TRUNCATES it whenever the decision is `fresh`, because a fresh session starts
# with no carried context and its size must reset with it. Empty node -> empty
# (caller skips), mirroring singular_ctx_planner_session_path.
singular_ctx_planner_session_transcript_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local state_dir="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}"
  printf '%s/sessions/planner/%s.log' "$state_dir" "$node"
}

# Last immutable context bundle delivered to this node's planner session. It is
# separate from model transcript state and contains only bounded host-selected
# prompt/provenance data, allowing resumed planners to receive deltas.
singular_ctx_planner_context_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local state_dir="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}"
  printf '%s/sessions/planner/%s.context-bundle.json' "$state_dir" "$node"
}

# Guarded finalize wrapper. No-op unless the knob is ON and the planner run
# exited successfully (rc 0). Delegates the session-meta.v0 shape to the shared
# singular_session_meta_finalize (role "planner"), then adds the additive optional
# `node` field. NEVER fails the caller.
singular_ctx_planner_session_finalize() {
  local node="$1" rc="$2" task_id="$3" run_id="$4" \
        runner="$5" prompt_sha="$6" head_sha="$7" attempt="$8"

  # Knob default-OFF: unset/"0" -> no file written, byte-identical.
  [[ "${SINGULAR_PLANNER_SESSION:-0}" == "1" ]] || return 0

  # Evidence invariance: a failed/invalid planner run is not a lineage we extend.
  # A non-numeric rc is treated as failure (fail closed).
  [[ "$rc" =~ ^[0-9]+$ ]] || return 0
  (( rc == 0 )) || return 0

  local meta_path; meta_path="$(singular_ctx_planner_session_path "$node")"
  [[ -n "$meta_path" ]] || return 0
  mkdir -p "$(dirname "$meta_path")"

  # SHA-alignment: the call site passes the sha of the RENDERED per-frontier
  # planner prompt ($run_dir/planner-prompt.md), but the decider's gate 8 keys on
  # the sha of the planner TEMPLATE (docs/orchestration/prompts/l1-planner.md),
  # which is stable across frontiers by design. Store the TEMPLATE sha so both
  # sides agree; the rendered-prompt sha the caller passes is intentionally
  # dropped. Resolve the template with the SAME canonical convention the decider
  # keys on (singular_planner_resume_template_path honors SINGULAR_PLANNER_TEMPLATE
  # and defaults under SINGULAR_ROOT). Evidence invariance: an unreadable/absent
  # template resolves fail-closed to an empty sha, so a later decide returns
  # `fresh prompt-template-changed` and never a spurious `resume`.
  local tpl_path template_sha
  tpl_path="$(singular_planner_resume_template_path)"
  template_sha="$(singular_sha256_file "$tpl_path" 2>/dev/null || printf '%s' "")"

  # Reuse the existing host-side finalize to merge the session-meta.v0 shape with
  # the planner role and lineage anchor (headShaAtCreate = planning-time head).
  # promptSha256 is the normalized TEMPLATE sha, NOT the rendered prompt_sha.
  singular_session_meta_finalize "$meta_path" planner "$task_id" "$run_id" \
    "$runner" "$template_sha" "$head_sha" "$attempt"

  # Add the additive optional `node` field. It does not alter the shape when
  # absent; here we set it to the target node. Never fatal.
  python3 - "$meta_path" "$node" <<'PY' 2>/dev/null || true
import json, sys
path, node = sys.argv[1:3]
doc = {}
try:
    with open(path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        doc = loaded
except Exception:
    doc = {}
doc["node"] = node
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
}
