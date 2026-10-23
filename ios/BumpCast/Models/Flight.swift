import Foundation

struct Flight: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var origin: String  // ICAO
    var destination: String  // ICAO
    var departureAt: Date  // scheduled departure, UTC
    /// "Tell me when it's ready or changes" for this flight.
    var notify: Bool = true
    /// From flight search, e.g. "B6 23". Flights added by airport have none.
    var flightNumber: String?
    var airlineName: String?
    /// Scheduled arrival, when the flight came from search.
    var arrivalAt: Date?
    /// Saved by number before the airline published this date; the times are the user's for now.
    var schedulePending: Bool = false
    /// Live status, written by the worker for every flight with a number.
    var status: FlightStatus?

    enum CodingKeys: String, CodingKey {
        case id, origin, destination, notify, status
        case departureAt = "departure_at"
        case flightNumber = "flight_number"
        case airlineName = "airline_name"
        case arrivalAt = "arrival_at"
        case schedulePending = "schedule_pending"
    }

    init(
        id: UUID, origin: String, destination: String, departureAt: Date, notify: Bool = true,
        flightNumber: String? = nil, airlineName: String? = nil, arrivalAt: Date? = nil,
        schedulePending: Bool = false, status: FlightStatus? = nil
    ) {
        self.id = id
        self.origin = origin
        self.destination = destination
        self.departureAt = departureAt
        self.notify = notify
        self.flightNumber = flightNumber
        self.airlineName = airlineName
        self.arrivalAt = arrivalAt
        self.schedulePending = schedulePending
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        origin = try c.decode(String.self, forKey: .origin)
        destination = try c.decode(String.self, forKey: .destination)
        departureAt = try c.decode(Date.self, forKey: .departureAt)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        flightNumber = try c.decodeIfPresent(String.self, forKey: .flightNumber)
        airlineName = try c.decodeIfPresent(String.self, forKey: .airlineName)
        arrivalAt = try c.decodeIfPresent(Date.self, forKey: .arrivalAt)
        schedulePending = try c.decodeIfPresent(Bool.self, forKey: .schedulePending) ?? false
        status = try? c.decodeIfPresent(FlightStatus.self, forKey: .status)
    }

    /// When the flight actually leaves, as far as we know: actual, then expected, then scheduled.
    /// Only flights with live status have one that differs from the schedule.
    var expectedDeparture: Date { status?.liveDeparture ?? departureAt }

    var originAirport: Airport? { AirportStore.shared.airport(origin) }
    var destinationAirport: Airport? { AirportStore.shared.airport(destination) }

    /// Forecasts unlock 48 hours before departure.
    static let forecastWindow: TimeInterval = 48 * 3600

    var forecastUnlocksAt: Date { departureAt.addingTimeInterval(-Self.forecastWindow) }

    /// Wheels-up the airline reported: a runway time that has passed. Rows the worker wrote before
    /// it stored runway times only can hold a guess in the future, which doesn't count.
    var reportedTakeoff: Date? { status?.takeoffAt.flatMap { $0 <= .now ? $0 : nil } }

    /// The plane has left: the airline reported wheels-up, or that it departed.
    var isAirborne: Bool { reportedTakeoff != nil || status?.state == .departed }

    /// The reported wheels-up, else the worker's assumption: wheels up 15 minutes after departure.
    /// Follows delays, like the forecast does.
    var estimatedTakeoff: Date { reportedTakeoff ?? expectedDeparture.addingTimeInterval(Forecast.taxiOut) }

    /// Landing from the forecast's flight time, or a rough great-circle estimate before there is one.
    func estimatedLanding(_ forecast: Forecast?) -> Date {
        if let minutes = forecast?.durationMin {
            return estimatedTakeoff.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return estimatedTakeoff.addingTimeInterval(estimatedAirMinutes * 60)
    }

    /// Air time at ~460 kt plus ~20 minutes: the worker's still-air profile (route.py) within ~2% from 200 to 8,000 nm.
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

    /// "B6 23 · JFK → LAX", or just the route for flights added by airport.
    var titleText: String {
        flightNumber.map { "\($0) · \(routeText)" } ?? routeText
    }
}

