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
import shutil
import socket
import socketserver
import sqlite3
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone

try:
    from engine.context_service import ContextError, ContextOverflow, ContextService
    from engine.campaign_manifest import (
        SETTING_PROJECTION_VERSION,
        resolved_settings_projection,
        runner_child_environment,
    )
except ImportError:  # installed execution from engine/
    from context_service import ContextError, ContextOverflow, ContextService
    from campaign_manifest import (  # type: ignore
        SETTING_PROJECTION_VERSION,
        resolved_settings_projection,
        runner_child_environment,
    )


class AdmissionDenied(ValueError):
    """A deterministic host admission refusal with a stable machine reason."""

    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason


def sha(data):
    return hashlib.sha256(data).hexdigest()


def invocation_setting_evidence(policy_projection=None, *, policy_verified=True):
    projection = resolved_settings_projection()
    encoded = lambda value: 'sha256:' + sha(json.dumps(
        value, sort_keys=True, separators=(',', ':')
    ).encode())
    return {
        'version': SETTING_PROJECTION_VERSION,
        'policySha256': encoded(
            projection['policy'] if policy_projection is None else policy_projection
        ) if policy_verified else None,
        'invocationSha256': encoded(projection['invocation']),
        'transportSha256': encoded(projection['transport']),
    }


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
        self.composed_limit = budget['limitBytes']
        if type(self.limit) is not int or not 0 <= self.limit <= 262144:
            raise ValueError('invalid retrieval limit')
        if type(self.excerpt) is not int or not 0 < self.excerpt <= 2048:
            raise ValueError('invalid excerpt limit')
        if type(self.composed_limit) is not int or not 0 < self.composed_limit <= 262144:
            raise ValueError('invalid composed prompt limit')
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


def delivery_engine_dir():
    """Lexical engine/ directory of this file.

    Same rule as verify_campaign's lib.sh probe: keep the path spelling the
    caller used (a symlink farm of engine/ is valid) but refuse a lexical
    sibling that is not physically this source file.
    """
    lexical_self = Path(os.path.abspath(__file__))
    try:
        physical_self = Path(__file__).resolve(strict=True)
        if (
            lexical_self.is_file()
            and physical_self.is_file()
            and lexical_self.samefile(physical_self)
        ):
            return lexical_self.parent
    except OSError:
        pass
    raise ValueError(
        'host evidence delivery requires an OS-enforced read-only adapter; '
        'engine directory is not the physical sibling of evidence_delivery.py'
    )


def _adapter_table(engine_dir):
    """adapter basename -> provider spec entry, from engine_dir/providers.json."""
    path = Path(engine_dir) / 'providers.json'
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError, TypeError):
        return {}
    providers = data.get('providers') if isinstance(data, dict) else None
    if not isinstance(providers, dict):
        return {}
    table = {}
    for entry in providers.values():
        if not isinstance(entry, dict):
            continue
        adapter = entry.get('adapter')
        if isinstance(adapter, str) and adapter:
            table[adapter] = entry
    return table


