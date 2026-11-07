#!/bin/bash
# Fixture-only RED/GREEN: no mounts, helper launches, packaging, or user storage.
set -euo pipefail
cd "$(dirname "$0")/.."
phase="${1:-green}"
case "$phase" in red|green) ;; *) exit 64 ;; esac
base="$PWD/artifacts/manifest-mismatch/policy"
build="$base/build"
export TMPDIR="$base/tmp"
export CLANG_MODULE_CACHE_PATH="$build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$build" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
run() {
    swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$build/RAMNestCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift -o "$build/libRAMNestCore.dylib" || return
    swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -D RAMNEST_LATEST_SNAPSHOT_STANDALONE -D RAMNEST_HOLDING_CLEANUP_STANDALONE -D RAMNEST_POPULATION_READINESS_STANDALONE -D RAMNEST_MOUNTED_FLAG_POLICY_STANDALONE -parse-as-library -I "$build" -L "$build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path Tests/RAMNestCoreTests/LatestSnapshotTests.swift Tests/RAMNestCoreTests/PopulationReadinessTests.swift Tests/RAMNestCoreTests/MountedFlagPolicyTests.swift scripts/MountedFlagPolicyTestRunner.swift -o "$build/population-readiness-tests" || return
    "$build/population-readiness-tests" || return

}
status=0
run > "$base/$phase.log" 2>&1 || status=$?
printf 'Exit status: %s\n' "$status" >> "$base/$phase.log"
cat "$base/$phase.log"
exit "$status"
