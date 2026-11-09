#!/bin/bash
set -euo pipefail
# SwiftPM plugins do not inherit an interactive toolchain search path.
# Keep compiler/build-tool discovery command-scoped and deterministic.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
cd "$(dirname "$0")/.."
work="${1:?plugin work directory required}"
mkdir -p "$work/generated"
# SwiftPM's Core is used for data/settings. Native controls use the packaged CLI,
# whose own independently compiled authority is checked inside that process.
bash scripts/build-native.sh "$work/native" RelWithDebInfo ramnest-helper >&2
python3 scripts/native-build-authority.py generate "$work/native" Release "$work/authority" "$work/generated/NativeHelperBuildIdentity.swift" >&2
