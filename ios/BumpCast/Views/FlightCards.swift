import StoreKit
import SwiftUI

/// Before and during the flight: "We've taken off" starts the Live Activity and offline reminders.
struct InFlightCard: View {
    let flight: Flight
    let forecast: Forecast

    @Environment(InFlight.self) private var inFlight
    @Environment(Paywalls.self) private var paywalls
    @Environment(FlightStore.self) private var store

    var body: some View {
        if inFlight.isFlying(flight, forecast: forecast) {
            flying
        } else if inFlight.canTakeOff(flight, forecast: forecast) {
            boarding
        } else if paywalls.hasFullAccess(to: flight), let synced = store.syncedAt,
            flight.departureAt.timeIntervalSinceNow < 24 * 3600
        {
            Label("Saved on this phone for offline use · updated \(synced.formatted(.relative(presentation: .named)))",
                systemImage: "arrow.down.circle")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
    }

    private var boarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Boarding soon?", systemImage: "airplane.departure").font(.bcCardTitle)
            Text("Tap when you take off. We'll count down to each bumpy stretch on your Lock Screen and remind you before it starts. Works without wifi.")
                .font(.bcSubheadline)
                .foregroundStyle(.secondary)
            Button {
                paywalls.unlock(.liveActivityLocked, flight: flight) {
                    inFlight.takeOff(flight, forecast: forecast)
                }
            } label: {
                Label("We've taken off", systemImage: "airplane")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
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
                Button("We've landed") { inFlight.land(flight) }
                    .buttonStyle(.bordered)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = store.reports[flight.id] {
                result(report)
                    .transition(.opacity)
            } else {
                Text("How did it feel?").font(.bcSection)
                if let forecast = store.forecasts[flight.id], let grade = forecast.grade {
                    Text("We forecast: \(grade.headline.lowercased())")
                        .font(.bcSubheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ForEach(FeltRating.allCases, id: \.self) { rating in
                        Button {
                            submit(rating)
                        } label: {
                            Text(rating.title).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        .disabled(isSending)
                    }
                }
                Text("Your answer helps make every forecast more accurate.")
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
