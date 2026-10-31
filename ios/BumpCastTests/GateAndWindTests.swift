import Foundation
import Testing

@testable import BumpCast

/// Gate changes and gusty takeoffs and landings (docs/design/gate-and-wind-brief.md): "was" only
/// for a gate this phone showed, and calm, city-named wording for a gusty stretch.
struct GateAndWindTests {
    private func status(_ gate: String?, _ terminal: String?, state: FlightStatus.State = .scheduled, live: Bool = true)
        -> FlightStatus
    {
        FlightStatus(state: state, live: live, departureGate: gate, departureTerminal: terminal, checkedAt: .now)
    }

    /// Notes what's on screen, then says what the row would.
    private func shown(_ status: FlightStatus, for id: UUID) -> GateMemory.Change {
        GateMemory.note(status, for: id)
        return GateMemory.change(status, seen: GateMemory.record(for: id))
    }

    @Test func aChangedGateSaysWhatThisPhoneShowed() {
        let id = UUID()
        #expect(shown(status("B18", "5"), for: id) == GateMemory.Change())
        #expect(shown(status("B22", "5"), for: id) == GateMemory.Change(wasGate: "B18"))
        // Still B22 later: still "was B18".
        #expect(shown(status("B22", "5"), for: id) == GateMemory.Change(wasGate: "B18"))
    }

    @Test func aGateChangedBeforeAnyoneLookedIsNeverStruckThrough() {
        #expect(shown(status("B22", "5"), for: UUID()) == GateMemory.Change())
    }

    @Test func aTerminalChangeKeepsTheOldGateWithIt() {
        let id = UUID()
        _ = shown(status("A3", "4"), for: id)
        #expect(shown(status("B22", "5"), for: id) == GateMemory.Change(wasTerminal: "4", wasTerminalGate: "A3"))
    }

    @Test func aGateThatDisappearsIsRemembered() {
        let id = UUID()
        _ = shown(status("H12", "3"), for: id)
        #expect(shown(status(nil, "3"), for: id) == GateMemory.Change(lastShownGate: "H12"))
        #expect(GateMemory.record(for: id)?.gate == "H12")
        // Back at another gate: that's a change from the one shown.
        #expect(shown(status("H14", "3"), for: id) == GateMemory.Change(wasGate: "H12"))
    }

    @Test func noGateTalkOnceThePlaneHasLeft() {
        let id = UUID()
        _ = shown(status("B18", "5"), for: id)
        #expect(shown(status("B22", "5", state: .departed), for: id) == GateMemory.Change())
    }

    @Test func onlyThePublishedScheduleIsNeverOnTime() {
        #expect(status(nil, nil, live: false).isScheduleOnly)
        #expect(!status(nil, nil).isScheduleOnly)
        #expect(!status(nil, nil, state: .delayed, live: false).isScheduleOnly)
    }

    private func segment(_ severity: Severity, _ phase: String, cause: String?) -> Forecast.Segment {
        Forecast.Segment(
            startMin: 0, endMin: 2, severity: severity, peakEdr: 0.15, phase: phase, altitudeFt: 600, cause: cause)
    }

    @Test func gustyRowsNameTheCityAndStayCalm() {
        let landing = segment(.light, "descent", cause: "wind_destination")
        #expect(landing.gustyLabel(city: "Newark") == "Gusty in Newark around your landing")
        #expect(
            landing.gustySentence(city: "Newark")
                == "Gusty wind expected in Newark around your landing. Normal on a windy day, and the crew plans for it.")
        let takeoff = segment(.light, "climb", cause: "wind_origin")
        #expect(takeoff.gustyLabel(city: "Toronto") == "Gusty in Toronto around your takeoff")
        #expect(takeoff.gustyReminder(city: "Toronto")?.contains("It eases as you climb higher.") == true)
        // Already moderate: the wind isn't claimed as the whole cause, and the reminder keeps its usual body.
        let moderate = segment(.moderate, "descent", cause: "wind_destination")
        #expect(moderate.gustyLabel(city: "Denver") == "May also be gusty in Denver around your landing")
        #expect(moderate.gustyReminder(city: "Denver") == nil)
    }

    @Test func anUnknownCauseShowsNothing() {
        let other = segment(.light, "descent", cause: "thunderstorms")
        #expect(other.gustyEnd == nil)
        #expect(other.gustyLabel(city: "Newark") == nil)
        #expect(Explainer.forStretch(other).id == "low-level")
    }

    @Test func onlyALightGustyStretchOpensGustyAtTheAirport() {
        #expect(Explainer.forStretch(segment(.light, "climb", cause: "wind_origin")).id == "gusty-airport")
        #expect(Explainer.forStretch(segment(.moderate, "descent", cause: "wind_destination")).id == "low-level")
        #expect(Explainer.byID("gusty-airport")?.offersLightChopFeel == false)
    }

    @Test func segmentsDecodeWithAndWithoutACause() throws {
        let decoder = JSONDecoder()
        let plain = #"{"start_min":0,"end_min":1,"severity":"light","peak_edr":0.1,"phase":"climb","altitude_ft":0}"#
        #expect(try decoder.decode(Forecast.Segment.self, from: Data(plain.utf8)).cause == nil)
        let gusty = #"{"start_min":0,"end_min":1,"severity":"light","peak_edr":0.1,"phase":"climb","altitude_ft":0,"cause":"wind_origin"}"#
        #expect(try decoder.decode(Forecast.Segment.self, from: Data(gusty.utf8)).gustyEnd == .takeoff)
    }
}
