import SwiftUI
import RAMNestCore

/// An info icon that reveals help text on hover (native tooltip) and to VoiceOver.
/// Use it instead of inline captions so screens stay scannable.
struct InfoTip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Image(systemName: "info.circle")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel("More info")
            .accessibilityHint(text)
            .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// Places an `InfoTip` after the view, aligned to its first text baseline.
    func infoTip(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) { self; InfoTip(text) }
    }
}

/// Bottom bar shown while the app is busy. Mount and eject get a determinate
/// bar and Cancel; other work keeps the small spinner.
struct OperationBar: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            if let op = model.operation {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(op.cancelRequested ? "Cancelling…" : op.message).lineLimit(1)
                        Spacer()
                        Text("Step \(op.completed + 1) of \(op.total)").monospacedDigit().foregroundStyle(.secondary)
                    }.font(.callout)
                    ProgressView(value: op.fraction).animation(.default, value: op.fraction)
                        .accessibilityLabel(op.message)
                        .accessibilityValue("Step \(op.completed + 1) of \(op.total)")
                }
                Button("Cancel") { model.cancelOperation() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!op.cancellable || op.cancelRequested)
                    .help(op.cancellable ? "Stop and leave your folder as it was." : "Can't cancel now. RAMNest is finishing so your files stay consistent.")
            } else {
                ProgressView().controlSize(.small)
                Text(model.progress).lineLimit(1)
                Spacer()
            }
        }
        .padding(12)
        .background(.bar)
    }
}
