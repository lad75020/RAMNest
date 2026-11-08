import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_QUARANTINE_SNAPSHOT_STANDALONE
import XCTest

final class QuarantineSnapshotTests: XCTestCase {
    func testExactQuarantineSnapshotCopy() throws { try QuarantineSnapshotScenarios.run() }
}

// Phase A: owned fixtures only. Never launch helpers/mounts or manufacture,
// strip, or interpret OS provenance. The emitter leaves a fresh XCTest-created
// tree for a separately authorized process to perform the real rename probe.
final class SourceWriteRaceTests: XCTestCase {
    private var artifacts: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath().appendingPathComponent("artifacts/source-race-fix")
    }
    private func freshTree(_ label: String) throws -> (root: URL, source: URL) {
        let root = artifacts.appendingPathComponent(label + "-" + UUID().uuidString)
        try Store.privateDirectory(root)
        let source = root.appendingPathComponent("selected")
        try Store.privateDirectory(source.appendingPathComponent("nested/leaf"))
        for directory in [source, source.appendingPathComponent("nested"), source.appendingPathComponent("nested/leaf")] {
            guard chmod(directory.path, 0o755) == 0 else { throw NestError("Cannot set owned fixture directory mode") }
        }
        for name in [".DS_Store", "ordinary.txt", "nested/tiny.txt", "nested/leaf/tiny.txt"] {
            let file = source.appendingPathComponent(name)
            try Data("Generated source-race fixture: \(name)\n".utf8).write(to: file)
            guard chmod(file.path, 0o644) == 0 else { throw NestError("Cannot set owned fixture file mode") }
        }
        return (root, source)
    }
    private func engineFixture(_ label: String) throws -> (URL, URL, Store, Folder) {
        let (root, source) = try freshTree(label)
        let identity = try DirectoryHandle.open(source).identity()
        let folder = Folder(name: "Owned source-race fixture", path: source.path, capacity: 16 << 20,
                            device: identity.device, inode: identity.inode)
        let store = try Store(root: root.appendingPathComponent("store"))
        var config = Configuration(); config.backend = .nfs; config.folders = [folder]
        try store.save(config)
        return (root, source, store, folder)
    }
    private func journal(_ expected: Manifest) -> Journal {
        var journal = Journal(); journal.backend = .nfs; journal.session = UUID()
        journal.phase = .preparing; journal.initialSourceManifest = expected
        return journal
    }
    func testEmitFreshCrossCreatorRenameFixture() throws {
        let (root, source) = try freshTree("creator")
        let before = try Snapshot.manifest(source)
        let identities = try QuarantineSnapshotScenarios.unchangedIdentities(source, before)
        for name in [".DS_Store", "ordinary.txt", "nested/tiny.txt", "nested/leaf/tiny.txt"] {
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(name)),
                           Data("Generated source-race fixture: \(name)\n".utf8))
        }
        XCTAssertEqual(try Snapshot.manifest(source), before)
        XCTAssertEqual(try QuarantineSnapshotScenarios.unchangedIdentities(source, before), identities)
        struct Record: Encodable {
            let schema: Int
            let creatorPID: Int32
            let fixtureRoot: String
            let sourcePath: String
            let rawManifest: Manifest
            // Each tuple is dev, ino, nlink, ctime seconds, ctime nanoseconds.
            let identities: [String: [Int64]]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(Record(schema: 1, creatorPID: getpid(), fixtureRoot: root.path,
                                             sourcePath: source.path, rawManifest: before, identities: identities))
        // Per-run evidence stays immutable; the pointer names only the newest
        // generated fixture. No earlier tree or snapshot is reused or modified.
        try bytes.write(to: root.appendingPathComponent("creator-fixture.json"), options: .withoutOverwriting)
        try bytes.write(to: artifacts.appendingPathComponent("creator-fixture.json"), options: .atomic)
        print("SOURCE_RACE_CREATOR_FIXTURE=" + source.path)
    }
    func testNFSEvacuationOfFreshTreePreservesRawEntriesAndInodes() throws {
        let (_, source, store, folder) = try engineFixture("same-creator-control")
        let expected = try Snapshot.manifest(source)
        let identities = try QuarantineSnapshotScenarios.unchangedIdentities(source, expected)
        var j = journal(expected)
        let (handle, holding) = try Engine(store: store).evacuateOriginal(folder, journal: &j, expected: expected)
        XCTAssertEqual(try handle.names(), [])
        try handle.verify(folder)
        XCTAssertTrue(try Snapshot.manifest(holding).contentsMatchExpected(expected))
        XCTAssertTrue(try Snapshot.manifest(holding, matching: expected).contentsMatchExpected(expected))
        let retained = try QuarantineSnapshotScenarios.unchangedIdentities(holding, expected)
        for entry in expected.entries {
            // Rename may change ctime; inode, device and link count must survive.
            XCTAssertEqual(retained[entry.path].map { Array($0.prefix(3)) },
                           identities[entry.path].map { Array($0.prefix(3)) })
        }
    }
    func testNFSEvacuationRejectsRealWriteAndNewEntryBeforeRename() throws {
        for mutation in ["write", "new-entry"] {
            let (_, source, store, folder) = try engineFixture("before-" + mutation)
            let expected = try Snapshot.manifest(source)
            let changed = source.appendingPathComponent(mutation == "write" ? "ordinary.txt" : "new-entry.txt")
            let bytes = Data("Real owned fixture mutation\n".utf8); try bytes.write(to: changed)
            let observed = try Snapshot.manifest(source)
            let identities = try QuarantineSnapshotScenarios.unchangedIdentities(source, observed)
            var j = journal(expected)
            XCTAssertThrowsError(try Engine(store: store).evacuateOriginal(folder, journal: &j, expected: expected)) {
                XCTAssertEqual($0.localizedDescription, "Source changed before evacuation.")
            }
            XCTAssertEqual(try Snapshot.manifest(source), observed)
            XCTAssertEqual(try QuarantineSnapshotScenarios.unchangedIdentities(source, observed), identities)
            XCTAssertEqual(try Data(contentsOf: changed), bytes)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: XCTUnwrap(j.evacuation)).isEmpty)
        }
    }
    func testNFSActivationRejectsOldFDWriteAndNewSourceEntry() throws {
        for mutation in ["old-fd", "new-entry"] {
            let (_, source, store, folder) = try engineFixture("after-" + mutation)
            let expected = try Snapshot.manifest(source)
            let fd = open(source.appendingPathComponent("ordinary.txt").path, O_WRONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw NestError("Cannot open owned fixture writer") }
            defer { close(fd) }
            var boundary = EngineSession(); boundary.populationRead = { _ in expected }
            boundary.request = { _, _ in XCTFail("Changed originals must never activate"); return [] }
            let engine = Engine(store: store, session: boundary)
            var j = journal(expected); j.socket = "owned-no-helper"
            let (handle, holding) = try engine.evacuateOriginal(folder, journal: &j, expected: expected)
            let changed = mutation == "old-fd" ? holding.appendingPathComponent("ordinary.txt") : source.appendingPathComponent("new-entry.txt")
            let bytes = Data("Changed through original descriptor\n".utf8)
            if mutation == "old-fd" {
                XCTAssertEqual(bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, 0) }, bytes.count)
                XCTAssertEqual(ftruncate(fd, off_t(bytes.count)), 0); XCTAssertEqual(fsync(fd), 0)
            } else { try bytes.write(to: changed) }
            let observed = try Snapshot.manifest(holding)
            XCTAssertThrowsError(try engine.verifyAndActivatePopulation(folder, journal: &j, expected: expected, source: handle, original: holding))
            XCTAssertEqual(j.phase, .recoveryRequired)
            XCTAssertEqual(try Snapshot.manifest(holding), observed)
            XCTAssertEqual(try Data(contentsOf: changed), bytes)
            XCTAssertFalse(j.populationVerified)
        }
    }
    func testRenameWindowRejectsRealMutationsAndReplacement() throws {
        for mutation in ["content", "old-fd", "source-entry", "holding-entry", "replacement", "quarantine", "xattr", "source-root"] {
            let (root, source, store, folder) = try engineFixture("window-" + mutation)
            let expected = try Snapshot.manifest(source)
            let writer = open(source.appendingPathComponent("ordinary.txt").path, O_WRONLY | O_NOFOLLOW)
            guard writer >= 0 else { throw NestError("Cannot open owned mutation writer") }; defer { close(writer) }
            var boundary = EngineSession()
            boundary.afterOriginalRenames = { selected, holding in
                let file = holding.appendingPathComponent("ordinary.txt")
                switch mutation {
                case "content": try Data("changed bytes".utf8).write(to: file)
                case "old-fd":
                    let bytes = Data("old descriptor write".utf8)
                    XCTAssertEqual(bytes.withUnsafeBytes { pwrite(writer, $0.baseAddress, bytes.count, 0) }, bytes.count)
                    XCTAssertEqual(fsync(writer), 0)
                case "source-entry": try Data("new source".utf8).write(to: selected.appendingPathComponent("new.txt"))
                case "holding-entry": try Data("unknown holding".utf8).write(to: holding.appendingPathComponent("unknown.txt"))
                case "replacement":
                    XCTAssertEqual(rename(file.path, root.appendingPathComponent("retained-displaced.txt").path), 0)
                    try Data("replacement".utf8).write(to: file)
                case "quarantine": try QuarantineSnapshotScenarios.setAttribute(file, QuarantineSnapshotScenarios.synthetic)
                case "xattr": try QuarantineSnapshotScenarios.setAttribute(file, Data("ordinary mutation".utf8), "user.ramnest-race-control")
                default:
                    XCTAssertEqual(rename(selected.path, root.appendingPathComponent("retained-selected").path), 0)
                    try Store.privateDirectory(selected)
                }
            }
            var j = journal(expected)
            XCTAssertThrowsError(try Engine(store: store, session: boundary).evacuateOriginal(folder, journal: &j, expected: expected), mutation)
            XCTAssertNil(j.originalRename?.after, "A failed readback cannot acknowledge the rename: \(mutation)")
            let holding = URL(fileURLWithPath: try XCTUnwrap(j.evacuation))
            XCTAssertTrue(FileManager.default.fileExists(atPath: holding.appendingPathComponent(".DS_Store").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: holding.appendingPathComponent("ordinary.txt").path))
            if mutation == "source-entry" { XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("new.txt")), Data("new source".utf8)) }
            if mutation == "replacement" { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("retained-displaced.txt")), Data("Generated source-race fixture: ordinary.txt\n".utf8)) }
        }
    }
    func testRenameSyncAndReadbackErrorsPreserveReasonAndIntent() throws {
        for fault in ["source", "holding", "readback"] {
            let (_, source, store, folder) = try engineFixture("fault-" + fault)
            let expected = try Snapshot.manifest(source)
            var boundary = EngineSession(), calls = 0
            boundary.renameSync = { _ in
                calls += 1
                if calls == (fault == "source" ? 1 : 2), fault != "readback" { errno = EIO; return -1 }
                return 0
            }
            if fault == "readback" { boundary.afterOriginalRenames = { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) } }
            var j = journal(expected)
            XCTAssertThrowsError(try Engine(store: store, session: boundary).evacuateOriginal(folder, journal: &j, expected: expected)) { error in
                if fault == "readback" { XCTAssertEqual((error as NSError).code, Int(EACCES)) }
                else { XCTAssertTrue(error.localizedDescription.contains("fsync \(fault) errno \(EIO)")) }
            }
            XCTAssertNil(j.originalRename?.after)
            XCTAssertEqual(try DirectoryHandle.open(source).names(), [])
            XCTAssertNotNil(j.evacuation)
        }
    }
    func testCompletedRenameProofRejectsLaterRawChangeAndTampering() throws {
        let (_, source, store, folder) = try engineFixture("later-raw-change")
        let expected = try Snapshot.manifest(source); var j = journal(expected)
        let (_, holding) = try Engine(store: store).evacuateOriginal(folder, journal: &j, expected: expected)
        let receipt = try XCTUnwrap(j.originalRename)
        XCTAssertNotNil(receipt.after)
        XCTAssertEqual(try receipt.verify(at: holding), receipt.after?.manifest)
        var tampered = receipt
        tampered.after?.nodes[1].inode += 1
        XCTAssertThrowsError(try tampered.validate())
        var intent = receipt; intent.after = nil
        XCTAssertEqual(try intent.verifyStrictIncomplete(at: holding).entries, expected.entries)
        XCTAssertNil(intent.after, "Strict recovery must not synthesize completion authority")
        var wrongIdentity = intent; wrongIdentity.before.nodes[1].inode += 1
        XCTAssertThrowsError(try wrongIdentity.verifyStrictIncomplete(at: holding))
        try QuarantineSnapshotScenarios.setAttribute(holding.appendingPathComponent("ordinary.txt"), Data("late raw mutation".utf8), "user.ramnest-race-control")
        XCTAssertThrowsError(try receipt.verify(at: holding))
        XCTAssertThrowsError(try intent.verifyStrictIncomplete(at: holding))
        XCTAssertEqual(j.initialSourceManifest, expected)
    }
    func testRenameJournalDecoderRejectsNullUnknownAndPartialAuthority() throws {
        let (_, source, store, folder) = try engineFixture("decoder")
        let expected = try Snapshot.manifest(source); var j = journal(expected)
        _ = try Engine(store: store).evacuateOriginal(folder, journal: &j, expected: expected)
        let bytes = try JSONEncoder().encode(j)
        XCTAssertEqual(try JSONDecoder().decode(Journal.self, from: bytes), j)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for field in ["originalRename", "publicationRename"] {
            var bad = object; bad[field] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: bad)))
        }
        for change in ["version", "after", "nodes", "binding"] {
            var bad = object, receipt = try XCTUnwrap(object["originalRename"] as? [String: Any])
            switch change {
            case "version": receipt["version"] = 99
            case "after": receipt["after"] = NSNull()
            case "binding": receipt["session"] = UUID().uuidString
            default: receipt.removeValue(forKey: "before")
            }
            bad["originalRename"] = receipt
            XCTAssertThrowsError(try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: bad)), change)
        }
        var legacy = object; legacy.removeValue(forKey: "originalRename")
        XCTAssertNil(try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: legacy)).originalRename)
        var intent = try XCTUnwrap(j.originalRename); intent.after = nil
        XCTAssertThrowsError(try intent.verify(at: URL(fileURLWithPath: try XCTUnwrap(j.evacuation))))
    }
    func testNFSRollbackVerifiesOwnReverseRenameAndRetainsConflicts() throws {
        for scenario in ["verified", "legacy-no-session", "conflict"] {
            let conflict = scenario == "conflict"
            let (_, source, store, folder) = try engineFixture(conflict ? "rollback-conflict" : "rollback")
            let expected = try Snapshot.manifest(source)
            let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
            var j = journal(expected); j.initialRevision = revision; j.revision = revision
            let engine = Engine(store: store)
            let (_, holding) = try engine.evacuateOriginal(folder, journal: &j, expected: expected)
            if scenario == "legacy-no-session" {
                j.originalRename = nil; j.session = nil; try store.write(j, for: folder.id)
            }
            if conflict {
                let new = source.appendingPathComponent("ordinary.txt")
                try Data("new entry must survive".utf8).write(to: new)
                XCTAssertThrowsError(try engine.rollbackInitial(folder, journal: &j))
                XCTAssertEqual(try Data(contentsOf: new), Data("new entry must survive".utf8))
                XCTAssertEqual(try Data(contentsOf: holding.appendingPathComponent("ordinary.txt")), Data("Generated source-race fixture: ordinary.txt\n".utf8))
            } else {
                try engine.rollbackInitial(folder, journal: &j)
                XCTAssertEqual(j.phase, .idle); XCTAssertNil(j.originalRename); XCTAssertNil(j.publicationRename)
                if scenario == "legacy-no-session" { XCTAssertNil(j.session, "Legacy rollback must not mint a session") }
                try Paths.checkedIdentity(folder)
                XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("ordinary.txt")), Data("Generated source-race fixture: ordinary.txt\n".utf8))
            }
        }
    }
    func testLegacyPendingJournalCannotAcquireRenameWaiver() throws {
        let (_, source, store, folder) = try engineFixture("legacy-pending")
        let expected = try Snapshot.manifest(source)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        var j = journal(expected); j.initialRevision = revision; j.revision = revision
        let engine = Engine(store: store)
        let (_, holding) = try engine.evacuateOriginal(folder, journal: &j, expected: expected)
        // No private provenance is synthesized. An actual ordinary xattr
        // change proves that absent legacy evidence does not bless mutations.
        j.originalRename = nil
        try QuarantineSnapshotScenarios.setAttribute(holding.appendingPathComponent("ordinary.txt"), Data("unacknowledged change".utf8), "user.ramnest-legacy-control")
        let raw = try Snapshot.manifest(holding)
        XCTAssertThrowsError(try engine.rollbackInitial(folder, journal: &j))
        XCTAssertNil(j.publicationRename)
        XCTAssertEqual(try Snapshot.manifest(holding), raw)
        XCTAssertEqual(try DirectoryHandle.open(source).names(), [])
    }
    func testPackagedCLINFSFreshCreatorColdLoop() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RAMNEST_RACE_ALLOW_NFS_TEST"] == "1", let cliPath = env["RAMNEST_RACE_CLI"] else {
            throw XCTSkip("Parent must explicitly bind RAMNEST_RACE_ALLOW_NFS_TEST=1 and RAMNEST_RACE_CLI for owned NFS acceptance")
        }
        let candidate = artifacts.appendingPathComponent("delivery/RAMNest.app/Contents/Helpers/ramnest").standardizedFileURL
        guard cliPath.hasPrefix("/"), URL(fileURLWithPath: cliPath).standardizedFileURL == candidate,
              FileManager.default.isExecutableFile(atPath: cliPath) else { throw NestError("Bind RAMNEST_RACE_CLI to the source-race-fix packaged candidate") }
        let (root, source) = try freshTree("host-nfs")
        let storeRoot = root.appendingPathComponent("store")
        var invocations: [[String: Any]] = []
        var observedSessions: [(pid: Int32, socket: String)] = []
        func awaitRetirement(pid: Int32, socket: String) throws {
            guard pid > 1 else { throw NestError("Invalid owned helper PID") }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while true {
                let result = kill(pid, 0), processError = errno
                let processGone = result == -1 && processError == ESRCH
                let endpointGone = !FileManager.default.fileExists(atPath: socket)
                if processGone && endpointGone { return }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw NestError("Owned helper retirement deadline exceeded (processGone=\(processGone), endpointGone=\(endpointGone))") }
                // Poll observable teardown, not a fixed grace sleep. retire ACK
                // precedes controller close/unlink and the periodic thread join.
                Thread.sleep(forTimeInterval: min(0.05, remaining))
            }
        }
        func run(_ args: [String]) throws {
            let child = Process(); child.executableURL = candidate
            child.arguments = ["--store", storeRoot.path] + args
            // create/info JSON can contain bookmarks. Discard all stdout.
            child.standardOutput = FileHandle.nullDevice
            let errorFile = root.appendingPathComponent("command-\(invocations.count).stderr")
            try Data().write(to: errorFile)
            let errors = try FileHandle(forWritingTo: errorFile); defer { errors.closeFile() }
            child.standardError = errors; try child.run(); child.waitUntilExit()
            invocations.append(["command": args.first ?? "", "exit": Int(child.terminationStatus)])
            try JSONSerialization.data(withJSONObject: invocations, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("invocations.json"))
            guard child.terminationReason == .exit, child.terminationStatus == 0 else { throw NestError("Owned NFS acceptance command failed: \(args.first ?? "") exit \(child.terminationStatus); generated stderr retained") }
        }
        try run(["create", source.path, "--size", "16MB", "--no-mount"])
        let store = try Store(root: storeRoot), folder = try XCTUnwrap(store.load().folders.first)
        defer {
            let pending = try? store.journal(folder.id)
            if pending?.phase != .idle || Paths.mounts().contains(where: { $0.path == source.path }) {
                do { try run(["eject", folder.id.uuidString, "--ignore-busy"]) }
                catch { XCTFail("Owned NFS cleanup failed; generated fixture retained") }
            }
            XCTAssertFalse(Paths.mounts().contains(where: { $0.path == source.path }), "Owned NFS mount cleanup is required")
            for observed in observedSessions {
                do { try awaitRetirement(pid: observed.pid, socket: observed.socket) }
                catch { XCTFail("Owned helper cleanup failed: \(error.localizedDescription)") }
            }
        }
        for cycle in 1...2 {
            try run(["mount", folder.id.uuidString])
            let live = try store.journal(folder.id)
            XCTAssertEqual(live.phase, .mounted); XCTAssertTrue(live.populationVerified)
            XCTAssertNotNil(live.originalRename?.after)
            let status = try Control.status(live, id: folder.id)
            let socket = try XCTUnwrap(live.socket)
            observedSessions.append((status.pid, socket))
            XCTAssertTrue(status.mounted); XCTAssertTrue(status.active)
            XCTAssertTrue(Paths.mounts().contains(where: { $0.path == source.path }))
            if cycle == 1 { try Data("Saved cold-loop bytes\n".utf8).write(to: source.appendingPathComponent("cold-loop.txt")) }
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("ordinary.txt")), Data("Generated source-race fixture: ordinary.txt\n".utf8))
            try run(["save", folder.id.uuidString]); try run(["eject", folder.id.uuidString, "--ignore-busy"])
            XCTAssertFalse(Paths.mounts().contains(where: { $0.path == source.path }))
            XCTAssertEqual(try store.journal(folder.id).phase, .idle)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("cold-loop.txt")), Data("Saved cold-loop bytes\n".utf8))
            try awaitRetirement(pid: status.pid, socket: socket)
            XCTAssertThrowsError(try Control.status(live, id: folder.id), "Retired helper must no longer serve the session")
            observedSessions.removeAll { $0.pid == status.pid && $0.socket == socket }
        }
    }
    func testFSKitWholeRootRenameAndTemporaryRollbackKeepInodeAuthority() throws {
        let (root, source, store, folder) = try engineFixture("fskit-root-control")
        let expected = try Snapshot.manifest(source)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        let mountRoot = root.appendingPathComponent("RAMNest-Mounts-\(getuid())")
        store.fsKitFixtureRoot = mountRoot
        var config = try store.load(); config.backend = .fskit; try store.save(config)
        var j = journal(expected); j.backend = .fskit; j.initialRevision = revision; j.revision = revision
        j.fsKitLink = try FSKitLinks.reserve(folder, session: try XCTUnwrap(j.session), root: mountRoot, filesystemCheck: { _ in })
        var boundary = EngineSession(); boundary.fsKitMountRoot = mountRoot
        let engine = Engine(store: store, session: boundary)
        let (_, holding) = try engine.evacuateOriginal(folder, journal: &j, expected: expected)
        let receipt = try XCTUnwrap(j.originalRename)
        XCTAssertTrue(receipt.wholeRoot)
        XCTAssertEqual(receipt.before.nodes.first?.inode, folder.inode)
        XCTAssertEqual(receipt.after?.nodes.first?.inode, folder.inode)
        XCTAssertEqual(try receipt.verify(at: holding), receipt.after?.manifest)
        // Same-creator control observes authentic OS behavior; it does not
        // manufacture a root provenance difference to force coverage.
        try engine.rollbackInitial(folder, journal: &j)
        XCTAssertEqual(j.phase, .idle); XCTAssertNil(j.originalRename); XCTAssertNil(j.publicationRename)
        try Paths.checkedIdentity(try engine.folder(folder.id.uuidString))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("ordinary.txt")), Data("Generated source-race fixture: ordinary.txt\n".utf8))
    }
}

