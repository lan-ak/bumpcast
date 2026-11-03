import Foundation
import Testing

@testable import BumpCast

/// The events sent to Superwall: never a paywall placement, and errors once a launch.
@MainActor
struct AnalyticsTests {
    @Test func eventNamesAreUniqueSnakeCaseAndNeverAPlacement() {
        let names = Analytics.Event.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        let placements = Set(Placement.allCases.map(\.rawValue))
        for name in names {
            #expect(!placements.contains(name), "\(name) is a paywall placement")
            #expect(name.allSatisfy { $0.isLowercase || $0 == "_" }, "\(name) isn't snake_case")
        }
    }

    /// Superwall's own events share the same table; an event with one of their names would be
    /// counted as theirs.
    @Test func eventNamesDontShadowSuperwallsOwn() {
        let superwall: Set<String> = [
            "app_open", "app_close", "app_launch", "app_install", "session_start", "first_seen",
            "paywall_open", "paywall_close", "paywall_decline", "transaction_start", "transaction_complete",
            "transaction_abandon", "transaction_fail", "subscription_start", "freeTrial_start",
            "permission_requested", "permission_granted", "permission_denied", "restore_start",
            "restore_complete", "restore_fail", "user_attributes", "trigger_fire", "survey_response",
        ]
        for event in Analytics.Event.allCases {
            #expect(!superwall.contains(event.rawValue))
        }
    }

    @Test func logOnceSendsEachKindOnceALaunch() {
        let reason = "test-\(UUID().uuidString)"
        let before = Analytics.sent.count
        Analytics.logOnce(.lockUnavailable, ["reason": reason])
        Analytics.logOnce(.lockUnavailable, ["reason": reason])
        Analytics.logOnce(.lockUnavailable, ["reason": reason + "-other"])
        let sent = Analytics.sent.suffix(Analytics.sent.count - before)
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.event == .lockUnavailable })
    }

    @Test func notificationPromptIsOnlyLoggedWhenItReallyAsks() async {
        let push = PushNotifications.shared
        guard push.status != .notDetermined else { return }
        let before = Analytics.sent.count
        await push.requestPermission(from: "settings")
        #expect(!Analytics.sent.suffix(Analytics.sent.count - before).contains { $0.event == .notificationPromptAnswered })
    }
}
