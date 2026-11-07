import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_QUARANTINE_SNAPSHOT_STANDALONE
import XCTest

final class QuarantineSnapshotTests: XCTestCase {
    func testExactQuarantineSnapshotCopy() throws { try QuarantineSnapshotScenarios.run() }
}
#endif

enum QuarantineSnapshotScenarios {
    static let quarantine = "com.apple.quarantine"
    static let synthetic = Data("0281;65000000;RAMNestFixture;00000000-0000-0000-0000-000000000001".utf8)

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NestError("TEST: " + message) }
    }
    static func descriptor(_ url: URL) throws -> Int32 {
        var st = stat()
        try check(lstat(url.path, &st) == 0, "fixture entry exists")
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | (st.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW))
        try check(fd >= 0, "open fixture without following a symlink")
        return fd
    }
    static func attribute(_ url: URL, _ name: String = quarantine) throws -> Data? {
        let fd = try descriptor(url); defer { close(fd) }
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        if size < 0 && errno == ENOATTR { return nil }
        try check(size >= 0 && size <= 16 * 1024 * 1024, "read fixture xattr size: " + name)
        var data = Data(count: size)
        try check(data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, size, 0, 0) } == size, "read fixture xattr: " + name)
        return data
    }
    static func setAttribute(_ url: URL, _ value: Data, _ name: String = quarantine) throws {
        let fd = try descriptor(url); defer { close(fd) }
        try check(value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, value.count, 0, 0) } == 0, "set synthetic fixture xattr: " + name)
        try check(try attribute(url, name) == value, "OS must retain exact synthetic fixture xattr: " + name)
    }
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.appendingPathComponent("artifacts/scripts-snapshot-fix/fixtures-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let source = root.appendingPathComponent("minimal-source")
        try Store.privateDirectory(source)
        let file = source.appendingPathComponent("generated.txt")
        try Data("Generated inert quarantine fixture.\n".utf8).write(to: file)
        try setAttribute(file, synthetic)
        let before = try Snapshot.manifest(source)
        let copy = root.appendingPathComponent("minimal-copy")
        do { try Snapshot.copyTree(from: source, to: copy, manifest: before) }
        catch {
            try check(try attribute(file) == synthetic && Snapshot.manifest(source) == before, "failed copy leaves source bytes and attributes unchanged")
            if try attribute(copy.appendingPathComponent("generated.txt")) != synthetic {
                throw NestError("TEST: generated.txt xattr com.apple.quarantine differs after copy; source unchanged. \(error.localizedDescription)")
            }
            throw error
        }
        try check(try attribute(copy.appendingPathComponent("generated.txt")) == synthetic, "exact quarantine bytes copied")
        try check(try Snapshot.manifest(source) == before, "source bytes and attributes unchanged")
        print("PASS: minimal generated regular file preserves exact quarantine bytes and source metadata")
        try treeAndRecovery(root)
        try changedSource(root)
        for mode: mode_t in [0o750, 0o550] {
            try rootMetadataRecovery(root, mode: mode, interrupted: false)
            try rootMetadataRecovery(root, mode: mode, interrupted: true)
        }
    }

    static func unchangedIdentities(_ root: URL, _ manifest: Manifest) throws -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        for path in [""] + manifest.entries.map(\.path) {
            var st = stat()
            try check(lstat(root.appendingPathComponent(path).path, &st) == 0, "source root/entry remains")
            result[path] = [Int64(st.st_dev), Int64(st.st_ino), Int64(st.st_nlink), Int64(st.st_ctimespec.tv_sec), Int64(st.st_ctimespec.tv_nsec)]
        }
        return result
    }
    static func exactAttributes(_ source: URL, _ copy: URL, _ manifest: Manifest) throws {
        try check(try Snapshot.manifest(copy) == manifest, "full metadata, checksums and hardlink groups match")
        for entry in manifest.entries {
            for name in Set(entry.attributes.keys).union([quarantine]) {
                try check(try attribute(source.appendingPathComponent(entry.path), name) == attribute(copy.appendingPathComponent(entry.path), name), "exact xattr bytes/absence: \(entry.path) \(name)")
            }
        }
    }
    static func rejects(_ tokens: [String], _ body: () throws -> Void) throws {
        var message: String?
        do { try body() } catch { message = error.localizedDescription }
        guard let message else { throw NestError("TEST: expected verification rejection") }
        try check(tokens.allSatisfy { message.contains($0) }, "diagnostic identifies first mismatch path and field/xattr")
        try check(message.count < 700 && !message.contains("\n") && !message.contains("65000000") && !message.contains("Generated inert"), "bounded diagnostic excludes attribute values and file contents")
    }
    static func treeAndRecovery(_ root: URL) throws {
        let source = root.appendingPathComponent("tree-source")
        let nested = source.appendingPathComponent("nested/leaf")
        try Store.privateDirectory(nested)
        let file = source.appendingPathComponent("a-file.txt")
        let bytes = Data("Generated inert tree fixture.\n".utf8)
        try bytes.write(to: file)
        try setAttribute(file, synthetic)
        let custom = "user.ramnest-fixture"
        try setAttribute(file, Data([0, 1, 2, 255]), custom)
        var finderInfo = Data(repeating: 0, count: 32); finderInfo[0] = 0x54
        try setAttribute(file, finderInfo, "com.apple.FinderInfo")
        try setAttribute(file, Data("inert resource fork".utf8), "com.apple.ResourceFork")
        try check(chmod(file.path, 0o640) == 0, "set fixture file mode")
        let hardlink = source.appendingPathComponent("z-hard.txt")
        try check(link(file.path, hardlink.path) == 0, "create fixture hardlink")
        let absent = nested.appendingPathComponent("absent.txt")
        try Data("No quarantine on this generated file.\n".utf8).write(to: absent)
        try check(try attribute(absent) == nil, "fixture starts without quarantine")
        let readonly = nested.appendingPathComponent("readonly.txt")
        try bytes.write(to: readonly); try setAttribute(readonly, synthetic)
        try check(chmod(readonly.path, 0o444) == 0, "set read-only fixture mode")
        let matching = nested.appendingPathComponent("matching.txt")
        try bytes.write(to: matching)
        try setAttribute(matching, Data("0081;65000000;RAMNestFixture;".utf8))
        try setAttribute(nested, synthetic)
        try setAttribute(nested, Data("directory metadata".utf8), custom)
        let target = root.appendingPathComponent("symlink-target.txt")
        try Data("Generated target must remain unchanged.\n".utf8).write(to: target)
        let targetBytes = try Data(contentsOf: target)
        let targetAttrs = try Snapshot.attributes(target)
        let symlink = nested.appendingPathComponent("link")
        try check(Darwin.symlink("../../../symlink-target.txt", symlink.path) == 0, "create generated symlink")
        try setAttribute(symlink, synthetic)
        try check(chmod(nested.path, 0o550) == 0, "set read-only fixture directory mode")
        let expected = try Snapshot.manifest(source)
        let identities = try unchangedIdentities(source, expected)
        let copy = root.appendingPathComponent("tree-copy")
        try Snapshot.copyTree(from: source, to: copy, manifest: expected)
        try exactAttributes(source, copy, expected)
        let reused = root.appendingPathComponent("reused-copy")
        try Snapshot.copyTree(from: source, to: reused, manifest: expected, previous: copy, comparison: .sizeAndModTime)
        try exactAttributes(source, reused, expected)
        print("PASS: directory, symlink, hardlink, nested tree, read-only file, absent/matching quarantine and other xattrs")

        let selected = root.appendingPathComponent("selected")
        try Store.privateDirectory(selected)
        let identity = try DirectoryHandle.open(selected).identity()
        let folder = Folder(name: "Generated quarantine fixture", path: selected.path, capacity: 16 << 20, device: identity.device, inode: identity.inode)
        let store = try Store(root: root.appendingPathComponent("store"))
        var config = Configuration(); config.folders = [folder]; try store.save(config)
        let revision = try store.locked { try Snapshot.capture(store: store, folder: folder, source: source, previous: nil) }
        let (data, saved) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        try check(saved == expected, "capture retains original manifest schema and exact hashes")
        try check(try JSONDecoder().decode(Manifest.self, from: JSONEncoder().encode(saved)) == saved, "manifest JSON round trip remains compatible")
        var journal = Journal(); journal.phase = .pendingRestore; journal.populationVerified = true
        journal.revision = revision; journal.restoreRevision = revision
        try store.write(journal, for: folder.id)
        // No native helper, socket, mount or live store participates in this restore.
        let session = EngineSession(status: { _, _ in throw NestError("Generated fixture has no helper") })
        try Engine(store: store, session: session).recover(folder.id.uuidString)
        try exactAttributes(source, selected, expected)
        try check(try store.journal(folder.id).phase == .idle, "coordinator recovery commits verified restore")
        print("PASS: capture, verified snapshot and coordinator restore preserve exact quarantine and full manifests")

        let savedFile = data.appendingPathComponent("a-file.txt")
        let altered = Data("0081;65000000;RAMNestFixture;".utf8)
        try setAttribute(savedFile, altered)
        try rejects(["a-file.txt", quarantine]) { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
        try setAttribute(savedFile, synthetic)
        try setAttribute(savedFile, Data([9, 8, 7, 6]), custom)
        try rejects(["a-file.txt", custom]) { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
        try setAttribute(savedFile, Data([0, 1, 2, 255]), custom)
        let entry = expected.entries.first { $0.path == "a-file.txt" }!
        try Data(repeating: 0x4A, count: bytes.count).write(to: savedFile)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(entry.mtimeSeconds), tv_nsec: Int(entry.mtimeNanos))]
        try check(utimensat(AT_FDCWD, savedFile.path, &times, AT_SYMLINK_NOFOLLOW) == 0, "restore fixture mtime to isolate checksum tampering")
        try rejects(["a-file.txt", "checksum"]) { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision) }
        try check(try Snapshot.manifest(source) == expected && unchangedIdentities(source, expected) == identities, "source bytes/attrs/inodes/link counts/ctime unchanged; no source attribute removal")
        try check(try Data(contentsOf: target) == targetBytes && Snapshot.attributes(target) == targetAttrs, "symlink metadata operations never touch target")
        print("PASS: quarantine, other-xattr and checksum tampering rejected with bounded field diagnostics; source untouched")
    }
    static func changedSource(_ root: URL) throws {
        let source = root.appendingPathComponent("changing-source")
        try Store.privateDirectory(source)
        let file = source.appendingPathComponent("changed.txt")
        try Data("Generated inert changed-source fixture.\n".utf8).write(to: file)
        try setAttribute(file, synthetic)
        let expected = try Snapshot.manifest(source)
        let changed = Data("0081;65000000;RAMNestFixture;".utf8)
        try setAttribute(file, changed)
        try rejects(["changed.txt", quarantine, "No source files were removed"]) {
            try Snapshot.copyTree(from: source, to: root.appendingPathComponent("stale-manifest-copy"), manifest: expected)
        }
        try check(try attribute(file) == changed, "stale manifest rejection retains changed source attribute")
        let unmarked = root.appendingPathComponent("unmarked-source")
        try Store.privateDirectory(unmarked)
        let unmarkedFile = unmarked.appendingPathComponent("added.txt")
        try Data("Generated inert unmarked fixture.\n".utf8).write(to: unmarkedFile)
        let unmarkedManifest = try Snapshot.manifest(unmarked)
        try setAttribute(unmarkedFile, synthetic)
        try rejects(["added.txt", quarantine, "No source files were removed"]) {
            try Snapshot.copyTree(from: unmarked, to: root.appendingPathComponent("added-attribute-copy"), manifest: unmarkedManifest)
        }
        try check(try attribute(unmarkedFile) == synthetic, "new source quarantine is never removed to match a stale manifest")
        print("PASS: changed/added source quarantine rejects stale manifests without removing attributes")
    }

    static func rootMetadataRecovery(_ root: URL, mode: mode_t, interrupted: Bool) throws {
        let fixture = root.appendingPathComponent("root-\(mode)-\(interrupted)")
        let source = fixture.appendingPathComponent("source"), selected = fixture.appendingPathComponent("selected")
        try Store.privateDirectory(source); try Store.privateDirectory(selected)
        let payload = Data("Owned root quarantine recovery bytes.\n".utf8)
        let file = source.appendingPathComponent("a-payload")
        try payload.write(to: file)
        try check(link(file.path, source.appendingPathComponent("z-alias").path) == 0, "root recovery hardlink fixture")
        try setAttribute(source, synthetic)
        try setAttribute(source, Data([0, 7, 255]), "user.ramnest-root")
        try check(chflags(source.path, UInt32(UF_HIDDEN | UF_NODUMP)) == 0, "supported public root flags")
        try check(chmod(source.path, mode) == 0, "public root writable/read-only mode")
        let expected = try Snapshot.manifest(source)
        let identities = try unchangedIdentities(source, expected)
        let sourceIdentity = try DirectoryHandle.open(source).identity()
        let store = try Store(root: fixture.appendingPathComponent("store"))
        let folder = try Engine(store: store).create(path: selected, name: "owned root", capacity: 16 << 20)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        let (committed, saved) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        try check(saved == expected && attribute(committed) == synthetic, "capture authenticates exact public root quarantine")
        let committedIdentity = try DirectoryHandle.open(committed).identity()
        let committedEntries = try unchangedIdentities(committed, saved)
        let engine = Engine(store: store, session: EngineSession(status: { _, _ in throw NestError("owned fixture has no helper") }))
        var journal = Journal(); journal.phase = .pendingRestore; journal.populationVerified = true
        journal.revision = revision; journal.restoreRevision = revision
        try store.write(journal, for: folder.id)
        let exported = fixture.appendingPathComponent("export")
        try engine.export(folder.id.uuidString, destination: exported)
        try check(try Snapshot.manifest(exported) == expected && attribute(exported) == synthetic,
                  "production export validates committed snapshot before recovery")
        if interrupted {
            #if RAMNEST_QUARANTINE_SNAPSHOT_STANDALONE && !RAMNEST_QUARANTINE_THROW_INTERRUPTION
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--interrupt-root-restore", store.root.path, folder.id.uuidString]
            try child.run(); child.waitUntilExit()
            try check(child.terminationReason == .exit && child.terminationStatus == 87, "actual process exit after durable rename before journal ACK")
            if mode & 0o200 == 0 {
                let journal = try store.journal(folder.id)
                let stage = URL(fileURLWithPath: journal.restoreStage!)
                var st = stat()
                try check(lstat(stage.appendingPathComponent("data").path, &st) == 0 && st.st_mode & 0o7777 == mode | 0o300,
                          "crash leaves only private staged root in temporary owner-writable mode")
                try check(FileManager.default.fileExists(atPath: stage.appendingPathComponent(".root-move-permissions").path),
                          "durable permission marker authorizes exact-mode restoration before retry integrity checks")
            }
            #else
            var injected = false
            store.beforeJournalWrite = { value, id in
                if id == folder.id && value.phase == .restoring && value.restoredEntries.count == 1 && !injected {
                    injected = true
                    throw NestError("owned move-before-journal interruption")
                }
            }
            var failure: String?
            do { try engine.recover(folder.id.uuidString) } catch { failure = error.localizedDescription }
            try check(injected && failure == "owned move-before-journal interruption", "deterministic durable-move interruption")
            #endif
            try check(FileManager.default.fileExists(atPath: selected.appendingPathComponent("a-payload").path), "first payload moved before interruption")
            try check(try store.journal(folder.id).phase == .restoring, "retry retains restoring journal")
            try check(try Snapshot.verified(store: store, id: folder.id, revision: revision).1 == expected, "interruption retains authenticated committed revision")
            store.beforeJournalWrite = nil
            if mode & 0o200 == 0 {
                let journal = try store.journal(folder.id)
                let data = URL(fileURLWithPath: journal.restoreStage!).appendingPathComponent("data")
                let fd = try descriptor(data); defer { close(fd) }
                try check(fchmod(fd, mode | 0o300) == 0, "owned staged-root corruption fixture permissions")
                let changed = Data("0081;65000000;RAMNestFixture;".utf8)
                try setAttribute(data, changed)
                var rejected = false
                do { try engine.recover(folder.id.uuidString) } catch {
                    rejected = error.localizedDescription.contains("Restore staging contents changed")
                }
                try check(rejected && attribute(data) == changed,
                          "permission replay never normalizes changed quarantine; strict root verification rejects before remaining moves")
                try check(!FileManager.default.fileExists(atPath: selected.appendingPathComponent("z-alias").path),
                          "root metadata corruption retains remaining staged payload")
                try check(fchmod(fd, mode | 0o300) == 0, "repair only owned synthetic staged-root attribute")
                try setAttribute(data, synthetic)
                try check(fchmod(fd, mode) == 0 && fsync(fd) == 0, "restore exact fixture mode before retry")
            }
        }
        try engine.recover(folder.id.uuidString)
        try check(try store.journal(folder.id).phase == .idle, "root quarantine recovery ends idle")
        try check(try Snapshot.manifest(selected) == expected && attribute(selected) == synthetic,
                  "root exact mode/flags/xattrs/quarantine and payload restored")
        try check(try Data(contentsOf: selected.appendingPathComponent("a-payload")) == payload, "root recovery payload bytes")
        try check(try Snapshot.manifest(source) == expected && unchangedIdentities(source, expected) == identities &&
                  DirectoryHandle.open(source).identity() == sourceIdentity, "source root and entries unchanged")
        try check(try Snapshot.verified(store: store, id: folder.id, revision: revision).1 == expected &&
                  DirectoryHandle.open(committed).identity() == committedIdentity && unchangedIdentities(committed, saved) == committedEntries,
                  "committed root and entries unchanged after export/recovery/retry")
        print("PASS: exact public-root quarantine capture/copy/export/recover mode=\(String(mode, radix: 8)) interrupted=\(interrupted); idle, hardlinks and source/revision retained")
    }
}
