import Foundation
@main struct SettingsResetTestRunner {
    static func main() {
        do { try SettingsResetScenarios.run(cli: CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil) }
        catch { FileHandle.standardError.write(Data("FAIL RESET: \(error)\n".utf8)); exit(1) }
    }
}
