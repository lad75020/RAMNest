import Foundation
import Darwin
import CryptoKit

public final class Store: @unchecked Sendable {
    var beforeJournalWrite: ((Journal, UUID) throws -> Void)?
    // Internal fixture injection only; no environment or public API override.
    var linkedFixtureRoot: URL?
    var journalDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        if let root = linkedFixtureRoot { decoder.userInfo[LinkedFolderLayout.decoderRootKey] = root }
        return decoder
    }
    public let root: URL
    private let rootIdentity: (device: UInt64, inode: UInt64)
    private let locationAuthority: (() throws -> Void)?
    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RAMNest", isDirectory: true) }
    public convenience init(root: URL = Store.defaultRoot) throws {
        try self.init(root: root, locationAuthority: nil)
    }
    init(root: URL, locationAuthority: (() throws -> Void)?) throws {
        self.root = root.standardizedFileURL
        self.locationAuthority = locationAuthority
        // A selected location is checked before creation. A disconnected drive
        // must never become a new empty repository on the underlying filesystem.
        try locationAuthority?()
        try Paths.rejectSymlinks(self.root.path, allowMissingLast: true)
        try Self.rejectRetired(self.root)
        try Self.privateDirectory(self.root)
        try Self.privateDirectory(self.root.appendingPathComponent("volumes"))
        rootIdentity = try DirectoryHandle.open(self.root).identity()
        try locationAuthority?()
    }
    private func validateAuthority() throws {
        try Self.rejectRetired(root)
        try locationAuthority?()
        let handle = try DirectoryHandle.open(root)
        guard try handle.identity() == rootIdentity else { throw NestError("Snapshot repository identity changed.", code: 4) }
        try handle.requireOwnedDirectory(device: rootIdentity.device, privateMode: true)
    }
    static func rejectRetired(_ root: URL) throws {
        var info = stat()
        for name in [".ramnest-retired.json", ".ramnest-incoming.json"] {
            if lstat(root.appendingPathComponent(name).path, &info) == 0 {
                throw NestError("This snapshot store is fenced for relocation or pending cleanup. Open Settings and retry the recorded storage move; do not recreate either store.", code: 6)
            }
            guard errno == ENOENT else { throw NestError("Cannot establish snapshot store relocation authority.", code: 6) }
        }
    }
    // Cleanup must stay inside the same owned repository, even if its pathname
    // was replaced after this Store was opened. Never create paths during cleanup.
    func managedVolume(_ id: UUID) throws -> DirectoryHandle {
        try validateAuthority()
        let handle = try DirectoryHandle.open(root)
        let identity = try handle.identity()
        guard identity == rootIdentity else { throw NestError("Snapshot repository identity changed.", code: 4) }
        try handle.requireOwnedDirectory(device: identity.device, privateMode: true)
        let volumes = try handle.child("volumes")
        try volumes.requireOwnedDirectory(device: identity.device, privateMode: true)
        let volume = try volumes.child(id.uuidString)
        try volume.requireOwnedDirectory(device: identity.device, privateMode: true)
        return volume
    }
    public static func privateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw NestError("Private storage must be an owned 0700 directory: \(url.path)", code: 6) }
    }
    public func locked<T>(_ operation: () throws -> T) throws -> T {
        try validateAuthority()
        let directory = try DirectoryHandle.open(root)
        let fd = openat(directory.fd, "repository.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw NestError("Cannot open repository lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NestError("Cannot lock repository.") }
        defer { flock(fd, LOCK_UN) }
        try validateAuthority()
        return try operation()
    }
    // Lock order: volume transaction -> short repository/configuration lock.
    // Resolve under repository lock, release it, acquire volume, then refresh.
    // Never hold repository.lock while waiting on a volume transaction.
    public func volumeLocked<T>(_ id: UUID, _ operation: () throws -> T) throws -> T {
        let directory = try managedVolume(id)
        let fd = openat(directory.fd, "transaction.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NestError("Cannot open volume transaction lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NestError("Cannot lock volume transaction.") }
        defer { flock(fd, LOCK_UN) }
        try validateAuthority()
        return try operation()
    }
    public func load() throws -> Configuration {
        try validateAuthority()
        let url = root.appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let config = try Self.read(Configuration.self, url)
        guard config.version == 1 else { throw NestError("Unsupported configuration version.") }
        return config
    }
    public func save(_ config: Configuration) throws {
        try validateAuthority()
        try Self.atomicJSON(config, root.appendingPathComponent("configuration.json"))
    }
    public func volume(_ id: UUID) throws -> URL {
        try validateAuthority()
        let url = root.appendingPathComponent("volumes/\(id.uuidString)", isDirectory: true)
        try Self.privateDirectory(url); try Self.privateDirectory(url.appendingPathComponent("revisions")); return url
    }
    public func journal(_ id: UUID) throws -> Journal {
        let url = try volume(id).appendingPathComponent("journal.json")
        return FileManager.default.fileExists(atPath: url.path) ? try Self.read(Journal.self, url, decoder: journalDecoder) : Journal()
    }
    public func write(_ journal: Journal, for id: UUID) throws {
        try beforeJournalWrite?(journal, id)
        var j = journal; j.updated = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(j)
        if j.backend == .tmpfs || j.nativeTmpfs != nil || j.nativeLink != nil {
            // Validate the exact bytes before replacement. An invalid transition
            // must retain the last readable durable journal, not strand recovery.
            _ = try journalDecoder.decode(Journal.self, from: bytes)
        }
        try Self.atomicData(bytes, volume(id).appendingPathComponent("journal.json"))
    }
    public func resolve(_ ref: String, config: Configuration) throws -> Folder {
        let value = ref.hasPrefix("ram://") ? (String(ref.dropFirst(6)).removingPercentEncoding ?? "") : ref
        let path = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
        guard let folder = config.folders.first(where: { $0.id.uuidString.caseInsensitiveCompare(value) == .orderedSame || $0.name.caseInsensitiveCompare(value) == .orderedSame || $0.path == path }) else { throw NestError("RAM folder not found: \(ref)", code: 64) }
        return folder
    }
    public static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try read(type, url, decoder: JSONDecoder())
    }
    static func read<T: Decodable>(_ type: T.Type, _ url: URL, decoder: JSONDecoder) throws -> T {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError("Cannot read \(url.lastPathComponent).", code: 6) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.readToEnd() ?? Data()
        return try decoder.decode(type, from: data)
    }
    public static func atomicJSON<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicData(encoder.encode(value), url)
    }
    public static func atomicData(_ data: Data, _ url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NestError("Cannot create durable state: \(String(cString: strerror(errno)))", code: 6) }
        var success = false
        defer { close(fd); if !success { unlink(temp.path) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw NestError("Durable state write failed.", code: 6) }; offset += count
            }
        }
        guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw NestError("Durable state promotion failed.", code: 6) }
        try syncDirectory(url.deletingLastPathComponent()); success = true
    }
    public static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError("Cannot open directory for sync.", code: 6) }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw NestError("Directory sync failed.", code: 6) }
    }
}

/// Stable, bundle-independent bootstrap. Explicit --store bypasses selection,
/// but every Store still respects a source retirement fence.
public struct StoreLocation: Sendable {
    public let bootstrapRoot: URL
    public var selectionURL: URL { bootstrapRoot.appendingPathComponent("storage-location.json") }
    public init(bootstrapRoot: URL = Store.defaultRoot) {
        self.bootstrapRoot = bootstrapRoot.standardizedFileURL
    }

