import Foundation

/// Outcome of `Engine.purgeIdleSnapshots()`.
public struct SnapshotPurgeReport: Equatable, Sendable {
    /// Committed snapshots deleted (configured and no-longer-configured folders).
    public var removedSnapshots = 0
    /// Records of folders removed from RAMNest whose snapshots were deleted.
    public var removedUnlistedRecords = 0
    /// Human-readable reasons something was kept (mounted, needs recovery, damaged snapshot…).
    public var skipped: [String] = []
    public init() {}
}

extension Engine {
    /// Deletes every committed snapshot of folders that are not mounted and need no recovery,
    /// including records of folders that were removed from RAMNest. Original folders are never
    /// touched. Anything uncertain (non-idle phase, recovery evidence, unrecognized or damaged
    /// entries) is kept and reported in `skipped`.
    public func purgeIdleSnapshots() throws -> SnapshotPurgeReport {
        var report = SnapshotPurgeReport()
        let configured = try store.locked { try store.load().folders }
        let configuredIDs = Set(configured.map(\.id))

        for folder in configured {
            do {
                try volumeTransaction(folder.id.uuidString) { f in
                    var j = try store.journal(f.id)
                    guard j.reviewedRecovery == nil, j.lastError == nil, j.phase == .idle else {
                        report.skipped.append("\(f.name) (needs recovery)"); return
                    }
                    let mountPath = j.nativeTmpfs.map { NativeTmpfsPaths.mount($0.session).path } ?? j.managedLink?.mountPath ?? f.path
                    guard !Paths.mounts().contains(where: { $0.path == mountPath || $0.path == f.path }) else {
                        report.skipped.append("\(f.name) (mounted)"); return
                    }
                    let outcome = try purgeRevisions(of: f.id)
                    report.removedSnapshots += outcome.removed
                    report.skipped.append(contentsOf: outcome.kept.map { "\(f.name): \($0)" })
                    if outcome.removed > 0 {
                        // Deleted revisions must not stay referenced as pending retirements.
                        j.priorRevision = nil; j.retiringRevisions = nil; j.cleanupWarning = nil
                        try store.write(j, for: f.id)
                    }
                }
            } catch {
                report.skipped.append("\(folder.name) (\(error.localizedDescription))")
            }
        }

        // Records of folders no longer in the configuration.
        let volumes = try store.locked { () -> [String] in
            let root = try DirectoryHandle.open(store.root)
            guard try root.exists("volumes") else { return [] }
            return try root.child("volumes").names()
        }
        for name in volumes {
            guard let id = UUID(uuidString: name), id.uuidString == name, !configuredIDs.contains(id) else { continue }
            let label = "removed folder \(name.prefix(8))"
            do {
                let outcome: (removed: Int, kept: [String])? = try store.volumeLocked(id) {
                    let volume = try store.managedVolume(id)
                    if try volume.exists("journal.json") {
                        let j = try volume.readJSON(Journal.self, "journal.json", decoder: store.journalDecoder)
                        guard j.reviewedRecovery == nil, j.lastError == nil, j.phase == .idle else { return nil }
                    }
                    return try purgeRevisions(of: id)
                }
                guard let outcome else { report.skipped.append("\(label) (needs recovery)"); continue }
                report.removedSnapshots += outcome.removed
                if outcome.removed > 0 { report.removedUnlistedRecords += 1 }
                report.skipped.append(contentsOf: outcome.kept.map { "\(label): \($0)" })
            } catch {
                report.skipped.append("\(label) (\(error.localizedDescription))")
            }
        }
        return report
    }

    /// Caller holds the volume transaction lock. Removes only UUID-named committed revisions that
    /// pass the existing preflight in `removeCommittedRevision`; everything else is kept.
    private func purgeRevisions(of id: UUID) throws -> (removed: Int, kept: [String]) {
        let volume = try store.managedVolume(id)
        guard try volume.exists("revisions") else { return (0, []) }
        let revisions = try volume.child("revisions")
        try revisions.requireOwnedDirectory(device: volume.identity().device, privateMode: true)
        var removed = 0
        var kept: [String] = []
        for name in try revisions.names() {
            guard UUID(uuidString: name)?.uuidString == name else { kept.append("unrecognized entry kept"); continue }
            do { try revisions.removeCommittedRevision(name); removed += 1 }
            catch { kept.append("snapshot \(name.prefix(8)) kept (\(error.localizedDescription))") }
        }
        return (removed, kept)
    }
}
