#!/bin/bash
# All product builds and fixtures go to a fresh isolated run root.
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/artifacts/test-runs/$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$output/logs"
output="$(cd "$output" && pwd)"
bash scripts/build.sh debug --output "$output/package-debug" > "$output/logs/build-debug.log" 2>&1
native="$output/package-debug/.build/debug/native-Debug"
ctest --test-dir "$native" --output-on-failure -V > "$output/logs/native-tests.log" 2>&1
python3 scripts/review-isolated-tests.py "$output"
export CLANG_MODULE_CACHE_PATH="$output/module-cache"
build="$output/test-project/.build/direct"
swiftc -g -Onone -swift-version 6 -parse-as-library -I "$build" -L "$build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path scripts/ControlTestClient.swift -o "$build/control-client"
python3 scripts/control-tests.py --client "$build/control-client" --native "$native/ramnest-control-tests" --root "$output/protocol" --socketpair > "$output/logs/control-protocol.log" 2>&1
printf 'Local no-mount gates completed. Evidence (including explicit skips): %s\n' "$output"
