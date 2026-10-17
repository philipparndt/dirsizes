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
                        button(part.title, systemImage: part.systemImage, tab: part.tab) {
                            Text(part.count.map { "\($0)" } ?? formatBytes(model.uniqueSize(of: part.nodes)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let changes = model.sizeChanges {
                        let delta = changes.total.new - changes.total.old
                        button("Since last scan", systemImage: "chart.line.uptrend.xyaxis", tab: .changes) {
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

    private func button(_ title: String, systemImage: String, tab: CleanupView.Tab,
                        @ViewBuilder value: () -> some View) -> some View {
        Button {
            self.tab = tab
            model.showCleanup()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                value()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary.opacity(0.6)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open in Cleanup")
    }

    private var parts: [Part] {
        var parts: [Part] = []
        func add(_ tab: CleanupView.Tab, _ title: String, _ image: String, _ nodes: [Int32], count: Int? = nil) {
            if !nodes.isEmpty { parts.append(Part(tab: tab, title: title, systemImage: image, nodes: Set(nodes), count: count)) }
        }
        if let caches = model.developerCaches {
            // Grouped by project and by kind are the same items; one of them is enough.
            let sections = caches.filter { $0.grouping != .byKind }.olderThan(months: projectMonths)
            add(.developer, "Developer", "hammer", sections.flatMap(\.suggestions).flatMap(\.items))
        }
        if let old = model.oldFiles {
            add(.oldFiles, "Old files", "clock.arrow.circlepath",
                old.olderThan(months: oldFilesMonths).flatMap(\.suggestions).flatMap(\.items))
        }
        if let duplicates = model.duplicates {
            add(.duplicates, "Duplicates", "doc.on.doc", duplicates.filter { $0.size >= duplicatesMinimumSize }
                .flatMap { group in group.nodes.filter { $0 != group.keeper } })
        }
        if let leftovers = model.leftovers {
            add(.leftBehind, "Left behind", "shippingbox",
                leftovers.filter { showsCheck || $0.confidence == .likely }.flatMap(\.items))
        }
        if let apps = model.unusedApps {
            let cutoff = months > 0 ? Calendar.current.date(byAdding: .month, value: -months, to: Date()) : nil
            add(.unusedApps, "Unused apps", "app.dashed",
                apps.filter { cutoff == nil || ($0.lastUsed ?? .distantPast) < cutoff! }.flatMap(\.items))
        }
        if let items = model.startupItems?.filter({ $0.status == .missing }), !items.isEmpty {
            add(.startupItems, "Startup items", "power", items.flatMap(\.items), count: items.count)
        }
        return parts
    }
}
