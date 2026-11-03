import SwiftUI

// Live flight status and published-schedule notes, free for every flight with a number.
// docs/design/flight-status-1.1-copy.md §1a, §2 and §3. Status never borrows the severity
// colours: ink and accent teal, with words carrying the meaning. Never say where status
// comes from, and never imply live tracking (no position, no "Landed").

extension Flight {
    /// Live status starts 48 hours before departure, with the forecast.
    var liveStatusStartsAt: Date { departureAt.addingTimeInterval(-Flight.forecastWindow) }

    var originTimeZone: TimeZone { originAirport?.timeZone ?? .current }
    var destinationTimeZone: TimeZone { destinationAirport?.timeZone ?? .current }

    /// Cancelled: no countdown, reminders or in-flight progress for it. By its live status, or by
    /// a booking email (kept on the phone, see EmailCancellations).
    var isCancelled: Bool { status?.state == .cancelled || EmailCancellations.shared.contains(id) }

    /// Cancelled or diverted: the countdown and in-flight progress follow the planned flight, so
    /// the screens never show them.
    var isDisrupted: Bool { isCancelled || status?.state == .diverted }
}

extension FlightStatus {
    var isDelayed: Bool { state == .delayed && (delayMin ?? 0) >= 5 }

    /// Only the published schedule, with no live times behind it: never "On time" then, since
    /// nothing says so.
    var isScheduleOnly: Bool { state == .scheduled && !live }

    /// Neither delayed nor moved on: the line says "On time" (or "Scheduled times only") and the gate.
    var isOnTimeState: Bool {
        switch state {
        case .delayed?: !isDelayed
        case .departed?, .cancelled?, .diverted?: false
        case .scheduled?, nil: true
        }
    }

    /// "Delayed 40 min", "On time", "Departed", "Cancelled", "Diverted".
    var headline: String {
        switch state {
        case .delayed?: "Delayed \((delayMin ?? 0).durationText)"
        case .departed?: "Departed"
        case .cancelled?: "Cancelled"
        case .diverted?: "Diverted"
        case .scheduled?, nil: "On time"
        }
    }

    /// Close to departure, a gate that still isn't known is often only on the airport screens.
    static let gateScreensWindow: TimeInterval = 90 * 60

    /// "Gate B22 · Terminal 5", "Terminal A · Gate not announced yet", or nothing when neither is
    /// known. Never promises a gate is coming: some flights only show it at the airport.
    func gateText(departure: Date, now: Date = .now) -> String? {
        switch (departureGate, departureTerminal) {
        case let (gate?, terminal?): "Gate \(gate) · Terminal \(terminal)"
        case let (gate?, nil): "Gate \(gate)"
        case let (nil, terminal?):
            departure.timeIntervalSince(now) > Self.gateScreensWindow
                ? "Terminal \(terminal) · Gate not announced yet" : "Terminal \(terminal) · Gate on airport screens"
        case (nil, nil): nil
        }
    }

    /// The gate stops mattering once the plane has left, or isn't leaving from here.
    var showsGate: Bool {
        switch state {
        case .departed?, .cancelled?, .diverted?: false
        default: takeoffAt.map { $0 > .now } ?? true
        }
    }

    var divertedAirport: Airport? { divertedTo.flatMap { AirportStore.shared.airport($0) } }
}

/// The compact status row on the flight card: gate, delays and cancellations, free for everyone.
struct LiveStatusRow: View {
    let flight: Flight

    @Environment(\.scenePhase) private var scenePhase
    @State private var seen: GateMemory.Record?

