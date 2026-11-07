import Foundation
@main struct Runner {
    static func main() {
        do { try Scenarios.run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
