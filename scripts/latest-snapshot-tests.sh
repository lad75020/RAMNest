#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
phase="${1:-green}"
case "$phase" in red|green|red-export|red-corrupt) ;; *) exit 64 ;; esac
base="$PWD/artifacts/latest-snapshot"
build="$base/build"
export TMPDIR="$base/tmp"
export CLANG_MODULE_CACHE_PATH="$build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$build" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
run() {
    set -x
    swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$build/RAMNestCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift -o "$build/libRAMNestCore.dylib" || return
    swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -D RAMNEST_LATEST_SNAPSHOT_STANDALONE -parse-as-library -I "$build" -L "$build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path Tests/RAMNestCoreTests/LatestSnapshotTests.swift -o "$build/latest-snapshot-tests" || return
    "$build/latest-snapshot-tests" || return
    swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -D RAMNEST_SNAPSHOT_DESCRIPTOR_STANDALONE -parse-as-library -I "$build" -L "$build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path Tests/RAMNestCoreTests/SnapshotDescriptorTests.swift -o "$build/snapshot-descriptor-tests" || return
    (ulimit -n 96; "$build/snapshot-descriptor-tests")
}
status=0
run > "$base/$phase.log" 2>&1 || status=$?
set +x
printf 'Exit status: %s\n' "$status" >> "$base/$phase.log"
cat "$base/$phase.log"
exit "$status"
