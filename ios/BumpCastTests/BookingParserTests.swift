import Foundation
import Testing

@testable import BumpCast

/// Booking emails read on the phone: schema.org first (JSON-LD, microdata), then the text
/// fallback. Synthetic fixtures only: made-up names, references and flights.
struct BookingParserTests {
    /// Oct 27, 2026, noon UTC.
    let now = Date(timeIntervalSince1970: 1_793_102_400)
    let utc = TimeZone(identifier: "UTC")!
    let airports: Set<String> = ["JFK", "LAX", "YYZ", "YVR", "SFO", "LHR", "EWR", "BOS", "YUL", "YTZ"]

    private func parse(subject: String = "Your trip", html: String? = nil, text: String? = nil) -> [BookingCandidate] {
        let message = MailMessage(id: "m1", subject: subject, html: html, text: text, received: now)
        return BookingParser.candidates(in: message, now: now, timeZone: utc, salt: "test-salt") { airports.contains($0) }
    }

    private func page(_ json: String) -> String {
        "<html><head><script type=\"application/ld+json\">\(json)</script></head><body>Thanks for booking.</body></html>"
    }

    private func leg(_ number: String, _ airline: String, _ from: String, _ to: String, _ departs: String) -> String {
        """
        {"@type":"Flight","flightNumber":"\(number)","airline":{"@type":"Airline","iataCode":"\(airline)"},
         "departureAirport":{"@type":"Airport","iataCode":"\(from)"},"arrivalAirport":{"@type":"Airport","iataCode":"\(to)"},
         "departureTime":"\(departs)"}
        """
    }

    @Test func jsonLDSingleFlight() {
        let json = """
            {"@context":"http://schema.org","@type":"FlightReservation","reservationNumber":"QX7K2M",
             "reservationStatus":"http://schema.org/ReservationConfirmed","underName":{"@type":"Person","name":"Sam Sample"},
             "reservationFor":\(leg("23", "B6", "JFK", "LAX", "2026-11-12T07:15:00-05:00"))}
            """
        let found = parse(html: page(json))
        #expect(found.count == 1)
        let flight = found[0]
        #expect(flight.number == "B6 23")
        #expect(flight.day == "2026-11-12")
        #expect(flight.time == "07:15")
        #expect(flight.origin == "JFK")
        #expect(flight.destination == "LAX")
        #expect(!flight.cancelled)
        // A salted hash, never the reference.
        #expect(flight.bookingHash == BookingParser.hash("QX7K2M", salt: "test-salt"))
        #expect(flight.bookingHash?.contains("QX7K2M") == false)
        #expect(flight.bookingHash?.count == 64)
    }

    @Test func localDateIsKeptNotConvertedToUTC() {
        // 11:30 PM in Vancouver is already the next day in UTC: the day stays the airport's own.
        let json = """
            {"@type":"FlightReservation","reservationFor":\(leg("AC 1507", "AC", "YVR", "YYZ", "2026-11-20T23:30:00-08:00"))}
            """
        let found = parse(html: page(json))
        #expect(found.map(\.day) == ["2026-11-20"])
        #expect(found.first?.number == "AC 1507")
    }

    @Test func jsonLDMultiLegArray() {
        let json = """
            [{"@type":"FlightReservation","reservationNumber":"ZZ9PLR","reservationFor":\(leg("110", "UA", "SFO", "EWR", "2026-12-03T08:00:00-08:00"))},
             {"@type":"FlightReservation","reservationNumber":"ZZ9PLR","reservationFor":\(leg("0016", "UA", "EWR", "LHR", "2026-12-03T18:45:00-05:00"))},
             {"@type":"FlightReservation","reservationNumber":"ZZ9PLR","reservationFor":\(leg("15", "UA", "LHR", "EWR", "2026-12-14T09:10:00+00:00"))}]
            """
        let found = parse(html: page(json))
        #expect(found.map(\.number) == ["UA 110", "UA 16", "UA 15"])
        #expect(found.map(\.day) == ["2026-12-03", "2026-12-03", "2026-12-14"])
        #expect(found.map { $0.origin ?? "" } == ["SFO", "EWR", "LHR"])
        // The legs of one booking share its hash.
        #expect(Set(found.compactMap(\.bookingHash)).count == 1)
    }

