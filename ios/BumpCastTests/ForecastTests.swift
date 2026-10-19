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
        #expect(forecast("mixed", run: run).confidence(departure: departure) == .partly(confirmed: [0...39]))
    }

    @Test func globalOutlookConfidenceComesFromStretches() {
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        var forecast = DemoFlightService.load("sample_partly_outlook")
        #expect(forecast.isGlobalOutlook)
        #expect(forecast.confidence(departure: departure) == .globalOutlook(confirmed: [0...90]))
        #expect(!forecast.isOutlook(minute: 30, departure: departure))
        #expect(forecast.isOutlook(minute: 200, departure: departure))
        // Routes NOAA can cover read their stretches too, including gaps in the middle.
        forecast.noaaPossible = true
        forecast.sources = [
            .init(startMin: 0, endMin: 40, source: "gtg"), .init(startMin: 41, endMin: 100, source: "gfs"),
            .init(startMin: 101, endMin: 130, source: "gtg"),
        ]
        #expect(forecast.confidence(departure: departure) == .partly(confirmed: [0...40, 101...130]))
        forecast.sources = [.init(startMin: 0, endMin: 130, source: "gtg")]
        #expect(forecast.confidence(departure: departure) == .confirmed)
    }

    @Test func confirmedStretchWording() {
        typealias C = Forecast.Confidence
        #expect(C.confirmedText([0...40]) == "First 41 min confirmed.")
        #expect(C.confirmedText([0...40, 371...400], durationMin: 400) == "First 41 min and last 30 min confirmed.")
        #expect(C.confirmedText([70...124]) == "Confirmed from 1 h 10 min to 2 h 05 min in.")
        #expect(C.confirmedText([0...44, 60...104, 200...244]) == "3 stretches confirmed, 2 h 15 min in total.")
        #expect(C.confirmedText([]) == nil)
        #expect(C.globalOutlook(confirmed: []).statusLine() == "Updated every 6 hours until you fly")
        #expect(
            C.globalOutlook(confirmed: [0...40]).statusLine()
                == "First 41 min confirmed. The rest is a beta outlook, updated every 6 hours.")
    }

    @Test func outlookReadsRougherThanAConfirmedForecast() {
        #expect(41.roughMinutes == 40 && 7.roughMinutes == 10 && 95.roughMinutes == 90 && 106.roughMinutes == 120)
        #expect(Forecast.Grade.smooth.outlookHeadline == "No major bumps expected.")
        #expect(Forecast.Grade.mostlySmooth.outlookSummary.hasSuffix("Light bumps are possible on any flight."))
        let forecast = DemoFlightService.load("sample_global_outlook")
        let warned = forecast.segments.first { forecast.warning(for: $0)?.isOfficial == true }!
        #expect(warned.outlookRange(warning: forecast.warning(for: warned)) == "Moderate to strong possible near the warning")
        let plain = forecast.segments.first { forecast.warning(for: $0) == nil }!
        #expect(plain.outlookRange(warning: nil) == "Light to moderate possible")
        #expect(forecast.officialWarnings.first?.bannerText == "Thunderstorms over Recife, about 1 h in")
    }

    @Test func nearbyOutlookStretchesShareARow() {
        let departure = Date.now
        let forecast = DemoFlightService.load("sample_global_outlook")
        let rows = forecast.expectedStretches(departure: departure)
        #expect(rows.count < forecast.segments.count)
        // No two outlook rows round to the same start.
        let starts = rows.map { $0.approximateTiming.components(separatedBy: ",")[0] }
        #expect(Set(starts).count == starts.count)
        // The warned stretch keeps its own row.
        #expect(rows.contains { forecast.warning(for: $0)?.isOfficial == true })
    }

    @Test func betaOffShowsNotForecastYet() {
        let now = Date.now
        let flight = Flight(id: UUID(), origin: "SBGR", destination: "LPPT", departureAt: now.addingTimeInterval(3600))
        let outlook = DemoFlightService.load("sample_global_outlook")
        #expect(ForecastState(flight: flight, forecast: outlook, now: now, betaOn: false) == .betaAvailable)
        #expect(ForecastState(flight: flight, forecast: outlook, now: now, betaOn: true) == .ready(outlook))
        #expect(ForecastState(flight: flight, forecast: nil, now: now, betaOn: false) == .betaAvailable)
        #expect(ForecastState(flight: flight, forecast: nil, now: now, betaOn: true) == .building)
    }

    @Test func statusLinesSayWhenItFirmsUp() {
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: .now)!
        let tonight = calendar.date(bySettingHour: 19, minute: 15, second: 0, of: now)!
        let early = Forecast.Confidence.early(noaaExpected: tonight)
        #expect(early.shortStatus(now: now) == "Advance · confirms tonight")
        #expect(early.statusLine(now: now).hasPrefix("Confirmed today around"))
        #expect(Forecast.Confidence.early(noaaExpected: now.addingTimeInterval(-60)).shortStatus(now: now) == "Advance · confirming now")
        #expect(Forecast.Confidence.confirmed.statusLine(now: now) == "Updated hourly until you fly")
    }

    @Test func airportSearchPrefersExactCode() {
        #expect(AirportStore.shared.search("lax").first?.icao == "KLAX")
        #expect(AirportStore.shared.airport("JFK")?.tz == "America/New_York")
    }
}
