import Foundation
import Observation
import Synchronization
import UIKit

/// Adds every flight found in the connected mailbox and keeps it up to date from later booking
/// emails (E1 in BOOKING_IMPORT.md, revision 2). There's no switch: nothing happens out of sight,
/// since every add, change or cancellation shows on the flight and in a toast with Undo.
/// Mail is read on the phone; only a flight number and day go to flight search, and what it
/// finds is saved like a flight added by hand. What came from email is kept here on the phone.
@Observable @MainActor
final class EmailImport {
    static let shared = EmailImport()

    /// A flight found while the free limit was reached: one tap adds it (through the paywall).
    struct ReadyFlight: Codable, Hashable, Identifiable, Sendable {
        let key: String
        var draft: FlightDraft
        var id: String { key }
        var flight: Flight { draft.asFlight }
    }

    /// Why a booking couldn't be added by itself. Nothing is dropped silently.
    enum NeedsYouReason: String, Codable, Sendable {
        case severalLegs, notFound, noSchedule, noAirports

        var text: String {
            switch self {
            case .severalLegs: "It has more than one flight that day, so we couldn't tell which is yours."
            case .notFound: "We couldn't find this flight on that day. The number may have changed."
            case .noSchedule: "We couldn't find a schedule for this flight yet."
            case .noAirports: "Its schedule isn't out yet, and the email didn't say which airports."
            }
        }
    }

    struct NeedsYouItem: Codable, Hashable, Identifiable, Sendable {
        let key: String
        let number: String
        let day: String
        let reason: NeedsYouReason
        var id: String { key }

        /// The day at noon on the phone, for Add flight's day tiles.
        var date: Date? {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        }

        var title: String {
            "A booking for \(number) on \(date?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? day)"
        }
    }

    /// A flight an email changed (a rebooking or new time): what it was, for the card and Undo.
    struct Change: Codable, Hashable, Sendable {
        var was: FlightDraft
        var at: Date
    }

    enum ScanResult: Equatable {
        case found(added: Int, ready: Int, needsYou: Int)
        case nothingNew
        case offline
        case unavailable
    }

    /// How far a scan has got: "Checked 50 of 120 booking emails", "3 flights added so far".
    struct Progress: Equatable {
        var checked = 0
        var total = 0
        var added = 0
    }

    /// The first scan's "We added N flights" sheet.
    struct Summary: Equatable {
        var added: [UUID]
    }

    /// What a scan did, for its toast and Undo.
    enum Event: Equatable {
        case added(UUID)
        case cancelled(UUID)
        case changed(UUID)
    }

    /// Everything kept on the phone, in UserDefaults. No message content: only message ids, and
    /// a salted hash of each booking reference.
    struct Ledger: Codable, Equatable {
        var lastChecked: Date?
        var flightsFound = 0
        var ready: [ReadyFlight] = []
        var needsYou: [NeedsYouItem] = []
        /// Flights this added, and when: the "Added from your email" line and Undo for a day.
        var imported: [UUID: Date] = [:]
        /// Each imported flight's booking hash, so a later email changes only its own booking.
        var hashes: [UUID: String] = [:]
        /// Removed or undone: number and day, never added again.
        var dismissed: Set<String> = []
        /// Marked cancelled by an email (an overlay on the flight's own status), and when.
        var cancelled: [UUID: Date] = [:]
        /// Cancellations undone: the same booking's cancellation never marks it again.
        var keptAfterCancel: Set<String> = []
        var changes: [UUID: Change] = [:]
        /// Messages already read, so each is parsed once (newest last).
        var processed: [String] = []
        /// Booking emails still to read after the last scan: the next open carries on.
        var backlog = 0
        var firstScanDone = false
        var salt = UUID().uuidString

        mutating func added(_ id: UUID, key: String, hash: String?, at date: Date) {
            imported[id] = date
            hashes[id] = hash
            flightsFound += 1
            ready.removeAll { $0.key == key }
            needsYou.removeAll { $0.key == key }
        }

        /// Removed from email's list of flights (Remove, Undo, or deleted): its key never comes back.
        mutating func removed(_ id: UUID, key: String?) {
            imported[id] = nil
            hashes[id] = nil
            changes[id] = nil
            cancelled[id] = nil
            if let key { dismissed.insert(key) }
        }

        func shouldCancel(_ key: String) -> Bool { !keptAfterCancel.contains(key) }

