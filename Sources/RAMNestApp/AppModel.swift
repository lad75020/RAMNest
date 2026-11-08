import SwiftUI
import AppKit
import ServiceManagement
import RAMNestCore

@MainActor final class AppModel: ObservableObject {
#if DEBUG
    @Published var benchmarkReport: DebugBenchmarkReport?
    @Published var benchmarkProgress: DebugBenchmarkProgress?
    @Published var benchmarkRunning = false
    var benchmarkAdmission = DebugBenchmarkAdmission()
    var benchmarkCancellation: DebugBenchmarkCancellation?
    var benchmarkTask: Task<Void, Never>?
#endif
    @Published var statuses: [FolderStatus] = []
    @Published var selected: UUID?
    @Published var draft: Folder?
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    @Published var showCreate = false
    @Published var creationPath: URL?
    @Published var menuBarMode = false
    @Published private(set) var backend = Configuration.Backend.nfs
    @Published private(set) var backendError: String?
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
    private var engineGeneration: UInt64 = 0
    private var storageCancellation: StorageMoveCancellation?
    var refreshTask: Task<Void, Never>?
    var selectedStatus: FolderStatus? { statuses.first { $0.id == selected } }
    var dirty: Bool { guard let draft, let selectedStatus else { return false }; return draft != selectedStatus.folder }
    var canMoveSnapshotStorage: Bool {
        storageManager != nil && engine != nil && !busy && !dirty && storagePending == nil &&
        statuses.allSatisfy { $0.journal.phase == .idle && !$0.connected && !$0.mounted && $0.helperActive != true }
    }
    init(repository: Store? = nil, storageManager injectedManager: SnapshotStorageManager? = nil,
         storagePicker: (@MainActor () -> URL?)? = nil) {
        self.storagePicker = storagePicker
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
            let config = try store.locked { try store.load() }
            engine = Engine(store: store); menuBarMode = config.menuBarMode; backend = config.backend; snapshotStoragePath = store.root.path
            fileVerification = config.fileVerification
            if let storageManager { let state = try storageManager.state(); storagePending = state.pending }
        } catch {
            engine = nil; self.error = error.localizedDescription; backendError = error.localizedDescription; storageError = error.localizedDescription
            if let state = try? storageManager?.state() { snapshotStoragePath = state.path; storagePending = state.pending }
        }
    }
    func start() {
        // Launch belongs to AppDelegate, not view appearance. Reopening a window
        // cannot start another auto-mount pass or a second refresh loop.
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            if let engine, engineGeneration == 0, !movingStorage, storagePending == nil {
                let unclean = statuses.contains { !$0.connected && $0.journal.phase != .idle }
                if unclean { error = "A previous session did not finish cleanly. Automatic mounting is paused. Recover or export each affected folder first." }
                else {
                    for status in statuses where !status.mounted && status.journal.phase == .idle && status.folder.options.mountAtLaunch {
                        guard engineGeneration == 0, !movingStorage, storagePending == nil, self.engine === engine else { break }
                        await perform("Mounting \(status.folder.name)…") { try engine.mount(status.id.uuidString) }
                    }
                }
            }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); if !busy { await refresh() } }
        }
    }
    func refresh() async {
        guard !busy, let engine else { return }
        let generation = engineGeneration, reader = refreshRead
        do {
            let (current, preference, verification) = try await Task.detached {
                let result: ([FolderStatus], Configuration.Backend)
                if let reader { result = try await reader(engine) }
                else { result = (try engine.statuses(), try engine.backend()) }
                return (result.0, result.1, try engine.fileVerification())
            }.value
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
        guard !busy, !dirty else { return }
        busy = true; movingStorage = true; storageError = nil; engineGeneration &+= 1
        let generation = engineGeneration
        progress = "Preparing snapshot storage move…"
        let cancellation = StorageMoveCancellation(); storageCancellation = cancellation
        let model = self
        do {
            let state = try await Task.detached(priority: .userInitiated) {
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
            self.engine = Engine(store: store); menuBarMode = config.menuBarMode; backend = config.backend
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
        guard !busy else { return }; busy = true; progress = label
        do { try await Task.detached(priority: .userInitiated) { try operation() }.value }
        catch { self.error = error.localizedDescription }
        busy = false; progress = ""; await refresh()
    }
    func guarded(_ action: @escaping @MainActor () -> Void) {
        guard !busy else { return }
        guard dirty else { action(); return }
        let alert = NSAlert(); alert.messageText = "Save option changes?"; alert.informativeText = "Apply or discard your changes before continuing."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let edited = draft, let engine else { return }
            Task {
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
            Task {
                if s.mounted {
                    do {
                        let processes = try await Task.detached { try engine.busyProcesses(s.id.uuidString) }.value
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
    func save() {
        guard selectedStatus?.canSave == true else { return }
        guarded { guard let s = self.selectedStatus, s.canSave, let engine = self.engine else { return }; Task { await self.perform("Saving a coherent local snapshot…") { try engine.save(s.id.uuidString) } } }
    }
    func recover(_ status: FolderStatus? = nil) { guarded { guard let s = status ?? self.selectedStatus, s.canRecover, let engine = self.engine else { return }; Task { await self.perform("Recovering the committed snapshot…") { try engine.recover(s.id.uuidString) } } } }
    func resize() {
        guard selectedStatus?.canResize == true else { return }
        guarded {
            guard let s = self.selectedStatus, s.canResize, let engine = self.engine else { return }
            let alert = NSAlert(); alert.messageText = "Resize \(s.folder.name)"; alert.informativeText = "Enter a capacity such as 512MB or 4GB. Mounted data stays in RAM, including temporary folders. Shrinking below allocated logical usage is rejected."
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
        guard !busy, let engine else { return }
        Task {
            busy = true; progress = "Updating app appearance…"
            defer { busy = false; progress = "" }
            do {
                try await Task.detached { try engine.setMenuBarMode(value) }.value
                menuBarMode = value
            } catch { self.error = error.localizedDescription }
        }
    }
    func setFileVerification(_ value: FileVerification) {
        guard !busy, let engine else { return }
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
    func setBackend(_ value: Configuration.Backend) {
        guard !busy, let engine else { return }
        busy = true; progress = "Saving next mount backend…"; backendError = nil
        Task {
            defer { busy = false; progress = "" }
            do { backend = try await Task.detached { try engine.setBackend(value) }.value }
            catch {
                backendError = error.localizedDescription
                if let saved = try? await Task.detached(operation: { try engine.backend() }).value { backend = saved }
            }
        }
    }
    func backendCaption(for status: FolderStatus) -> String {
        if status.mounted {
            return status.journal.backend.map { "Mounted with FUSE-T \($0.displayName)" } ?? "Mounted with FUSE-T · backend not recorded"
        }
        if status.journal.phase != .idle {
            return status.journal.backend.map { "Session backend: FUSE-T \($0.displayName)" } ?? "Session backend not recorded"
        }
        return "Next mount: FUSE-T \(backend.displayName)"
    }
    func quit() async -> Bool {
        guard !busy else { error = "Wait for the current transaction to finish before quitting."; return false }
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
