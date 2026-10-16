import SwiftUI

/// Start screen: all mounted disks with their free space, cloud folders, and folder shortcuts.
struct StartView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Choose a disk to scan")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 6)

                FullDiskAccessBanner()

                ForEach(model.volumes) { volume in
                    VolumeCard(volume: volume)
                }

                if model.cloudFolders.contains(where: \.isICloud) {
                    ICloudCard()
                }

                ForEach(model.cloudFolders.filter { !$0.isICloud }) { folder in
                    CloudCard(folder: folder)
                }

                PhotosCard()

                HStack(spacing: 12) {
                    Button("Scan Folder…", systemImage: "folder") { model.chooseFolder() }
                    Button("Home Folder", systemImage: "house") {
                        model.scan(path: NSHomeDirectory())
                    }
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            .frame(maxWidth: 620)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.loadVolumes() }
    }
}

private struct VolumeCard: View {
    @Environment(ScanModel.self) private var model
    let volume: VolumeInfo
    @State private var isHovered = false

    init(volume: VolumeInfo) {
        self.volume = volume
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ScanButton(prominent: true, help: model.scanHelp(volume.scanPath)) {
                    model.scan(volume: volume)
                } menu: {
                    Button("Clean Scan") { model.scan(volume: volume, full: true) }
                }
            }

            CapacityBar(fraction: volume.usedFraction)
                .frame(height: 10)

            HStack {
                Text("\(formatBytes(volume.usedBytes)) used")
                if let date = model.savedScanDates[volume.scanPath] {
                    Text("· last scanned \(date, format: .relative(presentation: .named))")
                }
                Spacer()
                Text("\(formatBytes(volume.availableBytes)) free of \(formatBytes(volume.totalBytes))")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(isHovered ? 0.9 : 0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { scan() }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(volume.url.path)
    }

    private func scan() {
        model.scan(volume: volume)
    }

    private var icon: String {
        switch volume.kind {
        case .internalDisk: "internaldrive.fill"
        case .externalDisk: "externaldrive.fill"
        case .network: "externaldrive.connected.to.line.below.fill"
        }
    }

    private var subtitle: String {
        let kind = switch volume.kind {
        case .internalDisk: "Internal"
        case .externalDisk: "External"
        case .network: "Network"
        }
        return volume.format.isEmpty ? kind : "\(kind) · \(volume.format)"
    }
}

/// iCloud Drive or another cloud folder: what it takes up on this Mac. There's no total before
/// a scan; files only in the cloud take no space here.
private struct CloudCard: View {
    @Environment(ScanModel.self) private var model
    let folder: CloudFolder
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text("Downloaded files on this Mac")
                    if let date = model.savedScanDates[folder.path] {
                        Text("· last scanned \(date, format: .relative(presentation: .named))")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ScanButton(prominent: false, help: model.scanHelp(folder.path)) {
                scan()
            } menu: {
                Button("Clean Scan") { model.scan(path: folder.path, full: true) }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(isHovered ? 0.9 : 0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { scan() }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(folder.path)
    }

    private func scan() {
        model.scan(path: folder.path)
    }
}

/// iCloud, like a disk: how full the plan is (after signing in to iCloud.com), and a scan that
/// charts all of it, with iCloud Drive's files and the other categories (Photos, Backups, …)
/// around them.
private struct ICloudCard: View {
    @Environment(ScanModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        let storage = model.iCloudStorage
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud")
                        .font(.headline)
                    Text(subtitle(storage.state))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch storage.state {
                case .signedOut, .failed:
                    Button("Sign In…") { storage.signIn() }
                        .controlSize(.large)
                        .help("Sign in to iCloud.com to see Photos, Backups, Mail and the rest, not just iCloud Drive")
                case .loading, .signingIn:
                    ProgressView().controlSize(.small)
                case .loaded:
                    EmptyView()
                }
                ScanButton(prominent: true, help: scanHelp) {
                    scan()
                } menu: {
                    Button("Only Files on This Mac") { model.scan(path: CloudFolder.iCloudPath, full: true) }
                    Divider()
                    Button("iCloud in System Settings") { CloudFolder.openICloudSettings() }
                    if case .loaded = storage.state {
                        Button("Reload iCloud Numbers") { storage.refresh(interactive: true) }
                        Button("Sign Out of iCloud.com") { storage.signOut() }
                    }
                }
            }

            if case .loaded(let usage, _, _) = storage.state {
                let totals = usage.storageUsageInfo
                CapacityBar(fraction: Double(totals.usedStorageInBytes) / Double(max(totals.totalStorageInBytes, 1)))
                    .frame(height: 10)
                HStack {
                    Text("\(formatBytes(totals.usedStorageInBytes)) used")
                    Spacer()
                    Text("\(formatBytes(max(totals.totalStorageInBytes - totals.usedStorageInBytes, 0))) free of "
                         + formatBytes(totals.totalStorageInBytes))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(isHovered ? 0.9 : 0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { scan() }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onAppear {
            if case .signedOut = storage.state, storage.wasSignedIn { storage.refresh(interactive: false) }
        }
    }

    private func subtitle(_ state: ICloudStorage.State) -> String {
        switch state {
        case .signedOut: "iCloud Drive, also files not on this Mac · sign in for Photos, Backups, Mail and more"
        case .loading: "Loading…"
        case .signingIn: "Sign in to iCloud in the window that opened"
        case .loaded(_, let account, _): account ?? "Signed in to iCloud.com"
        case .failed(let message): message
        }
    }

    private var scanHelp: String {
        if case .loaded = model.iCloudStorage.state {
            return "Chart all of iCloud: iCloud Drive file by file, and Photos, Backups, Mail and the rest. Nothing is downloaded."
        }
        return "Read all of iCloud Drive, counting files only in iCloud at their size. Nothing is downloaded."
    }

    private func scan() {
        model.scan(path: CloudFolder.iCloudPath, countingCloudFiles: true)
    }
}

/// "Scan", with other ways to scan (such as Clean Scan) in a menu next to it.
private struct ScanButton<MenuItems: View>: View {
    let prominent: Bool
    let help: String
    let scan: () -> Void
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        // Built by hand: the system split button draws a round highlight around the open menu half.
        HStack(spacing: 0) {
            Button("Scan", action: scan)
                .buttonStyle(SegmentStyle())
                .help(help)
            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 16)
            Menu(content: menu) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(SegmentStyle(horizontalPadding: 10))
            .fixedSize()
        }
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
        .clipShape(Capsule())
        .fixedSize()
    }

    /// One half of the split button: no background of its own, slightly dimmed while pressed.
    private struct SegmentStyle: ButtonStyle {
        var horizontalPadding: CGFloat = 16

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                .frame(height: 30)
                .contentShape(Rectangle())
                .background(configuration.isPressed ? Color.black.opacity(0.15) : .clear)
        }
    }
}

/// Used-space bar; turns orange and red as the disk fills up.
private struct CapacityBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(proxy.size.width * fraction, proxy.size.height))
            }
        }
    }

    private var colors: [Color] {
        switch fraction {
        case ..<0.75: [.blue, .purple]
        case ..<0.9: [.purple, .orange]
        default: [.orange, .red]
        }
    }
}
