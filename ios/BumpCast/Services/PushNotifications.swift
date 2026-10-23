import Foundation
import Observation
import UIKit
import UserNotifications

/// Remote forecast notifications (sent by the worker through APNs) and their taps.
@Observable @MainActor
final class PushNotifications: NSObject {
    static let shared = PushNotifications()

    private(set) var status: UNAuthorizationStatus = .notDetermined

    var isEnabled: Bool { status == .authorized || status == .provisional || status == .ephemeral }

    private var center: UNUserNotificationCenter { .current() }

    func refreshStatus() async {
        status = await center.notificationSettings().authorizationStatus
        if isEnabled {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Ask once the user has a reason to say yes (after saving a flight).
    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        await AppSync.saveProfile()
        Paywalls.shared.updateAttributes()
        return granted
    }

    private static let registeredKey = "push.registered"
    private static let registeredAtKey = "push.registeredAt"

    /// Called on every foreground. The worker only needs the token once per account, so it's sent
    /// again only when the account, token or environment changes, or a day has passed.
    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
            let environment = "sandbox"
        #else
            let environment = "production"
        #endif
        Task {
            let store = FlightStore.shared
            // Registered as the account the flights belong to, never before it's known.
            guard let userID = try? await store.account() else { return }
            let key = "\(userID.uuidString):\(token):\(environment)"
            let defaults = UserDefaults.standard
            if defaults.string(forKey: Self.registeredKey) == key,
                let registeredAt = defaults.object(forKey: Self.registeredAtKey) as? Date,
                registeredAt.timeIntervalSinceNow > -86400
            {
                return
            }
            do {
                try await store.service.registerDevice(token: token, environment: environment)
                defaults.set(key, forKey: Self.registeredKey)
                defaults.set(Date.now, forKey: Self.registeredAtKey)
            } catch {
                // Sent again on the next foreground.
            }
        }
    }

    /// Kinds the worker sends; local reminders use "stretch" and "landing".
    nonisolated static let forecastKinds: Set<String> = ["ready", "update", "confirmed"]

    fileprivate func handleTap(_ userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["flight_id"] as? String, let old = UUID(uuidString: raw) else { return }
        // Sent for a flight that was saved again since: the new id.
        let flightID = InFlight.shared.currentID(of: old)
        let kind = userInfo["kind"] as? String ?? ""
        switch kind {
        case "stretch":
            Router.shared.handle(url: URL(string: "bumpcast://breathe")!)
        default:
            Router.shared.openFlight(flightID)
            Task {
                await FlightStore.shared.refreshForecast(flightID)
                if Self.forecastKinds.contains(kind), let flight = FlightStore.shared.flight(flightID) {
                    Paywalls.shared.notificationOpened(flight: flight, kind: kind)
                }
            }
        }
    }
}

// Completion-handler variants on purpose: the async ones return on a background thread, and UIKit
// aborts when the tap's completion runs off the main thread (TestFlight crash, build 3).
extension PushNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let kind = notification.request.content.userInfo["kind"] as? String ?? ""
        DispatchQueue.main.async {
            completionHandler([.banner, .sound, .list])
            if PushNotifications.forecastKinds.contains(kind) {
                Task { @MainActor in await FlightStore.shared.reload() }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let flightID = userInfo["flight_id"] as? String
        let kind = userInfo["kind"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var info: [AnyHashable: Any] = [:]
                info["flight_id"] = flightID
                info["kind"] = kind
                PushNotifications.shared.handleTap(info)
            }
            completionHandler()
        }
    }
}
