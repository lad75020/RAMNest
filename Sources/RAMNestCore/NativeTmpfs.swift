import Foundation
import Darwin

/// A kernel identity, never a transport name or an inferred "native" session.
public struct NativeFilesystemID: Codable, Equatable, Sendable {
    var first: UInt32
    var second: UInt32
    init(_ fs: statfs) { first = UInt32(bitPattern: fs.f_fsid.val.0); second = UInt32(bitPattern: fs.f_fsid.val.1) }
    init(first: UInt32, second: UInt32) { self.first = first; self.second = second }
    private enum CodingKeys: String, CodingKey { case first, second }
    private struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Key.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["first", "second"] else { throw NestError("Unknown native fsid authority.", code: 6) }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        first = try values.decode(UInt32.self, forKey: .first); second = try values.decode(UInt32.self, forKey: .second)
        guard first != 0 || second != 0 else { throw NestError("Zero native filesystem identity.", code: 6) }
    }
}
public struct NativeTmpfsRecord: Codable, Equatable, Sendable {
    var version = 1
    var session: UUID
    var uid: UInt32
    var capacity: UInt64
    var filesystem: NativeFilesystemID?
    var data: LinkedFolderLayout.Identity?
    // Remains visible after explicit recovery. It is never a fresh-RAM receipt.
    public var lossDisclosure: String?
    var quiescence: String?
    var managedUnmount = false
    var periodicAuthorization: UUID?
    init(session: UUID, capacity: UInt64) { self.session = session; uid = getuid(); self.capacity = capacity }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, session, uid, capacity, filesystem, data, lossDisclosure, quiescence, managedUnmount, periodicAuthorization }
    private struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Key.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw NestError("Unknown native session authority; retained.", code: 6)
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        session = try c.decode(UUID.self, forKey: .session)
        uid = try c.decode(UInt32.self, forKey: .uid)
        capacity = try c.decode(UInt64.self, forKey: .capacity)
        filesystem = c.contains(.filesystem) ? try c.decode(NativeFilesystemID.self, forKey: .filesystem) : nil
        data = c.contains(.data) ? try c.decode(LinkedFolderLayout.Identity.self, forKey: .data) : nil
        lossDisclosure = c.contains(.lossDisclosure) ? try c.decode(String.self, forKey: .lossDisclosure) : nil
        quiescence = c.contains(.quiescence) ? try c.decode(String.self, forKey: .quiescence) : nil
        managedUnmount = c.contains(.managedUnmount) ? try c.decode(Bool.self, forKey: .managedUnmount) : false
        periodicAuthorization = c.contains(.periodicAuthorization) ? try c.decode(UUID.self, forKey: .periodicAuthorization) : nil
        try validate()
    }
    func validate() throws {
        guard version == 1, uid >= 501, capacity >= 16 << 20, capacity <= 1 << 50,
              filesystem.map({ $0.first != 0 || $0.second != 0 }) ?? true,
              data == nil || filesystem != nil, !managedUnmount || filesystem != nil,
              quiescence == nil || quiescence == NativeSnapshotSafety.receiptVersion else {
            throw NestError("Malformed native mount authority; all recovery data retained.", code: 6)
        }
    }
}

enum NativeTmpfsPaths {
    static var root: URL { URL(fileURLWithPath: "/Users/Shared/RAMNestNative-\(getuid())", isDirectory: true) }
    static func mount(_ session: UUID) -> URL { root.appendingPathComponent(session.uuidString).appendingPathComponent("mount") }
    static func workspace(_ session: UUID) -> URL { mount(session).appendingPathComponent("tree") }
    static func data(_ session: UUID) -> URL { workspace(session).appendingPathComponent("data") }
    static func requireRoot(_ handle: DirectoryHandle) throws {
        var st = stat()
        guard fstat(handle.fd, &st) == 0, st.st_uid == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_mode & 0o7777 == 0o755, st.st_flags == 0 else {
            throw NestError("Native runtime parent is not a protected root-owned directory; retained.", code: 4)
        }
        errno = 0
        if let acl = acl_get_fd_np(handle.fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
            guard result == -1, errno == EINVAL else { throw NestError("Native runtime parent has an unsupported ACL.", code: 4) }
        } else if errno != ENOENT && errno != ENOTSUP { throw NestError("Cannot inspect native runtime ACL.", code: 4) }
    }
    static func boundRoot(_ layout: LinkedFolderLayout) throws -> DirectoryHandle {
        try layout.validate()
        guard layout.version == 2, layout.mountRoot == root.path else { throw NestError("Not a native mount slot.", code: 4) }
        let handle = try DirectoryHandle.open(root); try requireRoot(handle); try layout.root.verify(handle)
        let slot = try handle.child(layout.session.uuidString); try requireRoot(slot)
        return handle
    }
}

