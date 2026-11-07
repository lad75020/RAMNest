import Foundation
import Darwin

// A narrow session boundary lets owned fixtures exercise coordinator behavior
// without mounting a filesystem or launching a native helper.
struct EngineSession {
    var beforeVolumeLock: ((UUID) throws -> Void)?
    var unmount: (String) throws -> Void = { _ = try Control.run("/sbin/umount", [$0]) }
    var beforeCleanupUnlink: ((DirectoryHandle, String) throws -> Void)?
    var populationRead: ((URL) throws -> Manifest)? = nil
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var request: (String, String) throws -> [String] = { try Control.request($0, $1) }
    var status: (Journal, UUID) throws -> HelperStatus = { try Control.status($0, id: $1) }
    var mountedIdentity: (Folder, Journal) -> Bool = { folder, journal in
        guard let device = journal.mountedDevice else { return false }
        var st = stat()
        return lstat(folder.path, &st) == 0 && Paths.deviceID(st.st_dev) == device && Paths.mounts().contains { $0.path == folder.path }
    }
}

// Offline negotiation is deliberately separate from --storage-capabilities:
// old callers require that reply to remain exactly private-storage-v2.
enum GuardedPopulationStartup {
    static let version = "pre-mount-population-v1"
    static func negotiate(_ query: () throws -> String) throws -> Bool {
        let output: String
        do { output = try query() } catch { return false } // Unsupported old helper.
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == version else {
            throw NestError("Helper returned an unsupported guarded-startup capability. Originals retained.", code: 6)
        }
        return true
    }
    static func arguments(enabled: Bool, owner: Int32 = getpid()) -> [String] {
        enabled ? ["--guarded-startup", version, "--startup-owner", String(owner)] : []
    }
    // Production call order, also exercised by canonical XCTest methods. The
    // request closure remains Control.request with its monotonic progress policy.
    static func populate(enabled: Bool, digest: String?, controlReady: () throws -> Void,
                         request: (String) throws -> [String], mountReady: () throws -> Void) throws {
        if enabled { try controlReady() } else { try mountReady() }
        if let digest {
            guard digest.utf8.count == 64, digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
                  try request("capabilities").contains("private-storage-v2") else {
                throw NestError("Running helper cannot populate storage format 2. Originals retained.", code: 6)
            }
        }
        let reply = try request(digest.map { "populate2\t" + $0 } ?? "populate")
        guard !enabled || reply.isEmpty else { throw NestError("Invalid guarded population ACK.", code: 6) }
        if enabled {
            guard try request("startup-status") == [version, "populated"],
                  try request("mount-populated") == [version, "mount-requested"] else {
                throw NestError("Invalid guarded startup ACK; RAM writes remain guarded.", code: 6)
            }
            try mountReady()
        }
    }
}

// Kept internal so the post-populate decision can be exercised without mounts.
enum PopulationReadiness {
    static func verify(expected: Manifest, read: () throws -> Manifest,
                       sleep: (TimeInterval) -> Void, uptime: () -> TimeInterval,
                       timeout: TimeInterval = 3, interval: TimeInterval = 0.15,
                       maximumAttempts: Int = 21, missingFlagsMask: UInt32 = 0) throws {
        guard timeout.isFinite, timeout >= 0, interval.isFinite, interval > 0, maximumAttempts > 0 else {
            throw NestError("Invalid population readiness bounds; RAM writes remain guarded.", code: 6)
        }
        let deadline = uptime() + timeout
        var attempts = 0
        var lastFailure = "full manifest mismatch"
        for attempt in 0..<maximumAttempts {
            // Always allow the initial full read, including large valid trees.
            // Synchronous reads finish normally; their runtime uses the budget.
            if attempt > 0 && uptime() >= deadline { break }
            attempts += 1
            do {
                var actual = try read()
                // Only this mounted-view comparison may project missing hint bits.
                // Clamp even internal callers to the two owner-approved flags.
                let allowed = missingFlagsMask & UInt32(UF_HIDDEN | UF_NODUMP)
                for index in 0..<min(actual.entries.count, expected.entries.count) {
                    let observed = actual.entries[index].flags
                    let raw = expected.entries[index].flags
                    if observed & ~raw == 0 && (raw & ~observed) & ~allowed == 0 {
                        actual.entries[index].flags = raw
                    }
                }
                if actual.matchesExpected(expected) { return }
                lastFailure = "full manifest mismatch " + Snapshot.mismatchDetail(actual, expected)
            } catch {
                guard transient(error) else { throw error }
                lastFailure = diagnostic(error)
            }
            // No shortened waits/busy loop near expiry, or sleep after the last
            // attempt. A scheduler oversleep is checked before the next read.
            guard attempt + 1 < maximumAttempts, deadline - uptime() >= interval else { break }
            sleep(interval)
        }
        throw NestError("Mounted population did not become ready after \(attempts) strict verification attempts: \(lastFailure). RAM writes remain guarded; initial snapshot and original files retained for explicit recovery.", code: 6)
    }
    private static func transient(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain {
            // FSKit can expose an expired startup directory handle before its
            // client view settles. This bounded read-only verification still
            // requires an exact manifest before RAM is ever activated.
            guard [Int(EIO), Int(ENOENT), Int(EBADF)].contains(failure.code) else { return false }
        } else if failure.domain == NSCocoaErrorDomain {
            guard [CocoaError.Code.fileReadUnknown, .fileReadNoSuchFile, .fileNoSuchFile].contains(where: { $0.rawValue == failure.code }) else { return false }
        } else { return false }
        // A Cocoa read wrapper must never hide a permission/security failure.
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error {
            return transient(underlying, depth: depth + 1)
        }
        return true
    }
    private static func diagnostic(_ error: Error, depth: Int = 0) -> String {
        let failure = error as NSError
        var value = "\(failure.domain) code \(failure.code)"
        if let operation = failure.userInfo[Snapshot.readOperationErrorKey] as? String,
           ["listxattr", "getxattr"].contains(operation) { value += " during " + operation }
        if let path = failure.userInfo[NSFilePathErrorKey] as? String {
            value += " at " + String(path.prefix(1024)).debugDescription
        }
        if depth < 7, let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error {
            value += "; " + diagnostic(underlying, depth: depth + 1)
        }
        // Structured operation/path only; never include arbitrary error text,
        // attribute names/values or file contents.
        return value
    }
}