        mutating func markCancelled(_ id: UUID, at date: Date) { cancelled[id] = date }

        /// Undo: the flight is back, and this booking's cancellation is handled for good.
        mutating func undoCancel(_ id: UUID, key: String) {
            cancelled[id] = nil
            keptAfterCancel.insert(key)
        }

        mutating func changed(_ id: UUID, was: FlightDraft, hash: String?, at date: Date) {
            changes[id] = Change(was: was, at: date)
            if let hash { hashes[id] = hash }
        }

        /// Undo: what it was, to save back; the new number and day are never applied again.
        mutating func undoChange(_ id: UUID, newKey: String) -> FlightDraft? {
            dismissed.insert(newKey)
            return changes.removeValue(forKey: id)?.was
        }

        mutating func needs(_ item: NeedsYouItem) {
            if !needsYou.contains(where: { $0.key == item.key }) { needsYou.append(item) }
        }

        func isRecent(_ date: Date?, now: Date) -> Bool {
            date.map { now.timeIntervalSince($0) < EmailImport.recentWindow } ?? false
        }
    }

    /// Checks at most this often when the app comes back (sooner while a big inbox is part-read).
    static let interval: TimeInterval = 30 * 60
    /// Searches per scan, so the hourly search limit is never at risk (BOOKING_IMPORT.md).
    static let searchesPerScan = 6
    static let messagesPerScan = 50
    /// How long "Added from your email", "Updated from your email" and Undo stay.
    nonisolated static let recentWindow: TimeInterval = 24 * 3600

    private(set) var provider: MailProvider?
    private(set) var email: String?
    /// The provider stopped accepting the sign-in: connect again to keep finding flights.
    private(set) var needsReconnect = false
    private(set) var isConnecting = false
    private(set) var isScanning = false
    private(set) var lastResult: ScanResult?
    private(set) var progress: Progress?
    /// Set when the first scan ends; the connect sheet turns into the summary.
    var summary: Summary?
    /// Connecting didn't go through (not a cancel): said in the sheet.
    var connectFailed = false

    private(set) var ledger: Ledger { didSet { save() } }
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var searchesLeft = 0
    @ObservationIgnored private var events: [Event] = []

    private let store: FlightStore
    private let session: MailSession
    private let scanner: MailScanner
    private let defaults: UserDefaults
    private static let ledgerKey = "email.import"

