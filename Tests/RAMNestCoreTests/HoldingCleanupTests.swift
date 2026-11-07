import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_HOLDING_CLEANUP_STANDALONE
import XCTest
final class HoldingCleanupTests: XCTestCase {
    func testCompletedSessionCleanup() throws { try HoldingCleanupScenarios.run() }
}
#endif

enum HoldingCleanupScenarios {
    typealias Fixture = LatestSnapshotScenarios.Fixture
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        try LatestSnapshotScenarios.check(try value(), message)
    }
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/holding-cleanup/fixtures-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        print("Fixtures: \(root.path)")
        var failures: [String] = []
        func scenario(_ name: String, _ body: () throws -> Void) {
            do { try body(); print("PASS: \(name)") }
            catch { failures.append(name); print("FAIL: \(name): \(error)") }
        }
        scenario("normal restore removes nonempty originals and empty restore stage") {
            let f = try Fixture(root, "normal")
            _ = try f.save("latest verified bytes")
            try f.finish()
            try check(try String(contentsOf: f.selected.appendingPathComponent("payload"), encoding: .utf8) == "latest verified bytes", "latest bytes restored")
            try check(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("originals").path), "completed nonempty holding removed")
            try check(try FileManager.default.contentsOfDirectory(atPath: f.root.path).allSatisfy { !$0.contains("-restore-") }, "empty restore stage removed")
        }
        scenario("temporary rollback removes empty holding and preserves original inode without RAM I/O") {
            let f = try Fixture(root, "temporary", temporary: true)
            let original = try DirectoryHandle.open(f.root.appendingPathComponent("originals")).entryStat("payload")
            try Data("private RAM changes".utf8).write(to: f.helper.live.appendingPathComponent("payload"))
            try f.finish()
            let restored = try DirectoryHandle.open(f.selected).entryStat("payload")
            try check(original.st_ino == restored.st_ino, "original inode returned")
            try check(try String(contentsOf: f.selected.appendingPathComponent("payload"), encoding: .utf8) == "original", "original data returned")
            try check(f.helper.commands == [], "rollback exports no RAM and socket is cleared")
            try check(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("originals").path), "empty rollback holding removed")
        }
        scenario("active and uncertain holdings survive") {
            let f = try Fixture(root, "active")
            _ = try f.save("saved")
            try check(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("originals/payload").path), "active original retained")
            try f.editJournal { $0.phase = .recoveryRequired; $0.lastError = "authoritative recovery error" }
            try f.cleanupExport()
            try check(try f.store.journal(f.folder.id).lastError == "authoritative recovery error", "recovery error survives")
            try check(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("originals/payload").path), "uncertain original retained")
        }
        scenario("mutated originals and unknown entries survive with a warning") {
            for unknown in [false, true] {
                let f = try Fixture(root, "changed-\(unknown)")
                _ = try f.save("latest")
                try Data("outside writer".utf8).write(to: f.root.appendingPathComponent(unknown ? "originals/unknown" : "originals/payload"))
                try f.finish()
                let j = try f.store.journal(f.folder.id)
                try check(j.phase == .idle && j.lastError == nil && j.cleanupWarning != nil, "cleanup failure is a nonfatal warning")
                try check(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("originals/payload").path), "changed original retained")
                try check(try f.exists(f.initial), "initial snapshot remains pinned")
            }
        }
        scenario("legacy journals decode defaults and round-trip queued provenance") { try legacy(root) }
        scenario("actual unlink failure is nonfatal, pins initial, and retries partial deletion") { try unlinkRetry(root) }
        scenario("failed snapshot verification and journal commit retain siblings") { try verificationAndCommit(root) }
        scenario("source, repository, parent, root, symlink and outside identities are checked") { try identities(root) }
        scenario("unknown or replaced restore data is retained") { try changedStage(root) }
        scenario("repeated completed cycles have no sibling growth") { try cycles(root) }
        scenario("wide and deep cleanup uses bounded descriptors and stack; symlink targets survive") { try stress(root) }
        scenario("existing latest-snapshot and recovery scenarios remain green") { try LatestSnapshotScenarios.run() }
        if !failures.isEmpty { throw NestError("Holding cleanup failures: " + failures.joined(separator: ", ")) }
    }

    static func idleCopy(_ f: Fixture) throws {
        let (_, manifest) = try Snapshot.verified(store: f.store, id: f.folder.id, revision: f.initial)
        let copy = f.root.appendingPathComponent("idle-copy")
        try Snapshot.copyTree(from: f.root.appendingPathComponent("originals"), to: copy, manifest: manifest)
        try DirectoryHandle.open(copy).renameNoReplace("payload", to: DirectoryHandle.open(f.selected), as: "payload")
        try f.editJournal { $0.phase = .idle; $0.socket = nil; $0.mountedDevice = nil; $0.restoreRevision = f.initial }
    }
    static func legacy(_ root: URL) throws {
        let old = try Fixture(root, "legacy-defaults")
        let encoded = try JSONEncoder().encode(old.store.journal(old.folder.id))
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["siblingCleanup", "restoreDataDevice", "restoreDataInode"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: json))
        try check(decoded.siblingCleanup == nil && decoded.restoreDataDevice == nil && decoded.restoreDataInode == nil, "legacy optional defaults")
        try idleCopy(old)
        try old.engine.recover(old.folder.id.uuidString)
        try check(!FileManager.default.fileExists(atPath: old.root.appendingPathComponent("originals").path), "recorded legacy holding with valid initial snapshot cleaned")
        for missing in [false, true] {
            let f = try Fixture(root, "legacy-missing-\(missing)")
            try idleCopy(f)
            if missing {
                try f.editJournal { $0.initialRevision = nil }
            } else {
                let originalRevision = try f.revisionURL(f.initial)
                try FileManager.default.moveItem(at: originalRevision, to: f.root.appendingPathComponent("unavailable-initial"))
                // A valid new committed snapshot permits cleanup to run while
                // the attributed original anchor remains unavailable.
                let latest = try Snapshot.capture(store: f.store, folder: f.folder, source: f.selected, previous: nil)
                try f.editJournal { $0.revision = latest; $0.restoreRevision = latest }
            }
            try f.engine.recover(f.folder.id.uuidString)
            let j = try f.store.journal(f.folder.id)
            try check(j.cleanupWarning != nil && j.siblingCleanup?.count == 1, "missing legacy provenance retained and warned")
            try check(try JSONDecoder().decode(Journal.self, from: JSONEncoder().encode(j)) == j, "queued journal round-trip")
            try check(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("originals/payload").path), "no guessing missing initial")
        }
    }
    static func unlinkRetry(_ root: URL) throws {
        let f = try Fixture(root, "unlink-retry")
        let holding = f.root.appendingPathComponent("originals")
        try Data("second original".utf8).write(to: holding.appendingPathComponent("second"))
        let initial = try Snapshot.capture(store: f.store, folder: f.folder, source: holding, previous: nil)
        try f.editJournal { $0.initialRevision = initial }
        _ = try f.save("latest")
        var calls = 0, injected = false
        var boundary = f.helper.boundary
        boundary.beforeCleanupUnlink = { parent, name in
            let current = try parent.identity()
            if current == (try DirectoryHandle.open(holding).identity()) {
                calls += 1
                if calls == 2 && !injected {
                    injected = true
                    guard fchmod(parent.fd, 0o500) == 0 else { throw NestError("Cannot inject owned unlink failure") }
                }
            }
        }
        let engine = Engine(store: f.store, session: boundary)
        f.helper.mounted = false
        try engine.finalize(f.folder.id.uuidString)
        try check(injected, "real unlink failure injected after first deletion")
        let j = try f.store.journal(f.folder.id)
        try check(j.phase == .idle && j.lastError == nil && j.cleanupWarning?.contains("unlink failed") == true, "actual syscall failure is nonfatal")
        try check(j.siblingCleanup?.first?.plan != nil, "partial cleanup plan durable")
        try check(try f.exists(initial), "initial snapshot pinned until cleanup completes")
        try check(try DirectoryHandle.open(holding).names().count == 1, "partial deletion happened")
        try check(chmod(holding.path, 0o700) == 0, "restore fixture permission")
        // A later completed transaction can have different verified source
        // bytes; the queued original still uses its own initial manifest.
        try Data("newer completed idle data".utf8).write(to: f.selected.appendingPathComponent("payload"))
        let newer = try Snapshot.capture(store: f.store, folder: f.folder, source: f.selected, previous: j.revision)
        try f.editJournal { $0.priorRevision = $0.revision; $0.revision = newer }
        try f.engine.recover(f.folder.id.uuidString)
        let done = try f.store.journal(f.folder.id)
        try check(done.siblingCleanup == nil && done.cleanupWarning == nil && done.lastError == nil, "next safe operation retries and clears warning")
        try check(!FileManager.default.fileExists(atPath: holding.path) && (try !f.exists(initial)), "holding and obsolete pin retired after retry")
    }
    static func verificationAndCommit(_ root: URL) throws {
        for kind in ["latest", "source", "commit", "stale", "recovery"] {
            let f = try Fixture(root, "failure-\(kind)")
            try idleCopy(f)
            var j = try f.store.journal(f.folder.id)
            let volumeURL = try f.store.volume(f.folder.id)
            if kind == "latest" {
                try Data("corrupt".utf8).write(to: Snapshot.dataURL(store: f.store, id: f.folder.id, revision: f.initial).appendingPathComponent("payload"))
            } else if kind == "source" {
                try Data("new source writer".utf8).write(to: f.selected.appendingPathComponent("payload"))
            } else if kind == "commit" {
                try check(chmod(volumeURL.path, 0o500) == 0, "inject journal commit failure")
            } else {
                try f.editJournal { $0.phase = .recoveryRequired; $0.lastError = "primary recovery failure" }
                if kind == "recovery" { j = try f.store.journal(f.folder.id) }
            }
            try f.store.locked {
                SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, validateSource: { try Paths.checkedIdentity(f.folder) })
            }
            if kind == "commit" { try check(chmod(volumeURL.path, 0o700) == 0, "restore journal permission") }
            try check(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("originals/payload").path), "failure preserves holding: \(kind)")
            if kind == "stale" || kind == "recovery" { try check(try f.store.journal(f.folder.id).lastError == "primary recovery failure", "recovery error not masked") }
        }
        let conflict = try Fixture(root, "failed-restore")
        _ = try conflict.save("latest")
        try Data("unknown source".utf8).write(to: conflict.selected.appendingPathComponent("unknown"))
        try LatestSnapshotScenarios.rejects { try conflict.finish() }
        try check(FileManager.default.fileExists(atPath: conflict.root.appendingPathComponent("originals/payload").path), "failed actual restore preserves original")
        try check(try conflict.exists(conflict.initial), "failed restore keeps initial pin")
    }
    static func identities(_ root: URL) throws {
        for kind in ["inode", "symlink", "outside", "mode", "device", "parent", "selected", "repository"] {
            let f = try Fixture(root, "identity-\(kind)")
            try idleCopy(f)
            let holding = f.root.appendingPathComponent("originals")
            let outside = f.root.appendingPathComponent("outside"); try Store.privateDirectory(outside)
            let sentinel = outside.appendingPathComponent("sentinel"); try Data("untouched".utf8).write(to: sentinel)
            var j = try f.store.journal(f.folder.id)
            if kind == "inode" || kind == "symlink" {
                try FileManager.default.moveItem(at: holding, to: f.root.appendingPathComponent("preserved-originals"))
                if kind == "symlink" { try FileManager.default.createSymbolicLink(at: holding, withDestinationURL: outside) }
                else { try Store.privateDirectory(holding); try Data("replacement".utf8).write(to: holding.appendingPathComponent("payload")) }
            } else if kind == "outside" {
                let h = try DirectoryHandle.open(outside).identity()
                j.evacuation = outside.path + "/../outside"; j.evacuationDevice = h.device; j.evacuationInode = h.inode
                try f.store.write(j, for: f.folder.id)
            } else if kind == "mode" { try check(chmod(holding.path, 0o755) == 0, "set unsafe root mode") }
            else if kind == "device" { j.evacuationDevice = UInt64.max; try f.store.write(j, for: f.folder.id) }
            else if kind == "parent" {
                SiblingCleanup.rememberCompleted(f.folder, &j)
                j.siblingCleanup?[0].parentInode = UInt64.max
                try f.store.write(j, for: f.folder.id)
            } else if kind == "selected" {
                try FileManager.default.moveItem(at: f.selected, to: f.root.appendingPathComponent("preserved-selected"))
                try Store.privateDirectory(f.selected)
            } else {
                try FileManager.default.moveItem(at: f.store.root, to: f.root.appendingPathComponent("preserved-store"))
                try Store.privateDirectory(f.store.root)
            }
            SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, validateSource: { try Paths.checkedIdentity(f.folder) })
            try check(try String(contentsOf: sentinel, encoding: .utf8) == "untouched", "outside target safe: \(kind)")
            if kind != "repository" {
                try check(try f.store.journal(f.folder.id).cleanupWarning != nil, "identity failure warns: \(kind)")
            }
            try check(FileManager.default.fileExists(atPath: holding.path), "identity mismatch never deletes root: \(kind)")
        }
    }
    static func changedStage(_ root: URL) throws {
        for kind in ["unknown", "root", "data"] {
            let f = try Fixture(root, "stage-\(kind)")
            var boundary = f.helper.boundary
            let request = boundary.request
            boundary.request = { socket, command in
                let result = try request(socket, command)
                if command == "retire", let stage = try f.store.journal(f.folder.id).restoreStage {
                    let stageURL = URL(fileURLWithPath: stage)
                    if kind == "unknown" { try Data("unknown".utf8).write(to: stageURL.appendingPathComponent("data/unknown")) }
                    else if kind == "root" {
                        try FileManager.default.moveItem(at: stageURL, to: f.root.appendingPathComponent("preserved-stage"))
                        try Store.privateDirectory(stageURL); try Store.privateDirectory(stageURL.appendingPathComponent("data"))
                    } else {
                        try FileManager.default.moveItem(at: stageURL.appendingPathComponent("data"), to: f.root.appendingPathComponent("preserved-data"))
                        try Store.privateDirectory(stageURL.appendingPathComponent("data"))
                    }
                }
                return result
            }
            f.helper.mounted = false
            try Engine(store: f.store, session: boundary).finalize(f.folder.id.uuidString)
            let j = try f.store.journal(f.folder.id)
            try check(j.phase == .idle && j.lastError == nil && j.cleanupWarning != nil, "stage anomaly nonfatal: \(kind)")
            try check(j.siblingCleanup?.contains { $0.kind == .restoreStage } == true, "stage provenance retained: \(kind)")
        }
    }
    static func cycles(_ root: URL) throws {
        let f = try Fixture(root, "cycles")
        for cycle in 0..<6 {
            if cycle > 0 {
                let previous = try f.store.journal(f.folder.id).revision
                let revision = try Snapshot.capture(store: f.store, folder: f.folder, source: f.selected, previous: previous)
                let holding = f.root.appendingPathComponent(".ramnest-cycle-\(cycle).original")
                let handle = try DirectoryHandle.open(f.root).createDirectory(holding.lastPathComponent)
                try DirectoryHandle.open(f.selected).renameNoReplace("payload", to: handle, as: "payload")
                let identity = try handle.identity()
                try f.editJournal {
                    $0.phase = .mounted; $0.populationVerified = true; $0.socket = "owned-recorder"; $0.mountedDevice = 123
                    $0.priorRevision = previous; $0.revision = revision; $0.initialRevision = revision; $0.restoreRevision = nil
                    $0.evacuation = holding.path; $0.evacuationDevice = identity.device; $0.evacuationInode = identity.inode
                }
                f.helper.mounted = true
            }
            _ = try f.save("cycle \(cycle)")
            try f.finish()
            try check(try f.store.journal(f.folder.id).siblingCleanup == nil, "cycle queue drained")
            let names = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
            try check(!names.contains("originals") && names.allSatisfy { !$0.hasPrefix(".ramnest-") }, "no completed sibling growth at cycle \(cycle)")
        }
    }
    static func stress(_ root: URL) throws {
        let f = try Fixture(root, "descriptor-stack")
        let holding = f.root.appendingPathComponent("originals")
        for i in 0..<160 {
            let directory = holding.appendingPathComponent("dir-\(i)"); try Store.privateDirectory(directory)
            try Data("owned".utf8).write(to: directory.appendingPathComponent("file"))
        }
        var deep = holding
        for _ in 0..<48 { deep = deep.appendingPathComponent("d"); try Store.privateDirectory(deep) }
        try Data("deep".utf8).write(to: deep.appendingPathComponent("file"))
        let sentinel = f.root.appendingPathComponent("sentinel"); try Data("outside".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: holding.appendingPathComponent("link"), withDestinationURL: sentinel)
        try check(link(holding.appendingPathComponent("payload").path, holding.appendingPathComponent("hardlink").path) == 0, "create original hardlink")
        let initial = try Snapshot.capture(store: f.store, folder: f.folder, source: holding, previous: nil)
        try f.editJournal { $0.initialRevision = initial }
        _ = try f.save("latest")
        try f.finish()
        try check(!FileManager.default.fileExists(atPath: holding.path), "wide/deep original cleaned")
        try check(try String(contentsOf: sentinel, encoding: .utf8) == "outside", "symlink target never followed")
    }
}
