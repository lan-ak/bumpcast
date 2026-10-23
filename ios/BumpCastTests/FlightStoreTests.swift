import Foundation
import Supabase
import Synchronization
import Testing

@testable import BumpCast

/// The account and sync rules that keep saved flights safe when the session is lost or replaced
/// (AC 1507: a failed refresh on plane wifi became a new account, whose empty list replaced them).
@MainActor
struct FlightStoreTests {
    let a = UUID()
    let b = UUID()
    /// On whole minutes, like real departures (the snapshot keeps dates to the second).
    let saved: [Flight] = (0..<3).map { day in
        let minute = (Date.now.timeIntervalSince1970 / 60).rounded() * 60
        return Flight(
            id: UUID(), origin: "KEWR", destination: "CYYZ",
            departureAt: Date(timeIntervalSince1970: minute + Double(day + 1) * 86400))
    }

    /// A store over a snapshot of `saved` owned by `owner` (or `snapshot`), in its own folder.
    private func makeStore(
        _ service: FakeFlightService, owner: UUID?, snapshot: Snapshot? = nil, connectivity: Connectivity = Connectivity()
    ) async -> (FlightStore, LocalStore) {
        let directory = URL.temporaryDirectory.appending(path: "FlightStoreTests-\(UUID().uuidString)")
        let local = LocalStore(directory: directory)
        await local.save(snapshot ?? Snapshot(flights: saved, syncedAt: .now.addingTimeInterval(-3600), userID: owner))
        let store = FlightStore(
            service: service, local: local, connectivity: connectivity, protectedDataAvailable: { true })
        return (store, local)
    }

    private func forecast(issued: TimeInterval = -3600) -> Forecast {
        Forecast(
            status: .ready, issuedAt: .now.addingTimeInterval(issued), source: "gtg", modelRun: nil,
            grade: .smooth, score: 100, durationMin: 90, cruiseFt: 35000, segments: [], samples: [], route: [])
    }

    @Test func emptyAnswerForAnotherAccountKeepsFlights() async {
        // Requests start out as A, and by the time the (empty) answer is in they go out as B.
        let service = FakeFlightService(stored: a, sessions: [a, a, b], remote: [])
        let (store, local) = await makeStore(service, owner: a)
        await store.reload()
        #expect(store.flights.map(\.id) == saved.map(\.id))
        #expect(store.isOffline)
        #expect(local.load()?.flights.count == 3)
        #expect(service.calls.signUps == 0)
    }

    @Test func emptyAnswerWithoutSessionKeepsFlights() async {
        // The refresh fails in the air: nothing goes out unauthenticated, nothing is replaced.
        let service = FakeFlightService(stored: a, sessions: [], remote: [])
        service.sessionError = URLError(.timedOut)
        let (store, _) = await makeStore(service, owner: a)
        await store.reload()
        #expect(store.flights.count == 3)
        #expect(store.isOffline)
        #expect(service.calls.flights == 0)
        #expect(service.calls.signUps == 0)
    }

    @Test func accountChangeAdoptsFlights() async throws {
        let service = FakeFlightService(stored: b, sessions: [b], remote: saved)
        service.adopted = Set(saved.map(\.id))
        let (store, local) = await makeStore(service, owner: a)
        await store.reload()
        #expect(service.calls.adoptedFrom == [a])
        #expect(store.userID == b)
        #expect(store.flights.map(\.id) == saved.map(\.id))
        #expect(store.pendingAdds.isEmpty)
        #expect(local.load()?.userID == b)
    }

    @Test func adoptionProvesTheInstall() async throws {
        // The secret saved with the flights goes with the move; the profile gets its hash.
        let service = FakeFlightService(stored: b, sessions: [b], remote: saved)
        service.adopted = Set(saved.map(\.id))
        let snapshot = Snapshot(flights: saved, userID: a, adoptSecret: "install-secret")
        let (store, _) = await makeStore(service, owner: a, snapshot: snapshot)
        _ = try await store.account()
        #expect(service.calls.adoptSecrets == ["install-secret"])
        // sha256("install-secret"), as the server compares it.
        let hash = await store.adoptSecretHash()
        #expect(hash == "38b27cef9195e99559ad05d85080d67c370a53f86c20007a158abb5cfbd8d232")
    }