    init(
        store: FlightStore = .shared, session: MailSession = .shared, scanner: MailScanner = MailScanner(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.session = session
        self.scanner = scanner
        self.defaults = defaults
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
        EmailCancellations.shared.set(Set(ledger.cancelled.keys))
    }

    var isConnected: Bool { provider != nil }
    var lastChecked: Date? { ledger.lastChecked }
    var flightsFound: Int { ledger.flightsFound }
    var backlog: Int { ledger.backlog }

    /// Still ahead and not added some other way meanwhile.
    var readyToAdd: [ReadyFlight] {
        ledger.ready.filter { item in
            item.draft.departureAt > .now && existing(number: item.draft.flightNumber, day: Self.day(fromKey: item.key)) == nil
        }
    }

    /// Not added some other way meanwhile, and not past.
    var needsYou: [NeedsYouItem] {
        let today = Date.now.searchDay(in: .current)
        return ledger.needsYou.filter { $0.day >= today && existing(number: $0.number, day: $0.day) == nil }
    }

    /// The providers to offer: Gmail, and Outlook once its client ID is set.
    var providers: [MailProvider] { MailProvider.available }

    /// Off in Release builds until Google verifies the Gmail scope (EMAIL_IMPORT_SETUP.md,
    /// "Coming soon"): Add a flight and Settings say "Coming soon", and nothing connects or scans.
    /// Debug builds keep it on to work on it; launch with `-emailImportComingSoon` to see Release.
    static var isReady: Bool {
        #if DEBUG
            !ProcessInfo.processInfo.arguments.contains("-emailImportComingSoon")
        #else
            false
        #endif
    }

    /// The account from the Keychain (unreadable before the first unlock, so tried again later).
    func load() async {
        guard !loaded else { return }
        if let account = await session.current() {
            provider = account.provider
            email = account.email
            loaded = true
        } else {
            loaded = UIApplication.shared.isProtectedDataAvailable
        }
    }

    // MARK: Connecting

    func connect(_ provider: MailProvider) async {
        guard Self.isReady, !isConnecting else { return }
        isConnecting = true
        connectFailed = false
        defer { isConnecting = false }
        do {
            let account = try await session.connect(provider)
            self.provider = account.provider
            email = account.email
            needsReconnect = false
            loaded = true
        } catch MailError.cancelled {
            // They closed the sign-in sheet: nothing to say.
            return
        } catch {
            connectFailed = true
            return
        }
        await scan()
    }

    /// Ends access and forgets the tokens and which messages were read. Flights already added
    /// stay, and so does what's on them (cancelled, changed, removed).
    func disconnect() async {
        await session.disconnect()
        provider = nil
        email = nil
        needsReconnect = false
        lastResult = nil
        progress = nil
        summary = nil
        ledger.processed = []
        ledger.ready = []
        ledger.needsYou = []
        ledger.backlog = 0
        ledger.lastChecked = nil
        ledger.flightsFound = 0
        ledger.firstScanDone = false
    }

    // MARK: Scanning

    /// On coming back to the app and in background refresh: at most every 30 minutes, unless a
    /// big inbox is still part-read.
    func scanIfDue(messages limit: Int = EmailImport.messagesPerScan) async {
        await load()
        guard Self.isReady, isConnected, !needsReconnect, Paywalls.shared.hasEmailImport else { return }
        if ledger.backlog == 0, let last = ledger.lastChecked, last.timeIntervalSinceNow > -Self.interval { return }
        await scan(messages: limit)
    }

    func scan(messages limit: Int = EmailImport.messagesPerScan) async {
        await load()
        // A Pro feature: a lapsed subscription stops the checks (Settings offers it again).
        guard Self.isReady, isConnected, !isScanning, Paywalls.shared.hasEmailImport else { return }
        guard Connectivity.shared.isOnline else {
            lastResult = .offline
            return
        }
        isScanning = true
        events = []
        defer {
            isScanning = false
            progress = nil
        }
        let first = !ledger.firstScanDone
        do {
            let (provider, token) = try await session.accessToken()
            let inbox = try await scanner.unread(provider: provider, token: token, processed: Set(ledger.processed))
            progress = Progress(total: inbox.ids.count)
            // Read first (each one parsed here, off the main thread), then act oldest first, so
            // a later email (a change or cancellation) has the last word.
            var read: [(id: String, received: Date, candidates: [BookingCandidate])] = []
            for id in inbox.ids.prefix(limit) {
                try Task.checkCancellation()
                let message = try await scanner.message(id, in: inbox, provider: provider, token: token)
                let salt = ledger.salt
                let candidates = await Task.detached { BookingParser.candidates(in: message, salt: salt) }.value
                read.append((id, message.received, candidates))
                progress?.checked += 1
            }
            searchesLeft = Self.searchesPerScan
            var counts = (added: 0, ready: 0, needsYou: 0)
            var handled: [String] = []
            for message in read.sorted(by: { $0.received < $1.received }) {
                var done = true
                for candidate in message.candidates {
                    switch await handle(candidate) {
                    case .added:
                        counts.added += 1
                        progress?.added += 1
                    case .ready: counts.ready += 1
                    case .needsYou: counts.needsYou += 1
                    case .later: done = false
                    case .skipped, .cancelled, .changed: break
                    }
                }
                // Left for the next scan when a search didn't fit in this one.
                if done { handled.append(message.id) }
            }
            ledger.processed = Array((ledger.processed + handled).suffix(5000))
            ledger.backlog = max(0, inbox.ids.count - handled.count)
            ledger.lastChecked = .now
            ledger.firstScanDone = true
            forgetGone()
            needsReconnect = false
            let changedSomething = counts.added + counts.ready + counts.needsYou > 0 || !events.isEmpty
            lastResult = changedSomething ? .found(added: counts.added, ready: counts.ready, needsYou: counts.needsYou) : .nothingNew
            if first {
                summary = Summary(added: events.compactMap { if case .added(let id) = $0 { id } else { nil } })
            } else {
                announce(events)
            }
        } catch MailError.signedOut {
            needsReconnect = true
            lastResult = nil
        } catch {
            lastResult = .unavailable
        }
    }

    private enum Outcome { case skipped, added, ready, needsYou, cancelled, changed, later }

    private func handle(_ candidate: BookingCandidate) async -> Outcome {
        let saved = existing(number: candidate.number, day: candidate.day)
        if candidate.cancelled {
            ledger.ready.removeAll { $0.key == candidate.key }
            ledger.needsYou.removeAll { $0.key == candidate.key }
            guard let saved, !saved.isCancelled, ledger.shouldCancel(candidate.key) else { return .skipped }
            ledger.markCancelled(saved.id, at: .now)
            applyCancellations()
            events.append(.cancelled(saved.id))
            return .cancelled
        }
        guard !ledger.dismissed.contains(candidate.key), !ledger.ready.contains(where: { $0.key == candidate.key }) else {
            return .skipped
        }
        // Already saved at the time the email gives (or it gives none): nothing to look up.
        if let saved, candidate.time == nil || candidate.time == Self.localTime(of: saved) { return .skipped }
        guard searchesLeft > 0 else { return .later }
        searchesLeft -= 1
        let result: FlightSearchResult
        do {
            result = try await store.service.searchFlights(number: candidate.number, date: candidate.day)
        } catch {
            return .later
        }
        switch Self.classify(result, for: candidate) {
        case .retry:
            searchesLeft = 0
            return .later
        case .skip:
            return .skipped
        case .needsYou(let reason):
            guard saved == nil else { return .skipped }
            ledger.needs(NeedsYouItem(key: candidate.key, number: candidate.number, day: candidate.day, reason: reason))
            return .needsYou
        case .pending(let draft):
            return saved == nil ? await place(draft, candidate) : .skipped
        case .found(let found):
            if store.flights.contains(where: { $0.flightNumber == found.flightNumber && $0.departureAt == found.departureAt }) {
                return .skipped
            }
            let draft = Self.draft(from: found)
            if let target = Self.replacementTarget(for: found, hash: candidate.bookingHash, in: store.flights, hashes: ledger.hashes) {
                return await replace(target, with: draft, candidate)
            }
            if isSaved(found) { return .skipped }
            return await place(draft, candidate)
        }
    }

    /// Added straight away within the free limit (the same check as Add flight's + button);
    /// past it, waiting in Ready to add. Never dropped.
    private func place(_ draft: FlightDraft, _ candidate: BookingCandidate) async -> Outcome {
        if Paywalls.shared.canAddFlight, let saved = await store.save(draft) {
            ledger.added(saved.id, key: candidate.key, hash: candidate.bookingHash, at: .now)
            events.append(.added(saved.id))
            return .added
        }
        ledger.ready.append(ReadyFlight(key: candidate.key, draft: draft))
        return .ready
    }

    /// A rebooking or new time for a saved flight: changed in place through the normal edit, so
    /// the forecast is worked out again.
    private func replace(_ target: Flight, with draft: FlightDraft, _ candidate: BookingCandidate) async -> Outcome {
        var draft = draft
        draft.notify = target.notify
        let was = FlightDraft(target)
        guard let saved = await store.save(draft, editing: target.id) else { return .later }
        ledger.changed(saved.id, was: was, hash: candidate.bookingHash, at: .now)
        events.append(.changed(saved.id))
        return .changed
    }

    // MARK: Matching (pure, tested)

    enum Classification: Equatable {
        case found(FoundFlight)
        /// Not published yet: saved pending, like Add flight's manual entry.
        case pending(FlightDraft)
        case needsYou(NeedsYouReason)
        /// Already flown, nothing to add.
        case skip
        /// Search wasn't available: tried on the next scan.
        case retry
    }

    nonisolated static func classify(_ result: FlightSearchResult, for candidate: BookingCandidate, now: Date = .now)
        -> Classification
    {
        switch result.state {
        case .found:
            let known = result.flights.filter(\.hasKnownAirports)
            if let found = pick(known, for: candidate) { return found.hasLanded(now: now) ? .skip : .found(found) }
            return known.count > 1 ? .needsYou(.severalLegs) : .needsYou(.notFound)
        case .notPublished:
            return pendingDraft(candidate, now: now).map { .pending($0) } ?? .needsYou(.noAirports)
        case .notFound: return .needsYou(.notFound)
        case .noSchedule: return .needsYou(.noSchedule)
        case .unavailable: return .retry
        }
    }

    /// The leg the booking names: by its departure airport (and arrival), else its arrival, else
    /// the only leg. Several legs and no hint: none, rather than a guess.
    nonisolated static func pick(_ flights: [FoundFlight], for candidate: BookingCandidate) -> FoundFlight? {
        let known = flights.filter(\.hasKnownAirports)
        if let origin = candidate.origin {
            let from = known.filter { $0.originAirport?.iata == origin }
            if let match = from.first(where: { $0.destinationAirport?.iata == candidate.destination }) ?? from.first {
                return match
            }
        }
        if let destination = candidate.destination, let match = known.first(where: { $0.destinationAirport?.iata == destination }) {
            return match
        }
        return known.count == 1 ? known[0] : nil
    }

    /// The saved flight a rebooking replaces: the same route within a day, with another number or
    /// time, and (when both are known) the same booking. Never a cancelled one.
    nonisolated static func replacementTarget(
        for found: FoundFlight, hash: String?, in flights: [Flight], hashes: [UUID: String]
    ) -> Flight? {
        flights.first { flight in
            !flight.isCancelled && flight.origin == found.origin && flight.destination == found.destination
                && abs(flight.departureAt.timeIntervalSince(found.departureAt)) < 24 * 3600
                && (flight.flightNumber != found.flightNumber || flight.departureAt != found.departureAt)
                && (hash == nil || hashes[flight.id] == nil || hashes[flight.id] == hash)
        }
    }

    /// As Add flight saves a flight it found (AddFlightView.save).
    nonisolated static func draft(from found: FoundFlight) -> FlightDraft {
        FlightDraft(
            origin: found.origin, destination: found.destination, departureAt: found.departureAt, notify: true,
            flightNumber: found.flightNumber, airlineName: found.airlineName, arrivalAt: found.arrivalAt)
    }

    /// A number whose schedule isn't out yet, with the booking's airports and local time (noon
    /// without one), saved pending like Add flight's manual entry.
    nonisolated static func pendingDraft(_ candidate: BookingCandidate, now: Date = .now) -> FlightDraft? {
        guard let from = candidate.origin.flatMap(AirportStore.shared.airport), from.iata == candidate.origin,
            let to = candidate.destination.flatMap(AirportStore.shared.airport), to.iata == candidate.destination
        else { return nil }
        let day = candidate.day.split(separator: "-").compactMap { Int($0) }
        let time = (candidate.time ?? "12:00").split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, time.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = from.timeZone
        guard
            let departure = calendar.date(
                from: DateComponents(year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1])),
            departure > now
        else { return nil }
        return FlightDraft(
            origin: from.icao, destination: to.icao, departureAt: departure, notify: true,
            flightNumber: candidate.number, schedulePending: true)
    }