// Cross-process regression: XCTest creates the source; the delivered CLI creates
// the export. Never synthesize, remove, or replay com.apple.provenance here.
final class ProvenanceCopyTests: XCTestCase {
    private let provenance = "com.apple.provenance"
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
    }
    private func fixture(_ name: String) throws -> URL {
        let root = project.appendingPathComponent("artifacts/provenance-fix/\(name)-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        return root
    }
    private func folder(_ source: URL, store: Store) throws -> Folder {
        let identity = try DirectoryHandle.open(source).identity()
        let folder = Folder(name: "Owned provenance fixture", path: source.path,
                            capacity: 16 << 20, device: identity.device, inode: identity.inode)
        var config = Configuration(); config.folders = [folder]; try store.save(config)
        return folder
    }
    // Include every visible xattr, using pinned no-follow descriptors. Comparing
    // these dictionaries must never print opaque values in a failure diagnostic.
    private func rawAttributes(_ root: URL, _ manifest: Manifest) throws -> [String: [String: Data]] {
        var result: [String: [String: Data]] = [:]
        for path in [""] + manifest.entries.map(\.path) {
            let url = path.isEmpty ? root : root.appendingPathComponent(path)
            let fd = try QuarantineSnapshotScenarios.descriptor(url); defer { close(fd) }
            let count = flistxattr(fd, nil, 0, 0)
            guard count >= 0 else { throw NestError("Cannot list owned fixture attributes") }
            var names = [CChar](repeating: 0, count: count)
            guard flistxattr(fd, &names, count, 0) == count else { throw NestError("Owned fixture attributes changed") }
            var attributes: [String: Data] = [:], offset = 0
            while offset < count {
                let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress!.advanced(by: offset)) }
                offset += name.utf8.count + 1
                guard let value = try QuarantineSnapshotScenarios.attribute(url, name) else {
                    throw NestError("Owned fixture attribute disappeared")
                }
                attributes[name] = value
            }
            result[path] = attributes
        }
        return result
    }
    // Test oracle only: remove precisely the observed name+value byte cost from
    // each side, retaining all other fields. No assumed provenance payload size.
    private func copyView(_ manifest: Manifest, at root: URL) throws -> Manifest {
        func project(_ entry: Entry) throws -> Entry {
            var value = entry
            if value.attributes.removeValue(forKey: provenance) != nil {
                let url = entry.path.isEmpty ? root : root.appendingPathComponent(entry.path)
                let bytes = try XCTUnwrap(QuarantineSnapshotScenarios.attribute(url, provenance))
                let cost = UInt64(provenance.utf8.count + bytes.count)
                guard value.attributeBytes >= cost else { throw NestError("Invalid fixture attribute accounting") }
                value.attributeBytes -= cost
            }
            value.provenanceBytes = 0
            return value
        }
        return try Manifest(entries: manifest.entries.map(project), publicRoot: manifest.publicRoot.map(project))
    }
    func testPackagedCLIExportsGeneratedDSStoreAcrossCreatorLineages() throws {
        try exportGenerated(names: [".DS_Store", "ordinary.txt"])
    }
    func testPackagedCLIExportsOrdinaryFileAcrossCreatorLineages() throws {
        try exportGenerated(names: ["ordinary.txt"])
    }
    func testCopyStillRejectsNonProvenanceSourceMutation() throws {
        for field in ["ordinary-xattr", "quarantine", "content", "mode", "flags"] {
            let root = try fixture("strict-\(field)"), source = root.appendingPathComponent("source")
            try Store.privateDirectory(source)
            let file = source.appendingPathComponent("ordinary.txt")
            try Data("original\n".utf8).write(to: file)
            let expected = try Snapshot.manifest(source)
            switch field {
            case "ordinary-xattr":
                try QuarantineSnapshotScenarios.setAttribute(file, Data("changed".utf8), "user.ramnest-provenance-control")
            case "quarantine": try QuarantineSnapshotScenarios.setAttribute(file, QuarantineSnapshotScenarios.synthetic)
            case "content": try Data("modified\n".utf8).write(to: file)
            case "mode": XCTAssertEqual(chmod(file.path, 0o400), 0)
            default: XCTAssertEqual(chflags(file.path, UInt32(UF_NODUMP)), 0)
            }
            let changed = try Snapshot.manifest(source), attrs = try rawAttributes(source, changed)
            XCTAssertThrowsError(try Snapshot.copyTree(from: source, to: root.appendingPathComponent("copy"), manifest: expected)) { error in
                XCTAssertTrue(error.localizedDescription.contains("ordinary.txt"), "Mismatch must name the changed entry: \(field)")
                XCTAssertTrue(error.localizedDescription.contains("No source files were removed"))
            }
            XCTAssertEqual(try Snapshot.manifest(source), changed)
            XCTAssertTrue(try rawAttributes(source, changed) == attrs, "Rejection changed raw source attributes: \(field)")
        }
    }
    func testPackagedExportPreservesRawSourceAndCommittedIntegrity() throws {
        try exportGenerated(names: ["ordinary.txt"], checkRawIntegrity: true)
    }
    private func exportGenerated(names: [String], checkRawIntegrity: Bool = false) throws {
        let root = try fixture("cli-export"), source = root.appendingPathComponent("selected")
        try Store.privateDirectory(source)
        for name in names {
            let file = source.appendingPathComponent(name)
            try Data("Generated inert fixture: \(name)\n".utf8).write(to: file)
            try QuarantineSnapshotScenarios.setAttribute(file, Data("ordinary metadata".utf8), "user.ramnest-provenance-control")
            try QuarantineSnapshotScenarios.setAttribute(file, QuarantineSnapshotScenarios.synthetic)
        }
        let before = try Snapshot.manifest(source)
        let attrs = try rawAttributes(source, before)
        let identities = try QuarantineSnapshotScenarios.unchangedIdentities(source, before)
        let store = try Store(root: root.appendingPathComponent("store"))
        let folder = try folder(source, store: store)
        let revision = try store.locked { try Snapshot.capture(store: store, folder: folder, source: source, previous: nil) }
        let (data, saved) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        let savedAttrs = try rawAttributes(data, saved)
        let savedIdentities = try QuarantineSnapshotScenarios.unchangedIdentities(data, saved)
        let env = ProcessInfo.processInfo.environment
        let cliPath = env["RAMNEST_PROVENANCE_CLI"] ?? env["RAMNEST_STORAGE_CLI"] ?? project
            .appendingPathComponent("artifacts/snapshot-storage-location/delivery/RAMNest.app/Contents/Helpers/ramnest").path
        guard cliPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw NestError("Bind RAMNEST_PROVENANCE_CLI to the current packaged Release CLI absolute path")
        }
        let destination = root.appendingPathComponent("export")
        let stdout = root.appendingPathComponent("cli.stdout"), stderr = root.appendingPathComponent("cli.stderr")
        try Data().write(to: stdout); try Data().write(to: stderr)
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { out.closeFile(); err.closeFile() }
        let child = Process(); child.executableURL = URL(fileURLWithPath: cliPath)
        child.arguments = ["--store", store.root.path, "export", folder.id.uuidString, destination.path, "--revision", revision]
        child.currentDirectoryURL = root
        child.standardOutput = out; child.standardError = err
        try child.run(); child.waitUntilExit()
        try JSONSerialization.data(withJSONObject: ["cli": cliPath, "arguments": child.arguments ?? [],
            "terminationStatus": Int(child.terminationStatus)], options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("invocation.json"))
        // Run these even on RED, before asserting the intended successful export.
        XCTAssertEqual(try Snapshot.manifest(source), before)
        XCTAssertTrue(try rawAttributes(source, before) == attrs, "Original raw attributes changed")
        XCTAssertEqual(try QuarantineSnapshotScenarios.unchangedIdentities(source, before), identities)
        XCTAssertEqual(try Snapshot.verified(store: store, id: folder.id, revision: revision).1, saved)
        XCTAssertTrue(try rawAttributes(data, saved) == savedAttrs, "Committed raw attributes changed")
        XCTAssertEqual(try QuarantineSnapshotScenarios.unchangedIdentities(data, saved), savedIdentities)
        let diagnostic = String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
        XCTAssertEqual(child.terminationReason, .exit)
        XCTAssertEqual(child.terminationStatus, 0, "Expected copy-local provenance policy; \(diagnostic)")
        guard child.terminationReason == .exit, child.terminationStatus == 0 else { return }
        XCTAssertEqual(try copyView(Snapshot.manifest(destination), at: destination), try copyView(saved, at: data))
        for name in names {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), try Data(contentsOf: source.appendingPathComponent(name)))
        }
        if checkRawIntegrity {
            let exported = try Snapshot.manifest(destination)
            let originalEntry = try XCTUnwrap(before.entries.first)
            let copiedEntry = try XCTUnwrap(exported.entries.first)
            guard originalEntry.attributes[provenance] != copiedEntry.attributes[provenance] else {
                throw XCTSkip("This OS/creator pair did not produce distinct authentic provenance")
            }
            // A stale expected record from another authentic copy cannot excuse
            // a raw source mismatch, even though cross-copy fidelity allows it.
            var stale = before
            stale.entries[0].attributes[provenance] = copiedEntry.attributes[provenance]
            stale.entries[0].attributeBytes = originalEntry.attributeBytes - (originalEntry.provenanceBytes ?? 0) + (copiedEntry.provenanceBytes ?? 0)
            stale.entries[0].provenanceBytes = copiedEntry.provenanceBytes
            XCTAssertThrowsError(try Snapshot.copyTree(from: source, to: root.appendingPathComponent("stale-source-copy"), manifest: stale)) { error in
                XCTAssertTrue(error.localizedDescription.contains("com.apple.provenance"))
            }
            XCTAssertEqual(try Snapshot.manifest(source), before)
            let replacement = destination.appendingPathComponent("ordinary.txt")
            XCTAssertEqual(chmod(replacement.path, 0o600), 0)
            XCTAssertEqual(rename(replacement.path, data.appendingPathComponent("ordinary.txt").path), 0)
            XCTAssertThrowsError(try Snapshot.verified(store: store, id: folder.id, revision: revision)) { error in
                XCTAssertTrue(error.localizedDescription.contains("com.apple.provenance"))
            }
            XCTAssertEqual(try Snapshot.manifest(source), before)
            XCTAssertTrue(try rawAttributes(source, before) == attrs)
        }
    }
    func testCommittedCopyRejectsOtherMetadataAndContentTampering() throws {
        for field in ["ordinary-xattr", "extra-xattr", "quarantine", "content", "mode", "flags"] {
            let root = try fixture("committed-\(field)"), source = root.appendingPathComponent("source")
            try Store.privateDirectory(source)
            let original = source.appendingPathComponent("ordinary.txt")
            try Data("owned snapshot bytes".utf8).write(to: original)
            try QuarantineSnapshotScenarios.setAttribute(original, Data("before".utf8), "user.ramnest-control")
            try QuarantineSnapshotScenarios.setAttribute(original, QuarantineSnapshotScenarios.synthetic)
            let before = try Snapshot.manifest(source), attributes = try rawAttributes(source, before)
            let store = try Store(root: root.appendingPathComponent("store")), folder = try folder(source, store: store)
            let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
            let (data, _) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
            let file = data.appendingPathComponent("ordinary.txt")
            switch field {
            case "ordinary-xattr": try QuarantineSnapshotScenarios.setAttribute(file, Data("after".utf8), "user.ramnest-control")
            case "extra-xattr": try QuarantineSnapshotScenarios.setAttribute(file, Data("extra".utf8), "user.ramnest-extra")
            case "quarantine": try QuarantineSnapshotScenarios.setAttribute(file, Data("0081;65000000;RAMNestFixture;".utf8))
            case "content": try Data("changed snapshot bytes".utf8).write(to: file)
            case "mode": XCTAssertEqual(chmod(file.path, 0o644), 0)
            default: XCTAssertEqual(chflags(file.path, UInt32(UF_NODUMP)), 0)
            }
            XCTAssertThrowsError(try Snapshot.verified(store: store, id: folder.id, revision: revision), field)
            XCTAssertEqual(try Snapshot.manifest(source), before)
            XCTAssertTrue(try rawAttributes(source, before) == attributes)
        }
    }
    func testRelocationKeepsLegacyRevisionFilesAndExactCopyIntegrity() throws {
        let root = try fixture("relocation"), source = root.appendingPathComponent("selected")
        try Store.privateDirectory(source)
        try Data("owned relocation payload".utf8).write(to: source.appendingPathComponent("ordinary.txt"))
        let manager = SnapshotStorageManager(location: StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap")))
        let store = try manager.open(), folder = try folder(source, store: store)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        let (data, saved) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        // Construct an owned old-schema fixture before recording its immutable
        // bytes. Never migrate/rewrite an existing user's revision.
        var legacy = saved
        for i in legacy.entries.indices { legacy.entries[i].provenanceBytes = nil }
        legacy.publicRoot?.provenanceBytes = nil
        let manifestURL = data.deletingLastPathComponent().appendingPathComponent("manifest.json")
        try Store.atomicJSON(StoredManifest(legacy, modes: StorageModes(legacy)), manifestURL)
        let manifestBytes = try Data(contentsOf: manifestURL)
        let modeBytes = try Data(contentsOf: data.deletingLastPathComponent().appendingPathComponent("modes.bin"))
        _ = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        for name in ["first-parent", "second-parent"] {
            let parent = root.appendingPathComponent(name); try Store.privateDirectory(parent)
            let current = try manager.open()
            XCTAssertNil(try manager.move(store: current, toParent: parent).pending)
            let moved = try manager.open()
            let (target, expected) = try Snapshot.verified(store: moved, id: folder.id, revision: revision)
            XCTAssertEqual(try Data(contentsOf: target.deletingLastPathComponent().appendingPathComponent("manifest.json")), manifestBytes)
            XCTAssertEqual(try Data(contentsOf: target.deletingLastPathComponent().appendingPathComponent("modes.bin")), modeBytes)
            XCTAssertTrue(try Snapshot.manifest(target, context: .managedRevision).matchesExpected(expected))
            let export = root.appendingPathComponent("export-" + name)
            try Engine(store: moved).export(folder.id.uuidString, destination: export, revision: revision)
            XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("ordinary.txt")), Data("owned relocation payload".utf8))
        }
        let moved = try manager.open(), target = try Snapshot.dataURL(store: moved, id: folder.id, revision: revision)
        try QuarantineSnapshotScenarios.setAttribute(target.appendingPathComponent("ordinary.txt"), Data("tampered".utf8), "user.extra")
        XCTAssertThrowsError(try Snapshot.verified(store: moved, id: folder.id, revision: revision))
    }
    func testObservedProvenanceAccountingAndLegacyRecords() throws {
        guard let path = ProcessInfo.processInfo.environment["RAMNEST_PROVENANCE_CREATOR_ROOT"] else {
            throw XCTSkip("Authentic OS provenance fixture is required for accounting observation tests")
        }
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard source.path.hasPrefix(project.appendingPathComponent("artifacts/provenance-fix").path + "/") else { throw NestError("Accounting fixture must be project-owned") }
        let observed = try Snapshot.manifest(source)
        guard let index = observed.entries.firstIndex(where: { $0.hardlink == nil && $0.attributes[provenance] != nil }) else {
            throw XCTSkip("Authentic fixture has no OS-created provenance")
        }
        let entry = observed.entries[index]
        let bytes = try XCTUnwrap(QuarantineSnapshotScenarios.attribute(source.appendingPathComponent(entry.path), provenance))
        XCTAssertEqual(entry.provenanceBytes, UInt64(provenance.utf8.count + bytes.count))
        XCTAssertEqual(try JSONDecoder().decode(Manifest.self, from: JSONEncoder().encode(observed)), observed)
        // Exercise the numeric accounting seam with a different measured cost,
        // retaining an authentic digest; no private xattr is written or forged.
        var larger = observed
        larger.entries[index].provenanceBytes! += 1
        larger.entries[index].attributeBytes += 1
        XCTAssertTrue(try larger.matchesCopy(of: observed))
        XCTAssertFalse(larger.matchesExpected(observed))
        try observed.preflight(capacity: observed.allocatedEstimate)
        XCTAssertThrowsError(try larger.preflight(capacity: observed.allocatedEstimate))
        var unexplained = larger; unexplained.entries[index].attributeBytes += 1
        XCTAssertFalse(try unexplained.matchesCopy(of: observed))
        var unmeasured = observed; unmeasured.entries[index].provenanceBytes = nil
        XCTAssertThrowsError(try unmeasured.matchesCopy(of: observed))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(observed)) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        for i in entries.indices { entries[i].removeValue(forKey: "provenanceBytes") }
        object["entries"] = entries
        var root = object["publicRoot"] as? [String: Any]; root?.removeValue(forKey: "provenanceBytes"); object["publicRoot"] = root
        let legacy = try JSONDecoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(observed.matchesExpected(legacy))
        var wrongLegacy = legacy; wrongLegacy.entries[index].attributes.removeValue(forKey: provenance)
        XCTAssertFalse(observed.matchesExpected(wrongLegacy))
        let modes = try StorageModes(observed), stored = StoredManifest(observed, modes: modes)
        let decoded = try JSONDecoder().decode(StoredManifest.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded.logical, observed); XCTAssertEqual(decoded.modeMapDigest, Snapshot.digest(modes.encoded))
    }
    func testCaptureAuthenticOtherCreatorTreeWithoutChangingSource() throws {
        guard let path = ProcessInfo.processInfo.environment["RAMNEST_PROVENANCE_CREATOR_ROOT"] else {
            throw XCTSkip("Parent must supply an authentic other-creator tree under artifacts/provenance-fix; no provenance is fabricated")
        }
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard source.path.hasPrefix(project.appendingPathComponent("artifacts/provenance-fix").path + "/") else {
            throw NestError("Creator fixture must be inside artifacts/provenance-fix")
        }
        let before = try Snapshot.manifest(source), attrs = try rawAttributes(source, before)
        guard before.entries.contains(where: { $0.path == ".DS_Store" }),
              before.entries.contains(where: { $0.path == "ordinary.txt" }),
              attrs.values.contains(where: { $0[provenance] != nil }) else {
            throw XCTSkip("Authentic creator fixture requires .DS_Store, ordinary.txt and OS-created provenance")
        }
        let identities = try QuarantineSnapshotScenarios.unchangedIdentities(source, before)
        defer {
            XCTAssertEqual(try Snapshot.manifest(source), before)
            XCTAssertTrue(try rawAttributes(source, before) == attrs, "Other-creator raw source attributes changed")
            XCTAssertEqual(try QuarantineSnapshotScenarios.unchangedIdentities(source, before), identities)
        }
        let root = try fixture("reverse-capture"), store = try Store(root: root.appendingPathComponent("store"))
        let folder = try folder(source, store: store)
        let revision = try store.locked { try Snapshot.capture(store: store, folder: folder, source: source, previous: nil) }
        let (data, saved) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        XCTAssertEqual(try copyView(Snapshot.manifest(data, context: .managedRevision), at: data), try copyView(before, at: source))
        XCTAssertEqual(try copyView(saved, at: data), try copyView(before, at: source))
    }
}
#endif

