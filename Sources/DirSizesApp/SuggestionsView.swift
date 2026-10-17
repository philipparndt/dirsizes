import DirScanner
import SwiftUI

/// Suggestions in sections, each expandable to its items when it has several. Sections with
/// dates only show what's older than `months` (0: everything).
struct SuggestionsList<Header: View>: View {
    @Environment(ScanModel.self) private var model
    let sections: [SuggestionSection]
    let months: Int
    @ViewBuilder let header: () -> Header
    @State private var selection = Set<Row.ID>()
    @FocusState private var listFocused: Bool

    struct Row: Identifiable {
        enum ID: Hashable {
            case suggestion(String)
            case item(Int32)
        }

        let id: ID
        let suggestion: Suggestion
        let children: [Row]?
    }

    var body: some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            SelectionBar(selected: nodes(for: selection), all: shown.flatMap(\.suggestions).flatMap(\.items))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            if shown.isEmpty {
                ContentUnavailableView("Nothing older", systemImage: "checkmark.seal",
                                       description: Text("Nothing here is older than the chosen time."))
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(shown) { section in
                Section {
                    OutlineGroup(rows(section), children: \.children) { row in
                        switch row.id {
                        case .suggestion: SuggestionRow(suggestion: row.suggestion)
                        case let .item(node): SuggestionItemRow(item: node, label: row.suggestion.itemLabels[node])
                        }
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text(formatBytes(section.suggestions.reduce(0) { $0 + $1.size }))
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($listFocused)
        .onKeyPress(.space) {
            toggle(nodes(for: selection))
            return .handled
        }
        .onDeleteCommand {
            guard !model.isDeleting else { return }
            nodes(for: selection).forEach(model.exclude)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            let nodes = nodes(for: ids)
            Button("Add to Collector") { nodes.forEach(model.collect) }
                .disabled(model.isDeleting || nodes.allSatisfy(model.isCollected))
            Button("Remove from Collector") { nodes.forEach(model.exclude) }
                .disabled(model.isDeleting || !nodes.contains(where: model.isCollected))
            if nodes.count == 1, let node = nodes.first {
                Divider()
                Button("Reveal in Finder") { model.revealInFinder(node) }
                Button("Copy Path") { model.copyPath(of: node) }
            }
        } primaryAction: { ids in
            toggle(nodes(for: ids))
        }
        .onAppear { listFocused = true }
    }

    /// The sections with what passes the age filter.
    var shown: [SuggestionSection] { sections.olderThan(months: months) }

    private func rows(_ section: SuggestionSection) -> [Row] {
        section.suggestions.map { suggestion in
            Row(id: .suggestion(suggestion.id), suggestion: suggestion,
                children: suggestion.items.count > 1
                    ? suggestion.items.map { Row(id: .item($0), suggestion: suggestion, children: nil) } : nil)
        }
    }

    private func nodes(for ids: Set<Row.ID>) -> [Int32] {
        var result: [Int32] = []
        for suggestion in shown.flatMap(\.suggestions) {
            if ids.contains(.suggestion(suggestion.id)) {
                result += suggestion.items
            } else {
                result += suggestion.items.filter { ids.contains(.item($0)) }
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

extension [SuggestionSection] {
    /// With what passes the age filter: in sections with dates, what's older than `months`
    /// (0: everything).
    func olderThan(months: Int) -> [SuggestionSection] {
        let cutoff = months > 0 ? Calendar.current.date(byAdding: .month, value: -months, to: Date()) : nil
        return compactMap { section in
            guard section.byAge, let cutoff else { return section }
            let old = section.suggestions.filter { ($0.date ?? .distantPast) < cutoff }
            return old.isEmpty ? nil
                : SuggestionSection(title: section.title, byAge: true, grouping: section.grouping, suggestions: old)
        }
    }
}

/// How much is selected and how much of the list is in the collector, with a button to add
/// the selection.
struct SelectionBar: View {
    @Environment(ScanModel.self) private var model
    let selected: [Int32]
    let all: [Int32]

    var body: some View {
        let selected = Set(selected)
        let collected = Set(all.filter(model.isCollected))
        HStack(spacing: 12) {
            Text(selected.isEmpty ? "Nothing selected"
                 : "\(selected.count) selected · \(formatBytes(size(of: selected)))")
                .monospacedDigit()
            Text("In the collector: \(formatBytes(size(of: collected)))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Add Selected") { selected.forEach(model.collect) }
                .disabled(selected.isEmpty || model.isDeleting || selected.allSatisfy(model.isCollected))
                .help("Space adds or removes the selected rows")
        }
        .font(.callout)
    }

    private func size(of nodes: Set<Int32>) -> Int64 { model.uniqueSize(of: nodes) }
}

/// The header above a suggestions list: a title, its total and an explanation.
struct SuggestionsHeader: View {
    let title: String
    let sections: [SuggestionSection]
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                Text(formatBytes(sections.flatMap(\.suggestions).reduce(0) { $0 + $1.size }))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: suggestion.items)
            Text(suggestion.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(suggestion.note)
            if let subtitle = suggestion.subtitle {
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            if let date = suggestion.date {
                Text(date.formatted(.relative(presentation: .named)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            EffectBadge(effect: suggestion.effect)
                .help(suggestion.note)
            Spacer()
            if suggestion.items.count > 1 {
                Text("\(suggestion.items.count) items")
                    .foregroundStyle(.secondary)
            }
            Text(formatBytes(suggestion.size))
                .monospacedDigit()
        }
    }
}

/// What removing it means: made again, downloaded again, or gone.
private struct EffectBadge: View {
    let effect: Suggestion.Effect

    var body: some View {
        let (label, color): (String, Color) = switch effect {
        case .rebuilt: ("Rebuilt", .green)
        case .redownloaded: ("Downloaded again", .blue)
        case .lost: ("Gone", .orange)
        }
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
            .fixedSize()
    }
}

private struct SuggestionItemRow: View {
    @Environment(ScanModel.self) private var model
    let item: Int32
    let label: String?

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: [item])
            Image(systemName: model.tree?.nodes[Int(item)].isDirectory == true ? "folder" : "doc")
                .foregroundStyle(.secondary)
            if let label {
                Text(label)
                    .lineLimit(1)
            }
            Text(label == nil ? model.libraryPath(item) : model.tree?.name(of: item) ?? "")
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
