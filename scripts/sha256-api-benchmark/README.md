# Standalone SHA-256 API benchmark

Build with Apple's installed macOS SDK and Xcode toolchain. No package manager,
network access, application target, mount or RAMNest code is involved.

```sh
scripts/sha256-api-benchmark/build.sh
scripts/sha256-api-benchmark/test.sh
# Full run is intentionally left for the parent after source freeze/review:
artifacts/metal-sha256/bin/sha256-api-benchmark --output-dir artifacts/metal-sha256/new-cpu-run
```

Use `--help` for options. `--self-test` exits after correctness tests.
`--smoke` runs all modes with one odd 16,777,219-byte large input, two repeats and
2,000 small calls per repeat. Explicit options override smoke defaults. The normal
configuration uses 1/2/4 **decimal** GB, 1,000,000-byte incremental chunks, five
repeats and 200,000 independent small hashes per repeat. Small buffers range from
64 to 4,096 bytes; small 1 KB is 1,024 bytes. Repetitions must be 2...100 and
large allocations 1...4,000,000,000 bytes. Invalid arguments fail before allocating.

Each large size uses one 64-byte-aligned allocation. SplitMix64 deterministically
fills every byte/page with high-entropy data outside timers. A single Foundation
`Data(bytesNoCopy:deallocator:.none)` wrapper is created outside timers, and its
address/count must match the allocation or the run fails. Both one-shot APIs use
that same Data value; CommonCrypto accesses its bytes via `withUnsafeBytes`.
Wrappers are dropped before freeing memory, and each size is released before the
next allocation. No generated input file or input file reads are used.

Incremental timing includes init, all updates and finalization. Both APIs traverse
the same original pointer with the same chunk boundaries, including a short final
chunk. CryptoKit uses its public `update(bufferPointer:)`, verified by compilation.
Every CommonCrypto length is checked before conversion to `CC_LONG`, including a
self-test rejecting 4 GiB without allocating it. 4 decimal GB is safe for CC_LONG.

For each small size, 4,096 separate initialized allocations and their Data wrappers
are prepared once. Each call starts a fresh SHA-256. Both APIs traverse the same
pool in the same order for exactly the same call count. CommonCrypto writes into
32 bytes of fixed stack storage; there is no per-call array allocation. The cost
of the API wrapper, full digest extraction and consumption is included for both.
Inputs, pool creation, reference digest checks, clocks per individual hash, output
formatting and I/O are excluded from the batch timer.

The complete 32-byte digest from every timed call contributes to four wrapping
64-bit rolling accumulators. Small-loop signatures must match the reference
sequence computed outside the timer. Every pool entry is checked byte-for-byte
between APIs outside timing. Single large-call signatures map all four digest
words injectively, so checking them verifies every digest byte. Known vectors
cover empty input, 64 zero bytes, `abc`, a standard multiblock message and one
million `a` bytes. Both incremental APIs are tested with 1-byte chunks and tails,
including a 256-byte source with values 0...255. Signature checks detect accidental
errors; the rolling signature is not a cryptographic proof against collisions.

Each cell performs a complete warmup batch for each API. Repeats alternate CC/CK
then CK/CC on one calling thread within one binary. Swift is compiled with `-O
-whole-module-optimization`; the recorded compiler, SDK, target info, flags and
source hashes live under `artifacts/metal-sha256/build`. The C probe is
compiled with `-O3 -isysroot <sdk>`. No CPU affinity, priority, system settings or
memory limits are changed. Internal system-library scheduling is not controlled.

`report.json` contains metadata, actual configuration, every raw measurement and
summaries derived directly from raw measurements. `measurements.csv` has numeric
values and quoted text fields. Both are checkpointed atomically after every timed
measurement, outside the timer. A nonempty output directory is refused unless
`--force` is supplied; force only replaces these two named reports. A partial
report has `completed: false`. CLI output provides median/min/max GB/s, ns/hash and
CC/CK throughput ratio; CSV/JSON also provide calls, total bytes and hashes/s.
Ratio >1 means CommonCrypto is faster. GB/s = bytes / elapsed nanoseconds.

Residency is best effort: prefaulting/warmup do not guarantee physical residency
or prevent OS swap. The public `proc_pid_rusage(RUSAGE_INFO_V4)` probe captures
own-process pageins, RSS and physical footprint, with `getrusage` fault counts and
ProcessInfo thermal states before/after each timed batch. Serious/critical thermal
state or increased pageins marks a measurement contaminated. Unsupported sampling
is marked unknown. Samples under 100 ms are flagged for timing uncertainty; fixed
call counts allow callers to increase small iterations fairly. The summary counts
all flagged samples, including short samples. Raw samples remain available, and
summaries include flagged samples rather than silently filtering them. The probe,
output I/O, and thermal sampling are outside the hash timer. Pageins before the
first boundary or transient thermal events between samples cannot be excluded.

This compares public API end-to-end costs. Both Apple libraries may share internal
corecrypto paths; measured speed does not prove hardware acceleration. The
`hw.optional.arm.FEAT_SHA256` capability is recorded if available, otherwise absent
(unknown), and never interpreted as proof that either call used that capability.

