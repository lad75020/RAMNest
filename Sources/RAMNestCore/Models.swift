import Foundation
import Darwin

public struct NestError: Error, LocalizedError, Sendable {
    public let message: String
    public let code: Int32
    public init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
    public var errorDescription: String? { message }
}
public enum Comparison: String, Codable, CaseIterable, Sendable { case sizeAndModTime, checksum }
// Immutable per-session/revision authority, independent of incremental selection.
public enum FileVerification: String, Codable, CaseIterable, Sendable {
    case sha256, sizeAndModTime
    public var displayName: String { self == .sha256 ? "SHA-256" : "Size and modification time" }
}
public struct FolderOptions: Codable, Equatable, Sendable {
    // Historical decode-only preference; native tmpfs has no app page compressor.
    public var legacyCompression: Bool?
    public var mountAtLaunch = true
    public var nobrowse = true
    public var sync = true
    public var periodicSave = false
    public var intervalMinutes = 15
    public var comparison = Comparison.sizeAndModTime
    public static let intervals = [5, 15, 30, 60, 360, 720, 1440]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case legacyCompression = "compression"
        case mountAtLaunch, nobrowse, sync, periodicSave, intervalMinutes, comparison
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        legacyCompression = c.contains(.legacyCompression) ? try c.decode(Bool.self, forKey: .legacyCompression) : nil
        mountAtLaunch = try c.decode(Bool.self, forKey: .mountAtLaunch)
        nobrowse = try c.decode(Bool.self, forKey: .nobrowse); sync = try c.decode(Bool.self, forKey: .sync)
        periodicSave = try c.decode(Bool.self, forKey: .periodicSave)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        comparison = try c.decode(Comparison.self, forKey: .comparison)
    }

}
public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var capacity: UInt64
    public var device: UInt64
    public var inode: UInt64
    public var bookmark: Data?
    public var options: FolderOptions
    public init(id: UUID = UUID(), name: String, path: String, capacity: UInt64, device: UInt64, inode: UInt64, bookmark: Data? = nil, options: FolderOptions = .init()) {
        self.id = id; self.name = name; self.path = path; self.capacity = capacity; self.device = device; self.inode = inode; self.bookmark = bookmark; self.options = options
    }
}
public enum Phase: String, Codable, Sendable { case idle, preparing, evacuated, mounting, mounted, ejecting, pendingRestore, restoring, recoveryRequired }
public struct Journal: Codable, Equatable, Sendable {
    public var phase = Phase.idle
    public var session: UUID?
    public var backend: Configuration.Backend?
    public var fileVerification = FileVerification.sha256
    public var socket: String?
    public var initialRevision: String?
    public var revision: String?
    public var priorRevision: String?
    public var nativeGeneration: String?
    public var quiescedRevision: String?
    public var quiescedSession: UUID?
    public var quiescedHelperPID: Int32?
    public var quiescedNativeInstance: String?
    // Only journal-referenced committed revisions are eligible for retirement.
    // Optional fields keep pre-retention journals readable.
    public var retiringRevisions: [String]?
    public var cleanupWarning: String?
    public var siblingCleanup: [SiblingCleanupCandidate]?
    public var evacuation: String?
    public var evacuationDevice: UInt64?
    public var evacuationInode: UInt64?
    public var evacuatedEntries: [String] = []
    public var restoredEntries: [String] = []
    public var restoreRevision: String?
    var initialSourceManifest: Manifest?
    var originalRename: VerifiedRenameReceipt?
    var publicationRename: VerifiedRenameReceipt?
    var reviewedRecovery: ReviewedRecoveryAcknowledgement?
    public var reviewedRecoveryNotice: String? {
        guard let reviewedRecovery else { return nil }
        return reviewedRecovery.completedAt == nil ? "Reviewed recovery was interrupted. Backups and acknowledgement are retained; Review Legacy Recovery again to inspect and explicitly confirm a retry." : reviewedRecovery.retentionNotice
    }
    var restoreManifest: Manifest?
    public var restoreStage: String?
    public var restoreStageDevice: UInt64?
    public var restoreStageInode: UInt64?
    public var restoreDataDevice: UInt64?
    public var restoreDataInode: UInt64?
    var publicationReceipt: PublicationReceipt?
    public var mountedDevice: UInt64?
    public var populationVerified = false
    public var legacyLink: LinkedFolderLayout?
    public var nativeLink: LinkedFolderLayout?
    public var nativeTmpfs: NativeTmpfsRecord?
    // RESET records admission before eject, so a crash after idle publication
    // cannot lose ownership of deferred holding/snapshot cleanup.
    var resetUnmountSession: UUID?
    public var resetUnmountPending: Bool { resetUnmountSession != nil }
    var resetUnmountCompleted: Bool {
        nativeSessionCompleted && resetUnmountSession == nativeTmpfs?.session &&
            resetUnmountSession != nil && nativeTmpfs?.managedUnmount == true
    }
    // A completed layout is historical publication evidence, not live mount
    // authority. Idle retention may release its initial/restore revision pins.
    var nativeSessionCompleted: Bool {
        phase == .idle && nativeTmpfs != nil && nativeLink?.stage == .restored && nativeLink?.mountReleased == true
    }
    // Shared transaction implementation, with separate on-disk discriminators.
    var managedLink: LinkedFolderLayout? {
        get { nativeLink ?? legacyLink }
        set {
            if newValue?.version == 2 { nativeLink = newValue; legacyLink = nil }
            else { legacyLink = newValue; nativeLink = nil }
        }
    }
    // Only absence of all three keys selects the legacy recovery contract.
    // A negotiated pre-mount helper must be sealed + retired before rollback,
    // including after a coordinator crash when its OS mount is still absent.
    var startupProtocol: String?
    var startupHelperPID: Int32?
    var startupRetired: Bool?
    public var lastError: String?
    public var updated = Date()
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case phase, session, backend, fileVerification, socket, initialRevision, revision, priorRevision
        case nativeGeneration, quiescedRevision, quiescedSession, quiescedHelperPID, quiescedNativeInstance
        case retiringRevisions, cleanupWarning, siblingCleanup, evacuation, evacuationDevice, evacuationInode
        case evacuatedEntries, restoredEntries, initialSourceManifest, restoreManifest, restoreRevision, restoreStage, restoreStageDevice, restoreStageInode
        case restoreDataDevice, restoreDataInode, publicationReceipt, mountedDevice, populationVerified
        case startupProtocol, startupHelperPID, startupRetired, lastError, updated
        case legacyLink = "fsKitLink"
        case originalRename, publicationRename, nativeLink, nativeTmpfs, resetUnmountSession, reviewedRecovery
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileVerification = values.contains(.fileVerification) ? try values.decode(FileVerification.self, forKey: .fileVerification) : .sha256
        // Validate the wire discriminator before any recovery branch can see a
        // nil protocol. Explicit null is not an old journal; nor is a partial
        // startup record, even if its remaining startup values are null.
        if values.contains(.startupProtocol) {
            startupProtocol = try values.decode(String.self, forKey: .startupProtocol)
            guard startupProtocol == LegacyJournalFormat.startupVersion else {
                throw DecodingError.dataCorruptedError(forKey: .startupProtocol, in: values,
                    debugDescription: "Unknown guarded startup journal; originals retained.")
            }
        } else {
            guard !values.contains(.startupHelperPID), !values.contains(.startupRetired) else {
                throw DecodingError.dataCorruptedError(forKey: .startupProtocol, in: values,
                    debugDescription: "Partial guarded startup journal; originals retained.")
            }
            startupProtocol = nil
        }
        // Preserve the synthesized contract for every older field: defaults
        // on stored non-optionals do not authorize missing/null wire values.
        phase = try values.decode(Phase.self, forKey: .phase)
        session = try values.decodeIfPresent(UUID.self, forKey: .session)
        backend = try values.decodeIfPresent(Configuration.Backend.self, forKey: .backend)
        socket = try values.decodeIfPresent(String.self, forKey: .socket)
        initialRevision = try values.decodeIfPresent(String.self, forKey: .initialRevision)
        revision = try values.decodeIfPresent(String.self, forKey: .revision)
        priorRevision = try values.decodeIfPresent(String.self, forKey: .priorRevision)
        nativeGeneration = try values.decodeIfPresent(String.self, forKey: .nativeGeneration)
        quiescedRevision = try values.decodeIfPresent(String.self, forKey: .quiescedRevision)
        quiescedSession = try values.decodeIfPresent(UUID.self, forKey: .quiescedSession)
        quiescedHelperPID = try values.decodeIfPresent(Int32.self, forKey: .quiescedHelperPID)
        quiescedNativeInstance = try values.decodeIfPresent(String.self, forKey: .quiescedNativeInstance)
        retiringRevisions = try values.decodeIfPresent([String].self, forKey: .retiringRevisions)
        cleanupWarning = try values.decodeIfPresent(String.self, forKey: .cleanupWarning)
        siblingCleanup = try values.decodeIfPresent([SiblingCleanupCandidate].self, forKey: .siblingCleanup)
        evacuation = try values.decodeIfPresent(String.self, forKey: .evacuation)
        evacuationDevice = try values.decodeIfPresent(UInt64.self, forKey: .evacuationDevice)
        evacuationInode = try values.decodeIfPresent(UInt64.self, forKey: .evacuationInode)
        evacuatedEntries = try values.decode([String].self, forKey: .evacuatedEntries)
        restoredEntries = try values.decode([String].self, forKey: .restoredEntries)
        restoreRevision = try values.decodeIfPresent(String.self, forKey: .restoreRevision)
        initialSourceManifest = values.contains(.initialSourceManifest) ? try values.decode(Manifest.self, forKey: .initialSourceManifest) : nil
        originalRename = values.contains(.originalRename) ? try values.decode(VerifiedRenameReceipt.self, forKey: .originalRename) : nil
        publicationRename = values.contains(.publicationRename) ? try values.decode(VerifiedRenameReceipt.self, forKey: .publicationRename) : nil
        reviewedRecovery = values.contains(.reviewedRecovery) ? try values.decode(ReviewedRecoveryAcknowledgement.self, forKey: .reviewedRecovery) : nil
        for receipt in [originalRename, publicationRename].compactMap({ $0 }) {
            guard receipt.session == session else { throw NestError("Rename receipt session mismatch; retained.", code: 6) }
        }
        if let originalRename {
            guard originalRename.operation == .evacuation, initialSourceManifest == originalRename.before.manifest,
                  evacuation != nil, evacuationDevice == originalRename.destinationDevice,
                  evacuationInode == originalRename.destinationInode else {
                throw NestError("Rename receipt source binding mismatch; retained.", code: 6)
            }
        }
        if let publicationRename, publicationRename.operation == .evacuation {
            throw NestError("Invalid publication rename operation; retained.", code: 6)
        }
        restoreManifest = values.contains(.restoreManifest) ? try values.decode(Manifest.self, forKey: .restoreManifest) : nil
        for manifest in [initialSourceManifest, restoreManifest, originalRename?.before.manifest, publicationRename?.before.manifest].compactMap({ $0 }) {
            guard manifest.fileVerification == fileVerification else { throw NestError("Journal file verification policy disagrees with transaction authority; retained.", code: 6) }
        }
        restoreStage = try values.decodeIfPresent(String.self, forKey: .restoreStage)
        restoreStageDevice = try values.decodeIfPresent(UInt64.self, forKey: .restoreStageDevice)
        restoreStageInode = try values.decodeIfPresent(UInt64.self, forKey: .restoreStageInode)
        restoreDataDevice = try values.decodeIfPresent(UInt64.self, forKey: .restoreDataDevice)
        restoreDataInode = try values.decodeIfPresent(UInt64.self, forKey: .restoreDataInode)
        publicationReceipt = try values.decodeIfPresent(PublicationReceipt.self, forKey: .publicationReceipt)
        mountedDevice = try values.decodeIfPresent(UInt64.self, forKey: .mountedDevice)
        populationVerified = try values.decode(Bool.self, forKey: .populationVerified)
        startupHelperPID = try values.decodeIfPresent(Int32.self, forKey: .startupHelperPID)
        startupRetired = try values.decodeIfPresent(Bool.self, forKey: .startupRetired)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        updated = try values.decode(Date.self, forKey: .updated)
        // Presence is authority, including explicit null. Never downgrade a
        // malformed new layout into the legacy physical-path recovery branch.
        legacyLink = values.contains(.legacyLink) ? try values.decode(LinkedFolderLayout.self, forKey: .legacyLink) : nil
        nativeLink = values.contains(.nativeLink) ? try values.decode(LinkedFolderLayout.self, forKey: .nativeLink) : nil
        nativeTmpfs = values.contains(.nativeTmpfs) ? try values.decode(NativeTmpfsRecord.self, forKey: .nativeTmpfs) : nil
        resetUnmountSession = values.contains(.resetUnmountSession) ? try values.decode(UUID.self, forKey: .resetUnmountSession) : nil
        if let resetUnmountSession {
            guard resetUnmountSession == session, resetUnmountSession == nativeTmpfs?.session else {
                throw NestError("RESET unmount provenance does not match the native session; all data retained.", code: 6)
            }
        }
        guard legacyLink == nil || (nativeLink == nil && nativeTmpfs == nil),
              legacyLink == nil || legacyLink?.version == 1,
              (nativeLink == nil) == (nativeTmpfs == nil),
              nativeLink == nil || (nativeLink?.version == 2 && backend == .tmpfs && nativeTmpfs?.session == session) else {
            throw NestError("Mixed or partial native/legacy journal authority; all data retained.", code: 6)
        }
        guard backend != .tmpfs || nativeTmpfs != nil ||
              ((phase == .idle || phase == .preparing || phase == .recoveryRequired) &&
               !populationVerified && legacyLink == nil && evacuation == nil && originalRename == nil && publicationRename == nil) else {
            throw NestError("Native session lacks native mount authority; legacy recovery is forbidden.", code: 6)
        }
        if let nativeTmpfs {
            try nativeTmpfs.validate()
            guard nativeTmpfs.uid == getuid(), nativeLink?.session == nativeTmpfs.session, startupProtocol == nil,
                  phase == .idle || !populationVerified || mountedDevice == nativeTmpfs.data?.device,
                  !populationVerified || (nativeTmpfs.filesystem != nil && nativeTmpfs.data != nil &&
                    (nativeSessionCompleted || initialRevision.flatMap(UUID.init(uuidString:)) != nil) && revision.flatMap(UUID.init(uuidString:)) != nil),
                  !nativeSessionCompleted || (mountedDevice == nil && nativeTmpfs.quiescence == nil &&
                    quiescedRevision == nil && quiescedSession == nil && nativeTmpfs.periodicAuthorization == nil &&
                    (!populationVerified || nativeTmpfs.managedUnmount || nativeTmpfs.lossDisclosure != nil)),
                  !(populationVerified && (phase == .pendingRestore || phase == .restoring)) || nativeTmpfs.managedUnmount || nativeTmpfs.lossDisclosure != nil,
                  nativeTmpfs.quiescence == nil || (populationVerified && quiescedRevision != nil &&
                    quiescedRevision == revision && quiescedSession == session) else {
                throw NestError("Native session identity is incomplete; retained.", code: 6)
            }
        }
        if let layout = managedLink {
            try layout.validate()
            let allowedRoot = layout.version == 2 ? NativeTmpfsPaths.root : ((decoder.userInfo[LinkedFolderLayout.decoderRootKey] as? URL) ?? LinkedFolders.legacyRoot)
            guard layout.mountRoot == allowedRoot.path else {
                throw DecodingError.dataCorruptedError(forKey: .legacyLink, in: values,
                    debugDescription: "legacy linked-folder journal names an unauthorized mount root; recovery blocked.")
            }
            for key in [CodingKeys.evacuation, .evacuationDevice, .evacuationInode, .restoreStage,
                        .restoreStageDevice, .restoreStageInode, .restoreDataDevice, .restoreDataInode, .restoreRevision] {
                if values.contains(key), try values.decodeNil(forKey: key) {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values,
                        debugDescription: "Null legacy linked-folder transaction authority; originals retained.")
                }
            }
            guard backend == (layout.version == 2 ? .tmpfs : .fskit), session == layout.session else {
                throw DecodingError.dataCorruptedError(forKey: .legacyLink, in: values,
                    debugDescription: "legacy linked-folder layout backend/session mismatch; all data retained.")
            }
            if let stage = restoreStage {
                let url = URL(fileURLWithPath: stage)
                let prefix = ".ramnest-\(layout.folderID.uuidString)-restore-"
                guard stage.hasPrefix("/"), url.standardizedFileURL.path == stage,
                      url.deletingLastPathComponent() == URL(fileURLWithPath: layout.originalPath).deletingLastPathComponent(),
                      url.lastPathComponent.hasPrefix(prefix),
                      UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil,
                      restoreStageDevice == layout.parent.device, (restoreStageInode ?? 0) > 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .restoreStage, in: values,
                        debugDescription: "Invalid legacy linked-folder staging authority; all data retained.")
                }
            } else if restoreStageDevice != nil || restoreStageInode != nil || restoreDataDevice != nil || restoreDataInode != nil {
                throw DecodingError.dataCorruptedError(forKey: .restoreStage, in: values,
                    debugDescription: "Partial legacy linked-folder staging authority; all data retained.")
            }
            guard phase != .mounted || (layout.stage == .linked && populationVerified),
                  phase != .idle || (layout.stage == .restored && layout.mountReleased),
                  !populationVerified || [.linked, .restoring, .publishing, .restored].contains(layout.stage),
                  !populationVerified || layout.link != nil,
                  evacuation == nil || (layout.holding != nil && evacuation == layout.holdingPath && evacuationDevice == layout.holding?.device && evacuationInode == layout.holding?.inode),
                  ![.evacuating, .evacuated, .linking, .linked, .restoring, .publishing].contains(layout.stage) || evacuation == layout.holdingPath,
                  layout.stage != .publishing || restoreRevision != nil,
                  layout.restoration != .checkpoint || phase == .idle || restoreRevision != nil,
                  layout.stage != .restoring || (restoreStage != nil && layout.restoration == .checkpoint),
                  layout.stage != .publishing || layout.restoration != .checkpoint ||
                    (restoreStage != nil && restoreStageDevice == layout.parent.device && restoreStageInode != nil &&
                     restoreDataDevice == layout.restored?.device && restoreDataInode == layout.restored?.inode) else {
                throw DecodingError.dataCorruptedError(forKey: .legacyLink, in: values,
                    debugDescription: "Incoherent legacy linked-folder transaction stage; all data retained.")
            }
        }
        try reviewedRecovery?.validate(journal: self, fixtureRoot: decoder.userInfo[LinkedFolderLayout.decoderRootKey] as? URL)
    }
}
public struct Configuration: Codable, Sendable {
    public enum Backend: String, Codable, Sendable {
        case nfs, fskit, smb, tmpfs
        public var displayName: String {
            switch self { case .nfs: "NFS"; case .fskit: "legacy linked-folder"; case .smb: "SMB3"; case .tmpfs: "Native macOS tmpfs" }
        }

    }
    public var version = 1
    public var menuBarMode = false
    public var folders: [Folder] = []
    public var backend = Backend.tmpfs
    public var fileVerification = FileVerification.sha256
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, menuBarMode, folders, backend, fileVerification }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        menuBarMode = try values.decode(Bool.self, forKey: .menuBarMode)
        folders = try values.decode([Folder].self, forKey: .folders)
        // Only absence means legacy NFS. Explicit null and invalid values fail.
        backend = values.contains(.backend) ? try values.decode(Backend.self, forKey: .backend) : .nfs
        fileVerification = values.contains(.fileVerification) ? try values.decode(FileVerification.self, forKey: .fileVerification) : .sha256
    }
}
public struct FolderStatus: Codable, Identifiable, Sendable {
    public var folder: Folder
    public var journal: Journal
    public var connected: Bool
    public var mounted: Bool
    public var used: UInt64
    public var nativeCapacityBytes: UInt64? = nil
    public var nativeReadOnly: Bool? = nil
    public var helperActive: Bool? = nil
    public var isReady: Bool { connected && mounted && helperActive == true && journal.populationVerified && journal.phase == .mounted }
    public var needsAttention: Bool { !isReady && (mounted || journal.phase != .idle) }
    public var statusTitle: String {
        if journal.nativeTmpfs != nil && mounted && !isReady {
            return nativeReadOnly == true ? "Needs attention · Read-only (guarded)" : "Needs attention · Native mount retained"
        }
        return isReady ? "Mounted in RAM" : mounted ? "Needs attention · Read-only (guarded)" : journal.phase == .idle ? "Files are on disk" : "Needs attention" }
    public var canMount: Bool { !mounted && !connected && journal.phase == .idle && journal.reviewedRecovery == nil }
    public var canEject: Bool {
        let nativePending = journal.nativeTmpfs != nil && (journal.phase == .ejecting ||
            (!journal.populationVerified && [.preparing, .mounting, .evacuated].contains(journal.phase)))
        return mounted && (connected || journal.nativeTmpfs != nil) &&
            (journal.phase == .mounted || journal.phase == .recoveryRequired || nativePending)
    }
    public var canSave: Bool { isReady && folder.options.sync && (journal.nativeTmpfs == nil || NativeSnapshotSafety.supported) }
    public var snapshotBlocker: String? { journal.nativeTmpfs != nil && !NativeSnapshotSafety.supported ? NativeSnapshotSafety.blockedMessage : nil }
    public var canResize: Bool { !mounted && !connected && journal.phase == .idle && journal.reviewedRecovery == nil }
    public var canRecover: Bool { !mounted && journal.phase != .idle }
    public var canReviewLegacyPublication: Bool {
        canRecover && journal.populationVerified && journal.managedLink?.restoration == .checkpoint &&
            journal.managedLink?.stage == .publishing && journal.publicationRename?.version == 1 &&
            journal.publicationRename?.after == nil && journal.publicationRename?.operation == .publication
    }
    public var primaryActionTitle: String { mounted ? (isReady && folder.options.sync ? "Save and Eject" : "Eject") : "Mount" }
    public var id: UUID { folder.id }
}
public enum SizeParser {
    public static func parse(_ input: String) throws -> UInt64 {
        let s = input.trimmingCharacters(in: .whitespaces).uppercased()
        let suffixes: [(String, UInt64)] = [("GIB", 1<<30), ("MIB", 1<<20), ("GB", 1<<30), ("MB", 1<<20), ("G", 1<<30), ("M", 1<<20), ("B", 1)]
        var digits = s; var multiplier: UInt64 = 1
        for (suffix, factor) in suffixes where s.hasSuffix(suffix) { digits = String(s.dropLast(suffix.count)); multiplier = factor; break }
        guard let value = UInt64(digits), value > 0, value <= UInt64.max / multiplier else { throw NestError("Invalid size. Use an integer such as 512MB or 4GB.", code: 64) }
        return value * multiplier
    }
    public static func validate(_ bytes: UInt64) throws {
        guard bytes >= 16<<20, bytes <= ProcessInfo.processInfo.physicalMemory / 4 * 3 else { throw NestError("Capacity must be 16 MiB through 75% of physical memory.", code: 64) }
    }
}

