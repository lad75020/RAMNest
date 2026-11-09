import Foundation
import Darwin

extension Engine {
    func nativeOperation(_ operation: String, layout: LinkedFolderLayout, record: NativeTmpfsRecord,
                         nobrowse: Bool = true) throws -> [String] {
        var arguments = try NativeTmpfsControl.arguments(operation, layout: layout, record: record)
        if operation == "mount" { arguments[arguments.count - 1] = String(nobrowse) }
        return try NativeTmpfsControl.authorize(helper: helper, arguments: arguments)
    }
    private func nativeSlot(_ folder: Folder, session: UUID, reply: [String]) throws -> LinkedFolderLayout {
        guard reply.count == 4, let rd = UInt64(reply[0]), let ri = UInt64(reply[1]),
              let md = UInt64(reply[2]), let mi = UInt64(reply[3]), ri > 0, mi > 0 else {
            throw NestError("Invalid native reservation receipt; originals unchanged. Retain the slot for inspection.", code: 6)
        }
        let selected = URL(fileURLWithPath: folder.path)
        let parent = try DirectoryHandle.open(selected.deletingLastPathComponent())
        let root = try DirectoryHandle.open(NativeTmpfsPaths.root)
        try NativeTmpfsPaths.requireRoot(root)
        try LinkedFolderLayout.Identity((rd, ri)).verify(root)
        let mount = try DirectoryHandle.open(NativeTmpfsPaths.mount(session))
        try LinkedFolderLayout.Identity((md, mi)).verify(mount)
        var layout = LinkedFolderLayout(folderID: folder.id, session: session, stage: .reserved,
            originalPath: folder.path, mountRoot: NativeTmpfsPaths.root.path, mountPath: NativeTmpfsPaths.data(session).path,
            holdingPath: selected.deletingLastPathComponent().appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(session.uuidString).original").path,
            linkStagePath: selected.deletingLastPathComponent().appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(session.uuidString).link").path,
            parent: try .init(parent.identity()), root: .init((rd, ri)), mountpoint: .init((md, mi)), source: .init((folder.device, folder.inode)))
        layout.version = 2; try layout.validate(); return layout
    }
    func ensureNativePin(_ f: Folder, journal j: inout Journal) throws {
        _ = try NativeTmpfsControl.observe(j, requireData: j.populationVerified)
        if let socket = j.socket, let status = try? Control.status(j, id: f.id), status.mounted,
           (try? Control.request(socket, "capabilities", timeout: 2)) == [NativeTmpfsControl.protocolVersion] { return }
        guard let record = j.nativeTmpfs, let fs = record.filesystem else { throw NestError("Missing native pin identity.", code: 6) }
        let socket = try Paths.socketDirectory(for: store).appendingPathComponent("\(UUID().uuidString).sock").path
        // Never unlink/reuse a predecessor socket. A failed launch remains explicit.
        j.socket = socket; try store.write(j, for: f.id)
        try Control.launch(helper: helper, arguments: ["--pin-v1", String(record.uid), record.session.uuidString,
            String(fs.first), String(fs.second), socket, f.id.uuidString, cli.path, store.root.path])
        for _ in 0..<100 {
            if let status = try? Control.status(j, id: f.id), status.mounted,
               (try? Control.request(socket, "capabilities", timeout: 2)) == [NativeTmpfsControl.protocolVersion] { return }
            session.sleep(0.05)
        }
        throw NestError("Native mount exists but its ordinary-user pin did not become ready. Retain the session and retry mount/recovery; do not create another mount.", code: 2)
    }
    func nativePeriod(_ f: Folder, journal: inout Journal, allowDisconnected: Bool = false) throws {
        // Periodic saves obey the same mandatory root mapping gate as Save.
        let minutes = NativeSnapshotSafety.supported && journal.phase == .mounted && journal.populationVerified &&
            journal.nativeTmpfs?.managedUnmount == false && f.options.sync && f.options.periodicSave ? f.options.intervalMinutes : 0
        let ticket = minutes > 0 ? UUID() : nil
        journal.nativeTmpfs?.periodicAuthorization = ticket
        try store.write(journal, for: f.id) // Retire all previously queued work before IPC.
        guard let socket = journal.socket, (try? Control.status(journal, id: f.id))?.mounted == true else {
            if allowDisconnected { return }
            throw NestError("Native pin is unavailable.", code: 2)
        }
        guard try Control.request(socket, "period\t\(minutes)\t\(ticket?.uuidString ?? "-")\t\(journal.fileVerification.rawValue)").isEmpty else { throw NestError("Invalid native period reply.", code: 6) }
    }
    public func reconnect(_ ref: String) throws {
        try volumeTransaction(ref) { f in
            var j = try store.journal(f.id)
            guard j.nativeTmpfs != nil, j.populationVerified, j.phase == .mounted, mountedIdentity(f, j) else {
                throw NestError("Only an exact surviving verified native session can reconnect.", code: 6)
            }
            try ensureNativePin(f, journal: &j); try nativePeriod(f, journal: &j)
            // Reconnection never thaws a guarded tree or changes checkpoints.
        }
    }
    func mountNative(_ ref: String) throws {
        try volumeTransaction(ref) { current in
            var f = current, j = try store.journal(current.id)
            if j.nativeTmpfs != nil, (try? NativeTmpfsControl.observe(j)) != nil {
                guard j.populationVerified, j.phase == .mounted, mountedIdentity(f, j) else {
                    throw NestError("Native mount remains guarded or has an incomplete transaction. Retain it for explicit recovery.", code: 6)
                }
                try ensureNativePin(f, journal: &j)
                if try NativeTmpfsControl.observe(j).readOnly {
                    j.quiescedRevision = nil; j.quiescedSession = nil; j.nativeTmpfs?.quiescence = nil
                    j.nativeTmpfs?.managedUnmount = false; try store.write(j, for: f.id)
                    let reply = try nativeOperation("thaw", layout: j.nativeLink!, record: j.nativeTmpfs!)
                    guard reply.isEmpty else { throw NestError("Invalid native thaw receipt.", code: 6) }
                    _ = try NativeTmpfsControl.observe(j, readonly: false)
                }
                try nativePeriod(f, journal: &j); return
            }
            guard j.phase == .idle else { throw NestError("Unclean session requires explicit recovery. Native RAMNest does not adopt legacy or unknown mounts.", code: 6) }
            if let prior = j.managedLink {
                guard prior.stage == .restored, prior.mountReleased else { throw NestError("Previous layout is not fully retired.", code: 6) }
            }
            guard FileManager.default.isExecutableFile(atPath: helper.path),
                  try Control.run(helper.path, ["--capabilities"]).trimmingCharacters(in: .whitespacesAndNewlines) == NativeTmpfsControl.protocolVersion else {
                throw NestError("Use the packaged native tmpfs helper; no FUSE fallback is available.", code: 2)
            }
            SiblingCleanup.rememberCompleted(f, &j)
            // Clear historical/live fields together. Every durable intermediate
            // state must decode, including a crash before the new preparation.
            try NativeJournalTransition.resetCompletedAuthority(&j)
            try store.write(j, for: f.id)
            cleanSnapshots(f, &j)
            let config = try store.locked { try store.load() }
            f = try Paths.resolveBookmark(f)
            _ = try Paths.validate(URL(fileURLWithPath: f.path), store: store, folders: config.folders, excluding: f.id)
            try store.locked {
                var latest = try store.load()
                guard let i = latest.folders.firstIndex(where: { $0.id == f.id }) else { throw NestError("Folder removed.", code: 6) }
                _ = try Paths.validate(URL(fileURLWithPath: f.path), store: store, folders: latest.folders, excluding: f.id)
                latest.folders[i] = f; try store.save(latest)
            }
            SnapshotRetention.remember(&j)
            j.phase = .preparing; j.session = UUID(); j.backend = .tmpfs; j.fileVerification = config.fileVerification
            j.populationVerified = false; j.mountedDevice = nil; j.socket = nil; j.lastError = nil
            j.initialRevision = nil; j.initialSourceManifest = nil; j.originalRename = nil; j.publicationRename = nil
            j.restoreRevision = nil; j.restoreManifest = nil; j.restoreStage = nil; j.restoreStageDevice = nil; j.restoreStageInode = nil
            j.restoreDataDevice = nil; j.restoreDataInode = nil; j.publicationReceipt = nil; j.evacuatedEntries = []; j.restoredEntries = []
            j.evacuation = nil; j.evacuationDevice = nil; j.evacuationInode = nil
            j.nativeGeneration = nil; j.quiescedRevision = nil; j.quiescedSession = nil; j.quiescedHelperPID = nil; j.quiescedNativeInstance = nil
            j.startupProtocol = nil; j.startupHelperPID = nil; j.startupRetired = nil
            try store.write(j, for: f.id)
            do {
                // Source snapshot is committed before either authorization or rename.
                let before = try VerifiedRenameReceipt.observe(URL(fileURLWithPath: f.path), verification: j.fileVerification)
                let revision = try Snapshot.capture(store: store, folder: f, source: URL(fileURLWithPath: f.path), previous: j.revision, verification: j.fileVerification)
                guard try VerifiedRenameReceipt.observe(URL(fileURLWithPath: f.path), matching: before.manifest) == before else {
                    throw NestError("Original changed during capture; no source moved.", code: 6)
                }
                j.initialSourceManifest = before.manifest; j.initialRevision = revision; j.priorRevision = j.revision; j.revision = revision
                try store.write(j, for: f.id)
                let (source, expected) = try Snapshot.verified(store: store, id: f.id, revision: revision, verification: j.fileVerification)
                let sid = j.session!
                let reservation = try NativeTmpfsControl.authorize(helper: helper, arguments: ["--native-v1", "reserve", String(getuid()), sid.uuidString])
                j.nativeLink = try nativeSlot(f, session: sid, reply: reservation)
                j.nativeTmpfs = NativeTmpfsRecord(session: sid, capacity: f.capacity)
                try store.write(j, for: f.id)
                // Keep originals in place during mount/population; failure is cheap.
                let mounted = try nativeOperation("mount", layout: j.nativeLink!, record: j.nativeTmpfs!, nobrowse: f.options.nobrowse)
                guard mounted.count == 3, let a = UInt32(mounted[0]), let b = UInt32(mounted[1]), UInt64(mounted[2]) != nil else {
                    throw NestError("Invalid native mount receipt. An uncertain mount is retained; no source moved.", code: 6)
                }
                j.nativeTmpfs!.filesystem = NativeFilesystemID(first: a, second: b); j.phase = .mounting
                try store.write(j, for: f.id)
                _ = try NativeTmpfsControl.observe(j, requireData: false, readonly: false)
                try ensureNativePin(f, journal: &j)
                let copied = try Snapshot.copyTree(from: source, to: NativeTmpfsPaths.data(sid), manifest: expected,
                                                   publicationStaging: true, sourceContext: .managedRevision)
                guard try copied.matchesCopy(of: expected) else { throw NestError("Native population copy mismatch; originals retained.", code: 6) }
                let data = try DirectoryHandle.open(NativeTmpfsPaths.data(sid))
                j.nativeTmpfs!.data = try .init(data.identity()); j.mountedDevice = try data.identity().device
                try store.write(j, for: f.id)
                // This unpublished tree has no client mappings created by RAMNest.
                // Read-only guards activation verification; it is not a save receipt.
                guard try nativeOperation("readonly", layout: j.nativeLink!, record: j.nativeTmpfs!).isEmpty else { throw NestError("Invalid native read-only receipt.", code: 6) }
                _ = try NativeTmpfsControl.observe(j, readonly: true)
                let (originalHandle, original) = try evacuateOriginal(f, journal: &j, expected: before.manifest, sourceBefore: before)
                try verifyAndPublishPopulation(f, journal: &j, expected: copied, source: originalHandle, original: original)
                try ensureNativePin(f, journal: &j)
                guard try nativeOperation("thaw", layout: j.nativeLink!, record: j.nativeTmpfs!).isEmpty else { throw NestError("Invalid native thaw receipt.", code: 6) }
                _ = try NativeTmpfsControl.observe(j, readonly: false)
                try nativePeriod(f, journal: &j)
                cleanSnapshots(f, &j)
            } catch {
                j.lastError = error.localizedDescription; j.phase = .recoveryRequired
                try store.write(j, for: f.id)
                // Do not guess whether an authorized mount completed after a lost
                // reply, nor remove a native slot without its recorded identity.
                if j.nativeTmpfs == nil, j.evacuation == nil {
                    try Paths.checkedIdentity(f)
                    j.phase = .idle; try store.write(j, for: f.id)
                }
                throw error
            }
        }
    }
    @discardableResult func captureNative(_ f: Folder, journal j: inout Journal, quiesce: Bool,
                                         periodic: NativePeriodicSaveRequest? = nil) throws -> String {
        try periodic?.validate(folder: f, journal: j)
        guard j.populationVerified, mountedIdentity(f, j), let layout = j.nativeLink, let record = j.nativeTmpfs else {
            throw NestError("Live native RAM is unavailable; a disk checkpoint cannot be saved as current RAM.", code: 6)
        }
        var next = j
        defer { j = next }
        try ensureNativePin(f, journal: &next)
        func validatePeriodic() throws {
            if let periodic { try periodic.validate(folder: self.folder(f.id.uuidString), journal: store.journal(f.id)) }
        }
        var receipt: [String] = []
        return try NativeCheckpointTransaction.run(keepFrozen: quiesce, readonly: {
            try validatePeriodic() // Before any administrator prompt.
            receipt = try nativeOperation("freeze", layout: layout, record: record)
        }, verify: { _ = try NativeTmpfsControl.observe(next, readonly: true) }, validateMappings: {
            guard let fs = record.filesystem else { throw NestError("Missing native fsid.", code: 6) }
            try NativeSnapshotSafety.validateReceipt(receipt, filesystem: fs)
        }, copy: {
            try Snapshot.capture(store: store, folder: f, source: NativeTmpfsPaths.data(record.session),
                                 previous: next.revision, verification: next.fileVerification)
        }, commit: { revision in
            try validatePeriodic() // Before promoting a new checkpoint.
            SnapshotRetention.remember(&next); next.priorRevision = next.revision; next.revision = revision
            next.quiescedRevision = quiesce ? revision : nil; next.quiescedSession = quiesce ? next.session : nil
            next.nativeTmpfs!.quiescence = quiesce ? NativeSnapshotSafety.receiptVersion : nil
            try store.write(next, for: f.id)
        }, invalidate: { failure, thawFailed in
            next.quiescedRevision = nil; next.quiescedSession = nil; next.nativeTmpfs?.quiescence = nil; next.nativeTmpfs?.managedUnmount = false
            next.lastError = failure.localizedDescription
            if thawFailed || (try? NativeTmpfsControl.observe(next)) == nil { next.phase = .recoveryRequired }
            try store.write(next, for: f.id)
        }, stillBoundReadonly: { (try? NativeTmpfsControl.observe(next, readonly: true)) != nil }, thaw: {
            guard try nativeOperation("thaw", layout: layout, record: record).isEmpty else { throw NestError("Invalid native thaw receipt.", code: 6) }
            _ = try NativeTmpfsControl.observe(next, readonly: false)
        })
    }

