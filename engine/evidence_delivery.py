#!/usr/bin/env python3
"""Host-owned bounded evidence delivery. Clients only read/connect; never write.

`run` preflights and delivers complete required artifacts in one prompt, charging
before provider launch. Optional paged reads use a local capability socket. A
SQLite host ledger counts repeat deliveries across restart, relocation and
manifest refresh by task/run/campaign (never by mutable manifest pathname).
The sandbox is the role boundary: reviewers cannot write the host ledger or
start an alternative writable broker. Completion means delivered, not accepted.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import socketserver
import sqlite3
import subprocess
import sys
import tempfile
import threading


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Evidence:
    def __init__(self, path):
        self.path = Path(path).resolve()
        self.raw = self.path.read_bytes()
        self.doc = json.loads(self.raw)
        if self.doc.get('schema') != 'singular.orchestration.evidence-manifest.v0':
            raise ValueError('unsupported evidence manifest')
        for field in ('taskId', 'runId', 'headSha'):
            if not isinstance(self.doc.get(field), str) or not self.doc[field]:
                raise ValueError('missing evidence identity: ' + field)
        self.entries = {}
        for item in self.doc['artifacts']:
            ref = item['ref']
            if ref in self.entries:
                raise ValueError('duplicate evidence reference')
            self.entries[ref] = item
        budget = self.doc['budget']
        self.limit = budget['retrievalLimitBytes']
        self.excerpt = budget['excerptLimitBytes']
        if type(self.limit) is not int or not 0 <= self.limit <= 262144:
            raise ValueError('invalid retrieval limit')
        if type(self.excerpt) is not int or not 0 < self.excerpt <= 2048:
            raise ValueError('invalid excerpt limit')
        self.key = sha(json.dumps([self.doc['taskId'], self.doc['runId'],
                                  self.doc.get('campaignBinding', 'legacy')]).encode())

    def read(self, ref):
        if self.path.read_bytes() != self.raw:
            raise ValueError('manifest changed during delivery')
        if ref not in self.entries or ref.startswith('worktree/'):
            raise ValueError('undeclared or non-run-local evidence')
        relative = Path(ref)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('evidence path escape')
        path = (self.path.parent / relative).resolve()
        path.relative_to(self.path.parent)
        data = path.read_bytes()
        if sha(data) != self.entries[ref]['sha256'] or len(data) != self.entries[ref]['bytes']:
            raise ValueError('evidence source identity changed')
        return data


def charge(ledger, evidence, count, detail):
    # Only called by the host. BEGIN IMMEDIATE serializes concurrent brokers.
    with sqlite3.connect(ledger, timeout=10) as db:
        db.execute('CREATE TABLE IF NOT EXISTS deliveries (identity TEXT, bytes INTEGER, detail TEXT)')
        db.execute('BEGIN IMMEDIATE')
        used = db.execute('SELECT coalesce(sum(bytes),0) FROM deliveries WHERE identity=?',
                          (evidence.key,)).fetchone()[0]
        if used + count > evidence.limit:
            raise ValueError('cumulative retrieval budget exhausted')
        db.execute('INSERT INTO deliveries VALUES (?,?,?)',
                   (evidence.key, count, json.dumps(detail, sort_keys=True)))
    return used + count


class Broker(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        try:
            raw = self.rfile.readline(8193)
            if len(raw) > 8192:
                raise ValueError('oversize request')
            request = json.loads(raw)
            if not secrets.compare_digest(request.get('token', ''), self.server.token):
                raise ValueError('unauthorized evidence capability')
            if request.get('role') != self.server.role:
                raise ValueError('unauthorized role')
            e = self.server.evidence
            if request.get('manifestSha256') != sha(e.raw):
                raise ValueError('wrong manifest identity')
            data = e.read(request['ref'])
            offset, count = request['offset'], request['count']
            if type(offset) is not int or type(count) is not int or offset < 0 or count <= 0 or offset > len(data):
                raise ValueError('invalid page bounds')
            count = min(count, e.excerpt, len(data) - offset)
            # Preserve partial final allowance behavior without overspending.
            with self.server.delivery_lock:
                with sqlite3.connect(self.server.ledger) as db:
                    used = db.execute('SELECT coalesce(sum(bytes),0) FROM deliveries WHERE identity=?', (e.key,)).fetchone()[0]
                count = min(count, max(0, e.limit - used))
                if not count and data:
                    raise ValueError('cumulative retrieval budget exhausted')
                view = data[offset:offset + count]
                identity = {'taskId': e.doc['taskId'], 'runId': e.doc['runId'],
                            'headSha': e.doc['headSha'], 'manifestSha256': sha(e.raw),
                            'ref': request['ref'], 'sourceSha256': sha(data),
                            'viewSha256': sha(view), 'offset': offset,
                            'nextOffset': offset + count, 'totalBytes': len(data),
                            'truncated': offset + count < len(data)}
                charge(self.server.ledger, e, count, identity)
            response = {'data': base64.b64encode(view).decode(), 'identity': identity}
        except Exception as error:
            response = {'error': str(error)}
        self.wfile.write(json.dumps(response).encode() + b'\n')


def client(args):
    path = os.environ.get('SINGULAR_EVIDENCE_SOCKET')
    token = os.environ.get('SINGULAR_EVIDENCE_CAPABILITY')
    if not path or not token:
        raise ValueError('host evidence delivery unavailable; run through evidence_delivery.py run')
    request = {'token': token, 'role': os.environ.get('SINGULAR_EVIDENCE_ROLE'),
               'manifestSha256': sha(Path(args.manifest).read_bytes()),
               'ref': args.ref, 'offset': args.offset, 'count': args.count}
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(15)
        channel.connect(path)
        channel.sendall(json.dumps(request).encode() + b'\n')
        with channel.makefile('rb') as stream:
            response = json.loads(stream.readline(32768))
    if 'error' in response:
        raise ValueError(response['error'])
    sys.stderr.write(json.dumps(response['identity'], sort_keys=True) + '\n')
    sys.stdout.buffer.write(base64.b64decode(response['data']))


def run(args):
    e = Evidence(args.manifest)
    ledger = Path(args.ledger).resolve()
    ledger.parent.mkdir(parents=True, exist_ok=True)
    command = args.command
    if command and command[0] == '--':
        command = command[1:]
    if not command:
        raise ValueError('missing child command')
    # Built-in alternate adapters do not currently enforce a filesystem sandbox.
    # Never silently offer them a host ledger as if restoration were isolation.
    if Path(command[0]).name in {'claude-run.sh', 'gemini-run.sh', 'cursor-run.sh',
                                'opencode-run.sh', 'openrouter-run.sh', 'grok-run.sh'}:
        raise ValueError('host evidence delivery requires an OS-enforced read-only adapter; use codex-run.sh')
    # Validate every required source before charge or provider spend. The source
    # snapshot used below is also the exact prompt payload; no second read.
    sources = [(ref, e.read(ref)) for ref in args.required]
    for ref, data in sources:
        if ref in {'packet.json', 'audit-verification.json'}:
            record = json.loads(data)
            for field in ('taskId', 'runId', 'headSha'):
                if record.get(field) != e.doc[field]:
                    raise ValueError('required source identity mismatch: ' + ref + ':' + field)
            if ref == 'audit-verification.json':
                if record.get('sourceIntegrity', {}).get('status') != 'verified':
                    raise ValueError('host source integrity is not verified')
                if record.get('outcome') not in {'passed', 'passed-with-acknowledged-baseline', 'not-rerun-evidence-verified'}:
                    raise ValueError('host verification is incomplete or unsuccessful')
                command_text = record.get('command')
                if not isinstance(command_text, str) or sha(command_text.encode()) != record.get('commandSha256'):
                    raise ValueError('host command binding mismatch')
    with tempfile.TemporaryDirectory(prefix='singular-delivery-') as temporary:
        env = os.environ.copy()
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        env['SINGULAR_EVIDENCE_SOCKET'] = str(Path(temporary) / 'broker.sock')
        env['SINGULAR_EVIDENCE_CAPABILITY'] = secrets.token_hex(32)
        env['SINGULAR_EVIDENCE_ROLE'] = args.role
        if sources:
            if '--prompt-file' not in command:
                raise ValueError('required delivery needs a prompt argument')
            index = command.index('--prompt-file') + 1
            original = Path(command[index]).read_bytes()
            chunks = [original, b'\n\n## Complete host-delivered review evidence\n']
            for ref, data in sources:
                chunks += [('\nArtifact: ' + ref + ' SHA256: ' + sha(data) + '\n').encode(), data, b'\n']
            prompt = b''.join(chunks)
            if len(prompt) > e.doc['budget'].get('limitBytes', 262144):
                raise ValueError('complete review input exceeds composed budget')
            charge(ledger, e, sum(len(data) for _, data in sources),
                   {'kind': 'required-prompt', 'manifestSha256': sha(e.raw),
                    'promptSha256': sha(prompt), 'refs': args.required})
            prompt_path = e.path.parent / ('delivery-prompt-' + sha(prompt) + '.md')
            # Publish complete bytes without truncating an existing immutable view.
            fd, temporary_prompt = tempfile.mkstemp(prefix='.delivery-', dir=e.path.parent)
            try:
                with os.fdopen(fd, 'wb') as output:
                    output.write(prompt)
                    output.flush()
                    os.fsync(output.fileno())
                try:
                    os.link(temporary_prompt, prompt_path)
                except FileExistsError:
                    if prompt_path.read_bytes() != prompt:
                        raise ValueError('prompt identity collision')
            finally:
                os.unlink(temporary_prompt)
            command[index] = str(prompt_path)
        else:
            charge(ledger, e, 0, {'kind': 'broker-open', 'manifestSha256': sha(e.raw)})
        with Broker(env['SINGULAR_EVIDENCE_SOCKET'], Handler) as broker:
            broker.evidence, broker.ledger, broker.token, broker.role = e, ledger, env['SINGULAR_EVIDENCE_CAPABILITY'], args.role
            broker.delivery_lock = threading.Lock()
            thread = threading.Thread(target=broker.serve_forever, daemon=True)
            thread.start()
            try:
                return subprocess.call(command, env=env)
            finally:
                broker.shutdown()
                thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='verb', required=True)
    get = sub.add_parser('get')
    get.add_argument('manifest')
    get.add_argument('ref')
    get.add_argument('count', type=int, nargs='?', default=2048)
    get.add_argument('offset', type=int, nargs='?', default=0)
    host = sub.add_parser('run')
    host.add_argument('--manifest', required=True)
    host.add_argument('--ledger', required=True)
    host.add_argument('--role', choices=['auditor', 'critic'], default='auditor')
    host.add_argument('--required', action='append', default=[])
    host.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        return run(args) if args.verb == 'run' else client(args) or 0
    except (ValueError, OSError, KeyError, sqlite3.Error) as error:
        print('evidence-delivery: ' + str(error), file=sys.stderr)
        return 3


if __name__ == '__main__':
    sys.exit(main())
