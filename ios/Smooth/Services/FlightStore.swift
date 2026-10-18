import Foundation
import Observation

@Observable @MainActor
final class FlightStore {
    private(set) var flights: [Flight] = []
    private(set) var forecasts: [UUID: Forecast] = [:]
    private(set) var isLoading = false
    var error: String?

    private let service: FlightService

    init(service: FlightService = Services.flights) {
        self.service = service
    }

    func start() async {
        do {
            try await service.signIn()
            await reload()
        } catch {
            report(error)
        }
    }

    func reload() async {
        // Run unstructured so pull-to-refresh dismissing (which cancels its task)
        // doesn't abort the network calls halfway.
        await Task {
            isLoading = true
            defer { isLoading = false }
            do {
                flights = try await service.flights()
                await withTaskGroup(of: Void.self) { group in
                    for flight in flights {
                        group.addTask { await self.refreshForecast(flight.id) }
                    }
                }
            } catch {
                report(error)
            }
        }.value
    }

    func refreshForecast(_ id: UUID) async {
        do {
            forecasts[id] = try await service.latestForecast(for: id)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        self.error = error.localizedDescription
    }

    @discardableResult
    func save(_ draft: FlightDraft, editing id: UUID? = nil) async -> Flight? {
        do {
            let flight = if let id { try await service.update(id, draft) } else { try await service.add(draft) }
            flights.removeAll { $0.id == flight.id }
            flights.append(flight)
            flights.sort { $0.departureAt < $1.departureAt }
            forecasts[flight.id] = nil
            await refreshForecast(flight.id)
            return flight
        } catch {
            report(error)
            return nil
        }
    }

    func delete(_ id: UUID) async {
        do {
            try await service.delete(id)
            flights.removeAll { $0.id == id }
            forecasts[id] = nil
        } catch {
            report(error)
        }
    }
}

/// What a flight's forecast card should show right now.
enum ForecastState: Equatable {
    case unlocksAt(Date)
    case building
    case outOfCoverage
    case ready(Forecast)
    case departed

    init(flight: Flight, forecast: Forecast?, now: Date = .now) {
        if flight.departureAt < now.addingTimeInterval(-6 * 3600) {
            self = .departed
        } else if let forecast, forecast.status == .ready {
            self = .ready(forecast)
        } else if forecast?.status == .outOfCoverage {
            self = .outOfCoverage
        } else if now < flight.forecastUnlocksAt {
            self = .unlocksAt(flight.forecastUnlocksAt)
        } else {
            self = .building
        }
    }
}
