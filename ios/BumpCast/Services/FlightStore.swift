import CryptoKit
import Foundation
import Observation
import Supabase
import UIKit

@Observable @MainActor
final class FlightStore {
    static let shared = FlightStore()

    private(set) var userID: UUID?
    private(set) var flights: [Flight] = []
    private(set) var forecasts: [UUID: Forecast] = [:]
    private(set) var updates: [UUID: [FlightUpdate]] = [:]
    private(set) var passes: Set<UUID> = []
    private(set) var reports: [UUID: LandingReport] = [:]
    private(set) var waitlist: Set<String> = []
    private(set) var syncedAt: Date?
    /// Flights added offline that haven't reached the server yet.
    private(set) var pendingAdds: [FlightDraft] = []
    /// Flight passes bought while the server couldn't be reached (they unlock the flight meanwhile).
    private(set) var pendingPasses: [FlightPassRecord] = []
    /// Landing ratings given offline (shown meanwhile), sent on the next sync.
    private(set) var pendingReports: [PendingLandingReport] = []
    /// Flights deleted here that the server may still have: deleted there on the next sync, and
    /// never taken back from its answer meanwhile.
    private(set) var pendingDeletes: Set<UUID> = []
    private(set) var isLoading = false
    /// True when the last sync failed (usually no connection); the UI says it's showing saved data.
    private(set) var isOffline = false
    /// The last failure was the connection, not the server: the screens keep saying so while the
    /// next try is on its way.
    private(set) var failedOnConnection = false
    var error: String?

    /// Called after every successful sync so Superwall attributes and scheduled
    /// in-flight reminders stay current.
    @ObservationIgnored var onSync: (@MainActor () -> Void)?

    let service: FlightService
    private let local: LocalStore
    private let connectivity: Connectivity
    private let protectedDataAvailable: @MainActor () -> Bool

    /// The account the saved flights belong to, kept with them so a lost or replaced session can
    /// never swap in another account's (empty) list.
    @ObservationIgnored private var ownerID: UUID?
    /// Accounts the flights were still moving from when a move failed partway: tried again with it.
    @ObservationIgnored private var previousOwners: [UUID] = []
    /// Flights saved again under new ids: the forecast they brought stays until the server has one,
    /// and a pass the lost account holds still unlocks them here.
    @ObservationIgnored private var carriedForecasts: Set<UUID> = []
    @ObservationIgnored private var carriedPasses: Set<UUID> = []
    /// This install's secret: its hash on the account's profile proves to the server that a later
    /// account on this phone may take the flights over (their ids alone aren't private).
    @ObservationIgnored private var adoptSecret: String?
    /// Launch, pull-to-refresh, pushes and background wakes share one sign-in and one sync instead
    /// of racing (three syncs and a sign-up raced on AC 1507).
    @ObservationIgnored private var signingIn: Task<UUID, Error>?
    @ObservationIgnored private var sync: Task<Void, Never>?
    /// Someone asked for a sync after the running one had fetched: it runs once more.
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var fetchStarted = false
    /// Flights saved or deleted here while a sync was running: its answer can be older than them.
    @ObservationIgnored private var savedDuringSync: Set<UUID> = []
    @ObservationIgnored private var deletedDuringSync: Set<UUID> = []
    /// Passes, ratings and waitlist countries the server took while a sync was running: its
    /// answers can be older than them.
    @ObservationIgnored private var passesSavedDuringSync: Set<UUID> = []
    @ObservationIgnored private var reportsSavedDuringSync: Set<UUID> = []
    @ObservationIgnored private var waitlistSavedDuringSync: Set<String> = []
    /// A snapshot exists but couldn't be read (before the first unlock): never save over it.
    @ObservationIgnored private var snapshotUnread = false

    init(
        service: FlightService = Services.flights, local: LocalStore = .shared, connectivity: Connectivity = .shared,
        protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    ) {
        self.service = service
        self.local = local
        self.connectivity = connectivity
        self.protectedDataAvailable = protectedDataAvailable
        if let saved = local.load() {
            apply(saved)
        } else {
            snapshotUnread = local.hasSnapshot
        }
    }

    private func apply(_ saved: Snapshot) {
        flights = saved.flights
        forecasts = saved.forecasts
        updates = saved.updates
        passes = saved.passes
        reports = saved.reports
        waitlist = saved.waitlist
        syncedAt = saved.syncedAt
        pendingAdds = saved.pendingAdds ?? []
        pendingPasses = saved.pendingPasses ?? []
        pendingReports = saved.pendingReports ?? []
        pendingDeletes = saved.pendingDeletes ?? []
        ownerID = saved.userID
        previousOwners = saved.previousOwners ?? []
        carriedForecasts = saved.carriedForecasts ?? []
        carriedPasses = saved.carriedPasses ?? []
        adoptSecret = saved.adoptSecret
    }

    /// A process woken before the first unlock can't read the saved flights. Read them once it can.
    private func loadSnapshotIfUnread() {
        guard snapshotUnread, protectedDataAvailable() else { return }
        // Still unreadable once unlocked: it's damaged, so the next save replaces it.
        snapshotUnread = false
        if let saved = local.load() { apply(saved) }
    }

