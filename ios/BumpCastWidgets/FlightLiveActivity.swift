import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct BumpCastWidgets: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
    }
}

/// Lock Screen, StandBy, Dynamic Island, Watch Smart Stack and CarPlay. Everything is worked out
/// at render time; the app sets staleDate to the next stretch boundary so the system re-renders
/// there even with no connection.
struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            ActivityRoot(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Sky.night.colors[1].opacity(0.85))  // night sky, also in StandBy
                .activitySystemActionForegroundColor(Theme.nightInk)
                .widgetURL(URL(string: "bumpcast://flight/\(context.attributes.flightID.uuidString)"))
        } dynamicIsland: { context in
            let a = context.attributes
            let s = context.state
            let current = a.current(at: .now, s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(a.route, systemImage: "airplane").font(.bcCaptionStrong)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: countdown(to: a.landing(s)), countsDown: true)
                        .font(.bcCaption.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        LeadText(attributes: a, state: s).font(.bcSubheadlineStrong)
                        RouteStrip(attributes: a, state: s)
                        HStack {
                            Link(destination: URL(string: "bumpcast://breathe")!) {
                                Label("Breathe", systemImage: "wind")
                            }
                            Spacer()
                            if let next = current?.0 {
                                Link(destination: URL(string: "bumpcast://learn/\(next.explainerID)")!) {
                                    Label("Why the next bumps?", systemImage: "book.pages")
                                }
                            }
                        }
                        .font(.bcCaptionStrong)
                    }
                }
            } compactLeading: {
                WaterGlass(severity: current.map { $0.1 ? $0.0.level : .smooth } ?? .smooth, size: 18)
            } compactTrailing: {
                CompactTimer(attributes: a, state: s)
            } minimal: {
                WaterGlass(severity: current.map { $0.1 ? $0.0.level : .smooth } ?? .smooth, size: 16)
            }
            .widgetURL(URL(string: "bumpcast://flight/\(a.flightID.uuidString)"))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// now...end, clamped so a past `end` can't make an inverted range (a runtime trap).
private func countdown(to end: Date) -> ClosedRange<Date> {
    let now = Date.now
    return min(now, end)...end
}

/// Lock Screen (medium) or Watch/CarPlay (small); after landing, the "How did it feel?" buttons.
private struct ActivityRoot: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        Group {
            if Date.now >= attributes.landing(state) {
                LandedView(attributes: attributes)
            } else if family == .small {
                SmallView(attributes: attributes, state: state)
            } else {
                LockScreenView(attributes: attributes, state: state)
            }
        }
        // The Live Activity is always on the night sky: the house style in its dark appearance.
        .bumpCastTheme()
        .themeInk()
        .environment(\.colorScheme, .dark)
    }
}

private struct LockScreenView: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributes.route, systemImage: "airplane").font(.bcMeta)
                Spacer()
                Text("Lands in \(Text(timerInterval: countdown(to: attributes.landing(state)), countsDown: true))")
                    .font(.bcCaption.monospacedDigit())
            }
            HStack(alignment: .center, spacing: 10) {
                WaterGlass(severity: currentSeverity, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    LeadText(attributes: attributes, state: state).font(.bcSection)
                    NextText(attributes: attributes, state: state).font(.bcCaption).foregroundStyle(.secondary)
                }
            }
            RouteStrip(attributes: attributes, state: state)
            HStack {
                Link(destination: URL(string: "bumpcast://breathe")!) {
                    Label("Breathe", systemImage: "wind")
                }
                Spacer()
                Link(destination: URL(string: "bumpcast://flight/\(attributes.flightID.uuidString)")!) {
                    Label("Full forecast", systemImage: "chart.bar")
                }
            }
            .font(.bcCaptionStrong)
            Text(footer).font(.bcCaption2).foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var currentSeverity: Severity {
        guard let (stretch, inProgress) = attributes.current(at: .now, state), inProgress else { return .smooth }
        return stretch.level
    }

    private var footer: String {
        guard let issued = attributes.issuedAt else { return "Saved before takeoff" }
        return "Saved before takeoff · \(attributes.confidenceTitle) from \(issued.formatted(date: .omitted, time: .shortened))"
    }
}

