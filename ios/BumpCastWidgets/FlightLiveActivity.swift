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
/// at render time from the state's plan (the attributes' when the state has none); the app sets
/// staleDate to the next stretch boundary so the system re-renders there even with no connection.
/// Nothing re-renders at takeoff, so what shows at the gate must still read right after it.
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
            let glass = a.glass(at: .now, s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(a.route, systemImage: "airplane").font(.bcCaptionStrong)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimeLabel(attributes: a, state: s, compact: true)
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
                WaterGlass(severity: glass, size: 18)
            } compactTrailing: {
                CompactTimer(attributes: a, state: s)
            } minimal: {
                WaterGlass(severity: glass, size: 16)
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

/// Top right: the takeoff time until the plane is up, then how long until landing. Before takeoff
/// it's a clock time, which still reads right after takeoff until the next re-render.
private struct TimeLabel: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState
    let compact: Bool

    var body: some View {
        if Date.now < state.takeoff {
            let time = state.takeoff.formatted(date: .omitted, time: .shortened)
            Text(compact ? time : "Takeoff ~\(time)")
        } else {
            let left = Text(timerInterval: countdown(to: attributes.landing(state)), countsDown: true)
            if compact { left } else { Text("Lands in \(left)") }
        }
    }
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
                TimeLabel(attributes: attributes, state: state, compact: false)
                    .font(.bcCaption.monospacedDigit())
            }
            HStack(alignment: .center, spacing: 10) {
                WaterGlass(severity: attributes.glass(at: .now, state), size: 28)
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
                Spacer()
                EndButton(flightID: attributes.flightID)
            }
            .font(.bcCaptionStrong)
            Text(footer).font(.bcCaption2).foregroundStyle(.tertiary)
        }
        .padding()
    }

    /// The takeoff the countdown is timed to and how fresh the plan is: "Takeoff 2:53 PM ·
    /// Confirmed forecast, updated 2:20 PM". Before takeoff the lead line already gives the time.
    private var footer: String {
        let plan = attributes.issued(state).map {
            "\(attributes.confidence(state)), updated \($0.formatted(date: .omitted, time: .shortened))"
        }
        guard Date.now >= state.takeoff else { return plan ?? "Saved on this phone" }
        let takeoff = "Takeoff \(state.takeoff.formatted(date: .omitted, time: .shortened))"
        return "\(takeoff) · \(plan ?? "saved on this phone")"
    }
}

/// "Takeoff around 2:50 PM" / "Smooth for 42:10" / "Light chop now · 5:40 left" / "Smooth to landing".
/// A global outlook never says "smooth", and its outlook stretches read "Bumps possible" at rough
/// times, as in the app: "Bumps possible around 3:40 PM" / "No major bumps expected to landing".
private struct LeadText: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        if Date.now < state.takeoff {
            // Started at the gate: nothing counts "Smooth for" through the taxi. Offline this
            // shows until the first stretch starts, and still reads right in the climb.
            Text("Takeoff around \(state.takeoff.formatted(date: .omitted, time: .shortened))")
        } else if let (stretch, inProgress) = attributes.current(at: .now, state) {
            if attributes.isOutlook(stretch, state) {
                // A clock time, not a timer: approximate, and still right with no re-render.
                Text(inProgress ? "Bumps possible now" : "Bumps possible around \(aboutTime(attributes.start(of: stretch, state)))")
            } else if inProgress {
                Text("\(stretch.level.phrase.sentenceCased) now · \(Text(timerInterval: countdown(to: attributes.end(of: stretch, state)), countsDown: true).monospacedDigit()) left")
            } else if attributes.isGlobalOutlook(state) {
                Text("\(stretch.level.phrase.sentenceCased) in \(Text(timerInterval: countdown(to: attributes.start(of: stretch, state)), countsDown: true).monospacedDigit())")
            } else {
                Text("Smooth for \(Text(timerInterval: countdown(to: attributes.start(of: stretch, state)), countsDown: true).monospacedDigit())")
            }
        } else {
            Text(attributes.isGlobalOutlook(state) ? "No major bumps expected to landing" : "Smooth to landing")
        }
    }
}

/// What comes after the current state.
private struct NextText: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        let globalOutlook = attributes.isGlobalOutlook(state)
        if Date.now < state.takeoff {
            if let first = attributes.stretches(state).first {
                if attributes.isOutlook(first, state) {
                    Text(first.startMin < 5
                        ? "Then bumps possible soon after takeoff"
                        : "Then bumps possible about \(roughText(first.startMin)) in")
                } else {
                    Text(first.startMin < 1
                        ? "Then \(first.level.phrase) right after takeoff"
                        : "Then \(first.level.phrase) about \(first.startMin) min in")
                }
            } else {
                Text(globalOutlook ? "No major bumps expected" : "Smooth flight expected")
            }
        } else if let (stretch, inProgress) = attributes.current(at: .now, state) {
            if attributes.isOutlook(stretch, state) {
                Text(inProgress
                    ? "Until about \(aboutTime(attributes.end(of: stretch, state)))"
                    : "For around \(roughText(stretch.minutes))")
            } else if inProgress {
                Text(globalOutlook ? "Then no major bumps expected" : "Then smoother air")
            } else if globalOutlook {
                Text("For about \(stretch.minutes) min")
            } else {
                Text("Then \(stretch.level.phrase) for about \(stretch.minutes) min")
            }
        } else {
            Text(globalOutlook ? "Light bumps are possible on any flight" : "No more bumps expected")
        }
    }
}

/// Outlook times are approximate: the clock to the nearest 10 minutes, "3:40 PM".
private func aboutTime(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.minute, .second], from: date)
    let past = TimeInterval((parts.minute ?? 0) % 10 * 60 + (parts.second ?? 0))
    return date.addingTimeInterval(past >= 300 ? 600 - past : -past).formatted(date: .omitted, time: .shortened)
}

/// Outlook lengths are approximate, as in the app: the nearest 10 min under an hour, the nearest
/// 30 min above. 95 -> "1 h 30 min".
private func roughText(_ minutes: Int) -> String {
    let rough = minutes < 60 ? max(10, (minutes + 5) / 10 * 10) : (minutes + 15) / 30 * 30
    let h = rough / 60, m = rough % 60
    if h == 0 { return "\(m) min" }
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
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
                    let total = Double(max(attributes.duration(state), 1))
                    ForEach(attributes.stretches(state), id: \.startMin) { stretch in
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
            WaterGlass(severity: attributes.glass(at: .now, state), size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(attributes.route).font(.bcCaption2Strong)
                LeadText(attributes: attributes, state: state).font(.bcCaption)
            }
        }
        .padding(8)
    }
}

/// Dynamic Island compact trailing: minutes of smooth air left (from the gate, counting through
/// takeoff, which nothing re-renders at), shorter in the iOS 27 landscape Dynamic Island.
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
            .foregroundStyle(Theme.color(attributes.glass(at: .now, state)))
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
            HStack {
                Text("How did it feel?").font(.bcSection)
                Spacer()
                EndButton(flightID: attributes.flightID, title: "Skip")
            }
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

/// Takes the countdown off the Lock Screen. The in-flight reminders stay.
private struct EndButton: View {
    let flightID: UUID
    var title: String = "End"

    var body: some View {
        Button(intent: EndFlightActivityIntent(flightID: flightID)) {
            Label(title, systemImage: "xmark")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(title == "End" ? "End the countdown" : "Skip rating")
    }
}