    var body: some View {
        if flight.flightNumber == nil || flight.expectedDeparture < .now.addingTimeInterval(-3 * 3600) {
            EmptyView()
        } else if flight.schedulePending {
            Label("We'll fill in the details when the airline publishes this flight.", systemImage: "calendar.badge.clock")
                .font(.bcCaptionStrong)
                .foregroundStyle(.secondary)
        } else {
            Label {
                line
            } icon: {
                Image(systemName: symbol)
            }
            .font(.bcCaptionStrong)
            .foregroundStyle(flight.status?.isDelayed == true ? Theme.accent : Theme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(spoken ?? text)
            .onAppear(perform: noteGate)
            .onChange(of: gateKey) { noteGate() }
            .onChange(of: scenePhase) { noteGate() }
        }
    }

    private var gateKey: String { "\(flight.status?.departureGate ?? "")|\(flight.status?.departureTerminal ?? "")" }

    /// Records the gate on screen (only while the app is in use), then reads back what was shown before.
    private func noteGate() {
        if scenePhase == .active { GateMemory.note(flight.status, for: flight.id) }
        seen = GateMemory.record(for: flight.id)
    }

    private var onTimeStatus: FlightStatus? {
        guard let status = flight.status, status.hasStatus, status.isOnTimeState else { return nil }
        return status
    }

    /// The row: a changed gate in teal with the old one struck through ("Gate B22, was B18").
    private var line: Text {
        guard let status = onTimeStatus else { return Text(text) }
        let parts = onTimeParts(status)
        var line = Text(parts.lead)
        if let gate = parts.gate { line = Text("\(line) · \(Text(gate).foregroundStyle(parts.was == nil ? Theme.secondaryInk : Theme.accent))") }
        if let rest = parts.rest { line = Text("\(line)\(rest)") }
        if let was = parts.was { line = Text("\(line), was \(Text(was).strikethrough())") }
        if let after = parts.after { line = Text("\(line) · \(after)") }
        return line
    }

    /// What VoiceOver reads for an on-time row: "On time, gate B22, changed from B18".
    private var spoken: String? {
        guard let status = onTimeStatus else { return nil }
        let parts = onTimeParts(status)
        let lead = status.isScheduleOnly ? "Scheduled times only, no live updates for this flight so far" : parts.lead
        // Lowercase the words, never the codes ("gate B22").
        func words(_ text: String) -> String {
            text.replacingOccurrences(of: " · ", with: "").replacingOccurrences(of: "Gate ", with: "gate ")
                .replacingOccurrences(of: "Terminal ", with: "terminal ")
        }
        var spoken = ([lead] + [parts.gate, parts.rest].compactMap { $0.map(words) }).joined(separator: ", ")
        if let was = parts.was { spoken += ", changed from \(words(was))" }
        if let after = parts.after { spoken += ", \(words(after))" }
        return spoken
    }

    /// "On time" · "Gate B22" ", was B18", or "On time" · "Gate B22" " · Terminal 5" ", was Terminal 4".
    private struct OnTimeParts {
        var lead: String
        var gate: String?
        var rest: String?
        var was: String?
        var after: String?
    }

    private func onTimeParts(_ status: FlightStatus) -> OnTimeParts {
        var parts = OnTimeParts(lead: status.isScheduleOnly ? "Scheduled times only" : "On time")
        guard status.showsGate else { return parts }
        let change = GateMemory.change(status, seen: seen)
        let soon = flight.expectedDeparture.timeIntervalSinceNow <= FlightStatus.gateScreensWindow
        if let gate = status.departureGate {
            parts.gate = "Gate \(gate)"
            if let was = change.wasTerminal, let terminal = status.departureTerminal {
                // Always the full form here, never "T4".
                parts.rest = " · Terminal \(terminal)"
                parts.was = "Terminal \(was)"
            } else if let was = change.wasGate {
                // The unchanged terminal stays in the header, so "was B18" can't read as a pair.
                parts.was = was
            } else if let terminal = status.departureTerminal {
                parts.rest = " · Terminal \(terminal)"
            }
            return parts
        }
        // No gate now: the terminal if known, and near departure, where to look.
        if let terminal = status.departureTerminal {
            parts.gate = "Terminal \(terminal)"
            parts.was = change.wasTerminal.map { "Terminal \($0)" }
        }
        if soon {
            parts.after = "Gate on airport screens"
        } else if status.departureTerminal != nil, change.lastShownGate == nil, change.wasTerminal == nil, !status.isScheduleOnly {
            parts.after = "Gate not announced yet"
        }
        return parts
    }

    private var text: String {
        guard let status = flight.status, status.hasStatus else {
            if Date.now < flight.liveStatusStartsAt {
                return "Live status starts \(flight.liveStatusStartsAt.dayName(.abbreviated))"
            }
            // No row yet: the worker checks within a few minutes. A row without a status was checked.
            return flight.status == nil ? "Checking live status…" : "Live status isn't available for this flight"
        }
        let tz = flight.originTimeZone
        switch status.state {
        case .delayed? where status.isDelayed:
            var parts = [status.headline]
            if let expected = status.departureExpected { parts.append("now \(expected.localTime(in: tz))") }
            if let gate = status.departureGate, status.showsGate { parts.append("Gate \(gate)") }
            return parts.joined(separator: " · ")
        case .departed?:
            return status.departureActual.map { "Departed \($0.localTime(in: tz))" } ?? "Departed"
        case .cancelled?:
            return "Cancelled"
        case .diverted?:
            return status.divertedAirport.map { "Diverted to \($0.iata)" } ?? "Diverted"
        default:
            let gate = status.showsGate ? status.gateText(departure: flight.expectedDeparture) : nil
            return (["On time"] + [gate].compactMap { $0 }).joined(separator: " · ")
        }
    }

    private var symbol: String {
        switch flight.status?.state {
        case .delayed? where flight.status?.isDelayed == true: "clock"
        case .departed?: "airplane.departure"
        case .cancelled?: "xmark.circle"
        case .diverted?: "arrow.triangle.branch"
        default: "airplane"
        }
    }
}

/// The detail view's route header, tracker-style: times beside the airports and the status in a
/// small label under the plane. Tap for the details. Approved: docs/design/flight-status-compact.html.
struct FlightRouteHeader: View, DuoPlaced {
    var duoRole: DuoRole { .leading }
    let flight: Flight

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isWideLayout) private var isWideLayout
    @State private var expanded = false
    @State private var seen: GateMemory.Record?

