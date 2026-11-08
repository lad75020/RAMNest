import Foundation
import Darwin

struct StoredManifest: Codable {
    var entries: [Entry]
    var publicRoot: Entry?
    var storageFormat: Int?
    var modeMapDigest: String?
    var logical: Manifest { Manifest(entries:entries,publicRoot:publicRoot) }
    init(_ manifest: Manifest, modes: StorageModes? = nil) {
        entries = manifest.entries;publicRoot = manifest.publicRoot
        storageFormat = modes == nil ? nil : 2;modeMapDigest = modes.map { Snapshot.digest($0.encoded) }
    }
    enum CodingKeys: String, CodingKey { case entries, publicRoot, storageFormat, modeMapDigest }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        entries = try c.decode([Entry].self,forKey:.entries);publicRoot = try c.decodeIfPresent(Entry.self,forKey:.publicRoot)
        if c.contains(.storageFormat) {
            storageFormat = try c.decode(Int.self,forKey:.storageFormat)
            modeMapDigest = try c.decode(String.self,forKey:.modeMapDigest)
            guard storageFormat == 2, let digest = modeMapDigest, digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), publicRoot != nil else { throw NestError("Unknown or malformed snapshot storage format.", code: 6) }
            _ = try StorageModes(logical)
        } else {
            guard !c.contains(.modeMapDigest) else { throw NestError("Unversioned storage mode map.", code: 6) }
            storageFormat = nil;modeMapDigest = nil
        }
    }
}

// Receipts describe a completed private readback and pinned final-mode handoff.
// They do not authorize chmod/reread of an inaccessible published user tree.
// Recovery still independently checks what it can, otherwise fails closed.
struct PublicationReceipt: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        var path: String;var device: UInt64;var inode: UInt64;var mode: UInt16
        var ctimeSeconds: Int64;var ctimeNanos: Int64
    }
    var version = 1
    var manifestDigest: String
    var destination: String
    var phase: String
    var privateName: String? = nil
    var privateNames: [String:String]? = nil
    var identities: [Identity] = []
    init(manifest: Manifest, destination: String, phase: String) {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        manifestDigest = Snapshot.digest((try? encoder.encode(manifest)) ?? Data())
        self.destination = destination;self.phase = phase
    }
}

