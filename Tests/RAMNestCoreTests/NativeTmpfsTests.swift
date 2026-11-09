import Foundation
import Darwin
import Testing
import Security
@testable import RAMNestCore

extension RAMNestTestSuite {
    struct NativeTmpfsTests {
        private let sid = UUID(uuidString: "CABB73E4-9FD3-48DF-8057-7B07CF95FB90")!
        private func layout() -> LinkedFolderLayout {
            let id = UUID(uuidString: "54005D71-73F7-450B-9F7E-39D6FDD8D941")!
            let original = URL(fileURLWithPath: "/private/tmp/native-source")
            var result = LinkedFolderLayout(folderID: id, session: sid, stage: .reserved,
                originalPath: original.path, mountRoot: NativeTmpfsPaths.root.path,
                mountPath: NativeTmpfsPaths.data(sid).path,
                holdingPath: original.deletingLastPathComponent().appendingPathComponent(".ramnest-\(id.uuidString)-\(sid.uuidString).original").path,
                linkStagePath: original.deletingLastPathComponent().appendingPathComponent(".ramnest-\(id.uuidString)-\(sid.uuidString).link").path,
                parent: .init((1, 10)), root: .init((1, 20)), mountpoint: .init((1, 21)), source: .init((1, 11)))
            result.version = 2; return result
        }
        private func journal(mounted: Bool = false) -> Journal {
            var j = Journal(); j.phase = .preparing; j.backend = .tmpfs; j.session = sid
            j.nativeLink = layout(); j.nativeTmpfs = NativeTmpfsRecord(session: sid, capacity: 64 << 20)
            if mounted {
                j.initialRevision = UUID().uuidString; j.revision = j.initialRevision
                j.nativeTmpfs!.filesystem = NativeFilesystemID(first: 42, second: 2)
                j.nativeTmpfs!.data = .init((42, 5)); j.mountedDevice = 42
                j.nativeLink!.stage = .linked; j.nativeLink!.holding = .init((1, 12)); j.nativeLink!.link = .init((1, 13))
                j.evacuation = j.nativeLink!.holdingPath; j.evacuationDevice = 1; j.evacuationInode = 12
                j.phase = .mounted; j.populationVerified = true
            }
            return j
        }
        private func wire(_ j: Journal) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(j)) as! [String: Any]
        }
        private func decode(_ json: [String: Any]) throws -> Journal {
            try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: json))
        }
        private func fixture() throws -> URL {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("artifacts/native-tmpfs-tests/\(UUID().uuidString)")
            try Store.privateDirectory(root); return root
        }
        @Test func `Native layout uses distinct root mount workspace and logical data`() throws {
            let l = layout(); try l.validate()
            #expect(l.version == 2)
            #expect(l.mountPath == NativeTmpfsPaths.mount(sid).appendingPathComponent("tree/data").path)
            #expect(!Paths.overlaps(l.mountPath, NativeTmpfsPaths.mount(sid).appendingPathComponent(".fseventsd").path))
            #expect(l.mountPath != l.originalPath)
            let decoded = try decode(wire(journal()))
            #expect(decoded.nativeLink == l && decoded.legacyLink == nil && decoded.backend == .tmpfs)
            var bad = l; bad.mountPath = NativeTmpfsPaths.mount(sid).path
            #expect(throws: (any Error).self) { try bad.validate() }
            bad = l; bad.mountRoot = "/Volumes/foreign"
            #expect(throws: (any Error).self) { try bad.validate() }
        }
        @Test func `Legacy preferences roundtrip without relabeling or changing compression metadata`() throws {
            #expect(Configuration().backend == .tmpfs)
            #expect(FolderOptions().legacyCompression == nil)
            for backend in [Configuration.Backend.nfs, .fskit, .smb] {
                var c = Configuration(); c.backend = backend
                var options = FolderOptions(); options.legacyCompression = true
                c.folders = [Folder(name: "old", path: "/private/tmp/old", capacity: 64 << 20, device: 1, inode: 2, options: options)]
                let data = try JSONEncoder().encode(c)
                let old = try JSONDecoder().decode(Configuration.self, from: data)
                #expect(old.backend == backend && old.folders == c.folders && old.folders[0].options.legacyCompression == true)
                var j = Journal(); j.backend = backend; j.phase = .recoveryRequired
                let decoded = try decode(wire(j))
                #expect(decoded.nativeTmpfs == nil && decoded.nativeLink == nil && decoded.backend == backend)
            }
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Configuration())) as! [String: Any]
            legacy.removeValue(forKey: "backend")
            #expect(try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: legacy)).backend == .nfs)
        }
        @Test func `Native journal fails closed on mixed partial null and unknown authority`() throws {
            let good = journal(mounted: true)
            #expect(try decode(wire(good)) == good)
            for key in ["nativeLink", "nativeTmpfs"] {
                var json = try wire(good); json[key] = NSNull()
                #expect(throws: (any Error).self) { try decode(json) }
                json = try wire(good); json.removeValue(forKey: key)
                #expect(throws: (any Error).self) { try decode(json) }
            }
            for mutation in ["version", "uid", "session", "filesystem", "data", "periodicAuthorization", "unknown", "quiescence"] {
                var json = try wire(good), record = json["nativeTmpfs"] as! [String: Any]
                switch mutation {
                case "version": record[mutation] = 2
                case "uid": record[mutation] = getuid() + 1
                case "session": record[mutation] = UUID().uuidString
                case "filesystem", "data", "periodicAuthorization": record[mutation] = NSNull()
                case "quiescence": record[mutation] = "readonly-is-enough"
                default: record[mutation] = true
                }
                json["nativeTmpfs"] = record
                #expect(throws: (any Error).self) { try decode(json) }
            }
            var json = try wire(good); json["fsKitLink"] = json["nativeLink"]
            #expect(throws: (any Error).self) { try decode(json) }
            json = try wire(good); json["backend"] = "fskit"
            #expect(throws: (any Error).self) { try decode(json) }
            var unsupported = Journal(); unsupported.backend = .tmpfs; unsupported.phase = .mounted; unsupported.populationVerified = true
            #expect(throws: (any Error).self) { try decode(wire(unsupported)) }
        }
        @Test func `Historical startup discriminators remain data-only and reject malformed downgrade`() throws {
            let original = try wire(Journal())
            #expect(try decode(original).startupProtocol == nil)
            var known = original
            known["startupProtocol"] = LegacyJournalFormat.startupVersion
            known["startupHelperPID"] = 12345; known["startupRetired"] = true
            #expect(try decode(known).startupRetired == true)
            for key in ["startupHelperPID", "startupRetired"] {
                var partial = original; partial[key] = NSNull()
                #expect(throws: (any Error).self) { try decode(partial) }
            }
            for value: Any in [NSNull(), "unknown-startup-v2", 1] {
                var bad = known; bad["startupProtocol"] = value
                #expect(throws: (any Error).self) { try decode(bad) }
            }
        }
        @Test func `Native reservations cannot use unprivileged legacy data cleanup`() throws {
            #expect(throws: (any Error).self) { try LinkedFolders.releaseMountpoint(layout()) }
        }
        @Test func `Native pin status rejects unknown states identities and fictional accounting`() throws {
            let valid = [sid.uuidString, "12345", "mounted", "4096", "67108864", "active"]
            let status = try NativePinStatus.decode(valid, id: sid)
            #expect(status.active && status.mounted && status.used == 4096)
            for (index, value) in [(0, UUID().uuidString), (1, "0"), (2, "nfs"), (3, "67108865"),
                                    (4, "0"), (5, "unknown")] {
                var bad = valid; bad[index] = value
                #expect(throws: (any Error).self) { try NativePinStatus.decode(bad, id: sid) }
            }
            #expect(throws: (any Error).self) { try NativePinStatus.decode(Array(valid.dropLast()), id: sid) }
            var lost = valid; lost[2] = "lost"
            #expect(throws: (any Error).self) { try NativePinStatus.decode(lost, id: sid) }
            lost[3] = "0"; lost[5] = "guarded"
            #expect(try !NativePinStatus.decode(lost, id: sid).mounted)
        }
        @Test func `Native status JSON omits former page metrics and roundtrips kernel counters`() throws {
            let j = journal(mounted: true), l = j.nativeLink!
            let f = Folder(id: l.folderID, name: "native", path: l.originalPath, capacity: 64 << 20, device: 1, inode: 11)
            let status = FolderStatus(folder: f, journal: j, connected: true, mounted: true, used: 4096,
                nativeCapacityBytes: 64 << 20, nativeReadOnly: false, helperActive: true)
            let data = try JSONEncoder().encode(status)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            for key in ["contentBytes", "payloadBytes", "mappedBytes", "backingSavingsFraction"] { #expect(json[key] == nil) }
            #expect(json["snapshotPolicy"] as? String == "close-writers-mapping-scan-v1")
            let readback = try JSONDecoder().decode(FolderStatus.self, from: data)
            #expect(readback.used == 4096 && readback.nativeCapacityBytes == 64 << 20 && readback.nativeReadOnly == false)
        }
        @Test func `Bounded native arguments contain identities and tokens but no source store or arbitrary mount path`() throws {
            let l = layout(); let r = NativeTmpfsRecord(session: sid, capacity: 64 << 20)
            let args = try NativeTmpfsControl.arguments("mount", layout: l, record: r)
            #expect(args == ["--native-v1", "mount", String(getuid()), sid.uuidString, "1", "20", "1", "21", "67108864", "true"])
            #expect(!args.contains(l.originalPath) && !args.contains(l.mountPath))
            #expect(throws: (any Error).self) { try NativeTmpfsControl.arguments("resize", layout: l, record: r) }
            #expect(throws: (any Error).self) { try NativeTmpfsControl.arguments("freeze", layout: l, record: r) }
            var bound = r; bound.filesystem = NativeFilesystemID(first: UInt32.max, second: 2)
            #expect(try NativeTmpfsControl.arguments("freeze", layout: l, record: bound).suffix(3) == [String(UInt32.max), "2", "67108864"])
        }
        @Test func `Administrator command quotes metacharacters and passes shell text as handler data`() throws {
            #expect(NativeTmpfsControl.shellQuote("a'b") == "'a'\\''b'")
            let url = URL(fileURLWithPath: "/private/tmp/A ' $()`\\\"/ramnest-helper")
            let image = NativeHelperImage(source: url, bytes: 128, digest: String(repeating: "a", count: 64))
            let command = try NativeHelperBootstrap.command(image: image, arguments: ["--native-v1", "reserve", String(getuid()), sid.uuidString])
            let script = NativeAppleScriptContext.source(operation: sid)
            #expect(script.contains("do shell script commandText with administrator privileges without altering line endings"))
            #expect(!script.contains(url.path))
            #expect(try NativeHelperBootstrap.script(image: image, arguments: ["--native-v1", "reserve", String(getuid()), sid.uuidString]).contains("'--native-v1' 'reserve'"))
            #expect(command.hasPrefix("'/usr/bin/env' '-i' 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' 'LC_ALL=C'"))
            #expect(try NativeHelperBootstrap.script(image: image, arguments: ["--native-v1", "reserve", String(getuid()), sid.uuidString]).contains(NativeTmpfsControl.shellQuote(url.path)))
            #expect(!script.contains("sudo") && !script.contains("password"))
            #expect(throws: (any Error).self) { try NativeHelperBootstrap.command(image: image, arguments: ["--exec", "id"]) }
        }
        @Test func `Kernel identity and read-only flag are mandatory and statfs supplies allocation`() throws {
            let fs = NativeFilesystemID(first: 42, second: 2), path = NativeTmpfsPaths.mount(sid).path
            func observe(type: String = "tmpfs", actual: NativeFilesystemID? = nil, readOnly: Bool = true,
                         blocks: UInt64 = 1024, free: UInt64 = 1000, size: UInt64 = 4096) throws -> (used: UInt64, capacity: UInt64) {
                try NativeKernelMountValidation.inspect(type: type, path: path, filesystem: actual ?? fs,
                    expectedPath: path, expectedFilesystem: fs, readOnly: readOnly, requiredReadOnly: true,
                    blocks: blocks, free: free, blockSize: size)
            }
            let counters = try observe()
            #expect(counters.used == 24 * 4096 && counters.capacity == 1024 * 4096)
            for type in ["nfs", "smbfs", "fskit", "apfs"] { #expect(throws: (any Error).self) { try observe(type: type) } }
            #expect(throws: (any Error).self) { try observe(actual: .init(first: 43, second: 2)) }
            #expect(throws: (any Error).self) { try observe(readOnly: false) }
            #expect(throws: (any Error).self) { try observe(blocks: .max) }
            #expect(throws: (any Error).self) { try observe(free: 1025) }
        }
        @Test func `Read-only alone or mismatched mapping receipt cannot authorize capture`() throws {
            let fs = NativeFilesystemID(first: 42, second: 2)
            for receipt in [[], [NativeSnapshotSafety.receiptVersion], [NativeSnapshotSafety.receiptVersion, "43", "2"], ["readonly", "42", "2"]] {
                #expect(throws: (any Error).self) { try NativeSnapshotSafety.validateReceipt(receipt, filesystem: fs) }
            }
            try NativeSnapshotSafety.validateReceipt([NativeSnapshotSafety.receiptVersion, "42", "2"], filesystem: fs)
            var events: [String] = []
            #expect(throws: (any Error).self) {
                try NativeSnapshotSafety.freeze(readonly: { events.append("readonly") }, verify: { events.append("verify") })
            }
            #expect(events == ["readonly", "verify"])
        }
        @Test func `Failed mapping gate invalidates receipt and thaws before returning without copying`() throws {
            var events: [String] = [], oldRevision = "old"
            #expect(throws: (any Error).self) {
                try NativeCheckpointTransaction.run(keepFrozen: false, readonly: { events.append("readonly") }, verify: { events.append("verify") },
                    validateMappings: { events.append("mapping"); throw NestError("fd-closed shared mapping") },
                    copy: { events.append("copy"); return "new" }, commit: { oldRevision = $0 },
                    invalidate: { _, _ in events.append("invalidate") }, stillBoundReadonly: { true }, thaw: { events.append("thaw") })
            }
            #expect(oldRevision == "old" && events == ["readonly", "verify", "mapping", "invalidate", "thaw"])
        }
        @Test func `Uncertain invalidation and replaced mount leave writes guarded`() throws {
            for lost in [false, true] {
                var thaws = 0, copies = 0
                #expect(throws: (any Error).self) {
                    try NativeCheckpointTransaction.run(keepFrozen: false, readonly: {}, verify: {}, validateMappings: { throw NestError("scan failure") },
                        copy: { copies += 1; return "new" }, commit: { _ in }, invalidate: { _, _ in if !lost { throw NestError("journal fsync failed") } },
                        stillBoundReadonly: { !lost }, thaw: { thaws += 1 })
                }
                #expect(copies == 0 && thaws == 0)
            }
        }
        @Test func `Successful quiesce commits before unmount while ordinary save thaws after commit`() throws {
            for quiesce in [true, false] {
                var events: [String] = []
                let revision = try NativeCheckpointTransaction.run(keepFrozen: quiesce,
                    readonly: { events.append("readonly") }, verify: { events.append("verify") }, validateMappings: { events.append("mapping") },
                    copy: { events.append("copy"); return "new" }, commit: { _ in events.append("commit") },
                    invalidate: { _, _ in Issue.record("Unexpected invalidation") }, stillBoundReadonly: { true }, thaw: { events.append("thaw") })
                #expect(revision == "new")
                #expect(events == ["readonly", "verify", "mapping", "verify", "copy", "verify", "commit"] + (quiesce ? [] : ["thaw"]))
            }
        }
        @Test func `External unmount never authorizes a fresh RAM export and requires loss disclosure`() throws {
            var j = journal(mounted: true); j.revision = UUID().uuidString
            #expect(NativeRecoveryPolicy.needsLossDisclosure(j, sync: true))
            j.phase = .ejecting
            #expect(!NativeRecoveryPolicy.managedEject(j, sync: true))
            j.quiescedRevision = j.revision; j.quiescedSession = j.session
            #expect(!NativeRecoveryPolicy.managedEject(j, sync: true))
            j.nativeTmpfs!.quiescence = NativeSnapshotSafety.receiptVersion
            #expect(!NativeRecoveryPolicy.managedEject(j, sync: true))
            j.nativeTmpfs!.managedUnmount = true
            #expect(NativeRecoveryPolicy.managedEject(j, sync: true))
            #expect(!NativeRecoveryPolicy.needsLossDisclosure(j, sync: true))
            j.quiescedRevision = UUID().uuidString
            #expect(NativeRecoveryPolicy.needsLossDisclosure(j, sync: true))
            #expect(NativeRecoveryPolicy.managedEject(j, sync: false))
            j.phase = .restoring
            #expect(!NativeRecoveryPolicy.needsLossDisclosure(j, sync: true))
        }
        @Test func `Live resize rejects before persisting capacity while offline edit remains usable`() throws {
            let root = try fixture(), selected = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
            let store = try Store(root: root.appendingPathComponent("store")), engine = Engine(store: store)
            let folder = try engine.create(path: selected, name: "resize", capacity: 64 << 20)
            let before = try Data(contentsOf: store.root.appendingPathComponent("configuration.json"))
            // A structurally valid native journal: no OS mount or helper is needed
            // to verify resize rejection occurs before any privileged path.
            var j = journal(mounted: true); j.nativeLink!.folderID = folder.id; j.nativeLink!.originalPath = folder.path
            let parent = selected.deletingLastPathComponent()
            j.nativeLink!.holdingPath = parent.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(sid.uuidString).original").path
            j.nativeLink!.linkStagePath = parent.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(sid.uuidString).link").path
            j.evacuation = j.nativeLink!.holdingPath
            try store.write(j, for: folder.id)
            #expect(throws: (any Error).self) { try engine.resize(folder.id.uuidString, capacity: 96 << 20) }
            #expect(try Data(contentsOf: store.root.appendingPathComponent("configuration.json")) == before)
            try store.write(Journal(), for: folder.id)
            try engine.resize(folder.id.uuidString, capacity: 96 << 20)
            #expect(try engine.folder(folder.id.uuidString).capacity == 96 << 20)
        }
    }
}

