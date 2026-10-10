import AppKit
import SwiftUI

@main
struct DirSizesApp: App {
    @State private var model = ScanModel()

    init() {
        // Launched via `swift run` there is no app bundle; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onAppear {
                    // `DirSizesApp -path <folder>` starts scanning right away. A dash option (read via
                    // the user-defaults argument domain) rather than a bare path: AppKit treats bare
                    // arguments as files to open, and then SwiftUI doesn't open the main window.
                    if model.phase == .idle, let path = UserDefaults.standard.string(forKey: "path") {
                        model.open(path: path)
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
        }
    }
}
