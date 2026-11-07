import Foundation
import SwiftUI
import RAMNestCore

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
        } catch {
            FileHandle.standardError.write(Data("FAIL GUI model lifecycle: \(error)\n".utf8)); exit(1)
        }
    }
}