    public struct Selection: Codable, Equatable, Sendable {
        let version: Int
        let stage: String
        let root: String
        let device: UInt64
        let inode: UInt64
        private enum CodingKeys: String, CodingKey, CaseIterable { case version, stage, root, device, inode }
        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(root: URL, identity: (device: UInt64, inode: UInt64)) {
            version = 1; stage = "committed"; self.root = root.path
            device = identity.device; inode = identity.inode
        }
        public init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: AnyKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw NestError("Incomplete or unknown snapshot storage selection. Keep both stores and restore the recorded selection file.", code: 6)
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            stage = try values.decode(String.self, forKey: .stage)
            root = try values.decode(String.self, forKey: .root)
            device = try values.decode(UInt64.self, forKey: .device)
            inode = try values.decode(UInt64.self, forKey: .inode)
            guard version == 1, stage == "committed", root.hasPrefix("/"),
                  URL(fileURLWithPath: root).standardizedFileURL.path == root,
                  !root.utf8.contains(0), inode != 0 else {
                throw NestError("Unsupported or unfinished snapshot storage selection. Keep both stores; do not reset to an empty store.", code: 6)
            }
        }
    }
    public struct Resolution: Sendable {
        public let root: URL
        fileprivate let selection: Selection?
    }

    /// Absence alone means legacy. A dangling link, unreadable file, invalid
    /// JSON, wrong owner, missing drive or replaced inode is always an error.
    public func resolve() throws -> Resolution {
        if let receipt = try StorageRelocation.readReceipt(at: bootstrapRoot), receipt.stage != .retiring {
            throw NestError("A snapshot storage move needs attention. Open Settings and Retry storage move. Source: \(receipt.source.path); destination: \(receipt.destination.path).", code: 6)
        }
        let parent: DirectoryHandle
        do { parent = try DirectoryHandle.open(bootstrapRoot) }
        catch {
            var info = stat()
            if lstat(bootstrapRoot.path, &info) != 0 && errno == ENOENT {
                try Paths.rejectSymlinks(bootstrapRoot.path, allowMissingLast: true)
                return Resolution(root: bootstrapRoot, selection: nil)
            }
            throw error
        }
        let parentIdentity = try parent.identity()
        try parent.requireOwnedDirectory(device: parentIdentity.device, privateMode: true)
        guard try parent.exists(selectionURL.lastPathComponent) else {
            return Resolution(root: bootstrapRoot, selection: nil)
        }
        let fd = openat(parent.fd, selectionURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NestError("Cannot read snapshot storage selection. Restore access to \(selectionURL.path).", code: 6) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 16 << 10 else {
            throw NestError("Unsafe snapshot storage selection file; storage has not been opened.", code: 6)
        }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: (16 << 10) + 1) ?? Data()
        guard bytes.count == Int(info.st_size) else {
            throw NestError("Snapshot storage selection changed during its bounded read.", code: 6)
        }
        let selection: Selection
        do { selection = try JSONDecoder().decode(Selection.self, from: bytes) }
        catch {
            throw NestError("Invalid snapshot storage selection at \(selectionURL.path). Keep this record and the existing stores for recovery; no default store was substituted.", code: 6)
        }
        // The sole future writer uses Store.atomicJSON. Requiring its canonical
        // representation also rejects duplicate keys and trailing JSON values.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard try encoder.encode(selection) == bytes,
              try DirectoryHandle.open(bootstrapRoot).identity() == parentIdentity else {
            throw NestError("Snapshot storage selection changed or is not canonical; keep the record for recovery.", code: 6)
        }
        let root = URL(fileURLWithPath: selection.root)
        try verify(selection, root: root)
        return Resolution(root: root, selection: selection)
    }

    public func open(explicitRoot: URL? = nil) throws -> Store {
        if let explicitRoot { return try Store(root: explicitRoot) }
        let resolution = try resolve()
        return try Store(root: resolution.root, locationAuthority: {
            let current = try resolve()
            guard current.root.path == resolution.root.path, current.selection == resolution.selection else {
                throw NestError("Snapshot storage location changed. Reopen RAMNest or rerun the command before writing.", code: 6)
            }
        })
    }

    // Fixture construction and the eventual transaction writer share the same
    // identity validation. This function never writes the selection file.
    func selection(for root: URL) throws -> Selection {
        let handle = try DirectoryHandle.open(root)
        let selection = Selection(root: root.standardizedFileURL, identity: try handle.identity())
        try verify(selection, root: root)
        return selection
    }
    private func verify(_ selection: Selection, root: URL) throws {
        let directory: DirectoryHandle
        do { directory = try DirectoryHandle.open(root) }
        catch { throw NestError("Snapshot storage is unavailable at \(root.path). Reconnect the selected drive; the default store will not be substituted.", code: 6) }
        guard try directory.identity() == (selection.device, selection.inode) else {
            throw NestError("Selected snapshot storage was replaced at \(root.path). Restore the original directory; storage has not been adopted.", code: 6)
        }
        try directory.requireOwnedDirectory(device: selection.device, privateMode: true)
        let volumes = try directory.child("volumes")
        try volumes.requireOwnedDirectory(device: selection.device, privateMode: true)
        var fs = statfs()
        guard fstatfs(directory.fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              fs.f_flags & UInt32(MNT_RDONLY) == 0 else {
            throw NestError("Snapshot storage requires an available writable local filesystem.", code: 6)
        }
    }
}

public final class StorageMoveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw NestError("Storage move paused before commit. Use Retry storage move to continue; source data is retained.", code: 6) }
    }
}

public struct SnapshotStorageState: Sendable {
    public var path: String
    public var pending: String?
    public var cleanupPending: Bool
}

/// The only location writer. Normal operations serialize through repository /
/// volume locks; relocation holds repo then TRIES volume locks, never waits.
public final class SnapshotStorageManager: @unchecked Sendable {
    public let location: StoreLocation
    // Controlled fixture fault seams; never read from environment/preferences.
    var fault: ((String) throws -> Void)?
    public init(location: StoreLocation = StoreLocation()) { self.location = location }
    public func open() throws -> Store { try location.open() }
    public func state() throws -> SnapshotStorageState {
        if let r = try StorageRelocation.readReceipt(at: location.bootstrapRoot) {
            return SnapshotStorageState(path: r.stage == .retiring ? r.destination.path : r.source.path,
                pending: r.stage == .retiring ? "Storage moved. Old payload cleanup is pending; retry to finish." : "An interrupted storage move needs Retry. Both recorded locations are retained.",
                cleanupPending: r.stage == .retiring)
        }
        do { return SnapshotStorageState(path: try location.resolve().root.path, pending: nil, cleanupPending: false) }
        catch {
            let bootstrap = try DirectoryHandle.open(location.bootstrapRoot)
            guard try bootstrap.exists(location.selectionURL.lastPathComponent) else { throw error }
            let selection = try StorageRelocation.read(StoreLocation.Selection.self, in: bootstrap, name: location.selectionURL.lastPathComponent)
            return SnapshotStorageState(path: selection.root, pending: "Selected storage is unavailable. Reconnect it, then Retry. " + error.localizedDescription, cleanupPending: false)
        }
    }
    public func move(store: Store, toParent parent: URL, cancellation: StorageMoveCancellation = .init(),
                     progress: @Sendable (String) -> Void = { _ in }) throws -> SnapshotStorageState {
        try StorageRelocation.Transaction(manager: self).move(store: store, parent: parent, cancellation: cancellation, progress: progress)
        return try state()
    }
    public func retry(progress: @Sendable (String) -> Void = { _ in }) throws -> SnapshotStorageState {
        try StorageRelocation.Transaction(manager: self).retry(progress: progress)
        return try state()
    }
}

// An opaque physical inventory, deliberately unrelated to Snapshot.manifest:
// no Trash exclusions, logical-mode projection, export or source chmod.
enum StorageRelocation {
    enum Stage: String, Codable { case reserving, copying, verified, fenced, retiring }
    struct Root: Codable, Equatable {
        var path: String; var device: UInt64; var inode: UInt64
        init(path: String, device: UInt64, inode: UInt64) { self.path = path; self.device = device; self.inode = inode }
        init(_ url: URL) throws {
            path = url.standardizedFileURL.path
            let handle = try DirectoryHandle.open(url), identity = try handle.identity()
            try handle.requireOwnedDirectory(device: identity.device)
            device = identity.device; inode = identity.inode
        }
        func open(privateMode: Bool = true) throws -> DirectoryHandle {
            let h = try DirectoryHandle.open(URL(fileURLWithPath: path))
            guard try h.identity() == (device, inode) else { throw NestError("Recorded storage identity changed at \(path). Keep both locations for recovery.", code: 6) }
            try h.requireOwnedDirectory(device: device, privateMode: privateMode)
            return h
        }
    }
    struct Item: Codable, Equatable {
        var path: String; var device: UInt64; var inode: UInt64
        var kind: UInt16; var mode: UInt16; var uid: UInt32; var gid: UInt32
        var flags: UInt32; var size: Int64; var modifiedSeconds: Int64; var modifiedNanos: Int64
        var attributes: [String: Data]; var acl: String; var digest: String?; var link: Data?
        var fileVerification: FileVerification? = nil // Missing is legacy SHA; only payload entries may be weak.
        enum CodingKeys: String, CodingKey { case path, device, inode, kind, mode, uid, gid, flags, size, modifiedSeconds, modifiedNanos, attributes, acl, digest, link, fileVerification }
        static func revisionPayload(_ path: String) -> Bool {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return parts.count >= 6 && parts[0] == "volumes" && UUID(uuidString: parts[1]) != nil &&
                parts[2] == "revisions" && UUID(uuidString: parts[3]) != nil && parts[4] == "data" &&
                parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
        }
        func sameCopyContent(_ other: Item, directoryTimes: Bool = true) -> Bool {
            var source = self, destination = other
            source.attributes.removeValue(forKey: Snapshot.provenanceName)
            destination.attributes.removeValue(forKey: Snapshot.provenanceName)
            return source.sameContent(destination, directoryTimes: directoryTimes)
        }
        func sameContent(_ other: Item, directoryTimes: Bool = true) -> Bool {
            path == other.path && kind == other.kind && mode == other.mode && uid == other.uid && gid == other.gid &&
            flags == other.flags && (kind == UInt16(S_IFDIR) || size == other.size) &&
            ((!directoryTimes && kind == UInt16(S_IFDIR)) || (modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos)) &&
            attributes == other.attributes && acl == other.acl && digest == other.digest && link == other.link && fileVerification == other.fileVerification
        }
    }
    struct Receipt: Codable {
        var version = 1; var transaction: UUID; var stage: Stage
        var bootstrap: Root; var source: Root; var sourceParent: Root
        var destination: Root; var destinationParent: Root
        var rootMetadata: Item
        var inventory: [Item]
        var destinationInventory: [Item]? = nil
        var destinationRootMetadata: Item? = nil
        var sourceObservation: Item? = nil
        var destinationObservation: Item? = nil
        var partialFile: PartialFile? = nil
        var allocations: [String: Allocation] = [:]
    }
    struct Allocation: Codable { var device: UInt64; var inode: UInt64; var kind: UInt16; var attributes: [String: Data]? = nil }
    struct PartialFile: Codable {
        var parent: Root; var temporary: String; var finalPath: String
        var device: UInt64; var inode: UInt64
        var attributes: [String: Data]? = nil
    }
    struct Fence: Codable, Equatable {
        var version = 1; var transaction: UUID; var bootstrap: String; var destination: String
    }
    static let receiptName = "storage-migration.json"
    static let fenceName = ".ramnest-retired.json"
    static let incomingName = ".ramnest-incoming.json"
    static let bootstrapNames: Set<String> = ["storage-location.json", receiptName, "storage-location.lock", "repository.lock"]

