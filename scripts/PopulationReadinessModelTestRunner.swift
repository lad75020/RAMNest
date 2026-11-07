import Foundation
import SwiftUI
@testable import RAMNestCore

@main struct PopulationReadinessModelTestRunner {
    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("artifacts/trash-fix/model-fixtures-\(UUID().uuidString)")
            let store = try Store(root: root)
            let model = AppModel(repository: store)
            let folder = Folder(name: "inert guarded fixture", path: root.path, capacity: 16 << 20, device: 1, inode: 1)
            var journal = Journal(); journal.phase = .recoveryRequired
            let guarded = FolderStatus(folder: folder, journal: journal, connected: true, mounted: true,
                used: 0, contentBytes: 0, payloadBytes: 0, mappedBytes: 0, backingSavingsFraction: 0, helperActive: false)
            model.statuses = [guarded]; model.selected = folder.id; model.draft = folder
            model.save()
            try await Task.sleep(for: .milliseconds(100))
            guard model.error == nil && !model.busy && model.progress.isEmpty else {
                throw NestError("TEST: guarded Save must return before starting an engine write action")
            }
            // These guards must return without dialogs, tasks, or helper calls.
            model.resize()
            var orphan = guarded; orphan.connected = false; orphan.journal.phase = .idle
            model.mountOrEject(orphan)
            try await Task.sleep(for: .milliseconds(100))
            guard model.error == nil && !model.busy else { throw NestError("TEST: guarded Resize/orphan Mount must stay disabled") }
            print("PASS: model rejects guarded Save/Resize and Mount over an orphan volume before dialogs or engine writes")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}
