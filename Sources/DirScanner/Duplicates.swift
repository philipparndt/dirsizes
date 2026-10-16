import CryptoKit
import Foundation

/// Files with the same contents, confirmed by SHA-256.
public struct DuplicateGroup: Sendable, Identifiable {
    /// The contents' SHA-256, hex.
    public let id: String
    /// Keeper first, then by path.
    public private(set) var files: [DuplicateFile]
    /// Allocated bytes of one copy.
    public let size: Int64
    /// How many copies take space of their own: pure APFS clones of one another share their
    /// blocks and count once.
    public private(set) var storedCopies: Int

    init(id: String, files: [DuplicateFile], size: Int64) {
        self.id = id
        self.files = files
        self.size = size
        storedCopies = 0
        arrange()
    }

    /// What deleting all copies but one frees.
    public var reclaimable: Int64 { Int64(max(storedCopies - 1, 0)) * size }

    /// All copies are clones sharing one set of blocks: deleting some frees nothing.
    public var isClones: Bool { storedCopies <= 1 }

    /// The copy to keep when collecting the others: the one created first (copies are created
    /// later, while Finder copies keep the modification date), then the shortest path.
    public var keeper: Int32 { files[0].node }

    public var nodes: [Int32] { files.map(\.node) }

    /// The group without files removed from the tree since, or nil when it frees nothing anymore.
    public func remaining(in tree: FileTree) -> DuplicateGroup? {
        var group = self
        group.files.removeAll { tree.isRemoved($0.node) }
        guard group.files.count >= 2 else { return nil }
        group.arrange()
        return group.isClones ? nil : group
    }

    private mutating func arrange() {
        files.sort { a, b in
            if a.created != b.created { return a.created < b.created }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
        let clones = Set(files.compactMap(\.cloneID))
        storedCopies = clones.count + files.filter { $0.cloneID == nil }.count
    }
}

public struct DuplicateFile: Sendable {
    public let node: Int32
    public let path: String
    public let modified: Date
    public let created: Date
    /// Set when the file shares all its blocks with another file (an APFS clone).
    public let cloneID: UInt64?
}

/// Looks for duplicate files in a scan: files of the same size are compared by a hash of their
/// first and last 64 KB, and those still alike by a SHA-256 of all of it. Runs on the calling
/// thread; `progress` and `cancel()` are for other threads.
public final class DuplicateSearch: @unchecked Sendable {
    public enum Stage: Sendable {
        /// Going through the scan for files of the same size.
        case listing
        /// Hashing the start and end of each candidate.
        case sampling
        /// Hashing candidates that are still alike in full.
        case hashing
    }

    public struct Progress: Sendable {
        public var stage = Stage.listing
        /// Files being compared.
        public var files = 0
        public var bytesDone: Int64 = 0
        public var bytesTotal: Int64 = 0

        public init() {}
    }

    /// Files below this many allocated bytes aren't compared.
    public let minimumSize: Int64
    private let lock = NSLock()
    private var state = Progress()
    private var cancelled = false

    private static let sampleSize = 64 * 1024
    private static let chunkSize = 1024 * 1024

    public init(minimumSize: Int64) {
        self.minimumSize = minimumSize
    }

    public var progress: Progress { lock.withLock { state } }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Stops the search soon; `run` then returns nothing.
    public func cancel() {
        lock.withLock { cancelled = true }
    }

