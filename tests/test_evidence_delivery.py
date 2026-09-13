import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
host = [sys.executable, str(root / 'engine/evidence_delivery.py'), 'run']
with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp)
    consumer = t / 'consumer'
    consumer.mkdir()
    subprocess.run(['git', '-C', str(consumer), 'init', '-q'], check=True)
    fixture_env = os.environ.copy()
    for key in tuple(fixture_env):
        if key.startswith(('SINGULAR_', 'FROZEN_')) or key == 'PYTHONPATH':
            fixture_env.pop(key)
    fixture_env.update({
        'SINGULAR_ROOT': str(consumer),
        'SINGULAR_STATE_DIR': str(consumer / '.singular-state'),
        'SINGULAR_ENGINE_HOME': str(root),
        'SINGULAR_CONFIG_FILE': '/dev/null',
        'SINGULAR_LOCAL_CONFIG_FILE': '/dev/null',
        'SINGULAR_BASH_BIN': '/opt/homebrew/bin/bash',
        'PYTHONDONTWRITEBYTECODE': '1',
    })
    def fixture_run(command, **kwargs):
        kwargs.setdefault('env', fixture_env)
        kwargs.setdefault('cwd', consumer)
        return subprocess.run(command, **kwargs)
    run = t / 'run'
    run.mkdir()
    data = b'a' * 4096 + b'final required fact'
    (run / 'packet.json').write_bytes(data)
    manifest = run / 'evidence-manifest.json'
    doc = {'schema': 'singular.orchestration.evidence-manifest.v0', 'taskId': 'TASK-9000',
           'runId': 'RUN-test', 'headSha': 'a' * 40, 'budget': {'retrievalLimitBytes': len(data) * 2,
           'excerptLimitBytes': 2048, 'limitBytes': 262144}, 'artifacts': [{'ref': 'packet.json',
           'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}]}
    manifest.write_text(json.dumps(doc))
    ledger = t / 'ledger.sqlite3'
    child = t / 'child.py'
    child.write_text('''
import concurrent.futures, json, os, pathlib, subprocess, sys
base=[sys.executable, sys.argv[1], 'get', sys.argv[2], 'packet.json', '2048']
# Native OS deny-all-writes profile: even /tmp writes must fail.
prefix=[]
if sys.platform == 'darwin':
    prefix=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny file-write*)']
    denial=subprocess.run(prefix+[sys.executable,'-c',"open('/tmp/forbidden-evidence-write','w')"],capture_output=True)
    assert denial.returncode != 0 and b'PermissionError' in denial.stderr, denial.stderr
else:
    raise SystemExit('OS sandbox proof unavailable on this platform')
views=[]
for offset in (0,2048,4096):
    p=subprocess.run(prefix+base+[str(offset)],capture_output=True)
    assert p.returncode == 0, p.stderr
    identity=json.loads(p.stderr)
    assert identity['offset']==offset
    views.append(p.stdout)
assert b''.join(views)==b'a'*4096+b'final required fact'
# Concurrent delivery must not overspend. Repeated reads count again.
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results=list(pool.map(lambda _:subprocess.run(prefix+base+['0'],capture_output=True),range(8)))
assert any(p.returncode for p in results)
assert sum(len(p.stdout) for p in results)==4115-1  # len(full packet)
'''.replace('4115-1', str(len(data))))
    base = host + ['--manifest', str(manifest), '--ledger', str(ledger), '--']
    result = fixture_run(base + [sys.executable, str(child), str(root / 'engine/evidence_delivery.py'), str(manifest)], capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    with sqlite3.connect(ledger) as db:
        assert db.execute('select sum(bytes) from deliveries').fetchone()[0] == len(data) * 2
    # Relocation and refreshed manifest preserve cumulative accounting.
    moved = t / 'moved'
    shutil.copytree(run, moved)
    doc['createdAt'] = 'new timestamp'
    (moved / manifest.name).write_text(json.dumps(doc))
    probe = host + ['--manifest', str(moved / manifest.name), '--ledger', str(ledger), '--',
                    sys.executable, str(root / 'engine/evidence_delivery.py'), 'get', str(moved / manifest.name), 'packet.json']
    result = fixture_run(probe, capture_output=True)
    assert result.returncode and b'budget exhausted' in result.stderr
    # Required source invalidity stops before launching child or charging it.
    (run / 'packet.json').write_bytes(b'tampered')
    result = fixture_run(host + ['--manifest', str(manifest), '--ledger', str(ledger), '--required', 'packet.json', '--', '/usr/bin/true'], capture_output=True)
    assert result.returncode and b'identity changed' in result.stderr
    # No broker means fail closed, without creating writable counters.
    result = fixture_run([str(root / 'engine/evidence-show.sh'), str(manifest), 'packet.json'], capture_output=True)
    assert result.returncode and b'host evidence delivery unavailable' in result.stderr
    # Successful mandatory delivery uses exactly one snapshotted prompt and charges it.
    packet = {'schema': 'singular.orchestration.state-packet.v0', 'taskId': 'TASK-9000',
              'runId': 'RUN-required', 'headSha': 'a' * 40}
    report = dict(packet, schema='singular.orchestration.gate-report.v0', outcome='passed',
                  command='true', commandSha256=hashlib.sha256(b'true').hexdigest(),
                  sourceIntegrity={'status': 'verified'})
    doc['runId'] = 'RUN-required'
    doc['budget']['retrievalLimitBytes'] = 8192
    def publish_required():
        doc['artifacts'] = []
        for name, value in [('packet.json', packet), ('audit-verification.json', report)]:
            content = json.dumps(value).encode()
            (run / name).write_bytes(content)
            doc['artifacts'].append({'ref': name, 'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
        manifest.write_text(json.dumps(doc))
    publish_required()
    prompt = t / 'prompt.md'
    prompt.write_text('Review this task.')
    marker_file = t / 'launched'
    provider = t / 'provider.py'
    provider.write_text("import pathlib,sys; prompt=pathlib.Path(sys.argv[2]); text=prompt.read_text(); assert 'Complete host-delivered' in text and 'audit-verification.json' in text; pathlib.Path(sys.argv[3]).write_text(str(prompt))")
    launch = host + ['--manifest', str(manifest), '--ledger', str(ledger), '--required', 'packet.json',
                     '--required', 'audit-verification.json', '--', sys.executable, str(provider),
                     '--prompt-file', str(prompt), str(marker_file)]
    result = fixture_run(launch, capture_output=True)
    assert result.returncode == 0 and marker_file.exists(), result.stderr
    delivered_prompt = Path(marker_file.read_text())
    delivered = delivered_prompt.read_bytes()
    delivered_sha = hashlib.sha256(delivered).hexdigest()
    assert delivered_prompt.name == 'delivery-prompt-' + delivered_sha + '.md'
    with sqlite3.connect(ledger) as db:
        required_rows = [json.loads(row[0]) for row in db.execute('select detail from deliveries')]
    required_rows = [row for row in required_rows if row.get('kind') == 'required-prompt']
    assert len(required_rows) == 1, required_rows
    assert required_rows[0]['promptSha256'] == delivered_sha
    assert required_rows[0]['promptBytes'] == len(delivered)
    assert required_rows[0]['requiredEvidenceBytes'] == sum(
        item['bytes'] for item in doc['artifacts']
    )
    marker_file.unlink()
    for field, invalid in [('headSha', 'b' * 40), ('runId', 'wrong-run'), ('taskId', 'TASK-0000'),
                           ('outcome', 'inconclusive-infrastructure'), ('commandSha256', '0' * 64)]:
        original = report[field]
        report[field] = invalid
        publish_required()
        result = fixture_run(launch, capture_output=True)
        assert result.returncode and not marker_file.exists(), (field, result.stderr)
        with sqlite3.connect(ledger) as db:
            rows = [json.loads(row[0]) for row in db.execute('select detail from deliveries')]
        assert len([row for row in rows if row.get('kind') == 'required-prompt']) == 1
        report[field] = original
    publish_required()
    result = fixture_run(host + ['--manifest', str(manifest), '--ledger', str(ledger), '--',
                                '/does-not-exist/claude-run.sh'], capture_output=True)
    assert result.returncode and b'OS-enforced' in result.stderr

# Exercise the real public campaign producer and verifier through the /tmp
# spelling that macOS physically aliases to /private/tmp. The selected spelling
# must survive all the way into lib.sh and the provider command.
with tempfile.TemporaryDirectory(prefix='singular-evidence-alias.', dir='/tmp') as alias_tmp:
    alias_base = Path(alias_tmp)
    assert str(alias_base).startswith('/tmp/'), alias_base
    selected_engine = alias_base / 'test-engine'
    shutil.copytree(
        root, selected_engine, symlinks=True,
        ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.singular-state'),
    )
    alias_consumer = alias_base / 'consumer'
    (alias_consumer / 'docs/orchestration/prompts').mkdir(parents=True)
    subprocess.run(['git', '-C', str(alias_consumer), 'init', '-q'], check=True)
    subprocess.run(['git', '-C', str(alias_consumer), 'config', 'user.name', 'test'], check=True)
    subprocess.run(['git', '-C', str(alias_consumer), 'config', 'user.email', 'test@example.com'], check=True)
    (alias_consumer / 'seed.txt').write_text('seed\n')
    (alias_consumer / 'docs/orchestration/prompts/l1-planner.md').write_text(
        'consumer planner policy\n'
    )
    config = {
        'schemaVersion': 'v2', 'targetBranch': 'canary-target', 'gateCommand': 'true',
        'runner': str(selected_engine / 'engine/codex-run.sh'),
        'bootstrap': {'required': False, 'commands': []},
    }
    (alias_consumer / 'singular.config.json').write_text(json.dumps(config))
    subprocess.run(['git', '-C', str(alias_consumer), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(alias_consumer), 'commit', '-qm', 'seed'], check=True)
    subprocess.run(['git', '-C', str(alias_consumer), 'branch', '-M', 'canary-target'], check=True)

    cycle_stub = alias_consumer / 'reconcile-cycle-stub.sh'
    cycle_stub.write_text('''#!/usr/bin/env bash
set -euo pipefail
echo imported_this_run=0
echo dispatched_this_run=0
echo integrated_this_run=0
echo failed_dispatches=0
echo failed_integrations=0
echo planner_failures_this_run=0
echo planner_backoff_active_this_run=0
echo l1_import_rejections_this_run=0
echo reaped_ok=0
echo reaped_failures=0
echo workers_running=0
echo gates_promoted_this_run=0
''')
    cycle_stub.chmod(0o755)

    alias_env = os.environ.copy()
    for key in tuple(alias_env):
        if key.startswith(('SINGULAR_', 'FROZEN_')) or key == 'PYTHONPATH':
            alias_env.pop(key)
    alias_env.update({
        'PATH': '/Library/Frameworks/Python.framework/Versions/3.12/bin:'
                '/opt/homebrew/bin:/usr/bin:/bin',
        'PYTHONDONTWRITEBYTECODE': '1',
        'SINGULAR_ROOT': str(alias_consumer),
        'SINGULAR_STATE_DIR': str(alias_consumer / '.singular-state'),
        'SINGULAR_ENGINE_HOME': str(selected_engine),
        'SINGULAR_CONFIG_FILE': '/dev/null',
        'SINGULAR_LOCAL_CONFIG_FILE': '/dev/null',
        'SINGULAR_BASH_BIN': '/opt/homebrew/bin/bash',
        'SINGULAR_CODEX_BIN': str(selected_engine / 'tests/fixtures/does-not-exist'),
        'SINGULAR_RECONCILE_SCRIPT': str(cycle_stub),
        'SINGULAR_SLEEP': '0',
    })
    campaign = ['/opt/homebrew/bin/bash', str(selected_engine / 'engine/campaign.sh')]
    started = subprocess.run(
        campaign + ['start', '--id', 'alias-evidence', '--allow-provider-unchecked'],
        cwd=alias_consumer, env=alias_env, capture_output=True,
    )
    assert started.returncode == 0, started.stderr.decode()
    verified = subprocess.run(
        campaign + ['verify', '--quiet'], cwd=alias_consumer, env=alias_env,
        capture_output=True,
    )
    assert verified.returncode == 0, verified.stderr.decode()
    binding_result = subprocess.run(
        ['/opt/homebrew/bin/bash', '-c',
         'source "$1"; singular_campaign_binding', 'alias-binding',
         str(selected_engine / 'engine/lib.sh')],
        cwd=alias_consumer, env=alias_env, capture_output=True, text=True,
    )
    assert binding_result.returncode == 0, binding_result.stderr
    alias_binding = binding_result.stdout.strip()
    assert alias_binding.startswith('campaign:alias-evidence:sha256:'), alias_binding

    alias_run = alias_consumer / '.singular-state/runs/RUN-alias-evidence'
    alias_run.mkdir(parents=True)
    alias_data = b'alias broker evidence\n'
    (alias_run / 'packet.json').write_bytes(alias_data)
    alias_manifest = alias_run / 'evidence-manifest.json'
    alias_manifest.write_text(json.dumps({
        'schema': 'singular.orchestration.evidence-manifest.v0',
        'taskId': 'TASK-ALIAS-0001', 'runId': 'RUN-alias-evidence',
        'headSha': 'c' * 40, 'campaignBinding': alias_binding,
        'budget': {'retrievalLimitBytes': 4096, 'excerptLimitBytes': 2048,
                   'limitBytes': 262144},
        'artifacts': [{'ref': 'packet.json', 'sha256': hashlib.sha256(alias_data).hexdigest(),
                       'bytes': len(alias_data)}],
    }))
    alias_ledger = alias_base / 'alias-ledger.sqlite3'
    provider_counter = alias_base / 'provider-calls'
    provider = alias_base / 'fake-provider.py'
    provider.write_text('''import pathlib, subprocess, sys
delivery, manifest, counter = sys.argv[1:]
result = subprocess.run([sys.executable, delivery, "get", manifest, "packet.json"],
                        capture_output=True)
assert result.returncode == 0, result.stderr
assert result.stdout == b"alias broker evidence\\n", result.stdout
path = pathlib.Path(counter)
count = int(path.read_text()) if path.exists() else 0
path.write_text(str(count + 1))
''')
    alias_host = [sys.executable, str(selected_engine / 'engine/evidence_delivery.py'), 'run',
                  '--manifest', str(alias_manifest), '--ledger', str(alias_ledger),
                  '--campaign-binding', alias_binding]
    provider_command = [sys.executable, str(provider),
                        str(selected_engine / 'engine/evidence_delivery.py'),
                        str(alias_manifest), str(provider_counter)]
    admitted_receipt = alias_base / 'admitted-receipt.json'
    admitted = subprocess.run(
        alias_host + ['--receipt', str(admitted_receipt), '--'] + provider_command,
        cwd=alias_consumer, env=alias_env, capture_output=True,
    )
    assert admitted.returncode == 0, admitted.stderr.decode()
    assert provider_counter.read_text() == '1'
    assert json.loads(admitted_receipt.read_text())['status'] == 'admitted'
    with sqlite3.connect(alias_ledger) as db:
        admitted_debit = db.execute('select coalesce(sum(bytes),0) from deliveries').fetchone()[0]
    assert admitted_debit == len(alias_data)

    def assert_pre_provider_denial(receipt, expected_message, expected_binding=alias_binding):
        denied = subprocess.run(
            alias_host[:-1] + [expected_binding, '--receipt', str(receipt), '--']
            + provider_command,
            cwd=alias_consumer, env=alias_env, capture_output=True,
        )
        assert denied.returncode != 0 and expected_message in denied.stderr.decode(), denied.stderr
        denial = json.loads(receipt.read_text())
        assert (denial['status'] == 'denied'
                and denial['denial']['reason'] == 'campaign-mismatch'
                and denial['retrievalDebitBytes'] == 0), denial
        assert provider_counter.read_text() == '1'
        with sqlite3.connect(alias_ledger) as db:
            debit = db.execute('select coalesce(sum(bytes),0) from deliveries').fetchone()[0]
        assert debit == admitted_debit

    drift_target = selected_engine / 'engine/secret-patterns.tsv'
    original_bytes = drift_target.read_bytes()
    original_mode = stat.S_IMODE(drift_target.stat().st_mode)
    try:
        drift_target.write_bytes(original_bytes + b'\nreal content drift\n')
        drift_target.chmod(original_mode)
        assert_pre_provider_denial(alias_base / 'content-drift-receipt.json',
                                   'campaign runtime drift')
        drift_target.write_bytes(original_bytes)
        drift_target.chmod(original_mode ^ stat.S_IXUSR)
        assert_pre_provider_denial(alias_base / 'mode-drift-receipt.json',
                                   'campaign runtime drift')
    finally:
        drift_target.write_bytes(original_bytes)
        drift_target.chmod(original_mode)
    assert_pre_provider_denial(alias_base / 'stale-binding-receipt.json',
                               'campaign identity changed', alias_binding + '-stale')
    restored = subprocess.run(
        campaign + ['verify', '--quiet'], cwd=alias_consumer, env=alias_env,
        capture_output=True,
    )
    assert restored.returncode == 0, restored.stderr.decode()

    # A script symlink beside a different lib.sh is not an authorized bridge,
    # even in legacy mode where no frozen campaign would otherwise reject it.
    bridge = alias_base / 'different-library-bridge'
    bridge.mkdir()
    (bridge / 'evidence_delivery.py').symlink_to(
        selected_engine / 'engine/evidence_delivery.py'
    )
    (bridge / 'lib.sh').write_text('# unrelated library\n')
    legacy_consumer = alias_base / 'legacy-consumer'
    legacy_consumer.mkdir()
    subprocess.run(['git', '-C', str(legacy_consumer), 'init', '-q'], check=True)
    legacy_env = alias_env.copy()
    legacy_env.update({
        'PYTHONPATH': str(selected_engine),
        'SINGULAR_ROOT': str(legacy_consumer),
        'SINGULAR_STATE_DIR': str(legacy_consumer / '.singular-state'),
    })
    different_receipt = alias_base / 'different-library-receipt.json'
    different = subprocess.run(
        [sys.executable, str(bridge / 'evidence_delivery.py'), 'run',
         '--receipt', str(different_receipt), '--'] + provider_command,
        cwd=legacy_consumer, env=legacy_env, capture_output=True,
    )
    assert different.returncode != 0 and b'campaign verifier is unavailable' in different.stderr
    assert json.loads(different_receipt.read_text())['retrievalDebitBytes'] == 0
    assert provider_counter.read_text() == '1'

print('PASS: evidence delivery broker, lexical campaign alias, physical library identity, and drift refusals')
