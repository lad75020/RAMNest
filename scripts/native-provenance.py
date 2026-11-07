"""Record the actual source, compiler command and packaged helper identity."""
import hashlib,json,sys
from pathlib import Path
source,build,configuration=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
sources={str(p.relative_to(source)):sha(p) for p in sorted((source/'Native').glob('*')) if p.is_file()}
inputs=build/'source-inputs.json'
if len(sys.argv)>4 and sys.argv[4]=='--prepare':
 inputs.write_text(json.dumps(sources,indent=2)+'\n')
 sys.exit(0)
if not inputs.exists() or json.loads(inputs.read_text())!=sources:
 raise SystemExit('Native sources changed during build or input receipt missing; rebuild in a fresh isolated directory')
commands=json.loads((build/'compile_commands.json').read_text())
native=next(c['command'] for c in commands if c['file']==str(source/'Native/MemoryFS.cpp'))
if configuration!='Debug' and ('-O2' not in native and '-O3' not in native):raise SystemExit('Native optimization missing')
for c in commands:
 if c['file'].endswith('Tests.cpp') and '-UNDEBUG' not in c['command']:raise SystemExit('Test assertions disabled')
value={'configuration':configuration,'memoryCompileCommand':native,'helperSHA256':sha(build/'ramnest-helper'),'sources':sources}
(build/'provenance.json').write_text(json.dumps(value,indent=2)+'\n')