struct NativeMountObservation {
    let filesystem: NativeFilesystemID
    let readOnly: Bool
    let used: UInt64
    let capacity: UInt64
    let data: LinkedFolderLayout.Identity?
}

/// All administrator input is structured, canonical and restricted to UUID slots.
/// The helper never accepts a path, store, executable or shell text in root mode.
enum NativeTmpfsControl {
    static let protocolVersion = "native-tmpfs-v1"
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func authorize(helper: URL, arguments: [String]) throws -> [String] {
        let image = try NativeHelperImage.capture(helper: helper)
        let script = try NativeHelperBootstrap.administratorScript(image: image, arguments: arguments)
        let result: String
        do { result = try Control.run("/usr/bin/osascript", ["-e", script], currentDirectory: URL(fileURLWithPath: "/")) }
        catch { throw NestError((arguments.dropFirst().first == "freeze" ? "Native freeze/mapping validation failed; no checkpoint was authorized. " : "Native tmpfs control could not complete using one-shot macOS administrator authorization. ") + error.localizedDescription, code: arguments.dropFirst().first == "freeze" ? 78 : 2) }
        let fields = result.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard fields.first == "OK" else { throw NestError("Invalid native control receipt; inspect the owned slot before retrying.", code: 6) }
        return Array(fields.dropFirst())
    }
    static func arguments(_ operation: String, layout: LinkedFolderLayout, record: NativeTmpfsRecord) throws -> [String] {
        try layout.validate(); try record.validate()
        guard layout.version == 2, layout.session == record.session, record.uid == getuid(),
              ["mount", "readonly", "freeze", "thaw", "unmount", "release"].contains(operation) else { throw NestError("Invalid native control authority.", code: 4) }
        var args = ["--native-v1", operation, String(record.uid), record.session.uuidString,
                    String(layout.root.device), String(layout.root.inode), String(layout.mountpoint.device), String(layout.mountpoint.inode)]
        if operation == "mount" { args += [String(record.capacity), "true"] }
        else if operation != "release" {
            guard let fs = record.filesystem else { throw NestError("Missing native filesystem identity.", code: 6) }
            args += [String(fs.first), String(fs.second), String(record.capacity)]
        }
        return args
    }
    static func observe(_ journal: Journal, requireData: Bool = true, readonly: Bool? = nil) throws -> NativeMountObservation {
        guard let layout = journal.nativeLink, let record = journal.nativeTmpfs,
              journal.backend == .tmpfs, journal.session == record.session, layout.session == record.session,
              let expected = record.filesystem, journal.phase != .idle, !record.managedUnmount else { throw NestError("No bound native tmpfs session.", code: 6) }
        _ = try NativeTmpfsPaths.boundRoot(layout)
        let mountURL = NativeTmpfsPaths.mount(record.session)
        let handle = try DirectoryHandle.open(mountURL)
        var fs = statfs()
        guard fstatfs(handle.fd, &fs) == 0 else { throw NestError("Cannot inspect native tmpfs.", code: 6) }
        let type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
        let path = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        guard fs.f_flags & UInt32(MNT_NOSUID | MNT_NODEV) == UInt32(MNT_NOSUID | MNT_NODEV) else { throw NestError("Native safety mount flags changed; retained.", code: 6) }
        let ro = fs.f_flags & UInt32(MNT_RDONLY) != 0
        let accounting = try NativeKernelMountValidation.inspect(type: type, path: path, filesystem: NativeFilesystemID(fs),
            expectedPath: mountURL.path, expectedFilesystem: expected, readOnly: ro, requiredReadOnly: readonly,
            blocks: UInt64(fs.f_blocks), free: UInt64(fs.f_bfree), blockSize: UInt64(fs.f_bsize))
        let page = sysconf(_SC_PAGESIZE)
        guard page > 0, accounting.capacity >= (record.capacity / UInt64(page)) * UInt64(page),
              accounting.capacity <= ((record.capacity + UInt64(page) - 1) / UInt64(page)) * UInt64(page) else {
            throw NestError("Native maximum does not match the recorded requested capacity.", code: 6)
        }
        guard !Paths.mounts().contains(where: { $0.path.hasPrefix(mountURL.path + "/") }) else {
            throw NestError("Nested native mount detected; no snapshot authorized.", code: 6)
        }
        var data: LinkedFolderLayout.Identity?
        if requireData {
            guard let identity = record.data else { throw NestError("Native data identity is not committed.", code: 6) }
            let dataHandle = try DirectoryHandle.open(NativeTmpfsPaths.data(record.session))
            try identity.verify(dataHandle)
            var dataFS = statfs()
            guard fstatfs(dataHandle.fd, &dataFS) == 0, NativeFilesystemID(dataFS) == expected else { throw NestError("Native data left its bound filesystem.", code: 6) }
            data = identity
        }
        return NativeMountObservation(filesystem: expected, readOnly: ro, used: accounting.used, capacity: accounting.capacity, data: data)
    }
    static func assertAbsent(_ journal: Journal) throws {
        guard let layout = journal.nativeLink else { throw NestError("No native reservation authority.", code: 6) }
        try layout.validate()
        let rootHandle = try DirectoryHandle.open(NativeTmpfsPaths.root)
        try NativeTmpfsPaths.requireRoot(rootHandle); try layout.root.verify(rootHandle)
        let path = NativeTmpfsPaths.mount(layout.session)
        guard !Paths.mounts().contains(where: { $0.path == path.path || $0.path.hasPrefix(path.path + "/") }) else { throw NestError("A mount is still present in the native slot; recovery is blocked.", code: 6) }
        // A successfully released slot may already be absent after a crash.
        let root = try DirectoryHandle.open(NativeTmpfsPaths.root)
        if try !root.exists(layout.session.uuidString) { return }
        let mount = try DirectoryHandle.open(path); try layout.mountpoint.verify(mount)
    }
}

