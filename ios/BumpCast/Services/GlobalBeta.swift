import Foundation
import Observation

/// The global outlook beta (opt-in): forecasts for routes outside the US, from the waitlist
/// card, the Settings switch or the one-time question when adding an international flight.
/// Synced to the profile so the worker only notifies people who turned it on.
@MainActor @Observable
final class GlobalBeta {
    static let shared = GlobalBeta()

    private nonisolated static let key = "globalOutlook.beta"

    /// The saved choice, readable from anywhere (UserDefaults is thread-safe).
    nonisolated static var storedIsOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool == true }

    /// nil until the person has answered once.
    private(set) var choice: Bool?

    var isOn: Bool { choice == true }
    var hasAnswered: Bool { choice != nil }

    private init() {
        choice = UserDefaults.standard.object(forKey: Self.key) as? Bool
    }

    func set(_ on: Bool) {
        guard choice != on else { return }
        choice = on
        UserDefaults.standard.set(on, forKey: Self.key)
        Task { await AppSync.saveProfile() }
    }
}
