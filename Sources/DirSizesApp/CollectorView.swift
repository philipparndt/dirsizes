import DirScanner
import SwiftUI

/// Drop zone for items to delete, like DaisyDisk's collector. Accepts drags from the chart, the
/// list and Finder (for paths inside the scanned folder). Expands into `CollectorReviewView`.
struct CollectorView: View {
    @Environment(ScanModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Collector", systemImage: "tray.full")
                    .font(.headline)
                Spacer()
                if !model.collected.isEmpty {
                    Text(formatBytes(model.collectedBytes))
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.default, value: model.collectedBytes)
                    Button("Review", systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.showsCollectorReview = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Review the collector as a chart and a tree")
                }
            }

            if model.collected.isEmpty {
                Text("Drag files and folders here,\nor right-click › Add to Collector.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.collected, id: \.self) { node in
                            CollectedRow(node: node)
                        }
                    }
                }
                .frame(minHeight: 40, maxHeight: .infinity)
                CollectorActions()
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor : .secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: model.collected.isEmpty ? [5, 4] : []))
                .background(RoundedRectangle(cornerRadius: 10).fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
        }
        .padding(10)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.collect(urls: urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Clear and delete buttons, or the progress while deleting. Shared by the panel and the review.
struct CollectorActions: View {
    @Environment(ScanModel.self) private var model
    @State private var pendingDeletion: ScanModel.DeletionMode?

    var body: some View {
        Group {
            if let deletion = model.deletion {
                DeletionProgressView(progress: deletion)
            } else {
                HStack {
                    Button("Clear") { model.clearCollector() }
                    Spacer()
                    Menu {
                        Button("Delete Immediately…", role: .destructive) { pendingDeletion = .permanent }
                    } label: {
                        Text("Move to Trash")
                    } primaryAction: {
                        pendingDeletion = .trash
                    }
                    .fixedSize()
                }
                .disabled(model.collected.isEmpty)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            if pendingDeletion == .permanent {
                Button("Delete Immediately", role: .destructive) { model.deleteCollected(mode: .permanent) }
            } else {
                Button("Move to Trash", role: .destructive) { model.deleteCollected(mode: .trash) }
            }
        } message: {
            Text(pendingDeletion == .permanent
                 ? "This permanently deletes them and cannot be undone."
                 : "You can restore them from the Trash. Space is freed when you empty the Trash.")
        }
    }

    private var confirmationTitle: String {
        let count = model.collected.count
        let items = count == 1 ? "1 item" : "\(count) items"
        let size = formatBytes(model.collectedBytes)
        return pendingDeletion == .permanent
            ? "Permanently delete \(items) (\(size))?"
            : "Move \(items) (\(size)) to the Trash?"
    }
}

private struct DeletionProgressView: View {
    @Environment(ScanModel.self) private var model
    let progress: DeletionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Bytes, not items: one item can be a 4 KB file and the next a 6 GB folder.
            if progress.totalBytes > 0 {
                ProgressView(value: Double(progress.doneBytes), total: Double(progress.totalBytes))
            } else {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(progress.mode == .trash ? "Moving to Trash" : "Deleting") \(progress.current)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text((progress.totalBytes > 0 ? "\(formatBytes(progress.doneBytes)) of \(formatBytes(progress.totalBytes)) · " : "")
                         + "\(progress.done) of \(progress.total) items"
                         + (progress.failed > 0 ? " · \(progress.failed) failed" : ""))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Spacer()
                Button("Stop") { model.cancelDeletion() }
                    .help("Stop deleting. What is already deleted stays deleted.")
            }
        }
    }
}

/// One collected item in a flat list. `showsPath` adds where it is, for the review list.
private struct CollectedRow: View {
    @Environment(ScanModel.self) private var model
    let node: Int32
    var showsPath = false