    func start() async -> UUID? {
        do {
            let id = try await account()
            await reload()
            return id
        } catch {
            noteFailure(error)
            report(error, quietlyIfOffline: true)
            return nil
        }
    }

    // MARK: Account

    /// The account to sync as: the phone's saved session, or a new anonymous one on a phone with
    /// none. If it isn't the account the saved flights belong to, they move over first.
    func account() async throws -> UUID {
        loadSnapshotIfUnread()
        if let userID, userID == ownerID, service.storedUserID() == userID { return userID }
        if let signingIn { return try await signingIn.value }
        let task = Task { try await resolveAccount() }
        signingIn = task
        defer { signingIn = nil }
        return try await task.value
    }

    private func resolveAccount() async throws -> UUID {
        // A keychain read can fail for a moment: look again before treating it as no session (also
        // while an older build's flights wait to be claimed, which runs this again on each call).
        if ownerID != nil || !flights.isEmpty, service.storedUserID() == nil { try? await Task.sleep(for: .milliseconds(300)) }
        let hadSession = service.storedUserID() != nil
        // Locked, the keychain can read as empty: never take that for a new phone.
        let id = try await service.signIn(allowSignUp: protectedDataAvailable())
        let changed = ownerID != id
        if let owner = ownerID, owner != id, !flights.isEmpty {
            // Throws when the move fails, so the old account stays the owner and it's tried again.
            do {
                try await adoptFlights(from: [owner] + previousOwners, into: id)
            } catch is PostgrestError {
                // Not about whatever asked for the account (a save, a rating): no "refused" for it.
                throw SyncError.flightsNotMoved
            }
        } else if ownerID == nil, !hadSession {
            // Saved by an older build, whose session is gone: that account can't be reached from
            // here, so its flights are saved again under this one.
            reAdd(flights.filter { !isPending($0.id) })
        } else if ownerID == nil {
            // Saved by an older build, which didn't note whose they are: the session it left may be
            // one it signed up after losing theirs (AC 1507).
            try await claimLegacyFlights(as: id)
        }
        ownerID = id
        userID = id
        previousOwners = []
        await persist()
        // A new account: its profile and device, and the countdowns of flights saved again.
        if changed { onSync?() }
        return id
    }

    /// The session belongs to another account than the saved flights (the old one was lost). They
    /// move over by id, which only this phone knows; any the server doesn't move are saved again.
    private func adoptFlights(from owners: [UUID], into id: UUID) async throws {
        try await verify(id)
        // Pending ones too: an add whose answer was lost may be on the old account already.
        let ids = flights.map(\.id)
        var owned: Set<UUID> = []
        var sources: [UUID] = []
        for owner in owners where owner != id && !sources.contains(owner) { sources.append(owner) }
        do {
            for owner in sources {
                for start in stride(from: 0, to: ids.count, by: adoptLimit) {
                    let batch = Array(ids[start..<min(start + adoptLimit, ids.count)])
                    owned.formUnion(try await service.adoptFlights(batch, from: owner, secret: adoptSecret ?? ""))
                }
            }
        } catch let error as PostgrestError where error.code == "PGRST202" {
            // A server without the move yet: they're saved again below.
        } catch {
            // Some may have moved to this account already: it's tried as well next time.
            if !previousOwners.contains(id) {
                previousOwners.append(id)
                await persist()
            }
            throw error
        }
        // The server leaves flights it can't move (the old account isn't anonymous, or it's gone).
        reAdd(flights.filter { !owned.contains($0.id) && !isPending($0.id) })
    }

    /// Flights an older build saved without their account: any this one doesn't have belong to one
    /// this phone lost, and are saved again under this one rather than dropped by its list.
    private func claimLegacyFlights(as id: UUID) async throws {
        let ids = flights.map(\.id).filter { !isPending($0) }
        guard !ids.isEmpty else { return }
        try await verify(id)
        var owned: Set<UUID> = []
        do {
            for start in stride(from: 0, to: ids.count, by: adoptLimit) {
                let batch = Array(ids[start..<min(start + adoptLimit, ids.count)])
                // Asked to move them from itself, the server moves nothing and answers which are its own.
                owned.formUnion(try await service.adoptFlights(batch, from: id, secret: ""))
            }
        } catch let error as PostgrestError where error.code == "PGRST202" {
            // A server without the move yet: the session's account is taken as theirs, as before.
            return
        } catch is PostgrestError {
            // Owner stays unknown, so it's asked again on the next call.
            throw SyncError.flightsNotMoved
        }
        reAdd(flights.filter { !owned.contains($0.id) && !isPending($0.id) })
    }