extension FolderStatus {
    private enum CodingKeys: String, CodingKey {
        case folder, journal, connected, mounted, used
        case nativeCapacityBytes, nativeReadOnly, helperActive, snapshotPolicy
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decode(Folder.self, forKey: .folder); journal = try c.decode(Journal.self, forKey: .journal)
        connected = try c.decode(Bool.self, forKey: .connected); mounted = try c.decode(Bool.self, forKey: .mounted)
        used = try c.decode(UInt64.self, forKey: .used)
        nativeCapacityBytes = try c.decodeIfPresent(UInt64.self, forKey: .nativeCapacityBytes)
        nativeReadOnly = try c.decodeIfPresent(Bool.self, forKey: .nativeReadOnly)
        helperActive = try c.decodeIfPresent(Bool.self, forKey: .helperActive)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folder, forKey: .folder); try c.encode(journal, forKey: .journal)
        try c.encode(connected, forKey: .connected); try c.encode(mounted, forKey: .mounted); try c.encode(used, forKey: .used)
        if journal.nativeTmpfs != nil { try c.encode("close-writers-mapping-scan-v1", forKey: .snapshotPolicy) }
        try c.encodeIfPresent(nativeCapacityBytes, forKey: .nativeCapacityBytes)
        try c.encodeIfPresent(nativeReadOnly, forKey: .nativeReadOnly)
        try c.encodeIfPresent(helperActive, forKey: .helperActive)
    }
}
