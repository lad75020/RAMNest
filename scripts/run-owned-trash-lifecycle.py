#!/usr/bin/env python3
"""HOST acceptance only. Fresh physical root, exact CLI, real FSKit, no force/sudo.

Never deletes fixtures or kills processes. On failure, result.json identifies the
exact active owned mount and recovery locations. --prepare-only never mounts.
"""
import argparse, ctypes, hashlib, json, os, socket, stat, subprocess, sys, time, uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--root',type=Path,required=True,help='NEW directory under the approved scratch parent')
p.add_argument('--cli',type=Path,required=True)
p.add_argument('--readback',type=Path,required=True)
p.add_argument('--backend',choices=['fskit'],required=True)
p.add_argument('--prepare-only',action='store_true')
a=p.parse_args()
scratch=Path('/Volumes/WDBlack4TB/.hermes/cache/scratch')
root=a.root.absolute();cli=a.cli.absolute();readback=a.readback.absolute()
assert root.is_relative_to(scratch) and not root.exists() and len(root.parts)>len(scratch.parts)
for path in [root.parent,cli,readback]:
 assert path.exists() and path.resolve()==path, 'physical, non-symlink paths required'
 for parent in [path,*path.parents]: assert not parent.is_symlink(), 'symlink ancestor refused'
assert cli.is_file() and os.access(cli,os.X_OK) and readback.is_file()
root.mkdir(mode=0o700)
token=str(uuid.uuid4());helper=cli.parent/'ramnest-helper'
assert helper.is_file() and helper.resolve()==helper
frozen={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in [cli,helper,readback,cli.parent.parent/'Frameworks/libRAMNestCore.dylib']}
(root/'owner.json').write_text(json.dumps(dict(uuid=token,uid=os.getuid(),cli=str(cli),products=frozen),indent=2)+'\n')
source=root/'source';source.mkdir(mode=0o700);store=root/'store';normal=source/'normal';normal.mkdir(mode=0o700)
(normal/'payload').write_bytes(b'included payload\n');os.link(normal/'payload',source/'alias')
libc=ctypes.CDLL(None,use_errno=True);value=b'included metadata'
assert libc.setxattr(os.fsencode(source/'alias'),b'user.trash-test',value,len(value),0,0)==0
trash=[source/'.Trashes',normal/'.Trashes'];sentinels=[]
for index,d in enumerate(trash):
 d.mkdir(mode=0o700);file=d/('owned-sentinel-'+token);file.write_bytes(('owned disk '+str(index)).encode());sentinels.append(os.open(file,os.O_RDONLY|os.O_NOFOLLOW))
 os.chmod(d,0o311 if index==0 else 0)
def identity(path):
 s=path.lstat();return dict(device=s.st_dev,inode=s.st_ino,mode=stat.S_IMODE(s.st_mode),ctime=s.st_ctime_ns)
before=[identity(d) for d in trash];source_identity=identity(source)
commands=[];result=dict(parentAcceptancePending=True,root=str(root),source=str(source),uuid=token,backend=a.backend,activeOwnedMount=None,steps=[],preexistingTrash=before)
def save(): (root/'result.json').write_text(json.dumps(result,indent=2)+'\n')
def inspect(command):
 child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try: out,err=child.communicate(timeout=30)
 except (subprocess.TimeoutExpired,KeyboardInterrupt):
  result['pendingOwnedInspectionPID']=child.pid;save()
  raise RuntimeError('Owned inspection still running; PID retained without signalling')
 if child.returncode: raise RuntimeError('Owned inspection failed: '+err)
 return out
def mounted():
 lines=inspect(['/sbin/mount']).splitlines()
 return [line for line in lines if ' on '+str(source)+' (' in line]
