#!/usr/bin/env python3
"""Build/run the real restrictive storage vertical slice in an explicit run root."""
import argparse, os, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--root',type=Path,required=True)
p.add_argument('--native',type=Path,required=True)
p.add_argument('--old-fixture',type=Path,required=True)
a=p.parse_args();root=a.root.resolve();root.mkdir(parents=True,exist_ok=True)
source=Path(__file__).resolve().parent.parent;build=root/'build';build.mkdir(exist_ok=True)
(root/'tmp').mkdir(exist_ok=True)
env=dict(os.environ,TMPDIR=str(root/'tmp'),CLANG_MODULE_CACHE_PATH=str(root/'module-cache'),SWIFTPM_MODULECACHE_OVERRIDE=str(root/'module-cache'),
         RAMNEST_STORAGE_TEST_ROOT=str(root/'fixtures'),RAMNEST_STORAGE_FIXTURE=str(a.native.resolve()/'ramnest-storage-fixture'),
         RAMNEST_STORAGE_PROTOCOL_FIXTURE=str(a.native.resolve()/'ramnest-storage-protocol-fixture'),
         RAMNEST_STORAGE_OLD_PROTOCOL_FIXTURE=str(a.old_fixture.resolve()),RAMNEST_STORAGE_COLD_RUNNER=str(build/'storage-tests'),RAMNEST_STORAGE_CLI=str(build/'ramnest'))
flags=['-g','-Onone','-swift-version','6','-target','arm64-apple-macosx27.0']
def run(name,args):
 with (root/(name+'.log')).open('w') as out:
  result=subprocess.run(list(map(str,args)),cwd=source,env=env,stdout=out,stderr=subprocess.STDOUT)
 print(name,result.returncode,flush=True)
 if result.returncode:raise SystemExit(result.returncode)
run('core-build',['swiftc',*flags,'-module-name','RAMNestCore','-enable-testing','-emit-library','-emit-module','-emit-module-path',build/'RAMNestCore.swiftmodule','-Xlinker','-install_name','-Xlinker','@rpath/libRAMNestCore.dylib',*(source/'Sources/RAMNestCore').glob('*.swift'),'-o',build/'libRAMNestCore.dylib'])
run('test-build',['swiftc',*flags,'-D','RAMNEST_STORAGE_STANDALONE','-parse-as-library','-I',build,'-L',build,'-lRAMNestCore','-Xlinker','-rpath','-Xlinker','@executable_path','Tests/RAMNestCoreTests/StorageFormatTests.swift','-o',build/'storage-tests'])
run('cli-build',['swiftc',*flags,'-parse-as-library','-I',build,'-L',build,'-lRAMNestCore','-Xlinker','-rpath','-Xlinker','@executable_path',*(source/'Sources/RAMNestCLI').glob('*.swift'),'-o',build/'ramnest'])
run('storage-tests',[build/'storage-tests'])
