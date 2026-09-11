#!/usr/bin/env bash
# Shared host-side task-batch handling.
#
# Provider runners only return a final message. They never receive orchestration
# paths such as an L1 staging directory. These helpers recover a task-batch.v0
# envelope from that message, validate and materialize the complete candidate
# set in a private directory, and (for revision) transactionally replace the
# staged set only after every candidate passes validation.
#
# Return codes from singular_task_batch_materialize:
#   0  valid non-empty batch materialized
#   2  parseable batch failed schema/identity/task validation
#   3  no JSON object could be recovered
#   4  valid empty batch

# Resolve the authoritative candidate batch exactly once for a reader. New v2
# revision publications use an immutable generation selected by the atomically
# replaced .candidate-current.json pointer. Direct files are accepted only as a
# legacy, pre-publication fallback.
singular_task_batch_candidate_dir() {
  local stage_dir="${1:-}"
  [[ -d "$stage_dir" ]] || return 2
  if [[ ! -e "$stage_dir/.candidate-current.json" \
        && ! -e "$stage_dir/.candidate-generation-format" ]] \
     && ! find "$stage_dir" -maxdepth 1 -name 'TASK-*.candidate.md' -type f \
       -print -quit 2>/dev/null | grep -q .; then
    printf '%s\n' "$stage_dir"
    return 0
  fi
  python3 "$SINGULAR_ENGINE_DIR/task_batch_publish.py" resolve \
    --stage-dir "$stage_dir"
}

singular_task_batch_has_candidates() {
  local stage_dir="${1:-}" resolved
  resolved="$(singular_task_batch_candidate_dir "$stage_dir" 2>/dev/null)" || return 1
  find "$resolved" -maxdepth 1 -name 'TASK-*.candidate.md' -type f \
    -print -quit 2>/dev/null | grep -q .
}

# Pin and verify the selected canonical batch, then copy it byte-for-byte into
# a new private writable directory. The publisher lock protects selection while
# copying; canonical bytes and modes are verified again before the copy appears.
singular_task_batch_prepare_import() {
  local stage_dir="${1:-}" private_dir="${2:-}"
  [[ -d "$stage_dir" && -n "$private_dir" ]] || return 2
  [[ "$private_dir" == "$stage_dir"/.import-* ]] || return 2
  [[ ! -e "$private_dir" && ! -L "$private_dir" ]] || return 2
  python3 "$SINGULAR_ENGINE_DIR/task_batch_publish.py" prepare-import \
    --stage-dir "$stage_dir" --output-dir "$private_dir" >/dev/null
}

# Apply a whole-batch TASK-id mapping in one tokenization pass per private file.
# Looking every original token up in the immutable mapping avoids A->B, B->C
# cascades when planner ids overlap the newly allocated range.
singular_task_batch_rewrite_import() {
  local private_dir="${1:-}" mapping_json="${2:-}"
  [[ -d "$private_dir" && -n "$mapping_json" ]] || return 2
  python3 - "$private_dir" "$mapping_json" <<'PY'
import json
import os
from pathlib import Path
import re
import sys

directory, mapping_raw = sys.argv[1:3]
mapping = json.loads(mapping_raw)
if not isinstance(mapping, dict) or not mapping:
    raise SystemExit(2)
token = re.compile(r"TASK-[0-9]{4,}")
paths = sorted(Path(directory).glob("TASK-*.candidate.md"))
if len(paths) != len(mapping):
    raise SystemExit(2)
fail_at = os.environ.get("SINGULAR_TEST_IMPORT_FAIL_AT", "")
for index, path in enumerate(paths, 1):
    text = path.read_text(encoding="utf-8")
    rewritten = token.sub(lambda match: mapping.get(match.group(0), match.group(0)), text)
    path.write_text(rewritten, encoding="utf-8")
    if fail_at == f"rewrite:{index}":
        raise SystemExit(73)
PY
}

