#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
FIXTURE="$ENGINE_HOME/tests/fixtures/brain-manifest-consumer"

# Consumer tests must not inherit campaign configuration, Git selectors, state,
# or provider commands. Ordinary executable discovery remains available.
while IFS= read -r inherited_name; do unset "$inherited_name"; done \
  < <(compgen -v | grep '^SINGULAR_' || true)
unset inherited_name
while IFS= read -r inherited_name; do unset "$inherited_name"; done \
  < <(compgen -v | grep '^GIT_' || true)
unset inherited_name

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-brain-consumer.XXXXXX")"
if [[ "${KEEP_BRAIN_TMP:-0}" == "1" ]]; then
  echo "brain manifest consumer tmp: $tmp" >&2
else
  trap 'rm -rf "$tmp"' EXIT
fi

mkdir -p "$tmp/config with spaces/nested/output" "$tmp/unrelated-cwd" \
  "$tmp/fixture-root/.singular-state" "$tmp/fixture-root/docs/orchestration/tasks"
cp -R "$FIXTURE/corpus" "$tmp/config with spaces/corpus"
cp "$FIXTURE/expected/KNOWLEDGE.json" "$tmp/config with spaces/nested/output/KNOWLEDGE.json"

cat >"$tmp/stub-provider.sh" <<'SH'
#!/usr/bin/env bash
echo "unexpected default provider invocation" >&2
exit 97
SH
chmod +x "$tmp/stub-provider.sh"
export SINGULAR_ROOT="$tmp/fixture-root"
export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
export SINGULAR_ENGINE_DIR="$ENGINE_HOME/engine"
export SINGULAR_SCHEMA_DIR="$ENGINE_HOME/schemas"
export SINGULAR_STATE_DIR="$tmp/fixture-root/.singular-state"
export SINGULAR_ORCH_DIR="$tmp/fixture-root/docs/orchestration"
export SINGULAR_TASKS_DIR="$tmp/fixture-root/docs/orchestration/tasks"
export SINGULAR_CONFIG_FILE="$tmp/fixture-root/no-shell-config"
export SINGULAR_LOCAL_CONFIG_FILE="$tmp/fixture-root/no-local-config"
export SINGULAR_TARGET_BRANCH=fixture-target
export SINGULAR_RUNNER="$tmp/stub-provider.sh"
export SINGULAR_CODEX_RUNNER="$tmp/stub-provider.sh"

config="$tmp/config with spaces/singular.config.json"
cat >"$config" <<'JSON'
{
  "contextManifest": {
    "format": "singular-brain.manifest.v1",
    "manifest": "nested/output/KNOWLEDGE.json",
    "sourceId": "fixture-upstream-0.2.0",
    "expectedScope": "knowledge",
    "sourceRoot": "corpus",
    "select": [
      "notes/decision-log.md",
      "skills/example-skill/SKILL.md"
    ]
  }
}
JSON
cat >"$tmp/unrelated-cwd/singular.config.json" <<'JSON'
{"contextManifest":"wrong-default-manifest.json"}
JSON

# Meaningful initial contract: drive the existing authored configuration entry
# point from an unrelated cwd. Explicit selection, not loadWhen token matching,
# must render bytes from the declared source root.
rendered="$({ cd "$tmp/unrelated-cwd"; SINGULAR_ROOT="$SINGULAR_ROOT" \
  SINGULAR_ENGINE_HOME="$SINGULAR_ENGINE_HOME" SINGULAR_ENGINE_DIR="$SINGULAR_ENGINE_DIR" \
  SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" SINGULAR_ORCH_DIR="$SINGULAR_ORCH_DIR" \
  SINGULAR_TASKS_DIR="$SINGULAR_TASKS_DIR" SINGULAR_CONFIG_FILE="$SINGULAR_CONFIG_FILE" \
  SINGULAR_LOCAL_CONFIG_FILE="$SINGULAR_LOCAL_CONFIG_FILE" SINGULAR_TARGET_BRANCH="$SINGULAR_TARGET_BRANCH" \
  SINGULAR_RUNNER="$SINGULAR_RUNNER" SINGULAR_CTX_MANIFEST=1 \
  SINGULAR_JSON_CONFIG_FILE="$config" bash -c \
  'source "'"$LIB"'"; singular_ctx_rehydrate_authored_config_render implementer'; })"
grep -qF 'Durable decisions live here.' <<<"$rendered" \
  || fail "explicit brain selection did not reach authored config rendering"
grep -qF 'Body content that is not part of routing metadata.' <<<"$rendered" \
  || fail "claude-skill without loadWhen was not explicitly selected"

# Captured producer bytes and provenance are immutable and self-verifying.
python3 - "$FIXTURE" <<'PY' || fail "captured upstream provenance mismatch"
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
p = json.loads((root / "CAPTURE-PROVENANCE.json").read_text())
assert p["version"] == "0.2.0"
assert p["commit"] == "e05f259be5cabda2bb8caa241f23cc1f48e9f059"
for rel, expected in p["files"].items():
    actual = "sha256:" + hashlib.sha256((root / rel).read_bytes()).hexdigest()
    assert actual == expected, (rel, actual, expected)
PY

