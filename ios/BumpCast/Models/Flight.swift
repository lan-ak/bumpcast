import Foundation

struct Flight: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var origin: String  // ICAO
    var destination: String  // ICAO
    var departureAt: Date  // scheduled departure, UTC
    /// "Tell me when it's ready or changes" for this flight.
    var notify: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, origin, destination, notify
        case departureAt = "departure_at"
    }

    init(id: UUID, origin: String, destination: String, departureAt: Date, notify: Bool = true) {
        self.id = id
        self.origin = origin
        self.destination = destination
        self.departureAt = departureAt
        self.notify = notify
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        origin = try c.decode(String.self, forKey: .origin)
        destination = try c.decode(String.self, forKey: .destination)
        departureAt = try c.decode(Date.self, forKey: .departureAt)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
    }

    var originAirport: Airport? { AirportStore.shared.airport(origin) }
    var destinationAirport: Airport? { AirportStore.shared.airport(destination) }

    /// Forecasts unlock 48 hours before departure.
    static let forecastWindow: TimeInterval = 48 * 3600

    var forecastUnlocksAt: Date { departureAt.addingTimeInterval(-Self.forecastWindow) }

    /// Matches the worker's assumption: wheels up 15 minutes after scheduled departure.
    var estimatedTakeoff: Date { departureAt.addingTimeInterval(Forecast.taxiOut) }

    /// Landing from the forecast's flight time, or a rough great-circle estimate before there is one.
    func estimatedLanding(_ forecast: Forecast?) -> Date {
        if let minutes = forecast?.durationMin {
            return estimatedTakeoff.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return estimatedTakeoff.addingTimeInterval(estimatedAirMinutes * 60)
    }

    /// Air time at ~460 kt cruise plus ~20 minutes for climb and descent.
    var estimatedAirMinutes: Double {
        guard let a = originAirport, let b = destinationAirport else { return 120 }
        let rad = Double.pi / 180
        let h = pow(sin((b.lat - a.lat) * rad / 2), 2)
            + cos(a.lat * rad) * cos(b.lat * rad) * pow(sin((b.lon - a.lon) * rad / 2), 2)
        let nm = 2 * 3440.065 * asin(sqrt(h))
        return nm / 460 * 60 + 20
    }

    var routeText: String {
        "\(originAirport?.iata ?? origin) → \(destinationAirport?.iata ?? destination)"
    }
}

/// Fields the app sends when creating or editing a flight. New flights carry a client-made id,
/// so one saved offline keeps the same id once it syncs.
struct FlightDraft: Codable, Sendable {
    var id: UUID?
    var origin: String
    var destination: String
    var departureAt: Date
    var notify: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, origin, destination, notify
        case departureAt = "departure_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(origin, forKey: .origin)
        try c.encode(destination, forKey: .destination)
        try c.encode(departureAt, forKey: .departureAt)
        try c.encode(notify, forKey: .notify)
    }

    var asFlight: Flight {
        Flight(id: id ?? UUID(), origin: origin, destination: destination, departureAt: departureAt, notify: notify)
    }
}