    /// On a wide screen (the open iPhone Duo) there's room, so the details are always shown and the
    /// header isn't a toggle.
    private var alwaysOpen: Bool { isWideLayout }

    var body: some View {
        let status = flight.status.flatMap { $0.hasStatus ? $0 : nil }
        let hasDetails = status != nil && status?.state != .cancelled && flight.flightNumber != nil
        VStack(alignment: .leading, spacing: 12) {
            if alwaysOpen {
                header(status, chevron: false)
                    .frame(minHeight: 44)
            } else {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    header(status, chevron: hasDetails)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!hasDetails)
                .accessibilityHint(hasDetails ? (expanded ? "Hides flight details" : "Shows flight details") : "")
            }
            if expanded || alwaysOpen, let status, hasDetails {
                FlightStatusDetails(flight: flight, status: status, seen: seen)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if flight.schedulePending {
                Label("We'll fill in the details when the airline publishes this flight.", systemImage: "calendar.badge.clock")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            noteGate()
            if opensOnAppear(status) { expanded = true }
        }
        .onChange(of: "\(flight.status?.departureGate ?? "")|\(flight.status?.departureTerminal ?? "")") { noteGate() }
        .onChange(of: scenePhase) { noteGate() }
    }

    /// Records the gate on screen (only while the app is in use), then reads back what was shown before.
    private func noteGate() {
        if scenePhase == .active { GateMemory.note(flight.status, for: flight.id) }
        seen = GateMemory.record(for: flight.id)
    }

    @ViewBuilder private func header(_ status: FlightStatus?, chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow).eyebrow().foregroundStyle(.secondary)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    departureSide(status)
                    arrivalSide(status, alignment: .leading)
                    StatusLabel(flight: flight, status: status, chevron: chevron, expanded: expanded)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    departureSide(status)
                    Spacer(minLength: 0)
                    VStack(spacing: 4) {
                        Image(systemName: "airplane").font(.bcTitle2).foregroundStyle(.secondary)
                        StatusLabel(flight: flight, status: status, chevron: chevron, expanded: expanded)
                    }
                    .padding(.top, 8)
                    Spacer(minLength: 0)
                    arrivalSide(status, alignment: .trailing)
                }
            }
        }
    }

    private var eyebrow: String {
        let tz = flight.originTimeZone
        let day = flight.departureAt.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated).month(.abbreviated).day())
        guard let number = flight.flightNumber else { return day }
        return ([number] + [flight.airlineName].compactMap { $0 } + [day]).joined(separator: " · ")
    }

    private func departureSide(_ status: FlightStatus?) -> some View {
        let scheduled = status?.departureScheduled ?? flight.departureAt
        let current = status.flatMap { $0.state == .cancelled ? nil : ($0.departureActual ?? $0.departureExpected) }
        // A moved time already stacks a struck line here: the old gate then shows in the details only.
        let timeMoved = current.map { abs($0.timeIntervalSince(scheduled)) >= 60 } ?? false
        let change = status.map { GateMemory.change($0, seen: seen) } ?? GateMemory.Change()
        let previous: (gate: String, terminal: String?)? =
            if let was = change.wasGate { (was, status?.departureTerminal) }
            else if let was = change.wasTerminal, let gate = change.wasTerminalGate { (gate, was) }
            else { nil }
        return VStack(alignment: .leading, spacing: 2) {
            Text(flight.originAirport?.iata ?? flight.origin).font(.bcDisplay)
            Text(flight.originAirport?.city ?? "").font(.bcFootnote).foregroundStyle(.secondary)
            TimePair(current: current, scheduled: scheduled, tz: flight.originTimeZone, alignment: .leading)
            if let gate = status?.departureGate, status?.showsGate == true {
                ViewThatFits(in: .horizontal) {
                    Text(Self.gateLine(gate, status?.departureTerminal, short: false))
                    Text(Self.gateLine(gate, status?.departureTerminal, short: true))
                }
                .font(.bcCaption)
                .foregroundStyle(previous != nil && !timeMoved ? Theme.accent : Theme.secondaryInk)
                if let previous, !timeMoved {
                    ViewThatFits(in: .horizontal) {
                        Text(Self.gateLine(previous.gate, previous.terminal, short: false))
                        Text(Self.gateLine(previous.gate, previous.terminal, short: true))
                    }
                    .font(.bcCaption2)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("was \(Self.gateLine(previous.gate, previous.terminal, short: false))")
                }
            }
        }
    }

    private func arrivalSide(_ status: FlightStatus?, alignment: HorizontalAlignment) -> some View {
        let diverted = status?.state == .diverted ? status?.divertedAirport : nil
        let code = flight.destinationAirport?.iata ?? flight.destination
        let scheduled = status?.arrivalScheduled ?? flight.arrivalAt
        let current = status.flatMap { $0.state == .cancelled ? nil : ($0.arrivalActual ?? $0.arrivalExpected) }
        return VStack(alignment: alignment, spacing: 2) {
            if let diverted {
                Text(diverted.iata).font(.bcDisplay)
                Text(code).font(.bcFootnote).strikethrough().foregroundStyle(.secondary)
                    .accessibilityLabel("instead of \(code)")
            } else {
                Text(code).font(.bcDisplay)
                Text(flight.destinationAirport?.city ?? "").font(.bcFootnote).foregroundStyle(.secondary)
                if let scheduled {
                    TimePair(current: current, scheduled: scheduled, tz: flight.destinationTimeZone, alignment: alignment)
                }
            }
        }
    }

    /// "Gate B22 · Terminal 5", or "Gate B22 · T5" when space is short.
    static func gateLine(_ gate: String, _ terminal: String?, short: Bool) -> String {
        guard let terminal else { return "Gate \(gate)" }
        return "Gate \(gate) · " + (short ? "T\(terminal)" : "Terminal \(terminal)")
    }

    /// Details open by themselves once, the first time the flight is seen after a new delay, gate,
    /// cancellation or diversion. Leaving the screen closes them again.
    private func opensOnAppear(_ status: FlightStatus?) -> Bool {
        guard let status, status.state != .cancelled else { return false }
        let signature = Self.signature(status)
        if signature != (UserDefaults.standard.string(forKey: seenKey) ?? Self.baseline) {
            UserDefaults.standard.set(signature, forKey: seenKey)
            Self.openedAt[flight.id] = .now
            return true
        }
        // The zoom transition can build the view twice on the way in: the second build opens too.
        return Self.openedAt[flight.id].map { Date.now.timeIntervalSince($0) < 2 } ?? false
    }

    @MainActor private static var openedAt: [UUID: Date] = [:]

    private var seenKey: String { "status.seen.\(flight.id)" }

    /// On time, no gate: nothing worth opening for.
    private static let baseline = "||"

    private static func signature(_ status: FlightStatus) -> String {
        [
            status.isDelayed ? status.departureExpected.map { "\(Int($0.timeIntervalSince1970))" } ?? "" : "",
            status.departureGate ?? "",
            status.state == .cancelled || status.state == .diverted ? status.state?.rawValue ?? "" : "",
        ].joined(separator: "|")
    }
}

