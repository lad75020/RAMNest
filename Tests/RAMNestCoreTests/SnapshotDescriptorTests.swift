import Foundation
import Darwin
@testable import RAMNestCore

#if !RAMNEST_SNAPSHOT_DESCRIPTOR_STANDALONE
import Testing

extension RAMNestTestSuite {
    struct SnapshotDescriptorTests {
        @Test func `Wide snapshot cleanup`() throws {
            try SnapshotDescriptorScenarios.run()
        }
        @Test func `Capture and hot retention exact scan counts`() throws { try SnapshotOptimizationScenarios.scanCounts() }
        @Test func `Rename observation single scan and concurrent mutation`() throws { try SnapshotOptimizationScenarios.renameObservation() }
        @Test func `Capture rejects same size restored mtime writes`() throws { try SnapshotOptimizationScenarios.sourceMutation() }
        @Test func `Corrupt prior is rejected and current source captured`() throws { try SnapshotOptimizationScenarios.corruptPrior() }
        @Test func `Stale evidence rejects payload namespace and revision replacement`() throws { try SnapshotOptimizationScenarios.staleEvidence() }
        @Test func `Retention pins and obsolete namespace remain protected`() throws { try SnapshotOptimizationScenarios.retentionSafety() }
        @Test func `Clone success preserves current metadata topology and sparse allocation`() throws { try SnapshotOptimizationScenarios.cloneFidelity() }
        @Test func `Read only original prior clones preserve current metadata and both sources`() throws { try SnapshotOptimizationScenarios.readonlyOriginalClone() }
        @Test func `Clone preparation rejects foreign replacements without normalizing them`() throws { try SnapshotOptimizationScenarios.cloneTargetReplacement() }
        @Test func `Unsupported clone copies current source and preserves sparse allocation`() throws { try SnapshotOptimizationScenarios.cloneFallback() }
        @Test func `Other clone errors fail without creating fallback targets`() throws { try SnapshotOptimizationScenarios.cloneErrors() }
        @Test func `Clone rejects prior replacement and failed partial targets`() throws { try SnapshotOptimizationScenarios.cloneRaces() }
    }
}

