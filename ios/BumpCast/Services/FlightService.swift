import Foundation
import Supabase

protocol FlightService: Sendable {
    /// The account of the session saved on this phone, even with an expired token (requests
    /// refresh it once there's a connection). A new anonymous account only when none is saved and
    /// `allowSignUp`: a refresh that fails in the air is never a reason for a new account.
    func signIn(allowSignUp: Bool) async throws -> UUID
    /// The saved session's account, read on the phone without the network. Nil when none is saved
    /// or it can't be read (before the first unlock).
    func storedUserID() -> UUID?
    /// The account requests go out as right now and the token they carry, refreshed first when it
    /// expires within `margin` seconds. Throws when it can't be refreshed (offline), so a sync keeps
    /// what's saved. A request that finds the token expired and can't refresh it still goes out,
    /// with the public key, so answers count only if the token is the same afterwards.
    func session(refreshingWithin margin: TimeInterval) async throws -> AccountSession
    /// Moves these flights (with their passes, reports, notifications and Live Activities) from the
    /// anonymous account `owner` this phone lost to the signed-in one, when `secret` matches the
    /// hash on that account's profile. Returns the ids the signed-in account owns afterwards. At
    /// most `adoptLimit` ids per call.
    func adoptFlights(_ ids: [UUID], from owner: UUID, secret: String) async throws -> Set<UUID>

    func flights() async throws -> [Flight]
    /// One flight, for its latest live status.
    func flight(_ id: UUID) async throws -> Flight
    func add(_ draft: FlightDraft) async throws -> Flight
    func update(_ id: UUID, _ draft: FlightDraft) async throws -> Flight
    func delete(_ id: UUID) async throws
    func latestForecast(for flightID: UUID) async throws -> Forecast?
    func updates(for flightID: UUID) async throws -> [FlightUpdate]

    /// Flight search (free): by number on a local date, or the nonstops on a route that day.
    func searchFlights(number: String, date: String) async throws -> FlightSearchResult
    func routeFlights(origin: String, destination: String, date: String) async throws -> FlightSearchResult

    func registerDevice(token: String, environment: String) async throws
    /// The Live Activity's push token, so wheels-up from the airline's data can re-time it.
    func registerLiveActivity(flightID: UUID, token: String, environment: String) async throws
    func endLiveActivity(flightID: UUID) async throws
    /// Returns what was saved: without the secret's hash on a database that has no column for it yet.
    @discardableResult func saveProfile(_ profile: ProfileRecord) async throws -> ProfileRecord

    func passFlightIDs() async throws -> Set<UUID>
    func recordPass(_ pass: FlightPassRecord) async throws

    func landingReports() async throws -> [LandingReport]
    /// `seatbeltMins`: minutes after takeoff the seatbelt sign was noted. `forecastIssuedAt`: the
    /// forecast the phone showed, so the rating is scored against it. Both are left out when nil.
    func submitLandingReport(
        flightID: UUID, rating: FeltRating, seatbeltMins: [Int]?, forecastIssuedAt: Date?
    ) async throws -> LandingReport
    func accuracyStats() async throws -> AccuracyStats?

    func waitlistCountries() async throws -> Set<String>
    func joinWaitlist(_ entry: WaitlistEntry) async throws

    func pilotReports(since: Date) async throws -> [PilotReport]
    func turbulenceGrids(levelFt: Int) async throws -> [TurbulenceGrid]
}

/// How many flights `adopt_flights` takes in one call.
let adoptLimit = 200

/// Who requests go out as, and with which access token.
struct AccountSession: Equatable, Sendable {
    let userID: UUID
    let accessToken: String
}

extension Error {
    /// Refused for the session, not the request: sent with the public key or an expired token
    /// (a refresh that failed on the way). The next sync, with a good session, sorts it out.
    var isSessionRefusal: Bool {
        if let error = self as? PostgrestError {
            return ["42501", "PGRST301", "PGRST302", "PGRST303"].contains(error.code ?? "")
        }
        if let error = self as? HTTPError { return error.response.statusCode == 401 }
        return false
    }
}

enum Services {
    /// Supabase when configured in Secrets.xcconfig, otherwise demo mode.
    static let flights: FlightService = {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
            // Development: `-demo` uses the bundled demo data even when Supabase is configured.
            if ProcessInfo.processInfo.arguments.contains("-demo") { return DemoFlightService() }
        #endif
        if let urlString = info["SupabaseURL"] as? String, let url = URL(string: urlString), url.host() != nil,
            let key = info["SupabaseAnonKey"] as? String, !key.isEmpty
        {
            let options = SupabaseClientOptions(
                // The saved session comes up at launch without first waiting on a refresh.
                auth: .init(emitLocalSessionAsInitialSession: true),
                global: .init(session: Services.session))
            return SupabaseFlightService(client: SupabaseClient(supabaseURL: url, supabaseKey: key, options: options))
        }
        return DemoFlightService()
    }()

