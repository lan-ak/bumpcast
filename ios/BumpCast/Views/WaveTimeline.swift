import SwiftUI

/// A compact wave line of bumpiness through the flight, with bumpy stretches tinted.
/// Used on summary cards ("Cabin Dawn"); the precise bar chart lives on the forecast screen.
struct WaveTimeline: View {
    let forecast: Forecast
    var height: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let samples = forecast.samples
            let count = max(samples.count - 1, 1)
            let peak = max(0.4, samples.map(\.edr).max() ?? 0)
            ZStack(alignment: .topLeading) {
                ForEach(forecast.segments, id: \.startMin) { segment in
                    let x = geo.size.width * CGFloat(segment.startMin) / CGFloat(count)
                    let w = max(3, geo.size.width * CGFloat(segment.minutes) / CGFloat(count))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.color(segment.severity).opacity(0.25))
                        .frame(width: w, height: geo.size.height)
                        .offset(x: x)
                }
                Path { path in
                    for (i, sample) in samples.enumerated() {
                        let point = CGPoint(
                            x: geo.size.width * CGFloat(i) / CGFloat(count),
                            y: geo.size.height * (1 - CGFloat(min(sample.edr, peak) / peak) * 0.85) - 2)
                        i == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
