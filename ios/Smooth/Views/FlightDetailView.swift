import SwiftUI

struct FlightDetailView: View {
    let flightID: UUID

    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    var body: some View {
        if let flight = store.flights.first(where: { $0.id == flightID }) {
            content(flight)
        } else {
            ContentUnavailableView("Flight removed", systemImage: "airplane")
        }
    }

    private func content(_ flight: Flight) -> some View {
        let state = ForecastState(flight: flight, forecast: store.forecasts[flight.id])
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FlightHeader(flight: flight)
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
                        message: "We're checking the latest turbulence data along your route. This usually takes a minute."
                    )
                case .outOfCoverage:
                    MessageCard(
                        symbol: "globe",
                        title: "We don't cover this route yet",
                        message: "Forecasts are US-only for now. Worldwide coverage is next, and we'll let you know when it reaches your route."
                    )
                case .departed:
                    MessageCard(symbol: "checkmark.circle", title: "This flight has flown", message: "Hope it was a smooth one.")
                }
            }
            .padding()
        }
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
        .refreshable { await store.refreshForecast(flight.id) }
        .task(id: state == .building) {
            // While the worker is building the forecast, check back every 15 seconds.
            while ForecastState(flight: flight, forecast: store.forecasts[flight.id]) == .building, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
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
            .font(.largeTitle.bold())
            Text("\(flight.originAirport?.city ?? "") to \(flight.destinationAirport?.city ?? "")")
                .foregroundStyle(.secondary)
            Text(flight.departureText).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct MessageCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title).foregroundStyle(.tint)
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.fill.quaternary, in: .rect(cornerRadius: 20))
    }
}
