import Foundation
import CryptoKit
import Darwin

// Authority for one coordinator-owned rename window, never a general manifest
// comparison mode. Intent is durable before mutation; an incomplete receipt is
// retained for review unless a v2 swap intent durably recorded both raw sides.
struct VerifiedRenameReceipt: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable { case evacuation, rollback, publication }
    struct Node: Codable, Equatable, Sendable {
        var path: String
        var device: UInt64
        var inode: UInt64
        var links: UInt64
        var mode: UInt16
        var owner: UInt32
        var group: UInt32
        var flags: UInt32
        var size: Int64
        var mtimeSeconds: Int64
        var mtimeNanos: Int64
        var ctimeSeconds: Int64
        var ctimeNanos: Int64
        init(_ path: String, _ st: stat) {
            self.path = path; device = Paths.deviceID(st.st_dev); inode = UInt64(st.st_ino)
            links = UInt64(st.st_nlink); mode = UInt16(st.st_mode)
            owner = st.st_uid; group = st.st_gid; flags = st.st_flags
            size = Int64(st.st_size); mtimeSeconds = Int64(st.st_mtimespec.tv_sec); mtimeNanos = Int64(st.st_mtimespec.tv_nsec)
            ctimeSeconds = Int64(st.st_ctimespec.tv_sec); ctimeNanos = Int64(st.st_ctimespec.tv_nsec)
        }
    }
    struct Observation: Codable, Equatable, Sendable {
        var manifest: Manifest
        var nodes: [Node]
        // Stat-only admission records for excluded top-level directories.
        // Their xattrs/accounting are outside the exclusion contract entirely.
        var opaque: [Entry]
    }
    var version = 1
    var operation: Operation
    var folder: UUID
    var session: UUID
    var wholeRoot: Bool
    var names: [String]
    var destinationDevice: UInt64
    var destinationInode: UInt64
    var destinationOwner: UInt32
    var destinationGroup: UInt32
    var before: Observation
    var after: Observation?
    var publicationSwap: PublicationSwap?

    static func observe(_ url: URL, matching: Manifest? = nil, verification: FileVerification? = nil) throws -> Observation {
        let root = try DirectoryHandle.open(url), cursor = DirectoryCursor(root)
        let manifest = try Snapshot.manifest(url, matching: matching, verification: verification)
        let names = try root.names()
        guard names.count < StorageModes.maximumRecords else { throw NestError("Rename namespace bound exceeded; retained.", code: 6) }
        let tops = Set(manifest.entries.map { String($0.path.split(separator: "/")[0]) })
        var opaque: [Entry] = []
        for name in names where !tops.contains(name) {
            let st = try root.entryStat(name)
            guard SnapshotExclusion.directory(name, st.st_mode) else { throw failure(name, "unknown entry") }
            opaque.append(try Snapshot.renameDirectoryMetadata(url.appendingPathComponent(name), path: name, info: st))
        }
        var rootStat = stat(); guard fstat(root.fd, &rootStat) == 0 else { throw failure(".", "root stat") }
        var nodes = [Node("", rootStat)]
        for path in (manifest.entries.map(\.path) + opaque.map(\.path)).sorted() {
            let (parent, name) = try cursor.parent(of: path)
            nodes.append(Node(path, try parent.entryStat(name)))
        }
        // Pin every observation to the same no-follow root and independent raw
        // readback. Nothing is changed to make an unreadable tree accessible.
        guard try root.identity() == DirectoryHandle.open(url).identity(),
              try Snapshot.manifest(url, matching: manifest) == manifest else { throw failure(".", "observation changed") }
        for node in nodes {
            let now: Node
            if node.path.isEmpty { var st = stat(); guard fstat(root.fd, &st) == 0 else { throw failure(".", "root stat") }; now = Node("", st) }
            else { let (parent, name) = try cursor.parent(of: node.path); now = Node(node.path, try parent.entryStat(name)) }
            guard now == node else { throw failure(node.path, "identity/metadata changed during readback") }
        }
        return Observation(manifest: manifest, nodes: nodes, opaque: opaque)
    }
    init(operation: Operation, folder: Folder, journal: Journal, source: URL,
         destination: DirectoryHandle, wholeRoot: Bool = false, matching: Manifest? = nil) throws {
        guard let session = journal.session else { throw Self.failure(".", "missing session") }
        self.operation = operation; self.folder = folder.id; self.session = session; self.wholeRoot = wholeRoot
        before = try Self.observe(source, matching: matching, verification: journal.fileVerification)
        names = wholeRoot ? [""] : try DirectoryHandle.open(source).names()
        let target = try destination.identity(); destinationDevice = target.device; destinationInode = target.inode
        var targetStat = stat(); guard fstat(destination.fd, &targetStat) == 0 else { throw Self.failure(".", "destination stat") }
        destinationOwner = targetStat.st_uid; destinationGroup = targetStat.st_gid
        try validate()
    }
    static func failure(_ path: String, _ reason: String) -> NestError {
        NestError("Verified rename at \(Snapshot.diagnosticLabel(path.isEmpty ? "." : path)): \(reason). Originals retained.", code: 6)
    }
    func validate() throws {
        func valid(_ path: String) -> Bool {
            path.isEmpty || (!path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 4096 &&
                path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
        }
        guard [1, 2].contains(version), (version == 2) == (publicationSwap != nil), destinationInode > 0, before.nodes.count <= StorageModes.maximumRecords,
              before.nodes.first?.path == "", Set(before.nodes.map(\.path)).count == before.nodes.count,
              before.manifest.publicRoot?.path == "", before.manifest.publicRoot?.kind == "directory",
              before.manifest.entries.count + before.opaque.count + 1 == before.nodes.count,
              before.nodes.allSatisfy({ valid($0.path) && $0.inode > 0 && $0.links > 0 && $0.size >= 0 &&
                  (0..<1_000_000_000).contains($0.mtimeNanos) && (0..<1_000_000_000).contains($0.ctimeNanos) }),
              Set(before.nodes.map(\.path)) == Set([""] + before.manifest.entries.map(\.path) + before.opaque.map(\.path)),
              names == names.sorted(), Set(names).count == names.count,
              (wholeRoot ? names == [""] : names.allSatisfy({ valid($0) && !$0.isEmpty && !$0.contains("/") })),
              wholeRoot || Set(names) == Set(before.nodes.dropFirst().map { String($0.path.split(separator: "/")[0]) }) else {
            throw Self.failure(".", "invalid rename receipt")
        }
        _ = try before.manifest.copyFidelityView()
        try validatePublicationSwap()
        if let after {
            guard after.manifest.publicRoot?.path == "", after.manifest.publicRoot?.kind == "directory" else { throw Self.failure(".", "missing raw completed root") }
            _ = try after.manifest.copyFidelityView()
            try compare(after)
        }
    }
    func bound(to folder: Folder, journal: Journal, operation: Operation) throws {
        try validate()
        guard self.folder == folder.id, session == journal.session, self.operation == operation,
              before.manifest.fileVerification == journal.fileVerification else { throw Self.failure(".", "receipt binding changed") }
        try boundPublicationSwap(to: folder, journal: journal)
    }
    // The exception applies only to the actual renamed inodes, including a
    // hardlink alias of one of them. All other raw fields remain exact.
    private func compare(_ observed: Observation, allowProvenanceChanges: Bool = true) throws {
        guard observed.manifest.fileVerification == before.manifest.fileVerification,
              observed.nodes.count == before.nodes.count,
              observed.nodes.map(\.path) == before.nodes.map(\.path) else { throw Self.failure(".", "namespace changed") }
        let renamedPaths = Set(names)
        let moved = Set(before.nodes.filter { wholeRoot ? $0.path.isEmpty : renamedPaths.contains($0.path) }.map { "\($0.device):\($0.inode)" })
        let allowed = Set(before.nodes.filter { moved.contains("\($0.device):\($0.inode)") }.map(\.path))
        for (prior, actual) in zip(before.nodes, observed.nodes) {
            if prior.path.isEmpty && !wholeRoot {
                guard actual.device == destinationDevice, actual.inode == destinationInode,
                      actual.owner == destinationOwner, actual.group == destinationGroup,
                      operation != .evacuation || actual.mode == UInt16(S_IFDIR | 0o700) else { throw Self.failure(".", "destination identity/owner/private mode changed") }
                continue
            }
            var normalized = actual
            if allowed.contains(prior.path) { normalized.ctimeSeconds = prior.ctimeSeconds; normalized.ctimeNanos = prior.ctimeNanos }
            guard normalized == prior else { throw Self.failure(prior.path, "inode/owner/mode/flags/link/ctime changed") }
        }
        func check(_ actual: Entry, _ prior: Entry) throws {
            var a = actual, b = prior
            if allowProvenanceChanges && allowed.contains(prior.path) {
                a = try Self.renameEntryView(a); b = try Self.renameEntryView(b)
            }
            guard a == b else { throw Self.failure(prior.path, Snapshot.mismatchDetail(Manifest(entries: [a]), Manifest(entries: [b]))) }
        }
        guard observed.manifest.entries.count == before.manifest.entries.count,
              observed.opaque.count == before.opaque.count else { throw Self.failure(".", "namespace changed") }
        for (a, b) in zip(observed.manifest.entries, before.manifest.entries) { try check(a, b) }
        // Opaque admission never reads xattrs and never uses copy/rename xattr
        // normalization. Its recorded stat fields and inode nodes remain exact.
        for (a, b) in zip(observed.opaque, before.opaque) {
            guard a == b else { throw Self.failure(b.path, "excluded directory admission changed") }
        }
        if wholeRoot {
            guard let a = observed.manifest.publicRoot, let b = before.manifest.publicRoot else { throw Self.failure(".", "missing public root") }
            if let swap = publicationSwap {
                try check(swap.directoryAfter.removing(from: a), swap.directoryBefore.removing(from: b))
            } else { try check(a, b) }
        }
    }
    private static func renameEntryView(_ entry: Entry) throws -> Entry {
        // Reuse measured accounting validation, not a payload length or format.
        try Manifest(entries: [entry]).copyFidelityView().entries[0]
    }
    mutating func complete(at url: URL) throws {
        guard after == nil else { throw Self.failure(".", "rename receipt already completed") }
        guard publicationSwap == nil else { throw Self.failure(".", "swap requires both raw after observations") }
        let observed = try Self.observe(url, matching: before.manifest)
        try compare(observed); after = observed
    }
    func verify(at url: URL) throws -> Manifest {
        try validate()
        guard let after else { throw Self.failure(".", "unacknowledged rename requires review") }
        guard publicationSwap == nil || publicationSwap?.destinationPath == url.path else { throw Self.failure(".", "swap readback path changed") }
        let actual = try Self.observe(url, matching: after.manifest)
        guard actual == after else { throw Self.failure(".", "raw post-rename observation changed") }
        return after.manifest
    }
    // Recovery only: missing completion grants no provenance exception. The
    // already-bound inodes and every raw manifest field must still match the
    // before observation. Only the actual moved inode's rename ctime can vary;
    // unrenamed descendants retain exact ctimes. This creates no after receipt.
    func verifyStrictIncomplete(at url: URL) throws -> Manifest {
        try validate()
        guard after == nil, publicationSwap == nil else { throw Self.failure(".", "expected strict non-swap incomplete rename intent") }
        let actual = try Self.observe(url, matching: before.manifest)
        try compare(actual, allowProvenanceChanges: false)
        return actual.manifest
    }
    // Reviewed legacy recovery is an acknowledgement of missing history, never
    // a completed rename receipt. Normalize only these locally supplied raw
    // root observations; the stored receipt and both observations stay intact.
    func validateReviewedPublication(_ actual: Observation, macl: MACL, displaced: SwapLink) throws {
        try validate()
        guard version == 1, operation == .publication, wholeRoot, after == nil,
              publicationSwap == nil, macl.digest == nil,
              let priorRoot = before.manifest.publicRoot, let actualRoot = actual.manifest.publicRoot,
              priorRoot.attributes[MACL.name] == displaced.macl.digest else {
            throw Self.failure(".", "not the narrowly supported legacy publication review")
        }
        var comparison = self, observed = actual
        comparison.before.manifest.publicRoot = try displaced.macl.removing(from: priorRoot)
        observed.manifest.publicRoot = try macl.removing(from: actualRoot)
        try comparison.compare(observed)
    }
    // Explicit null is not an absent completion, and an unknown version cannot
    // select legacy journal recovery. Encoding omits the pending after field.
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, operation, folder, session, wholeRoot, names, destinationDevice, destinationInode, destinationOwner, destinationGroup, before, after, publicationSwap }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); operation = try c.decode(Operation.self, forKey: .operation)
        if version == 2 { try Self.requireFields(decoder, required: [], allowed: Set(CodingKeys.allCases.map(\.rawValue))) }
        folder = try c.decode(UUID.self, forKey: .folder); session = try c.decode(UUID.self, forKey: .session)
        wholeRoot = try c.decode(Bool.self, forKey: .wholeRoot); names = try c.decode([String].self, forKey: .names)
        destinationDevice = try c.decode(UInt64.self, forKey: .destinationDevice); destinationInode = try c.decode(UInt64.self, forKey: .destinationInode)
        destinationOwner = try c.decode(UInt32.self, forKey: .destinationOwner); destinationGroup = try c.decode(UInt32.self, forKey: .destinationGroup)
        before = try c.decode(Observation.self, forKey: .before)
        after = c.contains(.after) ? try c.decode(Observation.self, forKey: .after) : nil
        publicationSwap = c.contains(.publicationSwap) ? try c.decode(PublicationSwap.self, forKey: .publicationSwap) : nil
        try validate()
    }
}

