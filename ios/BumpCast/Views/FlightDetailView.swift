import SwiftUI

struct FlightDetailView: View {
    let flightID: UUID

    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight
    @Environment(PushNotifications.self) private var push
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var isAdding = false

    var body: some View {
        if let flight = store.flight(flightID) {
            content(flight)
        } else {
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
    }

    private func content(_ flight: Flight) -> some View {
        let forecast = store.forecasts[flight.id]
        let state = ForecastState(flight: flight, forecast: forecast, betaOn: GlobalBeta.shared.isOn)
        let landed = inFlight.landing(of: flight, forecast: forecast) <= .now
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FlightRouteHeader(flight: flight)
                ScheduleNote(flight: flight)
                if store.isOffline, let synced = store.syncedAt {
                    Label("Offline. Saved \(synced.formatted(.relative(presentation: .named))).", systemImage: "wifi.slash")
                        .font(.bcFootnote)
                        .foregroundStyle(.secondary)
                }
                if case .ready(let forecast) = state {
                    if landed {
                        LandingCheckCard(flight: flight)
                    } else {
                        InFlightCard(flight: flight, forecast: forecast)
                    }
                }
                if !landed, flight.departureAt > .now, !push.isEnabled, state != .outOfCoverage, state != .betaAvailable {
                    NotificationsCard(forecastReady: { if case .ready = state { true } else { false } }())
                }
                if flight.status?.state == .cancelled {
                    CancelledCard(flight: flight, addFlight: { isAdding = true }) {
                        Task {
                            await store.delete(flight.id)
                            dismiss()
                        }
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
                        ForecastView(forecast: forecast, flight: flight).opacity(0.45)
                    }
                case .ready(let forecast):
                    ForecastView(forecast: forecast, flight: flight)
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
            .padding()
        }
        .skyBackground(Sky(date: flight.departureAt, timeZone: flight.originAirport?.timeZone ?? .current))
        .navigationTitle("Forecast")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                Button("Edit flight", systemImage: "pencil") { isEditing = true }
                Button("Delete flight", systemImage: "trash", role: .destructive) {
                    Task {
                        await store.delete(flight.id)
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $isEditing) { AddFlightView(flight: flight) }
        .sheet(isPresented: $isAdding) { AddFlightView() }
        .refreshable { await store.reload() }
        .task(id: state == .building) {
            // While the worker is building the forecast, check back every 30 seconds.
            while ForecastState(flight: flight, forecast: store.forecasts[flight.id], betaOn: GlobalBeta.shared.isOn) == .building,
                !Task.isCancelled
            {
                try? await Task.sleep(for: .seconds(30))
                await store.refreshForecast(flight.id)
            }
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
