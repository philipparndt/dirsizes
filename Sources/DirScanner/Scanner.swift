import Darwin
import Foundation
import Synchronization

public struct ScanResult: Sendable {
    public let tree: FileTree
    public let files: Int
    public let directories: Int
    public let errors: Int
    public let duration: Duration
    /// For saving the scan and updating it incrementally next time.
    public let info: ScanInfo
    /// How many folders were read again in an incremental scan; nil for a full scan.
    public let changedFolders: Int?

    public var totalBytes: Int64 { tree.root.size }
}

/// Parallel directory scanner built on `getattrlistbulk(2)`.
///
/// Each directory is opened once and its entries (name, type, inode, link count,
/// allocated size) are read in bulk, many per syscall, instead of readdir + lstat
/// per entry. Directories are processed by a pool of worker threads pulling from a
/// shared LIFO stack (depth-first keeps the pending set small).
///
/// Incremental: given an earlier scan of the same folder (in memory or saved by `ScanCache`),
/// it replays the volume's FSEvents history since then, copies unchanged folders from the
/// earlier tree without touching the disk and reads only the folders that changed.
public final class DiskScanner: @unchecked Sendable {
    public enum Incremental: Sendable {
        /// Read everything.
        case off
        /// Start from the scan `ScanCache` saved for this folder or a folder above it, if any.
        case cached
        /// Start from this earlier scan, of this folder or a folder above it.
        case previous(FileTree, ScanInfo)
    }

    public enum Stage: Int, Sendable {
        case loadingPrevious, checkingChanges, scanning
    }

