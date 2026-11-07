#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:?isolated native build directory required}"
configuration="${2:?Debug or RelWithDebInfo required}"
case "$configuration" in Debug|Release|RelWithDebInfo) ;; *) exit 64;; esac
# Xcode's script environment does not inherit the interactive Homebrew PATH.
# Resolve the existing tool without changing global settings or the sandbox.
cmake_command="$(command -v cmake || true)"
if [[ -z "$cmake_command" ]]; then
  for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
    if [[ -x "$candidate" ]]; then cmake_command="$candidate"; break; fi
  done
fi
[[ -n "$cmake_command" ]] || { printf 'CMake is required to build the native helper.\n' >&2; exit 69; }
"$cmake_command" -S "$source_root/Native" -B "$build" -DCMAKE_BUILD_TYPE="$configuration" -DRAMNEST_TEST_ROOT="$build/fixtures"
python3 "$source_root/scripts/native-provenance.py" "$source_root" "$build" "$configuration" --prepare
"$cmake_command" --build "$build" --target "${3:-all}" -j 4
python3 "$source_root/scripts/native-provenance.py" "$source_root" "$build" "$configuration"