singular_task_batch_materialize() {
  local raw_message="${1:-}" normalized_batch="${2:-}" candidate_dir="${3:-}"
  local expected_area="${4:-}" expected_ids_json="${5:-[]}" identity_mode="${6:-assign}"
  local schema_path="${7:-${SINGULAR_TASKBATCH_SCHEMA:-}}"

  [[ -f "$raw_message" && -n "$normalized_batch" && -n "$candidate_dir" ]] || return 2
  [[ "$candidate_dir" != "/" && "$candidate_dir" != "." ]] || return 2
  [[ "$identity_mode" == "assign" || "$identity_mode" == "exact" ]] || return 2
  [[ -n "$schema_path" && -f "$schema_path" ]] || {
    echo "task-batch schema not found: $schema_path" >&2
    return 2
  }

  rm -rf -- "$candidate_dir"
  mkdir -p "$candidate_dir"
  local extracted="$candidate_dir/.extracted.json"
  if ! singular_extract_json "$raw_message" "$extracted" 2>/dev/null; then
    rm -rf -- "$candidate_dir"
    return 3
  fi

  local manifest="$candidate_dir/.materialize.tsv"
  local prepared="$candidate_dir/.normalized.json"
  local envelope_rc=0
  python3 - "$schema_path" "$extracted" "$prepared" "$manifest" \
    "$expected_ids_json" "$identity_mode" <<'PY' || envelope_rc=$?
import json
import re
import sys

schema_path, source_path, output_path, manifest_path, expected_raw, mode = sys.argv[1:7]
try:
    with open(schema_path, "r", encoding="utf-8") as f:
        schema = json.load(f)
    with open(source_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    expected = json.loads(expected_raw)
except Exception as exc:
    print("invalid task-batch input: {}".format(exc), file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print("task batch must be an object", file=sys.stderr)
    sys.exit(2)
for key in schema.get("required", []):
    if key not in data:
        print("missing batch field: {}".format(key), file=sys.stderr)
        sys.exit(2)
allowed_batch_fields = set((schema.get("properties") or {}).keys())
if schema.get("additionalProperties") is False and set(data) - allowed_batch_fields:
    print(
        "unexpected batch fields: {}".format(
            ",".join(sorted(set(data) - allowed_batch_fields))
        ),
        file=sys.stderr,
    )
    sys.exit(2)
if data.get("schema") != "singular.orchestration.task-batch.v0":
    print("unsupported task batch schema", file=sys.stderr)
    sys.exit(2)
tasks = data.get("tasks")
if not isinstance(tasks, list):
    print("task batch tasks must be an array", file=sys.stderr)
    sys.exit(2)
if not tasks:
    sys.exit(4)
if not isinstance(expected, list) or not expected:
    print("expected task ids must be a non-empty array", file=sys.stderr)
    sys.exit(2)
if any(not isinstance(v, str) or not re.fullmatch(r"TASK-[0-9]{4,}", v) for v in expected):
    print("invalid expected task id", file=sys.stderr)
    sys.exit(2)
if len(set(expected)) != len(expected):
    print("duplicate expected task id", file=sys.stderr)
    sys.exit(2)

source_ids = []
item_schema = (((schema.get("properties") or {}).get("tasks") or {}).get("items") or {})
allowed_item_fields = set((item_schema.get("properties") or {}).keys())
required_item_fields = set(item_schema.get("required") or ())
for item in tasks:
    if not isinstance(item, dict):
        print("task batch item must be an object", file=sys.stderr)
        sys.exit(2)
    if required_item_fields - set(item):
        print(
            "missing task batch item fields: {}".format(
                ",".join(sorted(required_item_fields - set(item)))
            ),
            file=sys.stderr,
        )
        sys.exit(2)
    if item_schema.get("additionalProperties") is False and set(item) - allowed_item_fields:
        print(
            "unexpected task batch item fields: {}".format(
                ",".join(sorted(set(item) - allowed_item_fields))
            ),
            file=sys.stderr,
        )
        sys.exit(2)
    task_id = item.get("taskId")
    markdown = item.get("markdown")
    if not isinstance(task_id, str) or not re.fullmatch(r"TASK-[0-9]{4,}", task_id):
        print("invalid task batch item id", file=sys.stderr)
        sys.exit(2)
    if not isinstance(markdown, str) or not markdown.strip():
        print("invalid task batch item markdown", file=sys.stderr)
        sys.exit(2)
    source_ids.append(task_id)
if len(set(source_ids)) != len(source_ids):
    print("duplicate task id in batch", file=sys.stderr)
    sys.exit(2)

if mode == "exact":
    if len(source_ids) != len(expected) or set(source_ids) != set(expected):
        print(
            "task id set mismatch: expected={} actual={}".format(
                ",".join(sorted(expected)), ",".join(sorted(source_ids))
            ),
            file=sys.stderr,
        )
        sys.exit(2)
    by_id = {item["taskId"]: item for item in tasks}
    ordered = [(task_id, task_id, by_id[task_id]) for task_id in expected]
else:
    if len(tasks) > len(expected):
        print("task batch exceeds requested count", file=sys.stderr)
        sys.exit(2)
    ordered = [
        (item["taskId"], expected[index], item)
        for index, item in enumerate(tasks)
    ]

normalized_tasks = []
with open(manifest_path, "w", encoding="utf-8") as manifest:
    for source_id, destination_id, item in ordered:
        markdown = item["markdown"].strip() + "\n"
        normalized_tasks.append({"taskId": destination_id, "markdown": markdown.rstrip("\n")})
        manifest.write("{}\t{}\n".format(destination_id, source_id))
        with open(
            "{}/{}.candidate.md".format(
                manifest_path.rsplit("/", 1)[0], destination_id
            ),
            "w",
            encoding="utf-8",
        ) as candidate:
            candidate.write(markdown)

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(
        {"schema": "singular.orchestration.task-batch.v0", "tasks": normalized_tasks},
        f,
        indent=2,
    )
    f.write("\n")
PY

  if [[ "$envelope_rc" -eq 4 ]]; then
    rm -rf -- "$candidate_dir"
    return 4
  fi
  if [[ "$envelope_rc" -ne 0 ]]; then
    rm -rf -- "$candidate_dir"
    return 2
  fi

  local destination_id source_id candidate v_id v_status v_area v_owned v_mode v_deps
  local source_ids_json destination_ids_json internal_dep
  source_ids_json="$(cut -f2 "$manifest" | python3 -c \
    'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))')" || {
      rm -rf -- "$candidate_dir"
      return 2
    }
  destination_ids_json="$(cut -f1 "$manifest" | python3 -c \
    'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))')" || {
      rm -rf -- "$candidate_dir"
      return 2
    }

  while IFS=$'\t' read -r destination_id source_id; do
    [[ -n "$destination_id" && -n "$source_id" ]] || continue
    candidate="$candidate_dir/$destination_id.candidate.md"
    v_id="$(singular_task_field "$candidate" taskId 2>/dev/null || true)"
    if [[ -z "$v_id" || "$v_id" != "$source_id" ]]; then
      echo "batch/markdown task id mismatch: batch=$source_id markdown=$v_id" >&2
      rm -rf -- "$candidate_dir"
      return 2
    fi
    if [[ "$identity_mode" == "assign" && "$source_id" != "$destination_id" ]]; then
      singular_rewrite_task_id_token "$candidate" "$source_id" "$destination_id" || {
        rm -rf -- "$candidate_dir"
        return 2
      }
    fi

    v_id="$(singular_task_field "$candidate" taskId 2>/dev/null || true)"
    v_status="$(singular_task_field "$candidate" status 2>/dev/null || true)"
    v_area="$(singular_task_field "$candidate" area 2>/dev/null || true)"
    v_owned="$(singular_task_field "$candidate" ownedFiles 2>/dev/null || echo '[]')"
    v_mode="$(singular_task_field "$candidate" dispatchMode 2>/dev/null || true)"
    v_deps="$(singular_task_field "$candidate" dependsOn 2>/dev/null || echo '[]')"
    internal_dep="$(python3 - "$v_deps" "$source_ids_json" "$destination_ids_json" <<'PY'
import json
import sys
deps = set(json.loads(sys.argv[1]))
batch_ids = set(json.loads(sys.argv[2])) | set(json.loads(sys.argv[3]))
print("yes" if deps & batch_ids else "no")
PY
)" || {
      rm -rf -- "$candidate_dir"
      return 2
    }
    if [[ "$v_id" != "$destination_id" || "$v_status" != "ready" \
          || "$v_area" != "$expected_area" || "$v_owned" == "[]" \
          || "$v_mode" != "canonical" || "$internal_dep" == "yes" ]]; then
      echo "task validation failed: task=$destination_id status=$v_status area=$v_area owned=$v_owned mode=$v_mode internalDep=$internal_dep" >&2
      rm -rf -- "$candidate_dir"
      return 2
    fi
  done <"$manifest"

  # Regenerate the normalized envelope from the validated/rewritten candidate
  # bytes so the disposition recorder and the staged files share one identity.
  if ! python3 - "$prepared" "$manifest" "$candidate_dir" "$normalized_batch" <<'PY'
import json
import sys
_, manifest_path, candidate_dir, output_path = sys.argv[1:5]
tasks = []
with open(manifest_path, "r", encoding="utf-8") as f:
    for line in f:
        destination_id = line.rstrip("\n").split("\t", 1)[0]
        if not destination_id:
            continue
        with open(
            "{}/{}.candidate.md".format(candidate_dir, destination_id),
            "r",
            encoding="utf-8",
        ) as candidate:
            tasks.append({"taskId": destination_id, "markdown": candidate.read().strip()})
with open(output_path, "w", encoding="utf-8") as f:
    json.dump({"schema": "singular.orchestration.task-batch.v0", "tasks": tasks}, f, indent=2)
    f.write("\n")
PY
  then
    rm -rf -- "$candidate_dir"
    rm -f "$normalized_batch"
    return 2
  fi
  rm -f "$extracted" "$prepared" "$manifest"
  return 0
}

