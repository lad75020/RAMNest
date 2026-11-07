#!/usr/bin/env python3
"""Runs real CLI processes against disposable local configuration, without mounts."""
import concurrent.futures, json, pathlib, subprocess, uuid
root = pathlib.Path(__file__).resolve().parent.parent
fixture = root / 'artifacts' / ('cli-tests-' + str(uuid.uuid4()))
fixture.mkdir(mode=0o700)
state = fixture / 'support'
cli = root / 'artifacts' / 'ramnest'
def call(*args, expected=0):
    result = subprocess.run([str(cli), '--store', str(state), *map(str,args)], capture_output=True, text=True, timeout=20)
    assert result.returncode == expected, (args,result.returncode,result.stdout,result.stderr)
    return result
assert 'RAMNest' in call('--version').stdout
assert 'remote setup' not in call('--help').stdout
assert json.loads(call('list','--all','--json').stdout) == []
paths = []
for index in range(8):
    folder = fixture / f'folder-{index}'; folder.mkdir(); (folder/'sentinel').write_text(f'initial {index}')
    paths.append(folder)
def create(index):
    return json.loads(call('create', paths[index], '--size','16MB','--name',f'Folder {index}','--no-mount','--json').stdout)
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    created = list(pool.map(create,range(8)))
statuses = json.loads(call('ls','--all','--json').stdout)
assert len(statuses) == 8
assert all(s['folder']['options']['compression'] for s in statuses)
info = json.loads(call('info','ram://Folder%200','--json').stdout)
assert info['folder']['id'] == created[0]['id']
call('options','Folder 0','--no-compression','--periodic','5','--no-mount-at-launch')
info = json.loads(call('info','Folder 0','--json').stdout)
assert not info['folder']['options']['compression'] and info['folder']['options']['periodicSave']
call('rename','Folder 0','--name','Renamed')
call('resize','Renamed','--size','32MB')
assert json.loads(call('info','Renamed','--json').stdout)['folder']['capacity'] == 32*1024*1024
call('create',paths[0],'--size','16MB','--name','Duplicate','--no-mount',expected=4)
error = call('create', paths[1], '--size', 'bad', '--json',expected=64)
assert 'error' in json.loads(error.stderr)
call('delete','Renamed','--destroy',expected=64)
call('delete','Renamed','--keep')
assert (paths[0]/'sentinel').read_text() == 'initial 0'
assert len(json.loads(call('ls','--all','--json').stdout)) == 7
call('remote','list',expected=64)
binpath=fixture/'bin';binpath.mkdir();call('install-cli',binpath)
launcher=subprocess.run([str(binpath/'ramnest'),'--version'],capture_output=True,text=True,timeout=10);assert launcher.returncode==0 and 'RAMNest' in launcher.stdout
call('install-cli',binpath,expected=4)
print('PASS real CLI: help/version/JSON, eight concurrent creators, shared locking/state, references, options/compression/periodic, rename/resize, duplicate and malformed arguments, explicit destructive confirmation, keep-default deletion, local-only surface')
print('Fixtures:',fixture)
