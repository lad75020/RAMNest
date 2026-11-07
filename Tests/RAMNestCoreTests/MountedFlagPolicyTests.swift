import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_MOUNTED_FLAG_POLICY_STANDALONE
import XCTest
final class MountedFlagPolicyTests: XCTestCase {
    func testStrictDefaults() throws { try MountedFlagPolicyScenarios.strictDefaults() }
    func testDirectionalMask() throws { try MountedFlagPolicyScenarios.directionalMask() }
    func testJournalPolicyAndGuards() throws { try MountedFlagPolicyScenarios.journalPolicy() }
    func testSnapshotFlagsStayExact() throws { try MountedFlagPolicyScenarios.snapshots() }
}
#endif

enum MountedFlagPolicyScenarios {
    static let hints = UInt32(UF_HIDDEN | UF_NODUMP)
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NestError("TEST: " + message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NestError("TEST: expected rejection")
    }
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("artifacts/manifest-mismatch/policy/fixtures-\(UUID().uuidString)")
    }
    static func strictDefaults() throws {
        for flags in [UInt32(UF_HIDDEN), UInt32(UF_NODUMP), hints] {
            var expected = PopulationReadinessScenarios.expected
            expected.entries[0].flags = flags
            var actual = expected; actual.entries[0].flags = 0
            try rejects {
                try PopulationReadiness.verify(expected: expected, read: { actual }, sleep: { _ in },
                    uptime: { 0 }, maximumAttempts: 1)
            }
            try check(actual != expected, "raw manifest equality stays exact")
        }
    }
    static func directionalMask() throws {
        // Exercise every bit without applying security flags to fixture files.
        for bitIndex in 0..<32 {
            let bit = UInt32(1) << bitIndex
            var expected = PopulationReadinessScenarios.expected
            expected.entries[0].flags = hints | bit
            var actual = expected; actual.entries[0].flags = 0
            let verify = {
                try PopulationReadiness.verify(expected: expected, read: { actual }, sleep: { _ in },
                    uptime: { 0 }, maximumAttempts: 1, missingFlagsMask: hints)
            }
            if bit & hints != 0 { try verify() } else { try rejects(verify) }
            actual.entries[0].flags = expected.entries[0].flags | bit
            expected.entries[0].flags = hints & ~bit
            try rejects(verify) // Added bits are always fatal, including hint bits.
        }
        var expected = PopulationReadinessScenarios.expected
        expected.entries[0].flags = UInt32(UF_IMMUTABLE)
        var actual = expected; actual.entries[0].flags = 0
        try rejects {
            try PopulationReadiness.verify(expected: expected, read: { actual }, sleep: { _ in },
                uptime: { 0 }, maximumAttempts: 1, missingFlagsMask: UInt32.max)
        }
    }
    static func journalPolicy() throws {
        let parent = root; try Store.privateDirectory(parent)
        var serial = 0
        func run(backend: Configuration.Backend?, current: Configuration.Backend, flags: UInt32,
                 actualFlags: UInt32, mutate: ((inout Manifest) -> Void)? = nil,
                 originalChanged: Bool = false, sourceChanged: Bool = false, accepted: Bool) throws {
            serial += 1
            let f = try LatestSnapshotScenarios.Fixture(parent, "case-\(serial)")
            let original = URL(fileURLWithPath: try f.store.journal(f.folder.id).evacuation!)
            try check(chflags(original.appendingPathComponent("payload").path, flags) == 0, "set owned flags")
            let expected = try Snapshot.manifest(original)
            var actual = expected; actual.entries[0].flags = actualFlags; mutate?(&actual)
            if originalChanged { try check(chflags(original.appendingPathComponent("payload").path, 0) == 0, "change holding hint flags") }
            if sourceChanged { try Data("inert".utf8).write(to: f.selected.appendingPathComponent("new")) }
            var config = try f.store.load(); config.backend = current; try f.store.save(config)
            var j = try f.store.journal(f.folder.id); j.backend = backend; j.phase = .mounting; j.populationVerified = false
            try f.store.write(j, for: f.folder.id)
            let clock = PopulationReadinessScenarios.Clock()
            var boundary = f.helper.boundary
            boundary.populationRead = { _ in
                try check(try !f.store.journal(f.folder.id).populationVerified && f.helper.commands.isEmpty, "guarded before comparison")
                return actual
            }
            boundary.sleep = clock.sleep; boundary.uptime = { clock.time }
            let request = boundary.request
            boundary.request = { socket, command in
                let durable = try f.store.journal(f.folder.id)
                try check(command == "activate" && durable.populationVerified && durable.phase == .mounted,
                          "durable verification precedes activation")
                return try request(socket, command)
            }
            let engine = Engine(store: f.store, session: boundary)
            let operation = {
                try f.store.locked {
                    try engine.verifyAndActivatePopulation(f.folder, journal: &j, expected: expected,
                        source: DirectoryHandle.open(f.selected), original: original)
                }
            }
            if accepted {
                try operation()
                try check(f.helper.commands == ["activate"], "accepted hints activate once")
            } else {
                try rejects(operation)
                let durable = try f.store.journal(f.folder.id)
                try check(f.helper.commands.isEmpty && !durable.populationVerified && durable.phase == .recoveryRequired,
                          "mismatch keeps durable guard")
                if mutate != nil {
                    let diagnostic = durable.lastError ?? ""
                    try check(diagnostic.contains("field") || diagnostic.contains("xattr"), "field-specific readiness diagnostic")
                    try check(!diagnostic.contains("PRIVATE-DIGEST"), "diagnostic excludes digests")
                }
            }
        }
        for backend in [Configuration.Backend.fskit, .nfs] {
            for flags in [UInt32(UF_HIDDEN), UInt32(UF_NODUMP), hints] {
                try run(backend: backend, current: .smb, flags: flags, actualFlags: 0, accepted: true)
            }
            try run(backend: backend, current: .smb, flags: hints, actualFlags: UInt32(UF_HIDDEN), accepted: true)
            try run(backend: backend, current: .smb, flags: hints, actualFlags: hints, accepted: true)
            for bit in [UInt32(UF_IMMUTABLE), UInt32(UF_APPEND), UInt32(SF_IMMUTABLE), UInt32(SF_APPEND), UInt32(0x80000000)] {
                try run(backend: backend, current: .smb, flags: hints, actualFlags: bit, accepted: false)
            }
            try run(backend: backend, current: .smb, flags: 0, actualFlags: UInt32(UF_HIDDEN), accepted: false)
            try run(backend: backend, current: .smb, flags: 0, actualFlags: UInt32(UF_NODUMP), accepted: false)
        }
        for backend in [Configuration.Backend.smb, nil] {
            for current in [Configuration.Backend.nfs, .fskit] {
                try run(backend: backend, current: current, flags: hints, actualFlags: 0, accepted: false)
            }
        }
        let changes: [(inout Manifest) -> Void] = [
            { $0.entries[0].path = "other" }, { $0.entries.removeAll() }, { $0.entries.append($0.entries[0]) },
            { $0.entries[0].kind = "directory" }, { $0.entries[0].size += 1 }, { $0.entries[0].mode ^= 1 },
            { $0.entries[0].mtimeSeconds += 1 }, { $0.entries[0].mtimeNanos += 1 },
            { $0.entries[0].checksum = "PRIVATE-DIGEST" }, { $0.entries[0].attributes = ["fixture": "PRIVATE-DIGEST"] },
            { $0.entries[0].hardlink = "other" }, { $0.entries[0].attributeBytes += 1 }
        ]
        for change in changes {
            try run(backend: .fskit, current: .smb, flags: hints, actualFlags: 0, mutate: change, accepted: false)
        }
        try run(backend: .nfs, current: .smb, flags: hints, actualFlags: 0, originalChanged: true, accepted: false)
        try run(backend: .fskit, current: .smb, flags: hints, actualFlags: 0, sourceChanged: true, accepted: false)
    }
    static func snapshots() throws {
        let parent = root; try Store.privateDirectory(parent)
        let f = try LatestSnapshotScenarios.Fixture(parent, "snapshot")
        let source = f.helper.live
        try check(chflags(source.appendingPathComponent("payload").path, hints) == 0, "set snapshot fixture hints")
        let raw = try Snapshot.manifest(source)
        let revision = try f.store.locked { try Snapshot.capture(store: f.store, folder: f.folder, source: source, previous: nil) }
        let (data, saved) = try Snapshot.verified(store: f.store, id: f.folder.id, revision: revision)
        try check(saved == raw && saved.entries[0].flags == hints, "capture and verified preserve raw hint flags")
        let restored = f.root.appendingPathComponent("restored")
        try Snapshot.copyTree(from: data, to: restored, manifest: saved,sourceContext:.managedRevision)
        try check(try Snapshot.manifest(restored) == raw, "restoration copy preserves raw metadata")
        try check(chflags(data.appendingPathComponent("payload").path, 0) == 0, "remove saved hint flags")
        try rejects { _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: revision) }
    }
}
