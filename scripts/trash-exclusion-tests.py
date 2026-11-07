#!/usr/bin/env python3
"""Owned no-mount Trash vertical; executes freshly compiled Core and CLI."""
import argparse, json, os, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--root',type=Path,required=True)
a=p.parse_args();root=a.root.resolve();build=root/'focused';logs=root/'logs'
build.mkdir(parents=True,exist_ok=True);logs.mkdir(exist_ok=True)
source=Path(__file__).resolve().parent.parent
env=dict(os.environ,CLANG_MODULE_CACHE_PATH=str(root/'module-cache'),RAMNEST_TRASH_TEST_ROOT=str(root/'trash-fixtures'))
flags=['-g','-Onone','-swift-version','6','-target','arm64-apple-macosx27.0']
link=['-I',str(build),'-L',str(build),'-lRAMNestCore','-Xlinker','-rpath','-Xlinker','@executable_path']
results=[]
def run(name,command):
 with (logs/(name+'.log')).open('w') as out:
  result=subprocess.run(list(map(str,command)),cwd=source,env=env,stdout=out,stderr=subprocess.STDOUT)
 results.append(dict(name=name,command=list(map(str,command)),exit=result.returncode))
 (root/'trash-gate.json').write_text(json.dumps(results,indent=2)+'\n')
 print(name,result.returncode,flush=True)
 if result.returncode:raise SystemExit(result.returncode)
run('trash-core-build',['swiftc',*flags,'-module-name','RAMNestCore','-enable-testing','-emit-library','-emit-module','-emit-module-path',build/'RAMNestCore.swiftmodule','-Xlinker','-install_name','-Xlinker','@rpath/libRAMNestCore.dylib',*sorted((source/'Sources/RAMNestCore').glob('*.swift')),'-o',build/'libRAMNestCore.dylib'])
run('trash-test-build',['swiftc',*flags,'-D','RAMNEST_TRASH_STANDALONE','-parse-as-library',*link,'Tests/RAMNestCoreTests/TrashExclusionTests.swift','-o',build/'trash-tests'])
run('trash-cli-build',['swiftc',*flags,'-parse-as-library',*link,*sorted((source/'Sources/RAMNestCLI').glob('*.swift')),'-o',build/'ramnest'])
run('trash-swift-tests',[build/'trash-tests'])
run('trash-actual-cli',['python3','scripts/trash-cli-tests.py','--root',root/'green-cli','--cli',build/'ramnest'])
