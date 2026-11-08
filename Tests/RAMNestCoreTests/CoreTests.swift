import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_STANDALONE
import XCTest

// Location tests inject every path. They never read or write real AppSupport.
final class SnapshotStorageLocationTests: XCTestCase {
    private func fixture() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("artifacts/snapshot-storage-location/fixtures-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        return root
    }
    func testAbsentAndExplicitLocation() throws {
        let root = try fixture()
        let locations = StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap"))
        XCTAssertEqual(try locations.resolve().root, locations.bootstrapRoot)
        let explicit = root.appendingPathComponent("explicit")
        let isolated = try locations.open(explicitRoot: explicit)
        XCTAssertEqual(isolated.root, explicit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.bootstrapRoot.path))
        let normal = try locations.open()
        XCTAssertEqual(normal.root, locations.bootstrapRoot)
    }
    func testCommittedSelectionReopensAndRejectsStaleStore() throws {
        let root = try fixture()
        let locations = StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap"))
        let old = try locations.open()
        let destination = try Store(root: root.appendingPathComponent("destination"))
        var config = Configuration(); config.menuBarMode = true; config.backend = .fskit
        try destination.save(config)
        let selection = try locations.selection(for: destination.root)
        try Store.atomicJSON(selection, locations.selectionURL)
        let reopened = try locations.open()
        XCTAssertEqual(reopened.root.path, destination.root.path)
        XCTAssertEqual(try reopened.load().backend, .fskit)
        XCTAssertTrue(try reopened.load().menuBarMode)
        XCTAssertThrowsError(try old.locked { try old.save(Configuration()) })
        XCTAssertThrowsError(try old.load())
        XCTAssertThrowsError(try old.volume(UUID()))
        XCTAssertEqual(try locations.open(explicitRoot: old.root).root, old.root)
    }
    func testMalformedSelectionsFailClosed() throws {
        let root = try fixture()
        let locations = StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap"))
        _ = try locations.open()
        let destination = try Store(root: root.appendingPathComponent("destination"))
        let selection = try locations.selection(for: destination.root)
        let encoder = JSONEncoder()
        let valid = try encoder.encode(selection)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let mutations: [([String: Any]) -> [String: Any]] = [
            { var v = $0; v["version"] = 99; return v },
            { var v = $0; v["stage"] = "copying"; return v },
            { var v = $0; v["root"] = NSNull(); return v },
            { var v = $0; v["inode"] = nil; return v },
            { var v = $0; v["unexpected"] = true; return v }
        ]
        for mutation in mutations {
            try Store.atomicData(JSONSerialization.data(withJSONObject: mutation(object)), locations.selectionURL)
            XCTAssertThrowsError(try locations.open())
        }
        for bytes in [Data("null".utf8), Data("{".utf8), Data("{}".utf8), Data()] {
            try Store.atomicData(bytes, locations.selectionURL)
            XCTAssertThrowsError(try locations.open())
            // An explicit test/CLI store must not consult or repair globals.
            let isolated = root.appendingPathComponent("isolated")
            XCTAssertEqual(try locations.open(explicitRoot: isolated).root, isolated)
            XCTAssertEqual(try Data(contentsOf: locations.selectionURL), bytes)
        }
        try FileManager.default.removeItem(at: locations.selectionURL)
        try FileManager.default.createSymbolicLink(at: locations.selectionURL, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try locations.open())
    }
    func testMissingReplacedAndSymlinkDestinationsNeverCreateStore() throws {
        let root = try fixture()
        let locations = StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap"))
        _ = try locations.open()
        let destination = try Store(root: root.appendingPathComponent("destination"))
        let selection = try locations.selection(for: destination.root)
        try Store.atomicJSON(selection, locations.selectionURL)
        let retired = root.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: destination.root, to: retired)
        XCTAssertThrowsError(try locations.open())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.root.path))
        _ = try Store(root: destination.root)
        XCTAssertThrowsError(try locations.open())
        try FileManager.default.removeItem(at: destination.root)
        try FileManager.default.createSymbolicLink(at: destination.root, withDestinationURL: retired)
        XCTAssertThrowsError(try locations.open())
    }
    func testUnsafeAndDuplicateSelectionFilesFailClosed() throws {
        let root = try fixture()
        let locations = StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap"))
        _ = try locations.open()
        let destination = try Store(root: root.appendingPathComponent("destination"))
        let selection = try locations.selection(for: destination.root)
        try Store.atomicJSON(selection, locations.selectionURL)
        let bytes = try Data(contentsOf: locations.selectionURL)
        let duplicate = "{\"version\":1," + String(decoding: bytes.dropFirst(), as: UTF8.self)
        try Store.atomicData(Data(duplicate.utf8), locations.selectionURL)
        XCTAssertThrowsError(try locations.open())
        try Store.atomicJSON(selection, locations.selectionURL)
        XCTAssertEqual(chmod(locations.selectionURL.path, 0o644), 0)
        XCTAssertThrowsError(try locations.open())
        XCTAssertEqual(chmod(locations.selectionURL.path, 0o600), 0)
        let alias = root.appendingPathComponent("selection-hardlink")
        XCTAssertEqual(link(locations.selectionURL.path, alias.path), 0)
        XCTAssertThrowsError(try locations.open())
    }
    private func moveFixture() throws -> (URL, SnapshotStorageManager, Store, Folder, String) {
        let root = try fixture(), locations = StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap"))
        let manager = SnapshotStorageManager(location: locations), store = try manager.open()
        let selected = root.appendingPathComponent("selected"); try Store.privateDirectory(selected)
        try Data("snapshot payload αβ".utf8).write(to: selected.appendingPathComponent("payload"))
        var options = FolderOptions(); options.mountAtLaunch = false; options.comparison = .checksum
        let folder = try Engine(store: store).create(path: selected, name: "Relocation fixture", capacity: 16 << 20, options: options)
        let revision = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil)
        var journal = Journal(); journal.revision = revision; try store.write(journal, for: folder.id)
        var config = try store.load(); config.backend = .fskit; config.menuBarMode = true; try store.save(config)
        let trash = store.root.appendingPathComponent("opaque/.Trashes")
        try Store.privateDirectory(trash)
        let raw = trash.appendingPathComponent("raw")
        try Data("opaque retained trash bytes".utf8).write(to: raw)
        XCTAssertEqual(chmod(raw.path, 0o640), 0)
        let attribute = Data([0, 1, 2, 255])
        XCTAssertEqual(attribute.withUnsafeBytes { setxattr(raw.path, "user.ramnest.storage-location", $0.baseAddress, $0.count, 0, 0) }, 0)
        try FileManager.default.createSymbolicLink(atPath: store.root.appendingPathComponent("opaque/link").path, withDestinationPath: "../outside-is-never-followed")
        return (root, manager, store, folder, revision)
    }
    func testOpaqueMovePreservesStoreAndRemovesOldPayload() throws {
        let (root, manager, store, folder, revision) = try moveFixture()
        // Optional owned host fixture seam, not a production preference override.
        let crossPath = ProcessInfo.processInfo.environment["RAMNEST_SNAPSHOT_CROSS_DISK_PARENT"]
        let base = crossPath.map { URL(fileURLWithPath: $0) } ?? root
        if crossPath != nil {
            try Paths.rejectSymlinks(base.path, allowMissingLast: false)
            let handle = try DirectoryHandle.open(base)
            try handle.requireOwnedDirectory(device: handle.identity().device, privateMode: true)
        }
        let parent = base.appendingPathComponent("chosen-" + UUID().uuidString); try Store.privateDirectory(parent)
        let config = try Data(contentsOf: store.root.appendingPathComponent("configuration.json"))
        let journal = try Data(contentsOf: store.volume(folder.id).appendingPathComponent("journal.json"))
        let parentMode = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber
        let result = try manager.move(store: store, toParent: parent)
        XCTAssertNil(result.pending)
        let reopened = try manager.open()
        XCTAssertEqual(reopened.root.path, parent.appendingPathComponent("RAMNest Snapshots").path)
        if crossPath != nil { XCTAssertNotEqual(try DirectoryHandle.open(store.root).identity().device, try DirectoryHandle.open(reopened.root).identity().device) }
        XCTAssertEqual(try reopened.load().folders, [folder])
        XCTAssertEqual(try Data(contentsOf: reopened.root.appendingPathComponent("configuration.json")), config)
        XCTAssertEqual(try Data(contentsOf: reopened.volume(folder.id).appendingPathComponent("journal.json")), journal)
        XCTAssertEqual(try reopened.journal(folder.id).revision, revision)
        _ = try Snapshot.verified(store: reopened, id: folder.id, revision: revision)
        XCTAssertEqual(try String(contentsOf: reopened.root.appendingPathComponent("opaque/.Trashes/raw"), encoding: .utf8), "opaque retained trash bytes")
        let raw = reopened.root.appendingPathComponent("opaque/.Trashes/raw")
        var rawStat = stat(); XCTAssertEqual(lstat(raw.path, &rawStat), 0); XCTAssertEqual(rawStat.st_mode & 0o7777, 0o640)
        var copiedAttribute = Data(count: 4)
        XCTAssertEqual(copiedAttribute.withUnsafeMutableBytes { getxattr(raw.path, "user.ramnest.storage-location", $0.baseAddress, $0.count, 0, 0) }, 4)
        XCTAssertEqual(copiedAttribute, Data([0, 1, 2, 255]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: reopened.root.appendingPathComponent("opaque/link").path), "../outside-is-never-followed")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber, parentMode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("volumes").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("configuration.json").path))
        XCTAssertTrue(Set(try DirectoryHandle.open(store.root).names()).isSubset(of: ["repository.lock", "storage-location.lock", "storage-location.json", ".ramnest-retired.json"]))
        XCTAssertThrowsError(try store.save(Configuration()))
        XCTAssertThrowsError(try store.volume(UUID()))
        XCTAssertThrowsError(try Store(root: store.root))
        XCTAssertEqual(try StoreLocation(bootstrapRoot: manager.location.bootstrapRoot).open().root.path, reopened.root.path)
        XCTAssertNil(try manager.move(store: reopened, toParent: reopened.root).pending)
        XCTAssertNil(try manager.move(store: reopened, toParent: parent).pending)
        let second = root.appendingPathComponent("second"); try Store.privateDirectory(second)
        XCTAssertNil(try manager.move(store: reopened, toParent: second).pending)
        XCTAssertEqual(try manager.open().load().folders.first?.id, folder.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.root.appendingPathComponent("volumes").path))
        if crossPath != nil {
            try FileManager.default.removeItem(at: parent)
            print("PASS owned external-to-internal-to-external opaque relocation and cleanup")
        }
    }
    func testCompletedVerifiedStartupCanMoveButUnretiredGuardCannot() throws {
        let (root, manager, store, folder, revision) = try moveFixture()
        let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
        var journal = Journal(); journal.revision = revision; journal.session = UUID()
        journal.backend = .nfs; journal.startupProtocol = GuardedPopulationStartup.version
        try store.write(journal, for: folder.id)
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        // A normally activated and cleanly restored session retains startup
        // provenance; startupRetired is the aborted-startup receipt, not a
        // requirement for every completed session. Helper absence stays checked.
        journal.populationVerified = true
        try store.write(journal, for: folder.id)
        XCTAssertNil(try manager.move(store: store, toParent: parent).pending)
        XCTAssertEqual(try manager.open().journal(folder.id).revision, revision)
    }
    func testRelocationRejectsBusyLifecycleAndVolumeLock() throws {
        let (root, manager, store, folder, revision) = try moveFixture()
        let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
        for phase in [Phase.mounted, .pendingRestore, .preparing, .restoring] {
            var journal = Journal(); journal.phase = phase; journal.revision = revision; try store.write(journal, for: folder.id)
            XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        }
        var journal = Journal(); journal.revision = revision; journal.restoreStage = root.appendingPathComponent("owned-pending-stage").path
        try store.write(journal, for: folder.id)
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        journal.restoreStage = nil; journal.socket = root.appendingPathComponent("fake-helper-socket").path
        try Data().write(to: URL(fileURLWithPath: journal.socket!)); try store.write(journal, for: folder.id)
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        journal.socket = nil; try store.write(journal, for: folder.id)
        try store.volumeLocked(folder.id) { XCTAssertThrowsError(try manager.move(store: store, toParent: parent)) }
        XCTAssertNil(try manager.state().pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("RAMNest Snapshots").path))
    }
    func testRelocationRejectsOverlapUnknownAndSymlinkTargets() throws {
        let (root, manager, store, folder, _) = try moveFixture()
        let inside = store.root.appendingPathComponent("inside"); try Store.privateDirectory(inside)
        XCTAssertThrowsError(try manager.move(store: store, toParent: inside))
        XCTAssertThrowsError(try manager.move(store: store, toParent: URL(fileURLWithPath: folder.path)))
        let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
        let unrelated = parent.appendingPathComponent("RAMNest Snapshots"); try Store.privateDirectory(unrelated)
        let sentinel = unrelated.appendingPathComponent("unrelated"); try Data("leave me".utf8).write(to: sentinel)
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "leave me")
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        XCTAssertThrowsError(try manager.move(store: store, toParent: alias))
        let unknown = store.root.appendingPathComponent("volumes/unknown"); try Store.privateDirectory(unknown)
        let other = root.appendingPathComponent("other"); try Store.privateDirectory(other)
        XCTAssertThrowsError(try manager.move(store: store, toParent: other))
        XCTAssertNil(try manager.state().pending)
    }
    func testRelocationFaultsResumeAndCleanupIsVisible() throws {
        for stage in ["copy", "copy-file", "hash", "fsync", "verified", "fenced", "publication", "committed", "cleanup", "cleanup-entry"] {
            let (root, manager, store, folder, revision) = try moveFixture()
            let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
            manager.fault = { if $0 == stage { throw NestError("injected " + stage) } }
            XCTAssertThrowsError(try manager.move(store: store, toParent: parent), stage)
            XCTAssertNotNil(try manager.state().pending, stage)
            XCTAssertThrowsError(try manager.open(), stage)
            manager.fault = nil
            XCTAssertNil(try manager.retry().pending, stage)
            XCTAssertNil(try manager.retry().pending, stage)
            let reopened = try manager.open()
            XCTAssertEqual(try reopened.journal(folder.id).revision, revision, stage)
            _ = try Snapshot.verified(store: reopened, id: folder.id, revision: revision)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("volumes").path), stage)
        }
    }
    func testRecordedCopyCancellationCanRetryAndMissingStorageFailsClosed() throws {
        let (root, manager, store, _, _) = try moveFixture()
        let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
        let token = StorageMoveCancellation()
        manager.fault = { if $0 == "copy-file" { token.cancel() } }
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent, cancellation: token))
        manager.fault = nil
        XCTAssertNil(try manager.retry().pending)
        let destination = try manager.open().root
        let disconnected = root.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: parent, to: disconnected)
        XCTAssertThrowsError(try manager.open())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("volumes").path))
    }
    func testPendingDisconnectAndCorruptReceiptRetainBothStores() throws {
        let (root, manager, store, _, _) = try moveFixture()
        let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
        manager.fault = { if $0 == "fenced" { throw NestError("interrupted") } }
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        manager.fault = nil
        let disconnected = root.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: parent, to: disconnected)
        XCTAssertThrowsError(try manager.retry())
        XCTAssertThrowsError(try manager.open())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("volumes").path))
        try FileManager.default.moveItem(at: disconnected, to: parent)
        let receipt = manager.location.bootstrapRoot.appendingPathComponent("storage-migration.json")
        let original = try Data(contentsOf: receipt)
        try Store.atomicData(Data("null".utf8), receipt)
        XCTAssertThrowsError(try manager.retry())
        XCTAssertThrowsError(try manager.open())
        try Store.atomicData(original, receipt)
        XCTAssertNil(try manager.retry().pending)
    }
    func testPendingCopyFencesExplicitClientsAndRetryResyncsFences() throws {
        let (root, manager, store, _, _) = try moveFixture()
        let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
        manager.fault = { if $0 == "copy" { throw NestError("Pause recorded copy") } }
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        XCTAssertThrowsError(try Store(root: store.root))
        XCTAssertThrowsError(try store.load())
        for point in ["fence-file-sync", "fence-directory-sync"] {
            manager.fault = { if $0 == point { throw NestError("Fence durability ACK failure") } }
            XCTAssertThrowsError(try manager.retry())
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.location.selectionURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("volumes").path))
        }
        manager.fault = nil
        XCTAssertNil(try manager.retry().pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("volumes").path))
    }
    func testPartialCopyUnlinkLostACKCanRetryFromBothNamesAbsent() throws {
        let (root, manager, store, folder, revision) = try moveFixture()
        let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
        manager.fault = { if $0 == "copy-file" { throw NestError("Leave owned partial file") } }
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        let first = try XCTUnwrap(StorageRelocation.readReceipt(at: manager.location.bootstrapRoot)?.partialFile)
        XCTAssertNotEqual(first.inode, 0)
        manager.fault = { if $0 == "partial-copy-unlinked" { throw NestError("Lost unlink ACK") } }
        XCTAssertThrowsError(try manager.retry())
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: first.parent.path).appendingPathComponent(first.temporary).path))
        XCTAssertNotNil(try StorageRelocation.readReceipt(at: manager.location.bootstrapRoot)?.partialFile)
        manager.fault = nil
        XCTAssertNil(try manager.retry().pending)
        XCTAssertEqual(try manager.open().journal(folder.id).revision, revision)
    }
    func testPartialCleanupRetryAndUnknownDestinationAreConservative() throws {
        let (root, manager, store, _, _) = try moveFixture()
        let parent = root.appendingPathComponent("chosen"); try Store.privateDirectory(parent)
        var unlinks = 0
        manager.fault = { if $0 == "cleanup-entry" { unlinks += 1; if unlinks == 3 { throw NestError("partial cleanup") } } }
        XCTAssertThrowsError(try manager.move(store: store, toParent: parent))
        XCTAssertTrue(try manager.state().cleanupPending)
        XCTAssertThrowsError(try Store(root: store.root))
        manager.fault = nil
        XCTAssertNil(try manager.retry().pending)
        XCTAssertNil(try manager.retry().pending)
        let reopened = try manager.open()
        XCTAssertTrue(try reopened.load().menuBarMode)
        let second = root.appendingPathComponent("second"); try Store.privateDirectory(second)
        manager.fault = { if $0 == "verified" { throw NestError("before fence") } }
        XCTAssertThrowsError(try manager.move(store: reopened, toParent: second))
        manager.fault = nil
        let unknown = second.appendingPathComponent("RAMNest Snapshots/unrelated")
        try Data("preserve unknown".utf8).write(to: unknown)
        XCTAssertThrowsError(try manager.retry())
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "preserve unknown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.root.appendingPathComponent("volumes").path))
    }
}

