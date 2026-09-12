#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-context-e2e.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

while IFS= read -r inherited_name; do unset "$inherited_name"; done \
  < <(compgen -v | grep '^SINGULAR_' || true)
unset inherited_name

python3 -m unittest "$ROOT/tests/test_context_service.py"

project="$tmp/project with spaces"
cp -Rp "$ROOT/tests/fixtures/context-service" "$project"
invoke="$project/nested/invocation"
mkdir -p "$invoke"
python3 - "$project" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
late = root / "brain/notes/late-fact.md"
late.write_text(late.read_text(encoding="utf-8").replace(
    "## Late Operations", "padding " * 800 + "\n\n## Late Operations"
), encoding="utf-8")
code = root / "src/selected.py"
code.write_text(code.read_text(encoding="utf-8") +
                'LONG_VALUE = "' + ("é" * 3000) + ' UTF8-CLI-TAIL"\n',
                encoding="utf-8")
(root / "singular.config.json").write_text(json.dumps({
    "contextManifest": {
        "format": "singular-brain.manifest.v1",
        "manifest": "brain/generated/KNOWLEDGE.json",
        "sourceId": "e2e-brain",
        "expectedScope": "knowledge",
        "sourceRoot": "brain",
        "select": ["notes/late-fact.md"],
    },
    "contextService": {
        "enabled": True,
        "projectId": "e2e-project",
        "revision": "fixture-revision-1",
        "codePaths": ["src/selected.py"],
        "runRecordPaths": ["runs/RUN-fixture/runner-result.json"],
        "rolePolicy": {"implementer": ["brain", "code", "run"]},
    },
}, sort_keys=True), encoding="utf-8")
PY
git -C "$project" init -q
git -C "$project" -c user.name=test -c user.email=test@example.invalid \
  add .
git -C "$project" -c user.name=test -c user.email=test@example.invalid \
  commit -qm 'context service e2e fixture'

# Generate a real singular-brain manifest and freshness sidecar, then invoke
# every context operation through the public launcher from a nested cwd.
node "$ROOT/vendor/singular-brain/engine/cli.mjs" \
  --config "$project/brain/singular-brain.config.json" gen
context() {
  ( cd "$invoke" && SINGULAR_ENGINE_HOME="$ROOT" \
      SINGULAR_JSON_CONFIG_FILE="$project/singular.config.json" \
      bash "$ROOT/cli/singular" context "$@" )
}

search="$(context search --role implementer --query AURORA-TAIL-731 --max-bytes 600)"
read -r ref version < <(python3 -c 'import json,sys; d=json.load(sys.stdin); h=d["results"][0]; print(h["ref"], h["sourceSha256"]); assert d["identity"]["revision"] == "fixture-revision-1"' <<<"$search")
page="$(context get --role implementer --ref "$ref" --version "$version" --section "Late Operations" --max-bytes 600)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert "AURORA-TAIL-731" in d["text"]; assert d["range"]["startByte"] > 4000' <<<"$page"

code_search="$(context search --role implementer --query UTF8-CLI-TAIL --max-bytes 300)"
read -r code_ref code_version < <(python3 -c 'import json,sys; h=json.load(sys.stdin)["results"][0]; print(h["ref"], h["sourceSha256"])' <<<"$code_search")
code_page_one="$(context get --role implementer --ref "$code_ref" --version "$code_version" --max-bytes 257)"
code_cursor="$(python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["continuationCursor"].startswith("byte:"); print(d["continuationCursor"])' <<<"$code_page_one")"
code_page_two="$(context get --role implementer --ref "$code_ref" --version "$code_version" --cursor "$code_cursor" --max-bytes 257)"
python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.load(sys.stdin); assert a["range"]["endByte"] == b["range"]["startByte"]' "$code_page_one" <<<"$code_page_two"

bundle="$tmp/published/context-bundle.json"
context build --role implementer --phase implement --task "$project/task.md" \
  --query "cobalt rollback" --budget-bytes 10000 --output "$bundle" >/dev/null
context explain --role implementer --bundle "$bundle" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"] == "singular.context.explain.v1"; assert d["budget"]["usedBytes"] <= d["budget"]["limitBytes"]'
python3 - "$bundle" <<'PY'
import hashlib
import json
import pathlib
import sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert d["schema"] == "singular.context.bundle.v1"
assert "[violated] Never publish a partial prompt" in d["prompt"]
assert "[open] Verify the rollback latch" in d["prompt"]
assert d["promptSha256"] == "sha256:" + hashlib.sha256(d["prompt"].encode()).hexdigest()
assert d["budget"]["providerVisibleBytes"] is None
assert d["budget"]["unknownComponents"]
PY

set +e
context build --role implementer --phase implement --task "$project/task.md" \
  --budget-bytes 32 >/dev/null 2>"$tmp/overflow.err"
overflow_rc=$?
set -e
[[ "$overflow_rc" -eq 3 ]] && grep -q 'mandatory-overflow' "$tmp/overflow.err"

printf '\ntampered\n' >>"$project/brain/notes/late-fact.md"
set +e
context get --role implementer --ref "$ref" --version "$version" --max-bytes 100 \
  >/dev/null 2>"$tmp/tamper.err"
tamper_rc=$?
set -e
[[ "$tamper_rc" -eq 2 ]] && grep -Eq 'modified|wrong-version|ineligible|brain source is invalid' "$tmp/tamper.err"

echo "context service e2e tests passed"
