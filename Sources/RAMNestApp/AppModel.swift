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
    @Published private(set) var backend = Configuration.Backend.nfs
    @Published private(set) var backendError: String?
    @Published var memoryUsed: Double = 0
    let engine: Engine?
    var refreshTask: Task<Void, Never>?
    var selectedStatus: FolderStatus? { statuses.first { $0.id == selected } }
    var dirty: Bool { guard let draft, let selectedStatus else { return false }; return draft != selectedStatus.folder }
    init(repository: Store? = nil) {
        do {
            let args = CommandLine.arguments
            let root: URL
            if let i = args.firstIndex(of: "--store"), args.count > i+1 { root = URL(fileURLWithPath: args[i+1]) } else { root = Store.defaultRoot }
            let store = try repository ?? Store(root: root)
            let config = try store.locked { try store.load() }
            engine = Engine(store: store); menuBarMode = config.menuBarMode; backend = config.backend
        } catch { engine = nil; self.error = error.localizedDescription; backendError = error.localizedDescription }
    }
    func start() {
        // Launch belongs to AppDelegate, not view appearance. Reopening a window
        // cannot start another auto-mount pass or a second refresh loop.
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            if let engine {
                let unclean = statuses.contains { !$0.connected && $0.journal.phase != .idle }
                if unclean { error = "A previous session did not finish cleanly. Automatic mounting is paused. Recover or export each affected folder first." }
                else {
                    for status in statuses where !status.mounted && status.journal.phase == .idle && status.folder.options.mountAtLaunch {
                        await perform("Mounting \(status.folder.name)…") { try engine.mount(status.id.uuidString) }
                    }
                }
            }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); if !busy { await refresh() } }
        }
    }
    func refresh() async {
        guard let engine else { return }
        do {
            let (current, preference) = try await Task.detached { (try engine.statuses(), try engine.backend()) }.value
            let wasDirty = dirty
            statuses = current
            backend = preference
            if selected == nil { selected = current.first?.id }
            if !wasDirty { draft = selectedStatus?.folder }
            memoryUsed = MemoryReading.usedFraction()
        } catch { self.error = error.localizedDescription }
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
    func presentCreate(_ url: URL? = nil) { guarded { self.creationPath = url; self.showCreate = true } }
    func installCLI() {
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
