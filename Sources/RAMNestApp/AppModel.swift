import SwiftUI
import AppKit
import ServiceManagement
import RAMNestCore

@MainActor final class AppModel: ObservableObject {

    @Published var statuses: [FolderStatus] = []
    @Published var selected: UUID?
    @Published var draft: Folder?
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    @Published var showCreate = false
    @Published var creationPath: URL?
    @Published var menuBarMode = false
    @Published private(set) var backend = Configuration.Backend.tmpfs
    @Published private(set) var fileVerification = FileVerification.sha256
    @Published private(set) var fileVerificationError: String?
    @Published var memoryUsed: Double = 0
    @Published private(set) var engine: Engine?
    @Published private(set) var snapshotStoragePath = ""
    @Published private(set) var storagePending: String?
    @Published private(set) var storageError: String?
    @Published private(set) var movingStorage = false
    @Published private(set) var storageDestinationPath: String?
    let storageManager: SnapshotStorageManager?
    var storagePicker: (@MainActor () -> URL?)?
    // Injectable asynchronous read boundary for stale-completion regression tests.
    var refreshRead: (@Sendable (Engine) async throws -> ([FolderStatus], Configuration.Backend))?
    @Published private(set) var resetting = false
    @Published private(set) var resetCommitted = false
    @Published private(set) var resetError: String?
    private(set) var resetTerminationAllowed = false
    var resetConfirmation: (@MainActor () -> Bool)?
    var resetRelaunch: (@MainActor () async throws -> Void)?
    var resetTerminate: (@MainActor () -> Void)?
    private typealias RefreshResult = ([FolderStatus], Configuration.Backend, FileVerification)
    private var activeRefreshes: [UUID: Task<RefreshResult, Error>] = [:]
    private var engineGeneration: UInt64 = 0
    private var storageCancellation: StorageMoveCancellation?
    var refreshTask: Task<Void, Never>?
    var selectedStatus: FolderStatus? { statuses.first { $0.id == selected } }
    var dirty: Bool { guard let draft, let selectedStatus else { return false }; return draft != selectedStatus.folder }
    var canMoveSnapshotStorage: Bool {
        storageManager != nil && engine != nil && !busy && !resetCommitted && !dirty && storagePending == nil &&
        statuses.allSatisfy { $0.journal.phase == .idle && !$0.connected && !$0.mounted && $0.helperActive != true }
    }
    init(repository: Store? = nil, storageManager injectedManager: SnapshotStorageManager? = nil,
         storagePicker: (@MainActor () -> URL?)? = nil) {
        self.storagePicker = storagePicker
        // Isolated model fixtures must explicitly inject lifecycle callbacks.
        if repository == nil {
            resetRelaunch = { try await AppRelaunch.open() }
            resetTerminate = { NSApplication.shared.terminate(nil) }
        }
        let args = CommandLine.arguments
        let explicit: URL?
        if repository == nil, let i = args.firstIndex(of: "--store"), args.count > i+1 { explicit = URL(fileURLWithPath: args[i+1]) }
        else { explicit = nil }
        // Repository-only fixtures never consult home. An explicit launch cannot
        // change the global selection; tests opt in with an injected manager.
        storageManager = injectedManager ?? (repository == nil && explicit == nil ? SnapshotStorageManager() : nil)
        do {
            if repository == nil, args.last == "--store" { throw NestError("--store requires a directory.", code: 64) }
            let store = try repository ?? (explicit.map { try Store(root: $0) } ?? storageManager!.open())
            engine = Engine(store: store); snapshotStoragePath = store.root.path
            if store.resetPending {
                resetError = "An interrupted RESET needs Retry RESET. Folder operations remain paused."
                return
            }
            let config = try store.locked { try store.load() }
            engine = Engine(store: store); menuBarMode = config.menuBarMode; backend = .tmpfs; snapshotStoragePath = store.root.path
            fileVerification = config.fileVerification
            if let storageManager { let state = try storageManager.state(); storagePending = state.pending }
        } catch {
            engine = nil; self.error = error.localizedDescription; storageError = error.localizedDescription
            if let state = try? storageManager?.state() { snapshotStoragePath = state.path; storagePending = state.pending }
        }
    }
    func start() {
        // Launch belongs to AppDelegate, not view appearance. Reopening a window
        // cannot start another auto-mount pass or a second refresh loop.
        guard refreshTask == nil, !resetting, !resetCommitted, engine?.store.resetPending != true else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            if statuses.contains(where: { $0.journal.resetUnmountPending }) {
                resetError = "An interrupted RESET needs Retry RESET. Automatic mounting remains paused."
                return
            }
            if let engine, engineGeneration == 0, !Task.isCancelled, !resetting, !movingStorage, storagePending == nil {
                for status in statuses where status.journal.nativeTmpfs != nil && status.mounted && !status.connected && status.journal.phase == .mounted && status.journal.populationVerified {
                    guard engineGeneration == 0, !Task.isCancelled, !resetting, !movingStorage, storagePending == nil, self.engine === engine else { break }
                    await perform("Reconnecting \(status.folder.name)…") { try engine.reconnect(status.id.uuidString) }
                }
                let unclean = statuses.contains { !$0.connected && $0.journal.phase != .idle }
                if unclean { error = "A previous session did not finish cleanly. Automatic mounting is paused. Recover or export each affected folder first." }
                else {
                    for status in statuses where status.canMount && status.folder.options.mountAtLaunch {
                        guard engineGeneration == 0, !Task.isCancelled, !resetting, !movingStorage, storagePending == nil, self.engine === engine else { break }
                        await perform("Mounting \(status.folder.name)…") { try engine.mount(status.id.uuidString) }
                    }
                }
            }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled && !busy && !resetCommitted { await refresh() } }
        }
    }
    func refresh() async {
        guard !busy, !resetting, !resetCommitted, let engine, !engine.store.resetPending else { return }
        let generation = engineGeneration, reader = refreshRead
        let id = UUID()
        let read = Task.detached { () throws -> RefreshResult in
            let result: ([FolderStatus], Configuration.Backend)
            if let reader { result = try await reader(engine) }
            else { result = (try engine.statuses(), try engine.backend()) }
            return (result.0, result.1, try engine.fileVerification())
        }
        activeRefreshes[id] = read
        defer { activeRefreshes.removeValue(forKey: id) }
        do {
            let (current, preference, verification) = try await read.value
            guard !busy, generation == engineGeneration, self.engine === engine else { return }
            let wasDirty = dirty
            statuses = current
            backend = preference
            fileVerification = verification
            if selected == nil { selected = current.first?.id }
            if !wasDirty { draft = selectedStatus?.folder }
            memoryUsed = MemoryReading.usedFraction()
        } catch {
            guard !busy, generation == engineGeneration, self.engine === engine else { return }
            self.error = error.localizedDescription
        }
    }
    func chooseSnapshotStorage() {
        guard canMoveSnapshotStorage else { storageError = "Finish all folder operations and apply or discard option edits before moving snapshots."; return }
        let parent: URL?
        if let storagePicker { parent = storagePicker() }
        else {
            let panel = NSOpenPanel(); panel.title = "Choose snapshot storage parent"
            panel.message = "RAMNest creates a private ‘RAMNest Snapshots’ child here and moves snapshots, journals and settings together. The parent’s contents and permissions stay unchanged."
            panel.prompt = "Choose Parent"; panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
            parent = panel.runModal() == .OK ? panel.url : nil
        }
        guard let parent else { return }
        Task { await moveSnapshotStorage(toParent: parent) }
    }
    func moveSnapshotStorage(toParent parent: URL) async {
        guard canMoveSnapshotStorage, let storageManager, let engine else { storageError = "Storage can move only when every folder is idle and option edits are applied or discarded."; return }
        storageDestinationPath = parent.standardizedFileURL.appendingPathComponent("RAMNest Snapshots").path
        await runStorageChange(manager: storageManager) { cancellation, progress in
            try storageManager.move(store: engine.store, toParent: parent, cancellation: cancellation, progress: progress)
        }
    }
    func retrySnapshotStorage() {
        guard !busy, !dirty, let storageManager else { return }
        Task { await runStorageChange(manager: storageManager) { _, progress in try storageManager.retry(progress: progress) } }
    }
    func cancelSnapshotStorageMove() { storageCancellation?.cancel() }
    private func runStorageChange(manager: SnapshotStorageManager,
        operation: @escaping @Sendable (StorageMoveCancellation, @Sendable (String) -> Void) throws -> SnapshotStorageState) async {
        // Queued Retry tasks must recheck admission on the main actor, before
        // this operation first suspends. Only one generation owns completion.
        guard !busy, !resetCommitted, !dirty else { return }
        busy = true; movingStorage = true; storageError = nil; engineGeneration &+= 1
        let generation = engineGeneration
        progress = "Preparing snapshot storage move…"
        let cancellation = StorageMoveCancellation(); storageCancellation = cancellation
        let model = self
        do {
            let state = try await Task.detached(priority: .userInitiated) { [model] in
                try operation(cancellation, { message in Task { @MainActor [weak model] in if model?.movingStorage == true && model?.engineGeneration == generation { model?.progress = message } } })
            }.value
            guard generation == engineGeneration, movingStorage else { return }
            snapshotStoragePath = state.path; storagePending = state.pending
        } catch {
            guard generation == engineGeneration, movingStorage else { return }
            storageError = error.localizedDescription
        }
        guard generation == engineGeneration, movingStorage else { return }
        if let state = try? manager.state() { snapshotStoragePath = state.path; storagePending = state.pending }
        do {
            let store = try manager.open(), config = try store.locked { try store.load() }
            self.engine = Engine(store: store); menuBarMode = config.menuBarMode; backend = .tmpfs
            fileVerification = config.fileVerification
        } catch {
            // A committed-but-not-retired destination stays fenced. Settings
            // remains usable for Retry, while all folder mutators lose authority.
            self.engine = nil; statuses = []; storageError = storageError ?? error.localizedDescription
        }
        engineGeneration &+= 1; storageCancellation = nil; storageDestinationPath = nil; movingStorage = false; busy = false; progress = ""
        await refresh()
    }
    func perform(_ label: String, operation: @escaping @Sendable () throws -> Void) async {
        guard !busy, !resetCommitted, !resetting else { return }; busy = true; progress = label
        do { try await Task.detached(priority: .userInitiated) { try operation() }.value }
        catch { self.error = error.localizedDescription }
        busy = false; progress = ""; await refresh()
    }
    func guarded(_ action: @escaping @MainActor () -> Void) {
        guard !busy, !resetCommitted, !resetting else { return }
        guard dirty else { action(); return }
        let alert = NSAlert(); alert.messageText = "Save option changes?"; alert.informativeText = "Apply or discard your changes before continuing."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let edited = draft, let engine else { return }
            Task {
                guard !busy, !resetCommitted else { return }
                busy = true; progress = "Applying options…"
                do { try await Task.detached { try engine.update(edited) }.value; busy = false; await refresh(); action() }
                catch { busy = false; self.error = error.localizedDescription }
            }
        case .alertSecondButtonReturn: draft = selectedStatus?.folder; action()
        default: break
        }
    }
    func select(_ id: UUID?) { guarded { self.selected = id; self.draft = self.selectedStatus?.folder } }
    func apply() {
        guard !busy, let edited = draft, let engine else { return }
        Task { await perform("Applying options…") { try engine.update(edited) } }
    }
    func discard() { draft = selectedStatus?.folder }
    func mountOrEject(_ s: FolderStatus) {
        guard s.canMount || s.canEject else { return }
        guarded {
            guard let engine = self.engine else { return }
            let generation = self.engineGeneration
            Task {
                guard !self.busy, generation == self.engineGeneration else { return }
                if s.mounted {
                    do {
                        let processes = try await Task.detached { try engine.busyProcesses(s.id.uuidString) }.value
                        guard !self.busy, generation == self.engineGeneration else { return }
                        if !processes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let alert = NSAlert(); alert.messageText = "Files are in use"; alert.informativeText = "Close the listed processes to finish their writes, or Ignore to attempt a normal eject. RAMNest will not terminate them.\n\n" + processes
                            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Ignore")
                            if alert.runModal() != .alertSecondButtonReturn { return }
                        }
                        await self.perform("Ejecting \(s.folder.name)…") { try engine.unmount(s.id.uuidString, ignoreBusy: true) }
                    } catch { self.error = error.localizedDescription }
                } else { await self.perform("Mounting \(s.folder.name)…") { try engine.mount(s.id.uuidString) } }
            }
        }
    }
    func reconnect(_ status: FolderStatus) {
        guarded { guard let engine = self.engine else { return }; Task { await self.perform("Reconnecting native mount…") { try engine.reconnect(status.id.uuidString) } } }
    }
    func save() {
        guard selectedStatus?.canSave == true else { return }
        guarded { guard let s = self.selectedStatus, s.canSave, let engine = self.engine else { return }; Task { await self.perform("Saving a coherent local snapshot…") { try engine.save(s.id.uuidString) } } }
    }
    func recover(_ status: FolderStatus? = nil) { guarded { guard let s = status ?? self.selectedStatus, s.canRecover, let engine = self.engine else { return }; Task { await self.perform("Recovering the committed snapshot…") { try engine.recover(s.id.uuidString) } } } }
    func reviewLegacyRecovery() {
        guarded {
            guard let status = self.selectedStatus, status.canReviewLegacyPublication, let engine = self.engine else { return }
            // Synchronous admission prevents two queued clicks, polling or RESET
            // from opening another review before this Task reaches its first await.
            self.busy = true; self.progress = "Reviewing legacy recovery evidence (read only)…"
            let generation = self.engineGeneration
            Task {
                do {
                    let review = try await Task.detached(priority: .userInitiated) { try engine.reviewLegacyPublication(status.id.uuidString) }.value
                    defer { engine.cancelLegacyPublicationReview(review) }
                    if generation == self.engineGeneration {
                        let alert = NSAlert(); alert.alertStyle = .warning
                        alert.messageText = "Review incomplete legacy publication"
                        alert.informativeText = "The restored folder is already on disk. Its current contents and metadata were checked against the committed checkpoint and legacy receipt. The old destination symlink's pre-swap metadata and MACL were never recorded. That missing history cannot be proved or recreated. Only the explained root MACL pathname difference and the existing narrowly bound rename provenance rule are admitted.\n\nFolder: \(review.folderPath)\nLatest checkpoint: \(review.revision)\nInitial checkpoint: \(review.initialRevision)\n\nRetained original: \(review.retainedOriginalPath)\nRetained displaced link: \(review.retainedLinkPath)\nSnapshots: \(review.snapshotPath)\n\nAccepting records a durable acknowledgement of the missing historic record, then rechecks all reviewed evidence before changing metadata. Recovery copies and snapshots are kept; remount and automatic cleanup remain paused until a separately confirmed RESET removes the managed records. RESET preserves external recovery folders."
                        alert.addButton(withTitle: "Cancel")
                        alert.addButton(withTitle: "Accept Missing Record and Complete Recovery")
                        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[1].keyEquivalent = ""
                        self.progress = "Waiting for explicit recovery confirmation…"
                        if alert.runModal() == .alertSecondButtonReturn {
                            self.progress = "Rechecking evidence and completing reviewed recovery…"
                            try await Task.detached(priority: .userInitiated) {
                                try engine.confirmLegacyPublicationReview(review, token: review.token, acceptsMissingHistoricRecord: true)
                            }.value
                        }
                    }
                } catch { self.error = error.localizedDescription }
                self.busy = false; self.progress = ""; await self.refresh()
            }
        }
    }
    func resize() {
        guard selectedStatus?.canResize == true else { return }
        guarded {
            guard let s = self.selectedStatus, s.canResize, let engine = self.engine else { return }
            let alert = NSAlert(); alert.messageText = "Resize \(s.folder.name)"; alert.informativeText = "Enter an offline capacity such as 512MB or 4GB. Native tmpfs does not support live resize. Eject before editing; shrinking below admitted contents is rejected."
            let field = NSTextField(string: "\(s.folder.capacity / (1<<20))MB"); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
            alert.addButton(withTitle: "Resize"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                do { let capacity = try SizeParser.parse(field.stringValue); Task { await self.perform("Resizing…") { try engine.resize(s.id.uuidString, capacity: capacity) } } } catch { self.error = error.localizedDescription }
            }
        }
    }
    func exportSnapshot() {
        guarded {
            guard let s = self.selectedStatus, let engine = self.engine else { return }
            let panel = NSSavePanel(); panel.title = "Export local snapshot"; panel.nameFieldStringValue = "\(s.folder.name) Recovery"; panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url { Task { await self.perform("Exporting verified recovery files…") { try engine.export(s.id.uuidString, destination: url) } } }
        }
    }
    func remove() {
        guarded {
            guard let s = self.selectedStatus, let engine = self.engine else { return }
            let alert = NSAlert(); alert.messageText = "Remove \(s.folder.name)?"; alert.informativeText = "Keep Folder saves and ejects first. Delete Folder removes the selected directory after a clean eject. Recovery snapshots and original holding directories are retained."
            alert.addButton(withTitle: "Keep Folder"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Folder…")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return }
            let destroy = response == .alertThirdButtonReturn
            if destroy {
                let confirm = NSAlert(); confirm.alertStyle = .critical; confirm.messageText = "Delete this directory and its files?"; confirm.informativeText = s.folder.path
                confirm.addButton(withTitle: "Cancel"); confirm.addButton(withTitle: "Delete Folder")
                guard confirm.runModal() == .alertSecondButtonReturn else { return }
            }
            Task { await self.perform("Removing RAM folder…") { try engine.delete(s.id.uuidString, destroy: destroy, confirmed: destroy) }; self.selected = nil; self.draft = nil; await self.refresh() }
        }
    }
    func presentCreate(_ url: URL? = nil) { guard engine != nil else { return }; guarded { self.creationPath = url; self.showCreate = true } }
    func installCLI() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "Choose a directory for the ramnest launcher"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let directory = panel.url {
            let target = directory.appendingPathComponent("ramnest")
            do { try Paths.rejectSymlinks(directory.path); try FileManager.default.createSymbolicLink(at: target, withDestinationURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ramnest")) } catch { self.error = error.localizedDescription }
        }
    }
    func setMenuMode(_ value: Bool) {
        guard !busy, !resetCommitted, let engine else { return }
        busy = true; progress = "Updating app appearance…"
        Task {
            defer { busy = false; progress = "" }
            do {
                try await Task.detached { try engine.setMenuBarMode(value) }.value
                menuBarMode = value
            } catch { self.error = error.localizedDescription }
        }
    }
    func setFileVerification(_ value: FileVerification) {
        guard !busy, !resetCommitted, let engine else { return }
        busy = true; progress = "Saving next mount file verification…"; fileVerificationError = nil
        Task {
            defer { busy = false; progress = "" }
            do { fileVerification = try await Task.detached { try engine.setFileVerification(value) }.value }
            catch {
                fileVerificationError = error.localizedDescription
                if let saved = try? await Task.detached(operation: { try engine.fileVerification() }).value { fileVerification = saved }
            }
        }
    }
    func backendCaption(for status: FolderStatus) -> String {
        if status.mounted {
            return status.journal.backend.map { $0 == .tmpfs ? "Mounted with native macOS tmpfs" : "Legacy FUSE-T \($0.displayName) session · use original version to control" } ?? "Legacy session · backend not recorded"
        }
        if status.journal.phase != .idle {
            return status.journal.backend.map { "Session engine: \($0.displayName)" } ?? "Session backend not recorded"
        }
        return "Next mount: native macOS tmpfs"
    }
    var resetButtonTitle: String { resetCommitted ? "Retry Restart…" : engine?.store.resetPending == true ? "Retry RESET…" : "RESET RAMNest…" }
    var canReset: Bool { engine != nil && !busy && !resetting && storagePending == nil }
    func confirmReset() {
        guard canReset else { return }
        let accepted: Bool
        if let resetConfirmation { accepted = resetConfirmation() }
        else {
            let alert = NSAlert(); alert.alertStyle = .critical
            alert.messageText = resetCommitted ? "Restart RAMNest?" : "RESET RAMNest and delete all snapshots?"
            alert.informativeText = "All managed RAM folders will be ejected normally. Sync folders save their contents; temporary folders discard RAM changes and restore their originals. All RAM-folder records, reviewed-recovery acknowledgements and saved snapshots, including retained snapshots, will be permanently deleted. Original folders, external recovery folders and unrelated drives are preserved. Save the displayed recovery locations and evidence before RESET. RAMNest then restarts using the selected storage location. Close files first. Any unfinished recovery or cleanup error stops reset."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: resetCommitted ? "Restart" : "RESET and Restart")
            alert.buttons[0].keyEquivalent = "\r"; alert.buttons[1].keyEquivalent = ""
            alert.buttons[1].hasDestructiveAction = !resetCommitted
            accepted = alert.runModal() == .alertSecondButtonReturn
        }
        guard accepted else { return }
        // Admission is synchronous: queued actions cannot slip ahead of reset.
        busy = true; resetting = true
        Task { await runReset() }
    }
    private func runReset() async {
        guard let engine else { busy = false; resetting = false; return }
        resetError = nil; engineGeneration &+= 1
        refreshTask?.cancel(); refreshTask = nil
        let reads = Array(activeRefreshes.values)
        for read in reads { read.cancel() }
        for read in reads { _ = await read.result }
        progress = resetCommitted ? "Restarting RAMNest…" : "Ejecting folders and resetting saved state…"
        do {
            if !resetCommitted {
                let location = storageManager?.location
                try await Task.detached(priority: .userInitiated) { try engine.reset(location: location) }.value
                // Durable success alone authorizes clearing GUI state.
                resetCommitted = true; statuses = []; selected = nil; draft = nil
                showCreate = false; creationPath = nil; error = nil
            }
            guard let resetRelaunch, let resetTerminate else { throw NestError("RESET completed. Restart RAMNest manually; no relaunch callback is configured.") }
            try await resetRelaunch()
            resetTerminationAllowed = true
            resetTerminate()
        } catch { resetError = error.localizedDescription }
        resetting = false; busy = false; progress = ""
        // Failed reset leaves polling/startup paused. The existing GUI records
        // stay visible until a durable retry succeeds or explicit recovery runs.
    }

    func quit() async -> Bool {
        if resetTerminationAllowed { return true }
        guard !resetCommitted else { return true }
        guard !busy else { error = "Wait for the current transaction to finish before quitting."; return false }
        if let engine, engine.store.resetPending {
            busy = true; progress = "Checking interrupted RESET before quitting…"
            defer { busy = false; progress = "" }
            do { return try await Task.detached { try engine.canTerminatePendingReset() }.value }
            catch { self.error = error.localizedDescription; return false }
        }
        if dirty {
            let alert = NSAlert(); alert.messageText = "Unapplied option changes"; alert.informativeText = "Return to RAMNest to apply or discard them before quitting."; alert.runModal(); return false
        }
        guard let engine else { return true }
        busy = true; progress = "Saving RAM folders before quitting…"
        defer { busy = false; progress = "" }
        do {
            let current = try await Task.detached { try engine.statuses() }.value
            for s in current where s.connected && s.mounted {
                progress = "Saving and ejecting \(s.folder.name)…"
                do { try await Task.detached { try engine.unmount(s.id.uuidString) }.value }
                catch let e as NestError where e.code == 7 {
                    let alert = NSAlert(); alert.messageText = "\(s.folder.name) is in use"; alert.informativeText = e.message; alert.addButton(withTitle: "Stay"); alert.addButton(withTitle: "Ignore and Eject")
                    guard alert.runModal() == .alertSecondButtonReturn else { return false }
                    try await Task.detached { try engine.unmount(s.id.uuidString, ignoreBusy: true) }.value
                }
            }
            if current.contains(where: { !$0.connected && $0.journal.phase != .idle }) {
                let alert = NSAlert(); alert.messageText = "Some folders need recovery"; alert.informativeText = "Committed snapshots remain on disk. Stay to recover or export them."; alert.addButton(withTitle: "Stay"); alert.addButton(withTitle: "Quit")
                return alert.runModal() == .alertSecondButtonReturn
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

enum MemoryReading {
    static func usedFraction() -> Double {
        var info = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return min(1, Double(pages * UInt64(sysconf(_SC_PAGESIZE))) / Double(ProcessInfo.processInfo.physicalMemory))
    }
}

// Launch Services takes an argument array (no shell or detached waiter process).
// The old app exits only after the new instance is accepted by macOS.
@MainActor enum AppRelaunch {
    static func arguments(_ arguments: [String]) -> [String] {
        Array(arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
    }
    @MainActor private final class Request {
        var continuation: CheckedContinuation<Void, Error>?
        var deadline: Task<Void, Never>?
        func finish(_ error: Error?) {
            guard let continuation else { return }
            self.continuation = nil; deadline?.cancel(); deadline = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
    static func open() async throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NestError("RESET completed, but this executable is not an app bundle. Restart RAMNest manually.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments(CommandLine.arguments)
        let request = Request()
        try await withCheckedThrowingContinuation { continuation in
            request.continuation = continuation
            request.deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                request.finish(NestError("RESET completed, but macOS did not acknowledge relaunch. Restart manually or retry restart."))
            }
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { application, error in
                let failure = error ?? (application == nil ? NestError("RESET completed, but macOS returned no relaunched app. Retry restart or reopen RAMNest manually.") : nil)
                Task { @MainActor in request.finish(failure) }
            }
        }
    }
}
