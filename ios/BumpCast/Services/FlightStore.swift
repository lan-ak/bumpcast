import Foundation
import Observation
import Supabase

@Observable @MainActor
final class FlightStore {
    static let shared = FlightStore()

    private(set) var userID: UUID?
    private(set) var flights: [Flight] = []
    private(set) var forecasts: [UUID: Forecast] = [:]
    private(set) var updates: [UUID: [FlightUpdate]] = [:]
    private(set) var passes: Set<UUID> = []
    private(set) var reports: [UUID: LandingReport] = [:]
    private(set) var waitlist: Set<String> = []
    private(set) var syncedAt: Date?
    /// Flights added offline that haven't reached the server yet.
    private(set) var pendingAdds: [FlightDraft] = []
    private(set) var isLoading = false
    /// True when the last sync failed (usually no connection); the UI says it's showing saved data.
    private(set) var isOffline = false
    var error: String?

    /// Called after every successful sync so Superwall attributes and scheduled
    /// in-flight reminders stay current.
    @ObservationIgnored var onSync: (@MainActor () -> Void)?

    let service: FlightService
    private let local: LocalStore

    init(service: FlightService = Services.flights, local: LocalStore = .shared) {
        self.service = service
        self.local = local
        if let saved = local.load() {
            flights = saved.flights
            forecasts = saved.forecasts
            updates = saved.updates
            passes = saved.passes
            reports = saved.reports
            waitlist = saved.waitlist
            syncedAt = saved.syncedAt
            pendingAdds = saved.pendingAdds ?? []
        }
    }

    func start() async -> UUID? {
        do {
            let id = try await service.signIn()
            userID = id
            await reload()
            return id
        } catch {
            isOffline = true
            return nil
        }
    }

    func reload() async {
        // Unstructured so pull-to-refresh dismissing (which cancels its task) doesn't abort halfway.
        await Task {
            isLoading = true
            defer { isLoading = false }
            do {
                try await flushPendingAdds()
                let fetched = try await service.flights()
                async let passIDs = service.passFlightIDs()
                async let landed = service.landingReports()
                async let countries = service.waitlistCountries()
                flights = fetched
                // Drop cached data for flights deleted elsewhere.
                let ids = Set(fetched.map(\.id))
                forecasts = forecasts.filter { ids.contains($0.key) }
                updates = updates.filter { ids.contains($0.key) }
                await withTaskGroup(of: Void.self) { group in
                    for flight in fetched {
                        group.addTask { await self.refreshForecast(flight.id) }
                    }
                }
                passes = try await passIDs
                reports = Dictionary(uniqueKeysWithValues: try await landed.map { ($0.flightId, $0) })
                waitlist = try await countries
                syncedAt = .now
                isOffline = false
                await persist()
                onSync?()
            } catch {
                isOffline = true
                report(error, quietlyIfOffline: true)
            }
        }.value
    }

    func refreshForecast(_ id: UUID) async {
        do {
            async let forecast = service.latestForecast(for: id)
            async let feed = service.updates(for: id)
            // Mirror the server, including "no forecast" (e.g. after an edit reset it).
            forecasts[id] = try await forecast
            updates[id] = try await feed
        } catch {
            report(error, quietlyIfOffline: true)
        }
    }

    /// Whether a flight is only on this phone so far (added offline).
    func isPending(_ id: UUID) -> Bool { pendingAdds.contains { $0.id == id } }

    private func flushPendingAdds() async throws {
        for draft in pendingAdds {
            do {
                _ = try await service.add(draft)
            } catch let error as PostgrestError where error.code == "23505" {
                // Already saved by an earlier attempt.
            }
            pendingAdds.removeAll { $0.id == draft.id }
            await persist()
        }
    }