/// "Smooth for 42:10" / "Light chop now · 5:40 left" / "Smooth to landing".
private struct LeadText: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        if let (stretch, inProgress) = attributes.current(at: .now, state) {
            if inProgress {
                Text("\(stretch.title) now · \(Text(timerInterval: countdown(to: attributes.end(of: stretch, state)), countsDown: true).monospacedDigit()) left")
            } else {
                Text("Smooth for \(Text(timerInterval: countdown(to: attributes.start(of: stretch, state)), countsDown: true).monospacedDigit())")
            }
        } else {
            Text("Smooth to landing")
        }
    }
}

/// What comes after the current state.
private struct NextText: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        if let (stretch, inProgress) = attributes.current(at: .now, state) {
            if inProgress {
                Text("Then smoother air")
            } else {
                Text("Then \(stretch.title.lowercased()) for about \(stretch.minutes) min")
            }
        } else {
            Text("No more bumps expected")
        }
    }
}

/// Flight progress with the bumpy stretches marked: position vs bumps stays visible offline.
private struct RouteStrip: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "airplane.departure").font(.bcCaption2)
            ZStack(alignment: .leading) {
                ProgressView(timerInterval: state.takeoff...attributes.landing(state), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(Theme.nightInk)
                GeometryReader { geo in
                    let total = Double(max(attributes.durationMin, 1))
                    ForEach(attributes.stretches, id: \.startMin) { stretch in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.color(stretch.level))
                            .frame(width: max(3, geo.size.width * Double(stretch.minutes) / total), height: 6)
                            .offset(x: geo.size.width * Double(stretch.startMin) / total, y: geo.size.height / 2 - 3)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(height: 12)
            Image(systemName: "airplane.arrival").font(.bcCaption2)
        }
        .accessibilityHidden(true)
    }
}

/// Watch Smart Stack and CarPlay: glyph plus the one number that matters.
private struct SmallView: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            let current = attributes.current(at: .now, state)
            WaterGlass(severity: current.map { $0.1 ? $0.0.level : .smooth } ?? .smooth, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(attributes.route).font(.bcCaption2Strong)
                LeadText(attributes: attributes, state: state).font(.bcCaption)
            }
        }
        .padding(8)
    }
}

/// Dynamic Island compact trailing: minutes of smooth air left, shorter in the iOS 27
/// landscape Dynamic Island.
private struct CompactTimer: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        if #available(iOS 27, *) {
            LandscapeAwareTimer(attributes: attributes, state: state)
        } else {
            CompactTimerBody(attributes: attributes, state: state, limited: false)
        }
    }
}

@available(iOS 27, *)
private struct LandscapeAwareTimer: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState
    @Environment(\.isDynamicIslandLimitedInWidth) private var limited

    var body: some View {
        CompactTimerBody(attributes: attributes, state: state, limited: limited)
    }
}

private struct CompactTimerBody: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState
    let limited: Bool

    var body: some View {
        if let (stretch, inProgress) = attributes.current(at: .now, state) {
            Text(
                timerInterval: countdown(to: inProgress ? attributes.end(of: stretch, state) : attributes.start(of: stretch, state)),
                countsDown: true, showsHours: !limited
            )
            .font(.bcCaptionStrong.monospacedDigit())
            .frame(maxWidth: limited ? 36 : 52)
            .foregroundStyle(inProgress ? Theme.color(stretch.level) : Theme.color(.smooth))
        } else {
            Image(systemName: "checkmark")
        }
    }
}

/// After landing: rate the flight without opening the app.
private struct LandedView: View {
    let attributes: FlightActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Landed · \(attributes.route)", systemImage: "airplane.arrival").font(.bcFootnoteStrong)
            Text("How did it feel?").font(.bcSection)
            HStack {
                ForEach(FeltRating.allCases, id: \.self) { rating in
                    Button(intent: RateFlightIntent(flightID: attributes.flightID, rating: rating)) {
                        Text(rating.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.nightInk)
                }
            }
        }
        .padding()
    }
}
