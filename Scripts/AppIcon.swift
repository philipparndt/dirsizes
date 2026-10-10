// Renders the DirSizes app icon (1024×1024 PNG): a sunburst chart on a macOS-style rounded square.
// Usage: swift Scripts/AppIcon.swift <output.png>   (or `make icon`, which also builds the .icns)

import AppKit

let size: CGFloat = 1024
let center = CGPoint(x: size / 2, y: size / 2)

/// A folder: its share of the parent's angle, and its children (which may not fill it completely,
/// like small files the real chart leaves out).
struct Item {
    let share: Double
    var children: [Item] = []
    /// Drawn pulled out of its ring, like an item picked for the collector.
    var lifted = false
}

let chart: [Item] = [
    Item(share: 0.34, children: [
        Item(share: 0.46, children: [Item(share: 0.55), Item(share: 0.3)]),
        Item(share: 0.3, children: [Item(share: 0.7), Item(share: 0.2)]),
        Item(share: 0.16),
    ]),
    Item(share: 0.23, children: [
        Item(share: 0.58, children: [Item(share: 0.4), Item(share: 0.35)]),
        Item(share: 0.32, lifted: true),
    ]),
    Item(share: 0.18, children: [
        Item(share: 0.5, children: [Item(share: 0.8)]),
        Item(share: 0.3),
        Item(share: 0.12),
    ]),
    Item(share: 0.14, children: [
        Item(share: 0.62, children: [Item(share: 0.5), Item(share: 0.3)]),
        Item(share: 0.25),
    ]),
    Item(share: 0.11, children: [Item(share: 0.7), Item(share: 0.2)]),
]

let discRadius: CGFloat = 108
let ringWidth: CGFloat = 78
let gap: CGFloat = 7

/// Same color logic as the app: hue follows the angle, outer rings get lighter.
func color(mid: Double, depth: Int) -> NSColor {
    let level = CGFloat(depth - 1)
    return NSColor(hue: CGFloat(mid / (2 * .pi)),
                   saturation: max(0.78 - level * 0.13, 0.3),
                   brightness: min(0.86 + level * 0.06, 1), alpha: 1)
}

/// Wedge between two angles (radians, clockwise from the top) on ring `depth`.
func wedge(start: Double, end: Double, depth: Int, offset: CGFloat = 0) -> CGPath {
    let inner = discRadius + CGFloat(depth - 1) * ringWidth
    let outer = inner + ringWidth
    let mid = (start + end) / 2
    let c = CGPoint(x: center.x + offset * CGFloat(sin(mid)), y: center.y + offset * CGFloat(cos(mid)))
    // Core Graphics angles run counter-clockwise from +x; convert from "clockwise from top".
    func cg(_ a: Double) -> CGFloat { CGFloat(.pi / 2 - a) }
    let path = CGMutablePath()
    path.addArc(center: c, radius: outer, startAngle: cg(start), endAngle: cg(end), clockwise: true)
    path.addArc(center: c, radius: inner, startAngle: cg(end), endAngle: cg(start), clockwise: false)
    path.closeSubpath()
    return path
}

struct Wedge {
    let path: CGPath
    let color: NSColor
    let lifted: Bool
}

func layout(_ items: [Item], start: Double, span: Double, depth: Int, into wedges: inout [Wedge]) {
    var angle = start
    for item in items {
        let sweep = span * item.share
        let mid = angle + sweep / 2
        wedges.append(Wedge(path: wedge(start: angle, end: angle + sweep, depth: depth, offset: item.lifted ? 24 : 0),
                            color: color(mid: mid, depth: depth), lifted: item.lifted))
        layout(item.children, start: angle, span: sweep, depth: depth + 1, into: &wedges)
        angle += sweep
    }
}

var wedges: [Wedge] = []
// Start slightly left of the top so the largest folder doesn't begin exactly at 12 o'clock.
layout(chart, start: -0.35, span: 2 * .pi, depth: 1, into: &wedges)

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square body on Apple's icon grid (824 pt inside a 1024 canvas), with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [
        NSColor(red: 0.20, green: 0.22, blue: 0.42, alpha: 1).cgColor,
        NSColor(red: 0.07, green: 0.08, blue: 0.17, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Faint glow behind the chart.
    let glow = CGGradient(colorsSpace: nil, colors: [
        NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420, options: [])

    // Wedges go on their own transparency layer so the gaps can be cut out, revealing the background.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for wedge in wedges where !wedge.lifted {
        ctx.addPath(wedge.path)
        ctx.setFillColor(wedge.color.cgColor)
        ctx.fillPath()
    }
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(gap)
    ctx.setLineJoin(.round)
    for wedge in wedges where !wedge.lifted {
        ctx.addPath(wedge.path)
        ctx.strokePath()
    }
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()

    // The lifted wedge floats above the chart with a glow in its own color.
    for wedge in wedges where wedge.lifted {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 40, color: wedge.color.withAlphaComponent(0.9).cgColor)
        ctx.addPath(wedge.path)
        ctx.setFillColor(wedge.color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(wedge.path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
    }

    // Center disc.
    let disc = CGRect(x: center.x - discRadius + gap / 2, y: center.y - discRadius + gap / 2,
                      width: (discRadius - gap / 2) * 2, height: (discRadius - gap / 2) * 2)
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    let discFill = CGGradient(colorsSpace: nil, colors: [
        NSColor(red: 0.16, green: 0.17, blue: 0.27, alpha: 1).cgColor,
        NSColor(red: 0.06, green: 0.06, blue: 0.11, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(discFill, start: CGPoint(x: 0, y: disc.maxY), end: CGPoint(x: 0, y: disc.minY), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: disc)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    // Subtle top highlight and edge for depth.
    let sheen = CGGradient(colorsSpace: nil, colors: [
        NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    ctx.addPath(bodyPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()
    return true
}

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