enum QuarantineSnapshotScenarios {
    static let quarantine = "com.apple.quarantine"
    static let synthetic = Data("0281;65000000;RAMNestFixture;00000000-0000-0000-0000-000000000001".utf8)

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NestError("TEST: " + message) }
    }
    static func descriptor(_ url: URL) throws -> Int32 {
        var st = stat()
        try check(lstat(url.path, &st) == 0, "fixture entry exists")
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | (st.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
        try check(fd >= 0, "open fixture without following a symlink")
        return fd
    }
    static func attribute(_ url: URL, _ name: String = quarantine) throws -> Data? {
        let fd = try descriptor(url); defer { close(fd) }
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        if size < 0 && errno == ENOATTR { return nil }
        try check(size >= 0 && size <= 16 * 1024 * 1024, "read fixture xattr size: " + name)
        var data = Data(count: size)
        try check(data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, size, 0, 0) } == size, "read fixture xattr: " + name)
        return data
    }
    static func setAttribute(_ url: URL, _ value: Data, _ name: String = quarantine) throws {
        let fd = try descriptor(url); defer { close(fd) }
        try check(value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, value.count, 0, 0) } == 0, "set synthetic fixture xattr: " + name)
        try check(try attribute(url, name) == value, "OS must retain exact synthetic fixture xattr: " + name)
    }
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/scripts-snapshot-fix/fixtures-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let source = root.appendingPathComponent("minimal-source")
        try Store.privateDirectory(source)
        let file = source.appendingPathComponent("generated.txt")
        try Data("Generated inert quarantine fixture.\n".utf8).write(to: file)
        try setAttribute(file, synthetic)
        let before = try Snapshot.manifest(source)
        let copy = root.appendingPathComponent("minimal-copy")
        do { try Snapshot.copyTree(from: source, to: copy, manifest: before) }
        catch {
            try check(try attribute(file) == synthetic && Snapshot.manifest(source) == before, "failed copy leaves source bytes and attributes unchanged")
            if try attribute(copy.appendingPathComponent("generated.txt")) != synthetic {
                throw NestError("TEST: generated.txt xattr com.apple.quarantine differs after copy; source unchanged. \(error.localizedDescription)")
            }
            throw error
        }
        try check(try attribute(copy.appendingPathComponent("generated.txt")) == synthetic, "exact quarantine bytes copied")
        try check(try Snapshot.manifest(source) == before, "source bytes and attributes unchanged")
        print("PASS: minimal generated regular file preserves exact quarantine bytes and source metadata")
        try treeAndRecovery(root)
        try changedSource(root)
        for mode: mode_t in [0o750, 0o550] {
            try rootMetadataRecovery(root, mode: mode, interrupted: false)
            try rootMetadataRecovery(root, mode: mode, interrupted: true)
        }
    }

    static func unchangedIdentities(_ root: URL, _ manifest: Manifest) throws -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        for path in [""] + manifest.entries.map(\.path) {
            var st = stat()
            try check(lstat(root.appendingPathComponent(path).path, &st) == 0, "source root/entry remains")
            result[path] = [Int64(st.st_dev), Int64(st.st_ino), Int64(st.st_nlink), Int64(st.st_ctimespec.tv_sec), Int64(st.st_ctimespec.tv_nsec)]
        }
        return result
    }
    static func exactAttributes(_ source: URL, _ copy: URL, _ manifest: Manifest) throws {
        try check(try Snapshot.manifest(copy) == manifest, "full metadata, checksums and hardlink groups match")
        for entry in manifest.entries {
            for name in Set(entry.attributes.keys).union([quarantine]) {
                try check(try attribute(source.appendingPathComponent(entry.path), name) == attribute(copy.appendingPathComponent(entry.path), name), "exact xattr bytes/absence: \(entry.path) \(name)")
            }
        }
    }
    static func rejects(_ tokens: [String], _ body: () throws -> Void) throws {
        var message: String?
        do { try body() } catch { message = error.localizedDescription }
        guard let message else { throw NestError("TEST: expected verification rejection") }
        try check(tokens.allSatisfy { message.contains($0) }, "diagnostic identifies first mismatch path and field/xattr")
        try check(message.count < 700 && !message.contains("\n") && !message.contains("65000000") && !message.contains("Generated inert"), "bounded diagnostic excludes attribute values and file contents")
    }
    static func treeAndRecovery(_ root: URL) throws {
        let source = root.appendingPathComponent("tree-source")
        let nested = source.appendingPathComponent("nested/leaf")
        try Store.privateDirectory(nested)
        let file = source.appendingPathComponent("a-file.txt")
        let bytes = Data("Generated inert tree fixture.\n".utf8)
        try bytes.write(to: file)
        try setAttribute(file, synthetic)
        let custom = "user.ramnest-fixture"
        try setAttribute(file, Data([0, 1, 2, 255]), custom)
        var finderInfo = Data(repeating: 0, count: 32); finderInfo[0] = 0x54
        try setAttribute(file, finderInfo, "com.apple.FinderInfo")
        try setAttribute(file, Data("inert resource fork".utf8), "com.apple.ResourceFork")
        try check(chmod(file.path, 0o640) == 0, "set fixture file mode")
        let hardlink = source.appendingPathComponent("z-hard.txt")
        try check(link(file.path, hardlink.path) == 0, "create fixture hardlink")
        let absent = nested.appendingPathComponent("absent.txt")
        try Data("No quarantine on this generated file.\n".utf8).write(to: absent)
        try check(try attribute(absent) == nil, "fixture starts without quarantine")
        let readonly = nested.appendingPathComponent("readonly.txt")
        try bytes.write(to: readonly); try setAttribute(readonly, synthetic)
        try check(chmod(readonly.path, 0o444) == 0, "set read-only fixture mode")
        let matching = nested.appendingPathComponent("matching.txt")
        try bytes.write(to: matching)
        try setAttribute(matching, Data("0081;65000000;RAMNestFixture;".utf8))
        try setAttribute(nested, synthetic)
        try setAttribute(nested, Data("directory metadata".utf8), custom)
        let target = root.appendingPathComponent("symlink-target.txt")
        try Data("Generated target must remain unchanged.\n".utf8).write(to: target)
        let targetBytes = try Data(contentsOf: target)
        let targetAttrs = try Snapshot.attributes(target)
        let symlink = nested.appendingPathComponent("link")
        try check(Darwin.symlink("../../../symlink-target.txt", symlink.path) == 0, "create generated symlink")
        try setAttribute(symlink, synthetic)
        try check(chmod(nested.path, 0o550) == 0, "set read-only fixture directory mode")
        let expected = try Snapshot.manifest(source)
        let identities = try unchangedIdentities(source, expected)
        let copy = root.appendingPathComponent("tree-copy")
        try Snapshot.copyTree(from: source, to: copy, manifest: expected)
        try exactAttributes(source, copy, expected)
        let reused = root.appendingPathComponent("reused-copy")
        try Snapshot.copyTree(from: source, to: reused, manifest: expected, previous: copy, comparison: .sizeAndModTime)
        try exactAttributes(source, reused, expected)
        print("PASS: directory, symlink, hardlink, nested tree, read-only file, absent/matching quarantine and other xattrs")

        let selected = root.appendingPathComponent("selected")
        try Store.privateDirectory(selected)
        let identity = try DirectoryHandle.open(selected).identity()
        let folder = Folder(name: "Generated quarantine fixture", path: selected.path, capacity: 16 << 20, device: identity.device, inode: identity.inode)
        let store = try Store(root: root.appendingPathComponent("store"))
        var config = Configuration(); config.folders = [folder]; try store.save(config)
        let revision = try store.locked { try Snapshot.capture(store: store, folder: folder, source: source, previous: nil) }
        let (data, saved) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        try check(saved == expected, "capture retains original manifest schema and exact hashes")
        try check(try JSONDecoder().decode(Manifest.self, from: JSONEncoder().encode(saved)) == saved, "manifest JSON round trip remains compatible")
        var journal = Journal(); journal.phase = .pendingRestore; journal.populationVerified = true
        journal.revision = revision; journal.restoreRevision = revision
        try store.write(journal, for: folder.id)
        // No native helper, socket, mount or live store participates in this restore.
        let session = EngineSession(status: { _, _ in throw NestError("Generated fixture has no helper") })
        try Engine(store: store, session: session).recover(folder.id.uuidString)
        try exactAttributes(source, selected, expected)
        try check(try store.journal(folder.id).phase == .idle, "coordinator recovery commits verified restore")
        print("PASS: capture, verified snapshot and coordinator restore preserve exact quarantine and full manifests")

        let savedFile = data.appendingPathComponent("a-file.txt")
        let altered = Data("0081;65000000;RAMNestFixture;".utf8)
        try setAttribute(savedFile, altered)
        try rejects(["a-file.txt", quarantine]) { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
        try setAttribute(savedFile, synthetic)
        try setAttribute(savedFile, Data([9, 8, 7, 6]), custom)
        try rejects(["a-file.txt", custom]) { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
        try setAttribute(savedFile, Data([0, 1, 2, 255]), custom)
        let entry = expected.entries.first { $0.path == "a-file.txt" }!
        try Data(repeating: 0x4A, count: bytes.count).write(to: savedFile)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(entry.mtimeSeconds), tv_nsec: Int(entry.mtimeNanos))]
        try check(utimensat(AT_FDCWD, savedFile.path, &times, AT_SYMLINK_NOFOLLOW) == 0, "restore fixture mtime to isolate checksum tampering")
        try rejects(["a-file.txt", "checksum"]) { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
        try check(try Snapshot.manifest(source) == expected && unchangedIdentities(source, expected) == identities, "source bytes/attrs/inodes/link counts/ctime unchanged; no source attribute removal")
        try check(try Data(contentsOf: target) == targetBytes && Snapshot.attributes(target) == targetAttrs, "symlink metadata operations never touch target")
        print("PASS: quarantine, other-xattr and checksum tampering rejected with bounded field diagnostics; source untouched")
    }
    static func changedSource(_ root: URL) throws {
        let source = root.appendingPathComponent("changing-source")
        try Store.privateDirectory(source)
        let file = source.appendingPathComponent("changed.txt")
        try Data("Generated inert changed-source fixture.\n".utf8).write(to: file)
        try setAttribute(file, synthetic)
        let expected = try Snapshot.manifest(source)
        let changed = Data("0081;65000000;RAMNestFixture;".utf8)
        try setAttribute(file, changed)
        try rejects(["changed.txt", quarantine, "No source files were removed"]) {
            try Snapshot.copyTree(from: source, to: root.appendingPathComponent("stale-manifest-copy"), manifest: expected)
        }
        try check(try attribute(file) == changed, "stale manifest rejection retains changed source attribute")
        let unmarked = root.appendingPathComponent("unmarked-source")
        try Store.privateDirectory(unmarked)
        let unmarkedFile = unmarked.appendingPathComponent("added.txt")
        try Data("Generated inert unmarked fixture.\n".utf8).write(to: unmarkedFile)
        let unmarkedManifest = try Snapshot.manifest(unmarked)
        try setAttribute(unmarkedFile, synthetic)
        try rejects(["added.txt", quarantine, "No source files were removed"]) {
            try Snapshot.copyTree(from: unmarked, to: root.appendingPathComponent("added-attribute-copy"), manifest: unmarkedManifest)
        }
        try check(try attribute(unmarkedFile) == synthetic, "new source quarantine is never removed to match a stale manifest")
        print("PASS: changed/added source quarantine rejects stale manifests without removing attributes")
    }

    static func rootMetadataRecovery(_ root: URL, mode: mode_t, interrupted: Bool) throws {
        let fixture = root.appendingPathComponent("root-\(mode)-\(interrupted)")
        let source = fixture.appendingPathComponent("source"), selected = fixture.appendingPathComponent("selected")
        try Store.privateDirectory(source); try Store.privateDirectory(selected)
        let payload = Data("Owned root quarantine recovery bytes.\n".utf8)
        let file = source.appendingPathComponent("a-payload")
        try payload.write(to: file)
        try check(link(file.path, source.appendingPathComponent("z-alias").path) == 0, "root recovery hardlink fixture")
        try setAttribute(source, synthetic)
        try setAttribute(source, Data([0, 7, 255]), "user.ramnest-root")
        try check(chflags(source.path, UInt32(UF_HIDDEN | UF_NODUMP)) == 0, "supported public root flags")
        try check(chmod(source.path, mode) == 0, "public root writable/read-only mode")
        let expected = try Snapshot.manifest(source)
        let identities = try unchangedIdentities(source, expected)
        let sourceIdentity = try DirectoryHandle.open(source).identity()
        let store = try Store(root: fixture.appendingPathComponent("store"))
        let folder = try Engine(store: store).create(path: selected, name: "owned root", capacity: 16 << 20)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        let (committed, saved) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        try check(saved == expected && attribute(committed) == synthetic, "capture authenticates exact public root quarantine")
        let committedIdentity = try DirectoryHandle.open(committed).identity()
        let committedEntries = try unchangedIdentities(committed, saved)
        let engine = Engine(store: store, session: EngineSession(status: { _, _ in throw NestError("owned fixture has no helper") }))
        var journal = Journal(); journal.phase = .pendingRestore; journal.populationVerified = true
        journal.revision = revision; journal.restoreRevision = revision
        try store.write(journal, for: folder.id)
        let exported = fixture.appendingPathComponent("export")
        try engine.export(folder.id.uuidString, destination: exported)
        try check(try Snapshot.manifest(exported) == expected && attribute(exported) == synthetic,
                  "production export validates committed snapshot before recovery")
        if interrupted {
            #if RAMNEST_QUARANTINE_SNAPSHOT_STANDALONE && !RAMNEST_QUARANTINE_THROW_INTERRUPTION
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--interrupt-root-restore", store.root.path, folder.id.uuidString]
            try child.run(); child.waitUntilExit()
            try check(child.terminationReason == .exit && child.terminationStatus == 87, "actual process exit after durable rename before journal ACK")
            if mode & 0o200 == 0 {
                let journal = try store.journal(folder.id)
                let stage = URL(fileURLWithPath: journal.restoreStage!)
                var st = stat()
                try check(lstat(stage.appendingPathComponent("data").path, &st) == 0 && st.st_mode & 0o7777 == mode | 0o300,
                          "crash leaves only private staged root in temporary owner-writable mode")
                try check(FileManager.default.fileExists(atPath: stage.appendingPathComponent(".root-move-permissions").path),
                          "durable permission marker authorizes exact-mode restoration before retry integrity checks")
            }
            #else
            var injected = false
            store.beforeJournalWrite = { value, id in
                if id == folder.id && value.phase == .restoring && value.restoredEntries.count == 1 && !injected {
                    injected = true
                    throw NestError("owned move-before-journal interruption")
                }
            }
            var failure: String?
            do { try engine.recover(folder.id.uuidString) } catch { failure = error.localizedDescription }
            try check(injected && failure == "owned move-before-journal interruption", "deterministic durable-move interruption")
            #endif
            try check(FileManager.default.fileExists(atPath: selected.appendingPathComponent("a-payload").path), "first payload moved before interruption")
            try check(try store.journal(folder.id).phase == .restoring, "retry retains restoring journal")
            try check(try Snapshot.verified(store: store, id: folder.id, revision: revision).1 == expected, "interruption retains authenticated committed revision")
            store.beforeJournalWrite = nil
            if mode & 0o200 == 0 {
                let journal = try store.journal(folder.id)
                let data = URL(fileURLWithPath: journal.restoreStage!).appendingPathComponent("data")
                let fd = try descriptor(data); defer { close(fd) }
                try check(fchmod(fd, mode | 0o300) == 0, "owned staged-root corruption fixture permissions")
                let changed = Data("0081;65000000;RAMNestFixture;".utf8)
                try setAttribute(data, changed)
                var rejected = false
                do { try engine.recover(folder.id.uuidString) } catch {
                    rejected = error.localizedDescription.contains("Restore staging contents changed")
                }
                try check(rejected && attribute(data) == changed,
                          "permission replay never normalizes changed quarantine; strict root verification rejects before remaining moves")
                try check(!FileManager.default.fileExists(atPath: selected.appendingPathComponent("z-alias").path),
                          "root metadata corruption retains remaining staged payload")
                try check(fchmod(fd, mode | 0o300) == 0, "repair only owned synthetic staged-root attribute")
                try setAttribute(data, synthetic)
                try check(fchmod(fd, mode) == 0 && fsync(fd) == 0, "restore exact fixture mode before retry")
            }
        }
        try engine.recover(folder.id.uuidString)
        try check(try store.journal(folder.id).phase == .idle, "root quarantine recovery ends idle")
        try check(try Snapshot.manifest(selected) == expected && attribute(selected) == synthetic,
                  "root exact mode/flags/xattrs/quarantine and payload restored")
        try check(try Data(contentsOf: selected.appendingPathComponent("a-payload")) == payload, "root recovery payload bytes")
        try check(try Snapshot.manifest(source) == expected && unchangedIdentities(source, expected) == identities &&
                  DirectoryHandle.open(source).identity() == sourceIdentity, "source root and entries unchanged")
        try check(try Snapshot.verified(store: store, id: folder.id, revision: revision).1 == expected &&
                  DirectoryHandle.open(committed).identity() == committedIdentity && unchangedIdentities(committed, saved) == committedEntries,
                  "committed root and entries unchanged after export/recovery/retry")
        print("PASS: exact public-root quarantine capture/copy/export/recover mode=\(String(mode, radix: 8)) interrupted=\(interrupted); idle, hardlinks and source/revision retained")
    }
}
