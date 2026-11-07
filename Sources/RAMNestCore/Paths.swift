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