/// A time, and when it moved, the scheduled one struck through beneath it.
private struct TimePair: View {
    /// The house mono has Regular and Medium only: Medium is the bold here.
    static let changed = Font.custom(BrandFont.monoMedium, size: 13, relativeTo: .footnote)
    static let was = Font.custom(BrandFont.mono, size: 11, relativeTo: .caption)

    let current: Date?
    let scheduled: Date
    let tz: TimeZone
    let alignment: HorizontalAlignment

    var body: some View {
        let moved = current.map { abs($0.timeIntervalSince(scheduled)) >= 60 } ?? false
        VStack(alignment: alignment, spacing: 0) {
            Text((moved ? current! : scheduled).localTime(in: tz))
                .font(moved ? Self.changed : .bcMeta)
                .monospacedDigit()
            if moved {
                Text(scheduled.localTime(in: tz))
                    .font(Self.was)
                    .monospacedDigit()
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("was \(scheduled.localTime(in: tz))")
            }
        }
    }
}

/// "On time ›", "40 min late ›", "Departed ›", "Diverted ›", "Cancelled", "Checking…",
/// "Live status from Tue". Teal for a delay, bold ink for diverted and cancelled, quiet otherwise.
private struct StatusLabel: View {
    let flight: Flight
    let status: FlightStatus?
    let chevron: Bool
    let expanded: Bool