    func unmountNative(_ ref: String, ignoreBusy: Bool) throws {
        if !ignoreBusy {
            let busy = try busyProcesses(ref)
            guard busy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NestError("Processes use this native volume. Close them or explicitly Ignore for a normal eject. Ignore cannot bypass the mandatory mapping/coherence guard.\n" + busy, code: 7) }
        }
        try volumeTransaction(ref) { f in
            var j = try store.journal(f.id)
            if j.phase == .idle { return }
            guard let layout = j.nativeLink, let record = j.nativeTmpfs else { throw NestError("Missing native mount authority.", code: 6) }
            _ = try NativeTmpfsControl.observe(j, requireData: j.populationVerified)
            if j.phase == .ejecting {
                // A coordinator may have crashed before its normal unmount.
                // Retry from a fresh freeze/capture, never a stale eject receipt.
                j.phase = .recoveryRequired; j.quiescedRevision = nil; j.quiescedSession = nil
                j.nativeTmpfs?.quiescence = nil; j.nativeTmpfs?.managedUnmount = false
                try store.write(j, for: f.id)
            }
            guard j.phase == .mounted || j.phase == .recoveryRequired ||
                  (!j.populationVerified && [.preparing, .mounting, .evacuated].contains(j.phase)) else {
                throw NestError("Native publication is pending; retain it for explicit recovery.", code: 6)
            }
            if j.populationVerified { guard mountedIdentity(f, j) else { throw NestError("Managed native link changed; RAM retained.", code: 6) } }
            try ensureNativePin(f, journal: &j)
            if f.options.sync && j.populationVerified {
                // Mandatory, even when the caller selected Ignore Busy.
                _ = try captureNative(f, journal: &j, quiesce: true); j.restoreRevision = j.revision
            } else {
                // Explicit temporary discard needs no current-RAM checkpoint.
                guard try nativeOperation("readonly", layout: layout, record: record).isEmpty else { throw NestError("Invalid native read-only receipt.", code: 6) }
                _ = try NativeTmpfsControl.observe(j, requireData: j.populationVerified, readonly: true)
                j.restoreRevision = j.initialRevision
            }
            j.phase = .ejecting; try store.write(j, for: f.id)
            // Closing this pin is bounded to the journal's same-user helper. No
            // other process is killed; ordinary umount still rejects other pins.
            if let socket = j.socket { guard try Control.request(socket, "retire").isEmpty else { throw NestError("Native pin did not acknowledge retirement.", code: 6) } }
            do {
                guard try nativeOperation("unmount", layout: layout, record: record).isEmpty else { throw NestError("Invalid native unmount receipt.", code: 6) }
                try NativeTmpfsControl.assertAbsent(j)
                j.nativeTmpfs!.managedUnmount = true; try store.write(j, for: f.id)
            } catch {
                let failure = error
                // Retire all stale authority before any repin/thaw. A failed
                // operation cannot count as a completed managed unmount.
                j.quiescedRevision = nil; j.quiescedSession = nil; j.nativeTmpfs?.quiescence = nil
                j.nativeTmpfs?.managedUnmount = false; j.lastError = failure.localizedDescription
                if let observed = try? NativeTmpfsControl.observe(j, requireData: j.populationVerified) {
                    j.phase = j.populationVerified ? .mounted : .recoveryRequired
                    try store.write(j, for: f.id)
                    try ensureNativePin(f, journal: &j)
                    if j.populationVerified && observed.readOnly {
                        guard try nativeOperation("thaw", layout: layout, record: record).isEmpty else { throw NestError("Invalid native thaw receipt.", code: 6) }
                        _ = try NativeTmpfsControl.observe(j, readonly: false)
                    }
                } else {
                    j.phase = .recoveryRequired; try store.write(j, for: f.id)
                }
                throw failure
            }
        }
        try finalizeNative(ref, explicitRecovery: false)
    }
    func finalizeNative(_ ref: String, explicitRecovery: Bool) throws {
        try volumeTransaction(ref) { f in
            var j = try store.journal(f.id)
            guard j.nativeTmpfs != nil else { throw NestError("Not a native session.", code: 6) }
            try NativeTmpfsControl.assertAbsent(j)
            if j.phase == .idle { try finishLinkedRestore(f, journal: &j); cleanSnapshots(try refreshedFolder(f), &j); return }
            let continuingRestore = j.phase == .restoring || j.phase == .pendingRestore
            if NativeRecoveryPolicy.needsLossDisclosure(j, sync: f.options.sync) {
                j.nativeTmpfs!.lossDisclosure = "The native tmpfs mount disappeared outside a completed managed eject. Any unsaved contents are lost. Explicit recovery restores only the latest committed disk checkpoint; it cannot export the vanished RAM tree."
                j.lastError = j.nativeTmpfs!.lossDisclosure
                j.phase = .recoveryRequired; try store.write(j, for: f.id)
                guard explicitRecovery else { throw NestError(j.lastError!, code: 6) }
            }
            if let socket = j.socket { _ = try? Control.request(socket, "retire", timeout: 2) }
            // No helper export after unmount. Only a verified committed revision
            // or the retained original inode can authorize disk publication.
            if !j.populationVerified || !f.options.sync {
                try restoreLinkedOriginal(f, journal: &j, temporary: true)
            } else {
                if !continuingRestore {
                    j.restoreRevision = j.revision; j.phase = .pendingRestore; try store.write(j, for: f.id)
                }
                try restoreLinkedOriginal(f, journal: &j, temporary: false)
            }
            j.socket = nil; try store.write(j, for: f.id)
            cleanSnapshots(try refreshedFolder(f), &j)
        }
    }
}
