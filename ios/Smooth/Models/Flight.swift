import Foundation

struct Flight: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var origin: String  // ICAO
    var destination: String  // ICAO
    var departureAt: Date  // scheduled departure, UTC

    enum CodingKeys: String, CodingKey {
        case id, origin, destination
        case departureAt = "departure_at"
    }

    var originAirport: Airport? { AirportStore.shared.airport(origin) }
    var destinationAirport: Airport? { AirportStore.shared.airport(destination) }

    /// Forecasts unlock 48 hours before departure.
    static let forecastWindow: TimeInterval = 48 * 3600

    var forecastUnlocksAt: Date { departureAt.addingTimeInterval(-Self.forecastWindow) }
}

/// Fields the app sends when creating or editing a flight.
struct FlightDraft: Codable, Sendable {
    var origin: String
    var destination: String
    var departureAt: Date

    enum CodingKeys: String, CodingKey {
        case origin, destination
        case departureAt = "departure_at"
    }
}
