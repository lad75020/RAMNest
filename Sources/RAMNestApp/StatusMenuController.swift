import SwiftUI
import AppKit

/// Native status-item presentation lives outside AppGraph. Toggling Dock/menu
/// mode cannot insert/remove a SwiftUI Scene while its command list is updating.
@MainActor final class StatusMenuController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private var reopenedWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(model: AppModel) { self.model = model }

    func setMenuBarMode(_ enabled: Bool) {
        if enabled && item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item?.button?.image = NSImage(systemSymbolName: "leaf.circle.fill", accessibilityDescription: "RAMNest")
        } else if !enabled, let previous = item {
            NSStatusBar.system.removeStatusItem(previous)
            item = nil
        }
        rebuild()
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
    }

    func rebuild() {
        guard let item else { return }
        let menu = NSMenu(title: "RAMNest")
        for status in model.statuses {
            let row = NSMenuItem(title: status.folder.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: status.folder.name)
            let state = NSMenuItem(title: status.statusTitle, action: nil, keyEquivalent: "")
            state.isEnabled = false; submenu.addItem(state)
            let toggle = action(status.primaryActionTitle, #selector(toggleFolder(_:)))
            toggle.representedObject = status.id.uuidString; toggle.isEnabled = !model.busy && (status.canMount || status.canEject)
            submenu.addItem(toggle)
            if status.canRecover {
                let recover = action("Recover", #selector(recoverFolder(_:)))
                recover.representedObject = status.id.uuidString; recover.isEnabled = !model.busy
                submenu.addItem(recover)
            }
            let open = action("Open in Finder", #selector(openFolder(_:)))
            open.representedObject = status.folder.path; submenu.addItem(open)
            row.submenu = submenu; menu.addItem(row)
        }
        menu.addItem(.separator())
        let create = action("New RAM Folder…", #selector(createFolder))
        create.isEnabled = !model.busy; menu.addItem(create)
        menu.addItem(action("Open RAMNest", #selector(openMainWindow)))
        menu.addItem(action("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(action("Quit RAMNest", #selector(quit)))
        // Respect busy/state flags rather than NSMenu's default responder lookup.
        menu.autoenablesItems = false
        for row in menu.items { row.submenu?.autoenablesItems = false }
        item.menu = menu
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func toggleFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let status = model.statuses.first(where: { $0.id.uuidString == id }) else { return }
        model.mountOrEject(status)
    }
    @objc private func recoverFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let status = model.statuses.first(where: { $0.id.uuidString == id }), status.canRecover else { return }
        model.recover(status)
    }
    @objc private func openFolder(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }
    @objc private func createFolder() { showMainWindow(); model.presentCreate() }
    @objc private func openMainWindow() { showMainWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "RAMNest" && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Accessory apps remain alive after closing their last window. Reopen
        // the same shared model without adding/removing a SwiftUI app Scene.
        let root = ContentView().environmentObject(model).frame(minWidth: 850, minHeight: 610)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "RAMNest"; window.setContentSize(NSSize(width: 1050, height: 740))
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        reopenedWindow = window
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: AppSettingsView().environmentObject(model)))
        window.title = "RAMNest Settings"; window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }
}
