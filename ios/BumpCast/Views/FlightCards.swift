import StoreKit
import SwiftUI

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    /// Once a minute, on the flight's own minutes: each tick lands just after the time since takeoff
    /// passes a whole minute, so every in-flight line on a screen changes together.
    static func flightMinutes(takeoff: Date, now: Date = .now) -> PeriodicTimelineSchedule {
        // A whole number of minutes before takeoff and before now (so the first entry is now), plus a
        // second so a tick never lands a hair before the minute it's meant to show.
        let ahead = max(0, (takeoff.timeIntervalSince(now) / 60).rounded(.up))
        return .periodic(from: takeoff.addingTimeInterval(-(ahead + 1) * 60 + 1), by: 60)
    }
}

/// What the screens treat as in the air: the countdown's rule, never for a cancelled or diverted
/// flight, whose forecast and countdown follow the planned flight.
@MainActor
enum InFlightMode {
    static func isFlying(_ flight: Flight, forecast: Forecast?, inFlight: InFlight, now: Date) -> Bool {
        !flight.isDisrupted && inFlight.isFlying(flight, forecast: forecast, now: now)
    }

    /// Minutes since takeoff while flying, else nil.
    static func minute(_ flight: Flight, forecast: Forecast?, inFlight: InFlight, now: Date) -> Int? {
        flight.isDisrupted ? nil : inFlight.elapsedMinutes(flight, forecast: forecast, now: now)
    }

    /// The in-flight card is showing its flying view, which has its own connection note.
    static func showsFlyingCard(_ flight: Flight, forecast: Forecast, inFlight: InFlight, now: Date) -> Bool {
        isFlying(flight, forecast: forecast, inFlight: inFlight, now: now)
            && (inFlight.isArmed(flight) || inFlight.takeoffs[flight.id] != nil)
    }
}

/// Before and during the flight. At the gate the countdown is armed (and sold, to free users,
/// while there's still a connection); in the air "We've taken off" re-times it to wheels-up.
/// Stretch-by-stretch progress is the countdown's, so it only shows to people who have it; anyone
/// else in the air sees that they took off and can start it. Never for a cancelled flight. A
/// diverted one shows no progress (its forecast is the planned route's), but a countdown already
/// running keeps its buttons, since the Lock Screen and the reminders carry on until "We've landed".
struct InFlightCard: View {
    let flight: Flight
    let forecast: Forecast
    /// The screen's one clock, so this card and the forecast below it change minute together.
    var now: Date = .now

