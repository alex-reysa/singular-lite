#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/config" "$repo/docs/orchestration" "$repo/custom-state" "$repo/custom-tasks" \
  "$repo/custom-state/leases" "$repo/custom-state/runs/RUN-ACCEPTED" \
  "$repo/custom-state/runs/RUN-UNACCEPTED"
git -C "$repo" init -q
git -C "$repo" -c user.name=test -c user.email=test@example.com \
  commit -q --allow-empty -m init
config="$repo/config/runtime.json"
events="$repo/custom-state/events.ndjson"
dag="$repo/dag.json"

cat >"$config" <<'JSON'
{
  "schemaVersion":"v2",
  "runner":"codex-run.sh",
  "env":{
    "SINGULAR_TASKS_DIR":"custom-tasks",
    "SINGULAR_STATE_DIR":"custom-state",
    "SINGULAR_CODEX_IMPLEMENTER_MODEL":"gpt-5.6-sol",
    "SINGULAR_CODEX_AUDITOR_MODEL":"gpt-6-astra",
    "SINGULAR_CODEX_L2_REASONING_EFFORT":"high",
    "SINGULAR_CODEX_AUDITOR_REASONING_EFFORT":"medium"
  }
}
JSON
printf '%s\n' '{"schema":"singular.orchestration.dag.v0","nodes":[{"id":"diagnostics","stage":"S0","area":"brain","layer":"test","kind":"contract","dependsOn":[],"requiredCompletion":"done"}]}' >"$dag"
printf '%s\n' '{"schema":"singular.orchestration.dag.v0","nodes":[{"id":"diagnostics","stage":"S0","area":"brain","layer":"test","kind":"contract","dependsOn":[],"requiredCompletion":"done"}]}' >"$repo/docs/orchestration/dag.v0.json"
cat >"$events" <<'JSONL'
{"ts":"2026-09-11T10:00:00Z","type":"provider.model_rejected","message":"provider rejected requested model","data":{"diagnostic":{"category":"provider-failure","severity":"error","expected":false,"impact":"blocking","source":"provider","dedupeKey":"model-rejected","evidenceStatus":"provider-rejection","inventoryProvenance":"provider-response","providerRejected":true}}}
JSONL
cat >"$repo/custom-tasks/TASK-2001.md" <<'MD'
# accepted
Status: blocked
Depends on: [TASK-2002]
MD
cat >"$repo/custom-tasks/TASK-2002.md" <<'MD'
# dependency
Status: ready
Depends on: []
MD
cat >"$repo/custom-tasks/TASK-2003.md" <<'MD'
# unaccepted terminal
Status: blocked
Depends on: []
MD
cat >"$repo/custom-state/leases/TASK-2001.json" <<'JSON'
{"taskId":"TASK-2001","status":"blocked","owner":"owner-retained","acceptedCandidate":{"runId":"RUN-ACCEPTED","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","treeSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","state":"integration-failed","failures":[{"failureId":"FAIL-EXACT","failureClass":"gate-failed","domain":"product"}],"nextAction":"repair exact candidate"},"failureBudgets":{"product":2,"infrastructure":1,"regate":3},"recoveryAuthorization":{"action":"repair","state":"authorized","authorizedBy":"host-owner"},"nextAction":"dispatch bounded repair"}
JSON
cat >"$repo/custom-state/runs/RUN-ACCEPTED/run-status.json" <<'JSON'
{"schema":"singular.orchestration.run-status.v0","runId":"RUN-ACCEPTED","taskId":"TASK-2001","state":"failed","phase":"integrating","updatedAt":"2026-09-12T10:00:00Z","nextAction":"repair exact candidate"}
JSON
cat >"$repo/custom-state/runs/RUN-UNACCEPTED/run-status.json" <<'JSON'
{"schema":"singular.orchestration.run-status.v0","runId":"RUN-UNACCEPTED","taskId":"TASK-2003","state":"failed","phase":"auditing","owner":"sol-author","headSha":"cccccccccccccccccccccccccccccccccccccccc","treeSha":"dddddddddddddddddddddddddddddddddddddddd","updatedAt":"2026-09-12T11:00:00Z","nextAction":"create distinct successor correction"}
JSON
cat >"$repo/custom-state/runs/RUN-UNACCEPTED/audit.json" <<'JSON'
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-2003","runId":"RUN-UNACCEPTED","verdict":"needs-fix"}
JSON
printf '{malformed\n' >"$repo/custom-state/leases/TASK-2999.json"

before="$(find "$repo" -path "$repo/.git" -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256)"

effective="$(env SINGULAR_JSON_CONFIG_FILE='config/runtime.json' \
  python3 "$ROOT/engine/provider_resolver.py" effective-config --repo "$repo")"
health="$(python3 "$ROOT/engine/health_details.py" --repo "$repo" --dag "$dag" --events "$events" \
  --tasks "$repo/custom-tasks" --state "$repo/custom-state")"
cli="$(cd "$repo" && env SINGULAR_JSON_CONFIG_FILE='config/runtime.json' \
  SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_CODEX_BIN=/bin/true \
  bash "$ROOT/cli/singular" health --json)"
