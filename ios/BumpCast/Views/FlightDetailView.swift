import SwiftUI

struct FlightDetailView: View {
    let flightID: UUID
    /// On the open iPhone Duo the Flights tab shows the next flight's forecast in place: the sections
    /// only, inside the list's own scroll view and navigation bar.
    var embedded = false
    /// Embedded: the list's own entries before the flight's (its controls) and after (Coming up,
    /// the Learn card), so the list and the forecast are one list.
    var listLeading: [AdaptiveItem] = []
    var listTail: [AdaptiveItem] = []

    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight
    @Environment(PushNotifications.self) private var push
    @Environment(Router.self) private var router
    @Environment(EmailImport.self) private var emailImport
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    private var connectivity: Connectivity { .shared }

    /// The id the flight is listed under now. A sync can save a flight again under a new id (an
    /// account that was lost); the open screen follows it there rather than reading "Flight removed".
    private var currentID: UUID { inFlight.currentID(of: flightID) }

    var body: some View {
        if embedded {
            if let flight = store.flight(currentID) {
                // The flight's menu comes along into the list's navigation bar.
                clock(flight).modifier(actions(flight)).task(id: flight.id) { await waitForStatus() }
            }
        } else {
            screen
        }
    }

    private var screen: some View {
        Group {
            if let flight = store.flight(currentID) {
                content(flight)
            } else {
                removed
            }
        }
        .onAppear(perform: logOpened)
        // While this screen is on top, what's done here that doesn't go through (a delete, or an
        // edit still saving after its sheet closed) says so here; the list's alert waits its turn.
        .alert("That didn't go through", isPresented: .constant(store.error != nil && router.flightPath.last == flightID)) {
            Button("OK") { store.error = nil }
        } message: {
            Text("Check your connection and try again. Your saved forecasts still work offline.")
        }
    }

    /// `flight_opened`, or `flight_link_missing` for a link or notification to a deleted flight.
    private func logOpened() {
        let source = router.openedFrom ?? "list"
        router.openedFrom = nil
        guard let flight = store.flight(currentID) else {
            return Analytics.logOnce(.flightLinkMissing, ["from": source])
        }
        Analytics.log(.flightOpened, Analytics.forecastParams(flight).merging(["source": source]) { $1 })
    }