final class RAMNestCoreTests: XCTestCase {
    func testCoreScenarios() throws { try Scenarios.run() }
}
#endif
struct Scenarios {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "check failed") throws { if try !condition() { throw NestError("TEST: " + message) } }
    static func rejects(_ body: () throws -> Void) throws {
        var failed = false; do { try body() } catch { failed = true }; try check(failed, "expected controlled rejection")
    }
    static func run() throws {
        // XCTest can launch from /tmp (a symlink on macOS), outside the repo.
        // Fixtures must have a canonical owned path without weakening path checks.
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var tests = 0
        func pass(_ name: String) { tests += 1; print("PASS \(tests): \(name)") }
        func dir(_ name: String) throws -> URL { let p = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return p }
        func write(_ s: String, to url: URL) throws { try Data(s.utf8).write(to: url) }
        let store = try Store(root: root.appendingPathComponent("support"))
        let engine = Engine(store: store, helper: URL(fileURLWithPath: "/usr/bin/false"))
        try check(Paths.filesystemID(-1) == UInt64(UInt32.max), "negative fsid must retain bits")
        try check(Paths.deviceID(-1) == UInt64.max)
        try check(!Paths.mounts().isEmpty, "live getmntinfo must not trap")
        pass("negative fsid and signed dev_t regression; live mount enumeration")
        try check(try SizeParser.parse("2GB") == 2<<30); try check(try SizeParser.parse("16M") == 16<<20)
        try rejects { _ = try SizeParser.parse("18446744073709551615GB") }; try rejects { try SizeParser.validate(1) }
        let selected = try dir("selected")
        let f = try engine.create(path: selected, name: "Fast Stuff", capacity: 32<<20)
        try check(try engine.folder("ram://Fast%20Stuff").id == f.id)
        try check(try engine.folder(selected.path).id == f.id)
        let other = try dir("other")
        try rejects { _ = try engine.create(path: other, name: "FAST STUFF", capacity: 32<<20) }
        let nested = try dir("selected/nested")
        try rejects { _ = try engine.create(path: nested, name: "nested", capacity: 32<<20) }
        try rejects { _ = try Paths.validate(URL(fileURLWithPath: "/"), store: store, folders: []) }
        let symlink = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: other)
        try rejects { _ = try Paths.validate(symlink, store: store, folders: []) }
        pass("size overflow, references, unique names, root/symlink/overlap rejection")
        try FileManager.default.removeItem(at: nested)
        try write("initial αβ", to: selected.appendingPathComponent("a.txt"))
        _ = try dir("selected/dir")
        try write("nested", to: selected.appendingPathComponent("dir/x"))
        try FileManager.default.createSymbolicLink(atPath: selected.appendingPathComponent("link").path, withDestinationPath: "../../outside")
        try check(link(selected.appendingPathComponent("dir/x").path, selected.appendingPathComponent("dir-hard").path) == 0)
        try check(lchflags(selected.appendingPathComponent("a.txt").path, UInt32(UF_HIDDEN|UF_NODUMP)) == 0)
        let attr = Data("tag".utf8)
        let attrResult = attr.withUnsafeBytes { setxattr(selected.appendingPathComponent("a.txt").path, "user.ramnest", $0.baseAddress, $0.count, 0, 0) }; try check(attrResult == 0)
        let revision = try store.locked { try Snapshot.capture(store: store, folder: f, source: selected, previous: nil) }
        let (data, manifest) = try Snapshot.verified(store: store, id: f.id, revision: revision)
        try check(manifest.entries.count == 5)
        let exported = root.appendingPathComponent("export")
        try Snapshot.copyTree(from: data, to: exported, manifest: manifest,sourceContext:.managedRevision)
        try check(try Snapshot.manifest(exported) == manifest)
        pass("verified real file/symlink/hardlink/Unicode/xattr/flags snapshot roundtrip")
        try compressionMetadataScenarios(root: root)
        pass("logical compression metadata: reserved xattr and UF_COMPRESSED, source unchanged, strict content and user metadata verification")
        let before = try Snapshot.manifest(selected)
        try rejects { try Snapshot.copyTree(from: selected, to: exported, manifest: before) }
        try check(try Snapshot.manifest(selected) == before)
        try write("damage", to: data.appendingPathComponent("dir/x"))
        try rejects { _ = try Snapshot.verified(store: store, id: f.id, revision: revision) }
        try check(try Snapshot.manifest(selected) == before)
        pass("existing export destination and damaged snapshot reject without source mutation")
        let goodRevision = try Snapshot.capture(store: store, folder: f, source: selected, previous: nil)
        let holding = try dir("original-holding")
        let selectedFD = try DirectoryHandle.open(selected), holdingFD = try DirectoryHandle.open(holding)
        for e in before.entries where !e.path.contains("/") { try selectedFD.renameNoReplace(e.path, to: holdingFD, as: e.path) }
        var j = Journal(); j.phase = .pendingRestore; j.revision = goodRevision; j.initialRevision = goodRevision; j.populationVerified = true; j.mountedDevice = 999; j.restoreRevision = goodRevision; j.evacuation = holding.path; j.evacuatedEntries = before.entries.filter { !$0.path.contains("/") }.map(\.path)
        try store.write(j, for: f.id)
        try rejects { try engine.mount(f.id.uuidString) }
        try engine.recover(f.id.uuidString)
        try check(try Snapshot.manifest(selected) == before)
        try check(try store.journal(f.id).phase == .idle)
        pass("unclean auto-mount gate and pending snapshot authority restore")
        // A competing destination must survive an atomic RENAME_EXCL attempt.
        let a = try dir("rename-a"), b = try dir("rename-b")
        try write("snapshot", to: a.appendingPathComponent("file")); try write("newer sentinel", to: b.appendingPathComponent("file"))
        let ah = try DirectoryHandle.open(a), bh = try DirectoryHandle.open(b)
        try rejects { try ah.renameNoReplace("file", to: bh, as: "file") }
        try check(try String(contentsOf: b.appendingPathComponent("file"), encoding: .utf8) == "newer sentinel")
        pass("no-replace rename preserves competing writer sentinel")
        let substitute = try dir("substitute"), renamed = root.appendingPathComponent("renamed-b")
        try FileManager.default.moveItem(at: b, to: renamed); try FileManager.default.createSymbolicLink(at: b, withDestinationURL: substitute)
        try write("safe", to: a.appendingPathComponent("second")); try ah.renameNoReplace("second", to: bh, as: "second")
        try check(!FileManager.default.fileExists(atPath: substitute.appendingPathComponent("second").path))
        try check(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("second").path))
        try rejects { _ = try DirectoryHandle.open(b) }
        pass("anchored descriptor resists ancestor symlink substitution")
        // Failed restore and explicit conflict resolution keep the committed revision.
        for e in before.entries where !e.path.contains("/") { try FileManager.default.removeItem(at: selected.appendingPathComponent(e.path)) }
        try write("new user data", to: selected.appendingPathComponent("unrelated"))
        j.phase = .pendingRestore; j.restoreStage = nil; j.restoredEntries = []; try store.write(j, for: f.id)
        try rejects { try engine.recover(f.id.uuidString) }
        try check(try store.journal(f.id).revision == goodRevision)
        try check(try String(contentsOf: selected.appendingPathComponent("unrelated"), encoding: .utf8) == "new user data")
        try FileManager.default.moveItem(at: selected.appendingPathComponent("unrelated"), to: root.appendingPathComponent("rescued-unrelated"))
        try engine.recover(f.id.uuidString)
        try check(try Snapshot.manifest(selected) == before)
        pass("failed restore retains authoritative snapshot and refuses opaque merge")
        // A known startup failure must restore evacuated originals automatically.
        try rejects { try engine.mount(f.id.uuidString) }
        try check(try Snapshot.manifest(selected) == before)
        try check(try store.journal(f.id).phase == .idle)
        pass("known helper launch failure rolls back exact evacuated entries")
        // Lots of tiny files are charged per 64 KiB slot before any evacuation.
        let small = try dir("many-small")
        for index in 0..<257 { try write("x", to: small.appendingPathComponent(String(index))) }
        try rejects { _ = try engine.create(path: small, name: "Too Small", capacity: 16<<20) }
        try check(try FileManager.default.contentsOfDirectory(atPath: small.path).count == 257)
        let huge = Entry(path: "huge", kind: "file", size: Int64.max, mode: 0o600, mtimeSeconds: 0, mtimeNanos: 0, checksum: "", attributes: [:], hardlink: nil, flags: 0, attributeBytes: 0)
        try check(Manifest(entries: [huge, huge, huge]).allocatedEstimate == UInt64.max, "allocation estimate must saturate, not trap or wrap")
        pass("small-file capacity preflight matches 64 KiB logical block accounting")
        try metadataPreflightScenarios()
        // Apparent size may exceed capacity when occupied 64 KiB pages fit.
        let oversized = try dir("oversized-file"), oversizedFile = oversized.appendingPathComponent("too-large")
        try Data().write(to: oversizedFile)
        let oversizedHandle = try FileHandle(forWritingTo: oversizedFile)
        try oversizedHandle.truncate(atOffset: (16<<20) + 1); try oversizedHandle.close()
        let sparse = try Snapshot.manifest(oversized, maximumLogical: 16<<20)
        try sparse.preflight(capacity: 16<<20)
        try check(sparse.entries[0].size == 16777217 && sparse.entries[0].allocatedBytes == 0)
        try check(sparse.allocatedEstimate < 65536, "all-zero pages normalize to holes; attribute quota is retained")
        pass("55,000-entry synthetic manifest fits 8 GiB above old metadata cap; distinct logical/metadata errors and small-volume budget")
        // Temporary mode restores the same original file objects, not a new snapshot copy.
        let temp = try dir("temporary"); try write("original", to: temp.appendingPathComponent("seed"))
        var o = FolderOptions(); o.sync = false
        let tf = try engine.create(path: temp, name: "Temporary", capacity: 16<<20, options: o)
        let tr = try Snapshot.capture(store: store, folder: tf, source: temp, previous: nil)
        var originalStat = stat(); _ = lstat(temp.appendingPathComponent("seed").path, &originalStat)
        let th = try dir("temporary-original"); let thFD = try DirectoryHandle.open(th); let tFD = try DirectoryHandle.open(temp)
        try tFD.renameNoReplace("seed", to: thFD, as: "seed")
        var tj = Journal(); tj.phase = .ejecting; tj.populationVerified = true; tj.mountedDevice = 42; tj.revision = tr; tj.initialRevision = tr; tj.evacuation = th.path; tj.evacuatedEntries = ["seed"]
        try store.write(tj, for: tf.id); try engine.recover(tf.id.uuidString)
        var restoredStat = stat(); _ = lstat(temp.appendingPathComponent("seed").path, &restoredStat)
        try check(originalStat.st_ino == restoredStat.st_ino)
        pass("temporary recovery returns original inode and unchanged contents")
        try bookmarkRetryScenarios(root: root)
        pass("bounded bookmark retry accepts only the original identity; unsafe paths and unrelated errors stop immediately")
        print("PASS: \(tests) Swift integration scenarios; disposable fixtures at \(root.path)")
    }
    static func compressionMetadataScenarios(root: URL) throws {
        let source = root.appendingPathComponent("source&accent-é")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let store = try Store(root: root.appendingPathComponent("compression-store"))
        let payload = Data("owned fixture bytes!".utf8)
        var header = Data()
        for value in [UInt32(0x636d7066), UInt32(1)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        var length = UInt64(payload.count).littleEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(payload) // Valid raw-inline decmpfs header, exactly 36 bytes.
        try check(header.count == 36)
        func put(_ file: URL, _ name: String, _ value: Data) throws {
            try check(value.withUnsafeBytes { setxattr(file.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } == 0, "set \(name): \(errno)")
        }
        func get(_ file: URL, _ name: String) throws -> Data {
            let options = XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION
            let count = getxattr(file.path, name, nil, 0, 0, options)
            try check(count >= 0, "get \(name): \(errno)")
            var value = Data(count: count)
            try check(value.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, $0.count, 0, options) } == count)
            return value
        }
        var finderInfo = Data(repeating: 0, count: 32)
        finderInfo.replaceSubrange(0..<4, with: Data("TEXT".utf8))
        let metadata = ["user.ramnest": Data("ordinary metadata".utf8),
                        "com.apple.FinderInfo": finderInfo]
        let plain = source.appendingPathComponent("fixture.bin")
        let compressed = source.appendingPathComponent("compressed-é.bin")
        for file in [plain, compressed] {
            try payload.write(to: file)
            for (name, value) in metadata { try put(file, name, value) }
            try put(file, "com.apple.decmpfs", header)
            let flags = UInt32(UF_HIDDEN | UF_NODUMP) | (file == compressed ? UInt32(UF_COMPRESSED) : 0)
            try check(lchflags(file.path, flags) == 0, "set fixture storage flag: \(errno)")
        }
        // A genuine visible resource fork remains logical metadata. Compressed
        // storage forks are hidden by macOS without XATTR_SHOWCOMPRESSION.
        let resource = Data("legitimate resource fork".utf8)
        try put(plain, "com.apple.ResourceFork", resource)
        var before: [String: stat] = [:]
        for file in [plain, compressed] {
            var st = stat(); try check(lstat(file.path, &st) == 0)
            try check(st.st_size == payload.count)
            try check((st.st_flags & UInt32(UF_COMPRESSED) != 0) == (file == compressed))
            before[file.path] = st
            try check(try Data(contentsOf: file) == payload, "kernel must expose the logical bytes")
        }
        let initial = try Snapshot.manifest(source)
        for entry in initial.entries {
            try check(entry.attributes["com.apple.decmpfs"] == nil)
            try check(entry.flags == UInt32(UF_HIDDEN | UF_NODUMP))
            try check(entry.size == payload.count && entry.checksum == Snapshot.digest(payload))
            let file = source.appendingPathComponent(entry.path)
            let bytes = try entry.attributes.keys.reduce(UInt64(0)) { try $0 + UInt64($1.utf8.count + get(file, $1).count) }
            try check(entry.attributeBytes == bytes, "quota counts only logical metadata")
        }
        var st = stat(); try check(lstat(source.path, &st) == 0)
        let folder = Folder(name: "Compression", path: source.path, capacity: 16<<20, device: Paths.deviceID(st.st_dev), inode: UInt64(st.st_ino))
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        let (copied, expected) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        try check(expected == initial)
        let exported = root.appendingPathComponent("export&accent-é")
        try Snapshot.copyTree(from: copied, to: exported, manifest: expected,sourceContext:.managedRevision)
        try check(try Snapshot.manifest(exported) == expected)
        for file in [plain, compressed] {
            try check(try Data(contentsOf: exported.appendingPathComponent(file.lastPathComponent)) == payload)
            try check(try Data(contentsOf: file) == payload)
            try check(try get(file, "com.apple.decmpfs") == header, "source storage metadata unchanged")
            var after = stat(); try check(lstat(file.path, &after) == 0)
            let old = before[file.path]!
            try check(after.st_ino == old.st_ino && after.st_size == old.st_size && after.st_mode == old.st_mode && after.st_flags == old.st_flags && after.st_mtimespec == old.st_mtimespec && after.st_ctimespec == old.st_ctimespec)
            for (name, value) in metadata { try check(try get(file, name) == value) }
        }
        try check(try get(plain, "com.apple.ResourceFork") == resource)
        print("PASS compression snapshot capture/copy: logical bytes, flags, metadata quota, Unicode/ampersand paths, source contents/inode/timestamps/xattrs unchanged")
        let copy = copied.appendingPathComponent(plain.lastPathComponent)
        var originalTimes = [before[plain.path]!.st_atimespec, before[plain.path]!.st_mtimespec]
        var tamperMetadata = metadata; tamperMetadata["com.apple.ResourceFork"] = resource
        for (name, value) in tamperMetadata {
            var changed = value; changed[0] ^= 1
            try put(copy, name, changed)
            try check(utimensat(AT_FDCWD, copy.path, &originalTimes, AT_SYMLINK_NOFOLLOW) == 0)
            try rejects { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
            try put(copy, name, value)
            try check(utimensat(AT_FDCWD, copy.path, &originalTimes, AT_SYMLINK_NOFOLLOW) == 0)
            _ = try Snapshot.verified(store: store, id: folder.id, revision: revision)
            print("PASS strict metadata tamper detection:", name)
        }
        // copyfile canonicalizes quarantine values. Exercise byte-strict
        // quarantine verification through export adoption, which does not copy.
        let quarantineStage = try store.volume(folder.id).appendingPathComponent("stage-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: quarantineStage, withIntermediateDirectories: false)
        let quarantined = quarantineStage.appendingPathComponent("quarantined.bin")
        try payload.write(to: quarantined)
        let quarantine = Data("0081;65000000;RAMNest;".utf8)
        try put(quarantined, "com.apple.quarantine", quarantine)
        let quarantineRevision = try Snapshot.adoptExport(store: store, folder: folder, stage: quarantineStage)
        let (quarantineData, quarantineManifest) = try Snapshot.verified(store: store, id: folder.id, revision: quarantineRevision)
        try check(quarantineManifest.entries[0].attributes["com.apple.quarantine"] == Snapshot.digest(quarantine))
        let quarantineCopy = quarantineData.appendingPathComponent("quarantined.bin")
        try put(quarantineCopy, "com.apple.quarantine", Data("0081;65000001;RAMNest;".utf8))
        try rejects { _ = try Snapshot.verified(store: store, id: folder.id, revision: quarantineRevision) }
        try put(quarantineCopy, "com.apple.quarantine", quarantine)
        _ = try Snapshot.verified(store: store, id: folder.id, revision: quarantineRevision)
        print("PASS strict quarantine tamper detection through export adoption")
        // Keep size and mtime identical: the SHA check must detect this change.
        var changed = payload; changed[0] ^= 1
        let fd = open(copy.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try check(fd >= 0); defer { close(fd) }
        try check(changed.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == changed.count)
        var times = [before[plain.path]!.st_atimespec, before[plain.path]!.st_mtimespec]
        try check(futimens(fd, &times) == 0)
        let tampered = try Snapshot.manifest(copied,context:.managedRevision)
        let actual = tampered.entries.first { $0.path == plain.lastPathComponent }!
        let original = initial.entries.first { $0.path == plain.lastPathComponent }!
        try check(actual.size == original.size && actual.mtimeSeconds == original.mtimeSeconds && actual.mtimeNanos == original.mtimeNanos && actual.checksum != original.checksum)
        try rejects { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
        try check(payload.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == payload.count)
        try check(ftruncate(fd, off_t(payload.count + 1)) == 0 && futimens(fd, &times) == 0)
        try rejects { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
        try check(try Snapshot.manifest(source) == initial)
        print("PASS strict SHA at equal size/mtime and changed-size tamper detection")
    }
    static func metadataPreflightScenarios() throws {
        // No filesystem tree or payload allocation: one-byte files still cost
        // one logical block each, independently of compression.
        func entry(_ index: Int, kind: String) -> Entry {
            Entry(path: "entry-\(index)", kind: kind, size: kind == "file" ? 1 : 0, mode: 0o600, mtimeSeconds: 0, mtimeNanos: 0, checksum: "", attributes: [:], hardlink: nil, flags: 0, attributeBytes: 0)
        }
        let large = Manifest(entries: (0..<55_000).map { entry($0, kind: $0 < 45_000 ? "file" : "directory") })
        try check(large.metadataEstimate > 64<<20)
        try check(large.allocatedEstimate == 2_949_120_000)
        try check(Manifest.metadataBudget(capacity: 0) == 65536)
        try check(Manifest.metadataBudget(capacity: 16<<20) == 4<<20)
        try check(Manifest.metadataBudget(capacity: 256<<20) == 64<<20)
        try check(Manifest.metadataBudget(capacity: 512<<20) == 128<<20)
        try check(Manifest.metadataBudget(capacity: 8<<30) == 2<<30)
        try check(Manifest.metadataBudget(capacity: UInt64.max) == UInt64.max / 4)
        try large.preflight(capacity: 8<<30)
        do {
            try large.preflight(capacity: 2<<30)
            throw NestError("TEST: insufficient logical capacity was accepted")
        } catch let error as NestError {
            try check(error.code == 6 && error.message.contains("exceeds logical capacity") && !error.message.contains("exceeds metadata budget"))
            try check(error.message.contains("requires 2949120000 bytes") && error.message.contains("allowed 2147483648 bytes"))
            try check(error.message.contains("55000 entries, 45000 regular files") && error.message.contains("compression does not reduce") && error.message.contains("Increase capacity"))
        }
        let small = Manifest(entries: (0..<2_500).map { entry($0, kind: "directory") })
        try check(small.allocatedEstimate == 0)
        do {
            try small.preflight(capacity: 16<<20)
            throw NestError("TEST: small-volume metadata exhaustion was accepted")
        } catch let error as NestError {
            try check(error.code == 6 && error.message.contains("exceeds metadata budget") && !error.message.contains("exceeds logical capacity"))
            try check(error.message.contains("required \(small.metadataEstimate) bytes") && error.message.contains("allowed 4194304 bytes"))
            try check(error.message.contains("2500 entries, 0 regular files, 0 extended attributes") && error.message.contains("capacity / 4") && error.message.contains("Increase capacity"))
        }
        // Equality is accepted; crossing the same budget by one byte is not.
        let exactCapacity = small.metadataEstimate * 4
        try small.preflight(capacity: exactCapacity)
        try rejects { try small.preflight(capacity: exactCapacity - 1) }
    }
    static func bookmarkRetryScenarios(root: URL) throws {
        let original = root.appendingPathComponent("bookmark-original")
        let relocated = root.appendingPathComponent("bookmark-relocated")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try Data("original sentinel".utf8).write(to: original.appendingPathComponent("seed"))
        var identity = stat(); try check(lstat(original.path, &identity) == 0)
        let bookmark = Data([1, 2, 3]) // Injected resolver avoids nondeterministic APFS propagation timing.
        let folder = Folder(name: "Moved", path: original.path, capacity: 16<<20, device: Paths.deviceID(identity.st_dev), inode: UInt64(identity.st_ino), bookmark: bookmark)
        try FileManager.default.moveItem(at: original, to: relocated)
        let missing = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoSuchFile.rawValue)
        var attempts = 0, waits: [TimeInterval] = [], now: TimeInterval = 0
        func reset() { attempts = 0; waits = []; now = 0 }
        func sleep(_ seconds: TimeInterval) { waits.append(seconds); now += seconds }
        let result = try Paths.resolveBookmark(folder, resolver: { data in
            try check(data == bookmark, "every retry must use the original bookmark")
            attempts += 1; if attempts == 1 { throw missing }; return relocated
        }, sleep: sleep, uptime: { now })
        try check(result.path == relocated.path && result.device == folder.device && result.inode == folder.inode)
        try check(attempts == 2 && waits.count == 1 && now <= 2)
        // Once a URL is returned, a different inode/device is terminal, even if
        // a subsequent lookup would have returned the original directory.
        let unrelated = root.appendingPathComponent("bookmark-unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        reset()
        try rejects { _ = try Paths.resolveBookmark(folder, resolver: { _ in
            attempts += 1; if attempts == 1 { throw missing }; return attempts == 2 ? unrelated : relocated
        }, sleep: sleep, uptime: { now }) }
        try check(attempts == 2 && waits.count == 1, "identity mismatch must not be retried")
        var wrongDevice = folder; wrongDevice.device ^= 1
        reset()
        try rejects { _ = try Paths.resolveBookmark(wrongDevice, resolver: { _ in attempts += 1; return relocated }, sleep: sleep, uptime: { now }) }
        try check(attempts == 1 && waits.isEmpty, "device mismatch must be rejected even with the same inode")
        let alias = root.appendingPathComponent("bookmark-symlink")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: relocated)
        for unsafe in [alias, alias.appendingPathComponent(".."), URL(string: "https://example.invalid/folder")!] {
            reset()
            try rejects { _ = try Paths.resolveBookmark(folder, resolver: { _ in attempts += 1; return unsafe }, sleep: sleep, uptime: { now }) }
            try check(attempts == 1 && waits.isEmpty, "unsafe URL must not be retried")
        }
        // Domain and code must both match; permission/POSIX/custom failures
        // retain their original error instead of becoming a missing-file retry.
        for failure in [NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoPermission.rawValue),
                        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
                        NSError(domain: "unrelated-domain", code: missing.code)] {
            reset()
            do {
                _ = try Paths.resolveBookmark(folder, resolver: { _ in attempts += 1; throw failure }, sleep: sleep, uptime: { now })
                throw NestError("TEST: unrelated resolver error was accepted")
            } catch { try check((error as NSError) === failure, "original resolver NSError must be preserved") }
            try check(attempts == 1 && waits.isEmpty)
        }
        reset()
        do {
            _ = try Paths.resolveBookmark(folder, resolver: { _ in attempts += 1; throw NestError("unrelated custom error", code: 42) }, sleep: sleep, uptime: { now })
            throw NestError("TEST: custom error was accepted")
        } catch let error as NestError { try check(error.code == 42 && error.message == "unrelated custom error") }
        try check(attempts == 1 && waits.isEmpty)
        for code in [CocoaError.Code.fileNoSuchFile, .fileReadNoSuchFile] {
            reset()
            do {
                _ = try Paths.resolveBookmark(folder, resolver: { _ in attempts += 1; throw NSError(domain: NSCocoaErrorDomain, code: code.rawValue) }, sleep: sleep, uptime: { now })
                throw NestError("TEST: missing original was accepted")
            } catch let error as NestError {
                try check(error.code == 4 && error.message.contains("bounded bookmark retries") && error.message.contains(String(folder.inode)), "exhausted retry must explain identity and next action")
            }
            try check(attempts > 1 && attempts <= 8 && waits.reduce(0, +) <= 1.5 && now <= 2, "retry budget must be bounded")
        }
        reset()
        try rejects { _ = try Paths.resolveBookmark(folder, resolver: { _ in attempts += 1; now += 2; throw missing }, sleep: sleep, uptime: { now }) }
        try check(attempts == 1 && waits.isEmpty, "slow resolver must consume the retry deadline")
        reset()
        _ = try Paths.resolveBookmark(result, resolver: { _ in attempts += 1; throw missing }, sleep: sleep, uptime: { now })
        try check(attempts == 0 && waits.isEmpty, "unchanged identity must not invoke the resolver")
        try check(try String(contentsOf: relocated.appendingPathComponent("seed"), encoding: .utf8) == "original sentinel")
        try check(!FileManager.default.fileExists(atPath: original.path), "resolver must not create guessed fallback folders")
    }
}