    @Test func newInstallSecretIsSavedBeforeItsHashIsShared() async throws {
        let service = FakeFlightService(stored: a, sessions: [a], remote: saved)
        let (store, local) = await makeStore(service, owner: a)
        let hash = try #require(await store.adoptSecretHash())
        let secret = try #require(local.load()?.adoptSecret)
        #expect(secret.count == 64)
        #expect(hash.count == 64)
        #expect(hash != secret)
        #expect(await store.adoptSecretHash() == hash)
    }

    @Test func adoptFallbackReAddsWithNewIDs() async throws {
        let service = FakeFlightService(stored: b, sessions: [b], remote: [])
        service.adopted = []
        let (store, _) = await makeStore(service, owner: a)
        let id = try await store.account()
        #expect(id == b)
        let old = Set(saved.map(\.id))
        #expect(store.pendingAdds.count == 3)
        #expect(store.pendingAdds.allSatisfy { $0.id.map { !old.contains($0) } ?? false })
        #expect(Set(store.flights.map(\.id)) == Set(store.pendingAdds.compactMap(\.id)))
        #expect(store.flights.map(\.departureAt) == saved.map(\.departureAt))
    }

    @Test func legacySnapshotTakesTheStoredAccount() async throws {
        let service = FakeFlightService(stored: a, sessions: [a], remote: saved)
        let (store, local) = await makeStore(service, owner: nil)
        await store.reload()
        // Asked which of the flights are its own: all of them, so nothing moves or is saved again.
        #expect(service.calls.adoptedFrom == [a])
        #expect(service.calls.signUps == 0)
        #expect(store.userID == a)
        #expect(store.pendingAdds.isEmpty)
        #expect(store.flights.map(\.id) == saved.map(\.id))
        #expect(local.load()?.userID == a)
    }

    @Test func legacySnapshotOfALostAccountIsSavedAgain() async throws {
        // An older build signed up B after losing A, and its reload as B failed: the snapshot still
        // holds A's flights, with no owner. B's empty list must not wipe them.
        let service = FakeFlightService(stored: b, sessions: [b], remote: [])
        service.adoptError = PostgrestError(code: "PGRST002", message: "Could not query the database for the schema cache")
        let (store, local) = await makeStore(service, owner: nil)
        await store.reload()
        // Not known yet whose they are: kept as they are, and asked again next time.
        #expect(store.flights.map(\.id) == saved.map(\.id))
        #expect(store.error == nil)
        #expect(local.load()?.userID == nil)
        #expect(local.load()?.flights.count == 3)
        service.adoptError = nil
        await store.reload()
        #expect(store.userID == b)
        #expect(store.pendingAdds.isEmpty)
        #expect(store.flights.map(\.departureAt) == saved.map(\.departureAt))
        #expect(Set(store.flights.map(\.id)).isDisjoint(with: saved.map(\.id)))
        #expect(Set(service.remote.map(\.id)) == Set(store.flights.map(\.id)))
        #expect(local.load()?.userID == b)
    }

    @Test func deletedPendingFlightIsDeletedOnServer() async throws {
        // The add reached the server but its answer was lost, so the flight is still pending here.
        let service = FakeFlightService(stored: a, sessions: [a], remote: [saved[0]])
        let snapshot = Snapshot(flights: [saved[0]], pendingAdds: [FlightDraft(saved[0])], userID: a)
        let (store, local) = await makeStore(service, owner: a, snapshot: snapshot)
        await store.delete(saved[0].id)
        #expect(store.flight(saved[0].id) == nil)
        #expect(local.load()?.pendingDeletes == [saved[0].id])
        // The delete doesn't go through this time: the answer still leaves the flight out.
        service.deleteError = URLError(.timedOut)
        await store.reload()
        #expect(store.flight(saved[0].id) == nil)
        #expect(store.pendingDeletes == [saved[0].id])
        service.deleteError = nil
        await store.reload()
        #expect(store.flights.isEmpty)
        #expect(service.remote.isEmpty)
        #expect(store.pendingDeletes.isEmpty)
        #expect(local.load()?.pendingDeletes?.isEmpty == true)
    }