    /// The hash of this install's secret, for the profile. Made the first time and saved with the
    /// flights before it's shared. Nil while the saved flights can't be read yet (never replace it).
    func adoptSecretHash() async -> String? {
        loadSnapshotIfUnread()
        guard !snapshotUnread else { return nil }
        if adoptSecret == nil {
            adoptSecret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
            await persist()
        }
        return adoptSecret.map { secret in
            SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Saves these flights again as new ones. Never under their old ids: the old account's rows
    /// hold those, and the insert's 23505 would be taken for "already saved" and drop them.
    private func reAdd(_ lost: [Flight]) {
        guard !lost.isEmpty else { return }
        for flight in lost {
            let old = flight.id
            var draft = FlightDraft(flight)
            let id = UUID()
            draft.id = id
            var copy = flight
            copy.id = id
            pendingAdds.append(draft)
            flights.removeAll { $0.id == old }
            flights.append(copy)
            // What the phone has for it follows: the forecast (kept until the server has one for the
            // new id), queued passes and ratings, and the unlock.
            forecasts[id] = forecasts.removeValue(forKey: old)
            updates[id] = updates.removeValue(forKey: old)
            if forecasts[id] != nil { carriedForecasts.insert(id) }
            carriedForecasts.remove(old)
            pendingPasses = pendingPasses.map { $0.flightId == old ? $0.moved(to: id) : $0 }
            // Carried even when queued: a pass whose answer was lost is on the old account already,
            // and sending it again under the new id changes nothing there.
            if passes.remove(old) != nil {
                passes.insert(id)
                carriedPasses.insert(id)
            }
            carriedPasses.remove(old)
            // A pass bought this session (or a paywall open for this flight) follows it too.
            Paywalls.shared.moveUnlock(from: old, to: id)
            pendingReports = pendingReports.map { $0.flightId == old ? $0.moved(to: id) : $0 }
            if let report = reports.removeValue(forKey: old) { reports[id] = report.moved(to: id) }
            // The phone's taps, countdown and seatbelt notes follow the trip to its new id, and so
            // does a screen, link or notification for the old one (InFlight.currentID).
            InFlight.shared.rekey(from: old, to: id)
        }
        flights.sort { $0.departureAt < $1.departureAt }
    }

    /// Refreshed sooner than the SDK would (30 s before expiry), so a fetch doesn't run into it.
    private static let tokenMargin: TimeInterval = 120

    /// Throws unless requests go out as `owner` right now. Returns the token they carry.
    @discardableResult
    private func verify(_ owner: UUID) async throws -> String {
        let session = try await service.session(refreshingWithin: Self.tokenMargin)
        guard session.userID == owner else { throw SyncError.accountChanged }
        return session.accessToken
    }

    /// Throws unless every request since `token` was checked went out with it. One that found it
    /// expired and couldn't refresh it went out with the public key, and an answer to that comes
    /// back empty instead of refused: it must never replace what's saved.
    private func verify(_ owner: UUID, still token: String) async throws {
        let session = try await service.session(refreshingWithin: 0)
        guard session.userID == owner else { throw SyncError.accountChanged }
        guard session.accessToken == token else { throw SyncError.sessionRefreshed }
    }

    // MARK: Sync

    /// Launch, pushes and background refresh: one sync at a time, shared, waited for in full.
    func reload() async {
        guard connectivity.hasPath else {
            noteFailure(nil)
            return
        }
        await startSync().value
    }

    /// Pull-to-refresh: the same sync, but the spinner stops after a few seconds on a connection
    /// that isn't answering. The sync carries on, and the screen updates if it lands.
    func refresh() async {
        guard connectivity.hasPath else {
            noteFailure(nil)
            return
        }
        let task = startSync()
        let deadline = ContinuousClock.now + .seconds(10)
        while sync == task, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// After coming back to the app or getting a connection back: syncs when the last one is older
    /// than `age`, or failed.
    func refreshIfStale(olderThan age: TimeInterval = 600) async {
        guard connectivity.isOnline, isOffline || (syncedAt ?? .distantPast) < .now.addingTimeInterval(-age) else {
            return
        }
        await reload()
    }

    @discardableResult
    private func startSync() -> Task<Void, Never> {
        if let sync {
            if fetchStarted { syncAgain = true }
            return sync
        }
        // Unstructured, so pull-to-refresh letting go (which cancels its task) doesn't abort it halfway.
        let task = Task {
            repeat {
                syncAgain = false
                fetchStarted = false
                forgetSavedDuringSync()
                await performSync()
            } while syncAgain && !isOffline && connectivity.hasPath
            fetchStarted = false
            forgetSavedDuringSync()
            sync = nil
        }
        sync = task
        return task
    }

    private func forgetSavedDuringSync() {
        savedDuringSync = []
        deletedDuringSync = []
        passesSavedDuringSync = []
        reportsSavedDuringSync = []
        waitlistSavedDuringSync = []
    }

    private func performSync(retrying: Bool = false) async {
        loadSnapshotIfUnread()
        isLoading = true
        defer { isLoading = false }
        do {
            let owner = try await account()
            // Refreshes the session first: offline, this fails and everything saved stays.
            try await verify(owner)
            try await flushPendingAdds()
            await flushPendingDeletes()
            await flushPendingPasses()
            await flushPendingReports()
            fetchStarted = true
            // The answers count only if every request carried this token.
            let token = try await verify(owner)
            let fetched = try await service.flights()
            // One dropped request on plane wifi shouldn't fail the whole sync.
            async let passIDs = service.passFlightIDs()
            async let landed = service.landingReports()
            async let countries = service.waitlistCountries()
            let newPasses = try? await passIDs
            let newReports = try? await landed
            let newWaitlist = try? await countries
            // Only this account's answers, all sent with its session, replace what's saved.
            try await verify(owner, still: token)
            // Flights still waiting (or refused) stay on the phone, and changes made here while this
            // sync ran win over its answer.
            let fetchedIDs = Set(fetched.map(\.id))
            // A flight deleted here never comes back from the answer. One the server still has is
            // deleted again next time: an add whose answer was lost can land after the delete.
            pendingDeletes.formIntersection(fetchedIDs)
            let current = flights
            let kept = current.filter {
                !fetchedIDs.contains($0.id) && (isPending($0.id) || savedDuringSync.contains($0.id))
            }
            let answered = fetched.filter { !deletedDuringSync.contains($0.id) && !pendingDeletes.contains($0.id) }
                .map { flight in
                    savedDuringSync.contains(flight.id) ? (current.first { $0.id == flight.id } ?? flight) : flight
                }
            flights = (answered + kept).sorted { $0.departureAt < $1.departureAt }
            // Drop cached data for flights deleted elsewhere.
            let ids = Set(flights.map(\.id))
            forecasts = forecasts.filter { ids.contains($0.key) }
            updates = updates.filter { ids.contains($0.key) }
            carriedForecasts.formIntersection(ids)
            carriedPasses.formIntersection(ids)
            // Passes, ratings and countries saved while this sync ran can be missing from its answers.
            if let newPasses {
                passes = newPasses.union(pendingPasses.map(\.flightId)).union(carriedPasses).union(passesSavedDuringSync)
            }
            if let newReports {
                let before = reports
                reports = Dictionary(newReports.map { ($0.flightId, $0) }, uniquingKeysWith: { first, _ in first })
                for pending in pendingReports where reports[pending.flightId] == nil {
                    reports[pending.flightId] = pending.report
                }
                for id in reportsSavedDuringSync where reports[id] == nil { reports[id] = before[id] }
            }
            if let newWaitlist { waitlist = newWaitlist.union(waitlistSavedDuringSync) }
            let fresh = await fetchForecasts(answered.map(\.id))
            try await verify(owner, still: token)
            // A flight edited meanwhile has a newer (reset) forecast than this answer.
            for (id, result) in fresh where !savedDuringSync.contains(id) {
                applyForecast(result.forecast, updates: result.updates, for: id)
            }
            syncedAt = .now
            isOffline = false
            connectivity.noteSuccess()
            await persist()
            onSync?()
        } catch SyncError.sessionRefreshed where !retrying {
            // Refreshed while the answers came in, so some may have gone out without it: once more.
            await performSync(retrying: true)
        } catch {
            noteFailure(error)
            report(error, quietlyIfOffline: true)
        }
    }

    /// Each flight's latest forecast and updates. A flight whose requests fail keeps what's saved.
    private func fetchForecasts(_ ids: [UUID]) async -> [UUID: (forecast: Forecast?, updates: [FlightUpdate])] {
        let service = self.service
        return await withTaskGroup(of: (UUID, Forecast?, [FlightUpdate])?.self) { group in
            for id in ids {
                group.addTask {
                    async let forecast = service.latestForecast(for: id)
                    async let feed = service.updates(for: id)
                    guard let result = try? await (forecast, feed) else { return nil }
                    return (id, result.0, result.1)
                }
            }
            var results: [UUID: (forecast: Forecast?, updates: [FlightUpdate])] = [:]
            for await case let (id, fresh, items)? in group { results[id] = (fresh, items) }
            return results
        }
    }

    func refreshForecast(_ id: UUID) async {
        guard connectivity.hasPath else { return }
        do {
            let owner = try await account()
            let token = try await verify(owner)
            let asked = flight(id)
            async let forecast = service.latestForecast(for: id)
            async let feed = service.updates(for: id)
            let (fresh, items) = try await (forecast, feed)
            try await verify(owner, still: token)
            // Its route, time or number edited meanwhile: this answer is for the old flight.
            guard let asked, let current = flight(id), Self.sameForecast(current, FlightDraft(asked)) else { return }
            let before = forecasts[id]
            applyForecast(fresh, updates: items, for: id)
            connectivity.noteSuccess()
            // A new forecast can arm the countdown (e.g. for a flight added in the air).
            if forecasts[id] != before {
                await persist()
                onSync?()
            }
        } catch {
            report(error, quietlyIfOffline: true)
        }
    }

    /// Mirrors the server, including "no forecast" (e.g. after an edit reset it), except for a
    /// less certain forecast for the same departure soon after a more certain one.
    private func applyForecast(_ fresh: Forecast?, updates feed: [FlightUpdate], for id: UUID) {
        guard let flight = flight(id) else { return }
        // Saved again under a new id: the forecast it brought stays until the server has one.
        if carriedForecasts.contains(id) {
            guard fresh != nil else { return }
            carriedForecasts.remove(id)
        }
        let current = forecasts[id]
        if let fresh, let current, Self.isRegression(fresh, from: current, departure: flight.departureAt) {
            // Keep the more certain one.
        } else {
            forecasts[id] = fresh
        }
        updates[id] = feed
    }

    /// A forecast that's less certain than the one on the phone, for the same departure and issued
    /// within 3 hours of it: an outlook-only run published between two detailed ones (AC 1507,
    /// 17:20). Global outlooks follow their own stretches and are never held back.
    static func isRegression(_ fresh: Forecast, from current: Forecast, departure: Date) -> Bool {
        guard fresh.status == .ready, current.status == .ready, !fresh.isGlobalOutlook, !current.isGlobalOutlook,
            fresh.departureAt == current.departureAt,
            let freshIssued = fresh.issuedAt, let currentIssued = current.issuedAt,
            freshIssued > currentIssued, freshIssued.timeIntervalSince(currentIssued) < 3 * 3600
        else { return false }
        return certainty(fresh.confidence(departure: departure)) < certainty(current.confidence(departure: departure))
    }

    private static func certainty(_ confidence: Forecast.Confidence) -> Int {
        switch confidence {
        case .early: 0
        case .partly, .globalOutlook: 1
        case .confirmed: 2
        }
    }

    /// Fetches one flight again for its live status, e.g. right after adding one that's already
    /// left. Runs the after-sync work when the status changed, so an in-air flight can start.
    func refreshFlight(_ id: UUID) async {
        guard connectivity.hasPath, !isPending(id), flight(id) != nil else { return }
        do {
            let owner = try await account()
            let token = try await verify(owner)
            let asked = flight(id)
            let fresh = try await service.flight(id)
            try await verify(owner, still: token)
            // Edited here meanwhile: that's newer than this answer.
            guard let index = flights.firstIndex(where: { $0.id == id }), flights[index] == asked else { return }
            let changed = flights[index].status != fresh.status
            flights[index] = fresh
            flights.sort { $0.departureAt < $1.departureAt }
            connectivity.noteSuccess()
            await persist()
            if changed { onSync?() }
        } catch {
            // Polled: only a connection or session problem is worth noting.
            if error.isConnectivityFailure || error.isSessionRefusal { report(error, quietlyIfOffline: true) }
        }
    }

    // MARK: Pending writes

    /// Whether a flight is only on this phone so far (added offline).
    func isPending(_ id: UUID) -> Bool { pendingAdds.contains { $0.id == id } }

    /// Whether a landing rating is saved on the phone but not sent yet.
    func isReportPending(_ flightID: UUID) -> Bool { pendingReports.contains { $0.flightId == flightID } }

    private func flushPendingAdds() async throws {
        for id in pendingAdds.compactMap(\.id) {
            // Read each time: one can be edited or deleted here while another is being sent.
            guard let draft = pendingAdds.first(where: { $0.id == id }) else { continue }
            var upToDate = true
            do {
                _ = try await service.add(draft)
            } catch let error as PostgrestError where error.code == "23505" {
                // Saved by an earlier attempt whose answer was lost, maybe before an edit made here.
                upToDate = false
            } catch let error as PostgrestError where !error.isSessionRefusal {
                continue  // refused: it stays on the phone rather than holding up every sync
            }
            do {
                // Edited here while it was being sent: the server gets the edit too.
                var sent = draft
                while let current = pendingAdds.first(where: { $0.id == id }), !upToDate || current != sent {
                    _ = try await service.update(id, current)
                    sent = current
                    upToDate = true
                }
            } catch let error as PostgrestError where error.code == "PGRST116" && !upToDate {
                // The id is a row of an account this phone lost, not this one's: saved again.
                if let flight = flight(id) {
                    pendingAdds.removeAll { $0.id == id }
                    reAdd([flight])
                    await persist()
                }
                continue
            } catch let error as PostgrestError where !error.isSessionRefusal {
                continue
            }
            // Saved. One deleted here while it was being sent is deleted there next (flushPendingDeletes).
            pendingAdds.removeAll { $0.id == id }
            await persist()
        }
    }

    /// Deletes on the server the flights deleted here while it may have had them. By id, so a
    /// repeat (or one it never had) changes nothing. Each stays until an answer no longer has it.
    private func flushPendingDeletes() async {
        for id in pendingDeletes {
            do {
                try await service.delete(id)
            } catch let error as PostgrestError where !error.isSessionRefusal {
                continue  // refused for now: the answer still leaves it out
            } catch {
                return  // no connection: kept for next time
            }
        }
    }

    /// A pass or rating for a flight that isn't in the list is kept: it may come back (and passes
    /// are paid for). Deleting a flight drops its own.
    private func flushPendingPasses() async {
        for pass in pendingPasses where flight(pass.flightId) != nil && !isPending(pass.flightId) {
            do {
                // Upserts on the transaction, so a repeat is harmless.
                try await service.recordPass(pass)
            } catch let error as PostgrestError where !error.isSessionRefusal {
                continue  // refused for now (e.g. the flight isn't saved yet): try again next sync
            } catch {
                return  // no connection: keep the rest for next time
            }
            pendingPasses.removeAll { $0.transactionId == pass.transactionId }
            await persist()
        }
    }

    private func flushPendingReports() async {
        for pending in pendingReports where flight(pending.flightId) != nil && !isPending(pending.flightId) {
            do {
                reports[pending.flightId] = try await submit(pending)
            } catch let error as PostgrestError where error.code == "23505" {
                // Already saved by an earlier attempt; the sync brings the scored one.
            } catch let error as PostgrestError where !error.isSessionRefusal {
                // Refused (e.g. the flight left the account): don't retry forever.
            } catch {
                return  // no connection: keep the rest for next time
            }
            pendingReports.removeAll { $0.flightId == pending.flightId }
            await persist()
        }
    }

    private func submit(_ pending: PendingLandingReport) async throws -> LandingReport {
        try await service.submitLandingReport(
            flightID: pending.flightId, rating: pending.rating, seatbeltMins: pending.seatbeltMins,
            forecastIssuedAt: pending.forecastIssuedAt)
    }

    // MARK: Saving flights

    /// How long saving a new flight waits on the server before keeping it on the phone instead.
    static let addWait: Duration = .seconds(8)

    @discardableResult
    func save(_ draft: FlightDraft, editing id: UUID? = nil) async -> Flight? {
        var draft = draft
        if id == nil, draft.id == nil { draft.id = UUID() }
        if let id, isPending(id) {
            // Not on the server yet: change what will be sent.
            draft.id = id
            forgetIfDifferent(id, draft)
            if let old = flight(id), !Self.sameForecast(old, draft) {
                forecasts[id] = nil
                updates[id] = nil
                carriedForecasts.remove(id)
            }
            pendingAdds = pendingAdds.map { $0.id == id ? draft : $0 }
            if sync != nil { savedDuringSync.insert(id) }
            return await keepOnPhone(draft)
        }
        if let id {
            do {
                let flight = try await send(draft, editing: id)
                return await saved(flight, editing: id, draft)
            } catch {
                report(error)
                return nil
            }
        }
        // No connection, or a wifi that just didn't answer: don't wait for the request to fail.
        guard connectivity.isOnline else { return await keepOnPhone(draft) }
        let request = Task { try await send(draft, editing: nil) }
        switch await Self.result(of: request, within: Self.addWait) {
        case .success(let flight):
            return await saved(flight, editing: nil, draft)
        case .failure(let error as PostgrestError) where error.code != "23505" && !error.isSessionRefusal:
            // The server refused the flight itself.
            report(error)
            return nil
        case .failure(let error):
            // Offline, a wifi that isn't answering, or the session couldn't be checked: keep it on
            // the phone and save it on the next sync (a repeat insert is taken as already saved).
            if error.isConnectivityFailure { connectivity.noteFailure(error) }
            return await keepOnPhone(draft)
        case nil:
            // Slow to answer: kept on the phone for now, and the request carries on.
            let kept = await keepOnPhone(draft)
            Task {
                switch await request.result {
                case .success(let flight):
                    await addLanded(flight, draft)
                case .failure:
                    // Its answer was lost, so the server may have it after all: one deleted here
                    // meanwhile is deleted there again, even if a sync sent its delete before it landed.
                    if self.flight(kept.id) == nil, pendingDeletes.insert(kept.id).inserted { await persist() }
                }
            }
            return kept
        }
    }

    private func send(_ draft: FlightDraft, editing id: UUID?) async throws -> Flight {
        let owner = try await account()
        try await verify(owner)
        return if let id { try await service.update(id, draft) } else { try await service.add(draft) }
    }

    /// The server has the flight: it replaces the phone's copy, and its forecast is fetched.
    private func saved(_ flight: Flight, editing id: UUID?, _ draft: FlightDraft) async -> Flight {
        let old = id.flatMap(self.flight)
        if let id { forgetIfDifferent(id, draft) }
        flights.removeAll { $0.id == flight.id }
        flights.append(flight)
        flights.sort { $0.departureAt < $1.departureAt }
        if sync != nil { savedDuringSync.insert(flight.id) }
        // The server resets the forecast when the route, time or number changes.
        if old.map({ !Self.sameForecast($0, draft) }) ?? true {
            forecasts[flight.id] = nil
            updates[flight.id] = nil
            carriedForecasts.remove(flight.id)
        }
        connectivity.noteSuccess()
        await persist()
        onSync?()
        // Don't hold the sheet for the forecast: the card fills in when it lands.
        Task {
            await refreshForecast(flight.id)
            await persist()
            onSync?()
        }
        return flight
    }

    /// A new flight's insert answered after it was kept on the phone.
    private func addLanded(_ flight: Flight, _ draft: FlightDraft) async {
        if self.flight(flight.id) == nil {
            // Deleted here meanwhile: deleted there now, and again by each sync until its answer no
            // longer has it (so a failure here changes nothing).
            pendingDeletes.insert(flight.id)
            await persist()
            try? await service.delete(flight.id)
        } else if pendingAdds.first(where: { $0.id == flight.id }) == draft {
            pendingAdds.removeAll { $0.id == flight.id }
            _ = await saved(flight, editing: nil, draft)
        }
        // Edited meanwhile, or a sync sent it already: the queue has it in hand.
    }

    /// The task's result, or nil once `limit` has passed first. The task carries on either way.
    private static func result<T: Sendable>(
        of task: Task<T, Error>, within limit: Duration
    ) async -> Result<T, Error>? {
        let once = Once()
        return await withCheckedContinuation { continuation in
            let timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: nil) }
            }
            Task { @MainActor in
                let result = await task.result
                timer.cancel()
                if once.claim() { continuation.resume(returning: result) }
            }
        }
    }