public final class Engine: @unchecked Sendable {
    public let store: Store
    public let helper: URL
    public let cli: URL
    private let session: EngineSession
    public convenience init(store: Store, helper: URL? = nil, cli: URL? = nil) {
        self.init(store: store, helper: helper, cli: cli, session: EngineSession())
    }
    init(store: Store, helper: URL? = nil, cli: URL? = nil, session: EngineSession) {
        self.store = store
        self.session = session
        let binary = BinaryLocation.executable
        let bundle = Bundle.main.bundleURL
        self.helper = helper ?? (bundle.pathExtension == "app" ? bundle.appendingPathComponent("Contents/Helpers/ramnest-helper") : binary.deletingLastPathComponent().appendingPathComponent("ramnest-helper"))
        self.cli = cli ?? (bundle.pathExtension == "app" ? bundle.appendingPathComponent("Contents/Helpers/ramnest") : binary)
    }
    public func statuses() throws -> [FolderStatus] {
        let folders = try store.locked { try store.load().folders }
        return try folders.map { folder in
                let j = try store.journal(folder.id)
                let live = try? session.status(j, folder.id)
                let metrics = j.socket.flatMap { try? Control.request($0, "metrics", timeout: 2) }?.compactMap(UInt64.init) ?? []
                let mounted = Paths.mounts().contains { $0.path == folder.path } || (live?.mounted == true && mountedIdentity(folder, j))
                return FolderStatus(folder: folder, journal: j, connected: live != nil, mounted: mounted, used: live?.used ?? 0, contentBytes: metrics.count == 4 ? metrics[1] : 0, payloadBytes: metrics.count == 4 ? metrics[2] : 0, mappedBytes: metrics.count == 4 ? metrics[3] : 0, backingSavingsFraction: metrics.count == 4 && metrics[0] > 0 ? max(0, 1 - Double(metrics[3]) / Double(metrics[0])) : 0, helperActive: live?.active == true && mountedIdentity(folder, j))
        }
    }
    public func folder(_ ref: String) throws -> Folder { try store.locked { try store.resolve(ref, config: store.load()) } }
    private func volumeTransaction<T>(_ ref: String, _ operation: (Folder) throws -> T) throws -> T {
        let initial = try folder(ref)
        try session.beforeVolumeLock?(initial.id)
        return try store.volumeLocked(initial.id) {
            let current = try store.locked { try store.resolve(initial.id.uuidString, config: store.load()) }
            guard current.id == initial.id, current.path == initial.path, current.device == initial.device, current.inode == initial.inode else { throw NestError("Folder configuration changed.", code: 6) }
            return try operation(current)
        }
    }
    public func create(path: URL, name: String?, capacity: UInt64, options: FolderOptions = .init()) throws -> Folder {
        try SizeParser.validate(capacity)
        let url = path.standardizedFileURL
        let initialConfig = try store.locked { try store.load() }
        let st = try Paths.validate(url, store: store, folders: initialConfig.folders)
        let label = (name ?? url.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        try validateName(label, excluding: nil, config: initialConfig)
        let manifest = try Snapshot.manifest(url, maximumLogical: capacity)
        try manifest.preflight(capacity: capacity)
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try store.locked {
            var config = try store.load()
            let current = try Paths.validate(url, store: store, folders: config.folders)
            guard current.st_dev == st.st_dev, current.st_ino == st.st_ino else { throw NestError("Selected folder changed during admission.", code: 4) }
            try validateName(label, excluding: nil, config: config)
            let f = Folder(name: label, path: url.path, capacity: capacity, device: Paths.deviceID(st.st_dev), inode: UInt64(st.st_ino), bookmark: bookmark, options: options)
            config.folders.append(f); try store.save(config); try store.write(Journal(), for: f.id); return f
        }
    }
    private func validateName(_ name: String, excluding: UUID?, config: Configuration) throws {
        guard !name.isEmpty, name.utf8.count <= 255, !name.contains("\n"), !name.contains("\t"), !name.contains("\0"), !config.folders.contains(where: { $0.id != excluding && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw NestError("Names must be nonempty and unique, ignoring case.", code: 64) }
    }
    public func update(_ edited: Folder) throws {
        try volumeTransaction(edited.id.uuidString) { _ in
            let config = try store.load(); guard let i = config.folders.firstIndex(where: { $0.id == edited.id }) else { throw NestError("Folder was removed.") }
            let old = config.folders[i]
            guard edited.path == old.path, edited.device == old.device, edited.inode == old.inode, edited.capacity == old.capacity else { throw NestError("Use resize or locate; path identity cannot be edited.") }
            try validateName(edited.name, excluding: edited.id, config: config)
            guard FolderOptions.intervals.contains(edited.options.intervalMinutes) else { throw NestError("Unsupported periodic interval.", code: 64) }
            let j = try store.journal(edited.id)
            guard j.phase == .idle || j.phase == .mounted else { throw NestError("Finish recovery or the current operation before editing options.", code: 6) }
            try store.locked {
                var latest = try store.load()
                guard let current = latest.folders.firstIndex(where: { $0.id == edited.id }) else { throw NestError("Folder was removed.") }
                try validateName(edited.name, excluding: edited.id, config: latest)
                latest.folders[current] = edited; try store.save(latest)
            }
            if let socket = j.socket, (try? session.status(j, edited.id)) != nil { _ = try session.request(socket, "period\t\(edited.options.sync && edited.options.periodicSave ? edited.options.intervalMinutes : 0)") }
        }
    }
    public func setMenuBarMode(_ enabled: Bool) throws { try store.locked { var c = try store.load(); c.menuBarMode = enabled; try store.save(c) } }
    public func backend() throws -> Configuration.Backend { try store.locked { try store.load().backend } }
    @discardableResult public func setBackend(_ backend: Configuration.Backend) throws -> Configuration.Backend {
        try store.locked {
            var config = try store.load(); config.backend = backend
            try store.save(config)
            let saved = try store.load().backend
            guard saved == backend else { throw NestError("Backend preference could not be verified. Read Settings again before mounting.") }
            return saved
        }
    }
    public func mountedIdentity(_ folder: Folder, _ journal: Journal) -> Bool {
        session.mountedIdentity(folder, journal)
    }
    private func requireLive(_ folder: Folder, _ j: Journal) throws -> HelperStatus {
        let status = try session.status(j, folder.id)
        guard status.mounted, mountedIdentity(folder, j) else { throw NestError("Mounted identity is uncertain. Recover or export before continuing.", code: 6) }
        return status
    }
    private func cleanSnapshots(_ folder: Folder, _ journal: inout Journal) {
        guard journal.phase == .idle || journal.phase == .mounted, journal.lastError == nil else { return }
        let pinned = journal
        SnapshotRetention.clean(store: store, folder: folder, journal: &journal, validateSource: {
            if pinned.phase == .mounted { _ = try self.requireLive(folder, pinned) }
            else {
                guard !Paths.mounts().contains(where: { $0.path == folder.path || $0.path.hasPrefix(folder.path + "/") }) else { throw NestError("Selected mount identity changed; cleanup skipped.", code: 6) }
                try Paths.checkedIdentity(folder)
            }
        }, beforeSiblingUnlink: session.beforeCleanupUnlink)
    }
    func helperArguments(_ folder: Folder, journal: Journal, source: URL) throws -> [String] {
        guard let backend = journal.backend, let socket = journal.socket else { throw NestError("Missing prepared session backend or socket.", code: 6) }
        return ["--id", folder.id.uuidString, "--volume", try store.volume(folder.id).path, "--mount", folder.path, "--source", source.path, "--size", String(folder.capacity), "--socket", socket, "--cli", cli.path, "--store", store.root.path, "--nobrowse", String(folder.options.nobrowse), "--compression", String(folder.options.compression), "--backend", backend.rawValue]
    }
    public func mount(_ ref: String) throws {
        try volumeTransaction(ref) { current in
            let config = try store.load(); var f = current; var j = try store.journal(f.id)
            if let status = try? session.status(j, f.id), status.mounted, mountedIdentity(f, j) {
                guard j.populationVerified, j.phase == .mounted else { throw NestError("A guarded mount needs recovery; eject it before restoring the initial snapshot.", code: 6) }
                if !status.active {
                    guard let revision = j.initialRevision else { throw NestError("Missing verified population revision.", code: 6) }
                    let (_, expected) = try Snapshot.verified(store: store, id: f.id, revision: revision)
                    guard try Snapshot.manifest(URL(fileURLWithPath: f.path), matching: expected).matchesExpected(expected) else { throw NestError("Guarded mount changed. Recovery required.", code: 6) }
                    _ = try session.request(j.socket!, "activate")
                }
                cleanSnapshots(f, &j)
                return
            }
            guard j.phase == .idle else { throw NestError("Unclean session requires explicit recovery before mounting. Use recover or export.", code: 6) }
            // Preserve completed-session provenance before resetting any refs,
            // even if cleanup cannot currently validate a missing old snapshot.
            SiblingCleanup.rememberCompleted(f, &j)
            try store.write(j, for: f.id)
            cleanSnapshots(f, &j)
            f = try Paths.resolveBookmark(f)
            _ = try Paths.validate(URL(fileURLWithPath: f.path), store: store, folders: config.folders, excluding: f.id)
            try store.locked {
                var latest = try store.load()
                guard let i = latest.folders.firstIndex(where: { $0.id == f.id }) else { throw NestError("Folder was removed.", code: 6) }
                _ = try Paths.validate(URL(fileURLWithPath: f.path), store: store, folders: latest.folders, excluding: f.id)
                latest.folders[i] = f;try store.save(latest)
            }
            guard FileManager.default.isExecutableFile(atPath: helper.path), FileManager.default.fileExists(atPath: "/Library/Application Support/fuse-t/lib/libfuse-t-1.2.9.dylib") else { throw NestError("Install FUSE-T and use the packaged RAMNest helper. See README.", code: 2) }
            SnapshotRetention.remember(&j)
            j.restoreRevision = nil
            j.phase = .preparing; j.lastError = nil; j.session = UUID(); j.backend = config.backend; j.mountedDevice = nil; j.populationVerified = false; j.initialRevision = nil; j.restoreStage = nil; j.restoredEntries = []; j.evacuatedEntries = []
            j.startupProtocol = nil; j.startupHelperPID = nil; j.startupRetired = nil
            try store.write(j, for: f.id)
            var helperStarted = false
            var guardedStartup = false
            var startupPID: Int32?
            do {
                let revision = try Snapshot.capture(store: store, folder: f, source: URL(fileURLWithPath: f.path), previous: j.revision)
                j.priorRevision = j.revision; j.revision = revision; j.nativeGeneration = nil; j.quiescedRevision = nil; j.initialRevision = revision; try store.write(j, for: f.id)
                let (data, manifest) = try Snapshot.verified(store: store, id: f.id, revision: revision)
                // The disk representation must be understood BEFORE any original
                // namespace is evacuated. This query never mounts/starts a server.
                let storage = try Snapshot.storedMetadata(data)
                if storage?.storageFormat == 2 {
                    guard try Control.run(helper.path,["--storage-capabilities"]).trimmingCharacters(in:.whitespacesAndNewlines) == "private-storage-v2" else { throw NestError("Helper does not support private snapshot storage format 2. Originals retained.", code: 6) }
                }
                guardedStartup = try GuardedPopulationStartup.negotiate { try Control.run(helper.path, ["--startup-capabilities"]) }
                let (sourceHandle,original) = try evacuateOriginal(f,journal:&j,expected:manifest)
                j.phase = .mounting
                j.socket = try Paths.socketDirectory(for: store).appendingPathComponent("\(j.session!.uuidString).sock").path
                j.startupProtocol = guardedStartup ? GuardedPopulationStartup.version : nil
                try store.write(j, for: f.id)
                do { try Control.launch(helper: helper, arguments: helperArguments(f, journal: j, source: data) + GuardedPopulationStartup.arguments(enabled: guardedStartup)) }
                catch { throw NestError(config.backend.mountFailureMessage + " Helper launch: " + error.localizedDescription, code: 2) }
                helperStarted = true
                // Separate control-startup, progress-aware import and OS-mount
                // budgets. Import never consumes or extends the mount budget.
                let socket = j.socket!
                try GuardedPopulationStartup.populate(enabled: guardedStartup, digest: storage?.modeMapDigest, controlReady: {
                    startupPID = try self.waitForGuardedControl(j, id: f.id)
                    j.startupHelperPID = startupPID
                    try self.store.write(j, for: f.id)
                }, request: { command in
                    if guardedStartup {
                        let status = try self.session.status(j, f.id)
                        guard status.pid == startupPID, !status.mounted, !status.active else { throw NestError("Guarded startup identity/state changed.", code: 6) }
                    }
                    return try self.session.request(socket, command)
                }, mountReady: {
                    j.mountedDevice = try self.waitForPopulationMount(j, folder: f, pid: startupPID, failure: config.backend.mountFailureMessage)
                    try self.store.write(j, for: f.id)
                })
                try verifyAndActivatePopulation(f, journal: &j, expected: manifest, source: sourceHandle, original: original)
                _ = try session.request(j.socket!, "period\t\(f.options.sync && f.options.periodicSave ? f.options.intervalMinutes : 0)")
                cleanSnapshots(f, &j)
            } catch {
                j.lastError = error.localizedDescription; j.phase = .recoveryRequired; try store.write(j, for: f.id)
                // Roll back a failure before mount; any mounted/uncertain session remains gated.
                if !Paths.mounts().contains(where: { $0.path == f.path }), !helperStarted { try? rollbackInitial(f, journal: &j) }
                else if guardedStartup, !j.populationVerified, !Paths.mounts().contains(where: { $0.path == f.path }) {
                    // Seal first: an unmounted status alone races fuse_main.
                    // Failure/uncertainty at any step retains originals + guard.
                    do {
                        try retireGuardedStartup(j, id: f.id, expectedPID: startupPID)
                        j.startupRetired = true; try store.write(j, for: f.id)
                        try rollbackInitial(f, journal: &j)
                    } catch { /* Uncertain retirement/rollback retains recoveryRequired. */ }
                }
                throw error
            }
        }
    }
    private func waitForGuardedControl(_ journal: Journal, id: UUID) throws -> Int32 {
        for _ in 0..<150 {
            if let status = try? session.status(journal, id) {
                guard status.id == id, status.pid > 1, !status.mounted, !status.active,
                      let socket = journal.socket,
                      try session.request(socket, "startup-status") == [GuardedPopulationStartup.version, "waiting"],
                      try session.request(socket, "capabilities").contains(GuardedPopulationStartup.version) else {
                    throw NestError("Helper did not enter negotiated guarded startup.", code: 6)
                }
                return status.pid
            }
            session.sleep(0.1)
        }
        throw NestError("Guarded helper control did not become ready. Originals retained.", code: 2)
    }
    private func waitForPopulationMount(_ journal: Journal, folder: Folder, pid: Int32?, failure: String) throws -> UInt64 {
        for _ in 0..<150 {
            if let status = try? session.status(journal, folder.id) {
                if let pid { guard status.pid == pid, !status.active else { throw NestError("Guarded mount identity/state changed.", code: 6) } }
                if status.mounted, Paths.mounts().contains(where: { $0.path == folder.path }) {
                    var st = stat()
                    if lstat(folder.path, &st) == 0 && Paths.deviceID(st.st_dev) != folder.device { return Paths.deviceID(st.st_dev) }
                }
            }
            session.sleep(0.1)
        }
        throw NestError(failure, code: 2)
    }
    func retireGuardedStartup(_ journal: Journal, id: UUID, expectedPID: Int32?) throws {
        guard let socket = journal.socket else { throw NestError("Missing guarded startup socket.", code: 6) }
        let before = try session.status(journal, id)
        guard before.id == id, before.pid > 1, !before.mounted, !before.active, expectedPID == nil || expectedPID == before.pid,
              try session.request(socket, "abort-startup") == [GuardedPopulationStartup.version, "retained"] else {
            throw NestError("Cannot prove unmounted guarded startup; originals retained.", code: 6)
        }
        let after = try session.status(journal, id)
        guard after.id == id, after.pid == before.pid, !after.mounted, !after.active, try session.request(socket, "retire").isEmpty else {
            throw NestError("Guarded startup retirement is uncertain; originals retained.", code: 6)
        }
    }
    // Shared by the real mount coordinator and owned crash/lifecycle tests.
    func evacuateOriginal(_ f: Folder, journal j: inout Journal, expected: Manifest) throws -> (DirectoryHandle,URL) {
        try Paths.checkedIdentity(f)
        let original = URL(fileURLWithPath: f.path).deletingLastPathComponent().appendingPathComponent(".ramnest-\(f.id.uuidString)-\(j.session!.uuidString).original")
        let parentHandle = try DirectoryHandle.open(original.deletingLastPathComponent())
        let originalHandle = try parentHandle.createDirectory(original.lastPathComponent)
        let originalIdentity = try originalHandle.identity()
        j.evacuation = original.path; j.evacuationDevice = originalIdentity.device; j.evacuationInode = originalIdentity.inode
        // Evacuate the complete original namespace, including opaque
        // excluded directories. The journal pins the normal no-follow
        // moves; cleanup retains holdings with any excluded subtree.
        let sourceHandle = try DirectoryHandle.open(URL(fileURLWithPath:f.path));try sourceHandle.verify(f)
        let names = try sourceHandle.names()
        j.evacuatedEntries = names; j.phase = .evacuated; try store.write(j, for: f.id)
        guard try Snapshot.manifest(URL(fileURLWithPath: f.path)) == expected else { throw NestError("Source changed before evacuation.", code: 6) }
        let sourceFD = dup(sourceHandle.fd)
        let holdingFD = dup(originalHandle.fd)
        guard sourceFD >= 0, holdingFD >= 0 else { if sourceFD >= 0 { close(sourceFD) }; if holdingFD >= 0 { close(holdingFD) }; throw NestError("Cannot open source transaction directories.", code: 6) }
        defer { close(sourceFD); close(holdingFD) }
        for name in names {
            try Paths.checkedIdentity(f)
            guard renameatx_np(sourceFD, name, holdingFD, name, UInt32(RENAME_EXCL)) == 0 else { throw NestError("Cannot move selected entry \(name). Originals and snapshot retained.", code: 6) }
        }
        guard fsync(sourceFD) == 0, fsync(holdingFD) == 0, try Snapshot.manifest(original).contentsMatchExpected(expected), try FileManager.default.contentsOfDirectory(atPath: f.path).isEmpty else { throw NestError("Source write race detected. Recovery required; originals retained.", code: 6) }
        return (sourceHandle,original)
    }
    // Caller has populated a guarded session and owns repository.lock. Original
    // directory checks and the durable verification record still precede activate.
    func verifyAndActivatePopulation(_ f: Folder, journal j: inout Journal, expected: Manifest,
                                     source: DirectoryHandle, original: URL) throws {
        do {
            try PopulationReadiness.verify(expected: expected, read: { if let read = session.populationRead { return try read(URL(fileURLWithPath: f.path)) }; return try Snapshot.manifest(URL(fileURLWithPath: f.path), matching: expected) },
                                           sleep: session.sleep, uptime: session.uptime,
                                           missingFlagsMask: (j.backend == .fskit || j.backend == .nfs) ? UInt32(UF_HIDDEN | UF_NODUMP) : 0)
            guard try source.names().isEmpty, try Snapshot.manifest(original, matching: expected).contentsMatchExpected(expected) else { throw NestError("Original files changed during mount. RAM writes remain guarded; both copies retained for explicit recovery.", code: 6) }
            j.populationVerified = true; j.phase = .mounted; try store.write(j, for: f.id)
            _ = try session.request(j.socket!, "activate")
        } catch {
            j.lastError = error.localizedDescription; j.phase = .recoveryRequired; try store.write(j, for: f.id)
            throw error
        }
    }
    private func rollbackInitial(_ f: Folder, journal j: inout Journal) throws {
        guard j.startupProtocol == nil || j.startupProtocol == GuardedPopulationStartup.version else {
            throw NestError("Unknown guarded startup journal; originals retained.", code: 6)
        }
        guard j.populationVerified || j.startupProtocol == nil || j.startupRetired == true else {
            throw NestError("Guarded startup retirement is unproven. Original files and snapshot retained.", code: 6)
        }
        try Paths.checkedIdentity(f)
        guard let revision = j.initialRevision else { j.phase = .idle; try store.write(j, for: f.id); return }
        let (_, expected) = try Snapshot.verified(store: store, id: f.id, revision: revision)
        let selectedHandle = try DirectoryHandle.open(URL(fileURLWithPath: f.path)); try selectedHandle.verify(f)
        if let holding = j.evacuation {
            let original = try DirectoryHandle.open(URL(fileURLWithPath: holding))
            let identity = try original.identity()
            if let device = j.evacuationDevice, let inode = j.evacuationInode { guard identity.device == device && identity.inode == inode else { throw NestError("Original holding-directory identity changed.", code: 4) } }
            for name in j.evacuatedEntries where try original.exists(name) {
                try original.renameNoReplace(name, to: selectedHandle, as: name)
            }
            try original.sync(); try selectedHandle.sync()
        }
        guard try Snapshot.manifest(URL(fileURLWithPath: f.path), matching: expected).matchesExpected(expected) else { throw NestError("Rollback found changed original files. Manual recovery required.", code: 6) }
        try Store.syncDirectory(URL(fileURLWithPath: f.path))
        j.restoreRevision = revision
        j.phase = .idle; j.socket = nil; j.mountedDevice = nil; j.lastError = nil; try store.write(j, for: f.id)
        cleanSnapshots(f, &j)
    }
    @discardableResult private func exportRAM(_ f: Folder, _ committed: inout Journal, quiesce: Bool) throws -> String {
        var j = committed
        guard let socket = j.socket else { throw NestError("No helper session.", code: 2) }
        let stage = try store.volume(f.id).appendingPathComponent("stage-\(UUID().uuidString)")
        let capabilities = (try? session.request(socket, "capabilities")) ?? []
        let supportsIncremental = capabilities.contains("incremental-v1")
        let privateStorage = capabilities.contains("private-storage-v2")
        let exclusionAware = capabilities.contains("trash-directory-exclusion-v1")
        guard privateStorage || !capabilities.contains(where:{ $0.hasPrefix("private-storage-v") }) else { throw NestError("Unsupported helper private storage version; no checkpoint authority changed.", code: 6) }
        guard !privateStorage || supportsIncremental else { throw NestError("Inconsistent helper storage capabilities; no checkpoint authority changed.", code: 6) }
        var previous: URL?
        if privateStorage, exclusionAware, supportsIncremental, let revision = j.revision, j.nativeGeneration != nil {
            let candidate = try Snapshot.dataURL(store:store,id:f.id,revision:revision)
            let format = try Snapshot.storedMetadata(candidate)?.storageFormat
            // Old helpers always perform an ordinary full export. Do not even
            // read incompatible prior payloads: a damaged/restrictive old prior
            // must not prevent a fresh verified capture of authoritative RAM.
            // New helpers authenticate a compatible prior before reuse; unknown
            // discriminators fail above. Old helpers never receive/read a prior.
            if format == 2 {
                previous = try Snapshot.verified(store:store,id:f.id,revision:revision).0
            }
        }
        let verb = quiesce ? (privateStorage ? "quiesce3" : supportsIncremental ? "quiesce2" : "quiesce") : (privateStorage ? "export3" : supportsIncremental ? "export2" : "export")
        let prior = previous.map { "\t\($0.path)\t\(j.nativeGeneration!)" } ?? ""
        let response = try session.request(socket, "\(verb)\t\(stage.path)\(prior)")
        if privateStorage {
            guard response.count == 6, response[5].utf8.count == 64,
                  response[5].utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else { throw NestError("Invalid native original logical-mode receipt; stage retained.", code: 6) }
        }
        if supportsIncremental {
            guard response.count >= 2, UInt64(response[0]) != nil, ["exported", "reused"].contains(response[1]) else { throw NestError("Invalid native checkpoint receipt.", code: 6) }
            if response[1] == "reused" {
                guard let revision = j.revision, previous != nil,
                      let previousGeneration = j.nativeGeneration.flatMap(UInt64.init),
                      let generation = UInt64(response[0]), generation >= previousGeneration else { throw NestError("Invalid no-op checkpoint receipt.", code: 6) }
                if privateStorage {
                    // Full old metadata/map integrity was checked before reuse.
                    // The native receipt binds its included view, while an old
                    // committed full map remains immutable on disk.
                    let (_,priorView) = try Snapshot.verified(store:store,id:f.id,revision:revision)
                    guard try Snapshot.digest(StorageModes(priorView).encoded) == response[5] else { throw NestError("Native no-op original logical-mode receipt mismatch.", code: 6) }
                }
                j.nativeGeneration = response[0]
                if quiesce {
                    j.quiescedRevision = revision
                    try recordQuiesceIdentity(f, journal: &j, response: response)
                }
                try store.write(j, for: f.id); committed = j; return revision
            }
        }
        let revision = try Snapshot.adoptExport(store: store, folder: f, stage: stage, privateStorage:privateStorage,modeMapDigest:privateStorage ? response[5] : nil)
        j.nativeGeneration = supportsIncremental ? response[0] : nil
        j.quiescedRevision = quiesce ? revision : nil
        if quiesce { try recordQuiesceIdentity(f, journal: &j, response: supportsIncremental ? response : []) }
        else { j.quiescedSession = nil; j.quiescedHelperPID = nil; j.quiescedNativeInstance = nil }
        SnapshotRetention.remember(&j)
        j.priorRevision = j.revision; j.revision = revision
        try store.write(j, for: f.id); committed = j; return revision
    }
    private func recordQuiesceIdentity(_ f: Folder, journal j: inout Journal, response: [String]) throws {
        j.quiescedSession = j.session
        j.quiescedHelperPID = try session.status(j, f.id).pid
        j.quiescedNativeInstance = response.count >= 5 && UUID(uuidString: response[4]) != nil ? response[4] : nil
    }
    private func validQuiesceReceipt(_ j: Journal, live: HelperStatus) throws -> Bool {
        guard j.phase == .ejecting, j.quiescedRevision != nil, j.quiescedRevision == j.revision,
              j.quiescedSession == j.session, j.quiescedHelperPID == live.pid else { return false }
        if let instance = j.quiescedNativeInstance {
            guard let socket = j.socket else { return false }
            let current = try session.request(socket, "checkpoint-status")
            return current.count == 3 && current[0] == instance && current[1] == j.nativeGeneration && current[2] == "frozen"
        }
        // Legacy helpers have only PID/session identity; no new protocol fields
        // are required of them. New helpers always supply the incarnation UUID.
        return j.nativeGeneration == nil
    }
    public func save(_ ref: String) throws {
        _ = try volumeTransaction(ref) { f in
            var j = try store.journal(f.id)
            guard j.phase == .mounted else { throw NestError("A volume transaction is pending.", code: 6) }
            _ = try requireLive(f, j)
            guard f.options.sync else { throw NestError("Temporary mode preserves the initial folder. Explicit export can rescue current RAM data.", code: 64) }
            do { _ = try exportRAM(f, &j, quiesce: false); j.lastError = nil; try store.write(j, for: f.id) }
            catch { j.lastError = error.localizedDescription; try store.write(j, for: f.id); throw error }
            cleanSnapshots(f, &j)
            return f
        }
    }
    public func busyProcesses(_ ref: String) throws -> String {
        let f = try folder(ref)
        // lsof may return 1 for an empty set. It never terminates anything.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); p.arguments = ["-n", "-P", "+f", "--", f.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    // A crash after this durable write can only cause another verified export.
    // If publication/sync fails we deliberately leave the helper frozen.
    private func invalidateBeforeThaw(_ f: Folder, journal j: inout Journal, failure: Error) throws {
        j.quiescedRevision = nil; j.quiescedSession = nil; j.quiescedHelperPID = nil; j.quiescedNativeInstance = nil; j.phase = .mounted; j.lastError = failure.localizedDescription
        try store.write(j, for: f.id)
        if let socket = j.socket { _ = try session.request(socket, "thaw") }
    }
    public func unmount(_ ref: String, ignoreBusy: Bool = false) throws {
        let bound = try folder(ref)
        if !ignoreBusy { let busy = try busyProcesses(bound.id.uuidString); if !busy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw NestError("Processes are using the volume. Close them or choose Ignore explicitly:\n\(busy)", code: 7) } }
        let f = try volumeTransaction(bound.id.uuidString) { f in
            var j = try store.journal(f.id)
            if j.phase == .idle { return f }
            _ = try requireLive(f, j)
            guard j.phase == .mounted || j.phase == .recoveryRequired else { throw NestError("Volume has an operation pending; recover first.", code: 6) }
            do {
                if f.options.sync { _ = try exportRAM(f, &j, quiesce: true); j.restoreRevision = j.revision }
                else { _ = try session.request(j.socket!, "freeze"); j.restoreRevision = j.initialRevision }
                j.phase = .ejecting; try store.write(j, for: f.id)
            } catch {
                try invalidateBeforeThaw(f, journal: &j, failure: error)
                throw error
            }
            return f
        }
        let j = try store.journal(f.id)
        if j.phase == .idle { return }
        do { try session.unmount(f.path) }
        catch {
            try volumeTransaction(f.id.uuidString) { currentFolder in
                var current = try store.journal(currentFolder.id)
                try invalidateBeforeThaw(currentFolder, journal: &current, failure: error)
            }
            throw error
        }
        // The helper also calls finalize after external eject. Both serialize on repository.lock.
        for _ in 0..<100 {
            let current = try store.journal(f.id)
            if current.phase == .idle { return }
            if (try? session.status(current, f.id).mounted) == false { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try finalize(f.id.uuidString)
    }
    public func finalize(_ ref: String) throws {
        try volumeTransaction(ref) { f in
            var j = try store.journal(f.id)
            if j.phase == .idle { if let socket = j.socket { _ = try? session.request(socket, "retire") }; cleanSnapshots(f, &j); return }
            guard !Paths.mounts().contains(where: { $0.path == f.path }) else { throw NestError("Volume still mounted; restore is blocked.", code: 6) }
            do {
                if !j.populationVerified {
                    if j.startupProtocol != nil, j.startupRetired != true {
                        guard j.startupProtocol == GuardedPopulationStartup.version else { throw NestError("Unknown guarded startup journal; originals retained.", code: 6) }
                        try retireGuardedStartup(j, id: f.id, expectedPID: j.startupHelperPID)
                        j.startupRetired = true; try store.write(j, for: f.id)
                    }
                    try rollbackInitial(f, journal: &j)
                } else {
                    if j.phase != .pendingRestore && j.phase != .restoring {
                        if f.options.sync {
                            let live = try session.status(j, f.id)
                            guard !live.mounted else { throw NestError("Helper still considers the volume mounted.", code: 6) }
                            if try !validQuiesceReceipt(j, live: live) {
                                _ = try exportRAM(f, &j, quiesce: true)
                            } else if let revision = j.quiescedRevision {
                                _ = try Snapshot.verified(store: store, id: f.id, revision: revision)
                            }
                            j.restoreRevision = j.revision
                        } else { j.restoreRevision = j.initialRevision }
                        j.phase = .pendingRestore; try store.write(j, for: f.id)
                    }
                    if f.options.sync { try restore(f, journal: &j) } else { try rollbackInitial(f, journal: &j) }
                }
                if let socket = j.socket { _ = try? session.request(socket, "retire") }
                j.socket = nil; try store.write(j, for: f.id)
            } catch { j.lastError = error.localizedDescription; try store.write(j, for: f.id); throw error }
            cleanSnapshots(f, &j)
        }
    }
    private func restore(_ f: Folder, journal j: inout Journal) throws {
        try Paths.checkedIdentity(f)
        guard let revision = j.restoreRevision ?? j.revision else { throw NestError("No committed snapshot. Export originals instead.", code: 6) }
        let (source, authenticated) = try Snapshot.verified(store: store, id: f.id, revision: revision)
        let expected = try Snapshot.materializationManifest(source,expected:authenticated,context:.managedRevision)
        if expected.publicRoot.map({ $0.mode & 0o500 != 0o500 }) == true || expected.entries.contains(where:{
            if $0.kind == "directory" { return $0.mode & 0o500 != 0o500 || (!$0.path.contains("/") && $0.mode & 0o200 == 0) }
            return ($0.kind == "file" || $0.kind == "symlink") && $0.mode & 0o400 == 0
        }) {
            try restoreRestrictive(f,journal:&j,source:source,expected:expected);return
        }
        let selected = URL(fileURLWithPath: f.path)
        let actual = try Snapshot.manifest(selected, matching: expected)
        let topNames = expected.entries.filter { !$0.path.contains("/") }.map(\.path)
        // The complete selected subset must match, including hardlink classes.
        // A rename may be durable even if its following journal checkpoint was not.
        let present = Set(actual.entries.filter { !$0.path.contains("/") }.map(\.path))
        guard actual.contentsMatchExpected(expected.selecting(topNames: present)) else {
            throw NestError("Recovery conflict in already restored entries. Snapshot retained.", code: 6)
        }
        if !present.isEmpty && j.phase != .restoring { throw NestError("Mountpoint gained new entries. Export snapshot; automatic restore is blocked.", code: 6) }
        if j.restoreStage == nil {
            let stage = selected.deletingLastPathComponent().appendingPathComponent(".ramnest-\(f.id.uuidString)-restore-\(UUID().uuidString)")
            let parent = try DirectoryHandle.open(stage.deletingLastPathComponent())
            let stageHandle = try parent.createDirectory(stage.lastPathComponent)
            let identity = try stageHandle.identity()
            j.restoreStageDevice = identity.device; j.restoreStageInode = identity.inode
            try Snapshot.copyTree(from: source, to: stage.appendingPathComponent("data"), manifest: expected, publicationStaging:true,sourceContext:.managedRevision)
            let dataIdentity = try stageHandle.child("data").identity()
            j.restoreDataDevice = dataIdentity.device; j.restoreDataInode = dataIdentity.inode
            // Publish a restore source only after its full copy is verified.
            // An interrupted copy must never be resumed as trusted staging.
            j.restoreStage = stage.path; j.phase = .restoring
            try store.write(j, for: f.id)
        }
        guard let stagePath = j.restoreStage else { throw NestError("Missing restore staging path.", code: 6) }
        let stagingRoot = try DirectoryHandle.open(URL(fileURLWithPath: stagePath))
        let stageIdentity = try stagingRoot.identity()
        guard stageIdentity.device == j.restoreStageDevice, stageIdentity.inode == j.restoreStageInode else { throw NestError("Restore staging-directory identity changed. Snapshot retained.", code: 4) }
        let stagingData = try stagingRoot.child("data")
        let dataIdentity = try stagingData.identity()
        guard dataIdentity.device == j.restoreDataDevice, dataIdentity.inode == j.restoreDataInode else {
            throw NestError("Restore data-directory identity changed. Snapshot retained.", code: 4)
        }
        // A public read-only root remains read-only in the verified copy. Only
        // this identity-pinned private staging directory needs owner wx while
        // entries move out. Publish the marker before changing its mode so a
        // crash can restore the exact mode before the normal integrity check.
        let permissionMarker = ".root-move-permissions"
        let originalStageMode = expected.publicRoot.map { mode_t($0.mode) }
        func resetStagePermissions() throws {
            guard try stagingRoot.exists(permissionMarker) else { return }
            let marker = try stagingRoot.child(permissionMarker)
            try marker.requireOwnedDirectory(device: stageIdentity.device, privateMode: true)
            var st = stat()
            guard let mode = originalStageMode, mode | 0o300 != mode,
                  try marker.names().isEmpty, fstat(stagingData.fd, &st) == 0, st.st_uid == getuid(),
                  st.st_mode & 0o7777 == mode || st.st_mode & 0o7777 == mode | 0o300 else {
                throw NestError("Unexpected restore staging permissions. Snapshot retained.", code: 6)
            }
            guard fchmod(stagingData.fd, mode) == 0 else { throw NestError("Cannot restore staging root mode.", code: 6) }
            try stagingData.sync()
        }
        try resetStagePermissions()
        let remaining = expected.selecting(topNames: Set(topNames).subtracting(present))
        let staged = try Snapshot.manifest(URL(fileURLWithPath: stagePath).appendingPathComponent("data"), matching: remaining)
        guard staged.matchesExpected(remaining) else {
            throw NestError("Restore staging contents changed; no remaining entries moved. Snapshot retained.", code: 6)
        }
        let selectedHandle = try DirectoryHandle.open(selected); try selectedHandle.verify(f)
        // Check inode equivalence across the selected/staged boundary too.
        // Separate subset manifests alone cannot detect a split cross-boundary link.
        let selectedCursor = DirectoryCursor(selectedHandle), stagedCursor = DirectoryCursor(stagingData)
        var groups: [String: String] = [:], identities: [String: String] = [:]
        for entry in expected.entries where entry.kind == "file" {
            let top = String(entry.path.split(separator: "/")[0])
            let (parent, leaf) = try (present.contains(top) ? selectedCursor : stagedCursor).parent(of: entry.path)
            let st = try parent.entryStat(leaf)
            let identity = "\(st.st_dev):\(st.st_ino)", group = entry.hardlink ?? entry.path
            if let prior = groups[group], prior != identity { throw NestError("Restore hardlink class split; remaining entries retained.", code: 6) }
            if let prior = identities[identity], prior != group { throw NestError("Restore hardlink classes merged; remaining entries retained.", code: 6) }
            groups[group] = identity; identities[identity] = group
        }
        if let mode = originalStageMode, mode | 0o300 != mode, !Set(topNames).isSubset(of: present) {
            if try !stagingRoot.exists(permissionMarker) { _ = try stagingRoot.createDirectory(permissionMarker) }
            try stagingRoot.sync()
            guard fchmod(stagingData.fd, mode | 0o300) == 0 else { throw NestError("Cannot prepare private restore staging root.", code: 6) }
            try stagingData.sync()
        }
        do {
            for name in topNames where !present.contains(name) {
                try Paths.checkedIdentity(f)
                try stagingData.renameNoReplace(name, to: selectedHandle, as: name)
                try stagingData.sync(); try selectedHandle.sync()
                j.restoredEntries.append(name); try store.write(j, for: f.id)
            }
        } catch {
            try resetStagePermissions()
            throw error
        }
        try resetStagePermissions()
        if try stagingRoot.exists(permissionMarker) {
            guard unlinkat(stagingRoot.fd, permissionMarker, AT_REMOVEDIR) == 0 else { throw NestError("Cannot finish restore staging permissions.", code: 6) }
            try stagingRoot.sync()
        }
        try Snapshot.restorePublicRootMetadata(from: stagingData, to: selectedHandle, manifest: expected)
        guard try Snapshot.manifest(selected, matching: expected).matchesExpected(expected) else { throw NestError("Restored content verification failed. Snapshot retained.", code: 6) }
        try Paths.checkedIdentity(f)
        try Store.syncDirectory(selected)
        j.phase = .idle; j.mountedDevice = nil; j.lastError = nil; try store.write(j, for: f.id)
    }
    // Restrictive publication is a phase-specific handoff: full readback while
    // private, pinned no-follow final modes, durable receipt, no-replace moves.
    // A crash after finalization is retained and fails closed if independent
    // readback is now impossible. No chmod of published content is authorized.
    private func restoreRestrictive(_ f: Folder, journal j: inout Journal, source: URL, expected: Manifest) throws {
        let selected = URL(fileURLWithPath:f.path)
        let selectedHandle = try DirectoryHandle.open(selected);try selectedHandle.verify(f)
        let actual: Manifest
        do { actual = try Snapshot.manifest(selected,matching:expected) }
        catch { throw NestError("Restrictive restore recovery cannot independently verify published content; snapshot and publication evidence retained. " + error.localizedDescription, code: 6) }
        let topNames = expected.entries.filter { !$0.path.contains("/") }.map(\.path)
        let present = Set(actual.entries.filter { !$0.path.contains("/") }.map(\.path))
        guard actual.contentsMatchExpected(expected.selecting(topNames:present)), present.isEmpty || j.phase == .restoring else { throw NestError("Restrictive restore conflicts with public content; retained.", code: 6) }
        if j.restoreStage == nil {
            let stage = selected.deletingLastPathComponent().appendingPathComponent(".ramnest-\(f.id.uuidString)-restore-\(UUID().uuidString)")
            let parent = try DirectoryHandle.open(stage.deletingLastPathComponent()), root = try parent.createDirectory(stage.lastPathComponent)
            let identity = try root.identity()
            try Snapshot.copyTree(from:source,to:stage.appendingPathComponent("data"),manifest:expected,privateStorage:true,sourceContext:.managedRevision)
            let dataIdentity = try root.child("data").identity()
            j.restoreStage = stage.path;j.restoreStageDevice = identity.device;j.restoreStageInode = identity.inode
            j.restoreDataDevice = dataIdentity.device;j.restoreDataInode = dataIdentity.inode
            j.publicationReceipt = PublicationReceipt(manifest:expected,destination:selected.lastPathComponent,phase:"verified-accessible")
            j.phase = .restoring;try store.write(j,for:f.id)
        }
        let stage = URL(fileURLWithPath:j.restoreStage!), root = try DirectoryHandle.open(stage)
        let rootIdentity = try root.identity()
        guard rootIdentity.device == j.restoreStageDevice, rootIdentity.inode == j.restoreStageInode else { throw NestError("Restrictive restore stage identity changed.", code: 6) }
        let data = try root.child("data")
        let dataIdentity = try data.identity()
        guard dataIdentity.device == j.restoreDataDevice, dataIdentity.inode == j.restoreDataInode, try root.names() == ["data"] else { throw NestError("Restrictive restore data identity/namespace changed.", code: 6) }
        let remaining = expected.selecting(topNames:Set(topNames).subtracting(present))
        let staged: Manifest
        do { staged = try StorageModes(remaining).projecting(Snapshot.scanManifest(stage.appendingPathComponent("data"),matching:remaining,phase:"restore-accessible-readback")) }
        catch { throw NestError("Interrupted restrictive publication cannot be independently verified; stage, data, receipts and committed snapshot retained. " + error.localizedDescription, code: 6) }
        guard staged.matchesExpected(remaining) else { throw NestError("Restrictive restore staging integrity mismatch.", code: 6) }
        // Preserve the full inode partition across an earlier public/private
        // boundary. Never finalize a private alias of an already-public inode.
        let publicCursor = DirectoryCursor(selectedHandle), privateCursor = DirectoryCursor(data)
        var groups: [String:String] = [:], identities: [String:String] = [:]
        var publicIdentities = Set<String>(), privateIdentities = Set<String>()
        for e in expected.entries where e.kind == "file" {
            let isPublic = present.contains(String(e.path.split(separator:"/")[0]))
            let (parent,name) = try (isPublic ? publicCursor : privateCursor).parent(of:e.path), st = try parent.entryStat(name)
            let identity = "\(st.st_dev):\(st.st_ino)", group = e.hardlink ?? e.path
            guard groups[group] == nil || groups[group] == identity, identities[identity] == nil || identities[identity] == group else { throw NestError("Restrictive restore hardlink partition changed.", code: 6) }
            groups[group] = identity;identities[identity] = group
            if isPublic { publicIdentities.insert(identity) } else { privateIdentities.insert(identity) }
        }
        guard publicIdentities.isDisjoint(with:privateIdentities) else { throw NestError("Cannot finalize a cross-boundary public hardlink; retained.", code: 6) }
        let expectedReceipt = PublicationReceipt(manifest:expected,destination:selected.lastPathComponent,phase:"verified-accessible")
        guard let receipt = j.publicationReceipt, receipt.version == 1, receipt.manifestDigest == expectedReceipt.manifestDigest,
              receipt.destination == expectedReceipt.destination else { throw NestError("Missing or unauthenticated restrictive publication receipt; retained.", code: 6) }
        let names = Dictionary(uniqueKeysWithValues:topNames.filter{!present.contains($0)}.map{($0,".ramnest-publish-"+UUID().uuidString)})
        j.publicationReceipt?.phase = "finalizing";j.publicationReceipt?.privateNames = names;try store.write(j,for:f.id)
        // Darwin cannot move a 0000/read-only directory across parents. Move
        // only the verified, still-0700/0600 private objects to random temporary
        // names first. Exact modes precede the final SAME-parent publication.
        var transferred: [String:(device:UInt64,inode:UInt64)] = [:]
        for e in remaining.entries {
            let (parent,name) = try privateCursor.parent(of:e.path), st = try parent.entryStat(name)
            transferred[e.path] = (Paths.deviceID(st.st_dev),UInt64(st.st_ino))
        }
        for name in topNames where !present.contains(name) {
            try Paths.checkedIdentity(f)
            try data.renameNoReplace(name,to:selectedHandle,as:names[name]!)
            try data.sync();try selectedHandle.sync()
        }
        func shadowPath(_ path: String) -> String {
            let parts = path.split(separator:"/",maxSplits:1).map(String.init)
            guard let first = parts.first, let name = names[first] else { return path }
            return name + (parts.count == 2 ? "/"+parts[1] : "")
        }
        var shadow = remaining
        for i in shadow.entries.indices { shadow.entries[i].path = shadowPath(shadow.entries[i].path);shadow.entries[i].hardlink = shadow.entries[i].hardlink.map(shadowPath) }
        var finalized = try Snapshot.finalizeModes(selected,manifest:shadow,destination:selected.lastPathComponent,finalizeRoot:false)
        let originals = Dictionary(uniqueKeysWithValues:remaining.entries.map{(shadowPath($0.path),$0.path)})
        for i in finalized.identities.indices {
            guard let path = originals[finalized.identities[i].path], let before = transferred[path],
                  before.device == finalized.identities[i].device, before.inode == finalized.identities[i].inode else { throw NestError("Publication transfer identity changed; all evidence retained.", code: 6) }
            finalized.identities[i].path = path
        }
        finalized.privateNames = names
        // Bind even a selected subset to the complete authoritative revision.
        finalized.manifestDigest = expectedReceipt.manifestDigest
        j.publicationReceipt = finalized;try store.write(j,for:f.id)
        for name in topNames where !present.contains(name) {
            try Paths.checkedIdentity(f)
            try selectedHandle.renameNoReplace(names[name]!,to:selectedHandle,as:name)
            try data.sync();try selectedHandle.sync()
            j.restoredEntries.append(name);try store.write(j,for:f.id)
        }
        try Paths.checkedIdentity(f)
        try Snapshot.preparePublicRoot(from:data,to:selectedHandle,selected:selected,manifest:expected)
        guard let logical = expected.publicRoot?.mode, fchmod(selectedHandle.fd,mode_t(logical)) == 0 else { throw NestError("Cannot finalize selected root permissions.", code: 6) }
        var finalRoot = stat()
        guard fstat(selectedHandle.fd,&finalRoot) == 0, finalRoot.st_mode & 0o7777 == logical else { throw NestError("Selected root final-mode verification failed.", code: 6) }
        try selectedHandle.sync()
        try Paths.checkedIdentity(f)
        j.publicationReceipt?.phase = "published";j.phase = .idle;j.mountedDevice = nil;j.lastError = nil
        try store.write(j,for:f.id)
    }
    public func recover(_ ref: String) throws {
        let f = try folder(ref)
        let j = try store.locked { try store.journal(f.id) }
        if let live = try? session.status(j, f.id) {
            if live.mounted { throw NestError("Helper is alive. Use save/eject; recovery does not overwrite a live volume.", code: 6) }
            try finalize(f.id.uuidString); return
        }
        try volumeTransaction(f.id.uuidString) { f in
            var j = try store.journal(f.id)
            guard !Paths.mounts().contains(where: { $0.path == f.path }) else { throw NestError("An orphaned mount still exists. Unmount it on the host before recovery.", code: 6) }
            if j.phase == .idle { cleanSnapshots(f, &j); return }
            if !j.populationVerified || !f.options.sync { try rollbackInitial(f, journal: &j) }
            else {
                SnapshotRetention.remember(&j)
                j.restoreRevision = f.options.sync ? j.revision : j.initialRevision
                if j.phase != .restoring { j.phase = .pendingRestore }
                try store.write(j, for: f.id); try restore(f, journal: &j)
            }
            j.socket = nil; try store.write(j, for: f.id)
            cleanSnapshots(f, &j)
        }
    }
    public func export(_ ref: String, destination: URL, revision: String? = nil, live: Bool = false) throws {
        try volumeTransaction(ref) { f in
            var j = try store.journal(f.id)
            let selected: String
            if live { _ = try session.status(j, f.id); selected = try exportRAM(f, &j, quiesce: false) }
            else if let candidate = revision ?? j.revision { selected = candidate }
            else { throw NestError("No snapshot exists yet.", code: 6) }
            let (data, manifest) = try Snapshot.verified(store: store, id: f.id, revision: selected)
            try Paths.rejectSymlinks(destination.deletingLastPathComponent().path)
            try Snapshot.copyTree(from: data, to: destination, manifest: manifest,sourceContext:.managedRevision)
            cleanSnapshots(f, &j)
        }
    }
    public func resize(_ ref: String, capacity: UInt64) throws {
        try SizeParser.validate(capacity)
        try volumeTransaction(ref) { current in
            var f = current; let j = try store.journal(f.id)
            if let live = try? session.status(j, f.id) {
                guard live.mounted, mountedIdentity(f, j), live.used <= capacity else { throw NestError("Cannot shrink below allocated usage or resize an uncertain session.", code: 6) }
                _ = try session.request(j.socket!, "resize\t\(capacity)")
            } else {
                guard j.phase == .idle else { throw NestError("Recover the session before resizing.", code: 6) }
                guard try Snapshot.manifest(URL(fileURLWithPath: f.path)).allocatedEstimate <= capacity else { throw NestError("Cannot shrink below folder contents.", code: 6) }
            }
            f.capacity = capacity
            try store.locked {
                var latest = try store.load()
                guard let i = latest.folders.firstIndex(where: { $0.id == f.id }) else { throw NestError("Folder was removed.", code: 6) }
                latest.folders[i].capacity = f.capacity; try store.save(latest)
            }
        }
    }
    public func delete(_ ref: String, destroy: Bool = false, confirmed: Bool = false) throws {
        guard !destroy || confirmed else { throw NestError("Destructive deletion requires --destroy --confirm-delete.", code: 64) }
        let f = try folder(ref)
        let j = try store.locked { try store.journal(f.id) }
        if j.phase != .idle { try unmount(f.id.uuidString) }
        try volumeTransaction(f.id.uuidString) { f in
            let c = try store.load(); let j = try store.journal(f.id)
            guard j.phase == .idle else { throw NestError("Recovery must finish before deleting configuration.", code: 6) }
            try Paths.checkedIdentity(f)
            if destroy {
                _ = try Paths.validate(URL(fileURLWithPath: f.path), store: store, folders: c.folders, excluding: f.id)
                // Explicitly authorized path, refreshed identity, snapshots still retained.
                try FileManager.default.removeItem(at: URL(fileURLWithPath: f.path))
            }
            try store.locked { var latest = try store.load(); latest.folders.removeAll { $0.id == f.id }; try store.save(latest) }
        }
    }
}
