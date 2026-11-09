#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD"
if [[ "${1:-}" == --output && -n "${2:-}" && $# == 2 ]]; then output="$2"; elif [[ $# != 0 ]]; then exit 64; fi
mkdir -p "$output/artifacts/logs"
output="$(cd "$output" && pwd)"
products="$output/artifacts"
export CLANG_MODULE_CACHE_PATH="$output/.build/mcp-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
scripts/build.sh release --output "$output" > "$products/logs/build-release.log" 2>&1
# Native actions remain in the embedded CLI linked to its exact helper authority.
# SwiftPM's server reuses Core for data/settings and is sealed into THIS app.
swift build --disable-sandbox --scratch-path "$output/.build/swiftpm" -c release --product ramnest-mcp > "$products/logs/build-mcp-release.log" 2>&1
binary_dir="$(swift build --disable-sandbox --scratch-path "$output/.build/swiftpm" -c release --show-bin-path)"
app="$products/RAMNest.app"
cp "$binary_dir/ramnest-mcp" "$app/Contents/Helpers/ramnest-mcp"
codesign --force --sign - "$app/Contents/Helpers/ramnest-mcp"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
# Production native helper links only macOS system libraries. No FUSE is required or copied.
ditto -c -k --keepParent "$app" "$products/RAMNest-1.0.0-macos27-arm64.zip"
tar -czf "$products/RAMNest-1.0.0-source.tar.gz" Package.swift Package.resolved Native Plugins Sources Tests scripts resources docs README.md SECURITY.md FEATURE_MATRIX.md project.yml .gitignore
shasum -a 256 "$products/RAMNest-1.0.0-macos27-arm64.zip" "$products/RAMNest-1.0.0-source.tar.gz" > "$products/SHA256SUMS"
printf 'Packaged app and source. See artifacts/SHA256SUMS.\n'
