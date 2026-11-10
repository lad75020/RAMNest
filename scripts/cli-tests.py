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
unopened = fixture / 'parsing-only-store'
for arguments in [[], ['--help','--unknown'], ['--version','--unknown'], ['native-build-identity','--json']]:
    result = subprocess.run([str(cli),'--store',str(unopened),*arguments],capture_output=True,text=True,timeout=20)
    assert result.returncode == 0, (arguments,result.stderr)
    assert not unopened.exists(), 'early diagnostics must not open a store'
result = subprocess.run([str(cli),'--json','--store'],capture_output=True,text=True,timeout=20)
assert result.returncode == 64 and json.loads(result.stderr)['error'] == '--store requires a directory.'
result = subprocess.run([str(cli),'--store',str(unopened),'list','--store',str(fixture),'--json'],capture_output=True,text=True,timeout=20)
assert result.returncode == 64 and json.loads(result.stderr)['error'] == 'Unknown option: --store'
assert not unopened.exists(), 'only the first --store is extracted, before generic parsing'
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
assert all('compression' not in s['folder']['options'] for s in statuses)
info = json.loads(call('info','ram://Folder%200','--json').stdout)
assert info['folder']['id'] == created[0]['id']
call('options','Folder 0','--periodic','5','--no-mount-at-launch')
call('options','Folder 0','--compression',expected=64)
info = json.loads(call('info','Folder 0','--json').stdout)
assert 'compression' not in info['folder']['options'] and info['folder']['options']['periodicSave']
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
# Long options beat short aliases regardless of position; repeated values for
# the same spelling keep their last value. These commands never mount fixtures.
for index, size_args in enumerate([['--size','16MB','-s','32MB'], ['-s','32MB','--size','32MB','--size','16MB']]):
    source = fixture / f'parse-{index}'; source.mkdir()
    name_args = ['--name','First long name','--name',f'Parsed {index}']
    name_args = name_args + ['-n','Alias name'] if index == 0 else ['-n','Alias name'] + name_args
    parsed = json.loads(call('create', source, *size_args, *name_args, '--no-mount','--json').stdout)
    assert parsed['capacity'] == 16*1024*1024 and parsed['name'] == f'Parsed {index}'
    ref = parsed['id']
    for yes, no, key in [('--sync-folder','--no-sync-folder','sync'), ('--nobrowse','--no-nobrowse','nobrowse'),
                         ('--mount-at-launch','--no-mount-at-launch','mountAtLaunch')]:
        for flag, expected in [(no,False), (yes,True)]:
            call('options',ref,flag)
            assert json.loads(call('info',ref,'--json').stdout)['folder']['options'][key] is expected
        result = call('options',ref,yes,no,'--json',expected=64)
        assert json.loads(result.stderr)['error'] == f'Conflicting options: {yes} and {no}'
    for periodic in [['--no-periodic','--periodic','30'], ['--periodic','30','--no-periodic'], ['--periodic','5','--periodic','30']]:
        call('options',ref,*periodic)
        options = json.loads(call('info',ref,'--json').stdout)['folder']['options']
        assert options['periodicSave'] and options['intervalMinutes'] == 30
    call('options',ref,'--no-periodic')
    assert not json.loads(call('info',ref,'--json').stdout)['folder']['options']['periodicSave']
    # An option-looking value is still consumed as a value. JSON error/output
    # selection observes the raw argv, even when --json is that name value.
    assert json.loads(call('rename',ref,'--name','--json').stdout) == {'ok':True}
    assert json.loads(call('info',ref,'--json').stdout)['folder']['name'] == '--json'
    call('delete',ref,'--keep')
for args, message in [(['options','missing','--periodic'], '--periodic requires a value.'),
                      (['list','--confirm-reset'], 'RESET options are accepted only by reset.'),
                      (['list','--reset-bootstrap',str(fixture)], 'RESET options are accepted only by reset.'),
                      (['list','--unknown'], 'Unknown option: --unknown')]:
    error = json.loads(call(args[0],'--json',*args[1:],expected=64).stderr)
    assert error == {'error':message, 'exitCode':'64'}
assert 'RAMNest' in call('--help','--unknown').stdout
assert 'RAMNest 1.0.0' in call('--version','--unknown').stdout
call('remote','list',expected=64)
binpath=fixture/'bin';binpath.mkdir();call('install-cli',binpath)
launcher=subprocess.run([str(binpath/'ramnest'),'--version'],capture_output=True,text=True,timeout=10);assert launcher.returncode==0 and 'RAMNest' in launcher.stdout
call('install-cli',binpath,expected=4)
print('PASS real CLI: help/version/JSON, early diagnostics, parsing/alias/periodic precedence, eight concurrent creators, shared locking/state, references, options/native-only/periodic, rename/resize, duplicate and malformed arguments, explicit destructive confirmation, keep-default deletion, local-only surface')
print('Fixtures:',fixture)