    @Test func passRatingAndWaitlistSavedDuringSyncSurviveItsAnswer() async throws {
        let service = FakeFlightService(stored: a, sessions: [a], remote: saved)
        let (store, local) = await makeStore(service, owner: a)
        let id = saved[0].id
        // The sync has read the passes (and ratings) when these are saved.
        service.onPasses = {
            await store.recordPass(flightID: id, transactionID: "t1", productID: "pass")
            _ = await store.submitLandingReport(flightID: id, rating: .aboutRight)
            await store.joinWaitlist(country: "BR", airport: nil)
        }
        await store.reload()
        #expect(store.pendingPasses.isEmpty)
        #expect(store.passes == [id])
        #expect(store.reports[id] != nil)
        #expect(store.waitlist == ["BR"])
        #expect(local.load()?.passes == [id])
        #expect(local.load()?.reports[id] != nil)
    }

    @Test func userActionsSayWhenTheAccountCantBeReached() async throws {
        // The flights' account was lost and moving them keeps failing.
        let service = FakeFlightService(stored: b, sessions: [b], remote: saved)
        service.adoptError = PostgrestError(code: "PGRST002", message: "Could not query the database for the schema cache")
        let (store, _) = await makeStore(service, owner: a)
        await store.reload()
        #expect(store.error == nil)
        await store.delete(saved[0].id)
        #expect(store.flight(saved[0].id) != nil)
        #expect(store.error != nil)
    }

    @Test func concurrentReloadsShareOneSync() async {
        let service = FakeFlightService(stored: a, sessions: [a], remote: saved)
        let (store, _) = await makeStore(service, owner: a)
        async let first: Void = store.reload()
        async let second: Void = store.reload()
        _ = await (first, second)
        #expect(service.calls.flights == 1)
        #expect(service.calls.signIns == 1)
    }

    @Test func offlineRatingIsKeptAndSentNextSync() async throws {
        var landed = saved[0]
        landed.departureAt = .now.addingTimeInterval(-3 * 3600)
        let service = FakeFlightService(stored: a, sessions: [a], remote: [landed])
        let directory = URL.temporaryDirectory.appending(path: "FlightStoreTests-\(UUID().uuidString)")
        let local = LocalStore(directory: directory)
        await local.save(Snapshot(flights: [landed], userID: a))
        service.submitError = URLError(.notConnectedToInternet)
        let store = FlightStore(
            service: service, local: local, connectivity: Connectivity(), protectedDataAvailable: { true })
        let shown = await store.submitLandingReport(flightID: landed.id, rating: .bumpier)
        #expect(shown?.feltRelative == .bumpier)
        #expect(store.isReportPending(landed.id))
        service.submitError = nil
        await store.reload()
        #expect(!store.isReportPending(landed.id))
        #expect(service.calls.reports == 2)
    }

    @Test func tokenRefreshedMidFetchKeepsSavedData() async {
        // A request found the token expired and couldn't refresh it, so it went out with the public
        // key and came back empty; the next check refreshed fine. Every check sees a new token here.
        let service = FakeFlightService(stored: a, sessions: [a], remote: [])
        service.rotateTokens = true
        let snapshot = Snapshot(
            flights: saved, forecasts: [saved[0].id: forecast()], passes: [saved[1].id],
            syncedAt: .now.addingTimeInterval(-3600), userID: a)
        let (store, local) = await makeStore(service, owner: a, snapshot: snapshot)
        await store.reload()
        #expect(store.flights.map(\.id) == saved.map(\.id))
        #expect(store.forecasts[saved[0].id] != nil)
        #expect(store.passes == [saved[1].id])
        #expect(store.isOffline)
        #expect(local.load()?.flights.count == 3)
        // Tried once more with the new token, then gave up for now.
        #expect(service.calls.flights == 2)
    }

