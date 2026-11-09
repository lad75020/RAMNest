import Foundation
import MCP
import Logging
import ServiceLifecycle
import RAMNestMCPKit

private final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

func convert<T: Encodable, U: Decodable>(_ value: T, to: U.Type) throws -> U {
    try JSONDecoder().decode(U.self, from: JSONEncoder().encode(value))
}

struct MCPService: Service {
    let server: Server
    let activities: Activities
    let logger: Logger

    func run() async throws {
        let transport = StdioTransport(logger: logger)
        let stopping = StopSignal()
        try await register()
        do {
            try await withTaskCancellationHandler {
                try await withGracefulShutdownHandler {
                    try await server.start(transport: transport)
                    if stopping.isStopped || Task.isCancelled { await server.stop() }
                    await server.waitUntilCompleted()
                } onGracefulShutdown: {
                    stopping.stop()
                    Task { await server.stop() }
                }
            } onCancel: {
                stopping.stop()
                Task { await server.stop() }
            }
            await activities.shutdown()
            await server.stop()
        } catch {
            await activities.shutdown()
            await server.stop()
            throw error
        }
    }

    func register() async throws {
        let tools: [Tool] = try ToolCatalog.tools.map { t in
            Tool(name: t.name, description: t.description, inputSchema: try convert(t.schema, to: Value.self),
                 annotations: .init(readOnlyHint: t.readOnly, destructiveHint: t.destructive, openWorldHint: false))
        }
        await server.withMethodHandler(ListTools.self) { params in
            guard params.cursor == nil else { throw MCPError.invalidParams("No paginated tool cursor exists.") }
            return .init(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let args = try convert(params.arguments ?? [:], to: [String: JSON].self)
                let result = try await activities.call(params.name, arguments: args)
                return .init(content: [.text(text: try result.text(), annotations: nil, _meta: nil)], isError: false)
            } catch {
                let failure = error as? MCPFailure ?? MCPFailure("operation_failed", error.localizedDescription)
                // Tool failures are explicit MCP tool errors; stdout remains JSON-RPC.
                return .init(content: [.text(text: try failure.json.text(), annotations: nil, _meta: nil)], isError: true)
            }
        }
        let resources = ["capabilities", "folders", "settings", "storage"].map {
            Resource(name: "RAMNest " + $0, uri: "ramnest://" + $0, mimeType: "application/json")
        }
        await server.withMethodHandler(ListResources.self) { params in
            guard params.cursor == nil else { throw MCPError.invalidParams("No paginated resource cursor exists.") }
            return .init(resources: resources)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            let tool: String
            switch params.uri {
            case "ramnest://capabilities": tool = "capabilities"
            case "ramnest://folders": tool = "folder_list"
            case "ramnest://settings": tool = "settings_get"
            case "ramnest://storage": tool = "storage_status"
            default: throw MCPError.invalidParams("Unknown RAMNest resource URI.")
            }
            let result = try await activities.call(tool)
            return try convert(JSON.object(["contents": .array([.object([
                "uri": .string(params.uri), "mimeType": .string("application/json"), "text": .string(try result.text())
            ])])]), to: ReadResource.Result.self)
        }
        await server.withMethodHandler(ListPrompts.self) { params in
            guard params.cursor == nil else { throw MCPError.invalidParams("No paginated prompt cursor exists.") }
            return try convert(JSON.object(["prompts": .array([.object([
                "name": .string("ramnest-safety-review"), "description": .string("Review folder state, snapshot authority and explicit action consent before changing data."), "arguments": .array([])
            ])])]), to: ListPrompts.Result.self)
        }
        await server.withMethodHandler(GetPrompt.self) { params in
            guard params.name == "ramnest-safety-review", params.arguments?.isEmpty != false else {
                throw MCPError.invalidParams("Unknown prompt or unexpected prompt arguments.")
            }
            return try convert(JSON.object(["description": .string("RAMNest action review"), "messages": .array([.object([
                "role": .string("user"), "content": .object(["type": .string("text"), "text": .string("Read capabilities and folder_info first. Explain whether the next operation changes RAM, originals, checkpoints or configuration. Close regular files and mappings before saving/ejecting. Temporary-mode eject discards RAM edits. Recovery can restore only committed disk checkpoints or intact originals. Obtain explicit consent before destructive delete or RESET; never invent confirmation text or a recovery review token. A recovery token is valid only after the user reviews the returned evidence in this MCP session. Do not change login settings or mount folders merely because this server started.")])
            ])])]), to: GetPrompt.Result.self)
        }
    }
}
