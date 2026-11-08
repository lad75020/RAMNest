import SwiftUI
import AppKit
import ServiceManagement
import RAMNestCore

// Use the stable property-wrapper type explicitly; the macOS 27 State macro
// also requires a compiler-plugin sandbox that is unavailable in build sandboxes.
typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.circle.fill").font(.largeTitle).foregroundStyle(.green)
                    VStack(alignment: .leading) { Text("RAMNest").font(.title2.bold()); Text("Room to move faster").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(20)
                List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
                    Section("RAM folders") {
                        ForEach(model.statuses) { s in
                            HStack(spacing: 10) {
                                Image(systemName: s.needsAttention ? "exclamationmark.folder" : s.mounted ? "folder.fill" : "folder").foregroundStyle(s.isReady ? Color.green : s.needsAttention ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(s.folder.name).lineLimit(1)
                                    Text(s.isReady ? "Mounted · \(formatted(s.used)) used" : s.statusTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button { model.mountOrEject(s) } label: { Image(systemName: s.mounted ? "eject.circle" : "play.circle") }.buttonStyle(.borderless).help(s.primaryActionTitle).disabled(model.busy || !(s.canMount || s.canEject))
                            }.padding(.vertical, 5).tag(s.id)
                        }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("System memory"); Spacer(); Text("\(Int(model.memoryUsed * 100))%").monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: model.memoryUsed).tint(model.memoryUsed > 0.85 ? .orange : .green)
                    Text("Capacity is a ceiling. RAM grows with content.").font(.caption2).foregroundStyle(.secondary)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 245, ideal: 270)
        } detail: {
            if let status = model.selectedStatus {
#if DEBUG
                VStack(spacing: 0) {
                    FolderDetail(status: status)
                    DebugBenchmarkView()
                }
#else
                FolderDetail(status: status)
#endif
            }
            else {
                ContentUnavailableView {
                    Label("Make space for your work", systemImage: "leaf.circle")
                } description: { Text("Choose an existing folder. Its files stay protected in a verified local snapshot while you work in RAM.") } actions: { Button("New RAM Folder…") { model.presentCreate() }.buttonStyle(.borderedProminent) }
            }
        }
        .toolbar {
            ToolbarItemGroup { Button { model.presentCreate() } label: { Label("New RAM Folder", systemImage: "plus") }.keyboardShortcut("n"); Button { model.remove() } label: { Label("Remove", systemImage: "trash") }.disabled(model.selected == nil || model.busy); SettingsLink { Image(systemName: "gearshape") } }
        }
        .safeAreaInset(edge: .bottom) {
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.progress); Spacer() }.padding(12).background(.bar) }
        }
        .sheet(isPresented: $model.showCreate) { CreateFolderView(initialPath: model.creationPath).environmentObject(model) }
        .alert("RAMNest needs your attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .dropDestination(for: URL.self) { urls, _ in guard let url = urls.first else { return false }; model.presentCreate(url); return true }
    }
}
func formatted(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .binary) }