# The direct interface is deterministic and exposes separate review/integrity
# hashes, roots, identities, eligibility, provenance, and explicit selection.
norm_a="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$config")"
norm_b="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$config")"
[[ "$norm_a" == "$norm_b" ]] || fail "normalization is not deterministic"
python3 - "$norm_a" "$tmp/config with spaces" <<'PY' || fail "normalized contract mismatch"
import json, pathlib, sys
obj = json.loads(sys.argv[1]); root = pathlib.Path(sys.argv[2])
assert obj["schema"] == "singular.context.brain-documents.v1"
assert obj["format"] == "singular-brain.manifest.v1"
assert obj["sourceId"] == "fixture-upstream-0.2.0" and obj["scope"] == "knowledge"
assert obj["declaredSourceRoot"] == str(root / "corpus")
assert obj["resolvedSourceRoot"] == str((root / "corpus").resolve())
assert obj["manifestPath"] == str(root / "nested/output/KNOWLEDGE.json")
assert obj["manifestSha256"] == "sha256:45ea5a419beed4fbc6fd04c4d1d1fdde3ffdaeee2f133191fd5323c433304423"
docs = {d["artifactPath"]: d for d in obj["documents"]}
assert sorted(docs) == ["handoffs/session-2026-07-05.md", "notes/decision-log.md", "skills/example-skill/SKILL.md"]
decision = docs["notes/decision-log.md"]
assert decision["artifactId"] == "fixture-upstream-0.2.0:knowledge:notes/decision-log.md"
assert decision["included"] and decision["eligible"] and decision["selected"]
assert decision["integrity"]["liveSourceSha256"] == "sha256:06c6956d853f8307596ca9a38abace571d62821c569575957a5bca2a209e0153"
assert decision["review"]["bodyHash"] == "sha256:255a56a36c44c5b8ae31f6444780f47941e408de3f77031dccda58e64eb23758"
assert decision["review"]["bodyMatches"] and decision["review"]["metaMatches"]
assert decision["integrity"]["liveSourceSha256"] != decision["review"]["bodyHash"]
assert decision["provenance"]["approval"] == "unknown"
assert decision["provenance"]["authoritative"] is False and decision["provenance"]["hostVerified"] is False
skill = docs["skills/example-skill/SKILL.md"]
assert skill["loadWhen"] == [] and skill["included"]
handoff = docs["handoffs/session-2026-07-05.md"]
assert handoff["eligible"] and not handoff["selected"] and not handoff["included"]
PY

# Validate the emitted object against the committed schema with the small
# standard-library subset of JSON Schema used by this contract.
python3 - "$norm_a" "$ENGINE_HOME/schemas/brain-documents.v1.schema.json" <<'PY' \
  || fail "normalized output does not conform to brain-documents.v1 schema"
import json, re, sys
value=json.loads(sys.argv[1]); root=json.load(open(sys.argv[2]))
def check(schema, obj, path="$", root_schema=root):
    if "$ref" in schema:
        target=root_schema
        for part in schema["$ref"].removeprefix("#/").split("/"):
            target=target[part]
        return check(target,obj,path,root_schema)
    if "oneOf" in schema:
        matches=0
        for candidate in schema["oneOf"]:
            try: check(candidate,obj,path,root_schema); matches+=1
            except AssertionError: pass
        assert matches==1, (path,"oneOf",matches)
        return
    if "const" in schema: assert obj==schema["const"], (path,obj,schema["const"])
    if "enum" in schema: assert obj in schema["enum"], (path,obj,schema["enum"])
    types=schema.get("type")
    if types:
        types=[types] if isinstance(types,str) else types
        match={"object":lambda v:isinstance(v,dict),"array":lambda v:isinstance(v,list),
               "string":lambda v:isinstance(v,str),"boolean":lambda v:isinstance(v,bool),
               "null":lambda v:v is None,"integer":lambda v:isinstance(v,int) and not isinstance(v,bool)}
        assert any(match[t](obj) for t in types), (path,type(obj).__name__,types)
    if isinstance(obj,str):
        assert len(obj)>=schema.get("minLength",0), (path,"minLength")
        if "pattern" in schema: assert re.search(schema["pattern"],obj), (path,"pattern")
    if isinstance(obj,list) and "items" in schema:
        for i,item in enumerate(obj): check(schema["items"],item,f"{path}[{i}]",root_schema)
    if isinstance(obj,dict):
        for key in schema.get("required",[]): assert key in obj, (path,"required",key)
        props=schema.get("properties",{})
        if schema.get("additionalProperties") is False:
            assert not (set(obj)-set(props)), (path,"additional",sorted(set(obj)-set(props)))
        for key,item in obj.items():
            if key in props: check(props[key],item,f"{path}.{key}",root_schema)
            elif isinstance(schema.get("additionalProperties"),dict):
                check(schema["additionalProperties"],item,f"{path}.{key}",root_schema)
check(root,value)
PY

projected="$({ SINGULAR_CTX_MANIFEST=1 SINGULAR_JSON_CONFIG_FILE="$config" \
  bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_authored_config_manifest irrelevant-token'; })"
python3 - "$projected" <<'PY' || fail "authored event projection mismatch"
import json, sys
obj=json.loads(sys.argv[1]); sources={s["id"]:s for s in obj["sources"]}
assert obj["schema"] == "singular.orchestration.ctx-rehydrate-authored-manifest.v0"
assert sorted(sources) == ["fixture-upstream-0.2.0:knowledge:notes/decision-log.md", "fixture-upstream-0.2.0:knowledge:skills/example-skill/SKILL.md"]
assert sources["fixture-upstream-0.2.0:knowledge:notes/decision-log.md"]["sha256"] == "06c6956d853f8307596ca9a38abace571d62821c569575957a5bca2a209e0153"
assert all(s["authoritative"] is False and s["class"] == "authored-knowledge" for s in sources.values())
PY