    /// Keeps a new flight (or an edit to one) on the phone until the next sync saves it.
    private func keepOnPhone(_ draft: FlightDraft) async -> Flight {
        let flight = draft.asFlight
        if !isPending(flight.id) { pendingAdds.append(draft) }
        flights.removeAll { $0.id == flight.id }
        flights.append(flight)
        flights.sort { $0.departureAt < $1.departureAt }
        await persist()
        onSync?()
        return flight
    }

    /// A different flight now: its taps, Live Activity and reminders no longer apply.
    private func forgetIfDifferent(_ id: UUID, _ draft: FlightDraft) {
        guard let old = flight(id),
            old.departureAt != draft.departureAt || old.origin != draft.origin || old.destination != draft.destination
        else { return }
        // Still listed: old ids it replaced keep leading to it.
        InFlight.shared.forget(id, keepAliases: true)
    }

    private static func sameForecast(_ flight: Flight, _ draft: FlightDraft) -> Bool {
        flight.departureAt == draft.departureAt && flight.origin == draft.origin
            && flight.destination == draft.destination && flight.flightNumber == draft.flightNumber
    }

    func delete(_ id: UUID) async {
        if isPending(id) {
            // An add whose answer was lost may have saved it there already: the next sync deletes it.
            pendingDeletes.insert(id)
        } else {
            do {
                let owner = try await account()
                try await verify(owner)
                try await service.delete(id)
            } catch {
                report(error)
                return
            }
        }
        if sync != nil { deletedDuringSync.insert(id) }
        pendingAdds.removeAll { $0.id == id }
        pendingReports.removeAll { $0.flightId == id }
        pendingPasses.removeAll { $0.flightId == id }
        flights.removeAll { $0.id == id }
        forecasts[id] = nil
        updates[id] = nil
        carriedForecasts.remove(id)
        carriedPasses.remove(id)
        // Ends its Live Activity and reminders too.
        InFlight.shared.forget(id)
        await persist()
        onSync?()
    }

