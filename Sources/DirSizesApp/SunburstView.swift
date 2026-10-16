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
            let origin = proxy.frame(in: .global).origin
            // The timeline only ticks while a zoom or the intro runs.
            TimelineView(.animation(paused: model.transition == nil && model.intro == nil)) { timeline in
                let shown = introGeometry(at: timeline.date, final: geometry, origin: origin) ?? geometry
                ZStack {
                    Canvas { context, _ in
                        draw(in: &context, geometry: shown, date: timeline.date)
                    }
                    CenterLabel(width: geometry.innerRadius * 1.6)
                        .position(shown.center)
                        .allowsHitTesting(false)
                }
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
                // The part of iCloud Photos on this Mac is a folder that can be looked into.
                case .special(.photosOnMac): if let path = model.photosLibrary?.path { model.scan(path: path) }
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

    /// While the chart grows out of the live one: its place and size between the two, with the
    /// live chart's rings becoming this one's.
    private func introGeometry(at date: Date, final: SunburstGeometry, origin: CGPoint) -> SunburstGeometry? {
        guard let intro = model.intro else { return nil }
        let t = intro.morph.progress(at: date)
        let liveCenter = CGPoint(x: intro.liveCenter.x - origin.x, y: intro.liveCenter.y - origin.y)
        return SunburstGeometry(
            center: CGPoint(x: lerp(liveCenter.x, final.center.x, t), y: lerp(liveCenter.y, final.center.y, t)),
            outerRadius: lerp(intro.liveOuterRadius, final.outerRadius, t),
            rings: intro.morph.rings(at: date))
    }

    private func draw(in context: inout GraphicsContext, geometry: SunburstGeometry, date: Date) {
        guard let tree = model.tree else { return }
        if let intro = model.intro {
            for segment in intro.morph.segments(at: date) {
                if let special = segment.special {
                    drawSpecial(special, start: segment.start, end: segment.end, depth: Double(segment.depth),
                                opacity: 1, in: &context, geometry: geometry)
                } else if let path = geometry.wedge(start: segment.start, end: segment.end,
                                                    depth: Double(segment.depth)) {
                    let fill = Self.color(hue: segment.hue, depth: Double(segment.depth),
                                          isDirectory: segment.isDirectory, inCloud: segment.inCloud,
                                          highlighted: false)
                    context.fill(path, with: .color(fill))
                    context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 0.75)
                }
            }
            drawDisc(in: &context, geometry: geometry)
            return
        }
        let hoveredChain = model.hovered.map { Set(tree.ancestry(of: $0)) } ?? []
        let collected = Set(model.collected)
        let gone = model.gone
        func drawSegment(_ segment: Segment, start: Double, end: Double, depth: Double, opacity: Double) {
            guard opacity > 0.01 else { return }
            if let special = segment.special {
                drawSpecial(special, start: start, end: end, depth: depth, opacity: opacity,
                            in: &context, geometry: geometry)
                return
            }
            // Items in the collector (and everything inside them) are dimmed.
            let dimmed = !collected.isEmpty && tree.ancestry(of: segment.node).contains { collected.contains($0) }
            // Deleted by another app since the scan: gray until the next scan.
            let isGone = !gone.isEmpty && tree.ancestry(of: segment.node).contains { gone.contains($0) }
            draw(segment.node, hue: segment.hue, start: start, end: end, depth: depth,
                 opacity: dimmed ? opacity * 0.3 : opacity,
                 highlighted: hoveredChain.contains(segment.node), gone: isGone, tree: tree,
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

        drawDisc(in: &context, geometry: geometry)
    }

    private func drawDisc(in context: inout GraphicsContext, geometry: SunburstGeometry) {
        let disc = Path(ellipseIn: CGRect(x: geometry.center.x - geometry.innerRadius,
                                          y: geometry.center.y - geometry.innerRadius,
                                          width: geometry.innerRadius * 2,
                                          height: geometry.innerRadius * 2))
        context.fill(disc, with: .color(Color(nsColor: .controlBackgroundColor)))
        context.stroke(disc, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
    }

    /// `depth` is fractional during animations; rings that move past the edge are clipped.
    private func draw(_ index: Int32, hue: Double, start: Double, end: Double, depth: Double, opacity: Double,
                      highlighted: Bool, gone: Bool, tree: FileTree,
                      in context: inout GraphicsContext, geometry: SunburstGeometry) {
        guard let path = geometry.wedge(start: start, end: end, depth: depth) else { return }
        let node = tree.nodes[Int(index)]
        let fill = gone
            ? Color(white: highlighted ? 0.55 : 0.42)
            : Self.color(hue: hue, depth: depth, isDirectory: node.isDirectory, inCloud: node.kind == .cloudFile,
                         highlighted: highlighted)
        context.fill(path, with: .color(fill.opacity(opacity)))
        context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor).opacity(opacity)), lineWidth: 0.75)
    }

    /// Free space is drawn as an empty, outlined slot; hidden space as solid gray.
    private func drawSpecial(_ kind: SpecialSpace, start: Double, end: Double, depth: Double, opacity: Double,
                             in context: inout GraphicsContext, geometry: SunburstGeometry) {
        guard let path = geometry.wedge(start: start, end: end, depth: depth) else { return }
        Self.fillSpecial(kind, path: path, highlighted: model.hoveredSpecial == kind, tint: model.color(of: kind),
                         opacity: opacity, in: &context)
    }

    /// Free space is an empty, outlined slot; hidden space solid gray; iCloud categories in
    /// iCloud's colors (the rest of Documents in gray).
    static func fillSpecial(_ kind: SpecialSpace, path: Path, highlighted: Bool, tint: Color? = nil,
                            opacity: Double = 1, in context: inout GraphicsContext) {
        switch kind {
        case .iCloud, .photosOnMac:
            let fill = tint ?? .gray
            context.fill(path, with: .color(fill.opacity((highlighted ? 0.95 : 0.75) * opacity)))
            context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor).opacity(opacity)), lineWidth: 0.75)
        case .photosInCloud:
            // See-through, like files only in iCloud.
            let fill = tint ?? .gray
            context.fill(path, with: .color(fill.opacity((highlighted ? 0.5 : 0.3) * opacity)))
            context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor).opacity(opacity)), lineWidth: 0.75)
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
    /// folders stand out, like DaisyDisk. Files only in iCloud are see-through: they take no
    /// space on this Mac.
    static func color(hue: Double, depth: Double, isDirectory: Bool, inCloud: Bool = false,
                      highlighted: Bool) -> Color {
        let level = max(depth - 1, 0)
        var saturation = max(0.75 - level * 0.09, 0.25)
        var brightness = min(0.78 + level * 0.04, 0.98)
        if !isDirectory { saturation *= 0.25 }
        if highlighted { brightness = min(brightness + 0.15, 1); saturation = min(saturation + 0.1, 1) }
        return Color(hue: hue, saturation: saturation, brightness: brightness)
            .opacity(inCloud ? (highlighted ? 0.55 : 0.35) : 1)
    }
}


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
                Text(model.displayName(of: node))
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
                Text(model.label(of: special))
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                Text(formatBytes(model.bytes(of: special)))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(explanation(of: special))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: width)
        } else if let tree = model.tree {
            let node = tree.nodes[Int(model.focused)]
            VStack(spacing: 4) {
                Text(model.displayName(of: model.focused))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                // At the root of the iCloud chart: everything in iCloud, not just iCloud Drive.
                let iCloudTotals = model.focused == 0 ? model.iCloudUsage?.storageUsageInfo : nil
                Text(formatBytes(iCloudTotals?.usedStorageInBytes ?? node.size))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let iCloudTotals {
                    Text("of \(formatBytes(iCloudTotals.totalStorageInBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.isGone(model.focused) {
                    Text("deleted outside DirSizes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if node.isDirectory {
                    Text("\(node.itemCount.formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let cloud = model.bytesInCloud(model.focused), cloud > 0 {
                    Text(node.kind == .cloudFile ? "only in iCloud" : "\(formatBytes(cloud)) only in iCloud")
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

extension CenterLabel {
    fileprivate func explanation(of special: SpecialSpace) -> String {
        switch special {
        case .free: model.iCloudUsage != nil ? "left in your iCloud plan" : "available on \(model.rootName)"
        case .hidden: "used, but not visible to the scan: system, snapshots, swap, unreadable folders"
        case .iCloud("docs"): "in iCloud, but not as files in iCloud Drive (app data, iCloud Drive's trash, …)"
        case .iCloud: "in iCloud; not files on this Mac"
        case .photosOnMac: "originals and previews kept on this Mac; click to look inside"
        case .photosInCloud: "not downloaded to this Mac"
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