extension RAMNestTestSuite.NativeTmpfsTests {
    /// Prompts here are deterministic simulations of the documented per-script
    /// grace period. No test using this probe creates NSAppleScript or runs root.
    private final class AuthorizationProbe {
        var sources: [String] = [], operations: [String] = [], commands: [String] = []
        var captures = 0, prompts = 0, finishes = 0
        var captureFailureAt: Int?
        var failure: (operation: String, number: Int)?
        var malformedAt: String?
        func operation() -> NativeTmpfsAuthorization {
            let helper = URL(fileURLWithPath: "/private/tmp/owned ' € $()`\\\"/ramnest-helper")
            return NativeTmpfsAuthorization(helper: helper, capture: { url in
                self.captures += 1
                if self.captures == self.captureFailureAt { throw NestError("Captured image authority changed", code: 4) }
                return NativeHelperImage(source: url, bytes: 128, digest: String(repeating: "a", count: 64))
            }, makeScript: { source in
                self.sources.append(source)
                return Script(self)
            })
        }
        private final class Script: NativeAdministratorExecuting {
            let probe: AuthorizationProbe
            var prompted = false, finished = false
            init(_ probe: AuthorizationProbe) { self.probe = probe }
            func execute(command: String) throws -> String {
                #expect(!finished)
                if !prompted { probe.prompts += 1; prompted = true }
                let op = ["reserve", "mount", "readonly", "freeze", "thaw", "unmount", "release"].first {
                    command.contains(String(NativeTmpfsControl.shellQuote("'--native-v1' '\($0)'").dropFirst().dropLast()))
                } ?? "unknown"
                probe.operations.append(op); probe.commands.append(command)
                if let failure = probe.failure, failure.operation == op {
                    probe.failure = nil
                    throw NativeAppleScriptFailure(number: failure.number, message: "injected native failure")
                }
                if probe.malformedAt == op { return "NOT-OK\t42\t2" }
                switch op {
                case "reserve": return "OK\t1\t20\t1\t21\n"
                case "mount": return "OK\t42\t2\t67108864\n"
                case "freeze": return "OK\t\(NativeSnapshotSafety.receiptVersion)\t42\t2\n"
                default: return "OK\n"
                }
            }
            func finish() { if !finished { probe.finishes += 1; finished = true } }
        }
    }
    private func authorizationCoordinator() throws -> Engine {
        Engine(store: try Store(root: fixture().appendingPathComponent("authorization-store")))
    }
    private func authorizationRecord() -> NativeTmpfsRecord {
        var record = NativeTmpfsRecord(session: sid, capacity: 64 << 20)
        record.filesystem = .init(first: 42, second: 2)
        return record
    }
    private func authorizationCheckpoint(_ engine: Engine, authorization: NativeTmpfsAuthorization,
                                         keepFrozen: Bool = false, failCopy: Bool = false,
                                         events: inout [String]) throws -> String {
        var receipt: [String] = []
        return try NativeCheckpointTransaction.run(keepFrozen: keepFrozen, readonly: {
            events.append("freeze")
            receipt = try engine.nativeOperation("freeze", layout: layout(), record: authorizationRecord(), authorization: authorization)
        }, verify: { events.append("verify") }, validateMappings: {
            events.append("validate-mappings")
            try NativeSnapshotSafety.validateReceipt(receipt, filesystem: authorizationRecord().filesystem!)
        }, copy: {
            events.append("copy")
            if failCopy { throw NestError("injected copy failure", code: 6) }
            return "new-checkpoint"
        }, commit: { _ in events.append("commit") }, invalidate: { _, failedThaw in
            events.append(failedThaw ? "invalidate-guarded" : "invalidate")
        }, stillBoundReadonly: { true }, thaw: {
            events.append("thaw")
            let response = try engine.nativeOperation("thaw", layout: layout(), record: authorizationRecord(), authorization: authorization)
            #expect(response.isEmpty)
        })
    }

