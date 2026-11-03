import Foundation
import Mixpanel
import SuperwallKit

/// What people do in the app, sent to Superwall and Mixpanel. Superwall has no other way in, so
/// each event is registered as a placement, but these are only there to be counted: **no event
/// ever gets a campaign**, or a paywall would show in the middle of what the user was doing. The
/// paywall moments stay in `Placement`. See SUPERWALL.md, "Events".
///
/// Mixpanel gets the same events with the same params, under the same user id (the Supabase
/// account), plus Superwall's own paywall and purchase events (`forward`) and the user
/// attributes as the profile, so it holds the whole picture.
///
/// Unlike the paywall moments, events fire for everyone, Pro or free, online or not (both SDKs
/// queue them). Params are fixed values only: no free text, emails or account ids.
@MainActor
enum Analytics {
    enum Event: String, CaseIterable {
        // Adding and keeping flights
        case flightAddStarted = "flight_add_started"
        case flightSearched = "flight_searched"
        case flightSaved = "flight_saved"
        case flightSaveFailed = "flight_save_failed"
        case flightEdited = "flight_edited"
        case flightDeleted = "flight_deleted"
        case flightOpened = "flight_opened"
        case forecastConfirmedSeen = "forecast_confirmed_seen"
        // Notifications
        case notificationOpened = "notification_opened"
        case notificationPromptAnswered = "notification_prompt_answered"
        // In the air
        case countdownStarted = "countdown_started"
        case tookOff = "took_off"
        case landed
        case seatbeltTapped = "seatbelt_tapped"
        case landingRated = "landing_rated"
        case reviewRequested = "review_requested"
        // What people use
        case tabViewed = "tab_viewed"
        case breathingStarted = "breathing_started"
        case breathingFinished = "breathing_finished"
        case explainerOpened = "explainer_opened"
        case mapOpened = "map_opened"
        case pilotReportsToggled = "pilot_reports_toggled"
        case pilotReportTapped = "pilot_report_tapped"
        case globalOutlookSet = "global_outlook_set"
        case waitlistJoined = "waitlist_joined"
        case hapticsSet = "haptics_set"
        case restoreFinished = "restore_finished"
        case manageSubscriptionOpened = "manage_subscription_opened"
        case onboardingFellBack = "onboarding_fell_back"
        case onboardingFinished = "onboarding_finished"
        case onboardingFlightResult = "onboarding_flight_result"
        // When it goes wrong (once per session each)
        case syncFailed = "sync_failed"
        case mapLoadFailed = "map_load_failed"
        case lockUnavailable = "lock_unavailable"
        case flightLinkMissing = "flight_link_missing"
        case passLateRecorded = "pass_late_recorded"
        case passRejected = "pass_rejected"
        case pushRegistrationFailed = "push_registration_failed"
        // Email import (reachable once EmailImport.isReady is on in Release)
        case emailConnectFinished = "email_connect_finished"
        case emailScanFinished = "email_scan_finished"
        case emailFlightDismissed = "email_flight_dismissed"
        case emailDisconnected = "email_disconnected"
    }

    static func log(_ event: Event, _ params: [String: Any] = [:]) {
        #if DEBUG
            sent.append((event, params))
            if sent.count > 100 { sent.removeFirst() }
        #endif
        mixpanel?.track(event: event.rawValue, properties: properties(params))
        guard Paywalls.shared.isConfigured else { return }
        Superwall.shared.register(placement: event.rawValue, params: params)
    }

    // MARK: Mixpanel

    /// Nil without a token (demo builds) and under unit tests.
    private static var mixpanel: MixpanelInstance?

    static func configure() {
        guard !Services.isTestHost,
            let token = Bundle.main.infoDictionary?["MixpanelToken"] as? String, !token.isEmpty
        else { return }
        // Its automatic events: first open, sessions and app updates.
        mixpanel = Mixpanel.initialize(token: token, trackAutomaticEvents: true)
        // No city or region from the IP address: the privacy policy says BumpCast doesn't use location.
        mixpanel?.useIPAddressForGeoLocation = false
        // Debug builds share the project: filter them out with `build`.
        #if DEBUG
            mixpanel?.registerSuperProperties(["build": "debug"])
        #else
            mixpanel?.registerSuperProperties(["build": "release"])
        #endif
    }

    /// The Supabase account, the same id Superwall has.
    static func identify(_ userID: UUID) {
        mixpanel?.identify(distinctId: userID.uuidString)
    }

    /// The user attributes Superwall gets, as the Mixpanel profile; Pro also goes on every event.
    static func setProfile(_ attributes: [String: Any?], pro: Bool) {
        guard let mixpanel else { return }
        mixpanel.people.set(properties: properties(attributes.compactMapValues { $0 }))
        mixpanel.registerSuperProperties(["pro": pro])
    }

    /// Superwall's own events that Mixpanel should see too: paywalls, purchases, restores and
    /// permission answers. Its "$" params lose the "$" (Mixpanel keeps that for its own).
    static func forward(_ info: SuperwallEventInfo) {
        let name = info.event.description
        guard let mixpanel, forwarded.contains(name) else { return }
        let params = Dictionary(info.params.map { (key, value) in (key.hasPrefix("$") ? String(key.dropFirst()) : key, value) }) { a, _ in a }
        mixpanel.track(event: name, properties: properties(params))
    }

    private static let forwarded: Set<String> = [
        "paywall_open", "paywall_close", "paywall_decline", "transaction_start", "transaction_complete",
        "transaction_abandon", "transaction_fail", "transaction_restore", "subscription_start", "freeTrial_start",
        "nonRecurringProduct_purchase", "restore_complete", "restore_fail", "permission_granted",
        "permission_denied", "survey_response",
    ]

    /// Mixpanel takes strings, numbers, bools and dates; anything else is sent as text.
    private static func properties(_ params: [String: Any]) -> Properties {
        params.mapValues { value -> MixpanelType in
            switch value {
            case let value as String: value
            case let value as Bool: value
            case let value as Int: value
            case let value as Double: value
            case let value as Date: value
            default: String(describing: value)
            }
        }
    }

    /// For errors: a bad connection repeats the same failure, so each kind is sent once a launch.
    static func logOnce(_ event: Event, _ params: [String: Any] = [:]) {
        let key = event.rawValue + (params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined(separator: ","))
        guard sentThisLaunch.insert(key).inserted else { return }
        log(event, params)
    }

    private static var sentThisLaunch: Set<String> = []

    #if DEBUG
        /// The latest events, newest last, for tests.
        static var sent: [(event: Event, params: [String: Any])] = []
    #endif

    /// Whole hours to a date, the way the paywall params send it.
    static func hours(to date: Date) -> Double { (date.timeIntervalSinceNow / 3600).rounded() }

    /// A flight's forecast context: its state, grade, confidence and whether it's unlocked.
    static func forecastParams(_ flight: Flight) -> [String: Any] {
        let store = FlightStore.shared
        let forecast = store.forecasts[flight.id]
        let state = ForecastState(flight: flight, forecast: forecast, betaOn: GlobalBeta.shared.isOn)
        var params: [String: Any] = [
            "forecast_state": state.analyticsValue(departure: flight.departureAt),
            "full_access": Paywalls.shared.hasFullAccess(to: flight),
            "hours_to_departure": hours(to: flight.departureAt),
            "in_air": InFlight.shared.isFlying(flight, forecast: forecast),
        ]
        if let grade = forecast?.grade { params["grade"] = grade.rawValue }
        if let forecast { params["confidence"] = forecast.confidence(departure: flight.departureAt).attributeValue }
        return params
    }
}
