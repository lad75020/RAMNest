import Foundation
import Darwin

public final class Store: @unchecked Sendable {
    var beforeJournalWrite: ((Journal, UUID) throws -> Void)?
    // Internal fixture injection only; no environment or public API override.
    var fsKitFixtureRoot: URL?
    var journalDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        if let root = fsKitFixtureRoot { decoder.userInfo[FSKitLinkLayout.decoderRootKey] = root }
        return decoder
    }
    public let root: URL
    private let rootIdentity: (device: UInt64, inode: UInt64)
    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RAMNest", isDirectory: true) }
    public init(root: URL = Store.defaultRoot) throws {
        self.root = root.standardizedFileURL
        try Paths.rejectSymlinks(self.root.path, allowMissingLast: true)
        try Self.privateDirectory(self.root)
        try Self.privateDirectory(self.root.appendingPathComponent("volumes"))
        rootIdentity = try DirectoryHandle.open(self.root).identity()
    }
    // Cleanup must stay inside the same owned repository, even if its pathname
    // was replaced after this Store was opened. Never create paths during cleanup.
    func managedVolume(_ id: UUID) throws -> DirectoryHandle {
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
        let path = root.appendingPathComponent("repository.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NestError("Cannot open repository lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NestError("Cannot lock repository.") }
        defer { flock(fd, LOCK_UN) }
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
        return try operation()
    }
    public func load() throws -> Configuration {
        let url = root.appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let config = try Self.read(Configuration.self, url)
        guard config.version == 1 else { throw NestError("Unsupported configuration version.") }
        return config
    }
    public func save(_ config: Configuration) throws { try Self.atomicJSON(config, root.appendingPathComponent("configuration.json")) }
    public func volume(_ id: UUID) throws -> URL {
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
        try Self.atomicJSON(j, volume(id).appendingPathComponent("journal.json"))
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