    @Test func tokenRefreshedMidFetchRetriesOnce() async {
        // The first answer went out without the session; the retry, with the new token, is real.
        let service = FakeFlightService(stored: a, sessions: [a], remote: saved)
        service.flightAnswers = [[]]
        // Refreshed between the first fetch and its check, then stable.
        service.tokens = ["t1", "t1", "t2"]
        let (store, _) = await makeStore(service, owner: a)
        await store.reload()
        #expect(store.flights.map(\.id) == saved.map(\.id))
        #expect(!store.isOffline)
        #expect(service.calls.flights == 2)
    }

    @Test func refreshedForecastAnswerIsIgnored() async {
        let service = FakeFlightService(stored: a, sessions: [a], remote: saved)
        let snapshot = Snapshot(flights: saved, forecasts: [saved[0].id: forecast()], userID: a)
        let (store, _) = await makeStore(service, owner: a, snapshot: snapshot)
        service.rotateTokens = true
        await store.refreshForecast(saved[0].id)
        #expect(store.forecasts[saved[0].id] != nil)
        // With the same session throughout, "no forecast" is the server's answer and is mirrored.
        service.rotateTokens = false
        await store.refreshForecast(saved[0].id)
        #expect(store.forecasts[saved[0].id] == nil)
    }

    @Test func forecastForTheRouteBeforeAnEditIsIgnored() async {
        let service = FakeFlightService(stored: a, sessions: [a], remote: saved)
        let id = saved[0].id
        service.forecasts = [id: forecast()]
        // Kept on the phone, so the edit itself fetches nothing that could hide the old answer.
        let snapshot = Snapshot(flights: saved, pendingAdds: [FlightDraft(saved[0])], userID: a)
        let (store, _) = await makeStore(service, owner: a, snapshot: snapshot)
        // The route changes while the old route's forecast is on its way.
        service.onForecast = { _ in
            var draft = FlightDraft(store.flight(id)!)
            draft.destination = "KBOS"
            await store.save(draft, editing: id)
        }
        await store.refreshForecast(id)
        #expect(store.flight(id)?.destination == "KBOS")
        #expect(store.forecasts[id] == nil)
    }

    @Test func publicKeyRefusalIsQuiet() async {
        // With the public key's privileges revoked, an unauthenticated read fails instead of coming back empty.
        let service = FakeFlightService(stored: a, sessions: [a], remote: [])
        service.flightsError = PostgrestError(code: "42501", message: "permission denied for table flights")
        let (store, local) = await makeStore(service, owner: a)
        await store.reload()
        #expect(store.flights.count == 3)
        #expect(store.isOffline)
        #expect(store.error == nil)
        #expect(local.load()?.flights.count == 3)
    }

    @Test func failedAdoptionKeepsOwnerAndRetries() async throws {
        let service = FakeFlightService(stored: b, sessions: [b], remote: saved)
        service.adoptError = PostgrestError(code: "PGRST002", message: "Could not query the database for the schema cache")
        let (store, local) = await makeStore(service, owner: a)
        var failed = false
        do { _ = try await store.account() } catch { failed = error is SyncError }
        #expect(failed)
        // Nothing saved again under new ids, and the old account is still the one to move from.
        #expect(store.pendingAdds.isEmpty)
        #expect(store.flights.map(\.id) == saved.map(\.id))
        #expect(local.load()?.userID == a)
        #expect(local.load()?.previousOwners == [b])
        service.adoptError = nil
        service.adopted = Set(saved.map(\.id))
        let id = try await store.account()
        #expect(id == b)
        #expect(service.calls.adoptedFrom == [a, a])
        #expect(store.pendingAdds.isEmpty)
        #expect(local.load()?.userID == b)
        #expect(local.load()?.previousOwners == [])
    }

    @Test func adoptionIsBatched() async throws {
        let many = (0..<250).map { index in
            Flight(
                id: UUID(), origin: "KEWR", destination: "CYYZ",
                departureAt: saved[0].departureAt.addingTimeInterval(Double(index) * 60))
        }
        let service = FakeFlightService(stored: b, sessions: [b], remote: many)
        service.adopted = Set(many.map(\.id))
        let (store, _) = await makeStore(service, owner: a, snapshot: Snapshot(flights: many, userID: a))
        _ = try await store.account()
        #expect(service.calls.adoptBatches == [200, 50])
        #expect(store.pendingAdds.isEmpty)
    }

