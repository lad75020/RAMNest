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
            try await settingsResetModel()
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
    @MainActor static func settingsResetModel() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("artifacts/settings-reset/model-\(UUID().uuidString)")
        try Store.privateDirectory(root)
        let original = root.appendingPathComponent("original"); try Store.privateDirectory(original)
        try Data("model original".utf8).write(to: original.appendingPathComponent("payload"))
        let store = try Store(root: root.appendingPathComponent("store"))
        var options = FolderOptions(); options.mountAtLaunch = false
        let folder = try Engine(store: store).create(path: original, name: "Reset model fixture", capacity: 16 << 20, options: options)
        _ = try Snapshot.capture(store: store, folder: folder, source: original, previous: nil)
        let model = AppModel(repository: store)
        await model.refresh()
        model.resetConfirmation = { false }; model.confirmReset()
        precondition(!model.busy && !model.resetCommitted)
        let saved = model.statuses
        let gate = SnapshotStorageRefreshGate()
        model.refreshRead = { _ in await gate.wait(); return (saved, .nfs) }
        let oldRefresh = Task { @MainActor in await model.refresh() }
        for _ in 0..<1000 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        var relaunches = 0, terminations = 0
        model.resetConfirmation = { true }
        model.resetRelaunch = { relaunches += 1; throw NestError("Injected relaunch failure") }
        model.resetTerminate = { terminations += 1 }
        model.confirmReset(); model.confirmReset()
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.busy && model.statuses.map(\.id) == [folder.id], "in-flight refresh drains before cleanup/state clear")
        await gate.release(); await oldRefresh.value
        for _ in 0..<1000 { if !model.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
        precondition(model.resetCommitted && model.resetError == "Injected relaunch failure")
        precondition(model.statuses.isEmpty && model.selected == nil && model.draft == nil)
        precondition(model.backend == .tmpfs, "stale refresh cannot repopulate reset state")
        precondition(relaunches == 1 && terminations == 0 && model.refreshTask == nil)
        let empty = try store.load(); precondition(empty.folders.isEmpty)
        // A restart retry must not run cleanup again, even if new data appeared.
        let sentinel = store.root.appendingPathComponent("restart-retry-sentinel")
        try Data("keep".utf8).write(to: sentinel)
        model.resetRelaunch = { relaunches += 1 }
        model.confirmReset()
        for _ in 0..<1000 { if !model.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
        precondition(model.resetError == nil && relaunches == 2 && terminations == 1 && model.resetTerminationAllowed)
        let kept = try String(contentsOf: sentinel, encoding: .utf8); precondition(kept == "keep")
        let allowQuit = await model.quit(); precondition(allowQuit)
        precondition(AppRelaunch.arguments(["RAMNest", "--store", "/chosen path/$literal", "-psn_123", "--some-launch-flag"]) == ["--store", "/chosen path/$literal", "--some-launch-flag"])
        print("PASS RESET model: Cancel, duplicate admission, draining stale refresh, durable-only state clear, relaunch failure and restart-only retry, launch arguments")

        let bad = try Store(root: root.appendingPathComponent("failed-store"))
        _ = try Engine(store: bad).create(path: original, name: "Failure fixture", capacity: 16 << 20, options: options)
        let failed = AppModel(repository: bad); await failed.refresh()
        let before = failed.statuses.map(\.id), selected = failed.selected
        try Data("unknown".utf8).write(to: bad.root.appendingPathComponent("unknown"))
        failed.resetConfirmation = { true }
        failed.resetRelaunch = { preconditionFailure("cleanup failure must never relaunch") }
        failed.resetTerminate = { preconditionFailure("cleanup failure must never terminate") }
        failed.confirmReset()
        for _ in 0..<1000 { if !failed.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
        precondition(!failed.resetCommitted && failed.resetError != nil && failed.statuses.map(\.id) == before && failed.selected == selected)
        failed.refreshTask?.cancel()
        print("PASS RESET model cleanup failure preserves GUI state and displays Settings error")

        // Core scenarios round-trip this marker through real native journals;
        // the injected read exercises startup policy without a live mount.
        let interruptedUnmount = AppModel(repository: bad)
        var admitted = failed.statuses[0]
        admitted.journal.resetUnmountSession = UUID()
        let admittedStatus = admitted
        interruptedUnmount.refreshRead = { _ in ([admittedStatus], .tmpfs) }
        interruptedUnmount.start()
        for _ in 0..<1000 { if interruptedUnmount.resetError != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        precondition(interruptedUnmount.resetError?.contains("Automatic mounting remains paused") == true)
        precondition(!interruptedUnmount.resetCommitted && interruptedUnmount.canReset)
        interruptedUnmount.refreshTask?.cancel()
        print("PASS RESET model startup pauses automatic mounting for pre-receipt unmount provenance")

        let pendingStore = try Store(root: root.appendingPathComponent("pending-store"))
        let pendingFolder = try Engine(store: pendingStore).create(path: original, name: "Interrupted cleanup", capacity: 16 << 20, options: options)
        _ = try Snapshot.capture(store: pendingStore, folder: pendingFolder, source: original, previous: nil)
        var interruption = EngineSession(), unlinks = 0
        interruption.resetCheckpoint = { step in
            if step == "unlink" { unlinks += 1; if unlinks == 2 { throw NestError("Injected model cleanup interruption") } }
        }
        do {
            try Engine(store: pendingStore, session: interruption).reset()
            throw NestError("TEST: model fixture cleanup must be interrupted")
        } catch let failure as NestError {
            guard failure.message == "Injected model cleanup interruption" else { throw failure }
        }
        precondition(unlinks == 2 && pendingStore.resetPending)
        let pending = AppModel(repository: try Store(root: pendingStore.root))
        pending.start()
        precondition(pending.engine != nil && pending.refreshTask == nil && pending.resetError != nil && pending.canReset)
        pending.resetRelaunch = { preconditionFailure("ordinary Quit must not relaunch") }
        pending.resetTerminate = { preconditionFailure("ordinary Quit returns its decision to the app delegate") }
        let receiptBytes = try Data(contentsOf: pendingStore.root.appendingPathComponent(RepositoryReset.receiptName))
        let configBytes = try Data(contentsOf: pendingStore.root.appendingPathComponent("configuration.json"))
        let volumesPath = pendingStore.root.appendingPathComponent("volumes").path
        let remaining = FileManager.default.enumerator(atPath: volumesPath)!.allObjects as! [String]
        pending.busy = true
        let busyQuit = await pending.quit(); precondition(!busyQuit)
        pending.busy = false
        let pendingQuit = await pending.quit()
        guard pendingQuit && !pending.resetCommitted && pending.refreshTask == nil else {
            throw NestError("TEST: reopened interrupted RESET must permit ordinary Quit before Retry; \(pending.error ?? "no error")")
        }
        let retainedReceipt = try Data(contentsOf: pendingStore.root.appendingPathComponent(RepositoryReset.receiptName))
        precondition(retainedReceipt == receiptBytes, "Quit retains the durable receipt")
        let remainingAfterQuit = FileManager.default.enumerator(atPath: volumesPath)!.allObjects as! [String]
        let retainedConfig = try Data(contentsOf: pendingStore.root.appendingPathComponent("configuration.json"))
        precondition(Set(remainingAfterQuit) == Set(remaining) && retainedConfig == configBytes, "Quit performs no pending deletion or configuration commit")
        try Store.atomicData(Data("{ malformed receipt".utf8), pendingStore.root.appendingPathComponent(RepositoryReset.receiptName))
        let malformedQuit = await pending.quit(); precondition(!malformedQuit, "fail-closed pending inspection alone never authorizes Quit")
        try Store.atomicData(receiptBytes, pendingStore.root.appendingPathComponent(RepositoryReset.receiptName))
        print("PASS RESET model reopened partial cleanup permits Quit without deletion/relaunch; busy and malformed receipt refuse")
        pending.resetConfirmation = { true }; pending.resetRelaunch = {}; pending.resetTerminate = {}
        pending.confirmReset()
        for _ in 0..<1000 { if !pending.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
        precondition(pending.resetCommitted && pending.resetError == nil)
        print("PASS RESET model interrupted cleanup reopens in Settings with startup paused and Retry enabled")
    }

}

actor SnapshotStorageRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