    /// The duplicates in `tree`, most space to free first. The tree is only locked while
    /// listing candidates, not while reading files.
    public func run(in tree: FileTree) -> [DuplicateGroup] {
        let candidates = tree.read { Self.candidates(in: $0, minimumSize: minimumSize) }
        guard !isCancelled else { return [] }

        // The same length, from different files (hard links the scanner didn't zero out
        // share an inode).
        var byLength: [Int64: [Candidate]] = [:]
        var inodes = Set<[UInt64]>()
        for var candidate in candidates.joined() {
            var st = stat()
            guard lstat(candidate.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  inodes.insert([UInt64(bitPattern: Int64(st.st_dev)), st.st_ino]).inserted else { continue }
            candidate.length = Int64(st.st_size)
            candidate.modified = Date(timespec: st.st_mtimespec)
            candidate.created = Date(timespec: st.st_birthtimespec)
            byLength[candidate.length, default: []].append(candidate)
        }
        var alike = byLength.values.filter { $0.count >= 2 }

        let sampled = alike.joined().count
        lock.withLock {
            state.stage = .sampling
            state.files = sampled
            state.bytesTotal = alike.joined().reduce(0) { $0 + min($1.length, Int64(2 * Self.sampleSize)) }
        }
        alike = regroup(alike) { sample($0) }
        guard !isCancelled else { return [] }

        // Files no longer than the sample were read in full already.
        let small = alike.filter { $0[0].length <= Int64(2 * Self.sampleSize) }
        var large = alike.filter { $0[0].length > Int64(2 * Self.sampleSize) }
        lock.withLock {
            state.stage = .hashing
            state.files = large.joined().count
            state.bytesDone = 0
            state.bytesTotal = large.joined().reduce(0) { $0 + $1.length }
        }
        large = regroup(large) { fullHash($0) }
        guard !isCancelled else { return [] }

        let groups = (small + large).map { files in
            DuplicateGroup(id: files[0].hash, files: files.map { file in
                DuplicateFile(node: file.node, path: file.path, modified: file.modified, created: file.created,
                              cloneID: Self.cloneID(of: file.path))
            }, size: files[0].size)
        }
        // Clones of one another only, they take the space of one copy already.
        return groups.filter { !$0.isClones }.sorted { ($0.reclaimable, $0.size) > ($1.reclaimable, $1.size) }
    }

    // MARK: - Candidates

    struct Candidate {
        let node: Int32
        let path: String
        /// Allocated bytes, as in the tree.
        let size: Int64
        var length: Int64 = 0
        var modified = Date.distantPast
        var created = Date.distantPast
        var hash = ""
    }

    /// Packages and folders whose files belong together: deleting one copy would break them.
    private static let packageExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "xpc", "kext", "photoslibrary", "photolibrary",
        "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
        "logicx", "band", "xcarchive", "docarchive", "sparsebundle", "vmwarevm", "pvm", "utm", "rtfd",
        "pages", "numbers", "key", "lrdata", "dtbase2", "dtsparse",
    ]

    /// Dependencies and backups (hidden folders, such as .git, .Trash or .Spotlight-V100, are
    /// left out anyway).
    private static let skippedNames: Set<String> = ["node_modules", "Backups.backupdb"]

    /// macOS itself and the system's data (as users know the paths).
    private static let skippedPaths: Set<String> = [
        "/System/Library", "/System/Applications", "/System/Cryptexes", "/System/iOSSupport",
        "/System/DriverKit", "/System/Developer", "/usr", "/bin", "/sbin", "/cores", "/dev",
        "/private/var", "/private/tmp", "/Library/Apple", "/Library/Developer",
    ]

    /// Files of at least `minimumSize` in `tree`, by allocated size; only sizes shared by several.
    /// Files in iCloud only and hard links the scanner counted elsewhere (size 0) drop out. Pure
    /// APFS clones only carry their size in one node, so the others join it here: they are
    /// copies too, just ones that take no space of their own.
    static func candidates(in tree: FileTree, minimumSize: Int64) -> [[Candidate]] {
        var bySize: [Int64: [Candidate]] = [:]
        var clonesByNode: [Int32: UInt64] = [:]
        var clonesByID: [UInt64: [Int32]] = [:]
        for (node, id) in zip(tree.clones.nodes, tree.clones.ids) {
            clonesByNode[node] = id
            clonesByID[id, default: []].append(node)
        }
        let rootPath = tree.path(of: 0)
        let root = rootPath == "/" ? "" : rootPath
        var stack: [(node: Int32, path: String)] = [(0, root)]
        while let (folder, folderPath) = stack.popLast() {
            for child in tree.liveChildren(of: folder) {
                let node = tree.nodes[Int(child)]
                switch node.kind {
                case .directory:
                    guard node.size >= minimumSize else { continue }
                    let name = tree.name(of: child)
                    let path = folderPath + "/" + name
                    if !isSkipped(folder: name, path: path, in: folderPath) { stack.append((child, path)) }
                case .file where node.size >= minimumSize:
                    let path = folderPath + "/" + tree.name(of: child)
                    bySize[node.size, default: []].append(Candidate(node: child, path: path, size: node.size))
                    guard let id = clonesByNode[child] else { continue }
                    for sibling in clonesByID[id] ?? [] where sibling != child && !tree.isRemoved(sibling) {
                        let path = tree.path(of: sibling)
                        guard !isSkipped(path: path, below: root) else { continue }
                        bySize[node.size, default: []].append(Candidate(node: sibling, path: path, size: node.size))
                    }
                default:
                    continue
                }
            }
        }
        return bySize.values.filter { $0.count >= 2 }
    }

