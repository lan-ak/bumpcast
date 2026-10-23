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
    private static let timeout: Duration = .seconds(8)
    /// Long enough for the logo to draw itself before the flow slides in.
    private static let minimumLogoTime: Duration = .seconds(1.8)
    /// The onboarding flow's paywalls, by identifier (their directories under `superwall/paywalls`):
    /// the hard and soft sides of the flight-paywall test. Matched by identifier, not name, so the
    /// dashboard names can say which is which. (1.0 and 1.0.1 match the name "Onboarding".)
    private static let paywallIdentifiers: Set<String> = ["onboarding", "onboarding-soft"]

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var started = false
    @ObservationIgnored private var webviewReady = false
    @ObservationIgnored private var webviewFailed = false

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
            // Present only once the flow's page has preloaded, so Superwall never shows its
            // shimmer; and not before the logo animation has played.
            let launched = ContinuousClock.now
            let deadline = launched + Self.timeout
            while ContinuousClock.now < deadline {
                guard let self, self.phase == .loading else { return }
                if self.webviewFailed || Superwall.shared.configurationStatus == .failed { break }
                if self.webviewReady, ContinuousClock.now - launched >= Self.minimumLogoTime {
                    self.present()
                    return
                }
                // No network at all (a first launch in the air): Superwall only retries, so go
                // native as soon as the logo has drawn instead of waiting out the timeout.
                if !Connectivity.shared.hasPath, ContinuousClock.now - launched >= Self.minimumLogoTime { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.fallBack()
        }
    }

    /// The onboarding page preloads in the background as soon as Superwall configures (its
    /// campaign is prioritized). `Paywalls` forwards the webview events here.
    func paywallWebviewEvent(_ event: SuperwallEvent) {
        switch event {
        case .paywallWebviewLoadComplete(let info) where Self.paywallIdentifiers.contains(info.identifier):
            webviewReady = true
        case .paywallWebviewLoadFail(let info) where Self.paywallIdentifiers.contains(info.identifier),
            .paywallWebviewLoadTimeout(let info) where Self.paywallIdentifiers.contains(info.identifier):
            webviewFailed = true
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
        // People flying soon add their flight from inside the flow (OnboardingFlight).
        handler.onCustomCallback { callback in
            await OnboardingFlight.handle(callback)
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
