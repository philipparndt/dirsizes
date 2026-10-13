import AppKit
import DirScanner
import Observation
import Synchronization

/// A running zoom animation. The `inner` node's layout is drawn mapped into its slice of
/// the `outer` node's layout (expansion 0) or expanded to the full circle (expansion 1).
struct ZoomTransition {
    let id = UUID()
    let outer: Int32
    let inner: Int32
    let outerSegments: [Segment]
    let innerSegments: [Segment]
    /// Where `inner` sits inside `outer`'s layout.
    let slice: SunburstLayout.Slice
    let zoomingIn: Bool
    let start = Date()

    static let duration = 0.45

    /// 0 = inner shown inside its slice, 1 = inner fills the chart. Eased.
    func expansion(at date: Date) -> Double {
        let t = min(max(date.timeIntervalSince(start) / Self.duration, 0), 1)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return zoomingIn ? eased : 1 - eased
    }
}

@MainActor
@Observable
final class ScanModel {
    enum Phase {
        case idle
        case scanning
        case done
    }

    static let rings = 6
    private static let totalsKey = "lastScanTotals"

    private(set) var phase = Phase.idle
    private(set) var rootPath: String?
    /// Mounted disks for the start screen.
    private(set) var volumes: [VolumeInfo] = []
    /// Set when a whole disk is scanned; enables free and hidden space in the chart.
    private(set) var scannedVolume: VolumeInfo?
    /// Hovered free or hidden space segment.
    var hoveredSpecial: SpecialSpace?
    private(set) var tree: FileTree?
    private(set) var center: Int32 = 0
    private(set) var segments: [Segment] = []
    private(set) var transition: ZoomTransition?
    var hovered: Int32?

    private(set) var filesScanned = 0
    private(set) var bytesScanned: Int64 = 0
    private(set) var errors = 0
    private(set) var duration: Duration = .zero
    /// Expected total for the progress bar: the last scan of this path, or the volume's used
    /// space when scanning a volume root. Nil when there is no honest estimate.
    private(set) var expectedBytes: Int64?

    /// Items queued for deletion. Never contains both a folder and something inside it.
    private(set) var collected: [Int32] = []
    private(set) var isDeleting = false
    /// Failures from the last deletion, shown in an alert.
    var deletionErrors: [String] = []

    private var scanner: DiskScanner?
    private var pollTask: Task<Void, Never>?

    var focused: Int32 { hovered ?? center }

    /// The disk's name for disk scans (the startup disk's data volume is scanned at
    /// /System/Volumes/Data, but should read "Macintosh HD"), otherwise the folder name.
    var rootName: String {
        scannedVolume?.name ?? ((rootPath ?? "") as NSString).lastPathComponent
    }

    /// Free and hidden space for the root of a disk scan, empty for folder scans.
    var extras: [(SpecialSpace, Int64)] {
        guard let volume = scannedVolume, let tree else { return [] }
        return [(.hidden, max(volume.usedBytes - tree.root.size, 0)), (.free, volume.availableBytes)]
    }

    func bytes(of special: SpecialSpace) -> Int64 {
        extras.first { $0.0 == special }?.1 ?? 0
    }

