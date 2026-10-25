import Foundation
import Observation
import SuperwallKit
import UIKit

/// First-launch onboarding. The flow lives in Superwall (the `onboarding` placement); while it
/// loads the app shows `LaunchLoadingView`, and if it can't load, `NativeOnboardingView` asks the
/// same questions natively so nobody starts the app without them.
@Observable @MainActor
final class Onboarding {
    static let shared = Onboarding()

    enum Phase: Equatable {
        /// Onboarding already finished (or this isn't the first launch).
        case done
        /// Waiting for Superwall to configure and present the flow.
        case loading
        /// The Superwall flow is on screen.
        case superwall
        /// Superwall didn't load: the native flow is on screen.
        case native
    }

    private(set) var phase: Phase

    /// Kept for installs that finished onboarding before this coordinator existed.
    private static let doneKey = "onboarding.done"
    /// How long the loading screen waits for the Superwall flow before switching to the native one.
    /// A first launch can take a while to get Superwall's configuration (6 to 16 seconds on App
    /// Review's network, against under 3 for most people). Without a network path the native flow
    /// comes up as soon as the logo has drawn instead.
    private static let timeout: Duration = .seconds(20)
    /// Long enough for the logo to draw itself before the flow slides in.
    private static let minimumLogoTime: Duration = .seconds(1.8)
    /// How long after Superwall configures to ask about the placement if no preload reports.
    private static let preloadWait: Duration = .seconds(3)
    /// How long after the placement's answer a preloaded page has to show it's loading.
    private static let pageStartGrace: Duration = .seconds(1)

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var started = false
    /// What the `onboarding` placement shows this user, asked of Superwall at launch: the flow is
    /// whichever paywall the campaign gives the placement, whatever its name or identifier. (1.0
    /// and 1.0.1 wait for a paywall named "Onboarding".)
    @ObservationIgnored private var placementResult: PresentationResult?
    /// When `placementResult` arrived.
    @ObservationIgnored private var placementResultAt: ContinuousClock.Instant?
    /// Superwall's first preload has finished.
    @ObservationIgnored private var preloadFinished = false
    /// Paywalls whose page has started loading, preloaded, or failed to, by identifier.
    @ObservationIgnored private var loadingPaywalls: Set<String> = []
    @ObservationIgnored private var loadedPaywalls: Set<String> = []
    @ObservationIgnored private var failedPaywalls: Set<String> = []

    private init() {
        phase = UserDefaults.standard.bool(forKey: Self.doneKey) ? .done : .loading
    }

    /// Called once at launch. Waits for the flow to preload, then presents it (or falls back).
    func start() {
        guard phase == .loading, !started else { return }
        started = true
        let paywalls = Paywalls.shared
        guard paywalls.isConfigured, !Self.debugForceNative else {
            // No Superwall key (demo builds): straight to the native flow.
            phase = .native
            return
        }

        // The flow is full-bleed web content. Superwall infers the safe area from the device
        // model, which simulators (and future models) don't report, so hand it the real insets.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        {
            let insets = window.safeAreaInsets
            paywalls.setUserAttributes([
                "safe_area_top": Int(insets.top.rounded()), "safe_area_bottom": Int(insets.bottom.rounded()),
            ])
        }

