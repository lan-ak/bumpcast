import SwiftUI

/// Add a flight: find it by number (free), or in three short steps (Route, When, Check), where
/// When lists that day's nonstops on the route. Editing starts on Check.
/// DESIGN_SPEC §3 item 8 and docs/design/flight-status-1.1-copy.md. States are never red:
/// problems use the moderate orange plus words. Never say where flight data comes from.
struct AddFlightView: View {
    var flight: Flight?
    /// Set when the onboarding flow opened this (OnboardingFlight): one flight, no connections,
    /// and the flow decides what happens next. Called with the saved flight, or nil on Cancel.
    var onboarding: ((Flight?) -> Void)?

    enum Step: Int, CaseIterable { case find, route, when, check }

    /// The flight just saved, when adding its connection.
    struct Connection: Equatable {
        let from: Airport
        let arrival: Date
        /// The previous flight left on an earlier local day (an overnight flight).
        let overnight: Bool
    }

    @Environment(FlightStore.self) private var store
    @Environment(PushNotifications.self) private var push
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step = .find
    /// Which way the last step change went: forward steps arrive from the trailing edge.
    @State private var forward = true
    @State private var origin: Airport?
    @State private var destination: Airport?
    @State private var departure = AddFlightView.defaultDeparture
    @State private var notify = true
    @State private var allowOutsideCoverage = false
    @State private var isSaving = false
    /// An edit is still waiting on a connection that's slow to answer: say so (Cancel works).
    @State private var slowSave = false
    /// The save didn't go through: said here, where they tapped it.
    @State private var saveFailed = false
    /// The sheet has gone (its presenter closed it, or went away) while a save was still running.
    @State private var closed = false
    /// Which button is saving: the spinner shows in the one they tapped.
    @State private var savingConnection = false
    @State private var loaded = false
    // From search
    @State private var number = ""
    /// Find's search, kept here so Back from Check still shows the flight it found.
    @State private var search: FindStep.Search = .idle
    @State private var picked: FoundFlight?
    @State private var pendingNumber: String?
    /// Where the picked flight came from, for Back.
    @State private var pickedFrom: Step = .when
    /// On When: the time wheel instead of the list of flights.
    @State private var manualTime = false
    // Connecting flights
    @State private var connection: Connection?
    @State private var added: [Flight] = []

