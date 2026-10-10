import DirScanner
import SwiftUI

struct SunburstView: View {
    @Environment(ScanModel.self) private var model
    /// The item under the pointer, kept after the pointer leaves so the context menu and
    /// drags (which end hover tracking) still know their target.
    @State private var pointed: Int32?

    var body: some View {
        GeometryReader { proxy in
            let geometry = SunburstGeometry(size: proxy.size, rings: ScanModel.rings)
            ZStack {
                // The timeline only ticks while a zoom animation runs.
                TimelineView(.animation(paused: model.transition == nil)) { timeline in
                    Canvas { context, _ in
                        draw(in: &context, geometry: geometry, date: timeline.date)
                    }
                }
                CenterLabel(width: geometry.innerRadius * 1.6)
                    .position(geometry.center)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let hit = geometry.hitTest(point, segments: model.segments)
                    switch hit {
                    case .segment(let node): pointed = node
                    case .center: pointed = model.center
                    case .special, nil: pointed = nil
                    }
                    let special: SpecialSpace? = if case .special(let kind) = hit { kind } else { nil }
                    if model.hoveredSpecial != special { model.hoveredSpecial = special }
                    if case .segment(let node) = hit {
                        if model.hovered != node { model.hovered = node }
                    } else if model.hovered != nil {
                        model.hovered = nil
                    }
                case .ended:
                    model.hovered = nil
                    model.hoveredSpecial = nil
                }
            }
            .onTapGesture { point in
                switch geometry.hitTest(point, segments: model.segments) {
                case .center: model.zoomOut()
                case .segment(let node): model.zoom(to: node)
                case .special, nil: break
                }
            }
            .onDrag {
                guard let pointed, let url = model.url(of: pointed) else { return NSItemProvider() }
                return NSItemProvider(object: url as NSURL)
            } preview: {
                // Without a preview, macOS would use a snapshot of the whole chart.
                DragPreview(node: pointed, geometry: geometry)
            }
            .contextMenu {
                if let pointed {
                    NodeMenu(node: pointed)
                }
            }
        }
    }

    private func draw(in context: inout GraphicsContext, geometry: SunburstGeometry, date: Date) {
        guard let tree = model.tree else { return }
        let hoveredChain = model.hovered.map { Set(tree.ancestry(of: $0)) } ?? []
        let collected = Set(model.collected)
        func drawSegment(_ segment: Segment, start: Double, end: Double, depth: Double, opacity: Double) {
            guard opacity > 0.01 else { return }
            if let special = segment.special {
                drawSpecial(special, start: start, end: end, depth: depth, opacity: opacity,
                            in: &context, geometry: geometry)
                return
            }
            // Items in the collector (and everything inside them) are dimmed.
            let dimmed = !collected.isEmpty && tree.ancestry(of: segment.node).contains { collected.contains($0) }
            draw(segment.node, hue: segment.hue, start: start, end: end, depth: depth,
                 opacity: dimmed ? opacity * 0.3 : opacity,
                 highlighted: hoveredChain.contains(segment.node), tree: tree,
                 in: &context, geometry: geometry)
        }

        if let transition = model.transition {
            let expansion = transition.expansion(at: date)
            let slice = transition.slice

            // The outer chart, minus the inner node's subtree, fades out as the inner one expands.
            for segment in transition.outerSegments where !(segment.depth > slice.depth
                && segment.start >= slice.start - 1e-9 && segment.end <= slice.end + 1e-9) {
                drawSegment(segment, start: segment.start, end: segment.end,
                            depth: Double(segment.depth), opacity: 1 - expansion)
            }

            // The inner chart grows from its slice (and ring) in the outer chart to the full circle.
            let scale = (slice.end - slice.start) / (2 * .pi)
            let shift = Double(slice.depth) * (1 - expansion)
            for segment in transition.innerSegments {
                let start = lerp(slice.start + segment.start * scale, segment.start, expansion)
                let end = lerp(slice.start + segment.end * scale, segment.end, expansion)
                // Same cut-off as the layout, applied to the on-screen size. Otherwise slivers
                // squeezed into the slice would vanish all at once when the animation ends.
                guard end - start >= SunburstLayout.minAngle else { continue }
                drawSegment(segment, start: start, end: end, depth: Double(segment.depth) + shift, opacity: 1)
            }
        } else {
            for segment in model.segments {
                drawSegment(segment, start: segment.start, end: segment.end,
                            depth: Double(segment.depth), opacity: 1)
            }
        }

        let disc = Path(ellipseIn: CGRect(x: geometry.center.x - geometry.innerRadius,
                                          y: geometry.center.y - geometry.innerRadius,
                                          width: geometry.innerRadius * 2,
                                          height: geometry.innerRadius * 2))
        context.fill(disc, with: .color(Color(nsColor: .controlBackgroundColor)))
        context.stroke(disc, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
    }

    /// `depth` is fractional during animations; rings that move past the edge are clipped.
    private func draw(_ index: Int32, hue: Double, start: Double, end: Double, depth: Double, opacity: Double,
                      highlighted: Bool, tree: FileTree,
                      in context: inout GraphicsContext, geometry: SunburstGeometry) {
        guard let path = geometry.wedge(start: start, end: end, depth: depth) else { return }
        let node = tree.nodes[Int(index)]
        let fill = Self.color(hue: hue, depth: depth, isDirectory: node.isDirectory, highlighted: highlighted)
        context.fill(path, with: .color(fill.opacity(opacity)))
        context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor).opacity(opacity)), lineWidth: 0.75)
    }

    /// Free space is drawn as an empty, outlined slot; hidden space as solid gray.
    private func drawSpecial(_ kind: SpecialSpace, start: Double, end: Double, depth: Double, opacity: Double,
                             in context: inout GraphicsContext, geometry: SunburstGeometry) {
        guard let path = geometry.wedge(start: start, end: end, depth: depth) else { return }
        let highlighted = model.hoveredSpecial == kind
        switch kind {
        case .free:
            context.fill(path, with: .color(.primary.opacity((highlighted ? 0.12 : 0.05) * opacity)))
            context.stroke(path, with: .color(.secondary.opacity(0.5 * opacity)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .hidden:
            context.fill(path, with: .color(.gray.opacity((highlighted ? 0.75 : 0.5) * opacity)))
            context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor).opacity(opacity)), lineWidth: 0.75)
        }
    }

    /// Hue comes from the item's position in the root chart, so a subtree keeps its parent's color
    /// family and colors stay put when zooming; outer rings get lighter. Files are desaturated so
    /// folders stand out, like DaisyDisk.
    static func color(hue: Double, depth: Double, isDirectory: Bool, highlighted: Bool) -> Color {
        let level = max(depth - 1, 0)
        var saturation = max(0.75 - level * 0.09, 0.25)
        var brightness = min(0.78 + level * 0.04, 0.98)
        if !isDirectory { saturation *= 0.25 }
        if highlighted { brightness = min(brightness + 0.15, 1); saturation = min(saturation + 0.1, 1) }
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// Drag image for a chart item: its own wedge (or the center disc), with name and size.
private struct DragPreview: View {
    @Environment(ScanModel.self) private var model
    let node: Int32?
    let geometry: SunburstGeometry

    private static let maxShapeSize: CGFloat = 160

    var body: some View {
        if let node, let tree = model.tree {
            let item = tree.nodes[Int(node)]
            VStack(spacing: 6) {
                shape(for: node, isDirectory: item.isDirectory)
                Text(node == 0 ? model.rootName : tree.name(of: node))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(formatBytes(item.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func shape(for node: Int32, isDirectory: Bool) -> some View {
        if let segment = model.segments.first(where: { $0.node == node }),
           let path = geometry.wedge(start: segment.start, end: segment.end, depth: Double(segment.depth)) {
            // Move the wedge to the origin and shrink large ones to a sensible drag size.
            let bounds = path.boundingRect
            let scale = min(1, Self.maxShapeSize / max(bounds.width, bounds.height, 1))
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: -bounds.minX, y: -bounds.minY)
            path.applying(transform)
                .fill(SunburstView.color(hue: segment.hue, depth: Double(segment.depth),
                                         isDirectory: isDirectory, highlighted: false))
                .frame(width: bounds.width * scale, height: bounds.height * scale)
        } else {
            Circle()
                .fill(Color.accentColor.gradient)
                .frame(width: 56, height: 56)
        }
    }
}

private struct CenterLabel: View {
    @Environment(ScanModel.self) private var model
    let width: CGFloat

    var body: some View {
        if let special = model.hoveredSpecial {
            VStack(spacing: 4) {
                Text(special == .free ? "Free space" : "Hidden space")
                    .font(.subheadline.weight(.medium))
                Text(formatBytes(model.bytes(of: special)))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(special == .free
                     ? "available on \(model.rootName)"
                     : "used, but not visible to the scan: system, snapshots, swap, unreadable folders")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: width)
        } else if let tree = model.tree {
            let node = tree.nodes[Int(model.focused)]
            VStack(spacing: 4) {
                Text(model.focused == 0 ? model.rootName : tree.name(of: model.focused))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(formatBytes(node.size))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if node.isDirectory {
                    Text("\(node.itemCount.formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.focused == 0, let volume = model.scannedVolume {
                    Text("\(formatBytes(volume.availableBytes)) free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.hovered == nil && model.center != 0 {
                    Text("click to go up")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: width)
        }
    }
}

private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false // "0 KB" rather than "Zero KB"
    return formatter
}()

func formatBytes(_ bytes: Int64) -> String {
    byteFormatter.string(fromByteCount: bytes)
}