enum SnapshotOptimizationScenarios {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NestError("TEST: " + message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }; throw NestError("TEST: expected controlled rejection")
    }
    struct Fixture {
        let root: URL, source: URL, store: Store
        var folder: Folder
        init(_ name: String, policy: FileVerification = .sha256) throws {
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            root = project.appendingPathComponent("artifacts/snapshot-optimization/\(name)-\(UUID().uuidString)")
            source = root.appendingPathComponent("source")
            try Store.privateDirectory(source)
            store = try Store(root: root.appendingPathComponent("store"))
            let identity = try DirectoryHandle.open(source).identity()
            folder = Folder(name: name, path: source.path, capacity: 32 << 20, device: identity.device, inode: identity.inode)
            folder.options.comparison = .sizeAndModTime
            try Data("original".utf8).write(to: source.appendingPathComponent("payload"))
            var config = Configuration(); config.folders = [folder]; config.fileVerification = policy; try store.save(config)
        }
        func capture(_ previous: String? = nil, policy: FileVerification = .sha256,
                     operations: Snapshot.CopyOperations = Snapshot.CopyOperations()) throws -> Snapshot.CaptureEvidence {
            try Snapshot.captureVerified(store: store, folder: folder, source: source, previous: previous, verification: policy, operations: operations)
        }
        func data(_ revision: String) throws -> URL { try Snapshot.dataURL(store: store, id: folder.id, revision: revision) }
        func exists(_ revision: String) throws -> Bool {
            FileManager.default.fileExists(atPath: try data(revision).path)
        }
        func journal(_ latest: String, prior: String? = nil, initial: String? = nil) throws -> Journal {
            var j = Journal(); j.revision = latest; j.priorRevision = prior; j.initialRevision = initial
            j.phase = initial == nil ? .idle : .mounted; j.populationVerified = true
            try store.write(j, for: folder.id); return j
        }
    }
    static func mutate(_ url: URL) throws {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try check(fd >= 0, "open owned mutation fixture"); defer { close(fd) }
        var st = stat(); try check(fstat(fd, &st) == 0, "stat mutation")
        var byte: UInt8 = 88
        try check(pwrite(fd, &byte, 1, 0) == 1, "same-size mutation")
        var times = [st.st_atimespec, st.st_mtimespec]
        try check(futimens(fd, &times) == 0 && fsync(fd) == 0, "restore mtime and sync")
    }
    static func trace(_ root: URL, _ body: () throws -> Void) throws -> [String: Int] {
        let url = root.appendingPathComponent("trace-\(UUID().uuidString).jsonl")
        let previous = getenv("RAMNEST_HASH_TRACE").map { String(cString: $0) }
        setenv("RAMNEST_HASH_TRACE", url.path, 1)
        defer { if let previous { setenv("RAMNEST_HASH_TRACE", previous, 1) } else { unsetenv("RAMNEST_HASH_TRACE") } }
        try body()
        var counts: [String: Int] = [:]
        for line in try Data(contentsOf: url).split(separator: 10) {
            let event = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            counts[event["phase"] as! String, default: 0] += 1
        }
        return counts
    }
    static func scanCounts() throws {
        let f = try Fixture("counts"), first = try f.capture()
        let counts = try trace(f.root) {
            let captured = try f.capture(first.revision)
            var j = try f.journal(captured.revision, prior: first.revision)
            SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, verifiedRevisions: captured.revisions, validateSource: {})
            try check(j.cleanupWarning == nil && !f.exists(first.revision), "hot cleanup retires obsolete revision")
        }
        try check(counts == ["capture-source-before": 1, "copy-source-after": 1, "revision-integrity": 1, "copy-readback": 1], "two source, one prior and one destination scan including cleanup: \(counts)")
        var j = try f.store.journal(f.folder.id)
        let cold = try trace(f.root) { SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, validateSource: {}) }
        try check(cold == ["revision-integrity": 1], "cold retention still authenticates latest")
        let g = try Fixture("cold-candidate"), prior = try g.capture(), latest = try g.capture(prior.revision)
        var coldJournal = try g.journal(latest.revision, prior: prior.revision)
        let coldCandidate = try trace(g.root) { SnapshotRetention.clean(store: g.store, folder: g.folder, journal: &coldJournal, validateSource: {}) }
        try check(coldCandidate == ["revision-integrity": 2], "cold retention authenticates latest and deletion candidate")
        try check(coldJournal.cleanupWarning == nil && !g.exists(prior.revision), "cold cleanup retires verified obsolete revision")
    }
    static func renameObservation() throws {
        let f = try Fixture("rename")
        let counts = try trace(f.root) { _ = try VerifiedRenameReceipt.observe(f.source) }
        try check(counts == ["manifest": 1], "one content scan per rename observation")
        for change in ["content", "namespace", "xattr"] {
            let x = try Fixture("rename-\(change)")
            var operations = Snapshot.CopyOperations()
            operations.afterScan = { _, _ in
                if change == "content" { try mutate(x.source.appendingPathComponent("payload")) }
                else if change == "namespace" { try Data().write(to: x.source.appendingPathComponent("new")) }
                else { try attribute(x.source.appendingPathComponent("payload"), "user.changed", "changed") }
            }
            try rejects { _ = try VerifiedRenameReceipt.observe(x.source, operations: operations) }
        }
    }
    static func sourceMutation() throws {
        for policy in FileVerification.allCases {
            let f = try Fixture("source-write-\(policy.rawValue)", policy: policy)
            var operations = Snapshot.CopyOperations()
            operations.afterScan = { _, phase in
                if phase == "copy-readback" { try mutate(f.source.appendingPathComponent("payload")) }
            }
            try rejects { _ = try f.capture(policy: policy, operations: operations) }
            // A same-content inode substitution also invalidates admission.
            operations.afterScan = { _, phase in
                if phase == "capture-source-before" { try Data("Xriginal".utf8).write(to: f.source.appendingPathComponent("payload"), options: .atomic) }
            }
            try rejects { _ = try f.capture(policy: policy, operations: operations) }
        }
    }
    static func corruptPrior() throws {
        let f = try Fixture("corrupt-prior"), first = try f.capture()
        try mutate(f.data(first.revision).appendingPathComponent("payload"))
        try rejects { _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: first.revision) }
        var clones = 0, operations = Snapshot.CopyOperations()
        operations.clone = { _, _, _ in clones += 1; errno = ENOTSUP; return -1 }
        let next = try f.capture(first.revision, operations: operations)
        try check(clones == 0 && next.previous == nil, "damaged prior grants no reuse authority")
        try check(String(contentsOf: f.data(next.revision).appendingPathComponent("payload"), encoding: .utf8) == "original", "current source copied")
        try check(f.exists(first.revision), "corrupt prior remains retained by capture")
        var j = try f.journal(next.revision, prior: first.revision)
        SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, verifiedRevisions: next.revisions, validateSource: {})
        try check(f.exists(first.revision) && f.exists(next.revision), "same-size corrupt prior remains retained after cleanup")
        try check(j.cleanupWarning != nil && j.retiringRevisions == [first.revision], "damaged prior excluded from reuse remains linked with cleanup warning")
    }
    static func staleEvidence() throws {
        for change in ["payload", "namespace", "root", "manifest", "mode-map"] {
            let f = try Fixture("stale-\(change)"), first = try f.capture(), next = try f.capture(first.revision)
            let data = try f.data(next.revision)
            switch change {
            case "payload": try mutate(data.appendingPathComponent("payload"))
            case "namespace": try Data().write(to: data.appendingPathComponent("unknown"))
            case "root":
                try FileManager.default.moveItem(at: data, to: f.root.appendingPathComponent("displaced-data"))
                try Store.privateDirectory(data)
            case "manifest": try mutate(data.deletingLastPathComponent().appendingPathComponent("manifest.json"))
            default: try mutate(data.deletingLastPathComponent().appendingPathComponent("modes.bin"))
            }
            try rejects { _ = try next.latest.validate(store: f.store, id: f.folder.id, revision: next.revision) }
            try rejects { _ = try next.latest.validate(store: f.store, id: f.folder.id, revision: first.revision) }
            var j = try f.journal(next.revision, prior: first.revision)
            SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, verifiedRevisions: next.revisions, validateSource: {})
            try check(j.cleanupWarning != nil && f.exists(first.revision), "stale evidence cannot authorize retirement: \(change)")
        }
        let f = try Fixture("late-retention-write"), first = try f.capture(), next = try f.capture(first.revision)
        var j = try f.journal(next.revision, prior: first.revision), validations = 0
        SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, verifiedRevisions: next.revisions, validateSource: {
            validations += 1
            if validations == 3 { try mutate(f.data(next.revision).appendingPathComponent("payload")) }
        })
        try check(validations == 3 && j.cleanupWarning != nil && f.exists(first.revision), "anchor mutation immediately before removal retains obsolete recovery data")
    }
    static func retentionSafety() throws {
        let f = try Fixture("pins"), first = try f.capture(), second = try f.capture(first.revision), third = try f.capture(second.revision)
        try Data().write(to: f.data(second.revision).appendingPathComponent("unexpected"))
        var j = try f.journal(third.revision, prior: second.revision, initial: first.revision)
        SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, verifiedRevisions: third.revisions + [first.latest], validateSource: {})
        try check(f.exists(first.revision) && f.exists(second.revision) && f.exists(third.revision), "initial pin and unexpected obsolete namespace retained")
        try check(j.cleanupWarning != nil && j.retiringRevisions == [second.revision], "unsafe obsolete candidate remains linked")
        // Without a fresh candidate token, cleanup must authenticate content
        // and retain same-size corruption even when namespace checks pass.
        try FileManager.default.removeItem(at: f.data(second.revision).appendingPathComponent("unexpected"))
        try mutate(f.data(second.revision).appendingPathComponent("payload"))
        SnapshotRetention.clean(store: f.store, folder: f.folder, journal: &j, verifiedRevisions: [third.latest, first.latest], validateSource: {})
        try check(f.exists(second.revision) && f.exists(first.revision) && f.exists(third.revision), "same-size corrupt obsolete payload and pins remain retained")
        try check(j.cleanupWarning != nil && j.retiringRevisions == [second.revision], "corrupt obsolete candidate remains linked with cleanup warning")
        // Even unchanged content cannot refresh a stale candidate token from
        // current stats or a replacement scan during this operation.
        let g = try Fixture("stale-candidate"), prior = try g.capture(), latest = try g.capture(prior.revision)
        let priorFile = try g.data(prior.revision).appendingPathComponent("payload")
        try attribute(priorFile, "user.changed", "changed")
        try check(removexattr(priorFile.path, "user.changed", XATTR_NOFOLLOW) == 0, "restore candidate attributes while leaving evidence stale")
        _ = try Snapshot.verified(store: g.store, id: g.folder.id, revision: prior.revision)
        try rejects { _ = try latest.previous!.validate(store: g.store, id: g.folder.id, revision: prior.revision) }
        var staleJournal = try g.journal(latest.revision, prior: prior.revision)
        SnapshotRetention.clean(store: g.store, folder: g.folder, journal: &staleJournal, verifiedRevisions: latest.revisions, validateSource: {})
        try check(g.exists(prior.revision) && staleJournal.cleanupWarning != nil && staleJournal.retiringRevisions == [prior.revision], "stale candidate evidence retains obsolete recovery data")
    }
    static func attribute(_ url: URL, _ name: String, _ value: String) throws {
        let bytes = Data(value.utf8)
        try check(bytes.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) } == 0, "set owned xattr")
    }
    static func sparseFixture(_ f: Fixture) throws {
        let file = f.source.appendingPathComponent("payload")
        let fd = open(file.path, O_RDWR | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        try check(fd >= 0, "open sparse fixture"); defer { close(fd) }
        var byte: UInt8 = 65
        try check(ftruncate(fd, 8 << 20) == 0 && pwrite(fd, &byte, 1, 65536) == 1 && fsync(fd) == 0, "create sparse content")
        // APFS can materialize seek/truncate gaps on flush. Punch the zero
        // ranges after syncing, preserving the block with the content byte.
        let holes: [(off_t, off_t)] = [(0, 65536), (131072, (8 << 20) - 131072)]
        for (offset, length) in holes {
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: offset, fp_length: length)
            var result: Int32
            repeat { result = fcntl(fd, F_PUNCHHOLE, &hole) } while result < 0 && errno == EINTR
            try check(result == 0, "punch sparse fixture holes")
        }
        var st = stat()
        try check(fsync(fd) == 0 && fstat(fd, &st) == 0, "sync/stat sparse fixture")
        try check(st.st_size == 8 << 20 && st.st_blocks * 512 < 1 << 20, "fixture is physically sparse after fsync")
        try check(pread(fd, &byte, 1, 65536) == 1 && byte == 65, "sparse fixture retains content byte")
        try check(link(file.path, f.source.appendingPathComponent("alias").path) == 0, "source hardlink")
        try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("symlink").path, withDestinationPath: "payload")
        try attribute(file, "user.old", "obsolete")
    }
    static func physicalSparse(_ data: URL) throws {
        let file = data.appendingPathComponent("payload"), fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try check(fd >= 0, "pin sparse destination"); defer { close(fd) }
        var st = stat(), alias = stat()
        try check(fsync(fd) == 0 && fstat(fd, &st) == 0 && lstat(data.appendingPathComponent("alias").path, &alias) == 0, "sync/stat sparse destination")
        try check(st.st_size == 8 << 20 && st.st_blocks * 512 < 1 << 20, "physical sparse allocation remains bounded after fsync")
        var byte: UInt8 = 0
        try check(pread(fd, &byte, 1, 65536) == 1 && byte == 65, "sparse destination retains content byte")
        try check(st.st_ino == alias.st_ino && st.st_nlink == 2, "hardlink topology")
    }
    static func cloneFidelity() throws {
        let f = try Fixture("clone" ); try sparseFixture(f)
        let first = try f.capture(), file = f.source.appendingPathComponent("payload")
        try check(removexattr(file.path, "user.old", XATTR_NOFOLLOW) == 0, "remove obsolete metadata")
        try attribute(file, "user.current", "new value")
        try check(chmod(file.path, 0o550) == 0 && chflags(file.path, UInt32(UF_NODUMP)) == 0, "change current metadata")
        var successes = 0, operations = Snapshot.CopyOperations()
        let clone = operations.clone
        operations.clone = { source, parent, name in
            let result = try clone(source, parent, name); if result == 0 { successes += 1 }; return result
        }
        let next = try f.capture(first.revision, operations: operations)
        try check(successes == 1, "one successful descriptor clone for the hardlink group (requires clone-capable fixture filesystem)")
        let (data, manifest) = try Snapshot.verified(store: f.store, id: f.folder.id, revision: next.revision)
        try check(manifest.matchesCopy(of: Snapshot.manifest(f.source)), "current mode/xattrs/flags and symlink fidelity")
        try check(manifest.entries.first { $0.path == "payload" }?.attributes["user.old"] == nil, "clone-only xattr removed")
        try physicalSparse(data)
    }
    static func readonlyOriginalClone() throws {
        for priorMode: mode_t in [0o444, 0o550] {
            let f = try Fixture("readonly-original-\(priorMode)")
            let prior = f.root.appendingPathComponent("original-prior")
            try Store.privateDirectory(prior)
            let currentFile = f.source.appendingPathComponent("payload"), priorFile = prior.appendingPathComponent("payload")
            try Data("original".utf8).write(to: priorFile)
            // Set distinct metadata while writable, before either source is
            // made read-only. A managed revision's physical 0600 mode would
            // hide the regression, so previousContext must remain original.
            try attribute(priorFile, "user.shared", "prior value")
            try attribute(priorFile, "user.prior-only", "obsolete")
            try attribute(currentFile, "user.shared", "current value")
            try attribute(currentFile, "user.current-only", "new")
            try attribute(priorFile, "com.apple.quarantine", "0081;65000000;RAMNestFixture;")
            try attribute(currentFile, "com.apple.quarantine", "0281;65000000;RAMNestFixture;00000000-0000-0000-0000-000000000001")
            let currentMode: mode_t = priorMode == 0o444 ? 0o550 : 0o444
            try check(chflags(priorFile.path, UInt32(UF_NODUMP)) == 0 && chmod(priorFile.path, priorMode) == 0,
                      "original prior file has read-only mode and flags")
            try check(chmod(currentFile.path, currentMode) == 0 && chmod(f.source.path, 0o550) == 0 && chmod(prior.path, 0o550) == 0,
                      "both source trees are read-only")
            let sourceBefore = try Snapshot.inspectTree(f.source, context: .original)
            let priorBefore = try Snapshot.inspectTree(prior, context: .original)
            var successes = 0, operations = Snapshot.CopyOperations()
            let clone = operations.clone
            operations.clone = { source, parent, name in
                var st = stat()
                try check(fstat(source, &st) == 0 && st.st_mode & 0o7777 == priorMode, "real clone receives read-only original prior")
                let result = try clone(source, parent, name)
                if result == 0 { successes += 1 }
                return result
            }
            let destination = f.root.appendingPathComponent("accessible-copy")
            let copied = try Snapshot.copyAccessibleTree(from: f.source, to: destination, manifest: sourceBefore.manifest,
                previous: prior, sourceContext: .original, previousContext: .original, operations: operations)
            try check(successes == 1, "requires one successful real clone, never a fallback")
            try check(copied.matchesCopy(of: sourceBefore.manifest), "logical current mode, flags and exact xattrs retained")
            var st = stat()
            try check(lstat(destination.appendingPathComponent("payload").path, &st) == 0 && st.st_mode & 0o7777 == 0o600 && st.st_flags == 0,
                      "only owned clone normalized to private file storage")
            let actualAttributes = try Snapshot.attributes(destination.appendingPathComponent("payload"))
            let currentAttributes = try Snapshot.attributes(currentFile)
            try check(["user.shared", "user.current-only", "com.apple.quarantine"].allSatisfy { actualAttributes[$0] == currentAttributes[$0] } &&
                      actualAttributes["user.prior-only"] == nil,
                      "destination has current xattrs including exact quarantine, without prior-only attributes")
            try sourceBefore.validate(at: f.source); try priorBefore.validate(at: prior)
            try check(Snapshot.manifest(f.source) == sourceBefore.manifest && Snapshot.manifest(prior) == priorBefore.manifest,
                      "source/prior contents, metadata and full ctime evidence remain unchanged")
        }
    }
    static func cloneTargetReplacement() throws {
        for kind in ["regular", "hardlink", "symlink", "fifo", "directory"] {
            let f = try Fixture("clone-target-\(kind)"), first = try f.capture()
            let sourceBefore = try Snapshot.inspectTree(f.source)
            let foreign = f.root.appendingPathComponent("foreign")
            try Data("foreign bytes".utf8).write(to: foreign)
            try attribute(foreign, "user.foreign", "must remain")
            try check(chflags(foreign.path, UInt32(UF_NODUMP)) == 0 && chmod(foreign.path, 0o444) == 0, "read-only foreign fixture")
            let pinned = open(foreign.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            try check(pinned >= 0, "pin foreign fixture"); defer { close(pinned) }
            var foreignBefore: VerifiedRenameReceipt.Node?, targetBefore: VerifiedRenameReceipt.Node?
            var targetParent: Int32 = -1, targetName = ""
            defer { if targetParent >= 0 { close(targetParent) } }
            var operations = Snapshot.CopyOperations()
            operations.afterClone = { parent, name in
                // Substitute after the clone's initial stat, before the
                // read-only pin. None of these objects grants chmod authority.
                try check(renameat(parent, name, parent, name + "-retained") == 0, "retain real clone before substitution")
                switch kind {
                case "regular": try check(renameat(AT_FDCWD, foreign.path, parent, name) == 0, "substitute foreign inode")
                case "hardlink": try check(linkat(AT_FDCWD, foreign.path, parent, name, 0) == 0, "substitute foreign hardlink")
                case "symlink": try check(symlinkat(foreign.path, parent, name) == 0, "substitute foreign symlink")
                case "fifo": try check(mkfifoat(parent, name, 0o444) == 0, "substitute fifo without blocking")
                default: try check(mkdirat(parent, name, 0o550) == 0, "substitute read-only directory")
                }
                targetParent = dup(parent); targetName = name
                try check(targetParent >= 0, "retain replacement parent descriptor")
                var st = stat(), target = stat()
                try check(fstat(pinned, &st) == 0 && fstatat(parent, name, &target, AT_SYMLINK_NOFOLLOW) == 0, "record replacement evidence")
                foreignBefore = VerifiedRenameReceipt.Node("foreign", st)
                targetBefore = VerifiedRenameReceipt.Node(name, target)
            }
            try rejects { _ = try f.capture(first.revision, operations: operations) }
            var st = stat(), target = stat()
            try check(foreignBefore != nil && targetBefore != nil && fstat(pinned, &st) == 0 &&
                      fstatat(targetParent, targetName, &target, AT_SYMLINK_NOFOLLOW) == 0 &&
                      VerifiedRenameReceipt.Node("foreign", st) == foreignBefore && VerifiedRenameReceipt.Node(targetName, target) == targetBefore,
                      "foreign replacement and symlink target retain full stat, flags, mode and ctime")
            try sourceBefore.validate(at: f.source)
            try check(Snapshot.manifest(f.source) == sourceBefore.manifest, "replacement rejection retains current source")
            _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: first.revision)
        }
    }
    static func cloneFallback() throws {
        for failure in [ENOTSUP, EXDEV, ENOSYS, EINVAL] {
            let f = try Fixture("fallback-\(failure)", policy: .sizeAndModTime); try sparseFixture(f)
            let first = try f.capture(policy: .sizeAndModTime)
            try mutate(f.source.appendingPathComponent("payload")) // same length/mtime, different CURRENT bytes
            var attempts = 0, operations = Snapshot.CopyOperations()
            operations.clone = { _, _, _ in attempts += 1; errno = failure; return -1 }
            let next = try f.capture(first.revision, policy: .sizeAndModTime, operations: operations), data = try f.data(next.revision)
            try check(attempts == 1, "forced clone fallback attempted once")
            try check(Data(contentsOf: data.appendingPathComponent("payload")).first == 88, "fallback reads CURRENT source, never prior disk bytes")
            try physicalSparse(data)
        }
    }
    static func cloneErrors() throws {
        for failure in [EACCES, EIO] {
            let f = try Fixture("clone-error-\(failure)"), first = try f.capture()
            let destination = f.root.appendingPathComponent("failed-copy")
            var attempts = 0, priorFD: Int32 = -1, operations = Snapshot.CopyOperations()
            operations.clone = { prior, _, _ in priorFD = prior; attempts += 1; errno = failure; return -1 }
            do {
                _ = try Snapshot.copyAccessibleTree(from: f.source, to: destination, manifest: Snapshot.manifest(f.source),
                    previous: f.data(first.revision), previousContext: .managedRevision, operations: operations)
                throw NestError("TEST: unexpected clone fallback")
            } catch let error as NestError {
                try check(error.code == 6 && error.message == "Snapshot clone failed (errno \(failure)).", "non-fallback errno preserved")
            }
            try check(attempts == 1, "failed clone attempted exactly once")
            try check(priorFD >= 0 && fcntl(priorFD, F_GETFD) == -1 && errno == EBADF, "failed clone closes its pinned prior descriptor")
            try check(!DirectoryHandle.open(destination).exists("payload"), "rejected clone creates no fallback target")
            try check(Data(contentsOf: f.source.appendingPathComponent("payload")) == Data("original".utf8), "current source retained")
            _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: first.revision)
        }
        // A failed syscall may have created an unknown inode. Never remove,
        // normalize, or open it for fallback, even for a supported fallback errno.
        for failure in [ENOTSUP, EXDEV, ENOSYS, EINVAL] {
            let f = try Fixture("clone-partial-\(failure)"), first = try f.capture()
            let destination = f.root.appendingPathComponent("partial-copy")
            var operations = Snapshot.CopyOperations()
            operations.clone = { _, parent, name in
                let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o400)
                try check(fd >= 0, "create owned partial target")
                defer { close(fd) }
                try check(write(fd, "partial", 7) == 7, "seed partial target")
                errno = failure; return -1
            }
            try rejects {
                _ = try Snapshot.copyAccessibleTree(from: f.source, to: destination, manifest: Snapshot.manifest(f.source),
                    previous: f.data(first.revision), previousContext: .managedRevision, operations: operations)
            }
            let partial = destination.appendingPathComponent("payload")
            try check(Data(contentsOf: partial) == Data("partial".utf8), "unknown failed target retained without fallback writes")
            try check(DirectoryHandle.open(destination).entryStat("payload").st_mode & 0o7777 == 0o400, "partial target policy unchanged")
            try check(Data(contentsOf: f.source.appendingPathComponent("payload")) == Data("original".utf8), "current source unchanged")
            _ = try Snapshot.verified(store: f.store, id: f.folder.id, revision: first.revision)
        }
    }
    static func cloneRaces() throws {
        for change in ["prior-replacement", "partial-target", "prior-symlink"] {
            let f = try Fixture(change), first = try f.capture()
            var operations = Snapshot.CopyOperations()
            let clone = operations.clone
            operations.clone = { source, parent, name in
                if change == "partial-target" {
                    let fd = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    if fd >= 0 { close(fd) }; errno = ENOTSUP; return -1
                }
                // The clone's source FD stays pinned to the authenticated inode;
                // replacement of its name must still reject the operation.
                let file = try f.data(first.revision).appendingPathComponent("payload")
                if change == "prior-symlink" {
                    _ = unlink(file.path); _ = symlink(f.source.appendingPathComponent("payload").path, file.path)
                } else { try Data("original".utf8).write(to: file, options: .atomic) }
                return try clone(source, parent, name)
            }
            try rejects { _ = try f.capture(first.revision, operations: operations) }
            try check(String(contentsOf: f.source.appendingPathComponent("payload"), encoding: .utf8) == "original", "current source remains intact")
        }
    }
}
#endif

enum SnapshotDescriptorScenarios {
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/latest-snapshot/descriptor-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let source = root.appendingPathComponent("selected")
        try Store.privateDirectory(source)
        for i in 0..<160 {
            let directory = source.appendingPathComponent("dir-\(i)")
            try Store.privateDirectory(directory)
            try Data("Owned retention fixture".utf8).write(to: directory.appendingPathComponent("file"))
        }
        let store = try Store(root: root.appendingPathComponent("store"))
        let folder = try Engine(store: store).create(path: source, name: "Descriptor retention fixture", capacity: 16 << 20)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        try store.locked {
            let revisions = try store.managedVolume(folder.id).child("revisions")
            try revisions.removeCommittedRevision(revision)
            guard try !revisions.exists(revision) else { throw NestError("Obsolete revision remains.") }
        }
        print("PASS: 160-directory snapshot cleanup")
    }
}

#if RAMNEST_SNAPSHOT_DESCRIPTOR_STANDALONE
@main enum SnapshotDescriptorTests {
    static func main() {
        do { try SnapshotDescriptorScenarios.run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
#endif