capped="$({ SINGULAR_CTX_MANIFEST=1 SINGULAR_CONTEXT_SECTION_MAX_CHARS=120 \
  SINGULAR_JSON_CONFIG_FILE="$config" bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_authored_config_render'; })"
grep -qF '[authored-knowledge -- not authoritative]' <<<"$capped" || fail "reference-only marker missing"
grep -qF '[... authored section truncated to fit the context budget ...]' <<<"$capped" || fail "section cap missing"

make_config() {
  local path="$1" manifest="$2" root="$3" select_json="$4" scope="${5:-knowledge}"
  python3 - "$path" "$manifest" "$root" "$select_json" "$scope" <<'PY'
import json, sys
path, manifest, root, selected, scope = sys.argv[1:]
obj={"contextManifest":{"format":"singular-brain.manifest.v1","manifest":manifest,
 "sourceId":"test-source","expectedScope":scope,"sourceRoot":root,"select":json.loads(selected)}}
open(path,"w",encoding="utf-8").write(json.dumps(obj))
PY
}

expect_normalize_fail() {
  local cfg="$1" needle="$2" err="$tmp/error.log"
  if python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$cfg" >"$tmp/unexpected.json" 2>"$err"; then
    fail "expected normalization failure containing: $needle"
  fi
  grep -qF "$needle" "$err" || fail "diagnostic missing '$needle': $(cat "$err")"
  [[ ! -s "$tmp/unexpected.json" ]] || fail "invalid input emitted a partial successful packet"
}

# Unresolved selections remain observable and never become implicit selection.
unresolved_cfg="$tmp/config with spaces/unresolved.json"
make_config "$unresolved_cfg" "nested/output/KNOWLEDGE.json" "corpus" '["not-present.md"]'
unresolved="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$unresolved_cfg")"
python3 - "$unresolved" <<'PY' || fail "unresolved selection reason mismatch"
import json,sys
o=json.loads(sys.argv[1]); s=o["selection"][0]
assert s["requestedPath"]=="not-present.md" and not s["included"] and s["exclusionReasons"]==["not_in_manifest"]
assert not any(d["included"] for d in o["documents"])
PY

# Valid tier-2 producer shape is accepted but conservatively excluded because
# review and lifecycle are unknown; statusHint cannot grant current eligibility.
tier_root="$tmp/tier2"; mkdir -p "$tier_root/corpus" "$tier_root/out"
printf '# Legacy\n\nTier two prose.\n' >"$tier_root/corpus/legacy.md"
cat >"$tier_root/out/manifest.json" <<'JSON'
{"schema":"singular-brain.manifest.v1","scope":"knowledge","title":"Tier 2",
 "entries":[{"path":"legacy.md","section":"legacy","adapter":"markdown-doc","tier":2,
 "title":"Legacy","excerpt":"Tier two prose.","statusHint":{"status":"canonical"},"updated":"2026-01-02"}]}
JSON
make_config "$tier_root/config.json" "out/manifest.json" "corpus" '["legacy.md"]'
tier_norm="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$tier_root/config.json")"
python3 - "$tier_norm" <<'PY' || fail "tier-2 conservative policy mismatch"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]
assert d["tier"]==2 and d["statusHint"]=={"status":"canonical"}
assert d["review"]["state"]=="unknown" and d["lifecycle"]["state"]=="unknown"
assert not d["included"] and d["exclusionReasons"]==["review_unknown","lifecycle_unknown"]
PY

# Malformed top-level/entry data, unsupported contracts, scope mismatch, and
# duplicate identities are actionable fatal errors.
invalid_root="$tmp/invalid"; mkdir -p "$invalid_root/corpus" "$invalid_root/out"
cp "$FIXTURE/corpus/notes/decision-log.md" "$invalid_root/corpus/doc.md"
make_config "$invalid_root/config.json" "out/manifest.json" "corpus" '["doc.md"]'
write_invalid_manifest() {
  local mutation="$1"
  python3 - "$FIXTURE/expected/KNOWLEDGE.json" "$invalid_root/out/manifest.json" "$mutation" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1])); obj["entries"]=[obj["entries"][1]]; obj["entries"][0]["path"]="doc.md"
mutation=sys.argv[3]
if mutation=="schema": obj["schema"]="unknown.v9"
elif mutation=="adapter": obj["entries"][0]["adapter"]="guessed-adapter"
elif mutation=="tier": obj["entries"][0]["tier"]="1"
elif mutation=="entries": obj["entries"]={}
elif mutation=="tier2-updated":
    obj["entries"][0]={"path":"doc.md","section":"legacy","adapter":"markdown-doc","tier":2,"title":"Legacy","updated":[]}
elif mutation=="entry-extra": obj["entries"][0]["invented"]="guess-me"
elif mutation=="top-extra": obj["invented"]="guess-me"
elif mutation=="duplicate": obj["entries"].append(dict(obj["entries"][0]))
elif mutation=="scope": obj["scope"]="other"
json.dump(obj,open(sys.argv[2],"w"))
PY
}
for case_info in 'schema|manifest.schema' 'adapter|adapter is unsupported' 'tier|tier must be integer' \
  'entries|manifest.entries must be an array' 'tier2-updated|updated must be a string' \
  'entry-extra|unexpected field(s): invented' 'top-extra|manifest has unknown field(s): invented' \
  'duplicate|duplicate manifest artifact path'; do
  case_name="${case_info%%|*}"; needle="${case_info#*|}"
  write_invalid_manifest "$case_name"; expect_normalize_fail "$invalid_root/config.json" "$needle"