    @Test func nativeMountUsesOneAuthorizationContext() throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe(), authorization = probe.operation()
        defer { authorization.finish() }
        #expect(probe.sources.isEmpty && probe.prompts == 0) // Lazy, after source checkpoint.
        #expect(try authorization.authorize(arguments: ["--native-v1", "reserve", String(getuid()), sid.uuidString]) == ["1", "20", "1", "21"])
        #expect(try engine.nativeOperation("mount", layout: layout(), record: authorizationRecord(), nobrowse: false, authorization: authorization) == ["42", "2", "67108864"])
        for op in ["readonly", "thaw"] {
            #expect(try engine.nativeOperation(op, layout: layout(), record: authorizationRecord(), authorization: authorization).isEmpty)
        }
        #expect(probe.operations == ["reserve", "mount", "readonly", "thaw"])
        #expect(probe.sources.count == 1 && probe.prompts == 1 && probe.captures == 4)
        #expect(probe.commands[1].contains(String(NativeTmpfsControl.shellQuote("'67108864' 'false'").dropFirst().dropLast())))
        for command in probe.commands {
            #expect(command.contains("/usr/bin/codesign --verify --strict --all-architectures"))
            #expect(command.contains("Native staged image digest mismatch"))
            #expect(command.contains("trap cleanup EXIT"))
        }
        authorization.finish(); authorization.finish()
        #expect(probe.finishes == 1)
    }

    @Test func nativeEjectSharesAuthorizationThroughRelease() throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe(), authorization = probe.operation()
        defer { authorization.finish() }
        var events: [String] = []
        #expect(try authorizationCheckpoint(engine, authorization: authorization, keepFrozen: true, events: &events) == "new-checkpoint")
        #expect(events == ["freeze", "verify", "validate-mappings", "verify", "copy", "verify", "commit"])
        #expect(try engine.nativeOperation("unmount", layout: layout(), record: authorizationRecord(), authorization: authorization).isEmpty)
        // Release follows ordinary-user restoration/publication, with this same
        // context. It is deliberately not batched ahead of those durable steps.
        #expect(try engine.nativeOperation("release", layout: layout(), record: authorizationRecord(), authorization: authorization).isEmpty)
        #expect(probe.operations == ["freeze", "unmount", "release"])
        #expect(probe.sources.count == 1 && probe.prompts == 1 && probe.captures == 3)
    }

    @Test func nativeSaveAndLiveExportUseSeparateAuthorizationContexts() throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe()
        for _ in 0..<2 {
            let authorization = probe.operation()
            defer { authorization.finish() }
            var events: [String] = []
            #expect(try authorizationCheckpoint(engine, authorization: authorization, events: &events) == "new-checkpoint")
            #expect(events.last == "thaw" && events.firstIndex(of: "commit")! < events.firstIndex(of: "thaw")!)
        }
        #expect(probe.operations == ["freeze", "thaw", "freeze", "thaw"])
        #expect(probe.sources.count == 2 && Set(probe.sources).count == 2 && probe.prompts == 2 && probe.finishes == 2)
    }

    @Test func nativeRecoveryAndTemporaryEjectUseBoundedContexts() throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe()
        for steps in [["readonly", "unmount", "release"], ["release"]] {
            let authorization = probe.operation()
            defer { authorization.finish() }
            for op in steps {
                #expect(try engine.nativeOperation(op, layout: layout(), record: authorizationRecord(), authorization: authorization).isEmpty)
            }
        }
        #expect(probe.sources.count == 2 && probe.prompts == 2 && probe.finishes == 2)
        #expect(probe.operations == ["readonly", "unmount", "release", "release"])
    }

    @Test(arguments: [-128, Int(errAuthorizationCanceled), Int(errAuthorizationDenied)])
    func nativeCancellationNeverRepromptsDuringRollback(_ number: Int) throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe(), authorization = probe.operation()
        defer { authorization.finish() }
        probe.failure = ("freeze", number)
        var events: [String] = []
        #expect(throws: (any Error).self) { try authorizationCheckpoint(engine, authorization: authorization, events: &events) }
        #expect(events == ["freeze", "invalidate", "thaw", "invalidate-guarded"])
        #expect(probe.operations == ["freeze"] && probe.captures == 1)
        #expect(probe.sources.count == 1 && probe.prompts == 1 && probe.finishes == 1)
        #expect(throws: (any Error).self) {
            try engine.nativeOperation("unmount", layout: layout(), record: authorizationRecord(), authorization: authorization)
        }
        #expect(probe.prompts == 1 && probe.captures == 1)
    }

    @Test func nativeMappingFailureThawsUsingOriginalAuthorization() throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe(), authorization = probe.operation()
        defer { authorization.finish() }
        probe.failure = ("freeze", 78)
        var events: [String] = []
        #expect(throws: (any Error).self) { try authorizationCheckpoint(engine, authorization: authorization, events: &events) }
        #expect(events == ["freeze", "invalidate", "thaw"])
        #expect(probe.operations == ["freeze", "thaw"] && probe.captures == 2)
        #expect(probe.sources.count == 1 && probe.prompts == 1)
    }

    @Test func nativeCopyFailureThawsWithoutCommittingOrNewAuthorization() throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe(), authorization = probe.operation()
        defer { authorization.finish() }
        var events: [String] = []
        #expect(throws: (any Error).self) {
            try authorizationCheckpoint(engine, authorization: authorization, failCopy: true, events: &events)
        }
        #expect(!events.contains("commit") && events.suffix(2) == ["invalidate", "thaw"])
        #expect(probe.operations == ["freeze", "thaw"] && probe.prompts == 1 && probe.sources.count == 1)
    }

    @Test func nativeFailedUnmountReusesAuthorizationForThaw() throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe(), authorization = probe.operation()
        defer { authorization.finish() }
        probe.failure = ("unmount", 16)
        #expect(throws: (any Error).self) {
            try engine.nativeOperation("unmount", layout: layout(), record: authorizationRecord(), authorization: authorization)
        }
        #expect(try engine.nativeOperation("thaw", layout: layout(), record: authorizationRecord(), authorization: authorization).isEmpty)
        #expect(probe.operations == ["unmount", "thaw"] && probe.prompts == 1 && probe.sources.count == 1)
    }

    @Test func nativeAuthorityFailureCannotStartOrReusePrivilegedExecution() throws {
        let probe = AuthorizationProbe(), authorization = probe.operation()
        defer { authorization.finish() }
        let reserve = ["--native-v1", "reserve", String(getuid()), sid.uuidString]
        probe.captureFailureAt = 1
        #expect(throws: (any Error).self) { try authorization.authorize(arguments: reserve) }
        #expect(probe.sources.isEmpty && probe.prompts == 0)
        _ = try authorization.authorize(arguments: reserve)
        probe.captureFailureAt = 3
        #expect(throws: (any Error).self) { try authorization.authorize(arguments: reserve) }
        #expect(probe.captures == 3 && probe.operations == ["reserve"] && probe.prompts == 1)
    }

    @Test func nativeScriptCreationFailureCannotStartAnotherContext() throws {
        let helper = URL(fileURLWithPath: "/private/tmp/owned-helper")
        var captures = 0, contexts = 0
        let authorization = NativeTmpfsAuthorization(helper: helper, capture: { source in
            captures += 1
            return NativeHelperImage(source: source, bytes: 128, digest: String(repeating: "a", count: 64))
        }, makeScript: { _ in
            contexts += 1
            throw NativeAppleScriptFailure(number: -2741, message: "injected compile failure")
        })
        defer { authorization.finish() }
        let reserve = ["--native-v1", "reserve", String(getuid()), sid.uuidString]
        for _ in 0..<2 {
            #expect(throws: (any Error).self) { try authorization.authorize(arguments: reserve) }
        }
        #expect(captures == 1 && contexts == 1)
    }

    @Test func nativeAppleScriptErrorDictionaryPreservesCancellation() {
        let info: NSDictionary = [NSAppleScript.errorNumber: NSNumber(value: -128), NSAppleScript.errorMessage: "User canceled."]
        let failure = NativeAppleScriptFailure(info)
        #expect(failure.number == -128 && failure.authorizationStopped)
        #expect(failure.localizedDescription.contains("User canceled."))
        #expect(!NativeAppleScriptFailure(nil).authorizationStopped)
    }

    @Test func nativeClosedOrCrossSessionContextCannotAuthorize() throws {
        let probe = AuthorizationProbe()
        var authorization: NativeTmpfsAuthorization? = probe.operation()
        let reserve = ["--native-v1", "reserve", String(getuid()), sid.uuidString]
        _ = try authorization!.authorize(arguments: reserve)
        var other = reserve; other[3] = UUID().uuidString
        #expect(throws: (any Error).self) { try authorization!.authorize(arguments: other) }
        authorization!.finish()
        #expect(throws: (any Error).self) { try authorization!.authorize(arguments: reserve) }
        #expect(probe.sources.count == 1 && probe.prompts == 1 && probe.operations == ["reserve"] && probe.finishes == 1)
        authorization = nil
        #expect(probe.finishes == 1)
        var next: NativeTmpfsAuthorization? = probe.operation()
        _ = try next!.authorize(arguments: reserve)
        next = nil // Exceptional scope exit also releases the retained context.
        #expect(probe.sources.count == 2 && probe.prompts == 2 && probe.finishes == 2)
    }

    @Test func nativeMalformedReceiptCannotAuthorizeCheckpoint() throws {
        let engine = try authorizationCoordinator(), probe = AuthorizationProbe(), authorization = probe.operation()
        defer { authorization.finish() }
        probe.malformedAt = "freeze"
        var events: [String] = []
        #expect(throws: (any Error).self) { try authorizationCheckpoint(engine, authorization: authorization, events: &events) }
        #expect(!events.contains("copy") && !events.contains("commit"))
        #expect(probe.operations == ["freeze", "thaw"] && probe.prompts == 1 && probe.sources.count == 1)
    }

    @Test func nativeAppleScriptHandlerRetainsContextAndPreservesArgumentBytes() throws {
        // Real NSAppleScript handler transport, deliberately WITHOUT any shell
        // execution/administrator command. No auth dialog or external app events.
        let source = """
        property calls : 0
        on ramnest_authorize(commandText)
            set calls to calls + 1
            return (calls as text) & ":" & commandText
        end ramnest_authorize
        """
        let script = try NativeAppleScriptContext(source: source)
        defer { script.finish() }
        let values = ["OK\t42\t2\n", "é € ' \\\" $()`\r\n", ""]
        for (index, value) in values.enumerated() {
            #expect(try script.execute(command: value) == "\(index + 1):" + value)
        }
        script.finish()
        #expect(throws: (any Error).self) { try script.execute(command: "closed") }
    }

    @Test func `Native completed idle retention and authority reset decode every durable boundary`() throws {
        let root = try fixture(), selected = root.appendingPathComponent("selected")
        try Store.privateDirectory(selected)
        let payload = selected.appendingPathComponent("payload")
        try Data("initial".utf8).write(to: payload)
        let store = try Store(root: root.appendingPathComponent("store")), engine = Engine(store: store)
        let folder = try engine.create(path: selected, name: "native-boundaries", capacity: 64 << 20)
        let initial = try Snapshot.capture(store: store, folder: folder, source: selected, previous: nil)
        try Data("restored checkpoint".utf8).write(to: payload)
        let latest = try Snapshot.capture(store: store, folder: folder, source: selected, previous: initial)
        var j = journal(mounted: true)
        var l = j.nativeLink!
        l.folderID = folder.id; l.originalPath = folder.path
        l.source = .init((folder.device, folder.inode)); l.parent = try .init(DirectoryHandle.open(root).identity())
        l.holding = .init((l.parent.device, l.parent.inode + 123))
        l.link = .init((l.parent.device, l.parent.inode + 124))
        l.holdingPath = root.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(sid.uuidString).original").path
        l.linkStagePath = root.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(sid.uuidString).link").path
        l.stage = .restored; l.restoration = .original; l.restored = l.source; l.mountReleased = true
        j.nativeLink = l; j.phase = .restoring; j.nativeTmpfs!.managedUnmount = true
        j.initialRevision = initial; j.revision = latest; j.restoreRevision = latest
        j.evacuation = nil; j.evacuationDevice = nil; j.evacuationInode = nil
        var boundaries = 0
        store.beforeJournalWrite = { candidate, _ in
            let bytes = try JSONEncoder().encode(candidate)
            #expect(try JSONDecoder().decode(Journal.self, from: bytes) == candidate)
            boundaries += 1
        }
        try store.write(j, for: folder.id) // restored, before completed-idle commit
        try NativeJournalTransition.completeIdle(&j)
        try store.write(j, for: folder.id)
        #expect(j.nativeSessionCompleted && j.populationVerified && j.initialRevision == initial)
        SnapshotRetention.clean(store: store, folder: folder, journal: &j, validateSource: { try Paths.checkedIdentity(folder) })
        let durable = try store.journal(folder.id)
        #expect(durable.nativeSessionCompleted && durable.initialRevision == nil && durable.restoreRevision == nil)
        #expect(durable.revision == latest && durable.cleanupWarning == nil)
        #expect(!FileManager.default.fileExists(atPath: try Snapshot.dataURL(store: store, id: folder.id, revision: initial).path))
        #expect(throws: (any Error).self) { try NativeTmpfsControl.observe(durable) }
        var edited = folder; edited.options.periodicSave = true
        try engine.update(edited) // idle future-schedule edits grant no live ticket
        #expect(try store.journal(folder.id).nativeTmpfs?.periodicAuthorization == nil)
        j = try store.journal(folder.id)
        try NativeJournalTransition.resetCompletedAuthority(&j)
        try store.write(j, for: folder.id) // crash before preparing is readable too
        #expect(j.nativeTmpfs == nil && j.nativeLink == nil && !j.populationVerified && j.revision == latest)
        j.phase = .preparing; j.session = UUID(); j.backend = .tmpfs
        try store.write(j, for: folder.id)
        #expect(try store.journal(folder.id).phase == .preparing)
        #expect(boundaries >= 5)
        store.beforeJournalWrite = nil
        let durableBytes = try Data(contentsOf: store.volume(folder.id).appendingPathComponent("journal.json"))
        var halfReset = j; halfReset.populationVerified = true
        #expect(throws: (any Error).self) { try store.write(halfReset, for: folder.id) }
        #expect(try Data(contentsOf: store.volume(folder.id).appendingPathComponent("journal.json")) == durableBytes)
        var active = journal(mounted: true); active.initialRevision = nil
        #expect(throws: (any Error).self) { try decode(wire(active)) }
        #expect(throws: (any Error).self) { try NativeJournalTransition.resetCompletedAuthority(&active) }
    }

    @Test func `Delayed periodic work is fenced after the lock before any native operation`() throws {
        let root = try fixture(), selected = root.appendingPathComponent("selected")
        try Store.privateDirectory(selected)
        let store = try Store(root: root.appendingPathComponent("store")), engine = Engine(store: store)
        let folder = try engine.create(path: selected, name: "periodic-fence", capacity: 64 << 20)
        var configured = folder; configured.options.periodicSave = true
        var config = try store.load(); config.folders = [configured]; try store.save(config)
        var old = journal(mounted: true)
        // Data-only journal authority; no mount/root/pin is created. A valid old
        // request must be rejected at the lock boundary before filesystem I/O.
        old.nativeLink!.folderID = folder.id; old.nativeLink!.originalPath = folder.path
        old.nativeLink!.holdingPath = root.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(sid.uuidString).original").path
        old.nativeLink!.linkStagePath = root.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(sid.uuidString).link").path
        old.evacuation = old.nativeLink!.holdingPath
        let ticket = UUID(); old.nativeTmpfs!.periodicAuthorization = ticket; old.socket = "/private/tmp/old-pin.sock"
        let request = NativePeriodicSaveRequest(session: sid, first: 42, second: 2, verification: .sha256,
            interval: 15, authorization: ticket, socket: old.socket!)
        try request.validate(folder: configured, journal: old)
        try store.write(old, for: folder.id)
        var boundary = EngineSession()
        var successorBytes = Data()
        boundary.beforeVolumeLock = { _ in
            var replacement = Journal(); replacement.backend = .tmpfs; replacement.phase = .preparing; replacement.session = UUID()
            try store.write(replacement, for: folder.id)
            successorBytes = try Data(contentsOf: store.volume(folder.id).appendingPathComponent("journal.json"))
            var config = try store.load(); config.folders[0].options.periodicSave = false; try store.save(config)
        }
        let delayed = Engine(store: store, helper: root.appendingPathComponent("must-not-run"), session: boundary)
        let before = old.revision
        do { try delayed.periodicSave(folder.id.uuidString, expected: request); Issue.record("Old periodic worker reached native work") }
        catch { #expect(error.localizedDescription.contains("Retired or changed periodic")) }
        #expect(try store.journal(folder.id).revision != before)
        #expect(try store.journal(folder.id).phase == .preparing)
        #expect(try Data(contentsOf: store.volume(folder.id).appendingPathComponent("journal.json")) == successorBytes)
        for mutation in ["session", "fsid", "pin", "ticket", "policy", "disabled", "interval"] {
            var j = old, f = configured
            switch mutation {
            case "session": j.session = UUID()
            case "fsid": j.nativeTmpfs!.filesystem = .init(first: 43, second: 2)
            case "pin": j.socket = "/private/tmp/successor-pin.sock"
            case "ticket": j.nativeTmpfs!.periodicAuthorization = UUID()
            case "policy": j.fileVerification = .sizeAndModTime
            case "disabled": f.options.periodicSave = false
            default: f.options.intervalMinutes = 30
            }
            #expect(throws: (any Error).self) { try request.validate(folder: f, journal: j) }
        }
    }

    @Test func `Administrator bootstrap rejects source replacement and unsigned staged bytes before execution`() throws {
        func runScript(_ script: String) throws {
            _ = try Control.run("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "/bin/sh", "-c", script])
        }
        let root = try fixture(), source = root.appendingPathComponent("quoted ' source")
        let stage = root.appendingPathComponent("stage"); try Store.privateDirectory(stage)
        let original = Data("original intended image".utf8), digest = Snapshot.digest(original)
        try original.write(to: source)
        let image = NativeHelperImage(source: source, bytes: original.count, digest: digest)
        let bootstrap = try NativeHelperBootstrap.script(image: image, arguments: ["--native-v1", "reserve", String(getuid()), sid.uuidString])
        #expect(bootstrap.contains("mktemp -d /Users/Shared/.RAMNestNativeExec."))
        #expect(!bootstrap.contains("rm -r") && !bootstrap.contains("chown"))
        #expect(bootstrap.contains("trap cleanup EXIT") && bootstrap.contains("identity"))
        #expect(bootstrap.contains("cd /"))
        #expect(bootstrap.contains("stat -f '%u:%p' /Users/Shared") && bootstrap.contains("0:41777"))
        #expect(try Control.run("/bin/pwd", [], currentDirectory: URL(fileURLWithPath: "/")).trimmingCharacters(in: .whitespacesAndNewlines) == "/")
        #expect(throws: (any Error).self) { try runScript(bootstrap) } // ordinary uid cannot stage/execute root work
        let commands = try NativeHelperBootstrap.copyVerification(source: source, bytes: original.count, digest: digest)
        let prefix = "set -eu\nstage=" + NativeTmpfsControl.shellQuote(stage.path) + "\n"
        try Data(repeating: 0x78, count: original.count).write(to: source)
        do { try runScript(prefix + commands); Issue.record("Changed source was accepted") }
        catch { #expect(error.localizedDescription.contains("staged image digest mismatch")) }
        #expect(try Data(contentsOf: stage.appendingPathComponent("helper")) != original)
        #expect(unlink(stage.appendingPathComponent("helper").path) == 0)
        try original.write(to: source)
        // Exact digest alone is not a signature. This plain-text image must fail
        // the system codesign check, never be invoked as an executable.
        #expect(throws: (any Error).self) { try runScript(prefix + commands) }
        #expect(unlink(stage.appendingPathComponent("helper").path) == 0)
        #expect(unlink(source.path) == 0)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: root.appendingPathComponent("unknown"))
        #expect(throws: (any Error).self) { try runScript(prefix + commands) }
        #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("helper").path))
        #expect(throws: (any Error).self) { try NativeHelperImage.capture(helper: source) }
        // Exercise the real system signature verifier without
        // building code, mounting, authorization or invoking the staged image.
        let signed = URL(fileURLWithPath: "/usr/bin/true"), signedBytes = try Data(contentsOf: signed)
        let verify = try NativeHelperBootstrap.copyVerification(source: signed, bytes: signedBytes.count,
            digest: Snapshot.digest(signedBytes))
        try runScript(prefix + verify)
        #expect(try Data(contentsOf: stage.appendingPathComponent("helper")) == signedBytes)
    }
}
