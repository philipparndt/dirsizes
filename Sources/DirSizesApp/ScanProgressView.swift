import SwiftUI

/// Scan screen: the folder being scanned, a large gradient progress bar and live counters.
struct ScanProgressView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 4) {
                Text(model.rootName)
                    .font(.title2.weight(.semibold))
                Text(model.rootPath ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressBar(progress: model.progress)
                .frame(width: 420, height: 14)

            // Each value only ever grows in width, so the centered line doesn't jitter as digits change.
            HStack(spacing: 6) {
                if let progress = model.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .growOnlyWidth(alignment: .trailing)
                    Text("·")
                }
                Text(formatBytes(model.bytesScanned))
                    .growOnlyWidth(alignment: .trailing)
                if let expected = model.expectedBytes {
                    Text("of ~\(formatBytes(expected))")
                }
                Text("·")
                Text("\(model.filesScanned.formatted()) files")
                    .growOnlyWidth(alignment: .trailing)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            // Digits roll and blur into their new values as the counters change.
            .contentTransition(.numericText())
            .animation(.default, value: model.filesScanned)

            Button("Stop Scan") { model.stop() }
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Rounded bar with a multi-color gradient fill and a moving sheen. Without a known total it
/// shows an indeterminate segment sliding back and forth.
private struct ProgressBar: View {
    let progress: Double?

    private static let gradient = LinearGradient(
        colors: [.blue, .purple, .pink, .orange],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)

                    if let progress {
                        Self.gradient
                            .frame(width: width)
                            .overlay(sheen(time: time, width: width))
                            .mask(alignment: .leading) {
                                Capsule().frame(width: max(width * progress, proxy.size.height))
                            }
                            .animation(.easeOut(duration: 0.3), value: progress)
                    } else {
                        // Indeterminate: a third of the bar sweeping back and forth.
                        let phase = (sin(time * 2.2) + 1) / 2
                        let chunk = width * 0.33
                        Self.gradient
                            .frame(width: width)
                            .mask(alignment: .leading) {
                                Capsule()
                                    .frame(width: chunk)
                                    .offset(x: (width - chunk) * phase)
                            }
                    }
                }
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }

    /// Soft highlight that travels along the filled part, like a progress bar "working".
    private func sheen(time: Double, width: CGFloat) -> some View {
        let position = CGFloat(time.truncatingRemainder(dividingBy: 1.6) / 1.6)
        return LinearGradient(colors: [.clear, .white.opacity(0.45), .clear],
                              startPoint: .leading, endPoint: .trailing)
            .frame(width: 90)
            .offset(x: -90 + (width + 90) * position)
            .frame(width: width, alignment: .leading)
            .blendMode(.plusLighter)
    }
}

private struct GrowOnlyWidth: ViewModifier {
    let alignment: Alignment
    @State private var width: CGFloat = 0

    init(alignment: Alignment) {
        self.alignment = alignment
    }

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
                if newWidth > width { width = newWidth }
            }
            .frame(minWidth: width, alignment: alignment)
    }
}

extension View {
    /// Keeps the widest size seen so far, so changing text never makes the layout shrink back.
    func growOnlyWidth(alignment: Alignment = .leading) -> some View {
        modifier(GrowOnlyWidth(alignment: alignment))
    }
}