def admit_read_only_adapter(command, engine_dir, system):
    """Admit a review-evidence child when it is the engine's own OS-enforced adapter.

    Unknown names (fixture runners) are allowed. A known adapter must be the
    engine file itself -- never a wrapper or copy -- and must declare
    readOnlyEnforcement for `any` or the current platform. Absolute-path
    mechanisms must exist and be executable.
    """
    if not command:
        raise ValueError(
            'host evidence delivery requires an OS-enforced read-only adapter; '
            'missing runner'
        )
    presented = Path(command[0]).name
    resolved = Path(command[0]).resolve(strict=False).name
    adapters = _adapter_table(engine_dir)
    adapter_name = presented if presented in adapters else (
        resolved if resolved in adapters else None
    )
    if adapter_name is None:
        return
    expected = (Path(engine_dir) / adapter_name).resolve()
    actual = Path(command[0]).resolve(strict=False)
    if actual != expected:
        raise ValueError(
            'host evidence delivery requires an OS-enforced read-only adapter; '
            'use the engine file ' + str(expected) + ', not a copy or wrapper'
        )
    entry = adapters[adapter_name]
    enforcement = entry.get('readOnlyEnforcement') or {}
    if not isinstance(enforcement, dict):
        enforcement = {}
    mechanism = None
    if isinstance(enforcement.get('any'), str) and enforcement.get('any'):
        mechanism = enforcement['any']
    elif isinstance(enforcement.get(system), str) and enforcement.get(system):
        mechanism = enforcement[system]
    if not mechanism:
        raise ValueError(
            'host evidence delivery requires an OS-enforced read-only adapter; '
            + adapter_name
            + ' has no declared OS enforcement on '
            + str(system)
            + '; use codex-run.sh'
        )
    if mechanism.startswith('/'):
        tool = Path(mechanism)
        if not tool.is_file() or not os.access(tool, os.X_OK):
            raise ValueError(
                'host evidence delivery requires an OS-enforced read-only adapter; '
                + adapter_name
                + ' declares '
                + mechanism
                + ' but it is missing or not executable; use codex-run.sh'
            )


def _provider_launch_env(require_os_readonly=False):
    env = runner_child_environment()
    if require_os_readonly:
        env['SINGULAR_RUNNER_REQUIRE_OS_READONLY'] = '1'
    return env