    @Test func reAddedFlightsKeepPassesRatingsAndForecast() async throws {
        // A server without the move: saved again under new ids, with what the phone had for them.
        let service = FakeFlightService(stored: b, sessions: [b], remote: [])
        service.adoptError = PostgrestError(code: "PGRST202", message: "Could not find the function")
        let pass = FlightPassRecord(transactionId: "t1", flightId: saved[0].id, productId: "pass")
        let rating = PendingLandingReport(
            rating: .aboutRight, report: LandingReport(flightId: saved[2].id, rating: .aboutRight, forecast: nil),
            seatbeltMins: nil, forecastIssuedAt: nil)
        let snapshot = Snapshot(
            flights: saved, forecasts: [saved[0].id: forecast()], passes: [saved[0].id, saved[1].id],
            reports: [saved[2].id: rating.report], userID: a, pendingPasses: [pass], pendingReports: [rating])
        let (store, _) = await makeStore(service, owner: a, snapshot: snapshot)
        _ = try await store.account()
        let new = Dictionary(uniqueKeysWithValues: store.flights.map { ($0.departureAt, $0.id) })
        let ids = saved.map { new[$0.departureAt]! }
        #expect(Set(ids).isDisjoint(with: saved.map(\.id)))
        #expect(store.pendingPasses.map(\.flightId) == [ids[0]])
        #expect(store.pendingReports.map(\.flightId) == [ids[2]])
        #expect(store.reports[ids[2]] != nil)
        #expect(store.passes == [ids[0], ids[1]])
        #expect(store.forecasts[ids[0]] != nil)
        // The server has no forecast for the new rows yet, and the old account keeps the other pass.
        await store.reload()
        #expect(store.pendingAdds.isEmpty)
        #expect(store.pendingPasses.isEmpty)
        #expect(store.passes == [ids[0], ids[1]])
        #expect(store.forecasts[ids[0]] != nil)
        #expect(service.calls.reports == 1)
    }

    @Test func editAndDeleteDuringSendReachServer() async throws {
        let pendingA = FlightDraft(saved[0])
        let pendingB = FlightDraft(saved[1])
        let service = FakeFlightService(stored: a, sessions: [a], remote: [saved[2]])
        let snapshot = Snapshot(flights: saved, pendingAdds: [pendingA, pendingB], userID: a)
        let (store, _) = await makeStore(service, owner: a, snapshot: snapshot)
        var edited = pendingA
        edited.flightNumber = "AC 1507"
        edited.notify = false
        let edit = edited
        service.onAdd = { id in
            if id == pendingA.id { await store.save(edit, editing: id) }
            if id == pendingB.id { await store.delete(id) }
        }
        await store.reload()
        #expect(store.pendingAdds.isEmpty)
        #expect(service.remote.first { $0.id == saved[0].id }?.flightNumber == "AC 1507")
        #expect(!service.remote.contains { $0.id == saved[1].id })
        #expect(store.flight(saved[0].id)?.flightNumber == "AC 1507")
        #expect(store.flight(saved[1].id) == nil)
    }

    @Test func pendingIDTakenByLostAccountIsSavedAgain() async throws {
        // An add whose answer was lost landed on the old account, which didn't hand it over.
        let pending = FlightDraft(saved[0])
        let service = FakeFlightService(stored: a, sessions: [a], remote: [])
        service.addError = PostgrestError(code: "23505", message: "duplicate key value violates unique constraint")
        service.updateError = PostgrestError(code: "PGRST116", message: "Cannot coerce the result to a single JSON object")
        let snapshot = Snapshot(flights: [saved[0]], pendingAdds: [pending], userID: a)
        let (store, _) = await makeStore(service, owner: a, snapshot: snapshot)
        await store.reload()
        let again = try #require(store.pendingAdds.first?.id)
        #expect(store.pendingAdds.count == 1)
        #expect(again != saved[0].id)
        #expect(store.flights.map(\.id) == [again])
    }