/// Read-only remount plus a complete, conservative root lsof gate. This is a
/// cooperative writer-quiescence contract, not atomic mapping revocation against
/// adversarial inter-process descriptor/mapping handoff.
enum NativeSnapshotSafety {
    static let blockedMessage = "Native snapshot requires a complete privileged mapping scan after read-only remount. Close all files and mappings in the RAM tree; Ignore Busy cannot bypass this guard. No current-RAM checkpoint was committed."
    static let receiptVersion = "no-regular-vnode-references-v1"
    static var supported: Bool { true }
    static func requireValidatedMappings() throws { throw NestError(blockedMessage, code: 78) }
    static func validateReceipt(_ reply: [String], filesystem: NativeFilesystemID) throws {
        guard reply == [receiptVersion, String(filesystem.first), String(filesystem.second)] else {
            throw NestError("Missing or mismatched native mapping-scan receipt. Read-only remount alone cannot authorize a snapshot.", code: 78)
        }
    }
    static func freeze(readonly: () throws -> Void, verify: () throws -> Void,
                       validateMappings: () throws -> Void = requireValidatedMappings) throws {
        try readonly()
        try verify()
        try validateMappings()
        try verify()
    }
}

/// Actual statfs values feed both the identity check and accounting. No mmap,
/// encoded-payload, compression ratio or folder-config estimate participates.
enum NativeKernelMountValidation {
    static func inspect(type: String, path: String, filesystem: NativeFilesystemID,
                        expectedPath: String, expectedFilesystem: NativeFilesystemID,
                        readOnly: Bool, requiredReadOnly: Bool?, blocks: UInt64, free: UInt64,
                        blockSize: UInt64) throws -> (used: UInt64, capacity: UInt64) {
        guard type == "tmpfs", path == expectedPath, filesystem == expectedFilesystem,
              requiredReadOnly.map({ $0 == readOnly }) ?? true else {
            throw NestError("Native mount identity/type/fsid or read-only flag changed. No stale disk tree can be saved as RAM.", code: 6)
        }
        guard blockSize > 0, blocks <= UInt64.max / blockSize, free <= blocks else {
            throw NestError("Invalid native statfs accounting.", code: 6)
        }
        return ((blocks - free) * blockSize, blocks * blockSize)
    }
}

enum NativeCheckpointTransaction {
    static func run(keepFrozen: Bool, readonly: () throws -> Void, verify: () throws -> Void,
                    validateMappings: () throws -> Void, copy: () throws -> String,
                    commit: (String) throws -> Void, invalidate: (Error, Bool) throws -> Void,
                    stillBoundReadonly: () -> Bool, thaw: () throws -> Void) throws -> String {
        var attemptedFreeze = false, attemptedThaw = false
        do {
            attemptedFreeze = true
            try NativeSnapshotSafety.freeze(readonly: readonly, verify: verify, validateMappings: validateMappings)
            let revision = try copy()
            try verify() // Forced unmount/replacement cannot promote a disk fallback.
            try commit(revision)
            if !keepFrozen { attemptedThaw = true; try thaw() }
            return revision
        } catch {
            let failure = error
            // If invalidation cannot be made durable, leave writes guarded.
            try invalidate(failure, attemptedThaw)
            if attemptedFreeze, !attemptedThaw, stillBoundReadonly() {
                do { try thaw() }
                catch {
                    let combined = NestError(failure.localizedDescription + " Rollback thaw failed; native mount remains guarded. " + error.localizedDescription, code: 6)
                    try invalidate(combined, true); throw combined
                }
            }
            throw failure
        }
    }
}

