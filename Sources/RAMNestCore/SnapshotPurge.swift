import Foundation
import Darwin

/// Result of `Engine.purgeIdleSnapshots()`.
public struct SnapshotPurgeReport: Sendable, Equatable {
    /// Snapshot revisions deleted across all records.
    public var removedSnapshots = 0
    /// Display names of listed folders whose snapshots were deleted.
    public var cleanedFolders: [String] = []
    /// Records of folders no longer listed in RAMNest that were fully removed.
    public var removedUnlistedRecords = 0
    /// Human-readable reasons for anything retained.
    public var skipped: [String] = []
}

extension Engine {
    /// Deletes every snapshot of listed folders that are idle (not mounted, no
    /// pending recovery or cleanup), and every record left behind by folders no
    /// longer listed. Mounted or uncertain folders are skipped, never touched.
    ///
    /// Safety: a folder's original must still verify at its recorded identity,
    /// and journal references are dropped durably *before* any data is
    /// unlinked, so a crash leaves only unreferenced data for the next run.
    public func purgeIdleSnapshots() throws -> SnapshotPurgeReport {
        let path = store.root.path
        guard !Paths.mounts().contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) else {
            throw NestError("A mount inside snapshot storage blocks cleanup.", code: NestError.Code.retained)
        }
        var report = SnapshotPurgeReport()
        let config = try store.locked { try store.load() }
        for folder in config.folders {
            do {
                let removed = try purgeListed(folder.id)
                if removed > 0 { report.removedSnapshots += removed; report.cleanedFolders.append(folder.name) }
            } catch { report.skipped.append("\(folder.name): \(error.localizedDescription)") }
        }
        let listed = Set(config.folders.map(\.id))
        let volumes = try store.locked { try DirectoryHandle.open(store.root).child("volumes").names() }
        for name in volumes {
            guard let id = UUID(uuidString: name), id.uuidString == name, !listed.contains(id) else { continue }
            do {
                report.removedSnapshots += try purgeUnlisted(id)
                report.removedUnlistedRecords += 1
            } catch { report.skipped.append("Unlisted record \(name.prefix(8)): \(error.localizedDescription)") }
        }
        return report
    }

    private func purgeListed(_ id: UUID) throws -> Int {
        try volumeTransaction(id.uuidString) { f in
            var j = try store.journal(f.id)
            guard j.phase == .idle else { throw NestError("Mounted or needs recovery; kept.", code: NestError.Code.retained) }
            guard j.reviewedRecovery == nil else { throw NestError("Reviewed recovery evidence is kept until RESET.", code: NestError.Code.retained) }
            guard j.lastError == nil else { throw NestError("Has an unresolved error; kept.", code: NestError.Code.retained) }
            guard (j.siblingCleanup ?? []).isEmpty else { throw NestError("Original-folder cleanup is pending; kept.", code: NestError.Code.retained) }
            if let layout = j.managedLink {
                guard layout.stage == .restored, layout.mountReleased else { throw NestError("Previous session isn't fully restored; kept.", code: NestError.Code.retained) }
            }
            if j.nativeTmpfs != nil { try NativeTmpfsControl.assertAbsent(j) }
            guard !Paths.mounts().contains(where: { $0.path == f.path || $0.path.hasPrefix(f.path + "/") }) else {
                throw NestError("Folder is mounted; kept.", code: NestError.Code.retained)
            }
            // The snapshot may be the only other copy: require the original intact.
            try Paths.checkedIdentity(f)
            let volume = try store.managedVolume(f.id)
            guard try volume.exists("revisions") else { return 0 }
            let revisions = try volume.child("revisions")
            try revisions.requireOwnedDirectory(device: volume.identity().device, privateMode: true)
            let names = try revisions.names()
            guard names.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }) else {
                throw NestError("Unrecognized snapshot data; kept.", code: NestError.Code.retained)
            }
            for name in names { try revisions.removeCommittedRevision(name, validateOnly: true) }
            guard !names.isEmpty || j.revision != nil else { return 0 }
            // Drop every reference durably first; the folder is now like a new one.
            j.revision = nil; j.priorRevision = nil; j.initialRevision = nil; j.restoreRevision = nil
            j.initialSourceManifest = nil; j.restoreManifest = nil; j.originalRename = nil; j.publicationRename = nil
            j.retiringRevisions = names.isEmpty ? nil : names; j.cleanupWarning = nil
            try store.write(j, for: f.id)
            var removed = 0, retained: [String] = [], failures: [String] = []
            for name in names {
                do { try revisions.removeCommittedRevision(name); removed += 1 }
                catch { retained.append(name); failures.append(error.localizedDescription) }
            }
            j.retiringRevisions = retained.isEmpty ? nil : retained
            if !failures.isEmpty { j.cleanupWarning = "Snapshot cleanup warning: " + failures.joined(separator: " ") }
            try store.write(j, for: f.id)
            return removed
        }
    }

    private static let unlistedNames: Set<String> = ["journal.json", "transaction.lock", "revisions"]

    private func purgeUnlisted(_ id: UUID) throws -> Int {
        func stillUnlisted() throws {
            guard try !store.locked({ try store.load() }).folders.contains(where: { $0.id == id }) else {
                throw NestError("Folder is listed again; kept.", code: NestError.Code.retained)
            }
        }
        let removed = try store.volumeLocked(id) { () -> Int in
            try stillUnlisted()
            let volume = try store.managedVolume(id)
            let device = try volume.identity().device
            guard Set(try volume.names()).isSubset(of: Self.unlistedNames) else {
                throw NestError("Contains unrecognized data; kept.", code: NestError.Code.retained)
            }
            if try volume.exists("journal.json") {
                let j = try volume.readJSON(Journal.self, "journal.json", decoder: store.journalDecoder)
                guard j.phase == .idle, j.reviewedRecovery == nil else {
                    throw NestError("Needs recovery or RESET; kept.", code: NestError.Code.retained)
                }
                if j.nativeTmpfs != nil { try NativeTmpfsControl.assertAbsent(j) }
            }
            var count = 0
            if try volume.exists("revisions") {
                let revisions = try volume.child("revisions")
                try revisions.requireOwnedDirectory(device: device, privateMode: true)
                let names = try revisions.names()
                guard names.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }) else {
                    throw NestError("Unrecognized snapshot data; kept.", code: NestError.Code.retained)
                }
                for name in names { try revisions.removeCommittedRevision(name, validateOnly: true) }
                for name in names { try revisions.removeCommittedRevision(name); count += 1 }
                guard unlinkat(volume.fd, "revisions", AT_REMOVEDIR) == 0 else {
                    throw NestError("Couldn't remove the empty snapshot folder: \(String(cString: strerror(errno)))", code: NestError.Code.retained)
                }
            }
            if try volume.exists("journal.json") {
                guard unlinkat(volume.fd, "journal.json", 0) == 0 else {
                    throw NestError("Couldn't remove the record: \(String(cString: strerror(errno)))", code: NestError.Code.retained)
                }
            }
            return count
        }
        // Retire the now-empty record after its transaction lock is released.
        try store.locked {
            guard try !store.load().folders.contains(where: { $0.id == id }) else { return }
            let volumes = try DirectoryHandle.open(store.root).child("volumes")
            let volume = try volumes.child(id.uuidString)
            let names = try volume.names()
            guard Set(names).isSubset(of: ["transaction.lock"]) else { return }
            if !names.isEmpty, unlinkat(volume.fd, "transaction.lock", 0) != 0 { return }
            _ = unlinkat(volumes.fd, id.uuidString, AT_REMOVEDIR)
        }
        return removed
    }
}
