import Foundation
import Testing

@testable import BumpCast

/// Which searched flights Add flight offers: an overnight flight still in the air after midnight
/// (it left yesterday), and never "In the air" for one that's down.
struct FlightSearchTests {
    /// Just after midnight, on board a red-eye that left late the night before.
    let now = Date(timeIntervalSince1970: 1_792_805_400)

    private func flight(
        departs: TimeInterval, arrives: TimeInterval?, departed: Bool? = nil, takeoff: TimeInterval? = nil,
        landed: TimeInterval? = nil, reference: Date? = nil
    ) -> FoundFlight {
        let base = reference ?? now
        return FoundFlight(
            flightNumber: "AC 1507", airlineName: nil, origin: "KJFK", destination: "KLAX",
            departureAt: base.addingTimeInterval(departs * 3600),
            arrivalAt: arrives.map { base.addingTimeInterval($0 * 3600) },
            departed: departed, takeoffAt: takeoff.map { base.addingTimeInterval($0 * 3600) },
            landedAt: landed.map { base.addingTimeInterval($0 * 3600) })
    }

    @Test func tonightsFlightMeansLastNightsMayStillBeFlying() {
        // Today's search finds tonight's 23:30 (22 hours on), landing at 05:00.
        let tonight = flight(departs: 22, arrives: 27.5)
        #expect(FoundFlight.mayStillFlyFromYesterday([tonight], now: now))
        // By the evening, last night's has long landed: no second search.
        #expect(!FoundFlight.mayStillFlyFromYesterday([tonight], now: now.addingTimeInterval(16 * 3600)))
    }

    @Test func noSecondSearchWhenTodaysIsInTheAir() {
        let flying = flight(departs: -1, arrives: 3, departed: true, takeoff: -0.8)
        #expect(!FoundFlight.mayStillFlyFromYesterday([flying], now: now))
    }

    @Test func noFlightTodayStillLooksAtYesterday() {
        #expect(FoundFlight.mayStillFlyFromYesterday([], now: now))
    }

    @Test func yesterdaysLegsInTheAirAreKept() {
        let flying = flight(departs: -2, arrives: 3.5, departed: true, takeoff: -1.7)
        let down = flight(departs: -8, arrives: -3, departed: true, takeoff: -7.8, landed: -3)
        #expect(FoundFlight.stillFlying([down, flying], now: now) == [flying])
        // A phone a few time zones ahead of the airport calls a flight that hasn't left "yesterday".
        let later = flight(departs: 1, arrives: 6.25)
        #expect(FoundFlight.stillFlying([later], now: now) == [later])
    }

    @Test func arrivedWithoutALandingTimeNeverReadsInTheAir() {
        // Took off five hours ago and due an hour ago; no landing time came through.
        let down = flight(departs: -5, arrives: -1, departed: true, takeoff: -4.8, reference: .now)
        #expect(down.hasLanded())
        #expect(down.liveText == "Landed")
        // Still flying, it says so.
        let flying = flight(departs: -2, arrives: 2, departed: true, takeoff: -1.8, reference: .now)
        #expect(flying.liveText?.hasPrefix("In the air") == true)
    }
}