extension VerifiedRenameReceipt {
    private struct WireKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func requireFields(_ decoder: Decoder, required: Set<String>, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: allowed) else { throw failure(".", "unknown or missing swap evidence fields") }
    }
    // No grant bytes are stored or reapplied. This is measured no-follow evidence
    // for one pathname-preserving MACL exchange, not an xattr comparison policy.
    struct MACL: Codable, Equatable, Sendable {
        static let name = "com.apple.macl"
        var digest: String?
        var bytes: UInt64
        private enum CodingKeys: String, CodingKey { case digest, bytes }
        init(digest: String?, bytes: UInt64) { self.digest = digest; self.bytes = bytes }
        init(from decoder: Decoder) throws {
            try VerifiedRenameReceipt.requireFields(decoder, required: ["bytes"], allowed: ["digest", "bytes"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            digest = c.contains(.digest) ? try c.decode(String.self, forKey: .digest) : nil
            bytes = try c.decode(UInt64.self, forKey: .bytes)
            try validate()
        }
        func validate() throws {
            guard bytes <= 1 << 20, digest.map({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? (bytes == 0) else {
                throw VerifiedRenameReceipt.failure(".", "invalid measured MACL")
            }
        }
        static func observe(_ url: URL) throws -> MACL {
            let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            if count < 0 {
                guard errno == ENOATTR else { throw VerifiedRenameReceipt.failure(".", "cannot observe MACL") }
                return MACL(digest: nil, bytes: 0)
            }
            guard count <= 1 << 20 else { throw VerifiedRenameReceipt.failure(".", "MACL bound exceeded") }
            var data = Data(count: count)
            guard data.withUnsafeMutableBytes({ getxattr(url.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }) == count else {
                throw VerifiedRenameReceipt.failure(".", "MACL changed during observation")
            }
            return MACL(digest: Snapshot.digest(data), bytes: UInt64(count))
        }
        func removing(from entry: Entry) throws -> Entry {
            try validate()
            let cost = digest == nil ? 0 : bytes + UInt64(Self.name.utf8.count)
            guard entry.attributes[Self.name] == digest, cost <= entry.attributeBytes else {
                throw VerifiedRenameReceipt.failure(".", "MACL observation/accounting disagrees")
            }
            var result = entry; result.attributes.removeValue(forKey: Self.name); result.attributeBytes -= cost
            return result
        }
    }
    struct SwapLink: Codable, Equatable, Sendable {
        var node: Node
        var entry: Entry
        var macl: MACL
        private enum CodingKeys: String, CodingKey { case node, entry, macl }
        init(node: Node, entry: Entry, macl: MACL) { self.node = node; self.entry = entry; self.macl = macl }
        init(from decoder: Decoder) throws {
            try VerifiedRenameReceipt.requireFields(decoder, required: ["node", "entry", "macl"], allowed: ["node", "entry", "macl"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            node = try c.decode(Node.self, forKey: .node); entry = try c.decode(Entry.self, forKey: .entry); macl = try c.decode(MACL.self, forKey: .macl)
        }
        static func observe(_ url: URL) throws -> SwapLink {
            let parent = try DirectoryHandle.open(url.deletingLastPathComponent()), name = url.lastPathComponent
            let prior = Node("", try parent.entryStat(name))
            guard prior.mode & UInt16(S_IFMT) == UInt16(S_IFLNK), prior.links == 1,
                  prior.owner == getuid(), prior.group == getgid() else { throw VerifiedRenameReceipt.failure(".", "unsafe swap link") }
            try Snapshot.supportedSecurity(url, parent.entryStat(name))
            var target = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
            let count = readlinkat(parent.fd, name, &target, target.count - 1)
            guard count > 0, count < target.count - 1 else { throw VerifiedRenameReceipt.failure(".", "cannot read swap link") }
            let destination = String(decoding: target.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            var entry = Entry(path: "", kind: "symlink", size: prior.size, mode: prior.mode & 0o7777,
                mtimeSeconds: prior.mtimeSeconds, mtimeNanos: prior.mtimeNanos, checksum: destination,
                attributes: try Snapshot.attributes(url), flags: prior.flags, attributeBytes: 0)
            try Snapshot.accountAttributes(url, entry: &entry)
            let macl = try MACL.observe(url)
            _ = try macl.removing(from: entry)
            guard prior == Node("", try parent.entryStat(name)), try Snapshot.attributes(url) == entry.attributes,
                  try MACL.observe(url) == macl,
                  try DirectoryHandle.open(url.deletingLastPathComponent()).identity() == parent.identity() else {
                throw VerifiedRenameReceipt.failure(".", "swap link changed during observation")
            }
            return SwapLink(node: prior, entry: entry, macl: macl)
        }
    }
    struct PublicationSwap: Codable, Equatable, Sendable {
        var sourcePath: String
        var destinationPath: String
        var sourceParent: LinkedFolderLayout.Identity
        var directoryBefore: MACL
        // Expected pathname grant, independently measured again after the swap.
        var directoryAfter: MACL
        var linkBefore: SwapLink
        var linkAfter: SwapLink?
        private enum CodingKeys: String, CodingKey { case sourcePath, destinationPath, sourceParent, directoryBefore, directoryAfter, linkBefore, linkAfter }
        init(sourcePath: String, destinationPath: String, sourceParent: LinkedFolderLayout.Identity, directoryBefore: MACL, directoryAfter: MACL, linkBefore: SwapLink) {
            self.sourcePath = sourcePath; self.destinationPath = destinationPath; self.sourceParent = sourceParent
            self.directoryBefore = directoryBefore; self.directoryAfter = directoryAfter; self.linkBefore = linkBefore
        }
        init(from decoder: Decoder) throws {
            let required: Set<String> = ["sourcePath", "destinationPath", "sourceParent", "directoryBefore", "directoryAfter", "linkBefore"]
            try VerifiedRenameReceipt.requireFields(decoder, required: required, allowed: required.union(["linkAfter"]))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sourcePath = try c.decode(String.self, forKey: .sourcePath); destinationPath = try c.decode(String.self, forKey: .destinationPath)
            sourceParent = try c.decode(LinkedFolderLayout.Identity.self, forKey: .sourceParent)
            directoryBefore = try c.decode(MACL.self, forKey: .directoryBefore); directoryAfter = try c.decode(MACL.self, forKey: .directoryAfter)
            linkBefore = try c.decode(SwapLink.self, forKey: .linkBefore)
            linkAfter = c.contains(.linkAfter) ? try c.decode(SwapLink.self, forKey: .linkAfter) : nil
        }
    }
    static func publicationSource(_ journal: Journal) throws -> URL {
        guard let layout = journal.managedLink else { throw failure(".", "missing swap layout") }
        if layout.restoration == .original { return layout.originalDataURL }
        guard layout.restoration == .checkpoint, let stage = journal.restoreStage else { throw failure(".", "missing swap source") }
        return URL(fileURLWithPath: stage).appendingPathExtension("data")
    }
    func boundPublicationSwap(to folder: Folder, journal: Journal) throws {
        guard let swap = publicationSwap else { return }
        guard let layout = journal.managedLink, layout.folderID == folder.id, layout.session == session,
              [.publishing, .restored].contains(layout.stage), layout.originalPath == folder.path,
              journal.originalRename?.after != nil, journal.restoreManifest == (after?.manifest ?? before.manifest),
              operation == (layout.restoration == .original ? .rollback : .publication),
              swap.destinationPath == folder.path, swap.sourcePath == (try Self.publicationSource(journal)).path,
              layout.parent.device == destinationDevice, layout.parent.inode == destinationInode,
              layout.link?.device == swap.linkBefore.node.device, layout.link?.inode == swap.linkBefore.node.inode,
              layout.mountPath == swap.linkBefore.entry.checksum,
              layout.restored?.device == before.nodes.first?.device, layout.restored?.inode == before.nodes.first?.inode,
              swap.sourceParent == (layout.restoration == .original ? layout.holding : layout.parent) else {
            throw Self.failure(".", "swap journal/path/identity binding changed")
        }
    }
    mutating func preparePublicationSwap(source: URL, destination: URL, folder: Folder, journal: Journal) throws {
        guard version == 1, publicationSwap == nil, after == nil else { throw Self.failure(".", "swap intent already recorded") }
        let link = try SwapLink.observe(destination)
        let macl = try MACL.observe(source)
        guard let root = before.manifest.publicRoot else { throw Self.failure(".", "missing swap root") }
        _ = try macl.removing(from: root)
        publicationSwap = PublicationSwap(sourcePath: source.path, destinationPath: destination.path,
            sourceParent: try .init(DirectoryHandle.open(source.deletingLastPathComponent()).identity()),
            directoryBefore: macl, directoryAfter: link.macl, linkBefore: link)
        version = 2
        try bound(to: folder, journal: journal, operation: operation)
        try verifyPublicationSwapPreflight(folder: folder, journal: journal)
    }
    func verifyPublicationSwapPreflight(folder: Folder, journal: Journal) throws {
        try bound(to: folder, journal: journal, operation: operation)
        guard let swap = publicationSwap, after == nil,
              try Self.observe(URL(fileURLWithPath: swap.sourcePath), matching: before.manifest) == before,
              try MACL.observe(URL(fileURLWithPath: swap.sourcePath)) == swap.directoryBefore,
              try SwapLink.observe(URL(fileURLWithPath: swap.destinationPath)) == swap.linkBefore else {
            throw Self.failure(".", "raw swap preflight changed")
        }
        try swap.sourceParent.verify(DirectoryHandle.open(URL(fileURLWithPath: swap.sourcePath).deletingLastPathComponent()))
        let parent = try DirectoryHandle.open(URL(fileURLWithPath: swap.destinationPath).deletingLastPathComponent())
        var st = stat()
        guard try parent.identity() == (destinationDevice, destinationInode), fstat(parent.fd, &st) == 0,
              st.st_uid == destinationOwner, st.st_gid == destinationGroup else { throw Self.failure(".", "swap parent changed") }
    }
    func validatePublicationSwap() throws {
        guard let swap = publicationSwap else { return }
        guard wholeRoot, operation != .evacuation, swap.sourcePath != swap.destinationPath,
              [swap.sourcePath, swap.destinationPath].allSatisfy({ $0.hasPrefix("/") && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 && !$0.contains("\0") }),
              swap.sourceParent.inode > 0, swap.sourceParent.device == destinationDevice,
              before.nodes.first?.device == destinationDevice,
              swap.linkBefore.node.device == destinationDevice,
              swap.linkBefore.node.inode != before.nodes.first?.inode,
              swap.linkBefore.node.mode & UInt16(S_IFMT) == UInt16(S_IFLNK), swap.linkBefore.node.links == 1,
              swap.linkBefore.node.owner == getuid(), swap.linkBefore.node.group == getgid(),
              swap.directoryAfter == swap.linkBefore.macl, (after == nil) == (swap.linkAfter == nil),
              let root = before.manifest.publicRoot else { throw Self.failure(".", "invalid publication swap") }
        _ = try swap.directoryBefore.removing(from: root)
        _ = try swap.linkBefore.macl.removing(from: swap.linkBefore.entry)
        if let link = swap.linkAfter, let after {
            guard link.macl == swap.directoryBefore, let root = after.manifest.publicRoot else { throw Self.failure(".", "MACL did not remain at both pathnames") }
            _ = try swap.directoryAfter.removing(from: root)
            var node = link.node
            node.ctimeSeconds = swap.linkBefore.node.ctimeSeconds; node.ctimeNanos = swap.linkBefore.node.ctimeNanos
            guard node == swap.linkBefore.node,
                  try Self.renameEntryView(link.macl.removing(from: link.entry)) == Self.renameEntryView(swap.linkBefore.macl.removing(from: swap.linkBefore.entry)) else {
                throw Self.failure(".", "displaced swap link identity/raw metadata changed")
            }
        }
    }
    mutating func completePublicationSwap(folder: Folder, journal: Journal) throws {
        try bound(to: folder, journal: journal, operation: operation)
        guard let swap = publicationSwap, after == nil else { throw Self.failure(".", "missing pending swap authority") }
        try swap.sourceParent.verify(DirectoryHandle.open(URL(fileURLWithPath: swap.sourcePath).deletingLastPathComponent()))
        let parent = try DirectoryHandle.open(URL(fileURLWithPath: swap.destinationPath).deletingLastPathComponent())
        var st = stat()
        guard try parent.identity() == (destinationDevice, destinationInode), fstat(parent.fd, &st) == 0,
              st.st_uid == destinationOwner, st.st_gid == destinationGroup else { throw Self.failure(".", "swap destination parent changed") }
        var completed = self
        completed.after = try Self.observe(URL(fileURLWithPath: swap.destinationPath), matching: before.manifest)
        guard try MACL.observe(URL(fileURLWithPath: swap.destinationPath)) == swap.directoryAfter else { throw Self.failure(".", "published MACL relationship changed") }
        completed.publicationSwap?.linkAfter = try SwapLink.observe(URL(fileURLWithPath: swap.sourcePath))
        try completed.validate()
        self = completed
    }
    // Crash recovery may complete only a v2 intent that recorded BOTH sides
    // before mutation. A legacy v1 incomplete intent is never adopted here.
    func verifyDisplacedSwapLink(at url: URL) throws {
        guard let swap = publicationSwap else { return }
        try validate()
        try swap.sourceParent.verify(DirectoryHandle.open(url.deletingLastPathComponent()))
        guard url.path == swap.sourcePath, let expected = swap.linkAfter,
              try SwapLink.observe(url) == expected else { throw Self.failure(".", "raw post-swap link changed") }
    }
    func matchesPublicationCopy(_ published: Manifest, of source: Manifest) throws -> Bool {
        try validate()
        guard let after, after.manifest == published else { return false }
        // validate proves the exact swap relationship. Bind the unmodified raw
        // copy source to the revision; final readback still uses raw after.
        return try (publicationSwap == nil ? published : before.manifest).matchesCopy(of: source)
    }
}

/// An in-memory, single-use review. Only Engine can issue it; no CLI command
/// constructs or automatically accepts one. Its binding is immutable.
public struct LegacyPublicationReview: Sendable {
    struct ControlRecord: Equatable, Sendable {
        let bytes: Data
        let node: VerifiedRenameReceipt.Node
    }
    public let token: UUID
    public var folderPath: String { evidence.folder.path }
    public var revision: String { evidence.latest.id }
    public var initialRevision: String { evidence.initial.id }
    public var retainedOriginalPath: String { evidence.layout.originalDataURL.path }
    public var retainedLinkPath: String { evidence.stagePath + ".data" }
    public let snapshotPath: String
    let evidence: ReviewedPublicationEvidence
    let journalControl: ControlRecord
    let configurationControl: ControlRecord
    var journalBytes: Data { journalControl.bytes }
}

// Durable acknowledgement, deliberately distinct from VerifiedRenameReceipt.
// The raw incomplete receipt is also preserved in originalJournal byte-for-byte.
struct ReviewedPublicationEvidence: Codable, Equatable, Sendable {
    struct Revision: Codable, Equatable, Sendable {
        let id: String
        let logical: Manifest
        let materialized: Manifest
        let raw: VerifiedRenameReceipt.Observation
        fileprivate enum CodingKeys: String, CodingKey, CaseIterable { case id, logical, materialized, raw }

        func validate() throws {
            try logical.validateVerification(); try materialized.validateVerification(); try raw.manifest.validateVerification()
            guard UUID(uuidString: id) != nil, logical.fileVerification == .sha256,
                  materialized.fileVerification == .sha256, materialized.matchesExpected(logical),
                  raw.manifest.fileVerification == .sha256, raw.opaque.isEmpty,
                  let root = raw.manifest.publicRoot, root.path.isEmpty, root.mode == 0o700,
                  raw.nodes.count == raw.manifest.entries.count + 1,
                  raw.nodes.map(\.path) == [""] + raw.manifest.entries.map(\.path),
                  Set(raw.nodes.map(\.path)).count == raw.nodes.count else { throw Self.invalid() }
            _ = try StorageModes(materialized)
            _ = try StorageModes(raw.manifest)
            _ = try raw.manifest.copyFidelityView()
            let rootNode = raw.nodes[0]
            for (node, entry) in zip(raw.nodes, [root] + raw.manifest.entries) {
                let kind = entry.kind == "directory" ? S_IFDIR : entry.kind == "file" ? S_IFREG : S_IFLNK
                guard node.inode > 0, node.links > 0, node.size >= 0,
                      node.device == rootNode.device, node.owner == rootNode.owner, node.group == rootNode.group,
                      node.mode & UInt16(S_IFMT) == UInt16(kind), node.mode & 0o7777 == entry.mode,
                      node.flags & ~UInt32(entry.kind == "file" ? UF_COMPRESSED : 0) == entry.flags,
                      (0..<1_000_000_000).contains(node.mtimeNanos), (0..<1_000_000_000).contains(node.ctimeNanos),
                      entry.kind == "directory" || node.size == entry.size,
                      entry.kind != "file" || (node.mtimeSeconds == entry.mtimeSeconds && node.mtimeNanos == entry.mtimeNanos) else { throw Self.invalid() }
            }
            let controls = raw.manifest.entries.filter { $0.path != "data" && !$0.path.hasPrefix("data/") }
            let names = Set(controls.map(\.path))
            guard names == ["manifest.json"] || names == ["manifest.json", "modes.bin"],
                  controls.allSatisfy({ $0.kind == "file" && $0.mode == 0o600 && $0.hardlink == nil && $0.size > 0 && $0.size <= 64 << 20 }),
                  let dataRoot = raw.manifest.entries.first(where: { $0.path == "data" }), dataRoot.kind == "directory" else { throw Self.invalid() }
            // The wrapper/control-file hashes are diagnostic raw readback, not
            // authentication of original manifest.json bytes (which are not
            // embedded here and may predate relocation/legacy compatibility).
            // Only the data subtree, projected through the existing physical
            // mode policy, binds raw payload/metadata to the logical evidence.
            func relative(_ entry: Entry) throws -> Entry {
                var result = entry
                result.path = entry.path == "data" ? "" : String(entry.path.dropFirst(5))
                if let anchor = entry.hardlink {
                    guard anchor.hasPrefix("data/") else { throw Self.invalid() }
                    result.hardlink = String(anchor.dropFirst(5))
                }
                return result
            }
            let physical = try Manifest(entries: raw.manifest.entries.filter { $0.path.hasPrefix("data/") }.map(relative), publicRoot: relative(dataRoot))
            let observed = try names.contains("modes.bin") ? StorageModes(materialized).projecting(physical) : physical
            guard observed.matchesExpected(materialized) else { throw Self.invalid() }
        }
        private static func invalid() -> NestError { NestError("Reviewed snapshot raw/logical/materialized evidence is inconsistent; retained.", code: 6) }
    }
    let folder: Folder
    let originalJournal: Data
    let layout: LinkedFolderLayout
    let stagePath: String
    let parent: VerifiedRenameReceipt.Node
    let stage: VerifiedRenameReceipt.Node
    let holding: VerifiedRenameReceipt.Node
    let published: VerifiedRenameReceipt.Observation
    let publishedMACL: VerifiedRenameReceipt.MACL
    let displaced: VerifiedRenameReceipt.SwapLink
    let original: VerifiedRenameReceipt.Observation
    let initial: Revision
    let latest: Revision
    fileprivate enum CodingKeys: String, CodingKey, CaseIterable { case folder, originalJournal, layout, stagePath, parent, stage, holding, published, publishedMACL, displaced, original, initial, latest }

    func originalState(fixtureRoot: URL?) throws -> Journal {
        guard originalJournal.count <= 64 << 20,
              let object = try JSONSerialization.jsonObject(with: originalJournal) as? [String: Any],
              object["reviewedRecovery"] == nil else { throw NestError("Invalid original reviewed-recovery record; retained.", code: 6) }
        let decoder = JSONDecoder()
        if let fixtureRoot { decoder.userInfo[LinkedFolderLayout.decoderRootKey] = fixtureRoot }
        return try decoder.decode(Journal.self, from: originalJournal)
    }
    func validate(fixtureRoot: URL?) throws {
        try initial.validate(); try latest.validate()
        let base = try originalState(fixtureRoot: fixtureRoot)
        guard base.managedLink == layout, layout.stage == .publishing, layout.restoration == .checkpoint,
              layout.folderID == folder.id, layout.originalPath == folder.path,
              base.phase != .idle, base.populationVerified, base.fileVerification == .sha256,
              base.nativeTmpfs?.managedUnmount == true || (fixtureRoot != nil && layout.version == 1),
              folder.options.sync, base.restoreRevision == latest.id, base.revision == latest.id,
              base.initialRevision == initial.id, base.restoreStage == stagePath,
              base.restoreStageDevice == stage.device, base.restoreStageInode == stage.inode,
              base.restoreDataDevice == layout.restored?.device, base.restoreDataInode == layout.restored?.inode,
              base.restoreManifest == base.publicationRename?.before.manifest,
              let receipt = base.publicationRename, let evacuation = base.originalRename,
              evacuation.after == original, evacuation.folder == folder.id, evacuation.session == layout.session,
              layout.source.device == original.nodes.first?.device, layout.source.inode == original.nodes.first?.inode,
              layout.restored?.device == published.nodes.first?.device, layout.restored?.inode == published.nodes.first?.inode,
              layout.parent.device == parent.device, layout.parent.inode == parent.inode,
              layout.holding?.device == holding.device, layout.holding?.inode == holding.inode,
              layout.link?.device == displaced.node.device, layout.link?.inode == displaced.node.inode,
              displaced.entry.checksum == layout.mountPath,
              receipt.destinationDevice == parent.device, receipt.destinationInode == parent.inode,
              receipt.destinationOwner == parent.owner, receipt.destinationGroup == parent.group,
              try receipt.before.manifest.matchesCopy(of: latest.materialized),
              try evacuation.before.manifest.matchesCopy(of: initial.materialized),
              initial.id != latest.id || initial == latest else {
            throw NestError("Reviewed recovery evidence does not bind the original transaction and committed snapshots; retained.", code: 6)
        }
        try receipt.bound(to: folder, journal: base, operation: .publication)
        try receipt.validateReviewedPublication(published, macl: publishedMACL, displaced: displaced)
    }
}

struct ReviewedRecoveryAcknowledgement: Codable, Equatable, Sendable {
    struct Acceptance: Codable, Equatable, Sendable {
        let token: UUID
        let date: Date
        let acceptsMissingHistoricRecord: Bool
        fileprivate enum CodingKeys: String, CodingKey, CaseIterable { case token, date, acceptsMissingHistoricRecord }
    }
    var version = 1
    // Keep large immutable evidence off every Journal's inline representation,
    // including nil acknowledgements in ordinary transaction debug frames.
    // Acceptance history and completion remain independent value/COW state.
    private final class EvidenceBox: Encodable, Sendable {
        let value: ReviewedPublicationEvidence
        init(_ value: ReviewedPublicationEvidence) { self.value = value }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }
    private let evidenceBox: EvidenceBox
    var evidence: ReviewedPublicationEvidence { evidenceBox.value }
    var acceptances: [Acceptance]
    var completedAt: Date?
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, evidence, acceptances, completedAt }
    init(evidence: ReviewedPublicationEvidence, acceptance: Acceptance) { evidenceBox = EvidenceBox(evidence); acceptances = [acceptance] }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.evidence == rhs.evidence && lhs.acceptances == rhs.acceptances && lhs.completedAt == rhs.completedAt
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(evidenceBox, forKey: .evidence)
        try c.encode(acceptances, forKey: .acceptances); try c.encodeIfPresent(completedAt, forKey: .completedAt)
    }
    init(from decoder: Decoder) throws {
        try ReviewedEvidenceFields.require(decoder, required: ["version", "evidence", "acceptances"], allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        evidenceBox = try EvidenceBox(c.decode(ReviewedPublicationEvidence.self, forKey: .evidence))
        acceptances = try c.decode([Acceptance].self, forKey: .acceptances)
        completedAt = c.contains(.completedAt) ? try c.decode(Date.self, forKey: .completedAt) : nil
        guard version == 1, !acceptances.isEmpty, acceptances.count <= 128,
              acceptances.allSatisfy({ $0.acceptsMissingHistoricRecord && $0.date.timeIntervalSince1970.isFinite }),
              Set(acceptances.map(\.token)).count == acceptances.count else {
            throw NestError("Invalid explicit reviewed recovery acceptance; retained.", code: 6)
        }
        guard completedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= acceptances.last!.date }) ?? true else {
            throw NestError("Invalid reviewed recovery completion date; retained.", code: 6)
        }
        try evidence.validate(fixtureRoot: decoder.userInfo[LinkedFolderLayout.decoderRootKey] as? URL)
    }
    func validate(journal: Journal, fixtureRoot: URL?) throws {
        var base = try evidence.originalState(fixtureRoot: fixtureRoot), actual = journal
        base.updated = actual.updated
        actual.reviewedRecovery = nil
        if completedAt != nil {
            base.managedLink?.stage = .restored; base.managedLink?.mountReleased = true
            base.phase = .idle; base.mountedDevice = nil; base.socket = nil; base.lastError = nil
            base.nativeTmpfs?.quiescence = nil; base.nativeTmpfs?.periodicAuthorization = nil
            base.quiescedRevision = nil; base.quiescedSession = nil
            base.cleanupWarning = retentionNotice
        }
        guard actual == base else { throw NestError("Reviewed recovery journal diverged from its acknowledged transaction; retained.", code: 6) }
    }
    var retentionNotice: String {
        "Reviewed recovery completed; historical pre-swap link metadata remains unavailable. Backups and evidence retained. Original: \(evidence.layout.originalDataURL.path). Displaced link: \(evidence.stagePath).data. Snapshots: initial \(evidence.initial.id), latest \(evidence.latest.id). Automatic cleanup and remount are paused; explicit RESET can delete managed snapshots/records but preserves these external recovery folders."
    }
}

// Strictness is deliberately confined to these new acknowledgement-owned
// types. Historical Journal/Manifest/Entry decoders keep their existing policy.
private enum ReviewedEvidenceFields {
    private struct Key: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func require(_ decoder: Decoder, required: Set<String>, allowed: Set<String>) throws {
        let c = try decoder.container(keyedBy: Key.self), keys = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: allowed) else { throw NestError("Unknown or missing reviewed recovery evidence fields; retained.", code: 6) }
    }
}
extension ReviewedPublicationEvidence {
    init(from decoder: Decoder) throws {
        let fields = Set(CodingKeys.allCases.map(\.rawValue))
        try ReviewedEvidenceFields.require(decoder, required: fields, allowed: fields)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decode(Folder.self, forKey: .folder); originalJournal = try c.decode(Data.self, forKey: .originalJournal)
        layout = try c.decode(LinkedFolderLayout.self, forKey: .layout); stagePath = try c.decode(String.self, forKey: .stagePath)
        parent = try c.decode(VerifiedRenameReceipt.Node.self, forKey: .parent); stage = try c.decode(VerifiedRenameReceipt.Node.self, forKey: .stage)
        holding = try c.decode(VerifiedRenameReceipt.Node.self, forKey: .holding); published = try c.decode(VerifiedRenameReceipt.Observation.self, forKey: .published)
        publishedMACL = try c.decode(VerifiedRenameReceipt.MACL.self, forKey: .publishedMACL); displaced = try c.decode(VerifiedRenameReceipt.SwapLink.self, forKey: .displaced)
        original = try c.decode(VerifiedRenameReceipt.Observation.self, forKey: .original)
        initial = try c.decode(Revision.self, forKey: .initial); latest = try c.decode(Revision.self, forKey: .latest)
    }
}
extension ReviewedPublicationEvidence.Revision {
    init(from decoder: Decoder) throws {
        let fields = Set(CodingKeys.allCases.map(\.rawValue))
        try ReviewedEvidenceFields.require(decoder, required: fields, allowed: fields)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); logical = try c.decode(Manifest.self, forKey: .logical)
        materialized = try c.decode(Manifest.self, forKey: .materialized); raw = try c.decode(VerifiedRenameReceipt.Observation.self, forKey: .raw)
    }
}
extension ReviewedRecoveryAcknowledgement.Acceptance {
    init(from decoder: Decoder) throws {
        let fields = Set(CodingKeys.allCases.map(\.rawValue))
        try ReviewedEvidenceFields.require(decoder, required: fields, allowed: fields)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(UUID.self, forKey: .token); date = try c.decode(Date.self, forKey: .date)
        acceptsMissingHistoricRecord = try c.decode(Bool.self, forKey: .acceptsMissingHistoricRecord)
    }
}

extension Snapshot {
    // Excluded roots are admitted by no-follow stat only. Do not open for
    // reading, list/get xattrs, chmod, or descend into this directory.
    static func renameDirectoryMetadata(_ url: URL, path: String, info: stat) throws -> Entry {
        Entry(path: path, kind: "directory", size: 0, mode: UInt16(info.st_mode & 0o7777),
              mtimeSeconds: 0, mtimeNanos: 0, checksum: "", attributes: [:],
              hardlink: nil, flags: info.st_flags, attributeBytes: 0)
    }
}

public struct Entry: Codable, Equatable, Sendable {
    public var path: String
    public var kind: String
    public var size: Int64
    public var mode: UInt16
    public var mtimeSeconds: Int64
    public var mtimeNanos: Int64
    public var checksum: String
    public var attributes: [String: String]
    public var hardlink: String?
    public var flags: UInt32
    public var attributeBytes: UInt64
    public var allocatedBytes: UInt64? = nil
    // Observed name + value cost; nil only in older immutable records.
    public var provenanceBytes: UInt64? = nil
    // Directional compatibility is allowed only when the EXPECTED old record
    // predates allocatedBytes. Equatable itself is exact (synthesized).
    func matchesExpected(_ expected: Entry) -> Bool {
        var observed = self
        if expected.allocatedBytes == nil { observed.allocatedBytes = nil }
        if expected.provenanceBytes == nil { observed.provenanceBytes = nil }
        return observed == expected
    }

}
public struct Manifest: Codable, Equatable, Sendable {
    public var entries: [Entry]
    // Absent in legacy manifests: their contract remains exactly the entry list.
    // The data root carries public metadata; its enclosing revision stays 0700.
    public var publicRoot: Entry? = nil
    public var fileVerification = FileVerification.sha256
    public init(entries: [Entry], publicRoot: Entry? = nil, fileVerification: FileVerification = .sha256) {
        self.entries = entries; self.publicRoot = publicRoot; self.fileVerification = fileVerification
    }
    private enum CodingKeys: String, CodingKey { case entries, publicRoot, fileVerification }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([Entry].self, forKey: .entries)
        publicRoot = try c.decodeIfPresent(Entry.self, forKey: .publicRoot)
        fileVerification = c.contains(.fileVerification) ? try c.decode(FileVerification.self, forKey: .fileVerification) : .sha256
        try validateVerification()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries); try c.encodeIfPresent(publicRoot, forKey: .publicRoot)
        // Preserve canonical bytes used by historical publication receipts.
        if fileVerification != .sha256 { try c.encode(fileVerification, forKey: .fileVerification) }
    }
    func validateVerification() throws {
        for entry in entries where entry.kind == "file" {
            let digest = entry.checksum.hasPrefix("sparse64-v1:") ? String(entry.checksum.dropFirst(12)) : entry.checksum
            let validSHA = digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            guard fileVerification == .sha256 ? validSHA : entry.checksum.isEmpty else {
                throw NestError("File checksum contradicts snapshot verification policy; retained.", code: 6)
            }
        }
    }
    public func matchesExpected(_ expected: Manifest) -> Bool {
        contentsMatchExpected(expected) && (expected.publicRoot == nil || publicRoot?.matchesExpected(expected.publicRoot!) == true)
    }
    // Holding directories have private root permissions, separately from their
    // original public root. Only callers that verify that container use this.
    func contentsMatchExpected(_ expected: Manifest) -> Bool {
        fileVerification == expected.fileVerification && entries.count == expected.entries.count && zip(entries, expected.entries).allSatisfy { $0.matchesExpected($1) }
    }
    // Re-anchor each hardlink class when a restore has moved only some top-level
    // entries. This preserves equality of inode partitions within each remainder.
    func selecting(topNames: Set<String>) -> Manifest {
        var selected = entries.filter { topNames.contains(String($0.path.split(separator: "/")[0])) }
        var anchors: [String: String] = [:]
        let walkOrder = selected.indices.sorted { selected[$0].path.split(separator: "/").lexicographicallyPrecedes(selected[$1].path.split(separator: "/")) }
        for i in walkOrder where selected[i].kind == "file" {
            let group = selected[i].hardlink ?? selected[i].path
            selected[i].hardlink = anchors[group]
            if anchors[group] == nil { anchors[group] = selected[i].path }
        }
        return Manifest(entries: selected, publicRoot: publicRoot, fileVerification: fileVerification)
    }
    // Only distinct copy instances may differ in OS-managed provenance. Both
    // operands must be contemporary observations with measured byte costs.
    func matchesCopy(of source: Manifest) throws -> Bool {
        try copyFidelityView().matchesExpected(source.copyFidelityView())
    }
    func copyFidelityView() throws -> Manifest {
        func entry(_ value: Entry) throws -> Entry {
            var e = value
            guard let cost = e.provenanceBytes,
                  (e.attributes[Snapshot.provenanceName] == nil ? cost == 0 : (cost >= UInt64(Snapshot.provenanceName.utf8.count) && cost <= UInt64(1024 * 1024 + Snapshot.provenanceName.utf8.count))),
                  cost <= e.attributeBytes else { throw NestError("Missing or invalid observed provenance accounting.", code: 6) }
            e.attributes.removeValue(forKey: Snapshot.provenanceName)
            e.attributeBytes -= cost; e.provenanceBytes = 0
            return e
        }
        return try Manifest(entries: entries.map(entry), publicRoot: publicRoot.map(entry), fileVerification: fileVerification)
    }
    public var metadataEstimate: UInt64 {
        entries.reduce(1024 + UInt64((publicRoot?.attributes.count ?? 0) * 256)) { bytes, entry in
            bytes + UInt64(entry.hardlink == nil ? 2048 : 512) + UInt64((entry.path as NSString).lastPathComponent.utf8.count) + UInt64(entry.attributes.count * 256)
        }
    }
    static func metadataBudget(capacity: UInt64) -> UInt64 { max(65536, capacity / 4) }
    public func preflight(capacity: UInt64) throws {
        guard entries.lazy.filter({ $0.hardlink == nil }).count < 100000 else { throw NestError("Snapshot admission node limit is 100000 including the root. No files were moved.", code: 6) }
        let logicalRequired = allocatedEstimate, metadataRequired = metadataEstimate
        let metadataAllowed = Self.metadataBudget(capacity: capacity)
        guard logicalRequired > capacity || metadataRequired > metadataAllowed else { return }
        let files = entries.lazy.filter { $0.kind == "file" }.count
        let attributes = entries.reduce(0) { $0 + $1.attributes.count }
        let detail = "\(entries.count) entries, \(files) regular files, \(attributes) extended attributes"
        if logicalRequired > capacity {
            throw NestError("Source exceeds logical capacity: requires \(logicalRequired) bytes; allowed \(capacity) bytes (\(detail)). Conservative snapshot admission rounds files to 64 KiB; live kernel usage is measured separately. Increase capacity before mounting; no files were moved.", code: 6)
        }
        throw NestError("Source exceeds metadata budget: estimated required \(metadataRequired) bytes; allowed \(metadataAllowed) bytes at capacity \(capacity) bytes (\(detail)). Metadata budget is max(64 KiB, capacity / 4). Increase capacity or reduce entry/attribute count before mounting; no files were moved.", code: 6)
    }
    public var allocatedEstimate: UInt64 {
        var total: UInt64 = publicRoot?.attributeBytes ?? 0
        for entry in entries {
            guard entry.size >= 0 else { return UInt64.max }
            if entry.hardlink != nil { continue }
            var amount = entry.attributeBytes
            if entry.kind == "file" && entry.hardlink == nil {
                let size = UInt64(entry.size)
                amount = entry.allocatedBytes ?? ((size + 65535) / 65536) * 65536
                let extra = amount.addingReportingOverflow(entry.attributeBytes)
                if extra.overflow { return UInt64.max }; amount = extra.partialValue
            } else if entry.kind == "symlink" {
                let extra = amount.addingReportingOverflow(UInt64(entry.size))
                if extra.overflow { return UInt64.max }; amount = extra.partialValue
            }
            let sum = total.addingReportingOverflow(amount)
            if sum.overflow { return UInt64.max }; total = sum.partialValue
        }
        return total
    }
}
// Snapshot/reload policy only. Runtime filesystem callbacks and quota accounting
// still include Trash. A no-follow stat is the only permitted subtree access.
enum SnapshotExclusion {
    static func directory(_ name: String, _ mode: mode_t) -> Bool {
        name == ".Trashes" && mode & S_IFMT == S_IFDIR
    }
    static func directory(_ path: String, kind: String) -> Bool {
        path.split(separator:"/").last == ".Trashes" && kind == "directory"
    }
}
extension Manifest {
    // Validate the complete old namespace before projecting. Names alone never
    // establish managed authority, storage version, or directory kind.
    func excludingTrashDirectories() throws -> Manifest {
        var kinds: [String:String] = [:]
        for e in entries {
            guard !e.path.isEmpty, StorageModes.validPath(e.path), ["directory","file","symlink"].contains(e.kind),
                  e.mode <= 0o7777, kinds.updateValue(e.kind,forKey:e.path) == nil else { throw NestError("Malformed snapshot namespace.",code:6) }
        }
        var excluded = Set<String>()
        for e in entries {
            let parent = e.path.split(separator:"/").dropLast().joined(separator:"/")
            guard parent.isEmpty || kinds[parent] == "directory" else { throw NestError("Invalid snapshot namespace parent.",code:6) }
            if let link = e.hardlink { guard e.kind == "file", kinds[link] == "file", link != e.path else { throw NestError("Invalid snapshot hardlink anchor.",code:6) } }
            if SnapshotExclusion.directory(e.path,kind:e.kind) { excluded.insert(e.path) }
        }
        func ignored(_ path: String) -> Bool {
            var parts = path.split(separator:"/")
            while !parts.isEmpty { if excluded.contains(parts.joined(separator:"/")) { return true };parts.removeLast() }
            return false
        }
        var result = Manifest(entries:entries.filter { !ignored($0.path) },publicRoot:publicRoot,fileVerification:fileVerification)
        var anchors: [String:String] = [:]
        let order = result.entries.indices.sorted { result.entries[$0].path.split(separator:"/").lexicographicallyPrecedes(result.entries[$1].path.split(separator:"/")) }
        for i in order where result.entries[i].kind == "file" {
            let group = result.entries[i].hardlink ?? result.entries[i].path
            result.entries[i].hardlink = anchors[group]
            if anchors[group] == nil { anchors[group] = result.entries[i].path }
        }
        return result
    }
}
public enum Snapshot {
    static let provenanceName = "com.apple.provenance"
    // Only callers reading an explicitly selected Store revision may request
    // logical projection. User-controlled path/sibling names confer no authority.
    public enum SourceContext { case original, managedRevision }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static let readOperationErrorKey = "RAMNestReadOperation"
    private static func readFailure(_ operation: String, _ code: Int32, _ url: URL? = nil, syscall: String? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: "\(operation) (errno \(code))."]
        if let url { info[NSFilePathErrorKey] = url.path }
        if let syscall { info[readOperationErrorKey] = syscall }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: info)
    }
    static func attributes(_ url: URL, list: ((UnsafeMutablePointer<CChar>?, Int) -> Int)? = nil) throws -> [String: String] {
        let listing = list ?? { listxattr(url.path, $0, $1, XATTR_NOFOLLOW) }
        let count = listing(nil, 0)
        if count < 0 { let code = errno; if code == ENOTSUP || code == ENOATTR { return [:] }; throw readFailure("Cannot list extended attributes", code, url, syscall: "listxattr") }
        if count == 0 { return [:] }
        var names = [CChar](repeating: 0, count: count)
        let listed = listing(&names, count)
        if listed < 0 { throw readFailure("Cannot list extended attributes", errno, url, syscall: "listxattr") }
        guard listed == count else { throw NestError("Attributes changed during snapshot.", code: 6) }
        var result: [String: String] = [:]; var index = 0
        while index < count {
            let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress!.advanced(by: index)) }; index += name.utf8.count + 1
            // decmpfs describes filesystem storage, not logical user metadata.
            // fcopyfile may clone or decompress it; never reattach it to plain data.
            // Keep the normal xattr view (no XATTR_SHOWCOMPRESSION), so macOS
            // hides compression resource forks while visible user forks are hashed.
            if name == "com.apple.decmpfs" { continue }
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 { throw readFailure("Cannot read extended attribute size", errno, url, syscall: "getxattr") }
            guard size <= 1024 * 1024 else { throw NestError("Unsupported attribute size.", code: 6) }
            var data = Data(count: size)
            let got = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            if got < 0 { throw readFailure("Cannot read extended attribute", errno, url, syscall: "getxattr") }
            guard got == size else { throw NestError("Attribute changed during snapshot.", code: 6) }
            result[name] = digest(data)
        }
        return result
    }
    static func supportedSecurity(_ url: URL, _ st: stat) throws {
        guard st.st_uid == getuid(), st.st_gid == getgid() else {
            throw NestError("Unsupported ownership at \(url.lastPathComponent). RAMNest requires the current uid and primary gid; no files were moved.", code: 4)
        }
        errno = 0
        if let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
            guard result != 0, errno == EINVAL else { throw NestError("ACL-bearing entries are unsupported: \(url.lastPathComponent). No files were moved.", code: 4) }
        } else if errno != ENOENT && errno != ENOTSUP {
            throw readFailure("Cannot inspect ACL", errno, url)
        }
    }
    static func manifestFileBytes(_ container: DirectoryHandle) throws -> Data {
        let fd = openat(container.fd, "manifest.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NestError("Cannot pin immutable manifest.", code: 6) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
              before.st_nlink == 1, before.st_size > 0, before.st_size <= 64 << 20 else { throw NestError("Invalid immutable manifest inode.", code: 6) }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: (64 << 20) + 1) ?? Data()
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ctimespec == after.st_ctimespec, before.st_size == after.st_size,
              bytes.count == Int(before.st_size) else { throw NestError("Immutable manifest changed while reading.", code: 6) }
        return bytes
    }
    static func storedMetadata(_ data: URL) throws -> StoredManifest? {
        let revision = data.deletingLastPathComponent()
        let container = try DirectoryHandle.open(revision)
        let metadata = try container.readJSON(StoredManifest.self,"manifest.json")
        if metadata.storageFormat == 2 {
            let st = try container.entryStat("manifest.json")
            guard st.st_mode & 0o7777 == 0o600, st.st_uid == getuid(), st.st_gid == getgid(), st.st_nlink == 1 else { throw NestError("Invalid private manifest inode/physical policy.", code: 6) }
        }
        return try SnapshotCopyObservations.applying(to: metadata, data: data)
    }
    static func checkedModes(_ data: URL, _ metadata: StoredManifest) throws -> StorageModes? {
        guard metadata.storageFormat != nil else { return nil }
        let container = try DirectoryHandle.open(data.deletingLastPathComponent())
        var st = stat()
        guard fstat(container.fd,&st) == 0, st.st_mode & 0o7777 == 0o700, st.st_uid == getuid(), st.st_gid == getgid(),
              try container.names() == ["data","manifest.json","modes.bin"] else { throw NestError("Invalid format-2 private container policy/namespace.", code: 6) }
        let bytes = try StorageModes.read(data.deletingLastPathComponent().appendingPathComponent("modes.bin"))
        guard digest(bytes) == metadata.modeMapDigest else { throw NestError("Snapshot logical mode map digest mismatch.", code: 6) }
        let modes = try StorageModes(data:bytes)
        guard modes.records == (try StorageModes(metadata.logical)).records else { throw NestError("Snapshot logical modes disagree with authenticated mode map.", code: 6) }
        return modes
    }
    public static func manifest(_ root: URL, maximumLogical: UInt64? = nil, matching expected: Manifest? = nil, phase: String = "manifest", context: SourceContext = .original, verification: FileVerification? = nil) throws -> Manifest {
        let metadata = context == .managedRevision ? try storedMetadata(root) : nil
        let policy = verification ?? expected?.fileVerification ?? metadata?.fileVerification ?? .sha256
        guard expected.map({ $0.fileVerification == policy }) ?? true,
              metadata.map({ $0.fileVerification == policy }) ?? true else { throw NestError("Snapshot verification policy mismatch; retained.", code: 6) }
        let modes = try metadata.flatMap { try checkedModes(root,$0) }
        let observed = try scanManifest(root,maximumLogical:maximumLogical,matching:expected,phase:phase,containedHardlinks:modes != nil,verification:policy)
        // Observation remains distinct from authentication. Callers can inspect
        // a damaged checksum; verified/copy/capture must compare all fields.
        return try modes?.projecting(observed) ?? observed
    }
    static func scanManifest(_ root: URL, maximumLogical: UInt64? = nil, matching expected: Manifest? = nil, phase: String = "manifest", containedHardlinks: Bool = false, verification: FileVerification? = nil) throws -> Manifest {
        let policy = verification ?? expected?.fileVerification ?? .sha256
        guard expected.map({ $0.fileVerification == policy }) ?? true else { throw NestError("Snapshot verification policy mismatch; retained.", code: 6) }
        try expected?.validateVerification()
        try Paths.rejectSymlinks(root.path)
        var rootStat = stat(); guard lstat(root.path, &rootStat) == 0 else { throw NestError("Snapshot root is missing.", code: 6) }
        try supportedSecurity(root, rootStat)
        let started = ProcessInfo.processInfo.systemUptime
        var bytesRead: UInt64 = 0, sha256Bytes: UInt64 = 0, aliasesReused = 0
        var expectedByPath: [String: Entry] = [:]
        for entry in expected?.entries ?? [] {
            guard expectedByPath.updateValue(entry, forKey: entry.path) == nil else { throw NestError("Duplicate path in snapshot manifest.", code: 6) }
        }
        var digestCache: [String: (stat, SparseContent.Result)] = [:]
        var entries: [Entry] = []; var links: [String: String] = [:]
        var identities: [(URL,stat)] = [], linkCounts: [String:Int] = [:], expectedLinks: [String:Int] = [:]
        var pending = try children(root,path:".").sorted { $0.lastPathComponent > $1.lastPathComponent }.map { ($0, $0.lastPathComponent) }
        while let (child, path) = pending.popLast() {
                var st = stat(); guard lstat(child.path, &st) == 0 else { throw NestError("Source changed at \(diagnosticLabel(path)).",code:6) }
                if SnapshotExclusion.directory(child.lastPathComponent,st.st_mode) { identities.append((child,st));continue }
                guard st.st_dev == rootStat.st_dev else { throw NestError("Source changed or contains a nested mount: \(path)", code: 6) }
                try supportedSecurity(child, st)
                let type = st.st_mode & S_IFMT
                // Regular reads and hashes use kernel-decoded logical bytes.
                // Copy logical bytes without claiming an APFS decmpfs representation.
                let logicalFlags = type == S_IFREG ? st.st_flags & ~UInt32(UF_COMPRESSED) : st.st_flags
                var entry = Entry(path: path, kind: "", size: 0, mode: UInt16(st.st_mode & 0o7777), mtimeSeconds: 0, mtimeNanos: 0, checksum: "", attributes: try relativeAttributes(child,path), hardlink: nil, flags: logicalFlags, attributeBytes: 0)
                guard logicalFlags & ~UInt32(UF_HIDDEN | UF_NODUMP) == 0 else { throw NestError("Unsupported file flags on \(path). Clear immutable/append/system flags before conversion.", code: 4) }
                try accountAttributes(child, entry: &entry)
                if type == S_IFDIR { entry.kind = "directory" }
                else if type == S_IFLNK {
                    guard st.st_nlink == 1 else { throw NestError("Hardlinked symbolic links cannot be preserved; no files were moved.", code: 4) }
                    entry.kind = "symlink"
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                    entry.size = Int64(target.utf8.count); entry.checksum = digest(Data(target.utf8))
                } else if type == S_IFREG {
                    guard st.st_size >= 0 else { throw NestError("Invalid negative file size.", code: 6) }
                    entry.kind = "file"; entry.size = st.st_size; entry.mtimeSeconds = Int64(st.st_mtimespec.tv_sec); entry.mtimeNanos = Int64(st.st_mtimespec.tv_nsec)
                    let key = "\(st.st_dev):\(st.st_ino)"
                    linkCounts[key,default:0] += 1;expectedLinks[key] = Int(st.st_nlink)
                    if st.st_nlink > 1 { entry.hardlink = links[key]; if links[key] == nil { links[key] = path } }
                    let fd = open(child.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw readFailure("Cannot read snapshot at \(diagnosticLabel(path)) (open)",errno,syscall:"open") }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var before = stat(); guard fstat(fd, &before) == 0, before.st_ino == st.st_ino, before.st_dev == st.st_dev, before.st_size == st.st_size, before.st_mtimespec == st.st_mtimespec, before.st_ctimespec == st.st_ctimespec else { throw NestError("Source identity/metadata changed.", code: 6) }
                    let result: SparseContent.Result
                    if let (cached, digest) = digestCache[key], cached.st_size == before.st_size,
                       cached.st_mtimespec == before.st_mtimespec, cached.st_ctimespec == before.st_ctimespec {
                        result = digest; aliasesReused += 1
                    } else {
                        let legacy = policy == .sha256 && (expectedByPath[path].map { !$0.checksum.hasPrefix("sparse64-v1:") } ?? false)
                        result = try SparseContent.scan(fd, size: before.st_size, legacy: legacy, verification: policy)
                        bytesRead += result.bytesRead
                        sha256Bytes += result.sha256Bytes
                    }
                    var after = stat(); guard fstat(fd, &after) == 0, before.st_size == after.st_size, before.st_mtimespec == after.st_mtimespec, before.st_ctimespec == after.st_ctimespec else { throw NestError("Source is being written. Close writers and retry.", code: 6) }
                    digestCache[key] = (after, result)
                    entry.checksum = result.checksum
                    entry.allocatedBytes = result.allocated
                    _ = handle // retain the descriptor through final identity validation

                } else { throw NestError("Special files (socket/device/FIFO) cannot be put in RAMNest: \(path)", code: 4) }
                entries.append(entry)
                identities.append((child,st))
                guard entries.count < StorageModes.maximumRecords, pending.count < StorageModes.maximumRecords else { throw NestError("Snapshot namespace bound exceeded.", code: 6) }
                if type == S_IFDIR {
                    let descendants = try children(child,path:path).sorted { $0.lastPathComponent > $1.lastPathComponent }
                    pending += descendants.map { ($0, path + "/" + $0.lastPathComponent) }
                }
        }
        if let trace = ProcessInfo.processInfo.environment["RAMNEST_HASH_TRACE"] {
            let event: [String: Any] = ["phase": phase, "fileVerification": policy.rawValue, "fileContentSHA256Bytes": sha256Bytes, "bytesRead": bytesRead, "hardlinkDigestsReused": aliasesReused, "seconds": ProcessInfo.processInfo.systemUptime-started]
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) + Data([10])
            let fd = open(trace, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if fd >= 0 { _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }; close(fd) }
        }
        var rootEntry = Entry(path: "", kind: "directory", size: 0, mode: UInt16(rootStat.st_mode & 0o7777), mtimeSeconds: 0, mtimeNanos: 0, checksum: "", attributes: try relativeAttributes(root,"."), hardlink: nil, flags: rootStat.st_flags, attributeBytes: 0)
        try accountAttributes(root, entry: &rootEntry)
        guard rootEntry.flags & ~UInt32(UF_HIDDEN | UF_NODUMP) == 0 else { throw NestError("Unsupported root flags.", code: 4) }
        if containedHardlinks { guard linkCounts == expectedLinks else { throw NestError("Private snapshot has a cross-boundary hardlink.", code: 6) } }
        for (url,before) in identities + [(root,rootStat)] {
            var after = stat()
            guard lstat(url.path,&after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_mode == before.st_mode,
                  after.st_size == before.st_size, after.st_mtimespec == before.st_mtimespec, after.st_ctimespec == before.st_ctimespec else { throw NestError("Snapshot source changed during independent readback.", code: 6) }
        }
        return Manifest(entries: entries.sorted { $0.path < $1.path }, publicRoot: rootEntry, fileVerification: policy)
    }
    static func accountAttributes(_ url: URL, entry: inout Entry) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw readFailure("Cannot inspect attribute accounting", errno, url) }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | (st.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
        guard fd >= 0 else { throw readFailure("Cannot pin attribute accounting", errno, url) }
        defer { close(fd) }
        entry.attributeBytes = 0; entry.provenanceBytes = 0
        for name in entry.attributes.keys {
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0, size <= 1024 * 1024 else { throw readFailure("Cannot measure extended attribute", errno, url) }
            let amount = UInt64(size) + UInt64(name.utf8.count)
            let sum = entry.attributeBytes.addingReportingOverflow(amount)
            guard !sum.overflow else { throw NestError("Attribute accounting overflow.", code: 6) }
            entry.attributeBytes = sum.partialValue
            if name == provenanceName { entry.provenanceBytes = amount }
        }
    }
    static func relativeAttributes(_ url: URL, _ path: String) throws -> [String:String] {
        do { return try attributes(url) }
        catch {
            let e = error as NSError
            if e.domain == NSPOSIXErrorDomain {
                let operation = e.userInfo[readOperationErrorKey] as? String ?? "xattr"
                throw NSError(domain:e.domain,code:e.code,userInfo:[NSLocalizedDescriptionKey:"Cannot inspect snapshot source at \(diagnosticLabel(path)) (\(operation), errno \(e.code)). Source permissions were not changed; data is retained.",readOperationErrorKey:operation])
            }
            throw error
        }
    }
    static func children(_ url: URL, path: String) throws -> [URL] {
        do { return try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil) }
        catch {
            var e = error as NSError
            for _ in 0..<8 { guard let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError else { break };e = underlying }
            throw readFailure("Cannot enumerate snapshot at \(diagnosticLabel(path)) (readdir)",e.domain == NSPOSIXErrorDomain ? Int32(e.code) : EIO,syscall:"readdir")
        }
    }
    static func diagnosticLabel(_ value: String) -> String {
        value.unicodeScalars.prefix(160).map { CharacterSet.controlCharacters.contains($0) ? "?" : String($0) }.joined()
    }
    static func mismatchDetail(_ actual: Manifest, _ expected: Manifest) -> String {
        if actual.fileVerification != expected.fileVerification { return "at . (fileVerification policy)" }
        func detail(_ path: String, _ field: String) -> String { "at \(diagnosticLabel(path)) (\(field))" }
        for (a, e) in zip(actual.entries, expected.entries) where a != e {
            if a.path != e.path { return detail(min(a.path, e.path), "field path") }
            let fields: [(Bool, String)] = [
                (a.kind != e.kind, "kind"), (a.size != e.size, "size"), (a.mode != e.mode, "mode"),
                (a.mtimeSeconds != e.mtimeSeconds, "mtimeSeconds"), (a.mtimeNanos != e.mtimeNanos, "mtimeNanos"),
                (a.checksum != e.checksum, "checksum"), (a.hardlink != e.hardlink, "hardlink"), (a.flags != e.flags, "flags")
            ]
            if let field = fields.first(where: { $0.0 }) { return detail(e.path, "field " + field.1) }
            for name in Set(a.attributes.keys).union(e.attributes.keys).sorted() where a.attributes[name] != e.attributes[name] {
                return detail(e.path, "xattr " + diagnosticLabel(name))
            }
            return detail(e.path, "field attributeBytes")
        }
        if actual.entries == expected.entries { return detail(".", "field publicRoot") }
        let index = min(actual.entries.count, expected.entries.count)
        let extra = actual.entries.count > index ? actual.entries[index] : expected.entries[index]
        return detail(extra.path, "field path")
    }
    // fcopyfile handles quarantine via qtn APIs, which can change its flags.
    // Replay only manifest-validated source bytes, using the already-opened
    // no-follow descriptors. Never synthesize flags or remove an attribute.
    private static func preserveQuarantine(from source: Int32, to destination: Int32, entry: Entry) throws {
        let name = "com.apple.quarantine"
        guard let expected = entry.attributes[name] else { return }
        func failure(_ reason: String) -> NestError {
            NestError("Cannot preserve snapshot metadata at \(diagnosticLabel(entry.path)) (xattr \(name); \(reason)). No source files were removed.", code: 6)
        }
        func read(_ descriptor: Int32) throws -> Data? {
            let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
            if size < 0 && errno == ENOATTR { return nil }
            guard size >= 0 else { throw failure("read failed, errno \(errno)") }
            guard size <= 1024 * 1024 else { throw failure("unsupported size") }
            var data = Data(count: size)
            guard data.withUnsafeMutableBytes({ fgetxattr(descriptor, name, $0.baseAddress, size, 0, 0) }) == size else {
                throw failure("attribute changed or read failed")
            }
            return data
        }
        guard let bytes = try read(source), digest(bytes) == expected else { throw failure("source changed") }
        if try read(destination) == bytes { return }
        // fcopyfile may already have made this newly created private copy
        // read-only. Finish its metadata before restoring that exact mode;
        // never change the source, ACLs, or any global permission setting.
        var copied = stat()
        guard fstat(destination, &copied) == 0, copied.st_uid == getuid() else { throw failure("cannot inspect owned destination") }
        let mode = copied.st_mode & 0o7777
        let needsWrite = mode & 0o200 == 0 && (copied.st_mode & S_IFMT == S_IFREG || copied.st_mode & S_IFMT == S_IFDIR)
        if needsWrite && fchmod(destination, mode | 0o200) != 0 { throw failure("cannot finish private copy metadata, errno \(errno)") }
        let written = bytes.withUnsafeBytes { fsetxattr(destination, name, $0.baseAddress, bytes.count, 0, 0) }
        let writeError = errno
        if needsWrite && fchmod(destination, mode) != 0 { throw failure("cannot restore copied mode, errno \(errno)") }
        guard written == 0 else {
            throw failure("exact preservation denied, errno \(writeError)")
        }
        guard try read(destination) == bytes else { throw failure("exact preservation not retained") }
    }
    private static func verifyRootCopySource(_ fd: Int32, expected: Entry) throws {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_flags == expected.flags else { throw NestError("Public root source flags changed.", code: 6) }
        let count = flistxattr(fd, nil, 0, 0)
        guard count >= 0, count <= 1 << 20 else { throw NestError("Cannot enumerate public root source attributes.", code: 6) }
        var names = [CChar](repeating: 0, count: max(1, count))
        guard flistxattr(fd, &names, count, 0) == count else { throw NestError("Public root source attributes changed.", code: 6) }
        var hashes: [String: String] = [:], total: UInt64 = 0
        for key in names.prefix(count).split(separator: 0) {
            let name = String(decoding: key.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "com.apple.decmpfs" { continue }
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0, size <= 1 << 20 else { throw NestError("Cannot read public root source attribute.", code: 6) }
            var bytes = Data(count: size)
            guard bytes.withUnsafeMutableBytes({ fgetxattr(fd, name, $0.baseAddress, size, 0, 0) }) == size else { throw NestError("Public root source attribute changed.", code: 6) }
            hashes[name] = digest(bytes)
            let sum = total.addingReportingOverflow(UInt64(name.utf8.count) + UInt64(size))
            guard !sum.overflow else { throw NestError("Public root attribute accounting overflow.", code: 6) }; total = sum.partialValue
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ctimespec == after.st_ctimespec,
              before.st_mode == after.st_mode, hashes == expected.attributes, total == expected.attributeBytes else { throw NestError("Public root raw source metadata changed. No source files were removed.", code: 6) }
    }
    // Both copy and recovery finish public-root metadata from already-verified,
    // no-follow directory descriptors. Darwin's quarantine copy API can rewrite
    // bytes; replay only the value authenticated by this manifest, then sync.
    // Rootless historical manifests retain their original metadata contract.
    static func restorePublicRootMetadata(from source: DirectoryHandle, to destination: DirectoryHandle, manifest: Manifest) throws {
        guard let rootEntry = manifest.publicRoot else { return }
        try verifyRootCopySource(source.fd, expected: rootEntry)
        guard fcopyfile(source.fd, destination.fd, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0 else {
            throw NestError("Cannot preserve public root metadata.", code: 6)
        }
        try preserveQuarantine(from: source.fd, to: destination.fd, entry: rootEntry)
        try verifyRootCopySource(source.fd, expected: rootEntry)
        guard fchmod(destination.fd,mode_t(rootEntry.mode)) == 0 else { throw NestError("Cannot finalize public root mode.", code: 6) }
        try destination.sync()
    }
    static func preparePublicRoot(from source: DirectoryHandle, to destination: DirectoryHandle, selected: URL, manifest: Manifest) throws -> Entry {
        guard let root = manifest.publicRoot else { throw NestError("Missing public root metadata.", code: 6) }
        try verifyRootCopySource(source.fd, expected: root)
        guard fcopyfile(source.fd,destination.fd,nil,copyfile_flags_t(COPYFILE_XATTR)) == 0 else { throw NestError("Cannot copy public root attributes.", code: 6) }
        try preserveQuarantine(from:source.fd,to:destination.fd,entry:root)
        try verifyRootCopySource(source.fd, expected: root)
        guard fchflags(destination.fd,root.flags) == 0 else { throw NestError("Public root flag restoration failed.", code: 6) }
        var st = stat()
        guard fstat(destination.fd, &st) == 0, st.st_flags == root.flags else { throw NestError("Public root flag readback failed.", code: 6) }
        var observed = root
        observed.attributes = try relativeAttributes(selected, ".")
        try accountAttributes(selected, entry: &observed)
        guard try Manifest(entries: [], publicRoot: observed).matchesCopy(of: Manifest(entries: [], publicRoot: root)) else { throw NestError("Public root attribute readback failed.", code: 6) }
        try destination.sync()
        return observed
    }
    // A legacy manifest that omitted root metadata authenticates only entries.
    // Observe the readable physical root for THIS new materialization; never
    // invent historical metadata or rewrite/relabel the legacy revision.
    static func materializationManifest(_ source: URL, expected: Manifest, context: SourceContext) throws -> Manifest {
        if expected.publicRoot?.provenanceBytes != nil, expected.entries.allSatisfy({ $0.provenanceBytes != nil }) { return expected }
        let observed = try manifest(source,matching:expected,phase:"materialization-source",context:context)
        guard observed.matchesExpected(expected) else { throw NestError("Materialization source changed \(mismatchDetail(observed, expected)). No source files were removed.", code: 6) }
        return observed
    }

    @discardableResult public static func copyTree(from source: URL, to destination: URL, manifest expected: Manifest, previous: URL? = nil, comparison: Comparison = .checksum, privateStorage: Bool = false, publicationStaging: Bool = false, sourceContext: SourceContext = .original, previousContext: SourceContext = .original) throws -> Manifest {
        let manifest = try materializationManifest(source,expected:expected.excludingTrashDirectories(),context:sourceContext)
        if privateStorage { return try copyAccessibleTree(from:source,to:destination,manifest:manifest,previous:previous,comparison:comparison,sourceContext:sourceContext,previousContext:previousContext) }
        if publicationStaging {
            let copied = try copyAccessibleTree(from:source,to:destination,manifest:manifest,previous:previous,comparison:comparison,sourceContext:sourceContext,previousContext:previousContext)
            _ = try finalizeModes(destination,manifest:copied,destination:destination.lastPathComponent)
            return copied
        }
        let parent = try DirectoryHandle.open(destination.deletingLastPathComponent())
        guard try !parent.exists(destination.lastPathComponent) else { throw NestError("Export destination already exists.", code: 6) }
        let name = ".ramnest-materialize-" + UUID().uuidString
        let container = try parent.createDirectory(name)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(name).appendingPathComponent("data")
        let copied = try copyAccessibleTree(from:source,to:staging,manifest:manifest,previous:previous,comparison:comparison,sourceContext:sourceContext,previousContext:previousContext)
        let privateName = ".ramnest-publish-" + UUID().uuidString
        var intent = PublicationReceipt(manifest:copied,destination:destination.lastPathComponent,phase:"verified-accessible")
        intent.privateName = privateName
        try Store.atomicJSON(intent,staging.deletingLastPathComponent().appendingPathComponent("publication.json"))
        let pinned = try container.child("data").identity()
        // Darwin requires owner write on a directory moved between parents.
        // Transfer the verified 0700 object first, then finalize and publish by
        // same-parent rename. The random temporary root is itself private 0700.
        try container.renameNoReplace("data",to:parent,as:privateName)
        try container.sync();try parent.sync()
        let privateURL = destination.deletingLastPathComponent().appendingPathComponent(privateName)
        guard try parent.child(privateName).identity() == pinned else { throw NestError("Publication materialization identity changed.", code: 6) }
        var receipt = try finalizeModes(privateURL,manifest:copied,destination:destination.lastPathComponent)
        receipt.privateName = privateName
        try Store.atomicJSON(receipt,staging.deletingLastPathComponent().appendingPathComponent("publication.json"))
        try container.sync()
        guard try DirectoryHandle.open(destination.deletingLastPathComponent()).identity() == parent.identity() else { throw NestError("Publication parent identity changed; materialization and receipt retained.", code: 6) }
        try parent.renameNoReplace(privateName,to:parent,as:destination.lastPathComponent)
        try container.sync();try parent.sync()
        let published = try parent.entryStat(destination.lastPathComponent)
        guard Paths.deviceID(published.st_dev) == pinned.device, published.st_ino == pinned.inode,
              try DirectoryHandle.open(destination.deletingLastPathComponent()).identity() == parent.identity() else { throw NestError("Published materialization identity changed; receipt retained.", code: 6) }
        receipt.phase = "published"
        try Store.atomicJSON(receipt,staging.deletingLastPathComponent().appendingPathComponent("publication.json"))
        return copied
    }
    @discardableResult static func copyAccessibleTree(from source: URL, to destination: URL, manifest: Manifest, previous: URL? = nil, comparison: Comparison = .checksum, sourceContext: SourceContext = .original, previousContext: SourceContext = .original) throws -> Manifest {
        func observe(_ phase: String) throws -> Manifest {
            try self.manifest(source, matching: manifest, phase: phase, context: sourceContext)
        }
        let before = try observe("copy-source-before")
        guard before.matchesExpected(manifest) else { throw NestError("Copy source changed \(mismatchDetail(before,manifest)). No source files were removed.", code: 6) }
        let sourceRoot = try DirectoryHandle.open(source)
        let previousRoot = try previous.map { try DirectoryHandle.open($0) }
        let previousManifest = try previous.flatMap { url -> Manifest? in
            if previousContext == .managedRevision, try storedMetadata(url)?.fileVerification != manifest.fileVerification { return nil }
            return try self.manifest(url,context:previousContext,verification:manifest.fileVerification)
        }
        let previousEntries = Dictionary(uniqueKeysWithValues: (previousManifest?.entries ?? []).map { ($0.path, $0) })
        let destinationParent = try DirectoryHandle.open(destination.deletingLastPathComponent())
        let destinationRoot = try destinationParent.createDirectory(destination.lastPathComponent)
        let sourceCursor = DirectoryCursor(sourceRoot), destinationCursor = DirectoryCursor(destinationRoot)
        let previousCursor = previousRoot.map(DirectoryCursor.init)
        for entry in manifest.entries.sorted(by: { a, b in
            let ap = a.kind == "directory" ? 0 : a.hardlink == nil ? 1 : 2
            let bp = b.kind == "directory" ? 0 : b.hardlink == nil ? 1 : 2
            return ap == bp ? a.path < b.path : ap < bp
        }) {
            let (srcParent, srcName) = try sourceCursor.parent(of: entry.path)
            let (dstParent, dstName) = try destinationCursor.parent(of: entry.path)
            if entry.kind == "directory" { _ = try dstParent.createDirectory(dstName); continue }
            if let first = entry.hardlink {
                let (firstParent, firstName) = try destinationCursor.parent(of: first)
                guard linkat(firstParent.fd, firstName, dstParent.fd, dstName, 0) == 0 else { throw NestError("Hardlink copy failed.", code: 6) }
                continue
            }
            if entry.kind == "symlink" {
                var target = [CChar](repeating: 0, count: 4097)
                let size = readlinkat(srcParent.fd, srcName, &target, 4096)
                guard size >= 0, size < 4096 else { throw NestError("Cannot copy symlink.", code: 6) }
                target[size] = 0
                guard target.withUnsafeBufferPointer({ symlinkat($0.baseAddress!, dstParent.fd, dstName) }) == 0 else { throw NestError("Symlink copy failed.", code: 6) }
                let src = openat(srcParent.fd, srcName, O_RDONLY | O_SYMLINK | O_CLOEXEC)
                let dst = openat(dstParent.fd, dstName, O_RDONLY | O_SYMLINK | O_CLOEXEC)
                guard src >= 0, dst >= 0 else { if src >= 0 { close(src) }; if dst >= 0 { close(dst) }; throw NestError("Cannot preserve symlink metadata.", code: 6) }
                defer { close(src); close(dst) }
                let copied = fcopyfile(src, dst, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR))
                guard copied == 0 else { throw NestError("Symlink metadata copy failed.", code: 6) }
                guard fchmod(dst,0o700) == 0 else { throw NestError("Cannot set private symlink storage policy.", code: 6) }
                try preserveQuarantine(from: src, to: dst, entry: entry)
            } else {
                var chosenParent = srcParent; var chosenName = srcName
                // Incremental selection is separate from integrity. A policy
                // change never reinterprets the prior immutable revision.
                if let previousCursor, previousManifest?.fileVerification == manifest.fileVerification,
                   let old = previousEntries[entry.path], old.kind == "file", old.size == entry.size,
                   (manifest.fileVerification == .sha256 ? old.checksum == entry.checksum :
                       (comparison == .sizeAndModTime && old.mtimeSeconds == entry.mtimeSeconds && old.mtimeNanos == entry.mtimeNanos)),
                   let (oldParent, oldName) = try? previousCursor.parent(of: entry.path) {
                    chosenParent = oldParent; chosenName = oldName
                }
                let src = openat(chosenParent.fd, chosenName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                let dst = openat(dstParent.fd, dstName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard src >= 0, dst >= 0 else { if src >= 0 { close(src) }; if dst >= 0 { close(dst) }; throw NestError("Cannot open snapshot file.", code: 6) }
                defer { close(src); close(dst) }
                try SparseContent.copy(src, to: dst, size: entry.size)
                let current = openat(srcParent.fd, srcName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard current >= 0 else { throw NestError("Cannot read current source metadata.", code: 6) }
                defer { close(current) }
                guard fcopyfile(current, dst, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0 else { throw NestError("Cannot copy current metadata.", code: 6) }
                guard fchmod(dst,0o600) == 0 else { throw NestError("Cannot set private file storage policy.", code: 6) }
                try preserveQuarantine(from: current, to: dst, entry: entry)
                guard fsync(dst) == 0 else { throw NestError("Snapshot file copy/sync failed: \(entry.path)", code: 6) }
            }
        }
        for entry in manifest.entries.reversed() where entry.kind == "directory" {
            let (srcParent, name) = try sourceCursor.parent(of: entry.path)
            let (dstParent, _) = try destinationCursor.parent(of: entry.path)
            let src = try srcParent.child(name), dst = try dstParent.child(name)
            guard fcopyfile(src.fd, dst.fd, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0 else { throw NestError("Directory metadata copy failed.", code: 6) }
            guard fchmod(dst.fd,0o700) == 0 else { throw NestError("Cannot set private directory storage policy.", code: 6) }
            try preserveQuarantine(from: src.fd, to: dst.fd, entry: entry)
            try dst.sync()
        }
        try restorePublicRootMetadata(from: sourceRoot, to: destinationRoot, manifest: manifest)
        guard fchmod(destinationRoot.fd,0o700) == 0 else { throw NestError("Cannot set private root storage policy.", code: 6) }
        try destinationRoot.sync(); try destinationParent.sync()
        let actual = try StorageModes(manifest).projecting(scanManifest(destination, matching: manifest, phase: "copy-readback",containedHardlinks:true))
        guard try actual.matchesCopy(of: before) else { throw NestError("Snapshot verification failed \(mismatchDetail(actual, manifest)). No source files were removed.", code: 6) }
        try Store.syncDirectory(destination)
        let after = try observe("copy-source-after")
        guard after == before else { throw NestError("Source changed during copy \(mismatchDetail(after,manifest)). No source files were removed.", code: 6) }
        return actual
    }
    public static func dataURL(store: Store, id: UUID, revision: String) throws -> URL {
        guard UUID(uuidString: revision) != nil else { throw NestError("Invalid snapshot revision.", code: 6) }
        return try store.volume(id).appendingPathComponent("revisions/\(revision)/data")
    }
    public static func verified(store: Store, id: UUID, revision: String, verification: FileVerification? = nil) throws -> (URL, Manifest) {
        let data = try dataURL(store: store, id: id, revision: revision)
        let revisions = try DirectoryHandle.open(data.deletingLastPathComponent().deletingLastPathComponent())
        guard try revisions.exists(revision) else { throw NestError("Snapshot revision \(revision) is not retained on disk. RAMNest keeps the latest verified snapshot, with temporary transaction anchors while needed.", code: 6) }
        let container = try revisions.child(revision)
        let metadataBefore = try container.entryStat("manifest.json")
        let containerIdentity = try container.identity()
        guard let metadata = try storedMetadata(data) else { throw NestError("Missing snapshot metadata.", code: 6) }
        try container.requireOwnedDirectory(device:revisions.identity().device,privateMode:true)
        guard try container.names() == (metadata.storageFormat == 2 ? ["data", "manifest.json", "modes.bin"] : ["data", "manifest.json"]) else { throw NestError("Unexpected snapshot container namespace.", code: 6) }
        // Keep the full stored record/map immutable; only the returned view is filtered.
        _ = try checkedModes(data,metadata)
        let expected = try metadata.logical.excludingTrashDirectories()
        guard verification.map({ $0 == expected.fileVerification }) ?? true else { throw NestError("Revision file verification policy disagrees with session authority; retained.", code: 6) }
        let actual = try manifest(data, matching: expected, phase: "revision-integrity",context:.managedRevision)
        guard actual.matchesExpected(expected) else { throw NestError("Snapshot is damaged \(mismatchDetail(actual, expected)). Preserve recovery data and investigate before continuing.", code: 6) }
        let metadataAfter = try container.entryStat("manifest.json")
        guard metadataBefore.st_dev == metadataAfter.st_dev, metadataBefore.st_ino == metadataAfter.st_ino,
              metadataBefore.st_ctimespec == metadataAfter.st_ctimespec, metadataBefore.st_size == metadataAfter.st_size,
              try revisions.child(revision).identity() == containerIdentity else { throw NestError("Snapshot metadata/container changed during verification.", code: 6) }
        return (data, expected)
    }
    public static func capture(store: Store, folder: Folder, source: URL, previous: String?, sourceContext: SourceContext = .original, verification: FileVerification? = nil) throws -> String {
        let stored = sourceContext == .managedRevision ? try storedMetadata(source) : nil
        let initial = try manifest(source, maximumLogical: folder.capacity, matching:stored?.logical,phase: "capture-source-before",context:sourceContext,verification:verification)
        if let stored {
            let expected = try stored.logical.excludingTrashDirectories()
            guard initial.matchesExpected(expected) else { throw NestError("Cannot capture a damaged committed source \(mismatchDetail(initial,expected)).", code: 6) }
        }
        try initial.preflight(capacity: folder.capacity)
        let revision = UUID().uuidString
        let directory = try store.volume(folder.id).appendingPathComponent("revisions/\(revision)")
        try Store.privateDirectory(directory)
        // A prior revision is only an optimization, never current source
        // authority. Damaged/incompatible prior data is retained and cannot be
        // reused; the new source still receives full independent verification.
        let old = previous.flatMap { prior -> URL? in
            guard let verified = try? self.verified(store: store, id: folder.id, revision: prior),
                  verified.1.fileVerification == initial.fileVerification else { return nil }
            return verified.0
        }
        let copied = try copyTree(from: source, to: directory.appendingPathComponent("data"), manifest: initial, previous: old, comparison: folder.options.comparison, privateStorage: true,sourceContext:sourceContext,previousContext:.managedRevision)
        let final = try manifest(source, matching: initial, phase: "capture-source-after",context:sourceContext)
        guard final == initial else { throw NestError("Source changed during snapshot \(mismatchDetail(final, initial)). Close writers and retry. No source files were removed.", code: 6) }
        try copied.preflight(capacity: folder.capacity)
        let modes = try StorageModes(copied)
        try modes.write(directory.appendingPathComponent("modes.bin"))
        try Store.atomicJSON(StoredManifest(copied,modes:modes), directory.appendingPathComponent("manifest.json")); try Store.syncDirectory(directory); try Store.syncDirectory(directory.deletingLastPathComponent())
        return revision
    }
    // Metadata-only, pinned no-follow walk. Stops at each excluded directory.
    // Used to preserve opaque disk holdings/legacy stages, never to authenticate
    // payload or silently classify an unknown filesystem tree as managed.
    static func excludedDirectoryPaths(_ root: URL) throws -> [String] {
        let anchor = try DirectoryHandle.open(root), cursor = DirectoryCursor(anchor)
        let device = try anchor.identity().device
        var pending = try anchor.names(), result: [String] = []
        while let path = pending.popLast() {
            let (parent,name) = try cursor.parent(of:path), st = try parent.entryStat(name)
            if SnapshotExclusion.directory(name,st.st_mode) { result.append(path);continue }
            if st.st_mode & S_IFMT == S_IFDIR {
                guard Paths.deviceID(st.st_dev) == device else { throw NestError("Nested mount in excluded-directory inventory; retained.",code:6) }
                let child = try parent.child(name)
                guard try child.identity() == (device,UInt64(st.st_ino)) else { throw NestError("Excluded-directory inventory changed; retained.",code:6) }
                pending += try child.names().map { path + "/" + $0 }
            }
        }
        return result.sorted()
    }
}

enum SnapshotRetention {
    static func references(_ journal: Journal) -> Set<String> {
        Set((journal.retiringRevisions ?? []) + [journal.revision, journal.priorRevision, journal.initialRevision, journal.restoreRevision].compactMap { $0 }).union(SiblingCleanup.pins(journal))
    }
    static func remember(_ journal: inout Journal) {
        journal.retiringRevisions = references(journal).sorted()
    }
    static func warn(_ error: Error, store: Store, folder: Folder, journal: inout Journal) {
        let warning = "Snapshot cleanup warning: " + error.localizedDescription
        // Do not overwrite a newer journal or its recovery error while reporting
        // a secondary cleanup problem. stderr still reports an unwritable store.
        if let volume = try? store.managedVolume(folder.id),
           let current = try? volume.readJSON(Journal.self, "journal.json", decoder: store.journalDecoder) {
            var expected = journal; expected.updated = current.updated
            if expected == current {
                journal.cleanupWarning = warning
                try? store.write(journal, for: folder.id)
            }
        }
        FileHandle.standardError.write(Data((warning + "\n").utf8))
    }
    // Caller owns repository.lock and has refreshed the selected/mounted identity.
    // Deletion is never attempted until both the latest snapshot and the new
    // durable journal are verified. Failures are reported without failing saves.
    static func clean(store: Store, folder: Folder, journal: inout Journal, validateSource: () throws -> Void,
                      beforeSiblingUnlink: ((DirectoryHandle, String) throws -> Void)? = nil) {
        guard journal.reviewedRecovery == nil else { return }
        guard journal.phase == .idle || journal.phase == .mounted,
              journal.lastError == nil, let latest = journal.revision else { return }
        do {
            try validateSource()
            let volume = try store.managedVolume(folder.id)
            let revisions = try volume.child("revisions")
            try revisions.requireOwnedDirectory(device: volume.identity().device, privateMode: true)
            let path = store.root.path
            guard !Paths.mounts().contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) else { throw NestError("Nested mount in snapshot storage; cleanup skipped.", code: 6) }
            var durable = try volume.readJSON(Journal.self, "journal.json", decoder: store.journalDecoder)
            var expected = journal; expected.updated = durable.updated
            guard durable == expected else { throw NestError("Committed journal changed; cleanup skipped.", code: 6) }
            SiblingCleanup.rememberCompleted(folder, &durable)
            let completedSource = durable.restoreRevision ?? (folder.options.sync ? latest : nil)
            var keep = Set([latest])
            if journal.phase == .mounted {
                guard journal.populationVerified, let initial = journal.initialRevision else { return }
                keep.insert(initial)
                if let restore = journal.restoreRevision { keep.insert(restore) }
            }
            var identities: [String: (container: (device: UInt64, inode: UInt64), data: (device: UInt64, inode: UInt64))] = [:]
            for revision in keep {
                guard UUID(uuidString: revision)?.uuidString == revision else { throw NestError("Invalid committed revision; cleanup skipped.", code: 6) }
                let handle = try revisions.child(revision)
                try handle.requireOwnedDirectory(device: revisions.identity().device, privateMode: true)
                let data = try handle.child("data")
                try data.requireOwnedDirectory(device: revisions.identity().device)
                identities[revision] = try (handle.identity(), data.identity())
                _ = try Snapshot.verified(store: store, id: folder.id, revision: revision)
            }
            let pending = references(durable).subtracting(keep).sorted()
            durable.retiringRevisions = pending
            durable.priorRevision = nil
            if durable.phase == .idle {
                durable.initialRevision = nil; durable.restoreRevision = nil
                durable.initialSourceManifest = nil; durable.restoreManifest = nil
                durable.originalRename = nil; durable.publicationRename = nil
            }
            if durable.phase == .idle || durable.siblingCleanup == nil { durable.cleanupWarning = nil }
            try store.write(durable, for: folder.id)
            journal = durable
            let current = try store.managedVolume(folder.id).child("revisions")
            guard try current.identity() == revisions.identity() else { throw NestError("Snapshot storage identity changed; cleanup skipped.", code: 6) }
            for (revision, identity) in identities {
                let handle = try revisions.child(revision)
                guard try handle.identity() == identity.container, try handle.child("data").identity() == identity.data else { throw NestError("Retained snapshot identity changed; cleanup skipped.", code: 6) }
            }
            try validateSource()
            var remaining: [String] = []
            var warnings = SiblingCleanup.clean(store: store, folder: folder, journal: &journal,
                sourceRevision: completedSource, validateSource: validateSource, beforeUnlink: beforeSiblingUnlink)
            let siblingPins = SiblingCleanup.pins(journal)
            for candidate in pending {
                if siblingPins.contains(candidate) { remaining.append(candidate); continue }
                do {
                    guard UUID(uuidString: candidate)?.uuidString == candidate else { throw NestError("Unrecognized revision reference retained.", code: 6) }
                    if try revisions.exists(candidate) {
                        // Verify only journal-linked deletion candidates, never
                        // scan/hash unrelated history or incomplete captures.
                        _ = try Snapshot.verified(store: store, id: folder.id, revision: candidate)
                        try validateSource()
                        let current = try store.managedVolume(folder.id).child("revisions")
                        guard try current.identity() == revisions.identity() else { throw NestError("Snapshot storage changed; cleanup skipped.", code: 6) }
                        try revisions.removeCommittedRevision(candidate)
                    }
                } catch { remaining.append(candidate); warnings.append(error.localizedDescription) }
            }
            journal.retiringRevisions = remaining.isEmpty ? nil : remaining
            if !warnings.isEmpty { journal.cleanupWarning = "Snapshot cleanup warning: " + warnings.joined(separator: " ") }
            try store.write(journal, for: folder.id)
            if let warning = journal.cleanupWarning { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        } catch {
            warn(error, store: store, folder: folder, journal: &journal)
        }
    }
}

extension timespec: @retroactive Equatable {
    public static func == (lhs: timespec, rhs: timespec) -> Bool { lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec }
}
