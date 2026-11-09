import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_METADATA_STANDALONE
import Testing
#endif

// All state belongs to this run. Never opens AppSupport or a real mount.
enum MetadataRecoveryScenarios {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NestError("Fixture assertion: " + message) }
    }
    @discardableResult static func rejects(_ body: () throws -> Void) throws -> String {
        do { try body() } catch { return error.localizedDescription }
        throw NestError("Fixture expected rejection")
    }
    static func root() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("artifacts/scratch/metadata-recovery/" + UUID().uuidString)
        try Store.privateDirectory(root); return root
    }
    static func fixture(_ root: URL, _ name: String) throws -> (Store, Folder) {
        let base = root.appendingPathComponent(name); try Store.privateDirectory(base)
        let selected = base.appendingPathComponent("selected"); try Store.privateDirectory(selected)
        try Data("checkpoint bytes".utf8).write(to: selected.appendingPathComponent("payload"))
        let store = try Store(root: base.appendingPathComponent("store"))
        var options = FolderOptions(); options.mountAtLaunch = false
        let folder = try Engine(store: store).create(path: selected, name: name, capacity: 16 << 20, options: options)
        _ = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil)
        return (store, folder)
    }
    static func transaction(_ store: Store) -> StorageRelocation.Transaction {
        .init(manager: SnapshotStorageManager(location: StoreLocation(bootstrapRoot: store.root)))
    }
    static func unsafe(_ name: String, at url: URL, root: URL) throws {
        switch name {
        case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root)
        case "hardlink":
            let target = root.appendingPathComponent("hardlink-" + UUID().uuidString)
            try Data("untouched".utf8).write(to: target)
            guard link(target.path, url.path) == 0 else { throw NestError("fixture link") }
        case "fifo": guard mkfifo(url.path, 0o600) == 0 else { throw NestError("fixture fifo") }
        case "directory": try Store.privateDirectory(url)
        default: throw NestError("unknown variant")
        }
    }
    static func finderMetadata() throws {
        let root = try root()
        let (store, folder) = try fixture(root, "harmless")
        let finder = store.root.appendingPathComponent(".DS_Store")
        try Data("Finder fixture".utf8).write(to: finder)
        guard chmod(finder.path, 0o644) == 0 else { throw NestError("fixture mode") }
        let before = try DirectoryHandle.open(store.root).entryStat(".DS_Store")
        try RepositoryReset.validateNamespace(store: store)
        let prepared = try RepositoryReset.prepare(store: store, transaction: transaction(store))
        try check(!prepared.inventory.contains { $0.path == ".DS_Store" }, "Finder metadata excluded from deletion inventory")
        var boundary = EngineSession()
        boundary.resetCheckpoint = { if $0 == "prepared" { throw NestError("fixture pause") } }
        _ = try rejects { try Engine(store: store, session: boundary).reset() }
        try check(store.resetPending, "receipt persisted before retry")
        // Finder may update its own bytes while RESET is paused. Keep them.
        try Data("Finder updated fixture".utf8).write(to: finder)
        try Engine(store: store).reset()
        try check(try store.load().folders.isEmpty && !store.resetPending, "retry completed")
        try check(try Data(contentsOf: finder) == Data("Finder updated fixture".utf8), "Finder bytes preserved")
        try check(try DirectoryHandle.open(store.root).entryStat(".DS_Store").st_ino == before.st_ino, "Finder inode preserved")
        try check(try Data(contentsOf: URL(fileURLWithPath: folder.path).appendingPathComponent("payload")) == Data("checkpoint bytes".utf8), "selected content retained")
        for variant in ["symlink", "hardlink", "fifo", "directory"] {
            for phase in ["preflight", "finish", "retry"] {
                let (store, folder) = try fixture(root, variant + phase)
                let finder = store.root.appendingPathComponent(".DS_Store")
                if phase != "preflight" {
                    let receipt = try RepositoryReset.prepare(store: store, transaction: transaction(store))
                    try Store.atomicJSON(receipt, store.root.appendingPathComponent(RepositoryReset.receiptName))
                }
                try unsafe(variant, at: finder, root: root)
                let failure: String
                if phase == "preflight" {
                    failure = try rejects { try RepositoryReset.validateNamespace(store: store) }
                    _ = try rejects { _ = try RepositoryReset.prepare(store: store, transaction: transaction(store)) }
                } else if phase == "finish" {
                    let receipt = try Store.read(RepositoryReset.Receipt.self, store.root.appendingPathComponent(RepositoryReset.receiptName))
                    failure = try rejects { try store.access(exclusive: true) {
                        try RepositoryReset.finish(receipt, store: store, transaction: transaction(store), checkpoint: nil)
                    } }
                } else { failure = try rejects { try Engine(store: store).reset() } }
                try check(failure.contains(".DS_Store"), "safe offending name: " + variant + phase + ": " + failure)
                try check(try Store.read(Configuration.self, store.root.appendingPathComponent("configuration.json")).folders.map(\.id) == [folder.id], "unsafe metadata retains records")
                try check(try DirectoryHandle.open(store.root.appendingPathComponent("volumes/" + folder.id.uuidString)).exists("revisions"), "unsafe metadata retains snapshots")
            }
        }
        let (unknown, _) = try fixture(root, "unknown")
        try Data().write(to: unknown.root.appendingPathComponent("foreign\nentry"))
        let failure = try rejects { try RepositoryReset.validateNamespace(store: unknown) }
        try check(failure.contains("foreign") && !failure.contains("\n"), "unknown name safely identified")
        let (recovery, pendingFolder) = try fixture(root, "recovery")
        try Data().write(to: recovery.root.appendingPathComponent(".DS_Store"))
        var pending = try recovery.journal(pendingFolder.id); pending.phase = .recoveryRequired
        try recovery.write(pending, for: pendingFolder.id)
        let denied = try rejects { try Engine(store: recovery).reset() }
        try check(denied.contains("recovery") && !recovery.resetPending, "Finder allowance never clears required recovery")
        var foreign = before; foreign.st_dev = before.st_dev == 1 ? 2 : 1
        _ = try rejects { try RepositoryReset.validateFinderMetadata(foreign, device: Paths.deviceID(before.st_dev)) }
        var owner = before; owner.st_uid = getuid() + 1
        _ = try rejects { try RepositoryReset.validateFinderMetadata(owner, device: Paths.deviceID(before.st_dev)) }
        var oversized = before; oversized.st_size = (16 << 20) + 1
        _ = try rejects { try RepositoryReset.validateFinderMetadata(oversized, device: Paths.deviceID(before.st_dev)) }
        print("PASS Finder metadata: preservation, inventory/retry consistency, 12 unsafe boundaries, named unknown, recovery retained")
    }
    static func pausedPublication(_ root: URL, _ name: String, boundary: String = "completed", temporary: Bool = false, distinctRevision: Bool = false) throws -> LinkedTransactionDataFixture {
        let f = try LinkedTransactionDataFixture(root, name, temporary: temporary)
        try f.prepare(); _ = try f.evacuate(); try f.publish()
        if distinctRevision {
            let working = URL(fileURLWithPath: f.j.managedLink!.mountPath)
            try Data("latest checkpoint".utf8).write(to: working.appendingPathComponent("payload"))
            f.j.revision = try Snapshot.capture(store: f.store, folder: f.folder, source: working, previous: f.j.revision)
            try f.store.write(f.j, for: f.folder.id)
        }
        try f.discardWorkingCopy()
        f.boundary.publicationCheckpoint = { if $0 == boundary { throw NestError("fixture publication pause") } }
        let error = try rejects { try f.engine.recover(f.folder.id.uuidString) }
        try check(error.contains("fixture publication pause"), "reached publication boundary: " + error)
        f.j = try f.store.journal(f.folder.id)
        return f
    }
    static func reopened(_ f: LinkedTransactionDataFixture) throws -> Engine {
        let store = try Store(root: f.store.root); store.linkedFixtureRoot = f.mountRoot
        var boundary = EngineSession(); boundary.linkedMountRoot = f.mountRoot
        return Engine(store: store, session: boundary)
    }
    static func publicationLifecycle() throws {
        let root = try root()
        for temporary in [false, true] {
            for boundary in temporary ? ["intent", "renamed", "completed", "link-retired"] : ["intent", "renamed", "completed", "link-retired", "stage-retired"] {
                let f = try pausedPublication(root, boundary, boundary: boundary, temporary: temporary)
                let receipt = f.j.publicationRename!
                try check(receipt.publicationSwap != nil, "durable two-sided intent")
                try check((receipt.after != nil) == !["intent", "renamed"].contains(boundary), "raw completion persisted only after proof")
                let engine = try reopened(f)
                try engine.recover(f.folder.id.uuidString)
                let journal = try engine.store.journal(f.folder.id)
                try check(journal.phase == .idle && journal.lastError == nil, "reopen finishes without remount")
                try check(try Snapshot.manifest(f.selected).matchesCopy(of: f.expected), "full snapshot binding")
                try check(try Data(contentsOf: f.selected.appendingPathComponent("payload")) == Data("original".utf8), "payload survives")
            }
        }
        for mutation in ["published-inode", "link-inode", "root-xattr", "link-xattr", "payload", "source-preflight", "link-preflight", "source-inode-preflight", "legacy"] {
            let boundary = ["source-preflight", "link-preflight", "source-inode-preflight"].contains(mutation) ? "intent" : (mutation == "legacy" ? "renamed" : "completed")
            let f = try pausedPublication(root, mutation, boundary: boundary)
            let receipt = f.j.publicationRename!, swap = receipt.publicationSwap!
            let displaced = URL(fileURLWithPath: swap.sourcePath)
            switch mutation {
            case "published-inode":
                try FileManager.default.moveItem(at: f.selected, to: f.selected.appendingPathExtension("retained"))
                try Store.privateDirectory(f.selected)
            case "link-inode":
                // Keep the recorded inode allocated so reuse cannot hide replacement.
                try FileManager.default.moveItem(at: displaced, to: displaced.appendingPathExtension("retained"))
                try FileManager.default.createSymbolicLink(at: displaced, withDestinationURL: URL(fileURLWithPath: f.j.managedLink!.mountPath))
            case "root-xattr": try putXattr(f.selected)
            case "link-xattr": try putXattr(displaced)
            case "payload": try Data("mutation".utf8).write(to: f.selected.appendingPathComponent("payload"))
            case "source-preflight": try putXattr(displaced)
            case "link-preflight":
                try FileManager.default.moveItem(at: f.selected, to: f.selected.appendingPathExtension("retained"))
                try FileManager.default.createSymbolicLink(at: f.selected, withDestinationURL: URL(fileURLWithPath: f.j.managedLink!.mountPath))
            case "source-inode-preflight":
                try FileManager.default.moveItem(at: displaced, to: displaced.appendingPathExtension("retained"))
                try Store.privateDirectory(displaced)
            default:
                var legacy = receipt; legacy.version = 1; legacy.publicationSwap = nil
                f.j.publicationRename = legacy; try f.store.write(f.j, for: f.folder.id)
            }
            let engine = try reopened(f)
            let error = try rejects { try engine.recover(f.folder.id.uuidString) }
            if mutation == "legacy" { try check(error.contains("legacy incomplete publication"), "legacy requires explicit review") }
            try check(try engine.store.journal(f.folder.id).phase != .idle, "mutation stays recoverable")
            _ = try Snapshot.verified(store: engine.store, id: f.folder.id, revision: f.j.initialRevision!)
            try check(try DirectoryHandle.open(URL(fileURLWithPath: f.j.managedLink!.holdingPath)).exists("data"), "holding retained")
        }
        print("PASS publication lifecycle: 9 crash/reopen paths, 9 strict negative/review paths; no mount/helper")
    }
    static func putXattr(_ url: URL) throws {
        guard setxattr(url.path, "user.metadata-fixture", "x", 1, 0, XATTR_NOFOLLOW) == 0 else { throw NestError("fixture xattr errno \(errno)") }
    }
    static func legacyPublished(_ root: URL, _ name: String, distinctRevision: Bool = false) throws -> LinkedTransactionDataFixture {
        let f = try pausedPublication(root, name, boundary: "renamed", distinctRevision: distinctRevision)
        var receipt = f.j.publicationRename!; receipt.version = 1; receipt.publicationSwap = nil
        f.j.publicationRename = receipt; try f.store.write(f.j, for: f.folder.id)
        return f
    }
    static func journalBytes(_ f: LinkedTransactionDataFixture) throws -> Data {
        try Data(contentsOf: f.store.root.appendingPathComponent("volumes/\(f.folder.id.uuidString)/journal.json"))
    }
    static func reviewedCompletion() throws {
        let root = try root(), f = try legacyPublished(root, "review-completion"), engine = try reopened(f)
        let ordinary = try rejects { try engine.recover(f.folder.id.uuidString) }
        try check(ordinary.contains("legacy incomplete publication"), "ordinary Recover remains strict")
        let raw = try journalBytes(f), config = try Data(contentsOf: f.store.root.appendingPathComponent("configuration.json"))
        let review = try engine.reviewLegacyPublication(f.folder.id.uuidString)
        try check(try journalBytes(f) == raw && Data(contentsOf: f.store.root.appendingPathComponent("configuration.json")) == config, "preflight is read only")
        _ = try rejects { _ = try engine.reviewLegacyPublication(f.folder.id.uuidString) }
        _ = try rejects { try engine.confirmLegacyPublicationReview(review, token: UUID(), acceptsMissingHistoricRecord: true) }
        _ = try rejects { try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: false) }
        engine.cancelLegacyPublicationReview(review)
        _ = try rejects { try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: true) }
        try check(try journalBytes(f) == raw && Data(contentsOf: f.store.root.appendingPathComponent("configuration.json")) == config, "cancel, duplicate review and missing acceptance have no durable effects")
        let accepted = try engine.reviewLegacyPublication(f.folder.id.uuidString)
        try engine.confirmLegacyPublicationReview(accepted, token: accepted.token, acceptsMissingHistoricRecord: true)
        let journal = try engine.store.journal(f.folder.id), ack = journal.reviewedRecovery!
        try check(journal.phase == .idle && journal.mountedDevice == nil && journal.lastError == nil, "review completes offline without mounted/busy state")
        try check(ack.completedAt != nil && ack.evidence.originalJournal == raw && ack.acceptances.map(\.token) == [accepted.token], "durable explicit acknowledgement preserves raw original journal")
        try check(journal.publicationRename!.version == 1 && journal.publicationRename!.after == nil && journal.publicationRename!.publicationSwap == nil, "never fabricates v2 authority or completes v1 proof")
        let completed = try journalBytes(f)
        _ = try rejects { try engine.confirmLegacyPublicationReview(accepted, token: accepted.token, acceptsMissingHistoricRecord: true) }
        _ = try rejects { try engine.recover(f.folder.id.uuidString) }
        _ = try rejects { try engine.mount(f.folder.id.uuidString) }
        try check(try journalBytes(f) == completed, "duplicate completion, ordinary recover and remount cause no rerun side effects")
        let reopened = try reopened(f), persisted = try reopened.store.journal(f.folder.id)
        try check(persisted == journal, "acknowledgement round-trips on reopen")
        for mutation in ["version", "acceptance", "null", "history", "completed", "unknown"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as! [String: Any]
            var record = object["reviewedRecovery"] as! [String: Any]
            switch mutation {
            case "version": record["version"] = 99
            case "acceptance":
                var admissions = record["acceptances"] as! [[String: Any]]
                admissions[0]["acceptsMissingHistoricRecord"] = false; record["acceptances"] = admissions
            case "null": object["reviewedRecovery"] = NSNull()
            case "history":
                var evidence = record["evidence"] as! [String: Any]
                evidence["originalJournal"] = Data("{}".utf8).base64EncodedString(); record["evidence"] = evidence
            case "completed": record.removeValue(forKey: "completedAt")
            default: record["waiveAllMACL"] = true
            }
            if mutation != "null" { object["reviewedRecovery"] = record }
            _ = try rejects { _ = try reopened.store.journalDecoder.decode(Journal.self, from: JSONSerialization.data(withJSONObject: object)) }
        }
        var retained = persisted
        let currentFolder = try reopened.folder(f.folder.id.uuidString)
        reopened.cleanSnapshots(currentFolder, &retained)
        SnapshotRetention.clean(store: reopened.store, folder: currentFolder, journal: &retained, validateSource: { throw NestError("must never clean") })
        SiblingCleanup.rememberCompleted(currentFolder, &retained)
        try check(retained == persisted, "retention cannot enqueue or prune acknowledged evidence")
        let originalURL = URL(fileURLWithPath: accepted.retainedOriginalPath), linkURL = URL(fileURLWithPath: accepted.retainedLinkPath)
        try check(try VerifiedRenameReceipt.observe(originalURL, matching: ack.evidence.original.manifest) == ack.evidence.original, "original holding raw evidence preserved")
        try check(try VerifiedRenameReceipt.SwapLink.observe(linkURL) == ack.evidence.displaced, "displaced symlink raw evidence preserved")
        for revision in Set([accepted.revision, accepted.initialRevision]) { _ = try Snapshot.verified(store: reopened.store, id: f.folder.id, revision: revision) }
        _ = try rejects { _ = try reopened.reviewLegacyPublication(f.folder.id.uuidString) }
        // A separately authorized fixture RESET removes managed metadata only.
        // No original/stage/link path is included in its repository inventory.
        var resetBoundary = f.boundary
        resetBoundary.resetCheckpoint = { if $0 == "prepared" { throw NestError("fixture reviewed RESET pause") } }
        _ = try rejects { try Engine(store: reopened.store, session: resetBoundary).reset() }
        try check(reopened.store.resetPending, "reviewed RESET crash leaves durable deletion receipt")
        try check(try VerifiedRenameReceipt.SwapLink.observe(linkURL) == ack.evidence.displaced, "prepared RESET preserves external link")
        try reopened.reset()
        try check(try reopened.store.load().folders.isEmpty, "explicit fixture RESET removes records")
        try check(try VerifiedRenameReceipt.observe(originalURL, matching: ack.evidence.original.manifest) == ack.evidence.original, "RESET never deletes external original recovery folder")
        try check(try VerifiedRenameReceipt.SwapLink.observe(linkURL) == ack.evidence.displaced, "RESET never deletes displaced recovery link")
        try check(try Data(contentsOf: f.selected.appendingPathComponent("payload")) == Data("original".utf8), "selected payload retained through reviewed completion and RESET")
        print("PASS reviewed completion: read-only/cancel, explicit token+acceptance, duplicate admission, durable raw evidence, offline idle, retained backups/snapshots, external folders survive explicit fixture RESET/retry")
    }
    static func reviewedCrashRecovery() throws {
        let root = try root()
        for boundary in ["review-accepted", "review-configured", "review-released", "review-completed"] {
            let f = try legacyPublished(root, boundary)
            f.boundary.publicationCheckpoint = { if $0 == boundary { throw NestError("fixture reviewed pause") } }
            let engine = f.engine, review = try engine.reviewLegacyPublication(f.folder.id.uuidString)
            let error = try rejects { try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: true) }
            try check(error.contains("fixture reviewed pause"), "reaches acknowledged crash boundary: " + error)
            let reopened = try reopened(f), journal = try reopened.store.journal(f.folder.id)
            try check(journal.reviewedRecovery!.evidence == review.evidence, "crash/reopen retains exact evidence")
            if boundary != "review-completed" {
                let before = try journalBytes(f)
                _ = try rejects { try reopened.recover(f.folder.id.uuidString) }
                _ = try rejects { try reopened.reset() }
                try check(try journalBytes(f) == before, "ordinary Recover/RESET cannot consume unfinished acknowledgement")
                let next = try reopened.reviewLegacyPublication(f.folder.id.uuidString)
                try reopened.confirmLegacyPublicationReview(next, token: next.token, acceptsMissingHistoricRecord: true)
                let completed = try reopened.store.journal(f.folder.id)
                try check(completed.phase == .idle && completed.reviewedRecovery!.acceptances.count == 2, "fresh accepted review resumes after crash")
            } else { try check(journal.phase == .idle, "completed write remains complete after crash") }
            try check(try DirectoryHandle.open(URL(fileURLWithPath: review.evidence.layout.holdingPath)).exists("data"), "every interrupted boundary preserves original")
            try check(try VerifiedRenameReceipt.SwapLink.observe(URL(fileURLWithPath: review.retainedLinkPath)) == review.evidence.displaced, "every interrupted boundary preserves displaced link")
        }
        print("PASS reviewed crash/reopen: accepted, configured, reservation released, completed; fresh explicit retry and unfinished RESET blocking")
    }
    static func reviewedStaleRejection() throws {
        let root = try root()
        for mutation in ["published-inode", "link-inode", "root-xattr", "link-xattr", "payload", "holding-payload", "holding-xattr", "journal", "configuration", "journal-inode", "configuration-inode", "journal-xattr", "configuration-xattr", "revision-payload", "revision-metadata", "stage"] {
            let f = try legacyPublished(root, mutation), engine = try reopened(f)
            let review = try engine.reviewLegacyPublication(f.folder.id.uuidString)
            switch mutation {
            case "published-inode":
                try FileManager.default.moveItem(at: f.selected, to: f.selected.appendingPathExtension("retained")); try Store.privateDirectory(f.selected)
            case "link-inode":
                let url = URL(fileURLWithPath: review.retainedLinkPath)
                try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("retained"))
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: f.j.managedLink!.mountPath))
            case "root-xattr": try putXattr(f.selected)
            case "link-xattr": try putXattr(URL(fileURLWithPath: review.retainedLinkPath))
            case "payload": try Data("changed".utf8).write(to: f.selected.appendingPathComponent("payload"))
            case "holding-payload": try Data("changed".utf8).write(to: URL(fileURLWithPath: review.retainedOriginalPath).appendingPathComponent("payload"))
            case "holding-xattr": try putXattr(URL(fileURLWithPath: review.retainedOriginalPath))
            case "journal": var j = try engine.store.journal(f.folder.id); j.lastError = "changed review"; try engine.store.write(j, for: f.folder.id)
            case "configuration": var c = try engine.store.load(); c.menuBarMode.toggle(); try engine.store.save(c)
            case "journal-inode", "configuration-inode":
                let url = mutation == "journal-inode" ? f.store.root.appendingPathComponent("volumes/\(f.folder.id.uuidString)/journal.json") : f.store.root.appendingPathComponent("configuration.json")
                let bytes = try Data(contentsOf: url)
                try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("retained"))
                try Store.atomicData(bytes, url)
            case "journal-xattr": try putXattr(f.store.root.appendingPathComponent("volumes/\(f.folder.id.uuidString)/journal.json"))
            case "configuration-xattr": try putXattr(f.store.root.appendingPathComponent("configuration.json"))
            case "revision-payload":
                let data = try Snapshot.dataURL(store: f.store, id: f.folder.id, revision: review.revision)
                try Data("changed".utf8).write(to: data.appendingPathComponent("payload"))
            case "revision-metadata":
                let data = try Snapshot.dataURL(store: f.store, id: f.folder.id, revision: review.revision)
                try putXattr(data.deletingLastPathComponent().appendingPathComponent("manifest.json"))
            default: try Data("foreign".utf8).write(to: URL(fileURLWithPath: review.evidence.stagePath).appendingPathComponent("foreign"))
            }
            let before = try journalBytes(f), config = try Data(contentsOf: f.store.root.appendingPathComponent("configuration.json"))
            _ = try rejects { try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: true) }
            try check(try journalBytes(f) == before && Data(contentsOf: f.store.root.appendingPathComponent("configuration.json")) == config, "stale " + mutation + " rejected before metadata mutation")
            try check(try engine.store.journal(f.folder.id).reviewedRecovery == nil, "stale " + mutation + " creates no acknowledgement")
            _ = try rejects { try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: true) }
            try check(try DirectoryHandle.open(URL(fileURLWithPath: review.evidence.layout.holdingPath)).exists("data"), "stale " + mutation + " retains backups")
        }
        print("PASS reviewed stale rejection: 16 inode/xattr/payload/holding/journal/config/revision/stage changes, including identical-byte control replacement; no metadata mutation or repeated token effects")
    }
    static func reviewedMACLAndNativeModels() throws {
        let f = try legacyPublished(root(), "reviewed-value-models")
        let engine = try reopened(f), review = try engine.reviewLegacyPublication(f.folder.id.uuidString)
        defer { engine.cancelLegacyPublicationReview(review) }
        var legacy = f.j.publicationRename!
        let observed = review.evidence.published
        var displaced = review.evidence.displaced
        // Captured digest/length only, all changes below are Swift values.
        // Never writes, reapplies or recreates grant bytes on the filesystem.
        let grant = VerifiedRenameReceipt.MACL(digest: "7fcac7fe1fe5f6d77213793b8a5f5a0a6c1ad3fc438e3ec5c85bc08fbe727687", bytes: 72)
        let cost = grant.bytes + UInt64(VerifiedRenameReceipt.MACL.name.utf8.count)
        legacy.before.manifest.publicRoot!.attributes[VerifiedRenameReceipt.MACL.name] = grant.digest
        legacy.before.manifest.publicRoot!.attributeBytes += cost
        displaced.macl = grant; displaced.entry.attributes[VerifiedRenameReceipt.MACL.name] = grant.digest
        displaced.entry.attributeBytes += cost
        try legacy.validateReviewedPublication(observed, macl: review.evidence.publishedMACL, displaced: displaced)
        try check(legacy.after == nil && legacy.version == 1, "review model never makes proof authority")
        var changed = observed; changed.manifest.entries[0].attributes[VerifiedRenameReceipt.MACL.name] = grant.digest
        changed.manifest.entries[0].attributeBytes += cost
        _ = try rejects { try legacy.validateReviewedPublication(changed, macl: review.evidence.publishedMACL, displaced: displaced) }
        changed = observed; changed.manifest.publicRoot!.attributes["user.other"] = "changed"
        _ = try rejects { try legacy.validateReviewedPublication(changed, macl: review.evidence.publishedMACL, displaced: displaced) }
        var wrongLink = displaced; wrongLink.macl.digest = String(repeating: "0", count: 64)
        _ = try rejects { try legacy.validateReviewedPublication(observed, macl: review.evidence.publishedMACL, displaced: wrongLink) }
        _ = try rejects { try legacy.validateReviewedPublication(observed, macl: grant, displaced: displaced) }
        // Native wire-only model: no native root is opened or helper invoked.
        // The transaction fixture above exercises the shared disk operations.
        let old = review.evidence
        var base = try old.originalState(fixtureRoot: f.mountRoot), layout = old.layout
        layout.version = 2; layout.mountRoot = NativeTmpfsPaths.root.path; layout.mountPath = NativeTmpfsPaths.data(layout.session).path
        base.managedLink = layout; base.backend = .tmpfs
        var native = NativeTmpfsRecord(session: layout.session, capacity: f.folder.capacity)
        native.filesystem = NativeFilesystemID(first: 1, second: 2); native.data = layout.mountpoint; native.managedUnmount = true
        base.nativeTmpfs = native; base.mountedDevice = native.data!.device
        let baseBytes = try JSONEncoder().encode(base)
        var nativeLink = old.displaced
        nativeLink.entry.checksum = layout.mountPath; nativeLink.entry.size = Int64(layout.mountPath.utf8.count); nativeLink.node.size = nativeLink.entry.size
        let evidence = ReviewedPublicationEvidence(folder: old.folder, originalJournal: baseBytes, layout: layout, stagePath: old.stagePath,
            parent: old.parent, stage: old.stage, holding: old.holding, published: old.published, publishedMACL: old.publishedMACL,
            displaced: nativeLink, original: old.original, initial: old.initial, latest: old.latest)
        let accepted = ReviewedRecoveryAcknowledgement.Acceptance(token: UUID(), date: Date(), acceptsMissingHistoricRecord: true)
        base.reviewedRecovery = .init(evidence: evidence, acceptance: accepted)
        let pending = try JSONDecoder().decode(Journal.self, from: JSONEncoder().encode(base))
        try check(pending.reviewedRecovery!.completedAt == nil, "native pending acknowledgement decodes")
        base.nativeLink!.stage = .restored; base.nativeLink!.mountReleased = true
        try NativeJournalTransition.completeIdle(&base)
        base.reviewedRecovery!.completedAt = Date(); base.cleanupWarning = base.reviewedRecovery!.retentionNotice
        let complete = try JSONDecoder().decode(Journal.self, from: JSONEncoder().encode(base))
        try check(complete.nativeSessionCompleted && complete.phase == .idle && complete.restoreStage != nil && complete.evacuation != nil, "native completed acknowledgement decodes with recovery copies retained")
        var ordinary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(complete)) as! [String: Any]
        ordinary.removeValue(forKey: "reviewedRecovery")
        // Native ordinary recovery still sees the original v1 incomplete proof;
        // no v2 capability was created by the acknowledged metadata transition.
        let noAck = try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: ordinary))
        _ = try rejects { _ = try noAck.publicationRename!.verify(at: f.selected) }
        print("PASS reviewed value models: captured MACL root difference only, unrelated/descendant MACL rejection, native pending/completed journal persistence; no grant bytes or native filesystem operations")
    }
    static func reviewedBusyAdmission() throws {
        let f = try legacyPublished(root(), "busy-review")
        let other = try reopened(f), otherReview = try other.reviewLegacyPublication(f.folder.id.uuidString)
        var engine: Engine!, review: LegacyPublicationReview!
        var sawBusy = false
        f.boundary.publicationCheckpoint = { boundary in
            guard boundary == "review-accepted" else { return }
            let before = try journalBytes(f)
            _ = try rejects { try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: true) }
            let busy = try rejects { _ = try engine.reviewLegacyPublication(f.folder.id.uuidString) }
            try check(busy.contains("busy"), "same-engine review rejected during synchronous admission")
            let foreignBusy = try rejects { try other.confirmLegacyPublicationReview(otherReview, token: otherReview.token, acceptsMissingHistoricRecord: true) }
            try check(foreignBusy.contains("busy"), "second Engine cannot pass held cross-process volume lock")
            try check(try journalBytes(f) == before, "busy and duplicate requests have no journal effects")
            sawBusy = true
        }
        engine = f.engine; review = try engine.reviewLegacyPublication(f.folder.id.uuidString)
        try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: true)
        try check(sawBusy && engine.store.journal(f.folder.id).phase == .idle, "one admitted confirmation completes")
        let completed = try journalBytes(f)
        _ = try rejects { try other.confirmLegacyPublicationReview(otherReview, token: otherReview.token, acceptsMissingHistoricRecord: true) }
        try check(try journalBytes(f) == completed, "busy token cannot be replayed after first completion")
        print("PASS reviewed busy admission: duplicate confirmation/review and second-Engine lock race rejected without deadlock or rerun effects")
    }
    static func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func reviewedFootprintAndCopies() throws {
        let f = try legacyPublished(root(), "review-copy"), engine = try reopened(f)
        let review = try engine.reviewLegacyPublication(f.folder.id.uuidString)
        defer { engine.cancelLegacyPublicationReview(review) }
        let accepted = ReviewedRecoveryAcknowledgement.Acceptance(token: UUID(), date: Date(), acceptsMissingHistoricRecord: true)
        var pending = try f.store.journal(f.folder.id)
        pending.reviewedRecovery = .init(evidence: review.evidence, acceptance: accepted)
        let before = try canonicalBytes(pending), evidenceBefore = try canonicalBytes(review.evidence)
        var complete = pending
        complete.managedLink!.stage = .restored; complete.managedLink!.mountReleased = true
        complete.phase = .idle; complete.mountedDevice = nil; complete.socket = nil; complete.lastError = nil
        complete.reviewedRecovery!.acceptances.append(.init(token: UUID(), date: accepted.date, acceptsMissingHistoricRecord: true))
        complete.reviewedRecovery!.completedAt = accepted.date
        complete.cleanupWarning = complete.reviewedRecovery!.retentionNotice
        try check(try canonicalBytes(pending) == before && pending.managedLink!.stage == .publishing && pending.reviewedRecovery!.completedAt == nil && pending.reviewedRecovery!.acceptances.count == 1, "journal stage/completion/acceptance copies stay independent")
        let decoded = try f.store.journalDecoder.decode(Journal.self, from: canonicalBytes(complete))
        try check(decoded == complete, "completed copy round-trips independently")
        var separateAck = pending.reviewedRecovery!
        separateAck.version = 9; separateAck.acceptances.removeAll(); separateAck.completedAt = accepted.date
        try check(pending.reviewedRecovery!.version == 1 && pending.reviewedRecovery!.acceptances.count == 1 && pending.reviewedRecovery!.completedAt == nil, "acknowledgement retains value semantics")
        // Compare against the pre-box wire contract, independently of the
        // acknowledgement's encoder. No extra reference-wrapper key is legal.
        struct OriginalWire: Encodable {
            let version: Int
            let evidence: ReviewedPublicationEvidence
            let acceptances: [ReviewedRecoveryAcknowledgement.Acceptance]
            let completedAt: Date?
        }
        for ack in [pending.reviewedRecovery!, complete.reviewedRecovery!] {
            let wire = OriginalWire(version: ack.version, evidence: ack.evidence, acceptances: ack.acceptances, completedAt: ack.completedAt)
            try check(try canonicalBytes(ack) == canonicalBytes(wire), "exact canonical acknowledgement wire shape")
            try check(try canonicalBytes(ack.evidence) == evidenceBefore, "immutable evidence bytes survive journal copies")
        }
        print("PASS reviewed copies and canonical wire equivalence")
        let ack = MemoryLayout<ReviewedRecoveryAcknowledgement>.stride, journal = MemoryLayout<Journal>.stride
        print("Reviewed inline strides: acknowledgement=\(ack), journal=\(journal), sibling=\(MemoryLayout<SiblingCleanupCandidate>.stride)")
        try check(ack <= 64 && journal <= 4096, "inline size budgets: acknowledgement <= 64 and Journal <= 4096 bytes")
        print("PASS reviewed footprint budgets")
    }
    // Mutate only newly acknowledgement-owned objects; historical decoders
    // retain their compatibility policy. Exercise both direct ack and Journal
    // decoding so corrupt durable state cannot reach completed RESET admission.
    static func mutateReviewed(_ journal: Journal, store: Store, path: [String], mutation: (inout [String: Any]) -> Void) throws -> Bool {
        var object = try JSONSerialization.jsonObject(with: canonicalBytes(journal)) as! [String: Any]
        func edit(_ object: inout [String: Any], _ path: ArraySlice<String>) {
            guard let key = path.first else { mutation(&object); return }
            if key == "acceptances" {
                var array = object[key] as! [[String: Any]]; edit(&array[0], path.dropFirst()); object[key] = array
            } else {
                var child = object[key] as! [String: Any]; edit(&child, path.dropFirst()); object[key] = child
            }
        }
        edit(&object, (["reviewedRecovery"] + path)[...])
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let ackBytes = try JSONSerialization.data(withJSONObject: object["reviewedRecovery"]!)
        let decoder = store.journalDecoder
        let ackRejected: Bool
        do { _ = try decoder.decode(ReviewedRecoveryAcknowledgement.self, from: ackBytes); ackRejected = false } catch { ackRejected = true }
        let journalRejected: Bool
        do { _ = try decoder.decode(Journal.self, from: bytes); journalRejected = false } catch { journalRejected = true }
        return ackRejected && journalRejected
    }
    static func completedReviewFixture(_ name: String, distinctRevision: Bool = false) throws -> (LinkedTransactionDataFixture, Journal) {
        let f = try legacyPublished(root(), name, distinctRevision: distinctRevision), engine = try reopened(f)
        let review = try engine.reviewLegacyPublication(f.folder.id.uuidString)
        try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: true)
        let journal = try engine.store.journal(f.folder.id)
        try RepositoryReset.idle(journal)
        return (f, journal)
    }
    static func reviewedCanonicalFields() throws {
        let (f, journal) = try completedReviewFixture("review-canonical")
        let evidenceKeys = ["folder", "originalJournal", "layout", "stagePath", "parent", "stage", "holding", "published", "publishedMACL", "displaced", "original", "initial", "latest"]
        let cases: [([String], [String])] = [([], ["version", "evidence", "acceptances"]), (["evidence"], evidenceKeys), (["evidence", "initial"], ["id", "logical", "materialized", "raw"]), (["evidence", "latest"], ["id", "logical", "materialized", "raw"]), (["acceptances"], ["token", "date", "acceptsMissingHistoricRecord"])]
        var failures: [String] = []; var count = 0
        for (path, keys) in cases {
            for value: Any in [true, NSNull()] {
                count += 1
                if try !mutateReviewed(journal, store: f.store, path: path, mutation: { $0["unknown-policy"] = value }) { failures.append(path.joined(separator: ".") + ":unknown") }
            }
            for key in keys {
                for null in [false, true] {
                    count += 1
                    if try !mutateReviewed(journal, store: f.store, path: path, mutation: { if null { $0[key] = NSNull() } else { $0.removeValue(forKey: key) } }) { failures.append((path + [key]).joined(separator: ".") + (null ? ":null" : ":missing")) }
                }
            }
        }
        count += 1
        if try !mutateReviewed(journal, store: f.store, path: [], mutation: { $0["completedAt"] = NSNull() }) { failures.append("completedAt:null") }
        try check(failures.isEmpty, "canonical acknowledgement fields accepted corrupt cases: " + failures.joined(separator: ", "))
        print("PASS reviewed canonical fields: \(count) unknown/value/null and missing/null-required mutations rejected by both acknowledgement and journal decoding")
    }
    static func reviewedRevisionBindings() throws {
        let (f, journal) = try completedReviewFixture("review-bindings", distinctRevision: true)
        try check(journal.initialRevision != journal.revision && journal.reviewedRecovery!.evidence.initial.logical != journal.reviewedRecovery!.evidence.latest.logical, "binding fixture uses distinct initial/latest IDs and contents")
        var failures: [String] = []; var count = 0
        for revision in ["initial", "latest"] {
            for view in ["logical", "materialized", "raw"] {
                for field in ["checksum", "size", "mode", "attributes", "hardlink", "namespace"] {
                    count += 1
                    let rejected = try mutateReviewed(journal, store: f.store, path: ["evidence", revision]) { record in
                        var manifest = record[view] as! [String: Any]
                        if view == "raw" { manifest = manifest["manifest"] as! [String: Any] }
                        var entries = manifest["entries"] as! [[String: Any]]
                        let index = entries.firstIndex { ($0["path"] as? String) == (view == "raw" ? "data/payload" : "payload") }!
                        switch field {
                        case "checksum": entries[index][field] = String(repeating: "0", count: 64)
                        case "size": entries[index][field] = 99
                        case "mode": entries[index][field] = 0
                        case "attributes": entries[index][field] = ["com.apple.macl": String(repeating: "0", count: 64)]
                        case "hardlink": entries[index][field] = "foreign"
                        default: entries.remove(at: index)
                        }
                        manifest["entries"] = entries
                        if view == "raw" { var raw = record[view] as! [String: Any]; raw["manifest"] = manifest; record[view] = raw }
                        else { record[view] = manifest }
                    }
                    if !rejected { failures.append(revision + "." + view + "." + field) }
                }
            }
            for field in ["id", "nodes"] {
                count += 1
                if try !mutateReviewed(journal, store: f.store, path: ["evidence", revision], mutation: { record in
                    if field == "id" { record["id"] = UUID().uuidString }
                    else { var raw = record["raw"] as! [String: Any]; var nodes = raw["nodes"] as! [[String: Any]]; nodes[0]["inode"] = 0; raw["nodes"] = nodes; record["raw"] = raw }
                }) { failures.append(revision + "." + field) }
            }
        }
        try check(failures.isEmpty, "inconsistent completed revision evidence accepted: " + failures.joined(separator: ", "))
        print("PASS reviewed revision binding: \(count) independent initial/latest logical/materialized/raw payload, namespace, inode and revision-ID mutations rejected before completed RESET admission")
    }
    static func maclRelationship() throws {
        let f = try pausedPublication(root(), "captured-macl-model")
        let raw = f.j.publicationRename!
        try check(raw.publicationSwap!.directoryBefore.digest == nil && raw.publicationSwap!.linkBefore.macl.digest == nil, "owned model base has authentic no-MACL sides")
        // Pure receipt-value tests from the captured kernel report. No MACL is
        // manufactured, copied, removed, or applied to any filesystem object.
        // report.json beforeSource / afterSource, captured by the parent on
        // internal APFS. Keep this model runnable without ignored artifacts.
        let grant = VerifiedRenameReceipt.MACL(digest: "7fcac7fe1fe5f6d77213793b8a5f5a0a6c1ad3fc438e3ec5c85bc08fbe727687", bytes: 72)
        let absent = VerifiedRenameReceipt.MACL(digest: nil, bytes: 0)
        try check(grant.digest != nil && grant.bytes == 72, "genuine captured nonempty evidence")
        func adding(_ entry: Entry, _ macl: VerifiedRenameReceipt.MACL) -> Entry {
            var e = entry
            if let digest = macl.digest { e.attributes[VerifiedRenameReceipt.MACL.name] = digest; e.attributeBytes += macl.bytes + UInt64(VerifiedRenameReceipt.MACL.name.utf8.count) }
            return e
        }
        for (directory, link) in [(absent, absent), (grant, absent), (absent, grant), (grant, grant)] {
            var receipt = raw
            receipt.before.manifest.publicRoot = adding(raw.before.manifest.publicRoot!, directory)
            receipt.after!.manifest.publicRoot = adding(raw.after!.manifest.publicRoot!, link)
            receipt.publicationSwap!.directoryBefore = directory; receipt.publicationSwap!.directoryAfter = link
            receipt.publicationSwap!.linkBefore.macl = link
            receipt.publicationSwap!.linkBefore.entry = adding(raw.publicationSwap!.linkBefore.entry, link)
            receipt.publicationSwap!.linkAfter!.macl = directory
            receipt.publicationSwap!.linkAfter!.entry = adding(raw.publicationSwap!.linkAfter!.entry, directory)
            try receipt.validate()
            let decoded = try JSONDecoder().decode(VerifiedRenameReceipt.self, from: JSONEncoder().encode(receipt))
            try check(decoded == receipt && receipt.before == decoded.before, "raw before/after round-trip")
            try check(try receipt.matchesPublicationCopy(receipt.after!.manifest, of: receipt.before.manifest), "only proven publication view binds copy")
            if directory != link {
                try check(try !receipt.after!.manifest.matchesCopy(of: receipt.before.manifest), "global copy comparison remains MACL strict")
            }
            if directory != link {
                var normalRename = receipt; normalRename.version = 1; normalRename.publicationSwap = nil
                _ = try rejects { try normalRename.validate() }
            }
            var changed = receipt; changed.publicationSwap!.linkAfter!.macl.digest = String(repeating: "0", count: 64)
            _ = try rejects { try changed.validate() }
            changed = receipt; changed.publicationSwap!.directoryAfter.bytes = (1 << 20) + 1
            _ = try rejects { try changed.validate() }
            changed = receipt; changed.publicationSwap!.directoryBefore.digest = "corrupt"
            _ = try rejects { try changed.validate() }
            changed = receipt; changed.before.nodes[0].inode += 1
            _ = try rejects { try changed.validate() }
            changed = receipt; changed.publicationSwap!.linkAfter!.node.inode += 1
            _ = try rejects { try changed.validate() }
            changed = receipt; changed.after!.manifest.publicRoot!.attributes["user.unrelated"] = "changed"
            _ = try rejects { try changed.validate() }
            changed = receipt; changed.wholeRoot = false
            _ = try rejects { try changed.validate() }
            changed = receipt; changed.operation = .evacuation
            _ = try rejects { try changed.validate() }
            var intent = receipt; intent.after = nil; intent.publicationSwap!.linkAfter = nil
            try intent.validate()
            _ = try rejects { _ = try intent.verifyStrictIncomplete(at: f.selected) }
        }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as! [String: Any]
        object["publicationSwap"] = NSNull()
        _ = try rejects { _ = try JSONDecoder().decode(VerifiedRenameReceipt.self, from: JSONSerialization.data(withJSONObject: object)) }
        object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as! [String: Any]
        object["version"] = 99
        _ = try rejects { _ = try JSONDecoder().decode(VerifiedRenameReceipt.self, from: JSONSerialization.data(withJSONObject: object)) }
        for field in ["unknown-policy", "directoryBefore", "linkAfter"] {
            object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as! [String: Any]
            var swap = object["publicationSwap"] as! [String: Any]
            if field == "directoryBefore" {
                var macl = swap[field] as! [String: Any]; macl["unknown-grant"] = true; swap[field] = macl
            } else if field == "linkAfter" { swap[field] = NSNull() }
            else { swap[field] = "waive" }
            object["publicationSwap"] = swap
            _ = try rejects { _ = try JSONDecoder().decode(VerifiedRenameReceipt.self, from: JSONSerialization.data(withJSONObject: object)) }
        }
        print("PASS captured MACL receipt models: 4 presence combinations, raw round-trips, strict copy and negative authority checks")
    }
}