Reusable benchmark source is in this directory; the new standalone library is
under `Libraries/MetalSHA256/`. All new build/cache/temp files, measurements and
implementation notes are under `artifacts/metal-sha256/`. The previously completed
CPU reports under `artifacts/sha256-api-benchmark/full-run/` remain unchanged.


## Separate Metal independent-message batch mode

```sh
scripts/sha256-api-benchmark/build.sh
Libraries/MetalSHA256/test.sh
# Tiny smoke only (four cells, two repeats):
artifacts/metal-sha256/bin/sha256-api-benchmark --metal-batch --smoke \
  --output-dir artifacts/metal-sha256/new-mini-run
# After source freeze/review and successful host GPU correctness tests:
artifacts/metal-sha256/bin/sha256-api-benchmark --metal-batch \
  --output-dir artifacts/metal-sha256/new-full-batch-run
```

`--metal-batch` selects a separate workload and report schema. It does not run the
legacy large-file/incremental/small-call benchmarks. Without it, legacy CPU modes,
argument limits and `report.json` / `measurements.csv` semantics remain available;
no Metal context is created by CPU-only modes. A library/module build failure is
explicit; no fake API is substituted. All benchmark builds now include the two
local dylibs with relative RPATHs and public Swift/Clang modules. The library is
experimental and not audited or certified.

This mode hashes **independent complete messages**: 64/128/256/512/1024/2048/4096 B,
64 KiB and 1 MiB. Counts are 1,256,4096 for all but 1 MiB (1,64,256, keeping the
batch at or below 256 MiB). The 64 KiB case is page-size insight only; there is no
RAMNest integration. A 256 MiB batch of independent 1 MiB messages produces 256
digests, not the single standard SHA-256 of 256 MiB. Never compare those as the
same output. Empty batches/messages are correctness tests, not throughput rows.

Three APIs use the exact same messages, order, iterations, complete digest output
shape and timed full-digest sink:

1. `CryptoKitCPU-batch`: loop over SHA256.hash, serialize every 32-byte result.
2. `MetalSHA256-end-to-end`: Swift packs fresh bytes/descriptors; native code
   allocates/copies shared Metal buffers, dispatches, waits and copies all output.
3. `MetalSHA256-prepared`: owns a pre-copied snapshot; setup outside clocks is
   reported as `preparedSetupMS`. Every call still performs SHA on the GPU, waits,
   allocates the returned Data and copies all digests. No cached digest return.

Context bootstrap/runtime shader compilation is outside clocks and reported.
Input generation/prefault, dual independent CPU references, API warmups, per-input
full digest validation before timing, full final-output and rolling-sink checks
per repeat, process probes and report I/O are outside clocks. Every digest from
every timed call enters the same full 256-bit sink inside clocks. Signatures are
accidental-error detectors, not cryptographic proofs. API metadata handling is
included. Unified memory does not eliminate packing/copy/allocation costs.

Default is **six repetitions**, rotating three API orders so each API occupies
each position twice. Explicit `--repetitions` overrides it (2...100); `--smoke`
uses two. Each cell uses identical iterations/API/repeat: base 32 for count 1,
4 for counts <=256, 2 otherwise, additionally capped to at most 128 MiB processed
per sample (minimum 1 batch, so a 256 MiB batch still runs once). Smoke uses two
iterations. Legacy `--large-bytes`, `--small-iterations` and `--chunk-bytes` do not set GPU command
counts. Short samples (<100 ms) are flagged; few-message CPU timings can be
clock-sensitive. There is no million-dispatch GPU loop or automatic long calibration.

`batch-report.json` and `batch-measurements.csv` are checkpointed outside timers
and separate from legacy CPU reports. `--force` only replaces the two reports
belonging to the selected mode. The report gives raw wall nanoseconds, decimal
GB/s, amortized ns/message, batch latency in microseconds, hashes/s, exact bytes,
message counts and iterations. `gpuOverCryptoKitThroughputSpeedup` is GPU wall
GB/s divided by CPU wall GB/s: **>1 means GPU faster**. GPU command seconds and
first/last observed timestamps are separate diagnostics, never primary CPU/GPU
throughput comparisons. Unknown GPU time is omitted/null, never fabricated zero.
Every nonempty GPU call requires one completed Metal command or aborts without
recording a valid row. Device/driver/compiler failures are explicit errors.

The report records actual device/unified memory/maxBufferLength, API limits,
pipeline width/group size, shader source hash and optimized library/benchmark
build flags. Pageins, RSS, footprint, fault and thermal probes/caveats also apply
to this mode. There is no energy measurement; CPU/GPU share memory bandwidth and
power/thermal budget. It may lose to CryptoKit, especially for a single message.

The coding sandbox exposed no Metal device. On the ordinary Apple M4 Max host,
GPU correctness and public-language clients passed. The optimized benchmark smoke
also passes after explicitly retaining no-copy input owners through every CPU/GPU
use. Run `bash scripts/sha256-api-benchmark/test-metal.sh` for those library tests,
the legacy CPU suite, and the optimized lifetime-regression matrix. GPU performance
must come from the separate batch reports, not the earlier availability probe.
