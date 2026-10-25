import SwiftUI

struct FlightsListView: View {
    @Environment(FlightStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Paywalls.self) private var paywalls
    @Environment(InFlight.self) private var inFlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @Namespace private var zoom
    @State private var isAdding = false
    @State private var isShowingSettings = false
    /// Flights on screen when Add flight opened. A new one settles in once the sheet has closed,
    /// where it can be seen, instead of behind the sheet.
    @State private var heldIDs: Set<UUID>?
    /// Upcoming or Flown. Only offered once a flight has landed, and never remembered across
    /// launches, so the next flight is never left behind Flown (see `backgroundedAt`).
    @State private var segment: Segment = .upcoming
    /// When the app went to the background: back after 30 minutes or more, it opens on Upcoming.
    @State private var backgroundedAt: Date?
    /// Taps on the segmented control, for its haptic. Switches made for a link or a new flight play none.
    @State private var segmentTaps = 0
    /// The flight whose "Rate it" was tapped.
    @State private var rating: Flight?

    enum Segment { case upcoming, flown }

    private var connectivity: Connectivity { .shared }

    var body: some View {
        @Bindable var store = store
        @Bindable var router = router
        NavigationStack(path: $router.flightPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    notices
                    if !flown.isEmpty {
                        segmentPicker
                    }
                    // The two lists cross-fade in place, never slide.
                    ZStack(alignment: .top) {
                        if shown == .flown {
                            flownList.transition(.opacity)
                        } else {
                            upcomingList.transition(.opacity)
                        }
                    }
                }
                .padding()
                // A new flight settles in with the house spring, as do a switch of list and a rated
                // Just landed card leaving.
                .animation(Theme.motion(reduceMotion), value: shownIDs)
                .animation(Theme.motion(reduceMotion), value: shown)
                .animation(Theme.motion(reduceMotion), value: justLanded.map(\.id))
            }
            .skyBackground(sky)
            .navigationTitle("Flights")
            .navigationDestination(for: UUID.self) { id in
                FlightDetailView(flightID: id)
                    .navigationTransition(.zoom(sourceID: id, in: zoom))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add flight", systemImage: "plus", action: addFlight)
                }
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $isAdding, onDismiss: addingClosed) { AddFlightView() }
            .onChange(of: isAdding) { _, open in
                if open { heldIDs = Set(store.flights.map(\.id)) }
            }
            .onChange(of: router.showAddFlight, initial: true) { _, show in
                guard show else { return }
                router.showAddFlight = false
                isAdding = true
            }
            .sheet(isPresented: $isShowingSettings) { SettingsView() }
            .sheet(item: $rating) { RateFlightSheet(flight: $0).presentationDetents([.medium, .large]) }
            // The one "flight added" haptic, as the new card settles in.
            .sensoryFeedback(trigger: shownIDs.count) { old, new in
                new > old && hapticsEnabled ? .impact(flexibility: .soft, intensity: 0.5) : nil
            }
            .sensoryFeedback(trigger: segmentTaps) { _, _ in hapticsEnabled ? .selection : nil }
            // A notification or link opens its flight from the list that holds it, so Back returns there.
            .onChange(of: router.flightPath.first, initial: true) { _, id in
                if let id { showSegment(of: id) }
            }
            // The last flown flight deleted: Upcoming again when one next lands.
            .onChange(of: flown.isEmpty) { _, empty in
                if empty { segment = .upcoming }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    backgroundedAt = .now
                } else if phase == .active, let away = backgroundedAt {
                    backgroundedAt = nil
                    if Date.now.timeIntervalSince(away) >= 30 * 60 { showSegment(.upcoming) }
                }
            }
            // Calm, actionable wording instead of the raw system error. With a flight open, its
            // screen shows it instead (one alert at a time).
            .alert("That didn't go through", isPresented: .constant(store.error != nil && router.flightPath.isEmpty)) {
                Button("OK") { store.error = nil }
            } message: {
                Text("Check your connection and try again. Your saved forecasts still work offline.")
            }
        }
    }

    private func isShown(_ flight: Flight) -> Bool { heldIDs?.contains(flight.id) ?? true }
    private var shownIDs: [UUID] { store.flights.filter(isShown).map(\.id) }
    /// In the shared order (`FlightStore.upcomingFlights`): the first is the next flight.
    private var upcoming: [Flight] { store.upcomingFlights.filter(isShown) }
    /// Cancelled before their scheduled departure; after it they're on Flown.
    private var cancelled: [Flight] { store.cancelledUpcoming.filter(isShown) }
    /// Newest first.
    private var flown: [Flight] { store.flights.filter { isShown($0) && isFlown($0) }.reversed() }
    private func isFlown(_ flight: Flight) -> Bool {
        if flight.isCancelled { return flight.departureAt <= .now }
        return inFlight.landing(of: flight, forecast: store.forecasts[flight.id]) <= .now
    }

    /// The list on screen: Flown only while there's a flown flight to show.
    private var shown: Segment { flown.isEmpty ? .upcoming : segment }

    /// Landed in the last day and not rated yet: a row under Coming up, or cards at the top when
    /// nothing is coming up (see `JustLandedCard`).
    private var justLanded: [Flight] {
        let dayAgo = Date.now.addingTimeInterval(-24 * 3600)
        return flown.filter { flight in
            inFlight.landing(of: flight, forecast: store.forecasts[flight.id]) > dayAgo && canRate(flight)
                && !UserDefaults.standard.bool(forKey: LandingCheckCard.dismissKey(flight.id))
        }
    }

    /// The rating ask: a flight that flew where it was going (not cancelled or diverted), with a
    /// forecast to compare with, and no rating yet.
    private func canRate(_ flight: Flight) -> Bool {
        guard store.reports[flight.id] == nil, !flight.isDisrupted else { return false }
        if case .ready = ForecastState(flight: flight, forecast: store.forecasts[flight.id], betaOn: GlobalBeta.shared.isOn) {
            return true
        }
        return false
    }

    /// Switches, without animating, to the list that holds the flight.
    private func showSegment(of id: UUID) {
        guard let flight = store.flight(id) else { return }
        showSegment(isFlown(flight) ? .flown : .upcoming)
    }

    private func showSegment(_ holding: Segment) {
        guard holding != segment else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { segment = holding }
    }

    /// Add flight has finished closing: let the new card in, then open its forecast or show the toast.
    private func addingClosed() {
        // The flight Add flight saved or opened, and whether it's new to the list (not an edit).
        let saved = router.afterAdd.flatMap { store.flight($0.flightID) }
        let isNew = saved.map { heldIDs?.contains($0.id) == false } ?? false
        defer {
            // Asked once the sheet has gone, so nothing fades in over it closing. A new flight is
            // the `flight_added` moment: a Superwall surface if a campaign takes it, otherwise the
            // notifications they switched on, then a rating. An edit only asks for notifications.
            if let saved {
                if isNew {
                    paywalls.take(.flightAdded, flight: saved) {
                        await askForNotifications(saved)
                        ReviewPrompt.flightAdded(saved)
                    }
                } else {
                    Task { await askForNotifications(saved) }
                }
            }
        }
        // The new flight shows on the list that holds it: Upcoming, unless it has already landed.
        if let added = router.afterAdd?.flightID { showSegment(of: added) }
        if router.afterAdd?.openForecast == true {
            // Opening the forecast: put the card in place at once so the zoom has a source.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { heldIDs = nil }
        } else {
            heldIDs = nil  // settles in with the house spring (the .animation above)
        }
        router.finishAdding()
    }

    /// Add flight's "Tell me when it's ready" toggle, asked for once the sheet has gone.
    private func askForNotifications(_ flight: Flight) async {
        guard flight.notify, PushNotifications.shared.status == .notDetermined else { return }
        await PushNotifications.shared.requestPermission()
    }

    /// On Upcoming the sky follows the next flight's local departure time; otherwise it's now.
    private var sky: Sky {
        guard shown == .upcoming, let next = upcoming.first else { return Sky(date: .now) }
        return Sky(date: next.departureAt, timeZone: next.originAirport?.timeZone ?? .current)
    }

    @ViewBuilder
    private var notices: some View {
        if Services.isDemo {
            Label("Demo mode: sample forecast, nothing is saved", systemImage: "info.circle")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
        // Shown as soon as the phone is offline, not only after a sync has failed. Connection
        // wording only for a connection problem; any other failed sync gets a neutral line.
        let note = ConnectionNote(store: store, connectivity: connectivity)
        if let text = OfflineCopy.banner(note, checkedAt: lastChecked) {
            Label(text, systemImage: note.symbol)
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
    }

    /// When the phone last heard from us: its last sync, or a newer forecast fetched since.
    private var lastChecked: Date? {
        OfflineCopy.lastChecked(syncedAt: store.syncedAt, issued: store.forecasts.values.map(\.issuedAt))
    }

    /// Upcoming or Flown. VoiceOver hears how many flights each holds.
    private var segmentPicker: some View {
        Picker("Show", selection: Binding(get: { shown }, set: { segment = $0; segmentTaps += 1 })) {
            Text("Upcoming").tag(Segment.upcoming).accessibilityLabel("Upcoming, \(Self.count(upcoming.count))")
            Text("Flown").tag(Segment.flown).accessibilityLabel("Flown, \(Self.count(flown.count))")
        }
        .pickerStyle(.segmented)
    }

    /// The next flight always leads: its card, cancelled flights, Coming up, flights just landed,
    /// the free limit, then the Learn card. With nothing coming up, a flight just landed leads.
    private var upcomingList: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let next = upcoming.first {
                NavigationLink(value: next.id) {
                    NextFlightCard(flight: next, forecast: store.forecasts[next.id])
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: next.id, in: zoom)
                .contextMenu { deleteButton(next) }
                noticeRows(cancelled)
                if upcoming.count > 1 {
                    section("Coming up", flights: Array(upcoming.dropFirst()))
                }
                noticeRows(justLanded)
                if !paywalls.canAddFlight { limitNote }
            } else if shownIDs.isEmpty {
                if !store.isLoading { emptyState }
            } else {
                ForEach(justLanded) { JustLandedCard(flight: $0) }
                noticeRows(cancelled)
                noUpcomingState
            }
            LearnCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Flights on Upcoming that aren't coming up, one row each: cancelled (add the new flight) or
    /// just landed (rate it). Tapping the row opens the flight.
    @ViewBuilder
    private func noticeRows(_ flights: [Flight]) -> some View {
        if !flights.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(flights) { flight in
                    // A cancelled flight's replacement is never behind the free limit.
                    let action: () -> Void = flight.isCancelled ? { isAdding = true } : { rating = flight }
                    NavigationLink(value: flight.id) {
                        NoticeRow(flight: flight, forecast: store.forecasts[flight.id], action: action)
                            .skyCard(cornerRadius: 18, padding: 14)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: flight.id, in: zoom)
                    .contextMenu { deleteButton(flight) }
                    .accessibilityActions {
                        Button(flight.isCancelled ? "Add your new flight" : "Rate this flight", action: action)
                    }
                }
            }
        }
    }

    /// How the forecasts felt, then every flown flight by month, newest first.
    private var flownList: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let flownSummary {
                Text(flownSummary).font(.bcSubheadline).foregroundStyle(.secondary)
            }
            ForEach(flownMonths) { month in
                section(month.title, flights: month.flights, flown: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "12 flights flown. Forecasts felt about right on 8 of the 9 you rated." A cancelled flight
    /// wasn't flown, and only ratings scored against a forecast count.
    private var flownSummary: String? {
        let flights = flown.filter { !$0.isCancelled }
        guard !flights.isEmpty else { return nil }
        let lead = "\(Self.count(flights.count)) flown."
        let scored = flights.compactMap { store.reports[$0.id]?.matched }
        let right = scored.filter { $0 }.count
        switch scored.count {
        case 0: return lead
        case 1:
            return lead + (right == 1
                ? " The forecast felt about right on the one you rated."
                : " The one you rated felt different from the forecast.")
        default: return lead + " Forecasts felt about right on \(right) of the \(scored.count) you rated."
        }
    }

    /// Flown flights by month of departure in the origin's time ("October 2026"), newest first.
    private var flownMonths: [FlownMonth] {
        var months: [FlownMonth] = []
        for flight in flown {
            let timeZone = flight.originAirport?.timeZone ?? .current
            let title = flight.departureAt.formatted(Date.FormatStyle(timeZone: timeZone).month(.wide).year())
            if let index = months.firstIndex(where: { $0.title == title }) {
                months[index].flights.append(flight)
            } else {
                months.append(FlownMonth(title: title, flights: [flight]))
            }
        }
        return months
    }

    /// "1 flight", "3 flights".
    private static func count(_ flights: Int) -> String { flights == 1 ? "1 flight" : "\(flights) flights" }

    /// Flown rows show the day and the rating, or a way to rate.
    private func section(_ title: String, flights: [Flight], flown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrow().foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(flights) { flight in
                let rate: (() -> Void)? = flown && canRate(flight) ? { rating = flight } : nil
                NavigationLink(value: flight.id) {
                    FlightRow(
                        flight: flight, forecast: store.forecasts[flight.id], report: store.reports[flight.id],
                        flown: flown, rate: rate
                    )
                    .skyCard(cornerRadius: 18, padding: 14)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: flight.id, in: zoom)
                .contextMenu { deleteButton(flight) }
                .accessibilityActions {
                    if let rate { Button("Rate this flight", action: rate) }
                }
            }
        }
    }

    /// At the free limit: said calmly under the flights, so the paywall behind + isn't a surprise.
    private var limitNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You're using your \(Paywalls.freeUpcomingFlights) free upcoming flights").font(.bcHeadline)
                .fixedSize(horizontal: false, vertical: true)  // wrap, never cut off
            Text("Flown flights don't count. Pro saves as many as you like.")
                .font(.bcSubheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("See Pro") { paywalls.unlock(.flightLimitReached) {} }
                .font(.bcSubheadlineStrong)
                .foregroundStyle(Theme.accent)
                .buttonStyle(.borderless)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    private func deleteButton(_ flight: Flight) -> some View {
        Button("Delete flight", systemImage: "trash", role: .destructive) {
            Task { await store.delete(flight.id) }
        }
    }

    private var emptyState: some View {
        emptyCard("No flights yet", "Save a flight and we'll have its turbulence forecast ready 48 hours before you fly.")
    }

    /// Nothing ahead but flights flown or cancelled: a way to the next one, and back to the ones flown.
    private var noUpcomingState: some View {
        emptyCard(
            "No upcoming flights", "Add your next flight and we'll have its forecast ready 48 hours before you fly.",
            seeFlown: !flown.isEmpty)
    }

    private func emptyCard(_ title: String, _ message: String, seeFlown: Bool = false) -> some View {
        VStack(spacing: 12) {
            WaterGlass(severity: nil, size: 48)
            Text(title).font(.bcTitle2)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add a flight", action: addFlight)
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            if seeFlown {
                Button(flown.count == 1 ? "See your flown flight" : "See your \(flown.count) flown flights") {
                    segment = .flown
                }
                .font(.bcSubheadlineStrong)
                .foregroundStyle(Theme.accent)
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity)
        .skyCard()
    }

    /// Free users can keep a couple of upcoming flights; more goes through the paywall.
    private func addFlight() {
        if paywalls.canAddFlight {
            isAdding = true
        } else {
            paywalls.unlock(.flightLimitReached) { isAdding = true }
        }
    }
}

/// One month of flown flights.
private struct FlownMonth: Identifiable {
    let title: String
    var flights: [Flight]
    var id: String { title }
}

/// With nothing coming up, a flight that landed in the last day with no rating yet leads, with
/// the answers on the card. Once rated it leaves, and the flight lives in Flown.
private struct JustLandedCard: View {
    let flight: Flight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(flight.flightNumber.map { "Just landed · \($0)" } ?? "Just landed").eyebrow().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)  // wrap, never cut off the flight number
                Text(flight.routeText).font(.bcDisplay).displayTypeLimit()
            }
            Text("How did it compare?").font(.bcSection)
            LandingRatingChoices(flight: flight)
        }
        .skyCard()
    }
}