extension Snapshot {
    // All payload/xattr/namespace readback has finished before this entry point.
    // Only newly owned private materializations are admitted. Descendants finish
    // before parents; no recursive stack or per-tree descriptor retention.
    static func finalizeModes(_ data: URL, manifest: Manifest, destination: String, finalizeRoot: Bool = true) throws -> PublicationReceipt {
        let modes = try StorageModes(manifest)
        let root = try DirectoryHandle.open(data), cursor = DirectoryCursor(root)
        var receipt = PublicationReceipt(manifest:manifest,destination:destination,phase:"verified-final-modes")
        var done: [String:UInt16] = [:]
        for record in modes.records.sorted(by:{
            let a = $0.path.isEmpty ? 0 : $0.path.split(separator:"/").count
            let b = $1.path.isEmpty ? 0 : $1.path.split(separator:"/").count
            return a == b ? $0.path < $1.path : a > b
        }) {
            if record.path.isEmpty && !finalizeRoot { continue }
            var st = stat()
            var containingDirectory: DirectoryHandle?
            let fd: Int32
            if record.path.isEmpty { fd = dup(root.fd) }
            else {
                let (parent,name) = try cursor.parent(of:record.path)
                containingDirectory = parent
                st = try parent.entryStat(name)
                let key = "\(st.st_dev):\(st.st_ino)"
                if let mode = done[key] {
                    guard record.kind == "file", mode == record.mode, st.st_mode & 0o7777 == mode else { throw NestError("Materialization hardlink/mode mismatch.", code: 6) }
                    receipt.identities.append(.init(path:record.path,device:Paths.deviceID(st.st_dev),inode:UInt64(st.st_ino),mode:mode,ctimeSeconds:Int64(st.st_ctimespec.tv_sec),ctimeNanos:Int64(st.st_ctimespec.tv_nsec)))
                    continue
                }
                fd = openat(parent.fd,name,O_RDONLY | O_CLOEXEC | (record.kind == "symlink" ? O_SYMLINK : O_NOFOLLOW))
            }
            guard fd >= 0 else { throw NestError("Cannot pin private materialization at \(diagnosticLabel(record.path)) (openat, errno \(errno)).", code: 6) }
            defer { close(fd) }
            var pinned = stat()
            guard fstat(fd,&pinned) == 0, pinned.st_uid == getuid(), pinned.st_gid == getgid(),
                  record.path.isEmpty || (pinned.st_dev == st.st_dev && pinned.st_ino == st.st_ino),
                  pinned.st_mode & 0o7777 == StorageModes.physical(record) else { throw NestError("Materialization identity/physical policy changed.", code: 6) }
            guard fchmod(fd,mode_t(record.mode)) == 0 else { throw NestError("Cannot finalize private logical mode (fchmod, errno \(errno)).", code: 6) }
            if record.kind == "symlink" { try containingDirectory?.sync() }
            else { guard fsync(fd) == 0 else { throw NestError("Cannot sync final private logical mode (fsync, errno \(errno)).", code: 6) } }
            var final = stat()
            guard fstat(fd,&final) == 0, final.st_dev == pinned.st_dev, final.st_ino == pinned.st_ino, final.st_mode & 0o7777 == record.mode else { throw NestError("Final logical mode/identity verification failed.", code: 6) }
            done["\(final.st_dev):\(final.st_ino)"] = record.mode
            receipt.identities.append(.init(path:record.path,device:Paths.deviceID(final.st_dev),inode:UInt64(final.st_ino),mode:record.mode,ctimeSeconds:Int64(final.st_ctimespec.tv_sec),ctimeNanos:Int64(final.st_ctimespec.tv_nsec)))
        }
        try root.sync();return receipt
    }
}

