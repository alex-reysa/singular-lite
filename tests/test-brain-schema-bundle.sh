#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
name = 'brain-documents.v1.schema.json'
digest = 'fa021bc771393916b6482a894104b03bb037d43e40f13eea2881396e020ff78e'

def checked(path):
    assert path.is_file(), f'public scaffold did not deliver expected schema: {path.name}'
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest, f'wrong schema bytes: {path}'
    schema = json.loads(data)
    assert schema['$id'] == 'https://singular.local/schemas/brain-documents.v1.schema.json'
    assert schema['properties']['schema']['const'] == 'singular.context.brain-documents.v1'

with tempfile.TemporaryDirectory(prefix='brain-schema-bundle-') as scratch:
    tmp = Path(scratch)
    source, install, repo = (tmp / p for p in ('source', 'install', 'consumer'))
    for p in (source, repo, tmp / 'home', tmp / 'bin', tmp / 'state'):
        p.mkdir()
    # Only the installable payload; never copy VCS, live state or configuration.
    for item in ('install.sh', 'engine', 'schemas', 'promoters', 'templates',
                 'plugin', 'singular-ext', 'cli', 'migrations', 'VERSION',
                 'SCHEMA_VERSION', 'CHANGELOG.md'):
        src = root / item
        if src.is_dir():
            shutil.copytree(src, source / item, ignore=shutil.ignore_patterns('__pycache__'))
        elif src.is_file():
            shutil.copy2(src, source / item)
    stub = tmp / 'bin' / 'codex'
    stub.write_text('#!/bin/sh\ncase "$1" in\n--version) echo "codex-cli 0.0.0-stub";;\nlogin) echo "Logged in";;\n*) exit 2;;\nesac\n')
    stub.chmod(0o755)
    # Whitelist ordinary executable settings; discard all inherited consumer,
    # provider credentials, Git selectors, configuration and campaign settings.
    env = {k: os.environ[k] for k in ('PATH', 'TMPDIR', 'LANG') if k in os.environ}
    env.update(HOME=str(tmp / 'home'), PYTHONDONTWRITEBYTECODE='1',
               PATH=f'{install}/bin:{tmp}/bin:' + env.get('PATH', '/usr/bin:/bin'),
               SINGULAR_HOME=str(install), SINGULAR_ROOT=str(repo),
               SINGULAR_STATE_DIR=str(tmp / 'state'),
               SINGULAR_JSON_CONFIG_FILE=str(repo / 'singular.config.json'),
               SINGULAR_CONFIG_FILE=str(tmp / 'config.sh'),
               SINGULAR_LOCAL_CONFIG_FILE=str(tmp / 'local.sh'),
               SINGULAR_CODEX_BIN=str(stub))
    if os.environ.get('SINGULAR_BASH_BIN'):
        env['SINGULAR_BASH_BIN'] = os.environ['SINGULAR_BASH_BIN']

    def run(*args):
        result = subprocess.run(args, cwd=repo, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            print(result.stdout, end='')
            print(result.stderr, end='', file=sys.stderr)
        return result

    result = run('bash', str(source / 'install.sh'))
    assert result.returncode == 0, 'isolated installation failed'
    assert 'is already on PATH' in result.stdout, 'installer global-link guard not reached'
    version = (source / 'VERSION').read_text().strip()
    runtime = install / 'versions' / version
    schema_version = (runtime / 'SCHEMA_VERSION').read_text().strip()
    (repo / 'singular.config.json').write_text(json.dumps({
        'schemaVersion': schema_version, 'engineVersion': version,
        'runner': 'codex-run.sh', 'gateCommand': 'true', 'targetBranch': 'main',
    }))
    (repo / '.singular-version').write_text(version + '\n')
    env.update(SINGULAR_ENGINE_HOME=str(runtime), SINGULAR_ENGINE_DIR=str(runtime / 'engine'),
               SINGULAR_SCHEMA_DIR=str(runtime / 'schemas'),
               SINGULAR_RUNNER=str(runtime / 'engine/codex-run.sh'))
    shutil.rmtree(source)  # Every subsequent entrypoint uses the installed payload.
    assert not (runtime / '.git').exists() and not (runtime / 'tests').exists()

    def scaffold():
        assert run('bash', str(runtime / 'engine/scaffold.sh')).returncode == 0

    def doctor(status, fragment=''):
        # Explicit public option also supports this deliberately non-Git consumer.
        result = run('bash', str(install / 'bin/singular'), 'doctor', '--json',
                     '--repo-root', str(repo))
        report = json.loads(result.stdout)
        assert report['schema'] == 'singular.doctor-report.v1'
        bundle = next(c for c in report['checks'] if c['id'] == 'schema.bundle')
        assert bundle['status'] == status, bundle
        if status == 'fail':
            assert result.returncode != 0
            assert name in bundle['message'] and fragment in bundle['message'], bundle
            assert bundle['remediation'], bundle
        else:
            assert 'repo-consumer' in bundle['details']['consumerSchemaCounts'], bundle
        print(json.dumps({'schema.bundle': bundle, 'doctorExitCode': result.returncode}))

    scaffold()
    consumer = repo / 'schemas/orchestration' / name
    checked(consumer)  # Behavioral red must precede source-file assertions.
    for directory in (root / 'schemas', runtime / 'schemas'):
        checked(directory / name)
        checked(directory / 'orchestration' / name)
        assert {p.name for p in directory.glob('*.schema.json')} == {
            p.name for p in (directory / 'orchestration').glob('*.schema.json')}
    doctor('pass')
    # Exercise both shipped and delivered mirrors, restoring the shipped bytes
    # and invoking public scaffold to repair each consumer after every mutation.
    mirror = runtime / 'schemas/orchestration' / name
    original = mirror.read_bytes()
    for target in (mirror, consumer):
        for mutation, diagnostic in (('absent', 'missing schema copies'),
                                     ('malformed', 'Expecting'),
                                     ('drift', 'differs from authoritative')):
            if mutation == 'absent':
                target.unlink()
            elif mutation == 'malformed':
                target.write_text('{')
            else:
                value = json.loads(original)
                value['title'] = 'Disposable drift'
                target.write_text(json.dumps(value))
            print(f'mutation: {target.parent.name}/{name}: {mutation}')
            doctor('fail', diagnostic)
            mirror.write_bytes(original)
            scaffold()
            checked(consumer)
            checked(mirror)
            doctor('pass')
    print('PASS: brain schema installed delivery, identity, doctor mutations and scaffold repair')
PY