done
write_invalid_manifest scope
expect_normalize_fail "$invalid_root/config.json" 'manifest.scope mismatch'

# Live tier-1 markdown is parsed with the producer's strict frontmatter rules.
# A malformed routing block introduced after generation must not remain eligible
# merely because the recognized routing fields and body still hash the same.
python3 - "$FIXTURE/expected/KNOWLEDGE.json" "$invalid_root/out/manifest.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); o["entries"]=[o["entries"][1]]; o["entries"][0]["path"]="doc.md"; json.dump(o,open(sys.argv[2],"w"))
PY
python3 - "$invalid_root/corpus/doc.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace("status: canonical", "status: canonical\nmalformed field: value"); open(p,"w").write(s)
PY
expect_normalize_fail "$invalid_root/config.json" 'source frontmatter parse error'
cp "$FIXTURE/corpus/notes/decision-log.md" "$invalid_root/corpus/doc.md"

# Descriptor field names and types are strict; object validation never falls
# back to the legacy parser. OFF mode does not inspect configured sources.
cat >"$invalid_root/bad-descriptor.json" <<'JSON'
{"contextManifest":{"path":"out/manifest.json","sourceRoot":"corpus","select":[]}}
JSON
if SINGULAR_CTX_MANIFEST=1 SINGULAR_JSON_CONFIG_FILE="$invalid_root/bad-descriptor.json" \
  bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_authored_config_render' \
  >"$tmp/bad-object.out" 2>"$tmp/bad-object.err"; then
  fail "malformed object descriptor unexpectedly succeeded"
fi
grep -qF 'contextManifest missing required field' "$tmp/bad-object.err" || fail "malformed object diagnostic missing"
[[ ! -s "$tmp/bad-object.out" ]] || fail "malformed object fell back to legacy rendering"
off_out="$(SINGULAR_CTX_MANIFEST=0 SINGULAR_JSON_CONFIG_FILE="$invalid_root/bad-descriptor.json" \
  bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_authored_config_render')"
[[ -z "$off_out" ]] || fail "feature-off path inspected/rendered brain sources"

# Unsafe entry paths and escaping symlinks are fatal. A single in-root symlink is
# allowed and identified by its canonical target; aliases that collide are fatal.
write_path_manifest() {
  local path_value="$1" include_direct="${2:-no}"
  python3 - "$FIXTURE/expected/KNOWLEDGE.json" "$invalid_root/out/manifest.json" "$path_value" "$include_direct" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1])); e=obj["entries"][1]; e["path"]=sys.argv[3]; obj["entries"]=[e]
if sys.argv[4]=="yes":
    other=dict(e); other["path"]="doc.md"; obj["entries"].append(other)
json.dump(obj,open(sys.argv[2],"w"))
PY
}
for unsafe in '../doc.md' '/tmp/doc.md'; do
  write_path_manifest "$unsafe"; expect_normalize_fail "$invalid_root/config.json" 'must be a canonical relative path'
done
printf 'outside\n' >"$tmp/outside.md"; ln -s "$tmp/outside.md" "$invalid_root/corpus/escape.md"
write_path_manifest 'escape.md'; expect_normalize_fail "$invalid_root/config.json" 'resolves outside contextManifest.sourceRoot'
ln -s "doc.md" "$invalid_root/corpus/alias.md"
write_path_manifest 'alias.md'
alias_norm="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$invalid_root/config.json")"
python3 - "$alias_norm" <<'PY' || fail "in-root symlink policy mismatch"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]
assert d["artifactPath"]=="alias.md" and d["canonicalPath"]=="doc.md"
assert d["artifactId"].endswith(":knowledge:doc.md")
PY
write_path_manifest 'alias.md' yes
expect_normalize_fail "$invalid_root/config.json" 'canonical source collision'

# Declared and resolved quarantine markers independently exclude selected bytes.
quarantine_root="$tmp/quarantine"; mkdir -p "$quarantine_root/corpus" "$quarantine_root/out"
cp "$FIXTURE/corpus/notes/decision-log.md" "$quarantine_root/corpus/doc.md"
python3 - "$FIXTURE/expected/KNOWLEDGE.json" "$quarantine_root/out/manifest.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); o["entries"]=[o["entries"][1]]; o["entries"][0]["path"]="doc.md"; json.dump(o,open(sys.argv[2],"w"))
PY
make_config "$quarantine_root/config.json" "out/manifest.json" "corpus" '["doc.md"]'
: >"$quarantine_root/corpus/doc.md.quarantined"
qnorm="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$quarantine_root/config.json")"
python3 - "$qnorm" <<'PY' || fail "declared quarantine was not enforced"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]
assert not d["included"] and "declared_path_quarantined" in d["exclusionReasons"] and "resolved_source_quarantined" in d["exclusionReasons"]
PY
mkdir -p "$quarantine_root/corpus/real"
cp "$FIXTURE/corpus/notes/decision-log.md" "$quarantine_root/corpus/real/target.md"
: >"$quarantine_root/corpus/real/target.md.quarantined"
ln -s "real/target.md" "$quarantine_root/corpus/alias.md"
python3 - "$FIXTURE/expected/KNOWLEDGE.json" "$quarantine_root/out/manifest.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); o["entries"]=[o["entries"][1]]; o["entries"][0]["path"]="alias.md"; json.dump(o,open(sys.argv[2],"w"))
PY
make_config "$quarantine_root/config.json" "out/manifest.json" "corpus" '["alias.md"]'
qnorm="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$quarantine_root/config.json")"
python3 - "$qnorm" <<'PY' || fail "resolved quarantine was not enforced"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]
assert not d["included"] and "resolved_source_quarantined" in d["exclusionReasons"] and "declared_path_quarantined" not in d["exclusionReasons"]
PY

