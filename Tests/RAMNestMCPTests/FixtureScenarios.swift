import Foundation
import Darwin
@testable import RAMNestCore
@testable import RAMNestMCPKit

enum MCPAdvancedScenarios {
    static func run(root: URL) async throws {
        try nativeReviewAdmission()
        try await cancellation(root: root)
        try await review(root: root)
        try await destructiveOwnedDelete(root: root)
    }
    static func nativeReviewAdmission() throws {
        var legacy = Journal(); legacy.backend = .fskit
        try Activities.requireSupportedReview(legacy)
        var backendOnly = Journal(); backendOnly.backend = .tmpfs
        var recordOnly = Journal()
        recordOnly.nativeTmpfs = NativeTmpfsRecord(session: UUID(), capacity: 32 << 20)
        for journal in [backendOnly, recordOnly] {
            do {
                try Activities.requireSupportedReview(journal)
                throw MCPFailure("test_failed", "Native review was admitted before privileged release support")
            } catch let failure as MCPFailure where failure.code == "unavailable" { }
        }
    }
    static func cancellation(root: URL) async throws {
        let bootstrap = root.appendingPathComponent("cancel-store"), parent = root.appendingPathComponent("cancel-destination")
        try Store.privateDirectory(parent)
        let manager = SnapshotStorageManager(location: StoreLocation(bootstrapRoot: bootstrap))
        let activities = Activities(manager: manager)
        _ = try await activities.call("settings_get")
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        manager.fault = { name in
            if name == "reserved" { reached.signal(); _ = release.wait(timeout: .now() + 10) }
        }
        _ = try await activities.call("storage_move", arguments: ["parent": .string(parent.path)])
        let arrived = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: reached.wait(timeout: .now() + 10) == .success) }
        }
        guard arrived else { release.signal(); throw MCPFailure("test_failed", "Storage worker did not reach owned barrier") }
        try await MCPScenarios.expectFailure({ try await activities.call("settings_get") }, "busy excludes store while worker runs")
        let paused = try await activities.call("storage_pause")
        try MCPScenarios.check(paused["pauseRequested"] == .bool(true), "pause reached actor while worker blocked")
        release.signal()
        var final = JSON.null
        for _ in 0..<500 {
            final = try await activities.call("storage_status")
            if final["job"]?["running"] == .bool(false) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try MCPScenarios.check(final["job"]?["running"] == .bool(false) && final["job"]?["error"] != .null && final["pending"] != .null, "cooperative pause retains pending transaction")
        manager.fault = nil
        _ = try await activities.call("storage_retry")
        _ = try await MCPScenarios.waitForStorage(activities)
        await activities.shutdown()
        // Retry accepts the same cancellation object all the way into copying.
        let cancelled = StorageMoveCancellation(); cancelled.cancel()
        do { _ = try manager.retry(cancellation: cancelled); throw MCPFailure("test_failed", "cancelled retry accepted") }
        catch let e as MCPFailure where e.code == "test_failed" { throw e }
        catch { }
    }
    static func destructiveOwnedDelete(root: URL) async throws {
        let source = root.appendingPathComponent("destroy-only-owned")
        try Store.privateDirectory(source)
        try Data("explicitly disposable".utf8).write(to: source.appendingPathComponent("payload"))
        let a = Activities(bootstrap: root.appendingPathComponent("destroy-store"))
        let f = try await a.call("folder_create", arguments: ["path": .string(source.path), "capacityBytes": .integer(32 << 20)])
        guard case .string(let id) = f["id"] else { throw MCPFailure("test_failed", "delete fixture ID") }
        _ = try await a.call("folder_delete", arguments: ["id": .string(id), "destroy": .bool(true), "confirmation": .string("DELETE " + id)])
        try MCPScenarios.check(!FileManager.default.fileExists(atPath: source.path), "exact destructive confirmation removes only owned source")
        await a.shutdown()
    }
    /// Real disk-only legacy publication records. No filesystem is mounted and
    /// no native/helper operation is mocked or invoked.
    static func review(root: URL) async throws {
        let base = root.appendingPathComponent("review"), source = base.appendingPathComponent("source")
        try Store.privateDirectory(base); try Store.privateDirectory(source)
        try Data("reviewed original".utf8).write(to: source.appendingPathComponent("payload"))
        let store = try Store(root: base.appendingPathComponent("store"))
        let identity = try DirectoryHandle.open(source).identity()
        let folder = Folder(name: "review fixture", path: source.path, capacity: 32 << 20, device: identity.device, inode: identity.inode)
        var config = Configuration(); config.folders = [folder]; try store.save(config)
        let mounts = base.appendingPathComponent("RAMNest-Mounts-\(getuid())")
        try Store.privateDirectory(mounts)
        store.linkedFixtureRoot = mounts
        var boundary = EngineSession(); boundary.linkedMountRoot = mounts
        let e = Engine(store: store, session: boundary), session = UUID()
        let rootHandle = try DirectoryHandle.open(mounts), slot = try rootHandle.createDirectory("source")
        var layout = LinkedFolderLayout(folderID: folder.id, session: session, stage: .reserved,
            originalPath: source.path, mountRoot: mounts.path, mountPath: mounts.appendingPathComponent("source").path,
            holdingPath: base.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(session.uuidString).original").path,
            linkStagePath: base.appendingPathComponent(".ramnest-\(folder.id.uuidString)-\(session.uuidString).link").path,
            parent: try .init(DirectoryHandle.open(base).identity()), root: try .init(rootHandle.identity()),
            mountpoint: try .init(slot.identity()), source: .init(identity))
        layout.version = 1; try layout.validate()
        let manifest = try Snapshot.manifest(source)
        let revision = try Snapshot.capture(store: store, folder: folder, source: source, previous: nil)
        var j = Journal(); j.phase = .preparing; j.backend = .fskit; j.session = session
        j.legacyLink = layout; j.initialRevision = revision; j.revision = revision; j.initialSourceManifest = manifest
        try store.write(j, for: folder.id)
        let (data, expected) = try Snapshot.verified(store: store, id: folder.id, revision: revision)
        let staging = base.appendingPathComponent("population")
        var copied = try Snapshot.copyTree(from: data, to: staging, manifest: expected, publicationStaging: true, sourceContext: .managedRevision)
        let from = try DirectoryHandle.open(staging)
        for name in try from.names() { try from.renameNoReplace(name, to: slot, as: name) }
        copied.publicRoot = try Snapshot.preparePublicRoot(from: from, to: slot, selected: URL(fileURLWithPath: layout.mountPath), manifest: copied)
        if let mode = copied.publicRoot?.mode { guard fchmod(slot.fd, mode_t(mode)) == 0 else { throw NestError("owned fixture mode") }; try slot.sync() }
        _ = try e.evacuateOriginal(folder, journal: &j, expected: manifest)
        let original = j.managedLink!.originalDataURL
        try e.verifyAndPublishPopulation(folder, journal: &j, expected: copied, source: DirectoryHandle.open(original), original: original)
        for name in try slot.names() { try FileManager.default.removeItem(at: URL(fileURLWithPath: layout.mountPath).appendingPathComponent(name)) }
        boundary.publicationCheckpoint = { if $0 == "renamed" { throw NestError("owned publication pause") } }
        do { try Engine(store: store, session: boundary).recover(folder.id.uuidString); throw MCPFailure("test_failed", "fixture did not pause") }
        catch let failure as MCPFailure where failure.code == "test_failed" { throw failure }
        catch { }
        j = try store.journal(folder.id)
        guard var receipt = j.publicationRename else { throw MCPFailure("test_failed", "fixture publication receipt missing") }
        receipt.version = 1; receipt.publicationSwap = nil; j.publicationRename = receipt
        try store.write(j, for: folder.id)
        let manager = SnapshotStorageManager(location: StoreLocation(bootstrapRoot: store.root))
        let a = Activities(manager: manager, engine: Engine(store: store, session: EngineSession(linkedMountRoot: mounts)))
        let b = Activities(manager: manager, engine: Engine(store: store, session: EngineSession(linkedMountRoot: mounts)))
        let ref: [String: JSON] = ["id": .string(folder.id.uuidString)]
        let exported = base.appendingPathComponent("exported-checkpoint")
        _ = try await a.call("folder_export", arguments: ref.merging(["destination": .string(exported.path)]) { _, value in value })
        try MCPScenarios.check(try Data(contentsOf: exported.appendingPathComponent("payload")) == Data("reviewed original".utf8), "export actual verified disk checkpoint")
        let raw = try Data(contentsOf: store.root.appendingPathComponent("volumes/\(folder.id.uuidString)/journal.json"))
        let first = try await a.call("recovery_review", arguments: ref)
        guard case .string(let token) = first["token"] else { throw MCPFailure("test_failed", "review token missing") }
        var confirm: [String: JSON] = ["token": .string(token), "acceptsMissingHistoricRecord": .bool(true), "confirmation": .string("ACCEPT MISSING HISTORIC RECORD")]
        try await MCPScenarios.expectFailure({ try await b.call("recovery_confirm", arguments: confirm) }, "cross-session token")
        try MCPScenarios.check(try Data(contentsOf: store.root.appendingPathComponent("volumes/\(folder.id.uuidString)/journal.json")) == raw, "review/cross-session rejection is read only")
        _ = try await a.call("recovery_cancel", arguments: ["token": .string(token)])
        try await MCPScenarios.expectFailure({ try await a.call("recovery_confirm", arguments: confirm) }, "cancelled token")
        let second = try await a.call("recovery_review", arguments: ref)
        confirm["token"] = second["token"]
        _ = try await a.call("recovery_confirm", arguments: confirm)
        try await MCPScenarios.expectFailure({ try await a.call("recovery_confirm", arguments: confirm) }, "consumed token")
        try MCPScenarios.check(try store.journal(folder.id).phase == .idle, "review completes actual owned legacy publication")
        try MCPScenarios.check(FileManager.default.fileExists(atPath: first["retainedOriginalPath"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? ""), "review retains originals")
        await a.shutdown(); await b.shutdown()
    }
}
