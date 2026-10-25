import Foundation
import StoreKit
import SuperwallKit
import UIKit

/// The App Store rating request, kept for moments that went well: a landing rating the forecast
/// matched, and adding a flight we forecast. Each moment asks at most once per app version, never
/// over a paywall, and the system still decides whether the prompt shows. Adding a flight is a
/// Superwall moment (`flight_added`): a surface there asks with `requestNow()`, and this is what
/// the app does when no campaign takes it.
@MainActor
enum ReviewPrompt {
    enum Moment: String {
        /// "How did it feel?" answered, and the forecast felt about right.
        case forecastMatched
        /// A flight added that we forecast: advance, not ready yet, or confirmed.
        case flightAdded
    }

    /// After adding a flight. Not for a route we can't forecast or one only the global outlook
    /// covers: "Not forecast yet" isn't a moment to ask.
    static func flightAdded(_ flight: Flight) {
        let store = FlightStore.shared
        switch ForecastState(flight: flight, forecast: store.forecasts[flight.id], betaOn: GlobalBeta.shared.isOn) {
        case .ready(let forecast) where forecast.isGlobalOutlook:
            break
        case .betaAvailable, .outOfCoverage:
            break
        case .ready, .unlocksAt, .building:
            // A little longer than after a rating: a paywall opening with the flight goes first.
            request(.flightAdded, after: .seconds(2.5))
        }
    }

    /// Asks once the screen has settled (the forecast opening, the card settling in).
    static func request(_ moment: Moment, after delay: Duration = .seconds(1.5)) {
        let key = "review.requested.\(moment.rawValue).\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        Task {
            try? await Task.sleep(for: delay)
            // A paywall that opened with the flight comes first; this moment can come again.
            guard !Superwall.shared.isPaywallPresented, let scene = activeScene else { return }
            UserDefaults.standard.set(true, forKey: key)
            AppStore.requestReview(in: scene)
        }
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
