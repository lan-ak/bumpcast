import SwiftUI

/// A compact wave line of bumpiness through the flight, with bumpy stretches tinted.
/// Used on summary cards ("Cabin Dawn"); the precise bar chart lives on the forecast screen.
/// In the air, a marker shows where the plane is and the part already flown fades.
struct WaveTimeline: View {
    let forecast: Forecast
    var height: CGFloat = 36
    /// Minutes since takeoff while flying.
    var nowMinute: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let samples = forecast.samples
            let count = max(samples.count - 1, 1)
            let peak = max(0.4, samples.map(\.edr).max() ?? 0)
            let nowX = nowMinute.map { geo.size.width * CGFloat(min(max($0, 0), count)) / CGFloat(count) }
            let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            let line = Path { path in
                for (i, sample) in samples.enumerated() {
                    let point = CGPoint(
                        x: geo.size.width * CGFloat(i) / CGFloat(count),
                        y: geo.size.height * (1 - CGFloat(min(sample.edr, peak) / peak) * 0.85) - 2)
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            ZStack(alignment: .topLeading) {
                ForEach(forecast.segments, id: \.startMin) { segment in
                    let x = geo.size.width * CGFloat(segment.startMin) / CGFloat(count)
                    let w = max(3, geo.size.width * CGFloat(segment.minutes) / CGFloat(count))
                    let behind = nowMinute.map { segment.endMin < $0 } ?? false
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.color(segment.severity).opacity(behind ? 0.12 : 0.25))
                        .frame(width: w, height: geo.size.height)
                        .offset(x: x)
                }
                if let nowX {
                    // Flown: faint. Ahead: full strength, from the marker on.
                    line.stroke(Theme.accent.opacity(0.35), style: style)
                    line.stroke(Theme.accent, style: style)
                        .mask(alignment: .leading) { Rectangle().padding(.leading, nowX) }
                    Capsule()
                        .fill(Theme.ink)
                        .frame(width: 2, height: geo.size.height)
                        .offset(x: max(nowX - 1, 0))
                } else {
                    line.stroke(Theme.accent, style: style)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
