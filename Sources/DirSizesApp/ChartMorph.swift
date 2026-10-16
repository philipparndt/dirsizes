import DirScanner
import SwiftUI

/// A chart segment identified by its path below the chart's root, so it can be followed from one
/// layout to the next, even into another tree (the live scan's snapshot into the finished scan).
struct KeyedSegment {
    /// Path below the root ("Library/Caches"); special segments have their own keys.
    var key: String
    var depth: Int
    var start: Double
    var end: Double
    var hue: Double
    var isDirectory: Bool
    /// A file only in iCloud.
    var inCloud = false
    var special: SpecialSpace?
    /// In the tree the segment was laid out from; -1 for special segments and ones only drawn
    /// while they leave.
    var node: Int32

    static func keyed(_ segments: [Segment], tree: FileTree) -> [KeyedSegment] {
        // Parents come before their children, so each key is its parent's key plus a name.
        var keys: [Int32: String] = [0: ""]
        return segments.map { segment in
            if let special = segment.special {
                return KeyedSegment(key: special.key, depth: segment.depth,
                                    start: segment.start, end: segment.end, hue: segment.hue,
                                    isDirectory: false, special: special, node: -1)
            }
            let key = path(of: segment.node, in: tree, keys: &keys)
            let node = tree.nodes[Int(segment.node)]
            return KeyedSegment(key: key, depth: segment.depth, start: segment.start, end: segment.end,
                                hue: segment.hue, isDirectory: node.isDirectory, inCloud: node.kind == .cloudFile,
                                node: segment.node)
        }
    }

    private static func path(of node: Int32, in tree: FileTree, keys: inout [Int32: String]) -> String {
        if let key = keys[node] { return key }
        let parent = path(of: tree.nodes[Int(node)].parent, in: tree, keys: &keys)
        let key = parent.isEmpty ? tree.name(of: node) : parent + "/" + tree.name(of: node)
        keys[node] = key
        return key
    }

    /// File names can't contain "/", so the parent's key is everything before the last one.
    static func parentKey(of key: String) -> String? {
        guard !key.isEmpty else { return nil }
        guard let slash = key.lastIndex(of: "/") else { return "" }
        return String(key[..<slash])
    }
}

/// Moves every segment of one chart to its place in another: segments in both slide and resize,
/// new ones grow out of their parent, gone ones shrink into it, and rings added at the edge
/// (`fromRings` < `toRings`) slide in from the outside.
struct ChartMorph {
    struct Track {
        let from: KeyedSegment
        let to: KeyedSegment
    }

    let tracks: [Track]
    let fromRings: Double
    let toRings: Double
    let start: Date
    let duration: Double
    /// Ease out only: a morph that is replaced before it ends (by the next live snapshot) keeps
    /// moving instead of slowing down and speeding up again.
    let easeOut: Bool

    init(from old: [KeyedSegment], to new: [KeyedSegment], fromRings: Double, toRings: Double,
         duration: Double, easeOut: Bool = false, start: Date = Date()) {
        self.fromRings = fromRings
        self.toRings = toRings
        self.duration = duration
        self.easeOut = easeOut
        self.start = start

        let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let newByKey = Dictionary(new.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        // The root's range: where its contents end, as drawn (free and hidden space may follow).
        func rootRange(_ segments: [KeyedSegment]) -> (Double, Double) {
            (0, segments.lazy.filter { $0.depth == 1 && $0.special == nil }.map(\.end).max() ?? 0)
        }
        let oldRoot = rootRange(old)
        let newRoot = rootRange(new)

        /// The nearest ancestor of `key` in `segments`, with its range.
        func ancestor(of key: String, in segments: [String: KeyedSegment],
                      root: (Double, Double)) -> (key: String, range: (Double, Double)) {
            var current = KeyedSegment.parentKey(of: key) ?? ""
            while !current.isEmpty {
                if let segment = segments[current] { return (current, (segment.start, segment.end)) }
                current = KeyedSegment.parentKey(of: current) ?? ""
            }
            return ("", root)
        }

        /// Where `segment` (only in `here`) starts or ends up in the other chart.
        func counterpart(of segment: KeyedSegment, here: [String: KeyedSegment], hereRoot: (Double, Double),
                         there: [String: KeyedSegment], thereRoot: (Double, Double),
                         rings: Double) -> KeyedSegment {
            var result = segment
            result.node = -1
            let (key, thereRange) = segment.special == nil
                ? ancestor(of: segment.key, in: there, root: thereRoot)
                : ("", thereRoot)
            if Double(segment.depth) > rings {
                // A ring the other chart doesn't have: keep its place relative to the closest
                // ancestor both charts have, so it moves along with it.
                let hereRange = key.isEmpty ? hereRoot : here[key].map { ($0.start, $0.end) } ?? hereRoot
                let scale = hereRange.1 > hereRange.0 ? (thereRange.1 - thereRange.0) / (hereRange.1 - hereRange.0) : 0
                result.start = thereRange.0 + (segment.start - hereRange.0) * scale
                result.end = thereRange.0 + (segment.end - hereRange.0) * scale
            } else {
                // Children are sorted largest first, so new and vanishing ones sit at the end.
                result.start = thereRange.1
                result.end = thereRange.1
            }
            return result
        }

        var tracks: [Track] = []
        tracks.reserveCapacity(new.count + old.count)
        for segment in new {
            if let previous = oldByKey[segment.key] {
                tracks.append(Track(from: previous, to: segment))
            } else {
                tracks.append(Track(from: counterpart(of: segment, here: newByKey, hereRoot: newRoot,
                                                      there: oldByKey, thereRoot: oldRoot, rings: fromRings),
                                    to: segment))
            }
        }
        for segment in old where newByKey[segment.key] == nil {
            tracks.append(Track(from: segment,
                                to: counterpart(of: segment, here: oldByKey, hereRoot: oldRoot,
                                                there: newByKey, thereRoot: newRoot, rings: toRings)))
        }
        self.tracks = tracks
    }

    func progress(at date: Date) -> Double {
        let t = min(max(date.timeIntervalSince(start) / duration, 0), 1)
        if easeOut { return 1 - pow(1 - t, 3) }
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    func isFinished(at date: Date) -> Bool {
        date.timeIntervalSince(start) >= duration
    }

    func rings(at date: Date) -> Double {
        lerp(fromRings, toRings, progress(at: date))
    }

    /// The chart at `date`. Segments keep the target's node, or -1 while they are leaving.
    func segments(at date: Date) -> [KeyedSegment] {
        let t = progress(at: date)
        return tracks.compactMap { track in
            var segment = track.to.node >= 0 || track.to.special != nil ? track.to : track.from
            segment.start = lerp(track.from.start, track.to.start, t)
            segment.end = lerp(track.from.end, track.to.end, t)
            segment.hue = lerp(track.from.hue, track.to.hue, t)
            if track.to.node < 0 && track.to.special == nil { segment.node = -1 }
            return segment.end - segment.start > 1e-4 ? segment : nil
        }
    }
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