    // MARK: Flight passes, landing reports, waitlist

    /// The pass unlocks the flight on the phone at once, and is saved to the server now or on a later sync.
    func recordPass(flightID: UUID, transactionID: String, productID: String) async {
        let pass = FlightPassRecord(transactionId: transactionID, flightId: flightID, productId: productID)
        passes.insert(flightID)
        if !pendingPasses.contains(where: { $0.transactionId == transactionID }) { pendingPasses.append(pass) }
        await persist()
        if connectivity.isOnline, !isPending(flightID) {
            do {
                let owner = try await account()
                try await verify(owner)
                try await service.recordPass(pass)
                pendingPasses.removeAll { $0.transactionId == transactionID }
                if sync != nil { passesSavedDuringSync.insert(flightID) }
                await persist()
            } catch {
                // Kept, and sent on the next sync.
                if error.isConnectivityFailure { connectivity.noteFailure(error) }
            }
        }
        onSync?()
    }

    /// Offline (or on wifi that isn't answering) the rating is kept on the phone, shown as given,
    /// and sent on the next sync. Nil only when the server refused it.
    func submitLandingReport(flightID: UUID, rating: FeltRating) async -> LandingReport? {
        if let existing = reports[flightID] { return existing }
        let forecast = forecasts[flightID]
        let pending = PendingLandingReport(
            rating: rating, report: LandingReport(flightId: flightID, rating: rating, forecast: forecast),
            seatbeltMins: InFlight.shared.seatbelts[flightID].flatMap { $0.isEmpty ? nil : $0 },
            forecastIssuedAt: forecast?.issuedAt)
        guard connectivity.isOnline, !isPending(flightID) else { return await keep(pending) }
        do {
            let owner = try await account()
            try await verify(owner)
            let result = try await submit(pending)
            reports[flightID] = result
            if sync != nil { reportsSavedDuringSync.insert(flightID) }
            connectivity.noteSuccess()
            await persist()
            onSync?()
            return result
        } catch let error as PostgrestError where error.code == "23505" {
            // Already saved (e.g. from the Live Activity): the next sync brings the scored one.
            reports[flightID] = pending.report
            if sync != nil { reportsSavedDuringSync.insert(flightID) }
            await persist()
            return pending.report
        } catch let error as PostgrestError where !error.isSessionRefusal {
            report(error)
            return nil
        } catch {
            if error.isConnectivityFailure { connectivity.noteFailure(error) }
            return await keep(pending)
        }
    }

