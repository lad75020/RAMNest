import Foundation
import ServiceManagement
import RAMNestCore
import Darwin

/// Runs login-item requests in the APP executable before creating SwiftUI or
/// AppModel. In particular this path cannot start mount-at-launch or quit/eject.
@main struct RAMNestEntry {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--mcp-login-item" else { RAMNestApp.main(); return }
        do {
            guard Bundle.main.bundleIdentifier == "sh.ramnest.app", Bundle.main.bundleURL.pathExtension == "app",
                  args.count == 2, ["get", "enable", "disable"].contains(args[1]) else {
                throw NestError("Invalid app-owned login-item request.", code: 64)
            }
            switch args[1] {
            case "enable": try SMAppService.mainApp.register()
            case "disable": try SMAppService.mainApp.unregister()
            default: break
            }
            let status = SMAppService.mainApp.status
            let name: String
            switch status {
            case .enabled: name = "enabled"
            case .notRegistered: name = "notRegistered"
            case .requiresApproval: name = "requiresApproval"
            case .notFound: name = "notFound"
            @unknown default: name = "unknown"
            }
            let bytes = try JSONEncoder().encode(["status": name, "scope": "sh.ramnest.app"])
            FileHandle.standardOutput.write(bytes + Data([10]))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
