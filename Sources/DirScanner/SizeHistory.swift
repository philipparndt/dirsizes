import Foundation

/// The sizes of the larger items of a scan, kept after each scan to show what grew since.
public struct SizeSnapshot: Codable, Sendable {
    /// As users know it (DataVolume.displayPath).
    public let rootPath: String
    public let date: Date
    /// Items of at least `threshold`, by path as users know it. Smaller ones count as 0.
    public let sizes: [String: Int64]

    /// What's smaller isn't recorded: a few thousand entries for a whole disk.
    public static let threshold: Int64 = 10_000_000

    /// Whether the snapshot has `path` in it (as users know it), so a missing entry means
    /// "smaller than the threshold" rather than "not scanned".
    public func covers(_ path: String) -> Bool {
        rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/")
    }

    public func size(of path: String) -> Int64 { sizes[path] ?? 0 }
}

/// Snapshots of earlier scans, a few per scanned folder.
public enum SizeHistory {
    static let directory = ScanCache.directory.deletingLastPathComponent()
        .appendingPathComponent("Sizes", isDirectory: true)
    /// Per scanned folder; at most one per hour, so rescanning doesn't push older ones out.
    private static let kept = 10

    /// Records the scan's sizes. Replaces a snapshot of the same folder made within the last hour.
    public static func record(_ tree: FileTree, date: Date = Date()) {
        let root = DataVolume.displayPath(tree.path(of: 0))
        var sizes: [String: Int64] = [:]
        for index in tree.nodes.indices where tree.nodes[index].size >= SizeSnapshot.threshold {
            let node = Int32(index)
            guard !tree.isRemoved(node) else { continue }
            sizes[DataVolume.displayPath(tree.path(of: node))] = tree.nodes[index].size
        }
        let snapshot = SizeSnapshot(rootPath: root, date: date, sizes: sizes)
        let folder = directory.appendingPathComponent(ScanCache.url(for: root).deletingPathExtension().lastPathComponent)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var existing = files(in: folder)
        if let last = existing.last, date.timeIntervalSince(last.date) < 3600 {
            try? FileManager.default.removeItem(at: last.url)
            existing.removeLast()
        }
        for old in existing.dropLast(kept - 1) {
            try? FileManager.default.removeItem(at: old.url)
        }
        guard let data = try? PropertyListEncoder.binary.encode(snapshot) else { return }
        try? data.write(to: folder.appendingPathComponent("\(Int(date.timeIntervalSince1970)).sizes"))
    }

    /// Snapshots that cover `rootPath` (of it, or of a folder above it), newest first, without
    /// their sizes loaded.
    public static func available(covering rootPath: String) -> [(date: Date, rootPath: String, url: URL)] {
        let root = DataVolume.displayPath(rootPath)
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [(date: Date, rootPath: String, url: URL)] = []
        for folder in folders {
            // All snapshots in a folder have the same root.
            let files = files(in: folder)
            guard let first = files.last.flatMap({ load($0.url) }), first.covers(root) else { continue }
            result += files.map { ($0.date, first.rootPath, $0.url) }
        }
        return result.sorted { $0.date > $1.date }
    }

    public static func load(_ url: URL) -> SizeSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(SizeSnapshot.self, from: data)
    }

    /// Oldest first, dated by file name.
    private static func files(in folder: URL) -> [(date: Date, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "sizes", let seconds = TimeInterval(url.deletingPathExtension().lastPathComponent)
            else { return nil }
            return (Date(timeIntervalSince1970: seconds), url)
        }
        .sorted { $0.date < $1.date }
    }
}

/// A change in size between a snapshot and the scan, with the changes inside it.
public struct SizeChange: Sendable, Identifiable {
    public var id: String { path }
    /// As users know it.
    public let path: String
    /// Nil when it's gone since.
    public let node: Int32?
    public let old: Int64
    public let new: Int64
    public let children: [SizeChange]?

    public var delta: Int64 { new - old }

    /// The changes below `node` of at least `minimum` either way, largest growth first, then
    /// what shrank or is gone. Only goes into folders that changed by at least `minimum`.
    public static func compare(_ tree: FileTree, with snapshot: SizeSnapshot, minimum: Int64 = 50_000_000) -> [SizeChange] {
        // Paths in the snapshot by parent, for finding what's gone.
        var byParent: [String: [String]] = [:]
        for path in snapshot.sizes.keys {
            byParent[(path as NSString).deletingLastPathComponent, default: []].append(path)
        }

        func changes(below node: Int32, path: String, depth: Int) -> [SizeChange] {
            guard depth < 30 else { return [] }
            var result: [SizeChange] = []
            var seen = Set<String>()
            for child in tree.children(of: node) {
                let childPath = path == "/" ? "/" + tree.name(of: child) : path + "/" + tree.name(of: child)
                seen.insert(childPath)
                let new = tree.nodes[Int(child)].size
                let old = snapshot.size(of: childPath)
                guard abs(new - old) >= minimum else { continue }
                let inner = tree.nodes[Int(child)].isDirectory ? changes(below: child, path: childPath, depth: depth + 1) : []
                result.append(SizeChange(path: childPath, node: child, old: old, new: new,
                                         children: inner.isEmpty ? nil : inner))
            }
            for gone in byParent[path] ?? [] where !seen.contains(gone) {
                let old = snapshot.size(of: gone)
                if old >= minimum { result.append(SizeChange(path: gone, node: nil, old: old, new: 0, children: nil)) }
            }
            return result.sorted { $0.delta > $1.delta }
        }

        return changes(below: 0, path: DataVolume.displayPath(tree.path(of: 0)), depth: 0)
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
