import ActivityKit
import Foundation
import Observation
import UserNotifications

/// Arming at the gate schedules the Live Activity for departure and local reminders before each
/// bumpy stretch; "We've taken off" re-times both to the real wheels-up. Everything works offline,
/// which is the point: there's usually no signal up there.
@Observable @MainActor
final class InFlight {
    static let shared = InFlight()

    /// Actual takeoff and landing times the user tapped, by flight. Persisted across relaunches.
    private(set) var takeoffs: [UUID: Date] = [:]
    private(set) var landings: [UUID: Date] = [:]
    /// Flights armed on the ground, with the takeoff the countdown was timed to. Persisted too.
    private(set) var armed: [UUID: Date] = [:]

    private let defaults = UserDefaults.standard
    /// Remind a little before each stretch so there's time to settle in.
    static let leadTime: TimeInterval = 2 * 60
    static let landingCheckDelay: TimeInterval = 15 * 60
    /// How long the Live Activity stays after landing to collect the rating.
    static let ratingWindow: TimeInterval = 30 * 60

    init() {
        takeoffs = Self.load("takeoffs", from: defaults)
        landings = Self.load("landings", from: defaults)
        armed = Self.load("armed", from: defaults)
    }

    func takeoff(of flight: Flight) -> Date? { takeoffs[flight.id] }

    /// Best estimate of wheels-up: the tapped time, else the schedule.
    func effectiveTakeoff(of flight: Flight) -> Date { takeoffs[flight.id] ?? flight.estimatedTakeoff }

    func landing(of flight: Flight, forecast: Forecast?) -> Date {
        if let landed = landings[flight.id] { return landed }
        guard let tapped = takeoffs[flight.id] else { return flight.estimatedLanding(forecast) }
        let minutes = forecast?.durationMin.map(Double.init) ?? flight.estimatedAirMinutes
        return tapped.addingTimeInterval(minutes * 60)
    }

    func isArmed(_ flight: Flight) -> Bool { armed[flight.id] != nil }

