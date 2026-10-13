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
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        Breadcrumbs()
                        SunburstView()
                            .padding(8)
                    }
                    .frame(minWidth: 480)
                    VStack(spacing: 0) {
                        ChildList()
                        Divider()
                        CollectorView()
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                }
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 820, minHeight: 560)
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
                    Button("Rescan", systemImage: "arrow.clockwise") { model.rescan() }
                        .disabled(model.rootPath == nil)
                }
                Button("Open…", systemImage: "folder") { model.chooseFolder() }
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
                    ForEach(tree.ancestry(of: model.center), id: \.self) { node in
                        if node != 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(node == 0 ? (model.scannedVolume?.name ?? tree.path(of: 0)) : tree.name(of: node)) {
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

    var body: some View {
        if let tree = model.tree {
            let parentSize = max(tree.nodes[Int(model.center)].size, 1)
            List(tree.children(of: model.center).prefix(500), id: \.self) { child in
                let node = tree.nodes[Int(child)]
                ChildRow(name: tree.name(of: child), node: node,
                         fraction: Double(node.size) / Double(parentSize),
                         highlighted: model.hovered == child)
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
    }
}

private struct ChildRow: View {
    let name: String
    let node: Node
    let fraction: Double
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(formatBytes(node.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: max(proxy.size.width * fraction, 1))
            }
            .frame(height: 3)
        }
        .padding(.vertical, 2)
        .background(highlighted ? Color.accentColor.opacity(0.12) : .clear)
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
                if model.errors > 0 {
                    Text("· \(model.errors) unreadable")
                        .help("Grant Full Disk Access to scan protected folders.")
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
