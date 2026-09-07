#!/usr/bin/env bash
set -euo pipefail
# Consumer runner extension for the brain campaign. The upstream 0.21.0 runner
# owns isolation, session identity, output capture, and audit/result contracts.
# This wrapper only supplies its existing global model setting per invocation.
role="${SINGULAR_RUNNER_ROLE:-unknown}"
level=l2
prompt=""
args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) role="$2"; shift 2 ;;
    --level) level="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$role" == unknown ]]; then
  case "$(basename "$prompt")" in
    planner-prompt.md) role=planner ;;
    decider.md|decider-prompt-*.md) role=decider ;;
    *supervisor*|*ask*) role=supervisor ;;
    *critic*|auditor*|reviewer*) role=auditor ;;
    *) [[ "$level" != l2 ]] || role=implementer ;;
  esac
fi
case "$role" in
  planner) model="${SINGULAR_CODEX_PLANNER_MODEL:-gpt-6-astra}" ;;
  decider) model="${SINGULAR_CODEX_DECIDER_MODEL:-gpt-6-astra}" ;;
  supervisor|assistant) model="${SINGULAR_CODEX_SUPERVISOR_MODEL:-gpt-6-astra}" ;;
  *) model="${SINGULAR_CODEX_IMPLEMENTER_MODEL:-gpt-5.6-sol}" ;;
esac
# The campaign JSON deliberately has no SINGULAR_CODEX_MODEL entry, so the
# upstream runner's normal config load preserves this invocation-specific value.
export SINGULAR_CODEX_MODEL="$model"
: "${SINGULAR_ENGINE_HOME:?Use tools/brain-campaign/run.sh or the campaign environment}"
exec "${SINGULAR_BASH_BIN:-bash}" "$SINGULAR_ENGINE_HOME/engine/codex-run.sh" "${args[@]}"