// Version 2 stores owner-readable physical inodes, with original modes in a
// bounded, canonical binary map OUTSIDE data/. Its SHA256 is in manifest.json.
// No caller may use logical modes without checking both the map and the exact
// physical policy. Absence of a version is the immutable legacy representation.
struct StorageModes {
    struct Record: Equatable { var path: String; var kind: String; var mode: UInt16 }
    var records: [Record]
    static let magic = Data("RNMODE2\n".utf8)
    static let maximumBytes = 64 << 20
    // Namespace records include aliases, unlike the native unique-node quota.
    // This bound exceeds the existing 128 MiB native capture budget's possible
    // record count; it must not turn aliases into newly charged native nodes.
    static let maximumRecords = 1_000_000
    static func validPath(_ path: String) -> Bool {
        !path.contains("\0") && (path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
    }
    init(_ manifest: Manifest) throws {
        guard let root = manifest.publicRoot else { throw NestError("Private storage requires root metadata.", code: 6) }
        records = ([root] + manifest.entries).map { Record(path: $0.path, kind: $0.kind, mode: $0.mode) }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        try validate()
    }
    init(records: [Record]) throws { self.records = records.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }; try validate() }
    func validate() throws {
        guard records.count > 0, records.count <= Self.maximumRecords, records.first?.path == "", records.first?.kind == "directory" else { throw NestError("Invalid storage mode map root/count.", code: 6) }
        var seen: [String: String] = [:]
        var prior: String?
        var bytes = 12
        for r in records {
            guard Self.validPath(r.path), ["directory", "file", "symlink"].contains(r.kind), r.mode <= 0o7777,
                  seen.updateValue(r.kind, forKey: r.path) == nil,
                  prior == nil || prior!.utf8.lexicographicallyPrecedes(r.path.utf8) else { throw NestError("Malformed, duplicate or unordered storage mode map.", code: 6) }
            if !r.path.isEmpty {
                let parent = r.path.split(separator: "/").dropLast().joined(separator: "/")
                guard seen[parent] == "directory" else { throw NestError("Storage mode map parent is missing or not a directory.", code: 6) }
            }
            prior = r.path
            let amount = r.path.utf8.count + 7
            guard amount <= Self.maximumBytes - bytes else { throw NestError("Storage mode metadata byte bound exceeded.", code: 6) }
            bytes += amount
        }
    }
    var encoded: Data {
        var d = Self.magic
        func number(_ n: UInt32) { d.append(contentsOf: [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) }
        number(UInt32(records.count))
        for r in records { number(UInt32(r.path.utf8.count));d.append(contentsOf:r.path.utf8);d.append(r.kind == "directory" ? 1 : r.kind == "file" ? 2 : 3);d.append(UInt8(r.mode >> 8));d.append(UInt8(r.mode & 255)) }
        return d
    }
    init(data: Data) throws {
        guard data.count <= Self.maximumBytes, data.starts(with: Self.magic) else { throw NestError("Unknown or malformed storage mode map.", code: 6) }
        let bytes = [UInt8](data);var at = Self.magic.count
        func number() throws -> Int {
            guard at + 4 <= bytes.count else { throw NestError("Truncated storage mode map.", code: 6) }
            defer { at += 4 };return (0..<4).reduce(0) { ($0 << 8) | Int(bytes[at+$1]) }
        }
        let count = try number();guard count > 0, count <= Self.maximumRecords, count <= (bytes.count-at)/7 else { throw NestError("Invalid storage mode count.", code: 6) }
        var result: [Record] = [];result.reserveCapacity(count)
        for _ in 0..<count {
            let size = try number()
            guard size <= 1 << 20, at <= bytes.count - size - 3, let path = String(bytes:bytes[at..<at+size],encoding:.utf8) else { throw NestError("Invalid storage mode path.", code: 6) }
            at += size
            let kind = bytes[at] == 1 ? "directory" : bytes[at] == 2 ? "file" : bytes[at] == 3 ? "symlink" : "invalid"
            result.append(Record(path:path,kind:kind,mode:UInt16(bytes[at+1]) << 8 | UInt16(bytes[at+2])));at += 3
        }
        guard at == bytes.count else { throw NestError("Trailing storage mode metadata.", code: 6) }
        records = result;try validate()
    }
    static func physical(_ record: Record) -> UInt16 { record.kind == "file" ? 0o600 : 0o700 }
    func projecting(_ observed: Manifest) throws -> Manifest {
        // The complete binary map has already passed format, digest, namespace
        // and manifest correspondence checks. Project only directory subtrees.
        let excluded = Set(records.filter { SnapshotExclusion.directory($0.path,kind:$0.kind) }.map(\.path))
        let included = records.filter { record in
            var parts = record.path.split(separator:"/")
            while !parts.isEmpty { if excluded.contains(parts.joined(separator:"/")) { return false };parts.removeLast() }
            return true
        }
        guard observed.publicRoot != nil, included.count == observed.entries.count + 1 else { throw NestError("Private storage namespace/map mismatch.", code: 6) }
        let modes = Dictionary(uniqueKeysWithValues:included.map { ($0.path,$0) })
        var groups: [String:UInt16] = [:]
        for e in observed.entries where e.kind == "file" {
            let group = e.hardlink ?? e.path
            guard let mode = modes[e.path]?.mode, groups[group] == nil || groups[group] == mode else { throw NestError("Inconsistent logical modes within a hardlink class.", code: 6) }
            groups[group] = mode
        }
        func entry(_ e: Entry) throws -> Entry {
            guard let r = modes[e.path], r.kind == e.kind, e.mode == Self.physical(r) else { throw NestError("Private storage physical policy mismatch at \(Snapshot.diagnosticLabel(e.path.isEmpty ? "." : e.path)).", code: 6) }
            var result = e;result.mode = r.mode;return result
        }
        return try Manifest(entries:observed.entries.map(entry),publicRoot:entry(observed.publicRoot!))
    }
    static func read(_ url: URL) throws -> Data {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NestError("Cannot open storage mode map (open, errno \(errno)).", code: 6) }
        defer { close(fd) };var st = stat()
        guard fstat(fd,&st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o7777 == 0o600,
              st.st_uid == getuid(), st.st_gid == getgid(), st.st_nlink == 1, st.st_size >= 0, st.st_size <= maximumBytes else { throw NestError("Invalid private storage mode map inode/policy.", code: 6) }
        let data = try FileHandle(fileDescriptor:fd,closeOnDealloc:false).readToEnd() ?? Data()
        var after = stat()
        guard fstat(fd,&after) == 0, st.st_size == after.st_size, st.st_ctimespec == after.st_ctimespec, data.count == Int(st.st_size) else { throw NestError("Storage mode map changed while reading.", code: 6) }
        return data
    }
    func write(_ url: URL) throws {
        let fd = open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw NestError("Cannot create private storage mode map.", code: 6) };defer { close(fd) }
        try FileHandle(fileDescriptor:fd,closeOnDealloc:false).write(contentsOf:encoded)
        guard fchmod(fd,0o600) == 0, fsync(fd) == 0 else { throw NestError("Cannot sync private storage mode map.", code: 6) }
    }
    // Only the successful ordinary export of this operation may enter here.
    // The parent is a pinned owned 0700 store container, never a revision/public
    // tree. Directories are normalized top down; files wait until the complete
    // hardlink namespace proves that chmod cannot touch an outside inode.
    static func normalizeFreshExport(_ stage: URL, volume: URL, hook: ((String, String) throws -> Void)? = nil) throws -> StorageModes {
        guard stage.deletingLastPathComponent() == volume, stage.lastPathComponent.hasPrefix("stage-"), UUID(uuidString:String(stage.lastPathComponent.dropFirst(6))) != nil else { throw NestError("Normalization requires a fresh private export stage.", code: 6) }
        let parent = try DirectoryHandle.open(volume)
        try parent.requireOwnedDirectory(device:parent.identity().device,privateMode:true)
        let device = try parent.identity().device
        func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
            a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink &&
            a.st_size == b.st_size && a.st_mtimespec == b.st_mtimespec && a.st_ctimespec == b.st_ctimespec
        }
        // No pathname chmod: even an owned 0700 stage can be replaced by a
        // same-uid writer. Pin using rights the exported inode actually grants,
        // then verify both the descriptor and named binding BEFORE mutation.
        // Darwin O_SEARCH/O_EXEC are access checks, not mode-0000 bypasses.
        func pin(_ p: DirectoryHandle, _ n: String, _ expected: stat, _ path: String) throws -> Int32 {
            try hook?(path,"before-pin")
            let kind = expected.st_mode & S_IFMT
            let access: Int32
            if kind == S_IFDIR { access = O_SEARCH | O_DIRECTORY }
            else if kind == S_IFLNK { access = O_RDONLY | O_SYMLINK }
            else if expected.st_mode & 0o400 != 0 { access = O_RDONLY }
            else if expected.st_mode & 0o200 != 0 { access = O_WRONLY }
            else { access = O_EXEC }
            // O_SYMLINK opens the link itself on Darwin. Combining it with
            // O_NOFOLLOW rejects symlinks (ELOOP), rather than pinning them.
            let fd = openat(p.fd,n,access | O_CLOEXEC | (kind == S_IFLNK ? 0 : O_NOFOLLOW))
            guard fd >= 0 else {
                throw NestError("Cannot pin fresh legacy export at \(Snapshot.diagnosticLabel(path.isEmpty ? "." : path)) (openat, errno \(errno)); unpinnable legacy permissions require a corrected helper. RAM, stage and prior snapshots retained.", code: 6)
            }
            do {
                var actual = stat()
                guard fstat(fd,&actual) == 0, same(actual,expected) else { throw NestError("Fresh export pinned identity/owner/type/link class changed; no permission change performed.", code: 6) }
                try hook?(path,"after-pin")
                let named = try p.entryStat(n)
                guard fstat(fd,&actual) == 0, same(actual,expected), same(named,expected) else { throw NestError("Fresh export named/pinned identity changed; no permission change performed.", code: 6) }
                return fd
            } catch { close(fd);throw error }
        }
        func normalize(_ fd: Int32, _ p: DirectoryHandle, _ n: String, _ mode: mode_t) throws {
            guard fchmod(fd,mode) == 0 else { throw NestError("Cannot normalize pinned fresh private inode (fchmod, errno \(errno)).", code: 6) }
            var actual = stat()
            guard fstat(fd,&actual) == 0, actual.st_mode & 0o7777 == mode,
                  same(actual,try p.entryStat(n)) else { throw NestError("Normalized fresh export binding/policy changed; retained.", code: 6) }
        }
        struct FileNode { var path: String;var info: stat }
        var records: [Record] = [], files: [FileNode] = [], aliases: [String:Int] = [:]
        var pending = [""]
        while let path = pending.popLast() {
            let (p,n): (DirectoryHandle,String)
            if path.isEmpty { p = parent;n = stage.lastPathComponent }
            else { (p,n) = try DirectoryHandle.open(stage).parent(of:path) }
            let st = try p.entryStat(n), kind = st.st_mode & S_IFMT
            if !path.isEmpty && SnapshotExclusion.directory(n,st.st_mode) { continue }
            guard st.st_uid == getuid(), st.st_gid == getgid(), Paths.deviceID(st.st_dev) == device else { throw NestError("Unsafe fresh export ownership/device.", code: 6) }
            let url = path.isEmpty ? stage : stage.appendingPathComponent(path)
            try Snapshot.supportedSecurity(url,st)
            guard kind == S_IFDIR || kind == S_IFREG || (kind == S_IFLNK && st.st_nlink == 1) else { throw NestError("Unsupported fresh export inode.", code: 6) }
            records.append(Record(path:path,kind:kind == S_IFDIR ? "directory" : kind == S_IFREG ? "file" : "symlink",mode:UInt16(st.st_mode & 0o7777)))
            if kind == S_IFREG { files.append(FileNode(path:path,info:st));aliases["\(st.st_dev):\(st.st_ino)",default:0] += 1 }
            if kind == S_IFLNK {
                let fd = try pin(p,n,st,path);defer { close(fd) }
                try normalize(fd,p,n,0o700)
                try p.sync()
            }
            if kind == S_IFDIR {
                let fd = try pin(p,n,st,path);defer { close(fd) }
                try normalize(fd,p,n,0o700)
                // Upgrade enumeration rights via the pinned directory itself,
                // rather than reopening a potentially substituted pathname.
                let readable = openat(fd,".",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard readable >= 0 else { throw NestError("Cannot enumerate normalized pinned directory.", code: 6) }
                let opened = DirectoryHandle(fd:readable), now = try opened.identity()
                guard now.inode == st.st_ino, now.device == Paths.deviceID(st.st_dev) else { throw NestError("Fresh export directory identity changed.", code: 6) }
                for name in try opened.names().reversed() { pending.append(path.isEmpty ? name : path + "/" + name) }
                try opened.sync()
            }
            guard records.count <= Self.maximumRecords else { throw NestError("Fresh export namespace bound exceeded.", code: 6) }
        }
        for file in files { guard aliases["\(file.info.st_dev):\(file.info.st_ino)"] == Int(file.info.st_nlink) else { throw NestError("Fresh export has a cross-boundary hardlink; retained.", code: 6) } }
        let root = try DirectoryHandle.open(stage), cursor = DirectoryCursor(root)
        var changed = Set<String>()
        for file in files {
            let (p,n) = try cursor.parent(of:file.path), st = try p.entryStat(n)
            let key = "\(st.st_dev):\(st.st_ino)"
            guard st.st_ino == file.info.st_ino, st.st_dev == file.info.st_dev, st.st_size == file.info.st_size, st.st_mtimespec == file.info.st_mtimespec,
                  st.st_uid == file.info.st_uid, st.st_gid == file.info.st_gid, st.st_nlink == file.info.st_nlink, st.st_mode & S_IFMT == S_IFREG,
                  changed.contains(key) || st.st_ctimespec == file.info.st_ctimespec else { throw NestError("Fresh export file changed before normalization.", code: 6) }
            let pinned = try pin(p,n,st,file.path);defer { close(pinned) }
            if changed.insert(key).inserted {
                try normalize(pinned,p,n,0o600)
            }
            let fd = openat(p.fd,n,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NestError("Cannot open normalized private file.", code: 6) };defer { close(fd) }
            var actual = stat();guard fstat(fd,&actual) == 0, actual.st_ino == st.st_ino, actual.st_dev == st.st_dev, actual.st_mode & 0o7777 == 0o600, fsync(fd) == 0 else { throw NestError("Normalized private file identity/policy changed.", code: 6) }
        }
        return try StorageModes(records:records)
    }
}

