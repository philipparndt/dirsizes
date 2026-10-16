import CoreServices
import DirScanner
import Foundation

/// Watches a scanned folder with FSEvents and reports items that other apps deleted (and ones
/// that came back, e.g. restored from the Trash), so the chart can gray them out.
///
/// Built not to load the app when a lot changes at once (a build, `npm install`, a whole-disk
/// scan with busy caches):
/// - directory-level events, coalesced by FSEvents over `latency`, never one event per file;
/// - changed directories are merged into a set and checked in batches, at most every
///   `interval`, on a utility-priority queue; while a batch runs, new events just accumulate;
/// - a check reads each changed directory once (one readdir) and compares names with the tree;
/// - the main thread gets one callback per batch, and only when something actually changed.
final class DeletionMonitor: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (_ gone: Set<Int32>) -> Void

    private let tree: FileTree
    private let rootPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dirsizes.deletion-monitor", qos: .utility)
    private var stream: FSEventStreamRef?

    // Only touched on `queue`.
    /// Changed directories, and whether everything below them needs checking too (FSEvents
    /// says so when it had to drop or coalesce events).
    private var pending: [String: Bool] = [:]
    private var flushScheduled = false
    private var gone = Set<Int32>()

    private static let latency: CFTimeInterval = 1.0
    private static let interval: TimeInterval = 1.0
    /// Bounds the work of one "check everything below" request on a huge tree.
    private static let maxDirectoriesPerBatch = 50_000

    init(tree: FileTree, rootPath: String, handler: @escaping Handler) {
        self.tree = tree
        self.rootPath = rootPath
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<DeletionMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            monitor.received(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [rootPath] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               Self.latency, flags)
        else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Events (on `queue`)

    private func received(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            var path = path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            let recursive = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            // The root itself was moved or deleted: check it from its parent.
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                pending[rootPath] = true
                continue
            }
            pending[path] = (pending[path] ?? false) || recursive
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled, !pending.isEmpty else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.interval) { [weak self] in
            guard let self else { return }
            flushScheduled = false
            let batch = pending
            pending = [:]
            if check(batch) {
                let gone = self.gone
                let handler = self.handler
                Task { @MainActor in handler(gone) }
            }
            // Events that arrived during the check (FSEvents delivers them after it) wait
            // for the next interval.
            scheduleFlush()
        }
    }

    // MARK: - Checking (on `queue`)

    /// Updates `gone` for the changed directories; true when it changed.
    private func check(_ batch: [String: Bool]) -> Bool {
        let before = gone
        var budget = Self.maxDirectoriesPerBatch
        for (path, recursive) in batch where budget > 0 {
            if path == rootPath && !FileManager.default.fileExists(atPath: rootPath) {
                gone.insert(0)
                continue
            }
            guard let node = tree.read({ node(forPath: path, in: $0) }) else { continue }
            gone.remove(node) // it exists, since the event names it
            let directories = recursive ? tree.read { directories(below: node, in: $0, limit: budget) } : [node]
            budget -= directories.count
            for directory in directories {
                check(directory)
            }
        }
        return gone != before
    }

    /// Compares one directory's children in the tree with what is on disk now.
    private func check(_ directory: Int32) {
        let (path, children, insideGone) = tree.read { tree -> (String, [(Int32, String)], Bool) in
            let ancestry = tree.ancestry(of: directory)
            if tree.isRemoved(directory) || ancestry.dropLast().contains(where: gone.contains) {
                return ("", [], true)
            }
            return (tree.path(of: directory), tree.children(of: directory).map { ($0, tree.name(of: $0)) }, false)
        }
        guard !insideGone else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            if !FileManager.default.fileExists(atPath: path) { gone.insert(directory) }
            return
        }
        gone.remove(directory)
        let present = Set(names)
        for (child, name) in children {
            if present.contains(name) {
                gone.remove(child)
            } else {
                gone.insert(child)
            }
        }
    }

    private func directories(below node: Int32, in tree: FileTree, limit: Int) -> [Int32] {
        let mask = tree.subtreeMask(of: node)
        var result: [Int32] = []
        for i in Int(node)..<tree.nodes.count where mask[i] && tree.nodes[i].isDirectory {
            result.append(Int32(i))
            if result.count >= limit { break }
        }
        return result
    }

    /// FSEvents may report startup-disk paths with or without the data volume prefix.
    private func node(forPath path: String, in tree: FileTree) -> Int32? {
        if let node = tree.node(atPath: path) { return node }
        if rootPath.hasPrefix(DataVolume.path), let data = DataVolume.dataPath(for: path), data != path {
            return tree.node(atPath: data)
        }
        return nil
    }
}