doctor="$(cd / && env SINGULAR_JSON_CONFIG_FILE='config/runtime.json' \
  SINGULAR_CODEX_BIN=/bin/true HOME="$tmp/home" \
  python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$repo" \
    --bash /opt/homebrew/bin/bash --bash-version 5.2 --json 2>/dev/null || true)"
dashboard="$(cd / && env SINGULAR_JSON_CONFIG_FILE='config/runtime.json' \
  SINGULAR_ENGINE_HOME="$ROOT" python3 "$ROOT/plugin/scripts/singular_graph_server.py" \
    --repo "$repo" --lifecycle)"

python3 - "$effective" "$health" "$repo" "$config" "$cli" "$doctor" "$dashboard" <<'PY'
import json, os, sys
effective, health = map(json.loads, sys.argv[1:3])
repo, config = map(os.path.realpath, sys.argv[3:5])
cli, doctor, dashboard = map(json.loads, sys.argv[5:8])
assert effective["configuration"] == {
    "path": config, "source": "selector", "status": "ok"
}, effective
assert effective["paths"] == {
    "root": repo,
    "tasks": os.path.join(repo, "custom-tasks"),
    "state": os.path.join(repo, "custom-state"),
}, effective
assert effective["roles"]["implementer"]["model"] == "gpt-5.6-sol", effective
assert effective["roles"]["implementer"]["reasoningEffort"] == "high", effective
assert effective["roles"]["auditor"]["model"] == "gpt-6-astra", effective
assert effective["roles"]["auditor"]["reasoningEffort"] == "medium", effective

diagnostics = health["diagnostics"]
assert diagnostics["schema"] == "singular.diagnostics.v2.1", diagnostics
item = diagnostics["items"][0]
# Existing consumer fields remain while 2.1 evidence qualifiers survive.
assert {"category", "severity", "expected", "impact", "source", "dedupeKey"} <= set(item), item
assert item["evidenceStatus"] == "provider-rejection", item
assert item["inventoryProvenance"] == "provider-response", item
assert item["providerRejected"] is True, item

expected = health["lifecycle"]
assert cli["lifecycle"] == expected, (cli["lifecycle"], expected)
assert doctor["lifecycle"] == expected, (doctor.get("lifecycle"), expected)
dashboard_generation = dashboard.pop("generation")
assert dashboard_generation["status"] == "current", dashboard_generation
assert dashboard_generation["restartRequired"] is False, dashboard_generation
assert dashboard == expected, (dashboard, expected)
candidate = expected["candidates"][0]
assert candidate["acceptedCandidate"] is True, candidate
assert candidate["candidateRunId"] == "RUN-ACCEPTED", candidate
assert candidate["candidateHeadSha"] == "a" * 40, candidate
assert candidate["candidateTreeSha"] == "b" * 40, candidate
assert candidate["failureId"] == "FAIL-EXACT", candidate
assert candidate["failureDomain"] == "product", candidate
assert candidate["owner"] == "host-owner", candidate
assert candidate["failureBudgets"] == {"product":2,"infrastructure":1,"regate":3}, candidate
assert candidate["permittedNextAction"] == "dispatch bounded repair", candidate
attempt = next(x for x in expected["preservedAttempts"] if x["runId"] == "RUN-UNACCEPTED")
assert attempt["acceptedCandidate"] is False, attempt
assert attempt["auditVerdict"] == "needs-fix", attempt
assert attempt["permittedNextAction"] == "create distinct successor correction", attempt
assert any(x["record"] == "TASK-2999.json" and x["status"] == "corrupt"
           for x in expected["unknownRecords"]), expected
PY

after="$(find "$repo" -path "$repo/.git" -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256)"
[[ "$before" == "$after" ]] || {
  diff -u <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  echo "FAIL: diagnostics mutated fixture" >&2
  exit 1
}

# Real server-entrypoint regression: warm every configuration-dependent HTTP
# route, change bound inputs inside every TTL, then authorize exactly one
# settings refresh. A sandbox that denies loopback bind is reported distinctly
# as infrastructure-unavailable; on a normal host every assertion is mandatory.
http_repo="$tmp/http-main"
mkdir -p "$http_repo/docs/orchestration/tasks" "$http_repo/state-a/runs" \
  "$http_repo/state-a/leases" "$http_repo/state-b/runs" "$http_repo/state-b/leases"
git -C "$http_repo" init -q
git -C "$http_repo" -c user.name=test -c user.email=test@example.com \
  commit -q --allow-empty -m init
printf '%s\n' '{"schema":"singular.orchestration.dag.v0","nodes":[]}' \
  >"$http_repo/docs/orchestration/dag.v0.json"
printf '%s\n' '{"schemaVersion":"v2","runner":"codex-run.sh","env":{"SINGULAR_CODEX_MODEL":"model-a"}}' \
  >"$http_repo/singular.config.json"
printf '%s\n' 'printf "startup\n" >> "$SINGULAR_ROOT/startup-marker"' \
  'export SINGULAR_STATE_DIR=state-a' >"$http_repo/singular.config.sh"
