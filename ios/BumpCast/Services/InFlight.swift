import ActivityKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Arming at the gate gets the Live Activity ready for departure and local reminders before each
/// bumpy stretch. One takeoff times all of it: the airline's real wheels-up or the user's "We've
/// taken off", else the time the countdown was armed with, else the estimate. Wheels-up re-times
/// the countdown by push to the Live Activity and a background wake for the reminders. Everything
/// works offline, which is the point: there's usually no signal up there.
@Observable @MainActor
final class InFlight {
    static let shared = InFlight()

    /// Actual takeoff and landing times the user tapped, by flight. Persisted across relaunches.
    private(set) var takeoffs: [UUID: Date] = [:]
    private(set) var landings: [UUID: Date] = [:]
    /// Flights with a countdown, and the takeoff it was timed to. Persisted too. Once armed it
    /// moves only for a real wheels-up, a tap, or a departure the airline reported before takeoff.
    private(set) var armed: [UUID: Date] = [:]
    /// Flights whose Live Activity the user ended. Syncs don't bring it back; tapping does.
    private(set) var dismissed: Set<UUID> = []
    /// Minutes after takeoff the user tapped "Seatbelt sign is on". Sent with the landing report.
    private(set) var seatbelts: [UUID: [Int]] = [:]
    /// Wheels-up the worker pushed to the Live Activity before a sync brought it to the app.
    private var pushedTakeoffs: [UUID: Date] = [:]
    /// Flights whose Live Activity was started. A sync starts one only once, so an activity the
    /// user swiped away doesn't come back; tapping does, and so does the system ending it.
    @ObservationIgnored private var started: Set<UUID> = []
    /// "origin-destination" for each flight with a countdown, so a copy of the same trip added
    /// again (a new id) can take over its countdown.
    @ObservationIgnored private var trips: [UUID: String] = [:]
    /// Old id → new id for a trip saved again under a new id. A Live Activity and reminders made
    /// for the old id carry on as the new one's until it has its own.
    @ObservationIgnored private var replaced: [UUID: UUID] = [:]
    /// Activities whose push tokens are watched, and the token the worker has for each.
    @ObservationIgnored private var observedTokens: Set<String> = []
    @ObservationIgnored private var registeredTokens: [String: String] = [:]
    @ObservationIgnored private var registering: Set<String> = []
    /// One reconcile at a time, so two syncs can't both start an activity.
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    /// Stretch reminders are written one pass at a time, and only a flight's newest pass adds any,
    /// so one timed to an older takeoff can't put its reminders back after a newer one.
    @ObservationIgnored private var reminderPass: Task<Void, Never>?
    @ObservationIgnored private var reminderRuns: [UUID: Int] = [:]
    /// Bumped when an activity starts or ends, so views that ask hasActivity redraw.
    private var activityVersion = 0

    private let defaults = UserDefaults.standard
    /// Remind a little before each stretch so there's time to settle in.
    static let leadTime: TimeInterval = 2 * 60
    static let landingCheckDelay: TimeInterval = 15 * 60
    /// How long the Live Activity stays after landing to collect the rating.
    static let ratingWindow: TimeInterval = 30 * 60
    /// The countdown comes up on the Lock Screen this long before departure (about when the doors
    /// close), not hours ahead: it's scheduled for then, and opening the app any earlier doesn't
    /// bring it forward. "We've taken off" or a later start shows it at once.
    static let showLead: TimeInterval = 15 * 60
    // A Live Activity stays active for at most 8 hours. One the system ends before landing (a very
    // long flight) starts again the next time the app is open (see `mayRequest`).
    /// A flight added again takes over a trip's countdown when its takeoff is this close.
    private static let adoptWindow: TimeInterval = 3 * 3600
    /// How long a trip is remembered after its takeoff.
    private static let tripMemory: TimeInterval = 24 * 3600
    /// Activity content must stay under 4 KB; no real flight has this many stretches.
    private static let maxStretches = 20
    #if DEBUG
        static let environment = "sandbox"
    #else
        static let environment = "production"
    #endif

    init() {
        takeoffs = Self.load("takeoffs", from: defaults)
        landings = Self.load("landings", from: defaults)
        armed = Self.load("armed", from: defaults)
        pushedTakeoffs = Self.load("pushedTakeoffs", from: defaults)
        dismissed = Self.loadSet("dismissed", from: defaults)
        started = Self.loadSet("activityStarted", from: defaults)
        trips = Self.loadByID("trips", from: defaults)
        seatbelts = Self.loadByID("seatbelts", from: defaults)
        replaced = (Self.loadByID("replacedFlights", from: defaults) as [UUID: String]).compactMapValues(UUID.init(uuidString:))
    }

    // MARK: Takeoff

    /// Real wheels-up: the airline's runway time (from a sync, or pushed to the Live Activity),
    /// else the time the user tapped "We've taken off".
    func takeoff(of flight: Flight) -> Date? {
        flight.reportedTakeoff ?? pushedTakeoffs[flight.id] ?? takeoffs[flight.id]
    }

    /// The one takeoff everything is timed to: real wheels-up, else the time the countdown was
    /// armed with, else the estimate. The Live Activity, reminders and every screen agree.
    func effectiveTakeoff(of flight: Flight) -> Date {
        takeoff(of: flight) ?? armed[flight.id] ?? flight.estimatedTakeoff
    }

    /// Where the takeoff time comes from, for "Timed from ..." lines.
    enum TakeoffBasis: Sendable {
        case reported, tapped, expected
    }

    func takeoffBasis(of flight: Flight) -> TakeoffBasis {
        if flight.reportedTakeoff != nil || pushedTakeoffs[flight.id] != nil { return .reported }
        return takeoffs[flight.id] != nil ? .tapped : .expected
    }

