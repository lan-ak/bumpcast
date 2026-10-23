import SwiftUI

struct FlightsListView: View {
    @Environment(FlightStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(Paywalls.self) private var paywalls
    @Environment(InFlight.self) private var inFlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @Namespace private var zoom
    @State private var isAdding = false
    @State private var isShowingSettings = false
    /// Flights on screen when Add flight opened. A new one settles in once the sheet has closed,
    /// where it can be seen, instead of behind the sheet.
    @State private var heldIDs: Set<UUID>?

    private var connectivity: Connectivity { .shared }

    var body: some View {
        @Bindable var store = store
        @Bindable var router = router
        NavigationStack(path: $router.flightPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    notices
                    if let next = upcoming.first {
                        NavigationLink(value: next.id) {
                            NextFlightCard(flight: next, forecast: store.forecasts[next.id])
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: next.id, in: zoom)
                        .contextMenu { deleteButton(next) }
                    }
                    if upcoming.count > 1 {
                        section("Coming up", flights: Array(upcoming.dropFirst()))
                    }
                    if !flown.isEmpty {
                        section("Flown", flights: flown)
                    }
                    if shownIDs.isEmpty && !store.isLoading {
                        emptyState
                    }
                    LearnCard()
                }
                .padding()
                // A new flight settles in with the house spring.
                .animation(Theme.motion(reduceMotion), value: shownIDs)
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
            // The one "flight added" haptic, as the new card settles in.
            .sensoryFeedback(trigger: shownIDs.count) { old, new in
                new > old && hapticsEnabled ? .impact(flexibility: .soft, intensity: 0.5) : nil
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
    private var upcoming: [Flight] { store.upcomingFlights.filter(isShown) }
    private var flown: [Flight] {
        store.flights.filter { isShown($0) && inFlight.landing(of: $0, forecast: store.forecasts[$0.id]) <= .now }.reversed()
    }

    /// Add flight has finished closing: let the new card in, then open its forecast or show the toast.
    private func addingClosed() {
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

    /// The sky follows the next flight's local departure time, or now.
    private var sky: Sky {
        guard let next = upcoming.first else { return Sky(date: .now) }
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

    private func section(_ title: String, flights: [Flight]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrow().foregroundStyle(.secondary)
            ForEach(flights) { flight in
                NavigationLink(value: flight.id) {
                    FlightRow(flight: flight, forecast: store.forecasts[flight.id], report: store.reports[flight.id])
                        .skyCard(cornerRadius: 18, padding: 14)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: flight.id, in: zoom)
                .contextMenu { deleteButton(flight) }
            }
        }
    }

    private func deleteButton(_ flight: Flight) -> some View {
        Button("Delete flight", systemImage: "trash", role: .destructive) {
            Task { await store.delete(flight.id) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            WaterGlass(severity: nil, size: 48)
            Text("No flights yet").font(.bcTitle2)
            Text("Save a flight and we'll have its turbulence forecast ready 48 hours before you fly.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add a flight", action: addFlight)
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
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

    var body: some View {
        let state = ForecastState(flight: flight, forecast: forecast, betaOn: GlobalBeta.shared.isOn)
        AdaptiveStack {
            WaterGlass(severity: state.severity, size: 30)
            VStack(alignment: .leading, spacing: 4) {
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
                Text(flight.departureText).font(.bcMeta).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)  // wrap, never cut off the time
                if flight.departureAt > .now.addingTimeInterval(-3 * 3600) {
                    LiveStatusRow(flight: flight)
                }
                if let report {
                    Label(report.summary, systemImage: report.matched == true ? "checkmark.circle" : "hand.raised")
                        .font(.bcCaptionStrong)
                        .foregroundStyle(.secondary)
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
        // Short enough for one line of Plex Mono on a small phone: no year unless it differs.
        var calendar = Calendar.current
        calendar.timeZone = tz
        var day = Date.FormatStyle(timeZone: tz).weekday(.abbreviated).month(.abbreviated).day()
        if calendar.component(.year, from: departureAt) != calendar.component(.year, from: .now) {
            day = day.year()
        }
        let time = Date.FormatStyle(timeZone: tz).hour().minute()
        let zone = tz.abbreviation(for: departureAt) ?? ""
        return "\(departureAt.formatted(day)) · \(departureAt.formatted(time)) \(zone)"
    }
}
