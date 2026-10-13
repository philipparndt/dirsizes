import DirScanner
import SwiftUI

/// Cleanup suggestions from the scan: for now, data left behind by apps that are no longer
/// installed. Suggestions only go into the collector; deleting stays with the collector.
struct CleanupView: View {
    @Environment(ScanModel.self) private var model
    @AppStorage("cleanupShowsCheck") private var showsCheck = true
    @State private var selection = Set<CleanupRow.ID>()
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Back to Scan", systemImage: "chevron.left") { model.showsCleanup = false }
                Divider().frame(height: 16)
                Label("Cleanup", systemImage: "lightbulb")
                    .font(.headline)
                Spacer()
                Toggle("Show entries to check", isOn: $showsCheck)
                    .toggleStyle(.checkbox)
                    .help("Also list data that may still belong to something installed")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                CollectorActions()
                if !model.collected.isEmpty && !model.isDeleting {
                    Button("Review Collector", systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.showsCleanup = false
                        model.showsCollectorReview = true
                    }
                }
            }
            .padding(12)
        }
        .onExitCommand { model.showsCleanup = false }
    }

    @ViewBuilder
    private var content: some View {
        if model.leftovers == nil || model.findingLeftovers {
            ProgressView("Looking up installed apps…")
        } else if model.scannedLibraries.isEmpty {
            ContentUnavailableView {
                Label("No Library folder in this scan", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Apps keep their data in ~/Library and /Library. Scan your home folder or the startup disk to find what uninstalled apps left behind.")
            } actions: {
                Button("Scan Home Folder") { model.scan(path: NSHomeDirectory()) }
            }
        } else if groups.isEmpty {
            ContentUnavailableView("Nothing left behind", systemImage: "checkmark.seal",
                                   description: Text("No data from uninstalled apps was found in the scanned Library folders."))
        } else {
            VStack(spacing: 0) {
                LeftoversHeader(groups: groups, selected: selectedNodes)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                // Arrows move and expand, Space adds or removes the selection, ⌫ removes it.
                List(rows, children: \.children, selection: $selection) { row in
                    switch row.id {
                    case .group: LeftoverGroupRow(group: row.group)
                    case let .item(node): LeftoverItemRow(item: node)
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
                .contextMenu(forSelectionType: CleanupRow.ID.self) { ids in
                    let nodes = nodes(for: ids)
                    Button("Add to Collector") { nodes.forEach(model.collect) }
                        .disabled(model.isDeleting || nodes.allSatisfy(model.isCollected))
                    Button("Remove from Collector") { nodes.forEach(model.exclude) }
                        .disabled(model.isDeleting || !nodes.contains(where: model.isCollected))
                    if ids.count == 1, case let .item(node) = ids.first {
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

    private var groups: [Leftover] {
        (model.leftovers ?? []).filter { showsCheck || $0.confidence == .likely }
    }

    private var rows: [CleanupRow] {
        groups.map { group in
            CleanupRow(id: .group(group.id), group: group,
                       children: group.items.map { CleanupRow(id: .item($0), group: group, children: nil) })
        }
    }

    private var selectedNodes: [Int32] { nodes(for: selection) }

    private func nodes(for ids: Set<CleanupRow.ID>) -> [Int32] {
        var result: [Int32] = []
        for group in groups {
            if ids.contains(.group(group.id)) {
                result += group.items
            } else {
                result += group.items.filter { ids.contains(.item($0)) }
            }
        }
        return result
    }

    /// Adds the nodes, or removes them when they are all in the collector already.
    private func toggle(_ nodes: [Int32]) {
        guard !model.isDeleting, !nodes.isEmpty else { return }
        if nodes.allSatisfy(model.isCollected) {
            nodes.forEach(model.exclude)
        } else {
            nodes.forEach(model.collect)
        }
    }
}

struct CleanupRow: Identifiable {
    enum ID: Hashable {
        case group(String)
        case item(Int32)
    }

    let id: ID
    let group: Leftover
    let children: [CleanupRow]?
}

private struct LeftoversHeader: View {
    @Environment(ScanModel.self) private var model
    let groups: [Leftover]
    let selected: [Int32]

    var body: some View {
        let likely = groups.filter { $0.confidence == .likely }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Left behind by uninstalled apps")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Add Selected") { selected.forEach(model.collect) }
                    .disabled(selected.isEmpty || model.isDeleting || selected.allSatisfy(model.isCollected))
                    .help("Space adds or removes the selected rows")
                Button("Add All Likely (\(formatBytes(likely.reduce(0) { $0 + $1.size })))") {
                    for group in likely { group.items.forEach(model.collect) }
                }
                .disabled(likely.isEmpty || model.isDeleting)
            }
            Text("""
                Caches, settings and containers named after apps that aren't on this Mac anymore. \
                Entries marked “Check” may still belong to something installed (another app by the \
                same vendor, a command-line tool), so look before collecting them. Select rows \
                (⇧ and ⌘ for more) and press Space to add or remove them.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

private struct LeftoverGroupRow: View {
    @Environment(ScanModel.self) private var model
    let group: Leftover

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: group.items)
            Text(group.name)
                .lineLimit(1)
            if group.name != group.id {
                Text(group.id)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            if group.confidence == .check {
                Text("Check")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
                    .help("May still belong to something installed: look before collecting")
            }
            Text("\(group.items.count) \(group.items.count == 1 ? "place" : "places")")
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(group.size))
                .monospacedDigit()
        }
    }
}

private struct LeftoverItemRow: View {
    @Environment(ScanModel.self) private var model
    let item: Int32

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: [item])
            Image(systemName: model.tree?.nodes[Int(item)].isDirectory == true ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(model.libraryPath(item))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(model.tree?.nodes[Int(item)].size ?? 0))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Whether the nodes are in the collector (all, some, none); a click adds or removes them all.
private struct CollectCheckbox: View {
    @Environment(ScanModel.self) private var model
    let nodes: [Int32]

    var body: some View {
        let count = nodes.filter(model.isCollected).count
        let all = count == nodes.count
        Button {
            if all {
                nodes.forEach(model.exclude)
            } else {
                nodes.forEach(model.collect)
            }
        } label: {
            Image(systemName: all ? "checkmark.square.fill" : count > 0 ? "minus.square.fill" : "square")
                .foregroundStyle(count > 0 ? Color.accentColor : .secondary)
                .font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help(all ? "Remove from the collector" : "Add to the collector")
        .disabled(model.isDeleting)
    }
}
