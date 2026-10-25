import Foundation
import Observation
import StoreKit
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
    /// Gated: getting the countdown ready at the gate (or "We've taken off"): the Live Activity and in-flight reminders.
    case liveActivityLocked = "live_activity_locked"
    /// Gated: pilot reports on the map.
    case pilotReportsLocked = "pilot_reports_locked"
    /// Gated: saving more than the free number of upcoming flights.
    case flightLimitReached = "flight_limit_reached"
    /// "Get BumpCast Pro" in Settings.
    case upgradeFromSettings = "upgrade_from_settings"
    /// A flight just added in Add flight (the onboarding flow asks in its own pages). A surface
    /// here can ask for notifications (Request Permission) or a rating (`request_review`). With no
    /// campaign, the app asks for notifications itself (Add flight's toggle), then for a rating.
    case flightAdded = "flight_added"
    /// "Turn on notifications" on a flight's screen. With no campaign, the system prompt.
    case turnOnNotifications = "turn_on_notifications"
}

enum Products {
    static let flightPass = "bumpcast_flight_pass"
}

@Observable @MainActor
final class Paywalls {
    static let shared = Paywalls()

    /// Free users can keep this many upcoming flights; Pro is unlimited.
    static let freeUpcomingFlights = 2

    /// Pro is what Superwall says. It merges App Store, web, promo-code and test-store purchases,
    /// and its campaign audiences (`size(device.activeEntitlements) == 0`) check the same thing,
    /// so a lock always gets either the content or a paywall.
    private(set) var isPro = false
    /// Flights unlocked by a flight pass bought this session (before the pass syncs to Supabase).
    private(set) var unlockedFlights: Set<UUID> = []
    private(set) var isConfigured = false
    /// While a lock is waiting on Superwall, so repeated taps don't queue more requests.
    private(set) var isOpening = false

    /// Whether the phone can reach the App Store right now. A paywall can't complete a purchase
    /// without it (in the air, or on wifi that isn't answering), so locks show a calm note instead.
    var isOnline: Bool { Connectivity.shared.isOnline }

    /// The flight a paywall was opened for, so a flight pass bought there unlocks that flight.
    @ObservationIgnored private var passFlightID: UUID?
    @ObservationIgnored private var delegateAdapter: DelegateAdapter?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var openingReset: Task<Void, Never>?

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

