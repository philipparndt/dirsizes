import Foundation

/// One file or directory. Kept small (24 bytes) because a full disk scan can produce
/// millions of these; names live in a shared byte buffer instead of per-node Strings.
public struct Node: Sendable {
    /// Allocated bytes on disk. For directories this is the recursive total after `finalize()`.
    public var size: Int64
    /// Index of the parent node, -1 for the root.
    public var parent: Int32
    public var nameOffset: UInt32
    /// Recursive number of files below a directory (1 for a file).
    public var itemCount: UInt32
    public var nameLength: UInt16
    public var kind: Kind

    public enum Kind: UInt8, Sendable {
        case file
        case directory
        case symlink
        case other
    }

    public var isDirectory: Bool { kind == .directory }
}

/// Flat, arena-style tree. Children are always appended after their parent,
/// so a single reverse pass over `nodes` aggregates sizes bottom-up.
public final class FileTree: @unchecked Sendable {
    public internal(set) var nodes: [Node] = []
    public internal(set) var names: [UInt8] = []

    private var childStart: [Int32] = []
    private var childList: [Int32] = []
    /// Nodes deleted after the scan. Their subtrees are unreachable through `children(of:)`.
    private var removed = Set<Int32>()
    /// `remove(_:)` is the only mutation after the scan and runs on the main thread, so main-thread
    /// readers need no lock. Readers on other threads go through `read(_:)`.
    private let lock = NSLock()

    init(rootName: String) {
        let bytes = Array(rootName.utf8)
        names.append(contentsOf: bytes)
        nodes.append(Node(size: 0, parent: -1, nameOffset: 0, itemCount: 0,
                          nameLength: UInt16(clamping: bytes.count), kind: .directory))
    }

    public var root: Node { nodes[0] }

    public func name(of index: Int32) -> String {
        let node = nodes[Int(index)]
        let start = Int(node.nameOffset)
        return String(decoding: names[start..<start + Int(node.nameLength)], as: UTF8.self)
    }

    public func path(of index: Int32) -> String {
        var parts: [String] = []
        var i = index
        while i > 0 {
            parts.append(name(of: i))
            i = nodes[Int(i)].parent
        }
        let root = name(of: 0)
        guard !parts.isEmpty else { return root }
        return (root == "/" ? "" : root) + "/" + parts.reversed().joined(separator: "/")
    }

    /// Ancestors from the root down to and including `index`.
    public func ancestry(of index: Int32) -> [Int32] {
        var chain: [Int32] = []
        var i = index
        while i >= 0 {
            chain.append(i)
            i = nodes[Int(i)].parent
        }
        return chain.reversed()
    }

    /// Children of `index`, largest first.
    public func children(of index: Int32) -> [Int32] {
        unsortedChildren(of: index)
            .filter { !removed.contains($0) }
            .sorted { nodes[Int($0)].size > nodes[Int($1)].size }
    }

    private func unsortedChildren(of index: Int32) -> ArraySlice<Int32> {
        if childStart.isEmpty { buildChildIndex() }
        let i = Int(index)
        return childList[Int(childStart[i])..<Int(childStart[i + 1])]
    }

    /// Whether `index` or one of its ancestors was removed.
    public func isRemoved(_ index: Int32) -> Bool {
        var i = index
        while i >= 0 {
            if removed.contains(i) { return true }
            i = nodes[Int(i)].parent
        }
        return false
    }

    /// For every node, whether it lies inside `index` (inclusive) and wasn't removed. One forward
    /// pass, since parents always come before their children.
    public func subtreeMask(of index: Int32) -> [Bool] {
        var mask = [Bool](repeating: false, count: nodes.count)
        guard Int(index) < nodes.count, !isRemoved(index) else { return mask }
        mask[Int(index)] = true
        for i in (Int(index) + 1)..<nodes.count {
            let parent = Int(nodes[i].parent)
            mask[i] = parent >= 0 && mask[parent] && !removed.contains(Int32(i))
        }
        return mask
    }

    /// Runs `body` with the tree locked against `remove(_:)`, for reading off the main thread.
    public func read<T>(_ body: (FileTree) throws -> T) rethrows -> T {
        try lock.withLock { try body(self) }
    }

    /// Takes a deleted file or folder out of the tree and subtracts it from all ancestors.
    public func remove(_ index: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard index > 0, !isRemoved(index) else { return }
        let node = nodes[Int(index)]
        let count = node.isDirectory ? node.itemCount : 1
        var p = node.parent
        while p >= 0 {
            nodes[Int(p)].size -= node.size
            nodes[Int(p)].itemCount -= count
            p = nodes[Int(p)].parent
        }
        removed.insert(index)
    }

    /// The node for an absolute path inside this tree, if it was scanned.
    public func node(atPath path: String) -> Int32? {
        let root = name(of: 0)
        guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        var current: Int32 = 0
        for component in path.dropFirst(root.count).split(separator: "/") {
            guard let next = unsortedChildren(of: current).first(where: {
                !removed.contains($0) && name(of: $0) == component
            }) else { return nil }
            current = next
        }
        return current
    }

    /// Sum sizes and item counts into parents, and index children. After this the tree only
    /// changes through `remove(_:)`.
    func finalize() {
        defer { buildChildIndex() }
        for i in stride(from: nodes.count - 1, to: 0, by: -1) {
            let node = nodes[i]
            let p = Int(node.parent)
            nodes[p].size += node.size
            nodes[p].itemCount &+= node.isDirectory ? node.itemCount : 1
        }
    }

    /// Counting sort of nodes by parent into a CSR-style adjacency list.
    func buildChildIndex() {
        var start = [Int32](repeating: 0, count: nodes.count + 1)
        for node in nodes where node.parent >= 0 {
            start[Int(node.parent) + 1] += 1
        }
        for i in 1..<start.count { start[i] += start[i - 1] }
        var fill = start
        var list = [Int32](repeating: 0, count: max(nodes.count - 1, 0))
        for (i, node) in nodes.enumerated() where node.parent >= 0 {
            let p = Int(node.parent)
            list[Int(fill[p])] = Int32(i)
            fill[p] += 1
        }
        childStart = start
        childList = list
    }
}