    /// Whether to leave out a folder (and what's inside). Hidden folders hold apps' and tools'
    /// own data.
    private static func isSkipped(folder name: String, path: String, in parentPath: String) -> Bool {
        if name.hasPrefix(".") || skippedNames.contains(name) || skippedPaths.contains(DataVolume.displayPath(path)) {
            return true
        }
        if let dot = name.lastIndex(of: "."),
           packageExtensions.contains(name[name.index(after: dot)...].lowercased()) { return true }
        return name == "Caches" && parentPath.hasSuffix("/Library")
    }

    /// Whether a file is in a folder left out, below the scanned folder `root`.
    private static func isSkipped(path: String, below root: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        var parent = root
        for part in path.dropFirst(root.count).split(separator: "/").dropLast() {
            let folder = parent + "/" + part
            if isSkipped(folder: String(part), path: folder, in: parent) { return true }
            parent = folder
        }
        return false
    }

    // MARK: - Hashing

    /// Splits each group by `hash` (nil: unreadable, left out), on a few threads; keeps only
    /// groups of two or more.
    private func regroup(_ groups: [[Candidate]], by hash: (Candidate) -> String?) -> [[Candidate]] {
        // Largest files first, so the threads finish together.
        let files = groups.joined().sorted { $0.length > $1.length }
        var hashes = [String?](repeating: nil, count: files.count)
        let next = NSLock()
        var index = 0
        let workers = min(4, max(ProcessInfo.processInfo.activeProcessorCount, 1))
        hashes.withUnsafeMutableBufferPointer { results in
            let results = results
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while !isCancelled {
                    let i: Int = next.withLock {
                        defer { index += 1 }
                        return index
                    }
                    guard i < files.count else { break }
                    results[i] = hash(files[i])
                }
            }
        }
        var result: [String: [Candidate]] = [:]
        for (var file, hash) in zip(files, hashes) {
            guard let hash else { continue }
            file.hash = hash
            result[hash, default: []].append(file)
        }
        return result.values.filter { $0.count >= 2 }
    }

    /// The length and a hash of the first and last 64 KB (all of it for short files).
    private func sample(_ file: Candidate) -> String? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        withUnsafeBytes(of: file.length) { hasher.update(bufferPointer: $0) }
        var buffer = [UInt8](repeating: 0, count: Self.sampleSize)
        let offsets = file.length <= Int64(2 * Self.sampleSize)
            ? [Int64(0), Int64(Self.sampleSize)]
            : [0, file.length - Int64(Self.sampleSize)]
        var read: Int64 = 0
        for offset in offsets {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Self.sampleSize, off_t(offset)) }
            guard count >= 0 else { return nil }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            read += Int64(count)
        }
        lock.withLock { state.bytesDone += read }
        return Self.hex(hasher.finalize())
    }

    /// SHA-256 of the whole file, read past the file cache.
    private func fullHash(_ file: Candidate) -> String? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        var total: Int64 = 0
        while true {
            if isCancelled { return nil }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, Self.chunkSize) }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            total += Int64(count)
            lock.withLock { state.bytesDone += Int64(count) }
        }
        // Changed since it was listed.
        guard total == file.length else { return nil }
        return Self.hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The clone ID of a file that shares all its blocks with another (a pure APFS clone).
    static func cloneID(of path: String) -> UInt64? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED) | UInt32(FSOPT_NOFOLLOW)
        guard getattrlist(path, &attrs, &buffer, buffer.count, options) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> UInt64? in
            var p = raw.baseAddress! + MemoryLayout<UInt32>.size
            let returned = p.loadUnaligned(as: attribute_set_t.self)
            p += MemoryLayout<attribute_set_t>.size
            var cloneID: UInt64 = 0
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
                cloneID = p.loadUnaligned(as: UInt64.self)
                p += 8
            }
            var flags: UInt64 = 0
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                flags = p.loadUnaligned(as: UInt64.self)
            }
            return flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 && cloneID != 0 ? cloneID : nil
        }
    }
}

private extension Date {
    init(timespec t: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }
}
