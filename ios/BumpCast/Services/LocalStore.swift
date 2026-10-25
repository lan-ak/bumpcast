import Foundation

/// Everything the app needs to work without a connection, saved after each sync.
/// Forecasts are downloaded ahead of time, so they're on the phone before boarding.
/// Fields added later are Optional: synthesized decoding ignores default values, so a
/// non-Optional addition would make every snapshot saved by an older build unreadable.
struct Snapshot: Codable, Sendable {
    var flights: [Flight] = []
    var forecasts: [UUID: Forecast] = [:]
    var updates: [UUID: [FlightUpdate]] = [:]
    var passes: Set<UUID> = []
    var reports: [UUID: LandingReport] = [:]
    var waitlist: Set<String> = []
    var syncedAt: Date?
    /// Flights added while offline, saved to the server on the next sync.
    var pendingAdds: [FlightDraft]? = nil
    /// The account these flights belong to (nil in snapshots saved before this build).
    var userID: UUID? = nil
    /// Flight passes bought while the server couldn't be reached, saved on the next sync.
    var pendingPasses: [FlightPassRecord]? = nil
    /// Landing ratings given offline, sent on the next sync.
    var pendingReports: [PendingLandingReport]? = nil
    /// Accounts the flights were still moving from when a move failed: tried again on the next sign-in.
    var previousOwners: [UUID]? = nil
    /// Flights saved again under new ids that brought their forecast, kept until the server has one.
    var carriedForecasts: Set<UUID>? = nil
    /// Flights saved again under new ids whose pass stayed with the lost account: still unlocked here.
    var carriedPasses: Set<UUID>? = nil
    /// This install's secret. Its hash on the account's profile lets a later account on this phone
    /// take the flights over; it's kept here, not only in the keychain, which may be what was lost.
    var adoptSecret: String? = nil
    /// Flights deleted here that the server may still have (an add whose answer was lost), deleted
    /// there on the next sync.
    var pendingDeletes: Set<UUID>? = nil
}

/// The turbulence map's layers by height, saved so the map opens offline.
struct MapSnapshot: Codable, Sendable {
    var grids: [Int: [TurbulenceGrid]]
    var savedAt: Date
}

actor LocalStore {
    /// Demo mode saves apart: its sample flights belong to no account, so saved where the live app
    /// looks, the next live launch would save them again under the phone's account.
    static let shared = LocalStore(
        directory: Services.isDemo ? URL.applicationSupportDirectory.appending(path: "Demo") : .applicationSupportDirectory)

    private let url: URL
    private let mapURL: URL

    init(directory: URL = URL.applicationSupportDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "snapshot.json")
        mapURL = directory.appending(path: "map.json")
    }

    /// Nil when there's none, and also when it can't be read yet (before the first unlock) or is damaged.
    nonisolated func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Snapshot.self, from: data)
    }

    /// Whether a snapshot file exists, readable or not (before the first unlock it can't be read).
    nonisolated var hasSnapshot: Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    func save(_ snapshot: Snapshot) {
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        // Complete-until-first-unlock so background refresh can write while the phone is locked.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    nonisolated func loadMap() -> MapSnapshot? {
        guard let data = try? Data(contentsOf: mapURL) else { return nil }
        return try? Self.decoder.decode(MapSnapshot.self, from: data)
    }

    /// About 1 MB with every level, so save it only when the grids change.
    func saveMap(_ map: MapSnapshot) {
        guard let data = try? Self.encoder.encode(map) else { return }
        try? data.write(to: mapURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: mapURL)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
