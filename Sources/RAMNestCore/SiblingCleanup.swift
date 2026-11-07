import Foundation
import Darwin
import CryptoKit

/// Exact journal provenance, never a directory-name scan. Optional identities
/// preserve incomplete legacy records without granting permission to delete.
public struct SiblingCleanupCandidate: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case original, fsKitOriginal, restoreStage }
    var kind: Kind
    var path: String
    var device: UInt64?
    var inode: UInt64?
    var parentDevice: UInt64?
    var parentInode: UInt64?
    var fsid: [Int32]?
    var initialRevision: String?
    var completedRevision: String?
    var emptyOnly: Bool
    var dataDevice: UInt64?
    var dataInode: UInt64?
    var plan: CleanupTreePlan?
}

struct CleanupTreePlan: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        var path: String
        var device: UInt64
        var inode: UInt64
        var type: UInt16
    }
    var manifest: Manifest
    var identities: [Identity]
}

enum SiblingCleanup {
    static func pins(_ journal: Journal) -> Set<String> {
        Set((journal.siblingCleanup ?? []).flatMap { [$0.initialRevision, $0.completedRevision].compactMap { $0 } })
    }

    // Called only after verified restore/rollback has committed idle, and before
    // any next session can overwrite the original transaction references.
    static func rememberCompleted(_ folder: Folder, _ journal: inout Journal) {
        guard journal.phase == .idle, journal.lastError == nil else { return }
        let parentURL = URL(fileURLWithPath: folder.path).deletingLastPathComponent()
        let parent = try? DirectoryHandle.open(parentURL)
        let identity = try? parent?.identity()
        let fsid = try? parent?.cleanupFilesystem()
        func append(_ kind: SiblingCleanupCandidate.Kind, _ path: String, _ device: UInt64?, _ inode: UInt64?) {
            let candidate = SiblingCleanupCandidate(kind: kind, path: path, device: device, inode: inode,
                parentDevice: identity?.device, parentInode: identity?.inode, fsid: fsid,
                initialRevision: kind == .original || kind == .fsKitOriginal ? journal.initialRevision : nil,
                completedRevision: journal.restoreRevision ?? (folder.options.sync ? journal.revision : journal.initialRevision),
                emptyOnly: kind == .restoreStage || (kind == .fsKitOriginal ? journal.fsKitLink?.restoration == .original : !folder.options.sync || !journal.populationVerified),
                dataDevice: kind == .fsKitOriginal ? journal.fsKitLink?.source.device : kind == .restoreStage ? journal.restoreDataDevice : nil,
                dataInode: kind == .fsKitOriginal ? journal.fsKitLink?.source.inode : kind == .restoreStage ? journal.restoreDataInode : nil)
            var queue = journal.siblingCleanup ?? []
            if !queue.contains(where: { $0.path == path && $0.device == device && $0.inode == inode }) { queue.append(candidate) }
            journal.siblingCleanup = queue
        }
        if let path = journal.evacuation {
            append(journal.fsKitLink?.holding != nil ? .fsKitOriginal : .original, path, journal.evacuationDevice, journal.evacuationInode)
            journal.evacuation = nil; journal.evacuationDevice = nil; journal.evacuationInode = nil
        }
        if let path = journal.restoreStage {
            append(.restoreStage, path, journal.restoreStageDevice, journal.restoreStageInode)
            journal.restoreStage = nil; journal.restoreStageDevice = nil; journal.restoreStageInode = nil
            journal.restoreDataDevice = nil; journal.restoreDataInode = nil
        }
    }

    // Writes are checked against the same durable journal and owned repository.
    // Publish the deletion plan before unlinking; retain it across partial errors.
    private static func checkpoint(_ next: Journal, previous: Journal, store: Store, folder: Folder) throws {
        let current = try store.managedVolume(folder.id).readJSON(Journal.self, "journal.json", decoder: store.journalDecoder)
        var expected = previous; expected.updated = current.updated
        guard current == expected else { throw NestError("Cleanup journal changed; siblings retained.", code: 6) }
        try store.write(next, for: folder.id)
    }

