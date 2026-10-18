import SwiftUI

/// Add a flight: find it by number (free), or in three short steps (Route, When, Check), where
/// When lists that day's nonstops on the route. Editing starts on Check.
/// DESIGN_SPEC §3 item 8 and docs/design/flight-status-1.1-copy.md. States are never red:
/// problems use the moderate orange plus words. Never say where flight data comes from.
struct AddFlightView: View {
    var flight: Flight?

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
    @AppStorage("haptics.enabled") private var hapticsEnabled = true

    @State private var step: Step = .find
    @State private var origin: Airport?
    @State private var destination: Airport?
    @State private var departure = AddFlightView.defaultDeparture
    @State private var notify = true
    @State private var allowOutsideCoverage = false
    @State private var isSaving = false
    @State private var loaded = false
    // From search
    @State private var number = ""
    @State private var picked: FoundFlight?
    @State private var pendingNumber: String?
    /// Where the picked flight came from, for Back.
    @State private var pickedFrom: Step = .when
    /// On When: the time wheel instead of the list of flights.
    @State private var manualTime = false
    // Connecting flights
    @State private var connection: Connection?
    @State private var added: [Flight] = []
    @State private var savedHaptic = 0

    private var isEditing: Bool { flight != nil }
    private var sky: Sky { Sky(date: departure, timeZone: origin?.timeZone ?? .current) }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .find:
                    FindStep(
                        number: $number, departure: $departure, connection: connection,
                        timeZone: connection?.from.timeZone ?? origin?.timeZone ?? .current,
                        pick: use, chooseAirports: { step = .route }, enterManually: enterManually)
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
                        pick: use, lookUpNumber: { step = .find })
                    .transition(stepTransition)
                case .check:
                    CheckStep(
                        origin: origin, destination: destination, departure: departure, notify: $notify,
                        isEditing: isEditing, picked: picked
                    ) { step = .route }
                    .transition(stepTransition)
                }
            }
            .animation(Theme.motion(reduceMotion), value: step)
            .background { SkyBackground(sky: sky) }
            .onSky(sky)
            .safeAreaInset(edge: .top) { context }
            .safeAreaInset(edge: .bottom) { bottomButtons }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !added.isEmpty && step == .find {
                        Button("Done") { finish() }  // the first flight is already saved
                    } else if step == firstStep || (isEditing && step == .check) {
                        Button(added.isEmpty ? "Cancel" : "Done") { added.isEmpty ? dismiss() : finish() }
                    } else {
                        Button("Back", action: back)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: savedHaptic) { _, _ in hapticsEnabled }
            .onAppear(perform: loadExisting)
            // A new route lists its flights again (unless the number's schedule isn't out yet).
            .onChange(of: origin) { if step == .route { manualTime = pendingNumber != nil } }
            .onChange(of: destination) { if step == .route { manualTime = pendingNumber != nil } }
        }
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

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24)))
    }

    private func back() {
        switch step {
        case .check where picked != nil:
            // A searched flight came straight from Find or the route list.
            step = pickedFrom
            picked = nil
        case .route where pendingNumber != nil:
            step = .find
        default:
            step = Step(rawValue: step.rawValue - 1) ?? firstStep
        }
    }

    // MARK: Context above the steps

    @ViewBuilder
    private var context: some View {
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

    @ViewBuilder
    private var bottomButtons: some View {
        switch step {
        case .find:
            EmptyView()  // Find has its own buttons
        case .when where !manualTime:
            EmptyView()  // pick a flight from the list, or "Enter the time myself"
        case .check where !isEditing:
            VStack(spacing: 10) {
                primaryButton
                Button {
                    Task { await save(thenConnect: true) }
                } label: {
                    Text("Add a connecting flight").font(.bcHeadline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(Theme.accent).controlSize(.large)
                .disabled(!canAdvance || isSaving)
            }
            .padding()
        default:
            primaryButton.padding()
        }
    }

    private var primaryButton: some View {
        Button(action: advance) {
            Text(buttonTitle).font(.bcHeadline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
        .tint(Theme.accent)
        .controlSize(.large)
        .disabled(!canAdvance || isSaving)
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
        case .check:
            RouteStep.isValid(origin, destination, allowOutsideCoverage: true) && WhenStep.isValid(departure)
        }
    }

    private func advance() {
        switch step {
        case .find: break
        case .route: step = .when
        case .when: step = .check
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
        step = .check
    }

    /// The schedule for this number isn't out yet: enter airports and time, keep the number.
    private func enterManually(_ number: String) {
        pendingNumber = number
        picked = nil
        manualTime = true
        if let connection { origin = connection.from }
        step = .route
    }

    // MARK: Saving

    private func save(thenConnect: Bool) async {
        guard let origin, let destination else { return }
        isSaving = true
        defer { isSaving = false }
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
        guard let saved = await store.save(draft, editing: flight?.id) else { return }
        added.append(saved)
        if thenConnect {
            startConnection(after: saved)
            return
        }
        finish()
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
        allowOutsideCoverage = false
        // An hour after landing, on the arrival day.
        let next = arrival.addingTimeInterval(3600)
        departure = calendar.date(bySetting: .second, value: 0, of: next) ?? next
        step = .find
    }

    private func finish() {
        guard let last = added.last else { return dismiss() }
        dismiss()
        savedHaptic += 1
        Task {
            // The toggle asks for permission at the moment it's useful.
            if notify, push.status == .notDetermined {
                await push.requestPermission()
            }
        }
        router.showToast(toastText)
        // Leaving soon: go straight to the forecast.
        if !isEditing, added.count == 1, last.departureAt.timeIntervalSinceNow < 18 * 3600 {
            router.openFlight(last.id)
        }
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
        let unlock = saved.forecastUnlocksAt
        if unlock <= .now { return "\(saved.titleText) added. Your forecast will be ready in a few minutes." }
        return "\(saved.titleText) added. First forecast \(unlock.approximateDayAndTime())."
    }

    private static func unlockDay(_ flight: Flight) -> String {
        flight.forecastUnlocksAt <= .now ? "today" : flight.forecastUnlocksAt.formatted(.dateTime.weekday(.abbreviated))
    }

    // MARK: Setup

    private static var defaultDeparture: Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
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
    let connection: AddFlightView.Connection?
    let timeZone: TimeZone
    let pick: (FoundFlight) -> Void
    let chooseAirports: () -> Void
    let enterManually: (String) -> Void

    enum Search: Equatable {
        case idle, searching
        case found([FoundFlight])
        case notFound, notPublished, unavailable
    }

    @Environment(FlightStore.self) private var store
    @State private var search: Search = .idle
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
                    DayPicker(departure: $departure, calendar: calendar)
                    if let connection, connection.overnight {
                        Text("\(departure.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide))), because your overnight flight lands then.")
                            .font(.bcFootnote)
                            .foregroundStyle(.secondary)
                    }
                }
                result
                if search == .idle || search == .searching {
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
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if number.isEmpty { focused = true } }
        .onDisappear { focused = false }
        .onChange(of: number) { if search != .searching { search = .idle } }
        .onChange(of: departure) { if search != .searching { search = .idle } }
        .animation(.smooth, value: search)
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
                Text("Is this your flight?").font(.bcHeadline)
                Button {
                    pick(flight)
                } label: {
                    Text("Yes, use this flight").font(.bcHeadline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                Button("Not this one") { search = .idle; focused = true }
                    .font(.bcSubheadlineStrong).tint(Theme.accent).frame(maxWidth: .infinity)
            }
            .skyCard()
        case .found(let flights):
            VStack(alignment: .leading, spacing: 10) {
                Text("\(shown) flies \(flights.count) legs that day").font(.bcCardTitle)
                Text("Pick the one you're on.").font(.bcSubheadline).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(flights.enumerated()), id: \.element.id) { index, flight in
                        if index > 0 { Divider() }
                        Button { pick(flight) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(flight.originAirport?.iata ?? flight.origin) → \(flight.destinationAirport?.iata ?? flight.destination)")
                                        .font(.bcHeadline)
                                    Text(flight.timesText).font(.bcMeta).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
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
        }
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
        search = .searching
        Task {
            let result = (try? await store.service.searchFlights(number: normalized, date: departure.searchDay(in: timeZone)))
                ?? .unavailable
            // Only flights between airports we know; a connection prefers legs from where it lands.
            var flights = result.flights.filter { $0.originAirport != nil && $0.destinationAirport != nil }
            if let from = connection?.from, flights.contains(where: { $0.origin == from.icao }) {
                flights = flights.filter { $0.origin == from.icao }
            }
            switch result.state {
            case .found where !flights.isEmpty: search = .found(flights)
            case .found, .notFound, .noSchedule: search = .notFound
            case .notPublished: search = .notPublished
            case .unavailable: search = .unavailable
            }
        }
    }
}

/// "B6 23 · JFK → LAX · Departs 7:15 AM EDT · Arrives 10:41 AM PDT", laid out as a card body.
private struct FoundFlightSummary: View {
    let flight: FoundFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(flight.title).font(.bcMeta).foregroundStyle(.secondary)
            Text("\(flight.originAirport?.iata ?? flight.origin) → \(flight.destinationAirport?.iata ?? flight.destination)")
                .font(.bcTitle2)
            if let tz = flight.originAirport?.timeZone {
                Text("Departs \(flight.departureAt.localTimeWithZone(in: tz))").font(.bcSubheadline)
            }
            if let arrival = flight.arrivalAt, let tz = flight.destinationAirport?.timeZone {
                Text("Arrives \(arrival.localTimeWithZone(in: tz))").font(.bcSubheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension FoundFlight {
    /// "7:00 AM → 10:32 AM", each local to its airport.
    var timesText: String {
        let dep = departureAt.localTime(in: originAirport?.timeZone ?? .current)
        guard let arrivalAt else { return dep }
        return "\(dep) → \(arrivalAt.localTime(in: destinationAirport?.timeZone ?? .current))"
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
        return allowOutsideCoverage || Coverage.covers(from: origin, to: destination)
    }

    private var sameAirport: Bool { origin != nil && origin == destination }
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
                if outsideCoverage && !allowOutsideCoverage {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("This route is outside our coverage for now", systemImage: "globe")
                            .font(.bcCardTitle)
                        Text("You can still save it. We'll show it as not covered and let you know when we cover it.")
                            .font(.bcSubheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Save anyway") { allowOutsideCoverage = true }
                                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                            Button("Change route") { destination = nil }
                                .buttonStyle(.bordered).tint(Theme.accent)
                        }
                        .font(.bcSubheadlineStrong)
                    }
                    .skyCard()
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
        .background { SkyBackground(sky: sky) }
        .onSky(sky)
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

    /// Up to an hour late is allowed, for delays.
    static func isValid(_ departure: Date) -> Bool { departure > .now.addingTimeInterval(-3600) }

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
                DayPicker(departure: $departure, calendar: calendar)
                if manual {
                    TimeWheel(date: $departure, calendar: calendar)
                        .skyCard(padding: 8)
                    Text("Local time in \(origin?.city ?? "your departure city"), from your booking.")
                        .font(.bcFootnote)
                        .foregroundStyle(.secondary)
                    if !Self.isValid(departure) {
                        Text("Check the date, or pick a later time.")
                            .font(.bcSubheadline)
                            .foregroundStyle(Theme.color(.moderate))
                    } else {
                        Label(previewText, systemImage: "clock")
                            .font(.bcSubheadline)
                            .skyCard(cornerRadius: 16, padding: 12)
                    }
                } else if let origin, let destination {
                    RouteFlightList(
                        origin: origin, destination: destination, day: departure.searchDay(in: timeZone),
                        dayText: departure.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)),
                        after: after, pick: pick, enterTime: { manual = true }, lookUpNumber: lookUpNumber)
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
    @State private var result: FlightSearchResult?
    @State private var showEarlier = false

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
            switch result?.state {
            case nil:
                Label("Finding nonstop flights on \(dayText)…", systemImage: "airplane")
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
            case .found? where !flights.isEmpty:
                list
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
                    secondary: ("Try again", { Task { await load() } }))
            }
            if result == nil || (result?.state == .found && !flights.isEmpty) {
                Button("Enter the time myself", action: enterTime)  // the notices carry their own
                    .font(.bcSubheadlineStrong)
                    .tint(Theme.accent)
            }
        }
        .task(id: "\(origin.icao)-\(destination.icao)-\(day)") { await load() }
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

    private func load() async {
        result = nil
        showEarlier = false
        result = (try? await store.service.routeFlights(origin: origin.icao, destination: destination.icao, date: day)) ?? .unavailable
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
        return "\(airline) \(number), departs \(departs)\(arrives)"
    }
}

/// Day tiles for the next six days, then a calendar tile for later dates.
private struct DayPicker: View {
    @Binding var departure: Date
    let calendar: Calendar
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
                .background { SkyBackground(sky: Sky(date: departure, timeZone: timeZone)) }
                .onSky(Sky(date: departure, timeZone: timeZone))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { isPickingDate = false } }
                }
            }
            .font(.bcBody)
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
    }
}

/// A day tile: weekday eyebrow over the date in Familjen. Selected tiles fill with accent teal.
private struct DayTile: View {
    let top: String
    let bottom: Text
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            VStack(spacing: 4) {
                Text(top).eyebrow()
                bottom.font(.bcTitle2)
            }
            .frame(width: 50, height: 66)
            .foregroundStyle(selected ? Theme.onAccent : Color.primary)
            .background {
                if selected {
                    shape.fill(Theme.accent)
                } else {
                    shape.fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.6))
                        .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.7), lineWidth: 0.5))
                }
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
                        .foregroundStyle(value == (scrolled ?? selection) ? Color.primary : Color.secondary.opacity(0.6))
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
                .foregroundStyle(selected ? Theme.onAccent : isToday ? Theme.accent : Color.primary)
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
    let change: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Check your flight").font(.bcDisplay)
                if let origin, let destination {
                    routeCard(origin, destination)
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
            .padding()
        }
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
