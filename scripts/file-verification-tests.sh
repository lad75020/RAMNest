#!/bin/bash
# Standalone Swift/native gates; no mount, Xcode build or real preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/artifacts/verification-mode-run}"
mkdir -p "$output/build/module-cache"
output="$(cd "$output" && pwd)"
export CLANG_MODULE_CACHE_PATH="$output/build/module-cache"
flags=(-D DEBUG -g -Onone -swift-version 6 -target arm64-apple-macosx27.0)
link=(-I "$output/build" -L "$output/build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path)
swiftc "${flags[@]}" -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$output/build/RAMNestCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift -o "$output/build/libRAMNestCore.dylib" > "$output/swift-core-build.log" 2>&1
swiftc "${flags[@]}" -D RAMNEST_VERIFICATION_STANDALONE -parse-as-library "${link[@]}" Tests/RAMNestCoreTests/FileVerificationTests.swift -o "$output/build/file-verification-tests" > "$output/swift-test-build.log" 2>&1
: > "$output/swift-hash-trace.jsonl"
RAMNEST_HASH_TRACE="$output/swift-hash-trace.jsonl" "$output/build/file-verification-tests" > "$output/swift-tests.log" 2>&1
swiftc "${flags[@]}" -parse-as-library "${link[@]}" Sources/RAMNestApp/AppModel.swift scripts/FileVerificationModelTestRunner.swift -o "$output/build/file-verification-model-tests" > "$output/model-build.log" 2>&1
"$output/build/file-verification-model-tests" > "$output/model-tests.log" 2>&1
swiftc -typecheck "${flags[@]}" -parse-as-library -I "$output/build" Sources/RAMNestApp/*.swift > "$output/app-typecheck.log" 2>&1
swiftc "${flags[@]}" -parse-as-library "${link[@]}" Sources/RAMNestCLI/CLI.swift -o "$output/build/ramnest" > "$output/cli-build.log" 2>&1
"$output/build/ramnest" --store "$output/cli-store" file-verification sizeAndModTime > "$output/cli-tests.log"
"$output/build/ramnest" --store "$output/cli-store" file-verification --json >> "$output/cli-tests.log"
python3 - "$output" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
lines = (root / 'cli-tests.log').read_text().splitlines()
assert json.loads(lines[-1]) == 'sizeAndModTime', lines
events = [json.loads(line) for line in (root / 'swift-hash-trace.jsonl').read_text().splitlines()]
weak = [e for e in events if e['fileVerification'] == 'sizeAndModTime']
strong = [e for e in events if e['fileVerification'] == 'sha256']
assert weak and strong and all(e['fileContentSHA256Bytes'] == 0 for e in weak)
assert sum(e['fileContentSHA256Bytes'] for e in strong) > 0
summary = {'weakScans': len(weak), 'weakFileSHA256Bytes': sum(e['fileContentSHA256Bytes'] for e in weak), 'strongScans': len(strong), 'strongFileSHA256Bytes': sum(e['fileContentSHA256Bytes'] for e in strong)}
(root / 'hash-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('PASS CLI persisted policy; Swift no-file-content-SHA trace:', summary)
PY
cmake -S Native -B "$output/native" -DCMAKE_BUILD_TYPE=Debug -DRAMNEST_TEST_ROOT="$output/native/fixtures" > "$output/native-build.log" 2>&1
cmake --build "$output/native" --target ramnest-file-verification-tests ramnest-control-tests ramnest-checksum-integrity-tests ramnest-storage-tests ramnest-helper -j 4 >> "$output/native-build.log" 2>&1
ctest --test-dir "$output/native" --output-on-failure -R 'selectable-file-verification|checksum-|private-storage-format|helper-freeze-privacy' > "$output/native-tests.log" 2>&1
cat "$output/swift-tests.log" "$output/model-tests.log" "$output/native-tests.log"
