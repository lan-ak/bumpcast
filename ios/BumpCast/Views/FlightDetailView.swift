import SwiftUI

struct FlightDetailView: View {
    let flightID: UUID

    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight
    @Environment(PushNotifications.self) private var push
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var isAdding = false

    private var connectivity: Connectivity { .shared }

    /// The id the flight is listed under now. A sync can save a flight again under a new id (an
    /// account that was lost); the open screen follows it there rather than reading "Flight removed".
    private var currentID: UUID { inFlight.currentID(of: flightID) }

    var body: some View {
        Group {
            if let flight = store.flight(currentID) {
                content(flight)
            } else {
                removed
            }
        }
        // While this screen is on top, what's done here that doesn't go through (a delete, or an
        // edit still saving after its sheet closed) says so here; the list's alert waits its turn.
        .alert("That didn't go through", isPresented: .constant(store.error != nil && router.flightPath.last == flightID)) {
            Button("OK") { store.error = nil }
        } message: {
            Text("Check your connection and try again. Your saved forecasts still work offline.")
        }
    }

    private var removed: some View {
        // Brand type, not ContentUnavailableView's system fonts.
        VStack(spacing: 10) {
            Image(systemName: "airplane").font(.bcTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Flight removed").font(.bcTitle2)
            Text("It's no longer in your flights.").font(.bcSubheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .skyBackground(Sky(date: .now))
    }

    private func content(_ flight: Flight) -> some View {
        let forecast = store.forecasts[flight.id]
        return ScrollView {
            // One clock for the screen, on the flight's minutes, so the in-flight card and the
            // forecast below it never disagree about now. Never behind the real time, so a tap
            // ("We've landed") shows at once rather than on the next tick. The state follows it
            // too, so "Your forecast unlocks …" moves on to "Building" when that time comes.
            TimelineView(.flightMinutes(takeoff: inFlight.effectiveTakeoff(of: flight))) { context in
                let now = max(context.date, .now)
                let state = ForecastState(flight: flight, forecast: forecast, now: now, betaOn: GlobalBeta.shared.isOn)
                sections(flight, forecast: forecast, state: state, now: now)
                    .task(id: state == .building) {
                        // While the worker is building the forecast, check back every 30 seconds (online only).
                        while ForecastState(flight: flight, forecast: store.forecasts[flight.id], betaOn: GlobalBeta.shared.isOn) == .building,
                            !Task.isCancelled
                        {
                            try? await Task.sleep(for: .seconds(30))
                            guard connectivity.isOnline else { continue }
                            await store.refreshForecast(flight.id)
                        }
                    }
            }
            .padding()
        }
        .skyBackground(Sky(date: flight.departureAt, timeZone: flight.originAirport?.timeZone ?? .current))
        .navigationTitle("Forecast")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                Button("Edit flight", systemImage: "pencil") { isEditing = true }
                Button("Delete flight", systemImage: "trash", role: .destructive) {
                    Task { await delete(flight) }
                }
            }
        }
        // Add flight opens the new forecast or shows its toast once the sheet has closed.
        .sheet(isPresented: $isEditing, onDismiss: { router.finishAdding() }) { AddFlightView(flight: flight) }
        .sheet(isPresented: $isAdding, onDismiss: { router.finishAdding() }) { AddFlightView() }
        .refreshable { await store.refresh() }
        .task(id: flight.id) { await waitForStatus() }
    }

    /// Leaves the screen only once the flight is gone: one that wasn't deleted stays, with the alert.
    private func delete(_ flight: Flight) async {
        await store.delete(flight.id)
        if store.flight(flight.id) == nil { dismiss() }
    }

    private func sections(_ flight: Flight, forecast: Forecast?, state: ForecastState, now: Date) -> some View {
        let landed = inFlight.landing(of: flight, forecast: forecast) <= now
        // The flying card carries its own connection note, so the label above it steps aside.
        let cardShowsConnection: Bool =
            if case .ready(let forecast) = state {
                !landed && InFlightMode.showsFlyingCard(flight, forecast: forecast, inFlight: inFlight, now: now)
            } else {
                false
            }
        let note = ConnectionNote(store: store)
        return VStack(alignment: .leading, spacing: 20) {
            FlightRouteHeader(flight: flight)
            ScheduleNote(flight: flight)
            if !cardShowsConnection,
                let text = OfflineCopy.detail(
                    note, checkedAt: OfflineCopy.lastChecked(syncedAt: store.syncedAt, issued: [forecast?.issuedAt]))
            {
                Label(text, systemImage: note.symbol)
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
            if case .ready(let forecast) = state {
                if landed {
                    // A cancelled flight wasn't flown: nothing to rate.
                    if !flight.isCancelled { LandingCheckCard(flight: flight) }
                } else {
                    InFlightCard(flight: flight, forecast: forecast, now: now)
                }
            }
            if !landed, flight.departureAt > now, !push.isEnabled, state != .outOfCoverage, state != .betaAvailable {
                NotificationsCard(forecastReady: { if case .ready = state { true } else { false } }())
            }
            if flight.status?.state == .cancelled {
                CancelledCard(flight: flight, addFlight: { isAdding = true }) {
                    Task { await delete(flight) }
                }
            } else if flight.status?.state == .diverted {
                DivertedCard(flight: flight)
            }
            switch state {
            case _ where flight.status?.state == .cancelled:
                EmptyView()  // the forecast describes a flight that isn't happening
            case .ready(let forecast) where flight.status?.state == .diverted:
                VStack(alignment: .leading, spacing: 8) {
                    Text("This forecast was for the original route to \(flight.destinationAirport?.iata ?? flight.destination).")
                        .font(.bcFootnote)
                        .foregroundStyle(.secondary)
                    ForecastView(forecast: forecast, flight: flight, now: now).opacity(0.45)
                }
            case .ready(let forecast):
                ForecastView(forecast: forecast, flight: flight, now: now)
            case .unlocksAt(let date):
                MessageCard(
                    symbol: "clock",
                    title: "Your forecast unlocks \(date.formatted(.relative(presentation: .named)))",
                    message: "Turbulence forecasts are only reliable about two days out. We'll have yours ready 48 hours before departure, then refresh it as your flight gets closer."
                )
            case .building:
                MessageCard(
                    symbol: "hourglass",
                    title: "Building your forecast",
                    message: "We're checking the latest turbulence data along your route. This usually takes a few minutes."
                )
            case .betaAvailable:
                BetaInviteCard(flight: flight)
            case .outOfCoverage:
                WaitlistCard(flight: flight)
            }
            UpdatesSection(flight: flight)
        }
    }

    /// A numbered flight near departure with no status yet, usually one just added (sometimes
    /// already in the air): the worker fetches it within seconds, so check back every 10 seconds
    /// for a couple of minutes. The header, the takeoff time and the countdown then follow.
    private func waitForStatus() async {
        for _ in 0..<12 {
            let id = currentID
            guard let flight = store.flight(id), flight.flightNumber != nil, !flight.schedulePending,
                !store.isPending(id), flight.status?.hasStatus != true,
                abs(flight.departureAt.timeIntervalSinceNow) < 6 * 3600
            else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            guard connectivity.isOnline else { continue }
            await store.refreshFlight(currentID)
        }
    }
}

struct MessageCard<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.bcTitle).foregroundStyle(.tint)
            Text(title).font(.bcSection)
            Text(message).foregroundStyle(.secondary)
            actions
        }
        .skyCard()
    }
}

