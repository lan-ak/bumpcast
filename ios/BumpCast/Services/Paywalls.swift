import Foundation
import Observation
import SuperwallKit
import UIKit

/// Every Superwall placement the app registers. Campaigns in the Superwall dashboard decide
/// what each one shows (onboarding flow, soft paywall, gated paywall, or nothing).
enum Placement: String, CaseIterable {
    /// First launch. The onboarding flow lives entirely in Superwall.
    case onboarding
    /// The first time a free user sees a forecast grade: soft paywall.
    case firstGradeViewed = "first_grade_viewed"
    /// Opened from the "Your forecast is ready" notification: the main paywall moment.
    case forecastReadyOpened = "forecast_ready_opened"
    /// Opened from an update or "forecast confirmed" notification.
    case updateOpened = "update_opened"
    /// Gated: the full timeline (bump chart, stretches, confidence detail).
    case timelineLocked = "timeline_locked"
    /// Gated: "what changed" updates and their notifications.
    case updatesLocked = "updates_locked"
    /// Gated: "We've taken off", the Live Activity and in-flight reminders.
    case liveActivityLocked = "live_activity_locked"
    /// Gated: pilot reports on the map.
    case pilotReportsLocked = "pilot_reports_locked"
    /// Gated: saving more than the free number of upcoming flights.
    case flightLimitReached = "flight_limit_reached"
    /// "Get BumpCast Pro" in Settings.
    case upgradeFromSettings = "upgrade_from_settings"
}

enum Products {
    static let flightPass = "bumpcast_flight_pass"
    static let proMonthly = "bumpcast_pro_monthly"
    static let proAnnual = "bumpcast_pro_annual"
}

@Observable @MainActor
final class Paywalls {
    static let shared = Paywalls()

    /// Free users can keep this many upcoming flights; Pro is unlimited.
    static let freeUpcomingFlights = 2

    private(set) var isPro = false
    /// Flights unlocked by a flight pass bought this session (before the pass syncs to Supabase).
    private(set) var unlockedFlights: Set<UUID> = []
    private(set) var isConfigured = false

    /// The flight a paywall was opened for, so a flight pass bought there unlocks that flight.
    @ObservationIgnored private var passFlightID: UUID?
    @ObservationIgnored private var delegateAdapter: DelegateAdapter?
    @ObservationIgnored private let defaults = UserDefaults.standard

    func configure() {
        guard let key = Bundle.main.infoDictionary?["SuperwallAPIKey"] as? String, key.hasPrefix("pk_") else { return }
        Superwall.configure(apiKey: key)
        let adapter = DelegateAdapter(owner: self)
        delegateAdapter = adapter
        Superwall.shared.delegate = adapter
        isConfigured = true
        isPro = Superwall.shared.subscriptionStatus.isActive || Self.debugForcePro
    }

