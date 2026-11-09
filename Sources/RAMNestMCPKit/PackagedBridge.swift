import Foundation
import Security
import Darwin
import RAMNestCore

/// Only these two fixed executables in one selected, sealed RAMNest.app may be
/// launched. No RPC accepts an executable, command, environment or shell text.
public struct PackagedBridge: Sendable {
    public let app: URL?
    public init(app: URL? = nil) {
        if let app { self.app = app.standardizedFileURL }
        else {
            let candidate = BinaryLocation.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            self.app = candidate.pathExtension == "app" ? candidate : nil
        }
    }
    public func requirePackage() throws -> URL {
        guard let app, app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == "sh.ramnest.app" else {
            throw MCPFailure("unavailable", "Select a sealed RAMNest.app with --app /absolute/RAMNest.app, or run the packaged Contents/Helpers/ramnest-mcp. Native controls and app login settings require this package.")
        }
        try Paths.rejectSymlinks(app.path)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw MCPFailure("unavailable", "RAMNest.app signature or sealed resources are invalid. Rebuild a coherent package.")
        }
        let marker = app.appendingPathComponent("Contents/Resources/mcp-bridge.json")
        try Paths.rejectSymlinks(marker.path)
        guard (try? Data(contentsOf: marker)) == Data("{\"protocol\":1}\n".utf8) else {
            throw MCPFailure("unavailable", "This app predates the MCP bridge. Rebuild/package it before making requests; its GUI was not launched.")
        }
        for path in ["Contents/Helpers/ramnest", "Contents/Helpers/ramnest-helper", "Contents/MacOS/RAMNest"] {
            let url = app.appendingPathComponent(path)
            try Paths.rejectSymlinks(url.path)
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o022 == 0,
                  st.st_uid == getuid() || st.st_uid == 0 else { throw MCPFailure("unavailable", "Unsafe or missing packaged executable: \(path).") }
        }
        return app
    }
    func cli(_ arguments: [String], root: URL, timeout: TimeInterval = 600) throws -> JSON {
        let app = try requirePackage()
        return try Self.run(app.appendingPathComponent("Contents/Helpers/ramnest"), ["--store", root.path] + arguments + ["--json"], timeout: timeout)
    }
    func identity() throws -> JSON {
        let app = try requirePackage()
        return try Self.run(app.appendingPathComponent("Contents/Helpers/ramnest"), ["native-build-identity", "--json"], timeout: 20)
    }
    func login(enabled: Bool? = nil) throws -> JSON {
        let app = try requirePackage()
        let value = try Self.run(app.appendingPathComponent("Contents/MacOS/RAMNest"), ["--mcp-login-item", enabled.map { $0 ? "enable" : "disable" } ?? "get"], timeout: 30)
        guard value["scope"] == .string("sh.ramnest.app"), case .string(let status) = value["status"],
              ["enabled", "notRegistered", "requiresApproval", "notFound", "unknown"].contains(status) else {
            throw MCPFailure("unavailable", "The selected app lacks the bounded login-item bridge. Repackage RAMNest.")
        }
        if let enabled, (enabled && !["enabled", "requiresApproval"].contains(status)) || (!enabled && status != "notRegistered") {
            throw MCPFailure("login_readback", "Requested login preference did not take effect; actual status: \(status).")
        }
        return value
    }
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> JSON {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("ramnest-mcp-process-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let out = temp.appendingPathComponent("stdout"), err = temp.appendingPathComponent("stderr")
        guard fm.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw MCPFailure("io", "Cannot allocate private process output.") }
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(), done = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": fm.homeDirectoryForCurrentUser.path, "LANG": "en_US.UTF-8"]
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw MCPFailure("operation_timeout", "Packaged operation exceeded its bound. Inspect folder status/journal before retrying; no success is inferred.")
        }
        process.waitUntilExit()
        func bounded(_ url: URL) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let bytes = try handle.read(upToCount: (8 << 20) + 1) ?? Data()
            guard bytes.count <= 8 << 20 else { throw MCPFailure("output_bound", "Packaged operation output exceeded 8 MiB.") }; return bytes
        }
        guard process.terminationStatus == 0 else {
            throw MCPFailure("core_\(process.terminationStatus)", String(decoding: try bounded(err), as: UTF8.self))
        }
        let bytes = try bounded(out)
        guard !bytes.isEmpty else { throw MCPFailure("invalid_bridge_response", "Packaged operation returned no JSON receipt.") }
        return try JSONDecoder().decode(JSON.self, from: bytes)
    }
}