    var body: some View {
        if let tree = model.tree {
            let item = tree.nodes[Int(node)]
            let gone = model.isGone(node)
            HStack(spacing: 6) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(item.isDirectory && !gone ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tree.name(of: node))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(gone ? .secondary : .primary)
                        .strikethrough(gone)
                    if showsPath {
                        Text(model.displayPath((tree.path(of: node) as NSString).deletingLastPathComponent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(gone ? "Deleted outside DirSizes" : tree.path(of: node))
                Spacer()
                Text(formatBytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                RemoveButton(node: node)
            }
            .font(.callout)
            .padding(.vertical, 2)
            .contextMenu {
                Button("Reveal in Finder") { model.revealInFinder(node) }
                Button("Remove from Collector") { model.exclude(node) }
            }
        }
    }
}

private struct RemoveButton: View {
    @Environment(ScanModel.self) private var model
    let node: Int32
    var help = "Remove from Collector"

    var body: some View {
        Button {
            model.exclude(node)
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .disabled(model.isDeleting)
    }
}

// MARK: - Review

/// The collector filling the window: a chart of what will be deleted next to a tree (or flat
/// list) of it, for checking a large collection before deleting it.
struct CollectorReviewView: View {
    @Environment(ScanModel.self) private var model
    @AppStorage("collectorReviewMode") private var mode = Mode.tree
    /// Shared by the tree or list and the chart, which highlights it.
    @State private var selection = Set<Int32>()
    @FocusState private var listFocused: Bool

    enum Mode: String {
        case tree
        case list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Back to Scan", systemImage: "chevron.left") { model.showsCollectorReview = false }
                Divider().frame(height: 16)
                Label("Collector", systemImage: "tray.full")
                    .font(.headline)
                Text("\(model.collected.count.formatted()) items · \(formatBytes(model.collectedBytes))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("View", selection: $mode) {
                    Label("Tree", systemImage: "list.bullet.indent").tag(Mode.tree)
                    Label("List", systemImage: "list.bullet").tag(Mode.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let tree = model.tree, !model.collected.isEmpty {
                let collection = CollectionTree(tree: tree, collected: model.collected)
                HSplitView {
                    CollectorSunburst(collection: collection, selection: selection)
                        .padding(8)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    Group {
                        switch mode {
                        case .tree: CollectorTreeList(collection: collection, selection: $selection)
                        case .list: CollectorFlatList(selection: $selection)
                        }
                    }
                    .focused($listFocused)
                    // ⌫ keeps the selected rows (removes them from the collector).
                    .onDeleteCommand {
                        guard !model.isDeleting else { return }
                        for node in selection { model.exclude(node) }
                        selection = []
                    }
                    .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("The collector is empty.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            CollectorActions()
                .padding(12)
        }
        .onExitCommand { model.showsCollectorReview = false }
        .onAppear { listFocused = true }
        .onChange(of: mode) { listFocused = true }
    }
}

private struct CollectorFlatList: View {
    @Environment(ScanModel.self) private var model
    @Binding var selection: Set<Int32>

    var body: some View {
        if let tree = model.tree {
            List(model.collected.sorted { tree.nodes[Int($0)].size > tree.nodes[Int($1)].size }, id: \.self,
                 selection: $selection) { node in
                CollectedRow(node: node, showsPath: true)
            }
        }
    }
}

/// The collection as an outline: folders above the collected items (sized by what is
/// collected inside, single-child chains merged), the items, and their contents.
/// Arrow keys move the selection; ← and → collapse and expand folders.
private struct CollectorTreeList: View {
    let collection: CollectionTree
    @Binding var selection: Set<Int32>

    var body: some View {
        List(CollectorTreeRow.rows(of: collection.top, in: collection), children: \.children,
             selection: $selection) { row in
            CollectorTreeRowView(row: row, total: collection.totalBytes)
        }
    }
}

private struct CollectorTreeRow: Identifiable {
    let id: Int32
    let name: String
    let collection: CollectionTree

    /// Big folders show their largest entries; the rest add little to a review.
    private static let maxChildren = 500

    static func rows(of node: Int32, in collection: CollectionTree) -> [CollectorTreeRow] {
        collection.children(of: node).prefix(maxChildren).map { child in
            let (end, name) = collection.isAncestor(child)
                ? collection.collapsedChain(from: child)
                : (child, collection.tree.name(of: child))
            return CollectorTreeRow(id: end, name: name, collection: collection)
        }
    }

    var children: [CollectorTreeRow]? {
        guard collection.isDirectory(id) else { return nil }
        let rows = Self.rows(of: id, in: collection)
        return rows.isEmpty ? nil : rows
    }
}

private struct CollectorTreeRowView: View {
    @Environment(ScanModel.self) private var model
    let row: CollectorTreeRow
    let total: Int64

    var body: some View {
        let collection = row.collection
        let node = row.id
        let gone = model.isGone(node)
        let isAncestor = collection.isAncestor(node)
        let size = collection.size(of: node)
        HStack(spacing: 6) {
            Image(systemName: collection.isDirectory(node) ? (isAncestor ? "folder" : "folder.fill") : "doc")
                .foregroundStyle(collection.isDirectory(node) && !isAncestor && !gone ? Color.accentColor : .secondary)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(gone || isAncestor ? .secondary : .primary)
                .strikethrough(gone)
            if collection.isCollectedItem(node) {
                Image(systemName: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("In the collector")
            }
            Spacer()
            Capsule()
                .fill(gone ? Color.gray.opacity(0.5) : Color.accentColor.opacity(0.6))
                .frame(width: max(60 * Double(size) / Double(max(total, 1)), 1), height: 3)
                .frame(width: 60, alignment: .leading)
            Text(formatBytes(size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            RemoveButton(node: node, help: isAncestor
                         ? "Remove everything in this folder from the Collector"
                         : collection.isCollectedItem(node) ? "Remove from Collector" : "Keep this, delete the rest")
        }
        .help(gone ? "Deleted outside DirSizes" : collection.tree.path(of: node))
        .contextMenu {
            Button("Reveal in Finder") { model.revealInFinder(node) }
            Button(isAncestor || collection.isCollectedItem(node) ? "Remove from Collector" : "Keep (Remove from Collector)") {
                model.exclude(node)
            }
        }
    }
}

// MARK: - Collector chart

/// Sunburst of the collection, rooted at its top folder. Click a folder to zoom in, the center
/// to go back up.
private struct CollectorSunburst: View {
    @Environment(ScanModel.self) private var model
    let collection: CollectionTree
    let selection: Set<Int32>
    @State private var center: Int32?
    @State private var hovered: Int32?
    @State private var cache = LayoutCache()

    var body: some View {
        GeometryReader { proxy in
            let geometry = SunburstGeometry(size: proxy.size, rings: ScanModel.rings)
            let root = currentRoot
            let segments = cache.segments(for: root, collection: collection, collected: model.collected)
            ZStack {
                Canvas { context, _ in
                    draw(segments, in: &context, geometry: geometry)
                }
                centerLabel(root: root)
                    .frame(width: geometry.innerRadius * 1.6)
                    .position(geometry.center)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase, case .segment(let node) = geometry.hitTest(point, segments: segments) {
                    if hovered != node { hovered = node }
                } else if hovered != nil {
                    hovered = nil
                }
            }
            .onTapGesture { point in
                switch geometry.hitTest(point, segments: segments) {
                case .center:
                    if root != collection.top {
                        center = collection.tree.nodes[Int(root)].parent
                    }
                case .segment(let node) where collection.isDirectory(node):
                    center = node
                    hovered = nil
                default:
                    break
                }
            }
            .contextMenu {
                if let hovered {
                    Button("Reveal in Finder") { model.revealInFinder(hovered) }
                    Button("Remove from Collector") { model.exclude(hovered) }
                }
            }
        }
    }

    /// The zoomed-in folder, if it is still part of the collection.
    private var currentRoot: Int32 {
        guard let center, center != collection.top,
              collection.tree.ancestry(of: center).contains(collection.top),
              collection.isAncestor(center) || collection.tree.ancestry(of: center).contains(where: collection.isCollectedItem)
        else { return collection.top }
        return center
    }

    private func draw(_ segments: [Segment], in context: inout GraphicsContext, geometry: SunburstGeometry) {
        let tree = collection.tree
        let gone = model.gone
        let hoveredChain = hovered.map { Set(tree.ancestry(of: $0)) } ?? []
        // Selected rows light up with everything inside them.
        let selected = selection
        for segment in segments {
            guard let path = geometry.wedge(start: segment.start, end: segment.end, depth: Double(segment.depth)) else { continue }
            let isSelected = !selected.isEmpty && tree.ancestry(of: segment.node).contains(where: selected.contains)
            let highlighted = hoveredChain.contains(segment.node) || isSelected
            let isGone = !gone.isEmpty && tree.ancestry(of: segment.node).contains { gone.contains($0) }
            // Folders above the collected items are context, not deletions: drawn faint.
            let isAncestor = collection.isAncestor(segment.node)
            let fill = isGone
                ? Color(white: highlighted ? 0.55 : 0.42)
                : SunburstView.color(hue: segment.hue, depth: Double(segment.depth),
                                     isDirectory: collection.isDirectory(segment.node), highlighted: highlighted)
            let dimmed = !selected.isEmpty && !isSelected && !hoveredChain.contains(segment.node)
            context.fill(path, with: .color(fill.opacity((isAncestor ? 0.35 : 1) * (dimmed ? 0.4 : 1))))
            context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 0.75)
        }
        let disc = Path(ellipseIn: CGRect(x: geometry.center.x - geometry.innerRadius,
                                          y: geometry.center.y - geometry.innerRadius,
                                          width: geometry.innerRadius * 2, height: geometry.innerRadius * 2))
        context.fill(disc, with: .color(Color(nsColor: .controlBackgroundColor)))
        context.stroke(disc, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
    }

    @ViewBuilder
    private func centerLabel(root: Int32) -> some View {
        let focused = hovered ?? root
        VStack(spacing: 4) {
            Text(focused == collection.top && hovered == nil ? "Collector" : collection.tree.name(of: focused))
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            Text(formatBytes(collection.size(of: focused)))
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if collection.isAncestor(focused) && focused != collection.top {
                Text("collected inside")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isGone(focused) {
                Text("deleted outside DirSizes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if hovered == nil && root != collection.top {
                Text("click to go up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Keeps the chart's layout between redraws (hovering redraws constantly); recomputed when the
/// root, the collection or the tree's sizes change.
@MainActor
private final class LayoutCache {
    private var key: Int?
    private var cached: [Segment] = []

    func segments(for root: Int32, collection: CollectionTree, collected: [Int32]) -> [Segment] {
        var hasher = Hasher()
        hasher.combine(root)
        hasher.combine(collected)
        hasher.combine(collection.totalBytes)
        let key = hasher.finalize()
        if key != self.key {
            self.key = key
            cached = SunburstLayout.segments(center: root, rings: ScanModel.rings, size: collection.size,
                                             children: collection.children, isDirectory: collection.isDirectory)
        }
        return cached
    }
}