# Capture the immutable identity contract of the currently staged candidate set.
# The filename, markdown task id, count, and area must all agree.
singular_task_batch_stage_contract() {
  local stage_dir="${1:-}" output_path="${2:-}"
  [[ -d "$stage_dir" && -n "$output_path" ]] || return 2
  local candidate_batch_dir
  candidate_batch_dir="$(singular_task_batch_candidate_dir "$stage_dir")" || return 2
  local -a candidates=()
  mapfile -t candidates < <(find "$candidate_batch_dir" -maxdepth 1 \
    -name 'TASK-*.candidate.md' -type f 2>/dev/null | sort)
  [[ "${#candidates[@]}" -gt 0 ]] || return 2

  local candidate filename_id markdown_id area common_area="" ids_file
  ids_file="${output_path}.ids.$$"
  : >"$ids_file"
  for candidate in "${candidates[@]}"; do
    filename_id="$(basename "$candidate" .candidate.md)"
    markdown_id="$(singular_task_field "$candidate" taskId 2>/dev/null || true)"
    area="$(singular_task_field "$candidate" area 2>/dev/null || true)"
    if [[ ! "$filename_id" =~ ^TASK-[0-9]{4,}$ || "$markdown_id" != "$filename_id" || -z "$area" ]]; then
      rm -f "$ids_file"
      return 2
    fi
    if [[ -z "$common_area" ]]; then
      common_area="$area"
    elif [[ "$area" != "$common_area" ]]; then
      rm -f "$ids_file"
      return 2
    fi
    printf '%s\n' "$filename_id" >>"$ids_file"
  done
  if [[ "$(sort -u "$ids_file" | wc -l | tr -d '[:space:]')" != "${#candidates[@]}" ]]; then
    rm -f "$ids_file"
    return 2
  fi

  local tmp="${output_path}.tmp.$$"
  if ! python3 - "$ids_file" "$common_area" "$tmp" <<'PY'
import json
import sys
ids_path, area, output_path = sys.argv[1:4]
with open(ids_path, "r", encoding="utf-8") as f:
    ids = [line.strip() for line in f if line.strip()]
with open(output_path, "w", encoding="utf-8") as f:
    json.dump({"taskIds": ids, "count": len(ids), "area": area}, f, separators=(",", ":"))
    f.write("\n")
PY
  then
    rm -f "$ids_file" "$tmp"
    return 2
  fi
  if ! mv "$tmp" "$output_path"; then
    rm -f "$ids_file" "$tmp"
    return 2
  fi
  rm -f "$ids_file"
}

