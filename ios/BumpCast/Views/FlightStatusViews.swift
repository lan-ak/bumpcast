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
}

extension FlightStatus {
    var isDelayed: Bool { state == .delayed && (delayMin ?? 0) >= 5 }

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

    var gateText: String? {
        switch (departureGate, departureTerminal) {
        case let (gate?, terminal?): "Gate \(gate) · Terminal \(terminal)"
        case let (gate?, nil): "Gate \(gate)"
        case let (nil, terminal?): "Terminal \(terminal) · Gate not set yet"
        case (nil, nil): nil
        }
    }

    var divertedAirport: Airport? { divertedTo.flatMap { AirportStore.shared.airport($0) } }
}

/// The compact status row on the flight card: gate, delays and cancellations, free for everyone.
struct LiveStatusRow: View {
    let flight: Flight

    var body: some View {
        if flight.flightNumber == nil || flight.expectedDeparture < .now.addingTimeInterval(-3 * 3600) {
            EmptyView()
        } else if flight.schedulePending {
            Label("We'll fill in the details when the airline publishes this flight.", systemImage: "calendar.badge.clock")
                .font(.bcCaptionStrong)
                .foregroundStyle(.secondary)
        } else {
            Label(text, systemImage: symbol)
                .font(.bcCaptionStrong)
                .foregroundStyle(flight.status?.isDelayed == true ? Theme.accent : Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String {
        guard let status = flight.status, status.hasStatus else {
            if Date.now < flight.liveStatusStartsAt {
                return "Live status starts \(flight.liveStatusStartsAt.formatted(.dateTime.weekday(.abbreviated)))"
            }
            // No row yet: the worker checks within a few minutes. A row without a status was checked.
            return flight.status == nil ? "Checking live status…" : "Live status isn't available for this flight"
        }
        let tz = flight.originTimeZone
        switch status.state {
        case .delayed? where status.isDelayed:
            var parts = [status.headline]
            if let expected = status.departureExpected { parts.append("now \(expected.localTime(in: tz))") }
            if let gate = status.departureGate { parts.append("Gate \(gate)") }
            return parts.joined(separator: " · ")
        case .departed?:
            return status.departureActual.map { "Departed \($0.localTime(in: tz))" } ?? "Departed"
        case .cancelled?:
            return "Cancelled"
        case .diverted?:
            return status.divertedAirport.map { "Diverted to \($0.iata)" } ?? "Diverted"
        default:
            return ["On time", status.gateText ?? "Gate not set yet"].joined(separator: " · ")
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
struct FlightRouteHeader: View {
    let flight: Flight

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var expanded = false

    var body: some View {
        let status = flight.status.flatMap { $0.hasStatus ? $0 : nil }
        let hasDetails = status != nil && status?.state != .cancelled && flight.flightNumber != nil
        VStack(alignment: .leading, spacing: 12) {
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
            if expanded, let status, hasDetails {
                FlightStatusDetails(flight: flight, status: status)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if flight.schedulePending {
                Label("We'll fill in the details when the airline publishes this flight.", systemImage: "calendar.badge.clock")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { if opensOnAppear(status) { expanded = true } }
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
        return VStack(alignment: .leading, spacing: 2) {
            Text(flight.originAirport?.iata ?? flight.origin).font(.bcDisplay)
            Text(flight.originAirport?.city ?? "").font(.bcFootnote).foregroundStyle(.secondary)
            TimePair(current: current, scheduled: scheduled, tz: flight.originTimeZone, alignment: .leading)
            if let gate = status?.departureGate {
                ViewThatFits(in: .horizontal) {
                    Text(Self.gateLine(gate, status?.departureTerminal, short: false))
                    Text(Self.gateLine(gate, status?.departureTerminal, short: true))
                }
                .font(.bcCaption)
                .foregroundStyle(.secondary)
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
            default: return "On time"
            }
        }
        if Date.now < flight.liveStatusStartsAt {
            return "Live status from \(flight.liveStatusStartsAt.formatted(.dateTime.weekday(.abbreviated)))"
        }
        if flight.status == nil, flight.expectedDeparture > .now.addingTimeInterval(-3600) { return "Checking…" }
        return nil  // unavailable: scheduled times only
    }

    private var emphasis: Bool { status?.state == .cancelled || status?.state == .diverted || status?.isDelayed == true }

    private var color: Color {
        if status?.isDelayed == true, status?.state == .delayed { return Theme.accent }
        return emphasis ? Theme.ink : Theme.secondaryInk
    }

    /// "updated 3 h ago" once the status is more than 2 hours old and still meant to update.
    private var stale: String? {
        guard let status, !status.finished, Date.now.timeIntervalSince(status.checkedAt) > 2 * 3600 else { return nil }
        return "updated \(Int(Date.now.timeIntervalSince(status.checkedAt) / 3600)) h ago"
    }
}

/// Opened from the header: times in words, gate and terminal, and when status updates next.
private struct FlightStatusDetails: View {
    let flight: Flight
    let status: FlightStatus

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
            if let gate = gateText {
                detail("Gate") { Text(gate) }
            }
            Text(freshness).font(.bcFootnote).foregroundStyle(.secondary)
        }
        .font(.bcSubheadline)
        .padding(.vertical, 4)
    }

    private func row(_ title: String, actual: Date?, expected: Date?, scheduled: Date, tz: TimeZone) -> some View {
        detail(title) {
            if let actual {
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

    /// "B22 · Terminal 5", "Not set yet · Terminal A", or nothing.
    private var gateText: String? {
        switch (status.departureGate, status.departureTerminal) {
        case let (gate?, terminal?): "\(gate) · Terminal \(terminal)"
        case let (gate?, nil): gate
        case let (nil, terminal?): "Not set yet · Terminal \(terminal)"
        case (nil, nil): nil
        }
    }

    private var freshness: String {
        let updated = "Updated \(status.checkedAt.localTime(in: .current))"
        guard !status.finished, let next = status.nextCheckAt else {
            return "\(updated) · status updates have finished for this flight"
        }
        return "\(updated) · next update around \(next.localTime(in: .current))"
    }
}

extension FlightStatus {
    /// "Updated for the new 7:55 AM departure": the forecast moved with a changed departure.
    func forecastNote(for flight: Flight, forecast: Forecast) -> String? {
        guard let expected = departureExpected, abs(expected.timeIntervalSince(flight.departureAt)) >= 5 * 60,
            forecast.status == .ready, let forecastFor = forecast.departureAt,
            abs(forecastFor.timeIntervalSince(expected)) < 60
        else { return nil }
        return "Updated for the new \(expected.localTime(in: flight.originTimeZone)) departure"
    }
}

/// A cancelled flight: replaces the forecast.
struct CancelledCard: View {
    let flight: Flight
    let addFlight: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "xmark.circle").font(.bcTitle).foregroundStyle(.tint)
            Text("This flight is cancelled").font(.bcSection)
            Text("Your airline will be in touch about other options. When you have a new flight, add it and we'll forecast it.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Add a new flight", action: addFlight)
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                Button("Remove this flight", action: remove)
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
struct ScheduleNote: View {
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
                    seen += update.id.uuidString + ","
                } label: {
                    Image(systemName: "xmark").font(.bcFootnoteStrong).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
            }
            .skyCard(cornerRadius: 16, padding: 12)
            // One time: once it's been on screen, it's seen.
            .onDisappear { if !seen.contains(update.id.uuidString) { seen += update.id.uuidString + "," } }
        }
    }
}