    private func keep(_ pending: PendingLandingReport) async -> LandingReport {
        pendingReports.removeAll { $0.flightId == pending.flightId }
        pendingReports.append(pending)
        reports[pending.flightId] = pending.report
        await persist()
        onSync?()
        return pending.report
    }

    func joinWaitlist(country: String, airport: String?) async {
        do {
            let owner = try await account()
            try await verify(owner)
            try await service.joinWaitlist(WaitlistEntry(country: country, airport: airport))
            waitlist.insert(country)
            if sync != nil { waitlistSavedDuringSync.insert(country) }
            await persist()
            onSync?()
        } catch {
            report(error)
        }
    }

    // MARK: Helpers

    func flight(_ id: UUID) -> Flight? { flights.first { $0.id == id } }

    /// What's next, in the one order the Flights screen, Calm, auto-arm (and so the Live Activity)
    /// and the free limit share: a flight in the air first, then by expected departure (the
    /// airline's live time when there is one), so a delay re-sorts it. Cancelled flights are never
    /// next; see `cancelledUpcoming`.
    var upcomingFlights: [Flight] {
        let now = Date.now
        let inFlight = InFlight.shared
        // Uses the tapped landing time when there is one.
        let upcoming = flights.filter { !$0.isCancelled && inFlight.landing(of: $0, forecast: forecasts[$0.id]) > now }
        return upcoming.sorted { a, b in
            let aInAir = inFlight.effectiveTakeoff(of: a) <= now
            let bInAir = inFlight.effectiveTakeoff(of: b) <= now
            if aInAir != bInAir { return aInAir }
            if a.expectedDeparture != b.expectedDeparture { return a.expectedDeparture < b.expectedDeparture }
            return a.departureAt < b.departureAt
        }
    }

