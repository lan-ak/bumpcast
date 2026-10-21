import StoreKit
import SwiftUI

/// Before and during the flight. At the gate the countdown is armed (and sold, to free users,
/// while there's still a connection); in the air "We've taken off" re-times it to wheels-up.
struct InFlightCard: View {
    let flight: Flight
    let forecast: Forecast

    @Environment(InFlight.self) private var inFlight
    @Environment(Paywalls.self) private var paywalls
    @Environment(FlightStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsOfflineNote = false

    var body: some View {
        if inFlight.isFlying(flight, forecast: forecast) {
            flying
        } else if inFlight.canTakeOff(flight, forecast: forecast) {
            if inFlight.isArmed(flight) { armed } else { boarding }
        } else if paywalls.hasFullAccess(to: flight), let synced = store.syncedAt,
            flight.departureAt.timeIntervalSinceNow < 24 * 3600
        {
            Label("Saved on this phone for offline use · updated \(synced.formatted(.relative(presentation: .named)))",
                systemImage: "arrow.down.circle")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
    }

    private var takeoffTime: String {
        flight.estimatedTakeoff.formatted(date: .omitted, time: .shortened)
    }

    /// Not armed yet. Before departure it's "get it ready"; after, the user is telling us they're up.
    private var boarding: some View {
        let beforeDeparture = Date.now < flight.expectedDeparture
        return VStack(alignment: .leading, spacing: 10) {
            Label(beforeDeparture ? "Boarding soon?" : "In the air?", systemImage: "airplane.departure")
                .font(.bcCardTitle)
            Text(beforeDeparture
                ? "Get your bump countdown ready before you board. It starts on your Lock Screen at takeoff, around \(takeoffTime), and reminds you before each bumpy stretch. Works without wifi."
                : "Tap when you take off. We'll count down to each bumpy stretch on your Lock Screen and remind you before it starts. Works without wifi.")
                .font(.bcSubheadline)
                .foregroundStyle(.secondary)
            Button {
                paywalls.unlock(.liveActivityLocked, flight: flight, whenOffline: { showsOfflineNote = true }) {
                    showsOfflineNote = false
                    inFlight.getReady(flight, forecast: forecast)
                }
            } label: {
                Label(beforeDeparture ? "Get the countdown ready" : "We've taken off", systemImage: "airplane")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            if showsOfflineNote {
                Label(beforeDeparture
                    ? "Connect to wifi to unlock the countdown. Once it's ready, it works without a connection."
                    : "Connect to wifi to unlock the countdown, or get it ready before your next flight.",
                    systemImage: "wifi")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .skyCard()
        .animation(Theme.motion(reduceMotion), value: showsOfflineNote)
    }

    /// Armed, still on the ground. "We've taken off" corrects the timing if wheels-up differs.
    private var armed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Countdown ready", systemImage: "checkmark.circle").font(.bcCardTitle)
            Text("It starts on your Lock Screen at takeoff, around \(takeoffTime), and reminds you before each bumpy stretch. Works without wifi.")
                .font(.bcSubheadline)
                .foregroundStyle(.secondary)
            Button {
                inFlight.takeOff(flight, forecast: forecast)
            } label: {
                Label("We've taken off", systemImage: "airplane")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("We'll match the countdown to your real takeoff time once it's reported. Tap if you're up first.")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
        .skyCard()
    }

    private var flying: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                Label("In flight", systemImage: "airplane").font(.bcCardTitle)
                Text(status(at: context.date)).font(.bcSection)
                ProgressView(
                    timerInterval: inFlight.effectiveTakeoff(of: flight)...inFlight.landing(of: flight, forecast: forecast),
                    countsDown: false
                ) {
                    EmptyView()
                } currentValueLabel: {
                    Text("Landing about \(inFlight.landing(of: flight, forecast: forecast).formatted(date: .omitted, time: .shortened))")
                        .font(.bcMeta)
                }
                Text("The countdown is on your Lock Screen too.").font(.bcFootnote).foregroundStyle(.secondary)
                HStack {
                    // Armed flights count from the estimated wheels-up until the user says otherwise.
                    if inFlight.takeoff(of: flight) == nil {
                        Button("We've taken off") { inFlight.takeOff(flight, forecast: forecast) }
                            .buttonStyle(.bordered)
                    }
                    Button("We've landed") { inFlight.land(flight) }
                        .buttonStyle(.bordered)
                }
            }
            .skyCard()
        }
    }

    private func status(at date: Date) -> String {
        let takeoff = inFlight.effectiveTakeoff(of: flight)
        let minute = Int(date.timeIntervalSince(takeoff) / 60)
        if let current = forecast.segments.first(where: { $0.startMin <= minute && minute <= $0.endMin }) {
            let left = current.endMin - minute + 1
            return "\(current.severity.title) now, about \(left) min to go"
        }
        if let next = forecast.segments.first(where: { $0.startMin > minute }) {
            return "\(next.severity.title) in about \((next.startMin - minute).durationText)"
        }
        return "Smooth air for the rest of the flight"
    }
}

/// After landing: "How did it feel?" compared with the forecast. The answers are the
/// calibration data for the forecast, and feed the public accuracy stats.
struct LandingCheckCard: View {
    let flight: Flight

    @Environment(FlightStore.self) private var store
    @Environment(\.requestReview) private var requestReview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSending = false
    @State private var dismissed = false

    /// Beta flights always ask, compared with the outlook, until answered or dismissed.
    private var isBeta: Bool { store.forecasts[flight.id]?.isGlobalOutlook == true }

    var body: some View {
        if !dismissed {
            card
                .onAppear { dismissed = UserDefaults.standard.bool(forKey: dismissKey) }
        }
    }

    private var dismissKey: String { "landingCheck.dismissed.\(flight.id)" }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = store.reports[flight.id] {
                result(report)
                    .transition(.opacity)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(isBeta ? GlobalOutlookCopy.compareTitle : "How did it feel?").font(.bcSection)
                    Spacer()
                    if isBeta {
                        Button("Dismiss", systemImage: "xmark") {
                            UserDefaults.standard.set(true, forKey: dismissKey)
                            dismissed = true
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    }
                }
                if let forecast = store.forecasts[flight.id], let grade = forecast.grade {
                    Text(isBeta ? "Our outlook: \(grade.outlookHeadline.lowercased())" : "We forecast: \(grade.headline.lowercased())")
                        .font(.bcSubheadline)
                        .foregroundStyle(.secondary)
                }
                // Three long answers stack on beta flights; the short ones share a row.
                let layout = isBeta ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    ForEach(FeltRating.allCases, id: \.self) { rating in
                        Button {
                            submit(rating)
                        } label: {
                            Text(isBeta ? rating.outlookTitle : rating.title).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        .disabled(isSending)
                    }
                }
                Text(isBeta ? GlobalOutlookCopy.compareFooter : "Your answer helps make every forecast more accurate.")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
        }
        .skyCard()
        .animation(Theme.motion(reduceMotion), value: store.reports[flight.id])
    }

    @ViewBuilder
    private func result(_ report: LandingReport) -> some View {
        Label(report.matched == true ? "Glad it matched" : "Thanks for telling us",
            systemImage: report.matched == true ? "checkmark.seal.fill" : "hand.thumbsup")
            .font(.bcSection)
            .foregroundStyle(report.matched == true ? Theme.accent : Theme.ink)
        Text(report.matched == true
            ? "The forecast felt about right. We'll keep checking every flight."
            : "We use every answer to tune the forecast for flights like yours.")
            .font(.bcSubheadline)
            .foregroundStyle(.secondary)
    }

    private func submit(_ rating: FeltRating) {
        isSending = true
        Task {
            let report = await store.submitLandingReport(flightID: flight.id, rating: rating)
            isSending = false
            // Only ask for an App Store rating after a flight where the forecast was right, once per version.
            if report?.matched == true {
                let key = "review.requested.\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")"
                if !UserDefaults.standard.bool(forKey: key) {
                    UserDefaults.standard.set(true, forKey: key)
                    try? await Task.sleep(for: .seconds(1.5))
                    requestReview()
                }
            }
        }
    }
}

