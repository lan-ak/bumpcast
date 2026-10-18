import Foundation

/// A notification the worker sent about a flight: the "what changed" feed.
struct FlightUpdate: Codable, Hashable, Identifiable, Sendable {
    struct Change: Codable, Hashable, Sendable { let text: String }

    let id: UUID
    let flightId: UUID
    let milestone: String  // 48h | 24h | 6h | 2h | noaa
    let kind: String  // ready | update | confirmed
    let grade: Forecast.Grade?
    let title: String
    let body: String
    let changes: [Change]
    let proOnly: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, milestone, kind, grade, title, body, changes
        case flightId = "flight_id"
        case proOnly = "pro_only"
        case createdAt = "created_at"
    }
}

/// After-landing "How bumpy was it?" The forecast side is filled in by the database.
struct LandingReport: Codable, Hashable, Sendable {
    let flightId: UUID
    let felt: Severity
    let forecastWorst: Severity?
    let matched: Bool?

    enum CodingKeys: String, CodingKey {
        case felt, matched
        case flightId = "flight_id"
        case forecastWorst = "forecast_worst"
    }
}

struct AccuracyStats: Codable, Hashable, Sendable {
    let reports: Int
    let exact: Int
    let withinOne: Int
    let confirmedReports: Int
    let confirmedExact: Int

    enum CodingKeys: String, CodingKey {
        case reports, exact
        case withinOne = "within_one"
        case confirmedReports = "confirmed_reports"
        case confirmedExact = "confirmed_exact"
    }

    var exactPercent: Int? { reports > 0 ? Int((Double(exact) / Double(reports) * 100).rounded()) : nil }
    var withinOnePercent: Int? { reports > 0 ? Int((Double(withinOne) / Double(reports) * 100).rounded()) : nil }
}

/// A recent pilot report of turbulence (aviationweather.gov).
struct PilotReport: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let observedAt: Date
    let lat: Double
    let lon: Double
    let altitudeFt: Int?
    let intensity: Severity
    let aircraft: String?
    let raw: String?

    enum CodingKeys: String, CodingKey {
        case id, lat, lon, intensity, aircraft, raw
        case observedAt = "observed_at"
        case altitudeFt = "altitude_ft"
    }
}

/// One map layer: NOAA GTG turbulence at one height and time on a regular lat/lon grid.
struct TurbulenceGrid: Codable, Hashable, Sendable {
    let validAt: Date
    let levelFt: Int
    let cycle: Date
    let north: Double
    let west: Double
    let step: Double
    let ny: Int
    let nx: Int
    /// ny*nx characters from the north-west corner: "0"..."3" severity, "." no data.
    let cells: String

    enum CodingKeys: String, CodingKey {
        case north, west, step, ny, nx, cells
        case validAt = "valid_at"
        case levelFt = "level_ft"
        case cycle
    }

    /// Severity per cell, row-major from the north-west; nil where there's no data.
    func severities() -> [Severity?] {
        cells.utf8.map { byte in
            switch byte {
            case UInt8(ascii: "0"): .smooth
            case UInt8(ascii: "1"): .light
            case UInt8(ascii: "2"): .moderate
            case UInt8(ascii: "3"): .severe
            default: nil
            }
        }
    }
}

struct FlightPassRecord: Codable, Sendable {
    let transactionId: String
    let flightId: UUID
    let productId: String

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case flightId = "flight_id"
        case productId = "product_id"
    }
}

struct ProfileRecord: Codable, Sendable {
    let isPro: Bool
    let notificationsEnabled: Bool
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case timezone
        case isPro = "is_pro"
        case notificationsEnabled = "notifications_enabled"
    }
}

struct WaitlistEntry: Codable, Hashable, Sendable {
    let country: String
    let airport: String?
}
