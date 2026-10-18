import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Paywalls.shared.configure()
        BrandFont.applyToNavigationTitles()
        UNUserNotificationCenter.current().delegate = PushNotifications.shared
        AppSync.registerBackgroundRefresh()
        // "How did it feel?" buttons on the Live Activity after landing.
        FlightRatingHandler.submit = { flightID, rating in
            _ = await FlightStore.shared.submitLandingReport(flightID: flightID, rating: rating)
            InFlight.shared.endActivity(flightID)
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error.localizedDescription)")
    }

    /// A forecast notification arrived: pull the new forecast so it's saved for offline use.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await FlightStore.shared.reload()
        return FlightStore.shared.isOffline ? .failed : .newData
    }
}

@main
struct BumpCastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(FlightStore.shared)
                .environment(Router.shared)
                .environment(Paywalls.shared)
                .environment(PushNotifications.shared)
                .environment(InFlight.shared)
                .task { await AppSync.start() }
                .onOpenURL { Router.shared.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        InFlight.shared.refreshActivities()
                        Task { await PushNotifications.shared.refreshStatus() }
                    case .background:
                        AppSync.scheduleBackgroundRefresh()
                    default:
                        break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(Router.self) private var router

    /// Calm is the prominent tab on iOS 27; a regular tab on iOS 26.
    private var calmRole: TabRole? {
        if #available(iOS 27, *) { .prominent } else { nil }
    }

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Flights", systemImage: "airplane", value: Router.Tab.flights) {
                FlightsListView().font(.bcBody)
            }
            Tab("Map", systemImage: "map", value: Router.Tab.map) {
                TurbulenceMapView().font(.bcBody)
            }
            Tab("Learn", systemImage: "book.pages", value: Router.Tab.learn) {
                LearnView().font(.bcBody)
            }
            Tab("Calm", systemImage: "wind", value: Router.Tab.calm, role: calmRole) {
                CalmView().font(.bcBody)
            }
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: $router.showBreathing) { BreathingView().font(.bcBody) }
    }
}
