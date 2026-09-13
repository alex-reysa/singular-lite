import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
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
        if key.startswith('SINGULAR_'):
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
print('PASS: OS-enforced read-only pagination, concurrent budget, replay/relocation, source tamper and unavailable host')
