import Foundation
import Darwin

/// Every recovery mutation is relative to an opened, no-follow directory chain.
/// Renaming a path after it is checked cannot redirect these descriptors elsewhere.
public final class DirectoryHandle: @unchecked Sendable {
    public let fd: Int32
    public init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }
    public static func open(_ url: URL) throws -> DirectoryHandle {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NestError("Cannot open filesystem root.", code: 4) }
        for part in url.standardizedFileURL.pathComponents where part != "/" {
            let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { throw NestError("Path is missing, changed, or traverses a symlink: \(url.path)", code: 4) }
            descriptor = next
        }
        return DirectoryHandle(fd: descriptor)
    }
    public func identity() throws -> (device: UInt64, inode: UInt64) {
        var st = stat(); guard fstat(fd, &st) == 0 else { throw NestError("Cannot inspect directory handle.", code: 4) }
        return (Paths.deviceID(st.st_dev), UInt64(st.st_ino))
    }
    public func verify(_ folder: Folder) throws {
        let actual = try identity()
        guard actual.device == folder.device && actual.inode == folder.inode else { throw NestError("Selected directory identity changed. Recovery is blocked.", code: 4) }
    }
    public func child(_ name: String) throws -> DirectoryHandle {
        try Self.checkName(name)
        let result = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard result >= 0 else { throw NestError("Cannot open child directory: \(name)", code: 4) }
        return DirectoryHandle(fd: result)
    }
    public func parent(of relative: String) throws -> (DirectoryHandle, String) {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else { throw NestError("Invalid relative path.", code: 4) }
        var current = DirectoryHandle(fd: dup(fd))
        for part in parts.dropLast() { current = try current.child(part) }
        try Self.checkName(last); return (current, last)
    }
    public func createDirectory(_ name: String) throws -> DirectoryHandle {
        try Self.checkName(name)
        guard mkdirat(fd, name, 0o700) == 0 else { throw NestError("Cannot create new private directory: \(name)", code: 6) }
        return try child(name)
    }
    public func renameNoReplace(_ name: String, to destination: DirectoryHandle, as newName: String) throws {
        try Self.checkName(name); try Self.checkName(newName)
        guard renameatx_np(fd, name, destination.fd, newName, UInt32(RENAME_EXCL)) == 0 else { throw NestError("Recovery move failed or conflicts with a new entry: \(newName): \(String(cString: strerror(errno)))", code: 6) }
    }
    public func exists(_ name: String) throws -> Bool {
        try Self.checkName(name); var st = stat()
        if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw NestError("Cannot inspect recovery entry.", code: 6) }; return false
    }
    public func names() throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; throw NestError("Cannot enumerate anchored directory.", code: 6) }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(cString: $0) } }
            if name != "." && name != ".." { result.append(name) }
        }
        guard errno == 0 else { throw NestError("Directory enumeration failed.", code: 6) }
        return result.sorted()
    }
    public func sync() throws { guard fsync(fd) == 0 else { throw NestError("Directory sync failed.", code: 6) } }
    func requireOwnedDirectory(device: UInt64, privateMode: Bool = false) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_uid == getuid(), Paths.deviceID(st.st_dev) == device,
              !privateMode || st.st_mode & 0o077 == 0 else {
            throw NestError("Snapshot cleanup requires an owned directory on the repository device.", code: 4)
        }
    }
    func entryStat(_ name: String) throws -> stat {
        try Self.checkName(name)
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw NestError("Cannot inspect snapshot cleanup entry: \(name)", code: 6) }
        return st
    }
    func readJSON<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Self.checkName(name)
        let descriptor = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NestError("Cannot read managed snapshot metadata: \(name)", code: 6) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var st = stat()
        guard fstat(descriptor, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_uid == getuid(), st.st_size >= 0, st.st_size <= 64 << 20 else {
            throw NestError("Unexpected managed snapshot metadata: \(name)", code: 6)
        }
        return try JSONDecoder().decode(type, from: handle.readToEnd() ?? Data())
    }
    // Preflight the entire candidate before unlinking anything. The expected
    // namespace comes from its committed manifest; unknown entries are retained.
    // All traversal/unlinking is anchored, no-follow, same-device and same-fsid.
    func removeCommittedRevision(_ name: String) throws {
        let candidate = try entryStat(name)
        let revision = try child(name)
        let device = try identity().device
        try revision.requireOwnedDirectory(device: device, privateMode: true)
        guard try revision.identity().inode == UInt64(candidate.st_ino) else { throw NestError("Revision identity changed; cleanup skipped.", code: 6) }
        let metadata = try revision.readJSON(StoredManifest.self, "manifest.json")
        guard try revision.names() == (metadata.storageFormat == 2 ? ["data", "manifest.json", "modes.bin"] : ["data", "manifest.json"]) else { throw NestError("Unexpected revision contents; snapshot retained.", code: 6) }
        let manifest = metadata.logical
        if metadata.storageFormat == 2 {
            let descriptor = openat(revision.fd,"modes.bin",O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw NestError("Missing cleanup storage mode map.", code: 6) };defer { close(descriptor) }
            var st = stat()
            guard fstat(descriptor,&st) == 0, st.st_uid == getuid(), st.st_gid == getgid(), st.st_mode & S_IFMT == S_IFREG,
                  st.st_mode & 0o7777 == 0o600, st.st_nlink == 1, st.st_size >= 0, st.st_size <= StorageModes.maximumBytes else { throw NestError("Invalid cleanup storage mode map.", code: 6) }
            let bytes = try FileHandle(fileDescriptor:descriptor,closeOnDealloc:false).readToEnd() ?? Data()
            let modes = try StorageModes(data:bytes)
            guard Snapshot.digest(bytes) == metadata.modeMapDigest, modes.records == (try StorageModes(manifest)).records else { throw NestError("Cleanup storage mode map integrity mismatch.", code: 6) }
        }
        var expected: [String: Entry] = [:]
        for entry in manifest.entries {
            guard expected.updateValue(entry, forKey: entry.path) == nil,
                  ["directory", "file", "symlink"].contains(entry.kind) else { throw NestError("Invalid old manifest; snapshot retained.", code: 6) }
        }
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw NestError("Cannot inspect cleanup filesystem.", code: 6) }
        struct Removal {
            // Store paths, not open handles: a wide tree must not retain one
            // descriptor per subdirectory until deletion starts.
            let parentPath: [String]?
            let name: String
            let info: stat
        }
        var removals: [Removal] = []
        var seen = Set<String>()
        var directoryIdentities: [String: (device: UInt64, inode: UInt64)] = [:]
        struct Inspection {let childName: String; let relative: String?; let parentPath: [String]; let finish: Bool; let info: stat?}
        var pending = [Inspection(childName: "data", relative: nil, parentPath: [], finish: false, info: nil)]
        while let task = pending.popLast() {
            let childName = task.childName, relative = task.relative, parentPath = task.parentPath
            if task.finish { removals.append(Removal(parentPath: parentPath, name: childName, info: task.info!)); continue }
            var parent = revision
            var prefix: [String] = []
            for part in parentPath {
                prefix.append(part); parent = try parent.child(part)
                guard let expected = directoryIdentities[prefix.joined(separator: "/")], try parent.identity() == expected else { throw NestError("Snapshot ancestor changed; retained.", code: 6) }
            }
            let st = try parent.entryStat(childName)
            let kind = st.st_mode & S_IFMT
            if relative != nil && SnapshotExclusion.directory(childName,st.st_mode) {
                throw NestError("Old snapshot contains excluded disk Trash; revision retained without subtree access.",code:6)
            }
            guard relative != nil || kind == S_IFDIR else { throw NestError("Unexpected snapshot data root; snapshot retained.", code: 6) }
            guard st.st_uid == getuid(), Paths.deviceID(st.st_dev) == device,
                  st.st_flags & ~UInt32(UF_HIDDEN | UF_NODUMP | UF_COMPRESSED) == 0 else { throw NestError("Unsafe snapshot cleanup entry; snapshot retained.", code: 6) }
            if let relative {
                guard let e = expected[relative], seen.insert(relative).inserted,
                      (kind == S_IFDIR && e.kind == "directory") || (kind == S_IFREG && e.kind == "file" && st.st_size == e.size) || (kind == S_IFLNK && e.kind == "symlink" && st.st_size == e.size) else {
                    throw NestError("Old snapshot namespace changed; snapshot retained.", code: 6)
                }
                if metadata.storageFormat == 2 {
                    let policy: UInt16 = kind == S_IFREG ? 0o600 : 0o700
                    guard st.st_mode & 0o7777 == policy else { throw NestError("Cleanup private physical mode drift; retained.", code: 6) }
                }
            } else if metadata.storageFormat == 2 {
                guard st.st_mode & 0o7777 == 0o700 else { throw NestError("Cleanup private root mode drift; retained.", code: 6) }
            }
            if kind == S_IFDIR {
                let child = try parent.child(childName)
                try child.requireOwnedDirectory(device: device)
                let opened = try child.identity()
                var childFS = statfs()
                guard opened.inode == UInt64(st.st_ino), fstatfs(child.fd, &childFS) == 0,
                      childFS.f_fsid.val.0 == filesystem.f_fsid.val.0,
                      childFS.f_fsid.val.1 == filesystem.f_fsid.val.1 else { throw NestError("Snapshot cleanup crossed a mount or changed directory.", code: 6) }
                let path = parentPath + [childName]
                directoryIdentities[path.joined(separator: "/")] = opened
                pending.append(Inspection(childName: childName, relative: relative, parentPath: parentPath, finish: true, info: st))
                for part in try child.names().reversed() { pending.append(Inspection(childName: part, relative: relative.map { $0 + "/" + part } ?? part, parentPath: path, finish: false, info: nil)) }
                continue
            } else {
                guard kind == S_IFREG || kind == S_IFLNK else { throw NestError("Unexpected snapshot entry type.", code: 6) }
            }
            removals.append(Removal(parentPath: parentPath, name: childName, info: st))
        }
        guard seen == Set(expected.keys) else { throw NestError("Old snapshot entries are missing; snapshot retained.", code: 6) }
        let manifestStat = try revision.entryStat("manifest.json")
        guard manifestStat.st_mode & S_IFMT == S_IFREG, Paths.deviceID(manifestStat.st_dev) == device,
              manifestStat.st_flags & ~UInt32(UF_HIDDEN | UF_NODUMP) == 0 else { throw NestError("Unsafe old manifest; snapshot retained.", code: 6) }
        if metadata.storageFormat == 2 {
            guard manifestStat.st_mode & 0o7777 == 0o600, manifestStat.st_uid == getuid(), manifestStat.st_gid == getgid(), manifestStat.st_nlink == 1 else { throw NestError("Cleanup private manifest policy drift; retained.", code: 6) }
        }
        removals.append(Removal(parentPath: [], name: "manifest.json", info: manifestStat))
        if metadata.storageFormat == 2 { removals.append(Removal(parentPath:[],name:"modes.bin",info:try revision.entryStat("modes.bin"))) }
        removals.append(Removal(parentPath: nil, name: name, info: candidate))
        func reopenParent(_ parts: [String]) throws -> DirectoryHandle {
            var current = revision
            var path: [String] = []
            for part in parts {
                let child = try current.child(part)
                try child.requireOwnedDirectory(device: device)
                path.append(part)
                let opened = try child.identity()
                var childFS = statfs()
                guard let expected = directoryIdentities[path.joined(separator: "/")],
                      opened == expected, fstatfs(child.fd, &childFS) == 0,
                      childFS.f_fsid.val.0 == filesystem.f_fsid.val.0,
                      childFS.f_fsid.val.1 == filesystem.f_fsid.val.1 else {
                    throw NestError("Snapshot cleanup parent changed; cleanup stopped.", code: 6)
                }
                current = child
            }
            return current
        }
        for removal in removals {
            let parent = try removal.parentPath.map { try reopenParent($0) } ?? self
            let now = try parent.entryStat(removal.name)
            guard now.st_dev == removal.info.st_dev, now.st_ino == removal.info.st_ino,
                  now.st_mode & S_IFMT == removal.info.st_mode & S_IFMT else { throw NestError("Snapshot cleanup entry changed; cleanup stopped.", code: 6) }
            guard unlinkat(parent.fd, removal.name, now.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
                throw NestError("Snapshot cleanup could not remove an obsolete revision: \(String(cString: strerror(errno)))", code: 6)
            }
        }
        try sync()
    }
    private static func checkName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw NestError("Invalid managed entry name.", code: 4) }
    }
}

