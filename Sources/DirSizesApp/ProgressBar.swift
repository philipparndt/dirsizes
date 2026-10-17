import SwiftUI

/// Rounded bar with a multi-color gradient fill and a moving sheen. Without a known total it
/// shows an indeterminate segment sliding back and forth.
struct ProgressBar: View {
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
