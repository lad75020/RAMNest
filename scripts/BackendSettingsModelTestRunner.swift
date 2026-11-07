import Foundation
import SwiftUI
@testable import RAMNestCore

@main struct BackendSettingsModelTests {
    @MainActor static func wait(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NestError("TEST: backend save did not finish")
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/backend-selector/model-fixtures/\(UUID().uuidString)")
        let store = try Store(root: root)
        var config = Configuration(); config.backend = .fskit; config.menuBarMode = true
        try store.save(config)
        let model = AppModel(repository: store)
        precondition(model.backend == .fskit && model.menuBarMode, "owning model must load persisted app backend")
        for backend in Configuration.Backend.allCases {
            model.setBackend(backend)
            try await wait(model)
            precondition(model.backend == backend && model.backendError == nil)
            let saved = try store.load(); precondition(saved.backend == backend && saved.menuBarMode)
        }
        // Atomic save fails while readback of the previous confirmed value succeeds.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        model.setBackend(.nfs)
        try await wait(model)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        precondition(model.backend == .smb && model.backendError != nil && !model.busy, "failed save must show error and read back confirmed preference")
        model.setBackend(.nfs); try await wait(model)
        precondition(model.backend == .nfs && model.backendError == nil, "successful retry clears Settings error")
        config.backend = .smb; try store.save(config)
        await model.refresh()
        precondition(model.backend == .smb, "model refresh must read external preference changes")
        let folder = Folder(name: "fixture", path: root.path, capacity: 16<<20, device: 1, inode: 1)
        var journal = Journal(); journal.phase = .mounted; journal.backend = .fskit
        func status(_ journal: Journal, mounted: Bool) -> FolderStatus {
            FolderStatus(folder: folder, journal: journal, connected: mounted, mounted: mounted, used: 0, contentBytes: 0, payloadBytes: 0, mappedBytes: 0, backingSavingsFraction: 0)
        }
        precondition(model.backendCaption(for: status(journal, mounted: true)) == "Mounted with FUSE-T FSKit")
        journal.backend = nil
        precondition(model.backendCaption(for: status(journal, mounted: true)) == "Mounted with FUSE-T · backend not recorded", "legacy live journal must not inherit next preference")
        journal.phase = .recoveryRequired
        precondition(model.backendCaption(for: status(journal, mounted: false)) == "Session backend not recorded")
        journal.phase = .idle
        precondition(model.backendCaption(for: status(journal, mounted: false)) == "Next mount: FUSE-T SMB3")
        print("PASS Settings model: persisted bootstrap, three saves/readback, failed atomic save/readback/error/retry, refresh, recorded/legacy/next captions")
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL Settings model: \(error)\n".utf8)); exit(1) }
    }
}
