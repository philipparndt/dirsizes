import DirScanner
import SwiftUI

/// Files with the same contents, grouped, with the copies per group.
struct DuplicatesList: View {
    @Environment(ScanModel.self) private var model
    /// Smaller files aren't compared.
    let minimumSize: Int64
    @State private var selection = Set<Row.ID>()
    @FocusState private var listFocused: Bool

    struct Row: Identifiable {
        enum ID: Hashable {
            case group(String)
            case file(Int32)
        }

        let id: ID
        let group: DuplicateGroup
        let file: DuplicateFile?
        let children: [Row]?
    }

    var body: some View {
        content
            .task(id: minimumSize) { findIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if model.findingDuplicates {
            progress
        } else if model.duplicates == nil {
            ContentUnavailableView {
                Label("Duplicates", systemImage: "doc.on.doc")
            } description: {
                Text("Compares the scan's files of the same size by their contents.")
            } actions: {
                Button("Find Duplicates") { model.findDuplicates(minimumSize: minimumSize) }
            }
        } else if groups.isEmpty {
            ContentUnavailableView("No duplicates", systemImage: "checkmark.seal",
                                   description: Text("No files of \(formatBytes(minimumSize)) or more have the same contents."))
        } else {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                List(rows, children: \.children, selection: $selection) { row in
                    if let file = row.file {
                        DuplicateFileRow(file: file, isKeeper: file.node == row.group.keeper)
                    } else {
                        DuplicateGroupRow(group: row.group)
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
                    Button("Add All but the Oldest") {
                        for group in groups where ids.contains(.group(group.id)) { collectCopies(of: group) }
                    }
                    .disabled(model.isDeleting || !ids.contains { if case .group = $0 { true } else { false } })
                    Button("Remove from Collector") { nodes.forEach(model.exclude) }
                        .disabled(model.isDeleting || !nodes.contains(where: model.isCollected))
                    if ids.count == 1, case let .file(node) = ids.first {
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

    private var progress: some View {
        let progress = model.duplicateProgress
        return VStack(spacing: 12) {
            switch progress.stage {
            case .listing:
                ProgressView("Looking for files of the same size…")
            case .sampling, .hashing:
                ProgressView(value: Double(progress.bytesDone), total: Double(max(progress.bytesTotal, 1))) {
                    Text(progress.stage == .sampling
                         ? "Comparing the start and end of \(progress.files) files…"
                         : "Comparing \(progress.files) files in full…")
                } currentValueLabel: {
                    Text("\(formatBytes(progress.bytesDone)) of \(formatBytes(progress.bytesTotal))")
                        .monospacedDigit()
                }
                .frame(width: 320)
            }
            Button("Stop") { model.resetDuplicates() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Duplicate files")
                    .font(.headline)
                Text("\(formatBytes(groups.reduce(0) { $0 + $1.reclaimable })) reclaimable")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Add Selected") { selectedNodes.forEach(model.collect) }
                    .disabled(selectedNodes.isEmpty || model.isDeleting || selectedNodes.allSatisfy(model.isCollected))
                    .help("Space adds or removes the selected rows")
                Button("Add All but the Oldest") { groups.forEach(collectCopies) }
                    .disabled(model.isDeleting)
                    .help("Keeps the copy created first in each group and adds the others")
                Button("Search Again", systemImage: "arrow.clockwise") { model.findDuplicates(minimumSize: minimumSize) }
                    .labelStyle(.iconOnly)
                    .help("Compare the files again, e.g. after changing them outside DirSizes")
            }
            Text("""
                Files with the same contents, compared in full. “Add All but the Oldest” keeps the \
                copy that has been on this Mac longest (created first: copies are made later, even \
                when they keep the original's modification date) and adds the others; expand a \
                group to choose yourself. APFS clones share their storage, so they count once in \
                what can be freed. Files in apps, Photos and other libraries, hidden folders, \
                node_modules and Library/Caches aren't compared.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    /// The search covers smaller files than shown; a smaller minimum needs a new search.
    private func findIfNeeded() {
        let searched = model.duplicateSearch?.minimumSize ?? (model.duplicates != nil ? model.duplicatesMinimumSize : nil)
        if searched.map({ minimumSize < $0 }) ?? true { model.findDuplicates(minimumSize: minimumSize) }
    }

    private var groups: [DuplicateGroup] {
        (model.duplicates ?? []).filter { $0.size >= minimumSize }
    }

    private var rows: [Row] {
        groups.map { group in
            Row(id: .group(group.id), group: group, file: nil,
                children: group.files.map { Row(id: .file($0.node), group: group, file: $0, children: nil) })
        }
    }

    /// Every copy but the keeper; a collected keeper is taken out of the collector again.
    private func collectCopies(of group: DuplicateGroup) {
        guard !model.isDeleting else { return }
        model.exclude(group.keeper)
        group.nodes.filter { $0 != group.keeper }.forEach(model.collect)
    }

    private var selectedNodes: [Int32] { nodes(for: selection) }

    private func nodes(for ids: Set<Row.ID>) -> [Int32] {
        var result: [Int32] = []
        for group in groups {
            if ids.contains(.group(group.id)) {
                result += group.nodes
            } else {
                result += group.nodes.filter { ids.contains(.file($0)) }
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

private struct DuplicateGroupRow: View {
    @Environment(ScanModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: group.nodes)
            Text((group.files[0].path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            if group.nodes.allSatisfy(model.isCollected) {
                Label("Every copy collected", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red.opacity(0.15)))
                    .foregroundStyle(.red)
                    .help("Deleting the collector would leave no copy of this file. Remove one copy from the collector to keep it.")
            }
            Text(summary)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(group.reclaimable))
                .monospacedDigit()
                .help("What deleting all copies but one frees")
        }
    }

    private var summary: String {
        "\(group.files.count) copies · \(formatBytes(group.size)) each · \(formatBytes(group.reclaimable)) reclaimable"
    }
}

private struct DuplicateFileRow: View {
    @Environment(ScanModel.self) private var model
    let file: DuplicateFile
    let isKeeper: Bool

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: [file.node])
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            Text(model.libraryPath(file.node))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if isKeeper {
                tag("Oldest", color: .green)
                    .help("Created first; “Add All but the Oldest” keeps this copy")
            }
            if file.cloneID != nil {
                tag("Clone", color: .blue)
                    .help("Shares its storage with another file (an APFS clone): deleting it alone frees nothing")
            }
            Spacer()
            Text(file.modified.formatted(date: .abbreviated, time: .shortened))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Modified")
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
