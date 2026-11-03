import Foundation
import Testing

@testable import BumpCast

/// Revision 2's rules for what an email does to saved flights: which booking replaces a flight in
/// place, what goes to Needs you, and the bookkeeping behind cancellations and Undo.
struct EmailImportTests {
    /// On a whole minute, a week ahead.
    let departure = Date(timeIntervalSince1970: ((Date.now.timeIntervalSince1970 / 60).rounded() * 60) + 7 * 86400)

    private func found(_ number: String, _ origin: String, _ destination: String, hours: Double = 0) -> FoundFlight {
        FoundFlight(
            flightNumber: number, airlineName: nil, origin: origin, destination: destination,
            departureAt: departure.addingTimeInterval(hours * 3600), arrivalAt: nil)
    }

    private func saved(_ number: String, _ origin: String = "KJFK", _ destination: String = "KLAX", hours: Double = 0) -> Flight {
        Flight(
            id: UUID(), origin: origin, destination: destination, departureAt: departure.addingTimeInterval(hours * 3600),
            flightNumber: number)
    }

    private let candidate = BookingCandidate(number: "B6 23", day: "2026-11-12")

    // MARK: Replace in place

    @Test func rebookingOnTheSameRouteReplacesTheFlight() {
        let old = saved("B6 23")
        let other = saved("UA 5", "KBOS", "KLAX")
        let new = found("B6 1023", "KJFK", "KLAX", hours: 2)
        #expect(EmailImport.replacementTarget(for: new, hash: nil, in: [other, old], hashes: [:])?.id == old.id)
        // A new time for the same number is a change too.
        let later = found("B6 23", "KJFK", "KLAX", hours: 1.5)
        #expect(EmailImport.replacementTarget(for: later, hash: nil, in: [old], hashes: [:])?.id == old.id)
    }

    @Test func otherRoutesDaysAndTheSameFlightAreNotReplaced() {
        let old = saved("B6 23")
        // More than a day apart: a different trip.
        #expect(EmailImport.replacementTarget(for: found("B6 1023", "KJFK", "KLAX", hours: 30), hash: nil, in: [old], hashes: [:]) == nil)
        // Another route.
        #expect(EmailImport.replacementTarget(for: found("B6 1023", "KJFK", "KBOS", hours: 2), hash: nil, in: [old], hashes: [:]) == nil)
        // Exactly what's saved: nothing to change.
        #expect(EmailImport.replacementTarget(for: found("B6 23", "KJFK", "KLAX"), hash: nil, in: [old], hashes: [:]) == nil)
    }

    @Test func anotherBookingNeverReplacesAFlight() {
        let old = saved("B6 23")
        let new = found("B6 1023", "KJFK", "KLAX", hours: 2)
        #expect(EmailImport.replacementTarget(for: new, hash: "b", in: [old], hashes: [old.id: "a"]) == nil)
        #expect(EmailImport.replacementTarget(for: new, hash: "a", in: [old], hashes: [old.id: "a"])?.id == old.id)
    }

    @Test func aCancelledFlightIsNeverReplaced() {
        var old = saved("B6 23")
        old.status = FlightStatus(state: .cancelled, live: true, checkedAt: .now)
        #expect(EmailImport.replacementTarget(for: found("B6 1023", "KJFK", "KLAX", hours: 2), hash: nil, in: [old], hashes: [:]) == nil)
    }

    // MARK: Needs you

    @Test func severalLegsWithoutAHintNeedYou() {
        let legs = [found("WN 100", "KBOS", "KJFK"), found("WN 100", "KJFK", "KLAX", hours: 3)]
        let result = FlightSearchResult(state: .found, flights: legs)
        #expect(EmailImport.classify(result, for: candidate) == .needsYou(.severalLegs))
        var hinted = candidate
        hinted.origin = "JFK"
        #expect(EmailImport.classify(result, for: hinted) == .found(legs[1]))
        #expect(EmailImport.classify(FlightSearchResult(state: .found, flights: [legs[0]]), for: candidate) == .found(legs[0]))
    }

    @Test func notFoundAndNoScheduleNeedYouAndUnavailableRetries() {
        #expect(EmailImport.classify(FlightSearchResult(state: .notFound, flights: []), for: candidate) == .needsYou(.notFound))
        #expect(EmailImport.classify(FlightSearchResult(state: .noSchedule, flights: []), for: candidate) == .needsYou(.noSchedule))
        #expect(EmailImport.classify(.unavailable, for: candidate) == .retry)
        // Found, but only between airports we can't forecast: still not dropped.
        let unknown = FoundFlight(
            flightNumber: "B6 23", airlineName: nil, origin: "ZZZZ", destination: "YYYY", departureAt: departure, arrivalAt: nil)
        #expect(EmailImport.classify(FlightSearchResult(state: .found, flights: [unknown]), for: candidate) == .needsYou(.notFound))
    }

