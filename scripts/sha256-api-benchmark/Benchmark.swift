import Foundation
import CryptoKit
import CommonCrypto
import Darwin
import Dispatch

struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message) } }
let seed: UInt64 = 0x72616d6e65737431
struct Options: Codable {
    var largeBytes = [1_000_000_000, 2_000_000_000, 4_000_000_000]
    var chunkBytes = 1_000_000, repetitions = 5, smallIterations = 200_000
    var smallSizes = [64,128,256,512,1024,2048,4096]
    var outputDir = "", force = false, selfTest = false, smoke = false
    var metalBatch = false
    // Keep the legacy CPU JSON option schema unchanged. Batch reports have their own schema.
    enum CodingKeys: String, CodingKey {
        case largeBytes, chunkBytes, repetitions, smallIterations, smallSizes, outputDir, force, selfTest, smoke
    }
}
let help = """
Standalone CommonCrypto vs CryptoKit SHA-256 (macOS, one calling thread).
Usage: sha256-api-benchmark [options]
  --large-bytes N[,N...]   Each 1...4000000000 bytes; default 1,2,4 decimal GB
  --chunk-bytes N         Incremental chunk bytes; default 1000000 (decimal MB)
  --small-iterations N    Independent hashes per repeat; default 200000
  --repetitions N         2...100, default 5; alternate API order per repeat
  --output-dir PATH       New result directory (default timestamp under artifacts)
  --force                 Replace benchmark report.json/measurements.csv only
  --self-test             Known vectors, tails, zero-copy and overflow checks; exit
  --smoke                 Odd 16777219-byte input, 2000 small calls, 2 repeats
  --metal-batch           Separate independent-message GPU batch matrix (6 repeats)
  --metal-batch --smoke   Tiny GPU matrix; separate batch-report.json/csv
                          CPU size/chunk/small-call flags remain CPU-only
  --help                  Show this help
Small sizes: 64,128,256,512,1024,2048,4096 B; 4096 distinct buffers per size.
GB/s is decimal (1 GB = 1000000000 B). Small 1 KB means 1024 B.
Input is generated/prefaulted in RAM. OS paging cannot be ruled out or disabled.
Example: scripts/sha256-api-benchmark/build.sh && artifacts/metal-sha256/bin/sha256-api-benchmark --output-dir artifacts/metal-sha256/new-cpu-run
"""
func parse() throws -> Options {
    var o = Options(); let args = Array(CommandLine.arguments.dropFirst()); var i = 0
    func number(_ s: String, _ max: Int) throws -> Int {
        guard let n = Int(s), n > 0, n <= max else { throw Failure("Invalid positive bounded integer: \(s)") }; return n
    }
    if args.contains("--metal-batch") { o.metalBatch = true; o.repetitions = 6 }
    // Apply smoke defaults first so explicit options always override them.
    if args.contains("--smoke") { o.smoke = true; o.largeBytes = [16_777_219]; o.smallIterations = 2000; o.repetitions = 2 }
    while i < args.count {
        let a = args[i]; i += 1
        func value() throws -> String { guard i < args.count else { throw Failure("Missing value for \(a)") }; defer { i += 1 }; return args[i] }
        switch a {
        case "--help", "-h": print(help); exit(0)
        case "--smoke", "--metal-batch": break
        case "--self-test": o.selfTest = true
        case "--force": o.force = true
        case "--large-bytes":
            let parts = try value().split(separator: ",", omittingEmptySubsequences: false)
            try check(!parts.isEmpty && parts.count <= 16, "Require 1...16 large sizes")
            o.largeBytes = try parts.map { try number(String($0), 4_000_000_000) }
            try check(Set(o.largeBytes).count == o.largeBytes.count, "Duplicate large sizes")
        case "--chunk-bytes": o.chunkBytes = try number(value(), Int(UInt32.max))
        case "--small-iterations": o.smallIterations = try number(value(), 100_000_000)
        case "--repetitions": o.repetitions = try number(value(), 100); try check(o.repetitions >= 2, "At least two repetitions required")
        case "--output-dir": o.outputDir = try value(); try check(!o.outputDir.isEmpty, "Empty output path")
        default: throw Failure("Unknown option: \(a)")
        }
    }
    return o
}
func checkedLength(_ count: Int) throws -> CC_LONG {
    try check(count >= 0 && UInt64(count) <= UInt64(UInt32.max), "CommonCrypto one-shot length exceeds CC_LONG; refusing truncation")
    return CC_LONG(count)
}
// Four words provide fixed stack storage for the complete 32-byte digest.
struct Digest32: Equatable { var a: UInt64 = 0, b: UInt64 = 0, c: UInt64 = 0, d: UInt64 = 0 }
func hex(_ digest: Digest32) -> String { withUnsafeBytes(of: digest) { $0.map { String(format: "%02x", $0) }.joined() } }
@inline(never) func ccOne(_ data: Data) throws -> Digest32 {
    let n = try checkedLength(data.count); var out = Digest32()
    _ = withUnsafeMutableBytes(of: &out) { dst in data.withUnsafeBytes { src in CC_SHA256(src.baseAddress, n, dst.baseAddress!.assumingMemoryBound(to: UInt8.self)) } }
    return out
}
@inline(never) func ckOne(_ data: Data) -> Digest32 {
    SHA256.hash(data: data).withUnsafeBytes { $0.loadUnaligned(as: Digest32.self) }
}
@inline(never) func ccIncremental(_ raw: UnsafeRawBufferPointer, _ chunk: Int) throws -> Digest32 {
    var context = CC_SHA256_CTX(); var out = Digest32()
    try check(CC_SHA256_Init(&context) == 1, "CC init failed")
    var offset = 0
    while offset < raw.count {
        let n = min(chunk, raw.count - offset)
        try check(CC_SHA256_Update(&context, raw.baseAddress!.advanced(by: offset), checkedLength(n)) == 1, "CC update failed")
        offset += n
    }
    try check(withUnsafeMutableBytes(of: &out) { CC_SHA256_Final($0.baseAddress!.assumingMemoryBound(to: UInt8.self), &context) } == 1, "CC final failed")
    return out
}
@inline(never) func ckIncremental(_ raw: UnsafeRawBufferPointer, _ chunk: Int) -> Digest32 {
    var hasher = SHA256(); var offset = 0
    while offset < raw.count {
        let n = min(chunk, raw.count - offset)
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress!.advanced(by: offset), count: n))
        offset += n
    }
    return hasher.finalize().withUnsafeBytes { $0.loadUnaligned(as: Digest32.self) }
}
final class Input {
    let pointer: UnsafeMutableRawPointer; let count: Int; var data: Data
    init(_ count: Int, _ inputSeed: UInt64) throws {
        var p: UnsafeMutableRawPointer?
        try check(posix_memalign(&p, 64, count) == 0 && p != nil, "Allocation failed: \(count) bytes")
        pointer = p!; self.count = count; data = Data()
        // SplitMix64: deterministic high-entropy words, all pages written before timing.
        var state = inputSeed; var offset = 0
        while offset < count {
            state &+= 0x9e3779b97f4a7c15; var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb; z ^= z >> 31
            let n = min(8, count - offset)
            withUnsafeBytes(of: &z) { pointer.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: n) }
            offset += n
        }
        data = Data(bytesNoCopy: pointer, count: count, deallocator: .none)
        let same = data.withUnsafeBytes { $0.baseAddress == UnsafeRawPointer(pointer) && $0.count == count }
        try check(same, "Data representation copied the input; zero-copy benchmark refused")
    }
    var raw: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: pointer, count: count) }
    deinit { data = Data(); free(pointer) }
}
struct Sink: Codable, Equatable {
    var a: UInt64 = 1, b: UInt64 = 2, c: UInt64 = 3, d: UInt64 = 4
    @inline(__always) mutating func consume(_ x: Digest32) {
        a = (a &* 0x100000001b3) &+ x.a; b = (b &* 0x100000001b3) &+ x.b
        c = (c &* 0x100000001b3) &+ x.c; d = (d &* 0x100000001b3) &+ x.d
    }
}
func selfTests() throws {
    let vectors: [(Data,String)] = [
        (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (Data(repeating: 0, count: 64), "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b"),
        (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        (Data(repeating: 97, count: 1_000_000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")]
    for (data, expected) in vectors {
        let cc = try ccOne(data); try check(hex(cc) == expected && ckOne(data) == cc, "Known vector mismatch")
        for chunk in [1, 257, 1_000_000] {
            try data.withUnsafeBytes { raw in
                try check(ccIncremental(raw, chunk) == cc && ckIncremental(raw, chunk) == cc, "Incremental vector mismatch")
            }
        }
    }
    let source = Data((0..<256).map(UInt8.init)); let reference = try ccOne(source)
    try source.withUnsafeBytes { raw in
        for chunk in [1, 7, 255, 256, 257] { try check(ccIncremental(raw, chunk) == reference && ckIncremental(raw, chunk) == reference, "Tail mismatch") }
    }
    let input = try Input(4099, seed)
    try check(ccOne(input.data) == ckOne(input.data), "No-copy input mismatch")
    try check(checkedLength(Int(UInt32.max)) == UInt32.max, "CC_LONG boundary mismatch")
    var rejected = false
    do { _ = try checkedLength(Int(UInt32.max) + 1) } catch { rejected = true }
    try check(rejected, "CC_LONG overflow was accepted")
    print("SELF-TEST PASS: known vectors, full digests, incremental tails/1-byte chunks, zero-copy, CC_LONG overflow")
}
func sysctlString(_ name: String) -> String? {
    var n = 0; guard sysctlbyname(name, nil, &n, nil, 0) == 0, n > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: n)
    guard sysctlbyname(name, &bytes, &n, nil, 0) == 0 else { return nil }; return String(cString: bytes)
}
func sysctlNumber(_ name: String) -> UInt64? {
    var n = 0; guard sysctlbyname(name, nil, &n, nil, 0) == 0 else { return nil }
    if n == 4 { var v: UInt32 = 0; guard sysctlbyname(name, &v, &n, nil, 0) == 0 else { return nil }; return UInt64(v) }
    if n == 8 { var v: UInt64 = 0; guard sysctlbyname(name, &v, &n, nil, 0) == 0 else { return nil }; return v }; return nil
}
struct Sample: Codable {
    let available: Bool, pageins: UInt64?, rssBytes: UInt64?, physicalFootprintBytes: UInt64?
    let minorFaults: Int64, majorFaults: Int64, thermalState: Int
    init() {
        let p = benchmark_probe(); available = p.available != 0
        pageins = available ? p.pageins : nil; rssBytes = available ? p.resident : nil
        physicalFootprintBytes = available ? p.footprint : nil
        minorFaults = p.minor_faults; majorFaults = p.major_faults
        thermalState = ProcessInfo.processInfo.thermalState.rawValue
    }
}
struct Measurement: Codable {
    let mode: String, api: String, inputBytes: Int, calls: Int, totalBytes: UInt64, repetition: Int, order: Int
    let elapsedNanoseconds: UInt64, gbPerSecond: Double, nsPerHash: Double, hashesPerSecond: Double
    let sink: Sink, before: Sample, after: Sample, flags: [String]
}
struct Summary: Codable {
    let mode: String, api: String, inputBytes: Int, samples: Int
    let medianGBPerSecond: Double, minGBPerSecond: Double, maxGBPerSecond: Double, medianNSPerHash: Double
    let commonCryptoOverCryptoKitThroughput: Double, flaggedSamples: Int
}
func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
func summaries(_ raw: [Measurement]) -> [Summary] {
    let groups = Dictionary(grouping: raw) { "\($0.mode):\($0.inputBytes):\($0.api)" }
    return groups.keys.sorted().map { key in
        let g = groups[key]!, m = g[0], speeds = g.map(\.gbPerSecond)
        let cc = raw.filter { $0.mode == m.mode && $0.inputBytes == m.inputBytes && $0.api == "CommonCrypto" }.map(\.gbPerSecond)
        let ck = raw.filter { $0.mode == m.mode && $0.inputBytes == m.inputBytes && $0.api == "CryptoKit" }.map(\.gbPerSecond)
        return Summary(mode: m.mode, api: m.api, inputBytes: m.inputBytes, samples: g.count,
            medianGBPerSecond: median(speeds), minGBPerSecond: speeds.min()!, maxGBPerSecond: speeds.max()!,
            medianNSPerHash: median(g.map(\.nsPerHash)), commonCryptoOverCryptoKitThroughput: cc.isEmpty || ck.isEmpty ? 0 : median(cc) / median(ck),
            flaggedSamples: g.filter { !$0.flags.isEmpty }.count)
    }
}
struct Metadata: Encodable {
    let cpu: String, os: String, physicalMemoryBytes: UInt64, sha256Capability: UInt64?
    let callingThreads = 1, poolBuffers = 4096, decimalGB = 1_000_000_000
    let inputSeed = String(seed), zeroCopyVerified = true
    let build: [String:String]
    let caveats = "System-optimized Apple APIs; shared internal implementation and acceleration usage unknown. Prefault/warmup are best effort; no memory locking, OS paging possible. Small wrapper and complete-digest sink costs included. GB/s ratio CC/CK > 1 means CommonCrypto faster. Thermal states 0 nominal, 1 fair, 2 serious, 3 critical. Sampling and output I/O outside hash timers."
    init() {
        cpu = sysctlString("machdep.cpu.brand_string") ?? "unknown"
        os = ProcessInfo.processInfo.operatingSystemVersionString
        physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        sha256Capability = sysctlNumber("hw.optional.arm.FEAT_SHA256")
        let buildDir = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
        var b = [String:String]()
        for file in ["compiler.txt","sdk-version.txt","sdk-path.txt","target.json","flags.txt","source-sha256.txt"] { b[file] = (try? String(contentsOf: buildDir.appendingPathComponent(file), encoding: .utf8)) ?? "unknown" }
        build = b
    }
}
struct Report: Encodable { let metadata: Metadata, options: Options, completed: Bool, measurements: [Measurement], summaries: [Summary] }
// Keep replacement temporary files in the owned output directory. Foundation's
// atomic write may request a separate item-replacement location on macOS.
func atomicWrite(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporary)
    if rename(temporary.path, destination.path) != 0 {
        let code = errno; try? FileManager.default.removeItem(at: temporary)
        throw Failure("Atomic rename failed (errno \(code)) for \(destination.path)")
    }
}
final class Runner {
    let options: Options, metadata = Metadata(), directory: URL
    var raw = [Measurement]()
    init(_ input: Options) throws {
        var o = input
        if o.outputDir.isEmpty {
            let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
            o.outputDir = root.appendingPathComponent("run-\(UInt64(Date().timeIntervalSince1970))-\(getpid())").path
        }
        directory = URL(fileURLWithPath: o.outputDir).standardizedFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) && !o.force {
            let contents = try fm.contentsOfDirectory(atPath: directory.path)
            try check(contents.isEmpty, "Output directory is nonempty; choose a new path or --force")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        options = o
    }
    func save(_ completed: Bool = false) throws {
        let report = Report(metadata: metadata, options: options, completed: completed, measurements: raw, summaries: summaries(raw))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(encoder.encode(report), to: directory.appendingPathComponent("report.json"))
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["mode,api,input_bytes,calls,total_bytes,repetition,order,elapsed_ns,GB_per_s,ns_per_hash,hashes_per_s,flags"]
        for m in raw { rows.append([quote(m.mode),quote(m.api),String(m.inputBytes),String(m.calls),String(m.totalBytes),String(m.repetition),String(m.order),String(m.elapsedNanoseconds),String(m.gbPerSecond),String(m.nsPerHash),String(m.hashesPerSecond),quote(m.flags.joined(separator: ";"))].joined(separator: ",")) }
        try atomicWrite(Data((rows.joined(separator: "\n") + "\n").utf8), to: directory.appendingPathComponent("measurements.csv"))
    }
    func measure(mode: String, api: String, size: Int, calls: Int, rep: Int, order: Int, expected: Sink, body: () throws -> Sink) throws {
        let before = Sample(); let start = DispatchTime.now().uptimeNanoseconds
        let sink = try body()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start; let after = Sample()
        try check(sink == expected, "Timed digest/sink mismatch: \(mode) \(api) \(size)")
        try check(elapsed > 0, "Zero elapsed time")
        var flags = [String]()
        if before.thermalState >= 2 || after.thermalState >= 2 { flags.append("contaminated:serious-or-critical-thermal") }
        if let a = before.pageins, let b = after.pageins, b > a { flags.append("contaminated:process-pageins-increased") }
        if !before.available || !after.available { flags.append("pagein-residency-unknown") }
        if Double(elapsed) < 100_000_000 { flags.append("short-sample-under-100ms") }
        let bytes = UInt64(size) * UInt64(calls), ns = Double(elapsed), speed = Double(bytes) / ns
        try check(speed.isFinite && ns.isFinite, "Non-finite result")
        raw.append(Measurement(mode: mode, api: api, inputBytes: size, calls: calls, totalBytes: bytes, repetition: rep, order: order,
            elapsedNanoseconds: elapsed, gbPerSecond: speed, nsPerHash: ns / Double(calls), hashesPerSecond: Double(calls) * 1e9 / ns,
            sink: sink, before: before, after: after, flags: flags))
        try save()
    }
    func cell(mode: String, size: Int, calls: Int, expected: Sink, cc: () throws -> Sink, ck: () throws -> Sink) throws {
        try check(cc() == expected && ck() == expected, "Warmup mismatch")
        for rep in 0..<options.repetitions {
            let order = rep % 2 == 0 ? ["CommonCrypto","CryptoKit"] : ["CryptoKit","CommonCrypto"]
            for (position, api) in order.enumerated() {
                try measure(mode: mode, api: api, size: size, calls: calls, rep: rep + 1, order: position + 1, expected: expected, body: api == "CommonCrypto" ? cc : ck)
            }
        }
        print("Completed \(mode) \(size) B × \(calls) calls, \(options.repetitions) repeats/API")
    }
    func large(_ size: Int) throws {
        let input = try Input(size, seed); let expectedDigest = try ccOne(input.data)
        try check(expectedDigest == ckOne(input.data), "Large full digest mismatch")
        var expected = Sink(); expected.consume(expectedDigest)
        try cell(mode: "one-shot", size: size, calls: 1, expected: expected,
            cc: { var s = Sink(); s.consume(try ccOne(input.data)); return s },
            ck: { var s = Sink(); s.consume(ckOne(input.data)); return s })
        try cell(mode: "incremental", size: size, calls: 1, expected: expected,
            cc: { var s = Sink(); s.consume(try ccIncremental(input.raw, self.options.chunkBytes)); return s },
            ck: { var s = Sink(); s.consume(ckIncremental(input.raw, self.options.chunkBytes)); return s })
        // Input and its Data wrapper released at method return, before next size.
    }
    func small(_ size: Int) throws {
        let pool = try (0..<4096).map { try Input(size, seed &+ UInt64($0)) }
        var reference = [Digest32](); reference.reserveCapacity(pool.count)
        for input in pool {
            let d = try ccOne(input.data); try check(d == ckOne(input.data), "Small pool full digest mismatch"); reference.append(d)
        }
        var expected = Sink()
        for i in 0..<options.smallIterations { expected.consume(reference[i & 4095]) }
        try cell(mode: "small-independent", size: size, calls: options.smallIterations, expected: expected,
            cc: { var s = Sink(); for i in 0..<self.options.smallIterations { s.consume(try ccOne(pool[i & 4095].data)) }; return s },
            ck: { var s = Sink(); for i in 0..<self.options.smallIterations { s.consume(ckOne(pool[i & 4095].data)) }; return s })
    }
    func run() throws {
        print("CPU: \(metadata.cpu); OS: \(metadata.os); memory: \(metadata.physicalMemoryBytes) B")
        print("Decimal GB/s; chunk \(options.chunkBytes) B; output \(directory.path)")
        try save()
        for size in options.largeBytes { try large(size) }
        for size in options.smallSizes { try small(size) }
        try save(true)
        print("mode               bytes       API           median GB/s   min...max GB/s     ns/hash      CC/CK")
        for s in summaries(raw) {
            print(String(format: "%@ %10lld %@ %.4f %.4f...%.4f %.1f %.3f", s.mode, Int64(s.inputBytes), s.api, s.medianGBPerSecond, s.minGBPerSecond, s.maxGBPerSecond, s.medianNSPerHash, s.commonCryptoOverCryptoKitThroughput))
        }
        print("Report: \(directory.appendingPathComponent("report.json").path)")
    }
}
do {
    let options = try parse()
    try selfTests()
    if !options.selfTest {
        if options.metalBatch { try runMetalBatch(options) } else { try Runner(options).run() }
    }
} catch {
    fputs("ERROR: \(error)\n", stderr); exit(1)
}