# BOM stripping, CRLF normalization, and exact frontmatter boundaries match the
# producer's review-body semantics; raw-byte integrity remains separate.
review_root="$tmp/review"; mkdir -p "$review_root/corpus" "$review_root/out"
python3 - "$review_root" <<'PY'
import hashlib,json,pathlib,sys
r=pathlib.Path(sys.argv[1]); raw=b'\xef\xbb\xbf---\r\nstatus: canonical\r\ndescription: Route me.\r\nload-when:\r\n  - human phrase\r\n---\r\n\r\n# Reviewed\r\n\r\nBody.\r\n'
(r/'corpus/reviewed.md').write_bytes(raw)
h=lambda b:'sha256:'+hashlib.sha256(b).hexdigest()
entry={"path":"reviewed.md","section":"test","adapter":"markdown-doc","tier":1,"title":"Reviewed","status":"canonical","description":"Route me.","loadWhen":["human phrase"],"freshness":{"state":"clean","meta":h(b'Route me.\nhuman phrase'),"body":h(b'\n# Reviewed\n\nBody.\n')}}
json.dump({"schema":"singular-brain.manifest.v1","scope":"knowledge","title":"Review","entries":[entry]},open(r/'out/manifest.json','w'))
PY
make_config "$review_root/config.json" "out/manifest.json" "corpus" '["reviewed.md"]'
review_norm="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$review_root/config.json")"
python3 - "$review_norm" <<'PY' || fail "review normalization semantics mismatch"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]
assert d["included"] and d["review"]["metaMatches"] and d["review"]["bodyMatches"]
assert d["integrity"]["liveSourceSha256"] != d["review"]["bodyHash"]
PY
printf '\nTAMPERED\n' >>"$review_root/corpus/reviewed.md"
tampered="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$review_root/config.json")"
python3 - "$tampered" <<'PY' || fail "body tampering was not detected"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]
assert not d["included"] and "review_body_mismatch" in d["exclusionReasons"] and d["review"]["state"]=="clean"
PY

# Nested unverified state, supersession, and source-side lifecycle/routing drift
# all prevent current inclusion without changing or blessing producer output.
drift_root="$tmp/drift"; mkdir -p "$drift_root/corpus" "$drift_root/out"
cp "$FIXTURE/corpus/notes/decision-log.md" "$drift_root/corpus/doc.md"
python3 - "$FIXTURE/expected/KNOWLEDGE.json" "$drift_root/out/manifest.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); o["entries"]=[o["entries"][1]]; o["entries"][0]["path"]="doc.md"; json.dump(o,open(sys.argv[2],"w"))
PY
make_config "$drift_root/config.json" "out/manifest.json" "corpus" '["doc.md"]'
python3 - "$drift_root/out/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; o=json.load(open(p)); o["entries"][0]["freshness"]["state"]="description_unverified"; json.dump(o,open(p,"w"))
PY
dout="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$drift_root/config.json")"
python3 - "$dout" <<'PY' || fail "nested unverified state was not excluded"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]; assert "review_description_unverified" in d["exclusionReasons"] and not d["included"]
PY
python3 - "$drift_root/out/manifest.json" "$FIXTURE/expected/KNOWLEDGE.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[2])); o["entries"]=[o["entries"][1]]; e=o["entries"][0]; e["path"]="doc.md"; e["status"]="superseded"; json.dump(o,open(sys.argv[1],"w"))
PY
python3 - "$drift_root/corpus/doc.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace("status: canonical","status: superseded"); open(p,"w").write(s)
PY
dout="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$drift_root/config.json")"
python3 - "$dout" <<'PY' || fail "superseded lifecycle was not excluded"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]; assert d["lifecycle"]["state"]=="superseded" and "lifecycle_superseded" in d["exclusionReasons"] and not d["included"]
PY
cp "$FIXTURE/corpus/notes/decision-log.md" "$drift_root/corpus/doc.md"
python3 - "$FIXTURE/expected/KNOWLEDGE.json" "$drift_root/out/manifest.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); o["entries"]=[o["entries"][1]]; o["entries"][0]["path"]="doc.md"; json.dump(o,open(sys.argv[2],"w"))
PY
python3 - "$drift_root/corpus/doc.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace("status: canonical","status: draft"); open(p,"w").write(s)
PY
dout="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$drift_root/config.json")"
python3 - "$dout" <<'PY' || fail "source lifecycle drift was not detected"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]; assert "lifecycle_metadata_changed" in d["exclusionReasons"] and not d["included"]
PY
cp "$FIXTURE/corpus/notes/decision-log.md" "$drift_root/corpus/doc.md"
python3 - "$drift_root/corpus/doc.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace("Running log of durable decisions and their rationale.","Changed routing description."); open(p,"w").write(s)
PY
dout="$(python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$drift_root/config.json")"
python3 - "$dout" <<'PY' || fail "source routing drift was not detected"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]; assert "routing_metadata_changed" in d["exclusionReasons"] and not d["included"]
PY