    func landing(of flight: Flight, forecast: Forecast?) -> Date {
        if let landed = landings[flight.id] { return landed }
        let takeoff = effectiveTakeoff(of: flight)
        return takeoff.addingTimeInterval(Self.airMinutes(flight, forecast: forecast, takeoff: takeoff) * 60)
    }

    /// Minutes from `takeoff` to landing, the one rule the app, the Live Activity (see `content`)
    /// and the worker's pushes (notify.duration_min) share: the airline's arrival when it has one
    /// near our profile's, earlier or later (our profile is a typical climb and cruise with no
    /// wind; AC 1507 landed 10 minutes after it), so the screens agree with the "Arrives" time in
    /// the flight's status. An expected arrival never ends the flight before the plan's last
    /// stretch does; only a reported landing can.
    static func airMinutes(_ flight: Flight, forecast: Forecast?, takeoff: Date) -> Double {
        airMinutes(
            flight, planned: forecast?.durationMin.map(Double.init) ?? flight.estimatedAirMinutes,
            lastStretch: forecast?.segments.map(\.endMin).max() ?? 0, takeoff: takeoff)
    }

    static func airMinutes(_ flight: Flight, planned: Double, lastStretch: Int, takeoff: Date) -> Double {
        var minutes = planned
        var floor = Double(lastStretch)
        if let status = flight.status, status.live, let reported = status.arrivalActual ?? status.arrivalExpected {
            let airline = reported.timeIntervalSince(takeoff) / 60
            if airline > planned - 60, airline < planned + 120 {
                minutes = airline
                if status.arrivalActual != nil { floor = 0 }
            }
        }
        return max(minutes, floor, 1)
    }

    func isArmed(_ flight: Flight) -> Bool { armed[flight.id] != nil }

