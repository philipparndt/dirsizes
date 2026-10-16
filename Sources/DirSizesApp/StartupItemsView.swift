import DirScanner
import SwiftUI

/// Launch agents and daemons whose app is gone, with their plist and helper tool per row.
struct StartupItemsList: View {
    @Environment(ScanModel.self) private var model
    /// Also list items that may still belong to something installed.
    let showsCheck: Bool
    @State private var selection = Set<Row.ID>()
    @FocusState private var listFocused: Bool

    struct Row: Identifiable {
        enum ID: Hashable {
            case item(String)
            case node(Int32)
        }

        let id: ID
        let item: StartupItem
        let children: [Row]?
    }

    var body: some View {
        content
            .onAppear { if model.startupItems == nil { model.findStartupItems() } }
    }

    @ViewBuilder
    private var content: some View {
        if model.startupItems == nil || model.findingStartupItems {
            ProgressView("Looking at launch agents and daemons…")
        } else if model.scannedStartupFolders.isEmpty {
            ContentUnavailableView {
                Label("No launch agent folders in this scan", systemImage: "power.dotted")
            } description: {
                Text("Launch agents and daemons are in ~/Library/LaunchAgents and /Library. Scan the startup disk to see which ones apps you removed left behind.")
            }
        } else if items.isEmpty {
            ContentUnavailableView("Nothing left behind", systemImage: "checkmark.seal",
                                   description: Text("Every launch agent and daemon in the scan belongs to an installed app or to macOS."))
        } else {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                List(rows, children: \.children, selection: $selection) { row in
                    switch row.id {
                    case .item: StartupItemRow(item: row.item)
                    case let .node(node): StartupFileRow(node: node, isHelper: node != row.item.items[0])
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                .onKeyPress(.space) {
                    toggle(selectedNodes)
                    return .handled
                }
                .onDeleteCommand {
                    guard !model.isDeleting else { return }
                    selectedNodes.forEach(model.exclude)
                }
                .contextMenu(forSelectionType: Row.ID.self) { ids in
                    let nodes = nodes(for: ids)
                    Button("Add to Collector") { nodes.forEach(model.collect) }
                        .disabled(model.isDeleting || nodes.allSatisfy(model.isCollected))
                    Button("Remove from Collector") { nodes.forEach(model.exclude) }
                        .disabled(model.isDeleting || !nodes.contains(where: model.isCollected))
                    if ids.count == 1, let node = nodes.first {
                        Divider()
                        Button("Reveal in Finder") { model.revealInFinder(node) }
                        Button("Copy Path") { model.copyPath(of: node) }
                    }
                } primaryAction: { ids in
                    toggle(nodes(for: ids))
                }
                .onAppear { listFocused = true }
            }
        }
    }

    private var header: some View {
        let missing = items.filter { $0.status == .missing }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Startup items of removed apps")
                    .font(.headline)
                Spacer()
                Button("Add Selected") { selectedNodes.forEach(model.collect) }
                    .disabled(selectedNodes.isEmpty || model.isDeleting || selectedNodes.allSatisfy(model.isCollected))
                    .help("Space adds or removes the selected rows")
                Button("Add All Missing") {
                    for item in missing { item.items.forEach(model.collect) }
                }
                .disabled(missing.isEmpty || model.isDeleting)
            }
            Text("""
                Launch agents start when you log in, launch daemons when the Mac starts. “Missing” \
                ones start a program that isn't there anymore; “Check” ones start something that \
                exists but doesn't seem to belong to an installed app, so look before collecting \
                them. Removing the plist stops the item from starting at the next login or restart \
                (a loaded one keeps running until then). A daemon's helper tool is collected with \
                it. Apple's items aren't listed.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var items: [StartupItem] {
        (model.startupItems ?? []).filter { showsCheck || $0.status == .missing }
    }

    private var rows: [Row] {
        items.map { item in
            Row(id: .item(item.id), item: item,
                children: item.items.map { Row(id: .node($0), item: item, children: nil) })
        }
    }

    private var selectedNodes: [Int32] { nodes(for: selection) }

    private func nodes(for ids: Set<Row.ID>) -> [Int32] {
        var result: [Int32] = []
        for item in items {
            if ids.contains(.item(item.id)) {
                result += item.items
            } else {
                result += item.items.filter { ids.contains(.node($0)) }
            }
        }
        return result
    }

    private func toggle(_ nodes: [Int32]) {
        guard !model.isDeleting, !nodes.isEmpty else { return }
        if nodes.allSatisfy(model.isCollected) {
            nodes.forEach(model.exclude)
        } else {
            nodes.forEach(model.collect)
        }
    }
}

private struct StartupItemRow: View {
    let item: StartupItem

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: item.items)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .lineLimit(1)
                    Text(item.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    switch item.status {
                    case .missing:
                        tag("Missing", color: .red)
                            .help("What it starts isn't there anymore: likely left behind")
                    case .check:
                        tag("Check", color: .orange)
                            .help("May still belong to something installed: look before collecting")
                    }
                    if item.isLoaded {
                        tag("Loaded", color: .secondary)
                            .help("launchd has it loaded now; without its plist it won't start at the next login or restart")
                    }
                }
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.program.map { "Starts \($0)" } ?? item.reason)
            }
            Spacer()
            Text(kind)
                .foregroundStyle(.secondary)
            Text(formatBytes(item.size))
                .monospacedDigit()
        }
    }

    private var kind: String {
        switch item.kind {
        case .userAgent: "At your login"
        case .agent: "At every login"
        case .daemon: "At startup"
        case .helperTool: "Helper tool"
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }
}

private struct StartupFileRow: View {
    @Environment(ScanModel.self) private var model
    let node: Int32
    let isHelper: Bool

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: [node])
            Image(systemName: isHelper ? "terminal" : "doc.text")
                .foregroundStyle(.secondary)
            Text(model.libraryPath(node))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(model.tree?.nodes[Int(node)].size ?? 0))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