    var body: some View {
        if let text {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(text)
                    if chevron {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small)
                            .accessibilityHidden(true)
                    }
                }
                .font(emphasis ? .bcCaptionStrong : .bcCaption)
                .foregroundStyle(color)
                if let stale {
                    Text(stale).font(.bcCaption2).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String? {
        guard flight.flightNumber != nil, !flight.schedulePending else { return nil }
        if let status {
            switch status.state {
            case .cancelled?: return "Cancelled"
            case .diverted?: return "Diverted"
            case .departed?: return "Departed"
            case .delayed? where status.isDelayed: return "\((status.delayMin ?? 0).durationText) late"
            default: return status.isScheduleOnly ? "Scheduled times" : "On time"
            }
        }
        if Date.now < flight.liveStatusStartsAt {
            return "Live status from \(flight.liveStatusStartsAt.dayName(.abbreviated))"
        }
        if flight.status == nil, flight.expectedDeparture > .now.addingTimeInterval(-3600) { return "Checking…" }
        return nil  // unavailable: scheduled times only
    }

    private var emphasis: Bool { status?.state == .cancelled || status?.state == .diverted || status?.isDelayed == true }

    private var color: Color {
        if status?.isDelayed == true, status?.state == .delayed { return Theme.accent }
        return emphasis ? Theme.ink : Theme.secondaryInk
    }

    /// How old the status is, only when that matters. In the 3 hours before takeoff, where the app
    /// refreshes it every 5 minutes, "updated 40 min ago" once it's still over 30 minutes old;
    /// in the air "updated 3 h ago" after 2 hours; never once the flight should have landed.
    private var stale: String? {
        guard let status, !status.finished else { return nil }
        let age = Date.now.timeIntervalSince(status.checkedAt)
        let toDeparture = flight.expectedDeparture.timeIntervalSinceNow
        if !flight.isAirborne, toDeparture <= 3 * 3600, toDeparture > -3600 {
            return age > 30 * 60 ? "updated \(Int(age / 60).durationText) ago" : nil
        }
        let landing = status.arrivalActual ?? status.arrivalExpected ?? status.arrivalScheduled ?? flight.arrivalAt
        if let landing, Date.now > landing.addingTimeInterval(30 * 60) { return nil }
        return age > 2 * 3600 ? "updated \(Int(age / 3600)) h ago" : nil
    }
}

/// Opened from the header: times in words, gate and terminal, and when status updates next.
private struct FlightStatusDetails: View {
    let flight: Flight
    let status: FlightStatus
    /// What this phone showed for the gate before, for "Changed from B18."
    var seen: GateMemory.Record?

    @Environment(FlightStore.self) private var store