def publish_bytes(data, path):
    """Publish one content-addressed immutable file and return its path."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            if path.read_bytes() != data:
                raise ValueError('immutable publication identity collision: ' + str(path))
    finally:
        os.unlink(temporary)
    return path


def publish_bundle(bundle, hint):
    """Publish a unique immutable invocation bundle, preserving the first hint."""
    hint = Path(hint).resolve()
    payload = json.dumps(
        bundle, sort_keys=True, separators=(',', ':'), ensure_ascii=False
    ).encode() + b'\n'
    candidates = [hint]
    name = hint.name
    suffix = bundle['bundleId'].removeprefix('sha256:')
    if name.endswith('.bundle.json'):
        candidates.append(hint.with_name(name[:-12] + '-' + suffix + '.bundle.json'))
    else:
        candidates.append(hint.with_name(name + '-' + suffix))
    for candidate in candidates:
        if candidate.exists():
            if candidate.read_bytes() == payload:
                return candidate
            continue
        return publish_bytes(payload, candidate)
    raise ValueError('immutable invocation bundle identity collision: ' + str(hint))


def write_json(path, value):
    if not path:
        return
    destination = Path(path).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, sort_keys=True, separators=(',', ':')).encode() + b'\n'
    fd, temporary = tempfile.mkstemp(prefix='.' + destination.name + '.', dir=destination.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)


def append_context_event(receipt, path=None):
    path = path or os.environ.get('SINGULAR_EVENTS_FILE')
    if not path or not receipt.get('bundleRef'):
        return
    event = {
        'ts': datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
        'type': 'context.bundle_selected',
        'message': 'context service prompt bundle selected for provider invocation',
        'data': receipt['contextEvent'],
    }
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(event, separators=(',', ':')).encode() + b'\n'
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        view = memoryview(line)
        while view:
            view = view[os.write(descriptor, view):]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def verify_campaign(expected_binding=None):
    """Verify campaign policy and return its canonical resolved projection."""
    # Preserve the selected engine path spelling at this bridge. Campaign
    # policy intentionally fingerprints literal resolved settings, and on
    # systems where /tmp aliases /private/tmp resolving __file__ here would
    # make lib.sh derive a different engine path from the one that created the
    # frozen campaign. Still refuse a lexical sibling that is not physically
    # the library adjacent to the executing source (for example, a symlinked
    # evidence_delivery.py beside an unrelated lib.sh).
    library = Path(os.path.abspath(__file__)).with_name('lib.sh')
    try:
        physical_library = Path(__file__).resolve(strict=True).with_name('lib.sh')
        library_valid = (
            library.is_file()
            and physical_library.is_file()
            and library.samefile(physical_library)
        )
    except OSError:
        library_valid = False
    if not library_valid:
        raise ValueError('campaign verifier is unavailable')
    bash = os.environ.get('SINGULAR_BASH_BIN') or '/opt/homebrew/bin/bash'
    if not Path(bash).is_file():
        bash = '/bin/bash'
    result = subprocess.run(
        [
            bash, '-c',
            'source "$1"; singular_campaign_verify_or_refuse evidence-delivery '
            'provider-boundary || exit $?; actual="$(singular_campaign_binding)" '
            '|| exit $?; [[ -z "$2" || "$actual" == "$2" ]] || { '
            'echo "campaign identity changed at provider boundary" >&2; exit 2; }; '
            'manifest="${SINGULAR_CAMPAIGN_MANIFEST:-$SINGULAR_STATE_DIR/campaign/manifest.json}"; '
            'printf "%s\\n%s\\n" "$actual" "$manifest"',
            'evidence-delivery', str(library), expected_binding or '',
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=os.environ.copy(), text=True, check=False,
    )
    if result.returncode:
        detail = result.stderr.strip() or 'frozen campaign verification failed'
        reason = (
            'context-invalid'
            if 'failed to parse' in detail or 'selected JSON configuration is missing' in detail
            else 'campaign-mismatch'
        )
        raise AdmissionDenied(reason, detail)
    lines = result.stdout.splitlines()
    if len(lines) < 2 or not lines[0]:
        raise AdmissionDenied('campaign-mismatch', 'campaign verifier returned incomplete identity')
    binding, manifest_path = lines[0], lines[1]
    if not binding.startswith('campaign:'):
        return {
            'binding': binding,
            'policy': resolved_settings_projection()['policy'],
        }
    try:
        raw = Path(manifest_path).read_bytes()
        marker = ':sha256:' + sha(raw)
        manifest = json.loads(raw)
        policy = manifest['configuration']['resolvedSettings']
        campaign_id = manifest['campaignId']
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise AdmissionDenied('campaign-mismatch', f'verified campaign policy is unreadable: {exc}') from exc
    if marker not in binding or not binding.startswith('campaign:' + campaign_id + ':'):
        raise AdmissionDenied('campaign-mismatch', 'verified campaign identity does not match manifest bytes')
    if not isinstance(policy, dict):
        raise AdmissionDenied('campaign-mismatch', 'verified campaign resolved policy is invalid')
    return {'binding': binding, 'policy': policy}


def context_event(
    bundle, bundle_path, prompt_path, delivery, required_evidence,
    invocation_id, campaign_binding, final_cap, setting_evidence,
):
    provenance = bundle['provenance']
    reasons = [reason for item in provenance for reason in item.get('reasons', [])]
    prior = next(
        (reason.split(':', 1)[1] for reason in reasons if reason.startswith('prior_bundle:')),
        None,
    )
    return {
        'role': bundle['identity']['role'],
        'phase': bundle['identity']['phase'],
        'bundleId': bundle['bundleId'],
        'promptSha256': bundle['promptSha256'],
        'promptBytes': len(bundle['prompt'].encode()),
        'promptRef': prompt_path.name,
        'bundleRef': bundle_path.name,
        'identity': bundle['identity'],
        'policy': {
            **bundle['policy'],
            'resolvedSettingsProjectionVersion': setting_evidence['version'],
            'resolvedPolicySha256': setting_evidence['policySha256'],
        },
        'invocation': {
            **bundle['invocation'],
            'resolvedInvocationSha256': setting_evidence['invocationSha256'],
            'runnerTransportSha256': setting_evidence['transportSha256'],
        },
        'delivery': {
            'mode': delivery if prior else 'initial',
            'priorBundleId': prior,
            'changedRefs': [item['ref'] for item in provenance if 'changed_source' in item.get('reasons', [])],
            'unchangedRefs': [item['ref'] for item in provenance if 'unchanged_immutable_reference' in item.get('reasons', [])],
            'revokedRefs': [item['ref'] for item in bundle['omissions'] if item.get('reason') == 'revoked_since_prior_bundle'],
        },
        'budget': {**bundle['budget'], 'finalComposedLimitBytes': final_cap},
        'requiredEvidence': required_evidence,
        'omissions': bundle['omissions'],
        'sourceProvenance': [
            {key: item.get(key) for key in ('ref', 'kind', 'sourceSha256', 'validity', 'reasons')}
            for item in provenance
        ],
    }


def run(args):
    command = list(args.command)
    if command and command[0] == '--':
        command = command[1:]
    if not command:
        raise ValueError('missing child command')
    setting_evidence = None
    args._verified_setting_evidence = None

    evidence = Evidence(args.manifest) if args.manifest else None
    if bool(evidence) != bool(args.ledger):
        raise ValueError('manifest and ledger must be supplied together')
    ledger = Path(args.ledger).resolve() if args.ledger else None
    if ledger is not None:
        ledger.parent.mkdir(parents=True, exist_ok=True)

    # Validate the actual adapter by declared OS-enforced capability, never by
    # a name blocklist a wrapper could dodge. Unknown fixture names stay
    # allowed; a known adapter must be the engine's own file.
    require_os_readonly = False
    if evidence is not None:
        admit_read_only_adapter(command, delivery_engine_dir(), sys.platform)
        require_os_readonly = True
    executable = command[0] if os.path.sep in command[0] else shutil.which(command[0])
    if not executable or not Path(executable).is_file() or not os.access(executable, os.X_OK):
        raise ValueError('actual runner is missing or not executable: ' + command[0])

    admitted_campaign = verify_campaign(args.campaign_binding)
    setting_evidence = invocation_setting_evidence(admitted_campaign['policy'])
    args._verified_setting_evidence = setting_evidence

    sources = [(ref, evidence.read(ref)) for ref in args.required] if evidence else []
    for ref, data in sources:
        if ref in {'packet.json', 'audit-verification.json'}:
            record = json.loads(data)
            for field in ('taskId', 'runId', 'headSha'):
                if record.get(field) != evidence.doc[field]:
                    raise ValueError('required source identity mismatch: ' + ref + ':' + field)
            if ref == 'audit-verification.json':
                if record.get('sourceIntegrity', {}).get('status') != 'verified':
                    raise ValueError('host source integrity is not verified')
                if record.get('outcome') not in {
                    'passed', 'passed-with-acknowledged-baseline',
                    'not-rerun-evidence-verified',
                }:
                    raise ValueError('host verification is incomplete or unsuccessful')
                command_text = record.get('command')
                if not isinstance(command_text, str) or sha(command_text.encode()) != record.get('commandSha256'):
                    raise ValueError('host command binding mismatch')

    needs_prompt = bool(sources or args.context_config)
    prompt_index = None
    base_prompt = None
    if needs_prompt:
        if command.count('--prompt-file') != 1:
            raise ValueError('host invocation preparation needs a prompt argument')
        prompt_index = command.index('--prompt-file') + 1
        if prompt_index >= len(command):
            raise ValueError('host invocation prompt argument is missing')
        base_prompt = Path(command[prompt_index]).resolve()

    context = None
    if args.context_config:
        context = ContextService.from_config(
            args.context_config, role=args.context_role, phase=args.context_phase,
            workspace=args.context_workspace,
        )
    context_enabled = bool(context and context.enabled)
    final_cap = evidence.composed_limit if evidence else None
    evidence_snapshots = [
        {'ref': ref, 'data': data, 'sourceLocation': str(evidence.path.parent / ref)}
        for ref, data in sources
    ]

    bundle = None
    bundle_path = None
    delivery = 'delta' if args.context_prior_bundle else 'initial'
    if context_enabled:
        if not args.context_task or not args.context_bundle or not args.context_invocation_id:
            raise ValueError('enabled context invocation is missing task/bundle/invocation identity')
        budget = context.budget_bytes
        bundle = context.build(
            task=args.context_task,
            phase=args.context_phase,
            budget_bytes=budget,
            base_prompt=base_prompt,
            delivery=delivery,
            prior_bundle=args.context_prior_bundle,
            required_evidence=evidence_snapshots,
            final_budget_bytes=final_cap,
            invocation_id=args.context_invocation_id,
            campaign_binding=args.campaign_binding,
        )
        prompt = bundle['prompt'].encode()
    else:
        base_snapshot = base_prompt.read_bytes() if base_prompt else b''
        chunks = [base_snapshot]
        if sources:
            chunks.append(b'\n\n## Complete host-delivered review evidence\n')
            for ref, data in sources:
                chunks += [
                    ('\nArtifact: ' + ref + ' SHA256: ' + sha(data) + '\n').encode(),
                    data, b'\n',
                ]
        prompt = b''.join(chunks)
        if final_cap is not None and len(prompt) > final_cap:
            raise ValueError('complete review input exceeds composed budget')

    # Recheck every mutable input after final composition and before publishing
    # or charging. The published prompt is thereafter the only provider input.
    if base_prompt is not None and not context_enabled:
        if base_prompt.read_bytes() != base_snapshot:
            raise ValueError('mandatory base prompt changed during invocation')
    if evidence is not None:
        for ref, data in sources:
            if evidence.read(ref) != data:
                raise ValueError('evidence source identity changed during delivery')
    # Revalidate the frozen policy after snapshot/composition work and before
    # any immutable publication or retrieval debit.
    if verify_campaign(args.campaign_binding) != admitted_campaign:
        raise AdmissionDenied(
            'campaign-mismatch', 'campaign identity changed during invocation preparation'
        )
    if context_enabled:
        # Validate the exact composed bytes at admission. Publication below is
        # immutable, but this is deliberately a point-in-time snapshot promise,
        # not synchronization with future lifecycle writers.
        context.validate_snapshot()

    publication_dir = evidence.path.parent if evidence else Path(args.context_bundle).resolve().parent
    prompt_path = publish_bytes(
        prompt, publication_dir / ('delivery-prompt-' + sha(prompt) + '.md')
    )
    if bundle is not None:
        bundle_path = publish_bundle(bundle, args.context_bundle)

    required_bytes = sum(len(data) for _, data in sources)
    required_records = [
        {
            'ref': ref, 'bytes': len(data), 'sha256': 'sha256:' + sha(data),
            'sourceLocation': str(evidence.path.parent / ref) if evidence else '',
        }
        for ref, data in sources
    ]
    detail = {
        'kind': 'required-prompt' if sources else 'broker-open',
        'manifestSha256': sha(evidence.raw) if evidence else None,
        'promptSha256': sha(prompt),
        'promptBytes': len(prompt),
        'refs': args.required,
        'requiredEvidenceBytes': required_bytes,
        'bundleId': bundle.get('bundleId') if bundle else None,
        'bundleRef': bundle_path.name if bundle_path else None,
    }
    if evidence is not None:
        charge(ledger, evidence, required_bytes, detail)

    receipt = {
        'schema': 'singular.host-invocation.v1',
        'status': 'admitted',
        'promptPath': str(prompt_path),
        'promptRef': prompt_path.name,
        'promptSha256': 'sha256:' + sha(prompt),
        'promptBytes': len(prompt),
        'bundlePath': str(bundle_path) if bundle_path else None,
        'bundleRef': bundle_path.name if bundle_path else None,
        'bundleId': bundle.get('bundleId') if bundle else None,
        'requiredEvidence': required_records,
        'retrievalDebitBytes': required_bytes,
        'policy': {
            **(bundle.get('policy') if bundle else (
                context.policy_identity if context else {}
            )),
            'resolvedSettingsProjectionVersion': setting_evidence['version'],
            'resolvedPolicySha256': setting_evidence['policySha256'],
        },
        'invocation': {
            **(bundle.get('invocation') if bundle else {
                'invocationId': args.context_invocation_id,
                'campaignBinding': args.campaign_binding or admitted_campaign['binding'],
                'workspace': args.context_workspace,
                'role': args.context_role or args.role,
                'phase': args.context_phase,
            }),
            'resolvedInvocationSha256': setting_evidence['invocationSha256'],
            'runnerTransportSha256': setting_evidence['transportSha256'],
        },
        'contextEvent': context_event(
            bundle, bundle_path, prompt_path, delivery, required_records,
            args.context_invocation_id, args.campaign_binding, final_cap,
            setting_evidence,
        ) if bundle else None,
    }
    write_json(args.receipt, receipt)
    append_context_event(receipt, args.events_file)
    if prompt_index is not None:
        command[prompt_index] = str(prompt_path)

    if evidence is None:
        return subprocess.call(command, env=_provider_launch_env(require_os_readonly))

    with tempfile.TemporaryDirectory(prefix='singular-delivery-') as temporary:
        env = _provider_launch_env(require_os_readonly)
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        env['SINGULAR_EVIDENCE_SOCKET'] = str(Path(temporary) / 'broker.sock')
        env['SINGULAR_EVIDENCE_CAPABILITY'] = secrets.token_hex(32)
        env['SINGULAR_EVIDENCE_ROLE'] = args.role
        with Broker(env['SINGULAR_EVIDENCE_SOCKET'], Handler) as broker:
            broker.evidence, broker.ledger = evidence, ledger
            broker.token, broker.role = env['SINGULAR_EVIDENCE_CAPABILITY'], args.role
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
    host.add_argument('--manifest')
    host.add_argument('--ledger')
    host.add_argument('--role', choices=['auditor', 'critic'], default='auditor')
    host.add_argument('--required', action='append', default=[])
    host.add_argument('--context-config')
    host.add_argument('--context-workspace')
    host.add_argument('--context-role')
    host.add_argument('--context-phase')
    host.add_argument('--context-task')
    host.add_argument('--context-prior-bundle')
    host.add_argument('--context-bundle')
    host.add_argument('--context-invocation-id')
    host.add_argument(
        '--campaign-binding', '--context-campaign-binding', dest='campaign_binding'
    )
    host.add_argument('--receipt')
    host.add_argument('--events-file')
    host.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        return run(args) if args.verb == 'run' else client(args) or 0
    except (ValueError, ContextError, OSError, KeyError, sqlite3.Error) as error:
        receipt_already_admitted = False
        if args.verb == 'run' and args.receipt and Path(args.receipt).is_file():
            try:
                receipt_already_admitted = (
                    json.loads(Path(args.receipt).read_text(encoding='utf-8')).get('status')
                    == 'admitted'
                )
            except (OSError, ValueError):
                receipt_already_admitted = False
        if args.verb == 'run' and not receipt_already_admitted:
            denied_setting_evidence = getattr(args, '_verified_setting_evidence', None)
            if denied_setting_evidence is None:
                denied_setting_evidence = invocation_setting_evidence(policy_verified=False)
            if isinstance(error, AdmissionDenied):
                reason = error.reason
            elif isinstance(error, ContextOverflow):
                reason = 'prompt-overflow'
            elif isinstance(error, ContextError):
                reason = 'context-invalid'
            elif isinstance(error, OSError):
                reason = 'source-invalid'
            else:
                reason = 'admission-invalid'
            write_json(args.receipt, {
                'schema': 'singular.host-invocation.v1',
                'status': 'denied',
                'denial': {'reason': reason, 'message': str(error)},
                'retrievalDebitBytes': 0,
                'policy': {
                    'configPath': str(Path(args.context_config).resolve())
                    if args.context_config else None,
                    'resolvedSettingsProjectionVersion': denied_setting_evidence['version'],
                    'resolvedPolicySha256': denied_setting_evidence['policySha256'],
                },
                'invocation': {
                    'invocationId': args.context_invocation_id,
                    'campaignBinding': args.campaign_binding,
                    'workspace': args.context_workspace,
                    'role': args.context_role or args.role,
                    'phase': args.context_phase,
                    'resolvedInvocationSha256': denied_setting_evidence['invocationSha256'],
                    'runnerTransportSha256': denied_setting_evidence['transportSha256'],
                },
            })
        print('evidence-delivery: ' + str(error), file=sys.stderr)
        return 3


if __name__ == '__main__':
    sys.exit(main())
