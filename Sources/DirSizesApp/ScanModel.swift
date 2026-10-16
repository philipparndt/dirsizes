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
    /// Folders read again by an incremental scan; nil after a full scan.
    private(set) var changedFolders: Int?
    /// What the scan is doing before it reads folders (loading the last scan, replaying changes).
    private(set) var scanStage = DiskScanner.Stage.scanning
    /// The top levels found so far, for a chart that fills in while scanning.
    private(set) var liveTree: FileTree?
    /// The finished scan's FSEvents position, for updating it incrementally.
    private var scanInfo: ScanInfo?
    /// Expected total for the progress bar: the last scan of this path, or the volume's used
    /// space when scanning a volume root. Nil when there is no honest estimate.
    private(set) var expectedBytes: Int64?

    /// Items queued for deletion. Never contains both a folder and something inside it.
    private(set) var collected: [Int32] = []
    /// The collector fills the window for reviewing (chart and tree of what will be deleted).
    var showsCollectorReview = false
    var showsCleanup = false
    /// Leftovers of uninstalled apps in the scan; nil until looked for.
    private(set) var leftovers: [Leftover]?
    private(set) var findingLeftovers = false
    private var installedApps: InstalledApps?
    private var isDemo = false
    /// The Full Disk Access sheet is up; `pendingScan` runs once it is answered.
    var asksForFullDiskAccess = false
    private var pendingScan: (() -> Void)?
    private var declinedFullDiskAccess = false
    /// Set while the collector is being deleted.
    private(set) var deletion: DeletionProgress?
    var isDeleting: Bool { deletion != nil }
    /// Failures from the last deletion, shown in an alert.
    var deletionErrors: [String] = []

    /// Items deleted by other apps since the scan (top-most ones; their contents count as gone
    /// too). They stay in the tree and are drawn gray until the next scan.
    private(set) var gone = Set<Int32>()

    private var scanner: DiskScanner?
    private var pollTask: Task<Void, Never>?
    private var monitor: DeletionMonitor?
    private var deletionRun: CollectorDeletion?

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
        refreshSavedScans()
    }

    /// When each disk was last scanned (saved scans only), for the start screen.
    private(set) var savedScanDates: [String: Date] = [:]

    private func refreshSavedScans() {
        var dates: [String: Date] = [:]
        for volume in volumes {
            if let date = ScanCache.savedDate(covering: volume.scanPath) { dates[volume.scanPath] = date }
        }
        savedScanDates = dates
    }

    /// Full scans are the default on external and network drives: another computer may have
    /// changed them without macOS recording it, so an update could miss changes.
    func prefersFullScan(_ path: String) -> Bool {
        let path = DiskScanner.normalizedPath(path)
        let volume = volumes.filter { $0.url.path != "/" && (path == $0.scanPath || path.hasPrefix($0.url.path + "/")) }
            .max { $0.url.path.count < $1.url.path.count }
        return volume.map { $0.kind != .internalDisk } ?? false
    }

    /// Back to the disk list.
    func showStart() {
        scanner?.cancel()
        pollTask?.cancel()
        scanner = nil
        stopMonitoring()
        phase = .idle
        rootPath = nil
        scannedVolume = nil
        tree = nil
        segments = []
        transition = nil
        collected = []
        showsCollectorReview = false
        showsCleanup = false
        leftovers = nil
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

    /// Scans the same folder or disk again: an update with what changed since, or a full scan
    /// (the default for external drives). `full: nil` takes the default.
    func rescan(full: Bool? = nil) {
        if let volume = scannedVolume {
            scan(volume: volume, full: full)
        } else if let rootPath {
            scan(path: rootPath, full: full)
        }
    }

    /// Reads everything again, ignoring the earlier scan.
    func rescanFully() {
        rescan(full: true)
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

    /// `full` reads everything instead of updating an earlier scan; nil takes the default for
    /// the drive (see `prefersFullScan`).
    func scan(volume: VolumeInfo, full: Bool? = nil) {
        let full = full ?? prefersFullScan(volume.scanPath)
        withFullDiskAccess {
            self.startScan(path: volume.scanPath, full: full)
            self.scannedVolume = Self.refreshed(volume)
        }
    }

    func scan(path: String, full: Bool? = nil) {
        let full = full ?? prefersFullScan(path)
        withFullDiskAccess { self.startScan(path: path, full: full) }
    }


    /// Asks for Full Disk Access first (unless declined this session), so the scan doesn't
    /// trigger a macOS dialog for every protected folder.
    private func withFullDiskAccess(_ scan: @escaping () -> Void) {
        if declinedFullDiskAccess || FullDiskAccess.isGranted {
            scan()
        } else {
            pendingScan = scan
            asksForFullDiskAccess = true
        }
    }

    /// At launch, before a disk is chosen.
    func requestFullDiskAccess() {
        if !FullDiskAccess.isGranted { asksForFullDiskAccess = true }
    }

    func fullDiskAccessGranted() {
        asksForFullDiskAccess = false
        pendingScan?()
        pendingScan = nil
    }

    func declineFullDiskAccess() {
        declinedFullDiskAccess = true
        asksForFullDiskAccess = false
        pendingScan?()
        pendingScan = nil
    }

    /// Current free space; it changes while the app runs.
    private static func refreshed(_ volume: VolumeInfo) -> VolumeInfo {
        VolumeInfo.mounted().first { $0.url == volume.url } ?? volume
    }

    /// Whether a scan of `root` includes `path` (a startup disk scan is rooted at the data volume).
    private static func covers(_ root: String, _ path: String) -> Bool {
        DataVolume.candidates(for: path).contains { $0 == root || $0.hasPrefix(root == "/" ? "/" : root + "/") }
    }

    func stop() {
        scanner?.cancel()
    }

    /// Shows a made-up home folder as if it had been scanned, for screenshots (`-demo YES`).
    /// Its paths don't exist, so revealing or deleting from it does nothing useful.
    func showDemo() {
        showStart()
        let tree = FileTree.demo()
        isDemo = true
        installedApps = .demo
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

    private func startScan(path: String, full: Bool = false) {
        if isDemo {
            isDemo = false
            installedApps = nil
        }
        scanner?.cancel()
        pollTask?.cancel()

        stopMonitoring()
        // Start from the scan on screen when it covers this folder, else from a saved one.
        let normalized = DiskScanner.normalizedPath(path)
        let incremental: DiskScanner.Incremental = if full {
            .off
        } else if let tree, let scanInfo, phase == .done, Self.covers(scanInfo.rootPath, normalized) {
            .previous(tree, scanInfo)
        } else {
            .cached
        }
        let scanner = DiskScanner(path: path, incremental: incremental)
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
        showsCollectorReview = false
        showsCleanup = false
        leftovers = nil
        filesScanned = 0
        bytesScanned = 0
        errors = 0
        changedFolders = nil
        scanInfo = nil
        scanStage = .scanning
        liveTree = nil
        expectedBytes = Self.expectedTotal(for: scanner.rootPath)

        Task.detached(priority: .userInitiated) {
            let result = scanner.scan()
            await self.finish(scanner, result: result)
        }

        // Only the counters are shown while scanning; the sunburst appears once the tree is complete.
        pollTask = Task {
            var tick = 0
            while !Task.isCancelled, self.scanner === scanner, self.phase == .scanning {
                self.updateProgress(from: scanner)
                // The live chart twice a second: its snapshot is built off the main thread.
                if tick % 5 == 0 {
                    let snapshot = await Task.detached(priority: .utility) { scanner.liveSnapshot() }.value
                    if self.scanner === scanner, self.phase == .scanning, let snapshot { self.liveTree = snapshot }
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finish(_ scanner: DiskScanner, result: ScanResult) {
        guard self.scanner === scanner else { return }
        pollTask?.cancel()
        updateProgress(from: scanner)
        duration = result.duration
        changedFolders = result.changedFolders
        liveTree = nil
        phase = .done
        tree = result.tree
        if let volume = scannedVolume { scannedVolume = Self.refreshed(volume) }
        segments = layout(center: 0)
        if !scanner.isCancelled {
            Self.rememberTotal(result.totalBytes, for: scanner.rootPath)
            scanInfo = result.info
            // Saved for an incremental scan next time, also after the app was quit.
            Task.detached(priority: .utility) {
                DiskScanner.save(result)
                await MainActor.run { self.refreshSavedScans() }
            }
        }
        startMonitoring(result.tree, rootPath: scanner.rootPath)
    }

    // MARK: - External deletions

    private func startMonitoring(_ tree: FileTree, rootPath: String) {
        let monitor = DeletionMonitor(tree: tree, rootPath: rootPath) { [weak self] gone in
            guard let self, self.tree === tree else { return }
            // Our own deletion removes files before their folders leave the tree; that isn't
            // "deleted elsewhere".
            if let run = self.deletionRun {
                let deleting = Set(run.items.map(\.node))
                self.gone = gone.filter { !tree.ancestry(of: $0).contains(where: deleting.contains) }
            } else {
                self.gone = gone
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    private func stopMonitoring() {
        monitor?.stop()
        monitor = nil
        gone = []
    }

    /// Whether `node` or a folder containing it was deleted outside the app.
    func isGone(_ node: Int32) -> Bool {
        guard !gone.isEmpty, let tree else { return false }
        return tree.ancestry(of: node).contains { gone.contains($0) }
    }

    /// The gone items and their size, counting nested ones once.
    var goneSummary: (count: Int, bytes: Int64) {
        guard let tree, !gone.isEmpty else { return (0, 0) }
        let outermost = gone.filter { node in
            !tree.isRemoved(node) && !tree.ancestry(of: node).dropLast().contains { gone.contains($0) }
        }
        return (outermost.count, outermost.reduce(0) { $0 + tree.nodes[Int($1)].size })
    }

    private func updateProgress(from scanner: DiskScanner) {
        filesScanned = scanner.filesScanned.load(ordering: .relaxed)
        bytesScanned = scanner.bytesScanned.load(ordering: .relaxed)
        errors = scanner.errorCount.load(ordering: .relaxed)
        scanStage = scanner.stage
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

    // MARK: - Cleanup


    /// The Library folders (yours and the Mac's) the scan covers.
    var scannedLibraries: [String] {
        guard let tree else { return [] }
        if isDemo { return [tree.path(of: 0) + "/Library"] }
        return [NSHomeDirectory() + "/Library", "/Library"].compactMap { path in
            DataVolume.candidates(for: path).first { tree.node(atPath: $0) != nil }
        }
    }

    func showCleanup() {
        showsCollectorReview = false
        showsCleanup = true
        findLeftovers()
    }

    /// Looks for leftovers in the scan, again whenever asked: the installed apps are looked up
    /// once, the scan's Library folders are quick to go through.
    func findLeftovers() {
        guard let tree, !findingLeftovers else { return }
        let libraries = scannedLibraries
        guard !libraries.isEmpty else {
            leftovers = []
            return
        }
        if let installedApps {
            leftovers = tree.read { LeftoverFinder.find(in: $0, libraries: libraries, installed: installedApps) }
            return
        }
        findingLeftovers = true
        Task.detached(priority: .userInitiated) {
            let installed = InstalledApps.discover()
            let found = tree.read { LeftoverFinder.find(in: $0, libraries: libraries, installed: installed) }
            await MainActor.run {
                self.installedApps = installed
                self.findingLeftovers = false
                if self.tree === tree { self.leftovers = found }
            }
        }
    }

    /// Like `displayPath`, but home-relative ("~/Library/Caches/…"), for paths in Library folders.
    func libraryPath(_ node: Int32) -> String {
        guard let tree else { return "" }
        var path = tree.path(of: node)
        path = DataVolume.displayPath(path)
        let home = isDemo ? tree.path(of: 0) : NSHomeDirectory()
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        return path
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

    /// Keeps `node` out of the deletion: a collected item is removed; something inside a
    /// collected folder is split out, by collecting that folder's other contents instead,
    /// level by level down to `node`; a folder above collected items drops them all.
    func exclude(_ node: Int32) {
        guard let tree else { return }
        let ancestry = tree.ancestry(of: node)
        guard let top = collected.first(where: { ancestry.contains($0) }) else {
            collected.removeAll { tree.ancestry(of: $0).contains(node) }
            return
        }
        collected.removeAll { $0 == top }
        for (parent, keep) in zip(ancestry.drop { $0 != top }, ancestry.drop { $0 != top }.dropFirst()) {
            collected.append(contentsOf: tree.children(of: parent).filter { $0 != keep })
        }
    }

    func clearCollector() {
        collected = []
    }

    /// Stops a running deletion soon; what is already deleted stays deleted.
    func cancelDeletion() {
        deletionRun?.cancel()
    }

    func deleteCollected(mode: DeletionMode) {
        guard let tree, !collected.isEmpty, deletion == nil else { return }
        let items = collected.map { node in
            CollectorDeletion.Item(node: node, path: tree.path(of: node), bytes: tree.nodes[Int(node)].size)
        }
        let run = CollectorDeletion(mode: mode, items: items, tree: tree)
        deletionRun = run
        var progress = DeletionProgress(mode: mode, total: items.count,
                                        totalBytes: items.reduce(0) { $0 + $1.bytes }, current: "")
        deletion = progress
        run.start()

        // Poll rather than be called: the UI updates 10 times a second however fast the
        // workers go, and redraws once per update for everything deleted since the last one.
        Task {
            var snapshot = run.snapshot()
            while true {
                progress.done = snapshot.doneItems
                progress.failed = snapshot.failedItems
                progress.doneBytes = min(snapshot.doneBytes, progress.totalBytes)
                progress.current = displayPath(snapshot.current)
                deletion = progress
                var removed = snapshot.removed
                applyDeletions(&removed, from: tree)
                if snapshot.finished { break }
                try? await Task.sleep(for: .milliseconds(100))
                snapshot = run.snapshot()
            }
            deletionErrors = snapshot.failures
            deletion = nil
            deletionRun = nil
            // Trash moves and permanent deletes change free space.
            if self.tree === tree, let volume = scannedVolume { scannedVolume = Self.refreshed(volume) }
        }
    }

    /// A path relative to the scanned folder, for progress text.
    func displayPath(_ path: String) -> String {
        guard let rootPath else { return path }
        if path == rootPath { return rootName }
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// Takes deleted items out of the tree and the collector, and redraws once for all of them.
    private func applyDeletions(_ nodes: inout [Int32], from tree: FileTree) {
        guard !nodes.isEmpty else { return }
        defer { nodes.removeAll() }
        // A new scan replaced the tree in the meantime; nothing to update.
        guard self.tree === tree else { return }
        for node in nodes { tree.remove(node) }
        let removed = Set(nodes)
        collected.removeAll { removed.contains($0) }

        // Re-center if the current folder was deleted, then redraw with the new sizes.
        while center != 0 && tree.isRemoved(center) { center = tree.nodes[Int(center)].parent }
        hovered = nil
        transition = nil
        self.tree = tree
        segments = layout(center: center)
        if leftovers != nil { findLeftovers() }
    }
}

/// Progress of deleting the collector, shown in its panel.
struct DeletionProgress {
    let mode: ScanModel.DeletionMode
    let total: Int
    let totalBytes: Int64
    var done = 0
    var failed = 0
    var doneBytes: Int64 = 0
    var current: String
}