    var nextFlight: Flight? { upcomingFlights.first }

    /// Cancelled flights still before their scheduled departure, soonest first.
    var cancelledUpcoming: [Flight] {
        flights.filter { $0.isCancelled && $0.departureAt > .now }
    }

    func resetLocalData() async {
        await local.clear()
    }

    private func persist() async {
        guard !snapshotUnread else { return }
        await local.save(
            Snapshot(
                flights: flights, forecasts: forecasts, updates: updates, passes: passes,
                reports: reports, waitlist: waitlist, syncedAt: syncedAt, pendingAdds: pendingAdds,
                userID: ownerID, pendingPasses: pendingPasses, pendingReports: pendingReports,
                previousOwners: previousOwners, carriedForecasts: carriedForecasts, carriedPasses: carriedPasses,
                adoptSecret: adoptSecret, pendingDeletes: pendingDeletes))
    }

    /// Showing what's saved from now on; nil when there was no network to try.
    private func noteFailure(_ error: Error?) {
        isOffline = true
        failedOnConnection = error?.isConnectivityFailure ?? true
    }

    private func report(_ error: Error, quietlyIfOffline: Bool = false) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if error is SyncError {
            // The next sync sorts the account out. Something the person just did still needs a word.
            if !quietlyIfOffline { self.error = "Couldn't reach your account just now. Try again in a moment." }
            return
        }
        if error.isConnectivityFailure {
            connectivity.noteFailure(error)
            noteFailure(error)
            if quietlyIfOffline { return }
        }
        // Sent without a valid session (a refresh failed on the way): refused, like offline.
        if error.isSessionRefusal {
            noteFailure(error)
            if quietlyIfOffline { return }
        }
        // A captive portal answers with its own page, which reads as a broken session or reply.
        if quietlyIfOffline, error is AuthError || error is DecodingError { return }
        self.error = error.localizedDescription
    }
}

