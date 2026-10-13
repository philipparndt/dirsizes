import AppKit
import SwiftUI

/// Full Disk Access: without it, macOS asks about every protected folder the scan reaches
/// (Desktop, Documents, Music, Photos, other apps' data, …), one dialog each.
enum FullDiskAccess {
    /// Reads a file only Full Disk Access unlocks. Unlike opening Desktop or Music, this never
    /// shows a dialog, and the attempt lists DirSizes in System Settings.
    static var isGranted: Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Safari",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return true // none of the probes exist: nothing to tell
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Only an app bundle can be listed in System Settings (not `swift run`).
    static var isBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Some macOS versions apply the permission only to newly started processes.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// Asks for Full Disk Access before scanning, and starts the scan once it is granted.
struct FullDiskAccessSheet: View {
    @Environment(ScanModel.self) private var model
    @State private var waited = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow Full Disk Access")
                        .font(.title2.weight(.semibold))
                    Text("""
                        Without it, macOS asks separately for each protected folder DirSizes reaches \
                        (Desktop, Documents, Music, Photos, other apps' data, …), and folders it \
                        can't read count as hidden space.
                        """)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Click **Open System Settings**.", systemImage: "1.circle")
                Label("Turn on **DirSizes** under Full Disk Access.", systemImage: "2.circle")
                if FullDiskAccess.isBundle {
                    HStack(spacing: 6) {
                        Label("Not in the list? Drag this icon into it:", systemImage: "questionmark.circle")
                        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                            .resizable()
                            .frame(width: 32, height: 32)
                            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                            .help("Drag into the Full Disk Access list")
                    }
                }
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 56)

            HStack {
                if waited >= 5 && FullDiskAccess.isBundle {
                    Button("Quit & Reopen") { FullDiskAccess.relaunch() }
                        .help("Already allowed? Some macOS versions need the app to restart.")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Not Now") { model.declineFullDiskAccess() }
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") {
                    waited = 0
                    FullDiskAccess.openSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            // The scan starts by itself once access is turned on.
            while !Task.isCancelled {
                if FullDiskAccess.isGranted {
                    model.fullDiskAccessGranted()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                waited += 1
            }
        }
    }
}

/// Shown on the start screen while access is off.
struct FullDiskAccessBanner: View {
    @Environment(ScanModel.self) private var model
    @State private var granted = FullDiskAccess.isGranted

    var body: some View {
        Group {
            if !granted {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.lock")
                        .foregroundStyle(.orange)
                    Text("Full Disk Access is off: macOS will ask about protected folders while scanning.")
                        .font(.callout)
                    Spacer()
                    Button("Allow…") { model.requestFullDiskAccess() }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.12)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = FullDiskAccess.isGranted
        }
        .onChange(of: model.asksForFullDiskAccess) {
            granted = FullDiskAccess.isGranted
        }
    }
}