# A missing declared source never falls back to an identically named cwd file.
missing_root="$tmp/missing"; mkdir -p "$missing_root/corpus" "$missing_root/out" "$missing_root/cwd"
printf 'WRONG CWD CONTENT\n' >"$missing_root/cwd/doc.md"
cp "$drift_root/out/manifest.json" "$missing_root/out/manifest.json"
make_config "$missing_root/config.json" "out/manifest.json" "corpus" '["doc.md"]'
missing_norm="$({ cd "$missing_root/cwd"; python3 "$ENGINE_HOME/engine/brain_documents.py" normalize --config "$missing_root/config.json"; })"
python3 - "$missing_norm" <<'PY' || fail "missing source used a cwd fallback"
import json,sys
d=json.loads(sys.argv[1])["documents"][0]; assert d["resolvedSourcePath"] is None and d["integrity"]["liveSourceSha256"] is None and "missing_source" in d["exclusionReasons"]
PY

# Exercise the real l1 driver with a disposable Git repository and one hermetic
# provider executable used for worker and auditor roles. The first audit requests
# repair; window pressure then selects rehydrate for attempt two.
driver_root="$tmp/driver repo"
mkdir -p "$driver_root/docs/orchestration/prompts" "$driver_root/docs/orchestration/tasks" \
  "$driver_root/.singular-state" "$driver_root/internal/widget" "$driver_root/brain/out"
cp -R "$FIXTURE/corpus" "$driver_root/brain/corpus"
cp "$FIXTURE/expected/KNOWLEDGE.json" "$driver_root/brain/out/KNOWLEDGE.json"
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$driver_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$driver_root/docs/orchestration/prompts/auditor.md"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' >"$driver_root/docs/orchestration/prompts/decider.md"
cat >"$driver_root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Generic widget parser

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the widget parser.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Parser handles empty input.
EOF
cat >"$driver_root/valid.config.json" <<'JSON'
{
  "contextManifest": {
    "format": "singular-brain.manifest.v1",
    "manifest": "brain/out/KNOWLEDGE.json",
    "sourceId": "fixture-upstream-0.2.0",
    "expectedScope": "knowledge",
    "sourceRoot": "brain/corpus",
    "select": ["notes/decision-log.md", "skills/example-skill/SKILL.md"]
  }
}
JSON
cp "$driver_root/valid.config.json" "$driver_root/singular.config.json"

git -C "$driver_root" init -q
git -C "$driver_root" config user.email fixture@example.invalid
git -C "$driver_root" config user.name fixture
git -C "$driver_root" checkout -q -b target
git -C "$driver_root" add .
git -C "$driver_root" commit -qm fixture

driver_runner="$tmp/driver-stub-provider.sh"
cat >"$driver_runner" <<SH
#!/usr/bin/env bash
set -uo pipefail
source "$ENGINE_HOME/engine/lib.sh"
level=""; worktree=""; out=""; meta=""; resume="none"
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    --level) level="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    -C|--worktree) worktree="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --output-last-message) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --session-meta) meta="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --resume-session) resume="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ "\$level" == "l2" ]]; then
  c=0; [[ -f "\$DRIVER_L2_COUNT" ]] && c="\$(cat "\$DRIVER_L2_COUNT")"
  c=\$((c+1)); printf '%s\n' "\$c" >"\$DRIVER_L2_COUNT"
  if [[ "\$c" == "2" ]]; then [[ -n "\$out" ]] && : >"\$out"; exit 0; fi
  mkdir -p "\$worktree/internal/widget"
  printf 'package widget\n' >"\$worktree/internal/widget/parser.go"
  [[ -n "\$out" ]] && cat >"\$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  [[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" WORKER-SID gpt-5.5 medium "\$worktree" 0
  exit 0