enum SyncError: Error {
    /// Requests stopped going out as the account the saved flights belong to.
    case accountChanged
    /// The session was refreshed while answers came in: some may have gone out without it.
    case sessionRefreshed
    /// The server couldn't move the flights to this account just now: tried again on the next call.
    case flightsNotMoved
}

/// Lets only the first of two racing callbacks through.
@MainActor
private final class Once {
    private var claimed = false

    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}

/// What a flight's forecast card should show right now.
enum ForecastState: Equatable {
    case unlocksAt(Date)
    case building
    /// A route only the global outlook covers, with the beta off: "Not forecast yet".
    case betaAvailable
    /// No forecast can cover this route: "We can't forecast this route yet".
    case outOfCoverage
    case ready(Forecast)

    init(flight: Flight, forecast: Forecast?, now: Date = .now, betaOn: Bool? = nil) {
        let betaOn = betaOn ?? GlobalBeta.storedIsOn
        if let forecast, forecast.status == .ready {
            self = forecast.isGlobalOutlook && !betaOn ? .betaAvailable : .ready(forecast)
        } else if forecast?.status == .outOfCoverage {
            self = .outOfCoverage
        } else if !Coverage.covers(flight) && !betaOn {
            self = .betaAvailable
        } else if now < flight.forecastUnlocksAt {
            self = .unlocksAt(flight.forecastUnlocksAt)
        } else {
            self = .building
        }
    }
}
