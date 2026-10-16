import AppKit
import Observation

/// Whether ⌥ is held, for buttons that turn into their "full" variant (Scan → Full Scan).
@MainActor @Observable
final class ModifierKeys {
    static let shared = ModifierKeys()

    private(set) var option = false

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { ModifierKeys.shared.option = event.modifierFlags.contains(.option) }
            return event
        }
        // A key released while another app was active never reaches the monitor.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModifierKeys.shared.option = NSEvent.modifierFlags.contains(.option) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModifierKeys.shared.option = false }
        }
    }
}
