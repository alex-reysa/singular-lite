#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os, pathlib, signal, subprocess, sys, tempfile, time
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='exact-bounds-') as scratch:
    base = pathlib.Path(scratch)
    hostile = base / 'hostile.sh'
    hostile.write_text('export SINGULAR_TARGET_BRANCH=codex/brain-integration\necho HOSTILE-CONFIG-LOADED >&2\n')
    hostile_json = base / 'hostile.json'
    hostile_json.write_text('{"schemaVersion":"v2","targetBranch":"codex/brain-integration"}')
    # Characterize the causal override directly, without relying on the old log's suspicion.
    clean = {k:v for k,v in os.environ.items() if not k.startswith('SINGULAR_')}
    clean.update(SINGULAR_ROOT=str(base), SINGULAR_ENGINE_HOME=str(root),
                 SINGULAR_JSON_CONFIG_FILE=str(hostile_json), SINGULAR_CONFIG_FILE=str(hostile),
                 SINGULAR_LOCAL_CONFIG_FILE=str(hostile), SINGULAR_TARGET_BRANCH='target')
    bash = '/opt/homebrew/bin/bash' if pathlib.Path('/opt/homebrew/bin/bash').exists() else 'bash'
    probe = subprocess.run([bash, '-c', 'source "$1/engine/lib.sh"; printf "%s\\n" "$SINGULAR_TARGET_BRANCH"',
                            'config-probe', str(root)], env=clean, capture_output=True, text=True, timeout=10)
    assert probe.returncode == 0, probe.stderr
    assert probe.stdout.strip() == 'codex/brain-integration', probe.stdout
    assert 'HOSTILE-CONFIG-LOADED' in probe.stderr
    print('PASS: characterization: inherited config overrides target with codex/brain-integration', flush=True)
    for case, expected, diagnostic in [('hostile', 0, 'PASS: test-integration-exact-tree'), ('integrator', 37, 'injected integrator failure'), ('watcher', 38, 'injected watcher failure'), ('latch', 1, 'dirt-ready timed out'), ('signal', 143, 'fixture interrupted')]:
        temp = base / case
        temp.mkdir()
        record = base/'process-group'
        if record.exists(): record.unlink()
        env = dict(os.environ, TMPDIR=str(temp), SINGULAR_CONFIG_FILE=str(hostile),
                   SINGULAR_LOCAL_CONFIG_FILE=str(hostile), SINGULAR_JSON_CONFIG_FILE=str(hostile_json),
                   SINGULAR_TASKS_DIR=str(base/'wrong-tasks'), SINGULAR_RUNNER='/nonexistent-hostile-runner',
                   SINGULAR_CAMPAIGN_MANIFEST=str(base/'wrong-campaign'),
                   EXACT_TREE_PROCESS_RECORD=str(base/'process-group'),
                   EXACT_TREE_TEST_FAILURE='' if case == 'hostile' else case)
        proc = subprocess.Popen(['bash', str(root / 'tests/test-integration-exact-tree.sh')], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            if case == 'signal':
                deadline = time.monotonic() + 30
                while not list(temp.rglob('lock-fail-dirt-ready')):
                    assert proc.poll() is None, 'fixture exited before signal injection'
                    assert time.monotonic() < deadline, 'signal injection latch timed out'
                    time.sleep(0.01)
                proc.send_signal(signal.SIGTERM)
            output, _ = proc.communicate(timeout=90)
        except (subprocess.TimeoutExpired, AssertionError):
            if record.exists():
                try: os.killpg(int(record.read_text()), signal.SIGKILL)
                except ProcessLookupError: pass
            try: os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            output, _ = proc.communicate()
            print(output.decode(), flush=True)
            raise SystemExit('FAIL: '+case+' reached outer timeout (old waiter hang)')
        print(output.decode(), end='', flush=True)
        assert proc.returncode == expected, (case, proc.returncode, expected)
        assert diagnostic in output.decode(), (case, diagnostic)
        assert 'HOSTILE-CONFIG-LOADED' not in output.decode()
        pgid = int((base/'process-group').read_text())
        deadline = time.monotonic() + 3
        while True:
            try: os.killpg(pgid, 0)
            except ProcessLookupError: break
            except PermissionError:
                rows = subprocess.check_output(['ps', '-axo', 'pgid=,stat='], text=True)
                members = [row.split()[1] for row in rows.splitlines()
                           if len(row.split()) == 2 and row.split()[0] == str(pgid)]
                assert not any(not state.startswith('Z') for state in members), ('live owned process group cannot be signalled', pgid, members)
                break
            assert time.monotonic() < deadline, ('owned process group leaked', pgid)
            time.sleep(0.02)
        assert not list(temp.iterdir()), ('disposable resources leaked', list(temp.iterdir()))
        print('PASS: bounds '+case, flush=True)
PY
