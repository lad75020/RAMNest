#if DEBUG
import Foundation
import Darwin

public final class DebugBenchmarkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw NestError("Benchmark cancelled; owned-file cleanup attempted.") }
    }
}

/// Only this private namespace and its recorded inodes can be removed. All
/// mutation is fd-relative; a changed public path never authorizes cleanup.
final class DebugBenchmarkFile {
    let parent: DirectoryHandle
    let directory: DirectoryHandle
    let name: String
    private let directoryIdentity: (device: UInt64, inode: UInt64)
    private var fileIdentity: (device: dev_t, inode: ino_t)?
    private(set) var fd: Int32 = -1
    init(parent: DirectoryHandle, run: UUID) throws {
        self.parent = parent; name = ".ramnest-debug-io-\(run.uuidString)"
        directory = try parent.createDirectory(name)
        directoryIdentity = try directory.identity()
        var st = stat(), fs = statfs(), parentFS = statfs()
        guard fstat(directory.fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700,
              fstatfs(directory.fd, &fs) == 0, fstatfs(parent.fd, &parentFS) == 0,
              fs.f_fsid.val.0 == parentFS.f_fsid.val.0, fs.f_fsid.val.1 == parentFS.f_fsid.val.1 else {
            throw NestError("Benchmark namespace identity or filesystem changed; no file created.")
        }
    }
    func create() throws -> Int32 {
        guard fd < 0, fileIdentity == nil else { throw NestError("Benchmark file already created.") }
        fd = openat(directory.fd, "payload", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NestError("Cannot create exclusive benchmark payload (errno \(errno)).") }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              st.st_mode & 0o777 == 0o600, Paths.deviceID(st.st_dev) == directoryIdentity.device else {
            throw NestError("Benchmark payload identity could not be recorded; cleanup requires inspection.")
        }
        fileIdentity = (st.st_dev, st.st_ino); return fd
    }
    func reopen(_ flags: Int32) throws -> Int32 {
        guard fd < 0 else { throw NestError("Benchmark descriptor is already open.") }
        fd = openat(directory.fd, "payload", flags | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError("Cannot reopen owned benchmark payload (errno \(errno)).") }
        var st = stat()
        guard fstat(fd, &st) == 0, let expected = fileIdentity,
              st.st_dev == expected.device, st.st_ino == expected.inode,
              st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { throw NestError("Benchmark payload was replaced; I/O refused.") }
        return fd
    }
    func closeFile() throws {
        if fd >= 0 {
            let descriptor = fd; fd = -1
            guard Darwin.close(descriptor) == 0 else { throw NestError("Benchmark close failed (errno \(errno)); completion is uncertain.") }
        }
    }
    func cleanup() throws {
        var closeFailure: Error?
        do { try closeFile() } catch { closeFailure = error }
        if let expected = fileIdentity {
            var st = stat()
            guard fstatat(directory.fd, "payload", &st, AT_SYMLINK_NOFOLLOW) == 0,
                  st.st_dev == expected.device, st.st_ino == expected.inode,
                  st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1,
                  unlinkat(directory.fd, "payload", 0) == 0 else {
                throw NestError("Owned payload changed or disconnected; unrelated entries were retained. Cleanup incomplete.")
            }
            fileIdentity = nil
        }
        var st = stat()
        guard fstatat(parent.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
              Paths.deviceID(st.st_dev) == directoryIdentity.device, UInt64(st.st_ino) == directoryIdentity.inode,
              st.st_mode & S_IFMT == S_IFDIR, unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else {
            throw NestError("Owned benchmark directory changed or is nonempty; cleanup incomplete.")
        }
        if let closeFailure { throw closeFailure }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
}

public enum DebugBenchmarkWorker {
    public static let decimalGB: UInt64 = 1_000_000_000
    public static let blockBytes = 1_048_576
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    static func requiredCapacity(bytes: UInt64) throws -> UInt64 {
        let page: UInt64 = 65536, headroom: UInt64 = 16 * 1024 * 1024
        guard bytes > 0, bytes <= UInt64.max - page - headroom else { throw NestError("Benchmark capacity overflow.") }
        return ((bytes + page - 1) / page) * page + headroom
    }
    static func checkCapacity(available: UInt64, bytes: UInt64) throws {
        guard try available >= requiredCapacity(bytes: bytes) else {
            throw NestError("Benchmark needs 1 GB rounded to 64 KiB pages plus 16 MiB free headroom. Free space or enlarge this disposable mount.")
        }
    }
    // SplitMix64, distinct pseudo-random words throughout every 64 KiB page.
    // The bounded base buffer is prepared before any throughput measurement.
    static func payload(count: Int, seed: UInt64) -> [UInt8] {
        var state = seed, result = [UInt8](repeating: 0, count: count)
        for offset in stride(from: 0, to: count, by: 8) {
            state &+= 0x9e3779b97f4a7c15
            var value = state; value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb; value ^= value >> 31
            for i in 0..<min(8, count-offset) { result[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
        }
        return result
    }
    static func tag(_ buffer: inout [UInt8], offset: UInt64) {
        for page in stride(from: 0, to: buffer.count, by: 65536) {
            let absolute = offset + UInt64(page)
            for i in 0..<min(8, buffer.count-page) { buffer[page+i] = UInt8(truncatingIfNeeded: absolute >> (i*8)) }
        }
    }
    @discardableResult static func transfer(count: Int, cancellation: DebugBenchmarkCancellation,
        operation: (Int, Int) throws -> Int) throws -> Int {
        var done = 0
        while done < count {
            try cancellation.check()
            let n = try operation(done, count-done)
            if n < 0 && errno == EINTR { continue }
            guard n > 0, n <= count-done else { throw NestError("Benchmark short/failed I/O (errno \(n < 0 ? errno : EIO)).") }
            done += n
        }
        return done
    }
    struct Target {
        let folder: Folder
        let journal: Journal
        let status: HelperStatus
        let path: String
        let directory: DirectoryHandle
        let device: UInt64, inode: UInt64
        let fs0, fs1: Int32
        let socket: String
    }
    private static func target(engine: Engine, id: UUID) throws -> Target {
        let folder = try engine.folder(id.uuidString), j = try engine.store.journal(id)
        guard j.phase == .mounted, j.populationVerified, j.session != nil, let backend = j.backend,
              let socket = j.socket, let mountedDevice = j.mountedDevice else { throw NestError("Select a ready, active mounted RAM folder.") }
        let path: String
        if backend == .fskit {
            guard let layout = j.fsKitLink, layout.session == j.session, layout.folderID == id, layout.stage == .linked else { throw NestError("Current FSKit mount authority is missing.") }
            try layout.validate(); path = layout.mountPath
        } else {
            guard j.fsKitLink == nil else { throw NestError("Mount backend authority mismatch.") }
            path = folder.path
        }
        let status = try Control.status(j, id: id)
        guard status.active, status.mounted, status.pid > 0, kill(status.pid, 0) == 0,
              j.startupHelperPID.map({ $0 == status.pid }) ?? true,
              Paths.mounts().contains(where: { $0.path == path }) else { throw NestError("Current helper or mounted session is not active.") }
        let directory = try DirectoryHandle.open(URL(fileURLWithPath: path))
        let identity = try directory.identity()
        var fs = statfs()
        guard identity.device == mountedDevice, fstatfs(directory.fd, &fs) == 0 else { throw NestError("Pinned mount identity mismatch.") }
        let actualMount = withUnsafePointer(to: &fs.f_mntonname) { p in p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        guard actualMount == path, Paths.mounts().contains(where: { $0.path == path && $0.device == Paths.filesystemID(fs.f_fsid.val.0) }) else { throw NestError("Descriptor does not refer to the exact current public mount.") }
        return Target(folder: folder, journal: j, status: status, path: path, directory: directory, device: identity.device, inode: identity.inode, fs0: fs.f_fsid.val.0, fs1: fs.f_fsid.val.1, socket: socket)
    }
    private static func recheck(_ original: Target, engine: Engine) throws {
        let next = try target(engine: engine, id: original.folder.id)
        guard next.folder == original.folder, next.journal.session == original.journal.session,
              next.journal.socket == original.socket, next.journal.backend == original.journal.backend,
              next.status.pid == original.status.pid, next.path == original.path,
              next.device == original.device, next.inode == original.inode,
              next.fs0 == original.fs0, next.fs1 == original.fs1 else { throw NestError("Benchmark mount/session/configuration changed; stopped.") }
    }
    public static func run(engine: Engine, id: UUID, mode: DebugBenchmarkMode, cancellation: DebugBenchmarkCancellation,
                           progress: @escaping @Sendable (DebugBenchmarkProgress) -> Void = { _ in }) -> DebugBenchmarkReport {
        run(engine: engine, id: id, mode: mode, bytes: decimalGB, block: blockBytes, cancellation: cancellation, progress: progress)
    }
    // Only @testable clients can reduce the payload. The UI/public API is fixed 1 GB.
    static func run(engine: Engine, id: UUID, mode: DebugBenchmarkMode, bytes: UInt64, block: Int,
                    cancellation: DebugBenchmarkCancellation, progress: @escaping @Sendable (DebugBenchmarkProgress) -> Void) -> DebugBenchmarkReport {
        run(mode: mode, bytes: bytes, block: block, cancellation: cancellation, progress: progress,
            acquire: {
                do { return try target(engine: engine, id: id) }
                catch { throw NestError("Current ready mount/session authority could not be verified. Check mount readiness before retrying. Paths are omitted from profiling logs.") }
            },
            verify: {
                do { try recheck($0, engine: engine) }
                catch { throw NestError("Current mount/session/configuration changed or disconnected; benchmark stopped. Paths are omitted from profiling logs.") }
            },
            request: { try Control.request($0, $1, timeout: 2) })
    }
    // Owned-directory XCTest boundary only; production always supplies the live
    // mount/session checks above. No environment switch or synthetic metrics.
    static func run(mode: DebugBenchmarkMode, bytes: UInt64, block: Int, cancellation: DebugBenchmarkCancellation,
                    progress: @escaping @Sendable (DebugBenchmarkProgress) -> Void,
                    acquire: () throws -> Target, verify: (Target) throws -> Void,
                    request: (String, String) throws -> [String]) -> DebugBenchmarkReport {
        let started = now(), run = UUID()
        var report = DebugBenchmarkReport(run: run, requestedBytes: bytes, blockBytes: block, mode: mode)
        var owned: DebugBenchmarkFile?
        var creationAttempted = false
        var activePhase: String?
        var reservationAttempted = false
        var socket: String?
        var verification = FileVerification.sha256
        func rpc(_ verb: String, _ phase: String) throws -> DebugHelperProfile {
            guard let socket else { throw NestError("No Debug helper socket.") }
            let fields = try request(socket, "\(verb)\t\(run.uuidString)\t\(phase)")
            return try DebugHelperProfile.parse(fields, run: run, phase: phase, verification: verification)
        }
        do {
            guard bytes > 0, bytes <= decimalGB, (1_048_576...8_388_608).contains(block) else { throw NestError("Invalid bounded benchmark configuration.") }
            try cancellation.check()
            let target = try acquire(); socket = target.socket; verification = target.journal.fileVerification
            let caps = try request(target.socket, "capabilities")
            guard caps.contains("debug-io-profile-v2"), caps.contains("debug-benchmark-reservation-v1") else { throw NestError("Mounted helper lacks the Debug v2 profiling/reservation capability; eject and remount with the current Debug helper before benchmarking.") }
            let initialPhase = mode == .read ? "read" : "write"
            // Probe the actual running interval/compression before creating even a directory.
            let begin: DebugHelperProfile
            activePhase = initialPhase
            reservationAttempted = true
            do { begin = try rpc("profile-begin", initialPhase) }
            catch { throw NestError("Debug helper refused profiling or returned an invalid response. Disable periodic save, then eject and remount with the current Debug helper; finish any other active collector. " + error.localizedDescription) }
            guard !begin.stopped, !begin.expired, begin.periodicMinutes == 0, begin.backend == target.journal.backend?.rawValue else { throw NestError("Running helper configuration differs. Disable periodic save, then eject and remount using Debug.") }
            report.backend = begin.backend; report.compression = begin.compression
            let probeEnd = try rpc("profile-end", initialPhase); activePhase = nil
            guard probeEnd.stopped, !probeEnd.expired, probeEnd.backend == begin.backend,
                  probeEnd.compression == begin.compression, probeEnd.periodicMinutes == 0 else {
                throw NestError("Helper did not confirm a stopped, matching Debug probe; no fixture created.")
            }
            guard probeEnd.inFlight == 0 else { throw NestError("Helper is busy with in-flight I/O; retry after other clients finish.") }
            try verify(target)
            var fs = statfs()
            guard fstatfs(target.directory.fd, &fs) == 0, fs.f_bsize > 0 else { throw NestError("Cannot inspect mounted capacity.") }
            let availableBlocks = UInt64(fs.f_bavail), blockSize = UInt64(fs.f_bsize)
            let (available, overflow) = availableBlocks.multipliedReportingOverflow(by: blockSize)
            guard !overflow else { throw NestError("Mounted capacity overflow.") }
            try checkCapacity(available: min(available, target.status.capacity >= target.status.used ? target.status.capacity-target.status.used : 0), bytes: bytes)
            var input = payload(count: block, seed: 0x52414d4e45535431)
            var output = [UInt8](repeating: 0, count: block)
            creationAttempted = true
            owned = try DebugBenchmarkFile(parent: target.directory, run: run)
            guard let file = owned else { throw NestError("Missing benchmark namespace.") }
            _ = try file.create(); try file.closeFile()
            report.event("app", "prepare", "Bounded pseudo-random buffer prepared; private 0600 payload created under pinned current mount.")
            var lastProgress = 0.0, lastCheck = now()
            func check() throws {
                try cancellation.check()
                guard now()-started < 290 else { throw NestError("Benchmark exceeded its 290 second deadline.") }
                if now()-lastCheck >= 1 { try verify(target); lastCheck = now() }
            }
            func emit(_ phase: String, _ done: UInt64) {
                let t = now()
                if t-lastProgress >= 0.125 { progress(.init(phase: phase, bytes: done, total: bytes)); lastProgress = t }
            }
            func io(write: Bool, phase: String, record: inout DebugBenchmarkPhase) throws {
                try verify(target)
                let start = now()
                defer { record.wallSeconds += now()-start }
                var t = now()
                let fd = try file.reopen(write ? O_RDWR : O_RDONLY); record.syscallSeconds += now()-t
                errno = 0; record.cacheNoCacheAccepted = fcntl(fd, F_NOCACHE, 1) == 0
                record.cacheErrno = record.cacheNoCacheAccepted ? 0 : errno
                var offset: UInt64 = 0
                while offset < bytes {
                    try check()
                    let n = Int(min(UInt64(block), bytes-offset))
                    t = now(); tag(&input, offset: offset); record.generationSeconds += now()-t
                    var transferred = 0
                    defer { record.bytes += UInt64(transferred) }
                    try input.withUnsafeBytes { expected in
                        try output.withUnsafeMutableBytes { actual in
                            try transfer(count: n, cancellation: cancellation) { done, remaining in
                                try check()
                                let before = now()
                                let result = write ? pwrite(fd, expected.baseAddress!.advanced(by: done), remaining, off_t(offset)+off_t(done)) : pread(fd, actual.baseAddress!.advanced(by: done), remaining, off_t(offset)+off_t(done))
                                record.syscallSeconds += now()-before
                                if result > 0 { transferred += result }
                                return result
                            }
                            if !write {
                                let before = now()
                                let matches = memcmp(expected.baseAddress!, actual.baseAddress!, n) == 0
                                record.verificationSeconds += now()-before
                                guard matches else { throw NestError("Benchmark payload/offset verification failed.") }
                            }
                        }
                    }
                    offset += UInt64(n); emit(phase, offset)
                }
                if write {
                    t = now()
                    while fsync(fd) != 0 { if errno == EINTR { try check(); continue }; throw NestError("Benchmark fsync failed (errno \(errno)).") }
                    record.syscallSeconds += now()-t
                }
                t = now(); try file.closeFile(); record.syscallSeconds += now()-t
                if !write { record.verified = true }
            }
            if mode == .read {
                emit("Preparing own 1 GB input (untimed)", 0)
                var prep = DebugBenchmarkPhase(phase: "prepare")
                try io(write: true, phase: "Preparing own input (untimed)", record: &prep)
                report.event("app", "prepare", "Standalone read input fully written, fsynced, closed; excluded from read throughput and read helper window.")
            }
            report.preparationSeconds = now()-started
            for phase in (mode == .both ? ["write", "read"] : [mode.rawValue]) {
                try check(); try verify(target)
                activePhase = phase
                let begin = try rpc("profile-begin", phase)
                guard begin.backend == report.backend, begin.compression == report.compression, begin.periodicMinutes == 0, !begin.stopped, !begin.expired else { throw NestError("Helper runtime configuration changed. Disable periodic save and remount Debug.") }
                report.event("helper", phase, "Started window-wide epoch; actual running backend/compression captured over same-UID Control.")
                var measurement = DebugBenchmarkPhase(phase: phase)
                do {
                    try io(write: phase == "write", phase: phase, record: &measurement)
                    measurement.helper = try rpc("profile-end", phase); activePhase = nil
                    guard let h = measurement.helper, h.stopped, !h.expired, h.periodicMinutes == 0, h.backend == report.backend, h.compression == report.compression else { throw NestError("Helper window was lost, reconfigured or expired; no valid completed timing.") }
                    report.phases.append(measurement)
                    report.event("helper", phase, "Stopped epoch; aggregates returned, not inferred from daemon stderr. See inFlight and callback bytes for accounting limitations.")
                } catch {
                    if activePhase != nil { measurement.helper = try? rpc("profile-end", phase); activePhase = nil }
                    report.phases.append(measurement); throw error
                }
            }
            if mode == .write {
                var verify = DebugBenchmarkPhase(phase: "verify")
                let t = now(); try io(write: false, phase: "Verifying write (untimed)", record: &verify)
                report.phases[0].externalVerificationSeconds = now()-t
                report.event("app", "verify", String(format: "Separate full payload readback verified in %.6f seconds (outside write throughput/window).", report.phases[0].externalVerificationSeconds))
                report.phases[0].verified = true
            } else if mode == .both, report.phases.last?.verified == true { report.phases[0].verified = true }
        } catch {
            report.failure = error.localizedDescription
            report.event("app", "failure", "Benchmark stopped; cleanup is fd-relative and restricted to recorded owned inodes.")
        }
        if let activePhase { _ = try? rpc("profile-end", activePhase) }
        let cleanupStart = now()
        if let owned {
            do { try owned.cleanup(); report.cleanupSucceeded = true }
            catch { report.failure = (report.failure.map { $0 + " " } ?? "") + error.localizedDescription }
        } else {
            report.cleanupSucceeded = !creationAttempted
            if creationAttempted { report.failure = (report.failure ?? "") + " Namespace creation did not complete; removal could not be verified." }
        }
        if reservationAttempted, report.cleanupSucceeded, let socket {
            do {
                let fields = try request(socket, "profile-release\t\(run.uuidString)\t\(mode == .read ? "read" : "write")")
                guard fields == [run.uuidString] else { throw NestError("Helper did not acknowledge benchmark reservation release.") }
                report.event("helper", "cleanup", "Fixture removed before reservation release; periodic/checkpoint admission restored.")
            } catch {
                report.failure = (report.failure.map { $0 + " " } ?? "") + " Reservation release unconfirmed; helper keeps checkpoint protection. " + error.localizedDescription
            }
        }
        report.cleanupSeconds = now()-cleanupStart; report.totalSeconds = now()-started
        report.event("app", "cleanup", report.cleanupSucceeded ? "Owned fixture removed (or no fixture created)." : "Cleanup incomplete; changed/unrelated entries retained.")
        return report
    }
}
#endif
