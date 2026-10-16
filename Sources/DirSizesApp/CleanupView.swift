import DirScanner
import SwiftUI

/// Cleanup suggestions from the scan: data left behind by apps that are no longer installed,
/// apps that haven't been used for a while, developer caches, and old downloads and backups. Suggestions only go into the collector;
/// deleting stays with the collector.
struct CleanupView: View {
    enum Tab: String {
        case leftBehind, unusedApps, developer, oldFiles, changes
    }

    @Environment(ScanModel.self) private var model
    @AppStorage("cleanupTab") private var tab = Tab.leftBehind
    @AppStorage("cleanupShowsCheck") private var showsCheck = true
    @AppStorage("unusedAppsMonths") private var months = 6
    @AppStorage("developerProjectMonths") private var projectMonths = 3
    @AppStorage("oldFilesMonths") private var oldFilesMonths = 3
    @State private var selection = Set<CleanupRow.ID>()
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Back to Scan", systemImage: "chevron.left") { model.showsCleanup = false }
                Divider().frame(height: 16)
                Label("Cleanup", systemImage: "lightbulb")
                    .font(.headline)
                Picker("", selection: $tab) {
                    Text("Left Behind").tag(Tab.leftBehind)
                    Text("Unused Apps").tag(Tab.unusedApps)
                    Text("Developer").tag(Tab.developer)
                    Text("Old Files").tag(Tab.oldFiles)
                    Text("Changes").tag(Tab.changes)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                Spacer()
                switch tab {
                case .leftBehind:
                    Toggle("Show entries to check", isOn: $showsCheck)
                        .toggleStyle(.checkbox)
                        .help("Also list data that may still belong to something installed")
                case .unusedApps:
                    Picker("Not used for", selection: $months) {
                        Text("3 months").tag(3)
                        Text("6 months").tag(6)
                        Text("1 year").tag(12)
                        Text("2 years").tag(24)
                        Text("Any time").tag(0)
                    }
                    .fixedSize()
                case .developer:
                    Picker("Projects untouched for", selection: $projectMonths) {
                        Text("1 month").tag(1)
                        Text("3 months").tag(3)
                        Text("6 months").tag(6)
                        Text("1 year").tag(12)
                        Text("Any time").tag(0)
                    }
                    .fixedSize()
                case .oldFiles:
                    Picker("Older than", selection: $oldFilesMonths) {
                        Text("1 month").tag(1)
                        Text("3 months").tag(3)
                        Text("6 months").tag(6)
                        Text("1 year").tag(12)
                        Text("Any time").tag(0)
                    }
                    .fixedSize()
                case .changes:
                    if let snapshots = model.sizeSnapshots, snapshots.count > 1 {
                        Picker("Compared with", selection: Binding(
                            get: { model.sizeChanges?.base },
                            set: { if let url = $0 { model.findSizeChanges(since: url) } })) {
                            ForEach(snapshots, id: \.url) { snapshot in
                                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                                    .tag(Optional(snapshot.url))
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            Group {
                switch tab {
                case .leftBehind: content
                case .unusedApps: UnusedAppsList(months: months)
                case .developer: developer
                case .oldFiles: oldFiles
                case .changes: ChangesList()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear(perform: load)
            .onChange(of: tab, load)

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

    /// Looks for the tab's suggestions the first time it's shown.
    private func load() {
        switch tab {
        case .leftBehind: break
        case .unusedApps: if model.unusedApps == nil { model.findUnusedApps() }
        case .developer: if model.developerCaches == nil { model.findDeveloperCaches() }
        case .oldFiles: if model.oldFiles == nil { model.findOldFiles() }
        case .changes: if model.sizeSnapshots == nil { model.findSizeChanges() }
        }
    }

    @ViewBuilder
    private var developer: some View {
        if let sections = model.developerCaches, !model.findingDeveloperCaches {
            if sections.isEmpty {
                ContentUnavailableView {
                    Label("No developer caches in this scan", systemImage: "hammer")
                } description: {
                    Text("Developer tools keep their caches in your home folder, and projects their build output. Scan your home folder or the startup disk to find them.")
                } actions: {
                    Button("Scan Home Folder") { model.scan(path: NSHomeDirectory()) }
                }
            } else {
                SuggestionsList(sections: sections, months: projectMonths) {
                    SuggestionsHeader(title: "Developer caches and build output", sections: sections, text: """
                        Caches of Xcode, package managers and other tools, and build output and installed \
                        packages inside your projects (projects untouched the longest first). The badge says \
                        what removing it means: rebuilt or downloaded again when needed, or gone. Hover over \
                        a row for details. Quit the tool first when it's running.
                        """)
                }
            }
        } else {
            ProgressView("Looking for caches and projects…")
        }
    }

    @ViewBuilder
    private var oldFiles: some View {
        if let sections = model.oldFiles, !model.findingOldFiles {
            if model.scannedHome == nil {
                ContentUnavailableView {
                    Label("No home folder in this scan", systemImage: "arrow.down.circle")
                } description: {
                    Text("Scan your home folder or the startup disk to find old downloads, device backups and device software.")
                } actions: {
                    Button("Scan Home Folder") { model.scan(path: NSHomeDirectory()) }
                }
            } else if sections.isEmpty {
                ContentUnavailableView("No old files", systemImage: "checkmark.seal",
                                       description: Text("Downloads is empty, and there are no device backups or software updates."))
            } else {
                SuggestionsList(sections: sections, months: oldFilesMonths) {
                    SuggestionsHeader(title: "Old downloads and backups", sections: sections, text: """
                        What's in Downloads, by when you downloaded it, oldest first; iPhone and iPad backups \
                        made on this Mac; and device software downloaded for updates. Installers can go once \
                        the app is installed; look at archives and other downloads before removing them.
                        """)
                }
            }
        } else {
            ProgressView("Looking at your downloads…")
        }
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

/// Installed apps not used for `months` (0: all), with the app and its data per row.
private struct UnusedAppsList: View {
    @Environment(ScanModel.self) private var model
    let months: Int
    @State private var selection = Set<Row.ID>()
    @FocusState private var listFocused: Bool

    struct Row: Identifiable {
        enum ID: Hashable {
            case app(String)
            case item(Int32)
        }

        let id: ID
        let app: UnusedApp
        let children: [Row]?
    }

    var body: some View {
        if model.unusedApps == nil || model.findingUnusedApps {
            ProgressView("Looking at your apps…")
        } else if model.scannedAppFolders.isEmpty {
            ContentUnavailableView {
                Label("No Applications folder in this scan", systemImage: "app.dashed")
            } description: {
                Text("Scan the startup disk to see your apps, how much space each takes with its data, and when you last used it.")
            }
        } else if apps.isEmpty {
            ContentUnavailableView("No unused apps", systemImage: "checkmark.seal",
                                   description: Text("Every app was used within the chosen time."))
        } else {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                List(rows, children: \.children, selection: $selection) { row in
                    switch row.id {
                    case .app: UnusedAppRow(app: row.app)
                    case let .item(node): AppItemRow(item: node, isApp: node == row.app.app)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(months == 0 ? "All apps" : "Apps not used for \(months >= 12 ? "\(months / 12) year\(months > 12 ? "s" : "")" : "\(months) months")")
                    .font(.headline)
                Text(formatBytes(apps.reduce(0) { $0 + $1.size }))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Add Selected") { selectedNodes.forEach(model.collect) }
                    .disabled(selectedNodes.isEmpty || model.isDeleting || selectedNodes.allSatisfy(model.isCollected))
                    .help("Space adds or removes the selected rows")
            }
            Text("""
                Each app with its data in the Library folders, oldest use first. "Opened" is when \
                Spotlight last saw the app opened; where it has no record (common after moving to a \
                new Mac), it's when the app last changed its data. Apple's apps and running apps \
                aren't listed. Collecting an app also collects its data unless you expand it and \
                pick parts.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    /// Apps without any date come first: nothing says they were used.
    private var apps: [UnusedApp] {
        let all = model.unusedApps ?? []
        guard months > 0, let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) else {
            return all
        }
        return all.filter { ($0.lastUsed ?? .distantPast) < cutoff }
    }

    private var rows: [Row] {
        apps.map { app in
            Row(id: .app(app.id), app: app,
                children: app.items.map { Row(id: .item($0), app: app, children: nil) })
        }
    }

    private var selectedNodes: [Int32] { nodes(for: selection) }

    private func nodes(for ids: Set<Row.ID>) -> [Int32] {
        var result: [Int32] = []
        for app in apps {
            if ids.contains(.app(app.id)) {
                result += app.items
            } else {
                result += app.items.filter { ids.contains(.item($0)) }
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

private struct UnusedAppRow: View {
    let app: UnusedApp

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: app.items)
            Text(app.name)
                .lineLimit(1)
            Text(lastUsed)
                .foregroundStyle(.secondary)
                .help(app.lastUsedFromData
                      ? "Spotlight has no record of opening it; this is when the app last changed its data"
                      : app.lastUsed == nil ? "Neither Spotlight nor the app's data say when it was used"
                      : "When Spotlight last saw it opened")
            Spacer()
            Text(formatBytes(app.size))
                .monospacedDigit()
        }
    }

    private var lastUsed: String {
        guard let date = app.lastUsed else { return "no record of use" }
        let when = date.formatted(.relative(presentation: .named))
        return app.lastUsedFromData ? "data changed \(when)" : "opened \(when)"
    }
}

private struct AppItemRow: View {
    @Environment(ScanModel.self) private var model
    let item: Int32
    let isApp: Bool

    var body: some View {
        HStack(spacing: 8) {
            CollectCheckbox(nodes: [item])
            Image(systemName: isApp ? "app" : model.tree?.nodes[Int(item)].isDirectory == true ? "folder" : "doc")
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
struct CollectCheckbox: View {
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