    @Test func notAnsweringWifiKeepsNewFlightOnPhone() async {
        let service = FakeFlightService(stored: a, sessions: [a], remote: saved)
        let connectivity = Connectivity()
        connectivity.noteFailure(URLError(.timedOut))
        let (store, _) = await makeStore(service, owner: a, connectivity: connectivity)
        let draft = FlightDraft(id: nil, origin: "KJFK", destination: "KLAX", departureAt: .now.addingTimeInterval(86400))
        let flight = await store.save(draft)
        #expect(flight != nil)
        #expect(store.pendingAdds.count == 1)
        #expect(service.calls.adds == 0)
    }

    @Test func lessCertainForecastForSameDepartureIsHeldBack() {
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        func forecast(_ source: String, issued: TimeInterval) -> Forecast {
            var forecast = Forecast(
                status: .ready, issuedAt: departure.addingTimeInterval(issued), source: source, modelRun: nil,
                grade: .smooth, score: 100, durationMin: 60, cruiseFt: 35000, segments: [], samples: [], route: [])
            forecast.departureAt = departure
            return forecast
        }
        let confirmed = forecast("gtg", issued: -4 * 3600)
        #expect(FlightStore.isRegression(forecast("gfs", issued: -3 * 3600), from: confirmed, departure: departure))
        // Hours later, or more certain, it replaces it.
        #expect(!FlightStore.isRegression(forecast("gfs", issued: 0), from: confirmed, departure: departure))
        #expect(!FlightStore.isRegression(confirmed, from: forecast("gfs", issued: -5 * 3600), departure: departure))
    }

    @Test func snapshotWithoutUserIDDecodes() throws {
        // The shape an older build saved: no owner, no pending passes or reports.
        struct OldSnapshot: Encodable {
            var flights: [Flight]
            var forecasts: [UUID: Forecast] = [:]
            var updates: [UUID: [FlightUpdate]] = [:]
            var passes: Set<UUID> = []
            var reports: [UUID: LandingReport] = [:]
            var waitlist: Set<String> = []
            var syncedAt: Date? = .now
            var pendingAdds: [FlightDraft]? = nil
        }
        let directory = URL.temporaryDirectory.appending(path: "FlightStoreTests-\(UUID().uuidString)")
        let local = LocalStore(directory: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(OldSnapshot(flights: saved)).write(to: directory.appending(path: "snapshot.json"))
        let snapshot = try #require(local.load())
        #expect(snapshot.flights.count == 3)
        #expect(snapshot.userID == nil)
        #expect(snapshot.pendingPasses == nil)
        #expect(snapshot.pendingReports == nil)
    }
}

/// A server with one account per session, whose answers each test sets.
final class FakeFlightService: FlightService {
    struct Calls {
        var signIns = 0
        var signUps = 0
        var sessions = 0
        var flights = 0
        var adds = 0
        var reports = 0
        var deletes = 0
        var adoptedFrom: [UUID] = []
        var adoptBatches: [Int] = []
        var adoptSecrets: [String] = []
    }

    private struct State {
        var stored: UUID?
        /// What `session` answers, in turn; the last one repeats.
        var sessions: [UUID]
        var sessionError: URLError?
        /// The token each check finds, in turn; the last one repeats.
        var tokens = ["token"]
        /// A new token on every check, as if each one found it refreshed.
        var rotateTokens = false
        var remote: [Flight]
        /// The first answers to `flights()`, in turn, before `remote`.
        var flightAnswers: [[Flight]] = []
        var flightsError: PostgrestError?
        var addError: PostgrestError?
        var updateError: PostgrestError?
        var forecasts: [UUID: Forecast] = [:]
        var passes: Set<UUID> = []
        var adopted: Set<UUID> = []
        var adoptError: PostgrestError?
        var submitError: URLError?
        var deleteError: URLError?
        /// Runs on the main actor once the passes have been read, before they're answered.
        var onPasses: (@MainActor @Sendable () async -> Void)?
        /// Runs on the main actor while an insert is on its way.
        var onAdd: (@MainActor @Sendable (UUID) async -> Void)?
        /// Runs on the main actor once a forecast has been read, before it's answered.
        var onForecast: (@MainActor @Sendable (UUID) async -> Void)?
        var calls = Calls()
    }

