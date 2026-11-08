#if DEBUG
import Foundation

public enum DebugBenchmarkMode: String, Codable, Sendable { case write, read, both }
public struct DebugBenchmarkProgress: Sendable {
    public let phase: String
    public let bytes: UInt64
    public let total: UInt64
}
public struct DebugBenchmarkAdmission: Sendable {
    public private(set) var current: UUID?
    public init() {}
    public mutating func begin() -> UUID? {
        guard current == nil else { return nil }
        let next = UUID(); current = next; return next
    }
    public mutating func finish(_ generation: UUID) { if current == generation { current = nil } }
}
public struct DebugHelperMetric: Codable, Sendable {
    public let id: String
    public let calls, ns, requested, returned, errors: UInt64
    public let histogram: [UInt64]
}
public struct DebugHelperProfile: Codable, Sendable {
    static let metricNames = ["callback_read", "callback_write", "native_read", "native_write", "tree_wait", "tree_hold", "lz4_encode", "lz4_decode", "sha256", "mmap", "memcpy", "account", "compressed_block", "raw_block"]
    public let version: Int
    public let integrityAlgorithm: String
    public let run: UUID
    public let phase, backend: String
    public let compression: Bool
    public let periodicMinutes: UInt64
    public let debugBuild: Bool
    public let clock: String
    public let elapsedNS: UInt64
    public let stopped, expired: Bool
    public let inFlight: UInt64
    public let metrics: [DebugHelperMetric]
    public func seconds(for id: String) -> Double? {
        if id.hasPrefix("lz4_") && !compression { return nil }
        if id == "sha256" && integrityAlgorithm == FileVerification.sizeAndModTime.rawValue { return nil }
        guard let m = metrics.first(where: { $0.id == id }) else { return nil }
        return Double(m.ns) / 1e9
    }
    static func parse(_ fields: [String], run: UUID, phase: String, verification: FileVerification = .sha256) throws -> Self {
        guard fields.count == 1, fields[0].utf8.count < 8192 else { throw NestError("Invalid Debug profile frame.") }
        let data = Data(fields[0].utf8)
        let rootKeys: Set<String> = ["version", "integrityAlgorithm", "run", "phase", "backend", "compression", "periodicMinutes", "debugBuild", "clock", "elapsedNS", "stopped", "expired", "inFlight", "metrics"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == rootKeys,
              let rows = object["metrics"] as? [[String: Any]], rows.count == metricNames.count,
              rows.allSatisfy({ Set($0.keys) == ["id", "calls", "ns", "requested", "returned", "errors", "histogram"] }) else { throw NestError("Unknown or missing Debug profile fields.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 2, result.integrityAlgorithm == verification.rawValue, result.run == run, result.phase == phase,
              ["nfs", "fskit", "smb"].contains(result.backend), result.debugBuild,
              result.clock == "steady_clock_ns", result.periodicMinutes <= UInt64(Int32.max),
              result.elapsedNS <= 600_000_000_000, result.inFlight <= 1_000_000,
              result.metrics.map(\.id) == metricNames,
              result.metrics.allSatisfy({ $0.histogram.count == 5 && [$0.calls, $0.ns, $0.requested, $0.returned, $0.errors].allSatisfy { $0 <= 9_000_000_000_000_000 } && $0.histogram.allSatisfy { $0 <= 9_000_000_000_000_000 } }) else {
            throw NestError("Invalid, stale or unsupported Debug profile response.")
        }
        if verification == .sizeAndModTime {
            guard let sha = result.metrics.first(where: { $0.id == "sha256" }), sha.calls == 0, sha.requested == 0 else {
                throw NestError("Metadata verification profile unexpectedly hashed payload bytes.")
            }
        }
        return result
    }
}
public struct DebugBenchmarkPhase: Encodable, Sendable {
    public let phase: String
    public var bytes: UInt64 = 0
    public var wallSeconds = 0.0
    public var syscallSeconds = 0.0
    public var generationSeconds = 0.0
    public var verificationSeconds = 0.0
    public var externalVerificationSeconds = 0.0
    public var verified = false
    public var cacheNoCacheAccepted = false
    public var cacheErrno: Int32 = 0
    public var helper: DebugHelperProfile?
    public var throughputSeconds: Double { max(0, wallSeconds - generationSeconds - verificationSeconds) }
    public var decimalMBps: Double? { throughputSeconds > 0 && bytes > 0 ? Double(bytes) / 1_000_000 / throughputSeconds : nil }
    private enum CodingKeys: String, CodingKey {
        case phase, bytes, wallSeconds, syscallSeconds, generationSeconds, verificationSeconds, externalVerificationSeconds
        case verified, cacheNoCacheAccepted, cacheErrno, helper, throughputSeconds, decimalMBps
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phase, forKey: .phase); try c.encode(bytes, forKey: .bytes)
        try c.encode(wallSeconds, forKey: .wallSeconds); try c.encode(syscallSeconds, forKey: .syscallSeconds)
        try c.encode(generationSeconds, forKey: .generationSeconds); try c.encode(verificationSeconds, forKey: .verificationSeconds)
        try c.encode(externalVerificationSeconds, forKey: .externalVerificationSeconds); try c.encode(verified, forKey: .verified)
        try c.encode(cacheNoCacheAccepted, forKey: .cacheNoCacheAccepted); try c.encode(cacheErrno, forKey: .cacheErrno)
        try c.encodeIfPresent(helper, forKey: .helper); try c.encode(throughputSeconds, forKey: .throughputSeconds)
        try c.encode(decimalMBps, forKey: .decimalMBps)
    }
}
public struct DebugBenchmarkEvent: Codable, Sendable {
    public let origin, phase, message: String
    public let monotonicSeconds: Double
}
public struct DebugBenchmarkReport: Encodable, Sendable {
    public let run: UUID
    public let requestedBytes: UInt64
    public let blockBytes: Int
    public let mode: DebugBenchmarkMode
    public var configuration = "Debug; Swift -Onone; native CMake Debug (-O0 default). Profiling overhead; not Release-equivalent."
    public var clock = "app DispatchTime.uptimeNanoseconds (monotonic); helper steady_clock nanoseconds"
    public var cacheMode = "fcntl(F_NOCACHE) best effort per reopened file; physical cold I/O not established; OS read-ahead/caches can change helper bytes"
    public var scope = "WINDOW-WIDE helper counters, including background clients; no inode-exclusive correlation. Nested INCLUSIVE rows overlap and must not be summed."
    public var unobservable = "FUSE-T driver, NFS/SMB bridge and FSKit system extension private internals: not directly instrumented. Transport residual: N/A (concurrent/window-wide inclusive accounting). Metadata callbacks, zero-fill, allocator internals and kernel time are not individually covered."
    public var windowWideContaminationPossible = true
    public var metricSemantics: [String: String] = [
        "callback_read/write": "helper depth 0, inclusive callback wall; requested/returned bytes/errors/histograms",
        "native_read/write": "callback child depth 1, inclusive MemoryFS wall",
        "tree_wait/hold": "native acquisition regions; cumulative wait and hold wall across capture, revalidation, commit and fallback; hold ends before unlock",
        "lz4_encode/decode": "native work, usually outside tree_hold (serialized fallback/import may hold it); actual codec calls only; disabled = N/A, not measured zero; requested input and returned output bytes",
        "sha256": "native work, usually outside tree_hold; full logical 64 KiB integrity hashing in SHA sessions only; disabled in sizeAndModTime sessions; requested is actual hashed bytes",
        "mmap/memcpy/account": "native work, inside or outside tree_hold; selected page allocation/copies and Node.account; other copies/metadata not individually instrumented",
        "compressed_block/raw_block": "outcome counts, requested logical bytes and returned payload bytes; duration is not a performance layer",
        "availability": "Zero enabled-codec calls means no observed calls; in-flight/expired windows can omit unfinished work; window-wide background clients are possible"
    ]
    public var backend: String?
    public var compression: Bool?
    public var preparationSeconds = 0.0
    public var cleanupSeconds = 0.0
    public var totalSeconds = 0.0
    public var cleanupSucceeded = false
    public var failure: String?
    public var phases: [DebugBenchmarkPhase] = []
    public var events: [DebugBenchmarkEvent] = []
    mutating func event(_ origin: String, _ phase: String, _ message: String) {
        guard events.count < 32 else { return }
        events.append(.init(origin: origin, phase: phase, message: message, monotonicSeconds: DebugBenchmarkWorker.now()))
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count < 128 * 1024 else { throw NestError("Benchmark report exceeds bounded export size.") }
        return data
    }
    public var text: String {
        var lines = ["RAMNest Debug I/O report · \(run)", "\(requestedBytes) bytes (1 GB = 1,000,000,000 bytes); block \(blockBytes) bytes; decimal MB/s", configuration, clock,
                     "Running backend: \(backend ?? "unknown"); actual helper compression: \(compression.map { $0 ? "LZ4 enabled" : "disabled" } ?? "unknown")", cacheMode, scope, unobservable,
                     String(format: "Preparation %.6f s · cleanup %.6f s (%@) · total %.6f s", preparationSeconds, cleanupSeconds, cleanupSucceeded ? "verified removal" : "incomplete/not created", totalSeconds)]
        for p in phases {
            lines.append("\n\(p.phase.uppercased()): \(p.bytes) actual bytes · \(p.decimalMBps.map { String(format: "%.2f MB/s", $0) } ?? "N/A") · payload verification \(p.verified ? "PASS" : "not completed")")
            lines.append(String(format: "app wall %.6f s; I/O wall excluding generation/verification %.6f s; syscalls %.6f s; generation %.6f s; verification %.6f s", p.wallSeconds, p.throughputSeconds, p.syscallSeconds, p.generationSeconds, p.verificationSeconds))
            lines.append(String(format: "Separate post-write full readback verification outside throughput: %.6f s", p.externalVerificationSeconds))
            lines.append("write includes open + pwrite + fsync + checked close; read includes open + pread + checked close. F_NOCACHE accepted=\(p.cacheNoCacheAccepted), errno=\(p.cacheErrno)")
            if let h = p.helper {
                lines.append("Running helper integrity: \(h.integrityAlgorithm); debug-io-profile-v2 (JSON version \(h.version)); \(h.integrityAlgorithm == "sha256" ? "full logical 64 KiB SHA per verification" : "regular-file payload SHA disabled; structural decode and metadata checks only").")
                lines.append("helper window stopped=\(h.stopped), expired=\(h.expired), in-flight roots at snapshot=\(h.inFlight). Partial in-flight scopes may be omitted; background contamination is possible.")
                lines.append("layer [parent/depth] | inclusive seconds | calls | requested/returned bytes | errors")
                for m in h.metrics {
                    let parent: String
                    switch m.id {
                    case "callback_read", "callback_write": parent = "helper/0"
                    case "native_read", "native_write": parent = "callback/1"
                    case "tree_wait", "tree_hold": parent = "native/2"
                    default: parent = "native work; may be outside tree_hold or from other clients"
                    }
                    let duration = m.id.hasSuffix("_block") ? "N/A (block outcome count only)" : h.seconds(for: m.id).map { String(format: "%.9f", $0) } ?? (m.id == "sha256" ? "N/A (payload SHA disabled)" : "N/A (codec disabled)")
                    lines.append("\(m.id) [\(parent)] | \(duration) | \(m.calls) | \(m.requested)/\(m.returned) | \(m.errors)")
                }
                let reads = h.metrics.first { $0.id == "callback_read" }
                lines.append("Actual helper reads: \(reads?.calls ?? 0) requests, \(reads?.requested ?? 0) requested / \(reads?.returned ?? 0) returned bytes. Histogram buckets <=4KiB, <=64KiB, <=256KiB, <=1MiB, >1MiB are in JSON.")
            } else { lines.append("Helper aggregates unavailable; no zero timings inferred.") }
        }
        if let failure { lines.append("\nFAILED / CANCELLED: \(failure)") }
        for e in events { lines.append(String(format: "[%.6f] run=%@ phase=%@ origin=%@ %@", e.monotonicSeconds, run.uuidString, e.phase, e.origin, e.message)) }
        return lines.joined(separator: "\n")
    }
}
#endif