    // MARK: Toasts and Undo

    /// One toast per scan: the one thing that happened, or a count, each with Undo.
    private func announce(_ events: [Event]) {
        guard !events.isEmpty, UIApplication.shared.applicationState == .active else { return }
        let text: String
        switch events.count == 1 ? events[0] : nil {
        case .added(let id)?:
            text = "\(name(id)) added from your email"
        case .cancelled(let id)?:
            text = "\(name(id)) marked cancelled from your email"
        case .changed(let id)?:
            text = "Changed to \(store.flight(id)?.flightNumber ?? name(id)) from your email"
        case nil:
            let adds = events.filter { if case .added = $0 { true } else { false } }.count
            text = adds == events.count ? "\(adds) flights added from your email" : "\(events.count) flights updated from your email"
        }
        Router.shared.showToast(text, systemImage: "envelope", undo: { [weak self] in
            guard let self else { return }
            Task { for event in events.reversed() { await self.undo(event) } }
        })
    }

    func undo(_ event: Event) async {
        switch event {
        case .added(let id): if let flight = store.flight(id) { await remove(flight) }
        case .cancelled(let id): undoCancel(id)
        case .changed(let id): await undoChange(id)
        }
    }

    /// Remove (summary, flight screen) and Undo of an add: deletes it, and its number and day are
    /// never added again.
    func remove(_ flight: Flight) async {
        await store.delete(flight.id)
        guard store.flight(flight.id) == nil else { return }
        ledger.removed(flight.id, key: Self.key(of: flight))
        applyCancellations()
    }

