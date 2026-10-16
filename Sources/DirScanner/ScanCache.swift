import Foundation

/// What a saved scan needs for an incremental rescan.
public struct ScanInfo: Codable, Sendable {
    public var rootPath: String
    /// FSEvents event ID taken when the scan started: changes after it are replayed.
    public var eventID: UInt64
    /// The volume's FSEvents history the event ID belongs to.
    public var historyID: String?
    public var date: Date
}

/// Saves scans to the user's Caches folder, one file per scanned folder or disk, so the next
/// scan only has to look at what changed. The file holds the tree as it is in memory.
public enum ScanCache {
    public static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("de.rnd7.dirsizes/Scans", isDirectory: true)

    private static let magic: UInt32 = 0x315A_5344 // "DSZ1"
    private static let version: UInt32 = 1

    static func url(for rootPath: String) -> URL {
        // FNV-1a: a stable file name per root.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rootPath.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.scan", hash))
    }

    /// False when not saved because a saved scan of a folder above covers it.
    @discardableResult
    public static func save(_ tree: FileTree, info: ScanInfo) throws -> Bool {
        // A saved scan of a folder above covers this one already; saving it too would only
        // push that (usually bigger, slower) scan out of the kept ones.
        if savedInfos().contains(where: { $0.rootPath != info.rootPath && nodePath(of: info.rootPath, under: $0.rootPath) != nil }) {
            return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(for: info.rootPath)
        let temporary = url.appendingPathExtension(UUID().uuidString)
        let infoData = try JSONEncoder().encode(info)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var ok = true
        func write<T>(_ array: [T]) {
            array.withUnsafeBytes { bytes in
                var offset = 0
                while ok && offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if written <= 0 { ok = false } else { offset += written }
                }
            }
        }
        tree.read { tree in
            write([magic, version, UInt32(MemoryLayout<Node>.stride), UInt32(infoData.count)])
            write(Array(infoData))
            write([tree.nodes.count, tree.names.count, tree.hardLinks.nodes.count, tree.clones.nodes.count,
                   tree.unreadable.count].map(Int64.init))
            write(tree.nodes)
            write(tree.names)
            write(tree.hardLinks.nodes)
            write(tree.hardLinks.ids)
            write(tree.hardLinks.sizes)
            write(tree.clones.nodes)
            write(tree.clones.ids)
            write(tree.clones.sizes)
            write(tree.unreadable)
        }
        close(fd)
        guard ok else {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(.EIO)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        prune()
        return true
    }

    /// A whole-disk scan takes a few hundred MB; only the most recently used ones are kept.
    private static func prune(keeping limit: Int = 5) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let scans = files.filter { $0.pathExtension == "scan" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in scans.dropFirst(limit) {
            try? fm.removeItem(at: file)
        }
    }

    /// The saved scan of `rootPath`, if there is a readable one.
    public static func load(rootPath: String) -> (FileTree, ScanInfo)? {
        guard let data = try? Data(contentsOf: url(for: rootPath), options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { buffer -> (FileTree, ScanInfo)? in
            var offset = 0
            func read<T>(_ type: T.Type, count: Int) -> [T]? {
                let length = count * MemoryLayout<T>.stride
                guard count >= 0, offset + length <= buffer.count else { return nil }
                let result = [T](unsafeUninitializedCapacity: count) { target, initialized in
                    UnsafeMutableRawBufferPointer(target).copyMemory(
                        from: UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + length]))
                    initialized = count
                }
                offset += length
                return result
            }
            guard let header = read(UInt32.self, count: 4), header[0] == magic, header[1] == version,
                  header[2] == UInt32(MemoryLayout<Node>.stride),
                  let infoBytes = read(UInt8.self, count: Int(header[3])),
                  let info = try? JSONDecoder().decode(ScanInfo.self, from: Data(infoBytes)),
                  info.rootPath == rootPath,
                  let counts = read(Int64.self, count: 5),
                  let nodes = read(Node.self, count: Int(counts[0])), !nodes.isEmpty,
                  let names = read(UInt8.self, count: Int(counts[1])),
                  let hardLinkNodes = read(Int32.self, count: Int(counts[2])),
                  let hardLinkIDs = read(UInt64.self, count: Int(counts[2])),
                  let hardLinkSizes = read(Int64.self, count: Int(counts[2])),
                  let cloneNodes = read(Int32.self, count: Int(counts[3])),
                  let cloneIDs = read(UInt64.self, count: Int(counts[3])),
                  let cloneSizes = read(Int64.self, count: Int(counts[3])),
                  let unreadable = read(Int32.self, count: Int(counts[4])),
                  offset == buffer.count
            else { return nil }
            // A damaged file must not crash the app: parents come before children, names fit.
            for (i, node) in nodes.enumerated().dropFirst()
            where node.parent < 0 || Int(node.parent) >= i || Int(node.nameOffset) + Int(node.nameLength) > names.count {
                return nil
            }
            let tree = FileTree(nodes: nodes, names: names,
                                hardLinks: IDTable(nodes: hardLinkNodes, ids: hardLinkIDs, sizes: hardLinkSizes),
                                clones: IDTable(nodes: cloneNodes, ids: cloneIDs, sizes: cloneSizes),
                                unreadable: unreadable)
            return (tree, info)
        }
    }