    @discardableResult
    func save(_ draft: FlightDraft, editing id: UUID? = nil) async -> Flight? {
        var draft = draft
        if id == nil, draft.id == nil { draft.id = UUID() }
        do {
            let flight = if let id { try await service.update(id, draft) } else { try await service.add(draft) }
            if let id, let old = self.flight(id),
                old.departureAt != draft.departureAt || old.origin != draft.origin || old.destination != draft.destination
            {
                // A different flight now: its taps, Live Activity and reminders no longer apply.
                InFlight.shared.forget(id)
            }
            flights.removeAll { $0.id == flight.id }
            flights.append(flight)
            flights.sort { $0.departureAt < $1.departureAt }
            forecasts[flight.id] = nil
            updates[flight.id] = nil
            await refreshForecast(flight.id)
            await persist()
            onSync?()
            return flight
        } catch where id == nil && Self.isOffline(error) {
            // Keep it on the phone and save it when the connection returns.
            let flight = draft.asFlight
            pendingAdds.append(draft)
            flights.append(flight)
            flights.sort { $0.departureAt < $1.departureAt }
            await persist()
            onSync?()
            return flight
        } catch {
            report(error)
            return nil
        }
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .dataNotAllowed, .cannotConnectToHost]
            .contains(urlError.code)
    }

    func delete(_ id: UUID) async {
        do {
            try await service.delete(id)
            flights.removeAll { $0.id == id }
            forecasts[id] = nil
            updates[id] = nil
            await persist()
            onSync?()
        } catch {
            report(error)
        }
    }

    // MARK: Flight passes, landing reports, waitlist

    func recordPass(flightID: UUID, transactionID: String, productID: String) async {
        passes.insert(flightID)
        await persist()
        do {
            try await service.recordPass(FlightPassRecord(transactionId: transactionID, flightId: flightID, productId: productID))
        } catch {
            report(error)
        }
        onSync?()
    }

    func submitLandingReport(flightID: UUID, rating: FeltRating) async -> LandingReport? {
        if let existing = reports[flightID] { return existing }
        do {
            let result = try await service.submitLandingReport(flightID: flightID, rating: rating)
            reports[flightID] = result
            await persist()
            onSync?()
            return result
        } catch {
            report(error)
            return nil
        }
    }

    func joinWaitlist(country: String, airport: String?) async {
        do {
            try await service.joinWaitlist(WaitlistEntry(country: country, airport: airport))
            waitlist.insert(country)
            await persist()
            onSync?()
        } catch {
            report(error)
        }
    }

    // MARK: Helpers

    func flight(_ id: UUID) -> Flight? { flights.first { $0.id == id } }

    var upcomingFlights: [Flight] {
        // Uses the tapped landing time when there is one.
        flights.filter { InFlight.shared.landing(of: $0, forecast: forecasts[$0.id]) > .now }
    }

    var nextFlight: Flight? { upcomingFlights.first }

    func resetLocalData() async {
        await local.clear()
    }

    private func persist() async {
        await local.save(
            Snapshot(
                flights: flights, forecasts: forecasts, updates: updates, passes: passes,
                reports: reports, waitlist: waitlist, syncedAt: syncedAt, pendingAdds: pendingAdds))
    }

    private func report(_ error: Error, quietlyIfOffline: Bool = false) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if quietlyIfOffline, let urlError = error as? URLError,
            [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .dataNotAllowed]
                .contains(urlError.code)
        {
            return
        }
        self.error = error.localizedDescription
    }
}

/// What a flight's forecast card should show right now.
enum ForecastState: Equatable {
    case unlocksAt(Date)
    case building
    /// A route only the global outlook covers, with the beta off: "Not forecast yet".
    case betaAvailable
    /// No forecast can cover this route: "We can't forecast this route yet".
    case outOfCoverage
    case ready(Forecast)

    init(flight: Flight, forecast: Forecast?, now: Date = .now, betaOn: Bool? = nil) {
        let betaOn = betaOn ?? GlobalBeta.storedIsOn
        if let forecast, forecast.status == .ready {
            self = forecast.isGlobalOutlook && !betaOn ? .betaAvailable : .ready(forecast)
        } else if forecast?.status == .outOfCoverage {
            self = .outOfCoverage
        } else if !Coverage.covers(flight) && !betaOn {
            self = .betaAvailable
        } else if now < flight.forecastUnlocksAt {
            self = .unlocksAt(flight.forecastUnlocksAt)
        } else {
            self = .building
        }
    }
}