# Publish a complete immutable candidate generation, then atomically select it
# with one pointer replacement. Every in-engine reader pins the selected
# generation once, so a concurrent reader sees either the complete prior batch
# or the complete replacement. Legacy direct files are never rewritten and
# remain available to readers that resolved them before the first publication.
singular_task_batch_replace_stage() {
  local candidate_dir="${1:-}" stage_dir="${2:-}"
  [[ -d "$candidate_dir" && -d "$stage_dir" ]] || return 2
  [[ "$candidate_dir" != "$stage_dir" && "$stage_dir" != "/" && "$stage_dir" != "." ]] || return 2

  local current_dir
  current_dir="$(singular_task_batch_candidate_dir "$stage_dir")" || return 2
  local -a replacement=() current=()
  mapfile -t replacement < <(find "$candidate_dir" -maxdepth 1 -name 'TASK-*.candidate.md' -type f 2>/dev/null | sort)
  mapfile -t current < <(find "$current_dir" -maxdepth 1 -name 'TASK-*.candidate.md' -type f 2>/dev/null | sort)
  [[ "${#replacement[@]}" -gt 0 && "${#current[@]}" -gt 0 ]] || return 2
  [[ "${#replacement[@]}" -eq "${#current[@]}" ]] || return 2

  local path target
  for path in "${replacement[@]}"; do
    target="$current_dir/$(basename "$path")"
    [[ -f "$target" ]] || return 2
  done

  if ! python3 "$SINGULAR_ENGINE_DIR/task_batch_publish.py" publish \
    --stage-dir "$stage_dir" --candidate-dir "$candidate_dir" >/dev/null; then
    return 2
  fi
  rm -rf -- "$candidate_dir"
  rm -f "$stage_dir/NO-TASKS"
  return 0
}