    @Test func notPublishedIsSavedPendingWithAirportsElseNeedsYou() {
        let result = FlightSearchResult(state: .notPublished, flights: [])
        let future = Calendar(identifier: .gregorian).date(byAdding: .day, value: 200, to: .now)!.searchDay(in: .current)
        var booking = BookingCandidate(number: "AC 1507", day: future, time: "07:15", origin: "YYZ", destination: "YVR")
        guard case .pending(let draft) = EmailImport.classify(result, for: booking) else {
            Issue.record("Expected a pending flight")
            return
        }
        #expect(draft.schedulePending)
        #expect(draft.flightNumber == "AC 1507")
        #expect(draft.origin == "CYYZ" && draft.destination == "CYVR")
        booking.destination = nil
        #expect(EmailImport.classify(result, for: booking) == .needsYou(.noAirports))
    }

    @Test func aLandedFlightIsSkipped() {
        let flown = FoundFlight(
            flightNumber: "B6 23", airlineName: nil, origin: "KJFK", destination: "KLAX",
            departureAt: .now.addingTimeInterval(-10 * 3600), arrivalAt: .now.addingTimeInterval(-4 * 3600))
        #expect(EmailImport.classify(FlightSearchResult(state: .found, flights: [flown]), for: candidate) == .skip)
    }

    // MARK: Cancellations, changes and Undo

    @Test func undoingACancellationKeepsTheFlightForGood() {
        var ledger = EmailImport.Ledger()
        let id = UUID()
        #expect(ledger.shouldCancel("B6 23|2026-11-12"))
        ledger.markCancelled(id, at: .now)
        #expect(ledger.cancelled[id] != nil)
        ledger.undoCancel(id, key: "B6 23|2026-11-12")
        #expect(ledger.cancelled[id] == nil)
        // The same booking's cancellation never marks it again.
        #expect(!ledger.shouldCancel("B6 23|2026-11-12"))
        #expect(ledger.shouldCancel("B6 24|2026-11-22"))
    }

    @Test func undoingAChangeGivesBackTheOldFlight() {
        var ledger = EmailImport.Ledger()
        let old = saved("B6 23")
        ledger.changed(old.id, was: FlightDraft(old), hash: "h", at: .now)
        #expect(ledger.changes[old.id]?.was.flightNumber == "B6 23")
        #expect(ledger.hashes[old.id] == "h")
        let was = ledger.undoChange(old.id, newKey: "B6 1023|2026-11-12")
        #expect(was?.flightNumber == "B6 23")
        #expect(ledger.changes[old.id] == nil)
        // The new booking isn't applied again by a later scan.
        #expect(ledger.dismissed.contains("B6 1023|2026-11-12"))
    }

    @Test func removingAnAddedFlightDismissesItForGood() {
        var ledger = EmailImport.Ledger()
        let id = UUID()
        ledger.needs(EmailImport.NeedsYouItem(key: "B6 23|2026-11-12", number: "B6 23", day: "2026-11-12", reason: .notFound))
        ledger.added(id, key: "B6 23|2026-11-12", hash: "h", at: .now)
        #expect(ledger.needsYou.isEmpty)
        #expect(ledger.flightsFound == 1)
        #expect(ledger.isRecent(ledger.imported[id], now: .now.addingTimeInterval(23 * 3600)))
        #expect(!ledger.isRecent(ledger.imported[id], now: .now.addingTimeInterval(25 * 3600)))
        ledger.markCancelled(id, at: .now)
        ledger.removed(id, key: "B6 23|2026-11-12")
        #expect(ledger.imported[id] == nil && ledger.cancelled[id] == nil && ledger.hashes[id] == nil)
        #expect(ledger.dismissed.contains("B6 23|2026-11-12"))
    }

    @Test func emailCancellationReadsAsCancelled() {
        let flight = saved("B6 23")
        let overlay = EmailCancellations.shared
        #expect(!flight.isCancelled)
        overlay.set([flight.id])
        #expect(flight.isCancelled)
        overlay.set([])
        #expect(!flight.isCancelled)
    }
}

/// A flight pass that completes outside a paywall (Ask to Buy, the app closed mid-purchase) is
/// matched to the purchase that started on the flight's paywall.
struct PendingPassTests {
    let started = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func laterPassMatchesThePurchaseThatStarted() {
        let pending = Paywalls.PendingPass(flightID: UUID(), productID: "bumpcast_flight_pass", startedAt: started)
        // Approved a few hours later.
        #expect(pending.matches(productID: "bumpcast_flight_pass", purchaseDate: started + 3 * 3600, now: started + 3 * 3600))
        // Another pass product, one bought before this purchase started, or one long after.
        #expect(!pending.matches(productID: "bumpcast_flight_pass_999", purchaseDate: started + 60, now: started + 60))
        #expect(!pending.matches(productID: "bumpcast_flight_pass", purchaseDate: started - 3600, now: started + 60))
        #expect(!pending.matches(productID: "bumpcast_flight_pass", purchaseDate: started + 3 * 86400, now: started + 3 * 86400))
    }
}