    static func clean(store: Store, folder: Folder, journal: inout Journal,
                      sourceRevision: String?,
                      validateSource: () throws -> Void,
                      beforeUnlink: ((DirectoryHandle, String) throws -> Void)? = nil) -> [String] {
        guard journal.phase == .idle, journal.lastError == nil else { return [] }
        var warnings: [String] = []
        for recorded in journal.siblingCleanup ?? [] {
            do {
                guard let index = journal.siblingCleanup?.firstIndex(of: recorded) else { continue }
                var candidate = recorded
                try validateSource()
                guard let completed = sourceRevision ?? candidate.completedRevision else { throw NestError("Missing completed-session snapshot; sibling retained: \(candidate.path)", code: 6) }
                let (_, restored) = try Snapshot.verified(store: store, id: folder.id, revision: completed)
                let selected = try DirectoryHandle.open(URL(fileURLWithPath: folder.path)); try selected.verify(folder)
                guard try Snapshot.manifest(URL(fileURLWithPath: folder.path), matching: restored).matchesExpected(restored) else { throw NestError("Selected contents changed since restore; sibling retained.", code: 6) }
                if candidate.completedRevision != completed {
                    candidate.completedRevision = completed
                    var next = journal; next.siblingCleanup?[index] = candidate
                    try checkpoint(next, previous: journal, store: store, folder: folder); journal = next
                }
                let path = URL(fileURLWithPath: candidate.path)
                let parentURL = URL(fileURLWithPath: folder.path).deletingLastPathComponent()
                guard path.path == path.standardizedFileURL.path, path.deletingLastPathComponent() == parentURL,
                      path.lastPathComponent != URL(fileURLWithPath: folder.path).lastPathComponent,
                      let device = candidate.device, let inode = candidate.inode,
                      let parentDevice = candidate.parentDevice, let parentInode = candidate.parentInode,
                      let fsid = candidate.fsid else { throw NestError("Incomplete or outside sibling provenance; retained: \(candidate.path)", code: 6) }
                let parent = try DirectoryHandle.open(parentURL)
                guard try parent.identity() == (parentDevice, parentInode), try parent.cleanupFilesystem() == fsid,
                      device == parentDevice else { throw NestError("Sibling parent identity changed; retained.", code: 6) }
                if try parent.exists(path.lastPathComponent) {
                    let root = try parent.child(path.lastPathComponent)
                    try root.requireCleanupRoot(device: device, inode: inode, fsid: fsid)
                    if candidate.kind == .fsKitOriginal { try FSKitLinks.requirePrivateDirectory(root, device: device, checkACL: false) }
                    let inventory = try root.cleanupInventory(matching: candidate.plan?.manifest)
                    if let plan = candidate.plan {
                        try root.validateCleanupRemainder(inventory, plan: plan)
                    } else {
                        if candidate.kind == .original || candidate.kind == .fsKitOriginal {
                            guard let initial = candidate.initialRevision else { throw NestError("Missing initial snapshot; original holding retained.", code: 6) }
                            let (_, original) = try Snapshot.verified(store: store, id: folder.id, revision: initial)
                            var expected = original
                            if candidate.kind == .fsKitOriginal, !candidate.emptyOnly {
                                guard let dataDevice = candidate.dataDevice, let dataInode = candidate.dataInode,
                                      var dataRoot = original.publicRoot,
                                      try root.child("data").identity() == (dataDevice, dataInode) else { throw NestError("Missing FSKit original data authority; retained.", code: 6) }
                                dataRoot.path = "data"
                                expected = Manifest(entries: [dataRoot] + original.entries.map { entry in
                                    var projected = entry; projected.path = "data/" + entry.path
                                    projected.hardlink = entry.hardlink.map { "data/" + $0 }; return projected
                                })
                                expected.entries.sort { $0.path < $1.path }
                            }
                            guard inventory.manifest.contentsMatchExpected(candidate.emptyOnly ? Manifest(entries: []) : expected) else {
                                throw NestError("Original holding changed or contains unknown entries; retained.", code: 6)
                            }
                        } else {
                            guard inventory.manifest.entries.count == 1, inventory.manifest.entries[0].path == "data",
                                  inventory.manifest.entries[0].kind == "directory" else { throw NestError("Restore stage is not an empty recorded data directory; retained.", code: 6) }
                            if let dataDevice = candidate.dataDevice, let dataInode = candidate.dataInode {
                                guard try root.child("data").identity() == (dataDevice, dataInode) else { throw NestError("Restore data identity changed; stage retained.", code: 6) }
                            }
                        }
                        candidate.plan = inventory
                        var next = journal; next.siblingCleanup?[index] = candidate
                        try checkpoint(next, previous: journal, store: store, folder: folder); journal = next
                    }
                    try validateSource()
                    // Reopen both the source and parent to reject path replacement
                    // after verification or the durable deletion-plan commit.
                    let refreshed = try DirectoryHandle.open(parentURL)
                    guard try refreshed.identity() == parent.identity(), try selected.identity() == DirectoryHandle.open(URL(fileURLWithPath: folder.path)).identity() else { throw NestError("Cleanup paths changed; retained.", code: 6) }
                    try root.removeCleanupTree(from: parent, name: path.lastPathComponent, plan: candidate.plan!, device: device, inode: inode, fsid: fsid, validateAnchor: {
                        try validateSource()
                        if candidate.kind == .fsKitOriginal { try FSKitLinks.requirePrivateDirectory(root, device: device, checkACL: false) }
                        guard try DirectoryHandle.open(parentURL).identity() == (parentDevice, parentInode) else { throw NestError("Sibling parent path changed; stopped.", code: 6) }
                    }, beforeUnlink: beforeUnlink)
                }
                var next = journal; next.siblingCleanup?.remove(at: index)
                if next.siblingCleanup?.isEmpty == true { next.siblingCleanup = nil }
                try checkpoint(next, previous: journal, store: store, folder: folder); journal = next
            } catch { warnings.append(error.localizedDescription + " Recovery location: " + recorded.path) }
        }
        return warnings
    }
}

