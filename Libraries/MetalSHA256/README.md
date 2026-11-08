# MetalSHA256 (experimental macOS library)

A standalone standard SHA-256 **batch** API for independent messages. One Metal
thread runs all compression blocks of one complete message and produces its
32-byte digest. This is not a tree hash, a file chunk combiner, or a replacement
for RAMNest's integrity engine. This experimental cryptographic implementation
has not been audited or certified.

Requires macOS 13+, an available Metal device, and Apple's installed Swift/Clang
SDK. No package manager, network, app target, global SDK change, or downloaded
Metal toolchain is required. The shader is embedded during the build; the public
Metal runtime compiles it once per context. A context owns its device, command
queue and pipeline. There is no CPU fallback.

## Build and consume

From the repository root:

```sh
Libraries/MetalSHA256/build.sh
Libraries/MetalSHA256/test.sh
# Optional explicit expected-device gate on the ordinary host:
METAL_SHA256_EXPECT_DEVICE='Apple M4 Max' Libraries/MetalSHA256/test.sh
```

All outputs go to `artifacts/metal-sha256/` by default. Both scripts accept an
alternative **owned artifact directory** as their first argument. Output includes:

- `lib/libCMetalSHA256.dylib`: the C ABI, ObjC++ Metal owner and embedded shader.
- `lib/libMetalSHA256.dylib`, `MetalSHA256.swiftmodule`, `.swiftinterface`: Swift API.
- `include/MetalSHA256.h`, `module.modulemap`: public C header and Clang module.
- `bin/gpu-tests`, `c-smoke`, `cpp-smoke`: actual public API clients (after test build).
- `build/`: compiler/SDK/flags/source hashes, embedded shader, modules and temp files.
- `logs/`: all focused test outputs; tests fail when Metal is unavailable.

The `lib/`, `include/`, and `bin/` relative layout is portable on a compatible
macOS/architecture; local build paths are not runtime dependencies. Install names
use `@rpath`; executables use `@executable_path/../lib` and the Swift library uses
`@loader_path`. Keep both dylibs. Compile for a different architecture on that
architecture. The `.swiftinterface` supports compatible newer Swift compilers;
clients also need the Clang module include directory. This is not a universal
binary or an application bundle, and it does not install a system-wide library.

Swift client:

```swift
import Foundation
import MetalSHA256
let engine = try MetalSHA256Engine() // throws on device/pipeline failure
let messages = [Data(), Data("abc".utf8)]
let result = try engine.hashBatch(messages)
// result.digests: 64 bytes, in input order; each digest occupies exactly 32 bytes.
let prepared = try engine.prepare(messages) // owns an immutable Metal snapshot
let reused = try prepared.hash()            // still dispatches real SHA compression
print(engine.info.deviceName, reused.metrics.completedCommands)
```

```sh
xcrun swiftc -O -I artifacts/metal-sha256/include -I artifacts/metal-sha256/lib \
  -L artifacts/metal-sha256/lib -lMetalSHA256 -lCMetalSHA256 Client.swift \
  -Xlinker -rpath -Xlinker @executable_path/../lib \
  -o artifacts/metal-sha256/bin/client
```

C / ObjC / C++ use `include/MetalSHA256.h`, which contains no ObjC types and has
`extern "C"` linkage. See `examples/smoke.c` (compiled as both C and C++ by tests).
Create a context, pass packed bytes with `MS256Message { uint64_t offset, length; }`
and `sizeof(MS256Message)`, provide a caller-owned `N*32`-byte destination, check
the returned status, then free handles. `ms256_last_error` safely copies the
calling thread's most recent error, NUL-terminating within caller capacity; its
required-size result includes the NUL. The internally stored error is bounded to
4095 bytes. Swift exposes `hashPacked` and `preparePacked` for explicit descriptors.

```sh
xcrun clang -O3 -I artifacts/metal-sha256/include \
  -L artifacts/metal-sha256/lib Libraries/MetalSHA256/examples/smoke.c \
  -lCMetalSHA256 -Wl,-rpath,@executable_path/../lib \
  -o artifacts/metal-sha256/bin/c-client
```

