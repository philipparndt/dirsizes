import AppKit
import SwiftUI

@main
struct DirSizesApp: App {
    @State private var model: ScanModel
    private let mcp: DirSizesMCP

    init() {
        // Launched via `swift run` there is no app bundle; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate() }

        let model = ScanModel()
        _model = State(initialValue: model)
        mcp = DirSizesMCP(model: model)
        // A screenshot run quits right away and must not take over a running app's endpoint.
        if UserDefaults.standard.string(forKey: "screenshot") == nil {
            mcp.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(mcp)
                .onAppear {
                    // `DirSizesApp -path <folder>` starts scanning right away. A dash option (read via
                    // the user-defaults argument domain) rather than a bare path: AppKit treats bare
                    // arguments as files to open, and then SwiftUI doesn't open the main window.
                    let defaults = UserDefaults.standard
                    if model.phase == .idle, defaults.bool(forKey: "demo") {
                        model.showDemo()
                    } else if model.phase == .idle, let path = defaults.string(forKey: "path") {
                        model.open(path: path)
                    } else if defaults.string(forKey: "screenshot") == nil {
                        // Ask right away rather than with the first scan's macOS dialogs.
                        model.requestFullDiskAccess()
                    }
                    // `-screenshot <file.png>` saves the window once it has drawn, then quits.
                    if let file = defaults.string(forKey: "screenshot") {
                        Task {
                            // A fixed size, not whatever frame macOS restored for this machine.
                            NSApp.windows.first?.setContentSize(NSSize(width: 1100, height: 700))
                            try? await Task.sleep(for: .seconds(1.5))
                            Screenshot.save(to: file)
                            NSApp.terminate(nil)
                        }
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