    @Test func jsonLDGraph() {
        let json = """
            {"@context":"https://schema.org","@graph":[
              {"@type":"Organization","name":"Sample Travel"},
              {"@type":"FlightReservation","reservationFor":\(leg("1234", "DL", "BOS", "LAX", "2027-01-08T06:00:00-05:00"))}]}
            """
        let found = parse(html: page(json))
        #expect(found.map(\.number) == ["DL 1234"])
        #expect(found.first?.day == "2027-01-08")
    }

    @Test func microdata() {
        let html = """
            <div itemscope itemtype="http://schema.org/FlightReservation">
              <meta itemprop="reservationNumber" content="RXJ34P"/>
              <link itemprop="reservationStatus" href="http://schema.org/Confirmed"/>
              <div itemprop="underName" itemscope itemtype="http://schema.org/Person">
                <meta itemprop="name" content="Alex Example"/>
              </div>
              <div itemprop="reservationFor" itemscope itemtype="http://schema.org/Flight">
                <meta itemprop="flightNumber" content="573"/>
                <div itemprop="airline" itemscope itemtype="http://schema.org/Airline">
                  <meta itemprop="name" content="Sample Air"/>
                  <meta itemprop="iataCode" content="UA"/>
                </div>
                <div itemprop="departureAirport" itemscope itemtype="http://schema.org/Airport">
                  <meta itemprop="iataCode" content="SFO"/>
                </div>
                <meta itemprop="departureTime" content="2026-11-30T20:15:00-08:00"/>
                <div itemprop="arrivalAirport" itemscope itemtype="http://schema.org/Airport">
                  <meta itemprop="iataCode" content="JFK"/>
                </div>
              </div>
            </div>
            <p>Gate B6 opens 45 minutes before departure.</p>
            """
        let found = parse(html: html)
        #expect(found.count == 1)
        #expect(found.first?.number == "UA 573")
        #expect(found.first?.day == "2026-11-30")
        #expect(found.first?.time == "20:15")
        #expect(found.first?.origin == "SFO")
        #expect(found.first?.destination == "JFK")
        #expect(found.first?.bookingHash == BookingParser.hash("RXJ34P", salt: "test-salt"))
    }

    @Test func cancelledReservation() {
        let json = """
            {"@type":"FlightReservation","reservationStatus":"http://schema.org/ReservationCancelled",
             "reservationFor":\(leg("23", "B6", "JFK", "LAX", "2026-11-12T07:15:00-05:00"))}
            """
        let found = parse(subject: "Your trip has changed", html: page(json))
        #expect(found.count == 1)
        #expect(found.first?.cancelled == true)
    }

    @Test func plainTextConfirmation() {
        let text = """
            Your booking is confirmed
            Confirmation code: K7QX2M

            Thursday, November 12, 2026
            Flight B6 23  JFK → LAX
            Departs 7:15 AM  Arrives 10:41 AM
            Terminal 5, Gate B6. Seat 23A.

            Sunday, November 22, 2026
            Flight B6 24  LAX → JFK
            Departs 9:30 AM
            """
        let found = parse(subject: "Booking confirmation", text: text)
        #expect(found.map(\.number) == ["B6 23", "B6 24"])
        #expect(found.map(\.day) == ["2026-11-12", "2026-11-22"])
        #expect(found.first?.origin == "JFK")
        #expect(found.first?.destination == "LAX")
        #expect(found.last?.origin == "LAX")
        #expect(found.allSatisfy { !$0.cancelled })
        #expect(found.first?.bookingHash == BookingParser.hash("K7QX2M", salt: "test-salt"))
    }

    @Test func htmlBodyWithoutSchemaFallsBackToText() {
        let html = """
            <html><body><table><tr><td>Flt</td><td>AC 1507</td></tr>
            <tr><td>Date</td><td>Dec 5, 2026</td></tr><tr><td>Route</td><td>Toronto (YYZ) to Vancouver (YVR)</td></tr>
            </table></body></html>
            """
        let found = parse(html: html)
        #expect(found.map(\.number) == ["AC 1507"])
        #expect(found.first?.day == "2026-12-05")
        #expect(found.first?.origin == "YYZ")
        #expect(found.first?.destination == "YVR")
    }

