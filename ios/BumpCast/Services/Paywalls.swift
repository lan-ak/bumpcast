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
    /// Gated: adding flights from email (connect, keep checking). A subscription feature: a flight
    /// pass doesn't unlock it.
    case emailImportLocked = "email_import_locked"
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
    /// One-flight passes. Each price is its own consumable; any of them unlocks the flight.
    static let flightPasses: Set<String> = ["bumpcast_flight_pass", "bumpcast_flight_pass_999"]
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

    /// While a soft paywall (`show`) is waiting on Superwall. Unlike `isOpening`, locks stay tappable.
    private(set) var isShowing = false
    /// A paywall is on its way: a lock or a soft paywall is waiting on Superwall to present it.
    var isPaywallOnTheWay: Bool { isOpening || isShowing }

    /// The flight of the paywall on screen, so a flight pass bought there unlocks that flight. Set
    /// when the paywall is presented (a register Superwall refuses, with one already up, doesn't
    /// change it) and cleared when it closes, so a pass from a paywall with no flight is never
    /// credited to an earlier one.
    @ObservationIgnored private var passFlightID: UUID?
    /// The onboarding paywall was on screen this session: the first forecast's soft paywall waits
    /// for the next launch rather than following it straight away.
    @ObservationIgnored private var onboardingPaywallShown = false
    @ObservationIgnored private var delegateAdapter: DelegateAdapter?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var openingReset: Task<Void, Never>?
    @ObservationIgnored private var showingReset: Task<Void, Never>?
    @ObservationIgnored private var passUpdates: Task<Void, Never>?

    func configure() {
        guard let key = Bundle.main.infoDictionary?["SuperwallAPIKey"] as? String, key.hasPrefix("pk_") else { return }
        // The restore alert Superwall shows when nothing is active (Settings and paywalls alike).
        let options = SuperwallOptions()
        options.paywalls.restoreFailed.title = "Nothing to restore"
        options.paywalls.restoreFailed.message =
            "There's no BumpCast Pro subscription on this Apple Account. Flight passes stay with their flight."
        options.paywalls.restoreFailed.closeButtonTitle = "OK"
        Superwall.configure(apiKey: key, options: options)
        let adapter = DelegateAdapter(owner: self)
        delegateAdapter = adapter
        Superwall.shared.delegate = adapter
        isConfigured = true
        isPro = Superwall.shared.subscriptionStatus.isActive || Self.debugForcePro
        listenForPasses()
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
        Analytics.identify(userID)
        guard isConfigured else { return }
        Superwall.shared.identify(userId: userID.uuidString)
    }

    /// Pro, or a flight pass for this flight.
    func hasFullAccess(to flight: Flight) -> Bool {
        isPro || FlightStore.shared.passes.contains(flight.id) || unlockedFlights.contains(flight.id)
            || showsEverything
    }

    /// Adding flights from email: Pro only, never a flight pass.
    var hasEmailImport: Bool { isPro || showsEverything }

    var canAddFlight: Bool {
        isPro || showsEverything || FlightStore.shared.upcomingFlights.count < Self.freeUpcomingFlights
    }

    /// Demo builds without a Superwall key show everything. Unit tests skip Superwall too, but see
    /// the free app, as a configured build would, unless a test unlocks it.
    private var showsEverything: Bool { !isConfigured && (!Services.isTestHost || Self.debugTestsSeeEverything) }

    #if DEBUG
        /// Tests only: everything unlocked, as in a demo build (the iPhone comparison with an
        /// earlier build, which had no test-host lock).
        nonisolated(unsafe) static var debugTestsSeeEverything = false
    #else
        static let debugTestsSeeEverything = false
    #endif

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
            return flight.map(self.hasFullAccess) ?? (self.isPro || self.showsEverything)
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

        let handler = PaywallPresentationHandler()
        handler.onPresent { [weak self] _ in
            Task { @MainActor in
                self?.setOpening(false)
                self?.passFlightID = flight?.id
            }
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
        Analytics.logOnce(.lockUnavailable, ["reason": "\(note)"])
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
        setShowing(true)
        let handler = PaywallPresentationHandler()
        handler.onPresent { [weak self] _ in
            Task { @MainActor in
                self?.setShowing(false)
                self?.passFlightID = flight?.id
            }
        }
        // Nothing to show, or a paywall already up (102): the one on screen keeps its flight.
        handler.onSkip { [weak self] _ in
            Task { @MainActor in self?.setShowing(false) }
        }
        handler.onError { [weak self] _ in
            Task { @MainActor in self?.setShowing(false) }
        }
        Superwall.shared.register(placement: placement.rawValue, params: params(for: flight), handler: handler)
    }

    /// Like `setOpening`, for soft paywalls. A paywall still loading on slow wifi counts, so the
    /// rating prompt waits for it; after a minute it's taken as not coming.
    private func setShowing(_ showing: Bool) {
        isShowing = showing
        showingReset?.cancel()
        guard showing else { return }
        showingReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.isShowing = false
        }
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
        handler.onPresent { [weak self] _ in
            Task { @MainActor in self?.passFlightID = flight?.id }
        }
        handler.onCustomCallback { callback in
            guard callback.name == Self.requestReviewCallback else { return .failure() }
            await ReviewPrompt.requestNow(from: placement)
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
        if let pending = pendingPass, pending.flightID == old {
            pendingPass = PendingPass(flightID: new, productID: pending.productID, startedAt: pending.startedAt)
        }
    }

    /// Onboarding answers and other one-off attributes (the native onboarding fallback uses this).
    func setUserAttributes(_ attributes: [String: Any]) {
        guard isConfigured else { return }
        Superwall.shared.setUserAttributes(attributes)
    }

    /// The insets last handed to Superwall, so an unchanged screen sends nothing.
    @ObservationIgnored private var sharedSafeArea: UIEdgeInsets?

    /// Paywalls are full-bleed web content, and Superwall infers the safe area from the device
    /// model, which simulators and new models don't report: the closed iPhone Duo's camera column
    /// runs down the right edge. Hands it the window's real insets, which change as the Duo folds,
    /// so this runs before each paywall shows. On other iPhones they match what Superwall assumes.
    func shareSafeArea() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        let insets = window.safeAreaInsets
        guard insets != sharedSafeArea else { return }
        sharedSafeArea = insets
        setUserAttributes([
            "safe_area_top": Int(insets.top.rounded()), "safe_area_bottom": Int(insets.bottom.rounded()),
            "safe_area_left": Int(insets.left.rounded()), "safe_area_right": Int(insets.right.rounded()),
        ])
    }

    /// Offline, the moment waits for the next grade seen online. Right after the onboarding paywall
    /// (finishing it opens the flight) it waits for the next launch, so two paywalls don't follow
    /// each other.
    func firstGradeViewed(_ flight: Flight) {
        guard isConfigured, isOnline, !onboardingPaywallShown, !hasFullAccess(to: flight),
            !defaults.bool(forKey: "firstGrade.registered")
        else { return }
        defaults.set(true, forKey: "firstGrade.registered")
        show(.firstGradeViewed, flight: flight)
    }

    func notificationOpened(flight: Flight, kind: String) {
        guard !hasFullAccess(to: flight) else { return }
        show(kind == "ready" ? .forecastReadyOpened : .updateOpened, flight: flight)
    }

    enum RestoreOutcome {
        case restored
        /// Superwall has already said so in its own alert (`restoreFailed` in `configure`).
        case nothingFound
        /// No Superwall key (demo builds): nothing ran and nothing was shown.
        case unavailable
    }

    /// The SDK has no public way to restore without its alert: whenever the restore fails or
    /// leaves no active entitlement, it shows `restoreFailed`. So the app only speaks when Pro is
    /// active after the restore, and the SDK's alert carries the app's words otherwise.
    func restorePurchases() async -> RestoreOutcome {
        guard isConfigured else { return .unavailable }
        let result = await Superwall.shared.restorePurchases()
        refreshPro()
        if case .restored = result, isPro { return .restored }
        return .nothingFound
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
            "global_outlook_on": GlobalBeta.shared.isOn,
            "haptics_on": defaults.object(forKey: "haptics.enabled") as? Bool ?? true,
        ]
        attributes["next_flight_route"] = next?.routeText
        attributes["next_flight_hours"] = next.map { ($0.departureAt.timeIntervalSinceNow / 3600).rounded() }
        attributes["next_flight_grade"] = nextForecast?.grade?.rawValue
        attributes["next_flight_confidence"] = nextForecast.flatMap { forecast in
            next.map { forecast.confidence(departure: $0.departureAt).attributeValue }
        }
        attributes["next_flight_covered"] = next.map { Coverage.covers($0) || GlobalBeta.shared.isOn }
        Superwall.shared.setUserAttributes(attributes)
        Analytics.setProfile(attributes, pro: isPro)
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
            params["forecast_state"] = ForecastState(flight: flight, forecast: forecast, betaOn: GlobalBeta.shared.isOn)
                .analyticsValue(departure: flight.departureAt)
        }
        return params
    }

    // MARK: Delegate callbacks

    fileprivate func statusChanged(_ status: SuperwallKit.SubscriptionStatus) {
        refreshPro(status)
    }

    fileprivate func handle(_ event: SuperwallEvent) {
        Onboarding.shared.superwallEvent(event)
        switch event {
        case .paywallOpen(let info) where info.presentedByPlacementWithName == Placement.onboarding.rawValue:
            onboardingPaywallShown = true
        case .paywallClose:
            passFlightID = nil
        case .transactionStart(let product, _) where Products.flightPasses.contains(product.productIdentifier):
            // Kept on the phone until the purchase ends, so a pass that completes later (Ask to
            // Buy, or the app closed mid-purchase) is still recorded. No flight: nothing to credit.
            pendingPass = passFlightID.map { PendingPass(flightID: $0, productID: product.productIdentifier, startedAt: .now) }
        case .transactionAbandon(let product, _) where Products.flightPasses.contains(product.productIdentifier):
            pendingPass = nil
        case .transactionFail(.failure(_, let product), _) where Products.flightPasses.contains(product.productIdentifier):
            pendingPass = nil
        case .transactionComplete(let transaction, let product, _, _) where Products.flightPasses.contains(product.productIdentifier):
            let flightID = passFlightID ?? pendingPass?.flightID
            pendingPass = nil
            guard let flightID else { return }
            let transactionID = transaction?.storeTransactionId ?? transaction?.originalTransactionIdentifier ?? UUID().uuidString
            recordPass(flightID: flightID, transactionID: transactionID, productID: product.productIdentifier)
        default:
            break
        }
    }

    private func recordPass(flightID: UUID, transactionID: String, productID: String) {
        unlockedFlights.insert(flightID)
        Task { await FlightStore.shared.recordPass(flightID: flightID, transactionID: transactionID, productID: productID) }
    }

    /// A pass purchase that started on a paywall with a flight and hasn't ended yet.
    struct PendingPass: Codable, Equatable {
        let flightID: UUID
        let productID: String
        let startedAt: Date

        /// Ask to Buy requests lapse after a day or so; past this, a pass is someone else's.
        static let lifetime: TimeInterval = 2 * 24 * 3600

        /// Whether a pass transaction that arrived outside a paywall is this purchase.
        func matches(productID: String, purchaseDate: Date, now: Date = .now) -> Bool {
            productID == self.productID && now.timeIntervalSince(startedAt) < Self.lifetime
                && purchaseDate > startedAt.addingTimeInterval(-60)
        }
    }

    private static let pendingPassKey = "pass.pending"

    private var pendingPass: PendingPass? {
        get { defaults.data(forKey: Self.pendingPassKey).flatMap { try? JSONDecoder().decode(PendingPass.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.pendingPassKey) }
    }

    /// A pass approved later (Ask to Buy) or completed while the app was closed reaches the app
    /// only as a StoreKit update: Superwall finishes it and reloads purchases, but sends no
    /// `transactionComplete`. Unfinished ones are delivered here again at launch.
    private func listenForPasses() {
        passUpdates?.cancel()
        passUpdates = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result, transaction.revocationDate == nil,
                    Products.flightPasses.contains(transaction.productID)
                else { continue }
                self?.passArrived(transactionID: String(transaction.id), productID: transaction.productID, purchaseDate: transaction.purchaseDate)
            }
        }
    }

    private func passArrived(transactionID: String, productID: String, purchaseDate: Date) {
        guard let pending = pendingPass else { return }
        guard pending.matches(productID: productID, purchaseDate: purchaseDate) else {
            if Date.now.timeIntervalSince(pending.startedAt) >= PendingPass.lifetime { pendingPass = nil }
            return
        }
        pendingPass = nil
        Analytics.log(.passLateRecorded, ["product_id": productID])
        recordPass(flightID: pending.flightID, transactionID: transactionID, productID: productID)
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
            Analytics.forward(eventInfo)
        }

        /// The open iPhone Duo is regular in both size classes, where a modal paywall's page sheet
        /// shrinks to a card centred over the fold. Superwall presents each paywall from a window of
        /// its own, made for that presentation, so that window alone is told it's compact width: the
        /// sheet adapts to a phone's, spanning the screen, and the paywall lays out either side of the
        /// fold (its own CSS). The app's window behind it keeps its layout. Everywhere else the sheet
        /// is left as Superwall made it.
        @MainActor func willPresentPaywall(withInfo paywallInfo: PaywallInfo) {
            owner?.shareSafeArea()
            guard let paywall = Superwall.shared.presentedViewController,
                paywall.sheetPresentationController != nil,
                let window = paywall.presentingViewController?.view.window,
                window.traitCollection.horizontalSizeClass == .regular,
                window.traitCollection.verticalSizeClass == .regular
            else { return }
            window.traitOverrides.horizontalSizeClass = .compact
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