// Transaction-scoped bounded descriptor cache. Handles are no-follow anchors;
// copyTree still verifies destination and source-race boundaries independently.
final class DirectoryCursor {
    let root: DirectoryHandle
    private var handles: [String: DirectoryHandle] = [:]
    private var order: [String] = []
    init(_ root: DirectoryHandle) { self.root = root }
    func parent(of path: String) throws -> (DirectoryHandle, String) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = components.last, !name.isEmpty else { throw NestError("Invalid relative path.", code: 4) }
        var directory = root, prefix = ""
        for component in components.dropLast() {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            if let cached = handles[prefix] {
                let named = try directory.entryStat(component), pinned = try cached.identity()
                guard named.st_mode & S_IFMT == S_IFDIR, Paths.deviceID(named.st_dev) == pinned.device,
                      UInt64(named.st_ino) == pinned.inode else { throw NestError("Cached directory ancestor changed.", code: 4) }
                directory = cached
            }
            else {
                directory = try directory.child(component)
                if order.count == 24 { handles.removeValue(forKey: order.removeFirst()) }
                order.append(prefix); handles[prefix] = directory
            }
        }
        guard name != ".", name != "..", !name.contains("\0") else { throw NestError("Invalid relative path.", code: 4) }
        return (directory, name)
    }
}
