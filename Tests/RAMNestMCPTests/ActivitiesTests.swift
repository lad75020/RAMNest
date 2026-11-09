import Testing
@testable import RAMNestMCPKit

@Suite struct ActivitiesTests {
    @Test func ownedSchemaAndHandlerScenarios() async throws { try await MCPScenarios.run() }
}
