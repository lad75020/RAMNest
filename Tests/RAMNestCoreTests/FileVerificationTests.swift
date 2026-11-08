import Foundation
import Darwin
@testable import RAMNestCore
#if !RAMNEST_VERIFICATION_STANDALONE
import Testing
extension RAMNestTestSuite {
    struct FileVerificationTests {
        @Test func `Persisted policy and real snapshot lifecycle`() throws { try FileVerificationScenarios.run() }
    }
}
#endif

enum FileVerificationScenarios {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NestError("TEST: " + message) }
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }; throw NestError("TEST: expected rejection")
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    static func policyDecode<T: Codable>(_ type: T.Type, _ value: T, read: (T) -> FileVerification) throws {
        var legacy = try object(value); legacy.removeValue(forKey: "fileVerification")
        try check(read(decode(type, legacy)) == .sha256, "absent discriminator is SHA")
        for invalid: Any in [NSNull(), "", "SHA256", "unknown", 1, true, [], [:]] {
            var malformed = legacy; malformed["fileVerification"] = invalid
            try rejects { _ = try decode(type, malformed) }
        }
    }
    static func makeFolder(_ source: URL) throws -> Folder {
        var st = stat(); try check(lstat(source.path, &st) == 0, "stat fixture")
        return Folder(name: source.lastPathComponent, path: source.path, capacity: 32<<20, device: Paths.deviceID(st.st_dev), inode: UInt64(st.st_ino))
    }
    static func mutate(_ file: URL, size: Bool = false, time: Bool = false) throws {
        let fd = open(file.path, O_RDWR | O_NOFOLLOW); try check(fd >= 0, "open mutation")
        defer { close(fd) }; var st = stat(); try check(fstat(fd, &st) == 0, "stat mutation")
        var byte: UInt8 = 88; try check(pwrite(fd, &byte, 1, 0) == 1, "write mutation")
        if size { try check(ftruncate(fd, st.st_size + 1) == 0, "change size") }
        var times = [st.st_atimespec, st.st_mtimespec]; if time { times[1].tv_sec += 1 }
        try check(futimens(fd, &times) == 0, "restore/change mtime")
    }
    static func run() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("artifacts/verification-mode-run/swift-fixtures/\(UUID().uuidString)")
        try Store.privateDirectory(root)
        try policyDecode(Configuration.self, Configuration(), read: { $0.fileVerification })
        try policyDecode(Journal.self, Journal(), read: { $0.fileVerification })
        try policyDecode(Manifest.self, Manifest(entries: []), read: { $0.fileVerification })
        try policyDecode(StoredManifest.self, StoredManifest(Manifest(entries: [])), read: { $0.fileVerification })
        print("PASS default/legacy SHA and strict missing-only decoding for configuration, journal, manifest and stored revision")
        let store = try Store(root: root.appendingPathComponent("settings")), engine = Engine(store: store)
        var journal = Journal(); journal.session = UUID(); journal.backend = .nfs; journal.phase = .mounted; journal.socket = root.appendingPathComponent("unused.sock").path
        let folder = Folder(name: "settings", path: root.path, capacity: 32<<20, device: 1, inode: 1)
        try store.write(journal, for: folder.id)
        let journalURL = try store.volume(folder.id).appendingPathComponent("journal.json"), before = try Data(contentsOf: journalURL)
        for policy in FileVerification.allCases {
            try check(engine.setFileVerification(policy) == policy, "save/readback")
            try check(Engine(store: Store(root: store.root)).fileVerification() == policy, "reopen store")
            try check(Data(contentsOf: journalURL) == before, "next-mount setting leaves session byte-exact")
            var prepared = journal; prepared.fileVerification = policy
            let args = try engine.helperArguments(folder, journal: prepared, source: root)
            try check(args.contains("--file-verification") == (policy != .sha256), "weak policy bound in helper startup arguments")
            if policy != .sha256 { try check(args.last == policy.rawValue, "exact wire policy") }
        }
        try HelperFileVerification.negotiate(.sha256) { throw NestError("old helper") }
        try rejects { try HelperFileVerification.negotiate(.sizeAndModTime) { throw NestError("old helper") } }
        try rejects { try HelperFileVerification.negotiate(.sizeAndModTime) { "unsupported" } }
        try HelperFileVerification.negotiate(.sizeAndModTime) { HelperFileVerification.version }
        journal.fileVerification = .sizeAndModTime
        for reply in [[], [HelperFileVerification.version], [HelperFileVerification.version, "sha256"], ["unknown", "sizeAndModTime"]] {
            try rejects { try HelperFileVerification.verify(journal) { _ in reply } }
        }
        try HelperFileVerification.verify(journal) { _ in [HelperFileVerification.version, "sizeAndModTime"] }
        print("PASS persisted setting/reopen, next-mount journal isolation, helper propagation, old/unknown/mismatched helper rejection")
        for policy in FileVerification.allCases { try roundTrip(root.appendingPathComponent(policy.rawValue), policy) }
        try legacyCompatibility(root.appendingPathComponent("legacy-bytes"))
        try legacyRestrictiveRecovery(root.appendingPathComponent("legacy-recovery"))
