import Foundation
import Supabase

protocol FlightService: Sendable {
    func signIn() async throws -> UUID
    func flights() async throws -> [Flight]
    func add(_ draft: FlightDraft) async throws -> Flight
    func update(_ id: UUID, _ draft: FlightDraft) async throws -> Flight
    func delete(_ id: UUID) async throws
    func latestForecast(for flightID: UUID) async throws -> Forecast?
    func updates(for flightID: UUID) async throws -> [FlightUpdate]

    func registerDevice(token: String, environment: String) async throws
    func saveProfile(_ profile: ProfileRecord) async throws

    func passFlightIDs() async throws -> Set<UUID>
    func recordPass(_ pass: FlightPassRecord) async throws

    func landingReports() async throws -> [LandingReport]
    func submitLandingReport(flightID: UUID, rating: FeltRating) async throws -> LandingReport
    func accuracyStats() async throws -> AccuracyStats?

    func waitlistCountries() async throws -> Set<String>
    func joinWaitlist(_ entry: WaitlistEntry) async throws

    func pilotReports(since: Date) async throws -> [PilotReport]
    func turbulenceGrids(levelFt: Int) async throws -> [TurbulenceGrid]
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

    private static let flightColumns = "id,origin,destination,departure_at"
    private static let updateColumns = "id,flight_id,milestone,kind,grade,title,body,changes,pro_only,created_at"

    func signIn() async throws -> UUID {
        if let session = try? await client.auth.session {
            return session.user.id
        }
        return try await client.auth.signInAnonymously().user.id
    }

    func flights() async throws -> [Flight] {
        try await client.from("flights").select(Self.flightColumns).order("departure_at").execute().value
    }

    func add(_ draft: FlightDraft) async throws -> Flight {
        try await client.from("flights").insert(draft).select(Self.flightColumns).single().execute().value
    }

    func update(_ id: UUID, _ draft: FlightDraft) async throws -> Flight {
        try await client.from("flights").update(draft).eq("id", value: id)
            .select(Self.flightColumns).single().execute().value
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

    func updates(for flightID: UUID) async throws -> [FlightUpdate] {
        try await client.from("notifications").select(Self.updateColumns)
            .eq("flight_id", value: flightID)
            .order("created_at", ascending: false)
            .execute().value
    }

    func registerDevice(token: String, environment: String) async throws {
        try await client.rpc("register_device", params: ["p_token": token, "p_environment": environment]).execute()
    }

    func saveProfile(_ profile: ProfileRecord) async throws {
        try await client.from("profiles").upsert(profile, onConflict: "user_id").execute()
    }

    func passFlightIDs() async throws -> Set<UUID> {
        struct Row: Decodable { let flight_id: UUID }
        let rows: [Row] = try await client.from("flight_passes").select("flight_id").execute().value
        return Set(rows.map(\.flight_id))
    }

    func recordPass(_ pass: FlightPassRecord) async throws {
        try await client.from("flight_passes").upsert(pass, onConflict: "transaction_id", ignoreDuplicates: true).execute()
    }

    private static let reportColumns = "flight_id,felt,felt_relative,forecast_worst,matched"

    func landingReports() async throws -> [LandingReport] {
        try await client.from("landing_reports").select(Self.reportColumns).execute().value
    }

    func submitLandingReport(flightID: UUID, rating: FeltRating) async throws -> LandingReport {
        struct Insert: Encodable {
            let flight_id: UUID
            let felt_relative: FeltRating
        }
        return try await client.from("landing_reports")
            .insert(Insert(flight_id: flightID, felt_relative: rating))
            .select(Self.reportColumns).single().execute().value
    }

    func accuracyStats() async throws -> AccuracyStats? {
        let rows: [AccuracyStats] = try await client.rpc("accuracy_stats").execute().value
        return rows.first
    }

    func waitlistCountries() async throws -> Set<String> {
        struct Row: Decodable { let country: String }
        let rows: [Row] = try await client.from("waitlist").select("country").execute().value
        return Set(rows.map(\.country))
    }

    func joinWaitlist(_ entry: WaitlistEntry) async throws {
        try await client.from("waitlist").upsert(entry, onConflict: "user_id,country", ignoreDuplicates: true).execute()
    }

    func pilotReports(since: Date) async throws -> [PilotReport] {
        try await client.from("pireps").select()
            .gte("observed_at", value: since.ISO8601Format())
            .order("observed_at", ascending: false)
            .limit(1000)
            .execute().value
    }

    func turbulenceGrids(levelFt: Int) async throws -> [TurbulenceGrid] {
        try await client.from("turbulence_grids").select()
            .eq("level_ft", value: levelFt)
            .order("valid_at")
            .execute().value
    }
}

/// In-memory flights with a real forecast bundled from the worker, for previews and demo builds.
actor DemoFlightService: FlightService {
    private var stored: [Flight] = []
    private var passes: Set<UUID> = []
    private var reports: [UUID: LandingReport] = [:]
    private var waitlist: Set<String> = []

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

    func signIn() async throws -> UUID { UUID(uuidString: "00000000-0000-4000-8000-000000000000")! }

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
        if !Coverage.covers(flight) {
            return Forecast(
                status: .outOfCoverage, issuedAt: .now, source: nil, modelRun: nil, grade: nil, score: nil,
                durationMin: nil, cruiseFt: nil, segments: [], samples: [], route: [])
        }
        return Self.sampleForecast
    }

    func updates(for flightID: UUID) async throws -> [FlightUpdate] { [] }
    func registerDevice(token: String, environment: String) async throws {}
    func saveProfile(_ profile: ProfileRecord) async throws {}
    func passFlightIDs() async throws -> Set<UUID> { passes }
    func recordPass(_ pass: FlightPassRecord) async throws { passes.insert(pass.flightId) }
    func landingReports() async throws -> [LandingReport] { Array(reports.values) }

    func submitLandingReport(flightID: UUID, rating: FeltRating) async throws -> LandingReport {
        let worst = Self.sampleForecast.segments.map(\.severity).max() ?? .smooth
        let report = LandingReport(
            flightId: flightID, felt: nil, feltRelative: rating, forecastWorst: worst, matched: rating == .aboutRight)
        reports[flightID] = report
        return report
    }

    func accuracyStats() async throws -> AccuracyStats? {
        AccuracyStats(reports: 0, exact: 0, withinOne: 0, confirmedReports: 0, confirmedExact: 0)
    }

    func waitlistCountries() async throws -> Set<String> { waitlist }
    func joinWaitlist(_ entry: WaitlistEntry) async throws { waitlist.insert(entry.country) }
    func pilotReports(since: Date) async throws -> [PilotReport] { [] }
    func turbulenceGrids(levelFt: Int) async throws -> [TurbulenceGrid] { [] }
}