// Relocation keeps immutable revision files byte-for-byte. This store-level
// record binds each changed physical copy to the unchanged manifest and modes.
struct SnapshotCopyObservations: Codable {
    static let name = ".ramnest-copy-observations.json"
    struct Record: Codable {
        var manifestDigest: String
        var modeMapDigest: String?
        var basis: Manifest
        var observed: Manifest
    }
    var version = 1
    var device: UInt64
    var inode: UInt64
    var revisions: [String: Record]

    static func location(_ data: URL) throws -> (URL, String) {
        let revision = data.deletingLastPathComponent()
        let revisions = revision.deletingLastPathComponent()
        let volume = revisions.deletingLastPathComponent()
        let volumes = volume.deletingLastPathComponent()
        guard data.lastPathComponent == "data", UUID(uuidString: revision.lastPathComponent) != nil,
              revisions.lastPathComponent == "revisions", UUID(uuidString: volume.lastPathComponent) != nil,
              volumes.lastPathComponent == "volumes" else { throw NestError("Invalid revision observation path.", code: 6) }
        return (volumes.deletingLastPathComponent(), volume.lastPathComponent + "/" + revision.lastPathComponent)
    }
    static func read(_ root: URL) throws -> SnapshotCopyObservations? {
        let directory = try DirectoryHandle.open(root)
        guard try directory.exists(name) else { return nil }
        let identity = try directory.identity()
        try directory.requireOwnedDirectory(device: identity.device, privateMode: true)
        let before = try directory.entryStat(name)
        let value = try StorageRelocation.read(Self.self, in: directory, name: name)
        let after = try directory.entryStat(name)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_ctimespec == after.st_ctimespec,
              before.st_size == after.st_size, before.st_mode == after.st_mode else { throw NestError("Relocation observations changed during read.", code: 6) }
        guard value.version == 1, value.device == identity.device, value.inode == identity.inode,
              value.revisions.count <= 100_000 else { throw NestError("Invalid relocated copy observations.", code: 6) }
        for key in value.revisions.keys {
            let parts = key.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ UUID(uuidString: String($0)) != nil }) else { throw NestError("Malformed relocated revision key.", code: 6) }
        }
        return value
    }
    static func applying(to metadata: StoredManifest, data: URL) throws -> StoredManifest {
        guard let (root, key) = try? location(data) else { return metadata }
        guard let record = try read(root)?.revisions[key] else { return metadata }
        let container = try DirectoryHandle.open(data.deletingLastPathComponent())
        let manifestBytes = try Snapshot.manifestFileBytes(container)
        guard Snapshot.digest(manifestBytes) == record.manifestDigest,
              metadata.modeMapDigest == record.modeMapDigest,
              record.basis.matchesExpected(try metadata.logical.excludingTrashDirectories()),
              try record.observed.matchesCopy(of: record.basis) else { throw NestError("Relocated revision copy observation is not bound to its immutable manifest.", code: 6) }
        var result = metadata
        let entries = Dictionary(uniqueKeysWithValues: record.observed.entries.map { ($0.path, $0) })
        result.entries = metadata.entries.map { entries[$0.path] ?? $0 }; result.publicRoot = record.observed.publicRoot
        return result
    }
}