    var body: some View {
        let from = flight.originAirport?.iata ?? flight.origin
        let to = flight.destinationAirport?.iata ?? flight.destination
        VStack(alignment: .leading, spacing: 8) {
            row("Departs \(from)", actual: status.departureActual, expected: status.departureExpected,
                scheduled: status.departureScheduled ?? flight.departureAt, tz: flight.originTimeZone)
            if status.state != .diverted, let scheduled = status.arrivalScheduled ?? flight.arrivalAt {
                row("Arrives \(to)", actual: status.arrivalActual, expected: status.arrivalExpected,
                    scheduled: scheduled, tz: flight.destinationTimeZone)
            }
            if status.showsGate {
                let change = GateMemory.change(status, seen: seen)
                if let gate = gateText(change) {
                    detail("Gate") { Text(gate) }
                }
                if let was = change.wasGate {
                    note("Changed from \(was).")
                } else if let was = change.wasTerminal {
                    note("Changed from \(change.wasTerminalGate.map { "\($0) · " } ?? "")Terminal \(was).")
                }
                let screens = status.departureGate == nil
                    && flight.expectedDeparture.timeIntervalSinceNow <= FlightStatus.gateScreensWindow
                let notes = [
                    change.lastShownGate.map { "Last shown in the app as \($0)." },
                    screens ? "Some flights only show their gate on the airport screens." : nil,
                ].compactMap { $0 }
                if !notes.isEmpty { note(notes.joined(separator: " ")) }
            }
            if status.isScheduleOnly {
                note("We only have the published schedule for this flight so far. Delays and the gate may only show on the airport screens.")
            }
            Text(freshness).font(.bcFootnote).foregroundStyle(.secondary)
        }
        .font(.bcSubheadline)
        .padding(.vertical, 4)
    }

    private func row(_ title: String, actual: Date?, expected: Date?, scheduled: Date, tz: TimeZone) -> some View {
        // "Actual" only once it has happened: a runway time still ahead is an estimate.
        let happened = actual.flatMap { $0 <= .now ? $0 : nil }
        let expected = happened == nil ? (actual ?? expected) : expected
        return detail(title) {
            if let actual = happened {
                Text("\(actual.localTime(in: tz)) actual").monospacedDigit()
            } else if let expected, abs(expected.timeIntervalSince(scheduled)) >= 60 {
                HStack(spacing: 4) {
                    Text("\(expected.localTime(in: tz)) expected ·").monospacedDigit()
                    Text(scheduled.localTime(in: tz)).monospacedDigit().strikethrough().foregroundStyle(.secondary)
                        .accessibilityLabel("was \(scheduled.localTime(in: tz))")
                }
            } else {
                Text(scheduled.localTime(in: tz)).monospacedDigit()
            }
        }
    }

    private func detail(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.bcSubheadlineStrong)
                Spacer()
                value()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bcSubheadlineStrong)
                value()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.bcFootnote).foregroundStyle(.secondary)
    }

    /// "B22 · Terminal 5", "Not announced yet · Terminal A", or nothing. A gate this phone showed
    /// that has since gone is never "not announced": just the terminal, and "Last shown…" below.
    private func gateText(_ change: GateMemory.Change) -> String? {
        switch (status.departureGate, status.departureTerminal) {
        case let (gate?, terminal?): "\(gate) · Terminal \(terminal)"
        case let (gate?, nil): gate
        case let (nil, terminal?): change.lastShownGate == nil ? "Not announced yet · Terminal \(terminal)" : "Terminal \(terminal)"
        case (nil, nil): nil
        }
    }

    private var freshness: String {
        let updated = "Updated \(status.checkedAt.phoneTime(nextTo: flight.originTimeZone))"
        guard !status.finished, let next = status.nextCheckAt else {
            return "\(updated) · status updates have finished for this flight"
        }
        // Offline (in the air, usually) the next check can't happen, so don't name a time.
        if ConnectionNote(store: store).isConnectionProblem {
            return "\(updated) · we'll check again when you're back online"
        }
        guard next > .now else { return updated }
        return "\(updated) · next update around \(next.phoneTime(nextTo: flight.originTimeZone))"
    }
}