        Task { [weak self] in
            await self?.waitForPreload()
            // Waits for the configuration, so it can't run before Superwall knows the campaigns.
            // "Not available" can mean the subscription status took over 5 seconds to arrive, so
            // ask again until the loading screen gives up.
            while self?.phase == .loading {
                let result = await Superwall.shared.getPresentationResult(forPlacement: Placement.onboarding.rawValue)
                if result != .paywallNotAvailable {
                    self?.placementResult = result
                    self?.placementResultAt = .now
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        Task { [weak self] in
            // Present only once the flow's page has preloaded, so Superwall never shows its
            // shimmer; and not before the logo animation has played.
            let launched = ContinuousClock.now
            let deadline = launched + Self.timeout
            while ContinuousClock.now < deadline {
                guard let self, self.phase == .loading else { return }
                if Superwall.shared.configurationStatus == .failed { break }
                let logoDrawn = ContinuousClock.now - launched >= Self.minimumLogoTime
                switch self.placementResult {
                case .paywall(let experiment):
                    // The paywall this user is assigned (one side of an experiment, say).
                    guard let paywall = experiment.variant.paywallId else {
                        if logoDrawn { return self.present() }
                        break
                    }
                    if self.loadedPaywalls.contains(paywall) {
                        if logoDrawn { return self.present() }
                    } else if self.failedPaywalls.contains(paywall) {
                        return self.fallBack()
                    } else if !self.loadingPaywalls.contains(paywall), logoDrawn,
                        let answered = self.placementResultAt, ContinuousClock.now - answered >= Self.pageStartGrace
                    {
                        // Nothing is loading its page (it wasn't in the first preload, say), and
                        // nothing will until it's presented: present it, and Superwall shows its
                        // loading screen until the page is in.
                        return self.present()
                    }
                case .holdout, .noAudienceMatch, .placementNotFound:
                    // Nothing to preload: registering hands the skip to `present()`, which ends
                    // onboarding for a holdout and asks the questions natively otherwise.
                    if logoDrawn { return self.present() }
                case .paywallNotAvailable, nil:
                    break
                }
                // No network at all (a first launch in the air): Superwall only retries, so go
                // native as soon as the logo has drawn instead of waiting out the timeout.
                if !Connectivity.shared.hasPath, ContinuousClock.now - launched >= Self.minimumLogoTime { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.fallBack()
        }
    }

    /// Asking Superwall about the placement builds its paywall's screen without loading the page,
    /// and Superwall's preload then reuses that screen as it is, so the page would only load once
    /// presented (1.0.2 build 8 waited for it, timed out and went native). So ask once the first
    /// preload has finished: by then it has built the screens it preloads and started their pages.
    /// If no preload reports (preloading off), ask a few seconds after Superwall configures.
    private func waitForPreload() async {
        var configuredAt: ContinuousClock.Instant?
        while phase == .loading, !preloadFinished {
            if Superwall.shared.configurationStatus == .configured {
                let configured = configuredAt ?? .now
                configuredAt = configured
                if ContinuousClock.now - configured >= Self.preloadWait { return }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Paywall pages preload in the background as soon as Superwall configures (the onboarding
    /// campaign is prioritized), possibly before the placement's paywall is known, so every one is
    /// noted. `Paywalls` forwards Superwall's events here.
    func superwallEvent(_ event: SuperwallEvent) {
        switch event {
        case .paywallPreloadComplete:
            preloadFinished = true
        case .paywallWebviewLoadStart(let info):
            loadingPaywalls.insert(info.identifier)
        case .paywallWebviewLoadComplete(let info):
            loadedPaywalls.insert(info.identifier)
        case .paywallWebviewLoadFail(let info), .paywallWebviewLoadTimeout(let info):
            failedPaywalls.insert(info.identifier)
        default:
            break
        }
    }

    private func present() {
        let handler = PaywallPresentationHandler()
        handler.onPresent { [weak self] _ in
            Task { @MainActor in self?.phase = .superwall }
        }
        handler.onDismiss { [weak self] _, _ in
            Task { @MainActor in await self?.finish() }
        }
        handler.onSkip { [weak self] reason in
            Task { @MainActor in
                // A holdout is a deliberate "show nothing". Anything else means the campaign
                // isn't set up for this user, so ask the questions natively.
                if case .holdout = reason {
                    await self?.finish()
                } else {
                    self?.fallBack()
                }
            }
        }
        handler.onError { [weak self] _ in
            Task { @MainActor in self?.fallBack() }
        }
        // People flying soon add their flight from inside the flow (OnboardingFlight). Asking for a
        // rating is part of the flow too: a page sends `request_review`.
        handler.onCustomCallback { callback in
            if callback.name == Paywalls.requestReviewCallback {
                await ReviewPrompt.requestNow()
                return .success()
            }
            return await OnboardingFlight.handle(callback)
        }
        Superwall.shared.register(placement: Placement.onboarding.rawValue, handler: handler)

        // The page is already loaded, so presenting is near-instant; if it somehow isn't, don't
        // leave the logo up forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.fallBack()
        }
    }

    /// Debug builds only: launch with `-nativeOnboarding` to test the fallback flow.
    private static var debugForceNative: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-nativeOnboarding")
        #else
            false
        #endif
    }

    /// The native flow finished (or the user skipped through it). With `addFlight` (flying in
    /// the next 3 days), Add flight opens as the flow lifts.
    func finishNative(addFlight: Bool = false) async {
        await finish(addFlight: addFlight)
    }

    private func fallBack() {
        guard phase == .loading else { return }
        phase = .native
    }

    private func finish(addFlight: Bool = false) async {
        guard phase != .done else { return }
        defaults.set(true, forKey: Self.doneKey)
        phase = .done
        if addFlight { Router.shared.showAddFlight = true }
        // A flight added during the flow: open it, so its forecast is the first thing they see.
        if let id = OnboardingFlight.flightID {
            OnboardingFlight.forget()
            if FlightStore.shared.flight(id) != nil { Router.shared.openFlight(id) }
        }
        // The flow may have asked for notification permission: register for pushes and tell
        // the worker and Superwall.
        await PushNotifications.shared.refreshStatus()
        await AppSync.saveProfile()
        Paywalls.shared.updateAttributes()
    }
}
