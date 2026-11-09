import Foundation
import Darwin
import Testing
@testable import RAMNestCore
extension RAMNestTestSuite {
    struct SiblingInventoryTests {
        @Test func `Nested hardlinks match snapshot manifest`() throws { try InventoryScenarios.run() }
    }
    struct LinkedIndependentSafetyTests {
        private func fixture(_ label: String, temporary: Bool = false) throws -> LinkedTransactionDataFixture {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/linked-independent")
            try Store.privateDirectory(root); return try LinkedTransactionDataFixture(root, label, temporary: temporary)
        }
        private func checkpointRestore(_ f: LinkedTransactionDataFixture) throws {
            try f.discardWorkingCopy(); f.j.phase = .pendingRestore; f.j.restoreRevision = f.j.revision
            try f.store.write(f.j, for: f.folder.id); try f.engine.recover(f.folder.id.uuidString)
        }
        @Test func `Public source modes keep a private holding and restore exactly`() throws {
            let f = try fixture("public-root")
            #expect(chmod(f.selected.path, 0o755) == 0)
            try f.prepare(); _ = try f.evacuate(); try f.publish()
            let backup = URL(fileURLWithPath: f.j.evacuation!)
            var info = stat(); #expect(lstat(backup.path, &info) == 0 && info.st_mode & 0o7777 == 0o700)
            try checkpointRestore(f)
            #expect(!FileManager.default.fileExists(atPath: backup.path))
            #expect(lstat(f.selected.path, &info) == 0 && info.st_mode & 0o7777 == 0o755)
            #expect(try f.store.journal(f.folder.id).cleanupWarning == nil)
        }
        @Test func `Mode alone cannot authorize a runtime root with a permissive ACL`() throws {
            let f = try fixture("root-acl"); try f.prepare()
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/chmod")
            p.arguments = ["+a", "everyone allow add_file,add_subdirectory,delete_child", f.mountRoot.path]
            try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 0)
            #expect(throws: (any Error).self) { try f.evacuate() }
            try Paths.checkedIdentity(f.folder)
            #expect(try Snapshot.manifest(f.selected) == f.expected)
        }
        @Test func `Concurrent publication accepts only its durable restored identity`() throws {
            let f = try fixture("concurrent-identity"); try f.prepare(); _ = try f.evacuate(); try f.publish()
            var boundary = EngineSession(); boundary.linkedMountRoot = f.mountRoot
            var intervened = false
            boundary.beforeVolumeLock = { _ in
                #expect(!intervened); intervened = true
                try self.checkpointRestore(f)
            }
            try Engine(store: f.store, session: boundary).finalize(f.folder.id.uuidString)
            #expect(intervened)
            #expect(try f.store.journal(f.folder.id).phase == .idle)
            try Paths.checkedIdentity(f.engine.folder(f.folder.id.uuidString))
        }
        @Test func `Unbound configuration inode change blocks transaction`() throws {
            let f = try fixture("unbound"); try f.prepare()
            var boundary = EngineSession(); boundary.linkedMountRoot = f.mountRoot
            boundary.beforeVolumeLock = { _ in
                var c = try f.store.load(); c.folders[0].inode += 1; try f.store.save(c)
            }
            #expect(throws: (any Error).self) { try Engine(store: f.store, session: boundary).finalize(f.folder.id.uuidString) }
            #expect(try Data(contentsOf: f.selected.appendingPathComponent("payload")) == Data("original".utf8))
        }
        @Test func `Backup wrapper ACL does not waive contents or block verified original restoration`() throws {
            let f = try fixture("backup-acl", temporary: true); try f.prepare(); _ = try f.evacuate(); try f.publish()
            let backup = URL(fileURLWithPath: f.j.evacuation!)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/chmod")
            p.arguments = ["+a", "everyone allow add_file,add_subdirectory,delete_child", backup.path]
            try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 0)
            try f.discardWorkingCopy(); try f.engine.recover(f.folder.id.uuidString)
            #expect(try Data(contentsOf: f.selected.appendingPathComponent("payload")) == Data("original".utf8))
            #expect(try f.store.journal(f.folder.id).phase == .idle)
            #expect(!FileManager.default.fileExists(atPath: backup.path))
        }
    }
}
enum InventoryScenarios {
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/holding-cleanup/hardlinks-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let nested = root.appendingPathComponent("alpha")
        try Store.privateDirectory(nested)
        let payload = nested.appendingPathComponent("payload")
        try Data("Generated hardlink canonicalization fixture".utf8).write(to: payload)
        try FileManager.default.linkItem(at: payload, to: root.appendingPathComponent("alpha-link"))
        let expected = try Snapshot.manifest(root)
        let inventory = try DirectoryHandle.open(root).cleanupInventory()
        guard inventory.manifest.contentsMatchExpected(expected), inventory.manifest.publicRoot == nil, !inventory.manifest.matchesExpected(expected) else { throw NestError("Cleanup hardlink canonicalization differs from snapshot manifest.") }
        print("PASS standalone sibling inventory: hierarchical hardlink anchors")
    }
}

#if RAMNEST_INVENTORY_STANDALONE
@main struct InventoryRunner { static func main() throws { try InventoryScenarios.run() } }
#endif
