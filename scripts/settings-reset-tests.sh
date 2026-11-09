#!/bin/bash
# Isolated, nonprivileged tests. Compiles a helper solely for byte-authority
# generation; these tests never mount, authorize, install or relaunch an app.
set -euo pipefail
cd "$(dirname "$0")/.."
output="${RAMNEST_RESET_TEST_OUTPUT:-$PWD/artifacts/settings-reset}"
build="$output/build"
mkdir -p "$build/module-cache"
developer_path="$(xcode-select -p)"
frameworks="$developer_path/Platforms/MacOSX.platform/Developer/Library/Frameworks"
plugins="$developer_path/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
bash scripts/build-native.sh "$output/native" Debug ramnest-helper > "$output/native-build.log" 2>&1
python3 scripts/native-build-authority.py generate "$output/native" Debug "$output/authority" "$build/NativeHelperBuildIdentity.swift"
common=(-Onone -swift-version 6 -target arm64-apple-macosx27.0 -module-cache-path "$build/module-cache")
swiftc "${common[@]}" -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$build/RAMNestCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift "$build/NativeHelperBuildIdentity.swift" -o "$build/libRAMNestCore.dylib"
linked=(-parse-as-library -I "$build" -L "$build" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path)
swiftc "${common[@]}" "${linked[@]}" Sources/RAMNestCLI/*.swift -o "$build/ramnest"
swiftc "${common[@]}" "${linked[@]}" -D RAMNEST_STANDALONE Tests/RAMNestCoreTests/CoreTests.swift scripts/SettingsResetTestRunner.swift -o "$build/reset-tests"
"$build/reset-tests" "$build/ramnest" > "$output/reset-tests.log" 2>&1
swiftc "${common[@]}" "${linked[@]}" Sources/RAMNestApp/AppModel.swift Sources/RAMNestApp/AppCommands.swift scripts/AppModelTestRunner.swift -o "$build/app-model-tests"
"$build/app-model-tests" > "$output/app-model-tests.log" 2>&1
if [[ "${1:-}" == --related ]]; then
  # Reuse the generated helper identity and isolated core above. The older
  # standalone scripts do not yet supply that required generated source.
  swiftc "${common[@]}" "${linked[@]}" -D RAMNEST_LATEST_SNAPSHOT_STANDALONE -D RAMNEST_HOLDING_CLEANUP_STANDALONE Tests/RAMNestCoreTests/LatestSnapshotTests.swift Tests/RAMNestCoreTests/HoldingCleanupTests.swift scripts/HoldingCleanupTestRunner.swift -o "$build/holding-cleanup-tests"
  (ulimit -n 96; ulimit -s 1024; "$build/holding-cleanup-tests") > "$output/holding-cleanup-tests.log" 2>&1
  swiftc "${common[@]}" "${linked[@]}" -D RAMNEST_SNAPSHOT_DESCRIPTOR_STANDALONE Tests/RAMNestCoreTests/SnapshotDescriptorTests.swift -o "$build/snapshot-descriptor-tests"
  (ulimit -n 96; "$build/snapshot-descriptor-tests") > "$output/snapshot-descriptor-tests.log" 2>&1
fi
if [[ "${1:-}" == --full ]]; then
  cat > "$build/AllTestsRunner.swift" <<'SWIFT'
import Darwin
import Testing
@main struct AllTestsRunner {
    static func main() async {
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
SWIFT
  swiftc "${common[@]}" "${linked[@]}" -F "$frameworks" -load-plugin-library "$plugins" -Xlinker -rpath -Xlinker "$frameworks" "$PWD"/Tests/RAMNestCoreTests/*.swift "$build/AllTestsRunner.swift" -o "$build/all-tests"
  "$build/all-tests" > "$output/all-tests.log" 2>&1
fi
printf 'RESET tests passed. Logs: %s\n' "$output"
