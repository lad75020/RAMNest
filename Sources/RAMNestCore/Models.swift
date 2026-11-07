import Foundation

public struct NestError: Error, LocalizedError, Sendable {
    public let message: String
    public let code: Int32
    public init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
    public var errorDescription: String? { message }
}
public enum Comparison: String, Codable, CaseIterable, Sendable { case sizeAndModTime, checksum }
public struct FolderOptions: Codable, Equatable, Sendable {
    public var compression = true
    public var mountAtLaunch = true
    public var nobrowse = true
    public var sync = true
    public var periodicSave = false
    public var intervalMinutes = 15
    public var comparison = Comparison.sizeAndModTime
    public static let intervals = [5, 15, 30, 60, 360, 720, 1440]
    public init() {}
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
    public var restoreStage: String?
    public var restoreStageDevice: UInt64?
    public var restoreStageInode: UInt64?
    public var restoreDataDevice: UInt64?
    public var restoreDataInode: UInt64?
    var publicationReceipt: PublicationReceipt?
    public var mountedDevice: UInt64?
    public var populationVerified = false
    public var fsKitLink: FSKitLinkLayout?
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
        case phase, session, backend, socket, initialRevision, revision, priorRevision
        case nativeGeneration, quiescedRevision, quiescedSession, quiescedHelperPID, quiescedNativeInstance
        case retiringRevisions, cleanupWarning, siblingCleanup, evacuation, evacuationDevice, evacuationInode
        case evacuatedEntries, restoredEntries, restoreRevision, restoreStage, restoreStageDevice, restoreStageInode
        case restoreDataDevice, restoreDataInode, publicationReceipt, mountedDevice, populationVerified
        case startupProtocol, startupHelperPID, startupRetired, lastError, updated, fsKitLink
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Validate the wire discriminator before any recovery branch can see a
        // nil protocol. Explicit null is not an old journal; nor is a partial
        // startup record, even if its remaining startup values are null.
        if values.contains(.startupProtocol) {
            startupProtocol = try values.decode(String.self, forKey: .startupProtocol)
            guard startupProtocol == GuardedPopulationStartup.version else {
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
        fsKitLink = values.contains(.fsKitLink) ? try values.decode(FSKitLinkLayout.self, forKey: .fsKitLink) : nil
        if let layout = fsKitLink {
            try layout.validate()
            let allowedRoot = (decoder.userInfo[FSKitLinkLayout.decoderRootKey] as? URL) ?? FSKitLinks.productionRoot
            guard layout.mountRoot == allowedRoot.path else {
                throw DecodingError.dataCorruptedError(forKey: .fsKitLink, in: values,
                    debugDescription: "FSKit journal names an unauthorized mount root; recovery blocked.")
            }
            for key in [CodingKeys.evacuation, .evacuationDevice, .evacuationInode, .restoreStage,
                        .restoreStageDevice, .restoreStageInode, .restoreDataDevice, .restoreDataInode, .restoreRevision] {
                if values.contains(key), try values.decodeNil(forKey: key) {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values,
                        debugDescription: "Null FSKit transaction authority; originals retained.")
                }
            }
            guard backend == .fskit, session == layout.session else {
                throw DecodingError.dataCorruptedError(forKey: .fsKitLink, in: values,
                    debugDescription: "FSKit layout backend/session mismatch; all data retained.")
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
                        debugDescription: "Invalid FSKit staging authority; all data retained.")
                }
            } else if restoreStageDevice != nil || restoreStageInode != nil || restoreDataDevice != nil || restoreDataInode != nil {
                throw DecodingError.dataCorruptedError(forKey: .restoreStage, in: values,
                    debugDescription: "Partial FSKit staging authority; all data retained.")
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
                throw DecodingError.dataCorruptedError(forKey: .fsKitLink, in: values,
                    debugDescription: "Incoherent FSKit transaction stage; all data retained.")
            }
        }
    }
}
public struct Configuration: Codable, Sendable {
    public enum Backend: String, Codable, CaseIterable, Sendable {
        case nfs, fskit, smb
        public var displayName: String {
            switch self { case .nfs: "NFS"; case .fskit: "FSKit"; case .smb: "SMB3" }
        }
        var mountFailureMessage: String {
            let setup = self == .fskit ? " Open /Applications/fuse-t.app and follow its instructions to enable the FSKit extension; registration alone does not prove it is enabled. New FSKit sessions require RAMNest's writable internal mount directory and use a symlink at the original folder path." : ""
            return "FUSE-T \(displayName) did not mount." + setup + " Sandbox may also prohibit mounts. Original data is retained; run recover before retrying. RAMNest does not retry using another backend."
        }
    }
    public var version = 1
    public var menuBarMode = false
    public var folders: [Folder] = []
    public var backend = Backend.nfs
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, menuBarMode, folders, backend }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        menuBarMode = try values.decode(Bool.self, forKey: .menuBarMode)
        folders = try values.decode([Folder].self, forKey: .folders)
        // Only absence means legacy NFS. Explicit null and invalid values fail.
        backend = values.contains(.backend) ? try values.decode(Backend.self, forKey: .backend) : .nfs
    }
}
public struct FolderStatus: Codable, Identifiable, Sendable {
    public var folder: Folder
    public var journal: Journal
    public var connected: Bool
    public var mounted: Bool
    public var used: UInt64
    public var contentBytes: UInt64
    public var payloadBytes: UInt64
    public var mappedBytes: UInt64
    public var backingSavingsFraction: Double
    public var helperActive: Bool? = nil
    public var isReady: Bool { connected && mounted && helperActive == true && journal.populationVerified && journal.phase == .mounted }
    public var needsAttention: Bool { !isReady && (mounted || journal.phase != .idle) }
    public var statusTitle: String { isReady ? "Mounted in RAM" : mounted ? "Needs attention · Read-only (guarded)" : journal.phase == .idle ? "Files are on disk" : "Needs attention" }
    public var canMount: Bool { !mounted && !connected && journal.phase == .idle }
    public var canEject: Bool { mounted && connected && (journal.phase == .mounted || journal.phase == .recoveryRequired) }
    public var canSave: Bool { isReady && folder.options.sync }
    public var canResize: Bool { isReady || (!mounted && !connected && journal.phase == .idle) }
    public var canRecover: Bool { !mounted && journal.phase != .idle }
    public var primaryActionTitle: String { mounted ? (isReady ? "Save and Eject" : "Eject") : "Mount" }
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