    private var removed: some View {
        // Brand type, not ContentUnavailableView's system fonts.
        VStack(spacing: 10) {
            Image(systemName: "airplane").font(.bcTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Flight removed").font(.bcTitle2)
            Text("It's no longer in your flights.").font(.bcSubheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .skyBackground(Sky(date: .now))
    }

    private func content(_ flight: Flight) -> some View {
        ScrollView {
            clock(flight)
                .padding()
        }
        .skyBackground(Sky(date: flight.departureAt, timeZone: flight.originAirport?.timeZone ?? .current))
        .navigationTitle("Forecast")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(actions(flight))
        .refreshable { await store.refresh() }
        .task(id: flight.id) { await waitForStatus() }
    }

    /// The More menu (edit, delete) and the edit sheet. Add flight opens the new forecast or shows
    /// its toast once the sheet has closed. A new flight (from the cancelled card) opens from the
    /// Flights list, which runs the follow-up: the card settling in, the flight_added moment and
    /// the notification prompt.
    private func actions(_ flight: Flight) -> FlightActions {
        FlightActions(flight: flight, isEditing: $isEditing, onDelete: { Task { await delete(flight) } })
    }

    /// One clock for the screen, on the flight's minutes, so the in-flight card and the forecast
    /// below it never disagree about now. Never behind the real time, so a tap ("We've landed")
    /// shows at once rather than on the next tick. The state follows it too, so "Your forecast
    /// unlocks …" moves on to "Building" when that time comes.
    private func clock(_ flight: Flight) -> some View {
        let forecast = store.forecasts[flight.id]
        return TimelineView(.flightMinutes(takeoff: inFlight.effectiveTakeoff(of: flight))) { context in
            let now = max(context.date, .now)
            let state = ForecastState(flight: flight, forecast: forecast, now: now, betaOn: GlobalBeta.shared.isOn)
            entries(flight, forecast: forecast, state: state, now: now)
                .task(id: state == .building) {
                    // While the worker is building the forecast, check back every 30 seconds (online only).
                    while ForecastState(flight: flight, forecast: store.forecasts[flight.id], betaOn: GlobalBeta.shared.isOn) == .building,
                        !Task.isCancelled
                    {
                        try? await Task.sleep(for: .seconds(30))
                        guard connectivity.isOnline else { continue }
                        await store.refreshForecast(flight.id)
                    }
                }
        }
    }

    /// Leaves the screen only once the flight is gone: one that wasn't deleted stays, with the alert.
    private func delete(_ flight: Flight) async {
        await store.delete(flight.id)
        if store.flight(flight.id) == nil { dismiss() }
    }

    /// The screen as one list: the route and its notes, the status cards, the forecast (or what
    /// stands in for it), then the updates. Embedded in the Flights list, the list's own entries
    /// go first and last. `AdaptiveSpread` shows it as the phone's stack or as a spread.
    @ViewBuilder
    private func entries(_ flight: Flight, forecast: Forecast?, state: ForecastState, now: Date) -> some View {
        let header = listLeading + headerItems(flight, forecast: forecast, state: state, now: now)
        // Opened from Coming up on a spread, the other flights coming up and the Learn card follow.
        let comingUp = store.comingUp(after: flight.id)
        let more: [AdaptiveItem] =
            !listTail.isEmpty
            ? listTail
            : (comingUp.isEmpty
                ? [] : [AdaptiveItem(FlightRowsSection(title: FlightRowsSection.comingUpTitle, flights: comingUp, compact: true), onPhone: false)])
                + [AdaptiveItem(LearnCard(), onPhone: false)]
        let tail = [AdaptiveItem(UpdatesSection(flight: flight))] + more
        switch state {
        case _ where flight.isCancelled:
            // The forecast describes a flight that isn't happening.
            AdaptiveSpread(items: header + tail, spacing: 20)
        case .ready(let forecast) where flight.status?.state == .diverted:
            ForecastView(
                forecast: forecast, flight: flight, now: now,
                before: header + [AdaptiveItem(DivertedForecastNote(flight: flight))], after: tail, leadSpacing: 8, fade: 0.45)
        case .ready(let forecast):
            ForecastView(forecast: forecast, flight: flight, now: now, before: header, after: tail)
        default:
            AdaptiveSpread(items: header + [standIn(flight, state: state)].compactMap { $0 } + tail, spacing: 20)
        }
    }

    /// The route, its status and notes, then the cards for where the flight is now, in order.
    private func headerItems(_ flight: Flight, forecast: Forecast?, state: ForecastState, now: Date) -> [AdaptiveItem] {
        let landed = inFlight.landing(of: flight, forecast: forecast) <= now
        // The flying card carries its own connection note, so the label above it steps aside.
        let cardShowsConnection: Bool =
            if case .ready(let forecast) = state {
                !landed && InFlightMode.showsFlyingCard(flight, forecast: forecast, inFlight: inFlight, now: now)
            } else {
                false
            }
        let note = ConnectionNote(store: store)
        var items = [
            AdaptiveItem(FlightRouteHeader(flight: flight)),
            AdaptiveItem(ScheduleNote(flight: flight)),
            AdaptiveItem(EmailFlightNotes(flight: flight) { dismiss() }),
        ]
        if !cardShowsConnection,
            let text = OfflineCopy.detail(
                note, checkedAt: OfflineCopy.lastChecked(syncedAt: store.syncedAt, issued: [forecast?.issuedAt]))
        {
            items.append(AdaptiveItem(OfflineNote(text: text, symbol: note.symbol)))
        }
        if case .ready(let forecast) = state {
            if landed {
                // A cancelled flight wasn't flown: nothing to rate.
                if !flight.isCancelled { items.append(AdaptiveItem(LandingCheckCard(flight: flight))) }
            } else {
                items.append(AdaptiveItem(InFlightCard(flight: flight, forecast: forecast, now: now)))
            }
        }
        // Before the flight, while notifications are off.
        if !landed, flight.departureAt > now, !push.isEnabled, state != .outOfCoverage, state != .betaAvailable {
            items.append(AdaptiveItem(NotificationsCard(
                flight: flight, forecastReady: { if case .ready = state { true } else { false } }(),
                globalOutlook: !Coverage.covers(flight))))
        }
        if flight.isCancelled {
            items.append(AdaptiveItem(CancelledCard(
                flight: flight, fromEmail: emailImport.isCancelledFromEmail(flight.id),
                addFlight: {
                    router.addFlightSource = "cancelled_card"
                    router.showAddFlight = true
                }
            ) { Task { await delete(flight) } }))
        } else if flight.status?.state == .diverted {
            items.append(AdaptiveItem(DivertedCard(flight: flight)))
        }
        return items
    }

    /// What stands in for the forecast before it's ready, or on a route it can't cover.
    private func standIn(_ flight: Flight, state: ForecastState) -> AdaptiveItem? {
        switch state {
        case .unlocksAt(let date):
            AdaptiveItem(MessageCard(
                symbol: "clock",
                title: "Your forecast unlocks \(date.formatted(.relative(presentation: .named)))",
                message: "Turbulence forecasts are only reliable about two days out. We'll have yours ready 48 hours before departure, then refresh it as your flight gets closer."
            ))
        case .building:
            AdaptiveItem(MessageCard(
                symbol: "hourglass",
                title: "Building your forecast",
                message: "We're checking the latest turbulence data along your route. This usually takes a few minutes."
            ))
        case .betaAvailable:
            AdaptiveItem(BetaInviteCard(flight: flight))
        case .outOfCoverage:
            AdaptiveItem(WaitlistCard(flight: flight))
        case .ready:
            nil
        }
    }

    /// A numbered flight near departure with no status yet, usually one just added (sometimes
    /// already in the air): the worker fetches it within seconds, so check back every 10 seconds
    /// for a couple of minutes. The header, the takeoff time and the countdown then follow.
    private func waitForStatus() async {
        for _ in 0..<12 {
            let id = currentID
            guard let flight = store.flight(id), flight.flightNumber != nil, !flight.schedulePending,
                !store.isPending(id), flight.status?.hasStatus != true,
                abs(flight.departureAt.timeIntervalSinceNow) < 6 * 3600
            else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            guard connectivity.isOnline else { continue }
            await store.refreshFlight(currentID)
        }
    }
}

/// A flight's More menu: on its forecast screen, and in the Flights toolbar on the open iPhone Duo,
/// where the next flight's forecast is in place. Each screen keeps its own edit and delete.
struct FlightActionsMenu: View {
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Button("Edit flight", systemImage: "pencil", action: onEdit)
            DeleteFlightButton(action: onDelete)
        }
    }
}

/// "You're offline" or "Couldn't refresh" under the route.
private struct OfflineNote: View, DuoPlaced {
    let text: String
    let symbol: String
    var duoRole: DuoRole { .leading }