    /// Debug builds only: launch with `-forcePro` to test Pro features without a paywall.
    private static var debugForcePro: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-forcePro")
        #else
            false
        #endif
    }

    func identify(_ userID: UUID) {
        guard isConfigured else { return }
        Superwall.shared.identify(userId: userID.uuidString)
    }

    /// Pro, or a flight pass for this flight.
    func hasFullAccess(to flight: Flight) -> Bool {
        isPro || FlightStore.shared.passes.contains(flight.id) || unlockedFlights.contains(flight.id)
            || !isConfigured  // demo builds without a Superwall key show everything
    }

    var canAddFlight: Bool {
        isPro || !isConfigured || FlightStore.shared.upcomingFlights.count < Self.freeUpcomingFlights
    }

    /// Runs `feature` if the user already has access; otherwise registers the gated placement so
    /// Superwall can show a paywall. Access is always checked against real entitlements: Superwall
    /// also runs its feature block for holdouts and campaigns without a paywall, and those must not
    /// unlock Pro.
    func unlock(_ placement: Placement, flight: Flight? = nil, then feature: @escaping @MainActor () -> Void) {
        let entitled = { [weak self] in
            guard let self else { return false }
            return flight.map(self.hasFullAccess) ?? (self.isPro || !self.isConfigured)
        }
        if entitled() {
            feature()
            return
        }
        passFlightID = flight?.id
        Superwall.shared.register(placement: placement.rawValue, params: params(for: flight)) {
            Task { @MainActor in
                // Subscription status can land a moment after the purchase completes.
                for _ in 0..<10 where !entitled() {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if entitled() { feature() }
            }
        }
    }

    /// Registers a placement that isn't gating anything (soft paywalls, onboarding).
    func show(_ placement: Placement, flight: Flight? = nil) {
        guard isConfigured else { return }
        passFlightID = flight?.id
        Superwall.shared.register(placement: placement.rawValue, params: params(for: flight))
    }

    /// Onboarding answers and other one-off attributes (the native onboarding fallback uses this).
    func setUserAttributes(_ attributes: [String: Any]) {
        guard isConfigured else { return }
        Superwall.shared.setUserAttributes(attributes)
    }

    func firstGradeViewed(_ flight: Flight) {
        guard isConfigured, !hasFullAccess(to: flight), !defaults.bool(forKey: "firstGrade.registered") else { return }
        defaults.set(true, forKey: "firstGrade.registered")
        show(.firstGradeViewed, flight: flight)
    }

    func notificationOpened(flight: Flight, kind: String) {
        guard !hasFullAccess(to: flight) else { return }
        show(kind == "ready" ? .forecastReadyOpened : .updateOpened, flight: flight)
    }

    func restorePurchases() async -> Bool {
        guard isConfigured else { return false }
        let result = await Superwall.shared.restorePurchases()
        if case .restored = result { return true }
        return false
    }

    // MARK: User attributes (used by campaign audiences and paywall/onboarding text)

    func updateAttributes() {
        guard isConfigured else { return }
        let store = FlightStore.shared
        let next = store.nextFlight
        let nextForecast = next.flatMap { store.forecasts[$0.id] }
        let flown = store.flights.filter { InFlight.shared.landing(of: $0, forecast: store.forecasts[$0.id]) <= .now }
        let matched = store.reports.values.filter { $0.matched == true }.count
        var attributes: [String: Any?] = [
            "flights_saved": store.flights.count,
            "upcoming_flights": store.upcomingFlights.count,
            "flights_flown": flown.count,
            "has_flight_pass": !store.passes.isEmpty,
            "notifications_enabled": PushNotifications.shared.isEnabled,
            "in_flight": store.flights.contains { InFlight.shared.isFlying($0, forecast: store.forecasts[$0.id]) },
            "landing_reports": store.reports.count,
            "landing_reports_matched": matched,
            "waitlist_countries": store.waitlist.sorted().joined(separator: ","),
            "free_flight_limit": Self.freeUpcomingFlights,
        ]
        attributes["next_flight_route"] = next?.routeText
        attributes["next_flight_hours"] = next.map { ($0.departureAt.timeIntervalSinceNow / 3600).rounded() }
        attributes["next_flight_grade"] = nextForecast?.grade?.rawValue
        attributes["next_flight_confidence"] = nextForecast.flatMap { forecast in
            next.map { forecast.confidence(departure: $0.departureAt).attributeValue }
        }
        attributes["next_flight_covered"] = next.map(Coverage.covers)
        Superwall.shared.setUserAttributes(attributes)
    }

    private func params(for flight: Flight?) -> [String: Any]? {
        guard let flight else { return nil }
        let forecast = FlightStore.shared.forecasts[flight.id]
        var params: [String: Any] = [
            "flight_id": flight.id.uuidString,
            "route": flight.routeText,
            "hours_to_departure": (flight.departureAt.timeIntervalSinceNow / 3600).rounded(),
        ]
        if let grade = forecast?.grade {
            params["grade"] = grade.rawValue
            params["grade_title"] = grade.title
        }
        if let forecast, forecast.status == .ready {
            params["confidence"] = forecast.confidence(departure: flight.departureAt).attributeValue
            params["bumpy_minutes"] = forecast.samples.filter { $0.severity > .smooth }.count
        }
        return params
    }

    // MARK: Delegate callbacks

    fileprivate func statusChanged(_ status: SubscriptionStatus) {
        isPro = status.isActive || Self.debugForcePro
        updateAttributes()
        Task { await AppSync.saveProfile() }
    }

    fileprivate func handle(_ event: SuperwallEvent) {
        Onboarding.shared.paywallWebviewEvent(event)
        guard case .transactionComplete(let transaction, let product, _, _) = event,
            product.productIdentifier == Products.flightPass, let flightID = passFlightID
        else { return }
        let transactionID = transaction?.storeTransactionId ?? transaction?.originalTransactionIdentifier ?? UUID().uuidString
        unlockedFlights.insert(flightID)
        Task { await FlightStore.shared.recordPass(flightID: flightID, transactionID: transactionID, productID: product.productIdentifier) }
    }

    /// Superwall holds its delegate weakly; this keeps the bridge alive.
    private final class DelegateAdapter: SuperwallDelegate {
        weak var owner: Paywalls?
        init(owner: Paywalls) { self.owner = owner }

        @MainActor func subscriptionStatusDidChange(from oldValue: SubscriptionStatus, to newValue: SubscriptionStatus) {
            owner?.statusChanged(newValue)
        }

        @MainActor func handleSuperwallEvent(withInfo eventInfo: SuperwallEventInfo) {
            owner?.handle(eventInfo.event)
        }
    }
}

extension Forecast.Confidence {
    /// Stable values for Superwall audiences: early | partly_confirmed | confirmed.
    var attributeValue: String {
        switch self {
        case .early: "early"
        case .partly: "partly_confirmed"
        case .confirmed: "confirmed"
        }
    }
}