    func undoCancel(_ id: UUID) {
        guard let flight = store.flight(id) else { return }
        ledger.undoCancel(id, key: Self.key(of: flight) ?? "")
        applyCancellations()
    }

    func undoChange(_ id: UUID) async {
        guard let flight = store.flight(id), let was = ledger.changes[id]?.was else { return }
        var draft = was
        draft.id = nil
        guard await store.save(draft, editing: id) != nil else { return }
        _ = ledger.undoChange(id, newKey: Self.key(of: flight) ?? "")
    }

    /// Flight passes, the lists and reminders follow a cancellation or its Undo.
    private func applyCancellations() {
        EmailCancellations.shared.set(Set(ledger.cancelled.keys))
        store.noteLocalChange()
    }

    // MARK: What the screens show

    func isCancelledFromEmail(_ id: UUID) -> Bool { ledger.cancelled[id] != nil }

    /// "Updated from your email": the first day.
    func recentChange(_ id: UUID, now: Date = .now) -> Change? {
        ledger.changes[id].flatMap { ledger.isRecent($0.at, now: now) ? $0 : nil }
    }

    func importedAt(_ id: UUID) -> Date? {
        if let date = ledger.imported[id] { return date }
        return ledger.imported.first { InFlight.shared.currentID(of: $0.key) == id }?.value
    }

