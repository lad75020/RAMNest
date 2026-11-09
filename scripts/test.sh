#!/bin/bash
# Parent-runnable native no-mount gate. Full Swift/GUI acceptance belongs to Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/artifacts/native-tests-$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$output"
python3 scripts/native-production-static-tests.py
cmake -S Native -B "$output/native" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$output/native" --target ramnest-native-protocol-tests -j 4
ctest --test-dir "$output/native" --output-on-failure
printf 'Native no-mount gate complete. Run the worktree Xcode scheme tests and exact-package probe for acceptance.\n'
