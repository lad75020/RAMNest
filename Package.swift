// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RAMNest", platforms: [.macOS("27.0")], products: [
    .library(name: "RAMNestCore", targets: ["RAMNestCore"]),
    .executable(name: "ramnest", targets: ["RAMNestCLI"]),
    .executable(name: "RAMNest", targets: ["RAMNestApp"]),
    .executable(name: "ramnest-mcp", targets: ["RAMNestMCP"])
], dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.17.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.13.0")
], targets: [
    .target(name: "RAMNestCore", plugins: ["NativeAuthorityPlugin"]),
    .plugin(name: "NativeAuthorityPlugin", capability: .buildTool()),
    .executableTarget(name: "RAMNestCLI", dependencies: ["RAMNestCore"]),
    .executableTarget(name: "RAMNestApp", dependencies: ["RAMNestCore"]),
    .target(name: "RAMNestMCPKit", dependencies: ["RAMNestCore"]),
    .executableTarget(name: "RAMNestMCP", dependencies: ["RAMNestMCPKit",
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle")]),
    .testTarget(name: "RAMNestCoreTests", dependencies: ["RAMNestCore"]),
    .testTarget(name: "RAMNestMCPTests", dependencies: ["RAMNestMCPKit", "RAMNestCore"])
], swiftLanguageModes: [.v6])