    /// The saved scan of `rootPath`, or else the part of a saved scan of a folder or disk above
    /// it (the most specific one).
    public static func load(covering rootPath: String) -> (FileTree, ScanInfo)? {
        if let exact = load(rootPath: rootPath) { return exact }
        let candidates = savedInfos()
            .filter { nodePath(of: rootPath, under: $0.rootPath) != nil }
            .sorted { $0.rootPath.count > $1.rootPath.count }
        for info in candidates {
            if let (tree, info) = load(rootPath: info.rootPath), let narrowed = narrow(tree, info, to: rootPath) {
                return narrowed
            }
        }
        return nil
    }

    /// `tree` (a scan of `info.rootPath`) cut down to `rootPath` below it.
    public static func narrow(_ tree: FileTree, _ info: ScanInfo, to rootPath: String) -> (FileTree, ScanInfo)? {
        if info.rootPath == rootPath { return (tree, info) }
        guard let path = nodePath(of: rootPath, under: info.rootPath),
              let node = tree.read({ $0.node(atPath: path) }), tree.nodes[Int(node)].isDirectory
        else { return nil }
        var narrowedInfo = info
        narrowedInfo.rootPath = rootPath
        return (tree.read { $0.subtree(at: node, rootName: rootPath) }, narrowedInfo)
    }

    /// Where `path` is in a scan of `root`, if inside it. A startup disk scan is rooted at the
    /// data volume, which holds /Users, /Applications and so on.
    private static func nodePath(of path: String, under root: String) -> String? {
        for candidate in DataVolume.candidates(for: path) {
            if candidate == root { return candidate }
            if candidate.hasPrefix(root == "/" ? "/" : root + "/") { return candidate }
        }
        return nil
    }

    /// When the saved scan of `rootPath`, or of the closest folder above it, was taken.
    public static func savedDate(covering rootPath: String) -> Date? {
        savedInfos().filter { nodePath(of: rootPath, under: $0.rootPath) != nil }
            .max { $0.rootPath.count < $1.rootPath.count }?.date
    }

    private static func savedInfos() -> [ScanInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "scan" }.compactMap { readInfo(at: $0) }
    }

    /// Just the header of a saved scan.
    private static func readInfo(at url: URL) -> ScanInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else { return nil }
        let words = header.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        guard words[0] == magic, words[1] == version,
              let data = try? handle.read(upToCount: Int(words[3])), data.count == Int(words[3])
        else { return nil }
        return try? JSONDecoder().decode(ScanInfo.self, from: data)
    }

    public static func remove(rootPath: String) {
        try? FileManager.default.removeItem(at: url(for: rootPath))
    }
}
