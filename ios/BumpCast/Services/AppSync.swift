import BackgroundTasks
import Foundation

/// Launch sequence and the glue that keeps Supabase, Superwall and local reminders in step.
@MainActor
enum AppSync {
    static let refreshTaskID = "ca.akinyemi.bumpcast.refresh"

    private static var started = false
    /// The account this run last told the worker about (its profile and this device).
    private static var announcedUserID: UUID?
    private static var announcing: Task<Void, Never>?

    static func start() async {
        // RootView's task runs again when the scene comes back; the launch work only needs doing once.
        guard !started else {
            await FlightStore.shared.refreshIfStale()
            return
        }
        started = true
        let store = FlightStore.shared
        store.onSync = {
            // The account can be known only later (offline at launch, or after flights moved over).
            if let id = store.userID {
                Paywalls.shared.identify(id)
                if id != announcedUserID { Task { await announceAccount() } }
            }
            Paywalls.shared.updateAttributes()
            InFlight.shared.armUpcoming()
            InFlight.shared.retimeArmed()
            InFlight.shared.refreshActivities()
            Task {
                await InFlight.shared.scheduleLandingChecks()
                await InFlight.shared.scheduleBoardingReminders()
            }
        }
        Connectivity.shared.onReconnect = {
            Task { await FlightStore.shared.refreshIfStale(olderThan: 60) }
        }
        // What's saved first: the countdown, reminders and Superwall attributes never wait on the network.
        store.onSync?()
        let userID = await store.start()
        if let userID { Paywalls.shared.identify(userID) }
        if userID != nil {
            await announceAccount()
        } else {
            await PushNotifications.shared.refreshStatus()
        }
        store.onSync?()
        scheduleBackgroundRefresh()
    }

    /// An account new to this run (launch, or one that replaced a lost session): the worker needs
    /// its profile (Pro, quiet hours) and this device's token, or its flights get no updates.
    private static func announceAccount() async {
        guard let id = FlightStore.shared.userID else { return }
        if id == announcedUserID {
            await announcing?.value
            return
        }
        announcedUserID = id
        let task = Task {
            // Registers the token again, now for this account.
            await PushNotifications.shared.refreshStatus()
            await saveProfile()
            // Not saved (offline): tried again after the next sync.
            let saved = UserDefaults.standard.string(forKey: savedProfileKey)?.hasPrefix(id.uuidString) ?? false
            if !saved, announcedUserID == id { announcedUserID = nil }
        }
        announcing = task
        await task.value
    }

    private static let savedProfileKey = "profile.saved"
    private static let savedProfileAtKey = "profile.savedAt"

    /// What the worker needs to know: Pro status (update notifications), whether
    /// notifications are on, and the time zone for "updated with the 8 am run". Also the hash of
    /// this install's secret, so a later account on this phone can take the flights over.
    /// Skipped when nothing changed since the last save that went through (within a day).
    static func saveProfile() async {
        guard let userID = FlightStore.shared.userID else { return }
        let secretHash = await FlightStore.shared.adoptSecretHash()
        let profile = ProfileRecord(
            isPro: Paywalls.shared.isPro,
            notificationsEnabled: PushNotifications.shared.isEnabled,
            timezone: TimeZone.current.identifier,
            globalBeta: GlobalBeta.shared.choice,
            adoptSecretHash: secretHash)
        func key(_ profile: ProfileRecord) -> String {
            [
                userID.uuidString, "\(profile.isPro)", "\(profile.notificationsEnabled)", profile.timezone,
                profile.globalBeta.map { "\($0)" } ?? "-", profile.adoptSecretHash ?? "-",
            ].joined(separator: ":")
        }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: savedProfileKey) == key(profile),
            let savedAt = defaults.object(forKey: savedProfileAtKey) as? Date, savedAt.timeIntervalSinceNow > -86400
        {
            return
        }
        do {
            // What the server took: saved without the hash, it's sent again on the next launch or change.
            let saved = try await FlightStore.shared.service.saveProfile(profile)
            defaults.set(key(saved), forKey: savedProfileKey)
            defaults.set(Date.now, forKey: savedProfileAtKey)
        } catch {
            // Tried again on the next launch or change.
        }
    }

    // MARK: Background refresh: keep saved forecasts current before boarding

    static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: .main) { task in
            MainActor.assumeIsolated {
                scheduleBackgroundRefresh()
                let work = Task {
                    // No network: nothing to fetch, but the Live Activity can still move on a stretch.
                    var failed = true
                    if Connectivity.shared.hasPath {
                        await FlightStore.shared.reload()
                        failed = FlightStore.shared.isOffline
                    }
                    // Waits for the Live Activity pass (after the one a good sync started), so the
                    // app isn't suspended halfway through it.
                    await InFlight.shared.refreshActivities().value
                    // Out of time: the expiration handler has completed the task already.
                    guard !Task.isCancelled else { return }
                    task.setTaskCompleted(success: !failed)
                }
                task.expirationHandler = {
                    // The shared sync carries on; the system just stops waiting for it.
                    work.cancel()
                    task.setTaskCompleted(success: false)
                }
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
