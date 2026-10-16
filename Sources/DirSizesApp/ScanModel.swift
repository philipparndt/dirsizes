import AppKit
import CoreServices
import DirScanner
import Observation
import SwiftUI
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

/// The finished chart growing out of the live one when a scan ends.
struct ChartIntro {
    let id = UUID()
    let morph: ChartMorph
    /// The live chart's center (in global coordinates) and size.
    let liveCenter: CGPoint
    let liveOuterRadius: CGFloat

    static let duration = 0.8
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
    /// What the scanned disk's hidden space is made of; nil until looked up.
    private(set) var hiddenSpace: HiddenSpace?
    private(set) var loadingHiddenSpace = false
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
    /// The live chart's segments (for hovering) and its animation from the previous snapshot.
    private(set) var liveSegments: [Segment] = []
    /// Free space and what the scan hasn't reached yet, for disk scans.
    private(set) var liveExtras: [(SpecialSpace, Int64)] = []
    private(set) var liveMorph: ChartMorph?
    /// Where the live chart is in the window, so the finished chart can grow out of it.
    @ObservationIgnored var liveChartFrame: CGRect?
    /// The finished chart growing out of the live one: from its last state and place, gaining rings.
    private(set) var intro: ChartIntro?
    /// The finished scan's FSEvents position, for updating it incrementally.
    private var scanInfo: ScanInfo?
    /// The scan counts files that are only in iCloud at their size (see `DiskScanner.countsCloudFiles`).
    private(set) var countsCloudFiles = false
    /// For such scans: bytes in iCloud only, per node (folders include their contents).
    private(set) var cloudBytes: [Int64] = []
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
    /// Installed apps with their size and when they were last used; nil until looked for.
    private(set) var unusedApps: [UnusedApp]?
    private(set) var findingUnusedApps = false
    private(set) var findingLeftovers = false
    /// Caches of developer tools and build output in projects; nil until looked for.
    private(set) var developerCaches: [SuggestionSection]?
    private(set) var findingDeveloperCaches = false
    /// Old downloads, device backups and device software; nil until looked for.
    private(set) var oldFiles: [SuggestionSection]?
    private(set) var findingOldFiles = false
    /// Earlier scans' sizes to compare with, newest first; nil until looked for.
    private(set) var sizeSnapshots: [(date: Date, rootPath: String, url: URL)]?
    /// What changed since the snapshot at `base`.
    private(set) var sizeChanges: (base: URL, total: (old: Int64, new: Int64), changes: [SizeChange])?
    private(set) var findingSizeChanges = false
    /// Duplicate files in the scan; nil until looked for. Set in ScanModel+Duplicates.swift,
    /// as are the running search and its progress.
    var duplicates: [DuplicateGroup]?
    var duplicateSearch: DuplicateSearch?
    var duplicateProgress = DuplicateSearch.Progress()
    /// The smallest files `duplicates` compared.
    var duplicatesMinimumSize: Int64 = 0
    /// Launch agents and daemons of removed apps; nil until looked for (ScanModel+StartupItems.swift).
    var startupItems: [StartupItem]?
    var findingStartupItems = false
    private(set) var installedApps: InstalledApps?
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
        if iCloudUsage != nil { return "iCloud" }
        return scannedVolume?.name ?? rootPath.flatMap(CloudFolder.displayName(ofPath:))
            ?? ((rootPath ?? "") as NSString).lastPathComponent
    }

    /// Readable names of iCloud's app containers in the current tree, looked up once per tree.
    @ObservationIgnored private var containerNames: (tree: ObjectIdentifier, names: [Int32: String])?

    /// The name to show for `node`: the root's name, an iCloud container's app name, or the
    /// file name.
    func displayName(of node: Int32) -> String {
        guard let tree else { return "" }
        if node == 0 { return rootName }
        if node == photosLibraryNode { return "Photos on this Mac" }
        if containerNames?.tree != ObjectIdentifier(tree) {
            var names: [Int32: String] = [:]
            let folder = DataVolume.candidates(for: CloudFolder.iCloudPath).lazy.compactMap(tree.node(atPath:)).first
            if let folder {
                for child in tree.children(of: folder) {
                    names[child] = CloudFolder.displayName(ofPath: tree.path(of: child))
                }
            }
            containerNames = (ObjectIdentifier(tree), names)
        }
        return containerNames?.names[node] ?? tree.name(of: node)
    }

    /// Free and hidden space for the root of a disk scan, the rest of iCloud around an iCloud
    /// Drive scan, empty for folder scans.
    var extras: [(SpecialSpace, Int64)] {
        guard let tree, let source = extrasSource else { return [] }
        return source.extras(scanned: tree.root.size)
    }

    private var extrasSource: ExtrasSource? {
        if let volume = scannedVolume { return .disk(used: volume.usedBytes, free: volume.availableBytes) }
        if let usage = iCloudUsage {
            return .iCloud(categories: usage.storageUsageByMedia.map { ($0.mediaKey, $0.usageInBytes) },
                           free: max(usage.storageUsageInfo.totalStorageInBytes - usage.storageUsageInfo.usedStorageInBytes, 0),
                           photosOnMac: photosLibraryNode.flatMap { tree?.nodes[Int($0)].size } ?? 0)
        }
        return nil
    }

    /// The iCloud account's usage, when the scan is of iCloud Drive with files only in iCloud
    /// counted and the user signed in to iCloud.com: the chart then shows all of iCloud.
    var iCloudUsage: ICloudStorage.Usage? {
        guard countsCloudFiles, let rootPath, DataVolume.displayPath(rootPath) == CloudFolder.iCloudPath,
              case .loaded(let usage, _, _) = iCloudStorage.state else { return nil }
        return usage
    }

    func bytes(of special: SpecialSpace) -> Int64 {
        (phase == .scanning ? liveExtras : extras).first { $0.0 == special }?.1 ?? 0
    }

    /// Why folders couldn't be read: without Full Disk Access, that's the likely reason; with
    /// it, macOS protects them from every app (System Integrity Protection).
    var unreadableHint: String {
        FullDiskAccess.isGranted
            ? "macOS protects these folders from all apps, even with Full Disk Access."
            : "Grant DirSizes Full Disk Access to scan protected folders."
    }

    /// Folders the scan couldn't open, as shown to users (/Library, not /System/Volumes/Data/Library).
    var unreadableFolders: [String] {
        guard let tree else { return [] }
        return tree.unreadable.filter { !tree.isRemoved($0) }
            .map { DataVolume.displayPath(tree.path(of: $0)) }
            .sorted()
    }

    /// The name shown for a special segment.
    func label(of special: SpecialSpace) -> String {
        switch special {
        case .free: phase == .scanning || iCloudUsage == nil ? "Free space" : "Free in iCloud"
        case .hidden: phase == .scanning ? "Not scanned yet" : "Hidden space"
        case .iCloud("docs"): phase == .scanning ? "Not scanned yet" : "Other documents and app data"
        case .iCloud(let key): iCloudMedia(key)?.displayLabel ?? key
        case .photosInCloud: "Photos only in iCloud"
        }
    }

    /// The color of an iCloud category, as iCloud shows it.
    func color(of special: SpecialSpace) -> Color? {
        let key = switch special {
        case .iCloud(let key): key
        case .photosInCloud: "photos"
        case .free, .hidden: ""
        }
        return iCloudMedia(key).map(ICloudStorage.color)
    }

    private func iCloudMedia(_ key: String) -> ICloudStorage.Usage.Media? {
        guard case .loaded(let usage, _, _) = iCloudStorage.state else { return nil }
        return usage.storageUsageByMedia.first { $0.mediaKey == key }
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
        cloudFolders = CloudFolder.available()
        refreshSavedScans()
    }

    /// iCloud Drive and other cloud folders, for the start screen.
    private(set) var cloudFolders: [CloudFolder] = []
    /// The iCloud Photos estimate on the start screen.
    let photos = PhotosStorage()
    /// iCloud storage by category and family member, from iCloud.com after signing in.
    let iCloudStorage = ICloudStorage()

    /// When each disk was last scanned (saved scans only), for the start screen.
    private(set) var savedScanDates: [String: Date] = [:]

    private func refreshSavedScans() {
        var dates: [String: Date] = [:]
        for volume in volumes {
            if let date = ScanCache.savedDate(covering: volume.scanPath) { dates[volume.scanPath] = date }
        }
        for folder in cloudFolders {
            if let date = ScanCache.savedDate(covering: folder.path) { dates[folder.path] = date }
        }
        savedScanDates = dates
    }

    /// Tooltip for a Scan button: a plain scan only reads what changed since a saved scan,
    /// except where full scans are the default.
    func scanHelp(_ path: String) -> String {
        savedScanDates[path] != nil && !prefersFullScan(path)
            ? "Read what changed since the last scan" : "Read everything"
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
        hiddenSpace = nil
        tree = nil
        segments = []
        transition = nil
        intro = nil
        collected = []
        showsCollectorReview = false
        showsCleanup = false
        leftovers = nil
        unusedApps = nil
        developerCaches = nil
        oldFiles = nil
        sizeSnapshots = nil
        sizeChanges = nil
        resetDuplicates()
        startupItems = nil
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
            scan(path: rootPath, full: full, countingCloudFiles: countsCloudFiles)
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

    /// `countingCloudFiles` also counts files that are only in iCloud, at their size.
    func scan(path: String, full: Bool? = nil, countingCloudFiles: Bool = false) {
        let full = full ?? prefersFullScan(path)
        withFullDiskAccess { self.startScan(path: path, full: full, countingCloudFiles: countingCloudFiles) }
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

    private func startScan(path: String, full: Bool = false, countingCloudFiles: Bool = false) {
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
        let scanner = DiskScanner(path: path, incremental: incremental, countsCloudFiles: countingCloudFiles)
        self.scanner = scanner
        photosLibrary = nil
        photosLibraryNode = nil
        if countingCloudFiles && DataVolume.displayPath(scanner.rootPath) == CloudFolder.iCloudPath {
            scanPhotosLibrary(for: scanner)
        }
        countsCloudFiles = countingCloudFiles
        cloudBytes = []
        rootPath = scanner.rootPath
        scannedVolume = nil
        hiddenSpace = nil
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
        unusedApps = nil
        developerCaches = nil
        oldFiles = nil
        sizeSnapshots = nil
        sizeChanges = nil
        resetDuplicates()
        startupItems = nil
        filesScanned = 0
        bytesScanned = 0
        errors = 0
        changedFolders = nil
        scanInfo = nil
        scanStage = .scanning
        intro = nil
        resetLive()
        expectedBytes = Self.expectedTotal(for: totalsKey(scanner))

        Task.detached(priority: .userInitiated) {
            let result = scanner.scan()
            await self.finish(scanner, result: result)
        }

        // Counters ten times a second, the live chart less often.
        pollTask = Task {
            var tick = 0
            while !Task.isCancelled, self.scanner === scanner, self.phase == .scanning {
                self.updateProgress(from: scanner)
                // The live chart twice a second: its snapshot and layout are made off the main thread.
                if tick % 5 == 0 {
                    let source = self.extrasSource
                    let live = await Task.detached(priority: .utility) {
                        () -> (FileTree, [Segment], [KeyedSegment], [(SpecialSpace, Int64)])? in
                        guard let snapshot = scanner.liveSnapshot() else { return nil }
                        let extras = source?.extras(scanned: snapshot.root.size) ?? []
                        let segments = SunburstLayout.segments(tree: snapshot, center: 0, rings: DiskScanner.liveRings,
                                                               extras: extras)
                        return (snapshot, segments, KeyedSegment.keyed(segments, tree: snapshot), extras)
                    }.value
                    if self.scanner === scanner, self.phase == .scanning, let (snapshot, segments, keyed, extras) = live {
                        self.showLive(snapshot, segments: segments, keyed: keyed, extras: extras)
                    }
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
        let lastLive = liveMorph?.segments(at: Date())
        let liveFrame = liveChartFrame
        resetLive()
        phase = .done
        tree = result.tree
        cloudBytes = countsCloudFiles ? Self.cloudBytes(in: result.tree) : []
        if let volume = scannedVolume { scannedVolume = Self.refreshed(volume) }
        segments = layout(center: 0)
        // Before the intro, so it grows into the chart with the library.
        attachPhotosLibrary()
        if let lastLive, let liveFrame, !scanner.isCancelled {
            startIntro(from: lastLive, frame: liveFrame, tree: result.tree)
        }
        if !scanner.isCancelled {
            Self.rememberTotal(result.totalBytes, for: totalsKey(scanner))
        }
        // Scans counting cloud files can't be updated incrementally or seed other scans.
        if !scanner.isCancelled && !scanner.countsCloudFiles {
            scanInfo = result.info
            // Saved for an incremental scan next time, also after the app was quit.
            let rootPath = scanner.rootPath
            Task.detached(priority: .utility) {
                // The first time, the saved scan this one replaces is the one to compare with.
                if SizeHistory.available(covering: rootPath).isEmpty, let (old, info) = ScanCache.load(rootPath: rootPath) {
                    SizeHistory.record(old, date: info.date)
                }
                result.tree.read { SizeHistory.record($0) }
                DiskScanner.save(result)
                await MainActor.run { self.refreshSavedScans() }
            }
        }
        startMonitoring(result.tree, rootPath: scanner.rootPath)
    }

    /// Progress estimates are kept apart for scans counting cloud files: their totals differ.
    private func totalsKey(_ scanner: DiskScanner) -> String {
        scanner.countsCloudFiles ? scanner.rootPath + " (iCloud)" : scanner.rootPath
    }

    /// Bytes in iCloud only below each node, leaving out deleted items: children come after
    /// their parents, so one backwards pass adds everything up.
    private static func cloudBytes(in tree: FileTree) -> [Int64] {
        let present = tree.subtreeMask(of: 0)
        var bytes = tree.nodes.indices.map { present[$0] && tree.nodes[$0].kind == .cloudFile ? tree.nodes[$0].size : 0 }
        for i in stride(from: bytes.count - 1, to: 0, by: -1) where bytes[i] > 0 {
            bytes[Int(tree.nodes[i].parent)] += bytes[i]
        }
        return bytes
    }

    /// How much of `node` is only in iCloud; nil when the scan doesn't count cloud files.
    func bytesInCloud(_ node: Int32) -> Int64? {
        countsCloudFiles && Int(node) < cloudBytes.count ? cloudBytes[Int(node)] : nil
    }

    // MARK: - Live chart

    /// Animates the live chart from where it is now to the new snapshot's layout.
    private func showLive(_ snapshot: FileTree, segments: [Segment], keyed: [KeyedSegment],
                          extras: [(SpecialSpace, Int64)]) {
        let now = Date()
        let rings = Double(DiskScanner.liveRings)
        liveTree = snapshot
        liveSegments = segments
        liveExtras = extras
        // Lasts a bit longer than the time to the next snapshot, so the chart never stands still.
        liveMorph = ChartMorph(from: liveMorph?.segments(at: now) ?? [], to: keyed,
                               fromRings: rings, toRings: rings, duration: 0.7, easeOut: true, start: now)
    }

    private func resetLive() {
        liveTree = nil
        liveSegments = []
        liveExtras = []
        liveMorph = nil
        liveChartFrame = nil
    }

    /// The finished chart takes over from the live one: it moves and grows from the live chart's
    /// place, and its outer rings slide in.
    private func startIntro(from live: [KeyedSegment], frame: CGRect, tree: FileTree) {
        let next = ChartIntro(
            morph: ChartMorph(from: live, to: KeyedSegment.keyed(segments, tree: tree),
                              fromRings: Double(DiskScanner.liveRings), toRings: Double(Self.rings),
                              duration: ChartIntro.duration),
            liveCenter: CGPoint(x: frame.midX, y: frame.midY),
            liveOuterRadius: SunburstGeometry.outerRadius(for: frame.size))
        intro = next
        Task {
            try? await Task.sleep(for: .seconds(ChartIntro.duration))
            if self.intro?.id == next.id { self.intro = nil }
        }
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
        intro = nil
        segments = newSegments
    }

    private func layout(center: Int32) -> [Segment] {
        guard let tree else { return [] }
        var fixedHues: [Int32: Double] = [:]
        if let node = photosLibraryNode, let hue = color(of: .photosInCloud).flatMap(Self.hue) { fixedHues[node] = hue }
        return SunburstLayout.segments(tree: tree, center: center, rings: Self.rings, extras: extras,
                                       fixedHues: fixedHues)
    }

    private static func hue(of color: Color) -> Double? {
        NSColor(color).usingColorSpace(.deviceRGB).map { Double($0.hueComponent) }
    }

    /// The Photos library on this Mac, scanned along with iCloud Drive and charted next to it
    /// (in iCloud's color for Photos), so iCloud Photos splits into what is here, file by file,
    /// and what is only in iCloud. `tree` is nil when the library couldn't be read (Photos
    /// libraries are protected; reading them needs Full Disk Access).
    private(set) var photosLibrary: (path: String, tree: FileTree?)?
    /// The library's folder in the iCloud tree, once attached.
    private(set) var photosLibraryNode: Int32?

    private func scanPhotosLibrary(for scanner: DiskScanner) {
        Task.detached(priority: .utility) {
            guard let path = PhotosStorage.systemLibraryPath() else { return }
            let result = DiskScanner(path: path).scan()
            let readable = result.errors == 0 || result.totalBytes > 0
            await MainActor.run {
                guard self.scanner === scanner else { return }
                self.photosLibrary = (path, readable ? result.tree : nil)
                self.attachPhotosLibrary()
            }
        }
    }

    /// Attaches the library once both scans are done and iCloud's numbers are known.
    private func attachPhotosLibrary() {
        guard photosLibraryNode == nil, phase == .done, iCloudUsage != nil,
              let tree, let library = photosLibrary?.tree else { return }
        photosLibraryNode = tree.graft(library, under: 0)
        cloudBytes = Self.cloudBytes(in: tree)
        transition = nil
        intro = nil
        hovered = nil
        segments = layout(center: center)
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

    /// The app folders the scan covers.
    var scannedAppFolders: [String] {
        guard let tree else { return [] }
        return ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"].compactMap { path in
            DataVolume.candidates(for: path).first { tree.node(atPath: $0) != nil }
        }
    }

    /// Lists the scan's apps (not Apple's, not running ones) with their data, oldest use first.
    /// Reading the app bundles' Info.plists and Spotlight takes a moment, so it runs off the
    /// main thread.
    func findUnusedApps() {
        guard let tree, !findingUnusedApps else { return }
        let folders = scannedAppFolders
        let libraries = scannedLibraries
        guard !folders.isEmpty else {
            unusedApps = []
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        findingUnusedApps = true
        Task.detached(priority: .userInitiated) {
            let found = tree.read {
                UnusedAppFinder.find(in: $0, appFolders: folders, libraries: libraries, excluding: running,
                                     lastUsed: Self.lastOpened)
            }
            await MainActor.run {
                self.findingUnusedApps = false
                if self.tree === tree { self.unusedApps = found }
            }
        }
    }

    /// The home folder's path in the scan, if the scan covers it.
    var scannedHome: String? {
        guard let tree, !isDemo else { return nil }
        return DataVolume.candidates(for: NSHomeDirectory()).first { tree.node(atPath: $0) != nil }
    }

    /// Where to look for projects: the home folder, or the scanned folder when it is inside it.
    private var projectsRoot: Int32? {
        guard let tree, !isDemo else { return nil }
        if let home = scannedHome { return tree.node(atPath: home) }
        let root = DataVolume.displayPath(tree.path(of: 0))
        return root.hasPrefix(NSHomeDirectory() + "/") ? 0 : nil
    }

    func findDeveloperCaches() {
        guard let tree, !findingDeveloperCaches else { return }
        let home = scannedHome
        let projects = projectsRoot
        findingDeveloperCaches = true
        Task.detached(priority: .userInitiated) {
            let found = tree.read { DeveloperCacheFinder.find(in: $0, home: home, projects: projects) }
            await MainActor.run {
                self.findingDeveloperCaches = false
                if self.tree === tree { self.developerCaches = found }
            }
        }
    }

    func findOldFiles() {
        guard let tree, !findingOldFiles else { return }
        guard let home = scannedHome else {
            oldFiles = []
            return
        }
        findingOldFiles = true
        Task.detached(priority: .userInitiated) {
            let found = tree.read { OldFileFinder.find(in: $0, home: home) }
            await MainActor.run {
                self.findingOldFiles = false
                if self.tree === tree { self.oldFiles = found }
            }
        }
    }

    /// Looks up what the hidden space is made of (other volumes, snapshots, swap), again each
    /// time, since it changes while the Mac runs.
    func loadHiddenSpace() {
        guard let volume = scannedVolume, !loadingHiddenSpace else { return }
        loadingHiddenSpace = true
        Task.detached(priority: .userInitiated) {
            let found = HiddenSpace.load(volumePath: volume.scanPath)
            await MainActor.run {
                self.loadingHiddenSpace = false
                if self.scannedVolume?.url == volume.url { self.hiddenSpace = found }
            }
        }
    }

    /// Deletes the startup disk's local Time Machine snapshots; returns an error message.
    func deleteLocalSnapshots() async -> String? {
        let error = await HiddenSpace.deleteLocalSnapshots()
        if let volume = scannedVolume { scannedVolume = Self.refreshed(volume) }
        segments = layout(center: center)
        loadHiddenSpace()
        return error
    }

    /// Compares the scan with an earlier one: `base`, or else the newest from before this scan.
    func findSizeChanges(since base: URL? = nil) {
        guard let tree, !findingSizeChanges, let rootPath else { return }
        let started = scanInfo?.date ?? Date()
        findingSizeChanges = true
        Task.detached(priority: .userInitiated) {
            let snapshots = SizeHistory.available(covering: rootPath).filter { $0.date < started }
            let chosen = snapshots.first { $0.url == base } ?? snapshots.first
            let result = chosen.flatMap { SizeHistory.load($0.url) }.map { snapshot in
                tree.read { tree in
                    let root = DataVolume.displayPath(tree.path(of: 0))
                    return (total: (old: snapshot.size(of: root), new: tree.root.size),
                            changes: SizeChange.compare(tree, with: snapshot))
                }
            }
            await MainActor.run {
                self.findingSizeChanges = false
                guard self.tree === tree else { return }
                self.sizeSnapshots = snapshots
                if let chosen, let result {
                    self.sizeChanges = (base: chosen.url, total: result.total, changes: result.changes)
                } else {
                    self.sizeChanges = nil
                }
            }
        }
    }

    /// When Spotlight saw the app opened last.
    private nonisolated static func lastOpened(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
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
        intro = nil
        if countsCloudFiles { cloudBytes = Self.cloudBytes(in: tree) }
        self.tree = tree
        segments = layout(center: center)
        if leftovers != nil { findLeftovers() }
        if unusedApps != nil { findUnusedApps() }
        if developerCaches != nil { findDeveloperCaches() }
        if oldFiles != nil { findOldFiles() }
        if let sizeChanges { findSizeChanges(since: sizeChanges.base) }
        duplicates = duplicates?.compactMap { $0.remaining(in: tree) }
        if startupItems != nil { findStartupItems() }
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