/// A flight on Upcoming that isn't coming up, as one row under the next flight: "Cancelled" with
/// a way to add the new flight, or "Just landed" with a way to rate it.
private struct NoticeRow: View {
    let flight: Flight
    let forecast: Forecast?
    let action: () -> Void

    var body: some View {
        let cancelled = flight.isCancelled
        let label = cancelled ? "Cancelled" : "Just landed"
        AdaptiveStack {
            if cancelled {
                CancelledMark()
            } else {
                WaterGlass(severity: ForecastState(flight: flight, forecast: forecast, betaOn: GlobalBeta.shared.isOn).severity, size: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(flight.flightNumber.map { "\(label) · \($0)" } ?? label).eyebrow().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)  // wrap, never cut off the flight number
                Text(cancelled ? "\(flight.routeText) · \(flight.departureDayText)" : flight.routeText).font(.bcHeadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    Text(cancelled ? "Add your new flight ›" : "How did it compare? Rate it ›").multilineTextAlignment(.leading)
                }
                .font(.bcCaptionStrong)
                .foregroundStyle(Theme.accent)
                .buttonStyle(.borderless)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A cancelled flight's mark where the water glass goes: ink, never red.
private struct CancelledMark: View {
    var body: some View {
        Image(systemName: "xmark.circle")
            .font(.bcTitle2)
            .foregroundStyle(.primary)
            .frame(width: 30)
            .accessibilityHidden(true)
    }
}

/// "Rate it" from a row: the flight screen's landing check on its own, with the result after.
private struct RateFlightSheet: View {
    let flight: Flight

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(flight.departureDayText).eyebrow().foregroundStyle(.secondary)
                    Text(flight.titleText).font(.bcTitle)
                }
                LandingCheckCard(flight: flight)
            }
            .padding(20)
        }
        .skyBackground(Sky(date: .now))
    }
}

