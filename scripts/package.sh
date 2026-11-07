#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts/logs
scripts/build.sh release > artifacts/logs/build-release.log 2>&1
codesign --verify --deep --strict artifacts/RAMNest.app
plutil -lint artifacts/RAMNest.app/Contents/Info.plist
# FUSE-T is an external dependency. No installed third-party binaries are copied.
ditto -c -k --keepParent artifacts/RAMNest.app artifacts/RAMNest-1.0.0-macos27-arm64.zip
tar -czf artifacts/RAMNest-1.0.0-source.tar.gz --exclude='docs/reference' Package.swift Native Sources Tests scripts resources docs README.md SECURITY.md FEATURE_MATRIX.md project.yml .gitignore
shasum -a 256 artifacts/RAMNest-1.0.0-macos27-arm64.zip artifacts/RAMNest-1.0.0-source.tar.gz > artifacts/SHA256SUMS
printf 'Packaged app and source. See artifacts/SHA256SUMS.\n'