    /// One worker per performance core: more threads mostly add contention in the kernel.
    public static let defaultThreads: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
        return ProcessInfo.processInfo.activeProcessorCount
    }()

    public let rootPath: String
    public let threadCount: Int
    public let stayOnDevice: Bool

    // Live progress, readable from any thread while a scan runs.
    public let filesScanned = Atomic<Int>(0)
    public let bytesScanned = Atomic<Int64>(0)
    public let directoriesScanned = Atomic<Int>(0)
    public let errorCount = Atomic<Int>(0)
    private let stageValue = Atomic<Int>(Stage.scanning.rawValue)
    public var stage: Stage { Stage(rawValue: stageValue.load(ordering: .relaxed)) ?? .scanning }

    private static let bufferSize = 256 * 1024

    private let tree: FileTree
    private let treeLock = NSLock()
    /// Copied-over nodes that carried a hard link's or clone's size in the earlier scan; they
    /// keep it, so sizes don't move between copies from one scan to the next.
    private var keptCounted = Set<Int32>()

    private let incremental: Incremental
    /// The earlier scan being updated, and what changed since; nil for a full scan.
    private var previous: FileTree?
    private var reread = Set<String>()
    private var rescan = Set<String>()
    private var previousHardLinks: [Int32: (id: UInt64, size: Int64)] = [:]
    private var previousClones: [Int32: (id: UInt64, size: Int64)] = [:]
    /// Set under `treeLock` when `scan()` stops accepting results (finished or cancelled).
    private var frozen = false
    private let cancelled = Atomic<Bool>(false)

    private let queue = NSCondition()
    private var stack: [Job] = []
    /// Jobs queued or in progress. The scan is done when this reaches zero.
    private var pending = 0
    private var rootDevice: dev_t = 0

    private struct Job {
        let path: String
        let index: Int32
        /// The same folder in the earlier scan, or -1.
        var previous: Int32 = -1
        /// Depth below the root, and the folder (this one or above) whose live total its files
        /// count toward: the deepest one shown in the chart while scanning.
        var depth: Int = 0
        var liveAnchor: Int32 = 0
    }

    // Live totals for a chart of the top levels while scanning, under `treeLock`.
    /// How many levels below the root the live chart shows.
    public static let liveRings = 3
    /// Nodes in the top levels, in the order they were found (parents first), with their totals.
    private var liveOrder: [Int32] = []
    private var liveBytes: [Int32: Int64] = [:]
    /// Hard links and clones counted in the live totals (the final count is decided at the end).
    private var liveSeenLinks = Set<UInt64>()
    private var liveSeenClones = Set<UInt64>()

    /// The path as the scanner uses it: ~ expanded, no trailing slash.
    public static func normalizedPath(_ path: String) -> String {
        var normalized = (path as NSString).expandingTildeInPath
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    public init(path: String, threads: Int = DiskScanner.defaultThreads, stayOnDevice: Bool = true,
                incremental: Incremental = .off) {
        let normalized = Self.normalizedPath(path)
        rootPath = normalized
        threadCount = max(1, threads)
        self.stayOnDevice = stayOnDevice
        tree = FileTree(rootName: normalized)
        self.incremental = incremental
    }

    public func scan() -> ScanResult {
        let clock = ContinuousClock()
        let start = clock.now

        var st = stat()
        if stat(rootPath, &st) == 0 { rootDevice = st.st_dev }

        // Taken before reading anything, so changes during the scan are replayed next time.
        let info = ScanInfo(rootPath: rootPath, eventID: ChangeHistory.currentEventID,
                            historyID: ChangeHistory.historyID(of: rootPath), date: Date())
        let changes = prepareIncremental(historyID: info.historyID)
        stageValue.store(Stage.scanning.rawValue, ordering: .relaxed)

        stack = [Job(path: rootPath, index: 0, previous: previous == nil ? -1 : 0)]
        pending = 1

        let group = DispatchGroup()
        for _ in 0..<threadCount {
            group.enter()
            let thread = Thread { [self] in
                worker()
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        // On cancel, don't wait for workers: one can be stuck in the kernel indefinitely
        // (e.g. on a network or File Provider volume). Their late results are discarded.
        while group.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if isCancelled { break }
        }

        treeLock.lock()
        frozen = true
        countSharedOnce()
        tree.finalize()
        treeLock.unlock()
        return ScanResult(tree: tree,
                          files: filesScanned.load(ordering: .relaxed),
                          directories: directoriesScanned.load(ordering: .relaxed),
                          errors: errorCount.load(ordering: .relaxed),
                          duration: clock.now - start,
                          info: info,
                          changedFolders: changes?.count)
    }

    /// Saves the scan for an incremental update next time. Takes a moment for a whole disk.
    /// False when not saved, e.g. because a saved scan of a folder above covers it.
    @discardableResult
    public static func save(_ result: ScanResult) -> Bool {
        (try? ScanCache.save(result.tree, info: result.info)) ?? false
    }

    // MARK: - Incremental

    /// Sets up updating an earlier scan, when there is one and its change history is intact.
    private func prepareIncremental(historyID: String?) -> ChangeSet? {
        let base: (FileTree, ScanInfo)?
        switch incremental {
        case .off:
            return nil
        case let .previous(tree, info):
            stageValue.store(Stage.loadingPrevious.rawValue, ordering: .relaxed)
            base = ScanCache.narrow(tree, info, to: rootPath)
        case .cached:
            stageValue.store(Stage.loadingPrevious.rawValue, ordering: .relaxed)
            base = ScanCache.load(covering: rootPath)
        }
        guard let (old, info) = base, info.rootPath == rootPath, let historyID, info.historyID == historyID,
              !isCancelled
        else { return nil }
        stageValue.store(Stage.checkingChanges.rawValue, ordering: .relaxed)
        guard var changes = ChangeHistory.changes(below: rootPath, since: info.eventID), !isCancelled
        else { return nil }

        // Folders that couldn't be read last time are always tried again.
        old.read { old in
            for node in old.unreadable where !old.isRemoved(node) {
                changes.reread.insert(old.path(of: node))
            }
        }
        previous = old
        reread = changes.reread
        rescan = changes.rescan
        old.read { old in
            for (node, (id, size)) in zip(old.hardLinks.nodes, zip(old.hardLinks.ids, old.hardLinks.sizes)) {
                previousHardLinks[node] = (id, size)
            }
            for (node, (id, size)) in zip(old.clones.nodes, zip(old.clones.ids, old.clones.sizes)) {
                previousClones[node] = (id, size)
            }
        }
        return changes
    }

    /// Hard links (same inode) and pure APFS clones (same clone ID) share their blocks, so of
    /// all nodes with one ID only one carries the size: the one that did last time if it is
    /// still there unchanged, otherwise the first. Chrome alone keeps hundreds of clones of itself.
    private func countSharedOnce() {
        // A hard link that doesn't carry its inode's size can't carry a clone's either.
        var zeroed = Set<Int32>()
        func resolve(_ table: IDTable) {
            var counted: [UInt64: Int32] = [:]
            for (node, id) in zip(table.nodes, table.ids) where keptCounted.contains(node) && !zeroed.contains(node) {
                counted[id] = node
            }
            for (node, id) in zip(table.nodes, table.ids) where counted[id] == nil && !zeroed.contains(node) {
                counted[id] = node
            }
            for (node, (id, size)) in zip(table.nodes, zip(table.ids, table.sizes)) {
                let carries = counted[id] == node
                tree.nodes[Int(node)].size = carries ? size : 0
                if !carries { zeroed.insert(node) }
            }
        }
        resolve(tree.hardLinks)
        resolve(tree.clones)
    }

    /// Stops the scan early. `scan()` then returns the partial tree.
    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
        queue.lock()
        queue.broadcast()
        queue.unlock()
    }

    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    // MARK: - Work queue

    private func nextJob() -> Job? {
        queue.lock()
        defer { queue.unlock() }
        while stack.isEmpty && pending > 0 && !isCancelled { queue.wait() }
        return isCancelled ? nil : stack.popLast()
    }

    private func finish(_ job: Job, pushing subdirectories: [Job]) {
        queue.lock()
        stack.append(contentsOf: subdirectories)
        pending += subdirectories.count - 1
        if pending == 0 {
            queue.broadcast()
        } else {
            for _ in 0..<min(subdirectories.count, threadCount) { queue.signal() }
        }
        queue.unlock()
    }

    private func worker() {
        // Never trigger downloads of iCloud / File Provider items that were evicted from disk
        // ("dataless"). Listing one would otherwise block until it is downloaded.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var batch = Batch()
        while let job = nextJob() {
            let subdirectories = if let previous, job.previous >= 0, !reread.contains(job.path) {
                copyDirectory(job, from: previous, batch: &batch)
            } else {
                scanDirectory(job, buffer: buffer, batch: &batch)
            }
            finish(job, pushing: subdirectories)
        }
    }

    // MARK: - Directory scanning

    /// Per-worker scratch space, reused across directories to avoid reallocations.
    private struct Batch {
        var nodes: [Node] = []
        var names: [UInt8] = []
        var hardLinkIDs: [(local: Int, fileID: UInt64)] = []
        var cloneIDs: [(local: Int, cloneID: UInt64)] = []
        /// Hard links and clones copied from the earlier scan, with their full size and whether
        /// they carried it.
        var keptHardLinks: [(local: Int, fileID: UInt64, size: Int64, counted: Bool)] = []
        var keptClones: [(local: Int, cloneID: UInt64, size: Int64, counted: Bool)] = []
        var subdirectoryNames: [(local: Int, name: String, previous: Int32)] = []

        mutating func reset() {
            nodes.removeAll(keepingCapacity: true)
            names.removeAll(keepingCapacity: true)
            hardLinkIDs.removeAll(keepingCapacity: true)
            cloneIDs.removeAll(keepingCapacity: true)
            keptHardLinks.removeAll(keepingCapacity: true)
            keptClones.removeAll(keepingCapacity: true)
            subdirectoryNames.removeAll(keepingCapacity: true)
        }
    }

    private func scanDirectory(_ job: Job, buffer: UnsafeMutableRawPointer, batch: inout Batch) -> [Job] {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            errorCount.add(1, ordering: .relaxed)
            markUnreadable(job.index)
            return []
        }
        defer { close(fd) }

        if stayOnDevice && job.index != 0 {
            var st = stat()
            if fstat(fd, &st) == 0 && st.st_dev != rootDevice { return [] }
        }
        directoriesScanned.add(1, ordering: .relaxed)

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        attrs.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // Extended common attributes (with FSOPT_ATTR_CMN_EXTENDED): whether a file is a pure clone.
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)

        batch.reset()
        var fileCount = 0
        var byteCount: Int64 = 0

        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, Self.bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count < 0 {
                errorCount.add(1, ordering: .relaxed)
                markUnreadable(job.index)
                break
            }
            if count == 0 { break }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                if let parsed = parseEntry(entry + MemoryLayout<UInt32>.size) {
                    append(parsed, parent: job.index, to: &batch)
                    if parsed.kind != .directory {
                        fileCount += 1
                        byteCount += parsed.size
                    }
                }
            }
        }

        filesScanned.add(fileCount, ordering: .relaxed)
        bytesScanned.add(byteCount, ordering: .relaxed)
        // A folder read again keeps its subfolders' earlier contents, unless they changed too.
        if let previous, job.previous >= 0, !batch.subdirectoryNames.isEmpty {
            var earlier: [String: Int32] = [:]
            for child in previous.read({ $0.liveChildren(of: job.previous) }) where previous.nodes[Int(child)].isDirectory {
                earlier[previous.name(of: child)] = child
            }
            for i in batch.subdirectoryNames.indices {
                batch.subdirectoryNames[i].previous = earlier[batch.subdirectoryNames[i].name] ?? -1
            }
        }
        return commit(batch: &batch, job: job)
    }

    /// An unchanged folder: its entries come from the earlier scan, no disk access.
    private func copyDirectory(_ job: Job, from previous: FileTree, batch: inout Batch) -> [Job] {
        directoriesScanned.add(1, ordering: .relaxed)
        batch.reset()
        var fileCount = 0
        var byteCount: Int64 = 0
        for child in previous.liveChildren(of: job.previous) {
            let node = previous.nodes[Int(child)]
            let local = batch.nodes.count
            let name = previous.nameBytes(of: child)
            batch.nodes.append(Node(size: node.isDirectory ? 0 : node.size, parent: job.index,
                                    nameOffset: UInt32(batch.names.count), itemCount: 0,
                                    nameLength: node.nameLength, kind: node.kind))
            batch.names.append(contentsOf: name)
            if node.isDirectory {
                batch.subdirectoryNames.append((local, String(decoding: name, as: UTF8.self), child))
            } else {
                fileCount += 1
                byteCount += node.size
                if let (id, size) = previousHardLinks[child] {
                    batch.keptHardLinks.append((local, id, size, node.size > 0))
                }
                if let (id, size) = previousClones[child] {
                    batch.keptClones.append((local, id, size, node.size > 0))
                }
            }
        }
        filesScanned.add(fileCount, ordering: .relaxed)
        bytesScanned.add(byteCount, ordering: .relaxed)
        return commit(batch: &batch, job: job)
    }

    private func markUnreadable(_ index: Int32) {
        treeLock.lock()
        if !frozen { tree.unreadable.append(index) }
        treeLock.unlock()
    }

    private struct Entry {
        var name: UnsafeRawBufferPointer
        var kind: Node.Kind
        /// Evicted to iCloud / a File Provider: occupies no local space, must not be descended into.
        var isDataless: Bool
        var fileID: UInt64
        var linkCount: UInt32
        var size: Int64
        /// Set for files sharing all their blocks with other files (pure APFS clones).
        var cloneID: UInt64?
    }

    /// Parses one packed entry. Attributes appear in bitmap order, except ATTR_CMN_ERROR
    /// which directly follows the returned-attributes set (see getattrlistbulk(2)).
    /// Only attributes flagged in `returned` are present in the buffer.
    private func parseEntry(_ start: UnsafeRawPointer) -> Entry? {
        var p = start
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size

        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let error = p.loadUnaligned(as: UInt32.self)
            p += 4
            if error != 0 {
                errorCount.add(1, ordering: .relaxed)
                return nil
            }
        }

        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let nameRef = p.loadUnaligned(as: attrreference_t.self)
        // attr_length includes the trailing NUL.
        let name = UnsafeRawBufferPointer(start: p + Int(nameRef.attr_dataoffset),
                                          count: max(Int(nameRef.attr_length) - 1, 0))
        p += MemoryLayout<attrreference_t>.size

        var kind = Node.Kind.other
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            switch p.loadUnaligned(as: fsobj_type_t.self) {
            case VREG.rawValue: kind = .file
            case VDIR.rawValue: kind = .directory
            case VLNK.rawValue: kind = .symlink
            default: kind = .other
            }
            p += MemoryLayout<fsobj_type_t>.size
        }

        var isDataless = false
        if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            isDataless = p.loadUnaligned(as: UInt32.self) & UInt32(SF_DATALESS) != 0
            p += 4
        }

        var fileID: UInt64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            fileID = p.loadUnaligned(as: UInt64.self)
            p += 8
        }

        var linkCount: UInt32 = 1
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            linkCount = p.loadUnaligned(as: UInt32.self)
            p += 4
        }

        var size: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            size = p.loadUnaligned(as: Int64.self)
            p += 8
        }

        var cloneID: UInt64 = 0
        if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
            cloneID = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        var extendedFlags: UInt64 = 0
        if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
            extendedFlags = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        let isClone = extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 && cloneID != 0

        return Entry(name: name, kind: kind, isDataless: isDataless, fileID: fileID,
                     linkCount: linkCount, size: size, cloneID: isClone ? cloneID : nil)
    }

    private func append(_ entry: Entry, parent: Int32, to batch: inout Batch) {
        let local = batch.nodes.count
        batch.nodes.append(Node(size: entry.kind == .directory ? 0 : entry.size,
                                parent: parent,
                                nameOffset: UInt32(batch.names.count),
                                itemCount: 0,
                                nameLength: UInt16(clamping: entry.name.count),
                                kind: entry.kind))
        batch.names.append(contentsOf: entry.name)
        if entry.kind == .directory && !entry.isDataless {
            batch.subdirectoryNames.append((local, String(decoding: entry.name, as: UTF8.self), -1))
        } else {
            if entry.linkCount > 1 { batch.hardLinkIDs.append((local, entry.fileID)) }
            if let cloneID = entry.cloneID { batch.cloneIDs.append((local, cloneID)) }
        }
    }

    /// Appends a directory's entries to the shared tree under one lock acquisition.
    private func commit(batch: inout Batch, job: Job) -> [Job] {
        let parentPath = job.path
        treeLock.lock()
        if frozen {
            treeLock.unlock()
            return []
        }
        let base = tree.nodes.count
        let nameBase = UInt32(tree.names.count)

        // Which of these carries the size is decided once the scan is complete.
        for (local, fileID) in batch.hardLinkIDs {
            tree.hardLinks.append(Int32(base + local), fileID, size: batch.nodes[local].size)
        }
        for (local, cloneID) in batch.cloneIDs {
            tree.clones.append(Int32(base + local), cloneID, size: batch.nodes[local].size)
        }
        for (local, fileID, size, counted) in batch.keptHardLinks {
            tree.hardLinks.append(Int32(base + local), fileID, size: size)
            if counted { keptCounted.insert(Int32(base + local)) }
        }
        for (local, cloneID, size, counted) in batch.keptClones {
            tree.clones.append(Int32(base + local), cloneID, size: size)
            if counted { keptCounted.insert(Int32(base + local)) }
        }
        for i in batch.nodes.indices { batch.nodes[i].nameOffset += nameBase }

        tree.nodes.append(contentsOf: batch.nodes)
        tree.names.append(contentsOf: batch.names)
        addLiveTotals(batch: batch, base: base, job: job)
        treeLock.unlock()

        let separator = parentPath == "/" ? "" : "/"
        let depth = job.depth + 1
        return batch.subdirectoryNames.map { local, name, earlier in
            let path = parentPath + separator + name
            // Below a folder FSEvents lost track of, everything is read again.
            let previous = earlier >= 0 && (rescan.isEmpty || !rescan.contains(path)) ? earlier : -1
            let index = Int32(base + local)
            return Job(path: path, index: index, previous: previous, depth: depth,
                       liveAnchor: depth <= Self.liveRings ? index : job.liveAnchor)
        }
    }

    /// Adds a folder's files to the live totals, and its entries to the live chart when they are
    /// in the top levels. Under `treeLock`.
    private func addLiveTotals(batch: Batch, base: Int, job: Job) {
        guard !batch.nodes.isEmpty else { return }
        var duplicate = Set<Int>()
        for (local, id) in batch.hardLinkIDs where !liveSeenLinks.insert(id).inserted { duplicate.insert(local) }
        for (local, id) in batch.cloneIDs where !liveSeenClones.insert(id).inserted { duplicate.insert(local) }
        for (_, id, _, counted) in batch.keptHardLinks where counted { liveSeenLinks.insert(id) }
        for (_, id, _, counted) in batch.keptClones where counted { liveSeenClones.insert(id) }

        let shown = job.depth < Self.liveRings
        var bytes: Int64 = 0
        for (local, node) in batch.nodes.enumerated() {
            let size = node.isDirectory || duplicate.contains(local) ? 0 : node.size
            bytes += size
            if shown {
                liveOrder.append(Int32(base + local))
                liveBytes[Int32(base + local)] = size
            }
        }
        var folder = job.liveAnchor
        while folder > 0 {
            liveBytes[folder, default: 0] += bytes
            folder = tree.nodes[Int(folder)].parent
        }
    }

    /// The top levels found so far with their sizes so far, for a chart while scanning.
    public func liveSnapshot() -> FileTree? {
        treeLock.lock()
        defer { treeLock.unlock() }
        guard !liveOrder.isEmpty, !frozen else { return nil }
        let snapshot = FileTree(rootName: rootPath)
        var map: [Int32: Int32] = [0: 0]
        map.reserveCapacity(liveOrder.count + 1)
        var total: Int64 = 0
        for index in liveOrder {
            let node = tree.nodes[Int(index)]
            guard let parent = map[node.parent] else { continue }
            map[index] = Int32(snapshot.nodes.count)
            let size = liveBytes[index] ?? 0
            if parent == 0 { total += size }
            snapshot.nodes.append(Node(size: size, parent: parent, nameOffset: UInt32(snapshot.names.count),
                                       itemCount: 0, nameLength: node.nameLength, kind: node.kind))
            snapshot.names.append(contentsOf: tree.nameBytes(of: index))
        }
        snapshot.nodes[0].size = total
        snapshot.buildChildIndex()
        return snapshot
    }
}
