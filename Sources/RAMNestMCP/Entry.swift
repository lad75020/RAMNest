import Foundation
import Darwin
import MCP
import Logging
import ServiceLifecycle
import RAMNestCore
import RAMNestMCPKit

@main struct RAMNestMCP {
    static func main() async {
        LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
        var logger = Logger(label: "sh.ramnest.mcp")
        logger.logLevel = .notice
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            var bootstrap = Store.defaultRoot
            var app: URL?
            var seen = Set<String>()
            while !args.isEmpty {
                let flag = args.removeFirst()
                guard ["--store", "--app"].contains(flag), seen.insert(flag).inserted, !args.isEmpty else {
                    throw MCPFailure("usage", "Usage: ramnest-mcp [--store ABSOLUTE_BOOTSTRAP] [--app ABSOLUTE_RAMNest.app]. Standard input/output are MCP JSON-RPC only.")
                }
                let path = args.removeFirst()
                guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0), URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw MCPFailure("usage", "Paths must be absolute and canonical.") }
                if flag == "--store" { bootstrap = URL(fileURLWithPath: path) } else { app = URL(fileURLWithPath: path) }
            }
            let activities = Activities(bootstrap: bootstrap, app: app)
            let server = Server(name: "RAMNest", version: "1.0.0", instructions: "Local macOS RAMNest controls. No automatic startup mounts or exit eject. Use capabilities before native operations; review data-loss disclosures and obtain explicit destructive consent.",
                capabilities: .init(prompts: .init(), resources: .init(), tools: .init()), configuration: .strict)
            let service = MCPService(server: server, activities: activities, logger: logger)
            let group = ServiceGroup(configuration: .init(services: [
                .init(service: service, successTerminationBehavior: .gracefullyShutdownGroup)
            ], gracefulShutdownSignals: [.sigterm, .sigint], logger: logger))
            try await group.run()
        } catch {
            logger.error("RAMNest MCP stopped: \(error.localizedDescription)")
            exit(1)
        }
    }
}
