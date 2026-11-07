#!/usr/bin/env python3
"""HOST ONLY: real FUSE-T operations. All files/configuration are disposable.
Run after scripts/test.sh. Does not use sudo, force-eject, or terminate user apps.
"""
import argparse, errno, hashlib, json, os, pathlib, subprocess, sys, time, uuid
p=argparse.ArgumentParser(); p.add_argument('--prepare-only',action='store_true');p.add_argument('--crash-helper',action='store_true',help='SIGKILL only the disposable test helper to exercise recovery');args=p.parse_args()
project=pathlib.Path(__file__).resolve().parent.parent
root=project/'artifacts'/('host-integration-'+str(uuid.uuid4())); root.mkdir(mode=0o700)
state=root/'support'; selected=root/'selected'; selected.mkdir();(selected/'seed').write_bytes(b'initial\n')
cli=project/'artifacts'/'ramnest'; log=[]
def call(*a,check=True,timeout=60):
    r=subprocess.run([str(cli),'--store',str(state),*map(str,a)],capture_output=True,text=True,timeout=timeout)
    log.append({'args':list(map(str,a)),'code':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
    (root/'commands.json').write_text(json.dumps(log,indent=2))
    if check and r.returncode: raise RuntimeError(f'{a}: {r.returncode}: {r.stderr}')
    return r
ref='Host verification'
def info():return json.loads(call('info',ref,'--json').stdout)
def helper_pid():
    import socket
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
        client.connect(info()['journal']['socket']);client.sendall(b'status\n')
        return int(client.recv(4096).decode().split('\t')[2])
def rss(pid):
    return int(subprocess.check_output(['/bin/ps','-o','rss=','-p',str(pid)],text=True).strip())*1024
def wait_restored():
    for _ in range(100):
        s=info()
        if s['journal']['phase']=='idle':return
        time.sleep(.2)
    raise RuntimeError('External-eject restore did not finish; recovery files retained')
try:
    call('create',selected,'--size','256MB','--name',ref,'--no-mount','--file-comparison-method','checksum')
    if args.prepare_only:
        print(json.dumps({'status':'PREPARED — NO MOUNT ATTEMPTED','root':str(root),'state':str(state),'selected':str(selected)},indent=2));sys.exit(0)
    call('mount',ref)
    s=info();assert s['mounted'] and pathlib.Path(s['folder']['path'])==selected
    assert (selected/'seed').read_bytes()==b'initial\n'
    before=os.stat(selected).st_dev
    pid=helper_pid(); initial_rss=rss(pid)
    (selected/'dir').mkdir();(selected/'dir'/'file').write_bytes(b'payload');os.rename(selected/'dir'/'file',selected/'dir'/'renamed');os.link(selected/'dir'/'renamed',selected/'hard')
    assert os.stat(selected/'hard').st_nlink==2
    fd=os.open(selected/'hard',os.O_RDWR);os.unlink(selected/'hard');os.unlink(selected/'dir'/'renamed');assert os.pread(fd,7,0)==b'payload';os.pwrite(fd,b'changed',0);assert os.pread(fd,7,0)==b'changed';os.close(fd)
    os.symlink('../../outside',selected/'link');assert os.readlink(selected/'link')=='../../outside'
    with open(selected/'sparse','wb') as f:f.seek(32*1024*1024);f.write(b'sparse')
    with open(selected/'sparse','rb') as f:f.seek(32*1024*1024-5);assert f.read(11)==b'\0'*5+b'sparse'
    # Python's os xattr functions are Linux-only on some macOS distributions.
    subprocess.run(['/usr/bin/xattr','-w','user.ramnest','tags',str(selected/'seed')],check=True)
    assert subprocess.check_output(['/usr/bin/xattr','-p','user.ramnest',str(selected/'seed')]).strip()==b'tags'
    subprocess.run(['/usr/bin/xattr','-d','user.ramnest',str(selected/'seed')],check=True)
    # Incompressible content and checksum validation before checking helper usage.
    checksum=hashlib.sha256()
    with open(selected/'random','wb',buffering=0) as f:
        for _ in range(128):
            chunk=os.urandom(1024*1024);checksum.update(chunk);f.write(chunk)
    assert hashlib.sha256((selected/'random').read_bytes()).digest()==checksum.digest()
    peak=info();assert peak['mappedBytes']>=128*1024*1024
    time.sleep(.5); random_rss=rss(pid);assert random_rss>initial_rss+80*1024*1024
    with open(selected/'random','r+b') as f:f.truncate(64*1024*1024)
    time.sleep(.5);assert info()['mappedBytes']<=peak['mappedBytes']-60*1024*1024
    truncate_rss=rss(pid);assert random_rss>truncate_rss+40*1024*1024
    os.unlink(selected/'random');time.sleep(.5);assert info()['mappedBytes']<=1024*1024
    unlink_rss=rss(pid);assert truncate_rss>unlink_rss+40*1024*1024
    # Compressible content: physical backing must save native 16 KiB VM pages.
    with open(selected/'compressible','wb',buffering=0) as f:
        for _ in range(128):f.write(b'A'*1024*1024)
    compressed=info();assert compressed['mappedBytes']<40*1024*1024
    time.sleep(.5); compressed_rss=rss(pid);assert random_rss>compressed_rss+60*1024*1024
    call('resize',ref,'--size','512MB');assert info()['folder']['capacity']==512*1024*1024
    call('resize',ref,'--size','16MB',check=False);assert info()['folder']['capacity']==512*1024*1024
    # ENOSPC uses uncompressed logical allocation even for compressible content.
    try:
        with open(selected/'full','wb',buffering=0) as f:
            for _ in range(600):f.write(b'B'*1024*1024)
            os.fsync(f.fileno())
        raise AssertionError('capacity did not enforce ENOSPC')
    except OSError as e:
        # NFS can report a delayed write failure from fsync or close as well.
        assert e.errno==errno.ENOSPC
    os.unlink(selected/'full');call('save',ref)
    call('unmount',ref,'--ignore-busy');assert os.stat(selected).st_dev!=before
    assert (selected/'compressible').stat().st_size==128*1024*1024
    call('mount',ref);assert (selected/'compressible').read_bytes()==b'A'*(128*1024*1024)
    # External unmount with no GUI: helper retains tree after destroy, then restores.
    (selected/'external-sentinel').write_text('saved after external eject')
    subprocess.run(['/sbin/umount',str(selected)],check=True,cwd=root)
    wait_restored();assert (selected/'external-sentinel').read_text()=='saved after external eject'
    # Temporary discard, lossless live resize, and same initial folder restoration.
    call('options',ref,'--no-sync-folder');call('mount',ref);(selected/'discard-me').write_text('temporary')
    call('resize',ref,'--size','768MB');assert (selected/'discard-me').read_text()=='temporary'
    call('unmount',ref,'--ignore-busy');assert not (selected/'discard-me').exists();assert (selected/'external-sentinel').exists()
    call('options',ref,'--sync-folder')
    if args.crash_helper:
        call('mount',ref);(selected/'durable-sentinel').write_text('committed');call('save',ref)
        s=info();sock=s['journal']['socket']
        import socket,signal
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
            c.connect(sock);c.sendall(b'status\n');pid=int(c.recv(4096).decode().split('\t')[2])
        os.kill(pid,signal.SIGKILL) # only this disposable volume's helper, explicit flag
        # FUSE-T can already have removed the mount after its helper exits.
        if os.path.ismount(selected):
            subprocess.run(['/sbin/umount','-f',str(selected)],check=True,cwd=root)
        assert call('mount',ref,check=False).returncode!=0
        call('recover',ref);assert (selected/'durable-sentinel').read_text()=='committed'
    report={'status':'PASS','root':str(root),'incompressibleMetrics':peak,'compressibleMetrics':compressed,'crashHelperExercised':args.crash_helper,'helperRSS':{'initial':initial_rss,'random128MiB':random_rss,'truncate64MiB':truncate_rss,'unlink':unlink_rss,'compressible128MiB':compressed_rss}}
    (root/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
except Exception as e:
    report={'status':'FAILED OR HOST RESTRICTION','error':str(e),'root':str(root),'recovery':f'{cli} --store {state} recover "{ref}"'}
    (root/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));raise
finally:
    if not args.prepare_only and os.path.ismount(selected):
        try:
            result=call('unmount',ref,'--ignore-busy',check=False)
            if result.returncode:
                print(f'Test volume still needs recovery; committed files retained at {state}',file=sys.stderr)
        except Exception as cleanup_error:
            print(f'Cleanup requires manual recovery: {cleanup_error}',file=sys.stderr)
