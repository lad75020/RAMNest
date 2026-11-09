#!/bin/bash
# Offline owned-fixture gate; no MCP SDK, user stores, app startup or mounts.
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/artifacts/mcp-domain-$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$output/build/module-cache"
output="$(cd "$output" && pwd)"
build="$output/build"
bash scripts/build-native.sh "$output/native" RelWithDebInfo ramnest-helper > "$output/native-build.log" 2>&1
python3 scripts/native-build-authority.py generate "$output/native" Release "$output/authority" "$build/NativeHelperBuildIdentity.swift"
common=(-Onone -g -swift-version 6 -target arm64-apple-macosx27.0 -module-cache-path "$build/module-cache")
swiftc "${common[@]}" -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$build/RAMNestCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift "$build/NativeHelperBuildIdentity.swift" -o "$build/libRAMNestCore.dylib"
swiftc "${common[@]}" -module-name RAMNestMCPKit -enable-testing -emit-library -emit-module -emit-module-path "$build/RAMNestMCPKit.swiftmodule" -I "$build" -L "$build" -lRAMNestCore -Xlinker -install_name -Xlinker @rpath/libRAMNestMCPKit.dylib -Xlinker -rpath -Xlinker @loader_path Sources/RAMNestMCPKit/*.swift -o "$build/libRAMNestMCPKit.dylib"
swiftc "${common[@]}" -parse-as-library -I "$build" -L "$build" -lRAMNestMCPKit -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path Tests/RAMNestMCPTests/Scenarios.swift Tests/RAMNestMCPTests/FixtureScenarios.swift scripts/MCPDomainTestRunner.swift -o "$build/mcp-domain-tests"
"$build/mcp-domain-tests" > "$output/domain-tests.log" 2>&1
printf 'MCP owned domain scenarios passed: %s\n' "$output/domain-tests.log"
