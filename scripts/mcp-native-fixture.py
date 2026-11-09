#!/usr/bin/env python3
"""Explicitly authorized, bounded OWNED native lifecycle. Never runs in tests by default."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
from importlib.machinery import SourceFileLoader

assert os.environ.get('RAMNEST_MCP_AUTHORIZE_NATIVE_FIXTURE') == 'YES', (
    'Requires explicit interactive authorization: RAMNEST_MCP_AUTHORIZE_NATIVE_FIXTURE=YES. '
    'This mounts/ejects an owned 32 MiB fixture and invokes macOS administrator dialogs. '
    'Do not type credentials through automation.')
assert len(sys.argv) == 3, 'usage: mcp-native-fixture.py /absolute/ramnest-mcp /absolute/RAMNest.app'
protocol = SourceFileLoader('ramnest_mcp_protocol', str(Path(__file__).with_name('mcp-protocol-tests.py'))).load_module()
artifacts = Path(__file__).resolve().parents[1] / 'artifacts'
artifacts.mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='ramnest-mcp-native-owned-', dir=artifacts)).resolve()
source = root / 'source'
source.mkdir()
(source / 'payload').write_bytes(b'initial owned fixture\n')
session = protocol.Session(sys.argv[1], root / 'store', app=sys.argv[2])
completed = False
print(f'Owned native evidence directory: {root}', flush=True)
try:
    session.initialize()
    capability = session.call('capabilities')
    assert capability['package']['available'], capability
    folder = session.call('folder_create', dict(path=str(source), capacityBytes=32 << 20,
                         name='Owned MCP native fixture', options=dict(mountAtLaunch=False)))
    ref = dict(id=folder['id'])
    session.call('folder_mount', ref, timeout=620)
    assert session.call('folder_info', ref)['mounted'] is True
    (source / 'payload').write_bytes(b'saved owned fixture\n')
    session.call('folder_save', ref, timeout=620)
    session.call('folder_unmount', ref, timeout=620)
    assert session.call('folder_info', ref)['mounted'] is False
    assert not source.is_symlink()
    assert (source / 'payload').read_bytes() == b'saved owned fixture\n'
    session.call('folder_delete', ref)
    session.call('settings_reset', dict(confirmation='RESET RAMNEST'))
    session.close()
    completed = True
    print('PASS actual packaged MCP mount/save/unmount and original publication')
finally:
    if session.process.poll() is None:
        session.process.stdin.close()
        session.process.wait(timeout=650)  # includes the bounded packaged native operation
    if completed:
        shutil.rmtree(root)
    else:
        print(f'FAILED/INTERRUPTED: retained {root}. Inspect journal/status. No automatic force-unmount or cleanup.', file=sys.stderr)
