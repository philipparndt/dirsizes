import Darwin
import DirScanner
import Foundation
import Synchronization

/// Deletes the collector's items off the main thread. Progress is counted in bytes, using the
/// sizes from the scan, because one item can be a 4 KB file and the next a 6 GB folder.
///
/// - Trash: `FileManager.trashItem` per item (keeps Finder's Put Back), four at a time. Each
///   move is a rename, so bytes advance per item. Items the user may not move (apps from the
///   App Store or installer packages belong to root) are then handed to Finder together, which
///   asks for an administrator password once, as when dragging them to the Trash there.
/// - Permanent: the scan tree says what is inside each folder, so nothing has to be read from
///   disk first. Files are unlinked in batches by a pool of workers, across folders and items
///   at once: per-file cost dominates (measured ~150 µs a file here, with security software
///   inspecting each one), and 8 workers delete 2–2.5× faster than one, even inside a single
///   folder. A folder is removed once its files and subfolders are gone, and reported then, so
///   the chart shrinks while it runs. Files the scan doesn't know about (created since) are
///   removed by reading the folder before it is removed.
///
/// Safety: every worker reaches its folder from the item's parent one component at a time with
/// `O_NOFOLLOW` and checks it is still on the item's volume, so a folder replaced by a symlink
/// since the scan, or a disk mounted inside, is never followed. Symlinks themselves are removed.
///
/// The UI polls `snapshot()` at its own pace; the workers never wait for it.
final class CollectorDeletion: Sendable {
    struct Item: Sendable {
        let node: Int32
        let path: String
        let bytes: Int64
    }

    struct Snapshot {
        var doneBytes: Int64
        var doneItems: Int
        var failedItems: Int
        var current: String
        /// Nodes deleted since the last snapshot: finished items and, in permanent mode,
        /// finished subfolders.
        var removed: [Int32]
        var failures: [String]
        var finished: Bool
    }

    let mode: ScanModel.DeletionMode
    let items: [Item]
    private let tree: FileTree

