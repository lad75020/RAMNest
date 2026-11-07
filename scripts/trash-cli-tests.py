#!/usr/bin/env python3
"""Actual compiled CLI admission; only fresh owned fixtures, retained for evidence."""
import argparse, ctypes, json, os, subprocess, uuid
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--root', type=Path, required=True)
p.add_argument('--cli', type=Path, required=True)
a = p.parse_args()
root = a.root.resolve() / ('admission-' + str(uuid.uuid4()))
root.mkdir(parents=True)
source = root / 'source'; source.mkdir()
trash = source / '.Trashes'; trash.mkdir()
(trash / 'sentinel').write_bytes(b'owned inert trash sentinel')
nested = source / 'normal' / '.Trashes'; nested.mkdir(parents=True)
(nested / 'sentinel').write_bytes(b'owned nested sentinel')
(source / 'normal' / 'payload').write_bytes(b'included bytes')
os.link(source / 'normal' / 'payload', source / 'alias')
libc = ctypes.CDLL(None, use_errno=True)
value = b'included metadata'
assert libc.setxattr(os.fsencode(source / 'alias'), b'user.trash-test', value, len(value), 0, 0) == 0
os.chmod(trash, 0o311); os.chmod(nested, 0)
def evidence(path):
    s = path.lstat()
    return [s.st_dev, s.st_ino, s.st_mode, s.st_ctime_ns]
before = [evidence(trash), evidence(nested)]
command = [str(a.cli.resolve()), '--store', str(root / 'store'), 'create', str(source), '--name', 'owned-trash', '--size', '16MB', '--no-mount']
run = subprocess.run(command, capture_output=True, text=True)
result = dict(command=command, exit=run.returncode, stdout=run.stdout, stderr=run.stderr,
              beforeTrash=before, afterTrash=[evidence(trash), evidence(nested)],
              registeredFolders=len(json.loads((root / 'store' / 'configuration.json').read_text())['folders']) if (root / 'store' / 'configuration.json').exists() else 0,
              trashUnchanged=before == [evidence(trash), evidence(nested)])
(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
assert result['trashUnchanged'], 'source Trash identity/mode/ctime changed'
assert run.returncode == 0, 'exact Trash directory admission must succeed'
assert result['registeredFolders'] == 1