    var body: some View {
        Label(text, systemImage: symbol).font(.bcFootnote).foregroundStyle(.secondary)
    }
}

/// Above a diverted flight's faded forecast.
private struct DivertedForecastNote: View {
    let flight: Flight

    var body: some View {
        Text("This forecast was for the original route to \(flight.destinationAirport?.iata ?? flight.destination).")
            .font(.bcFootnote)
            .foregroundStyle(.secondary)
    }
}

/// The flight's More menu and edit sheet, wherever its forecast is shown.
private struct FlightActions: ViewModifier {
    let flight: Flight
    @Binding var isEditing: Bool
    let onDelete: () -> Void
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content
            .toolbar { FlightActionsMenu(onEdit: { isEditing = true }, onDelete: onDelete) }
            .adaptiveSheet(isPresented: $isEditing, onDismiss: { router.finishAdding() }) { AddFlightView(flight: flight) }
    }
}

/// Stands where the forecast's grade would: beside the route header on a spread.
struct MessageCard<Actions: View>: View, DuoPlaced {
    var duoRole: DuoRole { .trailing }
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.bcTitle).foregroundStyle(.tint)
            Text(title).font(.bcSection)
            Text(message).foregroundStyle(.secondary)
            actions
        }
        .skyCard()
    }
}

