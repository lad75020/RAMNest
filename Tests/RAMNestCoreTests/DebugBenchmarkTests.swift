#if DEBUG && !RAMNEST_STANDALONE
import XCTest
import Darwin
@testable import RAMNestCore

final class DebugBenchmarkTests: XCTestCase {
    private func root() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = project.appendingPathComponent("artifacts/sha256-only/fixtures/\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testPayloadAndOffsetVerification() throws {
        let a = DebugBenchmarkWorker.payload(count: 65536, seed: 17)
        XCTAssertGreaterThan(Set(a).count, 240)
        var b = a; DebugBenchmarkWorker.tag(&b, offset: 65536)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b, { var c = a; DebugBenchmarkWorker.tag(&c, offset: 65536); return c }())
    }
    func testShortIOEINTRAndCancellation() throws {
        var calls = 0
        let token = DebugBenchmarkCancellation()
        let count = try DebugBenchmarkWorker.transfer(count: 13, cancellation: token) { offset, remaining in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            return min(3, remaining)
        }
        XCTAssertEqual(count, 13); XCTAssertEqual(calls, 6)
        token.cancel()
        XCTAssertThrowsError(try DebugBenchmarkWorker.transfer(count: 1, cancellation: token) { _, _ in XCTFail(); return 1 })
        XCTAssertThrowsError(try DebugBenchmarkWorker.transfer(count: 2, cancellation: .init()) { _, _ in errno = ENOSPC; return -1 })
        XCTAssertThrowsError(try DebugBenchmarkWorker.transfer(count: 2, cancellation: .init()) { _, _ in 0 })
    }
    func testCapacityRoundedAndOverflow() {
        XCTAssertEqual(try DebugBenchmarkWorker.requiredCapacity(bytes: 1_000_000_000), 1_016_791_040)
        XCTAssertThrowsError(try DebugBenchmarkWorker.requiredCapacity(bytes: UInt64.max))
        XCTAssertThrowsError(try DebugBenchmarkWorker.checkCapacity(available: 100, bytes: 65536))
    }
    func testOwnedCleanupAndReplacement() throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let parent = try DirectoryHandle.open(url)
        let owned = try DebugBenchmarkFile(parent: parent, run: UUID())
        let fd = try owned.create(); XCTAssertEqual(write(fd, "abc", 3), 3); try owned.closeFile()
        try owned.cleanup(); XCTAssertTrue(try parent.names().isEmpty)
        let changed = try DebugBenchmarkFile(parent: parent, run: UUID())
        _ = try changed.create(); try changed.closeFile()
        XCTAssertEqual(unlinkat(changed.directory.fd, "payload", 0), 0)
        XCTAssertEqual(symlinkat("/never-follow", changed.directory.fd, "payload"), 0)
        XCTAssertThrowsError(try changed.cleanup())
        XCTAssertEqual(try changed.directory.entryStat("payload").st_mode & S_IFMT, S_IFLNK)
    }
    private func fixtureJSON(run: UUID, phase: String, compression: Bool) -> String {
        let metrics = DebugHelperProfile.metricNames.map { "{\"id\":\"\($0)\",\"calls\":0,\"ns\":0,\"requested\":0,\"returned\":0,\"errors\":0,\"histogram\":[0,0,0,0,0]}" }.joined(separator: ",")
        return "{\"version\":2,\"integrityAlgorithm\":\"sha256\",\"run\":\"\(run)\",\"phase\":\"\(phase)\",\"backend\":\"nfs\",\"compression\":\(compression),\"periodicMinutes\":0,\"debugBuild\":true,\"clock\":\"steady_clock_ns\",\"elapsedNS\":0,\"stopped\":false,\"expired\":false,\"inFlight\":0,\"metrics\":[\(metrics)]}"
    }
    func testStrictProfileReplyAndNA() throws {
        let run = UUID()
        let valid = fixtureJSON(run: run, phase: "read", compression: false)
        let profile = try DebugHelperProfile.parse([valid], run: run, phase: "read")
        XCTAssertFalse(profile.compression)
        XCTAssertNil(profile.seconds(for: "lz4_encode")); XCTAssertNil(profile.seconds(for: "lz4_decode"))
        let enabled = try DebugHelperProfile.parse([fixtureJSON(run: run, phase: "read", compression: true)], run: run, phase: "read")
        XCTAssertEqual(enabled.seconds(for: "lz4_encode"), 0)
        XCTAssertThrowsError(try DebugHelperProfile.parse([String(valid.dropLast())], run: run, phase: "read"))
        XCTAssertThrowsError(try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"version\":2", with: "\"version\":1")], run: run, phase: "read"))
        XCTAssertThrowsError(try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"elapsedNS\":0", with: "\"elapsedNS\":-1")], run: run, phase: "read"))
        XCTAssertThrowsError(try DebugHelperProfile.parse([valid], run: UUID(), phase: "read"))
        for replacement in ["18446744073709551616", "1e999", "null"] {
            XCTAssertThrowsError(try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"elapsedNS\":0", with: "\"elapsedNS\":\(replacement)")], run: run, phase: "read"))
        }
        XCTAssertThrowsError(try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"version\":2", with: "\"unknown\":0,\"version\":2")], run: run, phase: "read"))
        XCTAssertThrowsError(try DebugHelperProfile.parse([valid, valid], run: run, phase: "read"))
        XCTAssertThrowsError(try DebugHelperProfile.parse([valid.replacingOccurrences(of: run.uuidString, with: "not-a-uuid")], run: run, phase: "read"))
        XCTAssertThrowsError(try DebugHelperProfile.parse([valid.replacingOccurrences(of: "callback_read", with: "unknown_metric")], run: run, phase: "read"))
        XCTAssertThrowsError(try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"inFlight\":0", with: "\"inFlight\":1000001")], run: run, phase: "read"))
    }
    func testSHAOnlyProfilePolicyRejectsLegacyAndUnknown() throws {
        let run = UUID(), valid = fixtureJSON(run: UUID(), phase: "read", compression: true)
        let frame = fixtureJSON(run: run, phase: "read", compression: true)
        let parsed = try DebugHelperProfile.parse([frame], run: run, phase: "read")
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        var legacyRows = try XCTUnwrap(legacyObject["metrics"] as? [[String: Any]])
        var legacyRow = legacyRows[0]; legacyRow["id"] = "fnv"; legacyRows.insert(legacyRow, at: 8)
        legacyObject["metrics"] = legacyRows
        let legacyFrame = String(decoding: try JSONSerialization.data(withJSONObject: legacyObject), as: UTF8.self)
        XCTAssertThrowsError(try DebugHelperProfile.parse([legacyFrame], run: run, phase: "read"))
        XCTAssertEqual(parsed.version, 2); XCTAssertEqual(parsed.integrityAlgorithm, "sha256")
        XCTAssertEqual(parsed.metrics.count, 14)
        for changed in [
            frame.replacingOccurrences(of: "\"version\":2", with: "\"version\":1"),
            frame.replacingOccurrences(of: "\"integrityAlgorithm\":\"sha256\"", with: "\"integrityAlgorithm\":\"sha512\""),
            frame.replacingOccurrences(of: "\"integrityAlgorithm\":\"sha256\",", with: ""),
            frame.replacingOccurrences(of: "\"id\":\"sha256\"", with: "\"id\":\"fnv\""),
            frame.replacingOccurrences(of: "\"id\":\"sha256\"", with: "\"id\":\"unknown\""),
            frame.replacingOccurrences(of: "\"clock\":\"steady_clock_ns\"", with: "\"clock\":\"wall\""),
            frame.replacingOccurrences(of: "\"elapsedNS\":0", with: "\"elapsedNS\":600000000001"),
            frame.replacingOccurrences(of: "\"ns\":0", with: "\"ns\":9000000000000001"),
            String(repeating: " ", count: 8192) + frame,
            valid
        ] { XCTAssertThrowsError(try DebugHelperProfile.parse([changed], run: run, phase: "read")) }
    }
    func testAdmissionGeneration() {
        var gate = DebugBenchmarkAdmission()
        let first = gate.begin(); XCTAssertNotNil(first); XCTAssertNil(gate.begin())
        gate.finish(UUID()); XCTAssertNil(gate.begin())
        gate.finish(first!); let second = gate.begin(); XCTAssertNotNil(second)
        gate.finish(first!); XCTAssertNil(gate.begin())
    }
    func testReportMathAndOverlappingRows() throws {
        var phase = DebugBenchmarkPhase(phase: "write")
        phase.bytes = 1_000_000_000; phase.wallSeconds = 4; phase.generationSeconds = 0.5; phase.verificationSeconds = 1
        phase.externalVerificationSeconds = 7
        XCTAssertEqual(phase.decimalMBps!, 400, accuracy: 0.0001)
        var report = DebugBenchmarkReport(run: UUID(), requestedBytes: 1_000_000_000, blockBytes: 1_048_576, mode: .write)
        let run = UUID()
        phase.helper = try DebugHelperProfile.parse([fixtureJSON(run: run, phase: "write", compression: true)], run: run, phase: "write")
        report.phases = [phase]
        XCTAssertTrue(report.text.contains("Running helper integrity: sha256; debug-io-profile-v2 (JSON version 2)"))
        XCTAssertTrue(report.text.contains("must not be summed")); XCTAssertTrue(report.text.contains("not directly instrumented"))
        let data = try report.json()
        XCTAssertLessThan(data.count, 128 * 1024)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(encoded["phases"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["decimalMBps"] as? Double, 400)
        let helper = try XCTUnwrap(rows[0]["helper"] as? [String: Any])
        XCTAssertEqual(helper["integrityAlgorithm"] as? String, "sha256")
        XCTAssertEqual(helper["version"] as? Int, 2)
    }
    func testCancelledOwnedFixtureCleanup() throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let parent = try DirectoryHandle.open(url), file = try DebugBenchmarkFile(parent: parent, run: UUID())
        _ = try file.create()
        let flag = DebugBenchmarkCancellation(); flag.cancel()
        XCTAssertThrowsError(try DebugBenchmarkWorker.transfer(count: 65536, cancellation: flag) { _, _ in XCTFail(); return 0 })
        try file.cleanup(); XCTAssertTrue(try parent.names().isEmpty)
    }
    func testDirectoryReplacementRetainsOtherEntry() throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let parent = try DirectoryHandle.open(url), file = try DebugBenchmarkFile(parent: parent, run: UUID())
        _ = try file.create(); try file.closeFile()
        XCTAssertEqual(renameat(parent.fd, file.name, parent.fd, "moved-owned"), 0)
        XCTAssertEqual(mkdirat(parent.fd, file.name, 0o700), 0)
        XCTAssertThrowsError(try file.cleanup())
        XCTAssertEqual(try parent.child(file.name).names(), [])
        XCTAssertEqual(try parent.child("moved-owned").names(), [])
    }
    private func ownedRun(_ mode: DebugBenchmarkMode, stale: Bool = false, cancel: Bool = false,
                          capability: Bool = true, periodic: Bool = false, capabilities: [String]? = nil,
                          profileReply: ((String) -> String)? = nil) throws -> DebugBenchmarkReport {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let parent = try DirectoryHandle.open(url), identity = try parent.identity()
        let folder = Folder(name: "owned fixture", path: url.path, capacity: 64 << 20, device: identity.device, inode: identity.inode)
        var journal = Journal(); journal.phase = .mounted; journal.backend = .nfs
        let status = HelperStatus(id: folder.id, pid: getpid(), mounted: true, used: 0, capacity: 64 << 20, active: true)
        let target = DebugBenchmarkWorker.Target(folder: folder, journal: journal, status: status, path: url.path, directory: parent,
                                               device: identity.device, inode: identity.inode, fs0: 0, fs1: 0, socket: "owned-test")
        let flag = DebugBenchmarkCancellation()
        var verifications = 0
        var requests: [String] = []
        let report = DebugBenchmarkWorker.run(mode: mode, bytes: 1_048_699, block: 1_048_576, cancellation: flag,
            progress: { _ in if cancel { flag.cancel() } }, acquire: { target }, verify: { _ in
                verifications += 1
                if stale && verifications > 2 { throw NestError("fixture configuration changed") }
            }, request: { _, command in
                requests.append(command.components(separatedBy: "\t")[0])
                if command == "capabilities" { return capability ? (capabilities ?? ["debug-io-profile-v2", "debug-benchmark-reservation-v1"]) : [] }
                let parts = command.components(separatedBy: "\t")
                if parts[0] == "profile-release" {
                    XCTAssertTrue(try parent.names().isEmpty, "Reservation must protect the complete fixture lifetime")
                    return [parts[1]]
                }
                if profileReply != nil { XCTAssertTrue(try parent.names().isEmpty, "Invalid policy must be rejected before creating a fixture") }
                let json = self.fixtureJSON(run: UUID(uuidString: parts[1])!, phase: parts[2], compression: true)
                    .replacingOccurrences(of: "\"stopped\":false", with: "\"stopped\":\(parts[0] == "profile-end")")
                    .replacingOccurrences(of: "\"periodicMinutes\":0", with: "\"periodicMinutes\":\(periodic ? 60 : 0)")
                return [profileReply?(json) ?? json]
            })
        XCTAssertTrue(try parent.names().isEmpty, "owned fixture leaked")
        if !capability || capabilities.map({ !$0.contains("debug-io-profile-v2") || !$0.contains("debug-benchmark-reservation-v1") }) == true {
            XCTAssertEqual(requests, ["capabilities"], "Legacy helpers must be rejected before the first profile RPC or lease")
        }
        return report
    }
    func testLegacyCapabilitiesAndPolicyCreateNothing() throws {
        for caps in [["debug-io-profile-v1", "debug-benchmark-reservation-v1"], ["debug-io-profile-v2"], []] {
            let report = try ownedRun(.read, capabilities: caps)
            XCTAssertNotNil(report.failure); XCTAssertTrue(report.cleanupSucceeded); XCTAssertTrue(report.phases.isEmpty)
            XCTAssertTrue(report.failure?.contains("eject and remount") == true)
        }
        let transforms: [(String) -> String] = [
            { $0.replacingOccurrences(of: "\"version\":2", with: "\"version\":1") },
            { $0.replacingOccurrences(of: "\"integrityAlgorithm\":\"sha256\"", with: "\"integrityAlgorithm\":\"unknown\"") },
            { $0.replacingOccurrences(of: "\"id\":\"sha256\"", with: "\"id\":\"fnv\"") }
        ]
        for transform in transforms {
            let report = try ownedRun(.write, profileReply: transform)
            XCTAssertNotNil(report.failure); XCTAssertTrue(report.cleanupSucceeded); XCTAssertTrue(report.phases.isEmpty)
        }
    }
    func testSmallOwnedWorkerAllModesAndCleanup() throws {
        for mode in [DebugBenchmarkMode.both, .write, .read] {
            let report = try ownedRun(mode)
            XCTAssertNil(report.failure, report.text); XCTAssertTrue(report.cleanupSucceeded)
            XCTAssertEqual(report.phases.map(\.bytes), mode == .both ? [1_048_699, 1_048_699] : [1_048_699])
            XCTAssertTrue(report.phases.allSatisfy { $0.verified && $0.decimalMBps != nil })
        }
    }
    func testRuntimeStalenessCancellationCapabilityAndPeriodic() throws {
        for report in [try ownedRun(.both, stale: true), try ownedRun(.both, cancel: true),
                       try ownedRun(.read, capability: false), try ownedRun(.write, periodic: true)] {
            XCTAssertNotNil(report.failure); XCTAssertTrue(report.cleanupSucceeded)
        }
    }
    // Explicit host gate: existing disposable, already mounted Debug product only.
    // This test neither mounts nor changes user/global configuration.
    func testOwnedMountedFullDecimalGB() throws { try fullGB(.both) }
    func testOwnedMountedStandaloneRead() throws { try fullGB(.read) }
    func testOwnedMountedStandaloneWrite() throws { try fullGB(.write) }
    private func fullGB(_ mode: DebugBenchmarkMode) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RAMNEST_RUN_OWNED_1GB"] == "YES",
              let path = env["RAMNEST_BENCHMARK_STORE"], let raw = env["RAMNEST_BENCHMARK_FOLDER"], let id = UUID(uuidString: raw) else {
            throw XCTSkip("Parent must opt into an owned current Debug NFS/FSKit mount.")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed = project.appendingPathComponent("artifacts/sha256-only").path + "/"
        XCTAssertTrue(path.hasPrefix(allowed)); guard path.hasPrefix(allowed) else { return }
        let engine = Engine(store: try Store(root: URL(fileURLWithPath: path)))
        let report = DebugBenchmarkWorker.run(engine: engine, id: id, mode: mode, cancellation: .init())
        try report.json().write(to: project.appendingPathComponent("artifacts/sha256-only/host-\(report.run).json"))
        XCTAssertNil(report.failure, report.text)
        XCTAssertEqual(report.phases.map(\.bytes), mode == .both ? [1_000_000_000, 1_000_000_000] : [1_000_000_000])
        XCTAssertTrue(report.phases.allSatisfy { $0.verified && $0.helper?.stopped == true })
        XCTAssertTrue(report.cleanupSucceeded)
    }
}
#endif
