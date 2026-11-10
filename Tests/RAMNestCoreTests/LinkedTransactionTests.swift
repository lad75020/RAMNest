import Foundation
import Darwin
#if !RAMNEST_METADATA_STANDALONE
import Testing
#endif
@testable import RAMNestCore

/// Disk-only construction of the persisted version-1 linked layout. The same
/// whole-root transaction implements native v2, but this fixture never mounts,
/// mocks a storage engine, invokes root code or relaxes production root policy.
final class LinkedTransactionDataFixture {
    let root: URL, selected: URL, store: Store, folder: Folder, mountRoot: URL
    var j = Journal()
    var boundary = EngineSession()
    var engine: Engine { Engine(store: store, session: boundary) }
    var expected = Manifest(entries: [])
    var workingExpected = Manifest(entries: [])
    init(_ parent: URL, _ name: String, temporary: Bool = false) throws {
        root = parent.appendingPathComponent(name + "-" + UUID().uuidString); try Store.privateDirectory(root)
        selected = root.appendingPathComponent("selected"); try Store.privateDirectory(selected)
        try Data("original".utf8).write(to: selected.appendingPathComponent("payload"))
        try FileManager.default.linkItem(at: selected.appendingPathComponent("payload"), to: selected.appendingPathComponent("alias"))
        let identity = try DirectoryHandle.open(selected).identity()
        var options = FolderOptions(); options.sync = !temporary
        folder = Folder(name: name, path: selected.path, capacity: 64 << 20, device: identity.device, inode: identity.inode, options: options)
        store = try Store(root: root.appendingPathComponent("store"))
        var config = Configuration(); config.folders = [folder]; try store.save(config)
        mountRoot = root.appendingPathComponent("RAMNest-Mounts-\(getuid())")
        store.linkedFixtureRoot = mountRoot; boundary.linkedMountRoot = mountRoot
    }
    func prepare() throws {
        expected = try Snapshot.manifest(selected)
        let sid = UUID()
        try Store.privateDirectory(mountRoot)
        let handle = try DirectoryHandle.open(mountRoot), slot = try handle.createDirectory(selected.lastPathComponent)
        var layout = LinkedFolderLayout(folderID: folder.id, session: sid, stage: .reserved,
            originalPath: selected.path, mountRoot: mountRoot.path, mountPath: mountRoot.appendingPathComponent(selected.lastPathComponent).path,
            holdingPath: root.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(sid.uuidString).original").path,
            linkStagePath: root.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(sid.uuidString).link").path,
            parent: try .init(DirectoryHandle.open(root).identity()), root: try .init(handle.identity()),
            mountpoint: try .init(slot.identity()), source: .init((folder.device, folder.inode)))
        layout.version = 1; try layout.validate()
        let revision = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil)
        j = Journal(); j.phase = .preparing; j.backend = .fskit; j.session = sid
        j.legacyLink = layout; j.initialRevision = revision; j.revision = revision; j.initialSourceManifest = expected
        try store.write(j, for: folder.id)
        let (data, manifest) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        let temporary = root.appendingPathComponent("population-copy")
        var copied = try Snapshot.copyTree(from: data, to: temporary, manifest: manifest, publicationStaging: true, sourceContext: .managedRevision)
        let from = try DirectoryHandle.open(temporary)
        for name in try from.names() { try from.renameNoReplace(name, to: slot, as: name) }
        copied.publicRoot = try Snapshot.preparePublicRoot(from: from, to: slot, selected: URL(fileURLWithPath: layout.mountPath), manifest: copied)
        if let mode = copied.publicRoot?.mode {
            guard fchmod(slot.fd, mode_t(mode)) == 0 else { throw NestError("Cannot finalize fixture public root mode") }
            try slot.sync()
        }
        workingExpected = copied
        guard try Snapshot.manifest(URL(fileURLWithPath: layout.mountPath), matching: copied).matchesExpected(copied) else { throw NestError("Fixture population copy changed") }
    }
    func evacuate() throws -> (DirectoryHandle, URL) { try engine.evacuateOriginal(folder, journal: &j, expected: expected) }
    func publish() throws {
        let original = j.managedLink!.originalDataURL
        try engine.verifyAndPublishPopulation(folder, journal: &j, expected: workingExpected,
            source: DirectoryHandle.open(original), original: original)
    }
    func discardWorkingCopy() throws {
        let directory = URL(fileURLWithPath: j.managedLink!.mountPath)
        for name in try DirectoryHandle.open(directory).names() { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }
}

