import SwiftUI

struct FlightsListView: View {
    @Environment(FlightStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Paywalls.self) private var paywalls
    @State private var isAdding = false
    @State private var isShowingSettings = false

    var body: some View {
        @Bindable var store = store
        @Bindable var router = router
        NavigationStack(path: $router.flightPath) {
            List {
                if Services.isDemo {
                    Label("Demo mode: sample forecast, nothing is saved", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.isOffline, let synced = store.syncedAt {
                    Label("Offline. Showing forecasts saved \(synced.formatted(.relative(presentation: .named))).", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(upcoming) { row($0) }
                            .onDelete { delete(upcoming, $0) }
                    }
                }
                if !flown.isEmpty {
                    Section("Flown") {
                        ForEach(flown) { row($0) }
                            .onDelete { delete(flown, $0) }
                    }
                }
            }
            .overlay {
                if store.flights.isEmpty && !store.isLoading {
                    ContentUnavailableView {
                        Label("No flights yet", systemImage: "airplane")
                    } description: {
                        Text("Save a flight and we'll have its turbulence forecast ready 48 hours before you fly.")
                    } actions: {
                        Button("Add a flight", action: addFlight)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Flights")
            .navigationDestination(for: UUID.self) { FlightDetailView(flightID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add flight", systemImage: "plus", action: addFlight)
                }
            }
            .refreshable { await store.reload() }
            .sheet(isPresented: $isAdding) { FlightEditorView() }
            .sheet(isPresented: $isShowingSettings) { SettingsView() }
            .alert("Something went wrong", isPresented: .constant(store.error != nil)) {
                Button("OK") { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
    }

    private var upcoming: [Flight] { store.upcomingFlights }
    private var flown: [Flight] {
        store.flights.filter { $0.estimatedLanding(store.forecasts[$0.id]) <= .now }.reversed()
    }

    private func row(_ flight: Flight) -> some View {
        NavigationLink(value: flight.id) {
            FlightRow(flight: flight, forecast: store.forecasts[flight.id], report: store.reports[flight.id])
        }
    }

    private func delete(_ flights: [Flight], _ offsets: IndexSet) {
        let ids = offsets.map { flights[$0].id }
        Task { for id in ids { await store.delete(id) } }
    }

    /// Free users can keep a couple of upcoming flights; more goes through the paywall.
    private func addFlight() {
        if paywalls.canAddFlight {
            isAdding = true
        } else {
            paywalls.unlock(.flightLimitReached) { isAdding = true }
        }
    }
}

struct FlightRow: View {
    let flight: Flight
    let forecast: Forecast?
    var report: LandingReport? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(flight.routeText).font(.headline)
                Spacer()
                StatusPill(state: ForecastState(flight: flight, forecast: forecast))
            }
            Text(flight.departureText).font(.subheadline).foregroundStyle(.secondary)
            if let report {
                Label(
                    report.matched == true ? "Forecast matched" : "You felt \(report.felt.title.lowercased())",
                    systemImage: report.matched == true ? "checkmark.circle" : "hand.raised")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else if let forecast, forecast.status == .ready, flight.departureAt > .now {
                let confidence = forecast.confidence(departure: flight.departureAt)
                Label(confidence.title, systemImage: confidence.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(confidence.color)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusPill: View {
    let state: ForecastState

    var body: some View {
        Group {
            switch state {
            case .ready(let forecast):
                if let grade = forecast.grade {
                    Label(grade.title, systemImage: grade.symbol).foregroundStyle(grade.color)
                }
            case .unlocksAt(let date):
                Label {
                    Text("Forecast \(date, format: .relative(presentation: .named))")
                } icon: {
                    Image(systemName: "clock")
                }
                .foregroundStyle(.secondary)
            case .building:
                Label("Preparing", systemImage: "hourglass").foregroundStyle(.secondary)
            case .outOfCoverage:
                Label("Not covered yet", systemImage: "globe").foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
    }
}

extension Flight {
    /// Departure in the origin airport's local time, e.g. "Sun, Oct 18 · 3:00 PM EDT".
    var departureText: String {
        let tz = originAirport?.timeZone ?? .current
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: tz)
        style = style.weekday(.abbreviated)
        let zone = tz.abbreviation(for: departureAt) ?? ""
        return "\(departureAt.formatted(style)) \(zone)"
    }
}
