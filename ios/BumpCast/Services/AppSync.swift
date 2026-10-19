import BackgroundTasks
import Foundation

/// Launch sequence and the glue that keeps Supabase, Superwall and local reminders in step.
@MainActor
enum AppSync {
    static let refreshTaskID = "ca.akinyemi.bumpcast.refresh"

    static func start() async {
        let store = FlightStore.shared
        store.onSync = {
            Paywalls.shared.updateAttributes()
            InFlight.shared.armUpcoming()
            InFlight.shared.retimeArmed()
            InFlight.shared.refreshActivities()
            Task {
                await InFlight.shared.scheduleLandingChecks()
                await InFlight.shared.scheduleBoardingReminders()
            }
        }
        let userID = await store.start()
        if let userID { Paywalls.shared.identify(userID) }
        await PushNotifications.shared.refreshStatus()
        await saveProfile()
        store.onSync?()
        scheduleBackgroundRefresh()
    }

    /// What the worker needs to know: Pro status (update notifications), whether
    /// notifications are on, and the time zone for "updated with the 8 am run".
    static func saveProfile() async {
        guard FlightStore.shared.userID != nil else { return }
        let profile = ProfileRecord(
            isPro: Paywalls.shared.isPro,
            notificationsEnabled: PushNotifications.shared.isEnabled,
            timezone: TimeZone.current.identifier,
            globalBeta: GlobalBeta.shared.choice)
        try? await FlightStore.shared.service.saveProfile(profile)
    }

    // MARK: Background refresh: keep saved forecasts current before boarding

    static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: .main) { task in
            MainActor.assumeIsolated {
                scheduleBackgroundRefresh()
                let work = Task {
                    await FlightStore.shared.reload()
                    task.setTaskCompleted(success: !FlightStore.shared.isOffline)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
    }

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        // Sooner when a flight is close, so the latest forecast is on the phone before boarding.
        let soon = FlightStore.shared.upcomingFlights.contains { $0.departureAt.timeIntervalSinceNow < 6 * 3600 }
        request.earliestBeginDate = .now.addingTimeInterval(soon ? 15 * 60 : 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
