#!/bin/bash
# Tight disk-only harness. Does not build/launch RAMNest or execute a helper.
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/artifacts/scratch/metadata-recovery-build"
mkdir -p "$output/module-cache" "$output/identity-input"
# The authority generator explicitly supports opaque fixture inputs. These
# bytes cannot execute as a helper; production authorization is not exercised.
python3 - "$output" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'identity-input'
b = b'Agent-owned non-executable metadata regression fixture\n'
(p / 'ramnest-helper').write_bytes(b)
(p / 'ramnest-helper').chmod(0o600)
(p / 'provenance.json').write_text(json.dumps({'engine':'native-tmpfs-v1', 'configuration':'Debug', 'helperSHA256':hashlib.sha256(b).hexdigest()}))
PY
python3 scripts/native-build-authority.py generate "$output/identity-input" Debug "$output/authority" "$output/NativeHelperBuildIdentity.swift"
common=(-Onone -swift-version 6 -target arm64-apple-macosx27.0 -module-cache-path "$output/module-cache")
swiftc "${common[@]}" -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$output/RAMNestCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift "$output/NativeHelperBuildIdentity.swift" -o "$output/libRAMNestCore.dylib"
swiftc "${common[@]}" -parse-as-library -D RAMNEST_METADATA_STANDALONE -I "$output" -L "$output" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path Tests/RAMNestCoreTests/LinkedTransactionTests.swift Tests/RAMNestCoreTests/MetadataRecoveryTests.swift -o "$output/metadata-tests"
printf '%s\n' 'Standalone disk-only metadata tests: non-executable fixture build authority; no production helper validation.'
"$output/metadata-tests"
# Optional parent gate: Swift Testing's plugin server requires a host that can
# start Apple's nested macro sandbox. Never disable that sandbox to run this.
if [[ "${1:-}" == "--typecheck-swift-testing" ]]; then
# CoreTests.swift supplies this shared namespace in the Xcode target.
cat > "$output/MetadataTestingNamespace.swift" <<'SWIFT'
import Testing
@Suite(.serialized) struct RAMNestTestSuite {}
SWIFT
platform="$(xcrun --show-sdk-platform-path)"
compiler="$(xcrun --find swiftc)"
plugins="$(dirname "$compiler")/../lib/swift/host/plugins/testing"
swiftc "${common[@]}" -typecheck -F "$platform/Developer/Library/Frameworks" -external-plugin-path "$plugins#$(dirname "$compiler")/swift-plugin-server" -I "$output" "$output/MetadataTestingNamespace.swift" Tests/RAMNestCoreTests/LinkedTransactionTests.swift Tests/RAMNestCoreTests/MetadataRecoveryTests.swift
printf '%s\n' 'PASS normal Swift Testing declarations typechecked (test namespace fixture only).'
fi
