import SwiftUI

struct FlightsListView: View {
    @Environment(FlightStore.self) private var store
    @State private var isAdding = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                if Services.isDemo {
                    Label("Demo mode: sample forecast, nothing is saved", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.flights) { flight in
                    NavigationLink(value: flight) {
                        FlightRow(flight: flight, forecast: store.forecasts[flight.id])
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.flights[$0].id }
                    Task { for id in ids { await store.delete(id) } }
                }
            }
            .overlay {
                if store.flights.isEmpty && !store.isLoading {
                    ContentUnavailableView {
                        Label("No flights yet", systemImage: "airplane")
                    } description: {
                        Text("Save a flight and we'll have its turbulence forecast ready 48 hours before you fly.")
                    } actions: {
                        Button("Add a flight") { isAdding = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Flights")
            .navigationDestination(for: Flight.self) { FlightDetailView(flightID: $0.id) }
            .toolbar {
                Button("Add flight", systemImage: "plus") { isAdding = true }
            }
            .refreshable { await store.reload() }
            .sheet(isPresented: $isAdding) { FlightEditorView() }
            .alert("Something went wrong", isPresented: .constant(store.error != nil)) {
                Button("OK") { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
    }
}

struct FlightRow: View {
    let flight: Flight
    let forecast: Forecast?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(routeText).font(.headline)
                Spacer()
                StatusPill(state: ForecastState(flight: flight, forecast: forecast))
            }
            Text(flight.departureText).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var routeText: String {
        "\(flight.originAirport?.iata ?? flight.origin) → \(flight.destinationAirport?.iata ?? flight.destination)"
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
            case .departed:
                Label("Flown", systemImage: "checkmark").foregroundStyle(.secondary)
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
