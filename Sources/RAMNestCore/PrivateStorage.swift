import Foundation
import Darwin

struct StoredManifest: Codable {
    var entries: [Entry]
    var publicRoot: Entry?
    var storageFormat: Int?
    var modeMapDigest: String?
    var fileVerification: FileVerification
    var logical: Manifest { Manifest(entries:entries,publicRoot:publicRoot,fileVerification:fileVerification) }
    init(_ manifest: Manifest, modes: StorageModes? = nil) {
        entries = manifest.entries;publicRoot = manifest.publicRoot
        fileVerification = manifest.fileVerification
        storageFormat = modes == nil ? nil : 2;modeMapDigest = modes.map { Snapshot.digest($0.encoded) }
    }
    enum CodingKeys: String, CodingKey { case entries, publicRoot, storageFormat, modeMapDigest, fileVerification }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        entries = try c.decode([Entry].self,forKey:.entries);publicRoot = try c.decodeIfPresent(Entry.self,forKey:.publicRoot)
        fileVerification = c.contains(.fileVerification) ? try c.decode(FileVerification.self,forKey:.fileVerification) : .sha256
        try logical.validateVerification()
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
        return try Manifest(entries:observed.entries.map(entry),publicRoot:entry(observed.publicRoot!),fileVerification:observed.fileVerification)
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