def run(*args,timeout=240):
 assert json.loads((root/'owner.json').read_text())['uuid']==token
 assert all(hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest for path,digest in frozen.items()),'owned product freeze changed'
 command=[str(cli),'--store',str(store),*map(str,args)]
 child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try: out,err=child.communicate(timeout=timeout)
 except (subprocess.TimeoutExpired,KeyboardInterrupt):
  # Retain a possibly working owned CLI. No process killing or forced teardown.
  result['pendingOwnedCLIPID']=child.pid;save();raise RuntimeError('Owned CLI still running; inspect its PID before any recovery')
 commands.append(dict(command=command,pid=child.pid,exit=child.returncode,stdout=out,stderr=err))
 (root/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
 if child.returncode: raise RuntimeError('Owned CLI '+str(args[0])+' failed; see commands.json')
 return json.loads(out) if '--json' in args else out
def journal(): return json.loads((store/'volumes'/ref/'journal.json').read_text())
def bound_session():
 j=journal();assert j['backend']=='fskit' and uuid.UUID(j['session']) and j['populationVerified'] and j['phase']=='mounted'
 sock=Path(j['socket']);assert len(os.fsencode(sock))<104
 expected='/private/tmp/ramnest-'+str(os.getuid())+'-'+hashlib.sha256(str(store).encode()).hexdigest()[:12]
 assert sock.parent==Path(expected) and sock.name==j['session']+'.sock'
 info=run('info',ref,'--json');assert info['folder']['id']==ref and info['folder']['path']==str(source) and info['mounted'] and info['connected'] and info['helperActive']
 # Read-only control verifies UUID/PID/activation before normal CLI save/eject.
 with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
  s.settimeout(3);s.connect(str(sock));s.sendall(b'status\n');frame=b''
  while not frame.endswith(b'\n'):
   part=s.recv(1024);assert part;frame+=part;assert len(frame)<8192
 fields=frame.decode().strip().split('\t');assert fields[0]=='OK' and fields[1]==ref and fields[3]=='mounted' and fields[6]=='active'
 pid=int(fields[2]);assert pid>1;os.kill(pid,0)  # existence check only
 command=inspect(['/bin/ps','-p',str(pid),'-o','command='])
 expected_helper=cli.parent/'ramnest-helper'
 for binding in [str(expected_helper),'--id '+ref,'--volume '+str(store/'volumes'/ref),'--mount '+str(source),'--socket '+str(sock),'--store '+str(store),'--backend fskit']:
  assert binding in command,'owned helper process binding mismatch: '+binding
 result['ownedHelper']=dict(pid=pid,socket=str(sock),session=j['session'],id=ref)
 assert mounted() and source.stat().st_dev!=source_identity['device'];save();return j
def read():
 command=[str(readback),str(source),str(store),ref]
 child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try: out,err=child.communicate(timeout=60)
 except (subprocess.TimeoutExpired,KeyboardInterrupt):
  result['pendingOwnedReadbackPID']=child.pid;save()
  raise RuntimeError('Owned readback still running; inspect its PID before any recovery')
 commands.append(dict(command=command,pid=child.pid,exit=child.returncode,stdout=out,stderr=err));(root/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
 assert child.returncode==0,'strict compiled consumer readback failed'
try:
 created=run('create',source,'--name','owned-trash-'+token,'--size','64MB','--no-mount','--json');ref=created['id'];assert uuid.UUID(ref) and created['path']==str(source)
 assert [identity(d) for d in trash]==before,'admission mutated original Trash'
 config=store/'configuration.json';c=json.loads(config.read_text());assert len(c['folders'])==1 and c['folders'][0]['id']==ref;c['backend']='fskit';config.write_text(json.dumps(c));os.chmod(config,0o600)
 result['id']=ref;result['steps'].append('owned fixtures and CLI admission verified');save()
 if a.prepare_only:
  result['preparedOnly']=True;save();print(root/'result.json');sys.exit(0)
 preserved=None;held_evidence=None
 for cycle in range(3):
  assert not mounted() and identity(source)['inode']==source_identity['inode']
  run('mount',ref);j=bound_session();read()
  if cycle==0:
   preserved=Path(j['evacuation']);assert preserved.parent==root and preserved.name=='.ramnest-'+ref+'-'+j['session']+'.original' and j['evacuationInode']==preserved.stat().st_ino
   held_evidence=[identity(preserved/'.Trashes'),identity(preserved/'normal/.Trashes')]
   assert [(e['inode'],e['mode']) for e in held_evidence]==[(e['inode'],e['mode']) for e in before]
  # Finder may already have created root Trash after activation. Add only fresh
  # runtime sentinels. Never enumerate or change existing Trash permissions.
  runtime=source/'normal/.Trashes';assert not runtime.exists();runtime.mkdir(mode=0o700)
  fresh=runtime/('ram-'+token);fresh.write_bytes(b'disposable RAM Trash')
  run('save',ref);read();saved=journal();revision=saved['revision']
  fresh.write_bytes(b'dirty disposable RAM Trash');run('save',ref)
  assert journal()['revision']==revision,'Trash-only dirty save must reuse verified included checkpoint'
  read();bound_session();run('unmount',ref)
  assert not mounted(),'owned volume remains mounted; fixtures retained'
  idle=journal();assert idle['phase']=='idle' and idle.get('cleanupWarning') and str(preserved) in idle['cleanupWarning']
  pins=idle.get('siblingCleanup',[]);assert any(x['path']==str(preserved) for x in pins),'original holding is not durably pinned'
  assert identity(source)['inode']==source_identity['inode'] and not (source/'normal/.Trashes').exists()
  read();assert [identity(preserved/'.Trashes'),identity(preserved/'normal/.Trashes')]==held_evidence
  for index,fd in enumerate(sentinels): assert os.pread(fd,64,0)==('owned disk '+str(index)).encode()
  result['steps'].append(dict(cycle=cycle,realFSKit=True,includedExact=True,trashOnlyNoop=True,originalHolding=str(preserved)));save()
 result['parentAcceptancePending']=False;result['passed']=True;save();print(root/'result.json')
except Exception as error:
 result['passed']=False;result['error']=str(error);result['activeOwnedMount']=mounted();save()
 print(json.dumps(result,indent=2),file=sys.stderr);sys.exit(1)
finally:
 for fd in sentinels: os.close(fd)