extension MessageCard where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// A route only the global outlook covers, with the beta off: offer it, plainly.
private struct BetaInviteCard: View, DuoPlaced {
    var duoRole: DuoRole { .trailing }
    let flight: Flight
    @Environment(FlightStore.self) private var store
    @State private var dismissed = false

    var body: some View {
        if dismissed {
            MessageCard(
                symbol: "globe",
                title: GlobalOutlookCopy.notForecastYet,
                message: "You can turn on global outlooks (beta) in Settings at any time.")
        } else {
            MessageCard(symbol: "globe", title: GlobalOutlookCopy.waitlistTitle, message: GlobalOutlookCopy.waitlistBody) {
                HStack {
                    Button(GlobalOutlookCopy.turnOn) {
                        GlobalBeta.shared.set(true, from: "flight_invite")
                        Task { await store.refreshForecast(flight.id) }
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                    Button(GlobalOutlookCopy.notNow) {
                        GlobalBeta.shared.set(false, from: "flight_invite")
                        dismissed = true
                        UserDefaults.standard.set(true, forKey: key)
                    }
                    .buttonStyle(.bordered).tint(Theme.accent)
                }
                .font(.bcSubheadlineStrong)
            }
            .onAppear { dismissed = UserDefaults.standard.bool(forKey: key) }
        }
    }

    private var key: String { "betaInvite.dismissed.\(flight.id)" }
}

/// No forecast can cover this route yet (polar and other routes the worker can't do).
private struct WaitlistCard: View, DuoPlaced {
    var duoRole: DuoRole { .trailing }
    let flight: Flight
    @Environment(FlightStore.self) private var store
    @State private var isJoining = false

    var body: some View {
        let airport = Coverage.uncoveredAirport(flight)
        let country = airport?.country ?? "XX"
        MessageCard(
            symbol: "globe",
            title: GlobalOutlookCopy.unsupportedTitle,
            message: GlobalOutlookCopy.unsupportedBody
        ) {
            if store.waitlist.contains(country) {
                Label("We'll let you know when we can forecast it.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    isJoining = true
                    Task {
                        await store.joinWaitlist(country: country, airport: airport?.icao)
                        isJoining = false
                    }
                } label: {
                    Label(GlobalOutlookCopy.unsupportedAction, systemImage: "bell")
                }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                .disabled(isJoining)
            }
        }
    }
}

private struct NotificationsCard: View {
    let flight: Flight
    let forecastReady: Bool
    /// The worker only pushes a global outlook for a real change, and never "confirmed".
    var globalOutlook = false

    @Environment(PushNotifications.self) private var push
    @Environment(Paywalls.self) private var paywalls
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge").font(.bcTitle2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(forecastReady ? "Get told if your forecast changes" : "Get told when your forecast is ready")
                    .font(.bcCardTitle)
                Text(forecastReady
                    ? globalOutlook
                        ? GlobalOutlookCopy.notifyBody
                        : "We'll notify you at 24, 6 and 2 hours before departure, and when your forecast is confirmed."
                    : "We'll notify you 48 hours before departure, then when anything changes.")
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
                Button(push.status == .denied ? "Turn on in Settings" : "Turn on notifications") {
                    if push.status == .denied {
                        openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
                    } else {
                        // A Superwall surface if a campaign takes it, otherwise the system prompt.
                        paywalls.take(.turnOnNotifications, flight: flight) { await push.requestPermission(from: "flight_card") }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .skyCard()
    }
}