    private var isEditing: Bool { flight != nil }
    private var sky: Sky { Sky(date: departure, timeZone: origin?.timeZone ?? .current) }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .find:
                    FindStep(
                        number: $number, departure: $departure, search: $search, connection: connection,
                        timeZone: connection?.from.timeZone ?? origin?.timeZone ?? .current,
                        savedFlight: savedFlight, pick: use, open: open,
                        chooseAirports: { go(to: .route) }, enterManually: enterManually)
                    .transition(stepTransition)
                case .route:
                    RouteStep(
                        origin: $origin, destination: $destination,
                        allowOutsideCoverage: $allowOutsideCoverage, recent: recentAirports, sky: sky)
                    .transition(stepTransition)
                case .when:
                    WhenStep(
                        origin: origin, destination: destination, departure: $departure,
                        manual: $manualTime, after: connection?.arrival,
                        pick: use, lookUpNumber: { go(to: .find) },
                        // Another day here is another day on Find too, so its old result goes.
                        dayPicked: { if search != .searching { search = .idle } })
                    .transition(stepTransition)
                case .check:
                    CheckStep(
                        origin: origin, destination: destination, departure: departure, notify: $notify,
                        isEditing: isEditing, picked: picked, problem: checkProblem,
                        alreadySaved: existingFlight != nil
                    ) { go(to: .route) }
                    .transition(stepTransition)
                }
            }
            .skyBackground(sky)
            .safeAreaBar(edge: .top) { context }
            // A bar, not an inset: the scroll edge effect sits behind the buttons, so cards
            // scrolling under them don't show through.
            .safeAreaBar(edge: .bottom) { bottomButtons }
            // The step, its buttons and the context above it change together, in one animation.
            .animation(Theme.motion(reduceMotion), value: step)
            // When: the list of flights and the time wheel (and its Next button) swap the same way.
            .animation(Theme.motion(reduceMotion), value: manualTime)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Group {
                        if !added.isEmpty && step == .find {
                            Button("Done") { finish() }  // the first flight is already saved
                        } else if step == firstStep || (isEditing && step == .check) {
                            Button(added.isEmpty ? "Cancel" : "Done") { added.isEmpty ? cancel() : finish() }
                        } else {
                            Button("Back", action: back)
                        }
                    }
                    // A new flight is kept on the phone within seconds, so the sheet waits and
                    // closes itself. An edit waits on the server for as long as it takes, so it
                    // can always be closed: the save carries on, and the list says if it fails.
                    .disabled(isSaving && !isEditing)
                }
            }
            .interactiveDismissDisabled(isSaving && !isEditing)
            // No haptic here: the Flights list plays the one "flight added" haptic (DESIGN_SPEC §3.8).
            // The Flights list's error alert can't show over this sheet (or the onboarding flow).
            .alert("That didn't go through", isPresented: .constant(saveFailed || (onboarding != nil && store.error != nil))) {
                Button("OK") {
                    saveFailed = false
                    store.error = nil
                }
            } message: {
                Text("Check your connection and try again.")
            }
            .onAppear(perform: loadExisting)
            // A new route lists its flights again (unless the number's schedule isn't out yet).
            .onChange(of: origin) { if step == .route { manualTime = pendingNumber != nil } }
            .onChange(of: destination) { if step == .route { manualTime = pendingNumber != nil } }
        }
        // On the stack itself, so pushing the airport search inside it doesn't count as closing.
        .onAppear { closed = false }
        .onDisappear { closed = true }
    }

    private var firstStep: Step { isEditing ? .route : .find }

    private var title: String {
        if isEditing { return "Edit flight" }
        switch step {
        case .find: return ""
        case .route, .when: return "\(step.rawValue) of 3"
        case .check: return picked == nil ? "3 of 3" : ""
        }
    }

    /// Fade through, sliding in from the side the step comes from: forward from the trailing edge,
    /// Back from the leading edge.
    private var stepTransition: AnyTransition {
        .fadeThrough(reduceMotion, offset: forward ? 24 : -24)
    }

    /// Moves to a step. Forward unless said otherwise or the step comes earlier.
    private func go(to next: Step, forward: Bool? = nil) {
        self.forward = forward ?? (next.rawValue > step.rawValue)
        step = next
    }

    private func back() {
        switch step {
        case .check where picked != nil:
            // A searched flight came straight from Find or the route list.
            go(to: pickedFrom, forward: false)
            picked = nil
        case .route where pendingNumber != nil:
            go(to: .find)
        default:
            go(to: Step(rawValue: step.rawValue - 1) ?? firstStep, forward: false)
        }
    }

    // MARK: Context above the steps

    private var context: some View {
        Group { contextCard }.transition(.fadeThrough(reduceMotion))
    }

    @ViewBuilder
    private var contextCard: some View {
        if let connection, step != .check {
            Label {
                Text("Connecting from \(connection.from.iata) · arrives \(connection.arrival.localTime(in: connection.from.timeZone, withDay: connection.overnight))")
            } icon: {
                Image(systemName: "arrow.triangle.turn.up.right.diamond").foregroundStyle(Theme.accent)
            }
            .font(.bcSubheadlineStrong)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 4)
        } else if let pendingNumber, step != .find {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pendingNumber) · \(departure.formatted(Self.pendingDay(origin?.timeZone)))").font(.bcMeta)
                Text("Times fill in when the airline publishes them").font(.bcFootnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .skyCard(cornerRadius: 16, padding: 12)
            .padding(.horizontal)
        }
    }

    private static func pendingDay(_ tz: TimeZone?) -> Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).year()
        style.timeZone = tz ?? .current
        return style
    }

    // MARK: Bottom buttons

    private var bottomButtons: some View {
        Group { bottomButtonsContent }.transition(.fadeThrough(reduceMotion))
    }

    @ViewBuilder
    private var bottomButtonsContent: some View {
        switch step {
        case .find:
            EmptyView()  // Find has its own buttons
        case .when where !manualTime:
            EmptyView()  // pick a flight from the list, or "Enter the time myself"
        case .check:
            if let existing = existingFlight {
                openButton(existing).padding()
            } else if !isEditing && onboarding == nil {
                VStack(spacing: 10) {
                    primaryButton
                    Button {
                        Task { await save(thenConnect: true) }
                    } label: {
                        savingLabel("Add a connecting flight", saving: isSaving && savingConnection, tint: Theme.accent)
                    }
                    .buttonStyle(.bordered).tint(Theme.accent).controlSize(.large)
                    .disabled(!canAdvance || isSaving)
                }
                .padding()
            } else {
                VStack(spacing: 10) {
                    if slowSave {
                        Text("The connection is slow to answer. You can close this: your changes keep saving, and we'll tell you if they don't go through.")
                            .font(.bcFootnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.fadeThrough(reduceMotion))
                    }
                    primaryButton
                }
                .animation(Theme.motion(reduceMotion), value: slowSave)
                .padding()
            }
        default:
            primaryButton.padding()
        }
    }

    private var primaryButton: some View {
        Button(action: advance) {
            savingLabel(buttonTitle, saving: isSaving && !savingConnection, tint: Theme.onAccent)
        }
        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
        .tint(Theme.accent)
        .controlSize(.large)
        .disabled(!canAdvance || isSaving)
    }

    /// A button title that turns into a spinner while the flight saves, so the button never just
    /// sits there greyed out on a slow connection.
    private func savingLabel(_ title: String, saving: Bool, tint: Color) -> some View {
        Text(title).font(.bcHeadline).frame(maxWidth: .infinity)
            .opacity(saving ? 0 : 1)
            .overlay {
                if saving {
                    ProgressView()
                        .tint(tint)
                        .accessibilityLabel(isEditing ? "Saving your changes" : "Adding your flight")
                }
            }
    }

    /// For a flight that's already saved: open it instead of adding it twice.
    private func openButton(_ saved: Flight) -> some View {
        Button { open(saved) } label: {
            Text("Open it").font(.bcHeadline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
        .tint(Theme.accent)
        .controlSize(.large)
    }

    private var buttonTitle: String {
        switch step {
        case .find, .route, .when: "Next"
        case .check: isEditing ? "Save changes" : "Add flight"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .find: false
        case .route: RouteStep.isValid(origin, destination, allowOutsideCoverage: allowOutsideCoverage)
        case .when: WhenStep.isValid(departure)
        case .check: RouteStep.isValid(origin, destination, allowOutsideCoverage: true) && isAddable
        }
    }

    /// The searched flight, while the route and time on Check are still its own (Change can move them).
    private var searched: FoundFlight? {
        guard let picked, picked.origin == origin?.icao, picked.destination == destination?.icao,
            picked.departureAt == departure
        else { return nil }
        return picked
    }

    /// Whether Check can save: a searched flight until it lands, even in the air; an edit that keeps
    /// its time until it lands; a time entered by hand up to an hour late (for delays).
    private var isAddable: Bool {
        if let searched { return !searched.hasLanded() }
        if let flight, departure == flight.departureAt {
            return flight.estimatedLanding(store.forecasts[flight.id]) > .now
        }
        return WhenStep.isValid(departure)
    }

    /// Why Check can't save, said plainly rather than leaving the button greyed out.
    private var checkProblem: String? {
        guard !isAddable else { return nil }
        if searched != nil { return "This flight has landed. Pick another day." }
        if let flight, departure == flight.departureAt { return "This flight has landed." }
        return WhenStep.pastText(online: Connectivity.shared.isOnline)
    }

    /// The flight on Check when it's already in their flights. Not the one this sheet is saving
    /// or just saved: it lands in the list while the sheet waits on the notification prompt.
    private var existingFlight: Flight? {
        guard !isSaving, let existing = searched.flatMap(savedFlight) else { return nil }
        return added.contains { $0.id == existing.id } ? nil : existing
    }

    /// The same flight already saved (same number and departure airport, leaving within a few hours
    /// of it), so it's opened rather than added twice. The flight being edited doesn't count.
    private func savedFlight(_ found: FoundFlight) -> Flight? {
        store.flights.first {
            $0.id != flight?.id && $0.flightNumber == found.flightNumber && $0.origin == found.origin
                && abs($0.departureAt.timeIntervalSince(found.departureAt)) < 6 * 3600
        }
    }

    private func advance() {
        switch step {
        case .find: break
        case .route: go(to: .when)
        case .when: go(to: .check)
        case .check: Task { await save(thenConnect: false) }
        }
    }

    // MARK: Search results

    /// A flight picked from search or the route list: fill everything in and go to Check.
    private func use(_ found: FoundFlight) {
        guard let from = found.originAirport, let to = found.destinationAirport else { return }
        pickedFrom = step
        picked = found
        pendingNumber = nil
        origin = from
        destination = to
        departure = found.departureAt
        allowOutsideCoverage = true
        go(to: .check)
    }

    /// The schedule for this number isn't out yet: enter airports and time, keep the number.
    private func enterManually(_ number: String) {
        pendingNumber = number
        picked = nil
        manualTime = true
        if let connection { origin = connection.from }
        go(to: .route)
    }

    // MARK: Saving

    private func save(thenConnect: Bool) async {
        guard let origin, let destination else { return }
        isSaving = true
        savingConnection = thenConnect
        defer { isSaving = false }
        // The toggle asks for notifications as they tap Add flight, while the flight saves, so the
        // system prompt never fades in over the closing sheet (DESIGN_SPEC §3.8). The onboarding
        // flow has already asked.
        let asksPermission = notify && onboarding == nil && push.status == .notDetermined
        if asksPermission { Task { await push.requestPermission() } }
        var draft = FlightDraft(origin: origin.icao, destination: destination.icao, departureAt: departure, notify: notify)
        if let picked, picked.origin == origin.icao, picked.destination == destination.icao {
            draft.flightNumber = picked.flightNumber
            draft.airlineName = picked.airlineName
            // The airline's arrival, moved with the departure if the user changed the time.
            draft.arrivalAt = picked.arrivalAt?.addingTimeInterval(departure.timeIntervalSince(picked.departureAt))
        } else if let pendingNumber {
            draft.flightNumber = pendingNumber
            draft.schedulePending = true
        } else if let flight, flight.origin == origin.icao, flight.destination == destination.icao {
            // Editing keeps the number unless the route changed.
            draft.flightNumber = flight.flightNumber
            draft.airlineName = flight.airlineName
            draft.arrivalAt = flight.arrivalAt.map { $0.addingTimeInterval(departure.timeIntervalSince(flight.departureAt)) }
            draft.schedulePending = flight.schedulePending
        }
        // A new flight (or an edit to one not on the server yet) is kept on the phone if the server
        // is slow; an edit to a saved flight waits for its answer. After the same few seconds, say
        // it's still going and that the sheet can be closed.
        let waitsOnServer = flight.map { !store.isPending($0.id) } ?? false
        let slow = Task {
            guard waitsOnServer else { return }
            try? await Task.sleep(for: FlightStore.addWait)
            if !Task.isCancelled { slowSave = true }
        }
        let saved = await store.save(draft, editing: flight?.id)
        slow.cancel()
        slowSave = false
        guard let saved else {
            // Still open: say so here (the Flights list's alert can't show over the sheet).
            if !closed { saveFailed = true }
            return
        }
        if asksPermission { await notificationAnswer() }
        added.append(saved)
        if thenConnect {
            startConnection(after: saved)
            return
        }
        finish()
    }

    /// Waits for their answer to the notification prompt, so the sheet only moves once it's gone.
    /// The status changes as soon as they answer, before the answer is saved to their profile (a
    /// network call the sheet doesn't wait for). Never more than a minute.
    private func notificationAnswer() async {
        let deadline = ContinuousClock.now + .seconds(60)
        while push.status == .notDetermined, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Reopen the sheet for the next leg, from where this one lands.
    private func startConnection(after saved: Flight) {
        guard let from = saved.destinationAirport else { return finish() }
        let arrival = saved.arrivalAt ?? saved.estimatedLanding(nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = from.timeZone
        let departedOn = saved.departureAt.localDay(in: saved.originAirport?.timeZone ?? from.timeZone)
        connection = Connection(from: from, arrival: arrival, overnight: arrival.localDay(in: from.timeZone) > departedOn)
        origin = from
        manualTime = false
        destination = nil
        picked = nil
        pendingNumber = nil
        number = ""
        search = .idle
        allowOutsideCoverage = false
        // An hour after landing, on the arrival day.
        let next = arrival.addingTimeInterval(3600)
        departure = calendar.date(bySetting: .second, value: 0, of: next) ?? next
        go(to: .find, forward: true)  // a new leg counts as forward
    }

    private func cancel() {
        if let onboarding { onboarding(nil) } else { dismiss() }
    }

    private func finish() {
        guard let last = added.last else { return cancel() }
        if let onboarding {
            // The flow already asked about notifications; it moves on to the forecast.
            onboarding(last)
            return
        }
        // Leaving soon (or already in the air): the forecast opens once the sheet has closed, and
        // that's confirmation enough. Offline saves and in-air adds still get their note.
        let opensForecast = !isEditing && added.count == 1 && last.departureAt.timeIntervalSinceNow < 18 * 3600
        let quiet = opensForecast && !store.isPending(last.id) && !addedInAir
        router.afterAdd = Router.AfterAdd(flightID: last.id, openForecast: opensForecast, toast: quiet ? nil : toastText)
        closeSheet()
    }

    /// The presenter's onDismiss runs router.finishAdding(). If the sheet is already gone (its
    /// presenter went away mid-save), that has run, so it runs now rather than on a later sheet.
    private func closeSheet() {
        if closed { router.finishAdding() } else { dismiss() }
    }

    /// Closes and opens a flight that's already saved (the onboarding flow moves on with it).
    private func open(_ saved: Flight) {
        if let onboarding { return onboarding(saved) }
        router.afterAdd = Router.AfterAdd(flightID: saved.id, openForecast: true, toast: added.isEmpty ? nil : toastText)
        closeSheet()
    }

    /// The one flight just added came from search and is in the air now.
    private var addedInAir: Bool {
        guard !isEditing, added.count == 1, let saved = added.first, let searched,
            searched.flightNumber == saved.flightNumber
        else { return false }
        return searched.isInAir()
    }

    private var toastText: String {
        if added.count > 1 {
            var days: [String] = []
            for day in added.map(Self.unlockDay) where !days.contains(day) { days.append(day) }
            if days.count == 1 { return "\(added.count) flights added. Forecasts for each arrive \(days[0])." }
            return "\(added.count) flights added. First forecasts arrive \(days.dropLast().joined(separator: ", ")) and \(days.last ?? "")."
        }
        guard let saved = added.first else { return "" }
        if store.isPending(saved.id) {
            return "\(saved.routeText) saved on your phone. We'll sync it when you're back online."
        }
        if isEditing { return "Changes saved." }
        if addedInAir { return "\(saved.titleText) added. You're in the air, so we'll match your real takeoff time." }
        let unlock = saved.forecastUnlocksAt
        if unlock <= .now { return "\(saved.titleText) added. Your forecast will be ready in a few minutes." }
        return "\(saved.titleText) added. First forecast \(unlock.approximateDayAndTime())."
    }

    private static func unlockDay(_ flight: Flight) -> String {
        flight.forecastUnlocksAt <= .now ? "today" : flight.forecastUnlocksAt.formatted(.dateTime.weekday(.abbreviated))
    }

    // MARK: Setup

    /// Today at the next whole hour: Find searches today (people add flights at the gate and on
    /// board; other days are one tap away), and the time wheel starts at a time that's still valid.
    private static var defaultDeparture: Date {
        let calendar = Calendar.current
        let thisHour = calendar.dateInterval(of: .hour, for: .now)?.start ?? .now
        let nextHour = thisHour.addingTimeInterval(3600)
        // Late in the evening the next hour is tomorrow; this hour is still today, and still valid.
        return calendar.isDate(nextHour, inSameDayAs: .now) ? nextHour : thisHour
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        // Anything another Add flight sheet left behind belongs to that sheet, not this one.
        if onboarding == nil { router.afterAdd = nil }
        guard let flight else { return }
        origin = flight.originAirport
        destination = flight.destinationAirport
        departure = flight.departureAt
        notify = flight.notify
        allowOutsideCoverage = true
        manualTime = true
        step = .check
    }

    /// Airports from saved flights, most recent first.
    private var recentAirports: [Airport] {
        var seen = Set<String>()
        return store.flights.reversed()
            .flatMap { [$0.originAirport, $0.destinationAirport] }
            .compactMap { $0 }
            .filter { seen.insert($0.icao).inserted }
            .prefix(6)
            .map { $0 }
    }
}

// MARK: - Find by flight number (free)

private struct FindStep: View {
    @Binding var number: String
    @Binding var departure: Date
    /// Lives in AddFlightView, so Back from Check comes back to the flight it found.
    @Binding var search: Search
    let connection: AddFlightView.Connection?
    let timeZone: TimeZone
    /// The same flight when it's already saved, so it's opened rather than added twice.
    let savedFlight: (FoundFlight) -> Flight?
    let pick: (FoundFlight) -> Void
    let open: (Flight) -> Void
    let chooseAirports: () -> Void
    let enterManually: (String) -> Void

    enum Search: Equatable {
        case idle, searching
        case found([FoundFlight])
        case notFound, notPublished, unavailable
        /// No connection: looking up a number needs one; choosing airports doesn't.
        case offline
    }

    @Environment(FlightStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var normalized: String? { FlightNumber.normalize(number) }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = .current
        c.timeZone = timeZone
        return c
    }
    private var dayText: String { departure.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)) }
    private var shown: String { normalized ?? number.uppercased() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(connection == nil ? "Find your flight" : "Find your next flight")
                    .font(.bcDisplay)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Flight number").eyebrow().foregroundStyle(.secondary)
                    TextField(connection == nil ? "e.g. B6 23" : "e.g. UA 573", text: $number)
                        .font(.bcTitle2)
                        .focused($focused)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(find)
                        .skyCard(cornerRadius: 16, padding: 14)
                    Text("Airline code and number, from your booking.").font(.bcFootnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Day").eyebrow().foregroundStyle(.secondary)
                    // Another day is another search.
                    DayPicker(departure: $departure, calendar: calendar) { if search != .searching { search = .idle } }
                    if let connection, connection.overnight {
                        Text("\(departure.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide))), because your overnight flight lands then.")
                            .font(.bcFootnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // The buttons stay where they were tapped; what the search finds fades in below
                // them, or in their place once they've faded out.
                if search == .idle || search == .searching {
                    VStack(spacing: 18) {
                        Button(action: find) {
                            Text("Find flight").font(.bcHeadline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                        .controlSize(.large)
                        .disabled(normalized == nil || search == .searching)
                        Button("Choose airports instead", action: chooseAirports)
                            .font(.bcSubheadlineStrong)
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                    }
                    .transition(.fadeThrough(reduceMotion))
                }
                Group { result }.transition(.fadeThrough(reduceMotion))
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if number.isEmpty { focused = true } }
        .onDisappear { focused = false }
        .onChange(of: number) { if search != .searching { search = .idle } }
        // Back online with the offline note showing: look it up now.
        .onChange(of: Connectivity.shared.isOnline) { _, online in if online && search == .offline { find() } }
        .animation(Theme.motion(reduceMotion), value: search)
    }

    @ViewBuilder
    private var result: some View {
        switch search {
        case .idle:
            EmptyView()
        case .searching:
            Label("Looking for \(shown) on \(dayText)…", systemImage: "magnifyingglass")
                .font(.bcSubheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Searching for flight \(shown)")
        case .found(let flights) where flights.count == 1:
            let flight = flights[0]
            VStack(alignment: .leading, spacing: 12) {
                Text("Found it").eyebrow().foregroundStyle(Theme.accent)
                FoundFlightSummary(flight: flight)
                if let saved = savedFlight(flight) {
                    Text("Already in your flights").font(.bcHeadline)
                    Button {
                        open(saved)
                    } label: {
                        Text("Open it").font(.bcHeadline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                } else if flight.hasLanded() {
                    // The day tiles are just above.
                    Text("This flight has landed. Pick another day.").font(.bcHeadline)
                } else {
                    Text("Is this your flight?").font(.bcHeadline)
                    Button {
                        pick(flight)
                    } label: {
                        Text("Yes, use this flight").font(.bcHeadline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                }
                Button("Not this one") { search = .idle; focused = true }
                    .font(.bcSubheadlineStrong).tint(Theme.accent).frame(maxWidth: .infinity)
            }
            .skyCard()
        case .found(let flights):
            // Last night's flight, still in the air, can come first (see find()).
            let days = Set(flights.map { $0.departureAt.localDay(in: $0.originAirport?.timeZone ?? .current) })
            VStack(alignment: .leading, spacing: 10) {
                Text(days.count > 1 ? "We found \(flights.count) \(shown) flights" : "\(shown) flies \(flights.count) legs that day")
                    .font(.bcCardTitle)
                Text("Pick the one you're on.").font(.bcSubheadline).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(flights.enumerated()), id: \.element.id) { index, flight in
                        if index > 0 { Divider() }
                        leg(flight)
                    }
                }
                Button("Not this one") { search = .idle }
                    .font(.bcSubheadlineStrong).tint(Theme.accent)
            }
            .skyCard()
        case .notFound:
            notice(
                title: "We couldn't find \(shown) on \(dayText)",
                body: "Check the number and the day, or add it by choosing your airports.",
                primary: ("Choose airports", chooseAirports), secondary: ("Try again", find))
        case .notPublished:
            notice(
                title: "\(shown)'s schedule for \(departure.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated).year())) isn't out yet",
                body: "Airlines publish their schedules in stages, and this one hasn't been released. Add your airports and departure time from your booking. We'll fill in the rest when it's published.",
                primary: ("Enter airports and time", { enterManually(shown) }),
                secondary: ("Change number or day", { search = .idle; focused = true }))
        case .unavailable:
            notice(
                title: "Flight search isn't available right now",
                body: "You can still add your flight by choosing your airports. We'll forecast it the same way.",
                primary: ("Choose airports", chooseAirports), secondary: ("Try again", find))
        case .offline:
            notice(
                title: "You're offline",
                // A time entered by hand can be up to an hour ago, so a flight that's been flying
                // longer waits for a connection to be looked up.
                body: "Flight lookup needs a connection. Not in the air yet? Choose your airports and departure time instead, and we'll forecast it once you're back online. Already flying? Look it up once you're connected.",
                primary: ("Choose airports", chooseAirports), secondary: ("Try again", find))
        }
    }

    /// One leg of a multi-leg number: its route, the day and times, then whether it's already
    /// saved or already flying. A saved leg opens rather than being added again.
    private func leg(_ flight: FoundFlight) -> some View {
        let saved = savedFlight(flight)
        let note = saved != nil ? "Already in your flights" : flight.liveText
        return Button {
            if let saved { open(saved) } else { pick(flight) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(flight.originAirport?.iata ?? flight.origin) → \(flight.destinationAirport?.iata ?? flight.destination)")
                        .font(.bcHeadline)
                    Text("\(flight.departureAt.relativeDay(in: flight.originAirport?.timeZone ?? .current)) · \(flight.timesText)")
                        .font(.bcMeta).foregroundStyle(.secondary)
                    if let note {
                        Text(note).font(.bcFootnoteStrong).foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func notice(title: String, body: String, primary: (String, () -> Void), secondary: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.bcCardTitle)
            Text(body).font(.bcSubheadline).foregroundStyle(.secondary)
            HStack {
                Button(primary.0, action: primary.1)
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                Button(secondary.0, action: secondary.1)
                    .buttonStyle(.bordered).tint(Theme.accent)
            }
            .font(.bcSubheadlineStrong)
        }
        .skyCard()
    }

    private func find() {
        guard let normalized else { return }
        focused = false
        // "Try again" on the offline note tries whenever there's a network at all, like
        // pull-to-refresh; otherwise a connection that just failed gets a little while first.
        let retrying = search == .offline && Connectivity.shared.hasPath
        guard Connectivity.shared.isOnline || retrying else {
            search = .offline
            return
        }
        search = .searching
        let day = departure.searchDay(in: timeZone)
        // Today's search only lists flights leaving today, so just after midnight the flight
        // they're on (it left last night) needs yesterday's too.
        let yesterday = connection == nil && day == Date.now.searchDay(in: timeZone)
            ? calendar.date(byAdding: .day, value: -1, to: .now)?.searchDay(in: timeZone) : nil
        Task {
            let result = await lookUp(normalized, on: day)
            // Only flights between airports we know; a connection prefers legs from where it lands.
            var flights = result.flights.filter(\.hasKnownAirports)
            if let from = connection?.from, flights.contains(where: { $0.origin == from.icao }) {
                flights = flights.filter { $0.origin == from.icao }
            }
            var state = result.state
            if let yesterday, [.found, .notFound, .noSchedule].contains(state),
                FoundFlight.mayStillFlyFromYesterday(flights)
            {
                // Still flying from last night: listed first, so tonight's flight with the same
                // number is never the only one offered.
                let earlier = await lookUp(normalized, on: yesterday).flights.filter(\.hasKnownAirports)
                let flying = FoundFlight.stillFlying(earlier).filter { leg in !flights.contains { $0.id == leg.id } }
                if !flying.isEmpty {
                    flights = flying + flights
                    state = .found
                }
            }
            // The number or day changed while it looked: this answer is for another flight.
            guard FlightNumber.normalize(number) == normalized, departure.searchDay(in: timeZone) == day else {
                search = .idle
                return
            }
            switch state {
            case .found where !flights.isEmpty: search = .found(flights)
            case .found, .notFound, .noSchedule: search = .notFound
            case .notPublished: search = .notPublished
            // A lookup that failed for want of a connection says so.
            case .unavailable: search = Connectivity.shared.isOnline ? .unavailable : .offline
            }
        }
    }

    /// One day's search for the number. A failure reads as unavailable.
    private func lookUp(_ number: String, on day: String) async -> FlightSearchResult {
        do {
            return try await store.service.searchFlights(number: number, date: day)
        } catch {
            Connectivity.shared.noteFailure(error)  // counts only connection failures
            return .unavailable
        }
    }
}

/// "B6 23 · JetBlue", the route, "Today · Departs 7:15 AM EDT", "Arrives 10:41 AM PDT", and how
/// it's doing once it has left, laid out as a card body.
private struct FoundFlightSummary: View {
    let flight: FoundFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(flight.title).font(.bcMeta).foregroundStyle(.secondary)
            Text("\(flight.originAirport?.iata ?? flight.origin) → \(flight.destinationAirport?.iata ?? flight.destination)")
                .font(.bcTitle2)
            if let tz = flight.originAirport?.timeZone {
                // The day, so tomorrow's flight is never mistaken for today's.
                Text("\(flight.departureAt.relativeDay(in: tz)) · Departs \(flight.departureAt.localTimeWithZone(in: tz))")
                    .font(.bcSubheadline)
            }
            if let arrival = flight.arrivalAt, let tz = flight.destinationAirport?.timeZone {
                Text("Arrives \(arrival.localTimeWithZone(in: tz, withDay: flight.arrivesAnotherDay))").font(.bcSubheadline)
            }
            if let live = flight.liveText {
                Text(live).font(.bcSubheadlineStrong).foregroundStyle(Theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension FoundFlight {
    /// "7:00 AM → 10:32 AM", each local to its airport, with the day when it lands on another.
    var timesText: String {
        let dep = departureAt.localTime(in: originAirport?.timeZone ?? .current)
        guard let arrivalAt else { return dep }
        return "\(dep) → \(arrivalAt.localTime(in: destinationAirport?.timeZone ?? .current, withDay: arrivesAnotherDay))"
    }

    /// Lands on a later local day than it leaves (an overnight flight).
    var arrivesAnotherDay: Bool {
        guard let arrivalAt, let from = originAirport?.timeZone, let to = destinationAirport?.timeZone else { return false }
        return arrivalAt.localDay(in: to) != departureAt.localDay(in: from)
    }

    /// "In the air · took off 2:53 PM", "Left the gate 2:33 PM" or "Landed 3:57 PM", from the
    /// airline's live status; nil until it leaves the gate.
    var liveText: String? {
        if let landed { return "Landed \(landed.localTime(in: destinationAirport?.timeZone ?? .current))" }
        // Down by the clock, without a landing time: never "In the air" beside "has landed".
        if hasLanded() { return departed == true ? "Landed" : nil }
        let tz = originAirport?.timeZone ?? .current
        if let takeoffAt { return "In the air · took off \(takeoffAt.localTime(in: tz))" }
        guard departed == true else { return nil }
        return departureActual.map { "Left the gate \($0.localTime(in: tz))" } ?? "Left the gate"
    }
}

/// Fade through: what leaves is nearly gone before what arrives fades in (sliding in by `offset`
/// points), so two screens never show on top of each other. The removal never depends on the
/// direction, because a removed view keeps the transition it had when it was last drawn.
private extension AnyTransition {
    @MainActor
    static func fadeThrough(_ reduceMotion: Bool, offset: CGFloat = 0) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: reduceMotion ? 0 : offset))
                .animation(Theme.motion(reduceMotion).delay(0.25)),
            removal: .opacity.animation(Theme.fade))
    }
}

// MARK: - Step 1: Route

private struct RouteStep: View {
    @Binding var origin: Airport?
    @Binding var destination: Airport?
    @Binding var allowOutsideCoverage: Bool
    let recent: [Airport]
    let sky: Sky

    static func isValid(_ origin: Airport?, _ destination: Airport?, allowOutsideCoverage: Bool) -> Bool {
        guard let origin, let destination, origin != destination else { return false }
        return allowOutsideCoverage || GlobalBeta.storedIsOn || Coverage.covers(from: origin, to: destination)
    }

    private var sameAirport: Bool { origin != nil && origin == destination }
    private var beta: GlobalBeta { GlobalBeta.shared }

    /// "The first part, over the US, is confirmed." only when the flight starts in the US.
    private var betaExplanation: String {
        guard let origin, Coverage.latitude.contains(origin.lat), Coverage.longitude.contains(origin.lon) else {
            return GlobalOutlookCopy.addExplanationAll
        }
        return GlobalOutlookCopy.addFirstPartConfirmed + GlobalOutlookCopy.addExplanation
    }
    private var outsideCoverage: Bool {
        guard let origin, let destination, origin != destination else { return false }
        return !Coverage.covers(from: origin, to: destination)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Where are you flying?").font(.bcDisplay)
                VStack(spacing: 0) {
                    AirportField(title: "From", airport: $origin, highlight: false, sky: sky)
                    HStack {
                        DottedRouteLine().frame(width: 24, height: 28)
                        Spacer()
                        Button {
                            swap(&origin, &destination)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.bcHeadline)
                                .padding(10)
                                .background(.regularMaterial, in: .circle)
                        }
                        .accessibilityLabel("Swap airports")
                        .disabled(origin == nil && destination == nil)
                    }
                    .padding(.horizontal, 14)
                    AirportField(title: "To", airport: $destination, highlight: sameAirport, sky: sky)
                }
                if sameAirport {
                    Text("That's where you're leaving from. Pick where you're flying to.")
                        .font(.bcSubheadline)
                        .foregroundStyle(Theme.color(.moderate))
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent").eyebrow().foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(recent.filter { $0 != origin && $0 != destination }) { airport in
                                    Button {
                                        if origin == nil { origin = airport } else { destination = airport }
                                    } label: {
                                        Text("\(Text(airport.iata).font(.bcMeta)) \(airport.city)")
                                            .font(.bcSubheadline)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(Theme.accent)
                                }
                            }
                        }
                    }
                }
                if outsideCoverage && !allowOutsideCoverage && !beta.isOn {
                    if beta.hasAnswered {
                        // Said no before: save it as "Not forecast yet", or turn the beta on.
                        VStack(alignment: .leading, spacing: 10) {
                            Label(GlobalOutlookCopy.notForecastYet, systemImage: "globe")
                                .font(.bcCardTitle)
                            Text("This route needs the global outlook (beta), which is off. You can still save it.")
                                .font(.bcSubheadline)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Save anyway") { allowOutsideCoverage = true }
                                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                                Button(GlobalOutlookCopy.turnOn) {
                                    beta.set(true)
                                    allowOutsideCoverage = true
                                }
                                    .buttonStyle(.bordered).tint(Theme.accent)
                            }
                            .font(.bcSubheadlineStrong)
                        }
                        .skyCard()
                    } else {
                        // Asked once; the answer becomes the Settings switch.
                        VStack(alignment: .leading, spacing: 10) {
                            Label(GlobalOutlookCopy.addQuestion, systemImage: "globe")
                                .font(.bcCardTitle)
                            Text(betaExplanation)
                                .font(.bcSubheadline)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button(GlobalOutlookCopy.turnOn) {
                                    beta.set(true)
                                    allowOutsideCoverage = true
                                }
                                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                                Button(GlobalOutlookCopy.notNow) {
                                    beta.set(false)
                                    allowOutsideCoverage = true
                                }
                                .buttonStyle(.bordered).tint(Theme.accent)
                            }
                            .font(.bcSubheadlineStrong)
                        }
                        .skyCard()
                    }
                }
                Label("We have the strongest coverage in the US, and we're expanding rapidly.", systemImage: "info.circle")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .onChange(of: destination) { allowOutsideCoverage = false }
        .onChange(of: origin) { allowOutsideCoverage = false }
    }
}

/// A From/To field that pushes the airport search.
private struct AirportField: View {
    let title: String
    @Binding var airport: Airport?
    let highlight: Bool
    let sky: Sky

    var body: some View {
        NavigationLink {
            AirportSearchView(title: title, selection: $airport, sky: sky)
        } label: {
            HStack(spacing: 12) {
                Text(title).eyebrow().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                if let airport {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(airport.iata).font(.bcTitle2)
                        Text(airport.city).font(.bcSubheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Choose airport").font(.bcBody).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .skyCard(cornerRadius: 18, padding: 14)
            .overlay {
                if highlight {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.color(.moderate), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DottedRouteLine: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 0))
            path.addLine(to: CGPoint(x: 12, y: 28))
        }
        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 6]))
        .accessibilityHidden(true)
    }
}

/// Searchable airports on the same sky as the flow: a brand search field, then one card of
/// rows (IATA in Plex Mono, city, then airport name, with the matched text in bold).
private struct AirportSearchView: View {
    let title: String
    @Binding var selection: Airport?
    let sky: Sky
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [Airport] { AirportStore.shared.search(query) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).eyebrow().foregroundStyle(.secondary)
                Text(title == "From" ? "Where are you leaving from?" : "Where are you flying to?")
                    .font(.bcDisplay)
                    .accessibilityAddTraits(.isHeader)
                searchField
                if results.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No airports match \u{201C}\(trimmed)\u{201D}").font(.bcCardTitle)
                        Text("Try the city, the airport name or its three-letter code.")
                            .font(.bcSubheadline)
                            .foregroundStyle(.secondary)
                    }
                    .skyCard()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(trimmed.isEmpty ? "Popular airports" : "Airports").eyebrow().foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, airport in
                                if index > 0 { Divider().padding(.leading, 70) }
                                row(airport)
                            }
                        }
                        .skyCard(padding: 0)
                    }
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .skyBackground(sky)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("City, airport or code", text: $query)
                .font(.bcBody)
                .focused($focused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { if let first = results.first, !trimmed.isEmpty { pick(first) } }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .skyCard(cornerRadius: 16, padding: 14)
    }

    private func row(_ airport: Airport) -> some View {
        Button {
            pick(airport)
        } label: {
            HStack(spacing: 14) {
                Text(highlighted(airport.iata))
                    .font(.bcMeta)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 32)
                    .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlighted(airport.city)).font(.bcBody)
                    Text(highlighted(airport.name)).font(.bcFootnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if airport == selection {
                    Image(systemName: "checkmark").font(.bcHeadline).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(airport == selection ? .isSelected : [])
    }

    private func pick(_ airport: Airport) {
        // The keyboard starts down before the pop, so the Route step's Next doesn't ride it.
        focused = false
        selection = airport
        dismiss()
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !trimmed.isEmpty, let range = result.range(of: trimmed, options: .caseInsensitive) else { return result }
        result[range].inlinePresentationIntent = .stronglyEmphasized
        return result
    }
}

// MARK: - Step 2: When

private struct WhenStep: View {
    let origin: Airport?
    let destination: Airport?
    @Binding var departure: Date
    /// The time wheel instead of the list of that day's flights.
    @Binding var manual: Bool
    /// When connecting: list flights after this arrival first.
    let after: Date?
    let pick: (FoundFlight) -> Void
    let lookUpNumber: () -> Void
    /// After they pick a day here.
    var dayPicked: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Up to an hour late is allowed, for delays.
    static func isValid(_ departure: Date) -> Bool { departure > .now.addingTimeInterval(-3600) }

    /// Why a time can't be used: it's more than an hour ago. That's usually the wrong day, but
    /// it can be the real time of a flight that's been in the air a while, which is found by its
    /// number instead (that needs a connection).
    static func pastText(online: Bool) -> String {
        online
            ? "That's more than an hour ago. Check the date, or if you're already in the air, look up your flight number instead."
            : "That's more than an hour ago. Check the date, or if you're already in the air, look up your flight number once you're connected."
    }

    private var timeZone: TimeZone { origin?.timeZone ?? .current }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = .current
        c.timeZone = timeZone
        return c
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let origin, let destination {
                    Text(manual
                        ? "\(origin.iata) → \(destination.iata)"
                        : "\(origin.iata) → \(destination.iata) · \(departure.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)))")
                        .eyebrow().foregroundStyle(.secondary)
                }
                Text(manual ? "When do you leave?" : "Which flight are you on?").font(.bcDisplay)
                DayPicker(departure: $departure, calendar: calendar, picked: dayPicked)
                // The list and the time wheel fade through each other (AddFlightView animates `manual`).
                if manual {
                    VStack(alignment: .leading, spacing: 18) {
                        TimeWheel(date: $departure, calendar: calendar)
                            .skyCard(padding: 8)
                        Text("Local time in \(origin?.city ?? "your departure city"), from your booking.")
                            .font(.bcFootnote)
                            .foregroundStyle(.secondary)
                        if !Self.isValid(departure) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Self.pastText(online: Connectivity.shared.isOnline))
                                    .font(.bcSubheadline)
                                    .foregroundStyle(Theme.color(.moderate))
                                Button("Look up flight number", action: lookUpNumber)
                                    .font(.bcSubheadlineStrong)
                                    .tint(Theme.accent)
                            }
                        } else {
                            Label(previewText, systemImage: "clock")
                                .font(.bcSubheadline)
                                .skyCard(cornerRadius: 16, padding: 12)
                        }
                    }
                    .transition(.fadeThrough(reduceMotion))
                } else if let origin, let destination {
                    RouteFlightList(
                        origin: origin, destination: destination, day: departure.searchDay(in: timeZone),
                        dayText: departure.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)),
                        after: after, pick: pick, enterTime: { manual = true }, lookUpNumber: lookUpNumber)
                    .transition(.fadeThrough(reduceMotion))
                }
            }
            .padding()
        }
    }

    private var previewText: String {
        let unlock = departure.addingTimeInterval(-Flight.forecastWindow)
        if unlock <= .now { return "Your forecast will be ready a few minutes after you add the flight." }
        return "Your first forecast arrives \(unlock.approximateDayAndTime())."
    }
}

