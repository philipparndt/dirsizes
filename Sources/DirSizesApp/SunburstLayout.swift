import DirScanner
import SwiftUI

/// Space that isn't a file in the tree, shown at the root of the chart: on a scanned disk, or in
/// iCloud around iCloud Drive.
enum SpecialSpace: Hashable, Sendable {
    /// Used, but not seen by the scan (system volume, snapshots, swap, unreadable folders).
    case hidden
    case free
    /// A kind of iCloud data that isn't in iCloud Drive (Photos, Backups, Mail, …), by iCloud's
    /// key. "docs" is the part of Documents that the scan didn't find as files.
    case iCloud(String)
    /// The part of iCloud Photos that isn't in the Photos library on this Mac, when the library
    /// is charted next to iCloud Drive.
    case photosInCloud
    /// A part of hidden space, in the ring outside it: another volume by name, or "rest".
    case hiddenPart(String)
    /// The part of free space macOS frees on its own, in the ring outside free space.
    case purgeable

    /// Identifies the segment across layouts.
    var key: String {
        switch self {
        case .hidden: "\u{1}hidden"
        case .free: "\u{1}free"
        case .iCloud(let key): "\u{1}icloud:" + key
        case .photosInCloud: "\u{1}icloud:photos/cloud"
        case .hiddenPart(let name): "\u{1}hidden/" + name
        case .purgeable: "\u{1}free/purgeable"
        }
    }
}

/// What the chart shows around the scanned tree at its root, for a given scanned size: free and
/// hidden space of a disk, or the rest of an iCloud account around iCloud Drive.
enum ExtrasSource: Sendable {
    case disk(used: Int64, free: Int64)
    /// iCloud's usage by category; "docs" includes iCloud Drive.
    /// `photosOnMac` is the Photos library's size when it is part of the scanned tree.
    case iCloud(categories: [(key: String, bytes: Int64)], free: Int64, photosOnMac: Int64)

    /// While scanning, hidden space (or Documents beyond iCloud Drive) includes what the scan
    /// hasn't reached yet, and shrinks as it goes.
    func extras(scanned: Int64) -> [(SpecialSpace, Int64)] {
        switch self {
        case .disk(let used, let free):
            return [(.hidden, max(used - scanned, 0)), (.free, free)]
        case .iCloud(let categories, let free, let photosOnMac):
            var result: [(SpecialSpace, Int64)] = []
            if let docs = categories.first(where: { $0.key == "docs" }) {
                result.append((.iCloud("docs"), max(docs.bytes - (scanned - photosOnMac), 0)))
            }
            for category in categories.sorted(by: { $0.bytes > $1.bytes }) where category.key != "docs" {
                if category.key == "photos" && photosOnMac > 0 {
                    // The library holds previews too, so it can be larger than what iCloud counts.
                    result.append((.photosInCloud, max(category.bytes - photosOnMac, 0)))
                } else {
                    result.append((.iCloud(category.key), category.bytes))
                }
            }
            result.append((.free, free))
            return result
        }
    }
}

/// One ring segment. Angles are in radians, 0 at the top, increasing clockwise.
struct Segment {
    /// -1 for special segments, which have no node.
    let node: Int32
    /// 1 = innermost ring (children of the center node).
    let depth: Int
    let start: Double
    let end: Double
    var special: SpecialSpace?
    /// 0...1, from the item's position in the root chart, so colors stay the same when zooming.
    var hue: Double = 0

    var mid: Double { (start + end) / 2 }
}

struct SunburstGeometry {
    let center: CGPoint
    let innerRadius: CGFloat
    let ringWidth: CGFloat
    /// Fractional while rings are added during an animation.
    let rings: Double

    init(size: CGSize, rings: Int) {
        self.init(center: CGPoint(x: size.width / 2, y: size.height / 2),
                  outerRadius: Self.outerRadius(for: size), rings: Double(rings))
    }

    init(center: CGPoint, outerRadius: CGFloat, rings: Double) {
        self.rings = rings
        self.center = center
        innerRadius = outerRadius * 0.24
        ringWidth = (outerRadius - innerRadius) / CGFloat(rings)
    }

    static func outerRadius(for size: CGSize) -> CGFloat {
        max(min(size.width, size.height) / 2 - 12, 40)
    }

    var outerRadius: CGFloat { innerRadius + CGFloat(rings) * ringWidth }

    func radii(depth: Int) -> (inner: CGFloat, outer: CGFloat) {
        let inner = innerRadius + CGFloat(depth - 1) * ringWidth
        return (inner, inner + ringWidth)
    }

    /// The ring segment shape. `depth` may be fractional (during animations); the part beyond
    /// the outermost ring is clipped, and nil is returned when nothing is left.
    func wedge(start: Double, end: Double, depth: Double) -> Path? {
        let limit = outerRadius
        let inner = innerRadius + CGFloat(depth - 1) * ringWidth
        guard inner < limit else { return nil }
        let outer = min(inner + ringWidth, limit)

        // Shift by -90° so angle 0 is at the top; increasing angles run clockwise on screen.
        let from = Angle(radians: start - .pi / 2)
        let to = Angle(radians: end - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }

    enum Hit: Equatable {
        case center
        case segment(Int32)
        case special(SpecialSpace)
    }

    func hitTest(_ point: CGPoint, segments: [Segment]) -> Hit? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        if r < innerRadius { return .center }
        let depth = Int((r - innerRadius) / ringWidth) + 1
        // atan2 in y-down view coordinates; shift so 0 is at the top.
        var angle = atan2(Double(dy), Double(dx)) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return segments
            .first { $0.depth == depth && $0.start <= angle && angle < $0.end }
            .map { segment in segment.special.map(Hit.special) ?? .segment(segment.node) }
    }
}