    /// Air Canada's layout, forwarded from a phone: every line padded by ~100 spaces, the date in
    /// a "FLIGHT 1 •" header, airports as "City CODE", times above, and the number after them
    /// with "• Operated by". Made-up passenger and reference.
    @Test func paddedItineraryLayoutAsForwarded() {
        let pad = String(repeating: " ", count: 100)
        let lines = [
            "Sent from my phone",
            "-------- Original message --------From: Airline <notify@example.com> Date: 2026-10-27 15:25 (GMT-05:00)",
            "Booking Confirmation", "ZZ9Q11", "Issued 27 Oct, 2026",
            "Flights",
            "FLIGHT 1 • Thu 19 Nov, 2026", "Economy Standard",
            "Toronto YYZ", "Montréal YUL", "12:00", "13:25",
            "Toronto-Pearson International Airport Terminal 1", "Montréal-Trudeau International Airport",
            "AC 410 • Operated by Air Canada", "Aircraft type: Airbus A320-200", "Duration: 1hr 25m",
            "FLIGHT 2 • Fri 20 Nov, 2026", "Economy Standard",
            "Montréal YUL", "Toronto YTZ", "08:45", "10:10",
            "Montréal-Trudeau International Airport", "Billy Bishop Toronto City Airport",
            "AC 7955 • Operated by Air Canada Express - Jazz", "Aircraft type: De Havilland Dash 8-400",
            "Passengers", "Sam Sample", "Ticket #: 0000000000000",
            "Harmonized Sales Tax - Canada - 100000000 RT0001",
        ]
        let text = lines.map { pad + $0 }.joined(separator: "\n\n")
        let found = parse(subject: "FW: Air Canada - 19 Nov 2026: Toronto - Montréal (Booking reference: ZZ9Q11)", text: text)
        #expect(found.map(\.number) == ["AC 410", "AC 7955"])
        #expect(found.map(\.day) == ["2026-11-19", "2026-11-20"])
        #expect(found.first?.origin == "YYZ")
        #expect(found.first?.destination == "YUL")
        #expect(found.last?.origin == "YUL")
        #expect(found.last?.destination == "YTZ")
    }

    @Test func gateSeatTerminalAndCodesAreNotFlights() {
        let text = """
            Boarding pass for November 12, 2026, 7:15 AM.
            Gate B6 12, Seat 23A, Terminal T5 2, Row 23.
            Confirmation ABC123. Booking reference XY 4521.
            """
        #expect(parse(text: text).isEmpty)
    }

    @Test func pastDatesAndFarFutureAreDropped() {
        let json = """
            [{"@type":"FlightReservation","reservationFor":\(leg("23", "B6", "JFK", "LAX", "2026-10-20T07:15:00-04:00"))},
             {"@type":"FlightReservation","reservationFor":\(leg("24", "B6", "LAX", "JFK", "2027-11-01T07:15:00-07:00"))},
             {"@type":"FlightReservation","reservationFor":\(leg("25", "B6", "JFK", "BOS", "2026-10-27T18:00:00-04:00"))}]
            """
        // Last week's flight and one more than 330 days out go; today's stays.
        #expect(parse(html: page(json)).map(\.number) == ["B6 25"])
    }

    @Test func repeatsAreDeduped() {
        let json = """
            [{"@type":"FlightReservation","reservationFor":\(leg("23", "B6", "JFK", "LAX", "2026-11-12T07:15:00-05:00"))},
             {"@type":"FlightReservation","reservationFor":{"flightNumber":"B6023","departureTime":"2026-11-12T07:15:00-05:00"}}]
            """
        #expect(parse(html: page(json)).count == 1)
    }

    @Test func pickPrefersTheBookedLeg() {
        let day = Date(timeIntervalSince1970: 1_794_000_000)
        let first = FoundFlight(
            flightNumber: "WN 100", airlineName: nil, origin: "KBOS", destination: "KJFK", departureAt: day, arrivalAt: nil)
        let second = FoundFlight(
            flightNumber: "WN 100", airlineName: nil, origin: "KJFK", destination: "KLAX",
            departureAt: day.addingTimeInterval(3 * 3600), arrivalAt: nil)
        let candidate = BookingCandidate(number: "WN 100", day: "2026-11-05", origin: "JFK")
        #expect(EmailImport.pick([first, second], for: candidate) == second)
        // Several legs and no hint: no guess.
        #expect(EmailImport.pick([first, second], for: BookingCandidate(number: "WN 100", day: "2026-11-05")) == nil)
        #expect(EmailImport.pick([first], for: BookingCandidate(number: "WN 100", day: "2026-11-05")) == first)
    }
}
