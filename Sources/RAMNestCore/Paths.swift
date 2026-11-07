import Foundation
import Darwin

public enum Paths {
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
    public static func rejectSymlinks(_ path: String, allowMissingLast: Bool = false) throws {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var current = ""
        for (index, part) in components.enumerated() {
            current = part == "/" ? "/" : (current as NSString).appendingPathComponent(part)
            var st = stat()
            if lstat(current, &st) != 0 {
                if allowMissingLast && errno == ENOENT { return }
                throw NestError("Cannot inspect path: \(current)", code: 4)
            }
            guard st.st_mode & S_IFMT != S_IFLNK else { throw NestError("Symlink traversal is not allowed: \(current)", code: 4) }
            if index < components.count - 1 && st.st_mode & S_IFMT != S_IFDIR { throw NestError("Path component is not a directory.", code: 4) }
        }
    }
    public static func filesystemID(_ signed: Int32) -> UInt64 { UInt64(UInt32(bitPattern: signed)) }
    public static func deviceID(_ signed: dev_t) -> UInt64 { UInt64(bitPattern: Int64(signed)) }
    public static func mounts() -> [(path: String, device: UInt64)] {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&pointer, MNT_NOWAIT)
        guard count > 0, let pointer else { return [] }
        return (0..<Int(count)).map { i in
            var record = pointer[i]
            let path = withUnsafePointer(to: &record.f_mntonname) { p in p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            return (path, filesystemID(record.f_fsid.val.0))
        }
    }
    public static func validate(_ url: URL, store: Store, folders: [Folder], excluding: UUID? = nil) throws -> stat {
        let path = url.standardizedFileURL.path
        guard !path.contains("\n"), !path.contains("\t"), !path.contains("\0") else { throw NestError("Control characters are not allowed in managed paths.", code: 4) }
        try rejectSymlinks(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let forbidden = ["/", "/Users", "/Volumes", "/private", "/private/tmp", "/private/var", "/tmp", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev", "/etc", "/var", home, home + "/Library"]
        guard !forbidden.contains(path), !["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev"].contains(where: { path.hasPrefix($0 + "/") }) else { throw NestError("Choose a data folder, not a root, home, or system folder.", code: 4) }
        for unsafe in [home + "/Library/Containers", home + "/Library/Group Containers", store.root.path] where overlaps(path, unsafe) { throw NestError("This location overlaps protected app storage.", code: 4) }
        guard !folders.contains(where: { $0.id != excluding && overlaps(path, $0.path) }) else { throw NestError("RAM folders cannot overlap or nest.", code: 4) }
        guard !mounts().contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) else { throw NestError("Folder is or contains an existing mount.", code: 4) }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { throw NestError("Choose an existing directory owned by the current user.", code: 4) }
        return st
    }
    public static func checkedIdentity(_ folder: Folder) throws {
        try rejectSymlinks(folder.path)
        var st = stat()
        guard lstat(folder.path, &st) == 0, deviceID(st.st_dev) == folder.device, UInt64(st.st_ino) == folder.inode else { throw NestError("Folder identity changed. Locate the original folder or export its snapshot; automatic recovery is blocked.", code: 4) }
    }
    public static func resolveBookmark(_ folder: Folder) throws -> Folder {
        try resolveBookmark(folder, resolver: { bookmark in
            var stale = false
            return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        })
    }
    // APFS bookmark relocation can briefly report a missing file after rename.
    // Retry only that resolver error, never a failed identity/path safety check.
    static func resolveBookmark(_ folder: Folder, resolver: (Data) throws -> URL,
                                sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> Folder {
        if (try? checkedIdentity(folder)) != nil { return folder }
        guard let bookmark = folder.bookmark else { throw NestError("Original folder is missing; recovery is blocked.", code: 4) }
        let deadline = uptime() + 1.5
        var lastMissing: NSError?
        for attempt in 0..<8 {
            if attempt > 0 && uptime() >= deadline { break }
            let url: URL
            do { url = try resolver(bookmark) }
            catch {
                let failure = error as NSError
                guard failure.domain == NSCocoaErrorDomain,
                      failure.code == CocoaError.Code.fileNoSuchFile.rawValue || failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue else { throw error }
                lastMissing = failure
                // At most seven 200 ms waits (1.4 s total). Resolver runtime
                // counts toward the deadline; a slow lookup gets no extra waits.
                guard attempt < 7, deadline - uptime() >= 0.2 else { break }
                sleep(0.2)
                continue
            }
            guard url.isFileURL else { throw NestError("Bookmark did not resolve to a local directory; recovery is blocked.", code: 4) }
            var updated = folder; updated.path = url.path
            try checkedIdentity(updated)
            try DirectoryHandle.open(url).verify(updated)
            return updated
        }
        throw NestError("Original folder is still unavailable after bounded bookmark retries. No folder was accepted or moved. Retry the mount after the rename settles, or locate the original folder (device \(folder.device), inode \(folder.inode)). Bookmark error: \(lastMissing?.localizedDescription ?? "file not found")", code: 4)
    }
    public static func socketDirectory(for store: Store) throws -> URL {
        // macOS Unix sockets have a 104-byte path limit. Do not put them in Application Support.
        let path = URL(fileURLWithPath: "/private/tmp/ramnest-\(getuid())-\(String(Snapshot.digest(Data(store.root.path.utf8)).prefix(12)))", isDirectory: true)
        try Store.privateDirectory(path); return path
    }
}

/// Persisted authority for the new layout. Strings locate objects; identities
/// authorize them. Legacy journals never acquire this record during recovery.
public struct FSKitLinkLayout: Codable, Equatable, Sendable {
    // Decoder context is supplied only by the internal owned-fixture seam.
    // Normal JSONDecoder and every public Store use the fixed internal root.
    static let decoderRootKey = CodingUserInfoKey(rawValue: "RAMNest.FSKit.fixtureRoot")!
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public struct Identity: Codable, Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
        init(_ value: (device: UInt64, inode: UInt64)) { device = value.device; inode = value.inode }
        private enum CodingKeys: String, CodingKey { case device, inode }
        public init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: Key.self)
            guard Set(all.allKeys.map(\.stringValue)) == ["device", "inode"] else { throw NestError("Malformed FSKit identity.", code: 6) }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            device = try values.decode(UInt64.self, forKey: .device); inode = try values.decode(UInt64.self, forKey: .inode)
            guard inode > 0 else { throw NestError("Invalid FSKit inode.", code: 6) }
        }
        func verify(_ handle: DirectoryHandle) throws {
            guard try Identity(handle.identity()) == self else { throw NestError("FSKit directory identity changed; data retained.", code: 4) }
        }
        func matches(_ st: stat) -> Bool { device == Paths.deviceID(st.st_dev) && inode == UInt64(st.st_ino) }
    }
    enum Stage: String, Codable, Sendable { case reserved, evacuating, evacuated, linking, linked, restoring, publishing, restored }
    enum Restoration: String, Codable, Sendable { case original, checkpoint }
    var version = 1
    var folderID: UUID
    var session: UUID
    var stage: Stage
    var originalPath: String
    var mountRoot: String
    var mountPath: String
    var holdingPath: String
    var linkStagePath: String
    var parent: Identity
    var root: Identity
    var mountpoint: Identity
    var source: Identity
    var holding: Identity?
    var originalDataURL: URL { URL(fileURLWithPath: holdingPath).appendingPathComponent("data") }
    var link: Identity?
    // Recorded before atomic publication, never derived from the public path.
    var restored: Identity?
    var restoration: Restoration?
    var mountReleased = false

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, folderID, session, stage, originalPath, mountRoot, mountPath, holdingPath, linkStagePath
        case parent, root, mountpoint, source, holding, link, restored, restoration, mountReleased
    }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Key.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard all.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw NestError("Unknown FSKit layout fields; recovery blocked.", code: 6) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        folderID = try c.decode(UUID.self, forKey: .folderID); session = try c.decode(UUID.self, forKey: .session)
        stage = try c.decode(Stage.self, forKey: .stage)
        originalPath = try c.decode(String.self, forKey: .originalPath); mountRoot = try c.decode(String.self, forKey: .mountRoot)
        mountPath = try c.decode(String.self, forKey: .mountPath); holdingPath = try c.decode(String.self, forKey: .holdingPath)
        linkStagePath = try c.decode(String.self, forKey: .linkStagePath)
        parent = try c.decode(Identity.self, forKey: .parent); root = try c.decode(Identity.self, forKey: .root)
        mountpoint = try c.decode(Identity.self, forKey: .mountpoint); source = try c.decode(Identity.self, forKey: .source)
        holding = c.contains(.holding) ? try c.decode(Identity.self, forKey: .holding) : nil
        link = c.contains(.link) ? try c.decode(Identity.self, forKey: .link) : nil
        restored = c.contains(.restored) ? try c.decode(Identity.self, forKey: .restored) : nil
        restoration = c.contains(.restoration) ? try c.decode(Restoration.self, forKey: .restoration) : nil
        mountReleased = try c.decode(Bool.self, forKey: .mountReleased)
        try validate()
    }
    init(folderID: UUID, session: UUID, stage: Stage, originalPath: String, mountRoot: String, mountPath: String,
         holdingPath: String, linkStagePath: String, parent: Identity, root: Identity, mountpoint: Identity, source: Identity) {
        self.folderID = folderID; self.session = session; self.stage = stage; self.originalPath = originalPath
        self.mountRoot = mountRoot; self.mountPath = mountPath; self.holdingPath = holdingPath; self.linkStagePath = linkStagePath
        self.parent = parent; self.root = root; self.mountpoint = mountpoint; self.source = source
    }

    func validate() throws {
        let original = URL(fileURLWithPath: originalPath), mount = URL(fileURLWithPath: mountPath)
        let rootURL = URL(fileURLWithPath: mountRoot)
        let paths = [originalPath, mountRoot, mountPath, holdingPath, linkStagePath]
        guard version == 1, Set(paths).count == paths.count,
              paths.allSatisfy({ $0.hasPrefix("/") && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 && !$0.contains(where: { $0.isNewline || $0 == "\t" || $0 == "\0" }) }),
              rootURL.lastPathComponent == "RAMNest-Mounts-\(getuid())",
              original.lastPathComponent != ".", original.lastPathComponent != "..", !original.lastPathComponent.isEmpty,
              mount.deletingLastPathComponent() == rootURL, mount.lastPathComponent == original.lastPathComponent,
              !Paths.overlaps(originalPath, mountRoot),
              holdingPath == original.deletingLastPathComponent().appendingPathComponent(".ramnest-\(folderID.uuidString)-\(session.uuidString).original").path,
              linkStagePath == original.deletingLastPathComponent().appendingPathComponent(".ramnest-\(folderID.uuidString)-\(session.uuidString).link").path,
              [parent, root, mountpoint, source].allSatisfy({ $0.inode > 0 }),
              source.device == parent.device, mountpoint.device == root.device,
              mountpoint != root, source != parent,
              stage != .reserved || holding == nil,
              ![Stage.evacuating, .evacuated, .linking, .linked, .restoring, .publishing].contains(stage) || holding != nil,
              holding.map({ $0.device == parent.device && $0.inode > 0 && $0 != source && $0 != parent }) ?? true,
              ![Stage.linking, .linked].contains(stage) || link != nil,
              stage != .publishing || link != nil || restored == source,
              ![Stage.publishing, .restored].contains(stage) || restored != nil,
              ![Stage.restoring, .publishing, .restored].contains(stage) || restoration != nil,
              restoration != .original || restored == source,
              restoration != .checkpoint || restored == nil || restored != source,
              !mountReleased || stage == .restored,
              link.map({ $0.inode > 0 && $0.device == parent.device && $0 != source && $0 != parent }) ?? true,
              restored.map({ $0.inode > 0 && $0.device == parent.device }) ?? true else {
            throw NestError("Invalid FSKit symlink authority; recovery blocked and all data retained.", code: 6)
        }
    }
}

