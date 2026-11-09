import Foundation
import AppKit
import RAMNestCore

/// All Engine and Store access in this process is serialized here. Storage
/// copies alone run on a detached worker; while one owns the store, only cached
/// job status, capabilities and cancellation are admitted by this actor.
public actor Activities {
    public let location: StoreLocation
    private let manager: SnapshotStorageManager
    private let bridge: PackagedBridge
    private var engine: Engine?
    private var reviews: [UUID: (LegacyPublicationReview, Date)] = [:]
    private var worker: Task<Void, Never>?
    private var cancellation: StorageMoveCancellation?
    private var job: [String: JSON] = ["running": .bool(false)]
    private var closing = false

    public init(bootstrap: URL = Store.defaultRoot, app: URL? = nil) {
        location = StoreLocation(bootstrapRoot: bootstrap)
        manager = SnapshotStorageManager(location: location)
        bridge = PackagedBridge(app: app)
    }
    // Internal owned-fixture injection. No command-line, environment or RPC can
    // override production Engine/session authority through this initializer.
    init(manager: SnapshotStorageManager, engine: Engine? = nil) {
        self.location = manager.location; self.manager = manager
        self.engine = engine; self.bridge = PackagedBridge()
    }
    private func core() throws -> Engine {
        if let engine { return engine }
        let store = try manager.open()
        // Periodic scheduling also records the CLI path. Never let Core infer
        // that this stdio executable is the native worker CLI.
        let value = Engine(store: store, helper: bridge.app?.appendingPathComponent("Contents/Helpers/ramnest-helper"),
                           cli: bridge.app?.appendingPathComponent("Contents/Helpers/ramnest"))
        engine = value; return value
    }
    private func ok(_ values: [String: JSON] = [:]) -> JSON { .object(values.merging(["ok": .bool(true)]) { a, _ in a }) }
    private func invalidateReviews() {
        if let engine { for (review, _) in reviews.values { engine.cancelLegacyPublicationReview(review) } }
        reviews.removeAll()
    }
    private func expireReviews() {
        for (token, (review, date)) in reviews where Date().timeIntervalSince(date) > 600 {
            engine?.cancelLegacyPublicationReview(review); reviews.removeValue(forKey: token)
        }
    }
    public func call(_ name: String, arguments a: [String: JSON] = [:]) async throws -> JSON {
        try ToolCatalog.definition(name).validate(a)
        guard !closing else { throw MCPFailure("closing", "MCP session is shutting down.") }
        expireReviews()
        if worker != nil && !["capabilities", "storage_status", "storage_pause"].contains(name) {
            throw MCPFailure("busy", "A storage worker owns the repository. Poll storage_status or request storage_pause.")
        }
        func string(_ key: String) -> String { if case .string(let s) = a[key] { s } else { "" } }
        func bool(_ key: String, _ fallback: Bool = false) -> Bool { if case .bool(let b) = a[key] { b } else { fallback } }
        func capacity() -> UInt64 { if case .integer(let n) = a["capacityBytes"] { UInt64(n) } else { 0 } }
        func ref() -> String { UUID(uuidString: string("id"))!.uuidString }
        func path(_ key: String) -> URL { URL(fileURLWithPath: string(key)) }

        switch name {
        case "capabilities":
            let package: JSON
            do { package = .object(["available": .bool(true), "app": .string(try bridge.requirePackage().path), "compiledCLIIdentity": try bridge.identity(), "verification": .string("sealed package/static prerequisites only; native authorization and lifecycle are checked by the packaged CLI per operation")]) }
            catch { package = .object(["available": .bool(false), "reason": .string(error.localizedDescription)]) }
            return .object(["platform": .string("macOS"), "backend": .string("tmpfs"), "package": package,
                "loginItem": .string("app-owned bridge; requires package; reports actual SMAppService status"),
                "unsupported": .array(["backend selection", "app compression", "FSEvents suppression", "live resize", "native reviewed-publication recovery (use RAMNest app)"].map(JSON.string)),
                "startupMounts": .bool(false), "exitUnmounts": .bool(false), "storageBootstrap": .string(location.bootstrapRoot.path)])
        case "folder_list": return try JSON.encode(core().statuses())
        case "folder_info":
            let e = try core(), f = try e.folder(ref())
            guard let s = try e.statuses().first(where: { $0.id == f.id }) else { throw MCPFailure("missing", "Folder disappeared.") }
            return try JSON.encode(s)
        case "folder_create":
            if bool("mount") { _ = try bridge.requirePackage() }
            let e = try core()
            let options = try editedOptions(.init(), patch: a["options"])
            let f = try e.create(path: path("path"), name: a["name"] == nil ? nil : string("name"), capacity: capacity(), options: options)
            invalidateReviews()
            if bool("mount") {
                do { _ = try bridge.cli(["mount", f.id.uuidString], root: e.store.root) }
                catch { throw MCPFailure("create_mount_failed", "Registered folder \(f.id.uuidString), but mounting failed: \(error.localizedDescription). Inspect folder_info before retrying.") }
            }
            return try JSON.encode(f)
        case "folder_mount", "folder_reconnect", "folder_save", "folder_unmount":
            let e = try core(), f = try e.folder(ref())
            if name == "folder_unmount", try e.store.journal(f.id).phase == .idle { return ok(["alreadyIdle": .bool(true)]) }
            var args = [String(name.dropFirst("folder_".count)), f.id.uuidString]
            if bool("ignoreBusy") { args.append("--ignore-busy") }
            invalidateReviews()
            return try bridge.cli(args, root: e.store.root)
        case "folder_resize":
            let e = try core(); try e.resize(ref(), capacity: capacity()); invalidateReviews()
            return try JSON.encode(e.folder(ref()))
        case "folder_rename", "folder_options":
            let e = try core(); var f = try e.folder(ref())
            if try e.store.journal(f.id).phase != .idle { _ = try bridge.requirePackage() }
            if name == "folder_rename" { f.name = string("name") }
            else {
                guard case .object(let patch) = a["options"], !patch.isEmpty else { throw MCPFailure("invalid_arguments", "options must contain at least one setting.") }
                f.options = try editedOptions(f.options, patch: a["options"])
            }
            try e.update(f); invalidateReviews(); return try JSON.encode(e.folder(ref()))
        case "folder_delete":
            let destroy = bool("destroy"), id = ref()
            guard !destroy || string("confirmation") == "DELETE " + id else { throw MCPFailure("confirmation_required", "Destructive delete requires confirmation='DELETE \(id)'.") }
            guard destroy || a["confirmation"] == nil else { throw MCPFailure("invalid_arguments", "confirmation is only accepted with destroy=true.") }
            let e = try core(), f = try e.folder(id), j = try e.store.journal(f.id)
            invalidateReviews()
            if j.phase != .idle {
                var args = ["delete", id]
                args += destroy ? ["--destroy", "--confirm-delete"] : ["--keep"]
                return try bridge.cli(args, root: e.store.root)
            }
            try e.delete(id, destroy: destroy, confirmed: destroy)
            return ok(["originalsKept": .bool(!destroy), "snapshotsRetained": .bool(true)])
        case "folder_recover":
            let e = try core(), f = try e.folder(ref()), j = try e.store.journal(f.id)
            guard j.phase != .idle else { throw MCPFailure("invalid_state", "Folder is idle; no recovery is pending.") }
            invalidateReviews()
            if j.nativeTmpfs != nil { return try bridge.cli(["recover", f.id.uuidString], root: e.store.root) }
            try e.recover(f.id.uuidString); return ok(["source": .string("committed checkpoint or intact originals; no lost RAM rescue")])
        case "folder_export":
            guard !bool("live") || a["revision"] == nil else { throw MCPFailure("invalid_arguments", "live and revision are mutually exclusive.") }
            let e = try core(), f = try e.folder(ref())
            if bool("live") { return try bridge.cli(["export", f.id.uuidString, string("destination"), "--live"], root: e.store.root) }
            try e.export(f.id.uuidString, destination: path("destination"), revision: a["revision"] == nil ? nil : UUID(uuidString: string("revision"))!.uuidString)
            return ok(["source": .string("committed disk checkpoint"), "destination": a["destination"]!])
        case "folder_busy": return .object(["processes": .string(try core().busyProcesses(ref()))])
        case "folder_open", "folder_reveal":
            let folder = try core().folder(ref()), reveal = name == "folder_reveal"
            let accepted = await MainActor.run {
                if reveal { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) }
                else { NSWorkspace.shared.open(URL(fileURLWithPath: folder.path)) }
            }
            guard accepted else { throw MCPFailure("desktop_unavailable", "macOS did not accept the Finder request; a logged-in desktop may be required.") }
            return ok(["desktopRequestAccepted": .bool(true), "path": .string(folder.path), "verification": .string("OS request accepted; Finder window visibility is not observed")])
        case "recovery_review":
            guard reviews.count < 32 else { throw MCPFailure("review_bound", "Cancel outstanding reviews before starting another (maximum 32).") }
            let e = try core(), folder = try e.folder(ref())
            try Self.requireSupportedReview(e.store.journal(folder.id))
            let review = try e.reviewLegacyPublication(ref())
            reviews[review.token] = (review, Date())
            return .object(["token": .string(review.token.uuidString), "expiresInSeconds": .integer(600),
                "folderPath": .string(review.folderPath), "revision": .string(review.revision), "initialRevision": .string(review.initialRevision),
                "retainedOriginalPath": .string(review.retainedOriginalPath), "retainedLinkPath": .string(review.retainedLinkPath), "snapshotPath": .string(review.snapshotPath),
                "disclosure": .string("Historic rename proof is missing. Acceptance acknowledges that gap, updates the reviewed publication record, and retains backups. Review paths and checkpoints before confirming.")])
        case "recovery_confirm":
            guard bool("acceptsMissingHistoricRecord"), string("confirmation") == "ACCEPT MISSING HISTORIC RECORD" else { throw MCPFailure("confirmation_required", "Explicit missing historic record acceptance and exact confirmation text are required.") }
            let token = UUID(uuidString: string("token"))!
            guard let (review, _) = reviews[token] else { throw MCPFailure("invalid_review", "Token is unknown, expired, cancelled, consumed or from another MCP session.") }
            let e = try core()
            try Self.requireSupportedReview(e.store.journal(e.folder(review.folderPath).id))
            reviews.removeValue(forKey: token)
            try e.confirmLegacyPublicationReview(review, token: token, acceptsMissingHistoricRecord: true)
            return ok(["backupsRetained": .bool(true)])
        case "recovery_cancel":
            let token = UUID(uuidString: string("token"))!
            guard let (review, _) = reviews.removeValue(forKey: token) else { throw MCPFailure("invalid_review", "No outstanding same-session review has this token.") }
            try core().cancelLegacyPublicationReview(review); return ok()
        case "settings_get": return try preferences()
        case "settings_update":
            guard !a.isEmpty else { throw MCPFailure("invalid_arguments", "Supply menuBarMode or fileVerification.") }
            let e = try core()
            // One atomic locked update, retaining unknown historical fields as Core decodes them.
            try e.store.locked {
                var config = try e.store.load()
                if case .bool(let value) = a["menuBarMode"] { config.menuBarMode = value }
                if case .string(let value) = a["fileVerification"] { config.fileVerification = FileVerification(rawValue: value)! }
                try e.store.save(config)
            }
            invalidateReviews()
            let saved = try preferences()
            for (key, value) in a { guard saved[key] == value else { throw MCPFailure("readback", "Preference readback failed for \(key).") } }
            return saved
        case "login_item_get": return try bridge.login()
        case "login_item_set": return try bridge.login(enabled: bool("enabled"))
        case "storage_status":
            if worker != nil { return .object(["job": .object(job), "bootstrap": .string(location.bootstrapRoot.path)]) }
            return try storageState()
        case "storage_move", "storage_retry":
            if name == "storage_retry", try manager.state().pending == nil {
                throw MCPFailure("no_pending_storage", "There is no pending storage move or cleanup to retry.")
            }
            invalidateReviews()
            let store = name == "storage_move" ? try core().store : nil
            let parent = a["parent"].map { _ in path("parent") }
            let cancel = StorageMoveCancellation(), manager = manager, id = UUID().uuidString
            cancellation = cancel; engine = nil
            job = ["running": .bool(true), "id": .string(id), "operation": .string(name), "progress": .string("Preparing"), "pauseRequested": .bool(false)]
            worker = Task.detached { [self] in
                do {
                    let progress: @Sendable (String) -> Void = { text in Task { await self.progress(text, id: id) } }
                    if let store, let parent { _ = try manager.move(store: store, toParent: parent, cancellation: cancel, progress: progress) }
                    else { _ = try manager.retry(cancellation: cancel, progress: progress) }
                    await self.finished(id: id, error: nil)
                } catch { await self.finished(id: id, error: error.localizedDescription) }
            }
            return ok(["job": .object(job)])
        case "storage_pause":
            guard let cancellation, worker != nil else { throw MCPFailure("no_storage_job", "No running storage job to pause.") }
            cancellation.cancel(); job["pauseRequested"] = .bool(true)
            return ok(["pauseRequested": .bool(true), "meaning": .string("cooperative before commit; poll storage_status for the final result")])
        case "settings_reset":
            guard string("confirmation") == "RESET RAMNEST" else { throw MCPFailure("confirmation_required", "RESET requires confirmation='RESET RAMNEST'. Originals and storage selection are preserved; records and snapshots are removed.") }
            let e = try core()
            invalidateReviews()
            if try e.statuses().contains(where: { $0.journal.phase != .idle }) {
                _ = try bridge.cli(["reset", "--confirm-reset", "--reset-bootstrap", location.bootstrapRoot.path], root: e.store.root)
            } else { try e.reset(location: location) }
            engine = nil
            return ok(["originalsPreserved": .bool(true), "selectedStoragePreserved": .bool(true), "preferences": .string("retained, matching app RESET"), "appRestart": .string("Restart an open GUI manually to discard its stale view; MCP never launches it")])
        case "install_cli":
            let app = try bridge.requirePackage(), directory = path("directory")
            try Paths.rejectSymlinks(directory.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw MCPFailure("invalid_directory", "Choose an existing directory.") }
            let target = directory.appendingPathComponent("ramnest"), cli = app.appendingPathComponent("Contents/Helpers/ramnest")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: cli)
            guard try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == cli.path else { throw MCPFailure("readback", "CLI launcher readback failed.") }
            return ok(["installed": .string(target.path), "target": .string(cli.path)])
        default: throw MCPFailure("unknown_tool", "Unknown tool.")
        }
    }
    // Native confirmation persists acceptance before invoking privileged release.
    // This executable is deliberately NOT on Core's privileged caller allowlist.
    // Reject before issuing a token or entering that write path; never widen it.
    static func requireSupportedReview(_ journal: Journal) throws {
        guard journal.backend != .tmpfs, journal.nativeTmpfs == nil else {
            throw MCPFailure("unavailable", "Native reviewed-publication recovery requires the RAMNest app. MCP cannot complete its authorized reservation release; no recovery acceptance was written. Use Review Legacy Recovery in RAMNest.")
        }
    }
    private func editedOptions(_ initial: FolderOptions, patch: JSON?) throws -> FolderOptions {
        guard case .object(let fields) = patch else { return initial }
        var value = initial
        for (key, v) in fields {
            switch (key, v) {
            case ("mountAtLaunch", .bool(let b)): value.mountAtLaunch = b
            case ("nobrowse", .bool(let b)): value.nobrowse = b
            case ("sync", .bool(let b)): value.sync = b
            case ("periodicSave", .bool(let b)): value.periodicSave = b
            case ("intervalMinutes", .integer(let n)):
                guard FolderOptions.intervals.contains(n) else { throw MCPFailure("invalid_arguments", "Unsupported periodic interval.") }; value.intervalMinutes = n
            case ("comparison", .string(let s)): value.comparison = Comparison(rawValue: s)!
            default: throw MCPFailure("invalid_arguments", "Unknown folder option.")
            }
        }
        return value
    }
    private func preferences() throws -> JSON {
        let e = try core(), c = try e.store.locked { try e.store.load() }
        return .object(["menuBarMode": .bool(c.menuBarMode), "fileVerification": .string(c.fileVerification.rawValue),
            "backend": .string("tmpfs"), "verificationApplies": .string("next mount; existing sessions/revisions unchanged"),
            "menuModeApplies": .string("next GUI reload")])
    }
    private func storageState() throws -> JSON {
        let state = try manager.state()
        return .object(["path": .string(state.path), "pending": state.pending.map(JSON.string) ?? .null,
            "cleanupPending": .bool(state.cleanupPending), "job": .object(job)])
    }
    private func progress(_ value: String, id: String) {
        guard worker != nil, job["id"] == .string(id) else { return }; job["progress"] = .string(value)
    }
    private func finished(id: String, error: String?) {
        guard job["id"] == .string(id) else { return }
        job["running"] = .bool(false); job["error"] = error.map(JSON.string) ?? .null
        job["progress"] = .string(error == nil ? "Finished" : "Stopped; inspect pending state before retry")
        worker = nil; cancellation = nil; engine = nil
    }
    public func shutdown() async {
        closing = true; invalidateReviews(); cancellation?.cancel()
        let current = worker
        await current?.value
        // No mount/unmount/reconnect is performed here.
    }
}
