// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RAMNest", platforms: [.macOS("27.0")], products: [
    .library(name: "RAMNestCore", targets: ["RAMNestCore"]),
    .executable(name: "ramnest", targets: ["RAMNestCLI"]),
    .executable(name: "RAMNest", targets: ["RAMNestApp"])
], targets: [
    .target(name: "RAMNestCore"),
    .executableTarget(name: "RAMNestCLI", dependencies: ["RAMNestCore"]),
    .executableTarget(name: "RAMNestApp", dependencies: ["RAMNestCore"]),
    .testTarget(name: "RAMNestCoreTests", dependencies: ["RAMNestCore"])
], swiftLanguageModes: [.v6])
