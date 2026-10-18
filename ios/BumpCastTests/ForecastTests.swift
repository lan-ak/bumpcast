import Foundation
import Testing

@testable import BumpCast

struct ForecastTests {
    @Test func decodesWorkerOutput() throws {
        let forecast = DemoFlightService.sampleForecast
        #expect(forecast.status == .ready)
        #expect(forecast.grade != nil)
        #expect(!forecast.samples.isEmpty)
    }

    @Test func severityThresholds() {
        #expect(Severity(edr: 0.05) == .smooth)
        #expect(Severity(edr: 0.10) == .light)
        #expect(Severity(edr: 0.25) == .moderate)
        #expect(Severity(edr: 0.40) == .severe)
    }

    @Test func stateUnlocksAt48Hours() {
        let now = Date.now
        let flight = Flight(id: UUID(), origin: "KJFK", destination: "KLAX", departureAt: now.addingTimeInterval(72 * 3600))
        #expect(ForecastState(flight: flight, forecast: nil, now: now) == .unlocksAt(flight.forecastUnlocksAt))
        let soon = Flight(id: UUID(), origin: "KJFK", destination: "KLAX", departureAt: now.addingTimeInterval(3600))
        #expect(ForecastState(flight: soon, forecast: nil, now: now) == .building)
    }

    @Test func confidenceFollowsSource() throws {
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        let takeoff = departure.addingTimeInterval(15 * 60)
        func forecast(_ source: String, run: Date? = nil) -> Forecast {
            Forecast(
                status: .ready, issuedAt: nil, source: source, modelRun: run, grade: .smooth, score: 100,
                durationMin: 120, cruiseFt: 35000, segments: [], samples: [], route: [])
        }
        #expect(forecast("gtg").confidence(departure: departure) == .confirmed)
        // NOAA starts covering the flight once a run within 18 h of takeoff is published (~1 h later).
        #expect(
            forecast("gfs").confidence(departure: departure)
                == .early(noaaExpected: takeoff.addingTimeInterval(-17 * 3600)))
        // A run whose 18 h horizon ends 40 min after takeoff confirms the first 40 min.
        let run = takeoff.addingTimeInterval(-18 * 3600 + 40 * 60)
        #expect(forecast("mixed", run: run).confidence(departure: departure) == .partly(confirmedUntilMin: 40))
    }

    @Test func airportSearchPrefersExactCode() {
        #expect(AirportStore.shared.search("lax").first?.icao == "KLAX")
        #expect(AirportStore.shared.airport("JFK")?.tz == "America/New_York")
    }
}