    // Canonical decoding rejects unknown/duplicate/partial/null records too.
    static func read<T: Codable>(_ type: T.Type, in directory: DirectoryHandle, name: String) throws -> T {
        let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NestError("Cannot read storage move record \(name). Keep both locations.", code: 6) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o077 == 0, st.st_nlink == 1, st.st_size > 0, st.st_size <= 64 << 20 else {
            throw NestError("Unsafe storage move record \(name); keep both locations.", code: 6)
        }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: (64 << 20) + 1) ?? Data()
        let value = try JSONDecoder().decode(type, from: bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard bytes.count == Int(st.st_size), try encoder.encode(value) == bytes else { throw NestError("Noncanonical storage move record; preserve it for recovery.", code: 6) }
        return value
    }
    static func readReceipt(at root: URL) throws -> Receipt? {
        var st = stat()
        if lstat(root.path, &st) != 0 {
            guard errno == ENOENT else { throw NestError("Cannot inspect storage bootstrap.", code: 6) }
            return nil
        }
        let directory = try DirectoryHandle.open(root)
        try directory.requireOwnedDirectory(device: try directory.identity().device, privateMode: true)
        guard try directory.exists(receiptName) else { return nil }
        let receipt = try read(Receipt.self, in: directory, name: receiptName)
        guard receipt.version == 1, receipt.bootstrap.path == root.standardizedFileURL.path,
              Set(receipt.inventory.map(\.path)).count == receipt.inventory.count,
              receipt.inventory.map(\.path) == receipt.inventory.map(\.path).sorted(),
              receipt.rootMetadata.path == ".", receipt.rootMetadata.device == receipt.source.device,
              receipt.rootMetadata.inode == receipt.source.inode,
              receipt.sourceParent.path == URL(fileURLWithPath: receipt.source.path).deletingLastPathComponent().path,
              receipt.destination.path == URL(fileURLWithPath: receipt.destinationParent.path).appendingPathComponent("RAMNest Snapshots").path else {
            throw NestError("Unknown storage move record. Preserve both stores and the bootstrap record.", code: 6)
        }
        // Path parsing must never acquire authority through relative names.
        for item in receipt.inventory {
            guard item.device == receipt.source.device, item.inode != 0, !item.path.hasPrefix("/"),
                  [UInt16(S_IFDIR), UInt16(S_IFREG), UInt16(S_IFLNK)].contains(item.kind) else { throw NestError("Invalid storage inventory identity.", code: 6) }
            for component in item.path.split(separator: "/", omittingEmptySubsequences: false) {
                guard !component.isEmpty, component != ".", component != "..", !component.utf8.contains(0) else { throw NestError("Unsafe recorded inventory path.", code: 6) }
            }
        }
        for anchor in [receipt.bootstrap, receipt.source, receipt.sourceParent, receipt.destination, receipt.destinationParent] {
            guard anchor.path.hasPrefix("/"), !anchor.path.utf8.contains(0), URL(fileURLWithPath: anchor.path).standardizedFileURL.path == anchor.path,
                  anchor.inode != 0 || (receipt.stage == .reserving && anchor == receipt.destination) else { throw NestError("Malformed storage move anchor.", code: 6) }
        }
        let originals = Dictionary(uniqueKeysWithValues: receipt.inventory.map { ($0.path, $0) })
        for (path, allocation) in receipt.allocations {
            guard let original = originals[path], allocation.device == receipt.destination.device,
                  allocation.inode != 0, allocation.kind == original.kind else { throw NestError("Malformed storage allocation receipt.", code: 6) }
        }
        if let own = receipt.destinationInventory {
            guard own.map(\.path) == receipt.inventory.map(\.path),
                  own.allSatisfy({ item in
                      guard let allocation = receipt.allocations[item.path] else { return false }
                      return item.device == allocation.device && item.inode == allocation.inode && item.kind == allocation.kind
                  }) else { throw NestError("Malformed destination observation inventory.", code: 6) }
        }
        if let own = receipt.destinationRootMetadata {
            guard own.path == ".", own.device == receipt.destination.device, own.inode == receipt.destination.inode else { throw NestError("Malformed destination root observation.", code: 6) }
        }
        for (observation, root) in [(receipt.sourceObservation, receipt.source), (receipt.destinationObservation, receipt.destination)] {
            if let observation {
                guard observation.path == SnapshotCopyObservations.name, observation.device == root.device,
                      observation.inode != 0, observation.kind == UInt16(S_IFREG), observation.mode == 0o600 else { throw NestError("Malformed copy observation file receipt.", code: 6) }
            }
        }
        if let partial = receipt.partialFile {
            let final = URL(fileURLWithPath: receipt.destination.path).appendingPathComponent(partial.finalPath)
            guard originals[partial.finalPath]?.kind == UInt16(S_IFREG), partial.parent.path == final.deletingLastPathComponent().path,
                  partial.device == receipt.destination.device, partial.parent.device == receipt.destination.device,
                  partial.parent.inode != 0, partial.temporary.hasPrefix(".ramnest-move-"),
                  !partial.temporary.contains("/"), !partial.temporary.utf8.contains(0) else { throw NestError("Malformed partial copy receipt; both stores retained.", code: 6) }
        }
        return receipt
    }
}

extension StorageRelocation.Item {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path); device = try c.decode(UInt64.self, forKey: .device); inode = try c.decode(UInt64.self, forKey: .inode)
        kind = try c.decode(UInt16.self, forKey: .kind); mode = try c.decode(UInt16.self, forKey: .mode)
        uid = try c.decode(UInt32.self, forKey: .uid); gid = try c.decode(UInt32.self, forKey: .gid); flags = try c.decode(UInt32.self, forKey: .flags)
        size = try c.decode(Int64.self, forKey: .size); modifiedSeconds = try c.decode(Int64.self, forKey: .modifiedSeconds); modifiedNanos = try c.decode(Int64.self, forKey: .modifiedNanos)
        attributes = try c.decode([String: Data].self, forKey: .attributes); acl = try c.decode(String.self, forKey: .acl)
        digest = try c.decodeIfPresent(String.self, forKey: .digest); link = try c.decodeIfPresent(Data.self, forKey: .link)
        fileVerification = c.contains(.fileVerification) ? try c.decode(FileVerification.self, forKey: .fileVerification) : nil
        if fileVerification != nil {
            guard fileVerification == .sizeAndModTime, kind == UInt16(S_IFREG), digest == nil,
                  Self.revisionPayload(path) else { throw NestError("Invalid storage payload verification authority; retained.", code: 6) }
        } else if kind == UInt16(S_IFREG) {
            guard let digest, digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw NestError("Missing storage file SHA authority; retained.", code: 6) }
        }
    }
}

