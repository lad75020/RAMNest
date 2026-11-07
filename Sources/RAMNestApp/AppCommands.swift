import SwiftUI

/// Commands hold a reference for actions, without observing model publication in
/// the App's scene list. ContentView observes it within the window's view graph.
struct RAMNestCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New RAM Folder…") { model.presentCreate() }.keyboardShortcut("n")
        }
        CommandGroup(after: .appSettings) {
            Button("Install Command Line Tool…") { model.installCLI() }
        }
    }
}