/// That day's nonstop flights on the route, grouped by part of the day. Never says where the
/// list comes from.
private struct RouteFlightList: View {
    let origin: Airport
    let destination: Airport
    let day: String  // yyyy-MM-dd, local to the origin
    let dayText: String
    let after: Date?
    let pick: (FoundFlight) -> Void
    let enterTime: () -> Void
    let lookUpNumber: () -> Void

    @Environment(FlightStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var result: FlightSearchResult?
    @State private var showEarlier = false
    /// Another day's list is on its way: the one on screen stays, dimmed, until it arrives.
    @State private var isLoading = false
    /// No connection, so no list: say so and offer the time wheel.
    @State private var isOffline = false
    /// Bumped by Try again and by the connection coming back. Part of the load's id, so a newer
    /// day or retry cancels the older load instead of racing it.
    @State private var attempt = 0

    private enum Part: String, CaseIterable {
        case morning = "Morning", afternoon = "Afternoon", evening = "Evening"
    }

    private var flights: [FoundFlight] {
        (result?.flights ?? []).filter { $0.originAirport != nil && $0.destinationAirport != nil }
    }
    /// After a connection's arrival, earlier flights wait behind "Show earlier flights".
    private var earlier: [FoundFlight] {
        guard let after else { return [] }
        return flights.filter { $0.departureAt < after }
    }
    private var visible: [FoundFlight] { showEarlier ? flights : flights.filter { !earlier.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group { content }.transition(.fadeThrough(reduceMotion))
            if !isOffline && (result == nil || (result?.state == .found && !flights.isEmpty)) {
                Button("Enter the time myself", action: enterTime)  // the notices carry their own
                    .font(.bcSubheadlineStrong)
                    .tint(Theme.accent)
            }
        }
        .animation(Theme.motion(reduceMotion), value: result)
        .animation(Theme.motion(reduceMotion), value: isLoading)
        .animation(Theme.motion(reduceMotion), value: isOffline)
        .task(id: "\(origin.icao)-\(destination.icao)-\(day)-\(attempt)") { await load() }
        // Back online with the offline note showing: load the list now.
        .onChange(of: Connectivity.shared.isOnline) { _, online in
            if online && isOffline { attempt += 1 }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isOffline {
            notice(
                title: "You're offline",
                // A time entered by hand can be up to an hour ago (see WhenStep.isValid).
                body: "Enter your departure time instead. We'll save the flight and forecast it once you're back online. Already flying? Look up your flight number once you're connected.",
                secondary: ("Try again", { attempt += 1 }))
        } else {
            switch result?.state {
            case nil:
                Label("Finding nonstop flights on \(dayText)…", systemImage: "airplane")
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
            case .found? where !flights.isEmpty:
                list
                    // Another day's list is loading: this one is still the old day's, so it waits.
                    .opacity(isLoading ? 0.45 : 1)
                    .disabled(isLoading)
            case .found?, .notFound?:
                notice(
                    title: "No nonstop flights found that day",
                    body: "If you're connecting, add your first flight, then tap Add a connecting flight on the last step. Or enter your departure time and we'll forecast it the same way.")
            case .noSchedule?:
                notice(title: "We can't list flights from \(origin.city) yet", body: "Enter your departure time and we'll forecast it the same way.")
            case .notPublished?:
                notice(
                    title: "Flight lists for \(dayText) aren't out yet",
                    body: "They appear closer to the day. For now, enter your departure time, or look up your flight number.",
                    secondary: ("Look up flight number", lookUpNumber))
            case .unavailable?:
                notice(
                    title: "Can't load flights right now",
                    body: "Enter your departure time instead. We'll forecast it the same way.",
                    secondary: ("Try again", { attempt += 1 }))
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                Text("\(flights.count) nonstop flight\(flights.count == 1 ? "" : "s"). Times are local: \(origin.iata) \(zone(origin)), \(destination.iata) \(zone(destination)).")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
                if let after {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Showing flights after your \(after.localTime(in: origin.timeZone)) arrival.").font(.bcFootnote)
                        if !earlier.isEmpty && !showEarlier {
                            Button("Show \(earlier.count) earlier flight\(earlier.count == 1 ? "" : "s")") { showEarlier = true }
                                .font(.bcFootnoteStrong).tint(Theme.accent)
                        }
                    }
                }
                let groups = Part.allCases.map { part in (part, visible.filter { self.part(of: $0) == part }) }.filter { !$0.1.isEmpty }
                if visible.count > 6 && groups.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(groups, id: \.0) { part, rows in
                                Button("\(part.rawValue) \(rows.count)") { withAnimation(.smooth) { proxy.scrollTo(part, anchor: .top) } }
                                    .buttonStyle(.bordered).tint(Theme.accent).font(.bcSubheadlineStrong)
                            }
                        }
                    }
                }
                ForEach(groups, id: \.0) { part, rows in
                    VStack(alignment: .leading, spacing: 8) {
                        if groups.count > 1 { Text(part.rawValue).eyebrow().foregroundStyle(.secondary) }
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, flight in
                                if index > 0 { Divider().padding(.leading, 16) }
                                RouteFlightRow(flight: flight) { pick(flight) }
                            }
                        }
                        .skyCard(padding: 0)
                    }
                    .id(part)
                }
            }
        }
    }

    private func notice(title: String, body: String, secondary: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.bcCardTitle)
            Text(body).font(.bcSubheadline).foregroundStyle(.secondary)
            HStack {
                Button("Enter the time myself", action: enterTime)
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                if let secondary {
                    Button(secondary.0, action: secondary.1).buttonStyle(.bordered).tint(Theme.accent)
                }
            }
            .font(.bcSubheadlineStrong)
        }
        .skyCard()
    }

    private func part(of flight: FoundFlight) -> Part {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = origin.timeZone
        let hour = calendar.component(.hour, from: flight.departureAt)
        return hour < 12 ? .morning : hour < 17 ? .afternoon : .evening
    }

    private func zone(_ airport: Airport) -> String {
        airport.timeZone.abbreviation(for: flights.first?.departureAt ?? .now) ?? ""
    }

    /// Loads the day's list. The list on screen stays until the new one arrives, and a load that
    /// was cancelled for a newer day never lands.
    private func load() async {
        // With the offline note up, "Try again" tries whenever there's a network at all.
        guard Connectivity.shared.isOnline || (isOffline && Connectivity.shared.hasPath) else {
            isLoading = false
            isOffline = true
            return
        }
        isLoading = true
        let fetched: FlightSearchResult
        do {
            fetched = try await store.service.routeFlights(origin: origin.icao, destination: destination.icao, date: day)
        } catch {
            Connectivity.shared.noteFailure(error)  // counts only connection failures
            fetched = .unavailable
        }
        guard !Task.isCancelled else { return }  // a newer day's list is on its way
        isLoading = false
        // A load that failed for want of a connection says so.
        isOffline = fetched.state == .unavailable && !Connectivity.shared.isOnline
        guard !isOffline else { return }
        showEarlier = false
        result = fetched
    }
}

