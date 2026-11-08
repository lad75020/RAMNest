#!/usr/bin/env python3
"""Run no-mount regression gates in a caller-owned isolated project copy."""
import json, os, shutil, subprocess, sys
from pathlib import Path
source=Path(__file__).resolve().parent.parent
root=Path(sys.argv[1]).resolve()
project=root/'test-project'
project.mkdir(parents=True,exist_ok=True)
for name in ('Sources','Tests','Native','scripts','resources','docs'):
 shutil.copytree(source/name,project/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
for name in ('Package.swift','project.yml','README.md','FEATURE_MATRIX.md','SECURITY.md'):
 shutil.copy2(source/name,project/name)
build=project/'.build/direct';build.mkdir(parents=True,exist_ok=True)
logs=root/'logs';logs.mkdir(exist_ok=True)
env=dict(os.environ,CLANG_MODULE_CACHE_PATH=str(root/'module-cache'),SWIFTPM_MODULECACHE_OVERRIDE=str(root/'module-cache'),TMPDIR=str(root/'tmp'))
(root/'tmp').mkdir(exist_ok=True)
flags=['-g','-Onone','-swift-version','6','-target','arm64-apple-macosx27.0']
link=['-I',str(build),'-L',str(build),'-lRAMNestCore','-Xlinker','-rpath','-Xlinker','@executable_path']
results=[]
def run(name,args):
 with (logs/(name+'.log')).open('w') as out:
  p=subprocess.run(args,cwd=project,env=env,stdout=out,stderr=subprocess.STDOUT)
 results.append({'name':name,'exit':p.returncode,'log':str(logs/(name+'.log'))})
 (root/'swift-gate.json').write_text(json.dumps(results,indent=2)+'\n')
 print(name,p.returncode,flush=True)
 return p.returncode==0
core=['swiftc',*flags,'-module-name','RAMNestCore','-enable-testing','-emit-library','-emit-module','-emit-module-path',str(build/'RAMNestCore.swiftmodule'),'-Xlinker','-install_name','-Xlinker','@rpath/libRAMNestCore.dylib',*map(str,(project/'Sources/RAMNestCore').glob('*.swift')),'-o',str(build/'libRAMNestCore.dylib')]
if not run('swift-core-build',core):sys.exit(1)
platform=Path(subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-platform-path'],env=env,text=True).strip())
compiler=Path(subprocess.check_output(['xcrun','--find','swiftc'],env=env,text=True).strip())
testing_plugins=compiler.parent.parent/'lib/swift/host/plugins/testing'
run('swift-xctest-typecheck',['swiftc','-typecheck',*flags,'-F',str(platform/'Developer/Library/Frameworks'),'-plugin-path',str(testing_plugins),'-I',str(build),*map(str,(project/'Tests/RAMNestCoreTests').glob('*.swift'))])
run('swift-cli-build',['swiftc',*flags,'-parse-as-library',*link,*map(str,(project/'Sources/RAMNestCLI').glob('*.swift')),'-o',str(build/'ramnest')])
run('swift-all-app-typecheck',['swiftc','-typecheck',*flags,'-parse-as-library','-I',str(build),*map(str,(project/'Sources/RAMNestApp').glob('*.swift'))])
run('swift-core-test-build',['swiftc',*flags,'-D','RAMNEST_STANDALONE','-parse-as-library',*link,'Tests/RAMNestCoreTests/CoreTests.swift','scripts/CoreTestRunner.swift','-o',str(build/'core-tests')])
run('swift-core-tests',[str(build/'core-tests')])
(project/'artifacts').mkdir(exist_ok=True)
shutil.copy2(build/'ramnest',project/'artifacts/ramnest')
shutil.copy2(build/'libRAMNestCore.dylib',project/'artifacts/libRAMNestCore.dylib')
run('swift-cli-tests',['python3','scripts/cli-tests.py'])
run('swift-gui-model-build',['swiftc',*flags,'-parse-as-library',*link,'Sources/RAMNestApp/AppModel.swift','Sources/RAMNestApp/AppCommands.swift','scripts/AppModelTestRunner.swift','-o',str(build/'gui-tests')])
run('swift-gui-model-tests',[str(build/'gui-tests')])
for name in ('latest-snapshot','holding-cleanup','quarantine-snapshot','population-readiness','attribute-absence','mounted-flag-policy','backend-selector'):
 run(name,['bash','scripts/'+name+'-tests.sh','green'] if name!='backend-selector' else ['bash','scripts/backend-selector-tests.sh'])
run('sibling-inventory-build',['swiftc',*flags,'-D','RAMNEST_INVENTORY_STANDALONE','-parse-as-library',*link,'Tests/RAMNestCoreTests/SiblingInventoryTests.swift','-o',str(build/'inventory-tests')])
if (build/'inventory-tests').exists():run('sibling-inventory-tests',[str(build/'inventory-tests')])
run('review-swift-build',['swiftc',*flags,'-D','RAMNEST_REVIEW_STANDALONE','-D','RAMNEST_LATEST_SNAPSHOT_STANDALONE','-D','RAMNEST_HOLDING_CLEANUP_STANDALONE','-parse-as-library',*link,'Tests/RAMNestCoreTests/LatestSnapshotTests.swift','Tests/RAMNestCoreTests/ReviewAcceptanceTests.swift','-o',str(build/'review-tests')])
if (build/'review-tests').exists():run('review-swift-tests',[str(build/'review-tests'),str(root/'fixtures')])
env['RAMNEST_ENGINE_FIXTURE']=str(root/'native-Debug/ramnest-engine-protocol-fixture')
run('followup-swift-build',['swiftc',*flags,'-D','RAMNEST_FOLLOWUP_STANDALONE','-D','RAMNEST_LATEST_SNAPSHOT_STANDALONE','-D','RAMNEST_HOLDING_CLEANUP_STANDALONE','-parse-as-library',*link,'Tests/RAMNestCoreTests/LatestSnapshotTests.swift','Tests/RAMNestCoreTests/FollowupTests.swift','-o',str(build/'followup-tests')])
if (build/'followup-tests').exists():
 for case in ('equality','thaw','invalidation-failure','restore','restore-corrupt','restore-replay','restore-replay-split','uuid','process-rename','process-delete','legacy-large','occupied','symlink','protocol','protocol-thawed-receipt','protocol-refrozen-receipt','cursor-replacement','deep'):
  run('followup-'+case,[str(build/'followup-tests'),str(root/'fixtures'),case])
run('callback-source-contract',['python3','scripts/check-callbacks.py'])
run('gui-source-contract',['python3','scripts/check-gui-lifecycle.py'])
run('storage-format-build',['swiftc',*flags,'-D','RAMNEST_STORAGE_STANDALONE','-parse-as-library',*link,'Tests/RAMNestCoreTests/StorageFormatTests.swift','-o',str(build/'storage-tests')])
env['RAMNEST_STORAGE_TEST_ROOT']=str(root/'storage-fixtures')
env['RAMNEST_STORAGE_FIXTURE']=str(root/'native-Debug/ramnest-storage-fixture')
env['RAMNEST_STORAGE_PROTOCOL_FIXTURE']=str(root/'native-Debug/ramnest-storage-protocol-fixture')
env['RAMNEST_STORAGE_COLD_RUNNER']=str(build/'storage-tests')
env['RAMNEST_STORAGE_CLI']=str(build/'ramnest')
if (build/'storage-tests').exists():run('storage-format-tests',[str(build/'storage-tests')])
sys.exit(any(r['exit'] for r in results))