    private let doneBytes = Atomic<Int64>(0)
    private let doneItems = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)
    private let finished = Atomic<Bool>(false)
    private let state = Mutex(State())

    private struct State {
        var current = ""
        var removed: [Int32] = []
        var failures: [String] = []
        var failedItems = Set<Int32>()
        /// Trash moves refused for lack of permission, for Finder to try with authorization.
        var needAuthorization: [Item] = []
    }

    /// Files per unlink batch: big enough to amortize reaching the folder, small enough to
    /// spread one big folder over all workers.
    private static let batchSize = 256
    /// Queued operations before the planner waits, to bound memory on huge trees.
    private static let maxQueued = 20_000
    private static let maxReportedFailures = 50

    private var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    init(mode: ScanModel.DeletionMode, items: [Item], tree: FileTree) {
        self.mode = mode
        self.items = items
        self.tree = tree
    }

    func start() {
        Thread.detachNewThread { [self] in
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            // Trash moves go through Finder's machinery; more than a few at once doesn't help.
            queue.maxConcurrentOperationCount = mode == .trash ? 4 : 8
            for item in items {
                if isCancelled { break }
                switch mode {
                case .trash: queue.addOperation { [self] in trash(item) }
                case .permanent: plan(item, on: queue)
                }
            }
            queue.waitUntilAllOperationsAreFinished()
            let refused = state.withLock { $0.needAuthorization }
            if !refused.isEmpty && !isCancelled { trashWithFinder(refused) }
            finished.store(true, ordering: .releasing)
        }
    }

    /// Stops soon: workers check between files. Everything already deleted is reported, and
    /// unfinished items stay in the collector.
    func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    func snapshot() -> Snapshot {
        let isFinished = finished.load(ordering: .acquiring)
        return state.withLock { state in
            defer { state.removed.removeAll(keepingCapacity: true) }
            return Snapshot(doneBytes: doneBytes.load(ordering: .relaxed),
                            doneItems: doneItems.load(ordering: .relaxed),
                            failedItems: state.failedItems.count, current: state.current,
                            removed: state.removed, failures: state.failures, finished: isFinished)
        }
    }

    // MARK: - Trash

    private func trash(_ item: Item) {
        guard !isCancelled else { return }
        defer { doneItems.add(1, ordering: .relaxed) }
        setCurrent(item.path)
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            finish(item, counted: 0)
        } catch {
            // Already gone (e.g. deleted by another app) counts as done.
            if !FileManager.default.fileExists(atPath: item.path) {
                finish(item, counted: 0)
            } else if Self.isPermissionError(error) {
                state.withLock { $0.needAuthorization.append(item) }
            } else {
                fail(item.node, "\(name(of: item.path)): \(error.localizedDescription)")
            }
        }
    }

    private static func isPermissionError(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EACCES) || posix.code == Int(EPERM))
    }

    /// Asks Finder to move `items` to the Trash in one go: it asks for an administrator password
    /// where needed, and keeps Put Back. The first time, macOS asks whether DirSizes may
    /// control Finder. Runs on the deletion thread, after the other items.
    private func trashWithFinder(_ items: [Item]) {
        setCurrent(items.count == 1 ? items[0].path : "\(items.count) items that need your password")
        let files = items.map { item in
            let escaped = item.path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "POSIX file \"\(escaped)\""
        }
        let source = "tell application \"Finder\" to delete {\(files.joined(separator: ", "))}"
        // osascript rather than NSAppleScript, which would block the main thread (and the UI)
        // while Finder's password dialog is open. macOS still asks about DirSizes, which started it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        var output = ""
        if (try? process.run()) != nil {
            output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
        }
        for item in items {
            if !FileManager.default.fileExists(atPath: item.path) {
                finish(item, counted: 0)
                continue
            }
            // osascript reports "… (-128)" when the password was cancelled, "(-1743)" when
            // DirSizes may not send Finder commands.
            let reason = if output.contains("(-128)") {
                "cancelled"
            } else if output.contains("(-1743)") {
                "DirSizes may not control Finder. Allow it in System Settings → Privacy & Security → Automation."
            } else {
                "you don't have permission to move it"
            }
            fail(item.node, "\(name(of: item.path)): \(reason)")
        }
    }

    // MARK: - Permanent

    /// One item being deleted permanently: the open parent folder every worker starts from.
    private final class Job: Sendable {
        let item: Item
        let parentFD: Int32
        let device: dev_t
        /// Bytes of this item's files deleted so far, to top up to the item's size at the end.
        let counted = Atomic<Int64>(0)
        let failed = Atomic<Bool>(false)

        init(item: Item, parentFD: Int32, device: dev_t) {
            self.item = item
            self.parentFD = parentFD
            self.device = device
        }
    }

    private struct Entry {
        let node: Int32
        let name: String
        let bytes: Int64
    }

    /// Queues the operations that delete one item: file batches, then each folder after its
    /// contents, then the item's completion.
    private func plan(_ item: Item, on queue: OperationQueue) {
        let parentFD = open((item.path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let name = name(of: item.path)
        var info = stat()
        guard parentFD >= 0, fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if parentFD >= 0 { close(parentFD) }
            if code == ENOENT { finish(item, counted: 0) } else { fail(item.node, item.path, code) }
            doneItems.add(1, ordering: .relaxed)
            return
        }
        let job = Job(item: item, parentFD: parentFD, device: info.st_dev)

        let top: Operation
        if (info.st_mode & S_IFMT) == S_IFDIR {
            top = planDirectory(job, node: item.node, components: [name], on: queue)
        } else {
            top = BlockOperation { [self] in
                guard !isCancelled else { return }
                if unlinkat(job.parentFD, name, 0) != 0 && errno != ENOENT {
                    fail(job, item.path, errno)
                }
            }
            queue.addOperation(top)
        }

        let completion = BlockOperation { [self] in
            close(job.parentFD)
            if !job.failed.load(ordering: .relaxed) && !isCancelled {
                finish(item, counted: job.counted.load(ordering: .relaxed))
            }
            doneItems.add(1, ordering: .relaxed)
        }
        completion.addDependency(top)
        queue.addOperation(completion)
    }

    /// Queues one folder's file batches and subfolders, and returns the operation that removes
    /// the folder once they are done.
    private func planDirectory(_ job: Job, node: Int32, components: [String], on queue: OperationQueue) -> Operation {
        // Bound memory: let the workers catch up on huge trees.
        while queue.operationCount > Self.maxQueued && !isCancelled {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let (files, folders) = tree.read { tree -> ([Entry], [Entry]) in
            var files: [Entry] = []
            var folders: [Entry] = []
            for child in tree.children(of: node) {
                let entry = Entry(node: child, name: tree.name(of: child), bytes: tree.nodes[Int(child)].size)
                if tree.nodes[Int(child)].isDirectory { folders.append(entry) } else { files.append(entry) }
            }
            return (files, folders)
        }

        let removeFolder = BlockOperation { [self] in
            removeDirectory(job, node: node, components: components)
        }
        for start in stride(from: 0, to: files.count, by: Self.batchSize) {
            let batch = files[start..<min(start + Self.batchSize, files.count)]
            let unlinkBatch = BlockOperation { [self] in
                unlinkFiles(batch, in: components, job: job)
            }
            removeFolder.addDependency(unlinkBatch)
            queue.addOperation(unlinkBatch)
        }
        for folder in folders {
            if isCancelled { break }
            removeFolder.addDependency(planDirectory(job, node: folder.node, components: components + [folder.name], on: queue))
        }
        queue.addOperation(removeFolder)
        return removeFolder
    }

    private func unlinkFiles(_ files: ArraySlice<Entry>, in components: [String], job: Job) {
        guard !isCancelled, let fd = openDirectory(components, job: job) else { return }
        defer { close(fd) }
        setCurrent(path(job, components))
        for file in files {
            if isCancelled { return }
            if unlinkat(fd, file.name, 0) == 0 || errno == ENOENT {
                doneBytes.add(file.bytes, ordering: .relaxed)
                job.counted.add(file.bytes, ordering: .relaxed)
            } else if errno == EPERM || errno == EISDIR {
                // Replaced by a folder since the scan: removeDirectory's purge takes care of it.
                continue
            } else {
                fail(job, path(job, components + [file.name]), errno)
            }
        }
    }

    private func removeDirectory(_ job: Job, node: Int32, components: [String]) {
        guard !isCancelled, !job.failed.load(ordering: .relaxed),
              let parent = openDirectory(Array(components.dropLast()), job: job)
        else { return }
        defer { close(parent) }
        let name = components[components.count - 1]
        if unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT {
            if node != job.item.node { removed(node) }
            return
        }
        // Not empty: files the scan doesn't know about.
        if errno == ENOTEMPTY || errno == EEXIST, let fd = openDirectory(components, job: job) {
            purge(fd, path: path(job, components), job: job)
            close(fd)
            if unlinkat(parent, name, AT_REMOVEDIR) == 0 {
                if node != job.item.node { removed(node) }
                return
            }
        }
        fail(job, path(job, components), errno)
    }

    /// Opens a folder below the item's parent one component at a time, never following a
    /// symlink and never leaving the item's volume. The caller closes the result.
    private func openDirectory(_ components: [String], job: Job) -> Int32? {
        var fd = dup(job.parentFD)
        guard fd >= 0 else { return nil }
        for component in components {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else {
                if code != ENOENT { fail(job, path(job, components), code) }
                return nil
            }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_dev == job.device else {
                close(next)
                fail(job, "\(path(job, components)): is on another volume, left alone")
                return nil
            }
            fd = next
        }
        return fd
    }

    /// Empties a folder by reading it (for files the scan doesn't know about; no byte progress).
    private func purge(_ fd: Int32, path: String, job: Job) {
        for name in entries(of: fd) {
            if isCancelled { return }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                guard info.st_dev == job.device else {
                    fail(job, "\(path)/\(name): is on another volume, left alone")
                    continue
                }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { continue }
                purge(child, path: path + "/" + name, job: job)
                close(child)
                unlinkat(fd, name, AT_REMOVEDIR)
            } else {
                unlinkat(fd, name, 0)
            }
        }
    }

    /// Names in a folder, read fully before anything in it is deleted.
    private func entries(of fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private func path(_ job: Job, _ components: [String]) -> String {
        ((job.item.path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(components.joined(separator: "/"))
    }

    // MARK: - Reporting

    /// Counts the rest of the item's bytes (folders' own size, files not in the scan's view)
    /// and takes it out of the collector.
    private func finish(_ item: Item, counted: Int64) {
        doneBytes.add(max(item.bytes - counted, 0), ordering: .relaxed)
        removed(item.node)
    }

    private func removed(_ node: Int32) {
        state.withLock { $0.removed.append(node) }
    }

    private func setCurrent(_ path: String) {
        state.withLock { $0.current = path }
    }

    private func fail(_ job: Job, _ path: String, _ code: Int32) {
        fail(job, "\(path): \(String(cString: strerror(code)))")
    }

    private func fail(_ job: Job, _ message: String) {
        // A cancelled run leaves folders non-empty on purpose; that is not an error.
        guard !isCancelled else { return }
        job.failed.store(true, ordering: .relaxed)
        fail(job.item.node, message)
    }

    private func fail(_ node: Int32, _ path: String, _ code: Int32) {
        fail(node, "\(path): \(String(cString: strerror(code)))")
    }

    private func fail(_ node: Int32, _ message: String) {
        state.withLock { state in
            state.failedItems.insert(node)
            if state.failures.count < Self.maxReportedFailures { state.failures.append(message) }
        }
    }

    private func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