/// "B6 23 · JetBlue" over "7:00 AM → 10:32 AM". At large text sizes the chevron goes.
private struct RouteFlightRow: View {
    let flight: FoundFlight
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(flight.title).font(.bcHeadline)
                    Text(flight.timesText).font(.bcMeta).foregroundStyle(.secondary)
                    if let live = flight.liveText {
                        Text(live).font(.bcFootnoteStrong).foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let airline = flight.airlineName ?? flight.flightNumber
        let number = flight.flightNumber.split(separator: " ").last.map(String.init) ?? ""
        let departs = flight.departureAt.localTime(in: flight.originAirport?.timeZone ?? .current)
        let arrives = flight.arrivalAt.map { ", arrives \($0.localTime(in: flight.destinationAirport?.timeZone ?? .current))" } ?? ""
        let live = flight.liveText.map { ". \($0)" } ?? ""
        return "\(airline) \(number), departs \(departs)\(arrives)\(live)"
    }
}

/// Day tiles for the next six days, then a calendar tile for later dates.
private struct DayPicker: View {
    @Binding var departure: Date
    let calendar: Calendar
    /// After they pick a day (only then, never when the departure changes some other way).
    var picked: () -> Void = {}
    @State private var isPickingDate = false

    /// Days shown as tiles; later dates come from the calendar tile.
    private static let tileDays = 6