/// The latest live status the worker stored for a flight.
struct FlightStatus: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case scheduled, delayed, departed, cancelled, diverted
    }

    var state: State?
    var live: Bool = false
    var departureScheduled: Date?
    var departureExpected: Date?
    var departureActual: Date?
    var arrivalScheduled: Date?
    var arrivalExpected: Date?
    var arrivalActual: Date?
    var delayMin: Int?
    var departureGate: String?
    var departureTerminal: String?
    var arrivalTerminal: String?
    var divertedTo: String?
    var checkedAt: Date
    var nextCheckAt: Date?
    var finished: Bool = false
    /// Wheels-up from the airline's runway time. Nil until it left. Older rows may hold a guess
    /// (gate time plus taxi), so read it through `Flight.reportedTakeoff`.
    var takeoffAt: Date?

    enum CodingKeys: String, CodingKey {
        case live, finished
        case takeoffAt = "takeoff_at"
        case state = "status"
        case departureScheduled = "departure_scheduled"
        case departureExpected = "departure_expected"
        case departureActual = "departure_actual"
        case arrivalScheduled = "arrival_scheduled"
        case arrivalExpected = "arrival_expected"
        case arrivalActual = "arrival_actual"
        case delayMin = "delay_min"
        case departureGate = "departure_gate"
        case departureTerminal = "departure_terminal"
        case arrivalTerminal = "arrival_terminal"
        case divertedTo = "diverted_to"
        case checkedAt = "checked_at"
        case nextCheckAt = "next_check_at"
    }

    /// A status with live times, as opposed to a row that only records schedule checks.
    var hasStatus: Bool { state != nil }

    var liveDeparture: Date? { hasStatus ? (departureActual ?? departureExpected) : nil }
}

/// Fields the app sends when creating or editing a flight. New flights carry a client-made id,
/// so one saved offline keeps the same id once it syncs.
struct FlightDraft: Codable, Hashable, Sendable {
    var id: UUID?
    var origin: String
    var destination: String
    var departureAt: Date
    var notify: Bool = true
    var flightNumber: String? = nil
    var airlineName: String? = nil
    var arrivalAt: Date? = nil
    var schedulePending: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, origin, destination, notify
        case departureAt = "departure_at"
        case flightNumber = "flight_number"
        case airlineName = "airline_name"
        case arrivalAt = "arrival_at"
        case schedulePending = "schedule_pending"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(origin, forKey: .origin)
        try c.encode(destination, forKey: .destination)
        try c.encode(departureAt, forKey: .departureAt)
        try c.encode(notify, forKey: .notify)
        // Explicit nulls, so an edit that drops the flight number clears it.
        try c.encode(flightNumber, forKey: .flightNumber)
        try c.encode(airlineName, forKey: .airlineName)
        try c.encode(arrivalAt, forKey: .arrivalAt)
        try c.encode(schedulePending, forKey: .schedulePending)
    }

    var asFlight: Flight {
        Flight(
            id: id ?? UUID(), origin: origin, destination: destination, departureAt: departureAt, notify: notify,
            flightNumber: flightNumber, airlineName: airlineName, arrivalAt: arrivalAt, schedulePending: schedulePending)
    }
}

extension FlightDraft {
    /// The same flight, to save again (e.g. under another account).
    init(_ flight: Flight) {
        self.init(
            id: flight.id, origin: flight.origin, destination: flight.destination, departureAt: flight.departureAt,
            notify: flight.notify, flightNumber: flight.flightNumber, airlineName: flight.airlineName,
            arrivalAt: flight.arrivalAt, schedulePending: flight.schedulePending)
    }
}
