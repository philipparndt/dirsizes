import CoreServices
import Foundation

/// Folders that changed since an earlier scan, from the FSEvents history macOS keeps per volume.
public struct ChangeSet: Sendable {
    /// Folders whose own entries changed: read again, keep their subfolders.
    public var reread = Set<String>()
    /// Folders FSEvents could not follow in detail: scan everything below them again.
    public var rescan = Set<String>()

    public var count: Int { reread.count + rescan.count }
}

public enum ChangeHistory {
    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the volume's event history; it changes when the history was reset, after
    /// which old event IDs mean nothing.
    public static func historyID(of path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// What changed below `root` since `eventID`, or nil when a full scan is needed: the
    /// history is gone or incomplete, the root itself changed, or too much changed for an
    /// incremental scan to be worth it.
    public static func changes(below root: String, since eventID: UInt64, limit: Int = 300_000,
                               timeout: TimeInterval = 30) -> ChangeSet? {
        let collector = Collector(root: root, limit: limit)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            collector.received(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, eventID, 0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }
        let queue = DispatchQueue(label: "dirsizes.change-history")
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        let finished = collector.done.wait(timeout: .now() + timeout) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        return queue.sync { finished && !collector.invalid ? collector.changes : nil }
    }

    /// Only touched on the stream's queue.
    private final class Collector: @unchecked Sendable {
        let root: String
        let limit: Int
        let done = DispatchSemaphore(value: 0)
        var changes = ChangeSet()
        var invalid = false
        private var finished = false

        init(root: String, limit: Int) {
            self.root = root
            self.limit = limit
        }

        func received(paths: [String], flags: [FSEventStreamEventFlags]) {
            guard !finished else { return }
            for (path, flag) in zip(paths, flags) {
                func has(_ bit: Int) -> Bool { flag & FSEventStreamEventFlags(bit) != 0 }
                if has(kFSEventStreamEventFlagHistoryDone) {
                    finished = true
                    done.signal()
                    return
                }
                if has(kFSEventStreamEventFlagRootChanged) || has(kFSEventStreamEventFlagEventIdsWrapped) {
                    invalid = true
                    continue
                }
                guard let path = normalized(path) else { continue }
                if has(kFSEventStreamEventFlagMustScanSubDirs) {
                    if path == root { invalid = true }
                    changes.rescan.insert(path)
                } else {
                    changes.reread.insert(path)
                }
                if changes.count > limit { invalid = true }
            }
        }

        /// The path in the scan's terms (startup-disk events may lack the data volume prefix),
        /// or nil when it is outside the root.
        private func normalized(_ path: String) -> String? {
            var path = path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            if root.hasPrefix(DataVolume.path) {
                guard let data = DataVolume.dataPath(for: path) else { return nil }
                path = data
            }
            guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
            return path
        }
    }
}