struct FolderDetail: View {
    @EnvironmentObject var model: AppModel
    let status: FolderStatus
    @ViewState<Int> private var tab = 0
    private func option<T>(_ path: WritableKeyPath<FolderOptions, T>, fallback: T) -> Binding<T> { Binding(get: { model.draft?.options[keyPath: path] ?? fallback }, set: { model.draft?.options[keyPath: path] = $0 }) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 46)).foregroundStyle(status.needsAttention ? Color.orange.gradient : Color.green.gradient).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Display name", text: Binding(get: { model.draft?.name ?? status.folder.name }, set: { model.draft?.name = $0 })).font(.largeTitle.bold()).textFieldStyle(.plain).help("Display name in RAMNest. The mounted volume keeps the original folder name.")
                        Button(status.folder.path) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: status.folder.path) }.buttonStyle(.link).lineLimit(2).font(.callout)
                        Label(status.statusTitle, systemImage: status.needsAttention ? "exclamationmark.triangle" : status.isReady ? "circle.fill" : "circle").font(.caption).foregroundStyle(status.isReady ? Color.green : status.needsAttention ? Color.orange : Color.secondary)
                        Text(model.backendCaption(for: status)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(status.primaryActionTitle) { model.mountOrEject(status) }.buttonStyle(.borderedProminent).tint(status.needsAttention ? .orange : .green).disabled(model.busy || !(status.canMount || status.canEject))
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("\(formatted(status.used)) logical allocation").font(.headline); Spacer(); Button("of \(formatted(status.folder.capacity)) 􀈊") { model.resize() }.buttonStyle(.link).help("Resize without remounting").disabled(!status.canResize || model.busy) }
                        ProgressView(value: Double(status.used), total: Double(status.folder.capacity)).tint(.green)
                        HStack(spacing: 24) { metric("File bytes", status.contentBytes); metric("Encoded payload", status.payloadBytes); metric("Mapped backing", status.mappedBytes) }
                        Text("\(Int(status.backingSavingsFraction * 100))% backing saved versus logical allocation").font(.caption).foregroundStyle(.secondary)
                        Text("Backing metrics exclude metadata, temporary compression buffers, and kernel caches. They are not process RSS.").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                if let error = status.journal.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let warning = status.journal.cleanupWarning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Button("Save Snapshot", systemImage: "square.and.arrow.down") { model.save() }.disabled(!status.canSave || model.busy)
                    Button("Export Snapshot…", systemImage: "arrow.up.doc") { model.exportSnapshot() }.disabled(status.journal.revision == nil || model.busy)
                    Button("Recover", systemImage: "arrow.counterclockwise") { model.recover() }.disabled(!status.canRecover || model.busy)
                }
                Divider()
                HStack { Text(model.dirty ? "Options *" : "Options").font(.title3.bold()); Spacer(); Picker("Options", selection: $tab) { Text("Normal").tag(0); Text("Advanced").tag(1) }.pickerStyle(.segmented).frame(width: 230) }
                VStack(alignment: .leading, spacing: 16) {
                    if tab == 0 {
                        Toggle("Mount at app launch", isOn: option(\.mountAtLaunch, fallback: true))
                        Toggle("Hide from Desktop and Finder sidebar", isOn: option(\.nobrowse, fallback: true))
                        Toggle("Save changes when ejecting", isOn: option(\.sync, fallback: true))
                        Text(model.draft?.options.sync == false ? "Temporary mode: each mount begins with the original files. Eject restores the original folder and discards RAM changes." : "Periodic saves update the private snapshot. Eject restores the latest committed data to your folder.").font(.callout).foregroundStyle(.secondary)
                        Toggle("Save a snapshot periodically", isOn: option(\.periodicSave, fallback: false)).disabled(model.draft?.options.sync == false)
                        Picker("Save every", selection: option(\.intervalMinutes, fallback: 15)) { ForEach(FolderOptions.intervals, id: \.self) { Text($0 < 60 ? "\($0) minutes" : "\($0 / 60) hours").tag($0) } }.frame(maxWidth: 340).disabled(model.draft?.options.sync == false || model.draft?.options.periodicSave == false)
                    } else {
                        Toggle("Real-time LZ4 compression", isOn: option(\.compression, fallback: true))
                        Text("Compresses each 64 KiB content block as you write. Incompressible blocks stay raw. This option and Finder visibility take effect at the next mount.").font(.callout).foregroundStyle(.secondary)
                        Picker("Snapshot comparison", selection: option(\.comparison, fallback: .sizeAndModTime)) { Text("Size & modification time").tag(Comparison.sizeAndModTime); Text("File checksum").tag(Comparison.checksum) }.frame(maxWidth: 430)
                        Text("Controls incremental file selection. File integrity uses the policy recorded when this session mounted; choose the policy for future mounts in Settings.").font(.caption).foregroundStyle(.secondary)
                        Label("FSEvents suppression is unavailable", systemImage: "info.circle").font(.callout)
                        Text("RAMNest does not request FSEvents suppression. Folder watcher behavior depends on the mount backend.").font(.caption).foregroundStyle(.secondary)
                        Label("Local persistence only", systemImage: "internaldrive").font(.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack { if model.dirty { Text("Unapplied changes").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Discard") { model.discard() }.disabled(!model.dirty); Button("Apply") { model.apply() }.buttonStyle(.borderedProminent).disabled(!model.dirty || model.busy) }
            }.padding(30)
        }.disabled(model.busy)
    }
    private func metric(_ title: String, _ bytes: UInt64) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(formatted(bytes)).font(.callout.monospacedDigit()) } }
}

