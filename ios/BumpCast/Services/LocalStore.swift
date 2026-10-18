import Foundation

/// Everything the app needs to work without a connection, saved after each sync.
/// Forecasts are downloaded ahead of time, so they're on the phone before boarding.
struct Snapshot: Codable, Sendable {
    var flights: [Flight] = []
    var forecasts: [UUID: Forecast] = [:]
    var updates: [UUID: [FlightUpdate]] = [:]
    var passes: Set<UUID> = []
    var reports: [UUID: LandingReport] = [:]
    var waitlist: Set<String> = []
    var syncedAt: Date?
}

actor LocalStore {
    static let shared = LocalStore()

    private let url: URL

    init(directory: URL = URL.applicationSupportDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "snapshot.json")
    }

    nonisolated func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) {
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        // Complete-until-first-unlock so background refresh can write while the phone is locked.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
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
