import DirScanner

/// The collected items in their place in the folder hierarchy, for reviewing them: the folders
/// above them (sized by what is collected inside), the items, and everything inside the items.
/// Nodes are the scan tree's own, so nothing is copied.
struct CollectionTree {
    let tree: FileTree
    /// The deepest folder containing every collected item: the chart's and the tree's root.
    let top: Int32
    private let collected: Set<Int32>
    /// Folders above collected items: collected bytes inside, and their children on the way
    /// to collected items, largest first.
    private let ancestorBytes: [Int32: Int64]
    private let ancestorChildren: [Int32: [Int32]]

    init(tree: FileTree, collected: [Int32]) {
        self.tree = tree
        self.collected = Set(collected)
        var bytes: [Int32: Int64] = [:]
        var children: [Int32: Set<Int32>] = [:]
        var common: [Int32]?
        for item in collected {
            let chain = tree.ancestry(of: item)
            for (parent, child) in zip(chain, chain.dropFirst()) {
                bytes[parent, default: 0] += tree.nodes[Int(item)].size
                children[parent, default: []].insert(child)
            }
            let ancestors = Array(chain.dropLast())
            common = common.map { Array(zip($0, ancestors).prefix { $0 == $1 }.map(\.0)) } ?? ancestors
        }
        top = common?.last ?? 0
        ancestorBytes = bytes
        ancestorChildren = children.mapValues { set in
            set.sorted { (bytes[$0] ?? tree.nodes[Int($0)].size) > (bytes[$1] ?? tree.nodes[Int($1)].size) }
        }
    }

    var totalBytes: Int64 { size(of: top) }

    func size(of node: Int32) -> Int64 {
        ancestorBytes[node] ?? tree.nodes[Int(node)].size
    }

    /// Below `top`, a node is either a folder on the way to collected items or inside one.
    func children(of node: Int32) -> [Int32] {
        ancestorChildren[node] ?? tree.children(of: node)
    }

    func isDirectory(_ node: Int32) -> Bool {
        tree.nodes[Int(node)].isDirectory
    }

    /// A folder above collected items rather than one of them or inside one.
    func isAncestor(_ node: Int32) -> Bool {
        ancestorChildren[node] != nil
    }

    func isCollectedItem(_ node: Int32) -> Bool {
        collected.contains(node)
    }

    /// Folders above collected items with just one way down are shown as one row
    /// ("Library/Developer/Xcode"): the last folder of the chain, and the name to show.
    func collapsedChain(from node: Int32) -> (node: Int32, name: String) {
        var current = node
        var names = [tree.name(of: node)]
        while let next = ancestorChildren[current], next.count == 1, isAncestor(next[0]) {
            current = next[0]
            names.append(tree.name(of: current))
        }
        return (current, names.joined(separator: "/"))
    }
}

extension SunburstLayout {
    /// Lays out any tree given by `size` and `children`, `rings` levels below `center`, with hues
    /// from each item's position in this chart.
    static func segments(center: Int32, rings: Int, size: (Int32) -> Int64, children: (Int32) -> [Int32],
                         isDirectory: (Int32) -> Bool) -> [Segment] {
        var result: [Segment] = []
        func visit(_ node: Int32, depth: Int, start: Double, end: Double) {
            let total = Double(size(node))
            guard depth < rings, total > 0 else { return }
            var angle = start
            for child in children(node) {
                let sweep = (end - start) * Double(size(child)) / total
                if sweep < minAngle { break }
                result.append(Segment(node: child, depth: depth + 1, start: angle, end: angle + sweep,
                                      hue: (angle + sweep / 2) / (2 * .pi)))
                if isDirectory(child) {
                    visit(child, depth: depth + 1, start: angle, end: angle + sweep)
                }
                angle += sweep
            }
        }
        visit(center, depth: 0, start: 0, end: 2 * .pi)
        return result
    }
}
