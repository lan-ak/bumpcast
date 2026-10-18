import Foundation
import Observation
import SuperwallKit

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

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var started = false

    private init() {
        phase = UserDefaults.standard.bool(forKey: Self.doneKey) ? .done : .loading
    }

    /// Called once at launch. Registers the placement and starts the fallback timer.
    func start() {
        guard phase == .loading, !started else { return }
        started = true
        let paywalls = Paywalls.shared
        guard paywalls.isConfigured, !Self.debugForceNative else {
            // No Superwall key (demo builds): straight to the native flow.
            phase = .native
            return
        }

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
        Superwall.shared.register(placement: Placement.onboarding.rawValue, handler: handler)

        Task { [weak self] in
            let deadline = ContinuousClock.now + Self.timeout
            while ContinuousClock.now < deadline {
                if Superwall.shared.configurationStatus == .failed { break }
                try? await Task.sleep(for: .milliseconds(200))
                if self?.phase != .loading { return }
            }
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

    /// The native flow finished (or the user skipped through it).
    func finishNative() async {
        await finish()
    }

    private func fallBack() {
        guard phase == .loading else { return }
        phase = .native
    }

    private func finish() async {
        guard phase != .done else { return }
        defaults.set(true, forKey: Self.doneKey)
        phase = .done
        // The flow may have asked for notification permission: register for pushes and tell
        // the worker and Superwall.
        await PushNotifications.shared.refreshStatus()
        await AppSync.saveProfile()
        Paywalls.shared.updateAttributes()
    }
}
