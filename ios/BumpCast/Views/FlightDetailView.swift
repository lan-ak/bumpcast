import SwiftUI

struct FlightDetailView: View {
    let flightID: UUID

    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight
    @Environment(PushNotifications.self) private var push
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    var body: some View {
        if let flight = store.flight(flightID) {
            content(flight)
        } else {
            ContentUnavailableView("Flight removed", systemImage: "airplane")
        }
    }

    private func content(_ flight: Flight) -> some View {
        let forecast = store.forecasts[flight.id]
        let state = ForecastState(flight: flight, forecast: forecast)
        let landed = inFlight.landing(of: flight, forecast: forecast) <= .now
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FlightHeader(flight: flight)
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
                if !landed, flight.departureAt > .now, !push.isEnabled, state != .outOfCoverage {
                    NotificationsCard(forecastReady: { if case .ready = state { true } else { false } }())
                }
                switch state {
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
                case .outOfCoverage:
                    WaitlistCard(flight: flight)
                }
                UpdatesSection(flight: flight)
            }
            .padding()
        }
        .background { SkyBackground(sky: Sky(date: flight.departureAt, timeZone: flight.originAirport?.timeZone ?? .current)) }
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
        .sheet(isPresented: $isEditing) { FlightEditorView(flight: flight) }
        .refreshable { await store.reload() }
        .task(id: state == .building) {
            // While the worker is building the forecast, check back every 30 seconds.
            while ForecastState(flight: flight, forecast: store.forecasts[flight.id]) == .building, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await store.refreshForecast(flight.id)
            }
        }
    }
}

private struct FlightHeader: View {
    let flight: Flight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(flight.originAirport?.iata ?? flight.origin)
                Image(systemName: "airplane").font(.title2).foregroundStyle(.secondary)
                Text(flight.destinationAirport?.iata ?? flight.destination)
            }
            .font(.bcDisplay)
            Text("\(flight.originAirport?.city ?? "") to \(flight.destinationAirport?.city ?? "")")
                .foregroundStyle(.secondary)
            Text(flight.departureText).font(.bcMeta).foregroundStyle(.secondary)
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
            Image(systemName: symbol).font(.title).foregroundStyle(.tint)
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

/// Outside US coverage: say so plainly and offer to notify when the region launches.
private struct WaitlistCard: View {
    let flight: Flight
    @Environment(FlightStore.self) private var store
    @State private var isJoining = false

    var body: some View {
        let airport = Coverage.uncoveredAirport(flight)
        let country = airport?.country ?? "XX"
        let name = Locale.current.localizedString(forRegionCode: country) ?? country
        MessageCard(
            symbol: "globe",
            title: "We don't cover this route yet",
            message: "BumpCast forecasts cover US flights for now. Worldwide coverage is next."
        ) {
            if store.waitlist.contains(country) {
                Label("We'll let you know when we cover \(name).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    isJoining = true
                    Task {
                        await store.joinWaitlist(country: country, airport: airport?.icao)
                        isJoining = false
                    }
                } label: {
                    Label("Notify me when you cover \(name)", systemImage: "bell")
                }
                .buttonStyle(.borderedProminent)
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
            Image(systemName: "bell.badge").font(.title2).foregroundStyle(.tint)
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
