import Foundation
import StoreKit
import SuperwallKit
import UIKit

/// The App Store rating request, kept for moments that went well: the first forecast someone
/// sees (advance or confirmed, free or Pro), and a landing rating the forecast matched. The first
/// forecast asks once; a matched rating at most once per app version. Never over a paywall (it
/// waits for one to close), and the system still decides whether the prompt shows. A Superwall
/// surface on `flight_added` can also ask, with `requestNow()`.
@MainActor
enum ReviewPrompt {
    enum Moment: String {
        /// "How did it feel?" answered, and the forecast felt about right.
        case forecastMatched
        /// The first forecast opened: advance or confirmed, not the global outlook.
        case firstForecast

        /// The first forecast is asked about once; a matched rating can come again each version.
        var key: String {
            switch self {
            case .firstForecast: "review.requested.\(rawValue)"
            case .forecastMatched:
                "review.requested.\(rawValue).\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")"
            }
        }
    }

    /// A forecast on screen. Only the first real one counts: the global outlook is a beta guess.
    static func forecastShown(_ forecast: Forecast) {
        guard !forecast.isGlobalOutlook else { return }
        // Long enough for a free user's paywall to load first: then this waits for it to close.
        request(.firstForecast, after: .seconds(3))
    }

    /// Asks once the screen has settled (the forecast opening, the card settling in).
    static func request(_ moment: Moment, after delay: Duration = .seconds(1.5)) {
        let key = moment.key
        // Opening a forecast again while one is waiting doesn't ask twice.
        guard !UserDefaults.standard.bool(forKey: key), waiting.insert(key).inserted else { return }
        Task {
            defer { waiting.remove(key) }
            try? await Task.sleep(for: delay)
            // A paywall goes first (free users' first forecast opens one): ask once it has
            // closed, so free users are asked too.
            guard await paywallClosed() else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Superwall.shared.isPaywallPresented, let scene = activeScene else { return }
            UserDefaults.standard.set(true, forKey: key)
            AppStore.requestReview(in: scene)
        }
    }

    private static var waiting: Set<String> = []

    /// Waits for any paywall on screen to close, for up to 10 minutes. False if it's still open
    /// then: the moment can come again.
    private static func paywallClosed() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(600)
        while Superwall.shared.isPaywallPresented {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return true
    }

    /// A Superwall surface's `request_review` callback: the surface decided, so ask now.
    static func requestNow() {
        guard let scene = activeScene else { return }
        AppStore.requestReview(in: scene)
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