extension StorageRelocation {
    // A value wrapper keeps the manager's injected fault seam out of persistence.
    struct Transaction {
        let manager: SnapshotStorageManager
        var location: StoreLocation { manager.location }
        func checkpoint(_ name: String) throws { try manager.fault?(name) }
        func write(_ receipt: Receipt) throws {
            let directory = try receipt.bootstrap.open()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(receipt)
            guard bytes.count <= 64 << 20 else { throw NestError("Storage inventory exceeds the safe receipt limit; source retained.", code: 6) }
            try atomic(bytes, directory: directory, name: StorageRelocation.receiptName)
        }
        func atomic(_ bytes: Data, directory: DirectoryHandle, name: String) throws {
            let temporary = ".write-" + UUID().uuidString
            let fd = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NestError("Cannot reserve durable storage control record.", code: 6) }
            defer { close(fd); unlinkat(directory.fd, temporary, 0) }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count-offset)
                    guard n > 0 else { throw NestError("Storage control record write failed.", code: 6) }; offset += n
                }
            }
            guard fsync(fd) == 0, renameat(directory.fd, temporary, directory.fd, name) == 0 else { throw NestError("Storage control publication failed; retry the recorded move.", code: 6) }
            try directory.sync()
        }
        func stableLock() throws -> Int32 {
            try Paths.rejectSymlinks(location.bootstrapRoot.path, allowMissingLast: true)
            try Store.privateDirectory(location.bootstrapRoot)
            return try lock(DirectoryHandle.open(location.bootstrapRoot), "storage-location.lock", nonblocking: true)
        }
        func lock(_ root: DirectoryHandle, _ name: String, nonblocking: Bool) throws -> Int32 {
            let fd = openat(root.fd, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NestError("Cannot open storage transaction lock.", code: 6) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_nlink == 1,
                  st.st_size == 0,
                  flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
                close(fd); throw NestError("Storage is busy. Wait for current folder operations to finish and retry.", code: 7)
            }
            return fd
        }
        func release(_ descriptors: [Int32]) { for fd in descriptors.reversed() { flock(fd, LOCK_UN); close(fd) } }
        func excluded(_ source: Root) -> Set<String> {
            (source.path == location.bootstrapRoot.path ? StorageRelocation.bootstrapNames : ["repository.lock"]).union([SnapshotCopyObservations.name])
        }
        func move(store: Store, parent: URL, cancellation: StorageMoveCancellation,
                  progress: @Sendable (String) -> Void) throws {
            let stable = try stableLock(); defer { release([stable]) }
            guard try StorageRelocation.readReceipt(at: location.bootstrapRoot) == nil else { throw NestError("Retry the pending storage move before choosing another location.", code: 6) }
            let current = try location.resolve()
            guard current.root.path == store.root.path else { throw NestError("Only the current selected store can be moved. Explicit --store sessions are isolated.", code: 6) }
            // A panel chooses a parent. Passing the existing actual root itself
            // is also a no-op, useful to injected callers and repeated selections.
            if parent.standardizedFileURL.path == store.root.path { return }
            let destinationURL = parent.standardizedFileURL.appendingPathComponent("RAMNest Snapshots", isDirectory: true)
            if destinationURL.path == store.root.path { return }
            guard !Paths.overlaps(destinationURL.path, store.root.path),
                  !Paths.overlaps(destinationURL.path, location.bootstrapRoot.path) else {
                throw NestError("Snapshot storage cannot overlap the current store or bootstrap directory.", code: 4)
            }
            let source = try Root(store.root), sourceHandle = try source.open()
            try Store.rejectRetired(store.root)
            let repo = try lock(sourceHandle, "repository.lock", nonblocking: true)
            var locks = [repo]; defer { release(locks) }
            let config = try store.load()
            let volumes = try sourceHandle.child("volumes")
            try volumes.requireOwnedDirectory(device: source.device, privateMode: true)
            let expected = Set(config.folders.map { $0.id.uuidString })
            guard Set(try volumes.names()) == expected else { throw NestError("Unconfigured or missing volume data blocks relocation. Recover it before moving storage.", code: 6) }
            for folder in config.folders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let volume = try volumes.child(folder.id.uuidString)
                try volume.requireOwnedDirectory(device: source.device, privateMode: true)
                locks.append(try lock(volume, "transaction.lock", nonblocking: true))
                let journal = try store.journal(folder.id)
                try idle(journal, folder: folder)
                try Paths.checkedIdentity(folder)
                let forbidden = [folder.path, URL(fileURLWithPath: folder.path).deletingLastPathComponent().appendingPathComponent(".ramnest-\(folder.id.uuidString)").path]
                guard !forbidden.contains(where: { Paths.overlaps(destinationURL.path, $0) }) else { throw NestError("Snapshot storage overlaps a managed source or holding location.", code: 4) }
                let selectedParent = URL(fileURLWithPath: folder.path).deletingLastPathComponent().path
                if parent.path.lowercased().hasPrefix(selectedParent.lowercased() + "/.ramnest-\(folder.id.uuidString.lowercased())") { throw NestError("Choose storage outside managed holding/staging locations.", code: 4) }
                if let layout = journal.managedLink, [layout.mountRoot, layout.holdingPath, layout.linkStagePath].contains(where: { Paths.overlaps(destinationURL.path, $0) }) { throw NestError("Snapshot storage cannot overlap a linked-folder lifecycle location.", code: 4) }
            }
            // Config topology cannot change while repository.lock is held.
            let parentRoot = try Root(parent), parentHandle = try parentRoot.open(privateMode: false)
            if parentRoot.device == source.device && parentRoot.inode == source.inode { return }
            // Identity checks also cover case aliases / APFS firmlink spellings
            // that a lexical overlap check cannot establish.
            let bootstrapIdentity = try Root(location.bootstrapRoot)
            var ancestor = parent.standardizedFileURL
            while ancestor.path != "/" {
                let identity = try DirectoryHandle.open(ancestor).identity()
                guard identity != (source.device, source.inode), identity != (bootstrapIdentity.device, bootstrapIdentity.inode),
                      !config.folders.contains(where: { $0.device == identity.device && $0.inode == identity.inode }) else {
                    throw NestError("Snapshot parent is physically inside managed storage or a source folder.", code: 4)
                }
                ancestor = ancestor.deletingLastPathComponent()
            }
            try writableLocal(parentHandle)
            guard !Paths.mounts().contains(where: { $0.path == destinationURL.path || $0.path.hasPrefix(destinationURL.path + "/") }),
                  try !parentHandle.exists(destinationURL.lastPathComponent) else { throw NestError("The dedicated RAMNest Snapshots child already exists. Choose another parent; existing content will not be adopted.", code: 4) }
            try cancellation.check(); progress("Inspecting every stored entry…")
            let inventory = try scan(source, excluding: excluded(source), cancellation: cancellation)
            var receipt = Receipt(transaction: UUID(), stage: .reserving, bootstrap: try Root(location.bootstrapRoot),
                source: source, sourceParent: try Root(store.root.deletingLastPathComponent()),
                destination: Root(path: destinationURL.path, device: parentRoot.device, inode: 0),
                destinationParent: parentRoot,
                rootMetadata: try inspect(DirectoryHandle.open(store.root.deletingLastPathComponent()), name: store.root.lastPathComponent, relative: ".", device: source.device), inventory: inventory)
            if try sourceHandle.exists(SnapshotCopyObservations.name) {
                receipt.sourceObservation = try inspect(sourceHandle, name: SnapshotCopyObservations.name, relative: SnapshotCopyObservations.name, device: source.device)
                _ = try SnapshotCopyObservations.read(store.root)
            }
            try write(receipt)
            // Fence explicit clients before any interruptible allocation/copy.
            // Recovery owns the recorded transaction and uses anchored handles.
            try durableFence(StorageRelocation.Fence(transaction: receipt.transaction, bootstrap: receipt.bootstrap.path, destination: receipt.destination.path),
                             directory: sourceHandle, name: StorageRelocation.fenceName)
            try checkpoint("reservation-intent")
            _ = try parentHandle.createDirectory(destinationURL.lastPathComponent); try parentHandle.sync()
            receipt.destination = try Root(destinationURL); receipt.stage = .copying
            try write(receipt)
            try checkpoint("reserved")
            try advance(&receipt, cancellation: cancellation, progress: progress)
        }
        func idle(_ journal: Journal, folder: Folder) throws {
            guard journal.phase == .idle, journal.lastError == nil, journal.publicationReceipt == nil || journal.publicationReceipt?.phase == "published",
                  journal.restoreStage == nil, journal.restoreRevision == nil,
                  journal.evacuation == nil, journal.siblingCleanup?.isEmpty != false,
                  journal.retiringRevisions?.isEmpty != false, journal.cleanupWarning == nil,
                  journal.startupProtocol == nil || journal.startupRetired == true || journal.populationVerified,
                  journal.managedLink == nil || (journal.managedLink?.stage == .restored && journal.managedLink?.mountReleased == true) else {
                throw NestError("\(folder.name) has unfinished restore, capture or cleanup work. Finish recovery before moving storage.", code: 7)
            }
            if let socket = journal.socket {
                var st = stat()
                if lstat(socket, &st) == 0 { throw NestError("A helper socket still exists for \(folder.name). Finish its session before moving storage.", code: 7) }
                guard errno == ENOENT else { throw NestError("Cannot establish helper absence for \(folder.name).", code: 7) }
            }
            for pid in [journal.startupHelperPID, journal.quiescedHelperPID].compactMap({ $0 }) where pid > 0 {
                if kill(pid, 0) == 0 || errno != ESRCH { throw NestError("A recorded helper process may still own \(folder.name). Finish its session before moving storage.", code: 7) }
            }
            let paths = [folder.path, journal.nativeTmpfs.map { NativeTmpfsPaths.mount($0.session).path }, journal.managedLink?.mountPath].compactMap { $0 }
            guard !Paths.mounts().contains(where: { mount in paths.contains(where: { mount.path == $0 || mount.path.hasPrefix($0 + "/") }) }) else {
                throw NestError("Eject \(folder.name) before moving snapshots.", code: 7)
            }
        }
        func retry(progress: @Sendable (String) -> Void) throws {
            let stable = try stableLock(); defer { release([stable]) }
            guard var receipt = try StorageRelocation.readReceipt(at: location.bootstrapRoot) else { return }
            if receipt.stage == .reserving {
                try validate(receipt, destinationRequired: false)
                let parent = try receipt.destinationParent.open(privateMode: false)
                let name = URL(fileURLWithPath: receipt.destination.path).lastPathComponent
                guard try !parent.exists(name) else { throw NestError("Interrupted reservation has an unrecorded child identity at \(receipt.destination.path). Keep it and the source; manual review is required before clearing the move record. No pathname was adopted.", code: 6) }
                _ = try parent.createDirectory(name); try parent.sync()
                receipt.destination = try Root(URL(fileURLWithPath: receipt.destination.path)); receipt.stage = .copying
                try write(receipt)
            }
            try validate(receipt)
            let repo = try lock(receipt.source.open(), "repository.lock", nonblocking: true)
            defer { release([repo]) }
            // Once recorded, copying/fenced stores are unavailable through the
            // resolver. Explicit old clients are also checked below / fenced.
            var locks: [Int32] = []; defer { release(locks) }
            if receipt.stage == .copying || receipt.stage == .verified {
                let source = try receipt.source.open(), volumes = try source.child("volumes")
                try volumes.requireOwnedDirectory(device: receipt.source.device, privateMode: true)
                let config = try source.exists("configuration.json") ? source.readJSON(Configuration.self, "configuration.json") : Configuration()
                guard Set(try volumes.names()) == Set(config.folders.map { $0.id.uuidString }) else { throw NestError("Recorded source topology changed; keep both stores for manual recovery.", code: 6) }
                for folder in config.folders {
                    let volume = try volumes.child(folder.id.uuidString)
                    try volume.requireOwnedDirectory(device: receipt.source.device, privateMode: true)
                    locks.append(try lock(volume, "transaction.lock", nonblocking: true))
                    let journal = try volume.exists("journal.json") ? volume.readJSON(Journal.self, "journal.json") : Journal()
                    try idle(journal, folder: folder)
                }
            }
            try advance(&receipt, cancellation: .init(), progress: progress)
        }
        func validate(_ receipt: Receipt, destinationRequired: Bool = true) throws {
            _ = try receipt.bootstrap.open(); _ = try receipt.sourceParent.open(privateMode: false)
            _ = try receipt.destinationParent.open(privateMode: false); _ = try receipt.source.open()
            if destinationRequired { _ = try receipt.destination.open() }
            guard !Paths.overlaps(receipt.source.path, receipt.destination.path), receipt.destination.path == URL(fileURLWithPath: receipt.destinationParent.path).appendingPathComponent("RAMNest Snapshots").path else {
                throw NestError("Invalid recorded storage paths; keep all data for recovery.", code: 6)
            }
            let bootstrap = try receipt.bootstrap.open()
            if try bootstrap.exists(location.selectionURL.lastPathComponent) {
                let selection = try StorageRelocation.read(StoreLocation.Selection.self, in: bootstrap, name: location.selectionURL.lastPathComponent)
                let sourceMatches = selection.root == receipt.source.path && selection.device == receipt.source.device && selection.inode == receipt.source.inode
                let destinationMatches = selection.root == receipt.destination.path && selection.device == receipt.destination.device && selection.inode == receipt.destination.inode
                guard sourceMatches || ((receipt.stage == .fenced || receipt.stage == .retiring) && destinationMatches) else { throw NestError("Storage selection conflicts with recorded migration; preserve both stores.", code: 6) }
            } else {
                guard receipt.source == receipt.bootstrap, receipt.stage != .retiring else { throw NestError("Missing committed storage selection; no fallback is permitted.", code: 6) }
            }
        }
        func advance(_ receipt: inout Receipt, cancellation: StorageMoveCancellation,
                     progress: @Sendable (String) -> Void) throws {
            try validate(receipt)
            if receipt.stage != .retiring {
                let destination = try receipt.destination.open()
                let fence = StorageRelocation.Fence(transaction: receipt.transaction, bootstrap: receipt.bootstrap.path, destination: receipt.destination.path)
                try durableFence(fence, directory: receipt.source.open(), name: StorageRelocation.fenceName)
                try durableFence(fence, directory: destination, name: StorageRelocation.incomingName)
            }
            if receipt.stage == .copying {
                try cancellation.check(); try checkpoint("copy")
                progress("Copying the complete snapshot store…")
                try matchSource(receipt)
                if receipt.destinationInventory == nil { try copy(&receipt, cancellation: cancellation) }
                try checkpoint("hash")
                let copied = try scan(receipt.destination, excluding: [StorageRelocation.incomingName, SnapshotCopyObservations.name], cancellation: cancellation, matching: receipt.inventory)
                guard destinationMatches(receipt, copied), ownedCopies(receipt, copied), try rootMatches(receipt, root: receipt.destination) else { throw NestError("Opaque storage copy verification failed. Source and partial destination retained; retry or preserve both for recovery.", code: 6) }
                receipt.destinationInventory = copied
                let destinationURL = URL(fileURLWithPath: receipt.destination.path)
                receipt.destinationRootMetadata = try inspect(DirectoryHandle.open(destinationURL.deletingLastPathComponent()), name: destinationURL.lastPathComponent, relative: ".", device: receipt.destination.device)
                try installCopyObservations(&receipt)
                receipt.destinationRootMetadata = try inspect(DirectoryHandle.open(destinationURL.deletingLastPathComponent()), name: destinationURL.lastPathComponent, relative: ".", device: receipt.destination.device)
                try matchSource(receipt)
                try checkpoint("fsync")
                try receipt.destination.open().sync()
                receipt.stage = .verified; try write(receipt); try checkpoint("verified")
            }
            if receipt.stage == .verified {
                try verifyCopyObservation(receipt)
                try cancellation.check(); progress("Verifying before committing storage selection…")
                try matchSource(receipt)
                let copied = try scan(receipt.destination, excluding: [StorageRelocation.incomingName, SnapshotCopyObservations.name], cancellation: cancellation, matching: receipt.inventory)
                guard destinationMatches(receipt, copied), ownedCopies(receipt, copied), try rootMatches(receipt, root: receipt.destination) else { throw NestError("Verified destination changed. Both stores retained.", code: 6) }
                let source = try receipt.source.open()
                let fence = StorageRelocation.Fence(transaction: receipt.transaction, bootstrap: receipt.bootstrap.path, destination: receipt.destination.path)
                let destination = try receipt.destination.open()
                try durableFence(fence, directory: destination, name: StorageRelocation.incomingName)
                try durableFence(fence, directory: source, name: StorageRelocation.fenceName)
                receipt.stage = .fenced; try write(receipt); try checkpoint("fenced")
            }
            if receipt.stage == .fenced {
                try verifyCopyObservation(receipt)
                progress("Committing storage selection; cancellation is no longer available…")
                let source = try receipt.source.open()
                let fence = StorageRelocation.Fence(transaction: receipt.transaction, bootstrap: receipt.bootstrap.path, destination: receipt.destination.path)
                try durableFence(fence, directory: source, name: StorageRelocation.fenceName)
                try durableFence(fence, directory: receipt.destination.open(), name: StorageRelocation.incomingName)
                let copied = try scan(receipt.destination, excluding: [StorageRelocation.incomingName, SnapshotCopyObservations.name], matching: receipt.inventory)
                guard try StorageRelocation.read(StorageRelocation.Fence.self, in: source, name: StorageRelocation.fenceName) == StorageRelocation.Fence(transaction: receipt.transaction, bootstrap: receipt.bootstrap.path, destination: receipt.destination.path),
                      destinationMatches(receipt, copied), ownedCopies(receipt, copied), try rootMatches(receipt, root: receipt.destination) else { throw NestError("Fenced move cannot be proven. Preserve both stores and retry after restoring access.", code: 6) }
                try checkpoint("publication")
                let selection = try location.selection(for: URL(fileURLWithPath: receipt.destination.path))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try atomic(encoder.encode(selection), directory: receipt.bootstrap.open(), name: location.selectionURL.lastPathComponent)
                receipt.stage = .retiring; try write(receipt); try checkpoint("committed")
            }
            if receipt.stage == .retiring {
                progress("Storage selected. Removing verified obsolete payload…")
                let resolution = try location.resolve()
                guard resolution.root.path == receipt.destination.path else { throw NestError("Selection does not match the committed move; old payload retained.", code: 6) }
                try checkpoint("cleanup")
                try retire(receipt)
                let bootstrap = try receipt.bootstrap.open()
                guard unlinkat(bootstrap.fd, StorageRelocation.receiptName, 0) == 0 else { throw NestError("Storage moved; cleanup receipt removal needs Retry.", code: 6) }
                do { try bootstrap.sync() }
                catch { try? write(receipt); throw error }
            }
        }
        func contentMatches(_ expected: [Item], _ actual: [Item]) -> Bool {
            expected.count == actual.count && zip(expected, actual).allSatisfy { $0.sameContent($1) }
        }
        func destinationMatches(_ receipt: Receipt, _ actual: [Item]) -> Bool {
            if let own = receipt.destinationInventory { return contentMatches(own, actual) }
            if receipt.stage != .copying { return contentMatches(receipt.inventory, actual) }
            return receipt.inventory.count == actual.count && zip(receipt.inventory, actual).allSatisfy { $0.sameCopyContent($1) }
        }
        func ownedCopies(_ receipt: Receipt, _ actual: [Item]) -> Bool {
            actual.allSatisfy { item in
                guard let allocation = receipt.allocations[item.path] else { return false }
                return allocation.device == item.device && allocation.inode == item.inode && allocation.kind == item.kind && (allocation.attributes == nil || allocation.attributes == item.attributes)
            }
        }
        func matchSource(_ receipt: Receipt) throws {
            let actual = try scan(receipt.source, excluding: excluded(receipt.source).union([StorageRelocation.fenceName]), matching: receipt.inventory)
            let source = try receipt.source.open()
            if let recorded = receipt.sourceObservation {
                guard try inspect(source, name: SnapshotCopyObservations.name, relative: SnapshotCopyObservations.name, device: receipt.source.device) == recorded else { throw NestError("Source copy observations changed; both stores retained.", code: 6) }
            } else if try source.exists(SnapshotCopyObservations.name) { throw NestError("Source gained unknown copy observations; retained.", code: 6) }
            guard actual == receipt.inventory, try rootMatches(receipt, root: receipt.source) else { throw NestError("Source data changed after the move was recorded. Preserve both locations; no selection was changed.", code: 6) }
        }
        func rootMatches(_ receipt: Receipt, root: Root) throws -> Bool {
            let url = URL(fileURLWithPath: root.path)
            let current = try inspect(DirectoryHandle.open(url.deletingLastPathComponent()), name: url.lastPathComponent, relative: ".", device: root.device)
            if root == receipt.destination {
                if let own = receipt.destinationRootMetadata { return own.sameContent(current, directoryTimes: false) }
                if receipt.stage != .copying { return receipt.rootMetadata.sameContent(current, directoryTimes: false) }
                return receipt.rootMetadata.sameCopyContent(current, directoryTimes: false)
            }
            return receipt.rootMetadata.sameContent(current, directoryTimes: false)
        }
        func durableFence(_ value: StorageRelocation.Fence, directory: DirectoryHandle, name: String) throws {
            if try !directory.exists(name) { try exclusiveJSON(value, directory: directory, name: name) }
            let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NestError("Cannot reopen recorded migration fence; both stores retained.", code: 6) }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
                  st.st_nlink == 1, st.st_mode & 0o077 == 0, st.st_size > 0, st.st_size <= 16384 else {
                throw NestError("Unsafe migration fence; both stores retained.", code: 6)
            }
            let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16385) ?? Data()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard bytes.count == Int(st.st_size), try encoder.encode(value) == bytes,
                  try JSONDecoder().decode(StorageRelocation.Fence.self, from: bytes) == value else {
                throw NestError("Migration fence authority changed; both stores retained.", code: 6)
            }
            try checkpoint("fence-file-sync")
            guard fsync(fd) == 0 else { throw NestError("Recorded migration fence is not durable; Retry.", code: 6) }
            try checkpoint("fence-directory-sync")
            try directory.sync()
            let named = try directory.entryStat(name)
            guard named.st_dev == st.st_dev, named.st_ino == st.st_ino else { throw NestError("Migration fence was replaced; both stores retained.", code: 6) }
        }
        func exclusiveJSON<T: Encodable>(_ value: T, directory: DirectoryHandle, name: String) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(value)
            let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NestError("Cannot reserve source retirement fence; source retained.", code: 6) }
            defer { close(fd) }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count-offset)
                    guard n > 0 else { throw NestError("Retirement fence write failed. Keep both stores and retry recovery.", code: 6) }; offset += n
                }
            }
            guard fsync(fd) == 0 else { throw NestError("Retirement fence sync failed; recovery is required.", code: 6) }
            try directory.sync()
        }
    }
}

