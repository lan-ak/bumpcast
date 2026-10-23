import SuperwallKit
import SwiftUI
import UIKit

/// The onboarding flow's "add your flight" step for people flying soon. The Superwall page asks
/// the app, through custom callbacks, to add the flight natively and then to wait for its first
/// forecast, so the flow moves straight on to its paywall with nothing new to present.
///
/// - `add_flight`: opens Add flight over the flow. Returns the saved flight, or fails with
///   `reason` "cancelled" (the user closed it) or "unavailable" (it couldn't open).
/// - `flight_forecast` (`flight_id`): waits up to 20 s for the first forecast. Returns `state`
///   (ready | pending | too_early | out_of_coverage), and the grade when ready. Never when or how
///   long the bumps are: that's what the paywall sells.
@MainActor
enum OnboardingFlight {
    static let addFlightCallback = "add_flight"
    static let forecastCallback = "flight_forecast"

    /// The flight added during onboarding, so a relaunch mid-flow doesn't ask for it again.
    private static let flightKey = "onboarding.flightID"
    private static let forecastWait: Duration = .seconds(20)
    private static let forecastPoll: Duration = .seconds(1)

    static var flightID: UUID? {
        UserDefaults.standard.string(forKey: flightKey).flatMap(UUID.init)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: flightKey)
    }

    static func handle(_ callback: CustomCallback) async -> CustomCallbackResult {
        switch callback.name {
        case addFlightCallback:
            return await addFlight()
        case forecastCallback:
            let id = (callback.variables?["flight_id"] as? String).flatMap(UUID.init)
            return await forecast(for: id)
        default:
            return .failure()
        }
    }

    // MARK: add_flight

    private static func addFlight() async -> CustomCallbackResult {
        let store = FlightStore.shared
        if let id = flightID, let flight = store.flight(id), flight.departureAt > .now {
            Paywalls.shared.sellPass(for: flight.id)
            return .success(data: data(for: flight))
        }
        // Anonymous sign-in runs alongside the flow and is normally long done; saving needs it.
        for _ in 0..<50 where store.userID == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        switch await present() {
        case .saved(let flight) where store.isPending(flight.id):
            // Saved on the phone only (offline): no forecast or purchase can happen now, so the
            // flow goes on to its closable plans rather than the flight's paywall.
            return .failure(data: ["reason": "unavailable"])
        case .saved(let flight):
            UserDefaults.standard.set(flight.id.uuidString, forKey: flightKey)
            Paywalls.shared.sellPass(for: flight.id)
            return .success(data: data(for: flight))
        case .cancelled:
            return .failure(data: ["reason": "cancelled"])
        case .unavailable:
            return .failure(data: ["reason": "unavailable"])
        }
    }

    private enum Outcome {
        case saved(Flight)
        case cancelled
        case unavailable
    }

    /// Add flight, presented over the onboarding flow (Superwall presents it from UIKit, so a
    /// SwiftUI sheet from the app's root would open behind it).
    private static func present() async -> Outcome {
        guard let top = topViewController() else { return .unavailable }
        // An earlier error (a launch sync, say) would otherwise greet them as the sheet opens.
        FlightStore.shared.error = nil
        return await withCheckedContinuation { continuation in
            weak var host: UIViewController?
            var resumed = false
            // Exactly once, whichever comes first: Add flight finishing, or the sheet going away
            // some other way (the flow itself dismissed under it), so the page always hears back.
            let finish = { (outcome: Outcome) in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            let view = AddFlightView(onboarding: { flight in
                host?.dismiss(animated: true)
                finish(flight.map(Outcome.saved) ?? .cancelled)
            })
            .environment(FlightStore.shared)
            .environment(Router.shared)
            .environment(Paywalls.shared)
            .environment(PushNotifications.shared)
            .environment(InFlight.shared)
            .bumpCastTheme()
            .nightAppearanceAfterDark()
            .onDisappear { finish(.cancelled) }
            let controller = UIHostingController(rootView: view)
            // Swiping down would skip Cancel; Cancel and Add flight are the ways out.
            controller.isModalInPresentation = true
            host = controller
            top.present(controller, animated: true)
            // UIKit drops a presentation it can't make (the flow mid-transition), without a word.
            if top.presentedViewController !== controller { finish(.unavailable) }
        }
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private static func data(for flight: Flight) -> [String: Any] {
        let zone = flight.originAirport?.timeZone ?? .current
        var data: [String: Any] = [
            "flight_id": flight.id.uuidString,
            "route": flight.routeText,
            "origin": flight.originAirport?.iata ?? flight.origin,
            "destination": flight.destinationAirport?.iata ?? flight.destination,
            "departure_at": flight.departureAt.formatted(.iso8601),
            // The page shows the departure in the airport's time, like the rest of the app.
            "origin_utc_offset_minutes": zone.secondsFromGMT(for: flight.departureAt) / 60,
            "hours_to_departure": (flight.departureAt.timeIntervalSinceNow / 3600).rounded(),
            "forecast_unlocks_at": flight.forecastUnlocksAt.formatted(.iso8601),
        ]
        data["flight_number"] = flight.flightNumber
        return data
    }

    // MARK: flight_forecast

    private static func forecast(for id: UUID?) async -> CustomCallbackResult {
        let store = FlightStore.shared
        guard let id, let flight = store.flight(id) else { return .failure() }
        // A flight we can't forecast is never sold on the hard paywall, so this is checked first
        // (as the worker will decide), rather than waiting or calling it "too early".
        guard Coverage.covers(flight) || GlobalBeta.shared.isOn else {
            return .success(data: ["state": "out_of_coverage"])
        }
        // More than 48 h out there's nothing to wait for.
        if flight.forecastUnlocksAt > .now { return .success(data: ["state": "too_early"]) }
        let deadline = ContinuousClock.now + forecastWait
        while true {
            await store.refreshForecast(id)
            if let forecast = store.forecasts[id] {
                switch forecast.status {
                case .ready:
                    var data: [String: Any] = [
                        "state": "ready",
                        "confidence": forecast.confidence(departure: flight.departureAt).attributeValue,
                    ]
                    if let grade = forecast.grade {
                        data["grade"] = grade.rawValue
                        data["grade_title"] = grade.title
                    }
                    return .success(data: data)
                case .tooEarly where flight.forecastUnlocksAt > .now:
                    return .success(data: ["state": "too_early"])
                case .tooEarly:
                    break  // the window has just opened; the real forecast is on its way
                case .outOfCoverage:
                    return .success(data: ["state": "out_of_coverage"])
                }
            }
            guard ContinuousClock.now + forecastPoll < deadline else { break }
            try? await Task.sleep(for: forecastPoll)
        }
        return .success(data: ["state": "pending"])
    }
}
