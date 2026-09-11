#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-brain-ingestion.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

while IFS= read -r inherited_name; do unset "$inherited_name"; done \
  < <(compgen -v | grep '^SINGULAR_' || true)
unset inherited_name

fail() { echo "brain-ingestion-e2e failed: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"; }
run_rc() {
  local result_var="$1"; shift
  local captured status=0
  captured="$({ "$@"; } 2>&1)" || status=$?
  printf -v "$result_var" '%s' "$captured"
  return "$status"
}

consumer="$tmp/consumer with spaces"
corpus="$consumer/corpus"
invoke="$tmp/different cwd"
mkdir -p "$consumer/config" "$invoke"
cp -Rp "$ROOT/tests/fixtures/singular-brain/knowledge-scope" "$corpus"

cat >"$consumer/config/singular.json" <<'JSON'
{
  "schemaVersion": "v2",
  "brainConfig": "../corpus/singular-brain.config.json",
  "contextManifest": {
    "format": "singular-brain.manifest.v1",
    "manifest": "../corpus/docs/KNOWLEDGE.json",
    "sourceId": "e2e-live-generator",
    "expectedScope": "knowledge",
    "sourceRoot": "../corpus",
    "select": ["notes/decision-log.md", "skills/example-skill/SKILL.md"]
  }
}
JSON

manifest() {
  ( cd "$invoke" && SINGULAR_ENGINE_HOME="$ROOT" \
      SINGULAR_JSON_CONFIG_FILE="$consumer/config/singular.json" \
      bash "$ROOT/cli/singular" manifest "$@" )
}
consume() {
  ( cd "$invoke" && python3 "$ROOT/engine/brain_documents.py" "$@" \
      --config "$consumer/config/singular.json" )
}

# Generate the real producer format from a copied upstream corpus, then consume
# those exact bytes from an unrelated cwd.
manifest gen --scope knowledge
normalized="$(consume normalize)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"] == "singular.context.brain-documents.v1"; assert [x["artifactPath"] for x in d["documents"] if x["included"]] == ["notes/decision-log.md", "skills/example-skill/SKILL.md"]' <<<"$normalized"
rendered="$(consume render)"
assert_contains "$rendered" "Durable decisions live here." "generated decision was not selected"
assert_contains "$rendered" "Body content that is not part of routing metadata." "generated skill was not selected"

# A body edit remains review debt until explicit producer blessing. Live source
# and durable review hashes are both exposed and cannot be conflated.
printf '\nUnreviewed e2e drift.\n' >>"$corpus/notes/decision-log.md"
manifest gen
normalized="$(consume normalize)"
python3 -c 'import json,sys; d=json.load(sys.stdin); r=next(x for x in d["documents"] if x["artifactPath"]=="notes/decision-log.md"); assert not r["eligible"]; assert "review_description_unverified" in r["exclusionReasons"]; assert r["review"]["bodyHash"] != r["review"]["liveBodyHash"]' <<<"$normalized"
manifest bless --scope knowledge notes/decision-log.md
consume normalize >/dev/null

# Lifecycle state is authoritative and superseded content is excluded.
python3 - "$corpus/notes/decision-log.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace("status: canonical", "status: superseded", 1))
PY
manifest bless --scope knowledge notes/decision-log.md
normalized="$(consume normalize)"
python3 -c 'import json,sys; d=json.load(sys.stdin); r=next(x for x in d["documents"] if x["artifactPath"]=="notes/decision-log.md"); assert not r["eligible"]; assert "lifecycle_superseded" in r["exclusionReasons"]' <<<"$normalized"

# Configured containment and duplicate failures are visible and fail closed.
printf 'outside\n' >"$tmp/outside.md"
ln -s "$tmp" "$corpus/escape"
python3 - "$corpus/docs/KNOWLEDGE.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
entry = dict(d["entries"][0])
entry["path"] = "escape/outside.md"
d["entries"].append(entry)
open(p, "w").write(json.dumps(d))
PY
if run_rc output consume normalize; then fail "symlink escape passed"; else rc=$?; fi
[[ "$rc" -eq 2 ]] || fail "symlink escape should exit 2, got $rc"
assert_contains "$output" "outside contextManifest.sourceRoot" "symlink escape was not diagnosed"

manifest gen
python3 - "$corpus/docs/KNOWLEDGE.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["entries"].append(dict(d["entries"][0]))
open(p, "w").write(json.dumps(d))
PY
if run_rc output consume normalize; then fail "duplicate manifest identity passed"; else rc=$?; fi
[[ "$rc" -eq 2 ]] || fail "duplicate identity should exit 2, got $rc"
assert_contains "$output" "duplicate manifest artifact path" "duplicate identity was not diagnosed"

# The install payload carries both producer and consumer and works elsewhere.
install_home="$tmp/installed"; mkdir -p "$install_home/bin"
PATH="$install_home/bin:$PATH" SINGULAR_HOME="$install_home" bash "$ROOT/install.sh" >/dev/null
installed="$(cd "$install_home/current" && pwd -P)"
[[ -f "$installed/vendor/singular-brain/engine/cli.mjs" ]] || fail "installed producer missing"
[[ -f "$installed/engine/brain_documents.py" ]] || fail "installed consumer missing"
( cd "$invoke" && env -u SINGULAR_ENGINE_HOME SINGULAR_HOME="$install_home" \
    SINGULAR_JSON_CONFIG_FILE="$consumer/config/singular.json" \
    bash "$install_home/bin/singular" manifest gen >/dev/null )
( cd "$invoke" && python3 "$installed/engine/brain_documents.py" normalize \
    --config "$consumer/config/singular.json" >/dev/null )

echo "brain ingestion e2e tests passed"