fi
ac=0; [[ -f "\$DRIVER_AUDIT_COUNT" ]] && ac="\$(cat "\$DRIVER_AUDIT_COUNT")"
ac=\$((ac+1)); printf '%s\n' "\$ac" >"\$DRIVER_AUDIT_COUNT"
[[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" REVIEWER-SID gpt-5.5 high "\$worktree" 0
if [[ "\$ac" == "1" ]]; then
  if [[ "\${EMPTY_DURABLE:-0}" == "1" ]]; then
    rd="\$(dirname "\$meta")"
    for name in packet.json implementer-capsule.json reviewer-capsule.json findings-status.json assumptions-ledger.json plan-critique.json; do
      : >"\$rd/\$name.quarantined"
    done
  fi
  [[ -n "\$out" ]] && printf '%s\n' '{"verdict":"needs-fix","findings":[{"summary":"fix it"}]}' >"\$out"
else
  [[ -n "\$out" ]] && printf '%s\n' '{"verdict":"accepted","findings":[]}' >"\$out"
fi
exit 0
SH
chmod +x "$driver_runner"

# Exercise the current L1 bytes while replacing only the host-owned Unix-socket
# evidence broker. The managed test sandbox forbids AF_UNIX bind; this local
# pass-through preserves the runner argv and keeps provider execution hermetic.
driver_engine="$tmp/driver-engine"
mkdir -p "$driver_engine"
cp -R "$ENGINE_HOME/engine" "$driver_engine/engine"
cp -R "$ENGINE_HOME/schemas" "$driver_engine/schemas"
cp "$ENGINE_HOME/VERSION" "$ENGINE_HOME/SCHEMA_VERSION" "$driver_engine/"
cat >"$driver_engine/engine/evidence_delivery.py" <<'PY'
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
try:
    marker = args.index("--")
except ValueError:
    raise SystemExit(2)
os.execv(args[marker + 1], args[marker + 1:])
PY
chmod +x "$driver_engine/engine/evidence_delivery.py"

reset_driver() {
  git -C "$driver_root" checkout -q target 2>/dev/null || true
  rm -rf "$driver_root/.singular-state/runs" "$driver_root/.singular-state/leases" \
    "$driver_root/.singular-state/inbox" "$driver_root/.singular-state/review-policy" \
    "$driver_root/.worktrees"
  mkdir -p "$driver_root/.singular-state"
  : >"$driver_root/.singular-state/events.ndjson"
  rm -f "$driver_root/docs/orchestration/decisions.md" "$tmp/driver-l2-count" "$tmp/driver-audit-count"
  python3 - "$driver_root/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import re,sys
p=sys.argv[1]; text=open(p).read(); open(p,"w").write(re.sub(r"Status: \w+", "Status: ready", text, count=1))
PY
  git -C "$driver_root" worktree prune 2>/dev/null || true
  git -C "$driver_root" branch -D agent/widget/TASK-0001-generic >/dev/null 2>&1 || true
}

run_driver() {
  (cd "$driver_root" && env -i PATH="$PATH" HOME="$tmp/driver-home" TMPDIR="${TMPDIR:-/tmp}" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    SINGULAR_ROOT="$driver_root" SINGULAR_ENGINE_HOME="$driver_engine" \
    SINGULAR_ENGINE_DIR="$driver_engine/engine" SINGULAR_SCHEMA_DIR="$driver_engine/schemas" \
    SINGULAR_STATE_DIR="$driver_root/.singular-state" \
    SINGULAR_ORCH_DIR="$driver_root/docs/orchestration" \
    SINGULAR_TASKS_DIR="$driver_root/docs/orchestration/tasks" \
    SINGULAR_JSON_CONFIG_FILE="$driver_root/singular.config.json" \
    SINGULAR_CONFIG_FILE="$driver_root/no-shell-config" \
    SINGULAR_LOCAL_CONFIG_FILE="$driver_root/no-local-config" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$driver_runner" \
    SINGULAR_CODEX_RUNNER="$driver_runner" SINGULAR_MAX_RETRIES=1 \
    SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_CTX_MANIFEST=1 \
    SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
    DRIVER_L2_COUNT="$tmp/driver-l2-count" DRIVER_AUDIT_COUNT="$tmp/driver-audit-count" \
    EMPTY_DURABLE="${EMPTY_DURABLE:-0}" \
    "$driver_engine/engine/l1-drive.sh" TASK-0001)
}

run_dir_of() { find "$driver_root/.singular-state/runs" -mindepth 1 -maxdepth 1 -type d -name 'RUN-*' | head -1; }

# The real event builder also preserves selected authored provenance when its
# durable source directory is empty; no consumer or rehydrate function is stubbed.
mkdir -p "$tmp/empty-durable"
empty_event="$(SINGULAR_CTX_MANIFEST=1 SINGULAR_JSON_CONFIG_FILE="$config" \
  bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_event_data implementer TASK-EMPTY RUN-EMPTY 2 empty "$1"' _ "$tmp/empty-durable")" \
  || fail "real event builder rejected valid brain content with empty durable packet"
python3 - "$empty_event" "$projected" <<'PY' || fail "empty durable event lost brain provenance"
import json,sys
event=json.loads(sys.argv[1]); expected=json.loads(sys.argv[2])
assert event["manifest"]["sources"] == []
assert event["manifest"]["authored"] == expected
PY

# Valid configured content reaches the second worker prompt and the event records
# the same selected identities and live raw-byte hashes.
reset_driver
run_driver >"$tmp/driver-valid.log" 2>&1 || true
[[ "$(cat "$tmp/driver-l2-count" 2>/dev/null || echo 0)" == "2" ]] || {
  cat "$tmp/driver-valid.log" >&2
  find "$driver_root/.singular-state/runs" -name 'auditor-codex.log' -exec cat {} \; >&2
  fail "real driver did not reach rehydrate worker"
}
driver_run="$(run_dir_of)"; [[ -n "$driver_run" ]] || fail "real driver produced no run directory"
driver_prompt="$driver_run/l2-active-prompt.md"
grep -qF 'Durable decisions live here.' "$driver_prompt" || {
  cat "$tmp/driver-valid.log" >&2
  cat "$driver_root/.singular-state/events.ndjson" >&2
  sed -n '1,80p' "$driver_prompt" >&2
  fail "selected brain content did not reach real driver prompt"
}
grep -qF 'Body content that is not part of routing metadata.' "$driver_prompt" || fail "selected skill did not reach real driver prompt"
grep -qF '## Injected authored knowledge (reference material, NOT authoritative)' "$driver_prompt" || fail "real driver authored wrapper missing"
grep -qF '## Injected durable context' "$driver_prompt" || fail "real driver durable section missing"
python3 - "$driver_root/.singular-state/events.ndjson" <<'PY' || fail "real driver event brain provenance mismatch"
import json,sys
events=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
matches=[e["data"] for e in events if e.get("type")=="context.strategy_selected" and e.get("data",{}).get("strategy")=="rehydrate"]
assert matches
manifest=matches[-1]["manifest"]
assert manifest["sources"]
sources={s["id"]:s for s in manifest["authored"]["sources"]}
assert sources["fixture-upstream-0.2.0:knowledge:notes/decision-log.md"]["sha256"] == "06c6956d853f8307596ca9a38abace571d62821c569575957a5bca2a209e0153"
assert sources["fixture-upstream-0.2.0:knowledge:skills/example-skill/SKILL.md"]["sha256"] == "b973cf4c8a89baba3c19d1024f5822deecbe9338088e56d9309a19e680df6d26"
assert all(not source["authoritative"] for source in sources.values())
PY

# Exercise the same real-driver rehydrate path after every durable source has
# been quarantined by the first auditor. Authored selection must still reach the
# second worker, and its event must distinguish the empty durable source set
# from the independently selected authored references.
cp "$driver_root/valid.config.json" "$driver_root/singular.config.json"
reset_driver
EMPTY_DURABLE=1 run_driver >"$tmp/driver-empty-durable-valid.log" 2>&1 || true
[[ "$(cat "$tmp/driver-l2-count" 2>/dev/null || echo 0)" == "2" ]] \
  || fail "empty-durable real driver did not reach rehydrate worker"
driver_run="$(run_dir_of)"; [[ -n "$driver_run" ]] || fail "empty-durable real driver produced no run directory"
driver_prompt="$driver_run/l2-active-prompt.md"
grep -qF 'Durable decisions live here.' "$driver_prompt" \
  || {
    cat "$tmp/driver-empty-durable-valid.log" >&2
    cat "$driver_root/.singular-state/events.ndjson" >&2
    sed -n '1,100p' "$driver_prompt" >&2
    fail "selected brain content did not reach empty-durable real driver prompt"
  }
grep -qF 'Body content that is not part of routing metadata.' "$driver_prompt" \
  || fail "selected skill did not reach empty-durable real driver prompt"
grep -qF '## Injected authored knowledge (reference material, NOT authoritative)' "$driver_prompt" \
  || fail "empty-durable real driver authored wrapper missing"
if grep -qF '## Injected durable context' "$driver_prompt"; then
  fail "empty durable packet unexpectedly rendered a durable section"
fi
python3 - "$driver_root/.singular-state/events.ndjson" "$projected" <<'PY' \
  || fail "empty-durable real driver event provenance mismatch"
import json,sys
events=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
expected=json.loads(sys.argv[2])
matches=[e["data"] for e in events if e.get("type")=="context.strategy_selected" and e.get("data",{}).get("strategy")=="rehydrate"]
assert matches
manifest=matches[-1]["manifest"]
assert manifest["sources"] == []
assert manifest["authored"] == expected
sources={s["id"]:s for s in manifest["authored"]["sources"]}
assert sources["fixture-upstream-0.2.0:knowledge:notes/decision-log.md"]["sha256"] == "06c6956d853f8307596ca9a38abace571d62821c569575957a5bca2a209e0153"
assert sources["fixture-upstream-0.2.0:knowledge:skills/example-skill/SKILL.md"]["sha256"] == "b973cf4c8a89baba3c19d1024f5822deecbe9338088e56d9309a19e680df6d26"
PY

assert_driver_rejects() {
  local label="$1" needle="$2"
  reset_driver
  if run_driver >"$tmp/driver-$label.log" 2>&1; then
    fail "$label configured brain input unexpectedly completed"
  fi
  [[ "$(cat "$tmp/driver-l2-count" 2>/dev/null || echo 0)" == "1" ]] \
    || fail "$label configured brain input invoked the affected rehydrate worker"
  grep -qF "$needle" "$tmp/driver-$label.log" || fail "$label driver diagnostic missing: $(cat "$tmp/driver-$label.log")"
  grep -qF 'configured brain context validation failed before worker invocation' "$tmp/driver-$label.log" \
    || fail "$label driver failure was not truthfully classified"
}

# A malformed object and an unsafe entry each stop attempt two before the worker.
cat >"$driver_root/singular.config.json" <<'JSON'
{"contextManifest":{"path":"brain/out/KNOWLEDGE.json","sourceRoot":"brain/corpus","select":[]}}
JSON
assert_driver_rejects malformed 'contextManifest missing required field'
EMPTY_DURABLE=1 assert_driver_rejects malformed-empty-durable 'contextManifest missing required field'

python3 - "$FIXTURE/expected/KNOWLEDGE.json" "$driver_root/brain/out/unsafe.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); o["entries"]=[o["entries"][1]]; o["entries"][0]["path"]="../escape.md"; json.dump(o,open(sys.argv[2],"w"))
PY
cat >"$driver_root/singular.config.json" <<'JSON'
{"contextManifest":{"format":"singular-brain.manifest.v1","manifest":"brain/out/unsafe.json","sourceId":"unsafe","expectedScope":"knowledge","sourceRoot":"brain/corpus","select":["notes/decision-log.md"]}}
JSON
assert_driver_rejects unsafe 'must be a canonical relative path'
EMPTY_DURABLE=1 assert_driver_rejects unsafe-empty-durable 'must be a canonical relative path'

echo "brain manifest consumer tests passed"
