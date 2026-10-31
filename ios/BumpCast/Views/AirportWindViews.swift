import SwiftUI

// Gusty takeoffs and landings, approved Oct 27: docs/design/airport-wind.html. A short label on
// the stretch row is the only indicator: nothing is drawn on the timeline. VoiceOver reads the
// full reassuring sentence. Teal only, never a severity colour, and never the "wind" symbol
// ("Practice breathing" uses it). Never knots, crosswind or a clock time.

/// The gust mark, drawn from the design's #gust symbol (a 22 × 14 grid): two short, offset easy
/// curves over a faint ground line, in teal. Decorative.
struct GustMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 22
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * size.height / 14) }
            var waves = Path()
            waves.move(to: point(1, 4))
            waves.addCurve(to: point(13, 4), control1: point(5, 1.5), control2: point(8, 6.5))
            waves.move(to: point(3, 9))
            waves.addCurve(to: point(16, 9), control1: point(7, 6.5), control2: point(10, 11.5))
            var ground = Path()
            ground.move(to: point(1, 13))
            ground.addLine(to: point(21, 13))
            let style = StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round)
            context.stroke(waves, with: .color(Theme.accent), style: style)
            context.stroke(ground, with: .color(Theme.accent.opacity(0.5)), style: style)
        }
    }
}

extension Forecast.Segment {
    /// The short row label: "Gusty in Newark around your landing", or for a moderate or stronger
    /// stretch "May also be gusty in Denver around your landing".
    func gustyLabel(city: String) -> String? {
        guard let end = gustyEnd else { return nil }
        let place = "in \(city) around your \(end == .takeoff ? "takeoff" : "landing")"
        return severity > .light ? "May also be gusty \(place)" : "Gusty \(place)"
    }

    /// What VoiceOver reads in place of the label: the full sentence, with its reassurance.
    func gustySentence(city: String) -> String? {
        guard let end = gustyEnd else { return nil }
        let around = "around your \(end == .takeoff ? "takeoff" : "landing")"
        if severity > .light { return "It may also be gusty in \(city) \(around), which the crew plans for." }
        return end == .takeoff
            ? "Gusty wind expected in \(city) \(around). The bumps ease as you climb."
            : "Gusty wind expected in \(city) \(around). Normal on a windy day, and the crew plans for it."
    }

    /// The in-flight reminder's body for a light gusty stretch, in forecast tense ("was expected":
    /// it comes from the forecast saved before takeoff). Nil for other stretches.
    func gustyReminder(city: String) -> String? {
        guard let end = gustyEnd, severity == .light else { return nil }
        return end == .takeoff
            ? "Gusty wind was expected in \(city) for your takeoff, so the climb may be bumpy for about \(minutes) min. It eases as you climb higher. Tap for a slow breathing exercise."
            : "Gusty wind was expected in \(city) for your landing, so the descent may be bumpy for about \(minutes) min. Routine for the crew. Tap for a slow breathing exercise."
    }
}

extension Flight {
    /// The city a gusty stretch names: where it takes off or lands. Nil names no city, and shows nothing.
    func gustyCity(_ end: Forecast.Segment.GustyEnd) -> String? {
        let city = (end == .takeoff ? originAirport : destinationAirport)?.city
        return city?.isEmpty == false ? city : nil
    }
}

/// The stretch row's gusty label: the gust mark and a short secondary line.
struct GustyRowLabel: View {
    let label: String
    let sentence: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            GustMark()
                .frame(width: 16, height: 11)
                .accessibilityHidden(true)
            Text(label).font(.bcSubheadline).foregroundStyle(.secondary)
                .accessibilityLabel(sentence)
        }
    }
}
