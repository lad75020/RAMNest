import SwiftUI
import AppKit
import Combine

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    // A scene rebuild must never construct a second repository model or own its
    // lifecycle. The application delegate owns this one instance until exit.
    let model = AppModel()
    private var subscriptions = Set<AnyCancellable>()
    private var statusMenu: StatusMenuController?
    private var didStart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didStart else { return }
        didStart = true
        // Finish the first scene/command transaction before activating windows,
        // installing the status item, or publishing asynchronous startup state.
        DispatchQueue.main.async { [weak self] in self?.finishLaunch() }
    }

    private func finishLaunch() {
        let menu = StatusMenuController(model: model)
        statusMenu = menu
        model.$menuBarMode.removeDuplicates().receive(on: RunLoop.main).sink { [weak menu] enabled in
            menu?.setMenuBarMode(enabled)
        }.store(in: &subscriptions)
        model.$statuses.receive(on: RunLoop.main).sink { [weak menu] _ in menu?.rebuild() }.store(in: &subscriptions)
        model.$busy.removeDuplicates().receive(on: RunLoop.main).sink { [weak menu] _ in menu?.rebuild() }.store(in: &subscriptions)
        model.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { let allow = await model.quit(); sender.reply(toApplicationShouldTerminate: allow) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !model.menuBarMode }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { statusMenu?.showMainWindow(); model.presentCreate(url) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { statusMenu?.showMainWindow() }
        return true
    }
}

struct RAMNestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("RAMNest") {
            ContentView().environmentObject(delegate.model)
                .frame(minWidth: 850, minHeight: 610)
        }
        .defaultSize(width: 1050, height: 740)
        .commands { RAMNestCommands(model: delegate.model) }
        Settings { AppSettingsView().environmentObject(delegate.model) }
    }
}