    private var timeZone: TimeZone { calendar.timeZone }

    private var isLaterDate: Bool {
        let today = calendar.startOfDay(for: .now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: departure)).day ?? 0
        return days >= Self.tileDays || days < 0
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<Self.tileDays, id: \.self) { offset in
                    let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!
                    DayTile(
                        top: offset == 0 ? "Today" : weekday(day),
                        bottom: Text(dayNumber(day)),
                        selected: calendar.isDate(day, inSameDayAs: departure)
                    ) { setDay(day) }
                    .accessibilityLabel(offset == 0 ? "Today" : day.formatted(accessibleDay))
                }
                DayTile(
                    top: isLaterDate ? month(departure) : "More",
                    bottom: isLaterDate ? Text(dayNumber(departure)) : Text(Image(systemName: "calendar")),
                    selected: isLaterDate
                ) { isPickingDate = true }
                .accessibilityLabel(isLaterDate ? departure.formatted(accessibleDay) : "Pick another date")
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .sheet(isPresented: $isPickingDate) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Pick a date").font(.bcTitle)
                    MonthCalendar(selection: departure, calendar: calendar) { day in
                        setDay(day)
                        isPickingDate = false
                    }
                    .skyCard()
                    Spacer(minLength: 0)
                }
                .padding()
                .skyBackground(Sky(date: departure, timeZone: timeZone))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { isPickingDate = false } }
                }
            }
            .presentationDetents([.fraction(0.72), .large])
        }
    }

    private var accessibleDay: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide).month(.wide).day()
        style.timeZone = timeZone
        return style
    }

    private func weekday(_ day: Date) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated)
        style.timeZone = timeZone
        return day.formatted(style)
    }

    private func month(_ day: Date) -> String {
        var style = Date.FormatStyle().month(.abbreviated)
        style.timeZone = timeZone
        return day.formatted(style)
    }

    private func dayNumber(_ day: Date) -> String { "\(calendar.component(.day, from: day))" }

    /// Keeps the chosen time, moves it to `day` (in the departure airport's time zone).
    private func setDay(_ day: Date) {
        let time = calendar.dateComponents([.hour, .minute], from: departure)
        departure = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
        picked()
    }
}

