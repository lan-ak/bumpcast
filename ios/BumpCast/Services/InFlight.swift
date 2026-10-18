import ActivityKit
import Foundation
import Observation
import UserNotifications

/// "We've taken off": starts the Live Activity and schedules local reminders before each
/// bumpy stretch. Both work offline, which is the point: there's usually no signal up there.
@Observable @MainActor
final class InFlight {
    static let shared = InFlight()

    /// Actual takeoff and landing times the user tapped, by flight. Persisted across relaunches.
    private(set) var takeoffs: [UUID: Date] = [:]
    private(set) var landings: [UUID: Date] = [:]

    private let defaults = UserDefaults.standard
    /// Remind a little before each stretch so there's time to settle in.
    static let leadTime: TimeInterval = 2 * 60
    static let landingCheckDelay: TimeInterval = 15 * 60
    /// How long the Live Activity stays after landing to collect the rating.
    static let ratingWindow: TimeInterval = 30 * 60

    init() {
        takeoffs = Self.load("takeoffs", from: defaults)
        landings = Self.load("landings", from: defaults)
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

    func isFlying(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Bool {
        guard let tapped = takeoffs[flight.id] else { return false }
        return tapped <= now && now < landing(of: flight, forecast: forecast)
    }

    /// Minutes since takeoff while flying, for the "you are here" marker.
    func elapsedMinutes(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Int? {
        guard isFlying(flight, forecast: forecast, now: now), let tapped = takeoffs[flight.id] else { return nil }
        return Int(now.timeIntervalSince(tapped) / 60)
    }

    /// The takeoff button shows from an hour before departure until the estimated landing.
    func canTakeOff(_ flight: Flight, forecast: Forecast?, now: Date = .now) -> Bool {
        takeoffs[flight.id] == nil
            && now >= flight.departureAt.addingTimeInterval(-3600)
            && now < flight.estimatedLanding(forecast)
    }

    func takeOff(_ flight: Flight, forecast: Forecast, at date: Date = .now) {
        takeoffs[flight.id] = date
        persist()
        startActivity(flight, forecast: forecast, takeoff: date)
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
        persist()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: stretchIdentifiers(flightID) + ["landing-\(flightID)"])
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

    private func startActivity(_ flight: Flight, forecast: Forecast, takeoff: Date) {
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
            _ = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: attributes.nextBoundary(after: .now, state)),
                pushType: nil)
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
            content.title = "\(segment.severity.title) in about 2 minutes"
            content.body = "\(segment.severity.feelsLike) Lasts about \(segment.minutes) min. Tap for a slow breathing exercise."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["flight_id": flight.id.uuidString, "kind": "stretch"]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            try? await center.add(
                UNNotificationRequest(identifier: "stretch-\(flight.id)-\(segment.startMin)", content: content, trigger: trigger))
        }
    }

    /// "How bumpy was it?" shortly after each upcoming flight lands, unless already answered.
    func scheduleLandingChecks() async {
        let center = UNUserNotificationCenter.current()
        let store = FlightStore.shared
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("landing-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for flight in store.flights where store.reports[flight.id] == nil && Coverage.covers(flight) {
            let fire = landing(of: flight, forecast: store.forecasts[flight.id]).addingTimeInterval(Self.landingCheckDelay)
            guard fire > .now, fire < .now.addingTimeInterval(7 * 86400) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Welcome to \(flight.destinationAirport?.city ?? "your destination")"
            content.body = "How bumpy was it? Two taps help us make every forecast more accurate."
            content.sound = .default
            content.userInfo = ["flight_id": flight.id.uuidString, "kind": "landing"]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "landing-\(flight.id)", content: content, trigger: trigger))
        }
    }

    private func persist() {
        for (name, values) in [("takeoffs", takeoffs), ("landings", landings)] {
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
