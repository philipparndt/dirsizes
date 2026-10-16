import DirScanner
import SwiftUI

/// What grew or shrank since an earlier scan, folder by folder.
struct ChangesList: View {
    @Environment(ScanModel.self) private var model
    @State private var selection = Set<String>()
    @FocusState private var listFocused: Bool

    var body: some View {
        if let snapshots = model.sizeSnapshots, !model.findingSizeChanges {
            if let changes = model.sizeChanges, let base = snapshots.first(where: { $0.url == changes.base }) {
                VStack(spacing: 0) {
                    header(date: base.date, total: changes.total)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    if changes.changes.isEmpty {
                        ContentUnavailableView("No big changes", systemImage: "equal.circle",
                                               description: Text("Nothing grew or shrank by 50 MB or more."))
                    } else {
                        list(changes.changes)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No earlier scan to compare with", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("DirSizes keeps the sizes of each scan from now on. Scan again later to see what grew since.")
                }
            }
        } else {
            ProgressView("Comparing with the earlier scan…")
        }
    }

    private func header(date: Date, total: (old: Int64, new: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Since \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.headline)
                DeltaText(delta: total.new - total.old)
                Text("\(formatBytes(total.old)) → \(formatBytes(total.new))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            Text("""
                Folders and files that grew or shrank by 50 MB or more since the earlier scan, what grew \
                most first. Expand a folder to see where inside it changed. Items smaller than 10 MB back \
                then count as new.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private func list(_ changes: [SizeChange]) -> some View {
        List(changes, children: \.children, selection: $selection) { change in
            ChangeRow(change: change)
        }
        .listStyle(.inset)
        .focused($listFocused)
        .onKeyPress(.space) {
            toggle(nodes(for: selection, in: changes))
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let nodes = nodes(for: ids, in: changes)
            Button("Add to Collector") { nodes.forEach(model.collect) }
                .disabled(model.isDeleting || nodes.isEmpty || nodes.allSatisfy(model.isCollected))
            Button("Remove from Collector") { nodes.forEach(model.exclude) }
                .disabled(model.isDeleting || !nodes.contains(where: model.isCollected))
            if nodes.count == 1, let node = nodes.first {
                Divider()
                Button("Reveal in Finder") { model.revealInFinder(node) }
                Button("Copy Path") { model.copyPath(of: node) }
            }
        } primaryAction: { ids in
            toggle(nodes(for: ids, in: changes))
        }
        .onAppear { listFocused = true }
    }

    private func nodes(for ids: Set<String>, in changes: [SizeChange]) -> [Int32] {
        var result: [Int32] = []
        func visit(_ changes: [SizeChange]) {
            for change in changes {
                if ids.contains(change.id), let node = change.node { result.append(node) }
                visit(change.children ?? [])
            }
        }
        visit(changes)
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

private struct ChangeRow: View {
    let change: SizeChange

    var body: some View {
        HStack(spacing: 8) {
            if let node = change.node {
                CollectCheckbox(nodes: [node])
            } else {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
                    .help("Gone since the earlier scan")
            }
            Text((change.path as NSString).lastPathComponent)
                .lineLimit(1)
                .strikethrough(change.node == nil)
            Text(change.old == 0 ? "new" : change.node == nil ? "gone" : "\(formatBytes(change.old)) → \(formatBytes(change.new))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            DeltaText(delta: change.delta)
        }
        .help(change.path)
    }
}

/// "+1,2 GB" in orange, "−300 MB" in green.
private struct DeltaText: View {
    let delta: Int64

    var body: some View {
        Text((delta >= 0 ? "+" : "−") + formatBytes(abs(delta)))
            .monospacedDigit()
            .foregroundStyle(delta >= 0 ? .orange : .green)
    }
}
