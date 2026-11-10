import Foundation
import Testing
@testable import RAMNestMCPKit

@Suite struct ActivitiesTests {
    @Test func ownedSchemaAndHandlerScenarios() async throws { try await MCPScenarios.run() }

    @Test func handlerTableMatchesCatalog() {
        let names = ToolCatalog.tools.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Activities.handlerNames == Set(names))
    }

    @Test func validationStillPrecedesClosingAndDispatch() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ramnest-dispatch-" + UUID().uuidString)
        let activities = Activities(bootstrap: root)
        await activities.shutdown()
        for tool in ToolCatalog.tools {
            let valid = tool.fields.filter { tool.required.contains($0.key) }.mapValues { MCPScenarios.sample($0) }
            for (arguments, expected) in [(valid.merging(["unexpected": .bool(true)]) { _, v in v }, "invalid_arguments"), (valid, "closing")] {
                do {
                    _ = try await activities.call(tool.name, arguments: arguments)
                    Issue.record("Accepted closed/invalid call to \(tool.name)")
                } catch let error as MCPFailure { #expect(error.code == expected) }
            }
        }
        do {
            _ = try await activities.call("unknown-tool")
            Issue.record("Accepted unknown tool")
        } catch let error as MCPFailure { #expect(error.code == "unknown_tool") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func handlerTableDoesNotRetainActor() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ramnest-handler-lifetime-" + UUID().uuidString)
        var activities: Activities? = Activities(bootstrap: root)
        weak var released = activities
        _ = try await activities!.call("capabilities")
        await activities!.shutdown()
        activities = nil
        #expect(released == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
