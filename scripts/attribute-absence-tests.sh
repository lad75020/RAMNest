#!/bin/bash
# Owned in-process fixtures only; never launches the helper or mounts a volume.
set -euo pipefail
cd "$(dirname "$0")/.."
phase="${1:-green}"
case "$phase" in red|green) ;; *) exit 64 ;; esac
base="$PWD/artifacts/eio-fix/compatibility"
build="$base/build"
export TMPDIR="$PWD/artifacts/eio-fix/tmp"
export CLANG_MODULE_CACHE_PATH="$build/module-cache"
mkdir -p "$build" "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
native() {
    set -x
    clang++ -std=c++20 -g -O0 -Wall -Wextra -DFUSE_USE_VERSION=26 -D_FILE_OFFSET_BITS=64 -I '/Library/Application Support/fuse-t/include/fuse' Native/AttributeAbsenceTests.cpp Native/MemoryFS.cpp -lcompression '/Library/Application Support/fuse-t/lib/libfuse-t-1.2.9.dylib' -Wl,-rpath,'/Library/Application Support/fuse-t/lib' -o "$build/attribute-absence-native" || return
    install_name_tool -change @rpath/libfuse-t.dylib "/Library/Application Support/fuse-t/lib/libfuse-t-1.2.9.dylib" "$build/attribute-absence-native" || return
    codesign --force --sign - "$build/attribute-absence-native" || return
    "$build/attribute-absence-native"
}
swift() {
    set -x
    swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$build/RAMNestCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift -o "$build/libRAMNestCore.dylib" || return
    swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -D RAMNEST_ATTRIBUTE_ABSENCE_STANDALONE -parse-as-library -I "$build" -L "$build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path Tests/RAMNestCoreTests/AttributeAbsenceTests.swift scripts/AttributeAbsenceTestRunner.swift -o "$build/attribute-absence-swift" || return
    "$build/attribute-absence-swift"
}
nativeStatus=0
native > "$base/$phase-native.log" 2>&1 || nativeStatus=$?
printf 'Exit status: %s\n' "$nativeStatus" >> "$base/$phase-native.log"
swiftStatus=0
swift > "$base/$phase-swift.log" 2>&1 || swiftStatus=$?
printf 'Exit status: %s\n' "$swiftStatus" >> "$base/$phase-swift.log"
cat "$base/$phase-native.log" "$base/$phase-swift.log"
test "$nativeStatus" -eq 0 && test "$swiftStatus" -eq 0