    /// Brings Pro back in line with Superwall whenever the app comes forward. StoreKit's cache on
    /// the phone is never used to take Pro away: it can lag a renewal (in the air), and Pro from
    /// the web, a promo code or the test store has no App Store transaction at all. Superwall
    /// re-reads purchases itself on launch and on transaction updates; the delegate follows it.
    ///
    /// A subscription that simply runs out sends no transaction, though, so Superwall would keep
    /// it until the next launch. When StoreKit plainly shows it ended (refunded, or expired and
    /// not renewing), Superwall is asked to read purchases again, at most every few hours per
    /// transaction (that read can fail quietly on a weak connection), and Pro follows whatever it
    /// then says. It's checked again at the moment the current period ends.
    func verifyEntitlements() async {
        refreshPro()
        guard isConfigured, isPro, !Self.debugForcePro else { return }
        // Any Pro plan, including ones added in App Store Connect after this build: Pro is the
        // app's only subscription, so its latest transaction is the latest auto-renewable one.
        var latest: Transaction?
        for await result in Transaction.all {
            if case .verified(let transaction) = result, transaction.productType == .autoRenewable,
                transaction.purchaseDate > latest?.purchaseDate ?? .distantPast
            {
                latest = transaction
            }
        }
        guard let latest, let status = await latest.subscriptionStatus else { return }
        var renews = false
        if case .verified(let renewal) = status.renewalInfo { renews = renewal.willAutoRenew }
        if status.state == .revoked || (status.state == .expired && !renews) {
            let id = String(latest.id)
            // Superwall needs its config to re-read, and the network to fetch it.
            let checkedAt = defaults.object(forKey: Self.endedCheckedAtKey) as? Date ?? .distantPast
            let recentlyChecked = defaults.string(forKey: Self.endedCheckedKey) == id
                && checkedAt.timeIntervalSinceNow > -Self.endedRecheck
            guard isOnline, Superwall.shared.configurationStatus == .configured,
                Superwall.shared.subscriptionStatus.isActive, !recentlyChecked
            else { return }
            // Noted before the read, so two calls (foreground, expiry timer) can't both start one.
            defaults.set(id, forKey: Self.endedCheckedKey)
            defaults.set(Date.now, forKey: Self.endedCheckedAtKey)
            await Superwall.shared.refreshConfiguration()
            refreshPro()
            return
        }
        expiryCheck?.cancel()
        if let end = latest.expirationDate, end > .now, end < .now.addingTimeInterval(24 * 3600) {
            expiryCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, end.timeIntervalSinceNow + 1)))
                guard !Task.isCancelled else { return }
                await self?.verifyEntitlements()
            }
        }
    }

    /// The ended App Store transaction Superwall was last asked to re-read purchases for, and when.
    private static let endedCheckedKey = "pro.endedTransactionChecked"
    private static let endedCheckedAtKey = "pro.endedTransactionCheckedAt"
    /// Pro from the web or a promo code outlives an ended App Store subscription, so a read that
    /// still says Pro is only tried again after a while.
    private static let endedRecheck: TimeInterval = 6 * 3600
    @ObservationIgnored private var expiryCheck: Task<Void, Never>?

    /// Pro follows Superwall's subscription status, so the app is never stricter than the
    /// paywall gate. While Superwall hasn't worked the status out yet, Pro stays as it was.
    fileprivate func refreshPro(_ latest: SuperwallKit.SubscriptionStatus? = nil) {
        let status: SuperwallKit.SubscriptionStatus = latest ?? (isConfigured ? Superwall.shared.subscriptionStatus : .inactive)
        if case .unknown = status, !Self.debugForcePro { return }
        let pro = Self.debugForcePro || status.isActive
        guard pro != isPro else { return }
        isPro = pro
        updateAttributes()
        Task { await AppSync.saveProfile() }
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
    ///
    /// Every tap ends in the feature, a paywall, or a short note (offline, still connecting,
    /// couldn't load, unavailable). With `whenOffline`, a user without access who has no
    /// connection gets that instead of the offline note (an inline note on the card).
    func unlock(
        _ placement: Placement, flight: Flight? = nil, whenOffline: (@MainActor () -> Void)? = nil,
        then feature: @escaping @MainActor () -> Void
    ) {
        let entitled = { [weak self] in
            guard let self else { return false }
            return flight.map(self.hasFullAccess) ?? (self.isPro || !self.isConfigured)
        }
        refreshPro()
        if entitled() {
            feature()
            return
        }
        guard isOnline else {
            // The purchase couldn't go through (in the air, or wifi that isn't answering).
            if let whenOffline { whenOffline() } else { notify(.offline) }
            return
        }
        guard !isOpening else {
            notify(.connecting)
            return
        }
        setOpening(true)
        // Superwall is still fetching its config (up to a couple of minutes on plane wifi).
        if Superwall.shared.configurationStatus != .configured { notify(.connecting) }
        passFlightID = flight?.id

        let handler = PaywallPresentationHandler()
        handler.onPresent { [weak self] _ in
            Task { @MainActor in self?.setOpening(false) }
        }
        // Audiences only show paywalls to people with no active entitlement, so a skip usually
        // means Superwall already counts them as Pro (the feature block below then opens it).
        // A holdout or a placement with no campaign gets a note instead of nothing.
        handler.onSkip { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.setOpening(false)
                self.refreshPro()
                if !entitled() { self.notify(.unavailable) }
            }
        }
        handler.onError { [weak self] error in
            let code = (error as NSError).code
            Task { @MainActor in
                guard let self else { return }
                self.setOpening(false)
                switch code {
                case 102: break  // a paywall is already on screen
                case 104: self.notify(.notLoaded)  // Superwall gave up on its config; only a relaunch retries
                default: self.notify(self.isOnline ? .failed : .offline)
                }
            }
        }
        Superwall.shared.register(placement: placement.rawValue, params: params(for: flight), handler: handler) { [weak self] in
            // Purchased, restored, a closed non-gated paywall, or a skip.
            Task { @MainActor in
                self?.refreshPro()
                // Subscription status can land a moment after the purchase completes.
                for _ in 0..<10 where !entitled() {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if entitled() { feature() }
            }
        }
    }

    /// Marks a lock as waiting on Superwall. Superwall always answers with a paywall, a skip or
    /// an error, but if it somehow doesn't, taps work again after 30 s.
    private func setOpening(_ opening: Bool) {
        isOpening = opening
        openingReset?.cancel()
        guard opening else { return }
        openingReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.isOpening = false
        }
    }

    private enum Note { case offline, connecting, notLoaded, unavailable, failed }

    /// The short note a lock shows when it can't open anything, so a tap never does nothing.
    private func notify(_ note: Note) {
        let text: String
        var symbol = "exclamationmark.circle"
        switch note {
        case .offline where Connectivity.shared.hasPath:
            // Wifi that isn't answering, or a weak cellular signal: the words fit either.
            text = "Your connection isn't reaching the internet right now. Try again in a moment."
            symbol = "network.slash"
        case .offline:
            text = "You're offline. Connect to wifi to unlock this."
            symbol = "wifi.slash"
        case .connecting:
            text = "Connecting to the App Store. This can take a minute on plane wifi."
            symbol = "hourglass"
        case .notLoaded:
            text = "Couldn't reach BumpCast Pro. Once you're connected, close and reopen the app."
        case .unavailable:
            text = "BumpCast Pro isn't available right now. Please try again later."
        case .failed:
            text = "Couldn't open BumpCast Pro. Please try again."
        }
        Router.shared.showToast(text, systemImage: symbol)
    }

    /// Registers a placement that isn't gating anything (soft paywalls). Offline it does nothing:
    /// the paywall couldn't sell anything, and a queued one would pop up later, out of context.
    func show(_ placement: Placement, flight: Flight? = nil) {
        guard isConfigured, isOnline else { return }
        passFlightID = flight?.id
        Superwall.shared.register(placement: placement.rawValue, params: params(for: flight))
    }

    /// A moment a Superwall surface can take over, so how the app asks can change without a
    /// release: for notifications with the Request Permission action, for a rating with the
    /// `request_review` callback. With no campaign for the moment (none set up, or not for this
    /// user) the app does `otherwise`, as it always has; a holdout shows nothing. Offline, too,
    /// it does `otherwise`.
    func take(_ placement: Placement, flight: Flight? = nil, otherwise: @escaping @MainActor () async -> Void) {
        guard isConfigured, isOnline else {
            Task { await otherwise() }
            return
        }
        let handler = PaywallPresentationHandler()
        handler.onCustomCallback { callback in
            guard callback.name == Self.requestReviewCallback else { return .failure() }
            await ReviewPrompt.requestNow()
            return .success()
        }
        // The surface may have asked for notifications: register for pushes and tell the worker
        // and Superwall.
        handler.onDismiss { _, _ in
            Task { @MainActor in
                await PushNotifications.shared.refreshStatus()
                await AppSync.saveProfile()
                Paywalls.shared.updateAttributes()
            }
        }
        handler.onSkip { reason in
            if case .holdout = reason { return }
            Task { @MainActor in await otherwise() }
        }
        handler.onError { _ in
            Task { @MainActor in await otherwise() }
        }
        Superwall.shared.register(placement: placement.rawValue, params: momentParams(for: flight), handler: handler)
    }

    /// The custom callback a moment's surface sends to ask for an App Store rating.
    static let requestReviewCallback = "request_review"

    /// A paywall already on screen now sells a pass for this flight (the onboarding flow's
    /// paywall, once the user has added their flight).
    func sellPass(for flightID: UUID) {
        passFlightID = flightID
    }

    /// A flight saved again under a new id (FlightStore's reAdd) keeps a pass bought this session.
    func moveUnlock(from old: UUID, to new: UUID) {
        if unlockedFlights.remove(old) != nil { unlockedFlights.insert(new) }
        if passFlightID == old { passFlightID = new }
    }

    /// Onboarding answers and other one-off attributes (the native onboarding fallback uses this).
    func setUserAttributes(_ attributes: [String: Any]) {
        guard isConfigured else { return }
        Superwall.shared.setUserAttributes(attributes)
    }

    /// Offline, the moment waits for the next grade seen online.
    func firstGradeViewed(_ flight: Flight) {
        guard isConfigured, isOnline, !hasFullAccess(to: flight), !defaults.bool(forKey: "firstGrade.registered") else { return }
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
        refreshPro()
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
        attributes["next_flight_covered"] = next.map { Coverage.covers($0) || GlobalBeta.shared.isOn }
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

    /// A flight's params plus what a moment's surface decides on: whether notifications are on
    /// ("enabled", "denied", "not_determined"), whether the flight asked to be told ("notify"),
    /// and where its forecast stands ("forecast_state": a confidence once it's ready, otherwise
    /// "too_early", "building", "beta_available" or "not_covered").
    private func momentParams(for flight: Flight?) -> [String: Any] {
        var params = self.params(for: flight) ?? [:]
        let push = PushNotifications.shared
        params["notifications"] = push.isEnabled ? "enabled" : push.status == .denied ? "denied" : "not_determined"
        if let flight {
            params["notify"] = flight.notify
            let forecast = FlightStore.shared.forecasts[flight.id]
            params["forecast_state"] =
                switch ForecastState(flight: flight, forecast: forecast, betaOn: GlobalBeta.shared.isOn) {
                case .ready(let forecast): forecast.confidence(departure: flight.departureAt).attributeValue
                case .unlocksAt: "too_early"
                case .building: "building"
                case .betaAvailable: "beta_available"
                case .outOfCoverage: "not_covered"
                }
        }
        return params
    }

    // MARK: Delegate callbacks

    fileprivate func statusChanged(_ status: SuperwallKit.SubscriptionStatus) {
        refreshPro(status)
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

        @MainActor func subscriptionStatusDidChange(from oldValue: SuperwallKit.SubscriptionStatus, to newValue: SuperwallKit.SubscriptionStatus) {
            owner?.statusChanged(newValue)
        }

        /// Superwall re-read purchases (launch, refresh, a renewal or a transaction update). The
        /// status callback only fires on a logical change, so a renewal the app missed lands here.
        @MainActor func customerInfoDidChange(from oldValue: SuperwallKit.CustomerInfo, to newValue: SuperwallKit.CustomerInfo) {
            owner?.refreshPro()
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
        case .globalOutlook: "global_outlook"
        }
    }
}