    private let state: Mutex<State>

    init(stored: UUID?, sessions: [UUID], remote: [Flight]) {
        state = Mutex(State(stored: stored, sessions: sessions, remote: remote))
    }

    var calls: Calls { state.withLock { $0.calls } }
    var remote: [Flight] { state.withLock { $0.remote } }
    var adopted: Set<UUID> {
        get { state.withLock { $0.adopted } }
        set { state.withLock { $0.adopted = newValue } }
    }
    var adoptError: PostgrestError? {
        get { state.withLock { $0.adoptError } }
        set { state.withLock { $0.adoptError = newValue } }
    }
    var sessionError: URLError? {
        get { state.withLock { $0.sessionError } }
        set { state.withLock { $0.sessionError = newValue } }
    }
    var tokens: [String] {
        get { state.withLock { $0.tokens } }
        set { state.withLock { $0.tokens = newValue } }
    }
    var rotateTokens: Bool {
        get { state.withLock { $0.rotateTokens } }
        set { state.withLock { $0.rotateTokens = newValue } }
    }
    var flightAnswers: [[Flight]] {
        get { state.withLock { $0.flightAnswers } }
        set { state.withLock { $0.flightAnswers = newValue } }
    }
    var flightsError: PostgrestError? {
        get { state.withLock { $0.flightsError } }
        set { state.withLock { $0.flightsError = newValue } }
    }
    var addError: PostgrestError? {
        get { state.withLock { $0.addError } }
        set { state.withLock { $0.addError = newValue } }
    }
    var updateError: PostgrestError? {
        get { state.withLock { $0.updateError } }
        set { state.withLock { $0.updateError = newValue } }
    }
    var forecasts: [UUID: Forecast] {
        get { state.withLock { $0.forecasts } }
        set { state.withLock { $0.forecasts = newValue } }
    }
    var submitError: URLError? {
        get { state.withLock { $0.submitError } }
        set { state.withLock { $0.submitError = newValue } }
    }
    var deleteError: URLError? {
        get { state.withLock { $0.deleteError } }
        set { state.withLock { $0.deleteError = newValue } }
    }
    var onPasses: (@MainActor @Sendable () async -> Void)? {
        get { state.withLock { $0.onPasses } }
        set { state.withLock { $0.onPasses = newValue } }
    }
    var onAdd: (@MainActor @Sendable (UUID) async -> Void)? {
        get { state.withLock { $0.onAdd } }
        set { state.withLock { $0.onAdd = newValue } }
    }
    var onForecast: (@MainActor @Sendable (UUID) async -> Void)? {
        get { state.withLock { $0.onForecast } }
        set { state.withLock { $0.onForecast = newValue } }
    }

    func signIn(allowSignUp: Bool) async throws -> UUID {
        try state.withLock { state in
            state.calls.signIns += 1
            if let stored = state.stored { return stored }
            guard allowSignUp else { throw URLError(.userAuthenticationRequired) }
            state.calls.signUps += 1
            let id = UUID()
            state.stored = id
            state.sessions = [id]
            return id
        }
    }

    func storedUserID() -> UUID? { state.withLock { $0.stored } }

    func session(refreshingWithin margin: TimeInterval) async throws -> AccountSession {
        try state.withLock { state in
            if let error = state.sessionError { throw error }
            guard let next = state.sessions.first else { throw URLError(.userAuthenticationRequired) }
            if state.sessions.count > 1 { state.sessions.removeFirst() }
            state.calls.sessions += 1
            if state.rotateTokens { return AccountSession(userID: next, accessToken: "token-\(state.calls.sessions)") }
            let token = state.tokens.first ?? "token"
            if state.tokens.count > 1 { state.tokens.removeFirst() }
            return AccountSession(userID: next, accessToken: token)
        }
    }

