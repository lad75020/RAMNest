#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug) optimization=-Onone; native_configuration=Debug;; release) optimization=-O; native_configuration=RelWithDebInfo;; *) exit 64;; esac
# --output is a complete isolated build/package root, never an installed app.
output="$PWD"
if [[ "${2:-}" == --output && -n "${3:-}" ]]; then output="$3"; elif [[ $# -gt 1 ]]; then exit 64; fi
mkdir -p "$output"
output="$(cd "$output" && pwd)"
build="$output/.build/$configuration"
products="$output/artifacts"
app="$products/RAMNest.app"
[[ ! -e "$app" ]] || { printf 'Refusing to overwrite an existing app product: %s\n' "$app" >&2; exit 73; }
export CLANG_MODULE_CACHE_PATH="$build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export TMPDIR="$output/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR" "$build/direct" "$products/logs"
native="$build/native-$native_configuration"
bash scripts/build-native.sh "$native" "$native_configuration" ramnest-helper
authority="$build/native-authority"
generated="$build/direct/NativeHelperBuildIdentity.swift"
authority_configuration=Release
if [ "$configuration" = debug ]; then authority_configuration=Debug; fi
python3 scripts/native-build-authority.py generate "$native" "$authority_configuration" "$authority" "$generated"
swiftc "$optimization" -g -swift-version 6 -target arm64-apple-macosx27.0 -module-name RAMNestCore -enable-testing -emit-library -emit-module -emit-module-path "$build/direct"/RAMNestCore.swiftmodule -Xlinker -install_name -Xlinker @rpath/libRAMNestCore.dylib Sources/RAMNestCore/*.swift "$generated" -o "$build/direct"/libRAMNestCore.dylib
swiftc "$optimization" -g -swift-version 6 -target arm64-apple-macosx27.0 -parse-as-library -I "$build/direct" -L "$build/direct" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path -Xlinker -rpath -Xlinker @executable_path/../Frameworks Sources/RAMNestCLI/*.swift -o "$build/direct"/ramnest
swiftc "$optimization" -g -swift-version 6 -target arm64-apple-macosx27.0 -parse-as-library -I "$build/direct" -L "$build/direct" -lRAMNestCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks Sources/RAMNestApp/*.swift -o "$build/direct"/RAMNest
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$build/direct"/RAMNest "$app/Contents/MacOS/RAMNest"
cp "$build/direct"/ramnest "$app/Contents/Helpers/ramnest"
python3 scripts/native-build-authority.py embed "$authority" "$generated" "$app"
cp "$build/direct"/libRAMNestCore.dylib "$app/Contents/Frameworks/"
cp resources/Info.plist "$app/Contents/Info.plist"
cp resources/mcp-bridge.json "$app/Contents/Resources/mcp-bridge.json"
xcrun actool resources/Assets.xcassets \
  --compile "$app/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 27.0 \
  --target-device mac \
  --app-icon AppIcon \
  --output-partial-info-plist "$build/direct"/AppIcon-Info.plist
/usr/libexec/PlistBuddy -c "Merge '$build/direct/AppIcon-Info.plist'" "$app/Contents/Info.plist"
for binary in "$app/Contents/Frameworks/libRAMNestCore.dylib" "$app/Contents/Helpers/ramnest" "$app/Contents/MacOS/RAMNest"; do codesign --force --sign - "$binary"; done
python3 scripts/native-build-authority.py verify "$authority" "$generated"
cmp "$authority/ramnest-helper" "$app/Contents/Helpers/ramnest-helper"
codesign --force --sign - "$app"
cmp "$authority/ramnest-helper" "$app/Contents/Helpers/ramnest-helper"
cp "$build/direct"/ramnest "$products"/ramnest
cp "$build/direct"/libRAMNestCore.dylib "$products"/libRAMNestCore.dylib
cp "$authority/ramnest-helper" "$products"/ramnest-helper
codesign --force --sign - "$products"/ramnest
codesign --force --sign - "$products"/libRAMNestCore.dylib
printf 'Built %s\n' "$app"