    /// Plane and captive wifi often accept a connection and never answer. The SDK gives every
    /// request its own 60 s timeout and retries token refreshes, so each task is capped as a whole.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static var isDemo: Bool { flights is DemoFlightService }
}

struct SupabaseFlightService: FlightService {
    let client: SupabaseClient

    private static let flightColumns =
        "id,origin,destination,departure_at,notify,flight_number,airline_name,arrival_at,schedule_pending,status:flight_status(*)"
    private static let updateColumns = "id,flight_id,milestone,kind,grade,title,body,changes,pro_only,created_at"

    func signIn(allowSignUp: Bool) async throws -> UUID {
        // The saved session even when its token has expired: refreshes fail on planes and behind
        // captive portals, and signing up then would leave the saved flights behind (AC 1507).
        if let id = storedUserID() { return id }
        guard allowSignUp else { throw AuthError.sessionMissing }
        return try await client.auth.signInAnonymously().user.id
    }

    func storedUserID() -> UUID? { client.auth.currentSession?.user.id }

    func session(refreshingWithin margin: TimeInterval) async throws -> AccountSession {
        // Refreshes an expired one (the SDK's 30 s margin).
        var session = try await client.auth.session
        if session.expiresAt - Date.now.timeIntervalSince1970 < margin {
            if let latest = client.auth.currentSession, latest.expiresAt - Date.now.timeIntervalSince1970 >= margin {
                // Refreshed by another request meanwhile.
                session = latest
            } else {
                do {
                    // The stored refresh token, never an older one: a reused token can end the session.
                    session = try await client.auth.refreshSession()
                } catch where !session.isExpired && !(error is CancellationError) {
                    // Still good for now; the answers are checked against this token afterwards.
                }
            }
        }
        return AccountSession(userID: session.user.id, accessToken: session.accessToken)
    }

    func adoptFlights(_ ids: [UUID], from owner: UUID, secret: String) async throws -> Set<UUID> {
        struct Params: Encodable {
            let p_flight_ids: [UUID]
            let p_from_user: UUID
            let p_secret: String
        }
        let params = Params(p_flight_ids: ids, p_from_user: owner, p_secret: secret)
        let owned: [UUID] = try await client.rpc("adopt_flights", params: params).execute().value
        return Set(owned)
    }

    func flights() async throws -> [Flight] {
        try await client.from("flights").select(Self.flightColumns).order("departure_at").execute().value
    }

