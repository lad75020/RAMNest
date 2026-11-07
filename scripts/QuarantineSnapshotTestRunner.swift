import Foundation
import Darwin
@testable import RAMNestCore

@main enum QuarantineSnapshotTestRunner {
    static func main() {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--interrupt-root-restore" {
            do {
                let store = try Store(root: URL(fileURLWithPath: CommandLine.arguments[2]))
                store.beforeJournalWrite = { value, _ in
                    if value.phase == .restoring && value.restoredEntries.count == 1 {
                        _exit(87) // Durable first rename, no journal ACK or defer cleanup.
                    }
                }
                let session = EngineSession(status: { _, _ in throw NestError("owned fixture has no helper") })
                try Engine(store: store, session: session).recover(CommandLine.arguments[3])
            } catch { FileHandle.standardError.write(Data("FAIL crash fixture: \(error)\n".utf8)) }
            exit(88)
        }
        do { try QuarantineSnapshotScenarios.run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
