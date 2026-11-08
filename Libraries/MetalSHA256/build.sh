#!/bin/bash
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$src/../.." && pwd)"
out="${1:-$root/artifacts/metal-sha256}"
mkdir -p "$out/lib" "$out/include" "$out/build/module-cache" "$out/build/tmp" "$out/bin" "$out/logs"
out="$(cd "$out" && pwd)"
export TMPDIR="$out/build/tmp/"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
python3 - "$src/Sources/SHA256.metal" "$out/build/ShaderSource.h" <<'EMBED'
import sys,hashlib,pathlib
b=pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[2]).write_text('static const char MS256ShaderSource[] = R"MSLSOURCE('+b.decode()+')MSLSOURCE";\nstatic const char MS256ShaderHash[] = "'+hashlib.sha256(b).hexdigest()+'";\n')
EMBED
cp "$src/include/MetalSHA256.h" "$src/include/module.modulemap" "$out/include/"
xcrun clang++ -std=c++17 -O3 -fobjc-arc -fmodules -fmodules-cache-path="$out/build/module-cache" -isysroot "$sdk" -mmacosx-version-min=13.0 -I "$out/include" -I "$out/build" -dynamiclib "$src/Sources/MetalSHA256.mm" -framework Foundation -framework Metal -Wl,-install_name,@rpath/libCMetalSHA256.dylib -o "$out/lib/libCMetalSHA256.dylib"
swift_help="$(xcrun swiftc -help)"
if [[ "$swift_help" == *"-language-mode"* ]]; then
    language_flag=-language-mode
else
    language_flag=-swift-version
fi
xcrun swiftc -O -whole-module-optimization -enable-library-evolution "$language_flag" 5 -module-cache-path "$out/build/module-cache" -sdk "$sdk" -target "$(uname -m)-apple-macosx13.0" -I "$out/include" -L "$out/lib" -lCMetalSHA256 -module-name MetalSHA256 -emit-library -emit-module -emit-module-path "$out/lib/MetalSHA256.swiftmodule" -emit-module-interface-path "$out/lib/MetalSHA256.swiftinterface" "$src/Sources/MetalSHA256.swift" -Xlinker -install_name -Xlinker @rpath/libMetalSHA256.dylib -Xlinker -rpath -Xlinker @loader_path -o "$out/lib/libMetalSHA256.dylib"
xcrun swiftc --version > "$out/build/compiler.txt"
xcrun clang++ --version > "$out/build/clang.txt"
xcrun --sdk macosx --show-sdk-version > "$out/build/sdk-version.txt"
printf '%s\n' 'clang++ -std=c++17 -O3 -fobjc-arc; swiftc -O -whole-module-optimization -enable-library-evolution; deployment macOS 13; runtime MSL fastMathEnabled=NO' > "$out/build/flags.txt"
shasum -a 256 "$src"/Sources/* "$src"/include/* "$src/build.sh" > "$out/build/library-source-sha256.txt"
printf 'Built standalone library in %s\n' "$out"
