import Foundation
import Darwin
#if !RAMNEST_INVENTORY_STANDALONE
import XCTest
#endif
@testable import RAMNestCore

#if !RAMNEST_INVENTORY_STANDALONE
final class SiblingInventoryTests: XCTestCase {
    func testNestedHardlinksMatchSnapshotManifest() throws { try InventoryScenarios.run() }
}

final class FSKitIndependentSafetyTests: XCTestCase {
    func testNonPrivateSourceRootKeepsPrivateBackupAndCleansAfterRestore() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("artifacts/debug-io-instrumentation/independent-symlink-tests-" + UUID().uuidString)
        try Store.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        try Store.privateDirectory(selected)
        try Data("original".utf8).write(to: selected.appendingPathComponent("payload"))
        guard chmod(selected.path, 0o755) == 0 else { throw NestError("Cannot set owned source fixture mode") }
        let identity = try DirectoryHandle.open(selected).identity()
        let folder = Folder(name: "Independent root policy", path: selected.path, capacity: 16 << 20,
                            device: identity.device, inode: identity.inode)
        let store = try Store(root: root.appendingPathComponent("store"))
        var config = Configuration(); config.backend = .fskit; config.folders = [folder]; try store.save(config)
        let revision = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil)
        let expected = try Snapshot.verified(store: store, id: folder.id, revision: revision).1
        let mountRoot = root.appendingPathComponent("RAMNest-Mounts-\(getuid())")
        store.fsKitFixtureRoot = mountRoot
        var journal = Journal(); journal.backend = .fskit; journal.session = UUID(); journal.phase = .preparing
        journal.initialRevision = revision; journal.revision = revision; journal.socket = "independent-owned-session"
        journal.fsKitLink = try FSKitLinks.reserve(folder, session: journal.session!, root: mountRoot, filesystemCheck: { _ in })
        let physical = URL(fileURLWithPath: journal.fsKitLink!.mountPath)
        var mounted = true
        var boundary = EngineSession(); boundary.fsKitMountRoot = mountRoot
        boundary.mountedIdentity = { _, _ in mounted }
        boundary.populationRead = { _ in expected }
        boundary.status = { _, id in HelperStatus(id: id, pid: getpid(), mounted: mounted,
                                                used: 0, capacity: folder.capacity, active: true) }
        boundary.request = { _, command in
            let parts = command.components(separatedBy: "\t")
            if parts[0] == "export" || parts[0] == "quiesce" {
                try Snapshot.copyTree(from: physical, to: URL(fileURLWithPath: parts[1]),
                                      manifest: Snapshot.manifest(physical))
            }
            return []
        }
        boundary.unmount = { path in
            guard path == physical.path else { throw NestError("Wrong physical unmount target") }
            try FileManager.default.removeItem(at: physical.appendingPathComponent("payload")); mounted = false
        }
        let engine = Engine(store: store, session: boundary)
        try store.write(journal, for: folder.id)
        let (sourceHandle, originalData) = try engine.evacuateOriginal(folder, journal: &journal, expected: expected)
        let backup = URL(fileURLWithPath: journal.evacuation!)
        var backupStat = stat(); XCTAssertEqual(lstat(backup.path, &backupStat), 0)
        XCTAssertEqual(backupStat.st_mode & 0o7777, 0o700, "The holding wrapper must stay private without chmod-ing the original")
        try Data("original".utf8).write(to: physical.appendingPathComponent("payload"))
        try Snapshot.restorePublicRootMetadata(from: DirectoryHandle.open(originalData),
                                              to: DirectoryHandle.open(physical), manifest: expected)
        journal.mountedDevice = 999; journal.phase = .mounting; try store.write(journal, for: folder.id)
        try engine.verifyAndActivatePopulation(folder, journal: &journal, expected: expected,
                                              source: sourceHandle, original: originalData)
        try engine.unmount(folder.id.uuidString, ignoreBusy: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "Ordinary verified originals must not leak because root mode is 0755")
        XCTAssertNil(try store.journal(folder.id).cleanupWarning)
        var restored = stat(); XCTAssertEqual(lstat(selected.path, &restored), 0)
        XCTAssertEqual(restored.st_mode & 0o7777, 0o755)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("payload")), Data("original".utf8))
    }

    func testPrivateModeMountRootWithPermissiveACLIsNotAdopted() throws {
        let fixture = try FSKitSymlinkLifecycleTests.Fixture()
        defer { fixture.dispose() }
        try FSKitLinks.releaseMountpoint(fixture.journal.fsKitLink!)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow add_file,add_subdirectory,delete_child", fixture.mountRoot.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NestError("Owned ACL fixture could not be established") }
        var info = stat(); XCTAssertEqual(lstat(fixture.mountRoot.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o700)
        XCTAssertThrowsError(try FSKitLinks.reserve(fixture.folder, session: UUID(), root: fixture.mountRoot,
                                                  filesystemCheck: { _ in }), "Mode 0700 alone is not private authority when an ACL grants other writers")
        try Paths.checkedIdentity(fixture.folder)
    }

    func testConcurrentHelperFinalizationAcceptsOnlyDurableRestoredIdentity() throws {
        let fixture = try FSKitSymlinkLifecycleTests.Fixture()
        defer { fixture.dispose() }
        try fixture.activate()
        var boundary = EngineSession(); boundary.fsKitMountRoot = fixture.mountRoot
        var intervened = false
        boundary.beforeVolumeLock = { id in
            XCTAssertEqual(id, fixture.folder.id)
            guard !intervened else { throw NestError("Unexpected repeated lock hook") }
            intervened = true
            // Model the real helper completing internal-finalize after the CLI
            // captured its folder but before that CLI acquires the volume lock.
            try fixture.engine.unmount(id.uuidString, ignoreBusy: true)
        }
        let coordinator = Engine(store: fixture.store, session: boundary)
        XCTAssertNoThrow(try coordinator.finalize(fixture.folder.id.uuidString),
                         "The journal-authorized old-to-restored inode transition is not an unrelated configuration replacement")
        XCTAssertTrue(intervened)
        try Paths.checkedIdentity(fixture.engine.folder(fixture.folder.id.uuidString))
        XCTAssertEqual(try fixture.store.journal(fixture.folder.id).phase, .idle)
    }

    func testUnboundConfigurationInodeChangeStillBlocksTransaction() throws {
        let fixture = try FSKitSymlinkLifecycleTests.Fixture()
        defer { fixture.dispose() }
        var boundary = EngineSession(); boundary.fsKitMountRoot = fixture.mountRoot
        boundary.beforeVolumeLock = { _ in
            var config = try fixture.store.load()
            config.folders[0].inode += 1
            try fixture.store.save(config)
        }
        XCTAssertThrowsError(try Engine(store: fixture.store, session: boundary).finalize(fixture.folder.id.uuidString))
        XCTAssertEqual(try fixture.value(), "original")
    }

    func testBackupWrapperACLDoesNotBlockVerifiedRestore() throws {
        let fixture = try FSKitSymlinkLifecycleTests.Fixture()
        defer { fixture.dispose() }
        try fixture.activate()
        let backup = URL(fileURLWithPath: fixture.journal.evacuation!)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow add_file,add_subdirectory,delete_child", backup.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NestError("Owned backup ACL fixture could not be established") }
        XCTAssertNoThrow(try fixture.engine.unmount(fixture.folder.id.uuidString, ignoreBusy: true),
                         "The owner waived backup ACL fidelity; live mount-root authority and content verification remain strict")
        XCTAssertEqual(try fixture.value(), "original")
        XCTAssertEqual(try fixture.store.journal(fixture.folder.id).phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testUnmountSerializesFinalizationWhenHelperAlreadyPublishedIdle() throws {
        let fixture = try FSKitSymlinkLifecycleTests.Fixture()
        defer { fixture.dispose() }
        try fixture.activate()
        let physical = URL(fileURLWithPath: fixture.journal.fsKitLink!.mountPath)
        var transactions = 0
        var boundary = EngineSession(); boundary.fsKitMountRoot = fixture.mountRoot
        boundary.beforeVolumeLock = { _ in transactions += 1 }
        boundary.mountedIdentity = { _, _ in fixture.mounted }
        boundary.status = { _, id in HelperStatus(id: id, pid: getpid(), mounted: fixture.mounted,
                                                used: 0, capacity: fixture.folder.capacity, active: fixture.active) }
        boundary.request = { _, command in
            let fields = command.components(separatedBy: "\t")
            if fields[0] == "export" || fields[0] == "quiesce" {
                try Snapshot.copyTree(from: physical, to: URL(fileURLWithPath: fields[1]),
                                      manifest: Snapshot.manifest(physical))
            }
            return []
        }
        boundary.unmount = { path in
            guard path == physical.path else { throw NestError("Wrong physical unmount target") }
            try FileManager.default.removeItem(at: physical.appendingPathComponent("payload"))
            fixture.mounted = false
            // The helper may publish idle before it releases the volume lock
            // after cleanup. The caller must still cross that lock boundary.
            try fixture.engine.finalize(fixture.folder.id.uuidString)
        }
        try Engine(store: fixture.store, session: boundary).unmount(fixture.folder.id.uuidString, ignoreBusy: true)
        XCTAssertEqual(transactions, 2, "Do not return from an unlocked idle observation before serialized finalization")
        XCTAssertEqual(try fixture.value(), "original")
    }
}
#endif
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