## Contract, limits and ownership

- Each result is ordinary FIPS SHA-256 over exactly that descriptor's bytes. Standard
  big-endian digest/padding, including empty messages and two-block padding tails.
- Descriptor layout is 16 bytes, 8-byte alignment, offset then length. Host layout
  is statically asserted against MSL's two `ulong` fields. Views may overlap or
  begin at any byte; output preserves descriptor order.
- Default packed storage **and sum of message lengths**: 256 MiB; default maximum
  messages: 65536. Explicit context budgets may be at most 1 GiB / 65536 messages,
  subject to device `maxBufferLength`. Every message is at most 16 MiB.
- All dimensions, offset/length range/overflow, descriptor size, count/output
  arithmetic and destination capacity are checked before a GPU command. There is
  no silent UInt32 truncation. Rounded threadgroups include a kernel bounds check.
- Oversize ordinary file SHA is unsupported. Split into independent messages only
  when that matches your workload; hashing independent chunks does not produce the
  standard digest of their concatenation. Limits bound work and memory, not a
  universal deadline on every GPU. Explicit 1 GiB work caps may run much longer.
- Empty batch returns zero digests and zero completed commands, without dispatch.
  A nonempty batch of empty messages dispatches using a one-byte dummy input buffer.
- `prepare` copies bytes/descriptors into owned shared Metal buffers. Caller input
  may be changed/freed after return. Original hash/prepare input must stay valid
  and immutable for the duration of the synchronous call. Shared memory is not
  zero-copy packing. Output is copied after successful command completion.
- Same-context calls serialize with a native mutex. Different contexts are
  independent. Swift prepared objects retain the engine. C callers must keep the
  context alive until all prepared handles are freed. Handles must be valid live
  library handles; arbitrary invalid pointers are outside the contract. Freeing
  during an active operation, double free, and use after free are caller errors.
- ARC/RAII and per-call autorelease pools release transient buffers/commands after
  completion. There is no persistent verified-data cache and no buffer pool.
  Prepared handles intentionally retain input, descriptor and output buffers.
  The library cannot prevent a caller retaining many prepared handles at once.
- Device, runtime compilation, allocation, encoder, command completion and Metal
  errors are explicit statuses/Swift errors. No CPU digest code is in the backend.
  Result bytes are valid only on success. Exceptions do not cross status APIs.

## Metrics and validation status

`engine.info` reports the actual device, unified memory, buffer/work limits,
pipeline execution width/threadgroup size, embedded shader SHA-256 and context
bootstrap seconds. Bootstrap includes device/queue/runtime-library/pipeline setup;
it is separate from steady-state batch wall time. Metrics report the command
completion count, workload bytes and positive GPU start/end/duration **after**
`waitUntilCompleted`. Unavailable timestamps are `nil` in Swift / -1 in C, not zero.
GPU command duration is diagnostic; it is not end-to-end API latency.

`Tests/GPUTests.swift` requires full-byte agreement against **both CryptoKit and
CommonCrypto**, NIST KATs, million-a, padding boundaries, randomized/pattern/mixed
inputs, 1...4096 tails, maximum count with empty messages, unaligned/overlapping
views, snapshot mutation, context reuse/lifetime and concurrency. Native negative
checks cover limits/overflow/ranges/descriptor sizes/output capacity/wrong owners
and require no dispatch on errors. Optional expected device is an exact name gate.

The initial coding sandbox exposed no Metal device, so its GPU tests failed
explicitly rather than falling back. Subsequent ordinary-host tests on Apple M4
Max passed 71,313 full-digest comparisons, padding/randomized/negative tests and
Swift, C, C++ and Objective-C clients, with completed commands and positive GPU
timestamps. These are tests, not cryptographic certification. Run the commands
above on your target host and retain the actual command/timestamp evidence.

The separate benchmark extension is documented in
[`../../scripts/sha256-api-benchmark/README.md`](../../scripts/sha256-api-benchmark/README.md).