/// The "what changed and why" feed: every notification the worker sent for this flight.
struct UpdatesSection: View {
    let flight: Flight

    @Environment(FlightStore.self) private var store
    @Environment(Paywalls.self) private var paywalls

    var body: some View {
        let updates = store.updates[flight.id] ?? []
        if !updates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Updates").font(.bcSection)
                ForEach(updates) { update in
                    row(update, fullAccess: paywalls.hasFullAccess(to: flight))
                }
            }
        }
    }

    /// Pro sees what changed in detail. Free users see the summary of free notifications
    /// (the "ready" one) and a lock on updates, which are Pro.
    private func row(_ update: FlightUpdate, fullAccess: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(update.title).font(.bcCardTitle)
                Spacer()
                Text(update.createdAt, format: .relative(presentation: .named))
                    .font(.bcCaption)
                    .foregroundStyle(.secondary)
            }
            if fullAccess {
                ForEach(update.changes, id: \.text) { change in
                    Label(change.text, systemImage: "circle.fill")
                        .labelStyle(BulletLabelStyle())
                        .font(.bcSubheadline)
                }
            } else if !update.proOnly {
                Text(update.body).font(.bcSubheadline)
            } else {
                Button {
                    paywalls.unlock(.updatesLocked, flight: flight) {}
                } label: {
                    Label("See what changed", systemImage: "lock")
                }
                .buttonStyle(.bordered)
            }
        }
        .skyCard(cornerRadius: 16, padding: 14)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.bcCaption2).imageScale(.small).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
