import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // First: everything else asks it whether there's a connection.
        Connectivity.shared.start()
        // The airport index is decoded on first use (the first list render); do it now, off the main thread.
        Task.detached(priority: .userInitiated) { _ = AirportStore.shared.all.count }
        Paywalls.shared.configure()
        BrandFont.applyToSystemControls()
        UNUserNotificationCenter.current().delegate = PushNotifications.shared
        AppSync.registerBackgroundRefresh()
        // "How did it feel?" buttons on the Live Activity after landing.
        FlightRatingHandler.submit = { flightID, rating in
            // Offline the rating is kept on the phone and sent later. The activity stays only if
            // the server refused it, so the buttons are still there to try again. An activity
            // carried over from a flight's old id rates the flight under its new one.
            let id = InFlight.shared.currentID(of: flightID)
            if await FlightStore.shared.submitLandingReport(flightID: id, rating: rating) != nil {
                InFlight.shared.endActivity(id)
            }
        }
        FlightRatingHandler.end = { flightID in InFlight.shared.endActivity(flightID) }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error.localizedDescription)")
    }

    /// A forecast notification arrived: pull the new forecast so it's saved for offline use.
    /// Completion-handler form: the async one can finish off the main thread, which UIKit rejects.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            await FlightStore.shared.reload()
            completionHandler(FlightStore.shared.isOffline ? .failed : .newData)
        }
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
                .environment(Connectivity.shared)
                .task {
                    // First launch: present the onboarding flow while the rest of the app syncs.
                    Onboarding.shared.start()
                    await AppSync.start()
                }
                .onOpenURL { Router.shared.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        InFlight.shared.refreshActivities()
                        // Coming back to the app on a connection picks up new forecasts and status.
                        Task { await FlightStore.shared.refreshIfStale() }
                        Task { await PushNotifications.shared.refreshStatus() }
                        Task { await Paywalls.shared.verifyEntitlements() }
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
                FlightsListView()
            }
            Tab("Map", systemImage: "map", value: Router.Tab.map) {
                TurbulenceMapView()
            }
            Tab("Learn", systemImage: "book.pages", value: Router.Tab.learn) {
                LearnView()
            }
            Tab("Calm", systemImage: "wind", value: Router.Tab.calm, role: calmRole) {
                CalmView()
            }
        }
        .overlay(alignment: .top) { ToastView(text: router.toast, systemImage: router.toastSymbol) }
        .fullScreenCover(isPresented: $router.showBreathing) { BreathingView() }
        .overlay { OnboardingCover() }
        // The one root for type, ink and tint; sheets and covers inherit it.
        .bumpCastTheme()
        .nightAppearanceAfterDark()
    }
}

/// First launch: the logo while Superwall loads the onboarding flow, or the native flow if it
/// can't. Superwall presents its flow over this, and the cover lifts once it's on screen.
private struct OnboardingCover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var onboarding: Onboarding { .shared }

    var body: some View {
        ZStack {
            switch onboarding.phase {
            case .loading:
                LaunchLoadingView().transition(.opacity)
            case .native:
                NativeOnboardingView().transition(.opacity)
            case .superwall, .done:
                EmptyView()
            }
        }
        .animation(reduceMotion ? Theme.fade : .easeInOut(duration: 0.5), value: onboarding.phase)
    }
}

/// Brief confirmation at the top of the screen. Slides in with the house spring; fades with
/// Reduce Motion. Read out by VoiceOver. Sheets show their own (the root's is hidden under them).
struct ToastView: View {
    let text: String?
    var systemImage = "checkmark.circle.fill"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let text {
                Label(text, systemImage: systemImage)
                    .font(.bcSubheadlineStrong)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .onAppear { AccessibilityNotification.Announcement(text).post() }
            }
        }
        .animation(Theme.motion(reduceMotion), value: text)
    }
}
