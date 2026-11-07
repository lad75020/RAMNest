#!/bin/bash
# Focused no-mount checks. No package build, actool, global settings or user data.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD/artifacts/backend-selector"
export TMPDIR="$root/tmp"
export CLANG_MODULE_CACHE_PATH="$root/build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$root/logs"
swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$root/build/RAMNestCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift -o "$root/build/libRAMNestCore.dylib"
swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -parse-as-library -I "$root/build" -L "$root/build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path scripts/BackendSelectorTestRunner.swift -o "$root/build/backend-selector-tests"
"$root/build/backend-selector-tests"
python3 scripts/backend-selector-live-command-tests.py
swiftc -g -Onone -swift-version 6 -target arm64-apple-macosx27.0 -parse-as-library -I "$root/build" -L "$root/build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path Sources/RAMNestApp/AppModel.swift scripts/BackendSettingsModelTestRunner.swift -o "$root/build/backend-settings-model-tests"
"$root/build/backend-settings-model-tests"
swiftc -typecheck -swift-version 6 -target arm64-apple-macosx27.0 -parse-as-library -I "$root/build" Sources/RAMNestApp/*.swift
cmake -S Native -B "$root/native-build" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$root/native-build" --target ramnest-control-tests ramnest-callback-tests -j 4
RAMNEST_TEST_ROOT="$root/native-fixtures" "$root/native-build/ramnest-control-tests"
RAMNEST_TEST_ROOT="$root/native-fixtures" "$root/native-build/ramnest-callback-tests"
python3 scripts/check-callbacks.py
python3 scripts/check-gui-lifecycle.py
