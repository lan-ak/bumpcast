import SwiftUI

struct FlightsListView: View {
    @Environment(FlightStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Paywalls.self) private var paywalls
    @Environment(InFlight.self) private var inFlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoom
    @State private var isAdding = false
    @State private var isShowingSettings = false

    var body: some View {
        @Bindable var store = store
        @Bindable var router = router
        NavigationStack(path: $router.flightPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    notices
                    if let next = upcoming.first {
                        NavigationLink(value: next.id) {
                            NextFlightCard(flight: next, forecast: store.forecasts[next.id])
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: next.id, in: zoom)
                        .contextMenu { deleteButton(next) }
                    }
                    if upcoming.count > 1 {
                        section("Coming up", flights: Array(upcoming.dropFirst()))
                    }
                    if !flown.isEmpty {
                        section("Flown", flights: flown)
                    }
                    if store.flights.isEmpty && !store.isLoading {
                        emptyState
                    }
                    LearnCard()
                }
                .padding()
                // A new flight settles in with the house spring.
                .animation(Theme.motion(reduceMotion), value: store.flights.map(\.id))
            }
            .background { SkyBackground(sky: sky) }
            .navigationTitle("Flights")
            .navigationDestination(for: UUID.self) { id in
                FlightDetailView(flightID: id)
                    .navigationTransition(.zoom(sourceID: id, in: zoom))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add flight", systemImage: "plus", action: addFlight)
                }
            }
            .refreshable { await store.reload() }
            .sheet(isPresented: $isAdding) { AddFlightView().font(.bcBody) }
            .sheet(isPresented: $isShowingSettings) { SettingsView().font(.bcBody) }
            .sensoryFeedback(trigger: store.flights.count) { old, new in
                new > old ? .impact(flexibility: .soft, intensity: 0.5) : nil
            }
            .alert("Something went wrong", isPresented: .constant(store.error != nil)) {
                Button("OK") { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
    }

    private var upcoming: [Flight] { store.upcomingFlights }
    private var flown: [Flight] {
        store.flights.filter { inFlight.landing(of: $0, forecast: store.forecasts[$0.id]) <= .now }.reversed()
    }

    /// The sky follows the next flight's local departure time, or now.
    private var sky: Sky {
        guard let next = upcoming.first else { return Sky(date: .now) }
        return Sky(date: next.departureAt, timeZone: next.originAirport?.timeZone ?? .current)
    }

    @ViewBuilder
    private var notices: some View {
        if Services.isDemo {
            Label("Demo mode: sample forecast, nothing is saved", systemImage: "info.circle")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
        if store.isOffline, let synced = store.syncedAt {
            Label("Offline. Showing forecasts saved \(synced.formatted(.relative(presentation: .named))).", systemImage: "wifi.slash")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, flights: [Flight]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrow().foregroundStyle(.secondary)
            ForEach(flights) { flight in
                NavigationLink(value: flight.id) {
                    FlightRow(flight: flight, forecast: store.forecasts[flight.id], report: store.reports[flight.id])
                        .skyCard(cornerRadius: 18, padding: 14)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: flight.id, in: zoom)
                .contextMenu { deleteButton(flight) }
            }
        }
    }

    private func deleteButton(_ flight: Flight) -> some View {
        Button("Delete flight", systemImage: "trash", role: .destructive) {
            Task { await store.delete(flight.id) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            WaterGlass(severity: nil, size: 48)
            Text("No flights yet").font(.bcTitle2)
            Text("Save a flight and we'll have its turbulence forecast ready 48 hours before you fly.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add a flight", action: addFlight)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .skyCard()
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

/// The next flight, large: route, time, water glass, grade, wave timeline and confidence.
struct NextFlightCard: View {
    let flight: Flight
    let forecast: Forecast?

    var body: some View {
        let state = ForecastState(flight: flight, forecast: forecast)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next flight").eyebrow().foregroundStyle(.secondary)
                    Text(flight.routeText).font(.bcDisplay)
                    Text(flight.departureText).font(.bcMeta).foregroundStyle(.secondary)
                }
                Spacer()
                WaterGlass(severity: state.severity, size: 44)
            }
            switch state {
            case .ready(let forecast):
                if let grade = forecast.grade {
                    Text(grade.headline).font(.bcTitle2)
                }
                WaveTimeline(forecast: forecast)
                let confidence = forecast.confidence(departure: flight.departureAt)
                HStack(spacing: 6) {
                    Image(systemName: confidence.symbol)
                    Text(confidence.title)
                    if let issued = forecast.issuedAt {
                        Text("· updated \(issued.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.bcFootnoteStrong)
                .foregroundStyle(confidence.color)
            case .unlocksAt(let date):
                Text("Too early to tell").font(.bcTitle2)
                Text("Your first forecast arrives \(date.approximateDayAndTime()).").foregroundStyle(.secondary)
            case .building:
                Text("Building your forecast").font(.bcTitle2)
                Text("Checking the latest turbulence data along your route.").foregroundStyle(.secondary)
            case .outOfCoverage:
                Text("Not covered yet").font(.bcTitle2)
                Text("Forecasts cover US flights for now.").foregroundStyle(.secondary)
            }
        }
        .skyCard()
        .accessibilityElement(children: .combine)
    }
}

struct FlightRow: View {
    let flight: Flight
    let forecast: Forecast?
    var report: LandingReport? = nil

    var body: some View {
        let state = ForecastState(flight: flight, forecast: forecast)
        HStack(spacing: 14) {
            WaterGlass(severity: state.severity, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(flight.routeText).font(.bcHeadline)
                    Spacer()
                    StatusPill(state: state)
                }
                Text(flight.departureText).font(.bcMeta).foregroundStyle(.secondary)
                if let report {
                    Label(report.summary, systemImage: report.matched == true ? "checkmark.circle" : "hand.raised")
                        .font(.bcCaptionStrong)
                        .foregroundStyle(.secondary)
                } else if case .ready(let forecast) = state, flight.departureAt > .now {
                    let confidence = forecast.confidence(departure: flight.departureAt)
                    Label(confidence.shortStatus(), systemImage: confidence.symbol)
                        .font(.bcCaptionStrong)
                        .foregroundStyle(confidence.color)
                } else if case .unlocksAt(let date) = state {
                    Text("Too early · first forecast \(date.relativeDay())")
                        .font(.bcCaptionStrong)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    let state: ForecastState

    var body: some View {
        Group {
            switch state {
            case .ready(let forecast):
                if let grade = forecast.grade {
                    Text(grade.title).foregroundStyle(grade.color)
                }
            case .unlocksAt:
                Text("Too early").foregroundStyle(.secondary)
            case .building:
                Text("Preparing").foregroundStyle(.secondary)
            case .outOfCoverage:
                Text("Not covered yet").foregroundStyle(.secondary)
            }
        }
        .font(.bcCaptionStrong)
    }
}

/// A doorway into the Learn library from the Flights screen.
private struct LearnCard: View {
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.tab = .learn
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "book.pages").font(.bcTitle2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Why planes handle turbulence").font(.bcHeadline)
                    Text("Short reads on what's happening and what the crew is doing.")
                        .font(.bcSubheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .skyCard(cornerRadius: 18, padding: 14)
        }
        .buttonStyle(.plain)
    }
}

extension ForecastState {
    /// What the water glass shows: the forecast's worst stretch, or nil (dashed) when unknown.
    var severity: Severity? {
        if case .ready(let forecast) = self { return forecast.worstSeverity }
        return nil
    }
}

extension Forecast {
    var worstSeverity: Severity { segments.map(\.severity).max() ?? .smooth }
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
