#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
exe="$root/artifacts/metal-sha256/bin/sha256-api-benchmark"
out="$root/artifacts/metal-sha256/tests-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$out"
"$exe" --self-test > "$out/self-test.log" 2>&1
"$exe" --help > "$out/help.log"
reject() {
    if "$exe" "$@" > "$out/reject-$case_number.log" 2>&1; then
        printf 'FAIL: accepted invalid arguments: %s\n' "$*"; exit 1
    fi
    case_number=$((case_number + 1))
}
case_number=1
reject --large-bytes 0
reject --large-bytes -1
reject --large-bytes 4294967296
reject --large-bytes 9999999999999999999999999
reject --large-bytes 1,,2
reject --large-bytes 1,1
reject --chunk-bytes 0
reject --chunk-bytes 4294967296
reject --repetitions 1
reject --repetitions 101
reject --small-iterations -1
reject --small-iterations 100000001
reject --unsupported
reject --large-bytes
"$exe" --smoke --output-dir "$out/smoke" > "$out/smoke.log" 2>&1
reject --smoke --output-dir "$out/smoke"
printf 'PASS: self-test, help, %s CLI/output rejection checks, odd-size smoke\nArtifacts: %s\n' "$((case_number - 1))" "$out"