    func adoptFlights(_ ids: [UUID], from owner: UUID, secret: String) async throws -> Set<UUID> {
        let result: Result<Set<UUID>, PostgrestError> = state.withLock { state in
            state.calls.adoptedFrom.append(owner)
            state.calls.adoptBatches.append(ids.count)
            state.calls.adoptSecrets.append(secret)
            if let error = state.adoptError { return .failure(error) }
            // Asked of the caller itself: nothing moves, and its own come back.
            if owner == state.stored { return .success(Set(state.remote.map(\.id)).intersection(ids)) }
            return .success(state.adopted.intersection(ids))
        }
        return try result.get()
    }

    func flights() async throws -> [Flight] {
        let result: Result<[Flight], PostgrestError> = state.withLock { state in
            state.calls.flights += 1
            if let error = state.flightsError { return .failure(error) }
            if !state.flightAnswers.isEmpty { return .success(state.flightAnswers.removeFirst()) }
            return .success(state.remote)
        }
        return try result.get()
    }

    func flight(_ id: UUID) async throws -> Flight {
        let found = state.withLock { state in state.remote.first { flight in flight.id == id } }
        guard let found else { throw URLError(.fileDoesNotExist) }
        return found
    }

    func add(_ draft: FlightDraft) async throws -> Flight {
        let hook = state.withLock { state in
            state.calls.adds += 1
            return state.onAdd
        }
        if let hook, let id = draft.id { await hook(id) }
        let flight = draft.asFlight
        let result: Result<Flight, PostgrestError> = state.withLock { state in
            if let error = state.addError { return .failure(error) }
            state.remote.append(flight)
            return .success(flight)
        }
        return try result.get()
    }

    func update(_ id: UUID, _ draft: FlightDraft) async throws -> Flight {
        var flight = draft.asFlight
        flight.id = id
        let updated = flight
        let result: Result<Flight, PostgrestError> = state.withLock { state in
            if let error = state.updateError { return .failure(error) }
            state.remote.removeAll { $0.id == id }
            state.remote.append(updated)
            return .success(updated)
        }
        return try result.get()
    }

    func delete(_ id: UUID) async throws {
        try state.withLock { state in
            state.calls.deletes += 1
            if let error = state.deleteError { throw error }
            state.remote.removeAll { $0.id == id }
        }
    }
    func latestForecast(for flightID: UUID) async throws -> Forecast? {
        let (forecast, hook) = state.withLock { state in
            defer { state.onForecast = nil }
            return (state.forecasts[flightID], state.onForecast)
        }
        if let hook { await hook(flightID) }
        return forecast
    }
    func updates(for flightID: UUID) async throws -> [FlightUpdate] { [] }
    func searchFlights(number: String, date: String) async throws -> FlightSearchResult { .unavailable }
    func routeFlights(origin: String, destination: String, date: String) async throws -> FlightSearchResult {
        .unavailable
    }
    func registerDevice(token: String, environment: String) async throws {}
    func registerLiveActivity(flightID: UUID, token: String, environment: String) async throws {}
    func endLiveActivity(flightID: UUID) async throws {}
    func saveProfile(_ profile: ProfileRecord) async throws -> ProfileRecord { profile }
    func passFlightIDs() async throws -> Set<UUID> {
        let (passes, hook) = state.withLock { state in
            defer { state.onPasses = nil }
            return (state.passes, state.onPasses)
        }
        if let hook { await hook() }
        return passes
    }
    func recordPass(_ pass: FlightPassRecord) async throws { _ = state.withLock { $0.passes.insert(pass.flightId) } }
    func landingReports() async throws -> [LandingReport] { [] }

    func submitLandingReport(
        flightID: UUID, rating: FeltRating, seatbeltMins: [Int]?, forecastIssuedAt: Date?
    ) async throws -> LandingReport {
        try state.withLock { state in
            state.calls.reports += 1
            if let error = state.submitError { throw error }
        }
        return LandingReport(flightId: flightID, felt: nil, feltRelative: rating, forecastWorst: nil, matched: nil)
    }

    func accuracyStats() async throws -> AccuracyStats? { nil }
    func waitlistCountries() async throws -> Set<String> { [] }
    func joinWaitlist(_ entry: WaitlistEntry) async throws {}
    func pilotReports(since: Date) async throws -> [PilotReport] { [] }
    func turbulenceGrids(levelFt: Int) async throws -> [TurbulenceGrid] { [] }
}
