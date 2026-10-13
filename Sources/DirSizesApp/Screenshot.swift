import AppKit

/// Renders the main window, title bar and toolbar included, into a PNG. Drawn by the app
/// itself, so it needs no Screen Recording permission and nothing else on screen gets in.
@MainActor
enum Screenshot {
    static func save(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            FileHandle.standardError.write(Data("screenshot: no window to capture\n".utf8))
            return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            FileHandle.standardError.write(Data("screenshot: \(error.localizedDescription)\n".utf8))
        }
    }
}
