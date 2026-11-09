import PackagePlugin
import Foundation

@main struct NativeAuthorityPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        [.prebuildCommand(displayName: "Build signed native helper and compile its exact authority",
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [context.package.directoryURL.appending(path: "scripts/swiftpm-native-authority.sh").path,
                        context.pluginWorkDirectoryURL.path],
            outputFilesDirectory: context.pluginWorkDirectoryURL.appending(path: "generated"))]
    }
}