/// No environment overrides. The internal initializer's root argument is an
/// owned-fixture seam; public Engine always uses the fixed production root.
enum FSKitLinks {
    static func requirePrivateDirectory(_ handle: DirectoryHandle, device: UInt64, checkACL: Bool = true) throws {
        try handle.requireOwnedDirectory(device: device, privateMode: true)
        var st = stat()
        guard fstat(handle.fd, &st) == 0, st.st_mode & 0o7777 == 0o700 else { throw NestError("FSKit private directory must have mode 0700.", code: 4) }
        // Backup ACL fidelity is explicitly non-blocking. Live mount roots and
        // reservations keep the stricter access-control policy by default.
        guard checkACL else { return }
        errno = 0
        if let acl = acl_get_fd_np(handle.fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
            guard result != 0, errno == EINVAL else { throw NestError("ACL-bearing FSKit private directories are unsupported; retained.", code: 4) }
        } else if errno != ENOENT && errno != ENOTSUP { throw NestError("Cannot inspect bound FSKit directory ACL; retained.", code: 4) }
    }
    static func holding(_ layout: FSKitLinkLayout, parent: DirectoryHandle) throws -> DirectoryHandle {
        guard let identity = layout.holding else { throw NestError("Unrecorded FSKit backup wrapper; retained.", code: 4) }
        let handle = try parent.child(URL(fileURLWithPath: layout.holdingPath).lastPathComponent)
        try identity.verify(handle); try requirePrivateDirectory(handle, device: identity.device, checkACL: false)
        return handle
    }
    static var productionRoot: URL { URL(fileURLWithPath: "/Users/Shared/RAMNest-Mounts-\(getuid())", isDirectory: true) }
    static func requireInternalFilesystem(_ parent: DirectoryHandle) throws {
        var fs = statfs(), internalFS = statfs()
        guard fstatfs(parent.fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              fs.f_flags & UInt32(MNT_RDONLY) == 0,
              statfs("/Users/Shared", &internalFS) == 0,
              fs.f_fsid.val.0 == internalFS.f_fsid.val.0, fs.f_fsid.val.1 == internalFS.f_fsid.val.1 else {
            throw NestError("FSKit mount root requires writable internal storage.", code: 4)
        }
    }
    static func reserve(_ folder: Folder, session: UUID, root: URL,
                        filesystemCheck: (DirectoryHandle) throws -> Void = requireInternalFilesystem) throws -> FSKitLinkLayout {
        try Paths.checkedIdentity(folder)
        let selected = URL(fileURLWithPath: folder.path)
        let parent = try DirectoryHandle.open(selected.deletingLastPathComponent())
        let rootParent = try DirectoryHandle.open(root.deletingLastPathComponent())
        // Check internal local storage before creating even the reservation.
        try filesystemCheck(rootParent)
        if try !rootParent.exists(root.lastPathComponent) { _ = try rootParent.createDirectory(root.lastPathComponent); try rootParent.sync() }
        let rootHandle = try rootParent.child(root.lastPathComponent)
        let rootIdentity = try rootHandle.identity()
        try requirePrivateDirectory(rootHandle, device: rootIdentity.device)
        var rootStat = stat()
        guard fstat(rootHandle.fd, &rootStat) == 0, rootStat.st_mode & 0o7777 == 0o700 else { throw NestError("FSKit mount root must have mode 0700.", code: 4) }
        let mountPath = root.appendingPathComponent(selected.lastPathComponent)
        guard !Paths.mounts().contains(where: { $0.path == root.path || $0.path == mountPath.path || $0.path.hasPrefix(mountPath.path + "/") }),
              try !rootHandle.exists(selected.lastPathComponent) else { throw NestError("Exact FSKit mount basename is already reserved; source unchanged.", code: 6) }
        let mount = try rootHandle.createDirectory(selected.lastPathComponent)
        try requirePrivateDirectory(mount, device: rootIdentity.device)
        try rootHandle.sync()
        let result = FSKitLinkLayout(folderID: folder.id, session: session, stage: .reserved,
            originalPath: folder.path, mountRoot: root.path, mountPath: mountPath.path,
            holdingPath: selected.deletingLastPathComponent().appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(session.uuidString).original").path,
            linkStagePath: selected.deletingLastPathComponent().appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(session.uuidString).link").path,
            parent: try .init(parent.identity()), root: .init(rootIdentity), mountpoint: try .init(mount.identity()),
            source: .init((folder.device, folder.inode)))
        try result.validate(); return result
    }
    static func parent(_ layout: FSKitLinkLayout, folder: Folder, root: URL) throws -> DirectoryHandle {
        try layout.validate()
        guard layout.folderID == folder.id, layout.originalPath == folder.path, layout.mountRoot == root.path,
              (folder.device == layout.source.device && folder.inode == layout.source.inode) ||
              (layout.restored?.device == folder.device && layout.restored?.inode == folder.inode) else {
            throw NestError("FSKit folder/configuration authority changed; recovery blocked.", code: 4)
        }
        let handle = try DirectoryHandle.open(URL(fileURLWithPath: layout.originalPath).deletingLastPathComponent())
        try layout.parent.verify(handle)
        return handle
    }
    static func root(_ layout: FSKitLinkLayout) throws -> DirectoryHandle {
        let handle = try DirectoryHandle.open(URL(fileURLWithPath: layout.mountRoot))
        try layout.root.verify(handle)
        try requirePrivateDirectory(handle, device: layout.root.device)
        var st = stat()
        guard fstat(handle.fd, &st) == 0, st.st_mode & 0o7777 == 0o700 else { throw NestError("FSKit root mode changed.", code: 4) }
        return handle
    }
    static func verifyLink(_ layout: FSKitLinkLayout, parent: DirectoryHandle, name: String? = nil) throws {
        let leaf = name ?? URL(fileURLWithPath: layout.originalPath).lastPathComponent
        let st = try parent.entryStat(leaf)
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let count = readlinkat(parent.fd, leaf, &bytes, bytes.count - 1)
        guard let identity = layout.link, st.st_mode & S_IFMT == S_IFLNK, identity.matches(st),
              st.st_uid == getuid(), count > 0, count < bytes.count - 1,
              String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self) == layout.mountPath else {
            throw NestError("Managed original-path link changed; data and RAM retained.", code: 4)
        }
    }
    static func releaseMountpoint(_ layout: FSKitLinkLayout) throws {
        guard !Paths.mounts().contains(where: { $0.path == layout.mountPath || $0.path.hasPrefix(layout.mountPath + "/") }) else { throw NestError("Internal mount is still present.", code: 6) }
        let root = try root(layout), name = URL(fileURLWithPath: layout.mountPath).lastPathComponent
        if try !root.exists(name) { return }
        let child = try root.child(name)
        try layout.mountpoint.verify(child)
        guard try child.names().isEmpty, unlinkat(root.fd, name, AT_REMOVEDIR) == 0 else { throw NestError("Internal reservation changed or is not empty; retained.", code: 6) }
        try root.sync()
    }
}