/// The next flight, large: route, time, live status, water glass, grade, wave timeline and
/// confidence. Free users see the grade and gate; the flight's full path of bumps is Pro.
/// In the air it shows progress instead: what's happening now, what's next, and when it lands.
struct NextFlightCard: View {
    let flight: Flight
    let forecast: Forecast?

    @Environment(Paywalls.self) private var paywalls
    @Environment(InFlight.self) private var inFlight

    var body: some View {
        // Once a minute on the flight's own minutes, so the progress line, the "now" mark and the
        // landing time step together, and with the flight screen. Never for a cancelled or diverted flight.
        TimelineView(.flightMinutes(takeoff: inFlight.effectiveTakeoff(of: flight))) { context in
            card(minute: InFlightMode.minute(flight, forecast: forecast, inFlight: inFlight, now: max(context.date, .now)))
        }
    }

    /// `minute` is the time since takeoff while in the air, and nil on the ground.
    private func card(minute: Int?) -> some View {
        let state = ForecastState(flight: flight, forecast: forecast, betaOn: GlobalBeta.shared.isOn)
        let inAir = minute != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(eyebrow(inAir: inAir)).eyebrow().foregroundStyle(.secondary)
                    Text(flight.routeText).font(.bcDisplay).displayTypeLimit()
                    Text(inAir ? landingText : flight.departureText).font(.bcMeta).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)  // wrap, never cut off the time
                    LiveStatusRow(flight: flight)
                }
                Spacer()
                WaterGlass(severity: state.severity, size: 44)
            }
            switch state {
            case .ready(let forecast):
                if let minute, paywalls.hasFullAccess(to: flight) {
                    // What's now and next names the stretch timings, so it comes with the countdown.
                    // Everyone sees "In the air" and the landing time above (status is free).
                    Text(forecast.progressLine(minute: minute, departure: flight.departureAt)).font(.bcTitle2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let grade = forecast.grade {
                    Text(forecast.isGlobalOutlook ? grade.outlookHeadline : grade.headline).font(.bcTitle2)
                }
                if !forecast.officialWarnings.isEmpty {
                    OfficialWarningLabel()
                }
                if paywalls.hasFullAccess(to: flight) {
                    WaveTimeline(forecast: forecast, nowMinute: minute)
                } else {
                    LockedWaveTimeline(forecast: forecast) {
                        paywalls.unlock(.timelineLocked, flight: flight) {}
                    }
                }
                let confidence = forecast.confidence(departure: flight.departureAt)
                HStack(spacing: 6) {
                    Image(systemName: confidence.symbol)
                    Text(confidence.title)
                    if confidence.isBeta { BetaTag() }
                    if inAir {
                        // Up here it matters when the phone got it, not how long ago it was made.
                        Text(updatedInTheAir(forecast) ? "· updated in the air" : "· saved before takeoff")
                    } else if let issued = forecast.issuedAt {
                        Text("· updated \(issued.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.bcFootnoteStrong)
                .foregroundStyle(confidence.color)
            case .unlocksAt(let date):
                Text("Too early to tell").font(.bcTitle2)
                Text("Your first forecast arrives \(date.approximateDayAndTime()).").foregroundStyle(.secondary)
            case .building:
                Text("Building your forecast").font(.bcTitle2)
                Text("Checking the latest turbulence data along your route.").foregroundStyle(.secondary)
            case .betaAvailable:
                Text(GlobalOutlookCopy.notForecastYet).font(.bcTitle2)
                Text("\(GlobalOutlookCopy.listBetaAvailable): our global outlook can cover this route.").foregroundStyle(.secondary)
            case .outOfCoverage:
                Text(GlobalOutlookCopy.unsupportedTitle).font(.bcTitle2)
                Text(GlobalOutlookCopy.unsupportedBody).foregroundStyle(.secondary)
            }
        }
        .skyCard()
        .accessibilityElement(children: .combine)
    }

    /// "Next flight · AC 1507", or "In the air · AC 1507" once it has taken off.
    private func eyebrow(inAir: Bool) -> String {
        let lead = inAir ? "In the air" : "Next flight"
        return flight.flightNumber.map { "\(lead) · \($0)" } ?? lead
    }

    /// "Landing around 3:45 PM EDT", in the destination's time.
    private var landingText: String {
        let landing = inFlight.landing(of: flight, forecast: forecast)
        return "Landing around \(landing.localTimeWithZone(in: flight.destinationTimeZone))"
    }

    /// The forecast was issued after takeoff, so it reached the phone on the plane's wifi. The same
    /// rule as the forecast screen, so the two never disagree.
    private func updatedInTheAir(_ forecast: Forecast) -> Bool {
        (forecast.issuedAt ?? .distantPast) > inFlight.effectiveTakeoff(of: flight)
    }
}

/// The wave's shape, blurred, with a way in. Never the real stretch timings.
private struct LockedWaveTimeline: View {
    let forecast: Forecast
    let unlock: () -> Void

    var body: some View {
        Button(action: unlock) {
            ZStack {
                WaveTimeline(forecast: forecast).blur(radius: 6)
                Label("See when the bumps are", systemImage: "lock")
                    .font(.bcCaptionStrong)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: .capsule)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("See when the bumps are. Pro.")
    }
}

struct FlightRow: View {
    let flight: Flight
    let forecast: Forecast?
    var report: LandingReport? = nil
    /// On Flown: the day without the time, no grade pill (the water glass still shows the
    /// forecast), and the rating or `rate`. A cancelled flight says so instead.
    var flown = false
    /// "Rate it" for a flown flight with no rating yet.
    var rate: (() -> Void)? = nil

    var body: some View {
        let state = ForecastState(flight: flight, forecast: forecast, betaOn: GlobalBeta.shared.isOn)
        let cancelledFlight = flown && flight.isCancelled
        AdaptiveStack {
            if cancelledFlight {
                CancelledMark()
            } else {
                WaterGlass(severity: state.severity, size: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                if flown {
                    if cancelledFlight {
                        Text("Cancelled").eyebrow().foregroundStyle(.secondary)
                    }
                    Text(flight.titleText).font(.bcHeadline)
                } else {
                    // Route and status share a line until the text is too big, then stack.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(flight.titleText).font(.bcHeadline)
                            Spacer()
                            StatusPill(state: state)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flight.titleText).font(.bcHeadline)
                            StatusPill(state: state)
                        }
                    }
                }
                Text(flown ? flight.departureDayText : flight.departureText).font(.bcMeta).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)  // wrap, never cut off the time
                if flight.departureAt > .now.addingTimeInterval(-3 * 3600), !cancelledFlight {
                    LiveStatusRow(flight: flight)
                }
                if let report {
                    Label(report.summary, systemImage: report.matched == true ? "checkmark.circle" : "hand.raised")
                        .font(.bcCaptionStrong)
                        .foregroundStyle(.secondary)
                } else if let rate {
                    Button(action: rate) {
                        Text("How did it feel? Rate it ›").multilineTextAlignment(.leading)
                    }
                    .font(.bcCaptionStrong)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.borderless)
                } else if case .ready(let forecast) = state, flight.departureAt > .now {
                    if !forecast.officialWarnings.isEmpty {
                        OfficialWarningLabel()
                    } else {
                        let confidence = forecast.confidence(departure: flight.departureAt)
                        Label(confidence.shortStatus(), systemImage: confidence.symbol)
                            .font(.bcCaptionStrong)
                            .foregroundStyle(confidence.color)
                    }
                } else if case .unlocksAt(let date) = state {
                    Text("Too early · first forecast \(date.relativeDay())")
                        .font(.bcCaptionStrong)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    let state: ForecastState

    var body: some View {
        Group {
            switch state {
            case .ready(let forecast):
                if let grade = forecast.grade {
                    Text(forecast.isGlobalOutlook ? grade.outlookTitle : grade.title).foregroundStyle(grade.color)
                }
            case .unlocksAt:
                Text("Too early").foregroundStyle(.secondary)
            case .building:
                Text("Preparing").foregroundStyle(.secondary)
            case .betaAvailable:
                Text(GlobalOutlookCopy.listBetaAvailable).foregroundStyle(.secondary)
            case .outOfCoverage:
                Text("Can't forecast yet").foregroundStyle(.secondary)
            }
        }
        .font(.bcCaptionStrong)
    }
}

/// A doorway into the Learn library from the Flights screen.
private struct LearnCard: View {
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.tab = .learn
        } label: {
            HStack(spacing: 14) {
                AdaptiveStack {
                    Image(systemName: "book.pages").font(.bcTitle2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Why planes handle turbulence").font(.bcHeadline)
                        Text("Short reads on what's happening and what the crew is doing.")
                            .font(.bcSubheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .skyCard(cornerRadius: 18, padding: 14)
        }
        .buttonStyle(.plain)
    }
}

/// "⚑ Official warning on route": flags only official warnings, never pilot reports.
struct OfficialWarningLabel: View {
    var body: some View {
        Label(GlobalOutlookCopy.listWarning, systemImage: "flag.fill")
            .font(.bcCaptionStrong)
            .foregroundStyle(Theme.ink)
    }
}

/// The mono BETA tag on global outlook badges.
struct BetaTag: View {
    var body: some View {
        Text("BETA")
            .font(.custom(BrandFont.monoMedium, size: 10, relativeTo: .caption2))
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(lineWidth: 1))
            .accessibilityLabel("beta")
    }
}

extension ForecastState {
    /// What the water glass shows: the forecast's worst stretch, or nil (dashed) when unknown.
    var severity: Severity? {
        if case .ready(let forecast) = self { return forecast.worstSeverity }
        return nil
    }
}

extension Forecast {
    var worstSeverity: Severity { segments.map(\.severity).max() ?? .smooth }
}

extension Flight {
    /// Departure in the origin airport's local time, e.g. "Sun, Oct 18 · 3:00 PM EDT".
    var departureText: String {
        let tz = originAirport?.timeZone ?? .current
        let time = Date.FormatStyle(timeZone: tz).hour().minute()
        let zone = tz.abbreviation(for: departureAt) ?? ""
        return "\(departureDayText) · \(departureAt.formatted(time)) \(zone)"
    }

    /// The departure day in the origin airport's local time, e.g. "Sun, Oct 18".
    var departureDayText: String {
        let tz = originAirport?.timeZone ?? .current
        // Short enough for one line of Plex Mono on a small phone: no year unless it differs.
        var calendar = Calendar.current
        calendar.timeZone = tz
        var day = Date.FormatStyle(timeZone: tz).weekday(.abbreviated).month(.abbreviated).day()
        if calendar.component(.year, from: departureAt) != calendar.component(.year, from: .now) {
            day = day.year()
        }
        return departureAt.formatted(day)
    }
}
