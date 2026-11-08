import Foundation
import SwiftUI
@testable import RAMNestCore

@main struct FileVerificationModelTests {
    @MainActor static func wait(_ model: AppModel) async throws {
        for _ in 0..<300 { if !model.busy { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NestError("TEST: Settings save timed out")
    }
    @MainActor static func run() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--read-preference" {
            let model = AppModel(repository: try Store(root: URL(fileURLWithPath: CommandLine.arguments[2])))
            precondition(model.fileVerification.rawValue == CommandLine.arguments[3]); print("PASS cold process Settings bootstrap"); return
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("artifacts/verification-mode-run/model-fixtures/\(UUID().uuidString)")
        let store = try Store(root: root), model = AppModel(repository: store)
        precondition(model.fileVerification == .sha256)
        for policy in FileVerification.allCases {
            model.setFileVerification(policy); try await wait(model)
            precondition(model.fileVerification == policy && model.fileVerificationError == nil)
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--read-preference", root.path, policy.rawValue]; try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 0)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        model.setFileVerification(.sha256); try await wait(model)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        precondition(model.fileVerification == .sizeAndModTime && model.fileVerificationError != nil)
        model.setFileVerification(.sha256); try await wait(model)
        precondition(model.fileVerification == .sha256 && model.fileVerificationError == nil)
        _ = try Engine(store: store).setFileVerification(.sizeAndModTime); await model.refresh()
        precondition(model.fileVerification == .sizeAndModTime)
        print("PASS Settings: default, both saves/readback, cold process bootstrap, failed atomic save/readback/retry, refresh")
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL verification Settings: \(error)\n".utf8)); exit(1) }
    }
}
