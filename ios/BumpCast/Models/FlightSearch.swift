import Foundation

/// A flight found by number or on a route, from the flight-search function. The live fields say
/// whether it has left, taken off or landed; older versions of the function leave them out.
struct FoundFlight: Codable, Hashable, Identifiable, Sendable {
    let flightNumber: String  // "B6 23"
    let airlineName: String?
    let origin: String  // ICAO
    let destination: String  // ICAO
    let departureAt: Date
    let arrivalAt: Date?
    /// Off the gate (or later), by the airline's live status.
    var departed: Bool?
    /// Wheels-up: the airline's runway time, once it has passed.
    var takeoffAt: Date?
    /// Touchdown at the other end: the airline's runway time, once it has passed.
    var landedAt: Date?
    /// When it actually left the gate.
    var departureActual: Date?

    var id: String { "\(flightNumber)-\(origin)-\(departureAt.timeIntervalSince1970)" }

    enum CodingKeys: String, CodingKey {
        case origin, destination, departed
        case flightNumber = "flight_number"
        case airlineName = "airline_name"
        case departureAt = "departure_at"
        case arrivalAt = "arrival_at"
        case takeoffAt = "takeoff_at"
        case landedAt = "landed_at"
        case departureActual = "departure_actual"
    }

    var originAirport: Airport? { AirportStore.shared.airport(origin) }
    var destinationAirport: Airport? { AirportStore.shared.airport(destination) }

    /// The landing time, unless the live status says it hasn't left the gate: an arrival runway
    /// time can be an estimate that didn't move with a delay.
    var landed: Date? { departed == false ? nil : landedAt }

    /// "B6 23 · JetBlue"
    var title: String { airlineName.map { "\(flightNumber) · \($0)" } ?? flightNumber }

    /// On the ground at the other end, so it can no longer be added: by its live status, else by
    /// the clock (the arrival, or 6 hours after departure without one, moved by any delay we know
    /// of). Until then it can be added, even in the air.
    func hasLanded(now: Date = .now) -> Bool {
        if landed != nil { return true }
        // Still at the gate, a delay can run past the scheduled arrival.
        let delay: TimeInterval = departed == false
            ? 6 * 3600 : departureActual.map { max(0, $0.timeIntervalSince(departureAt)) } ?? 0
        return (arrivalAt ?? departureAt.addingTimeInterval(6 * 3600)).addingTimeInterval(delay) <= now
    }

    /// Left and not landed yet: by its live status, else by the clock (the usual taxi out).
    func isInAir(now: Date = .now) -> Bool {
        guard !hasLanded(now: now) else { return false }
        return takeoffAt != nil || (departed ?? (departureAt.addingTimeInterval(Forecast.taxiOut) <= now))
    }

    /// Both airports are ones we know, so it can be saved and forecast.
    var hasKnownAirports: Bool { originAirport != nil && destinationAirport != nil }

    /// Whether yesterday's flight with this number could still be flying, given today's: a search
    /// for today only lists flights leaving today, so just after midnight it shows tonight's
    /// flight instead of the overnight one they're on. Never when one of today's is in the air
    /// already; always when today has none; otherwise when today's schedule, a day earlier and
    /// with a few hours for a delay, would still be in the air.
    static func mayStillFlyFromYesterday(_ today: [FoundFlight], now: Date = .now) -> Bool {
        guard !today.contains(where: { $0.isInAir(now: now) }) else { return false }
        guard !today.isEmpty else { return true }
        return today.contains {
            ($0.arrivalAt ?? $0.departureAt.addingTimeInterval(6 * 3600)).addingTimeInterval(-24 * 3600 + 3 * 3600) > now
        }
    }

    /// Yesterday's legs that can still be added: the ones not landed yet. Usually in the air (or
    /// late at the gate); with the phone on another time zone than the airport, "yesterday" can
    /// even be a flight that hasn't left.
    static func stillFlying(_ yesterday: [FoundFlight], now: Date = .now) -> [FoundFlight] {
        yesterday.filter { !$0.hasLanded(now: now) }
    }
}

struct FlightSearchResult: Codable, Equatable, Sendable {
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

    /// "7:15 AM EDT", or "Sat 6:40 AM PDT" with the day.
    func localTimeWithZone(in tz: TimeZone, withDay: Bool = false) -> String {
        "\(localTime(in: tz, withDay: withDay)) \(tz.abbreviation(for: self) ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// "Today", "Tomorrow" or "Fri, Oct 23": the local day at an airport.
    func relativeDay(in tz: TimeZone, now: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        switch calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: self)).day {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated).month(.abbreviated).day())
        }
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
