import Foundation
import Darwin

public struct NativePinStatus: Sendable {
    public let id: UUID
    public let pid: Int32
    public let mounted: Bool
    public let used: UInt64
    public let capacity: UInt64
    public let active: Bool
    static func decode(_ fields: [String], id: UUID) throws -> NativePinStatus {
        guard fields.count == 6, let actual = UUID(uuidString: fields[0]), actual == id,
              let pid = Int32(fields[1]), pid > 1, let used = UInt64(fields[3]),
              let capacity = UInt64(fields[4]), capacity >= 16 << 20, used <= capacity,
              ["mounted", "lost"].contains(fields[2]), ["active", "guarded"].contains(fields[5]),
              fields[2] == "mounted" || (fields[5] == "guarded" && used == 0) else {
            throw NestError("Native pin status identity/state/accounting mismatch.", code: 2)
        }
        return NativePinStatus(id: actual, pid: pid, mounted: fields[2] == "mounted", used: used,
                               capacity: capacity, active: fields[5] == "active")
    }
}
public enum Control {
    public static func request(_ socketPath: String, _ command: String, timeout: Int = 180) throws -> [String] {
        let frameLimit = 8192
        guard timeout > 0, !command.contains("\n"), !command.contains("\0"), command.utf8.count <= frameLimit, socketPath.utf8.count < 104 else { throw NestError("Invalid helper request.", code: 2) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NestError("Cannot open helper connection.", code: 2) }; defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout.size(ofValue: wait)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout.size(ofValue: wait)))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in withUnsafeMutablePointer(to: &address.sun_path) { dst in dst.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, src, 104) } } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw NestError("Helper \(command.prefix { $0 != "\t" }) is unavailable. Recovery data was retained; do not remount over an uncertain session.", code: 2) }
        return try exchange(fd, command, timeout: timeout)
    }
    // Shared connected-socket boundary, also exercised with real AF_UNIX
    // socketpairs when the test sandbox prohibits pathname bind(). Owns no fd.
    static func exchange(_ fd: Int32, _ command: String, timeout: Int) throws -> [String] {
        let frameLimit = 8192
        guard timeout > 0, !command.contains("\n"), !command.contains("\0"), command.utf8.count <= frameLimit else { throw NestError("Invalid helper request.", code: 2) }
        let operation = String(command.prefix { $0 != "\t" })
        func failure(_ detail: String) -> NestError {
            NestError("Helper \(operation) \(detail). Recovery data was retained.", code: 2)
        }
        func timedOut() -> NestError {
            failure("timed out waiting for a reply")
        }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw NestError("Helper peer is not owned by this user.", code: 2) }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw failure("connection setup failed") }
        // Fixed monotonic deadlines survive EINTR, partial frames and trickling bytes.
        func ready(_ event: Int16, until deadline: TimeInterval) throws {
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw timedOut() }
                var descriptor = pollfd(fd: fd, events: event, revents: 0)
                let milliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1000)))
                let count = poll(&descriptor, 1, milliseconds)
                if count < 0 && errno == EINTR { continue }
                if count == 0 { continue }
                guard count > 0 else { throw failure("connection polling failed: \(String(cString: strerror(errno)))") }
                return // read/write reports EOF or the socket error, including HUP.
            }
        }
        let data = Data((command + "\n").utf8)
        let sendDeadline = ProcessInfo.processInfo.systemUptime + Double(timeout)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try ready(Int16(POLLOUT), until: sendDeadline)
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard n > 0 else { throw failure("disconnected while sending the request") }
                offset += n
            }
        }
        var output = Data(); var byte: UInt8 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeout)
        while true {
            try ready(Int16(POLLIN), until: deadline)
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            if count == 0 { throw failure(output.isEmpty ? "disconnected before a final reply" : "returned a truncated reply frame") }
            guard count == 1 else { throw failure("disconnected while receiving the reply: \(String(cString: strerror(errno)))") }
            if byte != 10 {
                guard output.count < frameLimit else { throw failure("reply frame exceeds \(frameLimit) bytes") }
                output.append(byte); continue
            }
            guard let frame = String(data: output, encoding: .utf8) else { throw failure("returned an invalid reply frame") }
            let fields = frame.components(separatedBy: "\t")
            if fields.first == "OK" { return Array(fields.dropFirst()) }
            if fields.first == "ERR", fields.count == 2, let code = Int32(fields[1]), code > 0 {
                throw NestError("Helper \(operation) rejected operation: \(String(cString: strerror(code))).", code: 6)
            }
            throw failure("returned an invalid reply frame")
        }
    }
    public static func status(_ journal: Journal, id: UUID) throws -> NativePinStatus {
        guard let path = journal.socket else { throw NestError("No helper session.", code: 2) }
        let fields = try request(path, "status", timeout: 2)
        return try NativePinStatus.decode(fields, id: id)
    }
    public static func launch(helper: URL, arguments: [String]) throws {
        guard arguments.first == "--pin-v1" else { throw NestError("Only the native user pin can detach.", code: 64) }
        let process = Process(); process.executableURL = helper; process.arguments = ["--daemonize"] + arguments
        let null = FileHandle(forUpdatingAtPath: "/dev/null")!
        process.standardInput = null; process.standardOutput = null; process.standardError = null
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NestError("Could not start the packaged native tmpfs pin helper.", code: 2) }
    }
    @discardableResult public static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NestError("\((executable as NSString).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))", code: 6) }
        return output
    }
}