enum NativeRecoveryPolicy {
    static func managedEject(_ journal: Journal, sync: Bool) -> Bool {
        guard journal.nativeTmpfs?.managedUnmount == true, journal.backend == .tmpfs, journal.phase == .ejecting else { return false }
        if !sync || !journal.populationVerified { return true }
        return journal.quiescedRevision != nil && journal.quiescedRevision == journal.revision &&
            journal.quiescedSession == journal.session && journal.nativeTmpfs?.quiescence == NativeSnapshotSafety.receiptVersion
    }
    static func needsLossDisclosure(_ journal: Journal, sync: Bool) -> Bool {
        journal.populationVerified && !managedEject(journal, sync: sync) &&
            journal.phase != .restoring && journal.phase != .pendingRestore && journal.phase != .idle
    }
}

/// Reset only a finished transaction; never publish a half-cleared native
/// discriminator. Snapshot/holding references are queued before being removed.
enum NativeJournalTransition {
    static func completeIdle(_ journal: inout Journal) throws {
        guard let record = journal.nativeTmpfs, journal.nativeLink?.stage == .restored,
              journal.nativeLink?.mountReleased == true,
              !journal.populationVerified || record.managedUnmount || record.lossDisclosure != nil else {
            throw NestError("Native restoration is not completed/retired.", code: 6)
        }
        journal.nativeTmpfs?.quiescence = nil; journal.nativeTmpfs?.periodicAuthorization = nil
        journal.quiescedRevision = nil; journal.quiescedSession = nil
        journal.mountedDevice = nil; journal.socket = nil; journal.phase = .idle; journal.lastError = nil
    }
    static func resetCompletedAuthority(_ journal: inout Journal) throws {
        guard journal.phase == .idle,
              journal.managedLink == nil || (journal.managedLink?.stage == .restored && journal.managedLink?.mountReleased == true) else {
            throw NestError("Only completed idle authority can be reset.", code: 6)
        }
        SnapshotRetention.remember(&journal)
        journal.managedLink = nil; journal.nativeTmpfs = nil; journal.resetUnmountSession = nil
        journal.populationVerified = false; journal.mountedDevice = nil; journal.session = nil; journal.socket = nil
        journal.initialRevision = nil; journal.restoreRevision = nil
        journal.initialSourceManifest = nil; journal.restoreManifest = nil
        journal.originalRename = nil; journal.publicationRename = nil; journal.publicationReceipt = nil
        journal.evacuation = nil; journal.evacuationDevice = nil; journal.evacuationInode = nil
        journal.evacuatedEntries = []; journal.restoredEntries = []
        journal.restoreStage = nil; journal.restoreStageDevice = nil; journal.restoreStageInode = nil
        journal.restoreDataDevice = nil; journal.restoreDataInode = nil
        journal.nativeGeneration = nil; journal.quiescedRevision = nil; journal.quiescedSession = nil
        journal.quiescedHelperPID = nil; journal.quiescedNativeInstance = nil
        journal.startupProtocol = nil; journal.startupHelperPID = nil; journal.startupRetired = nil
    }
}

/// An ordinary-user scheduling capability. It authorizes no root operation and
/// cannot survive session/fsid/pin/policy/interval replacement or disablement.
public struct NativePeriodicSaveRequest: Sendable {
    let session: UUID, authorization: UUID
    let filesystem: NativeFilesystemID
    let verification: FileVerification
    let interval: Int
    let socket: String
    public init(session: UUID, first: UInt32, second: UInt32, verification: FileVerification,
                interval: Int, authorization: UUID, socket: String) {
        self.session = session; filesystem = .init(first: first, second: second)
        self.verification = verification; self.interval = interval; self.authorization = authorization; self.socket = socket
    }
    func validate(folder: Folder, journal: Journal) throws {
        guard journal.phase == .mounted, journal.populationVerified, journal.backend == .tmpfs,
              journal.session == session, journal.nativeTmpfs?.session == session,
              journal.nativeTmpfs?.filesystem == filesystem, journal.nativeTmpfs?.managedUnmount == false,
              journal.nativeTmpfs?.periodicAuthorization == authorization, journal.socket == socket,
              journal.fileVerification == verification, folder.options.sync, folder.options.periodicSave,
              FolderOptions.intervals.contains(interval), folder.options.intervalMinutes == interval else {
            throw NestError("Retired or changed periodic native session; no save or administrator operation was started.", code: 6)
        }
    }
}

extension Engine {
    public func periodicSave(_ ref: String, expected: NativePeriodicSaveRequest) throws {
        try volumeTransaction(ref) { f in
            var j = try store.journal(f.id)
            // This runs AFTER acquiring the volume lock. A delayed old child may
            // not touch the new session, even if it has the same folder UUID.
            try expected.validate(folder: f, journal: j)
            _ = try captureNative(f, journal: &j, quiesce: false, periodic: expected)
            j.lastError = nil; try store.write(j, for: f.id); cleanSnapshots(f, &j)
        }
    }
}