    /// Flying once a tapped takeoff, or the estimated one for an armed flight, has passed.
    func isFlying(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Bool {
        guard takeoffs[flight.id] != nil || armed[flight.id] != nil else { return false }
        return effectiveTakeoff(of: flight) <= now && now < landing(of: flight, forecast: forecast)
    }

    /// Minutes since takeoff while flying, for the "you are here" marker.
    func elapsedMinutes(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Int? {
        guard isFlying(flight, forecast: forecast, now: now) else { return nil }
        return Int(now.timeIntervalSince(effectiveTakeoff(of: flight)) / 60)
    }

    /// The takeoff button shows from an hour before departure until the estimated landing.
    func canTakeOff(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Bool {
        takeoffs[flight.id] == nil
            && now >= flight.departureAt.addingTimeInterval(-3600)
            && now < flight.estimatedLanding(forecast)
    }

    /// Before departure, arm the countdown; once it's past, the user is telling us they took off.
    func getReady(_ flight: Flight, forecast: Forecast, now: Date = .now) {
        if now < flight.expectedDeparture {
            arm(flight, forecast: forecast)
        } else {
            takeOff(flight, forecast: forecast, at: now)
        }
    }

    /// On the ground: the Live Activity starts at departure (live when known, else scheduled) and
    /// reminders are timed to the estimated wheels-up. A later "We've taken off" re-times both.
    func arm(_ flight: Flight, forecast: Forecast) {
        let takeoff = flight.estimatedTakeoff
        armed[flight.id] = takeoff
        persist()
        startActivity(flight, forecast: forecast, takeoff: takeoff, at: flight.expectedDeparture)
        Task { await scheduleStretchReminders(flight, forecast: forecast, takeoff: takeoff) }
        Task { await scheduleLandingChecks() }
        Paywalls.shared.updateAttributes()
    }

    /// Pro and passholders don't have to remember to tap: a flight leaving within this window is
    /// armed on the next sync, so the countdown and reminders are ready even with no signal later.
    static let autoArmWindow: TimeInterval = 24 * 3600

    /// After a sync: arm upcoming flights for people who have the countdown.
    func armUpcoming(now: Date = .now) {
        let store = FlightStore.shared
        for flight in store.flights
        where armed[flight.id] == nil && takeoffs[flight.id] == nil && landings[flight.id] == nil {
            guard Paywalls.shared.hasFullAccess(to: flight),
                let forecast = store.forecasts[flight.id], forecast.isShown,
                flight.expectedDeparture > now, flight.expectedDeparture < now.addingTimeInterval(Self.autoArmWindow)
            else { continue }
            arm(flight, forecast: forecast)
        }
    }

    /// After a sync: follow delays for armed flights that haven't been tapped yet, and pick up the
    /// latest forecast's stretches so the reminders match what the app shows.
    func retimeArmed() {
        let store = FlightStore.shared
        for flight in store.flights {
            guard let timed = armed[flight.id], takeoffs[flight.id] == nil, landings[flight.id] == nil,
                let forecast = store.forecasts[flight.id], forecast.isShown
            else { continue }
            if abs(timed.timeIntervalSince(flight.estimatedTakeoff)) >= 60 {
                arm(flight, forecast: forecast)
            } else {
                Task { await scheduleStretchReminders(flight, forecast: forecast, takeoff: timed) }
            }
        }
    }

    func takeOff(_ flight: Flight, forecast: Forecast, at date: Date = .now) {
        takeoffs[flight.id] = date
        persist()
        startActivity(flight, forecast: forecast, takeoff: date, at: date)
        Task { await scheduleStretchReminders(flight, forecast: forecast, takeoff: date) }
        Task { await scheduleLandingChecks() }
        Paywalls.shared.updateAttributes()
    }

    func land(_ flight: Flight, at date: Date = .now) {
        landings[flight.id] = date
        persist()
        Task {
            for activity in Activity<FlightActivityAttributes>.activities where activity.attributes.flightID == flight.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: stretchIdentifiers(flight.id))
        Task { await scheduleLandingChecks() }
        Paywalls.shared.updateAttributes()
    }

    /// Ends the flight's Live Activity, e.g. once it has been rated.
    func endActivity(_ flightID: UUID) {
        Task {
            for activity in Activity<FlightActivityAttributes>.activities where activity.attributes.flightID == flightID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Clears taps, the Live Activity and reminders, e.g. when a flight's date or route is edited.
    func forget(_ flightID: UUID) {
        takeoffs[flightID] = nil
        landings[flightID] = nil
        armed[flightID] = nil
        persist()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: stretchIdentifiers(flightID) + ["landing-\(flightID)", "boarding-\(flightID)"])
        Task {
            for activity in Activity<FlightActivityAttributes>.activities where activity.attributes.flightID == flightID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Refresh "next stretch" on the Live Activity whenever the app runs.
    func refreshActivities() {
        Task {
            for activity in Activity<FlightActivityAttributes>.activities {
                var state = activity.content.state
                let landing = activity.attributes.landing(state)
                // Kept for a while after landing so "How did it feel?" can be answered from it.
                if landing.addingTimeInterval(Self.ratingWindow) < .now {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    continue
                }
                state.updatedAt = .now
                let stale = activity.attributes.nextBoundary(after: .now, state)
                await activity.update(ActivityContent(state: state, staleDate: stale))
            }
        }
    }

    // MARK: Live Activity

    /// Starts the activity now, or schedules it to start at `start` when that's still ahead.
    private func startActivity(_ flight: Flight, forecast: Forecast, takeoff: Date, at start: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let duration = forecast.durationMin else { return }
        let attributes = FlightActivityAttributes(
            flightID: flight.id,
            route: flight.routeText,
            durationMin: duration,
            stretches: forecast.segments.map {
                .init(startMin: $0.startMin, endMin: $0.endMin, severity: $0.severity.rawValue, phase: $0.phase)
            },
            confidenceTitle: forecast.confidence(departure: flight.departureAt).title,
            issuedAt: forecast.issuedAt)
        let state = FlightActivityAttributes.ContentState(takeoff: takeoff, updatedAt: .now)
        Task {
            for activity in Activity<FlightActivityAttributes>.activities where activity.attributes.flightID == flight.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let content = ActivityContent(state: state, staleDate: attributes.nextBoundary(after: max(start, .now), state))
            if start > .now.addingTimeInterval(60) {
                _ = try? Activity.request(
                    attributes: attributes, content: content, pushType: nil, style: .standard,
                    alertConfiguration: AlertConfiguration(
                        title: "Your bump countdown is on",
                        body: "We'll remind you a couple of minutes before each bumpy stretch.",
                        sound: .default),
                    start: start)
            } else {
                _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            }
        }
    }

    // MARK: Local reminders

    private func stretchIdentifiers(_ flightID: UUID) -> [String] {
        (0..<600).map { "stretch-\(flightID)-\($0)" }
    }

    private func scheduleStretchReminders(_ flight: Flight, forecast: Forecast, takeoff: Date) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: stretchIdentifiers(flight.id))
        for segment in forecast.segments {
            let fire = takeoff.addingTimeInterval(TimeInterval(segment.startMin * 60) - Self.leadTime)
            guard fire > .now else { continue }
            let content = UNMutableNotificationContent()
            if forecast.isOutlook(segment, departure: flight.departureAt) {
                // Outlook stretches are approximate: no exact level or length.
                let range = segment.outlookRange(warning: forecast.warning(for: segment))
                content.title = "Bumps possible soon"
                content.body = "\(range), for around \(segment.minutes.roughMinutes.durationText). Tap for a slow breathing exercise."
            } else {
                content.title = "\(segment.severity.title) in about 2 minutes"
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
        for flight in store.flights where store.reports[flight.id] == nil && store.forecasts[flight.id]?.isShown == true {
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
        for flight in store.flights where takeoffs[flight.id] == nil && flight.notify {
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

    private func persist() {
        for (name, values) in [("takeoffs", takeoffs), ("landings", landings), ("armed", armed)] {
            defaults.set(
                Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }),
                forKey: name)
        }
    }

    private static func load(_ name: String, from defaults: UserDefaults) -> [UUID: Date] {
        guard let saved = defaults.dictionary(forKey: name) as? [String: Double] else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: saved.compactMap { k, v in UUID(uuidString: k).map { ($0, Date(timeIntervalSince1970: v)) } })
    }
}
