import Foundation
import Testing

@testable import Smooth

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

    @Test func airportSearchPrefersExactCode() {
        #expect(AirportStore.shared.search("lax").first?.icao == "KLAX")
        #expect(AirportStore.shared.airport("JFK")?.tz == "America/New_York")
    }
}
