import DirScanner
import SwiftUI

struct ContentView: View {
    @Environment(ScanModel.self) private var model
    @State private var showsMCPSetup = false

    var body: some View {
        // A plain VStack rather than safeAreaInset: HSplitView ignores safe-area insets, which let
        // the chart extend underneath the status bar.
        VStack(spacing: 0) {
            if model.tree == nil {
                EmptyState()
            } else if model.showsCollectorReview {
                CollectorReviewView()
            } else if model.showsCleanup {
                CleanupView()
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        Breadcrumbs()
                        SunburstView()
                            .padding(8)
                    }
                    .frame(minWidth: 480)
                    // Drag the divider to give the collector more room.
                    VSplitView {
                        ChildList()
                            .frame(minHeight: 120)
                        CollectorView()
                            .frame(minHeight: 150, idealHeight: 240)
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                }
                CleanupSummary()
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: Binding(get: { model.asksForFullDiskAccess },
                                    set: { if !$0 && model.asksForFullDiskAccess { model.declineFullDiskAccess() } })) {
            FullDiskAccessSheet()
        }
        .alert("Some items could not be deleted", isPresented: Binding(
            get: { !model.deletionErrors.isEmpty },
            set: { if !$0 { model.deletionErrors = [] } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.deletionErrors.joined(separator: "\n"))
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Disks", systemImage: "internaldrive") { model.showStart() }
                    .help("Show all disks")
                    .disabled(model.rootPath == nil)
                Button("Up", systemImage: "chevron.up") { model.zoomOut() }
                    .disabled(model.center == 0)
                if model.phase == .scanning {
                    Button("Stop", systemImage: "stop.fill") { model.stop() }
                } else {
                    // ⌥ switches between an update (the default; full scans on external drives) and the other.
                    let full = model.prefersFullScan(model.rootPath ?? "") != ModifierKeys.shared.option
                    Button(full ? "Full Rescan" : "Rescan", systemImage: full ? "arrow.clockwise.circle" : "arrow.clockwise") {
                        model.rescan(full: full)
                    }
                    .help(full ? "Read everything again (⌥ to only read what changed)"
                               : "Update with what changed since the last scan (⌥ for a full rescan)")
                    .disabled(model.rootPath == nil)
                }
                Button("Open…", systemImage: "folder") { model.chooseFolder() }
                Button("Cleanup", systemImage: "lightbulb") { model.showCleanup() }
                    .help("Find what uninstalled apps left behind, unused apps, developer caches, old downloads, duplicates, and what grew since an earlier scan")
                    .disabled(model.tree == nil || model.phase == .scanning)
                Button("Use with Claude", systemImage: "sparkles") { showsMCPSetup.toggle() }
                    .help("Connect Claude Code to DirSizes")
                    .popover(isPresented: $showsMCPSetup, arrowEdge: .bottom) { MCPSetupView() }
            }
        }
        .navigationTitle(model.rootPath == nil ? "DirSizes" : model.rootName)
    }
}