/// A day tile: weekday eyebrow over the date in Familjen. Selected tiles fill with accent teal.
private struct DayTile: View {
    let top: String
    let bottom: Text
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            VStack(spacing: 4) {
                Text(top).eyebrow()
                bottom.font(.bcTitle2)
            }
            .frame(width: 50, height: 66)
            .foregroundStyle(selected ? Theme.onAccent : Theme.ink)
            .background {
                if selected { shape.fill(Theme.accent) } else { Color.clear.skySurface(shape) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The departure time as brand wheels (hour, minute, and AM/PM where the locale uses it),
/// in the departure airport's time zone. Replaces the SF Pro system wheel.
private struct TimeWheel: View {
    @Binding var date: Date
    let calendar: Calendar

    private static let uses12Hour: Bool =
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")

    private var hour24: Int { calendar.component(.hour, from: date) }
    private var minute: Int { calendar.component(.minute, from: date) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
                .frame(height: WheelColumn.rowHeight)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                if Self.uses12Hour {
                    WheelColumn(values: Array(1...12), selection: hour12Binding, label: { "\($0)" }, name: "Hour")
                } else {
                    WheelColumn(values: Array(0...23), selection: hour24Binding, label: { String(format: "%02d", $0) }, name: "Hour")
                }
                Text(":").font(.bcTitle).accessibilityHidden(true)
                WheelColumn(values: Array(0...59), selection: minuteBinding, label: { String(format: "%02d", $0) }, name: "Minute")
                if Self.uses12Hour {
                    WheelColumn(
                        values: [0, 1], selection: pmBinding,
                        label: { $0 == 0 ? calendar.amSymbol : calendar.pmSymbol }, name: "AM or PM")
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func set(hour: Int, minute: Int) {
        date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    private var hour24Binding: Binding<Int> {
        Binding { hour24 } set: { set(hour: $0, minute: minute) }
    }

    private var hour12Binding: Binding<Int> {
        Binding { hour24 % 12 == 0 ? 12 : hour24 % 12 } set: { set(hour: ($0 % 12) + (hour24 >= 12 ? 12 : 0), minute: minute) }
    }

    private var pmBinding: Binding<Int> {
        Binding { hour24 >= 12 ? 1 : 0 } set: { set(hour: hour24 % 12 + ($0 == 1 ? 12 : 0), minute: minute) }
    }

    private var minuteBinding: Binding<Int> {
        Binding { minute } set: { set(hour: hour24, minute: $0) }
    }
}

/// One snapping wheel column in Familjen Grotesk. VoiceOver adjusts it with swipe up/down.
private struct WheelColumn: View {
    static let rowHeight: CGFloat = 44
    let values: [Int]
    @Binding var selection: Int
    let label: (Int) -> String
    let name: String
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @State private var scrolled: Int?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(values, id: \.self) { value in
                    Text(label(value))
                        .font(.bcTitle)
                        .monospacedDigit()
                        .foregroundStyle(value == (scrolled ?? selection) ? Theme.ink : Theme.tertiaryInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.rowHeight)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.smooth) { scrolled = value } }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.vertical, Self.rowHeight * 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolled, anchor: .center)
        .frame(height: Self.rowHeight * 5)
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.3),
            .init(color: .black, location: 0.7), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        .sensoryFeedback(.selection, trigger: scrolled) { _, _ in hapticsEnabled }
        .onAppear { scrolled = selection }
        .onChange(of: scrolled) { if let scrolled, scrolled != selection { selection = scrolled } }
        .onChange(of: selection) { if scrolled != selection { scrolled = selection } }
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(label(selection))
        .accessibilityAdjustableAction { direction in
            guard let index = values.firstIndex(of: selection) else { return }
            switch direction {
            case .increment: if index + 1 < values.count { selection = values[index + 1] }
            case .decrement: if index > 0 { selection = values[index - 1] }
            @unknown default: break
            }
        }
    }
}

/// A month grid in brand type, for dates beyond the day tiles. Past days are disabled.
private struct MonthCalendar: View {
    let selection: Date
    let calendar: Calendar
    let pick: (Date) -> Void
    @State private var month: Date

    /// How far ahead flights can be added.
    private static let monthsAhead = 11

    init(selection: Date, calendar: Calendar, pick: @escaping (Date) -> Void) {
        self.selection = selection
        self.calendar = calendar
        self.pick = pick
        let base = max(selection, .now)
        _month = State(initialValue: calendar.dateInterval(of: .month, for: base)?.start ?? base)
    }

    private var firstMonth: Date { calendar.dateInterval(of: .month, for: .now)?.start ?? .now }
    private var lastMonth: Date { calendar.date(byAdding: .month, value: Self.monthsAhead, to: firstMonth)! }
    private var today: Date { calendar.startOfDay(for: .now) }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Leading blanks, then each day of the month.
    private var cells: [Date?] {
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead)
            + (0..<days).map { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(monthTitle).font(.bcTitle2)
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left").font(.bcHeadline).padding(10) }
                    .disabled(month <= firstMonth)
                    .accessibilityLabel("Previous month")
                Button { step(1) } label: { Image(systemName: "chevron.right").font(.bcHeadline).padding(10) }
                    .disabled(month >= lastMonth)
                    .accessibilityLabel("Next month")
            }
            .tint(Theme.accent)
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).eyebrow().foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayButton(day) } else { Color.clear.frame(height: 40) }
                }
            }
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let past = day < today
        return Button { pick(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(selected || isToday ? .bcHeadline : .bcBody)
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.onAccent : isToday ? Theme.accent : Theme.ink)
                .frame(width: 40, height: 40)
                .background { if selected { Circle().fill(Theme.accent) } }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(past)
        .opacity(past ? 0.3 : 1)
        .accessibilityLabel(day.formatted(accessibleStyle))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var monthTitle: String {
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = calendar.timeZone
        return month.formatted(style)
    }

    private var accessibleStyle: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide).month(.wide).day()
        style.timeZone = calendar.timeZone
        return style
    }

    private func step(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            withAnimation(.smooth) { month = min(max(next, firstMonth), lastMonth) }
        }
    }
}