    @Environment(InFlight.self) private var inFlight
    @Environment(Paywalls.self) private var paywalls
    @Environment(FlightStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @State private var showsOfflineNote = false
    @State private var seatbeltTaps = 0

    var body: some View {
        let isFlying = InFlightMode.isFlying(flight, forecast: forecast, inFlight: inFlight, now: now)
        if flight.isDisrupted {
            if !flight.isCancelled && hasCountdown { diverted }
        } else if isFlying && hasCountdown {
            flying
        } else if isFlying || inFlight.canTakeOff(flight, forecast: forecast, now: now) {
            if inFlight.isArmed(flight) { armed } else { boarding }
        } else if paywalls.hasFullAccess(to: flight),
            let saved = OfflineCopy.lastChecked(syncedAt: store.syncedAt, issued: [forecast.issuedAt]),
            flight.departureAt.timeIntervalSince(now) < 24 * 3600
        {
            Label("Saved on this phone for offline use · updated \(saved.formatted(.relative(presentation: .named)))",
                systemImage: "arrow.down.circle")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Armed, or the user tapped takeoff: the countdown is theirs.
    private var hasCountdown: Bool { inFlight.isArmed(flight) || inFlight.takeoffs[flight.id] != nil }

    private var connection: ConnectionNote { ConnectionNote(store: store) }

    /// What the Live Activity is timed to, in the departure airport's time.
    private var takeoffTime: String {
        inFlight.effectiveTakeoff(of: flight).localTime(in: flight.originTimeZone)
    }

    /// Not armed yet. Before departure it's "get it ready"; once the airline reports wheels-up it's
    /// "start the countdown"; with neither, the user is telling us they're up.
    private var boarding: some View {
        let airborne = flight.reportedTakeoff
        let beforeDeparture = airborne == nil && now < flight.expectedDeparture && !flight.isAirborne
        return VStack(alignment: .leading, spacing: 10) {
            if let airborne {
                Label(InFlightCopy.airborneTitle, systemImage: "airplane").font(.bcCardTitle)
                landingProgress(from: airborne)
                Text(InFlightCopy.airborneBody(takeoff: airborne, tz: flight.originTimeZone))
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label(beforeDeparture ? "Boarding soon?" : "In the air?", systemImage: "airplane.departure")
                    .font(.bcCardTitle)
                Text(beforeDeparture
                    ? InFlightCopy.boardingBody(takeoff: takeoffTime)
                    : "Tap when you take off. We'll count down to each bumpy stretch on your Lock Screen and remind you before it starts. Works without wifi.")
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                paywalls.unlock(.liveActivityLocked, flight: flight, whenOffline: { showsOfflineNote = true }) {
                    showsOfflineNote = false
                    inFlight.getReady(flight, forecast: forecast)
                }
            } label: {
                Label {
                    Text(airborne != nil ? InFlightCopy.startCountdown : beforeDeparture ? "Get the countdown ready" : "We've taken off")
                } icon: {
                    if paywalls.isOpening {
                        ProgressView().controlSize(.small).tint(Theme.onAccent)
                    } else {
                        Image(systemName: "airplane")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            .disabled(paywalls.isOpening)
            if showsOfflineNote {
                Label(beforeDeparture
                    ? "Connect to wifi to unlock the countdown. Once it's ready, it works without a connection."
                    : "Connect to wifi to unlock the countdown, or get it ready before your next flight.",
                    systemImage: "wifi")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if beforeDeparture {
                wifiNote
            }
        }
        .skyCard()
        .animation(Theme.motion(reduceMotion), value: showsOfflineNote)
    }

    /// Armed, still on the ground. "We've taken off" corrects the timing if wheels-up differs.
    private var armed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Countdown ready", systemImage: "checkmark.circle").font(.bcCardTitle)
            Text(InFlightCopy.armedBody(takeoff: takeoffTime, onLockScreen: inFlight.hasActivity(flight.id)))
                .font(.bcSubheadline)
                .foregroundStyle(.secondary)
            Button {
                inFlight.takeOff(flight, forecast: forecast)
            } label: {
                Label("We've taken off", systemImage: "airplane")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text(connection.isConnectionProblem ? InFlightCopy.tapWhenUp : InFlightCopy.matchedToTakeoff)
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
            wifiNote
        }
        .skyCard()
    }

    /// Before takeoff: what plane wifi is good for, and that nothing needs it.
    private var wifiNote: some View {
        Label(InFlightCopy.wifiBeforeTakeoff, systemImage: "wifi")
            .font(.bcFootnote)
            .foregroundStyle(.secondary)
    }

    /// The trip so far, with the landing time at the destination. The bar moves by itself; the
    /// words follow the screen's clock.
    private func landingProgress(from takeoff: Date) -> some View {
        let landing = max(takeoff, inFlight.landing(of: flight, forecast: forecast))
        return ProgressView(timerInterval: takeoff...landing, countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            Text(InFlightCopy.landing(landing, now: now, tz: flight.destinationTimeZone))
                .font(.bcMeta)
        }
    }

    @ViewBuilder
    private var flying: some View {
        let takeoff = inFlight.effectiveTakeoff(of: flight)
        let minute = max(0, Int(now.timeIntervalSince(takeoff) / 60))
        let confidence = forecast.confidence(departure: flight.departureAt)
        VStack(alignment: .leading, spacing: 10) {
            Label(InFlightCopy.eyebrow(minute: minute), systemImage: "airplane").font(.bcCardTitle)
            Text(forecast.progressLine(minute: minute, departure: flight.departureAt)).font(.bcSection)
            landingProgress(from: takeoff)
            VStack(alignment: .leading, spacing: 4) {
                Text(InFlightCopy.basis(inFlight.takeoffBasis(of: flight), takeoff: takeoff, tz: flight.originTimeZone))
                Text(confidence.savedLine(issuedAt: forecast.issuedAt, inAir: (forecast.issuedAt ?? .distantPast) > takeoff))
            }
            .font(.bcFootnote)
            .foregroundStyle(.secondary)
            connectionNote(since: takeoff)
            if inFlight.hasActivity(flight.id) {
                Text(InFlightCopy.lockScreen).font(.bcFootnote).foregroundStyle(.secondary)
            }
            controls(minute: minute)
        }
        .skyCard()
        .animation(Theme.motion(reduceMotion), value: inFlight.seatbelts[flight.id]?.count)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: seatbeltTaps) { _, _ in hapticsEnabled }
    }

    /// Diverted with the countdown on: no progress (it would be the planned route's), only the
    /// buttons, so the countdown and its reminders can be ended once down.
    private var diverted: some View {
        let minute = max(0, Int(now.timeIntervalSince(inFlight.effectiveTakeoff(of: flight)) / 60))
        return VStack(alignment: .leading, spacing: 10) {
            Label(InFlightCopy.divertedTitle, systemImage: "airplane").font(.bcCardTitle)
            Text(InFlightCopy.divertedBody(onLockScreen: inFlight.hasActivity(flight.id)))
                .font(.bcSubheadline)
                .foregroundStyle(.secondary)
            // No "We've taken off": it would re-time the planned route's countdown (and bring back
            // a Lock Screen activity the user ended) for a flight going somewhere else.
            controls(minute: minute, showsTakeoff: false)
        }
        .skyCard()
        .animation(Theme.motion(reduceMotion), value: inFlight.seatbelts[flight.id]?.count)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: seatbeltTaps) { _, _ in hapticsEnabled }
    }

    /// Takeoff (until wheels-up is known), landing and, once up, the seatbelt note.
    @ViewBuilder
    private func controls(minute: Int, showsTakeoff: Bool = true) -> some View {
        HStack {
            // Armed flights count from the estimated wheels-up until the user says otherwise.
            if showsTakeoff, inFlight.takeoff(of: flight) == nil {
                Button("We've taken off") { inFlight.takeOff(flight, forecast: forecast) }
                    .buttonStyle(.bordered)
            }
            Button("We've landed") { inFlight.land(flight) }
                .buttonStyle(.bordered)
        }
        if inFlight.effectiveTakeoff(of: flight) <= now {
            seatbelt(minute: minute)
        }
    }

    /// No connection: everything still works, and what wifi would add. A sync that failed for
    /// another reason says only that. Back online in the air: when it last checked.
    @ViewBuilder
    private func connectionNote(since takeoff: Date) -> some View {
        switch connection {
        case .offline, .notOnline:
            VStack(alignment: .leading, spacing: 4) {
                Label(connection == .offline ? InFlightCopy.offline : InFlightCopy.notOnline, systemImage: "wifi.slash")
                    .font(.bcFootnoteStrong)
                Text(connection == .offline ? InFlightCopy.wifiInAir : InFlightCopy.notOnlineYet)
                    .font(.bcFootnote)
            }
            .foregroundStyle(.secondary)
        case .syncFailed:
            Label(InFlightCopy.syncFailed, systemImage: ConnectionNote.syncFailed.symbol)
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        case .none:
            // The same time the forecast footer gives (a forecast fetched on its own counts too).
            if let checked = OfflineCopy.lastChecked(syncedAt: store.syncedAt, issued: [forecast.issuedAt]), checked > takeoff {
                Label(InFlightCopy.connected(at: checked), systemImage: "wifi")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A one-tap note of when the sign came on, kept on the phone and sent with the landing rating.
    /// The thanks stays for a few minutes, then the button is back for the next time.
    @ViewBuilder
    private func seatbelt(minute: Int) -> some View {
        if let last = inFlight.seatbelts[flight.id]?.last, minute - last < 10 {
            VStack(alignment: .leading, spacing: 4) {
                Label(InFlightCopy.seatbeltNoted(minute: last), systemImage: "checkmark.circle")
                    .font(.bcFootnoteStrong)
                // Nothing forecast within 5 minutes of the tap.
                if !forecast.segments.contains(where: { $0.startMin - 5 <= last && last <= $0.endMin + 5 }) {
                    Text(InFlightCopy.seatbeltEarly).font(.bcFootnote)
                }
            }
            .foregroundStyle(.secondary)
            .transition(.opacity)
        } else {
            Button(InFlightCopy.seatbeltButton, systemImage: "figure.seated.seatbelt") {
                inFlight.noteSeatbelt(flight)
                seatbeltTaps += 1
            }
            .buttonStyle(.bordered)
        }
    }
}

/// After landing: "How did it feel?" compared with the forecast. The answers are the
/// calibration data for the forecast, and feed the public accuracy stats.
struct LandingCheckCard: View {
    let flight: Flight

    @Environment(FlightStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissed = false

    /// Beta flights always ask, compared with the outlook, until answered or dismissed.
    private var isBeta: Bool { store.forecasts[flight.id]?.isGlobalOutlook == true }

    var body: some View {
        if !dismissed {
            card
                .onAppear { dismissed = UserDefaults.standard.bool(forKey: Self.dismissKey(flight.id)) }
        }
    }

    /// Set once a beta flight's check is dismissed; the Flights list's Just landed card honours it too.
    static func dismissKey(_ flightID: UUID) -> String { "landingCheck.dismissed.\(flightID)" }

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
                            UserDefaults.standard.set(true, forKey: Self.dismissKey(flight.id))
                            dismissed = true
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    }
                }
                LandingRatingChoices(flight: flight)
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
        if store.isReportPending(flight.id) {
            Label(OfflineCopy.reportPending, systemImage: "arrow.up.circle")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// What the forecast said, and the three answers to "how did it feel?" compared with it. Shared by
/// the flight screen's landing check and the Flights list's Just landed card.
struct LandingRatingChoices: View {
    let flight: Flight

    @Environment(FlightStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isSending = false

    private var isBeta: Bool { store.forecasts[flight.id]?.isGlobalOutlook == true }

    var body: some View {
        if let forecast = store.forecasts[flight.id], let grade = forecast.grade {
            Text(isBeta ? "Our outlook: \(grade.outlookHeadline.lowercased())" : "We forecast: \(grade.headline.lowercased())")
                .font(.bcSubheadline)
                .foregroundStyle(.secondary)
        }
        // Three long answers stack on beta flights, as do any at accessibility sizes; the short
        // ones share a row.
        let layout = isBeta || typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
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
    }

    private func submit(_ rating: FeltRating) {
        isSending = true
        Task {
            let report = await store.submitLandingReport(flightID: flight.id, rating: rating)
            isSending = false
            // Only ask for an App Store rating after a flight where the forecast was right, and not
            // while the answer is still waiting on the phone for a connection.
            if report?.matched == true, !store.isReportPending(flight.id) {
                ReviewPrompt.request(.forecastMatched)
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
                    Label {
                        Text("See what changed")
                    } icon: {
                        if paywalls.isOpening { ProgressView().controlSize(.small) } else { Image(systemName: "lock") }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(paywalls.isOpening)
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