extension Date {
    /// The phone's own time, for "Updated…" lines that sit next to airport-local times. When the
    /// phone's zone isn't the airport's, the zone is named ("2:20 PM EDT") so the two can't be mixed up.
    func phoneTime(nextTo airport: TimeZone?, phone: TimeZone = .current) -> String {
        guard let airport, airport.secondsFromGMT(for: self) != phone.secondsFromGMT(for: self) else {
            return localTime(in: phone)
        }
        return localTimeWithZone(in: phone)
    }
}

extension FlightStatus {
    /// "Updated for the new 7:55 AM departure": the forecast moved with a changed departure. Not for
    /// the old forecast only moved to the new time while a new one is worked out.
    func forecastNote(for flight: Flight, forecast: Forecast) -> String? {
        guard let expected = departureExpected, abs(expected.timeIntervalSince(flight.departureAt)) >= 5 * 60,
            forecast.status == .ready, forecast.retimed != true, let forecastFor = forecast.departureAt,
            abs(forecastFor.timeIntervalSince(expected)) < 60
        else { return nil }
        return "Updated for the new \(expected.localTime(in: flight.originTimeZone)) departure"
    }
}

/// A cancelled flight: replaces the forecast.
struct CancelledCard: View {
    let flight: Flight
    /// Cancelled by a booking email rather than the airline's live status: says so.
    var fromEmail = false
    let addFlight: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "xmark.circle").font(.bcTitle).foregroundStyle(.tint)
            Text(fromEmail ? "Your booking email says this flight was cancelled" : "This flight is cancelled").font(.bcSection)
            Text(
                fromEmail
                    ? "Booked on another flight? Add it and we'll forecast that one instead."
                    : "Your airline will be in touch about other options. When you have a new flight, add it and we'll forecast it."
            )
            .foregroundStyle(.secondary)
            HStack {
                Button(fromEmail ? "Add your new flight" : "Add a new flight", action: addFlight)
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                Button(fromEmail ? "Remove" : "Remove this flight", action: remove)
                    .buttonStyle(.bordered).tint(Theme.accent)
            }
            .font(.bcSubheadlineStrong)
        }
        .skyCard()
    }
}

/// A diverted flight: a calm note above the faded forecast.
struct DivertedCard: View {
    let flight: Flight

    var body: some View {
        let airport = flight.status?.divertedAirport
        VStack(alignment: .leading, spacing: 8) {
            Text(airport.map { "Diverted to \($0.city) (\($0.iata))" } ?? "Diverted").font(.bcSection)
            Text("Diversions are planned for and routine for the crew. Your airline will share what happens next.")
                .foregroundStyle(.secondary)
        }
        .skyCard()
    }
}

/// The one-time "Schedule published" note, from the worker's schedule notification.
struct ScheduleNote: View, DuoPlaced {
    var duoRole: DuoRole { .leading }
    let flight: Flight
    @Environment(FlightStore.self) private var store
    @AppStorage("schedule.notes.seen") private var seen = ""

    var body: some View {
        if let update = (store.updates[flight.id] ?? []).first(where: { $0.kind == "schedule" }),
            !seen.contains(update.id.uuidString)
        {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.checkmark").foregroundStyle(Theme.accent)
                Text(update.changes.first?.text ?? update.body).font(.bcSubheadline)
                Spacer(minLength: 0)
                Button {
                    markSeen(update.id)
                } label: {
                    Image(systemName: "xmark").font(.bcFootnoteStrong).foregroundStyle(.secondary)
                        // About a 44 pt target around the small cross, without moving it.
                        .contentShape(Rectangle().inset(by: -16))
                }
                .accessibilityLabel("Dismiss")
            }
            .skyCard(cornerRadius: 16, padding: 12)
            // One time: once it's been on screen, it's seen.
            .onDisappear { markSeen(update.id) }
        }
    }

    /// Adds the note to the seen list, keeping only notes the phone still holds (a deleted
    /// flight's go with it), so the list doesn't grow for good.
    private func markSeen(_ id: UUID) {
        let held = Set(store.updates.values.joined().map(\.id.uuidString))
        var ids = seen.split(separator: ",").map(String.init).filter(held.contains)
        if !ids.contains(id.uuidString) { ids.append(id.uuidString) }
        seen = ids.suffix(Self.seenLimit).map { $0 + "," }.joined()
    }

    private static let seenLimit = 200
}
