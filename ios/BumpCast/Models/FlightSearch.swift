import Foundation

/// A flight found by number or on a route, from the flight-search function.
struct FoundFlight: Codable, Hashable, Identifiable, Sendable {
    let flightNumber: String  // "B6 23"
    let airlineName: String?
    let origin: String  // ICAO
    let destination: String  // ICAO
    let departureAt: Date
    let arrivalAt: Date?

    var id: String { "\(flightNumber)-\(origin)-\(departureAt.timeIntervalSince1970)" }

    enum CodingKeys: String, CodingKey {
        case origin, destination
        case flightNumber = "flight_number"
        case airlineName = "airline_name"
        case departureAt = "departure_at"
        case arrivalAt = "arrival_at"
    }

    var originAirport: Airport? { AirportStore.shared.airport(origin) }
    var destinationAirport: Airport? { AirportStore.shared.airport(destination) }

    /// "B6 23 · JetBlue"
    var title: String { airlineName.map { "\(flightNumber) · \($0)" } ?? flightNumber }
}

struct FlightSearchResult: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case found
        case notFound = "not_found"
        /// Too far ahead: the airline hasn't published this date yet.
        case notPublished = "not_published"
        /// No flights listed for this airport.
        case noSchedule = "no_schedule"
        case unavailable
    }

    let state: State
    let flights: [FoundFlight]

    static let unavailable = FlightSearchResult(state: .unavailable, flights: [])
}

enum FlightNumber {
    /// "b6 23", "B6-023", "jbu23" -> "B6 23", "B6 23", "JBU 23". Matches the worker and search function.
    static func normalize(_ text: String) -> String? {
        let compact = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard let match = compact.wholeMatch(of: /([A-Z]{3}|[A-Z0-9]{2})(\d{1,4})([A-Z]?)/),
            match.1.contains(where: \.isLetter), let number = Int(match.2)
        else { return nil }
        return "\(match.1) \(number)\(match.3)"
    }
}

extension Date {
    /// "7:15 AM", or "Fri 6:40 AM" with the day, in an airport's time zone.
    func localTime(in tz: TimeZone, withDay: Bool = false) -> String {
        var style = Date.FormatStyle(timeZone: tz).hour().minute()
        if withDay { style = style.weekday(.abbreviated) }
        return formatted(style)
    }

    /// "7:15 AM EDT"
    func localTimeWithZone(in tz: TimeZone) -> String {
        "\(localTime(in: tz)) \(tz.abbreviation(for: self) ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// The local calendar day as a comparable number, e.g. 20261022.
    func localDay(in tz: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let c = calendar.dateComponents([.year, .month, .day], from: self)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// "2026-10-22" in an airport's time zone, for flight search.
    func searchDay(in tz: TimeZone) -> String {
        let n = localDay(in: tz)
        return String(format: "%04d-%02d-%02d", n / 10000, n / 100 % 100, n % 100)
    }
}
