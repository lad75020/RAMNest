import Foundation
import SwiftUI
@testable import RAMNestCore

/// Headless lifecycle regression: no NSApplication/run loop, windows, mounts or
/// activation-policy changes are needed to initialize/update the shared model.
@main struct AppModelTestRunner {
    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("artifacts/gui-model-tests-\(UUID().uuidString)")
            let store = try Store(root: root)
            let model = AppModel(repository: store)
            precondition(model.engine?.store.root == root)
            precondition(model.refreshTask == nil)
            // Exercise the opaque command-body metadata that was at the top of
            // the host crash, independently of a running GUI scene graph.
            let commands = RAMNestCommands(model: model)
            let description = String(reflecting: type(of: commands.body))
            precondition(!description.isEmpty)
            model.start()
            let first = model.refreshTask
            precondition(first != nil)
            model.start()
            precondition(model.refreshTask == first, "launch must be idempotent across window reopen")
            // Allow the real empty repository refresh to finish. It must not
            // require an application, add a scene, or trigger a mount.
            try await Task.sleep(for: .milliseconds(200))
            precondition(model.error == nil, model.error ?? "")
            precondition(model.statuses.isEmpty)
            model.setMenuMode(true)
            for _ in 0..<100 {
                if model.menuBarMode && !model.busy { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(model.menuBarMode)
            let persistedMenu = try store.locked { try store.load().menuBarMode }; precondition(persistedMenu)
            model.setMenuMode(false)
            for _ in 0..<100 {
                if !model.menuBarMode && !model.busy { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(!model.menuBarMode)
            let persistedDock = try store.locked { try !store.load().menuBarMode }; precondition(persistedDock)
            precondition(model.refreshTask == first)
            model.refreshTask?.cancel()
            print("PASS GUI model lifecycle: stable shared model, idempotent launch, command-body metadata, headless refresh, persisted Dock/menu choice without application/scene mutation")
            try await snapshotStorageModel()
            try await snapshotStorageRetryAdmission()
        } catch {
            FileHandle.standardError.write(Data("FAIL GUI model lifecycle: \(error)\n".utf8)); exit(1)
        }
    }
    @MainActor static func snapshotStorageModel() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/snapshot-storage-location/gui-model-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let manager = SnapshotStorageManager(location: StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap")))
        let store = try manager.open(), parent = root.appendingPathComponent("chosen")
        try Store.privateDirectory(parent)
        let selected = root.appendingPathComponent("selected"); try Store.privateDirectory(selected)
        var options = FolderOptions(); options.mountAtLaunch = false
        let folder = try Engine(store: store).create(path: selected, name: "GUI location fixture", capacity: 16 << 20, options: options)
        var config = try store.load(); config.backend = .fskit; try store.save(config)
        var pickerCalls = 0
        let model = AppModel(repository: store, storageManager: manager, storagePicker: { pickerCalls += 1; return parent })
        await model.refresh()
        precondition(model.canMoveSnapshotStorage)
        model.draft?.options.nobrowse.toggle()
        let edited = model.draft
        precondition(!model.canMoveSnapshotStorage)
        await model.moveSnapshotStorage(toParent: parent)
        precondition(model.draft == edited, "move must never discard edits")
        model.discard()
        let oldStatuses = model.statuses, gate = SnapshotStorageRefreshGate()
        model.refreshRead = { _ in await gate.wait(); return (oldStatuses, .nfs) }
        let lateRefresh = Task { @MainActor in await model.refresh() }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        let entered = await gate.entered; precondition(entered)
        model.refreshRead = nil
        model.chooseSnapshotStorage()
        for _ in 0..<1000 {
            if model.snapshotStoragePath == parent.appendingPathComponent("RAMNest Snapshots").path && !model.busy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await gate.release(); await lateRefresh.value
        precondition(pickerCalls == 1)
        precondition(model.storageError == nil, model.storageError ?? "")
        precondition(model.engine?.store.root.path == parent.appendingPathComponent("RAMNest Snapshots").path)
        precondition(model.statuses.map(\.id) == [folder.id])
        precondition(model.selected == folder.id && model.draft?.id == folder.id)
        precondition(model.backend == .tmpfs, "late old-engine refresh must be discarded")
        precondition(model.canMoveSnapshotStorage)
        print("PASS snapshot storage GUI model: injected picker/manager, dirty draft preservation, actual move/engine swap and stale refresh rejection")
    }
    @MainActor static func snapshotStorageRetryAdmission() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/snapshot-storage-location/retry-model-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let manager = SnapshotStorageManager(location: StoreLocation(bootstrapRoot: root.appendingPathComponent("bootstrap")))
        let store = try manager.open(), parent = root.appendingPathComponent("chosen")
        try Store.privateDirectory(parent)
        manager.fault = { if $0 == "copy" { throw NestError("Pause copy for Retry") } }
        do { _ = try manager.move(store: store, toParent: parent); preconditionFailure("Expected pending move") } catch { }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        manager.fault = { step in
            if step == "copy" {
                entered.signal()
                guard release.wait(timeout: .now() + 10) == .success else { throw NestError("Retry admission gate expired") }
            }
        }
        let model = AppModel(repository: store, storageManager: manager)
        model.retrySnapshotStorage(); model.retrySnapshotStorage()
        var waiting = false
        func didEnter() -> Bool { entered.wait(timeout: .now()) == .success }
        for _ in 0..<1000 {
            if didEnter() { waiting = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        let admittedOnce = waiting && model.busy && model.movingStorage
        release.signal()
        for _ in 0..<1000 {
            if !model.busy { break }; try await Task.sleep(for: .milliseconds(5))
        }
        precondition(admittedOnce, "Queued Retry must not reset a running storage operation")
        precondition(model.storageError == nil, model.storageError ?? "")
        precondition(model.engine?.store.root.path == parent.appendingPathComponent("RAMNest Snapshots").path)
        print("PASS queued Retry admission: one operation owns busy state and completion")
    }
}

actor SnapshotStorageRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