#if !RAMNEST_METADATA_STANDALONE
extension RAMNestTestSuite {
    struct LinkedTransactionTests {
        private func parent() throws -> URL {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/linked-transactions")
            try Store.privateDirectory(root); return root
        }
        @Test(arguments: ["legacy", "legacy-split", "unmoved", "strict", "completed", "published", "missing-publication"])
        func `Initial rollback preserves legacy strict and receipt branches`(branch: String) throws {
            let f = try LinkedTransactionDataFixture(parent(), "rollback-" + branch, temporary: true)
            // Independent top-level files let the legacy split case retain a
            // strict raw partition without granting external-hardlink authority.
            try FileManager.default.removeItem(at: f.selected.appendingPathComponent("alias"))
            try Data("second".utf8).write(to: f.selected.appendingPathComponent("second"))
            let selected = try DirectoryHandle.open(f.selected)
            let expected = try Snapshot.manifest(f.selected)
            let revision = try Snapshot.capture(store: f.store, folder: f.folder, source: f.selected, previous: nil)
            let holdingURL = f.root.appendingPathComponent("originals")
            let holding = try DirectoryHandle.open(f.root).createDirectory("originals")
            let identity = try holding.identity()
            var j = Journal(); j.phase = .preparing; j.session = UUID()
            j.initialRevision = revision; j.revision = revision; j.initialSourceManifest = expected
            j.evacuation = holdingURL.path; j.evacuationDevice = identity.device; j.evacuationInode = identity.inode
            var evacuation = try VerifiedRenameReceipt(operation: .evacuation, folder: f.folder, journal: j,
                source: f.selected, destination: holding, matching: expected)
            j.evacuatedEntries = evacuation.names
            let before = try selected.entryStat("payload")
            if branch != "unmoved" {
                for name in evacuation.names where branch != "legacy-split" || name == "payload" {
                    try selected.renameNoReplace(name, to: holding, as: name)
                }
                try holding.sync(); try selected.sync()
            }
            if ["completed", "published", "missing-publication"].contains(branch) {
                try evacuation.complete(at: holdingURL)
            }
            if !branch.hasPrefix("legacy") { j.originalRename = evacuation }
            if branch == "published" || branch == "missing-publication" {
                var publication = try VerifiedRenameReceipt(operation: .rollback, folder: f.folder, journal: j,
                    source: holdingURL, destination: selected, matching: evacuation.after!.manifest)
                for name in publication.names { try holding.renameNoReplace(name, to: selected, as: name) }
                try holding.sync(); try selected.sync(); try publication.complete(at: f.selected)
                if branch == "published" { j.publicationRename = publication }
            }
            try f.store.write(j, for: f.folder.id)
            let journalURL = try f.store.volume(f.folder.id).appendingPathComponent("journal.json")
            let journalBefore = try Data(contentsOf: journalURL)
            var writes: [Journal] = []
            f.store.beforeJournalWrite = { next, _ in
                if branch == "completed", let publication = next.publicationRename {
                    let selectedNames = try selected.names()
                    let holdingNames = try holding.names()
                    if publication.after == nil {
                        #expect(selectedNames.isEmpty)
                        #expect(holdingNames == evacuation.names)
                    } else {
                        #expect(holdingNames.isEmpty)
                        #expect(selectedNames == evacuation.names)
                    }
                }
                writes.append(next)
            }
            defer { f.store.beforeJournalWrite = nil }
            if branch == "missing-publication" {
                #expect(throws: (any Error).self) { try f.engine.rollbackInitial(f.folder, journal: &j) }
                #expect(writes.isEmpty)
                #expect(try Data(contentsOf: journalURL) == journalBefore)
            } else {
                try f.engine.rollbackInitial(f.folder, journal: &j)
                #expect(j.phase == .idle && j.lastError == nil && j.socket == nil && j.mountedDevice == nil)
                #expect(j.restoreRevision == nil && j.originalRename == nil && j.publicationRename == nil)
                let publicationWrites = writes.filter { $0.publicationRename != nil }
                if branch == "completed" {
                    #expect(publicationWrites.count == 2)
                    #expect(publicationWrites.first?.publicationRename?.after == nil)
                    #expect(publicationWrites.last?.publicationRename?.after != nil)
                    #expect(writes.firstIndex(where: { $0.phase == .idle }) == 2)
                } else { #expect(publicationWrites.isEmpty) }
                let idle = try #require(writes.first(where: { $0.phase == .idle }))
                #expect(idle.restoreRevision == revision)
                #expect(idle.originalRename == nil && idle.publicationRename == nil)
                #expect(idle.siblingCleanup?.first?.path == holdingURL.path)
                #expect(idle.siblingCleanup?.first?.completedRevision == revision)
            }
            #expect(try Snapshot.manifest(f.selected).matchesExpected(expected))
            #expect(try selected.entryStat("payload").st_ino == before.st_ino)
        }

        @Test func `Rollback without an initial revision retains its early-exit fields`() throws {
            let f = try LinkedTransactionDataFixture(parent(), "no-initial", temporary: true)
            let expected = try Snapshot.manifest(f.selected)
            var j = Journal(); j.phase = .preparing; j.socket = f.root.appendingPathComponent("unused.sock").path
            j.lastError = "previous diagnostic"
            try f.store.write(j, for: f.folder.id)
            let before = j
            try f.engine.rollbackInitial(f.folder, journal: &j)
            var expectedJournal = before; expectedJournal.phase = .idle
            #expect(j == expectedJournal)
            #expect(try Snapshot.manifest(f.selected) == expected)
            #expect(try DirectoryHandle.open(f.selected).identity() == (f.folder.device, f.folder.inode))
        }

        @Test func `Reserved linked original exits before materialization and publication`() throws {
            let f = try LinkedTransactionDataFixture(parent(), "unmoved-linked", temporary: true)
            try f.prepare(); try f.discardWorkingCopy()
            var writes: [Journal] = []
            f.store.beforeJournalWrite = { next, _ in writes.append(next) }
            defer { f.store.beforeJournalWrite = nil }
            try f.engine.recover(f.folder.id.uuidString)
            let first = try #require(writes.first)
            #expect(first.managedLink?.stage == .restored && first.managedLink?.restoration == .original)
            #expect(first.restoreRevision == f.j.initialRevision)
            #expect(writes.allSatisfy { $0.restoreStage == nil && $0.publicationRename == nil })
            #expect(try f.store.journal(f.folder.id).phase == .idle)
            #expect(try DirectoryHandle.open(f.selected).identity() == (f.folder.device, f.folder.inode))
            #expect(try Snapshot.manifest(f.selected).matchesExpected(f.expected))
        }

        @Test func `Whole-root publication and temporary rollback preserve original inodes and metadata`() throws {
            let f = try LinkedTransactionDataFixture(parent(), "temporary", temporary: true)
            try f.prepare()
            let before = try VerifiedRenameReceipt.observe(f.selected)
            let (_, holding) = try f.evacuate()
            #expect(try DirectoryHandle.open(holding).identity() == (f.folder.device, f.folder.inode))
            #expect(try Snapshot.manifest(holding).matchesCopy(of: before.manifest))
            try f.publish()
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.selected.path) == f.j.managedLink!.mountPath)
            try f.discardWorkingCopy(); try f.engine.recover(f.folder.id.uuidString)
            #expect(try DirectoryHandle.open(f.selected).identity() == (f.folder.device, f.folder.inode))
            #expect(try Snapshot.manifest(f.selected).matchesExpected(f.expected))
            #expect(try f.store.journal(f.folder.id).phase == .idle)
        }
        @Test(arguments: ["content", "old-fd", "source-entry", "holding-entry", "replacement", "xattr", "root-mode"])
        func `Rename window rejects changed source authority`(mutation: String) throws {
            let f = try LinkedTransactionDataFixture(parent(), mutation); try f.prepare()
            let writer = open(f.selected.appendingPathComponent("payload").path, O_WRONLY | O_NOFOLLOW)
            #expect(writer >= 0); defer { close(writer) }
            f.boundary.afterOriginalRenames = { selected, holding in
                switch mutation {
                case "content": try Data("changed".utf8).write(to: holding.appendingPathComponent("payload"))
                case "old-fd":
                    let bytes = Data("descriptor-change".utf8)
                    #expect(bytes.withUnsafeBytes { pwrite(writer, $0.baseAddress, bytes.count, 0) } == bytes.count)
                    #expect(fsync(writer) == 0)
                case "source-entry": try Store.privateDirectory(selected); try Data("unknown".utf8).write(to: selected.appendingPathComponent("foreign"))
                case "holding-entry": try Data("unknown".utf8).write(to: holding.appendingPathComponent("foreign"))
                case "replacement": try FileManager.default.moveItem(at: holding, to: holding.appendingPathExtension("retained")); try Store.privateDirectory(holding)
                case "xattr": #expect(setxattr(holding.appendingPathComponent("payload").path, "user.fixture", "x", 1, 0, 0) == 0)
                default: #expect(chmod(holding.path, 0o750) == 0)
                }
            }
            #expect(throws: (any Error).self) { try f.evacuate() }
            #expect(!f.j.populationVerified)
            #expect(try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.j.initialRevision!).1 == f.expected)
        }
        @Test func `Old descriptor write after evacuation blocks publication without weakening content checks`() throws {
            let f = try LinkedTransactionDataFixture(parent(), "late-writer"); try f.prepare()
            let writer = open(f.selected.appendingPathComponent("payload").path, O_WRONLY | O_NOFOLLOW)
            #expect(writer >= 0); defer { close(writer) }
            _ = try f.evacuate()
            #expect(pwrite(writer, "changed!", 8, 0) == 8 && fsync(writer) == 0)
            #expect(throws: (any Error).self) { try f.publish() }
            #expect(!f.j.populationVerified && f.j.phase == .recoveryRequired)
            #expect(!FileManager.default.fileExists(atPath: f.selected.path))
        }
        @Test func `Foreign original-path link remains untouched during recovery`() throws {
            let f = try LinkedTransactionDataFixture(parent(), "foreign-link", temporary: true); try f.prepare()
            _ = try f.evacuate(); try f.publish(); try f.discardWorkingCopy()
            let other = f.root.appendingPathComponent("outside"); try Store.privateDirectory(other)
            try Data("keep".utf8).write(to: other.appendingPathComponent("sentinel"))
            #expect(unlink(f.selected.path) == 0); try FileManager.default.createSymbolicLink(at: f.selected, withDestinationURL: other)
            #expect(throws: (any Error).self) { try f.engine.recover(f.folder.id.uuidString) }
            #expect(try Data(contentsOf: other.appendingPathComponent("sentinel")) == Data("keep".utf8))
        }
    }
}

#endif