    /// In the air: after a real wheels-up (for everyone, status is free), or once an armed
    /// countdown's takeoff has passed, until landing. Never for a cancelled flight.
    func isFlying(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Bool {
        guard !flight.isCancelled, takeoff(of: flight) != nil || armed[flight.id] != nil else { return false }
        return effectiveTakeoff(of: flight) <= now && now < landing(of: flight, forecast: forecast)
    }

    /// Minutes since takeoff while flying, for the "you are here" marker.
    func elapsedMinutes(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Int? {
        guard isFlying(flight, forecast: forecast, now: now) else { return nil }
        return Int(now.timeIntervalSince(effectiveTakeoff(of: flight)) / 60)
    }

    /// The takeoff button shows from an hour before departure until landing, unless it's cancelled.
    func canTakeOff(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Bool {
        !flight.isCancelled && takeoffs[flight.id] == nil
            && now >= flight.departureAt.addingTimeInterval(-3600)
            && now < landing(of: flight, forecast: forecast)
    }

    /// Before departure, or once wheels-up is known, arm the countdown (to the real takeoff when
    /// there is one). Otherwise the departure has passed and the user is telling us they took off.
    func getReady(_ flight: Flight, forecast: Forecast, now: Date = .now) {
        if takeoff(of: flight) != nil || now < flight.expectedDeparture {
            arm(flight, forecast: forecast)
        } else {
            takeOff(flight, forecast: forecast, at: now)
        }
    }

    /// The Live Activity starts at departure (right away when that's close) and reminders are
    /// timed to the effective takeoff. A later "We've taken off" or wheels-up re-times both.
    func arm(_ flight: Flight, forecast: Forecast) {
        dismissed.remove(flight.id)
        started.remove(flight.id)
        retime(flight, forecast: forecast, takeoff: effectiveTakeoff(of: flight))
    }

    /// Times the countdown and reminders to `takeoff`, updating a running Live Activity in place.
    private func retime(_ flight: Flight, forecast: Forecast, takeoff: Date) {
        armed[flight.id] = takeoff
        trips[flight.id] = Self.trip(flight)
        persist()
        startActivity(flight, forecast: forecast, takeoff: takeoff, at: showTime(flight, takeoff: takeoff))
        scheduleStretchReminders(flight, forecast: forecast, takeoff: takeoff)
        Task { await scheduleLandingChecks() }
        Paywalls.shared.updateAttributes()
    }

    /// Pro and passholders don't have to remember to tap: a flight leaving within this window is
    /// armed on the next sync, so the countdown and reminders are ready even with no signal later.
    static let autoArmWindow: TimeInterval = 24 * 3600

    /// After a sync: arm flights leaving soon, or already in the air, for people who have the
    /// countdown. One added mid-flight starts at its real takeoff.
    func armUpcoming(now: Date = .now) {
        adoptRecentTrips(now: now)
        let store = FlightStore.shared
        for flight in store.flights
        where armed[flight.id] == nil && takeoffs[flight.id] == nil && landings[flight.id] == nil && !flight.isCancelled {
            guard Paywalls.shared.hasFullAccess(to: flight),
                let forecast = store.forecasts[flight.id], forecast.isShown,
                flight.expectedDeparture < now.addingTimeInterval(Self.autoArmWindow),
                landing(of: flight, forecast: forecast) > now
            else { continue }
            arm(flight, forecast: forecast)
        }
    }

    /// After a sync: follow a real wheels-up, or a delay or departure the airline reported. Before
    /// the armed time it follows the latest estimate at the gate, and the real gate departure after
    /// it (an early pushback), earlier or later while takeoff is still ahead. Once the armed time
    /// has passed it only moves later, and only for news from a sync, so nothing jumps offline or
    /// back. Also picks up the latest forecast's stretches so the reminders match the app. A
    /// cancelled flight's countdown ends.
    func retimeArmed(now: Date = .now) {
        let store = FlightStore.shared
        for flight in store.flights {
            guard let timed = armed[flight.id], landings[flight.id] == nil else { continue }
            if flight.isCancelled {
                endCountdown(flight)
                continue
            }
            guard let forecast = store.forecasts[flight.id], forecast.isShown else { continue }
            let estimate = flight.estimatedTakeoff
            let target: Date
            if let real = takeoff(of: flight) {
                target = real
            } else if now < timed, now < flight.expectedDeparture, flight.status?.hasStatus == true || estimate > timed {
                // At the gate: the latest estimate, earlier or later (never the bare schedule).
                target = estimate
            } else if now < timed, estimate > now, awaitingWheelsUp(flight), leftGate(flight) {
                // Pushed back before the armed time (early, or after a delay that was cut short):
                // the real departure, earlier or later, while it's still taxiing by our estimate.
                target = estimate
            } else if awaitingWheelsUp(flight), estimate > timed {
                // A delay, or a later departure with no runway time, that came in after the armed
                // time passed.
                target = estimate
            } else {
                target = timed
            }
            if abs(timed.timeIntervalSince(target)) >= 60 {
                retime(flight, forecast: forecast, takeoff: target)
            } else {
                scheduleStretchReminders(flight, forecast: forecast, takeoff: timed)
            }
        }
    }

    /// No wheels-up yet (from the airline, a push or a tap), and not cancelled or diverted.
    private func awaitingWheelsUp(_ flight: Flight) -> Bool {
        takeoff(of: flight) == nil && !flight.isDisrupted
    }

    /// The airline reported the real gate departure (not an estimate), so the expected takeoff
    /// follows it.
    private func leftGate(_ flight: Flight) -> Bool {
        guard let status = flight.status else { return false }
        return status.hasStatus && status.departureActual != nil
    }

    /// A cancelled flight: its countdown, Live Activity and reminders end. Armed again only if a
    /// later status says it's flying after all.
    private func endCountdown(_ flight: Flight) {
        armed[flight.id] = nil
        persist()
        endActivity(flight.id)
        removeStretchReminders(flight.id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["landing-\(flight.id)", "boarding-\(flight.id)"])
        Paywalls.shared.updateAttributes()
    }

    /// "We've taken off". The tap is recorded, but when the airline's wheels-up is already known
    /// everything is timed to that, so the app and the Live Activity agree and nothing jumps later.
    func takeOff(_ flight: Flight, forecast: Forecast, at date: Date = .now) {
        takeoffs[flight.id] = date
        let time = takeoff(of: flight) ?? date
        armed[flight.id] = time
        trips[flight.id] = Self.trip(flight)
        dismissed.remove(flight.id)
        started.remove(flight.id)
        persist()
        startActivity(flight, forecast: forecast, takeoff: time, at: time)
        scheduleStretchReminders(flight, forecast: forecast, takeoff: time)
        Task { await scheduleLandingChecks() }
        Paywalls.shared.updateAttributes()
    }

    func land(_ flight: Flight, at date: Date = .now) {
        landings[flight.id] = date
        persist()
        let ids = ids(of: flight.id)
        Task {
            await endActivities(ids)
            try? await FlightStore.shared.service.endLiveActivity(flightID: flight.id)
        }
        removeStretchReminders(flight.id)
        Task { await scheduleLandingChecks() }
        Paywalls.shared.updateAttributes()
    }

    /// "Seatbelt sign is on", as minutes after takeoff. Kept on the phone and sent with the landing
    /// report; another tap within a couple of minutes is the same sign.
    func noteSeatbelt(_ flight: Flight, now: Date = .now) {
        let minute = max(0, Int(now.timeIntervalSince(effectiveTakeoff(of: flight)) / 60))
        if let last = seatbelts[flight.id]?.last, abs(minute - last) < 2 { return }
        seatbelts[flight.id, default: []].append(minute)
        persist()
    }

    /// Ends the flight's Live Activity, e.g. once it has been rated or the user tapped End. It
    /// stays gone until the user starts the countdown again; the reminders are left as they are.
    func endActivity(_ flightID: UUID) {
        let flightID = currentID(of: flightID)
        dismissed.insert(flightID)
        persist()
        let ids = ids(of: flightID)
        Task {
            await endActivities(ids)
            try? await FlightStore.shared.service.endLiveActivity(flightID: flightID)
        }
    }

    /// Clears taps, notes, the Live Activity (here and on the worker) and reminders, e.g. when a
    /// flight is deleted or its date or route is edited. An edited one is still listed, so the old
    /// ids it replaced keep leading to it (`keepAliases`), e.g. for its open screen.
    func forget(_ flightID: UUID, keepAliases: Bool = false) {
        // Before the old ids it replaced are let go below: their reminders go too.
        removeStretchReminders(flightID)
        let ids = ids(of: flightID)
        takeoffs[flightID] = nil
        landings[flightID] = nil
        armed[flightID] = nil
        pushedTakeoffs[flightID] = nil
        seatbelts[flightID] = nil
        trips[flightID] = nil
        dismissed.remove(flightID)
        started.remove(flightID)
        if !keepAliases { replaced = replaced.filter { $0.value != flightID } }
        persist()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["landing-\(flightID)", "boarding-\(flightID)"])
        Task {
            await endActivities(ids)
            try? await FlightStore.shared.service.endLiveActivity(flightID: flightID)
        }
    }

    /// Moves a trip's taps, countdown and notes to the flight that replaced it (the same trip
    /// under a new id). Its Live Activity and stretch reminders carry on as the new id's, so the
    /// countdown never stops; in the foreground the activity is swapped for one of the new id's
    /// own once that has a forecast, and the reminders are rescheduled with it.
    func rekey(from old: UUID, to new: UUID) {
        guard old != new else { return }
        takeoffs[new] = takeoffs[old] ?? takeoffs[new]
        landings[new] = landings[old] ?? landings[new]
        armed[new] = armed[old] ?? armed[new]
        pushedTakeoffs[new] = pushedTakeoffs[old] ?? pushedTakeoffs[new]
        seatbelts[new] = seatbelts[old] ?? seatbelts[new]
        trips[new] = trips[old] ?? trips[new]
        if dismissed.contains(old) { dismissed.insert(new) }
        if started.contains(old) { started.insert(new) }
        // The worker has the running activity's token under the old id: send it again for the new one.
        for activity in Activity<FlightActivityAttributes>.activities where owner(of: activity) == old {
            registeredTokens[activity.id] = nil
        }
        for (carried, current) in replaced where current == old { replaced[carried] = new }
        replaced[old] = new
        takeoffs[old] = nil
        landings[old] = nil
        armed[old] = nil
        pushedTakeoffs[old] = nil
        seatbelts[old] = nil
        trips[old] = nil
        dismissed.remove(old)
        started.remove(old)
        persist()
        activityVersion += 1
    }

    /// The id a flight is listed under now: the new id of one saved again, e.g. for a Live
    /// Activity's buttons, which keep the id the activity started with, or a screen open on the
    /// old id. Read in a view, it redraws on a re-key (which bumps activityVersion).
    func currentID(of flightID: UUID) -> UUID {
        _ = activityVersion
        return replaced[flightID] ?? flightID
    }

    /// Every id the flight's Live Activities and reminders can be under: its own, and old ids it replaced.
    private func ids(of flightID: UUID) -> Set<UUID> {
        Set(([flightID] + replaced.keys).filter { currentID(of: $0) == flightID })
    }

    /// The flight an activity belongs to now.
    private func owner(of activity: Activity<FlightActivityAttributes>) -> UUID {
        currentID(of: activity.attributes.flightID)
    }

    /// A flight that left the list (deleted on another device, or lost with an account) and came
    /// back under a new id keeps its countdown: same route, takeoff within 3 hours, and the new
    /// copy has no countdown of its own.
    private func adoptRecentTrips(now: Date = .now) {
        let store = FlightStore.shared
        guard store.syncedAt != nil else { return }
        let before = trips
        // Trips armed before they were recorded; drop the ones long past.
        for flight in store.flights where trips[flight.id] == nil && (takeoffs[flight.id] ?? armed[flight.id]) != nil {
            trips[flight.id] = Self.trip(flight)
        }
        trips = trips.filter { id, _ in
            guard let time = takeoffs[id] ?? armed[id] else { return false }
            return now.timeIntervalSince(time) < Self.tripMemory
        }
        let listed = Set(store.flights.map(\.id))
        // An old id is let go once the flight it leads to is gone: until then a screen, link or
        // notification for the old id still finds it, countdown or not.
        let carried = replaced
        replaced = replaced.filter { _, new in listed.contains(new) }
        if trips != before || replaced != carried { persist() }
        for (old, trip) in trips where !listed.contains(old) && landings[old] == nil {
            guard let timed = takeoffs[old] ?? armed[old] else { continue }
            let gap = { (flight: Flight) in abs(self.effectiveTakeoff(of: flight).timeIntervalSince(timed)) }
            let copy = store.flights
                .filter {
                    Self.trip($0) == trip && armed[$0.id] == nil && takeoffs[$0.id] == nil
                        && landings[$0.id] == nil && gap($0) <= Self.adoptWindow
                }
                .min { gap($0) < gap($1) }
            guard let copy else { continue }
            rekey(from: old, to: copy.id)
            if let forecast = store.forecasts[copy.id], forecast.isShown {
                scheduleStretchReminders(copy, forecast: forecast, takeoff: effectiveTakeoff(of: copy))
            }
        }
    }

    // MARK: Live Activity

    /// Whether a Live Activity for this flight is on the Lock Screen now.
    func hasActivity(_ flightID: UUID) -> Bool {
        _ = activityVersion
        return Activity<FlightActivityAttributes>.activities.contains {
            owner(of: $0) == flightID && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    /// Keeps every Live Activity in step with the flight list and the latest forecast. Runs on each
    /// foreground, after every sync and in background refreshes, one pass at a time. A background
    /// task can await the returned pass before it completes.
    @discardableResult
    func refreshActivities() -> Task<Void, Never> {
        adoptRecentTrips()
        let previous = reconciling
        let pass = Task {
            await previous?.value
            await reconcile()
            // And the stretch reminders queued so far, so a background task waiting on this pass
            // isn't suspended halfway through writing them.
            await reminderPass?.value
        }
        reconciling = pass
        return pass
    }

    /// Updates each running activity in place with the latest plan and effective takeoff, and
    /// registers its push token (retried every pass until the worker has it). Ends activities whose
    /// flight left the list. In the foreground, starts missing ones for armed flights, swaps a
    /// far-off scheduled one for an immediate one once departure is close, and swaps one carried
    /// over from a flight's old id for one of its own.
    private func reconcile() async {
        let store = FlightStore.shared
        let now = Date.now
        let inForeground = UIApplication.shared.applicationState == .active
        var seen: Set<UUID> = []
        // A flight's own activity before one carried over from its old id, so that's the one kept.
        let live = Activity<FlightActivityAttributes>.activities.filter { $0.activityState.isLive }
            .map { (id: $0.id, flightID: $0.attributes.flightID) }
            .sorted { replaced[$0.flightID] == nil && replaced[$1.flightID] != nil }
        for (id, startedFor) in live {
            // By id, so the activity is looked up fresh and never crosses isolation.
            guard let activity = Self.activity(id) else { continue }
            let flightID = currentID(of: startedFor)
            guard seen.insert(flightID).inserted else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            guard let flight = store.flight(flightID) else {
                // The list has synced (and the last sync worked), so the flight was deleted or
                // belongs to another account: its plan can't be kept up to date.
                if store.syncedAt != nil, !store.isOffline {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    activityVersion += 1
                    try? await store.service.endLiveActivity(flightID: flightID)
                }
                continue
            }
            if flight.isCancelled {
                // Not happening: its countdown ends (see retimeArmed).
                await activity.end(nil, dismissalPolicy: .immediate)
                activityVersion += 1
                continue
            }
            observePushToken(id: id)
            let current = activity.content.state
            followPushedTakeoff(flight, current, now: now)
            let forecast = store.forecasts[flightID].flatMap { $0.isShown && $0.durationMin != nil ? $0 : nil }
            let state = latestState(flight, current: current, forecast: forecast, takeoff: effectiveTakeoff(of: flight))
            // Kept for a while after landing so "How did it feel?" can be answered from it.
            if activity.attributes.landing(state).addingTimeInterval(Self.ratingWindow) < now {
                await activity.end(nil, dismissalPolicy: .immediate)
                activityVersion += 1
                continue
            }
            // Started for the flight's old id: the new id's own takes over (so its links and
            // buttons work) before this one ends. A showing one is only swapped for one that shows
            // now too, never for one scheduled later.
            if inForeground, activity.attributes.flightID != flightID, let forecast,
                activity.activityState == .pending || startsNow(flight, forecast, takeoff: state.takeoff, now: now),
                requestActivity(flight, forecast: forecast, takeoff: state.takeoff, at: showTime(flight, takeoff: state.takeoff))
            {
                await activity.end(nil, dismissalPolicy: .immediate)
                activityVersion += 1
                continue
            }
            // Up hours early (started by an earlier build, or the departure was delayed): it goes
            // back to coming up close to the flight.
            let show = showTime(flight, takeoff: state.takeoff)
            if inForeground, activity.activityState == .active, takeoff(of: flight) == nil, let forecast,
                show > now.addingTimeInterval(5 * 60),
                requestActivity(flight, forecast: forecast, takeoff: state.takeoff, at: show)
            {
                await activity.end(nil, dismissalPolicy: .immediate)
                activityVersion += 1
                continue
            }
            if inForeground, activity.activityState == .pending, let forecast, startsNow(flight, forecast, takeoff: state.takeoff, now: now) {
                await activity.end(nil, dismissalPolicy: .immediate)
                if !hasLiveActivity(flightID) { requestActivity(flight, forecast: forecast, takeoff: state.takeoff, at: now) }
                continue
            }
            await activity.update(ActivityContent(state: state, staleDate: activity.attributes.nextBoundary(after: now, state)))
            await registerToken(activityID: id)
        }
        guard inForeground else { return }
        // Armed flights with no activity: adopted trips, a request that couldn't run in the
        // background, or one the system ended at its 8-hour limit before landing. One the user
        // swiped away stays away (it's in `started`).
        for flight in store.flights
        where armed[flight.id] != nil && !dismissed.contains(flight.id) && landings[flight.id] == nil
            && !flight.isCancelled && !hasLiveActivity(flight.id) && mayRequest(flight.id)
        {
            guard let forecast = store.forecasts[flight.id], forecast.isShown, forecast.durationMin != nil,
                landing(of: flight, forecast: forecast) > now
            else { continue }
            let takeoff = effectiveTakeoff(of: flight)
            requestActivity(flight, forecast: forecast, takeoff: takeoff, at: showTime(flight, takeoff: takeoff))
        }
    }

    /// The worker pushes the airline's wheels-up straight to the Live Activity. When that came after
    /// the app's last sync, follow it here too, over a tap or an earlier push, so the app, reminders
    /// and Lock Screen agree until a sync brings the runway time. The app's own writes are never
    /// newer than its last sync (see `content`), so only a push passes.
    private func followPushedTakeoff(_ flight: Flight, _ state: FlightActivityAttributes.ContentState, now: Date) {
        guard flight.reportedTakeoff == nil, armed[flight.id] != nil, state.takeoff <= now,
            state.updatedAt > (FlightStore.shared.syncedAt ?? .distantPast),
            abs(state.takeoff.timeIntervalSince(effectiveTakeoff(of: flight))) >= 60
        else { return }
        pushedTakeoffs[flight.id] = state.takeoff
        armed[flight.id] = state.takeoff
        persist()
        if let forecast = FlightStore.shared.forecasts[flight.id], forecast.isShown {
            scheduleStretchReminders(flight, forecast: forecast, takeoff: state.takeoff)
            Task { await scheduleLandingChecks() }
        }
        Paywalls.shared.updateAttributes()
    }

    /// What a running activity should show: timed to `takeoff`, with the newest plan, the phone's
    /// forecast or one the worker pushed after it. A pushed plan is kept; when the takeoff moves or
    /// the airline reports the landing, its landing follows by the same rule as the app's.
    private func latestState(
        _ flight: Flight, current: FlightActivityAttributes.ContentState, forecast: Forecast?, takeoff: Date
    ) -> FlightActivityAttributes.ContentState {
        var state = current
        state.takeoff = takeoff
        guard let forecast else { return state }
        if current.durationMin != nil, let pushed = current.issuedAt, let saved = forecast.issuedAt, pushed > saved {
            let moved = abs(current.takeoff.timeIntervalSince(takeoff)) >= 1
            if moved {
                // The app's takeoff now, so it no longer reads as a push (see followPushedTakeoff).
                state.updatedAt = min(current.updatedAt, FlightStore.shared.syncedAt ?? .distantPast)
            }
            // A new takeoff changes how long it lasts, and so does a landing the airline reported
            // since the push: the Lock Screen lands when the app does.
            if moved || flight.status?.arrivalActual != nil, let planned = forecast.durationMin {
                let lastStretch = current.stretches?.map(\.endMin).max() ?? 0
                state.durationMin = Int(
                    Self.airMinutes(flight, planned: Double(planned), lastStretch: lastStretch, takeoff: takeoff))
            }
            return state
        }
        return content(flight, forecast, takeoff: takeoff)
    }

    /// The activity's whole state: the takeoff it's timed to and the latest forecast's plan. Every
    /// path (arming, takeoff, syncs) writes it the same way; the worker's push uses the same keys.
    private func content(_ flight: Flight, _ forecast: Forecast, takeoff: Date) -> FlightActivityAttributes.ContentState {
        FlightActivityAttributes.ContentState(
            takeoff: takeoff,
            // The last sync, never later: a newer time can only be a worker push.
            updatedAt: FlightStore.shared.syncedAt ?? .distantPast,
            // Lands when the app says it does (see `airMinutes`).
            durationMin: forecast.durationMin.map { _ in Int(Self.airMinutes(flight, forecast: forecast, takeoff: takeoff)) },
            stretches: Self.stretches(forecast, departure: flight.departureAt),
            confidenceTitle: forecast.confidence(departure: flight.departureAt).title,
            issuedAt: forecast.issuedAt)
    }

    /// The plan's stretches. On a global outlook each says whether it's outlook (approximate) or
    /// confirmed; elsewhere none is, and the flag is left out to keep the content small.
    private static func stretches(_ forecast: Forecast, departure: Date) -> [FlightActivityAttributes.Stretch] {
        forecast.segments.prefix(maxStretches).map {
            .init(
                startMin: $0.startMin, endMin: $0.endMin, severity: $0.severity.rawValue, phase: $0.phase,
                outlook: forecast.isGlobalOutlook ? forecast.isOutlook($0, departure: departure) : nil)
        }
    }

    /// When the countdown comes up: `showLead` before departure (or before a known takeoff, when
    /// that's earlier).
    private func showTime(_ flight: Flight, takeoff: Date) -> Date {
        min(flight.expectedDeparture, takeoff).addingTimeInterval(-Self.showLead)
    }

    /// Whether an activity requested now starts right away rather than scheduled: once its show
    /// time has passed.
    private func startsNow(_ flight: Flight, _ forecast: Forecast, takeoff: Date, now: Date) -> Bool {
        guard forecast.durationMin != nil else { return false }
        return showTime(flight, takeoff: takeoff) <= now
    }

    /// A new activity may be requested: none was started yet, or the system ended the last one at
    /// its 8-hour limit. One the user swiped away is dismissed, not ended, and stays away.
    private func mayRequest(_ flightID: UUID) -> Bool {
        !started.contains(flightID)
            || Activity<FlightActivityAttributes>.activities.contains { owner(of: $0) == flightID && $0.activityState == .ended }
    }

    /// Shows the countdown: the flight's running activity is updated in place (which also works in
    /// the background), else one is requested. A new activity can only be requested in the
    /// foreground, and a sync never brings back one that was already started (see `mayRequest`).
    private func startActivity(_ flight: Flight, forecast: Forecast, takeoff: Date, at start: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, !dismissed.contains(flight.id),
            forecast.durationMin != nil
        else { return }
        let flightID = flight.id
        Task {
            // By id, so each activity is looked up fresh and never crosses isolation.
            let running = liveActivities(flightID)
            let inForeground = UIApplication.shared.applicationState == .active
            guard let id = running.first else {
                // No suspension between this check and the request, so nothing can start a second one.
                if inForeground, mayRequest(flightID) {
                    requestActivity(flight, forecast: forecast, takeoff: takeoff, at: start)
                }
                return
            }
            for duplicate in running.dropFirst() {
                await Self.activity(duplicate)?.end(nil, dismissalPolicy: .immediate)
            }
            if inForeground, Self.activity(id)?.activityState == .pending, startsNow(flight, forecast, takeoff: takeoff, now: .now) {
                await Self.activity(id)?.end(nil, dismissalPolicy: .immediate)
                if !hasLiveActivity(flightID) { requestActivity(flight, forecast: forecast, takeoff: takeoff, at: .now) }
                return
            }
            observePushToken(id: id)
            if let first = Self.activity(id) {
                // A plan the worker pushed after the phone's forecast stays: only the takeoff moves.
                let state = latestState(flight, current: first.content.state, forecast: forecast, takeoff: takeoff)
                let content = ActivityContent(state: state, staleDate: first.attributes.nextBoundary(after: .now, state))
                await first.update(content)
            }
            await registerToken(activityID: id)
        }
    }

    /// Requests a new activity: scheduled for `start` unless it starts now (see `startsNow`), so its
    /// push token exists while there's still signal. Clears one the system ended for this flight.
    @discardableResult
    private func requestActivity(_ flight: Flight, forecast: Forecast, takeoff: Date, at start: Date) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let duration = forecast.durationMin else { return false }
        let state = content(flight, forecast, takeoff: takeoff)
        let attributes = FlightActivityAttributes(
            flightID: flight.id,
            route: flight.routeText,
            durationMin: duration,
            stretches: state.stretches ?? [],
            confidenceTitle: state.confidenceTitle ?? "Advance forecast",
            issuedAt: forecast.issuedAt)
        let now = Date.now
        let ended = Activity<FlightActivityAttributes>.activities
            .filter { owner(of: $0) == flight.id && $0.activityState == .ended }
            .map(\.id)
        let activity: Activity<FlightActivityAttributes>?
        if start > now, !startsNow(flight, forecast, takeoff: takeoff, now: now) {
            activity = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: attributes.nextBoundary(after: start, state)),
                pushType: .token, style: .standard,
                alertConfiguration: AlertConfiguration(
                    title: "Your bump countdown is on",
                    body: "We'll remind you a couple of minutes before each bumpy stretch.",
                    sound: .default),
                start: start)
        } else {
            activity = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: attributes.nextBoundary(after: now, state)),
                pushType: .token)
        }
        guard let id = activity?.id else { return false }
        started.insert(flight.id)
        persist()
        activityVersion += 1
        observePushToken(id: id)
        Task {
            // Off the Lock Screen: it can't be updated any more.
            for old in ended { await Self.activity(old)?.end(nil, dismissalPolicy: .immediate) }
            await registerToken(activityID: id)
        }
        return true
    }

    /// Scheduled, showing, or showing but out of date: still ours to update.
    private func hasLiveActivity(_ flightID: UUID) -> Bool {
        !liveActivities(flightID).isEmpty
    }

    /// The flight's live activities by id, its own before one carried over from an old id.
    private func liveActivities(_ flightID: UUID) -> [String] {
        Activity<FlightActivityAttributes>.activities
            .filter { owner(of: $0) == flightID && $0.activityState.isLive }
            .sorted { $0.attributes.flightID == flightID && $1.attributes.flightID != flightID }
            .map(\.id)
    }

    /// Ends every activity under these flight ids (a flight's own and old ones, see `ids(of:)`).
    private func endActivities(_ flightIDs: Set<UUID>) async {
        for activity in Activity<FlightActivityAttributes>.activities where flightIDs.contains(activity.attributes.flightID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activityVersion += 1
    }

    /// By id: the activity is looked up again inside each task, so it never crosses isolation.
    private nonisolated static func activity(_ id: String) -> Activity<FlightActivityAttributes>? {
        Activity<FlightActivityAttributes>.activities.first { $0.id == id }
    }

    /// Sends the activity's push token to the worker whenever it changes, and once a scheduled
    /// activity starts, so the airline's wheels-up can re-time the countdown with the app closed.
    private func observePushToken(id: String) {
        guard observedTokens.insert(id).inserted else { return }
        Task {
            guard let activity = Self.activity(id) else {
                observedTokens.remove(id)
                return
            }
            for await token in activity.pushTokenUpdates {
                await registerToken(activityID: id, token: token)
            }
        }
        Task {
            guard let activity = Self.activity(id) else { return }
            for await state in activity.activityStateUpdates {
                switch state {
                case .active: await registerToken(activityID: id)
                case .ended:
                    // The system's 8-hour limit, say: with the app open it starts again now.
                    activityVersion += 1
                    if UIApplication.shared.applicationState == .active { refreshActivities() }
                    return
                case .dismissed:
                    activityVersion += 1
                    return
                default: break
                }
            }
        }
    }

    /// Sends the token unless the worker already has it. Only for this account's flights (the
    /// server refuses others); a failed send (offline, signed out) is retried on the next pass.
    private func registerToken(activityID: String, token: Data? = nil) async {
        guard let activity = Self.activity(activityID), let data = token ?? activity.pushToken else { return }
        let token = data.map { String(format: "%02x", $0) }.joined()
        let flightID = owner(of: activity)
        guard registeredTokens[activityID] != token, FlightStore.shared.flight(flightID) != nil,
            registering.insert(activityID).inserted
        else { return }
        defer { registering.remove(activityID) }
        do {
            try await FlightStore.shared.service.registerLiveActivity(
                flightID: flightID, token: token, environment: Self.environment)
            registeredTokens[activityID] = token
        } catch {
            // Retried on the next refresh.
        }
    }

    // MARK: Local reminders

    /// Reminders before each stretch of the plan, timed to `takeoff`, in place of the flight's
    /// earlier ones (see `queueStretchReminders`).
    private func scheduleStretchReminders(_ flight: Flight, forecast: Forecast, takeoff: Date) {
        queueStretchReminders(flight.id, plan: (flight, forecast, takeoff))
    }

    /// Removes the flight's stretch reminders, and any still under an old id it replaced.
    private func removeStretchReminders(_ flightID: UUID) {
        queueStretchReminders(flightID, plan: nil)
    }

    /// One pass at a time, after any pass already running: it removes the flight's stretch
    /// reminders (by prefix, so every stretch of any length of flight, and old ids too), then adds
    /// the plan's. A pass stops adding as soon as a newer one for the flight is queued, so nothing
    /// is put back on a stale takeoff after a newer pass removed it.
    private func queueStretchReminders(_ flightID: UUID, plan: (flight: Flight, forecast: Forecast, takeoff: Date)?) {
        let run = (reminderRuns[flightID] ?? 0) + 1
        reminderRuns[flightID] = run
        // Now, while the old ids it replaced are still known (forget lets them go).
        let prefixes = ids(of: flightID).map { "stretch-\($0)-" }
        let previous = reminderPass
        reminderPass = Task {
            await previous?.value
            let isLatest = { self.reminderRuns[flightID] == run }
            guard isLatest() else { return }
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests().map(\.identifier)
                .filter { id in prefixes.contains { id.hasPrefix($0) } }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            guard let (flight, forecast, takeoff) = plan else { return }
            for segment in forecast.segments {
                guard isLatest() else { return }
                let fire = takeoff.addingTimeInterval(TimeInterval(segment.startMin * 60) - Self.leadTime)
                guard fire > .now else { continue }
                let content = UNMutableNotificationContent()
                if forecast.isOutlook(segment, departure: flight.departureAt) {
                    // Outlook stretches are approximate: no exact level or length.
                    let range = segment.outlookRange(warning: forecast.warning(for: segment))
                    content.title = "Bumps possible soon"
                    content.body = "\(range), for around \(segment.minutes.roughMinutes.durationText). Tap for a slow breathing exercise."
                } else {
                    content.title = "\(segment.severity.phrase.sentenceCased) in about 2 minutes"
                    content.body = "\(segment.severity.feelsLike) Lasts about \(segment.minutes) min. Tap for a slow breathing exercise."
                }
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.userInfo = ["flight_id": flight.id.uuidString, "kind": "stretch"]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
                try? await center.add(
                    UNNotificationRequest(identifier: "stretch-\(flight.id)-\(segment.startMin)", content: content, trigger: trigger))
            }
        }
    }

    /// The flight that continues this trip: it leaves from where this one lands, within a day.
    func connection(after flight: Flight) -> Flight? {
        let store = FlightStore.shared
        let landed = landing(of: flight, forecast: store.forecasts[flight.id])
        return store.flights
            .filter {
                $0.id != flight.id && $0.origin == flight.destination
                    && $0.departureAt > landed && $0.departureAt < landed.addingTimeInterval(24 * 3600)
            }
            .min { $0.departureAt < $1.departureAt }
    }

    /// "How bumpy was it?" shortly after each flight with a forecast lands, unless already answered.
    /// At a connection the same message also gives the next flight's outlook, so a trip gets one
    /// notification per landing, not two.
    func scheduleLandingChecks() async {
        let center = UNUserNotificationCenter.current()
        let store = FlightStore.shared
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("landing-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for flight in store.flights
        where store.reports[flight.id] == nil && store.forecasts[flight.id]?.isShown == true && !flight.isCancelled {
            let fire = landing(of: flight, forecast: store.forecasts[flight.id]).addingTimeInterval(Self.landingCheckDelay)
            guard fire > .now, fire < .now.addingTimeInterval(7 * 86400) else { continue }
            let city = flight.destinationAirport?.city ?? "your destination"
            let beta = store.forecasts[flight.id]?.isGlobalOutlook == true
            let helps = beta ? "Two taps help us improve our beta global outlook." : "Two taps help our forecasts."
            let content = UNMutableNotificationContent()
            if let next = connection(after: flight) {
                content.title = "Landed in \(city)"
                let onward = next.destinationAirport?.city ?? next.destination
                if let nextForecast = store.forecasts[next.id], nextForecast.isShown, let grade = nextForecast.grade {
                    let headline = nextForecast.isGlobalOutlook ? grade.outlookHeadline : grade.headline
                    content.body = "How was that leg? \(helps) Next, to \(onward): \(headline)"
                } else {
                    content.body = "How was that leg? \(helps) Next up: your flight to \(onward)."
                }
            } else {
                content.title = "Welcome to \(city)"
                content.body = beta
                    ? GlobalOutlookCopy.landingBody()
                    : "How bumpy was it? Two taps help us make every forecast more accurate."
            }
            content.sound = .default
            content.userInfo = ["flight_id": flight.id.uuidString, "kind": "landing"]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "landing-\(flight.id)", content: content, trigger: trigger))
        }
    }

    /// When the boarding card appears (an hour before departure).
    static let boardingLead: TimeInterval = 3600

    /// "Boarding soon": one calm note an hour before each flight with a forecast, written from the
    /// forecast saved on the phone. With the countdown it confirms it's ready; without it, it offers
    /// to set it up while there's still signal at the gate.
    func scheduleBoardingReminders(now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        let store = FlightStore.shared
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("boarding-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for flight in store.flights where takeoffs[flight.id] == nil && flight.notify && !flight.isCancelled {
            guard let forecast = store.forecasts[flight.id], forecast.isShown, let grade = forecast.grade else { continue }
            let headline = forecast.isGlobalOutlook ? grade.outlookHeadline : grade.headline
            let fire = flight.expectedDeparture.addingTimeInterval(-Self.boardingLead)
            guard fire > now, fire < now.addingTimeInterval(7 * 86400) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Boarding soon: \(flight.routeText)"
            content.body = Paywalls.shared.hasFullAccess(to: flight)
                ? "\(headline) Your bump countdown is ready, with a reminder before each bumpy stretch."
                : "\(headline) Get your bump countdown ready before you board."
            content.sound = .default
            content.userInfo = ["flight_id": flight.id.uuidString, "kind": "boarding"]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSince(now), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "boarding-\(flight.id)", content: content, trigger: trigger))
        }
    }

    private static func trip(_ flight: Flight) -> String { "\(flight.origin)-\(flight.destination)" }

    private func persist() {
        for (name, values) in [("takeoffs", takeoffs), ("landings", landings), ("armed", armed), ("pushedTakeoffs", pushedTakeoffs)] {
            defaults.set(
                Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }),
                forKey: name)
        }
        defaults.set(dismissed.map(\.uuidString), forKey: "dismissed")
        defaults.set(started.map(\.uuidString), forKey: "activityStarted")
        defaults.set(Dictionary(uniqueKeysWithValues: trips.map { ($0.key.uuidString, $0.value) }), forKey: "trips")
        defaults.set(Dictionary(uniqueKeysWithValues: seatbelts.map { ($0.key.uuidString, $0.value) }), forKey: "seatbelts")
        defaults.set(
            Dictionary(uniqueKeysWithValues: replaced.map { ($0.key.uuidString, $0.value.uuidString) }), forKey: "replacedFlights")
    }

    private static func load(_ name: String, from defaults: UserDefaults) -> [UUID: Date] {
        guard let saved = defaults.dictionary(forKey: name) as? [String: Double] else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: saved.compactMap { k, v in UUID(uuidString: k).map { ($0, Date(timeIntervalSince1970: v)) } })
    }

    private static func loadByID<Value>(_ name: String, from defaults: UserDefaults) -> [UUID: Value] {
        guard let saved = defaults.dictionary(forKey: name) as? [String: Value] else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    private static func loadSet(_ name: String, from defaults: UserDefaults) -> Set<UUID> {
        Set((defaults.stringArray(forKey: name) ?? []).compactMap(UUID.init(uuidString:)))
    }
}

private extension ActivityState {
    /// Scheduled, showing, or showing but out of date: an activity that's still ours to update.
    var isLive: Bool { self == .pending || self == .active || self == .stale }
}