#if DEBUG
        try debugProfiles()
#endif
        try transitions(root.appendingPathComponent("transitions"))
        try relocation(root.appendingPathComponent("relocation"))
        try cleanupHistory(root.appendingPathComponent("cleanup-history"))
        try legacyCleanupHistory(root.appendingPathComponent("legacy-cleanup-history"))
    }
    static func transitions(_ root: URL) throws {
        try Store.privateDirectory(root); let source = root.appendingPathComponent("source"); try Store.privateDirectory(source)
        let file = source.appendingPathComponent("file"); try Data("original".utf8).write(to: file)
        let store = try Store(root: root.appendingPathComponent("store")); var folder = try makeFolder(source)
        let strong = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        let weak = try Snapshot.capture(store: store, folder: folder, source: source, previous: strong, verification: .sizeAndModTime)
        try mutate(file)
        folder.options.comparison = .checksum
        let copied = try Snapshot.capture(store: store, folder: folder, source: source, previous: weak, verification: .sizeAndModTime)
        let newData = try Snapshot.verified(store: store, id: folder.id, revision: copied).0
        try check(Data(contentsOf: newData.appendingPathComponent("file")) == Data(contentsOf: file), "checksum incremental selection without digests copies the current source")
        let upgraded = try Snapshot.capture(store: store, folder: folder, source: source, previous: copied, verification: .sha256)
        try check(Snapshot.verified(store: store, id: folder.id, revision: upgraded).1.fileVerification == .sha256, "new SHA capture establishes its own authority")
        try check(Snapshot.verified(store: store, id: folder.id, revision: strong).1.fileVerification == .sha256 && Snapshot.verified(store: store, id: folder.id, revision: weak).1.fileVerification == .sizeAndModTime, "historical policies unchanged across new captures")
        print("PASS new captures cross policies without relabeling old revisions; checksum incremental selection in metadata mode copies current source without adding file hashes")
    }
    static func roundTrip(_ root: URL, _ policy: FileVerification) throws {
        try Store.privateDirectory(root); let source = root.appendingPathComponent("source"); try Store.privateDirectory(source)
        let file = source.appendingPathComponent("payload"), bytes = Data(repeating: 65, count: (2<<20) + 7)
        try bytes.write(to: file)
        try check(link(file.path, source.appendingPathComponent("alias").path) == 0, "hardlink fixture")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "payload")
        let attr = Data("metadata".utf8)
        try check(attr.withUnsafeBytes { setxattr(file.path, "user.ramnest.verification", $0.baseAddress, $0.count, 0, 0) } == 0, "xattr fixture")
        let observed = try Snapshot.manifest(source, verification: policy), store = try Store(root: root.appendingPathComponent("store")), folder = try makeFolder(source)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW); try check(fd >= 0, "open hash seam"); defer { close(fd) }
        let scan = try SparseContent.scan(fd, size: Int64(bytes.count), verification: policy)
        try check(policy == .sha256 ? scan.sha256Bytes > 0 : (scan.sha256Bytes == 0 && scan.checksum.isEmpty), "file-content SHA byte counter")
        var config = Configuration(); config.folders = [folder]; config.fileVerification = policy; try store.save(config)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil, verification: policy)
        let (data, expected) = try Snapshot.verified(store: store, id: folder.id, revision: revision, verification: policy)
        try check(expected.fileVerification == policy && expected.entries.first { $0.path == "payload" }?.checksum.isEmpty == (policy == .sizeAndModTime), "revision authority")
        try check(decode(Manifest.self, object(expected)).fileVerification == policy, "manifest roundtrip")
        try check(expected.selecting(topNames: ["payload"]).fileVerification == policy && expected.excludingTrashDirectories().fileVerification == policy, "policy survives projections")
        if policy == .sizeAndModTime {
            var relabeled = try object(expected); relabeled.removeValue(forKey: "fileVerification")
            try rejects { _ = try decode(Manifest.self, relabeled) }
            try rejects { _ = try Snapshot.verified(store: store, id: folder.id, revision: revision, verification: .sha256) }
        }
        var contradicted = try object(expected); contradicted["fileVerification"] = policy == .sha256 ? "sizeAndModTime" : "sha256"
        try rejects { _ = try decode(Manifest.self, contradicted) }
        var persisted = try object(StoredManifest(expected))
        persisted["fileVerification"] = policy == .sha256 ? "sizeAndModTime" : "sha256"
        try rejects { _ = try decode(StoredManifest.self, persisted) }
        if policy == .sizeAndModTime {
            persisted.removeValue(forKey: "fileVerification")
            try rejects { _ = try decode(StoredManifest.self, persisted) }
            var mismatch = Journal(); mismatch.initialSourceManifest = expected // Journal still SHA.
            try rejects { _ = try decode(Journal.self, object(mismatch)) }
        }
        let exported = root.appendingPathComponent("exported")
        try Snapshot.copyTree(from: data, to: exported, manifest: expected, sourceContext: .managedRevision)
        try check(Snapshot.manifest(exported, matching: expected).matchesCopy(of: expected), "materialized export")
        // Fresh native-format adoption uses the session policy, not Settings.
        let stage = try store.volume(folder.id).appendingPathComponent("stage-\(UUID().uuidString)")
        let copied = try Snapshot.copyTree(from: data, to: stage, manifest: expected, privateStorage: true, sourceContext: .managedRevision)
        let modes = try StorageModes(copied); try modes.write(URL(fileURLWithPath: stage.path + ".modes"))
        let adopted = try Snapshot.adoptExport(store: store, folder: folder, stage: stage, privateStorage: true, modeMapDigest: Snapshot.digest(modes.encoded), verification: policy)
        try check(Snapshot.verified(store: store, id: folder.id, revision: adopted).1.fileVerification == policy, "adopted export authority")
        // Exercise evacuation plus cold recovery against the real Swift engine.
        var j = Journal(); j.session = UUID(); j.backend = .nfs; j.fileVerification = policy; j.phase = .preparing
        j.revision = revision; j.initialRevision = revision; j.initialSourceManifest = observed
        let engine = Engine(store: store, session: EngineSession(status: { _, _ in throw NestError("no helper in owned fixture") }))
        _ = try engine.evacuateOriginal(folder, journal: &j, expected: observed)
        j.phase = .recoveryRequired; try store.write(j, for: folder.id)
        _ = try engine.setFileVerification(policy == .sha256 ? .sizeAndModTime : .sha256)
        try engine.recover(folder.id.uuidString)
        try check(store.journal(folder.id).phase == .idle && Snapshot.manifest(source, matching: observed).matchesExpected(observed), "cold rollback uses recorded policy after Settings change")
        // Exercise the actual save coordinator, then a cold checkpoint restore.
        var live = Journal(); live.session = UUID(); live.backend = .nfs; live.fileVerification = policy; live.phase = .preparing
        live.revision = revision; live.initialRevision = revision; live.initialSourceManifest = observed
        _ = try engine.evacuateOriginal(folder, journal: &live, expected: observed)
        live.phase = .mounted; live.populationVerified = true; live.socket = root.appendingPathComponent("fixture.sock").path
        try store.write(live, for: folder.id)
        let liveSession = EngineSession(request: { _, command in
            if command == "verification-policy" { return [HelperFileVerification.version, policy.rawValue] }
            if command == "capabilities" { return ["incremental-v1", "private-storage-v2", "trash-directory-exclusion-v1"] }
            let fields = command.split(separator: "\t").map(String.init)
            guard fields.first == "export3", fields.count == 2 else { throw NestError("Unexpected fixture request: \(command)") }
            let stage = URL(fileURLWithPath: fields[1])
            let copied = try Snapshot.copyTree(from: data, to: stage, manifest: expected, privateStorage: true, sourceContext: .managedRevision)
            let modes = try StorageModes(copied); try modes.write(URL(fileURLWithPath: stage.path + ".modes"))
            return ["1", "exported", "0", "0", UUID().uuidString, Snapshot.digest(modes.encoded)]
        }, status: { _, _ in HelperStatus(id: folder.id, pid: getpid(), mounted: true, used: 0, capacity: folder.capacity, active: true) }, mountedIdentity: { _, _ in true })
        try Engine(store: store, session: liveSession).save(folder.id.uuidString)
        live = try store.journal(folder.id)
        try check(live.revision != revision && live.fileVerification == policy, "real save coordinator adopts the journal policy")
        live.restoreRevision = live.revision; live.phase = .pendingRestore; live.socket = nil; try store.write(live, for: folder.id)
        try engine.recover(folder.id.uuidString)
        try check(store.journal(folder.id).phase == .idle && Snapshot.manifest(source, matching: observed).matchesCopy(of: observed), "cold checkpoint restore")
        let checkpoint = try store.journal(folder.id).revision!
        let checkpointData = try Snapshot.dataURL(store: store, id: folder.id, revision: checkpoint)
        let copiedFile = checkpointData.appendingPathComponent("payload")
        try mutate(copiedFile)
        if policy == .sha256 { try rejects { _ = try Snapshot.verified(store: store, id: folder.id, revision: checkpoint) } }
        else { _ = try Snapshot.verified(store: store, id: folder.id, revision: checkpoint) }
        try bytes.write(to: copiedFile) // Owned corruption fixture only.
        for changeTime in [false, true] {
            let target = root.appendingPathComponent(changeTime ? "time" : "size")
            try Snapshot.copyTree(from: source, to: target, manifest: observed, privateStorage: true)
            let baseline = try Snapshot.manifest(target, verification: policy)
            try mutate(target.appendingPathComponent("payload"), size: !changeTime, time: changeTime)
            try check(!Snapshot.manifest(target, matching: baseline).matchesExpected(baseline), "size/mtime differences reject")
        }
        print("PASS \(policy.rawValue): sparse SHA counter, capture/verify/export/adopt/save, hardlinks/symlinks/xattrs, evacuation/cold rollback/checkpoint restore after preference change, size/mtime rejection and documented same-size/restored-mtime outcome")
    }
    static func relocation(_ root: URL) throws {
        try Store.privateDirectory(root)
        let source = root.appendingPathComponent("source"); try Store.privateDirectory(source); try Data("payload".utf8).write(to: source.appendingPathComponent("file"))
        let manager = SnapshotStorageManager(location: StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap"))), store = try manager.open(), folder = try makeFolder(source)
        var config = Configuration(); config.folders = [folder]; config.fileVerification = .sizeAndModTime; try store.save(config)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil, verification: .sizeAndModTime)
        let transaction = StorageRelocation.Transaction(manager: manager)
        let inventory = try transaction.scan(StorageRelocation.Root(store.root), excluding: ["repository.lock"])
        let payload = inventory.first { $0.path.hasSuffix("/data/file") }!
        try check(payload.fileVerification == .sizeAndModTime && payload.digest == nil, "opaque relocation payload must skip content hashing")
        for invalid: Any in [NSNull(), "unknown", "sha256"] {
            var malformed = try object(payload); malformed["fileVerification"] = invalid
            try rejects { _ = try decode(StorageRelocation.Item.self, malformed) }
        }
        var malformed = try object(payload); malformed.removeValue(forKey: "fileVerification")
        try rejects { _ = try decode(StorageRelocation.Item.self, malformed) }
        malformed = try object(payload); malformed["path"] = "configuration.json"
        try rejects { _ = try decode(StorageRelocation.Item.self, malformed) }
        try check(inventory.first { $0.path.hasSuffix("/manifest.json") }?.digest != nil, "control metadata still hashed")
        let parent = root.appendingPathComponent("destination-parent"); try Store.privateDirectory(parent)
        _ = try manager.move(store: store, toParent: parent)
        let reopened = try manager.open()
        try check(Snapshot.verified(store: reopened, id: folder.id, revision: revision).1.fileVerification == .sizeAndModTime, "relocation retains weak authority")
        print("PASS snapshot store relocation: weak payload has no digest; control records retain SHA; relocated revision verifies with immutable policy")
    }
}

