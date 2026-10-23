import Foundation
import SwiftUI
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
        // The flight screen asks again on its own clock, so the card moves on once that time comes.
        let unlock = flight.forecastUnlocksAt
        #expect(ForecastState(flight: flight, forecast: nil, now: unlock.addingTimeInterval(-1)) == .unlocksAt(unlock))
        #expect(ForecastState(flight: flight, forecast: nil, now: unlock) == .building)
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

    @Test func advanceExplanationNeverPromisesAPastTime() {
        let now = Date.now
        let expected = now.addingTimeInterval(-3600)
        let passed = Forecast.Confidence.early(noaaExpected: expected).explanation(now: now)
        #expect(!passed.contains("We'll confirm it"))
        #expect(!passed.contains(expected.formatted(date: .omitted, time: .shortened)))
        #expect(passed.contains("We're confirming it"))
        #expect(Forecast.Confidence.early(noaaExpected: now.addingTimeInterval(3600)).explanation(now: now).contains("We'll confirm it"))
        // Under way, nothing promises updates to come.
        let all: [Forecast.Confidence] = [.early(noaaExpected: now), .partly(confirmed: [0...10]), .confirmed]
        for confidence in all {
            #expect(!confidence.inFlightExplanation.contains("until you fly"))
            #expect(!confidence.inFlightExplanation.contains("We'll confirm"))
        }
    }

    @Test func nextUpdateNeverInventsATime() {
        typealias C = Forecast.Confidence
        let now = Date.now
        let recent = now.addingTimeInterval(-20 * 60)
        #expect(C.confirmed.nextUpdate(after: recent, now: now) == recent.addingTimeInterval(3600))
        #expect(C.partly(confirmed: [0...10]).nextUpdate(after: recent, now: now) == recent.addingTimeInterval(3600))
        // An hourly run that's overdue (no connection in the air) has no next time to show.
        #expect(C.confirmed.nextUpdate(after: now.addingTimeInterval(-2 * 3600), now: now) == nil)
        #expect(C.globalOutlook(confirmed: []).nextUpdate(after: recent, now: now) == recent.addingTimeInterval(6 * 3600))
        #expect(C.early(noaaExpected: now.addingTimeInterval(-60)).nextUpdate(after: recent, now: now) == nil)
        #expect(C.early(noaaExpected: now.addingTimeInterval(600)).nextUpdate(after: recent, now: now) == now.addingTimeInterval(600))
    }

    @Test func savedLineSaysWhatIsOnThePhone() {
        typealias C = Forecast.Confidence
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let time = issued.formatted(date: .omitted, time: .shortened)
        #expect(C.confirmed.savedLine(issuedAt: issued, inAir: false) == "Confirmed forecast from \(time), saved before takeoff.")
        #expect(C.confirmed.savedLine(issuedAt: issued, inAir: true) == "Confirmed forecast from \(time), updated in the air.")
        #expect(
            C.partly(confirmed: [0...40]).savedLine(issuedAt: issued, inAir: false)
                == "Partly confirmed forecast from \(time), saved before takeoff.")
        #expect(
            C.early(noaaExpected: issued).savedLine(issuedAt: issued, inAir: false)
                == "Advance forecast from \(time), saved before takeoff. It wasn't confirmed in time, so treat it as a guide.")
        #expect(
            C.globalOutlook(confirmed: []).savedLine(issuedAt: issued, inAir: true)
                == "Global outlook from \(time), updated in the air.")
        #expect(C.confirmed.savedLine(issuedAt: nil, inAir: false) == "Confirmed forecast, saved before takeoff.")
    }

    @Test func progressLineFollowsThePlane() {
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = Forecast(
            status: .ready, issuedAt: nil, source: "gtg", modelRun: nil, grade: .someBumps, score: 80,
            durationMin: 60, cruiseFt: 35000,
            segments: [
                .init(startMin: 10, endMin: 13, severity: .light, peakEdr: 0.12, phase: "climb", altitudeFt: 20000),
                .init(startMin: 21, endMin: 47, severity: .moderate, peakEdr: 0.25, phase: "cruise", altitudeFt: 35000),
            ],
            samples: [], route: [])
        #expect(forecast.progressLine(minute: 4, departure: departure) == "Next: light chop in about 6 min, for about 4 min")
        #expect(forecast.progressLine(minute: 10, departure: departure) == "Light chop now, about 4 min to go")
        #expect(forecast.progressLine(minute: 15, departure: departure) == "Next: moderate bumps in about 6 min, for about 27 min")
        #expect(forecast.progressLine(minute: 47, departure: departure) == "Moderate bumps now, about 1 min to go")
        #expect(forecast.progressLine(minute: 48, departure: departure) == "Smooth to landing")
        // Outlook stretches stay approximate, and never "smooth".
        let outlook = DemoFlightService.load("sample_global_outlook")
        #expect(outlook.progressLine(minute: 2, departure: departure) == "Bumps possible now")
        #expect(outlook.progressLine(minute: 7, departure: departure) == "Next: bumps possible in about 10 min")
        #expect(outlook.progressLine(minute: 560, departure: departure) == "No major bumps expected to landing")
    }

    @Test func inFlightWording() {
        let now = Date.now
        #expect(InFlightCopy.eyebrow(minute: 0) == "In the air · just took off")
        #expect(InFlightCopy.eyebrow(minute: 72) == "In the air · 1 h 12 min in")
        #expect(InFlightCopy.landing(now.addingTimeInterval(90), now: now, tz: .current) == "Landing soon")
        #expect(InFlightCopy.landing(now.addingTimeInterval(25 * 60 + 5), now: now, tz: .current).hasPrefix("Landing in about 25 min, around "))
        // On a tick a second past minute 30 of a 294-minute flight, the landing line says what "Left to fly" does.
        let takeoff = now.addingTimeInterval(-(30 * 60 + 1))
        #expect(InFlightCopy.minutesLeft(to: takeoff.addingTimeInterval(294 * 60), now: now) == 294 - 30)
        #expect(InFlightCopy.basis(.reported, takeoff: now, tz: .current) == "Timed from takeoff at \(now.localTime(in: .current)).")
        #expect(InFlightCopy.basis(.expected, takeoff: now, tz: .current).hasPrefix("Timed from the expected takeoff, around"))
        #expect(InFlightCopy.seatbeltNoted(minute: 10) == "Noted at 10 min in. Thanks, this helps us check your forecast.")
        // The wifi advice never promises to follow a route change.
        #expect(!InFlightCopy.wifiInAir.contains("route"))
        #expect(!InFlightCopy.wifiBeforeTakeoff.contains("route"))
        #expect(InFlightCopy.clearToLanding(outlook: false) == "Smooth to landing")
        #expect(InFlightCopy.clearToLanding(outlook: true) == "No major bumps expected to landing")
        // A diverted flight's countdown keeps running, so its card names the button that ends it.
        for onLockScreen in [true, false] {
            #expect(InFlightCopy.divertedBody(onLockScreen: onLockScreen).contains("“We've landed”"))
        }
    }

    @Test func connectionWordingOnlyForConnectionProblems() {
        let now = Date.now
        #expect(ConnectionNote(hasPath: false, isDegraded: false, syncFailed: true) == .offline)
        #expect(ConnectionNote(hasPath: true, isDegraded: true, syncFailed: false) == .notOnline)
        #expect(ConnectionNote(hasPath: true, isDegraded: false, syncFailed: true) == .syncFailed)
        #expect(ConnectionNote(hasPath: true, isDegraded: false, syncFailed: false) == .none)
        // Wifi that passes nothing: the degraded note clears before the retry times out.
        #expect(ConnectionNote(hasPath: true, isDegraded: false, syncFailed: true, failedOnConnection: true) == .notOnline)
        #expect(ConnectionNote(hasPath: true, isDegraded: false, syncFailed: false, failedOnConnection: true) == .none)
        #expect(OfflineCopy.banner(.none, checkedAt: now) == nil)
        #expect(OfflineCopy.banner(.offline, checkedAt: nil) == "Offline. Showing what's saved on this phone.")
        #expect(OfflineCopy.banner(.offline, checkedAt: now)?.hasPrefix("Offline. Showing what's saved on this phone, last checked ") == true)
        #expect(OfflineCopy.detail(.notOnline, checkedAt: nil) == "Not reaching the internet · showing what's saved on this phone")
        // A server error never sends anyone to fix a connection that works.
        for text in [OfflineCopy.banner(.syncFailed, checkedAt: now), OfflineCopy.detail(.syncFailed, checkedAt: now)] {
            #expect(text?.hasPrefix("Couldn't update just now") == true)
            #expect(text?.contains("internet") == false)
            #expect(text?.contains("Offline") == false)
        }
        #expect(!InFlightCopy.syncFailed.contains("wifi"))
        // It can be cellular.
        #expect(!InFlightCopy.notOnlineYet.contains("to wifi"))
        // "Last checked" is the later of the last sync and the newest forecast on the phone.
        let sync = now.addingTimeInterval(-46 * 60)
        #expect(OfflineCopy.lastChecked(syncedAt: sync, issued: [now, nil]) == now)
        #expect(OfflineCopy.lastChecked(syncedAt: now, issued: [sync]) == now)
        #expect(OfflineCopy.lastChecked(syncedAt: nil, issued: [nil]) == nil)
    }

    @Test func countdownCopyMatchesWhenItStarts() {
        #expect(InFlightCopy.armedBody(takeoff: "3:15 PM", onLockScreen: true).hasPrefix("It's on your Lock Screen now."))
        // Not up yet: it comes up about 15 minutes before departure, not at takeoff.
        #expect(InFlightCopy.armedBody(takeoff: "3:15 PM", onLockScreen: false).contains("shortly before departure"))
        for text in [
            InFlightCopy.boardingBody(takeoff: "3:15 PM"),
            InFlightCopy.armedBody(takeoff: "3:15 PM", onLockScreen: false),
            InFlightCopy.armedBody(takeoff: "3:15 PM", onLockScreen: true),
        ] {
            #expect(!text.contains("starts on your Lock Screen at takeoff"))
            #expect(text.contains("around 3:15 PM"))
        }
    }

    @MainActor @Test func disruptedFlightsNeverShowInFlightMode() {
        let now = Date.now
        let takeoff = now.addingTimeInterval(-20.5 * 60)
        func flight(_ state: FlightStatus.State) -> Flight {
            Flight(
                id: UUID(), origin: "KJFK", destination: "KLAX", departureAt: takeoff.addingTimeInterval(-15 * 60),
                flightNumber: "B6 23", status: FlightStatus(state: state, checkedAt: now, takeoffAt: takeoff))
        }
        let forecast = DemoFlightService.sampleForecast
        #expect(InFlightMode.minute(flight(.departed), forecast: forecast, inFlight: .shared, now: now) == 20)
        for state in [FlightStatus.State.cancelled, .diverted] {
            let disrupted = flight(state)
            #expect(disrupted.isDisrupted)
            #expect(!InFlightMode.isFlying(disrupted, forecast: forecast, inFlight: .shared, now: now))
            #expect(InFlightMode.minute(disrupted, forecast: forecast, inFlight: .shared, now: now) == nil)
        }
        // The countdown itself stops for a cancelled flight; a diverted one is still in the air.
        #expect(!InFlight.shared.isFlying(flight(.cancelled), forecast: forecast, now: now))
        #expect(!InFlight.shared.canTakeOff(flight(.cancelled), forecast: forecast, now: now))
        #expect(InFlight.shared.isFlying(flight(.diverted), forecast: forecast, now: now))
    }

    /// One landing rule for the app, the Live Activity and the worker's pushes (notify.duration_min).
    @MainActor @Test func landingFollowsTheAirlineButNotBeforeTheLastStretch() {
        let takeoff = Date.now.addingTimeInterval(-3600)
        let forecast = DemoFlightService.sampleForecast  // 294 min; the last stretch ends at minute 294
        func flight(expected: Double?, actual: Double? = nil, live: Bool = true) -> Flight {
            Flight(
                id: UUID(), origin: "KJFK", destination: "KLAX", departureAt: takeoff.addingTimeInterval(-15 * 60),
                flightNumber: "B6 23",
                status: FlightStatus(
                    state: .departed, live: live, arrivalExpected: expected.map { takeoff.addingTimeInterval($0 * 60) },
                    arrivalActual: actual.map { takeoff.addingTimeInterval($0 * 60) }, checkedAt: .now, takeoffAt: takeoff))
        }
        #expect(InFlight.airMinutes(flight(expected: 320), forecast: forecast, takeoff: takeoff) == 320)
        #expect(InFlight.airMinutes(flight(expected: 270), forecast: forecast, takeoff: takeoff) == 294)
        #expect(InFlight.airMinutes(flight(expected: 290, actual: 270), forecast: forecast, takeoff: takeoff) == 270)
        #expect(InFlight.airMinutes(flight(expected: 320, live: false), forecast: forecast, takeoff: takeoff) == 294)
        #expect(InFlight.airMinutes(flight(expected: 294 + 125), forecast: forecast, takeoff: takeoff) == 294)
    }

    @Test func flightMinutesTickOnTheFlightsOwnMinutes() {
        let now = Date.now
        for offset in [-(2 * 3600 + 17.3), -5, 42.7, 30 * 3600 + 0.4] {
            let takeoff = now.addingTimeInterval(offset)
            var entries = PeriodicTimelineSchedule.flightMinutes(takeoff: takeoff, now: now)
                .entries(from: now, mode: .normal).makeIterator()
            guard let first = entries.next(), let second = entries.next() else {
                Issue.record("no entries")
                continue
            }
            // The first entry is the current one, and every tick lands a second past a flight minute.
            #expect(first <= now && second > now)
            let phase = first.timeIntervalSince(takeoff).truncatingRemainder(dividingBy: 60)
            #expect(abs(phase - 1) < 0.001 || abs(phase + 59) < 0.001)
        }
        let flying = now.addingTimeInterval(-(2 * 3600 + 17.3))
        var entries = PeriodicTimelineSchedule.flightMinutes(takeoff: flying, now: now).entries(from: now, mode: .normal).makeIterator()
        #expect(entries.next().map { Int($0.timeIntervalSince(flying) / 60) } == 120)
    }

    @Test func airportSearchPrefersExactCode() {
        #expect(AirportStore.shared.search("lax").first?.icao == "KLAX")
        #expect(AirportStore.shared.airport("JFK")?.tz == "America/New_York")
    }
}
