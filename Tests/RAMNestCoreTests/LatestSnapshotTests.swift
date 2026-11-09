import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_LATEST_SNAPSHOT_STANDALONE
import Testing
extension RAMNestTestSuite {
    struct LatestSnapshotTests {
        @Test func `Latest snapshot retention`() throws { try LatestSnapshotScenarios.run() }
    }
}
#endif

enum LatestSnapshotScenarios {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NestError("TEST: " + message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try check(rejected, "expected a controlled failure")
    }
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/latest-snapshot/fixtures-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        print("Fixtures: \(root.path)")
        let selected = root.appendingPathComponent("selected")
        try Store.privateDirectory(selected)
        let store = try Store(root: root.appendingPathComponent("store"))
        let engine = Engine(store: store)
        let folder = try engine.create(path: selected, name: "Owned retention fixture", capacity: 16 << 20)
        let file = selected.appendingPathComponent("payload")
        try Data("first".utf8).write(to: file)
        let first = try store.locked { try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil) }
        try Data("latest".utf8).write(to: file)
        let latest = try store.locked { try Snapshot.capture(store: store, folder: folder, source: selected, previous: first) }
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original-payload"))
        var journal = Journal()
        journal.phase = .pendingRestore; journal.populationVerified = true
        journal.revision = latest; journal.priorRevision = first
        journal.initialRevision = first; journal.restoreRevision = latest
        try store.write(journal, for: folder.id)
        try engine.recover(folder.id.uuidString)
        try check(try String(contentsOf: file, encoding: .utf8) == "latest", "recovery restores latest bytes")
        _ = try Snapshot.verified(store: store, id: folder.id, revision: latest)
        let firstData = try Snapshot.dataURL(store: store, id: folder.id, revision: first)
        try check(!FileManager.default.fileExists(atPath: firstData.deletingLastPathComponent().path), "successful idle recovery must retire the obsolete committed revision")
        let saved = try store.journal(folder.id)
        try check(saved.phase == .idle && saved.revision == latest && saved.priorRevision == nil && saved.initialRevision == nil && saved.restoreRevision == nil, "idle recovery clears obsolete transaction references")
        print("PASS: idle recovery retains only the latest verified committed revision and clears obsolete references")
        try mountedSaves(root)
        try transactionPins(root)
        try failurePreservation(root)
        try conservativeCleanup(root)
        try anchoredSafety(root)
        print("PASS: all latest-snapshot retention scenarios")
    }

    // Ordinary disk data for snapshot/retention tests, never a mock storage
    // engine or an alternate helper execution path. Native coherence has its
    // own kernel observation/freeze transaction and exact-package tests.
    final class CheckpointSource {
        let source: URL
        var identityValid = true, failCapture = false
        var captures = 0
        var afterCapture: (() throws -> Void)?
        var beforeValidation: (() throws -> Void)?
        init(source: URL) { self.source = source }
    }
    final class Fixture {
        let root: URL, selected: URL, store: Store, folder: Folder, engine: Engine, data: CheckpointSource, initial: String
        init(_ parent: URL, _ name: String, temporary: Bool = false) throws {
            root = parent.appendingPathComponent(name); try Store.privateDirectory(root)
            selected = root.appendingPathComponent("selected"); try Store.privateDirectory(selected)
            store = try Store(root: root.appendingPathComponent("store"))
            var options = FolderOptions(); options.sync = !temporary
            let identity = try DirectoryHandle.open(selected).identity()
            folder = Folder(name: name, path: selected.path, capacity: 16 << 20, device: identity.device, inode: identity.inode, options: options)
            var config = Configuration(); config.folders = [folder]; try store.save(config)
            try Data("original".utf8).write(to: selected.appendingPathComponent("payload"))
            initial = try store.locked { [store, folder, selected] in try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil) }
            let holding = root.appendingPathComponent("originals"); try Store.privateDirectory(holding)
            let holdingHandle = try DirectoryHandle.open(holding)
            try DirectoryHandle.open(selected).renameNoReplace("payload", to: holdingHandle, as: "payload")
            let live = root.appendingPathComponent("live"); try Store.privateDirectory(live)
            try Data("original".utf8).write(to: live.appendingPathComponent("payload"))
            data = CheckpointSource(source: live)
            engine = Engine(store: store)
            var j = Journal(); j.phase = .mounted; j.revision = initial; j.initialRevision = initial
            j.populationVerified = true // historical data journal only; no helper/socket/mount
            j.evacuation = holding.path; j.evacuatedEntries = ["payload"]
            let h = try holdingHandle.identity(); j.evacuationDevice = h.device; j.evacuationInode = h.inode
            try store.write(j, for: folder.id)
        }
        func exists(_ revision: String) throws -> Bool {
            FileManager.default.fileExists(atPath: try Snapshot.dataURL(store: store, id: folder.id, revision: revision).deletingLastPathComponent().path)
        }
        func captureSource(cleanup: Bool = true) throws -> String {
            do {
                try data.beforeValidation?()
                guard data.identityValid, !data.failCapture else { throw NestError("Injected data source/capture failure", code: 6) }
                let revision = try Snapshot.capture(store: store, folder: folder, source: data.source, previous: store.journal(folder.id).revision)
                data.captures += 1; try data.afterCapture?()
                var j = try store.journal(folder.id)
                SnapshotRetention.remember(&j); j.priorRevision = j.revision; j.revision = revision; j.lastError = nil
                try store.write(j, for: folder.id)
                if cleanup { try retention() }
                return revision
            } catch {
                if var j = try? store.journal(folder.id) { j.lastError = error.localizedDescription; try? store.write(j, for: folder.id) }
                throw error
            }
        }
        func retention() throws {
            var j = try store.journal(folder.id)
            SnapshotRetention.clean(store: store, folder: folder, journal: &j, validateSource: {
                try self.data.beforeValidation?()
                guard self.data.identityValid else { throw NestError("Data source identity changed", code: 6) }
                _ = try DirectoryHandle.open(self.data.source)
            })
        }
        func save(_ value: String) throws -> String {
            try Data(value.utf8).write(to: data.source.appendingPathComponent("payload"))
            return try captureSource()
        }
        func verify(_ revision: String, _ value: String) throws {
            let (data, _) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
            try check(try String(contentsOf: data.appendingPathComponent("payload"), encoding: .utf8) == value, "retained snapshot must contain the latest bytes")
        }
        func editJournal(_ edit: (inout Journal) throws -> Void) throws {
            try store.locked {
                var j = try store.journal(folder.id); try edit(&j); try store.write(j, for: folder.id)
            }
        }
        func finish() throws {
            if folder.options.sync { _ = try captureSource(cleanup: false) }
            try editJournal {
                SnapshotRetention.remember(&$0)
                $0.phase = .pendingRestore; $0.restoreRevision = $0.revision; $0.socket = nil
            }
            try engine.recover(folder.id.uuidString)
        }
        func revisionURL(_ revision: String) throws -> URL {
            try Snapshot.dataURL(store: store, id: folder.id, revision: revision).deletingLastPathComponent()
        }
        func cleanupExport() throws {
            try engine.export(folder.id.uuidString, destination: root.appendingPathComponent("export-\(UUID().uuidString)"))
            if try store.journal(folder.id).phase == .mounted { try retention() }
        }
    }
    static func mountedSaves(_ root: URL) throws {
        let f = try Fixture(root, "mounted-saves")
        let one = try f.save("one"), two = try f.save("two"), three = try f.save("three")
        try check(try !f.exists(one) && !f.exists(two) && f.exists(three) && f.exists(f.initial), "three saves keep latest and the actual mounted initial anchor")
        try f.verify(three, "three"); try f.verify(f.initial, "original")
        try check(f.data.captures == 3, "three independent verified data captures precede retention")
        print("PASS: three verified snapshot captures retire intermediate commits and verify latest plus initial anchor")
        var message = ""
        do { try f.engine.export(f.folder.id.uuidString, destination: f.root.appendingPathComponent("pruned-export"), revision: one) }
        catch { message = error.localizedDescription }
        try check(message.localizedCaseInsensitiveContains("not retained"), "explicit export of a pruned revision must clearly say not retained; got: \(message)")
        print("PASS: explicit pruned-revision export returns a clear not-retained error")
    }
    static func transactionPins(_ root: URL) throws {
        let f = try Fixture(root, "restore-pins")
        let restore = try f.save("actual transaction revision")
        try f.editJournal { $0.restoreRevision = restore }
        let obsolete = try f.save("intermediate")
        let latest = try f.save("latest mounted")
        try check(try f.exists(restore) && f.exists(f.initial) && f.exists(latest) && !f.exists(obsolete), "only actual restore/initial pins survive mounted saves")
        try f.finish()
        let idle = try f.store.journal(f.folder.id)
        let kept = idle.revision!
        try f.verify(kept, "latest mounted")
        try check(try !f.exists(restore) && !f.exists(f.initial) && !f.exists(latest), "successful finalize drops obsolete transaction anchors")
        try check(idle.phase == .idle && idle.initialRevision == nil && idle.restoreRevision == nil && idle.priorRevision == nil && idle.retiringRevisions == nil, "idle references all clear")
        try check(f.data.captures == 4, "disk publication consumes a fresh committed checkpoint; native unmount behavior is tested separately")
        print("PASS: mounted actual restore anchor survives; successful disk recovery leaves one committed revision")

        let temp = try Fixture(root, "temporary-pins", temporary: true)
        let originalStat = try DirectoryHandle.open(temp.root.appendingPathComponent("originals")).entryStat("payload")
        var exports: [String] = []
        for value in ["temporary one", "temporary two"] {
            _ = try temp.save(value)
            try temp.engine.export(temp.folder.id.uuidString, destination: temp.root.appendingPathComponent(value))
            exports.append(try temp.store.journal(temp.folder.id).revision!)
        }
        try check(try temp.exists(temp.initial) && !temp.exists(exports[0]), "temporary exports retain original anchor and retire superseded rescue snapshot")
        try rejects { try temp.engine.save(temp.folder.id.uuidString) }
        try temp.finish()
        let restoredStat = try DirectoryHandle.open(temp.selected).entryStat("payload")
        try check(restoredStat.st_ino == originalStat.st_ino, "temporary rollback restores original inode after exports")
        try check(try String(contentsOf: temp.selected.appendingPathComponent("payload"), encoding: .utf8) == "original", "temporary rollback discards live modifications")
        try check(try !temp.exists(temp.initial) && temp.exists(exports[1]), "temporary rollback releases initial anchor, retaining latest explicit rescue snapshot")
        try check(temp.data.captures == 2, "temporary disk rollback creates no new checkpoint")
        try temp.verify(exports[1], "temporary two")
        print("PASS: live exports preserve temporary-eject anchor; idle rollback restores original inode and clears pins")
    }
    static func failurePreservation(_ root: URL) throws {
        let failed = try Fixture(root, "failed-save")
        let before = try failed.save("last good")
        failed.data.failCapture = true
        try rejects { _ = try failed.save("not committed") }
        try check(try failed.exists(before) && failed.exists(failed.initial), "failed data capture preserves every committed revision")
        try failed.verify(before, "last good")
        try check(try failed.store.journal(failed.folder.id).lastError != nil, "save error remains visible")

        let writeFailure = try Fixture(root, "journal-write-failure")
        let old = try writeFailure.save("durable before failed journal")
        let journalURL = try writeFailure.store.volume(writeFailure.folder.id).appendingPathComponent("journal.json")
        let journalBackup = writeFailure.root.appendingPathComponent("saved-journal.json")
        writeFailure.data.afterCapture = {
            try FileManager.default.moveItem(at: journalURL, to: journalBackup)
            try Store.privateDirectory(journalURL) // rename of the new journal fails with EISDIR.
        }
        try rejects { _ = try writeFailure.save("snapshot without committed journal") }
        try check(try writeFailure.exists(old) && writeFailure.exists(writeFailure.initial), "journal promotion failure cannot retire old committed snapshots")
        try writeFailure.verify(old, "durable before failed journal")
        let backup = try Store.read(Journal.self, journalBackup)
        try check(backup.revision == old, "last durable journal still selects old snapshot")
        print("PASS: data capture and actual journal rename failures retain prior good snapshots")

        let cleanupWrite = try Fixture(root, "cleanup-journal-write-failure")
        let cleanupOld = try cleanupWrite.save("keep before cleanup write failure")
        let volume = try cleanupWrite.store.volume(cleanupWrite.folder.id)
        var statusCalls = 0
        cleanupWrite.data.beforeValidation = {
            statusCalls += 1
            // The second status is the cleanup source check, after both save
            // journal writes have succeeded. Make only cleanup writes fail.
            if statusCalls == 2 { try check(chmod(volume.path, 0o500) == 0, "make cleanup journal unwritable") }
        }
        defer { _ = chmod(volume.path, 0o700) }
        let committed = try cleanupWrite.save("successful save, failed cleanup journal")
        try check(try cleanupWrite.exists(cleanupOld) && cleanupWrite.exists(cleanupWrite.initial), "cleanup journal failure must precede any deletion")
        try cleanupWrite.verify(committed, "successful save, failed cleanup journal")
        try check(try cleanupWrite.store.journal(cleanupWrite.folder.id).lastError == nil, "cleanup journal failure cannot turn a successful save into a recovery error")
        try check(chmod(volume.path, 0o700) == 0, "restore owned fixture permissions")
        print("PASS: actual cleanup journal write failure preserves old revisions without failing the committed save")

        let corrupt = try Fixture(root, "corrupt-latest")
        let bad = try corrupt.save("last valid bytes")
        let payload = try Snapshot.dataURL(store: corrupt.store, id: corrupt.folder.id, revision: bad).appendingPathComponent("payload")
        try Data("corrupt".utf8).write(to: payload)
        try corrupt.editJournal { $0.phase = .idle; $0.socket = nil }
        try corrupt.engine.recover(corrupt.folder.id.uuidString)
        try check(try corrupt.exists(corrupt.initial) && corrupt.exists(bad), "corrupt retained latest blocks all cleanup")
        try check(try corrupt.store.journal(corrupt.folder.id).cleanupWarning != nil, "corrupt latest surfaces cleanup warning")
        try rejects { try corrupt.cleanupExport() }
        let corruptJournalURL = try corrupt.store.volume(corrupt.folder.id).appendingPathComponent("journal.json")
        try Data("{broken journal".utf8).write(to: corruptJournalURL)
        try rejects { try corrupt.engine.recover(corrupt.folder.id.uuidString) }
        try check(try corrupt.exists(corrupt.initial) && corrupt.exists(bad), "corrupt journal cannot trigger cleanup")
        print("PASS: corrupt latest checksum or journal blocks deletion and retains recovery data")

        let restoring = try Fixture(root, "restore-failure")
        let newest = try restoring.save("restore me")
        try restoring.editJournal { $0.phase = .restoring; $0.restoreRevision = newest }
        try Data("unknown writer".utf8).write(to: restoring.selected.appendingPathComponent("unrelated"))
        try rejects { try restoring.engine.finalize(restoring.folder.id.uuidString) }
        let recoveryError = try restoring.store.journal(restoring.folder.id).lastError
        try restoring.cleanupExport()
        try check(try restoring.exists(restoring.initial) && restoring.exists(newest), "failed mid-restore retains every committed snapshot")
        try check(try restoring.store.journal(restoring.folder.id).lastError == recoveryError && recoveryError != nil, "export/cleanup must not replace recovery errors")
        // The same non-pruning gate applies to every transitional/uncertain phase.
        for phase in [Phase.preparing, .evacuated, .mounting, .ejecting, .pendingRestore, .restoring, .recoveryRequired] {
            try restoring.editJournal { $0.phase = phase; $0.lastError = nil }
            try restoring.cleanupExport()
            try check(try restoring.exists(restoring.initial), "no pruning in phase \(phase.rawValue)")
        }
        print("PASS: failed/mid-restore and every uncertain transaction phase retain all snapshots and recovery errors")

        let uncertain = try Fixture(root, "uncertain-mount")
        let oldLatest = try uncertain.save("old latest")
        uncertain.data.afterCapture = { uncertain.data.identityValid = false }
        let unpruned = try uncertain.save("committed with uncertain mount")
        try check(try uncertain.exists(oldLatest) && uncertain.exists(unpruned) && uncertain.exists(uncertain.initial), "mount identity uncertainty disables cleanup")
        print("PASS: cleanup rechecks mounted identity after commit and skips uncertain sources")

        let corruptAnchor = try Fixture(root, "corrupt-mounted-anchor")
        let previousLatest = try corruptAnchor.save("valid previous latest")
        try Data("CORRUPT!".utf8).write(to: corruptAnchor.revisionURL(corruptAnchor.initial).appendingPathComponent("data/payload"))
        let newLatest = try corruptAnchor.save("valid new latest")
        try check(try corruptAnchor.exists(previousLatest) && corruptAnchor.exists(newLatest), "damaged retained initial anchor blocks all retirement")
        try check(try corruptAnchor.store.journal(corruptAnchor.folder.id).cleanupWarning != nil, "damaged mounted anchor is a separate warning")
        print("PASS: checksum verification of every retained anchor precedes cleanup")
    }
    static func conservativeCleanup(_ root: URL) throws {
        let f = try Fixture(root, "unknown-and-partial")
        let revisions = try f.revisionURL(f.initial).deletingLastPathComponent()
        let unknown = revisions.appendingPathComponent("manual-recovery")
        let partial = revisions.appendingPathComponent(UUID().uuidString)
        try Store.privateDirectory(unknown); try Store.privateDirectory(partial)
        try Data("keep unknown".utf8).write(to: unknown.appendingPathComponent("sentinel"))
        try Data("failed capture".utf8).write(to: partial.appendingPathComponent("partial"))
        // Even a complete capture that was never journal-committed is unknown.
        let orphan = try f.store.locked { try Snapshot.capture(store: f.store, folder: f.folder, source: f.data.source, previous: nil) }
        let stage = try f.store.volume(f.folder.id).appendingPathComponent("stage-owned-partial")
        try Store.privateDirectory(stage)
        _ = try f.save("kept")
        try f.finish()
        try check(try f.exists(orphan) && FileManager.default.fileExists(atPath: partial.path) && FileManager.default.fileExists(atPath: unknown.appendingPathComponent("sentinel").path) && FileManager.default.fileExists(atPath: stage.path), "unknown/partial/stage/uncommitted captures are never scanned or purged")
        print("PASS: unknown names, partial UUID captures, complete uncommitted captures, and helper stages are retained")

        let startup = try Fixture(root, "no-eager-startup")
        let known = try startup.store.locked { try Snapshot.capture(store: startup.store, folder: startup.folder, source: startup.data.source, previous: nil) }
        try startup.editJournal { $0.priorRevision = known }
        let reopened = try Store(root: startup.store.root)
        let observer = Engine(store: reopened)
        _ = try observer.statuses()
        try check(try startup.exists(known), "opening a store and reading status must not clean up")
        try startup.cleanupExport()
        try check(try !startup.exists(known), "legacy journal references are cleaned at next safe operation")
        print("PASS: legacy journals remain readable; store open/status never prune; next safe operation cleans known references")

        for kind in ["corrupt-manifest", "corrupt-payload", "unexpected-entry", "read-only-data"] {
            let x = try Fixture(root, kind)
            let initial = try x.revisionURL(x.initial)
            if kind == "corrupt-manifest" { try Data("broken".utf8).write(to: initial.appendingPathComponent("manifest.json")) }
            if kind == "corrupt-payload" { try Data("CORRUPT!".utf8).write(to: initial.appendingPathComponent("data/payload")) }
            if kind == "unexpected-entry" { try Data("unknown".utf8).write(to: initial.appendingPathComponent("data/unexpected")) }
            if kind == "read-only-data" { try check(chmod(initial.appendingPathComponent("data").path, 0o500) == 0, "set owned cleanup failure fixture mode") }
            // Finalization does not require the old initial snapshot in sync mode.
            try Data("successful latest".utf8).write(to: x.data.source.appendingPathComponent("payload"))
            try x.finish()
            let j = try x.store.journal(x.folder.id)
            try check(j.phase == .idle && j.lastError == nil && j.cleanupWarning != nil, "cleanup failure is a warning after successful restore: \(kind)")
            try check(try x.exists(x.initial), "unexpected/failed obsolete candidate remains: \(kind)")
            try x.verify(j.revision!, "successful latest")
            if kind == "read-only-data" {
                try check(chmod(initial.appendingPathComponent("data").path, 0o700) == 0, "restore owned fixture mode")
                try x.engine.recover(x.folder.id.uuidString)
                try check(try !x.exists(x.initial) && x.store.journal(x.folder.id).cleanupWarning == nil, "next safe operation retries failed cleanup")
            }
        }
        print("PASS: corrupt/unexpected old revisions and actual unlink permission failures are nonfatal warnings; safe retry succeeds")
    }
    static func anchoredSafety(_ root: URL) throws {
        let symlink = try Fixture(root, "symlink-candidate")
        let outside = symlink.root.appendingPathComponent("outside"); try Store.privateDirectory(outside)
        let sentinel = outside.appendingPathComponent("sentinel"); try Data("outside survives".utf8).write(to: sentinel)
        let initial = try symlink.revisionURL(symlink.initial)
        try FileManager.default.moveItem(at: initial, to: symlink.root.appendingPathComponent("retained-original-revision"))
        try FileManager.default.createSymbolicLink(at: initial, withDestinationURL: outside)
        try symlink.finish()
        try check(try String(contentsOf: sentinel, encoding: .utf8) == "outside survives", "UUID symlink candidate cannot redirect deletion")
        try check(try symlink.store.journal(symlink.folder.id).cleanupWarning != nil, "symlink candidate reports skipped cleanup")

        let leaf = try Fixture(root, "symlink-leaf")
        let leafOutside = leaf.root.appendingPathComponent("outside"); try Store.privateDirectory(leafOutside)
        let leafSentinel = leafOutside.appendingPathComponent("sentinel"); try Data("leaf target survives".utf8).write(to: leafSentinel)
        // A recognized committed snapshot may legitimately contain symlink leaves.
        let source = leaf.root.appendingPathComponent("symlink-source"); try Store.privateDirectory(source)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside-link"), withDestinationURL: leafOutside)
        let revision = try leaf.store.locked { try Snapshot.capture(store: leaf.store, folder: leaf.folder, source: source, previous: nil) }
        try leaf.editJournal { $0.priorRevision = revision }
        try leaf.finish()
        try check(try !leaf.exists(revision) && String(contentsOf: leafSentinel, encoding: .utf8) == "leaf target survives", "deletion unlinks a recognized symlink leaf without traversing its target")
        print("PASS: UUID symlink candidates are rejected; symlink leaves never follow outside targets")

        for component in ["root", "ancestor"] {
            let x = try Fixture(root, "symlink-\(component)")
            let path = component == "root" ? x.store.root : x.store.root.appendingPathComponent("volumes")
            let moved = x.root.appendingPathComponent("moved-\(component)")
            let outside = x.root.appendingPathComponent("outside-\(component)"); try Store.privateDirectory(outside)
            let sentinel = outside.appendingPathComponent("sentinel"); try Data("untouched".utf8).write(to: sentinel)
            try x.store.locked {
                var j = try x.store.journal(x.folder.id)
                try FileManager.default.moveItem(at: path, to: moved)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
                SnapshotRetention.clean(store: x.store, folder: x.folder, journal: &j, validateSource: {})
            }
            try check(try String(contentsOf: sentinel, encoding: .utf8) == "untouched", "symlink \(component) cannot redirect cleanup")
            try check(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["sentinel"], "unsafe ancestors cannot receive warning journal writes")
        }
        // A newer recovery journal must not be overwritten by a stale cleanup.
        let stale = try Fixture(root, "stale-journal")
        try stale.store.locked {
            var j = try stale.store.journal(stale.folder.id)
            var current = j; current.phase = .recoveryRequired; current.lastError = "authoritative recovery error"
            try stale.store.write(current, for: stale.folder.id)
            SnapshotRetention.clean(store: stale.store, folder: stale.folder, journal: &j, validateSource: {})
        }
        try check(try stale.store.journal(stale.folder.id).lastError == "authoritative recovery error", "cleanup warning must not overwrite a changed recovery journal")
        print("PASS: root/ancestor no-follow checks and stale journal guard preserve outside trees and recovery errors")
    }
}

#if RAMNEST_LATEST_SNAPSHOT_STANDALONE && !RAMNEST_HOLDING_CLEANUP_STANDALONE
@main struct LatestSnapshotRunner {
    static func main() {
        do { try LatestSnapshotScenarios.run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
#endif