#if RAMNEST_VERIFICATION_STANDALONE
@main struct FileVerificationRunner {
    static func main() {
        do { try FileVerificationScenarios.run() }
        catch { FileHandle.standardError.write(Data("FAIL verification: \(error)\n".utf8)); exit(1) }
    }
}
#endif

extension FileVerificationScenarios {
    // Frozen pre-policy declarations from HEAD:Snapshot.swift / PrivateStorage.swift.
    // Entry's Codable representation is unchanged. This uses the old synthesized
    // encoder, independently of Manifest.encode; never derive legacy by deleting
    // the new discriminator from a new encoder's output.
    private struct LegacyManifest: Codable {
        var entries: [Entry]
        var publicRoot: Entry? = nil
        init(_ m: Manifest) { entries = m.entries; publicRoot = m.publicRoot }
    }
    private struct LegacyObservations: Encodable {
        struct Record: Encodable {
            var manifestDigest: String
            var modeMapDigest: String?
            var basis: LegacyManifest
            var observed: LegacyManifest
        }
        var version = 1
        var device: UInt64
        var inode: UInt64
        var revisions: [String: Record]
    }
    private static func legacyBytes(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LegacyManifest(manifest))
    }
    static func legacyCompatibility(_ root: URL) throws {
        try Store.privateDirectory(root)
        let entry = Entry(path: "payload", kind: "file", size: 3, mode: 0, mtimeSeconds: 1, mtimeNanos: 2,
                          checksum: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", attributes: [:], flags: 0, attributeBytes: 0)
        let manifest = Manifest(entries: [entry])
        let frozen = Data(#"{"entries":[{"attributeBytes":0,"attributes":{},"checksum":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","flags":0,"kind":"file","mode":0,"mtimeNanos":2,"mtimeSeconds":1,"path":"payload","size":3}]}"#.utf8)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try check(legacyBytes(manifest) == frozen, "literal bytes equal frozen pre-change synthesized encoder")
        try check(encoder.encode(manifest) == frozen, "SHA manifest keeps identical historical sorted bytes")
        let decoded = try JSONDecoder().decode(Manifest.self, from: frozen)
        try check(decoded == manifest && decoded.fileVerification == .sha256, "real legacy payload record decodes as SHA")
        try check(PublicationReceipt(manifest: decoded, destination: "selected", phase: "verified-accessible").manifestDigest == Snapshot.digest(frozen), "legacy publication digest stays identical")
        var rooted = manifest; rooted.publicRoot = Entry(path: "", kind: "directory", size: 0, mode: 0o700, mtimeSeconds: 0, mtimeNanos: 0, checksum: "", attributes: [:], flags: 0, attributeBytes: 0)
        try check(encoder.encode(rooted) == legacyBytes(rooted), "public-root legacy encoding stays identical")
        let directory = try DirectoryHandle.open(root), identity = try directory.identity()
        let key = "11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222"
        let observations = LegacyObservations(device: identity.device, inode: identity.inode, revisions: [key: .init(manifestDigest: Snapshot.digest(frozen), basis: LegacyManifest(rooted), observed: LegacyManifest(rooted))])
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let oldBytes = try encoder.encode(observations), url = root.appendingPathComponent(SnapshotCopyObservations.name)
        try oldBytes.write(to: url); try check(chmod(url.path, 0o600) == 0, "private legacy observation fixture")
        let read = try SnapshotCopyObservations.read(root)
        try check(read?.revisions[key]?.basis == rooted && encoder.encode(read!) == oldBytes, "canonical relocation read/decode/reencode accepts authentic legacy nested manifests")
        print("PASS frozen pre-change encoder and literal sorted bytes; historical PublicationReceipt digest; canonical old SnapshotCopyObservations roundtrip")
    }
    static func legacyRestrictiveRecovery(_ root: URL) throws {
        try Store.privateDirectory(root); let selected = root.appendingPathComponent("selected"); try Store.privateDirectory(selected)
        let file = selected.appendingPathComponent("payload"), bytes = Data("legacy restrictive bytes".utf8); try bytes.write(to: file)
        let store = try Store(root: root.appendingPathComponent("store")), folder = try makeFolder(selected)
        var config = Configuration(); config.folders = [folder]; try store.save(config)
        let revision = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil)
        let data = try Snapshot.dataURL(store: store, id: folder.id, revision: revision)
        var logical = try Snapshot.verified(store: store, id: folder.id, revision: revision).1
        logical.entries[0].mode = 0 // Only the owned revision's logical mode map.
        let modes = try StorageModes(logical), map = data.deletingLastPathComponent().appendingPathComponent("modes.bin")
        try check(unlink(map.path) == 0, "replace owned fixture logical modes"); try modes.write(map)
        try Store.atomicJSON(StoredManifest(logical, modes: modes), data.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        _ = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        try check(unlink(file.path) == 0, "empty owned selected fixture before restore")
        var j = Journal(); j.phase = .pendingRestore; j.revision = revision; j.initialRevision = revision; j.restoreRevision = revision; j.populationVerified = true
        try store.write(j, for: folder.id)
        var cut = false
        store.beforeJournalWrite = { next, _ in
            if next.publicationReceipt?.phase == "finalizing" { cut = true; throw NestError("owned pre-finalization cut") }
        }
        try rejects { try Engine(store: store).recover(folder.id.uuidString) }
        store.beforeJournalWrite = nil; try check(cut, "restrictive publication interrupted before final modes")
        j = try store.journal(folder.id)
        let expected = j.restoreManifest!, originalDigest = Snapshot.digest(try legacyBytes(expected))
        try check(j.publicationReceipt?.manifestDigest == originalDigest, "pending receipt matches real pre-change encoder")
        j.publicationReceipt?.manifestDigest = originalDigest; try store.write(j, for: folder.id)
        let pinned = open(URL(fileURLWithPath: j.restoreStage!).appendingPathComponent("data/payload").path, O_RDONLY | O_NOFOLLOW)
        try check(pinned >= 0, "pin owned evidence before mode 000 publication"); defer { close(pinned); _ = chmod(file.path, 0o600) }
        try Engine(store: Store(root: store.root)).recover(folder.id.uuidString)
        let done = try store.journal(folder.id); var st = stat(), observed = Data(count: bytes.count)
        try check(done.phase == .idle && done.publicationReceipt?.phase == "published" && done.publicationReceipt?.manifestDigest == originalDigest, "cold restrictive recovery accepts historical receipt digest")
        try check(fstat(pinned, &st) == 0 && st.st_mode & 0o7777 == 0, "restrictive mode published exactly")
        try check(observed.withUnsafeMutableBytes { pread(pinned, $0.baseAddress, $0.count, 0) } == bytes.count && observed == bytes, "published payload via pinned evidence")
        print("PASS cold restrictive publication recovery using digest from frozen pre-change encoder; mode 000 and pinned payload verified")
    }
#if DEBUG
    static func debugProfiles() throws {
        let run = UUID()
        let rows = DebugHelperProfile.metricNames.map { ["id": $0, "calls": 0, "ns": 0, "requested": 0, "returned": 0, "errors": 0, "histogram": [0,0,0,0,0]] as [String: Any] }
        for policy in FileVerification.allCases {
            var object: [String: Any] = ["version": 2, "integrityAlgorithm": policy.rawValue, "run": run.uuidString, "phase": "read", "backend": "nfs", "compression": true, "periodicMinutes": 0, "debugBuild": true, "clock": "steady_clock_ns", "elapsedNS": 0, "stopped": true, "expired": false, "inFlight": 0, "metrics": rows]
            func frame() throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
            let profile = try DebugHelperProfile.parse([frame()], run: run, phase: "read", verification: policy)
            try rejects { _ = try DebugHelperProfile.parse([frame()], run: run, phase: "read", verification: policy == .sha256 ? .sizeAndModTime : .sha256) }
            var report = DebugBenchmarkReport(run: run, requestedBytes: 1, blockBytes: 1, mode: .read), phase = DebugBenchmarkPhase(phase: "read")
            phase.helper = profile; report.phases = [phase]
            try check(report.text.contains(policy == .sha256 ? "full logical 64 KiB SHA" : "regular-file payload SHA disabled"), "runtime report policy text")
            if policy == .sizeAndModTime {
                try check(profile.seconds(for: "sha256") == nil, "disabled SHA is N/A")
                var changedRows = rows; changedRows[8]["calls"] = 1; changedRows[8]["requested"] = 65536; object["metrics"] = changedRows
                try rejects { _ = try DebugHelperProfile.parse([frame()], run: run, phase: "read", verification: policy) }
            }
            object["integrityAlgorithm"] = "unknown"
            try rejects { _ = try DebugHelperProfile.parse([frame()], run: run, phase: "read", verification: policy) }
        }
        print("PASS strict Debug v2 schema, both runtime algorithms, mismatched/unknown algorithm rejection, metadata SHA counter rejection and honest report text")
    }
#endif
}

extension FileVerificationScenarios {
    static func legacyCleanupHistory(_ root: URL) throws {
        for originalPolicy in FileVerification.allCases {
            for emptyOnly in [false, true] {
                let fixture = root.appendingPathComponent("\(originalPolicy.rawValue)-\(emptyOnly)")
                let selected = fixture.appendingPathComponent("selected"), holding = fixture.appendingPathComponent("holding")
                try Store.privateDirectory(selected); try Store.privateDirectory(holding)
                try Data("original".utf8).write(to: holding.appendingPathComponent("original"))
                try Data("current".utf8).write(to: selected.appendingPathComponent("current"))
                let store = try Store(root: fixture.appendingPathComponent("store")), folder = try makeFolder(selected)
                let initial = try Snapshot.capture(store: store, folder: folder, source: holding, previous: nil, verification: originalPolicy)
                if emptyOnly { try FileManager.default.removeItem(at: holding.appendingPathComponent("original")) }
                let selectedPolicy: FileVerification = originalPolicy == .sha256 ? .sizeAndModTime : .sha256
                let completed = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil, verification: selectedPolicy)
                let parent = try DirectoryHandle.open(fixture), identity = try DirectoryHandle.open(holding).identity(), parentID = try parent.identity()
                // Legacy candidates have neither a source manifest nor a deletion plan.
                let candidate = SiblingCleanupCandidate(kind: .original, path: holding.path, device: identity.device, inode: identity.inode, parentDevice: parentID.device, parentInode: parentID.inode, fsid: try parent.cleanupFilesystem(), initialRevision: initial, completedRevision: completed, emptyOnly: emptyOnly)
                var journal = Journal(); journal.fileVerification = selectedPolicy; journal.revision = completed; journal.siblingCleanup = [candidate]
                try store.write(journal, for: folder.id)
                let warnings = SiblingCleanup.clean(store: store, folder: folder, journal: &journal, sourceRevision: completed, validateSource: { _ = try Snapshot.verified(store: store, id: folder.id, revision: completed) })
                try check(warnings.isEmpty && journal.siblingCleanup == nil && !FileManager.default.fileExists(atPath: holding.path), "legacy mixed-policy holding cleanup uses initial revision, not completed policy: \(warnings)")
            }
        }
        print("PASS legacy mixed-policy cleanup without source manifest or plan, both policy transitions and empty/nonempty holdings")
    }
    static func cleanupHistory(_ root: URL) throws {
        try Store.privateDirectory(root)
        let selected = root.appendingPathComponent("selected"), holding = root.appendingPathComponent("holding")
        try Store.privateDirectory(selected); try Store.privateDirectory(holding)
        for name in ["first", "second"] { try Data("original".utf8).write(to: holding.appendingPathComponent(name)) }
        let store = try Store(root: root.appendingPathComponent("store")), folder = try makeFolder(selected)
        let original = try Snapshot.manifest(holding, verification: .sizeAndModTime)
        let weak = try Snapshot.capture(store: store, folder: folder, source: holding, previous: nil, verification: .sizeAndModTime)
        // A subsequent session uses SHA; its source and the queued old holding
        // must each retain their own policy, including after partial deletion.
        try Data("current".utf8).write(to: selected.appendingPathComponent("current"))
        let strong = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil, verification: .sha256)
        let parent = try DirectoryHandle.open(root), owned = try DirectoryHandle.open(holding), identity = try owned.identity(), parentID = try parent.identity()
        var candidate = SiblingCleanupCandidate(kind: .original, path: holding.path, device: identity.device, inode: identity.inode, parentDevice: parentID.device, parentInode: parentID.inode, fsid: try parent.cleanupFilesystem(), initialRevision: weak, completedRevision: strong, emptyOnly: false)
        candidate.sourceManifest = original
        var j = Journal(); j.revision = strong; j.initialRevision = strong; j.siblingCleanup = [candidate]; try store.write(j, for: folder.id)
        var calls = 0
        let warnings = SiblingCleanup.clean(store: store, folder: folder, journal: &j, sourceRevision: strong, validateSource: { _ = try Snapshot.verified(store: store, id: folder.id, revision: strong) }, beforeUnlink: { _, _ in
            calls += 1; if calls == 2 { throw NestError("owned deferred deletion cut") }
        })
        try check(!warnings.isEmpty && owned.names().count == 1, "partial cleanup deletion actually occurred")
        j = try store.journal(folder.id)
        try check(j.fileVerification == .sha256 && j.siblingCleanup?.first?.plan?.manifest.fileVerification == .sizeAndModTime, "weak cleanup plan persists under newer SHA session")
        try check(j.siblingCleanup!.first!.plan!.manifest.entries.filter { $0.kind == "file" }.allSatisfy { $0.checksum.isEmpty }, "deferred regular file checksums remain empty")
        var config = Configuration(); config.folders = [folder]; config.fileVerification = .sizeAndModTime; try store.save(config)
        let remaining = try owned.names().first!; try mutate(holding.appendingPathComponent(remaining))
        let remainder = try owned.cleanupInventory(matching: j.siblingCleanup!.first!.plan!.manifest)
        try owned.validateCleanupRemainder(remainder, plan: j.siblingCleanup!.first!.plan!)
        let reopened = try Store(root: store.root)
        let retry = SiblingCleanup.clean(store: reopened, folder: folder, journal: &j, sourceRevision: strong, validateSource: { _ = try Snapshot.verified(store: store, id: folder.id, revision: strong) })
        try check(retry.isEmpty && j.siblingCleanup == nil && !FileManager.default.fileExists(atPath: holding.path), "cold retry uses weak per-leaf/remainder authority and removes completed old holding")
        try check(Snapshot.verified(store: store, id: folder.id, revision: strong).1.fileVerification == .sha256, "new SHA revision never weakened by preference or cleanup history")
        print("PASS mixed-policy deferred sibling cleanup: persisted weak plan, partial deletion, per-leaf/remainder checks and cold retry after preference change; strong revision remains strong")
    }
}
