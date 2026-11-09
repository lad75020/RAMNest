import Foundation
@main struct MCPDomainTestRunner {
    static func main() async {
        do {
            try await MCPScenarios.run()
            FileHandle.standardError.write(Data("PASS owned MCP schema/handler/store scenarios\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("FAIL MCP scenarios: \(error)\n".utf8)); exit(1)
        }
    }
}