private struct EmptyState: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            if model.phase == .scanning {
                ScanProgressView()
            } else {
                StartView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Breadcrumbs: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        if let tree = model.tree {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    Button("Disks", systemImage: "internaldrive") { model.showStart() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Show all disks")
                    ForEach(tree.ancestry(of: model.center), id: \.self) { node in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button(node == 0
                               ? (model.iCloudUsage != nil ? model.rootName : nil) ?? model.scannedVolume?.name
                                   ?? CloudFolder.displayName(ofPath: tree.path(of: 0)) ?? tree.path(of: 0)
                               : model.displayName(of: node)) {
                            model.zoom(to: node)
                        }
                            .buttonStyle(.plain)
                            .foregroundStyle(node == model.center ? .primary : .secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct ChildList: View {
    @Environment(ScanModel.self) private var model

    /// A file or folder, or space that isn't one (free, hidden, iCloud categories) at the root.
    private enum Row: Hashable {
        case node(Int32)
        case special(SpecialSpace)
    }

    var body: some View {
        if let tree = model.tree {
            let extras = model.center == 0 ? model.extras : []
            let bytes = Dictionary(extras, uniquingKeysWith: { a, _ in a })
            let parentSize = max(tree.nodes[Int(model.center)].size + extras.reduce(0) { $0 + $1.1 }, 1)
            let rows = (tree.children(of: model.center).prefix(500).map(Row.node)
                        + extras.filter { $0.1 > 0 }.map { Row.special($0.0) })
                .sorted { size(of: $0, tree: tree, extras: bytes) > size(of: $1, tree: tree, extras: bytes) }
            List(rows, id: \.self) { row in
                switch row {
                case .node(let child):
                    nodeRow(child, tree: tree, parentSize: parentSize)
                case .special(let kind):
                    SpecialRow(kind: kind, bytes: bytes[kind] ?? 0,
                               fraction: Double(bytes[kind] ?? 0) / Double(parentSize))
                }
            }
        }
    }

    private func size(of row: Row, tree: FileTree, extras: [SpecialSpace: Int64]) -> Int64 {
        switch row {
        case .node(let node): tree.nodes[Int(node)].size
        case .special(let kind): extras[kind] ?? 0
        }
    }

    private func nodeRow(_ child: Int32, tree: FileTree, parentSize: Int64) -> some View {
        let node = tree.nodes[Int(child)]
        return ChildRow(name: model.displayName(of: child), node: node,
                        fraction: Double(node.size) / Double(parentSize),
                        highlighted: model.hovered == child, gone: model.isGone(child))
            .contentShape(Rectangle())
            .onTapGesture { model.zoom(to: child) }
            .onHover { inside in model.hovered = inside ? child : nil }
            .opacity(model.isCollected(child) ? 0.45 : 1)
            .draggable(URL(fileURLWithPath: tree.path(of: child)))
            .contextMenu {
                NodeMenu(node: child)
            }
    }
}

/// Free or hidden space, or an iCloud category: there are no files to list, so expanding it
/// shows what is known about it instead.
private struct SpecialRow: View {
    @Environment(ScanModel.self) private var model
    let kind: SpecialSpace
    let bytes: Int64
    let fraction: Double
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            SpecialDetails(kind: kind)
                .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .frame(width: 16)
                    Text(model.label(of: kind))
                        .lineLimit(1)
                    Spacer()
                    Text(formatBytes(bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint.opacity(0.6))
                        .frame(width: max(proxy.size.width * fraction, 1))
                }
                .frame(height: 3)
            }
            .padding(.vertical, 2)
            // Only the title line: the details below aren't part of the highlight.
            .background(model.hoveredSpecial == kind ? Color.accentColor.opacity(0.12) : .clear)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .onHover { inside in
                if inside { model.hoveredSpecial = kind } else if model.hoveredSpecial == kind { model.hoveredSpecial = nil }
            }
        }
    }

    private var tint: Color {
        switch kind {
        case .free: .secondary
        case .hidden: .gray
        case .iCloud, .photosInCloud: model.color(of: kind) ?? .gray
        }
    }

    private var icon: String {
        switch kind {
        case .free: "circle.dashed"
        case .hidden: "eye.slash"
        case .iCloud(let key):
            switch key {
            case "photos": "photo.on.rectangle"
            case "backup": "arrow.clockwise.icloud"
            case "mail": "envelope"
            case "messages": "message"
            case "family": "person.2"
            case "docs": "doc.on.doc"
            default: "icloud"
            }
        case .photosInCloud: "icloud"
        }
    }
}

/// What DirSizes knows about space it can't list as files.
private struct SpecialDetails: View {
    @Environment(ScanModel.self) private var model
    let kind: SpecialSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .free:
                note(model.iCloudUsage != nil ? "Left in your iCloud plan." : "Available on \(model.rootName).")
            case .hidden:
                note("Used on the disk, but not seen by the scan: the system volume, APFS snapshots (Time Machine), "
                     + "swap and sleep image, and folders DirSizes couldn't read.")
                HiddenDetails()
                let unreadable = model.unreadableFolders
                if !unreadable.isEmpty {
                    note("\(unreadable.count.formatted()) folders couldn't be read. \(model.unreadableHint)")
                    if !FullDiskAccess.isGranted {
                        Button("Open Full Disk Access Settings") { FullDiskAccess.openSettings() }
                            .buttonStyle(.link)
                    }
                    UnreadableList(paths: unreadable)
                }
            case .iCloud("docs"):
                note("In iCloud under Documents, but not as files in iCloud Drive: app data apps keep in iCloud, "
                     + "Recently Deleted, and versions of documents.")
            case .iCloud("photos"):
                if let library = model.photosLibrary, library.tree == nil {
                    note("Can't read \((library.path as NSString).lastPathComponent) to chart what of it is on this Mac: "
                         + "Photos libraries are protected. Allow DirSizes Full Disk Access, then scan again.")
                    Button("Open Full Disk Access Settings") { FullDiskAccess.openSettings() }
                        .buttonStyle(.link)
                    Divider()
                }
                PhotosDetails()
            case .photosInCloud:
                note("What iCloud stores for Photos beyond the library on this Mac (\"Photos on this Mac\"): "
                     + "originals that aren't downloaded. Can be 0 when everything is downloaded; the library "
                     + "also holds previews, so it can be larger than what iCloud counts.")
                PhotosDetails()
            case .iCloud(let key):
                if let members = familyMembers(for: key) {
                    ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                        detail(member.name.isEmpty ? "Family member" : member.name, member.usageInBytes,
                               icon: "person.crop.circle")
                    }
                } else {
                    note("Stored by \(model.label(of: kind)) in iCloud. iCloud.com doesn't say what's inside; "
                         + "System Settings lists it by app and device under iCloud → Manage….")
                    Button("iCloud in System Settings") { CloudFolder.openICloudSettings() }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
    }

    /// Family Sharing's usage per person, shown under the family category.
    private func familyMembers(for key: String) -> [ICloudStorage.Usage.Family.Member]? {
        guard key.contains("family"),
              let members = model.iCloudUsage?.familyStorageUsageInfo?.storageUsageByMember, !members.isEmpty
        else { return nil }
        return members.sorted { $0.usageInBytes > $1.usageInBytes }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The hidden space by what it is: the disk's other volumes, and the rest, which is in the
/// scanned volume but not in its files.
private struct HiddenDetails: View {
    @Environment(ScanModel.self) private var model
    @State private var confirmsDeletion = false
    @State private var deleting = false
    @State private var error: String?

    var body: some View {
        Group {
            if let hidden = model.hiddenSpace {
                ForEach(hidden.volumes) { part in
                    detail(part.name, part.bytes, icon: part.icon)
                        .help(part.note)
                }
                let total = model.extras.first { $0.0 == .hidden }?.1 ?? 0
                detail("Snapshots and unread folders", max(total - hidden.volumesTotal, 0), icon: "eye.slash")
                    .help("In \(model.rootName) but not in its files: local snapshots, folders that couldn't be read, "
                          + "and file system data. Estimated as what's left.")
                if let swap = hidden.swapUsed, swap > 0 {
                    note("Swap in use now: \(formatBytes(swap)).")
                }
                if let oldest = hidden.snapshots.first {
                    note("\(hidden.snapshots.count) local Time Machine \(hidden.snapshots.count == 1 ? "snapshot" : "snapshots"), "
                         + "the oldest from \(oldest.formatted(.relative(presentation: .named))). They keep earlier versions "
                         + "of your files until the next backup; macOS deletes them on its own when space runs low, "
                         + "and counts them as free space.")
                    Button(deleting ? "Deleting Snapshots…" : "Delete Local Snapshots…") { confirmsDeletion = true }
                        .buttonStyle(.link)
                        .disabled(deleting)
                        .confirmationDialog("Delete all local Time Machine snapshots?", isPresented: $confirmsDeletion) {
                            Button("Delete Snapshots", role: .destructive) {
                                deleting = true
                                Task {
                                    error = await model.deleteLocalSnapshots()
                                    deleting = false
                                }
                            }
                        } message: {
                            Text("Backups on your Time Machine disk aren't affected. Until the next backup, earlier versions "
                                 + "of files changed since the last one can't be restored. Asks for an administrator password.")
                        }
                }
                if let error {
                    note(error)
                }
            } else if model.loadingHiddenSpace {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { model.loadHiddenSpace() }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The folders a scan couldn't open, collapsed by default (there can be hundreds).
private struct UnreadableList: View {
    let paths: [String]
    @State private var expanded = false

    private static let shown = 100

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(paths.prefix(Self.shown), id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                }
                if paths.count > Self.shown {
                    Text("and \((paths.count - Self.shown).formatted()) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("Unreadable folders")
                .foregroundStyle(.secondary)
        }
    }
}

/// Photos in iCloud: split into photos and videos once the library was counted.
private struct PhotosDetails: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        switch model.photos.state {
        case .done(let summary):
            detail("\(summary.photos.count.formatted()) photos", summary.photos.bytes, icon: "photo")
            detail("\(summary.videos.count.formatted()) videos", summary.videos.bytes, icon: "video")
            if summary.other.count > 0 {
                detail("\(summary.other.count.formatted()) other", summary.other.bytes, icon: "doc")
            }
            Text("Counted in your Photos library (an estimate).")
                .foregroundStyle(.secondary)
        case .counting(let done, let total):
            HStack {
                ProgressView().controlSize(.small)
                Text(total > 0 ? "Counting \(done.formatted()) of \(total.formatted())…" : "Counting…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .denied:
            Text("No access to Photos. Allow it in System Settings → Privacy & Security → Photos.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            Text("Count your Photos library to split this into photos and videos.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Count Photos Library") { model.photos.count() }
        }
    }
}

private func detail(_ name: String, _ bytes: Int64, icon: String) -> some View {
    HStack {
        Image(systemName: icon)
            .foregroundStyle(.secondary)
            .frame(width: 16)
        Text(name)
        Spacer()
        Text(formatBytes(bytes))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

private struct ChildRow: View {
    let name: String
    let node: Node
    let fraction: Double
    let highlighted: Bool
    /// Deleted by another app since the scan.
    let gone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(node.isDirectory && !gone ? Color.accentColor : .secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(gone ? .secondary : .primary)
                    .strikethrough(gone)
                Spacer()
                Text(formatBytes(node.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(gone ? Color.gray.opacity(0.5) : Color.accentColor.opacity(0.6))
                    .frame(width: max(proxy.size.width * fraction, 1))
            }
            .frame(height: 3)
        }
        .padding(.vertical, 2)
        .background(highlighted ? Color.accentColor.opacity(0.12) : .clear)
        .help(gone ? "Deleted outside DirSizes since the scan" : "")
    }
}

private struct StatusBar: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        HStack {
            switch model.phase {
            case .idle:
                Text("Ready")
            case .scanning:
                ProgressView().controlSize(.small)
                Text("Scanning…")
            case .done:
                let seconds = Double(model.duration.components.seconds)
                    + Double(model.duration.components.attoseconds) / 1e18
                Text("\(model.filesScanned.formatted()) files, \(formatBytes(model.tree?.root.size ?? 0)) in "
                     + String(format: "%.1f s", seconds))
                if let cloud = model.bytesInCloud(0) {
                    Text("· \(formatBytes(cloud)) only in iCloud")
                        .help("Files not downloaded to this Mac, shown see-through. They take space in iCloud, not here.")
                }
                if let changed = model.changedFolders {
                    Text("· updated \(changed == 1 ? "1 changed folder" : "\(changed.formatted()) changed folders")")
                        .help("Only folders that changed since the last scan were read again. ⌥ turns Rescan into Full Rescan.")
                }
                if model.errors > 0 {
                    Text("· \(model.errors) unreadable")
                        .help(model.unreadableHint)
                }
                let gone = model.goneSummary
                if gone.count > 0 {
                    Text("· \(gone.count == 1 ? "1 item" : "\(gone.count) items") (\(formatBytes(gone.bytes))) deleted elsewhere")
                        .help("Deleted by another app since the scan. Shown in gray; rescan to update the totals.")
                    Button("Rescan") { model.rescan() }
                        .buttonStyle(.link)
                }
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Context menu shared by the chart and the list.
struct NodeMenu: View {
    @Environment(ScanModel.self) private var model
    let node: Int32

    var body: some View {
        Button("Add to Collector") { model.collect(node) }
            .disabled(node == 0 || model.isCollected(node))
        Button("Reveal in Finder") { model.revealInFinder(node) }
        Divider()
        Button("Copy Name") { model.copyName(of: node) }
        Button("Copy Full Path") { model.copyPath(of: node) }
    }
}
