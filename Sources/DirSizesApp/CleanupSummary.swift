import DirScanner
import SwiftUI

/// One line below the chart with what Cleanup found in the scan, each part opening its tab.
/// Uses the tabs' own filters, so the numbers match what the tab shows.
struct CleanupSummary: View {
    @Environment(ScanModel.self) private var model
    @AppStorage("cleanupTab") private var tab = CleanupView.Tab.leftBehind
    @AppStorage("cleanupShowsCheck") private var showsCheck = true
    @AppStorage("unusedAppsMonths") private var months = 6
    @AppStorage("developerProjectMonths") private var projectMonths = 3
    @AppStorage("oldFilesMonths") private var oldFilesMonths = 3
    @AppStorage("duplicatesMinimumSize") private var duplicatesMinimumSize = 1_000_000

    private struct Part: Identifiable {
        var id: CleanupView.Tab { tab }
        let tab: CleanupView.Tab
        let title: String
        let systemImage: String
        let nodes: Set<Int32>
        /// Instead of the size, for parts whose size says little (startup items).
        var count: Int?
        /// What the tab has, for the hover card.
        var note = ""
        var entries: [SummaryCard.Entry] = []
    }

    var body: some View {
        let parts = parts
        let finding = model.findingLeftovers || model.findingUnusedApps || model.findingDeveloperCaches
            || model.findingOldFiles || model.findingStartupItems
        if model.phase == .done, !parts.isEmpty || finding || model.sizeChanges != nil {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                    if !parts.isEmpty {
                        Text("Could free \(formatBytes(model.uniqueSize(of: parts.reduce(into: Set()) { $0.formUnion($1.nodes) })))")
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .padding(.trailing, 4)
                    }
                    ForEach(parts) { part in
                        chip(part.title, systemImage: part.systemImage, tab: part.tab,
                             card: SummaryCard(title: part.title, note: part.note, entries: part.entries)) {
                            Text(part.count.map { "\($0)" } ?? formatBytes(model.uniqueSize(of: part.nodes)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let changes = model.sizeChanges {
                        let delta = changes.total.new - changes.total.old
                        chip("Since last scan", systemImage: "chart.line.uptrend.xyaxis", tab: .changes,
                             card: changesCard(changes.changes)) {
                            Text((delta >= 0 ? "+" : "−") + formatBytes(abs(delta)))
                                .foregroundStyle(delta >= 0 ? .orange : .green)
                        }
                    }
                    if finding {
                        ProgressView().controlSize(.mini)
                            .help("Looking for more")
                    }
                }
                .font(.callout)
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .animation(.default, value: parts.map(\.tab))
        }
    }

    private func chip(_ title: String, systemImage: String, tab: CleanupView.Tab, card: SummaryCard,
                      @ViewBuilder value: () -> some View) -> some View {
        let label = HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
            value()
        }
        return SummaryChip(card: card, label: label) {
            self.tab = tab
            model.showCleanup()
        }
    }

    private func changesCard(_ changes: [SizeChange]) -> SummaryCard {
        SummaryCard(title: "Since last scan",
                    note: "What grew or shrank by 50 MB or more since the earlier scan.",
                    entries: changes.sorted { abs($0.delta) > abs($1.delta) }.map { change in
                        SummaryCard.Entry(title: (change.path as NSString).lastPathComponent,
                                          detail: change.node == nil ? "gone" : change.old == 0 ? "new" : nil,
                                          value: (change.delta >= 0 ? "+" : "−") + formatBytes(abs(change.delta)),
                                          color: change.delta >= 0 ? .orange : .green)
                    })
    }

    private var parts: [Part] {
        var parts: [Part] = []
        func add(_ tab: CleanupView.Tab, _ title: String, _ image: String, _ nodes: [Int32], count: Int? = nil,
                 note: String, entries: [SummaryCard.Entry]) {
            guard !nodes.isEmpty else { return }
            parts.append(Part(tab: tab, title: title, systemImage: image, nodes: Set(nodes), count: count,
                              note: note, entries: entries))
        }
        func entries(_ suggestions: [Suggestion]) -> [SummaryCard.Entry] {
            suggestions.sorted { $0.size > $1.size }.map {
                SummaryCard.Entry(title: $0.title, detail: $0.subtitle, value: formatBytes($0.size))
            }
        }
        if let caches = model.developerCaches {
            // Grouped by project and by kind are the same items; one of them is enough.
            let suggestions = caches.filter { $0.grouping != .byKind }.olderThan(months: projectMonths)
                .flatMap(\.suggestions)
            add(.developer, "Developer", "hammer", suggestions.flatMap(\.items),
                note: "Caches of developer tools, and build output of projects untouched for a while.",
                entries: entries(suggestions))
        }
        if let old = model.oldFiles {
            let suggestions = old.olderThan(months: oldFilesMonths).flatMap(\.suggestions)
            add(.oldFiles, "Old files", "clock.arrow.circlepath", suggestions.flatMap(\.items),
                note: "Old downloads, iPhone and iPad backups, and device software updates.",
                entries: entries(suggestions))
        }
        if let old = model.oldCloudFolders {
            let suggestions = old.flatMap(\.suggestions)
            add(.oldCloudFolders, "Old cloud folders", "icloud.slash", suggestions.flatMap(\.items),
                note: "Cloud folders nothing syncs anymore, kept after a location was removed or reset.",
                entries: entries(suggestions))
        }
        if let duplicates = model.duplicates {
            let groups = duplicates.filter { $0.size >= duplicatesMinimumSize }
            add(.duplicates, "Duplicates", "doc.on.doc",
                groups.flatMap { group in group.nodes.filter { $0 != group.keeper } },
                note: "Files with the same contents; the space of all copies but one.",
                entries: groups.sorted { $0.reclaimable > $1.reclaimable }.map { group in
                    SummaryCard.Entry(title: (group.files[0].path as NSString).lastPathComponent,
                                      detail: "\(group.files.count) copies", value: formatBytes(group.reclaimable))
                })
        }
        if let leftovers = model.leftovers {
            let found = leftovers.filter { showsCheck || $0.confidence == .likely }
            add(.leftBehind, "Left behind", "shippingbox", found.flatMap(\.items),
                note: "Data of apps that aren't installed anymore.",
                entries: found.sorted { $0.size > $1.size }.map {
                    SummaryCard.Entry(title: $0.name, detail: $0.confidence == .check ? "to check" : nil,
                                      value: formatBytes($0.size))
                })
        }
        if let apps = model.unusedApps {
            let cutoff = months > 0 ? Calendar.current.date(byAdding: .month, value: -months, to: Date()) : nil
            let unused = apps.filter { cutoff == nil || ($0.lastUsed ?? .distantPast) < cutoff! }
            add(.unusedApps, "Unused apps", "app.dashed", unused.flatMap(\.items),
                note: months > 0 ? "Apps not opened for \(months) months or more, with their data." : "Installed apps with their data.",
                entries: unused.sorted { $0.size > $1.size }.map {
                    SummaryCard.Entry(title: $0.name,
                                      detail: $0.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "never",
                                      value: formatBytes($0.size))
                })
        }
        if let items = model.startupItems?.filter({ $0.status == .missing }), !items.isEmpty {
            add(.startupItems, "Startup items", "power", items.flatMap(\.items), count: items.count,
                note: "Launch agents and daemons whose app or program is gone.",
                entries: items.map { SummaryCard.Entry(title: $0.name, detail: $0.label, value: formatBytes($0.size)) })
        }
        return parts
    }
}

/// A chip in the summary: opens its tab on click, shows a card with the largest entries on hover.
private struct SummaryChip<Label: View>: View {
    let card: SummaryCard
    let label: Label
    let action: () -> Void
    @State private var hovering = false
    @State private var showsCard = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary.opacity(hovering ? 1 : 0.6)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // A moment's delay, so moving the mouse across the row doesn't flash cards.
        .task(id: hovering) {
            if hovering {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { showsCard = true }
            } else {
                showsCard = false
            }
        }
        .popover(isPresented: $showsCard, arrowEdge: .top) {
            card
        }
    }
}

/// What a part of the summary is, with its largest entries.
struct SummaryCard: View {
    struct Entry {
        let title: String
        var detail: String?
        let value: String
        var color: Color?
    }

    let title: String
    let note: String
    let entries: [Entry]
    private let shown = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(Array(entries.prefix(shown).enumerated()), id: \.offset) { _, entry in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Text(entry.value)
                            .monospacedDigit()
                            .foregroundStyle(entry.color ?? .secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            if entries.count > shown {
                Text("and \(entries.count - shown) more")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Click to open in Cleanup")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}