set +e
PYTHONDONTWRITEBYTECODE=1 /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 \
  - "$ROOT" "$http_repo" <<'PY'
import http.client, json, os, pathlib, select, subprocess, sys, time

engine, repo = map(pathlib.Path, sys.argv[1:3])
python = "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"
env = {
    "PATH": "/usr/bin:/bin",
    "HOME": str(repo / "home"),
    "TMPDIR": str(repo.parent),
    "PYTHONDONTWRITEBYTECODE": "1",
    "SINGULAR_ENGINE_HOME": str(engine),
    "SINGULAR_BASH_BIN": "/opt/homebrew/bin/bash",
    "SINGULAR_CODEX_BIN": str(repo / "missing-codex"),
    "SINGULAR_CONSOLE_NO_STATE": "1",
}
(repo / "home").mkdir()
proc = subprocess.Popen(
    [python, str(engine / "plugin/scripts/singular_graph_server.py"),
     "--repo", str(repo), "--host", "127.0.0.1", "--port", "0"],
    cwd="/", env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
try:
    ready, _, _ = select.select([proc.stdout], [], [], 20)
    if not ready:
        stderr = proc.stderr.read()
        if "PermissionError: [Errno 1] Operation not permitted" in stderr:
            print("SKIP infrastructure: loopback socket bind denied (EPERM)", file=sys.stderr)
            raise SystemExit(77)
        raise AssertionError(f"server did not become ready: {stderr}")
    line = proc.stdout.readline().strip()
    if "http://" not in line:
        stderr = proc.stderr.read()
        if "PermissionError: [Errno 1] Operation not permitted" in stderr:
            print("SKIP infrastructure: loopback socket bind denied (EPERM)", file=sys.stderr)
            raise SystemExit(77)
        raise AssertionError(f"bad readiness line: {line!r}; {stderr}")
    port = int(line.rsplit(":", 1)[1])

    def request(method, route, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
        raw = json.dumps(body).encode() if body is not None else None
        headers = ({"Content-Type": "application/json", "Content-Length": str(len(raw))}
                   if raw is not None else {})
        conn.request(method, route, raw, headers)
        response = conn.getresponse()
        payload = response.read()
        conn.close()
        return response.status, payload, json.loads(payload)

    routes = (
        "/api/config", "/api/providers", "/api/overview", "/api/home",
        "/api/dag", "/api/timeline", "/api/lifecycle", "/api/settings",
        "/api/state", "/api/sessions", "/api/plans",
    )
    warm = {route: request("GET", route) for route in routes}
    assert all(status == 200 for status, _raw, _data in warm.values()), warm
    initial = warm["/api/config"][2]["generation"]["id"]
    (repo / "singular.config.json").write_text(json.dumps({
        "schemaVersion": "v2", "runner": "gemini-run.sh",
        "env": {"SINGULAR_CODEX_MODEL": "model-b"},
    }))
    (repo / "singular.config.sh").write_text(
        'printf "startup\\n" >> "$SINGULAR_ROOT/startup-marker"\n'
        'export SINGULAR_STATE_DIR=state-b\n'
    )
    started = time.monotonic()
    changed = {route: request("GET", route) for route in routes}
    assert time.monotonic() - started < 6.0
    assert not any(changed[route][1] == warm[route][1] for route in routes), changed
    for route in ("/api/config", "/api/providers", "/api/lifecycle", "/api/settings"):
        status, _raw, data = changed[route]
        assert status == 200, (route, status, data)
        assert data["generation"]["status"] == "changed", (route, data)
    providers = changed["/api/providers"][2]
    assert providers["activeProvider"] == "unknown" and providers["activeRunner"] is None
    assert not any(row["isDefaultRunner"] for row in providers["providers"])
    for route in set(routes) - {"/api/config", "/api/providers", "/api/lifecycle", "/api/settings"}:
        status, _raw, data = changed[route]
        assert status == 409, (route, status, data)
        assert data["generation"]["status"] == "changed", (route, data)

    status, _raw, posted = request(
        "POST", "/api/settings", {"changes": {"SINGULAR_MAX_CONCURRENT": "4"}}
    )
    assert status == 200 and posted["ok"] is True, posted
    replacement = posted["config"]["generation"]["id"]
    assert replacement != initial
    refreshed = {route: request("GET", route) for route in routes}
    for route, (status, _raw, data) in refreshed.items():
        assert status == 200, (route, status, data)
        assert data["generation"]["id"] == replacement, (route, data)
        assert data["generation"]["status"] == "current", (route, data)
    assert (repo / "startup-marker").read_text().splitlines() == ["startup", "startup"]
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
PY
http_rc=$?
set -e
if [[ "$http_rc" -eq 77 ]]; then
  echo "SKIP: real HTTP diagnostic contract (socket bind unavailable)"
elif [[ "$http_rc" -ne 0 ]]; then
  echo "FAIL: real HTTP diagnostic contract exited $http_rc" >&2
  exit "$http_rc"
fi

echo "PASS: test-diagnostic-compatibility"
