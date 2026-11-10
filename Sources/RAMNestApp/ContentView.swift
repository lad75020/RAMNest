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
                    HStack { Text("System memory").infoTip("Folder capacity is a ceiling, not a reservation. RAM use grows only as you add files."); Spacer(); Text("\(Int(model.memoryUsed * 100))%").monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: model.memoryUsed).tint(model.memoryUsed > 0.85 ? .orange : .green)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 245, ideal: 270)
        } detail: {
            if let status = model.selectedStatus {
                FolderDetail(status: status)
            }
            else {
                ContentUnavailableView {
                    Label("Make space for your work", systemImage: "leaf.circle")
                } description: { Text("Run any folder from RAM. Its files stay protected by a verified snapshot.") } actions: { Button("New RAM Folder…") { model.presentCreate() }.buttonStyle(.borderedProminent) }
            }
        }
        .toolbar {
            ToolbarItemGroup { Button { model.presentCreate() } label: { Label("New RAM Folder", systemImage: "plus") }.keyboardShortcut("n"); Button { model.remove() } label: { Label("Remove", systemImage: "trash") }.disabled(model.selected == nil || model.busy); SettingsLink { Image(systemName: "gearshape") } }
        }
        .safeAreaInset(edge: .bottom) {
            if model.busy { OperationBar() }
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
                        TextField("Display name", text: Binding(get: { model.draft?.name ?? status.folder.name }, set: { model.draft?.name = $0 })).font(.largeTitle.bold()).textFieldStyle(.plain).help("Shown in RAMNest only. The folder path doesn't change.")
                        Button(status.folder.path) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: status.folder.path) }.buttonStyle(.link).lineLimit(2).font(.callout)
                        Label(status.statusTitle, systemImage: status.needsAttention ? "exclamationmark.triangle" : status.isReady ? "circle.fill" : "circle").font(.caption).foregroundStyle(status.isReady ? Color.green : status.needsAttention ? Color.orange : Color.secondary)
                        if let caption = model.backendCaption(for: status) { Text(caption).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(status.primaryActionTitle) { model.mountOrEject(status) }.buttonStyle(.borderedProminent).tint(status.needsAttention ? .orange : .green).disabled(model.busy || !(status.canMount || status.canEject))
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("\(formatted(status.used)) used").font(.headline).infoTip("Includes filesystem metadata and open files. This isn't the same as physical RAM; macOS handles compression and swap.")
                            Spacer()
                            Button("of \(formatted(status.folder.capacity)) 􀈊") { model.resize() }.buttonStyle(.link).help("Change capacity. Eject first.").disabled(!status.canResize || model.busy)
                        }
                        ProgressView(value: Double(status.used), total: Double(status.folder.capacity)).tint(.green)
                        if let capacity = status.nativeCapacityBytes { metric("Capacity reported by macOS", capacity) }
                    }.padding(10)
                }
                if let blocker = status.snapshotBlocker { Label(blocker, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let loss = status.journal.nativeTmpfs?.lossDisclosure { Label(loss, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let error = status.journal.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let warning = status.journal.cleanupWarning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let notice = status.journal.reviewedRecoveryNotice, status.journal.cleanupWarning != notice {
                    Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
                if status.journal.reviewedRecoveryNotice != nil {
                    Text("Retained snapshots: \(model.snapshotStoragePath)").font(.caption).textSelection(.enabled)
                }
                if status.canReviewLegacyPublication {
                    Label("Part of this folder's history was never recorded. Review the evidence to finish recovery.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    Button("Review Legacy Recovery…", systemImage: "doc.text.magnifyingglass") { model.reviewLegacyRecovery() }.disabled(model.busy)
                }
                HStack {
                    if status.journal.nativeTmpfs != nil && status.mounted && !status.connected && status.journal.phase == .mounted {
                        Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") { model.reconnect(status) }.disabled(model.busy)
                    }
                    Button("Save Snapshot", systemImage: "square.and.arrow.down") { model.save() }.disabled(!status.canSave || model.busy)
                    Button("Export Snapshot…", systemImage: "arrow.up.doc") { model.exportSnapshot() }.disabled(status.journal.revision == nil || model.busy)
                    Button("Recover", systemImage: "arrow.counterclockwise") { model.recover() }.disabled(!status.canRecover || model.busy)
                    if status.journal.nativeTmpfs != nil { InfoTip("Close all files in this folder before saving or ejecting. RAMNest can't save while files are open or memory-mapped, even if you eject anyway.") }
                }
                Divider()
                HStack { Text("Options").font(.title3.bold()); Spacer(); Picker("Options", selection: $tab) { Text("Normal").tag(0); Text("Advanced").tag(1) }.pickerStyle(.segmented).frame(width: 230) }
                VStack(alignment: .leading, spacing: 16) {
                    if tab == 0 {
                        Toggle("Mount at app launch", isOn: option(\.mountAtLaunch, fallback: true))
                        Toggle("Hide from Desktop and Finder sidebar", isOn: option(\.nobrowse, fallback: true))
                        Toggle("Save changes when ejecting", isOn: option(\.sync, fallback: true)).infoTip("On: eject writes your RAM changes back to the folder.\nOff (temporary): each mount starts from the original files and eject discards changes.")
                        Toggle("Save a snapshot periodically", isOn: option(\.periodicSave, fallback: false)).disabled(model.draft?.options.sync == false || status.snapshotBlocker != nil)
                        Picker("Save every", selection: option(\.intervalMinutes, fallback: 15)) { ForEach(FolderOptions.intervals, id: \.self) { Text($0 < 60 ? "\($0) minutes" : "\($0 / 60) hours").tag($0) } }.frame(maxWidth: 340).disabled(model.draft?.options.sync == false || model.draft?.options.periodicSave == false || status.snapshotBlocker != nil)
                    } else {
                        Picker(selection: option(\.comparison, fallback: .sizeAndModTime)) { Text("Size & modification time").tag(Comparison.sizeAndModTime); Text("File checksum").tag(Comparison.checksum) } label: {
                            Text("Snapshot comparison").infoTip("How snapshots find changed files. File verification for future mounts is set in Settings.")
                        }.frame(maxWidth: 430)
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
    @ViewState<Bool> private var sync = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("New RAM folder", systemImage: "folder.badge.plus").font(.title2.bold()).infoTip("The folder keeps its usual path. RAMNest verifies a snapshot before moving any files.")
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Mount at").font(.caption); Text(path?.path ?? "Choose an existing folder").lineLimit(3).textSelection(.enabled) }; Spacer(); Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { path = panel.url } } }
            TextField("Display name (optional)", text: $name).help("Shown in RAMNest only. The folder path doesn't change.")
            HStack { Text("Capacity").infoTip("16 MiB to \(formatted(ProcessInfo.processInfo.physicalMemory / 4 * 3)). Memory isn't reserved up front."); TextField("4", text: $size).frame(width: 100); Picker("Unit", selection: $unit) { Text("MB").tag("MB"); Text("GB").tag("GB") }.labelsHidden().frame(width: 100) }
            Toggle("Save changes on eject", isOn: $sync).infoTip("Off (temporary): eject restores the original folder and discards RAM changes.")
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Create and Mount") { create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(path == nil || model.busy) }
        }.padding(28).frame(width: 530).onAppear { path = initialPath }.interactiveDismissDisabled(model.busy)
    }
    private func create() {
        guard let path, let engine = model.engine else { return }
        do {
            let capacity = try SizeParser.parse(size + unit); var options = FolderOptions(); options.sync = sync
            let chosen = options; let label = name.isEmpty ? nil : name
            dismiss()
            Task {
                await model.performTracked("Creating RAM folder…", steps: 1 + Engine.progressSteps(mounting: true)) { progress in
                    try progress.step("Creating RAM folder…", cancellable: true)
                    let folder = try engine.create(path: path, name: label, capacity: capacity, options: chosen)
                    try engine.mount(folder.id.uuidString, progress: progress)
                }
            }
        } catch { model.error = error.localizedDescription }
    }
}
struct AppSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var login = SMAppService.mainApp.status == .enabled
    @ViewState<String?> private var loginError: String?
    var body: some View {
        ScrollView {
          Form {
            Section {
                Text(model.snapshotStoragePath.isEmpty ? "Storage unavailable" : model.snapshotStoragePath)
                    .font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Move Snapshot Storage…") { model.chooseSnapshotStorage() }.disabled(!model.canMoveSnapshotStorage)
                    Button("Clean Snapshot Folder…", systemImage: "bubbles.and.sparkles", role: .destructive) { model.confirmCleanSnapshots() }
                        .disabled(!model.canCleanSnapshots)
                        .infoTip("Deletes snapshots of folders that aren't mounted and of folders removed from RAMNest. Original folders aren't touched.")
                }
                if let result = model.cleanSnapshotsResult { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
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
                    Button("Pause Before Commit") { model.cancelSnapshotStorageMove() }.infoTip("Keeps both locations. Once the move commits, cleanup finishes and can't be paused.")
                }
                if let error = model.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            } header: {
                Text("Snapshot storage").infoTip("RAMNest creates a private ‘RAMNest Snapshots’ folder in the location you choose and moves snapshots, journals and settings there. Eject all folders and apply option edits first.")
            }
            Section {
                Button(model.resetButtonTitle, role: .destructive) { model.confirmReset() }.disabled(!model.canReset)
                if model.resetting { ProgressView(); Text(model.progress).font(.caption) }
                if let error = model.resetError { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            } header: {
                Text("Reset").infoTip("Ejects all RAM folders, permanently deletes their records and every saved snapshot, then restarts RAMNest. Saving folders save first; temporary folders discard RAM changes. Your original folders are kept.")
            }
            LabeledContent { Text("Native macOS tmpfs") } label: {
                Text("Storage engine").infoTip("Each mount asks for administrator approval. No background service or FUSE is installed.")
            }
            Picker(selection: Binding(get: { model.fileVerification }, set: { model.setFileVerification($0) })) {
                ForEach(FileVerification.allCases, id: \.self) { policy in Text(policy.displayName).tag(policy) }
            } label: {
                Text("File verification for next mount").infoTip("Applies to new mounts of every folder. SHA-256 checks file contents. Size and modification time is faster but can miss an edit that keeps both unchanged.")
            }.disabled(model.busy || model.engine == nil)
            if let error = model.fileVerificationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Toggle("Show in menu bar instead of Dock", isOn: Binding(get: { model.menuBarMode }, set: { model.setMenuMode($0) })).disabled(model.busy || model.engine == nil)
            Toggle(isOn: $login) { Text("Open at login").infoTip("Folders set to mount at launch wait if a previous session needs recovery.") }.disabled(model.busy).onChange(of: login) { _, enabled in
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { loginError = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
            }
            if let loginError { Text(loginError).foregroundStyle(.red) }
            Button("Install Command Line Tool…") { model.installCLI() }.disabled(model.busy)
          }.padding(24)
        }.frame(width: 500, height: 720)
    }
}