enum SunburstLayout {
    /// Segments thinner than this (radians on screen) are not drawn.
    static let minAngle = 0.01

    /// Lays out `rings` levels below `center`. Children are sorted largest first, so once one
    /// is too thin to see, all following siblings are too and the loop stops.
    /// Angle taken by the scanned tree at the root; the rest of the circle is `extras`.
    static func rootSpan(tree: FileTree, extras: [(SpecialSpace, Int64)]) -> Double {
        let scanned = Double(tree.root.size)
        let total = scanned + Double(extras.reduce(0) { $0 + $1.1 })
        return total > 0 ? 2 * .pi * scanned / total : 2 * .pi
    }

    /// `extras` (free and hidden space) are only shown when centered on the root, and
    /// `extraParts` in the ring outside the extra they're part of.
    /// Items in `fixedHues` (and everything inside them) get that hue instead of one from their
    /// position, such as the Photos library in iCloud's color for Photos.
    static func segments(tree: FileTree, center: Int32, rings: Int,
                         extras: [(SpecialSpace, Int64)] = [],
                         extraParts: [SpecialSpace: [(SpecialSpace, Int64)]] = [:],
                         fixedHues: [Int32: Double] = [:]) -> [Segment] {
        var result: [Segment] = []

        // Free and hidden space are only drawn at the root, but always take their share of the
        // root chart, which is what item hues are based on.
        let shownExtras = center == 0 ? extras : []
        let span = rootSpan(tree: tree, extras: shownExtras)

        // Hues come from where the center sits in the root chart: zooming in keeps every item's color.
        let centerRange = center == 0 ? (start: 0.0, end: 2 * Double.pi)
            : slice(of: center, within: 0, tree: tree, span: rootSpan(tree: tree, extras: extras))
                .map { (start: $0.start, end: $0.end) } ?? (start: 0, end: 2 * .pi)
        func hue(_ start: Double, _ end: Double) -> Double {
            let mid = (start + end) / 2
            return (centerRange.start + mid * (centerRange.end - centerRange.start) / (2 * .pi)) / (2 * .pi)
        }

        // Zoomed into a fixed-hue item, or below it: everything shown inherits its hue.
        let centerHue = fixedHues.isEmpty ? nil : tree.ancestry(of: center).lazy.compactMap { fixedHues[$0] }.last

        func visit(_ node: Int32, depth: Int, start: Double, end: Double, fixedHue: Double?) {
            let total = Double(tree.nodes[Int(node)].size)
            guard depth < rings, total > 0 else { return }
            var angle = start
            for child in tree.children(of: node) {
                let size = Double(tree.nodes[Int(child)].size)
                let sweep = (end - start) * size / total
                if sweep < minAngle { break }
                let childHue = fixedHues[child] ?? fixedHue
                result.append(Segment(node: child, depth: depth + 1, start: angle, end: angle + sweep,
                                      hue: childHue ?? hue(angle, angle + sweep)))
                if tree.nodes[Int(child)].isDirectory {
                    visit(child, depth: depth + 1, start: angle, end: angle + sweep, fixedHue: childHue)
                }
                angle += sweep
            }
        }

        visit(center, depth: 0, start: 0, end: span, fixedHue: centerHue)

        let total = Double(tree.root.size) + Double(shownExtras.reduce(0) { $0 + $1.1 })
        var angle = span
        for (kind, bytes) in shownExtras where total > 0 {
            let sweep = 2 * .pi * Double(bytes) / total
            if sweep >= minAngle {
                result.append(Segment(node: -1, depth: 1, start: angle, end: angle + sweep, special: kind))
                var partAngle = angle
                for (part, partBytes) in extraParts[kind] ?? [] where bytes > 0 && rings > 1 {
                    let partSweep = sweep * Double(min(partBytes, bytes)) / Double(bytes)
                    // Never beyond the end of the wedge it's part of.
                    let end = min(partAngle + partSweep, angle + sweep)
                    if end - partAngle >= minAngle {
                        result.append(Segment(node: -1, depth: 2, start: partAngle, end: end, special: part))
                    }
                    partAngle = end
                }
            }
            angle += sweep
        }
        return result
    }

    /// Angular range and ring depth of `node` inside the chart centered on `ancestor`.
    struct Slice {
        let start: Double
        let end: Double
        let depth: Int
    }

    /// Computed from sizes, not from drawn segments, so it also works for nodes too deep
    /// or too thin to be drawn.
    /// `span` is the angle the ancestor's contents occupy (less than a full circle at a disk's
    /// root, where free and hidden space take the rest).
    static func slice(of node: Int32, within ancestor: Int32, tree: FileTree,
                      span: Double = 2 * .pi) -> Slice? {
        let chain = tree.ancestry(of: node)
        guard let top = chain.firstIndex(of: ancestor) else { return nil }
        var start = 0.0
        var end = span
        for (parent, child) in zip(chain[top...], chain[(top + 1)...]) {
            let total = Double(tree.nodes[Int(parent)].size)
            guard total > 0 else { return nil }
            var offset = 0.0
            for sibling in tree.children(of: parent) {
                if sibling == child { break }
                offset += Double(tree.nodes[Int(sibling)].size)
            }
            let span = end - start
            start += span * offset / total
            end = start + span * Double(tree.nodes[Int(child)].size) / total
        }
        return Slice(start: start, end: end, depth: chain.count - 1 - top)
    }
}