#if RAMNEST_METADATA_STANDALONE
@main struct MetadataRecoveryTestRunner {
    static func main() {
        do {
            let targeted: [String: () throws -> Void] = ["footprint": MetadataRecoveryScenarios.reviewedFootprintAndCopies, "canonical": MetadataRecoveryScenarios.reviewedCanonicalFields, "binding": MetadataRecoveryScenarios.reviewedRevisionBindings]
            if let name = CommandLine.arguments.dropFirst().first, let run = targeted[name] { try run(); return }
            try MetadataRecoveryScenarios.reviewedFootprintAndCopies()
            try MetadataRecoveryScenarios.reviewedCanonicalFields()
            try MetadataRecoveryScenarios.reviewedRevisionBindings()
            try MetadataRecoveryScenarios.finderMetadata()
            try MetadataRecoveryScenarios.publicationLifecycle()
            try MetadataRecoveryScenarios.maclRelationship()
            try MetadataRecoveryScenarios.reviewedCompletion()
            try MetadataRecoveryScenarios.reviewedCrashRecovery()
            try MetadataRecoveryScenarios.reviewedStaleRejection()
            try MetadataRecoveryScenarios.reviewedMACLAndNativeModels()
            try MetadataRecoveryScenarios.reviewedBusyAdmission()
        }
        catch { FileHandle.standardError.write(Data("FAIL metadata recovery: \(error)\n".utf8)); exit(1) }
    }
}
#else
extension RAMNestTestSuite {
    struct MetadataRecoveryTests {
        @Test func finderMetadata() throws { try MetadataRecoveryScenarios.finderMetadata() }
        @Test func publicationLifecycle() throws { try MetadataRecoveryScenarios.publicationLifecycle() }
        @Test func maclRelationship() throws { try MetadataRecoveryScenarios.maclRelationship() }
        @Test func reviewedCompletion() throws { try MetadataRecoveryScenarios.reviewedCompletion() }
        @Test func reviewedCrashRecovery() throws { try MetadataRecoveryScenarios.reviewedCrashRecovery() }
        @Test func reviewedStaleRejection() throws { try MetadataRecoveryScenarios.reviewedStaleRejection() }
        @Test func reviewedMACLAndNativeModels() throws { try MetadataRecoveryScenarios.reviewedMACLAndNativeModels() }
        @Test func reviewedBusyAdmission() throws { try MetadataRecoveryScenarios.reviewedBusyAdmission() }
        @Test func reviewedFootprintAndCopies() throws { try MetadataRecoveryScenarios.reviewedFootprintAndCopies() }
        @Test func reviewedCanonicalFields() throws { try MetadataRecoveryScenarios.reviewedCanonicalFields() }
        @Test func reviewedRevisionBindings() throws { try MetadataRecoveryScenarios.reviewedRevisionBindings() }
    }
}
#endif
