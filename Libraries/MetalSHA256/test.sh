#!/bin/bash
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$src/../.." && pwd)"
out="${1:-$root/artifacts/metal-sha256}"
out="$(cd "$out" && pwd)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
export TMPDIR="$out/build/tmp/"
xcrun swiftc -O -whole-module-optimization -module-cache-path "$out/build/module-cache" -sdk "$sdk" -I "$out/include" -I "$out/lib" -L "$out/lib" -lMetalSHA256 -lCMetalSHA256 "$src/Tests/GPUTests.swift" -Xlinker -rpath -Xlinker @executable_path/../lib -o "$out/bin/gpu-tests"
xcrun clang -O3 -isysroot "$sdk" -I "$out/include" -L "$out/lib" "$src/examples/smoke.c" -lCMetalSHA256 -Wl,-rpath,@executable_path/../lib -o "$out/bin/c-smoke"
xcrun clang++ -x c++ -std=c++17 -O3 -isysroot "$sdk" -I "$out/include" -L "$out/lib" "$src/examples/smoke.c" -lCMetalSHA256 -Wl,-rpath,@executable_path/../lib -o "$out/bin/cpp-smoke"
# Run all public language clients, retaining every exit status (no GPU skip).
status=0
for client in gpu-tests c-smoke cpp-smoke; do
    if "$out/bin/$client" > "$out/logs/$client.log" 2>&1; then cat "$out/logs/$client.log"; else cat "$out/logs/$client.log"; status=1; fi
done
exit "$status"