// MARK: - Step 3: Check

private struct CheckStep: View {
    let origin: Airport?
    let destination: Airport?
    let departure: Date
    @Binding var notify: Bool
    let isEditing: Bool
    /// The flight from search, when it came from there.
    let picked: FoundFlight?
    /// Why it can't be saved (it has landed, or the time has passed), instead of a silent button.
    let problem: String?
    /// It's already in their flights: the button opens it instead.
    let alreadySaved: Bool
    let change: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Check your flight").font(.bcDisplay)
                if let origin, let destination {
                    routeCard(origin, destination)
                }
                if alreadySaved {
                    Label("Already in your flights", systemImage: "checkmark.circle.fill")
                        .font(.bcHeadline)
                        .foregroundStyle(Theme.accent)
                } else {
                    details
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var details: some View {
        if let problem {
            Text(problem)
                .font(.bcSubheadline)
                .foregroundStyle(Theme.color(.moderate))
        }
        if departure.timeIntervalSinceNow > 18 * 3600 {
            VStack(alignment: .leading, spacing: 12) {
                Text("What happens next").font(.bcSection)
                ForEach(timeline, id: \.title) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(item.isNow ? Theme.accent : Theme.secondaryInk.opacity(0.4))
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.when).eyebrow().foregroundStyle(.secondary)
                            Text(item.title).font(.bcHeadline)
                            Text(item.detail).font(.bcSubheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .skyCard()
        }
        Toggle(isOn: $notify) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tell me when it's ready or changes").font(.bcHeadline)
                // Backed by worker quiet hours (22:00–07:00 local; early flights still get updates).
                Text("Only for changes you'd notice. Quiet overnight unless you fly early.")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Theme.accent)
        .skyCard()
    }

    private func routeCard(_ origin: Airport, _ destination: Airport) -> some View {
        let flight = Flight(id: UUID(), origin: origin.icao, destination: destination.icao, departureAt: departure)
        return VStack(alignment: .leading, spacing: 8) {
            if let picked {
                Text(picked.title).eyebrow().foregroundStyle(.secondary)
            }
            HStack {
                Text(flight.routeText).font(.bcTitle2)
                Spacer()
                Button("Change", action: change).font(.bcSubheadlineStrong).tint(Theme.accent)
            }
            Text("\(origin.city) to \(destination.city)").font(.bcSubheadline)
            Text(flight.departureText).font(.bcMeta).foregroundStyle(.secondary)
            if let arrival = picked?.arrivalAt {
                // Moves with the departure if the time was changed here.
                let moved = arrival.addingTimeInterval(departure.timeIntervalSince(picked?.departureAt ?? departure))
                Text("Arrives \(moved.localTimeWithZone(in: destination.timeZone))").font(.bcMeta).foregroundStyle(.secondary)
            } else {
                Text("About \(Int(flight.estimatedAirMinutes).durationText) in the air").font(.bcFootnote).foregroundStyle(.secondary)
            }
            if let picked, picked.departureAt == departure, let live = picked.liveText {
                Text(live).font(.bcFootnoteStrong).foregroundStyle(Theme.accent)
            }
        }
        .skyCard()
    }

    private struct Item {
        let when: String
        let title: String
        let detail: String
        var isNow = false
    }

    private var timeline: [Item] {
        let advance = departure.addingTimeInterval(-Flight.forecastWindow)
        let confirmed = departure.addingTimeInterval(-Forecast.noaaHorizon + Forecast.noaaPublishLag)
        var items = [
            Item(
                when: "Now", title: isEditing ? "Saved" : "Saved",
                detail: advance > .now ? "Too early to tell yet." : "Your forecast will be ready in a few minutes.",
                isNow: true)
        ]
        if advance > .now {
            items.append(Item(when: advance.approximateDayAndTime(), title: "Advance forecast", detail: "An early look. It can still change."))
        }
        items.append(Item(when: confirmed.approximateDayAndTime(), title: "Confirmed forecast", detail: "Updated every hour until you fly."))
        items.append(Item(when: "You fly", title: "Ready for the flight", detail: "Saved on your phone for the flight, even offline."))
        return items
    }
}
