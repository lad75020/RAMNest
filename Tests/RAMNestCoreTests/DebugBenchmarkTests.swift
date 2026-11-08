#if DEBUG && !RAMNEST_STANDALONE
import Foundation
import Testing
import Darwin
@testable import RAMNestCore

extension RAMNestTestSuite {
    struct DebugBenchmarkTests {
        private func root() throws -> URL {
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let url = project.appendingPathComponent("artifacts/sha256-only/fixtures/\(UUID())")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        @Test func `Payload and offset verification`() throws {
            let a = DebugBenchmarkWorker.payload(count: 65536, seed: 17)
            #expect(Set(a).count > 240)
            var b = a; DebugBenchmarkWorker.tag(&b, offset: 65536)
            #expect(a != b)
            #expect(b == { var c = a; DebugBenchmarkWorker.tag(&c, offset: 65536); return c }())
        }
        @Test func `Short I/O, EINTR and cancellation`() throws {
            var calls = 0
            let token = DebugBenchmarkCancellation()
            let count = try DebugBenchmarkWorker.transfer(count: 13, cancellation: token) { offset, remaining in
                calls += 1
                if calls == 1 { errno = EINTR; return -1 }
                return min(3, remaining)
            }
            #expect(count == 13); #expect(calls == 6)
            token.cancel()
            #expect(throws: (any Error).self) { try DebugBenchmarkWorker.transfer(count: 1, cancellation: token) { _, _ in Issue.record("Unexpected operation"); return 1 } }
            #expect(throws: (any Error).self) { try DebugBenchmarkWorker.transfer(count: 2, cancellation: .init()) { _, _ in errno = ENOSPC; return -1 } }
            #expect(throws: (any Error).self) { try DebugBenchmarkWorker.transfer(count: 2, cancellation: .init()) { _, _ in 0 } }
        }
        @Test func `Capacity rounded and overflow`() throws {
            #expect((try DebugBenchmarkWorker.requiredCapacity(bytes: 1_000_000_000)) == 1_016_791_040)
            #expect(throws: (any Error).self) { try DebugBenchmarkWorker.requiredCapacity(bytes: UInt64.max) }
            #expect(throws: (any Error).self) { try DebugBenchmarkWorker.checkCapacity(available: 100, bytes: 65536) }
        }
        @Test func `Owned cleanup and replacement`() throws {
            let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
            let parent = try DirectoryHandle.open(url)
            let owned = try DebugBenchmarkFile(parent: parent, run: UUID())
            let fd = try owned.create(); #expect(write(fd, "abc", 3) == 3); try owned.closeFile()
            try owned.cleanup(); #expect(try parent.names().isEmpty)
            let changed = try DebugBenchmarkFile(parent: parent, run: UUID())
            _ = try changed.create(); try changed.closeFile()
            #expect(unlinkat(changed.directory.fd, "payload", 0) == 0)
            #expect(symlinkat("/never-follow", changed.directory.fd, "payload") == 0)
            #expect(throws: (any Error).self) { try changed.cleanup() }
            #expect((try changed.directory.entryStat("payload").st_mode & S_IFMT) == S_IFLNK)
        }
        private func fixtureJSON(run: UUID, phase: String, compression: Bool) -> String {
            let metrics = DebugHelperProfile.metricNames.map { "{\"id\":\"\($0)\",\"calls\":0,\"ns\":0,\"requested\":0,\"returned\":0,\"errors\":0,\"histogram\":[0,0,0,0,0]}" }.joined(separator: ",")
            return "{\"version\":2,\"integrityAlgorithm\":\"sha256\",\"run\":\"\(run)\",\"phase\":\"\(phase)\",\"backend\":\"nfs\",\"compression\":\(compression),\"periodicMinutes\":0,\"debugBuild\":true,\"clock\":\"steady_clock_ns\",\"elapsedNS\":0,\"stopped\":false,\"expired\":false,\"inFlight\":0,\"metrics\":[\(metrics)]}"
        }
        @Test func `Strict profile reply and N/A`() throws {
            let run = UUID()
            let valid = fixtureJSON(run: run, phase: "read", compression: false)
            let profile = try DebugHelperProfile.parse([valid], run: run, phase: "read")
            #expect(!(profile.compression))
            #expect(profile.seconds(for: "lz4_encode") == nil); #expect(profile.seconds(for: "lz4_decode") == nil)
            let enabled = try DebugHelperProfile.parse([fixtureJSON(run: run, phase: "read", compression: true)], run: run, phase: "read")
            #expect(enabled.seconds(for: "lz4_encode") == 0)
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([String(valid.dropLast())], run: run, phase: "read") }
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"version\":2", with: "\"version\":1")], run: run, phase: "read") }
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"elapsedNS\":0", with: "\"elapsedNS\":-1")], run: run, phase: "read") }
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid], run: UUID(), phase: "read") }
            for replacement in ["18446744073709551616", "1e999", "null"] {
                #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"elapsedNS\":0", with: "\"elapsedNS\":\(replacement)")], run: run, phase: "read") }
            }
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"version\":2", with: "\"unknown\":0,\"version\":2")], run: run, phase: "read") }
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid, valid], run: run, phase: "read") }
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid.replacingOccurrences(of: run.uuidString, with: "not-a-uuid")], run: run, phase: "read") }
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid.replacingOccurrences(of: "callback_read", with: "unknown_metric")], run: run, phase: "read") }
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([valid.replacingOccurrences(of: "\"inFlight\":0", with: "\"inFlight\":1000001")], run: run, phase: "read") }
        }
        @Test func `SHA only profile policy rejects legacy and unknown`() throws {
            let run = UUID(), valid = fixtureJSON(run: UUID(), phase: "read", compression: true)
            let frame = fixtureJSON(run: run, phase: "read", compression: true)
            let parsed = try DebugHelperProfile.parse([frame], run: run, phase: "read")
            var legacyObject = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            var legacyRows = try #require(legacyObject["metrics"] as? [[String: Any]])
            var legacyRow = legacyRows[0]; legacyRow["id"] = "fnv"; legacyRows.insert(legacyRow, at: 8)
            legacyObject["metrics"] = legacyRows
            let legacyFrame = String(decoding: try JSONSerialization.data(withJSONObject: legacyObject), as: UTF8.self)
            #expect(throws: (any Error).self) { try DebugHelperProfile.parse([legacyFrame], run: run, phase: "read") }
            #expect(parsed.version == 2); #expect(parsed.integrityAlgorithm == "sha256")
            #expect(parsed.metrics.count == 14)
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
            ] { #expect(throws: (any Error).self) { try DebugHelperProfile.parse([changed], run: run, phase: "read") } }
        }
        @Test func `Admission generation`() throws {
            var gate = DebugBenchmarkAdmission()
            let candidate = gate.begin()
            let first = try #require(candidate)
            let blocked = gate.begin(); #expect(blocked == nil)
            gate.finish(UUID()); let stillBlocked = gate.begin(); #expect(stillBlocked == nil)
            gate.finish(first); let second = gate.begin(); #expect(second != nil)
            gate.finish(first); let staleGeneration = gate.begin(); #expect(staleGeneration == nil)
        }
        @Test func `Report math and overlapping rows`() throws {
            var phase = DebugBenchmarkPhase(phase: "write")
            phase.bytes = 1_000_000_000; phase.wallSeconds = 4; phase.generationSeconds = 0.5; phase.verificationSeconds = 1
            phase.externalVerificationSeconds = 7
            let rate = try #require(phase.decimalMBps)
            #expect(abs(rate - 400) <= 0.0001)
            var report = DebugBenchmarkReport(run: UUID(), requestedBytes: 1_000_000_000, blockBytes: 1_048_576, mode: .write)
            let run = UUID()
            phase.helper = try DebugHelperProfile.parse([fixtureJSON(run: run, phase: "write", compression: true)], run: run, phase: "write")
            report.phases = [phase]
            #expect(report.text.contains("Running helper integrity: sha256; debug-io-profile-v2 (JSON version 2)"))
            #expect(report.text.contains("must not be summed")); #expect(report.text.contains("not directly instrumented"))
            let data = try report.json()
            #expect(data.count < 128 * 1024)
            let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rows = try #require(encoded["phases"] as? [[String: Any]])
            #expect(rows[0]["decimalMBps"] as? Double == 400)
            let helper = try #require(rows[0]["helper"] as? [String: Any])
            #expect(helper["integrityAlgorithm"] as? String == "sha256")
            #expect(helper["version"] as? Int == 2)
        }
        @Test func `Cancelled owned fixture cleanup`() throws {
            let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
            let parent = try DirectoryHandle.open(url), file = try DebugBenchmarkFile(parent: parent, run: UUID())
            _ = try file.create()
            let flag = DebugBenchmarkCancellation(); flag.cancel()
            #expect(throws: (any Error).self) { try DebugBenchmarkWorker.transfer(count: 65536, cancellation: flag) { _, _ in Issue.record("Unexpected operation"); return 0 } }
            try file.cleanup(); #expect(try parent.names().isEmpty)
        }
        @Test func `Directory replacement retains other entry`() throws {
            let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
            let parent = try DirectoryHandle.open(url), file = try DebugBenchmarkFile(parent: parent, run: UUID())
            _ = try file.create(); try file.closeFile()
            #expect(renameat(parent.fd, file.name, parent.fd, "moved-owned") == 0)
            #expect(mkdirat(parent.fd, file.name, 0o700) == 0)
            #expect(throws: (any Error).self) { try file.cleanup() }
            #expect((try parent.child(file.name).names()) == [])
            #expect((try parent.child("moved-owned").names()) == [])
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
                        #expect(throws: Never.self, "Reservation must protect the complete fixture lifetime") {
                            let names = try parent.names()
                            #expect(names.isEmpty, "Reservation must protect the complete fixture lifetime")
                        }
                        return [parts[1]]
                    }
                    if profileReply != nil {
                        #expect(throws: Never.self, "Invalid policy must be rejected before creating a fixture") {
                            let names = try parent.names()
                            #expect(names.isEmpty, "Invalid policy must be rejected before creating a fixture")
                        }
                    }
                    let json = self.fixtureJSON(run: UUID(uuidString: parts[1])!, phase: parts[2], compression: true)
                        .replacingOccurrences(of: "\"stopped\":false", with: "\"stopped\":\(parts[0] == "profile-end")")
                        .replacingOccurrences(of: "\"periodicMinutes\":0", with: "\"periodicMinutes\":\(periodic ? 60 : 0)")
                    return [profileReply?(json) ?? json]
                })
            #expect(try parent.names().isEmpty, "owned fixture leaked")
            if !capability || capabilities.map({ !$0.contains("debug-io-profile-v2") || !$0.contains("debug-benchmark-reservation-v1") }) == true {
                #expect(requests == ["capabilities"], "Legacy helpers must be rejected before the first profile RPC or lease")
            }
            return report
        }
        @Test func `Legacy capabilities and policy create nothing`() throws {
            for caps in [["debug-io-profile-v1", "debug-benchmark-reservation-v1"], ["debug-io-profile-v2"], []] {
                let report = try ownedRun(.read, capabilities: caps)
                #expect(report.failure != nil); #expect(report.cleanupSucceeded); #expect(report.phases.isEmpty)
                #expect(report.failure?.contains("eject and remount") == true)
            }
            let transforms: [(String) -> String] = [
                { $0.replacingOccurrences(of: "\"version\":2", with: "\"version\":1") },
                { $0.replacingOccurrences(of: "\"integrityAlgorithm\":\"sha256\"", with: "\"integrityAlgorithm\":\"unknown\"") },
                { $0.replacingOccurrences(of: "\"id\":\"sha256\"", with: "\"id\":\"fnv\"") }
            ]
            for transform in transforms {
                let report = try ownedRun(.write, profileReply: transform)
                #expect(report.failure != nil); #expect(report.cleanupSucceeded); #expect(report.phases.isEmpty)
            }
        }
        @Test(arguments: [DebugBenchmarkMode.both, .write, .read])
        func `Small owned worker all modes and cleanup`(mode: DebugBenchmarkMode) throws {
            let report = try ownedRun(mode)
            #expect(report.failure == nil, Comment(rawValue: report.text)); #expect(report.cleanupSucceeded)
            #expect(report.phases.map(\.bytes) == (mode == .both ? [1_048_699, 1_048_699] : [1_048_699]))
            #expect(report.phases.allSatisfy { $0.verified && $0.decimalMBps != nil })
        }
        @Test func `Runtime staleness cancellation capability and periodic`() throws {
            for report in [try ownedRun(.both, stale: true), try ownedRun(.both, cancel: true),
                           try ownedRun(.read, capability: false), try ownedRun(.write, periodic: true)] {
                #expect(report.failure != nil); #expect(report.cleanupSucceeded)
            }
        }
        // Explicit host gate: existing disposable, already mounted Debug product only.
        // This test neither mounts nor changes user/global configuration.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["RAMNEST_RUN_OWNED_1GB"] == "YES",
                       "Parent must opt into an owned current Debug NFS/FSKit mount."),
              arguments: [DebugBenchmarkMode.both, .read, .write])
        func `Owned mounted full decimal GB`(mode: DebugBenchmarkMode) throws { try fullGB(mode) }
        private func fullGB(_ mode: DebugBenchmarkMode) throws {
            let env = ProcessInfo.processInfo.environment
            guard env["RAMNEST_RUN_OWNED_1GB"] == "YES",
                  let path = env["RAMNEST_BENCHMARK_STORE"], let raw = env["RAMNEST_BENCHMARK_FOLDER"], let id = UUID(uuidString: raw) else {
                try Test.cancel("Parent must opt into an owned current Debug NFS/FSKit mount.")
            }
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let allowed = project.appendingPathComponent("artifacts/sha256-only").path + "/"
            #expect(path.hasPrefix(allowed)); guard path.hasPrefix(allowed) else { return }
            let engine = Engine(store: try Store(root: URL(fileURLWithPath: path)))
            let report = DebugBenchmarkWorker.run(engine: engine, id: id, mode: mode, cancellation: .init())
            try report.json().write(to: project.appendingPathComponent("artifacts/sha256-only/host-\(report.run).json"))
            #expect(report.failure == nil, Comment(rawValue: report.text))
            #expect(report.phases.map(\.bytes) == (mode == .both ? [1_000_000_000, 1_000_000_000] : [1_000_000_000]))
            #expect(report.phases.allSatisfy { $0.verified && $0.helper?.stopped == true })
            #expect(report.cleanupSucceeded)
        }
    }
}
#endif