extension StorageRelocation {
    static func make(_ manager: SnapshotStorageManager) -> Transaction { Transaction(manager: manager) }
}

extension StorageRelocation.Transaction {
    typealias Item = StorageRelocation.Item
    typealias Root = StorageRelocation.Root
    typealias Receipt = StorageRelocation.Receipt
    func writableLocal(_ handle: DirectoryHandle) throws {
        var fs = statfs()
        guard fstatfs(handle.fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0, fs.f_flags & UInt32(MNT_RDONLY) == 0 else {
            throw NestError("Choose writable local storage; network and read-only filesystems are unsupported.", code: 4)
        }
    }
    func parent(_ root: DirectoryHandle, path: String, inventory: [String: Item]? = nil) throws -> (DirectoryHandle, String) {
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last else { throw NestError("Invalid storage entry.", code: 6) }
        var result = root, prefix: [String] = []
        for part in components.dropLast() {
            prefix.append(part); result = try result.child(part)
            if let inventory {
                guard let recorded = inventory[prefix.joined(separator: "/")],
                      try result.identity() == (recorded.device, recorded.inode) else { throw NestError("Storage ancestor changed; ambiguous entries retained.", code: 6) }
            }
        }
        return (result, last)
    }
    func scan(_ root: Root, excluding: Set<String>, cancellation: StorageMoveCancellation = .init(), matching: [Item]? = nil) throws -> [Item] {
        let handle = try root.open(); try writableLocal(handle)
        var fs = statfs(); guard fstatfs(handle.fd, &fs) == 0 else { throw NestError("Cannot inspect storage filesystem.", code: 6) }
        var pending = try handle.names().filter { !excluding.contains($0) }
        var result: [Item] = []
        let recorded = Dictionary(uniqueKeysWithValues: (matching ?? []).map { ($0.path, $0) })
        var policies: [String: FileVerification] = [:]
        while let path = pending.popLast() {
            try cancellation.check()
            guard result.count < 100_000 else { throw NestError("Storage inventory exceeds safe entry bound; source retained.", code: 6) }
            let (directory, name) = try parent(handle, path: path)
            var policy = recorded[path]?.fileVerification ?? .sha256
            let components = path.split(separator: "/").map(String.init)
            if matching == nil, components.count >= 6, components[0] == "volumes", UUID(uuidString: components[1]) != nil,
               components[2] == "revisions", UUID(uuidString: components[3]) != nil, components[4] == "data" {
                let key = components.prefix(4).joined(separator: "/")
                if policies[key] == nil {
                    let (container, leaf) = try parent(handle, path: key + "/manifest.json")
                    let metadata = try container.readJSON(StoredManifest.self, leaf)
                    policies[key] = metadata.fileVerification
                }
                policy = policies[key]!
            }
            let item = try inspect(directory, name: name, relative: path, device: root.device, cancellation: cancellation, verification: policy)
            result.append(item)
            if item.kind == UInt16(S_IFDIR) {
                let child = try directory.child(name)
                var childFS = statfs()
                guard fstatfs(child.fd, &childFS) == 0, childFS.f_fsid.val.0 == fs.f_fsid.val.0,
                      childFS.f_fsid.val.1 == fs.f_fsid.val.1,
                      !Paths.mounts().contains(where: { $0.path == URL(fileURLWithPath: root.path).appendingPathComponent(path).path }) else {
                    throw NestError("Nested or foreign mount blocks snapshot storage relocation.", code: 4)
                }
                pending += try child.names().map { path + "/" + $0 }
            }
        }
        _ = try root.open()
        return result.sorted { $0.path < $1.path }
    }
    func inspect(_ parent: DirectoryHandle, name: String, relative: String, device: UInt64,
                 cancellation: StorageMoveCancellation = .init(), verification: FileVerification = .sha256) throws -> Item {
        let st = try parent.entryStat(name), kind = st.st_mode & S_IFMT
        guard verification == .sha256 || kind != S_IFREG || Item.revisionPayload(relative) else { throw NestError("Control storage files require SHA verification; retained.", code: 6) }
        guard Paths.deviceID(st.st_dev) == device, st.st_uid == getuid(),
              [S_IFDIR, S_IFREG, S_IFLNK].contains(kind),
              kind == S_IFDIR || st.st_nlink == 1,
              st.st_flags & ~UInt32(UF_HIDDEN | UF_NODUMP) == 0 else {
            throw NestError("Unsupported owner, hard link, compression/flags or special entry in opaque store: \(relative). No source attributes were changed.", code: 6)
        }
        let fd = openat(parent.fd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (kind == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
        guard fd >= 0 else { throw NestError("Cannot open opaque storage entry: \(relative). Source retained.", code: 6) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else { throw NestError("Storage entry changed during inspection.", code: 6) }
        let count = flistxattr(fd, nil, 0, XATTR_SHOWCOMPRESSION)
        guard count >= 0, count <= 1 << 20 else { throw NestError("Cannot enumerate complete physical xattrs: \(relative).", code: 6) }
        var names = [CChar](repeating: 0, count: max(1, count))
        guard flistxattr(fd, &names, count, XATTR_SHOWCOMPRESSION) == count else { throw NestError("Storage xattrs changed while reading.", code: 6) }
        var attributes: [String: Data] = [:]
        for bytes in names.prefix(count).split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = fgetxattr(fd, name, nil, 0, 0, XATTR_SHOWCOMPRESSION)
            guard size >= 0, size <= 16 << 20 else { throw NestError("Cannot read complete physical xattr metadata.", code: 6) }
            var data = Data(count: size)
            guard data.withUnsafeMutableBytes({ fgetxattr(fd, name, $0.baseAddress, size, 0, XATTR_SHOWCOMPRESSION) }) == size else { throw NestError("Physical xattr changed during inspection.", code: 6) }
            attributes[name] = data
        }
        let acl: String
        var parentPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parent.fd, F_GETPATH, &parentPath) == 0 else { throw NestError("Cannot establish anchored ACL path.", code: 6) }
        let parentPathString = String(decoding: parentPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let aclPath = URL(fileURLWithPath: parentPathString).appendingPathComponent(name).path
        errno = 0
        let aclValue = kind == S_IFLNK ? acl_get_link_np(aclPath, ACL_TYPE_EXTENDED) : acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        if let value = aclValue {
            defer { acl_free(UnsafeMutableRawPointer(value)) }
            var length = 0
            guard let bytes = acl_to_text(value, &length) else { throw NestError("Cannot read opaque storage ACL.", code: 6) }
            defer { acl_free(bytes) }
            acl = String(cString: bytes)
        } else if errno == ENOENT || errno == ENOTSUP { acl = "" }
        else { throw NestError("Cannot establish opaque storage ACL; source retained.", code: 6) }
        var digest: String?, link: Data?
        if kind == S_IFREG && verification == .sha256 {
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1 << 20), total: Int64 = 0
            while true {
                try cancellation.check()
                let n = Darwin.read(fd, &buffer, buffer.count)
                guard n >= 0 else { throw NestError("Storage file read failed.", code: 6) }
                if n == 0 { break }
                hash.update(data: Data(buffer.prefix(n))); total += Int64(n)
            }
            guard total == st.st_size else { throw NestError("Storage file size changed while hashing.", code: 6) }
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        } else if kind == S_IFLNK {
            var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN) + 1)
            let n = readlinkat(parent.fd, name, &bytes, bytes.count)
            guard n >= 0, n < bytes.count else { throw NestError("Cannot read stored symlink.", code: 6) }
            link = Data(bytes.prefix(n))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_dev == st.st_dev, after.st_ino == st.st_ino,
              after.st_size == st.st_size, after.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == st.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == st.st_ctimespec.tv_nsec else { throw NestError("Storage entry changed during hashing.", code: 6) }
        let named = try parent.entryStat(name)
        guard named.st_dev == st.st_dev, named.st_ino == st.st_ino else { throw NestError("Named storage entry was replaced during inspection.", code: 6) }
        return Item(path: relative, device: device, inode: UInt64(st.st_ino), kind: UInt16(kind), mode: UInt16(st.st_mode & 0o7777),
            uid: st.st_uid, gid: st.st_gid, flags: st.st_flags, size: st.st_size,
            modifiedSeconds: Int64(st.st_mtimespec.tv_sec), modifiedNanos: Int64(st.st_mtimespec.tv_nsec),
            attributes: attributes, acl: acl, digest: digest, link: link, fileVerification: kind == S_IFREG && verification != .sha256 ? verification : nil)
    }
    func copy(_ receipt: inout Receipt, cancellation: StorageMoveCancellation) throws {
        let source = try receipt.source.open(), destination = try receipt.destination.open()
        let expected = Dictionary(uniqueKeysWithValues: receipt.inventory.map { ($0.path, $0) })
        if let partial = receipt.partialFile {
            let handle = try partial.parent.open()
            guard partial.parent.path.hasPrefix(receipt.destination.path + "/") || partial.parent.path == receipt.destination.path,
                  partial.temporary.hasPrefix(".ramnest-move-") else { throw NestError("Interrupted allocation has no proven identity; retain both stores for manual recovery.", code: 6) }
            if try handle.exists(partial.temporary) {
                let st = try handle.entryStat(partial.temporary)
                guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
                      Paths.deviceID(st.st_dev) == partial.device, UInt64(st.st_ino) == partial.inode else { throw NestError("Interrupted copy file changed; preserve it for manual recovery.", code: 6) }
                guard unlinkat(handle.fd, partial.temporary, 0) == 0 else { throw NestError("Cannot retire recorded incomplete copy; Retry.", code: 6) }
                try checkpoint("partial-copy-unlinked")
                try handle.sync()
            } else if partial.inode != 0 {
                let (p, name) = try parent(destination, path: partial.finalPath)
                guard try p.identity() == (partial.parent.device, partial.parent.inode) else { throw NestError("Interrupted copy parent changed; both stores retained.", code: 6) }
                if try p.exists(name) {
                    guard let original = expected[partial.finalPath] else { throw NestError("Unknown interrupted copy; retained.", code: 6) }
                    let found = try inspect(p, name: name, relative: partial.finalPath, device: receipt.destination.device, verification: original.fileVerification ?? .sha256)
                    guard found.device == partial.device, found.inode == partial.inode, original.sameCopyContent(found), (partial.attributes == nil ? original.attributes == found.attributes : partial.attributes == found.attributes) else { throw NestError("Interrupted publication is not proven; retain both stores.", code: 6) }
                    receipt.allocations[partial.finalPath] = StorageRelocation.Allocation(device: found.device, inode: found.inode, kind: found.kind, attributes: found.attributes)
                } else {
                    // Unlink may have succeeded before sync/receipt ACK failed.
                    // Both names absent under the recorded parent permits retry,
                    // not adoption or deletion of any unknown object.
                    try p.sync()
                }
            }
            receipt.partialFile = nil; try write(receipt)
        }
        let existing = try scan(receipt.destination, excluding: [StorageRelocation.incomingName, SnapshotCopyObservations.name], matching: receipt.inventory)
        for item in existing {
            guard let original = expected[item.path], ownedCopies(receipt, [item]),
                  item.kind == UInt16(S_IFDIR) || (receipt.allocations[item.path]?.attributes == nil ? original.sameContent(item, directoryTimes: false) : original.sameCopyContent(item, directoryTimes: false)) else { throw NestError("Partial destination contains an unproven entry: \(item.path). Preserve it and source; automatic overwrite is refused.", code: 6) }
        }
        let present = Set(existing.map(\.path))
        for item in receipt.inventory.sorted(by: { a, b in
            let da = a.path.split(separator: "/").count, db = b.path.split(separator: "/").count
            return da == db ? a.path < b.path : da < db
        }) {
            try cancellation.check()
            if present.contains(item.path) { continue }
            _ = try receipt.source.open(); _ = try receipt.destination.open()
            let (srcParent, name) = try parent(source, path: item.path, inventory: expected)
            let (dstParent, dstName) = try parent(destination, path: item.path)
            guard try !dstParent.exists(dstName) else { throw NestError("Destination changed during copy; both stores retained.", code: 6) }
            if item.kind == UInt16(S_IFDIR) {
                let created = try dstParent.createDirectory(dstName), identity = try created.identity()
                receipt.allocations[item.path] = StorageRelocation.Allocation(device: identity.device, inode: identity.inode, kind: item.kind)
                try dstParent.sync(); try write(receipt); continue
            }
            if item.kind == UInt16(S_IFLNK) {
                // copyfile's NOFOLLOW flags preserve the link itself. Both
                // parent chains are pinned and rechecked around the operation.
                let src = URL(fileURLWithPath: receipt.source.path).appendingPathComponent(item.path)
                let dst = URL(fileURLWithPath: receipt.destination.path).appendingPathComponent(item.path)
                guard copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST | COPYFILE_EXCL)) == 0 else { throw NestError("Cannot preserve stored symlink metadata; both stores retained.", code: 6) }
                let allocated = try inspect(dstParent, name: dstName, relative: item.path, device: receipt.destination.device, verification: item.fileVerification ?? .sha256)
                guard item.sameCopyContent(allocated) else { throw NestError("Stored symlink copy differs; both stores retained.", code: 6) }
                receipt.allocations[item.path] = StorageRelocation.Allocation(device: allocated.device, inode: allocated.inode, kind: item.kind, attributes: allocated.attributes)
                try dstParent.sync(); try write(receipt)
            } else {
                let input = openat(srcParent.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard input >= 0 else { throw NestError("Cannot open storage source file.", code: 6) }
                defer { close(input) }
                let temporary = ".ramnest-move-" + UUID().uuidString
                let parentURL = URL(fileURLWithPath: receipt.destination.path).appendingPathComponent(item.path).deletingLastPathComponent()
                receipt.partialFile = StorageRelocation.PartialFile(parent: try Root(parentURL), temporary: temporary, finalPath: item.path, device: receipt.destination.device, inode: 0)
                try write(receipt)
                let output = openat(dstParent.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw NestError("Cannot reserve storage destination file.", code: 6) }
                defer { close(output) }
                var allocated = stat()
                guard fstat(output, &allocated) == 0 else { throw NestError("Cannot record private copy identity.", code: 6) }
                receipt.partialFile?.inode = UInt64(allocated.st_ino); receipt.partialFile?.device = Paths.deviceID(allocated.st_dev)
                try dstParent.sync(); try write(receipt)
                try checkpoint("copy-file")
                var buffer = [UInt8](repeating: 0, count: 1 << 20)
                while true {
                    try cancellation.check()
                    let n = Darwin.read(input, &buffer, buffer.count)
                    guard n >= 0 else { throw NestError("Storage copy read failed.", code: 6) }
                    if n == 0 { break }
                    try buffer.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < n {
                            let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), n-offset)
                            guard written > 0 else { throw NestError("Storage copy write failed.", code: 6) }; offset += written
                        }
                    }
                }
                try metadata(from: input, to: output, item: item)
                guard fsync(output) == 0 else { throw NestError("Cannot sync complete storage metadata; both stores retained.", code: 6) }
                let copied = try inspect(dstParent, name: temporary, relative: item.path, device: receipt.destination.device, cancellation: cancellation, verification: item.fileVerification ?? .sha256)
                guard item.sameCopyContent(copied) else { throw NestError("Storage file readback failed; recorded partial copy retained for Retry.", code: 6) }
                receipt.partialFile?.attributes = copied.attributes; try write(receipt)
                try dstParent.renameNoReplace(temporary, to: dstParent, as: dstName); try dstParent.sync()
                receipt.allocations[item.path] = StorageRelocation.Allocation(device: copied.device, inode: copied.inode, kind: copied.kind, attributes: copied.attributes)
                receipt.partialFile = nil; try write(receipt)
            }
            try dstParent.sync()
        }
        // Creating children changes directory timestamps. Finalize metadata only
        // after descendants; this never chmods the source.
        for item in receipt.inventory.reversed() where item.kind == UInt16(S_IFDIR) {
            let (sp, name) = try parent(source, path: item.path, inventory: expected)
            let (dp, dn) = try parent(destination, path: item.path)
            let src = try sp.child(name), dst = try dp.child(dn)
            try metadata(from: src.fd, to: dst.fd, item: item)
            try dst.sync()
        }
        try metadata(from: source.fd, to: destination.fd, item: receipt.rootMetadata)
        try destination.sync()
    }
    func verifyCopyObservation(_ receipt: Receipt) throws {
        let destination = try receipt.destination.open()
        if let own = receipt.destinationObservation {
            guard try inspect(destination, name: SnapshotCopyObservations.name, relative: SnapshotCopyObservations.name, device: receipt.destination.device) == own else { throw NestError("Destination copy observations changed; obsolete payload retained.", code: 6) }
        } else if try destination.exists(SnapshotCopyObservations.name) {
            throw NestError("Unknown destination copy observations; both stores retained.", code: 6)
        }
    }
    func installCopyObservations(_ receipt: inout Receipt) throws {
        if receipt.destinationObservation != nil { try verifyCopyObservation(receipt); return }
        let destination = try receipt.destination.open()
        guard try !destination.exists(SnapshotCopyObservations.name) else { throw NestError("Unacknowledged copy observations retained; preserve both stores for recovery.", code: 6) }
        let sourceRoot = URL(fileURLWithPath: receipt.source.path)
        let destinationRoot = URL(fileURLWithPath: receipt.destination.path)
        let previous = try SnapshotCopyObservations.read(sourceRoot)
        var records: [String: SnapshotCopyObservations.Record] = [:]
        for item in receipt.inventory where item.path.hasSuffix("/manifest.json") {
            let parts = item.path.split(separator: "/").map(String.init)
            guard parts.count == 5, parts[0] == "volumes", UUID(uuidString: parts[1]) != nil,
                  parts[2] == "revisions", UUID(uuidString: parts[3]) != nil else { continue }
            let relative = parts.dropLast().joined(separator: "/") + "/data"
            let source = sourceRoot.appendingPathComponent(relative), target = destinationRoot.appendingPathComponent(relative)
            guard let metadata = try Snapshot.storedMetadata(source) else { throw NestError("Missing source revision metadata; source retained.", code: 6) }
            let expected = try metadata.logical.excludingTrashDirectories()
            let sourceObserved = try Snapshot.manifest(source, matching: expected, context: .managedRevision)
            guard sourceObserved.matchesExpected(expected) else { throw NestError("Source revision is damaged; both stores retained.", code: 6) }
            let sourceContainer = try DirectoryHandle.open(source.deletingLastPathComponent())
            guard try sourceContainer.names() == (metadata.storageFormat == 2 ? ["data", "manifest.json", "modes.bin"] : ["data", "manifest.json"]) else { throw NestError("Unknown source revision namespace; both stores retained.", code: 6) }
            let observed = try Snapshot.manifest(target, matching: expected, context: .managedRevision)
            guard try observed.matchesCopy(of: sourceObserved) else { throw NestError("Relocated revision differs beyond provenance; both stores retained.", code: 6) }
            let key = parts[1] + "/" + parts[3]
            records[key] = SnapshotCopyObservations.Record(manifestDigest: Snapshot.digest(try Snapshot.manifestFileBytes(sourceContainer)),
                modeMapDigest: metadata.modeMapDigest, basis: previous?.revisions[key]?.basis ?? sourceObserved, observed: observed)
        }
        let observations = SnapshotCopyObservations(device: receipt.destination.device, inode: receipt.destination.inode, revisions: records)
        try exclusiveJSON(observations, directory: destination, name: SnapshotCopyObservations.name)
        try destination.sync()
        receipt.destinationObservation = try inspect(destination, name: SnapshotCopyObservations.name, relative: SnapshotCopyObservations.name, device: receipt.destination.device)
        try write(receipt)
        // Prove moved revisions remain usable through their ordinary managed
        // metadata path before publishing selection or retiring one source file.
        for key in records.keys {
            let parts = key.split(separator: "/")
            let target = destinationRoot.appendingPathComponent("volumes/\(parts[0])/revisions/\(parts[1])/data")
            guard let metadata = try Snapshot.storedMetadata(target),
                  try Snapshot.manifest(target, context: .managedRevision).matchesExpected(metadata.logical.excludingTrashDirectories()) else { throw NestError("Relocated revision verification failed; both stores retained.", code: 6) }
        }
    }
    func metadata(from source: Int32, to destination: Int32, item: Item) throws {
        guard fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw NestError("Cannot preserve opaque metadata at \(item.path); source retained.", code: 6) }
        // Darwin's quarantine copy API may normalize bytes. Replay authenticated
        // source bytes into the newly allocated private destination only.
        for (name, bytes) in item.attributes where name != Snapshot.provenanceName {
            let count = fgetxattr(destination, name, nil, 0, 0, XATTR_SHOWCOMPRESSION)
            if count == bytes.count {
                var current = Data(count: count)
                if current.withUnsafeMutableBytes({ fgetxattr(destination, name, $0.baseAddress, count, 0, XATTR_SHOWCOMPRESSION) }) == count && current == bytes { continue }
            }
            let mode = mode_t(item.mode)
            let temporaryWrite = mode & 0o200 == 0
            if temporaryWrite, fchmod(destination, mode | 0o200) != 0 { throw NestError("Cannot finish owned copy metadata; source retained.", code: 6) }
            let result = bytes.withUnsafeBytes { fsetxattr(destination, name, $0.baseAddress, bytes.count, 0, 0) }
            let restored = !temporaryWrite || fchmod(destination, mode) == 0
            guard result == 0, restored else { throw NestError("Exact metadata preservation was denied at \(item.path); source retained without attribute changes.", code: 6) }
        }
    }
    func retire(_ receipt: Receipt) throws {
        let source = try receipt.source.open(), destination = try receipt.destination.open()
        let fence = StorageRelocation.Fence(transaction: receipt.transaction, bootstrap: receipt.bootstrap.path, destination: receipt.destination.path)
        try durableFence(fence, directory: source, name: StorageRelocation.fenceName)
        if try destination.exists(StorageRelocation.incomingName) {
            try durableFence(fence, directory: destination, name: StorageRelocation.incomingName)
        }
        var locks = [try lock(destination, "repository.lock", nonblocking: true)]
        defer { release(locks) }
        let destinationVolumes = try destination.child("volumes")
        try destinationVolumes.requireOwnedDirectory(device: receipt.destination.device, privateMode: true)
        for name in try destinationVolumes.names() {
            let volume = try destinationVolumes.child(name)
            try volume.requireOwnedDirectory(device: receipt.destination.device, privateMode: true)
            locks.append(try lock(volume, "transaction.lock", nonblocking: true))
        }
        let expected = Dictionary(uniqueKeysWithValues: receipt.inventory.map { ($0.path, $0) })
        let remaining = try scan(receipt.source, excluding: excluded(receipt.source).union([StorageRelocation.fenceName]), matching: receipt.inventory)
        let copied = Dictionary(uniqueKeysWithValues: try scan(receipt.destination, excluding: ["repository.lock", StorageRelocation.incomingName, SnapshotCopyObservations.name], matching: receipt.inventory).map { ($0.path, $0) })
        if let recorded = receipt.sourceObservation {
            if try source.exists(SnapshotCopyObservations.name) {
                guard try inspect(source, name: SnapshotCopyObservations.name, relative: SnapshotCopyObservations.name, device: receipt.source.device) == recorded else { throw NestError("Obsolete copy observation changed; retained.", code: 6) }
            } else if !remaining.isEmpty { throw NestError("Source copy observation disappeared before payload retirement; retained.", code: 6) }
        }

        guard destinationMatches(receipt, copied.values.sorted { $0.path < $1.path }),
              ownedCopies(receipt, Array(copied.values)), try rootMatches(receipt, root: receipt.source) else { throw NestError("Selected copy or original root changed; obsolete source retained.", code: 6) }
        let ownDestination = Dictionary(uniqueKeysWithValues: (receipt.destinationInventory ?? receipt.inventory).map { ($0.path, $0) })
        try verifyCopyObservation(receipt)
        for item in remaining {
            guard let original = expected[item.path], original.device == item.device, original.inode == item.inode,
                  original.sameContent(item, directoryTimes: false),
                  let target = copied[item.path], let own = ownDestination[item.path], own.sameContent(target) else { throw NestError("Cleanup verification changed at \(item.path). Selected storage is retained; Retry after restoring access. No ambiguous data was removed.", code: 6) }
        }
        guard try rootMatches(receipt, root: receipt.destination) else { throw NestError("Selected store root metadata changed; obsolete data retained.", code: 6) }
        for item in remaining.sorted(by: { a, b in
            let da = a.path.split(separator: "/").count, db = b.path.split(separator: "/").count
            return da == db ? a.path > b.path : da > db
        }) {
            _ = try receipt.source.open(); _ = try receipt.destination.open()
            let (directory, name) = try parent(source, path: item.path, inventory: expected)
            let st = try directory.entryStat(name)
            guard Paths.deviceID(st.st_dev) == item.device, UInt64(st.st_ino) == item.inode, UInt16(st.st_mode & S_IFMT) == item.kind else { throw NestError("Cleanup entry changed; pending cleanup retained.", code: 6) }
            if item.kind != UInt16(S_IFDIR) {
                let current = try inspect(directory, name: name, relative: item.path, device: receipt.source.device, verification: item.fileVerification ?? .sha256)
                guard current.sameContent(item) else { throw NestError("Cleanup file changed; retained.", code: 6) }
                let (targetParent, targetName) = try parent(destination, path: item.path, inventory: copied)
                guard let own = ownDestination[item.path], try inspect(targetParent, name: targetName, relative: item.path, device: receipt.destination.device, verification: item.fileVerification ?? .sha256).sameContent(own) else { throw NestError("Selected copy changed before retirement; obsolete data retained.", code: 6) }
            }
            try checkpoint("cleanup-entry")
            guard unlinkat(directory.fd, name, item.kind == UInt16(S_IFDIR) ? AT_REMOVEDIR : 0) == 0 else { throw NestError("Storage selected, but obsolete payload cleanup needs Retry: \(String(cString: strerror(errno))).", code: 6) }
            try directory.sync()
        }
        if let recorded = receipt.sourceObservation, try source.exists(SnapshotCopyObservations.name) {
            guard try inspect(source, name: SnapshotCopyObservations.name, relative: SnapshotCopyObservations.name, device: receipt.source.device) == recorded,
                  unlinkat(source.fd, SnapshotCopyObservations.name, 0) == 0 else { throw NestError("Obsolete copy observation cleanup needs Retry.", code: 6) }
            try source.sync()
        }
        guard try source.names().allSatisfy({ excluded(receipt.source).union([StorageRelocation.fenceName]).contains($0) }) else { throw NestError("Unknown source entries retained; cleanup requires review.", code: 6) }
        if try destination.exists(StorageRelocation.incomingName) {
            guard unlinkat(destination.fd, StorageRelocation.incomingName, 0) == 0 else { throw NestError("Destination cleanup fence removal needs Retry.", code: 6) }
            try destination.sync()
        }
    }
}
