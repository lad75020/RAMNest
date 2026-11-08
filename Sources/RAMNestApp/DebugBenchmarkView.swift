#if DEBUG
import SwiftUI
import AppKit
import RAMNestCore

extension AppModel {
    var canStartBenchmark: Bool { !busy && !dirty && selectedStatus?.isReady == true && engine != nil && benchmarkAdmission.current == nil }
    func startBenchmark(_ mode: DebugBenchmarkMode) {
        // Synchronous MainActor admission, before creating a Task or awaiting.
        guard canStartBenchmark, let engine, let id = selectedStatus?.id,
              let generation = benchmarkAdmission.begin() else { return }
        let cancellation = DebugBenchmarkCancellation()
        benchmarkCancellation = cancellation; benchmarkRunning = true; busy = true
        benchmarkReport = nil; benchmarkProgress = nil; progress = "Preparing Debug 1 GB benchmark…"
        benchmarkTask = Task { [self] in
            let report = await Task.detached(priority: .userInitiated) {
                DebugBenchmarkWorker.run(engine: engine, id: id, mode: mode, cancellation: cancellation) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.benchmarkAdmission.current == generation else { return }
                        self.benchmarkProgress = value; self.progress = "\(value.phase): \(value.bytes) / \(value.total) bytes"
                    }
                }
            }.value
            guard benchmarkAdmission.current == generation else { return }
            benchmarkReport = report; benchmarkAdmission.finish(generation)
            benchmarkCancellation = nil; benchmarkTask = nil; benchmarkRunning = false; busy = false; progress = ""
            await refresh()
        }
    }
    func cancelBenchmark() { benchmarkCancellation?.cancel(); progress = "Cancelling benchmark and cleaning owned fixture…" }
    func copyBenchmarkReport() {
        guard let benchmarkReport else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(benchmarkReport.text, forType: .string)
    }
    func exportBenchmarkReport() {
        guard !benchmarkRunning, let benchmarkReport else { return }
        let panel = NSSavePanel(); panel.title = "Export Debug benchmark report and phase log"
        panel.nameFieldStringValue = "RAMNest-debug-\(benchmarkReport.run).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Export takes place after owned-file cleanup and outside measured I/O.
        do {
            let data = url.pathExtension.lowercased() == "txt" ? Data(benchmarkReport.text.utf8) : try benchmarkReport.json()
            guard data.count < 128 * 1024 else { throw NestError("Report exceeds export bound.") }
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}
struct DebugBenchmarkView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var showReport = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Debug I/O · 1 GB = 1,000,000,000 bytes").font(.headline)
            HStack {
                Button("Start 1 GB Write") { model.startBenchmark(.write) }.disabled(!model.canStartBenchmark)
                Button("Start 1 GB Read") { model.startBenchmark(.read) }.disabled(!model.canStartBenchmark)
                Button("Run Both") { model.startBenchmark(.both) }.disabled(!model.canStartBenchmark)
                Button("Cancel") { model.cancelBenchmark() }.disabled(!model.benchmarkRunning)
            }
            Text("Disposable private file on the selected ready mount. Disable periodic save and remount first. Debug timings include profiler overhead; physical cold I/O is not guaranteed.").font(.caption).foregroundStyle(.secondary)
            if let p = model.benchmarkProgress, model.benchmarkRunning {
                ProgressView(p.phase, value: Double(p.bytes), total: Double(p.total))
            }
            if let report = model.benchmarkReport {
                HStack {
                    Text(report.failure == nil ? "Completed · \(report.backend ?? "unknown")" : "Stopped · see report").foregroundStyle(report.failure == nil ? Color.primary : Color.orange)
                    Spacer()
                    Button("Show Report") { showReport = true }
                    Button("Copy Report") { model.copyBenchmarkReport() }
                    Button("Export Report + Log…") { model.exportBenchmarkReport() }
                }
                ForEach(Array(report.phases.enumerated()), id: \.offset) { _, phase in
                    Text("\(phase.phase): \(phase.bytes) bytes · \(phase.decimalMBps.map { String(format: "%.2f MB/s", $0) } ?? "N/A") · verified \(phase.verified ? "yes" : "no")").font(.caption.monospacedDigit())
                }
            }
        }.padding(.horizontal, 22).padding(.bottom, 14)
        .sheet(isPresented: $showReport) {
            VStack {
                ScrollView { Text(model.benchmarkReport?.text ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                Button("Close") { showReport = false }.keyboardShortcut(.cancelAction).padding()
            }.frame(minWidth: 760, minHeight: 540)
        }
    }
}
#endif