struct CreateFolderView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let initialPath: URL?
    @ViewState<URL?> private var path: URL?
    @ViewState<String> private var name = ""
    @ViewState<String> private var size = "4"
    @ViewState<String> private var unit = "GB"
    @ViewState<Bool> private var compression = true
    @ViewState<Bool> private var sync = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("New RAM folder", systemImage: "folder.badge.plus").font(.title2.bold())
            Text("Use an existing folder at its usual path. RAMNest verifies a private local snapshot before moving any original files.").foregroundStyle(.secondary)
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Mount at").font(.caption); Text(path?.path ?? "Choose an existing folder").lineLimit(3).textSelection(.enabled) }; Spacer(); Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { path = panel.url } } }
            TextField("Display name (optional)", text: $name).help("Display name in RAMNest. The mounted volume keeps the original folder name.")
            HStack { Text("Capacity"); TextField("4", text: $size).frame(width: 100); Picker("Unit", selection: $unit) { Text("MB").tag("MB"); Text("GB").tag("GB") }.labelsHidden().frame(width: 100) }
            Text("16 MiB to \(formatted(ProcessInfo.processInfo.physicalMemory / 4 * 3)). The ceiling is not reserved in advance.").font(.caption).foregroundStyle(.secondary)
            Toggle("Real-time LZ4 compression", isOn: $compression)
            Toggle("Save changes on eject", isOn: $sync)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Create and Mount") { create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(path == nil || model.busy) }
        }.padding(28).frame(width: 530).onAppear { path = initialPath }.interactiveDismissDisabled(model.busy)
    }
    private func create() {
        guard let path, let engine = model.engine else { return }
        do {
            let capacity = try SizeParser.parse(size + unit); var options = FolderOptions(); options.compression = compression; options.sync = sync
            let chosen = options; let label = name.isEmpty ? nil : name
            dismiss()
            Task { await model.perform("Creating and mounting RAM folder…") { let folder = try engine.create(path: path, name: label, capacity: capacity, options: chosen); try engine.mount(folder.id.uuidString) } }
        } catch { model.error = error.localizedDescription }
    }
}
struct AppSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var login = SMAppService.mainApp.status == .enabled
    @ViewState<String?> private var loginError: String?
    var body: some View {
        Form {
            Section("Snapshot storage") {
                Text(model.snapshotStoragePath.isEmpty ? "Storage unavailable" : model.snapshotStoragePath)
                    .font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Choose a parent directory. RAMNest creates a private ‘RAMNest Snapshots’ child and moves all snapshots, journals and folder settings together. A small location record stays in Application Support. Eject every RAM folder and apply option edits first.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Choose / Move Snapshot Storage…") { model.chooseSnapshotStorage() }.disabled(!model.canMoveSnapshotStorage)
                if model.storageManager == nil { Text("Storage selection is unavailable for an explicit --store session.").font(.caption).foregroundStyle(.secondary) }
                if let pending = model.storagePending {
                    Text(pending).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if model.storagePending != nil || model.storageError != nil {
                    Button("Retry Storage Move / Cleanup") { model.retrySnapshotStorage() }.disabled(model.busy || model.dirty)
                }
                if model.movingStorage {
                    if let destination = model.storageDestinationPath { Text("Destination: " + destination).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    ProgressView(); Text(model.progress).font(.caption)
                    Button("Pause Before Commit") { model.cancelSnapshotStorageMove() }
                    Text("Pausing retains both recorded locations. After selection commits, cleanup finishes without cancellation.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
            Picker("Backend for next mount", selection: Binding(get: { model.backend }, set: { model.setBackend($0) })) {
                ForEach(Configuration.Backend.allCases, id: \.self) { backend in Text(backend.displayName).tag(backend) }
            }.disabled(model.busy || model.engine == nil)
            Text("Applies to the next new mount for all folders. Changing this setting leaves running mounts and their helpers unchanged.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.backend == .fskit {
                Text("FSKit requires the FUSE-T extension to be enabled through /Applications/fuse-t.app. New mounts use a private internal location and a symlink at your folder’s original path, including for external-volume folders. RAMNest does not fall back to another backend.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.backendError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Picker("File verification for next mount", selection: Binding(get: { model.fileVerification }, set: { model.setFileVerification($0) })) {
                ForEach(FileVerification.allCases, id: \.self) { policy in Text(policy.displayName).tag(policy) }
            }.disabled(model.busy || model.engine == nil)
            Text("Applies to new mounts for all folders. Running sessions and retained snapshots keep their recorded policy. Size and modification time skips regular-file content SHA-256; an edit with the same size and restored modification time can go undetected. RAM payload corruption can also go undetected when structural decoding succeeds. Bounds, decompression checks, symlinks, extended attributes and control metadata retain their checks.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.fileVerificationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Toggle("Show in menu bar instead of Dock", isOn: Binding(get: { model.menuBarMode }, set: { model.setMenuMode($0) })).disabled(model.busy || model.engine == nil)
            Toggle("Open at login", isOn: $login).disabled(model.busy).onChange(of: login) { _, enabled in
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { loginError = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
            }
            if let loginError { Text(loginError).foregroundStyle(.red) }
            Text("Startup mounting pauses whenever an unfinished session needs recovery.").font(.caption).foregroundStyle(.secondary)
            Button("Install Command Line Tool…") { model.installCLI() }.disabled(model.busy)
            Text("RAMNest has no telemetry, license checks, cloud storage, or automatic updater.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 460)
    }
}
