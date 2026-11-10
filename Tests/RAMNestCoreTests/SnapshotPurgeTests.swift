import Foundation
@testable import RAMNestCore
#if !RAMNEST_SNAPSHOT_PURGE_STANDALONE
import Testing
extension RAMNestTestSuite {
    struct SnapshotPurgeTests {
        @Test func `Clean snapshot folder removes idle and unlisted snapshots only`() throws { try SnapshotPurgeScenarios.idleAndUnlisted() }
    }
}
#endif

enum SnapshotPurgeScenarios {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NestError("TEST: " + message) }
    }
    static func idleAndUnlisted() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("artifacts/snapshot-purge/fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try Store(root: root.appendingPathComponent("support"))
        let engine = Engine(store: store, helper: URL(fileURLWithPath: "/usr/bin/false"))
        func folder(_ name: String) throws -> (Folder, URL) {
            let dir = root.appendingPathComponent(name); try Store.privateDirectory(dir)
            try Data("payload \(name)".utf8).write(to: dir.appendingPathComponent("file.txt"))
            var o = FolderOptions(); o.mountAtLaunch = false
            return (try engine.create(path: dir, name: name, capacity: 16 << 20, options: o), dir)
        }
        func revisions(_ id: UUID) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("volumes/\(id.uuidString)/revisions").path)) ?? [] }
        // A: idle with two snapshots -> cleaned
        let (a, aDir) = try folder("Alpha")
        let r1 = try Snapshot.capture(store: store, folder: a, source: aDir, previous: nil)
        let r2 = try Snapshot.capture(store: store, folder: a, source: aDir, previous: r1)
        var ja = Journal(); ja.revision = r2; ja.priorRevision = r1; try store.write(ja, for: a.id)
        // B: idle but with an unresolved error -> kept
        let (b, bDir) = try folder("Beta")
        let rb = try Snapshot.capture(store: store, folder: b, source: bDir, previous: nil)
        var jb = Journal(); jb.revision = rb; jb.lastError = "boom"; try store.write(jb, for: b.id)
        // C: removed from the app, snapshot retained -> record deleted
        let (c, cDir) = try folder("Gamma")
        let rc = try Snapshot.capture(store: store, folder: c, source: cDir, previous: nil)
        var jc = Journal(); jc.revision = rc; try store.write(jc, for: c.id)
        try engine.delete(c.id.uuidString)
        try check(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("volumes/\(c.id.uuidString)").path), "orphan exists before purge")
        try check(revisions(a.id).count == 2, "A has 2 revisions")

        let report = try engine.purgeIdleSnapshots()
        try check(report.removedSnapshots == 3, "3 snapshots removed (2 A + 1 C)")
        try check(report.cleanedFolders == ["Alpha"], "Alpha cleaned")
        try check(report.removedUnlistedRecords == 1, "1 unlisted record removed")
        try check(report.skipped.count == 1 && report.skipped[0].hasPrefix("Beta"), "Beta skipped")
        try check(revisions(a.id).isEmpty, "A revisions gone")
        let after = try store.journal(a.id)
        try check(after.revision == nil && after.priorRevision == nil && after.retiringRevisions == nil && after.cleanupWarning == nil, "A journal cleared")
        try check(revisions(b.id) == [rb], "B snapshot kept")
        try check(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("volumes/\(c.id.uuidString)").path), "orphan volume removed")
        try check(try String(contentsOf: aDir.appendingPathComponent("file.txt"), encoding: .utf8) == "payload Alpha", "A original intact")
        try check(try String(contentsOf: cDir.appendingPathComponent("file.txt"), encoding: .utf8) == "payload Gamma", "C original intact")
        try check(try engine.statuses().first { $0.id == a.id }?.canMount == true, "A still mountable")
        // Idempotent, and A can take a fresh first snapshot again.
        let again = try engine.purgeIdleSnapshots()
        try check(again.removedSnapshots == 0 && again.removedUnlistedRecords == 0, "second run no-op")
        _ = try Snapshot.capture(store: store, folder: a, source: aDir, previous: nil)
    }
}