    func flight(_ id: UUID) async throws -> Flight {
        try await client.from("flights").select(Self.flightColumns).eq("id", value: id).single().execute().value
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

    func searchFlights(number: String, date: String) async throws -> FlightSearchResult {
        try await search(["number": number, "date": date])
    }

    func routeFlights(origin: String, destination: String, date: String) async throws -> FlightSearchResult {
        try await search(["origin": origin, "destination": destination, "date": date])
    }

    private func search(_ body: [String: String]) async throws -> FlightSearchResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            // Capped well under the SDK's 150 s, so a wifi that isn't answering offers airports soon.
            let result: FlightSearchResult = try await client.functions.invoke(
                "flight-search", options: FunctionInvokeOptions(body: body, timeoutInterval: 20), decoder: decoder)
            await Connectivity.shared.noteSuccess()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Offline, rate limited or failing: the sheet offers choosing airports instead. A
            // connection failure also tells the app it's offline, so the sheet says so.
            await Connectivity.shared.noteFailure(error)
            return .unavailable
        }
    }

    func registerDevice(token: String, environment: String) async throws {
        try await client.rpc("register_device", params: ["p_token": token, "p_environment": environment]).execute()
    }

    func registerLiveActivity(flightID: UUID, token: String, environment: String) async throws {
        try await client.rpc(
            "register_live_activity",
            params: ["p_flight_id": flightID.uuidString, "p_token": token, "p_environment": environment]
        ).execute()
    }

    func endLiveActivity(flightID: UUID) async throws {
        try await client.rpc("end_live_activity", params: ["p_flight_id": flightID.uuidString]).execute()
    }

    func saveProfile(_ profile: ProfileRecord) async throws -> ProfileRecord {
        do {
            try await client.from("profiles").upsert(profile, onConflict: "user_id").execute()
            return profile
        } catch let error as PostgrestError where error.code == "PGRST204" && profile.adoptSecretHash != nil {
            // A database without the secret's column yet: the rest still counts, and the hash is
            // sent again next time.
            var older = profile
            older.adoptSecretHash = nil
            try await client.from("profiles").upsert(older, onConflict: "user_id").execute()
            return older
        }
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

    func submitLandingReport(
        flightID: UUID, rating: FeltRating, seatbeltMins: [Int]?, forecastIssuedAt: Date?
    ) async throws -> LandingReport {
        // Optionals are left out of the body when nil (synthesized encodeIfPresent).
        struct Insert: Encodable {
            let flight_id: UUID
            let felt_relative: FeltRating
            let seatbelt_mins: [Int]?
            let forecast_issued_at: Date?
        }
        let insert = Insert(
            flight_id: flightID, felt_relative: rating,
            seatbelt_mins: seatbeltMins.flatMap { $0.isEmpty ? nil : $0 }, forecast_issued_at: forecastIssuedAt)
        do {
            return try await client.from("landing_reports")
                .insert(insert)
                .select(Self.reportColumns).single().execute().value
        } catch let error as PostgrestError where error.code == "PGRST204" {
            // A database without the newer columns yet: the rating itself still counts.
            guard insert.seatbelt_mins != nil || insert.forecast_issued_at != nil else { throw error }
            return try await client.from("landing_reports")
                .insert(Insert(flight_id: flightID, felt_relative: rating, seatbelt_mins: nil, forecast_issued_at: nil))
                .select(Self.reportColumns).single().execute().value
        }
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
        // The first flight is a numbered one with a 40-minute delay and a gate, for the status header.
        stored[0].flightNumber = "B6 23"
        stored[0].airlineName = "JetBlue"
        stored[0].arrivalAt = soon.addingTimeInterval(386 * 60)
        stored[0].status = Self.demoStatus(for: stored[0])
        // `-demoGlobal`: an outlook-only route with an official warning, for the global outlook (beta) screens.
        if ProcessInfo.processInfo.arguments.contains("-demoGlobal") {
            stored.append(Flight(id: UUID(), origin: "SBGR", destination: "LPPT", departureAt: soon.addingTimeInterval(2 * 3600)))
        }
    }

    static let sampleForecast: Forecast = load("sample_forecast")

    static func load(_ name: String) -> Forecast {
        let url = Bundle.main.url(forResource: name, withExtension: "json")!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var forecast = try! decoder.decode(Forecast.self, from: Data(contentsOf: url))
        forecast.issuedAt = forecast.issuedAt ?? .now
        return forecast
    }

    private static let demoUser = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!

    private enum DemoError: Error { case notFound }

    func signIn(allowSignUp: Bool) async throws -> UUID { Self.demoUser }
    nonisolated func storedUserID() -> UUID? { Self.demoUser }
    func session(refreshingWithin margin: TimeInterval) async throws -> AccountSession {
        AccountSession(userID: Self.demoUser, accessToken: "demo")
    }
    func adoptFlights(_ ids: [UUID], from owner: UUID, secret: String) async throws -> Set<UUID> { Set(ids) }

    func flights() async throws -> [Flight] { stored.sorted { $0.departureAt < $1.departureAt } }

    func flight(_ id: UUID) async throws -> Flight {
        guard let flight = stored.first(where: { $0.id == id }) else { throw DemoError.notFound }
        return flight
    }

    func add(_ draft: FlightDraft) async throws -> Flight {
        var flight = draft.asFlight
        flight.status = Self.demoStatus(for: flight)
        stored.append(flight)
        return flight
    }

    /// A 40-minute delay with a gate, for flights added by number within the live-status window.
    private static func demoStatus(for flight: Flight) -> FlightStatus? {
        guard flight.flightNumber != nil, !flight.schedulePending,
            flight.departureAt.timeIntervalSinceNow < Flight.forecastWindow
        else { return nil }
        let expected = flight.departureAt.addingTimeInterval(40 * 60)
        return FlightStatus(
            state: .delayed, live: true, departureScheduled: flight.departureAt, departureExpected: expected,
            arrivalScheduled: flight.arrivalAt, arrivalExpected: flight.arrivalAt?.addingTimeInterval(34 * 60),
            delayMin: 40, departureGate: "B22", departureTerminal: "5", arrivalTerminal: "5",
            checkedAt: .now.addingTimeInterval(-8 * 60), nextCheckAt: .now.addingTimeInterval(52 * 60))
    }

    func update(_ id: UUID, _ draft: FlightDraft) async throws -> Flight {
        var flight = draft.asFlight
        flight.id = id
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
            // Real worker output: JFK→LHR (confirmed over the US, outlook after) and GRU→LIS
            // (outlook only, with an official thunderstorm warning).
            let startsInUS = flight.originAirport.map {
                Coverage.latitude.contains($0.lat) && Coverage.longitude.contains($0.lon)
            } ?? false
            return Self.load(startsInUS ? "sample_partly_outlook" : "sample_global_outlook")
        }
        return Self.sampleForecast
    }

    func updates(for flightID: UUID) async throws -> [FlightUpdate] { [] }

    func searchFlights(number: String, date: String) async throws -> FlightSearchResult {
        try await Task.sleep(for: .milliseconds(600))
        guard let normalized = FlightNumber.normalize(number), let day = Self.day(date) else {
            return FlightSearchResult(state: .notFound, flights: [])
        }
        if day.timeIntervalSinceNow > 60 * 86400 { return FlightSearchResult(state: .notPublished, flights: []) }
        let legs = Self.demoRoutes.filter { $0.number == normalized }
        guard !legs.isEmpty else { return FlightSearchResult(state: .notFound, flights: []) }
        return FlightSearchResult(state: .found, flights: legs.map { $0.found(on: day) })
    }

    func routeFlights(origin: String, destination: String, date: String) async throws -> FlightSearchResult {
        try await Task.sleep(for: .milliseconds(600))
        guard let day = Self.day(date) else { return .unavailable }
        if day.timeIntervalSinceNow > 60 * 86400 { return FlightSearchResult(state: .notPublished, flights: []) }
        let flights = Self.demoRoutes.filter { $0.origin == origin && $0.destination == destination }.map { $0.found(on: day) }
        return FlightSearchResult(state: flights.isEmpty ? .notFound : .found, flights: flights.sorted { $0.departureAt < $1.departureAt })
    }

    /// Demo schedule: (number, airline, route, local departure hour/minute, minutes in the air).
    private struct DemoRoute {
        let number: String, airline: String, origin: String, destination: String
        let hour: Int, minute: Int, block: Int

        func found(on day: Date) -> FoundFlight {
            let tz = AirportStore.shared.airport(origin)?.timeZone ?? .current
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz
            let local = calendar.dateComponents([.year, .month, .day], from: day)
            let departure = calendar.date(from: DateComponents(
                year: local.year, month: local.month, day: local.day, hour: hour, minute: minute)) ?? day
            return FoundFlight(
                flightNumber: number, airlineName: airline, origin: origin, destination: destination,
                departureAt: departure, arrivalAt: departure.addingTimeInterval(TimeInterval(block * 60)))
        }
    }

    private static let demoRoutes: [DemoRoute] = [
        DemoRoute(number: "B6 23", airline: "JetBlue", origin: "KJFK", destination: "KLAX", hour: 7, minute: 15, block: 386),
        DemoRoute(number: "AA 1", airline: "American Airlines", origin: "KJFK", destination: "KLAX", hour: 8, minute: 0, block: 380),
        DemoRoute(number: "DL 423", airline: "Delta", origin: "KJFK", destination: "KLAX", hour: 13, minute: 30, block: 385),
        DemoRoute(number: "UA 2303", airline: "United", origin: "KJFK", destination: "KLAX", hour: 18, minute: 5, block: 390),
        DemoRoute(number: "UA 456", airline: "United", origin: "KDEN", destination: "KSFO", hour: 9, minute: 40, block: 150),
        DemoRoute(number: "B6 1023", airline: "JetBlue", origin: "KBOS", destination: "KJFK", hour: 5, minute: 30, block: 75),
        DemoRoute(number: "B6 1023", airline: "JetBlue", origin: "KJFK", destination: "KLAX", hour: 7, minute: 15, block: 386),
    ]

    /// "2026-10-22" as noon UTC, close enough to pick the local day anywhere in the US.
    private static func day(_ text: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: text)?.addingTimeInterval(12 * 3600)
    }

    func registerDevice(token: String, environment: String) async throws {}
    func registerLiveActivity(flightID: UUID, token: String, environment: String) async throws {}
    func endLiveActivity(flightID: UUID) async throws {}
    func saveProfile(_ profile: ProfileRecord) async throws -> ProfileRecord { profile }
    func passFlightIDs() async throws -> Set<UUID> { passes }
    func recordPass(_ pass: FlightPassRecord) async throws { passes.insert(pass.flightId) }
    func landingReports() async throws -> [LandingReport] { Array(reports.values) }

    func submitLandingReport(
        flightID: UUID, rating: FeltRating, seatbeltMins: [Int]?, forecastIssuedAt: Date?
    ) async throws -> LandingReport {
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