extension MessageCard where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// A route only the global outlook covers, with the beta off: offer it, plainly.
private struct BetaInviteCard: View {
    let flight: Flight
    @Environment(FlightStore.self) private var store
    @State private var dismissed = false

    var body: some View {
        if dismissed {
            MessageCard(
                symbol: "globe",
                title: GlobalOutlookCopy.notForecastYet,
                message: "You can turn on global outlooks (beta) in Settings at any time.")
        } else {
            MessageCard(symbol: "globe", title: GlobalOutlookCopy.waitlistTitle, message: GlobalOutlookCopy.waitlistBody) {
                HStack {
                    Button(GlobalOutlookCopy.turnOn) {
                        GlobalBeta.shared.set(true)
                        Task { await store.refreshForecast(flight.id) }
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                    Button(GlobalOutlookCopy.notNow) {
                        GlobalBeta.shared.set(false)
                        dismissed = true
                        UserDefaults.standard.set(true, forKey: key)
                    }
                    .buttonStyle(.bordered).tint(Theme.accent)
                }
                .font(.bcSubheadlineStrong)
            }
            .onAppear { dismissed = UserDefaults.standard.bool(forKey: key) }
        }
    }

    private var key: String { "betaInvite.dismissed.\(flight.id)" }
}

/// No forecast can cover this route yet (polar and other routes the worker can't do).
private struct WaitlistCard: View {
    let flight: Flight
    @Environment(FlightStore.self) private var store
    @State private var isJoining = false

    var body: some View {
        let airport = Coverage.uncoveredAirport(flight)
        let country = airport?.country ?? "XX"
        MessageCard(
            symbol: "globe",
            title: GlobalOutlookCopy.unsupportedTitle,
            message: GlobalOutlookCopy.unsupportedBody
        ) {
            if store.waitlist.contains(country) {
                Label("We'll let you know when we can forecast it.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    isJoining = true
                    Task {
                        await store.joinWaitlist(country: country, airport: airport?.icao)
                        isJoining = false
                    }
                } label: {
                    Label(GlobalOutlookCopy.unsupportedAction, systemImage: "bell")
                }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                .disabled(isJoining)
            }
        }
    }
}

private struct NotificationsCard: View {
    let forecastReady: Bool

    @Environment(PushNotifications.self) private var push
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge").font(.bcTitle2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(forecastReady ? "Get told if your forecast changes" : "Get told when your forecast is ready")
                    .font(.bcCardTitle)
                Text(forecastReady
                    ? "We'll notify you at 24, 6 and 2 hours before departure, and when your forecast is confirmed."
                    : "We'll notify you 48 hours before departure, then when anything changes.")
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
                Button(push.status == .denied ? "Turn on in Settings" : "Turn on notifications") {
                    if push.status == .denied {
                        openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
                    } else {
                        Task { await push.requestPermission() }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .skyCard()
    }
}