    /// Adds a ready flight. The caller has checked the free limit (and shown the paywall if needed).
    @discardableResult
    func add(_ item: ReadyFlight) async -> Bool {
        guard let saved = await store.save(item.draft) else { return false }
        ledger.added(saved.id, key: item.key, hash: nil, at: .now)
        return true
    }

    func discard(_ item: ReadyFlight) {
        ledger.ready.removeAll { $0.key == item.key }
        ledger.dismissed.insert(item.key)
    }

    func discard(_ item: NeedsYouItem) {
        ledger.needsYou.removeAll { $0.key == item.key }
        ledger.dismissed.insert(item.key)
    }

    // MARK: Helpers

    private func name(_ id: UUID) -> String {
        store.flight(id).map { $0.flightNumber ?? $0.routeText } ?? "Your flight"
    }

    /// The saved flight with this number on this local day.
    private func existing(number: String?, day: String) -> Flight? {
        guard let number else { return nil }
        return store.flights.first { $0.flightNumber == number && Self.day(of: $0) == day }
    }

    /// Add flight's own check: same number and airport, within a few hours.
    private func isSaved(_ found: FoundFlight) -> Bool {
        store.flights.contains {
            $0.flightNumber == found.flightNumber && $0.origin == found.origin
                && abs($0.departureAt.timeIntervalSince(found.departureAt)) < 6 * 3600
        }
    }

    nonisolated static func day(of flight: Flight) -> String {
        flight.departureAt.searchDay(in: flight.originAirport?.timeZone ?? .current)
    }

    nonisolated static func key(of flight: Flight) -> String? {
        flight.flightNumber.map { "\($0)|\(day(of: flight))" }
    }

    private static func day(fromKey key: String) -> String { String(key.split(separator: "|").last ?? "") }

    /// "07:15" at the departure airport, as the parser gives it.
    private static func localTime(of flight: Flight) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = flight.originAirport?.timeZone ?? .current
        let c = calendar.dateComponents([.hour, .minute], from: flight.departureAt)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Flights that are gone need nothing kept for them after a while; cancellations go with them.
    private func forgetGone() {
        let cutoff = Date.now.addingTimeInterval(-30 * 86400)
        let present = { (id: UUID) in self.store.flight(InFlight.shared.currentID(of: id)) != nil }
        ledger.imported = ledger.imported.filter { $0.value > cutoff || present($0.key) }
        ledger.hashes = ledger.hashes.filter { present($0.key) }
        ledger.changes = ledger.changes.filter { present($0.key) }
        let cancelled = ledger.cancelled.filter { present($0.key) }
        if cancelled != ledger.cancelled {
            ledger.cancelled = cancelled
            applyCancellations()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.ledgerKey)
    }
}

/// Flights an email said were cancelled, readable anywhere (`Flight.isCancelled`). An overlay on
/// the phone only: the flight's status belongs to the server, and email-derived state never
/// leaves the phone. EmailImport keeps it in step with its ledger.
final class EmailCancellations: Sendable {
    static let shared = EmailCancellations()
    private let ids = Mutex<Set<UUID>>([])

    func contains(_ id: UUID) -> Bool { ids.withLock { $0.contains(id) } }
    func set(_ new: Set<UUID>) { ids.withLock { $0 = new } }
}