extension DirectoryHandle {
    func cleanupFilesystem() throws -> [Int32] {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { throw NestError("Cannot inspect cleanup filesystem.", code: 6) }
        return [info.f_fsid.val.0, info.f_fsid.val.1]
    }
    func requireCleanupRoot(device: UInt64, inode: UInt64, fsid: [Int32]) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(),
              st.st_mode & 0o7777 == 0o700, Paths.deviceID(st.st_dev) == device, UInt64(st.st_ino) == inode,
              st.st_flags & ~UInt32(UF_HIDDEN | UF_NODUMP) == 0,
              try cleanupFilesystem() == fsid else { throw NestError("Sibling root identity, mode or filesystem changed; retained.", code: 6) }
    }
    // Iterative traversal, reopening paths with bounded descriptors. Every
    // ancestor is checked against the inventory, including on deletion retries.
    private func cleanupParent(_ path: String, identities: [String: CleanupTreePlan.Identity], device: UInt64, fsid: [Int32]) throws -> (DirectoryHandle, String) {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw NestError("Invalid cleanup path.", code: 6) }
        var current = self; var prefix: [String] = []
        for part in parts.dropLast() {
            prefix.append(part)
            let child = try current.child(part)
            guard let recorded = identities[prefix.joined(separator: "/")],
                  try child.identity() == (recorded.device, recorded.inode),
                  try child.cleanupFilesystem() == fsid else { throw NestError("Cleanup ancestor changed.", code: 6) }
            try child.requireOwnedDirectory(device: device)
            current = child
        }
        return (current, name)
    }
    func cleanupInventory(only name: String? = nil, matching expected: Manifest? = nil) throws -> CleanupTreePlan {
        let device = try identity().device, fsid = try cleanupFilesystem()
        var pending = try name.map { [$0] } ?? names(), entries: [Entry] = [], records: [String: CleanupTreePlan.Identity] = [:]
        var fileLinks: [String: String] = [:]
        while let path = pending.popLast() {
            let (parent, name) = try cleanupParent(path, identities: records, device: device, fsid: fsid)
            let st = try parent.entryStat(name), kind = st.st_mode & S_IFMT
            if SnapshotExclusion.directory(name,st.st_mode) {
                throw NestError("Excluded original disk Trash retained; recover it from this journal-pinned holding: \(Snapshot.diagnosticLabel(path)). No subtree was read or deleted.",code:6)
            }
            guard st.st_uid == getuid(), Paths.deviceID(st.st_dev) == device,
                  [S_IFDIR, S_IFREG, S_IFLNK].contains(kind) else { throw NestError("Unsafe cleanup entry; retained.", code: 6) }
            let flags = kind == S_IFREG ? st.st_flags & ~UInt32(UF_COMPRESSED) : st.st_flags
            guard flags & ~UInt32(UF_HIDDEN | UF_NODUMP) == 0 else { throw NestError("Unsupported cleanup flags; retained.", code: 6) }
            // Darwin's O_SYMLINK opens the link itself; combining it with
            // O_NOFOLLOW rejects the link instead of opening its metadata.
            let descriptor = openat(parent.fd, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (kind == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
            guard descriptor >= 0 else { throw NestError("Cannot open cleanup entry; retained.", code: 6) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { withExtendedLifetime(handle) {} }
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_dev == st.st_dev, before.st_ino == st.st_ino,
                  before.st_mode == st.st_mode else { throw NestError("Cleanup entry identity changed.", code: 6) }
            var entry = Entry(path: path, kind: kind == S_IFDIR ? "directory" : kind == S_IFREG ? "file" : "symlink", size: 0,
                mode: UInt16(st.st_mode & 0o7777), mtimeSeconds: 0, mtimeNanos: 0, checksum: "", attributes: [:], hardlink: nil, flags: flags, attributeBytes: 0)
            let count = flistxattr(descriptor, nil, 0, 0)
            guard count >= 0 else { throw NestError("Cannot inspect cleanup attributes.", code: 6) }
            if count > 0 {
                var buffer = [CChar](repeating: 0, count: count)
                guard flistxattr(descriptor, &buffer, count, 0) == count else { throw NestError("Cleanup attributes changed.", code: 6) }
                var index = 0
                while index < count {
                    let attribute = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!.advanced(by: index)) }
                    index += attribute.utf8.count + 1
                    if attribute == "com.apple.decmpfs" { continue }
                    let size = fgetxattr(descriptor, attribute, nil, 0, 0, 0)
                    guard size >= 0, size <= 1 << 20 else { throw NestError("Invalid cleanup attribute.", code: 6) }
                    var data = Data(count: size)
                    guard data.withUnsafeMutableBytes({ fgetxattr(descriptor, attribute, $0.baseAddress, size, 0, 0) }) == size else { throw NestError("Cleanup attribute changed.", code: 6) }
                    entry.attributes[attribute] = Snapshot.digest(data); entry.attributeBytes += UInt64(size + attribute.utf8.count)
                }
            }
            let record = CleanupTreePlan.Identity(path: path, device: device, inode: UInt64(st.st_ino), type: UInt16(kind))
            records[path] = record
            if kind == S_IFDIR {
                let directory = try parent.child(name)
                guard try directory.identity() == (device, UInt64(st.st_ino)), try directory.cleanupFilesystem() == fsid else { throw NestError("Cleanup crossed a mount.", code: 6) }
                pending += try directory.names().map { path + "/" + $0 }
            } else if kind == S_IFREG {
                entry.size = st.st_size; entry.mtimeSeconds = Int64(st.st_mtimespec.tv_sec); entry.mtimeNanos = Int64(st.st_mtimespec.tv_nsec)
                let prior = expected?.entries.first { $0.path == path }
                let scan = try SparseContent.scan(descriptor, size: st.st_size, legacy: prior.map { !$0.checksum.hasPrefix("sparse64-v1:") } ?? false)
                entry.checksum = scan.checksum; entry.allocatedBytes = scan.allocated
                if st.st_nlink > 1 { fileLinks[path] = "\(st.st_dev):\(st.st_ino)" }
            } else {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = readlinkat(parent.fd, name, &buffer, buffer.count)
                guard count >= 0, count < buffer.count else { throw NestError("Cleanup symlink changed.", code: 6) }
                entry.size = Int64(count); entry.checksum = Snapshot.digest(Data(buffer.prefix(count).map { UInt8(bitPattern: $0) }))
            }
            var after = stat()
            let named = try parent.entryStat(name)
            guard fstat(descriptor, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
                  after.st_size == before.st_size, after.st_mtimespec == before.st_mtimespec,
                  after.st_ctimespec == before.st_ctimespec, named.st_dev == after.st_dev, named.st_ino == after.st_ino else { throw NestError("Cleanup entry is being written; retained.", code: 6) }
            entries.append(entry)
        }
        entries.sort { $0.path < $1.path }
        var firstLinks: [String: String] = [:]
        // Snapshot.manifest assigns hardlink anchors during a sorted,
        // hierarchical walk. Flat path order differs for alpha/payload and
        // alpha-link, so derive anchors in component order before annotating.
        let linkPaths = fileLinks.keys.sorted {
            $0.split(separator: "/").lexicographicallyPrecedes($1.split(separator: "/"))
        }
        for path in linkPaths {
            if let key = fileLinks[path], firstLinks[key] == nil { firstLinks[key] = path }
        }
        for index in entries.indices {
            if let key = fileLinks[entries[index].path], let first = firstLinks[key] {
                entries[index].hardlink = first == entries[index].path ? nil : first
            }
        }
        return CleanupTreePlan(manifest: Manifest(entries: entries), identities: records.values.sorted { $0.path < $1.path })
    }
    func validateCleanupRemainder(_ actual: CleanupTreePlan, plan: CleanupTreePlan) throws {
        guard Set(plan.manifest.entries.map(\.path)).count == plan.manifest.entries.count,
              Set(plan.identities.map(\.path)).count == plan.identities.count else { throw NestError("Invalid cleanup plan; retained.", code: 6) }
        let expected = Dictionary(uniqueKeysWithValues: plan.manifest.entries.map { ($0.path, $0) })
        let identities = Dictionary(uniqueKeysWithValues: plan.identities.map { ($0.path, $0) })
        for var entry in actual.manifest.entries {
            guard var saved = expected[entry.path] else { throw NestError("Unknown cleanup entry; retained.", code: 6) }
            // A previously unlinked first hardlink changes only the canonical
            // path annotation. Content, metadata and recorded inode still match.
            entry.hardlink = nil; saved.hardlink = nil
            guard entry.matchesExpected(saved) else { throw NestError("Cleanup contents changed; retained.", code: 6) }
        }
        for identity in actual.identities {
            guard identities[identity.path] == identity else { throw NestError("Cleanup inode changed; retained.", code: 6) }
        }
    }
    func removeCleanupTree(from parent: DirectoryHandle, name: String, plan: CleanupTreePlan, device: UInt64, inode: UInt64, fsid: [Int32], validateAnchor: () throws -> Void, beforeUnlink: ((DirectoryHandle, String) throws -> Void)?) throws {
        try requireCleanupRoot(device: device, inode: inode, fsid: fsid)
        let actual = try cleanupInventory(matching: plan.manifest)
        try validateCleanupRemainder(actual, plan: plan)
        let identities = Dictionary(uniqueKeysWithValues: plan.identities.map { ($0.path, $0) })
        let expectedEntries = Dictionary(uniqueKeysWithValues: plan.manifest.entries.map { ($0.path, $0) })
        let ordered = actual.identities.sorted {
            let a = $0.path.split(separator: "/").count, b = $1.path.split(separator: "/").count
            return a == b ? $0.path > $1.path : a > b
        }
        for record in ordered {
            try validateAnchor()
            guard try parent.child(name).identity() == (device, inode), try parent.cleanupFilesystem() == fsid else { throw NestError("Cleanup root moved; stopped.", code: 6) }
            let (directory, leaf) = try cleanupParent(record.path, identities: identities, device: device, fsid: fsid)
            let now = try directory.entryStat(leaf)
            guard Paths.deviceID(now.st_dev) == record.device, UInt64(now.st_ino) == record.inode,
                  UInt16(now.st_mode & S_IFMT) == record.type else { throw NestError("Cleanup entry replaced; stopped.", code: 6) }
            var leafExpected = expectedEntries[record.path]
            leafExpected?.path = leaf
            let leafInventory = try directory.cleanupInventory(only: leaf, matching: leafExpected.map { Manifest(entries: [$0]) })
            guard leafInventory.manifest.entries.count == 1,
                  var expected = expectedEntries[record.path] else { throw NestError("Cleanup leaf gained entries; stopped.", code: 6) }
            var actualEntry = leafInventory.manifest.entries[0]
            expected.path = leaf; expected.hardlink = nil; actualEntry.hardlink = nil
            guard actualEntry.matchesExpected(expected) else { throw NestError("Cleanup leaf changed before unlink; stopped.", code: 6) }
            try beforeUnlink?(directory, leaf)
            guard unlinkat(directory.fd, leaf, now.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw NestError("Sibling cleanup unlink failed: \(String(cString: strerror(errno)))", code: 6) }
            try directory.sync()
        }
        try requireCleanupRoot(device: device, inode: inode, fsid: fsid)
        try validateAnchor()
        guard try parent.child(name).identity() == (device, inode), try names().isEmpty else { throw NestError("Cleanup root changed; retained.", code: 6) }
        try beforeUnlink?(parent, name)
        guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else { throw NestError("Sibling cleanup rmdir failed: \(String(cString: strerror(errno)))", code: 6) }
        try parent.sync()
    }
}
