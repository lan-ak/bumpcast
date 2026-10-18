import Foundation
import Supabase

protocol FlightService: Sendable {
    func signIn() async throws
    func flights() async throws -> [Flight]
    func add(_ draft: FlightDraft) async throws -> Flight
    func update(_ id: UUID, _ draft: FlightDraft) async throws -> Flight
    func delete(_ id: UUID) async throws
    func latestForecast(for flightID: UUID) async throws -> Forecast?
}

enum Services {
    /// Supabase when configured in Secrets.xcconfig, otherwise demo mode.
    static let flights: FlightService = {
        let info = Bundle.main.infoDictionary ?? [:]
        if let urlString = info["SupabaseURL"] as? String, let url = URL(string: urlString), url.host() != nil,
            let key = info["SupabaseAnonKey"] as? String, !key.isEmpty
        {
            return SupabaseFlightService(client: SupabaseClient(supabaseURL: url, supabaseKey: key))
        }
        return DemoFlightService()
    }()

    static var isDemo: Bool { flights is DemoFlightService }
}

struct SupabaseFlightService: FlightService {
    let client: SupabaseClient

    func signIn() async throws {
        if (try? await client.auth.session) == nil {
            try await client.auth.signInAnonymously()
        }
    }

    func flights() async throws -> [Flight] {
        try await client.from("flights").select("id,origin,destination,departure_at")
            .order("departure_at").execute().value
    }

    func add(_ draft: FlightDraft) async throws -> Flight {
        try await client.from("flights").insert(draft).select("id,origin,destination,departure_at")
            .single().execute().value
    }

    func update(_ id: UUID, _ draft: FlightDraft) async throws -> Flight {
        try await client.from("flights").update(draft).eq("id", value: id)
            .select("id,origin,destination,departure_at").single().execute().value
    }

    func delete(_ id: UUID) async throws {
        try await client.from("flights").delete().eq("id", value: id).execute()
    }

    func latestForecast(for flightID: UUID) async throws -> Forecast? {
        let rows: [Forecast] = try await client.from("forecasts").select()
            .eq("flight_id", value: flightID)
            .order("issued_at", ascending: false)
            .limit(1)
            .execute().value
        return rows.first
    }
}

/// In-memory flights with a real forecast bundled from the worker, for previews and demo builds.
actor DemoFlightService: FlightService {
    private var stored: [Flight] = []

    init() {
        let soon = Date.now.addingTimeInterval(5 * 3600)
        stored = [
            Flight(id: UUID(), origin: "KJFK", destination: "KLAX", departureAt: soon),
            Flight(id: UUID(), origin: "KORD", destination: "KDEN", departureAt: soon.addingTimeInterval(4 * 86400)),
            Flight(id: UUID(), origin: "CYYZ", destination: "EGLL", departureAt: soon.addingTimeInterval(86400)),
        ]
    }

    static let sampleForecast: Forecast = {
        let url = Bundle.main.url(forResource: "sample_forecast", withExtension: "json")!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(Forecast.self, from: Data(contentsOf: url))
    }()

    func signIn() async throws {}

    func flights() async throws -> [Flight] { stored.sorted { $0.departureAt < $1.departureAt } }

    func add(_ draft: FlightDraft) async throws -> Flight {
        let flight = Flight(id: UUID(), origin: draft.origin, destination: draft.destination, departureAt: draft.departureAt)
        stored.append(flight)
        return flight
    }

    func update(_ id: UUID, _ draft: FlightDraft) async throws -> Flight {
        let flight = Flight(id: id, origin: draft.origin, destination: draft.destination, departureAt: draft.departureAt)
        stored.removeAll { $0.id == id }
        stored.append(flight)
        return flight
    }

    func delete(_ id: UUID) async throws { stored.removeAll { $0.id == id } }

    func latestForecast(for flightID: UUID) async throws -> Forecast? {
        guard let flight = stored.first(where: { $0.id == flightID }) else { return nil }
        if flight.departureAt > .now.addingTimeInterval(Flight.forecastWindow) {
            return nil
        }
        if let o = flight.originAirport, let d = flight.destinationAirport, !(o.country == "US" && d.country == "US") {
            return Forecast(
                status: .outOfCoverage, issuedAt: .now, source: nil, modelRun: nil, grade: nil, score: nil,
                durationMin: nil, cruiseFt: nil, segments: [], samples: [], route: [])
        }
        return Self.sampleForecast
    }
}
