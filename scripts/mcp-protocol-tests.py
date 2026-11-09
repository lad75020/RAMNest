#!/usr/bin/env python3
"""Actual stdio JSON-RPC test, with only owned store/source fixtures. No mounts."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


class Session:
    def __init__(self, executable, store, app=None):
        args = [str(Path(executable).resolve()), '--store', str(Path(store).resolve())]
        if app:
            args += ['--app', str(Path(app).resolve())]
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, bufsize=1)
        self.messages = queue.Queue()
        self.stderr = []
        self.next_id = 0
        def read_stdout():
            for line in self.process.stdout:
                try:
                    self.messages.put(json.loads(line))
                except Exception as error:
                    self.messages.put(error)
            self.messages.put(EOFError('stdout closed'))
        def read_stderr():
            for line in self.process.stderr:
                self.stderr.append(line)
        self.readers = [threading.Thread(target=read_stdout, daemon=True),
                        threading.Thread(target=read_stderr, daemon=True)]
        for thread in self.readers:
            thread.start()

    def request(self, method, params=None, timeout=15):
        self.next_id += 1
        request = dict(jsonrpc='2.0', id=self.next_id, method=method)
        if params is not None:
            request['params'] = params
        self.process.stdin.write(json.dumps(request) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(message, Exception):
                raise AssertionError(f'Nonprotocol stdout/EOF: {message}; stderr={self.stderr}')
            assert message.get('jsonrpc') == '2.0', message
            if message.get('id') == self.next_id:
                return message
            assert 'method' in message and 'id' not in message, message

    def initialize(self):
        response = self.request('initialize', dict(protocolVersion='2025-11-25', capabilities={},
                                clientInfo=dict(name='RAMNest-owned-acceptance', version='1')))
        assert 'result' in response, response
        assert response['result']['serverInfo']['name'] == 'RAMNest'
        self.process.stdin.write(json.dumps(dict(jsonrpc='2.0', method='notifications/initialized')) + '\n')
        self.process.stdin.flush()

    def call(self, name, arguments=None, error=False, timeout=15):
        response = self.request('tools/call', dict(name=name, arguments=arguments or {}), timeout)
        assert 'result' in response, response
        result = response['result']
        assert bool(result.get('isError', False)) == error, result
        assert result['content'][0]['type'] == 'text', result
        return json.loads(result['content'][0]['text'])

    def close(self):
        self.process.stdin.close()
        code = self.process.wait(timeout=8)
        for reader in self.readers:
            reader.join(timeout=2)
        assert code == 0, (code, self.stderr)
        # Every stdout line must have passed the JSON parser, including shutdown.
        while not self.messages.empty():
            item = self.messages.get()
            assert not isinstance(item, Exception) or isinstance(item, EOFError), item


def main():
    assert len(sys.argv) == 2, 'usage: mcp-protocol-tests.py /absolute/ramnest-mcp'
    artifacts = Path(__file__).resolve().parents[1] / 'artifacts'
    artifacts.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ramnest-mcp-protocol-', dir=artifacts) as temp:
        root = Path(temp).resolve()
        store, source = root / 'store', root / 'source'
        source.mkdir()
        (source / 'payload').write_bytes(b'owned original bytes\n')
        s = Session(sys.argv[1], store)
        try:
            # MCP permits ping before initialization. SDK 0.12.1 drops other
            # pre-initialize requests rather than returning a wire error.
            assert 'result' in s.request('ping')
            assert not store.exists()
            s.initialize()
            tools = s.request('tools/list')['result']['tools']
            names = {tool['name'] for tool in tools}
            assert len(names) == 30, names
            for tool in tools:
                assert tool['inputSchema']['additionalProperties'] is False, tool
                for field in tool['inputSchema']['properties'].values():
                    if field.get('type') == 'object':
                        assert field['additionalProperties'] is False
                s.call(tool['name'], {'unexpected': True}, error=True)
            for name in ['capabilities', 'settings_get', 'folder_list', 'storage_status']:
                s.call(name)
            resources = s.request('resources/list')['result']['resources']
            assert len(resources) == 4
            for resource in resources:
                value = s.request('resources/read', {'uri': resource['uri']})
                json.loads(value['result']['contents'][0]['text'])
            assert 'error' in s.request('resources/read', {'uri': 'file:///etc/passwd'})
            prompts = s.request('prompts/list')['result']['prompts']
            assert len(prompts) == 1
            assert s.request('prompts/get', {'name': prompts[0]['name']})['result']['messages']
            assert 'error' in s.request('prompts/get', {'name': prompts[0]['name'], 'arguments': {'unknown': 'x'}})
            assert 'error' in s.request('prompts/get', {'name': 'unknown'})
            s.call('arbitrary_shell', {'command': 'true'}, error=True)
            s.call('folder_create', {'path': str(source), 'capacityBytes': '33554432'}, error=True)
            created = s.call('folder_create', {'path': str(source), 'capacityBytes': 32 << 20, 'name': 'Protocol fixture'})
            ref = {'id': created['id']}
            info = s.call('folder_info', ref)
            assert not info['mounted'] and info['journal']['phase'] == 'idle'
            assert s.call('folder_rename', dict(ref, name='Renamed'))['name'] == 'Renamed'
            options = dict(mountAtLaunch=False, nobrowse=False, sync=True, periodicSave=True,
                           intervalMinutes=30, comparison='checksum')
            edited = s.call('folder_options', dict(ref, options=options))
            assert all(edited['options'][key] == value for key, value in options.items())
            s.call('folder_options', dict(ref, options={'compression': True}), error=True)
            s.call('folder_options', dict(ref, options={'intervalMinutes': 6}), error=True)
            prefs = dict(fileVerification='sizeAndModTime', menuBarMode=True)
            s.call('settings_update', prefs)
            assert all(s.call('settings_get')[key] == value for key, value in prefs.items())
            s.call('folder_export', dict(ref, destination=str(root / 'export')), error=True)
            s.call('folder_recover', ref, error=True)
            s.call('folder_delete', dict(ref, destroy=True, confirmation='yes'), error=True)
            s.call('settings_reset', {'confirmation': 'yes'}, error=True)
            s.call('folder_delete', ref)
            assert (source / 'payload').read_bytes() == b'owned original bytes\n'
            s.call('folder_create', {'path': str(source), 'capacityBytes': 32 << 20})
            s.call('settings_reset', {'confirmation': 'RESET RAMNEST'})
            assert s.call('folder_list') == []
            assert (source / 'payload').read_bytes() == b'owned original bytes\n'
            s.close()
        finally:
            if s.process.poll() is None:
                s.process.terminate()
                s.process.wait(timeout=8)
        # EOF without initialization must also exit cleanly, without opening a store.
        unopened = root / 'unopened'
        s = Session(sys.argv[1], unopened)
        s.close()
        assert not unopened.exists()
        signalled = root / 'signal-unopened'
        s = Session(sys.argv[1], signalled)
        s.initialize()
        s.process.terminate()
        assert s.process.wait(timeout=8) == 0
        s.process.stdin.close()
        for reader in s.readers:
            reader.join(timeout=2)
        assert not signalled.exists()
        print(f'PASS actual MCP JSON-RPC: {len(names)} tools, 4 resources, 1 prompt, owned lifecycle, strict args, EOF')


if __name__ == '__main__':
    main()
