import Foundation
import Darwin

@main enum HoldingCleanupTestRunner {
    static func main() {
        do { try HoldingCleanupScenarios.run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