    init() {
        loadVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadVolumes() }
            }
        }
    }

    func loadVolumes() {
        volumes = VolumeInfo.mounted()
    }

    /// Back to the disk list.
    func showStart() {
        scanner?.cancel()
        pollTask?.cancel()
        scanner = nil
        phase = .idle
        rootPath = nil
        scannedVolume = nil
        tree = nil
        segments = []
        transition = nil
        collected = []
        hovered = nil
        hoveredSpecial = nil
        loadVolumes()
    }

    /// Scan progress in 0...1, or nil when the total is unknown. Held below 1 until the scan ends,
    /// since the estimate can be off.
    var progress: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(Double(bytesScanned) / Double(expectedBytes), 0.99)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            open(path: url.path)
        }
    }

    func rescan() {
        if let volume = scannedVolume {
            scan(volume: volume)
        } else if let rootPath {
            scan(path: rootPath)
        }
    }

    /// Scans `path`, as a disk scan (with free and hidden space) when it is a disk's root.
    func open(path: String) {
        let path = (path as NSString).expandingTildeInPath
        if let volume = volumes.first(where: { $0.url.path == path || $0.scanPath == path }) {
            scan(volume: volume)
        } else {
            scan(path: path)
        }
    }

    func scan(volume: VolumeInfo) {
        scan(path: volume.scanPath)
        scannedVolume = Self.refreshed(volume)
    }

    /// Current free space; it changes while the app runs.
    private static func refreshed(_ volume: VolumeInfo) -> VolumeInfo {
        VolumeInfo.mounted().first { $0.url == volume.url } ?? volume
    }

    func stop() {
        scanner?.cancel()
    }

    /// Shows a made-up home folder as if it had been scanned, for screenshots (`-demo YES`).
    /// Its paths don't exist, so revealing or deleting from it does nothing useful.
    func showDemo() {
        showStart()
        let tree = FileTree.demo()
        rootPath = tree.path(of: 0)
        self.tree = tree
        filesScanned = Int(tree.root.itemCount)
        duration = .milliseconds(1840)
        phase = .done
        segments = layout(center: 0)
        for path in ["Library/Developer/Xcode/DerivedData", "dev/web-shop/node_modules", "Downloads/Xcode_27.xip"] {
            if let node = tree.node(atPath: tree.path(of: 0) + "/" + path) { collect(node) }
        }
    }

    func scan(path: String) {
        scanner?.cancel()
        pollTask?.cancel()

        let scanner = DiskScanner(path: path)
        self.scanner = scanner
        rootPath = scanner.rootPath
        scannedVolume = nil
        hoveredSpecial = nil
        phase = .scanning
        tree = nil
        center = 0
        hovered = nil
        segments = []
        transition = nil
        collected = []
        filesScanned = 0
        bytesScanned = 0
        errors = 0
        expectedBytes = Self.expectedTotal(for: scanner.rootPath)

        Task.detached(priority: .userInitiated) {
            let result = scanner.scan()
            await self.finish(scanner, result: result)
        }

        // Only the counters are shown while scanning; the sunburst appears once the tree is complete.
        pollTask = Task {
            while !Task.isCancelled, self.scanner === scanner, self.phase == .scanning {
                self.updateProgress(from: scanner)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finish(_ scanner: DiskScanner, result: ScanResult) {
        guard self.scanner === scanner else { return }
        pollTask?.cancel()
        updateProgress(from: scanner)
        duration = result.duration
        phase = .done
        tree = result.tree
        if let volume = scannedVolume { scannedVolume = Self.refreshed(volume) }
        segments = layout(center: 0)
        if !scanner.isCancelled {
            Self.rememberTotal(result.totalBytes, for: scanner.rootPath)
        }
    }

    private func updateProgress(from scanner: DiskScanner) {
        filesScanned = scanner.filesScanned.load(ordering: .relaxed)
        bytesScanned = scanner.bytesScanned.load(ordering: .relaxed)
        errors = scanner.errorCount.load(ordering: .relaxed)
    }

    // MARK: - Expected totals

    private static func expectedTotal(for path: String) -> Int64? {
        if let totals = UserDefaults.standard.dictionary(forKey: totalsKey),
           let total = (totals[path] as? NSNumber)?.int64Value {
            return total
        }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mountPoint = withUnsafeBytes(of: fs.f_mntonname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard mountPoint == path else { return nil }
        return Int64(fs.f_blocks - fs.f_bfree) * Int64(fs.f_bsize)
    }

    private static func rememberTotal(_ bytes: Int64, for path: String) {
        var totals = UserDefaults.standard.dictionary(forKey: totalsKey) ?? [:]
        totals[path] = NSNumber(value: bytes)
        UserDefaults.standard.set(totals, forKey: totalsKey)
    }

    // MARK: - Navigation

    /// Zooms to `node`, a directory that is an ancestor or descendant of the current center.
    /// Animates the target's slice expanding to the full circle, or collapsing back into its parent.
    func zoom(to node: Int32) {
        guard let tree, node != center, tree.nodes[Int(node)].isDirectory else { return }
        let newSegments = layout(center: node)
        let zoomingIn = tree.ancestry(of: node).contains(center)
        let (outer, inner) = zoomingIn ? (center, node) : (node, center)

        let span = outer == 0 ? SunburstLayout.rootSpan(tree: tree, extras: extras) : 2 * .pi
        if let slice = SunburstLayout.slice(of: inner, within: outer, tree: tree, span: span) {
            let next = ZoomTransition(outer: outer, inner: inner,
                                      outerSegments: zoomingIn ? segments : newSegments,
                                      innerSegments: zoomingIn ? newSegments : segments,
                                      slice: slice, zoomingIn: zoomingIn)
            transition = next
            Task {
                try? await Task.sleep(for: .seconds(ZoomTransition.duration))
                if self.transition?.id == next.id { self.transition = nil }
            }
        }

        center = node
        hovered = nil
        segments = newSegments
    }

    private func layout(center: Int32) -> [Segment] {
        guard let tree else { return [] }
        return SunburstLayout.segments(tree: tree, center: center, rings: Self.rings, extras: extras)
    }

    func zoomOut() {
        guard let tree else { return }
        let parent = tree.nodes[Int(center)].parent
        if parent >= 0 { zoom(to: parent) }
    }

    func revealInFinder(_ node: Int32) {
        guard let tree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tree.path(of: node))])
    }

    func copyName(of node: Int32) {
        guard let tree else { return }
        copyToPasteboard(node == 0 ? (tree.path(of: 0) as NSString).lastPathComponent : tree.name(of: node))
    }

    func copyPath(of node: Int32) {
        guard let tree else { return }
        copyToPasteboard(tree.path(of: node))
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func url(of node: Int32) -> URL? {
        tree.map { URL(fileURLWithPath: $0.path(of: node)) }
    }

    // MARK: - Collector

    enum DeletionMode {
        case trash
        case permanent
    }

    var collectedBytes: Int64 {
        guard let tree else { return 0 }
        return collected.reduce(0) { $0 + tree.nodes[Int($1)].size }
    }

    func isCollected(_ node: Int32) -> Bool {
        guard let tree else { return false }
        return tree.ancestry(of: node).contains { collected.contains($0) }
    }

    /// Adds `node` unless it is already covered by a collected folder; a folder replaces any
    /// collected items inside it.
    func collect(_ node: Int32) {
        guard let tree, node != 0, !isCollected(node) else { return }
        collected.removeAll { tree.ancestry(of: $0).contains(node) }
        collected.append(node)
    }

    func collect(urls: [URL]) {
        guard let tree else { return }
        for url in urls {
            if let node = tree.node(atPath: url.standardizedFileURL.path) { collect(node) }
        }
    }

    func uncollect(_ node: Int32) {
        collected.removeAll { $0 == node }
    }

    func clearCollector() {
        collected = []
    }

    func deleteCollected(mode: DeletionMode) {
        guard let tree, !collected.isEmpty, !isDeleting else { return }
        isDeleting = true
        let items = collected.map { (node: $0, url: URL(fileURLWithPath: tree.path(of: $0))) }

        Task {
            // File operations can take a while (permanent deletes of big folders), so run them off
            // the main thread and apply the results to the tree afterwards.
            let failures = await Task.detached(priority: .userInitiated) {
                var failures: [(node: Int32, message: String)] = []
                for item in items {
                    do {
                        switch mode {
                        case .trash: try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                        case .permanent: try FileManager.default.removeItem(at: item.url)
                        }
                    } catch {
                        failures.append((item.node, "\(item.url.lastPathComponent): \(error.localizedDescription)"))
                    }
                }
                return failures
            }.value

            let failed = Set(failures.map(\.node))
            for item in items where !failed.contains(item.node) {
                tree.remove(item.node)
            }
            collected = items.map(\.node).filter { failed.contains($0) }
            deletionErrors = failures.map(\.message)
            isDeleting = false

            // Re-center if the current folder was deleted, then redraw with the new sizes.
            while center != 0 && tree.isRemoved(center) { center = tree.nodes[Int(center)].parent }
            hovered = nil
            transition = nil
            self.tree = tree
            // Permanent deletes free space right away.
            if let volume = scannedVolume { scannedVolume = Self.refreshed(volume) }
            segments = layout(center: center)
        }
    }
}
